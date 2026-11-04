import Testing
import Foundation
import MirrorCore
@testable import Mirror

private final class FakeArchive: ArchiveProviding, @unchecked Sendable {
    var entries: [ArchiveEntry] = []
    var listError: (any Error)?
    var restoreError: (any Error)?
    private(set) var restored: [(ArchiveEntry, URL)] = []
    private(set) var replacing: [Bool] = []
    var folders: [String: [BackupItem]] = [:]
    var browseError: (any Error)?
    func browse(path: String, set: BackupSet, destination: Destination) async throws -> [BackupItem] {
        if let browseError { throw browseError }
        return folders[path] ?? []
    }
    func list(set: BackupSet, destination: Destination) async throws -> [ArchiveEntry] {
        if let listError { throw listError }
        return entries
    }
    func restore(entry: ArchiveEntry, set: BackupSet, destination: Destination, to: URL, replacing: Bool) async throws {
        if let restoreError { throw restoreError }
        restored.append((entry, to))
        self.replacing.append(replacing)
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

    // MARK: The latest backup (final review S12)

    @Test func theLatestBackupOpensAtTheSetAndWalksIntoFolders() async throws {
        let fake = FakeArchive()
        fake.folders = ["Sets/Docs": [BackupItem(name: "p", isFolder: true, size: 0)],
                        "Sets/Docs/p": [BackupItem(name: "f.txt", isFolder: false, size: 3)]]
        let (model, _, _) = try make(fake)
        await model.reloadLatest()
        #expect(model.latest == .loaded(fake.folders["Sets/Docs"]!))
        await model.open("p")
        #expect(model.folder == ["p"])
        #expect(model.latest == .loaded(fake.folders["Sets/Docs/p"]!))
        await model.goUp(to: 0)
        #expect(model.folder.isEmpty)
    }

    @Test func aWholeSetRestoresFromSets() async throws {
        let fake = FakeArchive()
        let (model, _, _) = try make(fake)
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("Docs restored")
        await model.restoreLatest(nil) { $0.path == "Sets/Docs" ? target : nil }
        #expect(fake.restored.map(\.0.path) == ["Sets/Docs"])
        #expect(model.restoreState == .done(target))
    }

    @Test func aFolderOrFileRestoresFromWhereTheOwnerIs() async throws {
        let fake = FakeArchive()
        let (model, _, _) = try make(fake)
        await model.open("p")
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("out")
        await model.restoreLatest(nil) { _ in target }
        await model.restoreLatest(BackupItem(name: "f.txt", isFolder: false, size: 1)) { _ in target }
        #expect(fake.restored.map(\.0.path) == ["Sets/Docs/p", "Sets/Docs/p/f.txt"])
    }

    @Test func aFolderHasTheSameGuardAsAFile() async throws {
        let fake = FakeArchive()
        let (model, _, _) = try make(fake)
        await model.restoreLatest(nil) { [source] _ in source }
        #expect(fake.restored.isEmpty)
        guard case .failed = model.restoreState else { Issue.record("expected failed"); return }
    }

    @Test func aWholeRunRestoresFromItsStampFolder() async throws {
        let fake = FakeArchive()
        let (model, _, _) = try make(fake)
        let file = ArchiveEntry(id: "x", setName: "Docs", stamp: Date(), path: "Archive/Docs/2026-11-04T10-00-30/p/a.txt", size: 1)
        await model.restoreRun(of: file) { _ in FileManager.default.temporaryDirectory.appendingPathComponent("run") }
        #expect(fake.restored.map(\.0.path) == ["Archive/Docs/2026-11-04T10-00-30"])
    }

    /// The save panel asked "Replace?" and the owner said yes, so saying "try again" would be a lie.
    @Test func aFileTheSavePanelReplacesIsReplaced() async throws {
        let fake = FakeArchive(); fake.entries = [entry("x", day: 1)]
        let (model, _, _) = try make(fake)
        await model.reload()
        let existing = FileManager.default.temporaryDirectory.appendingPathComponent("mirror-existing-\(UUID().uuidString).txt")
        try "mine".write(to: existing, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: existing) }
        await model.restore(fake.entries[0]) { _ in existing }
        await model.restore(fake.entries[0]) { _ in existing.deletingLastPathComponent().appendingPathComponent("mirror-new-\(UUID().uuidString).txt") }
        #expect(fake.replacing == [true, false])
    }

    @Test func anAgentRefusalIsSaidForWhatItIs() async throws {
        let fake = FakeArchive(); fake.restoreError = RestoreError.destinationNotEmpty("/x")
        let (model, _, _) = try make(fake)
        await model.restoreLatest(nil) { _ in FileManager.default.temporaryDirectory.appendingPathComponent("out") }
        #expect(model.restoreState == .failed(SetupFailureText.message(for: RestoreError.destinationNotEmpty("/x"))))
    }

    @Test func aLatestBackupThatCantBeReadIsSaid() async throws {
        let fake = FakeArchive(); fake.browseError = URLError(.notConnectedToInternet)
        let (model, _, _) = try make(fake)
        await model.reloadLatest()
        guard case .failed = model.latest else { Issue.record("expected failed"); return }
    }

    @Test func changingTheSetGoesBackToTheTop() async throws {
        let (model, _, _) = try make(FakeArchive())
        await model.open("p")
        model.resetFolder()
        #expect(model.folder.isEmpty)
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
