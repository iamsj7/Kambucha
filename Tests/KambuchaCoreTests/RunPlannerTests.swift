import Testing
import Foundation
@testable import KambuchaCore

@Suite struct RunPlannerTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private let hour: TimeInterval = 3600
    private var iCloud: DestinationProfile { .profile(for: Destination(name: "i", kind: .iCloudFolder)) }
    private var cloud: DestinationProfile { .profile(for: Destination(name: "g", kind: .googleDrive)) }

    private func state(fullPassAgo: TimeInterval?) -> SetState {
        var s = SetState()
        s.lastFullPass = fullPassAgo.map { now.addingTimeInterval(-$0) }
        return s
    }

    @Test func fullPassDueAfter24HoursOnICloud() {
        #expect(!RunPlanner.plan(state: state(fullPassAgo: 23 * hour), scope: .nothing, profile: iCloud, now: now).isDailyPass)
        #expect(RunPlanner.plan(state: state(fullPassAgo: 24 * hour), scope: .nothing, profile: iCloud, now: now).isDailyPass)
    }

    @Test func fullPassDueAfter7DaysOnCloud() {
        #expect(!RunPlanner.plan(state: state(fullPassAgo: 6 * 24 * hour), scope: .nothing, profile: cloud, now: now).isDailyPass)
        #expect(RunPlanner.plan(state: state(fullPassAgo: 7 * 24 * hour), scope: .nothing, profile: cloud, now: now).isDailyPass)
    }

    @Test func neverRunMeansFullPassDue() {
        let p = RunPlanner.plan(state: SetState(), scope: .nothing, profile: iCloud, now: now)
        #expect(p.isDailyPass && p.scope == .wholeSet)
    }

    @Test func deepDueAfter30Days() {
        var s = state(fullPassAgo: hour)
        s.lastDeepCheck = now.addingTimeInterval(-29 * 24 * hour)
        #expect(!RunPlanner.plan(state: s, scope: .nothing, profile: iCloud, now: now).isDeepDue)
        s.lastDeepCheck = now.addingTimeInterval(-30 * 24 * hour)
        #expect(RunPlanner.plan(state: s, scope: .nothing, profile: iCloud, now: now).isDeepDue)
    }

    @Test func neverDeepCheckedIsNotDue() {
        #expect(!RunPlanner.plan(state: SetState(), scope: .nothing, profile: iCloud, now: now).isDeepDue)
    }

    @Test func nothingWithNoDailyDueStaysNothing() {
        #expect(RunPlanner.plan(state: state(fullPassAgo: hour), scope: .nothing, profile: iCloud, now: now).scope == .nothing)
    }

    @Test func nothingWithFullPassDueWidensToWholeSet() {
        #expect(RunPlanner.plan(state: state(fullPassAgo: 25 * hour), scope: .nothing, profile: iCloud, now: now).scope == .wholeSet)
    }

    @Test func projectsStayScopedWhenNoPassIsDue() {
        let p = RunPlanner.plan(state: state(fullPassAgo: hour), scope: .projects(["a"]), profile: iCloud, now: now)
        #expect(p.scope == .projects(["a"]) && !p.isDailyPass)
    }

    @Test func heldSetWidensAnyWorkToWholeSetButNotNothing() {
        var s = state(fullPassAgo: hour)
        s.heldDeletions = 5
        #expect(RunPlanner.plan(state: s, scope: .projects(["a"]), profile: iCloud, now: now).scope == .wholeSet)
        #expect(RunPlanner.plan(state: s, scope: .nothing, profile: iCloud, now: now).scope == .nothing)
    }

    @Test func anOwedWholeSetRunIsNotForgotten() {
        var s = state(fullPassAgo: hour)
        s.wholeSetOwed = true
        #expect(RunPlanner.plan(state: s, scope: .nothing, profile: iCloud, now: now).scope == .wholeSet)
    }

    @Test func iCloudPairsGoFirstThenLeastRecentlyFinished() {
        func pair() -> PairID { PairID(set: UUID(), destination: UUID()) }
        func finished(_ ago: TimeInterval?) -> SetState {
            var s = SetState(); s.lastFinished = ago.map { now.addingTimeInterval(-$0) }; return s
        }
        let (a, b, c, d, e) = (pair(), pair(), pair(), pair(), pair())
        let order = RunPlanner.order([(a, .googleDrive, finished(5)), (b, .iCloudFolder, finished(1)),
                                      (c, .oneDrive, finished(50)), (d, .iCloudFolder, finished(9)),
                                      (e, .googleDrive, finished(nil))])
        #expect(order == [d, b, e, c, a])
    }
}
