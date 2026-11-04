#if DEBUG
import SwiftUI
import AppKit
import ServiceManagement
import MirrorCore

/// Debug-only: renders the recovery, onboarding and settings views with fake data to PNGs, in light and dark.
@MainActor
enum DebugViewSnapshots {
    private struct FakeArchive: ArchiveProviding {
        func list(set: BackupSet, destination: Destination) async throws -> [ArchiveEntry] {
            let now = Date()
            func e(_ id: String, _ path: String, _ days: Double, _ size: Int64) -> ArchiveEntry {
                ArchiveEntry(id: id, setName: set.name, stamp: now.addingTimeInterval(-days * 86_400), path: path, size: size)
            }
            return [e("1", "src/App.swift", 0.1, 18_400), e("2", "src/Model.swift", 0.1, 9_200), e("3", "notes/plan.md", 1.2, 4_100),
                    e("4", "assets/logo.png", 3.5, 220_000), e("5", "README.md", 3.5, 2_900)]
        }
        func restore(entry: ArchiveEntry, set: BackupSet, destination: Destination, to: URL) async throws {}
    }

    @MainActor private final class FakeSystem: OnboardingSystem {
        func fullDiskAccessConfirmed() async -> Bool { true }
        func checkFullDiskAccessNow() async -> AccessConfirmation.Outcome { .confirmed }
        func agentStatus() -> SMAppService.Status { .requiresApproval }
        func enableAgent() throws {}
        func notificationAccess() async -> NotificationAccess { .notDetermined }
        func requestNotifications() async -> NotificationAccess { .allowed }
        func openFullDiskAccessPane() {}
        func openLoginItemsSettings() {}
        func openNotificationSettings() {}
    }

    @MainActor private struct FakeLogin: LoginItemControlling {
        var status: SMAppService.Status = .requiresApproval
        func register() throws {}
        func unregister() throws {}
    }

    private static func settle(_ seconds: Double) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private static func write<V: View>(_ view: V, size: CGSize, name: String, to dir: URL) {
        for (label, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
            host.appearance = NSAppearance(named: appearance)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.appearance = host.appearance
            window.contentView = host
            host.frame = NSRect(origin: .zero, size: size)
            window.layoutIfNeeded(); host.layoutSubtreeIfNeeded()
            settle(0.6)
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name)-\(label).png"))
        }
    }

    static func snapshotAll(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let support = DebugFixtures.make(.held)   // sets, destinations and run records
        let store = ConfigStore(root: support)
        let sets = (try? store.loadSets()) ?? []
        // A Google Drive destination that finished a backup and was never tested, so the reminder shows.
        var dests = (try? store.loadDestinations()) ?? []
        if let i = dests.firstIndex(where: { $0.kind == .googleDrive }) {
            dests[i].encrypted = true
            try? store.saveDestinations(dests)
        }

        // Archive
        let archive = ArchiveModel(provider: FakeArchive(), store: store)
        archive.loadConfig()
        Task { await archive.reload() }
        settle(0.5)
        write(ArchiveView(model: archive, agent: AgentClient(executable: URL(fileURLWithPath: "/dev/null"))),
              size: CGSize(width: 720, height: 460), name: "archive", to: dir)

        // Archive, empty and failed states
        let empty = ArchiveModel(provider: EmptyArchive(), store: store); empty.loadConfig()
        Task { await empty.reload() }; settle(0.3)
        write(ArchiveView(model: empty, agent: nil), size: CGSize(width: 720, height: 360), name: "archive-empty", to: dir)

        // Activity
        let records = (try? RunRecordStore(root: support).recent(limit: 50)) ?? []
        let activitySupport = FileManager.default.temporaryDirectory.appendingPathComponent("mirror-activity-\(UUID().uuidString)")
        let runStore = RunRecordStore(root: activitySupport)
        let now = Date()
        let s = sets.first
        let specs: [(RunRecord.Status, Int, Int, String, [String])] = [
            (.success, 12, 0, "Quick check passed", []), (.held, 40, 1_240, "Quick check passed", []),
            (.verificationFailed, 3, 0, "2 files differ", ["notes/plan.md differs from the backup", "src/App.swift size mismatch"]),
            (.partial, 220, 0, "Passed", []), (.failed, 0, 0, "Not run", ["Couldn't reach Google Drive"]), (.skipped, 0, 0, "", [])]
        for (i, spec) in specs.enumerated() {
            var r = RunRecord(setID: s?.id ?? UUID(), setName: s?.name ?? "Projects", destinationID: UUID(),
                              destinationName: i % 2 == 0 ? "iCloud Drive" : "Google Drive",
                              start: now.addingTimeInterval(-Double(i) * 3_600 - 600), end: now.addingTimeInterval(-Double(i) * 3_600),
                              trigger: .schedule, scope: "all", filesChecked: 48_210, copied: spec.1, deleted: spec.2,
                              verification: spec.3, errors: spec.4, status: spec.0)
            r.archived = spec.2 > 0 ? 0 : (i == 0 ? 2 : 0)
            try? runStore.append(r)
        }
        _ = records
        let activity = ActivityModel(support: activitySupport)
        Task { await activity.reload() }; settle(0.5)
        write(ActivityView(model: activity), size: CGSize(width: 980, height: 420), name: "activity", to: dir)

        // Onboarding: Full Disk Access granted, the agent waiting for approval.
        let onboardRoot = FileManager.default.temporaryDirectory.appendingPathComponent("mirror-onboard-\(UUID().uuidString)")
        let onboarding = OnboardingModel(system: FakeSystem(), store: ConfigStore(root: onboardRoot))
        Task { await onboarding.refresh() }; settle(0.4)
        write(OnboardingView(model: onboarding), size: CGSize(width: 600, height: 560), name: "onboarding", to: dir)

        // Settings
        let settingsRoot = FileManager.default.temporaryDirectory.appendingPathComponent("mirror-settings-\(UUID().uuidString)")
        let settings = SettingsModel(store: SettingsStore(root: settingsRoot), login: FakeLogin())
        write(SettingsView(model: settings), size: CGSize(width: 560, height: 640), name: "settings", to: dir)

        // Drill sheet, each outcome.
        let drillDest = dests.first { $0.kind == .googleDrive } ?? Destination(name: "Google Drive", kind: .googleDrive)
        func drill(_ phase: DrillModel.Phase, kit: String) -> DrillModel {
            let m = DrillModel(destinations: [drillDest], sets: sets, store: store, candidate: { _ in nil }, run: { _, _, _, _ in true })
            m.kitText = kit
            m.debugSet(phase)
            return m
        }
        let kitSample = "MIRROR RECOVERY KIT\n-----BEGIN-----\nkind: googleDrive\n..."
        write(DrillSheet(model: drill(.idle, kit: kitSample)), size: CGSize(width: 480, height: 400), name: "drill-idle", to: dir)
        write(DrillSheet(model: drill(.finished(.passed), kit: "")), size: CGSize(width: 480, height: 400), name: "drill-passed", to: dir)
        write(DrillSheet(model: drill(.finished(.badKit), kit: "")), size: CGSize(width: 480, height: 400), name: "drill-badkit", to: dir)
        write(DrillSheet(model: drill(.finished(.couldntTell), kit: "")), size: CGSize(width: 480, height: 400), name: "drill-unsure", to: dir)
    }

    private struct EmptyArchive: ArchiveProviding {
        func list(set: BackupSet, destination: Destination) async throws -> [ArchiveEntry] { [] }
        func restore(entry: ArchiveEntry, set: BackupSet, destination: Destination, to: URL) async throws {}
    }
}

extension DrillModel {
    /// Debug snapshots only: shows a result without running a drill.
    func debugSet(_ p: Phase) { setPhaseForSnapshot(p) }
}
#endif
