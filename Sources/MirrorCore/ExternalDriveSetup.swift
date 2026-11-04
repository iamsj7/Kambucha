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

    public static func choices(from locator: any VolumeLocating) -> [Choice] {
        let usable = locator.mounted().map {
            Choice(id: $0.uuid, name: $0.name, formatName: displayName(fileSystem: $0.fileSystem),
                   freeBytes: $0.freeBytes, volume: $0, unavailableReason: nil)
        }
        let bad = locator.unsupported().map {
            Choice(id: "unsupported:" + $0.mountPoint.path, name: $0.name, formatName: "", freeBytes: nil,
                   volume: nil, unavailableReason: reasonText($0.reason))
        }
        return usable + bad
    }

    public static func needsInternalConfirmation(_ v: VolumeInfo) -> Bool { v.looksInternal }

    public static func destination(name: String, volume: VolumeInfo, internalConfirmed: Bool) -> Destination {
        Destination(name: name, kind: .externalDrive, encrypted: false, volumeUUID: volume.uuid,
                    internalDiskConfirmed: needsInternalConfirmation(volume) && internalConfirmed)
    }

    public static func reasonText(_ r: UnsupportedVolume.Reason) -> String {
        switch r {
        case .noVolumeUUID: "This drive has no volume ID, so Mirror can't recognise it later."
        case .timeMachine: "Used by Time Machine."
        case .readOnly: "This drive is read-only."
        case .notLocal: "This is a network volume."
        case .unreadable: "Mirror can't read this drive."
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
