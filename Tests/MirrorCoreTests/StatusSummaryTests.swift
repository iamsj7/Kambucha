import Testing
import Foundation
@testable import MirrorCore

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
        let r = overall(s, [dest], [pair(s, dest): state()], [record(s, dest, .partial, pending: 40)])
        #expect(r == .uploading(40))
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
