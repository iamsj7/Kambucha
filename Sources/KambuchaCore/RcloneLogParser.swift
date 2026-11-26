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
    /// What a dry run would copy, in bytes.
    public var plannedBytes: Int64 = 0
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

    /// Calls `body` with each non-empty line of `data`.
    public static func forEachLine(in data: Data, _ body: (Data) -> Void) {
        var start = data.startIndex
        while start < data.endIndex {
            let end = data[start...].firstIndex(of: newline) ?? data.endIndex
            if end > start { body(data[start..<end]) }
            start = end == data.endIndex ? end : data.index(after: end)
        }
    }

    /// Calls `body` with each non-empty line of the file, reading `chunkSize` bytes at a time, so a log of
    /// any size costs one chunk of memory. A missing or unreadable file has no lines.
    public static func forEachLine(inFileAt url: URL, chunkSize: Int = 1 << 20, _ body: (Data) -> Void) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        var carry = Data()
        while let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty {
            carry.append(chunk)
            guard let last = carry.lastIndex(of: newline) else { continue }
            // One pool per chunk: JSONSerialization's objects would otherwise pile up until the run ends.
            autoreleasepool { forEachLine(in: carry[..<last], body) }
            carry = Data(carry[carry.index(after: last)...])
        }
        if !carry.isEmpty { autoreleasepool { body(carry) } }
    }

    private static let newline = UInt8(ascii: "\n")

    /// Reads a log one line at a time, building its summary and what decides its outcome in one pass.
    /// Nothing but the summary outlives a line.
    public struct Reader {
        public private(set) var summary = LogSummary()
        private var sizeSum: Int64 = 0
        private var statsBytes: Int64?
        private var archived = Set<String>(), deleted = Set<String>()
        // What `outcome(exitCode:)` needs from the error lines.
        private var maxDeleteStop = false, authFailed = false, uploadLimited = false, onlyLimits = true

        public init() {}

        /// `summarise: false` lets a line count towards the outcome only, as rclone's stderr does.
        public mutating func read(line raw: Data, summarise: Bool = true) {
            guard let line = Line(raw) else { return }
            if line.isError { note(error: line) }
            if summarise { add(line) }
        }

        public mutating func read(fileAt url: URL) {
            RcloneLogParser.forEachLine(inFileAt: url) { read(line: $0) }
        }

        /// The exit code, refined by the log: `--max-delete` stops and expired sign-ins are only visible there.
        public func outcome(exitCode: Int32) -> RcloneResult.Outcome {
            guard exitCode != 0 else { return .success }
            if maxDeleteStop { return .safetyStop }
            if authFailed { return .authExpired }
            // Only when the limit is all that went wrong: a real failure beside it must still count.
            if uploadLimited, onlyLimits { return .partial }
            return RcloneLogParser.outcome(exitCode: exitCode)
        }

        private mutating func note(error line: Line) {
            if line.msg == "Got fatal error on delete: --max-delete threshold reached" { maxDeleteStop = true }
            if line.msg.map({ RcloneLogParser.isAuthError($0, removing: line.object) }) ?? false { authFailed = true }
            let limited = line.msg.map { RcloneLogParser.isUploadLimit($0, removing: line.object) } ?? false
            if limited { uploadLimited = true } else if !RcloneLogParser.isRunSummary(line) { onlyLimits = false }
        }

        private mutating func add(_ line: Line) {
            if let b = line.statsBytes { statsBytes = b; summary.bytes = b }
            guard let msg = line.msg else { return }
            let object = line.object ?? ""
            if line.isError {
                summary.errors.append(object.isEmpty ? msg : "\(object): \(msg)")
                if !object.isEmpty { summary.flagged.append(object) }
            }
            if let n = RcloneLogParser.differenceCount(msg) { summary.differences = n }
            if let n = RcloneLogParser.matchingCount(msg) { summary.matching = n }
            guard !object.isEmpty else { return }
            if msg.hasPrefix("Skipped copy") {
                summary.planned.append(object)   // --dry-run
                summary.plannedBytes += line.size ?? 0
            } else if msg.hasPrefix("Copied") {
                summary.copied.append(object); sizeSum += line.size ?? 0
                if statsBytes == nil { summary.bytes = sizeSum }
            } else if msg == "Moved into backup dir" {
                summary.deleted.append(object); deleted.insert(object)
                if archived.insert(object).inserted { summary.archived.append(object) }
            } else if msg == "Moved (server-side)" {
                // With --backup-dir this is the move of an overwritten or deleted file into the archive.
                if archived.insert(object).inserted { summary.archived.append(object) }
            } else if msg == "Deleted" || msg.hasPrefix("Skipped delete") || msg.hasPrefix("Skipped move into backup dir") {
                if deleted.insert(object).inserted { summary.deleted.append(object) }   // the latter two are --dry-run
            } else if msg.hasPrefix("Renamed from \"") {
                let old = msg.dropFirst("Renamed from \"".count).dropLast()
                summary.renamed.append("\(old) -> \(object)")
            }
        }
    }

    public static func parse(_ data: Data) -> LogSummary {
        var reader = Reader()
        forEachLine(in: data) { reader.read(line: $0) }
        return reader.summary
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
        var reader = Reader()
        forEachLine(in: log) { reader.read(line: $0, summarise: false) }
        return reader.outcome(exitCode: exitCode)
    }

    /// The same, read from a log file a chunk at a time.
    public static func outcome(exitCode: Int32, logFile: URL) -> RcloneResult.Outcome {
        guard exitCode != 0 else { return .success }
        var reader = Reader()
        forEachLine(inFileAt: logFile) { reader.read(line: $0, summarise: false) }
        return reader.outcome(exitCode: exitCode)
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
