import Foundation

public enum RemoteSetupError: Error, Equatable, Codable, Sendable {
    case noSignInNeeded, clientIDRequired, clientSecretRequired, noToken
    case clientChangeRefused, vaultLostNeedsRecoveryKit, signInLostNeedsRecoveryKit
    case vaultAlreadyPresent, kitDoesNotMatchDestination, kitDoesNotOpenBackup, couldNotVerifyKit
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
    /// what was lost, so losing either means `restore(_:from:)`, never new values: backups would
    /// otherwise resume under keys no saved Kit holds.
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
        let vault = destination.encrypted ? try secrets.vault(for: destination) : nil
        if destination.recoveryKitConfirmed, destination.encrypted, vault == nil {
            throw RemoteSetupError.vaultLostNeedsRecoveryKit
        }
        let stored = try secrets.signIn(for: destination)
        if destination.recoveryKitConfirmed, destination.encrypted, stored == nil {
            throw RemoteSetupError.signInLostNeedsRecoveryKit
        }
        if let stored, !Self.sameClient(stored, options) { throw RemoteSetupError.clientChangeRefused }

        let signedIn = try await signIn(destination, options: options)
        if destination.encrypted, vault == nil { try secrets.saveVault(.generate(), for: destination) }
        try secrets.saveSignIn(signedIn, for: destination)
    }

    /// Signs in again with the stored client, after a token has expired. Crypt keys are left alone.
    /// The old sign-in stays in place until the new one has succeeded.
    public func reconnect(_ destination: Destination) async throws {
        guard RcloneBackend.type(for: destination.kind) != nil else { throw RemoteSetupError.noSignInNeeded }
        guard var options = try secrets.signIn(for: destination) else { throw RcloneSessionError.notSignedIn }
        options["token"] = nil
        try secrets.saveSignIn(try await signIn(destination, options: options), for: destination)
    }

    /// Puts back keys and client from a pasted Recovery Kit, after a Keychain loss. Signs in with the
    /// kit's client if no sign-in survived. Nothing is stored until the kit is shown to open what's
    /// in the cloud, because a wrong kit would resume backups under keys that can't read them.
    public func restore(_ destination: Destination, from kit: RecoveryKit) async throws {
        guard destination.encrypted, kit.kind == destination.kind, kit.rootPath == MirrorPaths.rootFolderName,
              kit.filenameEncoding == RcloneCrypt.filenameEncoding(for: destination.kind) else {
            throw RemoteSetupError.kitDoesNotMatchDestination
        }
        let keys = VaultSecrets(passphrase: kit.passphrase, salt: kit.salt)
        var present: VaultSecrets?
        do { present = try secrets.vault(for: destination) } catch RcloneSessionError.encryptionKeysMissing { present = nil }
        if let present, present != keys { throw RemoteSetupError.vaultAlreadyPresent }

        var client: [String: String] = [:]
        client["client_id"] = kit.clientID
        client["client_secret"] = kit.clientSecret
        let stored = try secrets.signIn(for: destination)
        if let stored, !Self.sameClient(stored, client) { throw RemoteSetupError.clientChangeRefused }
        var options = client
        if let stored, RcloneBackend.hasUsableToken(stored) { options = stored }
        else { options = try await signIn(destination, options: client) }

        let section = try RcloneBackend.section(for: destination, options: options)
        let dir = try RcloneTool.makePrivateDirectory(in: workDir)
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = dir.appendingPathComponent("rclone.conf")
        try RcloneTool.writePrivateFile(section, to: config)
        let root = "\(RcloneBackend.remoteName(destination)):\(MirrorPaths.rootFolderName)"
        guard try await kitOpens(kit, encryptedRoot: root, context: RcloneContext(configPath: config.path, environment: [:])) else {
            throw RemoteSetupError.kitDoesNotOpenBackup
        }
        try secrets.saveVault(keys, for: destination)
        if options != stored { try secrets.saveSignIn(options, for: destination) }
    }

    /// True when the kit's keys decrypt the root's names, or there's nothing there to strand. Wrong
    /// keys don't make rclone fail: it skips what it can't decrypt, so an empty view is the signal.
    func kitOpens(_ kit: RecoveryKit, encryptedRoot: String, context: RcloneContext) async throws -> Bool {
        guard let raw = try await list(encryptedRoot, context: context), !raw.isEmpty else { return true }
        var environment = context.environment
        environment.merge(try RcloneCrypt.environment(remote: Self.restoreRemote, over: encryptedRoot, passphrase: kit.passphrase,
                                                      salt: kit.salt, filenameEncoding: kit.filenameEncoding, binary: binary)) { $1 }
        let view = RcloneContext(configPath: context.configPath, environment: environment)
        guard let opened = try await list("\(Self.restoreRemote):", context: view) else { return false }
        return !opened.isEmpty
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
