import Testing
import Foundation
import MirrorCore
@testable import Mirror

final class Flag: @unchecked Sendable { private(set) var value = false; func set() { value = true } }

@MainActor
struct DrillModelTests {
    let kit: String = RecoveryKit(kind: .googleDrive, rootPath: "Mac Backup", passphrase: String(repeating: "a", count: 64), salt: String(repeating: "b", count: 64),
                                  filenameEncoding: "base32", rcloneVersion: "1.70.0", clientID: "id", clientSecret: "secret").text()
    func setup() throws -> (ConfigStore, BackupSet, Destination) {
        let store = ConfigStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("mirror-test-\(UUID().uuidString)"))
        let dest = Destination(name: "Drive", kind: .googleDrive)
        let set = BackupSet(name: "Docs", source: URL(fileURLWithPath: "/tmp/x"), destinationIDs: [dest.id])
        try store.saveSets([set]); try store.saveDestinations([dest])
        return (store, set, dest)
    }
    func model(_ dest: Destination, store: ConfigStore, run: @escaping DrillModel.Runner) -> DrillModel {
        let m = DrillModel(destinations: [dest], store: store,
                           candidate: { _ in DrillCandidate(relativePath: "Sets/Docs/a.txt", original: URL(fileURLWithPath: "/tmp/x/a.txt")) },
                           run: run)
        m.kitText = kit
        return m
    }

    @Test func passUpdatesLastDrill() async throws {
        let (store, set, dest) = try setup()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let m = model(dest, store: store) { _, _, _, _ in true }
        m.now = { now }
        await m.start()
        #expect(m.phase == .finished(.passed))
        #expect(try store.state(for: PairID(set: set.id, destination: dest.id)).lastDrill == now)
        #expect(m.kitText.isEmpty)   // the Kit does not linger in memory
    }

    @Test func falseIsABadKitAndLeavesLastDrill() async throws {
        let (store, set, dest) = try setup()
        let m = model(dest, store: store) { _, _, _, _ in false }
        await m.start()
        #expect(m.phase == .finished(.badKit))
        #expect(try store.state(for: PairID(set: set.id, destination: dest.id)).lastDrill == nil)
    }

    @Test func parseFailureFromTheAgentIsABadKit() async throws {
        let (store, _, dest) = try setup()
        let m = model(dest, store: store) { _, _, _, _ in throw RecoveryKitError.malformedLine }
        await m.start()
        #expect(m.phase == .finished(.badKit))
    }

    @Test func textThatIsNotAKitNeverReachesTheAgent() async throws {
        let (store, _, dest) = try setup()
        let called = Flag()
        let m = model(dest, store: store) { _, _, _, _ in called.set(); return true }
        m.kitText = "hello"
        await m.start()
        #expect(m.phase == .finished(.badKit) && !called.value)
    }

    @Test func networkFailureIsCouldntTell() async throws {
        let (store, set, dest) = try setup()
        for error: any Error in [URLError(.notConnectedToInternet), RestoreDrillError.couldNotRun, RestoreDrillError.signInExpired,
                                 AgentClientError.noResponse(exitCode: 1), RcloneSessionError.notSignedIn] {
            let m = model(dest, store: store) { _, _, _, _ in throw error }
            await m.start()
            #expect(m.phase == .finished(.couldntTell), "\(error)")
        }
        #expect(try store.state(for: PairID(set: set.id, destination: dest.id)).lastDrill == nil)
    }

    @Test func noCandidateFileIsNotAFailure() async throws {
        let (store, _, dest) = try setup()
        let m = DrillModel(destinations: [dest], store: store, candidate: { _ in nil }, run: { _, _, _, _ in true })
        m.kitText = kit
        await m.start()
        #expect(m.phase == .nothingToTest)
    }
}

private let vendoredRclone = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("vendor/rclone/rclone")

func drillFolder(_ files: [String]) throws -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("mirror-test-\(UUID().uuidString)")
    for f in files {
        let u = d.appendingPathComponent(f)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: u)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000)], ofItemAtPath: u.path)
    }
    return d
}

@MainActor
struct DrillPickerTests {
    let finished = Date(timeIntervalSince1970: 2_000_000)
    func fake(_ names: [String]?) -> DrillFilePicker.Lister { { _ in names } }

    @Test func prefersPlainTextAndShallowFiles() async throws {
        let d = try drillFolder(["a.bin", "b.dat", "z.md", "sub/a.txt"])
        let c = await DrillFilePicker.pick(in: BackupSet(name: "S", source: d), finishedBefore: finished,
                                           list: fake(["a.bin", "b.dat", "sub/a.txt", "z.md"]))
        #expect(c?.original.lastPathComponent == "z.md")
        #expect(c?.relativePath == "Sets/S/z.md")
    }

    @Test func secretsGitAndHiddenAreSkippedEvenIfListed() async throws {
        let d = try drillFolder([".env", "a.pem", "id_rsa", "key.properties", ".gitignore", "sub/prod.key", ".git/config", "ok.txt"])
        let listed = [".env", "a.pem", "id_rsa", "key.properties", ".gitignore", "sub/prod.key", ".git/config", "keys/x.p12", "ok.txt"]
        let c = await DrillFilePicker.pick(in: BackupSet(name: "S", source: d), finishedBefore: finished, list: fake(listed))
        #expect(c?.original.lastPathComponent == "ok.txt")
        #expect(await DrillFilePicker.pick(in: BackupSet(name: "S", source: d), finishedBefore: finished,
                                           list: fake([".env", "a.pem", ".git/config", "sub/prod.key"])) == nil)
    }

    @Test func listerFailureMeansNothingSuitable() async throws {
        let d = try drillFolder(["notes.txt"])
        #expect(await DrillFilePicker.pick(in: BackupSet(name: "S", source: d), finishedBefore: finished, list: fake(nil)) == nil)
        #expect(await DrillFilePicker.pick(in: BackupSet(name: "S", source: d), finishedBefore: nil, list: fake(["notes.txt"])) == nil)
    }

    @Test func realRcloneAppliesPathClassAndIncludeRules() async throws {
        let d = try drillFolder(["build/out.txt", "xkeep.dat", "ykeep.dat", "notes/readme.txt", "prod.pem", "app.log"])
        var set = BackupSet(name: "S", source: d)
        set.rules = [UserRule(pattern: "/prod.pem", action: .include),        // an include must not bring a secret back
                     UserRule(pattern: "/build/**", action: .exclude),        // path rule
                     UserRule(pattern: "/[!x]*.dat", action: .exclude),       // class: in rclone `!` is not negation, so this hits xkeep.dat
                     UserRule(pattern: "*.log", action: .exclude)]
        let listed = await DrillFilePicker.rcloneLister(binary: vendoredRclone)(set)
        #expect(Set(listed ?? []) == ["ykeep.dat", "notes/readme.txt", "prod.pem"])   // rclone's own answer, not ours
        let c = await DrillFilePicker.pick(in: set, finishedBefore: finished, list: DrillFilePicker.rcloneLister(binary: vendoredRclone))
        #expect(c?.original.lastPathComponent == "readme.txt")   // plain text first; never prod.pem
    }

    @Test func missingRcloneMeansNothingSuitable() async throws {
        let d = try drillFolder(["notes.txt"])
        let listed = await DrillFilePicker.rcloneLister(binary: URL(fileURLWithPath: "/nonexistent/rclone"))(BackupSet(name: "S", source: d))
        #expect(listed == nil)
    }

    @Test func discardClearsTheKit() throws {
        let store = ConfigStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("mirror-test-\(UUID().uuidString)"))
        let m = DrillModel(destinations: [Destination(name: "D", kind: .googleDrive)], store: store, candidate: { _ in nil }, run: { _, _, _, _ in true })
        m.kitText = "secret"
        m.discard()
        #expect(m.kitText.isEmpty && m.phase == .idle)
    }
}

struct BoundedProcessTests {
    @Test func finishedProcessReturnsItsExitCode() async {
        #expect(await BoundedProcess.run(URL(fileURLWithPath: "/usr/bin/true"), [], timeout: 5) == 0)
        #expect(await BoundedProcess.run(URL(fileURLWithPath: "/usr/bin/false"), [], timeout: 5) == 1)
    }

    @Test func aHungProcessIsKilledAtTheTimeout() async {
        let start = Date()
        #expect(await BoundedProcess.run(URL(fileURLWithPath: "/bin/sleep"), ["30"], timeout: 0.4) == nil)
        #expect(Date().timeIntervalSince(start) < 5)
    }

    @Test func missingExecutableIsNil() async {
        #expect(await BoundedProcess.run(URL(fileURLWithPath: "/nonexistent/x"), [], timeout: 1) == nil)
    }
}

struct AccessConfirmationTests {
    /// Any readable file, standing in for the TCC database.
    let probe = URL(fileURLWithPath: #filePath)

    func support() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("mirror-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test func confirmsWhenTheKickedAgentWritesAFreshPassingReport() async throws {
        let s = try support()
        let ok = await AccessConfirmation.confirm(support: s, timeout: 3, kick: { AgentAccess.writeReport(support: s, paths: [s], fullDiskProbe: probe); return true })
        #expect(ok == .confirmed)
    }

    @Test func aStalePassingReportIsNotEnoughAfterAKick() async throws {
        let s = try support()
        AgentAccess.writeReport(support: s, paths: [s], fullDiskProbe: probe, now: Date().addingTimeInterval(-600))
        #expect(await AccessConfirmation.confirm(support: s, timeout: 0.6, kick: { true }) == .notConfirmed)
    }

    @Test func aFailingReportIsNotConfirmed() async throws {
        let s = try support()
        let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
        #expect(await AccessConfirmation.confirm(support: s, timeout: 0.6, kick: { AgentAccess.writeReport(support: s, paths: [missing], fullDiskProbe: probe); return true }) == .notConfirmed)
    }

    @Test func kickstartArgumentsNameTheAgentInTheUsersDomain() {
        #expect(AccessConfirmation.kickstartArguments(uid: 501) == ["kickstart", "gui/501/com.shaikjaleel.mirror.agent"])
    }

    @Test func aFailedKickstartReturnsAtOnce() async throws {
        let s = try support()
        let start = Date()
        #expect(await AccessConfirmation.confirm(support: s, timeout: 15, kick: { false }) == .kickFailed)
        #expect(Date().timeIntervalSince(start) < 2)
    }
}

struct BoundedOutputTests {
    @Test func capturesStdoutAndTimesOut() async {
        let r = await BoundedProcess.output(URL(fileURLWithPath: "/bin/echo"), ["hi"], timeout: 5)
        #expect(r?.code == 0 && String(decoding: r?.output ?? Data(), as: UTF8.self) == "hi\n")
        #expect(await BoundedProcess.output(URL(fileURLWithPath: "/bin/sleep"), ["30"], timeout: 0.3) == nil)
    }
}
