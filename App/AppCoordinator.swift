import SwiftUI
import MumblurCore
import ServiceManagement
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

    /// Model name currently committed to the serving pipeline (nil until first load).
    @Published private(set) var servingModelID: String?
    /// Model name currently being loaded/swapped, if a swap is in flight.
    @Published private(set) var modelLoadingID: String?
    /// Model name currently downloading, if an install is in flight.
    @Published private(set) var downloadingModelID: String?
    /// Fractional download progress (0...1) for `downloadingModelID`.
    @Published private(set) var downloadProgress: Double = 0

    private let installer: ModelInstalling = WhisperKitInstaller()

    /// Where models are downloaded — kept inside the app's storage root so they
    /// live alongside the rest of the user's data.
    var modelsDownloadBase: URL? { storageRoot?.appendingPathComponent("models") }

    /// Installed built-in variants on disk (default repo). Custom-repo install
    /// state is resolved per-model in `installedModelIDs(custom:)`.
    func installedModelIDs() -> Set<String> {
        guard let base = modelsDownloadBase else { return [] }
        return installer.installedVariants(downloadBase: base, repo: WhisperKitModels.defaultRepo)
    }

    func customModels() async -> [CustomModel] {
        (try? await customModelStore?.all()) ?? []
    }

    func addCustomModel(_ model: CustomModel) async {
        try? await customModelStore?.add(model)
    }

    func removeCustomModel(id: String) async {
        try? await customModelStore?.remove(id: id)
    }

    /// Auto-install (with progress) if needed, then make `modelID` the active
    /// profile's model and reload. Used by the Models tab "Use" button.
    /// Local-folder custom models skip download; custom-repo models download
    /// from their own repo.
    func useModel(_ modelID: String) async {
        let custom = try? await customModelStore?.get(id: modelID)
        let needsDownload = custom?.kind != .folder
        let repo = custom?.repo ?? WhisperKitModels.defaultRepo

        if needsDownload, let base = modelsDownloadBase,
           !installer.installedVariants(downloadBase: base, repo: repo).contains(modelID) {
            downloadingModelID = modelID
            downloadProgress = 0
            do {
                _ = try await installer.download(
                    variant: modelID, repo: repo, downloadBase: base,
                    progress: { [weak self] p in
                        Task { @MainActor in self?.downloadProgress = p }
                    })
            } catch {
                Logger.app.error("model download failed: \(error.localizedDescription)")
                lastError = error.localizedDescription
                downloadingModelID = nil
                return
            }
            downloadingModelID = nil
        }
        await setActiveProfileModel(modelID)
    }

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
    private var customModelStore: CustomModelStore?
    private var llmEditor: OpenAICompatibleEditor?

    /// On-disk root for the SQLite DB and audio clips, once bootstrap has run.
    private(set) var storageRoot: URL?

    /// Most-recent dictations for the Data tab; empty if the store isn't ready yet.
    func recentTranscripts(limit: Int) async -> [TranscriptStore.Row] {
        guard let transcriptStore else { return [] }
        do { return try await transcriptStore.recent(limit: limit) }
        catch {
            Logger.app.error("recentTranscripts failed: \(error.localizedDescription)")
            return []
        }
    }

    /// The saved correction text for a transcript, or "" if none / store not ready.
    func correction(for transcriptID: Int64) async -> String {
        guard let transcriptStore else { return "" }
        do { return (try await transcriptStore.correction(for: transcriptID))?.correctedText ?? "" }
        catch {
            Logger.app.error("correction(for:) failed: \(error.localizedDescription)")
            return ""
        }
    }

    func upsertCorrection(transcriptID: Int64, correctedText: String) async {
        guard let transcriptStore else { return }
        do { try await transcriptStore.upsertCorrection(transcriptID: transcriptID, correctedText: correctedText) }
        catch { Logger.app.error("upsertCorrection failed: \(error.localizedDescription)") }
    }

    func deleteCorrection(transcriptID: Int64) async {
        guard let transcriptStore else { return }
        do { try await transcriptStore.deleteCorrection(transcriptID: transcriptID) }
        catch { Logger.app.error("deleteCorrection failed: \(error.localizedDescription)") }
    }

    /// Aggregate counts/sizes for the Data tab; nil if the store isn't ready yet.
    func transcriptStats() async -> TranscriptStore.Stats? {
        guard let transcriptStore else { return nil }
        do { return try await transcriptStore.stats() }
        catch {
            Logger.app.error("transcriptStats failed: \(error.localizedDescription)")
            return nil
        }
    }

    init() {
        self.perms = PermissionsCoordinator { [weak self] snap in self?.applyPermissionSnapshot(snap) }
    }

    func bootstrap() async {
        await perms.bootstrap()
        do {
            let root = try Self.applicationSupportRoot()
            self.storageRoot = root
            let db = try AppDatabase(location: .file(root.appendingPathComponent("mumblur.sqlite")))
            let settings  = SettingsStore(database: db)
            let transcripts = TranscriptStore(database: db)
            let audio = AudioStore(root: root)
            let persister = RetentionAwarePersister(database: db, transcripts: transcripts, audio: audio)
            let customModels = CustomModelStore(database: db)

            try await Self.seedDefaultProfileIfNeeded(settings: settings)
            guard let active = try await settings.activeOrFirstActive() else {
                throw NSError(domain: "AppCoordinator", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "no active profile after seed"])
            }

            let transcriber = Transcriber()
            let manager = ModelManager(
                loader: WhisperKitLoader(downloadBase: root.appendingPathComponent("models"),
                                         customModels: customModels),
                transcriber: transcriber)
            self.modelLoadingID = active.modelID
            let snap = try await manager.requestSwap(to: active)   // throws -> propagates to fatalError
            self.servingModelID = snap.modelID
            self.modelLoadingID = nil

            let llmConfig = try await settings.llmServerConfig()
            let editor = OpenAICompatibleEditor(config: llmConfig)

            let recorder = try AudioRecorder()
            let paster = Paster()
            let runner = Runner(
                recorder: recorder, transcriber: transcriber,
                paster: paster, persister: persister, editor: editor, minHoldMs: 200,
                onStateChange: { [weak self] s in
                    Task { @MainActor in self?.applyRunnerState(s) }
                })

            self.database = db; self.settingsStore = settings
            self.transcriptStore = transcripts; self.audioStore = audio
            self.persister = persister; self.customModelStore = customModels
            self.recorder = recorder; self.transcriber = transcriber
            self.manager = manager; self.runner = runner
            self.llmEditor = editor
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
        modelLoadingID = profile.modelID
        uiState = .swappingModel
        do {
            let snap = try await manager.requestSwap(to: profile)
            guard snap.profileID == profile.id else {
                settingsBridge.pendingProfileID = previouslyCommitted
                modelLoadingID = nil
                if uiState == .swappingModel { uiState = .idle }
                return
            }
            try await settings.setActiveProfileID(profile.id)
            settingsBridge.activeProfileID = profile.id
            settingsBridge.pendingProfileID = nil
            activeProfileName = profile.name
            servingModelID = snap.modelID
            modelLoadingID = nil
            if uiState == .swappingModel { uiState = .idle }
        } catch {
            Logger.app.error("swap failed: \(error.localizedDescription)")
            lastError = error.localizedDescription
            modelLoadingID = nil
            settingsBridge.pendingProfileID = previouslyCommitted
            if uiState == .swappingModel { uiState = .idle }
        }
    }

    /// Assign `modelID` to the currently-active profile and reload the pipeline.
    /// Reuses the tentative-then-commit swap: on failure the profile's model is
    /// rolled back so the serving model and stored model stay consistent.
    func setActiveProfileModel(_ modelID: String) async {
        guard let settings = settingsStore, let manager,
              let activeID = settingsBridge.activeProfileID,
              var profile = try? await settings.get(profileID: activeID),
              profile.modelID != modelID else { return }
        let previousModelID = profile.modelID
        profile.modelID = modelID
        modelLoadingID = modelID
        uiState = .swappingModel
        func rollbackStoredModel() async {
            var reverted = profile; reverted.modelID = previousModelID
            try? await settings.update(reverted)
        }
        do {
            try await settings.update(profile)
            let snap = try await manager.requestSwap(to: profile)
            guard snap.profileID == profile.id else {   // superseded by a newer swap
                await rollbackStoredModel()
                modelLoadingID = nil
                if uiState == .swappingModel { uiState = .idle }
                return
            }
            settingsBridge.profiles = try await settings.listActive()
            servingModelID = snap.modelID
            modelLoadingID = nil
            if uiState == .swappingModel { uiState = .idle }
        } catch {
            Logger.app.error("model swap failed: \(error.localizedDescription)")
            lastError = error.localizedDescription
            await rollbackStoredModel()
            modelLoadingID = nil
            if uiState == .swappingModel { uiState = .idle }
        }
    }

    /// Set a profile's decoding language (nil/"" = auto-detect, "en" = English).
    /// Persists to the DB and, if it's the active profile, live-patches the
    /// serving snapshot — no model reload needed.
    func setProfileLanguage(profileID: String, language: String?) async {
        guard let settings = settingsStore,
              var profile = try? await settings.get(profileID: profileID) else { return }
        let normalized = (language?.isEmpty == true) ? nil : language
        guard profile.language != normalized else { return }
        profile.language = normalized
        do {
            try await settings.update(profile)
            settingsBridge.profiles = try await settings.listActive()
            if profileID == settingsBridge.activeProfileID {
                await transcriber?.updateLanguage(normalized)
            }
        } catch {
            Logger.app.error("set language failed: \(error.localizedDescription)")
            lastError = error.localizedDescription
        }
    }

    /// Persist global LLM server config and hot-swap it into the live editor so
    /// URL/model/timeout/enable changes take effect immediately.
    func setLLMServerConfig(_ cfg: LLMServerConfig) async {
        guard let settings = settingsStore else { return }
        do {
            try await settings.setLLMServerConfig(cfg)
            await llmEditor?.configure(cfg)
        } catch {
            Logger.app.error("setLLMServerConfig failed: \(error.localizedDescription)")
            lastError = error.localizedDescription
        }
    }

    func currentLLMServerConfig() async -> LLMServerConfig {
        guard let settings = settingsStore else { return .default }
        return (try? await settings.llmServerConfig()) ?? .default
    }

    /// Persist a profile's LLM-edit settings. If it is the active profile, patch
    /// the live serving snapshot in place (no model reload).
    func updateProfileAISettings(profileID: String, enabled: Bool, prompt: String?) async {
        guard let settings = settingsStore,
              var profile = try? await settings.get(profileID: profileID) else { return }
        profile.llmEditEnabled = enabled
        profile.llmEditPrompt = prompt
        do {
            try await settings.update(profile)
            settingsBridge.profiles = try await settings.listActive()
            if settingsBridge.activeProfileID == profileID {
                let trimmed = prompt?.trimmingCharacters(in: .whitespacesAndNewlines)
                let resolved = (trimmed?.isEmpty ?? true) ? LLMEditConfig.defaultPrompt : trimmed!
                await transcriber?.updateLLMEdit(
                    LLMEditConfig(enabled: enabled, prompt: resolved))
            }
        } catch {
            Logger.app.error("updateProfileAISettings failed: \(error.localizedDescription)")
            lastError = error.localizedDescription
        }
    }

    func quit() {
        runner?.shutdown(); hotkey?.stop()
        NSApplication.shared.terminate(nil)
    }

    var isLaunchAtLoginEnabled: Bool { SMAppService.mainApp.status == .enabled }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() }
            else  { try SMAppService.mainApp.unregister() }
        } catch {
            Logger.app.error("launch-at-login toggle failed: \(error.localizedDescription)")
            lastError = error.localizedDescription
        }
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
            _ = try await settings.create(name: "Default", modelID: "openai_whisper-large-v3-turbo",
                                          language: "en")
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
    let downloadBase: URL?
    let customModels: CustomModelStore?

    func load(modelID: String) async throws -> LoadedModel {
        var custom: CustomModel?
        if let store = customModels { custom = try? await store.get(id: modelID) }
        let kit: RealWhisperKit
        switch custom?.kind {
        case .folder:
            kit = try await RealWhisperKit.make(modelFolder: URL(fileURLWithPath: custom?.folderPath ?? ""))
        case .repo:
            kit = try await RealWhisperKit.make(variant: custom!.id,
                                                repo: custom?.repo ?? WhisperKitModels.defaultRepo,
                                                downloadBase: downloadBase)
        case nil:
            kit = try await RealWhisperKit.make(modelHint: modelID, downloadBase: downloadBase)
        }
        return LoadedModel(kit: kit, tokenizer: WhisperKitTokenizer(kit: kit))
    }
}

private struct WhisperKitTokenizer: Tokenizing {
    let kit: RealWhisperKit
    func encode(text: String) throws -> [Int] { try kit.encode(text: text) }
}
