import Testing
import Foundation
@testable import MirrorCore

/// Real rclone against temp folders. The binary is always the vendored one, by absolute path.
private let rcloneBinary = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("vendor/rclone/rclone")

private final class Sandbox {
    let root: URL
    var src: URL { root.appendingPathComponent("src") }
    var dst: URL { root.appendingPathComponent("dst") }
    var archive: URL { root.appendingPathComponent("archive") }
    let filter: URL
    private var runs = 0
    init() throws {
        let r = FileManager.default.temporaryDirectory.appendingPathComponent("mirror-rclone-\(UUID().uuidString)")
        root = r
        filter = r.appendingPathComponent("f.filter")
        for d in ["src", "dst", "archive"] {
            try FileManager.default.createDirectory(at: r.appendingPathComponent(d), withIntermediateDirectories: true)
        }
        try "+ **\n".write(to: filter, atomically: true, encoding: .utf8)
    }
    deinit { try? FileManager.default.removeItem(at: root) }

    func write(_ name: String, _ text: String) throws {
        let u = src.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: u, atomically: true, encoding: .utf8)
    }
    func read(_ base: URL, _ name: String) -> String? { try? String(contentsOf: base.appendingPathComponent(name), encoding: .utf8) }
    func exists(_ base: URL, _ name: String) -> Bool { FileManager.default.fileExists(atPath: base.appendingPathComponent(name).path) }

    func request(source: URL? = nil, destination: URL? = nil, mode: SyncMode = .mirror(maxDelete: 100),
                 dryRun: Bool = false) -> SyncRequest {
        runs += 1
        return SyncRequest(source: source ?? src, destination: (destination ?? dst).path,
                           backupDir: archive.appendingPathComponent("run\(runs)").path,
                           filterFile: filter, logFile: root.appendingPathComponent("run\(runs).log"),
                           mode: mode, profile: .profile(for: Destination(name: "t", kind: .iCloudFolder)),
                           context: RcloneContext(configPath: "/dev/null", environment: [:]), dryRun: dryRun)
    }
    func rawLog(_ r: SyncRequest) -> String { (try? String(contentsOf: r.logFile, encoding: .utf8)) ?? "" }
}

@Suite struct RcloneIntegrationTests {
    let runner = RcloneRunner(binary: rcloneBinary)

    @Test func addModifyDelete() async throws {
        let sb = try Sandbox()
        try sb.write("a.txt", "one"); try sb.write("sub/b.txt", "two")
        var res = try await runner.sync(sb.request())
        #expect(res.outcome == .success && res.exitCode == 0)
        #expect(Set(res.summary.copied) == ["a.txt", "sub/b.txt"])
        #expect(sb.read(sb.dst, "sub/b.txt") == "two")

        try sb.write("a.txt", "one changed!"); try FileManager.default.removeItem(at: sb.src.appendingPathComponent("sub/b.txt"))
        try sb.write("c.txt", "new")
        res = try await runner.sync(sb.request())
        #expect(res.outcome == .success)
        #expect(Set(res.summary.copied) == ["a.txt", "c.txt"])
        #expect(res.summary.deleted == ["sub/b.txt"])
        #expect(sb.read(sb.dst, "a.txt") == "one changed!")
        #expect(!sb.exists(sb.dst, "sub/b.txt"))
    }

    @Test func renameMovesNotCopies() async throws {
        let sb = try Sandbox()
        try sb.write("old.txt", String(repeating: "x", count: 5000))
        _ = try await runner.sync(sb.request())
        try FileManager.default.moveItem(at: sb.src.appendingPathComponent("old.txt"), to: sb.src.appendingPathComponent("new.txt"))
        let res = try await runner.sync(sb.request())
        #expect(res.summary.renamed == ["old.txt -> new.txt"])
        #expect(res.summary.copied.isEmpty)
        #expect(res.summary.deleted.isEmpty)
        #expect(sb.exists(sb.dst, "new.txt") && !sb.exists(sb.dst, "old.txt"))
    }

    @Test func archiveReceivesOverwrittenAndDeleted() async throws {
        let sb = try Sandbox()
        try sb.write("keep.txt", "v1"); try sb.write("gone.txt", "bye")
        _ = try await runner.sync(sb.request())
        try sb.write("keep.txt", "v2 longer"); try FileManager.default.removeItem(at: sb.src.appendingPathComponent("gone.txt"))
        let req = sb.request()
        let res = try await runner.sync(req)
        let arch = URL(fileURLWithPath: req.backupDir)
        #expect(sb.read(arch, "keep.txt") == "v1")
        #expect(sb.read(arch, "gone.txt") == "bye")
        #expect(Set(res.summary.archived) == ["keep.txt", "gone.txt"])
    }

    @Test func unchangedCopiesNothing() async throws {
        let sb = try Sandbox()
        try sb.write("a.txt", "one")
        _ = try await runner.sync(sb.request())
        let res = try await runner.sync(sb.request())
        #expect(res.outcome == .success)
        #expect(res.summary.copied.isEmpty && res.summary.deleted.isEmpty && res.summary.renamed.isEmpty)
    }

    @Test func maxDeleteStopsRun() async throws {
        let sb = try Sandbox()
        for i in 1...5 { try sb.write("f\(i).txt", "n\(i)") }
        _ = try await runner.sync(sb.request())
        for i in 1...5 { try FileManager.default.removeItem(at: sb.src.appendingPathComponent("f\(i).txt")) }
        let res = try await runner.sync(sb.request(mode: .mirror(maxDelete: 2)))
        // Observed with rclone 1.75.2: exit code 7 (fatal error), log has "--max-delete threshold reached".
        #expect(res.exitCode == 7)
        #expect(res.outcome == .safetyStop)
        let remaining = (1...5).filter { sb.exists(sb.dst, "f\($0).txt") }.count
        #expect(remaining >= 3)
    }

    @Test func dryRunChangesNothingButReportsDeletion() async throws {
        let sb = try Sandbox()
        try sb.write("a.txt", "one")
        _ = try await runner.sync(sb.request())
        try FileManager.default.removeItem(at: sb.src.appendingPathComponent("a.txt"))
        let res = try await runner.sync(sb.request(dryRun: true))
        #expect(res.summary.deleted == ["a.txt"])
        #expect(sb.exists(sb.dst, "a.txt"))
    }

    @Test func symlinksRoundTrip() async throws {
        let sb = try Sandbox()
        try sb.write("target.txt", "payload")
        try FileManager.default.createSymbolicLink(atPath: sb.src.appendingPathComponent("link").path, withDestinationPath: "target.txt")
        let res = try await runner.sync(sb.request())
        #expect(res.outcome == .success)
        // --links on both sides: rclone carries the link as a .rclonelink object and recreates a real symlink.
        #expect(res.summary.copied.contains("link.rclonelink"))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: sb.dst.appendingPathComponent("link").path) == "target.txt")
        // And back again.
        let back = sb.root.appendingPathComponent("restored")
        try FileManager.default.createDirectory(at: back, withIntermediateDirectories: true)
        _ = try await runner.sync(sb.request(source: sb.dst, destination: back))
        let dest = try FileManager.default.destinationOfSymbolicLink(atPath: back.appendingPathComponent("link").path)
        #expect(dest == "target.txt")
    }

    @Test func localToLocalUsesServerSideCopy() async throws {
        let sb = try Sandbox()
        try sb.write("a.txt", String(repeating: "a", count: 10_000))
        let req = sb.request()
        _ = try await runner.sync(req)
        #expect(sb.rawLog(req).contains("server-side copy"))
    }

    @Test func checkReportsDifferences() async throws {
        let sb = try Sandbox()
        try sb.write("a.txt", "one")
        _ = try await runner.sync(sb.request())
        try "different".write(to: sb.dst.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let check = CheckRequest(source: sb.src, destination: sb.dst.path, filterFile: sb.filter, filesFrom: nil,
                                 sizeOnly: false, oneWay: true, cryptCheck: false,
                                 context: RcloneContext(configPath: "/dev/null", environment: [:]),
                                 logFile: sb.root.appendingPathComponent("check.log"))
        let res = try await runner.check(check)
        #expect(res.summary.differences == 1)
        #expect(res.exitCode == 1)
    }

    @Test func childEnvironmentIsMinimal() throws {
        let env = RcloneRunner.childEnvironment(RcloneContext(configPath: "/dev/null", environment: ["RCLONE_X": "1"]),
                                                parent: ["SECRET_TOKEN": "t", "PATH": "/evil", "HOME": "/h"])
        #expect(env["SECRET_TOKEN"] == nil)
        #expect(env["RCLONE_X"] == "1")
        #expect(env["PATH"] != nil && env["HOME"] == "/h")
        #expect(Set(env.keys) == ["PATH", "HOME", "RCLONE_X"])
    }

    private func script(_ body: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mirror-fake-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let u = dir.appendingPathComponent("fake-rclone")
        try ("#!/bin/sh\n" + body + "\n").write(to: u, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: u.path)
        return u
    }

    @Test func alreadyCancelledTaskNeverStartsRclone() async throws {
        let sb = try Sandbox()
        try sb.write("a.txt", "one")
        let req = sb.request()
        let runner = self.runner
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await runner.sync(req)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!sb.exists(sb.dst, "a.txt"))
    }

    @Test func cancelledRunThrowsAndEscalatesToKill() async throws {
        // Ignores SIGTERM, so only SIGKILL stops it.
        let fake = try script("trap '' TERM\nexec sleep 60")
        let sb = try Sandbox()
        let runner = RcloneRunner(binary: fake, killGrace: 0.5)
        let req = sb.request()
        let started = Date()
        let task = Task { try await runner.sync(req) }
        try await Task.sleep(for: .milliseconds(400))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(Date().timeIntervalSince(started) < 20)
    }

    @Test func launchFailureThrowsInsteadOfHanging() async throws {
        let sb = try Sandbox()
        let runner = RcloneRunner(binary: URL(fileURLWithPath: "/nonexistent/rclone"))
        await #expect(throws: (any Error).self) { try await runner.sync(sb.request()) }
    }
}
