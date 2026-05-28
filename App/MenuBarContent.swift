// App/MenuBarContent.swift
import SwiftUI
import MumblurCore

struct MenuBarContent: View {
    @ObservedObject var coordinator: AppCoordinator
    @EnvironmentObject var bridge: AppCoordinator.SettingsBridge

    var body: some View {
        VStack(alignment: .leading) {
            switch coordinator.uiState {
            case .loadingModel:
                Label("Loading model…", systemImage: "hourglass")
            case .idle:
                Label("Hold Right Option to dictate", systemImage: "mic")
            case .recording:
                Label("Recording…", systemImage: "mic.fill").foregroundStyle(.red)
            case .transcribing:
                Label("Transcribing…", systemImage: "waveform")
            case .swappingModel:
                Label("Switching model…", systemImage: "arrow.triangle.2.circlepath")
            case .permissionNeeded:
                Label(coordinator.permissionMessage ?? "Grant permissions",
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            case .fatalError:
                Label(coordinator.lastError ?? "Error", systemImage: "exclamationmark.octagon")
                    .foregroundStyle(.red)
            }

            Divider()

            Menu("Profile: \(coordinator.activeProfileName)") {
                ForEach(bridge.profiles) { p in
                    Button(p.name) {
                        Task { await coordinator.switchActiveProfile(p) }
                    }
                }
            }

            Button("Settings…") {
                // macOS Tahoe 26: openSettings() requires a render tree; the hidden
                // Window trampoline (Task 25) listens for this notification and
                // calls openSettings() with proper activation-policy juggling.
                NotificationCenter.default.post(name: .openSettingsRequest, object: nil)
            }
            .keyboardShortcut(",")

            Divider()
            Button("Quit Mumblur") { coordinator.quit() }
                .keyboardShortcut("q")
        }
    }
}
