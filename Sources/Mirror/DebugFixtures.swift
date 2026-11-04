#if DEBUG
import SwiftUI
import AppKit
import MirrorCore

/// Debug-only fixture state files, so each menu bar state can be seen without a real backup.
@MainActor
enum DebugFixtures {
    enum Name: String, CaseIterable { case backedUp, uploading, running, held, attention, paused, notConfigured }

    static func make(_ name: Name) -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mirror-fixture-\(name.rawValue)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = ConfigStore(root: root)
        if name == .notConfigured { return root }

        let icloud = Destination(name: "iCloud Drive", kind: .iCloudFolder)
        let drive = Destination(name: "Google Drive", kind: .googleDrive)
        var projects = BackupSet(name: "Projects", source: URL(fileURLWithPath: "/Users/me/Projects"),
                                 destinationIDs: [icloud.id, drive.id])
        var docs = BackupSet(name: "Documents", source: URL(fileURLWithPath: "/Users/me/Documents"),
                             destinationIDs: [icloud.id])
        if name == .paused { projects.isPaused = true; docs.isPaused = true }
        try? store.saveSets([projects, docs])
        try? store.saveDestinations([icloud, drive])

        let now = Date()
        func state(_ f: (inout SetState) -> Void = { _ in }) -> SetState {
            var s = SetState(); s.lastFinished = now.addingTimeInterval(-600); s.lastFileCount = 48_210; f(&s); return s
        }
        let pairs = [PairID(set: projects.id, destination: icloud.id), PairID(set: projects.id, destination: drive.id),
                     PairID(set: docs.id, destination: icloud.id)]
        for (i, p) in pairs.enumerated() {
            try? store.save(state {
                switch name {
                case .uploading where i == 0: $0.pendingUploads = 1_240
                case .held where i == 0: $0.heldDeletions = 1_240
                default: break
                }
            }, for: p)
            let status: RunRecord.Status = {
                switch name {
                case .held where i == 0: .held
                case .attention where i == 1: .verificationFailed
                default: .success
                }
            }()
            let rs = (i == 0 ? projects : (i == 1 ? projects : docs))
            let d = i == 1 ? drive : icloud
            try? RunRecordStore(root: root).append(RunRecord(
                setID: rs.id, setName: rs.name, destinationID: d.id, destinationName: d.name,
                start: now.addingTimeInterval(-660), end: now.addingTimeInterval(-600), trigger: .schedule,
                scope: "all", status: status))
        }
        if name == .running {
            try? "\(getpid())\n".write(to: root.appendingPathComponent(AgentPresence.fileName), atomically: true, encoding: .utf8)
        }
        return root
    }

    // MARK: Main window snapshots

    private struct FakePreview: PreviewProviding {
        func preview(set: BackupSet) async throws -> PreviewResult {
            let excluded = Set(set.rules.filter { $0.action == .exclude }.map(\.pattern))
            let all = [
                PreviewGroup(id: "src", title: "Source and documents", fileCount: 31_480, bytes: 2_400_000_000, included: true, pattern: "/src"),
                PreviewGroup(id: "git", title: ".git folders", fileCount: 7_500, bytes: 1_600_000_000, included: true, pattern: ".git/**"),
                PreviewGroup(id: "nm", title: "node_modules", fileCount: 96_200, bytes: 8_100_000_000, included: false, pattern: "node_modules/**"),
                PreviewGroup(id: "pods", title: "Pods", fileCount: 4_100, bytes: 420_000_000, included: false, pattern: "Pods/**"),
            ].map { g -> PreviewGroup in var c = g; if excluded.contains(g.pattern) { c.included = false }; return c }
            let inc = all.filter(\.included)
            return PreviewResult(includedBytes: inc.reduce(0) { $0 + $1.bytes }, skippedBytes: all.filter { !$0.included }.reduce(0) { $0 + $1.bytes },
                                 includedFiles: inc.reduce(0) { $0 + $1.fileCount }, groups: all,
                                 decisions: [ReviewItem(id: "1", path: "vendor/config/.env", kind: .secretInExcluded),
                                             ReviewItem(id: "2", path: "vendor/autoload.php", kind: .trackedInExcluded)])
        }
        func rule(for group: PreviewGroup, included: Bool) -> UserRule { UserRule(pattern: group.pattern, action: included ? .include : .exclude) }
    }
    private struct FakeDryRun: DeletionDryRunProviding {
        func heldDeletions(set: BackupSet) async throws -> [String] {
            (0..<240).map { "Old Builds/release-\($0 / 20)/app-\($0).zip" }
        }
    }
    private struct FakeVolumes: VolumeListing {
        func connectedVolumes() -> [ConnectedVolume] {
            [ConnectedVolume(id: "A", name: "Backup SSD", filesystem: "ExFAT", freeBytes: 420_000_000_000),
             ConnectedVolume(id: "B", name: "Archive", filesystem: "APFS", freeBytes: 1_800_000_000_000)]
        }
    }

    private static func spin(_ seconds: Double = 0.4) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    private static func render<V: View>(_ view: V, size: CGSize, to url: URL) {
        for (label, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
            host.appearance = NSAppearance(named: appearance)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = host.appearance
            window.contentView = host
            host.frame = NSRect(origin: .zero, size: size)
            window.orderBack(nil)
            spin()
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?
                .write(to: url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent)-\(label).png"))
            window.orderOut(nil)
        }
    }

    /// Renders the main window and its sheets in light and dark to `<dir>/<name>-<appearance>.png`.
    static func snapshotMain(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let root = make(.held)
        let store = ConfigStore(root: root)
        var dests = (try? store.loadDestinations()) ?? []
        var onedrive = Destination(name: "OneDrive", kind: .oneDrive)
        onedrive.recoveryKitConfirmed = false
        dests.append(onedrive)
        try? store.saveDestinations(dests)
        var sets = (try? store.loadSets()) ?? []
        sets[0].rules = [UserRule(pattern: "*.log", action: .exclude)]
        sets[0].presets = ["node", "ios"]
        try? store.saveSets(sets)
        let docsPair = PairID(set: sets[1].id, destination: dests[0].id)
        var st = (try? store.state(for: docsPair)) ?? SetState()
        st.reviewItems = [ReviewItem(id: "r1", path: "vendor/config/.env", kind: .secretInExcluded),
                          ReviewItem(id: "r2", path: "build/notes.tmp", kind: .refusedByICloud)]
        try? store.save(st, for: docsPair)
        let services = AppServices(preview: FakePreview(), dryRun: FakeDryRun(), inspector: nil,
                                   volumes: FakeVolumes(), agent: .bundled(in: Bundle.main.bundleURL))
        let model = AppModel(support: root, services: services)
        PreviewAcceptanceStore(root: root).accept(model.sets[1])

        func at(_ n: String) -> URL { dir.appendingPathComponent(n) }
        render(MainWindow(model: model), size: CGSize(width: 900, height: 640), to: at("main-overview"))
        render(NavigationStack { SetDetailView(model: model, setID: model.sets[0].id) }, size: CGSize(width: 620, height: 2000), to: at("set-detail"))
        render(NavigationStack { DestinationDetailView(model: model, destination: dests[1]) }, size: CGSize(width: 620, height: 480), to: at("destination-drive"))
        render(NavigationStack { DestinationDetailView(model: model, destination: onedrive) }, size: CGSize(width: 620, height: 480), to: at("destination-onedrive"))
        render(AddDestinationFlow(model: model) { _ in }, size: CGSize(width: 540, height: 640), to: at("add-destination"))
        render(AddSetFlow(model: model) { _ in }, size: CGSize(width: 540, height: 380), to: at("add-set"))
        render(RecoveryKitPasteSheet(model: model, destination: onedrive) {}, size: CGSize(width: 540, height: 400), to: at("kit-paste"))

        let pc = PreviewController(set: model.sets[0], provider: FakePreview(), inspector: nil)
        Task { await pc.load() }
        spin(0.3)
        render(PreviewSheet(model: model, controller: pc) { _ in }, size: CGSize(width: 680, height: 560), to: at("preview"))
        let review = DeletionReview(set: model.sets[0], provider: FakeDryRun())
        Task { await review.load() }
        spin(0.3)
        render(DeletionReviewSheet(model: model, review: review), size: CGSize(width: 560, height: 460), to: at("deletion-review"))
    }

    /// Renders each fixture in light and dark to `<dir>/<name>-<appearance>.png`.
    static func snapshotAll(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in Name.allCases {
            let model = AppModel(support: make(name))
            for (label, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let host = NSHostingView(rootView: MenuBarPanel(model: model).background(Color(nsColor: .windowBackgroundColor)))
                host.appearance = NSAppearance(named: appearance)
                let size = host.fittingSize
                host.frame = NSRect(origin: .zero, size: size)
                let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
                window.appearance = host.appearance
                window.contentView = host
                window.layoutIfNeeded()
                host.layoutSubtreeIfNeeded()
                guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: dir.appendingPathComponent("\(name.rawValue)-\(label).png"))
            }
        }
    }
}
#endif
