import Testing
import Foundation
@testable import MirrorCore

let vendoredRclone = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("vendor/rclone/rclone")

/// In-memory stand-in for the Keychain.
final class MemorySecrets: SecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    var failWrites = false
    var failDeletes = false
    /// Stands in for another command writing during a long step: the first read of `key` sees what
    /// was there, and `value` is in place straight after. A later save would overwrite it, visibly.
    var appearsAfterFirstRead: (key: String, value: String)?
    private(set) var reads = 0
    private(set) var readKeys: [String] = []
    func read(_ key: String) throws -> String? {
        lock.withLock {
            reads += 1
            readKeys.append(key)
            let found = values[key]
            if let a = appearsAfterFirstRead, a.key == key {
                values[key] = a.value
                appearsAfterFirstRead = nil
            }
            return found
        }
    }
    func write(_ value: String, key: String) throws {
        struct WriteFailed: Error {}
        if failWrites { throw WriteFailed() }
        lock.withLock { values[key] = value }
    }
    func delete(_ key: String) throws {
        struct DeleteFailed: Error {}
        if failDeletes { throw DeleteFailed() }
        lock.withLock { values[key] = nil }
    }
    var isEmpty: Bool { lock.withLock { values.isEmpty } }
    var keys: Set<String> { lock.withLock { Set(values.keys) } }
}

final class TempDir {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("mirror-t7-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }
    func sub(_ name: String) throws -> URL {
        let u = url.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
}

/// For tests that use the unsigned vendored rclone: the real check would refuse it, correctly.
struct AnyHelper: HelperValidating {
    func verifyHelper(at: URL) throws {}
}

struct RefusingHelper: HelperValidating {
    func verifyHelper(at: URL) throws { throw AgentFailure.untrustedHelper }
}

/// Logs each validation beside the fake rclone's `spawn` lines, so their order can be checked.
struct LoggingHelper: HelperValidating {
    let log: URL
    func verifyHelper(at: URL) throws {
        let handle = try FileHandle(forWritingTo: log)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("validate\n".utf8))
        try handle.close()
    }
}

/// True when every spawn in the log came straight after a validation of its own.
func everySpawnWasValidated(_ log: URL) throws -> Bool {
    let lines = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init)
    guard lines.contains(where: { $0.hasPrefix("spawn") }) else { return false }
    return lines.indices.allSatisfy { i in !lines[i].hasPrefix("spawn") || (i > 0 && lines[i - 1] == "validate") }
}

/// Runs the real vendored rclone with only the given environment.
@discardableResult
func realRclone(_ args: [String], env: [String: String] = [:], stdin: String? = nil) throws -> (code: Int32, out: String) {
    let p = Process()
    p.executableURL = vendoredRclone
    p.arguments = args
    p.environment = RcloneRunner.childEnvironment(RcloneContext(configPath: "/dev/null", environment: env))
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    if let stdin {
        let pipe = Pipe()
        try pipe.fileHandleForWriting.write(contentsOf: Data((stdin + "\n").utf8))
        try pipe.fileHandleForWriting.close()
        p.standardInput = pipe
    } else { p.standardInput = FileHandle.nullDevice }
    try p.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

/// `rclone reveal` has no stdin form. Only made-up test values go through here.
func reveal(_ obscured: String) throws -> String {
    try realRclone(["reveal", "--", obscured]).out.trimmingCharacters(in: .newlines)   // obscured text can start with a hyphen
}

func mode(_ url: URL) throws -> Int {
    (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
}

/// Writes a shell script standing in for rclone. It records what it was given in `record`.
func fakeRclone(in dir: URL, body: String) throws -> URL {
    let u = dir.appendingPathComponent("fake-rclone")
    try "#!/bin/sh\n\(body)\n".write(to: u, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: u.path)
    return u
}

private let fakeToken = #"{"access_token":"access-one","token_type":"Bearer","refresh_token":"refresh-one","expiry":"2030-01-01T00:00:00Z"}"#
private let newToken = #"{"access_token":"access-two","token_type":"Bearer","refresh_token":"refresh-two","expiry":"2031-01-01T00:00:00Z"}"#

private struct Fixture {
    let tmp: TempDir
    let work: URL
    let secrets = MemorySecrets()
    let vault = VaultSecrets(passphrase: "test-passphrase-not-real", salt: "test-salt-not-real")
    init() throws { tmp = try TempDir(); work = try tmp.sub("work") }

    func session(_ kind: DestinationKind, encrypted: Bool? = nil, signedIn: Bool = true, vaulted: Bool = true,
                 binary: URL = vendoredRclone, helper: any HelperValidating = AnyHelper()) throws -> (RcloneSession, Destination) {
        let d = Destination(name: "My Cloud: Personal", kind: kind, encrypted: encrypted)
        if signedIn {
            try secrets.saveSignIn(["client_id": "client-id-not-real", "client_secret": "client-secret-not-real",
                                    "token": fakeToken], for: d)
        }
        if vaulted { try secrets.saveVault(vault, for: d) }
        return (RcloneSession(destination: d, secrets: secrets, binary: binary, helper: helper, workDir: work), d)
    }

    var runDirs: [String] { (try? FileManager.default.contentsOfDirectory(atPath: work.path)) ?? [] }
}

private func cryptName(_ endpoint: String) -> String {
    String(endpoint.prefix { $0 != ":" }).uppercased()
}

@Suite struct RcloneSessionTests {
    @Test func cryptEnvHasRequiredKeys() throws {
        let f = try Fixture()
        let (s, _) = try f.session(.googleDrive)
        defer { try? s.close() }
        let (endpoint, context) = try s.open()
        let p = "RCLONE_CONFIG_\(cryptName(endpoint))_"
        #expect(endpoint.hasSuffix(":") && !endpoint.contains("Mac Backup"))   // the crypt root
        #expect(context.environment[p + "TYPE"] == "crypt")
        #expect(context.environment[p + "FILENAME_ENCRYPTION"] == "standard")
        #expect(context.environment[p + "DIRECTORY_NAME_ENCRYPTION"] == "true")
        #expect(context.environment[p + "REMOTE"]?.hasSuffix(":Mac Backup") == true)
        #expect(context.environment[p + "REMOTE"] == s.encryptedRoot)
        let password = try #require(context.environment[p + "PASSWORD"])
        let password2 = try #require(context.environment[p + "PASSWORD2"])
        #expect(password != f.vault.passphrase && password2 != f.vault.salt)   // obscured, not plain
        #expect(try reveal(password) == f.vault.passphrase)
        #expect(try reveal(password2) == f.vault.salt)
    }

    @Test func googleUsesBase32() throws {
        let f = try Fixture()
        let (s, _) = try f.session(.googleDrive)
        defer { try? s.close() }
        let (endpoint, context) = try s.open()
        #expect(context.environment["RCLONE_CONFIG_\(cryptName(endpoint))_FILENAME_ENCODING"] == "base32")
    }

    @Test func oneDriveUsesBase32768() throws {
        let f = try Fixture()
        let (s, _) = try f.session(.oneDrive)
        defer { try? s.close() }
        let (endpoint, context) = try s.open()
        #expect(context.environment["RCLONE_CONFIG_\(cryptName(endpoint))_FILENAME_ENCODING"] == "base32768")
    }

    @Test func unencryptedDestinationHasNoCryptEnv() throws {
        let f = try Fixture()
        let (s, _) = try f.session(.oneDrive, encrypted: false, vaulted: false)
        defer { try? s.close() }
        let (endpoint, context) = try s.open()
        #expect(context.environment.isEmpty)
        #expect(endpoint.hasSuffix(":Mac Backup"))
        #expect(s.encryptedRoot == nil)
        let config = try String(contentsOfFile: context.configPath, encoding: .utf8)
        #expect(config.contains("type = onedrive"))
    }

    /// Keys exist, so this root holds ciphertext. A flag flipped to false must not put plaintext there.
    @Test func unencryptedOpenRefusedWhenVaultExists() throws {
        let f = try Fixture()
        let (s, _) = try f.session(.oneDrive, encrypted: false, vaulted: true)
        #expect(throws: RcloneSessionError.plaintextIntoEncryptedRoot) { try s.open() }
        #expect(f.runDirs.isEmpty)
    }

    @Test func iCloudNeedsNoConfigAtAll() throws {
        let f = try Fixture()
        let (s, _) = try f.session(.iCloudFolder, signedIn: false, vaulted: false)
        let (endpoint, context) = try s.open()
        #expect(context == RcloneContext(configPath: "/dev/null", environment: [:]))
        #expect(endpoint == MirrorPaths.backupRoot.path)
        #expect(f.runDirs.isEmpty)
        try s.close()
    }

    @Test func encryptedICloudIsRefusedNotSilentlyPlain() throws {
        let f = try Fixture()
        let (s, _) = try f.session(.iCloudFolder, encrypted: true, signedIn: false)
        #expect(throws: RcloneSessionError.encryptionNotSupported) { try s.open() }
    }

    /// Missing keys must stop the run. Uploading without crypt, or with new keys, would be far worse.
    @Test func encryptedDestinationWithoutVaultRefusesToOpen() throws {
        let f = try Fixture()
        let (s, _) = try f.session(.googleDrive, vaulted: false)
        #expect(throws: RcloneSessionError.encryptionKeysMissing) { try s.open() }
        #expect(f.runDirs.isEmpty)
    }

    @Test func unreadableVaultRefusesToOpen() throws {
        let f = try Fixture()
        let (s, d) = try f.session(.googleDrive, vaulted: false)
        try f.secrets.write("not json", key: SecretKeys.vault(d.id))
        #expect(throws: RcloneSessionError.encryptionKeysMissing) { try s.open() }
    }

    @Test func destinationWithoutSignInRefusesToOpen() throws {
        let f = try Fixture()
        let (s, _) = try f.session(.googleDrive, signedIn: false)
        #expect(throws: RcloneSessionError.notSignedIn) { try s.open() }
        #expect(f.runDirs.isEmpty)
    }

    @Test func configFileIs0600InPrivateDir() throws {
        let f = try Fixture()
        let (s, _) = try f.session(.googleDrive)
        defer { try? s.close() }
        let (_, context) = try s.open()
        let file = URL(fileURLWithPath: context.configPath)
        #expect(try mode(file) == 0o600)
        #expect(try mode(file.deletingLastPathComponent()) == 0o700)
        #expect(file.deletingLastPathComponent().deletingLastPathComponent().path == f.work.path)
    }

    @Test func privateModesHoldUnderAPermissiveUmask() throws {
        let old = umask(0)
        defer { umask(old) }
        let f = try Fixture()
        let (s, _) = try f.session(.googleDrive)
        defer { try? s.close() }
        let (_, context) = try s.open()
        let file = URL(fileURLWithPath: context.configPath)
        #expect(try mode(file) == 0o600 && mode(file.deletingLastPathComponent()) == 0o700)
    }

    @Test func configContainsNoCryptSecrets() throws {
        let f = try Fixture()
        let (s, _) = try f.session(.googleDrive)
        defer { try? s.close() }
        let (endpoint, context) = try s.open()
        let config = try String(contentsOfFile: context.configPath, encoding: .utf8)
        #expect(!config.contains(f.vault.passphrase) && !config.contains(f.vault.salt))
        #expect(!config.lowercased().contains("password") && !config.contains("crypt"))
        for value in context.environment.values where value != "crypt" { #expect(!config.contains(value) || value == "true") }
        // Only the sign-in section: one section, for the base remote, with the forced scope.
        #expect(config.components(separatedBy: "\n").filter { $0.hasPrefix("[") }.count == 1)
        #expect(config.contains("type = drive\n") && config.contains("scope = drive.file\n"))
        #expect(config.contains("token = \(fakeToken)\n"))
        #expect(!config.contains("[\(cryptName(endpoint).lowercased())]"))
    }

    /// The display name can hold spaces and colons; remote names and env keys must not depend on it.
    @Test func remoteNameIsSafeForEnvironmentKeys() throws {
        let f = try Fixture()
        let (s, _) = try f.session(.googleDrive)
        defer { try? s.close() }
        let (endpoint, _) = try s.open()
        let name = endpoint.prefix { $0 != ":" }
        #expect(!name.isEmpty && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) })
    }

    @Test func storedScopeCannotWidenGoogleAccess() throws {
        let f = try Fixture()
        let (s, d) = try f.session(.googleDrive)
        try f.secrets.saveSignIn(["token": fakeToken, "scope": "drive", "type": "local"], for: d)
        defer { try? s.close() }
        let (_, context) = try s.open()
        let config = try String(contentsOfFile: context.configPath, encoding: .utf8)
        #expect(config.contains("scope = drive.file\n") && config.contains("type = drive\n"))
        #expect(!config.contains("scope = drive\n") && !config.contains("type = local"))
    }

    @Test func oneDriveKeepsDriveIdentityFromSignIn() throws {
        let f = try Fixture()
        let (s, d) = try f.session(.oneDrive)
        try f.secrets.saveSignIn(["token": fakeToken, "drive_id": "drive-1", "drive_type": "personal"], for: d)
        defer { try? s.close() }
        let (_, context) = try s.open()
        let config = try String(contentsOfFile: context.configPath, encoding: .utf8)
        #expect(config.contains("drive_id = drive-1\n") && config.contains("drive_type = personal\n"))
        #expect(!config.contains("scope"))
    }

    @Test func multilineValueCannotInjectIntoConfig() throws {
        let f = try Fixture()
        let (s, d) = try f.session(.googleDrive)
        try f.secrets.saveSignIn(["token": fakeToken, "client_id": "x\n[evil]\ntype = local"], for: d)
        #expect(throws: RcloneSessionError.invalidSignIn) { try s.open() }
        #expect(f.runDirs.isEmpty)
    }

    @Test func closeWritesRefreshedTokenAndDeletesFile() throws {
        let f = try Fixture()
        let (s, d) = try f.session(.googleDrive)
        let (endpoint, context) = try s.open()
        let base = String(try #require(context.environment["RCLONE_CONFIG_\(cryptName(endpoint))_REMOTE"]).prefix { $0 != ":" })
        // Real rclone rewrites the file, exactly as it does when a token refreshes during a run.
        let done = try realRclone(["config", "update", base, "token", newToken, "--config", context.configPath, "--non-interactive"])
        #expect(done.code == 0)
        #expect(try mode(URL(fileURLWithPath: context.configPath)) == 0o600)

        try s.close()
        let saved = try #require(try f.secrets.signIn(for: d))
        #expect(saved["token"] == newToken)
        #expect(saved["client_secret"] == "client-secret-not-real")
        #expect(saved["type"] == nil)
        #expect(!FileManager.default.fileExists(atPath: context.configPath))
        #expect(f.runDirs.isEmpty)
    }

    @Test func closeRunsAfterFailure() throws {
        let f = try Fixture()
        let (s, _) = try f.session(.googleDrive)
        let (_, context) = try s.open()
        var config = try String(contentsOfFile: context.configPath, encoding: .utf8)
        config = config.replacingOccurrences(of: fakeToken, with: newToken)
        try config.write(toFile: context.configPath, atomically: true, encoding: .utf8)
        f.secrets.failWrites = true

        var message = ""
        do { try s.close(); Issue.record("close should report the Keychain failure") }
        catch { message = "\(error) \(String(reflecting: error))" }
        #expect(!message.contains("access-two") && !message.contains("refresh-two"))
        #expect(f.runDirs.isEmpty)
        try s.close()   // a second close is harmless
    }

    @Test func closeNeverReplacesTokenWithGarbage() throws {
        for damaged in ["", "[other]\ntoken = \(newToken)\n", "[NAME]\ntoken = \n", "[NAME]\ntoken = not json\n",
                        "[NAME]\ntoken = {\"expiry\":\"2031\"}\n"] {
            let f = try Fixture()
            let (s, d) = try f.session(.googleDrive)
            let (_, context) = try s.open()
            let base = String(try #require(s.encryptedRoot).prefix { $0 != ":" })
            try damaged.replacingOccurrences(of: "NAME", with: base).write(toFile: context.configPath, atomically: true, encoding: .utf8)
            try s.close()
            #expect(try f.secrets.signIn(for: d)?["token"] == fakeToken)
            #expect(f.runDirs.isEmpty)
        }
    }

    /// A reconnect during the run stored a newer sign-in. The run's older refresh must not replace it.
    @Test func closeDoesNotOverwriteANewerReconnect() throws {
        let f = try Fixture()
        let (s, d) = try f.session(.googleDrive)
        let (_, context) = try s.open()
        let config = try String(contentsOfFile: context.configPath, encoding: .utf8)
        try config.replacingOccurrences(of: fakeToken, with: newToken).write(toFile: context.configPath, atomically: true, encoding: .utf8)
        let reconnected = ["client_id": "client-id-not-real", "token": #"{"access_token":"from-reconnect"}"#]
        try f.secrets.saveSignIn(reconnected, for: d)
        try s.close()
        #expect(try f.secrets.signIn(for: d) == reconnected)
        #expect(f.runDirs.isEmpty)
    }

    @Test func closeSurvivesConfigAlreadyWiped() throws {
        let f = try Fixture()
        let (s, d) = try f.session(.googleDrive)
        _ = try s.open()
        try RcloneSession.wipeLeftovers(in: f.work)
        try s.close()
        #expect(try f.secrets.signIn(for: d)?["token"] == fakeToken)
    }

    @Test func openTwiceIsRefused() throws {
        let f = try Fixture()
        let (s, _) = try f.session(.googleDrive)
        defer { try? s.close() }
        _ = try s.open()
        #expect(throws: RcloneSessionError.alreadyOpen) { try s.open() }
        #expect(f.runDirs.count == 1)
    }

    @Test func abandonedSessionStillDeletesItsFile() throws {
        let f = try Fixture()
        do {
            let (s, _) = try f.session(.googleDrive)
            _ = try s.open()
            #expect(f.runDirs.count == 1)
        }
        #expect(f.runDirs.isEmpty)
    }

    @Test func wipeLeftoversRemovesOldConfigs() throws {
        let f = try Fixture()
        let leftover = f.work.appendingPathComponent("mirror-run-crashed")
        try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)
        try "secret".write(to: leftover.appendingPathComponent("rclone.conf"), atomically: true, encoding: .utf8)
        let unrelated = f.work.appendingPathComponent("keep-me.txt")
        try "keep".write(to: unrelated, atomically: true, encoding: .utf8)

        try RcloneSession.wipeLeftovers(in: f.work)
        #expect(!FileManager.default.fileExists(atPath: leftover.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
        try RcloneSession.wipeLeftovers(in: f.work.appendingPathComponent("does-not-exist"))
    }

    @Test func wipeCanSpareRecentFolders() throws {
        let f = try Fixture()
        let old = f.work.appendingPathComponent("mirror-run-old"), recent = f.work.appendingPathComponent("mirror-run-recent")
        for u in [old, recent] { try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true) }
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -7200)], ofItemAtPath: old.path)
        try RcloneSession.wipeLeftovers(in: f.work, olderThan: 3600)
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: recent.path))
    }

    /// The agent wipes the run folder between backups, so anything interactive must live elsewhere.
    @Test func interactiveWorkIsOutOfTheAgentWipesReach() {
        let run = RcloneSession.defaultWorkDir.standardizedFileURL, app = RcloneSession.interactiveWorkDir.standardizedFileURL
        #expect(!PathGuard.isSameOrInside(app, run) && !PathGuard.isSameOrInside(run, app))
    }

    // MARK: - Obscure

    @Test func obscureUsesStdinNeverArgv() throws {
        let f = try Fixture()
        let record = f.tmp.url.appendingPathComponent("record")
        let fake = try fakeRclone(in: f.tmp.url, body: """
            printf '%s\\n' "$@" >> '\(record.path)'
            cat >> '\(record.path)'.stdin
            echo obscured-value
            """)
        let (s, _) = try f.session(.googleDrive, binary: fake)
        defer { try? s.close() }
        let (endpoint, context) = try s.open()
        let args = try String(contentsOf: record, encoding: .utf8)
        #expect(!args.contains(f.vault.passphrase) && !args.contains(f.vault.salt))
        #expect(args.contains("obscure\n-\n"))
        let stdin = try String(contentsOfFile: record.path + ".stdin", encoding: .utf8)
        #expect(stdin == f.vault.passphrase + "\n" + f.vault.salt + "\n")
        #expect(context.environment["RCLONE_CONFIG_\(cryptName(endpoint))_PASSWORD"] == "obscured-value")
    }

    @Test func obscureFailureDoesNotEchoTheValue() throws {
        let f = try Fixture()
        let fake = try fakeRclone(in: f.tmp.url, body: "cat; cat >&2; exit 3")
        let (s, _) = try f.session(.googleDrive, binary: fake)
        var message = ""
        do { _ = try s.open(); Issue.record("open should fail") }
        catch { message = "\(error) \(String(reflecting: error)) \(error.localizedDescription)" }
        #expect(message.contains("3"))
        #expect(!message.contains(f.vault.passphrase) && !message.contains(f.vault.salt))
        #expect(f.runDirs.isEmpty)
    }

    /// `rclone obscure -` with empty stdin obscures a literal hyphen, and a second line would be
    /// dropped: either way the backup would be keyed to something other than the stored secret.
    @Test func obscureRefusesValuesItWouldMangle() {
        for bad in ["", "two\nlines", "cr\rhere"] {
            #expect(throws: RcloneSessionError.invalidSecret) { try RcloneTool.obscure(bad, binary: vendoredRclone, helper: AnyHelper()) }
        }
    }

    @Test func obscureHandlesAnExitingChildWithoutSIGPIPE() throws {
        let f = try Fixture()
        let fake = try fakeRclone(in: f.tmp.url, body: "exit 9")
        #expect(throws: RcloneSessionError.obscureFailed(exitCode: 9)) {
            try RcloneTool.obscure(String(repeating: "a", count: 4096), binary: fake, helper: AnyHelper())
        }
    }

    // MARK: - The helper is checked before secrets go near it

    /// This is the scheduled path: `AgentService.respond` doesn't run here.
    @Test func openRefusesAnUntrustedHelperBeforeTheKeychain() throws {
        let f = try Fixture()
        let (s, _) = try f.session(.googleDrive, helper: RefusingHelper())
        let reads = f.secrets.reads
        #expect(throws: AgentFailure.untrustedHelper) { try s.open() }
        #expect(f.secrets.reads == reads && f.runDirs.isEmpty)
    }

    @Test func eachObscureIsValidatedFirst() throws {
        let f = try Fixture()
        let log = f.tmp.url.appendingPathComponent("log")
        try Data().write(to: log)
        let fake = try fakeRclone(in: f.tmp.url, body: "echo \"spawn $1\" >> '\(log.path)'; cat >/dev/null; echo obscured-stand-in")
        let (s, _) = try f.session(.googleDrive, binary: fake, helper: LoggingHelper(log: log))
        defer { try? s.close() }
        _ = try s.open()
        #expect(try everySpawnWasValidated(log))
        let spawns = try String(contentsOf: log, encoding: .utf8).components(separatedBy: "spawn obscure").count - 1
        #expect(spawns == 2)
    }

    @Test func helperValidationIsExposedForTheScheduledPath() throws {
        let f = try Fixture()
        let (good, _) = try f.session(.googleDrive)
        try good.verifyHelper()
        let (bad, _) = try f.session(.googleDrive, helper: RefusingHelper())
        #expect(throws: AgentFailure.untrustedHelper) { try bad.verifyHelper() }
    }

    /// An iCloud run hands rclone nothing secret, so there's nothing to protect and no check.
    @Test func iCloudOpenNeedsNoHelperCheck() throws {
        let f = try Fixture()
        let (s, _) = try f.session(.iCloudFolder, signedIn: false, vaulted: false, helper: RefusingHelper())
        _ = try s.open()
    }

    @Test func runnerRefusesSecretsWithoutAHelperCheck() async throws {
        let f = try Fixture()
        let filter = f.tmp.url.appendingPathComponent("f")
        try "+ **\n".write(to: filter, atomically: true, encoding: .utf8)
        func request(_ context: RcloneContext) -> SyncRequest {
            SyncRequest(source: f.tmp.url, destination: "x:", backupDir: "x:b", filterFile: filter,
                        logFile: f.tmp.url.appendingPathComponent("l"), mode: .copyOnly,
                        profile: .profile(for: Destination(name: "t", kind: .iCloudFolder)), context: context)
        }
        let spawned = f.tmp.url.appendingPathComponent("spawned")
        let unchecked = RcloneRunner.localOnly(binary: try fakeRclone(in: f.tmp.url, body: "touch '\(spawned.path)'"))
        for context in [RcloneContext(configPath: "/dev/null", environment: ["A": "b"]),
                        RcloneContext(configPath: "/tmp/x.conf", environment: [:]),
                        RcloneContext(configPath: "/tmp/x.conf", environment: ["A": "b"])] {
            await #expect(throws: RcloneRunnerError.helperNotChecked) { try await unchecked.sync(request(context)) }
        }
        #expect(!FileManager.default.fileExists(atPath: spawned.path))
        await #expect(throws: AgentFailure.untrustedHelper) {
            try await RcloneRunner(binary: vendoredRclone, helper: RefusingHelper())
                .sync(request(RcloneContext(configPath: "/dev/null", environment: ["A": "b"])))
        }
    }

    // MARK: - Home

    /// Foundation honours CFFIXED_USER_HOME, and the agent's environment comes from its caller.
    @Test func ownerHomeComesFromTheUserDatabase() throws {
        let entry = try #require(getpwuid(getuid()))
        #expect(MirrorPaths.ownerHome.path == String(cString: entry.pointee.pw_dir))
        #expect(MirrorPaths.support.path.hasPrefix(MirrorPaths.ownerHome.path + "/"))
        #expect(MirrorPaths.logs.path.hasPrefix(MirrorPaths.ownerHome.path + "/"))
    }

    // MARK: - Real crypt

    /// The session's own config and environment against real rclone, with one change: the sign-in
    /// section points at a folder, so the whole chain runs (crypt env -> file remote -> storage).
    private func roundTrip(_ kind: DestinationKind, assert onDisk: (String) -> Bool) async throws {
        let f = try Fixture()
        let (s, _) = try f.session(kind)
        defer { try? s.close() }
        let (endpoint, context) = try s.open()
        let storage = try f.tmp.sub("storage"), src = try f.tmp.sub("src"), back = try f.tmp.sub("back")
        let backend = kind == .oneDrive ? "onedrive" : "drive"
        let config = try String(contentsOfFile: context.configPath, encoding: .utf8)
            .replacingOccurrences(of: "type = \(backend)\n", with: "type = alias\nremote = \(storage.path)\n")
        try config.write(toFile: context.configPath, atomically: false, encoding: .utf8)
        let filter = f.tmp.url.appendingPathComponent("f.filter")
        try "+ **\n".write(to: filter, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: src.appendingPathComponent("Secret Folder"), withIntermediateDirectories: true)
        let content = "plain text that must not be readable"
        try content.write(to: src.appendingPathComponent("Secret Folder/private-name.txt"), atomically: true, encoding: .utf8)

        let name = cryptName(endpoint)
        let env = context.environment
        let request = SyncRequest(source: src, destination: endpoint + "Sets/t", backupDir: endpoint + "Archive/t/1",
                                  filterFile: filter, logFile: f.tmp.url.appendingPathComponent("up.log"), mode: .copyOnly,
                                  profile: .profile(for: Destination(name: "t", kind: .iCloudFolder)), context: context)
        let result = try await RcloneRunner(binary: vendoredRclone, helper: AnyHelper()).sync(request)
        #expect(result.outcome == .success)
        let log = try String(contentsOf: request.logFile, encoding: .utf8)
        #expect(!log.contains(f.vault.passphrase) && !log.contains(f.vault.salt))

        // The cloud shows one plain folder, the root the spec names, and everything in it is ciphertext.
        #expect(try FileManager.default.contentsOfDirectory(atPath: storage.path) == ["Mac Backup"])
        let cloud = storage.appendingPathComponent("Mac Backup")

        // On "the cloud": no plain names or content, and names in the expected encoding.
        var names: [String] = []
        let walker = try #require(FileManager.default.enumerator(at: cloud, includingPropertiesForKeys: nil))
        for case let u as URL in walker.allObjects {
            names.append(u.lastPathComponent)
            if (try? u.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                let bytes = try Data(contentsOf: u)
                #expect(bytes.starts(with: Data("RCLONE\0\0".utf8)))
                #expect(bytes.range(of: Data(content.utf8)) == nil)
            }
        }
        #expect(names.count == 4)   // Sets, t, Secret Folder, the file: no nested encrypted root
        for n in names {
            #expect(!n.contains("Secret") && !n.contains("private") && !n.contains("Sets"))
            #expect(onDisk(n))
        }

        // Decrypts with the right keys.
        let copied = try realRclone(["copy", endpoint + "Sets/t", back.path, "--config", context.configPath], env: env)
        #expect(copied.code == 0)
        #expect(try String(contentsOf: back.appendingPathComponent("Secret Folder/private-name.txt"), encoding: .utf8) == content)

        // A wrong passphrase sees nothing it can decrypt.
        var wrong = env
        wrong["RCLONE_CONFIG_\(name)_PASSWORD"] = try RcloneTool.obscure("wrong-passphrase", binary: vendoredRclone, helper: AnyHelper())
        let failed = try realRclone(["copy", endpoint + "Sets/t", try f.tmp.sub("nope").path, "--config", context.configPath], env: wrong)
        #expect(failed.code != 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.tmp.url.appendingPathComponent("nope").path).isEmpty)
    }

    @Test func cryptRoundTripBase32() async throws {
        try await roundTrip(.googleDrive) { n in n.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber) } }
    }

    @Test func cryptRoundTripBase32768() async throws {
        try await roundTrip(.oneDrive) { n in n.unicodeScalars.contains { !$0.isASCII } }
    }
}

@Suite struct RemoteSetupTests {
    private struct Rig {
        let tmp: TempDir
        let secrets = MemorySecrets()
        let record: URL
        let binary: URL
        init(exit code: Int = 0, writeToken: Bool = true, extra: String = "", prelude: String = "") throws {
            tmp = try TempDir()
            record = try tmp.sub("record")
            let r = record.path
            binary = try fakeRclone(in: tmp.url, body: """
                \(prelude)
                printf '%s\\n' "$@" > '\(r)/args'
                /usr/bin/env > '\(r)/env'
                prev=''
                for a in "$@"; do [ "$prev" = "--config" ] && cfg="$a"; prev="$a"; done
                cp "$cfg" '\(r)/config'
                echo "$cfg" > '\(r)/path'
                /usr/bin/stat -f '%Lp' "$cfg" > '\(r)/mode'
                /usr/bin/stat -f '%Lp' "$(dirname "$cfg")" > '\(r)/dirmode'
                \(writeToken ? "cat >> \"$cfg\" <<'EOF'\ntoken = \(newToken)\ndrive_id = drive-9\nEOF" : "")
                \(extra)
                exit \(code)
                """)
        }
        func read(_ name: String) throws -> String { try String(contentsOf: record.appendingPathComponent(name), encoding: .utf8) }
        /// Its own folder: the real interactive one is shared with the app and with other worktrees' runs.
        var setup: RemoteSetup { RemoteSetup(binary: binary, secrets: secrets, helper: AnyHelper(), workDir: tmp.url) }
    }

    @Test func connectBuildsCommandWithoutSecretsInArgv() async throws {
        let rig = try Rig()
        let d = Destination(name: "Drive", kind: .googleDrive)
        try await rig.setup.connect(d, clientID: " my-client-id\n", clientSecret: "my-client-secret")

        let args = try rig.read("args").split(separator: "\n").map(String.init)
        #expect(Array(args.prefix(2)) == ["config", "reconnect"])
        #expect(args[2].hasSuffix(":") && args.contains("--auto-confirm") && args.contains("--config"))
        let all = try rig.read("args") + rig.read("env")
        #expect(!all.contains("my-client-secret") && !all.contains("my-client-id"))

        let config = try rig.read("config")
        #expect(config.contains("type = drive\n") && config.contains("scope = drive.file\n"))
        #expect(config.contains("client_id = my-client-id\n") && config.contains("client_secret = my-client-secret\n"))
        #expect(try rig.read("mode").trimmingCharacters(in: .newlines) == "600")
        #expect(try rig.read("dirmode").trimmingCharacters(in: .newlines) == "700")

        let saved = try #require(try rig.secrets.signIn(for: d))
        #expect(saved["token"] == newToken && saved["client_secret"] == "my-client-secret")
        #expect(saved["drive_id"] == "drive-9")
        let path = try rig.read("path").trimmingCharacters(in: .newlines)
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(!FileManager.default.fileExists(atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path))
    }

    @Test func connectEnvironmentIsMinimal() async throws {
        let rig = try Rig()
        try await rig.setup.connect(Destination(name: "O", kind: .oneDrive), clientID: nil, clientSecret: nil)
        let names = try rig.read("env").split(separator: "\n").compactMap { $0.split(separator: "=").first.map(String.init) }
        #expect(Set(names).isSubset(of: ["PATH", "HOME", "PWD", "OLDPWD", "SHLVL", "_"]))
        #expect(try !rig.read("config").contains("scope"))
    }

    @Test func connectCreatesVaultOnceOnly() async throws {
        let rig = try Rig()
        let d = Destination(name: "Drive", kind: .googleDrive)
        try await rig.setup.connect(d, clientID: "id", clientSecret: "s")
        let vault = try #require(try rig.secrets.vault(for: d))
        try await rig.setup.connect(d, clientID: "id", clientSecret: "s")
        #expect(try rig.secrets.vault(for: d) == vault)   // new keys would strand every existing backup
    }

    @Test func connectLeavesUnencryptedDestinationWithoutVault() async throws {
        let rig = try Rig()
        let d = Destination(name: "O", kind: .oneDrive, encrypted: false)
        try await rig.setup.connect(d, clientID: nil, clientSecret: nil)
        #expect(try rig.secrets.vault(for: d) == nil)
    }

    @Test func failedSignInStoresNothingAndCleansUp() async throws {
        let rig = try Rig(exit: 1, extra: "echo my-client-secret >&2")
        let d = Destination(name: "Drive", kind: .googleDrive)
        var message = ""
        do { try await rig.setup.connect(d, clientID: "id", clientSecret: "my-client-secret"); Issue.record("should fail") }
        catch { message = "\(error) \(String(reflecting: error))" }
        #expect(message.contains("signInFailed") && !message.contains("my-client-secret"))
        #expect(rig.secrets.isEmpty)
        let path = try rig.read("path").trimmingCharacters(in: .newlines)
        #expect(!FileManager.default.fileExists(atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path))
    }

    @Test func signInThatReturnsNoTokenFails() async throws {
        let rig = try Rig(writeToken: false)
        let d = Destination(name: "Drive", kind: .googleDrive)
        await #expect(throws: RemoteSetupError.noToken) { try await rig.setup.connect(d, clientID: "id", clientSecret: "s") }
        #expect(rig.secrets.isEmpty)
    }

    @Test func googleRequiresOwnClientID() async throws {
        let rig = try Rig()
        let d = Destination(name: "Drive", kind: .googleDrive)
        await #expect(throws: RemoteSetupError.clientIDRequired) { try await rig.setup.connect(d, clientID: "  ", clientSecret: nil) }
        await #expect(throws: RemoteSetupError.clientIDRequired) { try await rig.setup.connect(d, clientID: nil, clientSecret: "s") }
    }

    /// Without the secret the kit couldn't sign in on another Mac, so it's required up front.
    @Test func googleRequiresClientSecret() async throws {
        let rig = try Rig()
        let d = Destination(name: "Drive", kind: .googleDrive)
        await #expect(throws: RemoteSetupError.clientSecretRequired) { try await rig.setup.connect(d, clientID: "id", clientSecret: " ") }
        await #expect(throws: RemoteSetupError.clientSecretRequired) { try await rig.setup.connect(d, clientID: "id", clientSecret: nil) }
    }

    /// The saved Kit holds the old keys. New ones would mean backups no saved Kit can open.
    @Test func confirmedKitWithLostVaultRefusesNewKeys() async throws {
        let rig = try Rig()
        var d = Destination(name: "Drive", kind: .googleDrive)
        d.recoveryKitConfirmed = true
        try rig.secrets.saveSignIn(["client_id": "id", "client_secret": "s", "token": fakeToken], for: d)
        await #expect(throws: RemoteSetupError.vaultLostNeedsRecoveryKit) { try await rig.setup.connect(d, clientID: "id", clientSecret: "s") }
        #expect(try rig.secrets.vault(for: d) == nil)
        #expect(!FileManager.default.fileExists(atPath: rig.record.appendingPathComponent("args").path))   // no browser opened
    }

    @Test func confirmedKitWithEverythingLostAlsoNeedsTheKit() async throws {
        let rig = try Rig()
        var d = Destination(name: "Drive", kind: .googleDrive)
        d.recoveryKitConfirmed = true
        await #expect(throws: RemoteSetupError.vaultLostNeedsRecoveryKit) { try await rig.setup.connect(d, clientID: "id", clientSecret: "s") }
        #expect(rig.secrets.isEmpty)
    }

    /// The vault survived but the client is unknown, and the Kit is the only record of the right one.
    @Test func confirmedKitWithLostSignInNeedsTheKit() async throws {
        let rig = try Rig()
        var d = Destination(name: "Drive", kind: .googleDrive)
        d.recoveryKitConfirmed = true
        try rig.secrets.saveVault(.generate(), for: d)
        await #expect(throws: RemoteSetupError.signInLostNeedsRecoveryKit) { try await rig.setup.connect(d, clientID: "id", clientSecret: "s") }
    }

    /// connect stores keys before the sign-in, so this state only comes from a loss. The flag may lie.
    @Test func signInWithoutVaultIsALossEvenUnconfirmed() async throws {
        let rig = try Rig()
        let d = Destination(name: "Drive", kind: .googleDrive)
        try rig.secrets.saveSignIn(["client_id": "id", "client_secret": "s", "token": fakeToken], for: d)
        await #expect(throws: RemoteSetupError.vaultLostNeedsRecoveryKit) { try await rig.setup.connect(d, clientID: "id", clientSecret: "s") }
        await #expect(throws: RemoteSetupError.vaultLostNeedsRecoveryKit) { try await rig.setup.reconnect(d) }
        #expect(try rig.secrets.vault(for: d) == nil)
    }

    @Test func damagedVaultRoutesToRecoveryKit() async throws {
        let rig = try Rig()
        let d = Destination(name: "Drive", kind: .googleDrive)
        try rig.secrets.write("not json", key: SecretKeys.vault(d.id))
        await #expect(throws: RemoteSetupError.vaultLostNeedsRecoveryKit) { try await rig.setup.connect(d, clientID: "id", clientSecret: "s") }
        try rig.secrets.saveSignIn(["client_id": "id", "client_secret": "s", "token": fakeToken], for: d)
        await #expect(throws: RemoteSetupError.vaultLostNeedsRecoveryKit) { try await rig.setup.reconnect(d) }
    }

    @Test func damagedSignInOnEncryptedDestinationNeedsTheKit() async throws {
        let rig = try Rig()
        let d = Destination(name: "Drive", kind: .googleDrive)
        try rig.secrets.saveVault(.generate(), for: d)
        try rig.secrets.write("not json", key: SecretKeys.signIn(d.id))
        await #expect(throws: RemoteSetupError.signInLostNeedsRecoveryKit) { try await rig.setup.connect(d, clientID: "id", clientSecret: "s") }
    }

    /// Keys written while the browser was open must survive: the earlier read is stale by then.
    @Test func connectRereadsVaultAfterTheBrowser() async throws {
        let rig = try Rig()
        let d = Destination(name: "Drive", kind: .googleDrive)
        let other = VaultSecrets.generate()
        let json = String(decoding: try JSONEncoder().encode(other), as: UTF8.self)
        rig.secrets.appearsAfterFirstRead = (SecretKeys.vault(d.id), json)
        try await rig.setup.connect(d, clientID: "id", clientSecret: "s")
        #expect(try rig.secrets.vault(for: d) == other)
    }

    @Test func clientChangeOnExistingDestinationIsRefused() async throws {
        let rig = try Rig()
        let d = Destination(name: "Drive", kind: .googleDrive)
        try await rig.setup.connect(d, clientID: "id", clientSecret: "s")
        let before = try rig.secrets.signIn(for: d)
        await #expect(throws: RemoteSetupError.clientChangeRefused) { try await rig.setup.connect(d, clientID: "other", clientSecret: "s") }
        await #expect(throws: RemoteSetupError.clientChangeRefused) { try await rig.setup.connect(d, clientID: "id", clientSecret: "other") }
        #expect(try rig.secrets.signIn(for: d) == before)

        let o = Destination(name: "One", kind: .oneDrive)
        try await rig.setup.connect(o, clientID: "own-client", clientSecret: nil)
        await #expect(throws: RemoteSetupError.clientChangeRefused) { try await rig.setup.connect(o, clientID: nil, clientSecret: nil) }
    }

    // MARK: - Restoring keys from a Kit

    private static let obscure = #"if [ "$1" = obscure ]; then cat >/dev/null; echo obscured-stand-in; exit 0; fi"#
    private static let listing = obscure + """

        if [ "$1" = lsf ]; then
          case "$2" in mirrorrestore*) echo decrypted-name ;; *) echo raw-name ;; esac
          exit 0
        fi
        """

    private func confirmed() -> Destination {
        var d = Destination(name: "Drive", kind: .googleDrive)
        d.recoveryKitConfirmed = true
        return d
    }

    private func kit(_ v: VaultSecrets) -> RecoveryKit {
        RecoveryKit(kind: .googleDrive, rootPath: "Mac Backup", passphrase: v.passphrase, salt: v.salt, filenameEncoding: "base32",
                    rcloneVersion: "v1.75.2", clientID: "kit-id", clientSecret: "kit-secret")
    }

    @Test func kitRestoresLostVaultAndSignIn() async throws {
        let rig = try Rig(prelude: Self.listing)
        let d = confirmed(), v = VaultSecrets.generate()
        try await rig.setup.restore(d, from: kit(v))
        #expect(try rig.secrets.vault(for: d) == v)
        let saved = try #require(try rig.secrets.signIn(for: d))
        #expect(saved["client_id"] == "kit-id" && saved["client_secret"] == "kit-secret" && saved["token"] == newToken)
    }

    /// Lost-sign-in recovery must work when the stored item is damaged, not only when it's gone.
    @Test func kitRestoreReplacesADamagedSignIn() async throws {
        let rig = try Rig(prelude: Self.listing)
        let d = confirmed(), v = VaultSecrets.generate()
        try rig.secrets.write("not json", key: SecretKeys.signIn(d.id))
        try await rig.setup.restore(d, from: kit(v))
        #expect(try rig.secrets.signIn(for: d)?["token"] == newToken)
    }

    @Test func kitRestoreReplacesASignInThatCannotBeWritten() async throws {
        let rig = try Rig(prelude: Self.listing)
        let d = confirmed(), v = VaultSecrets.generate()
        try rig.secrets.saveSignIn(["client_id": "kit-id", "client_secret": "kit-secret", "token": "x\ny"], for: d)
        try await rig.setup.restore(d, from: kit(v))
        #expect(try rig.secrets.signIn(for: d)?["token"] == newToken)
    }

    @Test func kitRestoreReplacesADamagedVault() async throws {
        let rig = try Rig(prelude: Self.listing)
        let d = confirmed(), v = VaultSecrets.generate()
        try rig.secrets.write("not json", key: SecretKeys.vault(d.id))
        try await rig.setup.restore(d, from: kit(v))
        #expect(try rig.secrets.vault(for: d) == v)
    }

    @Test func kitRestoreRereadsVaultBeforeSaving() async throws {
        let rig = try Rig(prelude: Self.listing)
        let d = confirmed(), other = VaultSecrets.generate()
        let json = String(decoding: try JSONEncoder().encode(other), as: UTF8.self)
        rig.secrets.appearsAfterFirstRead = (SecretKeys.vault(d.id), json)
        await #expect(throws: RemoteSetupError.vaultAlreadyPresent) { try await rig.setup.restore(d, from: kit(.generate())) }
        #expect(try rig.secrets.vault(for: d) == other)
    }

    private static let emptyCloud = obscure + """

        if [ "$1" = lsf ]; then exit 0; fi
        """
    private static let missingCloud = obscure + """

        if [ "$1" = lsf ]; then exit 3; fi
        """

    /// Under drive.file a wrong client or account sees nothing, so nothing there proves nothing.
    @Test(arguments: [emptyCloud, missingCloud])
    func freshSignInSeeingNothingIsUnproven(prelude: String) async throws {
        let rig = try Rig(prelude: prelude)
        var d = Destination(name: "Drive", kind: .googleDrive)
        d.recoveryKitConfirmed = false
        await #expect(throws: RemoteSetupError.kitUnproven) { try await rig.setup.restore(d, from: kit(.generate())) }
        #expect(try rig.secrets.vault(for: d) == nil && rig.secrets.signIn(for: d) == nil)
    }

    @Test(arguments: [emptyCloud, missingCloud])
    func confirmedDestinationSeeingNothingIsUnproven(prelude: String) async throws {
        let rig = try Rig(prelude: prelude)
        let d = confirmed()
        try rig.secrets.saveSignIn(["client_id": "kit-id", "client_secret": "kit-secret", "token": fakeToken], for: d)
        await #expect(throws: RemoteSetupError.kitUnproven) { try await rig.setup.restore(d, from: kit(.generate())) }
        #expect(try rig.secrets.vault(for: d) == nil)
    }

    /// A surviving sign-in proves nothing about the Kit, and the flag is only a line in `destinations.json`.
    @Test(arguments: [emptyCloud, missingCloud])
    func survivingSignInSeeingNothingIsUnprovenWhateverTheFlag(prelude: String) async throws {
        let rig = try Rig(prelude: prelude)
        let d = Destination(name: "Drive", kind: .googleDrive)
        #expect(!d.recoveryKitConfirmed)
        try rig.secrets.saveSignIn(["client_id": "kit-id", "client_secret": "kit-secret", "token": fakeToken], for: d)
        await #expect(throws: RemoteSetupError.kitUnproven) { try await rig.setup.restore(d, from: kit(.generate())) }
        #expect(try rig.secrets.vault(for: d) == nil)
    }

    @Test func acceptingKeepsTheSurvivingSignIn() async throws {
        let rig = try Rig(prelude: Self.emptyCloud)
        let d = Destination(name: "Drive", kind: .googleDrive), v = VaultSecrets.generate()
        try rig.secrets.saveSignIn(["client_id": "kit-id", "client_secret": "kit-secret", "token": fakeToken], for: d)
        try await rig.setup.restore(d, from: kit(v), acceptUnproven: true)
        #expect(try rig.secrets.vault(for: d) == v)
        #expect(try rig.secrets.signIn(for: d)?["token"] == fakeToken)
    }

    @Test func ownerCanAcceptAnUnprovenKit() async throws {
        let rig = try Rig(prelude: Self.emptyCloud)
        let d = confirmed(), v = VaultSecrets.generate()
        try await rig.setup.restore(d, from: kit(v), acceptUnproven: true)
        #expect(try rig.secrets.vault(for: d) == v)
        #expect(try rig.secrets.signIn(for: d)?["token"] == newToken)
    }

    /// Acceptance covers "nothing to see", never "the keys can't read what's there".
    @Test func acceptingCannotOverrideAKitThatFails() async throws {
        let rig = try Rig(prelude: Self.obscure + """

            if [ "$1" = lsf ]; then
              case "$2" in mirrorrestore*) ;; *) echo raw-name ;; esac
              exit 0
            fi
            """)
        await #expect(throws: RemoteSetupError.kitDoesNotOpenBackup) {
            try await rig.setup.restore(confirmed(), from: kit(.generate()), acceptUnproven: true)
        }
    }

    /// OneDrive rotates refresh tokens, so a refresh during the proof is kept whatever the verdict.
    @Test(arguments: [true, false])
    func tokenRefreshedDuringTheProofIsKept(opens: Bool) async throws {
        let rig = try Rig(prelude: Self.obscure + """

            if [ "$1" = lsf ]; then
              printf 'token = %s\\n' '\(newToken)' >> "$6"
              case "$2" in mirrorrestore*) \(opens ? "echo decrypted-name" : "") ;; *) echo raw-name ;; esac
              exit 0
            fi
            """)
        let d = confirmed()
        try rig.secrets.saveSignIn(["client_id": "kit-id", "client_secret": "kit-secret", "token": fakeToken], for: d)
        do { try await rig.setup.restore(d, from: kit(.generate())) } catch { #expect(!opens) }
        #expect(try rig.secrets.signIn(for: d)?["token"] == newToken)
    }

    private func browserRan(_ rig: Rig) -> Bool {
        FileManager.default.fileExists(atPath: rig.record.appendingPathComponent("args").path)
    }

    /// Yes to "use it anyway" shouldn't mean a second trip through the browser.
    @Test func acceptingReusesTheSignInFromTheFailedAttempt() async throws {
        let rig = try Rig(prelude: Self.emptyCloud)
        let d = confirmed(), k = kit(.generate())
        await #expect(throws: RemoteSetupError.kitUnproven) { try await rig.setup.restore(d, from: k) }
        #expect(browserRan(rig))
        try FileManager.default.removeItem(at: rig.record.appendingPathComponent("args"))

        try await rig.setup.restore(d, from: k, acceptUnproven: true)
        #expect(!browserRan(rig))
        #expect(try rig.secrets.signIn(for: d)?["token"] == newToken)
        #expect(try rig.secrets.read(SecretKeys.heldSignIn(d.id)) == nil)   // no spare copy left behind
    }

    /// Held apart from the real sign-in, or a retry would pass as "surviving" and skip the owner's answer.
    @Test func heldSignInDoesNotCountAsSurviving() async throws {
        let rig = try Rig(prelude: Self.emptyCloud)
        let d = Destination(name: "Drive", kind: .googleDrive), k = kit(.generate())
        await #expect(throws: RemoteSetupError.kitUnproven) { try await rig.setup.restore(d, from: k) }
        #expect(try rig.secrets.signIn(for: d) == nil)
        await #expect(throws: RemoteSetupError.kitUnproven) { try await rig.setup.restore(d, from: k) }
        #expect(try rig.secrets.vault(for: d) == nil)
    }

    /// "No, wrong account" is a retry without accepting, and it must reach the browser again.
    @Test func retryingWithoutAcceptingSignsInAgain() async throws {
        let rig = try Rig(prelude: Self.emptyCloud)
        let d = confirmed(), k = kit(.generate())
        await #expect(throws: RemoteSetupError.kitUnproven) { try await rig.setup.restore(d, from: k) }
        try FileManager.default.removeItem(at: rig.record.appendingPathComponent("args"))
        await #expect(throws: RemoteSetupError.kitUnproven) { try await rig.setup.restore(d, from: k) }
        #expect(browserRan(rig))
    }

    @Test func heldSignInMustBeTheKitsClient() async throws {
        let rig = try Rig(prelude: Self.emptyCloud)
        let d = confirmed()
        await #expect(throws: RemoteSetupError.kitUnproven) { try await rig.setup.restore(d, from: kit(.generate())) }
        try FileManager.default.removeItem(at: rig.record.appendingPathComponent("args"))
        var other = kit(.generate())
        other.clientID = "another-id"
        try await rig.setup.restore(d, from: other, acceptUnproven: true)
        #expect(browserRan(rig))
        #expect(try rig.secrets.signIn(for: d)?["client_id"] == "another-id")
    }

    @Test func aKitThatFailsLeavesNoHeldSignIn() async throws {
        let rig = try Rig(prelude: Self.obscure + """

            if [ "$1" = lsf ]; then
              case "$2" in mirrorrestore*) ;; *) echo raw-name ;; esac
              exit 0
            fi
            """)
        let d = confirmed()
        await #expect(throws: RemoteSetupError.kitDoesNotOpenBackup) { try await rig.setup.restore(d, from: kit(.generate())) }
        #expect(try rig.secrets.read(SecretKeys.heldSignIn(d.id)) == nil)
    }

    @Test func everyRestoreSpawnIsValidatedFirst() async throws {
        let tmp = try TempDir()
        let log = tmp.url.appendingPathComponent("log")
        try Data().write(to: log)
        let fake = try fakeRclone(in: tmp.url, body: """
            echo "spawn $1" >> '\(log.path)'
            prev=''
            for a in "$@"; do [ "$prev" = "--config" ] && cfg="$a"; prev="$a"; done
            case "$1" in
              obscure) cat >/dev/null; echo obscured-stand-in ;;
              lsf) echo a-name ;;
              config) echo 'token = {"access_token":"a"}' >> "$cfg" ;;
            esac
            exit 0
            """)
        let setup = RemoteSetup(binary: fake, secrets: MemorySecrets(), helper: LoggingHelper(log: log), workDir: tmp.url)
        try await setup.restore(confirmed(), from: kit(.generate()))
        #expect(try everySpawnWasValidated(log))
        let text = try String(contentsOf: log, encoding: .utf8)
        for step in ["spawn config", "spawn lsf", "spawn obscure"] { #expect(text.contains(step)) }
    }

    @Test func untrustedHelperNeverReceivesTheClientSecret() async throws {
        let rig = try Rig()
        let setup = RemoteSetup(binary: rig.binary, secrets: rig.secrets, helper: RefusingHelper(), workDir: rig.tmp.url)
        await #expect(throws: AgentFailure.untrustedHelper) {
            try await setup.connect(Destination(name: "D", kind: .googleDrive), clientID: "id", clientSecret: "s")
        }
        #expect(!browserRan(rig))
    }

    @Test func kitRestoreUsesExistingSignInWithoutABrowser() async throws {
        let rig = try Rig(prelude: Self.listing)
        let d = confirmed(), v = VaultSecrets.generate()
        try rig.secrets.saveSignIn(["client_id": "kit-id", "client_secret": "kit-secret", "token": fakeToken], for: d)
        try await rig.setup.restore(d, from: kit(v))
        #expect(try rig.secrets.vault(for: d) == v)
        #expect(try rig.secrets.signIn(for: d)?["token"] == fakeToken)
        #expect(!FileManager.default.fileExists(atPath: rig.record.appendingPathComponent("args").path))
    }

    /// Pasting the wrong Kit must not resume backups under keys that can't read what's there.
    @Test func kitThatCannotOpenTheBackupIsNotStored() async throws {
        let rig = try Rig(prelude: Self.obscure + """

            if [ "$1" = lsf ]; then
              case "$2" in mirrorrestore*) ;; *) echo raw-name ;; esac
              exit 0
            fi
            """)
        let d = confirmed()
        try rig.secrets.saveSignIn(["client_id": "kit-id", "client_secret": "kit-secret", "token": fakeToken], for: d)
        await #expect(throws: RemoteSetupError.kitDoesNotOpenBackup) { try await rig.setup.restore(d, from: kit(.generate())) }
        #expect(try rig.secrets.vault(for: d) == nil)
    }

    @Test func unreachableCloudLeavesKitUnproven() async throws {
        let rig = try Rig(prelude: #"if [ "$1" = lsf ]; then exit 1; fi"#)
        let d = confirmed()
        try rig.secrets.saveSignIn(["client_id": "kit-id", "client_secret": "kit-secret", "token": fakeToken], for: d)
        await #expect(throws: RemoteSetupError.couldNotVerifyKit) { try await rig.setup.restore(d, from: kit(.generate())) }
        #expect(try rig.secrets.vault(for: d) == nil)
    }

    @Test func kitRestoreNeverReplacesDifferentKeys() async throws {
        let rig = try Rig(prelude: Self.listing)
        let d = confirmed(), present = VaultSecrets.generate()
        try rig.secrets.saveVault(present, for: d)
        await #expect(throws: RemoteSetupError.vaultAlreadyPresent) { try await rig.setup.restore(d, from: kit(.generate())) }
        #expect(try rig.secrets.vault(for: d) == present)
    }

    @Test func kitForAnotherDestinationIsRefused() async throws {
        let rig = try Rig(prelude: Self.listing)
        var k = kit(.generate())
        k.kind = .oneDrive; k.filenameEncoding = "base32768"
        await #expect(throws: RemoteSetupError.kitDoesNotMatchDestination) { try await rig.setup.restore(confirmed(), from: k) }
        var other = kit(.generate())
        other.filenameEncoding = "base32768"
        await #expect(throws: RemoteSetupError.kitDoesNotMatchDestination) { try await rig.setup.restore(confirmed(), from: other) }
    }

    @Test func kitRestoreRefusesADifferentStoredClient() async throws {
        let rig = try Rig(prelude: Self.listing)
        let d = confirmed()
        try rig.secrets.saveSignIn(["client_id": "stored", "client_secret": "s", "token": fakeToken], for: d)
        await #expect(throws: RemoteSetupError.clientChangeRefused) { try await rig.setup.restore(d, from: kit(.generate())) }
    }

    /// The real proof against real rclone: the right keys list the backup, wrong keys see nothing.
    @Test func kitProofAgainstRealRclone() async throws {
        let tmp = try TempDir()
        let cloud = try tmp.sub("cloud/Mac Backup"), src = try tmp.sub("src")
        try "x".write(to: src.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        let conf = tmp.url.appendingPathComponent("c.conf")
        try "[base]\ntype = alias\nremote = \(tmp.url.appendingPathComponent("cloud").path)\n".write(to: conf, atomically: true, encoding: .utf8)
        let context = RcloneContext(configPath: conf.path, environment: [:])
        let setup = RemoteSetup(binary: vendoredRclone, secrets: MemorySecrets(), helper: AnyHelper(), workDir: tmp.url)
        let v = VaultSecrets.generate()

        #expect(try await setup.kitOpens(kit(.generate()), encryptedRoot: "base:Mac Backup", context: context) == .nothingThere)
        let env = try RcloneCrypt.environment(remote: "up", over: cloud.path, passphrase: v.passphrase, salt: v.salt,
                                              filenameEncoding: "base32", binary: vendoredRclone, helper: AnyHelper())
        #expect(try realRclone(["copy", src.path, "up:Sets/s", "--config", "/dev/null"], env: env).code == 0)
        #expect(try await setup.kitOpens(kit(v), encryptedRoot: "base:Mac Backup", context: context) == .opens)
        #expect(try await setup.kitOpens(kit(.generate()), encryptedRoot: "base:Mac Backup", context: context) == .doesNotOpen)
    }

    @Test func clientValuesCannotInjectIntoConfig() async throws {
        let rig = try Rig()
        let d = Destination(name: "Drive", kind: .googleDrive)
        await #expect(throws: RcloneSessionError.invalidSignIn) {
            try await rig.setup.connect(d, clientID: "a\n[evil]", clientSecret: "s")
        }
    }

    @Test func iCloudHasNoSignIn() async throws {
        let rig = try Rig()
        let d = Destination(name: "I", kind: .iCloudFolder)
        await #expect(throws: RemoteSetupError.noSignInNeeded) { try await rig.setup.connect(d, clientID: nil, clientSecret: nil) }
        await #expect(throws: RemoteSetupError.noSignInNeeded) { try await rig.setup.reconnect(d) }
    }

    @Test func reconnectReusesClientAndKeepsVault() async throws {
        let rig = try Rig()
        let d = Destination(name: "Drive", kind: .googleDrive)
        let vault = VaultSecrets.generate()
        try rig.secrets.saveVault(vault, for: d)
        try rig.secrets.saveSignIn(["client_id": "stored-id", "client_secret": "stored-secret", "token": fakeToken], for: d)
        try await rig.setup.reconnect(d)
        let config = try rig.read("config")
        #expect(config.contains("client_id = stored-id\n") && config.contains("client_secret = stored-secret\n"))
        #expect(!config.contains("access-one"))   // the old token is not offered to rclone
        #expect(try rig.secrets.signIn(for: d)?["token"] == newToken)
        #expect(try rig.secrets.vault(for: d) == vault)
    }

    @Test func failedReconnectKeepsOldSignIn() async throws {
        let rig = try Rig(exit: 1)
        let d = Destination(name: "Drive", kind: .googleDrive)
        try rig.secrets.saveVault(.generate(), for: d)
        try rig.secrets.saveSignIn(["client_id": "id", "token": fakeToken], for: d)
        await #expect(throws: RemoteSetupError.signInFailed(exitCode: 1)) { try await rig.setup.reconnect(d) }
        #expect(try rig.secrets.signIn(for: d)?["token"] == fakeToken)
    }

    @Test func reconnectWithoutEarlierSignInFails() async throws {
        let rig = try Rig()
        let d = Destination(name: "Drive", kind: .googleDrive)
        await #expect(throws: RcloneSessionError.notSignedIn) { try await rig.setup.reconnect(d) }
    }

    @Test func cancellingSignInStopsRcloneAndDeletesConfig() async throws {
        let rig = try Rig(writeToken: false, extra: "exec /bin/sleep 60")
        let d = Destination(name: "Drive", kind: .googleDrive)
        let setup = rig.setup
        let task = Task { try await setup.connect(d, clientID: "id", clientSecret: "s") }
        let pathFile = rig.record.appendingPathComponent("dirmode")
        while !FileManager.default.fileExists(atPath: pathFile.path) { try await Task.sleep(for: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        let path = try rig.read("path").trimmingCharacters(in: .newlines)
        #expect(!FileManager.default.fileExists(atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path))
        #expect(rig.secrets.isEmpty)
    }
}
