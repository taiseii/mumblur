// App/Settings/DataSettingsView.swift
import SwiftUI
import MumblurCore

struct DataSettingsView: View {
    @StateObject private var vm: DataViewModel
    @State private var selection: TranscriptStore.Row.ID?

    init(coordinator: AppCoordinator) {
        _vm = StateObject(wrappedValue: DataViewModel(deps: .live(coordinator)))
    }

    var body: some View {
        NavigationSplitView {
            List(vm.recent, selection: $selection) { row in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(row.startedAt, format: .dateTime.month().day().hour().minute())
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if let name = row.profileNameSnapshot {
                            Text(name).font(.caption).foregroundStyle(.secondary)
                        }
                        if row.audioRelPath != nil {
                            Image(systemName: "waveform").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Text(row.finalText.isEmpty ? "(empty)" : row.finalText)
                        .lineLimit(1).truncationMode(.tail)
                }
                .tag(row.id)
            }
            .frame(minWidth: 240)
            .overlay {
                if vm.recent.isEmpty {
                    ContentUnavailableView("No dictations yet",
                        systemImage: "text.badge.xmark",
                        description: Text("Past dictations will appear here once you record."))
                }
            }
        } detail: {
            if let id = selection, let row = vm.recent.first(where: { $0.id == id }) {
                TranscriptDetail(row: row, storageRoot: vm.storageRoot, vm: vm)
            } else {
                ContentUnavailableView("Select a dictation", systemImage: "doc.text")
            }
        }
        .safeAreaInset(edge: .bottom) { storageFooter }
        .task { await vm.load() }
    }

    private var storageFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            if let s = vm.stats {
                HStack(spacing: 16) {
                    Label("\(s.count) transcripts", systemImage: "doc.text")
                    Label("\(s.audioCount) audio clips", systemImage: "waveform")
                    Label(Self.byteFormatter.string(fromByteCount: s.bytes), systemImage: "internaldrive")
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            if let root = vm.storageRoot {
                HStack {
                    Text(root.path).font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    Spacer()
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([root])
                    }
                    .controlSize(.small)
                }
            }
            Text("Audio is kept only when retention is enabled (off by default).")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.horizontal).padding(.bottom, 8)
        .background(.bar)
    }

    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter(); f.countStyle = .file; return f
    }()
}

private struct TranscriptDetail: View {
    let row: TranscriptStore.Row
    let storageRoot: URL?
    @ObservedObject var vm: DataViewModel

    private var summary: TextDiff.Summary {
        TextDiff.summarize(raw: row.rawText, final: row.finalText)
    }

    private var diffSpans: [TextDiff.Span] {
        TextDiff.wordDiff(from: row.rawText, to: row.finalText)
    }

    private static func chars(_ n: Int) -> String {
        "\(n) char\(n == 1 ? "" : "s")"
    }

    private var rawHeader: String {
        "Raw input (Whisper) — \(Self.chars(summary.rawChars))"
    }

    private var correctedHeader: String {
        let base = "Corrected (AI edit + rules) — \(Self.chars(summary.finalChars))"
        guard summary.delta != 0 else { return base }
        // Use the en-dash form "−12" / "+5" so the sign is unambiguous at a glance.
        let sign = summary.delta > 0 ? "+" : "−"
        return "\(base) (\(sign)\(abs(summary.delta)))"
    }

    private var diffAttributed: AttributedString {
        var out = AttributedString()
        for span in diffSpans {
            switch span {
            case .equal(let s):
                out.append(AttributedString(s))
            case .added(let s):
                var added = AttributedString(s)
                added.foregroundColor = .green
                added.underlineStyle = .single
                out.append(added)
            case .removed(let s):
                var removed = AttributedString(s)
                removed.foregroundColor = .red
                removed.strikethroughStyle = .single
                out.append(removed)
            }
        }
        return out
    }

    var body: some View {
        Form {
            Section(rawHeader) {
                Text(row.rawText.isEmpty ? "(empty)" : row.rawText)
                    .textSelection(.enabled).foregroundStyle(.secondary)
            }
            Section(correctedHeader) {
                if row.finalText.isEmpty {
                    Text("(empty)")
                } else if summary.isUnchanged {
                    Label("No changes applied", systemImage: "equal.circle")
                        .foregroundStyle(.secondary).font(.caption)
                } else {
                    Text(diffAttributed).textSelection(.enabled)
                    Text("Red strikethrough = removed by editor. Green underline = added.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Section("Correction") {
                TextEditor(text: $vm.correctionText)
                    .frame(minHeight: 72)
                    .font(.body)
                HStack(alignment: .firstTextBaseline) {
                    Text("Your intended text — used to tune the model. Clear to discard.")
                        .font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Button("Save") { Task { await vm.saveCorrection(for: row.id) } }
                        .keyboardShortcut("s", modifiers: .command)
                }
            }
            Section("Details") {
                LabeledContent("When", value: row.startedAt.formatted(date: .abbreviated, time: .standard))
                LabeledContent("Duration", value: String(format: "%.1fs", Double(row.durationMs) / 1000.0))
                LabeledContent("Profile", value: row.profileNameSnapshot ?? "—")
                LabeledContent("Model", value: row.modelID)
                LabeledContent("Language", value: row.language ?? "auto")
                if let prompt = row.promptSnapshot, !prompt.isEmpty {
                    LabeledContent("Prompt", value: prompt)
                }
            }
            Section("Audio") {
                if let rel = row.audioRelPath {
                    LabeledContent("File", value: rel)
                    if let bytes = row.audioBytes {
                        LabeledContent("Size",
                            value: ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                    }
                    if let root = storageRoot {
                        Button("Reveal audio in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([root.appendingPathComponent(rel)])
                        }
                    }
                } else {
                    Text("No audio (retention was off for this dictation).")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .task(id: row.id) { await vm.loadCorrection(for: row.id) }
    }
}

private extension DataViewModel.Deps {
    @MainActor static func live(_ coordinator: AppCoordinator) -> Self {
        .init(
            loadStats: { await coordinator.transcriptStats() },
            loadRetention: { (false, "days", 30) },           // retention wiring is a later task
            setRetention: { _, _, _ in /* later task */ },
            loadRecent: { await coordinator.recentTranscripts(limit: 200) },
            loadCorrection: { id in await coordinator.correction(for: id) },
            upsertCorrection: { id, text in await coordinator.upsertCorrection(transcriptID: id, correctedText: text) },
            deleteCorrection: { id in await coordinator.deleteCorrection(transcriptID: id) },
            storageRoot: coordinator.storageRoot)
    }
}
