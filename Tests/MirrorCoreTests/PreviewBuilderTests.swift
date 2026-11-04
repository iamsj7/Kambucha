import Testing
import Foundation
@testable import MirrorCore

@Suite struct PreviewBuilderTests {
    func builder() throws -> PreviewBuilder {
        PreviewBuilder(rclone: realRunner(), context: plainContext, presets: try PresetCatalog.all())
    }
    func fixture(_ box: ArchiveSandbox) throws -> BackupSet {
        let src = try box.dir("src")
        try box.write("app/package.json", String(repeating: "j", count: 10), under: src)
        try box.write("app/index.js", String(repeating: "i", count: 100), under: src)
        try box.write("app/node_modules/dep/a.js", String(repeating: "a", count: 1000), under: src)
        try box.write("app/node_modules/dep/b.js", String(repeating: "b", count: 2000), under: src)
        try box.write("app/dist/out.js", String(repeating: "o", count: 500), under: src)
        try box.write("notes/dist/keep.txt", String(repeating: "k", count: 7), under: src)   // no marker: backed up
        var set = BackupSet(name: "Projects", source: src)
        set.presets = ["node"]
        return set
    }

    @Test func previewTotalsMatchFixture() async throws {
        let box = try ArchiveSandbox(); let set = try fixture(box)
        let r = try await builder().build(set: set)
        #expect(r.includedFiles == 3)
        #expect(r.includedBytes == 10 + 100 + 7)
        #expect(r.skippedBytes == 3000 + 500)
        let nm = try #require(r.groups.first { $0.title == "node_modules/" })
        #expect(nm.fileCount == 2 && nm.bytes == 3000 && !nm.included && nm.pattern == "node_modules/**")
        let dist = try #require(r.groups.first { $0.title == "dist/" })
        #expect(dist.fileCount == 1 && dist.bytes == 500)
        #expect(r.groups.first?.title == "node_modules/")   // largest first
        #expect(r.decisions.isEmpty)
        let viaProtocol = try await (builder() as any PreviewProviding).preview(set: set)
        #expect(viaProtocol == r)
    }

    @Test func untickingGroupProducesRule() async throws {
        let box = try ArchiveSandbox(); var set = try fixture(box)
        let b = try builder()
        let r = try await b.build(set: set)
        let nm = try #require(r.groups.first { $0.title == "node_modules/" })
        let on = b.rule(for: nm, included: true), off = b.rule(for: nm, included: false)
        #expect(on.action == .include && on.pattern == "node_modules/**")
        #expect(off.action == .exclude && off.pattern == "node_modules/**")
        // Saved as a rule, the choice changes the next preview.
        set.rules = [on]
        let after = try await b.build(set: set)
        #expect(after.groups.first { $0.title == "node_modules/" }?.included == true)
        #expect(after.includedFiles == 5 && after.skippedBytes == 500)
    }

    @Test func refusedTmpInPreview() async throws {
        let box = try ArchiveSandbox(); let set = try fixture(box)
        try box.write("notes/draft.tmp", under: set.source)
        try box.write("notes/build.nosync", under: set.source)
        let r = try await builder().build(set: set)
        let refused = r.decisions.filter { $0.kind == .refusedByICloud }.map(\.path)
        #expect(refused == ["notes/build.nosync", "notes/draft.tmp"])
    }

    @Test func secretsAndTrackedFilesInExcludedFoldersAreDecisions() async throws {
        let box = try ArchiveSandbox(); let set = try fixture(box)
        try box.write("app/dist/.env", "S", under: set.source)
        try box.write("app/node_modules/dep/.env", "S", under: set.source)   // third party: ignored
        let r = try await builder().build(set: set)
        #expect(r.decisions.map(\.path) == ["app/dist/.env"])
        #expect(r.decisions.first?.kind == .secretInExcluded)
    }

    @Test func newExclusionOfMirroredFilesReported() async throws {
        let box = try ArchiveSandbox(); let set = try fixture(box)
        let mirror = try box.dir("mirror")
        for f in ["app/index.js", "app/node_modules/dep/a.js", "app/dist/out.js"] { try box.write(f, under: mirror) }
        let gone = try await builder().newlyExcluded(set: set, mirror: mirror.path)
        #expect(gone == ["app/dist/out.js", "app/node_modules/dep/a.js"])
        // Nothing is touched.
        #expect(FileManager.default.fileExists(atPath: mirror.appendingPathComponent("app/dist/out.js").path))
    }

    @Test func newlyExcludedFollowsUserRulesAndIsEmptyWhenNothingChanged() async throws {
        let box = try ArchiveSandbox(); var set = try fixture(box)
        let mirror = try box.dir("mirror")
        for f in ["app/index.js", "app/debug.log", "notes/dist/keep.txt"] { try box.write(f, under: mirror) }
        let b = try builder()
        #expect(try await b.newlyExcluded(set: set, mirror: mirror.path).isEmpty)
        set.rules = [UserRule(pattern: "*.log", action: .exclude)]
        #expect(try await b.newlyExcluded(set: set, mirror: mirror.path) == ["app/debug.log"])
        let missing = box.root.appendingPathComponent("nope").path
        await #expect(throws: PreviewError.self) { _ = try await b.newlyExcluded(set: set, mirror: missing) }
    }
}
