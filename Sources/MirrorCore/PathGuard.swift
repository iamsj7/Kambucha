import Foundation

public enum GuardFailure: Error, Equatable {
    case sourceMissing, sourceUnreadable, sourceInsideICloud, sourceContainsBackupRoot, setsOverlap(String), setNameTaken(String)
    case iCloudUnavailable, destinationOutsideRoot, destinationUnclaimed
    case sourceSuspiciouslyEmpty(now: Int, last: Int)
}

public struct PathGuard: Sendable {
    public let iCloudDrive: URL
    public let backupRoot: URL

    public init(iCloudDrive: URL, backupRoot: URL) {
        self.iCloudDrive = iCloudDrive; self.backupRoot = backupRoot
    }

    /// Reduces a set name to a single safe path component (for display or new names).
    public static func sanitizedComponent(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (cleaned.isEmpty || cleaned == "." || cleaned == "..") ? "Set" : cleaned
    }

    public func validateNewSet(_ set: BackupSet, existing: [BackupSet]) throws {
        try checkSource(set)
        let mine = Self.resolved(set.source)
        for other in existing where other.id != set.id {
            if other.name.caseInsensitiveCompare(set.name) == .orderedSame { throw GuardFailure.setNameTaken(other.name) }
            let theirs = Self.resolved(other.source)
            if Self.isSameOrInside(mine, theirs) || Self.isSameOrInside(theirs, mine) {
                throw GuardFailure.setsOverlap(other.name)
            }
        }
        try assertInsideRoot(mirrorURL(set))
    }

    public func validateRun(_ set: BackupSet, destination: Destination, marker: RootMarker?,
                            sampleFileCount: Int, state: SetState) throws {
        try checkSource(set)
        try assertInsideRoot(mirrorURL(set))
        // Cloud destinations don't live in iCloud Drive, so only the iCloud folder needs it present.
        if destination.kind == .iCloudFolder {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: iCloudDrive.path, isDirectory: &isDir), isDir.boolValue else {
                throw GuardFailure.iCloudUnavailable
            }
        }
        guard let marker, marker.claims(set.id) else { throw GuardFailure.destinationUnclaimed }
        if sampleFileCount == 0, let last = state.lastFileCount, last > 0 {
            throw GuardFailure.sourceSuspiciouslyEmpty(now: sampleFileCount, last: last)
        }
    }

    public func sameVolumeAsICloud(_ url: URL) -> Bool {
        func vol(_ u: URL) -> NSObject? {
            (try? u.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
        }
        guard let a = vol(url), let b = vol(iCloudDrive) else { return false }
        return a.isEqual(b)
    }

    /// Throws unless `url` is strictly inside the backup root after resolving `..` and symlinks.
    public func assertInsideRoot(_ url: URL) throws {
        let root = Self.resolved(backupRoot), target = Self.resolved(url)
        guard target != root, Self.isSameOrInside(target, root) else { throw GuardFailure.destinationOutsideRoot }
    }

    // MARK: - Private

    /// The set's mirror folder. Must be exactly one component below `Sets/`.
    private func mirrorURL(_ set: BackupSet) throws -> URL {
        let name = set.name
        if name.isEmpty || name == "." || name == ".." || name.contains("/") || name.contains("\0") {
            throw GuardFailure.destinationOutsideRoot
        }
        let url = backupRoot.appendingPathComponent(MirrorPaths.mirrorPath(set), isDirectory: true)
        let sets = Self.resolved(backupRoot.appendingPathComponent("Sets", isDirectory: true))
        guard Self.resolved(url).deletingLastPathComponent().path.lowercased() == sets.path.lowercased() else {
            throw GuardFailure.destinationOutsideRoot
        }
        return url
    }

    private func checkSource(_ set: BackupSet) throws {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: set.source.path, isDirectory: &isDir), isDir.boolValue else {
            throw GuardFailure.sourceMissing
        }
        guard fm.isReadableFile(atPath: set.source.path),
              (try? fm.contentsOfDirectory(atPath: set.source.path)) != nil else {
            throw GuardFailure.sourceUnreadable
        }
        if Self.isSameOrInside(Self.resolved(set.source), Self.resolved(iCloudDrive)) {
            throw GuardFailure.sourceInsideICloud
        }
        let src = Self.resolved(set.source)
        if Self.isSameOrInside(Self.resolved(iCloudDrive), src) || Self.isSameOrInside(Self.resolved(backupRoot), src) {
            throw GuardFailure.sourceContainsBackupRoot
        }
    }

    static func resolved(_ url: URL) -> URL { url.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL }

    /// True when `child` equals `parent` or lies beneath it, compared by whole path components.
    static func isSameOrInside(_ child: URL, _ parent: URL) -> Bool {
        // Case-insensitive: default APFS is, and over-matching on a case-sensitive volume only errs safe.
        let c = child.pathComponents.map { $0.lowercased() }, p = parent.pathComponents.map { $0.lowercased() }
        return c.count >= p.count && Array(c.prefix(p.count)) == p
    }
}
