import SwiftUI
import AppKit
import MirrorCore

/// What the sidebar can select. Archive and Activity are separate cases so Task 18 can swap in
/// `ArchiveView` and `ActivityView` by editing only `MainWindow.detail`.
enum SidebarItem: Hashable {
    case overview
    case coverage
    case set(UUID)
    case destination(UUID)
    case archive
    case activity
    case settings
}

/// What's selected in the sidebar. Several rows can be, but only sets: anything else is one place to go.
struct SidebarSelection: Equatable {
    private(set) var items: Set<SidebarItem>

    /// What the detail pane shows.
    enum Content: Equatable {
        case one(SidebarItem)
        case several(Set<UUID>)
    }

    init(_ item: SidebarItem = .overview) { items = [item] }

    /// Selects by id, so nothing here depends on where a row sits in the list.
    init(sets: Set<UUID>) { items = Set(sets.map(SidebarItem.set)) }

    mutating func select(_ item: SidebarItem) { items = [item] }

    static func setIDs(in items: Set<SidebarItem>) -> Set<UUID> {
        Set(items.compactMap { if case .set(let id) = $0 { id } else { nil } })
    }

    /// A context menu acts on what the owner can see, and the list may pass it rows the filter is hiding.
    static func setIDs(in items: Set<SidebarItem>, visible: Set<UUID>) -> Set<UUID> { setIDs(in: items).intersection(visible) }

    var setIDs: Set<UUID> { Self.setIDs(in: items) }

    /// A change from the list. Command-clicking something else moves there, and a shift-click across sections keeps
    /// the sets it covered. `extending` says Shift is down: one row added looks the same either way.
    mutating func change(to new: Set<SidebarItem>, extending: Bool = false) {
        let sets = Self.setIDs(in: new)
        if new.count <= 1 || sets.count == new.count { items = new; return }
        if extending && !sets.isEmpty { items = Set(sets.map(SidebarItem.set)); return }
        let added = new.subtracting(items)
        if added.count == 1, let only = added.first, Self.setIDs(in: added).isEmpty { items = [only] }
        else if !sets.isEmpty { items = Set(sets.map(SidebarItem.set)) }
        else if let kept = new.intersection(items).first ?? new.first { items = [kept] }
    }

    /// `live` holds the sets that still exist. Of several, those that went are dropped.
    func content(live: Set<UUID>) -> Content {
        let ids = setIDs
        guard ids.count > 1 else { return .one(items.first ?? .overview) }
        let left = ids.intersection(live)
        if left.count > 1 { return .several(left) }
        return .one(left.first.map(SidebarItem.set) ?? .overview)
    }
}

struct MainWindow: View {
    @Bindable var model: AppModel
    /// The Settings window's model, so the two never hold different copies of what's saved.
    let settings: SettingsModel
    @State private var selection: SidebarSelection
    @State private var setOrder = SetOrder()
    @State private var filter = ""
    @State private var pointerOverSidebar = false
    @State private var pointerOverCoverage = false
    @State private var addingSet = false
    @State private var addingDestination = false
    @State private var confirmingRemoval = false
    @State private var launchError: String?
    @State private var archive: ArchiveModel
    @State private var activity: ActivityModel
    @State private var onboarding: OnboardingModel
    @State private var firstPreview: ReviewTarget?
    /// For snapshots, which can't pass the real system checks.
    private let skipsOnboarding: Bool

    init(model: AppModel, settings: SettingsModel, selection: SidebarSelection = SidebarSelection(), skipsOnboarding: Bool = false,
         archive: ArchiveModel? = nil) {
        self.model = model
        self.settings = settings
        self.skipsOnboarding = skipsOnboarding
        _selection = State(initialValue: selection)
        _archive = State(initialValue: archive ?? ArchiveModel(provider: model.services.archive, store: ConfigStore(root: model.support)))
        _activity = State(initialValue: ActivityModel(support: model.support))
        _onboarding = State(initialValue: OnboardingModel(store: ConfigStore(root: model.support),
                                                          settings: SettingsStore(root: model.support)))
    }

    var body: some View {
        // Onboarding stays until every step is done. Nothing is shown until the first read of those
        // steps finishes, so a finished setup doesn't flash it.
        Group {
            if !skipsOnboarding && onboarding.hasRefreshed && !onboarding.isComplete {
                OnboardingView(model: onboarding)
            } else {
                split
            }
        }
        .task {
            while !Task.isCancelled && !skipsOnboarding {
                await onboarding.refresh()
                try? await Task.sleep(for: .seconds(onboarding.isComplete ? 30 : 2))
            }
        }
        // The Dock icon shows only while this window is open; the app is otherwise a menu bar item. Here and not on
        // the split view, or a first-run window would open behind whatever else is on screen.
        .onAppear { DockPresence.windowOpened(); model.windowAppeared() }
        .onDisappear { DockPresence.windowClosed(); model.windowDisappeared() }
        .onChange(of: model.overviewRequests) { selection.select(.overview) }
        .onChange(of: onboarding.setAwaitingPreview) { _, id in
            guard let id else { return }
            model.reload()
            onboarding.previewShown()
            selection.select(.set(id))
            firstPreview = ReviewTarget(id: id)
        }
    }

    private var split: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 320)
        } detail: {
            detail
        }
        .frame(minWidth: 760, minHeight: 480)
        .navigationTitle("Mirror")
        .searchable(text: $filter, placement: .sidebar, prompt: "Filter Sets")
        .onChange(of: orderKeys, initial: true) { updateOrder() }
        .onChange(of: pointerOverSets) { updateOrder() }
        .sheet(isPresented: $addingSet) {
            AddSetFlow(model: model) { id in selection.select(.set(id)) }
        }
        .sheet(isPresented: $addingDestination) {
            AddDestinationFlow(model: model) { id in selection.select(.destination(id)) }
        }
        .sheet(item: reviewBinding) { item in
            DeletionReviewSheet(model: model, setID: item.id)
        }
        .sheet(item: $firstPreview) { item in
            if let set = model.set(item.id) {
                PreviewSheet(model: model, set: set) { updated in
                    var accepted = updated
                    accepted.acceptPreview()
                    model.save(set: accepted)
                    model.runNow(accepted.id)
                }
            }
        }
        .confirmationDialog(removalTitle, isPresented: $confirmingRemoval, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { removeSelection() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(removalMessage)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                if onboarding.accessWarning { AccessWarningBar { onboarding.openFullDiskAccess() } }
                if let error = model.lastError { ErrorBar(message: error) { model.dismissError() } }
            }
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: listSelection) {
            Label("Overview", systemImage: "gauge.with.dots.needle.33percent").tag(SidebarItem.overview)
            Label("Coverage", systemImage: "square.grid.3x3").tag(SidebarItem.coverage)

            Section("Backup Sets") {
                ForEach(visibleRows) { row in
                    SetSidebarRow(row: row).tag(SidebarItem.set(row.id))
                }
                if model.rows.isEmpty {
                    Text("No sets yet").foregroundStyle(.secondary)
                } else if visibleRows.isEmpty {
                    Text("No sets match").foregroundStyle(.secondary)
                }
            }
            Section("Destinations") {
                ForEach(model.destinations) { d in
                    DestinationSidebarRow(destination: d, status: model.destinationStatus(d))
                        .tag(SidebarItem.destination(d.id))
                }
                if model.destinations.isEmpty {
                    Text("No destinations yet").foregroundStyle(.secondary)
                }
            }
            Section("Recovery") {
                Label("Archive", systemImage: "archivebox").tag(SidebarItem.archive)
                Label("Activity", systemImage: "list.bullet.rectangle").tag(SidebarItem.activity)
            }
            Label("Settings", systemImage: "gearshape").tag(SidebarItem.settings)
        }
        .contextMenu(forSelectionType: SidebarItem.self) { items in
            let ids = SidebarSelection.setIDs(in: items, visible: Set(visibleRows.map(\.id)))
            if !ids.isEmpty { SetBatchActions(model: model, ids: ids) }
        }
        .onHover { pointerOverSidebar = $0 }
        .toolbar {
            ToolbarItem {
                Menu {
                    Button("Add Backup Set…") { addingSet = true }
                    Button("Add Destination…") { addingDestination = true }
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .accessibilityLabel("Add")
                .accessibilityHint("Adds a backup set or a destination")
            }
            ToolbarItem {
                Button { confirmingRemoval = true } label: { Label("Remove", systemImage: "minus") }
                    .disabled(!canRemoveSelection)
                    .accessibilityHint("Removes the selected set or destination")
            }
        }
    }

    private var listSelection: Binding<Set<SidebarItem>> {
        Binding(get: { selection.items }, set: { selection.change(to: $0, extending: NSEvent.modifierFlags.contains(.shift)) })
    }

    // MARK: Order

    /// All that the order depends on, so a refresh that changes only counts and times does nothing.
    private var orderKeys: [SetSortKey] {
        model.rows.map(\.sortKey)
    }
    private var pointerOverSets: Bool { pointerOverSidebar || pointerOverCoverage }
    private func updateOrder() { setOrder.update(orderKeys, held: pointerOverSets) }

    private var orderedRows: [SetRow] { setOrder.arranged(model.rows) }
    private var visibleRows: [SetRow] { orderedRows.filter { SetFilter.matches($0.name, filter: filter) } }
    private var content: SidebarSelection.Content { selection.content(live: Set(model.rows.map(\.id))) }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        switch content {
        case .several(let ids):
            SeveralSetsView(model: model, rows: model.rows.filter { ids.contains($0.id) }.byName,
                            hidden: ids.subtracting(visibleRows.map(\.id)).count, select: { selection.select($0) })
        case .one(.overview):
            OverviewView(model: model, select: { selection.select($0) })
        case .one(.coverage):
            CoverageView(model: model, rows: visibleRows, filter: filter, select: { selection.select($0) },
                         hovering: { pointerOverCoverage = $0 })
        case .one(.set(let id)):
            if model.set(id) != nil { SetDetailView(model: model, setID: id).id(id) }
            else { PageState { ContentUnavailableView("Set Not Found", systemImage: "questionmark.folder") } }
        case .one(.destination(let id)):
            if let d = model.destination(id) { DestinationDetailView(model: model, destination: d) }
            else { PageState { ContentUnavailableView("Destination Not Found", systemImage: "questionmark.folder") } }
        case .one(.archive):
            ArchiveView(model: archive, agent: model.services.agent)
        case .one(.activity):
            ActivityView(model: activity)
        case .one(.settings):
            SettingsView(model: settings)
        }
    }

    // MARK: Removal

    private var canRemoveSelection: Bool {
        switch content { case .several, .one(.set), .one(.destination): true; default: false }
    }
    private var removalTitle: String {
        switch content {
        case .several(let ids): SetBatch.removalTitle(count: ids.count)
        case .one(.set(let id)): "Remove \"\(model.set(id)?.name ?? "this set")\"?"
        case .one(.destination(let id)): "Remove \"\(model.destination(id)?.name ?? "this destination")\"?"
        default: "Remove?"
        }
    }
    private var removalMessage: String {
        switch content {
        case .several(let ids): SetBatch.removalMessage(names: orderedRows.filter { ids.contains($0.id) }.map(\.name))
        case .one(.set): "Mirror stops backing up this folder. Your files and the copies already in your backups are not deleted."
        default: "Sets that use this destination stop backing up to it. The copies already there are not deleted."
        }
    }
    private func removeSelection() {
        switch content {
        case .several(let ids): selection.select(.overview); model.removeSets(ids)
        case .one(.set(let id)): selection.select(.overview); model.removeSet(id)
        case .one(.destination(let id)): selection.select(.overview); model.removeDestination(id)
        default: break
        }
    }

    private var reviewBinding: Binding<ReviewTarget?> {
        Binding(get: { model.reviewingSet.map(ReviewTarget.init) },
                set: { if $0 == nil { model.keepHolding() } })
    }
}

struct ReviewTarget: Identifiable { var id: UUID }

/// Shows the Dock icon only while the main window is open.
@MainActor enum DockPresence {
    private static var open = 0
    static func windowOpened() {
        open += 1
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }
    static func windowClosed() {
        open = max(0, open - 1)
        if open == 0 { NSApp.setActivationPolicy(.accessory) }
    }
}

struct SetSidebarRow: View {
    let row: SetRow
    var body: some View {
        let p = StatusPresentation(row.status)
        Label {
            HStack {
                Text(row.name).lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: p.symbol).foregroundStyle(.secondary).imageScale(.small)
            }
        } icon: { Image(systemName: "folder") }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.name), \(p.title)")
    }
}

struct DestinationSidebarRow: View {
    let destination: Destination
    let status: DestinationStatus
    var body: some View {
        Label {
            HStack {
                Text(destination.name).lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: status.symbol).foregroundStyle(.secondary).imageScale(.small)
            }
        } icon: { Image(systemName: destination.kind.symbol) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(destination.name), \(status.text)")
    }
}

struct RecoveryPlaceholder: View {
    let title: String, symbol: String, text: String
    var body: some View {
        ContentUnavailableView(title, systemImage: symbol, description: Text(text))
            .navigationTitle(title)
    }
}

struct ErrorBar: View {
    let message: String
    let dismiss: () -> Void
    var body: some View {
        HStack {
            Label(message, systemImage: "exclamationmark.triangle").lineLimit(3)
            Spacer()
            Button("Dismiss", action: dismiss)
        }
        .padding(.horizontal, PageLayout.inset).padding(.vertical, PageLayout.bannerGap)
        .background(.bar)
        .accessibilityElement(children: .contain)
    }
}

/// The background helper's last check failed. Not a dead end: runs still say what they could and couldn't read.
struct AccessWarningBar: View {
    let open: () -> Void
    var body: some View {
        HStack {
            Label("The background helper can't confirm Full Disk Access, so backups may not read every folder.",
                  systemImage: "exclamationmark.triangle").lineLimit(3)
            Spacer()
            Button("Open Settings", action: open)
                .accessibilityHint("Opens Full Disk Access in System Settings")
        }
        .padding(.horizontal, PageLayout.inset).padding(.vertical, PageLayout.bannerGap)
        .background(.bar)
        .accessibilityElement(children: .contain)
    }
}

// MARK: Shared presentation

extension DestinationKind {
    var symbol: String {
        switch self {
        case .iCloudFolder: "icloud"
        case .googleDrive, .oneDrive: "cloud"
        case .externalDrive: "externaldrive"
        }
    }
    var title: String {
        switch self {
        case .iCloudFolder: "iCloud Drive"
        case .googleDrive: "Google Drive"
        case .oneDrive: "OneDrive"
        case .externalDrive: "External Drive"
        }
    }
}

/// A destination's state in words and a symbol, never colour alone.
struct DestinationStatus: Equatable {
    var symbol: String
    var text: String
}

extension DestinationStatus {
    init(_ health: DestinationHealth) {
        func files(_ n: Int) -> String { "\(n.formatted()) \(n == 1 ? "file" : "files")" }
        switch health {
        case .unused: self.init(symbol: "circle.dashed", text: "Not used by any set")
        case .paused: self.init(symbol: "pause.circle", text: "Paused")
        case .notBackedUp: self.init(symbol: "circle.dashed", text: "Not backed up yet")
        case .previewNeeded: self.init(symbol: "eye", text: "Preview needed")
        case .failing: self.init(symbol: "exclamationmark.icloud", text: "Needs attention")
        case .unfinished: self.init(symbol: "circle.dashed", text: "Backup not finished")
        case .stopped(let problem): self.init(symbol: "exclamationmark.icloud", text: problem.headline)
        case .mismatched(let n): self.init(symbol: "exclamationmark.icloud", text: "\(files(n)) didn't match")
        case .held(let n): self.init(symbol: "pause.circle", text: "\(n.formatted()) \(n == 1 ? "deletion" : "deletions") held")
        case .uploading(let n): self.init(symbol: "arrow.clockwise.icloud", text: "Uploading \(files(n))")
        case .notAccepted(let n): self.init(symbol: "icloud.slash", text: StatusSummary.notAcceptedText(count: n))
        case .backedUp(let last):
            self.init(symbol: "checkmark.circle", text: "Backed up \(last.formatted(.relative(presentation: .named)))")
        }
    }
}

extension AppModel {
    func destinationStatus(_ d: Destination, now: Date = Date()) -> DestinationStatus {
        let pairs = sets.flatMap { s in s.destinationIDs.contains(d.id) ? [PairID(set: s.id, destination: d.id)] : [] }
        let finished = pairs.compactMap { states[$0]?.lastFinished }.max()
        if d.kind == .externalDrive {
            guard let volume = ExternalVolume.find(d, in: volumeCache.volumes) else {
                return DestinationStatus(symbol: "externaldrive.badge.xmark",
                                         text: DestinationRules.notConnectedText(lastBackedUp: finished, now: now))
            }
            if ExternalDriveSetup.needsConfirmation(d, volume: volume) {
                return DestinationStatus(symbol: "exclamationmark.triangle", text: "Confirm this internal disk")
            }
        }
        if d.encrypted && !d.recoveryKitConfirmed {
            return DestinationStatus(symbol: "exclamationmark.triangle", text: "Save your Recovery Kit")
        }
        return DestinationStatus(StatusSummary.destinationHealth(d.id, sets: sets, states: states))
    }
}
