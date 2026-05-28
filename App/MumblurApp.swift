import SwiftUI
import MumblurCore

@main
struct MumblurApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // SCENE ORDER MATTERS — DO NOT REARRANGE.
        // On macOS Tahoe 26, `openSettings()` requires a SwiftUI render tree mounted
        // BEFORE the Settings scene. The hidden Window IS that tree.
        Window("OpenSettingsTrampoline", id: "openSettingsTrampoline") {
            OpenSettingsTrampolineView()
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 1, height: 1)
        .commandsRemoved()

        MenuBarExtra {
            MenuBarContent(coordinator: delegate.coordinator)
                .environmentObject(delegate.coordinator.settingsBridge)
        } label: {
            CoordinatorIcon(coordinator: delegate.coordinator)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsScene()
                .environmentObject(delegate.coordinator)
                .environmentObject(delegate.coordinator.settingsBridge)
                .onDisappear {
                    NotificationCenter.default.post(name: .settingsWindowClosed, object: nil)
                }
        }
    }
}

/// SwiftUI's MenuBarExtra content closure only mounts when the user opens the
/// menu (and may mount multiple times). Bootstrap must happen on app launch via
/// an AppDelegate, not via `.task` on the menu content.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let coordinator = AppCoordinator()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { await coordinator.bootstrap() }
    }
}

/// The label closure renders the always-visible menu bar icon. We split this
/// into its own view so `@ObservedObject` triggers redraws when `coordinator.icon`
/// changes (the label closure itself does not have view identity to observe state).
struct CoordinatorIcon: View {
    @ObservedObject var coordinator: AppCoordinator

    var body: some View {
        Image(systemName: coordinator.icon)
            .symbolRenderingMode(.hierarchical)
    }
}
