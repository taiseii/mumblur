// App/Settings/ViewModels/DataViewModel.swift
import SwiftUI
import MumblurCore

@MainActor
final class DataViewModel: ObservableObject {
    struct Deps {
        let loadStats: @MainActor () async -> TranscriptStore.Stats?
        let loadRetention: @MainActor () async -> (enabled: Bool, kind: String, value: Int)
        let setRetention: @MainActor (_ enabled: Bool, _ kind: String, _ value: Int) async -> Void
        var loadRecent: @MainActor () async -> [TranscriptStore.Row] = { [] }
        var storageRoot: URL? = nil
    }
    @Published var stats: TranscriptStore.Stats?
    @Published var recent: [TranscriptStore.Row] = []
    @Published var retentionEnabled = false
    @Published var retentionKind = "days"
    @Published var retentionValue = 30

    var storageRoot: URL? { deps.storageRoot }

    private let deps: Deps
    init(deps: Deps) { self.deps = deps }

    func load() async {
        stats = await deps.loadStats()
        recent = await deps.loadRecent()
        let r = await deps.loadRetention()
        retentionEnabled = r.enabled; retentionKind = r.kind; retentionValue = r.value
    }

    func setRetention(enabled: Bool) async {
        retentionEnabled = enabled
        await deps.setRetention(enabled, retentionKind, retentionValue)
    }
}
