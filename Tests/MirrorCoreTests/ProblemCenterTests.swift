import Testing
import Foundation
@testable import MirrorCore

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
        FileManager.default.temporaryDirectory.appendingPathComponent("mirror-problems-\(UUID().uuidString)")
    }
    let pair = PairID(set: UUID(), destination: UUID())

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
