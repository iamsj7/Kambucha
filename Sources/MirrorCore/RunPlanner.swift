import Foundation
import os

public struct RunPlan: Equatable, Sendable {
    public var scope: RunScope
    /// A full pass is due: the whole set, whatever the events say.
    public var isDailyPass: Bool
    /// Runs alongside the next full pass, as it needs the whole set.
    public var isDeepDue: Bool
    public init(scope: RunScope, isDailyPass: Bool, isDeepDue: Bool) {
        self.scope = scope; self.isDailyPass = isDailyPass; self.isDeepDue = isDeepDue
    }
}

/// What a pair should do now, and the order pairs go in. Pure, so every rule is testable.
public struct RunPlanner {
    public static let deepCheckInterval: TimeInterval = 30 * 86_400
    /// launchd doesn't say why it started the agent. Interval wake-ups are 30 minutes apart, so one sooner
    /// than this after a full pass came from `StartOnMount`.
    public static let mountWakeWindow: TimeInterval = 24 * 60

    /// `fullPass` overrides the interval, for a drive, where a new connection decides.
    public static func plan(state: SetState, scope: RunScope, profile: DestinationProfile, now: Date,
                            fullPass: Bool? = nil, deepInterval: TimeInterval = deepCheckInterval) -> RunPlan {
        let fullDue = fullPass ?? state.lastFullPass.map { now.timeIntervalSince($0) >= profile.fullPassInterval } ?? true
        // Never checked isn't overdue: the first full pass sets the baseline.
        let deepDue = state.lastDeepCheck.map { now.timeIntervalSince($0) >= deepInterval } ?? false
        // Evicted files can't be hashed yet, so they don't drive runs. They stay owed, and they wait.
        var planned = including(state.verifyOwed.filter { state.freedSince[$0] == nil }, in: scope)
        // With the evicted list full, another deep check couldn't name any more. It waits for the list to drain.
        let hashDue = state.hashWholeSet && state.freedSince.count < RunCoordinator.maxFreed
        if fullDue || state.wholeSetOwed || hashDue {
            planned = .wholeSet
        } else if state.heldDeletions > 0, planned != .nothing {
            // A scoped dry run can't see the held deletions, and would read as "none left".
            planned = .wholeSet
        }
        return RunPlan(scope: planned, isDailyPass: fullDue, isDeepDue: deepDue)
    }

    /// Files a run still owes proof for keep their folders in scope, with or without new changes.
    private static func including(_ owed: [String], in scope: RunScope) -> RunScope {
        guard !owed.isEmpty, scope != .wholeSet else { return scope }
        var projects = Set<String>()
        if case .projects(let names) = scope { projects.formUnion(names) }
        for path in owed {
            let parts = path.split(separator: "/", maxSplits: 1)
            guard parts.count == 2 else { return .wholeSet }   // a root-level file belongs to no project
            projects.insert(String(parts[0]))
        }
        return projects.count > ScopeMapper().maxProjects ? .wholeSet : .projects(projects.sorted())
    }

    /// iCloud pairs first, as they finish quickly, then cloud pairs. Least recently finished first
    /// within each, and never-finished before all.
    public static func order(_ pairs: [(PairID, DestinationKind, SetState)]) -> [PairID] {
        pairs.enumerated().sorted { a, b in
            let (ra, rb) = (rank(a.element.1), rank(b.element.1))
            if ra != rb { return ra < rb }
            let (fa, fb) = (a.element.2.lastFinished ?? .distantPast, b.element.2.lastFinished ?? .distantPast)
            return fa != fb ? fa < fb : a.offset < b.offset
        }.map(\.element.0)
    }

    private static func rank(_ kind: DestinationKind) -> Int {
        switch kind {
        case .iCloudFolder: 0
        case .googleDrive, .oneDrive: 1
        case .externalDrive: 2
        }
    }
}

/// One agent invocation.
public struct RunCommand: Codable, Equatable, Sendable {
    public var setID: UUID?
    /// The deletion count the owner reviewed, outside `.git` folders. It applies only to `approvedDestination`
    /// of this set, only while that pair holds deletions, and only up to this count.
    public var approvedDeletions: Int?
    public var approvedDestination: UUID?
    /// A manual run: the whole set, with or without changes.
    public var force: Bool
    /// The `--full-speed` flag, or the Full Speed setting.
    public var fullSpeed: Bool

    public init(setID: UUID? = nil, approvedDeletions: Int? = nil, approvedDestination: UUID? = nil, force: Bool = false,
                fullSpeed: Bool = false) {
        self.setID = setID; self.approvedDeletions = approvedDeletions; self.approvedDestination = approvedDestination
        self.force = force; self.fullSpeed = fullSpeed
    }

    /// Normal priority and more rclone concurrency: Back Up Now and Full Speed. A drive gets the same by itself.
    public var isFast: Bool { force || fullSpeed }

    /// Scheduled passes stay in the background.
    public var taskPriority: TaskPriority { isFast ? .medium : .background }

    /// No argument is a scheduled pass; `--run-now [set-id]` and `--allow-deletes <set-id> <destination-id> <count>` are
    /// manual, and either may add `--full-speed`. Nil for anything else, so a malformed approval
    /// never becomes a run.
    public static func parse(_ arguments: [String]) -> RunCommand? {
        let fullSpeed = arguments.contains("--full-speed")
        let rest = arguments.filter { $0 != "--full-speed" }
        switch rest.first {
        case nil:
            return fullSpeed ? nil : RunCommand()
        case "--run-now":
            guard rest.count <= 2 else { return nil }
            guard rest.count == 2 else { return RunCommand(force: true, fullSpeed: fullSpeed) }
            guard let id = UUID(uuidString: rest[1]) else { return nil }
            return RunCommand(setID: id, force: true, fullSpeed: fullSpeed)
        case "--allow-deletes":
            guard rest.count == 4, let id = UUID(uuidString: rest[1]), let destination = UUID(uuidString: rest[2]),
                  let count = Int(rest[3]), count >= 0 else { return nil }
            return RunCommand(setID: id, approvedDeletions: count, approvedDestination: destination, force: true, fullSpeed: fullSpeed)
        default:
            return nil
        }
    }
}

/// The agent's priority, set by the agent itself. Measured under launchd (docs/proofs.md): a `ProcessType`
/// Background job and everything it spawns stay at scheduling priority 4 whatever the job then calls, and a
/// plist `Nice` can't be undone without root. So the plist asks for neither, and a background pass lowers
/// itself instead: the same kernel policy, inherited by rclone, and unlike launchd's it can be lifted.
public enum AgentPriority {
    private static let raised = OSAllocatedUnfairLock(initialState: false)
    static var isRaised: Bool { raised.withLock { $0 } }

    /// `fast` is normal priority for this process and rclone children started from now on.
    public static func set(fast: Bool) {
        raised.withLock { $0 = fast }
        setpriority(PRIO_DARWIN_PROCESS, 0, fast ? 0 : PRIO_DARWIN_BG)
    }
}
