import Testing
import Foundation
@testable import MirrorCore

private final class FakeRclone: RcloneRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var _checks: [CheckRequest] = []
    private var _lists: [[String]] = []
    var differencesPerCall: [Int]
    var outcome: RcloneResult.Outcome = .success
    init(differences: [Int] = []) { differencesPerCall = differences }
    var checks: [CheckRequest] { lock.withLock { _checks } }
    var lists: [[String]] { lock.withLock { _lists } }
    func sync(_: SyncRequest) async throws -> RcloneResult { fatalError("unused") }
    func check(_ r: CheckRequest) async throws -> RcloneResult {
        let n: Int = lock.withLock {
            _checks.append(r)
            let list = r.filesFrom.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
                .map { $0.split(separator: "\n").map(String.init) } ?? []
            _lists.append(list)
            return _checks.count - 1 < differencesPerCall.count ? differencesPerCall[_checks.count - 1] : 0
        }
        var s = LogSummary(); s.differences = n
        return RcloneResult(exitCode: n > 0 ? 1 : 0, summary: s, outcome: outcome)
    }
}

private final class FakeAuditor: UploadAuditing, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [[URL]] = []
    var result = AuditResult(pending: [], refused: [])
    var calls: [[URL]] { lock.withLock { _calls } }
    func audit(_ urls: [URL]) -> AuditResult { lock.withLock { _calls.append(urls) }; return result }
}

private func ctx() -> RcloneContext { RcloneContext(configPath: "/dev/null", environment: [:]) }
private func profile(_ kind: DestinationKind, encrypted: Bool = false) -> DestinationProfile {
    DestinationProfile.profile(for: Destination(name: "d", kind: kind, encrypted: encrypted))
}

private struct Env {
    let root: URL, src: URL, dst: URL, logs: URL, filter: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ver-\(UUID().uuidString)")
        src = root.appendingPathComponent("src"); dst = root.appendingPathComponent("dst")
        logs = root.appendingPathComponent("logs"); filter = root.appendingPathComponent("f.filter")
        for d in [src, dst, logs] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        try Data("+ **\n".utf8).write(to: filter)
    }
    func mirror(_ names: [String]) throws {
        for n in names {
            let u = dst.appendingPathComponent(n)
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(n.utf8).write(to: u)
        }
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

@Suite struct VerifierTests {
    /// Eviction can happen between two reads, so one read decides each file.
    @Test func eachFileIsHashedOrSkippedNeverBothOrNeither() async throws {
        let e = try Env(); defer { e.cleanup() }
        final class Flip: @unchecked Sendable {
            let lock = NSLock(); var reads = 0
            func read() -> Bool { lock.withLock { reads += 1; return reads % 2 == 0 } }
        }
        let flip = Flip(), rclone = FakeRclone()
        let v = Verifier(rclone: rclone, auditor: FakeAuditor(), isDataless: { _ in flip.read() })
        let result = try await v.quick(source: e.src, destination: e.dst.path, profile: profile(.iCloudFolder), context: ctx(),
                                       filter: e.filter, copied: ["a", "b", "c", "d"], oneWay: false, logDir: e.logs)
        #expect(flip.reads == 4)
        #expect(Set((rclone.lists.last ?? []) + result.skippedFreed) == ["a", "b", "c", "d"])
    }

    @Test func aLinkIsAuditedByItsNameInTheMirror() async throws {
        let e = try Env(); defer { e.cleanup() }
        let rclone = FakeRclone(), auditor = FakeAuditor()
        let v = Verifier(rclone: rclone, auditor: auditor, isDataless: { _ in false })
        _ = try await v.quick(source: e.src, destination: e.dst.path, profile: profile(.iCloudFolder), context: ctx(),
                              filter: e.filter, copied: ["p/link.rclonelink"], oneWay: false, logDir: e.logs)
        #expect(auditor.calls.first?.map(\.lastPathComponent) == ["link"])
        #expect(rclone.lists.last == ["p/link.rclonelink"])   // the hash list keeps rclone's own name
    }

    @Test func quickRunsSizeOnlyThenHashOfCopied() async throws {
        let e = try Env(); defer { e.cleanup() }
        try e.mirror(["a.txt", "d/b.txt"])
        let rc = FakeRclone(); let v = Verifier(rclone: rc, auditor: FakeAuditor())
        _ = try await v.quick(source: e.src, destination: e.dst.path, profile: profile(.iCloudFolder), context: ctx(),
                              filter: e.filter, copied: ["a.txt", "d/b.txt"], oneWay: false, logDir: e.logs)
        #expect(rc.checks.count == 2)
        #expect(rc.checks[0].sizeOnly && rc.checks[0].filterFile == e.filter && rc.checks[0].filesFrom == nil)
        #expect(!rc.checks[1].sizeOnly && rc.checks[1].filesFrom != nil)
        #expect(rc.lists[1].sorted() == ["a.txt", "d/b.txt"])
    }

    @Test func quickSkipsHashWhenNothingCopied() async throws {
        let e = try Env(); defer { e.cleanup() }
        let rc = FakeRclone(); let v = Verifier(rclone: rc, auditor: FakeAuditor())
        _ = try await v.quick(source: e.src, destination: e.dst.path, profile: profile(.iCloudFolder), context: ctx(),
                              filter: e.filter, copied: [], oneWay: false, logDir: e.logs)
        #expect(rc.checks.count == 1)
    }

    @Test func quickOneWayPassedThrough() async throws {
        let e = try Env(); defer { e.cleanup() }
        try e.mirror(["a"])
        let rc = FakeRclone(); let v = Verifier(rclone: rc, auditor: FakeAuditor())
        _ = try await v.quick(source: e.src, destination: e.dst.path, profile: profile(.iCloudFolder), context: ctx(),
                              filter: e.filter, copied: ["a"], oneWay: true, logDir: e.logs)
        #expect(rc.checks.allSatisfy { $0.oneWay })
        let rc2 = FakeRclone(); let v2 = Verifier(rclone: rc2, auditor: FakeAuditor())
        _ = try await v2.quick(source: e.src, destination: e.dst.path, profile: profile(.iCloudFolder), context: ctx(),
                               filter: e.filter, copied: ["a"], oneWay: false, logDir: e.logs)
        #expect(rc2.checks.allSatisfy { !$0.oneWay })
    }

    @Test func pendingUploadsKeepChecksCleanButNotBackedUp() async throws {
        let e = try Env(); defer { e.cleanup() }
        try e.mirror(["a"])
        let au = FakeAuditor(); au.result = AuditResult(pending: ["a"], refused: [])
        let v = Verifier(rclone: FakeRclone(), auditor: au)
        let r = try await v.quick(source: e.src, destination: e.dst.path, profile: profile(.iCloudFolder), context: ctx(),
                                  filter: e.filter, copied: ["a"], oneWay: false, logDir: e.logs)
        #expect(r.checksClean); #expect(!r.backedUp); #expect(r.audit.pending == ["a"])
        #expect(au.calls.first == [e.dst.appendingPathComponent("a")])
    }

    @Test func refusedIsReported() async throws {
        let e = try Env(); defer { e.cleanup() }
        try e.mirror(["a.tmp"])
        let au = FakeAuditor(); au.result = AuditResult(pending: [], refused: ["a.tmp"])
        let v = Verifier(rclone: FakeRclone(), auditor: au)
        let r = try await v.quick(source: e.src, destination: e.dst.path, profile: profile(.iCloudFolder), context: ctx(),
                                  filter: e.filter, copied: ["a.tmp"], oneWay: false, logDir: e.logs)
        #expect(r.audit.refused == ["a.tmp"]); #expect(r.checksClean); #expect(!r.backedUp)
    }

    @Test func differencesFail() async throws {
        let e = try Env(); defer { e.cleanup() }
        try e.mirror(["a"])
        let rc = FakeRclone(differences: [2, 1])
        let v = Verifier(rclone: rc, auditor: FakeAuditor())
        let r = try await v.quick(source: e.src, destination: e.dst.path, profile: profile(.iCloudFolder), context: ctx(),
                                  filter: e.filter, copied: ["a"], oneWay: false, logDir: e.logs)
        #expect(r.differences == 3); #expect(!r.checksClean); #expect(!r.backedUp)
    }

    @Test func failedCheckRunThrowsNeverPasses() async throws {
        let e = try Env(); defer { e.cleanup() }
        let rc = FakeRclone(); rc.outcome = .transient
        let v = Verifier(rclone: rc, auditor: FakeAuditor())
        await #expect(throws: VerifyError.self) {
            _ = try await v.quick(source: e.src, destination: e.dst.path, profile: profile(.iCloudFolder), context: ctx(),
                                  filter: e.filter, copied: [], oneWay: false, logDir: e.logs)
        }
    }

    @Test func cloudSkipsUploadAudit() async throws {
        let e = try Env(); defer { e.cleanup() }
        let au = FakeAuditor(); au.result = AuditResult(pending: ["x"], refused: ["y"])
        let v = Verifier(rclone: FakeRclone(), auditor: au)
        let r = try await v.quick(source: e.src, destination: "gd:Backup", profile: profile(.googleDrive), context: ctx(),
                                  filter: e.filter, copied: ["a"], oneWay: false, logDir: e.logs)
        #expect(au.calls.isEmpty); #expect(r.audit == AuditResult(pending: [], refused: []))
    }

    @Test func encryptedUsesCryptCheckForCopiedAndDeep() async throws {
        let e = try Env(); defer { e.cleanup() }
        let rc = FakeRclone(); let v = Verifier(rclone: rc, auditor: FakeAuditor())
        let p = profile(.googleDrive, encrypted: true)
        _ = try await v.quick(source: e.src, destination: "gd:B", profile: p, context: ctx(), filter: e.filter,
                              copied: ["a"], oneWay: false, logDir: e.logs)
        _ = try await v.deep(source: e.src, destination: "gd:B", profile: p, context: ctx(), filter: e.filter,
                             sampleFreed: 0, logDir: e.logs)
        #expect(rc.checks.count == 3)
        #expect(rc.checks[0].sizeOnly && !rc.checks[0].cryptCheck)
        #expect(rc.checks[1].cryptCheck && rc.checks[2].cryptCheck)
        let rc2 = FakeRclone()
        _ = try await Verifier(rclone: rc2, auditor: FakeAuditor()).deep(
            source: e.src, destination: "gd:B", profile: profile(.googleDrive), context: ctx(), filter: e.filter,
            sampleFreed: 0, logDir: e.logs)
        #expect(!rc2.checks[0].cryptCheck)
    }

    @Test func deepOnCloudUsesWholeSet() async throws {
        let e = try Env(); defer { e.cleanup() }
        let rc = FakeRclone(); let v = Verifier(rclone: rc, auditor: FakeAuditor())
        _ = try await v.deep(source: e.src, destination: "gd:B", profile: profile(.googleDrive), context: ctx(),
                             filter: e.filter, sampleFreed: 5, logDir: e.logs)
        #expect(rc.checks.count == 1)
        #expect(rc.checks[0].filesFrom == nil && rc.checks[0].filterFile == e.filter && !rc.checks[0].sizeOnly)
    }

    @Test func deepExcludesDatalessFiles() async throws {
        let e = try Env(); defer { e.cleanup() }
        try e.mirror(["keep.txt", "freed1", "d/freed2", "d/ok"])
        let rc = FakeRclone()
        let v = Verifier(rclone: rc, auditor: FakeAuditor(), isDataless: { $0.lastPathComponent.hasPrefix("freed") })
        _ = try await v.deep(source: e.src, destination: e.dst.path, profile: profile(.iCloudFolder), context: ctx(),
                             filter: e.filter, sampleFreed: 0, logDir: e.logs)
        #expect(rc.checks.count == 2)
        #expect(rc.lists[1].sorted() == ["d/ok", "keep.txt"])
        #expect(rc.checks[1].filterFile == nil)
    }

    /// A list naming a link's mirror name matches nothing in rclone, so it would go unchecked and pass.
    @Test func deepHashesALinkUnderRclonesNameAndAuditsItUnderItsOwn() async throws {
        let e = try Env(); defer { e.cleanup() }
        try e.mirror(["ok"])
        try FileManager.default.createSymbolicLink(atPath: e.dst.appendingPathComponent("link").path, withDestinationPath: "ok")
        let rc = FakeRclone(), auditor = FakeAuditor()
        let v = Verifier(rclone: rc, auditor: auditor, isDataless: { _ in false })
        let result = try await v.deep(source: e.src, destination: e.dst.path, profile: profile(.iCloudFolder), context: ctx(),
                                      filter: e.filter, sampleFreed: 0, logDir: e.logs)
        #expect(rc.lists[1].sorted() == ["link.rclonelink", "ok"])
        #expect(result.hashedPaths == ["link.rclonelink", "ok"])
        #expect(auditor.calls.flatMap { $0 }.map(\.lastPathComponent).sorted() == ["link", "ok"])
    }

    @Test func deepSamplesAtMostRequested() async throws {
        let e = try Env(); defer { e.cleanup() }
        try e.mirror(["ok", "freed1", "freed2", "freed3", "freed4"])
        let rc = FakeRclone()
        let v = Verifier(rclone: rc, auditor: FakeAuditor(), isDataless: { $0.lastPathComponent.hasPrefix("freed") })
        _ = try await v.deep(source: e.src, destination: e.dst.path, profile: profile(.iCloudFolder), context: ctx(),
                             filter: e.filter, sampleFreed: 2, logDir: e.logs)
        let freed = rc.lists[1].filter { $0.hasPrefix("freed") }
        #expect(freed.count == 2); #expect(rc.lists[1].contains("ok"))
    }

    @Test func auditorMarksNonICloudFileRefused() throws {
        let e = try Env(); defer { e.cleanup() }
        try e.mirror(["a.txt"])
        let f = e.dst.appendingPathComponent("a.txt")
        let r = ICloudAuditor().audit([f])
        #expect(r.refused == [f.path]); #expect(r.pending.isEmpty); #expect(r.missing.isEmpty)
    }

    @Test func auditorReportsVanishedPathAsMissingNotRefused() throws {
        let e = try Env(); defer { e.cleanup() }
        let gone = e.dst.appendingPathComponent("gone.txt")
        let r = ICloudAuditor().audit([gone])
        #expect(r.missing == [gone.path]); #expect(r.refused.isEmpty); #expect(r.pending.isEmpty)
    }

    @Test func auditorTreatsDanglingLinkAsItselfNotMissing() throws {
        let e = try Env(); defer { e.cleanup() }
        let l = e.dst.appendingPathComponent("dangling")
        try FileManager.default.createSymbolicLink(atPath: l.path, withDestinationPath: "/nonexistent/x")
        let r = ICloudAuditor().audit([l])
        #expect(r.missing.isEmpty)   // lstat sees the link; it is judged itself, never via its target
    }

    @Test func backedUpRequiresNothingPendingRefusedOrMissing() {
        let none = AuditResult(pending: [], refused: [])
        #expect(VerifyResult(differences: 0, audit: none).backedUp)
        #expect(!VerifyResult(differences: 0, audit: AuditResult(pending: ["a"], refused: [])).backedUp)
        #expect(!VerifyResult(differences: 0, audit: AuditResult(pending: [], refused: ["a"])).backedUp)
        #expect(!VerifyResult(differences: 0, audit: AuditResult(pending: [], refused: [], missing: ["a"])).backedUp)
        #expect(!VerifyResult(differences: 1, audit: none).backedUp)
    }

    @Test func deepOnMissingMirrorThrows() async throws {
        let e = try Env(); defer { e.cleanup() }
        let v = Verifier(rclone: FakeRclone(), auditor: FakeAuditor())
        await #expect(throws: VerifyError.self) {
            _ = try await v.deep(source: e.src, destination: e.root.appendingPathComponent("nope").path,
                                 profile: profile(.iCloudFolder), context: ctx(), filter: e.filter,
                                 sampleFreed: 0, logDir: e.logs)
        }
    }

    @Test func deepOnEmptyMirrorFailsWhenSourceHasFiles() async throws {
        let e = try Env(); defer { e.cleanup() }
        let rc = FakeRclone(differences: [3])   // size-only filtered check sees the missing files
        let v = Verifier(rclone: rc, auditor: FakeAuditor())
        let r = try await v.deep(source: e.src, destination: e.dst.path, profile: profile(.iCloudFolder),
                                 context: ctx(), filter: e.filter, sampleFreed: 0, logDir: e.logs)
        #expect(!r.checksClean); #expect(r.differences == 3)
        #expect(rc.checks[0].sizeOnly && rc.checks[0].filterFile == e.filter && rc.checks[0].filesFrom == nil)
    }

    @Test func quickDropsDatalessCopied() async throws {
        let e = try Env(); defer { e.cleanup() }
        try e.mirror(["ok", "freed"])
        let rc = FakeRclone()
        let v = Verifier(rclone: rc, auditor: FakeAuditor(), isDataless: { $0.lastPathComponent == "freed" })
        _ = try await v.quick(source: e.src, destination: e.dst.path, profile: profile(.iCloudFolder), context: ctx(),
                              filter: e.filter, copied: ["ok", "freed"], oneWay: false, logDir: e.logs)
        #expect(rc.lists[1] == ["ok"])
    }
}
