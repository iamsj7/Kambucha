import Foundation

/// What the agent found when it last tried to read the folders it backs up, written to `access.json`.
public struct AccessReport: Codable, Equatable, Sendable {
    /// Documents and iCloud Drive could be listed. macOS can allow that on its own, so it proves little.
    public var folders: Bool
    /// The file only Full Disk Access can read was read.
    public var fullDiskAccess: Bool
    public var checkedAt: Date
    public init(folders: Bool, fullDiskAccess: Bool, checkedAt: Date) {
        self.folders = folders; self.fullDiskAccess = fullDiskAccess; self.checkedAt = checkedAt
    }
    public var passed: Bool { folders && fullDiskAccess }
}

/// Full Disk Access belongs to the process that reads. A child launched from the app can inherit the
/// app's grant, so only a report written by the launchd-started agent proves the agent's own access.
public enum AgentAccess {
    public static let fileName = "access.json"
    public static let defaultMaxAge: TimeInterval = 2 * 3600
    /// Readable only with Full Disk Access, whatever else has been allowed.
    public static let fullDiskAccessProbe = URL(fileURLWithPath: "/Library/Application Support/com.apple.TCC/TCC.db")

    /// Launchd starts the agent with no arguments. A child of the app can inherit the app's grant, so what it
    /// finds says nothing about the agent's own, and must not overwrite what a launchd start found.
    public static func reportsAccess(arguments: [String]) -> Bool { RunCommand.parse(arguments)?.isScheduled == true }

    /// A real read: `access(2)` goes by the file's mode, which lets everyone in, and the refusal comes at `open`.
    public static func canRead(_ file: URL) -> Bool {
        let fd = open(file.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var byte: UInt8 = 0
        return read(fd, &byte, 1) == 1
    }

    /// True when every folder can be listed. An empty list is not a pass.
    public static func check(paths: [URL]) -> Bool {
        guard !paths.isEmpty else { return false }
        return paths.allSatisfy { (try? FileManager.default.contentsOfDirectory(atPath: $0.path)) != nil }
    }

    /// iCloud Drive and Documents, the two places the first backup reads. Passing doesn't prove Full Disk Access.
    public static func defaultPaths(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        [MirrorPaths.iCloudDrive(home: home), home.appendingPathComponent("Documents", isDirectory: true)]
    }

    /// The agent calls this at the start of every launchd run. Read-only apart from this one file.
    @discardableResult
    public static func writeReport(support: URL, paths: [URL] = defaultPaths(), fullDiskProbe: URL = fullDiskAccessProbe,
                                   now: Date = Date()) -> Bool {
        let report = AccessReport(folders: check(paths: paths), fullDiskAccess: canRead(fullDiskProbe), checkedAt: now)
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try? e.encode(report).write(to: support.appendingPathComponent(fileName), options: .atomic)
        return report.passed
    }

    public static func readReport(support: URL) -> AccessReport? {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        return (try? Data(contentsOf: support.appendingPathComponent(fileName))).flatMap { try? d.decode(AccessReport.self, from: $0) }
    }

    public enum Status: Equatable, Sendable { case confirmed, stale, failing, unknown }

    /// What the last report says now. Launchd won't start a job that's still running, so while the agent runs an
    /// old report isn't stale: a long first upload is no sign of lost access.
    public static func status(support: URL, now: Date = Date(), maxAge: TimeInterval = defaultMaxAge, agentRunning: Bool) -> Status {
        guard let r = readReport(support: support), r.checkedAt <= now else { return .unknown }
        guard r.passed else { return .failing }
        return agentRunning || now.timeIntervalSince(r.checkedAt) <= maxAge ? .confirmed : .stale
    }

    /// Confirmed only by a passing report no older than `maxAge` (and not older than `notBefore`, when given).
    public static func isConfirmed(support: URL, now: Date = Date(), maxAge: TimeInterval = defaultMaxAge, notBefore: Date? = nil) -> Bool {
        guard let r = readReport(support: support), r.passed, r.checkedAt <= now,   // a clock set ahead can't pre-confirm
              now.timeIntervalSince(r.checkedAt) <= maxAge else { return false }
        if let notBefore, r.checkedAt < notBefore { return false }
        return true
    }
}
