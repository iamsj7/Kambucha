import Testing
import Foundation
@testable import MirrorCore

private func fixture(_ name: String) throws -> Data {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/\(name).jsonl")
    return try Data(contentsOf: url)
}

@Suite struct RcloneLogParserTests {
    @Test func firstCopyListsCopiedFiles() throws {
        let s = RcloneLogParser.parse(try fixture("sync-copy"))
        #expect(Set(s.copied) == ["a.txt", "b.txt", "old.txt"])
        #expect(s.deleted.isEmpty && s.errors.isEmpty)
        #expect(s.bytes > 0)
    }

    @Test func deleteRenameAndOverwriteAreClassified() throws {
        let s = RcloneLogParser.parse(try fixture("sync-delete-rename"))
        #expect(s.copied == ["a.txt"])
        #expect(s.deleted == ["b.txt"])
        #expect(Set(s.archived) == ["a.txt", "b.txt"])   // overwritten and deleted both archived
        #expect(s.renamed == ["old.txt -> renamed.txt"])
        #expect(!s.copied.contains("renamed.txt"))
        #expect(s.errors.isEmpty)
    }

    @Test func dryRunDeletionsLandInDeleted() throws {
        let s = RcloneLogParser.parse(try fixture("sync-dryrun-delete"))
        #expect(s.deleted == ["a.txt"])
        #expect(s.copied.isEmpty)
    }

    @Test func checkDifferencesAreCounted() throws {
        let s = RcloneLogParser.parse(try fixture("check-diff"))
        #expect(s.differences == 1)
        #expect(s.errors.contains { $0.contains("renamed.txt") })
    }

    @Test func maxDeleteLogIsRecognisedAsSafetyStop() throws {
        let data = try fixture("sync-maxdelete")
        let s = RcloneLogParser.parse(data)
        #expect(s.deleted.count == 2)
        #expect(!s.errors.isEmpty)
        #expect(RcloneLogParser.outcome(exitCode: 7, log: data) == .safetyStop)
        #expect(RcloneLogParser.outcome(exitCode: 7, log: Data()) == .permanent)
    }

    @Test func exitCodes() {
        #expect(RcloneLogParser.outcome(exitCode: 0) == .success)
        #expect(RcloneLogParser.outcome(exitCode: 5) == .transient)
        #expect(RcloneLogParser.outcome(exitCode: 6) == .transient)
        #expect(RcloneLogParser.outcome(exitCode: 10) == .partial)
        for c: Int32 in [1, 2, 3, 4, 7, 8, 9, 11, 99] { #expect(RcloneLogParser.outcome(exitCode: c) == .permanent) }
    }

    @Test func authErrorsGiveAuthExpired() {
        for msg in ["oauth2: \\\"invalid_grant\\\"", "token expired and there's no refresh token"] {
            let line = "{\"level\":\"error\",\"msg\":\"Failed to create file system: \(msg)\",\"source\":\"x\"}\n"
            #expect(RcloneLogParser.outcome(exitCode: 1, log: Data(line.utf8)) == .authExpired)
            #expect(RcloneLogParser.outcome(exitCode: 6, log: Data(line.utf8)) == .authExpired)
        }
        #expect(RcloneLogParser.outcome(exitCode: 0, log: Data()) == .success)
    }

    @Test func malformedLinesAreIgnored() {
        let s = RcloneLogParser.parse(Data("not json\n{\"level\":\"error\",\"msg\":\"boom\"}\n\n".utf8))
        #expect(s.errors == ["boom"])
    }
}
