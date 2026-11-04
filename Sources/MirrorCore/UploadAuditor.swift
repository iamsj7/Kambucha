import Foundation

public struct AuditResult: Equatable, Sendable {
    /// Present in iCloud's view but not yet uploaded.
    public var pending: [String]
    /// iCloud will not sync these (not ubiquitous items), e.g. `*.tmp`, `*.nosync`, or files that are missing.
    public var refused: [String]
    /// Paths that no longer exist (deleted or renamed since the sync). Not a refusal, but never "uploaded" either.
    public var missing: [String]
    public init(pending: [String], refused: [String], missing: [String] = []) {
        self.pending = pending; self.refused = refused; self.missing = missing
    }
}

public protocol UploadAuditing: Sendable {
    func audit(_: [URL]) -> AuditResult
    /// Whether iCloud holds this item. Nil when that can't be read, which says nothing either way.
    func ubiquity(of: URL) -> Bool?
}

public extension UploadAuditing {
    func ubiquity(of url: URL) -> Bool? { audit([url]).refused.isEmpty }
}

/// Asks iCloud to bring a file back. Returns at once. The download happens in the background.
public protocol ICloudDownloading: Sendable {
    func requestDownload(of: URL) throws
}

/// Measured from a process with no iCloud entitlement: an evicted file came back within a second.
public struct ICloudDownloader: ICloudDownloading {
    public init() {}
    public func requestDownload(of url: URL) throws {
        try FileManager.default.startDownloadingUbiquitousItem(at: url)
    }
}

public struct ICloudAuditor: UploadAuditing {
    public init() {}

    /// Reads a flag, so an evicted item isn't downloaded (measured). An item outside iCloud reads
    /// successfully with no value, which is why only a failed read counts as unknown.
    public func ubiquity(of original: URL) -> Bool? {
        var st = stat()
        guard lstat(original.path, &st) == 0 else { return nil }
        var url = URL(fileURLWithPath: original.path)
        url.removeAllCachedResourceValues()
        guard let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey]) else { return nil }
        return values.isUbiquitousItem == true
    }

    public func audit(_ urls: [URL]) -> AuditResult {
        var result = AuditResult(pending: [], refused: [])
        for original in urls {
            // lstat separates a vanished path from a refused one. Probed in iCloud Drive: a symlink to a
            // non-iCloud file and a dangling symlink each reported isUbiquitousItem and
            // ubiquitousItemIsUploaded true (the target is not ubiquitous), so values come from the link itself.
            var st = stat()
            guard lstat(original.path, &st) == 0 else { result.missing.append(original.path); continue }
            var url = URL(fileURLWithPath: original.path)
            url.removeAllCachedResourceValues()
            guard let v = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemIsUploadedKey]),
                  v.isUbiquitousItem == true else {
                result.refused.append(original.path); continue
            }
            if v.ubiquitousItemIsUploaded != true { result.pending.append(original.path) }
        }
        return result
    }
}
