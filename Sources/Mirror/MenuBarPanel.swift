import SwiftUI
import AppKit
import MirrorCore

struct MenuBarPanel: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var network = NetworkStatus()

    private var busy: Bool { if case .running = model.status { true } else { false } }
    private var canBackUp: Bool {
        switch model.status {
        case .notConfigured, .paused, .running: false
        default: true
        }
    }
    private var heldRow: SetRow? { model.heldSet }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if !model.rows.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(model.rows) { SetRowView(row: $0) }
                }
            }
            if busy && !model.progress.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(model.progress) { ProgressRow(label: $0.label, progress: $0.progress) }
                    NetworkUploadRow(network: network)
                }
            }
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
                Divider()
                Button { NSApplication.shared.terminate(nil) } label: { Label("Quit Mirror", systemImage: "power") }
                    .keyboardShortcut("q")
            }
            .buttonStyle(.borderless)
            if let err = model.lastError {
                HStack(alignment: .top) {
                    Label(err, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.secondary)
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
    let row: SetRow
    var body: some View {
        let p = StatusPresentation(row.status)
        HStack(spacing: 8) {
            Image(systemName: p.symbol).accessibilityHidden(true)
            Text(row.name).lineLimit(1)
            Spacer(minLength: 8)
            Text(row.status.shortText).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.name), \(p.title)")
    }
}

extension OverallStatus {
    /// Short wording for a set row.
    var shortText: String {
        switch self {
        case .backedUp: "Backed Up"
        case .uploading(let n): "Uploading \(n.formatted())"
        case .waitingForDownload: "Waiting for iCloud"
        case .running: "Backing Up"
        case .held(let n): "\(n.formatted()) held"
        case .attention: "Needs Attention"
        case .paused: "Paused"
        case .notConfigured: "Not Set Up"
        }
    }
}
