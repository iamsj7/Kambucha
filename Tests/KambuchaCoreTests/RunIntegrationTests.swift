import Testing
import Foundation
@testable import KambuchaCore

/// Real rclone against temp folders, with only FSEvents and the upload audit faked.
private let binary = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("vendor/rclone/rclone")
private let plain = RcloneContext(configPath: "/dev/null", environment: [:])

private func tempDir(_ name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)").resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private struct AllUploaded: UploadAuditing {
    func audit(_: [URL]) -> AuditResult { AuditResult(pending: [], refused: []) }
}

/// Reports a rescan every time, so each run covers the whole set.
private struct RescanFeed: ChangeFeeding {
    func changes(in: URL, since: UInt64?) async throws -> ChangeBatch {
        ChangeBatch(paths: [], mustRescan: since != 99, latestEventID: 99)
    }
}

private struct Quiet: Notifying {
    func post(_: Problem, pair: PairID, setName: String, detail: String) async -> Bool { true }
}

private struct NoSession: RunSession {
    func open() throws -> (endpoint: String, context: RcloneContext) { throw RcloneSessionError.notSignedIn }
    func close() throws {}
}

@Suite struct RemoteFilesIntegrationTests {
    private let files = RcloneRemoteFiles(binary: binary, helper: AnyHelper())

    @Test func readWriteAndListThroughRclone() async throws {
        let dir = try tempDir("files"); defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try await files.read(dir.path + "/.kambucha-root", context: plain) == nil)
        #expect(try await files.list(dir.path + "/nope", context: plain) == nil)
        try await files.write(Data("{}".utf8), to: dir.path + "/.kambucha-root", context: plain)
        #expect(try await files.read(dir.path + "/.kambucha-root", context: plain) == Data("{}".utf8))
        #expect(try await files.list(dir.path, context: plain) == [".kambucha-root"])
    }

    @Test func anExpiredSignInIsToldApartFromAFailedRead() async throws {
        let dir = try tempDir("auth"); defer { try? FileManager.default.removeItem(at: dir) }
        let fake = dir.appendingPathComponent("rclone")
        try """
        #!/bin/sh
        while [ $# -gt 0 ]; do
          if [ "$1" = "--log-file" ]; then
            echo '{"level":"error","msg":"Failed to create file system: couldn'"'"'t fetch token: invalid_grant"}' > "$2"
          fi
          shift
        done
        exit 1
        """.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        let remote = RcloneRemoteFiles(binary: fake, helper: AnyHelper())
        await #expect(throws: RemoteFileError.authExpired) { _ = try await remote.read("x:.kambucha-root", context: plain) }
        await #expect(throws: RemoteFileError.authExpired) { _ = try await remote.list("x:", context: plain) }
        await #expect(throws: RemoteFileError.authExpired) { try await remote.write(Data(), to: "x:m", context: plain) }
    }

    @Test func captureRefusesSecretsWithoutAHelper() async throws {
        let secret = RcloneContext(configPath: "/dev/null", environment: ["RCLONE_CONFIG_X_TYPE": "crypt"])
        await #expect(throws: RcloneRunnerError.helperNotChecked) {
            _ = try await RcloneRunner.localOnly(binary: binary).capture(["version"], context: secret)
        }
    }

    @Test func aFailedReadIsNotAMissingFile() async throws {
        await #expect(throws: RemoteFileError.self) {
            _ = try await files.read("nosuchremote:.kambucha-root", context: plain)
        }
    }

    @Test func oversizedMarkerIsRefusedNotTruncated() async throws {
        let dir = try tempDir("files"); defer { try? FileManager.default.removeItem(at: dir) }
        await #expect(throws: RemoteFileError.tooLarge) {
            try await files.write(Data(count: RcloneTool.maxStdin), to: dir.path + "/m", context: plain)
        }
    }

    @Test func encryptedMarkerNeverAppearsAsAPlainFile() async throws {
        let dir = try tempDir("crypt"); defer { try? FileManager.default.removeItem(at: dir) }
        let env = try RcloneCrypt.environment(remote: "kambuchacrypttest", over: dir.path, passphrase: "correct horse",
                                              salt: "battery staple", filenameEncoding: "base32", binary: binary, helper: AnyHelper())
        let context = RcloneContext(configPath: "/dev/null", environment: env)
        try await files.write(Data("{\"sets\":{}}".utf8), to: "kambuchacrypttest:.kambucha-root", context: context)
        #expect(try await files.read("kambuchacrypttest:.kambucha-root", context: context) == Data("{\"sets\":{}}".utf8))
        let raw = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(raw.count == 1)
        #expect(!raw.contains(".kambucha-root"))
        let bytes = try Data(contentsOf: dir.appendingPathComponent(raw[0]))
        #expect(!String(decoding: bytes, as: UTF8.self).contains("sets"))
    }
}

private final class Written: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [TransferProgress] = []
    var all: [TransferProgress] { lock.withLock { items } }
    func add(_ p: TransferProgress) { lock.withLock { items.append(p) } }
}

@Suite struct RunIntegrationTests {
    private final class Rig: @unchecked Sendable {
        let root: URL, source: URL, backupRoot: URL, support: URL
        let set: BackupSet, destination = Destination(name: "iCloud", kind: .iCloudFolder)
        let store: ConfigStore, records: RunRecordStore, problems: ProblemCenter
        let rclone = RcloneRunner.localOnly(binary: binary)
        init() throws {
            root = try tempDir("rig")
            source = root.appendingPathComponent("src")
            let iCloud = root.appendingPathComponent("icloud")
            backupRoot = iCloud.appendingPathComponent("Mac Backup")
            support = root.appendingPathComponent("support")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: iCloud, withIntermediateDirectories: true)
            var s = BackupSet(name: "x", source: source)
            s.destinationIDs = [destination.id]
            s.acceptPreview()
            set = s
            store = ConfigStore(root: support)
            records = RunRecordStore(root: support)
            problems = ProblemCenter(root: support, notifier: Quiet())
            try store.saveSets([set]); try store.saveDestinations([destination])
        }
        deinit { try? FileManager.default.removeItem(at: root) }

        var pair: PairID { PairID(set: set.id, destination: destination.id) }
        var mirror: URL { backupRoot.appendingPathComponent("Sets/x") }

        func write(_ rel: String, _ text: String = "data") throws {
            let url = source.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }

        /// A full run: the stored ID is reset so the feed asks for a rescan.
        func run(_ command: RunCommand = RunCommand(), rclone custom: RcloneRunner? = nil,
                 progress: RunProgress? = nil) async throws -> RunRecord {
            let rclone = custom ?? self.rclone
            var s = try store.state(for: pair); s.lastEventID = nil; try store.save(s, for: pair)
            let c = RunCoordinator(store: store, records: records, problems: problems, rclone: rclone, feed: RescanFeed(),
                                   verifier: Verifier(rclone: rclone, auditor: AllUploaded()),
                                   guard: PathGuard(iCloudDrive: backupRoot.deletingLastPathComponent(), backupRoot: backupRoot),
                                   detector: StackDetector(presets: []), filters: FilterBuilder(presets: []), clock: { Date() },
                                   sessions: { _ in NoSession() }, remote: RcloneRemoteFiles(binary: binary, helper: AnyHelper()),
                                   paths: RunPaths(support: support, logs: root.appendingPathComponent("logs"),
                                                   work: root.appendingPathComponent("work")), progress: progress)
            let before = Set(try records.recent(limit: 1000).map(\.id))
            await c.runAll(command: command)
            // Stored times are whole seconds, so runs this quick can only be told apart by ID.
            return try #require(try records.recent(limit: 1000).first { !before.contains($0.id) })
        }

        func archived(_ name: String) -> Bool {
            let archive = backupRoot.appendingPathComponent("Archive/x")
            guard let e = FileManager.default.enumerator(atPath: archive.path) else { return false }
            return e.contains { ($0 as? String)?.hasSuffix(name) == true }
        }
    }

    @Test func aCompleteLifecycleAgainstRealRclone() async throws {
        let r = try Rig()
        for i in 0..<300 { try r.write("p/f\(i).txt", "file \(i)") }

        var record = try await r.run()
        #expect(record.status == .success)
        #expect(record.copied == 300)
        #expect(try r.store.state(for: r.pair).lastFileCount == 300)
        #expect(try RootMarker.load(backupRoot: r.backupRoot)?.claims(r.set.id) == true)

        // Modify and rename: both reach the mirror, and neither counts as a deletion.
        try r.write("p/f0.txt", "changed, and longer")
        try FileManager.default.moveItem(at: r.source.appendingPathComponent("p/f1.txt"),
                                         to: r.source.appendingPathComponent("p/moved.txt"))
        record = try await r.run()
        #expect(record.status == .success)
        #expect(record.renamed == 1)
        #expect(try String(contentsOf: r.mirror.appendingPathComponent("p/f0.txt"), encoding: .utf8) == "changed, and longer")
        #expect(FileManager.default.fileExists(atPath: r.mirror.appendingPathComponent("p/moved.txt").path))
        #expect(r.archived("f0.txt"))

        // One deletion goes through and lands in the archive.
        try FileManager.default.removeItem(at: r.source.appendingPathComponent("p/f2.txt"))
        record = try await r.run()
        #expect(record.status == .success)
        #expect(!FileManager.default.fileExists(atPath: r.mirror.appendingPathComponent("p/f2.txt").path))
        #expect(r.archived("f2.txt"))

        // A mass deletion holds: new files still back up, deleted ones stay in the mirror.
        for i in 3..<203 { try FileManager.default.removeItem(at: r.source.appendingPathComponent("p/f\(i).txt")) }
        try r.write("p/new.txt")
        record = try await r.run()
        #expect(record.status == .held)
        #expect(try r.store.state(for: r.pair).heldDeletions == 200)
        #expect(try r.problems.active().map(\.problem) == [.deletionsHeld])
        #expect(FileManager.default.fileExists(atPath: r.mirror.appendingPathComponent("p/f3.txt").path))
        #expect(FileManager.default.fileExists(atPath: r.mirror.appendingPathComponent("p/new.txt").path))

        // Too small an approval changes nothing. The reviewed count goes through.
        record = try await r.run(RunCommand(setID: r.set.id, approvedDeletions: 199, approvedDestination: r.destination.id, force: true))
        #expect(record.status == .held)
        #expect(FileManager.default.fileExists(atPath: r.mirror.appendingPathComponent("p/f3.txt").path))
        record = try await r.run(RunCommand(setID: r.set.id, approvedDeletions: 200, approvedDestination: r.destination.id, force: true))
        #expect(record.status == .success)
        #expect(!FileManager.default.fileExists(atPath: r.mirror.appendingPathComponent("p/f3.txt").path))
        #expect(r.archived("f3.txt"))
        #expect(try r.problems.active().isEmpty)
    }

    @Test func aRealRunArchivesWhereTheArchiveCanFindItAndPrunesWhatExpired() async throws {
        let r = try Rig()
        try r.write("p/f.txt", "first")
        try r.write("p/g.txt")
        _ = try await r.run()

        let expired = ArchiveScope.stampString(Date().addingTimeInterval(-40 * 86_400))
        let old = r.backupRoot.appendingPathComponent("Archive/x/\(expired)/p")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: old.appendingPathComponent("stale.txt"))

        try r.write("p/f.txt", "second, and longer")
        let record = try await r.run()
        #expect(record.status == .success)
        #expect(record.archivesPruned == 1)
        #expect(!FileManager.default.fileExists(atPath: old.path))

        let entries = try await ArchiveManager(rclone: r.rclone, endpoint: r.backupRoot.path, context: plain, kind: .iCloudFolder).list(set: r.set)
        #expect(entries.map { ($0.path as NSString).lastPathComponent } == ["f.txt"])
    }

    @Test func aRealRunWritesTheManifestRestoreReads() async throws {
        let r = try Rig()
        try r.write("p/f.txt")
        try FileManager.default.createSymbolicLink(atPath: r.source.appendingPathComponent("p/link").path, withDestinationPath: "f.txt")
        _ = try await r.run()
        let manifest = try SymlinkManifest.read(set: "x", backupRoot: r.backupRoot)
        #expect(manifest.entries == [.init(path: "p/link", target: "f.txt", isAbsolute: false, isBroken: false)])
    }

    @Test func realRcloneStatsReachTheProgressFolder() async throws {
        let r = try Rig()
        try r.write("p/f.txt")
        let log = Written()
        let progress = RunProgress(store: ProgressStore(root: r.support), clock: { Date() }, observer: { log.add($0) })
        let runner = RcloneRunner.localOnly(binary: binary, onStats: { progress.stats($0) })
        let record = try await r.run(rclone: runner, progress: progress)
        #expect(record.status == .success)
        #expect(log.all.contains { $0.phase == .transferring && $0.filesDone == 1 })
        #expect(try ProgressStore(root: r.support).all(now: Date()).isEmpty)
    }

    private struct OneVolume: VolumeLocating {
        let volume: VolumeInfo
        func mounted() -> [VolumeInfo] { [volume] }
    }

    /// The whole stack but the volume list, as a temp folder can't be a mounted drive.
    private func driveRun(_ r: Rig, looksInternal: Bool, confirmed: Bool) async throws -> (URL, RunRecord) {
        let mount = r.root.appendingPathComponent("Volumes/SSD")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        let volume = VolumeInfo(uuid: "SSD-UUID", name: "SSD", mountPoint: mount, fileSystem: "apfs", freeBytes: 1 << 50,
                                totalBytes: 1 << 40, mountID: "m1", looksInternal: looksInternal)
        let drive = Destination(name: "SSD", kind: .externalDrive, volumeUUID: volume.uuid, internalDiskConfirmed: confirmed)
        var set = r.set
        set.destinationIDs = [drive.id]
        set.acceptPreview()
        try r.store.saveSets([set]); try r.store.saveDestinations([drive])
        let c = RunCoordinator(store: r.store, records: r.records, problems: r.problems, rclone: r.rclone, feed: RescanFeed(),
                               verifier: Verifier(rclone: r.rclone, auditor: AllUploaded()),
                               guard: PathGuard(iCloudDrive: r.backupRoot.deletingLastPathComponent(), backupRoot: r.backupRoot),
                               detector: StackDetector(presets: []), filters: FilterBuilder(presets: []), clock: { Date() },
                               sessions: { _ in NoSession() }, remote: RcloneRemoteFiles(binary: binary, helper: AnyHelper()),
                               paths: RunPaths(support: r.support, logs: r.root.appendingPathComponent("logs"),
                                               work: r.root.appendingPathComponent("work")),
                               volumes: OneVolume(volume: volume))
        await c.runAll(command: RunCommand(force: true))
        return (mount.appendingPathComponent("Mac Backup"), try #require(try r.records.recent(limit: 1).first))
    }

    @Test func anUnconfirmedInternalLookingVolumeIsRefusedThroughTheRealEntryPoint() async throws {
        let r = try Rig()
        try r.write("p/f.txt")
        let (root, record) = try await driveRun(r, looksInternal: true, confirmed: false)
        #expect(record.status == .failed)
        #expect(record.copied == 0)
        #expect(!FileManager.default.fileExists(atPath: root.path))
        #expect(try r.problems.active().map(\.problem) == [.destinationMissing])
    }

    @Test func aConfirmedVolumeBacksUpWithRealRclone() async throws {
        let r = try Rig()
        try r.write("p/f.txt", "on the drive")
        try FileManager.default.createSymbolicLink(atPath: r.source.appendingPathComponent("p/link").path, withDestinationPath: "f.txt")
        let (root, record) = try await driveRun(r, looksInternal: true, confirmed: true)
        #expect(record.status == .success)
        #expect(try String(contentsOf: root.appendingPathComponent("Sets/x/p/f.txt"), encoding: .utf8) == "on the drive")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: root.appendingPathComponent("Sets/x/p/link").path) == "f.txt")
        #expect(try SymlinkManifest.read(set: "x", backupRoot: root).entries.map(\.path) == ["p/link"])
    }

    @Test func aRealDryRunCountsTheBytesItWouldCopy() async throws {
        let r = try Rig()
        try r.write("p/f.txt", "12345")
        try r.write("p/g.txt", "1234567")
        let log = r.root.appendingPathComponent("dry.log")
        let filter = r.root.appendingPathComponent("filter.txt")
        try Data().write(to: filter)
        let result = try await r.rclone.sync(SyncRequest(
            source: r.source, destination: r.mirror.path, backupDir: r.backupRoot.appendingPathComponent("Archive/x/t").path,
            filterFile: filter, logFile: log, mode: .mirror(maxDelete: -1), profile: .profile(for: r.destination),
            context: plain, dryRun: true))
        #expect(result.summary.plannedBytes == 12)
    }

    @Test func emptiedSourceLeavesTheMirrorAlone() async throws {
        let r = try Rig()
        for i in 0..<5 { try r.write("p/f\(i).txt") }
        _ = try await r.run()
        try FileManager.default.removeItem(at: r.source.appendingPathComponent("p"))
        let record = try await r.run()
        #expect(record.status == .held)
        #expect(FileManager.default.fileExists(atPath: r.mirror.appendingPathComponent("p/f0.txt").path))
    }

    @Test func unmountedSourceLeavesTheMirrorAlone() async throws {
        let r = try Rig()
        try r.write("p/f.txt")
        _ = try await r.run()
        try FileManager.default.removeItem(at: r.source)
        let record = try await r.run()
        #expect(record.status == .failed)
        #expect(FileManager.default.fileExists(atPath: r.mirror.appendingPathComponent("p/f.txt").path))
    }

    @Test func symlinksAreAuditedAtTheirRealMirrorName() async throws {
        let r = try Rig()
        try r.write("p/f.txt")
        try FileManager.default.createSymbolicLink(atPath: r.source.appendingPathComponent("p/link").path, withDestinationPath: "f.txt")
        #expect(try await r.run().status == .success)
        #expect(try r.store.state(for: r.pair).verifyOwed.isEmpty)
    }

    @Test func aRealDryRunListsWhatItWouldCopy() async throws {
        let r = try Rig()
        try r.write("p/f.txt")
        _ = try await r.run()
        try r.write("p/g.txt")
        let log = r.root.appendingPathComponent("dry.log")
        let filter = r.root.appendingPathComponent("f"); try Data().write(to: filter)
        let result = try await r.rclone.sync(SyncRequest(
            source: r.source, destination: r.mirror.path, backupDir: r.backupRoot.appendingPathComponent("Archive/x/t").path,
            filterFile: filter, logFile: log, mode: .mirror(maxDelete: -1),
            profile: .profile(for: r.destination), context: plain, dryRun: true))
        #expect(result.summary.planned == ["p/g.txt"])
    }

    /// Plain `--files-from` reads `#` as a comment and trims spaces, so these went unchecked.
    @Test func awkwardNamesAreHashedForReal() async throws {
        let dir = try tempDir("names"); defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("s"), dst = dir.appendingPathComponent("d"), logs = dir.appendingPathComponent("l")
        for d in [src, dst, logs] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        let names = ["#hash.txt", " lead.txt"]
        for n in names {
            try Data("aaaa".utf8).write(to: src.appendingPathComponent(n))
            try Data("bbbb".utf8).write(to: dst.appendingPathComponent(n))   // same size, so only a hash can tell
        }
        let filter = dir.appendingPathComponent("f"); try Data().write(to: filter)
        let verifier = Verifier(rclone: RcloneRunner.localOnly(binary: binary), auditor: AllUploaded())
        let result = try await verifier.quick(source: src, destination: dst.path,
                                              profile: .profile(for: Destination(name: "d", kind: .iCloudFolder)),
                                              context: plain, filter: filter, copied: names, oneWay: false, logDir: logs)
        #expect(result.differences == 2)
        #expect(Set(result.differingPaths) == Set(names))
    }

    @Test func anEmptyFirstRunPasses() async throws {
        let r = try Rig()
        #expect(try await r.run().status == .success)
    }
}
