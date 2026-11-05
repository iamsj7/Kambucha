import Foundation

/// A run's access to a destination, opened before it starts and closed after, whatever happened.
public protocol RunSession {
    func open() throws -> (endpoint: String, context: RcloneContext)
    func close() throws
}

extension RcloneSession: RunSession {}

public enum RemoteFileError: Error, Equatable, Sendable {
    case tooLarge, authExpired
    case failed(exitCode: Int32)
}

/// Small files at a destination, by the same path strings rclone is given. Reading a marker must
/// tell "isn't there" from "couldn't look", because only the first may ever lead to writing one.
public protocol RemoteFileAccessing: Sendable {
    /// Nil when the file doesn't exist. Anything else that stops the read throws.
    func read(_ path: String, context: RcloneContext) async throws -> Data?
    func write(_ data: Data, to path: String, context: RcloneContext) async throws
    /// Entry names, folders with a trailing "/" or not. Nil when the folder doesn't exist.
    func list(_ path: String, context: RcloneContext) async throws -> [String]?
}

/// Through rclone, so an encrypted destination's marker is encrypted like everything else in it.
/// This is a cloud run's first rclone call, so an expired sign-in shows up here first.
public struct RcloneRemoteFiles: RemoteFileAccessing {
    private static let directoryNotFound: Int32 = 3, fileNotFound: Int32 = 4
    private let binary: URL
    private let helper: any HelperValidating
    private let workDir: URL

    public init(binary: URL, helper: any HelperValidating, workDir: URL = RcloneSession.defaultWorkDir) {
        self.binary = binary; self.helper = helper; self.workDir = workDir
    }

    public func read(_ path: String, context: RcloneContext) async throws -> Data? {
        let (code, output) = try await run(["cat", path], context: context, capture: true)
        if code == Self.directoryNotFound || code == Self.fileNotFound { return nil }
        guard code == 0 else { throw RemoteFileError.failed(exitCode: code) }
        return output
    }

    public func write(_ data: Data, to path: String, context: RcloneContext) async throws {
        guard data.count < RcloneTool.maxStdin else { throw RemoteFileError.tooLarge }
        let (code, _) = try await run(["rcat", path], context: context, stdin: data, capture: false)
        guard code == 0 else { throw RemoteFileError.failed(exitCode: code) }
    }

    public func list(_ path: String, context: RcloneContext) async throws -> [String]? {
        let (code, output) = try await run(["lsf", path, "--max-depth", "1"], context: context, capture: true)
        if code == Self.directoryNotFound { return nil }
        guard code == 0 else { throw RemoteFileError.failed(exitCode: code) }
        return String(decoding: output, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init)
    }

    /// The log exists only to classify the failure, in a private folder gone before this returns.
    private func run(_ arguments: [String], context: RcloneContext, stdin: Data? = nil,
                     capture: Bool) async throws -> (code: Int32, output: Data) {
        let dir = try RcloneTool.makePrivateDirectory(in: workDir)
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = dir.appendingPathComponent("rclone.log")
        let result = try await RcloneTool.execute(
            arguments + ["--use-json-log", "--log-file", log.path, "--config", context.configPath],
            binary: binary, helper: helper, context: context, stdin: stdin, capture: capture)
        let text = (try? Data(contentsOf: log)) ?? Data()
        if RcloneLogParser.outcome(exitCode: result.code, log: text) == .authExpired { throw RemoteFileError.authExpired }
        return result
    }
}

/// The same operations on a local folder, for the iCloud destination.
struct LocalFiles: RemoteFileAccessing {
    func read(_ path: String, context: RcloneContext) async throws -> Data? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return try Data(contentsOf: URL(fileURLWithPath: path))
    }

    func write(_ data: Data, to path: String, context: RcloneContext) async throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    func list(_ path: String, context: RcloneContext) async throws -> [String]? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return try FileManager.default.contentsOfDirectory(atPath: path)
    }
}
