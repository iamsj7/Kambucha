import Foundation

public enum RestoreDrillError: Error, Equatable, Codable, Sendable {
    case invalidPath, couldNotRun, signInExpired
}

/// Proves a Recovery Kit opens the backup. The crypt keys come only from the kit, never from the
/// Keychain, and exist only in memory and the child's environment.
///
/// `true` means the kit decrypted the file and it matched. `false` means the kit or backup failed.
/// A throw means the drill couldn't tell, so it shouldn't raise the failed-drill alarm.
public struct RestoreDrill: Sendable {
    private static let remote = "kambuchadrill"
    private let rclone: any RcloneRunning
    private let binary: URL
    private let helper: any HelperValidating
    private let workDir: URL

    public init(rclone: any RcloneRunning, binary: URL, helper: any HelperValidating) {
        self.init(rclone: rclone, binary: binary, helper: helper, workDir: RcloneSession.interactiveWorkDir)
    }
    init(rclone: any RcloneRunning, binary: URL, helper: any HelperValidating, workDir: URL) {
        self.rclone = rclone; self.binary = binary; self.helper = helper; self.workDir = workDir
    }

    /// - Parameters:
    ///   - encryptedRoot: the folder holding the ciphertext, `RcloneSession.encryptedRoot` for a cloud.
    ///   - context: sign-in only. Its config's section for that remote is compared with the kit's
    ///     client. Any crypt settings in it are not used.
    ///   - relativePath: the file below the crypt root, such as `Sets/Docs/note.txt`.
    ///   - original: the local copy to compare with, a regular file of the same name.
    public func run(kit: RecoveryKit, encryptedRoot: String, context: RcloneContext,
                    relativePath: String, original: URL) async throws -> Bool {
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard let name = parts.last, !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
              name == original.lastPathComponent else { throw RestoreDrillError.invalidPath }
        guard Self.kitDescribes(encryptedRoot, kit: kit, context: context) else { return false }

        var environment = context.environment
        environment.merge(try RcloneCrypt.environment(remote: Self.remote, over: encryptedRoot, passphrase: kit.passphrase,
                                                      salt: kit.salt, filenameEncoding: kit.filenameEncoding, binary: binary, helper: helper)) { $1 }
        let drillContext = RcloneContext(configPath: context.configPath, environment: environment)

        let dir = try RcloneTool.makePrivateDirectory(in: workDir)   // the decrypted copy lives here briefly
        defer { try? FileManager.default.removeItem(at: dir) }

        // Wrong keys and a dropped network can look alike further on, so the cloud is checked without
        // crypt first, and again after any failure. Only a reachable cloud makes a failure the kit's.
        func cloudAnswers() async throws -> Bool {
            try await reachable(encryptedRoot, context: context, log: dir.appendingPathComponent("reach.log"))
        }
        guard try await cloudAnswers() else { return false }

        // cryptcheck first: a cheap verdict with rclone's own outcome classification.
        let list = dir.appendingPathComponent("files.txt")
        try RcloneTool.writePrivateFile(name + "\n", to: list)
        let folder = "\(Self.remote):" + parts.dropLast().joined(separator: "/")
        let check = try await rclone.check(CheckRequest(
            source: original.deletingLastPathComponent(), destination: folder, filterFile: nil, filesFrom: list,
            sizeOnly: false, oneWay: true, cryptCheck: true, context: drillContext,
            logFile: dir.appendingPathComponent("check.log")))
        switch check.outcome {
        case .success where check.summary.differences == 0: break
        case .success, .permanent:
            _ = try await cloudAnswers()
            return false
        case .authExpired: throw RestoreDrillError.signInExpired
        case .transient, .partial, .safetyStop: throw RestoreDrillError.couldNotRun
        }

        // Then the real thing: download, decrypt, compare byte for byte.
        let restored = dir.appendingPathComponent("restored")
        let code = try await RcloneTool.run(["copyto", "\(Self.remote):\(relativePath)", restored.path, "--config", context.configPath],
                                            binary: binary, helper: helper, context: drillContext)
        guard code == 0 else {
            if RcloneLogParser.outcome(exitCode: code) == .transient { throw RestoreDrillError.couldNotRun }
            _ = try await cloudAnswers()
            return false
        }
        guard let wanted = try? Data(contentsOf: original) else { throw RestoreDrillError.couldNotRun }
        return (try? Data(contentsOf: restored)) == wanted
    }

    /// The kit must name this root and the client that's signed in to it, or it wouldn't open the
    /// backup from another Mac, however well its keys decrypt here.
    private static func kitDescribes(_ encryptedRoot: String, kit: RecoveryKit, context: RcloneContext) -> Bool {
        let remote = String(encryptedRoot.prefix { $0 != ":" })
        guard encryptedRoot == "\(remote):\(kit.rootPath)",
              let text = try? String(contentsOfFile: context.configPath, encoding: .utf8),
              let section = RcloneBackend.parse(text, remote: remote) else { return false }
        return section["client_id"] == kit.clientID && section["client_secret"] == kit.clientSecret
    }

    /// True when the root is there, false when the cloud says it isn't. Anything else throws.
    private func reachable(_ root: String, context: RcloneContext, log: URL) async throws -> Bool {
        try? FileManager.default.removeItem(at: log)
        let code = try await RcloneTool.run(["lsf", root, "--max-depth", "1", "--use-json-log", "--log-file", log.path,
                                             "--config", context.configPath], binary: binary, helper: helper, context: context)
        if code == 0 { return true }
        if code == 3 { return false }
        if RcloneLogParser.outcome(exitCode: code, log: (try? Data(contentsOf: log)) ?? Data()) == .authExpired {
            throw RestoreDrillError.signInExpired
        }
        throw RestoreDrillError.couldNotRun
    }
}
