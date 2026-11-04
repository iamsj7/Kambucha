import Testing
import Foundation
@testable import MirrorCore

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
    private let files = RcloneRemoteFiles(binary: binary)

    @Test func readWriteAndListThroughRclone() async throws {
        let dir = try tempDir("files"); defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try await files.read(dir.path + "/.mirror-root", context: plain) == nil)
        #expect(try await files.list(dir.path + "/nope", context: plain) == nil)
        try await files.write(Data("{}".utf8), to: dir.path + "/.mirror-root", context: plain)
        #expect(try await files.read(dir.path + "/.mirror-root", context: plain) == Data("{}".utf8))
        #expect(try await files.list(dir.path, context: plain) == [".mirror-root"])
    }

    @Test func aFailedReadIsNotAMissingFile() async throws {
        await #expect(throws: RemoteFileError.self) {
            _ = try await files.read("nosuchremote:.mirror-root", context: plain)
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
        let env = try RcloneCrypt.environment(remote: "mirrorcrypttest", over: dir.path, passphrase: "correct horse",
                                              salt: "battery staple", filenameEncoding: "base32", binary: binary)
        let context = RcloneContext(configPath: "/dev/null", environment: env)
        try await files.write(Data("{\"sets\":{}}".utf8), to: "mirrorcrypttest:.mirror-root", context: context)
        #expect(try await files.read("mirrorcrypttest:.mirror-root", context: context) == Data("{\"sets\":{}}".utf8))
        let raw = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(raw.count == 1)
        #expect(!raw.contains(".mirror-root"))
        let bytes = try Data(contentsOf: dir.appendingPathComponent(raw[0]))
        #expect(!String(decoding: bytes, as: UTF8.self).contains("sets"))
    }
}

@Suite struct RunIntegrationTests {
    private final class Rig: @unchecked Sendable {
        let root: URL, source: URL, backupRoot: URL, support: URL
        let set: BackupSet, destination = Destination(name: "iCloud", kind: .iCloudFolder)
        let store: ConfigStore, records: RunRecordStore, problems: ProblemCenter
        let rclone = RcloneRunner(binary: binary)
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
        func run(_ command: RunCommand = RunCommand()) async throws -> RunRecord {
            var s = try store.state(for: pair); s.lastEventID = nil; try store.save(s, for: pair)
            let c = RunCoordinator(store: store, records: records, problems: problems, rclone: rclone, feed: RescanFeed(),
                                   verifier: Verifier(rclone: rclone, auditor: AllUploaded()),
                                   guard: PathGuard(iCloudDrive: backupRoot.deletingLastPathComponent(), backupRoot: backupRoot),
                                   detector: StackDetector(presets: []), filters: FilterBuilder(presets: []), clock: { Date() },
                                   sessions: { _ in NoSession() }, remote: RcloneRemoteFiles(binary: binary),
                                   paths: RunPaths(support: support, logs: root.appendingPathComponent("logs"),
                                                   work: root.appendingPathComponent("work")))
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
        record = try await r.run(RunCommand(setID: r.set.id, approvedDeletions: 199, force: true))
        #expect(record.status == .held)
        #expect(FileManager.default.fileExists(atPath: r.mirror.appendingPathComponent("p/f3.txt").path))
        record = try await r.run(RunCommand(setID: r.set.id, approvedDeletions: 200, force: true))
        #expect(record.status == .success)
        #expect(!FileManager.default.fileExists(atPath: r.mirror.appendingPathComponent("p/f3.txt").path))
        #expect(r.archived("f3.txt"))
        #expect(try r.problems.active().isEmpty)
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

    @Test func anEmptyFirstRunPasses() async throws {
        let r = try Rig()
        #expect(try await r.run().status == .success)
    }
}
