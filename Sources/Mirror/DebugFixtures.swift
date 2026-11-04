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
