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
        var loadCorrection: @MainActor (Int64) async -> String = { _ in "" }
        var upsertCorrection: @MainActor (Int64, String) async -> Void = { _, _ in }
        var deleteCorrection: @MainActor (Int64) async -> Void = { _ in }
        var storageRoot: URL? = nil
    }
    @Published var stats: TranscriptStore.Stats?
    @Published var recent: [TranscriptStore.Row] = []
    @Published var correctionText = ""
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

    /// Loads the saved correction (if any) for the selected transcript into the editable field.
    func loadCorrection(for transcriptID: Int64) async {
        correctionText = await deps.loadCorrection(transcriptID)
    }

    /// Persists the edited correction. An empty/whitespace field discards it (deletes the row)
    /// rather than storing an empty training target.
    func saveCorrection(for transcriptID: Int64) async {
        let trimmed = correctionText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            await deps.deleteCorrection(transcriptID)
            correctionText = ""
        } else {
            await deps.upsertCorrection(transcriptID, trimmed)
        }
    }
}
