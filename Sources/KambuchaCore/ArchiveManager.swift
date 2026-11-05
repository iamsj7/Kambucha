import Foundation
import os

public enum ArchiveError: Error, Equatable, Sendable {
    case outsideArchive(String)
    case rcloneFailed(String)
    case authExpired
}

/// Keeps archive work inside `Archive/`. Textual checks for every endpoint; for a local folder the path is
/// also canonicalised through `PathGuard`, so a symlink inside `Archive/` cannot lead out of it.
enum ArchiveScope {
    static let folder = "Archive"

    static func checkName(_ name: String) throws {
        if name.isEmpty || name == "." || name == ".." || name.contains("/") || name.contains("\0") {
            throw ArchiveError.outsideArchive(name)
        }
    }

    static func join(_ base: String, _ parts: String...) -> String {
        parts.reduce(base) { acc, p in (acc.hasSuffix(":") || acc.hasSuffix("/")) ? acc + p : acc + "/" + p }
    }

    private static func parse(_ s: String) -> (remote: String?, comps: [String]) {
        var rest = s, remote: String?
        if !s.hasPrefix("/"), let i = s.firstIndex(of: ":"), !s[..<i].contains("/") {
            remote = String(s[..<i]); rest = String(s[s.index(after: i)...])
        }
        return (remote, rest.split(separator: "/", omittingEmptySubsequences: true).map(String.init))
    }

    /// Throws unless `path` lies strictly below an `Archive` folder. With `archiveRoot` it must lie below
    /// exactly that folder; without it, below the first `Archive` component.
    static func validate(_ path: String, archiveRoot: String? = nil) throws {
        let p = parse(path)
        guard !p.comps.contains(".."), !p.comps.contains("."), !path.contains("\0") else {
            throw ArchiveError.outsideArchive(path)
        }
        var rootComps: [String]
        if let archiveRoot {
            let r = parse(archiveRoot)
            guard r.remote == p.remote else { throw ArchiveError.outsideArchive(path) }
            rootComps = r.comps
        } else {
            guard let i = p.comps.firstIndex(of: folder) else { throw ArchiveError.outsideArchive(path) }
            rootComps = Array(p.comps.prefix(i + 1))
        }
        guard p.comps.count > rootComps.count, Array(p.comps.prefix(rootComps.count)) == rootComps else {
            throw ArchiveError.outsideArchive(path)
        }
        if p.remote == nil, path.hasPrefix("/") {
            let root = URL(fileURLWithPath: "/" + rootComps.joined(separator: "/"), isDirectory: true)
            let target = URL(fileURLWithPath: "/" + p.comps.joined(separator: "/"))
            do { try PathGuard(iCloudDrive: root, backupRoot: root).assertInsideRoot(target) }
            catch { throw ArchiveError.outsideArchive(path) }
        }
    }

    /// Restore sources: `Sets/<set>[/sub]` or `Archive/<set>/<stamp>[/sub]` below the backup root.
    /// - Local paths must be absolute and need `backupRoot` (also absolute): the target, canonicalised, must lie
    ///   strictly inside the canonical `backupRoot/Sets` or `/Archive`, and that `Sets`/`Archive` folder must not
    ///   itself be a symlink. The root is canonicalised alone, never derived from the target.
    /// - Remote paths (`name:...`) need a remote name without `,` or `:`; with `backupRoot` they must sit under it,
    ///   without it under the first `Sets` or `Archive` component.
    /// - A path starting with `-` or `:` is refused, so rclone can never read it as an option or connection string.
    static func validateRestore(_ path: String, backupRoot: String? = nil) throws {
        let bad = ArchiveError.outsideArchive(path)
        guard !path.hasPrefix("-"), !path.hasPrefix(":") else { throw bad }
        let p = parse(path)
        guard !p.comps.contains(".."), !p.comps.contains("."), !path.contains("\0") else { throw bad }
        if let remote = p.remote, remote.isEmpty || remote.contains(",") || remote.contains(":") || remote.hasPrefix("-") {
            throw bad
        }
        let isLocal = p.remote == nil
        if isLocal { guard path.hasPrefix("/") else { throw bad } }
        var rootCount: Int
        if let backupRoot {
            guard !backupRoot.hasPrefix("-"), !backupRoot.hasPrefix(":") else { throw bad }
            let r = parse(backupRoot)
            guard r.remote == p.remote, p.comps.count > r.comps.count,
                  Array(p.comps.prefix(r.comps.count)) == r.comps else { throw bad }
            if isLocal { guard backupRoot.hasPrefix("/") else { throw bad } }
            rootCount = r.comps.count
        } else {
            if isLocal { throw bad }
            guard let i = p.comps.firstIndex(where: { $0 == "Sets" || $0 == folder }) else { throw bad }
            rootCount = i
        }
        let rest = Array(p.comps.dropFirst(rootCount))
        switch rest.first {
        case "Sets": guard rest.count >= 2 else { throw bad }
        case folder: guard rest.count >= 3, parseStamp(rest[2]) != nil else { throw bad }
        default: throw bad
        }
        if isLocal, let backupRoot {
            let rootURL = PathGuard.canonical(URL(fileURLWithPath: backupRoot, isDirectory: true))
            let top = URL(fileURLWithPath: backupRoot, isDirectory: true).appendingPathComponent(rest[0], isDirectory: true)
            // The Sets/Archive folder itself must be a real directory, wherever a link would point.
            if let type = (try? FileManager.default.attributesOfItem(atPath: top.path))?[.type] as? FileAttributeType,
               type == .typeSymbolicLink { throw bad }
            let allowed = rootURL.appendingPathComponent(rest[0], isDirectory: true)
            let target = URL(fileURLWithPath: "/" + p.comps.joined(separator: "/"))
            guard PathGuard.strictlyInsideCanonical(target, allowed) else { throw bad }
        }
    }

    /// Stamp folder names: `2026-11-04T10-00` or `2026-11-04T10-00-30`, UTC.
    static func parseStamp(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC")
        for fmt in ["yyyy-MM-dd'T'HH-mm-ss", "yyyy-MM-dd'T'HH-mm"] {
            f.dateFormat = fmt
            if let d = f.date(from: s) { return d }
        }
        return nil
    }

    static func stampString(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        return f.string(from: d)
    }
}

/// Lists, prunes and evicts `Archive/<set>/<stamp>/...` at one destination. `endpoint` is the backup root as
/// rclone sees it: a folder path for iCloud, a crypt remote such as `kambuchacrypt:` for the cloud kinds.
public struct ArchiveManager: Sendable {
    private static let log = Logger(subsystem: KambuchaCore.bundleID, category: "ArchiveManager")
    let rclone: any RcloneRunning
    let endpoint: String
    let context: RcloneContext
    let kind: DestinationKind
    let isUploaded: @Sendable (URL) -> Bool
    let evict: @Sendable (URL) throws -> Void

    public init(rclone: any RcloneRunning, endpoint: String, context: RcloneContext, kind: DestinationKind) {
        self.init(rclone: rclone, endpoint: endpoint, context: context, kind: kind,
                  isUploaded: Self.systemIsUploaded, evict: { try FileManager.default.evictUbiquitousItem(at: $0) })
    }

    init(rclone: any RcloneRunning, endpoint: String, context: RcloneContext, kind: DestinationKind,
         isUploaded: @escaping @Sendable (URL) -> Bool, evict: @escaping @Sendable (URL) throws -> Void) {
        self.rclone = rclone; self.endpoint = endpoint; self.context = context; self.kind = kind
        self.isUploaded = isUploaded; self.evict = evict
    }

    static let systemIsUploaded: @Sendable (URL) -> Bool = { url in
        guard let v = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemIsUploadedKey]) else { return false }
        return v.isUbiquitousItem == true && v.ubiquitousItemIsUploaded == true
    }

    var archiveRoot: String { ArchiveScope.join(endpoint, ArchiveScope.folder) }

    /// `Archive/<set>` or `Archive/<set>/<stamp>`, checked to be inside `Archive/` before anything uses it.
    func target(_ set: BackupSet, stamp: String? = nil) throws -> String {
        try ArchiveScope.checkName(set.name)
        var path = ArchiveScope.join(archiveRoot, set.name)
        if let stamp {
            guard ArchiveScope.parseStamp(stamp) != nil, !stamp.contains("/") else { throw ArchiveError.outsideArchive(stamp) }
            path = ArchiveScope.join(path, stamp)
        }
        try ArchiveScope.validate(path, archiveRoot: archiveRoot)
        return path
    }

    /// JSON on stderr, so an expired sign-in can be told apart the way a run's log is read.
    private func args(_ a: [String]) -> [String] { a + ["--use-json-log", "--config", context.configPath] }

    private func failure(_ out: RcloneCapture) -> ArchiveError {
        RcloneLogParser.outcome(exitCode: out.exitCode, log: Data(out.stderr.utf8)) == .authExpired ? .authExpired : .rcloneFailed(out.stderr)
    }

    // rclone reports a missing directory as exit code 3. For an archive that has not been made yet that is empty.
    private func lsf(_ extra: [String], _ path: String) async throws -> [String] {
        let out = try await rclone.capture(args(["lsf"] + extra + [path]), context: context)
        if out.exitCode == 3 { return [] }
        guard out.exitCode == 0 else { throw failure(out) }
        return out.stdout.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    /// Lists through rclone so names on an encrypted destination are decrypted.
    public func list(set: BackupSet) async throws -> [ArchiveEntry] {
        let base = try target(set)
        let lines = try await lsf(["-R", "--files-only", "--format", "sp", "--separator", "\t"], base)
        var entries: [ArchiveEntry] = []
        for line in lines {
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, let size = Int64(parts[0]) else { continue }
            let rel = String(parts[1])
            guard let stamp = rel.split(separator: "/", maxSplits: 1).first.map(String.init),
                  let date = ArchiveScope.parseStamp(stamp), rel.contains("/") else { continue }
            let path = "\(ArchiveScope.folder)/\(set.name)/\(rel)"
            entries.append(ArchiveEntry(id: "\(set.name)/\(rel)", setName: set.name, stamp: date, path: path, size: size))
        }
        return entries.sorted { ($0.stamp, $0.path) > ($1.stamp, $1.path) }
    }

    /// Purges stamp folders older than the set's keep period (never less than 1 day). Only
    /// `Archive/<set>/<stamp>` is ever passed to purge. The newest stamp is always kept, and nothing is
    /// pruned when the clock looks wrong: a stamp in the future, or a newest stamp older than the keep period
    /// plus 7 days (a forward jump would otherwise make every stamp look expired). Returns how many went.
    @discardableResult
    public func prune(set: BackupSet, now: Date) async throws -> Int {
        let base = try target(set)
        let keep = Double(max(1, set.archiveDays)) * 86_400
        let stamps = try await lsf(["--dirs-only"], base).map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
        let dated = stamps.compactMap { s in ArchiveScope.parseStamp(s).map { (s, $0) } }
        guard let newest = dated.map(\.1).max() else { return 0 }
        if newest > now || now.timeIntervalSince(newest) > keep + 7 * 86_400 { return 0 }
        var purged = 0
        let cutoff = now.addingTimeInterval(-keep)
        for (stamp, date) in dated where date < cutoff && date != newest {
            let path = try target(set, stamp: stamp)
            let out = try await rclone.capture(args(["purge", path]), context: context)
            guard out.exitCode == 0 || out.exitCode == 3 else { throw failure(out) }
            purged += 1
        }
        return purged
    }

    /// Frees uploaded archive files on this Mac. iCloud only, and only below `Archive/<set>`; the mirror is
    /// never visited. Returns how many files were evicted.
    public func evictUploaded(set: BackupSet) throws -> Int {
        guard kind == .iCloudFolder, endpoint.hasPrefix("/") else { return 0 }
        let dir = URL(fileURLWithPath: try target(set), isDirectory: true)
        guard let walker = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: [.isRegularFileKey], options: []) else { return 0 }
        var count = 0
        for case let url as URL in walker {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                  !Dataless.isDataless(url), isUploaded(url) else { continue }
            do { try evict(url); count += 1 } catch { Self.log.error("could not evict an archive file") }
        }
        return count
    }
}
