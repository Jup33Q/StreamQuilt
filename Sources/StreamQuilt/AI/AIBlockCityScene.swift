import Metal
import simd

/// AI path scene: same raymarched block city as sq-demo, but with two outputs:
/// - `encodeBase`: fast full-quilt HDR render (the 60fps 3D backbone layer)
/// - `encodeView`: one view into a square LDR staging texture, as img2img input
///
/// The staging render is square (aspect 1); `QuiltRenderer.updateTile` center-crops
/// it to the portrait tile aspect when compositing a stylized result.
public final class AIBlockCityScene {
    public var sweep: Float = 2.5
    public var fovY: Float = 25 * .pi / 180
    public var dist: Float = 13.0
    public var camH: Float = 2.5
    public var pitch: Float = 0.07
    public var flip: Float = 1.0
    /// AI path: diffusion refreshes at ~1-2 Hz, so slow the scene animation
    /// down to keep staged tiles from going stale too fast.
    public var timeScale: Float = 0.2

    public let viewSize: Int
    private let renderer: QuiltRenderer
    private let basePSO: MTLRenderPipelineState
    private let viewPSO: MTLRenderPipelineState
    /// v5 groove pipelines (sceneMSL5). Used only when slowEnergy or kickEnv
    /// is nonzero; at zero the v4 pipeline runs and output is bitwise S5.
    private let basePSO5: MTLRenderPipelineState
    private let viewPSO5: MTLRenderPipelineState
    public private(set) var staging: [MTLTexture]
    public private(set) var readBuffers: [MTLBuffer]

    /// Emotion-engine scene theme: (hueBias, crystalGain, columnGain, emberGain).
    /// Default is bitwise-neutral (hue +0, gains ×1) — offline dumps stay identical.
    public var themeBias: SIMD4<Float> = SIMD4(0, 1, 1, 1)

    struct BaseParams {
        var tileSize: SIMD2<Float>
        var audio: SIMD4<Float>
        var cols: Float; var rows: Float; var time: Float
        var size: Float; var flip: Float; var dist: Float; var camH: Float
        var fovTan: Float; var pitch: Float; var aspect: Float
        var theme: SIMD4<Float>
        var audioPitch: Float   // tail-appended: detected pitch in hue turns (MIDI/12)
        var slowEnergy: Float   // tail-appended v5: 2-4s phrase-energy EMA
        var kickEnv: Float      // tail-appended v5: kick envelope (slow attack, fast release)
    }

    struct ViewParams {
        var audio: SIMD4<Float>
        var time: Float; var viewT: Float; var size: Float; var flip: Float
        var dist: Float; var camH: Float; var fovTan: Float; var pitch: Float
        var renderSize: Float
        var theme: SIMD4<Float>
        var audioPitch: Float   // tail-appended: detected pitch in hue turns (MIDI/12)
        var slowEnergy: Float   // tail-appended v5
        var kickEnv: Float      // tail-appended v5
    }

    /// Supplies (bass, mid, treble, beat) each encode; nil = silence.
    public var audioProvider: (() -> SIMD4<Float>)?
    /// Supplies the detected pitch in hue turns (MIDI/12) each encode;
    /// nil = 0 (bitwise-neutral — offline dumps stay identical).
    public var pitchProvider: (() -> Float)?
    /// v5 fast/slow split: phrase-energy EMA + kick envelope for
    /// geometry-level groove; nil = 0 (bitwise-neutral).
    public var slowEnergyProvider: (() -> Float)?
    public var kickEnvProvider: (() -> Float)?

    public init(renderer: QuiltRenderer, viewSize: Int = 512, stagingCount: Int = 8) throws {
        self.renderer = renderer
        self.viewSize = viewSize
        let lib = try renderer.device.makeLibrary(source: LKGShaderCommon.msl + Self.sceneMSL, options: nil)
        let lib5 = try renderer.device.makeLibrary(source: LKGShaderCommon.msl + Self.sceneMSL5, options: nil)

        let bd = MTLRenderPipelineDescriptor()
        bd.vertexFunction = lib.makeFunction(name: "aiSceneVS")
        bd.fragmentFunction = lib.makeFunction(name: "aiBaseFS")
        bd.colorAttachments[0].pixelFormat = .rgba16Float
        basePSO = try renderer.device.makeRenderPipelineState(descriptor: bd)

        let vd = MTLRenderPipelineDescriptor()
        vd.vertexFunction = lib.makeFunction(name: "aiSceneVS")
        vd.fragmentFunction = lib.makeFunction(name: "aiViewFS")
        vd.colorAttachments[0].pixelFormat = .rgba8Unorm
        viewPSO = try renderer.device.makeRenderPipelineState(descriptor: vd)

        let bd5 = MTLRenderPipelineDescriptor()
        bd5.vertexFunction = lib5.makeFunction(name: "aiSceneVS")
        bd5.fragmentFunction = lib5.makeFunction(name: "aiBaseFS")
        bd5.colorAttachments[0].pixelFormat = .rgba16Float
        basePSO5 = try renderer.device.makeRenderPipelineState(descriptor: bd5)

        let vd5 = MTLRenderPipelineDescriptor()
        vd5.vertexFunction = lib5.makeFunction(name: "aiSceneVS")
        vd5.fragmentFunction = lib5.makeFunction(name: "aiViewFS")
        vd5.colorAttachments[0].pixelFormat = .rgba8Unorm
        viewPSO5 = try renderer.device.makeRenderPipelineState(descriptor: vd5)

        let sd = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: viewSize, height: viewSize, mipmapped: false)
        sd.usage = [.renderTarget, .shaderRead]
        sd.storageMode = .shared
        staging = (0..<stagingCount).compactMap { _ in renderer.device.makeTexture(descriptor: sd) }
        readBuffers = (0..<stagingCount).compactMap { _ in
            renderer.device.makeBuffer(length: viewSize * viewSize * 4, options: .storageModeShared)
        }
    }

    /// Full-quilt HDR raymarch — the always-fresh 3D backbone under AI tiles.
    /// `into: nil` renders into the main quilt; pass the alt target for raw peek.
    public func encodeBase(cmd: MTLCommandBuffer, time: Float, into altTarget: MTLTexture? = nil) {
        let t = time * timeScale
        guard let target = altTarget ?? renderer.quiltTexture else { return }
        let spec = renderer.spec
        let pass = altTarget != nil
            ? renderer.makeAltQuiltPassDescriptor(loadAction: .dontCare)
            : renderer.makeQuiltPassDescriptor(loadAction: .dontCare)
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        let slow = slowEnergyProvider?() ?? 0
        let kick = kickEnvProvider?() ?? 0
        // v5 pipeline engages only when the groove uniforms are live; at
        // (0, 0) the v4 pipeline produces bitwise-S5 output by construction.
        enc.setRenderPipelineState(slow > 0 || kick > 0 ? basePSO5 : basePSO)
        var p = BaseParams(
            tileSize: SIMD2(Float(target.width) / Float(spec.columns),
                            Float(target.height) / Float(spec.rows)),
            audio: audioProvider?() ?? .zero,
            cols: Float(spec.columns), rows: Float(spec.rows), time: t,
            size: sweep, flip: flip, dist: dist, camH: camH,
            fovTan: tan(fovY / 2), pitch: pitch, aspect: spec.tileAspect,
            theme: themeBias, audioPitch: pitchProvider?() ?? 0,
            slowEnergy: slow,
            kickEnv: kick)
        enc.setFragmentBytes(&p, length: MemoryLayout<BaseParams>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }

    /// Render one view into a staging texture (LDR, for the diffusion worker).
    public func encodeView(cmd: MTLCommandBuffer, viewIndex: Int, stagingIndex: Int, time: Float) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = staging[stagingIndex]
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        let slow = slowEnergyProvider?() ?? 0
        let kick = kickEnvProvider?() ?? 0
        enc.setRenderPipelineState(slow > 0 || kick > 0 ? viewPSO5 : viewPSO)
        var p = ViewParams(
            audio: audioProvider?() ?? .zero,
            time: time * timeScale,
            viewT: Float(viewIndex) / Float(renderer.spec.viewCount - 1),
            size: sweep, flip: flip, dist: dist, camH: camH,
            fovTan: tan(fovY / 2), pitch: pitch, renderSize: Float(viewSize),
            theme: themeBias, audioPitch: pitchProvider?() ?? 0,
            slowEnergy: slow,
            kickEnv: kick)
        enc.setFragmentBytes(&p, length: MemoryLayout<ViewParams>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }

    /// Encode an async readback of a staging texture into its read buffer (RGBA8).
    public func encodeReadback(cmd: MTLCommandBuffer, stagingIndex: Int) {
        guard let blit = cmd.makeBlitCommandEncoder() else { return }
        blit.copy(from: staging[stagingIndex], sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: viewSize, height: viewSize, depth: 1),
                  to: readBuffers[stagingIndex], destinationOffset: 0,
                  destinationBytesPerRow: viewSize * 4,
                  destinationBytesPerImage: viewSize * viewSize * 4)
        blit.endEncoding()
    }

    /// RGBA bytes of a completed readback.
    public func readbackBytes(stagingIndex: Int) -> UnsafeRawBufferPointer {
        UnsafeRawBufferPointer(start: readBuffers[stagingIndex].contents(),
                               count: viewSize * viewSize * 4)
    }

    public var statusLine: String {
        String(format: "size %.1f fov %.0f dist %.0f%@", sweep, fovY * 180 / .pi, dist,
               flip < 0 ? " flipped" : "")
    }

    public func handleKey(_ key: String) -> Bool {
        switch key {
        case "f": flip *= -1
        case "-": sweep = max(0.2, sweep - 0.2)
        case "=", "+": sweep += 0.2
        case "[": dist = max(4, dist - 1)
        case "]": dist += 1
        case "9": fovY = max(8 * .pi / 180, fovY - 2 * .pi / 180)
        case "0": fovY = min(50 * .pi / 180, fovY + 2 * .pi / 180)
        default: return false
        }
        return true
    }
}
