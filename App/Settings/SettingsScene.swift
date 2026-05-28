// App/Settings/SettingsScene.swift
import SwiftUI

struct SettingsScene: View {
    @EnvironmentObject var coordinator: AppCoordinator
    @EnvironmentObject var bridge: AppCoordinator.SettingsBridge

    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General",  systemImage: "gearshape") }
            ProfilesSettingsView()
                .tabItem { Label("Profiles", systemImage: "person.crop.rectangle.stack") }
            // Models / Tuning / Data / About come in Task 26.
        }
        .frame(width: 720, height: 460)
    }
}
