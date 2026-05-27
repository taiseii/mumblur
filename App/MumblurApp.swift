import SwiftUI
import MumblurCore

@main
struct MumblurApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(coordinator: delegate.coordinator)
        } label: {
            CoordinatorIcon(coordinator: delegate.coordinator)
        }
        .menuBarExtraStyle(.menu)
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
/// into its own view so `@ObservedObject` triggers redraws when state changes
/// (the label closure itself does not have view identity to observe state).
///
/// Hybrid icon design: SF Symbols for active states (gets free `.symbolEffect`
/// animation that signals "alive"); IBM Carbon icons for static states (clean
/// branded look where animation isn't needed).
struct CoordinatorIcon: View {
    @ObservedObject var coordinator: AppCoordinator

    var body: some View {
        switch coordinator.uiState {
        case .loadingModel:
            Image("CarbonHourglass")
        case .idle:
            Image("CarbonMicrophone")
        case .recording:
            Image(systemName: "record.circle.fill")
                .symbolRenderingMode(.multicolor)
                .foregroundStyle(.red)
                .symbolEffect(.pulse, options: .repeating)
        case .transcribing:
            Image(systemName: "waveform")
                .symbolRenderingMode(.multicolor)
                .foregroundStyle(.orange)
                .symbolEffect(.variableColor, options: .repeating)
        case .permissionNeeded:
            Image("CarbonWarning")
                .foregroundStyle(.yellow)
        case .fatalError:
            Image("CarbonError")
                .foregroundStyle(.red)
        }
    }
}
