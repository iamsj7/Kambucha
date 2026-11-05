import Foundation

public struct DetectedProject: Codable, Equatable, Sendable {
    /// Folder relative to the scanned root; "." for the root itself.
    public var relativePath: String
    public var presetIDs: Set<String>
    public init(relativePath: String, presetIDs: Set<String>) {
        self.relativePath = relativePath; self.presetIDs = presetIDs
    }
}

/// Finds project folders by marker files. Reads only folder listings, never .gitignore.
public struct StackDetector: Sendable {
    private let presets: [Preset]
    /// Folder paths (as component lists) the scan never descends into.
    private let skipPaths: [[String]]

    public init(presets: [Preset]) {
        self.presets = presets
        var skip: [[String]] = [[".git"]]
        for p in presets {
            for e in p.alwaysExclude where e.hasSuffix("/") {
                skip.append(e.dropLast().split(separator: "/").map(String.init))
            }
        }
        self.skipPaths = skip
    }

    public func detect(in root: URL, maxDepth: Int = 4) -> [DetectedProject] {
        var result: [DetectedProject] = []
        walk(root, components: [], depth: 0, maxDepth: maxDepth, into: &result)
        return result
    }

    private func isSkipped(_ components: [String]) -> Bool {
        skipPaths.contains { skip in
            components.count >= skip.count
                && zip(components.suffix(skip.count), skip).allSatisfy { Self.match($1, $0) }
        }
    }

    private func walk(_ dir: URL, components: [String], depth: Int, maxDepth: Int,
                      into result: inout [DetectedProject]) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: []) else { return }
        let names = entries.map(\.lastPathComponent)
        var ids = Set<String>()
        for p in presets where p.markers.contains(where: { m in names.contains { Self.match(m, $0) } }) {
            ids.insert(p.id)
        }
        if !ids.isEmpty {
            result.append(DetectedProject(relativePath: components.isEmpty ? "." : components.joined(separator: "/"),
                                          presetIDs: ids))
        }
        guard depth < maxDepth else { return }
        for e in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let v = try? e.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard v?.isDirectory == true, v?.isSymbolicLink != true else { continue }
            let next = components + [e.lastPathComponent]
            if isSkipped(next) { continue }
            walk(e, components: next, depth: depth + 1, maxDepth: maxDepth, into: &result)
        }
    }

    /// Glob match of a single path component (supports * and ?).
    static func match(_ pattern: String, _ name: String) -> Bool {
        fnmatch(pattern, name, 0) == 0
    }
}
