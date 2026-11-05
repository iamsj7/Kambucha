import Testing
import Foundation
@testable import KambuchaCore

@Suite struct ExcludeRuleTests {
    /// What rclone really keeps of `root` under these rules, listed the way a run reads a source.
    func kept(_ root: URL, _ rules: [UserRule]) async throws -> Set<String> {
        let filter = root.deletingLastPathComponent().appendingPathComponent("filter-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: filter) }
        let lines = rules.map { "\($0.action == .include ? "+" : "-") \($0.pattern)\n" }.joined()
        try Data(lines.utf8).write(to: filter)
        let out = try await realRunner().capture(["lsf", "-R", "--links", "--files-only", "--filter-from", filter.path,
                                                  "--config", plainContext.configPath, root.path], context: plainContext)
        #expect(out.exitCode == 0)
        return Set(out.stdout.split(separator: "\n").map(String.init))
    }

    func rig() throws -> (ArchiveSandbox, URL, BackupSet) {
        let box = try ArchiveSandbox()
        let source = try box.dir("home/proj")
        for f in ["keep.txt", "Drafts/a.txt", "Drafts/sub/b.txt", "app/Drafts/c.txt", "app/secret.psd", "a[1]/b c/x*y.txt"] {
            try box.write(f, "x", under: source)
        }
        return (box, source, BackupSet(name: "P", source: source))
    }

    @Test func aFolderLeavesWithEverythingInIt() async throws {
        let (box, source, set) = try rig(); defer { withExtendedLifetime(box) {} }
        let r = ExcludeRule.adding([source.appendingPathComponent("Drafts")], to: set)
        #expect(r.rules.map(\.pattern) == ["/Drafts/**"] && r.rules[0].action == .exclude)
        #expect(try await kept(source, r.rules) == ["keep.txt", "app/Drafts/c.txt", "app/secret.psd", "a[1]/b c/x*y.txt"])
    }

    @Test func aFileLeavesAloneAndOnlyThatOne() async throws {
        let (box, source, set) = try rig(); defer { withExtendedLifetime(box) {} }
        try box.write("secret.psd", "x", under: source)
        let r = ExcludeRule.adding([source.appendingPathComponent("app/secret.psd")], to: set)
        #expect(r.rules.map(\.pattern) == ["/app/secret.psd"])
        let left = try await kept(source, r.rules)
        #expect(!left.contains("app/secret.psd") && left.contains("secret.psd"))
    }

    @Test func oddNamesAreTakenLiterally() async throws {
        let (box, source, set) = try rig(); defer { withExtendedLifetime(box) {} }
        let r = ExcludeRule.adding([source.appendingPathComponent("a[1]/b c/x*y.txt")], to: set)
        #expect(!(try await kept(source, r.rules)).contains("a[1]/b c/x*y.txt"))
        let folder = ExcludeRule.adding([source.appendingPathComponent("a[1]")], to: set)
        #expect(!(try await kept(source, folder.rules)).contains("a[1]/b c/x*y.txt"))
    }

    /// With `--links` rclone names a link `<name>.rclonelink`, so a rule for the plain name catches nothing.
    @Test func aLinkLeavesAsALinkAndItsTargetStays() async throws {
        let (box, source, set) = try rig(); defer { withExtendedLifetime(box) {} }
        let link = source.appendingPathComponent("shortcut")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "Drafts")
        #expect(try await kept(source, []).contains("shortcut.rclonelink"))
        let r = ExcludeRule.adding([link], to: set)
        let left = try await kept(source, r.rules)
        #expect(!left.contains("shortcut.rclonelink") && left.contains("Drafts/a.txt"))
    }

    @Test func aPickBeatsAWiderInclude() async throws {
        let (box, source, base) = try rig(); defer { withExtendedLifetime(box) {} }
        var set = base
        set.rules = [UserRule(pattern: "/Drafts/**", action: .include), UserRule(pattern: "*.txt", action: .include)]
        let r = ExcludeRule.adding([source.appendingPathComponent("Drafts")], to: set)
        #expect(r.rules.map(\.pattern) == ["/Drafts/**", "*.txt"] && r.rules[0].action == .exclude)
        #expect(!(try await kept(source, r.rules)).contains("Drafts/a.txt"))
    }

    @Test func pickingTwiceAddsOneRule() throws {
        let (box, source, set) = try rig(); defer { withExtendedLifetime(box) {} }
        let item = source.appendingPathComponent("keep.txt")
        let once = ExcludeRule.adding([item, item], to: set)
        var again = set; again.rules = once.rules
        #expect(ExcludeRule.adding([item], to: again).rules.map(\.pattern) == ["/keep.txt"])
    }

    @Test func theSetsOwnFolderAndAnythingOutsideAreLeftOut() throws {
        let (box, source, set) = try rig(); defer { withExtendedLifetime(box) {} }
        let outside = try box.dir("home/projects-other")
        let r = ExcludeRule.adding([source, outside, source.deletingLastPathComponent(), source.appendingPathComponent("keep.txt")], to: set)
        #expect(r.rules.map(\.pattern) == ["/keep.txt"] && r.outside == 3)
    }

    @Test func aSpelledDifferentlySourceStillMatches() throws {
        let (box, source, set) = try rig(); defer { withExtendedLifetime(box) {} }
        let alias = box.root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source)
        var viaLink = set; viaLink.source = alias
        let r = ExcludeRule.adding([source.resolvingSymlinksInPath().appendingPathComponent("keep.txt")], to: viaLink)
        #expect(r.rules.map(\.pattern) == ["/keep.txt"] && r.outside == 0)
    }

    /// A scheduled run narrows to one top-level folder. The rule must hold there too.
    @Test func thePickedRuleSurvivesAScopedRun() throws {
        let (box, source, base) = try rig(); defer { withExtendedLifetime(box) {} }
        var set = base
        set.rules = ExcludeRule.adding([source.appendingPathComponent("app/secret.psd"), source.appendingPathComponent("Drafts")], to: set).rules
        let builder = FilterBuilder(presets: [])
        #expect(builder.lines(for: set, projects: [], scope: "app").contains("- /secret.psd"))
        #expect(builder.lines(for: set, projects: [], scope: "Drafts").contains("- /**"))
    }
}
