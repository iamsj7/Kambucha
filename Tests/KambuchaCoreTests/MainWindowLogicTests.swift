import Testing
import Foundation
@testable import KambuchaCore

// MARK: Fakes

private struct FakePreview: PreviewProviding {
    var groups: [PreviewGroup]
    func preview(set: BackupSet) async throws -> PreviewResult {
        // A group is counted as included unless an exclude rule for its pattern is on the set.
        let excluded = Set(set.rules.filter { $0.action == .exclude }.map(\.pattern))
        let gs = groups.map { g -> PreviewGroup in var c = g; c.included = !excluded.contains(g.pattern); return c }
        let inc = gs.filter(\.included), skip = gs.filter { !$0.included }
        return PreviewResult(includedBytes: inc.reduce(0) { $0 + $1.bytes }, skippedBytes: skip.reduce(0) { $0 + $1.bytes },
                             includedFiles: inc.reduce(0) { $0 + $1.fileCount }, groups: gs,
                             decisions: [ReviewItem(id: "d1", path: "vendor/.env", kind: .secretInExcluded)])
    }
    func rule(for group: PreviewGroup, included: Bool) -> UserRule {
        UserRule(pattern: group.pattern, action: included ? .include : .exclude)
    }
}

private struct FailingPreview: PreviewProviding {
    func preview(set: BackupSet) async throws -> PreviewResult { throw CocoaError(.fileReadNoSuchFile) }
    func rule(for group: PreviewGroup, included: Bool) -> UserRule { UserRule(pattern: "", action: .exclude) }
}

private final class FakeInspector: MirroredExcludeInspecting, @unchecked Sendable {
    var matches: [String]
    var archived: [String] = []
    init(matches: [String]) { self.matches = matches }
    func mirroredFiles(matching excludes: [UserRule], set: BackupSet) async throws -> [String] { matches }
    func archive(_ files: [String], set: BackupSet) async throws { archived = files }
}

private struct FakeDryRun: DeletionDryRunProviding {
    var files: [String]
    var gitCount = 0
    func heldDeletions(set: BackupSet, destination: Destination) async throws -> HeldFiles { HeldFiles(files: files, gitCount: gitCount) }
}

private let groups = [
    PreviewGroup(id: "nm", title: "node_modules", fileCount: 900, bytes: 9_000, included: true, pattern: "node_modules/"),
    PreviewGroup(id: "src", title: "Source", fileCount: 100, bytes: 1_000, included: true, pattern: "src/"),
]

private func tempDir() -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("mw-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

private func aSet() -> BackupSet { BackupSet(name: "Projects", source: URL(fileURLWithPath: "/tmp/p")) }

// MARK: Preview controller

@MainActor @Test func previewLoadsTotals() async {
    let c = PreviewController(set: aSet(), provider: FakePreview(groups: groups), inspector: nil)
    await c.load()
    #expect(c.result?.includedBytes == 10_000)
    #expect(c.result?.decisions.count == 1)
    #expect(c.loadError == nil)
}

@MainActor @Test func previewReportsFailure() async {
    let c = PreviewController(set: aSet(), provider: FailingPreview(), inspector: nil)
    await c.load()
    #expect(c.result == nil)
    #expect(c.loadError != nil)
}

@MainActor @Test func untickingSavesARuleAndRecomputes() async {
    let c = PreviewController(set: aSet(), provider: FakePreview(groups: groups), inspector: nil)
    await c.load()
    var saved: BackupSet?
    c.onSetChanged = { saved = $0 }
    await c.setIncluded(false, for: groups[0])
    #expect(c.set.rules == saved?.rules)
    #expect(c.set.rules.map(\.pattern) == ["node_modules/"])
    #expect(c.set.rules.first?.action == .exclude)
    #expect(c.result?.skippedBytes == 9_000)
}

@MainActor @Test func tickingAgainReplacesTheRuleForThatPattern() async {
    let c = PreviewController(set: aSet(), provider: FakePreview(groups: groups), inspector: nil)
    await c.load()
    await c.setIncluded(false, for: groups[0])
    await c.setIncluded(true, for: groups[0])
    #expect(c.set.rules.count == 1)
    #expect(c.set.rules.first?.action == .include)
}

@MainActor @Test func newExcludeMatchingMirroredFilesAsksWhatToDo() async {
    let inspector = FakeInspector(matches: ["node_modules/a.js", "node_modules/b.js"])
    let c = PreviewController(set: aSet(), provider: FakePreview(groups: groups), inspector: inspector)
    await c.load()
    await c.setIncluded(false, for: groups[0])
    #expect(c.pendingImpact?.count == 2)
    await c.resolveImpact(.moveToArchive)
    #expect(inspector.archived.count == 2)
    #expect(c.pendingImpact == nil)
}

@MainActor @Test func leavingMirroredFilesArchivesNothing() async {
    let inspector = FakeInspector(matches: ["x"])
    let c = PreviewController(set: aSet(), provider: FakePreview(groups: groups), inspector: inspector)
    await c.load()
    await c.setIncluded(false, for: groups[0])
    await c.resolveImpact(.leaveInPlace)
    #expect(inspector.archived.isEmpty)
    #expect(c.pendingImpact == nil)
}

@MainActor @Test func tickingIncludeNeverAsksAboutArchive() async {
    let inspector = FakeInspector(matches: ["x"])
    let c = PreviewController(set: aSet(), provider: FakePreview(groups: groups), inspector: inspector)
    await c.load()
    await c.setIncluded(true, for: groups[1])
    #expect(c.pendingImpact == nil)
}

// MARK: Deletion review

private let driveA = Destination(name: "Drive", kind: .googleDrive)
private let driveB = Destination(name: "iCloud", kind: .iCloudFolder)

// MARK: Any rule change asks about what's already mirrored

@MainActor private func changedSet(_ change: (inout BackupSet) -> Void) -> BackupSet {
    var set = aSet()
    set.acceptPreview()
    change(&set)
    return set
}

@MainActor @Test func aPresetTurnedOnAsksAboutMirroredFiles() async {
    let inspector = FakeInspector(matches: ["a/node_modules/x"])
    let c = PreviewController(set: changedSet { $0.presets.insert("node") }, provider: FakePreview(groups: groups), inspector: inspector)
    await c.open()
    #expect(c.pendingImpact == ["a/node_modules/x"])
    await c.resolveImpact(.moveToArchive)
    #expect(inspector.archived == ["a/node_modules/x"])
}

@MainActor @Test func theSecretsSwitchAsksAboutMirroredFiles() async {
    let c = PreviewController(set: changedSet { $0.backupSecrets = false }, provider: FakePreview(groups: groups),
                              inspector: FakeInspector(matches: [".env"]))
    await c.open()
    #expect(c.pendingImpact == [".env"])
}

@MainActor @Test func aTypedRuleAsksAboutMirroredFiles() async {
    let set = changedSet { $0.rules.append(UserRule(pattern: "*.log", action: .exclude)) }
    let c = PreviewController(set: set, provider: FakePreview(groups: groups), inspector: FakeInspector(matches: ["a.log"]))
    await c.open()
    #expect(c.pendingImpact == ["a.log"])
}

/// A set the owner already accepted changed nothing, so what they left in place isn't asked about again.
@MainActor @Test func openingAnUnchangedSetAsksNothing() async {
    let c = PreviewController(set: changedSet { _ in }, provider: FakePreview(groups: groups), inspector: FakeInspector(matches: ["a.log"]))
    await c.open()
    #expect(c.result != nil && c.pendingImpact == nil)
}

@MainActor @Test func aFirstPreviewWithNothingMirroredAsksNothing() async {
    let c = PreviewController(set: aSet(), provider: FakePreview(groups: groups), inspector: FakeInspector(matches: []))
    await c.open()
    #expect(c.pendingImpact == nil)
}

@MainActor @Test func deletionReviewShowsEachHeldDestinationSeparately() async {
    let set = aSet()
    let r = DeletionReview(set: set, destinations: [driveA, driveB], provider: FakeDryRun(files: ["a", "b", "c"]))
    await r.load()
    #expect(r.entries.map(\.destination.id) == [driveA.id, driveB.id])
    #expect(r.entries.allSatisfy { $0.isLoaded && $0.files == ["a", "b", "c"] && $0.count == 3 })
}

@MainActor @Test func allowOnceNamesTheDestinationAndCountsOnlyThatPairsNonGitFiles() async {
    let set = aSet()
    let r = DeletionReview(set: set, destinations: [driveA], provider: FakeDryRun(files: ["a", "b", "sub/.git/x", ".git/y"]))
    await r.load()
    #expect(r.allowOnceArguments(for: driveA.id) == ["--allow-deletes", set.id.uuidString, driveA.id.uuidString, "2"])
    #expect(r.allowOnceArguments(for: driveB.id) == nil)
}

@MainActor @Test func allowOnceIsNilUntilThatDestinationListLoaded() async {
    let r = DeletionReview(set: aSet(), destinations: [driveA], provider: FakeDryRun(files: ["a"]))
    #expect(r.allowOnceArguments(for: driveA.id) == nil)
}

/// A hold over nothing but `.git`, or with nothing left to delete, has to be releasable too.
@MainActor @Test func anEmptyListCanStillBeReleasedWithACountOfZero() async {
    let set = aSet()
    let empty = DeletionReview(set: set, destinations: [driveA], provider: FakeDryRun(files: [], gitCount: 12))
    await empty.load()
    #expect(empty.allowOnceArguments(for: driveA.id) == ["--allow-deletes", set.id.uuidString, driveA.id.uuidString, "0"])
    #expect(empty.entries[0].gitCount == 12)
}

@MainActor @Test func oneDestinationFailingDoesNotApproveItsSibling() async {
    struct Half: DeletionDryRunProviding {
        func heldDeletions(set: BackupSet, destination: Destination) async throws -> HeldFiles {
            if destination.id == driveA.id { throw AgentFailure.busy }
            return HeldFiles(files: ["z"], gitCount: 0)
        }
    }
    let r = DeletionReview(set: aSet(), destinations: [driveA, driveB], provider: Half())
    await r.load()
    #expect(r.allowOnceArguments(for: driveA.id) == nil)
    #expect(r.entries[0].loadError != nil)
    #expect(r.allowOnceArguments(for: driveB.id)?.last == "1")
}

@Test func onlyDestinationsHoldingDeletionsAreReviewed() {
    var set = aSet(); set.destinationIDs = [driveA.id, driveB.id]
    var held = SetState(); held.heldDeletions = 4
    let states = [PairID(set: set.id, destination: driveA.id): held, PairID(set: set.id, destination: driveB.id): SetState()]
    #expect(DeletionReview.heldDestinations(set: set, destinations: [driveA, driveB], states: states).map(\.id) == [driveA.id])
}

// MARK: Destination rules

@Test func encryptionDefaultsAndLocks() {
    #expect(DestinationRules.encryptionDefault(.googleDrive))
    #expect(DestinationRules.encryptionDefault(.oneDrive))
    #expect(!DestinationRules.encryptionDefault(.iCloudFolder))
    #expect(DestinationRules.encryptionOffered(.googleDrive))
    #expect(!DestinationRules.encryptionOffered(.iCloudFolder))
    #expect(DestinationRules.encryptionOffWarning.contains("provider can read"))
}

@Test func needsGoogleClientID() {
    #expect(DestinationRules.needsClientID(.googleDrive))
    #expect(!DestinationRules.needsClientID(.oneDrive))
}

@Test func externalDriveStatusText() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let six = now.addingTimeInterval(-6 * 86_400)
    #expect(DestinationRules.notConnectedText(lastBackedUp: six, now: now) == "Not connected, last backed up 6 days ago")
    #expect(DestinationRules.notConnectedText(lastBackedUp: now.addingTimeInterval(-86_400), now: now) == "Not connected, last backed up 1 day ago")
    #expect(DestinationRules.notConnectedText(lastBackedUp: now, now: now) == "Not connected, last backed up today")
    #expect(DestinationRules.notConnectedText(lastBackedUp: nil, now: now) == "Not connected yet")
}

@Test func exFATWarns() {
    #expect(DestinationRules.filesystemWarning("exfat") != nil)
    #expect(DestinationRules.filesystemWarning("ExFAT") != nil)
    #expect(DestinationRules.filesystemWarning("apfs") == nil)
}

// MARK: Failure wording

@Test func kitPasteIsOfferedForLostVaultAndSignIn() {
    #expect(SetupFailureText.needsRecoveryKit(RemoteSetupError.vaultLostNeedsRecoveryKit))
    #expect(SetupFailureText.needsRecoveryKit(RemoteSetupError.signInLostNeedsRecoveryKit))
    #expect(!SetupFailureText.needsRecoveryKit(RemoteSetupError.noToken))
    #expect(!SetupFailureText.message(for: RemoteSetupError.vaultLostNeedsRecoveryKit).isEmpty)
    #expect(!SetupFailureText.message(for: GuardFailure.sourceInsideICloud).isEmpty)
    #expect(!SetupFailureText.message(for: CocoaError(.fileNoSuchFile)).isEmpty)
}

// MARK: Adding a set

@Test func newSetUsesFolderNameAndDetectedPresets() throws {
    let dir = tempDir().appendingPathComponent("Work", isDirectory: true)
    try FileManager.default.createDirectory(at: dir.appendingPathComponent("app"), withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: dir.appendingPathComponent("app/package.json").path, contents: Data("{}".utf8))
    let set = NewSet.make(folder: dir, presets: try PresetCatalog.all(), destinations: [])
    #expect(set.name == "Work")
    #expect(set.presets.contains("node"))
    #expect(set.source == dir)
}

// MARK: Fix round 1

@Test func badSetNameGetsASanitizedSuggestion() {
    #expect(SetNaming.suggestion(for: "a/b") == "a-b")
    #expect(SetNaming.suggestion(for: "  ") == "Set")
    #expect(SetNaming.suggestion(for: "Projects") == nil)
    #expect(SetNaming.suggestion(for: " Projects ") == nil)   // trimming alone is not a bad name
}

@MainActor @Test func previewOfANewSetDoesNotPersistEdits() async {
    let c = PreviewController(set: aSet(), provider: FakePreview(groups: groups), inspector: nil, persistsEdits: false)
    await c.load()
    var called = false
    c.onSetChanged = { _ in called = true }
    await c.setIncluded(false, for: groups[0])
    #expect(!called)
    #expect(c.set.rules.count == 1)   // the candidate still holds the edit
}

@Test func staleDraftNeverUndoesAnExternalPause() {
    let base = aSet()
    var draft = base
    draft.archiveDays = 60                    // the owner is editing this field
    var latest = base
    latest.isPaused = true                    // the menu bar paused the set meanwhile
    let merged = SetDraftMerge.merge(draft: draft, previouslySaved: base, latest: latest)
    #expect(merged.isPaused)
    #expect(merged.archiveDays == 60)
}

@Test func mergeLeavesDraftAloneWhenNothingChangedOutside() {
    let base = aSet()
    var draft = base
    draft.archiveDays = 60
    #expect(SetDraftMerge.merge(draft: draft, previouslySaved: base, latest: base) == draft)
}

@Test func runNowRunsAcceptedSetsAndReportsTheRest() {
    let a = BackupSet(name: "A", source: URL(fileURLWithPath: "/a"))
    let b = BackupSet(name: "B", source: URL(fileURLWithPath: "/b"))
    var paused = BackupSet(name: "C", source: URL(fileURLWithPath: "/c")); paused.isPaused = true
    let plan = RunNowPlan.make(sets: [a, b, paused], target: nil, isAccepted: { $0.id == a.id })
    #expect(plan.run == [a.id])
    #expect(plan.unaccepted == ["B"])
    let one = RunNowPlan.make(sets: [a, b], target: b.id, isAccepted: { $0.id == a.id })
    #expect(one.run.isEmpty)
    #expect(one.unaccepted == ["B"])
}

// MARK: Fix round 2

@Test func failedRunLeavesNothingQueuedAndRunAllLaunchesOnce() {
    let a = UUID(), b = UUID()
    var q = RunQueue()
    q.start(.sets([a, b]))                  // first launch is a; b waits
    #expect(q.next(afterExit: 1) == nil)    // a failed: nothing may be left behind
    #expect(q.waiting.isEmpty)
    q.start(.all)                           // a later run-all
    #expect(q.waiting.isEmpty)
    #expect(q.next(afterExit: 0) == nil)    // launches once, no leftover set
}

@Test func queueDrainsInOrderOnSuccess() {
    let a = UUID(), b = UUID(), c = UUID()
    var q = RunQueue()
    q.start(.sets([a, b, c]))
    #expect(q.first == a)
    #expect(q.next(afterExit: 0) == b)
    #expect(q.next(afterExit: 0) == c)
    #expect(q.next(afterExit: 0) == nil)
}

@Test func inProgressEmptyRuleSurvivesAnExternalRulesChange() {
    let base = aSet()
    var draft = base
    draft.rules = [UserRule(pattern: "", action: .exclude)]
    var latest = base
    latest.rules = [UserRule(pattern: "*.log", action: .exclude)]
    let merged = SetDraftMerge.merge(draft: draft, previouslySaved: base, latest: latest)
    #expect(merged.rules.map(\.pattern) == ["*.log", ""])
}
