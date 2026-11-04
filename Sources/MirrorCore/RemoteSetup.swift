import Foundation

public enum RemoteSetupError: Error, Equatable, Codable, Sendable {
    case noSignInNeeded, clientIDRequired, clientSecretRequired, noToken
    case clientChangeRefused, vaultLostNeedsRecoveryKit, signInLostNeedsRecoveryKit
    case vaultAlreadyPresent, kitDoesNotMatchDestination, kitDoesNotOpenBackup, couldNotVerifyKit
    /// Nothing visible to test the kit against. Ask the owner, then retry with `acceptUnproven`.
    case kitUnproven
    case signInFailed(exitCode: Int32)
}

/// One-time browser sign-in. rclone runs `config reconnect` on a private config, so the client
/// secret reaches it through that file and never through argv. Runs inside `MirrorAgent`, which owns
/// the Keychain. Mirror.app reaches it through `AgentClient`.
public struct RemoteSetup: Sendable {
    private static let restoreRemote = "mirrorrestore"
    private let binary: URL
    private let secrets: any SecretStoring
    private let workDir: URL

    public init(binary: URL, secrets: any SecretStoring) {
        self.init(binary: binary, secrets: secrets, workDir: RcloneSession.interactiveWorkDir)
    }
    init(binary: URL, secrets: any SecretStoring, workDir: URL) {
        self.binary = binary; self.secrets = secrets; self.workDir = workDir
    }

    /// First sign-in. Also creates the crypt keys of a new encrypted destination. Existing keys are
    /// never replaced, and neither is the client. Once the Kit is confirmed it's the only record of
    /// what was lost, so losing either means `restore(_:from:acceptUnproven:)`, never new values:
    /// backups would otherwise resume under keys no saved Kit holds.
    public func connect(_ destination: Destination, clientID: String?, clientSecret: String?) async throws {
        guard RcloneBackend.type(for: destination.kind) != nil else { throw RemoteSetupError.noSignInNeeded }
        var options: [String: String] = [:]
        options["client_id"] = Self.cleaned(clientID)
        options["client_secret"] = Self.cleaned(clientSecret)
        // rclone's shared Google client is being retired, and drive.file ties files to one client.
        if destination.kind == .googleDrive {
            guard options["client_id"] != nil else { throw RemoteSetupError.clientIDRequired }
            guard options["client_secret"] != nil else { throw RemoteSetupError.clientSecretRequired }
        }

        // All before the browser opens, so a refusal costs the owner nothing.
        let stored = try storedSignIn(destination)
        let vaultBefore = destination.encrypted ? try vaultState(destination) : .absent
        if destination.encrypted {
            // Keys are stored before the sign-in, so a sign-in without them is a loss whatever the flag says.
            let confirmed = destination.recoveryKitConfirmed
            if vaultBefore == .damaged || (vaultBefore == .absent && (confirmed || stored != .none)) {
                throw RemoteSetupError.vaultLostNeedsRecoveryKit
            }
            if stored == .damaged || (confirmed && stored == .none) { throw RemoteSetupError.signInLostNeedsRecoveryKit }
        }
        if case .usable(let existing) = stored, !Self.sameClient(existing, options) {
            throw RemoteSetupError.clientChangeRefused
        }

        let signedIn = try await signIn(destination, options: options)
        if destination.encrypted {
            // Minutes may have passed in the browser, so the earlier read can't decide this.
            switch try vaultState(destination) {
            case .present: break
            case .damaged: throw RemoteSetupError.vaultLostNeedsRecoveryKit
            case .absent:
                guard vaultBefore == .absent else { throw RemoteSetupError.vaultLostNeedsRecoveryKit }
                try secrets.saveVault(.generate(), for: destination)
            }
        }
        try secrets.saveSignIn(signedIn, for: destination)
    }

    /// Signs in again with the stored client, after a token has expired. Crypt keys are left alone.
    /// The old sign-in stays in place until the new one has succeeded.
    public func reconnect(_ destination: Destination) async throws {
        guard RcloneBackend.type(for: destination.kind) != nil else { throw RemoteSetupError.noSignInNeeded }
        var options: [String: String]
        switch try storedSignIn(destination) {
        case .usable(let existing): options = existing
        case .none: throw RcloneSessionError.notSignedIn
        case .damaged:
            throw destination.encrypted ? RemoteSetupError.signInLostNeedsRecoveryKit : RcloneSessionError.notSignedIn
        }
        if destination.encrypted {
            guard case .present = try vaultState(destination) else { throw RemoteSetupError.vaultLostNeedsRecoveryKit }
        }
        options["token"] = nil
        try secrets.saveSignIn(try await signIn(destination, options: options), for: destination)
    }

    /// Puts back keys and client from a pasted Recovery Kit, after a Keychain loss. Signs in with the
    /// kit's client if no usable sign-in survived. Nothing is stored until the kit is shown to open
    /// what's in the cloud, because a wrong kit would resume backups under keys that can't read them.
    ///
    /// Seeing nothing proves nothing: under `drive.file` a wrong client or account sees an empty
    /// root. So that passes only for a surviving sign-in with the kit's client on an unconfirmed
    /// destination. Otherwise it throws `kitUnproven`, and `acceptUnproven` is the owner's answer.
    public func restore(_ destination: Destination, from kit: RecoveryKit, acceptUnproven: Bool = false) async throws {
        guard destination.encrypted, kit.kind == destination.kind, kit.rootPath == MirrorPaths.rootFolderName,
              kit.filenameEncoding == RcloneCrypt.filenameEncoding(for: destination.kind) else {
            throw RemoteSetupError.kitDoesNotMatchDestination
        }
        let keys = VaultSecrets(passphrase: kit.passphrase, salt: kit.salt)
        try refuseOtherKeys(keys, destination)

        var client: [String: String] = [:]
        client["client_id"] = kit.clientID
        client["client_secret"] = kit.clientSecret
        var surviving: [String: String]?
        if case .usable(let existing) = try storedSignIn(destination) {
            guard Self.sameClient(existing, client) else { throw RemoteSetupError.clientChangeRefused }
            if RcloneBackend.hasUsableToken(existing) { surviving = existing }
        }
        var options = client
        if let surviving { options = surviving } else { options = try await signIn(destination, options: client) }

        let section = try RcloneBackend.section(for: destination, options: options)
        let dir = try RcloneTool.makePrivateDirectory(in: workDir)
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = dir.appendingPathComponent("rclone.conf")
        try RcloneTool.writePrivateFile(section, to: config)
        let remote = RcloneBackend.remoteName(destination)
        let root = "\(remote):\(MirrorPaths.rootFolderName)"
        let context = RcloneContext(configPath: config.path, environment: [:])

        // rclone may have refreshed the token while listing. OneDrive rotates refresh tokens, so a
        // surviving sign-in keeps the new one whatever the verdict.
        func latest() -> [String: String] {
            guard let text = try? String(contentsOf: config, encoding: .utf8),
                  let found = RcloneBackend.parse(text, remote: remote), RcloneBackend.hasUsableToken(found) else { return options }
            return found
        }
        func keepRefresh() throws {
            let now = latest()
            if let surviving, now != surviving, try secrets.signIn(for: destination) == surviving {
                try secrets.saveSignIn(now, for: destination)
            }
        }
        let proof: KitProof
        do { proof = try await kitOpens(kit, encryptedRoot: root, context: context) } catch {
            try? keepRefresh()
            throw error
        }
        try keepRefresh()

        switch proof {
        case .opens: break
        case .doesNotOpen: throw RemoteSetupError.kitDoesNotOpenBackup
        case .nothingThere:
            let shortcut = surviving != nil && !destination.recoveryKitConfirmed
            guard shortcut || acceptUnproven else { throw RemoteSetupError.kitUnproven }
        }
        try refuseOtherKeys(keys, destination)   // the browser and the proof took time
        try secrets.saveVault(keys, for: destination)
        if surviving == nil { try secrets.saveSignIn(latest(), for: destination) }
    }

    enum KitProof: Equatable { case opens, doesNotOpen, nothingThere }

    /// Wrong keys don't make rclone fail: it skips what it can't decrypt, so an empty view is the
    /// signal, and only when the raw listing shows there's something to decrypt.
    func kitOpens(_ kit: RecoveryKit, encryptedRoot: String, context: RcloneContext) async throws -> KitProof {
        guard let raw = try await list(encryptedRoot, context: context), !raw.isEmpty else { return .nothingThere }
        var environment = context.environment
        environment.merge(try RcloneCrypt.environment(remote: Self.restoreRemote, over: encryptedRoot, passphrase: kit.passphrase,
                                                      salt: kit.salt, filenameEncoding: kit.filenameEncoding, binary: binary)) { $1 }
        let view = RcloneContext(configPath: context.configPath, environment: environment)
        guard let opened = try await list("\(Self.restoreRemote):", context: view), !opened.isEmpty else { return .doesNotOpen }
        return .opens
    }

    private enum VaultState: Equatable { case present(VaultSecrets), absent, damaged }
    private enum SignInState: Equatable { case usable([String: String]), none, damaged }

    private func vaultState(_ destination: Destination) throws -> VaultState {
        do { return try secrets.vault(for: destination).map(VaultState.present) ?? .absent }
        catch RcloneSessionError.encryptionKeysMissing { return .damaged }
    }

    /// Damaged covers an item that won't decode and one that couldn't be written to a config.
    private func storedSignIn(_ destination: Destination) throws -> SignInState {
        do {
            guard let options = try secrets.signIn(for: destination) else { return .none }
            _ = try RcloneBackend.section(for: destination, options: options)
            return .usable(options)
        } catch RcloneSessionError.invalidSignIn { return .damaged }
    }

    private func refuseOtherKeys(_ keys: VaultSecrets, _ destination: Destination) throws {
        if case .present(let present) = try vaultState(destination), present != keys {
            throw RemoteSetupError.vaultAlreadyPresent
        }
    }

    /// Nil when the folder doesn't exist. Any other failure leaves the kit unproven.
    private func list(_ path: String, context: RcloneContext) async throws -> Data? {
        let (code, output) = try await RcloneTool.execute(["lsf", path, "--max-depth", "1", "--config", context.configPath],
                                                          binary: binary, context: context, capture: true)
        if code == 3 { return nil }
        guard code == 0 else { throw RemoteSetupError.couldNotVerifyKit }
        return output
    }

    private func signIn(_ destination: Destination, options: [String: String]) async throws -> [String: String] {
        let section = try RcloneBackend.section(for: destination, options: options)
        let dir = try RcloneTool.makePrivateDirectory(in: workDir)
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = dir.appendingPathComponent("rclone.conf")
        try RcloneTool.writePrivateFile(section, to: config)

        let remote = RcloneBackend.remoteName(destination)
        let code = try await RcloneTool.run(["config", "reconnect", "\(remote):", "--auto-confirm", "--config", config.path],
                                            binary: binary, context: RcloneContext(configPath: config.path, environment: [:]))
        guard code == 0 else { throw RemoteSetupError.signInFailed(exitCode: code) }
        guard let text = try? String(contentsOf: config, encoding: .utf8),
              let result = RcloneBackend.parse(text, remote: remote),
              RcloneBackend.hasUsableToken(result) else { throw RemoteSetupError.noToken }
        return result
    }

    private static func sameClient(_ a: [String: String], _ b: [String: String]) -> Bool {
        a["client_id"] == b["client_id"] && a["client_secret"] == b["client_secret"]
    }

    private static func cleaned(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == true ? nil : trimmed
    }
}
