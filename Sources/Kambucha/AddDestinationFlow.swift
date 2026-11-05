import SwiftUI
import KambuchaCore

/// Choose a kind, sign in, set encryption, then save the Recovery Kit for encrypted destinations.
struct AddDestinationFlow: View {
    let model: AppModel
    var added: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss

    enum Choice: Hashable { case iCloud, googleDrive, oneDrive, externalDrive }

    @State private var choice: Choice = .googleDrive
    @State private var name = ""
    @State private var clientID = ""
    @State private var clientSecret = ""
    @State private var encrypted = true
    @State private var confirmedOff = false
    @State private var volumes: [ExternalDriveSetup.Choice] = []
    @State private var confirmingInternal = false
    @State private var loadingVolumes = false
    @State private var volumeID: String?
    @State private var working = false
    @State private var error: String?
    @State private var task: Task<Void, Never>?
    @State private var pending: Destination?
    @State private var showingKit = false
    @State private var pasting = false

    private var kind: DestinationKind? {
        switch choice { case .iCloud: .iCloudFolder; case .googleDrive: .googleDrive; case .oneDrive: .oneDrive; case .externalDrive: .externalDrive }
    }
    private var selectedVolume: VolumeInfo? { volumes.first { $0.id == volumeID }?.volume }

    private var canContinue: Bool {
        if working { return false }
        switch choice {
        case .iCloud: return true
        case .externalDrive: return selectedVolume != nil
        case .googleDrive: return !clientID.trimmingCharacters(in: .whitespaces).isEmpty && !clientSecret.isEmpty && encryptionSettled
        case .oneDrive: return encryptionSettled
        }
    }
    /// Turning encryption off needs an explicit acknowledgement of the warning.
    private var encryptionSettled: Bool { encrypted || confirmedOff }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Kind") {
                    Picker("Kind", selection: $choice) {
                        Label("iCloud Drive", systemImage: "icloud").tag(Choice.iCloud)
                        Label("Google Drive", systemImage: "cloud").tag(Choice.googleDrive)
                        Label("OneDrive", systemImage: "cloud").tag(Choice.oneDrive)
                        Label("External Drive", systemImage: "externaldrive").tag(Choice.externalDrive)
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                    .accessibilityLabel("Destination kind")
                }

                if choice == .googleDrive {
                    Section {
                        TextField("Client ID", text: $clientID, prompt: Text("Ends in .apps.googleusercontent.com"))
                        SecureField("Client secret", text: $clientSecret, prompt: Text("Required"))
                    } header: { Text("Google Client") } footer: {
                        Text("Create your own client ID in Google Cloud Console. Kambucha opens your browser to sign in, and keeps the secret in the Keychain.")
                    }
                }

                if let k = kind, DestinationRules.encryptionOffered(k) {
                    Section {
                        Toggle("Encrypt backups", isOn: $encrypted)
                        if !encrypted {
                            Label(DestinationRules.encryptionOffWarning, systemImage: "exclamationmark.triangle")
                            Toggle("I understand the provider can read my files", isOn: $confirmedOff)
                        }
                    } header: { Text("Encryption") } footer: {
                        Text("On by default. It can't be changed after the destination is created.")
                    }
                }

                if choice == .iCloud {
                    Section { Text("Backups go to a Mac Backup folder in iCloud Drive. No sign-in is needed, and iCloud's own protection applies.").foregroundStyle(.secondary) }
                }

                if choice == .externalDrive { externalSection }

                if choice != .externalDrive || selectedVolume != nil {
                    Section("Name") { TextField("Name", text: $name, prompt: Text(defaultName)) }
                }

                if working { Section { ProgressView(choice == .iCloud ? "Saving…" : "Waiting for sign-in in your browser…") } }
                if let error { Section { Label(error, systemImage: "xmark.octagon") } }
            }
            .formStyle(.grouped)

            HStack {
                if let kind, DestinationRules.encryptionOffered(kind), encrypted {
                    Button("I Have a Recovery Kit…") { useRecoveryKit(kind) }
                        .disabled(working)
                        .accessibilityHint("Opens a backup you already have, instead of making new keys")
                }
                Spacer()
                Button("Cancel", role: .cancel) { task?.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                Button(choice == .iCloud || choice == .externalDrive ? "Add" : "Sign In…") { start() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canContinue)
            }
            .padding(16)
        }
        .frame(minWidth: 520, minHeight: 600)
        .onDisappear { clientSecret = "" }
        .onAppear { if choice == .externalDrive { refreshVolumes() } }
        .confirmationDialog(ExternalDriveSetup.internalConfirmationTitle, isPresented: $confirmingInternal, titleVisibility: .visible) {
            Button("Use This Disk") { save(internalConfirmed: true) }
            Button("Cancel", role: .cancel) {}
        } message: { Text(ExternalDriveSetup.internalConfirmationMessage) }
        .onChange(of: choice) { _, new in
            error = nil
            if let k = kind { encrypted = DestinationRules.encryptionDefault(k); confirmedOff = false }
            if new == .externalDrive { refreshVolumes() }
        }
        // Done and Later both end the flow: the destination is saved and shows "Save your Recovery Kit"
        // until confirmed, so there is nothing left here that Sign In could collide with.
        .sheet(isPresented: $showingKit, onDismiss: { if let d = pending { added(d.id); dismiss() } }) {
            if let d = pending {
                RecoveryKitSheet(model: model, destination: d) {
                    var done = d; done.recoveryKitConfirmed = true
                    model.save(destination: done)
                }
            }
        }
        .sheet(isPresented: $pasting) {
            if let d = pending {
                RecoveryKitPasteSheet(model: model, destination: d) { added(d.id); dismiss() }
            }
        }
    }

    private var defaultName: String {
        switch choice {
        case .iCloud: "iCloud Drive"
        case .googleDrive: "Google Drive"
        case .oneDrive: "OneDrive"
        case .externalDrive: selectedVolume?.name ?? "External Drive"
        }
    }

    private func refreshVolumes() {
        loadingVolumes = true
        let locator = model.services.volumes, existing = model.destinations
        Task {
            let rows = await ExternalDriveSetup.loadChoices(from: locator, existing: existing)
            volumes = rows
            loadingVolumes = false
            if let id = volumeID, !rows.contains(where: { $0.id == id && $0.selectable }) { volumeID = nil }
        }
    }

    @ViewBuilder private var externalSection: some View {
        Section {
            if loadingVolumes && volumes.isEmpty {
                ProgressView("Looking for drives…")
            } else if volumes.isEmpty {
                Text("No external drives are connected.").foregroundStyle(.secondary)
            }
            ForEach(volumes) { v in
                Button { volumeID = v.id } label: {
                    HStack(alignment: .firstTextBaseline) {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(v.formatName.isEmpty ? v.name : "\(v.name), \(v.formatName)")
                                if let reason = v.unavailableReason { Text(reason).font(.callout).foregroundStyle(.secondary) }
                            }
                        } icon: {
                            Image(systemName: volumeID == v.id ? "checkmark.circle.fill" : "externaldrive")
                        }
                        Spacer()
                        if let free = v.freeBytes { Text("\(free.formatted(.byteCount(style: .file))) free").foregroundStyle(.secondary) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!v.selectable)
                .accessibilityAddTraits(volumeID == v.id ? [.isButton, .isSelected] : .isButton)
            }
            if let v = selectedVolume {
                if let warn = DestinationRules.filesystemWarning(v.fileSystem) {
                    Label(warn, systemImage: "exclamationmark.triangle")
                }
                if ExternalDriveSetup.needsInternalConfirmation(v) {
                    Label(ExternalDriveSetup.internalConfirmationTitle, systemImage: "internaldrive")
                }
            }
        } header: { Text("Connected Drives") } footer: {
            Text("Kambucha doesn't encrypt external drives. Use a drive with its own password protection. A locked drive counts as not connected.")
        }
    }

    // MARK: Actions

    /// A new Mac with a backup already out there. Signing in here would make new keys, so nothing is saved until
    /// the Kit has opened the backup.
    private func useRecoveryKit(_ kind: DestinationKind) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let finalName = trimmed.isEmpty ? defaultName : trimmed
        guard !model.destinations.contains(where: { $0.name.caseInsensitiveCompare(finalName) == .orderedSame }) else {
            error = "A destination called \"\(finalName)\" already exists."
            return
        }
        error = nil
        pending = Destination(name: finalName, kind: kind, encrypted: true)
        pasting = true
    }

    private func start() {
        error = nil
        let finalName = name.trimmingCharacters(in: .whitespaces).isEmpty ? defaultName : name.trimmingCharacters(in: .whitespaces)
        guard let kind else { return }
        if model.destinations.contains(where: { $0.name.caseInsensitiveCompare(finalName) == .orderedSame }) {
            error = "A destination called \"\(finalName)\" already exists."
            return
        }
        if kind == .externalDrive {
            if let v = selectedVolume, ExternalDriveSetup.needsInternalConfirmation(v) { confirmingInternal = true }
            else { save(internalConfirmed: false) }
            return
        }
        let d = Destination(name: finalName, kind: kind, encrypted: DestinationRules.encryptionOffered(kind) ? encrypted : false)
        if kind == .iCloudFolder { model.save(destination: d); added(d.id); dismiss(); return }

        // The agent reads destinations from the app's saved list, so it is saved before signing in.
        model.save(destination: d)
        pending = d
        working = true
        let id = clientID.trimmingCharacters(in: .whitespaces), secret = clientSecret
        task = Task {
            do {
                try await model.services.agent.connect(d, clientID: kind == .googleDrive ? id : nil,
                                                       clientSecret: kind == .googleDrive ? secret : nil)
                clientSecret = ""
                working = false
                if d.encrypted { showingKit = true } else { added(d.id); dismiss() }
            } catch {
                working = false
                self.error = SetupFailureText.message(for: error)
                if SetupFailureText.needsRecoveryKit(error) { pasting = true }
                else { model.removeDestination(d.id); pending = nil }
            }
        }
    }

    private func save(internalConfirmed: Bool) {
        guard let v = selectedVolume else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let finalName = trimmed.isEmpty ? defaultName : trimmed
        if model.destinations.contains(where: { $0.name.caseInsensitiveCompare(finalName) == .orderedSame }) {
            error = "A destination called \"\(finalName)\" already exists."
            return
        }
        if let existing = DestinationRules.duplicateDrive(of: v.uuid, in: model.destinations, excluding: nil) {
            error = DestinationRules.duplicateDriveMessage(existing)
            return
        }
        let d = ExternalDriveSetup.destination(name: finalName, volume: v, internalConfirmed: internalConfirmed)
        model.save(destination: d); added(d.id); dismiss()
    }
}
