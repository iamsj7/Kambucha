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

    var syncs: [SyncRequest] { lock.withLock { _syncs } }
    var realSyncs: [SyncRequest] { syncs.filter { !$0.dryRun } }
    var dryRuns: [SyncRequest] { syncs.filter(\.dryRun) }
    var checks: [CheckRequest] { lock.withLock { _checks } }
    var allCalls: Int { syncs.count + checks.count }

    /// One outcome per real sync; `.success` once used up.
    func script(real: [RcloneResult.Outcome] = [], dryDeletions: [String] = [], copied: [String] = [],
                differences: Int = 0, matching: Int = 0, checkOutcome: RcloneResult.Outcome = .success,
                dryOutcome: RcloneResult.Outcome = .success, killRealSync: Bool = false) {
        lock.withLock {
            _real = real; _dryDeletions = dryDeletions; _copied = copied; _differences = differences
            _matching = matching; _checkOutcome = checkOutcome; _dryOutcome = dryOutcome; _throwOnRealSync = killRealSync
        }
    }

    func sync(_ r: SyncRequest) async throws -> RcloneResult {
        try lock.withLock {
            _syncs.append(r)
            var s = LogSummary()
            if r.dryRun {
                s.deleted = _dryDeletions
                return RcloneResult(exitCode: 0, summary: s, outcome: _dryOutcome)
            }
            if _throwOnRealSync { throw CancellationError() }
            s.copied = _copied
            let outcome = _real.isEmpty ? .success : _real.removeFirst()
            if outcome != .success { s.errors = ["boom"] }
            return RcloneResult(exitCode: outcome == .success ? 0 : 1, summary: s, outcome: outcome)
        }
    }

    func check(_ r: CheckRequest) async throws -> RcloneResult {
        lock.withLock {
            _checks.append(r)
            var s = LogSummary()
            s.differences = _differences; s.matching = _matching
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

private final class RecordingNotifier: Notifying, @unchecked Sendable {
    private let lock = NSLock()
    private var _posts: [(Problem, PairID)] = []
    var posted: [Problem] { lock.withLock { _posts.map(\.0) } }
    func post(_ p: Problem, pair: PairID, setName: String, detail: String) async -> Bool {
        lock.withLock { _posts.append((p, pair)) }
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
    var calls: Int { lock.withLock { _calls } }
    var paths: [String] { lock.withLock { Array(_files.keys) } }
    func put(_ data: Data, at path: String) { lock.withLock { _files[path] = data } }
    func data(at path: String) -> Data? { lock.withLock { _files[path] } }
    func listing(_ path: String, _ entries: [String]) { lock.withLock { _listings[path] = entries } }
    func read(_ path: String, context: RcloneContext) async throws -> Data? {
        lock.withLock { _calls += 1; return _files[path] }
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
    private let lock = NSLock()
    private var _sessions: [UUID: FakeSession] = [:]
    var now = Date(timeIntervalSince1970: 2_000_000_000)
    var set: BackupSet
    var iCloudDest = Destination(name: "iCloud", kind: .iCloudFolder)
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

    func coordinator(presets: [Preset] = []) -> RunCoordinator {
        let clock: @Sendable () -> Date = { [self] in now }
        return RunCoordinator(
            store: store, records: records, problems: problems, rclone: rclone, feed: feed,
            verifier: Verifier(rclone: rclone, auditor: auditor, isDataless: { _ in false }),
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
            remote: files, paths: RunPaths(support: support, logs: logs, work: work))
    }

    func run(_ c: RunCommand = RunCommand(), presets: [Preset] = []) async { await coordinator(presets: presets).runAll(command: c) }

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
        #expect(h.rclone.realSyncs.last?.mode == .mirror(maxDelete: 510))
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
        h.rclone.script(differences: 1)
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

private struct Mute: Notifying {
    func post(_: Problem, pair: PairID, setName: String, detail: String) async -> Bool { false }
}
