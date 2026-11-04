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
    /// The owner confirmed "This looks like an internal disk" for this drive. Runs refuse a drive that looks
    /// internal while this is false.
    public var internalDiskConfirmed = false
    /// Encryption defaults to on for Google Drive and OneDrive only. The iCloud folder relies on Advanced
    /// Data Protection and an external drive on its own password protection.
    public init(id: UUID = UUID(), name: String, kind: DestinationKind, encrypted: Bool? = nil,
                volumeUUID: String? = nil, internalDiskConfirmed: Bool = false) {
        self.id = id; self.name = name; self.kind = kind; self.volumeUUID = volumeUUID
        self.internalDiskConfirmed = internalDiskConfirmed
        self.encrypted = encrypted ?? (kind == .googleDrive || kind == .oneDrive)
    }
}

extension Destination {
    private enum CodingKeys: String, CodingKey {
        case id, name, kind, encrypted, recoveryKitConfirmed, volumeUUID, internalDiskConfirmed
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decode(DestinationKind.self, forKey: .kind)
        encrypted = try c.decode(Bool.self, forKey: .encrypted)
        recoveryKitConfirmed = try c.decodeIfPresent(Bool.self, forKey: .recoveryKitConfirmed) ?? false
        volumeUUID = try c.decodeIfPresent(String.self, forKey: .volumeUUID)
        internalDiskConfirmed = try c.decodeIfPresent(Bool.self, forKey: .internalDiskConfirmed) ?? false
    }
}

public struct PairID: Codable, Hashable, Sendable {
    public var set: UUID
    public var destination: UUID
    public init(set: UUID, destination: UUID) { self.set = set; self.destination = destination }
    /// For what belongs to no pair: the agent itself failing to run.
    public static let agent = PairID(set: UUID(uuid: UUID_NULL), destination: UUID(uuid: UUID_NULL))
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
    /// Set-relative paths a run touched or planned to, not yet proven by a hash check and an audit.
    /// Saved before the real sync and after each slice, so a failure or a kill can't forget them.
    public var verifyOwed: [String] = []
    /// `verifyOwed` outgrew its bound, so only a whole-set hash check can prove what it held.
    public var hashWholeSet = false
    /// A stop that never reached the backup: iCloud gone, source unreadable, marker lost, sign-in
    /// expired. Cleared only when the same check next passes.
    public var stoppedBy: Problem?
    public init() {}

    /// Fields added after the first release of this file may be absent, and that must never make
    /// a pair's history unreadable: an unreadable state stops the pair.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lastEventID = try c.decodeIfPresent(UInt64.self, forKey: .lastEventID)
        lastFullPass = try c.decodeIfPresent(Date.self, forKey: .lastFullPass)
        lastDeepCheck = try c.decodeIfPresent(Date.self, forKey: .lastDeepCheck)
        lastFinished = try c.decodeIfPresent(Date.self, forKey: .lastFinished)
        lastDrill = try c.decodeIfPresent(Date.self, forKey: .lastDrill)
        lastSeenMountID = try c.decodeIfPresent(String.self, forKey: .lastSeenMountID)
        lastFileCount = try c.decodeIfPresent(Int.self, forKey: .lastFileCount)
        consecutiveFailures = try c.decodeIfPresent(Int.self, forKey: .consecutiveFailures) ?? 0
        heldDeletions = try c.decodeIfPresent(Int.self, forKey: .heldDeletions) ?? 0
        pendingUploads = try c.decodeIfPresent(Int.self, forKey: .pendingUploads) ?? 0
        refusedSince = try c.decodeIfPresent([String: Date].self, forKey: .refusedSince) ?? [:]
        reviewItems = try c.decodeIfPresent([ReviewItem].self, forKey: .reviewItems) ?? []
        uploadingPaths = try c.decodeIfPresent([String].self, forKey: .uploadingPaths) ?? []
        uploadingSince = try c.decodeIfPresent(Date.self, forKey: .uploadingSince)
        wholeSetOwed = try c.decodeIfPresent(Bool.self, forKey: .wholeSetOwed) ?? false
        syncIncomplete = try c.decodeIfPresent(Bool.self, forKey: .syncIncomplete) ?? false
        knownProjects = try c.decodeIfPresent([String].self, forKey: .knownProjects)
        verifyOwed = try c.decodeIfPresent([String].self, forKey: .verifyOwed) ?? []
        hashWholeSet = try c.decodeIfPresent(Bool.self, forKey: .hashWholeSet) ?? false
        stoppedBy = try c.decodeIfPresent(Problem.self, forKey: .stoppedBy)
    }

    /// The one source of "Backed Up": the last run finished, checks passed, everything reached iCloud.
    public var isBackedUp: Bool {
        lastFinished != nil && consecutiveFailures == 0 && heldDeletions == 0 && pendingUploads == 0
            && refusedSince.isEmpty && !syncIncomplete && !wholeSetOwed
            && verifyOwed.isEmpty && !hashWholeSet && stoppedBy == nil
    }
}

public struct Preset: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var markers: [String]
    public var alwaysExclude: [String]
    public var ambiguousExclude: [String]
}
