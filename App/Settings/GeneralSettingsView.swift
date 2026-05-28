// App/Settings/GeneralSettingsView.swift
import SwiftUI
import MumblurCore

struct GeneralSettingsView: View {
    @EnvironmentObject var coordinator: AppCoordinator
    @EnvironmentObject var bridge: AppCoordinator.SettingsBridge

    var body: some View {
        Form {
            Picker("Active profile", selection: Binding(
                get: { bridge.pendingProfileID ?? bridge.activeProfileID ?? "" },
                set: { newID in
                    if let p = bridge.profiles.first(where: { $0.id == newID }) {
                        Task { await coordinator.switchActiveProfile(p) }
                    }
                })) {
                ForEach(bridge.profiles, id: \.id) { p in Text(p.name).tag(p.id) }
            }
            Toggle("Launch at login", isOn: Binding(
                get: { coordinator.isLaunchAtLoginEnabled },
                set: { coordinator.setLaunchAtLogin($0) }))
            LabeledContent("Hotkey", value: "Right Option (hold)")
            Text("State: \(coordinator.uiState.rawValue)")
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}
