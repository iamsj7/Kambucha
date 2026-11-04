import Foundation

public struct LogRotator {
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
