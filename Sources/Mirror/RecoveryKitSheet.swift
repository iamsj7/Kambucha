import SwiftUI
import AppKit
import MirrorCore

/// Shows the Recovery Kit for an encrypted destination. Backups to it don't start until the owner
/// confirms they saved or printed it. The kit is fetched from the agent (which asks for Touch ID)
/// and held in memory only while this sheet is open.
struct RecoveryKitSheet: View {
    let model: AppModel
    let destination: Destination
    var confirmed: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var reveal: KitRevealModel
    @State private var savedOrPrinted = false
    @State private var understood = false
    @State private var saveError: String?

    init(model: AppModel, destination: Destination, confirmed: @escaping () -> Void) {
        self.model = model; self.destination = destination; self.confirmed = confirmed
        let agent = model.services.agent
        _reveal = State(initialValue: KitRevealModel(destination: destination) { try await agent.recoveryKitText(for: $0) })
    }

    /// For rendering screenshots with a model already in a state.
    init(model: AppModel, destination: Destination, reveal: KitRevealModel) {
        self.model = model; self.destination = destination; self.confirmed = {}
        _reveal = State(initialValue: reveal)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Save Your Recovery Kit", systemImage: "key").font(.title2.weight(.semibold))
            Text("Your backup in \(destination.name) is encrypted. If this Mac is lost, only this kit can open it. Save it somewhere safe that is not inside a folder Mirror backs up, or print it.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            if case .failed(let text) = reveal.phase {
                ContentUnavailableView {
                    Label("Recovery Kit Unavailable", systemImage: "exclamationmark.triangle")
                } description: { Text(text) } actions: {
                    Button("Try Again") { Task { await reveal.begin() } }
                }
            } else if reveal.phase == .cancelled {
                ContentUnavailableView {
                    Label("Recovery Kit Not Shown", systemImage: "touchid")
                } description: { Text("Touch ID was cancelled, so the kit stays hidden.") } actions: {
                    Button("Show Recovery Kit…") { Task { await reveal.begin() } }
                }
            } else if let kitText = reveal.kitText {
                ScrollView {
                    Text(kitText).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                .frame(minHeight: 160)
                .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("Recovery Kit text")
                HStack {
                    Button("Save…") { save(kitText) }
                    Button("Print…") { printKit(kitText) }
                    Spacer()
                }
                Text("If you print to PDF, don't save the PDF inside a folder Mirror backs up.")
                    .font(.caption).foregroundStyle(.secondary)
                if let saveError { Label(saveError, systemImage: "xmark.octagon") }
                Toggle("I saved or printed my Recovery Kit and I know where it is", isOn: $understood)
                    .disabled(!savedOrPrinted)
                    .accessibilityHint(savedOrPrinted ? "" : "Save or print the kit first")
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "touchid").font(.largeTitle).foregroundStyle(.secondary).accessibilityHidden(true)
                    ProgressView().controlSize(.small)
                    Text("Use Touch ID or your password to show the Recovery Kit.").font(.headline)
                    Text("Mirror asks first, so nobody else at this Mac can read it.").foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 160)
                .accessibilityElement(children: .combine)
            }

            HStack {
                Spacer()
                Button("Later", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityHint("Backups to this destination wait until you confirm")
                Button("Done") { confirmed(); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!(savedOrPrinted && understood))
            }
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 420)
        .task { await reveal.begin() }
        .onDisappear { reveal.clear() }
    }

    private func save(_ text: String) {
        saveError = nil
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Mirror Recovery Kit - \(PathGuard.sanitizedComponent(destination.name)).txt"
        panel.message = "Save the Recovery Kit outside the folders Mirror backs up."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard RecoveryKit.canSave(to: url, sets: model.sets) else {
            saveError = "That location is inside a folder Mirror backs up, so the kit would end up in the backup it unlocks. Choose another place."
            return
        }
        do {
            try Data(text.utf8).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            savedOrPrinted = true
        } catch { saveError = "Mirror could not save the file." }
    }

    private func printKit(_ text: String) {
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 468, height: 648))
        view.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        view.string = text
        let op = NSPrintOperation(view: view)
        if op.run() { savedOrPrinted = true }
    }
}

/// Paste a Recovery Kit to restore a destination's keys or sign-in on this Mac.
struct RecoveryKitPasteSheet: View {
    let model: AppModel
    let destination: Destination
    var restored: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var flow: KitRestoreModel

    init(model: AppModel, destination: Destination, restored: @escaping () -> Void) {
        self.model = model; self.destination = destination; self.restored = restored
        let agent = model.services.agent
        _flow = State(initialValue: KitRestoreModel(destination: destination) {
            try await agent.restore($0, kitText: $1, acceptUnproven: $2)
        })
    }

    /// For rendering screenshots with a model already in a state.
    init(model: AppModel, destination: Destination, flow: KitRestoreModel) {
        self.model = model; self.destination = destination; self.restored = {}
        _flow = State(initialValue: flow)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Restore From Recovery Kit", systemImage: "key").font(.title2.weight(.semibold))
            Text("Paste the whole Recovery Kit for \(destination.name). Mirror uses it to restore this Mac's access, and doesn't keep the text.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $flow.text)
                .font(.system(.caption, design: .monospaced))
                .frame(minHeight: 180)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
                .disabled(flow.phase == .working || flow.phase == .askingUnproven)
                .accessibilityLabel("Recovery Kit text")
            if flow.phase == .askingUnproven {
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("This Recovery Kit can't be checked yet", systemImage: "questionmark.circle").font(.headline)
                        Text("\(SetupFailureText.message(for: RemoteSetupError.kitUnproven)) Use it anyway? Mirror asks for Touch ID or your password first.")
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Spacer()
                            Button("Don't Use It") { flow.declineUnproven() }
                            Button("Use Anyway") { Task { await finish { await flow.acceptUnproven() } } }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if case .failed(let text) = flow.phase { Label(text, systemImage: "xmark.octagon") }
            HStack {
                if flow.phase == .working { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { flow.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                Button("Restore") { Task { await finish { await flow.submit() } } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!flow.canSubmit)
            }
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 380)
        .onDisappear { flow.cancel() }
    }

    private func finish(_ step: () async -> Void) async {
        await step()
        guard flow.phase == .done else { return }
        // The owner holds the kit, so the destination counts as confirmed.
        var d = destination; d.recoveryKitConfirmed = true
        model.save(destination: d)
        restored()
        dismiss()
    }
}
