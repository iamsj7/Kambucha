import Testing
import Foundation
@testable import KambuchaCore

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
    let storage: URL
    let source: URL
    let scratch: URL
    let kit: RecoveryKit
    let relative = "Sets/Docs/sub/note.txt"
    let encryptedRoot = "base:Mac Backup"
    var original: URL { source.appendingPathComponent("sub/note.txt") }
    let context: RcloneContext
    var conf: URL { URL(fileURLWithPath: context.configPath) }

    init(kind: DestinationKind = .googleDrive) async throws {
        tmp = try TempDir()
        storage = try tmp.sub("storage"); source = try tmp.sub("source"); scratch = try tmp.sub("scratch")
        let root = try tmp.sub("storage/Mac Backup")
        let v = VaultSecrets.generate()
        kit = RecoveryKit(kind: kind, rootPath: "Mac Backup", passphrase: v.passphrase, salt: v.salt,
                          filenameEncoding: kind == .oneDrive ? "base32768" : "base32", rcloneVersion: "v1.75.2",
                          clientID: "client-id-not-real", clientSecret: "client-secret-not-real")
        let sub = try tmp.sub("source/sub")
        try "the original words".write(to: sub.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)

        // A sign-in section as a session writes it, with a folder in place of the cloud.
        let file = tmp.url.appendingPathComponent("rclone.conf")
        try """
            [base]
            type = alias
            remote = \(storage.path)
            client_id = client-id-not-real
            client_secret = client-secret-not-real

            """.write(to: file, atomically: true, encoding: .utf8)
        context = RcloneContext(configPath: file.path, environment: [:])

        // Written independently of the drill's own code: plain env keys and `rclone obscure`.
        let up = "RCLONE_CONFIG_UP_"
        let p = try realRclone(["obscure", "-"], stdin: v.passphrase).out.trimmingCharacters(in: .newlines)
        let s = try realRclone(["obscure", "-"], stdin: v.salt).out.trimmingCharacters(in: .newlines)
        let env = [up + "TYPE": "crypt", up + "REMOTE": root.path, up + "FILENAME_ENCRYPTION": "standard",
                   up + "DIRECTORY_NAME_ENCRYPTION": "true", up + "FILENAME_ENCODING": kit.filenameEncoding,
                   up + "PASSWORD": p, up + "PASSWORD2": s]
        #expect(try realRclone(["copy", source.path, "up:Sets/Docs", "--config", "/dev/null"], env: env).code == 0)
    }

    func drill(_ runner: any RcloneRunning = RcloneRunner(binary: vendoredRclone, helper: AnyHelper()), binary: URL = vendoredRclone,
               helper: any HelperValidating = AnyHelper()) -> RestoreDrill {
        RestoreDrill(rclone: runner, binary: binary, helper: helper, workDir: scratch)
    }
    func run(_ k: RecoveryKit? = nil, relative r: String? = nil, root: String? = nil) async throws -> Bool {
        try await drill().run(kit: k ?? kit, encryptedRoot: root ?? encryptedRoot, context: context,
                              relativePath: r ?? relative, original: original)
    }
    func run(with runner: any RcloneRunning, binary: URL = vendoredRclone) async throws -> Bool {
        try await drill(runner, binary: binary).run(kit: kit, encryptedRoot: encryptedRoot, context: context,
                                                    relativePath: relative, original: original)
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
        try FileManager.default.removeItem(at: rig.storage)
        try FileManager.default.createDirectory(at: rig.storage, withIntermediateDirectories: true)
        #expect(try await rig.run() == false)
    }

    /// The download is compared byte for byte, so a check that wrongly passes can't pass the drill.
    @Test func downloadComparisonStandsOnItsOwn() async throws {
        let rig = try await Rig()
        try "tampered".write(to: rig.original, atomically: true, encoding: .utf8)
        let result = try await rig.run(with: StubRunner())
        #expect(result == false)
    }

    @Test func checkDifferencesFailTheDrill() async throws {
        let rig = try await Rig()
        let result = try await rig.run(with: StubRunner(differences: 1))
        #expect(result == false)
    }

    /// A network failure says nothing about the kit, so it must not raise the failed-drill alarm.
    @Test func transientProblemsThrowInsteadOfFailing() async throws {
        let rig = try await Rig()
        for (outcome, expected) in [(RcloneResult.Outcome.transient, RestoreDrillError.couldNotRun),
                                    (.authExpired, RestoreDrillError.signInExpired)] {
            await #expect(throws: expected) {
                try await rig.run(with: StubRunner(outcome: outcome))
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
        _ = try await rig.run(with: StubRunner(), binary: fake)
        let args = try String(contentsOf: record, encoding: .utf8)
        #expect(!args.contains(rig.kit.passphrase) && !args.contains(rig.kit.salt))
        #expect(args.contains("copyto\n") && args.contains("kambuchadrill:" + rig.relative + "\n"))
        let env = try String(contentsOfFile: record.path + ".env", encoding: .utf8)
        #expect(!env.contains(rig.kit.passphrase) && !env.contains(rig.kit.salt))   // obscured only
        #expect(env.contains("_TYPE=crypt"))
    }

    // MARK: - The kit's client details

    private func withClient(_ rig: Rig, id: String?, secret: String?) -> RecoveryKit {
        var k = rig.kit; k.clientID = id; k.clientSecret = secret
        return k
    }

    /// The kit decrypts, but its client couldn't sign in: on another Mac it wouldn't open the backup.
    @Test func drillFailsWithWrongClientDetails() async throws {
        let rig = try await Rig()
        #expect(try await rig.run(withClient(rig, id: "another-id", secret: rig.kit.clientSecret)) == false)
        #expect(try await rig.run(withClient(rig, id: rig.kit.clientID, secret: "another-secret")) == false)
    }

    @Test func drillFailsWithMissingClientDetails() async throws {
        let rig = try await Rig()
        #expect(try await rig.run(withClient(rig, id: nil, secret: rig.kit.clientSecret)) == false)
        #expect(try await rig.run(withClient(rig, id: rig.kit.clientID, secret: nil)) == false)
    }

    @Test func drillFailsWithoutASignInSectionToCompare() async throws {
        let rig = try await Rig()
        #expect(try await rig.run(root: "other:Mac Backup") == false)
    }

    @Test func drillFailsWhenKitRootIsNotTheEncryptedRoot() async throws {
        let rig = try await Rig()
        var k = rig.kit; k.rootPath = "Other Backup"
        #expect(try await rig.run(k) == false)
    }

    // MARK: - Network and sign-in failures

    private func fakeCloud(_ rig: Rig, lsf: String) throws -> URL {
        try fakeRclone(in: rig.tmp.url, body: """
            if [ "$1" = obscure ]; then cat >/dev/null; echo obscured-stand-in; exit 0; fi
            if [ "$1" = lsf ]; then
              while [ $# -gt 0 ]; do [ "$1" = --log-file ] && log="$2"; shift; done
              \(lsf)
            fi
            exit 1
            """)
    }

    /// Generic exit 1 is what most network failures give. It says nothing about the kit.
    @Test func unreachableCloudThrows() async throws {
        let rig = try await Rig()
        let fake = try fakeCloud(rig, lsf: "exit 1")
        await #expect(throws: RestoreDrillError.couldNotRun) { try await rig.run(with: StubRunner(), binary: fake) }
        #expect(rig.scratchIsEmpty)
    }

    @Test func expiredSignInThrows() async throws {
        let rig = try await Rig()
        let fake = try fakeCloud(rig, lsf: #"echo '{"level":"error","msg":"oauth2: invalid_grant"}' > "$log"; exit 1"#)
        await #expect(throws: RestoreDrillError.signInExpired) { try await rig.run(with: StubRunner(), binary: fake) }
    }

    /// The cloud drops out after the first look: the later failure must not read as a bad kit.
    @Test func cloudLostMidDrillThrows() async throws {
        let rig = try await Rig()
        let count = rig.tmp.url.appendingPathComponent("count")
        let fake = try fakeCloud(rig, lsf: "[ -f '\(count.path)' ] && exit 1; touch '\(count.path)'; exit 0")
        await #expect(throws: RestoreDrillError.couldNotRun) {
            try await rig.run(with: StubRunner(outcome: .permanent), binary: fake)
        }
    }

    /// Cloud reachable, permanent failure: now it really is the kit or the backup.
    @Test func reachableCloudWithPermanentFailureFails() async throws {
        let rig = try await Rig()
        let fake = try fakeCloud(rig, lsf: "exit 0")
        #expect(try await rig.run(with: StubRunner(outcome: .permanent), binary: fake) == false)
    }

    /// Five spawns get the kit's keys or the sign-in: two obscures, the look, cryptcheck, the download.
    @Test func everyDrillSpawnIsValidatedFirst() async throws {
        let rig = try await Rig()
        let log = rig.tmp.url.appendingPathComponent("log")
        try Data().write(to: log)
        let fake = try fakeRclone(in: rig.tmp.url, body: """
            echo "spawn $1" >> '\(log.path)'
            case "$1" in
              obscure) cat >/dev/null; echo obscured-stand-in ;;
              copyto) printf 'the original words' > "$3" ;;
            esac
            exit 0
            """)
        let helper = LoggingHelper(log: log)
        let drill = RestoreDrill(rclone: RcloneRunner(binary: fake, helper: helper), binary: fake, helper: helper, workDir: rig.scratch)
        #expect(try await drill.run(kit: rig.kit, encryptedRoot: rig.encryptedRoot, context: rig.context,
                                    relativePath: rig.relative, original: rig.original))
        #expect(try everySpawnWasValidated(log))
        let spawns = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").filter { $0.hasPrefix("spawn") }
        #expect(spawns.map(String.init) == ["spawn obscure", "spawn obscure", "spawn lsf", "spawn cryptcheck", "spawn copyto"])
    }

    @Test func untrustedHelperStopsTheDrill() async throws {
        let rig = try await Rig()
        await #expect(throws: AgentFailure.untrustedHelper) {
            try await rig.drill(helper: RefusingHelper()).run(kit: rig.kit, encryptedRoot: rig.encryptedRoot, context: rig.context,
                                                              relativePath: rig.relative, original: rig.original)
        }
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
