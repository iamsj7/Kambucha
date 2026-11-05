import SwiftUI
import AppKit
import MirrorCore

/// A destination as Coverage needs it, worked out once per render and not per cell.
struct CoverageColumn: Identifiable, Equatable {
    var destination: Destination
    var status: DestinationStatus
    var driveAway: Bool
    var needsDiskConfirmation: Bool
    var id: UUID { destination.id }
}

extension AppModel {
    /// Before the first read of the mounted drives no drive is called away, as the status files aren't either.
    var coverageColumns: [CoverageColumn] {
        let volumes = volumeCache.volumes
        let away = volumeCache.hasLoaded ? ExternalVolume.disconnected(destinations, in: volumes) : []
        return destinations.map { d in
            CoverageColumn(destination: d, status: destinationStatus(d), driveAway: away.contains(d.id),
                           needsDiskConfirmation: ExternalDriveSetup.needsConfirmation(d, volume: ExternalVolume.find(d, in: volumes)))
        }
    }

    func coverageCell(_ set: BackupSet, _ column: CoverageColumn) -> CoverageCell {
        CoverageCell.make(set: set, destination: column.destination,
                          status: pairStatus[PairID(set: set.id, destination: column.id)],
                          driveAway: column.driveAway, needsDiskConfirmation: column.needsDiskConfirmation)
    }
}

/// A cell in words and a symbol. `short` fits the cell, `detail` is for the tooltip and VoiceOver.
struct CoveragePresentation: Equatable {
    let symbol: String
    let short: String
    let detail: String

    init(_ cell: CoverageCell) {
        switch cell {
        case .off:
            symbol = "minus.circle"; short = "Off"; detail = "Off"
        case .confirmDisk:
            symbol = "exclamationmark.triangle"; short = "Confirm Disk"; detail = "Confirm this internal disk"
        case .saveRecoveryKit:
            symbol = "exclamationmark.triangle"; short = "Save Kit"; detail = "Save your Recovery Kit"
        case .status(.attention(let why)):
            symbol = StatusPresentation(.attention(why)).symbol
            // Each is a pair of one, so the name that follows "Preview needed" is already on the row.
            if why.hasPrefix("Preview needed") { short = "Preview Needed"; detail = "Preview needed" }
            else if why == "Not backed up yet" { short = "Not Backed Up"; detail = why }
            else { short = OverallStatus.attention(why).shortText; detail = why }
        case .status(let status):
            let p = StatusPresentation(status)
            symbol = p.symbol; short = status.shortText
            detail = [p.title, p.detail].compactMap(\.self).joined(separator: ". ")
        }
    }
}

extension CoverageCell.Kind {
    /// Goes with the words and the symbol, never in place of them.
    var tint: Color {
        switch self {
        case .attention: .orange
        case .backedUp: .green
        case .off, .paused, .working, .notConnected: .secondary
        }
    }
}

/// Sets down the side, destinations along the top. Not a `Table`, though `TableColumnForEach` is there: a table's first
/// column scrolls away sideways, and with 10 destinations the owner would lose which set a row is. So this is one
/// two-axis scroll view, with lazy rows, the header pinned by the stack and the set names pinned by offset.
struct CoverageView: View {
    @Bindable var model: AppModel
    /// In the sidebar's order, with its filter applied.
    let rows: [SetRow]
    let filter: String
    var select: (SidebarItem) -> Void
    /// The pointer is over the grid, so rows hold still as they do in the sidebar.
    var hovering: (Bool) -> Void = { _ in }
    @State private var turningOff: TurnOffRequest?
    @State private var width: CGFloat = 0

    static let rowHeight: CGFloat = 32

    private struct TurnOffRequest: Equatable {
        var set: UUID, setName: String, destination: UUID, destinationName: String
    }

    var body: some View {
        Group {
            if model.sets.isEmpty {
                PageState {
                    ContentUnavailableView("No Backup Sets", systemImage: "folder",
                                           description: Text("Add a folder to start backing it up."))
                }
            } else if model.destinations.isEmpty {
                PageState {
                    ContentUnavailableView("No Destinations", systemImage: "externaldrive",
                                           description: Text("Add a place to keep your backups."))
                }
            } else if rows.isEmpty {
                PageState { ContentUnavailableView.search(text: filter) }
            } else {
                grid
            }
        }
        .measuringWidth($width)
        .navigationTitle("Coverage")
        // The view can go with the pointer still inside it, and then no hover ends.
        .onDisappear { hovering(false) }
        .confirmationDialog(turningOff.map { CoverageTurnOff.title(set: $0.setName, destination: $0.destinationName) } ?? "",
                            isPresented: Binding(get: { turningOff != nil }, set: { if !$0 { turningOff = nil } }),
                            titleVisibility: .visible, presenting: turningOff) { request in
            // Not destructive, as the owner chose this by turning the cell off. The shortcut keeps it off Return, as in MainWindow.
            Button(CoverageTurnOff.button) {
                model.setDestination(request.destination, on: false, for: request.set)
            }
            .keyboardShortcut("t", modifiers: .command)
            Button("Cancel", role: .cancel) {}
        } message: { request in
            Text(CoverageTurnOff.message(destination: request.destinationName,
                                         isLast: model.set(request.set)?.destinationIDs == [request.destination]))
        }
    }

    private var grid: some View {
        let columns = model.coverageColumns
        let layout = CoverageLayout(available: width - Self.scrollerWidth, columns: columns.count)
        return ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    ForEach(rows) { row in
                        if let set = model.set(row.id) {
                            CoverageRow(row: row, set: set, columns: columns, layout: layout, model: model, select: select) { column in
                                turningOff = TurnOffRequest(set: set.id, setName: set.name, destination: column.id,
                                                            destinationName: column.destination.name)
                            }
                            .frame(height: Self.rowHeight)
                            Divider()
                        }
                    }
                } header: {
                    CoverageHeader(columns: columns, layout: layout, select: select)
                }
            }
            .frame(width: layout.width)
        }
        .defaultScrollAnchor(.topLeading)
        .background(.background)
        .onHover(perform: hovering)
    }

    /// A scroller that takes up room, as it does with a mouse attached, comes out of what the columns can share.
    private static var scrollerWidth: CGFloat {
        NSScroller.preferredScrollerStyle == .legacy ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
    }
}

private extension View {
    /// Keeps a view at the leading edge while the grid scrolls sideways. An effect, not state, so it moves in the same
    /// frame as the scroll and costs no render of the rows.
    func pinnedToLeadingEdge() -> some View {
        visualEffect { content, proxy in
            content.offset(x: max(0, -proxy.frame(in: .scrollView).minX))
        }
        .zIndex(1)
    }
}

private struct CoverageHeader: View {
    let columns: [CoverageColumn]
    let layout: CoverageLayout
    var select: (SidebarItem) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("Set").font(.headline)
                    .padding(.horizontal, PageLayout.dataInset)
                    .frame(width: layout.name, height: 40, alignment: .leading)
                    .background(.background)
                    .pinnedToLeadingEdge()
                ForEach(columns) { column in
                    Button { select(.destination(column.id)) } label: {
                        Label(column.destination.name, systemImage: column.destination.kind.symbol)
                            .font(.subheadline.weight(.semibold)).lineLimit(2)
                            .padding(.horizontal, 8)
                            .frame(width: layout.column, height: 40, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("\(column.destination.name): \(column.status.text)")
                    .accessibilityLabel(column.destination.name)
                    .accessibilityValue(column.status.text)
                    .accessibilityHint("Opens this destination")
                }
                Spacer(minLength: 0)
            }
            Divider()
        }
        .background(.background)
    }
}

private struct CoverageRow: View {
    let row: SetRow
    let set: BackupSet
    let columns: [CoverageColumn]
    let layout: CoverageLayout
    let model: AppModel
    var select: (SidebarItem) -> Void
    var askToTurnOff: (CoverageColumn) -> Void

    var body: some View {
        let p = StatusPresentation(row.status)
        HStack(spacing: 0) {
            Button { select(.set(row.id)) } label: {
                Label {
                    Text(row.name).lineLimit(1).truncationMode(.middle)
                } icon: {
                    Image(systemName: p.symbol).foregroundStyle(row.status.needsAttention ? Color.orange : .secondary)
                        .frame(width: 20)
                }
                .padding(.horizontal, PageLayout.dataInset)
                .frame(width: layout.name, height: CoverageView.rowHeight, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(.background)
            .help("\(row.name): \(p.title)")
            .accessibilityLabel("\(row.name), \(p.title)")
            .accessibilityHint("Opens this set")
            .pinnedToLeadingEdge()
            ForEach(columns) { column in
                CoverageCellView(cell: model.coverageCell(set, column), setName: row.name, destinationName: column.destination.name,
                                 width: layout.column, isOn: Binding(get: { set.destinationIDs.contains(column.id) }, set: { on in
                                     if on { model.setDestination(column.id, on: true, for: set.id) } else { askToTurnOff(column) }
                                 }))
            }
            Spacer(minLength: 0)
        }
        .contextMenu { SetBatchActions(model: model, ids: [row.id]) }
        .accessibilityElement(children: .contain)
    }
}

private struct CoverageCellView: View {
    let cell: CoverageCell
    let setName: String
    let destinationName: String
    let width: CGFloat
    @Binding var isOn: Bool

    var body: some View {
        let p = CoveragePresentation(cell)
        Toggle(isOn: $isOn) {
            HStack(spacing: 4) {
                Image(systemName: p.symbol).foregroundStyle(cell.kind.tint).frame(width: 20)
                Text(p.short).lineLimit(1).foregroundStyle(cell == .off ? .secondary : .primary)
            }
            .font(.callout)
        }
        .toggleStyle(.checkbox)
        .padding(.horizontal, 8)
        .frame(width: width, alignment: .leading)
        .help("\(destinationName): \(p.detail)")
        .accessibilityLabel("\(setName) to \(destinationName), \(p.detail)")
        .accessibilityHint("Turns this destination on or off for the set")
    }
}

// MARK: Several sets

/// The actions on one or several sets. In the sidebar's and Coverage's context menus, and the summary of several.
struct SetBatchActions: View {
    let model: AppModel
    let ids: Set<UUID>

    var body: some View {
        let batch = SetBatch(sets: model.sets.filter { ids.contains($0.id) })
        let addable = batch.addable(model.destinations)
        Button("Back Up Now") { model.runNow(sets: ids) }
            .disabled(!batch.canBackUp)
        Button("Pause") { model.setPaused(true, sets: ids) }
            .disabled(!batch.canPause)
        Button("Resume") { model.setPaused(false, sets: ids) }
            .disabled(!batch.canResume)
        Menu("Add to Destination") {
            ForEach(addable) { d in
                Button(d.name) { model.addDestination(d.id, to: ids) }
            }
        }
        .disabled(addable.isEmpty)
    }
}

/// The detail pane while more than one set is selected.
struct SeveralSetsView: View {
    let model: AppModel
    /// By name: these are buttons, and the hold that keeps the sidebar still doesn't reach here.
    let rows: [SetRow]
    /// How many of them the filter is hiding in the sidebar. The actions here still reach those.
    var hidden = 0
    var select: (SidebarItem) -> Void

    var body: some View {
        let summary = SetBatch.summary(attention: rows.filter(\.status.needsAttention).count, paused: rows.filter(\.isPaused).count)
        ReadingForm {
            Section {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(rows.count.formatted()) Sets Selected").font(.title2.weight(.semibold))
                    if let summary { Text(summary).foregroundStyle(.secondary) }
                    if let note = SetBatch.hiddenNote(count: hidden) { Text(note).foregroundStyle(.secondary) }
                }
                .accessibilityElement(children: .combine)
            }
            Section {
                SetBatchActions(model: model, ids: Set(rows.map(\.id)))
            }
            Section("Selected") {
                ForEach(rows) { row in
                    Button { select(.set(row.id)) } label: {
                        LabeledContent(row.name) { Text(row.status.shortText) }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(row.name), \(StatusPresentation(row.status).title)")
                    .accessibilityHint("Opens this set")
                }
            }
        }
        .navigationTitle("\(rows.count.formatted()) Sets")
    }
}
