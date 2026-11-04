import Foundation

public protocol RcloneRunning: Sendable {
    func sync(_: SyncRequest) async throws -> RcloneResult
    func check(_: CheckRequest) async throws -> RcloneResult
}

/// Runs the bundled rclone. `binary` is an absolute path chosen by the caller (the app derives it
/// from `Bundle.main.bundleURL`); nothing here reads it from argv or PATH.
public struct RcloneRunner: RcloneRunning {
    public let binary: URL
    public init(binary: URL) { self.binary = binary }

    public func sync(_ r: SyncRequest) async throws -> RcloneResult {
        try await run(RcloneCommand.arguments(r), context: r.context, logFile: r.logFile, isCheck: false)
    }

    public func check(_ r: CheckRequest) async throws -> RcloneResult {
        try await run(RcloneCommand.arguments(r), context: r.context, logFile: r.logFile, isCheck: true)
    }

    /// Explicit minimal environment: PATH, HOME and the context's variables. The parent's
    /// environment is never inherited, so unrelated secrets cannot leak into rclone.
    static func childEnvironment(_ context: RcloneContext,
                                 parent: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env = ["PATH": "/usr/bin:/bin", "HOME": parent["HOME"] ?? NSHomeDirectory()]
        for (k, v) in context.environment { env[k] = v }
        return env
    }

    private static func qos(_ p: TaskPriority) -> QualityOfService {
        if p >= .userInitiated { return .userInitiated }
        if p >= .medium { return .default }
        if p >= .utility { return .utility }
        return .background
    }

    private func run(_ args: [String], context: RcloneContext, logFile: URL, isCheck: Bool) async throws -> RcloneResult {
        // The log file is per run; a leftover would be parsed as this run's output.
        try? FileManager.default.removeItem(at: logFile)

        let process = Process()
        process.executableURL = binary
        process.arguments = args
        process.environment = Self.childEnvironment(context)
        process.qualityOfService = Self.qos(Task.currentPriority)   // same priority as the calling agent
        // Output goes to the log file; stdout is discarded and stderr is drained concurrently,
        // so a full pipe can never block the child.
        let stderrPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice

        let box = ProcessBox(process)
        let stderrTask = Task.detached { () -> Data in
            (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data()
        }
        let exitCode: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int32, Error>) in
                process.terminationHandler = { p in cont.resume(returning: p.terminationStatus) }
                do { try process.run() } catch {
                    process.terminationHandler = nil
                    cont.resume(throwing: error)
                }
            }
        } onCancel: { box.terminate() }

        let stderr = await stderrTask.value
        var log = (try? Data(contentsOf: logFile)) ?? Data()
        var summary = RcloneLogParser.parse(log)
        // rclone writes some early failures (bad flags, missing remote) only to stderr.
        if !stderr.isEmpty {
            log.append(stderr)
            let text = String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if exitCode != 0, summary.errors.isEmpty, !text.isEmpty { summary.errors.append(text) }
        }
        var outcome = RcloneLogParser.outcome(exitCode: exitCode, log: log)
        // A check that finds differences exits 1; that is a finding, not a failed run.
        if isCheck, exitCode == 1, summary.differences > 0, outcome == .permanent { outcome = .success }
        return RcloneResult(exitCode: exitCode, summary: summary, outcome: outcome)
    }
}

private final class ProcessBox: @unchecked Sendable {
    private let process: Process
    init(_ p: Process) { process = p }
    func terminate() { if process.isRunning { process.terminate() } }
}
