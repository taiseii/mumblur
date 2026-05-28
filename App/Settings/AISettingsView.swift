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
                    Button("Save") { Task { await vm.saveGlobal() } }
                    Button("Test connection") { Task { await vm.test() } }
                    if let r = vm.testResult { Text(r).foregroundStyle(.secondary) }
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
                do {
                    let out = try await editor.editFailOpen("ping", instructions: "Reply with: ok")
                    return out == "ping" ? "No response (check server/model)" : "Connected ✓"
                } catch { return "Failed: \(error.localizedDescription)" }
            })
    }
}
