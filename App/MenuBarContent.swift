import SwiftUI

struct MenuBarContent: View {
    @ObservedObject var coordinator: AppCoordinator

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
                Label(coordinator.lastError ?? "Error",
                      systemImage: "exclamationmark.octagon")
                    .foregroundStyle(.red)
            }
            Divider()
            Button("Quit Mumblur") { coordinator.quit() }
                .keyboardShortcut("q")
        }
    }
}
