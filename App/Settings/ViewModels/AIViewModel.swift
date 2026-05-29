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
        await deps.saveProfileAI(id, profileEditEnabled,
                                 profilePrompt.isEmpty ? nil : profilePrompt)
        profiles = await deps.loadProfiles()
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
        profilePrompt = p?.llmEditPrompt ?? ""
    }
}
