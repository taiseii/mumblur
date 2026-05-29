// App/Settings/AISettingsView.swift
import SwiftUI
import MumblurCore

struct AISettingsView: View {
    @StateObject private var vm: AIViewModel

    init(coordinator: AppCoordinator) {
        _vm = StateObject(wrappedValue: AIViewModel(deps: .live(coordinator)))
    }

    var body: some View {
        Form {
            Section("Local LLM Server") {
                Toggle("Enable LLM editing", isOn: $vm.enabled)
                TextField("Base URL", text: $vm.baseURL)
                TextField("Model", text: $vm.model)
                Stepper("Timeout: \(vm.timeoutMs) ms", value: $vm.timeoutMs, in: 500...60_000, step: 500)
                HStack {
                    Toggle("Set max_tokens", isOn: Binding(
                        get: { vm.maxTokens != nil },
                        set: { vm.maxTokens = $0 ? (vm.maxTokens ?? 512) : nil }))
                    if vm.maxTokens != nil {
                        Stepper("\(vm.maxTokens ?? 512)",
                                value: Binding(
                                    get: { vm.maxTokens ?? 512 },
                                    set: { vm.maxTokens = $0 }),
                                in: 1...8192, step: 64)
                    }
                }
                HStack {
                    Toggle("Set temperature", isOn: Binding(
                        get: { vm.temperature != nil },
                        set: { vm.temperature = $0 ? (vm.temperature ?? 0.7) : nil }))
                    if vm.temperature != nil {
                        Slider(value: Binding(
                            get: { vm.temperature ?? 0.7 },
                            set: { vm.temperature = $0 }),
                               in: 0...2, step: 0.05)
                        Text(String(format: "%.2f", vm.temperature ?? 0.7)).monospacedDigit()
                    }
                }
                HStack {
                    Button("Save") { Task { await vm.saveGlobal() } }
                    Button("Test connection") { Task { await vm.test() } }
                    if let r = vm.testResult { Text(r).foregroundStyle(.secondary) }
                }
            }
            Section {
                DisclosureGroup("Advanced") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Extra body JSON")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("Merged into the request body (top-level). Canonical fields (model, messages, stream) cannot be overridden.")
                            .font(.caption2).foregroundStyle(.secondary)
                        TextEditor(text: $vm.extraBodyJSON).frame(minHeight: 60).font(.body.monospaced())

                        Text("Request template (advanced)")
                            .font(.caption).foregroundStyle(.secondary).padding(.top, 4)
                        Text("When set, used as the ENTIRE request body (Mode 2). Use placeholders {{model}}, {{instructions}}, {{text}}, {{max_tokens}}, {{temperature}}. Leave empty for default OpenAI Chat shape.")
                            .font(.caption2).foregroundStyle(.secondary)
                        TextEditor(text: $vm.requestTemplate).frame(minHeight: 80).font(.body.monospaced())

                        Text("Content path (JSON Pointer)")
                            .font(.caption).foregroundStyle(.secondary).padding(.top, 4)
                        TextField("/choices/0/message/content", text: $vm.contentPath).font(.body.monospaced())

                        HStack {
                            Text("Fallback path")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Use reasoning_content") {
                                vm.contentFallbackPath = "/choices/0/message/reasoning_content"
                            }
                            .controlSize(.small)
                        }
                        TextField("(optional)", text: $vm.contentFallbackPath).font(.body.monospaced())
                    }
                    .padding(.vertical, 4)
                }
            }
            Section("Per-Profile Editing") {
                Picker("Profile", selection: Binding(
                    get: { vm.selectedProfileID },
                    set: { vm.selectProfile($0) })) {
                    ForEach(vm.profiles) { p in Text(p.name).tag(Optional(p.id)) }
                }
                Toggle("Edit transcripts for this profile", isOn: $vm.profileEditEnabled)
                VStack(alignment: .leading) {
                    Text("Editing instructions").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $vm.profilePrompt).frame(minHeight: 80).font(.body.monospaced())
                }
                Button("Save profile") { Task { await vm.saveProfile() } }
            }
        }
        .formStyle(.grouped)
        .padding()
        .task { await vm.load() }
    }
}

private extension AIViewModel.Deps {
    @MainActor
    static func live(_ c: AppCoordinator) -> AIViewModel.Deps {
        AIViewModel.Deps(
            loadConfig: { await c.currentLLMServerConfig() },
            saveConfig: { await c.setLLMServerConfig($0) },
            loadProfiles: { c.settingsBridge.profiles },
            activeProfileID: { c.settingsBridge.activeProfileID },
            saveProfileAI: { await c.updateProfileAISettings(profileID: $0, enabled: $1, prompt: $2) },
            testConnection: { cfg in
                let editor = OpenAICompatibleEditor(config: cfg)
                let result = await editor.probe()
                return Self.renderProbe(result)
            })
    }

    private static func renderProbe(_ r: ProbeResult) -> String {
        switch r {
        case .success(let content):
            let snippet = content.prefix(60).replacingOccurrences(of: "\n", with: " ")
            return "Connected ✓ — got: \"\(snippet)\""
        case .successEmpty(let excerpt):
            let s = excerpt.prefix(120)
            return "Connected, but empty content — raise max_tokens or set a fallback path. Body: \(s)"
        case .disabled:
            return "Editor disabled — enable LLM editing to test"
        case .invalidURL:
            return "Failed: invalid base URL"
        case .requestBuildFailure(let reason):
            return "Failed: request build — \(reason)"
        case .httpFailure(let status, let excerpt):
            return "Failed: HTTP \(status) — \(excerpt.prefix(120))"
        case .jsonFailure(let excerpt):
            return "Failed: bad JSON — \(excerpt.prefix(120))"
        case .transportFailure(let message):
            return "Failed: \(message)"
        case .timeout:
            return "Failed: timeout"
        }
    }
}
