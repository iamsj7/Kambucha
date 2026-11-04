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

@MainActor @Observable
final class AppModel {
    private(set) var sets: [BackupSet] = []
    private(set) var rows: [SetRow] = []
    private(set) var status: OverallStatus = .notConfigured
    /// Set when the owner chooses Review Deletions; Task 17 replaces the placeholder with the real sheet.
    var reviewingSet: UUID?
    private(set) var lastError: String?

    var isPaused: Bool { !sets.isEmpty && sets.allSatisfy(\.isPaused) }

    @ObservationIgnored private let support: URL
    @ObservationIgnored private let store: ConfigStore
    @ObservationIgnored private var watchers: [DispatchSourceFileSystemObject] = []

    init(support: URL = MirrorPaths.support) {
        self.support = support
        store = ConfigStore(root: support)
        refresh()
        startWatching()
    }

    // MARK: Reading state

    func refresh() {
        do {
            let sets = try store.loadSets()
            let destinations = try store.loadDestinations()
            var states: [PairID: SetState] = [:]
            for s in sets {
                for d in s.destinationIDs {
                    let p = PairID(set: s.id, destination: d)
                    if let st = try? store.state(for: p) { states[p] = st }
                }
            }
            let records = (try? RunRecordStore(root: support).recent(limit: 200)) ?? []
            let problems = (try? ProblemCenter(root: support, notifier: SilentNotifier()).active()) ?? []
            let running = Self.agentIsRunning(support: support)
            self.sets = sets
            status = StatusSummary.overall(sets: sets, destinations: destinations, states: states,
                                           records: records, problems: problems, running: running)
            rows = sets.map { s in
                SetRow(id: s.id, name: s.name, isPaused: s.isPaused,
                       status: s.isPaused ? .paused
                       : StatusSummary.overall(sets: [s], destinations: destinations, states: states,
                                               records: records, problems: problems, running: running))
            }
            lastError = nil
        } catch {
            lastError = "Mirror could not read its settings."
            status = .attention("Mirror could not read its settings")
        }
        reattachWatchers()
    }

    /// True while some process holds the agent-wide lock. Never creates the lock file.
    private nonisolated static func agentIsRunning(support: URL) -> Bool {
        let url = support.appendingPathComponent("locks/agent.lock")
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let lock = RunLock(url: url)
        if case .held = lock.attempt() { return true }
        lock.release()
        return false
    }

    // MARK: Actions

    /// Runs the agent for one set, or all sets when nil.
    func runNow(_ set: UUID?) {
        launchAgent(["--run-now"] + (set.map { [$0.uuidString] } ?? []))
    }

    func setPaused(_ paused: Bool) {
        var updated = sets
        for i in updated.indices { updated[i].isPaused = paused }
        do { try store.saveSets(updated); refresh() }
        catch { lastError = "Mirror could not save the pause setting." }
    }

    /// Placeholder until the review sheet (Task 17) exists: approving deletions needs the owner to see the list.
    func allowDeletes(_ set: UUID) { reviewingSet = set }

    func keepHolding() { reviewingSet = nil }

    /// The first set that has deletions held, for the Review Deletions action.
    var heldSet: SetRow? { rows.first { if case .held = $0.status { true } else { false } } }

    /// The agent lives next to the app binary. Never derived from argv.
    private func launchAgent(_ arguments: [String]) {
        let exe = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/MirrorAgent")
        let p = Process()
        p.executableURL = exe
        p.arguments = arguments
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run(); lastError = nil }
        catch { lastError = "Mirror could not start a backup." }
    }

    // MARK: Watching

    private func startWatching() { reattachWatchers() }

    private func reattachWatchers() {
        guard watchers.isEmpty else { return }
        for sub in ["", "state", "runs"] {
            let dir = sub.isEmpty ? support : support.appendingPathComponent(sub, isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let fd = open(dir.path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .extend],
                                                                queue: .main)
            src.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.scheduleRefresh() }
            }
            src.setCancelHandler { close(fd) }
            src.resume()
            watchers.append(src)
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
