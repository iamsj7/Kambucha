import Testing
import Foundation
@testable import MirrorCore

struct RunRecordTests {
    func root() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("mirror-runs-\(UUID().uuidString)")
    }
    func record(start: TimeInterval, errors: [String] = []) -> RunRecord {
        RunRecord(setID: UUID(), setName: "Projects", destinationID: UUID(), destinationName: "iCloud",
                  start: Date(timeIntervalSince1970: start), end: Date(timeIntervalSince1970: start + 60),
                  trigger: .schedule, scope: "full", filesChecked: 10, copied: 2, renamed: 1, deleted: 0,
                  archived: 0, bytes: 2048, verification: "ok", pendingUploads: 0, refused: 0,
                  errors: errors, status: .success)
    }

    @Test func recordsRoundTripNewestFirst() throws {
        let store = RunRecordStore(root: root())
        let a = record(start: 1_700_000_000), b = record(start: 1_700_100_000), c = record(start: 1_700_050_000)
        for r in [a, b, c] { try store.append(r) }
        #expect(try store.recent(limit: 10) == [b, c, a])
        #expect(try store.recent(limit: 2) == [b, c])
    }

    @Test func pruneRemovesOld() throws {
        let r = root()
        let store = RunRecordStore(root: r)
        let old = record(start: 1_600_000_000), new = record(start: 1_700_000_000)
        try store.append(old); try store.append(new)
        try store.prune(olderThan: Date(timeIntervalSince1970: 1_650_000_000))
        #expect(try store.recent(limit: 10) == [new])
        let files = try FileManager.default.contentsOfDirectory(atPath: r.appendingPathComponent("runs").path)
        #expect(files.count == 1)
    }

    @Test func recordsContainNoFileContents() throws {
        let r = root()
        let store = RunRecordStore(root: r)
        try store.append(record(start: 1_700_000_000, errors: ["a/b.txt: permission denied"]))
        let f = try FileManager.default.contentsOfDirectory(at: r.appendingPathComponent("runs"),
                                                            includingPropertiesForKeys: nil)[0]
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: f)) as! [String: Any]
        let allowed: Set<String> = ["id", "setID", "setName", "destinationID", "destinationName", "start", "end",
            "trigger", "scope", "filesChecked", "copied", "renamed", "deleted", "archived", "bytes",
            "verification", "pendingUploads", "refused", "errors", "status"]
        #expect(Set(obj.keys) == allowed)
        for (k, v) in obj where k != "errors" { #expect(!(v is [Any]) && !(v is [String: Any])) }
        #expect(f.lastPathComponent.hasSuffix("\(try #require(obj["id"] as? String)).json"))
    }
}

struct LogRotatorTests {
    @Test func prunesOldLogsOnly() throws {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("mirror-logs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        let old = d.appendingPathComponent("old.log"), new = d.appendingPathComponent("new.log")
        try Data("x".utf8).write(to: old); try Data("x".utf8).write(to: new)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: old.path)
        try LogRotator.prune(d, olderThan: Date(timeIntervalSince1970: 2_000))
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: new.path))
        try LogRotator.prune(d.appendingPathComponent("missing"), olderThan: Date())
    }
}
