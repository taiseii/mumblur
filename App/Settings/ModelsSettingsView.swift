// App/Settings/ModelsSettingsView.swift
import SwiftUI
import MumblurCore

struct ModelsSettingsView: View {
    @StateObject private var vm = ModelsViewModel(deps: .live)

    var body: some View {
        VStack(alignment: .leading) {
            if vm.loading { ProgressView("Listing models…") }
            List(vm.available, id: \.self) { name in
                HStack {
                    Text(name)
                    Spacer()
                    Button("Install") { Task { await vm.install(modelID: name) } }
                }
            }
        }
        .padding()
        .task { await vm.load() }
    }
}

private extension ModelsViewModel.Deps {
    static var live: Self {
        .init(
            list: { (try? await RealWhisperKit.fetchAvailableModels()) ?? [] },
            install: { _ in /* download wiring is later polish */ })
    }
}
