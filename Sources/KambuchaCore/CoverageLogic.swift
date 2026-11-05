import Foundation

// Logic behind Coverage and a sidebar with many sets, kept out of the views so it can be tested.

// MARK: One set at one destination

extension StatusSummary {
    /// Each pair judged by `overall` and `withPreviewNeeded` as if it were a set with that one destination, so a cell
    /// can't disagree with its set's row. A trouble with the agent as a whole belongs to no pair, so what a pair says of
    /// itself stands, except "Backed Up": no cell claims that while Kambucha can't run. `running` holds the pairs moving files now. Destinations no longer known have no column, so they get no entry.
    public static func pairStatuses(sets: [BackupSet], destinations: [Destination], states: [PairID: SetState],
                                    records: [RunRecord], problems: [ActiveProblem], running: Set<PairID>,
                                    disconnected: Set<UUID>) -> [PairID: OverallStatus] {
        let known = Dictionary(destinations.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let recordsByPair = Dictionary(grouping: records) { PairID(set: $0.setID, destination: $0.destinationID) }
        let problemsByPair = Dictionary(grouping: problems, by: \.pair)
        let agentProblem = problemsByPair[.agent]?.first
        var out: [PairID: OverallStatus] = [:]
        for s in sets {
            for id in s.destinationIDs {
                guard let d = known[id] else { continue }
                let pair = PairID(set: s.id, destination: id)
                var alone = s
                alone.destinationIDs = [id]
                let status = overall(sets: [alone], destinations: [d], states: states, records: recordsByPair[pair] ?? [],
                                     problems: problemsByPair[pair] ?? [], running: running.contains(pair),
                                     disconnected: disconnected.contains(id) ? [id] : [])
                let judged = withPreviewNeeded(status, sets: [alone])
                if case .backedUp = judged, let agentProblem { out[pair] = .attention(agentProblem.problem.headline) }
                else { out[pair] = judged }
            }
        }
        return out
    }

    /// A pair turned back on has only an old finish to go by, so it reads as owing a run until one finishes after
    /// `turnedOn`. For reading only: in a state file `wholeSetOwed` would change what the agent's next run does.
    public static func withTurnedOn(_ states: [PairID: SetState], turnedOn: [PairID: Date]) -> [PairID: SetState] {
        var out = states
        for (pair, since) in turnedOn {
            if let last = out[pair]?.lastFinished, last <= since { out[pair]?.wholeSetOwed = true }
        }
        return out
    }
}

extension OverallStatus {
    /// The owner has something to do. A drive that's away is not a failure, and what only iCloud or the next run can
    /// settle isn't theirs to act on, so neither moves a set to the top.
    public var needsAttention: Bool {
        switch self {
        case .attention, .held: true
        default: false
        }
    }
}

/// What one cell of Coverage says.
public enum CoverageCell: Equatable, Sendable {
    case off
    case status(OverallStatus)
    case confirmDisk
    case saveRecoveryKit

    /// Broad groups, for the colour that goes with the words and the symbol.
    public enum Kind: Equatable, Sendable { case off, paused, backedUp, working, attention, notConnected }

    /// What a destination's own page puts ahead of how its backups went, in the same order. A paused set says so first,
    /// as `overall` does. `status` is nil only for a pair too new to have been judged.
    public static func make(set: BackupSet, destination: Destination, status: OverallStatus?, driveAway: Bool,
                            needsDiskConfirmation: Bool) -> CoverageCell {
        guard set.destinationIDs.contains(destination.id) else { return .off }
        if set.isPaused { return .status(.paused) }
        if !driveAway {
            if needsDiskConfirmation { return .confirmDisk }
            if destination.encrypted && !destination.recoveryKitConfirmed { return .saveRecoveryKit }
        }
        return .status(status ?? .attention("Not backed up yet"))
    }

    public var kind: Kind {
        switch self {
        case .off: .off
        case .confirmDisk, .saveRecoveryKit: .attention
        case .status(let s):
            switch s {
            case .backedUp: .backedUp
            case .paused: .paused
            case .driveNotConnected: .notConnected
            case .uploading, .running, .waitingForDownload, .notAccepted, .unfinished: .working
            case .held, .attention, .notConfigured: .attention
            }
        }
    }
}

extension BackupSet {
    /// What the switch on the set's page does: only the list of destinations changes. The preview stays accepted, as
    /// destinations aren't part of it, and nothing is said to the destination itself.
    public func withDestination(_ id: UUID, on: Bool) -> BackupSet {
        var s = self
        if !on { s.destinationIDs.removeAll { $0 == id } }
        else if !s.destinationIDs.contains(id) { s.destinationIDs.append(id) }
        return s
    }
}

/// Words for turning a destination off. A set may end up with none, as on its own page, and then it reads as needing
/// attention ("No destination chosen"). So the last one isn't refused, but the owner is told first.
public enum CoverageTurnOff {
    public static let button = "Turn Off"

    public static func title(set: String, destination: String) -> String {
        "Stop backing up \"\(set)\" to \(destination)?"
    }

    public static func message(destination: String, isLast: Bool) -> String {
        let copy = "The copy already in \(destination) stays there and nothing in it is deleted. It stops being updated, and you can't restore from it in Kambucha until you turn this back on."
        return isLast ? copy + " This is the set's only destination, so it won't be backed up anywhere." : copy
    }
}

// MARK: Order and filter

public struct SetSortKey: Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var needsAttention: Bool
    public init(id: UUID, name: String, needsAttention: Bool) {
        self.id = id; self.name = name; self.needsAttention = needsAttention
    }
}

/// The order sets are listed in: those needing attention, then by name as Finder sorts them. It keeps only what that
/// depends on, so file counts and times changing every few seconds never move a row.
public struct SetOrder: Equatable, Sendable {
    public private(set) var ids: [UUID] = []
    public init() {}

    public static func sorted(_ keys: [SetSortKey]) -> [UUID] {
        keys.sorted { a, b in
            if a.needsAttention != b.needsAttention { return a.needsAttention }
            switch a.name.localizedStandardCompare(b.name) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: return a.id.uuidString < b.id.uuidString
            }
        }.map(\.id)
    }

    /// While `held` the pointer is over the list, so a row mustn't move under it: sets that went are dropped, new ones
    /// join the end, and the rest wait for the next update that isn't held.
    public mutating func update(_ keys: [SetSortKey], held: Bool) {
        guard held else { ids = Self.sorted(keys); return }
        let live = Set(keys.map(\.id)), listed = Set(ids)
        ids.removeAll { !live.contains($0) }
        ids += Self.sorted(keys.filter { !listed.contains($0.id) })
    }

    /// `items` in this order. Any this order hasn't seen yet go last, so a row is never lost.
    public func arranged<T: Identifiable>(_ items: [T]) -> [T] where T.ID == UUID {
        let rank = Dictionary(ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return items.enumerated().sorted { a, b in
            (rank[a.element.id] ?? Int.max, a.offset) < (rank[b.element.id] ?? Int.max, b.offset)
        }.map(\.element)
    }
}

public enum SetFilter {
    /// Ignores case and accents. A blank filter matches everything.
    public static func matches(_ name: String, filter: String) -> Bool {
        let text = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty || name.localizedStandardContains(text)
    }
}

// MARK: Several sets at once

/// What can be done to the chosen sets, and to which of them.
public struct SetBatch: Equatable, Sendable {
    public var sets: [BackupSet]
    public init(sets: [BackupSet]) { self.sets = sets }

    /// As on a set's page, a paused set or one whose preview wasn't accepted can't be backed up now.
    public var canBackUp: Bool { sets.contains { !$0.isPaused && $0.isPreviewAccepted } }
    public var canPause: Bool { sets.contains { !$0.isPaused } }
    public var canResume: Bool { sets.contains(where: \.isPaused) }

    /// Those that aren't all there yet, as adding the rest still means something.
    public func addable(_ destinations: [Destination]) -> [Destination] {
        destinations.filter { d in sets.contains { !$0.destinationIDs.contains(d.id) } }
    }

    public struct RunPlan: Equatable, Sendable {
        public var run: [UUID]
        public var unaccepted: [String]
        public var paused: [String]
    }

    public var runPlan: RunPlan {
        let active = sets.filter { !$0.isPaused }
        return RunPlan(run: active.filter(\.isPreviewAccepted).map(\.id),
                       unaccepted: active.filter { !$0.isPreviewAccepted }.map(\.name),
                       paused: sets.filter(\.isPaused).map(\.name))
    }

    /// What's left undone, named, or nil when everything chosen is going to run.
    public static func runNotice(_ plan: RunPlan) -> String? {
        var parts: [String] = []
        if !plan.unaccepted.isEmpty {
            parts.append("Preview before the first backup: \(plan.unaccepted.joined(separator: ", ")). Open each in Kambucha and choose Preview Backup.")
        }
        if !plan.paused.isEmpty { parts.append("Paused, so left out: \(plan.paused.joined(separator: ", ")).") }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// Only what's worth saying, or nil.
    public static func summary(attention: Int, paused: Int) -> String? {
        var parts: [String] = []
        if attention > 0 { parts.append("\(attention.formatted()) \(attention == 1 ? "needs" : "need") attention") }
        if paused > 0 { parts.append("\(paused.formatted()) paused") }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// Or nil, with none hidden.
    public static func hiddenNote(count: Int) -> String? {
        count > 0 ? "\(count.formatted()) hidden by the filter" : nil
    }

    public static func removalTitle(count: Int) -> String { "Remove \(count.formatted()) Sets?" }

    /// Every name, however many: removing several must never be a surprise.
    public static func removalMessage(names: [String]) -> String {
        "\(names.formatted(.list(type: .and))). Kambucha stops backing up these folders. Your files and the copies already in your backups are not deleted."
    }
}
