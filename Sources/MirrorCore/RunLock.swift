import Foundation

/// Exclusive, non-blocking advisory lock (flock). The kernel drops it when the holder exits or crashes.
/// One per pair at `support/locks/<pair>.lock`, plus one agent-wide.
public final class RunLock: @unchecked Sendable {
    private let url: URL
    private var fd: Int32 = -1
    private let guardLock = NSLock()

    public init(url: URL) { self.url = url }
    deinit { release() }

    public func tryAcquire() -> Bool {
        guardLock.lock(); defer { guardLock.unlock() }
        if fd >= 0 { return true }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let f = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard f >= 0 else { return false }
        if flock(f, LOCK_EX | LOCK_NB) == 0 { fd = f; return true }
        close(f)
        return false
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
