import Testing
import Foundation
@testable import KambuchaCore

@Suite struct RunMemoryTests {
    @Test func thisProcessHasAPeak() throws {
        let peak = try #require(RunMemory.ownPeak)
        #expect(peak > 1_000_000)
    }

    @Test func aProcessThatIsGoneHasNoFigure() {
        #expect(RunMemory.peakFootprint(pid: -1) == nil)
    }

    @Test func aChildIsSampledWhileItRuns() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["1"]
        let state = RunState(process, killGrace: 1)
        let pair = RunMemory.Peak()
        let peak = try await RunMemory.$pair.withValue(pair) {
            let sampler = RunMemory.follow(state)
            try state.start()
            try await Task.sleep(for: .milliseconds(600))
            return await RunMemory.stop(sampler)
        }
        process.waitUntilExit()
        #expect(peak > 0)
        #expect(pair.value == peak)
    }

    @Test func aPairKeepsItsLargestChild() {
        let pair = RunMemory.Peak()
        #expect(pair.value == nil)
        pair.note(5); pair.note(9); pair.note(7)
        #expect(pair.value == 9)
    }

    @Test func aChildThatNeverStartedReportsNothing() async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        let sampler = RunMemory.follow(RunState(process, killGrace: 1))
        #expect(await RunMemory.stop(sampler) == 0)
    }

    @Test func recordsWithoutMemoryStillRead() throws {
        let old = """
        {"archived":0,"bytes":0,"copied":0,"deleted":0,"destinationID":"249BACC9-1329-4AF4-B14D-64FA1BE8C346",
         "destinationName":"d","end":"2026-11-25T20:18:00Z","errors":[],"filesChecked":0,
         "id":"72254582-27E8-46A4-B54C-1A5B1D368CD3","pendingUploads":0,"refused":0,"renamed":0,"scope":"none",
         "setID":"F8E786FC-A215-4B8C-84A6-7E43359F1253","setName":"s","start":"2026-11-25T20:18:00Z",
         "status":"skipped","trigger":"schedule","verification":""}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record = try decoder.decode(RunRecord.self, from: Data(old.utf8))
        #expect(record.rclonePeakMemory == nil && record.agentPeakMemory == nil)

        var withMemory = record
        withMemory.rclonePeakMemory = 120_000_000
        withMemory.agentPeakMemory = 30_000_000
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        #expect(try decoder.decode(RunRecord.self, from: encoder.encode(withMemory)) == withMemory)
    }
}

@Suite struct CaptureLinesTests {
    private struct Fake: RcloneRunning {
        let stdout: String
        func sync(_: SyncRequest) async throws -> RcloneResult { throw RcloneUnsupported() }
        func check(_: CheckRequest) async throws -> RcloneResult { throw RcloneUnsupported() }
        func capture(_ arguments: [String], context: RcloneContext) async throws -> RcloneCapture {
            RcloneCapture(exitCode: 0, stdout: stdout, stderr: "")
        }
    }

    @Test func aCaptureOnlyRunnerStillHandsOverLines() async throws {
        var lines: [String] = []
        let out = try await Fake(stdout: "a\nb/c\n\nd\n")
            .captureLines([], context: RcloneContext(configPath: "/dev/null", environment: [:])) { lines.append($0) }
        #expect(lines == ["a", "b/c", "d"])
        #expect(out.stdout.isEmpty && out.exitCode == 0)
    }

    @Test func realRcloneListsEveryFileAndLeavesNoTempFile() async throws {
        let binary = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("vendor/rclone/rclone")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kambucha-lines-test-\(UUID().uuidString)")
        let dir = root.appendingPathComponent("src"), scratch = root.appendingPathComponent("scratch")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let names = (0..<2_000).map { "sub/f\($0).txt" } + ["ünïcode name.txt"]
        for name in names { try Data(name.utf8).write(to: dir.appendingPathComponent(name)) }

        var lines: [String] = []
        let out = try await RcloneRunner.localOnly(binary: binary, killGrace: 5, scratch: scratch)
            .captureLines(["lsf", "-R", "--files-only", dir.path, "--config", "/dev/null"],
                          context: RcloneContext(configPath: "/dev/null", environment: [:])) { lines.append($0) }
        #expect(out.exitCode == 0)
        #expect(Set(lines) == Set(names))
        #expect(lines.count == names.count)
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.path).isEmpty)
    }

    @Test func aFailedListingStillRemovesItsTempFile() async throws {
        let binary = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("vendor/rclone/rclone")
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("kambucha-lines-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let out = try await RcloneRunner.localOnly(binary: binary, killGrace: 5, scratch: scratch)
            .captureLines(["lsf", "/nonexistent/kambucha-\(UUID().uuidString)", "--config", "/dev/null"],
                          context: RcloneContext(configPath: "/dev/null", environment: [:])) { _ in }
        #expect(out.exitCode != 0)
        #expect(!out.stderr.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.path).isEmpty)
    }
}
