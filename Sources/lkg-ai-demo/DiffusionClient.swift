import Foundation

/// Manages a pool of Python quilt_diffusion_worker processes: length-prefixed
/// binary frames over stdin/stdout pipes (protocol documented in the worker).
///
/// Threading: `submit` may be called from any thread (Metal completion
/// handlers); results are buffered and drained from the render loop.
final class DiffusionClient {
    struct Result {
        let view: Int
        let width: Int
        let height: Int
        let rgba: Data
    }

    private final class Worker {
        let id: Int
        let process: Process
        let stdinHandle: FileHandle
        var busy = false
        var ready = false
        var stdoutBuffer = Data()
        init(id: Int, process: Process, stdinHandle: FileHandle) {
            self.id = id
            self.process = process
            self.stdinHandle = stdinHandle
        }
    }

    private var workers: [Worker] = []
    private let resultLock = NSLock()
    private var pendingResults: [Result] = []
    private let writeLock = NSLock()
    private var resultCount = 0
    private var resultWindowStart = Date()

    private let workerCount: Int
    private let prompt: String
    private let renderSize: Int
    private let strength: Float
    private let pythonPath: String
    private let scriptPath: String
    private let coremlDir: String
    private let batch: Int
    /// Per-view latent temporal feedback (0-1). Higher = stronger frame-to-frame
    /// coherence (anti-flicker), too high smears motion.
    private let feedback: Float
    /// Compute-unit assignment per worker. Default hetero split: worker 0 on ANE
    /// ("all"), the rest on GPU ("cpu_and_gpu") — ANE+GPU truly run in parallel,
    /// while two ANE workers just time-slice (measured 19 vs 44 tiles/s).
    private let units: [String]

    /// Results per second over the last window (for the status line).
    private(set) var resultsPerSec: Double = 0

    /// Called on the reader thread when a result arrives (live mode uses this
    /// to self-sustain dispatch; dump mode uses drainResults/processSync).
    var onResult: ((Result) -> Void)?

    init(workerCount: Int, prompt: String, renderSize: Int, strength: Float,
         pythonPath: String, scriptPath: String, coremlDir: String,
         batch: Int = 1, feedback: Float = 0.3, units: [String]? = nil) {
        self.workerCount = workerCount
        self.prompt = prompt
        self.renderSize = renderSize
        self.strength = strength
        self.pythonPath = pythonPath
        self.scriptPath = scriptPath
        self.coremlDir = coremlDir
        self.batch = batch
        self.feedback = feedback
        self.units = units ?? (0..<workerCount).map { $0 == 0 ? "all" : "cpu_and_gpu" }
    }

    var readyWorkerCount: Int { workers.filter { $0.ready }.count }
    var hasIdleWorker: Bool { workers.contains { $0.ready && !$0.busy } }

    /// Reserve an idle worker (marks it busy immediately, so concurrent
    /// dispatchers can't double-book it). Pair with `submitReserved`.
    func reserveWorker() -> Int? {
        writeLock.lock()
        defer { writeLock.unlock() }
        guard let idx = workers.firstIndex(where: { $0.ready && !$0.busy }) else { return nil }
        workers[idx].busy = true
        return idx
    }

    /// Submit a view frame to a previously reserved worker.
    func submitReserved(workerIndex: Int, view: Int, rgb: Data, width: Int, height: Int) {
        let w = workers[workerIndex]
        writePacket(to: w, view: view, rgb: rgb, width: width, height: height)
    }

    /// Cancel a reservation without submitting (e.g. staging render failed).
    func cancelReservation(_ workerIndex: Int) {
        workers[workerIndex].busy = false
    }

    func start() {
        for i in 0..<workerCount { spawn(id: i) }
    }

    func waitUntilReady(timeout: TimeInterval = 60) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if workers.count == workerCount, workers.allSatisfy({ $0.ready }) { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }

    private func spawn(id: Int) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: pythonPath)
        p.arguments = [scriptPath,
                       "--prompt", prompt,
                       "--render-size", String(renderSize),
                       "--strength", String(strength),
                       "--compute-units", units[id % units.count],
                       "--batch", String(batch),
                       "--feedback", String(feedback),
                       "--coreml-dir", coremlDir,
                       "--worker-id", String(id)]
        var env = ProcessInfo.processInfo.environment
        env["HF_HUB_OFFLINE"] = "1"
        p.environment = env
        let inPipe = Pipe()
        let outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = FileHandle.standardError

        let w = Worker(id: id, process: p, stdinHandle: inPipe.fileHandleForWriting)
        workers.append(w)

        outPipe.fileHandleForReading.readabilityHandler = { [weak self, weak w] fh in
            guard let self, let w else { return }
            let data = fh.availableData
            if data.isEmpty { return }
            w.stdoutBuffer.append(data)
            self.parse(worker: w)
        }
        do {
            try p.run()
            print("[diffusion] worker \(id) spawned pid \(p.processIdentifier)")
        } catch {
            print("[diffusion] worker \(id) spawn failed: \(error)")
        }
    }

    private func parse(worker w: Worker) {
        while true {
            if w.stdoutBuffer.count < 12 { return }
            var hdr = [UInt8](repeating: 0, count: 12)
            w.stdoutBuffer.copyBytes(to: &hdr, count: 12)
            func u32(_ o: Int) -> UInt32 {
                UInt32(hdr[o]) | UInt32(hdr[o + 1]) << 8 | UInt32(hdr[o + 2]) << 16 | UInt32(hdr[o + 3]) << 24
            }
            let view = u32(0), wd = u32(4), ht = u32(8)

            if view == 0xFFFFFFFE { // ready beacon
                w.stdoutBuffer.removeFirst(12)
                w.ready = true
                print("[diffusion] worker \(w.id) ready (pid \(wd))")
                continue
            }
            let payloadSize = Int(wd) * Int(ht) * 4
            guard payloadSize > 0, payloadSize < 64 * 1024 * 1024 else {
                print("[diffusion] worker \(w.id) protocol desync, dropping byte")
                w.stdoutBuffer.removeFirst(1)
                continue
            }
            if w.stdoutBuffer.count < 12 + payloadSize { return }
            let s = w.stdoutBuffer.startIndex
            var rgba = Data(count: payloadSize)
            rgba.withUnsafeMutableBytes { ptr in
                w.stdoutBuffer.copyBytes(to: ptr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                                         from: (s + 12)..<(s + 12 + payloadSize))
            }
            w.stdoutBuffer.removeFirst(12 + payloadSize)
            w.busy = false

            resultLock.lock()
            pendingResults.append(Result(view: Int(view), width: Int(wd), height: Int(ht), rgba: rgba))
            resultCount += 1
            let elapsed = Date().timeIntervalSince(resultWindowStart)
            if elapsed >= 2 {
                resultsPerSec = Double(resultCount) / elapsed
                resultCount = 0
                resultWindowStart = Date()
            }
            let cb = onResult
            let res = Result(view: Int(view), width: Int(wd), height: Int(ht), rgba: rgba)
            resultLock.unlock()
            cb?(res)
        }
    }

    /// Submit a view frame (RGB, 3 channels). Returns false if no worker is idle.
    func submit(view: Int, rgb: Data, width: Int, height: Int) -> Bool {
        guard let idx = reserveWorker() else { return false }
        submitReserved(workerIndex: idx, view: view, rgb: rgb, width: width, height: height)
        return true
    }

    private func writePacket(to w: Worker, view: Int, rgb: Data, width: Int, height: Int) {
        var header = Data()
        header.append(contentsOf: withUnsafeBytes(of: UInt32(view).littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: UInt32(width).littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: UInt32(height).littleEndian) { Array($0) })
        writeLock.lock()
        w.stdinHandle.write(header)
        w.stdinHandle.write(rgb)
        writeLock.unlock()
    }

    func setPrompt(_ prompt: String) {
        guard let bytes = prompt.data(using: .utf8) else { return }
        var header = Data()
        header.append(contentsOf: withUnsafeBytes(of: UInt32(0xFFFFFFFF).littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: UInt32(bytes.count).littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: UInt32(0).littleEndian) { Array($0) })
        writeLock.lock()
        for w in workers {
            w.stdinHandle.write(header)
            w.stdinHandle.write(bytes)
        }
        writeLock.unlock()
    }

    /// Drain completed results (called from the render loop).
    func drainResults() -> [Result] {
        resultLock.lock()
        defer { resultLock.unlock() }
        let r = pendingResults
        pendingResults.removeAll()
        return r
    }

    /// Synchronous round trip for offline/dump mode.
    func processSync(view: Int, rgb: Data, width: Int, height: Int, timeout: TimeInterval = 30) -> Result? {
        guard submit(view: view, rgb: rgb, width: width, height: height) else { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            resultLock.lock()
            if let idx = pendingResults.firstIndex(where: { $0.view == view }) {
                let r = pendingResults.remove(at: idx)
                resultLock.unlock()
                return r
            }
            resultLock.unlock()
            Thread.sleep(forTimeInterval: 0.005)
        }
        return nil
    }

    func stopAll() {
        for w in workers {
            if w.process.isRunning { w.process.terminate() }
        }
    }
}
