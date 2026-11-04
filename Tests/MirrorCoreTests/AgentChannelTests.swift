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
          lsf|cryptcheck) exit 0 ;;
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

private struct ServiceRig {
    let tmp: TempDir
    let secrets = MemorySecrets()
    let service: AgentService
    let work: URL
    let drive = Destination(name: "Drive", kind: .googleDrive)
    init() throws {
        tmp = try TempDir()
        work = try tmp.sub("work")
        service = AgentService(secrets: secrets, binary: try fakeCloudRclone(in: tmp.url), workDir: work)
    }
    func send(_ r: AgentRequest) async throws -> AgentResponse {
        try decode(await service.respond(subcommand: r.subcommand, input: try data(r)))
    }
    func connected() async throws {
        let r = try await send(.connect(destination: drive, clientID: "id", clientSecret: "client-secret-not-real"))
        #expect(r.failure == nil)
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
        var confirmed = rig.drive
        confirmed.recoveryKitConfirmed = true
        #expect(try await rig.send(.connect(destination: confirmed, clientID: "id", clientSecret: "client-secret-not-real")).failure
                == .setup(.vaultLostNeedsRecoveryKit))
        #expect(try await rig.send(.restoreFromKit(destination: confirmed, kitText: kitText)).failure == nil)
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
        let out = await rig.service.respond(subcommand: "connect", input: garbage)
        #expect(try decode(out).failure == .invalidRequest)
        #expect(!String(decoding: out, as: UTF8.self).contains("not-real"))

        // The subcommand on the command line must agree with the request on stdin.
        let mismatch = await rig.service.respond(subcommand: "drill", input: try data(.reconnect(destination: rig.drive)))
        #expect(try decode(mismatch).failure == .invalidRequest)
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
        try await rig.client.restore(rig.drive, kitText: "kit-text-not-real")
        #expect(rig.args == "restore-kit\n" && rig.stdin.contains("kit-text-not-real"))
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
            try await rig.client.restore(rig.drive, kitText: String(repeating: "a", count: 100_000))
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

    @Test func bundledAgentPath() {
        let c = AgentClient.bundled(in: URL(fileURLWithPath: "/Applications/Mirror.app"))
        #expect(c.executable.path == "/Applications/Mirror.app/Contents/MacOS/MirrorAgent")
    }
}
