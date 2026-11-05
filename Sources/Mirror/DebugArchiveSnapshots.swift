#if DEBUG
import SwiftUI
import AppKit
import MirrorCore

/// Debug-only: the Archive screen at the sizes it has to cope with, rendered to PNGs and timed.
@MainActor
enum DebugArchiveSnapshots {
    /// 100,000 files over 40 runs, the newest of them a mass delete of 20,000. `flat` puts that run in no folder at all.
    private struct BigArchive: ArchiveProviding {
        var flat = false
        var unreachable: String?

        func list(set: BackupSet, destination: Destination) async throws -> [ArchiveEntry] {
            if destination.name == unreachable { throw AgentFailure.driveNotConnected }
            let now = Date()
            var entries: [ArchiveEntry] = []
            entries.reserveCapacity(100_000)
            for run in 0..<40 {
                let stamp = now.addingTimeInterval(-Double(run) * 21_600)
                let folder = ArchiveStampText.string(stamp)
                for i in 0..<(run == 0 ? 20_000 : 2_051) {
                    let inside = flat && run == 0 ? "" : "client-\(i % 12)/src/module-\(i % 40)/"
                    let rel = "\(folder)/\(inside)report-\(i).pdf"
                    entries.append(ArchiveEntry(id: "\(set.name)/\(rel)", setName: set.name, stamp: stamp,
                                                path: "Archive/\(set.name)/\(rel)", size: Int64(1_000 + i * 37)))
                }
            }
            return entries
        }
        func browse(path: String, set: BackupSet, destination: Destination) async throws -> [BackupItem] { [] }
        func restore(entry: ArchiveEntry, set: BackupSet, destination: Destination, to: URL, replacing: Bool) async throws {}
    }

    private enum ArchiveStampText {
        static func string(_ date: Date) -> String {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
            return f.string(from: date)
        }
    }

    private static func settle(until done: () -> Bool) {
        let deadline = Date().addingTimeInterval(30)
        while !done(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    static func snapshotAll(store: ConfigStore, sets: [BackupSet], destinations: [Destination], to dir: URL) {
        let size = CGSize(width: 720, height: 520)

        let big = ArchiveModel(provider: BigArchive(), store: store)
        big.loadConfig()
        Task { await big.reload() }
        settle { if case .loaded = big.phase { true } else { false } }
        DebugRender.render(ArchiveView(model: big, agent: nil), size: size, name: "archive-big", to: dir, settle: 1)

        // All 20,000 of the newest run's files in one place, opened.
        let flat = ArchiveModel(provider: BigArchive(flat: true), store: store)
        flat.loadConfig()
        Task { await flat.reload() }
        settle { if case .loaded = flat.phase { true } else { false } }
        DebugRender.render(ArchiveView(model: flat, agent: nil), size: size, name: "archive-big-flat", to: dir, settle: 1)

        // A search, with one destination out of reach.
        let search = ArchiveModel(provider: BigArchive(unreachable: destinations.first?.name), store: store, debounce: .zero)
        search.loadConfig()
        search.query = "report-1999"
        settle { search.results.query == "report-1999" && !search.results.isReading }
        DebugRender.render(ArchiveView(model: search, agent: nil), size: size, name: "archive-search", to: dir, settle: 1)

        renderWithToolbar(NavigationStack { ArchiveView(model: search, agent: nil) }, size: CGSize(width: 760, height: 300),
                          name: "archive-toolbar", to: dir)
    }

    /// `DebugRender` draws the content only, and the search field lives in the toolbar.
    private static func renderWithToolbar<V: View>(_ view: V, size: CGSize, name: String, to dir: URL) {
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.styleMask = [.titled, .resizable, .fullSizeContentView]
        window.setContentSize(size)
        window.orderBack(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        guard let frame = window.contentView?.superview, let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { return }
        frame.cacheDisplay(in: frame.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
        window.orderOut(nil)
    }
}
#endif
