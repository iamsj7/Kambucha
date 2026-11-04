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
    /// True when the destination can't hold symlinks (exFAT). Links are then read from the source only,
    /// through a `:local,links:` connection string, and stored as `.rclonelink` files.
    public var linksAsFiles: Bool
    /// Rename tracking uses the `hash` strategy, only where both sides have a hash. It is off for encrypted
    /// cloud destinations (no hash) and exFAT. The `modtime` strategy is never used: it trusts size and date
    /// only, so a same-size file written in the same window is matched wrongly and silently, on any destination.
    public var trackRenames: Bool
    /// True on exFAT. macOS stores extended attributes there as `._*` AppleDouble files, which sync would
    /// otherwise see as extras and delete, tripping `--max-delete`. Filtered on both sides, ahead of the set's filter.
    public var excludeAppleDouble: Bool
    /// rclone's own retries. A drive gets one try: a retry after an unplug would `mkdir` the vanished mount
    /// path, and only the coordinator can confirm the volume first.
    public var retries: Int

    public init(kind: DestinationKind, encrypted: Bool, modifyWindow: String, extraFlags: [String],
                maxDuration: String?, fullPassInterval: TimeInterval, linksAsFiles: Bool = false,
                trackRenames: Bool = true, excludeAppleDouble: Bool = false, retries: Int = 3) {
        self.retries = retries
        self.trackRenames = trackRenames; self.excludeAppleDouble = excludeAppleDouble
        self.kind = kind; self.encrypted = encrypted; self.modifyWindow = modifyWindow
        self.extraFlags = extraFlags; self.maxDuration = maxDuration; self.fullPassInterval = fullPassInterval
        self.linksAsFiles = linksAsFiles
    }

    /// Spec section 8a. `fileSystem` is the detected file system type of an external drive (for example
    /// "apfs", "hfs", "exfat"), known only at run time. Nil or unknown is treated as exFAT, the safe side.
    public static func profile(for destination: Destination, fileSystem: String? = nil) -> DestinationProfile {
        let day: TimeInterval = 86_400
        switch destination.kind {
        case .iCloudFolder:
            return DestinationProfile(kind: .iCloudFolder, encrypted: destination.encrypted, modifyWindow: "1ms",
                                      extraFlags: [], maxDuration: nil, fullPassInterval: day)
        case .googleDrive:
            return DestinationProfile(kind: .googleDrive, encrypted: destination.encrypted, modifyWindow: "1ms",
                                      extraFlags: ["--fast-list", "--drive-stop-on-upload-limit", "--drive-use-trash=false"],
                                      maxDuration: "25m", fullPassInterval: 7 * day,
                                      trackRenames: !destination.encrypted)
        case .oneDrive:
            return DestinationProfile(kind: .oneDrive, encrypted: destination.encrypted, modifyWindow: "1s",
                                      extraFlags: ["--onedrive-no-versions", "--onedrive-hard-delete"],
                                      maxDuration: "25m", fullPassInterval: 7 * day,
                                      trackRenames: !destination.encrypted)
        case .externalDrive:
            let symlinks = ExternalVolume.supportsSymlinks(fileSystem: fileSystem ?? "")
            return DestinationProfile(kind: .externalDrive, encrypted: false, modifyWindow: symlinks ? "1ms" : "2s",
                                      extraFlags: [], maxDuration: nil, fullPassInterval: 7 * day,
                                      linksAsFiles: !symlinks, trackRenames: symlinks,
                                      excludeAppleDouble: !symlinks, retries: 1)
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
    /// Set from `DestinationProfile.linksAsFiles`.
    public var linksAsFiles = false
    /// Set from `DestinationProfile.excludeAppleDouble`.
    public var excludeAppleDouble = false

    /// The same link handling and `._*` exclusion as the sync used, from its profile.
    public func applying(_ profile: DestinationProfile) -> CheckRequest {
        var r = self
        r.linksAsFiles = profile.linksAsFiles; r.excludeAppleDouble = profile.excludeAppleDouble
        return r
    }
    public init(source: URL, destination: String, filterFile: URL?, filesFrom: URL?, sizeOnly: Bool,
                oneWay: Bool, cryptCheck: Bool, context: RcloneContext, logFile: URL, linksAsFiles: Bool = false,
                excludeAppleDouble: Bool = false) {
        self.linksAsFiles = linksAsFiles; self.excludeAppleDouble = excludeAppleDouble
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
        a += [sourceArgument(r.source, linksAsFiles: r.profile.linksAsFiles), r.destination]
        a += ["--modify-window", r.profile.modifyWindow]
        if case .mirror(let maxDelete) = r.mode {
            if r.profile.trackRenames { a += ["--track-renames", "--track-renames-strategy", "hash"] }
            a += ["--max-delete", String(maxDelete)]
        }
        // --links is a plain global flag. A ":local,links:" connection string would stop rclone
        // seeing both sides as one backend config and so disable APFS clones.
        if !r.profile.linksAsFiles { a.append("--links") }
        // Filter rules are first match wins, so this must come before the set's `+ **`.
        if r.profile.excludeAppleDouble { a += ["--filter", "- ._*"] }
        a += ["--backup-dir", r.backupDir, "--filter-from", r.filterFile.path]
        a += ["--checkers", r.fullSpeed ? "8" : "2", "--transfers", r.fullSpeed ? "4" : "2"]
        a += ["--retries", String(r.profile.retries), "--retries-sleep", "30s", "--low-level-retries", "10"]
        a += r.profile.extraFlags
        if let d = r.profile.maxDuration { a += ["--max-duration", d, "--cutoff-mode", "soft"] }
        a += common(logFile: r.logFile, context: r.context)
        if r.dryRun { a.append("--dry-run") }
        return a
    }

    public static func arguments(_ r: CheckRequest) -> [String] {
        var a = [r.cryptCheck ? "cryptcheck" : "check", sourceArgument(r.source, linksAsFiles: r.linksAsFiles), r.destination]
        if !r.linksAsFiles { a.append("--links") }
        if r.oneWay { a.append("--one-way") }
        if r.sizeOnly { a.append("--size-only") }
        // rclone doesn't combine a file list with --filter-from. Raw, because the plain form treats `#`
        // as a comment and trims spaces, so such a name would go unchecked and still pass (measured).
        if let list = r.filesFrom { a += ["--files-from-raw", list.path] }
        else {
            // Excluded even with no filter file, as the whole-tree Deep check has none.
            if r.excludeAppleDouble { a += ["--filter", "- ._*"] }
            if let f = r.filterFile { a += ["--filter-from", f.path] }
        }
        a += common(logFile: r.logFile, context: r.context)
        return a
    }

    /// A plain path, or for a destination that can't hold symlinks a source-only `:local,links:` connection
    /// string. The destination stays a plain path, so it writes `.rclonelink` files. Clones don't apply
    /// across volumes, so losing the same-backend shortcut costs nothing here.
    static func sourceArgument(_ source: URL, linksAsFiles: Bool) -> String {
        guard linksAsFiles else { return source.path }
        // The path after the last colon is taken literally, so colons, commas and quotes in it need no escaping.
        return ":local,links:" + source.path
    }

    private static func common(logFile: URL, context: RcloneContext) -> [String] {
        ["--use-json-log", "-v", "--log-file", logFile.path, "--stats", "2s", "--stats-log-level", "NOTICE", "--config", context.configPath]
    }
}
