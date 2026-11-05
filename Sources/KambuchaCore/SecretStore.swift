import Foundation
import Security

/// Only the `KambuchaAgent` executable ever touches a real store. The Keychain item's creator and
/// reader are then the same signed binary, so no access list or prompt is involved. `KeychainStore`
/// lives in `KambuchaSecrets`, which only the agent links. Kambucha.app goes through `AgentClient`, which
/// passes secrets over the agent's stdin and stdout, and `verify-bundle.sh` checks its binary has no
/// `SecItem` references. This should hold after a rebuild with the same signing identity, but it has yet to be tested on a real cloud destination.
public protocol SecretStoring: Sendable {
    func read(_ key: String) throws -> String?
    func write(_ value: String, key: String) throws
    func delete(_ key: String) throws
}

/// Errors carry a status code only, never a key's value.
public enum SecretStoreError: Error, Equatable, Codable, Sendable {
    case keychain(status: Int32)
    case notText
}

/// The two crypt keys of one destination. Losing them loses the backup, so they are created once.
public struct VaultSecrets: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible,
                            CustomReflectable {
    public var passphrase: String
    public var salt: String
    public init(passphrase: String, salt: String) { self.passphrase = passphrase; self.salt = salt }

    /// 32 random bytes each, as hex: unambiguous when read off paper, and safe on one line.
    public static func generate() -> VaultSecrets {
        VaultSecrets(passphrase: randomHex(), salt: randomHex())
    }

    private static func randomHex() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        // A weak key would silently protect nothing, so there is no fallback.
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            fatalError("The system random number generator failed")
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    public var description: String { "VaultSecrets(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// Keychain item names for one destination.
public enum SecretKeys {
    public static func vault(_ destination: UUID) -> String { "vault.\(destination.uuidString)" }
    public static func signIn(_ destination: UUID) -> String { "signin.\(destination.uuidString)" }
    /// A sign-in kept from a restore that couldn't prove its kit, until the owner answers. Apart from
    /// `signIn` on purpose: there it would pass as a sign-in that survived.
    public static func heldSignIn(_ destination: UUID) -> String { "heldsignin.\(destination.uuidString)" }
}

extension SecretStoring {
    /// Nil when there is none. Unreadable keys throw, so a caller can't mistake them for absent and
    /// generate replacements.
    public func vault(for destination: Destination) throws -> VaultSecrets? {
        guard let json = try read(SecretKeys.vault(destination.id)) else { return nil }
        guard let vault = try? JSONDecoder().decode(VaultSecrets.self, from: Data(json.utf8)),
              !vault.passphrase.isEmpty, !vault.salt.isEmpty else {
            throw RcloneSessionError.encryptionKeysMissing
        }
        return vault
    }

    func saveVault(_ vault: VaultSecrets, for destination: Destination) throws {
        try write(String(decoding: try JSONEncoder().encode(vault), as: UTF8.self), key: SecretKeys.vault(destination.id))
    }

    /// The rclone options of the sign-in: token, client ID and secret, and anything rclone needs to
    /// keep, such as OneDrive's `drive_id` and `drive_type`.
    func signIn(for destination: Destination) throws -> [String: String]? {
        guard let json = try read(SecretKeys.signIn(destination.id)) else { return nil }
        guard let options = try? JSONDecoder().decode([String: String].self, from: Data(json.utf8)) else {
            throw RcloneSessionError.invalidSignIn
        }
        return options
    }

    func saveSignIn(_ options: [String: String], for destination: Destination) throws {
        try write(String(decoding: try JSONEncoder().encode(options), as: UTF8.self), key: SecretKeys.signIn(destination.id))
    }

    /// Nil also for an item that won't decode: it's only a convenience, and signing in again replaces it.
    func heldSignIn(for destination: Destination) throws -> [String: String]? {
        guard let json = try read(SecretKeys.heldSignIn(destination.id)) else { return nil }
        return try? JSONDecoder().decode([String: String].self, from: Data(json.utf8))
    }

    func saveHeldSignIn(_ options: [String: String], for destination: Destination) throws {
        try write(String(decoding: try JSONEncoder().encode(options), as: UTF8.self), key: SecretKeys.heldSignIn(destination.id))
    }
}
