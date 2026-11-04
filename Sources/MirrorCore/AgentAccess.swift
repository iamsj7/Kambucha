import Foundation

/// The agent's read-only Full Disk Access check. TCC grants belong to the process that reads, and the
/// agent is the one that backs up, so the agent answers for itself. No Keychain, no writes.
public enum AgentAccess {
    /// True when every folder can be listed. An empty list is not a pass.
    public static func check(paths: [URL]) -> Bool {
        guard !paths.isEmpty else { return false }
        return paths.allSatisfy { (try? FileManager.default.contentsOfDirectory(atPath: $0.path)) != nil }
    }

    /// iCloud Drive and Documents, the two places the first backup reads.
    public static func defaultPaths(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        [MirrorPaths.iCloudDrive(home: home), home.appendingPathComponent("Documents", isDirectory: true)]
    }
}
