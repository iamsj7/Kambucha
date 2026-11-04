import Foundation

/// Every run writes one of these per set to `Mac Backup/Manifests/<set>.json`, outside `Sets/`.
/// On iCloud the mirror holds real symlinks, but how iCloud stores them could not be proved from one Mac,
/// so restore recreates any link missing from the restored files from this record.
public struct SymlinkManifest: Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        /// Path of the link, relative to the set's source.
        public var path: String
        /// The link's target exactly as stored (relative or absolute).
        public var target: String
        public var isAbsolute: Bool
        /// The target did not exist when the manifest was written.
        public var isBroken: Bool
        public init(path: String, target: String, isAbsolute: Bool, isBroken: Bool) {
            self.path = path; self.target = target; self.isAbsolute = isAbsolute; self.isBroken = isBroken
        }
    }

    public var set: String
    public var entries: [Entry]
    public init(set: String, entries: [Entry]) { self.set = set; self.entries = entries }

    /// On disk the manifest is a JSON array of entries; the set is named by the file.
    public static let folderName = "Manifests"

    /// Lists every symlink under `source` without following any of them. `skipDirectory` receives a
    /// source-relative folder path and returns true to leave it unvisited (junk folders hold thousands of links).
    public static func scan(set: BackupSet, source: URL,
                            skipDirectory: (String) -> Bool = { _ in false }) -> SymlinkManifest {
        let fm = FileManager.default
        var entries: [Entry] = []
        // Listed folder by folder with lstat: the enumerator drops dangling links.
        func walk(_ dir: URL, _ rel: String) {
            guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
            for name in names {
                let url = dir.appendingPathComponent(name)
                let path = rel.isEmpty ? name : rel + "/" + name
                var st = stat()
                guard lstat(url.path, &st) == 0 else { continue }
                let kind = st.st_mode & S_IFMT
                if kind == S_IFLNK {
                    guard let target = try? fm.destinationOfSymbolicLink(atPath: url.path) else { continue }
                    entries.append(Entry(path: path, target: target, isAbsolute: target.hasPrefix("/"),
                                         isBroken: !fm.fileExists(atPath: url.path)))
                } else if kind == S_IFDIR, !skipDirectory(path) {
                    walk(url, path)
                }
            }
        }
        walk(source, "")
        entries.sort { $0.path < $1.path }
        return SymlinkManifest(set: set.name, entries: entries)
    }

    /// `<backupRoot>/Manifests/<set>.json`. Refuses a set name that is not one path component.
    public static func location(set: String, backupRoot: URL) throws -> URL {
        try ArchiveScope.checkName(set)
        let folder = backupRoot.appendingPathComponent(folderName, isDirectory: true)
        let file = folder.appendingPathComponent("\(set).json")
        try PathGuard(iCloudDrive: backupRoot, backupRoot: folder).assertInsideRoot(file)
        return file
    }

    @discardableResult
    public func write(backupRoot: URL) throws -> URL {
        let file = try Self.location(set: set, backupRoot: backupRoot)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(entries).write(to: file, options: .atomic)
        return file
    }

    public static func read(set: String, backupRoot: URL) throws -> SymlinkManifest {
        let entries = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: location(set: set, backupRoot: backupRoot)))
        return SymlinkManifest(set: set, entries: entries)
    }

    /// Recreates links that are not present under `root`. `subpath` is the set-relative folder that `root`
    /// holds ("" when `root` is the whole set). Nothing that already exists is touched, and nothing is
    /// created outside `root`. Returns how many links were created.
    @discardableResult
    public func recreateMissing(under root: URL, subpath: String = "") -> Int {
        let fm = FileManager.default
        let prefix = subpath.split(separator: "/").map(String.init)
        var created = 0
        for e in entries {
            let comps = e.path.split(separator: "/").map(String.init)
            guard comps.count > prefix.count, Array(comps.prefix(prefix.count)) == prefix,
                  !comps.contains(".."), !comps.contains(".") else { continue }
            // The parent chain is built one component at a time. A component that is a symlink (for example a
            // restored `a -> /outside`) is never entered, so nothing is written outside `root`.
            var cur = root, ok = true
            for c in comps.dropFirst(prefix.count).dropLast() {
                cur = cur.appendingPathComponent(c)
                var st = stat()
                if lstat(cur.path, &st) == 0 {
                    if (st.st_mode & S_IFMT) != S_IFDIR { ok = false; break }
                } else if (try? fm.createDirectory(at: cur, withIntermediateDirectories: false)) == nil { ok = false; break }
            }
            let dest = cur.appendingPathComponent(comps.last!)
            guard ok, PathGuard.strictlyInsideCanonical(cur.appendingPathComponent("x"), root) else { continue }
            var st = stat()
            if lstat(dest.path, &st) == 0 { continue }   // present, even if broken
            do {
                try fm.createSymbolicLink(atPath: dest.path, withDestinationPath: e.target)
                created += 1
            } catch { continue }
        }
        return created
    }
}
