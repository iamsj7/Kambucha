import Foundation

public struct LogSummary: Equatable, Sendable {
    public var copied: [String] = []
    public var deleted: [String] = []
    public var archived: [String] = []
    /// "old -> new"
    public var renamed: [String] = []
    public var errors: [String] = []
    public var differences = 0
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

public enum RcloneLogParser {
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
            if line.isError { s.errors.append(object.isEmpty ? msg : "\(object): \(msg)") }
            if let n = differenceCount(msg) { s.differences = n }
            guard !object.isEmpty else { continue }
            if msg.hasPrefix("Copied") {
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
        return outcome(exitCode: exitCode)
    }
}
