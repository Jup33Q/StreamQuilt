import AppKit
import SwiftUI

final class StudioAppDelegate: NSObject, NSApplicationDelegate {
    weak var model: StudioModel?
    func applicationWillTerminate(_ notification: Notification) { model?.shutdown() }
}

@main
struct LKGStudioApp: App {
    @NSApplicationDelegateAdaptor(StudioAppDelegate.self) private var appDelegate
    @StateObject private var model = StudioModel()

    var body: some Scene {
        WindowGroup("LKG Studio") {
            ContentView(model: model)
                .onAppear {
                    appDelegate.model = model
                    model.start()
                }
        }
        .defaultSize(width: 520, height: 880)
    }
}
