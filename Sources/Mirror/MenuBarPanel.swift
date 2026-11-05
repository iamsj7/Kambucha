import SwiftUI
import AppKit
import MirrorCore

struct MenuBarPanel: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var network = NetworkStatus()

    private var busy: Bool { if case .running = model.status { true } else { false } }
    private var canBackUp: Bool {
        switch model.status {
        case .notConfigured, .paused, .running: false
        default: true
        }
    }
    private var heldRow: SetRow? { model.heldSet }
    private var health: HealthSummary { HealthSummary(model.rows.map { SetHealth(id: $0.id, name: $0.name, status: $0.status) }) }
    /// Panel rows are capped, so 50 failing sets can't push the actions off the screen.
    private static let rowLimit = 5

    /// Only what's active or needs a look; a calm line when there's nothing.
    @ViewBuilder private var summarySection: some View {
        let health = health
        let live = model.progress
        let rows = PanelRows(attention: health.attention.count, progress: live.count, limit: Self.rowLimit)
        if health.isCalm {
            if let line = health.countLine {
                Divider()
                Text(line).font(.subheadline).foregroundStyle(.secondary)
            }
        } else {
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                ForEach(health.attention.prefix(rows.attention)) { item in
                    SetRowView(name: item.name, status: item.status)
                }
                ForEach(live.prefix(rows.progress)) { ProgressRow(label: $0.label, progress: $0.progress) }
                if rows.more > 0 {
                    Button { openMirror("main") } label: { Text("\(rows.more.formatted()) more") }
                        .buttonStyle(.borderless).font(.subheadline)
                        .accessibilityHint("Opens Mirror to show all of them")
                }
                if !live.isEmpty { NetworkUploadRow(network: network) }
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            summarySection
            if let heldRow {
                HStack {
                    Button("Review Deletions") { review(heldRow.id) }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .accessibilityHint("Shows the files that would be deleted from the backup")
                    Button("Keep Holding") { model.keepHolding() }
                        .accessibilityHint("Leaves the deletions on hold. New and changed files keep backing up")
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Button { model.runNow(nil) } label: { Label("Back Up Now", systemImage: "arrow.clockwise.icloud") }
                    .disabled(!canBackUp)
                Button { model.setPaused(!model.isPaused) } label: {
                    Label(model.isPaused ? "Resume Backups" : "Pause Backups",
                          systemImage: model.isPaused ? "play.circle" : "pause.circle")
                }
                .disabled(model.sets.isEmpty)
                Button { openMirror("main") } label: { Label("Open Mirror", systemImage: "macwindow") }
                Button { openSettings(); NSApplication.shared.activate() } label: { Label("Settings…", systemImage: "gearshape") }
                Divider()
                Button { NSApplication.shared.terminate(nil) } label: { Label("Quit Mirror", systemImage: "power") }
                    .keyboardShortcut("q")
            }
            .buttonStyle(.borderless)
            if let err = model.lastError {
                HStack(alignment: .top) {
                    Label(err, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.secondary).lineLimit(3)
                    Spacer(minLength: 4)
                    Button("Dismiss") { model.dismissError() }.font(.footnote).buttonStyle(.borderless)
                }
            }
        }
        .padding()
        .frame(width: 320)
        .onAppear { model.panelAppeared(); network.start() }
        .onDisappear { model.panelDisappeared(); network.stop() }
    }

    private var header: some View {
        let p = StatusPresentation(model.status)
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: p.symbol).font(.title2).imageScale(.large).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(p.title).font(.headline)
                if let d = p.detail { Text(d).font(.subheadline).foregroundStyle(.secondary) }
                if busy { ProgressView().controlSize(.small).accessibilityLabel("Backing up") }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func review(_ id: UUID) {
        model.allowDeletes(id)
        openMirror("main")
    }

    private func openMirror(_ id: String) {
        openWindow(id: id)
        NSApplication.shared.activate()
    }
}

struct SetRowView: View {
    let name: String
    let status: OverallStatus
    var body: some View {
        let p = StatusPresentation(status)
        HStack(spacing: 8) {
            Image(systemName: p.symbol).accessibilityHidden(true)
            Text(name).lineLimit(1)
            Spacer(minLength: 8)
            Text(status.shortText).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name), \(p.title)")
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
