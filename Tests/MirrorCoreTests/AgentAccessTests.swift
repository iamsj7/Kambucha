import Testing
import Foundation
@testable import MirrorCore

struct AgentAccessTests {
    func dir(files: Int = 0) throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("mirror-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test func readableFoldersPass() throws {
        #expect(AgentAccess.check(paths: [try dir(), try dir()]))
    }

    @Test func aMissingOrUnreadableFolderFails() throws {
        #expect(!AgentAccess.check(paths: [try dir(), URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")]))
        let locked = try dir()
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path) }
        #expect(!AgentAccess.check(paths: [locked]))
    }

    @Test func noPathsIsNotAPass() { #expect(!AgentAccess.check(paths: [])) }

    @Test func reportRoundTripsAndOnlyAFreshPassConfirms() throws {
        let support = try dir()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(!AgentAccess.isConfirmed(support: support, now: now))   // no file
        #expect(AgentAccess.writeReport(support: support, paths: [try dir()], now: now))
        #expect(AgentAccess.readReport(support: support) == AccessReport(passed: true, checkedAt: now))
        #expect(AgentAccess.isConfirmed(support: support, now: now.addingTimeInterval(60)))
        #expect(!AgentAccess.isConfirmed(support: support, now: now.addingTimeInterval(3 * 3600)))            // stale
        #expect(!AgentAccess.isConfirmed(support: support, now: now.addingTimeInterval(60), notBefore: now.addingTimeInterval(30)))
    }

    @Test func aFailingReportNeverConfirms() throws {
        let support = try dir()
        let now = Date()
        #expect(!AgentAccess.writeReport(support: support, paths: [URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")], now: now))
        #expect(!AgentAccess.isConfirmed(support: support, now: now))
    }

    @Test func aReportFromTheFutureNeverConfirms() throws {
        let support = try dir()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        AgentAccess.writeReport(support: support, paths: [support], now: now.addingTimeInterval(3600))
        #expect(!AgentAccess.isConfirmed(support: support, now: now))
    }
}
