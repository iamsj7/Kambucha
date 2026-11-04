import Foundation
import Observation

// Logic behind the main window, kept out of the views so it can be tested with fakes.

// MARK: Injected services

/// Supplies the files a held deletion would remove, from a dry run. The engine implements it.
public protocol DeletionDryRunProviding: Sendable {
    func heldDeletions(set: BackupSet) async throws -> [String]
}

/// Finds files already mirrored that new exclude rules would now skip, and moves them to the archive
/// when the owner asks. Never automatic (spec section 9).
public protocol MirroredExcludeInspecting: Sendable {
    func mirroredFiles(matching excludes: [UserRule], set: BackupSet) async throws -> [String]
    func archive(_ files: [String], set: BackupSet) async throws
}

public enum ExcludeResolution: Sendable { case moveToArchive, leaveInPlace }

// MARK: Preview acceptance

/// Remembers which rule set the owner accepted for each backup set. A change to the rules, presets or
/// switches makes the set unaccepted again, so the preview reopens. Stored as plain JSON, no secrets.
public final class PreviewAcceptanceStore: Sendable {
    private let url: URL
    public init(root: URL) { url = root.appendingPathComponent("preview-accepted.json") }

    public static func fingerprint(_ set: BackupSet) -> String {
        let rules = set.rules.map { "\($0.action.rawValue):\($0.pattern)" }.joined(separator: "\n")
        return ["presets=" + set.presets.sorted().joined(separator: ","), "secrets=\(set.backupSecrets)",
                "git=\(set.backupGit)", rules].joined(separator: "|")
    }

    public func isAccepted(_ set: BackupSet) -> Bool { load()[set.id.uuidString] == Self.fingerprint(set) }

    public func accept(_ set: BackupSet) {
        var all = load()
        all[set.id.uuidString] = Self.fingerprint(set)
        write(all)
    }

    public func forget(_ id: UUID) {
        var all = load()
        all[id.uuidString] = nil
        write(all)
    }

    private func load() -> [String: String] {
        (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))) ?? [:]
    }

    private func write(_ all: [String: String]) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(all).write(to: url, options: .atomic)
    }
}

// MARK: Preview

@MainActor @Observable
public final class PreviewController {
    public private(set) var set: BackupSet
    public private(set) var result: PreviewResult?
    public private(set) var loadError: String?
    public private(set) var isLoading = false
    /// Mirrored files a fresh exclude would now skip: the owner must choose what happens to them.
    public private(set) var pendingImpact: [String]?

    @ObservationIgnored public var onSetChanged: ((BackupSet) -> Void)?
    @ObservationIgnored private let provider: any PreviewProviding
    @ObservationIgnored private let inspector: (any MirroredExcludeInspecting)?

    public init(set: BackupSet, provider: any PreviewProviding, inspector: (any MirroredExcludeInspecting)?) {
        self.set = set; self.provider = provider; self.inspector = inspector
    }

    public func load() async {
        isLoading = true
        defer { isLoading = false }
        do { result = try await provider.preview(set: set); loadError = nil }
        catch { loadError = SetupFailureText.message(for: error) }
    }

    /// Unticking saves an exclude rule and ticking an include rule, replacing any earlier rule for the
    /// same pattern. Every change recomputes the preview.
    public func setIncluded(_ included: Bool, for group: PreviewGroup) async {
        let rule = provider.rule(for: group, included: included)
        set.rules.removeAll { $0.pattern == rule.pattern }
        set.rules.append(rule)
        onSetChanged?(set)
        await load()
        pendingImpact = nil
        if rule.action == .exclude, let inspector,
           let files = try? await inspector.mirroredFiles(matching: [rule], set: set), !files.isEmpty {
            pendingImpact = files
        }
    }

    public func resolveImpact(_ choice: ExcludeResolution) async {
        guard let files = pendingImpact else { return }
        pendingImpact = nil
        if choice == .moveToArchive {
            do { try await inspector?.archive(files, set: set) }
            catch { loadError = SetupFailureText.message(for: error) }
        }
    }
}

// MARK: Deletion review

@MainActor @Observable
public final class DeletionReview {
    public let set: BackupSet
    public private(set) var files: [String] = []
    public private(set) var isLoaded = false
    public private(set) var loadError: String?

    @ObservationIgnored private let provider: any DeletionDryRunProviding

    public init(set: BackupSet, provider: any DeletionDryRunProviding) { self.set = set; self.provider = provider }

    public var count: Int { files.count }

    public func load() async {
        do { files = try await provider.heldDeletions(set: set); isLoaded = true; loadError = nil }
        catch { loadError = SetupFailureText.message(for: error); isLoaded = false }
    }

    /// The agent is told how many deletions were reviewed, so a bigger list later is held again.
    /// Nil until a non-empty list has been shown.
    public var allowOnceArguments: [String]? {
        guard isLoaded, count > 0 else { return nil }
        return ["--allow-deletes", set.id.uuidString, String(count)]
    }
}

// MARK: Destinations

public enum DestinationRules {
    public static func encryptionDefault(_ kind: DestinationKind) -> Bool { kind != .iCloudFolder }
    /// The iCloud folder is covered by Advanced Data Protection, so no switch is offered.
    public static func encryptionOffered(_ kind: DestinationKind) -> Bool { kind != .iCloudFolder }
    public static func needsClientID(_ kind: DestinationKind) -> Bool { kind == .googleDrive }
    public static let encryptionOffWarning =
        "Without encryption the provider can read secrets such as .env files and private keys. This can't be changed later without creating a new destination."

    public static func notConnectedText(lastBackedUp: Date?, now: Date = Date()) -> String {
        guard let last = lastBackedUp else { return "Not connected, not backed up yet" }
        let days = Calendar.current.dateComponents([.day], from: last, to: now).day ?? 0
        switch days {
        case ..<1: return "Not connected, last backed up today"
        case 1: return "Not connected, last backed up 1 day ago"
        default: return "Not connected, last backed up \(days) days ago"
        }
    }

    public static func filesystemWarning(_ name: String) -> String? {
        name.lowercased().contains("exfat")
            ? "exFAT can't store symbolic links or file permissions, and it keeps coarser timestamps. Mirror stores links as .rclonelink files. APFS is recommended."
            : nil
    }
}

// MARK: Wording

public enum SetupFailureText {
    /// After these two, pasting the Recovery Kit is the way forward.
    public static func needsRecoveryKit(_ error: any Error) -> Bool {
        switch error as? RemoteSetupError {
        case .vaultLostNeedsRecoveryKit, .signInLostNeedsRecoveryKit: true
        default: false
        }
    }

    public static func message(for error: any Error) -> String {
        switch error {
        case let e as RemoteSetupError: return message(e)
        case let e as GuardFailure: return message(e)
        case let e as AgentClientError:
            switch e {
            case .requestTooLarge: return "That text is too long to be a Recovery Kit."
            case .noResponse: return "The backup agent did not answer. Try again."
            }
        case is CancellationError: return "Cancelled."
        default: return "Something went wrong: \(error.localizedDescription)"
        }
    }

    private static func message(_ e: RemoteSetupError) -> String {
        switch e {
        case .noSignInNeeded: "This destination doesn't need a sign-in."
        case .clientIDRequired: "Enter your Google client ID."
        case .clientSecretRequired: "Enter your Google client secret."
        case .noToken: "The sign-in did not finish. Try again."
        case .clientChangeRefused: "This destination is already signed in with a different Google client."
        case .vaultLostNeedsRecoveryKit: "This Mac no longer holds the encryption keys for this destination. Paste your Recovery Kit to restore them."
        case .signInLostNeedsRecoveryKit: "This Mac no longer holds the sign-in for this destination. Paste your Recovery Kit to restore it."
        case .vaultAlreadyPresent: "This destination already has encryption keys on this Mac."
        case .kitDoesNotMatchDestination: "That Recovery Kit is for a different destination."
        case .kitDoesNotOpenBackup: "That Recovery Kit does not open this backup."
        case .couldNotVerifyKit: "Mirror could not check that Recovery Kit against the backup. Check the connection and try again."
        case .signInFailed(let code): "Sign-in failed (code \(code))."
        }
    }

    private static func message(_ e: GuardFailure) -> String {
        switch e {
        case .sourceMissing: "That folder doesn't exist."
        case .sourceUnreadable: "Mirror can't read that folder. Check Full Disk Access in System Settings."
        case .sourceInsideICloud: "That folder is already in iCloud Drive. Choose a folder outside it."
        case .sourceContainsBackupRoot: "That folder contains the backup itself. Choose a different folder."
        case .setsOverlap(let name): "That folder overlaps the set \"\(name)\"."
        case .setNameTaken(let name): "A set called \"\(name)\" already exists."
        case .iCloudUnavailable: "iCloud Drive isn't available."
        case .destinationOutsideRoot, .destinationUnclaimed: "The backup folder isn't safe to use."
        case .sourceSuspiciouslyEmpty: "That folder looks empty compared with the last backup."
        }
    }
}

// MARK: Adding a set

public enum NewSet {
    /// A set named for the folder, with the stack presets its project markers suggest. macOS junk is
    /// always excluded by the filter builder, so it needs no preset.
    public static func make(folder: URL, presets: [Preset], destinations: [Destination]) -> BackupSet {
        let found = StackDetector(presets: presets).detect(in: folder)
        let ids = found.reduce(into: Set<String>()) { $0.formUnion($1.presetIDs) }
        return BackupSet(name: PathGuard.sanitizedComponent(folder.lastPathComponent), source: folder,
                         presets: ids, destinationIDs: destinations.prefix(1).map(\.id))
    }
}
