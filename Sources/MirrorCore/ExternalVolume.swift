import Foundation

public struct VolumeInfo: Equatable, Sendable {
    public var uuid: String
    public var name: String
    public var mountPoint: URL
    public var fileSystem: String
    /// Free space that excludes purgeable space (`volumeAvailableCapacityKey`), so it is what is really there.
    public var freeBytes: Int64
    public var totalBytes: Int64
    /// Identifies this connection: device node plus filesystem ID. It changes when the drive is unplugged and
    /// plugged back in. Empty when unknown, which never counts as "the same connection".
    public var mountID: String
    /// True for the boot volume and the system volumes. Never a backup target.
    public var isSystem: Bool
    public init(uuid: String, name: String, mountPoint: URL, fileSystem: String, freeBytes: Int64,
                totalBytes: Int64 = 0, mountID: String = "", isSystem: Bool = false) {
        self.uuid = uuid; self.name = name; self.mountPoint = mountPoint; self.fileSystem = fileSystem
        self.freeBytes = freeBytes; self.totalBytes = totalBytes; self.mountID = mountID; self.isSystem = isSystem
    }
}

/// A mounted volume that looks like a drive but can't be used, so setup can say why.
public struct UnsupportedVolume: Equatable, Sendable {
    public enum Reason: Equatable, Sendable { case noVolumeUUID }
    public var name: String
    public var mountPoint: URL
    public var reason: Reason
    public init(name: String, mountPoint: URL, reason: Reason) {
        self.name = name; self.mountPoint = mountPoint; self.reason = reason
    }
}

public protocol VolumeLocating: Sendable {
    func mounted() -> [VolumeInfo]
    /// Drives that were left out of `mounted()` because they can't be identified.
    func unsupported() -> [UnsupportedVolume]
}
public extension VolumeLocating { func unsupported() -> [UnsupportedVolume] { [] } }

/// What `SystemVolumes` knows about a mounted volume before deciding to offer it.
public struct VolumeTraits: Equatable, Sendable {
    public var path: String
    public var isRootFileSystem: Bool, isLocal: Bool, isInternal: Bool, isEjectable: Bool
    public var isReadOnly: Bool, isTimeMachine: Bool
    public init(path: String, isRootFileSystem: Bool, isLocal: Bool, isInternal: Bool, isEjectable: Bool,
                isReadOnly: Bool, isTimeMachine: Bool) {
        self.path = path; self.isRootFileSystem = isRootFileSystem; self.isLocal = isLocal
        self.isInternal = isInternal; self.isEjectable = isEjectable; self.isReadOnly = isReadOnly
        self.isTimeMachine = isTimeMachine
    }
}

/// Reads the real mounted volumes, offering only writable, local, external or ejectable ones. A locked drive
/// doesn't mount, so it simply isn't listed.
public struct SystemVolumes: VolumeLocating {
    private let accepts: @Sendable (VolumeTraits) -> Bool
    private let includeHidden: Bool

    /// `accepts` is injectable so tests can keep disk images usable; the default is `isBackupTarget`.
    /// `includeHidden` also lists `-nobrowse` mounts, which is how test disk images attach. Real drives are not hidden.
    public init(includeHidden: Bool = false,
                accepts: @escaping @Sendable (VolumeTraits) -> Bool = SystemVolumes.isBackupTarget) {
        self.includeHidden = includeHidden; self.accepts = accepts
    }

    /// Not the boot or a system volume, local, writable, not Time Machine, and external or ejectable.
    public static func isBackupTarget(_ t: VolumeTraits) -> Bool {
        if t.isRootFileSystem || t.path == "/" || t.path.hasPrefix("/System/Volumes") { return false }
        if !t.isLocal || t.isReadOnly || t.isTimeMachine { return false }
        return !t.isInternal || t.isEjectable
    }

    /// Splits candidates (name, traits, UUID) into usable indexes and unsupported ones.
    public static func partition(_ candidates: [(String, VolumeTraits, String?)])
        -> (ok: [Int], bad: [(index: Int, reason: UnsupportedVolume.Reason)]) {
        var ok: [Int] = [], bad: [(index: Int, reason: UnsupportedVolume.Reason)] = []
        for (i, c) in candidates.enumerated() {
            if let u = c.2, !u.isEmpty { ok.append(i) } else { bad.append((i, .noVolumeUUID)) }
        }
        return (ok, bad)
    }

    /// The `statfs` type name when known, else the localized description read as a type, so "Mac OS Extended" is "hfs".
    public static func normalizedFileSystem(statfsName: String?, description: String) -> String {
        if let s = statfsName, !s.isEmpty { return s.lowercased() }
        let d = description.lowercased()
        if d.contains("apfs") { return "apfs" }
        if d.contains("mac os extended") || d.contains("hfs") { return "hfs" }
        if d.contains("exfat") { return "exfat" }
        if d.contains("ms-dos") || d.contains("fat") { return "msdos" }
        return d
    }

    private struct Entry { var info: VolumeInfo?; var traits: VolumeTraits; var name: String; var url: URL; var hasUUID: Bool }

    private func entries() -> [Entry] {
        let keys: [URLResourceKey] = [.volumeUUIDStringKey, .volumeNameKey, .volumeLocalizedFormatDescriptionKey,
                                      .volumeAvailableCapacityKey, .volumeTotalCapacityKey, .volumeIsRootFileSystemKey,
                                      .volumeIsLocalKey, .volumeIsInternalKey, .volumeIsEjectableKey, .volumeIsReadOnlyKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: includeHidden ? [] : [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            let fm = FileManager.default
            let tm = fm.fileExists(atPath: url.appendingPathComponent(".com.apple.timemachine.supported").path)
                || fm.fileExists(atPath: url.appendingPathComponent("Backups.backupdb").path)
            let traits = VolumeTraits(path: url.path, isRootFileSystem: v.volumeIsRootFileSystem ?? false,
                                      isLocal: v.volumeIsLocal ?? false, isInternal: v.volumeIsInternal ?? true,
                                      isEjectable: v.volumeIsEjectable ?? false, isReadOnly: v.volumeIsReadOnly ?? true,
                                      isTimeMachine: tm)
            let name = v.volumeName ?? url.lastPathComponent
            guard accepts(traits) else { return nil }
            guard let uuid = v.volumeUUIDString, !uuid.isEmpty else {
                return Entry(info: nil, traits: traits, name: name, url: url, hasUUID: false)
            }
            let (fsType, mountID) = Self.statfsInfo(url)
            let info = VolumeInfo(uuid: uuid, name: name, mountPoint: url,
                                  fileSystem: Self.normalizedFileSystem(statfsName: fsType,
                                                                        description: v.volumeLocalizedFormatDescription ?? ""),
                                  freeBytes: Int64(v.volumeAvailableCapacity ?? 0), totalBytes: Int64(v.volumeTotalCapacity ?? 0),
                                  mountID: mountID, isSystem: traits.isRootFileSystem)
            return Entry(info: info, traits: traits, name: name, url: url, hasUUID: true)
        }
    }

    public func mounted() -> [VolumeInfo] { entries().compactMap(\.info) }

    public func unsupported() -> [UnsupportedVolume] {
        entries().filter { !$0.hasUUID }.map { UnsupportedVolume(name: $0.name, mountPoint: $0.url, reason: .noVolumeUUID) }
    }

    /// The `statfs` type name (such as "apfs", "hfs", "exfat") and a per-connection mount ID.
    static func statfsInfo(_ url: URL) -> (type: String?, mountID: String) {
        var s = statfs()
        guard statfs(url.path, &s) == 0 else { return (nil, "") }
        let type = withUnsafePointer(to: &s.f_fstypename) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) { String(cString: $0) }
        }
        let from = withUnsafePointer(to: &s.f_mntfromname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MNAMELEN)) { String(cString: $0) }
        }
        return (type, "\(from)@\(s.f_fsid.val.0)-\(s.f_fsid.val.1)")
    }
}

public enum ExternalVolume {
    /// Matches by volume UUID only. A drive with the same name and another UUID is never returned.
    public static func find(_ destination: Destination, in volumes: [VolumeInfo]) -> VolumeInfo? {
        guard destination.kind == .externalDrive, let uuid = destination.volumeUUID, !uuid.isEmpty else { return nil }
        return volumes.first { $0.uuid.caseInsensitiveCompare(uuid) == .orderedSame }
    }

    /// Kept free after a run: 1 GB or 2% of the drive, whichever is greater.
    public static func reserve(for volume: VolumeInfo) -> Int64 {
        max(1_000_000_000, volume.totalBytes / 50)
    }

    /// The bytes to copy and the archive's growth must both fit, leaving the reserve.
    public static func fits(bytesToCopy: Int64, archiveBytes: Int64, volume: VolumeInfo) -> Bool {
        bytesToCopy + archiveBytes + reserve(for: volume) <= volume.freeBytes
    }

    /// True on a new connection (the mount changed or was never recorded), plus a weekly backstop because a
    /// mount ID can repeat. Otherwise the 30 minute wake-ups are ordinary runs on the change feed.
    public static func needsFullPass(lastSeenMountID: String?, volume: VolumeInfo, lastFullPass: Date?, now: Date,
                                     backstop: TimeInterval = 7 * 86_400) -> Bool {
        guard let last = lastSeenMountID, !last.isEmpty, !volume.mountID.isEmpty, last == volume.mountID else { return true }
        guard let pass = lastFullPass else { return true }
        return now.timeIntervalSince(pass) >= backstop
    }

    public static func supportsSymlinks(_ volume: VolumeInfo) -> Bool { supportsSymlinks(fileSystem: volume.fileSystem) }

    /// APFS and HFS+ hold symlinks. exFAT, FAT and anything unknown don't.
    public static func supportsSymlinks(fileSystem: String) -> Bool {
        let f = fileSystem.lowercased()
        return f == "apfs" || f.hasPrefix("hfs")
    }

    /// `<volume>/Mac Backup`. The root marker sits at `<volume>/Mac Backup/.mirror-root`.
    public static func backupRoot(on volume: VolumeInfo) -> URL {
        volume.mountPoint.appendingPathComponent(MirrorPaths.rootFolderName, isDirectory: true)
    }
}
