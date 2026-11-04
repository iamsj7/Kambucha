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

    private var status: DestinationStatus { model.destinationStatus(destination) }
    private var usedBy: [BackupSet] { model.sets.filter { $0.destinationIDs.contains(destination.id) } }
    private var signsIn: Bool { destination.kind == .googleDrive || destination.kind == .oneDrive }
    private var connected: VolumeInfo? { ExternalVolume.find(destination, in: model.services.volumes.mounted()) }
    private var hasRun: Bool {
        model.sets.contains { $0.destinationIDs.contains(destination.id) &&
            model.states[PairID(set: $0.id, destination: destination.id)]?.lastFinished != nil }
    }

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

            if destination.kind == .externalDrive, let volume = connected, hasRun {
                Section("Drive") {
                    Button("Eject \"\(volume.name)\"") { eject(volume) }
                        .accessibilityHint("Safely unmounts the drive")
                    if let message { Label(message, systemImage: "exclamationmark.triangle") }
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
    }

    private func eject(_ volume: VolumeInfo) {
        message = nil
        do { try NSWorkspace.shared.unmountAndEjectDevice(at: volume.mountPoint) }
        catch { message = "Couldn't eject \"\(volume.name)\". Something may still be using it." }
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
