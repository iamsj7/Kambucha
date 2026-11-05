import Testing
import Foundation
@testable import MirrorCore

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func accepted(_ name: String, _ destinations: [Destination], paused: Bool = false) -> BackupSet {
    var s = BackupSet(name: name, source: URL(fileURLWithPath: "/tmp/\(name)"), destinationIDs: destinations.map(\.id))
    s.acceptPreview()
    s.isPaused = paused
    return s
}

private func finished(_ change: (inout SetState) -> Void = { _ in }) -> SetState {
    var s = SetState(); s.lastFinished = now; s.lastFileCount = 10; change(&s); return s
}

private func record(_ set: BackupSet, _ d: Destination, _ status: RunRecord.Status) -> RunRecord {
    RunRecord(setID: set.id, setName: set.name, destinationID: d.id, destinationName: d.name, start: now, end: now,
              trigger: .schedule, scope: "all", status: status)
}

private func statuses(_ sets: [BackupSet], _ ds: [Destination], _ states: [PairID: SetState], records: [RunRecord] = [],
                      problems: [ActiveProblem] = [], running: Set<PairID> = [], away: Set<UUID> = []) -> [PairID: OverallStatus] {
    StatusSummary.pairStatuses(sets: sets, destinations: ds, states: states, records: records, problems: problems,
                               running: running, disconnected: away)
}

@Suite struct PairStatusTests {
    let icloud = Destination(name: "iCloud Drive", kind: .iCloudFolder)
    let drive = Destination(name: "Travel SSD", kind: .externalDrive, encrypted: false, volumeUUID: "Z")

    @Test func aPairIsJudgedOnItsOwnNotByItsSiblings() {
        let s = accepted("A", [icloud, drive])
        let good = PairID(set: s.id, destination: icloud.id), bad = PairID(set: s.id, destination: drive.id)
        let out = statuses([s], [icloud, drive], [good: finished(), bad: finished { $0.consecutiveFailures = 2 }])
        #expect(out[good] == .backedUp(last: now, files: 10))
        #expect(out[bad] == .attention(Problem.repeatedFailures.headline))
    }

    @Test func aPairAgreesWithTheWholeSetWhenTheSetHasOneDestination() {
        let s = accepted("A", [icloud])
        let p = PairID(set: s.id, destination: icloud.id)
        for state in [finished(), finished { $0.pendingUploads = 3 }, finished { $0.heldDeletions = 4 }, SetState()] {
            let whole = StatusSummary.overall(sets: [s], destinations: [icloud], states: [p: state], records: [], problems: [], running: false)
            #expect(statuses([s], [icloud], [p: state])[p] == whole)
        }
    }

    @Test func aProblemAndARunRecordCountForTheirPairOnly() {
        let s = accepted("A", [icloud, drive])
        let a = PairID(set: s.id, destination: icloud.id), b = PairID(set: s.id, destination: drive.id)
        let problem = ActiveProblem(problem: .uploadStalled, pair: a, setName: "A", detail: "", since: now)
        let out = statuses([s], [icloud, drive], [a: finished(), b: finished()], records: [record(s, drive, .failed)], problems: [problem])
        #expect(out[a] == .attention(Problem.uploadStalled.headline))
        #expect(out[b] == .attention(Problem.repeatedFailures.headline))
    }

    @Test func noPairSaysBackedUpWhileMirrorCanNotRun() {
        let s = accepted("A", [icloud, drive])
        let p = PairID(set: s.id, destination: icloud.id), q = PairID(set: s.id, destination: drive.id)
        let failed = ActiveProblem(problem: .agentFailed, pair: .agent, setName: "", detail: "", since: now)
        let out = statuses([s], [icloud, drive], [p: finished(), q: finished { $0.pendingUploads = 3 }], problems: [failed])
        #expect(out[p] == .attention(Problem.agentFailed.headline))
        #expect(out[q] == .uploading(3))
    }

    @Test func aPairTurnedBackOnOwesARunUntilOneFinishes() {
        let s = accepted("A", [icloud])
        let p = PairID(set: s.id, destination: icloud.id)
        let turnedOn = [p: now.addingTimeInterval(60)]
        #expect(statuses([s], [icloud], StatusSummary.withTurnedOn([p: finished()], turnedOn: turnedOn))[p] == .unfinished)
        let later = finished { $0.lastFinished = now.addingTimeInterval(120) }
        #expect(statuses([s], [icloud], StatusSummary.withTurnedOn([p: later], turnedOn: turnedOn))[p]
                == .backedUp(last: now.addingTimeInterval(120), files: 10))
    }

    @Test func aPairThatNeverFinishedStillReadsAsNotBackedUpWhenTurnedOn() {
        let s = accepted("A", [icloud])
        let p = PairID(set: s.id, destination: icloud.id)
        let states = StatusSummary.withTurnedOn([p: SetState()], turnedOn: [p: now])
        #expect(statuses([s], [icloud], states)[p] == .attention("Not backed up yet"))
    }

    @Test func onlyThePairMovingFilesSaysSo() {
        let s = accepted("A", [icloud, drive])
        let a = PairID(set: s.id, destination: icloud.id), b = PairID(set: s.id, destination: drive.id)
        let out = statuses([s], [icloud, drive], [a: finished(), b: finished()], running: [a])
        #expect(out[a] == .running)
        #expect(out[b] == .backedUp(last: now, files: 10))
    }

    @Test func aDriveAwayIsNotAFailure() {
        let s = accepted("A", [drive])
        let p = PairID(set: s.id, destination: drive.id)
        #expect(statuses([s], [drive], [p: finished()], away: [drive.id])[p] == .driveNotConnected(name: "Travel SSD", last: now))
    }

    @Test func aPausedSetIsPausedEverywhereAndAnUnacceptedOneAsksForItsPreview() {
        let paused = accepted("A", [icloud], paused: true)
        let unaccepted = BackupSet(name: "B", source: URL(fileURLWithPath: "/tmp/b"), destinationIDs: [icloud.id])
        let out = statuses([paused, unaccepted], [icloud], [:])
        #expect(out[PairID(set: paused.id, destination: icloud.id)] == .paused)
        #expect(out[PairID(set: unaccepted.id, destination: icloud.id)] == .attention("Preview needed: B"))
    }

    @Test func aDestinationThatIsGoneHasNoEntry() {
        let s = accepted("A", [icloud, drive])
        #expect(statuses([s], [icloud], [:]).count == 1)
    }

    @Test func fiveHundredPairsAreQuickEnoughForARefresh() {
        let ds = (0..<10).map { Destination(name: "D\($0)", kind: .iCloudFolder) }
        let sets = (0..<50).map { accepted("S\($0)", ds) }
        var states: [PairID: SetState] = [:]
        for p in BackupSet.pairs(of: sets) { states[p] = finished() }
        let records = (0..<200).map { record(sets[$0 % 50], ds[$0 % 10], .success) }
        let start = ContinuousClock.now
        let out = statuses(sets, ds, states, records: records)
        #expect(out.count == 500)
        #expect(ContinuousClock.now - start < .milliseconds(500))
    }
}

@Suite struct CoverageCellTests {
    let icloud = Destination(name: "iCloud Drive", kind: .iCloudFolder)
    let locked = Destination(name: "OneDrive", kind: .oneDrive)

    private func cell(_ set: BackupSet, _ d: Destination, _ status: OverallStatus? = .backedUp(last: now, files: 1),
                      away: Bool = false, confirm: Bool = false) -> CoverageCell {
        CoverageCell.make(set: set, destination: d, status: status, driveAway: away, needsDiskConfirmation: confirm)
    }

    @Test func aDestinationTheSetDoesNotUseIsOff() {
        #expect(cell(accepted("A", []), icloud) == .off)
        #expect(cell(accepted("A", []), icloud).kind == .off)
    }

    @Test func aPausedSetSaysSoBeforeAnythingElse() {
        #expect(cell(accepted("A", [locked], paused: true), locked, confirm: true) == .status(.paused))
    }

    @Test func anUnsavedKitAndAnUnconfirmedDiskAreSaidFirstAsOnTheDestinationsPage() {
        #expect(cell(accepted("A", [locked]), locked) == .saveRecoveryKit)
        #expect(cell(accepted("A", [icloud]), icloud, confirm: true) == .confirmDisk)
        var saved = locked; saved.recoveryKitConfirmed = true
        #expect(cell(accepted("A", [saved]), saved) == .status(.backedUp(last: now, files: 1)))
    }

    @Test func aDriveThatIsAwayKeepsItsOwnWording() {
        let d = Destination(name: "SSD", kind: .externalDrive, encrypted: true, volumeUUID: "Z")
        let away = OverallStatus.driveNotConnected(name: "SSD", last: nil)
        #expect(cell(accepted("A", [d]), d, away, away: true) == .status(away))
        #expect(cell(accepted("A", [d]), d, away, away: true).kind == .notConnected)
    }

    @Test func aPairNotJudgedYetIsNotCalledBackedUp() {
        #expect(cell(accepted("A", [icloud]), icloud, nil).kind == .attention)
    }

    @Test func kinds() {
        let cases: [(OverallStatus, CoverageCell.Kind)] = [
            (.backedUp(last: now, files: 1), .backedUp), (.uploading(1), .working), (.running, .working), (.unfinished, .working),
            (.waitingForDownload(1), .working), (.notAccepted(1), .working), (.held(1), .attention), (.attention("x"), .attention),
            (.paused, .paused), (.driveNotConnected(name: "x", last: nil), .notConnected)]
        for (status, kind) in cases { #expect(CoverageCell.status(status).kind == kind) }
    }
}

@Suite struct TurningADestinationOffTests {
    let a = UUID(), b = UUID()

    @Test func onlyTheDestinationListChanges() {
        var s = BackupSet(name: "A", source: URL(fileURLWithPath: "/tmp/a"), destinationIDs: [a, b])
        s.acceptPreview()
        s.adoptsBackupIn = [b]
        let off = s.withDestination(b, on: false)
        var expected = s; expected.destinationIDs = [a]
        #expect(off == expected)
        #expect(off.isPreviewAccepted)
    }

    @Test func turningOnAddsAtTheEndOnce() {
        let s = BackupSet(name: "A", source: URL(fileURLWithPath: "/tmp/a"), destinationIDs: [a])
        #expect(s.withDestination(b, on: true).destinationIDs == [a, b])
        #expect(s.withDestination(a, on: true).destinationIDs == [a])
    }

    @Test func theLastDestinationCanGoAsOnTheSetsPage() {
        let s = BackupSet(name: "A", source: URL(fileURLWithPath: "/tmp/a"), destinationIDs: [a])
        #expect(s.withDestination(a, on: false).destinationIDs.isEmpty)
    }

    @Test func theWordsSayTheCopyStays() {
        let text = CoverageTurnOff.message(destination: "Google Drive", isLast: false)
        #expect(text.contains("stays there") && text.contains("nothing in it is deleted"))
        #expect(!text.contains("only destination"))
        #expect(CoverageTurnOff.message(destination: "Google Drive", isLast: true).contains("only destination"))
        #expect(CoverageTurnOff.title(set: "Photos", destination: "Google Drive") == "Stop backing up \"Photos\" to Google Drive?")
    }
}

private struct Item: Identifiable { var id: UUID }

@Suite struct SetOrderTests {
    let a = UUID(), b = UUID(), c = UUID()

    private func keys(attention: Set<UUID> = []) -> [SetSortKey] {
        [(b, "Beta"), (a, "alpha"), (c, "Gamma")].map { SetSortKey(id: $0, name: $1, needsAttention: attention.contains($0)) }
    }

    @Test func attentionFirstThenByNameIgnoringCase() {
        #expect(SetOrder.sorted(keys()) == [a, b, c])
        #expect(SetOrder.sorted(keys(attention: [c])) == [c, a, b])
    }

    @Test func numbersSortAsFinderSortsThem() {
        let ten = UUID(), two = UUID()
        #expect(SetOrder.sorted([SetSortKey(id: ten, name: "Set 10", needsAttention: false),
                                 SetSortKey(id: two, name: "Set 2", needsAttention: false)]) == [two, ten])
    }

    @Test func sameNamesKeepOneOrderWhateverCameFirst() {
        let x = SetSortKey(id: a, name: "Same", needsAttention: false), y = SetSortKey(id: b, name: "Same", needsAttention: false)
        #expect(SetOrder.sorted([x, y]) == SetOrder.sorted([y, x]))
    }

    @Test func whatNeedsAttentionIsWhatTheOwnerCanActOn() {
        #expect(OverallStatus.attention("x").needsAttention)
        #expect(OverallStatus.held(1).needsAttention)
        for s in [OverallStatus.backedUp(last: now, files: 1), .uploading(1), .running, .paused, .unfinished, .notAccepted(1),
                  .waitingForDownload(1), .driveNotConnected(name: "x", last: nil)] { #expect(!s.needsAttention) }
    }

    @Test func aRowHoldsStillWhileThePointerIsOverTheList() {
        var order = SetOrder()
        order.update(keys(), held: false)
        order.update(keys(attention: [c]), held: true)
        #expect(order.ids == [a, b, c])
        order.update(keys(attention: [c]), held: false)
        #expect(order.ids == [c, a, b])
    }

    @Test func whileHeldASetThatWentIsDroppedAndANewOneJoinsTheEnd() {
        var order = SetOrder()
        order.update(keys(), held: false)
        let new = SetSortKey(id: UUID(), name: "Aardvark", needsAttention: true)
        order.update(keys().filter { $0.id != b } + [new], held: true)
        #expect(order.ids == [a, c, new.id])
    }

    @Test func anItemTheOrderHasNotSeenIsKeptAtTheEnd() {
        var order = SetOrder()
        order.update(keys(), held: false)
        let unseen = UUID()
        #expect(order.arranged([c, unseen, b, a].map(Item.init)).map(\.id) == [a, b, c, unseen])
    }
}

@Suite struct SetFilterTests {
    @Test func ignoresCaseAndAccents() {
        #expect(SetFilter.matches("Études", filter: "etu"))
        #expect(SetFilter.matches("Client Sites", filter: "SITES"))
        #expect(!SetFilter.matches("Photos", filter: "music"))
    }

    @Test func blankMatchesEverything() {
        #expect(SetFilter.matches("Photos", filter: ""))
        #expect(SetFilter.matches("Photos", filter: "  "))
    }
}

@Suite struct SetBatchTests {
    let d1 = Destination(name: "One", kind: .iCloudFolder), d2 = Destination(name: "Two", kind: .iCloudFolder)

    @Test func actionsAreOfferedWhenTheyCanDoSomething() {
        let active = SetBatch(sets: [accepted("A", [])])
        #expect(active.canBackUp && active.canPause && !active.canResume)
        let paused = SetBatch(sets: [accepted("A", [], paused: true)])
        #expect(!paused.canBackUp && !paused.canPause && paused.canResume)
        let mixed = SetBatch(sets: [accepted("A", []), accepted("B", [], paused: true)])
        #expect(mixed.canBackUp && mixed.canPause && mixed.canResume)
        let never = SetBatch(sets: [BackupSet(name: "C", source: URL(fileURLWithPath: "/tmp/c"))])
        #expect(!never.canBackUp)
    }

    @Test func aDestinationEverySetAlreadyUsesIsNotOffered() {
        let batch = SetBatch(sets: [accepted("A", [d1]), accepted("B", [d1, d2])])
        #expect(batch.addable([d1, d2]).map(\.id) == [d2.id])
    }

    @Test func aRunLeavesOutPausedAndUnacceptedSetsAndNamesThem() {
        let ok = accepted("A", [])
        let plan = SetBatch(sets: [ok, accepted("B", [], paused: true),
                                   BackupSet(name: "C", source: URL(fileURLWithPath: "/tmp/c"))]).runPlan
        #expect(plan == SetBatch.RunPlan(run: [ok.id], unaccepted: ["C"], paused: ["B"]))
        let notice = SetBatch.runNotice(plan)
        #expect(notice?.contains("Preview before the first backup: C.") == true)
        #expect(notice?.contains("Paused, so left out: B.") == true)
        #expect(SetBatch.runNotice(SetBatch.RunPlan(run: [ok.id], unaccepted: [], paused: [])) == nil)
    }

    @Test func removingSeveralNamesEveryOne() {
        let names = (1...50).map { "Set \($0)" }
        let text = SetBatch.removalMessage(names: names)
        for n in names { #expect(text.contains(n)) }
        #expect(text.contains("are not deleted"))
        #expect(SetBatch.removalTitle(count: 50) == "Remove 50 Sets?")
    }

    @Test func theSummarySaysOnlyWhatIsThere() {
        #expect(SetBatch.summary(attention: 1, paused: 0) == "1 needs attention")
        #expect(SetBatch.summary(attention: 2, paused: 3) == "2 need attention, 3 paused")
        #expect(SetBatch.summary(attention: 0, paused: 0) == nil)
    }

    @Test func selectedSetsTheFilterHidesAreCounted() {
        #expect(SetBatch.hiddenNote(count: 0) == nil)
        #expect(SetBatch.hiddenNote(count: 1) == "1 hidden by the filter")
        #expect(SetBatch.hiddenNote(count: 2) == "2 hidden by the filter")
    }
}
