import Foundation

/// Stored once at `Mac Backup/.kambucha-root`. Never written inside `Sets/<name>/`.
/// Maps set ID to set name for every set this app has claimed a destination for.
public struct RootMarker: Codable, Equatable, Sendable {
    public static let fileName = ".kambucha-root"
    public var sets: [UUID: String]

    public init(sets: [UUID: String] = [:]) { self.sets = sets }

    // Dictionaries keyed by UUID encode as arrays by default; use string keys for a readable file.
    private enum CodingKeys: String, CodingKey { case sets }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.container(keyedBy: CodingKeys.self).decode([String: String].self, forKey: .sets)
        var out: [UUID: String] = [:]
        for (k, v) in raw {
            guard let id = UUID(uuidString: k) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                        debugDescription: "Bad set id \(k)"))
            }
            out[id] = v
        }
        sets = out
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Dictionary(uniqueKeysWithValues: sets.map { ($0.key.uuidString, $0.value) }), forKey: .sets)
    }

    public func claims(_ id: UUID) -> Bool { sets[id] != nil }

    public static func url(backupRoot: URL) -> URL { backupRoot.appendingPathComponent(fileName) }

    /// Returns nil when the marker file does not exist; throws if it exists but is unreadable.
    public static func load(backupRoot: URL) throws -> RootMarker? {
        let url = url(backupRoot: backupRoot)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(RootMarker.self, from: Data(contentsOf: url))
    }

    public func save(backupRoot: URL) throws {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: backupRoot, withIntermediateDirectories: true)
        try enc.encode(self).write(to: Self.url(backupRoot: backupRoot), options: .atomic)
    }
}
