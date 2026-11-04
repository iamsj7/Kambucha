import Testing
import Foundation
@testable import MirrorCore

struct FilterBuilderTests {
    let presets: [Preset]
    let builder: FilterBuilder
    init() throws { presets = try PresetCatalog.all(); builder = FilterBuilder(presets: presets) }

    func set(_ ids: Set<String> = ["node", "flutter"], secrets: Bool = true, git: Bool = true,
             rules: [UserRule] = []) -> BackupSet {
        var s = BackupSet(name: "t", source: URL(fileURLWithPath: "/tmp/src"), presets: ids)
        s.backupSecrets = secrets; s.backupGit = git; s.rules = rules
        return s
    }
    let projects = [DetectedProject(relativePath: "flowapp", presetIDs: ["node"])]

    @Test func unambiguousJunkPrunedAnywhere() {
        #expect(builder.lines(for: set(), projects: projects, scope: nil).contains("- node_modules/**"))
    }

    @Test func ambiguousOnlyBesideMarker() {
        let lines = builder.lines(for: set(), projects: projects, scope: nil)
        #expect(lines.contains("- /flowapp/dist/**"))
        #expect(!lines.contains { $0.contains("/notes/dist") })
        #expect(!lines.contains("- dist/**"))
    }

    @Test func nestedProjectIsDetected() {
        let p = [DetectedProject(relativePath: "apps/web", presetIDs: ["node"])]
        #expect(builder.lines(for: set(), projects: p, scope: nil).contains("- /apps/web/dist/**"))
    }

    @Test func rootProjectAnchorsAtRoot() {
        let p = [DetectedProject(relativePath: ".", presetIDs: ["node"])]
        #expect(builder.lines(for: set(), projects: p, scope: nil).contains("- /dist/**"))
    }

    @Test func disabledPresetContributesNothing() {
        let lines = builder.lines(for: set(["flutter"]), projects: projects, scope: nil)
        #expect(!lines.contains("- node_modules/**"))
        #expect(!lines.contains("- /flowapp/dist/**"))
        #expect(lines.contains("- .dart_tool/**"))
    }

    @Test func userRulesComeFirst() {
        let rules = [UserRule(pattern: "/flowapp/dist/keep.txt", action: .include),
                     UserRule(pattern: "*.log", action: .exclude)]
        let lines = builder.lines(for: set(rules: rules), projects: projects, scope: nil)
        #expect(lines.first == "+ /flowapp/dist/keep.txt")
        #expect(lines[1] == "- *.log")
    }

    @Test func orderIsSwitchesThenUserThenPresets() throws {
        let rules = [UserRule(pattern: "/u", action: .include)]
        let lines = builder.lines(for: set(secrets: false, git: false, rules: rules), projects: projects, scope: nil)
        let u = try #require(lines.firstIndex(of: "+ /u"))
        let s = try #require(lines.firstIndex(of: "- .env*"))
        let g = try #require(lines.firstIndex(of: "- .git/**"))
        let m = try #require(lines.firstIndex(of: "- .DS_Store"))
        let a = try #require(lines.firstIndex(of: "- node_modules/**"))
        let d = try #require(lines.firstIndex(of: "- /flowapp/dist/**"))
        #expect(s < g && g < u && u < m && m < a && a < d)
    }

    @Test func secretsOnAddsNoSecretExcludes() {
        let lines = builder.lines(for: set(secrets: true), projects: projects, scope: nil)
        #expect(!lines.contains("- .env*")); #expect(!lines.contains("- *.pem"))
    }

    @Test func secretsOffExcludesAllPatterns() {
        let lines = builder.lines(for: set(secrets: false), projects: projects, scope: nil)
        for p in PresetCatalog.secretPatterns { #expect(lines.contains("- \(p)")) }
    }

    @Test func gitOffExcludesGit() {
        #expect(builder.lines(for: set(git: false), projects: [], scope: nil).contains("- .git/**"))
        #expect(!builder.lines(for: set(git: true), projects: [], scope: nil).contains("- .git/**"))
    }

    @Test func gitignoreIsIgnored() throws {
        let root = try makeTree(["package.json", ".gitignore"])
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(".env\nsecret.txt\n".utf8).write(to: root.appendingPathComponent(".gitignore"))
        let det = StackDetector(presets: presets)
        let withIgnore = builder.lines(for: set(), projects: det.detect(in: root), scope: nil)
        try FileManager.default.removeItem(at: root.appendingPathComponent(".gitignore"))
        let without = builder.lines(for: set(), projects: det.detect(in: root), scope: nil)
        #expect(withIgnore == without)
        #expect(!withIgnore.contains { $0.contains("secret.txt") })
    }

    @Test func macOSExcludesAlwaysPresent() {
        let lines = builder.lines(for: set([]), projects: [], scope: nil)
        #expect(lines.contains("- .DS_Store")); #expect(lines.contains("- .Trash/**"))
    }

    @Test func noTrailingCatchAll() {
        let lines = builder.lines(for: set(), projects: projects, scope: nil)
        #expect(!lines.contains { $0 == "- **" || $0 == "- *" || $0 == "- /**" })
    }

    @Test func scopeRebasesAnchors() {
        let p = [DetectedProject(relativePath: "flowapp", presetIDs: ["node"]),
                 DetectedProject(relativePath: "other", presetIDs: ["node"]),
                 DetectedProject(relativePath: "flowapp/sub", presetIDs: ["node"])]
        let lines = builder.lines(for: set(), projects: p, scope: "flowapp")
        #expect(lines.contains("- /dist/**"))
        #expect(lines.contains("- /sub/dist/**"))
        #expect(!lines.contains { $0.contains("/other/") })
        #expect(!lines.contains { $0.contains("flowapp") })
    }

    @Test func scopeDoesNotConfuseSiblingPrefix() {
        let p = [DetectedProject(relativePath: "flowapp2", presetIDs: ["node"])]
        let lines = builder.lines(for: set(), projects: p, scope: "flowapp")
        #expect(!lines.contains { $0.contains("dist") })
    }

    @Test func scopeRebasesAnchoredUserRules() {
        let rules = [UserRule(pattern: "/flowapp/x.txt", action: .exclude),
                     UserRule(pattern: "/other/y.txt", action: .exclude),
                     UserRule(pattern: "*.tmp", action: .exclude)]
        let lines = builder.lines(for: set(rules: rules), projects: [], scope: "flowapp")
        #expect(lines.contains("- /x.txt")); #expect(!lines.contains { $0.contains("y.txt") })
        #expect(lines.contains("- *.tmp"))
    }

    @Test func escapesSpacesAndGlobChars() {
        #expect(FilterBuilder.escape("a[b]/c*") == "a\\[b\\]/c\\*")
        #expect(FilterBuilder.escape("Async Focus") == "Async Focus")
        #expect(FilterBuilder.escape("a{b}?\\") == "a\\{b\\}\\?\\\\")
    }

    @Test func projectPathsAreEscaped() {
        let p = [DetectedProject(relativePath: "a[b]/Async Focus", presetIDs: ["node"])]
        #expect(builder.lines(for: set(), projects: p, scope: nil).contains("- /a\\[b\\]/Async Focus/dist/**"))
    }

    @Test func writeRoundTrips() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("f-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: url) }
        try builder.write(["- a", "+ b"], to: url)
        #expect(try String(contentsOf: url, encoding: .utf8) == "- a\n+ b\n")
    }

    @Test func realRcloneHonoursFilter() throws {
        let rcloneURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("vendor/rclone/rclone")
        guard FileManager.default.isExecutableFile(atPath: rcloneURL.path) else { return }
        let root = try makeTree([
            "Async Focus/package.json", "Async Focus/dist/out.js", "Async Focus/src/a.ts",
            "Async Focus/node_modules/pkg/index.js",
            "a[b]/package.json", "a[b]/dist/out.js", "a[b]/src/b.ts",
            "notes/dist/keep.md", "notes/readme.md",
            "deep/x/node_modules/y/z.js", "deep/x/main.ts",
            "cfg/.env", "cfg/key.pem", "cfg/app.txt", ".git/HEAD", ".DS_Store", "notes/.DS_Store",
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let projects = StackDetector(presets: presets).detect(in: root)
        let filter = root.deletingLastPathComponent().appendingPathComponent("filter-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: filter) }
        try builder.write(builder.lines(for: set(["node"], secrets: false, git: false), projects: projects, scope: nil), to: filter)

        func rclone(_ extra: String) throws -> Set<String> {
            let p = Process()
            p.executableURL = rcloneURL
            p.arguments = ["--config", "/dev/null", "lsf", "-R", extra, "--filter-from", filter.path, root.path]
            let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
            try p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            #expect(p.terminationStatus == 0)
            return Set(String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init))
        }
        // Directory excludes must prune the folder itself, not just hide its files.
        let dirs = try rclone("--dirs-only")
        #expect(!dirs.contains { $0.contains("node_modules") })
        #expect(!dirs.contains("a[b]/dist/") && !dirs.contains("Async Focus/dist/"))
        #expect(dirs.contains("notes/dist/"))
        let got = try rclone("--files-only")
        #expect(got == [
            "Async Focus/package.json", "Async Focus/src/a.ts",
            "a[b]/package.json", "a[b]/src/b.ts",
            "notes/dist/keep.md", "notes/readme.md",
            "deep/x/main.ts", "cfg/app.txt",
        ])
    }
}
