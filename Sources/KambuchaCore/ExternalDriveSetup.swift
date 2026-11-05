import Foundation

/// What Add Destination needs from the volume list, kept apart from the view so fakes can drive it.
public enum ExternalDriveSetup {
    public struct Choice: Equatable, Identifiable, Sendable {
        public var id: String
        public var name: String
        public var formatName: String
        public var freeBytes: Int64?
        /// Set for a usable drive. Unsupported drives have no volume and can't be selected.
        public var volume: VolumeInfo?
        public var unavailableReason: String?
        public var selectable: Bool { volume != nil }
    }

    public static let internalConfirmationTitle = "This looks like an internal disk"
    public static let internalConfirmationMessage =
        "Backing up to a disk inside this Mac doesn't protect you if the Mac is lost or fails. Use it anyway?"

    /// A drive that an existing destination already names is listed but not selectable: one drive, one destination.
    public static func choices(from locator: any VolumeLocating, existing: [Destination] = []) -> [Choice] {
        let usable = locator.mounted().map { v -> Choice in
            if let dup = DestinationRules.duplicateDrive(of: v.uuid, in: existing, excluding: nil) {
                return Choice(id: v.uuid, name: v.name, formatName: displayName(fileSystem: v.fileSystem),
                              freeBytes: v.freeBytes, volume: nil, unavailableReason: DestinationRules.duplicateDriveMessage(dup))
            }
            return Choice(id: v.uuid, name: v.name, formatName: displayName(fileSystem: v.fileSystem),
                          freeBytes: v.freeBytes, volume: v, unavailableReason: nil)
        }
        let bad = locator.unsupported().map {
            Choice(id: "unsupported:" + $0.mountPoint.path, name: $0.name, formatName: "", freeBytes: nil,
                   volume: nil, unavailableReason: reasonText($0.reason))
        }
        return usable + bad
    }

    /// `choices`, read off the calling thread: listing volumes touches the disks.
    public static func loadChoices(from locator: any VolumeLocating, existing: [Destination]) async -> [Choice] {
        await Task.detached(priority: .userInitiated) { choices(from: locator, existing: existing) }.value
    }

    public static func needsInternalConfirmation(_ v: VolumeInfo) -> Bool { v.looksInternal }

    /// True for a saved drive that is connected, looks like an internal disk and was never confirmed. Runs refuse it
    /// until the owner confirms in the destination's details.
    public static func needsConfirmation(_ destination: Destination, volume: VolumeInfo?) -> Bool {
        destination.kind == .externalDrive && !destination.internalDiskConfirmed && (volume?.looksInternal ?? false)
    }

    public static func confirmed(_ destination: Destination) -> Destination {
        var d = destination; d.internalDiskConfirmed = true; return d
    }

    public static func destination(name: String, volume: VolumeInfo, internalConfirmed: Bool) -> Destination {
        Destination(name: name, kind: .externalDrive, encrypted: false, volumeUUID: volume.uuid,
                    internalDiskConfirmed: needsInternalConfirmation(volume) && internalConfirmed)
    }

    public static func reasonText(_ r: UnsupportedVolume.Reason) -> String {
        switch r {
        case .noVolumeUUID: "This drive has no volume ID, so Kambucha can't recognise it later."
        case .timeMachine: "Used by Time Machine."
        case .readOnly: "This drive is read-only."
        case .notLocal: "This is a network volume."
        case .unreadable: "Kambucha can't read this drive."
        }
    }

    public static func displayName(fileSystem: String) -> String {
        switch fileSystem.lowercased() {
        case "apfs": "APFS"
        case "hfs": "Mac OS Extended"
        case "exfat": "exFAT"
        case "msdos": "FAT"
        default: fileSystem
        }
    }
}
