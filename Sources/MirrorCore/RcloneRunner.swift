import Foundation

public protocol RcloneRunning: Sendable {
    func sync(_: SyncRequest) async throws -> RcloneResult
    func check(_: CheckRequest) async throws -> RcloneResult
    /// Runs rclone with exactly these arguments (the caller adds `--config` and the log flags) and parses the log.
    func execute(_ arguments: [String], context: RcloneContext, logFile: URL) async throws -> RcloneResult
    /// Runs a listing or size command and returns what it printed.
    func capture(_ arguments: [String], context: RcloneContext) async throws -> RcloneCapture
}

public struct RcloneCapture: Equatable, Sendable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String
    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode; self.stdout = stdout; self.stderr = stderr
    }
}

public struct RcloneUnsupported: Error, Equatable, Sendable {}

/// Runners that only sync and check (test fakes) need not implement the extra commands.
public extension RcloneRunning {
    func execute(_ arguments: [String], context: RcloneContext, logFile: URL) async throws -> RcloneResult {
        throw RcloneUnsupported()
    }
    func capture(_ arguments: [String], context: RcloneContext) async throws -> RcloneCapture {
        throw RcloneUnsupported()
    }
}

/// Proves `url` is our signed rclone. Run immediately before any spawn that receives secrets, so a
/// swapped binary is caught as late as possible. The instant between check and exec stays open.
public protocol HelperValidating: Sendable {
    func verifyHelper(at url: URL) throws
}

public enum RcloneRunnerError: Error, Equatable {
    /// The context holds secrets and this runner has nothing to check the binary with.
    case helperNotChecked
}

/// Runs the bundled rclone. `binary` is an absolute path chosen by the caller (the app derives it
/// from `Bundle.main.bundleURL`); nothing here reads it from argv or PATH.
public struct RcloneRunner: RcloneRunning {
    public let binary: URL
    /// Seconds between SIGTERM and SIGKILL when a run is cancelled.
    let killGrace: TimeInterval
    /// Called with each live stats record while rclone runs (about every 2 seconds). Off the main thread.
    let onStats: (@Sendable (RcloneStats) -> Void)?
    private let helper: (any HelperValidating)?
    /// `helper` may be nil only for runs with nothing secret, which is any iCloud run. A context with
    /// a config or environment is refused without one.
    public init(binary: URL, helper: (any HelperValidating)? = nil, onStats: (@Sendable (RcloneStats) -> Void)? = nil) {
        self.init(binary: binary, killGrace: 5, helper: helper, onStats: onStats)
    }
    init(binary: URL, killGrace: TimeInterval, helper: (any HelperValidating)? = nil,
         onStats: (@Sendable (RcloneStats) -> Void)? = nil) {
        self.binary = binary; self.killGrace = killGrace; self.helper = helper; self.onStats = onStats
    }

    public func sync(_ r: SyncRequest) async throws -> RcloneResult {
        try await run(RcloneCommand.arguments(r), context: r.context, logFile: r.logFile, isCheck: false)
    }

    public func check(_ r: CheckRequest) async throws -> RcloneResult {
        try await run(RcloneCommand.arguments(r), context: r.context, logFile: r.logFile, isCheck: true)
    }

    public func execute(_ arguments: [String], context: RcloneContext, logFile: URL) async throws -> RcloneResult {
        try await run(arguments, context: context, logFile: logFile, isCheck: false)
    }

    public func capture(_ arguments: [String], context: RcloneContext) async throws -> RcloneCapture {
        try checkHelper(for: context)
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        process.environment = Self.childEnvironment(context)
        process.qualityOfService = Self.qos(Task.currentPriority)
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        let state = RunState(process, killGrace: killGrace)
        // Both pipes are drained concurrently so a full pipe never blocks the child.
        let outTask = Task.detached { () -> Data in (try? out.fileHandleForReading.readToEnd()) ?? Data() }
        let errTask = Task.detached { () -> Data in (try? err.fileHandleForReading.readToEnd()) ?? Data() }
        let exitCode: Int32
        do {
            exitCode = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int32, Error>) in
                    process.terminationHandler = { p in cont.resume(returning: p.terminationStatus) }
                    do { try state.start() } catch {
                        process.terminationHandler = nil
                        try? out.fileHandleForWriting.close(); try? err.fileHandleForWriting.close()
                        cont.resume(throwing: error)
                    }
                }
            } onCancel: { state.cancel() }
        } catch {
            _ = await outTask.value; _ = await errTask.value
            throw error
        }
        let o = await outTask.value, e = await errTask.value
        if state.wasCancelled { throw CancellationError() }
        return RcloneCapture(exitCode: exitCode, stdout: String(decoding: o, as: UTF8.self),
                             stderr: String(decoding: e, as: UTF8.self))
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

    private func checkHelper(for context: RcloneContext) throws {
        if let helper { try helper.verifyHelper(at: binary) }
        else if !context.environment.isEmpty || context.configPath != "/dev/null" { throw RcloneRunnerError.helperNotChecked }
    }

    private func run(_ args: [String], context: RcloneContext, logFile: URL, isCheck: Bool) async throws -> RcloneResult {
        try checkHelper(for: context)

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

        let state = RunState(process, killGrace: killGrace)
        let stderrTask = Task.detached { () -> Data in
            (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data()
        }
        // Live progress: follow the log file while rclone runs. Only when someone is listening.
        let tail = onStats.map { handler in
            Task.detached { await LogTail.follow(logFile, from: 0, handler: handler) }
        }
        // Cancel and await the tail on every exit path, so no stats callback can land after `sync` returns.
        func stopTail() async { tail?.cancel(); await tail?.value }
        let exitCode: Int32
        do {
            exitCode = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int32, Error>) in
                    process.terminationHandler = { p in cont.resume(returning: p.terminationStatus) }
                    // Checked under the same lock as cancel(), so a cancelled task never starts rclone.
                    do { try state.start() } catch {
                        process.terminationHandler = nil
                        // Closing our write end lets the stderr reader finish.
                        try? stderrPipe.fileHandleForWriting.close()
                        cont.resume(throwing: error)
                    }
                }
            } onCancel: { state.cancel() }
        } catch {
            _ = await stderrTask.value
            await stopTail()
            throw error
        }
        await stopTail()
        if state.wasCancelled { _ = await stderrTask.value; throw CancellationError() }

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

/// Polls a growing JSON log once a second and reports each complete stats line. The final read after
/// cancellation catches anything written just before the process exited.
enum LogTail {
    static func follow(_ file: URL, from start: UInt64? = nil, handler: @Sendable (RcloneStats) -> Void) async {
        // Start at the file's current size: anything already there belongs to an earlier run.
        // The runner passes 0 (it deletes the log first); a late-starting task must not skip what rclone already wrote.
        var offset = start ?? ((try? FileManager.default.attributesOfItem(atPath: file.path)[.size]) as? NSNumber)?.uint64Value ?? 0
        var carry = Data()
        func drain() {
            guard let h = try? FileHandle(forReadingFrom: file) else { return }
            defer { try? h.close() }
            if let size = try? h.seekToEnd(), size < offset { offset = 0; carry = Data() }   // truncated or replaced
            guard (try? h.seek(toOffset: offset)) != nil, let chunk = try? h.readToEnd(), !chunk.isEmpty else { return }
            offset += UInt64(chunk.count)
            carry.append(chunk)
            while let nl = carry.firstIndex(of: UInt8(ascii: "\n")) {
                let line = carry[carry.startIndex..<nl]
                carry = Data(carry[carry.index(after: nl)...])
                if let s = RcloneLogParser.stats(line: Data(line)) { handler(s) }
            }
        }
        while !Task.isCancelled {
            drain()
            try? await Task.sleep(for: .seconds(1))
        }
        drain()
    }
}

/// Lock-protected start/cancel state for one child process.
private final class RunState: @unchecked Sendable {
    private let lock = NSLock()
    private let process: Process
    private let killGrace: TimeInterval
    private var cancelled = false
    private var started = false
    init(_ p: Process, killGrace: TimeInterval) { process = p; self.killGrace = killGrace }

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
            // Escalate if rclone ignored SIGTERM. pid reuse is not a concern within the grace window
            // because the process is only reaped by Foundation after it has exited and been observed.
            if lock.withLock({ process.isRunning }) { kill(pid, SIGKILL) }
        }
    }
}
