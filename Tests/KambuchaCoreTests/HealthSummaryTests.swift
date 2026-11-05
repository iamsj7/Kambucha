import Testing
import Foundation
@testable import KambuchaCore

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

    // Any agent running marks every clean set as running, so a count would read "0 of 12" on a healthy Mac.
    @Test func aRunningBackupIsNotCountedAsNothingBackedUp() {
        let s = HealthSummary((1...12).map { h("S\($0)", .running) })
        #expect(s.countLine == "Backing up")
        let mixed = HealthSummary([h("A", .running), h("B", .paused), h("C", .driveNotConnected(name: "SSD", last: nil))])
        #expect(mixed.countLine == "Backing up, 1 paused, 1 on a drive that isn't connected")
    }

    @Test func uploadingSetsAreSaidInTheCount() {
        let s = HealthSummary([h("A", .backedUp(last: now, files: 1)), h("B", .uploading(4))])
        #expect(s.countLine == "1 of 2 sets backed up, 1 uploading")
    }

    @Test func onlyAFullCountIsAllBackedUp() {
        let ok = h("A", OverallStatus.backedUp(last: now, files: 1))
        #expect(HealthSummary([ok]).allBackedUp)
        #expect(HealthSummary([ok, h("B", .paused)]).allBackedUp)
        #expect(!HealthSummary([]).allBackedUp)
        #expect(!HealthSummary([h("B", .paused)]).allBackedUp)
        #expect(!HealthSummary([ok, h("B", .attention("Sign in again"))]).allBackedUp)
        #expect(!HealthSummary([h("A", .driveNotConnected(name: "SSD", last: nil))]).allBackedUp)
        #expect(!HealthSummary([h("A", .running)]).allBackedUp)
    }

    @Test func aPanelWithNoRowsSaysSo() {
        #expect(PanelRows(attention: 0, progress: 0).isEmpty)
        #expect(!PanelRows(attention: 1, progress: 0).isEmpty)
        #expect(!PanelRows(attention: 0, progress: 1).isEmpty)
    }

    @Test func moreCountsOnlyWhatTheOverviewLists() {
        #expect(PanelRows(attention: 0, progress: 8).more == 0)
        #expect(PanelRows(attention: 8, progress: 0).more == 3)
    }

    @Test func destinationsAreFineOnlyWhenBackedUp() {
        #expect(DestinationSummary.line([.fine, .fine]) == "2 destinations, all fine")
        #expect(DestinationSummary.line([.fine, .unused]) == "2 destinations, all fine")
        #expect(DestinationSummary.line([.notBackedUp]) == "1 destination, 1 not backed up yet")
        #expect(DestinationSummary.line([.paused]) == "1 destination, 1 paused")
        #expect(DestinationSummary.line([.uploading, .fine]) == "2 destinations, 1 uploading")
        #expect(DestinationSummary.line([.fine, .notConnected, .notBackedUp]) == "3 destinations, 1 not connected, 1 not backed up yet")
        #expect(DestinationSummary.line([.unused]) == "1 destination, not used yet")
        #expect(DestinationSummary.line([]) == nil)
    }

    @Test func oneDestinationNeedsAttentionAndTwoNeed() {
        #expect(DestinationSummary.line([.fine, .attention]) == "2 destinations, 1 needs attention")
        #expect(DestinationSummary.line([.attention, .attention]) == "2 destinations, 2 need attention")
    }

    @Test func aDriveThatIsAwayIsNotAProblemUnlessSomethingElseIs() {
        let last = now
        #expect(DestinationStanding(.backedUp(last: last), driveAway: true) == .notConnected)
        #expect(DestinationStanding(.unfinished, driveAway: true) == .notConnected)
        #expect(DestinationStanding(.notBackedUp, driveAway: true) == .notConnected)
        #expect(DestinationStanding(.failing, driveAway: true) == .attention)
        #expect(DestinationStanding(.held(2), driveAway: true) == .attention)
        #expect(DestinationStanding(.paused, driveAway: true) == .paused)
        #expect(DestinationStanding(.unused, driveAway: true) == .unused)
    }

    @Test func standingOfAConnectedDestination() {
        #expect(DestinationStanding(.backedUp(last: now), driveAway: false) == .fine)
        #expect(DestinationStanding(.notBackedUp, driveAway: false) == .notBackedUp)
        #expect(DestinationStanding(.uploading(3), driveAway: false) == .uploading)
        #expect(DestinationStanding(.unfinished, driveAway: false) == .attention)
    }

    // The destination screen's own warnings stand even with no set using it yet.
    @Test func aWarningAlwaysNeedsAttention() {
        #expect(DestinationStanding(.unused, driveAway: false, warned: true) == .attention)
        #expect(DestinationStanding(.backedUp(last: now), driveAway: false, warned: true) == .attention)
    }

    @Test func overviewAsksForWhatIsMissing() {
        #expect(OverviewPrompts.lines(hasSets: false, hasDestinations: false)
                == ["Add a folder to start backing it up.", "Add a place to keep your backups."])
        #expect(OverviewPrompts.lines(hasSets: false, hasDestinations: true) == ["Add a folder to start backing it up."])
        #expect(OverviewPrompts.lines(hasSets: true, hasDestinations: false) == ["Add a place to keep your backups."])
        #expect(OverviewPrompts.lines(hasSets: true, hasDestinations: true).isEmpty)
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
            #expect(r.attention + r.more == a)
        }
        let r = PanelRows(attention: 50, progress: 20)
        #expect(r.progress == 1 && r.attention == 4 && r.more == 46)
    }

    @Test func destinationAttentionMatchesTheFailureStates() {
        #expect(DestinationHealth.failing.needsAttention && DestinationHealth.held(1).needsAttention)
        #expect(!DestinationHealth.backedUp(last: now).needsAttention && !DestinationHealth.uploading(3).needsAttention)
    }
}
