import Foundation
import os

public enum RunLockError: Error, Equatable { case cannotOpen(errno: Int32) }

/// Exclusive, non-blocking advisory lock (flock). The kernel drops it when the holder exits or crashes.
/// One per pair at `support/locks/<pair>.lock`, plus one agent-wide.
public final class RunLock: @unchecked Sendable {
    private let url: URL
    private var fd: Int32 = -1
    private let guardLock = NSLock()

    public init(url: URL) { self.url = url }
    deinit { release() }

    public enum Outcome: Equatable, Sendable { case acquired, held, openFailed(errno: Int32) }

    private static let log = Logger(subsystem: "app.kambucha", category: "RunLock")

    /// Tells "someone else holds it" apart from "the lock file can't be opened".
    public func attempt() -> Outcome {
        guardLock.lock(); defer { guardLock.unlock() }
        if fd >= 0 { return .acquired }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let f = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard f >= 0 else { return .openFailed(errno: errno) }
        if flock(f, LOCK_EX | LOCK_NB) == 0 { fd = f; return .acquired }
        close(f)
        return .held
    }

    /// True only when acquired. Held and open failure both give false (open failure is logged once).
    public func tryAcquire() -> Bool {
        switch attempt() {
        case .acquired: return true
        case .held: return false
        case .openFailed(let e): Self.log.error("cannot open lock file, errno \(e)"); return false
        }
    }

    /// Waits up to `timeout` seconds while another holder has it. Throws at once if the file can't be opened.
    public func acquire(timeout: TimeInterval) throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            switch attempt() {
            case .acquired: return true
            case .openFailed(let e): throw RunLockError.cannotOpen(errno: e)
            case .held: break
            }
            if Date() >= deadline { return false }
            usleep(5_000)
        }
    }

    public func release() {
        guardLock.lock(); defer { guardLock.unlock() }
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN)
        close(fd)
        fd = -1
    }

    /// Runs `body` only if the lock is free; otherwise returns false without running or reporting anything.
    @discardableResult
    public func runIfAcquired(_ body: () throws -> Void) rethrows -> Bool {
        guard tryAcquire() else { return false }
        defer { release() }
        try body()
        return true
    }
}
