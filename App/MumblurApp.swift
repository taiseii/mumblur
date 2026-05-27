import SwiftUI

@main
struct MumblurApp: App {
    var body: some Scene {
        MenuBarExtra("Mumblur", systemImage: "mic") {
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        .menuBarExtraStyle(.menu)
    }
}
