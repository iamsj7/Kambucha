import Testing
import Foundation
@testable import KambuchaCore

@Suite struct DatalessTests {
    private func temp() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("dl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test func regularFileIsNotDataless() throws {
        let d = try temp(); defer { try? FileManager.default.removeItem(at: d) }
        let f = d.appendingPathComponent("a.txt")
        try Data("x".utf8).write(to: f)
        #expect(!Dataless.isDataless(f))
    }

    @Test func missingFileIsNotDataless() {
        #expect(!Dataless.isDataless(URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)")))
    }

    @Test func symlinkIsNotDatalessAndNotFollowed() throws {
        let d = try temp(); defer { try? FileManager.default.removeItem(at: d) }
        let link = d.appendingPathComponent("l")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/nonexistent/target")
        #expect(!Dataless.isDataless(link))
    }

    @Test func flagMaskIsSFDataless() {
        #expect(Dataless.flag == 0x4000_0000)
        #expect(Dataless.isDataless(flags: 0x4000_0000 | 0x2, isLink: false))
        #expect(!Dataless.isDataless(flags: 0x4000_0000, isLink: true))
        #expect(!Dataless.isDataless(flags: 0, isLink: false))
    }
}
