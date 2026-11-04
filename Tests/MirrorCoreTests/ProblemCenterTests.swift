import Testing
import Foundation
@testable import MirrorCore

final class FakeNotifier: Notifying, @unchecked Sendable {
    private let lock = NSLock()
    private var _posts: [(Problem, String, String)] = []
    var posts: [(Problem, String, String)] { lock.withLock { _posts } }
    func post(_ p: Problem, setName: String, detail: String) { lock.withLock { _posts.append((p, setName, detail)) } }
}

struct ProblemCenterTests {
    func root() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("mirror-problems-\(UUID().uuidString)")
    }
    let pair = PairID(set: UUID(), destination: UUID())

    @Test func raisingTwicePostsOnce() throws {
        let n = FakeNotifier()
        let c = ProblemCenter(root: root(), notifier: n)
        try c.raise(.deletionsHeld, pair: pair, setName: "Projects", detail: "1,240 deletions held")
        try c.raise(.deletionsHeld, pair: pair, setName: "Projects", detail: "1,241 deletions held")
        #expect(n.posts.count == 1)
        #expect(try c.active().count == 1)
        #expect(try c.active()[0].pair == pair)
    }

    @Test func clearedProblemPostsAgain() throws {
        let n = FakeNotifier()
        let r = root()
        let c = ProblemCenter(root: r, notifier: n)
        try c.raise(.verificationFailed, pair: pair, setName: "P", detail: "x")
        try c.clear(.verificationFailed, pair: pair)
        #expect(try c.active().isEmpty)
        // a fresh instance over the same files also sees state
        try ProblemCenter(root: r, notifier: n).raise(.verificationFailed, pair: pair, setName: "P", detail: "x")
        #expect(n.posts.count == 2)
    }

    @Test func problemsKeyOnPairAndKind() throws {
        let n = FakeNotifier()
        let c = ProblemCenter(root: root(), notifier: n)
        let other = PairID(set: pair.set, destination: UUID())
        try c.raise(.deletionsHeld, pair: pair, setName: "P", detail: "d")
        try c.raise(.deletionsHeld, pair: other, setName: "P", detail: "d")
        try c.raise(.destinationMissing, pair: pair, setName: "P", detail: "d")
        #expect(n.posts.count == 3)
        try c.clear(.deletionsHeld, pair: pair)
        #expect(try c.active().count == 2)
    }

    @Test func notificationTextIsPlain() {
        #expect(NotificationText.body(.deletionsHeld, setName: "Projects", detail: "1,240 deletions held")
                == "Backup paused: 1,240 deletions held")
        for p in Problem.allCases { #expect(!p.headline.isEmpty) }
    }
}
