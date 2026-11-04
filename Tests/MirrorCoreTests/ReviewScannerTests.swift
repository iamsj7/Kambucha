import Testing
import Foundation
@testable import MirrorCore

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
        let repo = try box.dir("broken"); try box.dir("broken/.git")   // looks like a repo, is not one
        #expect(throws: ReviewError.self) { try scanner.trackedInExcluded(repo: repo, excluded: ["vendor"]) }
        let missing = ReviewScanner(filters: FilterBuilder(presets: []), gitPath: "/nonexistent/git")
        #expect(throws: ReviewError.self) { try missing.trackedInExcluded(repo: repo, excluded: ["vendor"]) }
    }
}
