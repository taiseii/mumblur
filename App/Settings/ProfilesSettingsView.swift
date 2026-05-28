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
    let profile: Profile
    var body: some View {
        Form {
            TextField("Name", text: .constant(profile.name))
            TextField("Language (BCP-47, blank = auto)", text: .constant(profile.language ?? ""))
            TextField("Model", text: .constant(profile.modelID))
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
