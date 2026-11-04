import SwiftUI
import AppKit
import MirrorCore

/// What the sidebar can select. Archive and Activity are separate cases so Task 18 can swap in
/// `ArchiveView` and `ActivityView` by editing only `MainWindow.detail`.
enum SidebarItem: Hashable {
    case overview
    case set(UUID)
    case destination(UUID)
    case archive
    case activity
}

struct MainWindow: View {
    @Bindable var model: AppModel
    @State private var selection: SidebarItem? = .overview
    @State private var addingSet = false
    @State private var addingDestination = false
    @State private var confirmingRemoval = false
    @State private var launchError: String?
    @State private var archive: ArchiveModel
    @State private var activity: ActivityModel
    @State private var onboarding: OnboardingModel

    init(model: AppModel) {
        self.model = model
        _archive = State(initialValue: ArchiveModel(provider: model.services.archive, store: ConfigStore(root: model.support)))
        _activity = State(initialValue: ActivityModel(support: model.support))
        _onboarding = State(initialValue: OnboardingModel(store: ConfigStore(root: model.support),
                                                          settings: SettingsStore(root: model.support)))
    }

    var body: some View {
        // Onboarding stays until every step is done. Nothing is shown until the first read of those
        // steps finishes, so a finished setup doesn't flash it.
        Group {
            if onboarding.hasRefreshed && !onboarding.isComplete {
                OnboardingView(model: onboarding)
            } else {
                split
            }
        }
        .task {
            while !Task.isCancelled {
                await onboarding.refresh()
                try? await Task.sleep(for: .seconds(onboarding.isComplete ? 30 : 2))
            }
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
        .sheet(isPresented: $addingSet) {
            AddSetFlow(model: model) { id in selection = .set(id) }
        }
        .sheet(isPresented: $addingDestination) {
            AddDestinationFlow(model: model) { id in selection = .destination(id) }
        }
        .sheet(item: reviewBinding) { item in
            DeletionReviewSheet(model: model, setID: item.id)
        }
        .confirmationDialog(removalTitle, isPresented: $confirmingRemoval, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { removeSelection() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(removalMessage)
        }
        .safeAreaInset(edge: .bottom) {
            if let error = model.lastError { ErrorBar(message: error) { model.dismissError() } }
        }
        // The Dock icon shows only while this window is open; the app is otherwise a menu bar item.
        .onAppear { DockPresence.windowOpened() }
        .onDisappear { DockPresence.windowClosed() }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $selection) {
            Label("Overview", systemImage: "gauge.with.dots.needle.33percent").tag(SidebarItem.overview)

            Section("Backup Sets") {
                ForEach(model.rows) { row in
                    SetSidebarRow(row: row).tag(SidebarItem.set(row.id))
                }
                if model.rows.isEmpty {
                    Text("No sets yet").foregroundStyle(.secondary)
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
        }
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

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        switch selection ?? .overview {
        case .overview:
            OverviewView(model: model, select: { selection = $0 })
        case .set(let id):
            if model.set(id) != nil { SetDetailView(model: model, setID: id).id(id) }
            else { ContentUnavailableView("Set Not Found", systemImage: "questionmark.folder") }
        case .destination(let id):
            if let d = model.destination(id) { DestinationDetailView(model: model, destination: d) }
            else { ContentUnavailableView("Destination Not Found", systemImage: "questionmark.folder") }
        case .archive:
            ArchiveView(model: archive, agent: model.services.agent)
        case .activity:
            ActivityView(model: activity)
        }
    }

    // MARK: Removal

    private var canRemoveSelection: Bool {
        switch selection { case .set, .destination: true; default: false }
    }
    private var removalTitle: String {
        switch selection {
        case .set(let id): "Remove \"\(model.set(id)?.name ?? "this set")\"?"
        case .destination(let id): "Remove \"\(model.destination(id)?.name ?? "this destination")\"?"
        default: "Remove?"
        }
    }
    private var removalMessage: String {
        switch selection {
        case .set: "Mirror stops backing up this folder. Your files and the copies already in your backups are not deleted."
        default: "Sets that use this destination stop backing up to it. The copies already there are not deleted."
        }
    }
    private func removeSelection() {
        switch selection {
        case .set(let id): selection = .overview; model.removeSet(id)
        case .destination(let id): selection = .overview; model.removeDestination(id)
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
        .padding(10)
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
        }
    }
    var title: String {
        switch self {
        case .iCloudFolder: "iCloud Drive"
        case .googleDrive: "Google Drive"
        case .oneDrive: "OneDrive"
        }
    }
}

/// A destination's state in words and a symbol, never colour alone.
struct DestinationStatus: Equatable {
    var symbol: String
    var text: String
}

extension AppModel {
    func destinationStatus(_ d: Destination, now: Date = Date()) -> DestinationStatus {
        let pairs = sets.flatMap { s in s.destinationIDs.contains(d.id) ? [PairID(set: s.id, destination: d.id)] : [] }
        let finished = pairs.compactMap { states[$0]?.lastFinished }.max()
        if d.encrypted && !d.recoveryKitConfirmed {
            return DestinationStatus(symbol: "exclamationmark.triangle", text: "Save your Recovery Kit")
        }
        if pairs.contains(where: { (states[$0]?.consecutiveFailures ?? 0) > 0 }) {
            return DestinationStatus(symbol: "exclamationmark.icloud", text: "Needs attention")
        }
        if let finished {
            return DestinationStatus(symbol: "checkmark.circle",
                                     text: "Backed up \(finished.formatted(.relative(presentation: .named)))")
        }
        return DestinationStatus(symbol: "circle.dashed", text: pairs.isEmpty ? "Not used by any set" : "Not backed up yet")
    }
}
