import Foundation
import LocalAuthentication
import KambuchaCore
import Security

/// Pins the agent's caller and helper to our signature. The caller check is defence in depth: a
/// process of the same user can exec the signed Kambucha binary and pass it.
/// Team ID is the certificate's OU, not the code in its name. The two identifiers differ on purpose:
/// rclone can run commands (`--password-command`), so if it could pass as the caller, anyone could
/// use it to launder a request.
///
/// The team is whichever one signed this agent, so any developer's build pins itself. It comes only
/// from the running signature, never from a file, argument or environment, and it fails closed: with
/// no proven team, nothing passes. Re-signing the agent moves the pin too, so this guards against
/// other programs, not against a replaced agent. That job is the Keychain's: its items answer to the
/// code that wrote them.
public struct SignedCodeTrust: AgentTrust {
    /// Nil on an unsigned, ad-hoc or team-less build, and every check then refuses.
    let team: String?

    public init() { self.init(team: Self.ownTeam()) }
    init(team: String?) { self.team = team }

    /// Also what keeps a hostile signature from writing its own requirement language.
    static func isTeamID(_ text: String) -> Bool {
        text.utf8.count == 10 && text.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) }
    }

    /// Nil, not a looser requirement, when `team` isn't a Team ID.
    static func requirement(identifier: String, team: String?) -> String? {
        guard let team, isTeamID(team) else { return nil }
        return "identifier \"\(identifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
    }

    var callerRequirement: String? { Self.requirement(identifier: KambuchaCore.bundleID, team: team) }
    var helperRequirement: String? { Self.requirement(identifier: "\(KambuchaCore.bundleID).rclone", team: team) }

    /// By pid, as there's no public way to get a parent's audit token. If the parent exits we're
    /// reparented to launchd, so a second look shows the pid wasn't recycled during the check.
    public func verifyCaller() throws {
        let parent = getppid()
        guard parent > 1, let requirement = callerRequirement,
              Self.runningValid(pid: parent, requirement: requirement), getppid() == parent else {
            throw AgentFailure.untrustedCaller
        }
    }

    public func verifyHelper(at url: URL) throws {
        guard let requirement = helperRequirement, Self.staticallyValid(url, requirement: requirement) else {
            throw AgentFailure.untrustedHelper
        }
    }

    /// A signature's TeamIdentifier is only a string its signer wrote, and an ad-hoc or self-made
    /// signature can claim any team. So a claim counts only once `proof` shows that the signature
    /// meets the whole requirement, which takes an Apple-issued certificate for that team.
    static func provenTeam(claimed: String?, identifier: String, proof: (String) -> Bool) -> String? {
        guard let requirement = requirement(identifier: identifier, team: claimed), proof(requirement) else { return nil }
        return claimed
    }

    /// `SecCodeCheckValidity` on our own running code also ties the kernel's view of this process to
    /// the signature read here, so swapping the file on disk after launch doesn't move the pin.
    private static func ownTeam() -> String? {
        var running: SecCode?
        guard SecCodeCopySelf([], &running) == errSecSuccess, let running else { return nil }
        var onDisk: SecStaticCode?
        guard SecCodeCopyStaticCode(running, [], &onDisk) == errSecSuccess, let onDisk else { return nil }
        return provenTeam(claimed: claimedTeam(onDisk), identifier: KambuchaCore.agentLabel) { text in
            guard let requirement = requirement(text) else { return false }
            return SecCodeCheckValidity(running, [], requirement) == errSecSuccess
        }
    }

    static func claimedTeam(_ code: SecStaticCode) -> String? {
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let info = info as? [String: Any] else { return nil }
        return info[kSecCodeInfoTeamIdentifier as String] as? String
    }

    private static func requirement(_ text: String) -> SecRequirement? {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess else { return nil }
        return requirement
    }

    private static func runningValid(pid: pid_t, requirement text: String) -> Bool {
        var code: SecCode?
        let attributes = [kSecGuestAttributePid: NSNumber(value: pid)] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code,
              let requirement = requirement(text) else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    static func staticallyValid(_ url: URL, requirement text: String) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              let requirement = requirement(text) else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate)
        return SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
    }
}

/// One prompt to the person at the Mac. `invalidate` dismisses it, and its reply then says false.
public protocol PresencePrompt: AnyObject, Sendable {
    func evaluate(reason: String, reply: @escaping @Sendable (Bool) -> Void)
    func invalidate()
}

private final class SystemPrompt: PresencePrompt, @unchecked Sendable {
    private let context = LAContext()
    func evaluate(reason: String, reply: @escaping @Sendable (Bool) -> Void) {
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in reply(success) }
    }
    func invalidate() { context.invalidate() }
}

/// Touch ID or the login password, shown by the system. It holds the secrets lock while it waits, so
/// it gives up after `timeout`, and cancelling (SIGTERM from the app) dismisses it at once.
public struct DevicePresence: UserPresence {
    private let timeout: TimeInterval
    private let prompt: @Sendable () -> any PresencePrompt

    public init(timeout: TimeInterval = 120) { self.init(timeout: timeout, prompt: { SystemPrompt() }) }
    init(timeout: TimeInterval, prompt: @escaping @Sendable () -> any PresencePrompt) {
        self.timeout = timeout; self.prompt = prompt
    }

    public func confirm(reason: String) async throws {
        try Task.checkCancellation()
        let current = prompt()
        let expiry = DispatchWorkItem { current.invalidate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: expiry)
        defer { expiry.cancel() }
        let passed = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                current.evaluate(reason: reason) { continuation.resume(returning: $0) }
            }
        } onCancel: { current.invalidate() }
        try Task.checkCancellation()
        guard passed else { throw AgentFailure.presenceRefused }
    }
}
