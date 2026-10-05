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

    /// Optional second quilt target (same spec), e.g. for a raw/unprocessed
    /// peek layer. Lazily created via `makeAltQuiltTarget()`.
    public private(set) var altQuiltTexture: MTLTexture?

    /// Lazily create/return the alternate quilt target (matches current renderScale).
    @discardableResult
    public func makeAltQuiltTarget() -> MTLTexture {
        if let altQuiltTexture, altQuiltTexture.width == quiltTexture.width {
            return altQuiltTexture
        }
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: quiltTexture.width, height: quiltTexture.height,
            mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        let tex = device.makeTexture(descriptor: d)!
        altQuiltTexture = tex
        return tex
    }

    /// Pass descriptor onto the alternate quilt target.
    public func makeAltQuiltPassDescriptor(loadAction: MTLLoadAction = .dontCare) -> MTLRenderPassDescriptor {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = makeAltQuiltTarget()
        pass.colorAttachments[0].loadAction = loadAction
        pass.colorAttachments[0].storeAction = .store
        return pass
    }

    private let tonemapPSO: MTLRenderPipelineState
    private let lenticularPSO: MTLRenderPipelineState
    private let testPatternPSO: MTLRenderPipelineState
    private let tileBlitPSO: MTLRenderPipelineState
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

        let td = MTLRenderPipelineDescriptor()
        td.vertexFunction = lib.makeFunction(name: "lkgFullscreenVS")
        td.fragmentFunction = lib.makeFunction(name: "lkgTileBlitFS")
        td.colorAttachments[0].pixelFormat = .rgba16Float
        td.colorAttachments[0].isBlendingEnabled = true
        td.colorAttachments[0].rgbBlendOperation = .add
        td.colorAttachments[0].alphaBlendOperation = .add
        td.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        td.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        td.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        td.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        tileBlitPSO = try dev.makeRenderPipelineState(descriptor: td)
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
    /// Use `.load` when compositing onto a persistent quilt (e.g. AI tile updates).
    public func makeQuiltPassDescriptor(loadAction: MTLLoadAction = .dontCare) -> MTLRenderPassDescriptor {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = quiltTexture
        pass.colorAttachments[0].loadAction = loadAction
        pass.colorAttachments[0].storeAction = .store
        return pass
    }

    /// Pixel rect of a view's tile inside the current quilt texture
    /// (accounts for renderScale). View 0 = bottom-left tile.
    public func tileRect(index: Int) -> MTLViewport {
        let tw = quiltTexture.width / spec.columns
        let th = quiltTexture.height / spec.rows
        let col = index % spec.columns
        let row = index / spec.columns
        return MTLViewport(originX: Double(col * tw),
                           originY: Double(quiltTexture.height - (row + 1) * th),
                           width: Double(tw), height: Double(th), znear: 0, zfar: 1)
    }

    /// Composite an LDR sRGB image (any size; center-cropped to tile aspect)
    /// into one view's tile of the persistent quilt, converting to linear HDR.
    /// blendAlpha < 1 crossfades with the existing tile content (anti-flicker).
    /// lumaGain rescales the source brightness (output mean pulled toward the
    /// input frame's mean; anti-flicker brightness normalization).
    public func updateTile(index: Int, srcTexture: MTLTexture, cmd: MTLCommandBuffer,
                           blendAlpha: Float = 1, lumaGain: Float = 1) {
        let vp = tileRect(index: index)
        let tileW = Float(vp.width), tileH = Float(vp.height)
        let srcW = Float(srcTexture.width), srcH = Float(srcTexture.height)
        // center-crop src to tile aspect
        let tileAspect = tileW / tileH
        var cropW = srcW, cropH = srcH
        if srcW / srcH > tileAspect { cropW = srcH * tileAspect } else { cropH = srcW / tileAspect }
        struct TileBlitParams {
            var tileOrigin: SIMD2<Float>; var tileSize: SIMD2<Float>
            var cropOrigin: SIMD2<Float>; var cropSize: SIMD2<Float>
            var srcSize: SIMD2<Float>; var blendAlpha: Float; var lumaGain: Float
        }
        var p = TileBlitParams(
            tileOrigin: SIMD2(Float(vp.originX), Float(vp.originY)),
            tileSize: SIMD2(tileW, tileH),
            cropOrigin: SIMD2((srcW - cropW) * 0.5, (srcH - cropH) * 0.5),
            cropSize: SIMD2(cropW, cropH),
            srcSize: SIMD2(srcW, srcH),
            blendAlpha: blendAlpha, lumaGain: lumaGain)

        let pass = makeQuiltPassDescriptor(loadAction: .load)
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.setRenderPipelineState(tileBlitPSO)
        enc.setViewport(vp)
        enc.setScissorRect(MTLScissorRect(x: Int(vp.originX), y: Int(vp.originY),
                                          width: Int(vp.width), height: Int(vp.height)))
        enc.setFragmentBytes(&p, length: MemoryLayout<TileBlitParams>.stride, index: 0)
        enc.setFragmentTexture(srcTexture, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
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
    /// `source` defaults to the main quilt; pass an alternate target for peek modes.
    /// `alt` + `altMix` blend a second quilt per subpixel at the same view
    /// coordinates (0 = source only, 1 = alt only) — smooth layer crossfade.
    public func encodeLenticular(cmd: MTLCommandBuffer, pass: MTLRenderPassDescriptor,
                                 calibration: Calibration, drawableSize: SIMD2<Float>,
                                 source: MTLTexture? = nil,
                                 overlay: MTLTexture? = nil, overlayShift: Float = 0,
                                 alt: MTLTexture? = nil, altMix: Float = 0,
                                 mainGain: Float = 1, mainHue: Float = 0) {
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.setRenderPipelineState(lenticularPSO)
        enc.setFragmentTexture(source ?? quiltTexture, index: 0)
        enc.setFragmentTexture(overlay ?? source ?? quiltTexture, index: 1)
        enc.setFragmentTexture(alt ?? source ?? quiltTexture, index: 2)
        var lp = calibration.lenticularUniforms(columns: spec.columns, rows: spec.rows)
        lp.screenW = drawableSize.x
        lp.screenH = drawableSize.y
        lp.hasOverlay = overlay != nil ? 1 : 0
        lp.overlayShift = overlayShift
        lp.altMix = alt != nil ? altMix : 0
        lp.mainGain = mainGain
        lp.mainHue = mainHue
        enc.setFragmentBytes(&lp, length: MemoryLayout<LenticularUniforms>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }

    /// Tonemapped copy of the quilt into any render pass (preview window, PNG export).
    public func encodeTonemappedBlit(cmd: MTLCommandBuffer, pass: MTLRenderPassDescriptor,
                                     drawableSize: SIMD2<Float>, source: MTLTexture? = nil) {
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.setRenderPipelineState(tonemapPSO)
        enc.setFragmentTexture(source ?? quiltTexture, index: 0)
        var sz = drawableSize
        enc.setFragmentBytes(&sz, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }

    // MARK: - PNG export

    /// Render one frame via `encodeQuilt` and save the tonemapped quilt as PNG.
    public func saveQuiltPNG(to path: String, source: MTLTexture? = nil,
                             encodeQuilt: (MTLCommandBuffer) -> Void) {
        guard let cmd = commandQueue.makeCommandBuffer() else { return }
        encodeQuilt(cmd)
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = ldrTexture
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        encodeTonemappedBlit(cmd: cmd, pass: pass,
                             drawableSize: SIMD2(Float(spec.width), Float(spec.height)),
                             source: source)
        cmd.commit()
        cmd.waitUntilCompleted()
        writePNG(texture: ldrTexture, to: path)
        print("saved \(path) (\(spec.width)x\(spec.height), \(spec.columns)x\(spec.rows) views)")
    }

    /// Render one frame and save the interlaced panel image as PNG
    /// (for inspecting the optical transformation off-device).
    public func saveLenticularPNG(to path: String, calibration: Calibration,
                                  source: MTLTexture? = nil,
                                  overlay: MTLTexture? = nil, overlayShift: Float = 0,
                                  alt: MTLTexture? = nil, altMix: Float = 0,
                                  mainGain: Float = 1, mainHue: Float = 0,
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
                         drawableSize: SIMD2(Float(w), Float(h)), source: source,
                         overlay: overlay, overlayShift: overlayShift,
                         alt: alt, altMix: altMix, mainGain: mainGain, mainHue: mainHue)
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
