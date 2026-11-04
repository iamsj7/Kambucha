import SwiftUI
import AppKit
import MirrorCore

struct DestinationDetailView: View {
    @Bindable var model: AppModel
    let destination: Destination
    @State private var working = false
    @State private var message: String?
    @State private var showingKit = false
    @State private var pasting = false
    @State private var confirmingInternal = false

    private var status: DestinationStatus { model.destinationStatus(destination) }
    private var usedBy: [BackupSet] { model.sets.filter { $0.destinationIDs.contains(destination.id) } }
    private var signsIn: Bool { destination.kind == .googleDrive || destination.kind == .oneDrive }
    private var connected: VolumeInfo? { ExternalVolume.find(destination, in: model.volumeCache.volumes) }

    var body: some View {
        Form {
            Section {
                LabeledContent("Kind") { Label(destination.kind.title, systemImage: destination.kind.symbol) }
                LabeledContent("Status") { Label(status.text, systemImage: status.symbol) }
                LabeledContent("Encryption") {
                    Text(destination.encrypted ? "On" : "Off")
                }
                if destination.encrypted {
                    LabeledContent("Recovery Kit") {
                        Text(destination.recoveryKitConfirmed ? "Saved" : "Not saved yet")
                    }
                }
            } footer: {
                Text("Encryption is chosen when a destination is created and can't be changed. To change it, add a new destination.")
            }

            if ExternalDriveSetup.needsConfirmation(destination, volume: connected) {
                Section {
                    Label(ExternalDriveSetup.internalConfirmationTitle, systemImage: "internaldrive")
                    Text(ExternalDriveSetup.internalConfirmationMessage).foregroundStyle(.secondary)
                    Button("Use This Disk…") { confirmingInternal = true }
                } header: { Text("Confirm This Disk") } footer: {
                    Text("Backups to this drive wait until you confirm.")
                }
            }

            if destination.kind == .externalDrive, let volume = connected {
                Section("Drive") {
                    Button("Eject \"\(volume.name)\"") { Task { await model.eject.eject(volume) } }
                        .disabled(model.eject.isEjecting || model.isBackupActive)
                        .accessibilityHint("Safely unmounts the drive")
                    if model.isBackupActive {
                        Text("A backup is running. You can eject when it finishes.").font(.caption).foregroundStyle(.secondary)
                    }
                    if case .failed(let text) = model.eject.phase {
                        HStack {
                            Label(text, systemImage: "exclamationmark.triangle")
                            Spacer()
                            Button("Dismiss") { model.eject.dismiss() }.buttonStyle(.borderless)
                        }
                    }
                }
            }

            if signsIn || destination.encrypted {
                Section("Access") {
                    if signsIn {
                        Button("Reconnect…") { Task { await reconnect() } }
                            .disabled(working)
                            .accessibilityHint("Signs in again in your browser")
                    }
                    if destination.encrypted {
                        Button("Show Recovery Kit…") { showingKit = true }
                        Button("Restore From Recovery Kit…") { pasting = true }
                    }
                    if working { ProgressView("Waiting for sign-in…") }
                    if let message { Label(message, systemImage: "exclamationmark.triangle") }
                }
            }

            Section("Used By") {
                ForEach(usedBy) { Label($0.name, systemImage: "folder") }
                if usedBy.isEmpty { Text("No set uses this destination.").foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(destination.name)
        .sheet(isPresented: $showingKit) {
            RecoveryKitSheet(model: model, destination: destination) {
                var d = destination; d.recoveryKitConfirmed = true; model.save(destination: d)
            }
        }
        .sheet(isPresented: $pasting) {
            RecoveryKitPasteSheet(model: model, destination: destination) { message = nil }
        }
        .confirmationDialog(ExternalDriveSetup.internalConfirmationTitle, isPresented: $confirmingInternal, titleVisibility: .visible) {
            Button("Use This Disk") { model.save(destination: ExternalDriveSetup.confirmed(destination)) }
            Button("Cancel", role: .cancel) {}
        } message: { Text(ExternalDriveSetup.internalConfirmationMessage) }
    }

    private func reconnect() async {
        working = true; message = nil
        defer { working = false }
        do { try await model.services.agent.reconnect(destination) }
        catch {
            message = SetupFailureText.message(for: error)
            if SetupFailureText.needsRecoveryKit(error) { pasting = true }
        }
    }
}
