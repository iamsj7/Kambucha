import DiskArbitration
import Foundation
import IOKit

public struct VolumeInfo: Equatable, Sendable {
    public var uuid: String
    public var name: String
    public var mountPoint: URL
    public var fileSystem: String
    /// Free space that excludes purgeable space (`volumeAvailableCapacityKey`), so it is what is really there.
    public var freeBytes: Int64
    public var totalBytes: Int64
    /// Identifies this connection, and changes when the drive is unplugged and plugged back in. Empty when
    /// `statfs` failed, and then the 7 day interval decides.
    public var mountID: String
    /// True for the boot volume and the system volumes. Never a backup target.
    public var isSystem: Bool
    /// Reports internal and non-ejectable. A USB or Thunderbolt SSD can look like this, so it is kept, and
    /// Add Destination shows "This looks like an internal disk" for confirmation.
    public var looksInternal: Bool
    public init(uuid: String, name: String, mountPoint: URL, fileSystem: String, freeBytes: Int64,
                totalBytes: Int64 = 0, mountID: String = "", isSystem: Bool = false, looksInternal: Bool = false) {
        self.looksInternal = looksInternal
        self.uuid = uuid; self.name = name; self.mountPoint = mountPoint; self.fileSystem = fileSystem
        self.freeBytes = freeBytes; self.totalBytes = totalBytes; self.mountID = mountID; self.isSystem = isSystem
    }
}

/// A mounted volume that looks like a drive but can't be used, so setup can say why.
public struct UnsupportedVolume: Equatable, Sendable {
    public enum Reason: Equatable, Sendable { case noVolumeUUID, timeMachine, readOnly, notLocal, unreadable }
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
    private let includeHidden: Bool

    /// `includeHidden` also lists `-nobrowse` mounts, which is how test disk images attach. Real drives are not hidden.
    public init(includeHidden: Bool = false) { self.includeHidden = includeHidden }

    public enum Classification: Equatable, Sendable {
        case target(looksInternal: Bool)
        case unsupported(UnsupportedVolume.Reason)
        /// The boot volume, system volumes and anything outside `/Volumes`: refused without comment.
        case ignore
    }

    /// Any local, writable volume under `/Volumes` is a target, except the root, system volumes and Time Machine.
    /// `traits` is nil when reading the volume's resource keys failed, which is reported rather than dropped.
    public static func classify(path: String, traits: VolumeTraits?) -> Classification {
        guard path != "/", !path.hasPrefix("/System/"), path.hasPrefix("/Volumes/") else { return .ignore }
        guard let t = traits else { return .unsupported(.unreadable) }
        if t.isRootFileSystem { return .ignore }
        if t.isTimeMachine { return .unsupported(.timeMachine) }
        if !t.isLocal { return .unsupported(.notLocal) }
        if t.isReadOnly { return .unsupported(.readOnly) }
        return .target(looksInternal: Self.looksInternalValue(isInternal: t.isInternal, isEjectable: t.isEjectable))
    }

    /// A missing `volumeIsInternal` reads as internal, so the drive stays usable but needs confirmation.
    public static func looksInternalValue(isInternal: Bool?, isEjectable: Bool) -> Bool { (isInternal ?? true) && !isEjectable }

    public static func isBackupTarget(_ t: VolumeTraits) -> Bool {
        if case .target = classify(path: t.path, traits: t) { return true }
        return false
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

    private enum Entry { case usable(VolumeInfo), unsupported(UnsupportedVolume) }

    private func entries() -> [Entry] {
        let keys: [URLResourceKey] = [.volumeUUIDStringKey, .volumeNameKey, .volumeLocalizedFormatDescriptionKey,
                                      .volumeAvailableCapacityKey, .volumeTotalCapacityKey, .volumeIsRootFileSystemKey,
                                      .volumeIsLocalKey, .volumeIsInternalKey, .volumeIsEjectableKey, .volumeIsReadOnlyKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                         options: includeHidden ? [] : [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            let fm = FileManager.default
            let values = try? url.resourceValues(forKeys: Set(keys))
            // A volume whose essential keys can't be read is reported as unreadable, never dropped.
            var traits: VolumeTraits?
            if let v = values, let local = v.volumeIsLocal, let readOnly = v.volumeIsReadOnly {
                let tm = fm.fileExists(atPath: url.appendingPathComponent(".com.apple.timemachine.supported").path)
                    || fm.fileExists(atPath: url.appendingPathComponent("Backups.backupdb").path)
                traits = VolumeTraits(path: url.path, isRootFileSystem: v.volumeIsRootFileSystem ?? false, isLocal: local,
                                      isInternal: v.volumeIsInternal ?? true, isEjectable: v.volumeIsEjectable ?? false,
                                      isReadOnly: readOnly, isTimeMachine: tm)
            }
            let name = values?.volumeName ?? url.lastPathComponent
            switch Self.classify(path: url.path, traits: traits) {
            case .ignore: return nil
            case .unsupported(let reason): return .unsupported(UnsupportedVolume(name: name, mountPoint: url, reason: reason))
            case .target(let looksInternal):
                guard let v = values, let uuid = v.volumeUUIDString, !uuid.isEmpty else {
                    return .unsupported(UnsupportedVolume(name: name, mountPoint: url, reason: .noVolumeUUID))
                }
                let (fsType, mountID) = Self.statfsInfo(url)
                return .usable(VolumeInfo(
                    uuid: uuid, name: name, mountPoint: url,
                    fileSystem: Self.normalizedFileSystem(statfsName: fsType, description: v.volumeLocalizedFormatDescription ?? ""),
                    freeBytes: Int64(v.volumeAvailableCapacity ?? 0), totalBytes: Int64(v.volumeTotalCapacity ?? 0),
                    mountID: mountID, isSystem: false, looksInternal: looksInternal))
            }
        }
    }

    public func mounted() -> [VolumeInfo] { entries().compactMap { if case .usable(let i) = $0 { i } else { nil } } }

    public func unsupported() -> [UnsupportedVolume] { entries().compactMap { if case .unsupported(let u) = $0 { u } else { nil } } }

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
        return (type, mountID(device: from, fsid: "\(s.f_fsid.val.0)-\(s.f_fsid.val.1)", media: bsdName(from).flatMap(mediaID)))
    }

    /// The device node and fsid repeat when a drive comes back on the same port (measured), so on their own a
    /// reconnection would pass for the same connection. The media object is new with every attach.
    static func mountID(device: String, fsid: String, media: UInt64?) -> String {
        let base = "\(device)@\(fsid)"
        return media.map { "\(base)#\($0)" } ?? base
    }

    static func bsdName(_ device: String) -> String? {
        device.hasPrefix("/dev/") ? String(device.dropFirst("/dev/".count)) : nil
    }

    /// The I/O Registry ID of the volume's media object. Nil if it can't be read, which only costs the distinction.
    private static func mediaID(_ bsdName: String) -> UInt64? {
        guard let session = DASessionCreate(kCFAllocatorDefault),
              let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsdName) else { return nil }
        let media = DADiskCopyIOMedia(disk)
        guard media != 0 else { return nil }
        defer { IOObjectRelease(media) }
        var id: UInt64 = 0
        return IORegistryEntryGetRegistryEntryID(media, &id) == KERN_SUCCESS ? id : nil
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
        func stale() -> Bool {
            guard let pass = lastFullPass else { return true }
            return now.timeIntervalSince(pass) >= backstop
        }
        // statfs failed: no connection identity, so fall back to the interval rather than a pass every wake-up.
        if volume.mountID.isEmpty { return stale() }
        guard let last = lastSeenMountID, !last.isEmpty, last == volume.mountID else { return true }
        return stale()
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
