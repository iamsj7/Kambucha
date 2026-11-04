import Foundation
import LocalAuthentication
import MirrorCore
import Security

/// The login Keychain, used from `MirrorAgent` only. Items are never synchronizable, so they stay on
/// this Mac.
///
/// `kSecUseKeychain` isn't set: it needs a `SecKeychainRef`, and the SDK no longer declares any way
/// to get one. Staying off the data-protection Keychain sends items to the default file Keychain,
/// which is the login Keychain, and a test confirms that.
public struct KeychainStore: SecretStoring {
    private let service: String
    public init(service: String = "com.shaikjaleel.mirror") { self.service = service }

    /// Asks for no interaction: the agent has nobody to answer a dialog, and a secret must never fall
    /// back to anywhere else. This is a backstop, unproven on the file Keychain until Gate 7. What
    /// keeps prompts away is that the agent is the only reader.
    static func baseQuery(service: String, key: String) -> [String: Any] {
        let noInteraction = LAContext()
        noInteraction.interactionNotAllowed = true
        return [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: key,
                kSecAttrSynchronizable as String: false,
                kSecUseDataProtectionKeychain as String: false,
                kSecUseAuthenticationContext as String: noInteraction]
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
