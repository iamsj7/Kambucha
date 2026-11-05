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
            case .running, .uploading: active.append(Item(id: s.id, name: s.name, kind: .unfinished, status: s.status))
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

    /// "12 sets backed up", "10 of 12 sets backed up, 2 paused". Nil with no sets.
    public var countLine: String? {
        guard total > 0 else { return nil }
        let live = total - paused
        func sets(_ n: Int) -> String { "\(n.formatted()) \(n == 1 ? "set" : "sets")" }
        var line = backedUp == live ? "\(sets(backedUp)) backed up" : "\(backedUp.formatted()) of \(sets(live)) backed up"
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
    /// Rows left out, said as "N more".
    public var more: Int

    /// Attention rows and progress lines share `limit`. A running backup always keeps one line, so it never
    /// disappears behind a long list of problems.
    public init(attention: Int, progress: Int, limit: Int = 5) {
        let reserved = min(progress, 1)
        let a = min(attention, max(limit - reserved, 0))
        let p = min(progress, max(limit - a, 0))
        self.attention = a; self.progress = p
        more = attention + progress - a - p
    }
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
