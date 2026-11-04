import Foundation

public struct AuditResult: Equatable, Sendable {
    /// Present in iCloud's view but not yet uploaded.
    public var pending: [String]
    /// iCloud will not sync these (not ubiquitous items), e.g. `*.tmp`, `*.nosync`, or files that are missing.
    public var refused: [String]
    public init(pending: [String], refused: [String]) { self.pending = pending; self.refused = refused }
}

public protocol UploadAuditing: Sendable { func audit(_: [URL]) -> AuditResult }

public struct ICloudAuditor: UploadAuditing {
    public init() {}

    public func audit(_ urls: [URL]) -> AuditResult {
        var result = AuditResult(pending: [], refused: [])
        for original in urls {
            // A fresh URL value on the link itself: nothing cached, no symlink following.
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
