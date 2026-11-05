import Testing
import Foundation
@testable import MirrorCore

struct ArchiveBrowsingTests {
    let stamp = "2026-11-04T10-00-30"
    func file(_ rel: String, stamp: String? = nil, date: Date = Date(timeIntervalSince1970: 1_800_000_000), set: String = "Docs", size: Int64 = 10) -> ArchiveEntry {
        let folder = stamp ?? self.stamp
        return ArchiveEntry(id: "\(set)/\(folder)/\(rel)", setName: set, stamp: date, path: "Archive/\(set)/\(folder)/\(rel)", size: size)
    }
    func listing(_ entries: [ArchiveEntry], set: String = "Docs", destination: String = "iCloud") -> ArchiveListing {
        let d = Destination(name: destination, kind: .iCloudFolder)
        return ArchiveListing(source: ArchiveSource(set: BackupSet(name: set, source: URL(fileURLWithPath: "/tmp/x"), destinationIDs: [d.id]), destination: d),
                              entries: entries)
    }

    // MARK: Grouping

    @Test func aRunCountsEverythingBelowIt() throws {
        let runs = ArchiveGrouping.runs(from: [file("a.txt", size: 1), file("p/b.txt", size: 2), file("p/q/c.txt", size: 4), file("r/d.txt", size: 8)])
        let run = try #require(runs.first)
        #expect(runs.count == 1 && run.id == "Archive/Docs/\(stamp)")
        #expect(run.fileCount == 4 && run.size == 15)
        #expect(run.root.files.map(\.path) == ["Archive/Docs/\(stamp)/a.txt"])
        #expect(run.root.folders.map(\.name) == ["p", "r"])
        // A folder's count is what restoring it brings back, subfolders included.
        let p = run.root.folders[0]
        #expect(p.path == "Archive/Docs/\(stamp)/p" && p.fileCount == 2 && p.size == 6)
        #expect(p.folders.map(\.path) == ["Archive/Docs/\(stamp)/p/q"])
    }

    @Test func runsAreNewestFirst() {
        let old = file("a.txt", stamp: "2026-11-01T10-00-00", date: Date(timeIntervalSince1970: 100))
        let new = file("a.txt", stamp: "2026-11-02T10-00-00", date: Date(timeIntervalSince1970: 200))
        #expect(ArchiveGrouping.runs(from: [old, new]).map(\.stamp) == [new.stamp, old.stamp])
    }

    @Test func twoFoldersOfTheSameMinuteStayTwoRuns() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let runs = ArchiveGrouping.runs(from: [file("a.txt", stamp: "2026-11-04T10-00", date: date), file("a.txt", stamp: "2026-11-04T10-00-00", date: date)])
        #expect(Set(runs.map(\.id)) == ["Archive/Docs/2026-11-04T10-00", "Archive/Docs/2026-11-04T10-00-00"])
    }

    @Test func namesSortTheWayFinderDoes() {
        let runs = ArchiveGrouping.runs(from: [file("report-10.pdf"), file("report-9.pdf"), file("Apple.pdf")])
        #expect(runs[0].root.files.map { ($0.path as NSString).lastPathComponent } == ["Apple.pdf", "report-9.pdf", "report-10.pdf"])
    }

    @Test func aPathThatNamesNoRunIsKeptButNotOfferedAsAFolder() throws {
        let entry = ArchiveEntry(id: "x", setName: "Docs", stamp: Date(timeIntervalSince1970: 5), path: "a/x.txt", size: 3)
        let run = try #require(ArchiveGrouping.runs(from: [entry]).first)
        #expect(run.fileCount == 1 && !run.canRestoreFolders)
    }

    @Test func nothingArchivedIsNoRuns() { #expect(ArchiveGrouping.runs(from: []).isEmpty) }

    // MARK: Search

    @Test func matchesNameOrFolderInAnyCase() {
        let l = listing([file("tax/Plan.PDF"), file("planning/notes.txt"), file("other.txt")])
        #expect(ArchiveSearch.find("plan", in: [l]).total == 2)
        #expect(ArchiveSearch.find("TAX/plan", in: [l]).total == 1)
    }

    @Test func thePartsEveryFileSharesDontMatch() {
        let l = listing([file("a.txt")], set: "Documents")
        #expect(ArchiveSearch.find("Documents", in: [l]).total == 0)
        #expect(ArchiveSearch.find("Archive", in: [l]).total == 0)
        #expect(ArchiveSearch.find("2026", in: [l]).total == 0)
    }

    @Test func everyWordHasToMatchInAnyOrder() {
        let l = listing([file("2024/tax/final plan.pdf"), file("2024/plan.pdf")])
        #expect(ArchiveSearch.find("plan   tax", in: [l]).total == 1)
    }

    @Test func accentsAndTheirTwoSpellingsMatch() {
        let composed = file("caf\u{E9}.txt"), decomposed = file("cafe\u{301}.md")
        let l = listing([composed, decomposed, file("تقرير.pdf")])
        #expect(ArchiveSearch.find("cafe", in: [l]).total == 2)
        #expect(ArchiveSearch.find("CAF\u{C9}", in: [l]).total == 2)
        #expect(ArchiveSearch.find("تقرير", in: [l]).total == 1)
    }

    /// A name made on a Mac is often stored decomposed, while what's typed is composed.
    @Test func hangulAndKanaMatchInBothSpellings() {
        for name in ["\u{D55C}\u{AE00}", "\u{304C}", "\u{30D1}\u{30B9}\u{30DD}\u{30FC}\u{30C8}"] {
            let composed = name.precomposedStringWithCanonicalMapping, decomposed = name.decomposedStringWithCanonicalMapping
            #expect(Array(composed.utf8) != Array(decomposed.utf8))
            #expect(ArchiveSearch.find(composed, in: [listing([file("\(decomposed).txt")])]).total == 1, "\(name)")
            #expect(ArchiveSearch.find(decomposed, in: [listing([file("\(composed).txt")])]).total == 1, "\(name)")
        }
    }

    @Test func aBlankQueryFindsNothing() {
        #expect(ArchiveSearch.find("   ", in: [listing([file("a.txt")])]) == ArchiveMatches())
    }

    @Test func nameMatchesComeFirstThenNewest() {
        let old = file("plan.txt", stamp: "2026-11-01T10-00-00", date: Date(timeIntervalSince1970: 100))
        let new = file("plan.txt", stamp: "2026-11-02T10-00-00", date: Date(timeIntervalSince1970: 200))
        let folder = file("plan/x.txt", stamp: "2026-11-03T10-00-00", date: Date(timeIntervalSince1970: 300))
        #expect(ArchiveSearch.find("plan", in: [listing([old, folder, new])]).hits.map(\.entry.id) == [new.id, old.id, folder.id])
    }

    @Test func theLimitKeepsTheCount() {
        let m = ArchiveSearch.find("a", in: [listing((0..<50).map { file("a\($0).txt") })], limit: 10)
        #expect(m.hits.count == 10 && m.total == 50)
    }

    @Test func theSameFileEverywhereHasADifferentIdEachTime() {
        let drive = listing([file("plan.txt", set: "Docs")], destination: "Drive")
        let cloud = listing([file("plan.txt", set: "Docs")], destination: "Cloud")
        let otherRun = listing([file("plan.txt", stamp: "2026-11-01T10-00-00"), file("plan.txt")])
        let hits = ArchiveSearch.find("plan", in: [drive, cloud, otherRun]).hits
        #expect(hits.count == 4 && Set(hits.map(\.id)).count == 4)
    }

    @Test func aHitSaysWhereItLived() {
        let hits = ArchiveSearch.find("a", in: [listing([file("p/q/a.txt"), file("a.md")])]).hits
        #expect(Set(hits.map(\.folder)) == ["p/q", ""])
        #expect(Set(hits.map(\.name)) == ["a.txt", "a.md"])
    }

    // MARK: Failures

    @Test func failuresAreToldApart() {
        #expect(ArchiveReadFailure(AgentFailure.driveNotConnected) == .driveNotConnected)
        #expect(ArchiveReadFailure(RcloneSessionError.notSignedIn) == .signInExpired)
        #expect(ArchiveReadFailure(ArchiveError.authExpired) == .signInExpired)
        #expect(ArchiveReadFailure(AgentFailure.busy) == .busy)
        #expect(ArchiveReadFailure(URLError(.timedOut)) == .unreadable)
    }

    @Test func oneDestinationIsOneLineHoweverManySetsItHolds() {
        let d = Destination(name: "SSD", kind: .externalDrive)
        func source(_ name: String) -> ArchiveSource { ArchiveSource(set: BackupSet(name: name, source: URL(fileURLWithPath: "/tmp/x")), destination: d) }
        let summary = ArchiveUnreadable.summary(of: ["B", "A"].map { (source($0), .driveNotConnected) })
        #expect(summary.map(\.sets) == [["A", "B"]])
        #expect(summary[0].text == "Drive not connected. A and B weren't searched.")
        let twin = Destination(name: "SSD", kind: .externalDrive)
        let two = ArchiveUnreadable.summary(of: [(source("A"), .driveNotConnected),
                                                 (ArchiveSource(set: BackupSet(name: "A", source: URL(fileURLWithPath: "/tmp/x")), destination: twin), .driveNotConnected)])
        #expect(Set(two.map(\.id)).count == 2)   // the same name, but two drives to plug in
        let many = ArchiveUnreadable.summary(of: ["A", "B", "C", "D"].map { (source($0), .driveNotConnected) })
        #expect(many[0].text == "Drive not connected. 4 sets weren't searched.")
    }

    // MARK: Taking turns

    @MainActor @Test func urgentWorkGoesFirstAndNoMoreThanTheLimitRun() async {
        let queue = ArchiveAgentQueue(limit: 1)
        let gate = AsyncStream<Void>.makeStream()
        var order: [String] = []
        let first = Task { await queue.turn(urgent: false) { for await _ in gate.stream { break }; order.append("first") } }
        await Task.yield()
        let pair = PairID(set: UUID(), destination: UUID())
        let slow = Task { await queue.turn(urgent: false) { order.append("slow") } }
        await Task.yield()
        let hurried = Task { await queue.turn(for: pair, urgent: false) { order.append("hurried") } }
        await Task.yield()
        let urgent = Task { await queue.turn(urgent: true) { order.append("urgent") } }
        await Task.yield()
        queue.hurry(pair)
        gate.continuation.yield()
        _ = await (first.value, slow.value, hurried.value, urgent.value)
        #expect(order == ["first", "hurried", "urgent", "slow"])
    }

    // MARK: Scale

    func measured<T>(_ label: String, within limit: Duration, _ work: () -> T) -> T {
        var result: T?
        let took = ContinuousClock().measure { result = work() }
        print("\(label): \(took)")
        #expect(took < limit, "\(label) took \(took)")
        return result!
    }

    /// Bounds are for a debug build under a parallel test run, so a tenth of them is the real figure at most.
    @Test func a100000FileArchiveWithARunOf20000() throws {
        var entries: [ArchiveEntry] = []
        for run in 0..<40 {
            let stamp = String(format: "2026-10-%02dT%02d-00-00", 1 + run / 2, run % 2 * 12)
            for i in 0..<(run == 0 ? 20_000 : 2_051) {
                entries.append(file("client-\(i % 12)/src/module-\(i % 40)/report-\(i).pdf", stamp: stamp,
                                    date: Date(timeIntervalSince1970: 1_800_000_000 + Double(run) * 43_200)))
            }
        }
        #expect(entries.count == 99_989)
        let runs = measured("group 100k", within: .seconds(20)) { ArchiveGrouping.runs(from: entries) }
        #expect(runs.count == 40 && runs.reduce(0) { $0 + $1.fileCount } == entries.count)
        let big = measured("index 100k", within: .seconds(20)) { listing(entries) }
        _ = measured("search everything", within: .seconds(5)) { ArchiveSearch.find("report", in: [big]) }
        let some = measured("search a few", within: .seconds(5)) { ArchiveSearch.find("report-19999", in: [big]) }
        #expect(some.total == 1)
    }
}
