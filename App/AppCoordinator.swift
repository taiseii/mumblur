import SwiftUI
import MumblurCore
import os

@MainActor
final class AppCoordinator: ObservableObject {
    enum UIState: String {
        case loadingModel
        case idle
        case recording
        case transcribing
        case permissionNeeded
        case fatalError
    }

    @Published var uiState: UIState = .loadingModel
    @Published var permissionMessage: String?
    @Published var lastError: String?

    private var runner: Runner?
    private var hotkey: HotkeyListening?
    private var recorder: AudioRecording?
    private var transcriber: Transcribing?

    func bootstrap() async {
        await PermissionGate.ensureMicrophone()
        _ = PermissionGate.ensureAccessibility(prompt: true)
        _ = PermissionGate.ensureInputMonitoring(prompt: true)

        do {
            let kit = try await RealWhisperKit.make()
            let transcriber = Transcriber(kit: kit, language: nil)
            let recorder = try AudioRecorder()
            let paster = Paster()

            let runner = Runner(
                recorder: recorder,
                transcriber: transcriber,
                paster: paster,
                minHoldMs: 200,
                onStateChange: { [weak self] state in
                    Task { @MainActor in self?.applyRunnerState(state) }
                }
            )
            self.recorder = recorder
            self.transcriber = transcriber
            self.runner = runner
            self.uiState = .idle
            tryStartHotkey()
        } catch {
            Logger.app.error("bootstrap failed: \(error.localizedDescription)")
            self.lastError = error.localizedDescription
            self.uiState = .fatalError
        }
    }

    func tryStartHotkey() {
        guard let runner else { return }
        let hk = Hotkey { event in
            switch event {
            case .press:   runner.onPress()
            case .release: runner.onRelease()
            }
        }
        do {
            try hk.start()
            self.hotkey = hk
            Logger.app.info("hotkey started")
        } catch {
            Logger.app.error("hotkey start failed: \(error.localizedDescription)")
            self.uiState = .permissionNeeded
            self.permissionMessage = "Grant Accessibility and Input Monitoring to Mumblur."
        }
    }

    func quit() {
        runner?.shutdown()
        hotkey?.stop()
        NSApplication.shared.terminate(nil)
    }

    var icon: String {
        switch uiState {
        case .loadingModel:     return "hourglass"
        case .idle:             return "mic"
        case .recording:        return "mic.fill"
        case .transcribing:     return "waveform"
        case .permissionNeeded: return "exclamationmark.triangle"
        case .fatalError:       return "exclamationmark.octagon"
        }
    }

    private func applyRunnerState(_ s: Runner.State) {
        switch s {
        case .idle:         uiState = .idle
        case .recording:    uiState = .recording
        case .stopping:     uiState = .transcribing      // collapse for UI
        case .transcribing: uiState = .transcribing
        }
    }
}
