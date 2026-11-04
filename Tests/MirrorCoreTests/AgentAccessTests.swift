import Testing
import Foundation
@testable import MirrorCore

struct AgentAccessTests {
    func dir(files: Int = 0) throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("mirror-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test func readableFoldersPass() throws {
        #expect(AgentAccess.check(paths: [try dir(), try dir()]))
    }

    @Test func aMissingOrUnreadableFolderFails() throws {
        #expect(!AgentAccess.check(paths: [try dir(), URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")]))
        let locked = try dir()
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path) }
        #expect(!AgentAccess.check(paths: [locked]))
    }

    @Test func noPathsIsNotAPass() { #expect(!AgentAccess.check(paths: [])) }

    @Test func settingsFileThatIsDamagedThrows() throws {
        let root = try dir()
        try Data("not json".utf8).write(to: root.appendingPathComponent("settings.json"))
        #expect(throws: (any Error).self) { try SettingsStore(root: root).load() }
    }
}
