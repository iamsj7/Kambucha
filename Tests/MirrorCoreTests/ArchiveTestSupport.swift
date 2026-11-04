import Foundation
@testable import MirrorCore

final class ArchiveSandbox {
    let root: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("mirror-t15-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    @discardableResult func write(_ rel: String, _ text: String = "x", under base: URL? = nil) throws -> URL {
        let u = (base ?? root).appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: u, atomically: true, encoding: .utf8)
        return u
    }
    func dir(_ rel: String) throws -> URL {
        let u = root.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    func exists(_ rel: String) -> Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent(rel).path) }
}

let plainContext = RcloneContext(configPath: "/dev/null", environment: [:])
func realRunner() -> RcloneRunner { RcloneRunner(binary: vendoredRclone) }
func makeSet(_ name: String = "Projects", source: URL = URL(fileURLWithPath: "/tmp/none"), days: Int = 30) -> BackupSet {
    var s = BackupSet(name: name, source: source); s.archiveDays = days; return s
}
func utc(_ s: String) -> Date { ArchiveScope.parseStamp(s)! }
