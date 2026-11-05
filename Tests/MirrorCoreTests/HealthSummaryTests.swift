import Testing
import Foundation
@testable import MirrorCore

struct HealthSummaryTests {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    func h(_ name: String, _ s: OverallStatus) -> SetHealth { SetHealth(id: UUID(), name: name, status: s) }

    @Test func allWellIsCalmAndCounted() {
        let s = HealthSummary((1...12).map { h("S\($0)", .backedUp(last: now.addingTimeInterval(Double(-$0 * 60)), files: 1)) })
        #expect(s.isCalm)
        #expect(s.countLine == "12 sets backed up")
        #expect(s.lastBackup == now.addingTimeInterval(-60))
    }

    @Test func attentionIsOrderedByUrgencyThenName() {
        let s = HealthSummary([
            h("Zed", .attention("Preview needed: Zed")), h("B", .attention("Sign in again")), h("A", .held(3)),
            h("C", .unfinished), h("D", .backedUp(last: now, files: 1))])
        #expect(s.attention.map(\.name) == ["A", "B", "Zed", "C"])
        #expect(s.attention.map(\.kind) == [.held, .problem, .previewNeeded, .unfinished])
        #expect(!s.isCalm)
        #expect(s.countLine == "1 of 5 sets backed up")
    }

    @Test func runningAndUploadingAreActiveNotAttention() {
        let s = HealthSummary([h("A", .running), h("B", .uploading(4)), h("C", .paused), h("D", .driveNotConnected(name: "SSD", last: nil))])
        #expect(s.active.count == 2 && s.attention.isEmpty && s.paused == 1 && s.driveAway == 1)
    }

    @Test func countLineForPausedAndEmpty() {
        #expect(HealthSummary([]).countLine == nil)
        #expect(HealthSummary([h("A", .paused)]).countLine == "1 set paused")
        let s = HealthSummary([h("A", .backedUp(last: now, files: 1)), h("B", .paused)])
        #expect(s.countLine == "1 set backed up, 1 paused")
    }

    @Test func previewPrefixMatchesWhatStatusSummaryWrites() {
        let set = BackupSet(name: "P", source: URL(fileURLWithPath: "/x"), destinationIDs: [])
        let out = StatusSummary.withPreviewNeeded(.backedUp(last: now, files: 1), sets: [set])
        #expect(HealthSummary([h("P", out)]).attention.first?.kind == .previewNeeded)
    }

    @Test func panelNeverShowsMoreThanTheLimit() {
        for (a, p) in [(0, 0), (50, 0), (50, 20), (2, 9), (0, 9), (3, 1)] {
            let r = PanelRows(attention: a, progress: p)
            #expect(r.attention + r.progress <= 5)
            #expect(r.attention + r.progress + r.more == a + p)
        }
        let r = PanelRows(attention: 50, progress: 20)
        #expect(r.progress == 1 && r.attention == 4 && r.more == 65)
    }

    @Test func destinationAttentionMatchesTheFailureStates() {
        #expect(DestinationHealth.failing.needsAttention && DestinationHealth.held(1).needsAttention)
        #expect(!DestinationHealth.backedUp(last: now).needsAttention && !DestinationHealth.uploading(3).needsAttention)
    }
}
