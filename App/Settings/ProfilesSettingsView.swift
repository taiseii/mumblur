// App/Settings/ProfilesSettingsView.swift
import SwiftUI
import MumblurCore

struct ProfilesSettingsView: View {
    @EnvironmentObject var coordinator: AppCoordinator
    @EnvironmentObject var bridge: AppCoordinator.SettingsBridge
    @StateObject private var vm: ProfilesViewModel

    init() {
        _vm = StateObject(wrappedValue: ProfilesViewModel(coordinator: .live))
    }

    var body: some View {
        NavigationSplitView {
            List(bridge.profiles, selection: $vm.selection) { p in
                Text(p.name).tag(p.id)
            }
            .frame(minWidth: 200)
            .toolbar {
                ToolbarItemGroup {
                    Button("New") {
                        Task { _ = try? await vm.create(name: "New profile",
                            modelID: bridge.profiles.first?.modelID ?? "openai_whisper-large-v3-turbo") }
                    }
                    Button("Delete") {
                        if let id = vm.selection { Task { try? await vm.delete(id) } }
                    }
                    .disabled(vm.selection == nil)
                }
            }
        } detail: {
            if let id = vm.selection,
               let p = bridge.profiles.first(where: { $0.id == id }) {
                ProfileEditor(profile: p)
            } else {
                ContentUnavailableView("Select a profile",
                    systemImage: "person.crop.rectangle.stack")
            }
        }
    }
}

struct ProfileEditor: View {
    @EnvironmentObject var coordinator: AppCoordinator
    let profile: Profile

    private static let languages: [(name: String, code: String?)] = [
        ("Auto-detect", nil), ("English", "en"), ("Spanish", "es"), ("French", "fr"),
        ("German", "de"), ("Italian", "it"), ("Portuguese", "pt"), ("Dutch", "nl"),
        ("Japanese", "ja"), ("Chinese", "zh"), ("Korean", "ko"),
    ]

    var body: some View {
        Form {
            TextField("Name", text: .constant(profile.name))
            Picker("Language", selection: Binding(
                get: { profile.language },
                set: { newValue in
                    Task { await coordinator.setProfileLanguage(profileID: profile.id, language: newValue) }
                })) {
                ForEach(Self.languages, id: \.code) { lang in
                    Text(lang.name).tag(lang.code)
                }
            }
            LabeledContent("Model") {
                VStack(alignment: .leading, spacing: 1) {
                    Text(profile.modelID)
                    Text("Change in the Models tab").font(.caption2).foregroundStyle(.secondary)
                }
            }
            TextEditor(text: .constant(profile.initialPrompt ?? ""))
                .frame(height: 80)
            Section("Vocabulary") {
                ForEach(profile.vocab, id: \.self) { Text($0) }
            }
            Section("Replacement rules") {
                ForEach(profile.rules) { r in
                    Text("\(r.pattern) → \(r.replacement)")
                }
            }
        }
        .padding()
    }
}

private extension ProfilesViewModel.Coordinator {
    static var live: Self {
        .init(
            switchActive: { _ in /* wired in a later task */ },
            createProfile: { _, _ in throw CocoaError(.featureUnsupported) },
            softDelete: { _ in throw CocoaError(.featureUnsupported) })
    }
}
