import Foundation

public enum RestoreError: Error, Equatable, Sendable {
    case overSource(String)
}

/// Restores from `Archive/` to a chosen folder through rclone, so symlinks come back as symlinks.
public struct RestoreService: Sendable {
    private let rclone: any RcloneRunning
    private let archiveRoot: String?

    /// `archiveRoot`, when given, is the exact `Archive` folder restores must come from. Without it any path
    /// below an `Archive` folder is accepted.
    public init(rclone: any RcloneRunning, archiveRoot: String? = nil) {
        self.rclone = rclone; self.archiveRoot = archiveRoot
    }

    /// - `sources`: the source folders of the backup sets. A destination equal to, inside, or containing one is
    ///   refused unless `overwrite` is true.
    /// - `manifest`/`manifestSubpath`: links in the manifest that are missing from the restored files are
    ///   recreated; `manifestSubpath` is the set-relative folder that `to` holds.
    public func restore(from: String, context: RcloneContext, to: URL, sources: [URL] = [], overwrite: Bool = false,
                        manifest: SymlinkManifest? = nil, manifestSubpath: String = "") async throws -> RcloneResult {
        try ArchiveScope.validate(from, archiveRoot: archiveRoot)
        if !overwrite {
            let dest = PathGuard.canonical(to)
            for s in sources {
                let src = PathGuard.canonical(s)
                if PathGuard.denyContains(dest, src) || PathGuard.denyContains(src, dest) {
                    throw RestoreError.overSource(s.path)
                }
            }
        }
        try FileManager.default.createDirectory(at: to, withIntermediateDirectories: true)
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("mirror-restore-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: log) }
        let args = ["copy", from, to.path, "--links", "--retries", "3", "--use-json-log", "-v",
                    "--log-file", log.path, "--stats", "0", "--config", context.configPath]
        let result = try await rclone.execute(args, context: context, logFile: log)
        if result.outcome == .success, let manifest {
            manifest.recreateMissing(under: to, subpath: manifestSubpath)
        }
        return result
    }
}
