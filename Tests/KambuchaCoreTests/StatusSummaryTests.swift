import Testing
import Foundation
@testable import KambuchaCore

struct StatusSummaryTests {
    let dest = Destination(name: "iCloud", kind: .iCloudFolder)
    let dest2 = Destination(name: "Drive", kind: .googleDrive)
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func set(_ dests: [Destination], paused: Bool = false) -> BackupSet {
        var s = BackupSet(name: "Projects", source: URL(fileURLWithPath: "/tmp/p"), destinationIDs: dests.map(\.id))
        s.isPaused = paused
        return s
    }
    func state(finished: Bool = true, pending: Int = 0, held: Int = 0, failures: Int = 0, files: Int = 100) -> SetState {
        var st = SetState()
        st.lastFinished = finished ? now : nil
        st.lastFileCount = files
        st.pendingUploads = pending; st.heldDeletions = held; st.consecutiveFailures = failures
        return st
    }
    func record(_ s: BackupSet, _ d: Destination, _ status: RunRecord.Status, pending: Int = 0, at: TimeInterval = 0) -> RunRecord {
        RunRecord(setID: s.id, setName: s.name, destinationID: d.id, destinationName: d.name,
                  start: now.addingTimeInterval(at - 5), end: now.addingTimeInterval(at), trigger: .schedule,
                  scope: "all", pendingUploads: pending, status: status)
    }
    func problem(_ p: Problem, _ s: BackupSet, _ d: Destination) -> ActiveProblem {
        ActiveProblem(problem: p, pair: PairID(set: s.id, destination: d.id), setName: s.name, detail: "x", since: now)
    }
    func overall(_ s: BackupSet, _ ds: [Destination], _ states: [PairID: SetState], _ recs: [RunRecord] = [],
                 _ probs: [ActiveProblem] = [], running: Bool = false) -> OverallStatus {
        StatusSummary.overall(sets: [s], destinations: ds, states: states, records: recs, problems: probs, running: running)
    }
    func pair(_ s: BackupSet, _ d: Destination) -> PairID { PairID(set: s.id, destination: d.id) }

    @Test func backedUpNeedsAllUploadsDone() {
        let s = set([dest])
        let ok = overall(s, [dest], [pair(s, dest): state()], [record(s, dest, .success)])
        #expect(ok == .backedUp(last: now, files: 100))
    }

    @Test func pendingShowsUploading() {
        let s = set([dest])
        #expect(overall(s, [dest], [pair(s, dest): state(pending: 12)], [record(s, dest, .success)]) == .uploading(12))
    }

    @Test func heldBeatsUploading() {
        let s = set([dest])
        let st = state(pending: 12, held: 1240)
        #expect(overall(s, [dest], [pair(s, dest): st], [record(s, dest, .held)]) == .held(1240))
    }

    @Test func problemBeatsBackedUp() {
        let s = set([dest])
        let r = overall(s, [dest], [pair(s, dest): state()], [record(s, dest, .success)],
                        [problem(.permissionLost, s, dest)])
        #expect(r == .attention(Problem.permissionLost.headline))
    }

    @Test func verificationFailureIsNeverBackedUp() {
        let s = set([dest])
        let r = overall(s, [dest], [pair(s, dest): state()], [record(s, dest, .verificationFailed)])
        #expect(r != .backedUp(last: now, files: 100))
        guard case .attention = r else { Issue.record("expected attention, got \(r)"); return }
    }

    @Test func reviewItemsDoNotBlockBackedUp() {
        let s = set([dest])
        var st = state()
        st.reviewItems = [ReviewItem(id: "1", path: "a/.env", kind: .secretInExcluded)]
        #expect(overall(s, [dest], [pair(s, dest): st], [record(s, dest, .success)]) == .backedUp(last: now, files: 100))
    }

    @Test func noSetsIsNotConfigured() {
        let r = StatusSummary.overall(sets: [], destinations: [dest], states: [:], records: [], problems: [], running: false)
        #expect(r == .notConfigured)
    }

    @Test func oneFailingDestinationBlocksBackedUp() {
        let s = set([dest, dest2])
        let states = [pair(s, dest): state(), pair(s, dest2): state()]
        let recs = [record(s, dest, .success), record(s, dest2, .failed)]
        guard case .attention = overall(s, [dest, dest2], states, recs) else {
            Issue.record("a failing destination must block Backed Up"); return
        }
    }

    @Test func partialUploadShowsUploading() {
        let s = set([dest])
        var st = state()
        st.syncIncomplete = true   // honest: a state that says it's backed up has nothing left uploading
        let r = overall(s, [dest], [pair(s, dest): st], [record(s, dest, .partial, pending: 40)])
        #expect(r == .uploading(40))
    }

    @Test func aFinishedUploadReadsBackedUpWhateverTheOldRecordSays() {
        let s = set([dest])
        let r = overall(s, [dest], [pair(s, dest): state()], [record(s, dest, .partial, pending: 40)])
        #expect(r == .backedUp(last: now, files: 100))
    }

    @Test func aKilledRunIsNotBackedUpBehindAnOldSuccess() {
        let s = set([dest])
        var st = state()
        st.wholeSetOwed = true   // saved before the sync, then the agent was killed, so no record followed
        #expect(overall(s, [dest], [pair(s, dest): st], [record(s, dest, .success)]) == .unfinished)
    }

    private func waiting(alerted: Bool = false) -> SetState {
        var st = state()
        st.verifyOwed = ["a"]
        st.mismatched = ["a": Mismatch(since: now, evicted: true)]
        st.mismatched["a"]?.alerted = alerted
        return st
    }

    @Test func aPartialRunWaitingOnICloudSaysSoNotUploadingZero() {
        let s = set([dest])
        let r = overall(s, [dest], [pair(s, dest): waiting()], [record(s, dest, .partial, pending: 0)])
        #expect(r == .waitingForDownload(1))
    }

    @Test func aPartialRunWithNothingToCountIsUnfinishedNotRunning() {
        let s = set([dest])
        var st = state(); st.syncIncomplete = true
        let partial = [record(s, dest, .partial, pending: 0)]
        #expect(overall(s, [dest], [pair(s, dest): st], partial) == .unfinished)
        #expect(overall(s, [dest], [pair(s, dest): st], partial, running: true) == .running)
    }

    @Test func aRefusedFileIsNeverBackedUpEvenWithACleanRecord() {
        let s = set([dest])
        var st = state(); st.refusedSince = ["a.tmp": now]
        #expect(overall(s, [dest], [pair(s, dest): st], [record(s, dest, .success)]) == .notAccepted(1))
        #expect(overall(s, [dest], [pair(s, dest): st], [record(s, dest, .partial)]) == .notAccepted(1))
    }

    @Test func aRefusedFileOverItsTimeIsAProblemNotACount() {
        let s = set([dest])
        var st = state(); st.refusedSince = ["a.tmp": now]
        let r = overall(s, [dest], [pair(s, dest): st], [record(s, dest, .partial)], [problem(.fileRefused, s, dest)])
        #expect(r == .attention(Problem.fileRefused.headline))
    }

    @Test func aMismatchOutranksARefusedFile() {
        let s = set([dest])
        var st = waiting(); st.refusedSince = ["a.tmp": now]
        #expect(overall(s, [dest], [pair(s, dest): st], [record(s, dest, .partial)]) == .waitingForDownload(1))
    }

    /// A skipped run says nothing, so the record stays partial after the state has caught up.
    @Test func aPartialRecordTheStateHasMovedPastIsBackedUp() {
        let s = set([dest])
        #expect(overall(s, [dest], [pair(s, dest): state()], [record(s, dest, .partial)]) == .backedUp(last: now, files: 100))
    }

    @Test func realUploadsOutrankTheWait() {
        let s = set([dest])
        var st = waiting(); st.pendingUploads = 3
        #expect(overall(s, [dest], [pair(s, dest): st], [record(s, dest, .partial, pending: 3)]) == .uploading(3))
    }

    @Test func theOpenAlertAndFailedRecordOfAWaitingFileDontHideTheWait() {
        let s = set([dest])
        let r = overall(s, [dest], [pair(s, dest): waiting()], [record(s, dest, .verificationFailed)],
                        [problem(.verificationFailed, s, dest)])
        #expect(r == .waitingForDownload(1))
    }

    @Test func aWaitPastItsTimeNeedsAttention() {
        let s = set([dest])
        let r = overall(s, [dest], [pair(s, dest): waiting(alerted: true)], [record(s, dest, .partial)],
                        [problem(.verificationFailed, s, dest)])
        #expect(r == .attention(Problem.verificationFailed.headline))
    }

    @Test func aMismatchOnDiskIsNotAWait() {
        let s = set([dest])
        var st = waiting(); st.mismatched["b"] = Mismatch(since: now)
        let r = overall(s, [dest], [pair(s, dest): st], [record(s, dest, .partial)], [problem(.verificationFailed, s, dest)])
        #expect(r == .attention(Problem.verificationFailed.headline))
    }

    @Test func anotherPairsFailureIsNotHiddenByAWait() {
        let s = set([dest, dest2])
        let states = [pair(s, dest): waiting(), pair(s, dest2): state()]
        let r = overall(s, [dest, dest2], states, [record(s, dest, .partial), record(s, dest2, .success)],
                        [problem(.verificationFailed, s, dest), problem(.verificationFailed, s, dest2)])
        #expect(r == .attention(Problem.verificationFailed.headline))
    }

    @Test func theWaitDoesNotOutrankAMissingDestination() {
        let s = set([dest])
        let lost = overall(s, [dest], [pair(s, dest): waiting()], [record(s, dest, .partial)], [problem(.destinationMissing, s, dest)])
        #expect(lost == .attention(Problem.destinationMissing.headline))

        var removed = set([dest]); removed.destinationIDs.append(UUID())
        let gone = overall(removed, [dest], [PairID(set: removed.id, destination: dest.id): waiting()], [])
        #expect(gone == .attention("A destination was removed"))
    }

    @Test func theMismatchWordingSaysWhatsTrue() {
        #expect(StatusSummary.recheckText(count: 1) == "Re-checking 1 file that didn't match, waiting for iCloud to download it")
        #expect(StatusSummary.recheckText(count: 1200) == "Re-checking 1,200 files that didn't match, waiting for iCloud to download them")
    }

    // MARK: External drives (final review S4)

    let ssd = Destination(name: "SSD", kind: .externalDrive, encrypted: false, volumeUUID: "U")
    func unplugged(_ s: BackupSet, _ ds: [Destination], _ states: [PairID: SetState], _ recs: [RunRecord] = [],
                   _ probs: [ActiveProblem] = []) -> OverallStatus {
        StatusSummary.overall(sets: [s], destinations: ds, states: states, records: recs, problems: probs, running: false,
                              disconnected: [ssd.id])
    }

    @Test func anOverdueDriveIsAQuietReminderNotAttention() {
        let s = set([dest, ssd])
        let states = [pair(s, dest): state(), pair(s, ssd): state()]
        let recs = [record(s, dest, .success), record(s, ssd, .success)]
        #expect(overall(s, [dest, ssd], states, recs, [problem(.driveOverdue, s, ssd)]) == .backedUp(last: now, files: 200))
        #expect(unplugged(s, [dest, ssd], states, recs, [problem(.driveOverdue, s, ssd)]) == .backedUp(last: now, files: 100))
    }

    @Test func aDriveThatIsNotConnectedDoesNotBlockBackedUp() {
        let s = set([dest, ssd])
        var away = state(); away.syncIncomplete = true
        let r = unplugged(s, [dest, ssd], [pair(s, dest): state(), pair(s, ssd): away],
                          [record(s, dest, .success), record(s, ssd, .partial)])
        #expect(r == .backedUp(last: now, files: 100))
    }

    @Test func aNeverConnectedDriveDoesNotBlockBackedUp() {
        let s = set([dest, ssd])
        let r = unplugged(s, [dest, ssd], [pair(s, dest): state()], [record(s, dest, .success)])
        #expect(r == .backedUp(last: now, files: 100))
    }

    @Test func aSetOnlyOnANotConnectedDriveSaysSoNotThatItResumesNextRun() {
        let s = set([ssd])
        var away = state(); away.syncIncomplete = true
        let r = unplugged(s, [ssd], [pair(s, ssd): away], [record(s, ssd, .partial)])
        #expect(r == .driveNotConnected(name: "SSD", last: now))
    }

    @Test func aSetOnlyOnANeverConnectedDriveHasNoLastBackup() {
        let s = set([ssd])
        #expect(unplugged(s, [ssd], [:]) == .driveNotConnected(name: "SSD", last: nil))
    }

    @Test func aConnectedDriveStillCountsInFull() {
        let s = set([dest, ssd])
        var away = state(); away.syncIncomplete = true
        let r = overall(s, [dest, ssd], [pair(s, dest): state(), pair(s, ssd): away],
                        [record(s, dest, .success), record(s, ssd, .partial)])
        #expect(r == .unfinished)
    }

    @Test func aDriveNotConnectedGivesWayToAPreviewRequest() {
        let s = set([ssd])
        #expect(StatusSummary.withPreviewNeeded(.driveNotConnected(name: "SSD", last: nil), sets: [s]) == .attention("Preview needed: Projects"))
    }

    @Test func aProblemFromAPairNoLongerInUseSaysNothing() {
        let s = set([dest])
        let oldPair = ActiveProblem(problem: .verificationFailed, pair: PairID(set: s.id, destination: dest2.id), setName: s.name, detail: "x", since: now)
        let oldSet = ActiveProblem(problem: .deletionsHeld, pair: PairID(set: UUID(), destination: dest.id), setName: "Gone", detail: "x", since: now)
        let oldHold = ActiveProblem(problem: .deletionsHeld, pair: PairID(set: s.id, destination: dest2.id), setName: s.name, detail: "x", since: now)
        #expect(overall(s, [dest, dest2], [pair(s, dest): state()], [record(s, dest, .success)], [oldPair, oldSet, oldHold]) == .backedUp(last: now, files: 100))
    }

    @Test func drillDueDoesNotBlockBackedUp() {
        let s = set([dest])
        let r = overall(s, [dest], [pair(s, dest): state()], [record(s, dest, .success)], [problem(.drillDue, s, dest)])
        #expect(r == .backedUp(last: now, files: 100))
    }

    @Test func newerRecordSupersedesOlderFailure() {
        let s = set([dest])
        let recs = [record(s, dest, .failed, at: -100), record(s, dest, .success, at: 0)]
        #expect(overall(s, [dest], [pair(s, dest): state()], recs) == .backedUp(last: now, files: 100))
    }

    @Test func runningAndPausedAndNeverRun() {
        let s = set([dest])
        #expect(overall(s, [dest], [pair(s, dest): state()], [record(s, dest, .success)], running: true) == .running)
        #expect(overall(set([dest], paused: true), [dest], [:]) == .paused)
        guard case .attention = overall(s, [dest], [:]) else { Issue.record("never run is not Backed Up"); return }
    }
}

extension StatusSummaryTests {
    @Test func danglingDestinationIsAttentionNotBackedUp() {
        var s = set([dest])
        s.destinationIDs.append(UUID())
        let r = overall(s, [dest], [pair(s, dest): state()], [record(s, dest, .success)])
        #expect(r == .attention("A destination was removed"))
    }
}
