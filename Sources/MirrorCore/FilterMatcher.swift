import Foundation

/// Answers "does this filter exclude that path?" for `ScopeMapper`, with rclone's first-match-wins
/// reading of `FilterBuilder` lines. Only ever saves work: a path wrongly called included costs a
/// sync with nothing to do, so a pattern it can't read makes it exclude nothing at all.
public struct FilterMatcher: Sendable {
    private struct Rule: Sendable { var include: Bool; var regex: NSRegularExpression }
    private var rules: [Rule] = []

    public init(lines: [String]) {
        for line in lines {
            guard line.hasPrefix("+ ") || line.hasPrefix("- "), let regex = Self.regex(String(line.dropFirst(2))) else {
                rules = []
                return
            }
            rules.append(Rule(include: line.hasPrefix("+"), regex: regex))
        }
    }

    /// `path` is relative to the set. `folder/**` rules cover everything beneath the folder.
    public func isExcluded(_ path: String) -> Bool {
        let range = NSRange(path.startIndex..., in: path)
        for rule in rules where rule.regex.firstMatch(in: path, range: range) != nil { return !rule.include }
        return false
    }

    private static func regex(_ glob: String) -> NSRegularExpression? {
        var pattern = glob
        if pattern.hasSuffix("/") { pattern += "**" }
        let anchored = pattern.hasPrefix("/")
        if anchored { pattern.removeFirst() }
        guard !pattern.contains("{{"), let body = translate(pattern) else { return nil }
        return try? NSRegularExpression(pattern: (anchored ? "^" : "(?:^|/)") + body + "$")
    }

    private static func translate(_ glob: String) -> String? {
        var out = ""
        let chars = Array(glob)
        var i = 0, braces = 0
        while i < chars.count {
            let c = chars[i]
            switch c {
            case "\\":
                i += 1
                guard i < chars.count else { return nil }
                out += NSRegularExpression.escapedPattern(for: String(chars[i]))
            case "*":
                if i + 1 < chars.count, chars[i + 1] == "*" { out += ".*"; i += 1 } else { out += "[^/]*" }
            case "?":
                out += "[^/]"
            case "[":
                guard let end = chars[i...].firstIndex(of: "]") else { return nil }
                out += String(chars[i...end])
                i = end
            case "{":
                braces += 1; out += "(?:"
            case "}":
                guard braces > 0 else { return nil }
                braces -= 1; out += ")"
            case "," where braces > 0:
                out += "|"
            default:
                out += NSRegularExpression.escapedPattern(for: String(c))
            }
            i += 1
        }
        return braces == 0 ? out : nil
    }
}
