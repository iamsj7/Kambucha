import Testing
import Foundation
import Security
@testable import MirrorCore
@testable import MirrorSecrets

/// Service names for tests that touch the real login Keychain. A killed run never reaches its
/// `defer`, so each name carries its creator's pid, and the first use in a run clears items whose
/// creator has gone. A live pid may be another worktree's run, so its items are left alone, and so
/// is any name without this prefix.
enum ThrowawayKeychain {
    static let prefix = "com.shaikjaleel.mirror.test.pid-"
    private static let sweptOnce: Void = sweepStale()

    static func service() -> String {
        _ = sweptOnce
        return service(owner: getpid())
    }

    static func service(owner: pid_t) -> String { "\(prefix)\(owner).\(UUID().uuidString)" }

    static func isStale(_ service: String) -> Bool {
        guard service.hasPrefix(prefix), let pid = pid_t(service.dropFirst(prefix.count).prefix { $0 != "." }), pid > 0 else {
            return false
        }
        return kill(pid, 0) == -1 && errno == ESRCH
    }

    /// Asks for attributes only, so no secret is read.
    static func sweepStale() {
        var query = KeychainStore.baseQuery(service: "", key: "")
        query[kSecAttrService as String] = nil
        query[kSecAttrAccount as String] = nil
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        query[kSecReturnAttributes as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let items = result as? [[String: Any]] else { return }
        for item in items {
            guard let service = item[kSecAttrService as String] as? String, isStale(service),
                  let account = item[kSecAttrAccount as String] as? String else { continue }
            try? KeychainStore(service: service).delete(account)
        }
    }
}

/// Serialized: a Keychain listing taken during another test's write can come back short.
@Suite(.serialized) struct SecretStoreTests {
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
        let store = KeychainStore(service: ThrowawayKeychain.service())
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
        let a = KeychainStore(service: ThrowawayKeychain.service())
        let b = KeychainStore(service: ThrowawayKeychain.service())
        defer { try? a.delete("k"); try? b.delete("k") }
        try a.write("only in a", key: "k")
        #expect(try b.read("k") == nil)
    }

    /// `kSecUseKeychain` needs a `SecKeychainRef`, which the SDK no longer lets us get, so this proves
    /// where the item really lands. `security` reads attributes only, of a throwaway item.
    @Test func keychainItemLandsInTheLoginKeychain() throws {
        let service = ThrowawayKeychain.service()
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

    @Test func staleThrowawayItemsAreClearedAndLiveOnesKept() throws {
        let finished = Process()
        finished.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try finished.run()
        finished.waitUntilExit()
        let stale = KeychainStore(service: ThrowawayKeychain.service(owner: finished.processIdentifier))
        let live = KeychainStore(service: ThrowawayKeychain.service())
        defer { try? stale.delete("k"); try? live.delete("k") }
        try stale.write("v", key: "k")
        try live.write("v", key: "k")

        ThrowawayKeychain.sweepStale()

        #expect(try stale.read("k") == nil)
        #expect(try live.read("k") == "v")
    }

    /// Only names this code made, and only with a dead creator. Older test items and the real
    /// service aren't ours to judge.
    @Test func onlyAThrowawayNameWithADeadOwnerIsStale() {
        #expect(!ThrowawayKeychain.isStale(ThrowawayKeychain.service()))
        #expect(!ThrowawayKeychain.isStale("com.shaikjaleel.mirror"))
        #expect(!ThrowawayKeychain.isStale("com.shaikjaleel.mirror.test.\(UUID().uuidString)"))
        #expect(!ThrowawayKeychain.isStale(ThrowawayKeychain.prefix + "not-a-pid.x"))
    }

    @Test func keychainQueryStaysOffTheDataProtectionKeychain() {
        let q = KeychainStore.baseQuery(service: "s", key: "k")
        #expect(q[kSecUseDataProtectionKeychain as String] as? Bool == false)
        #expect(q[kSecUseAuthenticationContext as String] != nil)
    }

    @Test func keychainItemIsNotSynchronizable() throws {
        let service = ThrowawayKeychain.service()
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
