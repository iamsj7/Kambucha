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

    @State private var kitText: String?
    @State private var loadError: String?
    @State private var savedOrPrinted = false
    @State private var understood = false
    @State private var saveError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Save Your Recovery Kit", systemImage: "key").font(.title2.weight(.semibold))
            Text("Your backup in \(destination.name) is encrypted. If this Mac is lost, only this kit can open it. Save it somewhere safe that is not inside a folder Mirror backs up, or print it.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            if let loadError {
                ContentUnavailableView("Recovery Kit Unavailable", systemImage: "exclamationmark.triangle", description: Text(loadError))
            } else if let kitText {
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
                ProgressView("Getting your Recovery Kit…").frame(maxWidth: .infinity, minHeight: 160)
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
        .task { await load() }
        .onDisappear { kitText = nil }
    }

    private func load() async {
        do { kitText = try await model.services.agent.recoveryKitText(for: destination) }
        catch { loadError = SetupFailureText.message(for: error) }
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

    @State private var text = ""
    @State private var working = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Restore From Recovery Kit", systemImage: "key").font(.title2.weight(.semibold))
            Text("Paste the whole Recovery Kit for \(destination.name). Mirror uses it to restore this Mac's access, and doesn't keep the text.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $text)
                .font(.system(.caption, design: .monospaced))
                .frame(minHeight: 180)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
                .accessibilityLabel("Recovery Kit text")
            if let error { Label(error, systemImage: "xmark.octagon") }
            HStack {
                if working { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { text = ""; dismiss() }.keyboardShortcut(.cancelAction)
                Button("Restore") { Task { await restore() } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(working || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 380)
        .onDisappear { text = "" }
    }

    private func restore() async {
        working = true; error = nil
        defer { working = false }
        do {
            try await model.services.agent.restore(destination, kitText: text)
            // The owner holds the kit, so the destination counts as confirmed.
            var d = destination; d.recoveryKitConfirmed = true
            model.save(destination: d)
            text = ""
            restored()
            dismiss()
        } catch { self.error = SetupFailureText.message(for: error) }
    }
}
