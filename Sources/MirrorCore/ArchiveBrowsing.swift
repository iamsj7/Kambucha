import Foundation

/// A folder of one backup run, with what's inside it counted all the way down, as restoring it restores all of that.
public struct ArchiveFolder: Identifiable, Equatable, Sendable {
    public var name: String
    /// Below the backup root: `Archive/<set>/<stamp>[/sub]`.
    public var path: String
    public var fileCount: Int
    public var size: Int64
    public var folders: [ArchiveFolder]
    public var files: [ArchiveEntry]
    public var id: String { path }
}

/// What one backup moved to the archive: everything under one `Archive/<set>/<stamp>` folder.
public struct ArchiveRun: Identifiable, Equatable, Sendable {
    public var id: String
    public var stamp: Date
    public var root: ArchiveFolder
    /// False for files whose path doesn't name a run, as there's no folder to restore then. Each file still can be.
    public var canRestoreFolders: Bool
    public var fileCount: Int { root.fileCount }
    public var size: Int64 { root.size }
}

public enum ArchiveGrouping {
    private final class Node {
        var folders: [Substring: Node] = [:]
        var files: [ArchiveEntry] = []

        func folder(_ name: Substring) -> Node {
            if let found = folders[name] { return found }
            let made = Node()
            folders[name] = made
            return made
        }

        func built(name: String, path: String) -> ArchiveFolder {
            let inside = folders.map { $0.value.built(name: String($0.key), path: "\(path)/\($0.key)") }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            let listed = files.map { (name: ($0.path as NSString).lastPathComponent, entry: $0) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return ArchiveFolder(name: name, path: path,
                                 fileCount: inside.reduce(files.count) { $0 + $1.fileCount },
                                 size: inside.reduce(files.reduce(0) { $0 + $1.size }) { $0 + $1.size },
                                 folders: inside, files: listed.map(\.entry))
        }
    }

    /// Newest run first. A run is keyed by its folder and not its date: `T10-00` and `T10-00-00` are the same moment
    /// but two folders, and restoring one must not leave the other out of what the owner was shown.
    public static func runs(from entries: [ArchiveEntry]) -> [ArchiveRun] {
        var found: [Substring: (stamp: Date, node: Node, placed: Bool)] = [:]
        for entry in entries {
            let parts = entry.path.split(separator: "/")
            let placed = parts.count >= 4 && parts[0] == "Archive"
            let key = placed ? entry.path[..<parts[2].endIndex] : Substring("Unplaced/\(entry.stamp.timeIntervalSince1970)")
            let run = found[key] ?? (entry.stamp, Node(), placed)
            found[key] = run
            var node = run.node
            for name in parts.dropFirst(placed ? 3 : 0).dropLast() { node = node.folder(name) }
            node.files.append(entry)
        }
        return found.map { key, run in
            let path = String(key)
            let name = (path as NSString).lastPathComponent
            return ArchiveRun(id: path, stamp: run.stamp, root: run.node.built(name: name, path: path), canRestoreFolders: run.placed)
        }
        .sorted { ($0.stamp, $0.id) > ($1.stamp, $1.id) }
    }
}

/// Where a listing was read from.
public struct ArchiveSource: Hashable, Sendable {
    public var pair: PairID
    public var setName: String
    public var destinationName: String
    public init(set: BackupSet, destination: Destination) {
        pair = PairID(set: set.id, destination: destination.id); setName = set.name; destinationName = destination.name
    }
}

/// One set's archive at one destination, grouped and made searchable once, when it's read.
public struct ArchiveListing: Sendable {
    fileprivate struct Item: Sendable {
        var entry: ArchiveEntry
        var key: [UInt8]
        var nameStart: Int
    }

    public let source: ArchiveSource
    public let runs: [ArchiveRun]
    fileprivate let items: [Item]

    public init(source: ArchiveSource, entries: [ArchiveEntry]) {
        self.source = source
        runs = ArchiveGrouping.runs(from: entries)
        items = entries.map { entry in
            let key = ArchiveSearch.folded(ArchiveSearch.relativePath(of: entry.path))
            return Item(entry: entry, key: key, nameStart: (key.lastIndex(of: UInt8(ascii: "/")) ?? -1) + 1)
        }
    }
}

public struct ArchiveHit: Identifiable, Equatable, Sendable {
    /// The same file is in many runs, sets and destinations, and an entry's own id only tells runs apart.
    public var id: String { "\(source.pair.set)/\(source.pair.destination)/\(entry.id)" }
    public var entry: ArchiveEntry
    public var source: ArchiveSource
    public var name: String { (entry.path as NSString).lastPathComponent }
    /// Where it lived in the set, empty at the top.
    public var folder: String { (String(ArchiveSearch.relativePath(of: entry.path)) as NSString).deletingLastPathComponent }

    public init(entry: ArchiveEntry, source: ArchiveSource) { self.entry = entry; self.source = source }
}

public struct ArchiveMatches: Equatable, Sendable {
    public var hits: [ArchiveHit] = []
    /// Everything that matched, which can be more than the `hits` kept.
    public var total = 0
    public init() {}
}

public enum ArchiveSearch {
    /// Enough for anything someone would read through. Past this they type another letter.
    public static let hitLimit = 1_000

    /// A path below its run. The rest is the same in every file of a set, so searching for "Docs" or "2026"
    /// would otherwise match all of it.
    public static func relativePath(of path: String) -> Substring {
        guard path.hasPrefix("Archive/") else { return path[...] }
        var slashes = 0
        for i in path.utf8.indices where path.utf8[i] == UInt8(ascii: "/") {
            slashes += 1
            if slashes == 3 { return path[path.utf8.index(after: i)...] }
        }
        return path[...]
    }

    /// Case and accents dropped. Composed first, as folding alone leaves Hangul and kana in the two spellings macOS can store.
    static func folded<S: StringProtocol>(_ text: S) -> [UInt8] {
        if text.utf8.allSatisfy({ $0 < 0x80 }) {
            return text.utf8.map { $0 >= 0x41 && $0 <= 0x5A ? $0 + 0x20 : $0 }
        }
        return Array(text.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).utf8)
    }

    private static func has(_ token: [UInt8], in key: [UInt8], from start: Int) -> Bool {
        key.count - start >= token.count && key.withUnsafeBytes { k in
            token.withUnsafeBytes { memmem(k.baseAddress! + start, k.count - start, $0.baseAddress!, $0.count) != nil }
        }
    }

    /// Files holding every word of `query` in their path below the run, those with all of it in the name first,
    /// then newest first. Stops early if the task is cancelled, as a newer query has replaced this one.
    public static func find(_ query: String, in listings: [ArchiveListing], limit: Int = hitLimit) -> ArchiveMatches {
        let words = query.split(whereSeparator: \.isWhitespace).map { folded($0) }.filter { !$0.isEmpty }
        var matches = ArchiveMatches()
        guard !words.isEmpty else { return matches }
        var found: [(inName: Bool, stamp: Date, listing: Int, item: Int)] = []
        for (l, listing) in listings.enumerated() {
            for (i, item) in listing.items.enumerated() {
                if i & 0xFFF == 0, Task.isCancelled { return matches }
                guard words.allSatisfy({ has($0, in: item.key, from: 0) }) else { continue }
                found.append((words.allSatisfy { has($0, in: item.key, from: item.nameStart) }, item.entry.stamp, l, i))
            }
        }
        matches.total = found.count
        found.sort {
            if $0.inName != $1.inName { return $0.inName }
            if $0.stamp != $1.stamp { return $0.stamp > $1.stamp }
            return ($0.listing, $0.item) < ($1.listing, $1.item)
        }
        matches.hits = found.prefix(limit).map { ArchiveHit(entry: listings[$0.listing].items[$0.item].entry, source: listings[$0.listing].source) }
        return matches
    }
}

/// Why one destination's archive couldn't be read, said for the owner rather than taken from the error.
public enum ArchiveReadFailure: Equatable, Sendable {
    case driveNotConnected, signInExpired, busy, unreadable

    public init(_ error: any Error) {
        switch error {
        case AgentFailure.driveNotConnected, GuardFailure.wrongDrive, GuardFailure.internalDiskNotConfirmed: self = .driveNotConnected
        case RcloneSessionError.notSignedIn, RcloneSessionError.invalidSignIn, ArchiveError.authExpired: self = .signInExpired
        case AgentFailure.busy: self = .busy
        default: self = .unreadable
        }
    }

    public var text: String {
        switch self {
        case .driveNotConnected: "Drive not connected"
        case .signInExpired: "Sign-in expired"
        case .busy: "Mirror was busy"
        case .unreadable: "Couldn't be read"
        }
    }
}

/// A destination that couldn't be searched, with one entry however many sets it holds: that's one thing to fix.
public struct ArchiveUnreadable: Identifiable, Equatable, Sendable {
    public var destinationID: UUID
    public var destinationName: String
    public var failure: ArchiveReadFailure
    public var sets: [String]
    public var id: String { "\(destinationID)/\(failure)" }

    public init(destinationID: UUID, destinationName: String, failure: ArchiveReadFailure, sets: [String]) {
        self.destinationID = destinationID; self.destinationName = destinationName; self.failure = failure; self.sets = sets
    }

    public static func summary(of failures: [(source: ArchiveSource, failure: ArchiveReadFailure)]) -> [ArchiveUnreadable] {
        var summary: [ArchiveUnreadable] = []
        for (source, failure) in failures {
            if let i = summary.firstIndex(where: { $0.destinationID == source.pair.destination && $0.failure == failure }) {
                summary[i].sets.append(source.setName)
            } else {
                summary.append(ArchiveUnreadable(destinationID: source.pair.destination, destinationName: source.destinationName,
                                                 failure: failure, sets: [source.setName]))
            }
        }
        return summary.map { var s = $0; s.sets.sort { $0.localizedStandardCompare($1) == .orderedAscending }; return s }
            .sorted { $0.destinationName.localizedStandardCompare($1.destinationName) == .orderedAscending }
    }

    /// "Drive not connected. Photos and Docs weren't searched."
    public var text: String {
        let names = sets.count <= 3 ? sets.formatted(.list(type: .and)) : "\(sets.count) sets"
        return "\(failure.text). \(names) \(sets.count == 1 ? "wasn't" : "weren't") searched."
    }
}

/// Takes turns at the agent, so listings for a search can't get in the way of what the owner is waiting for.
@MainActor
public final class ArchiveAgentQueue {
    private struct Waiter {
        var pair: PairID?
        var urgent: Bool
        var go: CheckedContinuation<Void, Never>
    }

    private let limit: Int
    private var running = 0
    private var waiting: [Waiter] = []

    public init(limit: Int) { self.limit = max(1, limit) }

    /// Urgent work goes ahead of everything else that's waiting, but never stops what's already running.
    public func turn<T: Sendable>(for pair: PairID? = nil, urgent: Bool, _ work: () async throws -> T) async rethrows -> T {
        if running < limit {
            running += 1
        } else {
            await withCheckedContinuation { waiting.append(Waiter(pair: pair, urgent: urgent, go: $0)) }
        }
        defer { finished() }
        return try await work()
    }

    /// The owner just asked for something that was queued behind a search.
    public func hurry(_ pair: PairID) {
        for i in waiting.indices where waiting[i].pair == pair { waiting[i].urgent = true }
    }

    private func finished() {
        guard !waiting.isEmpty else { running -= 1; return }
        waiting.remove(at: waiting.firstIndex(where: \.urgent) ?? 0).go.resume()   // the turn passes on, so `running` stays
    }
}
