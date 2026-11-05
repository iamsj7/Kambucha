import Testing
import Foundation
@testable import Mirror

@Suite struct PageLayoutTests {
    private let column = PageLayout.readingWidth + 2 * PageLayout.inset

    @Test func aNarrowPageHasNoExtraMargin() {
        #expect(PageLayout.readingMargin(in: 530) == 0)
        #expect(PageLayout.readingMargin(in: column) == 0)
    }

    @Test func aWidePageCentresItsColumnAtTheReadingWidth() {
        for width: CGFloat in [column + 2, 870, 1570] {
            let margin = PageLayout.readingMargin(in: width)
            #expect(width - 2 * (margin + PageLayout.inset) == PageLayout.readingWidth)
        }
    }

    @Test func theToolbarGivesUpItsSegmentsBelowTheRoomyWidth() {
        #expect(!PageLayout.hasRoomyToolbar(width: 530))
        #expect(PageLayout.hasRoomyToolbar(width: 810))   // the window's default size
        #expect(!PageLayout.hasWordyToolbar(width: 810))
        #expect(PageLayout.hasWordyToolbar(width: 1570))
    }

    @Test func aCardRoundsOnlyItsOuterCorners() {
        #expect(PageCard.Position(index: 0, count: 1) == .only)
        #expect(PageCard.Position(index: 0, count: 3) == .first)
        #expect(PageCard.Position(index: 1, count: 3) == .middle)
        #expect(PageCard.Position(index: 2, count: 3) == .last)
        #expect(PageCard.Position.only.roundsTop && PageCard.Position.only.roundsBottom)
        #expect(PageCard.Position.first.roundsTop && !PageCard.Position.first.roundsBottom)
        #expect(!PageCard.Position.middle.roundsTop && !PageCard.Position.middle.roundsBottom)
        #expect(!PageCard.Position.last.roundsTop && PageCard.Position.last.roundsBottom)
    }
}

@Suite struct CoverageLayoutTests {
    @Test func aFewColumnsShareTheWidthUpToTheirMaximum() {
        let layout = CoverageLayout(available: 870, columns: 3)
        #expect(layout.column > CoverageLayout.fixedColumn)
        #expect(layout.column <= CoverageLayout.maxColumn)
        #expect(layout.name >= CoverageLayout.minName)
        #expect(layout.width == 870)
        #expect(layout.name + 3 * layout.column <= layout.width)
    }

    @Test func oneColumnOnAWideWindowStopsAtBothMaximums() {
        let layout = CoverageLayout(available: 1570, columns: 1)
        #expect(layout.column == CoverageLayout.maxColumn)
        #expect(layout.name == CoverageLayout.maxName)
        #expect(layout.width == 1570)   // the row lines still span the page
    }

    @Test func columnsFillTheWidthExactlyWhileTheyAreBelowTheirMaximum() {
        let layout = CoverageLayout(available: 1000, columns: 4)
        #expect(layout.name == CoverageLayout.minName)
        #expect(layout.name + 4 * layout.column == 1000)
    }

    @Test func tooManyColumnsFallBackToTheFixedWidthAndScroll() {
        let layout = CoverageLayout(available: 870, columns: 10)
        #expect(layout.column == CoverageLayout.fixedColumn)
        #expect(layout.name == CoverageLayout.minName)
        #expect(layout.width == CoverageLayout.minName + 10 * CoverageLayout.fixedColumn)
        #expect(layout.width > 870)
    }

    @Test func theSmallestWindowStillFitsTwoColumns() {
        let layout = CoverageLayout(available: 530, columns: 2)
        #expect(layout.column >= CoverageLayout.minColumn)
        #expect(layout.width == 530)
    }

    @Test func noMeasurementYetAndNoColumnsDontBreakIt() {
        #expect(CoverageLayout(available: 0, columns: 3).column == CoverageLayout.fixedColumn)
        #expect(CoverageLayout(available: 870, columns: 0).width == 870)
    }
}

@Suite struct ArchivePathTests {
    @Test func aShallowPathIsShownWhole() {
        #expect(ArchivePath.text(set: "Projects", folder: []) == "Projects")
        #expect(ArchivePath.text(set: "Projects", folder: ["client", "src"]) == "Projects / client / src")
    }

    @Test func aDeepPathKeepsTheSetAndTheFarEnd() {
        #expect(ArchivePath.text(set: "Projects", folder: ["a", "b", "c", "d"]) == "Projects / … / c / d")
    }

    @Test func noSetIsNoPath() {
        #expect(ArchivePath.text(set: nil, folder: []) == "")
    }
}
