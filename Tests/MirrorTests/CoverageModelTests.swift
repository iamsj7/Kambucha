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
        for item in [SidebarItem.overview, .coverage, .set(a), .destination(a), .archive, .activity] {
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
        #expect(after(SidebarSelection(.archive), [.archive, .activity]) == [.activity])
        #expect(after(SidebarSelection(.set(a)), [.set(a), .destination(b)]) == [.destination(b)])
    }

    @Test func commandClickingASetFromElsewhereLeavesThatBehind() {
        #expect(after(SidebarSelection(.coverage), [.coverage, .set(a)]) == [.set(a)])
    }

    @Test func aShiftClickAcrossSectionsKeepsItsSets() {
        #expect(after(SidebarSelection(.set(a)), [.set(a), .set(b), .destination(c), .archive]) == [.set(a), .set(b)])
    }

    @Test func aRangeWithNoSetsEndsOnOneItem() {
        #expect(after(SidebarSelection(.archive), [.archive, .activity, .coverage]) == [.archive])
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

    @Test func aContextMenuReachesOnlySetsTheFilterLeftShowing() {
        #expect(SidebarSelection.setIDs(in: [.set(a), .set(b), .set(c)], visible: [a]) == [a])
    }

    @Test func shiftingFromTheLastSetOntoTheNextRowKeepsTheSets() {
        var s = SidebarSelection(sets: [a, b])
        s.change(to: [.set(a), .set(b), .destination(c)], extending: true)
        #expect(s.items == [.set(a), .set(b)])
    }

    @Test func shiftingWithNoSetsInvolvedStaysOneItem() {
        var s = SidebarSelection(.archive)
        s.change(to: [.archive, .activity], extending: true)
        #expect(s.items == [.activity])
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

private extension OverallStatus {
    var isBackedUp: Bool { if case .backedUp = self { true } else { false } }
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
        m.reload()
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

    @Test func aSetCanLoseItsLastDestinationAndThenAsksForAttention() async throws {
        let s = set("A", [one.id])
        let m = try model([s])
        m.setDestination(one.id, on: false, for: s.id)
        #expect(try saved()[0].destinationIDs.isEmpty)
        try await until { m.rows[0].status == .attention("No destination chosen") }
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
        m.setPaused(false, sets: [x.id])
        #expect(try saved().map(\.isPaused) == [false, true, false])
    }

    @Test func anEditStraightAfterAPauseKeepsThePause() throws {
        let x = set("X", []), y = set("Y", [])
        let m = try model([x, y])
        m.setPaused(true, sets: [x.id, y.id])
        m.setDestination(one.id, on: true, for: x.id)
        #expect(try saved().map(\.isPaused) == [true, true])
        m.setPaused(false, sets: [x.id, y.id])
        m.setPaused(true)
        m.addDestination(two.id, to: [y.id])
        #expect(try saved().map(\.isPaused) == [true, true])
    }

    @Test func resumingAllLeavesSetsPausedOnTheirOwn() throws {
        let x = set("X", []), y = set("Y", [])
        let m = try model([x, y])
        m.setPaused(true, sets: [x.id])
        m.setPaused(true)
        #expect(m.isPaused)
        m.setPaused(false)
        #expect(try saved().map(\.isPaused) == [true, false])
    }

    @Test func resumingAllWhenEachWasPausedOnItsOwnResumesThemAll() throws {
        let x = set("X", []), y = set("Y", [])
        let m = try model([x, y])
        m.setPaused(true, sets: [x.id, y.id])
        m.setPaused(false)
        #expect(try saved().map(\.isPaused) == [false, false])
    }

    @Test func aSetPausedByHandDuringPauseAllStaysPausedAfterIt() throws {
        let x = set("X", []), y = set("Y", [])
        let m = try model([x, y])
        m.setPaused(true)
        m.setPaused(false, sets: [x.id])
        m.setPaused(true, sets: [x.id])
        m.setPaused(false)
        #expect(try saved().map(\.isPaused) == [true, false])
    }

    @Test func aClickChangesTheSetsAtOnceAndLeavesStateToTheBackgroundRead() async throws {
        let s = set("A", [one.id])
        let pair = PairID(set: s.id, destination: one.id)
        let m = try model([s])
        var state = SetState(); state.lastFinished = Date()
        try ConfigStore(root: root).save(state, for: pair)

        m.setDestination(two.id, on: true, for: s.id)

        #expect(m.set(s.id)?.destinationIDs == [one.id, two.id])
        #expect(m.states[pair]?.lastFinished == nil)
        try await until { m.states[pair]?.lastFinished != nil }
    }

    @Test func aDestinationTurnedBackOnReadsAsNotFinishedUntilARunFinishes() throws {
        let s = set("A", [one.id])
        let pair = PairID(set: s.id, destination: one.id)
        let m = try model([s])
        var state = SetState(); state.lastFinished = Date().addingTimeInterval(-30 * 86_400); state.lastFileCount = 7
        try ConfigStore(root: root).save(state, for: pair)
        m.reload()
        #expect(m.rows[0].status.isBackedUp)

        m.setDestination(one.id, on: false, for: s.id)
        m.setDestination(one.id, on: true, for: s.id)
        m.reload()

        let column = try #require(m.coverageColumns.first { $0.id == one.id })
        #expect(m.coverageCell(try #require(m.set(s.id)), column) == .status(.unfinished))
        #expect(m.rows[0].status == .unfinished)
        // Only how it reads: what the agent plans from is left alone.
        #expect(try ConfigStore(root: root).state(for: pair).wholeSetOwed == false)

        state.lastFinished = Date().addingTimeInterval(1)
        try ConfigStore(root: root).save(state, for: pair)
        m.reload()
        #expect(m.rows[0].status.isBackedUp)
    }

    @Test func aDestinationTurnedBackOnFromTheSetsPageReadsTheSame() throws {
        let s = set("A", [one.id])
        let pair = PairID(set: s.id, destination: one.id)
        let m = try model([s])
        var state = SetState(); state.lastFinished = Date().addingTimeInterval(-60)
        try ConfigStore(root: root).save(state, for: pair)
        var off = s; off.destinationIDs = []
        m.save(set: off)
        m.save(set: s)
        #expect(m.rows[0].status == .unfinished)
    }

    @Test func aSetNeedingAPreviewKeepsItsPlaceDuringARun() throws {
        let zed = set("Zed", [one.id]), abc = set("Abc", [one.id]), yak = set("Yak", [one.id], accepted: false)
        let m = try model([zed, abc, yak])
        var state = SetState(); state.lastFinished = Date()
        for s in [zed, abc] { try ConfigStore(root: root).save(state, for: PairID(set: s.id, destination: one.id)) }
        m.reload()
        #expect(SetOrder.sorted(m.rows.map(\.sortKey)) == [yak.id, abc.id, zed.id])
        try agentIsRunning()
        for s in [zed, abc, yak] {
            try ProgressStore(root: root).write(TransferProgress(pair: PairID(set: s.id, destination: one.id), phase: .transferring, bytesDone: 1, updated: Date()))
        }
        m.reload()
        #expect(m.rows.allSatisfy { $0.status == .running })
        #expect(SetOrder.sorted(m.rows.map(\.sortKey)) == [yak.id, abc.id, zed.id])
    }

    @Test func thePaneOfSeveralListsThemByNameWhateverTheirStatus() throws {
        let zed = SetRow(id: UUID(), name: "Zed", isPaused: false, status: .attention("Sign-in expired"), attentionWhenIdle: true)
        let abc = SetRow(id: UUID(), name: "Abc", isPaused: false, status: .running, attentionWhenIdle: false)
        #expect([zed, abc].byName == [abc, zed])
    }

    // MARK: Asking for runs while one is under way

    /// Stands in for the agent: notes the set it was given, works for a moment and exits.
    private func fakeAgent(exit code: Int = 0) throws -> URL {
        let url = root.appendingPathComponent("fake-agent")
        try "#!/bin/sh\necho \"$2\" >> \"\(launchLog.path)\"\nsleep 0.2\nexit \(code)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private var launchLog: URL { root.appendingPathComponent("launched") }
    private func launched() -> [String] {
        ((try? String(contentsOf: launchLog, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    private func agentIsRunning() throws {
        try "\(getpid())\n".write(to: root.appendingPathComponent(AgentPresence.fileName), atomically: true, encoding: .utf8)
    }

    private func until(_ done: @MainActor () -> Bool) async throws {
        let limit = ContinuousClock.now + .seconds(20)
        while !done() {
            if ContinuousClock.now > limit { Issue.record("Timed out"); return }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test func aFailedBatchNamesWhatItDroppedAndAQueuedRunKeepsTheMessage() async throws {
        let sets = ["A", "B", "C", "D"].map { set($0, [one.id]) }
        let ids = sets.map(\.id)
        let m = try model(sets)
        let agent = root.appendingPathComponent("failing-agent")
        try "#!/bin/sh\necho \"$2\" >> \"\(launchLog.path)\"\nsleep 0.2\n[ \"$2\" = \"\(ids[0].uuidString)\" ] && exit 1\nexit 0\n"
            .write(to: agent, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: agent.path)
        m.agentExecutable = agent

        m.runNow(sets: Set(ids[0..<3]))
        m.runNow(sets: [ids[3]])
        try await until { launched().count == 2 && m.queuedRuns.isEmpty }
        try await Task.sleep(for: .milliseconds(400))

        #expect(launched() == [ids[0].uuidString, ids[3].uuidString])
        let message = m.lastError ?? ""
        #expect(message.contains("stopped with code 1"))
        #expect(message.contains("Not backed up this time: B, C."))
        #expect(!message.contains(AppModel.queuedText))
    }

    @Test func aSecondBatchWaitsAndTheFirstCarriesOn() async throws {
        let sets = ["A", "B", "C", "D", "E"].map { set($0, [one.id]) }
        let ids = sets.map(\.id)
        let m = try model(sets)
        m.agentExecutable = try fakeAgent()

        m.runNow(sets: Set(ids[0..<3]))
        m.runNow(sets: Set(ids[3...]))
        #expect(m.queuedRuns == Array(ids[3...]))
        #expect(m.lastError == AppModel.queuedText)

        try await until { launched().count == 5 }
        #expect(launched() == ids.map(\.uuidString))
    }

    @Test func oneSetAskedForDuringABatchWaitsToo() async throws {
        let sets = ["A", "B", "C"].map { set($0, [one.id]) }
        let ids = sets.map(\.id)
        let m = try model(sets)
        m.agentExecutable = try fakeAgent()

        m.runNow(sets: Set(ids[0..<2]))
        m.runNow(ids[2])

        try await until { launched().count == 3 }
        #expect(launched() == ids.map(\.uuidString))
    }

    @Test func aRequestWithNothingToRunLeavesABatchAlone() async throws {
        let sets = ["A", "B"].map { set($0, [one.id]) }
        let never = set("N", [one.id], accepted: false)
        let m = try model(sets + [never])
        m.agentExecutable = try fakeAgent()

        m.runNow(sets: Set(sets.map(\.id)))
        m.runNow(sets: [never.id])

        try await until { launched().count == 2 }
    }

    @Test func aSetAlreadyWaitingInABatchIsNotQueuedAgain() throws {
        let sets = ["A", "B"].map { set($0, [one.id]) }
        let m = try model(sets)
        m.agentExecutable = try fakeAgent()
        m.runNow(sets: Set(sets.map(\.id)))
        m.runNow(sets[1].id)
        #expect(m.queuedRuns.isEmpty)
    }

    @Test func aRequestDuringAScheduledRunWaitsAndNamesWhatWasLeftOut() throws {
        var paused = set("P", [one.id]); paused.isPaused = true
        let x = set("X", [one.id])
        let m = try model([paused, x])
        try agentIsRunning()
        m.reload()
        m.runNow(sets: [paused.id, x.id])
        #expect(m.queuedRuns == [x.id])
        #expect(m.lastError == "Paused, so left out: P. \(AppModel.queuedText)")
    }

    @Test func anAgentThatCouldNotStartLeavesNothingWaitingOnIt() throws {
        let sets = ["A", "B", "C"].map { set($0, [one.id]) }
        let m = try model(sets)
        m.agentExecutable = root.appendingPathComponent("no-such-agent")
        m.runNow(sets: [sets[0].id, sets[1].id])
        m.runNow(sets: [sets[2].id])
        #expect(m.queuedRuns.isEmpty)
        #expect(m.lastError?.contains("could not start") == true)
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
