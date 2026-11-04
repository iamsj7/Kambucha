import Foundation

public struct VolumeInfo: Equatable, Sendable {
    public var uuid: String
    public var name: String
    public var mountPoint: URL
    public var fileSystem: String
    public var freeBytes: Int64
    public init(uuid: String, name: String, mountPoint: URL, fileSystem: String, freeBytes: Int64) {
        self.uuid = uuid; self.name = name; self.mountPoint = mountPoint
        self.fileSystem = fileSystem; self.freeBytes = freeBytes
    }
}

public protocol VolumeLocating: Sendable { func mounted() -> [VolumeInfo] }

/// Reads the real mounted volumes. A locked drive doesn't mount, so it simply isn't listed.
public struct SystemVolumes: VolumeLocating {
    public init() {}

    public func mounted() -> [VolumeInfo] {
        let keys: [URLResourceKey] = [.volumeUUIDStringKey, .volumeNameKey, .volumeLocalizedFormatDescriptionKey,
                                      .volumeAvailableCapacityForImportantUsageKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                         options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            guard let v = try? url.resourceValues(forKeys: Set(keys)), let uuid = v.volumeUUIDString else { return nil }
            return VolumeInfo(uuid: uuid, name: v.volumeName ?? url.lastPathComponent, mountPoint: url,
                              fileSystem: Self.fileSystemType(url) ?? (v.volumeLocalizedFormatDescription ?? "").lowercased(),
                              freeBytes: v.volumeAvailableCapacityForImportantUsage ?? 0)
        }
    }

    /// The `statfs` type name, such as "apfs", "hfs", "exfat" or "msdos".
    static func fileSystemType(_ url: URL) -> String? {
        var s = statfs()
        guard statfs(url.path, &s) == 0 else { return nil }
        return withUnsafePointer(to: &s.f_fstypename) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) { String(cString: $0) }
        }
    }
}

public enum ExternalVolume {
    /// Matches by volume UUID only. A drive with the same name and another UUID is never returned.
    public static func find(_ destination: Destination, in volumes: [VolumeInfo]) -> VolumeInfo? {
        guard destination.kind == .externalDrive, let uuid = destination.volumeUUID, !uuid.isEmpty else { return nil }
        return volumes.first { $0.uuid.caseInsensitiveCompare(uuid) == .orderedSame }
    }

    public static func fits(bytesToCopy: Int64, volume: VolumeInfo) -> Bool { bytesToCopy <= volume.freeBytes }

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
