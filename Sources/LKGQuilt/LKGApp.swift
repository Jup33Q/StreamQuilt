import AppKit
import Metal
import MetalKit
import QuartzCore

/// AppKit shell that drives a Looking Glass display: fullscreen window on the
/// LKG panel showing the interlaced image, plus an optional quilt preview
/// window on the main screen.
///
/// Usage:
/// ```swift
/// let app = try LKGApp()
/// app.onRenderQuilt = { cmd, pass, time in /* encode scene into quilt */ }
/// app.onKey = { key in /* custom keys, return true if consumed */ }
/// app.run()
/// ```
///
/// Built-in keys (preview window focused): q quit · s save quilt PNG ·
/// S save interlaced PNG · b bypass interlace (show raw quilt on device) ·
/// c calibration test pattern · p pause · 1/2 render scale.
public final class LKGApp: NSObject, NSApplicationDelegate {
    public let renderer: QuiltRenderer
    public let calibration: Calibration

    /// Encode the scene into the quilt for a frame. `time` is seconds since
    /// start (freeze-aware). Called once per device frame.
    public var onRenderQuilt: ((MTLCommandBuffer, MTLRenderPassDescriptor, Float) -> Void)?
    /// Custom key handler. Return true if the key was consumed.
    public var onKey: ((String) -> Bool)?
    /// Extra text appended to the periodic status line.
    public var onStatusLine: (() -> String)?
    /// Called from applicationWillTerminate — release external resources (e.g. child processes).
    public var onWillTerminate: (() -> Void)?

    public var showPreview = true
    /// Show the raw quilt on the device instead of the interlaced image (key: b).
    public var bypassLenticular = false
    /// Render the per-view flat-color calibration test pattern (key: c).
    public var testPattern = false
    public private(set) var paused = false

    private var windows: [NSWindow] = []
    private var drivers: [FrameDriver] = []
    private var deviceDriver: FrameDriver?
    private var startTime = CACurrentMediaTime()
    private var pauseBase: Float = 0

    public init(spec: QuiltSpec = .lkgGo, calibration: Calibration? = nil,
                renderScale: Float = 1) throws {
        renderer = try QuiltRenderer(spec: spec, renderScale: renderScale)
        if let calibration {
            self.calibration = calibration
        } else if let fetched = Calibration.fetchFromBridge() {
            print("calibration fetched from Looking Glass Bridge: \(fetched.serial)")
            self.calibration = fetched
        } else {
            print("Bridge unavailable — using built-in fallback calibration")
            self.calibration = .lkgGoFallback
        }
    }

    public func currentTime() -> Float {
        paused ? pauseBase : Float(CACurrentMediaTime() - startTime)
    }

    public func run() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let menubar = NSMenu()
        let appItem = NSMenuItem()
        menubar.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        app.mainMenu = menubar
        app.delegate = self
        app.run()
    }

    // MARK: - NSApplicationDelegate

    public func applicationDidFinishLaunching(_ note: Notification) {
        print("GPU: \(renderer.device.name)")
        let lp = calibration.lenticularUniforms(columns: renderer.spec.columns, rows: renderer.spec.rows)
        print(String(format: "calibration: %@ -> pitch %.3f tilt %.5f center %.4f subp %.7f invView %.0f",
                     calibration.serial, lp.pitch, lp.tilt, lp.center, lp.subp, lp.invView))
        print("quilt \(renderer.spec.width)x\(renderer.spec.height), "
              + "\(renderer.spec.columns)x\(renderer.spec.rows)=\(renderer.spec.viewCount) views, "
              + "tile \(renderer.spec.tileWidth)x\(renderer.spec.tileHeight)")

        // Fullscreen window on the LKG panel
        if let lkg = Self.findLKGScreen() {
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
            let d = FrameDriver(app: self, isDeviceView: true)
            v.delegate = d
            w.contentView = v
            w.orderFrontRegardless()
            windows.append(w); drivers.append(d); deviceDriver = d
            print("LKG display: \(lkg.localizedName) \(Int(lkg.frame.width))x\(Int(lkg.frame.height)) — live")
        } else {
            print("no LKG display found — preview only")
        }

        // Quilt preview window
        if showPreview {
            let pw = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 460, height: 460),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            pw.title = "LKG quilt preview — q quit · s save · b bypass · c calib-test · p pause · 1/2 res"
            let pv = MTKView(frame: pw.contentView!.bounds, device: renderer.device)
            pv.autoresizingMask = [.width, .height]
            pv.colorPixelFormat = .bgra8Unorm
            pv.isPaused = false
            pv.enableSetNeedsDisplay = false
            pv.preferredFramesPerSecond = 30
            let pd = FrameDriver(app: self, isDeviceView: false)
            pv.delegate = pd
            pw.contentView = pv
            pw.makeKeyAndOrderFront(nil)
            windows.append(pw); drivers.append(pd)
        }

        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            guard let self, let chars = ev.charactersIgnoringModifiers else { return ev }
            self.handleKey(chars)
            return ev
        }
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    public func applicationWillTerminate(_ notification: Notification) {
        onWillTerminate?()
    }

    public static func findLKGScreen() -> NSScreen? {
        if ProcessInfo.processInfo.environment["LKG_NO_DEVICE"] != nil { return nil }
        return NSScreen.screens.first {
            $0.localizedName.localizedCaseInsensitiveContains("LKG") ||
            ($0.frame.width == 1440 && $0.frame.height == 2560)
        }
    }

    // MARK: - Keys

    private func handleKey(_ key: String) {
        switch key {
        case "q": NSApp.terminate(nil)
        case "p":
            if paused { startTime = CACurrentMediaTime() - CFTimeInterval(pauseBase) }
            else { pauseBase = currentTime() }
            paused.toggle()
        case "s":
            let path = FileManager.default.currentDirectoryPath + "/quilt\(renderer.spec.namingSuffix).png"
            saveQuilt(to: path)
        case "S":
            let path = FileManager.default.currentDirectoryPath + "/lenticular.png"
            saveLenticular(to: path)
        case "b": bypassLenticular.toggle(); print("bypassLenticular = \(bypassLenticular)")
        case "c": testPattern.toggle(); print("testPattern = \(testPattern)")
        case "1": renderer.renderScale = 1.0
        case "2": renderer.renderScale = 0.5
        default: _ = onKey?(key)
        }
    }

    // MARK: - Snapshot

    public func saveQuilt(to path: String) {
        let t = currentTime()
        renderer.saveQuiltPNG(to: path) { cmd in self.encodeScene(cmd: cmd, time: t) }
    }

    public func saveLenticular(to path: String) {
        let t = currentTime()
        renderer.saveLenticularPNG(to: path, calibration: calibration) { cmd in
            self.encodeScene(cmd: cmd, time: t)
        }
    }

    fileprivate func encodeScene(cmd: MTLCommandBuffer, time: Float) {
        if testPattern || onRenderQuilt == nil {
            renderer.encodeTestPattern(cmd: cmd)
        } else {
            onRenderQuilt?(cmd, renderer.makeQuiltPassDescriptor(), time)
        }
    }
}

// MARK: - Frame driver

private final class FrameDriver: NSObject, MTKViewDelegate {
    unowned let app: LKGApp
    let isDeviceView: Bool
    var frames = 0
    var lastReport = CACurrentMediaTime()
    var sceneMs: Double = 0, sceneN = 0
    var postMs: Double = 0, postN = 0

    init(app: LKGApp, isDeviceView: Bool) {
        self.app = app
        self.isDeviceView = isDeviceView
    }

    func draw(in view: MTKView) {
        let r = app.renderer
        let t = app.currentTime()
        let destSize = SIMD2(Float(view.drawableSize.width), Float(view.drawableSize.height))

        if isDeviceView {
            // Split command buffers so scene / interlace GPU times are measurable.
            guard let rpd = view.currentRenderPassDescriptor,
                  let drawable = view.currentDrawable else { return }
            let cmd1 = r.commandQueue.makeCommandBuffer()!
            app.encodeScene(cmd: cmd1, time: t)
            cmd1.addCompletedHandler { [weak self] cb in
                self?.sceneMs += (cb.gpuEndTime - cb.gpuStartTime) * 1000
                self?.sceneN += 1
            }
            cmd1.commit()

            let cmd2 = r.commandQueue.makeCommandBuffer()!
            if app.bypassLenticular {
                r.encodeTonemappedBlit(cmd: cmd2, pass: rpd, drawableSize: destSize)
            } else {
                r.encodeLenticular(cmd: cmd2, pass: rpd, calibration: app.calibration,
                                   drawableSize: destSize)
            }
            cmd2.present(drawable)
            cmd2.addCompletedHandler { [weak self] cb in
                self?.postMs += (cb.gpuEndTime - cb.gpuStartTime) * 1000
                self?.postN += 1
            }
            cmd2.commit()
            report()
        } else {
            guard let cmd = r.commandQueue.makeCommandBuffer(),
                  let rpd = view.currentRenderPassDescriptor,
                  let drawable = view.currentDrawable else { return }
            if app.deviceDriverExists == false { app.encodeScene(cmd: cmd, time: t) }
            r.encodeTonemappedBlit(cmd: cmd, pass: rpd, drawableSize: destSize)
            cmd.present(drawable)
            cmd.commit()
            if app.deviceDriverExists == false { report() }
        }
    }

    private func report() {
        frames += 1
        let now = CACurrentMediaTime()
        guard now - lastReport >= 2 else { return }
        let fps = Double(frames) / (now - lastReport)
        let s = sceneN > 0 ? sceneMs / Double(sceneN) : 0
        let p = postN > 0 ? postMs / Double(postN) : 0
        let extra = app.onStatusLine?() ?? ""
        print(String(format: "FPS %5.1f | scene %6.2f ms | post %5.2f ms | quilt %dx%d%@",
                     fps, s, p, app.renderer.quiltTexture.width, app.renderer.quiltTexture.height,
                     extra.isEmpty ? "" : " | " + extra))
        frames = 0; lastReport = now
        sceneMs = 0; sceneN = 0; postMs = 0; postN = 0
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
}

private extension LKGApp {
    var deviceDriverExists: Bool { deviceDriver != nil }
}
