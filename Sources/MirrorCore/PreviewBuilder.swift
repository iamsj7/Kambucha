import Foundation

public enum PreviewError: Error, Equatable, Sendable { case rcloneFailed(String) }

/// Shows what a set will back up, what it skips and what needs a decision. This is the one place excluded
/// folders are measured; later runs never walk them.
public struct PreviewBuilder: PreviewProviding {
    private let rclone: any RcloneRunning
    private let context: RcloneContext
    private let presets: [Preset]

    public init(rclone: any RcloneRunning, context: RcloneContext, presets: [Preset]) {
        self.rclone = rclone; self.context = context; self.presets = presets
    }

    public func preview(set: BackupSet) async throws -> PreviewResult { try await build(set: set) }

    /// Unticking a group excludes its folder; ticking includes it. Saved by the caller as a set rule.
    public func rule(for group: PreviewGroup, included: Bool) -> UserRule {
        UserRule(pattern: group.pattern, action: included ? .include : .exclude)
    }

    public func build(set: BackupSet) async throws -> PreviewResult {
        let filters = FilterBuilder(presets: presets)
        let projects = StackDetector(presets: presets).detect(in: set.source)
        let filterFile = FileManager.default.temporaryDirectory.appendingPathComponent("mirror-preview-\(UUID().uuidString).filter")
        defer { try? FileManager.default.removeItem(at: filterFile) }
        try filters.write(filters.lines(for: set, projects: projects, scope: nil), to: filterFile)

        let size = try await run(["size", "--json", "--links", "--filter-from", filterFile.path, set.source.path])
        let (count, bytes) = Self.parseSize(size.stdout)
        let listing = try await run(["lsf", "-R", "--files-only", "--links", "--filter-from", filterFile.path, set.source.path])

        var decisions: [ReviewItem] = []
        for path in listing.stdout.split(separator: "\n").map(String.init) {
            let name = (path as NSString).lastPathComponent.lowercased()
            if name.hasSuffix(".tmp") || name.hasSuffix(".nosync") {
                decisions.append(ReviewItem(id: "refused:\(path)", path: path, kind: .refusedByICloud))
            }
        }

        let source = set.source, enabled = presets.filter { set.presets.contains($0.id) }
        let measured = await Task.detached { Self.measure(source: source, presets: enabled, projects: projects) }.value
        let scanner = ReviewScanner(filters: filters)
        decisions += scanner.secretsIn(changedExcludedPaths: measured.secretPaths)
        for (repo, folders) in Self.reposByFolder(source: source, folders: measured.folders) {
            decisions += try scanner.trackedInExcluded(repo: repo, excluded: folders)
        }

        var groups: [PreviewGroup] = measured.groups.map { key, g in
            let rulePattern = key.hasSuffix("/") ? key + "**" : key
            let included = set.rules.first(where: { $0.pattern == rulePattern })?.action == .include
            return PreviewGroup(id: key, title: key, fileCount: g.files, bytes: g.bytes, included: included, pattern: rulePattern)
        }
        groups.sort { ($0.bytes, $1.id) > ($1.bytes, $0.id) }
        let skipped = groups.filter { !$0.included }.reduce(Int64(0)) { $0 + $1.bytes }
        decisions.sort { ($0.kind.rawValue, $0.path) < ($1.kind.rawValue, $1.path) }
        return PreviewResult(includedBytes: bytes, skippedBytes: skipped, includedFiles: count, groups: groups, decisions: decisions)
    }

    /// Mirrored files that the set's current rules would now exclude. Reported only; nothing is deleted or moved.
    public func newlyExcluded(set: BackupSet, mirror: String) async throws -> [String] {
        let filters = FilterBuilder(presets: presets)
        let projects = StackDetector(presets: presets).detect(in: set.source)
        let filterFile = FileManager.default.temporaryDirectory.appendingPathComponent("mirror-preview-\(UUID().uuidString).filter")
        defer { try? FileManager.default.removeItem(at: filterFile) }
        try filters.write(filters.lines(for: set, projects: projects, scope: nil), to: filterFile)
        let all = try await run(["lsf", "-R", "--files-only", "--links", mirror])
        let kept = try await run(["lsf", "-R", "--files-only", "--links", "--filter-from", filterFile.path, mirror])
        let keptSet = Set(kept.stdout.split(separator: "\n").map(String.init))
        return all.stdout.split(separator: "\n").map(String.init).filter { !keptSet.contains($0) }.sorted()
    }

    private func run(_ a: [String]) async throws -> RcloneCapture {
        let out = try await rclone.capture(a + ["--config", context.configPath], context: context)
        guard out.exitCode == 0 else { throw PreviewError.rcloneFailed(out.stderr) }
        return out
    }

    static func parseSize(_ json: String) -> (Int, Int64) {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return (0, 0) }
        return ((obj["count"] as? NSNumber)?.intValue ?? 0, (obj["bytes"] as? NSNumber)?.int64Value ?? 0)
    }

    // MARK: Measuring excluded folders

    struct Measured: Sendable {
        var groups: [String: (files: Int, bytes: Int64)] = [:]
        var folders: [String] = []        // source-relative excluded folders found
        var secretPaths: [String] = []    // source-relative
    }

    private struct Matcher {
        var pattern: String
        var comps: [String]
        var isDir: Bool
        var project: [String]?     // nil = anywhere
    }

    static func measure(source: URL, presets: [Preset], projects: [DetectedProject]) -> Measured {
        var matchers: [Matcher] = []
        func comps(_ s: String) -> [String] { s.split(separator: "/").map(String.init) }
        for preset in presets {
            for p in preset.alwaysExclude {
                matchers.append(Matcher(pattern: p, comps: comps(p), isDir: p.hasSuffix("/"), project: nil))
            }
            for project in projects where project.presetIDs.contains(preset.id) {
                let base = project.relativePath == "." ? [] : comps(project.relativePath)
                for p in preset.ambiguousExclude {
                    matchers.append(Matcher(pattern: p, comps: comps(p), isDir: p.hasSuffix("/"), project: base))
                }
            }
        }
        func matches(_ m: Matcher, _ path: [String], isDir: Bool) -> Bool {
            guard m.isDir == isDir else { return false }
            if let base = m.project {
                guard path.count == base.count + m.comps.count, Array(path.prefix(base.count)) == base else { return false }
                return zip(path.dropFirst(base.count), m.comps).allSatisfy { fnmatch($1, $0, 0) == 0 }
            }
            guard path.count >= m.comps.count else { return false }
            return zip(path.suffix(m.comps.count), m.comps).allSatisfy { fnmatch($1, $0, 0) == 0 }
        }

        var result = Measured()
        let fm = FileManager.default
        func walk(_ dir: URL, _ path: [String]) {
            guard let entries = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey], options: []) else { return }
            for e in entries {
                let v = try? e.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
                let isLink = v?.isSymbolicLink == true, isDir = v?.isDirectory == true && !isLink
                let next = path + [e.lastPathComponent]
                if isDir {
                    if let m = matchers.first(where: { matches($0, next, isDir: true) }) {
                        let (n, b, secrets) = measureFolder(e, next)
                        var g = result.groups[m.pattern] ?? (0, 0)
                        g.files += n; g.bytes += b
                        result.groups[m.pattern] = g
                        result.folders.append(next.joined(separator: "/"))
                        result.secretPaths += secrets
                    } else if e.lastPathComponent != ".git" {
                        walk(e, next)
                    }
                } else if let m = matchers.first(where: { matches($0, next, isDir: false) }) {
                    var g = result.groups[m.pattern] ?? (0, 0)
                    g.files += 1; g.bytes += Int64(v?.fileSize ?? 0)
                    result.groups[m.pattern] = g
                }
            }
        }
        func measureFolder(_ dir: URL, _ path: [String]) -> (Int, Int64, [String]) {
            var n = 0, b: Int64 = 0, secrets: [String] = []
            let base = dir.standardizedFileURL.path
            guard let w = fm.enumerator(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .isSymbolicLinkKey]) else { return (0, 0, []) }
            for case let u as URL in w {
                let v = try? u.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .isSymbolicLinkKey])
                if v?.isDirectory == true && v?.isSymbolicLink != true { continue }
                n += 1; b += Int64(v?.fileSize ?? 0)
                if ReviewScanner.isSecretName(u.lastPathComponent) {
                    let full = u.standardizedFileURL.path
                    if full.hasPrefix(base + "/") {
                        secrets.append((path + full.dropFirst(base.count + 1).split(separator: "/").map(String.init)).joined(separator: "/"))
                    }
                }
            }
            return (n, b, secrets)
        }
        walk(source, [])
        result.folders.sort(); result.secretPaths.sort()
        return result
    }

    /// Groups source-relative excluded folders by the nearest git repo above them (inside the source).
    static func reposByFolder(source: URL, folders: [String]) -> [(URL, [String])] {
        let fm = FileManager.default
        var map: [String: [String]] = [:]
        for folder in folders {
            var comps = folder.split(separator: "/").map(String.init)
            var inner: [String] = [comps.removeLast()]
            while true {
                let candidate = comps.reduce(source) { $0.appendingPathComponent($1) }
                if fm.fileExists(atPath: candidate.appendingPathComponent(".git").path) {
                    map[candidate.path, default: []].append(inner.joined(separator: "/")); break
                }
                guard let last = comps.popLast() else { break }
                inner.insert(last, at: 0)
            }
        }
        return map.keys.sorted().map { (URL(fileURLWithPath: $0, isDirectory: true), map[$0]!.sorted()) }
    }
}
