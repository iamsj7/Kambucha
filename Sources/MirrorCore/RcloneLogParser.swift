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
    private struct Line: Decodable {
        var level: String?
        var msg: String?
        var object: String?
        var size: Int64?
        var stats: Stats?
        struct Stats: Decodable { var bytes: Int64? }
    }

    public static func parse(_ data: Data) -> LogSummary {
        var s = LogSummary()
        var sizeSum: Int64 = 0
        var statsBytes: Int64?
        let decoder = JSONDecoder()
        for raw in data.split(separator: UInt8(ascii: "\n")) {
            guard let line = try? decoder.decode(Line.self, from: Data(raw)), let msg = line.msg else { continue }
            let object = line.object ?? ""
            if let b = line.stats?.bytes { statsBytes = b }
            if line.level == "error" || line.level == "critical" { s.errors.append(object.isEmpty ? msg : "\(object): \(msg)") }
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

    /// Exit code refined by the raw log: `--max-delete` stops and expired sign-ins are only visible there.
    public static func outcome(exitCode: Int32, log: Data) -> RcloneResult.Outcome {
        guard exitCode != 0 else { return .success }
        let text = String(decoding: log, as: UTF8.self).lowercased()
        if text.contains("--max-delete threshold reached") { return .safetyStop }
        if text.contains("invalid_grant") || text.contains("token expired") { return .authExpired }
        return outcome(exitCode: exitCode)
    }
}
