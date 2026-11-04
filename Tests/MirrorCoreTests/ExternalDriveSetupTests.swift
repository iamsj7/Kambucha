import Testing
import Foundation
@testable import MirrorCore

private struct FakeLocator: VolumeLocating {
    var volumes: [VolumeInfo] = []
    var bad: [UnsupportedVolume] = []
    func mounted() -> [VolumeInfo] { volumes }
    func unsupported() -> [UnsupportedVolume] { bad }
}

private func vol(_ uuid: String, _ name: String, fs: String = "apfs", free: Int64 = 5_000_000_000,
                 internal looksInternal: Bool = false) -> VolumeInfo {
    VolumeInfo(uuid: uuid, name: name, mountPoint: URL(fileURLWithPath: "/Volumes/\(name)"), fileSystem: fs,
               freeBytes: free, looksInternal: looksInternal)
}

@Suite struct ExternalDriveSetupTests {
    @Test func listsMountedThenUnsupportedWithReasons() {
        let loc = FakeLocator(volumes: [vol("A", "SSD", fs: "exfat")],
                              bad: [UnsupportedVolume(name: "Backups", mountPoint: URL(fileURLWithPath: "/Volumes/Backups"), reason: .timeMachine)])
        let rows = ExternalDriveSetup.choices(from: loc)
        #expect(rows.count == 2)
        #expect(rows[0].selectable && rows[0].volume?.uuid == "A" && rows[0].unavailableReason == nil)
        #expect(rows[0].formatName == "exFAT")
        #expect(!rows[1].selectable && rows[1].volume == nil)
        #expect(rows[1].unavailableReason == "Used by Time Machine.")
    }

    @Test func everyReasonHasText() {
        for r in [UnsupportedVolume.Reason.noVolumeUUID, .timeMachine, .readOnly, .notLocal, .unreadable] {
            #expect(!ExternalDriveSetup.reasonText(r).isEmpty)
        }
    }

    @Test func internalLookingNeedsConfirmation() {
        #expect(ExternalDriveSetup.needsInternalConfirmation(vol("A", "X", internal: true)))
        #expect(!ExternalDriveSetup.needsInternalConfirmation(vol("A", "X")))
        #expect(ExternalDriveSetup.internalConfirmationTitle == "This looks like an internal disk")
    }

    @Test func missingInternalKeyReadsAsInternal() {
        #expect(SystemVolumes.looksInternalValue(isInternal: nil, isEjectable: false))
        #expect(SystemVolumes.looksInternalValue(isInternal: true, isEjectable: false))
        #expect(!SystemVolumes.looksInternalValue(isInternal: false, isEjectable: false))
        #expect(!SystemVolumes.looksInternalValue(isInternal: nil, isEjectable: true))
    }

    @Test func destinationStoresUUIDUnencryptedAndConfirmation() {
        let d = ExternalDriveSetup.destination(name: "Backup", volume: vol("U-1", "SSD", internal: true), internalConfirmed: true)
        #expect(d.kind == .externalDrive && d.volumeUUID == "U-1" && d.encrypted == false && d.internalDiskConfirmed)
        let e = ExternalDriveSetup.destination(name: "Backup", volume: vol("U-2", "SSD"), internalConfirmed: false)
        #expect(!e.internalDiskConfirmed)
    }

    @Test func externalNeverOffersEncryption() {
        #expect(!DestinationRules.encryptionOffered(.externalDrive))
        #expect(!DestinationRules.encryptionDefault(.externalDrive))
    }

    @Test func exFATWarningNamesTheLimits() throws {
        let w = try #require(DestinationRules.filesystemWarning("exfat"))
        #expect(w.contains("symbolic links") && w.contains("2 second") && w.contains("._"))
        #expect(DestinationRules.filesystemWarning("apfs") == nil)
    }

    @Test func destinationDecodesLeniently() throws {
        let old = #"{"id":"7B2F1C7E-0000-4000-8000-000000000001","name":"x","kind":"externalDrive","encrypted":false,"recoveryKitConfirmed":false,"volumeUUID":"A"}"#
        let d = try JSONDecoder().decode(Destination.self, from: Data(old.utf8))
        #expect(d.internalDiskConfirmed == false)
        let round = try JSONDecoder().decode(Destination.self, from: JSONEncoder().encode(
            Destination(name: "y", kind: .externalDrive, volumeUUID: "B", internalDiskConfirmed: true)))
        #expect(round.internalDiskConfirmed)
    }

    @Test func runRefusesUnconfirmedInternalLookingVolume() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("edsetup-\(UUID().uuidString)")
        let mount = base.appendingPathComponent("Volumes/SSD"), src = base.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let v = VolumeInfo(uuid: "AAAA", name: "SSD", mountPoint: mount, fileSystem: "apfs", freeBytes: 1, looksInternal: true)
        let g = PathGuard.forVolume(v, iCloudDrive: base.appendingPathComponent("icloud"))
        let set = BackupSet(name: "A", source: src)
        let marker = RootMarker(sets: [set.id: "A"])
        var dest = Destination(name: "SSD", kind: .externalDrive, volumeUUID: "AAAA")
        do { try g.validateRun(set, destination: dest, marker: marker, sampleFileCount: 5, state: SetState(), volume: v)
             Issue.record("should refuse") }
        catch { #expect(error as? GuardFailure == .internalDiskNotConfirmed) }
        dest.internalDiskConfirmed = true
        try g.validateRun(set, destination: dest, marker: marker, sampleFileCount: 5, state: SetState(), volume: v)
        #expect(!SetupFailureText.message(for: GuardFailure.internalDiskNotConfirmed).isEmpty)
        #expect(!SetupFailureText.message(for: GuardFailure.wrongDrive).isEmpty)
    }
}
