import Testing
import Foundation
@testable import MirrorCore

private let hour: TimeInterval = 3600

/// For a second set saved straight to the store, which `Harness.save` doesn't see.
private func accepted(_ set: BackupSet) -> BackupSet {
    var s = set
    s.acceptPreview()
    return s
}

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
    private var _captures: [[String]] = [], _archiveStamps: [String] = [], _captureFailure: RcloneCapture?
    var captures: [[String]] { lock.withLock { _captures } }
    var purged: [String] { captures.filter { $0.first == "purge" }.compactMap { $0.dropFirst().first } }
    func archive(stamps: [String]) { lock.withLock { _archiveStamps = stamps } }
    func failCaptures(_ c: RcloneCapture?) { lock.withLock { _captureFailure = c } }
    func capture(_ arguments: [String], context: RcloneContext) async throws -> RcloneCapture {
        if arguments.first == "purge" { onPurge?() }
        return lock.withLock {
            _captures.append(arguments)
            if let _captureFailure { return _captureFailure }
            return RcloneCapture(exitCode: 0, stdout: arguments.first == "lsf" ? _archiveStamps.joined(separator: "\n") : "", stderr: "")
        }
    }
    private var _dryBytes: Int64 = 0
    func dry(bytes: Int64) { lock.withLock { _dryBytes = bytes } }
    var onPurge: (@Sendable () -> Void)?
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
                s.plannedBytes = _dryBytes
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

private final class FakeVolumes: VolumeLocating, @unchecked Sendable {
    private let lock = NSLock()
    private var _list: [VolumeInfo] = []
    private var _reads = 0
    private var _goneAfter: Int?
    var reads: Int { lock.withLock { _reads } }
    func set(_ list: [VolumeInfo]) { lock.withLock { _list = list } }
    /// The drive leaves once this many looks have been answered.
    func gone(after reads: Int) { lock.withLock { _goneAfter = reads; _reads = 0 } }
    func mounted() -> [VolumeInfo] {
        lock.withLock {
            _reads += 1
            if let _goneAfter, _reads > _goneAfter { return [] }
            return _list
        }
    }
}

private final class FakeDownloader: ICloudDownloading, @unchecked Sendable {
    private let lock = NSLock()
    private var _requested: [URL] = []
    private var _queues: [String] = []
    private var _error: (any Error)?
    private var _space: (free: Int64, capacity: Int64)? = (100_000_000_000, 500_000_000_000)
    private var _gate: DispatchSemaphore?
    private var _returned = 0
    var requested: [URL] { lock.withLock { _requested } }
    /// Which dispatch queue each request ran on.
    var queues: [String] { lock.withLock { _queues } }
    var returned: Int { lock.withLock { _returned } }
    func fail(_ e: (any Error)?) { lock.withLock { _error = e } }
    func set(space: (free: Int64, capacity: Int64)?) { lock.withLock { _space = space } }
    /// Requests hang until `release`, or 30 seconds.
    func stall() { lock.withLock { _gate = DispatchSemaphore(value: 0) } }
    func release() { lock.withLock { _gate }?.signal() }
    func space(at: URL) -> (free: Int64, capacity: Int64)? { lock.withLock { _space } }
    func requestDownload(of url: URL) throws {
        let queue = String(cString: __dispatch_queue_get_label(nil))
        let gate = lock.withLock {
            _requested.append(url); _queues.append(queue)
            return _gate
        }
        _ = gate?.wait(timeout: .now() + 30)
        try lock.withLock {
            _returned += 1
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
    private var _ejects: [String] = []
    var ejects: [String] { lock.withLock { _ejects } }
    func postSafeToEject(volumeName: String, volumeUUID: String) async -> Bool {
        lock.withLock { _ejects.append(volumeUUID) }
        return true
    }
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
    let volumes = FakeVolumes()
    var mountWakeWindow: TimeInterval = 0
    var lowPower = false
    private var _priorities: [Bool] = []
    var priorities: [Bool] { lock.withLock { _priorities } }
    private var _helperChecks = 0
    var helperChecks: Int { lock.withLock { _helperChecks } }
    private var _written: [TransferProgress] = []
    var written: [TransferProgress] { lock.withLock { _written } }
    private(set) lazy var progress = RunProgress(store: ProgressStore(root: support), clock: { [self] in now },
                                                 observer: { [self] p in lock.withLock { _written.append(p) } })
    private var _evicted: [String] = []
    var evicted: [String] { lock.withLock { _evicted } }
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

    /// Accepted, as nearly every test wants a set that may run.
    func save(extra: [Destination] = [], accepted: Bool = true) throws {
        set.acceptedFingerprint = accepted ? set.previewFingerprint : nil
        try store.saveSets([set])
        try store.saveDestinations([iCloudDest] + extra)
    }

    func coordinator(presets: [Preset] = [], rclone wrapped: (any RcloneRunning)? = nil, requestGrace: TimeInterval = 30) -> RunCoordinator {
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
            helperCheck: { [self] in
                lock.withLock { _helperChecks += 1 }
                if let helperError { throw helperError }
            },
            archives: { [self] endpoint, context, kind in
                ArchiveManager(rclone: runner, endpoint: endpoint, context: context, kind: kind, isUploaded: { _ in true },
                               evict: { [self] url in lock.withLock { _evicted.append(url.lastPathComponent) } })
            },
            progress: progress, volumes: volumes, mountWakeWindow: mountWakeWindow,
            priority: { [self] fast in lock.withLock { _priorities.append(fast) } },
            lowPower: { [self] in lowPower }, downloader: downloader, requestGrace: requestGrace)
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

    /// A drive mounted at a real temp folder, with plenty of room, and this set using only it.
    @discardableResult
    func useDrive(uuid: String = "DRIVE-1", fileSystem: String = "apfs", free: Int64 = 1 << 50, mountID: String = "m1",
                  looksInternal: Bool = false, confirmed: Bool = false) throws -> (Destination, VolumeInfo) {
        let mount = root.appendingPathComponent("Volumes/\(uuid)")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        let v = VolumeInfo(uuid: uuid, name: "SSD", mountPoint: mount, fileSystem: fileSystem, freeBytes: free, totalBytes: 1 << 40,
                           mountID: mountID, looksInternal: looksInternal)
        let d = Destination(name: "SSD", kind: .externalDrive, volumeUUID: uuid, internalDiskConfirmed: confirmed)
        set.destinationIDs = [d.id]
        try save(extra: [d])
        volumes.set([v])
        return (d, v)
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
        await h.run(RunCommand(setID: h.set.id, approvedDeletions: 1000, approvedDestination: h.iCloudDest.id, force: true))
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
        try h.store.saveSets([h.set, accepted(other)])
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
        await h.run(RunCommand(setID: h.set.id, approvedDeletions: 500, approvedDestination: h.iCloudDest.id, force: true))
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
        await h.run(RunCommand(setID: h.set.id, approvedDeletions: 499, approvedDestination: h.iCloudDest.id, force: true))
        #expect(h.rclone.realSyncs.last?.mode == .copyOnly)
        #expect(try h.state.heldDeletions == 500)
    }

    @Test func approvalDoesNothingForAPairThatIsNotHeld() async throws {
        let h = try Harness(); try h.prime()
        h.rclone.script(dryDeletions: manyDeletions())
        await h.run(RunCommand(setID: h.set.id, approvedDeletions: 500, approvedDestination: h.iCloudDest.id, force: true))
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
        try h.store.saveSets([h.set, accepted(second)]); try h.store.saveDestinations([google, drive])
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
        try h.store.saveSets([h.set, accepted(other)])
        await h.run(RunCommand(setID: h.set.id, force: true))
        #expect(h.rclone.realSyncs.map(\.destination) == [h.mirror])
        #expect(try h.latest()?.trigger == .manual)
    }

    @Test func fullSpeedReachesRcloneForManualRunsAndTheSetting() async throws {
        let h = try Harness(); try h.prime()
        await h.run(RunCommand(force: true))
        #expect(!h.rclone.syncs.isEmpty && h.rclone.syncs.allSatisfy { $0.fullSpeed })
        h.change("flowapp/a.txt")
        await h.run(RunCommand(fullSpeed: true))
        #expect(h.rclone.syncs.last?.fullSpeed == true)
        h.change("flowapp/a.txt", id: 11)
        await h.run()
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
        await h.run(RunCommand(setID: h.set.id, approvedDeletions: 2, approvedDestination: h.iCloudDest.id, force: true))
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
        try h.store.saveSets([h.set, accepted(second)]); try h.store.saveDestinations([d])
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
        for name in names {
            try Data().write(to: h.source.appendingPathComponent("flowapp/\(name)"))
            s.verifyOwed.append("flowapp/\(name)")
            s.mismatched["flowapp/\(name)"] = Mismatch(since: h.now, evicted: true)
        }
        s.verifyOwed.sort()
        try h.store.save(s, for: h.pair)
        h.freed = Set(names)
    }

    @Test func owedEvictedMismatchesAreRequestedAtTheirMirrorPath() async throws {
        let h = try Harness(); try owedFreed(h)
        await h.run()
        #expect(h.downloader.requested.map(\.path) == [h.mirror + "/flowapp/a.txt"])
    }

    @Test func onlyMismatchesAreEverRequested() async throws {
        let h = try Harness(); try h.prime()
        let m = h.backupRoot.appendingPathComponent("Sets/x/flowapp")
        try FileManager.default.createDirectory(at: m, withIntermediateDirectories: true)
        try Data().write(to: m.appendingPathComponent("other.txt"))
        try Data().write(to: m.appendingPathComponent("owed.txt"))
        try Data().write(to: h.source.appendingPathComponent("flowapp/owed.txt"))
        var s = try h.state
        s.lastFullPass = h.now.addingTimeInterval(-25 * hour); s.verifyOwed = ["flowapp/owed.txt"]
        try h.store.save(s, for: h.pair)
        h.freed = ["other.txt", "owed.txt"]   // evicted, and no mismatch recorded on either
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
        #expect(try h.state.mismatched.keys.sorted() == ["flowapp/a.txt"])
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
        #expect(try h.latest()?.verification == StatusSummary.recheckText(count: 2))
    }
}

/// Fix round 4: what the owner sees, from the records, problems and state real runs leave behind.
@Suite struct WaitingStatusTests {
    private func status(_ h: Harness) throws -> OverallStatus {
        StatusSummary.overall(sets: [h.set], destinations: [h.iCloudDest], states: [h.pair: try h.state],
                              records: try h.records.recent(limit: 50), problems: try h.problems.active(), running: false)
    }

    /// A real mismatch, then iCloud evicts the file, then a clean run of other work.
    private func evictedAfterAMismatch(_ h: Harness) async throws {
        try h.prime(); h.change("flowapp/a.txt")
        h.rclone.script(copied: ["a.txt"], hashDifferences: 1, differing: ["a.txt"])
        await h.run()
        #expect(try status(h) == .attention(Problem.verificationFailed.headline))
        h.rclone.script()
        h.freed = ["a.txt"]
        h.now = h.now.addingTimeInterval(hour)   // records order by time
        await h.run()
        #expect(try h.latest()?.status == .partial)
        #expect(try h.latest()?.pendingUploads == 0)
    }

    @Test func aRealRunWaitingOnICloudReachesTheOwner() async throws {
        let h = try Harness(); try await evictedAfterAMismatch(h)
        #expect(try status(h) == .waitingForDownload(1))
        #expect(try h.active == [.verificationFailed])   // told at once, and still open until the hash
        #expect(try h.latest()?.verification == "Re-checking 1 file that didn't match, waiting for iCloud to download it")
    }

    @Test func thePassingHashEndsTheWait() async throws {
        let h = try Harness(); try await evictedAfterAMismatch(h)
        h.freed = []
        h.now = h.now.addingTimeInterval(hour)
        await h.run()
        guard case .backedUp = try status(h) else { Issue.record("expected Backed Up"); return }
    }

    @Test func sevenDaysOfWaitingTurnsToAttention() async throws {
        let h = try Harness(); try await evictedAfterAMismatch(h)
        h.now = h.now.addingTimeInterval(7 * 24 * hour)
        await h.run()
        #expect(try status(h) == .attention(Problem.verificationFailed.headline))
    }

    @Test func aRunStoppedByTheTimeLimitIsUnfinishedOnceTheAgentHasGone() async throws {
        let h = try Harness(); try h.prime(); h.change("flowapp/a.txt")
        h.rclone.script(real: [.partial])
        await h.run()
        #expect(try h.latest()?.status == .partial)
        #expect(try status(h) == .unfinished)
    }

    private func refused(_ h: Harness) async throws {
        try h.prime(); h.change("flowapp/a.txt")
        h.rclone.script(copied: ["a.txt"])
        h.auditor.set(refused: ["a.txt"])
        await h.run()
        #expect(try h.latest()?.status == .partial)
    }

    @Test func aRefusedFileWaitingOnItsAlertIsCounted() async throws {
        let h = try Harness(); try await refused(h)
        #expect(try status(h) == .notAccepted(1))
        #expect(StatusSummary.notAcceptedText(count: 1) == "1 file iCloud hasn't accepted yet")
    }

    @Test func aRefusedFileTurnsToAttentionAfterADay() async throws {
        let h = try Harness(); try await refused(h)
        h.now = h.now.addingTimeInterval(25 * hour)
        await h.run()
        #expect(try status(h) == .attention(Problem.fileRefused.headline))
    }

    @Test func aFileICloudAcceptsAfterAllEndsTheCount() async throws {
        let h = try Harness(); try await refused(h)
        h.auditor.set()
        h.now = h.now.addingTimeInterval(hour)   // records order by time
        await h.run()   // a skipped run, so the partial record stands
        #expect(try h.latest()?.status == .skipped)
        guard case .backedUp = try status(h) else { Issue.record("expected Backed Up"); return }
    }
}

/// Fix round 4: downloads are for recorded mismatches, and never at the cost of the disk or the wake-up.
@Suite struct DownloadLimitTests {
    private func waiting(_ h: Harness, _ names: [String] = ["a.txt"], since: Date? = nil) throws {
        try h.prime()
        var s = try h.state
        for name in names {
            try Data().write(to: h.source.appendingPathComponent("flowapp/\(name)"))
            s.verifyOwed.append("flowapp/\(name)")
            s.mismatched["flowapp/\(name)"] = Mismatch(since: since ?? h.now, evicted: true)
        }
        s.verifyOwed.sort()
        try h.store.save(s, for: h.pair)
        h.freed = Set(names)
    }

    private func names(_ count: Int) -> [String] { (0..<count).map { String(format: "f%04d", $0) } }

    @Test func aRunRequestsNoMoreThanTheLimit() async throws {
        #expect(RunCoordinator.maxDownloadsPerRun == 50)
        let h = try Harness(); try waiting(h, names(RunCoordinator.maxDownloadsPerRun + 1))
        await h.run()
        #expect(h.downloader.requested.count == RunCoordinator.maxDownloadsPerRun)
    }

    @Test func requestsRotateSoEveryFileGetsItsTurn() async throws {
        let h = try Harness(); let all = names(RunCoordinator.maxDownloadsPerRun * 2 + 10)
        try waiting(h, all)
        for _ in 0..<3 { await h.run() }
        let asked = h.downloader.requested.map(\.lastPathComponent)
        #expect(Set(asked) == Set(all))
        #expect(asked.count == RunCoordinator.maxDownloadsPerRun * 3)
        await h.run()   // wrapped round
        #expect(Set(h.downloader.requested.suffix(RunCoordinator.maxDownloadsPerRun).map(\.lastPathComponent)).isDisjoint(with: Set(asked.suffix(10))))
    }

    @Test func aFileThatLeavesTheListCantLoseTheOthersTheirTurn() async throws {
        let h = try Harness(); let all = names(RunCoordinator.maxDownloadsPerRun + 5)
        try waiting(h, all)
        await h.run()
        var s = try h.state; s.mismatched[try #require(s.downloadCursor)] = nil; try h.store.save(s, for: h.pair)
        await h.run()
        #expect(h.downloader.requested.suffix(RunCoordinator.maxDownloadsPerRun).first?.lastPathComponent == all[RunCoordinator.maxDownloadsPerRun])
    }

    @Test func theFreeSpaceBoundIsTheLargerOfFiveGBAndFivePercent() {
        let gb: Int64 = 1_000_000_000
        #expect(RunCoordinator.hasRoomForDownloads(free: 5 * gb, capacity: 50 * gb))
        #expect(!RunCoordinator.hasRoomForDownloads(free: 5 * gb - 1, capacity: 50 * gb))
        #expect(RunCoordinator.hasRoomForDownloads(free: 50 * gb, capacity: 1_000 * gb))
        #expect(!RunCoordinator.hasRoomForDownloads(free: 50 * gb - 1, capacity: 1_000 * gb))
    }

    @Test func aFullDiskGetsNoRequestsAndStaysOwed() async throws {
        let h = try Harness(); try waiting(h)
        h.downloader.set(space: (4_000_000_000, 500_000_000_000))
        await h.run()
        #expect(h.downloader.requested.isEmpty)
        #expect(try h.state.verifyOwed == ["flowapp/a.txt"])
    }

    @Test func aVolumeThatCantBeReadGetsNoRequests() async throws {
        let h = try Harness(); try waiting(h)
        h.downloader.set(space: nil)
        await h.run()
        #expect(h.downloader.requested.isEmpty)
    }

    @Test func aFileDeletedFromTheSourceIsNotRequestedAndClearsOnTheNextFullPass() async throws {
        let h = try Harness(); try waiting(h)
        try FileManager.default.removeItem(at: h.source.appendingPathComponent("flowapp/a.txt"))
        await h.run()
        #expect(h.downloader.requested.isEmpty)
        #expect(try h.state.mismatched.keys.sorted() == ["flowapp/a.txt"])
        var s = try h.state; s.lastFullPass = h.now.addingTimeInterval(-25 * hour); try h.store.save(s, for: h.pair)
        await h.run()
        #expect(try h.state.mismatched.isEmpty)
        #expect(try h.state.verifyOwed.isEmpty)
    }

    @Test func requestsLeaveTheCooperativePool() async throws {
        let h = try Harness(); try waiting(h)
        await h.run()
        #expect(h.downloader.queues.count == 1)
        #expect(h.downloader.queues.allSatisfy { !$0.contains("cooperative") })
    }

    /// The fake is still inside the call when the run returns, so nothing waited for it.
    private func expectNotHeldUp(_ h: Harness) async throws {
        h.downloader.stall()
        defer { h.downloader.release() }
        await h.coordinator(requestGrace: 0.05).runAll(command: RunCommand())
        #expect(h.rclone.realSyncs.count == 1)
        #expect(h.downloader.returned == 0)
    }

    @Test func aStalledRequestDoesNotHoldUpTheWakeUp() async throws {
        let h = try Harness(); try waiting(h); h.change("other/b.txt")
        try await expectNotHeldUp(h)
    }

    @Test func aDatalessMarkerIsRequestedWithoutHoldingUpTheWakeUp() async throws {
        let h = try Harness(); try h.prime(); h.change("flowapp/a.txt")
        h.freed = [RootMarker.fileName]
        try await expectNotHeldUp(h)
        #expect(h.downloader.requested.map(\.lastPathComponent) == [RootMarker.fileName])
    }

    @Test func aDatalessMarkerIsNotHeldBackByALowDisk() async throws {
        let h = try Harness(); try h.prime()
        h.freed = [RootMarker.fileName]
        h.downloader.set(space: (1, 500_000_000_000))
        await h.run()
        #expect(h.downloader.requested.map(\.lastPathComponent) == [RootMarker.fileName])
    }

    private let stuck = "flowapp/a.txt couldn't be verified for 7 days"

    @Test func aFileWaitingSevenDaysAlertsOnceWithItsOwnDetail() async throws {
        let h = try Harness(); try waiting(h, since: h.now.addingTimeInterval(-7 * 24 * hour - 1))
        try h.problems.store(.verificationFailed, pair: h.pair, setName: "x", detail: "1 differences found")
        await h.run()
        await h.run()
        h.now = h.now.addingTimeInterval(hour)
        await h.run()
        #expect(try h.problems.active().map(\.detail) == [stuck])
        #expect(h.notifier.details.filter { $0 == stuck }.count == 1)
        #expect(try h.state.mismatched["flowapp/a.txt"]?.alerted == true)
    }

    @Test func aFileWaitingLessThanSevenDaysDoesNotAlert() async throws {
        let h = try Harness(); try waiting(h, since: h.now.addingTimeInterval(-7 * 24 * hour + 60))
        await h.run()
        #expect(try h.active.isEmpty)
        #expect(try h.state.mismatched["flowapp/a.txt"]?.alerted == false)
    }

    @Test func severalLateFilesShareOneAlert() async throws {
        let h = try Harness(); try waiting(h, ["a.txt", "b.txt"], since: h.now.addingTimeInterval(-8 * 24 * hour))
        await h.run()
        #expect(try h.problems.active().map(\.detail) == ["2 files couldn't be verified for 7 days"])
    }

    @Test func aFileGoneFromTheSourceDoesNotAlert() async throws {
        let h = try Harness(); try waiting(h, since: h.now.addingTimeInterval(-8 * 24 * hour))
        try FileManager.default.removeItem(at: h.source.appendingPathComponent("flowapp/a.txt"))
        await h.run()
        #expect(try h.active.isEmpty)
    }

    @Test func anAlertedFileStillClearsOnlyOnItsHash() async throws {
        let h = try Harness(); try waiting(h, since: h.now.addingTimeInterval(-8 * 24 * hour))
        await h.run()
        #expect(try h.active == [.verificationFailed])
        h.freed = []
        await h.run()
        #expect(h.rclone.hashed.last == ["a.txt"])
        #expect(try h.state.mismatched.isEmpty)
        #expect(try h.active.isEmpty)
    }

    @Test func aHashThatFinishesTheFileInTheSameRunRaisesNoLateAlert() async throws {
        let h = try Harness(); try waiting(h, since: h.now.addingTimeInterval(-8 * 24 * hour))
        h.freed = []
        await h.run()
        #expect(try h.state.mismatched.isEmpty)
        #expect(try h.active.isEmpty)
    }
}

/// Fix round 4: iCloud only frees what it has uploaded, so a freed file with no recorded mismatch
/// needs its size check and nothing else.
@Suite struct PlainFreedFileTests {
    private func owed(_ h: Harness, _ name: String = "a.txt") throws {
        try h.prime()
        var s = try h.state; s.verifyOwed = ["flowapp/\(name)"]; try h.store.save(s, for: h.pair)
        h.freed = [name]
    }

    @Test func itClearsOnItsSizeCheckWithNoHashOrDownload() async throws {
        let h = try Harness(); try owed(h)
        await h.run()
        #expect(h.rclone.checks.contains { $0.logFile.lastPathComponent == "quick-size.log" })
        #expect(h.rclone.hashed.isEmpty)
        #expect(h.downloader.requested.isEmpty)
        #expect(try h.state.verifyOwed.isEmpty)
        #expect(try h.state.isBackedUp)
        #expect(try h.latest()?.status == .success)
    }

    @Test func aFailedSizeCheckClearsNothing() async throws {
        let h = try Harness(); try owed(h)
        h.rclone.script(differences: 1, differing: ["a.txt"])
        await h.run()
        #expect(try h.state.verifyOwed == ["flowapp/a.txt"])
        #expect(try h.state.mismatched.keys.sorted() == ["flowapp/a.txt"])
    }

    @Test func aRoutineDeepCheckOwesNothingForEvictedFiles() async throws {
        let h = try Harness(); try h.prime()
        let names = try mirror(h, count: RunCoordinator.freedSample + 5)
        h.freed = Set(names)
        var s = try h.state
        s.lastFullPass = h.now.addingTimeInterval(-25 * hour); s.lastDeepCheck = h.now.addingTimeInterval(-31 * 24 * hour)
        try h.store.save(s, for: h.pair)
        await h.run()
        #expect(try h.state.verifyOwed.isEmpty)
        #expect(h.downloader.requested.isEmpty)
    }

    /// The flag speaks for files on disk. Evicted ones it can't reach were uploaded, so none become owed.
    @Test func aFlagDrivenDeepCheckHashesPresentFilesAndOwesNothingForEvictedOnes() async throws {
        let h = try Harness(); try h.prime()
        let names = try mirror(h, count: RunCoordinator.freedSample + 5)
        try Data().write(to: h.backupRoot.appendingPathComponent("Sets/x/flowapp/present.txt"))
        h.freed = Set(names)
        var s = try h.state; s.hashWholeSet = true; try h.store.save(s, for: h.pair)
        await h.run()
        let after = try h.state
        #expect(h.rclone.hashed.last?.contains("flowapp/present.txt") == true)
        #expect(h.rclone.hashed.last?.count == RunCoordinator.freedSample + 1)
        #expect(after.hashWholeSet == false)
        #expect(after.verifyOwed.isEmpty)
        #expect(h.downloader.requested.isEmpty)
    }

    private func mirror(_ h: Harness, count: Int) throws -> [String] {
        let m = h.backupRoot.appendingPathComponent("Sets/x/flowapp")
        try FileManager.default.createDirectory(at: m, withIntermediateDirectories: true)
        let names = (0..<count).map { "e\($0).txt" }
        for name in names {
            try Data().write(to: m.appendingPathComponent(name))
            try Data().write(to: h.source.appendingPathComponent("flowapp/\(name)"))
        }
        return names
    }
}

/// Fix round 3: past the bound the flag takes over, and nothing but a whole-set check ends it.
@Suite struct OverflowTests {
    private func many() -> [String] { (0...RunCoordinator.maxOwed).map { "f\($0)" } }

    private func withFreedOwed(_ h: Harness) throws {
        try h.prime()
        try Data().write(to: h.source.appendingPathComponent("flowapp/old.txt"))
        var s = try h.state
        s.verifyOwed = ["flowapp/old.txt"]; s.mismatched = ["flowapp/old.txt": Mismatch(since: h.now, evicted: true)]
        try h.store.save(s, for: h.pair)
        h.freed = ["old.txt"]
    }

    @Test func aScopedOverflowKeepsMismatchesAndIsNotSuccess() async throws {
        let h = try Harness(); try withFreedOwed(h); h.change("flowapp/a.txt")
        h.rclone.script(copied: many(), planned: many())
        await h.run()
        let s = try h.state
        #expect(s.hashWholeSet)
        #expect(s.verifyOwed == ["flowapp/old.txt"])
        #expect(s.mismatched.keys.sorted() == ["flowapp/old.txt"])
        #expect(s.isBackedUp == false)
        #expect(try h.latest()?.status == .partial)
    }

    /// A run that reaches `prove` puts them back by itself, which hides a wipe. One that stops first can't.
    @Test func anOverflowThenAFailedSyncStillKeepsMismatches() async throws {
        let h = try Harness(); try withFreedOwed(h); h.change("flowapp/a.txt")
        h.rclone.script(real: [.permanent], planned: many())
        await h.run()
        let s = try h.state
        #expect(s.hashWholeSet)
        #expect(s.verifyOwed == ["flowapp/old.txt"])
        #expect(s.mismatched.keys.sorted() == ["flowapp/old.txt"])
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

    @Test func theNextRunsDeepCheckEndsTheFlagAndKeepsMismatches() async throws {
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
        s.hashWholeSet = true; s.verifyOwed = ["flowapp/a.txt"]; s.mismatched = ["flowapp/a.txt": Mismatch(since: h.now)]
        try h.store.save(s, for: h.pair)
        // Quick passes, then Deep can't even start: the mirror folder is missing.
        await h.run()
        #expect(try h.state.verifyOwed == ["flowapp/a.txt"])
        #expect(try h.state.mismatched.keys.sorted() == ["flowapp/a.txt"])
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
        var s = try h.state; s.verifyOwed = ["flowapp/a.txt"]; s.mismatched = ["flowapp/a.txt": Mismatch(since: h.now)]; try h.store.save(s, for: h.pair)
        await h.run()   // a.txt isn't in the mirror, so the deep check's list can't have held it
        #expect(try h.state.verifyOwed == ["flowapp/a.txt"])
        #expect(try h.state.mismatched.keys.sorted() == ["flowapp/a.txt"])
    }

    @Test func aFileOnDiskTheDeepCheckDidNotHashStaysOwed() async throws {
        let h = try Harness(); try flagged(h)
        var s = try h.state; s.verifyOwed = ["flowapp/a.txt"]; try h.store.save(s, for: h.pair)
        await h.run()   // a.txt isn't in the mirror, so the deep check's list can't have held it
        #expect(try h.state.verifyOwed == ["flowapp/a.txt"])
    }

    /// An overflow says nothing about a mismatch, so none is lost to one, in any order.
    @Test func aMismatchThatTipsTheListOverIsKeptAndOwed() async throws {
        let h = try Harness(); try h.prime(); h.change("flowapp/a.txt")
        try Data().write(to: h.source.appendingPathComponent("flowapp/b.txt"))
        var s = try h.state; s.verifyOwed = (0..<RunCoordinator.maxOwed).map { "flowapp/f\($0)" }; try h.store.save(s, for: h.pair)
        h.rclone.script(differences: 1, differing: ["b.txt"])
        await h.run()
        s = try h.state
        #expect(s.hashWholeSet)
        #expect(s.mismatched.keys.sorted() == ["flowapp/b.txt"])
        #expect(s.verifyOwed == ["flowapp/b.txt"])
    }

    @Test func aMismatchNoLongerOnTheOwedListIsStillHashedBeforeItClears() async throws {
        let h = try Harness(); try h.prime(); h.change("flowapp/a.txt")
        var s = try h.state; s.mismatched = ["flowapp/a.txt": Mismatch(since: h.now)]; try h.store.save(s, for: h.pair)
        await h.run()
        #expect(h.rclone.hashed.last == ["a.txt"])
        #expect(try h.state.mismatched.isEmpty)
    }
}

/// Fix round 4: a run with a deep check to come has no Quick hash, so the deep list is all a link has.
@Suite struct LinksOnADeepRunTests {
    private func touched(_ h: Harness, inMirror: Bool) throws {
        try h.prime()
        var s = try h.state; s.hashWholeSet = true; try h.store.save(s, for: h.pair)
        let m = h.backupRoot.appendingPathComponent("Sets/x/flowapp")
        try FileManager.default.createDirectory(at: m, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: h.source.appendingPathComponent("flowapp/link").path, withDestinationPath: "a.txt")
        try Data().write(to: m.appendingPathComponent("a.txt"))   // so the deep list is never empty
        if inMirror { try FileManager.default.createSymbolicLink(atPath: m.appendingPathComponent("link").path, withDestinationPath: "a.txt") }
        h.rclone.script(copied: ["flowapp/link.rclonelink"])
    }

    @Test func aTouchedLinkClearsOnTheDeepHashOfItsRcloneName() async throws {
        let h = try Harness(); try touched(h, inMirror: true)
        await h.run()
        #expect(h.rclone.hashed.last?.contains("flowapp/link.rclonelink") == true)
        #expect(h.rclone.checks.contains { $0.logFile.lastPathComponent == "quick-size.log" })
        #expect(try h.state.verifyOwed.isEmpty)
    }

    @Test func aTouchedLinkNoHashReachedStaysOwed() async throws {
        let h = try Harness(); try touched(h, inMirror: false)
        await h.run()
        #expect(try h.state.verifyOwed == ["flowapp/link.rclonelink"])
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
        #expect(try h.state.mismatched.keys.sorted() == ["flowapp/a.txt"])
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
        #expect(try h.state.verifyOwed.isEmpty)
        #expect(try h.active.isEmpty)
    }

    private func full(_ h: Harness) throws {
        try h.prime(); h.change("flowapp/a.txt")
        var s = try h.state
        for i in 0..<RunCoordinator.maxMismatched {
            s.mismatched["flowapp/k\(i)"] = Mismatch(since: h.now)
            s.verifyOwed.append("flowapp/k\(i)")
        }
        try h.store.save(s, for: h.pair)
        try h.problems.store(.verificationFailed, pair: h.pair, setName: "x", detail: "earlier")
    }

    @Test func pastTheBoundTheOwnerIsToldAndTheFlagCoversTheRest() async throws {
        let h = try Harness(); try full(h)
        h.rclone.script(copied: ["a.txt"], hashDifferences: 1, differing: ["a.txt"])
        await h.run()
        let s = try h.state
        #expect(s.mismatched.count == RunCoordinator.maxMismatched)
        #expect(s.mismatched["flowapp/a.txt"] == nil)
        #expect(s.hashWholeSet)
        let news = "More than 1,000 files differ, so not all of them are listed"
        #expect(try h.problems.active().first?.detail == news)
        #expect(h.notifier.details.filter { $0 == news }.count == 1)
    }

    /// What fell past the bound is known only to the flag, so an empty list isn't an all-clear.
    @Test func theAlertOutlastsTheListWhileTheFlagIsUp() async throws {
        let h = try Harness(); try h.prime(); h.change("flowapp/a.txt")
        try h.problems.store(.verificationFailed, pair: h.pair, setName: "x", detail: "earlier")
        let many = (0...RunCoordinator.maxOwed).map { "f\($0)" }
        h.rclone.script(copied: many, planned: many)
        await h.run()
        #expect(try h.state.mismatched.isEmpty)
        #expect(try h.state.hashWholeSet)
        #expect(try h.active.contains(.verificationFailed))
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

    @Test func anEvictedMismatchIsNotClearedUnhashed() async throws {
        let h = try Harness(); try await mismatched(h)
        h.rclone.script()
        h.freed = ["a.txt"]
        await h.run()
        #expect(h.rclone.hashed.count == 1)   // only the first run's: nothing was hashed this time
        #expect(try h.state.verifyOwed == ["flowapp/a.txt"])
        #expect(try h.state.mismatched["flowapp/a.txt"]?.evicted == true)
        #expect(try h.state.isBackedUp == false)
        #expect(try h.active == [.verificationFailed])   // unhashed proves nothing, so the alert stands
    }

    @Test func anEvictedMismatchDoesNotForceAnRcloneRunEveryWakeUp() async throws {
        let h = try Harness(); try await mismatched(h)
        h.rclone.script(); h.freed = ["a.txt"]
        await h.run()
        let calls = h.rclone.allCalls
        await h.run()
        #expect(h.rclone.allCalls == calls)
        #expect(try h.state.verifyOwed == ["flowapp/a.txt"])
    }

    @Test func anEvictedMismatchIsHashedOnceItsBackOnDisk() async throws {
        let h = try Harness(); try await mismatched(h)
        h.rclone.script(); h.freed = ["a.txt"]
        await h.run()
        h.freed = []
        await h.run()
        #expect(h.rclone.hashed.last == ["a.txt"])
        #expect(try h.state.verifyOwed.isEmpty)
        #expect(try h.state.mismatched.isEmpty)
        #expect(try h.active.isEmpty)
    }

    private func deepDue(_ h: Harness, freed: [String], recorded: Bool = false) throws {
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
            if recorded { s.mismatched["flowapp/\(name)"] = Mismatch(since: h.now, evicted: true) }
        }
        s.verifyOwed.sort()
        try h.store.save(s, for: h.pair)
        h.freed = Set(freed)
    }

    /// The deep sample is a real hash, so a recorded mismatch it reaches and passes is done with.
    @Test func aSampledMismatchThatPassesItsHashClears() async throws {
        let h = try Harness(); try deepDue(h, freed: ["old.txt"], recorded: true)
        await h.run()
        #expect(h.rclone.hashed.last == ["flowapp/old.txt"])
        #expect(try h.state.verifyOwed.isEmpty)
        #expect(try h.state.mismatched.isEmpty)
    }

    @Test func aMismatchTheSampleMissedStaysOwed() async throws {
        let h = try Harness()
        let names = (0...RunCoordinator.freedSample).map { "e\($0).txt" }
        try deepDue(h, freed: names, recorded: true)
        await h.run()
        let s = try h.state
        #expect(s.mismatched.count == 1)
        #expect(s.verifyOwed == s.mismatched.keys.sorted())
    }

    @Test func aSampledFreedFileThatFailsIsReportedAndRecorded() async throws {
        let h = try Harness(); try deepDue(h, freed: ["old.txt"])
        h.rclone.script(hashDifferences: 1, differing: ["flowapp/old.txt"])
        await h.run()
        #expect(try h.state.verifyOwed == ["flowapp/old.txt"])
        #expect(try h.state.mismatched.keys.sorted() == ["flowapp/old.txt"])
        #expect(try h.state.reviewItems.isEmpty)
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
        try h.store.saveSets([h.set, accepted(other)])
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
        await h.run(RunCommand(setID: h.set.id, approvedDeletions: 500, approvedDestination: h.iCloudDest.id, force: true))
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

@Suite struct RunWiringArchiveTests {
    private static let old = "2020-01-01T10-00-00", recent = "2033-05-18T00-00-00"

    private func withArchive(_ h: Harness) {
        h.rclone.archive(stamps: [Self.old + "/", "2033-05-17T00-00-00/", Self.recent + "/"])
    }

    /// Stamps relative to the harness clock, 2033-05-18.
    private func expiredAndFresh(_ h: Harness) -> (String, [String]) {
        let old = ArchiveScope.stampString(h.now.addingTimeInterval(-40 * 86_400))
        return (old, [old + "/", ArchiveScope.stampString(h.now.addingTimeInterval(-86_400)) + "/"])
    }

    private func link(_ h: Harness, _ rel: String, to target: String) throws {
        let url = h.source.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: target)
    }

    private func manifest(_ h: Harness) throws -> [String] {
        try SymlinkManifest.read(set: "x", backupRoot: h.backupRoot).entries.map(\.path)
    }

    private func write(_ h: Harness, _ rel: String, _ text: String = "x") throws {
        let url = h.source.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    @Test func archiveStampsAreOnesTheArchiveCanRead() async throws {
        let h = try Harness(); try h.prime(); h.change("flowapp/a.txt", rescan: true)
        await h.run()
        let stamp = try #require(h.rclone.realSyncs.first?.backupDir.split(separator: "/").last.map(String.init))
        #expect(ArchiveScope.parseStamp(stamp) == h.now)
    }

    @Test func aSuccessfulRunPrunesAndRecordsIt() async throws {
        let h = try Harness(); try h.prime(); h.change("flowapp/a.txt")
        let (old, stamps) = expiredAndFresh(h)
        h.rclone.archive(stamps: stamps)
        await h.run()
        #expect(h.rclone.purged == [h.backupRoot.appendingPathComponent("Archive/x/\(old)").path])
        #expect(try h.latest()?.archivesPruned == 1)
        #expect(try h.latest()?.status == .success)
    }

    @Test func iCloudEvictsUploadedArchiveFilesAndNeverTheMirror() async throws {
        let h = try Harness(); try h.prime(); h.change("flowapp/a.txt")
        for rel in ["Archive/x/2033-05-01T00-00-00/gone.txt", "Sets/x/flowapp/a.txt"] {
            let url = h.backupRoot.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("a".utf8).write(to: url)
        }
        await h.run()
        #expect(h.evicted == ["gone.txt"])
    }

    @Test func aCloudRunPrunesThroughItsEndpointAndEvictsNothing() async throws {
        let h = try Harness()
        let cloud = try h.addCloud()
        h.set.destinationIDs = [cloud.id]
        try h.save(extra: [cloud])
        let pair = PairID(set: h.set.id, destination: cloud.id)
        try h.prime(pair, kind: .googleDrive)
        h.setSession(cloud, FakeSession(endpoint: "crypt:"))
        try h.cloudMarker(at: "crypt:.mirror-root")
        h.change("flowapp/a.txt")
        let (old, stamps) = expiredAndFresh(h)
        h.rclone.archive(stamps: stamps)
        await h.run()
        #expect(h.rclone.purged == ["crypt:Archive/x/\(old)"])
        #expect(h.rclone.captures.allSatisfy { $0.contains("/private/run.conf") })
        #expect(h.evicted.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: h.backupRoot.appendingPathComponent("Manifests").path))
    }

    @Test func nothingIsPrunedByARunThatDidNotFinish() async throws {
        let h = try Harness(); try h.prime(); h.change("flowapp/a.txt")
        withArchive(h)
        h.rclone.script(real: [.transient])
        await h.run()
        #expect(h.rclone.captures.isEmpty)
    }

    @Test func nothingIsPrunedByARunThatFailedItsChecks() async throws {
        let h = try Harness(); try h.prime(); h.change("flowapp/a.txt")
        withArchive(h)
        h.rclone.script(differences: 2)
        await h.run()
        #expect(h.rclone.captures.isEmpty)
    }

    @Test func nothingIsPrunedWhileDeletionsAreHeld() async throws {
        let h = try Harness(); try h.prime(); h.change("flowapp/a.txt", rescan: true)
        withArchive(h)
        h.rclone.script(dryDeletions: (0..<500).map { "d\($0)" })
        await h.run()
        #expect(try h.latest()?.status == .held)
        #expect(h.rclone.captures.isEmpty)
    }

    @Test func nothingIsPrunedWhenThereWasNoWork() async throws {
        let h = try Harness(); try h.prime()
        await h.run()
        #expect(h.rclone.captures.isEmpty)
    }

    @Test func aFailedPruneDoesNotUndoTheBackupAndItsTextStaysOut() async throws {
        let h = try Harness(); try h.prime(); h.change("flowapp/a.txt")
        h.rclone.failCaptures(RcloneCapture(exitCode: 1, stdout: "", stderr: "token=SECRET-VALUE"))
        await h.run()
        let record = try #require(try h.latest())
        #expect(record.status == .success)
        #expect(record.errors == ["The archive could not be pruned"])
        #expect(try h.state.lastEventID == 10)
        #expect(try h.state.consecutiveFailures == 0)
    }

    @Test func anExpiredSignInDuringPruningStopsLikeAnyOther() async throws {
        let h = try Harness()
        let cloud = try h.addCloud()
        h.set.destinationIDs = [cloud.id]
        try h.save(extra: [cloud])
        let pair = PairID(set: h.set.id, destination: cloud.id)
        try h.prime(pair, kind: .googleDrive)
        h.setSession(cloud, FakeSession(endpoint: "crypt:"))
        try h.cloudMarker(at: "crypt:.mirror-root")
        h.change("flowapp/a.txt")
        h.rclone.failCaptures(RcloneCapture(exitCode: 1, stdout: "", stderr: """
            {"level":"error","msg":"Failed to create file system: couldn't fetch token: invalid_grant"}
            """))
        await h.run()
        #expect(try h.state(pair).stoppedBy == .signInExpired)
        #expect(try h.active.contains(.signInExpired))
        #expect(h.session(cloud)?.closes == 1)
    }

    @Test func aCancelledPruneStopsTheAgent() async throws {
        let h = try Harness(); try h.prime(); h.change("flowapp/a.txt")
        let spy = CancelledCapture(wrapping: h.rclone)
        #expect(await h.coordinator(rclone: spy).runAll(command: RunCommand()))
        #expect(try h.latest()?.errors == ["Stopped before finishing"])
    }

    // MARK: Symlink manifest

    @Test func theManifestListsLinksAndSkipsExcludedFolders() async throws {
        let h = try Harness(); try h.prime(); h.change("flowapp/a.txt", rescan: true)
        try link(h, "flowapp/link", to: "a.txt")
        try link(h, "flowapp/node_modules/.bin/tool", to: "../tool")
        try link(h, "flowapp/skipped-link", to: "a.txt")
        h.set.rules = [UserRule(pattern: "node_modules/**", action: .exclude), UserRule(pattern: "skipped-link", action: .exclude)]
        try h.save()
        await h.run()
        #expect(try manifest(h) == ["flowapp/link"])
    }

    @Test func aScopedRunRefreshesOnlyItsFolders() async throws {
        let h = try Harness(); try h.prime()
        try SymlinkManifest(set: "x", entries: [
            .init(path: "other/kept", target: "t", isAbsolute: false, isBroken: true),
            .init(path: "flowapp/stale", target: "t", isAbsolute: false, isBroken: true),
        ]).write(backupRoot: h.backupRoot)
        try link(h, "flowapp/fresh", to: "a.txt")
        try link(h, "unvisited/not-walked", to: "x")
        h.change("flowapp/a.txt")
        await h.run()
        #expect(try manifest(h) == ["flowapp/fresh", "other/kept"])
    }

    @Test func anUnchangedManifestIsNotRewritten() async throws {
        let h = try Harness(); try h.prime()
        try link(h, "flowapp/link", to: "a.txt")
        h.change("flowapp/a.txt", rescan: true)
        await h.run()
        let file = try SymlinkManifest.location(set: "x", backupRoot: h.backupRoot)
        let before = try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? Int
        h.feed.set(ChangeBatch(paths: [], mustRescan: true, latestEventID: 11))
        await h.run()
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? Int == before)
    }

    @Test func aManifestFolderLeadingOutOfTheRootIsNotWrittenThrough() async throws {
        let h = try Harness(); try h.prime(); h.change("flowapp/a.txt", rescan: true)
        try link(h, "flowapp/link", to: "a.txt")
        let outside = h.root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: h.backupRoot.appendingPathComponent("Manifests"), withDestinationURL: outside)
        await h.run()
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        #expect(try h.latest()?.errors == ["The symlink list could not be saved"])
        #expect(try h.latest()?.status == .success)
    }

    // MARK: Items to review

    private func excludingVendor(_ h: Harness) throws {
        h.set.rules = [UserRule(pattern: "cache/**", action: .exclude), UserRule(pattern: "node_modules/**", action: .exclude)]
        try h.save()
    }

    @Test func aSecretInAnExcludedFolderIsSpottedEvenWithNothingToBackUp() async throws {
        let h = try Harness(); try h.prime(); try excludingVendor(h)
        try write(h, "flowapp/cache/.env")
        h.change("flowapp/cache/.env")
        await h.run()
        #expect(try h.latest()?.status == .skipped)
        #expect(try h.state.reviewItems == [ReviewItem(id: "secret:flowapp/cache/.env", path: "flowapp/cache/.env", kind: .secretInExcluded)])
    }

    @Test func thirdPartyFoldersAndDeletedFilesAreNotItems() async throws {
        let h = try Harness(); try h.prime(); try excludingVendor(h)
        try write(h, "flowapp/node_modules/pkg/.env")
        h.change("flowapp/node_modules/pkg/.env", "flowapp/cache/gone.pem")
        await h.run()
        #expect(try h.state.reviewItems.isEmpty)
    }

    @Test func aSecretExcludedByItsOwnNameIsNoSurprise() async throws {
        let h = try Harness(); try h.prime()
        h.set.backupSecrets = false
        try h.save()
        try write(h, "flowapp/.env")
        h.change("flowapp/.env")
        await h.run()
        #expect(try h.state.reviewItems.isEmpty)
    }

    @Test func aManualRunStillLooksAtWhatChanged() async throws {
        let h = try Harness(); try h.prime(); try excludingVendor(h)
        try write(h, "flowapp/cache/key.pem")
        h.change("flowapp/cache/key.pem")
        await h.run(RunCommand(force: true))
        #expect(try h.state.reviewItems.map(\.path) == ["flowapp/cache/key.pem"])
    }

    @Test func anItemIsRaisedOnceAndGoesWhenTheOwnerDecides() async throws {
        let h = try Harness(); try h.prime(); try excludingVendor(h)
        try write(h, "flowapp/cache/.env")
        h.change("flowapp/cache/.env")
        await h.run()
        h.change("flowapp/cache/.env", id: 11)
        await h.run()
        #expect(try h.state.reviewItems.count == 1)

        h.set.rules.insert(UserRule(pattern: "/flowapp/cache/.env", action: .exclude), at: 0)
        try h.save()
        h.change("flowapp/cache/.env", id: 12)
        await h.run()
        #expect(try h.state.reviewItems.isEmpty)
    }

    /// Waits on a termination handler, as a blocked pool thread would starve timing tests running alongside.
    private func repo(_ h: Harness, tracked: String) async throws {
        let dir = h.source.appendingPathComponent("flowapp")
        try write(h, "flowapp/\(tracked)")
        func git(_ a: String...) async throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-C", dir.path] + a
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
                p.terminationHandler = { _ in c.resume() }
                do { try p.run() } catch { c.resume(throwing: error) }
            }
        }
        try await git("init", "-q")
        try await git("add", "-f", tracked)
    }

    @Test func aFullPassFindsTrackedFilesInExcludedFolders() async throws {
        let h = try Harness(); try h.prime(); try excludingVendor(h)
        try await repo(h, tracked: "cache/committed.txt")
        h.now = Date()   // the index was just written
        var s = try h.state
        s.lastFullPass = h.now.addingTimeInterval(-2 * 86_400)
        try h.store.save(s, for: h.pair)
        h.change("flowapp/a.txt")
        await h.run()
        #expect(try h.state.reviewItems == [ReviewItem(id: "tracked:flowapp/cache", path: "flowapp/cache", kind: .trackedInExcluded)])
    }

    @Test func aRepoWhoseIndexIsOlderThanTheLastPassIsLeftAlone() async throws {
        let h = try Harness(); try h.prime(); try excludingVendor(h)
        try await repo(h, tracked: "cache/committed.txt")
        h.now = Date().addingTimeInterval(3 * 86_400)
        var s = try h.state
        s.lastFullPass = h.now.addingTimeInterval(-2 * 86_400)   // a day after the index changed
        try h.store.save(s, for: h.pair)
        h.change("flowapp/a.txt")
        await h.run()
        #expect(try h.state.reviewItems.isEmpty)
    }

    @Test func anOrdinaryRunRunsNoGit() async throws {
        let h = try Harness(); try h.prime(); try excludingVendor(h)
        try await repo(h, tracked: "cache/committed.txt")
        h.now = Date()
        var s = try h.state
        s.lastFullPass = h.now.addingTimeInterval(-3600)
        try h.store.save(s, for: h.pair)
        h.change("flowapp/a.txt")
        await h.run()
        #expect(try h.state.reviewItems.isEmpty)
    }
}

/// Everything goes through, until something is captured.
private struct CancelledCapture: RcloneRunning {
    let wrapping: FakeRclone
    func sync(_ r: SyncRequest) async throws -> RcloneResult { try await wrapping.sync(r) }
    func check(_ r: CheckRequest) async throws -> RcloneResult { try await wrapping.check(r) }
    func capture(_ arguments: [String], context: RcloneContext) async throws -> RcloneCapture { throw CancellationError() }
}

@Suite struct RunWiringProgressTests {
    private func files(_ h: Harness) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: h.support.appendingPathComponent("progress").path)) ?? []
    }
    private let stats = RcloneStats(bytes: 50, bytesTotal: 100, filesDone: 1, filesTotal: 2, speed: 4096, eta: 12)

    @Test func aRunGoesThroughItsPhasesAndLeavesNothingBehind() async throws {
        let h = try Harness(); try h.prime(); h.change("flowapp/a.txt")
        await h.run()
        var phases: [TransferProgress.Phase] = []
        for p in h.written.map(\.phase) where phases.last != p { phases.append(p) }
        #expect(phases == [.scanning, .transferring, .verifying])
        #expect(h.written.allSatisfy { $0.pair == h.pair })
        #expect(files(h).isEmpty)
    }

    @Test func statsReachTheStoreOnlyWhileTransferring() async throws {
        let h = try Harness(); try h.prime(); h.change("flowapp/a.txt")
        let (progress, stats) = (h.progress, stats)
        var seen: TransferProgress?
        h.rclone.onDryRun = { progress.stats(stats) }
        h.rclone.onRealSync = { progress.stats(stats) }
        await h.run()
        seen = h.written.first { $0.bytesTotal != nil }
        #expect(seen?.phase == .transferring)
        #expect(seen?.fraction == 0.5 && seen?.eta == 12 && seen?.etaIsEstimate == false)
        #expect(h.written.filter { $0.phase != .transferring }.allSatisfy { $0.bytesTotal == nil })
    }

    @Test func statsKeepAQuietPhaseFromGoingStale() async throws {
        let h = try Harness(); try h.prime(); h.change("flowapp/a.txt")
        let progress = h.progress
        let stats = stats
        h.rclone.onDryRun = { progress.stats(stats) }
        await h.run()
        #expect(h.written.filter { $0.phase == .scanning }.count == 2)
    }

    @Test func statsWithNoRunGoNowhere() throws {
        let h = try Harness()
        h.progress.stats(stats)
        #expect(h.written.isEmpty)
    }

    @Test func aFailedRunClearsItsProgress() async throws {
        let h = try Harness(); try h.prime(); h.change("flowapp/a.txt")
        h.rclone.script(real: [.transient])
        await h.run()
        #expect(!h.written.isEmpty)
        #expect(files(h).isEmpty)
    }

    @Test func aCancelledRunClearsItsProgress() async throws {
        let h = try Harness(); try h.prime(); h.change("flowapp/a.txt")
        h.rclone.script(killRealSync: true)
        await h.run()
        #expect(!h.written.isEmpty)
        #expect(files(h).isEmpty)
    }

    @Test func aWakeUpWithNothingToDoWritesNothing() async throws {
        let h = try Harness(); try h.prime()
        await h.run()
        #expect(h.written.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: h.support.appendingPathComponent("progress").path))
    }

    @Test func iCloudUploadsCountFilesWithAnEstimatedTime() async throws {
        let h = try Harness(); try h.prime()
        var s = try h.state
        s.uploadingPaths = (0..<80).map { "p/\($0)" } + (80..<100).map { "p/done\($0)" }
        s.uploadingSince = h.now.addingTimeInterval(-hour)
        s.uploadTotal = 100
        s.uploadSample = UploadSample(done: 0, at: h.now.addingTimeInterval(-1000))
        try h.store.save(s, for: h.pair)
        h.auditor.set(pending: Set((0..<80).map(String.init)))
        await h.run()
        let p = try #require(h.written.last)
        #expect(p.phase == .waitingForICloud)
        #expect(p.filesDone == 20 && p.filesTotal == 100)
        #expect(p.etaIsEstimate && p.eta == 4000)
        #expect(p.fraction == 0.2)
        #expect(files(h).isEmpty)
        #expect(try h.state.uploadSample == UploadSample(done: 20, at: h.now))
    }

    @Test func theFirstSightOfAnUploadHasNoRateToGoOn() async throws {
        let h = try Harness(); try h.prime(); h.change("flowapp/a.txt")
        h.rclone.script(copied: ["a.txt"], matching: 1)
        h.auditor.set(pending: ["a.txt"])
        await h.run()
        let p = try #require(h.written.last)
        #expect(p.phase == .waitingForICloud && p.filesDone == 0 && p.filesTotal == 1)
        #expect(p.eta == nil && p.etaIsEstimate)
    }

    @Test func aFinishedBatchForgetsItsCount() async throws {
        let h = try Harness(); try h.prime()
        var s = try h.state
        s.uploadingPaths = ["p/x"]
        s.uploadingSince = h.now
        s.uploadTotal = 5
        s.uploadSample = UploadSample(done: 4, at: h.now)
        try h.store.save(s, for: h.pair)
        await h.run()
        #expect(try h.state.uploadTotal == 0)
        #expect(try h.state.uploadSample == nil)
        #expect(h.written.isEmpty)
    }

    @Test func nothingIsCountedForACloudDestination() async throws {
        let h = try Harness()
        let cloud = try h.addCloud()
        h.set.destinationIDs = [cloud.id]
        try h.save(extra: [cloud])
        try h.prime(PairID(set: h.set.id, destination: cloud.id), kind: .googleDrive)
        h.setSession(cloud, FakeSession(endpoint: "crypt:"))
        try h.cloudMarker(at: "crypt:.mirror-root")
        h.change("flowapp/a.txt")
        await h.run()
        #expect(!h.written.isEmpty)
        #expect(!h.written.contains { $0.phase == .waitingForICloud })
    }
}

@Suite struct RunWiringDriveTests {
    private func root(_ v: VolumeInfo) -> URL { v.mountPoint.appendingPathComponent("Mac Backup") }

    /// A pair that has run on this connection: claimed, passed, event 5 stored.
    private func settled(_ h: Harness, _ d: Destination, _ v: VolumeInfo, seen: String? = "m1") throws -> PairID {
        try RootMarker(sets: [h.set.id: h.set.name]).save(backupRoot: root(v))
        let pair = PairID(set: h.set.id, destination: d.id)
        try h.prime(pair, kind: .externalDrive)
        var s = try h.state(pair)
        s.lastSeenMountID = seen
        try h.store.save(s, for: pair)
        return pair
    }

    @Test func aDriveThatIsNotConnectedIsSkippedQuietly() async throws {
        let h = try Harness()
        let (d, _) = try h.useDrive()
        let pair = PairID(set: h.set.id, destination: d.id)
        h.volumes.set([])
        h.change("flowapp/a.txt")
        await h.run()
        let record = try #require(try h.latest())
        #expect(record.status == .skipped && record.scope == "not connected")
        #expect(h.rclone.allCalls == 0)
        #expect(try h.active.isEmpty)
        #expect(try h.state(pair) == SetState())
    }

    @Test func aDriveWithTheSameNameAndAnotherUUIDIsNeverWritten() async throws {
        let h = try Harness()
        let (_, v) = try h.useDrive()
        var other = v; other.uuid = "OTHER"
        h.volumes.set([other])
        await h.run(RunCommand(force: true))
        #expect(h.rclone.allCalls == 0)
        #expect(!FileManager.default.fileExists(atPath: root(v).path))
        #expect(try h.latest()?.scope == "not connected")
    }

    @Test func theFirstConnectionClaimsTheDriveAndWritesOnlyThere() async throws {
        let h = try Harness()
        let (d, v) = try h.useDrive()
        let pair = PairID(set: h.set.id, destination: d.id)
        h.rclone.script(matching: 1)
        await h.run()
        #expect(try RootMarker.load(backupRoot: root(v))?.claims(h.set.id) == true)
        let sync = try #require(h.rclone.realSyncs.first)
        #expect(sync.destination == root(v).appendingPathComponent("Sets/x").path)
        #expect(sync.backupDir.hasPrefix(root(v).appendingPathComponent("Archive/x").path + "/"))
        #expect(sync.context == RcloneContext(configPath: "/dev/null", environment: [:]))
        #expect(h.session(d) == nil)
        #expect(try h.latest()?.status == .success)
        #expect(try h.state(pair).lastSeenMountID == "m1")
        #expect(!FileManager.default.fileExists(atPath: h.backupRoot.path))
    }

    @Test func aDriveHasNoUploadAuditAndNothingToEvict() async throws {
        let h = try Harness()
        let (d, v) = try h.useDrive()
        _ = try settled(h, d, v)
        h.change("flowapp/a.txt")
        let archived = root(v).appendingPathComponent("Archive/x/2033-05-01T00-00-00")
        try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)
        try Data("a".utf8).write(to: archived.appendingPathComponent("old.txt"))
        h.rclone.script(copied: ["flowapp/a.txt"], matching: 1)
        h.auditor.set(pending: ["a.txt"])
        await h.run()
        #expect(h.auditor.calls.isEmpty)
        #expect(h.evicted.isEmpty)
        #expect(try h.latest()?.status == .success)
    }

    @Test func aDriveKeepsItsOwnManifestUnlessItStoresLinksAsFiles() async throws {
        let h = try Harness()
        try FileManager.default.createSymbolicLink(atPath: h.source.appendingPathComponent("flowapp/link").path, withDestinationPath: "a.txt")
        let (_, v) = try h.useDrive()
        await h.run()
        #expect(try SymlinkManifest.read(set: "x", backupRoot: root(v)).entries.map(\.path) == ["flowapp/link"])

        let h2 = try Harness()
        try FileManager.default.createSymbolicLink(atPath: h2.source.appendingPathComponent("flowapp/link").path, withDestinationPath: "a.txt")
        let (_, exfat) = try h2.useDrive(fileSystem: "exfat")
        await h2.run()
        #expect(!FileManager.default.fileExists(atPath: root(exfat).appendingPathComponent("Manifests").path))
    }

    @Test func theDrivesFileSystemSetsEveryRequest() async throws {
        let h = try Harness()
        try h.useDrive(fileSystem: "exfat")
        await h.run()
        let sync = try #require(h.rclone.realSyncs.first)
        #expect(sync.profile.linksAsFiles && sync.profile.excludeAppleDouble && !sync.profile.trackRenames)
        #expect(sync.profile.modifyWindow == "2s")
        #expect(!h.rclone.checks.isEmpty)
        #expect(h.rclone.checks.allSatisfy { $0.linksAsFiles && $0.excludeAppleDouble })
    }

    // MARK: Full passes

    @Test func aNewConnectionIsAFullPassWhateverTheFeedSays() async throws {
        let h = try Harness()
        let (d, v) = try h.useDrive(mountID: "m2")
        let pair = try settled(h, d, v, seen: "m1")
        await h.run()
        #expect(h.rclone.realSyncs.count == 1)
        #expect(try h.latest()?.scope == "whole set")
        #expect(try h.state(pair).lastSeenMountID == "m2")
        #expect(try h.state(pair).lastFullPass == h.now)
    }

    @Test func theSameConnectionUsesTheChangeFeed() async throws {
        let h = try Harness()
        let (d, v) = try h.useDrive()
        _ = try settled(h, d, v)
        await h.run()
        #expect(h.rclone.allCalls == 0)
        h.change("flowapp/a.txt")
        h.now = h.now.addingTimeInterval(60)   // records sort by start time, to the second
        await h.run()
        #expect(try h.latest()?.scope == "flowapp")
    }

    @Test func aFailedPassLeavesTheConnectionOwed() async throws {
        let h = try Harness()
        let (d, v) = try h.useDrive(mountID: "m2")
        let pair = try settled(h, d, v, seen: "m1")
        h.rclone.script(real: [.permanent])
        await h.run()
        #expect(try h.state(pair).lastSeenMountID == "m1")
    }

    @Test func aManualWholeSetRunCountsForTheConnection() async throws {
        let h = try Harness()
        let (d, v) = try h.useDrive(mountID: "m2")
        let pair = try settled(h, d, v, seen: "m1")
        await h.run(RunCommand(force: true))
        #expect(try h.state(pair).lastSeenMountID == "m2")
    }

    // MARK: Room

    @Test func aBackupThatWontFitStopsBeforeCopying() async throws {
        let h = try Harness()
        let (d, v) = try h.useDrive(free: 2_000_000_000)
        let pair = try settled(h, d, v)
        h.change("flowapp/a.txt")
        h.rclone.dry(bytes: 3_000_000_000)
        await h.run()
        #expect(h.rclone.realSyncs.isEmpty && !h.rclone.dryRuns.isEmpty)
        #expect(try h.active == [.driveFull])
        let state = try h.state(pair)
        #expect(state.stoppedBy == .driveFull)
        #expect(state.lastEventID == 5)
        #expect(state.consecutiveFailures == 0)
        #expect(try h.latest()?.status == .failed)
    }

    @Test func driveFullClearsOnceItFits() async throws {
        let h = try Harness()
        let (d, v) = try h.useDrive(free: 30_000_000_000)   // about 22 GB of it is the reserve
        let pair = try settled(h, d, v)
        h.change("flowapp/a.txt")
        h.rclone.dry(bytes: 10_000_000_000)
        await h.run()
        h.rclone.dry(bytes: 100)
        await h.run()
        #expect(try h.active.isEmpty)
        #expect(try h.state(pair).stoppedBy == nil)
        #expect(h.rclone.realSyncs.count == 1)
    }

    @Test func theReserveCounts() async throws {
        let h = try Harness()
        let (d, v) = try h.useDrive(free: 22_000_000_000)   // the reserve on this 1 TiB drive is about 22 GB
        _ = try settled(h, d, v)
        h.change("flowapp/a.txt")
        h.rclone.dry(bytes: 1_000_000_000)
        await h.run()
        #expect(try h.active == [.driveFull])
    }

    @Test func expiredArchivesAreClearedBeforeCallingADriveFull() async throws {
        let h = try Harness()
        let (d, v) = try h.useDrive(free: 2_000_000_000)
        _ = try settled(h, d, v)
        h.change("flowapp/a.txt")
        h.rclone.dry(bytes: 3_000_000_000)
        h.rclone.archive(stamps: [ArchiveScope.stampString(h.now.addingTimeInterval(-40 * 86_400)) + "/",
                                  ArchiveScope.stampString(h.now.addingTimeInterval(-86_400)) + "/"])
        var freed = v
        freed.freeBytes = 1 << 40
        let (volumes, roomy) = (h.volumes, freed)
        h.rclone.onPurge = { volumes.set([roomy]) }
        await h.run()
        #expect(h.rclone.purged.count >= 1)
        #expect(h.rclone.realSyncs.count == 1)
        #expect(try h.active.isEmpty)
    }

    // MARK: Unplugged

    @Test func unpluggedDuringTheSyncIsTransient() async throws {
        let h = try Harness()
        let (d, v) = try h.useDrive(mountID: "m2")
        let pair = try settled(h, d, v, seen: "m1")
        let volumes = h.volumes
        h.rclone.onRealSync = { volumes.set([]) }
        h.rclone.script(real: [.permanent])
        await h.run()
        let state = try h.state(pair)
        #expect(state.consecutiveFailures == 0)
        #expect(state.lastEventID == 5 && state.lastSeenMountID == "m1")
        #expect(state.wholeSetOwed && state.syncIncomplete && !state.isBackedUp)
        #expect(try h.active.isEmpty)
        let record = try #require(try h.latest())
        #expect(record.status == .partial && record.errors == ["The drive was disconnected"])
        #expect(h.notifier.ejects.isEmpty)
    }

    @Test func noCopyStartsOnADriveThatWentAfterTheDryRun() async throws {
        let h = try Harness()
        let (d, v) = try h.useDrive()
        _ = try settled(h, d, v)
        h.change("flowapp/a.txt")
        let volumes = h.volumes
        h.rclone.onDryRun = { volumes.set([]) }
        await h.run()
        #expect(h.rclone.realSyncs.isEmpty && h.rclone.checks.isEmpty)
        #expect(try h.latest()?.status == .partial)
    }

    @Test func aDriveRemountedElsewhereIsGoneToThisRun() async throws {
        let h = try Harness()
        let (d, v) = try h.useDrive()
        _ = try settled(h, d, v)
        h.change("flowapp/a.txt")
        var elsewhere = v
        elsewhere.mountPoint = h.root.appendingPathComponent("Volumes/SSD 1")
        let (volumes, moved) = (h.volumes, elsewhere)
        h.rclone.onDryRun = { volumes.set([moved]) }
        await h.run()
        #expect(h.rclone.realSyncs.isEmpty)
    }

    @Test func anOrdinaryFailureOnAConnectedDriveStillCounts() async throws {
        let h = try Harness()
        let (d, v) = try h.useDrive()
        let pair = try settled(h, d, v)
        h.change("flowapp/a.txt")
        h.rclone.script(real: [.permanent])
        await h.run()
        #expect(try h.state(pair).consecutiveFailures == 1)
        #expect(try h.latest()?.status == .failed)
    }

    @Test func housekeepingLeavesADriveThatWentAlone() async throws {
        let h = try Harness()
        let (d, v) = try h.useDrive()
        let pair = try settled(h, d, v)
        h.change("flowapp/a.txt")
        let spy = GoneBeforeTidy(wrapping: h.rclone, volumes: h.volumes)
        await h.coordinator(rclone: spy).runAll(command: RunCommand())
        #expect(h.rclone.captures.isEmpty)
        #expect(try h.state(pair).lastEventID == 10)
    }

    // MARK: Reminders and the end of a run

    @Test func aLongAbsentDriveGetsOneReminder() async throws {
        let h = try Harness()
        let (d, v) = try h.useDrive()
        let pair = try settled(h, d, v)
        var s = try h.state(pair)
        s.lastFinished = h.now.addingTimeInterval(-8 * 86_400)
        try h.store.save(s, for: pair)
        h.volumes.set([])
        await h.run()
        await h.run()
        #expect(h.notifier.posted == [.driveOverdue])
        #expect(try h.latest()?.status == .skipped)
    }

    @Test func noReminderBeforeAWeekOrForADriveThatNeverRan() async throws {
        let h = try Harness()
        let (d, v) = try h.useDrive()
        let pair = try settled(h, d, v)
        var s = try h.state(pair)
        s.lastFinished = h.now.addingTimeInterval(-6 * 86_400)
        try h.store.save(s, for: pair)
        h.volumes.set([])
        await h.run()
        s.lastFinished = nil
        try h.store.save(s, for: pair)
        await h.run()
        #expect(h.notifier.posted.isEmpty)
    }

    @Test func aFinishedRunClearsTheReminder() async throws {
        let h = try Harness()
        let (d, v) = try h.useDrive(mountID: "m2")
        let pair = try settled(h, d, v, seen: "m1")
        var s = try h.state(pair)
        s.lastFinished = h.now.addingTimeInterval(-8 * 86_400)
        try h.store.save(s, for: pair)
        h.volumes.set([])
        await h.run()
        h.volumes.set([v])
        await h.run()
        #expect(try h.active.isEmpty)
    }

    @Test func aFinishedConnectionSaysItIsSafeToEject() async throws {
        let h = try Harness()
        let (d, v) = try h.useDrive(mountID: "m2")
        _ = try settled(h, d, v, seen: "m1")
        await h.run()
        #expect(h.notifier.ejects == ["DRIVE-1"])
    }

    @Test func routineRunsOnAConnectedDriveDontKeepSayingSo() async throws {
        let h = try Harness()
        let (d, v) = try h.useDrive()
        _ = try settled(h, d, v)
        h.change("flowapp/a.txt")
        await h.run()
        #expect(try h.latest()?.status == .success)
        #expect(h.notifier.ejects.isEmpty)
    }

    @Test func aManualRunSaysSoToo() async throws {
        let h = try Harness()
        let (d, v) = try h.useDrive()
        _ = try settled(h, d, v)
        await h.run(RunCommand(force: true))
        #expect(h.notifier.ejects == ["DRIVE-1"])
    }

    @Test func twoSetsOnOneDriveSayItOnceAndOnlyIfBothFinished() async throws {
        let h = try Harness()
        let (d, _) = try h.useDrive()
        let other = h.root.appendingPathComponent("src2")
        try FileManager.default.createDirectory(at: other.appendingPathComponent("p"), withIntermediateDirectories: true)
        try Data("b".utf8).write(to: other.appendingPathComponent("p/b.txt"))
        var second = BackupSet(name: "y", source: other)
        second.destinationIDs = [d.id]
        second.acceptPreview()
        try h.store.saveSets([h.set, accepted(second)])
        await h.run(RunCommand(force: true))
        #expect(h.notifier.ejects == ["DRIVE-1"])

        h.rclone.script(real: [.permanent])
        await h.run(RunCommand(force: true))
        #expect(h.notifier.ejects == ["DRIVE-1"])
    }

    // MARK: Refusals

    @Test func anUnconfirmedInternalLookingDriveIsRefused() async throws {
        let h = try Harness()
        let (d, v) = try h.useDrive(looksInternal: true)
        await h.run(RunCommand(force: true))
        #expect(h.rclone.allCalls == 0)
        #expect(!FileManager.default.fileExists(atPath: root(v).path))
        #expect(try h.active == [.destinationMissing])
        #expect(try h.state(PairID(set: h.set.id, destination: d.id)).stoppedBy == .destinationMissing)
        #expect(try h.latest()?.status == .failed)
    }

    @Test func aConfirmedInternalLookingDriveRuns() async throws {
        let h = try Harness()
        let (_, v) = try h.useDrive(looksInternal: true, confirmed: true)
        await h.run()
        #expect(h.rclone.realSyncs.first?.destination == root(v).appendingPathComponent("Sets/x").path)
    }

    @Test func aSystemVolumeReadsAsNotConnected() async throws {
        let h = try Harness()
        var (_, v) = try h.useDrive()
        v.isSystem = true
        h.volumes.set([v])
        h.change("flowapp/a.txt")
        await h.run()
        #expect(h.rclone.allCalls == 0)
        #expect(!FileManager.default.fileExists(atPath: root(v).path))
        #expect(try h.active.isEmpty)
        let record = try #require(try h.latest())
        #expect(record.status == .skipped && record.scope == "not connected")
    }

    @Test func aLostMarkerOnADriveThatRanBeforeStops() async throws {
        let h = try Harness()
        let (d, v) = try h.useDrive()
        let pair = try settled(h, d, v)
        try FileManager.default.removeItem(at: RootMarker.url(backupRoot: root(v)))
        h.change("flowapp/a.txt")
        await h.run()
        #expect(h.rclone.allCalls == 0)
        #expect(try h.state(pair).stoppedBy == .destinationMissing)
    }

    // MARK: Mount wake-ups

    private func lastPass(_ h: Harness, _ ago: TimeInterval) throws {
        try FileManager.default.createDirectory(at: h.support, withIntermediateDirectories: true)
        try JSONEncoder().encode(h.now.addingTimeInterval(-ago)).write(to: h.support.appendingPathComponent("last-pass.json"))
    }

    @Test func aMountWithNothingDueIsGoneAtOnce() async throws {
        let h = try Harness(); try h.prime(); h.change("flowapp/a.txt")
        h.mountWakeWindow = 1440
        try lastPass(h, 60)
        await h.run()
        #expect(h.helperChecks == 0)
        #expect(h.feed.calls == 0)
        #expect(h.rclone.allCalls == 0)
        #expect(try h.latest() == nil)
        #expect(!FileManager.default.fileExists(atPath: h.support.appendingPathComponent("agent.pid").path))
    }

    @Test func aDriveAlreadySeenOnThisConnectionIsNotDue() async throws {
        let h = try Harness()
        let (d, v) = try h.useDrive()
        _ = try settled(h, d, v)
        h.mountWakeWindow = 1440
        try lastPass(h, 60)
        await h.run()
        #expect(try h.latest() == nil)
    }

    @Test func aMountRunsTheDriveThatJustArrivedFirstAndThenTheRest() async throws {
        let h = try Harness(); try h.prime(); h.change("flowapp/a.txt")
        let mount = h.root.appendingPathComponent("Volumes/D")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        let v = VolumeInfo(uuid: "D", name: "D", mountPoint: mount, fileSystem: "apfs", freeBytes: 1 << 50, mountID: "m1")
        let d = Destination(name: "D", kind: .externalDrive, volumeUUID: "D")
        h.set.destinationIDs.append(d.id)
        try h.save(extra: [d])
        h.volumes.set([v])
        h.mountWakeWindow = 1440
        try lastPass(h, 60)
        await h.run()
        // The time is only an inference, and an interval wake read as a mount mustn't lose the other pairs.
        #expect(h.rclone.realSyncs.map(\.destination).first == root(v).appendingPathComponent("Sets/x").path)
        #expect(h.rclone.realSyncs.map(\.destination).last == h.mirror + "/flowapp")
        #expect(h.priorities == [true, false])
    }

    @Test func aWakeUpPastTheWindowIsAFullPass() async throws {
        let h = try Harness(); try h.prime(); h.change("flowapp/a.txt")
        h.mountWakeWindow = 1440
        try lastPass(h, 1800)
        await h.run()
        #expect(h.rclone.realSyncs.count == 1)
    }

    @Test func aFullPassIsWhatTheWindowCountsFrom() async throws {
        let h = try Harness(); try h.prime(); h.change("flowapp/a.txt")
        h.mountWakeWindow = 1440
        await h.run()   // nothing on record, so a full pass
        #expect(h.rclone.realSyncs.count == 1)
        h.change("flowapp/a.txt", id: 11)
        await h.run()
        #expect(h.rclone.realSyncs.count == 1)
    }

    @Test func aManualRunIsNeverAMountWakeUp() async throws {
        let h = try Harness(); try h.prime()
        h.mountWakeWindow = 1440
        try lastPass(h, 60)
        await h.run(RunCommand(force: true))
        #expect(h.rclone.realSyncs.count == 1)
    }
}

/// Unplugs the drive as the last check of a run finishes.
private struct GoneBeforeTidy: RcloneRunning {
    let wrapping: FakeRclone
    let volumes: FakeVolumes
    func sync(_ r: SyncRequest) async throws -> RcloneResult { try await wrapping.sync(r) }
    func check(_ r: CheckRequest) async throws -> RcloneResult {
        let result = try await wrapping.check(r)
        volumes.set([])
        return result
    }
    func capture(_ arguments: [String], context: RcloneContext) async throws -> RcloneCapture {
        try await wrapping.capture(arguments, context: context)
    }
}

@Suite struct RunWiringPriorityTests {
    private func settings(_ h: Harness, _ change: (inout AppSettings) -> Void) throws {
        var s = AppSettings()
        change(&s)
        try SettingsStore(root: h.support).save(s)
    }

    private func flag(_ r: SyncRequest?) -> Bool? { r?.fullSpeed }

    @Test func aScheduledICloudRunStaysInTheBackground() async throws {
        let h = try Harness(); try h.prime(); h.change("flowapp/a.txt")
        await h.run()
        #expect(h.priorities == [false])
        #expect(flag(h.rclone.realSyncs.first) == false)
    }

    @Test func aScheduledCloudRunStaysInTheBackground() async throws {
        let h = try Harness()
        let cloud = try h.addCloud()
        h.set.destinationIDs = [cloud.id]
        try h.save(extra: [cloud])
        try h.prime(PairID(set: h.set.id, destination: cloud.id), kind: .googleDrive)
        h.setSession(cloud, FakeSession(endpoint: "crypt:"))
        try h.cloudMarker(at: "crypt:.mirror-root")
        h.change("flowapp/a.txt")
        await h.run()
        #expect(h.priorities == [false])
        #expect(flag(h.rclone.realSyncs.first) == false)
    }

    @Test func backUpNowRunsAtNormalPriority() async throws {
        let h = try Harness(); try h.prime()
        await h.run(RunCommand(force: true))
        #expect(h.priorities == [true])
        #expect(flag(h.rclone.realSyncs.first) == true)
    }

    @Test func aScheduledDriveRunIsRaisedAndUsesMoreTransfers() async throws {
        let h = try Harness()
        try h.useDrive()
        await h.run()
        #expect(h.priorities == [true])
        #expect(h.rclone.syncs.allSatisfy { $0.fullSpeed })
    }

    @Test func aPassWithBothRaisesOnlyForTheDrive() async throws {
        let h = try Harness(); try h.prime(); h.change("flowapp/a.txt")
        let mount = h.root.appendingPathComponent("Volumes/D")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        let d = Destination(name: "D", kind: .externalDrive, volumeUUID: "D")
        h.set.destinationIDs.append(d.id)
        try h.save(extra: [d])
        h.volumes.set([VolumeInfo(uuid: "D", name: "D", mountPoint: mount, fileSystem: "apfs", freeBytes: 1 << 50, mountID: "m")])
        await h.run()
        #expect(h.priorities == [false, true])
        #expect(h.rclone.realSyncs.map(\.fullSpeed) == [false, true])
    }

    @Test func lowPowerModeHoldsScheduledRunsWhenTheOwnerAskedForThat() async throws {
        let h = try Harness(); try h.prime(); h.change("flowapp/a.txt")
        try settings(h) { $0.pauseInLowPowerMode = true }
        h.lowPower = true
        await h.run()
        #expect(h.rclone.allCalls == 0)
        #expect(try h.latest() == nil)
        await h.run(RunCommand(force: true))
        #expect(h.rclone.realSyncs.count == 1)
    }

    @Test func lowPowerModeChangesNothingUnlessAsked() async throws {
        let h = try Harness(); try h.prime(); h.change("flowapp/a.txt")
        h.lowPower = true
        await h.run()
        #expect(h.rclone.realSyncs.count == 1)
    }

    @Test func theDeepCheckFollowsTheSetting() async throws {
        let h = try Harness(); try h.prime(); h.change("flowapp/a.txt", rescan: true)
        try settings(h) { $0.deepCheck = .weekly }
        try FileManager.default.createDirectory(atPath: h.mirror, withIntermediateDirectories: true)
        var s = try h.state
        s.lastFullPass = h.now.addingTimeInterval(-2 * 86_400)
        s.lastDeepCheck = h.now.addingTimeInterval(-8 * 86_400)
        try h.store.save(s, for: h.pair)
        await h.run()
        #expect(try h.state.lastDeepCheck == h.now)
    }

    @Test func aDamagedSettingsFileFallsBackToDefaults() async throws {
        let h = try Harness(); try h.prime(); h.change("flowapp/a.txt")
        try FileManager.default.createDirectory(at: h.support, withIntermediateDirectories: true)
        try Data("nope".utf8).write(to: h.support.appendingPathComponent("settings.json"))
        await h.run()
        #expect(h.rclone.realSyncs.count == 1)
    }

    @Test func theDriveReminderFollowsTheSetting() async throws {
        let h = try Harness()
        let (d, _) = try h.useDrive()
        try settings(h) { $0.driveReminderDays = 3 }
        let pair = PairID(set: h.set.id, destination: d.id)
        try h.prime(pair, kind: .externalDrive)
        var s = try h.state(pair)
        s.lastFinished = h.now.addingTimeInterval(-4 * 86_400)
        try h.store.save(s, for: pair)
        h.volumes.set([])
        await h.run()
        #expect(h.notifier.posted == [.driveOverdue])
    }
}

@Suite struct RunWiringPreviewTests {
    private let node = Preset(id: "node", name: "Node", markers: ["package.json"], alwaysExclude: ["node_modules/"], ambiguousExclude: [])

    @Test func aSetWhosePreviewWasNeverAcceptedIsNotBackedUp() async throws {
        let h = try Harness(); try h.prime(); h.change("flowapp/a.txt")
        try h.save(accepted: false)
        await h.run()
        let record = try #require(try h.latest())
        #expect(record.status == .skipped && record.scope == "waiting for preview")
        #expect(h.rclone.allCalls == 0)
        #expect(try h.state.lastEventID == 5)
    }

    @Test func backUpNowCantGetRoundIt() async throws {
        let h = try Harness(); try h.prime()
        try h.save(accepted: false)
        await h.run(RunCommand(force: true, fullSpeed: true))
        #expect(h.rclone.allCalls == 0)
        #expect(try h.latest()?.scope == "waiting for preview")
    }

    @Test func aRuleChangedSinceTheAcceptanceAsksAgain() async throws {
        let h = try Harness(); try h.prime(); h.change("flowapp/a.txt")
        try h.save()
        var sets = try h.store.loadSets()
        sets[0].rules.append(UserRule(pattern: "*.log", action: .exclude))
        try h.store.saveSets(sets)
        await h.run()
        #expect(h.rclone.allCalls == 0)
    }

    @Test func aRenameOrPauseIsNotARuleChange() async throws {
        var s = BackupSet(name: "a", source: URL(fileURLWithPath: "/tmp/a"))
        s.acceptPreview()
        s.name = "b"; s.archiveDays = 7
        #expect(s.isPreviewAccepted)
    }

    @Test func anOlderSetsFileReadsAsNotAccepted() throws {
        let h = try Harness()
        let url = h.support.appendingPathComponent("sets.json")
        var json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        json[0]["acceptedFingerprint"] = nil
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        #expect(try h.store.loadSets().first?.isPreviewAccepted == false)
    }

    @Test func aPresetTheAgentAddsDoesNotUnacceptTheSet() async throws {
        let h = try Harness(); try h.prime()
        var s = try h.state
        s.knownProjects = []
        try h.store.save(s, for: h.pair)
        try Data("{}".utf8).write(to: h.source.appendingPathComponent("flowapp/package.json"))
        h.change("flowapp/package.json")
        await h.run(presets: [node])
        let set = try #require(try h.store.loadSets().first)
        #expect(set.presets == ["node"])
        #expect(set.isPreviewAccepted)
        #expect(h.rclone.realSyncs.count == 1)

        h.change("flowapp/a.txt", id: 11)
        await h.run(presets: [node])
        #expect(h.rclone.realSyncs.count == 2)
    }
}

@Suite struct RunWiringApprovalTests {
    /// iCloud and a cloud destination, both holding.
    private func twoHolding(_ h: Harness) async throws -> (cloud: Destination, pair: PairID) {
        let cloud = try h.addCloud()
        try h.save(extra: [cloud])
        try h.prime()
        let pair = PairID(set: h.set.id, destination: cloud.id)
        try h.prime(pair, kind: .googleDrive)
        h.setSession(cloud, FakeSession(endpoint: "crypt:"))
        try h.cloudMarker(at: "crypt:.mirror-root")
        for p in [h.pair, pair] {
            var s = try h.state(p)
            s.heldDeletions = 300
            try h.store.save(s, for: p)
        }
        h.rclone.script(dryDeletions: (0..<300).map { "d\($0)" })
        return (cloud, pair)
    }

    private func mode(_ h: Harness, to prefix: String) -> SyncMode? {
        h.rclone.realSyncs.last { $0.destination.hasPrefix(prefix) }?.mode
    }

    @Test func anApprovalCoversOnlyTheNamedDestination() async throws {
        let h = try Harness()
        let (cloud, pair) = try await twoHolding(h)
        await h.run(RunCommand(setID: h.set.id, approvedDeletions: 300, approvedDestination: cloud.id, force: true))
        #expect(mode(h, to: "crypt:") != .copyOnly)
        #expect(mode(h, to: h.mirror) == .copyOnly)
        #expect(try h.state(pair).heldDeletions == 0)
        #expect(try h.state.heldDeletions == 300)
    }

    @Test func anApprovalNamingNoDestinationCoversNothing() async throws {
        let h = try Harness()
        _ = try await twoHolding(h)
        await h.run(RunCommand(setID: h.set.id, approvedDeletions: 300, force: true))
        #expect(mode(h, to: "crypt:") == .copyOnly)
        #expect(mode(h, to: h.mirror) == .copyOnly)
    }

    @Test func theApprovedCountIsTheNonGitCount() async throws {
        let h = try Harness(); try h.prime()
        var s = try h.state
        s.heldDeletions = 300
        try h.store.save(s, for: h.pair)
        let files = (0..<300).map { "d\($0)" } + (0..<50).map { "p/.git/o\($0)" }
        h.rclone.script(dryDeletions: files)
        await h.run(RunCommand(setID: h.set.id, approvedDeletions: AgentWire.nonGitCount(files), approvedDestination: h.iCloudDest.id, force: true))
        #expect(h.rclone.realSyncs.last?.mode == .mirror(maxDelete: 350))
    }
}

@Suite struct ReviewKindMigrationTests {
    @Test func aRetiredReviewKindLeavesThePairsHistoryReadable() throws {
        let json = #"""
        {"lastEventID": 7, "reviewItems": [
            {"id": "unproven:a.txt", "path": "a.txt", "kind": "unprovenFreed"},
            {"id": "secret:b/.env", "path": "b/.env", "kind": "secretInExcluded"}]}
        """#
        let state = try JSONDecoder().decode(SetState.self, from: Data(json.utf8))
        #expect(state.lastEventID == 7)
        #expect(state.reviewItems.map(\.path) == ["b/.env"])
    }
}

@Suite struct FixRoundOneTests {
    private func lastPass(_ h: Harness, _ ago: TimeInterval) throws {
        try FileManager.default.createDirectory(at: h.support, withIntermediateDirectories: true)
        try JSONEncoder().encode(h.now.addingTimeInterval(-ago)).write(to: h.support.appendingPathComponent("last-pass.json"))
    }

    // I1

    @Test func fullSpeedLeavesAMountWakeAMountWake() async throws {
        let h = try Harness(); try h.prime(); h.change("flowapp/a.txt")
        h.mountWakeWindow = 1440
        try lastPass(h, 60)
        await h.run(RunCommand(fullSpeed: true))
        #expect(h.rclone.allCalls == 0)
        #expect(try h.latest() == nil)
    }

    @Test func aFullSpeedPassStillCountsAsTheLastPass() async throws {
        let h = try Harness(); try h.prime(); h.change("flowapp/a.txt")
        h.mountWakeWindow = 1440
        await h.run(RunCommand(fullSpeed: true))
        #expect(h.rclone.realSyncs.count == 1)
        #expect(FileManager.default.fileExists(atPath: h.support.appendingPathComponent("last-pass.json").path))
    }

    @Test func onlyAManualRunOrAnApprovalIsNotScheduled() {
        #expect(RunCommand().isScheduled && RunCommand(fullSpeed: true).isScheduled)
        #expect(!RunCommand(force: true).isScheduled)
        #expect(!RunCommand(setID: UUID()).isScheduled)
        #expect(!RunCommand(approvedDeletions: 1, approvedDestination: UUID()).isScheduled)
    }

    // I4

    private func emptied(_ h: Harness) throws {
        try FileManager.default.removeItem(at: h.source.appendingPathComponent("flowapp"))
        h.rclone.script(dryDeletions: ["a", "b", "c", "p/.git/x", ".git/y"])
    }

    @Test func anEmptySourceHoldsTheCountTheReviewListShows() async throws {
        let h = try Harness(); try h.prime()
        var s = try h.state
        s.lastFileCount = nil   // otherwise the guard stops it before any dry run
        try h.store.save(s, for: h.pair)
        try emptied(h)
        await h.run(RunCommand(force: true))
        #expect(try h.state.heldDeletions == 3)
    }

    @Test func anEmptySourceWithGitFilesCanBeApproved() async throws {
        let h = try Harness(); try h.prime()
        var s = try h.state
        s.lastFileCount = nil
        s.heldDeletions = 3
        try h.store.save(s, for: h.pair)
        try emptied(h)
        let files = ["a", "b", "c", "p/.git/x", ".git/y"]
        await h.run(RunCommand(setID: h.set.id, approvedDeletions: AgentWire.nonGitCount(files), approvedDestination: h.iCloudDest.id, force: true))
        #expect(h.rclone.realSyncs.last?.mode == .mirror(maxDelete: 5))
        #expect(try h.state.heldDeletions == 0)
    }

    @Test func anEmptySourceLosingOnlyGitFilesStillHoldsAndCanBeReleased() async throws {
        let h = try Harness(); try h.prime()
        var s = try h.state
        s.lastFileCount = nil
        try h.store.save(s, for: h.pair)
        try FileManager.default.removeItem(at: h.source.appendingPathComponent("flowapp"))
        h.rclone.script(dryDeletions: [".git/y"])
        await h.run(RunCommand(force: true))
        #expect(h.rclone.realSyncs.last?.mode == .copyOnly)
        #expect(try h.state.heldDeletions == 1)
        await h.run(RunCommand(setID: h.set.id, approvedDeletions: 0, approvedDestination: h.iCloudDest.id, force: true))
        #expect(h.rclone.realSyncs.last?.mode == .mirror(maxDelete: 1))
    }

    @Test func aSafetyStopCountsWhatTheReviewListShows() async throws {
        let h = try Harness(); try h.prime(); h.change("flowapp/a.txt", rescan: true)
        h.rclone.script(real: [.safetyStop], dryDeletions: ["a", "b", "p/.git/x"])
        await h.run()
        #expect(try h.state.heldDeletions == 2)
    }
}

/// Throws from the first capture, and passes everything else through.
private struct ThrowingCapture: RcloneRunning {
    let wrapping: FakeRclone
    let error: any Error & Sendable
    func sync(_ r: SyncRequest) async throws -> RcloneResult { try await wrapping.sync(r) }
    func check(_ r: CheckRequest) async throws -> RcloneResult { try await wrapping.check(r) }
    func capture(_ arguments: [String], context: RcloneContext) async throws -> RcloneCapture { throw error }
}

@Suite struct DriveRoomPruneTests {
    /// A drive with too little room and one expired archive folder.
    private func cramped(_ h: Harness, held: Int = 0) throws -> PairID {
        let (d, v) = try h.useDrive(free: 2_000_000_000)
        try RootMarker(sets: [h.set.id: h.set.name]).save(backupRoot: v.mountPoint.appendingPathComponent("Mac Backup"))
        let pair = PairID(set: h.set.id, destination: d.id)
        try h.prime(pair, kind: .externalDrive)
        var s = try h.state(pair)
        s.lastSeenMountID = "m1"
        s.heldDeletions = held
        try h.store.save(s, for: pair)
        h.change("flowapp/a.txt")
        h.rclone.dry(bytes: 3_000_000_000)
        h.rclone.archive(stamps: [ArchiveScope.stampString(h.now.addingTimeInterval(-40 * 86_400)) + "/",
                                  ArchiveScope.stampString(h.now.addingTimeInterval(-86_400)) + "/"])
        return pair
    }

    @Test func aHeldPairNeverPrunesForRoom() async throws {
        let h = try Harness()
        _ = try cramped(h, held: 300)
        await h.run()
        #expect(h.rclone.purged.isEmpty)
        #expect(try h.active.contains(.driveFull))
    }

    @Test func neitherDoesAHoldThisRunJustMade() async throws {
        let h = try Harness()
        _ = try cramped(h)
        h.rclone.script(dryDeletions: (0..<500).map { "d\($0)" })
        h.rclone.dry(bytes: 3_000_000_000)
        await h.run()
        #expect(h.rclone.purged.isEmpty)
        #expect(h.rclone.realSyncs.isEmpty)
    }

    @Test func whatAPruneForRoomRemovedIsRecorded() async throws {
        let h = try Harness()
        _ = try cramped(h)
        await h.run()
        #expect(h.rclone.purged.count == 1)
        #expect(try h.latest()?.archivesPruned == 1)
        #expect(try h.latest()?.status == .failed)   // still no room
    }

    @Test func aCancelDuringThatPruneStops() async throws {
        let h = try Harness()
        _ = try cramped(h)
        await h.coordinator(rclone: ThrowingCapture(wrapping: h.rclone, error: CancellationError())).runAll(command: RunCommand())
        #expect(try h.latest()?.errors == ["Stopped before finishing"])
        #expect(h.rclone.realSyncs.isEmpty)
        #expect(try !h.active.contains(.driveFull))
    }

    @Test func aBadRcloneDuringThatPruneFailsTheAgent() async throws {
        let h = try Harness()
        _ = try cramped(h)
        let ran = await h.coordinator(rclone: ThrowingCapture(wrapping: h.rclone, error: AgentFailure.untrustedHelper)).runAll(command: RunCommand())
        #expect(!ran)
        #expect(try h.active.contains(.agentFailed))
    }

    @Test func aDriveThatLeftBeforeThatPruneIsLeftAlone() async throws {
        let h = try Harness()
        let pair = try cramped(h)
        let volumes = h.volumes
        h.rclone.onDryRun = { volumes.set([]) }
        await h.run()
        #expect(h.rclone.captures.isEmpty)
        #expect(try h.latest()?.status == .partial)
        #expect(try h.state(pair).stoppedBy == nil)
    }
}

@Suite struct FixRoundOneMinorTests {
    private func lastPass(_ h: Harness, _ ago: TimeInterval) throws {
        try FileManager.default.createDirectory(at: h.support, withIntermediateDirectories: true)
        try JSONEncoder().encode(h.now.addingTimeInterval(-ago)).write(to: h.support.appendingPathComponent("last-pass.json"))
    }

    private func root(_ v: VolumeInfo) -> URL { v.mountPoint.appendingPathComponent("Mac Backup") }

    private func settled(_ h: Harness, _ d: Destination, _ v: VolumeInfo) throws -> PairID {
        try RootMarker(sets: [h.set.id: h.set.name]).save(backupRoot: root(v))
        let pair = PairID(set: h.set.id, destination: d.id)
        try h.prime(pair, kind: .externalDrive)
        var s = try h.state(pair)
        s.lastSeenMountID = "m1"
        try h.store.save(s, for: pair)
        return pair
    }

    // M2

    @Test func aPausedSetIsNotADueDrive() async throws {
        let h = try Harness()
        h.set.isPaused = true
        try h.useDrive()
        h.mountWakeWindow = 1440
        try lastPass(h, 60)
        await h.run()
        #expect(try h.latest() == nil)
    }

    @Test func anUnacceptedSetIsNotADueDrive() async throws {
        let h = try Harness()
        try h.useDrive()
        try h.save(extra: try h.store.loadDestinations().filter { $0.id != h.iCloudDest.id }, accepted: false)
        h.mountWakeWindow = 1440
        try lastPass(h, 60)
        await h.run()
        #expect(try h.latest() == nil)
    }

    // M3

    @Test func noMarkerIsWrittenToADriveThatJustLeft() async throws {
        let h = try Harness()
        let (_, v) = try h.useDrive()
        h.volumes.gone(after: 1)   // the look that found it
        await h.run()
        #expect(!FileManager.default.fileExists(atPath: RootMarker.url(backupRoot: root(v)).path))
        #expect(try h.latest()?.status == .partial)
    }

    private func looksInAScopedRun() async throws -> Int {
        let h = try Harness()
        let (d, v) = try h.useDrive()
        _ = try settled(h, d, v)
        h.change("flowapp/a.txt")
        h.volumes.gone(after: 1000)
        await h.run()
        return h.volumes.reads
    }

    @Test func noManifestIsWrittenToADriveThatJustLeft() async throws {
        let looks = try await looksInAScopedRun()
        let h = try Harness()
        try FileManager.default.createSymbolicLink(atPath: h.source.appendingPathComponent("flowapp/link").path, withDestinationPath: "a.txt")
        let (d, v) = try h.useDrive()
        _ = try settled(h, d, v)
        h.change("flowapp/a.txt")
        h.volumes.gone(after: looks - 1)   // it leaves between housekeeping's first look and the write
        await h.run()
        #expect(!FileManager.default.fileExists(atPath: root(v).appendingPathComponent("Manifests").path))
        #expect(try h.latest()?.errors == [])
    }

    // M4

    @Test func runningOutOfSpaceMidCopyIsADriveFull() async throws {
        let h = try Harness()
        let (d, v) = try h.useDrive()
        let pair = try settled(h, d, v)
        h.change("flowapp/a.txt")
        h.rclone.script(real: [.permanent], errors: ["big.bin: write /Volumes/x/big.bin: no space left on device"])
        await h.run()
        let state = try h.state(pair)
        #expect(state.stoppedBy == .driveFull && state.consecutiveFailures == 0)
        #expect(try h.active == [.driveFull])
        #expect(state.lastEventID == 5)
    }

    @Test func thatWordingMeansNothingSpecialOffADrive() async throws {
        let h = try Harness(); try h.prime(); h.change("flowapp/a.txt")
        h.rclone.script(real: [.permanent], errors: ["no space left on device"])
        await h.run()
        #expect(try h.state.consecutiveFailures == 1)
        #expect(try !h.active.contains(.driveFull))
    }

    // M5

    @Test func aFailedPriorityChangeIsToldApart() {
        #expect(AgentPriority.succeeded(0))
        #expect(!AgentPriority.succeeded(-1))
    }
}
