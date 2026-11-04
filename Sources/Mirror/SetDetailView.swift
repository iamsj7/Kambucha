import SwiftUI
import AppKit
import MirrorCore

struct SetDetailView: View {
    @Bindable var model: AppModel
    let setID: UUID
    @State private var draft: BackupSet
    @State private var presets: [Preset] = []
    @State private var showingPreview = false
    @State private var previewTask: Task<Void, Never>?

    init(model: AppModel, setID: UUID) {
        self.model = model
        self.setID = setID
        _draft = State(initialValue: model.set(setID) ?? BackupSet(name: "", source: URL(fileURLWithPath: "/")))
    }

    /// Rules still being typed (empty patterns) are neither saved nor previewed.
    private static func cleaned(_ set: BackupSet) -> BackupSet {
        var c = set
        c.rules.removeAll { $0.pattern.trimmingCharacters(in: .whitespaces).isEmpty }
        return c
    }
    private var accepted: Bool { model.acceptance.isAccepted(Self.cleaned(draft)) }

    var body: some View {
        Form {
            if !accepted {
                Section {
                    Label("Preview this set before its first backup. Changing rules asks again.", systemImage: "eye")
                    Button("Preview Backup…") { showingPreview = true }
                        .buttonStyle(.borderedProminent)
                }
            }

            Section("Location") {
                TextField("Name", text: $draft.name)
                LabeledContent("Folder") {
                    Text(draft.source.path).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([draft.source]) }
                Toggle("Pause this set", isOn: $draft.isPaused)
            }

            Section {
                Toggle(isOn: .constant(true)) { Text("macOS (.DS_Store, .Trash)") }
                    .disabled(true)
                ForEach(presets) { preset in
                    Toggle(preset.name, isOn: presetBinding(preset.id))
                }
            } header: {
                Text("Stacks")
            } footer: {
                Text("Build folders and caches for these stacks are skipped. When unsure, Mirror backs a file up.")
            }

            Section {
                Toggle("Back up secrets", isOn: $draft.backupSecrets)
                Toggle("Back up Git history", isOn: $draft.backupGit)
            } header: {
                Text("Secrets and Git")
            } footer: {
                Text("Secrets are .env files and private keys. Git history adds the .git folders, which can be large.")
            }

            Section {
                ForEach($draft.rules) { $rule in
                    HStack {
                        Picker("Action", selection: $rule.action) {
                            Text("Include").tag(UserRule.Action.include)
                            Text("Exclude").tag(UserRule.Action.exclude)
                        }
                        .labelsHidden().frame(width: 100)
                        TextField("Pattern", text: $rule.pattern, prompt: Text("For example *.log or /Drafts"))
                            .labelsHidden()
                            .onSubmit { requestPreview(after: 0) }
                        Button(role: .destructive) { draft.rules.removeAll { $0.id == rule.id }; requestPreview() } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Delete rule \(rule.pattern)")
                    }
                }
                Button("Add Rule") { draft.rules.append(UserRule(pattern: "", action: .exclude)) }
            } header: {
                Text("Your Rules")
            } footer: {
                Text("Your rules come first. Press Return after typing a pattern to preview the effect.")
            }

            Section("Destinations") {
                ForEach(model.destinations) { d in
                    let status = model.destinationStatus(d)
                    Toggle(isOn: destinationBinding(d.id)) {
                        VStack(alignment: .leading) {
                            Label(d.name, systemImage: d.kind.symbol)
                            Text(status.text).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if model.destinations.isEmpty {
                    Text("Add a destination from the sidebar.").foregroundStyle(.secondary)
                }
            }

            Section {
                Stepper("At least \(draft.deletion.minFiles) files", value: $draft.deletion.minFiles, in: 1...100_000, step: 10)
                Stepper("More than \(draft.deletion.percent.formatted())% of the set",
                        value: $draft.deletion.percent, in: 1...100, step: 1)
                Stepper("Or more than \(draft.deletion.absoluteMax.formatted()) files",
                        value: $draft.deletion.absoluteMax, in: 10...1_000_000, step: 100)
            } header: {
                Text("Hold Deletions When a Backup Would Remove")
            } footer: {
                Text("A hold needs both the first two, or the last on its own. New and changed files keep backing up while deletions wait for you.")
            }

            Section {
                Stepper("Keep removed files \(draft.archiveDays) days", value: $draft.archiveDays, in: 1...3650, step: 5)
            } header: {
                Text("Archive")
            } footer: {
                Text("Files you delete or change are kept in the archive for this long.")
            }

            Section {
                Button("Preview Backup…") { showingPreview = true }
                Button("Back Up Now") { model.runNow(setID) }
                    .disabled(!accepted || draft.isPaused)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(draft.name)
        .onChange(of: draft) { _, new in model.save(set: Self.cleaned(new)) }
        .onChange(of: draft.presets) { requestPreview() }
        .onChange(of: draft.backupSecrets) { requestPreview() }
        .onChange(of: draft.backupGit) { requestPreview() }
        .task { presets = (try? PresetCatalog.all()) ?? [] }
        .sheet(isPresented: $showingPreview, onDismiss: { if let s = model.set(setID) { draft = s } }) {
            PreviewSheet(model: model, set: Self.cleaned(draft), startLabel: "Start Backup") { updated in
                draft = updated
                model.save(set: updated)
                model.acceptance.accept(updated)
                model.runNow(updated.id)
            }
        }
    }

    /// Several quick changes become one preview.
    private func requestPreview(after seconds: Double = 0.8) {
        previewTask?.cancel()
        previewTask = Task {
            try? await Task.sleep(for: .seconds(seconds))
            if !Task.isCancelled { showingPreview = true }
        }
    }

    private func presetBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { draft.presets.contains(id) },
                set: { if $0 { draft.presets.insert(id) } else { draft.presets.remove(id) } })
    }

    private func destinationBinding(_ id: UUID) -> Binding<Bool> {
        Binding(get: { draft.destinationIDs.contains(id) },
                set: { if $0 { draft.destinationIDs.append(id) } else { draft.destinationIDs.removeAll { $0 == id } } })
    }
}
