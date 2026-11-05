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
        if r.status == .skipped { return r.scope == "none" ? "Nothing to do" : r.scope.prefix(1).uppercased() + r.scope.dropFirst() }
        let parts = [(r.copied, "copied"), (r.renamed, "renamed"), (r.deleted, "deleted"), (r.archived, "archived")]
            .filter { $0.0 > 0 }.map { "\($0.0.formatted()) \($0.1)" }
        return parts.isEmpty ? "No changes" : parts.joined(separator: ", ")
    }
}

/// What an empty list means. A failed read comes first, as no filter explains it.
enum ActivityEmptyState: Equatable {
    case loadFailed, noActivity, noSearchResults, noMatchingRuns

    init(loadFailed: Bool, isFiltering: Bool, search: String) {
        if loadFailed { self = .loadFailed }
        else if !isFiltering { self = .noActivity }
        else { self = search.isEmpty ? .noMatchingRuns : .noSearchResults }
    }
}

@MainActor @Observable
final class ActivityModel {
    /// Records shown at most, counted after filtering.
    static let limit = 500
    static let scanNote = "Only the most recent runs were searched."

    private(set) var records: [RunRecord] = []
    private(set) var loadFailed = false
    private var hasLoaded = false
    /// Sets to choose from in the filter, by name.
    private(set) var sets: [(id: UUID, name: String)] = []
    var filter = RunFilter()
    @ObservationIgnored private let store: RunRecordStore
    @ObservationIgnored private let config: ConfigStore

    /// True when the history was too long to read to its end, so a run that isn't listed may still exist.
    private(set) var reachedScanLimit = false
    @ObservationIgnored private let maxRead: Int

    init(support: URL = MirrorPaths.support, maxRead: Int = RunRecordStore.scanBound) {
        store = RunRecordStore(root: support); config = ConfigStore(root: support); self.maxRead = maxRead
    }

    /// Reads off the main thread. A filter changed while this runs is read again by the next call.
    func reload() async {
        let store = store, config = config, filter = filter, limit = Self.limit, maxRead = maxRead
        let (result, names) = await Task.detached(priority: .utility) {
            (try? store.search(limit: limit, matching: filter, maxRead: maxRead),
             ((try? config.loadSets()) ?? []).map { (id: $0.id, name: $0.name) }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
        }.value
        guard filter == self.filter else { return }
        sets = names
        hasLoaded = true
        if let id = self.filter.setID, !names.contains(where: { $0.id == id }) { self.filter.setID = nil }
        if let result {
            records = result.records; reachedScanLimit = result.reachedScanLimit; loadFailed = false
        } else {
            loadFailed = true
        }
    }

    /// The wait is for typing, so opening the screen doesn't pay it.
    var readDelay: Duration { hasLoaded ? .milliseconds(250) : .zero }
    var emptyState: ActivityEmptyState { ActivityEmptyState(loadFailed: loadFailed, isFiltering: isFiltering, search: filter.search) }

    /// True when a filter hides records, so an empty list isn't read as "no activity".
    var isFiltering: Bool { filter.setID != nil || filter.result != .all || !filter.search.isEmpty }

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
    @State private var width: CGFloat = 0

    private var sorted: [RunRecord] { model.records.sorted(using: sortOrder) }
    private var selected: RunRecord? { model.records.first { $0.id == selection } }

    var body: some View {
        VStack(spacing: 0) {
            scopeBar
            if model.records.isEmpty && model.reachedScanLimit {
                PageState {
                    ContentUnavailableView("No Results", systemImage: "magnifyingglass",
                                           description: Text("\(ActivityModel.scanNote) Older runs may match."))
                }
            } else if model.records.isEmpty && model.emptyState == .noSearchResults {
                PageState { ContentUnavailableView.search }
            } else if model.records.isEmpty && model.emptyState == .noMatchingRuns {
                PageState {
                    ContentUnavailableView("No Matching Runs", systemImage: "line.3.horizontal.decrease.circle",
                                           description: Text("No runs match these filters."))
                }
            } else if model.records.isEmpty {
                PageState {
                    ContentUnavailableView(model.loadFailed ? "Couldn't Read Activity" : "No Activity Yet",
                                           systemImage: model.loadFailed ? "exclamationmark.triangle" : "clock.arrow.circlepath",
                                           description: Text(model.loadFailed ? "Mirror couldn't read its run history. Try again."
                                                                              : model.filter.includeSkipped ? "Backups appear here after they run."
                                                                              : "Backups appear here after they run. Skipped runs are hidden."))
                }
            } else {
                Table(sorted, selection: $selection, sortOrder: $sortOrder) {
                    TableColumn("Started", value: \.start) { r in
                        Text(r.start.formatted(date: .abbreviated, time: .shortened))
                    }.width(min: 100, ideal: 140)
                    TableColumn("Set", value: \.setName) { r in
                        VStack(alignment: .leading, spacing: 0) {
                            Text(r.setName)
                            Text(r.destinationName).font(.caption).foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }.width(min: 80, ideal: 130)
                    TableColumn("Result") { r in
                        let p = RunResultPresentation(r.status)
                        Label(p.title, systemImage: p.symbol)
                    }.width(min: 100, ideal: 130)
                    TableColumn("Files") { r in
                        VStack(alignment: .leading, spacing: 0) {
                            Text(RunResultPresentation.counts(r))
                            Text("\(r.filesChecked.formatted()) checked").font(.caption).foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }.width(min: 100, ideal: 150)
                    TableColumn("Verification") { r in
                        Text(r.verification.isEmpty ? "Not checked" : r.verification).lineLimit(2)
                    }.width(min: 60, ideal: 110)
                    TableColumn("Errors") { r in
                        Text(r.errors.isEmpty ? "None" : "\(r.errors.count.formatted()), \(r.errors[0])").lineLimit(2)
                            .foregroundStyle(r.errors.isEmpty ? .secondary : .primary)
                    }.width(min: 60, ideal: 130)
                }
                if model.reachedScanLimit {
                    Text(ActivityModel.scanNote).font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, PageLayout.dataInset).padding(.vertical, PageLayout.bannerGap)
                }
                if let selected, !selected.errors.isEmpty {
                    Divider()
                    ErrorList(record: selected)
                }
            }
        }
        .measuringWidth($width)
        .navigationTitle("Activity")
        .searchable(text: $model.filter.search, prompt: "Search sets")
        .toolbar {
            ToolbarItemGroup {
                Button { Task { await model.reload() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .help("Reload the run history")
                Button { model.revealLogs() } label: { Label("Reveal Logs", systemImage: "doc.text.magnifyingglass") }
                    .help("Show Mirror's log files in Finder")
            }
        }
        .task(id: model.filter) {
            // Light refresh while the screen is open; nothing runs when it is closed. A new filter restarts it,
            // after a short wait so typing in the search field doesn't read the history per keystroke.
            try? await Task.sleep(for: model.readDelay)
            while !Task.isCancelled {
                await model.reload()
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    private var scopeBar: some View {
        PageScopeBar {
            Picker("Set", selection: $model.filter.setID) {
                Text("All Sets").tag(UUID?.none)
                ForEach(model.sets, id: \.id) { Text($0.name).tag(UUID?.some($0.id)) }
            }
            .fixedSize()
            .help("Show one set's runs")
            resultPicker
                .help("Show all runs, only those with problems, or only those that succeeded")
            Spacer(minLength: 0)
            Toggle("Show Skipped Runs", isOn: $model.filter.includeSkipped)
                .help("Include runs that had nothing to do or couldn't start, such as a paused set or a drive that isn't connected")
                .disabled(model.filter.result != .all)
                .accessibilityHint("Skipped runs are hidden by default")
        }
    }

    @ViewBuilder private var resultPicker: some View {
        let picker = Picker("Result", selection: $model.filter.result) {
            Text("All").tag(RunFilter.Result.all)
            Text("Problems").tag(RunFilter.Result.problems)
            Text("Success").tag(RunFilter.Result.success)
        }
        if PageLayout.hasRoomyToolbar(width: width) { picker.pickerStyle(.segmented).fixedSize() } else { picker.pickerStyle(.menu) }
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
        .padding(PageLayout.dataInset)
        .accessibilityElement(children: .contain)
    }
}
