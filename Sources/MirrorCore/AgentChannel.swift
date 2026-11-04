import Foundation

/// The app's only route to secrets. `MirrorAgent` owns the Keychain, and Mirror.app spawns it with a
/// subcommand as its one argument. Everything else, secrets included, goes as JSON over its stdin and
/// comes back as JSON over its stdout: never arguments, environment or files.
public enum AgentRequest: Codable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    case connect(destination: Destination, clientID: String?, clientSecret: String?)
    case reconnect(destination: Destination)
    case recoveryKit(destination: Destination)
    case restoreFromKit(destination: Destination, kitText: String, acceptUnproven: Bool)
    case drill(destination: Destination, kitText: String, relativePath: String, original: URL)

    public static let subcommands: Set = ["connect", "reconnect", "kit", "restore-kit", "drill"]

    public var subcommand: String {
        switch self {
        case .connect: "connect"
        case .reconnect: "reconnect"
        case .recoveryKit: "kit"
        case .restoreFromKit: "restore-kit"
        case .drill: "drill"
        }
    }

    var destination: Destination {
        switch self {
        case .connect(let d, _, _), .reconnect(let d), .recoveryKit(let d), .restoreFromKit(let d, _, _), .drill(let d, _, _, _): d
        }
    }

    /// Changes the Keychain, so overlapping commands must not interleave. A drill counts, because
    /// closing its session can save a refreshed token.
    var writesSecrets: Bool {
        switch self {
        case .recoveryKit: false
        case .connect, .reconnect, .restoreFromKit, .drill: true
        }
    }

    public var description: String { "AgentRequest(\(subcommand), redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// Typed, so the app sees the same errors the agent did. None of them carries a secret.
public enum AgentFailure: Error, Equatable, Codable, Sendable {
    case session(RcloneSessionError), setup(RemoteSetupError), kit(RecoveryKitError)
    case drill(RestoreDrillError), keychain(SecretStoreError)
    case untrustedCaller, untrustedHelper, presenceRefused, configUnreadable, busy
    case invalidRequest, cancelled, other

    init(_ error: any Error) {
        switch error {
        case let e as AgentFailure: self = e
        case let e as RcloneSessionError: self = .session(e)
        case let e as RemoteSetupError: self = .setup(e)
        case let e as RecoveryKitError: self = .kit(e)
        case let e as RestoreDrillError: self = .drill(e)
        case let e as SecretStoreError: self = .keychain(e)
        case is CancellationError: self = .cancelled
        default: self = .other   // arbitrary errors could describe anything, so they don't cross
        }
    }

    var underlying: any Error {
        switch self {
        case .session(let e): e
        case .setup(let e): e
        case .kit(let e): e
        case .drill(let e): e
        case .keychain(let e): e
        case .cancelled: CancellationError()
        default: self
        }
    }
}

public struct AgentResponse: Codable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var failure: AgentFailure?
    public var kitText: String?
    public var drillPassed: Bool?
    public init(failure: AgentFailure? = nil, kitText: String? = nil, drillPassed: Bool? = nil) {
        self.failure = failure; self.kitText = kitText; self.drillPassed = drillPassed
    }

    public var description: String { "AgentResponse(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// Who may use the agent. Any process of the owner can spawn it, so being spawned proves nothing.
public protocol AgentTrust: Sendable {
    /// Throws `AgentFailure.untrustedCaller` unless the parent process is Mirror.app.
    func verifyCaller() throws
    /// Throws `AgentFailure.untrustedHelper` unless `url` is our signed rclone.
    func verifyHelper(at url: URL) throws
}

/// Asks the person at the Mac to prove they're the owner.
public protocol UserPresence: Sendable {
    /// Throws `AgentFailure.presenceRefused` unless they do.
    func confirm(reason: String) async throws
}

/// `support/locks/secrets.lock`. Never waits: the holder may be sitting in a browser for minutes.
/// The kernel releases it if the process dies, so a crash can't leave it stuck.
enum SecretsLock {
    static func withLock<T>(in support: URL, _ body: () async throws -> T) async throws -> T {
        let folder = support.appendingPathComponent("locks", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = open(folder.appendingPathComponent("secrets.lock").path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard fd >= 0 else { throw AgentFailure.other }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw AgentFailure.busy }
        return try await body()
    }
}

/// The agent's side: one request in, one response out. Always answers, even to bad input.
public struct AgentService: Sendable {
    /// Long enough that no sign-in can still be using a folder.
    private static let leftoverAge: TimeInterval = 86_400
    private let secrets: any SecretStoring
    private let binary: URL
    private let trust: any AgentTrust
    private let presence: any UserPresence
    private let support: URL
    private let workDir: URL

    public init(secrets: any SecretStoring, binary: URL, trust: any AgentTrust, presence: any UserPresence, support: URL) {
        self.init(secrets: secrets, binary: binary, trust: trust, presence: presence, support: support,
                  workDir: RcloneSession.interactiveWorkDir)
    }
    init(secrets: any SecretStoring, binary: URL, trust: any AgentTrust, presence: any UserPresence, support: URL, workDir: URL) {
        self.secrets = secrets; self.binary = binary; self.trust = trust; self.presence = presence
        self.support = support; self.workDir = workDir
    }

    /// `input` is a closure so a refused caller's stdin is never even read.
    public func respond(subcommand: String, input: @Sendable () -> Data) async -> Data {
        var response: AgentResponse
        do {
            try trust.verifyCaller()
            try trust.verifyHelper(at: binary)
            // The input is never repeated in a refusal: it may hold secrets.
            guard let request = try? JSONDecoder().decode(AgentRequest.self, from: input()), request.subcommand == subcommand else {
                throw AgentFailure.invalidRequest
            }
            let destination = try resolve(request.destination)
            if request.writesSecrets {
                response = try await SecretsLock.withLock(in: support) { try await handle(request, destination) }
            } else {
                response = try await handle(request, destination)
            }
        } catch {
            response = AgentResponse(failure: AgentFailure(error))
        }
        return (try? JSONEncoder().encode(response)) ?? Data("{\"failure\":{\"other\":{}}}".utf8)
    }

    /// The stored copy wins, so a request can't lower confirmation or turn encryption off. The
    /// request's own copy counts only for a destination still being created.
    private func resolve(_ requested: Destination) throws -> Destination {
        guard let stored = try? ConfigStore(root: support).loadDestinations() else { throw AgentFailure.configUnreadable }
        return stored.first { $0.id == requested.id } ?? requested
    }

    private func handle(_ request: AgentRequest, _ destination: Destination) async throws -> AgentResponse {
        try? RcloneSession.wipeLeftovers(in: workDir, olderThan: Self.leftoverAge)
        let setup = RemoteSetup(binary: binary, secrets: secrets, workDir: workDir)
        switch request {
        case .connect(_, let clientID, let clientSecret):
            try await setup.connect(destination, clientID: clientID, clientSecret: clientSecret)
            return AgentResponse()
        case .reconnect:
            try await setup.reconnect(destination)
            return AgentResponse()
        case .recoveryKit:
            // After confirmation the Kit is only ever a reveal of the backup's keys. The first showing
            // comes during setup, before there's a backup to protect.
            if destination.recoveryKitConfirmed { try await presence.confirm(reason: "show the Recovery Kit") }
            return AgentResponse(kitText: try RecoveryKit.make(for: destination, secrets: secrets, binary: binary).text())
        case .restoreFromKit(_, let kitText, let acceptUnproven):
            try await setup.restore(destination, from: try RecoveryKit(parsing: kitText), acceptUnproven: acceptUnproven)
            return AgentResponse()
        case .drill(_, let kitText, let relativePath, let original):
            let kit = try RecoveryKit(parsing: kitText)
            return AgentResponse(drillPassed: try await drill(destination, kit: kit, relativePath: relativePath, original: original))
        }
    }

    /// The session supplies the sign-in alone, so a lost vault can't stop a kit proving itself.
    private func drill(_ destination: Destination, kit: RecoveryKit, relativePath: String, original: URL) async throws -> Bool {
        let session = RcloneSession(destination: destination, secrets: secrets, binary: binary, workDir: workDir)
        guard let root = session.encryptedRoot else { throw RcloneSessionError.encryptionNotSupported }
        let context = try session.openSignInOnly()
        do {
            let passed = try await RestoreDrill(rclone: RcloneRunner(binary: binary), binary: binary, workDir: workDir)
                .run(kit: kit, encryptedRoot: root, context: context, relativePath: relativePath, original: original)
            try session.close()
            return passed
        } catch {
            try? session.close()
            throw error
        }
    }
}

public enum AgentClientError: Error, Equatable, Sendable {
    case requestTooLarge
    case noResponse(exitCode: Int32)   // what it printed isn't repeated: it may hold secrets
}

/// The app's side. Each call spawns the agent once, and cancelling the task stops it.
public struct AgentClient: Sendable {
    /// Well past `RcloneTool.killGrace`: the agent needs that long to stop rclone and clean up.
    static let killGrace: TimeInterval = 15
    public let executable: URL
    public init(executable: URL) { self.executable = executable }

    public static func bundled(in app: URL) -> AgentClient {
        AgentClient(executable: app.appendingPathComponent("Contents/MacOS/MirrorAgent"))
    }

    public func connect(_ destination: Destination, clientID: String?, clientSecret: String?) async throws {
        _ = try await send(.connect(destination: destination, clientID: clientID, clientSecret: clientSecret))
    }

    public func reconnect(_ destination: Destination) async throws {
        _ = try await send(.reconnect(destination: destination))
    }

    public func recoveryKitText(for destination: Destination) async throws -> String {
        guard let text = try await send(.recoveryKit(destination: destination)).kitText else {
            throw AgentClientError.noResponse(exitCode: 0)
        }
        return text
    }

    /// After `RemoteSetupError.vaultLostNeedsRecoveryKit` or `signInLostNeedsRecoveryKit`. Set
    /// `acceptUnproven` only once the owner has answered `RemoteSetupError.kitUnproven`.
    public func restore(_ destination: Destination, kitText: String, acceptUnproven: Bool = false) async throws {
        _ = try await send(.restoreFromKit(destination: destination, kitText: kitText, acceptUnproven: acceptUnproven))
    }

    public func drill(_ destination: Destination, kitText: String, relativePath: String, original: URL) async throws -> Bool {
        let request = AgentRequest.drill(destination: destination, kitText: kitText, relativePath: relativePath, original: original)
        guard let passed = try await send(request).drillPassed else { throw AgentClientError.noResponse(exitCode: 0) }
        return passed
    }

    private func send(_ request: AgentRequest) async throws -> AgentResponse {
        let input = try JSONEncoder().encode(request)
        guard input.count < RcloneTool.maxStdin else { throw AgentClientError.requestTooLarge }
        let (code, output) = try await RcloneTool.execute([request.subcommand], binary: executable,
                                                          context: RcloneContext(configPath: "/dev/null", environment: [:]),
                                                          stdin: input, capture: true, killGrace: Self.killGrace)
        guard let response = try? JSONDecoder().decode(AgentResponse.self, from: output) else {
            throw AgentClientError.noResponse(exitCode: code)
        }
        if let failure = response.failure { throw failure.underlying }
        return response
    }
}
