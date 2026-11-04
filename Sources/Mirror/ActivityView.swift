import SwiftUI
import AppKit
import MirrorCore

/// Words and a symbol for each run result. Status is never colour alone.
struct RunResultPresentation {
    let symbol: String
    let title: String

    init(_ s: RunRecord.Status) {
        switch s {
        case .success: symbol = "checkmark.circle"; title = "Succeeded"
        case .partial: symbol = "clock.arrow.circlepath"; title = "Partly Uploaded"
        case .held: symbol = "pause.circle"; title = "Deletions Held"
        case .failed: symbol = "xmark.octagon"; title = "Failed"
        case .verificationFailed: symbol = "exclamationmark.triangle"; title = "Verification Failed"
        case .skipped: symbol = "minus.circle"; title = "Skipped"
        }
    }

    /// "3 copied, 1 deleted": only the counts that aren't zero.
    static func counts(_ r: RunRecord) -> String {
        let parts = [(r.copied, "copied"), (r.renamed, "renamed"), (r.deleted, "deleted"), (r.archived, "archived")]
            .filter { $0.0 > 0 }.map { "\($0.0.formatted()) \($0.1)" }
        return parts.isEmpty ? "No changes" : parts.joined(separator: ", ")
    }
}

@MainActor @Observable
final class ActivityModel {
    private(set) var records: [RunRecord] = []
    private(set) var loadFailed = false
    @ObservationIgnored private let store: RunRecordStore

    init(support: URL = MirrorPaths.support) { store = RunRecordStore(root: support) }

    func reload() async {
        let store = store
        let result = await Task.detached(priority: .utility) { try? store.recent(limit: 500) }.value
        if let result { records = result; loadFailed = false } else { loadFailed = true }
    }

    func revealLogs() {
        let dir = MirrorPaths.logs
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }
}

struct ActivityView: View {
    @Bindable var model: ActivityModel
    @State private var sortOrder = [KeyPathComparator(\RunRecord.start, order: .reverse)]
    @State private var selection: RunRecord.ID?

    private var sorted: [RunRecord] { model.records.sorted(using: sortOrder) }
    private var selected: RunRecord? { model.records.first { $0.id == selection } }

    var body: some View {
        VStack(spacing: 0) {
            if model.records.isEmpty {
                ContentUnavailableView(model.loadFailed ? "Couldn't Read Activity" : "No Activity Yet",
                                       systemImage: model.loadFailed ? "exclamationmark.triangle" : "clock.arrow.circlepath",
                                       description: Text(model.loadFailed ? "Mirror couldn't read its run history. Try again."
                                                                          : "Backups appear here after they run."))
            } else {
                Table(sorted, selection: $selection, sortOrder: $sortOrder) {
                    TableColumn("Started", value: \.start) { r in
                        Text(r.start.formatted(date: .abbreviated, time: .shortened))
                    }.width(min: 120, ideal: 150)
                    TableColumn("Set", value: \.setName) { r in
                        VStack(alignment: .leading, spacing: 0) {
                            Text(r.setName)
                            Text(r.destinationName).font(.caption).foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }.width(min: 100, ideal: 150)
                    TableColumn("Result") { r in
                        let p = RunResultPresentation(r.status)
                        Label(p.title, systemImage: p.symbol)
                    }.width(min: 130, ideal: 160)
                    TableColumn("Files") { r in
                        VStack(alignment: .leading, spacing: 0) {
                            Text(RunResultPresentation.counts(r))
                            Text("\(r.filesChecked.formatted()) checked").font(.caption).foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }.width(min: 120, ideal: 170)
                    TableColumn("Verification") { r in
                        Text(r.verification.isEmpty ? "Not checked" : r.verification).lineLimit(2)
                    }.width(min: 90, ideal: 130)
                    TableColumn("Errors") { r in
                        Text(r.errors.isEmpty ? "None" : "\(r.errors.count.formatted()), \(r.errors[0])").lineLimit(2)
                            .foregroundStyle(r.errors.isEmpty ? .secondary : .primary)
                    }.width(min: 90, ideal: 180)
                }
                if let selected, !selected.errors.isEmpty {
                    Divider()
                    ErrorList(record: selected)
                }
            }
        }
        .navigationTitle("Activity")
        .toolbar {
            ToolbarItemGroup {
                Button { Task { await model.reload() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .help("Reload the run history")
                Button { model.revealLogs() } label: { Label("Reveal Logs", systemImage: "doc.text.magnifyingglass") }
                    .help("Show Mirror's log files in Finder")
            }
        }
        .task {
            // Light refresh while the screen is open; nothing runs when it is closed.
            while !Task.isCancelled {
                await model.reload()
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }
}

private struct ErrorList: View {
    let record: RunRecord
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Errors in this run").font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(record.errors.enumerated()), id: \.offset) { _, e in
                        Text(e).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxHeight: 100)
        }
        .padding()
        .accessibilityElement(children: .contain)
    }
}
