import Foundation

public enum OverallStatus: Equatable, Sendable {
    case backedUp(last: Date, files: Int)
    case uploading(Int)
    /// Recorded mismatches iCloud has evicted, waiting for it to bring them back to be hashed.
    case waitingForDownload(Int)
    /// Files iCloud has refused so far, not yet old enough for the 24-hour alert.
    case notAccepted(Int)
    /// The last run stopped short, and no run is under way. The next wake-up resumes it.
    case unfinished
    case running
    case held(Int)
    case attention(String)
    /// Nothing else speaks for the set: its only destinations are drives away from this Mac. Not a failure.
    case driveNotConnected(name: String, last: Date?)
    case paused
    case notConfigured
}

/// What one destination can honestly say, across the sets that use it.
public enum DestinationHealth: Equatable, Sendable {
    case unused, paused, notBackedUp, previewNeeded, failing, unfinished
    case stopped(Problem)
    case mismatched(Int)
    case held(Int)
    case uploading(Int)
    case notAccepted(Int)
    case backedUp(last: Date)
}

/// Folds the on-disk state into the one status the menu bar shows.
public enum StatusSummary {
    /// A real mismatch said as one, in the status and the run record: never a neutral wait.
    public static func notAcceptedText(count n: Int) -> String {
        "\(n.formatted()) \(n == 1 ? "file" : "files") iCloud hasn't accepted yet"
    }

    public static func recheckText(count n: Int) -> String {
        n == 1 ? "Re-checking 1 file that didn't match, waiting for iCloud to download it"
               : "Re-checking \(n.formatted()) files that didn't match, waiting for iCloud to download them"
    }

    /// "Backed Up" means every destination of every active set passed, leaving out drives that aren't
    /// connected. Review items, a due restore drill and an overdue drive never block it. Priority: attention, held, running, uploading, a missing destination,
    /// waiting for iCloud, files not accepted, a run still to resume, only drives away, backed up.
    /// `disconnected` holds the external drives known not to be mounted. Spec section 8a: they aren't a failure,
    /// so they take no part unless they are all a set has.
    public static func overall(sets: [BackupSet], destinations: [Destination], states: [PairID: SetState],
                               records: [RunRecord], problems: [ActiveProblem], running: Bool,
                               disconnected: Set<UUID> = []) -> OverallStatus {
        // Before anything that reads the sets: a run that couldn't start may be why they look empty.
        if let failed = problems.first(where: { $0.pair == .agent }) { return .attention(failed.problem.headline) }
        if sets.isEmpty { return .notConfigured }
        let active = sets.filter { !$0.isPaused }
        if active.isEmpty { return .paused }

        let known = Dictionary(destinations.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var pairs: [PairID] = []
        for s in active {
            for d in s.destinationIDs {
                if let dest = known[d], blocksBackedUp(dest, disconnected: disconnected) { pairs.append(PairID(set: s.id, destination: d)) }
            }
        }
        let setsWithNoDestination = active.filter { s in !s.destinationIDs.contains { known[$0] != nil } }

        // Latest finished record per pair; a skipped run says nothing about the backup itself.
        var latest: [PairID: RunRecord] = [:]
        for r in records where r.status != .skipped {
            let p = PairID(set: r.setID, destination: r.destinationID)
            if let cur = latest[p], cur.end >= r.end { continue }
            latest[p] = r
        }

        // The owner was told of these when they were found. For its first days a mismatch only iCloud
        // can settle reads as the wait it is. It leaves the problem open, and `.alerted` ends the wait.
        func waits(_ p: PairID) -> Bool { states[p]?.isOnlyWaiting ?? false }

        // 1. Anything that needs the owner, other than held deletions (handled below) and the two reminders.
        let quiet: Set<Problem> = [.drillDue, .driveOverdue, .deletionsHeld]
        let live = BackupSet.pairs(of: active)
        if let p = problems.first(where: {
            !quiet.contains($0.problem) && live.contains($0.pair)
                && !($0.problem == .verificationFailed && waits($0.pair))
        }) {
            return .attention(p.problem.headline)
        }
        for p in pairs {
            if let r = latest[p], r.status == .failed || (r.status == .verificationFailed && !waits(p)) {
                return .attention(r.status == .verificationFailed ? Problem.verificationFailed.headline
                                                                  : Problem.repeatedFailures.headline)
            }
            if (states[p]?.consecutiveFailures ?? 0) > 0 { return .attention(Problem.repeatedFailures.headline) }
        }

        // 2. Held deletions.
        let held = pairs.reduce(0) { $0 + (states[$1]?.heldDeletions ?? 0) }
        let heldProblem = problems.contains { $0.problem == .deletionsHeld && live.contains($0.pair) }
        if held > 0 || heldProblem { return .held(max(held, 1)) }

        // 3. A run in progress, then uploads still pending.
        if running { return .running }
        let pending = pairs.reduce(0) { $0 + (states[$1]?.pendingUploads ?? 0) }
        let fromRecords = pairs.reduce(0) { $0 + (latest[$1]?.status == .partial && states[$1]?.isBackedUp != true ? latest[$1]!.pendingUploads : 0) }
        if max(pending, fromRecords) > 0 { return .uploading(max(pending, fromRecords)) }

        // 4. A destination that's gone says more than anything left to wait for.
        if !setsWithNoDestination.isEmpty { return .attention("No destination chosen") }
        if active.contains(where: { $0.destinationIDs.contains { known[$0] == nil } }) {
            return .attention("A destination was removed")
        }

        // 5. Files that can't be verified until iCloud brings them back.
        let waiting = pairs.reduce(0) { $0 + (states[$1]?.waitingForDownload ?? 0) }
        if waiting > 0 { return .waitingForDownload(waiting) }

        // 6. What's left is said as it is. "Backing Up" is only for a run that's really under way.
        let refused = pairs.reduce(0) { $0 + (states[$1]?.refusedSince.count ?? 0) }
        if refused > 0 { return .notAccepted(refused) }
        // A skipped run leaves the record behind, so the state says whether this is still true.
        if pairs.contains(where: { latest[$0]?.status == .partial && states[$0]?.isBackedUp != true }) { return .unfinished }

        // 7. Every destination that's left is a drive away from this Mac, which is its own line.
        if pairs.isEmpty, let drive = destinations.first(where: { d in disconnected.contains(d.id) && active.contains { $0.destinationIDs.contains(d.id) } }) {
            let last = active.compactMap { states[PairID(set: $0.id, destination: drive.id)]?.lastFinished }.max()
            return .driveNotConnected(name: drive.name, last: last)
        }

        // 8. Backed up only when every pair has finished at least once.
        let finished = pairs.compactMap { states[$0]?.lastFinished }
        if pairs.isEmpty || finished.count != pairs.count { return .attention("Not backed up yet") }
        // A killed run leaves no record, so only the state knows it never finished.
        if pairs.contains(where: { states[$0]?.isBackedUp != true }) { return .unfinished }
        let files = pairs.reduce(0) { $0 + (states[$1]?.lastFileCount ?? 0) }
        return .backedUp(last: finished.max()!, files: files)
    }

    /// One destination's state across the sets that use it. Only a pair's `isBackedUp` earns "Backed Up", so
    /// finishing a run while uploads are pending or deletions are held reads as what it is. Worst first.
    public static func destinationHealth(_ id: UUID, sets: [BackupSet], states: [PairID: SetState]) -> DestinationHealth {
        let using = sets.filter { $0.destinationIDs.contains(id) }
        guard !using.isEmpty else { return .unused }
        let active = using.filter { !$0.isPaused }
        guard !active.isEmpty else { return .paused }
        let pairs = active.map { states[PairID(set: $0.id, destination: id)] ?? SetState() }
        func total(_ count: (SetState) -> Int) -> Int { pairs.reduce(0) { $0 + count($1) } }

        if let stop = pairs.compactMap(\.stoppedBy).first { return .stopped(stop) }
        if pairs.contains(where: { $0.consecutiveFailures > 0 }) { return .failing }
        if total(\.mismatched.count) > 0 { return .mismatched(total(\.mismatched.count)) }
        if total(\.heldDeletions) > 0 { return .held(total(\.heldDeletions)) }
        if total(\.pendingUploads) > 0 { return .uploading(total(\.pendingUploads)) }
        if total(\.refusedSince.count) > 0 { return .notAccepted(total(\.refusedSince.count)) }
        if active.contains(where: { !$0.isPreviewAccepted }) { return .previewNeeded }
        if pairs.contains(where: { $0.lastFinished == nil }) { return .notBackedUp }
        guard pairs.allSatisfy(\.isBackedUp) else { return .unfinished }
        return .backedUp(last: pairs.compactMap(\.lastFinished).max()!)
    }

    /// A set whose preview was never accepted (a set made before acceptance moved onto the set, say) can't be backed up
    /// by the agent, so "Backed Up" and "Not backed up yet" give way to a plain request. Problems, held deletions and a
    /// run keep their own message, and a paused set needs nothing.
    public static let previewNeededPrefix = "Preview needed: "

    public static func withPreviewNeeded(_ status: OverallStatus, sets: [BackupSet]) -> OverallStatus {
        let needing = sets.filter { !$0.isPaused && !$0.isPreviewAccepted }.map(\.name)
        guard !needing.isEmpty else { return status }
        switch status {
        case .backedUp, .driveNotConnected, .attention("Not backed up yet"): return .attention(previewNeededPrefix + needing.joined(separator: ", "))
        default: return status
        }
    }

    /// A drive that isn't connected must not block "Backed Up". Every other destination does.
    static func blocksBackedUp(_ destination: Destination, disconnected: Set<UUID>) -> Bool {
        !disconnected.contains(destination.id)
    }
}
