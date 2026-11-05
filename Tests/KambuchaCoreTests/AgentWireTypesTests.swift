import Testing
import Foundation
@testable import KambuchaCore

private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
    let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
    let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
    return try d.decode(T.self, from: try e.encode(value))
}

@Test func wireRequestsRoundTrip() throws {
    let pair = AgentWire.PairRequest(set: UUID(), destination: UUID())
    #expect(try roundTrip(pair) == pair)
    let restore = AgentWire.RestoreRequest(set: UUID(), destination: UUID(), path: "Archive/Docs/2026-11-04T10-00/a.txt", to: "/tmp/a.txt")
    #expect(try roundTrip(restore) == restore)
}

@Test func wireResponseRoundTripsWithEntriesFilesAndFailure() throws {
    let entry = AgentWire.Entry(id: "i", setName: "Docs", stamp: Date(timeIntervalSince1970: 1_800_000_000), path: "Archive/Docs/x/a", size: 5)
    let r = AgentWire.Response(ok: true, failure: nil, entries: [entry], files: ["a", ".git/b"])
    #expect(try roundTrip(r) == r)
    let failed = AgentWire.Response(ok: false, failure: .busy)
    #expect(try roundTrip(failed) == failed)
}

@Test func subcommandNamesAreFixed() {
    #expect(AgentWire.archiveList == "archive-list")
    #expect(AgentWire.archiveRestore == "archive-restore")
    #expect(AgentWire.dryRunDeletions == "dry-run-deletions")
    #expect(AgentWire.subcommands == ["archive-list", "archive-restore", "dry-run-deletions", "set-names", "set-list"])
}

@Test func theNonGitCountIgnoresGitFolders() {
    #expect(AgentWire.nonGitCount(["a", "sub/.git/x", ".git/y", "b/.gitignore", "c/.git"]) == 2)
}
