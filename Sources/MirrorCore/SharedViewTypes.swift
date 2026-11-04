import Foundation

/// Types shared between the engine and the screens, so both can be built at the same time.

public struct ArchiveEntry: Identifiable, Equatable, Sendable {
    public var id: String; public var setName: String; public var stamp: Date; public var path: String; public var size: Int64
    public init(id: String, setName: String, stamp: Date, path: String, size: Int64) {
        self.id = id; self.setName = setName; self.stamp = stamp; self.path = path; self.size = size
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
    public init(includedBytes: Int64, skippedBytes: Int64, includedFiles: Int, groups: [PreviewGroup], decisions: [ReviewItem]) {
        self.includedBytes = includedBytes; self.skippedBytes = skippedBytes; self.includedFiles = includedFiles
        self.groups = groups; self.decisions = decisions
    }
}

/// Implemented by the engine in Task 15. Screens take this so they can be tested with fakes.
public protocol PreviewProviding: Sendable {
    func preview(set: BackupSet) async throws -> PreviewResult
    func rule(for group: PreviewGroup, included: Bool) -> UserRule
}

/// Archive and restore for one destination. Cloud access goes through the agent, as only it touches the Keychain.
public protocol ArchiveProviding: Sendable {
    func list(set: BackupSet, destination: Destination) async throws -> [ArchiveEntry]
    func restore(entry: ArchiveEntry, set: BackupSet, destination: Destination, to: URL) async throws
}
