import Foundation

public struct UserRule: Codable, Equatable, Identifiable, Sendable {
    public enum Action: String, Codable, Sendable { case include, exclude }
    public var id: UUID
    public var pattern: String
    public var action: Action
    public init(id: UUID = UUID(), pattern: String, action: Action) {
        self.id = id; self.pattern = pattern; self.action = action
    }
}

public struct DeletionPolicy: Codable, Equatable, Sendable {
    public var minFiles = 100
    public var percent = 5.0
    public var absoluteMax = 2000
    public init(minFiles: Int = 100, percent: Double = 5.0, absoluteMax: Int = 2000) {
        self.minFiles = minFiles; self.percent = percent; self.absoluteMax = absoluteMax
    }
}

public struct BackupSet: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var source: URL
    public var presets: Set<String>
    public var backupSecrets = true
    public var backupGit = true
    public var rules: [UserRule] = []
    public var deletion = DeletionPolicy()
    public var archiveDays = 30
    public var isPaused = false
    public var destinationIDs: [UUID] = []
    public init(id: UUID = UUID(), name: String, source: URL, presets: Set<String> = [],
                destinationIDs: [UUID] = []) {
        self.id = id; self.name = name; self.source = source; self.presets = presets
        self.destinationIDs = destinationIDs
    }
}

public enum DestinationKind: String, Codable, Sendable { case iCloudFolder, googleDrive, oneDrive }

public struct Destination: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: DestinationKind
    public var encrypted: Bool
    public var recoveryKitConfirmed = false
    /// Encryption defaults to on for cloud kinds and off for the iCloud folder.
    public init(id: UUID = UUID(), name: String, kind: DestinationKind, encrypted: Bool? = nil) {
        self.id = id; self.name = name; self.kind = kind
        self.encrypted = encrypted ?? (kind != .iCloudFolder)
    }
}

public struct PairID: Codable, Hashable, Sendable {
    public var set: UUID
    public var destination: UUID
    public init(set: UUID, destination: UUID) { self.set = set; self.destination = destination }
}

public struct ReviewItem: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case trackedInExcluded, secretInExcluded, refusedByICloud }
    public var id: String
    public var path: String
    public var kind: Kind
    public init(id: String, path: String, kind: Kind) { self.id = id; self.path = path; self.kind = kind }
}

public struct SetState: Codable, Equatable, Sendable {
    public var lastEventID: UInt64?
    public var lastFullPass: Date?
    public var lastDeepCheck: Date?
    public var lastFinished: Date?
    public var lastDrill: Date?
    public var lastFileCount: Int?
    public var consecutiveFailures = 0
    public var heldDeletions = 0
    public var pendingUploads = 0
    public var refusedSince: [String: Date] = [:]
    public var reviewItems: [ReviewItem] = []
    /// Mirror-relative paths behind `pendingUploads`, so later wake-ups can re-read them with no disk walk.
    public var uploadingPaths: [String] = []
    /// When uploads last made progress. Nil with nothing pending.
    public var uploadingSince: Date?
    /// A whole-set run started and hasn't passed. FSEvents may not replay why it was needed.
    public var wholeSetOwed = false
    /// `--max-duration` stopped the last run. It resumes at the next wake-up.
    public var syncIncomplete = false
    /// Project folders from the last scan. Nil until the first, so only later arrivals count as new.
    public var knownProjects: [String]?
    public init() {}

    /// The one source of "Backed Up": the last run finished, checks passed, everything reached iCloud.
    public var isBackedUp: Bool {
        lastFinished != nil && consecutiveFailures == 0 && heldDeletions == 0 && pendingUploads == 0
            && refusedSince.isEmpty && !syncIncomplete && !wholeSetOwed
    }
}

public struct Preset: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var markers: [String]
    public var alwaysExclude: [String]
    public var ambiguousExclude: [String]
}
