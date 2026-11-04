import Testing
import Foundation
@testable import MirrorCore

@Suite struct ArchiveManagerTests {
    func manager(_ box: ArchiveSandbox, kind: DestinationKind = .iCloudFolder,
                 evict: @escaping @Sendable (URL) throws -> Void = { _ in }) -> ArchiveManager {
        ArchiveManager(rclone: realRunner(), endpoint: box.root.path, context: plainContext, kind: kind,
                       isUploaded: { _ in true }, evict: evict)
    }

    @Test func pruneRemovesOnlyExpiredStamps() async throws {
        let box = try ArchiveSandbox()
        try box.write("Archive/Projects/2026-09-01T10-00/old.txt")
        try box.write("Archive/Projects/2026-10-30T10-00/new.txt")
        try box.write("Archive/Other/2026-01-01T10-00/keep.txt")
        try box.write("Sets/Projects/live.txt")
        try await manager(box).prune(set: makeSet(), now: utc("2026-11-04T10-00"))
        #expect(!box.exists("Archive/Projects/2026-09-01T10-00"))
        #expect(box.exists("Archive/Projects/2026-10-30T10-00/new.txt"))
        #expect(box.exists("Archive/Other/2026-01-01T10-00/keep.txt"))
        #expect(box.exists("Sets/Projects/live.txt"))
    }

    @Test func pruneRefusesPathsOutsideArchive() async throws {
        let box = try ArchiveSandbox()
        try box.write("Sets/Projects/2020-01-01T10-00/precious.txt")
        let m = manager(box)
        await #expect(throws: ArchiveError.self) { try await m.prune(set: makeSet("../Sets/Projects"), now: Date()) }
        await #expect(throws: ArchiveError.self) { try await m.prune(set: makeSet(".."), now: Date()) }
        // Archive/Projects is a link out to the mirror: canonical path leaves Archive/.
        try box.dir("Archive")
        try FileManager.default.createSymbolicLink(
            atPath: box.root.appendingPathComponent("Archive/Projects").path,
            withDestinationPath: box.root.appendingPathComponent("Sets/Projects").path)
        await #expect(throws: ArchiveError.self) { try await m.prune(set: makeSet("Projects"), now: Date()) }
        #expect(box.exists("Sets/Projects/2020-01-01T10-00/precious.txt"))
        #expect(throws: ArchiveError.self) { try m.target(makeSet("Projects"), stamp: "../x") }
    }

    @Test func evictNeverTouchesMirror() throws {
        let box = try ArchiveSandbox()
        try box.write("Sets/Projects/live.txt")
        try box.write("Archive/Projects/2026-10-30T10-00/a.txt")
        try box.write("Archive/Projects/2026-10-30T10-00/sub/b.txt")
        try box.write("Archive/Other/2026-10-30T10-00/c.txt")
        let seen = Seen()
        let n = try manager(box, evict: { seen.add($0.path) }).evictUploaded(set: makeSet())
        #expect(n == 2)
        #expect(seen.all.allSatisfy { $0.contains("/Archive/Projects/") })
        #expect(!seen.all.contains { $0.contains("/Sets/") || $0.contains("/Archive/Other/") })
    }

    @Test func evictIsICloudOnly() throws {
        let box = try ArchiveSandbox()
        try box.write("Archive/Projects/2026-10-30T10-00/a.txt")
        let seen = Seen()
        for kind in [DestinationKind.googleDrive, .oneDrive] {
            #expect(try manager(box, kind: kind, evict: { seen.add($0.path) }).evictUploaded(set: makeSet()) == 0)
        }
        #expect(seen.all.isEmpty)
        // A file that iCloud has not finished uploading is never freed.
        let m = ArchiveManager(rclone: realRunner(), endpoint: box.root.path, context: plainContext, kind: .iCloudFolder,
                               isUploaded: { _ in false }, evict: { seen.add($0.path) })
        #expect(try m.evictUploaded(set: makeSet()) == 0)
        #expect(seen.all.isEmpty)
    }

    @Test func archiveWorksThroughLocalCryptRemote() async throws {
        let box = try ArchiveSandbox()
        let store = try box.dir("store")
        let obscured = try await realRunner().capture(["obscure", "correct horse"], context: plainContext)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let ctx = RcloneContext(configPath: "/dev/null", environment: [
            "RCLONE_CONFIG_CR_TYPE": "crypt", "RCLONE_CONFIG_CR_REMOTE": store.path, "RCLONE_CONFIG_CR_PASSWORD": obscured])
        let r = realRunner()
        let src = try box.dir("src")
        try box.write("note.txt", "hello", under: src)
        for stamp in ["2026-09-01T10-00", "2026-10-30T10-00"] {
            let out = try await r.capture(["copy", src.path, "CR:Archive/Projects/\(stamp)", "--config", "/dev/null"], context: ctx)
            #expect(out.exitCode == 0)
        }
        // On disk the names are scrambled.
        #expect(!FileManager.default.fileExists(atPath: store.appendingPathComponent("Archive").path))
        let m = ArchiveManager(rclone: r, endpoint: "CR:", context: ctx, kind: .googleDrive)
        let entries = try await m.list(set: makeSet())
        #expect(entries.count == 2)
        #expect(entries.allSatisfy { $0.path.hasSuffix("/note.txt") && $0.size == 5 && $0.setName == "Projects" })
        #expect(entries.first?.stamp == utc("2026-10-30T10-00"))
        try await m.prune(set: makeSet(), now: utc("2026-11-04T10-00"))
        #expect(try await m.list(set: makeSet()).count == 1)
        #expect(try await m.list(set: makeSet("Nothing")).isEmpty)
    }
}

final class Seen: @unchecked Sendable {
    private let lock = NSLock(); private var items: [String] = []
    func add(_ s: String) { lock.withLock { items.append(s) } }
    var all: [String] { lock.withLock { items } }
}
