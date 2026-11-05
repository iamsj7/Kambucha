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

    /// Where a backed-up path lived in the set's source: `Archive/<set>/<stamp>/<rest>` or `Sets/<set>/<rest>`.
    static func original(of path: String, in set: BackupSet) -> URL? {
        let parts = path.split(separator: "/").map(String.init)
        let skip = parts.first == "Sets" ? 2 : parts.first == "Archive" ? 3 : parts.count
        guard parts.count > skip else { return nil }
        return parts.dropFirst(skip).reduce(set.source) { $0.appendingPathComponent($1) }
    }

    /// The folder a file came from, or the nearest one still there if that's been deleted too.
    static func startFolder(for original: URL, in set: BackupSet) -> URL? {
        var folder = original.deletingLastPathComponent()
        while isInside(folder, anyOf: [set.source]) {
            if FileManager.default.fileExists(atPath: folder.path) { return folder }
            folder.deleteLastPathComponent()
        }
        return nil
    }
}

struct ArchiveSelection: Hashable { var set: UUID?; var destination: UUID? }

/// What a search has found so far, across every set and destination.
struct ArchiveResults: Equatable {
    /// The text these results are for, which trails what's typed while it's being filtered.
    var query = ""
    var matches = ArchiveMatches()
    var readCount = 0
    var pairCount = 0
    var unreadable: [ArchiveUnreadable] = []
    var isReading = false

    var status: String {
        if isReading { return "Reading the archive, \(readCount.formatted()) of \(pairCount.formatted()) done…" }
        let found = matches.total == 1 ? "1 file" : "\(matches.total.formatted()) files"
        guard matches.hits.count < matches.total else { return "\(found) found" }
        return "\(found) found. Showing the first \(matches.hits.count.formatted()), so type more to narrow it down."
    }

    /// For no results with something unread, where "no results" alone would say the file isn't there.
    var nothingFoundNote: String {
        if isReading { return "Nothing found yet." }
        let unread = unreadable.reduce(0) { $0 + $1.sets.count }
        return unread == pairCount ? "None of the archive could be searched." : "Nothing found in the rest of the archive."
    }
}

@MainActor @Observable
final class ArchiveModel {
    enum Phase: Equatable { case idle, loading, loaded([ArchiveRun]), failed(String) }
    enum RestoreState: Equatable { case idle, restoring(String), done(URL), failed(String) }
    enum Mode: Hashable { case archive, latest }
    enum Latest: Equatable { case idle, loading, loaded([BackupItem]), failed(String) }
    private enum ListingRead: Sendable { case read(ArchiveListing), failed(ArchiveReadFailure) }

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
    /// What's typed in the search field.
    var query = "" { didSet { if query != oldValue { queryChanged() } } }
    private(set) var results = ArchiveResults()

    @ObservationIgnored private let provider: any ArchiveProviding
    @ObservationIgnored private let store: ConfigStore
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let agent: ArchiveAgentQueue
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private let busyWaits: [Duration]
    /// Each read is an agent launch and, for a cloud, a network trip, so one is kept until the owner leaves the screen
    /// or reloads. A failure is kept too, or typing would try an unplugged drive again on every keystroke.
    @ObservationIgnored private var listings: [PairID: ListingRead] = [:]
    @ObservationIgnored private var reads: [PairID: Task<ListingRead?, Never>] = [:]
    /// Moves on when the listings are dropped, so a read still running can't put old ones back.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var filter: Task<Void, Never>?
    @ObservationIgnored private var filterQueued = false

    /// `agentLimit` is 1 because the agent runs every command under one lock and refuses a second rather than wait
    /// (`SecretsLock`), so running more only earns busy errors. Raise it if that lock ever allows shared reads.
    init(provider: any ArchiveProviding, store: ConfigStore = ConfigStore(root: MirrorPaths.support),
         now: @escaping () -> Date = Date.init, agentLimit: Int = 1, debounce: Duration = .milliseconds(250),
         busyWaits: [Duration] = [.milliseconds(500), .seconds(1), .seconds(2)]) {
        self.provider = provider; self.store = store; self.now = now
        agent = ArchiveAgentQueue(limit: agentLimit); self.debounce = debounce; self.busyWaits = busyWaits
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

    /// Reads the selected archive again, whatever was read before.
    func reload() async {
        guard let set = selectedSet, let dest = selectedDestination else { phase = .idle; return }
        listings[PairID(set: set.id, destination: dest.id)] = nil
        await show(set, dest)
    }

    /// Shows the selected archive, reading it only if that hasn't been done yet.
    func loadSelection() async {
        guard let set = selectedSet, let dest = selectedDestination else { phase = .idle; return }
        if case .read(let listing) = listings[PairID(set: set.id, destination: dest.id)] {
            phase = .loaded(listing.runs)
        } else {
            await show(set, dest)
        }
    }

    private func show(_ set: BackupSet, _ dest: Destination) async {
        phase = .loading
        let read = await read(set, dest, urgent: true).value
        guard set.id == selectedSet?.id, dest.id == selectedDestination?.id else { return }   // selection moved on
        switch read {
        case .read(let listing): phase = .loaded(listing.runs)
        case .failed: phase = .failed("Mirror couldn't read the archive. Check your connection and try again.")
        case nil: break
        }
    }

    /// Starts reading a listing, or joins the read already under way. Nil if the listings were dropped meanwhile.
    private func read(_ set: BackupSet, _ dest: Destination, urgent: Bool) -> Task<ListingRead?, Never> {
        let source = ArchiveSource(set: set, destination: dest)
        if let running = reads[source.pair] {
            if urgent { agent.hurry(source.pair) }
            return running
        }
        let generation = generation
        let task = Task { [weak self, agent, provider, busyWaits] () -> ListingRead? in
            let read = await agent.turn(for: source.pair, urgent: urgent) {
                await Self.fetch(source, set, dest, from: provider, busyWaits: busyWaits)
            }
            guard let self, generation == self.generation else { return nil }
            self.reads[source.pair] = nil
            self.listings[source.pair] = read
            if read != nil { self.listingArrived() }
            return read
        }
        reads[source.pair] = task
        return task
    }

    /// Grouping and indexing happen here, off the main thread, once per read. Nil only if the read was called off.
    @concurrent private static func fetch(_ source: ArchiveSource, _ set: BackupSet, _ dest: Destination,
                                          from provider: any ArchiveProviding, busyWaits: [Duration]) async -> ListingRead? {
        var waits = busyWaits[...]
        while !Task.isCancelled {
            do {
                return .read(ArchiveListing(source: source, entries: try await provider.list(set: set, destination: dest)))
            } catch {
                if Task.isCancelled { return nil }
                // Something outside this screen has the agent, such as a sign-in. That's no fault of the destination.
                guard SetupFailureText.isBusy(error), let wait = waits.popFirst() else { return .failed(ArchiveReadFailure(error)) }
                try? await Task.sleep(for: wait)
            }
        }
        return nil
    }

    // MARK: Search

    var isSearching: Bool { !query.allSatisfy(\.isWhitespace) }

    /// Every set at every destination it uses, the selected set first as that's where the owner is looking.
    private var everyPair: [(set: BackupSet, destination: Destination)] {
        let ordered = sets.filter { $0.id == selection.set } + sets.filter { $0.id != selection.set }
        return ordered.flatMap { set in destinations.filter { set.destinationIDs.contains($0.id) }.map { (set, $0) } }
    }

    private func queryChanged() {
        filter?.cancel()
        if isSearching { scheduleFilter(after: debounce) } else { filterQueued = false; results = ArchiveResults() }
    }

    /// Coming back to the screen with text still in the field.
    func resumeSearch() { if isSearching { scheduleFilter(after: .zero) } }

    private func listingArrived() {
        if isSearching, !filterQueued { scheduleFilter(after: debounce) }
    }

    private func scheduleFilter(after delay: Duration) {
        filter?.cancel()
        filterQueued = true
        let text = query
        filter = Task { [weak self] in
            if delay > .zero { do { try await Task.sleep(for: delay) } catch { return } }
            guard let self else { return }
            filterQueued = false
            readWhatsMissing()
            let pairs = everyPair
            var ready: [ArchiveListing] = [], failures: [(source: ArchiveSource, failure: ArchiveReadFailure)] = []
            for (set, dest) in pairs {
                switch listings[PairID(set: set.id, destination: dest.id)] {
                case .read(let listing): ready.append(listing)
                case .failed(let why): failures.append((ArchiveSource(set: set, destination: dest), why))
                case nil: break
                }
            }
            let matches = await Self.find(text, in: ready)
            guard !Task.isCancelled else { return }
            results = ArchiveResults(query: text, matches: matches, readCount: ready.count + failures.count, pairCount: pairs.count,
                                     unreadable: ArchiveUnreadable.summary(of: failures), isReading: !reads.isEmpty)
        }
    }

    @concurrent private static func find(_ text: String, in listings: [ArchiveListing]) async -> ArchiveMatches {
        ArchiveSearch.find(text, in: listings)
    }

    /// Only ever reads what has no listing and no read under way, so it's safe to call on each filter.
    private func readWhatsMissing() {
        for (set, dest) in everyPair {
            let pair = PairID(set: set.id, destination: dest.id)
            if listings[pair] == nil, reads[pair] == nil { _ = read(set, dest, urgent: false) }
        }
    }

    /// Tries the destinations that couldn't be read, once more.
    func retryUnreadable() {
        listings = listings.filter { if case .failed = $0.value { false } else { true } }
        resumeSearch()
    }

    /// A backup can archive more at any time, so what was read lasts only while the owner is on the screen.
    func forgetListings() {
        generation += 1
        reads.values.forEach { $0.cancel() }
        reads = [:]; listings = [:]
        filter?.cancel()
        filterQueued = false
        results = ArchiveResults()
        phase = .idle
    }

    /// Reads everything on show again.
    func reloadAll() async {
        forgetListings()
        resumeSearch()
        await reload()
        if mode == .latest { await reloadLatest() }
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
            let items = try await agent.turn(urgent: true) { [provider] in try await provider.browse(path: path, set: set, destination: dest) }
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
        await restore(ArchiveEntry(id: path, setName: set.name, stamp: now(), path: path, size: item?.size ?? 0,
                                   isFolder: item?.isFolder ?? true),
                      chooseLocation: chooseLocation)
    }

    /// Everything one run moved to the archive, as a folder. How a mass deletion is undone.
    func restoreRun(of entry: ArchiveEntry, chooseLocation: (ArchiveEntry) async -> URL?) async {
        await restore(runFolder(of: entry), chooseLocation: chooseLocation)
    }

    private func runFolder(of entry: ArchiveEntry) -> ArchiveEntry {
        let path = entry.path.split(separator: "/").prefix(3).joined(separator: "/")
        return ArchiveEntry(id: path, setName: entry.setName, stamp: entry.stamp, path: path, size: 0, isFolder: true)
    }

    func restoreRun(_ run: ArchiveRun, chooseLocation: (ArchiveEntry) async -> URL?) async {
        await restore(folder: run.root, of: run, chooseLocation: chooseLocation)
    }

    /// One folder of a run with all that's below it. The same guards as a whole run.
    func restore(folder: ArchiveFolder, of run: ArchiveRun, chooseLocation: (ArchiveEntry) async -> URL?) async {
        guard run.canRestoreFolders, let set = selectedSet else { return }
        await restore(ArchiveEntry(id: folder.path, setName: set.name, stamp: run.stamp, path: folder.path, size: folder.size, isFolder: true),
                      chooseLocation: chooseLocation)
    }

    /// Where the save panel opens: a file's original folder. A folder has no such place, as it can't go back there.
    func startFolder(for entry: ArchiveEntry) -> URL? {
        guard let set = selectedSet else { return nil }
        return startFolder(for: entry, in: set)
    }

    /// A hit can be from any set, and its path means nothing against the selected one.
    func startFolder(for hit: ArchiveHit) -> URL? {
        guard let set = sets.first(where: { $0.id == hit.source.pair.set }) else { return nil }
        return startFolder(for: hit.entry, in: set)
    }

    private func startFolder(for entry: ArchiveEntry, in set: BackupSet) -> URL? {
        guard !entry.isFolder, let original = RestoreTarget.original(of: entry.path, in: set) else { return nil }
        return RestoreTarget.startFolder(for: original, in: set)
    }

    /// Restores from the selected set and destination.
    func restore(_ entry: ArchiveEntry, chooseLocation: (ArchiveEntry) async -> URL?) async {
        guard let set = selectedSet, let dest = selectedDestination else { return }
        await restore(entry, from: set, dest, chooseLocation: chooseLocation)
    }

    /// Restores a search result from where it was found, which needn't be what the pickers show.
    func restore(_ hit: ArchiveHit, chooseLocation: (ArchiveEntry) async -> URL?) async {
        await restore(hit.entry, from: hit, chooseLocation: chooseLocation)
    }

    func restoreRun(of hit: ArchiveHit, chooseLocation: (ArchiveEntry) async -> URL?) async {
        await restore(runFolder(of: hit.entry), from: hit, chooseLocation: chooseLocation)
    }

    private func restore(_ entry: ArchiveEntry, from hit: ArchiveHit, chooseLocation: (ArchiveEntry) async -> URL?) async {
        guard let set = sets.first(where: { $0.id == hit.source.pair.set }),
              let dest = destinations.first(where: { $0.id == hit.source.pair.destination }) else {
            restoreState = .failed("\(hit.source.setName) on \(hit.source.destinationName) is no longer in Mirror.")
            return
        }
        await restore(entry, from: set, dest, chooseLocation: chooseLocation)
    }

    /// Restores one file or folder to a place the owner picks. A file can go back into a backed-up folder, where
    /// the save panel asks before replacing anything. A folder can't, as it could overwrite newer work file by file.
    private func restore(_ entry: ArchiveEntry, from set: BackupSet, _ dest: Destination, chooseLocation: (ArchiveEntry) async -> URL?) async {
        guard let target = await chooseLocation(entry) else { restoreState = .idle; return }
        if entry.isFolder, RestoreTarget.isInside(target, anyOf: sets.map(\.source)) {
            restoreState = .failed("Choose a place outside the folders Mirror backs up, so newer files aren't replaced.")
            return
        }
        let name = (entry.path as NSString).lastPathComponent
        restoreState = .restoring(name)
        // The save panel has already asked "Replace?" of anything it was pointed at.
        let replacing = FileManager.default.fileExists(atPath: target.path)
        do {
            // Ahead of any listing still waiting, or the owner would watch a search finish before getting the file back.
            try await agent.turn(urgent: true) { [provider] in
                try await provider.restore(entry: entry, set: set, destination: dest, to: target, replacing: replacing)
            }
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
func chooseRestoreLocation(for entry: ArchiveEntry, startingIn folder: URL?) async -> URL? {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = (entry.path as NSString).lastPathComponent
    panel.prompt = "Restore"
    panel.message = entry.isFolder ? "Choose where to put the restored copy. Your original files aren't touched."
                                   : "This is where the file was. Choose another place to keep both copies."
    panel.canCreateDirectories = true
    panel.directoryURL = folder ?? FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
    return await withCheckedContinuation { c in
        panel.begin { c.resume(returning: $0 == .OK ? panel.url : nil) }
    }
}

struct ArchiveView: View {
    @Bindable var model: ArchiveModel
    let agent: AgentClient?
    private var chooseLocation: (ArchiveEntry) async -> URL? {
        { [model] entry in await chooseRestoreLocation(for: entry, startingIn: model.startFolder(for: entry)) }
    }
    @State private var drill: DrillModel?
    @State private var showDrill = false
    @State private var focused: ArchiveEntry.ID?

    private func chooseLocation(for hit: ArchiveHit) -> (ArchiveEntry) async -> URL? {
        { [model] entry in await chooseRestoreLocation(for: entry, startingIn: model.startFolder(for: hit)) }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let due = model.drillDueDestinations.first { reminder(due) }
            if model.isSearching {
                searchResults
            } else {
                Picker("Show", selection: $model.mode) {
                    Text("Older Versions").tag(ArchiveModel.Mode.archive)
                    Text("Latest Backup").tag(ArchiveModel.Mode.latest)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .padding(.vertical, 8)
                if model.mode == .archive { content } else { latest }
            }
            if model.restoreState != .idle { restoreBar }
        }
        .navigationTitle("Archive")
        .searchable(text: $model.query, placement: .toolbar, prompt: "Search all archived files")
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
                Button { Task { await model.reloadAll() } } label: { Label("Reload", systemImage: "arrow.clockwise") }
                    .help("Read the archive again")
            }
        }
        .task(id: model.selection) {
            model.loadConfig()
            model.resetFolder()
            model.resumeSearch()
            await model.loadSelection()
            if model.mode == .latest { await model.reloadLatest() }
        }
        .onDisappear { model.forgetListings() }
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
        case .loaded(let runs):
            if runs.isEmpty {
                ContentUnavailableView("Nothing Archived", systemImage: "externaldrive.badge.checkmark",
                                       description: Text("Changed and deleted files are kept for \(model.selectedSet?.archiveDays ?? 30) days. None are kept right now."))
            } else {
                List(selection: $focused) {
                    ForEach(runs) { run in
                        ArchiveRunGroup(run: run, startsOpen: run.id == runs.first?.id, model: model, chooseLocation: chooseLocation)
                    }
                }
            }
        }
    }

    @ViewBuilder private var searchResults: some View {
        let results = model.results
        if results.matches.hits.isEmpty, results.unreadable.isEmpty {
            if results.isReading || results.query != model.query {
                ProgressView("Searching the archive").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView.search(text: model.query)
            }
        } else {
            VStack(spacing: 0) {
                HStack {
                    if results.isReading { ProgressView().controlSize(.small) }
                    Text(results.status).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal).padding(.vertical, 8)
                .accessibilityElement(children: .combine)
                List {
                    if !results.unreadable.isEmpty {
                        Section {
                            ForEach(results.unreadable) { unreadable in
                                VStack(alignment: .leading, spacing: 0) {
                                    Label(unreadable.destinationName, systemImage: "exclamationmark.triangle")
                                    Text(unreadable.text).font(.caption).foregroundStyle(.secondary)
                                }
                                .accessibilityElement(children: .combine)
                            }
                        } header: {
                            HStack {
                                Text("Not searched")
                                Spacer()
                                Button("Try Again") { model.retryUnreadable() }
                                    .accessibilityHint("Reads these destinations again")
                            }
                        }
                    }
                    if results.matches.hits.isEmpty {
                        Text(results.nothingFoundNote).foregroundStyle(.secondary)
                    } else {
                        Section { ForEach(results.matches.hits) { row($0) } }
                    }
                }
            }
        }
    }

    private func row(_ hit: ArchiveHit) -> some View {
        let archived = hit.entry.stamp.formatted(date: .abbreviated, time: .shortened)
        let place = "\(hit.source.setName) on \(hit.source.destinationName)"
        return HStack {
            Image(systemName: "doc").accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(hit.name).lineLimit(1)
                Text(hit.folder.isEmpty ? "\(place), archived \(archived)" : "\(place), in \(hit.folder), archived \(archived)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Text(hit.entry.size.formatted(.byteCount(style: .file))).foregroundStyle(.secondary)
            Button("Restore…") { Task { await model.restore(hit, chooseLocation: chooseLocation(for: hit)) } }
                .accessibilityLabel("Restore \(hit.name) from \(place)")
                .accessibilityHint("Asks where to put the restored copy")
        }
        .contextMenu {
            Button("Restore…") { Task { await model.restore(hit, chooseLocation: chooseLocation(for: hit)) } }
            Button("Restore Everything From This Run…") { Task { await model.restoreRun(of: hit, chooseLocation: chooseLocation(for: hit)) } }
        }
        .accessibilityElement(children: .contain)
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

/// One backup run. Starts closed unless it's the newest, as a big delete can be a run of thousands.
private struct ArchiveRunGroup: View {
    let run: ArchiveRun
    let model: ArchiveModel
    let chooseLocation: (ArchiveEntry) async -> URL?
    @State private var isOpen: Bool

    init(run: ArchiveRun, startsOpen: Bool, model: ArchiveModel, chooseLocation: @escaping (ArchiveEntry) async -> URL?) {
        self.run = run; self.model = model; self.chooseLocation = chooseLocation
        _isOpen = State(initialValue: startsOpen)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isOpen) {
            ArchiveFolderContents(folder: run.root, run: run, model: model, chooseLocation: chooseLocation)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 0) {
                    Text(run.stamp.formatted(date: .complete, time: .shortened)).lineLimit(1)
                    Text(archiveSummary(files: run.fileCount, size: run.size)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if run.canRestoreFolders {
                    Button("Restore Everything From This Run…") { Task { await model.restoreRun(run, chooseLocation: chooseLocation) } }
                        .accessibilityLabel("Restore everything from the run of \(run.stamp.formatted(date: .long, time: .shortened))")
                        .accessibilityHint("Asks where to put the restored copy")
                }
            }
            .accessibilityElement(children: .contain)
        }
    }
}

/// What's in a folder of a run. A closed group's contents aren't built, so a run costs what's been opened of it.
private struct ArchiveFolderContents: View {
    /// The list only draws what's on screen, but opening a group still takes time for each row in it: about 80 ms
    /// for this many, and 350 ms for a folder of 20,000, in a debug build. Past this the owner asks for more.
    private static let page = 2_000
    let folder: ArchiveFolder
    let run: ArchiveRun
    let model: ArchiveModel
    let chooseLocation: (ArchiveEntry) async -> URL?
    @State private var shown = page

    var body: some View {
        ForEach(folder.folders) { inner in
            DisclosureGroup {
                ArchiveFolderContents(folder: inner, run: run, model: model, chooseLocation: chooseLocation)
            } label: {
                HStack {
                    Label(inner.name, systemImage: "folder").lineLimit(1)
                    Spacer(minLength: 8)
                    Text(archiveSummary(files: inner.fileCount, size: inner.size)).foregroundStyle(.secondary).lineLimit(1)
                    if run.canRestoreFolders {
                        Button("Restore Folder…") { Task { await model.restore(folder: inner, of: run, chooseLocation: chooseLocation) } }
                            .accessibilityLabel("Restore folder \(inner.name)")
                            .accessibilityHint("Asks where to put the restored copy")
                    }
                }
                .accessibilityElement(children: .contain)
            }
        }
        ForEach(folder.files.prefix(shown)) { row($0) }
        if folder.files.count > shown {
            Button("Show More (\((folder.files.count - shown).formatted()) Left)") { shown += Self.page }
                .accessibilityHint("Adds more files from this folder to the list")
        }
    }

    private func row(_ entry: ArchiveEntry) -> some View {
        let name = (entry.path as NSString).lastPathComponent
        return HStack {
            Image(systemName: "doc").accessibilityHidden(true)
            Text(name).lineLimit(1)
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
}

private func archiveSummary(files: Int, size: Int64) -> String {
    "\(files == 1 ? "1 file" : "\(files.formatted()) files"), \(size.formatted(.byteCount(style: .file)))"
}
