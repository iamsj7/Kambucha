import Testing
import Foundation
import KambuchaCore
@testable import Kambucha

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
    let source = URL(fileURLWithPath: "/tmp/kambucha-test-source-\(UUID().uuidString)")
    fileprivate func make(_ fake: FakeArchive) throws -> (ArchiveModel, BackupSet, Destination) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kambucha-test-\(UUID().uuidString)")
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

    /// This pinned grouping by day. The archive now groups by run, and that's computed once when the listing is read.
    @Test func groupsNewestRunFirst() async throws {
        let fake = FakeArchive()
        func file(_ name: String, _ stamp: String, _ day: Int) -> ArchiveEntry {
            ArchiveEntry(id: "\(stamp)/\(name)", setName: "Docs", stamp: Date(timeIntervalSince1970: 1_800_000_000 + Double(day) * 86_400),
                         path: "Archive/Docs/\(stamp)/\(name)", size: 10)
        }
        fake.entries = [file("old.txt", "2027-01-15T08-00-00", 0), file("a.txt", "2027-01-20T08-00-00", 5), file("p/b.txt", "2027-01-20T08-00-00", 5)]
        let (model, _, _) = try make(fake)
        await model.reload()
        guard case .loaded(let runs) = model.phase else { Issue.record("expected loaded"); return }
        #expect(runs.map(\.fileCount) == [2, 1])
        #expect(runs[0].root.files.map(\.path) == ["Archive/Docs/2027-01-20T08-00-00/a.txt"])
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

    @Test func aFileRestoresIntoItsOriginalFolder() async throws {
        let fake = FakeArchive(); fake.entries = [entry("x", day: 1)]
        let (model, _, _) = try make(fake)
        await model.reload()
        let inside = source.appendingPathComponent("a/x.txt")   // the original's own path
        await model.restore(fake.entries[0]) { _ in inside }
        #expect(fake.restored.map(\.1) == [inside])
        #expect(model.restoreState == .done(inside))
    }

    @Test func thePanelOpensWhereTheFileWas() async throws {
        let fake = FakeArchive()
        let (model, set, _) = try make(fake)
        let notes = source.appendingPathComponent("notes")
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: source) }
        func file(_ path: String) -> ArchiveEntry { ArchiveEntry(id: path, setName: "Docs", stamp: .now, path: path, size: 1) }
        let stamp = "2026-11-05T06-52-32"
        func same(_ a: URL?, _ b: URL) -> Bool { a?.standardizedFileURL.path == b.standardizedFileURL.path }
        #expect(same(model.startFolder(for: file("Archive/Docs/\(stamp)/notes/a.txt")), notes))
        #expect(same(model.startFolder(for: file("Sets/Docs/notes/a.txt")), notes))
        #expect(same(model.startFolder(for: file("Archive/Docs/\(stamp)/a.txt")), source))
        // Its folder went too, so the nearest one left.
        #expect(same(model.startFolder(for: file("Archive/Docs/\(stamp)/notes/gone/deep/a.txt")), notes))
        #expect(RestoreTarget.original(of: "Archive/Docs/\(stamp)/notes/a.txt", in: set)?.path == notes.appendingPathComponent("a.txt").path)
        var folder = file("Archive/Docs/\(stamp)"); folder.isFolder = true
        #expect(model.startFolder(for: folder) == nil)
    }

    @Test func thePanelFallsBackWhenTheSourceIsGone() async throws {
        let (model, _, _) = try make(FakeArchive())
        #expect(model.startFolder(for: ArchiveEntry(id: "x", setName: "Docs", stamp: .now, path: "Sets/Docs/a.txt", size: 1)) == nil)
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

    @Test func aFolderCannotGoInsideTheSource() async throws {
        let fake = FakeArchive()
        let (model, _, _) = try make(fake)
        await model.restoreLatest(nil) { [source] _ in source }
        await model.restoreLatest(BackupItem(name: "p", isFolder: true, size: 0)) { [source] _ in source.appendingPathComponent("p") }
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
        let existing = FileManager.default.temporaryDirectory.appendingPathComponent("kambucha-existing-\(UUID().uuidString).txt")
        try "mine".write(to: existing, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: existing) }
        await model.restore(fake.entries[0]) { _ in existing }
        await model.restore(fake.entries[0]) { _ in existing.deletingLastPathComponent().appendingPathComponent("kambucha-new-\(UUID().uuidString).txt") }
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
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kambucha-test-\(UUID().uuidString)")
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

/// Two sets on two destinations, one of them shared, with a fake that behaves as the agent does.
private final class Shelf: ArchiveProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var _listCalls: [PairID] = []
    private var _restored: [(path: String, set: UUID, destination: UUID, to: URL)] = []
    private var running = 0, _peak = 0
    var listings: [PairID: [ArchiveEntry]] = [:]
    var failures: [UUID: any Error] = [:]        // by destination
    var busyTimes = 0
    /// Refuses a second command the way the agent's lock does, rather than waiting.
    var exclusive = false
    var pause: Duration = .zero
    var folders: [String: [BackupItem]] = [:]
    var browseFailures: Set<String> = []
    /// By path, as a restore or a browse of that path stops until `release`.
    private var held: Set<String> = []
    private var _started: [String] = []
    private var _restoreFailures: [String: any Error] = [:]

    var started: [String] { lock.withLock { _started } }
    func hold(_ path: String) { lock.withLock { _ = held.insert(path) } }
    func release(_ path: String) { lock.withLock { _ = held.remove(path) } }
    func failRestore(of path: String, with error: (any Error)?) { lock.withLock { _restoreFailures[path] = error } }
    private func start(_ path: String) async throws {
        lock.withLock { _started.append(path) }
        while lock.withLock({ held.contains(path) }) { try await Task.sleep(for: .milliseconds(2)) }
    }

    var listCalls: [PairID] { lock.withLock { _listCalls } }
    var restored: [(path: String, set: UUID, destination: UUID, to: URL)] { lock.withLock { _restored } }
    var peak: Int { lock.withLock { _peak } }

    private func enter() throws {
        try lock.withLock {
            if exclusive, running > 0 { throw AgentFailure.busy }
            running += 1; _peak = max(_peak, running)
        }
    }
    private func leave() { lock.withLock { running -= 1 } }

    func list(set: BackupSet, destination: Destination) async throws -> [ArchiveEntry] {
        try enter(); defer { leave() }
        let pair = PairID(set: set.id, destination: destination.id)
        let busy = lock.withLock { () -> Bool in
            _listCalls.append(pair)
            if busyTimes > 0 { busyTimes -= 1; return true }
            return false
        }
        if pause > .zero { try await Task.sleep(for: pause) }
        if busy { throw AgentFailure.busy }
        if let failure = lock.withLock({ failures[destination.id] }) { throw failure }
        return lock.withLock { listings[pair] ?? [] }
    }
    func browse(path: String, set: BackupSet, destination: Destination) async throws -> [BackupItem] {
        try enter(); defer { leave() }
        try await start(path)
        if browseFailures.contains(path) { throw URLError(.notConnectedToInternet) }
        return folders[path] ?? []
    }
    func restore(entry: ArchiveEntry, set: BackupSet, destination: Destination, to: URL, replacing: Bool) async throws {
        try enter(); defer { leave() }
        try await start(entry.path)
        if let failure = lock.withLock({ _restoreFailures[entry.path] }) { throw failure }
        lock.withLock { _restored.append((entry.path, set.id, destination.id, to)) }
    }
}

@MainActor
struct ArchiveSearchModelTests {
    let cloud = Destination(name: "Google Drive", kind: .googleDrive)
    let drive = Destination(name: "Backup SSD", kind: .externalDrive)
    let docsSource = URL(fileURLWithPath: "/tmp/kambucha-test-docs-\(UUID().uuidString)")
    let photosSource = URL(fileURLWithPath: "/tmp/kambucha-test-photos-\(UUID().uuidString)")
    var docs: BackupSet { BackupSet(id: UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!, name: "Docs", source: docsSource, destinationIDs: [cloud.id]) }
    var photos: BackupSet { BackupSet(id: UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!, name: "Photos", source: photosSource, destinationIDs: [cloud.id, drive.id]) }

    fileprivate func make(_ shelf: Shelf, agentLimit: Int = 1, debounce: Duration = .zero) throws -> ArchiveModel {
        let store = ConfigStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("kambucha-test-\(UUID().uuidString)"))
        try store.saveSets([docs, photos]); try store.saveDestinations([cloud, drive])
        let model = ArchiveModel(provider: shelf, store: store, agentLimit: agentLimit, debounce: debounce, busyWaits: [.zero, .zero])
        model.loadConfig()
        return model
    }
    func file(_ set: BackupSet, _ rel: String, stamp: String = "2026-11-04T10-00-30") -> ArchiveEntry {
        ArchiveEntry(id: "\(set.name)/\(stamp)/\(rel)", setName: set.name, stamp: Date(timeIntervalSince1970: 1_800_000_000),
                     path: "Archive/\(set.name)/\(stamp)/\(rel)", size: 5)
    }
    func pair(_ set: BackupSet, _ dest: Destination) -> PairID { PairID(set: set.id, destination: dest.id) }

    /// Waits for the search on screen to finish, as a person would.
    func settled(_ model: ArchiveModel, for query: String? = nil) async {
        let text = query ?? model.query
        for _ in 0..<2_000 {
            if model.results.query == text, !model.results.isReading { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("search didn't settle")
    }

    @Test func aSearchFindsFilesInEverySetAndDestination() async throws {
        let shelf = Shelf()
        shelf.listings = [pair(docs, cloud): [file(docs, "tax/plan.pdf")], pair(photos, cloud): [file(photos, "plan.jpg")],
                          pair(photos, drive): [file(photos, "plan.jpg"), file(photos, "other.jpg")]]
        let model = try make(shelf)
        model.query = "plan"
        await settled(model)
        #expect(Set(model.results.matches.hits.map(\.source.pair)) == [pair(docs, cloud), pair(photos, cloud), pair(photos, drive)])
        #expect(model.results.matches.total == 3)
        #expect(Set(model.results.matches.hits.map(\.id)).count == 3)   // the same file at two destinations is two results
    }

    @Test func typingNeverReadsAListingTwice() async throws {
        let shelf = Shelf()
        shelf.failures = [drive.id: AgentFailure.driveNotConnected]
        let model = try make(shelf)
        for text in ["p", "pl", "pla", "plan", "plan ", "plan x"] {
            model.query = text
            await settled(model)
        }
        #expect(shelf.listCalls.count == 3)   // the failure too: an unplugged drive isn't tried on each keystroke
    }

    @Test func aDebounceSkipsWhatsTypedInBetween() async throws {
        let shelf = Shelf()
        let model = try make(shelf, debounce: .milliseconds(50))
        model.query = "p"; model.query = "pl"; model.query = "pla"
        #expect(shelf.listCalls.isEmpty)
        await settled(model, for: "pla")
    }

    @Test func clearingTheFieldEndsTheSearch() async throws {
        let shelf = Shelf()
        let model = try make(shelf)
        model.query = "plan"
        await settled(model)
        model.query = "  "
        #expect(!model.isSearching)
        #expect(model.results == ArchiveResults())
    }

    @Test func nothingReadIsntToldAsNothingFound() async throws {
        let shelf = Shelf()
        shelf.failures = [cloud.id: RcloneSessionError.notSignedIn, drive.id: AgentFailure.driveNotConnected]
        let model = try make(shelf)
        model.query = "plan"
        await settled(model)
        #expect(model.results.nothingFoundNote == "None of the archive could be searched.")
    }

    @Test func aLongResultSaysItsCut() {
        var results = ArchiveResults()
        results.matches.total = 34_211
        results.matches.hits = Array(repeating: ArchiveHit(entry: ArchiveEntry(id: "x", setName: "D", stamp: .now, path: "a", size: 1),
                                                           source: ArchiveSource(set: docs, destination: cloud)), count: 1_000)
        #expect(results.status == "34,211 files found. Showing the first 1,000, so type more to narrow it down.")
    }

    @Test func readsAreBounded() async throws {
        let shelf = Shelf(); shelf.pause = .milliseconds(20)
        let model = try make(shelf, agentLimit: 2)
        model.query = "plan"
        await settled(model)
        #expect(shelf.peak == 2)
        #expect(shelf.listCalls.count == 3)
    }

    /// The real agent refuses a second command outright, so running two at once would lose one.
    @Test func withTheAgentsLockEveryListingStillGetsRead() async throws {
        let shelf = Shelf(); shelf.exclusive = true; shelf.pause = .milliseconds(5)
        shelf.listings = [pair(docs, cloud): [file(docs, "plan.pdf")], pair(photos, cloud): [file(photos, "plan.jpg")],
                          pair(photos, drive): [file(photos, "plan.jpg")]]
        let model = try make(shelf)
        model.query = "plan"
        await settled(model)
        #expect(model.results.unreadable.isEmpty)
        #expect(model.results.matches.total == 3)
    }

    @Test func aRestoreGoesAheadOfListingsStillWaiting() async throws {
        let shelf = Shelf(); shelf.exclusive = true; shelf.pause = .milliseconds(30)
        shelf.listings = [pair(docs, cloud): [file(docs, "plan.pdf")]]
        let model = try make(shelf, debounce: .zero)
        model.query = "plan"
        for _ in 0..<400 where model.results.matches.hits.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        let hit = try #require(model.results.matches.hits.first)
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("restored-\(UUID().uuidString).pdf")
        await model.restore(hit) { _ in target }
        #expect(model.restoreState == .done(target))   // not refused for clashing with a listing
        await settled(model)
    }

    @Test func somethingElseHoldingTheAgentIsWaitedOut() async throws {
        let shelf = Shelf(); shelf.busyTimes = 2
        shelf.listings = [pair(docs, cloud): [file(docs, "plan.pdf")]]
        let model = try make(shelf)
        await model.reload()
        guard case .loaded(let runs) = model.phase else { Issue.record("expected loaded"); return }
        #expect(runs.count == 1)
    }

    @Test func aDestinationOutOfReachDoesntStopTheRest() async throws {
        let shelf = Shelf()
        shelf.failures = [drive.id: AgentFailure.driveNotConnected]
        shelf.listings = [pair(docs, cloud): [file(docs, "plan.pdf")], pair(photos, drive): [file(photos, "plan.jpg")]]
        let model = try make(shelf)
        model.query = "plan"
        await settled(model)
        #expect(model.results.matches.hits.map(\.source.setName) == ["Docs"])
        #expect(model.results.unreadable == [ArchiveUnreadable(destinationID: drive.id, destinationName: "Backup SSD", failure: .driveNotConnected, sets: ["Photos"])])
        #expect(model.results.status == "1 file found")
    }

    @Test func anExpiredSignInIsSaidAndCanBeRetried() async throws {
        let shelf = Shelf()
        shelf.failures = [cloud.id: RcloneSessionError.notSignedIn]
        shelf.listings = [pair(docs, cloud): [file(docs, "plan.pdf")]]
        let model = try make(shelf)
        model.query = "plan"
        await settled(model)
        #expect(model.results.matches.hits.isEmpty)
        #expect(model.results.unreadable.first?.failure == .signInExpired)
        #expect(model.results.unreadable.first?.sets == ["Docs", "Photos"])
        #expect(model.results.nothingFoundNote == "Nothing found in the rest of the archive.")   // the drive was read

        shelf.failures = [:]
        let before = shelf.listCalls.count
        model.retryUnreadable()
        for _ in 0..<400 where !model.results.unreadable.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        await settled(model)
        #expect(model.results.matches.total == 1)
        #expect(shelf.listCalls.count == before + 2)   // only what had failed
    }

    /// `restore` reads the pickers for what's on screen. A result from elsewhere must never go through them.
    @Test func aResultRestoresFromItsOwnSetAndDestination() async throws {
        let shelf = Shelf()
        shelf.listings = [pair(photos, drive): [file(photos, "beach/plan.jpg")]]
        let model = try make(shelf)
        #expect(model.selectedSet?.id == docs.id && model.selectedDestination?.id == cloud.id)
        model.query = "plan"
        await settled(model)
        let hit = try #require(model.results.matches.hits.first)
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("r-\(UUID().uuidString).jpg")
        await model.restore(hit) { _ in target }
        #expect(shelf.restored.count == 1)
        #expect(shelf.restored[0].set == photos.id && shelf.restored[0].destination == drive.id)
        #expect(shelf.restored[0].path == "Archive/Photos/2026-11-04T10-00-30/beach/plan.jpg")
        #expect(model.selection.set == docs.id)
    }

    @Test func aResultsPanelOpensInItsOwnSetsFolder() async throws {
        let shelf = Shelf()
        let beach = photosSource.appendingPathComponent("beach")
        try FileManager.default.createDirectory(at: beach, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: docsSource.appendingPathComponent("beach"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: photosSource); try? FileManager.default.removeItem(at: docsSource) }
        shelf.listings = [pair(photos, drive): [file(photos, "beach/plan.jpg")]]
        let model = try make(shelf)
        model.query = "plan"
        await settled(model)
        let hit = try #require(model.results.matches.hits.first)
        #expect(model.startFolder(for: hit.entry, of: hit)?.standardizedFileURL.path == beach.standardizedFileURL.path)
    }

    /// The whole run is a folder, and the guard would refuse the place the file came from.
    @Test func aResultsWholeRunPanelDoesntOpenInsideTheSource() async throws {
        let shelf = Shelf()
        let beach = photosSource.appendingPathComponent("beach")
        try FileManager.default.createDirectory(at: beach, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: photosSource) }
        shelf.listings = [pair(photos, drive): [file(photos, "beach/plan.jpg")]]
        let model = try make(shelf)
        model.query = "plan"
        await settled(model)
        let hit = try #require(model.results.matches.hits.first)
        var asked: ArchiveEntry?
        await model.restoreRun(of: hit) { asked = $0; return nil }
        let run = try #require(asked)
        #expect(run.isFolder)
        #expect(model.startFolder(for: run, of: hit) == nil)
    }

    @Test func aResultCanGoBackIntoItsOriginalFolder() async throws {
        let shelf = Shelf()
        shelf.listings = [pair(photos, drive): [file(photos, "plan.jpg")]]
        let model = try make(shelf)
        model.query = "plan"
        await settled(model)
        let hit = try #require(model.results.matches.hits.first)
        let inside = photosSource.appendingPathComponent("plan.jpg")
        await model.restore(hit) { _ in inside }
        #expect(shelf.restored.map(\.to) == [inside])
    }

    @Test func aResultsWholeRunUsesItsOwnSetAndTheFolderGuard() async throws {
        let shelf = Shelf()
        shelf.listings = [pair(photos, drive): [file(photos, "beach/plan.jpg")]]
        let model = try make(shelf)
        model.query = "plan"
        await settled(model)
        let hit = try #require(model.results.matches.hits.first)
        await model.restoreRun(of: hit) { [docsSource] _ in docsSource.appendingPathComponent("x") }   // any set's folder counts
        #expect(shelf.restored.isEmpty)
        guard case .failed = model.restoreState else { Issue.record("expected failed"); return }
        await model.restoreRun(of: hit) { _ in FileManager.default.temporaryDirectory.appendingPathComponent("run-\(UUID().uuidString)") }
        #expect(shelf.restored.map(\.path) == ["Archive/Photos/2026-11-04T10-00-30"])
        #expect(shelf.restored.first?.set == photos.id && shelf.restored.first?.destination == drive.id)
    }

    @Test func aFolderOfARunRestoresAsAFolderBehindTheGuard() async throws {
        let shelf = Shelf()
        shelf.listings = [pair(docs, cloud): [file(docs, "tax/2026/plan.pdf")]]
        let model = try make(shelf)
        await model.reload()
        guard case .loaded(let runs) = model.phase else { Issue.record("expected loaded"); return }
        let run = try #require(runs.first)
        let tax = try #require(run.root.folders.first)
        var asked: [ArchiveEntry] = []
        await model.restore(folder: tax, of: run) { [photosSource] in asked.append($0); return photosSource.appendingPathComponent("tax") }
        #expect(shelf.restored.isEmpty)
        guard case .failed = model.restoreState else { Issue.record("expected failed"); return }
        await model.restore(folder: tax, of: run) { _ in FileManager.default.temporaryDirectory.appendingPathComponent("tax-\(UUID().uuidString)") }
        #expect(shelf.restored.map(\.path) == ["Archive/Docs/2026-11-04T10-00-30/tax"])
        #expect(asked.first?.isFolder == true)
        #expect(model.startFolder(for: asked[0]) == nil)
    }

    @Test func aWholeRunRestoresFromItsGroup() async throws {
        let shelf = Shelf()
        shelf.listings = [pair(docs, cloud): [file(docs, "tax/plan.pdf")]]
        let model = try make(shelf)
        await model.reload()
        guard case .loaded(let runs) = model.phase else { Issue.record("expected loaded"); return }
        await model.restoreRun(runs[0]) { _ in FileManager.default.temporaryDirectory.appendingPathComponent("run-\(UUID().uuidString)") }
        #expect(shelf.restored.map(\.path) == ["Archive/Docs/2026-11-04T10-00-30"])
    }

    @Test func aListingReadForSearchIsntReadAgainForThePickers() async throws {
        let shelf = Shelf()
        let model = try make(shelf)
        model.query = "plan"
        await settled(model)
        await model.loadSelection()
        #expect(shelf.listCalls.count == 3)
        await model.reload()   // the way to ask for it again
        #expect(shelf.listCalls.count == 4)
    }

    @Test func leavingTheScreenForgetsWhatWasRead() async throws {
        let shelf = Shelf()
        shelf.listings = [pair(docs, cloud): [file(docs, "plan.pdf")]]
        let model = try make(shelf)
        await model.loadSelection()
        model.forgetListings()
        shelf.listings[pair(docs, cloud)] = [file(docs, "plan.pdf"), file(docs, "new.pdf")]   // a backup ran meanwhile
        await model.loadSelection()
        guard case .loaded(let runs) = model.phase else { Issue.record("expected loaded"); return }
        #expect(runs[0].fileCount == 2)
    }

    @Test func reloadingReadsEverythingAgain() async throws {
        let shelf = Shelf()
        let model = try make(shelf)
        model.query = "plan"
        await settled(model)
        await model.reloadAll()
        await settled(model)
        #expect(shelf.listCalls.count == 6)
    }

    /// Measured, not pinned tightly: the point is that the main actor keeps turning while a big listing is read.
    // MARK: Moving the selection

    func until(_ condition: () -> Bool) async {
        for _ in 0..<2_000 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        Issue.record("never happened")
    }

    /// A row's name is joined to the selected set, so one left from the last set would restore a different file.
    @Test func changingTheSetDropsTheLatestRowsInTheSameStep() async throws {
        let shelf = Shelf()
        let report = BackupItem(name: "report.docx", isFolder: false, size: 111)
        shelf.folders = ["Sets/Docs": [report]]
        let model = try make(shelf)
        model.mode = .latest
        await model.showSelection()
        #expect(model.latest == .loaded([report]))
        shelf.hold("Sets/Photos")
        model.selection.set = photos.id
        #expect(model.latest == .idle)
        let moving = Task { await model.showSelection() }
        await until { shelf.started.contains("Sets/Photos") }
        #expect(model.latest == .loading)
        shelf.release("Sets/Photos")
        await moving.value
        #expect(model.latest == .loaded([]))
    }

    @Test func changingTheDestinationDropsTheLatestRowsInTheSameStep() async throws {
        let shelf = Shelf()
        shelf.folders = ["Sets/Photos": [BackupItem(name: "beach.jpg", isFolder: false, size: 1)]]
        let model = try make(shelf)
        model.selection = ArchiveSelection(set: photos.id, destination: cloud.id)
        model.mode = .latest
        await model.showSelection()
        model.selection.destination = drive.id
        #expect(model.latest == .idle)
    }

    @Test func changingTheSetDropsOlderVersionsInTheSameStep() async throws {
        let shelf = Shelf()
        shelf.listings = [pair(docs, cloud): [file(docs, "plan.pdf")]]
        let model = try make(shelf)
        await model.showSelection()
        guard case .loaded = model.phase else { Issue.record("expected loaded"); return }
        model.selection.set = photos.id
        #expect(model.phase == .idle)
    }

    /// A listing can wait minutes behind a search, and this pane has no use for one.
    @Test func theLatestBackupReadsNoListing() async throws {
        let shelf = Shelf()
        let model = try make(shelf)
        model.mode = .latest
        await model.showSelection()
        #expect(shelf.listCalls.isEmpty)
    }

    @Test func goingBackToOlderVersionsShowsTheSetNowSelected() async throws {
        let shelf = Shelf()
        shelf.listings = [pair(photos, cloud): [file(photos, "beach.jpg")]]
        let model = try make(shelf)
        model.mode = .latest
        model.selection.set = photos.id
        await model.showSelection()
        model.mode = .archive
        await model.showPane()
        guard case .loaded(let runs) = model.phase else { Issue.record("expected loaded"); return }
        #expect(runs.map(\.fileCount) == [1])
    }

    @Test func aFailedReadOfTheLastSetIsntShownUnderTheNewOne() async throws {
        let shelf = Shelf()
        shelf.browseFailures = ["Sets/Docs"]
        shelf.hold("Sets/Docs")
        let model = try make(shelf)
        model.mode = .latest
        let old = Task { await model.reloadLatest() }
        await until { shelf.started.contains("Sets/Docs") }
        model.selection.set = photos.id
        shelf.release("Sets/Docs")
        await old.value
        #expect(model.latest == .idle)
    }

    // MARK: Several restores at once

    /// Counts panels answered, so a test knows a restore has been asked for.
    @MainActor final class Panels {
        var answered = 0
        let tmp = FileManager.default.temporaryDirectory
        func target(_ name: String) -> URL { tmp.appendingPathComponent("\(UUID().uuidString)-\(name)") }
    }

    /// Starts a restore of `entry` and returns once it has left the panel.
    func begin(_ entry: ArchiveEntry, on model: ArchiveModel, to target: URL, _ panels: Panels) async -> Task<Void, Never> {
        let before = panels.answered
        let task = Task { await model.restore(entry) { _ in panels.answered += 1; return target } }
        await until { panels.answered > before }
        return task
    }

    @Test func aFailureIsntOverwrittenByARestoreThatSucceeds() async throws {
        let shelf = Shelf(), panels = Panels()
        let a = file(docs, "a.txt"), b = file(docs, "b.txt")
        shelf.hold(a.path)
        shelf.failRestore(of: a.path, with: URLError(.timedOut))
        let model = try make(shelf)
        let first = await begin(a, on: model, to: panels.target("a"), panels)
        let second = await begin(b, on: model, to: panels.target("b"), panels)
        shelf.release(a.path)
        await first.value; await second.value
        guard case .failed(let why) = model.restoreState else { Issue.record("expected failed, got \(model.restoreState)"); return }
        #expect(why.contains("a.txt"))
        #expect(why.contains("1 other was restored"))
    }

    @Test func restoredWaitsUntilNothingIsLeft() async throws {
        let shelf = Shelf(), panels = Panels()
        let a = file(docs, "a.txt"), b = file(docs, "b.txt")
        shelf.hold(a.path); shelf.hold(b.path)
        let model = try make(shelf)
        let target = panels.target("b")
        let first = await begin(a, on: model, to: panels.target("a"), panels)
        let second = await begin(b, on: model, to: target, panels)
        #expect(model.restoreState == .restoring("2 items"))
        shelf.release(a.path)
        await first.value
        #expect(model.restoreState == .restoring("b.txt"))
        shelf.release(b.path)
        await second.value
        #expect(model.restoreState == .done(target))
    }

    @Test func aCancelledPanelLeavesARunningRestoreOnShow() async throws {
        let shelf = Shelf(), panels = Panels()
        let a = file(docs, "a.txt")
        shelf.hold(a.path)
        let model = try make(shelf)
        let first = await begin(a, on: model, to: panels.target("a"), panels)
        await model.restore(file(docs, "b.txt")) { _ in nil }
        #expect(model.restoreState == .restoring("a.txt"))
        shelf.release(a.path)
        await first.value
    }

    @Test func aFailureStaysUntilItsDismissed() async throws {
        let shelf = Shelf(), panels = Panels()
        let a = file(docs, "a.txt")
        shelf.failRestore(of: a.path, with: URLError(.timedOut))
        let model = try make(shelf)
        await model.restore(a) { _ in panels.target("a") }
        guard case .failed = model.restoreState else { Issue.record("expected failed"); return }
        await model.restore(file(docs, "b.txt")) { _ in nil }
        guard case .failed = model.restoreState else { Issue.record("a cancelled panel cleared the failure"); return }
        await model.restore(file(docs, "c.txt")) { _ in panels.target("c") }
        guard case .failed = model.restoreState else { Issue.record("a later restore cleared the failure"); return }
        model.dismissRestoreState()
        #expect(model.restoreState == .idle)
    }

    @Test func everyFailureIsKept() async throws {
        let shelf = Shelf(), panels = Panels()
        let a = file(docs, "a.txt"), b = file(docs, "b.txt")
        shelf.failRestore(of: a.path, with: URLError(.timedOut))
        shelf.failRestore(of: b.path, with: RestoreError.destinationNotEmpty("/x"))
        let model = try make(shelf)
        await model.restore(a) { _ in panels.target("a") }
        await model.restore(b) { _ in panels.target("b") }
        guard case .failed(let why) = model.restoreState else { Issue.record("expected failed"); return }
        #expect(why.contains("a.txt") && why.contains("b.txt"))
    }

    @Test func tryingAFileAgainClearsItsFailure() async throws {
        let shelf = Shelf(), panels = Panels()
        let a = file(docs, "a.txt")
        shelf.failRestore(of: a.path, with: URLError(.timedOut))
        let model = try make(shelf)
        await model.restore(a) { _ in panels.target("a") }
        shelf.failRestore(of: a.path, with: nil)
        let target = panels.target("a")
        await model.restore(a) { _ in target }
        #expect(model.restoreState == .done(target))
    }

    // MARK: Reads that recover, and turns at the agent

    @Test func aReadThatRecoversThroughSearchClearsTheFailure() async throws {
        let shelf = Shelf()
        shelf.listings = [pair(docs, cloud): [file(docs, "plan.pdf")]]
        shelf.failures = [cloud.id: URLError(.notConnectedToInternet)]
        let model = try make(shelf)
        await model.reload()
        guard case .failed = model.phase else { Issue.record("expected failed"); return }
        model.query = "plan"
        await settled(model)
        shelf.failures = [:]
        model.retryUnreadable()
        await until { !model.results.matches.hits.isEmpty && !model.results.isReading }
        guard case .loaded = model.phase else { Issue.record("expected loaded, got \(model.phase)"); return }
    }

    /// The agent refuses a second command at once, and the test would end as "couldn't tell" with the Kit already typed.
    @Test func aRecoveryKitTestWaitsForTheListingBeforeIt() async throws {
        let shelf = Shelf(); shelf.exclusive = true; shelf.pause = .milliseconds(50)
        let model = try make(shelf)
        model.query = "plan"
        await until { !shelf.listCalls.isEmpty }
        let items = try await model.agentTurn { [docs, cloud] in try await shelf.browse(path: "Sets/Docs", set: docs, destination: cloud) }
        #expect(items.isEmpty)
        await settled(model)
    }

    @Test func aHugeListingDoesntHoldUpTheMainThread() async throws {
        let shelf = Shelf()
        shelf.listings[pair(docs, cloud)] = (0..<100_000).map { file(docs, "client-\($0 % 12)/module-\($0 % 40)/report-\($0).pdf", stamp: "2026-11-\(10 + $0 % 20)T10-00-30") }
        let model = try make(shelf)
        let load = Task { await model.reload() }
        var worst = Duration.zero, last = ContinuousClock.now
        while true {
            if case .loaded = model.phase { break }
            try await Task.sleep(for: .milliseconds(1))
            let now = ContinuousClock.now
            worst = max(worst, now - last); last = now
        }
        await load.value
        print("archive load: worst main-actor gap \(worst)")
        #expect(worst < .seconds(1))
    }
}
