import Foundation

/// Errors never carry a secret, a token or rclone's output, which can echo either.
public enum RcloneSessionError: Error, Equatable {
    case notSignedIn, invalidSignIn, encryptionKeysMissing, encryptionNotSupported, alreadyOpen
    case invalidSecret, versionUnavailable
    case obscureFailed(exitCode: Int32)
}

/// One run's access to a destination. Cloud kinds get a private config holding only the sign-in
/// section, and crypt exists only in the returned environment. Call `close()` whatever happens.
public final class RcloneSession {
    /// Where per-run folders live unless a caller chooses otherwise.
    public static var defaultWorkDir: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Mirror", isDirectory: true)
    }

    private let destination: Destination
    private let secrets: any SecretStoring
    private let binary: URL
    private let workDir: URL
    private var runDir: URL?
    private var openedWith: [String: String] = [:]

    public init(destination: Destination, secrets: any SecretStoring, binary: URL, workDir: URL) {
        self.destination = destination; self.secrets = secrets; self.binary = binary; self.workDir = workDir
    }

    deinit { if let runDir { try? FileManager.default.removeItem(at: runDir) } }

    /// The folder holding the ciphertext, for `RestoreDrill`. Nil when there's no encryption.
    public var encryptedRoot: String? {
        guard destination.encrypted, RcloneBackend.type(for: destination.kind) != nil else { return nil }
        return "\(RcloneBackend.remoteName(destination)):\(MirrorPaths.rootFolderName)"
    }

    /// Refuses, rather than runs without encryption, when an encrypted destination's keys are missing.
    public func open() throws -> (endpoint: String, context: RcloneContext) {
        guard runDir == nil else { throw RcloneSessionError.alreadyOpen }
        switch destination.kind {
        case .iCloudFolder:
            guard !destination.encrypted else { throw RcloneSessionError.encryptionNotSupported }
            return (MirrorPaths.backupRoot.path, RcloneContext(configPath: "/dev/null", environment: [:]))
        case .googleDrive, .oneDrive:
            break
        }
        guard let options = try secrets.signIn(for: destination) else { throw RcloneSessionError.notSignedIn }
        let base = RcloneBackend.remoteName(destination)
        let section = try RcloneBackend.section(for: destination, options: options)

        var environment: [String: String] = [:]
        var outer = base
        if destination.encrypted {
            guard let root = encryptedRoot, let encoding = RcloneCrypt.filenameEncoding(for: destination.kind) else {
                throw RcloneSessionError.encryptionNotSupported
            }
            guard let vault = try secrets.vault(for: destination) else { throw RcloneSessionError.encryptionKeysMissing }
            outer = RcloneBackend.cryptName(destination)
            environment = try RcloneCrypt.environment(remote: outer, over: root, passphrase: vault.passphrase,
                                                      salt: vault.salt, filenameEncoding: encoding, binary: binary)
        }

        // Written last, so nothing above can fail with a config on disk.
        let dir = try RcloneTool.makePrivateDirectory(in: workDir)
        let config = dir.appendingPathComponent("rclone.conf")
        do { try RcloneTool.writePrivateFile(section, to: config) } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
        runDir = dir
        openedWith = options
        return ("\(outer):\(MirrorPaths.rootFolderName)", RcloneContext(configPath: config.path, environment: environment))
    }

    /// Saves any token rclone refreshed, then deletes the config. The file goes even if saving fails.
    public func close() throws {
        guard let dir = runDir else { return }
        var saveFailure: (any Error)?
        do { try saveRefreshedSignIn(from: dir.appendingPathComponent("rclone.conf")) } catch { saveFailure = error }
        do {
            if FileManager.default.fileExists(atPath: dir.path) { try FileManager.default.removeItem(at: dir) }
            runDir = nil
        } catch {
            throw saveFailure ?? error
        }
        if let saveFailure { throw saveFailure }
    }

    /// Clears per-run folders left by a crash. Run it before a run starts, never during one.
    public static func wipeLeftovers(in workDir: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: workDir.path) else { return }
        for name in try fm.contentsOfDirectory(atPath: workDir.path) where name.hasPrefix(RcloneTool.runPrefix) {
            try fm.removeItem(at: workDir.appendingPathComponent(name))
        }
    }

    /// A damaged or missing file changes nothing: the Keychain's token is better than none.
    private func saveRefreshedSignIn(from config: URL) throws {
        guard let text = try? String(contentsOf: config, encoding: .utf8),
              let found = RcloneBackend.parse(text, remote: RcloneBackend.remoteName(destination)),
              RcloneBackend.hasUsableToken(found), found != openedWith else { return }
        try secrets.saveSignIn(found, for: destination)
    }
}

/// How sign-in remotes are named and written. Names come from the destination's ID, because display
/// names can hold spaces and colons and these become environment variable names.
enum RcloneBackend {
    /// Nil for kinds with no remote. Exhaustive, so a new kind has to decide here.
    static func type(for kind: DestinationKind) -> String? {
        switch kind {
        case .iCloudFolder: nil
        case .googleDrive: "drive"
        case .oneDrive: "onedrive"
        }
    }

    private static func idHex(_ d: Destination) -> String {
        d.id.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }
    static func remoteName(_ d: Destination) -> String { "mirrorbase\(idHex(d))" }
    static func cryptName(_ d: Destination) -> String { "mirrorcrypt\(idHex(d))" }

    /// `type` and `scope` always come from the kind, so a stored value can't widen access.
    static func section(for d: Destination, options: [String: String]) throws -> String {
        guard let type = type(for: d.kind) else { throw RcloneSessionError.invalidSignIn }
        var all = options
        all["type"] = type
        all["scope"] = d.kind == .googleDrive ? "drive.file" : nil
        var text = "[\(remoteName(d))]\n"
        for (key, value) in all.sorted(by: { $0.key < $1.key }) {
            // A line break would start a new key or section in the file.
            guard !value.contains(where: \.isNewline), !value.contains("\0"), !key.isEmpty,
                  key.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) else {
                throw RcloneSessionError.invalidSignIn
            }
            text += "\(key) = \(value)\n"
        }
        return text
    }

    /// The remote's options as rclone left them, without the two that `section` supplies.
    static func parse(_ text: String, remote: String) -> [String: String]? {
        var options: [String: String]?
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                if options != nil { break }
                if line == "[\(remote)]" { options = [:] }
            } else if options != nil, let equals = line.firstIndex(of: "=") {
                let key = line[..<equals].trimmingCharacters(in: .whitespaces)
                let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
                if key != "type", key != "scope", !value.isEmpty { options?[key] = value }
            }
        }
        return options
    }

    static func hasUsableToken(_ options: [String: String]) -> Bool {
        guard let token = options["token"],
              let object = try? JSONSerialization.jsonObject(with: Data(token.utf8)) as? [String: Any] else { return false }
        return object["access_token"] is String
    }
}

/// The one definition of Mirror's crypt settings. The session and the drill must never differ.
enum RcloneCrypt {
    static let filenameEncryption = "standard"
    static let directoryNameEncryption = "true"

    /// Nil for kinds that are never encrypted. Spec section 8a.
    static func filenameEncoding(for kind: DestinationKind) -> String? {
        switch kind {
        case .iCloudFolder: nil
        case .googleDrive: "base32"
        case .oneDrive: "base32768"   // OneDrive limits paths to 400 characters
        }
    }

    static func environment(remote: String, over target: String, passphrase: String, salt: String,
                            filenameEncoding: String, binary: URL) throws -> [String: String] {
        let prefix = "RCLONE_CONFIG_\(remote.uppercased())_"
        return [prefix + "TYPE": "crypt",
                prefix + "REMOTE": target,
                prefix + "FILENAME_ENCRYPTION": filenameEncryption,
                prefix + "DIRECTORY_NAME_ENCRYPTION": directoryNameEncryption,
                prefix + "FILENAME_ENCODING": filenameEncoding,
                prefix + "PASSWORD": try RcloneTool.obscure(passphrase, binary: binary),
                prefix + "PASSWORD2": try RcloneTool.obscure(salt, binary: binary)]
    }
}

/// Short-lived rclone commands and private files. Output is never put into an error.
enum RcloneTool {
    static let runPrefix = "mirror-run-"
    /// Pipes hold at least this much, so input can be written before the child exists.
    private static let maxStdin = 8192

    /// Through stdin, so the value is never in argv. `rclone obscure -` reads one line and turns
    /// empty input into a literal hyphen, so anything but one non-empty line is refused rather than
    /// quietly becoming a different key.
    static func obscure(_ value: String, binary: URL) throws -> String {
        guard !value.isEmpty, !value.contains(where: \.isNewline), value.utf8.count < maxStdin else {
            throw RcloneSessionError.invalidSecret
        }
        let (code, out) = try capture(["obscure", "-", "--config", "/dev/null"], binary: binary, stdin: Data((value + "\n").utf8))
        let obscured = String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard code == 0, !obscured.isEmpty, !obscured.contains(where: \.isNewline) else {
            throw RcloneSessionError.obscureFailed(exitCode: code)
        }
        return obscured
    }

    /// For example `v1.75.2`.
    static func version(binary: URL) throws -> String {
        let (code, out) = try capture(["version"], binary: binary, stdin: nil)
        let words = String(decoding: out, as: UTF8.self).split(whereSeparator: \.isWhitespace)
        guard code == 0, words.count >= 2, words[0] == "rclone" else { throw RcloneSessionError.versionUnavailable }
        return String(words[1])
    }

    private static func capture(_ args: [String], binary: URL, stdin: Data?) throws -> (Int32, Data) {
        let process = Process()
        process.executableURL = binary
        process.arguments = args
        process.environment = RcloneRunner.childEnvironment(RcloneContext(configPath: "/dev/null", environment: [:]))
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        if let stdin {
            // Filled before launch: a child that exits early can't raise SIGPIPE here.
            let input = Pipe()
            try input.fileHandleForWriting.write(contentsOf: stdin)
            try input.fileHandleForWriting.close()
            process.standardInput = input
        } else {
            process.standardInput = FileHandle.nullDevice
        }
        try process.run()
        let data = (try? out.fileHandleForReading.readToEnd()) ?? Data()
        process.waitUntilExit()
        return (process.terminationStatus, data)
    }

    /// Runs rclone with all output discarded, so nothing it prints can reach a log or an error.
    /// Cancelling the task stops the child.
    static func run(_ args: [String], binary: URL, context: RcloneContext) async throws -> Int32 {
        let process = Process()
        process.executableURL = binary
        process.arguments = args
        process.environment = RcloneRunner.childEnvironment(context)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let child = CancellableChild(process)
        let code = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int32, any Error>) in
                process.terminationHandler = { cont.resume(returning: $0.terminationStatus) }
                do { try child.start() } catch {
                    process.terminationHandler = nil
                    cont.resume(throwing: error)
                }
            }
        } onCancel: { child.cancel() }
        if child.wasCancelled { throw CancellationError() }
        return code
    }

    /// A new 0700 folder inside `parent`, which is created private if it doesn't exist.
    static func makePrivateDirectory(in parent: URL) throws -> URL {
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let dir = parent.appendingPathComponent(runPrefix + UUID().uuidString, isDirectory: true)
        guard mkdir(dir.path, 0o700) == 0 else { throw CocoaError(.fileWriteUnknown) }
        return dir
    }

    /// Created 0600 from the first byte, and refuses to follow or reuse anything already there.
    static func writePrivateFile(_ text: String, to url: URL) throws {
        let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }
}

/// Lock-protected start and cancel for one child, so a cancelled task never starts it.
private final class CancellableChild: @unchecked Sendable {
    private let lock = NSLock()
    private let process: Process
    private var cancelled = false
    private var started = false
    init(_ process: Process) { self.process = process }

    var wasCancelled: Bool { lock.withLock { cancelled } }

    func start() throws {
        try lock.withLock {
            if cancelled { throw CancellationError() }
            try process.run()
            started = true
        }
    }

    func cancel() {
        let pid: pid_t? = lock.withLock {
            cancelled = true
            guard started, process.isRunning else { return nil }
            process.terminate()
            return process.processIdentifier
        }
        guard let pid else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [self] in
            if lock.withLock({ process.isRunning }) { kill(pid, SIGKILL) }
        }
    }
}
