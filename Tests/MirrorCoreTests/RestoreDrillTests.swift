import Testing
import Foundation
@testable import MirrorCore

/// Real rclone unless a test swaps the runner to control the outcome.
private struct StubRunner: RcloneRunning {
    var outcome: RcloneResult.Outcome = .success
    var differences = 0
    private var result: RcloneResult {
        var s = LogSummary(); s.differences = differences
        return RcloneResult(exitCode: outcome == .success ? 0 : 5, summary: s, outcome: outcome)
    }
    func sync(_: SyncRequest) async throws -> RcloneResult { result }
    func check(_: CheckRequest) async throws -> RcloneResult { result }
}

private struct Rig {
    let tmp: TempDir
    let cloud: URL
    let source: URL
    let scratch: URL
    let kit: RecoveryKit
    let relative = "Sets/Docs/sub/note.txt"
    var original: URL { source.appendingPathComponent("sub/note.txt") }
    let context = RcloneContext(configPath: "/dev/null", environment: [:])

    init(kind: DestinationKind = .googleDrive) async throws {
        tmp = try TempDir()
        cloud = try tmp.sub("cloud"); source = try tmp.sub("source"); scratch = try tmp.sub("scratch")
        let v = VaultSecrets.generate()
        kit = RecoveryKit(kind: kind, rootPath: "Mac Backup", passphrase: v.passphrase, salt: v.salt,
                          filenameEncoding: kind == .oneDrive ? "base32768" : "base32", rcloneVersion: "v1.75.2",
                          clientID: nil, clientSecret: nil)
        let sub = try tmp.sub("source/sub")
        try "the original words".write(to: sub.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)

        // Written independently of the drill's own code: plain env keys and `rclone obscure`.
        let up = "RCLONE_CONFIG_UP_"
        let p = try realRclone(["obscure", "-"], stdin: v.passphrase).out.trimmingCharacters(in: .newlines)
        let s = try realRclone(["obscure", "-"], stdin: v.salt).out.trimmingCharacters(in: .newlines)
        let env = [up + "TYPE": "crypt", up + "REMOTE": cloud.path, up + "FILENAME_ENCRYPTION": "standard",
                   up + "DIRECTORY_NAME_ENCRYPTION": "true", up + "FILENAME_ENCODING": kit.filenameEncoding,
                   up + "PASSWORD": p, up + "PASSWORD2": s]
        #expect(try realRclone(["copy", source.path, "up:Mac Backup/Sets/Docs", "--config", "/dev/null"], env: env).code == 0)
    }

    func drill(_ runner: any RcloneRunning = RcloneRunner(binary: vendoredRclone), binary: URL = vendoredRclone) -> RestoreDrill {
        RestoreDrill(rclone: runner, binary: binary, workDir: scratch)
    }
    func run(_ k: RecoveryKit? = nil, relative r: String? = nil) async throws -> Bool {
        try await drill().run(kit: k ?? kit, encryptedRoot: cloud.path, context: context,
                              relativePath: r ?? relative, original: original)
    }
    var scratchIsEmpty: Bool { ((try? FileManager.default.contentsOfDirectory(atPath: scratch.path)) ?? ["?"]).isEmpty }
}

@Suite struct RestoreDrillTests {
    @Test func drillPassesWithRightKit() async throws {
        let rig = try await Rig()
        #expect(try await rig.run())
        #expect(rig.scratchIsEmpty)   // the decrypted copy doesn't stay behind
    }

    @Test func drillPassesOnOneDriveEncoding() async throws {
        let rig = try await Rig(kind: .oneDrive)
        #expect(try await rig.run())
    }

    @Test func drillPassesWithAKitPastedBackFromText() async throws {
        let rig = try await Rig()
        #expect(try await rig.run(RecoveryKit(parsing: rig.kit.text())))
    }

    @Test func drillFailsWithWrongPassphrase() async throws {
        let rig = try await Rig()
        var k = rig.kit; k.passphrase = VaultSecrets.generate().passphrase
        #expect(try await rig.run(k) == false)
        #expect(rig.scratchIsEmpty)
    }

    @Test func drillFailsWithWrongSalt() async throws {
        let rig = try await Rig()
        var k = rig.kit; k.salt = VaultSecrets.generate().salt
        #expect(try await rig.run(k) == false)
    }

    @Test func drillFailsWithWrongFilenameEncoding() async throws {
        let rig = try await Rig()
        var k = rig.kit; k.filenameEncoding = "base32768"
        #expect(try await rig.run(k) == false)
    }

    @Test func drillFailsWhenOriginalDiffers() async throws {
        let rig = try await Rig()
        try "changed locally!!!".write(to: rig.original, atomically: true, encoding: .utf8)   // same length is not needed
        #expect(try await rig.run() == false)
    }

    @Test func drillFailsWhenFileIsMissingFromBackup() async throws {
        let rig = try await Rig()
        try FileManager.default.removeItem(at: rig.cloud)
        try FileManager.default.createDirectory(at: rig.cloud, withIntermediateDirectories: true)
        #expect(try await rig.run() == false)
    }

    /// The download is compared byte for byte, so a check that wrongly passes can't pass the drill.
    @Test func downloadComparisonStandsOnItsOwn() async throws {
        let rig = try await Rig()
        try "tampered".write(to: rig.original, atomically: true, encoding: .utf8)
        let result = try await rig.drill(StubRunner()).run(kit: rig.kit, encryptedRoot: rig.cloud.path, context: rig.context,
                                                           relativePath: rig.relative, original: rig.original)
        #expect(result == false)
    }

    @Test func checkDifferencesFailTheDrill() async throws {
        let rig = try await Rig()
        let result = try await rig.drill(StubRunner(differences: 1)).run(kit: rig.kit, encryptedRoot: rig.cloud.path, context: rig.context,
                                                                         relativePath: rig.relative, original: rig.original)
        #expect(result == false)
    }

    /// A network failure says nothing about the kit, so it must not raise the failed-drill alarm.
    @Test func transientProblemsThrowInsteadOfFailing() async throws {
        let rig = try await Rig()
        for (outcome, expected) in [(RcloneResult.Outcome.transient, RestoreDrillError.couldNotRun),
                                    (.authExpired, RestoreDrillError.signInExpired)] {
            await #expect(throws: expected) {
                try await rig.drill(StubRunner(outcome: outcome)).run(kit: rig.kit, encryptedRoot: rig.cloud.path, context: rig.context,
                                                                      relativePath: rig.relative, original: rig.original)
            }
        }
        #expect(rig.scratchIsEmpty)
    }

    @Test func secretsAreNeverInArgv() async throws {
        let rig = try await Rig()
        let record = rig.tmp.url.appendingPathComponent("record")
        let fake = try fakeRclone(in: rig.tmp.url, body: """
            printf '%s\\n' "$@" >> '\(record.path)'
            /usr/bin/env >> '\(record.path)'.env
            cat >/dev/null
            echo obscured-stand-in
            exit 0
            """)
        _ = try await rig.drill(StubRunner(), binary: fake).run(kit: rig.kit, encryptedRoot: rig.cloud.path, context: rig.context,
                                                                relativePath: rig.relative, original: rig.original)
        let args = try String(contentsOf: record, encoding: .utf8)
        #expect(!args.contains(rig.kit.passphrase) && !args.contains(rig.kit.salt))
        #expect(args.contains("copyto\n") && args.contains("Mac Backup/" + rig.relative))
        let env = try String(contentsOfFile: record.path + ".env", encoding: .utf8)
        #expect(!env.contains(rig.kit.passphrase) && !env.contains(rig.kit.salt))   // obscured only
        #expect(env.contains("_TYPE=crypt"))
    }

    @Test func pathsThatEscapeTheRootAreRefused() async throws {
        let rig = try await Rig()
        for bad in ["", "/etc/hosts", "../note.txt", "Sets/../../note.txt"] {
            await #expect(throws: RestoreDrillError.invalidPath) { try await rig.run(relative: bad) }
        }
    }

    @Test func mismatchedOriginalNameIsRefused() async throws {
        let rig = try await Rig()
        await #expect(throws: RestoreDrillError.invalidPath) { try await rig.run(relative: "Sets/Docs/sub/other.txt") }
    }
}
