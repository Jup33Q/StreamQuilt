import Foundation
import AppKit
import Metal
import MetalKit
import QuartzCore
import StreamQuilt

/// Signal handlers can't capture context — keep a global for cleanup
/// (same pattern as sq-ai-demo's main.swift; SIGTERM would orphan the
/// Python workers otherwise).
private var gStreamQuiltModel: StreamQuiltModel?

enum AudioSourceKind: String, CaseIterable, Identifiable {
    case music, mic, system, none
    var id: String { rawValue }
    var label: String {
        switch self {
        case .music: return "Music"
        case .mic: return "Mic"
        case .system: return "System"
        case .none: return "Off"
        }
    }
}

/// View model for StreamQuilt. Owns the single live QuiltRenderer (only one
/// per process — a second instance silently splits render targets and shows
/// black), the AI pipeline (scene/client/coordinator), audio linkage, and
/// the device window. All @Published mutations happen on the main thread
/// (MTKView delegates, main-runloop timers, explicit main-queue hops).
final class StreamQuiltModel: ObservableObject {
    static let defaultPrompt = "synthwave retrowave landscape, vivid highly saturated pink and cyan palette, golden sunset lighting, neon grid valley, starry sky, clean bold shapes, masterpiece"

    private let defaults = UserDefaults.standard
    private var loaded = false

    // MARK: - Persisted configuration (S3)

    /// Initial worker prompt (used until the emotion engine's first compose).
    @Published var prompt = StreamQuiltModel.defaultPrompt
    @Published var strength: Float = 0.6
    @Published var renderSize = 384
    @Published var workers = 2
    @Published var grid = "7x8"
    @Published var audioSource: AudioSourceKind = .music {
        didSet { if loaded, audioSource != oldValue { applyAudioSource(); persistConfig() } }
    }
    @Published var lyricPrompt = true { didSet { if loaded { persistConfig() } } }
    @Published var beatGlow: Float = 0 { didSet { if loaded { persistConfig() } } }
    /// Display-level beat HUE pulse amplitude in turns (rhythm -> hue, not brightness).
    @Published var beatHue: Float = 0.06 { didSet { if loaded { persistConfig() } } }
    /// v5: display-level pitch->hue gain (pitchTurns straight into mainHue).
    @Published var pitchHue: Float = 1.0 { didSet { if loaded { persistConfig() } } }
    /// Permanent raw-layer blend floor (CLI --alt-mix equivalent).
    @Published var altMix: Float = 0 {
        didSet { coordinator?.baseAltMix = altMix; if loaded { persistConfig() } }
    }
    /// Parallax lyric overlay on the device (L2). Default on.
    @Published var lyricOverlay = true { didSet { if loaded { persistConfig() } } }

    // MARK: - Runtime status

    @Published private(set) var fps: Double = 0
    @Published private(set) var tilesPerSec: Double = 0
    @Published private(set) var tileHz: Double = 0
    @Published private(set) var workersReady = 0
    @Published private(set) var pipelineLoading = false
    @Published private(set) var nowPlaying = ""
    @Published private(set) var lyricLine = ""
    /// In-line progress 0...1 from the lyric line window (L2 overlay / UI bar).
    @Published private(set) var lineProgress: Double = 0
    @Published private(set) var playing = false
    @Published private(set) var bpm = 0
    @Published private(set) var deviceAvailable = true
    @Published private(set) var lastError = ""
    /// Effective prompt most recently pushed to the workers (engine-composed
    /// or manual) — live readout for the UI.
    @Published private(set) var livePrompt = ""
    /// 情感引擎当前判定（emotion id · theme_en），供 UI 展示。
    @Published private(set) var emotionLabel = ""

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
    private let sysAudio = SystemAudioAnalyzer()
    private let groove = GrooveEnvelope()   // v5: slowEnergy + kickEnv scene uniforms
    private let lyrics = LyricsService()
    /// 情感引擎（laya 本地决策模型：整曲主题 top-5 权重池 + 逐行情感滞后切换）。
    private let themeEngine = TrackThemeEngine()
    private var layaClient: LayaClient?
    private var musicActive = false
    private var micActive = false
    private var sysActive = false

    private var startTime = CACurrentMediaTime()
    private var started = false
    private var statsTimer: Timer?
    private var overlayTimer: Timer?
    /// L2 parallax lyric overlay: text+progress fed by a 0.25s timer, sampled
    /// by the device interlace via `LKGDeviceWindowController.overlayProvider`.
    private var overlayRenderer: LyricOverlayRenderer?
    private var keyMonitor: Any?
    private var previewFrames = 0
    private var previewLastReport = CACurrentMediaTime()

    // What the running pipeline was built with (dirty-check for the Apply button).
    private var appliedStrength: Float = 0.6
    private var appliedRenderSize = 384
    private var appliedWorkers = 2
    private var appliedGrid = "7x8"

    private let pythonPath = NSString(string: "~/Documents/kimi/workspace/streamdiffusion-mac/.venv/bin/python").expandingTildeInPath
    private let layaPythonPath = NSString(string: "~/Documents/kimi/workspace/laya-coreml/.venv/bin/python").expandingTildeInPath
    private let layaModelsDir = NSString(string: "~/Documents/kimi/workspace/laya-coreml/models").expandingTildeInPath
    private let repoRootPath: String
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
        repoRootPath = repoRoot
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
        // 歌词服务只负责行跟踪（引擎 0.5s 轮询它并驱动 prompt/权重更新）
        lyrics.attach(music: music) { _ in }
        // laya sidecar（7-26s 模型加载，常驻进程；没 ready 时引擎走 hash 兜底）
        let lc = LayaClient(pythonPath: layaPythonPath,
                            scriptPath: repoRootPath + "/python/laya_emotion_worker.py",
                            trackModel: layaModelsDir + "/multilingual",
                            lineModel: layaModelsDir + "/multilingual-ane")
        lc.start()
        layaClient = lc
        themeEngine.brain = .laya
        themeEngine.laya = lc
        lc.onReady = { [weak themeEngine] in themeEngine?.layaReady() }
        themeEngine.onTheme = { [weak self] t in
            self?.scene?.themeBias = SIMD4(t.hueBias, t.crystalGain, t.columnGain, t.emberGain)
        }
        themeEngine.onFontSet = { [weak self] id in
            guard let self, let fs = LyricFontPool.byID(id) else { return }
            self.overlayRenderer?.applyFontSet(fs)
            print("[overlay] fontset -> \(id)")
        }
        themeEngine.onPrompt = { [weak self] p in
            guard let self, self.lyricPrompt else { return }
            self.livePrompt = p
            self.client?.setPrompt(p)
        }
        themeEngine.attach(music: music, lyrics: lyrics)
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.refreshStats()
        }
        // L2 overlay feed: line window from LyricsService + MusicBridge
        // position extrapolation; bar redraws at 4 Hz, text only on change.
        overlayRenderer = renderer.map { LyricOverlayRenderer(device: $0.device) }
        overlayTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.feedOverlay()
        }
        gStreamQuiltModel = self
        signal(SIGTERM) { _ in gStreamQuiltModel?.shutdown(); exit(0) }
        signal(SIGINT) { _ in gStreamQuiltModel?.shutdown(); exit(0) }
        // Hold-G raw-layer peek (CLI demo parity). Handled keys must return
        // nil or AppKit plays the "invalid input" beep; never steal keys from
        // a text field (the prompt editor) — the field editor is an NSTextView.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] ev in
            guard let self, !ev.modifierFlags.contains(.command) else { return ev }
            if let fr = NSApp.keyWindow?.firstResponder, fr is NSTextView { return ev }
            if ev.keyCode == 5 {   // G: raw-layer peek
                self.coordinator?.rawPeek = (ev.type == .keyDown)
                return nil
            }
            if ev.type == .keyDown {   // ,/. : lyric timing nudge (persisted per track)
                if ev.keyCode == 43 { self.lyrics.nudge(-0.5); return nil }
                if ev.keyCode == 47 { self.lyrics.nudge(+0.5); return nil }
            }
            return ev
        }
    }

    func shutdown() {
        persistConfig()
        statsTimer?.invalidate()
        overlayTimer?.invalidate()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        lyrics.stop()
        themeEngine.stop()
        layaClient?.stop()
        music.stop()
        analyzer.stop()
        sysAudio.stop()
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
            // re-apply the current emotion theme after a pipeline rebuild
            if !themeEngine.currentTheme.isEmpty {
                s.themeBias = SIMD4(themeEngine.currentHueBias, themeEngine.currentGains.x,
                                    themeEngine.currentGains.y, themeEngine.currentGains.z)
            }
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
        dw.mainGainProvider = { [weak self] in
            guard let self, self.beatGlow > 0 else { return 1 }
            return self.displayGain()
        }
        dw.mainHueProvider = { [weak self] in self?.displayHue() ?? 0 }
        dw.overlayProvider = { [weak self] in
            guard let self, self.lyricOverlay,
                  self.audioSource == .music || self.audioSource == .system, self.playing
            else { return nil }
            return self.overlayRenderer?.texture
        }
        dw.testPattern = testPattern
        dw.bypassLenticular = bypassLenticular
        dw.onFPS = { [weak self] f in self?.fps = f }
    }

    /// 0.25s feed for the lyric overlay + the UI line-progress bar. Line window
    /// from LRCLIB timestamps, coverage from MusicBridge position extrapolation.
    /// The overlay footer bar shows TRACK progress; the lyric line progress
    /// drives the karaoke coverage sweep. No lyrics / instrumental: the track
    /// title is shown instead (coverage 0).
    private func feedOverlay() {
        var title = ""
        var subtitle = ""
        if (audioSource == .music || audioSource == .system) && playing {
            let pos = music.position
            if let win = lyrics.currentLineWindow(at: pos) {
                title = win.text
                subtitle = music.line
            } else {
                title = music.line  // no lyrics / instrumental: track title
            }
        }
        lineProgress = 0  // karaoke coverage disabled (line-window sync drifts); UI bar idle
        guard lyricOverlay, !title.isEmpty,
              let ov = overlayRenderer, let size = deviceWindow?.drawableSize
        else { return }
        let trackProg = music.duration > 0 ? music.position / music.duration : 0
        ov.update(title: title, subtitle: subtitle,
                  progress: Float(min(max(trackProg, 0), 1)),
                  coverage: 1,   // interface kept; fixed fully-lit until sync improves
                  timecode: LyricOverlayRenderer.timecode(position: music.position,
                                                          duration: music.duration),
                  drawableSize: size)
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

    /// Display-level beat pulse on the AI layer only: rhythm reads as hue.
    private func beatForDisplay() -> Float {
        switch audioSource {
        case .music: return music.features.w
        case .mic: return analyzer.current.beat
        case .system: return sysAudio.current.beat
        case .none: return 0
        }
    }

    /// v5 音高锚定分层：音高显色走显示层（60Hz 相干，无扩散衰减）。
    private func pitchForDisplay() -> Float {
        switch audioSource {
        case .mic: return analyzer.current.pitchTurns
        case .system: return sysAudio.current.pitchTurns
        default: return 0
        }
    }

    private func displayHue() -> Float {
        let amp = beatHue * (audioSource == .music || audioSource == .system
                             ? (0.7 + 0.6 * themeEngine.effectiveEnergy) : 1)
        return amp * beatForDisplay() + pitchHue * pitchForDisplay()
    }

    /// Legacy brightness pulse (beatGlow > 0 only).
    private func displayGain() -> Float {
        return 1 + beatGlow * (audioSource == .music || audioSource == .system
                               ? (0.7 + 0.6 * themeEngine.effectiveEnergy) : 1) * beatForDisplay()
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

    /// Prompting is engine-driven: TrackThemeEngine.onPrompt (top-5 theme
    /// pool sampling + per-line emotion + lyric line + fixed quality tail)
    /// pushes to the workers, beat-snapped and 2s throttled. `prompt` only
    /// seeds the workers' initial style before the first engine compose.

    // MARK: - Audio source

    private func applyAudioSource() {
        switch audioSource {
        case .music:
            if !musicActive { music.start(); musicActive = true }
            if micActive { analyzer.stop(); micActive = false }
            if sysActive { sysAudio.stop(); sysActive = false }
            scene?.audioProvider = { [weak self] in
                guard let self else { return .zero }
                let f = self.music.features
                self.groove.push(bass: f.x, mid: f.y, beat: f.w)
                return f
            }
            scene?.pitchProvider = nil
            scene?.slowEnergyProvider = { [weak self] in self?.groove.slowEnergy ?? 0 }
            scene?.kickEnvProvider = { [weak self] in self?.groove.kick ?? 0 }
            scene?.accumEnergyProvider = { [weak self] in self?.groove.accum ?? 0 }
            coordinator?.beatClockProvider = { [weak self] in self?.music.beatClock }
        case .mic:
            if musicActive { music.stop(); musicActive = false }
            if sysActive { sysAudio.stop(); sysActive = false }
            if !micActive { analyzer.start(); micActive = true }
            scene?.audioProvider = { [weak self] in
                guard let self else { return .zero }
                let f = self.analyzer.current
                self.groove.push(bass: f.bass, mid: f.mid, beat: f.beat)
                return SIMD4(f.bass, f.mid, f.treble, f.beat)
            }
            scene?.pitchProvider = { [weak self] in self?.analyzer.current.pitchTurns ?? 0 }
            scene?.slowEnergyProvider = { [weak self] in self?.groove.slowEnergy ?? 0 }
            scene?.kickEnvProvider = { [weak self] in self?.groove.kick ?? 0 }
            scene?.accumEnergyProvider = { [weak self] in self?.groove.accum ?? 0 }
            coordinator?.beatClockProvider = nil
        case .system:
            // metadata (beat clock/lyrics/emotion) stays on Music.app; only the
            // audio FEATURES come from the real playback-output capture
            if !musicActive { music.start(); musicActive = true }
            if micActive { analyzer.stop(); micActive = false }
            if !sysActive { sysAudio.start(); sysActive = true }
            scene?.audioProvider = { [weak self] in
                guard let self else { return .zero }
                let f = self.sysAudio.current
                self.groove.push(bass: f.bass, mid: f.mid, beat: f.beat)
                return SIMD4(f.bass, f.mid, f.treble, f.beat)
            }
            scene?.pitchProvider = { [weak self] in self?.sysAudio.current.pitchTurns ?? 0 }
            scene?.slowEnergyProvider = { [weak self] in self?.groove.slowEnergy ?? 0 }
            scene?.kickEnvProvider = { [weak self] in self?.groove.kick ?? 0 }
            scene?.accumEnergyProvider = { [weak self] in self?.groove.accum ?? 0 }
            coordinator?.beatClockProvider = { [weak self] in self?.music.beatClock }
        case .none:
            if musicActive { music.stop(); musicActive = false }
            if micActive { analyzer.stop(); micActive = false }
            if sysActive { sysAudio.stop(); sysActive = false }
            scene?.audioProvider = nil
            scene?.pitchProvider = nil
            scene?.slowEnergyProvider = nil
            scene?.kickEnvProvider = nil
            scene?.accumEnergyProvider = nil
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
        if audioSource == .music || audioSource == .system {
            nowPlaying = music.line
            playing = music.playing
            bpm = music.bpm
            lyricLine = lyrics.currentLine
            emotionLabel = themeEngine.currentEmotionID.isEmpty ? ""
                : themeEngine.currentEmotionID
                  + (themeEngine.currentThemeZH.isEmpty ? "" : " · " + themeEngine.currentThemeZH)
                  + (themeEngine.currentSubjectZH.isEmpty ? "" : " · " + themeEngine.currentSubjectZH)
                  + (themeEngine.lineEmotionID.isEmpty ? "" : " → " + themeEngine.lineEmotionID)
        } else {
            nowPlaying = ""
            lyricLine = ""
            emotionLabel = ""
        }
    }

    // MARK: - Persistence (S3)

    private func loadPersisted() {
        let d = defaults
        if let p = d.string(forKey: "studio.prompt"), !p.isEmpty { prompt = p }
        if d.object(forKey: "studio.strength") != nil { strength = d.float(forKey: "studio.strength") }
        if d.object(forKey: "studio.renderSize") != nil { renderSize = d.integer(forKey: "studio.renderSize") }
        if d.object(forKey: "studio.workers") != nil { workers = max(1, d.integer(forKey: "studio.workers")) }
        if let g = d.string(forKey: "studio.grid"), g == "7x8" || g == "11x6" { grid = g }
        if let a = d.string(forKey: "studio.audioSource"), let k = AudioSourceKind(rawValue: a) { audioSource = k }
        if d.object(forKey: "studio.lyricPrompt") != nil { lyricPrompt = d.bool(forKey: "studio.lyricPrompt") }
        if d.object(forKey: "studio.beatGlow") != nil { beatGlow = d.float(forKey: "studio.beatGlow") }
        if d.object(forKey: "studio.beatHue") != nil { beatHue = d.float(forKey: "studio.beatHue") }
        if d.object(forKey: "studio.pitchHue") != nil { pitchHue = d.float(forKey: "studio.pitchHue") }
        if d.object(forKey: "studio.altMix") != nil { altMix = d.float(forKey: "studio.altMix") }
        if d.object(forKey: "studio.lyricOverlay") != nil { lyricOverlay = d.bool(forKey: "studio.lyricOverlay") }
        loaded = true
    }

    private func persistConfig() {
        guard loaded else { return }
        defaults.set(prompt, forKey: "studio.prompt")
        defaults.set(strength, forKey: "studio.strength")
        defaults.set(renderSize, forKey: "studio.renderSize")
        defaults.set(workers, forKey: "studio.workers")
        defaults.set(grid, forKey: "studio.grid")
        defaults.set(audioSource.rawValue, forKey: "studio.audioSource")
        defaults.set(lyricPrompt, forKey: "studio.lyricPrompt")
        defaults.set(beatGlow, forKey: "studio.beatGlow")
        defaults.set(beatHue, forKey: "studio.beatHue")
        defaults.set(pitchHue, forKey: "studio.pitchHue")
        defaults.set(altMix, forKey: "studio.altMix")
        defaults.set(lyricOverlay, forKey: "studio.lyricOverlay")
    }
}
