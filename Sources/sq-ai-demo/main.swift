// sq-ai-demo: real-time AI-stylized quilt on Looking Glass.
//
// Metal raymarches 66 views -> Python StreamDiffusion workers (CoreML img2img)
// stylize them concurrently -> results composite into the quilt -> lenticular
// interlace -> LKG at 60 Hz (AI tiles refresh asynchronously).
//
//   swift run -c release sq-ai-demo                                  # live
//   swift run -c release sq-ai-demo -- --workers 4 --strength 0.5
//   swift run -c release sq-ai-demo -- --dump ai-quilt.png           # offline

import Foundation
import CoreGraphics
import QuartzCore
import ImageIO
import StreamQuilt
import Metal

setvbuf(stdout, nil, _IONBF, 0)

// signal handlers can't capture context — keep globals for cleanup.
private var gDiffusionClient: DiffusionClient?
private var gLayaClient: LayaClient?
private var gSystemAudio: SystemAudioAnalyzer?

struct CLI {
    // N2: palette-locked prompt matching the synthwave scene (anti-flicker:
    // shrinks style/brightness variance between AI tiles and the base layer)
    var prompt = "synthwave retrowave landscape, vivid highly saturated pink and cyan palette, golden sunset lighting, neon grid valley, starry sky, clean bold shapes, masterpiece"
    var workers = 2
    // euler 修复后 strength 真实生效（1.0=修复前的全风格化）。0.6 = A/B 后选定：
    // 输出贴近输入构图/色调，epoch 间跳变最小；要更强风格化用 --strength 0.8~1.0
    var strength: Float = 0.6
    var renderSize = 512
    var dumpPath: String?
    var peekDumpPath: String?
    var overlayDumpPath: String?
    var titleLatinFont = "HelveticaNeue-CondensedBlack"  // poster title latin face
    var titleCJKFont = "PingFangSC-Semibold"             // poster title CJK cascade
    var fontSet = "auto"   // lyric overlay font set id, or "auto" = laya per-track pick
    var overlayText = ""   // --overlay-dump test line (empty = built-in sample)
    var time: Float = 1.2
    var audioOverride: SIMD4<Float>?   // --audio bass,mid,treble,beat (offline ablation)
    var benchBase = 0                  // --bench-base N: GPU-time N base-scene encodes, print mean ms
    var showPreview = true
    var renderScale: Float = 1.0
    var batch = 1
    var feedback: Float = 0.3   // latent 时序粘合（防频闪）
    var lumaNorm: Float = 1.0   // N1 tile 明度归一强度（0=关，1=输出均值拉齐输入均值）
    var order = "wave"          // N3 更新顺序：wave 蛇形扫描波 | center 中心优先
    var beatEpoch = true        // N4 epoch 边界对齐节拍（每 2 拍一个 epoch）
    var altMix: Float = 0       // 常驻原始层混合比（0-1；G 键按住时平滑推到 1）
    var beatGlow: Float = 0     // 旧版显示级节拍亮度脉冲幅度（已让位给 beatHue）
    var beatHue: Float = 0.06   // 显示级节拍色相脉冲幅度（turns；interlace 内主 quilt 色相旋转）
    var pitchHue: Float = 1.0   // v5: 显示级音高→色相增益（pitchTurns 直接转入 mainHue，无扩散衰减）
    var overlayShift: Float = 0.10  // 歌词浮层视差全扫幅度（屏宽分数，默认已加强）
    var lyricPrompt = true      // L3 歌词行热调制 prompt（--no-lyric-prompt 关）
    var emotionEngine = true    // 情感引擎：曲目主题/情感分类 → prompt+场景 theme（仅 music 源）
    var themeBrain = "laya"     // laya（本地 CoreML 决策模型，默认）| ollama（自由文本）
    var layaPython = NSString(string: "~/Documents/kimi/workspace/laya-coreml/.venv/bin/python").expandingTildeInPath
    var layaModels = NSString(string: "~/Documents/kimi/workspace/laya-coreml/models").expandingTildeInPath
    var ollamaURL = "http://127.0.0.1:11434"
    var ollamaModel = "gemma4:e4b-mlx"
    var grid = "7x8"   // AI 路径默认 7x8=56（低算力布局）；11x6 为全规格 66
    var units = ""     // 逗号分隔，如 "all,cpu_and_gpu"；空 = 异构默认
    var audioSource = "music"   // music（Apple Music 节拍钟，默认）| mic（环境声 FFT）| system（SCK 播放输出捕获+音高）| none
    var python = NSString(string: "~/Documents/kimi/workspace/streamdiffusion-mac/.venv/bin/python").expandingTildeInPath
    var script = ""
    var models = ""
}

var cli = CLI()
// default paths relative to the package root (cwd under `swift run`)
let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
cli.script = repoRoot + "/python/quilt_diffusion_worker.py"
cli.models = repoRoot + "/models"

var args = CommandLine.arguments
var i = 1
while i < args.count {
    switch args[i] {
    case "--prompt": cli.prompt = args[i + 1]; i += 1
    case "--workers": cli.workers = Int(args[i + 1]) ?? 2; i += 1
    case "--strength": cli.strength = Float(args[i + 1]) ?? 0.45; i += 1
    case "--render-size": cli.renderSize = Int(args[i + 1]) ?? 512; i += 1
    case "--dump": cli.dumpPath = args[i + 1]; i += 1
    case "--peek-dump": cli.peekDumpPath = args[i + 1]; i += 1
    case "--overlay-dump": cli.overlayDumpPath = args[i + 1]; i += 1
    case "--title-latin-font": cli.titleLatinFont = args[i + 1]; i += 1
    case "--title-cjk-font": cli.titleCJKFont = args[i + 1]; i += 1
    case "--font-set": cli.fontSet = args[i + 1]; i += 1
    case "--overlay-text": cli.overlayText = args[i + 1]; i += 1
    case "--time": cli.time = Float(args[i + 1]) ?? 1.2; i += 1
    case "--bench-base": cli.benchBase = Int(args[i + 1]) ?? 0; i += 1
    case "--audio":
        let parts = args[i + 1].split(separator: ",").compactMap { Float($0) }
        if parts.count == 4 { cli.audioOverride = SIMD4(parts[0], parts[1], parts[2], parts[3]) }
        i += 1
    case "--no-preview": cli.showPreview = false
    case "--half": cli.renderScale = 0.5
    case "--batch": cli.batch = Int(args[i + 1]) ?? 1; i += 1
    case "--feedback": cli.feedback = Float(args[i + 1]) ?? 0.3; i += 1
    case "--luma-norm": cli.lumaNorm = Float(args[i + 1]) ?? 1.0; i += 1
    case "--order": cli.order = args[i + 1]; i += 1
    case "--no-beat-epoch": cli.beatEpoch = false
    case "--alt-mix": cli.altMix = Float(args[i + 1]) ?? 0; i += 1
    case "--beat-glow": cli.beatGlow = Float(args[i + 1]) ?? 0.25; i += 1
    case "--beat-hue": cli.beatHue = Float(args[i + 1]) ?? 0.06; i += 1
    case "--pitch-hue": cli.pitchHue = Float(args[i + 1]) ?? 1.0; i += 1
    case "--overlay-shift": cli.overlayShift = Float(args[i + 1]) ?? 0.10; i += 1
    case "--lyric-prompt": cli.lyricPrompt = true
    case "--no-lyric-prompt": cli.lyricPrompt = false
    case "--emotion-engine": cli.emotionEngine = true
    case "--no-emotion-engine": cli.emotionEngine = false
    case "--theme-brain": cli.themeBrain = args[i + 1]; i += 1
    case "--laya-python": cli.layaPython = args[i + 1]; i += 1
    case "--laya-models": cli.layaModels = args[i + 1]; i += 1
    case "--ollama": cli.ollamaURL = args[i + 1]; i += 1
    case "--ollama-model": cli.ollamaModel = args[i + 1]; i += 1
    case "--grid": cli.grid = args[i + 1]; i += 1
    case "--units": cli.units = args[i + 1]; i += 1
    case "--audio-source": cli.audioSource = args[i + 1]; i += 1
    case "--python": cli.python = args[i + 1]; i += 1
    case "--script": cli.script = args[i + 1]; i += 1
    case "--models": cli.models = args[i + 1]; i += 1
    default: break
    }
    i += 1
}

func makeClient() -> DiffusionClient {
    DiffusionClient(workerCount: cli.workers, prompt: cli.prompt,
                    renderSize: cli.renderSize, strength: cli.strength,
                    pythonPath: cli.python, scriptPath: cli.script, coremlDir: cli.models,
                    batch: cli.batch, feedback: cli.feedback,
                    units: cli.units.isEmpty ? nil : cli.units.split(separator: ",").map(String.init))
}

/// Offline audio ablation (--audio b,m,t,bt): fixed features + derived phrase
/// energy so the v5 slow-geometry paths (melt range, blob presence, camera
/// travel) are exercised offline too. kickEnv stays 0 (no beat edges offline).
/// --audio 0,0,0,0 (or no flag) keeps every new uniform at 0: bitwise-neutral.
func applyAudioOverride(_ scene: AIBlockCityScene, _ a: SIMD4<Float>) {
    scene.audioProvider = { a }
    // v5: phrase energy derived so offline ablation exercises slow-geometry paths
    let slow = min(1, max(0, a.x * 0.75 + a.y * 0.5))
    scene.slowEnergyProvider = { slow }
    scene.kickEnvProvider = { 0 }
    // accumulated energy simulated as ~20s of this level, so the cumulative
    // terrain sculpture + palette drift show up offline too
    scene.accumEnergyProvider = { slow * 20 }
}

func selectSpec() -> QuiltSpec {
    cli.grid == "11x6" ? .lkgGo : .lkgGo56
}

do {
    if let peekPath = cli.peekDumpPath {
        let renderer = try QuiltRenderer(spec: selectSpec(), renderScale: cli.renderScale)
        let scene = try AIBlockCityScene(renderer: renderer, viewSize: cli.renderSize)
        if let a = cli.audioOverride { applyAudioOverride(scene, a) }
        // Offline peek check: raw raymarch into the alt quilt, interlaced from it.
        renderer.makeAltQuiltTarget()
        let calibration = Calibration.fetchFromBridge() ?? .lkgGoFallback
        renderer.saveLenticularPNG(to: peekPath, calibration: calibration,
                                   source: renderer.altQuiltTexture) { cmd in
            scene.encodeBase(cmd: cmd, time: cli.time, into: renderer.altQuiltTexture)
        }
        renderer.saveQuiltPNG(to: peekPath.replacingOccurrences(of: ".png", with: "-quilt.png"),
                              source: renderer.altQuiltTexture) { _ in }
        exit(0)
    }

    if let ovPath = cli.overlayDumpPath {
        // Offline lyric-overlay check: interlaced frame with a test overlay so
        // text direction (CGContext Y flip) and per-view parallax can be
        // eyeballed without the device or Music playing.
        let renderer = try QuiltRenderer(spec: selectSpec(), renderScale: cli.renderScale)
        let scene = try AIBlockCityScene(renderer: renderer, viewSize: cli.renderSize)
        if let a = cli.audioOverride { applyAudioOverride(scene, a) }
        let calibration = Calibration.fetchFromBridge() ?? .lkgGoFallback
        let ov = LyricOverlayRenderer(device: renderer.device)
        ov.titleLatinFontName = cli.titleLatinFont
        ov.titleCJKFontName = cli.titleCJKFont
        if cli.fontSet != "auto", let fs = LyricFontPool.byID(cli.fontSet) {
            ov.applyFontSet(fs)
        }
        ov.update(title: cli.overlayText.isEmpty ? "夜空中最亮的星 The brightest star" : cli.overlayText,
                  subtitle: "StreamQuilt — Test Track",
                  progress: 0.5, coverage: 0.65, timecode: "1:23 / 2:46",
                  drawableSize: CGSize(width: CGFloat(calibration.screenW),
                                       height: CGFloat(calibration.screenH)))
        renderer.saveLenticularPNG(to: ovPath, calibration: calibration,
                                   overlay: ov.texture, overlayShift: cli.overlayShift) { cmd in
            scene.encodeBase(cmd: cmd, time: cli.time)
        }
        // raw overlay texture for direction/typography inspection
        if let tex = ov.texture {
            let w = tex.width, h = tex.height
            var data = [UInt8](repeating: 0, count: w * h * 4)
            tex.getBytes(&data, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
            let cs = CGColorSpace(name: CGColorSpace.sRGB)!
            let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                                    | CGBitmapInfo.byteOrder32Big.rawValue)
            if let c = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8,
                                 bytesPerRow: w * 4, space: cs, bitmapInfo: info.rawValue),
               let img = c.makeImage(),
               let dest = CGImageDestinationCreateWithURL(
                    URL(fileURLWithPath: ovPath.replacingOccurrences(of: ".png", with: "-overlay.png"))
                    as CFURL, "public.png" as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, img, nil)
                CGImageDestinationFinalize(dest)
            }
        }
        exit(0)
    }

    if cli.benchBase > 0 {
        // Offline GPU timing for the base-scene raymarch (split command
        // buffers like LKGApp does; grid via --grid, default 7x8).
        let renderer = try QuiltRenderer(spec: selectSpec(), renderScale: cli.renderScale)
        let scene = try AIBlockCityScene(renderer: renderer, viewSize: cli.renderSize)
        if let a = cli.audioOverride { applyAudioOverride(scene, a) }
        renderer.makeAltQuiltTarget()
        // warmup (shader/pipeline first-use cost stays out of the mean)
        for _ in 0..<3 {
            guard let cmd = renderer.commandQueue.makeCommandBuffer() else { continue }
            scene.encodeBase(cmd: cmd, time: cli.time, into: renderer.altQuiltTexture)
            cmd.commit()
            cmd.waitUntilCompleted()
        }
        var totalMs = 0.0
        let t0 = CACurrentMediaTime()
        for _ in 0..<cli.benchBase {
            guard let cmd = renderer.commandQueue.makeCommandBuffer() else { continue }
            scene.encodeBase(cmd: cmd, time: cli.time, into: renderer.altQuiltTexture)
            cmd.commit()
            cmd.waitUntilCompleted()   // serialize: GPU timestamps stay per-buffer
            totalMs += (cmd.gpuEndTime - cmd.gpuStartTime) * 1000
        }
        let wallMs = (CACurrentMediaTime() - t0) * 1000 / Double(cli.benchBase)
        print(String(format: "base scene: %.2f ms GPU (%.2f ms wall) avg over %d frames (grid %@, time %.2f)",
                     totalMs / Double(cli.benchBase), wallMs, cli.benchBase, cli.grid, cli.time))
        exit(0)
    }

    if let dumpPath = cli.dumpPath {
        let renderer = try QuiltRenderer(spec: selectSpec(), renderScale: cli.renderScale)
        let scene = try AIBlockCityScene(renderer: renderer, viewSize: cli.renderSize)
        if let a = cli.audioOverride { applyAudioOverride(scene, a) }
        // Offline: render base, diffuse all views synchronously, save quilt PNG.
        let client = makeClient()
        client.start()
        print("waiting for worker (first init ~10s)...")
        guard client.waitUntilReady(timeout: 120) else {
            print("worker failed to become ready"); exit(1)
        }
        if let cmd = renderer.commandQueue.makeCommandBuffer() {
            scene.encodeBase(cmd: cmd, time: cli.time)
            cmd.commit(); cmd.waitUntilCompleted()
        }
        let t0 = Date()
        for v in 0..<renderer.spec.viewCount {
            guard let cmd = renderer.commandQueue.makeCommandBuffer() else { continue }
            scene.encodeView(cmd: cmd, viewIndex: v, stagingIndex: 0, time: cli.time)
            scene.encodeReadback(cmd: cmd, stagingIndex: 0)
            cmd.commit(); cmd.waitUntilCompleted()

            let vs = scene.viewSize
            let src = scene.readbackBytes(stagingIndex: 0).bindMemory(to: UInt8.self)
            var rgb = Data(count: vs * vs * 3)
            rgb.withUnsafeMutableBytes { out in
                let o = out.baseAddress!.assumingMemoryBound(to: UInt8.self)
                for px in 0..<(vs * vs) {
                    o[px * 3] = src[px * 4]
                    o[px * 3 + 1] = src[px * 4 + 1]
                    o[px * 3 + 2] = src[px * 4 + 2]
                }
            }
            guard let r = client.processSync(view: v, rgb: rgb, width: vs, height: vs) else {
                print("view \(v): worker timeout, skipped"); continue
            }
            // N1: same brightness normalization as the live coordinator
            var gain: Float = 1
            if cli.lumaNorm > 0 {
                let inLuma = lumaMean(rgb, bytesPerPixel: 3)
                let outLuma = lumaMean(r.rgba, bytesPerPixel: 4)
                if inLuma > 1, outLuma > 1 {
                    gain = pow(min(max(inLuma / outLuma, 0.5), 2.0), cli.lumaNorm)
                }
            }
            // apply result tile
            if let cmd2 = renderer.commandQueue.makeCommandBuffer() {
                // reuse coordinator-style apply inline
                let d = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: .rgba8Unorm, width: r.width, height: r.height, mipmapped: false)
                d.storageMode = .shared; d.usage = .shaderRead
                if let tex = renderer.device.makeTexture(descriptor: d) {
                    r.rgba.withUnsafeBytes { ptr in
                        tex.replace(region: MTLRegionMake2D(0, 0, r.width, r.height),
                                    mipmapLevel: 0, withBytes: ptr.baseAddress!,
                                    bytesPerRow: r.width * 4)
                    }
                    renderer.updateTile(index: r.view, srcTexture: tex, cmd: cmd2, lumaGain: gain)
                }
                cmd2.commit()
            }
            if v % 11 == 10 { print("  row done (\(v + 1)/\(renderer.spec.viewCount))") }
        }
        cmdWait(renderer)
        print("all views diffused in \(String(format: "%.1f", Date().timeIntervalSince(t0)))s")
        renderer.saveQuiltPNG(to: dumpPath) { _ in }
        client.stopAll()
        exit(0)
    }

    // Live mode — the scene MUST be built on app.renderer: LKGApp owns its own
    // QuiltRenderer (displayed texture), a second instance would silently split
    // render targets and show black.
    let app = try LKGApp(spec: selectSpec(), renderScale: cli.renderScale)
    app.showPreview = cli.showPreview
    let scene = try AIBlockCityScene(renderer: app.renderer, viewSize: cli.renderSize)
    let client = makeClient()
    let coordinator = AIQuiltCoordinator(scene: scene, renderer: app.renderer, client: client)
    coordinator.sceneTimeProvider = { app.currentTime() }
    coordinator.lumaNormStrength = cli.lumaNorm
    coordinator.orderMode = cli.order == "center" ? .center : .wave
    coordinator.baseAltMix = cli.altMix

    // audio-reactive: Apple Music beat clock (default), mic FFT, or real
    // playback-output capture (--audio-source music|mic|system).
    // Metadata (Now Playing/BPM/beat-epoch/lyrics/emotion hooks) is decoupled
    // from the audio FEATURE source: it runs in both music and system modes —
    // only scene.audioProvider/pitchProvider differ.
    let music = MusicBridge()
    let analyzer = AudioAnalyzer()
    let sysAudio = SystemAudioAnalyzer()
    let groove = GrooveEnvelope()   // v5: slowEnergy + kickEnv scene uniforms
    let lyrics = LyricsService()
    let themeEngine = TrackThemeEngine()
    let metadataActive = (cli.audioSource == "music" || cli.audioSource == "system")
    if metadataActive {
        music.start()
        // N4: epoch boundaries aligned to every 2nd beat
        if cli.beatEpoch {
            coordinator.beatClockProvider = { music.beatClock }
        }
        // 情感引擎：曲目主题分类 → 场景 theme uniform + prompt 中段 + top-5
        // 主题池权重采样；失败/超时时 trackName hash 兜底，不阻塞主流程
        if cli.emotionEngine {
            themeEngine.brain = cli.themeBrain == "ollama" ? .ollama : .laya
            switch themeEngine.brain {
            case .ollama:
                themeEngine.ollama = OllamaClient(base: cli.ollamaURL, model: cli.ollamaModel)
            case .laya:
                let lc = LayaClient(pythonPath: cli.layaPython,
                                    scriptPath: repoRoot + "/python/laya_emotion_worker.py",
                                    trackModel: cli.layaModels + "/multilingual",
                                    lineModel: cli.layaModels + "/multilingual-ane")
                lc.start()
                themeEngine.laya = lc
                lc.onReady = { [weak themeEngine] in themeEngine?.layaReady() }
                gLayaClient = lc
            }
            themeEngine.onTheme = { t in
                scene.themeBias = SIMD4(t.hueBias, t.crystalGain, t.columnGain, t.emberGain)
            }
            themeEngine.attach(music: music, lyrics: lyrics)
            // 引擎驱动的 prompt：主题池权重采样 + 行情感 + 歌词行 + 固定质量尾，
            // 引擎内部做 2s 节流 + 节拍边界量化
            if cli.lyricPrompt {
                themeEngine.onPrompt = { p in client.setPrompt(p) }
            }
        }
        // L3 legacy path (engine off): lyric line -> hot prompt modulation
        lyrics.attach(music: music) { line in
            guard cli.lyricPrompt, !cli.emotionEngine else { return }
            let composed = cli.prompt + ", " + String(line.prefix(60))
            let apply = {
                client.setPrompt(composed)
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
    }
    switch cli.audioSource {
    case "music":
        scene.audioProvider = {
            let f = music.features
            groove.push(bass: f.x, mid: f.y, beat: f.w)
            return f
        }
    case "mic":
        scene.audioProvider = {
            let f = analyzer.current
            groove.push(bass: f.bass, mid: f.mid, beat: f.beat)
            return SIMD4(f.bass, f.mid, f.treble, f.beat)
        }
        scene.pitchProvider = { analyzer.current.pitchTurns }
        analyzer.start()
    case "system":
        scene.audioProvider = {
            let f = sysAudio.current
            groove.push(bass: f.bass, mid: f.mid, beat: f.beat)
            return SIMD4(f.bass, f.mid, f.treble, f.beat)
        }
        scene.pitchProvider = { sysAudio.current.pitchTurns }
        sysAudio.start()
        // 2s diagnostic: real features + pitch track visible in stdout
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            let f = sysAudio.current
            print(String(format: "[audio] sys b%.2f m%.2f t%.2f bt%.2f | pitch %.0fHz conf %.2f turns %.3f",
                         f.bass, f.mid, f.treble, f.beat,
                         f.pitchHz, f.pitchConfidence, f.pitchTurns))
        }
    default: break
    }
    if cli.audioSource != "none" {
        scene.slowEnergyProvider = { groove.slowEnergy }
        scene.kickEnvProvider = { groove.kick }
        scene.accumEnergyProvider = { groove.accum }
    }

    // L2 parallax lyric overlay: the device interlace samples this screen-space
    // MusicBridge position extrapolation at 4 Hz; toggle with 'l'.
    var lyricOverlayEnabled = true
    let lyricOverlay = LyricOverlayRenderer(device: app.renderer.device)
    lyricOverlay.titleLatinFontName = cli.titleLatinFont
    lyricOverlay.titleCJKFontName = cli.titleCJKFont
    if cli.fontSet != "auto", let fs = LyricFontPool.byID(cli.fontSet) {
        lyricOverlay.applyFontSet(fs)
    } else if cli.fontSet == "auto" {
        // laya arbitrates the poster font set per track at classification time
        themeEngine.onFontSet = { id in
            guard let fs = LyricFontPool.byID(id) else { return }
            lyricOverlay.applyFontSet(fs)
            print("[overlay] fontset -> \(id)")
        }
    }
    app.overlayProvider = { lyricOverlayEnabled ? lyricOverlay.texture : nil }
    if metadataActive {
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            guard lyricOverlayEnabled else { return }
            var title = "", subtitle = ""
            if music.playing {
                let pos = music.position
                if let win = lyrics.currentLineWindow(at: pos) {
                    title = win.text
                    subtitle = music.line
                } else {
                    title = music.line  // no lyrics / instrumental: track title
                }
            }
            // footer bar = track progress; karaoke coverage DISABLED for now
            // (line-window sync from LRCLIB + position extrapolation drifts)
            // — the coverage interface stays, fed a fixed 1 (fully lit).
            let trackProg = music.duration > 0 ? Float(music.position / music.duration) : 0
            lyricOverlay.update(title: title, subtitle: subtitle,
                                progress: min(max(trackProg, 0), 1), coverage: 1,
                                timecode: LyricOverlayRenderer.timecode(position: music.position,
                                                                        duration: music.duration),
                                drawableSize: CGSize(width: CGFloat(app.calibration.screenW),
                                                     height: CGFloat(app.calibration.screenH)))
        }
    }

    app.onRenderQuilt = { cmd, _, time in coordinator.onFrame(cmd: cmd, time: time) }
    // dual-quilt blend: device interlace lerps AI quilt <-> raw raymarch quilt
    // (hold G to fade to raw, release to fade back; --alt-mix sets a floor)
    app.altMixSource = { coordinator.altMixForDisplay }
    // display-level beat pulse on the AI layer only (raw layer stays steady):
    // same beat clock as the scene uniforms, 60 Hz smooth, no tile-phase noise.
    // Rhythm reads as a HUE pulse (mainHue); brightness gain is legacy-only.
    let beatForDisplay: () -> Float = {
        switch cli.audioSource {
        case "music": return music.features.w
        case "mic": return analyzer.current.beat
        case "system": return sysAudio.current.beat
        default: return 0
        }
    }
    // v5 音高锚定分层：AI 主层的音高显色走显示层（mainHue 60Hz 相干，无扩散
    // 衰减）；场景内 audioPitch 保留给 raw 层 / G-peek。
    let pitchForDisplay: () -> Float = {
        switch cli.audioSource {
        case "mic": return analyzer.current.pitchTurns
        case "system": return sysAudio.current.pitchTurns
        default: return 0
        }
    }
    app.mainHueProvider = {
        // 情感引擎 energy（含 chorus 短期 +0.3）缩放节拍脉冲；引擎关闭保持原样
        let amp: Float = (cli.emotionEngine && metadataActive)
            ? cli.beatHue * (0.7 + 0.6 * themeEngine.effectiveEnergy)
            : cli.beatHue
        return amp * beatForDisplay() + cli.pitchHue * pitchForDisplay()
    }
    if cli.beatGlow > 0 {
        app.mainGainProvider = { 1 + cli.beatGlow * beatForDisplay() }
    }
    app.overlayShiftFraction = cli.overlayShift
    app.onKey = { key in
        if key == "g" { coordinator.rawPeek = true; return true }
        if key == "l" {
            lyricOverlayEnabled.toggle()
            print("lyric overlay = \(lyricOverlayEnabled)")
            return true
        }
        if scene.handleKey(key) { return true }
        guard metadataActive else { return false }
        switch key {
        case " ": music.togglePlayPause(); return true
        case "n": music.nextTrack(); return true
        case "N": music.previousTrack(); return true
        default: return false
        }
    }
    app.onKeyUp = { key in
        if key == "g" { coordinator.rawPeek = false }
    }
    app.onStatusLine = {
        var s = coordinator.statusLine
        switch cli.audioSource {
        case "music":
            let f = music.features
            s += String(format: " | ♫ beat %.2f", f.w)
            if !music.line.isEmpty {
                s += " | ♪ " + music.line + (music.bpm > 0 ? " \(music.bpm)bpm" : "")
                if !lyrics.currentLine.isEmpty {
                    s += " | “" + String(lyrics.currentLine.prefix(32)) + "”"
                }
                if cli.emotionEngine, !themeEngine.currentEmotionID.isEmpty {
                    s += " | 🎭 " + themeEngine.currentEmotionID
                    if !themeEngine.currentThemeEN.isEmpty {
                        s += " · " + String(themeEngine.currentThemeEN.prefix(24))
                    }
                    if let sub = themeEngine.currentSubject {
                        s += " · " + sub.zh
                    }
                    s += String(format: " e%.2f", themeEngine.effectiveEnergy)
                }
            } else {
                s += " | ♪ (Music not playing)"
            }
        case "mic":
            let f = analyzer.current
            s += String(format: " | ♫ b%.2f m%.2f t%.2f bt%.2f p%.0fHz",
                        f.bass, f.mid, f.treble, f.beat, f.pitchHz)
        case "system":
            let f = sysAudio.current
            s += String(format: " | ♫ b%.2f m%.2f t%.2f bt%.2f p%.0fHz",
                        f.bass, f.mid, f.treble, f.beat, f.pitchHz)
            if !music.line.isEmpty {
                s += " | ♪ " + music.line + (music.bpm > 0 ? " \(music.bpm)bpm" : "")
            } else {
                s += " | ♪ (Music not playing)"
            }
        default: break
        }
        return s
    }
    // clean up workers no matter how we exit (TaskStop/SIGINT orphan them otherwise)
    gDiffusionClient = client
    gSystemAudio = sysAudio
    signal(SIGTERM) { _ in gDiffusionClient?.stopAll(); gLayaClient?.stop(); gSystemAudio?.stop(); exit(0) }
    signal(SIGINT) { _ in gDiffusionClient?.stopAll(); gLayaClient?.stop(); gSystemAudio?.stop(); exit(0) }
    app.onWillTerminate = { client.stopAll(); gLayaClient?.stop(); sysAudio.stop() }
    client.start()
    coordinator.start()

    // headless peek self-test: LKG_PEEK_TEST=1 auto-engages raw peek and dumps
    // the interlaced frame so the alt-quilt display path can be verified
    // without a keyboard.
    if ProcessInfo.processInfo.environment["LKG_PEEK_TEST"] != nil {
        // baseline (main quilt) dumps before engaging peek
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
            app.saveLenticular(to: "/tmp/peek-normal-lentic.png")
            app.renderer.saveQuiltPNG(to: "/tmp/peek-normal-quilt.png") { _ in }
            print("[peek-test] dumped normal baseline")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
            coordinator.rawPeek = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                app.saveLenticular(to: "/tmp/peek-live-lentic.png")
                app.renderer.saveQuiltPNG(to: "/tmp/peek-live-altquilt.png",
                                          source: app.renderer.altQuiltTexture) { _ in }
                print("[peek-test] dumped lentic + altquilt")
            }
        }
    }

    app.run()
} catch {
    print("error: \(error)")
    exit(1)
}

func cmdWait(_ renderer: QuiltRenderer) {
    if let cmd = renderer.commandQueue.makeCommandBuffer() {
        cmd.commit(); cmd.waitUntilCompleted()
    }
}
