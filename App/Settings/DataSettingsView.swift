// App/Settings/DataSettingsView.swift
import SwiftUI
import MumblurCore

struct DataSettingsView: View {
    @StateObject private var vm = DataViewModel(deps: .live)

    var body: some View {
        Form {
            Section("Storage") {
                if let s = vm.stats {
                    LabeledContent("Transcripts", value: "\(s.count)")
                    LabeledContent("Audio clips", value: "\(s.audioCount)")
                    LabeledContent("Disk", value: "\(s.bytes / 1024) KB")
                }
                Button("Reveal in Finder") { /* later polish */ }
            }
            Section("Retention") {
                Toggle("Keep audio of each dictation", isOn: Binding(
                    get: { vm.retentionEnabled },
                    set: { on in Task { await vm.setRetention(enabled: on) } }))
                Picker("Cap by", selection: $vm.retentionKind) {
                    Text("Days").tag("days"); Text("Count").tag("count")
                }
                Stepper("Value: \(vm.retentionValue)", value: $vm.retentionValue, in: 0...10000)
            }
            Section("Export & cleanup") {
                Button("Export JSON") { }
                Button("Export CSV") { }
                Button("Delete all data") { }.foregroundStyle(.red)
            }
        }
        .padding()
        .task { await vm.load() }
    }
}

private extension DataViewModel.Deps {
    static var live: Self {
        .init(
            loadStats: { nil },
            loadRetention: { (false, "days", 30) },
            setRetention: { _, _, _ in /* persistence wiring is later polish */ })
    }
}
