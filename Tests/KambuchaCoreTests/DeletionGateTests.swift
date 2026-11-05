import Testing
@testable import KambuchaCore

private func paths(_ count: Int, prefix: String = "docs") -> [String] {
    (0..<count).map { "\(prefix)/file\($0).txt" }
}

private let defaultPolicy = DeletionPolicy()

@Test func smallSetNeverHoldsUnderMinimum() {
    let decision = DeletionGate.decide(deletions: paths(99), totalFiles: 100,
                                       policy: defaultPolicy, approvedDeletions: nil)
    #expect(decision == .proceed(maxDelete: 109))
}

@Test func holdsAtMinimumAndOverPercent() {
    let decision = DeletionGate.decide(deletions: paths(100), totalFiles: 1_000,
                                       policy: defaultPolicy, approvedDeletions: nil)
    #expect(decision == .hold(count: 100))
}

@Test func underPercentProceeds() {
    let decision = DeletionGate.decide(deletions: paths(100), totalFiles: 5_000,
                                       policy: defaultPolicy, approvedDeletions: nil)
    #expect(decision == .proceed(maxDelete: 110))
}

@Test func absoluteMaxHoldsLargeSet() {
    let decision = DeletionGate.decide(deletions: paths(2_001), totalFiles: 500_000,
                                       policy: defaultPolicy, approvedDeletions: nil)
    #expect(decision == .hold(count: 2_001))
}

@Test func exactlyAbsoluteMaxProceeds() {
    let decision = DeletionGate.decide(deletions: paths(2_000), totalFiles: 500_000,
                                       policy: defaultPolicy, approvedDeletions: nil)
    #expect(decision == .proceed(maxDelete: 2_010))
}

@Test func exactlyFivePercentProceeds() {
    let decision = DeletionGate.decide(deletions: paths(100), totalFiles: 2_000,
                                       policy: defaultPolicy, approvedDeletions: nil)
    #expect(decision == .proceed(maxDelete: 110))
}

@Test func gitFilesDoNotCount() {
    let deletions = paths(5_000, prefix: "flowapp/.git/objects")
    let decision = DeletionGate.decide(deletions: deletions, totalFiles: 500_000,
                                       policy: defaultPolicy, approvedDeletions: nil)
    #expect(decision == .proceed(maxDelete: 5_010))
}

@Test func nestedGitDoesNotCount() {
    let deletions = paths(3_000, prefix: "a/b/.git/objects")
    let decision = DeletionGate.decide(deletions: deletions, totalFiles: 500_000,
                                       policy: defaultPolicy, approvedDeletions: nil)
    #expect(decision == .proceed(maxDelete: 3_010))
}

@Test func holdCountExcludesGit() {
    let deletions = paths(150) + paths(5_000, prefix: "repo/.git/objects")
    let decision = DeletionGate.decide(deletions: deletions, totalFiles: 1_000,
                                       policy: defaultPolicy, approvedDeletions: nil)
    #expect(decision == .hold(count: 150))
}

@Test func githubAndGitignoreStillCount() {
    let deletions = paths(100, prefix: ".github/workflows")
    let decision = DeletionGate.decide(deletions: deletions, totalFiles: 1_000,
                                       policy: defaultPolicy, approvedDeletions: nil)
    #expect(decision == .hold(count: 100))
}

@Test func approvalCoversReviewedCountOnly() {
    let approved = DeletionGate.decide(deletions: paths(1_240), totalFiles: 5_000,
                                       policy: defaultPolicy, approvedDeletions: 1_240)
    #expect(approved == .proceed(maxDelete: 1_240))

    let larger = DeletionGate.decide(deletions: paths(1_241), totalFiles: 5_000,
                                     policy: defaultPolicy, approvedDeletions: 1_240)
    #expect(larger == .hold(count: 1_241))
}

@Test func approvalDoesNotApplyWhenNil() {
    let decision = DeletionGate.decide(deletions: paths(1_240), totalFiles: 5_000,
                                       policy: defaultPolicy, approvedDeletions: nil)
    #expect(decision == .hold(count: 1_240))
}

@Test func proceedSetsMaxDeleteToActualCountPlusMargin() {
    // 60 non-git plus 40 .git files = 100 total; non-git count stays under the rule.
    let deletions = paths(60) + paths(40, prefix: "repo/.git/refs")
    let decision = DeletionGate.decide(deletions: deletions, totalFiles: 1_000,
                                       policy: defaultPolicy, approvedDeletions: nil)
    #expect(decision == .proceed(maxDelete: 110))
}

@Test func zeroTotalHolds() {
    let decision = DeletionGate.decide(deletions: paths(100), totalFiles: 0,
                                       policy: defaultPolicy, approvedDeletions: nil)
    #expect(decision == .hold(count: 100))
}

@Test func anApprovedRunGetsNoMarginBeyondTheReviewedCount() {
    let git = (0..<3).map { "p/.git/objects/\($0)" }
    let files = (0..<200).map { "f\($0)" }
    let decision = DeletionGate.decide(deletions: files + git, totalFiles: 1000, policy: DeletionPolicy(), approvedDeletions: 250)
    #expect(decision == .proceed(maxDelete: 253))
}
