import SwiftUI
import MirrorCore

/// What will be backed up, what is skipped and what needs a decision. Unticking a row saves a rule.
struct PreviewSheet: View {
    let model: AppModel
    var startLabel = "Start Backup"
    var onStart: (BackupSet) -> Void
    @State private var controller: PreviewController
    @Environment(\.dismiss) private var dismiss

    init(model: AppModel, set: BackupSet, startLabel: String = "Start Backup", onStart: @escaping (BackupSet) -> Void) {
        self.model = model
        self.startLabel = startLabel
        self.onStart = onStart
        // A set that isn't saved yet keeps its edits in the controller until Start Backup.
        _controller = State(initialValue: PreviewController(set: set, provider: model.services.preview,
                                                            inspector: model.services.inspector,
                                                            persistsEdits: model.set(set.id) != nil))
    }

    /// For rendering screenshots with a ready-made controller.
    init(model: AppModel, controller: PreviewController, onStart: @escaping (BackupSet) -> Void) {
        self.model = model
        self.onStart = onStart
        _controller = State(initialValue: controller)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Preview \"\(controller.set.name)\"").font(.title2.weight(.semibold))
            content
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(startLabel) { onStart(controller.set); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(controller.result == nil || controller.isLoading)
                    .accessibilityHint("Accepts this preview and starts the first backup")
            }
        }
        .padding(20)
        .frame(minWidth: 620, minHeight: 460)
        .task { await controller.load() }
        .onAppear { controller.onSetChanged = { model.save(set: $0) } }
        .confirmationDialog(
            "New rule matches files already backed up",
            isPresented: Binding(get: { controller.pendingImpact != nil },
                                 set: { if !$0 { Task { await controller.resolveImpact(.leaveInPlace) } } }),
            titleVisibility: .visible
        ) {
            Button("Move to Archive") { Task { await controller.resolveImpact(.moveToArchive) } }
            Button("Leave in Place") { Task { await controller.resolveImpact(.leaveInPlace) } }
        } message: {
            let n = controller.pendingImpact?.count ?? 0
            Text("\(n.formatted()) \(n == 1 ? "file" : "files") already in the backup now match your exclude rules. Move them to the archive, or leave them where they are? Nothing is deleted without your choice.")
        }
    }

    @ViewBuilder private var content: some View {
        if let error = controller.loadError {
            ContentUnavailableView("Preview Unavailable", systemImage: "exclamationmark.triangle", description: Text(error))
        } else if let r = controller.result {
            ForEach(PreviewWarnings.appleDouble(set: controller.set, destinations: model.destinations,
                                                volumes: model.volumeCache.volumes), id: \.self) {
                Label($0, systemImage: "exclamationmark.triangle").font(.callout)
            }
            ForEach(r.warnings, id: \.self) {
                Label($0, systemImage: "exclamationmark.triangle").font(.callout)
            }
            HStack(spacing: 12) {
                Total(title: "Backed up", value: r.includedBytes.formatted(.byteCount(style: .file)),
                      detail: "\(r.includedFiles.formatted()) files", symbol: "checkmark.circle")
                Total(title: "Skipped", value: r.skippedBytes.formatted(.byteCount(style: .file)),
                      detail: "by your rules", symbol: "minus.circle")
                Total(title: "Needs a decision", value: r.decisions.count.formatted(),
                      detail: r.decisions.isEmpty ? "none" : "listed below", symbol: "questionmark.circle")
            }
            Table(r.groups) {
                TableColumn("Back Up") { g in
                    Toggle(g.title, isOn: Binding(get: { g.included },
                                                  set: { v in Task { await controller.setIncluded(v, for: g) } }))
                        .labelsHidden()
                        .accessibilityLabel("Back up \(g.title)")
                }
                .width(60)
                TableColumn("Folder or Pattern") { g in
                    VStack(alignment: .leading) {
                        Text(g.title)
                        Text(g.pattern).font(.caption).foregroundStyle(.secondary)
                    }
                }
                TableColumn("Files") { g in Text(g.fileCount.formatted()).monospacedDigit() }.width(70)
                TableColumn("Size") { g in Text(g.bytes.formatted(.byteCount(style: .file))).monospacedDigit() }.width(80)
            }
            .frame(minHeight: 160)
            if !r.decisions.isEmpty {
                GroupBox("Needs a decision") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(r.decisions) { item in
                            Label {
                                Text(item.path).lineLimit(1).truncationMode(.middle)
                            } icon: { Image(systemName: "questionmark.circle") }
                            .accessibilityLabel("\(item.path), needs a decision")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }
            }
        } else {
            ProgressView("Looking at your files…").frame(maxWidth: .infinity, minHeight: 200)
        }
    }
}

private struct Total: View {
    let title: String, value: String, detail: String, symbol: String
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 2) {
                Label(title, systemImage: symbol).font(.subheadline).foregroundStyle(.secondary)
                Text(value).font(.title3.weight(.semibold)).monospacedDigit()
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}
