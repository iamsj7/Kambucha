import Testing
import Foundation
@testable import KambuchaCore

struct RunRecordTests {
    func root() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("kambucha-runs-\(UUID().uuidString)")
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

struct RunFilterTests {
    func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("kambucha-runs-\(UUID().uuidString)") }
    func rec(_ t: TimeInterval, _ status: RunRecord.Status, set: UUID = UUID(), name: String = "Projects") -> RunRecord {
        RunRecord(setID: set, setName: name, destinationID: UUID(), destinationName: "iCloud",
                  start: Date(timeIntervalSince1970: t), end: Date(timeIntervalSince1970: t + 5),
                  trigger: .schedule, scope: "full", status: status)
    }

    @Test func limitCountsOnlyRecordsThatPassTheFilter() throws {
        let store = RunRecordStore(root: root())
        let real = rec(1_700_000_000, .failed)
        try store.append(real)
        for i in 1...50 { try store.append(rec(1_700_000_000 + Double(i) * 60, .skipped)) }
        #expect(try store.recent(limit: 3, matching: RunFilter()) == [real])
        #expect(try store.recent(limit: 3, matching: .everything).count == 3)
    }

    @Test func skippedRunsAreNamedSoTheyCanBePassedOverUnread() throws {
        let r = root()
        let store = RunRecordStore(root: r)
        try store.append(rec(1_700_000_000, .skipped)); try store.append(rec(1_700_000_001, .success))
        let names = try FileManager.default.contentsOfDirectory(atPath: r.appendingPathComponent("runs").path)
        #expect(names.filter { $0.contains("-skipped-") }.count == 1)
    }

    @Test func oldNamesWithoutAMarkerStillReadAndFilter() throws {
        let r = root()
        let store = RunRecordStore(root: r)
        let old = rec(1_600_000_000, .skipped), keep = rec(1_600_000_100, .success)
        try FileManager.default.createDirectory(at: r.appendingPathComponent("runs"), withIntermediateDirectories: true)
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        for x in [old, keep] {
            try e.encode(x).write(to: r.appendingPathComponent("runs/20200913T120000-\(x.id.uuidString).json"))
        }
        #expect(try store.recent(limit: 10, matching: RunFilter()) == [keep])
        #expect(try store.recent(limit: 10, matching: .everything).count == 2)
    }

    @Test func filtersBySetResultAndSearch() throws {
        let store = RunRecordStore(root: root())
        let a = UUID()
        let ok = rec(1_700_000_000, .success, set: a, name: "Photos"), bad = rec(1_700_000_100, .failed, name: "Projects")
        let part = rec(1_700_000_200, .partial, name: "Projects")
        for x in [ok, bad, part] { try store.append(x) }
        #expect(try store.recent(limit: 9, matching: RunFilter(result: .problems)) == [part, bad])
        #expect(try store.recent(limit: 9, matching: RunFilter(result: .success)) == [ok])
        #expect(try store.recent(limit: 9, matching: RunFilter(setID: a)) == [ok])
        #expect(try store.recent(limit: 9, matching: RunFilter(search: "proj")) == [part, bad])
    }

    @Test func skippedNeverShowsUnderProblemsOrSuccess() {
        let f = RunFilter(includeSkipped: true, result: .problems)
        #expect(!f.matches(rec(1, .skipped)))
        #expect(RunFilter(includeSkipped: true).matches(rec(1, .skipped)))
        #expect(!RunFilter().matches(rec(1, .skipped)))
    }

    @Test func aFilterThatMatchesLittleReadsAtMostTheBound() throws {
        let store = RunRecordStore(root: root())
        for i in 0..<30 { try store.append(rec(1_700_000_000 + Double(i), .success)) }
        #expect(try store.recent(limit: 5, matching: RunFilter(search: "nothing"), maxRead: 10).isEmpty)
    }

    /// A failed run past the bound mustn't read as "no problems".
    @Test func aScanCutShortSaysSo() throws {
        let store = RunRecordStore(root: root())
        let bad = rec(1_700_000_000, .failed)
        try store.append(bad)
        for i in 1...5 { try store.append(rec(1_700_000_000 + Double(i) * 60, .success)) }
        let cut = try store.search(limit: 9, matching: RunFilter(result: .problems), maxRead: 3)
        #expect(cut.records.isEmpty && cut.reachedScanLimit)
        let whole = try store.search(limit: 9, matching: RunFilter(result: .problems), maxRead: 6)
        #expect(whole.records == [bad] && !whole.reachedScanLimit)
    }

    @Test func stoppingAtTheLimitIsntACutScan() throws {
        let store = RunRecordStore(root: root())
        for i in 0..<5 { try store.append(rec(1_700_000_000 + Double(i) * 60, .success)) }
        let found = try store.search(limit: 2, matching: RunFilter(), maxRead: 2)
        #expect(found.records.count == 2 && !found.reachedScanLimit)
    }

    @Test func skippedFilesPassedOverArentACutScan() throws {
        let store = RunRecordStore(root: root())
        for i in 0..<5 { try store.append(rec(1_700_000_000 + Double(i) * 60, .skipped)) }
        for i in 5..<8 { try store.append(rec(1_700_000_000 + Double(i) * 60, .success)) }
        let found = try store.search(limit: 9, matching: RunFilter(), maxRead: 3)
        #expect(found.records.count == 3 && !found.reachedScanLimit)
    }

    @Test func pruneKeepsRecentWithoutNeedingThemRead() throws {
        let store = RunRecordStore(root: root())
        let old = rec(1_600_000_000, .skipped), new = rec(1_700_000_000, .success)
        try store.append(old); try store.append(new)
        try store.prune(olderThan: Date(timeIntervalSince1970: 1_650_000_000))
        #expect(try store.recent(limit: 10) == [new])
    }
}

struct LogRotatorTests {
    @Test func prunesOldLogsOnly() throws {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("kambucha-logs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        let old = d.appendingPathComponent("old.log"), new = d.appendingPathComponent("new.log")
        try Data("x".utf8).write(to: old); try Data("x".utf8).write(to: new)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: old.path)
        try LogRotator.prune(d, olderThan: Date(timeIntervalSince1970: 2_000))
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: new.path))
        try LogRotator.prune(d.appendingPathComponent("missing"), olderThan: Date())
    }

    @Test func continuesPastRemovalError() throws {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("kambucha-logs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        let stuck = d.appendingPathComponent("a-stuck.log"), other = d.appendingPathComponent("b-old.log")
        for u in [stuck, other] {
            try Data("x".utf8).write(to: u)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: u.path)
        }
        chflags(stuck.path, UInt32(UF_IMMUTABLE))
        defer { chflags(stuck.path, 0) }
        #expect(throws: (any Error).self) { try LogRotator.prune(d, olderThan: Date(timeIntervalSince1970: 2_000)) }
        #expect(!FileManager.default.fileExists(atPath: other.path))
    }
}
