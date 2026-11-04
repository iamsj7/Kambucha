import Foundation

/// The app's only route to secrets. `MirrorAgent` owns the Keychain, and Mirror.app spawns it with a
/// subcommand as its one argument. Everything else, secrets included, goes as JSON over its stdin and
/// comes back as JSON over its stdout: never arguments, environment or files.
public enum AgentRequest: Codable, Sendable {
    case connect(destination: Destination, clientID: String?, clientSecret: String?)
    case reconnect(destination: Destination)
    case recoveryKit(destination: Destination)
    case restoreFromKit(destination: Destination, kitText: String)
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
}

/// Typed, so the app sees the same errors the agent did. None of them carries a secret.
public enum AgentFailure: Error, Equatable, Codable, Sendable {
    case session(RcloneSessionError), setup(RemoteSetupError), kit(RecoveryKitError)
    case drill(RestoreDrillError), keychain(SecretStoreError)
    case invalidRequest, cancelled, other

    init(_ error: any Error) {
        switch error {
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
        case .invalidRequest, .other: self
        }
    }
}

public struct AgentResponse: Codable, Sendable {
    public var failure: AgentFailure?
    public var kitText: String?
    public var drillPassed: Bool?
    public init(failure: AgentFailure? = nil, kitText: String? = nil, drillPassed: Bool? = nil) {
        self.failure = failure; self.kitText = kitText; self.drillPassed = drillPassed
    }
}

/// The agent's side: one request in, one response out. Always answers, even to bad input.
public struct AgentService: Sendable {
    /// Long enough that no sign-in can still be using a folder.
    private static let leftoverAge: TimeInterval = 86_400
    private let secrets: any SecretStoring
    private let binary: URL
    private let workDir: URL

    public init(secrets: any SecretStoring, binary: URL) {
        self.init(secrets: secrets, binary: binary, workDir: RcloneSession.interactiveWorkDir)
    }
    init(secrets: any SecretStoring, binary: URL, workDir: URL) {
        self.secrets = secrets; self.binary = binary; self.workDir = workDir
    }

    public func respond(subcommand: String, input: Data) async -> Data {
        let response: AgentResponse
        if let request = try? JSONDecoder().decode(AgentRequest.self, from: input), request.subcommand == subcommand {
            do { response = try await handle(request) } catch { response = AgentResponse(failure: AgentFailure(error)) }
        } else {
            response = AgentResponse(failure: .invalidRequest)   // the input is not repeated: it may hold secrets
        }
        return (try? JSONEncoder().encode(response)) ?? Data("{\"failure\":{\"other\":{}}}".utf8)
    }

    private func handle(_ request: AgentRequest) async throws -> AgentResponse {
        try? RcloneSession.wipeLeftovers(in: workDir, olderThan: Self.leftoverAge)
        let setup = RemoteSetup(binary: binary, secrets: secrets, workDir: workDir)
        switch request {
        case .connect(let destination, let clientID, let clientSecret):
            try await setup.connect(destination, clientID: clientID, clientSecret: clientSecret)
            return AgentResponse()
        case .reconnect(let destination):
            try await setup.reconnect(destination)
            return AgentResponse()
        case .recoveryKit(let destination):
            return AgentResponse(kitText: try RecoveryKit.make(for: destination, secrets: secrets, binary: binary).text())
        case .restoreFromKit(let destination, let kitText):
            try await setup.restore(destination, from: try RecoveryKit(parsing: kitText))
            return AgentResponse()
        case .drill(let destination, let kitText, let relativePath, let original):
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

    /// After `RemoteSetupError.vaultLostNeedsRecoveryKit` or `signInLostNeedsRecoveryKit`.
    public func restore(_ destination: Destination, kitText: String) async throws {
        _ = try await send(.restoreFromKit(destination: destination, kitText: kitText))
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
                                                          stdin: input, capture: true)
        guard let response = try? JSONDecoder().decode(AgentResponse.self, from: output) else {
            throw AgentClientError.noResponse(exitCode: code)
        }
        if let failure = response.failure { throw failure.underlying }
        return response
    }
}
