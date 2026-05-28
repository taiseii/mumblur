// App/Settings/SettingsScene.swift
import SwiftUI

struct SettingsScene: View {
    @EnvironmentObject var coordinator: AppCoordinator

    var body: some View {
        TabView {
            GeneralSettingsView()  .tabItem { Label("General",  systemImage: "gearshape") }
            ProfilesSettingsView() .tabItem { Label("Profiles", systemImage: "person.crop.rectangle.stack") }
            ModelsSettingsView()   .tabItem { Label("Models",   systemImage: "shippingbox") }
            TuningSettingsView()   .tabItem { Label("Tuning",   systemImage: "waveform.path.ecg") }
            DataSettingsView()     .tabItem { Label("Data",     systemImage: "internaldrive") }
            AboutSettingsView()    .tabItem { Label("About",    systemImage: "info.circle") }
        }
        .frame(width: 720, height: 460)
        .environmentObject(coordinator)
    }
}
