import Foundation

/// Builds rclone filter-file lines. First match wins in rclone, so order is the policy: secret and git excludes
/// when those switches are off, user rules, macOS junk, always-excludes, then per-project ambiguous excludes.
/// The switches go first so an Include on a folder can't bring back what the owner switched off. A user exclude
/// loses nothing by following them, as both exclude.
/// There is deliberately no trailing catch-all: anything not excluded is backed up.
public struct FilterBuilder: Sendable {
    private let presets: [Preset]
    public init(presets: [Preset]) { self.presets = presets }

    /// `scope` is a set-relative folder for a scoped sync, or nil for the whole set.
    public func lines(for set: BackupSet, projects: [DetectedProject], scope: String?) -> [String] {
        let scope = Self.normalise(scope)
        var out: [String] = []
        var seen = Set<String>()
        func add(_ line: String) { if seen.insert(line).inserted { out.append(line) } }

        if !set.backupSecrets {
            for p in PresetCatalog.secretPatterns { add("- \(p)") }
        }
        if !set.backupGit { add("- .git/**") }
        for rule in set.rules {
            guard let pattern = rebaseRule(rule.pattern, scope: scope) else { continue }
            out.append("\(rule.action == .include ? "+" : "-") \(pattern)")
        }
        for p in PresetCatalog.macOSExcludes { add("- \(Self.glob(p))") }

        let enabled = presets.filter { set.presets.contains($0.id) }
        for preset in enabled {
            for p in preset.alwaysExclude { add("- \(Self.glob(p))") }
        }
        for project in projects {
            guard let base = rebase(project.relativePath, scope: scope) else { continue }
            let prefix = base.isEmpty ? "" : "/" + base.split(separator: "/").map { Self.escape(String($0)) }.joined(separator: "/")
            for preset in enabled where project.presetIDs.contains(preset.id) {
                for p in preset.ambiguousExclude { add("- \(prefix)/\(Self.glob(p))") }
            }
        }
        return out
    }

    public func write(_ lines: [String], to url: URL) throws {
        let text = lines.map { $0 + "\n" }.joined()
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    /// Escapes rclone glob metacharacters in a literal path: \ [ ] { } * ?
    public static func escape(_ path: String) -> String {
        var out = ""
        for ch in path {
            if "\\[]{}*?".contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    /// A trailing "/" (folder) becomes "/**" so rclone prunes the whole subtree.
    private static func glob(_ p: String) -> String { p.hasSuffix("/") ? p + "**" : p }

    private static func normalise(_ scope: String?) -> String? {
        guard let s = scope else { return nil }
        let t = s.split(separator: "/").joined(separator: "/")
        return (t.isEmpty || t == ".") ? nil : t
    }

    /// Project path relative to the scope; nil when outside it. "" means the scope root itself.
    private func rebase(_ path: String, scope: String?) -> String? {
        let p = path == "." ? "" : path
        guard let scope else { return p }
        if p == scope { return "" }
        if p.hasPrefix(scope + "/") { return String(p.dropFirst(scope.count + 1)) }
        return nil
    }

    /// Unanchored user patterns apply everywhere; anchored ones are rebased or dropped when outside the scope.
    private func rebaseRule(_ pattern: String, scope: String?) -> String? {
        guard let scope, pattern.hasPrefix("/") else { return pattern }
        let esc = Self.escape(scope)
        if pattern == "/" + esc { return "/" }
        if pattern.hasPrefix("/" + esc + "/") { return String(pattern.dropFirst(esc.count + 1)) }
        if pattern.hasPrefix("/" + scope + "/") { return String(pattern.dropFirst(scope.count + 1)) }
        return nil
    }
}
