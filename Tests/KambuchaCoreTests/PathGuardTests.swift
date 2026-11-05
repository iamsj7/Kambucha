import Testing
import Foundation
@testable import KambuchaCore

struct PathGuardTests {
    struct Env {
        let base: URL, icloud: URL, root: URL, guardian: PathGuard
        init() throws {
            base = FileManager.default.temporaryDirectory.appendingPathComponent("kambucha-pg-\(UUID().uuidString)")
            icloud = base.appendingPathComponent("iCloud")
            root = icloud.appendingPathComponent("Mac Backup")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            guardian = PathGuard(iCloudDrive: icloud, backupRoot: root)
        }
        func dir(_ rel: String) throws -> URL {
            let u = base.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
            return u
        }
        func set(_ name: String, _ source: URL) -> BackupSet { BackupSet(name: name, source: source) }
    }
    let dest = Destination(name: "iCloud", kind: .iCloudFolder)

    func fails(_ expected: GuardFailure, _ body: () throws -> Void) {
        do { try body(); Issue.record("expected \(expected)") }
        catch let e as GuardFailure { #expect(e == expected) }
        catch { Issue.record("wrong error \(error)") }
    }

    @Test func rejectsSourceInsideICloud() throws {
        let e = try Env()
        let s = e.set("A", try e.dir("iCloud/Docs"))
        fails(.sourceInsideICloud) { try e.guardian.validateNewSet(s, existing: []) }
    }

    @Test func rejectsOverlappingSets() throws {
        let e = try Env()
        let parent = e.set("Parent", try e.dir("src/proj"))
        let child = e.set("Child", try e.dir("src/proj/sub"))
        fails(.setsOverlap("Parent")) { try e.guardian.validateNewSet(child, existing: [parent]) }
        fails(.setsOverlap("Child")) { try e.guardian.validateNewSet(parent, existing: [child]) }
        let sibling = e.set("Sib", try e.dir("src/proj2"))
        try e.guardian.validateNewSet(sibling, existing: [parent])
    }

    @Test func rejectsDestinationEscapingRoot() throws {
        let e = try Env()
        let src = try e.dir("src")
        fails(.destinationOutsideRoot) { try e.guardian.validateNewSet(e.set("..", src), existing: []) }
        fails(.destinationOutsideRoot) { try e.guardian.validateNewSet(e.set("../../x", src), existing: []) }
        fails(.destinationOutsideRoot) { try e.guardian.assertInsideRoot(e.base.appendingPathComponent("elsewhere")) }
        fails(.destinationOutsideRoot) { try e.guardian.assertInsideRoot(e.root.appendingPathComponent("../x")) }
        try e.guardian.assertInsideRoot(e.root.appendingPathComponent("Sets/A"))
    }

    @Test func refusesExistingFolderNotInMarker() throws {
        let e = try Env()
        let s = e.set("A", try e.dir("src"))
        _ = try e.dir("iCloud/Mac Backup/Sets/A")
        fails(.destinationUnclaimed) {
            try e.guardian.validateRun(s, destination: dest, marker: nil, sampleFileCount: 10, state: SetState())
        }
        fails(.destinationUnclaimed) {
            try e.guardian.validateRun(s, destination: dest, marker: RootMarker(sets: [UUID(): "A"]),
                                       sampleFileCount: 10, state: SetState())
        }
        try e.guardian.validateRun(s, destination: dest, marker: RootMarker(sets: [s.id: "A"]),
                                   sampleFileCount: 10, state: SetState())
    }

    @Test func iCloudMissingThrowsUnavailable() throws {
        let e = try Env()
        let s = e.set("A", try e.dir("src"))
        let g = PathGuard(iCloudDrive: e.base.appendingPathComponent("nope"),
                          backupRoot: e.base.appendingPathComponent("nope/Mac Backup"))
        let m = RootMarker(sets: [s.id: "A"])
        fails(.iCloudUnavailable) {
            try g.validateRun(s, destination: dest, marker: m, sampleFileCount: 1, state: SetState())
        }
        // Cloud destinations skip the iCloud check but still need the claim.
        let cloud = Destination(name: "GD", kind: .googleDrive)
        try g.validateRun(s, destination: cloud, marker: m, sampleFileCount: 1, state: SetState())
        fails(.destinationUnclaimed) {
            try g.validateRun(s, destination: cloud, marker: nil, sampleFileCount: 1, state: SetState())
        }
    }

    @Test func sourceMissingThrows() throws {
        let e = try Env()
        let s = e.set("A", e.base.appendingPathComponent("gone"))
        fails(.sourceMissing) { try e.guardian.validateNewSet(s, existing: []) }
        fails(.sourceMissing) {
            try e.guardian.validateRun(s, destination: dest, marker: RootMarker(sets: [s.id: "A"]),
                                       sampleFileCount: 1, state: SetState())
        }
    }

    @Test func emptySourceWithPriorFilesThrowsSuspicious() throws {
        let e = try Env()
        let s = e.set("A", try e.dir("src"))
        var st = SetState(); st.lastFileCount = 5000
        let m = RootMarker(sets: [s.id: "A"])
        fails(.sourceSuspiciouslyEmpty(now: 0, last: 5000)) {
            try e.guardian.validateRun(s, destination: dest, marker: m, sampleFileCount: 0, state: st)
        }
        // A genuinely new, empty set is fine.
        try e.guardian.validateRun(s, destination: dest, marker: m, sampleFileCount: 0, state: SetState())
    }

    @Test func smallDropIsAllowed() throws {
        let e = try Env()
        let s = e.set("A", try e.dir("src"))
        var st = SetState(); st.lastFileCount = 5000
        try e.guardian.validateRun(s, destination: dest, marker: RootMarker(sets: [s.id: "A"]),
                                   sampleFileCount: 4900, state: st)
    }

    @Test func markerRoundTripsAndVolumeCheck() throws {
        let e = try Env()
        let m = RootMarker(sets: [UUID(): "A", UUID(): "B"])
        try m.save(backupRoot: e.root)
        #expect(try RootMarker.load(backupRoot: e.root) == m)
        #expect(try RootMarker.load(backupRoot: e.base.appendingPathComponent("none")) == nil)
        #expect(e.guardian.sameVolumeAsICloud(e.base))
        #expect(PathGuard.sanitizedComponent("a/b:c") == "a-b-c")
        #expect(PathGuard.sanitizedComponent("..") == "Set")
    }

    @Test func rejectsSourceContainingICloudOrRoot() throws {
        let e = try Env()
        let s = e.set("A", e.base)
        fails(.sourceContainsBackupRoot) { try e.guardian.validateNewSet(s, existing: []) }
        fails(.sourceContainsBackupRoot) {
            try e.guardian.validateRun(s, destination: dest, marker: RootMarker(sets: [s.id: "A"]),
                                       sampleFileCount: 1, state: SetState())
        }
    }

    @Test func caseVariantPathsAreCaught() throws {
        let e = try Env()
        let up = e.set("A", e.icloud.deletingLastPathComponent().appendingPathComponent("ICLOUD/Docs"))
        // Only meaningful where the volume is case-insensitive (default APFS); the guard must not rely on it.
        _ = try e.dir("iCloud/Docs")
        fails(.sourceInsideICloud) { try e.guardian.validateNewSet(up, existing: []) }
        fails(.destinationOutsideRoot) {
            try e.guardian.assertInsideRoot(e.base.appendingPathComponent("ICLOUD/MAC BACKUP/../x"))
        }
        try e.guardian.assertInsideRoot(e.base.appendingPathComponent("ICLOUD/MAC BACKUP/Sets/A"))
        _ = try e.dir("src/Proj/sub")
        let a = e.set("A", try e.dir("src/Proj")), b = e.set("B", e.base.appendingPathComponent("SRC/proj/sub"))
        fails(.setsOverlap("A")) { try e.guardian.validateNewSet(b, existing: [a]) }
    }

    @Test func rejectsDuplicateSetNames() throws {
        let e = try Env()
        let a = e.set("Work", try e.dir("one"))
        let b = e.set("work", try e.dir("two"))
        fails(.setNameTaken("Work")) { try e.guardian.validateNewSet(b, existing: [a]) }
        var same = a; same.source = try e.dir("three")
        try e.guardian.validateNewSet(same, existing: [a])
    }

    @Test func symlinkedSourceIntoICloudRejected() throws {
        let e = try Env()
        let target = try e.dir("iCloud/Docs")
        let link = e.base.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        fails(.sourceInsideICloud) { try e.guardian.validateNewSet(e.set("A", link), existing: []) }
    }

    @Test func symlinkedMirrorFolderEscapingRootRejected() throws {
        let e = try Env()
        let outside = try e.dir("outside")
        _ = try e.dir("iCloud/Mac Backup/Sets")
        try FileManager.default.createSymbolicLink(at: e.root.appendingPathComponent("Sets/A"),
                                                   withDestinationURL: outside)
        let s = e.set("A", try e.dir("src"))
        fails(.destinationOutsideRoot) { try e.guardian.validateNewSet(s, existing: []) }
    }

    @Test func caseVariantOfRootIsNotStrictlyInside() throws {
        let e = try Env()
        fails(.destinationOutsideRoot) {
            try e.guardian.assertInsideRoot(e.icloud.appendingPathComponent("MAC BACKUP"))
        }
        fails(.destinationOutsideRoot) { try e.guardian.assertInsideRoot(e.root) }
        // A not-yet-existing destination under the root must not crash and is allowed.
        try e.guardian.assertInsideRoot(e.root.appendingPathComponent("Sets/NeverCreated/deep"))
    }

    @Test func symlinkedSetFolderRejected() throws {
        let e = try Env()
        let sets = try e.dir("iCloud/Mac Backup/Sets")
        let other = try e.dir("iCloud/Mac Backup/Sets/Real")
        try FileManager.default.createSymbolicLink(at: sets.appendingPathComponent("A"), withDestinationURL: other)
        let s = e.set("A", try e.dir("src"))
        fails(.destinationOutsideRoot) { try e.guardian.validateNewSet(s, existing: []) }
        fails(.destinationOutsideRoot) {
            try e.guardian.validateRun(s, destination: dest, marker: RootMarker(sets: [s.id: "A"]),
                                       sampleFileCount: 1, state: SetState())
        }
    }

    @Test func firmlinkAliasOfSourceRejected() throws {
        let e = try Env()
        // resolvingSymlinksInPath strips /private, so take the on-disk canonical path instead.
        let real = URL(fileURLWithPath: (try? e.base.resourceValues(forKeys: [.canonicalPathKey]))?.canonicalPath ?? e.base.path)
        let alias = URL(fileURLWithPath: "/System/Volumes/Data" + real.path)
        guard FileManager.default.fileExists(atPath: alias.path),
              PathGuard.sameFileIdentity(alias, real) else {
            Issue.record("skipped: /System/Volumes/Data firmlink alias does not resolve to the temp folder on this Mac")
            return
        }
        // Source is the firmlink alias of a folder that contains the backup root.
        let s = e.set("A", alias)
        fails(.sourceContainsBackupRoot) { try e.guardian.validateNewSet(s, existing: []) }
        // Source inside iCloud, reached via the alias.
        _ = try e.dir("iCloud/Docs")
        let inside = e.set("B", alias.appendingPathComponent("iCloud/Docs"))
        fails(.sourceInsideICloud) { try e.guardian.validateNewSet(inside, existing: []) }
        // Overlap through the alias.
        let a = e.set("P", try e.dir("src/proj"))
        let b = e.set("C", alias.appendingPathComponent("src/proj/sub"))
        _ = try e.dir("src/proj/sub")
        fails(.setsOverlap("P")) { try e.guardian.validateNewSet(b, existing: [a]) }
    }

    @Test func sameFileIdentityDetectedThroughSymlink() throws {
        let e = try Env()
        let target = try e.dir("target")
        let link = e.base.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(PathGuard.sameFileIdentity(link, target))
        #expect(!PathGuard.sameFileIdentity(target, try e.dir("other")))
        #expect(!PathGuard.sameFileIdentity(target, e.base.appendingPathComponent("missing")))
        #expect(PathGuard.identityIsSameOrInside(target.appendingPathComponent("x/y"), link))
        #expect(!PathGuard.identityIsSameOrInside(e.base, link))
    }
}
