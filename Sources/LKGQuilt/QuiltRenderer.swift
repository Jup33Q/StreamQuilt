import AppKit
import CoreGraphics
import ImageIO
import Metal
import simd

/// Owns the HDR quilt render target and the fixed post-processing pipelines
/// (tonemap blit, lenticular interlace, calibration test pattern).
///
/// Content is supplied by the caller: render your scene into `quiltTexture`
/// (via `makeQuiltPassDescriptor()`), then `encodeLenticular()` turns it into
/// the image the Looking Glass panel needs.
public final class QuiltRenderer {
    public let device: MTLDevice
    public let commandQueue: MTLCommandQueue
    public let spec: QuiltSpec

    /// Fraction of full quilt resolution the scene renders at (1.0, 0.5, ...).
    public var renderScale: Float {
        didSet { rebuildTarget() }
    }

    /// rgba16Float quilt render target the scene renders into.
    public private(set) var quiltTexture: MTLTexture!

    private let tonemapPSO: MTLRenderPipelineState
    private let lenticularPSO: MTLRenderPipelineState
    private let testPatternPSO: MTLRenderPipelineState
    private var ldrTexture: MTLTexture!       // tonemapped quilt (PNG export)
    private var lenticTexture: MTLTexture!    // interlaced screen image (PNG export)

    public init(device: MTLDevice? = nil, spec: QuiltSpec = .lkgGo, renderScale: Float = 1) throws {
        guard let dev = device ?? MTLCreateSystemDefaultDevice() else {
            throw LKGError.noMetalDevice
        }
        self.device = dev
        guard let queue = dev.makeCommandQueue() else { throw LKGError.noCommandQueue }
        self.commandQueue = queue
        self.spec = spec
        self.renderScale = renderScale

        let lib = try dev.makeLibrary(source: LKGFixedShaders.msl, options: nil)
        func pso(_ fragment: String, format: MTLPixelFormat) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: "lkgFullscreenVS")
            d.fragmentFunction = lib.makeFunction(name: fragment)
            d.colorAttachments[0].pixelFormat = format
            return try dev.makeRenderPipelineState(descriptor: d)
        }
        tonemapPSO = try pso("lkgTonemapFS", format: .bgra8Unorm)
        lenticularPSO = try pso("lkgLenticularFS", format: .bgra8Unorm)
        testPatternPSO = try pso("lkgTestPatternFS", format: .rgba16Float)
        rebuildTarget()

        let ldr = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: spec.width, height: spec.height, mipmapped: false)
        ldr.usage = [.renderTarget, .shaderRead]
        ldr.storageMode = .shared
        ldrTexture = dev.makeTexture(descriptor: ldr)
    }

    private func rebuildTarget() {
        let w = max(1, Int(Float(spec.width) * renderScale))
        let h = max(1, Int(Float(spec.height) * renderScale))
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        quiltTexture = device.makeTexture(descriptor: d)
    }

    public enum LKGError: Error {
        case noMetalDevice, noCommandQueue, encodeFailed
    }

    // MARK: - Scene pass

    /// Render pass descriptor covering the whole quilt texture. Encode your
    /// scene into it — for raymarched content draw one fullscreen triangle and
    /// use `LKGShaderCommon.msl`'s `lkgTileInfo()` in your fragment shader.
    public func makeQuiltPassDescriptor() -> MTLRenderPassDescriptor {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = quiltTexture
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        return pass
    }

    /// Fill the quilt with the calibration test pattern (flat hue per view).
    public func encodeTestPattern(cmd: MTLCommandBuffer) {
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: makeQuiltPassDescriptor()) else { return }
        enc.setRenderPipelineState(testPatternPSO)
        struct TestParams { var tileSize: SIMD2<Float>; var cols: Float; var rows: Float }
        var p = TestParams(
            tileSize: SIMD2(Float(quiltTexture.width) / Float(spec.columns),
                            Float(quiltTexture.height) / Float(spec.rows)),
            cols: Float(spec.columns), rows: Float(spec.rows))
        enc.setFragmentBytes(&p, length: MemoryLayout<TestParams>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }

    // MARK: - Fixed post passes

    /// Interlace the quilt for direct display on a Looking Glass panel.
    public func encodeLenticular(cmd: MTLCommandBuffer, pass: MTLRenderPassDescriptor,
                                 calibration: Calibration, drawableSize: SIMD2<Float>) {
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.setRenderPipelineState(lenticularPSO)
        enc.setFragmentTexture(quiltTexture, index: 0)
        var lp = calibration.lenticularUniforms(columns: spec.columns, rows: spec.rows)
        lp.screenW = drawableSize.x
        lp.screenH = drawableSize.y
        enc.setFragmentBytes(&lp, length: MemoryLayout<LenticularUniforms>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }

    /// Tonemapped copy of the quilt into any render pass (preview window, PNG export).
    public func encodeTonemappedBlit(cmd: MTLCommandBuffer, pass: MTLRenderPassDescriptor,
                                     drawableSize: SIMD2<Float>) {
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.setRenderPipelineState(tonemapPSO)
        enc.setFragmentTexture(quiltTexture, index: 0)
        var sz = drawableSize
        enc.setFragmentBytes(&sz, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }

    // MARK: - PNG export

    /// Render one frame via `encodeQuilt` and save the tonemapped quilt as PNG.
    public func saveQuiltPNG(to path: String, encodeQuilt: (MTLCommandBuffer) -> Void) {
        guard let cmd = commandQueue.makeCommandBuffer() else { return }
        encodeQuilt(cmd)
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = ldrTexture
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        encodeTonemappedBlit(cmd: cmd, pass: pass,
                             drawableSize: SIMD2(Float(spec.width), Float(spec.height)))
        cmd.commit()
        cmd.waitUntilCompleted()
        writePNG(texture: ldrTexture, to: path)
        print("saved \(path) (\(spec.width)x\(spec.height), \(spec.columns)x\(spec.rows) views)")
    }

    /// Render one frame and save the interlaced panel image as PNG
    /// (for inspecting the optical transformation off-device).
    public func saveLenticularPNG(to path: String, calibration: Calibration,
                                  encodeQuilt: (MTLCommandBuffer) -> Void) {
        let w = Int(calibration.screenW), h = Int(calibration.screenH)
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: d),
              let cmd = commandQueue.makeCommandBuffer() else { return }
        encodeQuilt(cmd)
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = tex
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        encodeLenticular(cmd: cmd, pass: pass, calibration: calibration,
                         drawableSize: SIMD2(Float(w), Float(h)))
        cmd.commit()
        cmd.waitUntilCompleted()
        writePNG(texture: tex, to: path)
        print("saved \(path) (\(w)x\(h) interlaced)")
    }

    private func writePNG(texture: MTLTexture, to path: String) {
        let w = texture.width, h = texture.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        texture.getBytes(&data, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        guard let ctx = CGContext(data: &data, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: cs, bitmapInfo: info.rawValue),
              let img = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                         "public.png" as CFString, 1, nil)
        else { print("PNG encode failed: \(path)"); return }
        CGImageDestinationAddImage(dest, img, nil)
        CGImageDestinationFinalize(dest)
    }
}
