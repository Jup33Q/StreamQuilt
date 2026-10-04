// lkg-ai-demo: real-time AI-stylized quilt on Looking Glass.
//
// Metal raymarches 66 views -> Python StreamDiffusion workers (CoreML img2img)
// stylize them concurrently -> results composite into the quilt -> lenticular
// interlace -> LKG at 60 Hz (AI tiles refresh asynchronously).
//
//   swift run -c release lkg-ai-demo                                  # live
//   swift run -c release lkg-ai-demo -- --workers 4 --strength 0.5
//   swift run -c release lkg-ai-demo -- --dump ai-quilt.png           # offline

import Foundation
import LKGQuilt
import Metal

setvbuf(stdout, nil, _IONBF, 0)

// signal handlers can't capture context — keep a global for cleanup.
private var gDiffusionClient: DiffusionClient?

struct CLI {
    // N2: palette-locked prompt matching the synthwave scene (anti-flicker:
    // shrinks style/brightness variance between AI tiles and the base layer)
    var prompt = "synthwave retrowave landscape, bright pastel pink and cyan palette, golden sunset lighting, neon grid valley, starry sky, clean bold shapes, masterpiece"
    var workers = 2
    // euler 修复后 strength 真实生效（1.0=修复前的全风格化）。0.6 = A/B 后选定：
    // 输出贴近输入构图/色调，epoch 间跳变最小；要更强风格化用 --strength 0.8~1.0
    var strength: Float = 0.6
    var renderSize = 512
    var dumpPath: String?
    var peekDumpPath: String?
    var time: Float = 1.2
    var showPreview = true
    var renderScale: Float = 1.0
    var batch = 1
    var feedback: Float = 0.3   // latent 时序粘合（防频闪）
    var lumaNorm: Float = 1.0   // N1 tile 明度归一强度（0=关，1=输出均值拉齐输入均值）
    var order = "wave"          // N3 更新顺序：wave 蛇形扫描波 | center 中心优先
    var beatEpoch = true        // N4 epoch 边界对齐节拍（每 2 拍一个 epoch）
    var altMix: Float = 0       // 常驻原始层混合比（0-1；G 键按住时平滑推到 1）
    var beatGlow: Float = 0.25  // AI 层显示级节拍脉冲幅度（0=关；interlace 内主 quilt 增益）
    var grid = "7x8"   // AI 路径默认 7x8=56（低算力布局）；11x6 为全规格 66
    var units = ""     // 逗号分隔，如 "all,cpu_and_gpu"；空 = 异构默认
    var audioSource = "music"   // music（Apple Music 节拍钟，默认）| mic | none
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
    case "--time": cli.time = Float(args[i + 1]) ?? 1.2; i += 1
    case "--no-preview": cli.showPreview = false
    case "--half": cli.renderScale = 0.5
    case "--batch": cli.batch = Int(args[i + 1]) ?? 1; i += 1
    case "--feedback": cli.feedback = Float(args[i + 1]) ?? 0.3; i += 1
    case "--luma-norm": cli.lumaNorm = Float(args[i + 1]) ?? 1.0; i += 1
    case "--order": cli.order = args[i + 1]; i += 1
    case "--no-beat-epoch": cli.beatEpoch = false
    case "--alt-mix": cli.altMix = Float(args[i + 1]) ?? 0; i += 1
    case "--beat-glow": cli.beatGlow = Float(args[i + 1]) ?? 0.25; i += 1
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

func selectSpec() -> QuiltSpec {
    cli.grid == "11x6" ? .lkgGo : .lkgGo56
}

do {
    if let peekPath = cli.peekDumpPath {
        let renderer = try QuiltRenderer(spec: selectSpec(), renderScale: cli.renderScale)
        let scene = try AIBlockCityScene(renderer: renderer, viewSize: cli.renderSize)
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

    if let dumpPath = cli.dumpPath {
        let renderer = try QuiltRenderer(spec: selectSpec(), renderScale: cli.renderScale)
        let scene = try AIBlockCityScene(renderer: renderer, viewSize: cli.renderSize)
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

    // audio-reactive: Apple Music beat clock (default) or mic FFT (--audio-source mic)
    let music = MusicBridge()
    let analyzer = AudioAnalyzer()
    if cli.audioSource == "music" {
        scene.audioProvider = { music.features }
        music.start()
        // N4: epoch boundaries aligned to every 2nd beat
        if cli.beatEpoch {
            coordinator.beatClockProvider = { music.beatClock }
        }
    } else if cli.audioSource == "mic" {
        scene.audioProvider = {
            let f = analyzer.current
            return SIMD4(f.bass, f.mid, f.treble, f.beat)
        }
        analyzer.start()
    }

    app.onRenderQuilt = { cmd, _, time in coordinator.onFrame(cmd: cmd, time: time) }
    // dual-quilt blend: device interlace lerps AI quilt <-> raw raymarch quilt
    // (hold G to fade to raw, release to fade back; --alt-mix sets a floor)
    app.altMixSource = { coordinator.altMixForDisplay }
    // display-level beat pulse on the AI layer only (raw layer stays steady):
    // same beat clock as the scene uniforms, 60 Hz smooth, no tile-phase noise
    app.mainGainProvider = {
        let beat: Float
        switch cli.audioSource {
        case "music": beat = music.features.w
        case "mic": beat = analyzer.current.beat
        default: beat = 0
        }
        return 1 + cli.beatGlow * beat
    }
    app.onKey = { key in
        if key == "g" { coordinator.rawPeek = true; return true }
        if scene.handleKey(key) { return true }
        guard cli.audioSource == "music" else { return false }
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
            } else {
                s += " | ♪ (Music not playing)"
            }
        case "mic":
            let f = analyzer.current
            s += String(format: " | ♫ b%.2f m%.2f t%.2f bt%.2f", f.bass, f.mid, f.treble, f.beat)
        default: break
        }
        return s
    }
    // clean up workers no matter how we exit (TaskStop/SIGINT orphan them otherwise)
    gDiffusionClient = client
    signal(SIGTERM) { _ in gDiffusionClient?.stopAll(); exit(0) }
    signal(SIGINT) { _ in gDiffusionClient?.stopAll(); exit(0) }
    app.onWillTerminate = { client.stopAll() }
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
