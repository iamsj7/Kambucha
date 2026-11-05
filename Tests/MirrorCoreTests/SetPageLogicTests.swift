import Testing
import Foundation
@testable import MirrorCore

struct SetPageLogicTests {
    private func rules(_ n: Int) -> [UserRule] { (0..<n).map { UserRule(pattern: "*.f\($0)", action: .exclude) } }

    @Test func filterKeepsStoredOrderAndNeverReorders() {
        let r = rules(30)
        let ids = RuleFilter.visibleIDs(r, query: ".f1")
        #expect(ids == r.filter { $0.pattern.contains(".f1") }.map(\.id))
        #expect(ids.count == 11)
    }

    @Test func aJustAddedEmptyRuleIsNeverFilteredAway() {
        var r = rules(30)
        let blank = UserRule(pattern: "", action: .exclude)
        r.append(blank)
        #expect(RuleFilter.visibleIDs(r, query: "zzz") == [blank.id])
    }

    @Test func theRowBeingEditedStaysEvenWhenItStopsMatching() {
        let r = rules(30)
        #expect(RuleFilter.visibleIDs(r, query: "zzz", keep: [r[5].id]) == [r[5].id])
    }

    @Test func theFirstAddedRuleIsFoundWhereverItLanded() {
        let r = rules(3)
        let a = UserRule(pattern: "/a", action: .exclude), b = UserRule(pattern: "/b", action: .exclude)
        #expect(RuleFilter.firstAdded(to: r, in: [a, b] + r) == a.id)
        #expect(RuleFilter.firstAdded(to: r, in: r + [b]) == b.id)
        #expect(RuleFilter.firstAdded(to: r, in: r) == nil)
    }

    @Test func smallListsAreNeverFiltered() {
        let r = rules(10)
        #expect(!RuleFilter.offersFilter(ruleCount: 10))
        #expect(RuleFilter.offersFilter(ruleCount: 11))
        #expect(RuleFilter.visibleIDs(r, query: "zzz").count == 10)
    }

    @Test func blankQueryShowsEverything() {
        let r = rules(200)
        #expect(RuleFilter.visibleIDs(r, query: "  ").count == 200)
    }

    @Test func countText() {
        #expect(RuleFilter.countText(total: 24, shown: 24) == "24 rules")
        #expect(RuleFilter.countText(total: 1, shown: 1) == "1 rule")
        #expect(RuleFilter.countText(total: 24, shown: 3) == "3 of 24 rules")
    }

    @Test func bannersShowOnEveryPane() {
        for pane in SetPane.allCases {
            #expect(SetBanners.visible(nameConflict: true, previewAccepted: false, on: pane) == [.nameConflict, .previewNeeded])
            #expect(SetBanners.visible(nameConflict: false, previewAccepted: true, on: pane).isEmpty)
            #expect(SetBanners.visible(nameConflict: false, previewAccepted: false, on: pane) == [.previewNeeded])
        }
    }
}
