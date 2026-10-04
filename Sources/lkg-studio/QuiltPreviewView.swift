import Metal
import MetalKit
import SwiftUI

/// 30 Hz tonemapped quilt preview (the persistent AI composite, as QuiltPlayer
/// would show it). Scene encoding happens here only while the device window
/// is hidden — when the LKG panel is live, its driver owns the frame.
struct QuiltPreviewView: NSViewRepresentable {
    let model: StudioModel

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero,
                           device: model.renderer?.device ?? MTLCreateSystemDefaultDevice())
        view.colorPixelFormat = .bgra8Unorm
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.preferredFramesPerSecond = 30
        view.delegate = context.coordinator
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    final class Coordinator: NSObject, MTKViewDelegate {
        let model: StudioModel
        init(model: StudioModel) { self.model = model }
        func draw(in view: MTKView) { model.drawPreviewFrame(view) }
        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    }
}
