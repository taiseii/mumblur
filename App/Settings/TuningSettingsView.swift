// App/Settings/TuningSettingsView.swift
import SwiftUI
import Charts
import MumblurCore

struct TuningSettingsView: View {
    @StateObject private var vm = TuningViewModel(deps: .live)

    var body: some View {
        VStack(alignment: .leading) {
            Text("Calibration").font(.headline)
            Text("Read a script; we measure WER on a held-out evaluation set and propose vocab/rules. We tune the prompt and post-processing rules, not the model weights.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button("Start calibration") { Task { await vm.start() } }
                .padding(.vertical, 8)

            if !vm.runs.isEmpty {
                Chart(vm.runs) { r in
                    if let v = r.evalFinalWER {
                        LineMark(x: .value("Run", r.startedAt), y: .value("WER", v))
                    }
                }
                .frame(height: 180)
            }
        }
        .padding()
        .task { await vm.load() }
    }
}

private extension TuningViewModel.Deps {
    static var live: Self {
        .init(
            startCalibration: { /* ceremony wiring is later polish */ },
            loadRuns: { [] })
    }
}
