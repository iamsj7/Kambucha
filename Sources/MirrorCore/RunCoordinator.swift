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
/// whole app depends on: the stored event ID moves only in `finish`, after sync and verification
/// both passed, so anything else (a failure, a kill, a held source) replays from where it was.
public final class RunCoordinator: Sendable {
    private static let log = Logger(subsystem: MirrorCore.bundleID, category: "RunCoordinator")
    private static let retention: TimeInterval = 30 * 86_400
    private static let notifyAfterFailures = 3
    private static let patience: TimeInterval = 86_400   // refused and stalled files
    private static let freedSample = 20
    /// Finder's droppings don't make a source any less empty.
    private static let noise: Set<String> = [".DS_Store", ".localized"]

    private let store: ConfigStore, records: RunRecordStore, problems: ProblemCenter
    private let rclone: any RcloneRunning, feed: any ChangeFeeding, verifier: Verifier
    private let pathGuard: PathGuard, detector: StackDetector, filters: FilterBuilder
    private let clock: @Sendable () -> Date
    private let sessions: @Sendable (Destination) -> any RunSession
    private let remote: any RemoteFileAccessing
    private let paths: RunPaths

    public init(store: ConfigStore, records: RunRecordStore, problems: ProblemCenter, rclone: any RcloneRunning,
                feed: any ChangeFeeding, verifier: Verifier, guard pathGuard: PathGuard, detector: StackDetector,
                filters: FilterBuilder, clock: @escaping @Sendable () -> Date,
                sessions: @escaping @Sendable (Destination) -> any RunSession, remote: any RemoteFileAccessing,
                paths: RunPaths) {
        self.store = store; self.records = records; self.problems = problems; self.rclone = rclone
        self.feed = feed; self.verifier = verifier; self.pathGuard = pathGuard; self.detector = detector
        self.filters = filters; self.clock = clock; self.sessions = sessions; self.remote = remote; self.paths = paths
    }

    /// Another run holding the lock means leave quietly: no state, record or pid file is touched.
    public func runAll(command: RunCommand) async {
        let lock = RunLock(url: paths.agentLock)
        switch lock.attempt() {
        case .acquired: break
        case .held: return
        case .openFailed(let code):
            Self.log.error("cannot open the agent lock, errno \(code)")
            return
        }
        defer { lock.release() }
        writePID()
        defer { try? FileManager.default.removeItem(at: paths.pidFile) }

        do { try RcloneSession.wipeLeftovers(in: paths.work) } catch { Self.log.error("wiping leftovers failed") }
        do { try await problems.retryPending() } catch { Self.log.error("retrying notifications failed") }
        await runPairs(command)
        prune()
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

    private func runPairs(_ command: RunCommand) async {
        let sets: [BackupSet], destinations: [Destination]
        do {
            sets = try store.loadSets()
            destinations = try store.loadDestinations()
        } catch {
            Self.log.error("cannot read the configuration")
            return
        }
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
            guard await run(pair, destination: destination, command: command, expired: &expired) else { break }
        }
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
    }

    /// One folder's worth of work: the whole set, or one project.
    private struct Slice {
        var folder: String?
        var source: URL
        var destination: String
        var backupDir: String
        var filter: URL
        var logDir: URL
    }

    /// False when the run was cancelled, so no further pair starts.
    private func run(_ pair: PairID, destination: Destination, command: RunCommand, expired: inout Set<UUID>) async -> Bool {
        let lock = RunLock(url: paths.pairLock(pair))
        guard lock.attempt() == .acquired else { return true }
        defer { lock.release() }
        // Read here, not at the start: an earlier pair may have applied presets to this set.
        guard let set = (try? store.loadSets())?.first(where: { $0.id == pair.set }) else { return true }

        let started = clock()
        var tally = Tally()
        tally.trigger = command.force || command.approvedDeletions != nil ? .manual : .schedule
        func record() { write(tally, set: set, destination: destination, started: started) }

        let loaded: SetState
        do { loaded = try store.state(for: pair) } catch {
            // Treating it as new would forget the file count and the event ID, so nothing runs.
            await raise(.repeatedFailures, pair, set, detail: "Mirror can't read what it saved about this backup")
            tally.errors = ["State file unreadable"]
            record()
            return true
        }
        if set.isPaused {
            tally.status = .skipped; tally.scope = "paused"
            record()
            return true
        }
        if destination.encrypted, !destination.recoveryKitConfirmed, !Self.isLocal(destination.kind) {
            tally.status = .skipped; tally.scope = "waiting for Recovery Kit"
            record()
            return true
        }
        if expired.contains(destination.id) {
            await raise(.signInExpired, pair, set, detail: destination.name)
            tally.errors = ["Sign-in expired"]
            record()
            return true
        }

        let job = Job(pair: pair, set: set, destination: destination,
                      approved: loaded.heldDeletions > 0 ? command.approvedDeletions : nil,
                      profile: .profile(for: destination), isLocal: Self.isLocal(destination.kind))
        var state = loaded
        var carryOn = true
        do {
            try await process(job, command: command, state: &state, tally: &tally)
        } catch {
            carryOn = await absorb(error, job, state: &state, tally: &tally, expired: &expired)
        }
        if state != loaded { save(state, pair) }
        tally.pending = state.pendingUploads
        tally.refused = state.refusedSince.count
        record()
        return carryOn
    }

    /// Exhaustive, so a new kind has to decide. An external drive will be local too.
    private static func isLocal(_ kind: DestinationKind) -> Bool {
        switch kind {
        case .iCloudFolder: true
        case .googleDrive, .oneDrive: false
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
        clear([.permissionLost, .iCloudUnavailable], pair)

        let localContext = RcloneContext(configPath: "/dev/null", environment: [:])
        if job.isLocal {
            guard !job.destination.encrypted else { throw RcloneSessionError.encryptionNotSupported }
            try await confirmClaim(job, endpoint: pathGuard.backupRoot.path, context: localContext, files: LocalFiles(), state: state)
        }

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
            try await reconcileUploads(job, set: set, fresh: nil, state: &state)
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

        var session: (any RunSession)?
        var endpoint = pathGuard.backupRoot.path, context = localContext
        if !job.isLocal {
            let opened = sessions(job.destination)
            (endpoint, context) = try opened.open()
            session = opened
        }
        do {
            if !job.isLocal {
                try await confirmClaim(job, endpoint: endpoint, context: context, files: remote, state: state)
            }
            clear([.destinationMissing], pair)
            try await work(job, set: set, command: command, plan: plan, scope: runScope, sample: sample, batch: batch,
                           projects: detected, endpoint: endpoint, context: context, state: &state, tally: &tally)
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

        func request(_ s: Slice, mode: SyncMode, dryRun: Bool) -> SyncRequest {
            SyncRequest(source: s.source, destination: s.destination, backupDir: s.backupDir, filterFile: s.filter,
                        logFile: s.logDir.appendingPathComponent(dryRun ? "dry-run.log" : "sync.log"), mode: mode,
                        profile: job.profile, context: context, dryRun: dryRun, fullSpeed: command.fullSpeed)
        }

        // Mass-deletion check. -1 is rclone's "no limit": the dry run must see them all to count them.
        var deletions: [String] = []
        for slice in slices {
            let result = try await rclone.sync(request(slice, mode: .mirror(maxDelete: -1), dryRun: true))
            guard result.outcome == .success else { throw Stop.rclone(result.outcome, result.summary.errors) }
            deletions += result.summary.deleted.map { path in slice.folder.map { "\($0)/\(path)" } ?? path }
        }
        var decision = DeletionGate.decide(deletions: deletions, totalFiles: state.lastFileCount ?? 0,
                                           policy: set.deletion, approvedDeletions: job.approved)
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
            await raise(.deletionsHeld, pair, set, detail: "\(count) deletions held")
        }

        // Saved first, so a kill during the sync can't lose a hold or a whole-set run.
        if scope == .wholeSet { state.wholeSetOwed = true }
        save(state, pair)

        var perSlice: [LogSummary] = []
        for slice in slices {
            let result = try await rclone.sync(request(slice, mode: mode, dryRun: false))
            Self.add(result.summary, to: &tally.summary)
            perSlice.append(result.summary)
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
                await raise(.deletionsHeld, pair, set, detail: "\(state.heldDeletions) deletions held")
                tally.status = .held
                return
            default:
                throw Stop.rclone(result.outcome, result.summary.errors)
            }
        }

        // Verify. Held files are extras in the mirror on purpose, so the check runs one way.
        var verified = VerifyResult(differences: 0, audit: AuditResult(pending: [], refused: []))
        let wholePass = plan.isDailyPass && scope == .wholeSet
        for (slice, summary) in zip(slices, perSlice) {
            let touched = summary.copied + summary.renamed.compactMap(Self.renameTarget)
            let result = try await verifier.quick(source: slice.source, destination: slice.destination, profile: job.profile,
                                                  context: context, filter: slice.filter, copied: touched, oneWay: holding,
                                                  logDir: slice.logDir, auditWholeMirror: wholePass)
            Self.merge(result, into: &verified)
        }
        tally.filesChecked = verified.matchingFiles
        var deepRan = false
        if plan.isDeepDue, wholePass, !holding, let slice = slices.first {
            let deep = try await verifier.deep(source: slice.source, destination: slice.destination, profile: job.profile,
                                               context: context, filter: slice.filter, sampleFreed: Self.freedSample, logDir: slice.logDir)
            verified.differences += deep.differences
            verified.checksClean = verified.checksClean && deep.checksClean
            deepRan = true
        }
        guard verified.checksClean else {
            tally.verification = "Quick check found \(verified.differences) differences"
            if await changedDuringRun(set, projects: projects, since: batch.latestEventID) { throw Stop.changedDuringRun }
            throw Stop.verificationFailed(differences: verified.differences)
        }
        tally.verification = deepRan ? "Quick and deep checks passed" : "Quick check passed"

        try await reconcileUploads(job, set: set, fresh: verified.audit, state: &state)
        finish(job, plan: plan, scope: scope, batch: batch, verified: verified, holding: holding, deepRan: deepRan, state: &state)
        tally.status = holding ? .held : (verified.backedUp && state.isBackedUp ? .success : .partial)
    }

    /// The only place the event ID moves. Sync and verification have both passed.
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
        var solved: [Problem] = [.verificationFailed, .repeatedFailures, .signInExpired]
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

    /// Spec section 11: a source that changed under the run is retried by the next one, not an alarm.
    private func changedDuringRun(_ set: BackupSet, projects: [DetectedProject], since: UInt64) async -> Bool {
        guard let later = try? await feed.changes(in: set.source, since: since) else { return false }
        let matcher = FilterMatcher(lines: filters.lines(for: set, projects: projects, scope: nil))
        return ScopeMapper().scope(for: later, root: set.source, isExcluded: matcher.isExcluded) != .nothing
    }

    // MARK: Claiming a destination

    private static func join(_ endpoint: String, _ path: String) -> String {
        endpoint.hasSuffix(":") || endpoint.hasSuffix("/") ? endpoint + path : "\(endpoint)/\(path)"
    }

    /// A pair that has run before never re-claims: a lost marker means something is wrong out there.
    /// A new pair claims only where nothing of anyone else's can be overwritten, and only after
    /// `validateNewSet` passed. A marker that won't parse is never replaced.
    private func confirmClaim(_ job: Job, endpoint: String, context: RcloneContext, files: any RemoteFileAccessing,
                              state: SetState) async throws {
        let set = job.set
        let path = Self.join(endpoint, RootMarker.fileName)
        var marker: RootMarker?
        if let data = try await files.read(path, context: context) {
            guard let parsed = try? JSONDecoder().decode(RootMarker.self, from: data) else { throw GuardFailure.destinationUnclaimed }
            marker = parsed
        }
        if marker?.claims(set.id) != true {
            guard state.lastFinished == nil, state.lastEventID == nil, state.lastFullPass == nil else {
                throw GuardFailure.destinationUnclaimed
            }
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
            var claimed = marker ?? RootMarker()
            claimed.sets[set.id] = set.name
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try await files.write(try encoder.encode(claimed), to: path, context: context)
            marker = claimed
        }
        try pathGuard.validateRun(set, destination: job.destination, marker: marker,
                                  sampleFileCount: 1, state: SetState())
        clear([.destinationMissing], job.pair)
    }

    // MARK: Projects

    /// Finds projects, and applies the presets of any that arrived since the last scan. The first
    /// scan only takes note: the owner chose those presets in the preview.
    private func scan(_ set: inout BackupSet, state: inout SetState) throws -> [DetectedProject] {
        let found = detector.detect(in: set.source)
        let names = found.map(\.relativePath).sorted()
        defer { state.knownProjects = names }
        guard let known = state.knownProjects else { return found }
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
        return found
    }

    // MARK: Uploads

    /// Merges this run's audit with a fresh look at files already pending or refused, then applies
    /// the 24-hour rules. A gone file drops out, so short-lived temp files never reach an alert.
    private func reconcileUploads(_ job: Job, set: BackupSet, fresh: AuditResult?, state: inout SetState) async throws {
        guard job.isLocal else { return }
        guard fresh != nil || !state.uploadingPaths.isEmpty || !state.refusedSince.isEmpty else {
            clear([.uploadStalled, .fileRefused], job.pair)
            return
        }
        let now = clock()
        let mirror = pathGuard.backupRoot.appendingPathComponent(MirrorPaths.mirrorPath(set), isDirectory: true)
        let prefix = mirror.path + "/"
        func relative(_ path: String) -> String { path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path }

        let tracked = Set(state.uploadingPaths).union(state.refusedSince.keys)
        let again = tracked.isEmpty ? AuditResult(pending: [], refused: [])
            : try await verifier.audit(tracked.sorted().map { mirror.appendingPathComponent($0) })
        let pending = Set((again.pending + (fresh?.pending ?? [])).map(relative))
        // Accepting a refused file adds an exclude rule, which ends its claim on "Backed Up".
        let rules = FilterMatcher(lines: filters.lines(for: set, projects: [], scope: nil))
        let refused = Set((again.refused + (fresh?.refused ?? [])).map(relative)).filter { !rules.isExcluded($0) }

        let moved = !Set(state.uploadingPaths).isSubset(of: pending)
        state.uploadingSince = pending.isEmpty ? nil : (moved ? now : state.uploadingSince ?? now)
        state.uploadingPaths = pending.sorted()
        state.pendingUploads = pending.count
        state.refusedSince = Dictionary(uniqueKeysWithValues: refused.map { ($0, state.refusedSince[$0] ?? now) })

        if let since = state.uploadingSince, now.timeIntervalSince(since) > Self.patience {
            await raise(.uploadStalled, job.pair, set, detail: "\(pending.count) files waiting for over a day")
        } else {
            clear([.uploadStalled], job.pair)
        }
        let overdue = state.refusedSince.filter { now.timeIntervalSince($0.value) > Self.patience }.keys.sorted()
        state.reviewItems.removeAll { $0.kind == .refusedByICloud && !overdue.contains($0.path) }
        for path in overdue where !state.reviewItems.contains(where: { $0.kind == .refusedByICloud && $0.path == path }) {
            state.reviewItems.append(ReviewItem(id: "refused:\(path)", path: path, kind: .refusedByICloud))
        }
        if let first = overdue.first {
            await raise(.fileRefused, job.pair, set, detail: overdue.count == 1 ? first : "\(first) and \(overdue.count - 1) more")
        } else {
            clear([.fileRefused], job.pair)
        }
    }

    // MARK: Failures

    /// Turns whatever stopped a run into state, a record and at most one alert. The event ID stays
    /// put on every path through here. False when the run was cancelled.
    private func absorb(_ error: any Error, _ job: Job, state: inout SetState, tally: inout Tally,
                        expired: inout Set<UUID>) async -> Bool {
        let (pair, set) = (job.pair, job.set)
        func signInExpired() async {
            expired.insert(job.destination.id)
            tally.errors = ["Sign-in expired"]   // rclone's text can quote what the token endpoint said
            await raise(.signInExpired, pair, set, detail: job.destination.name)
        }
        switch error {
        case is CancellationError:
            tally.errors = ["Stopped before finishing"]
            return false
        case let failure as GuardFailure:
            switch failure {
            case .iCloudUnavailable:
                tally.errors = ["iCloud Drive is unavailable"]
                await raise(.iCloudUnavailable, pair, set, detail: "Backups are paused until it's back. Nothing was deleted.")
            case .sourceUnreadable:
                tally.errors = ["Source can't be read"]
                await raise(.permissionLost, pair, set, detail: set.source.path)
            case .sourceMissing where Self.isPermissionDenied(set.source):
                tally.errors = ["Source can't be read"]
                await raise(.permissionLost, pair, set, detail: set.source.path)
            case .sourceSuspiciouslyEmpty(_, let last):
                state.heldDeletions = max(state.heldDeletions, last)
                tally.status = .held
                tally.errors = ["Source is empty"]
                await raise(.deletionsHeld, pair, set, detail: "the source folder is empty, so nothing was changed")
            case .destinationUnclaimed:
                tally.errors = ["Destination isn't claimed by this set"]
                await raise(.destinationMissing, pair, set, detail: job.destination.name)
            default:
                await fail("\(failure)", job, state: &state, tally: &tally)
            }
        case Stop.rclone(.authExpired, _), VerifyError.checkDidNotComplete(.authExpired):
            await signInExpired()
        case RcloneSessionError.notSignedIn, RcloneSessionError.invalidSignIn:
            await signInExpired()
        case Stop.rclone(.partial, _):
            // The dry run ran out of time. Nothing changed, so this is a resume, not a failure.
            state.syncIncomplete = true
            tally.status = .partial
        case Stop.rclone(_, let errors):
            await fail(errors.first ?? "rclone failed", job, state: &state, tally: &tally)
            tally.errors = Array(errors.prefix(20))
        case Stop.verificationFailed(let differences):
            state.consecutiveFailures += 1
            tally.status = .verificationFailed
            tally.errors = ["\(differences) differences found"]
            await raise(.verificationFailed, pair, set, detail: "\(differences) differences found")
        case Stop.changedDuringRun:
            await fail("Files changed during the run", job, state: &state, tally: &tally)
        case VerifyError.mirrorUnreadable:
            state.consecutiveFailures += 1
            tally.status = .verificationFailed
            tally.errors = ["Mirror can't be read"]
            await raise(.verificationFailed, pair, set, detail: "the mirror can't be read")
        case let failure as VerifyError:
            await fail("\(failure)", job, state: &state, tally: &tally)
        case let failure as RcloneSessionError:
            await fail("\(failure)", job, state: &state, tally: &tally)
        case let failure as RemoteFileError:
            await fail("\(failure)", job, state: &state, tally: &tally)
        default:
            // Arbitrary errors could describe anything, so they stay out of the record.
            await fail("Run failed", job, state: &state, tally: &tally)
        }
        return true
    }

    private func fail(_ message: String, _ job: Job, state: inout SetState, tally: inout Tally) async {
        state.consecutiveFailures += 1
        tally.errors = [message]
        tally.status = .failed
        if state.consecutiveFailures >= Self.notifyAfterFailures {
            await raise(.repeatedFailures, job.pair, job.set, detail: "\(state.consecutiveFailures) failed runs in a row")
        }
    }

    private func raise(_ problem: Problem, _ pair: PairID, _ set: BackupSet, detail: String) async {
        do { try await problems.raise(problem, pair: pair, setName: set.name, detail: detail) } catch {
            Self.log.error("could not record a problem")
        }
    }

    private func clear(_ list: [Problem], _ pair: PairID) {
        for problem in list {
            do { try problems.clear(problem, pair: pair) } catch { Self.log.error("could not clear a problem") }
        }
    }

    private func save(_ state: SetState, _ pair: PairID) {
        do { try store.save(state, for: pair) } catch { Self.log.error("could not save state") }
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

    private static func merge(_ r: VerifyResult, into total: inout VerifyResult) {
        total.differences += r.differences
        total.checksClean = total.checksClean && r.checksClean
        total.matchingFiles += r.matchingFiles
        total.audit.pending += r.audit.pending
        total.audit.refused += r.audit.refused
        total.audit.missing += r.audit.missing
    }
}
