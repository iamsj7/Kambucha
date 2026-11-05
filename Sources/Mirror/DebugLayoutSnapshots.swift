#if DEBUG
import SwiftUI
import AppKit
import MirrorCore

/// Debug-only: the whole main window, toolbar and sidebar included, on every screen with the owner's amount of data and
/// with a lot of it, at the smallest, usual and largest window sizes. `--snapshot-only <text>` keeps the names containing it.
@MainActor
enum DebugLayoutSnapshots {
    private struct FakeArchive: ArchiveProviding {
        var runs: Int
        var fails = false
        var hangs = false

        func list(set: BackupSet, destination: Destination) async throws -> [ArchiveEntry] {
            if fails { throw AgentFailure.driveNotConnected }
            if hangs { try await Task.sleep(for: .seconds(600)) }
            let now = Date()
            return (0..<runs).flatMap { run in
                (0..<40).map { i in
                    let stamp = now.addingTimeInterval(-Double(run) * 21_600 - 600)
                    let rel = "\(Self.folder(stamp))/client-\(i % 3)/report-\(i).pdf"
                    return ArchiveEntry(id: "\(set.name)/\(rel)", setName: set.name, stamp: stamp, path: "Archive/\(set.name)/\(rel)",
                                        size: Int64(1_000 + i * 3_700))
                }
            }
        }
        func browse(path: String, set: BackupSet, destination: Destination) async throws -> [BackupItem] {
            if fails { throw AgentFailure.driveNotConnected }
            if hangs { try await Task.sleep(for: .seconds(600)) }
            return runs == 0 ? [] : (0..<(runs > 5 ? 40 : 4)).map {
                $0 % 3 == 2 ? BackupItem(name: "notes-\($0).md", isFolder: false, size: 4_100) : BackupItem(name: "client-site-\($0)", isFolder: true, size: 0)
            }
        }
        func restore(entry: ArchiveEntry, set: BackupSet, destination: Destination, to: URL, replacing: Bool) async throws {}

        private static func folder(_ date: Date) -> String {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
            return f.string(from: date)
        }
    }

    private static func services(_ archive: FakeArchive) -> AppServices {
        AppServices(preview: AppServices.live.preview, dryRun: AppServices.live.dryRun, inspector: nil, volumes: DebugCoverageSnapshots.Volumes(),
                    agent: .bundled(in: Bundle.main.bundleURL), archive: archive)
    }

    private static func spin(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    /// A folder of data on disk, ready for a model.
    private struct Data {
        var label: String
        var support: URL
        var runs: Int
    }

    /// What the owner has now: two sets, one destination.
    private static func small() -> Data {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mirror-layout-small-\(UUID().uuidString)")
        let store = ConfigStore(root: root)
        let icloud = Destination(name: "iCloud Drive", kind: .iCloudFolder)
        var projects = BackupSet(name: "Projects", source: URL(fileURLWithPath: "/Users/me/Projects"), destinationIDs: [icloud.id])
        var documents = BackupSet(name: "Documents", source: URL(fileURLWithPath: "/Users/me/Documents"), destinationIDs: [icloud.id])
        projects.rules = [UserRule(pattern: "*.log", action: .exclude), UserRule(pattern: "/Drafts/**", action: .include)]
        projects.acceptPreview(); documents.acceptPreview()
        try? store.saveDestinations([icloud]); try? store.saveSets([projects, documents])
        for s in [projects, documents] {
            var st = SetState(); st.lastFinished = Date().addingTimeInterval(-600); st.lastFileCount = 48_210
            try? store.save(st, for: PairID(set: s.id, destination: icloud.id))
        }
        addRuns(count: 6, sets: [projects, documents], destination: icloud, root: root)
        return Data(label: "small", support: root, runs: 3)
    }

    /// 50 sets, 10 destinations, 200 rules on the first set and a long history.
    private static func large() -> Data {
        let root = DebugCoverageSnapshots.fixture(sets: 50)
        let store = ConfigStore(root: root)
        var sets = (try? store.loadSets()) ?? []
        sets[0].rules = (0..<200).map { UserRule(pattern: $0 % 7 == 0 ? "/Drafts/part\($0)/**" : "*.tmp\($0)", action: $0 % 5 == 0 ? .include : .exclude) }
        sets[0].presets = ["node", "ios"]
        sets[0].acceptPreview()
        try? store.saveSets(sets)
        if let d = try? store.loadDestinations().first { addRuns(count: 300, sets: sets, destination: d, root: root) }
        return Data(label: "large", support: root, runs: 40)
    }

    private static func addRuns(count: Int, sets: [BackupSet], destination: Destination, root: URL) {
        let store = RunRecordStore(root: root)
        let now = Date()
        for i in 0..<count {
            let s = sets[i % sets.count]
            let failed = i % 5 == 3
            var r = RunRecord(setID: s.id, setName: s.name, destinationID: destination.id, destinationName: destination.name,
                              start: now.addingTimeInterval(-Double(i) * 3_600 - 600), end: now.addingTimeInterval(-Double(i) * 3_600),
                              trigger: .schedule, scope: "all", filesChecked: 48_210, copied: failed ? 0 : 12 + i, deleted: 0,
                              verification: failed ? "Not run" : "Quick check passed",
                              errors: failed ? ["Couldn't reach \(destination.name)"] : [], status: failed ? .failed : .success)
            r.archived = i % 2 == 0 ? 2 : 0
            try? store.append(r)
        }
    }

    /// Every banner at once: a set with a name conflict that needs a preview, and a Recovery Kit due for a test.
    private static func banners() -> Data {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mirror-layout-banners-\(UUID().uuidString)")
        let store = ConfigStore(root: root)
        var drive = Destination(name: "Google Drive", kind: .googleDrive); drive.encrypted = true; drive.recoveryKitConfirmed = true
        let projects = BackupSet(name: "Projects", source: URL(fileURLWithPath: "/Users/me/Projects"), destinationIDs: [drive.id])
        try? store.saveDestinations([drive]); try? store.saveSets([projects])
        var st = SetState(); st.lastFinished = Date().addingTimeInterval(-600); st.stoppedBy = .setNameInUse
        try? store.save(st, for: PairID(set: projects.id, destination: drive.id))
        return Data(label: "banners", support: root, runs: 3)
    }

    /// A blank support folder for the screens' empty states.
    private static func blank() -> Data {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mirror-layout-blank-\(UUID().uuidString)")
        try? ConfigStore(root: root).saveSets([]); try? ConfigStore(root: root).saveDestinations([])
        return Data(label: "blank", support: root, runs: 0)
    }

    private struct Screen {
        var name: String
        var selection: (AppModel) -> SidebarSelection
        var pane = SetPane.status
        var archive: FakeArchive?
        var prepare: (ArchiveModel) -> Void = { _ in }
        /// How far down the page's list to look.
        var scroll: CGFloat?
    }

    private static func title(_ screen: Screen, _ model: AppModel) -> String {
        switch screen.name {
        case "overview": "Overview"
        case "coverage": "Coverage"
        case "several": "2 Sets"
        case "destination": model.destinations.first?.name ?? "Overview"
        case "activity": "Activity"
        case "settings": "Settings"
        case let n where n.hasPrefix("archive"): "Archive"
        default: model.sets.first?.name ?? "Overview"
        }
    }

    /// A folder restore refused, which is what leaves the restore bar up without a real restore.
    private static func refuseRestore(_ m: ArchiveModel) {
        m.loadConfig()
        let source = m.selectedSet?.source
        Task { await m.restoreLatest(nil) { _ in source } }
    }

    private static func screens(_ data: Data) -> [Screen] {
        func firstSet(_ m: AppModel) -> SidebarSelection { SidebarSelection(m.sets.first.map { .set($0.id) } ?? .overview) }
        let archive = FakeArchive(runs: data.runs)
        if data.label == "banners" {
            return [Screen(name: "set-status", selection: firstSet, pane: .status), Screen(name: "set-included", selection: firstSet, pane: .included),
                    Screen(name: "archive-older", selection: { _ in SidebarSelection(.archive) }, archive: archive, prepare: refuseRestore),
                    Screen(name: "archive-empty", selection: { _ in SidebarSelection(.archive) }, archive: FakeArchive(runs: 0), prepare: refuseRestore)]
        }
        var out = [
            Screen(name: "overview", selection: { _ in SidebarSelection(.overview) }),
            Screen(name: "coverage", selection: { _ in SidebarSelection(.coverage) }),
            Screen(name: "several", selection: { SidebarSelection(sets: Set($0.sets.prefix(2).map(\.id))) }),
            Screen(name: "destination", selection: { SidebarSelection($0.destinations.first.map { .destination($0.id) } ?? .overview) }),
            Screen(name: "archive-older", selection: { _ in SidebarSelection(.archive) }, archive: archive),
            Screen(name: "archive-latest", selection: { _ in SidebarSelection(.archive) }, archive: archive, prepare: { $0.mode = .latest }),
            Screen(name: "archive-search", selection: { _ in SidebarSelection(.archive) }, archive: archive, prepare: { $0.query = "report-1" }),
            Screen(name: "archive-empty", selection: { _ in SidebarSelection(.archive) }, archive: FakeArchive(runs: 0)),
            Screen(name: "archive-failed", selection: { _ in SidebarSelection(.archive) }, archive: FakeArchive(runs: 0, fails: true)),
            Screen(name: "archive-loading", selection: { _ in SidebarSelection(.archive) }, archive: FakeArchive(runs: 0, hangs: true)),
            Screen(name: "activity", selection: { _ in SidebarSelection(.activity) }),
        ]
        for pane in SetPane.allCases {
            out.append(Screen(name: "set-\(pane.rawValue)", selection: firstSet, pane: pane))
        }
        out.append(Screen(name: "set-rules", selection: firstSet, pane: .included, scroll: 640))
        return out
    }

    /// The list in the sidebar, which is at the window's left edge. Lists elsewhere in the window aren't.
    private static func sidebarList(in view: NSView) -> NSOutlineView? {
        if let list = view as? NSOutlineView, list.convert(list.bounds, to: nil).minX == 0 { return list }
        return view.subviews.lazy.compactMap(sidebarList).first
    }

    private static func open(_ view: some View, title: String, subtitle: String, size: CGSize) -> NSWindow {
        let controller = NSHostingController(rootView: view)
        controller.sceneBridgingOptions = .all
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.appearance = NSAppearance(named: .aqua)
        window.setFrame(NSRect(origin: NSPoint(x: 40, y: 40), size: size), display: true)
        window.orderBack(nil)
        spin(1.2)
        // The toolbar's title isn't bridged from a hosting controller outside a scene.
        window.title = title
        window.subtitle = subtitle
        window.setFrame(NSRect(origin: NSPoint(x: 40, y: 40), size: size), display: true)
        spin(0.3)
        return window
    }

    private static func capture(_ window: NSWindow) -> NSBitmapImageRep? {
        guard let frame = window.contentView?.superview, let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { return nil }
        frame.cacheDisplay(in: frame.bounds, to: rep)
        return rep
    }

    private static func save(_ rep: NSBitmapImageRep, name: String, to dir: URL) {
        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
    }

    /// `cacheDisplay` leaves out what's in the sidebar's glass, which a titled window has and a borderless one doesn't. So the
    /// sidebar comes from a second render, without a toolbar, and goes in under the first one's toolbar. Both end at the bottom.
    private static func addSidebar(to rep: NSBitmapImageRep, from view: some View, width: CGFloat, toolbar: CGFloat) {
        let height = rep.size.height - toolbar
        let host = NSHostingView(rootView: view)
        let frame = NSRect(x: 0, y: 0, width: rep.size.width, height: height)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        host.frame = frame
        window.orderBack(nil)
        spin(0.5)
        if let part = host.bitmapImageRepForCachingDisplay(in: host.bounds), let context = NSGraphicsContext(bitmapImageRep: rep) {
            host.cacheDisplay(in: host.bounds, to: part)
            let area = NSRect(x: 0, y: 0, width: width, height: height)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            part.draw(in: area, from: area, operation: .copy, fraction: 1, respectFlipped: false, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
        }
        window.orderOut(nil)
    }

    private static func pageList(in view: NSView) -> NSOutlineView? {
        if let list = view as? NSOutlineView, list.convert(list.bounds, to: nil).minX > 0 { return list }
        return view.subviews.lazy.compactMap(pageList).first
    }

    private static func render(_ view: () -> some View, title: String, subtitle: String, size: CGSize, scroll: CGFloat?, name: String, to dir: URL) {
        let window = open(view(), title: title, subtitle: subtitle, size: size)
        if let scroll, let clip = window.contentView.flatMap(pageList)?.enclosingScrollView?.contentView {
            clip.scroll(to: NSPoint(x: 0, y: scroll))
            spin(0.5)
        }
        let sidebar = window.contentView.flatMap(sidebarList)?.bounds.width ?? 230
        let toolbar = window.contentLayoutRect.minY == 0 ? window.frame.height - window.contentLayoutRect.height : 52
        let rep = capture(window)
        window.orderOut(nil)
        window.close()
        guard let rep else { return }
        addSidebar(to: rep, from: view(), width: sidebar, toolbar: toolbar)
        save(rep, name: name, to: dir)
    }

    /// One window, moved around the sidebar as a click would: each screen's toolbar must leave with it.
    private static func snapshotSwitching(to dir: URL) {
        let data = small()
        let model = AppModel(support: data.support, services: services(FakeArchive(runs: data.runs)))
        spin(0.5)
        model.reload()
        SetPaneMemory.last = .included
        let window = open(MainWindow(model: model, skipsOnboarding: true), title: "", subtitle: "", size: CGSize(width: 1100, height: 700))
        guard let list = window.contentView.flatMap(sidebarList) else { return }
        for (step, row) in [3, 0, 8, 3, 9, 10, 1, 4, 6, 8, 0].enumerated() {
            list.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            spin(1.2)
            let items = window.toolbar?.items.map { $0.label.isEmpty ? $0.itemIdentifier.rawValue.suffix(24).description : $0.label } ?? []
            print("switch", step, "row", row, items)
            if let rep = capture(window) { save(rep, name: "switch-\(step)-row\(row)", to: dir) }
        }
        window.orderOut(nil)
        window.close()
    }

    static func snapshotAll(to dir: URL, only: String?) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if only == nil || only == "switch" { snapshotSwitching(to: dir) }
        if only == "switch" { return }
        let sizes = [CGSize(width: 900, height: 480), CGSize(width: 1040, height: 700), CGSize(width: 1100, height: 700), CGSize(width: 1800, height: 1050)]
        for make in [small, large, banners, blank] {
            let data = make()
            for screen in screens(data) {
                if let only, !"\(data.label)-\(screen.name)".contains(only) { continue }
                let model = AppModel(support: data.support, services: services(screen.archive ?? FakeArchive(runs: data.runs)))
                spin(0.5)
                model.reload()
                spin(0.2)
                for size in sizes {
                    let name = "\(data.label)-\(screen.name)-\(Int(size.width))"
                    if let only, !name.contains(only) { continue }
                    SetPaneMemory.last = screen.pane
                    render({
                        let archive = ArchiveModel(provider: model.services.archive, store: ConfigStore(root: model.support), debounce: .zero)
                        screen.prepare(archive)
                        return MainWindow(model: model, selection: screen.selection(model), skipsOnboarding: true, archive: archive)
                    }, title: title(screen, model), subtitle: screen.name == "archive-latest" ? model.sets.first?.name ?? "" : "", size: size, scroll: screen.scroll, name: name, to: dir)
                }
            }
        }
    }
}
#endif
