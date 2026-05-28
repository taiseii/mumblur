// App/Settings/ViewModels/ModelsViewModel.swift
import SwiftUI
import MumblurCore

@MainActor
final class ModelsViewModel: ObservableObject {
    struct ModelRow: Identifiable, Sendable, Equatable {
        let id: String              // WhisperKit model name / variant
        var installed: Bool = false
        var isCustom: Bool = false
        var detail: String? = nil   // repo id or local folder, for custom entries
    }
    struct Deps {
        let list: @MainActor () async -> [ModelRow]
        let use: @MainActor (_ modelID: String) async -> Void
        var addCustom: @MainActor (_ model: CustomModel) async -> Void = { _ in }
        var removeCustom: @MainActor (_ id: String) async -> Void = { _ in }
    }
    @Published var rows: [ModelRow] = []
    @Published var loading = true
    @Published var busyModelID: String?   // a Use action (download + swap) in flight

    private let deps: Deps
    init(deps: Deps) { self.deps = deps }

    func load() async { rows = await deps.list(); loading = false }

    func use(_ modelID: String) async {
        busyModelID = modelID
        await deps.use(modelID)
        rows = await deps.list()   // refresh installed badges after a possible download
        busyModelID = nil
    }

    func addCustom(_ model: CustomModel) async {
        await deps.addCustom(model)
        rows = await deps.list()
    }

    func removeCustom(_ id: String) async {
        await deps.removeCustom(id)
        rows = await deps.list()
    }
}
