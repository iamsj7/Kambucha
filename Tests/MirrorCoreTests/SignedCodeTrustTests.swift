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

/// Made up. It belongs to nobody, so no real signature can pass with it.
private let madeUpTeam = "ABCDE12345"

/// The team that really signed dist/Mirror.app, proven the way the agent proves its own.
private func bundleTrust() throws -> SignedCodeTrust {
    let agent = bundle.appendingPathComponent("Contents/MacOS/MirrorAgent")
    var code: SecStaticCode?
    #expect(SecStaticCodeCreateWithPath(agent as CFURL, [], &code) == errSecSuccess)
    let signature = try #require(code)
    let proven: String? = SignedCodeTrust.provenTeam(claimed: SignedCodeTrust.claimedTeam(signature), identifier: MirrorCore.agentLabel) {
        SignedCodeTrust.staticallyValid(agent, requirement: $0)
    }
    let team: String = try #require(proven)
    return SignedCodeTrust(team: team)
}

private func runScript(_ name: String, environment: [String: String]) throws -> (status: Int32, out: String, err: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = [repoRoot.appendingPathComponent("scripts/\(name)").path]
    process.environment = environment
    let out = Pipe(), err = Pipe()
    process.standardOutput = out
    process.standardError = err
    try process.run()
    process.waitUntilExit()
    return (process.terminationStatus,
            String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
}

@Suite struct SignedCodeTrustTests {
    private let trust = SignedCodeTrust(team: madeUpTeam)

    @Test func requirementsPinTheTeamAndDistinctIdentifiers() throws {
        for text in [try #require(trust.callerRequirement), try #require(trust.helperRequirement)] {
            var requirement: SecRequirement?
            #expect(SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess)
            #expect(text.contains("anchor apple generic") && text.contains("certificate leaf[subject.OU] = \"\(madeUpTeam)\""))
        }
        #expect(try #require(trust.callerRequirement).contains("identifier \"com.shaikjaleel.mirror\" "))
        // rclone can run commands (--password-command), so it must never pass as the caller.
        #expect(try #require(trust.helperRequirement).contains("identifier \"com.shaikjaleel.mirror.rclone\" "))
    }

    @Test func onlyATeamIDShapedStringIsATeam() {
        #expect(SignedCodeTrust.isTeamID(madeUpTeam))
        #expect(SignedCodeTrust.isTeamID("0123456789"))
        for bad in ["", "ABCDE1234", "ABCDE123456", "abcde12345", "ABCDE 2345", "ABCDE1234\n", "ÀBCDE12345", "not set"] {
            #expect(!SignedCodeTrust.isTeamID(bad), "\(bad)")
        }
    }

    /// The team is read out of a signature, so a hostile one mustn't be able to rewrite the requirement.
    @Test func aTeamCannotInjectRequirementLanguage() {
        for hostile in ["X\" or always", "\" or anchor", "A\"or true ", "ABCD\"EFGHI"] {
            #expect(SignedCodeTrust.requirement(identifier: "id", team: hostile) == nil, "\(hostile)")
            #expect(SignedCodeTrust(team: hostile).callerRequirement == nil)
            #expect(SignedCodeTrust(team: hostile).helperRequirement == nil)
        }
    }

    /// An unsigned, ad-hoc or team-less build claims nothing, and a forged claim fails its proof.
    @Test func aTeamIsOnlyEverProven() {
        var asked: [String] = []
        #expect(SignedCodeTrust.provenTeam(claimed: nil, identifier: "id") { asked.append($0); return true } == nil)
        #expect(SignedCodeTrust.provenTeam(claimed: "", identifier: "id") { asked.append($0); return true } == nil)
        #expect(SignedCodeTrust.provenTeam(claimed: "X\" or always", identifier: "id") { asked.append($0); return true } == nil)
        #expect(asked.isEmpty)
        #expect(SignedCodeTrust.provenTeam(claimed: madeUpTeam, identifier: "id") { _ in false } == nil)
        #expect(SignedCodeTrust.provenTeam(claimed: madeUpTeam, identifier: "id") { asked.append($0); return true } == madeUpTeam)
        #expect(asked == [SignedCodeTrust.requirement(identifier: "id", team: madeUpTeam)])
    }

    /// The real derivation, run on a process that isn't our signed agent.
    @Test func thisTestProcessProvesNoTeam() {
        #expect(SignedCodeTrust().team == nil)
    }

    @Test func noTeamRefusesEverything() {
        let none = SignedCodeTrust(team: nil)
        #expect(none.callerRequirement == nil && none.helperRequirement == nil)
        #expect(throws: AgentFailure.untrustedCaller) { try none.verifyCaller() }
        #expect(throws: AgentFailure.untrustedHelper) { try none.verifyHelper(at: vendoredRclone) }
        #expect(throws: AgentFailure.untrustedHelper) { try none.verifyHelper(at: URL(fileURLWithPath: "/bin/ls")) }
    }

    @Test func scriptsAgreeWithThePins() throws {
        let build = try String(contentsOf: repoRoot.appendingPathComponent("scripts/build-app.sh"), encoding: .utf8)
        #expect(build.contains("--identifier com.shaikjaleel.mirror.rclone"))
        #expect(build.contains("--identifier \(MirrorCore.agentLabel) "))
        let verify = try String(contentsOf: repoRoot.appendingPathComponent("scripts/verify-bundle.sh"), encoding: .utf8)
        #expect(verify.contains("anchor apple generic and certificate leaf[subject.OU]"))
        #expect(verify.contains("com.shaikjaleel.mirror.rclone") && verify.contains(MirrorCore.agentLabel))
        #expect(verify.contains(#"symbols="$(nm -u"#))   // a failed nm must not read as "no references"
    }

    /// The real check, on this test process's real parent, which isn't Mirror.app.
    @Test func realCheckRefusesThisTestsParent() {
        #expect(throws: AgentFailure.untrustedCaller) { try SignedCodeTrust().verifyCaller() }
        #expect(throws: AgentFailure.untrustedCaller) { try trust.verifyCaller() }
    }

    @Test func vendoredRcloneIsNotOurSignedHelper() {
        #expect(throws: AgentFailure.untrustedHelper) { try SignedCodeTrust().verifyHelper(at: vendoredRclone) }
        #expect(throws: AgentFailure.untrustedHelper) { try trust.verifyHelper(at: vendoredRclone) }
    }

    @Test func systemBinaryAndMissingFileAreRefused() {
        for check in [SignedCodeTrust(), trust] {
            #expect(throws: AgentFailure.untrustedHelper) { try check.verifyHelper(at: URL(fileURLWithPath: "/bin/ls")) }
            #expect(throws: AgentFailure.untrustedHelper) { try check.verifyHelper(at: URL(fileURLWithPath: "/nonexistent/rclone")) }
        }
    }

    @Test(.enabled(if: hasSignedBundle, noBundle))
    func signedBundlePassesThePins() throws {
        let signed = try bundleTrust()
        try signed.verifyHelper(at: bundle.appendingPathComponent("Contents/Helpers/rclone"))
        #expect(SignedCodeTrust.staticallyValid(bundle, requirement: try #require(signed.callerRequirement)))
    }

    /// Everything about the bundle is right but the team: this is what the team pin adds.
    @Test(.enabled(if: hasSignedBundle, noBundle))
    func anotherTeamsBuildIsRefused() throws {
        #expect(throws: AgentFailure.untrustedHelper) { try trust.verifyHelper(at: bundle.appendingPathComponent("Contents/Helpers/rclone")) }
        #expect(!SignedCodeTrust.staticallyValid(bundle, requirement: try #require(trust.callerRequirement)))
    }

    /// Same team, wrong identifier: this is what the identifier pin adds.
    @Test(.enabled(if: hasSignedBundle, noBundle))
    func identifierPinSeparatesOurOwnBinaries() throws {
        let signed = try bundleTrust()
        let caller = try #require(signed.callerRequirement)
        let agent = bundle.appendingPathComponent("Contents/MacOS/MirrorAgent")
        let rclone = bundle.appendingPathComponent("Contents/Helpers/rclone")
        #expect(throws: AgentFailure.untrustedHelper) { try signed.verifyHelper(at: agent) }
        #expect(!SignedCodeTrust.staticallyValid(agent, requirement: caller))
        #expect(!SignedCodeTrust.staticallyValid(rclone, requirement: caller))
    }

    @Test(.enabled(if: hasSignedBundle, noBundle))
    func tamperedHelperIsRefused() throws {
        let signed = try bundleTrust()
        let tmp = try TempDir()
        let copy = tmp.url.appendingPathComponent("rclone")
        try FileManager.default.copyItem(at: bundle.appendingPathComponent("Contents/Helpers/rclone"), to: copy)
        try signed.verifyHelper(at: copy)
        let handle = try FileHandle(forUpdating: copy)
        try handle.seek(toOffset: 1_000_000)
        let byte = try #require(try handle.read(upToCount: 1))
        try handle.seek(toOffset: 1_000_000)
        try handle.write(contentsOf: Data([byte[0] ^ 0xFF]))
        try handle.close()
        #expect(throws: AgentFailure.untrustedHelper) { try signed.verifyHelper(at: copy) }
    }
}

/// `security` is a stand-in on PATH, so these never list the real Keychain.
@Suite struct SigningIdentityScriptTests {
    private let hashA = String(repeating: "A", count: 40)
    private let hashB = String(repeating: "B", count: 40)

    private func run(listing: [String], chosen: String? = nil) throws -> (status: Int32, out: String, err: String) {
        let tmp = try TempDir()
        let fake = tmp.url.appendingPathComponent("security")
        let lines = listing.enumerated().map { "  \($0.offset + 1)) \($0.element)" } + ["     \(listing.count) valid identities found"]
        try ("#!/bin/sh\ncat <<'EOF'\n" + lines.joined(separator: "\n") + "\nEOF\n").write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        var environment = ["PATH": "\(tmp.url.path):/usr/bin:/bin", "HOME": tmp.url.path]
        if let chosen { environment["MIRROR_SIGN_IDENTITY"] = chosen }
        return try runScript("signing-identity.sh", environment: environment)
    }

    @Test func theSoleIdentityIsPicked() throws {
        for name in ["Apple Development: A Person (ABCDE12345)", "Developer ID Application: A Company (ABCDE12345)"] {
            let result = try run(listing: ["\(hashA) \"\(name)\""])
            #expect(result.status == 0)
            #expect(result.out == "\(hashA)\n")
        }
    }

    @Test func otherKindsOfIdentityDoNotCount() throws {
        let result = try run(listing: ["\(hashB) \"Mac Developer Installer: Someone\"", "\(hashA) \"Apple Development: A Person (ABCDE12345)\""])
        #expect(result.status == 0 && result.out == "\(hashA)\n")
    }

    @Test func noIdentityFailsAndSaysSo() throws {
        let result = try run(listing: [])
        #expect(result.status != 0 && result.out.isEmpty)
        #expect(result.err.contains("No \"Apple Development\" or \"Developer ID Application\" identity"))
    }

    @Test func severalIdentitiesFailAndAreListed() throws {
        let result = try run(listing: ["\(hashA) \"Apple Development: A Person (ABCDE12345)\"", "\(hashB) \"Developer ID Application: A Company (ABCDE12345)\""])
        #expect(result.status != 0 && result.out.isEmpty)
        #expect(result.err.contains("MIRROR_SIGN_IDENTITY"))
        #expect(result.err.contains("Apple Development: A Person") && result.err.contains("Developer ID Application: A Company"))
    }

    @Test func theEnvironmentWinsWithoutLooking() throws {
        let result = try run(listing: [], chosen: "Developer ID Application: A Company (ABCDE12345)")
        #expect(result.status == 0 && result.out == "Developer ID Application: A Company (ABCDE12345)\n")
    }

    /// Ad-hoc would build an app whose agent refuses everything, so say it now.
    @Test func adHocIsNotAnIdentity() throws {
        let result = try run(listing: [], chosen: "-")
        #expect(result.status != 0 && result.out.isEmpty)
    }
}
