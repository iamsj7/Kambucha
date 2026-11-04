import Testing
import Foundation
@preconcurrency import CoreServices
@testable import MirrorCore

struct ChangeFeedTests {
    @Test func replaysChangesFromStoredID() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mirror-feed-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let feed = FSEventsFeed()

        let first = try await feed.changes(in: dir, since: nil)
        #expect(first.mustRescan)
        let stored = first.latestEventID

        try FileManager.default.createDirectory(at: dir.appendingPathComponent("proj"), withIntermediateDirectories: true)
        try Data("hi".utf8).write(to: dir.appendingPathComponent("proj/a.txt"))
        try await Task.sleep(for: .seconds(1.5))

        let second = try await feed.changes(in: dir, since: stored)
        #expect(!second.mustRescan)
        #expect(second.paths.contains { $0.hasSuffix("/proj/a.txt") })
        #expect(second.latestEventID > stored)

        let third = try await feed.changes(in: dir, since: second.latestEventID)
        #expect(third.paths.isEmpty)
        #expect(!third.mustRescan)
    }

    @Test func futureIDForcesRescan() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mirror-feed-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let b = try await FSEventsFeed().changes(in: dir, since: FSEventsGetCurrentEventId() + 1_000_000_000)
        #expect(b.mustRescan)
    }

    @Test func timeoutForcesRescan() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mirror-feed-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let b = try await FSEventsFeed(timeout: .nanoseconds(1)).changes(in: dir, since: FSEventsGetCurrentEventId())
        #expect(b.mustRescan)
    }
}
