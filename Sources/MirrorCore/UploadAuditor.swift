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

public protocol UploadAuditing: Sendable { func audit(_: [URL]) -> AuditResult }

public struct ICloudAuditor: UploadAuditing {
    public init() {}

    public func audit(_ urls: [URL]) -> AuditResult {
        var result = AuditResult(pending: [], refused: [])
        for original in urls {
            // lstat tells a vanished path from a refused one, and does not follow links. Probed on a
            // real iCloud Drive folder: resourceValues on a symlink URL (including a dangling one) reads
            // the link's own ubiquity state and never its target's, so links are audited like files.
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
