import AppKit
import Metal
import MetalKit
import QuartzCore

/// Fullscreen borderless window on the Looking Glass panel showing the
/// interlaced image at 60 Hz. Shared device-display path so both AppKit
/// shells and SwiftUI apps can manage the LKG screen without owning the
/// NSApplication run loop (SwiftUI never touches this window).
///
/// Frame encoding mirrors LKGApp's verified device path: the scene renders
/// into the quilt in its own command buffer, then the lenticular interlace
/// samples it (with optional alt-quilt subpixel blend and main-layer gain).
public final class LKGDeviceWindowController: NSObject {
    /// Reassignable so a rebuilt renderer (e.g. grid change) takes over the
    /// same window. The MTKView's device is unchanged in practice.
    public var renderer: QuiltRenderer
    public var calibration: Calibration

    /// Encode the scene into the quilt for a frame. Called once per device frame.
    public var onRenderQuilt: ((MTLCommandBuffer, Float) -> Void)?
    /// Frame timestamp in seconds (pause-aware clock of the host app).
    /// Default: wall clock.
    public var timeProvider: (() -> Float)?
    /// When non-nil, the device displays this texture instead of the main quilt.
    public var displaySourceOverride: (() -> MTLTexture?)?
    /// Dual-quilt blend: alt quilt texture + lerp factor (same semantics as
    /// `LKGApp.altMixSource`).
    public var altMixSource: (() -> (texture: MTLTexture, mix: Float)?)?
    /// Per-frame gain on the main quilt sample at display time. Default nil = 1.
    public var mainGainProvider: (() -> Float)?
    /// Show the raw quilt on the device instead of the interlaced image.
    public var bypassLenticular = false
    /// Render the per-view flat-color calibration test pattern.
    public var testPattern = false
    /// ~1 Hz callback with the measured device frame rate (main thread).
    public var onFPS: ((Double) -> Void)?

    public private(set) var window: NSWindow?
    private var driver: DeviceDriver?

    public init(renderer: QuiltRenderer, calibration: Calibration) {
        self.renderer = renderer
        self.calibration = calibration
    }

    /// The LKG panel screen, nil when not connected (or LKG_NO_DEVICE is set).
    public static var deviceScreen: NSScreen? { LKGApp.findLKGScreen() }

    public var isShowing: Bool { window != nil }

    /// Open the fullscreen window on the LKG panel.
    /// Returns false when no LKG screen is connected.
    @discardableResult
    public func show() -> Bool {
        if window != nil { return true }
        guard let lkg = Self.deviceScreen else { return false }
        let w = NSWindow(contentRect: lkg.frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.setFrame(lkg.frame, display: true)
        let scale = lkg.backingScaleFactor
        let v = MTKView(frame: NSRect(origin: .zero, size: lkg.frame.size), device: renderer.device)
        v.autoResizeDrawable = false
        v.drawableSize = CGSize(width: lkg.frame.width * scale, height: lkg.frame.height * scale)
        v.colorPixelFormat = .bgra8Unorm
        v.isPaused = false
        v.enableSetNeedsDisplay = false
        v.preferredFramesPerSecond = 60
        let d = DeviceDriver(controller: self)
        v.delegate = d
        w.contentView = v
        w.orderFrontRegardless()
        window = w
        driver = d
        return true
    }

    public func hide() {
        window?.orderOut(nil)
        window = nil
        driver = nil
    }

    private final class DeviceDriver: NSObject, MTKViewDelegate {
        weak var controller: LKGDeviceWindowController?
        private var frames = 0
        private var lastReport = CACurrentMediaTime()

        init(controller: LKGDeviceWindowController) { self.controller = controller }

        func draw(in view: MTKView) {
            guard let c = controller else { return }
            let r = c.renderer
            let t = c.timeProvider?() ?? Float(CACurrentMediaTime())
            let destSize = SIMD2(Float(view.drawableSize.width), Float(view.drawableSize.height))
            guard let rpd = view.currentRenderPassDescriptor,
                  let drawable = view.currentDrawable else { return }

            // Split command buffers like LKGApp: scene first, interlace second.
            let cmd1 = r.commandQueue.makeCommandBuffer()!
            if c.testPattern || c.onRenderQuilt == nil {
                r.encodeTestPattern(cmd: cmd1)
            } else {
                c.onRenderQuilt?(cmd1, t)
            }
            cmd1.commit()

            let cmd2 = r.commandQueue.makeCommandBuffer()!
            // mix >= 0.999: sample the alt quilt directly (saves the blend fetch)
            let altMix = c.altMixSource?()
            let fullAlt = altMix != nil && altMix!.mix >= 0.999
            let src = c.displaySourceOverride?() ?? (fullAlt ? altMix!.texture : nil)
            if c.bypassLenticular {
                r.encodeTonemappedBlit(cmd: cmd2, pass: rpd, drawableSize: destSize, source: src)
            } else {
                r.encodeLenticular(cmd: cmd2, pass: rpd, calibration: c.calibration,
                                   drawableSize: destSize, source: src,
                                   alt: fullAlt ? nil : altMix?.texture,
                                   altMix: fullAlt ? 0 : (altMix?.mix ?? 0),
                                   mainGain: c.mainGainProvider?() ?? 1)
            }
            cmd2.present(drawable)
            cmd2.commit()

            frames += 1
            let now = CACurrentMediaTime()
            if now - lastReport >= 1 {
                c.onFPS?(Double(frames) / (now - lastReport))
                frames = 0
                lastReport = now
            }
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    }
}
