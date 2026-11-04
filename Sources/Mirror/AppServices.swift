import Foundation
import MirrorCore

/// A mounted volume that could hold a backup. Task 21 replaces this list with `VolumeLocating`.
struct ConnectedVolume: Identifiable, Equatable, Sendable {
    var id: String          // volume UUID, never the name
    var name: String
    var filesystem: String
    var freeBytes: Int64?
}

protocol VolumeListing: Sendable {
    func connectedVolumes() -> [ConnectedVolume]
}

/// Lists removable and external volumes that are mounted now.
struct SystemVolumeList: VolumeListing {
    func connectedVolumes() -> [ConnectedVolume] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeUUIDStringKey, .volumeLocalizedFormatDescriptionKey,
                                      .volumeIsInternalKey, .volumeIsLocalKey, .volumeAvailableCapacityForImportantUsageKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            guard let v = try? url.resourceValues(forKeys: Set(keys)),
                  v.volumeIsInternal == false, v.volumeIsLocal == true, let id = v.volumeUUIDString else { return nil }
            return ConnectedVolume(id: id, name: v.volumeName ?? url.lastPathComponent,
                                   filesystem: v.volumeLocalizedFormatDescription ?? "Unknown",
                                   freeBytes: v.volumeAvailableCapacityForImportantUsage)
        }
    }
}

struct ServiceUnavailable: LocalizedError {
    var what: String
    var errorDescription: String? { "\(what) isn't available in this build yet." }
}

private struct UnavailablePreview: PreviewProviding {
    func preview(set: BackupSet) async throws -> PreviewResult { throw ServiceUnavailable(what: "Preview") }
    func rule(for group: PreviewGroup, included: Bool) -> UserRule {
        UserRule(pattern: group.pattern, action: included ? .include : .exclude)
    }
}

private struct UnavailableDryRun: DeletionDryRunProviding {
    func heldDeletions(set: BackupSet) async throws -> [String] { throw ServiceUnavailable(what: "The deletion list") }
}

/// Everything the main window needs from the engine, injected so views can be rendered and tested
/// with fakes. Until Tasks 14 and 15 land, the live set reports these as unavailable.
struct AppServices: Sendable {
    var preview: any PreviewProviding
    var dryRun: any DeletionDryRunProviding
    var inspector: (any MirroredExcludeInspecting)?
    var volumes: any VolumeListing
    var agent: AgentClient

    static var live: AppServices {
        AppServices(preview: UnavailablePreview(), dryRun: UnavailableDryRun(), inspector: nil,
                    volumes: SystemVolumeList(), agent: .bundled(in: Bundle.main.bundleURL))
    }
}
