import Testing
import Foundation
@testable import MirrorCore

struct PathGuardTests {
    struct Env {
        let base: URL, icloud: URL, root: URL, guardian: PathGuard
        init() throws {
            base = FileManager.default.temporaryDirectory.appendingPathComponent("mirror-pg-\(UUID().uuidString)")
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
}
