import Testing
import Foundation
@testable import MirrorCore

@Suite struct RestoreServiceTests {
    func rig() throws -> (ArchiveSandbox, URL) {
        let box = try ArchiveSandbox()
        try box.write("Archive/Projects/2026-10-30T10-00/app/main.txt", "v1")
        return (box, box.root.appendingPathComponent("Archive/Projects/2026-10-30T10-00/app"))
    }

    @Test func restoreRefusesOverSourceByDefault() async throws {
        let (box, from) = try rig()
        let source = try box.dir("home/proj")
        let svc = RestoreService(rclone: realRunner())
        for dest in [source, source.appendingPathComponent("sub"), box.root.appendingPathComponent("home")] {
            await #expect(throws: RestoreError.self) {
                _ = try await svc.restore(from: from.path, context: plainContext, to: dest, sources: [source])
            }
        }
        #expect(!box.exists("home/proj/main.txt"))
        let r = try await svc.restore(from: from.path, context: plainContext, to: source, sources: [source], overwrite: true)
        #expect(r.outcome == .success)
        #expect(box.exists("home/proj/main.txt"))
    }

    @Test func restoreRefusesAnythingOutsideArchive() async throws {
        let (box, _) = try rig()
        try box.write("Sets/Projects/live.txt")
        let svc = RestoreService(rclone: realRunner())
        let to = box.root.appendingPathComponent("out")
        await #expect(throws: ArchiveError.self) {
            _ = try await svc.restore(from: box.root.appendingPathComponent("Sets/Projects").path, context: plainContext, to: to)
        }
        await #expect(throws: ArchiveError.self) {
            _ = try await svc.restore(from: box.root.appendingPathComponent("Archive/../Sets").path, context: plainContext, to: to)
        }
        let pinned = RestoreService(rclone: realRunner(), archiveRoot: box.root.appendingPathComponent("Archive").path)
        await #expect(throws: ArchiveError.self) {
            _ = try await pinned.restore(from: box.root.path, context: plainContext, to: to)
        }
        #expect(!box.exists("out"))
    }

    @Test func restoreKeepsSymlinks() async throws {
        let (box, from) = try rig()
        try FileManager.default.createSymbolicLink(atPath: from.appendingPathComponent("link").path, withDestinationPath: "main.txt")
        let to = box.root.appendingPathComponent("restored")
        let r = try await RestoreService(rclone: realRunner()).restore(from: from.path, context: plainContext, to: to)
        #expect(r.outcome == .success)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: to.appendingPathComponent("link").path) == "main.txt")
        #expect(!FileManager.default.fileExists(atPath: to.appendingPathComponent("link.rclonelink").path))
    }

    @Test func restoreRecreatesLinksMissingFromRestoredFiles() async throws {
        let (box, from) = try rig()
        let manifest = SymlinkManifest(set: "Projects", entries: [
            .init(path: "app/link", target: "main.txt", isAbsolute: false, isBroken: false),
            .init(path: "app/deep/gone", target: "/nowhere", isAbsolute: true, isBroken: true),
            .init(path: "other/skip", target: "x", isAbsolute: false, isBroken: false),
            .init(path: "app/main.txt", target: "x", isAbsolute: false, isBroken: false),
            .init(path: "app/../escape", target: "x", isAbsolute: false, isBroken: false),
        ])
        let to = box.root.appendingPathComponent("restored")
        _ = try await RestoreService(rclone: realRunner()).restore(
            from: from.path, context: plainContext, to: to, manifest: manifest, manifestSubpath: "app")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: to.appendingPathComponent("link").path) == "main.txt")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: to.appendingPathComponent("deep/gone").path) == "/nowhere")
        #expect(try String(contentsOf: to.appendingPathComponent("main.txt"), encoding: .utf8) == "v1")   // untouched
        #expect(!FileManager.default.fileExists(atPath: to.appendingPathComponent("skip").path))
        #expect(!box.exists("escape"))
    }

    @Test func manifestRecordsRelativeAbsoluteAndBrokenLinks() throws {
        let box = try ArchiveSandbox()
        let src = try box.dir("src")
        try box.write("a/real.txt", under: src)
        try box.write("node_modules/.bin/tool", under: src)
        let fm = FileManager.default
        try fm.createSymbolicLink(atPath: src.appendingPathComponent("a/rel").path, withDestinationPath: "real.txt")
        try fm.createSymbolicLink(atPath: src.appendingPathComponent("abs").path, withDestinationPath: src.appendingPathComponent("a/real.txt").path)
        try fm.createSymbolicLink(atPath: src.appendingPathComponent("a/dead").path, withDestinationPath: "missing")
        try fm.createSymbolicLink(atPath: src.appendingPathComponent("node_modules/.bin/lnk").path, withDestinationPath: "tool")
        let m = SymlinkManifest.scan(set: makeSet(), source: src, skipDirectory: { $0 == "node_modules" })
        #expect(m.entries.map(\.path) == ["a/dead", "a/rel", "abs"])
        let by = Dictionary(uniqueKeysWithValues: m.entries.map { ($0.path, $0) })
        #expect(by["a/rel"] == .init(path: "a/rel", target: "real.txt", isAbsolute: false, isBroken: false))
        #expect(by["abs"]?.isAbsolute == true && by["abs"]?.isBroken == false)
        #expect(by["a/dead"]?.isBroken == true && by["a/dead"]?.isAbsolute == false)
    }

    @Test func manifestWrittenOutsideSetsFolder() throws {
        let box = try ArchiveSandbox()
        let root = try box.dir("Mac Backup")
        let m = SymlinkManifest(set: "Projects", entries: [.init(path: "l", target: "t", isAbsolute: false, isBroken: false)])
        let file = try m.write(backupRoot: root)
        #expect(file.path == root.appendingPathComponent("Manifests/Projects.json").path)
        #expect(!file.path.contains("/Sets/"))
        #expect(!box.exists("Mac Backup/Sets"))
        #expect(try SymlinkManifest.read(set: "Projects", backupRoot: root) == m)
        #expect(throws: ArchiveError.self) { try SymlinkManifest(set: "../Sets/x", entries: []).write(backupRoot: root) }
    }
}
