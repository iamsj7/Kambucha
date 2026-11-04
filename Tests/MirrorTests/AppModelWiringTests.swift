import Testing
import Foundation
import MirrorCore
@testable import Mirror

private struct Vols: VolumeLocating {
    var list: [VolumeInfo]
    func mounted() -> [VolumeInfo] { list }
}

private final class NoEject: VolumeEjecting { func eject(_ mountPoint: URL) async throws {} }

@MainActor
private func make(volumes: [VolumeInfo] = [], destinations: [Destination] = []) throws -> AppModel {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("mirror-wiring-\(UUID().uuidString)")
    try ConfigStore(root: root).saveDestinations(destinations)
    let services = AppServices(preview: LivePreviewProvider(binary: URL(fileURLWithPath: "/dev/null")),
                               dryRun: AgentDeletionDryRun(client: AgentArchiveClient(transport: AgentProcessTransport(executable: URL(fileURLWithPath: "/dev/null"))), store: ConfigStore(root: root)),
                               inspector: nil, volumes: Vols(list: volumes), agent: AgentClient(executable: URL(fileURLWithPath: "/dev/null")),
                               archive: AgentArchiveProvider(client: AgentArchiveClient(transport: AgentProcessTransport(executable: URL(fileURLWithPath: "/dev/null")))),
                               ejector: NoEject())
    let model = AppModel(support: root, services: services)
    return model
}

private func vol(_ uuid: String, internalLooking: Bool = false) -> VolumeInfo {
    VolumeInfo(uuid: uuid, name: "SSD", mountPoint: URL(fileURLWithPath: "/Volumes/SSD"), fileSystem: "apfs",
               freeBytes: 1, looksInternal: internalLooking)
}

@MainActor struct AppModelWiringTests {
    @Test func theProgressFolderIsWatchedWhileEitherSurfaceIsOpen() throws {
        let m = try make()
        #expect(!m.isWatchingProgress)
        m.windowAppeared()
        #expect(m.isWatchingProgress)
        m.panelAppeared(); m.windowDisappeared()
        #expect(m.isWatchingProgress)
        m.panelDisappeared()
        #expect(!m.isWatchingProgress)
    }

    @Test func aSecondDestinationForTheSameDriveIsRefused() throws {
        let first = Destination(name: "A", kind: .externalDrive, encrypted: false, volumeUUID: "UUID-1")
        let m = try make(destinations: [first])
        m.save(destination: Destination(name: "B", kind: .externalDrive, encrypted: false, volumeUUID: "uuid-1"))
        #expect(m.destinations.count == 1)
        #expect(m.lastError == "This drive is already a destination called \"A\".")
        // Saving the same destination again (an edit) is fine.
        var edited = first; edited.internalDiskConfirmed = true
        m.save(destination: edited)
        #expect(m.destinations.first?.internalDiskConfirmed == true)
    }

    @Test func anUnconfirmedInternalLookingDriveShowsAsNeedingConfirmation() async throws {
        let d = Destination(name: "SSD", kind: .externalDrive, encrypted: false, volumeUUID: "U")
        let m = try make(volumes: [vol("U", internalLooking: true)], destinations: [d])
        await m.volumeCache.refresh()
        #expect(m.destinationStatus(d).text == "Confirm this internal disk")
        m.save(destination: ExternalDriveSetup.confirmed(d))
        #expect(m.destinationStatus(m.destinations[0]).text != "Confirm this internal disk")
    }

    @Test func aDriveThatIsNotMountedIsNotConnected() async throws {
        let d = Destination(name: "SSD", kind: .externalDrive, encrypted: false, volumeUUID: "U")
        let m = try make(destinations: [d])
        await m.volumeCache.refresh()
        #expect(m.destinationStatus(d).text.hasPrefix("Not connected"))
    }
}
