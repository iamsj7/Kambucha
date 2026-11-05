import Testing
import Foundation
@testable import KambuchaCore

private func aSet() -> BackupSet { BackupSet(name: "Docs", source: URL(fileURLWithPath: "/tmp/docs"), presets: ["node"]) }

@Test func newSetIsNotAcceptedUntilAcceptPreview() {
    var set = aSet()
    #expect(set.acceptedFingerprint == nil)
    #expect(!set.isPreviewAccepted)
    set.acceptPreview()
    #expect(set.isPreviewAccepted)
    #expect(set.acceptedFingerprint == set.previewFingerprint)
}

@Test func ruleStackAndSwitchChangesReopenThePreview() {
    var set = aSet()
    set.acceptPreview()
    set.rules.append(UserRule(pattern: "*.log", action: .exclude))
    #expect(!set.isPreviewAccepted)
    set.acceptPreview()
    #expect(set.isPreviewAccepted)
    set.presets.insert("ios")
    #expect(!set.isPreviewAccepted)
    set.acceptPreview()
    set.backupSecrets = false
    #expect(!set.isPreviewAccepted)
    set.acceptPreview()
    set.backupGit = false
    #expect(!set.isPreviewAccepted)
}

@Test func renamePauseAndDestinationsKeepTheAcceptance() {
    var set = aSet()
    set.acceptPreview()
    set.name = "Renamed"; set.isPaused = true; set.destinationIDs = [UUID()]; set.archiveDays = 90
    #expect(set.isPreviewAccepted)
}

@Test func fingerprintDoesNotIncludeItself() {
    var set = aSet()
    let before = set.previewFingerprint
    set.acceptPreview()
    #expect(set.previewFingerprint == before)
    set.acceptPreview()
    #expect(set.isPreviewAccepted)
}

@Test func acceptanceSurvivesRelaunchThroughTheConfigStore() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("kambucha-accept-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    var set = aSet()
    set.acceptPreview()
    try ConfigStore(root: root).saveSets([set])
    let loaded = try ConfigStore(root: root).loadSets()
    #expect(loaded == [set])
    #expect(loaded[0].isPreviewAccepted)
}

@Test func aSetsFileWrittenBeforeTheFieldExistedStillLoadsAsUnaccepted() throws {
    let json = """
    [{"id":"\(UUID().uuidString)","name":"Docs","source":"file:///tmp/docs","presets":[],"backupSecrets":true,
      "backupGit":true,"rules":[],"deletion":{"minFiles":100,"percent":5,"absoluteMax":2000},
      "archiveDays":30,"isPaused":false,"destinationIDs":[]}]
    """
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("kambucha-accept-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data(json.utf8).write(to: root.appendingPathComponent("sets.json"))
    let loaded = try ConfigStore(root: root).loadSets()
    #expect(loaded.count == 1)
    #expect(loaded[0].acceptedFingerprint == nil)
    #expect(!loaded[0].isPreviewAccepted)
}

@Test func draftMergeTakesAnAcceptanceMadeElsewhere() {
    let saved = aSet()
    var latest = saved
    latest.acceptPreview()
    let merged = SetDraftMerge.merge(draft: saved, previouslySaved: saved, latest: latest)
    #expect(merged.isPreviewAccepted)
}
