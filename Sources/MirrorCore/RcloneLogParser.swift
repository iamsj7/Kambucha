import Foundation

public struct LogSummary: Equatable, Sendable {
    public var copied: [String] = []
    public var deleted: [String] = []
    public var archived: [String] = []
    /// "old -> new"
    public var renamed: [String] = []
    public var errors: [String] = []
    public var differences = 0
    /// Files a check found identical. Absent from rclone's log when there are none.
    public var matching = 0
    /// What a dry run would copy.
    public var planned: [String] = []
    /// Paths named by error lines. For a check, the files that differ.
    public var flagged: [String] = []
    public var bytes: Int64 = 0
    public init() {}
}

public struct RcloneResult: Equatable, Sendable {
    /// `safetyStop` = the run was stopped by `--max-delete`. Observed exit code 7 (fatal error) with
    /// "--max-delete threshold reached" in the log; the code alone is not unique, so the log decides.
    public enum Outcome: Equatable, Sendable { case success, partial, transient, authExpired, permanent, safetyStop }
    public var exitCode: Int32
    public var summary: LogSummary
    public var outcome: Outcome
    public init(exitCode: Int32, summary: LogSummary, outcome: Outcome) {
        self.exitCode = exitCode; self.summary = summary; self.outcome = outcome
    }
}

/// One live stats record from rclone's JSON log (`--stats 2s --stats-log-level NOTICE`).
public struct RcloneStats: Equatable, Sendable {
    public var bytes: Int64
    /// Nil when rclone has not counted a total yet (it reports 0 while listing).
    public var bytesTotal: Int64?
    public var filesDone: Int
    public var filesTotal: Int?
    /// Nil until rclone has a speed (it reports 0 at the start).
    public var speed: Double?
    public var eta: TimeInterval?
    public init(bytes: Int64, bytesTotal: Int64?, filesDone: Int, filesTotal: Int?, speed: Double?, eta: TimeInterval?) {
        self.bytes = bytes; self.bytesTotal = bytesTotal; self.filesDone = filesDone
        self.filesTotal = filesTotal; self.speed = speed; self.eta = eta
    }
}

public enum RcloneLogParser {
    /// A stats record from one log line, or nil when the line is not one.
    public static func stats(line: Data) -> RcloneStats? {
        guard let d = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let s = d["stats"] as? [String: Any], let bytes = (s["bytes"] as? NSNumber)?.int64Value else { return nil }
        func positive(_ k: String) -> Int64? { (s[k] as? NSNumber).map(\.int64Value).flatMap { $0 > 0 ? $0 : nil } }
        let speed = (s["speed"] as? NSNumber)?.doubleValue
        let eta = (s["eta"] as? NSNumber)?.doubleValue
        return RcloneStats(bytes: bytes, bytesTotal: positive("totalBytes"),
                           filesDone: Int((s["transfers"] as? NSNumber)?.int64Value ?? 0),
                           filesTotal: positive("totalTransfers").map(Int.init),
                           speed: speed.flatMap { $0 > 0 ? $0 : nil }, eta: eta.flatMap { $0 >= 0 ? $0 : nil })
    }

    /// The newest stats record in a log.
    public static func lastStats(_ data: Data) -> RcloneStats? {
        data.split(separator: UInt8(ascii: "\n")).reversed().lazy.compactMap { stats(line: Data($0)) }.first
    }

    /// One log line, decoded leniently: a field of an unexpected type is ignored, never the whole line.
    private struct Line {
        var level: String?
        var msg: String?
        var object: String?
        var size: Int64?
        var statsBytes: Int64?
        init?(_ raw: Data) {
            guard let d = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] else { return nil }
            level = d["level"] as? String
            msg = d["msg"] as? String
            object = d["object"] as? String
            size = (d["size"] as? NSNumber)?.int64Value
            statsBytes = ((d["stats"] as? [String: Any])?["bytes"] as? NSNumber)?.int64Value
        }
        var isError: Bool { level == "error" || level == "critical" }
    }

    private static func lines(_ data: Data) -> [Line] {
        data.split(separator: UInt8(ascii: "\n")).compactMap { Line(Data($0)) }
    }

    public static func parse(_ data: Data) -> LogSummary {
        var s = LogSummary()
        var sizeSum: Int64 = 0
        var statsBytes: Int64?
        for line in lines(data) {
            if let b = line.statsBytes { statsBytes = b }
            guard let msg = line.msg else { continue }
            let object = line.object ?? ""
            if line.isError {
                s.errors.append(object.isEmpty ? msg : "\(object): \(msg)")
                if !object.isEmpty { s.flagged.append(object) }
            }
            if let n = differenceCount(msg) { s.differences = n }
            if let n = matchingCount(msg) { s.matching = n }
            guard !object.isEmpty else { continue }
            if msg.hasPrefix("Skipped copy") {
                s.planned.append(object)   // --dry-run
            } else if msg.hasPrefix("Copied") {
                s.copied.append(object); sizeSum += line.size ?? 0
            } else if msg == "Moved into backup dir" {
                s.deleted.append(object); appendUnique(&s.archived, object)
            } else if msg == "Moved (server-side)" {
                // With --backup-dir this is the move of an overwritten or deleted file into the archive.
                appendUnique(&s.archived, object)
            } else if msg == "Deleted" || msg.hasPrefix("Skipped delete") || msg.hasPrefix("Skipped move into backup dir") {
                appendUnique(&s.deleted, object)   // the latter two are --dry-run
            } else if msg.hasPrefix("Renamed from \"") {
                let old = msg.dropFirst("Renamed from \"".count).dropLast()
                s.renamed.append("\(old) -> \(object)")
            }
        }
        s.bytes = statsBytes ?? sizeSum
        return s
    }

    private static func appendUnique(_ list: inout [String], _ item: String) {
        if !list.contains(item) { list.append(item) }
    }

    private static func differenceCount(_ msg: String) -> Int? {
        guard msg.hasSuffix(" differences found"), let n = Int(msg.dropLast(" differences found".count)) else { return nil }
        return n
    }

    private static func matchingCount(_ msg: String) -> Int? {
        msg.hasSuffix(" matching files") ? Int(msg.dropLast(" matching files".count)) : nil
    }

    /// Exit-code classification only. 10 is rclone's "transfer limit reached", which `--max-duration` triggers.
    public static func outcome(exitCode: Int32) -> RcloneResult.Outcome {
        switch exitCode {
        case 0: .success
        case 5, 6: .transient
        case 10: .partial
        default: .permanent
        }
    }

    /// Known rclone and oauth2 wordings of an expired or revoked sign-in. Verified present in the vendored
    /// rclone binary's strings; still to be confirmed against real Google and OneDrive errors.
    private static let authShapes = [
        "couldn't fetch token",                           // rclone oauthutil
        "token expired and there's no refresh token",     // rclone oauthutil
        "no refresh token found",                         // rclone oauthutil
        "oauth2: token expired and refresh token is not set",  // golang.org/x/oauth2
    ]

    /// Google's daily upload limit, which `--drive-stop-on-upload-limit` makes fatal. Not a failure:
    /// it lifts within a day, so it ends a run the way `--max-duration` does, and the next one resumes.
    private static func isUploadLimit(_ msg: String, removing object: String?) -> Bool {
        var text = msg
        if let object, !object.isEmpty { text = text.replacingOccurrences(of: object, with: "") }
        return text.contains("userRateLimitExceeded") || text.contains("User rate limit exceeded")
    }

    /// Rclone's own wrap-up, which repeats failures rather than adding one.
    private static func isRunSummary(_ line: Line) -> Bool {
        guard line.object?.isEmpty ?? true, let msg = line.msg else { return false }
        return ["Attempt ", "Fatal error received", "Can't retry", "Not deleting", "Failed to sync"].contains(where: msg.hasPrefix)
    }

    private static func isAuthError(_ msg: String, removing object: String?) -> Bool {
        var text = msg
        if let object, !object.isEmpty { text = text.replacingOccurrences(of: object, with: "") }
        if authShapes.contains(where: text.contains) { return true }
        // `oauth2: cannot fetch token: 400 Bad Request\nResponse: {"error":"invalid_grant",...}`: the token
        // endpoint's error code is only meaningful after the oauth2 prefix, never as a free substring.
        if let r = text.range(of: "oauth2: ") { return text[r.upperBound...].contains("invalid_grant") }
        return false
    }

    /// Exit code refined by the log: `--max-delete` stops and expired sign-ins are only visible there.
    /// Only error-level lines count. For auth, the line's `object` is first removed from `msg` and then
    /// only known rclone/oauth2 message shapes match (not free substrings), because real messages embed
    /// paths ("open /x/token expired.txt: permission denied"). Stderr text is deliberately not consulted:
    /// it can carry user paths, and with `--log-file` rclone logs everything of interest to the file.
    public static func outcome(exitCode: Int32, log: Data) -> RcloneResult.Outcome {
        guard exitCode != 0 else { return .success }
        let errorLines = lines(log).filter(\.isError)
        if errorLines.contains(where: { $0.msg == "Got fatal error on delete: --max-delete threshold reached" }) { return .safetyStop }
        if errorLines.contains(where: { line in line.msg.map { isAuthError($0, removing: line.object) } ?? false }) { return .authExpired }
        // Only when the limit is all that went wrong: a real failure beside it must still count.
        func limited(_ line: Line) -> Bool { line.msg.map { isUploadLimit($0, removing: line.object) } ?? false }
        if errorLines.contains(where: limited), errorLines.allSatisfy({ limited($0) || isRunSummary($0) }) { return .partial }
        return outcome(exitCode: exitCode)
    }

    private static let scrubbers: [(NSRegularExpression, String)] = [
        (#"(https?://[^\s"'?]+)\?[^\s"']*"#, "$1"),
        (#"(?i)\b(bearer|basic)\s+[^\s"']+"#, "$1 [redacted]"),
        (#"(?i)"?\b(access_token|refresh_token|id_token|token|client_secret|client_id|password|passphrase|secret|api[_-]?key|key|code)"?\s*[:=]\s*("[^"]*"|[^\s,&}"']+)"#, "$1=[redacted]"),
        (#"[A-Za-z0-9_+=-]{40,}"#, "[redacted]"),
    ].compactMap { pattern, template in (try? NSRegularExpression(pattern: pattern)).map { ($0, template) } }

    /// For anything kept from rclone's output. Its errors can quote URLs and token responses, and
    /// run records are read by the UI and last 30 days. Paths stay, as they say what failed.
    public static func scrub(_ text: String) -> String {
        var out = text
        for (regex, template) in scrubbers {
            out = regex.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: template)
        }
        return String(out.prefix(500))
    }
}
