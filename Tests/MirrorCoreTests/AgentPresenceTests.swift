import Testing
import Foundation
@testable import MirrorCore

struct AgentPresenceTests {
    func dir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("mirror-presence-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test func noFileIsNotRunning() throws {
        #expect(AgentPresence.isRunning(support: try dir()) == false)
    }

    @Test func livePidIsRunning() throws {
        let d = try dir()
        try "\(getpid())\n".write(to: d.appendingPathComponent("agent.pid"), atomically: true, encoding: .utf8)
        #expect(AgentPresence.isRunning(support: d))
    }

    @Test func deadPidIsNotRunningAndStaleFileIsCleared() throws {
        let d = try dir()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try p.run(); p.waitUntilExit()
        let url = d.appendingPathComponent("agent.pid")
        try "\(p.processIdentifier)".write(to: url, atomically: true, encoding: .utf8)
        #expect(AgentPresence.isRunning(support: d) == false)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func garbageFileIsNotRunning() throws {
        let d = try dir()
        try "nope".write(to: d.appendingPathComponent("agent.pid"), atomically: true, encoding: .utf8)
        #expect(AgentPresence.isRunning(support: d) == false)
    }
}
