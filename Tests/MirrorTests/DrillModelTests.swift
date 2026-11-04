import Testing
import Foundation
import MirrorCore
@testable import Mirror

final class Flag: @unchecked Sendable { private(set) var value = false; func set() { value = true } }

@MainActor
struct DrillModelTests {
    let kit: String = RecoveryKit(kind: .googleDrive, rootPath: "Mac Backup", passphrase: String(repeating: "a", count: 64), salt: String(repeating: "b", count: 64),
                                  filenameEncoding: "base32", rcloneVersion: "1.70.0", clientID: "id", clientSecret: "secret").text()
    func setup() throws -> (ConfigStore, BackupSet, Destination) {
        let store = ConfigStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("mirror-test-\(UUID().uuidString)"))
        let dest = Destination(name: "Drive", kind: .googleDrive)
        let set = BackupSet(name: "Docs", source: URL(fileURLWithPath: "/tmp/x"), destinationIDs: [dest.id])
        try store.saveSets([set]); try store.saveDestinations([dest])
        return (store, set, dest)
    }
    func model(_ dest: Destination, store: ConfigStore, run: @escaping DrillModel.Runner) -> DrillModel {
        let m = DrillModel(destinations: [dest], store: store,
                           candidate: { _ in DrillCandidate(relativePath: "Sets/Docs/a.txt", original: URL(fileURLWithPath: "/tmp/x/a.txt")) },
                           run: run)
        m.kitText = kit
        return m
    }

    @Test func passUpdatesLastDrill() async throws {
        let (store, set, dest) = try setup()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let m = model(dest, store: store) { _, _, _, _ in true }
        m.now = { now }
        await m.start()
        #expect(m.phase == .finished(.passed))
        #expect(try store.state(for: PairID(set: set.id, destination: dest.id)).lastDrill == now)
        #expect(m.kitText.isEmpty)   // the Kit does not linger in memory
    }

    @Test func falseIsABadKitAndLeavesLastDrill() async throws {
        let (store, set, dest) = try setup()
        let m = model(dest, store: store) { _, _, _, _ in false }
        await m.start()
        #expect(m.phase == .finished(.badKit))
        #expect(try store.state(for: PairID(set: set.id, destination: dest.id)).lastDrill == nil)
    }

    @Test func parseFailureFromTheAgentIsABadKit() async throws {
        let (store, _, dest) = try setup()
        let m = model(dest, store: store) { _, _, _, _ in throw RecoveryKitError.malformedLine }
        await m.start()
        #expect(m.phase == .finished(.badKit))
    }

    @Test func textThatIsNotAKitNeverReachesTheAgent() async throws {
        let (store, _, dest) = try setup()
        let called = Flag()
        let m = model(dest, store: store) { _, _, _, _ in called.set(); return true }
        m.kitText = "hello"
        await m.start()
        #expect(m.phase == .finished(.badKit) && !called.value)
    }

    @Test func networkFailureIsCouldntTell() async throws {
        let (store, set, dest) = try setup()
        for error: any Error in [URLError(.notConnectedToInternet), RestoreDrillError.couldNotRun, RestoreDrillError.signInExpired,
                                 AgentClientError.noResponse(exitCode: 1), RcloneSessionError.notSignedIn] {
            let m = model(dest, store: store) { _, _, _, _ in throw error }
            await m.start()
            #expect(m.phase == .finished(.couldntTell), "\(error)")
        }
        #expect(try store.state(for: PairID(set: set.id, destination: dest.id)).lastDrill == nil)
    }

    @Test func noCandidateFileIsNotAFailure() async throws {
        let (store, _, dest) = try setup()
        let m = DrillModel(destinations: [dest], store: store, candidate: { _ in nil }, run: { _, _, _, _ in true })
        m.kitText = kit
        await m.start()
        #expect(m.phase == .nothingToTest)
    }
}
