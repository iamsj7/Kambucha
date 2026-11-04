import Foundation

/// `.mirror` syncs and may delete (guarded by --max-delete). `.copyOnly` holds deletions.
public enum SyncMode: Equatable, Sendable { case mirror(maxDelete: Int), copyOnly }

public struct DestinationProfile: Equatable, Sendable {
    public var kind: DestinationKind
    public var encrypted: Bool
    public var modifyWindow: String
    public var extraFlags: [String]
    public var maxDuration: String?
    public var fullPassInterval: TimeInterval

    public init(kind: DestinationKind, encrypted: Bool, modifyWindow: String, extraFlags: [String],
                maxDuration: String?, fullPassInterval: TimeInterval) {
        self.kind = kind; self.encrypted = encrypted; self.modifyWindow = modifyWindow
        self.extraFlags = extraFlags; self.maxDuration = maxDuration; self.fullPassInterval = fullPassInterval
    }

    /// Spec section 8a.
    public static func profile(for destination: Destination) -> DestinationProfile {
        let day: TimeInterval = 86_400
        switch destination.kind {
        case .iCloudFolder:
            return DestinationProfile(kind: .iCloudFolder, encrypted: destination.encrypted, modifyWindow: "1ms",
                                      extraFlags: [], maxDuration: nil, fullPassInterval: day)
        case .googleDrive:
            return DestinationProfile(kind: .googleDrive, encrypted: destination.encrypted, modifyWindow: "1ms",
                                      extraFlags: ["--fast-list", "--drive-stop-on-upload-limit", "--drive-use-trash=false"],
                                      maxDuration: "25m", fullPassInterval: 7 * day)
        case .oneDrive:
            return DestinationProfile(kind: .oneDrive, encrypted: destination.encrypted, modifyWindow: "1s",
                                      extraFlags: ["--onedrive-no-versions", "--onedrive-hard-delete"],
                                      maxDuration: "25m", fullPassInterval: 7 * day)
        }
    }
}

/// `configPath` is `/dev/null` and `environment` is `[:]` for iCloud. Secrets live only in `environment`.
public struct RcloneContext: Equatable, Sendable {
    public var configPath: String
    public var environment: [String: String]
    public init(configPath: String, environment: [String: String]) {
        self.configPath = configPath; self.environment = environment
    }
}

public struct SyncRequest: Equatable, Sendable {
    public var source: URL
    public var destination: String
    public var backupDir: String
    public var filterFile: URL
    public var logFile: URL
    public var mode: SyncMode
    public var profile: DestinationProfile
    public var context: RcloneContext
    public var dryRun = false
    /// A run the owner asked to hurry. Scheduled runs never set it.
    public var fullSpeed = false
    public init(source: URL, destination: String, backupDir: String, filterFile: URL, logFile: URL,
                mode: SyncMode, profile: DestinationProfile, context: RcloneContext, dryRun: Bool = false,
                fullSpeed: Bool = false) {
        self.source = source; self.destination = destination; self.backupDir = backupDir
        self.filterFile = filterFile; self.logFile = logFile; self.mode = mode
        self.profile = profile; self.context = context; self.dryRun = dryRun; self.fullSpeed = fullSpeed
    }
}

public struct CheckRequest: Equatable, Sendable {
    public var source: URL
    public var destination: String
    public var filterFile: URL?
    public var filesFrom: URL?
    public var sizeOnly: Bool
    public var oneWay: Bool
    public var cryptCheck: Bool
    public var context: RcloneContext
    public var logFile: URL
    public init(source: URL, destination: String, filterFile: URL?, filesFrom: URL?, sizeOnly: Bool,
                oneWay: Bool, cryptCheck: Bool, context: RcloneContext, logFile: URL) {
        self.source = source; self.destination = destination; self.filterFile = filterFile
        self.filesFrom = filesFrom; self.sizeOnly = sizeOnly; self.oneWay = oneWay
        self.cryptCheck = cryptCheck; self.context = context; self.logFile = logFile
    }
}

public enum RcloneCommand {
    public static func arguments(_ r: SyncRequest) -> [String] {
        var a: [String]
        switch r.mode {
        case .mirror: a = ["sync"]
        case .copyOnly: a = ["copy"]
        }
        a += [r.source.path, r.destination]
        a += ["--modify-window", r.profile.modifyWindow]
        if case .mirror(let maxDelete) = r.mode {
            a += ["--track-renames", "--track-renames-strategy", "modtime", "--max-delete", String(maxDelete)]
        }
        // --links is a plain global flag. A ":local,links:" connection string would stop rclone
        // seeing both sides as one backend config and so disable APFS clones.
        a += ["--links", "--backup-dir", r.backupDir, "--filter-from", r.filterFile.path]
        a += ["--checkers", r.fullSpeed ? "8" : "2", "--transfers", r.fullSpeed ? "4" : "2"]
        a += ["--retries", "3", "--retries-sleep", "30s", "--low-level-retries", "10"]
        a += r.profile.extraFlags
        if let d = r.profile.maxDuration { a += ["--max-duration", d, "--cutoff-mode", "soft"] }
        a += common(logFile: r.logFile, context: r.context)
        if r.dryRun { a.append("--dry-run") }
        return a
    }

    public static func arguments(_ r: CheckRequest) -> [String] {
        var a = [r.cryptCheck ? "cryptcheck" : "check", r.source.path, r.destination, "--links"]
        if r.oneWay { a.append("--one-way") }
        if r.sizeOnly { a.append("--size-only") }
        // rclone doesn't combine --files-from with --filter-from.
        if let list = r.filesFrom { a += ["--files-from", list.path] }
        else if let f = r.filterFile { a += ["--filter-from", f.path] }
        a += common(logFile: r.logFile, context: r.context)
        return a
    }

    private static func common(logFile: URL, context: RcloneContext) -> [String] {
        ["--use-json-log", "-v", "--log-file", logFile.path, "--stats", "0", "--config", context.configPath]
    }
}
