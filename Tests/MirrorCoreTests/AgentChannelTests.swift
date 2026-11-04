import Testing
import Foundation
@testable import MirrorCore

private func data(_ r: AgentRequest) throws -> Data { try JSONEncoder().encode(r) }
private func decode(_ d: Data) throws -> AgentResponse { try JSONDecoder().decode(AgentResponse.self, from: d) }

/// A fake rclone that signs in, lists, and "downloads" a fixed file.
private func fakeCloudRclone(in dir: URL) throws -> URL {
    try fakeRclone(in: dir, body: #"""
        case "$1" in
          obscure) cat >/dev/null; echo obscured-stand-in; exit 0 ;;
          version) echo "rclone v1.75.2"; exit 0 ;;
          lsf) echo listed-name; exit 0 ;;
          cryptcheck) exit 0 ;;
          copyto) printf 'the words' > "$3"; exit 0 ;;
          config)
            prev=''
            for a in "$@"; do [ "$prev" = "--config" ] && cfg="$a"; prev="$a"; done
            echo 'token = {"access_token":"a","refresh_token":"r"}' >> "$cfg"
            exit 0 ;;
        esac
        exit 1
        """#)
}

private final class FakeTrust: AgentTrust, @unchecked Sendable {
    var callerFailure: AgentFailure?
    var helperFailure: AgentFailure?
    private(set) var helperChecks = 0
    func verifyCaller() throws { if let callerFailure { throw callerFailure } }
    func verifyHelper(at: URL) throws {
        helperChecks += 1
        if let helperFailure { throw helperFailure }
    }
}

private final class FakePresence: UserPresence, @unchecked Sendable {
    var refuses = false
    private(set) var asked = 0
    func confirm(reason: String) async throws {
        asked += 1
        if refuses { throw AgentFailure.presenceRefused }
    }
}

private final class ReadFlag: @unchecked Sendable { var read = false }

private struct ServiceRig {
    let tmp: TempDir
    let secrets = MemorySecrets()
    let service: AgentService
    let work: URL
    let support: URL
    let trust = FakeTrust()
    let presence = FakePresence()
    let drive = Destination(name: "Drive", kind: .googleDrive)
    init() throws {
        tmp = try TempDir()
        work = try tmp.sub("work")
        support = try tmp.sub("support")
        service = AgentService(secrets: secrets, binary: try fakeCloudRclone(in: tmp.url), trust: trust, presence: presence,
                               support: support, workDir: work)
    }
    var config: ConfigStore { ConfigStore(root: support) }
    var lockFile: URL { support.appendingPathComponent("locks/secrets.lock") }
    func sendOnce(_ r: AgentRequest) async throws -> AgentResponse {
        let input = try data(r)
        return try decode(await service.respond(subcommand: r.subcommand, input: { input }))
    }
    /// A sibling test spawning a process can briefly keep a just-released flock alive, so back-to-back
    /// commands in one process can see `.busy` here. Real commands are separate processes, and only
    /// the holder spawns. A lock that's really stuck still fails: this gives up after 2 seconds.
    func send(_ r: AgentRequest) async throws -> AgentResponse {
        var response = try await sendOnce(r)
        for _ in 0..<100 where response.failure == .busy {
            try await Task.sleep(for: .milliseconds(20))
            response = try await sendOnce(r)
        }
        return response
    }
    func connected() async throws {
        let r = try await send(.connect(destination: drive, clientID: "id", clientSecret: "client-secret-not-real"))
        #expect(r.failure == nil)
    }
    func store(confirmed: Bool) throws -> Destination {
        var d = drive
        d.recoveryKitConfirmed = confirmed
        try config.saveDestinations([d])
        return d
    }
    var workIsEmpty: Bool { ((try? FileManager.default.contentsOfDirectory(atPath: work.path)) ?? ["?"]).isEmpty }
}

@Suite struct AgentServiceTests {
    @Test func connectAndKitGoThroughTheAgent() async throws {
        let rig = try ServiceRig()
        try await rig.connected()
        #expect(try rig.secrets.vault(for: rig.drive) != nil)

        let r = try await rig.send(.recoveryKit(destination: rig.drive))
        let kit = try RecoveryKit(parsing: try #require(r.kitText))
        #expect(kit.clientID == "id" && kit.clientSecret == "client-secret-not-real")
        #expect(rig.workIsEmpty)
    }

    @Test func reconnectGoesThroughTheAgent() async throws {
        let rig = try ServiceRig()
        try await rig.connected()
        #expect(try await rig.send(.reconnect(destination: rig.drive)).failure == nil)
    }

    @Test func drillUsesOnlyTheKitsKeys() async throws {
        let rig = try ServiceRig()
        try await rig.connected()
        let kitText = try #require(try await rig.send(.recoveryKit(destination: rig.drive)).kitText)
        try rig.secrets.delete(SecretKeys.vault(rig.drive.id))   // the Keychain's keys play no part

        let original = rig.tmp.url.appendingPathComponent("note.txt")
        try "the words".write(to: original, atomically: true, encoding: .utf8)
        let r = try await rig.send(.drill(destination: rig.drive, kitText: kitText, relativePath: "Sets/D/note.txt", original: original))
        #expect(r.failure == nil && r.drillPassed == true)
        #expect(rig.workIsEmpty)   // session closed

        try "other words".write(to: original, atomically: true, encoding: .utf8)
        let failed = try await rig.send(.drill(destination: rig.drive, kitText: kitText, relativePath: "Sets/D/note.txt", original: original))
        #expect(failed.drillPassed == false)
        #expect(rig.workIsEmpty)
    }

    @Test func restoreFromKitGoesThroughTheAgent() async throws {
        let rig = try ServiceRig()
        try await rig.connected()
        let kitText = try #require(try await rig.send(.recoveryKit(destination: rig.drive)).kitText)
        let vault = try rig.secrets.vault(for: rig.drive)
        try rig.secrets.delete(SecretKeys.vault(rig.drive.id))
        let confirmed = try rig.store(confirmed: true)
        #expect(try await rig.send(.connect(destination: confirmed, clientID: "id", clientSecret: "client-secret-not-real")).failure
                == .setup(.vaultLostNeedsRecoveryKit))
        #expect(try await rig.send(.restoreFromKit(destination: confirmed, kitText: kitText, acceptUnproven: false)).failure == nil)
        #expect(try rig.secrets.vault(for: rig.drive) == vault)
    }

    @Test func typedFailuresCrossTheChannel() async throws {
        let rig = try ServiceRig()
        #expect(try await rig.send(.reconnect(destination: rig.drive)).failure == .session(.notSignedIn))
        #expect(try await rig.send(.recoveryKit(destination: rig.drive)).failure == .session(.encryptionKeysMissing))
        let r = try await rig.send(.drill(destination: rig.drive, kitText: "nothing", relativePath: "a", original: rig.tmp.url))
        #expect(r.failure == .kit(.notARecoveryKit))
    }

    @Test func badInputIsRefusedWithoutEchoingIt() async throws {
        let rig = try ServiceRig()
        let garbage = Data("client-secret-not-real".utf8)
        let out = await rig.service.respond(subcommand: "connect", input: { garbage })
        #expect(try decode(out).failure == .invalidRequest)
        #expect(!String(decoding: out, as: UTF8.self).contains("not-real"))

        // The subcommand on the command line must agree with the request on stdin.
        let request = try data(.reconnect(destination: rig.drive))
        let mismatch = await rig.service.respond(subcommand: "drill", input: { request })
        #expect(try decode(mismatch).failure == .invalidRequest)
    }

    // MARK: - Who may ask

    /// Any process of the owner can spawn the agent. A refusal must come before stdin or the Keychain.
    @Test func untrustedCallerReachesNothing() async throws {
        let rig = try ServiceRig()
        rig.trust.callerFailure = .untrustedCaller
        let flag = ReadFlag()
        let out = await rig.service.respond(subcommand: "kit", input: { flag.read = true; return Data() })
        #expect(try decode(out).failure == .untrustedCaller)
        #expect(!flag.read && rig.secrets.reads == 0)
    }

    @Test func tamperedHelperStopsBeforeTheKeychain() async throws {
        let rig = try ServiceRig()
        rig.trust.helperFailure = .untrustedHelper
        #expect(try await rig.send(.recoveryKit(destination: rig.drive)).failure == .untrustedHelper)
        #expect(rig.secrets.reads == 0)
    }

    // MARK: - Kit reveal

    @Test func onlyTheFirstRevealSkipsTheOwnerCheck() async throws {
        let rig = try ServiceRig()
        try await rig.connected()
        #expect(try await rig.send(.recoveryKit(destination: rig.drive)).kitText != nil)
        #expect(rig.presence.asked == 0)
        #expect(try await rig.send(.recoveryKit(destination: rig.drive)).kitText != nil)
        #expect(rig.presence.asked == 1)
    }

    @Test func refusedPresenceRevealsNothing() async throws {
        let rig = try ServiceRig()
        try await rig.connected()
        try rig.secrets.delete(SecretKeys.firstReveal(rig.drive.id))
        rig.presence.refuses = true
        let refused = try await rig.send(.recoveryKit(destination: rig.drive))
        #expect(refused.failure == .presenceRefused && refused.kitText == nil)
        // Asked before any key or client is read.
        let vaultKey = SecretKeys.vault(rig.drive.id), signInKey = SecretKeys.signIn(rig.drive.id)
        let afterConnect = rig.secrets.readKeys.suffix(1)
        #expect(afterConnect == [SecretKeys.firstReveal(rig.drive.id)])
        #expect(!afterConnect.contains(vaultKey) && !afterConnect.contains(signInKey))
    }

    /// The whole point: a missing marker means ask. Nothing has to be proven to demand presence.
    @Test func noMarkerMeansPresenceWhateverTheConfigSays() async throws {
        let rig = try ServiceRig()
        try await rig.connected()
        try rig.secrets.delete(SecretKeys.firstReveal(rig.drive.id))
        _ = try rig.store(confirmed: false)
        rig.presence.refuses = true
        #expect(try await rig.send(.recoveryKit(destination: rig.drive)).failure == .presenceRefused)
    }

    @Test func aDamagedMarkerIsNoMarker() async throws {
        let rig = try ServiceRig()
        try await rig.connected()
        try rig.secrets.write("anything else", key: SecretKeys.firstReveal(rig.drive.id))
        rig.presence.refuses = true
        #expect(try await rig.send(.recoveryKit(destination: rig.drive)).failure == .presenceRefused)
    }

    @Test func markerIsSpentBeforeTheTextReturns() async throws {
        let rig = try ServiceRig()
        try await rig.connected()
        rig.secrets.failDeletes = true
        let failed = try await rig.send(.recoveryKit(destination: rig.drive))
        #expect(failed.kitText == nil && failed.failure != nil)
        rig.secrets.failDeletes = false
        #expect(try await rig.send(.recoveryKit(destination: rig.drive)).kitText != nil)
        #expect(try rig.secrets.read(SecretKeys.firstReveal(rig.drive.id)) == nil)
    }

    @Test func aFailedRevealKeepsTheMarker() async throws {
        let rig = try ServiceRig()
        try await rig.connected()
        let vault = try #require(try rig.secrets.read(SecretKeys.vault(rig.drive.id)))
        try rig.secrets.delete(SecretKeys.vault(rig.drive.id))
        #expect(try await rig.send(.recoveryKit(destination: rig.drive)).failure == .session(.encryptionKeysMissing))
        try rig.secrets.write(vault, key: SecretKeys.vault(rig.drive.id))
        #expect(try await rig.send(.recoveryKit(destination: rig.drive)).kitText != nil)
        #expect(rig.presence.asked == 0)
    }

    @Test func aRestoredVaultAlwaysAsks() async throws {
        let rig = try ServiceRig()
        try await rig.connected()
        let text = try #require(try await rig.send(.recoveryKit(destination: rig.drive)).kitText)
        try rig.secrets.delete(SecretKeys.vault(rig.drive.id))
        #expect(try await rig.send(.restoreFromKit(destination: try rig.store(confirmed: true), kitText: text, acceptUnproven: false)).failure == nil)
        rig.presence.refuses = true
        #expect(try await rig.send(.recoveryKit(destination: rig.drive)).failure == .presenceRefused)
    }

    // MARK: - Accepting an unproven kit

    private func kitText(_ rig: ServiceRig) async throws -> String {
        try await rig.connected()
        return try #require(try await rig.send(.recoveryKit(destination: rig.drive)).kitText)
    }

    @Test func acceptingAnUnprovenKitNeedsPresence() async throws {
        let rig = try ServiceRig()
        let text = try await kitText(rig)
        try rig.secrets.delete(SecretKeys.vault(rig.drive.id))
        rig.presence.refuses = true
        let r = try await rig.send(.restoreFromKit(destination: rig.drive, kitText: text, acceptUnproven: true))
        #expect(r.failure == .presenceRefused)
        #expect(try rig.secrets.vault(for: rig.drive) == nil)
    }

    @Test func provenRestoreDoesNotAskForPresence() async throws {
        let rig = try ServiceRig()
        let text = try await kitText(rig)
        try rig.secrets.delete(SecretKeys.vault(rig.drive.id))
        let r = try await rig.send(.restoreFromKit(destination: rig.drive, kitText: text, acceptUnproven: false))
        #expect(r.failure == nil && rig.presence.asked == 0)
    }

    // MARK: - The stored Destination wins

    @Test func requestCannotLowerConfirmationForConnect() async throws {
        let rig = try ServiceRig()
        _ = try rig.store(confirmed: true)
        let r = try await rig.send(.connect(destination: rig.drive, clientID: "id", clientSecret: "s"))
        #expect(r.failure == .setup(.vaultLostNeedsRecoveryKit))
        #expect(try rig.secrets.vault(for: rig.drive) == nil)
    }

    @Test func requestCannotTurnEncryptionOff() async throws {
        let rig = try ServiceRig()
        try rig.config.saveDestinations([rig.drive])
        var plain = rig.drive
        plain.encrypted = false
        #expect(try await rig.send(.connect(destination: plain, clientID: "id", clientSecret: "s")).failure == nil)
        #expect(try rig.secrets.vault(for: rig.drive) != nil)
    }

    @Test func unknownDestinationUsesTheRequestsCopy() async throws {
        let rig = try ServiceRig()
        try rig.config.saveDestinations([Destination(name: "Other", kind: .oneDrive)])
        try await rig.connected()
        #expect(try rig.secrets.signIn(for: rig.drive) != nil)
    }

    @Test func unreadableConfigRefuses() async throws {
        let rig = try ServiceRig()
        try "not json".write(to: rig.support.appendingPathComponent("destinations.json"), atomically: true, encoding: .utf8)
        #expect(try await rig.send(.reconnect(destination: rig.drive)).failure == .configUnreadable)
        #expect(rig.secrets.reads == 0)
    }

    // MARK: - One writer at a time

    private func holdLock(_ rig: ServiceRig) async throws -> Int32 {
        try FileManager.default.createDirectory(at: rig.lockFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(rig.lockFile.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        var locked = flock(fd, LOCK_EX | LOCK_NB) == 0
        for _ in 0..<100 where !locked {   // see `ServiceRig.send`
            try await Task.sleep(for: .milliseconds(20))
            locked = flock(fd, LOCK_EX | LOCK_NB) == 0
        }
        #expect(locked)
        return fd
    }

    @Test func overlappingWritersAreRefused() async throws {
        let rig = try ServiceRig()
        let fd = try await holdLock(rig)
        let original = rig.tmp.url.appendingPathComponent("n.txt")
        for r: AgentRequest in [.connect(destination: rig.drive, clientID: "id", clientSecret: "s"),
                                .reconnect(destination: rig.drive),
                                .recoveryKit(destination: rig.drive),
                                .restoreFromKit(destination: rig.drive, kitText: "x", acceptUnproven: false),
                                .drill(destination: rig.drive, kitText: "x", relativePath: "n.txt", original: original)] {
            #expect(try await rig.sendOnce(r).failure == .busy)
        }
        close(fd)
        try await rig.connected()   // released by close
    }

    @Test func lockIsReleasedAfterEveryCommand() async throws {
        let rig = try ServiceRig()
        #expect(try await rig.send(.reconnect(destination: rig.drive)).failure == .session(.notSignedIn))
        try await rig.connected()
        let fd = try await holdLock(rig)
        close(fd)
    }

    /// `kit` spends the marker, so two at once mustn't both get the free reveal.
    @Test func kitTakesTheLock() async throws {
        let rig = try ServiceRig()
        try await rig.connected()
        let fd = try await holdLock(rig)
        defer { close(fd) }
        let r = try await rig.sendOnce(.recoveryKit(destination: rig.drive))
        #expect(r.failure == .busy)
        #expect(try rig.secrets.read(SecretKeys.firstReveal(rig.drive.id)) == SecretKeys.firstRevealPending)
    }

    @Test func aBrokenLockIsNotBusy() async throws {
        let rig = try ServiceRig()
        try FileManager.default.createDirectory(at: rig.lockFile, withIntermediateDirectories: true)   // open() fails: it's a folder
        #expect(try await rig.sendOnce(.reconnect(destination: rig.drive)).failure == .lockFailed)
    }

    @Test func onlyContentionIsBusy() {
        #expect(SecretsLock.failure(errno: EWOULDBLOCK) == .busy)
        #expect(SecretsLock.failure(errno: ENOLCK) == .lockFailed)
        #expect(SecretsLock.failure(errno: EIO) == .lockFailed)
    }

    /// An orphaned rclone that inherited the lock would block every later command until it died.
    @Test func rcloneDoesNotInheritTheLock() async throws {
        let tmp = try TempDir()
        let support = try tmp.sub("support"), record = tmp.url.appendingPathComponent("open-files")
        let fake = try fakeRclone(in: tmp.url, body: """
            /usr/sbin/lsof -p $$ > '\(record.path)'
            prev=''
            for a in "$@"; do [ "$prev" = "--config" ] && cfg="$a"; prev="$a"; done
            echo 'token = {"access_token":"a","refresh_token":"r"}' >> "$cfg"
            exit 0
            """)
        let service = AgentService(secrets: MemorySecrets(), binary: fake, trust: FakeTrust(), presence: FakePresence(),
                                   support: support, workDir: try tmp.sub("work"))
        let connect = try data(.connect(destination: Destination(name: "O", kind: .oneDrive, encrypted: false),
                                        clientID: nil, clientSecret: nil))
        let out = try decode(await service.respond(subcommand: "connect", input: { connect }))
        #expect(out.failure == nil)
        let files = try String(contentsOf: record, encoding: .utf8)
        #expect(files.contains("fake-rclone") && !files.contains("secrets.lock"))
    }

    @Test func lockFileIsPrivate() async throws {
        let rig = try ServiceRig()
        try await rig.connected()
        #expect(try mode(rig.lockFile) == 0o600)
        #expect(try mode(rig.lockFile.deletingLastPathComponent()) == 0o700)
    }

    /// The agent's own helper check runs before each spawn too, not only once at the start.
    @Test func agentRevalidatesTheHelperBeforeEachSpawn() async throws {
        let rig = try ServiceRig()
        try await rig.connected()
        let before = rig.trust.helperChecks
        #expect(try await rig.send(.reconnect(destination: rig.drive)).failure == nil)
        #expect(rig.trust.helperChecks >= before + 2)   // once on entry, once before the sign-in
    }

    @Test func oldInteractiveLeftoversAreWiped() async throws {
        let rig = try ServiceRig()
        let old = rig.work.appendingPathComponent("mirror-run-crashed")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -200_000)], ofItemAtPath: old.path)
        _ = try await rig.send(.reconnect(destination: rig.drive))
        #expect(!FileManager.default.fileExists(atPath: old.path))
    }
}

@Suite struct AgentClientTests {
    private struct Rig {
        let tmp: TempDir
        let record: URL
        let client: AgentClient
        let drive = Destination(name: "Drive", kind: .googleDrive)
        init(reply: String, after: String = "") throws {
            tmp = try TempDir()
            record = tmp.url.appendingPathComponent("record")
            let agent = try fakeRclone(in: tmp.url, body: """
                printf '%s\\n' "$@" > '\(record.path)'
                cat > '\(record.path)'.stdin
                /usr/bin/env > '\(record.path)'.env
                printf '%s' '\(reply)'
                \(after)
                """)
            client = AgentClient(executable: agent)
        }
        var args: String { (try? String(contentsOf: record, encoding: .utf8)) ?? "" }
        var stdin: String { (try? String(contentsOfFile: record.path + ".stdin", encoding: .utf8)) ?? "" }
    }

    @Test func secretsGoOverStdinNeverArguments() async throws {
        let rig = try Rig(reply: "{}")
        try await rig.client.connect(rig.drive, clientID: "client-id-not-real", clientSecret: "client-secret-not-real")
        #expect(rig.args == "connect\n")
        #expect(rig.stdin.contains("client-secret-not-real"))
        let env = (try? String(contentsOfFile: rig.record.path + ".env", encoding: .utf8)) ?? ""
        #expect(!env.contains("not-real"))
    }

    @Test func drillInputStaysOnStdin() async throws {
        let rig = try Rig(reply: #"{"drillPassed":true}"#)
        let passed = try await rig.client.drill(rig.drive, kitText: "kit-text-not-real", relativePath: "Sets/a.txt",
                                                original: URL(fileURLWithPath: "/tmp/a.txt"))
        #expect(passed)
        #expect(rig.args == "drill\n" && rig.stdin.contains("kit-text-not-real"))
    }

    @Test func kitArrivesOverStdout() async throws {
        let rig = try Rig(reply: #"{"kitText":"kit-text-not-real"}"#)
        #expect(try await rig.client.recoveryKitText(for: rig.drive) == "kit-text-not-real")
        #expect(rig.args == "kit\n")
    }

    @Test func restoreSendsKitOverStdin() async throws {
        let rig = try Rig(reply: "{}")
        try await rig.client.restore(rig.drive, kitText: "kit-text-not-real", acceptUnproven: true)
        #expect(rig.args == "restore-kit\n" && rig.stdin.contains("kit-text-not-real"))
        #expect(rig.stdin.contains("acceptUnproven"))
    }

    @Test func reconnectUsesItsSubcommand() async throws {
        let rig = try Rig(reply: "{}")
        try await rig.client.reconnect(rig.drive)
        #expect(rig.args == "reconnect\n")
    }

    @Test func typedFailuresAreRethrown() async throws {
        let rig = try Rig(reply: String(decoding: try JSONEncoder().encode(
            AgentResponse(failure: .setup(.vaultLostNeedsRecoveryKit))), as: UTF8.self))
        await #expect(throws: RemoteSetupError.vaultLostNeedsRecoveryKit) {
            try await rig.client.connect(rig.drive, clientID: "id", clientSecret: "s")
        }
    }

    @Test func garbageOutputIsAnErrorThatDoesNotRepeatIt() async throws {
        let rig = try Rig(reply: "client-secret-not-real", after: "exit 7")
        do { try await rig.client.reconnect(rig.drive); Issue.record("should fail") }
        catch {
            #expect(error as? AgentClientError == .noResponse(exitCode: 7))
            #expect(!"\(error)".contains("not-real"))
        }
    }

    @Test func missingAnswerFieldIsAnError() async throws {
        let rig = try Rig(reply: "{}")
        await #expect(throws: AgentClientError.noResponse(exitCode: 0)) { try await rig.client.recoveryKitText(for: rig.drive) }
    }

    @Test func oversizedRequestIsRefusedNotBlocked() async throws {
        let rig = try Rig(reply: "{}")
        await #expect(throws: AgentClientError.requestTooLarge) {
            try await rig.client.restore(rig.drive, kitText: String(repeating: "a", count: 100_000), acceptUnproven: false)
        }
    }

    @Test func cancellingStopsTheAgent() async throws {
        let rig = try Rig(reply: "", after: "exec /bin/sleep 60")
        let client = rig.client, drive = rig.drive
        let task = Task { try await client.reconnect(drive) }
        while !FileManager.default.fileExists(atPath: rig.record.path + ".env") { try await Task.sleep(for: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    /// The agent stops rclone first, escalating after its own grace, so the client must outwait that.
    @Test func clientWaitsLongerThanTheAgentDoes() {
        #expect(AgentClient.killGrace >= RcloneTool.killGrace * 2)
    }

    @Test func messagesHideTheirSecrets() throws {
        let d = Destination(name: "Drive", kind: .googleDrive)
        let requests: [AgentRequest] = [
            .connect(destination: d, clientID: "id-not-real", clientSecret: "secret-not-real"),
            .restoreFromKit(destination: d, kitText: "kit-not-real", acceptUnproven: false),
            .drill(destination: d, kitText: "kit-not-real", relativePath: "a", original: URL(fileURLWithPath: "/a")),
        ]
        for r in requests {
            for text in [String(describing: r), String(reflecting: r), "\(r)"] {
                #expect(!text.contains("not-real") && text.contains(r.subcommand))
            }
            var dumped = ""
            dump(r, to: &dumped)
            #expect(!dumped.contains("not-real"))
        }
        let response = AgentResponse(kitText: "kit-not-real")
        var dumped = ""
        dump(response, to: &dumped)
        for text in [String(describing: response), String(reflecting: response), dumped] { #expect(!text.contains("not-real")) }
    }

    @Test func bundledAgentPath() {
        let c = AgentClient.bundled(in: URL(fileURLWithPath: "/Applications/Mirror.app"))
        #expect(c.executable.path == "/Applications/Mirror.app/Contents/MacOS/MirrorAgent")
    }
}
