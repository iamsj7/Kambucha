import SwiftUI
import AppKit
import MirrorCore

enum RestoreTarget {
    /// True when `target` is one of `sources` or below it. Compared by whole path components, so
    /// `/Projects-restored` isn't taken for being inside `/Projects`.
    static func isInside(_ target: URL, anyOf sources: [URL]) -> Bool {
        // Case-insensitive: the default macOS volume is, so `/users/me/projects` is the same folder.
        let t = target.standardizedFileURL.resolvingSymlinksInPath().pathComponents.map { $0.lowercased() }
        return sources.contains { source in
            let s = source.standardizedFileURL.resolvingSymlinksInPath().pathComponents.map { $0.lowercased() }
            return t.count >= s.count && Array(t.prefix(s.count)) == s
        }
    }
}

struct ArchiveSelection: Hashable { var set: UUID?; var destination: UUID? }

@MainActor @Observable
final class ArchiveModel {
    enum Phase: Equatable { case idle, loading, loaded([ArchiveEntry]), failed(String) }
    enum RestoreState: Equatable { case idle, restoring(String), done(URL), failed(String) }
    enum Mode: Hashable { case archive, latest }
    enum Latest: Equatable { case idle, loading, loaded([BackupItem]), failed(String) }

    private(set) var sets: [BackupSet] = []
    private(set) var destinations: [Destination] = []
    private(set) var phase: Phase = .idle
    private(set) var restoreState: RestoreState = .idle
    private(set) var drillDueDestinations: [Destination] = []
    var selection = ArchiveSelection()
    var mode = Mode.archive
    /// Where the owner is in the latest backup, below the set's own folder.
    private(set) var folder: [String] = []
    private(set) var latest = Latest.idle

    @ObservationIgnored private let provider: any ArchiveProviding
    @ObservationIgnored private let store: ConfigStore
    @ObservationIgnored private let now: () -> Date

    init(provider: any ArchiveProviding, store: ConfigStore = ConfigStore(root: MirrorPaths.support),
         now: @escaping () -> Date = Date.init) {
        self.provider = provider; self.store = store; self.now = now
    }

    var selectedSet: BackupSet? { sets.first { $0.id == selection.set } }
    var selectedDestination: Destination? { destinations.first { $0.id == selection.destination } }
    /// Destinations the selected set uses.
    var destinationsForSelectedSet: [Destination] {
        guard let s = selectedSet else { return [] }
        return destinations.filter { s.destinationIDs.contains($0.id) }
    }
    var encryptedDestinations: [Destination] { destinations.filter(\.encrypted) }

    func loadConfig() {
        sets = (try? store.loadSets()) ?? []
        destinations = (try? store.loadDestinations()) ?? []
        if selectedSet == nil { selection.set = sets.first?.id }
        if !destinationsForSelectedSet.contains(where: { $0.id == selection.destination }) {
            selection.destination = destinationsForSelectedSet.first?.id
        }
        drillDueDestinations = destinations.filter { d in
            let states = sets.filter { $0.destinationIDs.contains(d.id) }
                .compactMap { try? store.state(for: PairID(set: $0.id, destination: d.id)) }
            return DrillSchedule.isDue(d, states: states, now: now())
        }
    }

    func reload() async {
        guard let set = selectedSet, let dest = selectedDestination else { phase = .idle; return }
        phase = .loading
        do {
            let entries = try await provider.list(set: set, destination: dest)
            guard set.id == selectedSet?.id, dest.id == selectedDestination?.id else { return }   // selection moved on
            phase = .loaded(entries)
        } catch is CancellationError {
            return
        } catch {
            phase = .failed("Mirror couldn't read the archive. Check your connection and try again.")
        }
    }

    /// `Sets/<set>` plus where the owner is, and a name below that.
    private func latestPath(_ name: String? = nil) -> String? {
        guard let set = selectedSet else { return nil }
        return (["Sets", set.name] + folder + (name.map { [$0] } ?? [])).joined(separator: "/")
    }

    func reloadLatest() async {
        guard let set = selectedSet, let dest = selectedDestination, let path = latestPath() else { latest = .idle; return }
        latest = .loading
        do {
            let items = try await provider.browse(path: path, set: set, destination: dest)
            guard path == latestPath(), dest.id == selectedDestination?.id else { return }   // the owner moved on
            latest = .loaded(items)
        } catch is CancellationError {
            return
        } catch {
            latest = .failed(SetupFailureText.message(for: error))
        }
    }

    func open(_ name: String) async { folder.append(name); await reloadLatest() }
    func goUp(to depth: Int) async { folder = Array(folder.prefix(depth)); await reloadLatest() }
    /// A folder of one set means nothing in another.
    func resetFolder() { folder = [] }

    /// Restores a file or folder of the latest backup, or with `item` nil the folder the owner is in, which
    /// at the top is the whole set. The same guards as an archived file.
    func restoreLatest(_ item: BackupItem?, chooseLocation: (ArchiveEntry) async -> URL?) async {
        guard let path = latestPath(item?.name), let set = selectedSet else { return }
        await restore(ArchiveEntry(id: path, setName: set.name, stamp: now(), path: path, size: item?.size ?? 0),
                      chooseLocation: chooseLocation)
    }

    /// Everything one run moved to the archive, as a folder. How a mass deletion is undone.
    func restoreRun(of entry: ArchiveEntry, chooseLocation: (ArchiveEntry) async -> URL?) async {
        let path = entry.path.split(separator: "/").prefix(3).joined(separator: "/")
        await restore(ArchiveEntry(id: path, setName: entry.setName, stamp: entry.stamp, path: path, size: 0), chooseLocation: chooseLocation)
    }

    /// Archived files grouped by the day they were archived, newest first.
    var sections: [(day: Date, entries: [ArchiveEntry])] {
        guard case .loaded(let entries) = phase else { return [] }
        let groups = Dictionary(grouping: entries) { Calendar.current.startOfDay(for: $0.stamp) }
        return groups.keys.sorted(by: >).map { day in
            (day, groups[day]!.sorted { ($0.stamp, $0.path) > ($1.stamp, $1.path) })
        }
    }

    /// Restores one file or folder to a place the owner picks. Never into a backed-up folder, where it could
    /// replace the original.
    func restore(_ entry: ArchiveEntry, chooseLocation: (ArchiveEntry) async -> URL?) async {
        guard let set = selectedSet, let dest = selectedDestination else { return }
        guard let target = await chooseLocation(entry) else { restoreState = .idle; return }
        if RestoreTarget.isInside(target, anyOf: sets.map(\.source)) {
            restoreState = .failed("Choose a place outside the folders Mirror backs up, so the original isn't replaced.")
            return
        }
        let name = (entry.path as NSString).lastPathComponent
        restoreState = .restoring(name)
        // The save panel has already asked "Replace?" of anything it was pointed at.
        let replacing = FileManager.default.fileExists(atPath: target.path)
        do {
            try await provider.restore(entry: entry, set: set, destination: dest, to: target, replacing: replacing)
            restoreState = .done(target)
        } catch is CancellationError {
            restoreState = .idle
        } catch let refused as RestoreError {
            restoreState = .failed(SetupFailureText.message(for: refused))   // trying again wouldn't help
        } catch {
            restoreState = .failed("Mirror couldn't restore \(name). Nothing was changed. Try again.")
        }
    }

    func dismissRestoreState() { restoreState = .idle }
}

@MainActor
func chooseRestoreLocation(for entry: ArchiveEntry) async -> URL? {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = (entry.path as NSString).lastPathComponent
    panel.prompt = "Restore"
    panel.message = "Choose where to put the restored copy. Your original files aren't touched."
    panel.canCreateDirectories = true
    panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
    return await withCheckedContinuation { c in
        panel.begin { c.resume(returning: $0 == .OK ? panel.url : nil) }
    }
}

struct ArchiveView: View {
    @Bindable var model: ArchiveModel
    let agent: AgentClient?
    var chooseLocation: (ArchiveEntry) async -> URL? = { await chooseRestoreLocation(for: $0) }
    @State private var drill: DrillModel?
    @State private var showDrill = false
    @State private var focused: ArchiveEntry.ID?

    var body: some View {
        VStack(spacing: 0) {
            if let due = model.drillDueDestinations.first { reminder(due) }
            Picker("Show", selection: $model.mode) {
                Text("Older Versions").tag(ArchiveModel.Mode.archive)
                Text("Latest Backup").tag(ArchiveModel.Mode.latest)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .padding(.vertical, 8)
            if model.mode == .archive { content } else { latest }
            if model.restoreState != .idle { restoreBar }
        }
        .navigationTitle("Archive")
        .toolbar {
            ToolbarItemGroup {
                Picker("Set", selection: $model.selection.set) {
                    ForEach(model.sets) { Text($0.name).tag(Optional($0.id)) }
                }
                Picker("Destination", selection: $model.selection.destination) {
                    ForEach(model.destinationsForSelectedSet) { Text($0.name).tag(Optional($0.id)) }
                }
                Button { openDrill() } label: { Label("Test Recovery Kit", systemImage: "key.horizontal") }
                    .help("Check that your Recovery Kit still opens a backup")
                    .disabled(model.encryptedDestinations.isEmpty || agent == nil)
            }
        }
        .task(id: model.selection) {
            model.loadConfig()
            model.resetFolder()
            await model.reload()
            if model.mode == .latest { await model.reloadLatest() }
        }
        // Each look at a cloud is an agent launch and a network trip, so this waits until it's asked for.
        .onChange(of: model.mode) { _, mode in if mode == .latest { Task { await model.reloadLatest() } } }
        .sheet(isPresented: $showDrill, onDismiss: { drill?.discard(); drill = nil; model.loadConfig() }) {
            if let drill { DrillSheet(model: drill) }
        }
    }

    /// One model per opening, so the sheet keeps its state while it is on screen.
    private func openDrill() {
        guard let agent else { return }
        drill = DrillModel(destinations: model.encryptedDestinations, sets: model.sets,
                           candidate: DrillFilePicker.candidate(sets: model.sets),
                           run: { try await agent.drill($0, kitText: $1, relativePath: $2, original: $3) })
        showDrill = true
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .idle where model.sets.isEmpty:
            ContentUnavailableView("No Archive Yet", systemImage: "externaldrive.badge.checkmark",
                                   description: Text("Old versions and deleted files appear here after your first backup."))
        case .idle, .loading:
            ProgressView("Reading the archive").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let why):
            ContentUnavailableView {
                Label("Couldn't Read the Archive", systemImage: "exclamationmark.triangle")
            } description: { Text(why) } actions: {
                Button("Try Again") { Task { await model.reload() } }
            }
        case .loaded:
            if model.sections.isEmpty {
                ContentUnavailableView("Nothing Archived", systemImage: "externaldrive.badge.checkmark",
                                       description: Text("Changed and deleted files are kept for \(model.selectedSet?.archiveDays ?? 30) days. None are kept right now."))
            } else {
                List(selection: $focused) {
                    ForEach(model.sections, id: \.day) { section in
                        Section(section.day.formatted(date: .complete, time: .omitted)) {
                            ForEach(section.entries) { entry in row(entry) }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var latest: some View {
        VStack(spacing: 0) {
            HStack {
                if !model.folder.isEmpty {
                    Button { Task { await model.goUp(to: model.folder.count - 1) } } label: { Label("Back", systemImage: "chevron.left") }
                        .accessibilityHint("Goes up one folder")
                }
                Text(((model.selectedSet.map { [$0.name] } ?? []) + model.folder).joined(separator: " / "))
                    .lineLimit(1).truncationMode(.head).foregroundStyle(.secondary)
                Spacer()
                Button(model.folder.isEmpty ? "Restore Whole Set…" : "Restore This Folder…") {
                    Task { await model.restoreLatest(nil, chooseLocation: chooseLocation) }
                }
                .disabled(model.selectedDestination == nil)
                .accessibilityHint("Asks where to put the restored copy")
            }
            .padding(.horizontal).padding(.bottom, 8)
            switch model.latest {
            case .idle where model.sets.isEmpty:
                ContentUnavailableView("No Backup Yet", systemImage: "externaldrive.badge.checkmark",
                                       description: Text("Your backed-up folders appear here after your first backup."))
            case .idle, .loading:
                ProgressView("Reading the backup").frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let why):
                ContentUnavailableView {
                    Label("Couldn't Read the Backup", systemImage: "exclamationmark.triangle")
                } description: { Text(why) } actions: {
                    Button("Try Again") { Task { await model.reloadLatest() } }
                }
            case .loaded(let items):
                if items.isEmpty {
                    ContentUnavailableView("Nothing Here", systemImage: "folder")
                } else {
                    List(items) { latestRow($0) }
                }
            }
        }
    }

    private func latestRow(_ item: BackupItem) -> some View {
        HStack {
            if item.isFolder {
                Button { Task { await model.open(item.name) } } label: {
                    Label(item.name, systemImage: "folder").lineLimit(1)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens this folder")
            } else {
                Label(item.name, systemImage: "doc").lineLimit(1)
            }
            Spacer(minLength: 8)
            if !item.isFolder { Text(item.size.formatted(.byteCount(style: .file))).foregroundStyle(.secondary) }
            Button("Restore…") { Task { await model.restoreLatest(item, chooseLocation: chooseLocation) } }
                .accessibilityLabel("Restore \(item.name)")
                .accessibilityHint("Asks where to put the restored copy")
        }
        .accessibilityElement(children: .contain)
    }

    private func row(_ entry: ArchiveEntry) -> some View {
        let name = (entry.path as NSString).lastPathComponent
        let folder = (entry.path as NSString).deletingLastPathComponent
        return HStack {
            Image(systemName: "doc").accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(name).lineLimit(1)
                Text(folder.isEmpty ? entry.stamp.formatted(date: .omitted, time: .shortened)
                                    : "\(folder), \(entry.stamp.formatted(date: .omitted, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(entry.size.formatted(.byteCount(style: .file))).foregroundStyle(.secondary)
            Button("Restore…") { Task { await model.restore(entry, chooseLocation: chooseLocation) } }
                .accessibilityLabel("Restore \(name)")
                .accessibilityHint("Asks where to put the restored copy")
        }
        .tag(entry.id)
        .contextMenu {
            Button("Restore…") { Task { await model.restore(entry, chooseLocation: chooseLocation) } }
            Button("Restore Everything From This Run…") { Task { await model.restoreRun(of: entry, chooseLocation: chooseLocation) } }
        }
        .accessibilityElement(children: .contain)
    }

    private func reminder(_ d: Destination) -> some View {
        HStack {
            Label("Time to test your Recovery Kit for \(d.name)", systemImage: "key.horizontal")
            Spacer()
            Button("Test Now…") { openDrill() }.disabled(agent == nil)
        }
        .padding(.horizontal).padding(.vertical, 8)
        .background(.bar)
        .accessibilityElement(children: .combine)
    }

    private var restoreBar: some View {
        HStack {
            switch model.restoreState {
            case .restoring(let n):
                ProgressView().controlSize(.small)
                Text("Restoring \(n)…")
            case .done(let url):
                Label("Restored", systemImage: "checkmark.circle")
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            case .failed(let why):
                Label(why, systemImage: "exclamationmark.triangle")
            case .idle:
                EmptyView()
            }
            Spacer()
            if case .restoring = model.restoreState {} else { Button("Dismiss") { model.dismissRestoreState() } }
        }
        .font(.callout)
        .padding(.horizontal).padding(.vertical, 8)
        .background(.bar)
        .accessibilityElement(children: .contain)
    }
}
