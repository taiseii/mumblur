// App/Settings/ModelsSettingsView.swift
import SwiftUI
import MumblurCore

struct ModelsSettingsView: View {
    @EnvironmentObject var coordinator: AppCoordinator
    @StateObject private var vm: ModelsViewModel
    @State private var showingAdd = false

    init(coordinator: AppCoordinator) {
        _vm = StateObject(wrappedValue: ModelsViewModel(deps: .live(coordinator)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("The active profile (\(coordinator.activeProfileName)) uses the selected model.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { showingAdd = true } label: { Label("Add custom…", systemImage: "plus") }
            }
            if vm.loading {
                ProgressView("Listing models…")
            }
            List(vm.rows) { row in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(row.id)
                            if row.isCustom {
                                Text("custom").font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(.quaternary, in: Capsule())
                            }
                        }
                        Text(detail(for: row)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    status(for: row)
                }
                .contextMenu {
                    if row.isCustom {
                        Button("Remove custom model", role: .destructive) {
                            Task { await vm.removeCustom(row.id) }
                        }
                    }
                }
            }
        }
        .padding()
        .task { await vm.load() }
        .sheet(isPresented: $showingAdd) {
            AddCustomModelSheet { model in
                Task { await vm.addCustom(model) }
            }
        }
    }

    private func detail(for row: ModelsViewModel.ModelRow) -> String {
        if let d = row.detail { return d }
        return row.installed ? "Installed" : "Not downloaded"
    }

    @ViewBuilder
    private func status(for row: ModelsViewModel.ModelRow) -> some View {
        if coordinator.servingModelID == row.id {
            Label("Serving", systemImage: "checkmark.circle.fill")
                .labelStyle(.titleAndIcon).foregroundStyle(.green).font(.caption)
        } else if coordinator.downloadingModelID == row.id {
            HStack(spacing: 6) {
                ProgressView(value: coordinator.downloadProgress).frame(width: 80)
                Text("\(Int(coordinator.downloadProgress * 100))%")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        } else if coordinator.modelLoadingID == row.id || vm.busyModelID == row.id {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Loading…").font(.caption).foregroundStyle(.secondary)
            }
        } else {
            Button(row.installed ? "Use" : "Download & Use") { Task { await vm.use(row.id) } }
                .disabled(vm.busyModelID != nil || coordinator.modelLoadingID != nil
                          || coordinator.downloadingModelID != nil)
        }
    }
}

private struct AddCustomModelSheet: View {
    enum Kind: String, CaseIterable, Identifiable { case repo = "Hugging Face repo", folder = "Local folder"; var id: String { rawValue } }
    @Environment(\.dismiss) private var dismiss
    let onAdd: (CustomModel) -> Void

    @State private var kind: Kind = .repo
    @State private var repo = ""
    @State private var variant = ""
    @State private var folderPath = ""
    @State private var folderName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add a custom model").font(.headline)
            Picker("Source", selection: $kind) {
                ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)

            switch kind {
            case .repo:
                TextField("Hugging Face repo (e.g. argmaxinc/whisperkit-coreml)", text: $repo)
                TextField("Model variant (e.g. openai_whisper-small)", text: $variant)
                Text("The variant is downloaded from the repo on first use.")
                    .font(.caption).foregroundStyle(.secondary)
            case .folder:
                HStack {
                    TextField("CoreML model folder", text: $folderPath).disabled(true)
                    Button("Choose…") { chooseFolder() }
                }
                if !folderName.isEmpty {
                    Text("Will appear as “\(folderName)”.").font(.caption).foregroundStyle(.secondary)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add") { add() }.keyboardShortcut(.defaultAction).disabled(!isValid)
            }
        }
        .padding()
        .frame(width: 460)
    }

    private var isValid: Bool {
        switch kind {
        case .repo: return !repo.trimmingCharacters(in: .whitespaces).isEmpty
                        && !variant.trimmingCharacters(in: .whitespaces).isEmpty
        case .folder: return !folderPath.isEmpty
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            folderPath = url.path
            folderName = url.lastPathComponent
        }
    }

    private func add() {
        switch kind {
        case .repo:
            onAdd(.repo(variant: variant.trimmingCharacters(in: .whitespaces),
                        repo: repo.trimmingCharacters(in: .whitespaces)))
        case .folder:
            onAdd(.folder(id: folderName, path: folderPath))
        }
        dismiss()
    }
}

private extension ModelsViewModel.Deps {
    @MainActor static func live(_ coordinator: AppCoordinator) -> Self {
        .init(
            list: {
                let names = (try? await RealWhisperKit.fetchAvailableModels()) ?? []
                let installed = coordinator.installedModelIDs()
                let custom = await coordinator.customModels()
                let customRows = custom.map { c in
                    ModelsViewModel.ModelRow(
                        id: c.id,
                        installed: c.kind == .folder,
                        isCustom: true,
                        detail: c.kind == .folder ? c.folderPath : c.repo)
                }
                let builtinRows = names.map {
                    ModelsViewModel.ModelRow(id: $0, installed: installed.contains($0))
                }
                return customRows + builtinRows
            },
            use: { await coordinator.useModel($0) },
            addCustom: { await coordinator.addCustomModel($0) },
            removeCustom: { await coordinator.removeCustomModel(id: $0) })
    }
}
