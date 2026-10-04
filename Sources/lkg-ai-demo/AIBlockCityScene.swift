import LKGQuilt
import Metal
import simd

/// AI path scene: same raymarched block city as lkg-demo, but with two outputs:
/// - `encodeBase`: fast full-quilt HDR render (the 60fps 3D backbone layer)
/// - `encodeView`: one view into a square LDR staging texture, as img2img input
///
/// The staging render is square (aspect 1); `QuiltRenderer.updateTile` center-crops
/// it to the portrait tile aspect when compositing a stylized result.
final class AIBlockCityScene {
    var sweep: Float = 2.5
    var fovY: Float = 25 * .pi / 180
    var dist: Float = 13.0
    var camH: Float = 3.2
    var pitch: Float = 0.20
    var flip: Float = 1.0
    /// AI path: diffusion refreshes at ~1-2 Hz, so slow the scene animation
    /// down to keep staged tiles from going stale too fast.
    var timeScale: Float = 0.2

    let viewSize: Int
    private let renderer: QuiltRenderer
    private let basePSO: MTLRenderPipelineState
    private let viewPSO: MTLRenderPipelineState
    private(set) var staging: [MTLTexture]
    private(set) var readBuffers: [MTLBuffer]

    struct BaseParams {
        var tileSize: SIMD2<Float>
        var audio: SIMD4<Float>
        var cols: Float; var rows: Float; var time: Float
        var size: Float; var flip: Float; var dist: Float; var camH: Float
        var fovTan: Float; var pitch: Float; var aspect: Float
    }

    struct ViewParams {
        var audio: SIMD4<Float>
        var time: Float; var viewT: Float; var size: Float; var flip: Float
        var dist: Float; var camH: Float; var fovTan: Float; var pitch: Float
        var renderSize: Float
    }

    /// Supplies (bass, mid, treble, beat) each encode; nil = silence.
    var audioProvider: (() -> SIMD4<Float>)?

    init(renderer: QuiltRenderer, viewSize: Int = 512, stagingCount: Int = 8) throws {
        self.renderer = renderer
        self.viewSize = viewSize
        let lib = try renderer.device.makeLibrary(source: LKGShaderCommon.msl + Self.sceneMSL, options: nil)

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
    func encodeBase(cmd: MTLCommandBuffer, time: Float, into altTarget: MTLTexture? = nil) {
        let t = time * timeScale
        guard let target = altTarget ?? renderer.quiltTexture else { return }
        let spec = renderer.spec
        let pass = altTarget != nil
            ? renderer.makeAltQuiltPassDescriptor(loadAction: .dontCare)
            : renderer.makeQuiltPassDescriptor(loadAction: .dontCare)
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.setRenderPipelineState(basePSO)
        var p = BaseParams(
            tileSize: SIMD2(Float(target.width) / Float(spec.columns),
                            Float(target.height) / Float(spec.rows)),
            audio: audioProvider?() ?? .zero,
            cols: Float(spec.columns), rows: Float(spec.rows), time: t,
            size: sweep, flip: flip, dist: dist, camH: camH,
            fovTan: tan(fovY / 2), pitch: pitch, aspect: spec.tileAspect)
        enc.setFragmentBytes(&p, length: MemoryLayout<BaseParams>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }

    /// Render one view into a staging texture (LDR, for the diffusion worker).
    func encodeView(cmd: MTLCommandBuffer, viewIndex: Int, stagingIndex: Int, time: Float) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = staging[stagingIndex]
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.setRenderPipelineState(viewPSO)
        var p = ViewParams(
            audio: audioProvider?() ?? .zero,
            time: time * timeScale,
            viewT: Float(viewIndex) / Float(renderer.spec.viewCount - 1),
            size: sweep, flip: flip, dist: dist, camH: camH,
            fovTan: tan(fovY / 2), pitch: pitch, renderSize: Float(viewSize))
        enc.setFragmentBytes(&p, length: MemoryLayout<ViewParams>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }

    /// Encode an async readback of a staging texture into its read buffer (RGBA8).
    func encodeReadback(cmd: MTLCommandBuffer, stagingIndex: Int) {
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
    func readbackBytes(stagingIndex: Int) -> UnsafeRawBufferPointer {
        UnsafeRawBufferPointer(start: readBuffers[stagingIndex].contents(),
                               count: viewSize * viewSize * 4)
    }

    var statusLine: String {
        String(format: "size %.1f fov %.0f dist %.0f%@", sweep, fovY * 180 / .pi, dist,
               flip < 0 ? " flipped" : "")
    }

    func handleKey(_ key: String) -> Bool {
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
