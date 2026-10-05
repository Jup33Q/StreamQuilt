import Foundation

/// Swift front-end for `python/laya_emotion_worker.py` — a resident laya
/// sidecar serving typed-decision requests over line-delimited JSON
/// (protocol documented in the worker's header).
///
/// Model load takes 7-26s, so the process is spawned once at app start and
/// kept resident; `ready` flips true when the worker reports its lanes.
/// Requests carry a caller-chosen id; responses are paired by id, so
/// multiple in-flight requests are fine. All completions fire on a private
/// serial queue — hop to main before touching UI/engine state.
public final class LayaClient {
    public enum Lane: String {
        case track   // 1024-token model: track-level theme + emotion
        case line    // ANE 96-token model: per-lyric-line re-ranking
    }

    public struct Response {
        /// question name -> chosen criterion
        public let answers: [String: String]
        /// question name -> (criterion -> probability)
        public let probabilities: [String: [String: Float]]
        /// input exceeded the lane's token budget (laya truncated it)
        public let truncated: Bool
    }

    public private(set) var ready = false
    public private(set) var lanes: Set<Lane> = []
    /// Fires when the worker reports ready (on the callback queue).
    public var onReady: (() -> Void)?
    /// Fires when the worker process dies (on the callback queue).
    public var onExit: (() -> Void)?

    private let pythonPath: String
    private let scriptPath: String
    private let trackModel: String?
    private let lineModel: String?

    private var process: Process?
    private var stdinHandle: FileHandle?
    private let callbackQueue = DispatchQueue(label: "laya-client.cb")
    private let ioLock = NSLock()
    private var nextID = 0
    private var inFlight: [Int: (Response?) -> Void] = [:]
    private var stdoutBuffer = Data()

    public init(pythonPath: String, scriptPath: String,
                trackModel: String?, lineModel: String?) {
        self.pythonPath = pythonPath
        self.scriptPath = scriptPath
        self.trackModel = trackModel
        self.lineModel = lineModel
    }

    public func start() {
        var args = [scriptPath]
        if let trackModel { args += ["--track-model", trackModel] }
        if let lineModel { args += ["--line-model", lineModel] }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: pythonPath)
        p.arguments = args
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        p.standardInput = stdinPipe
        p.standardOutput = stdoutPipe
        p.standardError = FileHandle.standardError   // worker logs stay visible
        p.terminationHandler = { [weak self] _ in
            guard let self else { return }
            self.callbackQueue.async {
                // fail every in-flight request; caller decides about respawn
                let pending = self.inFlight
                self.inFlight.removeAll()
                self.ready = false
                for (_, cb) in pending { cb(nil) }
                self.onExit?()
            }
        }
        do {
            try p.run()
        } catch {
            print("[laya] spawn failed: \(error.localizedDescription)")
            return
        }
        process = p
        stdinHandle = stdinPipe.fileHandleForWriting
        Thread.detachNewThread { [weak self] in
            self?.readerLoop(stdoutPipe.fileHandleForReading)
        }
    }

    public func stop() {
        process?.terminate()   // SIGTERM; worker has no cleanup of its own
        process = nil
    }

    /// Queue a prediction. Returns the request id, or nil if the worker is
    /// not ready / the lane was not loaded. Completion fires on the callback
    /// queue with nil on transport failure.
    @discardableResult
    public func predict(lane: Lane, text: String,
                        questions: [String: [String: Any]],
                        completion: @escaping (Response?) -> Void) -> Int? {
        ioLock.lock()
        defer { ioLock.unlock() }
        guard ready, lanes.contains(lane), let stdinHandle else { return nil }
        nextID += 1
        let rid = nextID
        inFlight[rid] = completion
        let req: [String: Any] = ["id": rid, "lane": lane.rawValue,
                                  "text": text, "questions": questions]
        guard let data = try? JSONSerialization.data(withJSONObject: req) else {
            inFlight.removeValue(forKey: rid)
            return nil
        }
        var line = data
        line.append(0x0A)
        stdinHandle.write(line)
        return rid
    }

    // MARK: - Reader thread

    private func readerLoop(_ handle: FileHandle) {
        while true {
            let chunk = handle.availableData   // blocks; empty on EOF
            if chunk.isEmpty { break }
            ioLock.lock()
            stdoutBuffer.append(chunk)
            var frames: [Data] = []
            // Data slices are index-space shifted after mutation; copy via
            // Data(slice) which rebases to 0 (removeFirst/subdata pitfall).
            while let nl = stdoutBuffer.firstIndex(of: 0x0A) {
                frames.append(Data(stdoutBuffer[..<nl]))
                stdoutBuffer = Data(stdoutBuffer[stdoutBuffer.index(after: nl)...])
            }
            ioLock.unlock()
            for f in frames { dispatch(frame: f) }
        }
        // EOF: worker exited
    }

    private func dispatch(frame: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: frame) as? [String: Any]
        else { return }
        if obj["ready"] as? Bool == true {
            let laneNames = (obj["lanes"] as? [String]) ?? []
            let loaded = Set(laneNames.compactMap { Lane(rawValue: $0) })
            ioLock.lock()
            self.lanes = loaded
            self.ready = true
            ioLock.unlock()
            callbackQueue.async { self.onReady?() }
            return
        }
        guard let rid = obj["id"] as? Int else { return }
        ioLock.lock()
        let cb = inFlight.removeValue(forKey: rid)
        ioLock.unlock()
        guard let cb else { return }
        let ok = obj["ok"] as? Bool ?? false
        var resp: Response?
        if ok {
            let answers = (obj["answers"] as? [String: String]) ?? [:]
            var probs: [String: [String: Float]] = [:]
            if let raw = obj["probabilities"] as? [String: [String: NSNumber]] {
                for (q, m) in raw { probs[q] = m.mapValues { $0.floatValue } }
            }
            resp = Response(answers: answers, probabilities: probs,
                            truncated: obj["truncated"] as? Bool ?? false)
        }
        callbackQueue.async { cb(resp) }
    }
}
