import Foundation
import os

/// Where a run keeps its files. `work` is wiped of leftovers at every start.
public struct RunPaths: Sendable {
    public var support: URL, logs: URL, work: URL
    public init(support: URL, logs: URL, work: URL) { self.support = support; self.logs = logs; self.work = work }

    var agentLock: URL { support.appendingPathComponent("locks/agent.lock") }
    /// The app reads this to see a run in progress. A crash leaves it behind, and the app checks the pid.
    var pidFile: URL { support.appendingPathComponent("agent.pid") }
    func pairLock(_ p: PairID) -> URL {
        support.appendingPathComponent("locks/\(p.set.uuidString)-\(p.destination.uuidString).lock")
    }
}

/// Runs every due pair, one at a time, through the flow in spec section 10. This owns the rule the
/// whole app depends on: the stored event ID moves only after sync and verification both passed
/// (`finish`), or when a batch held nothing but excluded paths, so nothing was owed. Anything else
/// (a failure, a kill, a held source) replays from where it was.
public final class RunCoordinator: Sendable {
    private static let log = Logger(subsystem: MirrorCore.bundleID, category: "RunCoordinator")
    private static let retention: TimeInterval = 30 * 86_400
    private static let notifyAfterFailures = 3
    private static let patience: TimeInterval = 86_400   // refused and stalled files
    static let freedSample = 20
    static let maxMismatched = 1_000
    /// Past this the list stops being cheap to save at every step, so a flag stands in for it.
    static let maxOwed = 5_000
    /// Each is a real download, so a long list is worked through over several wake-ups.
    static let maxDownloadsPerRun = 200
    /// Finder's droppings don't make a source any less empty.
    private static let noise: Set<String> = [".DS_Store", ".localized"]

    private let store: ConfigStore, records: RunRecordStore, problems: ProblemCenter
    private let rclone: any RcloneRunning, feed: any ChangeFeeding, verifier: Verifier
    private let pathGuard: PathGuard, detector: StackDetector, filters: FilterBuilder
    private let clock: @Sendable () -> Date
    private let sessions: @Sendable (Destination) -> any RunSession
    private let remote: any RemoteFileAccessing
    private let paths: RunPaths
    private let helperCheck: @Sendable () throws -> Void
    private let downloader: any ICloudDownloading

    public init(store: ConfigStore, records: RunRecordStore, problems: ProblemCenter, rclone: any RcloneRunning,
                feed: any ChangeFeeding, verifier: Verifier, guard pathGuard: PathGuard, detector: StackDetector,
                filters: FilterBuilder, clock: @escaping @Sendable () -> Date,
                sessions: @escaping @Sendable (Destination) -> any RunSession, remote: any RemoteFileAccessing,
                paths: RunPaths, helperCheck: @escaping @Sendable () throws -> Void = {},
                downloader: any ICloudDownloading = ICloudDownloader()) {
        self.store = store; self.records = records; self.problems = problems; self.rclone = rclone
        self.feed = feed; self.verifier = verifier; self.pathGuard = pathGuard; self.detector = detector
        self.filters = filters; self.clock = clock; self.sessions = sessions; self.remote = remote; self.paths = paths
        self.helperCheck = helperCheck; self.downloader = downloader
    }

    /// Another run holding the lock means leave quietly: no state, record or pid file is touched.
    /// False only when the agent itself couldn't run, which the record and a problem also say.
    @discardableResult
    public func runAll(command: RunCommand) async -> Bool {
        let lock = RunLock(url: paths.agentLock)
        switch lock.attempt() {
        case .acquired: break
        case .held: return true
        case .openFailed(let code):
            Self.log.error("cannot open the agent lock, errno \(code)")
            await report("Mirror could not open its run lock")
            return false
        }
        defer { lock.release() }
        writePID()
        defer { try? FileManager.default.removeItem(at: paths.pidFile) }

        // First of all, so a swapped rclone is caught before any Keychain read.
        do { try helperCheck() } catch {
            await report("The embedded rclone failed its signature check")
            return false
        }
        do { try RcloneSession.wipeLeftovers(in: paths.work) } catch { Self.log.error("wiping leftovers failed") }
        do { try await problems.retryPending() } catch { Self.log.error("retrying notifications failed") }
        let ran = await runPairs(command)
        prune()
        return ran
    }

    private func report(_ message: String) async {
        await AgentFailureReport.file(message, records: records, problems: problems, now: clock())
    }

    private func writePID() {
        do {
            try Data(String(ProcessInfo.processInfo.processIdentifier).utf8).write(to: paths.pidFile, options: .atomic)
        } catch {
            Self.log.error("cannot write the pid file")
        }
    }

    private func prune() {
        let cutoff = clock().addingTimeInterval(-Self.retention)
        do {
            try records.prune(olderThan: cutoff)
            try LogRotator.pruneRunFolders(paths.logs, olderThan: cutoff)
        } catch {
            Self.log.error("pruning failed")
        }
    }

    private func runPairs(_ command: RunCommand) async -> Bool {
        let sets: [BackupSet], destinations: [Destination]
        do {
            sets = try store.loadSets()
            destinations = try store.loadDestinations()
        } catch {
            Self.log.error("cannot read the configuration")
            await report("Mirror could not read its settings")
            return false
        }
        clear([.agentFailed], .agent)
        var pairs: [(PairID, DestinationKind, SetState)] = []
        for set in sets where command.setID == nil || command.setID == set.id {
            for id in set.destinationIDs {
                guard let destination = destinations.first(where: { $0.id == id }) else { continue }
                let pair = PairID(set: set.id, destination: id)
                // Ordering only. An unreadable state fails properly in `run`.
                pairs.append((pair, destination.kind, (try? store.state(for: pair)) ?? SetState()))
            }
        }
        var expired = Set<UUID>()
        for pair in RunPlanner.order(pairs) {
            if Task.isCancelled { break }
            guard let destination = destinations.first(where: { $0.id == pair.destination }) else { continue }
            switch await run(pair, destination: destination, command: command, expired: &expired) {
            case .carryOn: continue
            case .stop: return true
            case .agentFailed: return false
            }
        }
        return true
    }

    // MARK: One pair

    /// What the record will say. Filled in as the run goes, so a failure keeps what was learned.
    private struct Tally {
        var trigger = RunRecord.Trigger.schedule
        var scope = ""
        var summary = LogSummary()
        var filesChecked = 0
        var verification = ""
        var pending = 0, refused = 0
        var errors: [String] = []
        var status = RunRecord.Status.failed
        /// Raised once the run is over, so a slow notification never holds a session open.
        var notices: [(problem: Problem, pair: PairID, detail: String)] = []
    }

    private struct Job {
        var pair: PairID
        var set: BackupSet
        var destination: Destination
        var approved: Int?
        var profile: DestinationProfile
        var isLocal: Bool
    }

    /// What stops a run after it starts. Rclone's own text stays out of anything but the record.
    private enum Stop: Error {
        case rclone(RcloneResult.Outcome, [String])
        case verificationFailed(differences: Int)
        case changedDuringRun
        case stateNotSaved
        case iCloudSignedOut
        case markerNotLocal
    }

    /// How one pair's run leaves the rest. `stop` is a cancelled run. `agentFailed` also fails the agent.
    private enum PairEnd { case carryOn, stop, agentFailed }

    /// One folder's worth of work: the whole set, or one project.
    private struct Slice {
        var folder: String?
        var source: URL
        var destination: String
        var backupDir: String
        var filter: URL
        var logDir: URL
    }

    private func run(_ pair: PairID, destination: Destination, command: RunCommand, expired: inout Set<UUID>) async -> PairEnd {
        // Read here, not at the start: an earlier pair may have applied presets to this set.
        let found: BackupSet?
        do { found = try store.loadSets().first(where: { $0.id == pair.set }) } catch {
            await report("Mirror could not read its settings")
            return .agentFailed
        }
        guard let set = found else { return .carryOn }   // removed since the run began

        let started = clock()
        var tally = Tally()
        tally.trigger = command.force || command.approvedDeletions != nil ? .manual : .schedule
        func record() { write(tally, set: set, destination: destination, started: started) }

        let lock = RunLock(url: paths.pairLock(pair))
        switch lock.attempt() {
        case .acquired: break
        case .held: return .carryOn
        case .openFailed:
            tally.errors = ["This backup's lock could not be opened"]
            record()
            await raise(.repeatedFailures, pair, set, detail: "Mirror could not open this backup's lock")
            return .carryOn
        }
        defer { lock.release() }

        let loaded: SetState
        do { loaded = try store.state(for: pair) } catch {
            // Treating it as new would forget the file count and the event ID, so nothing runs.
            await raise(.repeatedFailures, pair, set, detail: "Mirror can't read what it saved about this backup")
            tally.errors = ["State file unreadable"]
            record()
            return .carryOn
        }
        if set.isPaused {
            tally.status = .skipped; tally.scope = "paused"
            record()
            return .carryOn
        }
        // Not wired in yet (Task 21's list). Treating it as local would put its files in the iCloud root.
        if destination.kind == .externalDrive {
            tally.status = .skipped; tally.scope = "external drive"
            record()
            return .carryOn
        }
        if destination.encrypted, !destination.recoveryKitConfirmed, !Self.isLocal(destination.kind) {
            tally.status = .skipped; tally.scope = "waiting for Recovery Kit"
            record()
            return .carryOn
        }

        let job = Job(pair: pair, set: set, destination: destination,
                      approved: loaded.heldDeletions > 0 ? command.approvedDeletions : nil,
                      profile: .profile(for: destination), isLocal: Self.isLocal(destination.kind))
        var state = loaded
        var end = PairEnd.carryOn
        if expired.contains(destination.id) {
            state.stoppedBy = .signInExpired
            tally.errors = ["Sign-in expired"]
            tally.notices.append((.signInExpired, pair, destination.name))
        } else {
            do {
                try await process(job, command: command, state: &state, tally: &tally)
            } catch {
                end = absorb(error, job, state: &state, tally: &tally, expired: &expired)
            }
        }
        if state != loaded, !save(state, pair), tally.status != .failed, tally.status != .verificationFailed {
            // The next run would act on the old state, so this run can't claim what it did.
            tally.status = .failed
            tally.errors.append("State could not be saved")
        }
        tally.pending = state.pendingUploads
        tally.refused = state.refusedSince.count
        if state.waitingForDownload > 0, tally.status != .verificationFailed {
            tally.verification = "Waiting for iCloud to download \(state.waitingForDownload) files to verify"
        }
        // Saved ahead of the record, so a kill between them can't leave a stop no one was told of.
        for notice in tally.notices { keep(notice.problem, notice.pair, set, detail: notice.detail) }
        record()
        for notice in tally.notices { await raise(notice.problem, notice.pair, set, detail: notice.detail) }
        return end
    }

    /// Exhaustive, so a new kind has to decide. An external drive will be local too.
    private static func isLocal(_ kind: DestinationKind) -> Bool {
        switch kind {
        case .iCloudFolder: true
        case .googleDrive, .oneDrive, .externalDrive: false
        }
    }

    private func process(_ job: Job, command: RunCommand, state: inout SetState, tally: inout Tally) async throws {
        var set = job.set
        let pair = job.pair

        // Everything but the claim, so nothing is ever written to a destination that isn't there.
        var guarded = state
        if job.approved != nil { guarded.lastFileCount = nil }   // the owner has seen this hold
        let sample = sampleCount(set.source)
        try pathGuard.validateRun(set, destination: job.destination, marker: RootMarker(sets: [set.id: set.name]),
                                  sampleFileCount: sample, state: guarded)
        clear([.permissionLost], pair)
        if state.stoppedBy == .permissionLost { state.stoppedBy = nil }

        let localContext = RcloneContext(configPath: "/dev/null", environment: [:])
        if job.isLocal {
            guard !job.destination.encrypted else { throw RcloneSessionError.encryptionNotSupported }
            try await confirmClaim(job, endpoint: pathGuard.backupRoot.path, context: localContext, files: LocalFiles(), state: &state)
        }

        refreshMismatches(job, set: set, state: &state)

        // Find changes, with no disk walk and no network when there are none.
        let batch = try await feed.changes(in: set.source, since: state.lastEventID)
        let wanted = command.force || job.approved != nil
        var projects: [DetectedProject]?
        var scope = RunScope.nothing
        if wanted {
            scope = .wholeSet
        } else if !batch.paths.isEmpty || batch.mustRescan {
            let found = try scan(&set, state: &state)
            projects = found
            let matcher = FilterMatcher(lines: filters.lines(for: set, projects: found, scope: nil))
            scope = ScopeMapper().scope(for: batch, root: set.source, isExcluded: matcher.isExcluded)
        }
        let plan = RunPlanner.plan(state: state, scope: scope, profile: job.profile, now: clock())
        if plan.isDailyPass, tally.trigger == .schedule { tally.trigger = .daily }

        if plan.scope == .nothing {
            // A cloud stop has to be disproved. Only this path skips the destination altogether.
            if state.stoppedBy != nil { try await reprove(job, state: &state) }
            // Only excluded paths changed, so nothing is owed and replaying them would just rescan.
            if !batch.paths.isEmpty { state.lastEventID = batch.latestEventID }
            try await reconcileUploads(job, set: set, state: &state, tally: &tally)
            // Nothing is outstanding, or the event ID would have replayed it.
            state.consecutiveFailures = 0
            state.syncIncomplete = false
            clear([.repeatedFailures], pair)
            tally.status = .skipped; tally.scope = "none"
            return
        }

        let detected = try projects ?? scan(&set, state: &state)
        var runScope = plan.scope
        if case .projects(let names) = runScope,
           !names.allSatisfy({ Self.isRealFolder(set.source.appendingPathComponent($0)) }) {
            runScope = .wholeSet   // gone, or replaced by a link or a file since the event
        }
        tally.scope = Self.describe(runScope)

        // Before anything can fail or be killed, so the reason for this run isn't lost with it.
        if runScope == .wholeSet { state.wholeSetOwed = true }
        try persist(state, pair)

        var session: (any RunSession)?
        var endpoint = pathGuard.backupRoot.path, context = localContext
        if !job.isLocal {
            let opened = sessions(job.destination)
            (endpoint, context) = try opened.open()
            session = opened
        }
        do {
            if !job.isLocal {
                try await confirmClaim(job, endpoint: endpoint, context: context, files: remote, state: &state)
            }
            try await work(job, set: set, command: command, plan: plan, scope: runScope, sample: sample, batch: batch,
                           projects: detected, endpoint: endpoint, context: context, state: &state, tally: &tally)
        } catch {
            closeSession(session)
            throw error
        }
        closeSession(session)
    }

    /// Proves a cloud destination is reachable and still ours, for a stop with no work to do.
    private func reprove(_ job: Job, state: inout SetState) async throws {
        let session = sessions(job.destination)
        let (endpoint, context) = try session.open()
        do {
            try await confirmClaim(job, endpoint: endpoint, context: context, files: remote, state: &state)
        } catch {
            closeSession(session)
            throw error
        }
        closeSession(session)
    }

    private func closeSession(_ session: (any RunSession)?) {
        do { try session?.close() } catch { Self.log.error("closing a session failed") }
    }

    private func work(_ job: Job, set: BackupSet, command: RunCommand, plan: RunPlan, scope: RunScope, sample: Int,
                      batch: ChangeBatch, projects: [DetectedProject], endpoint: String, context: RcloneContext,
                      state: inout SetState, tally: inout Tally) async throws {
        let pair = job.pair
        let now = clock()
        let stamp = Self.stamp(now)
        let runDir = try RcloneTool.makePrivateDirectory(in: paths.work)
        defer { try? FileManager.default.removeItem(at: runDir) }
        let slices = try makeSlices(job, set: set, scope: scope, projects: projects, endpoint: endpoint, stamp: stamp, runDir: runDir)
        // What earlier runs left unproven. Kept apart, as `owe` may give the saved list up to the flag.
        let carried = Array(Set(state.verifyOwed).union(state.mismatched.keys))

        func request(_ s: Slice, mode: SyncMode, dryRun: Bool) -> SyncRequest {
            SyncRequest(source: s.source, destination: s.destination, backupDir: s.backupDir, filterFile: s.filter,
                        logFile: s.logDir.appendingPathComponent(dryRun ? "dry-run.log" : "sync.log"), mode: mode,
                        profile: job.profile, context: context, dryRun: dryRun, fullSpeed: command.fullSpeed)
        }

        // Mass-deletion check. -1 is rclone's "no limit": the dry run must see them all to count them.
        var deletions: [String] = []
        var planned: [String] = []
        for slice in slices {
            let result = try await rclone.sync(request(slice, mode: .mirror(maxDelete: -1), dryRun: true))
            guard result.outcome == .success else { throw Stop.rclone(result.outcome, result.summary.errors) }
            deletions += result.summary.deleted.map { Self.inSet($0, slice) }
            planned += Self.touched(by: result.summary, planned: true).map { Self.inSet($0, slice) }
        }
        let countable = DeletionGate.countable(deletions)
        var decision = DeletionGate.decide(deletions: deletions, totalFiles: state.lastFileCount ?? 0,
                                           policy: set.deletion, approvedDeletions: job.approved)
        // A hold ends with the owner's approval or with nothing left to delete, never by shrinking.
        if state.heldDeletions > 0, countable > 0, job.approved.map({ countable > $0 }) ?? true {
            decision = .hold(count: countable)
        }
        // An empty source deleting anything is never routine, whatever the count says.
        if sample == 0, !deletions.isEmpty, job.approved.map({ deletions.count > $0 }) ?? true {
            decision = .hold(count: deletions.count)
        }
        let mode: SyncMode
        var holding = false
        switch decision {
        case .proceed(let maxDelete):
            mode = .mirror(maxDelete: maxDelete)
        case .hold(let count):
            mode = .copyOnly
            holding = true
            state.heldDeletions = count
            tally.notices.append((.deletionsHeld, pair, "\(count) deletions held"))
            keep(.deletionsHeld, pair, set, detail: "\(count) deletions held")   // no posting with a session open
        }

        // Saved first, so a kill during the sync can't lose a hold or what it was about to copy.
        owe(planned, state: &state)
        try persist(state, pair)

        var perSlice: [LogSummary] = []
        for slice in slices {
            let result = try await rclone.sync(request(slice, mode: mode, dryRun: false))
            Self.add(result.summary, to: &tally.summary)
            perSlice.append(result.summary)
            // Whatever came of it: a failed sync can still have copied files.
            owe(Self.touched(by: result.summary).map { Self.inSet($0, slice) }, state: &state)
            try persist(state, pair)
            switch result.outcome {
            case .success:
                continue
            case .partial:
                state.syncIncomplete = true
                state.consecutiveFailures = 0
                clear([.repeatedFailures], pair)
                tally.status = .partial
                return
            case .safetyStop:
                state.heldDeletions = max(state.heldDeletions, deletions.count, 1)
                tally.notices.append((.deletionsHeld, pair, "\(state.heldDeletions) deletions held"))
                tally.status = .held
                return
            default:
                throw Stop.rclone(result.outcome, result.summary.errors)
            }
        }

        // Verify. Held files are extras in the mirror on purpose, so the check runs one way.
        var verified = VerifyResult(differences: 0, audit: AuditResult(pending: [], refused: []))
        let wholePass = plan.isDailyPass && scope == .wholeSet
        let matcher = FilterMatcher(lines: filters.lines(for: set, projects: projects, scope: nil))
        // A deep check hashes every file on disk, so a Quick hash beside it would do the work twice.
        let deepDue = plan.isDeepDue && plan.isDailyPass && !holding
        let deepFollows = scope == .wholeSet && (state.hashWholeSet || deepDue)
        var awaitingDeep: (slice: Slice, result: VerifyResult, names: [String])?
        for (slice, summary) in zip(slices, perSlice) {
            // Carried files that have since left the source, or the rules, have nothing to prove.
            let owed = Self.within(slice, carried).filter {
                Self.existsInSource($0, slice.source) && !matcher.isExcluded(Self.inSet($0, slice))
            }
            let names = Array(Set(Self.touched(by: summary) + owed)).sorted()
            let result = try await verifier.quick(source: slice.source, destination: slice.destination, profile: job.profile,
                                                  context: context, filter: slice.filter, copied: names, oneWay: holding,
                                                  logDir: slice.logDir, auditWholeMirror: wholePass, hashCopied: !deepFollows)
            Self.merge(result, of: slice, into: &verified)
            guard result.checksClean else { continue }   // a mismatch stays owed, or the next run would call it clean
            // With a deep check to come nothing has been hashed yet, so nothing is proven yet either.
            if deepFollows { awaitingDeep = (slice, result, names); continue }
            prove(slice, result, unhashed: result.skippedFreed, set: set, state: &state)
            try persist(state, pair)
        }
        tally.filesChecked = verified.matchingFiles
        var deepRan = false
        if let slice = slices.first, scope == .wholeSet, state.hashWholeSet || deepDue {
            let deep = try await verifier.deep(source: slice.source, destination: slice.destination, profile: job.profile,
                                               context: context, filter: slice.filter, sampleFreed: Self.freedSample,
                                               logDir: slice.logDir, oneWay: holding)
            verified.differences += deep.differences
            verified.checksClean = verified.checksClean && deep.checksClean
            verified.differingPaths += deep.differingPaths
            if verified.checksClean {
                // Lowered first, so whatever the steps below can't hold raises it again and it stays up.
                state.hashWholeSet = false
                if let awaitingDeep {
                    // Both lists use rclone's names, so a link is covered by the deep hash of `x.rclonelink`.
                    // What the list left out, a sampled-out evicted file say, had the size check alone.
                    let unhashed = deep.hashedPaths.map { hashed in awaitingDeep.names.filter { !hashed.contains($0) } } ?? []
                    prove(awaitingDeep.slice, awaitingDeep.result, unhashed: unhashed, set: set, state: &state)
                }
                track(deep.audit, mirror: mirrorRoot(set), state: &state)
            }
            deepRan = true
        }
        guard verified.checksClean else {
            tally.verification = "Quick check found \(verified.differences) differences"
            // A deep check can name files no earlier run owed. What's gone from the source is the sync's to remove.
            let named = Array(Set(verified.differingPaths).filter { Self.existsInSource($0, set.source) })
            if await changedDuringRun(set, verified, since: batch.latestEventID) {
                owe(named, state: &state)
                throw Stop.changedDuringRun
            }
            // Recorded first: `owe` keeps what's recorded through an overflow, and only that.
            recordMismatches(named, job, set: set, state: &state)
            owe(named, state: &state)
            throw Stop.verificationFailed(differences: verified.differences)
        }
        tally.verification = deepRan ? "Quick and deep checks passed" : "Quick check passed"

        try await reconcileUploads(job, set: set, state: &state, tally: &tally)
        finish(job, plan: plan, scope: scope, batch: batch, verified: verified, holding: holding, deepRan: deepRan, state: &state)
        tally.status = holding ? .held : (verified.backedUp && state.isBackedUp ? .success : .partial)
    }

    /// Adds to what's owed. Past the bound the flag takes over from the list, except for a recorded
    /// mismatch, which only the list can speak for. The flag is the record of an overflow, so no
    /// caller has to carry one.
    private func owe(_ paths: [String], state: inout SetState) {
        let all = Set(state.verifyOwed).union(paths).union(state.mismatched.keys)
        guard all.count > Self.maxOwed else {
            state.verifyOwed = all.sorted()
            return
        }
        state.hashWholeSet = true
        state.verifyOwed = state.mismatched.keys.sorted()
    }

    /// Past the bound the flag's whole-set hash finds what's on disk again once the list drains, and
    /// the owner is told, since an evicted file left off the list has nothing else speaking for it.
    private func recordMismatches(_ paths: [String], _ job: Job, set: BackupSet, state: inout SetState) {
        let now = clock(), mirror = mirrorRoot(set)
        var overflowed = false
        for path in paths.sorted() where state.mismatched[path] == nil {
            guard state.mismatched.count < Self.maxMismatched else { overflowed = true; continue }
            state.mismatched[path] = Mismatch(since: now, evicted: job.isLocal && verifier.isFreed(mirror.appendingPathComponent(path)))
        }
        guard overflowed else { return }
        state.hashWholeSet = true
        restate(.verificationFailed, job, set: set, detail: "More than \(Self.maxMismatched.formatted()) files differ, so not all of them are listed")
    }

    /// A slice passed its checks: what it owed is proven, and its audit carries on in the upload
    /// tracking. `unhashed` is what no hash reached. A recorded mismatch among them stays, and so
    /// does a file on disk, which the next run can hash. An evicted one is done: its size check
    /// passed, and iCloud only frees what it has uploaded. A file the audit couldn't find stays too.
    private func prove(_ slice: Slice, _ result: VerifyResult, unhashed: [String], set: BackupSet, state: inout SetState) {
        let mirror = mirrorRoot(set)
        let prefix = slice.folder.map { $0 + "/" } ?? ""
        let names = unhashed.map { Self.inSet($0, slice) }
        let open = Set(names.filter { state.mismatched[$0] != nil })
        state.verifyOwed.removeAll { $0.hasPrefix(prefix) }
        state.mismatched = state.mismatched.filter { !$0.key.hasPrefix(prefix) || open.contains($0.key) }
        track(result.audit, mirror: mirror, state: &state)
        let root = mirror.path + "/"
        let lost = result.audit.missing.map { $0.hasPrefix(root) ? String($0.dropFirst(root.count)) : $0 }
        let missing = Self.within(slice, lost).filter { Self.existsInSource($0, slice.source) }.map { Self.inSet($0, slice) }
        let onDisk = names.filter { !open.contains($0) && !verifier.isFreed(mirror.appendingPathComponent($0)) }
        owe(missing + onDisk, state: &state)
    }

    /// One flag read per recorded mismatch, no walk. One that came back is hashed by this or the next run.
    private func refreshMismatches(_ job: Job, set: BackupSet, state: inout SetState) {
        guard job.isLocal else { return }
        let mirror = mirrorRoot(set)
        for path in state.mismatched.keys {
            state.mismatched[path]?.evicted = verifier.isFreed(mirror.appendingPathComponent(path))
        }
        let waiting = state.mismatched.filter(\.value.evicted).keys.sorted()
        for path in waiting {
            do { try downloader.requestDownload(of: mirror.appendingPathComponent(path)) } catch {
                Self.log.error("iCloud refused a download request")
            }
        }
    }

    /// Takes on an audit's findings without re-reading anything. `reconcileUploads` applies the rules.
    private func track(_ audit: AuditResult, mirror: URL, state: inout SetState) {
        let root = mirror.path + "/"
        func relative(_ path: String) -> String { path.hasPrefix(root) ? String(path.dropFirst(root.count)) : path }
        let now = clock()
        state.uploadingPaths = Set(state.uploadingPaths).union(audit.pending.map(relative)).sorted()
        state.pendingUploads = state.uploadingPaths.count
        if !state.uploadingPaths.isEmpty, state.uploadingSince == nil { state.uploadingSince = now }
        for path in audit.refused.map(relative) where state.refusedSince[path] == nil { state.refusedSince[path] = now }
    }

    private func mirrorRoot(_ set: BackupSet) -> URL {
        pathGuard.backupRoot.appendingPathComponent(MirrorPaths.mirrorPath(set), isDirectory: true)
    }

    /// The only place the event ID moves after work. Sync and verification have both passed.
    private func finish(_ job: Job, plan: RunPlan, scope: RunScope, batch: ChangeBatch, verified: VerifyResult,
                        holding: Bool, deepRan: Bool, state: inout SetState) {
        let now = clock()
        state.lastEventID = batch.latestEventID
        state.lastFinished = now
        state.consecutiveFailures = 0
        state.wholeSetOwed = false
        state.syncIncomplete = false
        if plan.isDailyPass { state.lastFullPass = now }
        if scope == .wholeSet {
            state.lastFileCount = verified.matchingFiles
            if state.lastDeepCheck == nil { state.lastDeepCheck = now }
        }
        if deepRan { state.lastDeepCheck = now }
        var solved: [Problem] = [.repeatedFailures, .signInExpired]
        // A mismatch stands until that file's own hash passes, however clean the rest of the run was.
        if state.mismatched.isEmpty, !state.hashWholeSet { solved.append(.verificationFailed) }
        if !holding {
            state.heldDeletions = 0
            solved.append(.deletionsHeld)
        }
        clear(solved, job.pair)
    }

    private func makeSlices(_ job: Job, set: BackupSet, scope: RunScope, projects: [DetectedProject], endpoint: String,
                            stamp: String, runDir: URL) throws -> [Slice] {
        let folders: [String?]
        switch scope {
        case .projects(let names): folders = names
        case .wholeSet, .nothing: folders = [nil]
        }
        let mirror = Self.join(endpoint, MirrorPaths.mirrorPath(set))
        let archive = Self.join(endpoint, MirrorPaths.archivePath(set, stamp: stamp))
        let logRoot = paths.logs.appendingPathComponent(
            "\(stamp)-\(job.pair.set.uuidString.prefix(8))-\(job.pair.destination.uuidString.prefix(8))", isDirectory: true)
        var out: [Slice] = []
        for (index, folder) in folders.enumerated() {
            let filter = runDir.appendingPathComponent("filter-\(index).txt")
            try filters.write(filters.lines(for: set, projects: projects, scope: folder), to: filter)
            let logDir = logRoot.appendingPathComponent(String(index), isDirectory: true)
            try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
            let slice = Slice(folder: folder,
                              source: folder.map { set.source.appendingPathComponent($0, isDirectory: true) } ?? set.source,
                              destination: folder.map { "\(mirror)/\($0)" } ?? mirror,
                              backupDir: folder.map { "\(archive)/\($0)" } ?? archive,
                              filter: filter, logDir: logDir)
            if job.isLocal {
                // Resolves links, so a mirror folder that became a link can't lead rclone out of the root.
                try pathGuard.assertInsideRoot(URL(fileURLWithPath: slice.destination))
                try pathGuard.assertInsideRoot(URL(fileURLWithPath: slice.backupDir))
            }
            out.append(slice)
        }
        return out
    }

    /// Spec section 11: a file that changed under the run is retried by the next one, not an alarm.
    /// Every difference has to be accounted for, by count and by path, or a real mismatch could
    /// hide behind unrelated activity.
    private func changedDuringRun(_ set: BackupSet, _ verified: VerifyResult, since: UInt64) async -> Bool {
        let differing = verified.differingPaths
        guard !differing.isEmpty, differing.count >= verified.differences,
              let later = try? await feed.changes(in: set.source, since: since) else { return false }
        return Set(differing).isSubset(of: ScopeMapper.relative(later.paths, to: set.source))
    }

    // MARK: Claiming a destination

    private static func join(_ endpoint: String, _ path: String) -> String {
        endpoint.hasSuffix(":") || endpoint.hasSuffix("/") ? endpoint + path : "\(endpoint)/\(path)"
    }

    /// A pair that has run before never re-claims: a lost marker means something is wrong out there.
    /// A new pair claims only where nothing of anyone else's can be overwritten, and only after
    /// `validateNewSet` passed. A marker that won't parse is never replaced.
    private func confirmClaim(_ job: Job, endpoint: String, context: RcloneContext, files: any RemoteFileAccessing,
                              state: inout SetState) async throws {
        let set = job.set
        let path = Self.join(endpoint, RootMarker.fileName)
        // Reading an evicted marker would wait on a download, and this runs at every wake-up.
        if job.destination.kind == .iCloudFolder, verifier.isFreed(URL(fileURLWithPath: path)) {
            try await requireICloud(job, at: URL(fileURLWithPath: path))
            guard Self.hasRun(state) else {
                try? downloader.requestDownload(of: URL(fileURLWithPath: path))
                throw Stop.markerNotLocal
            }
            clear([.destinationMissing, .signInExpired, .iCloudUnavailable], job.pair)
            state.stoppedBy = nil
            return
        }
        var marker: RootMarker?
        if let data = try await files.read(path, context: context) {
            guard let parsed = try? JSONDecoder().decode(RootMarker.self, from: data) else { throw GuardFailure.destinationUnclaimed }
            marker = parsed
            // Signing out can leave a local copy of the folder behind, marker included.
            try await requireICloud(job, at: URL(fileURLWithPath: path))
        }
        if marker?.claims(set.id) != true {
            guard !Self.hasRun(state) else { throw GuardFailure.destinationUnclaimed }
            let others = try store.loadSets().filter { $0.id != set.id }
            try pathGuard.validateNewSet(set, existing: others)
            if marker == nil, let entries = try await files.list(endpoint, context: context),
               entries.contains(where: { !Self.noise.contains($0) }) {
                throw GuardFailure.destinationUnclaimed
            }
            let taken = try await files.list(Self.join(endpoint, "Sets"), context: context) ?? []
            let name = set.name.lowercased()
            if taken.contains(where: { $0.lowercased() == name || $0.lowercased() == name + "/" }) {
                throw GuardFailure.destinationUnclaimed
            }
            try await requireICloud(job, at: pathGuard.backupRoot.deletingLastPathComponent())
            var claimed = marker ?? RootMarker()
            claimed.sets[set.id] = set.name
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try await files.write(try encoder.encode(claimed), to: path, context: context)
            marker = claimed
        }
        try pathGuard.validateRun(set, destination: job.destination, marker: marker,
                                  sampleFileCount: 1, state: SetState())
        clear([.destinationMissing, .signInExpired, .iCloudUnavailable], job.pair)
        state.stoppedBy = nil
    }

    private static func hasRun(_ state: SetState) -> Bool {
        state.lastFinished != nil || state.lastEventID != nil || state.lastFullPass != nil
    }

    /// One resource read. Measured in a real iCloud Drive: the folder and a marker are ubiquitous from
    /// the moment they're written, so "not ubiquitous" means iCloud has let go of this folder. The
    /// agent has no iCloud entitlement, so `ubiquityIdentityToken` can't be relied on here.
    private func requireICloud(_ job: Job, at url: URL) async throws {
        guard job.destination.kind == .iCloudFolder else { return }
        // Nil is a failed read, which proves nothing. Only a clear "no" stops the pair.
        if await verifier.ubiquity(of: url) == false { throw Stop.iCloudSignedOut }
    }

    // MARK: Projects

    /// Finds projects, and applies the presets of any that arrived since the last scan. The first
    /// scan only takes note: the owner chose those presets in the preview.
    private func scan(_ set: inout BackupSet, state: inout SetState) throws -> [DetectedProject] {
        let found = detector.detect(in: set.source)
        let names = found.map(\.relativePath).sorted()
        guard let known = state.knownProjects else {
            state.knownProjects = names
            return found
        }
        let fresh = found.filter { !known.contains($0.relativePath) }
        let added = fresh.reduce(into: Set<String>()) { $0.formUnion($1.presetIDs) }.subtracting(set.presets)
        if !added.isEmpty {
            var sets = try store.loadSets()
            if let index = sets.firstIndex(where: { $0.id == set.id }) {
                sets[index].presets.formUnion(added)
                try store.saveSets(sets)
            }
            set.presets.formUnion(added)
        }
        state.knownProjects = names   // last, so a failed save finds these projects new next time
        return found
    }

    // MARK: Uploads

    /// Takes a fresh look at files pending or refused, then applies the 24-hour rules. A gone file
    /// drops out, so short-lived temp files never reach an alert.
    private func reconcileUploads(_ job: Job, set: BackupSet, state: inout SetState, tally: inout Tally) async throws {
        guard job.isLocal else { return }
        guard !state.uploadingPaths.isEmpty || !state.refusedSince.isEmpty else {
            clear([.uploadStalled, .fileRefused], job.pair)
            return
        }
        let now = clock()
        let mirror = mirrorRoot(set)
        let prefix = mirror.path + "/"
        func relative(_ path: String) -> String { path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path }

        let tracked = Set(state.uploadingPaths).union(state.refusedSince.keys)
        let again = try await verifier.audit(tracked.sorted().map { mirror.appendingPathComponent($0) })
        let pending = Set(again.pending.map(relative))
        // Accepting a refused file adds an exclude rule, which ends its claim on "Backed Up".
        let rules = FilterMatcher(lines: filters.lines(for: set, projects: [], scope: nil))
        let refused = Set(again.refused.map(relative)).filter { !rules.isExcluded($0) }

        let moved = !Set(state.uploadingPaths).isSubset(of: pending)
        state.uploadingSince = pending.isEmpty ? nil : (moved ? now : state.uploadingSince ?? now)
        state.uploadingPaths = pending.sorted()
        state.pendingUploads = pending.count
        state.refusedSince = Dictionary(uniqueKeysWithValues: refused.map { ($0, state.refusedSince[$0] ?? now) })

        if let since = state.uploadingSince, now.timeIntervalSince(since) > Self.patience {
            tally.notices.append((.uploadStalled, job.pair, "\(pending.count) files waiting for over a day"))
        } else {
            clear([.uploadStalled], job.pair)
        }
        let overdue = state.refusedSince.filter { now.timeIntervalSince($0.value) > Self.patience }.keys.sorted()
        state.reviewItems.removeAll { $0.kind == .refusedByICloud && !overdue.contains($0.path) }
        for path in overdue where !state.reviewItems.contains(where: { $0.kind == .refusedByICloud && $0.path == path }) {
            state.reviewItems.append(ReviewItem(id: "refused:\(path)", path: path, kind: .refusedByICloud))
        }
        if let first = overdue.first {
            tally.notices.append((.fileRefused, job.pair, overdue.count == 1 ? first : "\(first) and \(overdue.count - 1) more"))
        } else {
            clear([.fileRefused], job.pair)
        }
    }

    // MARK: Failures

    /// Turns whatever stopped a run into state, a record and at most one alert. The event ID stays
    /// put on every path through here.
    private func absorb(_ error: any Error, _ job: Job, state: inout SetState, tally: inout Tally,
                        expired: inout Set<UUID>) -> PairEnd {
        let (pair, set) = (job.pair, job.set)
        func stop(_ problem: Problem, _ message: String, detail: String) {
            state.stoppedBy = problem
            tally.errors = [message]
            tally.notices.append((problem, pair, detail))
        }
        func signInExpired() {
            expired.insert(job.destination.id)
            // Rclone's text can quote what the token endpoint said, so it stays out.
            stop(.signInExpired, "Sign-in expired", detail: job.destination.name)
        }
        func iCloudStopped() {
            stop(.iCloudUnavailable, "iCloud Drive is unavailable", detail: "Backups are paused until it's back. Nothing was deleted.")
        }
        switch error {
        case is CancellationError:
            tally.errors = ["Stopped before finishing"]
            return .stop
        case let failure as GuardFailure:
            switch failure {
            case .iCloudUnavailable:
                iCloudStopped()
            case .sourceUnreadable:
                stop(.permissionLost, "Source can't be read", detail: set.source.path)
            case .sourceMissing where Self.isPermissionDenied(set.source):
                stop(.permissionLost, "Source can't be read", detail: set.source.path)
            case .sourceSuspiciouslyEmpty(_, let last):
                state.heldDeletions = max(state.heldDeletions, last)
                tally.status = .held
                tally.errors = ["Source is empty"]
                tally.notices.append((.deletionsHeld, pair, "the source folder is empty, so nothing was changed"))
            case .destinationUnclaimed:
                stop(.destinationMissing, "Destination isn't claimed by this set", detail: job.destination.name)
            default:
                fail("\(failure)", job, state: &state, tally: &tally)
            }
        case Stop.rclone(.authExpired, _), VerifyError.checkDidNotComplete(.authExpired), RemoteFileError.authExpired:
            signInExpired()
        case RcloneSessionError.notSignedIn, RcloneSessionError.invalidSignIn:
            signInExpired()
        case AgentFailure.untrustedHelper:
            tally.errors = ["The embedded rclone failed its signature check"]
            tally.notices.append((.agentFailed, .agent, "The embedded rclone failed its signature check"))
            return .agentFailed
        case Stop.rclone(.partial, _):
            // The dry run hit the time limit or Google's upload limit. Nothing changed, so this
            // is a resume, not a failure.
            state.syncIncomplete = true
            tally.status = .partial
        case Stop.rclone(_, let errors):
            let scrubbed = errors.prefix(20).map(RcloneLogParser.scrub)
            fail(scrubbed.first ?? "rclone failed", job, state: &state, tally: &tally)
            tally.errors = scrubbed
        case Stop.verificationFailed(let differences):
            state.consecutiveFailures += 1
            tally.status = .verificationFailed
            tally.errors = ["\(differences) differences found"]
            tally.notices.append((.verificationFailed, pair, "\(differences) differences found"))
        case Stop.changedDuringRun:
            fail("Files changed during the run", job, state: &state, tally: &tally)
        case Stop.iCloudSignedOut:
            stop(.iCloudUnavailable, "iCloud Drive may be signed out",
                 detail: "iCloud Drive may be signed out, so backups are paused. Nothing was deleted.")
        case Stop.markerNotLocal:
            // Nothing is wrong: a new pair needs the marker's contents, and iCloud is fetching them.
            tally.status = .skipped; tally.scope = "waiting for iCloud to download the marker"
        case Stop.stateNotSaved:
            fail("State could not be saved", job, state: &state, tally: &tally)
        case VerifyError.mirrorUnreadable:
            state.consecutiveFailures += 1
            tally.status = .verificationFailed
            tally.errors = ["Mirror can't be read"]
            tally.notices.append((.verificationFailed, pair, "the mirror can't be read"))
        case let failure as VerifyError:
            fail("\(failure)", job, state: &state, tally: &tally)
        case let failure as RcloneSessionError:
            fail("\(failure)", job, state: &state, tally: &tally)
        case let failure as RemoteFileError:
            fail("\(failure)", job, state: &state, tally: &tally)
        default:
            // Arbitrary errors could describe anything, so they stay out of the record.
            fail("Run failed", job, state: &state, tally: &tally)
        }
        return .carryOn
    }

    private func fail(_ message: String, _ job: Job, state: inout SetState, tally: inout Tally) {
        state.consecutiveFailures += 1
        tally.errors = [message]
        tally.status = .failed
        if state.consecutiveFailures >= Self.notifyAfterFailures {
            tally.notices.append((.repeatedFailures, job.pair, "\(state.consecutiveFailures) failed runs in a row"))
        }
    }

    private func raise(_ problem: Problem, _ pair: PairID, _ set: BackupSet, detail: String) async {
        do { try await problems.raise(problem, pair: pair, setName: set.name, detail: detail) } catch {
            Self.log.error("could not record a problem")
        }
    }

    /// Saves a problem without posting it, for when a notification mustn't delay anything.
    private func keep(_ problem: Problem, _ pair: PairID, _ set: BackupSet, detail: String) {
        do { try problems.store(problem, pair: pair, setName: set.name, detail: detail) } catch {
            Self.log.error("could not record a problem")
        }
    }

    /// For news an open alert doesn't carry. Saved now, and posted with the run's other notices.
    private func restate(_ problem: Problem, _ job: Job, set: BackupSet, detail: String) {
        do { try problems.restate(problem, pair: job.pair, setName: set.name, detail: detail) } catch {
            Self.log.error("could not record a problem")
        }
    }

    private func clear(_ list: [Problem], _ pair: PairID) {
        for problem in list {
            do { try problems.clear(problem, pair: pair) } catch { Self.log.error("could not clear a problem") }
        }
    }

    @discardableResult
    private func save(_ state: SetState, _ pair: PairID) -> Bool {
        do { try store.save(state, for: pair); return true } catch {
            Self.log.error("could not save state")
            return false
        }
    }

    /// For saves a later step depends on: without them a kill would forget what's under way.
    private func persist(_ state: SetState, _ pair: PairID) throws {
        guard save(state, pair) else { throw Stop.stateNotSaved }
    }

    private func write(_ tally: Tally, set: BackupSet, destination: Destination, started: Date) {
        let s = tally.summary
        let record = RunRecord(setID: set.id, setName: set.name, destinationID: destination.id, destinationName: destination.name,
                               start: started, end: clock(), trigger: tally.trigger, scope: tally.scope,
                               filesChecked: tally.filesChecked, copied: s.copied.count, renamed: s.renamed.count,
                               deleted: s.deleted.count, archived: s.archived.count, bytes: s.bytes,
                               verification: tally.verification, pendingUploads: tally.pending, refused: tally.refused,
                               errors: tally.errors, status: tally.status)
        do { try records.append(record) } catch { Self.log.error("could not write a run record") }
    }

    // MARK: Small helpers

    /// A cheap look at the top level, enough to tell a source that's there from one that isn't.
    private func sampleCount(_ source: URL) -> Int {
        ((try? FileManager.default.contentsOfDirectory(atPath: source.path)) ?? []).filter { !Self.noise.contains($0) }.count
    }

    private static func isPermissionDenied(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) != 0 && (errno == EPERM || errno == EACCES)
    }

    /// lstat, so a link to a folder doesn't pass: rclone would otherwise replace it in the mirror.
    private static func isRealFolder(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
    }

    private static func renameTarget(_ entry: String) -> String? {
        entry.range(of: " -> ", options: .backwards).map { String(entry[$0.upperBound...]) }
    }

    /// Paths a sync wrote, or in a dry run would write.
    private static func touched(by s: LogSummary, planned: Bool = false) -> [String] {
        (planned ? s.planned : s.copied) + s.renamed.compactMap(renameTarget)
    }

    /// A slice-relative path as a set-relative one.
    private static func inSet(_ path: String, _ slice: Slice) -> String {
        slice.folder.map { "\($0)/\(path)" } ?? path
    }

    /// The set-relative `paths` under a slice, relative to it.
    private static func within(_ slice: Slice, _ paths: [String]) -> [String] {
        guard let folder = slice.folder else { return paths }
        return paths.filter { $0.hasPrefix(folder + "/") }.map { String($0.dropFirst(folder.count + 1)) }
    }

    private static func exists(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0
    }

    /// What a local mirror calls a path from rclone's log.
    private static func mirrorName(_ path: String) -> String {
        path.hasSuffix(".rclonelink") ? String(path.dropLast(".rclonelink".count)) : path
    }

    /// Rclone's `x.rclonelink` is a link called `x` in the source.
    private static func existsInSource(_ path: String, _ source: URL) -> Bool {
        exists(source.appendingPathComponent(mirrorName(path)))
    }

    private static func describe(_ scope: RunScope) -> String {
        switch scope {
        case .nothing: "none"
        case .wholeSet: "whole set"
        case .projects(let names): names.joined(separator: ", ")
        }
    }

    /// Sortable, and safe as a folder name on every destination.
    private static func stamp(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(timeZone: .gmt).year().month().day().time(includingFractionalSeconds: false)
            .dateSeparator(.omitted).timeSeparator(.omitted))
    }

    private static func add(_ s: LogSummary, to total: inout LogSummary) {
        total.copied += s.copied; total.deleted += s.deleted; total.archived += s.archived
        total.renamed += s.renamed; total.errors += s.errors; total.bytes += s.bytes
    }

    private static func merge(_ r: VerifyResult, of slice: Slice, into total: inout VerifyResult) {
        total.differences += r.differences
        total.differingPaths += r.differingPaths.map { inSet($0, slice) }
        total.checksClean = total.checksClean && r.checksClean
        total.matchingFiles += r.matchingFiles
        total.audit.pending += r.audit.pending
        total.audit.refused += r.audit.refused
        total.audit.missing += r.audit.missing
    }
}

/// The agent itself failed to run. Nothing else would ever say so.
public enum AgentFailureReport {
    private static let log = Logger(subsystem: MirrorCore.bundleID, category: "AgentFailureReport")

    public static func file(_ message: String, records: RunRecordStore, problems: ProblemCenter, now: Date) async {
        let pair = PairID.agent
        let record = RunRecord(setID: pair.set, setName: "Mirror", destinationID: pair.destination, destinationName: "",
                               start: now, end: now, trigger: .schedule, scope: "", errors: [message], status: .failed)
        do { try records.append(record) } catch { log.error("could not write a run record") }
        do { try await problems.raise(.agentFailed, pair: pair, setName: "Mirror", detail: message) } catch {
            log.error("could not record a problem")
        }
    }
}
