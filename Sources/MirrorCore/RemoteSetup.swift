import Foundation

public enum RemoteSetupError: Error, Equatable {
    case noSignInNeeded, clientIDRequired, noToken
    case signInFailed(exitCode: Int32)
}

/// One-time browser sign-in. rclone runs `config reconnect` on a private config, so the client
/// secret reaches it through that file and never through argv.
public struct RemoteSetup: Sendable {
    private let binary: URL
    private let secrets: any SecretStoring
    private let workDir: URL

    public init(binary: URL, secrets: any SecretStoring) {
        self.binary = binary; self.secrets = secrets; workDir = RcloneSession.defaultWorkDir
    }

    /// First sign-in. Also creates the destination's crypt keys if it's encrypted and has none:
    /// existing keys are never replaced, because that would strand every backup made with them.
    public func connect(_ destination: Destination, clientID: String?, clientSecret: String?) async throws {
        guard RcloneBackend.type(for: destination.kind) != nil else { throw RemoteSetupError.noSignInNeeded }
        var options: [String: String] = [:]
        options["client_id"] = Self.cleaned(clientID)
        options["client_secret"] = Self.cleaned(clientSecret)
        // rclone's shared Google client is being retired, and drive.file ties files to one client.
        if destination.kind == .googleDrive, options["client_id"] == nil { throw RemoteSetupError.clientIDRequired }

        let signedIn = try await signIn(destination, options: options)
        if destination.encrypted, try secrets.vault(for: destination) == nil {
            try secrets.saveVault(.generate(), for: destination)
        }
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

    private static func cleaned(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == true ? nil : trimmed
    }
}
