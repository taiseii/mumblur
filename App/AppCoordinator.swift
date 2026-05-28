import SwiftUI
import MumblurCore
import os

@MainActor
final class AppCoordinator: ObservableObject {
    enum UIState: String, Sendable {
        case loadingModel       // first-launch cold start
        case idle
        case recording
        case transcribing
        case swappingModel      // active profile changed; new model is loading
        case permissionNeeded
        case fatalError
    }

    @Published var uiState: UIState = .loadingModel
    @Published var permissionMessage: String?
    @Published var lastError: String?
    @Published private(set) var activeProfileName: String = "Default"

    @MainActor
    final class SettingsBridge: ObservableObject {
        @Published var profiles: [Profile] = []
        @Published var activeProfileID: String?     // committed
        @Published var pendingProfileID: String?    // tentative during a swap
    }
    let settingsBridge = SettingsBridge()

    private var runner: Runner?
    private var hotkey: HotkeyListening?
    private var recorder: AudioRecording?
    private var transcriber: Transcriber?
    private var manager: ModelManager?
    private var perms: PermissionsCoordinator!

    // Stores
    private var database: AppDatabase?
    private var settingsStore: SettingsStore?
    private var transcriptStore: TranscriptStore?
    private var audioStore: AudioStore?
    private var persister: RetentionAwarePersister?

    init() {
        self.perms = PermissionsCoordinator { [weak self] snap in self?.applyPermissionSnapshot(snap) }
    }

    func bootstrap() async {
        await perms.bootstrap()
        do {
            let root = try Self.applicationSupportRoot()
            let db = try AppDatabase(location: .file(root.appendingPathComponent("mumblur.sqlite")))
            let settings  = SettingsStore(database: db)
            let transcripts = TranscriptStore(database: db)
            let audio = AudioStore(root: root)
            let persister = RetentionAwarePersister(database: db, transcripts: transcripts, audio: audio)

            try await Self.seedDefaultProfileIfNeeded(settings: settings)
            guard let active = try await settings.activeOrFirstActive() else {
                throw NSError(domain: "AppCoordinator", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "no active profile after seed"])
            }

            let transcriber = Transcriber()
            let manager = ModelManager(loader: WhisperKitLoader(), transcriber: transcriber)
            _ = try await manager.requestSwap(to: active)   // throws -> propagates to fatalError

            let recorder = try AudioRecorder()
            let paster = Paster()
            let runner = Runner(
                recorder: recorder, transcriber: transcriber,
                paster: paster, persister: persister, minHoldMs: 200,
                onStateChange: { [weak self] s in
                    Task { @MainActor in self?.applyRunnerState(s) }
                })

            self.database = db; self.settingsStore = settings
            self.transcriptStore = transcripts; self.audioStore = audio
            self.persister = persister
            self.recorder = recorder; self.transcriber = transcriber
            self.manager = manager; self.runner = runner
            self.activeProfileName = active.name

            settingsBridge.profiles = try await settings.listActive()
            settingsBridge.activeProfileID = active.id
            settingsBridge.pendingProfileID = nil

            // Orphan cleanup at launch (only deletes WAVs not referenced by any row).
            try await audio.cleanupOrphans(referencedRelPaths: {
                try await transcripts.allAudioRelPaths()
            })

            if uiState != .permissionNeeded { tryStartHotkey() }
            if uiState == .loadingModel { uiState = .idle }
        } catch {
            Logger.app.error("bootstrap failed: \(error.localizedDescription)")
            self.lastError = error.localizedDescription
            self.uiState = .fatalError
        }
    }

    /// Tentative-then-commit profile switch.
    /// 1. UI shows `.swappingModel` with `pendingProfileID = profile.id`.
    /// 2. Awaits `manager.requestSwap(to:)`.
    /// 3. ON SUCCESS — commit: write `app_setting.active_profile_id`, publish the
    ///    new `activeProfileID`, clear `pendingProfileID`.
    /// 4. ON FAILURE (load error or `.staleSwap`) — roll back: restore
    ///    `pendingProfileID = previously-committed`, surface `lastError`.
    func switchActiveProfile(_ profile: Profile) async {
        guard let settings = settingsStore, let manager else { return }
        let previouslyCommitted = settingsBridge.activeProfileID
        settingsBridge.pendingProfileID = profile.id
        uiState = .swappingModel
        do {
            let snap = try await manager.requestSwap(to: profile)
            guard snap.profileID == profile.id else {
                settingsBridge.pendingProfileID = previouslyCommitted
                if uiState == .swappingModel { uiState = .idle }
                return
            }
            try await settings.setActiveProfileID(profile.id)
            settingsBridge.activeProfileID = profile.id
            settingsBridge.pendingProfileID = nil
            activeProfileName = profile.name
            if uiState == .swappingModel { uiState = .idle }
        } catch {
            Logger.app.error("swap failed: \(error.localizedDescription)")
            lastError = error.localizedDescription
            settingsBridge.pendingProfileID = previouslyCommitted
            if uiState == .swappingModel { uiState = .idle }
        }
    }

    func quit() {
        runner?.shutdown(); hotkey?.stop()
        NSApplication.shared.terminate(nil)
    }

    var icon: String {
        switch uiState {
        case .loadingModel:     return "hourglass"
        case .idle:             return "mic"
        case .recording:        return "mic.fill"
        case .transcribing:     return "waveform"
        case .swappingModel:    return "arrow.triangle.2.circlepath"
        case .permissionNeeded: return "exclamationmark.triangle"
        case .fatalError:       return "exclamationmark.octagon"
        }
    }

    // MARK: - Helpers

    private static func applicationSupportRoot() throws -> URL {
        let fm = FileManager.default
        let base = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                              appropriateFor: nil, create: true)
        let root = base.appendingPathComponent("Mumblur", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func seedDefaultProfileIfNeeded(settings: SettingsStore) async throws {
        if try await settings.listActive().isEmpty {
            _ = try await settings.create(name: "Default", modelID: "openai_whisper-large-v3-turbo")
        }
        if try await settings.activeProfileID() == nil,
           let first = try await settings.listActive().first {
            try await settings.setActiveProfileID(first.id)
        }
    }

    private func tryStartHotkey() {
        guard let runner, hotkey == nil else { return }
        let hk = Hotkey { event in
            switch event {
            case .press:   runner.onPress()
            case .release: runner.onRelease()
            }
        }
        do { try hk.start(); self.hotkey = hk }
        catch {
            uiState = .permissionNeeded
            permissionMessage = "Grant Accessibility and Input Monitoring to Mumblur."
        }
    }

    private func applyPermissionSnapshot(_ snap: PermissionsCoordinator.Snapshot) {
        if !snap.allGranted {
            uiState = .permissionNeeded
            var missing: [String] = []
            if snap.microphone     != .granted { missing.append("Microphone") }
            if snap.accessibility  != .granted { missing.append("Accessibility") }
            if snap.inputMonitoring != .granted { missing.append("Input Monitoring") }
            permissionMessage = "Grant: " + missing.joined(separator: ", ")
            return
        }
        permissionMessage = nil
        if runner != nil && hotkey == nil { tryStartHotkey() }
        if uiState == .permissionNeeded { uiState = .idle }
    }

    private func applyRunnerState(_ s: Runner.State) {
        switch s {
        case .idle:         if uiState != .swappingModel { uiState = .idle }
        case .recording:    uiState = .recording
        case .stopping:     uiState = .transcribing
        case .transcribing: uiState = .transcribing
        }
    }
}

private struct WhisperKitLoader: ModelLoading {
    func load(modelID: String) async throws -> LoadedModel {
        let kit = try await RealWhisperKit.make(modelHint: modelID)
        return LoadedModel(kit: kit, tokenizer: WhisperKitTokenizer(kit: kit))
    }
}

private struct WhisperKitTokenizer: Tokenizing {
    let kit: RealWhisperKit
    func encode(text: String) throws -> [Int] { try kit.encode(text: text) }
}
