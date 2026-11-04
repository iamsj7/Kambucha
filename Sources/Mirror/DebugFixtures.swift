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
        func heldDeletions(set: BackupSet, destination: Destination) async throws -> [String] {
            (0..<240).map { "Old Builds/release-\($0 / 20)/app-\($0).zip" }
        }
    }
    private struct FakeVolumes: VolumeLocating {
        func mounted() -> [VolumeInfo] {
            [VolumeInfo(uuid: "A", name: "Backup SSD", mountPoint: URL(fileURLWithPath: "/Volumes/Backup SSD"), fileSystem: "exfat", freeBytes: 420_000_000_000),
             VolumeInfo(uuid: "B", name: "Archive", mountPoint: URL(fileURLWithPath: "/Volumes/Archive"), fileSystem: "apfs", freeBytes: 1_800_000_000_000, looksInternal: true)]
        }
        func unsupported() -> [UnsupportedVolume] {
            [UnsupportedVolume(name: "Time Machine", mountPoint: URL(fileURLWithPath: "/Volumes/Time Machine"), reason: .timeMachine)]
        }
    }

    private static func spin(_ seconds: Double = 0.4) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    private static func render<V: View>(_ view: V, size: CGSize, to url: URL) {
        DebugRender.render(view, size: size, name: url.lastPathComponent, to: url.deletingLastPathComponent(), settle: 0.4)
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
        let ssd = Destination(name: "Backup SSD", kind: .externalDrive, encrypted: false, volumeUUID: "A")
        let inner = Destination(name: "Archive", kind: .externalDrive, encrypted: false, volumeUUID: "B")
        dests += [ssd, inner]
        try? store.saveDestinations(dests)
        var sets = (try? store.loadSets()) ?? []
        sets[0].rules = [UserRule(pattern: "*.log", action: .exclude)]
        sets[0].presets = ["node", "ios"]
        sets[0].destinationIDs.append(ssd.id)
        sets[1].acceptPreview()
        try? store.saveSets(sets)
        let docsPair = PairID(set: sets[1].id, destination: dests[0].id)
        var st = (try? store.state(for: docsPair)) ?? SetState()
        st.reviewItems = [ReviewItem(id: "r1", path: "vendor/config/.env", kind: .secretInExcluded),
                          ReviewItem(id: "r2", path: "build/notes.tmp", kind: .refusedByICloud),
                          ReviewItem(id: "r3", path: "Photos/holiday.nosync", kind: .refusedByICloud)]
        try? store.save(st, for: docsPair)
        let services = AppServices(preview: FakePreview(), dryRun: FakeDryRun(), inspector: nil,
                                   volumes: FakeVolumes(), agent: .bundled(in: Bundle.main.bundleURL),
                                   archive: AppServices.live.archive)
        // A live run on the first set, so its detail shows the progress row.
        try? "\(getpid())\n".write(to: root.appendingPathComponent(AgentPresence.fileName), atomically: true, encoding: .utf8)
        try? ProgressStore(root: root).write(TransferProgress(
            pair: PairID(set: sets[0].id, destination: dests[0].id), phase: .transferring, bytesDone: 2_125_824_000,
            bytesTotal: 5_000_000_000, filesDone: 412, filesTotal: 1_040, bytesPerSecond: 3_400_000, eta: 845, updated: Date()))
        let model = AppModel(support: root, services: services)
        spin(0.5)

        func at(_ n: String) -> URL { dir.appendingPathComponent(n) }
        // MainWindow itself shows onboarding until the real system checks pass, so the overview is rendered directly.
        render(NavigationStack { OverviewView(model: model, select: { _ in }) }, size: CGSize(width: 700, height: 900), to: at("main-overview"))
        render(NavigationStack { SetDetailView(model: model, setID: model.sets[0].id) }, size: CGSize(width: 620, height: 2000), to: at("set-detail"))
        render(NavigationStack { DestinationDetailView(model: model, destination: dests[1]) }, size: CGSize(width: 620, height: 480), to: at("destination-drive"))
        render(NavigationStack { DestinationDetailView(model: model, destination: onedrive) }, size: CGSize(width: 620, height: 480), to: at("destination-onedrive"))
        render(NavigationStack { DestinationDetailView(model: model, destination: ssd) }, size: CGSize(width: 620, height: 480), to: at("destination-ssd-running"))
        render(NavigationStack { DestinationDetailView(model: model, destination: inner) }, size: CGSize(width: 620, height: 520), to: at("destination-internal-confirm"))
        render(AddDestinationFlow(model: model) { _ in }, size: CGSize(width: 540, height: 640), to: at("add-destination"))
        render(AddSetFlow(model: model) { _ in }, size: CGSize(width: 540, height: 380), to: at("add-set"))
        render(RecoveryKitPasteSheet(model: model, destination: onedrive) {}, size: CGSize(width: 540, height: 400), to: at("kit-paste"))

        func reveal(_ fetch: @escaping (Destination) async throws -> String) -> KitRevealModel {
            let m = KitRevealModel(destination: onedrive, fetch: fetch)
            Task { await m.begin() }
            spin(0.3)
            return m
        }
        render(RecoveryKitSheet(model: model, destination: onedrive, reveal: reveal { _ in try await Task.sleep(for: .seconds(60)); return "" }),
               size: CGSize(width: 540, height: 480), to: at("kit-touchid"))
        render(RecoveryKitSheet(model: model, destination: onedrive, reveal: reveal { _ in throw AgentFailure.presenceRefused }),
               size: CGSize(width: 540, height: 480), to: at("kit-refused"))
        let unproven = KitRestoreModel(destination: onedrive) { _, _, accept in if !accept { throw RemoteSetupError.kitUnproven } }
        unproven.text = "MIRROR RECOVERY KIT\n..."
        Task { await unproven.submit() }
        spin(0.3)
        render(RecoveryKitPasteSheet(model: model, destination: onedrive, flow: unproven), size: CGSize(width: 540, height: 520), to: at("kit-unproven"))

        let pc = PreviewController(set: model.sets[0], provider: FakePreview(), inspector: nil)
        Task { await pc.load() }
        spin(0.3)
        render(PreviewSheet(model: model, controller: pc) { _ in }, size: CGSize(width: 680, height: 560), to: at("preview"))
        let review = DeletionReview(set: model.sets[0], destinations: [dests[0], dests[1]], provider: FakeDryRun())
        Task { await review.load() }
        spin(0.3)
        render(DeletionReviewSheet(model: model, review: review), size: CGSize(width: 600, height: 560), to: at("deletion-review"))
    }

    /// Renders each fixture in light and dark to `<dir>/<name>-<appearance>.png`.
    static func snapshotAll(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in Name.allCases {
            let model = AppModel(support: make(name))
            DebugRender.render(MenuBarPanel(model: model), size: nil, name: name.rawValue, to: dir, settle: 0)
        }
    }

    /// Renders ProgressRow states (determinate, indeterminate, iCloud estimate) in light and dark.
    static func snapshotProgress(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pair = PairID(set: UUID(), destination: UUID())
        let now = Date()
        let rows: [(String, TransferProgress)] = [
            ("Projects to Google Drive", TransferProgress(pair: pair, phase: .transferring, bytesDone: 2_125_824_000,
                bytesTotal: 5_000_000_000, filesDone: 412, filesTotal: 1_040, bytesPerSecond: 3_400_000, eta: 845, updated: now)),
            ("Documents to OneDrive", TransferProgress(pair: pair, phase: .scanning, updated: now)),
            ("Documents to iCloud Drive", TransferProgress.iCloud(pair: pair, filesDone: 40, filesTotal: 100, filesPerSecond: 2, now: now)),
        ]
        let net = NetworkStatus()
        let view = VStack(alignment: .leading, spacing: 8) {
            ForEach(rows.indices, id: \.self) { ProgressRow(label: rows[$0].0, progress: rows[$0].1) }
            NetworkUploadRow(network: net)
        }.padding().frame(width: 320)
        DebugRender.render(view, size: nil, name: "progress", to: dir, settle: 0)
    }
}

/// One renderer for every debug snapshot: the view in a window, light then dark, to `<name>-<appearance>.png`.
/// A nil size uses the view's fitting size.
@MainActor
enum DebugRender {
    static func render<V: View>(_ view: V, size: CGSize?, name: String, to dir: URL, settle: Double) {
        for (label, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
            host.appearance = NSAppearance(named: appearance)
            let frame = NSRect(origin: .zero, size: size ?? host.fittingSize)
            let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = host.appearance
            window.contentView = host
            host.frame = frame
            window.orderBack(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(settle))
            window.layoutIfNeeded(); host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name)-\(label).png"))
            window.orderOut(nil)
        }
    }
}
#endif
