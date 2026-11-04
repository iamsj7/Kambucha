import Testing
import Foundation
@testable import MirrorCore

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
    func heldDeletions(set: BackupSet) async throws -> [String] { files }
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

// MARK: Acceptance

@Test func backupIsBlockedUntilPreviewAccepted() {
    let store = PreviewAcceptanceStore(root: tempDir())
    let set = aSet()
    #expect(!store.isAccepted(set))
    store.accept(set)
    #expect(store.isAccepted(set))
}

@Test func ruleChangeReopensThePreview() {
    let store = PreviewAcceptanceStore(root: tempDir())
    var set = aSet()
    store.accept(set)
    set.rules.append(UserRule(pattern: "*.log", action: .exclude))
    #expect(!store.isAccepted(set))
    store.accept(set)
    #expect(store.isAccepted(set))
    set.presets.insert("node")
    #expect(!store.isAccepted(set))
}

@Test func acceptanceSurvivesRelaunchAndIgnoresRenameOnly() {
    let root = tempDir()
    var set = aSet()
    PreviewAcceptanceStore(root: root).accept(set)
    set.name = "Renamed"
    #expect(PreviewAcceptanceStore(root: root).isAccepted(set))
}

// MARK: Deletion review

@MainActor @Test func deletionReviewShowsCountAndPassesReviewedCount() async {
    let set = aSet()
    let r = DeletionReview(set: set, provider: FakeDryRun(files: ["a", "b", "c"]))
    await r.load()
    #expect(r.files == ["a", "b", "c"])
    #expect(r.count == 3)
    #expect(r.allowOnceArguments == ["--allow-deletes", set.id.uuidString, "3"])
}

@MainActor @Test func deletionReviewCannotAllowBeforeListLoads() {
    let r = DeletionReview(set: aSet(), provider: FakeDryRun(files: ["a"]))
    #expect(r.allowOnceArguments == nil)
}

@MainActor @Test func deletionReviewWithNothingHeldCannotAllow() async {
    let r = DeletionReview(set: aSet(), provider: FakeDryRun(files: []))
    await r.load()
    #expect(r.allowOnceArguments == nil)
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
    #expect(DestinationRules.notConnectedText(lastBackedUp: nil, now: now) == "Not connected, not backed up yet")
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
