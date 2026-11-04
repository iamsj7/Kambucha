import Testing
import Foundation
@testable import MirrorCore

struct AgentAccessTests {
    func dir(files: Int = 0) throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("mirror-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// Stands in for the TCC database, which only Full Disk Access can read.
    func readable() throws -> URL {
        let f = try dir().appendingPathComponent("TCC.db")
        try Data("db".utf8).write(to: f)
        return f
    }

    @Test func theFullDiskAccessCheckReadsTheFileItself() throws {
        #expect(AgentAccess.canRead(try readable()))
        #expect(!AgentAccess.canRead(URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")))
        #expect(!AgentAccess.canRead(try dir()))   // a folder opens, but it can't be read
        let locked = try readable()
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        #expect(!AgentAccess.canRead(locked))
    }

    @Test func theCheckLooksAtTheRealDatabase() {
        #expect(AgentAccess.fullDiskAccessProbe.path == "/Library/Application Support/com.apple.TCC/TCC.db")
    }

    @Test func foldersAndFullDiskAccessAreReportedApart() throws {
        let support = try dir()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let noAccess = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
        #expect(!AgentAccess.writeReport(support: support, paths: [try dir()], fullDiskProbe: noAccess, now: now))
        let report = try #require(AgentAccess.readReport(support: support))
        #expect(report.folders && !report.fullDiskAccess && !report.passed)
        #expect(!AgentAccess.isConfirmed(support: support, now: now))   // reading Documents alone doesn't prove it
    }

    @Test func onlyALaunchdStartWritesTheReport() {
        #expect(AgentAccess.reportsAccess(arguments: []))
        #expect(!AgentAccess.reportsAccess(arguments: ["--run-now"]))
        #expect(!AgentAccess.reportsAccess(arguments: ["--run-now", UUID().uuidString]))
        #expect(!AgentAccess.reportsAccess(arguments: ["--allow-deletes", UUID().uuidString, UUID().uuidString, "4"]))
        #expect(!AgentAccess.reportsAccess(arguments: ["--anything"]))
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
        #expect(AgentAccess.writeReport(support: support, paths: [try dir()], fullDiskProbe: try readable(), now: now))
        #expect(AgentAccess.readReport(support: support) == AccessReport(folders: true, fullDiskAccess: true, checkedAt: now))
        #expect(AgentAccess.isConfirmed(support: support, now: now.addingTimeInterval(60)))
        #expect(!AgentAccess.isConfirmed(support: support, now: now.addingTimeInterval(3 * 3600)))            // stale
        #expect(!AgentAccess.isConfirmed(support: support, now: now.addingTimeInterval(60), notBefore: now.addingTimeInterval(30)))
    }

    @Test func aFailingReportNeverConfirms() throws {
        let support = try dir()
        let now = Date()
        #expect(!AgentAccess.writeReport(support: support, paths: [URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")], fullDiskProbe: try readable(), now: now))
        #expect(!AgentAccess.isConfirmed(support: support, now: now))
    }

    @Test func aReportFromTheFutureNeverConfirms() throws {
        let support = try dir()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        AgentAccess.writeReport(support: support, paths: [support], fullDiskProbe: try readable(), now: now.addingTimeInterval(3600))
        #expect(!AgentAccess.isConfirmed(support: support, now: now))
    }
}
