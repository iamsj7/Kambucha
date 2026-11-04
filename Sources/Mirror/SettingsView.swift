import SwiftUI
import ServiceManagement
import MirrorCore

@MainActor @Observable
final class SettingsModel {
    private(set) var settings: AppSettings
    private(set) var loginStatus: SMAppService.Status
    private(set) var error: String?
    @ObservationIgnored private let store: SettingsStore
    @ObservationIgnored private let login: any LoginItemControlling

    init(store: SettingsStore = SettingsStore(root: MirrorPaths.support),
         login: any LoginItemControlling = AgentRegistration.LoginItem()) {
        self.store = store; self.login = login
        loginStatus = login.status
        do { settings = try store.load() }
        catch {
            // A damaged file isn't silently replaced: show defaults and say so. Changing a setting saves a new file.
            settings = AppSettings()
            self.error = "Mirror couldn't read its saved settings, so defaults are shown. Changing a setting replaces the damaged file."
        }
    }

    var launchAtLogin: Bool { loginStatus == .enabled || loginStatus == .requiresApproval }

    func update(_ change: (inout AppSettings) -> Void) {
        var next = settings
        change(&next)
        guard next != settings else { return }
        do { try store.save(next); settings = next; error = nil }
        catch { self.error = "Mirror couldn't save this setting." }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try login.register() } else { try login.unregister() }
            error = nil
        } catch {
            self.error = "Mirror couldn't change launch at login. \(error.localizedDescription)"
        }
        loginStatus = login.status
    }

    func refreshLoginStatus() { loginStatus = login.status }
}

/// Settings are saved to `settings.json` in Application Support (see `AppSettings`) as soon as they change.
struct SettingsView: View {
    @Bindable var model: SettingsModel

    private func binding<T>(_ keyPath: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding(get: { model.settings[keyPath: keyPath] }, set: { v in model.update { $0[keyPath: keyPath] = v } })
    }

    private var retentionChoices: [Int] {
        Array(Set(AppSettings.retentionChoices + [model.settings.defaultRetentionDays])).sorted()
    }

    var body: some View {
        Form {
            Section {
                Toggle("Open Mirror at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                if model.loginStatus == .requiresApproval {
                    LabeledContent {
                        Button("Open Login Items Settings") { AgentRegistration.openLoginItemsSettings() }
                    } label: {
                        Label("Needs your approval in System Settings", systemImage: "exclamationmark.triangle")
                    }
                }
            } header: { Text("General") } footer: {
                Text("Backups run in the background whether or not Mirror is open.")
            }

            Section {
                Picker("Deep check", selection: binding(\.deepCheck)) {
                    Text("Every Week").tag(AppSettings.DeepCheckFrequency.weekly)
                    Text("Every Month").tag(AppSettings.DeepCheckFrequency.monthly)
                    Text("Every 3 Months").tag(AppSettings.DeepCheckFrequency.quarterly)
                }
            } header: { Text("Checks") } footer: {
                Text("A Deep check compares the content of files on this Mac with the backup. It never downloads freed iCloud files.")
            }

            Section {
                Picker("Keep old versions for", selection: binding(\.defaultRetentionDays)) {
                    ForEach(retentionChoices, id: \.self) { Text("\($0) days").tag($0) }
                }
            } header: { Text("Archive") } footer: {
                Text("Applies to sets you add from now on. Existing sets keep their own setting.")
            }

            Section {
                Toggle("Pause backups in Low Power Mode", isOn: binding(\.pauseInLowPowerMode))
                Toggle("Full Speed", isOn: binding(\.fullSpeed))
            } header: { Text("Performance") } footer: {
                Text("Scheduled backups run quietly at background priority. Full Speed uses normal priority with more files at once (4 transfers, 8 checks), so it finishes sooner and uses more of your Mac and network. Back Up Now and manual drive backups always run at normal priority.")
            }

            if let e = model.error {
                Section { Label(e, systemImage: "exclamationmark.triangle").font(.callout) }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .frame(minWidth: 460, idealWidth: 520)
        .onAppear { model.refreshLoginStatus() }
    }
}
