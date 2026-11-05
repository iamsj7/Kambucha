import Foundation

/// Errors never carry a secret, a token or rclone's output, which can echo either.
public enum RcloneSessionError: Error, Equatable, Codable, Sendable {
    case notSignedIn, invalidSignIn, encryptionKeysMissing, encryptionNotSupported, alreadyOpen, unsupportedKind
    case plaintextIntoEncryptedRoot
    case invalidSecret, versionUnavailable
    case obscureFailed(exitCode: Int32)
}

/// One run's access to a destination. Cloud kinds get a private config holding only the sign-in
/// section, and crypt exists only in the returned environment. Call `close()` whatever happens.
public final class RcloneSession {
    /// Where backup runs keep their per-run folders. The agent wipes this between runs.
    public static var defaultWorkDir: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Kambucha", isDirectory: true)
    }

    /// Where in-app operations work: sign-in and the drill. Separate, because they can run while the
    /// agent is wiping `defaultWorkDir`.
    public static var interactiveWorkDir: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Kambucha-Interactive", isDirectory: true)
    }

    private let destination: Destination
    private let secrets: any SecretStoring
    private let binary: URL
    private let helper: any HelperValidating
    private let workDir: URL
    private var runDir: URL?
    private var openedWith: [String: String] = [:]
    private let tokenLock: URL?
    private let tokenLockWait: TimeInterval

    /// `helper` is required, so no caller can forget it. It's `SignedCodeTrust` outside tests.
    public init(destination: Destination, secrets: any SecretStoring, binary: URL, helper: any HelperValidating, workDir: URL,
                tokenLock: URL? = nil, tokenLockWait: TimeInterval = 5) {
        self.tokenLock = tokenLock; self.tokenLockWait = tokenLockWait
        self.destination = destination; self.secrets = secrets; self.binary = binary
        self.helper = helper; self.workDir = workDir
    }

    deinit { if let runDir { try? FileManager.default.removeItem(at: runDir) } }

    /// Proves the rclone this session would run. `open()` does this itself before it reads the
    /// Keychain, which covers scheduled runs, as `AgentService.respond` doesn't run for those.
    public func verifyHelper() throws { try helper.verifyHelper(at: binary) }

    /// The folder holding the ciphertext, for `RestoreDrill`. Nil when there's no encryption.
    public var encryptedRoot: String? {
        guard destination.encrypted, RcloneBackend.type(for: destination.kind) != nil else { return nil }
        return "\(RcloneBackend.remoteName(destination)):\(KambuchaPaths.rootFolderName)"
    }

    /// Refuses, rather than runs without encryption, when an encrypted destination's keys are missing.
    /// An encrypted destination's endpoint is the crypt root, whose `REMOTE` is the cloud's
    /// `Mac Backup`, so paths join as `<endpoint>Sets/<name>`. An unencrypted one is `<remote>:Mac Backup`.
    public func open() throws -> (endpoint: String, context: RcloneContext) {
        guard runDir == nil else { throw RcloneSessionError.alreadyOpen }
        switch destination.kind {
        case .iCloudFolder:
            guard !destination.encrypted else { throw RcloneSessionError.encryptionNotSupported }
            return (KambuchaPaths.backupRoot.path, RcloneContext(configPath: "/dev/null", environment: [:]))
        case .externalDrive:
            // A drive has no sign-in, config or secrets. The caller resolves the live volume's path instead.
            throw RcloneSessionError.unsupportedKind
        case .googleDrive, .oneDrive:
            break
        }
        try verifyHelper()
        var environment: [String: String] = [:]
        var endpoint = "\(RcloneBackend.remoteName(destination)):\(KambuchaPaths.rootFolderName)"
        if destination.encrypted {
            guard let root = encryptedRoot, let encoding = RcloneCrypt.filenameEncoding(for: destination.kind) else {
                throw RcloneSessionError.encryptionNotSupported
            }
            guard let vault = try secrets.vault(for: destination) else { throw RcloneSessionError.encryptionKeysMissing }
            let crypt = RcloneBackend.cryptName(destination)
            environment = try RcloneCrypt.environment(remote: crypt, over: root, passphrase: vault.passphrase,
                                                      salt: vault.salt, filenameEncoding: encoding, binary: binary, helper: helper)
            endpoint = "\(crypt):"
        } else if try secrets.vault(for: destination) != nil {
            // Keys exist, so this root holds ciphertext. Plain files must not land beside it.
            throw RcloneSessionError.plaintextIntoEncryptedRoot
        }
        return (endpoint, RcloneContext(configPath: try writeConfig().path, environment: environment))
    }

    /// The sign-in alone, with no crypt, for a drill that must rely on the kit's keys and nothing else.
    func openSignInOnly() throws -> RcloneContext {
        guard runDir == nil else { throw RcloneSessionError.alreadyOpen }
        try verifyHelper()
        return RcloneContext(configPath: try writeConfig().path, environment: [:])
    }

    /// Runs last in `open`, so nothing there can fail with a config on disk.
    private func writeConfig() throws -> URL {
        guard let options = try secrets.signIn(for: destination) else { throw RcloneSessionError.notSignedIn }
        let section = try RcloneBackend.section(for: destination, options: options)
        let dir = try RcloneTool.makePrivateDirectory(in: workDir)
        let config = dir.appendingPathComponent("rclone.conf")
        do { try RcloneTool.writePrivateFile(section, to: config) } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
        runDir = dir
        openedWith = options
        return config
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
    /// `olderThan` spares recent folders, for `interactiveWorkDir`, where one may be in use.
    public static func wipeLeftovers(in workDir: URL, olderThan age: TimeInterval = 0) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: workDir.path) else { return }
        for name in try fm.contentsOfDirectory(atPath: workDir.path) where name.hasPrefix(RcloneTool.runPrefix) {
            let folder = workDir.appendingPathComponent(name)
            if age > 0, let changed = try fm.attributesOfItem(atPath: folder.path)[.modificationDate] as? Date,
               Date().timeIntervalSince(changed) < age { continue }
            try fm.removeItem(at: folder)
        }
    }

    /// A damaged or missing file changes nothing: the Keychain's token is better than none. Neither
    /// does a stored value that moved on since `open`: a reconnect during the run is newer than this.
    private func saveRefreshedSignIn(from config: URL) throws {
        guard let text = try? String(contentsOf: config, encoding: .utf8),
              let found = RcloneBackend.parse(text, remote: RcloneBackend.remoteName(destination)),
              RcloneBackend.hasUsableToken(found), found != openedWith else { return }
        // Compare and write as one step. If another writer won't let go, the stored token still works,
        // so this refresh is what's given up rather than writing over whatever they're saving.
        var lock: RunLock?
        if let tokenLock {
            let held = RunLock(url: tokenLock)
            guard try held.acquire(timeout: tokenLockWait) else { return }
            lock = held
        }
        defer { lock?.release() }
        guard try secrets.signIn(for: destination) == openedWith else { return }
        try secrets.saveSignIn(found, for: destination)
    }
}

/// How sign-in remotes are named and written. Names come from the destination's ID, because display
/// names can hold spaces and colons and these become environment variable names.
enum RcloneBackend {
    /// Nil for kinds with no remote. Exhaustive, so a new kind has to decide here.
    static func type(for kind: DestinationKind) -> String? {
        switch kind {
        case .iCloudFolder, .externalDrive: nil
        case .googleDrive: "drive"
        case .oneDrive: "onedrive"
        }
    }

    private static func idHex(_ d: Destination) -> String {
        d.id.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }
    static func remoteName(_ d: Destination) -> String { "kambuchabase\(idHex(d))" }
    static func cryptName(_ d: Destination) -> String { "kambuchacrypt\(idHex(d))" }

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

/// The one definition of Kambucha's crypt settings. The session and the drill must never differ.
enum RcloneCrypt {
    static let filenameEncryption = "standard"
    static let directoryNameEncryption = "true"

    /// Nil for kinds that are never encrypted. Spec section 8a.
    static func filenameEncoding(for kind: DestinationKind) -> String? {
        switch kind {
        case .iCloudFolder, .externalDrive: nil
        case .googleDrive: "base32"
        case .oneDrive: "base32768"   // OneDrive limits paths to 400 characters
        }
    }

    static func environment(remote: String, over target: String, passphrase: String, salt: String,
                            filenameEncoding: String, binary: URL, helper: any HelperValidating) throws -> [String: String] {
        let prefix = "RCLONE_CONFIG_\(remote.uppercased())_"
        return [prefix + "TYPE": "crypt",
                prefix + "REMOTE": target,
                prefix + "FILENAME_ENCRYPTION": filenameEncryption,
                prefix + "DIRECTORY_NAME_ENCRYPTION": directoryNameEncryption,
                prefix + "FILENAME_ENCODING": filenameEncoding,
                prefix + "PASSWORD": try RcloneTool.obscure(passphrase, binary: binary, helper: helper),
                prefix + "PASSWORD2": try RcloneTool.obscure(salt, binary: binary, helper: helper)]
    }
}

/// Short-lived rclone commands and private files. Output is never put into an error.
enum RcloneTool {
    static let runPrefix = "kambucha-run-"
    /// Pipes hold at least this much, so input can be written before the child exists.
    static let maxStdin = 8192
    /// Seconds between SIGTERM and SIGKILL when a child is cancelled.
    static let killGrace: TimeInterval = 5

    /// Through stdin, so the value is never in argv. `rclone obscure -` reads one line and turns
    /// empty input into a literal hyphen, so anything but one non-empty line is refused rather than
    /// quietly becoming a different key.
    static func obscure(_ value: String, binary: URL, helper: any HelperValidating) throws -> String {
        guard !value.isEmpty, !value.contains(where: \.isNewline), value.utf8.count < maxStdin else {
            throw RcloneSessionError.invalidSecret
        }
        try helper.verifyHelper(at: binary)
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
        process.standardInput = try input(stdin)
        try process.run()
        let data = (try? out.fileHandleForReading.readToEnd()) ?? Data()
        process.waitUntilExit()
        return (process.terminationStatus, data)
    }

    /// Filled before launch: a child that exits early can't raise SIGPIPE here.
    private static func input(_ data: Data?) throws -> Any {
        guard let data else { return FileHandle.nullDevice }
        let pipe = Pipe()
        try pipe.fileHandleForWriting.write(contentsOf: data)
        try pipe.fileHandleForWriting.close()
        return pipe
    }

    /// Runs rclone with all output discarded, so nothing it prints can reach a log or an error.
    static func run(_ args: [String], binary: URL, helper: any HelperValidating, context: RcloneContext) async throws -> Int32 {
        try await execute(args, binary: binary, helper: helper, context: context, capture: false).code
    }

    /// Runs a child with the minimal environment, and stderr discarded. Input must fit `maxStdin`.
    /// Cancelling the task stops the child. `helper` is nil only for a child that isn't rclone.
    static func execute(_ args: [String], binary: URL, helper: (any HelperValidating)?, context: RcloneContext, stdin: Data? = nil,
                        capture: Bool, killGrace: TimeInterval = killGrace) async throws -> (code: Int32, output: Data) {
        try helper?.verifyHelper(at: binary)
        let process = Process()
        process.executableURL = binary
        process.arguments = args
        process.environment = RcloneRunner.childEnvironment(context)
        process.standardInput = try input(stdin)
        process.standardError = FileHandle.nullDevice
        let out = capture ? Pipe() : nil
        process.standardOutput = out ?? FileHandle.nullDevice
        let reader = Task.detached { () -> Data in (try? out?.fileHandleForReading.readToEnd()) ?? Data() }
        let child = CancellableChild(process, killGrace: killGrace)
        let code: Int32
        do {
            code = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int32, any Error>) in
                    process.terminationHandler = { cont.resume(returning: $0.terminationStatus) }
                    do { try child.start() } catch {
                        process.terminationHandler = nil
                        try? out?.fileHandleForWriting.close()   // lets the reader finish
                        cont.resume(throwing: error)
                    }
                }
            } onCancel: { child.cancel() }
        } catch {
            _ = await reader.value
            throw error
        }
        let output = await reader.value
        if child.wasCancelled { throw CancellationError() }
        return (code, output)
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
    private let killGrace: TimeInterval
    private var cancelled = false
    private var started = false
    init(_ process: Process, killGrace: TimeInterval) { self.process = process; self.killGrace = killGrace }

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
        DispatchQueue.global().asyncAfter(deadline: .now() + killGrace) { [self] in
            if lock.withLock({ process.isRunning }) { kill(pid, SIGKILL) }
        }
    }
}
