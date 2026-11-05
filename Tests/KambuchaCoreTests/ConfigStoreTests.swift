import Testing
import Foundation
@testable import KambuchaCore

struct ConfigStoreTests {
    func tempRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("kambucha-test-\(UUID().uuidString)")
    }

    @Test func roundTrip() throws {
        let store = ConfigStore(root: tempRoot())
        let dest = Destination(name: "iCloud", kind: .iCloudFolder)
        var set = BackupSet(name: "Projects", source: URL(fileURLWithPath: "/Users/x/Projects"),
                            presets: ["node", "python"], destinationIDs: [dest.id])
        set.rules = [UserRule(pattern: "keep/**", action: .include)]
        set.deletion.percent = 9
        try store.saveSets([set]); try store.saveDestinations([dest])
        #expect(try store.loadSets() == [set])
        #expect(try store.loadDestinations() == [dest])
        let pair = PairID(set: set.id, destination: dest.id)
        var st = SetState()
        st.lastEventID = 42; st.lastFinished = Date(timeIntervalSince1970: 1_700_000_000)
        st.refusedSince["a.tmp"] = Date(timeIntervalSince1970: 1_700_000_100)
        st.reviewItems = [ReviewItem(id: "1", path: "vendor/x", kind: .trackedInExcluded)]
        try store.save(st, for: pair)
        #expect(try store.state(for: pair) == st)
    }

    @Test func saveIsAtomic() throws {
        let root = tempRoot()
        let store = ConfigStore(root: root)
        let set = BackupSet(name: "A", source: URL(fileURLWithPath: "/a"))
        try store.saveSets([set])
        // A crashed writer's leftover temp file must not affect reads.
        try Data("{ garbage".utf8).write(to: root.appendingPathComponent("sets.json.tmp-leftover"))
        #expect(try store.loadSets() == [set])
        let updated = BackupSet(name: "B", source: URL(fileURLWithPath: "/b"))
        try store.saveSets([updated])
        #expect(try store.loadSets() == [updated])
    }

    @Test func missingStateReturnsDefaults() throws {
        let store = ConfigStore(root: tempRoot())
        let st = try store.state(for: PairID(set: UUID(), destination: UUID()))
        #expect(st == SetState())
        #expect(st.consecutiveFailures == 0 && st.lastEventID == nil)
        #expect(try store.loadSets().isEmpty && store.loadDestinations().isEmpty)
    }

    @Test func stateIsPerPair() throws {
        let store = ConfigStore(root: tempRoot())
        let s = UUID()
        let p1 = PairID(set: s, destination: UUID()), p2 = PairID(set: s, destination: UUID())
        var a = SetState(); a.consecutiveFailures = 3
        try store.save(a, for: p1)
        #expect(try store.state(for: p1).consecutiveFailures == 3)
        #expect(try store.state(for: p2).consecutiveFailures == 0)
    }

    @Test func cloudDefaultsToEncrypted() {
        #expect(Destination(name: "d", kind: .googleDrive).encrypted)
        #expect(Destination(name: "o", kind: .oneDrive).encrypted)
        #expect(!Destination(name: "i", kind: .iCloudFolder).encrypted)
        #expect(!Destination(name: "d", kind: .googleDrive, encrypted: false).encrypted)
    }

    @Test func pathsAreRelativeToRoot() {
        let set = BackupSet(name: "Projects", source: URL(fileURLWithPath: "/p"))
        #expect(KambuchaPaths.mirrorPath(set) == "Sets/Projects")
        #expect(KambuchaPaths.archivePath(set, stamp: "2026-11-04T10-00") == "Archive/Projects/2026-11-04T10-00")
        let home = URL(fileURLWithPath: "/tmp/h")
        #expect(KambuchaPaths.backupRoot(iCloudDrive: KambuchaPaths.iCloudDrive(home: home)).lastPathComponent == "Mac Backup")
        #expect(KambuchaPaths.support(home: home).path == "/tmp/h/Library/Application Support/Kambucha")
    }
}
