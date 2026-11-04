import Foundation

public enum RestoreDrillError: Error, Equatable {
    case invalidPath, couldNotRun, signInExpired
}

/// Proves a Recovery Kit opens the backup. The crypt keys come only from the kit, never from the
/// Keychain, and exist only in memory and the child's environment.
///
/// `true` means the kit decrypted the file and it matched. `false` means the kit or backup failed.
/// A throw means the drill couldn't tell, so it shouldn't raise the failed-drill alarm.
public struct RestoreDrill: Sendable {
    private static let remote = "mirrordrill"
    private let rclone: any RcloneRunning
    private let binary: URL
    private let workDir: URL

    public init(rclone: any RcloneRunning, binary: URL) {
        self.init(rclone: rclone, binary: binary, workDir: RcloneSession.defaultWorkDir)
    }
    init(rclone: any RcloneRunning, binary: URL, workDir: URL) {
        self.rclone = rclone; self.binary = binary; self.workDir = workDir
    }

    /// - Parameters:
    ///   - encryptedRoot: the folder holding the ciphertext, `RcloneSession.encryptedRoot` for a cloud.
    ///   - context: sign-in only. Any crypt settings in it are not used.
    ///   - relativePath: the file below the kit's root path, such as `Sets/Docs/note.txt`.
    ///   - original: the local copy to compare with, a regular file of the same name.
    public func run(kit: RecoveryKit, encryptedRoot: String, context: RcloneContext,
                    relativePath: String, original: URL) async throws -> Bool {
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard let name = parts.last, !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
              name == original.lastPathComponent else { throw RestoreDrillError.invalidPath }

        var environment = context.environment
        environment.merge(try RcloneCrypt.environment(remote: Self.remote, over: encryptedRoot, passphrase: kit.passphrase,
                                                      salt: kit.salt, filenameEncoding: kit.filenameEncoding, binary: binary)) { $1 }
        let drillContext = RcloneContext(configPath: context.configPath, environment: environment)
        let root = "\(Self.remote):\(kit.rootPath)"

        let dir = try RcloneTool.makePrivateDirectory(in: workDir)   // the decrypted copy lives here briefly
        defer { try? FileManager.default.removeItem(at: dir) }

        // cryptcheck first: its outcome separates a wrong kit from a failure to reach the cloud.
        let list = dir.appendingPathComponent("files.txt")
        try RcloneTool.writePrivateFile(name + "\n", to: list)
        let folder = ([root] + parts.dropLast()).joined(separator: "/")
        let check = try await rclone.check(CheckRequest(
            source: original.deletingLastPathComponent(), destination: folder, filterFile: nil, filesFrom: list,
            sizeOnly: false, oneWay: true, cryptCheck: true, context: drillContext,
            logFile: dir.appendingPathComponent("check.log")))
        switch check.outcome {
        case .success: if check.summary.differences > 0 { return false }
        case .authExpired: throw RestoreDrillError.signInExpired
        case .transient, .partial, .safetyStop: throw RestoreDrillError.couldNotRun
        case .permanent: return false
        }

        // Then the real thing: download, decrypt, compare byte for byte.
        let restored = dir.appendingPathComponent("restored")
        let code = try await RcloneTool.run(["copyto", "\(root)/\(relativePath)", restored.path, "--config", context.configPath],
                                            binary: binary, context: drillContext)
        guard code == 0 else {
            if RcloneLogParser.outcome(exitCode: code) == .transient { throw RestoreDrillError.couldNotRun }
            return false
        }
        guard let wanted = try? Data(contentsOf: original) else { throw RestoreDrillError.couldNotRun }
        return (try? Data(contentsOf: restored)) == wanted
    }
}
