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
    /// `previewFingerprint` as it was when the owner accepted the preview. The agent starts no backup of a set
    /// unless this equals the current fingerprint, so changing rules, stacks or switches asks again.
    public var acceptedFingerprint: String?
    /// Destinations where the owner confirmed this set takes over a backup left under its name by a set that
    /// was removed. Only ever read when claiming, so it means nothing once a destination has been claimed.
    public var adoptsBackupIn: Set<UUID>?
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

extension BackupSet {
    /// Every set-and-destination pair of these sets.
    public static func pairs(of sets: [BackupSet]) -> Set<PairID> {
        Set(sets.flatMap { s in s.destinationIDs.map { PairID(set: s.id, destination: $0) } })
    }
}

public struct ReviewItem: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case trackedInExcluded, secretInExcluded, refusedByICloud }
    public var id: String
    public var path: String
    public var kind: Kind
    public init(id: String, path: String, kind: Kind) { self.id = id; self.path = path; self.kind = kind }

    /// The anchored rule that answers this item. Once the owner has one, the item is settled. A tracked
    /// item is a folder, and rclone only lets a rule beat `- folder/**` if it covers the same contents.
    public var rulePattern: String {
        let exact = "/" + FilterBuilder.escape(path)
        return kind == .trackedInExcluded ? exact + "/**" : exact
    }
}

/// How far an upload batch had got, and when. Two of these make a rate across wake-ups.
public struct UploadSample: Codable, Equatable, Sendable {
    public var done: Int
    public var at: Date
    public init(done: Int, at: Date) { self.done = done; self.at = at }
}

/// A file a check found different. Only a passing hash of the file itself ends one.
public struct Mismatch: Codable, Equatable, Sendable {
    public var since: Date
    /// iCloud has evicted it, so its hash has to wait for a download. It drives no runs meanwhile.
    public var evicted: Bool
    /// The owner has been told it couldn't be verified in time. They're told once.
    public var alerted = false
    public init(since: Date, evicted: Bool = false) { self.since = since; self.evicted = evicted }
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
    /// Files in the current upload batch, finished ones included. Zero with nothing pending.
    public var uploadTotal = 0
    public var uploadSample: UploadSample?
    /// A whole-set run started and hasn't passed. FSEvents may not replay why it was needed.
    public var wholeSetOwed = false
    /// `--max-duration` or Google's daily upload limit stopped the last run. It resumes at the next wake-up.
    public var syncIncomplete = false
    /// Project folders from the last scan. Nil until the first, so only later arrivals count as new.
    public var knownProjects: [String]?
    /// Set-relative paths a run touched or planned to, not yet proven by a hash check and an audit.
    /// Saved before the real sync and after each slice, so a failure or a kill can't forget them.
    public var verifyOwed: [String] = []
    /// `verifyOwed` outgrew its bound, so a whole-set hash check of the files on disk has to run.
    public var hashWholeSet = false
    /// A stop that never reached the backup: iCloud gone, source unreadable, marker lost, sign-in
    /// expired. Cleared only when the same check next passes.
    public var stoppedBy: Problem?
    /// Files a check found different, which `.verificationFailed` is about. All are in `verifyOwed`.
    public var mismatched: [String: Mismatch] = [:]
    /// The last evicted mismatch a download was requested for. The next batch starts after it, so a
    /// stuck file can't keep the others from their turn.
    public var downloadCursor: String?
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
        // One at a time: a kind that's since been retired costs that item, not the pair's whole history.
        reviewItems = try c.decodeIfPresent([LenientItem].self, forKey: .reviewItems)?.compactMap(\.item) ?? []
        uploadingPaths = try c.decodeIfPresent([String].self, forKey: .uploadingPaths) ?? []
        uploadingSince = try c.decodeIfPresent(Date.self, forKey: .uploadingSince)
        uploadTotal = try c.decodeIfPresent(Int.self, forKey: .uploadTotal) ?? 0
        uploadSample = try c.decodeIfPresent(UploadSample.self, forKey: .uploadSample)
        wholeSetOwed = try c.decodeIfPresent(Bool.self, forKey: .wholeSetOwed) ?? false
        syncIncomplete = try c.decodeIfPresent(Bool.self, forKey: .syncIncomplete) ?? false
        knownProjects = try c.decodeIfPresent([String].self, forKey: .knownProjects)
        verifyOwed = try c.decodeIfPresent([String].self, forKey: .verifyOwed) ?? []
        hashWholeSet = try c.decodeIfPresent(Bool.self, forKey: .hashWholeSet) ?? false
        stoppedBy = try c.decodeIfPresent(Problem.self, forKey: .stoppedBy)
        mismatched = try c.decodeIfPresent([String: Mismatch].self, forKey: .mismatched) ?? [:]
        downloadCursor = try c.decodeIfPresent(String.self, forKey: .downloadCursor)
    }

    /// Files iCloud must bring back before Kambucha can verify them.
    public var waitingForDownload: Int { mismatched.values.filter(\.evicted).count }

    /// Every recorded mismatch is evicted and within its time, so what's left is iCloud's to deliver.
    public var isOnlyWaiting: Bool {
        !mismatched.isEmpty && mismatched.values.allSatisfy { $0.evicted && !$0.alerted }
    }

    private struct LenientItem: Decodable {
        var item: ReviewItem?
        init(from decoder: any Decoder) { item = try? ReviewItem(from: decoder) }
    }

    /// The one source of "Backed Up": the last run finished, checks passed, everything reached iCloud.
    public var isBackedUp: Bool {
        lastFinished != nil && consecutiveFailures == 0 && heldDeletions == 0 && pendingUploads == 0
            && refusedSince.isEmpty && !syncIncomplete && !wholeSetOwed
            && verifyOwed.isEmpty && mismatched.isEmpty && !hashWholeSet && stoppedBy == nil
    }
}

public struct Preset: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var markers: [String]
    public var alwaysExclude: [String]
    public var ambiguousExclude: [String]
}
