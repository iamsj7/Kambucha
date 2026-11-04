import Testing
import Foundation
@testable import MirrorCore

struct TransferProgressTests {
    let pair = PairID(set: UUID(), destination: UUID())
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    func dir() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("mirror-progress-\(UUID().uuidString)") }
    func fixtureData() throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/sync-stats.jsonl"))
    }
    func fixtureLines() throws -> [Data] {
        try fixtureData().split(separator: UInt8(ascii: "\n")).map { Data($0) }
    }

    @Test func parsesRcloneStatsFromJSONLog() throws {
        let stats = try fixtureLines().compactMap { RcloneLogParser.stats(line: $0) }
        #expect(stats.count == 5)
        let mid = stats[1]
        #expect(mid.bytes == 2_125_824)
        #expect(mid.bytesTotal == 5_000_000)
        #expect(mid.speed != nil && abs(mid.speed! - 1_062_876.56) < 1)
        #expect(mid.eta == 2)
        #expect(mid.filesDone == 0 && mid.filesTotal == 2)
        let last = try #require(stats.last)
        #expect(last.filesDone == 2 && last.bytes == 5_000_000)
        #expect(RcloneLogParser.lastStats(try fixtureData()) == last)
        // First tick: speed 0 and eta null are "unknown", not zero.
        #expect(stats[0].speed == nil && stats[0].eta == nil)
    }

    @Test func missingTotalIsNil() throws {
        let line = Data(#"{"level":"notice","msg":"x","stats":{"bytes":10,"totalBytes":0,"transfers":0,"totalTransfers":0,"speed":0,"eta":null}}"#.utf8)
        let s = try #require(RcloneLogParser.stats(line: line))
        #expect(s.bytesTotal == nil && s.filesTotal == nil)
        let p = TransferProgress(pair: pair, stats: s, now: t0)
        #expect(p.bytesTotal == nil && p.fraction == nil && p.eta == nil && p.phase == .scanning)
    }

    @Test func nonStatsLineIsNil() {
        #expect(RcloneLogParser.stats(line: Data(#"{"level":"info","msg":"Copied (new)","object":"a"}"#.utf8)) == nil)
    }

    @Test func storeThrottlesToTwoSeconds() throws {
        let store = ProgressStore(root: dir())
        try store.write(TransferProgress(pair: pair, phase: .transferring, bytesDone: 1, updated: t0))
        try store.write(TransferProgress(pair: pair, phase: .transferring, bytesDone: 2, updated: t0 + 1))
        #expect(try store.all(now: t0 + 1).first?.bytesDone == 1)
        try store.write(TransferProgress(pair: pair, phase: .transferring, bytesDone: 3, updated: t0 + 2))
        #expect(try store.all(now: t0 + 2).first?.bytesDone == 3)
        try store.write(TransferProgress(pair: pair, phase: .verifying, bytesDone: 4, updated: t0 + 2.5))   // phase change passes
        #expect(try store.all(now: t0 + 3).first?.phase == .verifying)
    }

    @Test func clearedOnRunEnd() throws {
        let store = ProgressStore(root: dir())
        try store.write(TransferProgress(pair: pair, phase: .transferring, updated: t0))
        try store.clear(pair)
        try store.clear(pair)   // clearing nothing is fine
        #expect(try store.all(now: t0).isEmpty)
    }

    @Test func staleProgressIgnored() throws {
        let store = ProgressStore(root: dir())
        try store.write(TransferProgress(pair: pair, phase: .transferring, updated: t0))
        #expect(try store.all(now: t0 + 29).count == 1)
        #expect(try store.all(now: t0 + 31).isEmpty)
    }

    @Test func emptyStoreReadsEmpty() throws {
        #expect(try ProgressStore(root: dir()).all(now: t0).isEmpty)
    }

    @Test func iCloudProgressCountsFilesAndMarksEstimate() {
        let p = TransferProgress.iCloud(pair: pair, filesDone: 40, filesTotal: 100, filesPerSecond: 2, now: t0)
        #expect(p.phase == .waitingForICloud && p.bytesTotal == nil)
        #expect(p.fraction == 0.4 && p.eta == 30 && p.etaIsEstimate)
        let unknown = TransferProgress.iCloud(pair: pair, filesDone: 40, filesTotal: nil, filesPerSecond: nil, now: t0)
        #expect(unknown.fraction == nil && unknown.eta == nil)
    }

    @Test func syncArgumentsAskForLiveStats() {
        let a = RcloneCommand.arguments(CheckRequest(source: URL(fileURLWithPath: "/a"), destination: "/b", filterFile: nil,
            filesFrom: nil, sizeOnly: false, oneWay: false, cryptCheck: false,
            context: RcloneContext(configPath: "/dev/null", environment: [:]), logFile: URL(fileURLWithPath: "/l")))
        let i = a.firstIndex(of: "--stats")
        #expect(i.map { a[$0 + 1] } == "2s")
        #expect(a.contains("--stats-log-level") && a.contains("NOTICE"))
    }
}

final class StatsBox: @unchecked Sendable {
    private let lock = NSLock(); private var items: [RcloneStats] = []
    func add(_ s: RcloneStats) { lock.withLock { items.append(s) } }
    var all: [RcloneStats] { lock.withLock { items } }
}

extension TransferProgressTests {
    @Test func logTailReportsLinesAsTheyAreAppended() async throws {
        let file = dir().appendingPathExtension("jsonl")
        let lines = try fixtureLines().filter { RcloneLogParser.stats(line: $0) != nil }
        try (lines[0] + Data("\n".utf8)).write(to: file)
        let box = StatsBox()
        let task = Task { await LogTail.follow(file) { box.add($0) } }
        try await Task.sleep(for: .milliseconds(300))
        let h = try FileHandle(forWritingTo: file)
        try h.seekToEnd()
        // A line split across two writes must be reassembled, not dropped.
        let second = lines[1] + Data("\n".utf8)
        try h.write(contentsOf: second.prefix(40))
        try await Task.sleep(for: .milliseconds(1200))
        try h.write(contentsOf: second.dropFirst(40))
        try h.close()
        try await Task.sleep(for: .milliseconds(1300))
        task.cancel(); await task.value
        #expect(box.all.map(\.bytes) == [1_077_248, 2_125_824], "got \(box.all.map(\.bytes))")
    }
}
