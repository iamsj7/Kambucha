import Testing
import Foundation
import Security
@testable import MirrorCore
@testable import MirrorSecrets

private let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let bundle = repoRoot.appendingPathComponent("dist/Mirror.app")
private var hasSignedBundle: Bool {
    FileManager.default.fileExists(atPath: bundle.appendingPathComponent("Contents/Helpers/rclone").path)
}

private let noBundle: Comment = "SKIPPED, signature not proven: no dist/Mirror.app. Run scripts/build-app.sh first"

/// Stands in for LAContext: answers only when told, and an invalidate ends it, as the real one does.
private final class FakePrompt: PresencePrompt, @unchecked Sendable {
    private let lock = NSLock()
    private var reply: (@Sendable (Bool) -> Void)?
    private(set) var invalidated = false
    let answer: Bool?
    init(answer: Bool?) { self.answer = answer }
    func evaluate(reason: String, reply: @escaping @Sendable (Bool) -> Void) {
        if let answer { reply(answer) } else { lock.withLock { self.reply = reply } }
    }
    func invalidate() {
        let pending: (@Sendable (Bool) -> Void)? = lock.withLock {
            invalidated = true
            defer { reply = nil }
            return reply
        }
        pending?(false)
    }
}

@Suite struct DevicePresenceTests {
    @Test func answerDecides() async throws {
        try await DevicePresence(timeout: 5, prompt: { FakePrompt(answer: true) }).confirm(reason: "r")
        await #expect(throws: AgentFailure.presenceRefused) {
            try await DevicePresence(timeout: 5, prompt: { FakePrompt(answer: false) }).confirm(reason: "r")
        }
    }

    /// Nobody at the Mac must not leave the agent, and the secrets lock, waiting forever.
    @Test func timeoutDismissesThePrompt() async throws {
        let prompt = FakePrompt(answer: nil)
        await #expect(throws: AgentFailure.presenceRefused) {
            try await DevicePresence(timeout: 0.05, prompt: { prompt }).confirm(reason: "r")
        }
        #expect(prompt.invalidated)
    }

    /// SIGTERM from a cancelled app call arrives as task cancellation.
    @Test func cancellationDismissesThePrompt() async throws {
        let prompt = FakePrompt(answer: nil)
        let task = Task { try await DevicePresence(timeout: 60, prompt: { prompt }).confirm(reason: "r") }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(prompt.invalidated)
    }

    @Test func aQuickAnswerDoesNotDismissLater() async throws {
        let prompt = FakePrompt(answer: true)
        try await DevicePresence(timeout: 0.05, prompt: { prompt }).confirm(reason: "r")
        try await Task.sleep(for: .milliseconds(120))
        #expect(!prompt.invalidated)
    }
}

@Suite struct SignedCodeTrustTests {
    @Test func requirementsPinTheTeamAndDistinctIdentifiers() {
        for text in [SignedCodeTrust.callerRequirement, SignedCodeTrust.helperRequirement] {
            var requirement: SecRequirement?
            #expect(SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess)
            #expect(text.contains("anchor apple generic") && text.contains("certificate leaf[subject.OU] = \"ABCDE12345\""))
        }
        #expect(SignedCodeTrust.callerRequirement.contains("identifier \"com.shaikjaleel.mirror\" "))
        // rclone can run commands (--password-command), so it must never pass as the caller.
        #expect(SignedCodeTrust.helperRequirement.contains("identifier \"com.shaikjaleel.mirror.rclone\" "))
    }

    @Test func scriptsAgreeWithThePins() throws {
        let build = try String(contentsOf: repoRoot.appendingPathComponent("scripts/build-app.sh"), encoding: .utf8)
        #expect(build.contains("--identifier com.shaikjaleel.mirror.rclone"))
        let verify = try String(contentsOf: repoRoot.appendingPathComponent("scripts/verify-bundle.sh"), encoding: .utf8)
        #expect(verify.contains(SignedCodeTrust.teamID) && verify.contains("com.shaikjaleel.mirror.rclone"))
        #expect(verify.contains(#"symbols="$(nm -u"#))   // a failed nm must not read as "no references"
    }

    /// The real check, on this test process's real parent, which isn't Mirror.app.
    @Test func realCheckRefusesThisTestsParent() {
        #expect(throws: AgentFailure.untrustedCaller) { try SignedCodeTrust().verifyCaller() }
    }

    @Test func vendoredRcloneIsNotOurSignedHelper() {
        #expect(throws: AgentFailure.untrustedHelper) { try SignedCodeTrust().verifyHelper(at: vendoredRclone) }
    }

    @Test func systemBinaryAndMissingFileAreRefused() {
        #expect(throws: AgentFailure.untrustedHelper) { try SignedCodeTrust().verifyHelper(at: URL(fileURLWithPath: "/bin/ls")) }
        #expect(throws: AgentFailure.untrustedHelper) { try SignedCodeTrust().verifyHelper(at: URL(fileURLWithPath: "/nonexistent/rclone")) }
    }

    @Test(.enabled(if: hasSignedBundle, noBundle))
    func signedBundlePassesThePins() throws {
        try SignedCodeTrust().verifyHelper(at: bundle.appendingPathComponent("Contents/Helpers/rclone"))
        #expect(SignedCodeTrust.staticallyValid(bundle, requirement: SignedCodeTrust.callerRequirement))
    }

    /// Same team, wrong identifier: this is what the identifier pin adds.
    @Test(.enabled(if: hasSignedBundle, noBundle))
    func identifierPinSeparatesOurOwnBinaries() {
        let agent = bundle.appendingPathComponent("Contents/MacOS/MirrorAgent")
        let rclone = bundle.appendingPathComponent("Contents/Helpers/rclone")
        #expect(throws: AgentFailure.untrustedHelper) { try SignedCodeTrust().verifyHelper(at: agent) }
        #expect(!SignedCodeTrust.staticallyValid(agent, requirement: SignedCodeTrust.callerRequirement))
        #expect(!SignedCodeTrust.staticallyValid(rclone, requirement: SignedCodeTrust.callerRequirement))
    }

    @Test(.enabled(if: hasSignedBundle, noBundle))
    func tamperedHelperIsRefused() throws {
        let tmp = try TempDir()
        let copy = tmp.url.appendingPathComponent("rclone")
        try FileManager.default.copyItem(at: bundle.appendingPathComponent("Contents/Helpers/rclone"), to: copy)
        try SignedCodeTrust().verifyHelper(at: copy)
        let handle = try FileHandle(forUpdating: copy)
        try handle.seek(toOffset: 1_000_000)
        let byte = try #require(try handle.read(upToCount: 1))
        try handle.seek(toOffset: 1_000_000)
        try handle.write(contentsOf: Data([byte[0] ^ 0xFF]))
        try handle.close()
        #expect(throws: AgentFailure.untrustedHelper) { try SignedCodeTrust().verifyHelper(at: copy) }
    }
}
