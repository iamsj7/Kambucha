import Foundation
import MirrorCore

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

private struct UnavailableArchive: ArchiveProviding {
    func list(set: BackupSet, destination: Destination) async throws -> [ArchiveEntry] { throw ServiceUnavailable(what: "The archive") }
    func restore(entry: ArchiveEntry, set: BackupSet, destination: Destination, to: URL) async throws {
        throw ServiceUnavailable(what: "Restore")
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
    var volumes: any VolumeLocating
    var agent: AgentClient
    var archive: any ArchiveProviding

    static var live: AppServices {
        AppServices(preview: UnavailablePreview(), dryRun: UnavailableDryRun(), inspector: nil,
                    volumes: SystemVolumes(), agent: .bundled(in: Bundle.main.bundleURL),
                    archive: UnavailableArchive())
    }
}
