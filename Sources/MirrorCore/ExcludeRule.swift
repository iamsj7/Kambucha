import Foundation

/// Turns files and folders the owner picked into exclude rules, so nobody has to know rclone's patterns.
public enum ExcludeRule {
    /// The anchored pattern for one item in `source`, or nil if it isn't strictly inside. A folder needs `/**`, as a
    /// bare name matches no folder. With `--links` rclone names a link `<name>.rclonelink`, and a link to a folder is
    /// a link: its target stays. Deliberately not `URL.hasDirectoryPath`, which is only how the URL was spelled.
    public static func pattern(for item: URL, in source: URL) -> String? {
        guard let relative = ScopeMapper.relative([item.standardizedFileURL.path], to: source).first, !relative.isEmpty else { return nil }
        let exact = "/" + FilterBuilder.escape(relative)
        var st = stat()
        guard lstat(item.path, &st) == 0 else { return exact }
        switch st.st_mode & S_IFMT {
        case S_IFDIR: return exact + "/**"
        case S_IFLNK: return exact + ".rclonelink"
        default: return exact
        }
    }

    /// The set's rules with `items` excluded, and how many items weren't inside the set. New rules go first, because
    /// the first match wins and a wider Include must not bring a picked item back. A rule already on the same
    /// pattern gives way, so one item never has two.
    public static func adding(_ items: [URL], to set: BackupSet) -> (rules: [UserRule], outside: Int) {
        var picked: [String] = [], outside = 0
        for item in items {
            guard let pattern = pattern(for: item, in: set.source) else { outside += 1; continue }
            if !picked.contains(pattern) { picked.append(pattern) }
        }
        let rest = set.rules.filter { !picked.contains($0.pattern) }
        return (picked.map { UserRule(pattern: $0, action: .exclude) } + rest, outside)
    }
}
