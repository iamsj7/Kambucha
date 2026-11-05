import Testing
import Foundation
import MirrorCore
@testable import Mirror

private let a = UUID(), b = UUID(), c = UUID()

@Suite struct SidebarSelectionTests {
    private func after(_ start: SidebarSelection, _ new: Set<SidebarItem>) -> Set<SidebarItem> {
        var s = start; s.change(to: new); return s.items
    }

    @Test func startsOnOverview() {
        #expect(SidebarSelection().content(live: []) == .one(.overview))
    }

    @Test func oneItemOfAnyKindIsOneItem() {
        for item in [SidebarItem.overview, .coverage, .set(a), .destination(a), .archive, .activity, .settings] {
            var s = SidebarSelection()
            s.change(to: [item])
            #expect(s.content(live: [a]) == .one(item))
        }
    }

    @Test func nothingSelectedShowsOverview() {
        var s = SidebarSelection(.set(a))
        s.change(to: [])
        #expect(s.content(live: [a]) == .one(.overview))
    }

    @Test func severalSetsStayTogether() {
        let s = SidebarSelection(sets: [a, b])
        #expect(s.content(live: [a, b, c]) == .several([a, b]))
        #expect(after(s, [.set(a), .set(b), .set(c)]).count == 3)
    }

    @Test func commandClickingSomethingElseMovesThere() {
        #expect(after(SidebarSelection(sets: [a, b]), [.set(a), .set(b), .archive]) == [.archive])
        #expect(after(SidebarSelection(.archive), [.archive, .settings]) == [.settings])
        #expect(after(SidebarSelection(.set(a)), [.set(a), .destination(b)]) == [.destination(b)])
    }

    @Test func commandClickingASetFromElsewhereLeavesThatBehind() {
        #expect(after(SidebarSelection(.coverage), [.coverage, .set(a)]) == [.set(a)])
    }

    @Test func aShiftClickAcrossSectionsKeepsItsSets() {
        #expect(after(SidebarSelection(.set(a)), [.set(a), .set(b), .destination(c), .archive]) == [.set(a), .set(b)])
    }

    @Test func aRangeWithNoSetsEndsOnOneItem() {
        #expect(after(SidebarSelection(.archive), [.archive, .activity, .settings]) == [.archive])
    }

    @Test func setsThatWentLeaveTheSelection() {
        let s = SidebarSelection(sets: [a, b, c])
        #expect(s.content(live: [a, b]) == .several([a, b]))
        #expect(s.content(live: [a]) == .one(.set(a)))
        #expect(s.content(live: []) == .one(.overview))
    }

    @Test func aSingleSetThatWentStillSaysSo() {
        #expect(SidebarSelection(.set(a)).content(live: []) == .one(.set(a)))
    }

    @Test func aContextMenuOnSomethingElseHasNoSets() {
        #expect(SidebarSelection.setIDs(in: [.overview, .destination(a)]).isEmpty)
        #expect(SidebarSelection.setIDs(in: [.set(a), .archive]) == [a])
    }
}

@Suite struct CoveragePresentationTests {
    private let now = Date()

    @Test func everyStateHasWordsAndASymbol() {
        let cells: [CoverageCell] = [.off, .confirmDisk, .saveRecoveryKit, .status(.backedUp(last: now, files: 3)), .status(.uploading(2)),
                                     .status(.running), .status(.held(1)), .status(.paused), .status(.unfinished), .status(.notAccepted(1)),
                                     .status(.waitingForDownload(1)), .status(.attention("Sign-in expired")),
                                     .status(.driveNotConnected(name: "SSD", last: nil))]
        for cell in cells {
            let p = CoveragePresentation(cell)
            #expect(!p.symbol.isEmpty && !p.short.isEmpty && !p.detail.isEmpty)
        }
    }

    @Test func theBriefsFiveStatesReadAsThemselves() {
        #expect(CoveragePresentation(.status(.backedUp(last: now, files: 3))).short == "Backed Up")
        #expect(CoveragePresentation(.status(.uploading(1_240))).short == "Uploading \(1_240.formatted())")
        #expect(CoveragePresentation(.status(.attention("Sign-in expired"))).short == "Needs Attention")
        #expect(CoveragePresentation(.status(.driveNotConnected(name: "SSD", last: nil))).short == "Not Connected")
        #expect(CoveragePresentation(.off).short == "Off")
    }

    @Test func theDetailSaysWhy() {
        #expect(CoveragePresentation(.status(.attention("Sign-in expired"))).detail == "Sign-in expired")
        #expect(CoveragePresentation(.saveRecoveryKit).detail == "Save your Recovery Kit")
    }

    @Test func aPairAskingForAPreviewDoesNotRepeatTheSetName() {
        let p = CoveragePresentation(.status(.attention("Preview needed: Photos")))
        #expect(p.short == "Preview Needed" && p.detail == "Preview needed")
    }
}

private struct Vols: VolumeLocating {
    func mounted() -> [VolumeInfo] { [] }
}

@MainActor @Suite struct CoverageActionTests {
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("mirror-coverage-\(UUID().uuidString)")
    private let one = Destination(name: "One", kind: .iCloudFolder)
    private let two = Destination(name: "Two", kind: .iCloudFolder)

    private func model(_ sets: [BackupSet], destinations: [Destination]? = nil) throws -> AppModel {
        let store = ConfigStore(root: root)
        try store.saveDestinations(destinations ?? [one, two])
        try store.saveSets(sets)
        let transport = AgentProcessTransport(executable: URL(fileURLWithPath: "/dev/null"))
        let calls = AgentArchiveClient(transport: transport)
        return AppModel(support: root, services: AppServices(
            preview: LivePreviewProvider(binary: URL(fileURLWithPath: "/dev/null")), dryRun: AgentDeletionDryRun(client: calls), inspector: nil,
            volumes: Vols(), agent: AgentClient(executable: URL(fileURLWithPath: "/dev/null")), archive: AgentArchiveProvider(client: calls)))
    }

    private func set(_ name: String, _ ids: [UUID], accepted: Bool = true) -> BackupSet {
        var s = BackupSet(name: name, source: URL(fileURLWithPath: "/tmp/\(name)"), destinationIDs: ids)
        if accepted { s.acceptPreview() }
        return s
    }

    private func saved() throws -> [BackupSet] { try ConfigStore(root: root).loadSets() }

    @Test func turningOffKeepsThePreviewAndWhatIsKnownAboutTheCopy() throws {
        let s = set("A", [one.id, two.id])
        let pair = PairID(set: s.id, destination: two.id)
        let m = try model([s])
        var state = SetState(); state.lastFinished = Date(); state.lastFileCount = 7
        try ConfigStore(root: root).save(state, for: pair)

        m.setDestination(two.id, on: false, for: s.id)

        #expect(try saved()[0].destinationIDs == [one.id])
        #expect(try saved()[0].isPreviewAccepted)
        #expect(try ConfigStore(root: root).state(for: pair).lastFileCount == 7)

        m.setDestination(two.id, on: true, for: s.id)
        #expect(try saved()[0].destinationIDs == [one.id, two.id])
        #expect(m.states[pair]?.lastFileCount == 7)
    }

    @Test func aProblemEndsWithItsPairAsAfterASaveOnTheSetsPage() throws {
        let s = set("A", [one.id, two.id])
        let pair = PairID(set: s.id, destination: two.id)
        let m = try model([s])
        let center = ProblemCenter(root: root, notifier: NoNotifier())
        try center.store(.uploadStalled, pair: pair, setName: "A", detail: "")
        m.setDestination(two.id, on: false, for: s.id)
        #expect(try center.active().isEmpty)
    }

    @Test func aSetCanLoseItsLastDestinationAndThenAsksForAttention() throws {
        let s = set("A", [one.id])
        let m = try model([s])
        m.setDestination(one.id, on: false, for: s.id)
        #expect(try saved()[0].destinationIDs.isEmpty)
        #expect(m.rows[0].status == .attention("No destination chosen"))
    }

    @Test func aDestinationWithoutItsKitCanBeTurnedOnAndThenSaysSo() throws {
        let locked = Destination(name: "OneDrive", kind: .oneDrive)
        let s = set("A", [])
        let m = try model([s], destinations: [locked])
        m.setDestination(locked.id, on: true, for: s.id)
        #expect(try saved()[0].destinationIDs == [locked.id])
        let column = try #require(m.coverageColumns.first)
        #expect(m.coverageCell(try #require(m.set(s.id)), column) == .saveRecoveryKit)
    }

    @Test func coverageReadsTheSameJudgementAsTheRows() throws {
        let s = set("A", [one.id])
        let m = try model([s])
        var state = SetState(); state.pendingUploads = 5; state.lastFinished = Date()
        try ConfigStore(root: root).save(state, for: PairID(set: s.id, destination: one.id))
        m.reload()
        let column = try #require(m.coverageColumns.first)
        #expect(m.coverageCell(try #require(m.set(s.id)), column) == .status(m.rows[0].status))
    }

    @Test func pauseAndResumeTouchOnlyTheChosenSets() throws {
        let x = set("X", []), y = set("Y", []), z = set("Z", [])
        let m = try model([x, y, z])
        m.setPaused(true, sets: [x.id, y.id])
        #expect(try saved().map(\.isPaused) == [true, true, false])
        m.reload()
        m.setPaused(false, sets: [x.id])
        #expect(try saved().map(\.isPaused) == [false, true, false])
    }

    @Test func addingToADestinationSkipsSetsAlreadyThere() throws {
        let x = set("X", [one.id]), y = set("Y", [two.id]), z = set("Z", [])
        let m = try model([x, y, z])
        m.addDestination(two.id, to: [x.id, y.id])
        #expect(try saved().map(\.destinationIDs) == [[one.id, two.id], [two.id], []])
        #expect(try saved()[0].isPreviewAccepted)
    }

    @Test func removingSeveralRemovesThoseAndNoOthers() throws {
        let x = set("X", []), y = set("Y", []), z = set("Z", [])
        let m = try model([x, y, z])
        m.removeSets([x.id, z.id])
        #expect(try saved().map(\.id) == [y.id])
    }

    @Test func aBatchWithNothingToRunNamesWhyAndStartsNothing() throws {
        var paused = set("P", [one.id]); paused.isPaused = true
        let never = set("N", [one.id], accepted: false)
        let m = try model([paused, never])
        m.runNow(sets: [paused.id, never.id])
        #expect(m.lastError?.contains("N") == true && m.lastError?.contains("Paused, so left out: P.") == true)
        #expect(!m.isBackupActive)
    }
}
