import Foundation
import LocalAuthentication
import MirrorCore
import Security

/// Pins the agent's caller and helper to our signature. Team ID is the certificate's OU, not the code
/// in its name. The two identifiers differ on purpose: rclone can run commands (`--password-command`),
/// so if it could pass as the caller, anyone could use it to launder a request.
public struct SignedCodeTrust: AgentTrust {
    static let teamID = "ABCDE12345"
    private static let pin = "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\""
    static let callerRequirement = "identifier \"\(MirrorCore.bundleID)\" and \(pin)"
    static let helperRequirement = "identifier \"\(MirrorCore.bundleID).rclone\" and \(pin)"

    public init() {}

    /// By pid, as there's no public way to get a parent's audit token. If the parent exits we're
    /// reparented to launchd, so a second look shows the pid wasn't recycled during the check.
    public func verifyCaller() throws {
        let parent = getppid()
        guard parent > 1, Self.runningValid(pid: parent, requirement: Self.callerRequirement), getppid() == parent else {
            throw AgentFailure.untrustedCaller
        }
    }

    public func verifyHelper(at url: URL) throws {
        guard Self.staticallyValid(url, requirement: Self.helperRequirement) else { throw AgentFailure.untrustedHelper }
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

/// Touch ID or the login password, shown by the system.
public struct DevicePresence: UserPresence {
    public init() {}

    public func confirm(reason: String) async throws {
        let passed: Bool = await withCheckedContinuation { continuation in
            LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
                continuation.resume(returning: success)
            }
        }
        guard passed else { throw AgentFailure.presenceRefused }
    }
}
