import Foundation

/// Types shared between the engine and the screens, so both can be built at the same time.

public struct ArchiveEntry: Identifiable, Equatable, Sendable {
    public var id: String; public var setName: String; public var stamp: Date; public var path: String; public var size: Int64
    public var isFolder: Bool
    public init(id: String, setName: String, stamp: Date, path: String, size: Int64, isFolder: Bool = false) {
        self.id = id; self.setName = setName; self.stamp = stamp; self.path = path; self.size = size; self.isFolder = isFolder
    }
}

public struct PreviewGroup: Identifiable, Equatable, Sendable {
    public var id: String; public var title: String; public var fileCount: Int; public var bytes: Int64
    public var included: Bool; public var pattern: String
    public init(id: String, title: String, fileCount: Int, bytes: Int64, included: Bool, pattern: String) {
        self.id = id; self.title = title; self.fileCount = fileCount; self.bytes = bytes
        self.included = included; self.pattern = pattern
    }
}

public struct PreviewResult: Equatable, Sendable {
    public var includedBytes: Int64; public var skippedBytes: Int64; public var includedFiles: Int
    public var groups: [PreviewGroup]; public var decisions: [ReviewItem]
    /// What the preview couldn't look at, said plainly. None of it stops a backup.
    public var warnings: [String]
    public init(includedBytes: Int64, skippedBytes: Int64, includedFiles: Int, groups: [PreviewGroup], decisions: [ReviewItem],
                warnings: [String] = []) {
        self.includedBytes = includedBytes; self.skippedBytes = skippedBytes; self.includedFiles = includedFiles
        self.groups = groups; self.decisions = decisions; self.warnings = warnings
    }
}

/// Implemented by the engine. Screens take this so they can be tested with fakes.
public protocol PreviewProviding: Sendable {
    func preview(set: BackupSet) async throws -> PreviewResult
    func rule(for group: PreviewGroup, included: Bool) -> UserRule
}

/// One thing in a folder of the latest backup.
public struct BackupItem: Codable, Identifiable, Equatable, Sendable {
    public var name: String; public var isFolder: Bool; public var size: Int64
    public var id: String { name }
    public init(name: String, isFolder: Bool, size: Int64) { self.name = name; self.isFolder = isFolder; self.size = size }
}

/// Archive and restore for one destination. Cloud access goes through the agent, as only it touches the Keychain.
public protocol ArchiveProviding: Sendable {
    func list(set: BackupSet, destination: Destination) async throws -> [ArchiveEntry]
    /// One folder of the latest backup. `path` is below the backup root: `Sets/<set>[/sub]`.
    func browse(path: String, set: BackupSet, destination: Destination) async throws -> [BackupItem]
    /// `entry.path` can be a file or a folder, under `Archive/` or `Sets/`.
    /// `replacing`: the owner already agreed to replace the file at `to`.
    func restore(entry: ArchiveEntry, set: BackupSet, destination: Destination, to: URL, replacing: Bool) async throws
}
