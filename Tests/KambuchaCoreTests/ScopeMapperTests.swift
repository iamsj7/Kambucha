import Testing
import Foundation
@testable import KambuchaCore

struct ScopeMapperTests {
    let root = URL(fileURLWithPath: "/Users/x/Projects")
    let excluded: (String) -> Bool = { $0.contains("node_modules") }

    func batch(_ rel: [String], rescan: Bool = false) -> ChangeBatch {
        ChangeBatch(paths: rel.map { "/Users/x/Projects/" + $0 }, mustRescan: rescan, latestEventID: 5)
    }
    func scope(_ b: ChangeBatch, max: Int = 25) -> RunScope {
        ScopeMapper(maxProjects: max).scope(for: b, root: root, isExcluded: excluded)
    }

    @Test func noChangesIsNothing() { #expect(scope(batch([])) == .nothing) }
    @Test func changesInExcludedFolderOnlyIsNothing() {
        #expect(scope(batch(["flowapp/node_modules/x"])) == .nothing)
    }
    @Test func mapsToTopLevelProject() {
        #expect(scope(batch(["flowapp/src/a.ts", "flowapp/b.ts"])) == .projects(["flowapp"]))
    }
    @Test func rootLevelChangeWidens() { #expect(scope(batch(["notes.txt"])) == .wholeSet) }
    @Test func deletedProjectWidens() { #expect(scope(batch(["flowapp"])) == .wholeSet) }
    @Test func mustRescanWidens() { #expect(scope(batch([], rescan: true)) == .wholeSet) }
    @Test func nilSinceWidens() {
        #expect(scope(ChangeBatch(paths: [], mustRescan: true, latestEventID: 1)) == .wholeSet)
    }
    @Test func overLimitWidens() {
        let many = (0..<26).map { "p\($0)/f" }
        #expect(scope(batch(many)) == .wholeSet)
        #expect(scope(batch(Array(many.prefix(25)))) != .wholeSet)
    }
    @Test func outsideRootWidens() {
        #expect(scope(ChangeBatch(paths: ["/elsewhere/a/b"], mustRescan: false, latestEventID: 1)) == .wholeSet)
    }

    @Test func excludedRootFileDoesNotWiden() {
        let b = ChangeBatch(paths: ["/Users/x/Projects/.DS_Store"], mustRescan: false, latestEventID: 1)
        let m = ScopeMapper().scope(for: b, root: root, isExcluded: { $0 == ".DS_Store" })
        #expect(m == .nothing)
        #expect(scope(batch(["notes.txt"])) == .wholeSet)
    }
    @Test func siblingPrefixIsOutsideRoot() {
        let r = URL(fileURLWithPath: "/a/b")
        let b = ChangeBatch(paths: ["/a/bc/x/y"], mustRescan: false, latestEventID: 1)
        #expect(ScopeMapper().scope(for: b, root: r, isExcluded: { _ in false }) == .wholeSet)
    }
    @Test func rootPathItselfWidens() {
        let b = ChangeBatch(paths: ["/Users/x/Projects"], mustRescan: false, latestEventID: 1)
        #expect(ScopeMapper().scope(for: b, root: root, isExcluded: { _ in true }) == .wholeSet)
    }
    @Test func privateVarAndVarAreSameRoot() {
        let r = FileManager.default.temporaryDirectory.appendingPathComponent("kambucha-scope-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: r, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: r) }
        let real = r.resolvingSymlinksInPath().path
        let b = ChangeBatch(paths: [real + "/p/f"], mustRescan: false, latestEventID: 1)
        #expect(ScopeMapper().scope(for: b, root: r, isExcluded: { _ in false }) == .projects(["p"]))
    }

    /// FSEvents reports `/private/tmp/...`, while URL's own spellings drop `/private`.
    @Test func eventsSpelledWithPrivatePrefixStayInScope() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("scope-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let real = try #require(realpath(root.path, nil))
        defer { free(real) }
        let batch = ChangeBatch(paths: [String(cString: real) + "/p/a.txt"], mustRescan: false, latestEventID: 1)
        #expect(ScopeMapper().scope(for: batch, root: root, isExcluded: { _ in false }) == .projects(["p"]))
    }
}
