import Foundation
import Metal
import QuartzCore

/// Mean Rec.601 luma (0-255) of packed RGB/RGBX bytes — used by the
/// brightness normalization that pulls an AI tile's mean to its input's mean.
public func lumaMean(_ data: Data, bytesPerPixel: Int) -> Float {
    data.withUnsafeBytes { raw in
        let p = raw.bindMemory(to: UInt8.self)
        guard !p.isEmpty else { return 0 }
        var sum: Double = 0
        var n = 0
        // sample every 4th pixel — plenty for a mean, 4x cheaper
        var i = 0
        while i + 2 < p.count {
            sum += Double(p[i]) * 0.299 + Double(p[i + 1]) * 0.587 + Double(p[i + 2]) * 0.114
            n += 1
            i += bytesPerPixel * 4
        }
        return n > 0 ? Float(sum / Double(n)) : 0
    }
}

/// Drives the AI quilt loop, event-driven: a worker finishing a view
/// immediately triggers compositing of that tile and dispatch of the next
/// view — AI throughput is fully decoupled from the display link rate.
/// The display frame only re-primes the fast raymarch base layer.
public final class AIQuiltCoordinator {
    public let scene: AIBlockCityScene
    public let renderer: QuiltRenderer
    public let client: DiffusionClient

    /// Tile update order: center-out priority vs serpentine scan wave.
    public enum ViewOrderMode { case center, wave }
    public var orderMode: ViewOrderMode = .wave {
        didSet { stateLock.lock(); viewOrder = Self.buildViewOrder(orderMode, spec: renderer.spec); orderPos = 0; stateLock.unlock() }
    }

    private var viewOrder: [Int]
    private var orderPos = 0
    private var inFlight = Set<Int>()
    private var stagingInUse: [Bool]
    private let stateLock = NSLock()
    public private(set) var tilesApplied = 0
    private var frameCount = 0
    /// Per-view last-apply timestamps (wall clock), for per-tile refresh metrics.
    private var lastAppliedAt: [Double]
    /// Per-view last-dispatch timestamps; enforces min re-diffusion interval.
    private var lastDispatchAt: [Double]
    /// Minimum seconds between two diffusions of the same view (anti-thrash).
    public var minViewInterval: Double = 0.4
    /// Crossfade generation per view; a newer result cancels an older fade.
    private var fadeGen: [Int: Int] = [:]
    /// N1: brightness normalization strength. 0 = off; 1 = the AI tile's mean
    /// luma is pulled fully to its input frame's mean (anti-flicker backstop).
    public var lumaNormStrength: Float = 1.0
    /// Per-view mean luma of the dispatched input frame (for lumaGain).
    private var inputLuma: [Int: Float] = [:]
    /// N4: beat clock for epoch quantization — returns (phase in beats,
    /// seconds per beat), nil when unavailable (falls back to 1s epochs).
    public var beatClockProvider: (() -> (phase: Double, beatLen: Double)?)?
    private var started = false

    /// Permanent alt-quilt (raw raymarch) blend floor 0..1 (CLI --alt-mix);
    /// damps AI tile pop-in by always showing some of the fresh raw layer.
    public var baseAltMix: Float = 0
    /// Smoothed G-fader position: ramps toward 1 while rawPeek is held.
    private var peekMix: Float = 0

    /// Hold-to-peek: ramps the display mix toward the alt (raw raymarch) quilt.
    public var rawPeek = false {
        didSet { if rawPeek != oldValue { print("[peek] rawPeek = \(rawPeek)") } }
    }

    /// Alt-quilt blend for the display loop (nil = main quilt only).
    public var altMixForDisplay: (MTLTexture, Float)? {
        let m = max(peekMix, min(max(baseAltMix, 0), 1))
        guard m > 0.001, let alt = renderer.altQuiltTexture else { return nil }
        return (alt, m)
    }

    // diagnostics
    private var dispatchCount = 0
    private var dispatchWindowStart = Date()
    private var dispatchesPerSec: Double = 0
    private var readbackLagMs: Double = 0
    private var readbackLagN = 0
    private var onFrameMs: Double = 0
    private var onFrameN = 0

    public init(scene: AIBlockCityScene, renderer: QuiltRenderer, client: DiffusionClient) {
        self.scene = scene
        self.renderer = renderer
        self.client = client
        let n = renderer.spec.viewCount
        viewOrder = Self.buildViewOrder(.wave, spec: renderer.spec)
        stagingInUse = [Bool](repeating: false, count: scene.staging.count)
        lastAppliedAt = [Double](repeating: 0, count: n)
        lastDispatchAt = [Double](repeating: 0, count: n)
    }

    private static func buildViewOrder(_ mode: ViewOrderMode, spec: QuiltSpec) -> [Int] {
        let n = spec.viewCount
        switch mode {
        case .center:
            let center = Float(n - 1) / 2
            return (0..<n).sorted { abs(Float($0) - center) < abs(Float($1) - center) }
        case .wave:
            // N3 serpentine scan: bottom row upward, alternating direction —
            // updates read as a continuous sweep instead of scattered pops.
            var order: [Int] = []
            order.reserveCapacity(n)
            for r in 0..<spec.rows {
                if r % 2 == 0 {
                    for c in 0..<spec.columns { order.append(r * spec.columns + c) }
                } else {
                    for c in stride(from: spec.columns - 1, through: 0, by: -1) {
                        order.append(r * spec.columns + c)
                    }
                }
            }
            return order
        }
    }

    /// Start the self-sustaining dispatch loop (call after client.start()).
    public func start() {
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

    /// Display-frame hook: primes the base under not-yet-diffused tiles ONCE
    /// at startup, renders the alt (raw) quilt while the blend is engaged,
    /// smooths the G-fader, and runs the dispatch fallback.
    /// NOTE: the base layer must NOT be periodically re-rendered into the
    /// main quilt — a full-quilt dontCare pass hard-wipes every AI tile
    /// (~10 Hz), which strobes worse than any tile pop-in. Freshness of the
    /// raw layer comes from the alt quilt + altMix lerp instead.
    public func onFrame(cmd: MTLCommandBuffer, time: Float) {
        let t0 = CACurrentMediaTime()
        frameCount += 1
        // smooth G-fader: exponential approach at display rate (~63% per 8 frames)
        peekMix += ((rawPeek ? 1 : 0) - peekMix) * 0.12
        if frameCount == 1 {
            scene.encodeBase(cmd: cmd, time: time)
        }
        // alt (raw) layer: half rate is plenty for a lerp source and keeps the
        // GPU free for the diffusion workers (full-rate peek halves tiles/s).
        if rawPeek || peekMix > 0.001 || baseAltMix > 0.001, frameCount % 2 == 0 {
            scene.encodeBase(cmd: cmd, time: time, into: renderer.makeAltQuiltTarget())
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
        let now = CACurrentMediaTime()
        for _ in 0..<viewOrder.count {
            let v = viewOrder[orderPos % viewOrder.count]
            orderPos += 1
            if !inFlight.contains(v), now - lastDispatchAt[v] >= minViewInterval { return v }
        }
        return nil
    }

    /// Epoch-quantized scene timestamp. N4: when a beat clock is available,
    /// epoch boundaries land on every 2nd beat (content refreshes in time
    /// with the music); otherwise 1s wall-clock epochs (S1).
    private func epochTime() -> Float {
        if let bc = beatClockProvider?() {
            let epochBeats = 2.0
            let e = (bc.phase / epochBeats).rounded(.down) * epochBeats
            return Float(e * bc.beatLen)
        }
        return floor(sceneTime())
    }

    private func dispatchView(_ v: Int, slot: Int, workerIndex: Int) {
        guard let cmd = renderer.commandQueue.makeCommandBuffer() else {
            client.cancelReservation(workerIndex)
            return
        }
        // epoch quantization: every view dispatched in the same epoch shares
        // one scene timestamp -> geometry/lighting consistent within a sweep.
        let t = epochTime()
        scene.encodeView(cmd: cmd, viewIndex: v, stagingIndex: slot, time: t)
        scene.encodeReadback(cmd: cmd, stagingIndex: slot)
        stateLock.lock()
        inFlight.insert(v)
        stagingInUse[slot] = true
        lastDispatchAt[v] = CACurrentMediaTime()
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
            self.inputLuma[v] = lumaMean(rgb, bytesPerPixel: 3)
            self.readbackLagMs += lag
            self.readbackLagN += 1
            self.stateLock.unlock()
        }
        cmd.commit()
    }

    private func applyResult(_ r: DiffusionClient.Result) {
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: r.width, height: r.height, mipmapped: false)
        d.storageMode = .shared
        d.usage = .shaderRead
        guard let tex = renderer.device.makeTexture(descriptor: d) else { return }
        r.rgba.withUnsafeBytes { ptr in
            tex.replace(region: MTLRegionMake2D(0, 0, r.width, r.height),
                        mipmapLevel: 0, withBytes: ptr.baseAddress!, bytesPerRow: r.width * 4)
        }

        // N1 brightness normalization: pull the result's mean luma toward its
        // input frame's mean (clamped; strength-scaled) — kills the
        // base<->AI brightness jump that reads as a "patch flash".
        var gain: Float = 1
        if lumaNormStrength > 0 {
            let outLuma = lumaMean(r.rgba, bytesPerPixel: 4)
            stateLock.lock()
            let inLuma = inputLuma[r.view]
            stateLock.unlock()
            if let inLuma, inLuma > 1, outLuma > 1 {
                let full = min(max(inLuma / outLuma, 0.5), 2.0)
                gain = pow(full, lumaNormStrength)
            }
        }

        // 3-step crossfade; a newer result for the same view cancels older steps.
        stateLock.lock()
        fadeGen[r.view] = (fadeGen[r.view] ?? 0) + 1
        let gen = fadeGen[r.view]!
        stateLock.unlock()
        let steps: [(Float, Double)] = [(0.4, 0), (0.75, 0.12), (1.0, 0.24)]
        for (alpha, delay) in steps {
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                self.stateLock.lock()
                let current = self.fadeGen[r.view] ?? 0
                self.stateLock.unlock()
                guard current == gen else { return }
                guard let cmd = self.renderer.commandQueue.makeCommandBuffer() else { return }
                self.renderer.updateTile(index: r.view, srcTexture: tex, cmd: cmd,
                                         blendAlpha: alpha, lumaGain: gain)
                cmd.commit()
            }
        }
    }

    /// Scene clock mirrors LKGApp's pause-aware time.
    public var sceneTimeProvider: (() -> Float)?
    private func sceneTime() -> Float { sceneTimeProvider?() ?? Float(CACurrentMediaTime()) }

    public var statusLine: String {
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
