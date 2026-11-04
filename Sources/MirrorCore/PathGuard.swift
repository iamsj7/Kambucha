import Foundation

public enum GuardFailure: Error, Equatable {
    case sourceMissing, sourceUnreadable, sourceInsideICloud, sourceContainsBackupRoot, setsOverlap(String), setNameTaken(String)
    case iCloudUnavailable, destinationOutsideRoot, destinationUnclaimed, wrongDrive, internalDiskNotConfirmed
    case sourceSuspiciouslyEmpty(now: Int, last: Int)
}

public struct PathGuard: Sendable {
    public let iCloudDrive: URL
    public let backupRoot: URL

    public init(iCloudDrive: URL, backupRoot: URL) {
        self.iCloudDrive = iCloudDrive; self.backupRoot = backupRoot
    }

    /// A guard whose `Mac Backup` root is at the top of an external volume.
    public static func forVolume(_ volume: VolumeInfo, iCloudDrive: URL) -> PathGuard {
        PathGuard(iCloudDrive: iCloudDrive, backupRoot: ExternalVolume.backupRoot(on: volume))
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
            if Self.denyContains(mine, theirs) || Self.denyContains(theirs, mine) {
                throw GuardFailure.setsOverlap(other.name)
            }
        }
        try assertInsideRoot(mirrorURL(set))
    }

    public func validateRun(_ set: BackupSet, destination: Destination, marker: RootMarker?,
                            sampleFileCount: Int, state: SetState, volume: VolumeInfo? = nil) throws {
        try checkSource(set)
        if destination.kind == .externalDrive {
            // The backup root must sit on the mounted drive whose UUID the destination names.
            let mount = volume?.mountPoint.standardizedFileURL.path ?? "/"
            guard let volume, !volume.isSystem, mount != "/", !mount.hasPrefix("/System/Volumes"),
                  let uuid = destination.volumeUUID,
                  volume.uuid.caseInsensitiveCompare(uuid) == .orderedSame,
                  Self.strictlyInsideCanonical(backupRoot, volume.mountPoint) else { throw GuardFailure.wrongDrive }
            if volume.looksInternal && !destination.internalDiskConfirmed { throw GuardFailure.internalDiskNotConfirmed }
        }
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
        // Allow decision: canonical on-disk spelling, one exact comparison for both "not equal" and "inside".
        guard Self.strictlyInsideCanonical(url, backupRoot) else { throw GuardFailure.destinationOutsideRoot }
    }

    // MARK: - Private

    /// The set's mirror folder. Must be exactly one component below `Sets/`.
    private func mirrorURL(_ set: BackupSet) throws -> URL {
        let name = set.name
        if name.isEmpty || name == "." || name == ".." || name.contains("/") || name.contains("\0") {
            throw GuardFailure.destinationOutsideRoot
        }
        let url = backupRoot.appendingPathComponent(MirrorPaths.mirrorPath(set), isDirectory: true)
        // A Sets/<name> that is itself a symlink is never acceptable, wherever it points.
        if let type = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType,
           type == .typeSymbolicLink {
            throw GuardFailure.destinationOutsideRoot
        }
        let sets = Self.canonical(backupRoot.appendingPathComponent("Sets", isDirectory: true))
        guard Self.canonical(url).deletingLastPathComponent().pathComponents == sets.pathComponents else {
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
        if Self.denyContains(Self.resolved(set.source), Self.resolved(iCloudDrive)) {
            throw GuardFailure.sourceInsideICloud
        }
        let src = Self.resolved(set.source)
        if Self.denyContains(Self.resolved(iCloudDrive), src) || Self.denyContains(Self.resolved(backupRoot), src) {
            throw GuardFailure.sourceContainsBackupRoot
        }
    }

    static func resolved(_ url: URL) -> URL { url.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL }

    /// DENY direction: true when `child` equals or lies beneath `parent` by path (case-insensitive,
    /// `/System/Volumes/Data` prefix ignored) or by filesystem identity. Over-matching here only blocks more,
    /// so it is safe for deny checks. It must NOT be used for allow decisions.
    static func denyContains(_ child: URL, _ parent: URL) -> Bool {
        isSameOrInside(stripDataPrefix(child), stripDataPrefix(parent)) || identityIsSameOrInside(child, parent)
    }

    /// Case-insensitive component containment. Deny checks only: on a case-sensitive volume it over-matches,
    /// which is safe when the answer means "refuse" and unsafe when it means "allow".
    static func isSameOrInside(_ child: URL, _ parent: URL) -> Bool {
        let c = child.pathComponents.map { $0.lowercased() }, p = parent.pathComponents.map { $0.lowercased() }
        return c.count >= p.count && Array(c.prefix(p.count)) == p
    }

    static func stripDataPrefix(_ url: URL) -> URL {
        let c = url.pathComponents
        if c.count >= 4, c[1] == "System", c[2] == "Volumes", c[3] == "Data" {
            return URL(fileURLWithPath: "/" + c.dropFirst(4).joined(separator: "/"))
        }
        return url
    }

    private static func identity(_ url: URL) -> NSObject? {
        guard let v = try? url.resourceValues(forKeys: [.fileResourceIdentifierKey, .volumeIdentifierKey]),
              let f = v.fileResourceIdentifier as? NSObject else { return nil }
        return f
    }

    /// True when both exist and are the same filesystem object (follows symlinks, firmlinks, case variants).
    static func sameFileIdentity(_ a: URL, _ b: URL) -> Bool {
        guard let x = identity(a.resolvingSymlinksInPath()), let y = identity(b.resolvingSymlinksInPath()) else { return false }
        return x.isEqual(y)
    }

    /// True when `child` or any of its existing ancestors is the same filesystem object as `parent`.
    static func identityIsSameOrInside(_ child: URL, _ parent: URL) -> Bool {
        guard let p = identity(parent.resolvingSymlinksInPath()) else { return false }
        var cur = child.standardizedFileURL.resolvingSymlinksInPath()
        while true {
            if let i = identity(cur), i.isEqual(p) { return true }
            let up = cur.deletingLastPathComponent()
            if up.path == cur.path || cur.path == "/" { return false }
            cur = up
        }
    }

    /// Canonical on-disk spelling: the deepest existing ancestor is resolved (symlinks, real case);
    /// components that do not exist yet are kept exactly as given.
    static func canonical(_ url: URL) -> URL {
        let std = resolved(url)
        var existing = std, tail: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" {
            tail.insert(existing.lastPathComponent, at: 0)
            existing = existing.deletingLastPathComponent()
        }
        var base = existing
        if let key = (try? existing.resourceValues(forKeys: [.canonicalPathKey]))?.canonicalPath {
            base = URL(fileURLWithPath: key)
        }
        for t in tail { base.appendPathComponent(t) }
        return base
    }

    /// ALLOW direction: `target` is strictly below `root`, both canonicalised, compared exactly.
    static func strictlyInsideCanonical(_ target: URL, _ root: URL) -> Bool {
        let t = canonical(target).pathComponents, r = canonical(root).pathComponents
        return t.count > r.count && Array(t.prefix(r.count)) == r
    }
}
