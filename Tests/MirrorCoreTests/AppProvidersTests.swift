import Testing
import Foundation
@testable import MirrorCore

// MARK: Fakes

private final class FakeTransport: AgentTransport, @unchecked Sendable {
    var response = Data(#"{"ok":true}"#.utf8)
    var error: (any Error)?
    private(set) var calls: [(subcommand: String, body: Data)] = []
    func call(subcommand: String, body: Data) async throws -> Data {
        calls.append((subcommand, body))
        if let error { throw error }
        return response
    }
}

private func json(_ s: String) -> Data { Data(s.utf8) }
private func bodyText(_ t: FakeTransport) -> String { String(decoding: t.calls[0].body, as: UTF8.self) }

// MARK: Agent client

@Test func archiveListSendsOnlyIdsAndDecodesEntries() async throws {
    let t = FakeTransport()
    t.response = json(#"{"ok":true,"entries":[{"id":"Docs/2026-11-04T10-00/a.txt","setName":"Docs","stamp":"2026-11-04T10:00:00Z","path":"Archive/Docs/2026-11-04T10-00/a.txt","size":42}]}"#)
    let set = UUID(), dest = UUID()
    let entries = try await AgentArchiveClient(transport: t).archiveList(set: set, destination: dest)
    #expect(t.calls.count == 1)
    #expect(t.calls[0].subcommand == "archive-list")
    #expect(bodyText(t).contains(set.uuidString) && bodyText(t).contains(dest.uuidString))
    #expect(entries.count == 1)
    #expect(entries[0].path == "Archive/Docs/2026-11-04T10-00/a.txt" && entries[0].size == 42)
    #expect(entries[0].stamp == utcStamp("2026-11-04T10:00:00Z"))
}

private func utcStamp(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

@Test func archiveRestoreSendsThePathAndTarget() async throws {
    let t = FakeTransport()
    let to = URL(fileURLWithPath: "/Users/me/Restored/a.txt")
    try await AgentArchiveClient(transport: t).archiveRestore(set: UUID(), destination: UUID(),
                                                              path: "Archive/Docs/2026-11-04T10-00/a.txt", to: to)
    #expect(t.calls[0].subcommand == "archive-restore")
    #expect(bodyText(t).contains("Archive/Docs/2026-11-04T10-00/a.txt"))
    #expect(bodyText(t).contains("/Users/me/Restored/a.txt"))
}

@Test func browsingAsksForThePathAndReturnsTheItems() async throws {
    let t = FakeTransport()
    t.response = json(#"{"ok":true,"items":[{"name":"p","isFolder":true,"size":0}]}"#)
    let items = try await AgentArchiveClient(transport: t).setList(set: UUID(), destination: UUID(), path: "Sets/Docs")
    #expect(t.calls[0].subcommand == "set-list")
    #expect(bodyText(t).contains("Sets/Docs"))
    #expect(items == [BackupItem(name: "p", isFolder: true, size: 0)])
}

@Test func dryRunReturnsTheFiles() async throws {
    let t = FakeTransport()
    t.response = json(#"{"ok":true,"files":["a","b/c"],"gitFiles":7}"#)
    let held = try await AgentArchiveClient(transport: t).dryRunDeletions(set: UUID(), destination: UUID())
    #expect(t.calls[0].subcommand == "dry-run-deletions")
    #expect(held == HeldFiles(files: ["a", "b/c"], gitCount: 7))
}

@Test func anAgentFailureComesBackAsTheSameTypedError() async throws {
    let t = FakeTransport()
    t.response = json(#"{"failure":{"busy":{}}}"#)
    await #expect(throws: AgentFailure.busy) {
        _ = try await AgentArchiveClient(transport: t).archiveList(set: UUID(), destination: UUID())
    }
}

@Test func anUnreadableAnswerIsNoResponse() async {
    let t = FakeTransport()
    t.response = json("not json")
    await #expect(throws: AgentClientError.self) {
        _ = try await AgentArchiveClient(transport: t).dryRunDeletions(set: UUID(), destination: UUID())
    }
}

@Test func theProcessTransportPassesTheSubcommandAsTheOnlyArgumentAndBodyOnStdin() async throws {
    let box = try ArchiveSandbox()
    let log = box.root.appendingPathComponent("args.txt"), stdin = box.root.appendingPathComponent("stdin.txt")
    let script = box.root.appendingPathComponent("fake-agent.sh")
    try "#!/bin/sh\necho \"$#:$1\" > '\(log.path)'\ncat > '\(stdin.path)'\necho '{\"ok\":true,\"files\":[\"x\"]}'\n"
        .write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    let held = try await AgentArchiveClient(transport: AgentProcessTransport(executable: script))
        .dryRunDeletions(set: UUID(), destination: UUID())
    #expect(held.files == ["x"])
    #expect(try String(contentsOf: log, encoding: .utf8) == "1:dry-run-deletions\n")
    #expect(try String(contentsOf: stdin, encoding: .utf8).contains("\"set\""))
}

private func scriptTransport(_ box: ArchiveSandbox, exit code: Int, output: String) throws -> AgentProcessTransport {
    let script = box.root.appendingPathComponent("agent-\(UUID().uuidString).sh")
    try "#!/bin/sh\ncat > /dev/null\nprintf '%s' '\(output)'\nexit \(code)\n".write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    return AgentProcessTransport(executable: script)
}

@Test func aNonZeroExitWithoutAnOkOrAFailureIsNotASuccess() async throws {
    let box = try ArchiveSandbox()
    let t = try scriptTransport(box, exit: 3, output: "garbage")
    await #expect(throws: AgentClientError.noResponse(exitCode: 3)) { _ = try await t.call(subcommand: "dry-run-deletions", body: Data()) }
}

@Test func aZeroExitWithoutOkIsNotASuccessEither() async throws {
    let box = try ArchiveSandbox()
    let t = try scriptTransport(box, exit: 0, output: #"{"files":["x"]}"#)
    await #expect(throws: AgentClientError.self) {
        _ = try await AgentArchiveClient(transport: t).dryRunDeletions(set: UUID(), destination: UUID())
    }
}

@Test func aFailureAnswerSurvivesANonZeroExit() async throws {
    let box = try ArchiveSandbox()
    let t = try scriptTransport(box, exit: 1, output: #"{"ok":false,"failure":{"busy":{}}}"#)
    await #expect(throws: AgentFailure.busy) {
        _ = try await AgentArchiveClient(transport: t).archiveList(set: UUID(), destination: UUID())
    }
}

// MARK: Providers

@Test func archiveProviderAsksTheAgentForTheSetAndDestination() async throws {
    let t = FakeTransport()
    t.response = json(#"{"ok":true,"entries":[]}"#)
    let set = makeSet("Docs"), dest = Destination(name: "iCloud", kind: .iCloudFolder)
    _ = try await AgentArchiveProvider(client: AgentArchiveClient(transport: t)).list(set: set, destination: dest)
    #expect(bodyText(t).contains(set.id.uuidString) && bodyText(t).contains(dest.id.uuidString))
}

@Test func archiveProviderRestoresTheEntryPath() async throws {
    let t = FakeTransport()
    let set = makeSet("Docs"), dest = Destination(name: "iCloud", kind: .iCloudFolder)
    let entry = ArchiveEntry(id: "1", setName: "Docs", stamp: Date(), path: "Archive/Docs/2026-11-04T10-00/a.txt", size: 1)
    try await AgentArchiveProvider(client: AgentArchiveClient(transport: t))
        .restore(entry: entry, set: set, destination: dest, to: URL(fileURLWithPath: "/tmp/out"))
    #expect(t.calls[0].subcommand == "archive-restore")
    #expect(bodyText(t).contains("Archive/Docs/2026-11-04T10-00/a.txt"))
}

@Test func dryRunAsksTheAgentForTheOneDestination() async throws {
    let a = Destination(name: "iCloud", kind: .iCloudFolder)
    let set = makeSet("Docs")
    let client = FakeDryRunClient(files: [a.id: ["x", "y"]])
    let held = try await AgentDeletionDryRun(client: client).heldDeletions(set: set, destination: a)
    #expect(held.files == ["x", "y"])
    #expect(client.asked == [a.id])
}

private final class FakeDryRunClient: ArchiveAgentCalling, @unchecked Sendable {
    let files: [UUID: [String]]
    private(set) var asked: [UUID] = []
    init(files: [UUID: [String]]) { self.files = files }
    func archiveList(set: UUID, destination: UUID) async throws -> [ArchiveEntry] { [] }
    func archiveRestore(set: UUID, destination: UUID, path: String, to: URL) async throws {}
    func setList(set: UUID, destination: UUID, path: String) async throws -> [BackupItem] { [] }
    func dryRunDeletions(set: UUID, destination: UUID) async throws -> HeldFiles {
        asked.append(destination); return HeldFiles(files: files[destination] ?? [], gitCount: 0)
    }
}

// MARK: Exclude inspector

private struct NoVolumes: VolumeLocating { func mounted() -> [VolumeInfo] { [] } }
private struct OneVolume: VolumeLocating {
    var volume: VolumeInfo
    func mounted() -> [VolumeInfo] { [volume] }
}

private struct InspectorWorld {
    let box: ArchiveSandbox
    let icloud: URL            // stands for iCloud Drive
    let store: ConfigStore
    let dest: Destination
    var set: BackupSet

    init() throws {
        box = try ArchiveSandbox()
        icloud = try box.dir("icloud")
        store = ConfigStore(root: try box.dir("support"))
        dest = Destination(name: "iCloud Drive", kind: .iCloudFolder)
        set = makeSet("Docs")
        set.destinationIDs = [dest.id]
        try store.saveSets([set]); try store.saveDestinations([dest])
    }
    var backupRoot: URL { MirrorPaths.backupRoot(iCloudDrive: icloud) }
    var mirror: URL { backupRoot.appendingPathComponent("Sets/Docs") }

    func inspector(volumes: any VolumeLocating = NoVolumes(), list: @escaping @Sendable (BackupSet, String) async throws -> [String] = { _, _ in [] },
                   now: Date = utc("2026-11-04T10-00-30")) -> LocalMirrorInspector {
        LocalMirrorInspector(store: store, iCloudDrive: icloud, volumes: volumes, support: box.root.appendingPathComponent("support"),
                             listNewlyExcluded: list, now: { now })
    }
}

@Test func inspectorListsWhatTheRulesWouldNowSkipInTheICloudMirror() async throws {
    let w = try InspectorWorld()
    try w.box.write("Sets/Docs/build/out.o", under: w.backupRoot)
    let asked = MirrorBox<String>()
    let files = try await w.inspector(list: { _, mirror in asked.set(mirror); return ["build/out.o"] })
        .mirroredFiles(matching: [UserRule(pattern: "build/**", action: .exclude)], set: w.set)
    #expect(files == ["build/out.o"])
    #expect(asked.value == w.mirror.path)
}

@Test func inspectorSkipsCloudDestinationsAndMirrorsThatDontExist() async throws {
    var w = try InspectorWorld()
    let cloud = Destination(name: "Drive", kind: .googleDrive)
    w.set.destinationIDs = [cloud.id, w.dest.id]
    try w.store.saveDestinations([cloud, w.dest]); try w.store.saveSets([w.set])
    let calls = MirrorBox<Int>()
    let files = try await w.inspector(list: { _, _ in calls.set((calls.value ?? 0) + 1); return ["x"] })
        .mirroredFiles(matching: [], set: w.set)
    #expect(files.isEmpty && calls.value == nil)   // iCloud mirror folder doesn't exist yet, cloud is never read here
}

@Test func inspectorReadsAConnectedDriveByUUIDOnly() async throws {
    var w = try InspectorWorld()
    let mount = try w.box.dir("Volumes/SSD")
    let vol = VolumeInfo(uuid: "UUID-1", name: "SSD", mountPoint: mount, fileSystem: "apfs", freeBytes: 1)
    let drive = Destination(name: "SSD", kind: .externalDrive, encrypted: false, volumeUUID: "UUID-1")
    w.set.destinationIDs = [drive.id]
    try w.store.saveDestinations([drive]); try w.store.saveSets([w.set])
    try w.box.write("Mac Backup/Sets/Docs/a.log", under: mount)
    let asked = MirrorBox<String>()
    let files = try await w.inspector(volumes: OneVolume(volume: vol), list: { _, m in asked.set(m); return ["a.log"] })
        .mirroredFiles(matching: [], set: w.set)
    #expect(files == ["a.log"])
    #expect(asked.value == mount.appendingPathComponent("Mac Backup/Sets/Docs").path)
    // Another UUID on the same name is not this drive.
    let other = try await w.inspector(volumes: OneVolume(volume: VolumeInfo(uuid: "OTHER", name: "SSD", mountPoint: mount, fileSystem: "apfs", freeBytes: 1)),
                                      list: { _, _ in ["a.log"] }).mirroredFiles(matching: [], set: w.set)
    #expect(other.isEmpty)
}

@Test func inspectorIgnoresAnInternalLookingDriveThatWasNeverConfirmed() async throws {
    var w = try InspectorWorld()
    let mount = try w.box.dir("Volumes/Inner")
    let vol = VolumeInfo(uuid: "U", name: "Inner", mountPoint: mount, fileSystem: "apfs", freeBytes: 1, looksInternal: true)
    let drive = Destination(name: "Inner", kind: .externalDrive, encrypted: false, volumeUUID: "U")
    w.set.destinationIDs = [drive.id]
    try w.store.saveDestinations([drive]); try w.store.saveSets([w.set])
    try w.box.write("Mac Backup/Sets/Docs/a.log", under: mount)
    let files = try await w.inspector(volumes: OneVolume(volume: vol), list: { _, _ in ["a.log"] }).mirroredFiles(matching: [], set: w.set)
    #expect(files.isEmpty)
}

@Test func archivingMovesFilesIntoTheStampedArchiveAndKeepsTheirFolders() async throws {
    let w = try InspectorWorld()
    try w.box.write("Sets/Docs/build/out.o", "O", under: w.backupRoot)
    try w.box.write("Sets/Docs/keep.txt", "K", under: w.backupRoot)
    try await w.inspector().archive(["build/out.o"], set: w.set)
    let moved = w.backupRoot.appendingPathComponent("Archive/Docs/2026-11-04T10-00-30/build/out.o")
    #expect(try String(contentsOf: moved, encoding: .utf8) == "O")
    #expect(!FileManager.default.fileExists(atPath: w.mirror.appendingPathComponent("build/out.o").path))
    #expect(FileManager.default.fileExists(atPath: w.mirror.appendingPathComponent("keep.txt").path))
}

@Test func archivingRefusesPathsThatLeaveTheMirror() async throws {
    let w = try InspectorWorld()
    try w.box.write("Sets/Docs/a.txt", under: w.backupRoot)
    let secret = try w.box.write("outside.txt", "S")
    for bad in ["../outside.txt", "/etc/hosts", "a/../../x", "", "."] {
        await #expect(throws: LocalMirrorInspectorError.unsafePath(bad)) { try await w.inspector().archive([bad], set: w.set) }
    }
    #expect(FileManager.default.fileExists(atPath: secret.path))
}

@Test func archivingNeverFollowsASymlinkedFolderOutOfTheMirror() async throws {
    let w = try InspectorWorld()
    let outside = try w.box.dir("elsewhere")
    let victim = try w.box.write("victim.txt", "V", under: outside)
    try FileManager.default.createDirectory(at: w.mirror, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: w.mirror.appendingPathComponent("link"), withDestinationURL: outside)
    await #expect(throws: LocalMirrorInspectorError.unsafePath("link/victim.txt")) {
        try await w.inspector().archive(["link/victim.txt"], set: w.set)
    }
    #expect(FileManager.default.fileExists(atPath: victim.path))
}

@Test func archivingWaitsForNoBackupAndRefusesWhileTheAgentHoldsItsLock() async throws {
    let w = try InspectorWorld()
    try w.box.write("Sets/Docs/a.txt", under: w.backupRoot)
    let lock = RunLock(url: w.box.root.appendingPathComponent("support/locks/agent.lock"))
    #expect(lock.tryAcquire())
    await #expect(throws: LocalMirrorInspectorError.backupRunning) { try await w.inspector().archive(["a.txt"], set: w.set) }
    #expect(FileManager.default.fileExists(atPath: w.mirror.appendingPathComponent("a.txt").path))
    lock.release()
    try await w.inspector().archive(["a.txt"], set: w.set)
    #expect(!FileManager.default.fileExists(atPath: w.mirror.appendingPathComponent("a.txt").path))
}

@Test func archivingAFileThatIsAlreadyGoneIsNotAnError() async throws {
    let w = try InspectorWorld()
    try FileManager.default.createDirectory(at: w.mirror, withIntermediateDirectories: true)
    try await w.inspector().archive(["gone.txt"], set: w.set)
}

private final class MirrorBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T?
    var value: T? { lock.withLock { stored } }
    func set(_ v: T) { lock.withLock { stored = v } }
}
