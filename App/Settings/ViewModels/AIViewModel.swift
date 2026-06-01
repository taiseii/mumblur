// App/Settings/ViewModels/AIViewModel.swift
import SwiftUI
import MumblurCore

@MainActor
final class AIViewModel: ObservableObject {
    struct Deps {
        let loadConfig: @MainActor () async -> LLMServerConfig
        let saveConfig: @MainActor (_ cfg: LLMServerConfig) async -> Void
        let loadProfiles: @MainActor () async -> [Profile]
        let activeProfileID: @MainActor () -> String?
        let saveProfileAI: @MainActor (_ id: String, _ enabled: Bool, _ prompt: String?) async -> Void
        let testConnection: @MainActor (_ cfg: LLMServerConfig) async -> String
    }

    @Published var enabled = false
    @Published var baseURL = "http://localhost:8080"
    @Published var model = ""
    @Published var timeoutMs = 5000
    @Published var maxTokens: Int?           = nil
    @Published var temperature: Double?      = nil
    @Published var extraBodyJSON: String     = ""
    @Published var requestTemplate: String  = ""
    @Published var contentPath: String      = "/choices/0/message/content"
    @Published var contentFallbackPath: String = ""
    @Published var profiles: [Profile] = []
    @Published var selectedProfileID: String?
    @Published var profileEditEnabled = false
    @Published var profilePrompt = ""
    @Published var testResult: String?

    private let deps: Deps
    init(deps: Deps) { self.deps = deps }

    func load() async {
        let cfg = await deps.loadConfig()
        enabled = cfg.enabled; baseURL = cfg.baseURL; model = cfg.model; timeoutMs = cfg.timeoutMs
        maxTokens = cfg.maxTokens
        temperature = cfg.temperature
        extraBodyJSON = cfg.extraBodyJSON
        requestTemplate = cfg.requestTemplate
        contentPath = cfg.contentPath
        contentFallbackPath = cfg.contentFallbackPath
        profiles = await deps.loadProfiles()
        selectedProfileID = selectedProfileID ?? deps.activeProfileID() ?? profiles.first?.id
        syncProfileFields()
    }

    func saveGlobal() async {
        await deps.saveConfig(LLMServerConfig(
            enabled: enabled, baseURL: baseURL, model: model, timeoutMs: timeoutMs,
            maxTokens: maxTokens, temperature: temperature,
            extraBodyJSON: extraBodyJSON, requestTemplate: requestTemplate,
            contentPath: contentPath, contentFallbackPath: contentFallbackPath))
    }

    func selectProfile(_ id: String?) { selectedProfileID = id; syncProfileFields() }

    func saveProfile() async {
        guard let id = selectedProfileID else { return }
        // If the user hasn't changed the prefilled default, persist nil so the
        // stored value tracks the evolving default instead of pinning a snapshot.
        let trimmed = profilePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let payload: String?
        if trimmed.isEmpty || trimmed == LLMEditConfig.defaultPrompt {
            payload = nil
        } else {
            payload = profilePrompt
        }
        await deps.saveProfileAI(id, profileEditEnabled, payload)
        profiles = await deps.loadProfiles()
    }

    /// Restore the editor instructions to the canonical default. Persists on Save.
    func resetPromptToDefault() {
        profilePrompt = LLMEditConfig.defaultPrompt
    }

    /// True when the editor's current text matches the stored default (whitespace-trimmed).
    var promptIsDefault: Bool {
        profilePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            == LLMEditConfig.defaultPrompt
    }

    func test() async {
        testResult = "Testing…"
        testResult = await deps.testConnection(
            LLMServerConfig(enabled: true, baseURL: baseURL, model: model, timeoutMs: timeoutMs,
                            maxTokens: maxTokens, temperature: temperature,
                            extraBodyJSON: extraBodyJSON, requestTemplate: requestTemplate,
                            contentPath: contentPath, contentFallbackPath: contentFallbackPath))
    }

    private func syncProfileFields() {
        let p = profiles.first { $0.id == selectedProfileID }
        profileEditEnabled = p?.llmEditEnabled ?? false
        // An empty stored value means "use the runtime default". Show the actual
        // default in the editor so the user can see what's being asked of the model.
        let stored = (p?.llmEditPrompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        profilePrompt = stored.isEmpty ? LLMEditConfig.defaultPrompt : stored
    }
}
