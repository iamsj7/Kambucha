import Foundation

/// The JSON the app and the agent exchange for `archive-list`, `archive-restore` and `dry-run-deletions`. One request on
/// stdin, one `Response` on stdout, the subcommand as the agent's only argument. Requests name the set and destination by
/// id, so the agent reads its own stored copies; they hold no secret. Dates are ISO 8601.
public enum AgentWire {
    public static let archiveList = "archive-list"
    public static let archiveRestore = "archive-restore"
    public static let dryRunDeletions = "dry-run-deletions"
    public static let subcommands: Set<String> = [archiveList, archiveRestore, dryRunDeletions]

    /// `archive-list` and `dry-run-deletions`.
    public struct PairRequest: Codable, Equatable, Sendable {
        public var set: UUID
        public var destination: UUID
        public init(set: UUID, destination: UUID) { self.set = set; self.destination = destination }
    }

    /// `archive-restore`. `path` is below the backup root (`Archive/<set>/<stamp>/...`); the agent pins the backup root, or
    /// the crypt endpoint for an encrypted destination. `to` is the absolute folder or file to restore into.
    public struct RestoreRequest: Codable, Equatable, Sendable {
        public var set: UUID
        public var destination: UUID
        public var path: String
        public var to: String
        public init(set: UUID, destination: UUID, path: String, to: String) {
            self.set = set; self.destination = destination; self.path = path; self.to = to
        }
    }

    public struct Entry: Codable, Equatable, Sendable {
        public var id: String
        public var setName: String
        public var stamp: Date
        public var path: String
        public var size: Int64
        public init(id: String, setName: String, stamp: Date, path: String, size: Int64) {
            self.id = id; self.setName = setName; self.stamp = stamp; self.path = path; self.size = size
        }
    }

    /// Every answer. `ok` must be true for success: a missing or false `ok` with no `failure` is an error. `entries` is set by
    /// `archive-list`, `files` by `dry-run-deletions` (every file a run would delete, `.git` ones included).
    public struct Response: Codable, Equatable, Sendable {
        public var ok: Bool?
        public var failure: AgentFailure?
        public var entries: [Entry]?
        public var files: [String]?
        public init(ok: Bool? = nil, failure: AgentFailure? = nil, entries: [Entry]? = nil, files: [String]? = nil) {
            self.ok = ok; self.failure = failure; self.entries = entries; self.files = files
        }
    }

    /// What `--allow-deletes <set> <destination> <count>` counts: deletions outside `.git` folders.
    public static func nonGitCount(_ files: [String]) -> Int {
        files.filter { !$0.split(separator: "/").contains(".git") }.count
    }
}
