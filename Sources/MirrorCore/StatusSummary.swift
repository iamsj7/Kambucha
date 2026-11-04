import Foundation

public enum OverallStatus: Equatable, Sendable {
    case backedUp(last: Date, files: Int)
    case uploading(Int)
    /// Recorded mismatches iCloud has evicted, waiting for it to bring them back to be hashed.
    case waitingForDownload(Int)
    case running
    case held(Int)
    case attention(String)
    case paused
    case notConfigured
}

/// Folds the on-disk state into the one status the menu bar shows (spec sections 8a and 12).
public enum StatusSummary {
    /// "Backed Up" means every destination of every active set passed. Review items and a due restore
    /// drill never block it. Priority: attention, held, running, uploading, a missing destination,
    /// waiting for iCloud, a run still to resume, backed up.
    public static func overall(sets: [BackupSet], destinations: [Destination], states: [PairID: SetState],
                               records: [RunRecord], problems: [ActiveProblem], running: Bool) -> OverallStatus {
        // Before anything that reads the sets: a run that couldn't start may be why they look empty.
        if let failed = problems.first(where: { $0.pair == .agent }) { return .attention(failed.problem.headline) }
        if sets.isEmpty { return .notConfigured }
        let active = sets.filter { !$0.isPaused }
        if active.isEmpty { return .paused }

        let known = Dictionary(destinations.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var pairs: [PairID] = []
        for s in active {
            for d in s.destinationIDs {
                if let dest = known[d], blocksBackedUp(dest) { pairs.append(PairID(set: s.id, destination: d)) }
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

        // 1. Anything that needs the owner, other than held deletions (handled below) and a due drill.
        let activeIDs = Set(active.map(\.id))
        if let p = problems.first(where: {
            $0.problem != .drillDue && $0.problem != .deletionsHeld && activeIDs.contains($0.pair.set)
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
        let heldProblem = problems.contains { $0.problem == .deletionsHeld && activeIDs.contains($0.pair.set) }
        if held > 0 || heldProblem { return .held(max(held, 1)) }

        // 3. A run in progress, then uploads still pending.
        if running { return .running }
        let pending = pairs.reduce(0) { $0 + (states[$1]?.pendingUploads ?? 0) }
        let fromRecords = pairs.reduce(0) { $0 + (latest[$1]?.status == .partial ? latest[$1]!.pendingUploads : 0) }
        if max(pending, fromRecords) > 0 { return .uploading(max(pending, fromRecords)) }

        // 4. A destination that's gone says more than anything left to wait for.
        if !setsWithNoDestination.isEmpty { return .attention("No destination chosen") }
        if active.contains(where: { $0.destinationIDs.contains { known[$0] == nil } }) {
            return .attention("A destination was removed")
        }

        // 5. Files that can't be verified until iCloud brings them back.
        let waiting = pairs.reduce(0) { $0 + (states[$1]?.waitingForDownload ?? 0) }
        if waiting > 0 { return .waitingForDownload(waiting) }

        // 6. A partial run with nothing to count, stopped by a time limit say. The next wake-up resumes it.
        if pairs.contains(where: { latest[$0]?.status == .partial }) { return .running }

        // 7. Backed up only when every pair has finished at least once.
        let finished = pairs.compactMap { states[$0]?.lastFinished }
        if pairs.isEmpty || finished.count != pairs.count { return .attention("Not backed up yet") }
        let files = pairs.reduce(0) { $0 + (states[$1]?.lastFileCount ?? 0) }
        return .backedUp(last: finished.max()!, files: files)
    }

    /// Extension point for the external drive: a drive that isn't connected must not block "Backed Up",
    /// so once that kind exists, return false here for an unmounted one. Every current kind blocks.
    static func blocksBackedUp(_ destination: Destination) -> Bool { true }
}
