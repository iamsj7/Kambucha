import Foundation

public enum ReviewError: Error, Equatable, Sendable { case gitFailed(String) }

/// Finds items worth a second look without walking excluded folders.
public struct ReviewScanner: Sendable {
    /// Third-party folders: a secret inside one is somebody else's, never the owner's.
    public static let thirdParty: Set<String> = ["node_modules", "Pods", ".venv", "vendor"]
    let filters: FilterBuilder
    let gitPath: String
    public init(filters: FilterBuilder) { self.init(filters: filters, gitPath: "/usr/bin/git") }
    init(filters: FilterBuilder, gitPath: String) { self.filters = filters; self.gitPath = gitPath }

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
    /// means it is not really junk. Uses `git ls-files` only; no folder is walked. A folder with no `.git` is
    /// not a repo and gives nothing; git failing to run in a repo throws, so it is never read as "all clear".
    public func trackedInExcluded(repo: URL, excluded: [String]) throws -> [ReviewItem] {
        let folders = excluded.map { $0.split(separator: "/").joined(separator: "/") }.filter { !$0.isEmpty }
        guard !folders.isEmpty,
              FileManager.default.fileExists(atPath: repo.appendingPathComponent(".git").path) else { return [] }
        let tracked = try gitLsFiles(repo)
        var out: [ReviewItem] = []
        for folder in Set(folders).sorted() where tracked.contains(where: { $0.hasPrefix(folder + "/") }) {
            let path = repo.appendingPathComponent(folder).path
            out.append(ReviewItem(id: "tracked:\(path)", path: path, kind: .trackedInExcluded))
        }
        return out
    }

    /// A repo's own config must not be able to run anything in this process (core.fsmonitor, hooks).
    static func gitArguments(_ repo: URL) -> [String] {
        ["-C", repo.path, "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null",
         "-c", "core.quotepath=off", "ls-files", "-z"]
    }
    static var gitEnvironment: [String: String] {
        ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "GIT_OPTIONAL_LOCKS": "0",
         "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"]
    }

    func gitLsFiles(_ repo: URL) throws -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: gitPath)
        p.arguments = Self.gitArguments(repo)
        p.environment = Self.gitEnvironment
        let out = Pipe()
        p.standardOutput = out; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { throw ReviewError.gitFailed("could not run git: \(error.localizedDescription)") }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw ReviewError.gitFailed("git ls-files exited \(p.terminationStatus) in \(repo.path)") }
        return String(decoding: data, as: UTF8.self).split(separator: "\0").map(String.init)
    }
}
