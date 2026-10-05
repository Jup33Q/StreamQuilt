import AppKit
import SwiftUI

final class StreamQuiltAppDelegate: NSObject, NSApplicationDelegate {
    weak var model: StreamQuiltModel?
    func applicationWillTerminate(_ notification: Notification) { model?.shutdown() }
}

@main
struct StreamQuiltApp: App {
    @NSApplicationDelegateAdaptor(StreamQuiltAppDelegate.self) private var appDelegate
    @StateObject private var model = StreamQuiltModel()

    var body: some Scene {
        WindowGroup("StreamQuilt") {
            ContentView(model: model)
                .onAppear {
                    appDelegate.model = model
                    model.start()
                }
        }
        .defaultSize(width: 520, height: 880)
    }
}
