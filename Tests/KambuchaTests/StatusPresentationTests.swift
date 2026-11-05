import Testing
import Foundation
import KambuchaCore
@testable import Kambucha

struct StatusPresentationTests {
    /// A mismatch is a real problem being worked on, so nothing about it may read as calm.
    @Test func aRecordedMismatchIsSaidPlainlyWithTheAttentionSymbol() {
        let p = StatusPresentation(.waitingForDownload(2))
        #expect(p.symbol == StatusPresentation(.attention("x")).symbol)
        #expect(p.title == "Files Didn't Match")
        #expect(p.detail == "Re-checking 2 files that didn't match, waiting for iCloud to download them")
        #expect(OverallStatus.waitingForDownload(2).shortText == "Didn't Match")
    }

    @Test func aFileNotAcceptedYetIsCountedAndIsNotBackedUp() {
        #expect(StatusPresentation(.notAccepted(1)).title == "1 file iCloud hasn't accepted yet")
        #expect(StatusPresentation(.notAccepted(2)).title == "2 files iCloud hasn't accepted yet")
    }

    @Test func anUnfinishedBackupNeverReadsAsRunning() {
        #expect(StatusPresentation(.unfinished).title != StatusPresentation(.running).title)
        #expect(OverallStatus.unfinished.shortText != OverallStatus.running.shortText)
    }

    @Test func aDriveNotConnectedHasItsOwnLine() {
        let never = StatusPresentation(.driveNotConnected(name: "SSD", last: nil))
        #expect(never.title == "Not connected yet")
        #expect(never.detail == "SSD backs up when you plug it in.")
        #expect(never.symbol == "externaldrive.badge.xmark")
        let last = Date().addingTimeInterval(-6 * 86_400 - 60)
        #expect(StatusPresentation(.driveNotConnected(name: "SSD", last: last)).title == "Not connected, last backed up 6 days ago")
        #expect(OverallStatus.driveNotConnected(name: "SSD", last: nil).shortText == "Not Connected")
    }
}

struct OverviewReviewTests {
    private func entry(_ set: UUID, _ name: String, _ path: String) -> ReviewEntry {
        ReviewEntry(setID: set, setName: name, item: ReviewItem(id: path, path: path, kind: .secretInExcluded))
    }

    @Test func everyItemIsReachableUnderItsSet() {
        let a = UUID(), b = UUID()
        let entries = (0..<30).map { entry(a, "A", "/f\($0)") } + [entry(b, "B", "/.env")]
        let groups = ReviewGroup.grouped(entries)
        #expect(groups.map(\.name) == ["A", "B"])
        #expect(groups.map(\.entries.count) == [30, 1])
        #expect(groups.last?.entries.first?.item.path == "/.env")
    }

    @Test func aListThatFitsOffersNothingMore() {
        #expect(!ReviewGroup.needsShowAll(count: ReviewGroup.overviewLimit))
        #expect(ReviewGroup.needsShowAll(count: ReviewGroup.overviewLimit + 1))
    }

    @MainActor @Test func arrivingFromNeedsAttentionLandsOnStatus() {
        SetPaneMemory.last = .safety
        SetPaneMemory.openOnStatus()
        #expect(SetPaneMemory.last == .status)
    }
}
