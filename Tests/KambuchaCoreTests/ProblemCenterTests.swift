import Testing
import Foundation
@testable import KambuchaCore

final class FakeNotifier: Notifying, @unchecked Sendable {
    private let lock = NSLock()
    private var _posts: [(Problem, String, String)] = []
    private var _deliver = true
    var onPost: (@Sendable () async -> Bool?)?
    var posts: [(Problem, String, String)] { lock.withLock { _posts } }
    var deliver: Bool { get { lock.withLock { _deliver } } set { lock.withLock { _deliver = newValue } } }
    func post(_ p: Problem, pair: PairID, setName: String, detail: String) async -> Bool {
        let hook = lock.withLock { _posts.append((p, setName, detail)); return onPost }
        if let hook, let r = await hook() { return r }
        return lock.withLock { _deliver }
    }
}

struct ProblemCenterTests {
    func root() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("kambucha-problems-\(UUID().uuidString)")
    }
    let pair = PairID(set: UUID(), destination: UUID())

    @Test func retainingDropsProblemsOfPairsThatAreGoneAndKeepsTheAgents() throws {
        let c = ProblemCenter(root: root(), notifier: FakeNotifier())
        let gone = PairID(set: UUID(), destination: UUID())
        try c.store(.verificationFailed, pair: gone, setName: "Old", detail: "d")
        try c.store(.deletionsHeld, pair: pair, setName: "P", detail: "d")
        try c.store(.agentFailed, pair: .agent, setName: "Kambucha", detail: "d")
        try c.retain(pairs: [pair])
        #expect(try c.active().map(\.problem) == [.deletionsHeld, .agentFailed])
    }

    @Test func raisingTwicePostsOnce() async throws {
        let n = FakeNotifier()
        let c = ProblemCenter(root: root(), notifier: n)
        try await c.raise(.deletionsHeld, pair: pair, setName: "Projects", detail: "1,240 deletions held")
        try await c.raise(.deletionsHeld, pair: pair, setName: "Projects", detail: "1,241 deletions held")
        #expect(n.posts.count == 1)
        #expect(try c.active().count == 1)
        #expect(try c.active()[0].pair == pair)
    }

    @Test func clearedProblemPostsAgain() async throws {
        let n = FakeNotifier()
        let r = root()
        let c = ProblemCenter(root: r, notifier: n)
        try await c.raise(.verificationFailed, pair: pair, setName: "P", detail: "x")
        try c.clear(.verificationFailed, pair: pair)
        #expect(try c.active().isEmpty)
        // a fresh instance over the same files also sees state
        try await ProblemCenter(root: r, notifier: n).raise(.verificationFailed, pair: pair, setName: "P", detail: "x")
        #expect(n.posts.count == 2)
    }

    @Test func problemsKeyOnPairAndKind() async throws {
        let n = FakeNotifier()
        let c = ProblemCenter(root: root(), notifier: n)
        let other = PairID(set: pair.set, destination: UUID())
        try await c.raise(.deletionsHeld, pair: pair, setName: "P", detail: "d")
        try await c.raise(.deletionsHeld, pair: other, setName: "P", detail: "d")
        try await c.raise(.destinationMissing, pair: pair, setName: "P", detail: "d")
        #expect(n.posts.count == 3)
        try c.clear(.deletionsHeld, pair: pair)
        #expect(try c.active().count == 2)
    }

    @Test func notificationTextIsPlain() {
        #expect(NotificationText.body(.deletionsHeld, setName: "Projects", detail: "1,240 deletions held")
                == "Backup paused: 1,240 deletions held")
        for p in Problem.allCases { #expect(!p.headline.isEmpty) }
    }

    @Test func failedDeliveryIsRetriedOnNextRaiseThenNotRepeated() async throws {
        let n = FakeNotifier(); n.deliver = false
        let c = ProblemCenter(root: root(), notifier: n)
        try await c.raise(.deletionsHeld, pair: pair, setName: "P", detail: "d")
        #expect(try c.active()[0].notified == false)
        n.deliver = true
        try await c.raise(.deletionsHeld, pair: pair, setName: "P", detail: "d")
        #expect(n.posts.count == 2)
        #expect(try c.active()[0].notified)
        try await c.raise(.deletionsHeld, pair: pair, setName: "P", detail: "d")
        #expect(n.posts.count == 2)
    }

    @Test func retryPendingPostsUndeliveredOnce() async throws {
        let n = FakeNotifier(); n.deliver = false
        let c = ProblemCenter(root: root(), notifier: n)
        try await c.raise(.uploadStalled, pair: pair, setName: "P", detail: "d")
        try await c.raise(.destinationMissing, pair: pair, setName: "P", detail: "d")
        n.deliver = true
        try await c.retryPending()
        try await c.retryPending()
        #expect(n.posts.count == 4)
        #expect(try c.active().allSatisfy(\.notified))
    }

    @Test func corruptFileIsMovedAsideAndTreatedEmpty() async throws {
        let r = root()
        try FileManager.default.createDirectory(at: r, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: r.appendingPathComponent("problems.json"))
        let n = FakeNotifier()
        let c = ProblemCenter(root: r, notifier: n)
        #expect(try c.active().isEmpty)
        try await c.raise(.deletionsHeld, pair: pair, setName: "P", detail: "d")
        #expect(n.posts.count == 1)
        let names = try FileManager.default.contentsOfDirectory(atPath: r.path)
        #expect(names.contains { $0.hasPrefix("problems.corrupt") })
    }

    @Test func concurrentRaisesLoseNothing() async throws {
        let n = FakeNotifier()
        let r = root()
        let pairs = (0..<12).map { _ in PairID(set: UUID(), destination: UUID()) }
        await withThrowingTaskGroup(of: Void.self) { g in
            for p in pairs {
                g.addTask { try await ProblemCenter(root: r, notifier: n).raise(.deletionsHeld, pair: p, setName: "P", detail: "d") }
            }
            try? await g.waitForAll()
        }
        #expect(try ProblemCenter(root: r, notifier: n).active().count == 12)
        #expect(n.posts.count == 12)
    }

    @Test func unreadableFileThrowsAndIsNotQuarantined() throws {
        let r = root()
        try FileManager.default.createDirectory(at: r, withIntermediateDirectories: true)
        let f = r.appendingPathComponent("problems.json")
        try Data("[]".utf8).write(to: f)
        chmod(f.path, 0)
        defer { chmod(f.path, 0o600) }
        let c = ProblemCenter(root: r, notifier: FakeNotifier())
        #expect(throws: (any Error).self) { try c.active() }
        #expect(FileManager.default.fileExists(atPath: f.path))
        #expect(!(try FileManager.default.contentsOfDirectory(atPath: r.path)).contains { $0.hasPrefix("problems.corrupt") })
    }

    @Test func lateDeliveryDoesNotMarkNewOccurrence() async throws {
        let n = FakeNotifier()
        let c = ProblemCenter(root: root(), notifier: n)
        let p = pair
        // While the first post is in flight, the problem is cleared and raised again; the new one's post fails.
        n.onPost = { [n] in
            n.onPost = nil
            try? c.clear(.deletionsHeld, pair: p)
            try? await Task.sleep(for: .milliseconds(5))
            n.deliver = false
            try? await c.raise(.deletionsHeld, pair: p, setName: "P", detail: "new")
            return true  // the first occurrence's delivery succeeds late
        }
        try await c.raise(.deletionsHeld, pair: p, setName: "P", detail: "old")
        let a = try c.active()
        #expect(a.count == 1 && a[0].detail == "new")
        #expect(a[0].notified == false)
    }
}

private struct StuckNotifier: Notifying {
    func post(_: Problem, pair: PairID, setName: String, detail: String) async -> Bool {
        await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }   // never answers
        return true
    }
}

/// Answers yes after `delay`, on a dispatch timer.
private struct SlowNotifier: Notifying {
    let delay: Double
    func post(_: Problem, pair: PairID, setName: String, detail: String) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) { continuation.resume(returning: true) }
        }
    }
}

@Suite struct ProblemCenterRestateTests {
    private final class Posts: Notifying, @unchecked Sendable {
        let lock = NSLock(); var details: [String] = []
        func post(_: Problem, pair: PairID, setName: String, detail: String) async -> Bool {
            lock.withLock { details.append(detail) }
            return true
        }
    }

    @Test func newsOnAnOpenProblemIsPostedOnceAndDoesNotReopenIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let posts = Posts()
        let center = ProblemCenter(root: root, notifier: posts)
        let pair = PairID(set: UUID(), destination: UUID())
        try await center.raise(.verificationFailed, pair: pair, setName: "x", detail: "first")
        let since = try center.active().first?.since
        try center.restate(.verificationFailed, pair: pair, setName: "x", detail: "second")
        try await center.raise(.verificationFailed, pair: pair, setName: "x", detail: "ignored")
        try await center.raise(.verificationFailed, pair: pair, setName: "x", detail: "ignored")
        #expect(posts.details == ["first", "second"])
        #expect(try center.active().count == 1)
        #expect(try center.active().first?.since == since)
    }

    @Test func aRestatedProblemWithNothingOpenIsNew() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let center = ProblemCenter(root: root, notifier: Posts())
        try center.restate(.verificationFailed, pair: PairID(set: UUID(), destination: UUID()), setName: "x", detail: "news")
        #expect(try center.active().map(\.detail) == ["news"])
    }
}

@Suite struct ProblemCenterTimeoutTests {
    /// No wall clock is read: the same answer loses to a shorter timeout and beats a longer one, so
    /// the value must be what decides, and load can only delay the answer. A timer that ignored the
    /// value would give the same result both ways, whatever constant it used.
    private func deliveredInTime(_ timeout: Duration) async throws -> Bool? {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let center = ProblemCenter(root: root, notifier: SlowNotifier(delay: 2), postTimeout: timeout)
        try await center.raise(.uploadStalled, pair: PairID(set: UUID(), destination: UUID()), setName: "x", detail: "")
        return try center.active().first?.notified
    }

    @Test func aTimeoutShorterThanTheAnswerGivesUpOnIt() async throws {
        #expect(try await deliveredInTime(.milliseconds(100)) == false)
    }

    @Test func aTimeoutLongerThanTheAnswerWaitsForIt() async throws {
        #expect(try await deliveredInTime(.seconds(120)) == true)
    }

    @Test func aStuckNotifierCostsOnlyTheTimeoutAndIsRetriedLater() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let center = ProblemCenter(root: root, notifier: StuckNotifier(), postTimeout: .milliseconds(50))
        let pair = PairID(set: UUID(), destination: UUID())
        let started = Date()
        try await center.raise(.uploadStalled, pair: pair, setName: "x", detail: "")
        // Only tells a return from a hang: resuming here needs the pool, which the suite keeps busy.
        #expect(Date().timeIntervalSince(started) < 60)
        #expect(try center.active().first?.notified == false)
        try await center.retryPending()
        #expect(try center.active().first?.notified == false)
    }

    @Test func theDefaultTimeoutIsTenSeconds() {
        #expect(ProblemCenter.defaultPostTimeout == .seconds(10))
    }
}
