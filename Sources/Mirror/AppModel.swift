import Foundation
import Observation
import AppKit
import MirrorCore

/// One row of the menu bar panel.
struct SetRow: Identifiable, Equatable {
    var id: UUID
    var name: String
    var isPaused: Bool
    var status: OverallStatus
    /// Whether `status` would need attention with no run under way. A run reads as running ahead of what's owed here.
    var attentionWhenIdle: Bool
}

extension SetRow {
    /// Judged as if idle, or sets needing the owner would sink for as long as any backup runs.
    var sortKey: SetSortKey { SetSortKey(id: id, name: name, needsAttention: attentionWhenIdle) }
}

extension Array where Element == SetRow {
    /// By name alone, so a change of status can't move a row as it's clicked.
    var byName: [SetRow] {
        var order = SetOrder()
        order.update(map { SetSortKey(id: $0.id, name: $0.name, needsAttention: false) }, held: false)
        return order.arranged(self)
    }
}

/// One live progress line for the panel.
struct ProgressItem: Identifiable, Equatable, Sendable {
    var id: PairID { progress.pair }
    var label: String
    var progress: TransferProgress
}

/// Everything `refresh()` reads from disk, computed off the main thread.
private struct Snapshot: Sendable {
    var sets: [BackupSet]
    var status: OverallStatus
    var rows: [SetRow]
    var destinations: [Destination]
    var states: [PairID: SetState]
    var pairStatus: [PairID: OverallStatus]
    var progress: [ProgressItem]
    var running: Bool

    /// `volumes` is nil until the first read of the mounted drives: no drive is called away on a guess.
    static func load(support: URL, volumes: [VolumeInfo]?, turnedOn: [PairID: Date] = [:]) -> Snapshot? {
        let store = ConfigStore(root: support)
        guard let sets = try? store.loadSets(), let destinations = try? store.loadDestinations() else { return nil }
        var saved: [PairID: SetState] = [:]
        for s in sets {
            for d in s.destinationIDs {
                let p = PairID(set: s.id, destination: d)
                if let st = try? store.state(for: p) { saved[p] = st }
            }
        }
        let states = StatusSummary.withTurnedOn(saved, turnedOn: turnedOn)
        // `overall` ignores skipped runs, so they must not crowd real ones out of the 200.
        let records = (try? RunRecordStore(root: support).recent(limit: 200, matching: RunFilter())) ?? []
        let problems = (try? ProblemCenter(root: support, notifier: NoNotifier()).active()) ?? []
        let running = AgentPresence.isRunning(support: support)
        // Progress belongs to a live agent only; a file left by a killed one is ignored.
        let live = running ? ((try? ProgressStore(root: support).all(now: Date())) ?? []) : []
        let items: [ProgressItem] = live.compactMap { p in
            guard let set = sets.first(where: { $0.id == p.pair.set }) else { return nil }
            let dest = destinations.first { $0.id == p.pair.destination }?.name
            return ProgressItem(label: dest.map { "\(set.name) to \($0)" } ?? set.name, progress: p)
        }.sorted { $0.label < $1.label }
        let disconnected = volumes.map { ExternalVolume.disconnected(destinations, in: $0) } ?? []
        func judged(_ ss: [BackupSet], running: Bool) -> OverallStatus {
            let status = StatusSummary.overall(sets: ss, destinations: destinations, states: states, records: records,
                                               problems: problems, running: running, disconnected: disconnected)
            return StatusSummary.withPreviewNeeded(status, sets: ss)
        }
        func row(_ s: BackupSet) -> SetRow {
            let status = s.isPaused ? OverallStatus.paused : judged([s], running: running)
            let idle = running && !s.isPaused ? judged([s], running: false) : status
            return SetRow(id: s.id, name: s.name, isPaused: s.isPaused, status: status, attentionWhenIdle: idle.needsAttention)
        }
        return Snapshot(sets: sets, status: judged(sets, running: running), rows: sets.map(row),
                        destinations: destinations, states: states,
                        pairStatus: StatusSummary.pairStatuses(sets: sets, destinations: destinations, states: states, records: records,
                                                               problems: problems, running: Set(live.map(\.pair)), disconnected: disconnected),
                        progress: items, running: running)
    }
}

/// Keeps the tail of a process's stderr, bounded.
private final class BoundedBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let limit = 2048
    func append(_ d: Data) {
        lock.withLock { data.append(d); if data.count > limit { data = data.suffix(limit) } }
    }
    var text: String {
        lock.withLock { String(decoding: data, as: UTF8.self) }.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@MainActor @Observable
final class AppModel {
    private(set) var sets: [BackupSet] = []
    private(set) var rows: [SetRow] = []
    private(set) var status: OverallStatus = .notConfigured
    private(set) var destinations: [Destination] = []
    private(set) var states: [PairID: SetState] = [:]
    /// Each set at each of its destinations, judged as `rows` are.
    private(set) var pairStatus: [PairID: OverallStatus] = [:]
    private(set) var progress: [ProgressItem] = []
    /// Mounted drives, read off the main thread and refreshed when the system mounts or unmounts one.
    @ObservationIgnored let volumeCache: VolumeCache
    @ObservationIgnored let eject: EjectController
    /// Set when the owner chooses Review Deletions; the review window shows that set's held deletions.
    var reviewingSet: UUID?
    /// Sets to run once the backup under way ends, as what it's doing was decided before the owner's latest choice.
    private(set) var queuedRuns: [UUID] = []
    /// Why the review is still open, shown in it. Ends with the review.
    private(set) var reviewNotice: String?
    /// Sticky: cleared only by `dismissError()` or the next owner action. `refresh()` never touches it.
    private(set) var lastError: String?

    var isPaused: Bool { !sets.isEmpty && sets.allSatisfy(\.isPaused) }

    @ObservationIgnored let support: URL
    @ObservationIgnored private let store: ConfigStore
    @ObservationIgnored let services: AppServices
    @ObservationIgnored private nonisolated(unsafe) var watchers: [String: DispatchSourceFileSystemObject] = [:]
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var process: Process?
    /// Next to the app binary, never derived from argv. Tests point it at a stand-in.
    @ObservationIgnored var agentExecutable = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/MirrorAgent")
    @ObservationIgnored private var runQueue = RunQueue()
    @ObservationIgnored private var surfaces = SurfaceVisibility()
    /// When each pair was last turned on. Kept here and not in its state file, which is the agent's: there `wholeSetOwed`
    /// would widen the next run. A relaunch forgets it, and the pair reads as its state does.
    @ObservationIgnored private var turnedOn: [PairID: Date] = [:]
    /// The sets Pause Backups paused, so Resume Backups leaves any paused on their own.
    @ObservationIgnored private var pausedTogether: Set<UUID> = []
    private var agentRunning = false
    @ObservationIgnored private var poller: Task<Void, Never>?

    init(support: URL = MirrorPaths.support, services: AppServices = .live) {
        self.support = support
        self.services = services
        store = ConfigStore(root: support)
        let cache = VolumeCache(locator: services.volumes, center: NSWorkspace.shared.notificationCenter,
                                names: [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification,
                                        NSWorkspace.didRenameVolumeNotification])
        volumeCache = cache
        eject = EjectController(ejector: services.ejector, isBackupRunning: { false }, refresh: { await cache.refresh() })
        // Eject also asks the lock itself, so a launchd run this app hasn't loaded yet still blocks it.
        eject.isBackupRunning = { [weak self] in
            guard let self else { return false }
            return self.isBackupActive || AgentLockProbe.isHeld(support: self.support)
        }
        if let snap = Snapshot.load(support: support, volumes: nil) { apply(snap) }   // first paint is synchronous
        else { status = .attention("Mirror could not read its settings") }
        attachMissingWatchers()
        cache.onChange = { [weak self] in self?.refresh() }
        Task { await cache.refresh() }
    }

    /// An agent this app launched, or one launchd started, is working. Read from the last state load (the poller keeps it
    /// current while anything is visible), never from disk per render.
    var isBackupActive: Bool { agentRunning || process?.isRunning == true }

    deinit {
        for w in watchers.values { w.cancel() }
        poller?.cancel()
    }

    // MARK: Reading state

    /// Reads state files off the main thread and applies the newest result.
    func refresh() {
        generation += 1
        let mine = generation
        let support = support, volumes = loadedVolumes, turnedOn = turnedOn
        Task { [weak self] in
            let snap = await Task.detached(priority: .utility) {
                Snapshot.load(support: support, volumes: volumes, turnedOn: turnedOn)
            }.value
            guard let self, mine == self.generation else { return }
            if let snap { self.apply(snap) } else { self.status = .attention("Mirror could not read its settings") }
            self.attachMissingWatchers()
            self.updatePolling()
        }
    }

    /// Reads state now, for a change made outside this model that the next line depends on.
    func reload() {
        if let snap = Snapshot.load(support: support, volumes: loadedVolumes, turnedOn: turnedOn) { apply(snap) }
    }

    private var loadedVolumes: [VolumeInfo]? { volumeCache.hasLoaded ? volumeCache.volumes : nil }

    private func apply(_ snap: Snapshot) {
        sets = snap.sets; rows = snap.rows; status = snap.status; progress = snap.progress
        agentRunning = snap.running
        destinations = snap.destinations; states = snap.states; pairStatus = snap.pairStatus
        startQueuedRun()
    }

    /// Asks for a run of `set` now, or as soon as the one under way ends.
    func runSoon(_ set: UUID) {
        if runsMustWait { enqueue([set]) } else { runNow(set) }
    }

    /// A batch counts until its last set has gone, as its agent's exit may not have reached this model yet.
    private var runsMustWait: Bool { isBackupActive || !runQueue.waiting.isEmpty }

    private func enqueue(_ ids: [UUID]) {
        for id in ids where !queuedRuns.contains(id) && !runQueue.waiting.contains(id) { queuedRuns.append(id) }
    }

    /// Asked for while another backup is under way. That one's queue is left alone, and these follow it.
    private func runAfterwards(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        enqueue(ids)
        lastError = [lastError, Self.queuedText].compactMap(\.self).joined(separator: " ")
    }

    /// Every state load comes here, and the end of any run, launchd's included, changes the folders being watched.
    private func startQueuedRun() {
        guard !queuedRuns.isEmpty, !isBackupActive, runQueue.waiting.isEmpty, !AgentLockProbe.isHeld(support: support) else { return }
        runNow(queuedRuns.removeFirst())
    }

    // MARK: Panel visibility and polling

    func panelAppeared() { surfaceAppeared(.panel) }
    func panelDisappeared() { surfaceDisappeared(.panel) }
    func windowAppeared() { surfaceAppeared(.window) }
    func windowDisappeared() { surfaceDisappeared(.window) }

    private func surfaceAppeared(_ s: SurfaceVisibility.Surface) {
        surfaces.appeared(s)
        attachMissingWatchers()
        refresh(); updatePolling()
    }

    private func surfaceDisappeared(_ s: SurfaceVisibility.Surface) {
        surfaces.disappeared(s)
        // The progress folder is written every 2 s during a run; once nobody is looking, stop watching it.
        if !surfaces.anyVisible { watchers.removeValue(forKey: "progress")?.cancel() }
        updatePolling()
    }

    /// Whether the progress folder is being watched. For tests.
    var isWatchingProgress: Bool { watchers["progress"] != nil }

    private var isRunning: Bool { if case .running = status { true } else { false } }

    /// A light timer runs only while the panel or the main window is visible or a backup is running: it keeps relative
    /// times current and clears a stale pid file after a crash. Idle costs nothing.
    private func updatePolling() {
        guard surfaces.anyVisible || isRunning else { poller?.cancel(); poller = nil; return }
        guard poller == nil else { return }
        poller = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, !Task.isCancelled else { return }
                self.refresh()
            }
        }
    }

    // MARK: Actions

    func dismissError() { lastError = nil }

    /// Runs the agent for one set, or all sets when nil.
    func runNow(_ set: UUID?) {
        lastError = nil
        // Starting a run while a drive unmounts could write to a drive that is going away.
        guard !eject.isEjecting else { lastError = "A drive is being ejected. Start the backup when it finishes."; return }
        // No backup for a set starts until its preview was accepted once (spec section 9).
        // Accepted sets still run; the others are named so the owner can preview them.
        let plan = RunNowPlan.make(sets: sets, target: set, isAccepted: \.isPreviewAccepted)
        if !plan.unaccepted.isEmpty {
            lastError = "Preview before the first backup: \(plan.unaccepted.joined(separator: ", ")). Open each in Mirror and choose Preview Backup."
        }
        if runsMustWait { runAfterwards(plan.run); return }
        runQueue.start(.all)
        guard !plan.run.isEmpty else { return }
        if set == nil && plan.unaccepted.isEmpty {
            launchAgent(["--run-now"])
        } else {
            runQueue.start(.sets(plan.run))
            if let id = runQueue.first { launchAgent(["--run-now", id.uuidString]) }
        }
    }

    func setPaused(_ paused: Bool) {
        var updated = sets
        if paused {
            pausedTogether.formUnion(sets.filter { !$0.isPaused }.map(\.id))
            for i in updated.indices { updated[i].isPaused = true }
        } else {
            // With no record, as after a relaunch, Resume is all there is to go on.
            let chosen = pausedTogether.intersection(sets.map(\.id))
            for i in updated.indices where chosen.isEmpty || chosen.contains(updated[i].id) { updated[i].isPaused = false }
            pausedTogether = []
        }
        commit(updated, failure: Self.pauseFailedText)
    }

    /// Several sets, one after the other. Paused sets stay out, as Back Up Now is off for them on their own page.
    func runNow(sets ids: Set<UUID>) {
        lastError = nil
        guard !eject.isEjecting else { lastError = "A drive is being ejected. Start the backup when it finishes."; return }
        let plan = SetBatch(sets: sets.filter { ids.contains($0.id) }).runPlan
        lastError = SetBatch.runNotice(plan)
        if runsMustWait { runAfterwards(plan.run); return }
        runQueue.start(.all)
        guard !plan.run.isEmpty else { return }
        runQueue.start(.sets(plan.run))
        if let id = runQueue.first { launchAgent(["--run-now", id.uuidString]) }
    }

    func setPaused(_ paused: Bool, sets ids: Set<UUID>) {
        var updated = sets
        for i in updated.indices where ids.contains(updated[i].id) { updated[i].isPaused = paused }
        pausedTogether.subtract(ids)
        commit(updated, failure: Self.pauseFailedText)
    }

    /// Opens the deletion review. Approving deletions needs the owner to see the list first.
    func allowDeletes(_ set: UUID) { lastError = nil; reviewNotice = nil; reviewingSet = set }

    func keepHolding() { reviewingSet = nil; reviewNotice = nil }

    static let busyText = "A backup is running. Try again shortly."
    static let queuedText = "A backup is running. The next one starts when it finishes."
    private static let pauseFailedText = "Mirror could not save the pause setting."

    /// Launches the agent with the count the owner reviewed; it holds again if the list has grown. False, with the
    /// review left open, while a run holds the lock: the agent couldn't take this, and the approval mustn't vanish.
    @discardableResult
    func allowOnce(arguments: [String]) -> Bool {
        lastError = nil
        if isBackupActive || AgentLockProbe.isHeld(support: support) {
            reviewNotice = Self.busyText
            return false
        }
        let reviewed = reviewingSet
        keepHolding()
        launchAgent(arguments, reviewing: reviewed)
        return true
    }

    // MARK: Editing sets and destinations

    func set(_ id: UUID) -> BackupSet? { sets.first { $0.id == id } }
    func destination(_ id: UUID) -> Destination? { destinations.first { $0.id == id } }

    /// Adds a new set or replaces the one with the same id.
    func save(set updated: BackupSet) {
        var all = sets
        if let i = all.firstIndex(where: { $0.id == updated.id }) { all[i] = updated } else { all.append(updated) }
        noteTurnedOn(all)
        persist { try store.saveSets(all) }
    }

    func removeSet(_ id: UUID) {
        persist { try store.saveSets(sets.filter { $0.id != id }) }
    }

    /// The same change as the switch on the set's page, and saved the same way.
    func setDestination(_ destination: UUID, on: Bool, for setID: UUID) {
        let updated = sets.map { $0.id == setID ? $0.withDestination(destination, on: on) : $0 }
        noteTurnedOn(updated)
        commit(updated)
    }

    /// One save for all of them, as each save reads every pair's state again.
    func addDestination(_ destination: UUID, to ids: Set<UUID>) {
        let updated = sets.map { ids.contains($0.id) ? $0.withDestination(destination, on: true) : $0 }
        noteTurnedOn(updated)
        commit(updated)
    }

    func removeSets(_ ids: Set<UUID>) {
        persist { try store.saveSets(sets.filter { !ids.contains($0.id) }) }
    }

    func save(destination updated: Destination) {
        // One drive is one destination: identity is the volume UUID.
        if updated.kind == .externalDrive, let uuid = updated.volumeUUID,
           let existing = DestinationRules.duplicateDrive(of: uuid, in: destinations, excluding: updated.id) {
            lastError = DestinationRules.duplicateDriveMessage(existing)
            return
        }
        var all = destinations
        if let i = all.firstIndex(where: { $0.id == updated.id }) { all[i] = updated } else { all.append(updated) }
        persist { try store.saveDestinations(all) }
    }

    func removeDestination(_ id: UUID) {
        var updatedSets = sets
        for i in updatedSets.indices { updatedSets[i].destinationIDs.removeAll { $0 == id } }
        persist {
            try store.saveDestinations(destinations.filter { $0.id != id })
            try store.saveSets(updatedSets)
        }
    }

    func report(_ message: String) { lastError = message }

    private func persist(_ write: () throws -> Void) {
        lastError = nil
        do { try write() } catch { lastError = "Mirror could not save your changes." }
        // Apply at once so the screen the owner is on reflects the change before the file watcher fires.
        reload()
        // A pair that's gone can't be cleared by any run, so its problems end with it.
        try? ProblemCenter(root: support, notifier: NoNotifier()).retain(pairs: BackupSet.pairs(of: sets))
        refresh()
    }

    /// For a click that may be one of many. `sets` changes now, so the next edit builds on it, and what's judged from
    /// every state file follows from the background read.
    private func commit(_ updated: [BackupSet], failure: String = "Mirror could not save your changes.") {
        lastError = nil
        do { try store.saveSets(updated) } catch { lastError = failure; return }
        sets = updated
        try? ProblemCenter(root: support, notifier: NoNotifier()).retain(pairs: BackupSet.pairs(of: sets))
        refresh()
    }

    /// Call before `sets` changes. A new set has no earlier copy to fall behind, so only sets already here count.
    private func noteTurnedOn(_ updated: [BackupSet]) {
        let now = Date()
        for s in updated {
            guard let before = set(s.id) else { continue }
            for d in s.destinationIDs where !before.destinationIDs.contains(d) { turnedOn[PairID(set: s.id, destination: d)] = now }
        }
    }

    /// The first set that has deletions held, for the Review Deletions action.
    var heldSet: SetRow? { rows.first { if case .held = $0.status { true } else { false } } }

    /// The agent lives next to the app binary. Never derived from argv.
    private func launchAgent(_ arguments: [String], reviewing: UUID? = nil) {
        // One agent at a time: a second launch would let the first one's exit advance the new queue.
        if process?.isRunning == true {
            runQueue.start(.all)
            lastError = "A backup is already running. Try again when it finishes."
            return
        }
        let p = Process()
        p.executableURL = agentExecutable
        p.arguments = arguments
        let err = Pipe()
        let buffer = BoundedBuffer()
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = err
        err.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil } else { buffer.append(d) }
        }
        p.terminationHandler = { [weak self] proc in
            err.fileHandleForReading.readabilityHandler = nil
            let code = proc.terminationStatus
            let tail = buffer.text
            Task { @MainActor in
                guard let self else { return }
                let isCurrent = self.process === proc
                if isCurrent { self.process = nil }
                self.agentExited(code: code, tail: tail, reviewing: reviewing)
                self.refresh()
                if isCurrent, let id = self.runQueue.next(afterExit: code) { self.launchAgent(["--run-now", id.uuidString]) }
            }
        }
        do { try p.run(); process = p }
        catch {
            runQueue.start(.all)   // no exit is coming to move it on
            lastError = "Mirror could not start a backup: \(error.localizedDescription)"
        }
    }

    /// `reviewing` is the set whose approval this launch carried. A launchd run can take the lock between the
    /// check and the launch, so that review comes back rather than the approval being lost.
    func agentExited(code: Int32, tail: String, reviewing: UUID?) {
        guard code != 0 else { return }
        if code == AgentExit.busy {
            if let reviewing { reviewingSet = reviewing; reviewNotice = Self.busyText } else { lastError = Self.busyText }
            return
        }
        let why = tail.split(separator: "\n").last.map(String.init) ?? ""
        lastError = "The backup agent stopped with code \(code)." + (why.isEmpty ? "" : " \(why)")
    }

    // MARK: Watching

    private static let watched = ["", "state", "runs"]

    /// Attaches a watcher for each folder that doesn't have one. A folder that was replaced has its
    /// old watcher cancelled first, so the new one is picked up on the next refresh.
    private func attachMissingWatchers() {
        let wanted = surfaces.anyVisible ? Self.watched + ["progress"] : Self.watched
        for sub in wanted where watchers[sub] == nil {
            let dir = sub.isEmpty ? support : support.appendingPathComponent(sub, isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let fd = open(dir.path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let src = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd, eventMask: [.write, .rename, .delete, .extend, .link], queue: .main)
            src.setEventHandler { [weak self, weak src] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let src, !src.data.isDisjoint(with: [.delete, .rename]) {
                        src.cancel()
                        self.watchers[sub] = nil
                    }
                    self.scheduleRefresh()
                }
            }
            src.setCancelHandler { close(fd) }
            src.resume()
            watchers[sub] = src
        }
    }

    @ObservationIgnored private var pending = false
    /// Coalesces bursts of file events into one refresh.
    private func scheduleRefresh() {
        guard !pending else { return }
        pending = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            self?.pending = false
            self?.refresh()
        }
    }
}
