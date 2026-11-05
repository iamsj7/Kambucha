import SwiftUI
import AppKit
import MirrorCore

/// The pane last chosen, kept across sets (MainWindow recreates the view per set) for the session.
@MainActor enum SetPaneMemory {
    static var last = SetPane.status
    /// A set opened to deal with a problem shows why, not the pane last used.
    static func openOnStatus() { last = .status }
}

struct SetDetailView: View {
    @Bindable var model: AppModel
    let setID: UUID
    @State private var draft: BackupSet
    @State private var presets: [Preset] = []
    @State private var showingPreview = false
    @State private var previewTask: Task<Void, Never>?
    @State private var lastSaved: BackupSet
    @State private var network = NetworkStatus()
    @State private var confirmingAdoption = false
    @State private var outsidePicks = 0
    @State private var pane: SetPane
    /// Here and not in the pane, which a pane switch destroys.
    @State private var ruleQuery = ""
    @State private var revealRule: UUID?
    @State private var width: CGFloat = 0

    init(model: AppModel, setID: UUID, pane: SetPane? = nil) {
        _pane = State(initialValue: pane ?? SetPaneMemory.last)
        self.model = model
        self.setID = setID
        let initial = model.set(setID) ?? BackupSet(name: "", source: URL(fileURLWithPath: "/"))
        _draft = State(initialValue: initial)
        _lastSaved = State(initialValue: initial)
    }

    /// Rules still being typed (empty patterns) are neither saved nor previewed.
    private static func cleaned(_ set: BackupSet) -> BackupSet {
        var c = set
        c.rules.removeAll { $0.pattern.trimmingCharacters(in: .whitespaces).isEmpty }
        return c
    }
    private var accepted: Bool { Self.cleaned(draft).isPreviewAccepted }
    /// Destinations whose run stopped because a backup there already has this set's name.
    private var nameConflicts: [Destination] {
        model.destinations.filter { draft.destinationIDs.contains($0.id) && model.states[PairID(set: setID, destination: $0.id)]?.stoppedBy == .setNameInUse }
    }

    var body: some View {
        BannerPage(kind: .reading) {
            banners
        } content: {
            switch pane {
            case .status: ReadingForm { statusPane }
            case .included:
                IncludedPane(draft: $draft, query: $ruleQuery, revealRule: $revealRule, presets: presets, presetBinding: presetBinding,
                             requestPreview: { requestPreview(after: $0) }, excludeItems: { Task { await excludeItems() } })
            case .destinations: ReadingForm { destinationsPane }
            case .safety: ReadingForm { safetyPane }
            }
        }
        .measuringWidth($width)
        .onChange(of: pane) { _, new in SetPaneMemory.last = new }
        .toolbar {
            ToolbarItem(placement: .principal) { panePicker }
            ToolbarItemGroup(placement: .primaryAction) {
                Group {
                    Button { showingPreview = true } label: { Label("Preview Backup…", systemImage: "eye") }
                        .help("Preview Backup")
                        .accessibilityLabel("Preview Backup…")
                        .accessibilityHint("Shows what a backup of this set would change")
                    Button { model.runNow(setID) } label: { Label("Back Up Now", systemImage: "arrow.clockwise.icloud") }
                        .help("Back Up Now")
                        .accessibilityLabel("Back Up Now")
                        .disabled(!accepted || draft.isPaused)
                }
                .labelStyle(PageToolbarLabelStyle(wordy: PageLayout.hasWordyToolbar(width: width)))
            }
        }
        .navigationTitle(draft.name)
        .onChange(of: draft) { _, new in
            let c = Self.cleaned(new)
            lastSaved = c
            model.save(set: c)
        }
        // A change made elsewhere (the menu bar's Pause) is merged in, so a stale draft can't undo it.
        .onChange(of: model.set(setID)) { _, latest in
            guard let latest, latest != lastSaved else { return }
            draft = SetDraftMerge.merge(draft: draft, previouslySaved: lastSaved, latest: latest)
            lastSaved = latest
        }
        .confirmationDialog(SetNameConflict.title(name: draft.name, in: nameConflicts), isPresented: $confirmingAdoption, titleVisibility: .visible) {
            Button(SetNameConflict.adoptButton, role: .destructive) {
                draft.adoptsBackupIn = (draft.adoptsBackupIn ?? []).union(nameConflicts.map(\.id))
                model.save(set: Self.cleaned(draft))
                model.runNow(setID)
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text(SetNameConflict.message(name: draft.name)) }
        .alert("Choose Items Inside \(draft.name)", isPresented: Binding(get: { outsidePicks > 0 }, set: { if !$0 { outsidePicks = 0 } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(outsidePicks == 1 ? "1 item wasn't inside this set, so it was left out." : "\(outsidePicks) items weren't inside this set, so they were left out.")
        }
        .onChange(of: draft.presets) { requestPreview() }
        .onChange(of: draft.backupSecrets) { requestPreview() }
        .onChange(of: draft.backupGit) { requestPreview() }
        .task { presets = (try? PresetCatalog.all()) ?? [] }
        .onAppear { network.start() }
        .onDisappear { network.stop() }
        .sheet(isPresented: $showingPreview, onDismiss: { if let s = model.set(setID) { draft = s } }) {
            PreviewSheet(model: model, set: Self.cleaned(draft), startLabel: "Start Backup") { updated in
                var accepted = updated
                accepted.acceptPreview()
                draft = accepted
                model.save(set: accepted)
                model.runNow(accepted.id)
            }
        }
    }

    @ViewBuilder private var panePicker: some View {
        let picker = Picker("Section", selection: $pane) {
            ForEach(SetPane.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .labelsHidden()
        .accessibilityLabel("Section")
        if PageLayout.hasRoomyToolbar(width: width) { picker.pickerStyle(.segmented).fixedSize() } else { picker.pickerStyle(.menu) }
    }

    private var shownBanners: [SetBanner] {
        SetBanners.visible(nameConflict: !nameConflicts.isEmpty, previewAccepted: accepted, on: pane)
    }

    /// Notices that need the owner show at the top of every pane, and don't scroll away with 200 rules.
    @ViewBuilder private var banners: some View {
        ForEach(shownBanners, id: \.self) { banner in
            PageBanner {
                switch banner {
                case .nameConflict:
                    VStack(alignment: .leading, spacing: 4) {
                        Label(SetNameConflict.title(name: draft.name, in: nameConflicts), systemImage: "exclamationmark.triangle")
                        Text(Self.conflictHelp).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: PageLayout.bannerGap)
                    Button("\(SetNameConflict.adoptButton)…") { confirmingAdoption = true }
                case .previewNeeded:
                    Label(Self.previewHelp, systemImage: "eye")
                    Spacer(minLength: PageLayout.bannerGap)
                    Button("Preview Backup…") { showingPreview = true }.buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private static let conflictHelp = "Nothing has been changed there. To start a fresh backup instead, remove this set and add it under another name."
    private static let previewHelp = "Preview this set before its first backup. Changing rules asks again."

    @ViewBuilder private var statusPane: some View {
        let running = model.progress.filter { $0.progress.pair.set == setID }
        let current = model.rows.first { $0.id == setID }.map { StatusPresentation($0.status) }
        let lastRun = model.states.filter { $0.key.set == setID }.compactMap(\.value.lastFinished).max()
        Section("Location") {
            LabeledContent("Name") { Text(draft.name) }
            LabeledContent("Folder") {
                Text(draft.source.path).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([draft.source]) }
            Toggle("Pause this set", isOn: $draft.isPaused)
            Text("The name can't be changed, because it names this set's folder in every destination. To rename it, remove the set and add it again.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("State") {
            if let current {
                LabeledContent("Now") { Label(current.title, systemImage: current.symbol) }
                if let detail = current.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
            LabeledContent("Last backup") {
                Text(lastRun.map { $0.formatted(.relative(presentation: .named)) } ?? "Not yet")
            }
        }
        if !running.isEmpty {
            Section("Backing Up") {
                ForEach(running) { ProgressRow(label: $0.label, progress: $0.progress) }
                NetworkUploadRow(network: network)
            }
        }
        Section {
            Button("Preview Backup…") { showingPreview = true }
            Button("Back Up Now") { model.runNow(setID) }
                .disabled(!accepted || draft.isPaused)
        }
    }

    @ViewBuilder private var destinationsPane: some View {
        Section("Destinations") {
            ForEach(model.destinations) { d in
                let status = model.destinationStatus(d)
                Toggle(isOn: destinationBinding(d.id)) {
                    VStack(alignment: .leading) {
                        Label(d.name, systemImage: d.kind.symbol)
                        Text(status.text).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if model.destinations.isEmpty {
                Text("Add a destination from the sidebar.").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var safetyPane: some View {
        Section {
            Stepper("At least \(draft.deletion.minFiles) files", value: $draft.deletion.minFiles, in: 1...100_000, step: 10)
            Stepper("More than \(draft.deletion.percent.formatted())% of the set",
                    value: $draft.deletion.percent, in: 1...100, step: 1)
            Stepper("Or more than \(draft.deletion.absoluteMax.formatted()) files",
                    value: $draft.deletion.absoluteMax, in: 10...1_000_000, step: 100)
        } header: {
            Text("Hold Deletions When a Backup Would Remove")
        } footer: {
            Text("A hold needs both the first two, or the last on its own. New and changed files keep backing up while deletions wait for you.")
        }

        Section {
            Stepper("Keep removed files \(draft.archiveDays) days", value: $draft.archiveDays, in: 1...3650, step: 5)
        } header: {
            Text("Archive")
        } footer: {
            Text("Files you delete or change are kept in the archive for this long.")
        }
    }

    /// Hidden files show, as `.env` and friends are what people often want to pick. Links stay links, so picking
    /// one excludes the link and not what it points at.
    private func excludeItems() async {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = false
        panel.showsHiddenFiles = true
        panel.treatsFilePackagesAsDirectories = true
        panel.directoryURL = draft.source
        panel.prompt = "Exclude"
        panel.message = "Choose the files and folders to leave out of this backup."
        let picked: [URL] = await withCheckedContinuation { c in
            panel.begin { c.resume(returning: $0 == .OK ? panel.urls : []) }
        }
        guard !picked.isEmpty else { return }
        let result = ExcludeRule.adding(picked, to: draft)
        outsidePicks = result.outside
        guard result.rules != draft.rules else { return }
        // The filter goes, or it could hide the rule just made.
        ruleQuery = ""
        revealRule = RuleFilter.firstAdded(to: draft.rules, in: result.rules)
        draft.rules = result.rules
        requestPreview(after: 0)
    }

    /// Several quick changes become one preview.
    private func requestPreview(after seconds: Double = 0.8) {
        previewTask?.cancel()
        previewTask = Task {
            try? await Task.sleep(for: .seconds(seconds))
            if !Task.isCancelled { showingPreview = true }
        }
    }

    private func presetBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { draft.presets.contains(id) },
                set: { if $0 { draft.presets.insert(id) } else { draft.presets.remove(id) } })
    }

    private func destinationBinding(_ id: UUID) -> Binding<Bool> {
        Binding(get: { draft.destinationIDs.contains(id) },
                set: { if $0 { draft.destinationIDs.append(id) } else { draft.destinationIDs.removeAll { $0 == id } } })
    }
}
