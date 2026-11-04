import Testing
import Foundation
@testable import MirrorCore

func makeTree(_ files: [String]) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("mirror-t5-\(UUID().uuidString)")
    for f in files {
        let url = root.appendingPathComponent(f)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !f.hasSuffix("/") { try Data("x".utf8).write(to: url) }
    }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

struct StackDetectorTests {
    let detector: StackDetector
    init() throws { detector = StackDetector(presets: try PresetCatalog.all()) }

    @Test func detectsRootAndNestedProjects() throws {
        let root = try makeTree(["package.json", "apps/web/package.json", "flowapp/pubspec.yaml", "notes/a.txt"])
        defer { try? FileManager.default.removeItem(at: root) }
        let found = Dictionary(uniqueKeysWithValues: detector.detect(in: root).map { ($0.relativePath, $0.presetIDs) })
        #expect(found["."] == ["node"])
        #expect(found["apps/web"] == ["node"])
        #expect(found["flowapp"] == ["flutter"])
        #expect(found["notes"] == nil)
    }

    @Test func globMarkersMatch() throws {
        let root = try makeTree(["App/App.xcodeproj/project.pbxproj", "App/Podfile"])
        defer { try? FileManager.default.removeItem(at: root) }
        let found = detector.detect(in: root)
        #expect(found.first { $0.relativePath == "App" }?.presetIDs == ["ios"])
    }

    @Test func detectorSkipsJunkFolders() throws {
        let root = try makeTree(["node_modules/pkg/package.json", ".git/x/package.json", "vendor/bundle/gem/Gemfile", "ok/package.json"])
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = Set(detector.detect(in: root).map(\.relativePath))
        #expect(paths == ["ok"])
    }

    @Test func respectsMaxDepth() throws {
        let root = try makeTree(["a/b/c/d/e/package.json", "a/b/package.json"])
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = Set(detector.detect(in: root, maxDepth: 2).map(\.relativePath))
        #expect(paths == ["a/b"])
    }
}
