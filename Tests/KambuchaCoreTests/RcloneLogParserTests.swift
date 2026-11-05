import Testing
import Foundation
@testable import KambuchaCore

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

    private func jsonLine(level: String, msg: String, object: String? = nil) -> String {
        var d: [String: Any] = ["level": level, "msg": msg]
        if let object { d["object"] = object }
        let data = try! JSONSerialization.data(withJSONObject: d)
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    @Test func fileNamesCannotForgeAuthExpired() {
        let log = jsonLine(level: "info", msg: "Copied (new)", object: "token expired.txt")
            + jsonLine(level: "error", msg: "Failed to copy: boom", object: "invalid_grant.txt")
        #expect(RcloneLogParser.outcome(exitCode: 1, log: Data(log.utf8)) == .permanent)
        #expect(RcloneLogParser.outcome(exitCode: 5, log: Data(log.utf8)) == .transient)
        let real = jsonLine(level: "error", msg: "couldn't fetch token: invalid_grant: maybe token expired?")
        #expect(RcloneLogParser.outcome(exitCode: 1, log: Data(real.utf8)) == .authExpired)
        // Only error-level lines count.
        let info = jsonLine(level: "info", msg: "invalid_grant")
        #expect(RcloneLogParser.outcome(exitCode: 1, log: Data(info.utf8)) == .permanent)
    }

    @Test func pathInsideErrorMessageIsNotAuthExpired() {
        let line = jsonLine(level: "error", msg: "Failed to copy: open /x/token expired.txt: permission denied")
        #expect(RcloneLogParser.outcome(exitCode: 5, log: Data(line.utf8)) == .transient)
    }

    @Test func invalidGrantFileNameInMessageIsNotAuthExpired() {
        let bare = jsonLine(level: "error", msg: "Failed to copy: open /x/invalid_grant.txt: permission denied")
        #expect(RcloneLogParser.outcome(exitCode: 5, log: Data(bare.utf8)) == .transient)
        // The object's value is removed from msg before matching, even when it looks like an auth shape.
        let name = "/x/couldn't fetch token.txt"
        let withObject = jsonLine(level: "error", msg: "Failed to copy: open \(name): permission denied", object: name)
        #expect(RcloneLogParser.outcome(exitCode: 5, log: Data(withObject.utf8)) == .transient)
    }

    @Test func realOAuthErrorIsAuthExpired() {
        let msg = "Failed to create file system for \"gdrive:\": couldn't fetch token: oauth2: cannot fetch token: 400 Bad Request\nResponse: {\"error\": \"invalid_grant\", \"error_description\": \"Token has been expired or revoked.\"}"
        let line = jsonLine(level: "error", msg: msg)
        #expect(RcloneLogParser.outcome(exitCode: 1, log: Data(line.utf8)) == .authExpired)
        let direct = jsonLine(level: "error", msg: "oauth2: cannot fetch token: 400 Bad Request\nResponse: {\"error\":\"invalid_grant\"}")
        #expect(RcloneLogParser.outcome(exitCode: 6, log: Data(direct.utf8)) == .authExpired)
    }

    @Test func fileNamesCannotForgeSafetyStop() {
        let name = "--max-delete threshold reached"
        let log = jsonLine(level: "info", msg: "Copied (new)", object: name)
            + jsonLine(level: "error", msg: "Failed to copy: boom", object: name)
        #expect(RcloneLogParser.outcome(exitCode: 7, log: Data(log.utf8)) == .permanent)
        let real = jsonLine(level: "error", msg: "Got fatal error on delete: --max-delete threshold reached", object: name)
        #expect(RcloneLogParser.outcome(exitCode: 7, log: Data(real.utf8)) == .safetyStop)
    }

    @Test func dryRunOverwriteAndRenameDoNotCountAsDeleted() throws {
        let s = RcloneLogParser.parse(try fixture("sync-dryrun-overwrite-rename"))
        #expect(s.deleted.isEmpty)
        #expect(s.renamed == ["old.txt -> new.txt"])
    }

    @Test func oneUnexpectedFieldTypeDoesNotDropTheLine() {
        let log = "{\"level\":\"info\",\"msg\":\"Copied (new)\",\"object\":\"a.txt\",\"size\":\"oops\",\"stats\":\"x\"}\n"
            + "{\"level\":\"error\",\"msg\":\"bad\",\"object\":7}\n"
        let s = RcloneLogParser.parse(Data(log.utf8))
        #expect(s.copied == ["a.txt"])
        #expect(s.errors == ["bad"])
    }

    @Test func aRepeatedDeletionIsCountedOnceAndALongListStaysFast() throws {
        var lines: [String] = []
        for i in 0..<20_000 { lines.append(#"{"level":"notice","msg":"Skipped delete as --dry-run is set (size 1)","object":"f\#(i)"}"#) }
        lines.append(lines[0])
        let started = Date()
        let s = RcloneLogParser.parse(Data(lines.joined(separator: "\n").utf8))
        #expect(s.deleted.count == 20_000)
        #expect(Date().timeIntervalSince(started) < 5)
    }
}
