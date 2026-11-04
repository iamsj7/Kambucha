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

public enum DestinationKind: String, Codable, Sendable { case iCloudFolder, googleDrive, oneDrive, externalDrive }

public struct Destination: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: DestinationKind
    public var encrypted: Bool
    public var recoveryKitConfirmed = false
    /// The drive's volume UUID. Only for `.externalDrive`. Identity is by UUID, never by name or path.
    public var volumeUUID: String?
    /// Encryption defaults to on for Google Drive and OneDrive only. The iCloud folder relies on Advanced
    /// Data Protection and an external drive on its own password protection.
    public init(id: UUID = UUID(), name: String, kind: DestinationKind, encrypted: Bool? = nil,
                volumeUUID: String? = nil) {
        self.id = id; self.name = name; self.kind = kind; self.volumeUUID = volumeUUID
        self.encrypted = encrypted ?? (kind == .googleDrive || kind == .oneDrive)
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
    /// External drives: the `VolumeInfo.mountID` of the connection that last got a full pass.
    public var lastSeenMountID: String?
    public var lastFileCount: Int?
    public var consecutiveFailures = 0
    public var heldDeletions = 0
    public var pendingUploads = 0
    public var refusedSince: [String: Date] = [:]
    public var reviewItems: [ReviewItem] = []
    public init() {}
}

public struct Preset: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var markers: [String]
    public var alwaysExclude: [String]
    public var ambiguousExclude: [String]
}
