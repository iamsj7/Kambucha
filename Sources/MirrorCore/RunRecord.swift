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
    public var pendingUploads: Int, refused: Int
    public var errors: [String]
    public var status: Status

    public init(id: UUID = UUID(), setID: UUID, setName: String, destinationID: UUID, destinationName: String,
                start: Date, end: Date, trigger: Trigger, scope: String,
                filesChecked: Int = 0, copied: Int = 0, renamed: Int = 0, deleted: Int = 0, archived: Int = 0,
                bytes: Int64 = 0, verification: String = "", pendingUploads: Int = 0, refused: Int = 0,
                errors: [String] = [], status: Status) {
        self.id = id; self.setID = setID; self.setName = setName
        self.destinationID = destinationID; self.destinationName = destinationName
        self.start = start; self.end = end; self.trigger = trigger; self.scope = scope
        self.filesChecked = filesChecked; self.copied = copied; self.renamed = renamed
        self.deleted = deleted; self.archived = archived; self.bytes = bytes
        self.verification = verification; self.pendingUploads = pendingUploads; self.refused = refused
        self.errors = errors; self.status = status
    }
}

/// Stores records at `<root>/runs/<date>-<id>.json`. `root` is the support directory.
public struct RunRecordStore: Sendable {
    private let dir: URL
    public init(root: URL) { dir = root.appendingPathComponent("runs", isDirectory: true) }

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
        let name = "\(Self.stamp(r.start))-\(r.id.uuidString).json"
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

    /// Newest first by start time. Unreadable files are skipped.
    public func recent(limit: Int) throws -> [RunRecord] {
        // File names start with a sortable UTC stamp, so only the newest `limit` need decoding.
        let newest = try files().sorted { $0.lastPathComponent > $1.lastPathComponent }.prefix(max(limit, 0))
        return newest.compactMap(load).sorted { $0.start > $1.start }
    }

    public func prune(olderThan cutoff: Date) throws {
        for url in try files() {
            if let r = load(url), r.end < cutoff { try FileManager.default.removeItem(at: url) }
        }
    }
}
