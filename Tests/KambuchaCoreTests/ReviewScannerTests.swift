import Testing
import Foundation
@testable import KambuchaCore

@Suite struct ReviewScannerTests {
    let scanner = ReviewScanner(filters: FilterBuilder(presets: []))

    @Test func newSecretInBuildFolderFlagged() {
        let items = scanner.secretsIn(changedExcludedPaths: ["app/build/.env", "app/dist/server.pem", "app/build/readme.md"])
        #expect(items.map(\.path) == ["app/build/.env", "app/dist/server.pem"])
        #expect(items.allSatisfy { $0.kind == .secretInExcluded })
    }

    @Test func secretInNodeModulesNotFlagged() {
        let paths = ["app/node_modules/x/.env", "ios/Pods/Foo/key.pem", "py/.venv/lib/id_rsa", "php/vendor/acme/.env.example"]
        #expect(scanner.secretsIn(changedExcludedPaths: paths).isEmpty)
    }

    func gitRepo(_ box: ArchiveSandbox) throws -> URL {
        let repo = try box.dir("repo")
        try box.write("vendor/autoload.php", under: repo)
        try box.write("vendor/untracked/x.php", under: repo)
        try box.write("node_modules/pkg/index.js", under: repo)
        try box.write("src/main.php", under: repo)
        return repo
    }
    func git(_ repo: URL, _ a: String...) throws {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", repo.path, "-c", "user.name=t", "-c", "user.email=t@t"] + a
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        #expect(p.terminationStatus == 0)
    }

    @Test func trackedVendorFlagged() throws {
        let box = try ArchiveSandbox(); let repo = try gitRepo(box)
        try git(repo, "init", "-q")
        try git(repo, "add", "vendor/autoload.php", "src/main.php")
        try git(repo, "commit", "-q", "-m", "init")
        let items = try scanner.trackedInExcluded(repo: repo, excluded: ["vendor", "node_modules/"])
        #expect(items.count == 1)
        #expect(items[0].kind == .trackedInExcluded)
        #expect(items[0].path == repo.appendingPathComponent("vendor").path)
    }

    @Test func untrackedVendorNotFlagged() throws {
        let box = try ArchiveSandbox(); let repo = try gitRepo(box)
        try git(repo, "init", "-q")
        try git(repo, "add", "src/main.php")
        try git(repo, "commit", "-q", "-m", "init")
        #expect(try scanner.trackedInExcluded(repo: repo, excluded: ["vendor", "node_modules"]).isEmpty)
        #expect(try scanner.trackedInExcluded(repo: box.root, excluded: ["vendor"]).isEmpty)   // not a repo
    }

    @Test func gitFailingIsReportedNotSwallowed() throws {
        let box = try ArchiveSandbox()
        let repo = try box.dir("broken"); _ = try box.dir("broken/.git")   // looks like a repo, is not one
        #expect(throws: ReviewError.self) { try scanner.trackedInExcluded(repo: repo, excluded: ["vendor"]) }
        let missing = ReviewScanner(filters: FilterBuilder(presets: []), gitPath: "/nonexistent/git")
        #expect(throws: ReviewError.self) { try missing.trackedInExcluded(repo: repo, excluded: ["vendor"]) }
    }

    @Test func repoConfigCannotRunCommands() throws {
        let box = try ArchiveSandbox(); let repo = try gitRepo(box)
        try git(repo, "init", "-q")
        try git(repo, "add", "vendor/autoload.php", "src/main.php")
        try git(repo, "commit", "-q", "-m", "init")
        let marker = box.root.appendingPathComponent("marker")
        let hook = box.root.appendingPathComponent("hook.sh")
        try "#!/bin/sh\ntouch '\(marker.path)'\n".write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        try git(repo, "config", "core.fsmonitor", hook.path)
        try git(repo, "config", "core.hooksPath", box.root.path)
        try git(repo, "config", "core.pager", "touch '\(marker.path)'")
        let items = try scanner.trackedInExcluded(repo: repo, excluded: ["vendor"])
        #expect(items.count == 1)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        // The arguments and environment carry the hardening.
        #expect(ReviewScanner.gitArguments(repo).contains("core.fsmonitor=false"))
        #expect(ReviewScanner.gitArguments(repo).contains("core.hooksPath=/dev/null"))
        let args = ReviewScanner.gitArguments(repo)
        #expect(args.contains("protocol.allow=never"))
        #expect(args.contains("core.sshCommand=false"))
        #expect(ReviewScanner.gitEnvironment["GIT_NO_LAZY_FETCH"] == "1")
        #expect(ReviewScanner.gitEnvironment["GIT_ALLOW_PROTOCOL"] == "")
        #expect(ReviewScanner.gitEnvironment["GIT_TERMINAL_PROMPT"] == "0")
        #expect(ReviewScanner.gitEnvironment["GIT_CONFIG_NOSYSTEM"] == "1")
        #expect(ReviewScanner.gitEnvironment["GIT_CONFIG_GLOBAL"] == "/dev/null")
    }

    @Test func theRuleForATrackedFolderCoversItsContents() {
        let tracked = ReviewItem(id: "t", path: "proj/vendor", kind: .trackedInExcluded)
        #expect(tracked.rulePattern == "/proj/vendor/**")
        #expect(ReviewActions.rule(for: tracked, include: true)?.pattern == "/proj/vendor/**")
        #expect(ReviewActions.rule(for: tracked, include: false)?.pattern == "/proj/vendor/**")
        #expect(ReviewItem(id: "b", path: "pro[j]/vendor", kind: .trackedInExcluded).rulePattern == "/pro\\[j\\]/vendor/**")
    }

    @Test func theRuleForASingleFileStaysExact() {
        let secret = ReviewItem(id: "s", path: "proj/build/.env", kind: .secretInExcluded)
        let refused = ReviewItem(id: "r", path: "proj/a.tmp", kind: .refusedByICloud)
        #expect(secret.rulePattern == "/proj/build/.env")
        #expect(refused.rulePattern == "/proj/a.tmp")
        #expect(ReviewActions.rule(for: secret, include: true)?.pattern == "/proj/build/.env")
        #expect(ReviewActions.rule(for: refused, include: true) == nil)
    }
}
