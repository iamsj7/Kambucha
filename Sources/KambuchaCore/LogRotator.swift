import Foundation

public struct LogRotator {
    /// Prunes each per-run folder directly inside `dir`, then removes those left empty.
    public static func pruneRunFolders(_ dir: URL, olderThan date: Date) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path) else { return }
        for url in try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey]) {
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            try pruneRunFolders(url, olderThan: date)
            try prune(url, olderThan: date)
            if try fm.contentsOfDirectory(atPath: url.path).isEmpty { try fm.removeItem(at: url) }
        }
    }

    /// Deletes regular files in `dir` last modified before `date`. A missing directory is not an error.
    public static func prune(_ dir: URL, olderThan date: Date) throws {
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        var firstError: Error?
        for url in try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys) {
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if v.isRegularFile == true, let m = v.contentModificationDate, m < date {
                do { try FileManager.default.removeItem(at: url) } catch { firstError = firstError ?? error }
            }
        }
        if let firstError { throw firstError }
    }
}
