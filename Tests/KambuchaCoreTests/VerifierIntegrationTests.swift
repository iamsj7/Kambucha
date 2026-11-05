import Testing
import Foundation
@testable import KambuchaCore

private let rcloneBinary = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("vendor/rclone/rclone")

/// Real rclone on temp folders. A non-iCloud profile is used so the upload audit is skipped.
@Suite struct VerifierIntegrationTests {
    private func setup() throws -> (root: URL, src: URL, dst: URL, logs: URL, filter: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ver-int-\(UUID().uuidString)")
        let src = root.appendingPathComponent("src"), dst = root.appendingPathComponent("dst")
        let logs = root.appendingPathComponent("logs"), filter = root.appendingPathComponent("f.filter")
        for d in [src, dst, logs] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        try "+ **\n".write(to: filter, atomically: true, encoding: .utf8)
        return (root, src, dst, logs, filter)
    }
    private func put(_ dir: URL, _ name: String, _ text: String) throws {
        try text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    private let ctx = RcloneContext(configPath: "/dev/null", environment: [:])
    private var profile: DestinationProfile { DestinationProfile.profile(for: Destination(name: "d", kind: .googleDrive, encrypted: false)) }
    private var verifier: Verifier { Verifier(rclone: RcloneRunner.localOnly(binary: rcloneBinary), auditor: ICloudAuditor()) }

    @Test func filteredSizeOnlyCheckReportsFileMissingFromDestination() async throws {
        let t = try setup(); defer { try? FileManager.default.removeItem(at: t.root) }
        try put(t.src, "a.txt", "aaa"); try put(t.src, "b.txt", "bbb"); try put(t.dst, "a.txt", "aaa")
        let r = try await verifier.quick(source: t.src, destination: t.dst.path, profile: profile, context: ctx,
                                         filter: t.filter, copied: [], oneWay: false, logDir: t.logs)
        #expect(r.differences >= 1); #expect(!r.checksClean)
    }

    @Test func twoWayCheckReportsExtraFileInDestinationButOneWayDoesNot() async throws {
        let t = try setup(); defer { try? FileManager.default.removeItem(at: t.root) }
        try put(t.src, "a.txt", "aaa"); try put(t.dst, "a.txt", "aaa"); try put(t.dst, "extra.txt", "x")
        let two = try await verifier.quick(source: t.src, destination: t.dst.path, profile: profile, context: ctx,
                                           filter: t.filter, copied: [], oneWay: false, logDir: t.logs)
        #expect(two.differences >= 1); #expect(!two.checksClean)
        let one = try await verifier.quick(source: t.src, destination: t.dst.path, profile: profile, context: ctx,
                                           filter: t.filter, copied: [], oneWay: true, logDir: t.logs)
        #expect(one.differences == 0); #expect(one.checksClean)
    }

    @Test func identicalTreesAreClean() async throws {
        let t = try setup(); defer { try? FileManager.default.removeItem(at: t.root) }
        try put(t.src, "a.txt", "aaa"); try put(t.dst, "a.txt", "aaa")
        let r = try await verifier.quick(source: t.src, destination: t.dst.path, profile: profile, context: ctx,
                                         filter: t.filter, copied: ["a.txt"], oneWay: false, logDir: t.logs)
        #expect(r.differences == 0); #expect(r.checksClean)
    }
}
