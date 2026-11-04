import Foundation

/// What the agent found when it last tried to read the folders it backs up, written to `access.json`.
public struct AccessReport: Codable, Equatable, Sendable {
    public var passed: Bool
    public var checkedAt: Date
}

/// Full Disk Access belongs to the process that reads. A child launched from the app can inherit the
/// app's grant, so only a report written by the launchd-started agent proves the agent's own access.
public enum AgentAccess {
    public static let fileName = "access.json"

    /// True when every folder can be listed. An empty list is not a pass.
    public static func check(paths: [URL]) -> Bool {
        guard !paths.isEmpty else { return false }
        return paths.allSatisfy { (try? FileManager.default.contentsOfDirectory(atPath: $0.path)) != nil }
    }

    /// iCloud Drive and Documents, the two places the first backup reads.
    public static func defaultPaths(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        [MirrorPaths.iCloudDrive(home: home), home.appendingPathComponent("Documents", isDirectory: true)]
    }

    /// The agent calls this at the start of every launchd run. Read-only apart from this one file.
    @discardableResult
    public static func writeReport(support: URL, paths: [URL] = defaultPaths(), now: Date = Date()) -> Bool {
        let report = AccessReport(passed: check(paths: paths), checkedAt: now)
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try? e.encode(report).write(to: support.appendingPathComponent(fileName), options: .atomic)
        return report.passed
    }

    public static func readReport(support: URL) -> AccessReport? {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        return (try? Data(contentsOf: support.appendingPathComponent(fileName))).flatMap { try? d.decode(AccessReport.self, from: $0) }
    }

    /// Confirmed only by a passing report no older than `maxAge` (and not older than `notBefore`, when given).
    public static func isConfirmed(support: URL, now: Date = Date(), maxAge: TimeInterval = 2 * 3600, notBefore: Date? = nil) -> Bool {
        guard let r = readReport(support: support), r.passed, r.checkedAt <= now,   // a clock set ahead can't pre-confirm
              now.timeIntervalSince(r.checkedAt) <= maxAge else { return false }
        if let notBefore, r.checkedAt < notBefore { return false }
        return true
    }
}
