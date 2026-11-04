import Testing
import Foundation
@testable import MirrorCore

private let hour: TimeInterval = 3600

private final class FakeRclone: RcloneRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var _syncs: [SyncRequest] = [], _checks: [CheckRequest] = []
    private var _real: [RcloneResult.Outcome] = []
    private var _dryOutcome = RcloneResult.Outcome.success
    private var _dryDeletions: [String] = [], _copied: [String] = []
    private var _differences = 0, _matching = 0
    private var _checkOutcome = RcloneResult.Outcome.success
    private var _throwOnRealSync = false
    private var _planned: [String] = [], _hashDifferences = 0, _differing: [String] = [], _killCheck = false
    private var _hashed: [[String]] = []
    private var _realErrors: [String] = []
    private var _realThrow: (any Error)?
    private var _deepDifferences = 0
    func failRealSync(_ e: (any Error)?) { lock.withLock { _realThrow = e } }
    var onDryRun: (@Sendable () -> Void)?
    var onRealSync: (@Sendable () -> Void)?

    var hashed: [[String]] { lock.withLock { _hashed } }
    var syncs: [SyncRequest] { lock.withLock { _syncs } }
    var realSyncs: [SyncRequest] { syncs.filter { !$0.dryRun } }
    var dryRuns: [SyncRequest] { syncs.filter(\.dryRun) }
    var checks: [CheckRequest] { lock.withLock { _checks } }
    var allCalls: Int { syncs.count + checks.count }

    /// One outcome per real sync; `.success` once used up.
    func script(real: [RcloneResult.Outcome] = [], dryDeletions: [String] = [], copied: [String] = [],
                differences: Int = 0, matching: Int = 0, checkOutcome: RcloneResult.Outcome = .success,
                dryOutcome: RcloneResult.Outcome = .success, killRealSync: Bool = false, planned: [String] = [],
                hashDifferences: Int = 0, differing: [String] = [], killCheck: Bool = false, errors: [String] = [],
                deepDifferences: Int = 0) {
        lock.withLock {
            _deepDifferences = deepDifferences
            _planned = planned; _hashDifferences = hashDifferences; _differing = differing; _killCheck = killCheck
            _realErrors = errors
            _real = real; _dryDeletions = dryDeletions; _copied = copied; _differences = differences
            _matching = matching; _checkOutcome = checkOutcome; _dryOutcome = dryOutcome; _throwOnRealSync = killRealSync
        }
    }

    func sync(_ r: SyncRequest) async throws -> RcloneResult {
        (r.dryRun ? onDryRun : onRealSync)?()
        return try lock.withLock {
            _syncs.append(r)
            var s = LogSummary()
            if r.dryRun {
                s.deleted = _dryDeletions
                s.planned = _planned
                return RcloneResult(exitCode: 0, summary: s, outcome: _dryOutcome)
            }
            if _throwOnRealSync { throw CancellationError() }
            if let _realThrow { throw _realThrow }
            s.copied = _copied
            let outcome = _real.isEmpty ? .success : _real.removeFirst()
            if outcome != .success { s.errors = _realErrors.isEmpty ? ["boom"] : _realErrors }
            return RcloneResult(exitCode: outcome == .success ? 0 : 1, summary: s, outcome: outcome)
        }
    }

    func check(_ r: CheckRequest) async throws -> RcloneResult {
        try lock.withLock {
            if _killCheck { throw CancellationError() }
            _checks.append(r)
            var s = LogSummary()
            s.differences = _differences; s.matching = _matching
            let deep = r.logFile.lastPathComponent.hasPrefix("deep")
            if deep { s.differences += _deepDifferences }
            if s.differences > 0 || r.filesFrom != nil && _hashDifferences > 0 { s.flagged = _differing }
            if let list = r.filesFrom {
                _hashed.append(((try? String(contentsOf: list, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init))
                s.differences += _hashDifferences
            }
            return RcloneResult(exitCode: 0, summary: s, outcome: _checkOutcome)
        }
    }
}

private final class FakeFeed: ChangeFeeding, @unchecked Sendable {
    private let lock = NSLock()
    private var _batch = ChangeBatch(paths: [], mustRescan: false, latestEventID: 10)
    private var _since: [UInt64?] = []
    private var _changedLater: ChangeBatch?
    var since: [UInt64?] { lock.withLock { _since } }
    var calls: Int { since.count }
    func set(_ b: ChangeBatch, changedLater: ChangeBatch? = nil) { lock.withLock { _batch = b; _changedLater = changedLater } }

    /// Like FSEvents: replaying from the batch's own latest ID shows nothing new.
    func changes(in: URL, since: UInt64?) async throws -> ChangeBatch {
        lock.withLock {
            _since.append(since)
            if since == _batch.latestEventID {
                return _changedLater ?? ChangeBatch(paths: [], mustRescan: false, latestEventID: _batch.latestEventID)
            }
            return _batch
        }
    }
}

private final class FakeAuditor: UploadAuditing, @unchecked Sendable {
    private let lock = NSLock()
    private var _unreadable = Set<String>()
    func set(unreadable: Set<String>) { lock.withLock { _unreadable = unreadable } }
    func ubiquity(of url: URL) -> Bool? {
        if lock.withLock({ _unreadable.contains(url.lastPathComponent) }) { return nil }
        return audit([url]).refused.isEmpty
    }
    private var _pending = Set<String>(), _refused = Set<String>(), _calls: [[URL]] = []
    var calls: [[URL]] { lock.withLock { _calls } }
    func set(pending: Set<String> = [], refused: Set<String> = []) { lock.withLock { _pending = pending; _refused = refused } }
    func audit(_ urls: [URL]) -> AuditResult {
        lock.withLock {
            _calls.append(urls)
            var r = AuditResult(pending: [], refused: [])
            for u in urls {
                if _pending.contains(u.lastPathComponent) { r.pending.append(u.path) }
                else if _refused.contains(u.lastPathComponent) { r.refused.append(u.path) }
                else if !FileManager.default.fileExists(atPath: u.path) && u.lastPathComponent.hasPrefix("gone") { r.missing.append(u.path) }
            }
            return r
        }
    }
}

private final class FakeDownloader: ICloudDownloading, @unchecked Sendable {
    private let lock = NSLock()
    private var _requested: [URL] = []
    private var _error: (any Error)?
    var requested: [URL] { lock.withLock { _requested } }
    func fail(_ e: (any Error)?) { lock.withLock { _error = e } }
    func requestDownload(of url: URL) throws {
        try lock.withLock {
            _requested.append(url)
            if let _error { throw _error }
        }
    }
}

private final class RecordingNotifier: Notifying, @unchecked Sendable {
    private let lock = NSLock()
    private var _posts: [(Problem, PairID)] = []
    private var _details: [String] = []
    var onPost: (@Sendable () -> Void)?
    var details: [String] { lock.withLock { _details } }
    var posted: [Problem] { lock.withLock { _posts.map(\.0) } }
    func post(_ p: Problem, pair: PairID, setName: String, detail: String) async -> Bool {
        onPost?()
        lock.withLock { _posts.append((p, pair)); _details.append(detail) }
        return true
    }
}

private final class FakeSession: RunSession, @unchecked Sendable {
    let endpoint: String
    let openError: (any Error)?
    private let lock = NSLock()
    private var _opens = 0, _closes = 0
    var opens: Int { lock.withLock { _opens } }
    var closes: Int { lock.withLock { _closes } }
    init(endpoint: String, openError: (any Error)? = nil) { self.endpoint = endpoint; self.openError = openError }
    func open() throws -> (endpoint: String, context: RcloneContext) {
        lock.withLock { _opens += 1 }
        if let openError { throw openError }
        return (endpoint, RcloneContext(configPath: "/private/run.conf", environment: ["K": "V"]))
    }
    func close() throws { lock.withLock { _closes += 1 } }
}

private final class FakeFiles: RemoteFileAccessing, @unchecked Sendable {
    private let lock = NSLock()
    private var _files: [String: Data] = [:]
    private var _listings: [String: [String]] = [:]
    private var _calls = 0
    private var _readError: (any Error)?
    func failReads(_ e: any Error) { lock.withLock { _readError = e } }
    var calls: Int { lock.withLock { _calls } }
    var paths: [String] { lock.withLock { Array(_files.keys) } }
    func put(_ data: Data, at path: String) { lock.withLock { _files[path] = data } }
    func data(at path: String) -> Data? { lock.withLock { _files[path] } }
    func listing(_ path: String, _ entries: [String]) { lock.withLock { _listings[path] = entries } }
    func read(_ path: String, context: RcloneContext) async throws -> Data? {
        try lock.withLock {
            _calls += 1
            if let _readError { throw _readError }
            return _files[path]
        }
    }
    func write(_ data: Data, to path: String, context: RcloneContext) async throws {
        lock.withLock { _calls += 1; _files[path] = data }
    }
    func list(_ path: String, context: RcloneContext) async throws -> [String]? {
        lock.withLock { _calls += 1; return _listings[path] }
    }
}

private final class Harness: @unchecked Sendable {
    let root: URL, iCloud: URL, backupRoot: URL, support: URL, logs: URL, work: URL, source: URL
    let rclone = FakeRclone(), feed = FakeFeed(), auditor = FakeAuditor(), notifier = RecordingNotifier(), files = FakeFiles()
    let downloader = FakeDownloader()
    private let lock = NSLock()
    private var _sessions: [UUID: FakeSession] = [:]
    var now = Date(timeIntervalSince1970: 2_000_000_000)
    var set: BackupSet
    var iCloudDest = Destination(name: "iCloud", kind: .iCloudFolder)
    var helperError: (any Error)?
    private var _freed = Set<String>()
    /// File names iCloud has evicted.
    var freed: Set<String> { get { lock.withLock { _freed } } set { lock.withLock { _freed = newValue } } }
    let store: ConfigStore, records: RunRecordStore, problems: ProblemCenter

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("coord-\(UUID().uuidString)").resolvingSymlinksInPath()
        iCloud = root.appendingPathComponent("icloud")
        backupRoot = iCloud.appendingPathComponent("Mac Backup")
        support = root.appendingPathComponent("support"); logs = root.appendingPathComponent("logs")
        work = root.appendingPathComponent("work"); source = root.appendingPathComponent("src")
        let fm = FileManager.default
        try fm.createDirectory(at: iCloud, withIntermediateDirectories: true)
        try fm.createDirectory(at: source.appendingPathComponent("flowapp"), withIntermediateDirectories: true)
        try Data("a".utf8).write(to: source.appendingPathComponent("flowapp/a.txt"))
        set = BackupSet(name: "x", source: source)
        set.destinationIDs = [iCloudDest.id]
        store = ConfigStore(root: support)
        records = RunRecordStore(root: support)
        problems = ProblemCenter(root: support, notifier: notifier)
        try save()
    }
    deinit { try? FileManager.default.removeItem(at: root) }

    var pair: PairID { PairID(set: set.id, destination: iCloudDest.id) }
    var mirror: String { backupRoot.appendingPathComponent("Sets/x").path }
    var state: SetState { get throws { try store.state(for: pair) } }
    func state(_ p: PairID) throws -> SetState { try store.state(for: p) }
    var active: [Problem] { get throws { try problems.active().map(\.problem) } }
    func latest() throws -> RunRecord? { try records.recent(limit: 1).first }
    func session(_ d: Destination) -> FakeSession? { lock.withLock { _sessions[d.id] } }
    func setSession(_ d: Destination, _ s: FakeSession) { lock.withLock { _sessions[d.id] = s } }

    func save(extra: [Destination] = []) throws {
        try store.saveSets([set])
        try store.saveDestinations([iCloudDest] + extra)
    }

    func coordinator(presets: [Preset] = [], rclone wrapped: (any RcloneRunning)? = nil) -> RunCoordinator {
        let clock: @Sendable () -> Date = { [self] in now }
        let runner: any RcloneRunning = wrapped ?? rclone
        return RunCoordinator(
            store: store, records: records, problems: problems, rclone: runner, feed: feed,
            verifier: Verifier(rclone: runner, auditor: auditor, isDataless: { [self] in freed.contains($0.lastPathComponent) }),
            guard: PathGuard(iCloudDrive: iCloud, backupRoot: backupRoot),
            detector: StackDetector(presets: presets), filters: FilterBuilder(presets: presets), clock: clock,
            sessions: { [self] d in
                lock.withLock {
                    if let s = _sessions[d.id] { return s }
                    let s = FakeSession(endpoint: d.encrypted ? "crypt\(d.id.uuidString.prefix(4)):" : "base:Mac Backup")
                    _sessions[d.id] = s
                    return s
                }
            },
            remote: files, paths: RunPaths(support: support, logs: logs, work: work),
            helperCheck: { [self] in if let helperError { throw helperError } }, downloader: downloader)
    }

    @discardableResult
    func run(_ c: RunCommand = RunCommand(), presets: [Preset] = []) async -> Bool {
        await coordinator(presets: presets).runAll(command: c)
    }

    /// A pair that has run before: claimed, counted, full pass recent, event 10 stored.
    func prime(_ p: PairID? = nil, kind: DestinationKind = .iCloudFolder) throws {
        if kind == .iCloudFolder { try claim() }
        var s = SetState()
        s.lastEventID = 5; s.lastFullPass = now; s.lastFinished = now.addingTimeInterval(-hour)
        s.lastDeepCheck = now; s.lastFileCount = 1000
        s.knownProjects = []
        try store.save(s, for: p ?? pair)
    }

    func claim() throws { try RootMarker(sets: [set.id: set.name]).save(backupRoot: backupRoot) }

    func change(_ rels: String..., rescan: Bool = false, id: UInt64 = 10) {
        feed.set(ChangeBatch(paths: rels.map { source.appendingPathComponent($0).path }, mustRescan: rescan, latestEventID: id))
    }

    func addCloud(_ kind: DestinationKind = .googleDrive, encrypted: Bool = true, kit: Bool = true) throws -> Destination {
        var d = Destination(name: "\(kind)", kind: kind, encrypted: encrypted)
        d.recoveryKitConfirmed = kit
        set.destinationIDs.append(d.id)
        return d
    }

    func cloudMarker(at path: String) throws {
        files.put(try JSONEncoder().encode(RootMarker(sets: [set.id: set.name])), at: path)
    }
}

@Suite struct RunCoordinatorTests {
    // MARK: Quiet paths

    @Test func noChangesDoesNoRcloneWork() async throws {
        let h = try Harness(); try h.prime()
        await h.run()
        #expect(h.rclone.allCalls == 0)
        #expect(try h.latest()?.status == .skipped)
        #expect(try h.state.lastEventID == 5)
    }

    @Test func lockHeldExitsWithoutTouchingState() async throws {
        let h = try Harness(); try h.prime(); h.change("flowapp/a.txt")
        let before = try h.state
        let other = RunLock(url: h.support.appendingPathComponent("locks/agent.lock"))
        #expect(other.tryAcquire())
        try Data("99999".utf8).write(to: h.support.appendingPathComponent("agent.pid"))
        await h.run()
        #expect(h.feed.calls == 0 && h.rclone.allCalls == 0)
        #expect(try h.state == before)
        #expect(try h.records.recent(limit: 5).isEmpty)
        #expect(try h.active.isEmpty)
        // The file belongs to the run that holds the lock.
        #expect(try String(contentsOf: h.support.appendingPathComponent("agent.pid"), encoding: .utf8) == "99999")
        other.release()
    }

    @Test func pairLockHeldSkipsThatPairQuietly() async throws {
        let h = try Harness(); try h.prime(); h.change("flowapp/a.txt")
        let name = "\(h.pair.set.uuidString)-\(h.pair.destination.uuidString).lock"
        let other = RunLock(url: h.support.appendingPathComponent("locks/\(name)"))
        #expect(other.tryAcquire())
        await h.run()
        #expect(h.rclone.allCalls == 0 && h.feed.calls == 0)
        #expect(try h.records.recent(limit: 5).isEmpty)
        other.release()
    }

    @Test func pidFileExistsDuringRunAndGoesAfter() async throws {
        let h = try Harness(); try h.prime()
        let pidFile = h.support.appendingPathComponent("agent.pid")
        final class Spy: ChangeFeeding, @unchecked Sendable {
            let file: URL; var seen: String?
            init(file: URL) { self.file = file }
            func changes(in: URL, since: UInt64?) async throws -> ChangeBatch {
                seen = try? String(contentsOf: file, encoding: .utf8)
                return ChangeBatch(paths: [], mustRescan: false, latestEventID: 5)
            }
        }
        let spy = Spy(file: pidFile)
        let c = RunCoordinator(store: h.store, records: h.records, problems: h.problems, rclone: h.rclone, feed: spy,
                               verifier: Verifier(rclone: h.rclone, auditor: h.auditor, isDataless: { _ in false }),
                               guard: PathGuard(iCloudDrive: h.iCloud, backupRoot: h.backupRoot),
                               detector: StackDetector(presets: []), filters: FilterBuilder(presets: []), clock: { h.now },
                               sessions: { _ in FakeSession(endpoint: "x:") }, remote: h.files,
                               paths: RunPaths(support: h.support, logs: h.logs, work: h.work))
        await c.runAll(command: RunCommand())
        #expect(spy.seen == String(ProcessInfo.processInfo.processIdentifier))
        #expect(!FileManager.default.fileExists(atPath: pidFile.path))
    }

    @Test func pidFileGoesWhenConfigCannotBeRead() async throws {
        let h = try Harness()
        try Data("not json".utf8).write(to: h.support.appendingPathComponent("sets.json"))
        await h.run()
        #expect(!FileManager.default.fileExists(atPath: h.support.appendingPathComponent("agent.pid").path))
    }

    @Test func leftoversAreWipedAtStart() async throws {
        let h = try Harness(); try h.prime()
        let stale = h.work.appendingPathComponent("mirror-run-stale")
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        await h.run()
        #expect(!FileManager.default.fileExists(atPath: stale.path))
    }

    @Test func oldRecordsAndLogsArePruned() async throws {
        let h = try Harness(); try h.prime()
        let old = h.now.addingTimeInterval(-31 * 24 * hour)
        try h.records.append(RunRecord(setID: h.set.id, setName: "x", destinationID: h.iCloudDest.id, destinationName: "i",
                                       start: old, end: old, trigger: .schedule, scope: "", status: .skipped))
        let folder = h.logs.appendingPathComponent("oldrun")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let log = folder.appendingPathComponent("sync.log")
        try Data().write(to: log)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: log.path)
        await h.run()
        #expect(try h.records.recent(limit: 10).allSatisfy { $0.start > old })
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func undeliveredNotificationsAreRetriedOncePerRun() async throws {
        let h = try Harness(); try h.prime()
        let silent = ProblemCenter(root: h.support, notifier: Mute())
        try await silent.raise(.uploadStalled, pair: PairID(set: UUID(), destination: UUID()), setName: "x", detail: "")
        await h.run()
        #expect(h.notifier.posted == [.uploadStalled])
    }

    @Test func pausedSetIsSkipped() async throws {
        let h = try Harness(); try h.prime(); h.change("flowapp/a.txt")
        h.set.isPaused = true; try h.save()
        await h.run()
        #expect(h.rclone.allCalls == 0 && h.feed.calls == 0)
        #expect(try h.latest()?.status == .skipped)
    }

    // MARK: Nothing may look like everything was deleted

    @Test func missingICloudStopsAndRaises() async throws {
        let h = try Harness(); try h.prime(); h.change("flowapp/a.txt")
        try FileManager.default.removeItem(at: h.iCloud)
        await h.run()
        #expect(h.rclone.allCalls == 0)
        #expect(try h.active == [.iCloudUnavailable])
        #expect(try h.state.lastEventID == 5)
        #expect(!FileManager.default.fileExists(atPath: h.iCloud.path))   // nothing recreated it
    }

    @Test func firstRunNeverCreatesAMissingICloudFolder() async throws {
        let h = try Harness()
        try FileManager.default.removeItem(at: h.iCloud)
        await h.run()
        #expect(!FileManager.default.fileExists(atPath: h.iCloud.path))
        #expect(try h.active == [.iCloudUnavailable])
    }

    @Test func missingSourceStops() async throws {
        let h = try Harness(); try h.prime(); h.change("flowapp/a.txt")
        try FileManager.default.removeItem(at: h.source)
        await h.run()
        #expect(h.rclone.allCalls == 0)
        #expect(try h.state.lastEventID == 5)
        #expect(try h.state.lastFileCount == 1000)
        #expect(try h.latest()?.status == .failed)
    }

    @Test func aFailedRunStillReportsWhatIsPending() async throws {
        let h = try Harness(); try h.prime(); h.change("flowapp/a.txt")
        h.rclone.script(copied: ["a.txt"])
        h.auditor.set(pending: ["a.txt"])
        await h.run()
        try FileManager.default.removeItem(at: h.source)
        await h.run()
        let records = try h.records.recent(limit: 5)
        #expect(records.filter { $0.status == .failed }.map(\.pendingUploads) == [1])
    }

    @Test func emptySourceHolds() async throws {
        let h = try Harness(); try h.prime(); h.change("flowapp/a.txt", rescan: true)
        try FileManager.default.removeItem(at: h.source.appendingPathComponent("flowapp"))
        try Data().write(to: h.source.appendingPathComponent(".DS_Store"))   // Finder leaves this behind
        await h.run()
        #expect(h.rclone.allCalls == 0)
        #expect(try h.active == [.deletionsHeld])
        #expect(try h.latest()?.status == .held)
        #expect(try h.state.heldDeletions == 1000)
        #expect(try h.state.lastFileCount == 1000)
        #expect(try h.state.lastEventID == 5)
    }

    @Test func emptySourceWithoutACountStillNeverDeletes() async throws {
        let h = try Harness(); try h.prime()
        var s = try h.state; s.lastFileCount = nil; try h.store.save(s, for: h.pair)
        try FileManager.default.removeItem(at: h.source.appendingPathComponent("flowapp"))
        h.change("flowapp", rescan: true)
        h.rclone.script(dryDeletions: ["a.txt"])
        await h.run()
        #expect(h.rclone.realSyncs.map(\.mode) == [.copyOnly])
        #expect(try h.state.heldDeletions == 1)
    }

    @Test func aReviewedEmptySourceCanBeAllowed() async throws {
        let h = try Harness(); try h.prime()
        var s = try h.state; s.heldDeletions = 1000; try h.store.save(s, for: h.pair)
        try FileManager.default.removeItem(at: h.source.appendingPathComponent("flowapp"))
        h.rclone.script(dryDeletions: (0..<900).map { "f\($0)" })
        await h.run(RunCommand(setID: h.set.id, approvedDeletions: 1000, force: true))
        guard case .mirror = h.rclone.realSyncs.first?.mode else { Issue.record("expected mirror"); return }
        #expect(try h.state.heldDeletions == 0)
    }

    @Test func unreadableSourceRaisesPermissionLost() async throws {
        let h = try Harness(); try h.prime()
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: h.source.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: h.source.path) }
        await h.run()
        #expect(h.rclone.allCalls == 0)
        #expect(try h.active == [.permissionLost])
    }

    // MARK: Marker

    @Test func firstRunClaimsAnUntouchedDestination() async throws {
        let h = try Harness()
        await h.run()
        let marker = try RootMarker.load(backupRoot: h.backupRoot)
        #expect(marker?.claims(h.set.id) == true)
        #expect(h.rclone.realSyncs.count == 1)
    }

    @Test func existingFolderWithoutMarkerIsRefused() async throws {
        let h = try Harness()
        try FileManager.default.createDirectory(at: h.backupRoot.appendingPathComponent("Sets/x"), withIntermediateDirectories: true)
        await h.run()
        #expect(h.rclone.allCalls == 0)
        #expect(try h.active == [.destinationMissing])
        #expect(try RootMarker.load(backupRoot: h.backupRoot) == nil)
    }

    @Test func claimedRootStillRefusesAnExistingMirrorFolder() async throws {
        let h = try Harness()
        try RootMarker(sets: [UUID(): "other"]).save(backupRoot: h.backupRoot)
        try FileManager.default.createDirectory(at: h.backupRoot.appendingPathComponent("Sets/X"), withIntermediateDirectories: true)
        await h.run()
        #expect(h.rclone.allCalls == 0)
        #expect(try h.active == [.destinationMissing])
    }

    @Test func aPairThatRanBeforeNeverReclaimsALostMarker() async throws {
        let h = try Harness(); try h.prime(); h.change("flowapp/a.txt")
        try FileManager.default.removeItem(at: h.backupRoot)
        await h.run()
        #expect(h.rclone.allCalls == 0)
        #expect(try h.active == [.destinationMissing])
        #expect(!FileManager.default.fileExists(atPath: h.backupRoot.path))
    }

    @Test func damagedMarkerIsNeverOverwritten() async throws {
        let h = try Harness()
        try FileManager.default.createDirectory(at: h.backupRoot, withIntermediateDirectories: true)
        let url = RootMarker.url(backupRoot: h.backupRoot)
        try Data("garbage".utf8).write(to: url)
        await h.run()
        #expect(h.rclone.allCalls == 0)
        #expect(try h.active == [.destinationMissing])
        #expect(try Data(contentsOf: url) == Data("garbage".utf8))
    }

    @Test func overlappingSetIsNotClaimed() async throws {
        let h = try Harness()
        var other = BackupSet(name: "y", source: h.source.appendingPathComponent("flowapp"))
        other.isPaused = true
        try h.store.saveSets([h.set, other])
        await h.run()
        #expect(h.rclone.allCalls == 0)
        #expect(try RootMarker.load(backupRoot: h.backupRoot) == nil)
    }

    @Test func cloudMarkerGoesThroughTheCryptEndpoint() async throws {
        let h = try Harness()
        let d = try h.addCloud(); h.set.destinationIDs = [d.id]; try h.save(extra: [d])
        let session = FakeSession(endpoint: "mirrorcrypt1:"); h.setSession(d, session)
        await h.run()
        #expect(h.files.paths == ["mirrorcrypt1:.mirror-root"])
        #expect(h.rclone.realSyncs.first?.destination == "mirrorcrypt1:Sets/x")
        #expect(h.rclone.realSyncs.first?.backupDir.hasPrefix("mirrorcrypt1:Archive/x/") == true)
    }

    @Test func unencryptedCloudPathsKeepTheirSeparator() async throws {
        let h = try Harness()
        let d = try h.addCloud(.oneDrive, encrypted: false, kit: false); h.set.destinationIDs = [d.id]; try h.save(extra: [d])
        h.setSession(d, FakeSession(endpoint: "base:Mac Backup"))
        await h.run()
        #expect(h.files.paths == ["base:Mac Backup/.mirror-root"])
        #expect(h.rclone.realSyncs.first?.destination == "base:Mac Backup/Sets/x")
    }

    @Test func cloudRootWithForeignContentIsRefused() async throws {
        let h = try Harness()
        let d = try h.addCloud(); h.set.destinationIDs = [d.id]; try h.save(extra: [d])
        h.setSession(d, FakeSession(endpoint: "c:"))
        h.files.listing("c:", ["Sets/"])
        await h.run()
        #expect(h.rclone.realSyncs.isEmpty)
        #expect(h.files.paths.isEmpty)
        #expect(try h.active == [.destinationMissing])
    }

    // MARK: Scope

    @Test func scopedSyncUsesScopedPaths() async throws {
        let h = try Harness(); try h.prime(); h.change("flowapp/a.txt")
        await h.run()
        let r = try #require(h.rclone.realSyncs.first)
        #expect(h.rclone.realSyncs.count == 1)
        #expect(r.source.path == h.source.appendingPathComponent("flowapp").path)
        #expect(r.destination == h.mirror + "/flowapp")
        let archive = h.backupRoot.appendingPathComponent("Archive/x").path + "/"
        #expect(r.backupDir.hasPrefix(archive) && r.backupDir.hasSuffix("/flowapp"))
        #expect(!r.backupDir.dropFirst(archive.count).dropLast("/flowapp".count).contains("/"))
        #expect(r.context == RcloneContext(configPath: "/dev/null", environment: [:]))
        #expect(h.rclone.checks.allSatisfy { $0.destination == h.mirror + "/flowapp" })
    }

    @Test func aProjectThatVanishedWidensToWholeSet() async throws {
        let h = try Harness(); try h.prime(); h.change("gone/a.txt")
        await h.run()
        #expect(h.rclone.realSyncs.map(\.destination) == [h.mirror])
    }

    @Test func aSymlinkedProjectWidensToWholeSet() async throws {
        let h = try Harness(); try h.prime(); h.change("link/a.txt")
        try FileManager.default.createSymbolicLink(at: h.source.appendingPathComponent("link"),
                                                   withDestinationURL: h.source.appendingPathComponent("flowapp"))
        await h.run()
        #expect(h.rclone.realSyncs.map(\.destination) == [h.mirror])
    }

    @Test func aMirrorFolderLinkingOutsideTheRootIsRefused() async throws {
        let h = try Harness(); try h.prime(); h.change("flowapp/a.txt")
        let sets = h.backupRoot.appendingPathComponent("Sets/x")
        try FileManager.default.createDirectory(at: sets, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: sets.appendingPathComponent("flowapp"), withDestinationURL: h.root)
        await h.run()
        #expect(h.rclone.allCalls == 0)
    }

    @Test func changesOnlyInExcludedFoldersDoNothing() async throws {
        let h = try Harness(); try h.prime()
        h.set.rules = [UserRule(pattern: "cache/**", action: .exclude)]; try h.save()
        h.change("flowapp/cache/deep/a.bin")
        await h.run()
        #expect(h.rclone.allCalls == 0)
        #expect(try h.latest()?.status == .skipped)
    }

    @Test func newProjectGetsPresetsApplied() async throws {
        let h = try Harness(); try h.prime()
        let flutter = Preset(id: "flutter", name: "Flutter", markers: ["pubspec.yaml"], alwaysExclude: [".dart_tool/"], ambiguousExclude: ["build/"])
        let app = h.source.appendingPathComponent("newapp")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try Data().write(to: app.appendingPathComponent("pubspec.yaml"))
        h.change("newapp")
        await h.run(presets: [flutter])
        #expect(try h.store.loadSets().first?.presets == ["flutter"])
        #expect(try h.state.knownProjects == ["newapp"])
        #expect(h.rclone.realSyncs.count == 1)
    }

    @Test func firstScanOnlyRecordsProjects() async throws {
        let h = try Harness()
        let flutter = Preset(id: "flutter", name: "Flutter", markers: ["pubspec.yaml"], alwaysExclude: [], ambiguousExclude: ["build/"])
        try Data().write(to: h.source.appendingPathComponent("flowapp/pubspec.yaml"))
        await h.run(presets: [flutter])
        #expect(try h.store.loadSets().first?.presets == [])   // the owner decided in the preview
        #expect(try h.state.knownProjects == ["flowapp"])
    }

    @Test func runFolderIsRemovedAfterwards() async throws {
        let h = try Harness(); try h.prime(); h.change("flowapp/a.txt")
        await h.run()
        let left = (try? FileManager.default.contentsOfDirectory(atPath: h.work.path)) ?? []
        #expect(left.isEmpty)
    }

    // MARK: Event ID

    @Test func eventIDAdvancesOnlyAfterVerifyPasses() async throws {
        let h = try Harness(); try h.prime(); h.change("flowapp/a.txt")
        await h.run()
        #expect(try h.state.lastEventID == 10)
        #expect(try h.latest()?.status == .success)

        let v = try Harness(); try v.prime(); v.change("flowapp/a.txt")
        v.rclone.script(differences: 1)
        await v.run()
        #expect(try v.state.lastEventID == 5)
    }

    @Test func failedSyncKeepsEventID() async throws {
        let h = try Harness(); try h.prime(); h.change("flowapp/a.txt")
        h.rclone.script(real: [.permanent])
        await h.run()
        #expect(try h.state.lastEventID == 5)
        #expect(try h.state.consecutiveFailures == 1)
        #expect(try h.latest()?.status == .failed)
        #expect(h.rclone.checks.isEmpty)
    }

    @Test func checkThatCouldNotCompleteKeepsEventIDAndIsNotAVerificationAlert() async throws {
        let h = try Harness(); try h.prime(); h.change("flowapp/a.txt")
        h.rclone.script(checkOutcome: .transient)
        await h.run()
        #expect(try h.state.lastEventID == 5)
        #expect(try h.active.isEmpty)
    }

    @Test func killedRunReplaysChanges() async throws {
        let h = try Harness(); try h.prime(); h.change("flowapp/a.txt")
        h.rclone.script(killRealSync: true)
        await h.run()
        #expect(try h.state.lastEventID == 5)
        h.rclone.script()
        await h.run()
        #expect(h.feed.since == [5, 5])
        #expect(try h.state.lastEventID == 10)
        #expect(h.rclone.realSyncs.count == 2)
    }

    @Test func killedWholeSetRunStaysWholeSetEvenIfHistoryLooksClean() async throws {
        let h = try Harness(); try h.prime(); h.change("flowapp/a.txt", rescan: true)
        h.rclone.script(killRealSync: true)
        await h.run()
        #expect(try h.state.wholeSetOwed)
        h.rclone.script()
        h.feed.set(ChangeBatch(paths: [], mustRescan: false, latestEventID: 11))
        await h.run()
        #expect(h.rclone.realSyncs.last?.destination == h.mirror)
        #expect(try h.state.wholeSetOwed == false)
    }

    @Test func cancelledRunStopsTheRemainingPairsAndCountsNoFailure() async throws {
        let h = try Harness(); try h.prime(); h.change("flowapp/a.txt")
        let d = try h.addCloud(encrypted: false, kit: false); try h.save(extra: [d])
        let p = PairID(set: h.set.id, destination: d.id); try h.prime(p, kind: .googleDrive)
        h.rclone.script(killRealSync: true)
        await h.run()
        #expect(h.rclone.realSyncs.count == 1)
        #expect(try h.state.consecutiveFailures == 0)
        #expect(try h.active.isEmpty)
    }

    // MARK: Deletions

    private func manyDeletions(_ n: Int = 500) -> [String] { (0..<n).map { "f\($0)" } }

    @Test func overThresholdRunsCopyOnly() async throws {
        let h = try Harness(); try h.prime(); h.change("flowapp/a.txt")
        h.rclone.script(dryDeletions: manyDeletions())
        await h.run()
        #expect(h.rclone.dryRuns.count == 1)
        #expect(h.rclone.realSyncs.map(\.mode) == [.copyOnly])
        #expect(!h.rclone.checks.isEmpty && h.rclone.checks.allSatisfy { $0.oneWay })
        #expect(try h.state.heldDeletions == 500)
        #expect(try h.active == [.deletionsHeld])
        #expect(h.notifier.posted == [.deletionsHeld])
        #expect(try h.latest()?.status == .held)
    }

    @Test func underThresholdMirrorsWithAGuard() async throws {
        let h = try Harness(); try h.prime(); h.change("flowapp/a.txt")
        h.rclone.script(dryDeletions: ["a", "b"])
        await h.run()
        #expect(h.rclone.realSyncs.map(\.mode) == [.mirror(maxDelete: 12)])
        #expect(h.rclone.checks.allSatisfy { !$0.oneWay })
    }

    @Test func dryRunHasNoDeleteLimit() async throws {
        let h = try Harness(); try h.prime(); h.change("flowapp/a.txt")
        await h.run()
        #expect(h.rclone.dryRuns.first?.mode == .mirror(maxDelete: -1))
    }

    @Test func heldSetKeepsFullCheckOneWayUntilAllowed() async throws {
        let h = try Harness(); try h.prime(); h.change("flowapp/a.txt")
        h.rclone.script(dryDeletions: manyDeletions())
        await h.run()
        h.change("flowapp/a.txt", id: 20)
        await h.run()
        #expect(h.rclone.realSyncs.map(\.mode) == [.copyOnly, .copyOnly])
        #expect(h.rclone.realSyncs.last?.destination == h.mirror)   // the whole set, so no deletion is forgotten
        #expect(h.rclone.checks.allSatisfy { $0.oneWay })
        #expect(try h.state.heldDeletions == 500)
        #expect(h.notifier.posted == [.deletionsHeld])
    }

    @Test func heldSetClearsItselfWhenTheFilesComeBack() async throws {
        let h = try Harness(); try h.prime(); h.change("flowapp/a.txt")
        h.rclone.script(dryDeletions: manyDeletions())
        await h.run()
        h.rclone.script()
        h.change("flowapp/a.txt", id: 20)
        await h.run()
        #expect(try h.state.heldDeletions == 0)
        #expect(try h.active.isEmpty)
    }

    @Test func allowDeletesRunsMirrorOnce() async throws {
        let h = try Harness(); try h.prime(); h.change("flowapp/a.txt")
        h.rclone.script(dryDeletions: manyDeletions())
        await h.run()
        await h.run(RunCommand(setID: h.set.id, approvedDeletions: 500, force: true))
        #expect(h.rclone.realSyncs.last?.mode == .mirror(maxDelete: 500))
        #expect(h.rclone.realSyncs.last?.destination == h.mirror)
        #expect(try h.state.heldDeletions == 0)
        #expect(try h.active.isEmpty)
        // The approval doesn't outlive the run.
        h.change("flowapp/a.txt", id: 30)
        await h.run()
        #expect(h.rclone.realSyncs.last?.mode == .copyOnly)
    }

    @Test func approvalCoversOnlyTheReviewedCount() async throws {
        let h = try Harness(); try h.prime(); h.change("flowapp/a.txt")
        h.rclone.script(dryDeletions: manyDeletions())
        await h.run()
        await h.run(RunCommand(setID: h.set.id, approvedDeletions: 499, force: true))
        #expect(h.rclone.realSyncs.last?.mode == .copyOnly)
        #expect(try h.state.heldDeletions == 500)
    }

    @Test func approvalDoesNothingForAPairThatIsNotHeld() async throws {
        let h = try Harness(); try h.prime()
        h.rclone.script(dryDeletions: manyDeletions())
        await h.run(RunCommand(setID: h.set.id, approvedDeletions: 500, force: true))
        #expect(h.rclone.realSyncs.last?.mode == .copyOnly)
    }

    @Test func maxDeleteStopHoldsAndKeepsEventID() async throws {
        let h = try Harness(); try h.prime(); h.change("flowapp/a.txt")
        h.rclone.script(real: [.safetyStop], dryDeletions: ["a"])
        await h.run()
        #expect(try h.state.lastEventID == 5)
        #expect(try h.state.heldDeletions > 0)
        #expect(try h.active == [.deletionsHeld])
        #expect(try h.latest()?.status == .held)
        #expect(h.rclone.checks.isEmpty)
    }

    // MARK: Failures

    @Test func thirdFailureNotifies() async throws {
        let h = try Harness(); try h.prime(); h.change("flowapp/a.txt")
        h.rclone.script(real: [.permanent, .permanent, .permanent])
        await h.run(); #expect(h.notifier.posted.isEmpty)
        await h.run(); #expect(h.notifier.posted.isEmpty)
        await h.run(); #expect(h.notifier.posted == [.repeatedFailures])
    }

    @Test func transientFailureDoesNotNotifyEarly() async throws {
        let h = try Harness(); try h.prime(); h.change("flowapp/a.txt")
        h.rclone.script(real: [.transient, .transient])
        await h.run(); await h.run()
        #expect(h.notifier.posted.isEmpty)
        #expect(try h.state.consecutiveFailures == 2)
    }

    @Test func successClearsFailures() async throws {
        let h = try Harness(); try h.prime(); h.change("flowapp/a.txt")
        h.rclone.script(real: [.permanent, .permanent, .permanent])
        await h.run(); await h.run(); await h.run()
        await h.run()
        #expect(try h.state.consecutiveFailures == 0)
        #expect(try h.active.isEmpty)
    }

    @Test func aReturnedSourceClearsFailuresWithoutChanges() async throws {
        let h = try Harness(); try h.prime()
        let aside = h.root.appendingPathComponent("aside")
        try FileManager.default.moveItem(at: h.source, to: aside)
        await h.run(); await h.run(); await h.run()
        #expect(try h.active == [.repeatedFailures])
        try FileManager.default.moveItem(at: aside, to: h.source)
        await h.run()
        #expect(try h.state.consecutiveFailures == 0)
        #expect(try h.active.isEmpty)
    }

    @Test func verificationFailureNotifiesAtOnce() async throws {
        let h = try Harness(); try h.prime(); h.change("flowapp/a.txt")
        h.rclone.script(differences: 2)
        await h.run()
        #expect(h.notifier.posted == [.verificationFailed])
        #expect(try h.latest()?.status == .verificationFailed)
    }

    @Test func aFileChangingDuringTheRunIsRetriedNotAlerted() async throws {
        let h = try Harness(); try h.prime()
        let path = h.source.appendingPathComponent("flowapp/a.txt").path
        h.feed.set(ChangeBatch(paths: [path], mustRescan: false, latestEventID: 10),
                   changedLater: ChangeBatch(paths: [path], mustRescan: false, latestEventID: 11))
        h.rclone.script(differences: 1, differing: ["a.txt"])
        await h.run()
        #expect(h.notifier.posted.isEmpty)
        #expect(try h.state.lastEventID == 5)
        #expect(try h.state.consecutiveFailures == 1)
    }

    @Test func oneDestinationFailingLeavesOthersRunning() async throws {
        let h = try Harness(); try h.prime(); h.change("flowapp/a.txt")
        let d = try h.addCloud(encrypted: false, kit: false); try h.save(extra: [d])
        let p = PairID(set: h.set.id, destination: d.id); try h.prime(p, kind: .googleDrive)
        h.setSession(d, FakeSession(endpoint: "g:Mac Backup"))
        try h.cloudMarker(at: "g:Mac Backup/.mirror-root")
        h.rclone.script(real: [.permanent])   // iCloud goes first
        await h.run()
        #expect(h.rclone.realSyncs.count == 2)
        #expect(try h.state.lastEventID == 5)
        #expect(try h.state(p).lastEventID == 10)
    }

    @Test func eachPairAdvancesOwnEventID() async throws {
        let h = try Harness(); try h.prime(); h.change("flowapp/a.txt")
        let d = try h.addCloud(encrypted: false, kit: false); try h.save(extra: [d])
        let p = PairID(set: h.set.id, destination: d.id); try h.prime(p, kind: .googleDrive)
        var s = try h.state(p); s.lastEventID = 7; try h.store.save(s, for: p)
        h.setSession(d, FakeSession(endpoint: "g:Mac Backup"))
        try h.cloudMarker(at: "g:Mac Backup/.mirror-root")
        await h.run()
        #expect(h.feed.since == [5, 7])
        #expect(try h.state.lastEventID == 10)
        #expect(try h.state(p).lastEventID == 10)
    }

    // MARK: Uploads

    @Test func pendingUploadsReadAsUploadingAndAdvanceTheEventID() async throws {
        let h = try Harness(); try h.prime(); h.change("flowapp/a.txt")
        h.rclone.script(copied: ["a.txt"])
        h.auditor.set(pending: ["a.txt"])
        await h.run()
        let s = try h.state
        #expect(s.lastEventID == 10)
        #expect(s.pendingUploads == 1 && !s.isBackedUp)
        #expect(try h.latest()?.status == .partial)
        #expect(try h.latest()?.pendingUploads == 1)
        #expect(try h.active.isEmpty)
    }

    @Test func finishedUploadsAreNoticedWithoutRclone() async throws {
        let h = try Harness(); try h.prime(); h.change("flowapp/a.txt")
        h.rclone.script(copied: ["a.txt"])
        h.auditor.set(pending: ["a.txt"])
        await h.run()
        let calls = h.rclone.allCalls
        h.auditor.set()
        await h.run()
        #expect(h.rclone.allCalls == calls)
        #expect(try h.state.pendingUploads == 0)
        #expect(try h.state.isBackedUp)
    }

    @Test func cleanRunIsBackedUp() async throws {
        let h = try Harness(); try h.prime(); h.change("flowapp/a.txt")
        await h.run()
        #expect(try h.state.isBackedUp)
    }

    @Test func renamedFilesAreVerifiedAndAudited() async throws {
        let h = try Harness(); try h.prime(); h.change("flowapp/a.txt")
        final class Renamer: RcloneRunning, @unchecked Sendable {
            let inner: FakeRclone
            init(_ i: FakeRclone) { inner = i }
            func sync(_ r: SyncRequest) async throws -> RcloneResult {
                var res = try await inner.sync(r)
                if !r.dryRun { res.summary.renamed = ["old.txt -> new.txt"] }
                return res
            }
            func check(_ r: CheckRequest) async throws -> RcloneResult { try await inner.check(r) }
        }
        let renamer = Renamer(h.rclone)
        let c = RunCoordinator(store: h.store, records: h.records, problems: h.problems, rclone: renamer, feed: h.feed,
                               verifier: Verifier(rclone: renamer, auditor: h.auditor, isDataless: { _ in false }),
                               guard: PathGuard(iCloudDrive: h.iCloud, backupRoot: h.backupRoot),
                               detector: StackDetector(presets: []), filters: FilterBuilder(presets: []), clock: { h.now },
                               sessions: { _ in FakeSession(endpoint: "x:") }, remote: h.files,
                               paths: RunPaths(support: h.support, logs: h.logs, work: h.work))
        await c.runAll(command: RunCommand())
        #expect(h.auditor.calls.flatMap { $0 }.contains { $0.lastPathComponent == "new.txt" })
        #expect(try h.latest()?.renamed == 1)
    }

    @Test func refusedAfter24HoursBecomesProblem() async throws {
        let h = try Harness(); try h.prime(); h.change("flowapp/a.tmp")
        h.rclone.script(copied: ["a.tmp"])
        h.auditor.set(refused: ["a.tmp"])
        await h.run()
        #expect(try h.state.refusedSince == ["flowapp/a.tmp": h.now])
        #expect(try h.active.isEmpty)
        #expect(try h.state.isBackedUp == false)

        h.now = h.now.addingTimeInterval(23 * hour)
        h.rclone.script()
        await h.run()
        #expect(try h.active.isEmpty)

        h.now = h.now.addingTimeInterval(2 * hour)
        await h.run()   // the daily pass is due by now too
        #expect(try h.active == [.fileRefused])
        #expect(try h.state.reviewItems.map(\.kind) == [.refusedByICloud])
        #expect(try h.state.reviewItems.map(\.path) == ["flowapp/a.tmp"])

        h.auditor.set()
        var s = try h.state; s.refusedSince = ["flowapp/gone.tmp": s.refusedSince.values.first!]; try h.store.save(s, for: h.pair)
        await h.run()   // the file has left the mirror
        #expect(try h.state.refusedSince.isEmpty)
        #expect(try h.state.reviewItems.isEmpty)
        #expect(try h.active.isEmpty)
    }

    @Test func acceptedRefusedFileStopsBlockingBackedUp() async throws {
        let h = try Harness(); try h.prime(); h.change("flowapp/a.tmp")
        h.rclone.script(copied: ["a.tmp"])
        h.auditor.set(refused: ["a.tmp"])
        await h.run()
        h.set.rules = [UserRule(pattern: "/flowapp/a.tmp", action: .exclude)]; try h.save()
        h.rclone.script()
        await h.run()
        #expect(try h.state.refusedSince.isEmpty)
        #expect(try h.state.isBackedUp)
    }

    @Test func uploadPendingOver24HoursRaisesStall() async throws {
        let h = try Harness(); try h.prime(); h.change("flowapp/a.txt")
        h.rclone.script(copied: ["a.txt"])
        h.auditor.set(pending: ["a.txt"])
        await h.run()
        h.rclone.script()
        h.now = h.now.addingTimeInterval(23 * hour)
        await h.run()
        #expect(try h.active.isEmpty)
        h.now = h.now.addingTimeInterval(2 * hour)
        await h.run()
        #expect(try h.active == [.uploadStalled])
        h.auditor.set()
        await h.run()
        #expect(try h.active.isEmpty)
    }

    @Test func aSlowUploadThatKeepsMovingIsNotStalled() async throws {
        let h = try Harness(); try h.prime(); h.change("flowapp/a.txt")
        h.rclone.script(copied: ["a.txt", "b.txt"])
        h.auditor.set(pending: ["a.txt", "b.txt"])
        await h.run()
        h.rclone.script()
        h.now = h.now.addingTimeInterval(20 * hour)
        h.auditor.set(pending: ["b.txt"])
        await h.run()
        h.now = h.now.addingTimeInterval(20 * hour)
        await h.run()
        #expect(try h.active.isEmpty)
    }

    @Test func dailyPassAuditsTheWholeMirror() async throws {
        let h = try Harness(); try h.prime()
        var s = try h.state; s.lastFullPass = h.now.addingTimeInterval(-25 * hour); try h.store.save(s, for: h.pair)
        let m = h.backupRoot.appendingPathComponent("Sets/x/p")
        try FileManager.default.createDirectory(at: m, withIntermediateDirectories: true)
        try Data().write(to: m.appendingPathComponent("old.txt"))
        h.rclone.script(matching: 777)
        await h.run()
        #expect(h.auditor.calls.flatMap { $0 }.contains { $0.lastPathComponent == "old.txt" })
        #expect(try h.state.lastFullPass == h.now)
        #expect(try h.state.lastFileCount == 777)
        #expect(try h.latest()?.trigger == .daily)
    }

    @Test func scopedRunLeavesTheFileCountAlone() async throws {
        let h = try Harness(); try h.prime(); h.change("flowapp/a.txt")
        h.rclone.script(matching: 3)
        await h.run()
        #expect(try h.state.lastFileCount == 1000)
    }

    @Test func deepCheckRunsWithTheFullPassWhenDue() async throws {
        let h = try Harness(); try h.prime()
        var s = try h.state
        s.lastFullPass = h.now.addingTimeInterval(-25 * hour)
        s.lastDeepCheck = h.now.addingTimeInterval(-31 * 24 * hour)
        try h.store.save(s, for: h.pair)
        try FileManager.default.createDirectory(at: h.backupRoot.appendingPathComponent("Sets/x"), withIntermediateDirectories: true)
        await h.run()
        #expect(h.rclone.checks.contains { $0.logFile.lastPathComponent == "deep-size.log" })
        #expect(try h.state.lastDeepCheck == h.now)
    }

    // MARK: Cloud

    @Test func partialRunKeepsEventIDAndResumes() async throws {
        let h = try Harness(); try h.prime(); h.change("flowapp/a.txt")
        h.rclone.script(real: [.partial])
        await h.run()
        let s = try h.state
        #expect(s.lastEventID == 5 && s.syncIncomplete && !s.isBackedUp)
        #expect(s.consecutiveFailures == 0)
        #expect(h.notifier.posted.isEmpty)
        #expect(try h.latest()?.status == .partial)
        #expect(h.rclone.checks.isEmpty)
        await h.run()
        #expect(h.feed.since == [5, 5])
        #expect(h.rclone.realSyncs.count == 2)
        #expect(try h.state.lastEventID == 10)
        #expect(try h.state.syncIncomplete == false)
    }

    @Test func authExpiredPausesOnlyThatDestination() async throws {
        let h = try Harness()
        let google = try h.addCloud(encrypted: false, kit: false), drive = try h.addCloud(.oneDrive, encrypted: false, kit: false)
        var second = BackupSet(name: "y", source: h.root.appendingPathComponent("src2"))
        try FileManager.default.createDirectory(at: second.source.appendingPathComponent("p"), withIntermediateDirectories: true)
        try Data().write(to: second.source.appendingPathComponent("p/f"))
        second.destinationIDs = [google.id]
        h.set.destinationIDs = [google.id, drive.id]
        try h.store.saveSets([h.set, second]); try h.store.saveDestinations([google, drive])
        h.setSession(google, FakeSession(endpoint: "g:Mac Backup")); h.setSession(drive, FakeSession(endpoint: "o:Mac Backup"))
        let marker = try JSONEncoder().encode(RootMarker(sets: [h.set.id: "x", second.id: "y"]))
        h.files.put(marker, at: "g:Mac Backup/.mirror-root"); h.files.put(marker, at: "o:Mac Backup/.mirror-root")
        let pg = PairID(set: h.set.id, destination: google.id), po = PairID(set: h.set.id, destination: drive.id)
        let ps = PairID(set: second.id, destination: google.id)
        for (p, age) in [(pg, 3.0), (ps, 2.0), (po, 1.0)] {
            try h.prime(p, kind: .googleDrive)
            var s = try h.state(p); s.lastFinished = h.now.addingTimeInterval(-age * hour); try h.store.save(s, for: p)
        }
        h.change("flowapp/a.txt")
        h.rclone.script(dryOutcome: .authExpired)
        await h.run()
        // Google's second pair never reached rclone. OneDrive still tried.
        #expect(h.rclone.dryRuns.map(\.destination).filter { $0.hasPrefix("g:") }.count == 1)
        #expect(h.rclone.dryRuns.contains { $0.destination.hasPrefix("o:") })
        #expect(try h.problems.active().filter { $0.problem == .signInExpired }.map(\.pair).contains(pg))
        #expect(try h.state(pg).lastEventID == 5)
        #expect(try h.state(pg).consecutiveFailures == 0)
    }

    @Test func missingSignInAsksForReconnect() async throws {
        let h = try Harness()
        let d = try h.addCloud(encrypted: false, kit: false); h.set.destinationIDs = [d.id]; try h.save(extra: [d])
        h.setSession(d, FakeSession(endpoint: "x", openError: RcloneSessionError.notSignedIn))
        await h.run()
        #expect(h.rclone.allCalls == 0)
        #expect(try h.active == [.signInExpired])
    }

    @Test func encryptedDestinationWaitsForRecoveryKit() async throws {
        let h = try Harness()
        let d = try h.addCloud(kit: false); h.set.destinationIDs = [d.id]; try h.save(extra: [d])
        await h.run()
        #expect(h.rclone.allCalls == 0)
        #expect(h.session(d) == nil)
        #expect(try h.latest()?.status == .skipped)
    }

    @Test func cloudContextIsCleanedUpOnFailure() async throws {
        let h = try Harness()
        let d = try h.addCloud(); h.set.destinationIDs = [d.id]; try h.save(extra: [d])
        let session = FakeSession(endpoint: "c:"); h.setSession(d, session)
        try h.cloudMarker(at: "c:.mirror-root")
        let p = PairID(set: h.set.id, destination: d.id); try h.prime(p, kind: .googleDrive)
        h.change("flowapp/a.txt")
        h.rclone.script(real: [.permanent])
        await h.run()
        #expect(session.opens == 1 && session.closes == 1)
        h.rclone.script()
        h.change("flowapp/a.txt", id: 11)
        await h.run()
        #expect(session.opens == 2 && session.closes == 2)
        #expect(h.rclone.syncs.last?.context.configPath == "/private/run.conf")
    }

    @Test func noChangesMakesNoNetworkCall() async throws {
        let h = try Harness()
        let d = try h.addCloud(); h.set.destinationIDs = [d.id]; try h.save(extra: [d])
        let p = PairID(set: h.set.id, destination: d.id); try h.prime(p, kind: .googleDrive)
        await h.run()
        #expect(h.session(d) == nil)
        #expect(h.files.calls == 0 && h.rclone.allCalls == 0)
        #expect(try h.records.recent(limit: 1).first?.status == .skipped)
    }

    @Test func lostCloudMarkerStopsAPairThatRanBefore() async throws {
        let h = try Harness()
        let d = try h.addCloud(); h.set.destinationIDs = [d.id]; try h.save(extra: [d])
        h.setSession(d, FakeSession(endpoint: "c:"))
        let p = PairID(set: h.set.id, destination: d.id); try h.prime(p, kind: .googleDrive)
        h.change("flowapp/a.txt")
        await h.run()
        #expect(h.rclone.allCalls == 0)
        #expect(h.files.paths.isEmpty)
        #expect(try h.active == [.destinationMissing])
    }

    // MARK: Commands

    @Test func runNowCoversOnlyThatSetAndTheWholeOfIt() async throws {
        let h = try Harness(); try h.prime()
        var other = BackupSet(name: "y", source: h.root.appendingPathComponent("src2"))
        try FileManager.default.createDirectory(at: other.source, withIntermediateDirectories: true)
        other.destinationIDs = [h.iCloudDest.id]
        try h.store.saveSets([h.set, other])
        await h.run(RunCommand(setID: h.set.id, force: true))
        #expect(h.rclone.realSyncs.map(\.destination) == [h.mirror])
        #expect(try h.latest()?.trigger == .manual)
    }

    @Test func fullSpeedReachesRcloneOnlyWhenAsked() async throws {
        let h = try Harness(); try h.prime()
        await h.run(RunCommand(force: true, fullSpeed: true))
        #expect(!h.rclone.syncs.isEmpty && h.rclone.syncs.allSatisfy { $0.fullSpeed })
        await h.run(RunCommand(force: true))
        #expect(h.rclone.syncs.last?.fullSpeed == false)
    }

    @Test func recordCarriesCountsAndNoSecretContext() async throws {
        let h = try Harness(); try h.prime(); h.change("flowapp/a.txt")
        h.rclone.script(copied: ["a.txt", "b.txt"], matching: 2)
        await h.run()
        let r = try #require(try h.latest())
        #expect(r.copied == 2 && r.filesChecked == 2 && r.scope == "flowapp" && r.trigger == .schedule)
        #expect(r.verification.contains("passed"))
    }
}

/// Fix round 1. What a run did must survive it, and only proof clears it.
@Suite struct OwedWorkTests {
    @Test func hashMismatchIsRetriedAndOnlyACleanCheckClearsIt() async throws {
        let h = try Harness(); try h.prime(); h.change("flowapp/a.txt")
        h.rclone.script(copied: ["a.txt"], hashDifferences: 1, differing: ["a.txt"])
        await h.run()
        #expect(try h.active == [.verificationFailed])
        #expect(try h.state.verifyOwed == ["flowapp/a.txt"])
        #expect(try h.state.isBackedUp == false)

        // Same size and time, so rclone copies nothing. The mismatch must not be forgotten.
        h.rclone.script(hashDifferences: 1, differing: ["a.txt"])
        await h.run()
        #expect(h.rclone.hashed.last == ["a.txt"])
        #expect(try h.active == [.verificationFailed])
        #expect(try h.state.lastEventID == 5)

        h.rclone.script()
        await h.run()
        #expect(h.rclone.hashed.last == ["a.txt"])
        #expect(try h.active.isEmpty)
        #expect(try h.state.verifyOwed.isEmpty)
        #expect(try h.state.lastEventID == 10)
        #expect(try h.state.isBackedUp)
    }

    @Test func aPendingUploadAfterAFailureIsStillAudited() async throws {
        let h = try Harness(); try h.prime(); h.change("flowapp/a.txt")
        h.rclone.script(real: [.permanent], copied: ["a.txt"])
        await h.run()
        #expect(try h.state.verifyOwed == ["flowapp/a.txt"])
        h.rclone.script()
        h.auditor.set(pending: ["a.txt"])
        await h.run()
        #expect(try h.state.uploadingPaths == ["flowapp/a.txt"])
        #expect(try h.state.verifyOwed.isEmpty)
        #expect(try h.state.isBackedUp == false)
        // Both records share the fixed clock, so they're told apart by status.
        #expect(try h.records.recent(limit: 5).map(\.status).sorted { $0.rawValue < $1.rawValue } == [.failed, .partial])
    }

    @Test func aKillBetweenSyncAndAuditLosesNothing() async throws {
        let h = try Harness(); try h.prime(); h.change("flowapp/a.txt")
        h.rclone.script(copied: ["a.txt"], killCheck: true)
        await h.run()
        #expect(try h.state.verifyOwed == ["flowapp/a.txt"])
        h.rclone.script()
        h.auditor.set(pending: ["a.txt"])
        await h.run()
        #expect(h.rclone.hashed.last == ["a.txt"])
        #expect(try h.state.uploadingPaths == ["flowapp/a.txt"])
    }

    @Test func plannedCopiesAreOwedBeforeTheRealSyncStarts() async throws {
        let h = try Harness(); try h.prime(); h.change("flowapp/a.txt")
        h.rclone.script(killRealSync: true, planned: ["a.txt", "b.txt"])
        final class Seen: @unchecked Sendable { var owed: [String] = [] }
        let seen = Seen()
        h.rclone.onRealSync = { seen.owed = (try? h.state.verifyOwed) ?? [] }
        await h.run()
        #expect(seen.owed == ["flowapp/a.txt", "flowapp/b.txt"])
        #expect(try h.state.verifyOwed == ["flowapp/a.txt", "flowapp/b.txt"])
    }

    @Test func aFailureInOneProjectKeepsTheOthersProofUnderway() async throws {
        let h = try Harness(); try h.prime()
        try FileManager.default.createDirectory(at: h.source.appendingPathComponent("zeta"), withIntermediateDirectories: true)
        try Data().write(to: h.source.appendingPathComponent("zeta/a.txt"))
        h.change("flowapp/a.txt", "zeta/a.txt")
        h.rclone.script(real: [.success, .permanent], copied: ["a.txt"])
        await h.run()
        #expect(try h.state.verifyOwed == ["flowapp/a.txt", "zeta/a.txt"])
        h.rclone.script()
        await h.run()
        #expect(h.rclone.hashed.suffix(2).map { $0 } == [["a.txt"], ["a.txt"]])
        #expect(try h.state.verifyOwed.isEmpty)
        #expect(try h.state.lastEventID == 10)
    }

    @Test func aCleanProjectIsProvenEvenWhenAnotherMismatches() async throws {
        let h = try Harness(); try h.prime()
        try FileManager.default.createDirectory(at: h.source.appendingPathComponent("zeta"), withIntermediateDirectories: true)
        h.change("flowapp/a.txt", "zeta/b.txt")
        // Only the slice whose list names the file differs, by way of a fake keyed on the list.
        final class Picky: RcloneRunning, @unchecked Sendable {
            let inner: FakeRclone
            init(_ i: FakeRclone) { inner = i }
            func sync(_ r: SyncRequest) async throws -> RcloneResult {
                var res = try await inner.sync(r)
                if !r.dryRun { res.summary.copied = [r.destination.hasSuffix("zeta") ? "b.txt" : "a.txt"] }
                return res
            }
            func check(_ r: CheckRequest) async throws -> RcloneResult {
                var res = try await inner.check(r)
                if r.filesFrom != nil, r.destination.hasSuffix("zeta") { res.summary.differences = 1; res.summary.flagged = ["b.txt"] }
                return res
            }
        }
        let picky = Picky(h.rclone)
        await h.coordinator(rclone: picky).runAll(command: RunCommand())
        #expect(try h.state.verifyOwed == ["zeta/b.txt"])
        #expect(try h.active == [.verificationFailed])
    }

    @Test func cloudPartialSegmentsAreProvenWhenTheRunFinishes() async throws {
        let h = try Harness()
        let d = try h.addCloud(); h.set.destinationIDs = [d.id]; try h.save(extra: [d])
        h.setSession(d, FakeSession(endpoint: "c:"))
        try h.cloudMarker(at: "c:.mirror-root")
        let p = PairID(set: h.set.id, destination: d.id); try h.prime(p, kind: .googleDrive)
        for name in ["one.txt", "two.txt", "three.txt"] { try Data().write(to: h.source.appendingPathComponent("flowapp/\(name)")) }
        h.change("flowapp/a.txt")
        h.rclone.script(real: [.partial], copied: ["one.txt"])
        await h.run()
        h.rclone.script(real: [.partial], copied: ["two.txt"])
        await h.run()
        #expect(try h.state(p).verifyOwed == ["flowapp/one.txt", "flowapp/two.txt"])
        h.rclone.script(copied: ["three.txt"])
        await h.run()
        #expect(Set(h.rclone.hashed.last ?? []) == ["one.txt", "two.txt", "three.txt"])
        #expect(try h.state(p).verifyOwed.isEmpty)
        #expect(try h.state(p).lastEventID == 10)
    }

    @Test func owedWorkRunsEvenWithNoChanges() async throws {
        let h = try Harness(); try h.prime()
        var s = try h.state; s.verifyOwed = ["flowapp/a.txt"]; try h.store.save(s, for: h.pair)
        await h.run()
        #expect(h.rclone.hashed.last == ["a.txt"])
        #expect(try h.state.verifyOwed.isEmpty)
    }

    @Test func owedWorkOutsideTheChangedProjectStillRuns() async throws {
        let h = try Harness(); try h.prime()
        try FileManager.default.createDirectory(at: h.source.appendingPathComponent("zeta"), withIntermediateDirectories: true)
        var s = try h.state; s.verifyOwed = ["zeta/old.txt"]; try h.store.save(s, for: h.pair)
        h.change("flowapp/a.txt")
        await h.run()
        #expect(Set(h.rclone.realSyncs.map(\.destination)) == [h.mirror + "/flowapp", h.mirror + "/zeta"])
    }

    @Test func anOwedFileThatLeftTheSourceIsNoLongerOwed() async throws {
        let h = try Harness(); try h.prime()
        var s = try h.state; s.verifyOwed = ["flowapp/deleted.txt"]; try h.store.save(s, for: h.pair)
        await h.run()
        #expect(try h.state.verifyOwed.isEmpty)
    }

    @Test func tooLongAListForcesAWholeSetHashCheckAfterAnUnfinishedRun() async throws {
        let h = try Harness(); try h.prime(); h.change("flowapp/a.txt")
        let many = (0...RunCoordinator.maxOwed).map { "f\($0)" }
        h.rclone.script(real: [.permanent], planned: many)
        await h.run()
        #expect(try h.state.hashWholeSet)
        #expect(try h.state.verifyOwed.isEmpty)
        #expect(try h.state.isBackedUp == false)

        h.rclone.script()
        h.feed.set(ChangeBatch(paths: [], mustRescan: false, latestEventID: 11))
        try FileManager.default.createDirectory(at: h.backupRoot.appendingPathComponent("Sets/x"), withIntermediateDirectories: true)
        await h.run()
        #expect(h.rclone.realSyncs.last?.destination == h.mirror)
        #expect(h.rclone.checks.contains { $0.logFile.lastPathComponent == "deep-size.log" })
        #expect(try h.state.hashWholeSet == false)
    }

    @Test func aScopedRunHashesALongListButLeavesTheFlag() async throws {
        let h = try Harness(); try h.prime(); h.change("flowapp/a.txt")
        let many = (0...RunCoordinator.maxOwed).map { "f\($0)" }
        h.rclone.script(copied: many, planned: many)
        await h.run()
        #expect(try h.state.hashWholeSet)   // scoped, so only the next run's whole-set check may end it
        #expect(try h.state.verifyOwed.isEmpty)
        #expect(h.rclone.hashed.last?.count == many.count)
    }

    @Test func aMissingAuditedFileStaysOwed() async throws {
        let h = try Harness(); try h.prime(); h.change("flowapp/gone-from-mirror.txt")
        try Data().write(to: h.source.appendingPathComponent("flowapp/gone-from-mirror.txt"))
        h.rclone.script(copied: ["gone-from-mirror.txt"])
        await h.run()
        #expect(try h.state.verifyOwed == ["flowapp/gone-from-mirror.txt"])
        #expect(try h.state.isBackedUp == false)
    }
}

@Suite struct HoldStaysHeldTests {
    private func held(_ h: Harness) async throws {
        try h.prime(); h.change("flowapp/a.txt")
        h.rclone.script(dryDeletions: (0..<500).map { "f\($0)" })
        await h.run()
        #expect(try h.state.heldDeletions == 500)
    }

    @Test func aHoldSurvivesTheCountFallingBelowTheThreshold() async throws {
        let h = try Harness(); try await held(h)
        h.rclone.script(dryDeletions: ["a", "b"])
        h.change("flowapp/a.txt", id: 20)
        await h.run()
        #expect(h.rclone.realSyncs.last?.mode == .copyOnly)
        #expect(try h.state.heldDeletions == 2)
        #expect(try h.active == [.deletionsHeld])
    }

    @Test func approvalBelowTheThresholdStillCoversOnlyTheReviewedCount() async throws {
        let h = try Harness(); try await held(h)
        h.rclone.script(dryDeletions: ["a", "b", "c"])
        await h.run(RunCommand(setID: h.set.id, approvedDeletions: 2, force: true))
        #expect(h.rclone.realSyncs.last?.mode == .copyOnly)
    }

    @Test func onlyZeroClearsAHoldWithoutApproval() async throws {
        let h = try Harness(); try await held(h)
        h.rclone.script()
        h.change("flowapp/a.txt", id: 20)
        await h.run()
        guard case .mirror = h.rclone.realSyncs.last?.mode else { Issue.record("expected mirror"); return }
        #expect(try h.state.heldDeletions == 0)
    }

    @Test func gitChurnAloneDoesNotKeepAHoldAlive() async throws {
        let h = try Harness(); try await held(h)
        h.rclone.script(dryDeletions: ["p/.git/objects/ab/cd"])
        h.change("flowapp/a.txt", id: 20)
        await h.run()
        #expect(try h.state.heldDeletions == 0)
    }
}

@Suite struct StopsAreVisibleTests {
    private func backedUp() throws -> Harness {
        let h = try Harness(); try h.prime()
        #expect(try h.state.isBackedUp)
        return h
    }

    @Test func iCloudUnavailableIsNotBackedUp() async throws {
        let h = try backedUp()
        try FileManager.default.removeItem(at: h.iCloud)
        await h.run()
        #expect(try h.state.isBackedUp == false)
    }

    @Test func unreadableSourceIsNotBackedUp() async throws {
        let h = try backedUp()
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: h.source.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: h.source.path) }
        await h.run()
        #expect(try h.state.isBackedUp == false)
        #expect(try h.state.stoppedBy == .permissionLost)
    }

    @Test func unclaimedDestinationIsNotBackedUp() async throws {
        let h = try backedUp()
        try FileManager.default.removeItem(at: h.backupRoot)
        await h.run()
        #expect(try h.state.isBackedUp == false)
    }

    @Test func expiredSignInIsNotBackedUp() async throws {
        let h = try Harness()
        let d = try h.addCloud(); h.set.destinationIDs = [d.id]; try h.save(extra: [d])
        h.setSession(d, FakeSession(endpoint: "c:"))
        let p = PairID(set: h.set.id, destination: d.id); try h.prime(p, kind: .googleDrive)
        h.change("flowapp/a.txt")
        h.files.failReads(RemoteFileError.authExpired)
        await h.run()
        #expect(try h.state(p).isBackedUp == false)
    }

    @Test func aPairSkippedBehindAnExpiredDestinationIsNotBackedUp() async throws {
        let h = try Harness()
        let d = try h.addCloud()
        var second = BackupSet(name: "y", source: h.root.appendingPathComponent("src2"))
        try FileManager.default.createDirectory(at: second.source.appendingPathComponent("p"), withIntermediateDirectories: true)
        second.destinationIDs = [d.id]; h.set.destinationIDs = [d.id]
        try h.store.saveSets([h.set, second]); try h.store.saveDestinations([d])
        h.setSession(d, FakeSession(endpoint: "c:"))
        let a = PairID(set: h.set.id, destination: d.id), b = PairID(set: second.id, destination: d.id)
        try h.prime(a, kind: .googleDrive); try h.prime(b, kind: .googleDrive)
        h.change("flowapp/a.txt")
        h.files.failReads(RemoteFileError.authExpired)
        await h.run()
        #expect(try h.state(a).isBackedUp == false)
        #expect(try h.state(b).isBackedUp == false)
    }

    @Test func recoveryIsProvenBeforeBackedUpReturns() async throws {
        let h = try backedUp()
        let aside = h.root.appendingPathComponent("aside")
        try FileManager.default.moveItem(at: h.backupRoot, to: aside)
        await h.run()
        #expect(try h.state.isBackedUp == false)
        try FileManager.default.moveItem(at: aside, to: h.backupRoot)
        await h.run()
        #expect(try h.state.isBackedUp)
        #expect(try h.active.isEmpty)
    }

    @Test func cloudStopIsReprovenAtTheNextWakeUpEvenWithNoChanges() async throws {
        let h = try Harness()
        let d = try h.addCloud(); h.set.destinationIDs = [d.id]; try h.save(extra: [d])
        h.setSession(d, FakeSession(endpoint: "c:"))
        try h.cloudMarker(at: "c:.mirror-root")
        let p = PairID(set: h.set.id, destination: d.id); try h.prime(p, kind: .googleDrive)
        var s = try h.state(p); s.stoppedBy = .signInExpired; try h.store.save(s, for: p)
        await h.run()
        #expect(h.rclone.allCalls == 0)
        #expect(try h.state(p).stoppedBy == nil)
        #expect(try h.state(p).isBackedUp)
    }

    @Test func expiredSignInAtTheMarkerRaisesAndPausesTheDestination() async throws {
        let h = try Harness()
        let d = try h.addCloud(); h.set.destinationIDs = [d.id]; try h.save(extra: [d])
        h.setSession(d, FakeSession(endpoint: "c:"))
        let p = PairID(set: h.set.id, destination: d.id); try h.prime(p, kind: .googleDrive)
        h.change("flowapp/a.txt")
        h.files.failReads(RemoteFileError.authExpired)
        await h.run()
        #expect(try h.active == [.signInExpired])
        #expect(try h.state(p).consecutiveFailures == 0)
        #expect(h.rclone.allCalls == 0)
    }

    @Test func aMarkerThatLeftICloudStopsThePair() async throws {
        let h = try backedUp(); h.change("flowapp/a.txt")
        h.auditor.set(refused: [RootMarker.fileName])
        await h.run()
        #expect(h.rclone.allCalls == 0)
        #expect(try h.active == [.iCloudUnavailable])
        #expect(h.notifier.details.first?.contains("iCloud Drive may be signed out") == true)
        #expect(try h.latest()?.errors == ["iCloud Drive may be signed out"])
        #expect(try h.state.isBackedUp == false)
        #expect(try h.state.lastEventID == 5)
    }

    @Test func theMarkerCheckIsOneReadAWakeUp() async throws {
        let h = try backedUp()
        await h.run()
        #expect(h.auditor.calls.map { $0.map(\.lastPathComponent) } == [[RootMarker.fileName]])
    }

    @Test func aSignedOutMacNeverClaimsANewPair() async throws {
        let h = try Harness()
        h.auditor.set(refused: ["icloud"])   // the backup root's parent
        await h.run()
        #expect(h.rclone.allCalls == 0)
        #expect(!FileManager.default.fileExists(atPath: h.backupRoot.path))
        #expect(try h.active == [.iCloudUnavailable])
    }

    @Test func iCloudUnavailableNotifiesOnceAcrossWakeUps() async throws {
        let h = try backedUp()
        h.auditor.set(refused: [RootMarker.fileName])
        await h.run(); await h.run(); await h.run()
        #expect(h.notifier.posted == [.iCloudUnavailable])
    }

    @Test func iCloudUnavailableClearsOnlyOnceTheClaimPasses() async throws {
        let h = try backedUp()
        h.auditor.set(refused: [RootMarker.fileName])
        await h.run()
        h.auditor.set()
        await h.run()
        #expect(try h.active.isEmpty)
        #expect(try h.state.isBackedUp)
    }

    @Test func aLostMarkerWhileSignedInIsStillADestinationProblem() async throws {
        let h = try backedUp()
        try FileManager.default.removeItem(at: h.backupRoot)
        await h.run()
        #expect(try h.active == [.destinationMissing])
    }
}

@Suite struct NoSilentNonRunsTests {
    private func failureRecord(_ h: Harness) throws -> RunRecord? {
        try h.records.recent(limit: 5).first { $0.setID == PairID.agent.set }
    }

    @Test func unreadableConfigIsRecordedRaisedAndFails() async throws {
        let h = try Harness()
        try Data("not json".utf8).write(to: h.support.appendingPathComponent("sets.json"))
        let ok = await h.run()
        #expect(ok == false)
        #expect(try failureRecord(h)?.status == .failed)
        #expect(try h.active == [.agentFailed])
    }

    @Test func aGoodRunClearsTheAgentProblem() async throws {
        let h = try Harness(); try h.prime()
        try await h.problems.raise(.agentFailed, pair: .agent, setName: "Mirror", detail: "x")
        let ok = await h.run()
        #expect(ok)
        #expect(try h.active.isEmpty)
    }

    @Test func lockOpenFailureIsRecordedRaisedAndFails() async throws {
        let h = try Harness(); try h.prime()
        try Data().write(to: h.support.appendingPathComponent("locks"))   // a file where the folder belongs
        let ok = await h.run()
        #expect(ok == false)
        #expect(try failureRecord(h) != nil)
        #expect(try h.active == [.agentFailed])
    }

    @Test func aHeldLockIsQuietAndSucceeds() async throws {
        let h = try Harness(); try h.prime()
        let other = RunLock(url: h.support.appendingPathComponent("locks/agent.lock"))
        #expect(other.tryAcquire())
        let ok = await h.run()
        #expect(ok)
        other.release()
    }

    @Test func aFailedPresetLoadCanBeReported() async throws {
        let h = try Harness()
        await AgentFailureReport.file("Presets could not be loaded", records: h.records, problems: h.problems, now: h.now)
        #expect(try failureRecord(h)?.errors == ["Presets could not be loaded"])
        #expect(try h.active == [.agentFailed])
    }

    @Test func agentProblemsReachTheStatus() throws {
        let set = BackupSet(name: "x", source: URL(fileURLWithPath: "/x"))
        let problem = ActiveProblem(problem: .agentFailed, pair: .agent, setName: "Mirror", detail: "", since: Date())
        let status = StatusSummary.overall(sets: [set], destinations: [], states: [:], records: [], problems: [problem], running: false)
        #expect(status == .attention(Problem.agentFailed.headline))
    }

    @Test func anUntrustedHelperStopsBeforeAnySessionOrChange() async throws {
        let h = try Harness()
        let d = try h.addCloud(); h.set.destinationIDs = [d.id]; try h.save(extra: [d])
        let session = FakeSession(endpoint: "c:"); h.setSession(d, session)
        h.helperError = AgentFailure.untrustedHelper
        let ok = await h.run(RunCommand(force: true))
        #expect(ok == false)
        #expect(session.opens == 0)
        #expect(h.feed.calls == 0)
        #expect(try h.active == [.agentFailed])
    }

    @Test func aNotificationNeverCrossesAnOpenCloudSession() async throws {
        let h = try Harness()
        let d = try h.addCloud(); h.set.destinationIDs = [d.id]; try h.save(extra: [d])
        let session = FakeSession(endpoint: "c:"); h.setSession(d, session)
        try h.cloudMarker(at: "c:.mirror-root")
        let p = PairID(set: h.set.id, destination: d.id); try h.prime(p, kind: .googleDrive)
        h.change("flowapp/a.txt")
        h.rclone.script(dryDeletions: (0..<500).map { "f\($0)" })
        final class Seen: @unchecked Sendable { var closes = -1 }
        let seen = Seen()
        h.notifier.onPost = { seen.closes = session.closes }
        await h.run()
        #expect(h.notifier.posted == [.deletionsHeld])
        #expect(seen.closes == 1)
    }
}

/// Fix round 3: an evicted owed file's way out is iCloud bringing it back, then a passing hash.
@Suite struct FreedDownloadTests {
    private func owedFreed(_ h: Harness, _ names: [String] = ["a.txt"]) throws {
        try h.prime()
        var s = try h.state
        for (i, name) in names.enumerated() {
            try Data().write(to: h.source.appendingPathComponent("flowapp/\(name)"))
            s.verifyOwed.append("flowapp/\(name)")
            s.freedSince["flowapp/\(name)"] = h.now.addingTimeInterval(Double(i))
        }
        s.verifyOwed.sort()
        try h.store.save(s, for: h.pair)
        h.freed = Set(names)
    }

    @Test func owedEvictedFilesAreRequestedAtTheirMirrorPath() async throws {
        let h = try Harness(); try owedFreed(h)
        await h.run()
        #expect(h.downloader.requested.map(\.path) == [h.mirror + "/flowapp/a.txt"])
    }

    @Test func requestsStopAtTheLimitOldestFirst() async throws {
        let h = try Harness()
        try owedFreed(h, (0...RunCoordinator.maxDownloadsPerRun).map { String(format: "f%04d", $0) })
        await h.run()
        #expect(h.downloader.requested.count == RunCoordinator.maxDownloadsPerRun)
        #expect(h.downloader.requested.first?.lastPathComponent == "f0000")
        #expect(!h.downloader.requested.contains { $0.lastPathComponent == String(format: "f%04d", RunCoordinator.maxDownloadsPerRun) })
    }

    @Test func onlyOwedFilesAreEverRequested() async throws {
        let h = try Harness(); try h.prime()
        let m = h.backupRoot.appendingPathComponent("Sets/x/flowapp")
        try FileManager.default.createDirectory(at: m, withIntermediateDirectories: true)
        try Data().write(to: m.appendingPathComponent("other.txt"))
        var s = try h.state; s.lastFullPass = h.now.addingTimeInterval(-25 * hour); try h.store.save(s, for: h.pair)
        h.freed = ["other.txt"]   // evicted, but nothing is owed on it
        await h.run()
        #expect(h.downloader.requested.isEmpty)
    }

    @Test func aFileBackOnDiskIsHashedAndOnlyThenCleared() async throws {
        let h = try Harness(); try owedFreed(h)
        await h.run()
        #expect(try h.state.verifyOwed == ["flowapp/a.txt"])   // asked for, not yet proven
        h.freed = []
        await h.run()
        #expect(h.rclone.hashed.last == ["a.txt"])
        #expect(try h.state.verifyOwed.isEmpty)
        #expect(try h.state.isBackedUp)
    }

    @Test func aDownloadedFileThatMismatchesStaysOwed() async throws {
        let h = try Harness(); try owedFreed(h)
        await h.run()
        h.freed = []
        h.rclone.script(hashDifferences: 1, differing: ["a.txt"])
        await h.run()
        #expect(try h.state.verifyOwed == ["flowapp/a.txt"])
        #expect(try h.state.mismatched == ["flowapp/a.txt"])
        #expect(try h.active == [.verificationFailed])
    }

    @Test func aRefusedRequestIsRetriedAndFailsNothing() async throws {
        let h = try Harness(); try owedFreed(h)
        h.downloader.fail(CocoaError(.fileReadUnknown))
        await h.run()
        h.downloader.fail(nil)
        await h.run()
        #expect(h.downloader.requested.count == 2)
        #expect(try h.state.consecutiveFailures == 0)
    }

    @Test func nothingIsRequestedWhileICloudIsStopped() async throws {
        let h = try Harness(); try owedFreed(h)
        h.auditor.set(refused: [RootMarker.fileName])
        await h.run()
        #expect(h.downloader.requested.isEmpty)
    }

    @Test func theWaitIsStatedInTheRecordAndState() async throws {
        let h = try Harness(); try owedFreed(h, ["a.txt", "b.txt"])
        await h.run()
        #expect(try h.state.waitingForDownload == 2)
        #expect(try h.latest()?.verification == "Waiting for iCloud to download 2 files to verify")
    }

    @Test func theWaitReachesTheOverallStatus() throws {
        let set = { () -> BackupSet in
            var s = BackupSet(name: "x", source: URL(fileURLWithPath: "/x")); s.destinationIDs = [UUID()]; return s
        }()
        let d = Destination(id: set.destinationIDs[0], name: "i", kind: .iCloudFolder)
        var state = SetState()
        state.lastFinished = Date(); state.verifyOwed = ["a"]; state.freedSince = ["a": Date()]
        let status = StatusSummary.overall(sets: [set], destinations: [d], states: [PairID(set: set.id, destination: d.id): state],
                                           records: [], problems: [], running: false)
        #expect(status == .waitingForDownload(1))
    }
}

/// Fix round 3: past the bound the flag takes over, and nothing but a whole-set check ends it.
@Suite struct OverflowTests {
    private func many() -> [String] { (0...RunCoordinator.maxOwed).map { "f\($0)" } }

    private func withFreedOwed(_ h: Harness) throws {
        try h.prime()
        try Data().write(to: h.source.appendingPathComponent("flowapp/old.txt"))
        var s = try h.state
        s.verifyOwed = ["flowapp/old.txt"]; s.freedSince = ["flowapp/old.txt": h.now]; s.mismatched = ["flowapp/old.txt"]
        try h.store.save(s, for: h.pair)
        h.freed = ["old.txt"]
    }

    @Test func aScopedOverflowKeepsFreedFilesAndIsNotSuccess() async throws {
        let h = try Harness(); try withFreedOwed(h); h.change("flowapp/a.txt")
        h.rclone.script(copied: many(), planned: many())
        await h.run()
        let s = try h.state
        #expect(s.hashWholeSet)
        #expect(s.verifyOwed == ["flowapp/old.txt"])
        #expect(s.freedSince.keys.sorted() == ["flowapp/old.txt"])
        #expect(s.mismatched == ["flowapp/old.txt"])
        #expect(s.isBackedUp == false)
        #expect(try h.latest()?.status == .partial)
    }

    /// A run that reaches `prove` puts them back by itself, which hides a wipe. One that stops first can't.
    @Test func anOverflowThenAFailedSyncStillKeepsFreedFiles() async throws {
        let h = try Harness(); try withFreedOwed(h); h.change("flowapp/a.txt")
        h.rclone.script(real: [.permanent], planned: many())
        await h.run()
        let s = try h.state
        #expect(s.hashWholeSet)
        #expect(s.verifyOwed == ["flowapp/old.txt"])
        #expect(s.freedSince.keys.sorted() == ["flowapp/old.txt"])
        #expect(s.mismatched == ["flowapp/old.txt"])
    }

    @Test func aScopedRunNeverClearsTheFlag() async throws {
        let h = try Harness(); try h.prime(); h.change("flowapp/a.txt")
        var s = try h.state; s.hashWholeSet = true; try h.store.save(s, for: h.pair)
        final class Scoped: RcloneRunning, @unchecked Sendable {
            let inner: FakeRclone
            init(_ i: FakeRclone) { inner = i }
            func sync(_ r: SyncRequest) async throws -> RcloneResult { try await inner.sync(r) }
            func check(_ r: CheckRequest) async throws -> RcloneResult { try await inner.check(r) }
        }
        await h.coordinator(rclone: Scoped(h.rclone)).runAll(command: RunCommand())
        // The planner widens it, so a flag can only leave by the whole-set route.
        #expect(h.rclone.realSyncs.last?.destination == h.mirror)
    }

    @Test func theNextRunsDeepCheckEndsTheFlagAndKeepsFreedFiles() async throws {
        let h = try Harness(); try withFreedOwed(h); h.change("flowapp/a.txt")
        h.rclone.script(copied: many(), planned: many())
        await h.run()
        h.rclone.script()
        try FileManager.default.createDirectory(at: h.backupRoot.appendingPathComponent("Sets/x"), withIntermediateDirectories: true)
        await h.run()
        #expect(h.rclone.checks.contains { $0.logFile.lastPathComponent == "deep-size.log" })
        #expect(try h.state.hashWholeSet == false)
        #expect(try h.state.verifyOwed == ["flowapp/old.txt"])
    }

    @Test func aFailedDeepCheckLeavesTheFlagUp() async throws {
        let h = try Harness(); try h.prime()
        var s = try h.state; s.hashWholeSet = true; try h.store.save(s, for: h.pair)
        try FileManager.default.createDirectory(at: h.backupRoot.appendingPathComponent("Sets/x"), withIntermediateDirectories: true)
        h.rclone.script(differing: ["flowapp/a.txt"], deepDifferences: 1)
        await h.run()
        #expect(try h.state.hashWholeSet)
    }

    @Test func aDeepCheckThatCouldNotFinishProvesNothing() async throws {
        let h = try Harness(); try h.prime()
        var s = try h.state
        s.hashWholeSet = true; s.verifyOwed = ["flowapp/a.txt"]; s.mismatched = ["flowapp/a.txt"]
        try h.store.save(s, for: h.pair)
        // Quick passes, then Deep can't even start: the mirror folder is missing.
        await h.run()
        #expect(try h.state.verifyOwed == ["flowapp/a.txt"])
        #expect(try h.state.mismatched == ["flowapp/a.txt"])
        #expect(try h.state.hashWholeSet)
    }

    @Test func aWholeSetOverflowIsProvenInTheSameRunWithOneHash() async throws {
        let h = try Harness(); try h.prime(); h.change("flowapp/a.txt", rescan: true)
        let m = h.backupRoot.appendingPathComponent("Sets/x")
        try FileManager.default.createDirectory(at: m, withIntermediateDirectories: true)
        for name in many() { try Data().write(to: m.appendingPathComponent(name)) }   // so the deep check hashes them
        h.rclone.script(copied: many(), planned: many())
        await h.run()
        #expect(try h.state.hashWholeSet == false)
        #expect(h.rclone.checks.contains { $0.logFile.lastPathComponent == "deep-size.log" })
        #expect(!h.rclone.checks.contains { $0.logFile.lastPathComponent == "quick-hash.log" })
        #expect(try h.latest()?.status == .success)
    }

    /// Nothing clears unless a hash of that file passed.
    private func flagged(_ h: Harness, mirrored: [String] = [], freed: [String] = []) throws {
        try h.prime()
        var s = try h.state; s.hashWholeSet = true; try h.store.save(s, for: h.pair)
        let m = h.backupRoot.appendingPathComponent("Sets/x/flowapp")
        try FileManager.default.createDirectory(at: m, withIntermediateDirectories: true)
        for name in mirrored + freed {
            try Data().write(to: m.appendingPathComponent(name))
            try Data().write(to: h.source.appendingPathComponent("flowapp/\(name)"))
        }
        h.freed = Set(freed)
    }

    @Test func aFileTheDeepCheckDidNotHashStaysOwed() async throws {
        let h = try Harness(); try flagged(h)
        var s = try h.state; s.verifyOwed = ["flowapp/a.txt"]; s.mismatched = ["flowapp/a.txt"]; try h.store.save(s, for: h.pair)
        await h.run()   // a.txt isn't in the mirror, so the deep check's list can't have held it
        #expect(try h.state.verifyOwed == ["flowapp/a.txt"])
        #expect(try h.state.mismatched == ["flowapp/a.txt"])
        #expect(try h.state.freedSince.isEmpty)   // owed, but not evicted: the next run can hash it
    }

    @Test func evictedFilesTheFlagStoodForAreOwedAfterItsDeepCheck() async throws {
        let h = try Harness()
        let names = (0..<(RunCoordinator.freedSample + 5)).map { "e\($0).txt" }
        try flagged(h, freed: names)
        await h.run()
        let s = try h.state
        #expect(s.hashWholeSet == false)
        #expect(s.verifyOwed.count == 5)   // the rest were sampled, so hashed
        #expect(Set(s.freedSince.keys) == Set(s.verifyOwed))
    }

    @Test func aRoutineDeepCheckOwesNothingForEvictedFiles() async throws {
        let h = try Harness(); try h.prime()
        let m = h.backupRoot.appendingPathComponent("Sets/x/flowapp")
        try FileManager.default.createDirectory(at: m, withIntermediateDirectories: true)
        let names = (0..<(RunCoordinator.freedSample + 5)).map { "e\($0).txt" }
        for name in names {
            try Data().write(to: m.appendingPathComponent(name))
            try Data().write(to: h.source.appendingPathComponent("flowapp/\(name)"))
        }
        h.freed = Set(names)
        var s = try h.state
        s.lastFullPass = h.now.addingTimeInterval(-25 * hour); s.lastDeepCheck = h.now.addingTimeInterval(-31 * 24 * hour)
        try h.store.save(s, for: h.pair)
        await h.run()
        #expect(try h.state.verifyOwed.isEmpty)
        #expect(h.downloader.requested.isEmpty)
    }

    @Test func aWholeSetDeepRunPastTheFreedBoundKeepsTheFlag() async throws {
        let h = try Harness()
        let names = (0...RunCoordinator.maxFreed).map { "k\($0)" }
        try flagged(h, freed: names)
        h.change("flowapp/a.txt", rescan: true)
        var s = try h.state
        s.verifyOwed = names.map { "flowapp/\($0)" }
        for name in names.dropLast() { s.freedSince["flowapp/\(name)"] = h.now }
        try h.store.save(s, for: h.pair)
        await h.run()
        let after = try h.state
        #expect(after.freedSince.count == RunCoordinator.maxFreed)
        #expect(after.hashWholeSet)
        #expect(after.isBackedUp == false)
    }

    @Test func aFullFreedListWaitsInsteadOfRepeatingDeepChecks() async throws {
        let h = try Harness(); try h.prime()
        var s = try h.state
        s.hashWholeSet = true
        for i in 0..<RunCoordinator.maxFreed {
            s.freedSince["flowapp/k\(i)"] = h.now; s.verifyOwed.append("flowapp/k\(i)")
        }
        try h.store.save(s, for: h.pair)
        h.freed = Set((0..<RunCoordinator.maxFreed).map { "k\($0)" })
        await h.run()
        #expect(h.rclone.allCalls == 0)
        #expect(try h.state.hashWholeSet)
    }

    @Test func anOverflowClassifiesEvictedFilesBeforeDroppingThem() async throws {
        let h = try Harness(); try h.prime(); h.change("flowapp/a.txt")
        h.freed = ["old.txt"]
        h.rclone.script(real: [.permanent], planned: many() + ["old.txt"])
        await h.run()
        #expect(try h.state.freedSince.keys.sorted() == ["flowapp/old.txt"])
        #expect(try h.state.verifyOwed == ["flowapp/old.txt"])
        #expect(try h.state.hashWholeSet)
    }

    @Test func theFreedListIsBoundedAndTheFlagCoversTheRest() async throws {
        let h = try Harness(); try h.prime()
        var s = try h.state
        for i in 0..<RunCoordinator.maxFreed {
            s.freedSince["flowapp/k\(i)"] = h.now; s.verifyOwed.append("flowapp/k\(i)")
            try Data().write(to: h.source.appendingPathComponent("flowapp/k\(i)"))
        }
        s.verifyOwed.append("flowapp/a.txt")
        try h.store.save(s, for: h.pair)
        h.freed = Set((0..<RunCoordinator.maxFreed).map { "k\($0)" } + ["a.txt"])
        await h.run()
        let after = try h.state
        #expect(after.freedSince.count == RunCoordinator.maxFreed)
        #expect(after.hashWholeSet)
        #expect(after.isBackedUp == false)
    }
}

/// Fix round 3: a mismatch is a recorded fact, cleared only by a hash.
@Suite struct RecordedMismatchTests {
    private func deepFailed(_ h: Harness, path: String = "flowapp/a.txt") async throws {
        try h.prime()
        var s = try h.state; s.hashWholeSet = true; try h.store.save(s, for: h.pair)
        let mirrored = h.backupRoot.appendingPathComponent("Sets/x/flowapp")
        try FileManager.default.createDirectory(at: mirrored, withIntermediateDirectories: true)
        try Data().write(to: mirrored.appendingPathComponent("a.txt"))
        h.rclone.script(differing: [path], deepDifferences: 1)
        await h.run()
        #expect(try h.active == [.verificationFailed])
    }

    @Test func aDeepMismatchIsOwedAndRecorded() async throws {
        let h = try Harness(); try await deepFailed(h)
        #expect(try h.state.verifyOwed == ["flowapp/a.txt"])
        #expect(try h.state.mismatched == ["flowapp/a.txt"])
    }

    @Test func aDeepMismatchInAFileThatLeftTheSourceIsNotOwed() async throws {
        let h = try Harness(); try await deepFailed(h, path: "flowapp/deleted.txt")
        #expect(try h.state.verifyOwed.isEmpty)
    }

    @Test func aDeepMismatchClearsOnlyOnAPassingHash() async throws {
        let h = try Harness(); try await deepFailed(h)
        h.rclone.script()
        await h.run()
        #expect(h.rclone.hashed.contains { $0.contains("flowapp/a.txt") })
        #expect(try h.state.mismatched.isEmpty)
        #expect(try h.active.isEmpty)
    }

    @Test func anEvictedDeepMismatchCantClearUnhashed() async throws {
        let h = try Harness(); try await deepFailed(h)
        h.rclone.script()
        h.freed = ["a.txt"]
        await h.run()
        #expect(try h.state.mismatched == ["flowapp/a.txt"])
        #expect(try h.state.verifyOwed == ["flowapp/a.txt"])
        #expect(try h.active == [.verificationFailed])
    }

    @Test func anUnrelatedFreedFileDoesNotHoldTheAlertOpen() async throws {
        let h = try Harness(); try h.prime(); h.change("flowapp/a.txt")
        try Data().write(to: h.source.appendingPathComponent("flowapp/b.txt"))
        h.rclone.script(copied: ["a.txt"], hashDifferences: 1, differing: ["flowapp/a.txt"].map { String($0.dropFirst(8)) })
        await h.run()
        #expect(try h.active == [.verificationFailed])
        var s = try h.state; s.verifyOwed.append("flowapp/b.txt"); s.verifyOwed.sort(); try h.store.save(s, for: h.pair)
        h.rclone.script()
        h.freed = ["b.txt"]
        await h.run()
        #expect(try h.state.mismatched.isEmpty)
        #expect(try h.state.verifyOwed == ["flowapp/b.txt"])
        #expect(try h.active.isEmpty)
    }

    @Test func aFileThatChangedDuringTheRunIsOwedButNotAMismatch() async throws {
        let h = try Harness(); try h.prime()
        let a = h.source.appendingPathComponent("flowapp/a.txt").path
        h.feed.set(ChangeBatch(paths: [a], mustRescan: false, latestEventID: 10),
                   changedLater: ChangeBatch(paths: [a], mustRescan: false, latestEventID: 11))
        h.rclone.script(differences: 1, differing: ["a.txt"])
        await h.run()
        #expect(try h.state.verifyOwed == ["flowapp/a.txt"])
        #expect(try h.state.mismatched.isEmpty)
    }
}

/// Fix round 3, the self-contained items.
@Suite struct RoundThreeSmallTests {
    @Test func changedPathsAreMatchedInFullNotBySuffix() async throws {
        let h = try Harness(); try h.prime()
        let root = h.source.appendingPathComponent("a.txt").path
        let deep = h.source.appendingPathComponent("flowapp/a.txt").path   // same name, a different file
        h.feed.set(ChangeBatch(paths: [root], mustRescan: false, latestEventID: 10),
                   changedLater: ChangeBatch(paths: [deep], mustRescan: false, latestEventID: 11))
        h.rclone.script(differences: 1, differing: ["a.txt"])
        await h.run()
        #expect(h.notifier.posted == [.verificationFailed])
    }

    @Test func anUnreadableMarkerValueIsNotSignOut() async throws {
        let h = try Harness(); try h.prime(); h.change("flowapp/a.txt")
        h.auditor.set(refused: [RootMarker.fileName])   // what the audit would call it, not knowing better
        h.auditor.set(unreadable: [RootMarker.fileName])
        await h.run()
        #expect(try h.active.isEmpty)
        #expect(h.rclone.realSyncs.count == 1)
    }

    @Test func aMarkerReadingUbiquitousAgainClearsTheStopAndRuns() async throws {
        let h = try Harness(); try h.prime(); h.change("flowapp/a.txt")
        h.auditor.set(refused: [RootMarker.fileName])
        await h.run()
        #expect(try h.state.stoppedBy == .iCloudUnavailable)
        h.auditor.set()
        await h.run()
        #expect(try h.state.stoppedBy == nil)
        #expect(try h.active.isEmpty)
        #expect(try h.state.lastEventID == 10)
    }

    @Test func aDatalessMarkerIsAcceptedWithoutBeingRead() async throws {
        let h = try Harness(); try h.prime(); h.change("flowapp/a.txt")
        // Unparsable on purpose: reading it would stop the pair.
        try Data("not json".utf8).write(to: RootMarker.url(backupRoot: h.backupRoot))
        h.freed = [RootMarker.fileName]
        await h.run()
        #expect(try h.active.isEmpty)
        #expect(h.rclone.realSyncs.count == 1)
    }

    @Test func aDatalessMarkerStillHasToBeInICloud() async throws {
        let h = try Harness(); try h.prime(); h.change("flowapp/a.txt")
        h.freed = [RootMarker.fileName]
        h.auditor.set(refused: [RootMarker.fileName])
        await h.run()
        #expect(try h.active == [.iCloudUnavailable])
        #expect(h.rclone.allCalls == 0)
    }

    @Test func aNewPairWaitsForADatalessMarkerWithoutReadingOrFailing() async throws {
        let h = try Harness()
        try RootMarker(sets: [UUID(): "other"]).save(backupRoot: h.backupRoot)
        h.freed = [RootMarker.fileName]
        await h.run()
        #expect(h.rclone.allCalls == 0)
        #expect(try h.latest()?.status == .skipped)
        #expect(try h.state.consecutiveFailures == 0)
        #expect(h.downloader.requested.map(\.lastPathComponent) == [RootMarker.fileName])
    }

    @Test func uploadLimitDoesNotOutrankARealFailure() {
        let limit = #"{"level":"error","msg":"Failed to copy: googleapi: Error 403: User rate limit exceeded., userRateLimitExceeded","object":"a.bin"}"#
        let real = #"{"level":"error","msg":"Failed to copy: permission denied","object":"b.bin"}"#
        let summary = #"{"level":"error","msg":"Attempt 1/3 failed with 2 errors and: limit"}"#
        #expect(RcloneLogParser.outcome(exitCode: 7, log: Data((limit + "\n" + real).utf8)) == .permanent)
        #expect(RcloneLogParser.outcome(exitCode: 7, log: Data((limit + "\n" + summary).utf8)) == .partial)
    }

    @Test func iCloudAuditorTellsUnreadableFromNotUbiquitous() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ubq-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(ICloudAuditor().ubiquity(of: dir) == false)
        #expect(ICloudAuditor().ubiquity(of: dir.appendingPathComponent("nope")) == nil)
    }
}

/// Fix round 2.
@Suite struct RoundTwoTests {
    private func mismatched(_ h: Harness) async throws {
        try h.prime(); h.change("flowapp/a.txt")
        h.rclone.script(copied: ["a.txt"], hashDifferences: 1, differing: ["a.txt"])
        await h.run()
        #expect(try h.active == [.verificationFailed])
    }

    @Test func anEvictedOwedFileIsNotClearedUnhashed() async throws {
        let h = try Harness(); try await mismatched(h)
        h.rclone.script()
        h.freed = ["a.txt"]
        await h.run()
        #expect(h.rclone.hashed.count == 1)   // only the first run's: nothing was hashed this time
        #expect(try h.state.verifyOwed == ["flowapp/a.txt"])
        #expect(try h.state.freedSince["flowapp/a.txt"] == h.now)
        #expect(try h.state.isBackedUp == false)
        #expect(try h.active == [.verificationFailed])   // unhashed proves nothing, so the alert stands
    }

    @Test func aFreedFileDoesNotForceAnRcloneRunEveryWakeUp() async throws {
        let h = try Harness(); try await mismatched(h)
        h.rclone.script(); h.freed = ["a.txt"]
        await h.run()
        let calls = h.rclone.allCalls
        await h.run()
        #expect(h.rclone.allCalls == calls)
        #expect(try h.state.verifyOwed == ["flowapp/a.txt"])
    }

    @Test func aFreedFileIsHashedOnceItsBackOnDisk() async throws {
        let h = try Harness(); try await mismatched(h)
        h.rclone.script(); h.freed = ["a.txt"]
        await h.run()
        h.freed = []
        await h.run()
        #expect(h.rclone.hashed.last == ["a.txt"])
        #expect(try h.state.verifyOwed.isEmpty)
        #expect(try h.state.freedSince.isEmpty)
        #expect(try h.active.isEmpty)
    }

    private func deepDue(_ h: Harness, freed: [String]) throws {
        try h.prime()
        let dir = h.backupRoot.appendingPathComponent("Sets/x/flowapp")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var s = try h.state
        s.lastFullPass = h.now.addingTimeInterval(-25 * hour)
        s.lastDeepCheck = h.now.addingTimeInterval(-31 * 24 * hour)
        for name in freed {
            try Data().write(to: dir.appendingPathComponent(name))
            try Data().write(to: h.source.appendingPathComponent("flowapp/\(name)"))
            s.verifyOwed.append("flowapp/\(name)")
            s.freedSince["flowapp/\(name)"] = h.now.addingTimeInterval(-40 * 24 * hour)
        }
        s.verifyOwed.sort()
        try h.store.save(s, for: h.pair)
        h.freed = Set(freed)
    }

    @Test func aPassingDeepCheckNeverClearsAFreedOwedFile() async throws {
        let h = try Harness(); try deepDue(h, freed: ["old.txt"])
        await h.run()
        #expect(try h.state.verifyOwed == ["flowapp/old.txt"])
        #expect(try h.state.freedSince.keys.sorted() == ["flowapp/old.txt"])
        #expect(try h.state.reviewItems.map(\.kind) == [.unprovenFreed])
    }

    @Test func aSampledFreedFileThatMismatchesStaysOwedAndFlagged() async throws {
        let h = try Harness(); try deepDue(h, freed: ["old.txt"])
        h.rclone.script(hashDifferences: 1, differing: ["flowapp/old.txt"])
        await h.run()
        #expect(try h.state.verifyOwed == ["flowapp/old.txt"])
        #expect(try h.state.reviewItems.map(\.kind) == [.unprovenFreed])
        #expect(try h.active.contains(.verificationFailed))
    }

    @Test func anOweUnderTheFlagKeepsAMissingFile() async throws {
        let h = try Harness(); try h.prime(); h.change("flowapp/gone-x.txt")
        try Data().write(to: h.source.appendingPathComponent("flowapp/gone-x.txt"))
        let many = (0...RunCoordinator.maxOwed).map { "f\($0)" }
        h.rclone.script(copied: many + ["gone-x.txt"], planned: many)
        await h.run()
        #expect(try h.state.verifyOwed == ["flowapp/gone-x.txt"])
        #expect(try h.state.hashWholeSet)
    }

    @Test func aDifferenceCountWithNoNamedPathIsNotExplained() async throws {
        let h = try Harness(); try h.prime()
        let a = h.source.appendingPathComponent("flowapp/a.txt").path
        h.feed.set(ChangeBatch(paths: [a], mustRescan: false, latestEventID: 10),
                   changedLater: ChangeBatch(paths: [a], mustRescan: false, latestEventID: 11))
        h.rclone.script(differences: 2, differing: ["a.txt"])   // two differences, only one explained
        await h.run()
        #expect(h.notifier.posted == [.verificationFailed])
    }

    @Test func aDeepDifferenceFromAChangingFileIsRetried() async throws {
        let h = try Harness(); try h.prime()
        let a = h.source.appendingPathComponent("flowapp/a.txt").path
        var s = try h.state; s.hashWholeSet = true; try h.store.save(s, for: h.pair)
        try FileManager.default.createDirectory(at: h.backupRoot.appendingPathComponent("Sets/x"), withIntermediateDirectories: true)
        h.feed.set(ChangeBatch(paths: [a], mustRescan: false, latestEventID: 10),
                   changedLater: ChangeBatch(paths: [a], mustRescan: false, latestEventID: 11))
        h.rclone.script(differing: ["flowapp/a.txt"], deepDifferences: 1)
        await h.run()
        #expect(h.notifier.posted.isEmpty)
        #expect(try h.state.consecutiveFailures == 1)
    }

    @Test func aPairLockThatWontOpenIsRecorded() async throws {
        let h = try Harness(); try h.prime(); h.change("flowapp/a.txt")
        let name = "\(h.pair.set.uuidString)-\(h.pair.destination.uuidString).lock"
        try FileManager.default.createDirectory(at: h.support.appendingPathComponent("locks/\(name)"), withIntermediateDirectories: true)
        await h.run()
        #expect(h.rclone.allCalls == 0)
        #expect(try h.latest()?.status == .failed)
        #expect(try h.active == [.repeatedFailures])
    }

    @Test func configLostMidRunIsRecordedAndFails() async throws {
        let h = try Harness(); try h.prime(); h.change("flowapp/a.txt")
        var other = BackupSet(name: "y", source: h.root.appendingPathComponent("src2"))
        try FileManager.default.createDirectory(at: other.source.appendingPathComponent("p"), withIntermediateDirectories: true)
        other.destinationIDs = [h.iCloudDest.id]
        try h.store.saveSets([h.set, other])
        let sets = h.support.appendingPathComponent("sets.json")
        h.rclone.onRealSync = { try? Data("not json".utf8).write(to: sets) }
        let ok = await h.run()
        #expect(ok == false)
        #expect(try h.records.recent(limit: 5).contains { $0.setID == PairID.agent.set })
        #expect(try h.active.contains(.agentFailed))
    }

    @Test func anUntrustedHelperMidRunFailsTheAgent() async throws {
        let h = try Harness(); try h.prime(); h.change("flowapp/a.txt")
        h.rclone.failRealSync(AgentFailure.untrustedHelper)
        let ok = await h.run()
        #expect(ok == false)
        #expect(try h.active == [.agentFailed])
    }

    @Test func aHoldIsStoredBeforeTheSyncSoAKillCantLoseIt() async throws {
        let h = try Harness(); try h.prime(); h.change("flowapp/a.txt")
        h.rclone.script(dryDeletions: (0..<500).map { "f\($0)" })
        final class Seen: @unchecked Sendable { var problems: [Problem] = [] }
        let seen = Seen()
        h.rclone.onRealSync = { seen.problems = (try? h.active) ?? [] }
        await h.run()
        #expect(seen.problems == [.deletionsHeld])
        #expect(h.notifier.posted == [.deletionsHeld])
    }

    @Test func aStoredHoldIsNotifiedByTheNextRunAfterAKill() async throws {
        let h = try Harness(); try h.prime()
        try h.problems.store(.deletionsHeld, pair: h.pair, setName: "x", detail: "500 deletions held")
        #expect(h.notifier.posted.isEmpty)
        await h.run()
        #expect(h.notifier.posted == [.deletionsHeld])
    }

    @Test func anExternalDrivePairNeverTouchesTheICloudRoot() async throws {
        let h = try Harness(); try h.claim()
        var d = Destination(name: "Drive", kind: .externalDrive, encrypted: false)
        d.volumeUUID = UUID().uuidString
        h.set.destinationIDs = [d.id]; try h.save(extra: [d])
        h.change("flowapp/a.txt", rescan: true)
        await h.run()
        #expect(h.rclone.allCalls == 0)
        #expect(h.session(d) == nil)
        #expect(h.files.calls == 0)
        #expect(try h.latest()?.status == .skipped)
        #expect(try h.active.isEmpty)
    }

    @Test func theApprovedMaxDeleteIsTheReviewedCountPlusGit() async throws {
        let h = try Harness(); try h.prime(); h.change("flowapp/a.txt")
        let plain = (0..<500).map { "f\($0)" }
        h.rclone.script(dryDeletions: plain)
        await h.run()
        h.rclone.script(dryDeletions: plain + ["p/.git/x", "p/.git/y"])
        await h.run(RunCommand(setID: h.set.id, approvedDeletions: 500, force: true))
        #expect(h.rclone.realSyncs.last?.mode == .mirror(maxDelete: 502))
    }
}

@Suite struct CoordinatorRoundOneMinorTests {
    @Test func rawRcloneTextIsScrubbedInRecords() async throws {
        let h = try Harness(); try h.prime(); h.change("flowapp/a.txt")
        h.rclone.script(real: [.permanent], errors: [#"a.txt: Post "https://www.googleapis.com/upload?key=SECRETKEY&uploadType=x": {"access_token":"ya29.SECRET"} Bearer abc123SECRET"#])
        await h.run()
        let text = try #require(try h.latest()).errors.joined()
        #expect(text.contains("a.txt"))
        #expect(!text.contains("SECRET"))
    }

    @Test func wholeSetOwedIsSavedBeforeTheDryRun() async throws {
        let h = try Harness(); try h.prime(); h.change("flowapp/a.txt", rescan: true)
        final class Seen: @unchecked Sendable { var owed: Bool? }
        let seen = Seen()
        h.rclone.onDryRun = { seen.owed = try? h.state.wholeSetOwed }
        h.rclone.script(dryOutcome: .transient)
        await h.run()
        #expect(seen.owed == true)
        #expect(try h.state.wholeSetOwed)
    }

    @Test func aFileChangingElsewhereDoesNotExcuseARealMismatch() async throws {
        let h = try Harness(); try h.prime()
        let a = h.source.appendingPathComponent("flowapp/a.txt").path, other = h.source.appendingPathComponent("flowapp/other.txt").path
        h.feed.set(ChangeBatch(paths: [a], mustRescan: false, latestEventID: 10),
                   changedLater: ChangeBatch(paths: [other], mustRescan: false, latestEventID: 11))
        h.rclone.script(differences: 1, differing: ["a.txt"])
        await h.run()
        #expect(h.notifier.posted == [.verificationFailed])
    }

    @Test func excludedOnlyBatchesAdvanceTheEventID() async throws {
        let h = try Harness(); try h.prime()
        h.set.rules = [UserRule(pattern: "cache/**", action: .exclude)]; try h.save()
        h.change("flowapp/cache/a.bin")
        await h.run()
        #expect(h.rclone.allCalls == 0)
        #expect(try h.state.lastEventID == 10)
    }

    @Test func aFailedSaveIsNeverReportedAsSuccess() async throws {
        let h = try Harness(); try h.prime(); h.change("flowapp/a.txt")
        let dir = h.support.appendingPathComponent("state").path
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir) }
        await h.run()
        #expect(try h.latest()?.status == .failed)
    }

    @Test func aFailedPreSyncSaveStopsTheSync() async throws {
        let h = try Harness(); try h.prime(); h.change("flowapp/a.txt")
        let dir = h.support.appendingPathComponent("state").path
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir) }
        await h.run()
        #expect(h.rclone.realSyncs.isEmpty)
    }

    @Test func knownProjectsWaitUntilPresetsAreSaved() async throws {
        let h = try Harness(); try h.prime()
        let flutter = Preset(id: "flutter", name: "Flutter", markers: ["pubspec.yaml"], alwaysExclude: [], ambiguousExclude: ["build/"])
        let app = h.source.appendingPathComponent("newapp")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try Data().write(to: app.appendingPathComponent("pubspec.yaml"))
        await h.run()   // so the lock files already exist when the folder goes read-only
        h.change("newapp")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: h.support.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: h.support.path) }
        await h.run(presets: [flutter])
        #expect(try h.state.knownProjects == [])
        #expect(h.rclone.realSyncs.isEmpty)
    }

    @Test func stateFromBeforeTheNewFieldsStillLoads() throws {
        let old = #"{"consecutiveFailures":2,"heldDeletions":3,"pendingUploads":1,"refusedSince":{},"reviewItems":[]}"#
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        let s = try d.decode(SetState.self, from: Data(old.utf8))
        #expect(s.consecutiveFailures == 2 && s.heldDeletions == 3)
        #expect(s.verifyOwed.isEmpty && !s.wholeSetOwed && !s.hashWholeSet && s.stoppedBy == nil)
    }

    @Test func uploadLimitResumesLikeAPartialRun() {
        let line = #"{"level":"error","msg":"Failed to copy: googleapi: Error 403: User rate limit exceeded., userRateLimitExceeded","object":"a.bin"}"#
        #expect(RcloneLogParser.outcome(exitCode: 7, log: Data(line.utf8)) == .partial)
        let named = #"{"level":"error","msg":"Failed to copy: permission denied","object":"User rate limit exceeded.txt"}"#
        #expect(RcloneLogParser.outcome(exitCode: 7, log: Data(named.utf8)) == .permanent)
    }

    @Test func parserFindsPlannedCopiesAndFlaggedPaths() throws {
        let dry = #"{"level":"notice","msg":"Skipped copy as --dry-run is set (size 18)","skipped":"copy","object":"a.txt"}"#
        #expect(RcloneLogParser.parse(Data(dry.utf8)).planned == ["a.txt"])
        let check = #"{"level":"error","msg":"sizes differ","object":"b.txt"}"#
        #expect(RcloneLogParser.parse(Data(check.utf8)).flagged == ["b.txt"])
    }
}

private struct Mute: Notifying {
    func post(_: Problem, pair: PairID, setName: String, detail: String) async -> Bool { false }
}
