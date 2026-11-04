import Testing
@testable import MirrorCore

private func paths(_ count: Int, prefix: String = "docs") -> [String] {
    (0..<count).map { "\(prefix)/file\($0).txt" }
}

private let defaultPolicy = DeletionPolicy()

@Test func smallSetNeverHoldsUnderMinimum() {
    let decision = DeletionGate.decide(deletions: paths(99), totalFiles: 100,
                                       policy: defaultPolicy, allowOnce: false)
    #expect(decision == .proceed(maxDelete: 109))
}

@Test func holdsAtMinimumAndOverPercent() {
    let decision = DeletionGate.decide(deletions: paths(100), totalFiles: 1_000,
                                       policy: defaultPolicy, allowOnce: false)
    #expect(decision == .hold(count: 100))
}

@Test func underPercentProceeds() {
    let decision = DeletionGate.decide(deletions: paths(100), totalFiles: 5_000,
                                       policy: defaultPolicy, allowOnce: false)
    #expect(decision == .proceed(maxDelete: 110))
}

@Test func absoluteMaxHoldsLargeSet() {
    let decision = DeletionGate.decide(deletions: paths(2_001), totalFiles: 500_000,
                                       policy: defaultPolicy, allowOnce: false)
    #expect(decision == .hold(count: 2_001))
}

@Test func exactlyAbsoluteMaxProceeds() {
    let decision = DeletionGate.decide(deletions: paths(2_000), totalFiles: 500_000,
                                       policy: defaultPolicy, allowOnce: false)
    #expect(decision == .proceed(maxDelete: 2_010))
}

@Test func gitFilesDoNotCount() {
    let deletions = paths(5_000, prefix: "flowapp/.git/objects")
    let decision = DeletionGate.decide(deletions: deletions, totalFiles: 500_000,
                                       policy: defaultPolicy, allowOnce: false)
    #expect(decision == .proceed(maxDelete: 5_010))
}

@Test func nestedGitDoesNotCount() {
    let deletions = paths(3_000, prefix: "a/b/.git/objects")
    let decision = DeletionGate.decide(deletions: deletions, totalFiles: 500_000,
                                       policy: defaultPolicy, allowOnce: false)
    #expect(decision == .proceed(maxDelete: 3_010))
}

@Test func allowOnceProceeds() {
    let decision = DeletionGate.decide(deletions: paths(5_000), totalFiles: 5_000,
                                       policy: defaultPolicy, allowOnce: true)
    #expect(decision == .proceed(maxDelete: 5_010))
}

@Test func proceedSetsMaxDeleteToActualCountPlusMargin() {
    // 60 non-git plus 40 .git files = 100 total; non-git count stays under the rule.
    let deletions = paths(60) + paths(40, prefix: "repo/.git/refs")
    let decision = DeletionGate.decide(deletions: deletions, totalFiles: 1_000,
                                       policy: defaultPolicy, allowOnce: false)
    #expect(decision == .proceed(maxDelete: 110))
}

@Test func zeroTotalHolds() {
    let decision = DeletionGate.decide(deletions: paths(100), totalFiles: 0,
                                       policy: defaultPolicy, allowOnce: false)
    #expect(decision == .hold(count: 100))
}
