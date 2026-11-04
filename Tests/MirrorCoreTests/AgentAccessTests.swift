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
}

struct FilterMatcherTests {
    func excluded(_ lines: [String], _ path: String) -> Bool { FilterMatcher(lines: lines).isExcluded(path) }

    @Test func anchoredAndUnanchoredPatterns() {
        #expect(excluded(["- /build"], "build"))
        #expect(!excluded(["- /build"], "src/build"))
        #expect(excluded(["- build"], "src/build"))
        #expect(!excluded(["- /build"], "builder"))
    }

    @Test func starsAndDoubleStars() {
        #expect(excluded(["- **/*.log"], "x.log"))
        #expect(excluded(["- **/*.log"], "a/b/x.log"))
        #expect(excluded(["- *.log"], "a/x.log"))
        #expect(!excluded(["- /*.log"], "a/x.log"))
        #expect(excluded(["- /*.log"], "x.log"))
        #expect(!excluded(["- **/*.log"], "x.txt"))
    }

    @Test func alternationClassesAndEscapes() {
        #expect(excluded(["- *.{tmp,bak}"], "a.bak"))
        #expect(!excluded(["- *.{tmp,bak}"], "a.txt"))
        #expect(excluded(["- /file[0-9].txt"], "file7.txt"))
        #expect(excluded(["- /a\\*b"], "a*b"))
        #expect(!excluded(["- /a\\*b"], "axb"))
    }

    @Test func firstMatchWinsAndNoMatchIncludes() {
        #expect(!excluded(["+ /keep.log", "- *.log"], "keep.log"))
        #expect(excluded(["+ /keep.log", "- *.log"], "other.log"))
        #expect(!excluded([], "anything"))
    }
}
