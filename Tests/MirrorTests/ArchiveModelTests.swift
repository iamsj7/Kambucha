import Testing
import Foundation
import MirrorCore
@testable import Mirror

private final class FakeArchive: ArchiveProviding, @unchecked Sendable {
    var entries: [ArchiveEntry] = []
    var listError: (any Error)?
    var restoreError: (any Error)?
    private(set) var restored: [(ArchiveEntry, URL)] = []
    func list(set: BackupSet, destination: Destination) async throws -> [ArchiveEntry] {
        if let listError { throw listError }
        return entries
    }
    func restore(entry: ArchiveEntry, set: BackupSet, destination: Destination, to: URL) async throws {
        if let restoreError { throw restoreError }
        restored.append((entry, to))
    }
}

@MainActor
struct ArchiveModelTests {
    let source = URL(fileURLWithPath: "/tmp/mirror-test-source-\(UUID().uuidString)")
    fileprivate func make(_ fake: FakeArchive) throws -> (ArchiveModel, BackupSet, Destination) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mirror-test-\(UUID().uuidString)")
        let store = ConfigStore(root: root)
        let dest = Destination(name: "iCloud", kind: .iCloudFolder)
        let set = BackupSet(name: "Docs", source: source, destinationIDs: [dest.id])
        try store.saveSets([set]); try store.saveDestinations([dest])
        let model = ArchiveModel(provider: fake, store: store)
        model.loadConfig()
        return (model, set, dest)
    }
    func entry(_ id: String, day: Int) -> ArchiveEntry {
        ArchiveEntry(id: id, setName: "Docs", stamp: Date(timeIntervalSince1970: 1_800_000_000 + Double(day) * 86_400), path: "a/\(id).txt", size: 10)
    }

    @Test func groupsNewestDayFirst() async throws {
        let fake = FakeArchive()
        fake.entries = [entry("old", day: 0), entry("new1", day: 5), entry("new2", day: 5)]
        let (model, _, _) = try make(fake)
        await model.reload()
        #expect(model.sections.map { $0.entries.count } == [2, 1])
        #expect(model.sections[0].entries.allSatisfy { $0.id.hasPrefix("new") })
    }

    @Test func listFailureIsShownNotThrown() async throws {
        let fake = FakeArchive(); fake.listError = URLError(.notConnectedToInternet)
        let (model, _, _) = try make(fake)
        await model.reload()
        guard case .failed = model.phase else { Issue.record("expected failed"); return }
    }

    @Test func restoreGoesToTheChosenLocation() async throws {
        let fake = FakeArchive(); fake.entries = [entry("x", day: 1)]
        let (model, _, _) = try make(fake)
        await model.reload()
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("restored-x.txt")
        await model.restore(fake.entries[0]) { _ in target }
        #expect(fake.restored.count == 1 && fake.restored[0].1 == target)
        #expect(model.restoreState == .done(target))
    }

    @Test func cancellingThePanelRestoresNothing() async throws {
        let fake = FakeArchive(); fake.entries = [entry("x", day: 1)]
        let (model, _, _) = try make(fake)
        await model.reload()
        await model.restore(fake.entries[0]) { _ in nil }
        #expect(fake.restored.isEmpty && model.restoreState == .idle)
    }

    @Test func neverRestoresInsideTheSource() async throws {
        let fake = FakeArchive(); fake.entries = [entry("x", day: 1)]
        let (model, _, _) = try make(fake)
        await model.reload()
        let inside = source.appendingPathComponent("a/x.txt")   // the original's own path
        await model.restore(fake.entries[0]) { _ in inside }
        #expect(fake.restored.isEmpty)
        guard case .failed = model.restoreState else { Issue.record("expected failed"); return }
    }

    @Test func restoreFailureIsShown() async throws {
        let fake = FakeArchive(); fake.entries = [entry("x", day: 1)]; fake.restoreError = URLError(.timedOut)
        let (model, _, _) = try make(fake)
        await model.reload()
        await model.restore(fake.entries[0]) { _ in FileManager.default.temporaryDirectory.appendingPathComponent("r.txt") }
        guard case .failed = model.restoreState else { Issue.record("expected failed"); return }
    }

    @Test func restoreTargetCheckHandlesLookalikePrefixes() {
        let src = URL(fileURLWithPath: "/Users/me/Projects")
        #expect(RestoreTarget.isInside(URL(fileURLWithPath: "/Users/me/Projects/a.txt"), anyOf: [src]))
        #expect(RestoreTarget.isInside(src, anyOf: [src]))
        #expect(RestoreTarget.isInside(URL(fileURLWithPath: "/users/ME/projects/a.txt"), anyOf: [src]))
        #expect(!RestoreTarget.isInside(URL(fileURLWithPath: "/Users/me/Projects-restored/a.txt"), anyOf: [src]))
    }

    @Test func drillDueAfterFirstBackupOfAnEncryptedDestination() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mirror-test-\(UUID().uuidString)")
        let store = ConfigStore(root: root)
        let dest = Destination(name: "Drive", kind: .googleDrive)
        let set = BackupSet(name: "Docs", source: source, destinationIDs: [dest.id])
        try store.saveSets([set]); try store.saveDestinations([dest])
        var st = SetState(); st.lastFinished = Date()
        try store.save(st, for: PairID(set: set.id, destination: dest.id))
        let model = ArchiveModel(provider: FakeArchive(), store: store)
        model.loadConfig()
        #expect(model.drillDueDestinations.map(\.id) == [dest.id])
    }
}
