import Foundation

/// Finds items worth a second look without walking excluded folders.
public struct ReviewScanner: Sendable {
    /// Third-party folders: a secret inside one is somebody else's, never the owner's.
    public static let thirdParty: Set<String> = ["node_modules", "Pods", ".venv", "vendor"]
    let filters: FilterBuilder
    public init(filters: FilterBuilder) { self.filters = filters }

    static func isSecretName(_ name: String) -> Bool {
        let n = name.lowercased()
        return PresetCatalog.secretPatterns.contains { fnmatch($0.lowercased(), n, 0) == 0 }
    }

    /// `changedExcludedPaths` are set-relative paths FSEvents reported inside excluded folders.
    public func secretsIn(changedExcludedPaths: [String]) -> [ReviewItem] {
        var seen = Set<String>()
        var out: [ReviewItem] = []
        for path in changedExcludedPaths {
            let comps = path.split(separator: "/").map(String.init)
            guard let name = comps.last, Self.isSecretName(name),
                  !comps.dropLast().contains(where: Self.thirdParty.contains) else { continue }
            if seen.insert(path).inserted { out.append(ReviewItem(id: "secret:\(path)", path: path, kind: .secretInExcluded)) }
        }
        return out
    }

    /// `excluded` are repo-relative excluded folders. One item per folder that holds tracked files, which
    /// means it is not really junk. Uses `git ls-files` only; no folder is walked.
    public func trackedInExcluded(repo: URL, excluded: [String]) -> [ReviewItem] {
        let folders = excluded.map { $0.split(separator: "/").joined(separator: "/") }.filter { !$0.isEmpty }
        guard !folders.isEmpty, let tracked = Self.gitLsFiles(repo) else { return [] }
        var out: [ReviewItem] = []
        for folder in Set(folders).sorted() where tracked.contains(where: { $0.hasPrefix(folder + "/") }) {
            let path = repo.appendingPathComponent(folder).path
            out.append(ReviewItem(id: "tracked:\(path)", path: path, kind: .trackedInExcluded))
        }
        return out
    }

    static func gitLsFiles(_ repo: URL) -> [String]? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", repo.path, "-c", "core.quotepath=off", "ls-files", "-z"]
        p.environment = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "GIT_OPTIONAL_LOCKS": "0"]
        let out = Pipe()
        p.standardOutput = out; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self).split(separator: "\0").map(String.init)
    }
}
