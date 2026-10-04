import Foundation
import Metal
import MetalKit
import QuartzCore
import LKGQuilt

/// Signal handlers can't capture context — keep a global for cleanup
/// (same pattern as lkg-ai-demo's main.swift; SIGTERM would orphan the
/// Python workers otherwise).
private var gStudioModel: StudioModel?

enum AudioSourceKind: String, CaseIterable, Identifiable {
    case music, mic, none
    var id: String { rawValue }
    var label: String {
        switch self {
        case .music: return "Music"
        case .mic: return "Mic"
        case .none: return "Off"
        }
    }
}

/// View model for LKG Studio. Owns the single live QuiltRenderer (only one
/// per process — a second instance silently splits render targets and shows
/// black), the AI pipeline (scene/client/coordinator), audio linkage, and
/// the device window. All @Published mutations happen on the main thread
/// (MTKView delegates, main-runloop timers, explicit main-queue hops).
final class StudioModel: ObservableObject {
    static let defaultPrompt = "synthwave retrowave landscape, bright pastel pink and cyan palette, golden sunset lighting, neon grid valley, starry sky, clean bold shapes, masterpiece"

    private let defaults = UserDefaults.standard
    private var loaded = false

    // MARK: - Persisted configuration (S3)

    @Published var prompt = StudioModel.defaultPrompt
    @Published var recentPrompts: [String] = []
    @Published var strength: Float = 0.6
    @Published var renderSize = 384
    @Published var workers = 2
    @Published var grid = "7x8"
    @Published var audioSource: AudioSourceKind = .music {
        didSet { if loaded, audioSource != oldValue { applyAudioSource(); persistConfig() } }
    }
    @Published var lyricPrompt = true { didSet { if loaded { persistConfig() } } }
    @Published var beatGlow: Float = 0.25 { didSet { if loaded { persistConfig() } } }
    /// Permanent raw-layer blend floor (CLI --alt-mix equivalent).
    @Published var altMix: Float = 0 {
        didSet { coordinator?.baseAltMix = altMix; if loaded { persistConfig() } }
    }

    // MARK: - Runtime status

    @Published private(set) var fps: Double = 0
    @Published private(set) var tilesPerSec: Double = 0
    @Published private(set) var tileHz: Double = 0
    @Published private(set) var workersReady = 0
    @Published private(set) var pipelineLoading = false
    @Published private(set) var nowPlaying = ""
    @Published private(set) var lyricLine = ""
    @Published private(set) var playing = false
    @Published private(set) var bpm = 0
    @Published private(set) var deviceAvailable = true
    @Published private(set) var lastError = ""

    @Published var deviceFullscreen = false { didSet { applyDeviceFullscreen() } }
    @Published var testPattern = false { didSet { deviceWindow?.testPattern = testPattern } }
    @Published var bypassLenticular = false { didSet { deviceWindow?.bypassLenticular = bypassLenticular } }

    // MARK: - Pipeline (main-thread access only)

    private(set) var renderer: QuiltRenderer?
    private var calibration: Calibration = .lkgGoFallback
    private var scene: AIBlockCityScene?
    private(set) var client: DiffusionClient?
    private var coordinator: AIQuiltCoordinator?
    private(set) var deviceWindow: LKGDeviceWindowController?

    private let music = MusicBridge()
    private let analyzer = AudioAnalyzer()
    private let lyrics = LyricsService()
    private var musicActive = false
    private var micActive = false

    private var startTime = CACurrentMediaTime()
    private var started = false
    private var statsTimer: Timer?
    private var previewFrames = 0
    private var previewLastReport = CACurrentMediaTime()

    // What the running pipeline was built with (dirty-check for the Apply button).
    private var appliedStrength: Float = 0.6
    private var appliedRenderSize = 384
    private var appliedWorkers = 2
    private var appliedGrid = "7x8"

    private let pythonPath = NSString(string: "~/Documents/kimi/workspace/streamdiffusion-mac/.venv/bin/python").expandingTildeInPath
    private let scriptPath: String
    private let modelsDir: String

    var currentTime: Float { Float(CACurrentMediaTime() - startTime) }
    var viewCount: Int { renderer?.spec.viewCount ?? 56 }
    var renderConfigDirty: Bool {
        strength != appliedStrength || renderSize != appliedRenderSize
            || workers != appliedWorkers || grid != appliedGrid
    }

    init() {
        // default paths relative to the package root (same trick as main.swift)
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
        scriptPath = repoRoot + "/python/quilt_diffusion_worker.py"
        modelsDir = repoRoot + "/models"
        loadPersisted()
    }

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true
        if let fetched = Calibration.fetchFromBridge() {
            calibration = fetched
            print("calibration fetched from Looking Glass Bridge: \(fetched.serial)")
        } else {
            print("Bridge unavailable — using built-in fallback calibration")
        }
        rebuildPipeline()
        lyrics.attach(music: music) { [weak self] line in self?.lyricLineChanged(line) }
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.refreshStats()
        }
        gStudioModel = self
        signal(SIGTERM) { _ in gStudioModel?.shutdown(); exit(0) }
        signal(SIGINT) { _ in gStudioModel?.shutdown(); exit(0) }
    }

    func shutdown() {
        persistConfig()
        statsTimer?.invalidate()
        lyrics.stop()
        music.stop()
        analyzer.stop()
        client?.stopAll()
    }

    // MARK: - Pipeline build / rebuild (worker respawn, S1.2)

    private func rebuildPipeline() {
        pipelineLoading = true
        workersReady = 0
        lastError = ""
        let spec: QuiltSpec = grid == "11x6" ? .lkgGo : .lkgGo56
        do {
            // Tear down the old pipeline first — one live QuiltRenderer at a time.
            let oldClient = client
            coordinator = nil
            scene = nil
            client = nil
            oldClient?.stopAll()

            let r = try QuiltRenderer(spec: spec)
            renderer = r
            deviceWindow?.renderer = r
            let s = try AIBlockCityScene(renderer: r, viewSize: renderSize)
            scene = s
            let c = DiffusionClient(workerCount: workers, prompt: prompt,
                                    renderSize: renderSize, strength: strength,
                                    pythonPath: pythonPath, scriptPath: scriptPath,
                                    coremlDir: modelsDir)
            client = c
            let coord = AIQuiltCoordinator(scene: s, renderer: r, client: c)
            coord.sceneTimeProvider = { [weak self] in self?.currentTime ?? 0 }
            coord.baseAltMix = altMix
            coordinator = coord
            appliedStrength = strength
            appliedRenderSize = renderSize
            appliedWorkers = workers
            appliedGrid = grid
            applyAudioSource()

            if deviceWindow == nil {
                let dw = LKGDeviceWindowController(renderer: r, calibration: calibration)
                wireDeviceWindow(dw)
                deviceWindow = dw
            }

            c.start()
            coord.start()
            DispatchQueue.global().async { [weak self, weak c] in
                let ok = c?.waitUntilReady(timeout: 300) ?? false
                DispatchQueue.main.async {
                    guard let self, let c, self.client === c else { return }
                    self.pipelineLoading = false
                    if !ok { self.lastError = "diffusion workers failed to become ready" }
                }
            }
        } catch {
            pipelineLoading = false
            lastError = "pipeline init failed: \(error.localizedDescription)"
        }
    }

    /// Apply strength/renderSize/workers/grid: tears down the worker pool and
    /// respawns it (~10 s CoreML model load; UI shows a loading overlay).
    func applyRenderConfig() {
        guard !pipelineLoading, renderConfigDirty else { return }
        persistConfig()
        rebuildPipeline()
    }

    private func wireDeviceWindow(_ dw: LKGDeviceWindowController) {
        dw.onRenderQuilt = { [weak self] cmd, t in self?.encodeSceneFrame(cmd: cmd, time: t) }
        dw.timeProvider = { [weak self] in self?.currentTime ?? 0 }
        dw.altMixSource = { [weak self] in self?.coordinator?.altMixForDisplay }
        dw.mainGainProvider = { [weak self] in self?.displayGain() ?? 1 }
        dw.testPattern = testPattern
        dw.bypassLenticular = bypassLenticular
        dw.onFPS = { [weak self] f in self?.fps = f }
    }

    /// Scene encode shared by the device window and (when the device window is
    /// hidden) the preview. Test pattern fills the quilt while workers load,
    /// so a fresh renderer never displays undefined texture content.
    private func encodeSceneFrame(cmd: MTLCommandBuffer, time: Float) {
        guard let coordinator, !pipelineLoading else {
            renderer?.encodeTestPattern(cmd: cmd)
            return
        }
        coordinator.onFrame(cmd: cmd, time: time)
    }

    /// Display-level beat pulse on the AI layer only (CLI --beat-glow equivalent).
    private func displayGain() -> Float {
        let beat: Float
        switch audioSource {
        case .music: beat = music.features.w
        case .mic: beat = analyzer.current.beat
        case .none: beat = 0
        }
        return 1 + beatGlow * beat
    }

    // MARK: - Preview frame (30 Hz MTKView on the main screen)

    func drawPreviewFrame(_ view: MTKView) {
        guard let renderer,
              let cmd = renderer.commandQueue.makeCommandBuffer(),
              let rpd = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable else { return }
        let deviceShowing = deviceWindow?.isShowing == true
        // Same split as LKGApp: the device driver owns scene encoding when present.
        if !deviceShowing {
            encodeSceneFrame(cmd: cmd, time: currentTime)
        }
        let destSize = SIMD2(Float(view.drawableSize.width), Float(view.drawableSize.height))
        // preview hard-switches to the alt quilt at mix >= 0.5 (LKGApp behavior)
        let altMixValue = coordinator?.altMixForDisplay
        let src = (altMixValue != nil && altMixValue!.1 >= 0.5) ? altMixValue!.0 : nil
        renderer.encodeTonemappedBlit(cmd: cmd, pass: rpd, drawableSize: destSize, source: src)
        cmd.present(drawable)
        cmd.commit()
        if !deviceShowing {
            previewFrames += 1
            let now = CACurrentMediaTime()
            if now - previewLastReport >= 1 {
                fps = Double(previewFrames) / (now - previewLastReport)
                previewFrames = 0
                previewLastReport = now
            }
        }
    }

    // MARK: - Device fullscreen (S2.2)

    private func applyDeviceFullscreen() {
        if deviceFullscreen {
            guard let dw = deviceWindow, dw.show() else {
                deviceAvailable = LKGDeviceWindowController.deviceScreen != nil
                lastError = "no LKG display found — preview only"
                deviceFullscreen = false
                return
            }
        } else {
            deviceWindow?.hide()
        }
    }

    // MARK: - Prompt / lyric modulation (S1.2, CLI --lyric-prompt equivalent)

    func applyPrompt() {
        let p = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty else { return }
        prompt = p
        recentPrompts.removeAll { $0 == p }
        recentPrompts.insert(p, at: 0)
        if recentPrompts.count > 10 { recentPrompts.removeLast() }
        persistConfig()
        client?.setPrompt(p)
    }

    /// Lyric line change -> hot prompt modulation, snapped to the next beat
    /// boundary when one is near (identical logic to lkg-ai-demo main.swift).
    private func lyricLineChanged(_ line: String) {
        lyricLine = line
        guard lyricPrompt else { return }
        let composed = prompt + ", " + String(line.prefix(60))
        let apply = { [weak self] in
            self?.client?.setPrompt(composed)
            print("[lyric-prompt] “\(line.prefix(60))”")
        }
        if let bc = music.beatClock {
            let toNextBeat = (1 - (bc.phase - bc.phase.rounded(.down))) * bc.beatLen
            if toNextBeat > 0.1, toNextBeat < 1.5 {
                DispatchQueue.global().asyncAfter(deadline: .now() + toNextBeat) { apply() }
                return
            }
        }
        apply()
    }

    // MARK: - Audio source

    private func applyAudioSource() {
        switch audioSource {
        case .music:
            if !musicActive { music.start(); musicActive = true }
            if micActive { analyzer.stop(); micActive = false }
            scene?.audioProvider = { [weak self] in self?.music.features ?? .zero }
            coordinator?.beatClockProvider = { [weak self] in self?.music.beatClock }
        case .mic:
            if musicActive { music.stop(); musicActive = false }
            if !micActive { analyzer.start(); micActive = true }
            scene?.audioProvider = { [weak self] in
                guard let self else { return .zero }
                let f = self.analyzer.current
                return SIMD4(f.bass, f.mid, f.treble, f.beat)
            }
            coordinator?.beatClockProvider = nil
        case .none:
            if musicActive { music.stop(); musicActive = false }
            if micActive { analyzer.stop(); micActive = false }
            scene?.audioProvider = nil
            coordinator?.beatClockProvider = nil
        }
    }

    // MARK: - Transport (S1.3)

    func togglePlayPause() { music.togglePlayPause() }
    func nextTrack() { music.nextTrack() }
    func previousTrack() { music.previousTrack() }

    // MARK: - Stats (1 Hz)

    private func refreshStats() {
        tilesPerSec = client?.resultsPerSec ?? 0
        tileHz = tilesPerSec / Double(max(viewCount, 1))
        workersReady = client?.readyWorkerCount ?? 0
        deviceAvailable = LKGDeviceWindowController.deviceScreen != nil
        if audioSource == .music {
            nowPlaying = music.line
            playing = music.playing
            bpm = music.bpm
            lyricLine = lyrics.currentLine
        } else {
            nowPlaying = ""
            lyricLine = ""
        }
    }

    // MARK: - Persistence (S3)

    private func loadPersisted() {
        let d = defaults
        if let p = d.string(forKey: "studio.prompt"), !p.isEmpty { prompt = p }
        if let r = d.stringArray(forKey: "studio.recentPrompts") { recentPrompts = r }
        if d.object(forKey: "studio.strength") != nil { strength = d.float(forKey: "studio.strength") }
        if d.object(forKey: "studio.renderSize") != nil { renderSize = d.integer(forKey: "studio.renderSize") }
        if d.object(forKey: "studio.workers") != nil { workers = max(1, d.integer(forKey: "studio.workers")) }
        if let g = d.string(forKey: "studio.grid"), g == "7x8" || g == "11x6" { grid = g }
        if let a = d.string(forKey: "studio.audioSource"), let k = AudioSourceKind(rawValue: a) { audioSource = k }
        if d.object(forKey: "studio.lyricPrompt") != nil { lyricPrompt = d.bool(forKey: "studio.lyricPrompt") }
        if d.object(forKey: "studio.beatGlow") != nil { beatGlow = d.float(forKey: "studio.beatGlow") }
        if d.object(forKey: "studio.altMix") != nil { altMix = d.float(forKey: "studio.altMix") }
        loaded = true
    }

    private func persistConfig() {
        guard loaded else { return }
        defaults.set(prompt, forKey: "studio.prompt")
        defaults.set(recentPrompts, forKey: "studio.recentPrompts")
        defaults.set(strength, forKey: "studio.strength")
        defaults.set(renderSize, forKey: "studio.renderSize")
        defaults.set(workers, forKey: "studio.workers")
        defaults.set(grid, forKey: "studio.grid")
        defaults.set(audioSource.rawValue, forKey: "studio.audioSource")
        defaults.set(lyricPrompt, forKey: "studio.lyricPrompt")
        defaults.set(beatGlow, forKey: "studio.beatGlow")
        defaults.set(altMix, forKey: "studio.altMix")
    }
}
