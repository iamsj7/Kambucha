import Foundation
import Observation
import MirrorCore

/// A notifier that never posts: the app only reads problems; the agent raises them.
private struct SilentNotifier: Notifying {
    func post(_ problem: Problem, pair: PairID, setName: String, detail: String) async -> Bool { false }
}

/// One row of the menu bar panel.
struct SetRow: Identifiable, Equatable {
    var id: UUID
    var name: String
    var isPaused: Bool
    var status: OverallStatus
}

/// Everything `refresh()` reads from disk, computed off the main thread.
private struct Snapshot: Sendable {
    var sets: [BackupSet]
    var status: OverallStatus
    var rows: [SetRow]

    static func load(support: URL) -> Snapshot? {
        let store = ConfigStore(root: support)
        guard let sets = try? store.loadSets(), let destinations = try? store.loadDestinations() else { return nil }
        var states: [PairID: SetState] = [:]
        for s in sets {
            for d in s.destinationIDs {
                let p = PairID(set: s.id, destination: d)
                if let st = try? store.state(for: p) { states[p] = st }
            }
        }
        let records = (try? RunRecordStore(root: support).recent(limit: 200)) ?? []
        let problems = (try? ProblemCenter(root: support, notifier: SilentNotifier()).active()) ?? []
        let running = AgentPresence.isRunning(support: support)
        func overall(_ ss: [BackupSet]) -> OverallStatus {
            StatusSummary.overall(sets: ss, destinations: destinations, states: states,
                                  records: records, problems: problems, running: running)
        }
        return Snapshot(sets: sets, status: overall(sets),
                        rows: sets.map { SetRow(id: $0.id, name: $0.name, isPaused: $0.isPaused,
                                                status: $0.isPaused ? .paused : overall([$0])) })
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
    /// Set when the owner chooses Review Deletions; Task 17 replaces the placeholder with the real sheet.
    var reviewingSet: UUID?
    /// Sticky: cleared only by `dismissError()` or the next owner action. `refresh()` never touches it.
    private(set) var lastError: String?

    var isPaused: Bool { !sets.isEmpty && sets.allSatisfy(\.isPaused) }

    @ObservationIgnored private let support: URL
    @ObservationIgnored private let store: ConfigStore
    @ObservationIgnored private nonisolated(unsafe) var watchers: [String: DispatchSourceFileSystemObject] = [:]
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var panelVisible = false
    @ObservationIgnored private var poller: Task<Void, Never>?

    init(support: URL = MirrorPaths.support) {
        self.support = support
        store = ConfigStore(root: support)
        if let snap = Snapshot.load(support: support) { apply(snap) }   // first paint is synchronous
        else { status = .attention("Mirror could not read its settings") }
        attachMissingWatchers()
    }

    deinit {
        for w in watchers.values { w.cancel() }
        poller?.cancel()
    }

    // MARK: Reading state

    /// Reads state files off the main thread and applies the newest result.
    func refresh() {
        generation += 1
        let mine = generation
        let support = support
        Task { [weak self] in
            let snap = await Task.detached(priority: .utility) { Snapshot.load(support: support) }.value
            guard let self, mine == self.generation else { return }
            if let snap { self.apply(snap) } else { self.status = .attention("Mirror could not read its settings") }
            self.attachMissingWatchers()
            self.updatePolling()
        }
    }

    private func apply(_ snap: Snapshot) {
        sets = snap.sets; rows = snap.rows; status = snap.status
    }

    // MARK: Panel visibility and polling

    func panelAppeared() { panelVisible = true; refresh(); updatePolling() }
    func panelDisappeared() { panelVisible = false; updatePolling() }

    private var isRunning: Bool { if case .running = status { true } else { false } }

    /// A light timer runs only while the panel is visible or a backup is running: it keeps relative
    /// times current and clears a stale pid file after a crash. Idle costs nothing.
    private func updatePolling() {
        guard panelVisible || isRunning else { poller?.cancel(); poller = nil; return }
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
        launchAgent(["--run-now"] + (set.map { [$0.uuidString] } ?? []))
    }

    func setPaused(_ paused: Bool) {
        lastError = nil
        var updated = sets
        for i in updated.indices { updated[i].isPaused = paused }
        do { try store.saveSets(updated); refresh() }
        catch { lastError = "Mirror could not save the pause setting." }
    }

    /// Placeholder until the review sheet (Task 17) exists: approving deletions needs the owner to see the list.
    func allowDeletes(_ set: UUID) { lastError = nil; reviewingSet = set }

    func keepHolding() { reviewingSet = nil }

    /// The first set that has deletions held, for the Review Deletions action.
    var heldSet: SetRow? { rows.first { if case .held = $0.status { true } else { false } } }

    /// The agent lives next to the app binary. Never derived from argv.
    private func launchAgent(_ arguments: [String]) {
        let exe = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/MirrorAgent")
        let p = Process()
        p.executableURL = exe
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
                if self.process === proc { self.process = nil }
                if code != 0 {
                    let why = tail.split(separator: "\n").last.map(String.init) ?? ""
                    self.lastError = "The backup agent stopped with code \(code)." + (why.isEmpty ? "" : " \(why)")
                }
                self.refresh()
            }
        }
        do { try p.run(); process = p }
        catch { lastError = "Mirror could not start a backup: \(error.localizedDescription)" }
    }

    // MARK: Watching

    private static let watched = ["", "state", "runs"]

    /// Attaches a watcher for each folder that doesn't have one. A folder that was replaced has its
    /// old watcher cancelled first, so the new one is picked up on the next refresh.
    private func attachMissingWatchers() {
        for sub in Self.watched where watchers[sub] == nil {
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
