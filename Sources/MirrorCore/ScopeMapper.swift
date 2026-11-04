import Foundation

public enum RunScope: Equatable, Sendable {
    case nothing
    case projects([String])
    case wholeSet
}

/// Maps a change batch to the smallest safe run scope. Any doubt widens to `.wholeSet`.
public struct ScopeMapper {
    public let maxProjects: Int
    public init(maxProjects: Int = 25) { self.maxProjects = maxProjects }

    public func scope(for batch: ChangeBatch, root: URL, isExcluded: (String) -> Bool) -> RunScope {
        if batch.mustRescan { return .wholeSet }
        let prefixes = Self.rootPrefixes(root)
        var projects = Set<String>()
        for path in batch.paths {
            guard let rel = Self.relative(path, prefixes: prefixes) else { return .wholeSet }
            let parts = rel.split(separator: "/").map(String.init)
            // The root itself always widens.
            if parts.isEmpty { return .wholeSet }
            if isExcluded(rel) { continue }
            // A root-level entry, or a top-level folder itself (created, deleted, renamed),
            // cannot be pinned to one project.
            if parts.count < 2 { return .wholeSet }
            projects.insert(parts[0])
        }
        if projects.isEmpty { return .nothing }
        if projects.count > maxProjects { return .wholeSet }
        return .projects(projects.sorted())
    }

    /// `paths` relative to `root`. Any that aren't below it are left out.
    public static func relative(_ paths: [String], root: URL) -> [String] {
        let prefixes = rootPrefixes(root)
        return paths.compactMap { relative($0, prefixes: prefixes) }.filter { !$0.isEmpty }
    }

    private static func rootPrefixes(_ root: URL) -> [String] {
        var out = [root.standardizedFileURL.path]
        let resolved = root.resolvingSymlinksInPath().path
        if !out.contains(resolved) { out.append(resolved) }
        // URL's spellings drop `/private`, which is how FSEvents reports /tmp and /var.
        if let real = realpath(root.path, nil) {
            defer { free(real) }
            let path = String(cString: real)
            if !out.contains(path) { out.append(path) }
        }
        return out.map { $0.hasSuffix("/") ? $0 : $0 + "/" }
    }

    private static func relative(_ path: String, prefixes: [String]) -> String? {
        for p in prefixes {
            if path.hasPrefix(p) { return String(path.dropFirst(p.count)) }
            if path + "/" == p { return "" }
        }
        return nil
    }
}
