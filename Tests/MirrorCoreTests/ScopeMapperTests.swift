import Testing
import Foundation
@testable import MirrorCore

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
}
