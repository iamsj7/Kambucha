import SwiftUI
import AppKit
import MirrorCore

/// A menu item has one line that never wraps, so long words are cut here rather than widening the menu past the screen.
enum MenuText {
    static let limit = 64

    /// The first sentence, or the start of it, of a message.
    static func short(_ text: String) -> String {
        let first = text.split(separator: ". ", maxSplits: 1).first.map(String.init) ?? text
        return first.count <= limit ? first : first.prefix(limit - 1).trimmingCharacters(in: .whitespaces) + "…"
    }
}

/// The real menu under the menu bar icon. Items are SwiftUI's, so AppKit draws them, and a Text is a dimmed line that can't
/// be chosen. There are no bars here, as a menu can't hold them: the set's page has those.
struct MenuBarPanel: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    /// Rows are capped, so 50 failing sets can't push the actions off the screen.
    private static let rowLimit = 5

    var body: some View {
        let p = StatusPresentation(model.status)
        let health = HealthSummary(model.rows.map { SetHealth(id: $0.id, name: $0.name, status: $0.status) })
        let live = model.progress
        let rows = PanelRows(attention: health.attention.count, progress: live.count, limit: Self.rowLimit)

        Text(p.title)
        if let detail = p.detail { Text(MenuText.short(detail)) }
        if health.isCalm || rows.isEmpty {
            if let line = health.countLine { Text(line) }
        } else {
            ForEach(live.prefix(rows.progress)) { Text(MenuText.short(ProgressPresentation(progress: $0.progress).menuLine(label: $0.label))) }
            Divider()
            ForEach(health.attention.prefix(rows.attention)) { item in
                Button(MenuText.short("\(item.name): \(item.status.shortText)")) { showOverview() }
            }
            if rows.more > 0 {
                Button("\(rows.more.formatted()) More…") { showOverview() }
                    .accessibilityHint("Opens Mirror. The Overview lists all of them")
            }
        }
        if let err = model.lastError {
            Divider()
            Button(MenuText.short(err)) { openMirror() }
            Button("Dismiss Message") { model.dismissError() }
        }
        if let held = model.heldSet {
            Divider()
            Button("Review Deletions…") { model.allowDeletes(held.id); openMirror() }
                .accessibilityHint("Shows the files that would be deleted from the backup")
            Button("Keep Holding") { model.keepHolding() }
                .accessibilityHint("Leaves the deletions on hold. New and changed files keep backing up")
        }
        Divider()
        Button("Back Up Now") { model.runNow(nil) }
            .disabled(!model.canBackUp)
        Button(model.pauseTitle) { model.togglePause() }
            .disabled(!model.canPause)
        Divider()
        Button("Open Mirror") { openMirror() }
        Button("Settings…") { openSettings(); NSApplication.shared.activate() }
            .keyboardShortcut(",")
        Divider()
        Button("Quit Mirror") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func showOverview() { model.showOverview(); openMirror() }

    private func openMirror() {
        openWindow(id: "main")
        NSApplication.shared.activate()
    }
}

extension OverallStatus {
    /// Short wording for a set row.
    var shortText: String {
        switch self {
        case .backedUp: "Backed Up"
        case .uploading(let n): "Uploading \(n.formatted())"
        case .waitingForDownload: "Didn't Match"
        case .notAccepted(let n): "\(n.formatted()) not accepted"
        case .unfinished: "Not Finished"
        case .running: "Backing Up"
        case .held(let n): "\(n.formatted()) held"
        case .attention: "Needs Attention"
        case .driveNotConnected: "Not Connected"
        case .paused: "Paused"
        case .notConfigured: "Not Set Up"
        }
    }
}
