import Testing
import Foundation
import MirrorCore
@testable import Mirror

struct StatusPresentationTests {
    /// A mismatch is a real problem being worked on, so nothing about it may read as calm.
    @Test func aRecordedMismatchIsSaidPlainlyWithTheAttentionSymbol() {
        let p = StatusPresentation(.waitingForDownload(2))
        #expect(p.symbol == StatusPresentation(.attention("x")).symbol)
        #expect(p.title == "Files Didn't Match")
        #expect(p.detail == "Re-checking 2 files that didn't match, waiting for iCloud to download them")
        #expect(OverallStatus.waitingForDownload(2).shortText == "Didn't Match")
    }
}
