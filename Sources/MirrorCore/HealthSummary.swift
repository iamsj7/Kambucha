import Foundation

/// One set as the status logic sees it: the status `StatusSummary` already worked out for it alone.
public struct SetHealth: Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var status: OverallStatus
    public init(id: UUID, name: String, status: OverallStatus) { self.id = id; self.name = name; self.status = status }
}

/// What the menu bar panel and the Overview say about many sets at once: what needs the owner, what is under way,
/// and a count of the rest. Built only from per-set `OverallStatus`, so there is one idea of "needs attention".
public struct HealthSummary: Equatable, Sendable {
    /// Most urgent first.
    public enum Kind: Int, Comparable, Sendable {
        case held, problem, previewNeeded, unfinished
        public static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }
    }

    public struct Item: Equatable, Identifiable, Sendable {
        public var id: UUID
        public var name: String
        public var kind: Kind
        public var status: OverallStatus
    }

    /// Needs the owner, or can't finish alone. Sorted by urgency, then name.
    public private(set) var attention: [Item] = []
    /// Backing up or uploading right now.
    public private(set) var active: [Item] = []
    public private(set) var backedUp = 0
    /// Sets with live progress.
    private var running = 0
    public private(set) var paused = 0
    /// Only on drives that aren't plugged in. Not a problem.
    public private(set) var driveAway = 0
    public private(set) var total = 0
    public private(set) var lastBackup: Date?

    public init(_ sets: [SetHealth]) {
        total = sets.count
        for s in sets {
            switch s.status {
            case .backedUp(let last, _):
                backedUp += 1
                lastBackup = max(lastBackup ?? last, last)
            case .paused: paused += 1
            case .driveNotConnected: driveAway += 1
            case .running:
                running += 1
                active.append(Item(id: s.id, name: s.name, kind: .unfinished, status: s.status))
            case .uploading: active.append(Item(id: s.id, name: s.name, kind: .unfinished, status: s.status))
            case .held: attention.append(Item(id: s.id, name: s.name, kind: .held, status: s.status))
            case .attention(let why):
                let preview = why.hasPrefix(StatusSummary.previewNeededPrefix)
                attention.append(Item(id: s.id, name: s.name, kind: preview ? .previewNeeded : .problem, status: s.status))
            case .unfinished, .waitingForDownload, .notAccepted:
                attention.append(Item(id: s.id, name: s.name, kind: .unfinished, status: s.status))
            case .notConfigured: break
            }
        }
        attention.sort { ($0.kind, $0.name.lowercased()) < ($1.kind, $1.name.lowercased()) }
        active.sort { $0.name.lowercased() < $1.name.lowercased() }
    }

    /// Nothing needs the owner and nothing is under way.
    public var isCalm: Bool { attention.isEmpty && active.isEmpty }

    /// Every set that isn't paused is backed up, and there is at least one.
    public var allBackedUp: Bool { total > paused && backedUp == total - paused }

    /// "12 sets backed up", "10 of 12 sets backed up, 2 paused". Nil with no sets. While a backup runs it is
    /// "Backing up", as a count would call healthy sets not backed up.
    public var countLine: String? {
        guard total > 0 else { return nil }
        let live = total - paused
        func sets(_ n: Int) -> String { "\(n.formatted()) \(n == 1 ? "set" : "sets")" }
        var line = backedUp == live ? "\(sets(backedUp)) backed up" : "\(backedUp.formatted()) of \(sets(live)) backed up"
        if running > 0 { line = "Backing up" }
        if active.count > running { line += ", \((active.count - running).formatted()) uploading" }
        if live == 0 { line = "\(sets(total)) paused" }
        else if paused > 0 { line += ", \(paused.formatted()) paused" }
        if driveAway > 0 { line += ", \(driveAway.formatted()) on a drive that isn't connected" }
        return line
    }
}

/// How many rows the menu bar panel shows, so it can't grow past the screen however many sets are failing.
public struct PanelRows: Equatable, Sendable {
    public var attention: Int
    public var progress: Int
    /// Attention rows left out, said as "N more". Progress lines aren't counted: the Overview doesn't list them.
    public var more: Int

    /// Attention rows and progress lines share `limit`. A running backup always keeps one line, so it never
    /// disappears behind a long list of problems.
    public init(attention: Int, progress: Int, limit: Int = 5) {
        let reserved = min(progress, 1)
        let a = min(attention, max(limit - reserved, 0))
        let p = min(progress, max(limit - a, 0))
        self.attention = a; self.progress = p
        more = attention - a
    }

    /// Nothing to list, though sets may be uploading with no agent running.
    public var isEmpty: Bool { attention == 0 && progress == 0 }
}

extension DestinationHealth {
    /// Something to do or look at, as opposed to working, waiting, or switched off.
    public var needsAttention: Bool {
        switch self {
        case .failing, .stopped, .mismatched, .held, .previewNeeded, .unfinished, .notAccepted: true
        case .unused, .paused, .notBackedUp, .uploading, .backedUp: false
        }
    }
}

/// One destination in one word, so the Overview's list and its summary line can't disagree.
public enum DestinationStanding: Equatable, Sendable {
    case fine, attention, notConnected, notBackedUp, uploading, paused, unused

    /// `warned` is a warning the destination raises itself, such as an unsaved Recovery Kit. A drive that's away
    /// isn't a problem, and a run it left unfinished isn't either, as a drive pulled mid-run is no failure.
    public init(_ health: DestinationHealth, driveAway: Bool, warned: Bool = false) {
        if warned { self = .attention; return }
        switch health {
        case .unused: self = .unused
        case .paused: self = .paused
        case .unfinished where driveAway: self = .notConnected
        case _ where health.needsAttention: self = .attention
        case _ where driveAway: self = .notConnected
        case .notBackedUp: self = .notBackedUp
        case .uploading: self = .uploading
        default: self = .fine
        }
    }
}

public enum DestinationSummary {
    /// "3 destinations, all fine", or plain counts of whatever isn't. Unused destinations aren't a concern. Nil with none.
    public static func line(_ all: [DestinationStanding]) -> String? {
        guard !all.isEmpty else { return nil }
        func count(_ s: DestinationStanding) -> Int { all.filter { $0 == s }.count }
        let attention = count(.attention)
        let parts = [(attention, attention == 1 ? "needs attention" : "need attention"), (count(.notConnected), "not connected"),
                     (count(.notBackedUp), "not backed up yet"), (count(.uploading), "uploading"), (count(.paused), "paused")]
            .filter { $0.0 > 0 }.map { "\($0.0.formatted()) \($0.1)" }
        let state = parts.isEmpty ? (count(.fine) > 0 ? "all fine" : "not used yet") : parts.joined(separator: ", ")
        return "\(all.count.formatted()) \(all.count == 1 ? "destination" : "destinations"), \(state)"
    }
}

public enum OverviewPrompts {
    /// What the owner still has to add before anything can be backed up.
    public static func lines(hasSets: Bool, hasDestinations: Bool) -> [String] {
        (hasSets ? [] : ["Add a folder to start backing it up."]) + (hasDestinations ? [] : ["Add a place to keep your backups."])
    }
}
