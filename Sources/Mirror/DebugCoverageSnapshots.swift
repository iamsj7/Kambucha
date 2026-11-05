#if DEBUG
import SwiftUI
import AppKit
import MirrorCore

/// Debug-only: Coverage and the sidebar with 50 sets and 10 destinations, every state in the mix.
@MainActor
enum DebugCoverageSnapshots {
    struct Volumes: VolumeLocating {
        func mounted() -> [VolumeInfo] {
            [VolumeInfo(uuid: "A", name: "Backup SSD", mountPoint: URL(fileURLWithPath: "/Volumes/Backup SSD"), fileSystem: "apfs", freeBytes: 420_000_000_000),
             VolumeInfo(uuid: "B", name: "Archive", mountPoint: URL(fileURLWithPath: "/Volumes/Archive"), fileSystem: "apfs", freeBytes: 1_800_000_000_000, looksInternal: true)]
        }
    }

    static func fixture(sets setCount: Int) -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mirror-coverage-\(UUID().uuidString)")
        let store = ConfigStore(root: root)
        var google = Destination(name: "Google Drive", kind: .googleDrive); google.recoveryKitConfirmed = true
        var work = Destination(name: "Work OneDrive with a long name", kind: .oneDrive); work.recoveryKitConfirmed = true
        var dests = [Destination(name: "iCloud Drive", kind: .iCloudFolder), google, work,
                     Destination(name: "OneDrive", kind: .oneDrive),   // its Recovery Kit isn't saved
                     Destination(name: "Backup SSD", kind: .externalDrive, encrypted: false, volumeUUID: "A"),
                     Destination(name: "Archive", kind: .externalDrive, encrypted: false, volumeUUID: "B"),
                     Destination(name: "Travel SSD", kind: .externalDrive, encrypted: false, volumeUUID: "Z")]
        for i in 1...3 {
            var d = Destination(name: "Client Drive \(i)", kind: .googleDrive); d.recoveryKitConfirmed = true
            dests.append(d)
        }
        let names = ["Projects", "Documents", "Photos", "Music", "Client Sites", "Invoices", "Taxes", "Recipes", "Études", "Design"]
        let sets: [BackupSet] = (0..<setCount).map { i in
            var s = BackupSet(name: i < names.count ? names[i] : "Set \(i + 1)", source: URL(fileURLWithPath: "/Users/me/set-\(i)"),
                              destinationIDs: dests.enumerated().filter { ($0.offset + i) % 3 != 0 }.map(\.element.id))
            if i % 11 != 4 { s.acceptPreview() }
            s.isPaused = i % 13 == 7
            return s
        }
        try? store.saveDestinations(dests)
        try? store.saveSets(sets)
        let now = Date()
        for (i, s) in sets.enumerated() {
            for (j, id) in s.destinationIDs.enumerated() {
                var st = SetState()
                st.lastFinished = now.addingTimeInterval(-Double(i * 40 + j) * 600)
                st.lastFileCount = 4_000 + i * 31
                switch (i * 7 + j) % 17 {
                case 3: st.pendingUploads = 1_240 + i
                case 5: st.consecutiveFailures = 2
                case 8: st.heldDeletions = 310
                case 11: st.lastFinished = nil
                default: break
                }
                try? store.save(st, for: PairID(set: s.id, destination: id))
            }
        }
        return root
    }

    private static func model(sets setCount: Int = 50) -> AppModel {
        let root = fixture(sets: setCount)
        let services = AppServices(preview: AppServices.live.preview, dryRun: AppServices.live.dryRun, inspector: nil, volumes: Volumes(),
                                   agent: .bundled(in: Bundle.main.bundleURL), archive: AppServices.live.archive)
        let model = AppModel(support: root, services: services)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        model.reload()
        return model
    }

    private static func firstScrollView(in view: NSView) -> NSScrollView? {
        if let s = view as? NSScrollView { return s }
        return view.subviews.lazy.compactMap(firstScrollView).first
    }

    /// `DebugRender`, with the scroll view moved first.
    private static func render<V: View>(_ view: V, size: CGSize, scroll: CGPoint? = nil, name: String, to dir: URL) {
        for (label, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
            host.appearance = NSAppearance(named: appearance)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = host.appearance
            window.contentView = host
            window.orderBack(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            if let scroll, let s = firstScrollView(in: host) {
                s.contentView.scroll(to: scroll)
                s.reflectScrolledClipView(s.contentView)
                RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            }
            window.layoutIfNeeded(); host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name)-\(label).png"))
            window.orderOut(nil)
        }
    }

    static func snapshotAll(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let model = model()
        var order = SetOrder()
        order.update(model.rows.map { SetSortKey(id: $0.id, name: $0.name, needsAttention: $0.status.needsAttention) }, held: false)
        let rows = order.arranged(model.rows)
        func coverage() -> some View {
            NavigationStack { CoverageView(model: model, rows: rows, filter: "", select: { _ in }) }
        }
        let size = CGSize(width: 900, height: 620)
        render(coverage(), size: size, name: "coverage", to: dir)
        render(coverage(), size: size, scroll: CGPoint(x: 520, y: 700), name: "coverage-scrolled", to: dir)
        render(NavigationStack { CoverageView(model: model, rows: [], filter: "zzz", select: { _ in }) }, size: size, name: "coverage-no-match", to: dir)
        render(NavigationStack { SeveralSetsView(model: model, rows: Array(rows.prefix(4)), select: { _ in }) },
               size: CGSize(width: 620, height: 520), name: "several-sets", to: dir)
        render(MainWindow(model: model, selection: SidebarSelection(sets: Set(rows.prefix(3).map(\.id))), skipsOnboarding: true),
               size: CGSize(width: 1100, height: 720), name: "main-several", to: dir)
        render(MainWindow(model: model, selection: SidebarSelection(.coverage), skipsOnboarding: true),
               size: CGSize(width: 1100, height: 720), name: "main-coverage", to: dir)
    }
}
#endif
