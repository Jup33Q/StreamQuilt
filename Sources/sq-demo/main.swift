// sq-demo: real-time shadertoy-style quilt rendering on Looking Glass (Metal).
//
//   swift run -c release sq-demo                     live on LKG + preview window
//   swift run -c release sq-demo -- --dump q.png     save one quilt frame and exit
//   swift run -c release sq-demo -- --dump-lentic l.png  save interlaced panel image
//   flags: --time 1.2  --half  --no-preview

import Foundation
import StreamQuilt

setvbuf(stdout, nil, _IONBF, 0)

var dumpPath: String?
var dumpLenticPath: String?
var dumpTime: Float = 1.2
var renderScale: Float = 1.0
var showPreview = true

var args = CommandLine.arguments
var i = 1
while i < args.count {
    switch args[i] {
    case "--dump": dumpPath = args[i + 1]; i += 1
    case "--dump-lentic": dumpLenticPath = args[i + 1]; i += 1
    case "--time": dumpTime = Float(args[i + 1]) ?? 1.2; i += 1
    case "--half": renderScale = 0.5
    case "--no-preview": showPreview = false
    default: break
    }
    i += 1
}

do {
    if dumpPath != nil || dumpLenticPath != nil {
        let renderer = try QuiltRenderer(spec: .lkgGo, renderScale: renderScale)
        let scene = try BlockCityScene(renderer: renderer)
        let calibration = Calibration.fetchFromBridge() ?? .lkgGoFallback
        if let dumpPath {
            renderer.saveQuiltPNG(to: dumpPath) { cmd in
                scene.encodeQuilt(cmd: cmd, pass: renderer.makeQuiltPassDescriptor(), time: dumpTime)
            }
        }
        if let dumpLenticPath {
            renderer.saveLenticularPNG(to: dumpLenticPath, calibration: calibration) { cmd in
                scene.encodeQuilt(cmd: cmd, pass: renderer.makeQuiltPassDescriptor(), time: dumpTime)
            }
        }
        exit(0)
    }

    let app = try LKGApp(spec: .lkgGo, renderScale: renderScale)
    app.showPreview = showPreview
    let scene = try BlockCityScene(renderer: app.renderer)
    app.onRenderQuilt = { cmd, pass, time in
        scene.encodeQuilt(cmd: cmd, pass: pass, time: time)
    }
    app.onKey = { scene.handleKey($0) }
    app.onStatusLine = { scene.statusLine }
    app.run()
} catch {
    print("error: \(error)")
    exit(1)
}
