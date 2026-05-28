// App/Settings/ViewModels/ModelsViewModel.swift
import SwiftUI
import MumblurCore

@MainActor
final class ModelsViewModel: ObservableObject {
    struct Deps {
        let list: @MainActor () async -> [String]
        let install: @MainActor (_ modelID: String) async -> Void
    }
    @Published var available: [String] = []
    @Published var loading = true

    private let deps: Deps
    init(deps: Deps) { self.deps = deps }

    func load() async { available = await deps.list(); loading = false }
    func install(modelID: String) async { await deps.install(modelID) }
}
