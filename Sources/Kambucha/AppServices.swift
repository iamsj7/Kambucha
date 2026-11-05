import Foundation
import AppKit
import KambuchaCore

/// Unmounts through the system, off the main thread (the call blocks until the volume is released).
struct WorkspaceEjector: VolumeEjecting {
    func eject(_ mountPoint: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            try NSWorkspace.shared.unmountAndEjectDevice(at: mountPoint)
        }.value
    }
}

/// Everything the main window needs from the engine, injected so views can be rendered and tested
/// with fakes.
struct AppServices: Sendable {
    var preview: any PreviewProviding
    var dryRun: any DeletionDryRunProviding
    var inspector: (any MirroredExcludeInspecting)?
    var volumes: any VolumeLocating
    var agent: AgentClient
    var archive: any ArchiveProviding
    var ejector: any VolumeEjecting = WorkspaceEjector()
    var names: any SetNameListing = NoSetNames()

    /// Real providers. rclone and the agent come only from the app bundle, never from the environment or argv.
    static var live: AppServices {
        let bundle = Bundle.main.bundleURL
        let agent = AgentClient.bundled(in: bundle)
        let support = KambuchaPaths.support
        let store = ConfigStore(root: support)
        let calls = AgentArchiveClient(transport: AgentProcessTransport(executable: agent.executable))
        let preview = LivePreviewProvider(binary: bundle.appendingPathComponent("Contents/Helpers/rclone"))
        let volumes = SystemVolumes()
        return AppServices(
            preview: preview,
            dryRun: AgentDeletionDryRun(client: calls),
            inspector: LocalMirrorInspector(store: store, preview: preview, volumes: volumes, support: support),
            volumes: volumes, agent: agent, archive: AgentArchiveProvider(client: calls), names: calls)
    }
}
