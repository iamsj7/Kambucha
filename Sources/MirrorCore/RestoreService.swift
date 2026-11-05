import Foundation

public enum RestoreError: Error, Equatable, Codable, Sendable {
    case overSource(String)
    case destinationNotEmpty(String)
}

/// Restores from `Sets/<set>[/sub]` or `Archive/<set>/<stamp>[/sub]` to a chosen folder through rclone, so symlinks come back as symlinks.
public struct RestoreService: Sendable {
    private let rclone: any RcloneRunning
    private let backupRoot: String?

    /// `backupRoot`, when given, is the exact backup root restores must come from. Required for local paths; without
    /// it only remote paths below a `Sets` or `Archive` folder are accepted.
    public init(rclone: any RcloneRunning, backupRoot: String? = nil) {
        self.rclone = rclone; self.backupRoot = backupRoot
    }

    /// - `sources`: the source folders of the backup sets. A destination equal to, inside, or containing one is
    ///   refused unless `overwrite` is true. Required, so the guard cannot be forgotten. One file may go inside a
    ///   source, as that's where a deleted file belongs; what's already there still needs `replacingFile`.
    /// - A `to` folder that already holds anything is refused unless `overwrite` is true.
    /// - `asFile`: `from` is one file and `to` names the file to create, which must not already exist.
    /// - `replacingFile`: the owner agreed to replace the plain file at `to`. Never a folder or a link.
    /// - `manifest`/`manifestSubpath`: links in the manifest that are missing from the restored files are
    ///   recreated; `manifestSubpath` is the set-relative folder that `to` holds.
    public func restore(from: String, context: RcloneContext, to: URL, sources: [URL], overwrite: Bool = false, asFile: Bool = false,
                        replacingFile: Bool = false, manifest: SymlinkManifest? = nil, manifestSubpath: String = "") async throws -> RcloneResult {
        try ArchiveScope.validateRestore(from, backupRoot: backupRoot)
        if !overwrite {
            let dest = PathGuard.canonical(to)
            for s in sources {
                let src = PathGuard.canonical(s)
                if PathGuard.denyContains(src, dest) || (!asFile && PathGuard.denyContains(dest, src)) {
                    throw RestoreError.overSource(s.path)
                }
            }
            if let items = try? FileManager.default.contentsOfDirectory(atPath: to.path), !items.isEmpty {
                throw RestoreError.destinationNotEmpty(to.path)
            }
            var st = stat()
            if asFile, lstat(to.path, &st) == 0, !(replacingFile && (st.st_mode & S_IFMT) == S_IFREG) {
                throw RestoreError.destinationNotEmpty(to.path)
            }
        }
        try FileManager.default.createDirectory(at: asFile ? to.deletingLastPathComponent() : to, withIntermediateDirectories: true)
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("mirror-restore-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: log) }
        let args = [asFile ? "copyto" : "copy", "--links", "--retries", "3", "--use-json-log", "-v",
                    "--log-file", log.path, "--stats", "0", "--config", context.configPath, "--", from, to.path]
        let result = try await rclone.execute(args, context: context, logFile: log)
        if result.outcome == .success, let manifest {
            manifest.recreateMissing(under: to, subpath: manifestSubpath)
        }
        return result
    }
}
