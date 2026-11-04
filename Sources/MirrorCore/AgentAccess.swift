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
        guard let r = readReport(support: support), r.passed, now.timeIntervalSince(r.checkedAt) <= maxAge else { return false }
        if let notBefore, r.checkedAt < notBefore { return false }
        return true
    }
}

/// Path-aware matching of rclone filter lines (`+ pattern` / `- pattern`, first match wins, no match
/// means included), for paths relative to the set root.
public struct FilterMatcher: Sendable {
    private let rules: [(include: Bool, regex: NSRegularExpression)]

    public init(lines: [String]) {
        rules = lines.compactMap { line in
            guard line.count > 2, let sign = line.first, sign == "+" || sign == "-", line.dropFirst().first == " " else { return nil }
            guard let re = Self.regex(String(line.dropFirst(2))) else { return nil }
            return (sign == "+", re)
        }
    }

    public func isExcluded(_ path: String) -> Bool {
        let range = NSRange(path.startIndex..., in: path)
        for r in rules where r.regex.firstMatch(in: path, range: range) != nil { return !r.include }
        return false
    }

    /// rclone glob: `*` and `?` stay inside one path component, `**` crosses them, `{a,b}` alternates,
    /// `[..]` is a class, `\x` is literal. A leading `/` anchors to the root; otherwise any depth.
    /// Case-insensitive, which can only skip more files than rclone does.
    static func regex(_ glob: String) -> NSRegularExpression? {
        var p = Array(glob)
        var out = ""
        if p.first == "/" { out = "^"; p.removeFirst() } else { out = "^(?:.*/)?" }
        var i = 0, depth = 0
        while i < p.count {
            let c = p[i]
            switch c {
            case "*":
                if i + 1 < p.count, p[i + 1] == "*" {
                    i += 1
                    if i + 1 < p.count, p[i + 1] == "/" { out += "(?:.*/)?"; i += 1 } else { out += ".*" }
                } else { out += "[^/]*" }
            case "?": out += "[^/]"
            case "{": out += "(?:"; depth += 1
            case "}": if depth > 0 { out += ")"; depth -= 1 } else { out += "\\}" }
            case ",": out += depth > 0 ? "|" : ","
            case "[":
                if let close = p[i...].firstIndex(of: "]") { out += String(p[i...close]); i = close } else { out += "\\[" }
            case "\\":
                i += 1
                if i < p.count { out += NSRegularExpression.escapedPattern(for: String(p[i])) }
            default: out += NSRegularExpression.escapedPattern(for: String(c))
            }
            i += 1
        }
        guard depth == 0 else { return nil }
        return try? NSRegularExpression(pattern: out + "$", options: [.caseInsensitive])
    }
}
