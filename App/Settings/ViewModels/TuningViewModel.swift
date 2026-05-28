// App/Settings/ViewModels/TuningViewModel.swift
import SwiftUI
import MumblurCore

@MainActor
final class TuningViewModel: ObservableObject {
    struct RunSummary: Identifiable, Sendable {
        let id: Int64
        let startedAt: Date
        let evalFinalWER: Double?
        let evalRawWER: Double?
    }
    struct Deps {
        let startCalibration: @MainActor () async -> Void
        let loadRuns: @MainActor () async -> [RunSummary]
    }
    @Published var runs: [RunSummary] = []

    private let deps: Deps
    init(deps: Deps) { self.deps = deps }

    func start() async { await deps.startCalibration() }
    func load() async { runs = await deps.loadRuns() }
}
