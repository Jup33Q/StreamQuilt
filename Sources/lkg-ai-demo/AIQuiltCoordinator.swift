import Foundation
import LKGQuilt
import Metal
import QuartzCore

/// Drives the AI quilt loop, event-driven: a worker finishing a view
/// immediately triggers compositing of that tile and dispatch of the next
/// view — AI throughput is fully decoupled from the display link rate.
/// The display frame only re-primes the fast raymarch base layer.
final class AIQuiltCoordinator {
    let scene: AIBlockCityScene
    let renderer: QuiltRenderer
    let client: DiffusionClient

    private let viewOrder: [Int]
    private var orderPos = 0
    private var inFlight = Set<Int>()
    private var stagingInUse: [Bool]
    private let stateLock = NSLock()
    private(set) var tilesApplied = 0
    private var frameCount = 0
    /// Per-view last-apply timestamps (wall clock), for per-tile refresh metrics.
    private var lastAppliedAt: [Double]
    private var started = false

    /// Hold-to-peek: while true, the raw raymarch renders into the alt quilt
    /// every frame and the display samples that instead of the AI quilt.
    var rawPeek = false {
        didSet { print("[peek] rawPeek = \(rawPeek)") }
    }

    // diagnostics
    private var dispatchCount = 0
    private var dispatchWindowStart = Date()
    private var dispatchesPerSec: Double = 0
    private var readbackLagMs: Double = 0
    private var readbackLagN = 0
    private var onFrameMs: Double = 0
    private var onFrameN = 0

    init(scene: AIBlockCityScene, renderer: QuiltRenderer, client: DiffusionClient) {
        self.scene = scene
        self.renderer = renderer
        self.client = client
        let n = renderer.spec.viewCount
        let center = Float(n - 1) / 2
        viewOrder = (0..<n).sorted { abs(Float($0) - center) < abs(Float($1) - center) }
        stagingInUse = [Bool](repeating: false, count: scene.staging.count)
        lastAppliedAt = [Double](repeating: 0, count: n)
    }

    /// Start the self-sustaining dispatch loop (call after client.start()).
    func start() {
        client.onResult = { [weak self] r in self?.handleResult(r) }
        // Workers become ready asynchronously (~10s model load); poll for the
        // first ready worker and kick off dispatch. After that the loop
        // sustains itself: every result frees a worker and dispatches again.
        DispatchQueue.global().async { [weak self] in
            while true {
                if let self, self.client.hasIdleWorker {
                    self.dispatchIdle()
                    return
                }
                Thread.sleep(forTimeInterval: 0.25)
            }
        }
    }

    /// Display-frame hook: raw peek renders every frame into the alt quilt;
    /// otherwise the base layer re-primes at 1/6 rate + dispatch fallback.
    func onFrame(cmd: MTLCommandBuffer, time: Float) {
        let t0 = CACurrentMediaTime()
        frameCount += 1
        if rawPeek {
            scene.encodeBase(cmd: cmd, time: time, into: renderer.makeAltQuiltTarget())
        } else if frameCount % 6 == 1 {
            scene.encodeBase(cmd: cmd, time: time)
        }
        dispatchIdle()
        stateLock.lock()
        onFrameMs += (CACurrentMediaTime() - t0) * 1000
        onFrameN += 1
        stateLock.unlock()
    }

    private func handleResult(_ r: DiffusionClient.Result) {
        stateLock.lock()
        inFlight.remove(r.view)
        tilesApplied += 1
        lastAppliedAt[r.view] = CACurrentMediaTime()
        stateLock.unlock()
        applyResult(r)
        dispatchIdle()
    }

    /// Dispatch fresh views to every idle worker.
    private func dispatchIdle() {
        while let workerIdx = client.reserveWorker() {
            stateLock.lock()
            let slot = stagingInUse.firstIndex(of: false)
            let view = nextFreeViewLocked()
            stateLock.unlock()
            guard let slot, let view else {
                client.cancelReservation(workerIdx)
                break
            }
            dispatchView(view, slot: slot, workerIndex: workerIdx)
        }
    }

    private func nextFreeViewLocked() -> Int? {
        for _ in 0..<viewOrder.count {
            let v = viewOrder[orderPos % viewOrder.count]
            orderPos += 1
            if !inFlight.contains(v) { return v }
        }
        return nil
    }

    private func dispatchView(_ v: Int, slot: Int, workerIndex: Int) {
        guard let cmd = renderer.commandQueue.makeCommandBuffer() else {
            client.cancelReservation(workerIndex)
            return
        }
        let t = sceneTime()
        scene.encodeView(cmd: cmd, viewIndex: v, stagingIndex: slot, time: t)
        scene.encodeReadback(cmd: cmd, stagingIndex: slot)
        stateLock.lock()
        inFlight.insert(v)
        stagingInUse[slot] = true
        dispatchCount += 1
        let elapsed = Date().timeIntervalSince(dispatchWindowStart)
        if elapsed >= 2 {
            dispatchesPerSec = Double(dispatchCount) / elapsed
            dispatchCount = 0
            dispatchWindowStart = Date()
        }
        stateLock.unlock()
        let commitAt = CACurrentMediaTime()
        cmd.addCompletedHandler { [weak self] _ in
            guard let self else { return }
            let lag = (CACurrentMediaTime() - commitAt) * 1000
            let vs = self.scene.viewSize
            let src = self.scene.readbackBytes(stagingIndex: slot).bindMemory(to: UInt8.self)
            var rgb = Data(count: vs * vs * 3)
            rgb.withUnsafeMutableBytes { out in
                let o = out.baseAddress!.assumingMemoryBound(to: UInt8.self)
                for i in 0..<(vs * vs) {
                    o[i * 3] = src[i * 4]
                    o[i * 3 + 1] = src[i * 4 + 1]
                    o[i * 3 + 2] = src[i * 4 + 2]
                }
            }
            self.client.submitReserved(workerIndex: workerIndex, view: v, rgb: rgb,
                                       width: vs, height: vs)
            self.stateLock.lock()
            self.stagingInUse[slot] = false
            self.readbackLagMs += lag
            self.readbackLagN += 1
            self.stateLock.unlock()
        }
        cmd.commit()
    }

    private func applyResult(_ r: DiffusionClient.Result) {
        guard let cmd = renderer.commandQueue.makeCommandBuffer() else { return }
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: r.width, height: r.height, mipmapped: false)
        d.storageMode = .shared
        d.usage = .shaderRead
        guard let tex = renderer.device.makeTexture(descriptor: d) else { return }
        r.rgba.withUnsafeBytes { ptr in
            tex.replace(region: MTLRegionMake2D(0, 0, r.width, r.height),
                        mipmapLevel: 0, withBytes: ptr.baseAddress!, bytesPerRow: r.width * 4)
        }
        renderer.updateTile(index: r.view, srcTexture: tex, cmd: cmd)
        cmd.commit()
    }

    /// Scene clock mirrors LKGApp's pause-aware time.
    var sceneTimeProvider: (() -> Float)?
    private func sceneTime() -> Float { sceneTimeProvider?() ?? Float(CACurrentMediaTime()) }

    var statusLine: String {
        stateLock.lock()
        let disp = dispatchesPerSec
        let lag = readbackLagN > 0 ? readbackLagMs / Double(readbackLagN) : 0
        let onf = onFrameN > 0 ? onFrameMs / Double(onFrameN) : 0
        readbackLagMs = 0; readbackLagN = 0; onFrameMs = 0; onFrameN = 0
        // per-tile freshness: average update rate = tiles/s ÷ viewCount,
        // plus worst-case staleness of any painted tile
        let n = Float(lastAppliedAt.count)
        let tileHz = client.resultsPerSec / Double(max(n, 1))
        let now = CACurrentMediaTime()
        var oldest: Double = 0
        var painted = 0
        for t in lastAppliedAt where t > 0 {
            painted += 1
            oldest = max(oldest, now - t)
        }
        stateLock.unlock()
        return String(format: "tile %.2f Hz avg (%.1f tiles/s, %d/%d painted, stale max %.1fs) | disp %.1f/s rbLag %.0fms onFrame %.1fms | %@",
                      tileHz, client.resultsPerSec, painted, Int(n), oldest,
                      disp, lag, onf, scene.statusLine)
    }
}
