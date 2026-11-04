import Foundation
import Security

public protocol SecretStoring: Sendable {
    func read(_ key: String) throws -> String?
    func write(_ value: String, key: String) throws
    func delete(_ key: String) throws
}

/// Errors carry a status code only, never a key's value.
public enum SecretStoreError: Error, Equatable {
    case keychain(status: Int32)
    case notText
}

/// The login Keychain. Items are never synchronizable, so they stay on this Mac.
public struct KeychainStore: SecretStoring {
    private let service: String
    public init(service: String = "com.shaikjaleel.mirror") { self.service = service }

    /// A locked or prompting Keychain fails rather than blocks: the agent has nobody to answer a
    /// dialog, and a secret must never fall back to anywhere else.
    static func baseQuery(service: String, key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key,
         kSecAttrSynchronizable as String: false,
         kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail]
    }

    public func read(_ key: String) throws -> String? {
        var query = Self.baseQuery(service: service, key: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw SecretStoreError.keychain(status: status) }
        guard let data = result as? Data, let text = String(data: data, encoding: .utf8) else {
            throw SecretStoreError.notText
        }
        return text
    }

    public func write(_ value: String, key: String) throws {
        let query = Self.baseQuery(service: service, key: key)
        let data = Data(value.utf8)
        let updated = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw SecretStoreError.keychain(status: updated) }
        var add = query
        add[kSecValueData as String] = data
        let added = SecItemAdd(add as CFDictionary, nil)
        guard added == errSecSuccess else { throw SecretStoreError.keychain(status: added) }
    }

    public func delete(_ key: String) throws {
        let status = SecItemDelete(Self.baseQuery(service: service, key: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecretStoreError.keychain(status: status)
        }
    }
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
}
