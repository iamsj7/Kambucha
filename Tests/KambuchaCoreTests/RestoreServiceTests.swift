import Testing
import Foundation
@testable import KambuchaCore

@Suite struct RestoreServiceTests {
    func rig() throws -> (ArchiveSandbox, URL) {
        let box = try ArchiveSandbox()
        try box.write("Archive/Projects/2026-10-30T10-00/app/main.txt", "v1")
        return (box, box.root.appendingPathComponent("Archive/Projects/2026-10-30T10-00/app"))
    }

    @Test func restoreRefusesOverSourceByDefault() async throws {
        let (box, from) = try rig()
        let source = try box.dir("home/proj")
        let svc = RestoreService(rclone: realRunner(), backupRoot: box.root.path)
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

    @Test func restoreRefusesAnythingOutsideSetsAndArchive() async throws {
        let (box, _) = try rig()
        try box.write("Manifests/Projects.json", "[]")
        try box.write("Sets/Projects/live.txt")
        let svc = RestoreService(rclone: realRunner(), backupRoot: box.root.path)
        let to = box.root.appendingPathComponent("out")
        let bad = [box.root.appendingPathComponent("Manifests").path, box.root.path,
                   box.root.appendingPathComponent("Archive").path,                          // no set
                   box.root.appendingPathComponent("Archive/Projects").path,                 // no stamp
                   box.root.appendingPathComponent("Archive/Projects/not-a-stamp/app").path,
                   box.root.appendingPathComponent("Sets").path,                             // no set
                   box.root.appendingPathComponent("Sets/../Manifests").path,
                   box.root.appendingPathComponent("Archive/../Manifests").path]
        for from in bad {
            await #expect(throws: ArchiveError.self) {
                _ = try await svc.restore(from: from, context: plainContext, to: to, sources: [])
            }
        }
        let pinned = RestoreService(rclone: realRunner(), backupRoot: box.root.path)
        await #expect(throws: ArchiveError.self) {
            _ = try await pinned.restore(from: box.root.deletingLastPathComponent().path, context: plainContext, to: to, sources: [])
        }
        // A link in Sets/ that leads out of the backup is refused by the canonical check.
        try FileManager.default.createSymbolicLink(atPath: box.root.appendingPathComponent("Sets/escape").path,
                                                   withDestinationPath: box.root.appendingPathComponent("Manifests").path)
        await #expect(throws: ArchiveError.self) {
            _ = try await pinned.restore(from: box.root.appendingPathComponent("Sets/escape").path, context: plainContext, to: to, sources: [])
        }
        #expect(!box.exists("out"))
    }

    @Test func symlinkedSetsOrArchiveFolderIsRefused() async throws {
        let box = try ArchiveSandbox()
        let elsewhere = try box.dir("elsewhere"); try box.write("Projects/x.txt", "secret", under: elsewhere)
        let fm = FileManager.default
        try fm.createSymbolicLink(atPath: box.root.appendingPathComponent("Sets").path, withDestinationPath: elsewhere.path)
        try fm.createSymbolicLink(atPath: box.root.appendingPathComponent("Archive").path, withDestinationPath: elsewhere.path)
        let svc = RestoreService(rclone: realRunner(), backupRoot: box.root.path)
        let to = box.root.appendingPathComponent("out")
        for from in ["Sets/Projects", "Archive/Projects/2026-10-30T10-00"] {
            await #expect(throws: ArchiveError.self) {
                _ = try await svc.restore(from: box.root.appendingPathComponent(from).path, context: plainContext, to: to, sources: [])
            }
        }
        #expect(!box.exists("out"))
    }

    @Test func localRestoreWithoutBackupRootIsRefused() async throws {
        let (box, from) = try rig()
        await #expect(throws: ArchiveError.self) {
            _ = try await RestoreService(rclone: realRunner()).restore(from: from.path, context: plainContext,
                                                                       to: box.root.appendingPathComponent("o"), sources: [])
        }
    }

    @Test func optionLikeAndRelativeAndOddRemoteSourcesAreRefused() async throws {
        let box = try ArchiveSandbox()
        let svc = RestoreService(rclone: realRunner(), backupRoot: box.root.path)
        let remoteSvc = RestoreService(rclone: realRunner())
        let to = box.root.appendingPathComponent("out")
        for from in ["-Sets/x", "--config=/x/Sets/y", ":local:/tmp/Sets/x", "Sets/Projects", "./Sets/Projects"] {
            await #expect(throws: ArchiveError.self) {
                _ = try await svc.restore(from: from, context: plainContext, to: to, sources: [])
            }
        }
        for from in ["a,b:Sets/Projects", "a:b:Sets/Projects", "-r:Sets/Projects", ":Sets/Projects"] {
            await #expect(throws: ArchiveError.self) {
                _ = try await remoteSvc.restore(from: from, context: plainContext, to: to, sources: [])
            }
        }
        #expect(!box.exists("out"))
    }

    func wholeProject(_ box: ArchiveSandbox, in base: URL) throws {
        try box.write("Sets/Projects/app/main.txt", "v1", under: base)
        try box.write("Sets/Projects/app/sub/deep.txt", "v2", under: base)
        try FileManager.default.createSymbolicLink(
            atPath: base.appendingPathComponent("Sets/Projects/app/link").path, withDestinationPath: "main.txt")
    }
    let manifest = SymlinkManifest(set: "Projects", entries: [
        .init(path: "app/link", target: "main.txt", isAbsolute: false, isBroken: false),
        .init(path: "app/sub/lost", target: "../main.txt", isAbsolute: false, isBroken: false)])

    @Test func restoreWholeProjectFromSetsLocal() async throws {
        let box = try ArchiveSandbox(); try wholeProject(box, in: box.root)
        let to = box.root.appendingPathComponent("restored")
        let svc = RestoreService(rclone: realRunner(), backupRoot: box.root.path)
        let r = try await svc.restore(from: box.root.appendingPathComponent("Sets/Projects").path, context: plainContext,
                                      to: to, sources: [box.root.appendingPathComponent("src")], manifest: manifest)
        #expect(r.outcome == .success)
        #expect(try String(contentsOf: to.appendingPathComponent("app/sub/deep.txt"), encoding: .utf8) == "v2")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: to.appendingPathComponent("app/link").path) == "main.txt")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: to.appendingPathComponent("app/sub/lost").path) == "../main.txt")
        // One file, and a sub folder, also come from Sets/.
        let one = box.root.appendingPathComponent("one")
        _ = try await svc.restore(from: box.root.appendingPathComponent("Sets/Projects/app/sub").path, context: plainContext,
                                  to: one, sources: [], manifest: manifest, manifestSubpath: "app/sub")
        #expect(box.exists("one/deep.txt"))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: one.appendingPathComponent("lost").path) == "../main.txt")
    }

    @Test func restoreWholeProjectFromSetsThroughCrypt() async throws {
        let box = try ArchiveSandbox()
        let store = try box.dir("store"); let src = try box.dir("srcmirror")
        try wholeProject(box, in: src)
        let obscured = try await realRunner().capture(["obscure", "pw"], context: plainContext)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let ctx = RcloneContext(configPath: "/dev/null", environment: [
            "RCLONE_CONFIG_CR_TYPE": "crypt", "RCLONE_CONFIG_CR_REMOTE": store.path, "RCLONE_CONFIG_CR_PASSWORD": obscured])
        let up = try await realRunner().capture(["copy", src.appendingPathComponent("Sets/Projects").path, "CR:Sets/Projects",
                                                 "--links", "--config", "/dev/null"], context: ctx)
        #expect(up.exitCode == 0)
        let to = box.root.appendingPathComponent("restored")
        let svc = RestoreService(rclone: realRunner(), backupRoot: "CR:")
        let r = try await svc.restore(from: "CR:Sets/Projects", context: ctx, to: to, sources: [], manifest: manifest)
        #expect(r.outcome == .success)
        #expect(try String(contentsOf: to.appendingPathComponent("app/main.txt"), encoding: .utf8) == "v1")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: to.appendingPathComponent("app/link").path) == "main.txt")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: to.appendingPathComponent("app/sub/lost").path) == "../main.txt")
        await #expect(throws: ArchiveError.self) {
            _ = try await svc.restore(from: "CR:Manifests", context: ctx, to: box.root.appendingPathComponent("x"), sources: [])
        }
    }

    @Test func restoringOntoASourceIsRefused() async throws {
        let box = try ArchiveSandbox(); try wholeProject(box, in: box.root)
        let source = try box.dir("home/proj")
        let svc = RestoreService(rclone: realRunner(), backupRoot: box.root.path)
        let from = box.root.appendingPathComponent("Sets/Projects").path
        await #expect(throws: RestoreError.overSource(source.path)) {
            _ = try await svc.restore(from: from, context: plainContext, to: source, sources: [source])
        }
        #expect(!box.exists("home/proj/app"))
    }

    @Test func aDeletedFileGoesBackInsideItsSource() async throws {
        let box = try ArchiveSandbox()
        try box.write("Archive/Projects/2026-10-30T10-00/notes/gone.txt", "kept")
        let source = try box.dir("home/proj")
        let to = source.appendingPathComponent("notes/gone.txt")
        let from = box.root.appendingPathComponent("Archive/Projects/2026-10-30T10-00/notes/gone.txt").path
        let svc = RestoreService(rclone: realRunner(), backupRoot: box.root.path)
        let r = try await svc.restore(from: from, context: plainContext, to: to, sources: [source], asFile: true)
        #expect(r.outcome == .success)
        #expect(try String(contentsOf: to, encoding: .utf8) == "kept")
    }

    @Test func aFileInsideASourceIsReplacedOnlyWithAgreement() async throws {
        let box = try ArchiveSandbox()
        try box.write("Archive/Projects/2026-10-30T10-00/a.txt", "old")
        let source = try box.dir("home/proj"); try box.write("a.txt", "new", under: source)
        let to = source.appendingPathComponent("a.txt")
        let from = box.root.appendingPathComponent("Archive/Projects/2026-10-30T10-00/a.txt").path
        let svc = RestoreService(rclone: realRunner(), backupRoot: box.root.path)
        await #expect(throws: RestoreError.destinationNotEmpty(to.path)) {
            _ = try await svc.restore(from: from, context: plainContext, to: to, sources: [source], asFile: true)
        }
        #expect(try String(contentsOf: to, encoding: .utf8) == "new")
        _ = try await svc.restore(from: from, context: plainContext, to: to, sources: [source], asFile: true, replacingFile: true)
        #expect(try String(contentsOf: to, encoding: .utf8) == "old")
    }

    @Test func aFileNeverTakesTheSourceFolderOrAFolderHoldingIt() async throws {
        let box = try ArchiveSandbox()
        try box.write("Archive/Projects/2026-10-30T10-00/a.txt", "old")
        let source = try box.dir("home/proj")
        let from = box.root.appendingPathComponent("Archive/Projects/2026-10-30T10-00/a.txt").path
        let svc = RestoreService(rclone: realRunner(), backupRoot: box.root.path)
        for to in [source, box.root.appendingPathComponent("home")] {
            await #expect(throws: RestoreError.overSource(source.path)) {
                _ = try await svc.restore(from: from, context: plainContext, to: to, sources: [source], asFile: true, replacingFile: true)
            }
        }
    }

    @Test func aFolderStillCannotGoInsideASource() async throws {
        let (box, from) = try rig()
        let source = try box.dir("home/proj")
        let svc = RestoreService(rclone: realRunner(), backupRoot: box.root.path)
        await #expect(throws: RestoreError.overSource(source.path)) {
            _ = try await svc.restore(from: from.path, context: plainContext, to: source.appendingPathComponent("new"), sources: [source])
        }
    }

    @Test func restoreIntoNonEmptyFolderIsRefusedWithoutOverwrite() async throws {
        let box = try ArchiveSandbox(); try wholeProject(box, in: box.root)
        let to = try box.dir("dest"); try box.write("mine.txt", "keep", under: to)
        try box.write("app/main.txt", "local edit", under: to)
        let svc = RestoreService(rclone: realRunner(), backupRoot: box.root.path)
        let from = box.root.appendingPathComponent("Sets/Projects").path
        await #expect(throws: RestoreError.destinationNotEmpty(to.path)) {
            _ = try await svc.restore(from: from, context: plainContext, to: to, sources: [])
        }
        #expect(try String(contentsOf: to.appendingPathComponent("app/main.txt"), encoding: .utf8) == "local edit")
        _ = try await svc.restore(from: from, context: plainContext, to: to, sources: [], overwrite: true)
        #expect(try String(contentsOf: to.appendingPathComponent("app/main.txt"), encoding: .utf8) == "v1")
    }

    @Test func recreateMissingNeverWritesThroughRestoredSymlinkedParent() throws {
        let box = try ArchiveSandbox()
        let outside = try box.dir("outside"); let root = try box.dir("restored")
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("a").path, withDestinationPath: outside.path)
        let m = SymlinkManifest(set: "P", entries: [
            .init(path: "a/x", target: "t", isAbsolute: false, isBroken: false),
            .init(path: "a/deeper/y", target: "t", isAbsolute: false, isBroken: false),
            .init(path: "ok/z", target: "t", isAbsolute: false, isBroken: false)])
        #expect(m.recreateMissing(under: root) == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: root.appendingPathComponent("ok/z").path) == "t")
    }

    @Test func manifestIsAJSONArrayOfPathAndTarget() throws {
        let box = try ArchiveSandbox(); let root = try box.dir("Mac Backup")
        let file = try manifest.write(backupRoot: root)
        let arr = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [[String: Any]])
        #expect(arr.count == 2 && arr[0]["path"] as? String == "app/link" && arr[0]["target"] as? String == "main.txt")
        #expect(try SymlinkManifest.read(set: "Projects", backupRoot: root) == manifest)
    }

    @Test func restoreKeepsSymlinks() async throws {
        let (box, from) = try rig()
        try FileManager.default.createSymbolicLink(atPath: from.appendingPathComponent("link").path, withDestinationPath: "main.txt")
        let to = box.root.appendingPathComponent("restored")
        let r = try await RestoreService(rclone: realRunner(), backupRoot: box.root.path).restore(from: from.path, context: plainContext, to: to, sources: [])
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
        _ = try await RestoreService(rclone: realRunner(), backupRoot: box.root.path).restore(
            from: from.path, context: plainContext, to: to, sources: [], manifest: manifest, manifestSubpath: "app")
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
