import Foundation

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

    public static func plan(state: SetState, scope: RunScope, profile: DestinationProfile, now: Date) -> RunPlan {
        let fullDue = state.lastFullPass.map { now.timeIntervalSince($0) >= profile.fullPassInterval } ?? true
        // Never checked isn't overdue: the first full pass sets the baseline.
        let deepDue = state.lastDeepCheck.map { now.timeIntervalSince($0) >= deepCheckInterval } ?? false
        // An evicted mismatch can't be hashed yet, so it doesn't drive runs. It stays owed, and it waits.
        var planned = including(state.verifyOwed.filter { state.mismatched[$0]?.evicted != true }, in: scope)
        if fullDue || state.wholeSetOwed || state.hashWholeSet {
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
    /// The deletion count the owner reviewed. It applies only to pairs holding deletions, and only up to this count.
    public var approvedDeletions: Int?
    /// A manual run: the whole set, with or without changes.
    public var force: Bool
    /// Normal priority and more rclone concurrency. Manual runs only.
    public var fullSpeed: Bool

    public init(setID: UUID? = nil, approvedDeletions: Int? = nil, force: Bool = false, fullSpeed: Bool = false) {
        self.setID = setID; self.approvedDeletions = approvedDeletions; self.force = force; self.fullSpeed = fullSpeed
    }

    /// Scheduled and mount-triggered runs stay in the background.
    public var taskPriority: TaskPriority { fullSpeed ? .medium : .background }

    /// No argument is a scheduled pass; `--run-now [set-id]` and `--allow-deletes <set-id> <count>` are
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
            guard rest.count == 3, let id = UUID(uuidString: rest[1]), let count = Int(rest[2]), count >= 0 else { return nil }
            return RunCommand(setID: id, approvedDeletions: count, force: true, fullSpeed: fullSpeed)
        default:
            return nil
        }
    }
}

public enum AgentPriority {
    /// Lifts the background limits launchd or the parent may have set. Best effort: a process can't
    /// lower its own nice value, so a run started by launchd with `Nice` keeps that.
    public static func raiseToNormal() {
        setpriority(PRIO_DARWIN_PROCESS, 0, 0)
        setiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_PROCESS, IOPOL_DEFAULT)
        setpriority(PRIO_PROCESS, 0, 0)
    }
}
