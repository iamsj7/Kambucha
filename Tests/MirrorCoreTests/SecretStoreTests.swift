import Testing
import Foundation
import Security
@testable import MirrorCore

@Suite struct SecretStoreTests {
    @Test func generatedSecretsAreUniqueAndLongEnough() {
        let a = VaultSecrets.generate(), b = VaultSecrets.generate()
        #expect(a.passphrase != b.passphrase && a.salt != b.salt && a.passphrase != a.salt)
        for value in [a.passphrase, a.salt, b.passphrase, b.salt] {
            #expect(value.utf8.count == 64)   // 32 bytes as hex
            #expect(value.allSatisfy { $0.isHexDigit })
        }
    }

    @Test func vaultDescriptionHidesSecrets() {
        let v = VaultSecrets.generate()
        for text in [String(describing: v), String(reflecting: v), "\(v)"] {
            #expect(!text.contains(v.passphrase) && !text.contains(v.salt))
        }
    }

    /// A throwaway service, so no real Mirror item can be touched. Deleted even if an expectation fails.
    @Test func keychainRoundTrip() throws {
        let store = KeychainStore(service: "com.shaikjaleel.mirror.test.\(UUID().uuidString)")
        let key = "round-trip"
        defer { try? store.delete(key) }

        #expect(try store.read(key) == nil)
        try store.write("first value", key: key)
        #expect(try store.read(key) == "first value")
        try store.write("second value", key: key)
        #expect(try store.read(key) == "second value")
        try store.delete(key)
        #expect(try store.read(key) == nil)
        try store.delete(key)   // deleting nothing is not an error
    }

    @Test func keychainServicesAreSeparate() throws {
        let a = KeychainStore(service: "com.shaikjaleel.mirror.test.\(UUID().uuidString)")
        let b = KeychainStore(service: "com.shaikjaleel.mirror.test.\(UUID().uuidString)")
        defer { try? a.delete("k"); try? b.delete("k") }
        try a.write("only in a", key: "k")
        #expect(try b.read("k") == nil)
    }

    /// `kSecUseKeychain` needs a `SecKeychainRef`, which the SDK no longer lets us get, so this proves
    /// where the item really lands. `security` reads attributes only, of a throwaway item.
    @Test func keychainItemLandsInTheLoginKeychain() throws {
        let service = "com.shaikjaleel.mirror.test.\(UUID().uuidString)"
        let store = KeychainStore(service: service)
        defer { try? store.delete("k") }
        try store.write("v", key: "k")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", service, "-a", "k"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        #expect(p.terminationStatus == 0)
        #expect(text.contains("login.keychain"))
    }

    @Test func keychainQueryStaysOffTheDataProtectionKeychain() {
        let q = KeychainStore.baseQuery(service: "s", key: "k")
        #expect(q[kSecUseDataProtectionKeychain as String] as? Bool == false)
        #expect(q[kSecUseAuthenticationContext as String] != nil)
    }

    @Test func keychainItemIsNotSynchronizable() throws {
        let service = "com.shaikjaleel.mirror.test.\(UUID().uuidString)"
        let store = KeychainStore(service: service)
        defer { try? store.delete("k") }
        try store.write("v", key: "k")
        #expect(KeychainStore.baseQuery(service: service, key: "k")[kSecAttrSynchronizable as String] as? Bool == false)
        // Asking for a synchronizable item must find nothing.
        var q = KeychainStore.baseQuery(service: service, key: "k")
        q[kSecAttrSynchronizable as String] = true
        q[kSecUseDataProtectionKeychain as String] = nil   // synchronizable items live only there
        #expect(SecItemCopyMatching(q as CFDictionary, nil) == errSecItemNotFound)
    }
}
