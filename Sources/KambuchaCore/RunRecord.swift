import Foundation

/// One finished (or skipped) run. Counts, names and relative paths only; never file contents.
public struct RunRecord: Codable, Identifiable, Equatable, Sendable {
    public enum Trigger: String, Codable, Sendable { case schedule, manual, daily }
    public enum Status: String, Codable, Sendable { case skipped, success, partial, held, failed, verificationFailed }

    public var id: UUID
    public var setID: UUID
    public var setName: String
    public var destinationID: UUID
    public var destinationName: String
    public var start: Date
    public var end: Date
    public var trigger: Trigger
    public var scope: String
    public var filesChecked: Int, copied: Int, renamed: Int, deleted: Int, archived: Int
    public var bytes: Int64
    public var verification: String
    /// Archive folders past their keep period that this run removed. Optional, so older records still read.
    public var archivesPruned: Int?
    public var pendingUploads: Int, refused: Int
    public var errors: [String]
    public var status: Status

    public init(id: UUID = UUID(), setID: UUID, setName: String, destinationID: UUID, destinationName: String,
                start: Date, end: Date, trigger: Trigger, scope: String,
                filesChecked: Int = 0, copied: Int = 0, renamed: Int = 0, deleted: Int = 0, archived: Int = 0,
                bytes: Int64 = 0, verification: String = "", pendingUploads: Int = 0, refused: Int = 0,
                errors: [String] = [], status: Status, archivesPruned: Int? = nil) {
        self.archivesPruned = archivesPruned
        self.id = id; self.setID = setID; self.setName = setName
        self.destinationID = destinationID; self.destinationName = destinationName
        self.start = start; self.end = end; self.trigger = trigger; self.scope = scope
        self.filesChecked = filesChecked; self.copied = copied; self.renamed = renamed
        self.deleted = deleted; self.archived = archived; self.bytes = bytes
        self.verification = verification; self.pendingUploads = pendingUploads; self.refused = refused
        self.errors = errors; self.status = status
    }
}

/// What the Activity screen wants from the history. The limit applies after this, so records people don't
/// care about (a scheduled run that found nothing to do) can't push the ones they do off the end.
public struct RunFilter: Equatable, Sendable {
    public enum Result: String, CaseIterable, Sendable { case all, problems, success }
    public var includeSkipped = false
    public var setID: UUID?
    public var result: Result = .all
    /// Matched against the set name, ignoring case.
    public var search = ""

    public init(includeSkipped: Bool = false, setID: UUID? = nil, result: Result = .all, search: String = "") {
        self.includeSkipped = includeSkipped; self.setID = setID; self.result = result; self.search = search
    }

    /// Every record, skipped runs too.
    public static let everything = RunFilter(includeSkipped: true)

    /// Problems are the runs that need a look: failed, unverified, unfinished, or holding deletions.
    public static func isProblem(_ s: RunRecord.Status) -> Bool {
        switch s {
        case .failed, .verificationFailed, .partial, .held: true
        case .success, .skipped: false
        }
    }

    /// Whether any record with this status can match, so a file known by name to be skipped needn't be read.
    func admits(_ s: RunRecord.Status) -> Bool {
        switch s {
        case .skipped: includeSkipped && result == .all
        case .success: result != .problems
        default: result != .success
        }
    }

    public func matches(_ r: RunRecord) -> Bool {
        guard admits(r.status) else { return false }
        if let setID, r.setID != setID { return false }
        let q = search.trimmingCharacters(in: .whitespaces)
        return q.isEmpty || r.setName.localizedCaseInsensitiveContains(q)
    }
}

/// Stores records at `<root>/runs/<stamp>-<id>.json`, or `<stamp>-skipped-<id>.json` for a skipped run. `root` is the
/// support directory. The name carries the one fact the Activity screen filters on most, so it can pass over the
/// many skipped runs a schedule writes without reading them. Older records have no marker and are read as before.
public struct RunRecordStore: Sendable {
    private let dir: URL
    public init(root: URL) { dir = root.appendingPathComponent("runs", isDirectory: true) }

    public static let scanBound = 5_000
    private static let skippedMarker = "-skipped-"
    private static let stampLength = 15   // yyyyMMddTHHmmss

    private static func stamp(_ d: Date) -> String {
        let f = Date.ISO8601FormatStyle(timeZone: .gmt).year().month().day().time(includingFractionalSeconds: false)
            .dateSeparator(.omitted).timeSeparator(.omitted)
        return d.formatted(f)
    }

    public func append(_ r: RunRecord) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        let marker = r.status == .skipped ? Self.skippedMarker : "-"
        let name = "\(Self.stamp(r.start))\(marker)\(r.id.uuidString).json"
        try e.encode(r).write(to: dir.appendingPathComponent(name), options: .atomic)
    }

    private func files() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: dir.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
    }

    private func load(_ url: URL) -> RunRecord? {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return (try? Data(contentsOf: url)).flatMap { try? d.decode(RunRecord.self, from: $0) }
    }

    /// Newest first by start time. Unreadable files are skipped. Includes skipped runs.
    public func recent(limit: Int) throws -> [RunRecord] { try recent(limit: limit, matching: .everything) }

    /// The newest `limit` records that match, newest first. See `search`.
    public func recent(limit: Int, matching filter: RunFilter, maxRead: Int = scanBound) throws -> [RunRecord] {
        try search(limit: limit, matching: filter, maxRead: maxRead).records
    }

    /// The newest `limit` records that match, newest first. Names sort by start time, so this reads newest-first and stops
    /// at `limit` matches; files marked skipped in their name are passed over unread when skipped runs can't match.
    /// `maxRead` bounds the files decoded, so a filter that matches little can't read the whole history.
    /// `reachedScanLimit` means files that could match were left unread, so a run that isn't here may still exist.
    public func search(limit: Int, matching filter: RunFilter, maxRead: Int = scanBound) throws -> (records: [RunRecord], reachedScanLimit: Bool) {
        guard limit > 0 else { return ([], false) }
        let passOverSkipped = !filter.admits(.skipped)
        var out: [RunRecord] = []
        var read = 0
        var reachedScanLimit = false
        for url in try files().sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) {
            if passOverSkipped, url.lastPathComponent.dropFirst(Self.stampLength).hasPrefix(Self.skippedMarker) { continue }
            guard read < maxRead else { reachedScanLimit = true; break }
            read += 1
            if let r = load(url), filter.matches(r) {
                out.append(r)
                if out.count == limit { break }
            }
        }
        return (out.sorted { $0.start > $1.start }, reachedScanLimit)
    }

    public func prune(olderThan cutoff: Date) throws {
        let cutoffStamp = Self.stamp(cutoff)
        for url in try files() {
            // A run that started after the cutoff's second ended after it: no need to read it.
            if url.lastPathComponent.prefix(Self.stampLength) > cutoffStamp { continue }
            if let r = load(url), r.end < cutoff { try FileManager.default.removeItem(at: url) }
        }
    }
}
