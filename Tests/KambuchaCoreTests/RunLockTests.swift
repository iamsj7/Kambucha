import Testing
import Foundation
@testable import KambuchaCore

struct RunLockTests {
    func lockURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("kambucha-lock-\(UUID().uuidString)/locks/pair.lock")
    }

    @Test func secondLockFails() {
        let url = lockURL()
        let a = RunLock(url: url), b = RunLock(url: url)
        #expect(a.tryAcquire())
        #expect(!b.tryAcquire())
        a.release()
        #expect(b.tryAcquire())
        b.release()
    }

    @Test func lockReleasesWhenHolderExits() throws {
        let url = lockURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        child.arguments = ["-e", "use Fcntl qw(:flock); open(F, '>>', $ARGV[0]) or die; flock(F, LOCK_EX) or die; $|=1; print \"held\\n\"; sleep 60;", url.path]
        let out = Pipe()
        child.standardOutput = out
        try child.run()
        defer { if child.isRunning { child.terminate() } }
        _ = out.fileHandleForReading.availableData  // blocks until the child reports it holds the lock
        let lock = RunLock(url: url)
        #expect(!lock.tryAcquire())
        child.terminate()
        child.waitUntilExit()
        #expect(lock.tryAcquire())
        lock.release()
    }

    @Test func lockHeldByLongRunExitsQuietly() throws {
        let url = lockURL()
        let holder = RunLock(url: url)
        #expect(holder.tryAcquire())
        var ran = false
        let acquired = RunLock(url: url).runIfAcquired { ran = true }
        #expect(!acquired)
        #expect(!ran)
        holder.release()
        #expect(RunLock(url: url).runIfAcquired { ran = true })
        #expect(ran)
    }

    @Test func openFailureIsDistinctFromHeldAndAbortsImmediately() throws {
        let blocker = FileManager.default.temporaryDirectory.appendingPathComponent("kambucha-blocker-\(UUID().uuidString)")
        try Data("x".utf8).write(to: blocker)
        let lock = RunLock(url: blocker.appendingPathComponent("x.lock"))  // parent is a file
        guard case .openFailed = lock.attempt() else { Issue.record("expected openFailed"); return }
        let t0 = Date()
        #expect(throws: RunLockError.self) { try lock.acquire(timeout: 5) }
        #expect(Date().timeIntervalSince(t0) < 1)
        let url = lockURL()
        let holder = RunLock(url: url); #expect(holder.tryAcquire())
        #expect(RunLock(url: url).attempt() == .held)
        #expect(try !RunLock(url: url).acquire(timeout: 0.05))
    }
}
