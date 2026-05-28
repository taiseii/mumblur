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
    private var perms: PermissionsCoordinator!

    init() {
        // Two-phase: build perms with a callback, then trigger bootstrap.
        self.perms = PermissionsCoordinator { [weak self] snap in
            self?.applyPermissionSnapshot(snap)
        }
    }

    func bootstrap() async {
        await perms.bootstrap()
        do {
            let kit = try await RealWhisperKit.make()
            // Temporary bridge for Tasks 18-19 — replaced in Task 21 with real
            // profile + ServingSnapshot wiring.
            let core = Transcriber()
            await core.commit(
                snapshot: ServingSnapshot(profileID: "default", profileName: "Default",
                                          modelID: "default", language: nil,
                                          prompt: .empty, rules: []),
                kit: kit)
            let transcriber = TranscribingBridge(inner: core)
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
            // Hotkey start is gated on permissions in applyPermissionSnapshot.
            if uiState != .permissionNeeded { tryStartHotkey() }
            if uiState == .loadingModel { uiState = .idle }
        } catch {
            Logger.app.error("bootstrap failed: \(error.localizedDescription)")
            self.lastError = error.localizedDescription
            self.uiState = .fatalError
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

    // MARK: - Private

    private func tryStartHotkey() {
        guard let runner, hotkey == nil else { return }
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

    private func applyPermissionSnapshot(_ snap: PermissionsCoordinator.Snapshot) {
        if !snap.allGranted {
            uiState = .permissionNeeded
            var missing: [String] = []
            if snap.microphone != .granted        { missing.append("Microphone") }
            if snap.accessibility != .granted     { missing.append("Accessibility") }
            if snap.inputMonitoring != .granted   { missing.append("Input Monitoring") }
            permissionMessage = "Grant: " + missing.joined(separator: ", ")
            return
        }
        permissionMessage = nil
        // All granted — start hotkey if we have a runner.
        if runner != nil && hotkey == nil {
            tryStartHotkey()
        }
        if uiState == .permissionNeeded { uiState = .idle }
    }

    private func applyRunnerState(_ s: Runner.State) {
        switch s {
        case .idle:         uiState = .idle
        case .recording:    uiState = .recording
        case .stopping:     uiState = .transcribing
        case .transcribing: uiState = .transcribing
        }
    }
}

/// Temporary bridge for Tasks 18-19 — removed in Task 21 when AppCoordinator
/// gets real profile + ServingSnapshot wiring. Adapts the snapshot-based
/// `Transcriber` to the legacy `Transcribing` (string-returning) interface `Runner` expects.
private actor TranscribingBridge: Transcribing {
    private let inner: Transcriber
    init(inner: Transcriber) { self.inner = inner }
    func transcribe(_ samples: [Float]) async throws -> String {
        try await inner.transcribe(samples).rawText
    }
}
