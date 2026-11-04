import Testing
import Foundation
import MirrorCore
@testable import Mirror

private struct Vols: VolumeLocating {
    var list: [VolumeInfo]
    func mounted() -> [VolumeInfo] { list }
}

private final class NoEject: VolumeEjecting { func eject(_ mountPoint: URL) async throws {} }

private final class SlowEjector: VolumeEjecting {
    func eject(_ mountPoint: URL) async throws { try await Task.sleep(for: .milliseconds(300)) }
}

@MainActor
private func make(volumes: [VolumeInfo] = [], destinations: [Destination] = [], sets: [BackupSet] = [],
                  ejector: any VolumeEjecting = NoEject(), prepare: (ConfigStore, URL) throws -> Void = { _, _ in }) throws -> AppModel {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("mirror-wiring-\(UUID().uuidString)")
    try ConfigStore(root: root).saveDestinations(destinations)
    try ConfigStore(root: root).saveSets(sets)
    try prepare(ConfigStore(root: root), root)
    let services = AppServices(preview: LivePreviewProvider(binary: URL(fileURLWithPath: "/dev/null")),
                               dryRun: AgentDeletionDryRun(client: AgentArchiveClient(transport: AgentProcessTransport(executable: URL(fileURLWithPath: "/dev/null")))),
                               inspector: nil, volumes: Vols(list: volumes), agent: AgentClient(executable: URL(fileURLWithPath: "/dev/null")),
                               archive: AgentArchiveProvider(client: AgentArchiveClient(transport: AgentProcessTransport(executable: URL(fileURLWithPath: "/dev/null")))),
                               ejector: ejector)
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

    @Test func resolvingAReviewItemKeepsAnAcceptedSetAccepted() throws {
        let dest = Destination(name: "iCloud", kind: .iCloudFolder)
        var set = BackupSet(name: "Docs", source: URL(fileURLWithPath: "/tmp/docs"), destinationIDs: [dest.id])
        set.acceptPreview()
        let item = ReviewItem(id: "1", path: "vendor/.env", kind: .secretInExcluded)
        let m = try make(destinations: [dest], sets: [set]) { store, _ in
            var st = SetState(); st.reviewItems = [item]
            try store.save(st, for: PairID(set: set.id, destination: dest.id))
        }
        let entry = try #require(m.reviewEntries.first)
        m.resolve(entry, include: false)
        #expect(m.sets[0].rules.count == 1)
        #expect(m.sets[0].isPreviewAccepted)
    }

    @Test func resolvingAReviewItemDoesNotAcceptASetThatWasNeverAccepted() throws {
        let dest = Destination(name: "iCloud", kind: .iCloudFolder)
        let set = BackupSet(name: "Docs", source: URL(fileURLWithPath: "/tmp/docs"), destinationIDs: [dest.id])
        let item = ReviewItem(id: "1", path: "vendor/.env", kind: .secretInExcluded)
        let m = try make(destinations: [dest], sets: [set]) { store, _ in
            var st = SetState(); st.reviewItems = [item]
            try store.save(st, for: PairID(set: set.id, destination: dest.id))
        }
        m.resolve(try #require(m.reviewEntries.first), include: true)
        #expect(!m.sets[0].isPreviewAccepted)
    }

    @Test func aLegacySetShowsPreviewNeededInTheStatus() throws {
        let dest = Destination(name: "iCloud", kind: .iCloudFolder)
        let set = BackupSet(name: "Docs", source: URL(fileURLWithPath: "/tmp/docs"), destinationIDs: [dest.id])
        let m = try make(destinations: [dest], sets: [set]) { store, _ in
            var st = SetState(); st.lastFinished = Date()
            try store.save(st, for: PairID(set: set.id, destination: dest.id))
        }
        #expect(m.status == .attention("Preview needed: Docs"))
    }

    @Test func theRunningFlagIsReadWhenStateIsLoadedNotPerRender() throws {
        let m = try make { _, root in
            try "\(getpid())\n".write(to: root.appendingPathComponent(AgentPresence.fileName), atomically: true, encoding: .utf8)
        }
        #expect(m.isBackupActive)
        // Removing the file changes nothing until the next refresh: reads of the flag touch no file.
        try? FileManager.default.removeItem(at: m.support.appendingPathComponent(AgentPresence.fileName))
        #expect(m.isBackupActive)
    }

    @Test func aBackupDoesNotStartWhileADriveIsBeingEjected() async throws {
        let m = try make(ejector: SlowEjector())
        let v = VolumeInfo(uuid: "U", name: "SSD", mountPoint: URL(fileURLWithPath: "/Volumes/SSD"), fileSystem: "apfs", freeBytes: 1)
        async let ejecting: Void = m.eject.eject(v)
        try await Task.sleep(for: .milliseconds(60))
        m.runNow(nil)
        #expect(m.lastError?.contains("eject") == true)
        await ejecting
    }
}
