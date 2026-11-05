import SwiftUI
import AppKit
import KambuchaCore

/// Choose a folder, check it is safe, auto-detect stacks, then preview before anything is backed up.
struct AddSetFlow: View {
    let model: AppModel
    var added: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var folder: URL?
    @State private var name = ""
    @State private var presets: Set<String> = []
    @State private var catalog: [Preset] = []
    @State private var chosenDestinations: Set<UUID> = []
    @State private var previewing = false
    @State private var checkingName = false
    @State private var nameConflicts: [Destination] = []
    /// What the owner agreed to take over, for this name only.
    @State private var adopting: (name: String, destinations: Set<UUID>)?
    /// Used if nothing was chosen and no iCloud destination is saved yet, so a check and the set agree on it.
    @State private var newICloud = Destination(name: "iCloud Drive", kind: .iCloudFolder)

    private let guardrail = PathGuard(iCloudDrive: KambuchaPaths.iCloudDrive, backupRoot: KambuchaPaths.backupRoot)

    private var candidate: BackupSet? {
        guard let folder else { return nil }
        var s = BackupSet(name: name.trimmingCharacters(in: .whitespacesAndNewlines), source: folder, presets: presets,
                          destinationIDs: model.destinations.filter { chosenDestinations.contains($0.id) }.map(\.id))
        s.archiveDays = (try? SettingsStore(root: model.support).load().defaultRetentionDays) ?? AppSettings().defaultRetentionDays
        return s
    }

    private var problem: String? {
        guard let c = candidate else { return nil }
        do { try guardrail.validateNewSet(c, existing: model.sets); return nil }
        catch { return SetupFailureText.message(for: error) }
    }

    private var differentVolume: Bool {
        guard let folder else { return false }
        return !guardrail.sameVolumeAsICloud(folder)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    LabeledContent("Folder") {
                        HStack {
                            Text(folder?.path ?? "None chosen").foregroundStyle(folder == nil ? .secondary : .primary)
                                .lineLimit(1).truncationMode(.middle)
                            Button("Choose…") { chooseFolder() }
                        }
                    }
                    if folder != nil {
                        TextField("Name", text: $name)
                        if let better = SetNaming.suggestion(for: name) {
                            Button("Use \"\(better)\" instead") { name = better }
                                .accessibilityHint("This name can't be used as a folder name")
                        }
                    }
                } header: {
                    Text("Folder to Back Up")
                } footer: {
                    Text("Pick a parent folder such as Projects. Everything inside is backed up, except what your rules skip. The name can't be changed later, because it names the folder in every destination.")
                }

                if let problem {
                    Section { Label(problem, systemImage: "xmark.octagon").foregroundStyle(.primary) }
                }
                if folder != nil, problem == nil, differentVolume {
                    Section {
                        Label("This folder is on a different drive from iCloud Drive. Backups work, but they take more disk space and time, because files can't be cloned.",
                              systemImage: "exclamationmark.triangle")
                    }
                }

                if folder != nil, !catalog.isEmpty {
                    Section {
                        ForEach(catalog) { p in
                            Toggle(p.name, isOn: Binding(get: { presets.contains(p.id) },
                                                         set: { if $0 { presets.insert(p.id) } else { presets.remove(p.id) } }))
                        }
                    } header: { Text("Stacks Found") } footer: {
                        Text(presets.isEmpty ? "No projects were recognised. You can turn stacks on here." : "Kambucha turned on the stacks it found. You can change them.")
                    }
                }

                if !model.destinations.isEmpty {
                    Section("Back Up To") {
                        ForEach(model.destinations) { d in
                            Toggle(isOn: Binding(get: { chosenDestinations.contains(d.id) },
                                                 set: { if $0 { chosenDestinations.insert(d.id) } else { chosenDestinations.remove(d.id) } })) {
                                Label(d.name, systemImage: d.kind.symbol)
                            }
                        }
                    }
                } else {
                    Section { Text("Your backups go to iCloud Drive. Add Google Drive, OneDrive or an external drive afterwards.").foregroundStyle(.secondary) }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                if checkingName { ProgressView().controlSize(.small).accessibilityLabel("Checking the name") }
                Button("Preview…") { Task { await preview() } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(checkingName || candidate == nil || problem != nil || SetNaming.suggestion(for: name) != nil || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(16)
        }
        .frame(minWidth: 520, minHeight: 420)
        .task {
            catalog = (try? PresetCatalog.all()) ?? []
            chosenDestinations = Set(model.destinations.prefix(1).map(\.id))
        }
        .confirmationDialog(SetNameConflict.title(name: trimmedName, in: nameConflicts),
                            isPresented: Binding(get: { !nameConflicts.isEmpty }, set: { if !$0 { nameConflicts = [] } }),
                            titleVisibility: .visible) {
            Button(SetNameConflict.adoptButton, role: .destructive) {
                adopting = (trimmedName, Set(nameConflicts.map(\.id)))
                nameConflicts = []
                previewing = true
            }
            Button("Choose a Different Name", role: .cancel) { nameConflicts = [] }
        } message: { Text(SetNameConflict.message(name: trimmedName)) }
        .sheet(isPresented: $previewing) {
            if let c = candidate {
                PreviewSheet(model: model, set: c, startLabel: "Start Backup") { accepted in create(accepted) }
            }
        }
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Where this set will back up: what's ticked, or iCloud Drive when nothing is.
    private var targets: [Destination] {
        let chosen = model.destinations.filter { chosenDestinations.contains($0.id) }
        return chosen.isEmpty ? [model.destinations.first { $0.kind == .iCloudFolder } ?? newICloud] : chosen
    }

    /// Asks before the preview, so the owner hears about a name in use here and not from a stopped run.
    private func preview() async {
        checkingName = true
        defer { checkingName = false }
        if adopting?.name != trimmedName { adopting = nil }
        let found = await SetNameConflict.destinations(holding: trimmedName, among: targets, stored: model.destinations,
                                                       names: model.services.names)
        if found.isEmpty || adopting.map({ Set(found.map(\.id)).isSubset(of: $0.destinations) }) == true {
            previewing = true
        } else {
            nameConflicts = found
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose a folder to back up"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        folder = url
        let made = NewSet.make(folder: url, presets: catalog, destinations: [])
        name = made.name
        presets = made.presets
    }

    private func create(_ set: BackupSet) {
        var final = set
        if final.destinationIDs.isEmpty {
            // iCloud Drive needs no sign-in, so it is the destination when none was chosen.
            let existing = model.destinations.first { $0.kind == .iCloudFolder }
            let icloud = existing ?? newICloud
            if existing == nil { model.save(destination: icloud) }
            final.destinationIDs = [icloud.id]
        }
        if let adopting, adopting.name == final.name { final.adoptsBackupIn = adopting.destinations }
        final.acceptPreview()
        model.save(set: final)
        model.runNow(final.id)
        added(final.id)
        dismiss()
    }
}
