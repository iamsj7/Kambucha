import SwiftUI
import ServiceManagement
import KambuchaCore

@main
struct KambuchaApp: App {
    @State private var model: AppModel
    @State private var settings: SettingsModel
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @Environment(\.openWindow) private var openWindow
    /// Past the first-run screen, Kambucha is a menu bar app: opening at login must not put a window in the way, unless
    /// there's no menu bar icon to open it from. An unreadable settings file counts as the icon being there, as it will be.
    private let opensWindowAtLaunch: Bool

    init() {
        let model: AppModel
        #if DEBUG
        // Debug builds only: --fixture <name> runs against fixture state files in a temp folder, and
        // --snapshot <dir> renders every fixture in light and dark to PNGs, then exits.
        let dbg = CommandLine.arguments
        if let i = dbg.firstIndex(of: "--snapshot"), i + 1 < dbg.count {
            DebugFixtures.snapshotAll(to: URL(fileURLWithPath: dbg[i + 1]))
            exit(0)
        }
        if let i = dbg.firstIndex(of: "--snapshot-views"), i + 1 < dbg.count {
            _ = NSApplication.shared
            DebugViewSnapshots.snapshotAll(to: URL(fileURLWithPath: dbg[i + 1]))
            exit(0)
        }
        if let i = dbg.firstIndex(of: "--snapshot-main"), i + 1 < dbg.count {
            _ = NSApplication.shared
            DebugFixtures.snapshotMain(to: URL(fileURLWithPath: dbg[i + 1]))
            exit(0)
        }
        if let i = dbg.firstIndex(of: "--snapshot-coverage"), i + 1 < dbg.count {
            _ = NSApplication.shared
            DebugCoverageSnapshots.snapshotAll(to: URL(fileURLWithPath: dbg[i + 1]))
            exit(0)
        }
        if let i = dbg.firstIndex(of: "--snapshot-layout"), i + 1 < dbg.count {
            _ = NSApplication.shared
            let only = dbg.firstIndex(of: "--snapshot-only").flatMap { $0 + 1 < dbg.count ? dbg[$0 + 1] : nil }
            DebugLayoutSnapshots.snapshotAll(to: URL(fileURLWithPath: dbg[i + 1]), only: only)
            exit(0)
        }
        if let i = dbg.firstIndex(of: "--snapshot-progress"), i + 1 < dbg.count {
            DebugFixtures.snapshotProgress(to: URL(fileURLWithPath: dbg[i + 1]))
            exit(0)
        }
        if let i = dbg.firstIndex(of: "--fixture"), i + 1 < dbg.count, let f = DebugFixtures.Name(rawValue: dbg[i + 1]) {
            // --fixture-onboarded and --fixture-no-menu-bar set the fixture up for checking the launch and reopen rules by hand.
            let root = DebugFixtures.make(f)
            if dbg.contains("--fixture-onboarded") { try? ConfigStore(root: root).noteOnboardingFinished() }
            if dbg.contains("--fixture-no-menu-bar") {
                var off = AppSettings()
                off.showInMenuBar = false
                try? SettingsStore(root: root).save(off)
            }
            model = AppModel(support: root)
        } else {
            model = AppModel()
        }
        #else
        model = AppModel()
        #endif
        _model = State(initialValue: model)
        _settings = State(initialValue: SettingsModel(store: SettingsStore(root: model.support)))
        AppDelegate.model = model
        opensWindowAtLaunch = AppPresence.opensWindowAtLaunch(
            onboardingFinished: ConfigStore(root: model.support).onboardingFinished,
            showInMenuBar: (try? SettingsStore(root: model.support).load())?.showInMenuBar ?? true)
        #if KAMBUCHA_PROBES
        // Command-line helpers for the permission proofs; the app has no UI for these yet.
        let args = CommandLine.arguments
        if args.contains("--register-agent") {
            let svc = SMAppService.agent(plistName: "\(KambuchaCore.agentLabel).plist")
            do { try svc.register() } catch { print("register error: \(error)") }
            print("agent status: \(svc.status.rawValue) (0 notRegistered, 1 enabled, 2 requiresApproval, 3 notFound)")
            exit(0)
        }
        if args.contains("--unregister-agent") {
            let svc = SMAppService.agent(plistName: "\(KambuchaCore.agentLabel).plist")
            do { try svc.unregister() } catch { print("unregister error: \(error)") }
            print("agent status: \(svc.status.rawValue)")
            exit(0)
        }
        #endif
    }

    var body: some Scene {
        // The system can take the icon away too, if the owner drags it out of the menu bar, and that saves here the same way.
        MenuBarExtra(isInserted: Binding(get: { settings.settings.showInMenuBar },
                                         set: { shown in settings.update { $0.showInMenuBar = shown } })) {
            MenuBarPanel(model: model)
        } label: {
            Image(nsImage: MenuBarIcon.image(for: model.status))
                .accessibilityLabel("Kambucha, \(StatusPresentation(model.status).title)")
        }
        .menuBarExtraStyle(.menu)
        .onChange(of: settings.settings.showInMenuBar, initial: true) { _, shown in
            DockPresence.menuBarChanged(shown)
            AppDelegate.showMainWindow = { [openWindow] in openWindow(id: "main") }
        }

        Window("Kambucha", id: "main") { MainWindow(model: model) }
            .defaultSize(width: 1040, height: 700)
            .defaultLaunchBehavior(opensWindowAtLaunch ? .presented : .suppressed)
            .restorationBehavior(.disabled)
            .commands {
                SidebarCommands()
                ToolbarCommands()
                CommandGroup(replacing: .newItem) { AddCommands(model: model) }
                CommandMenu("Backup") { BackupCommands(model: model) }
            }

        Settings { SettingsView(model: settings) }
    }
}

/// File's items. Views, not Commands, for `openWindow`: the main window may be closed.
private struct AddCommands: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Add Backup Set…") { add(.set) }
            .keyboardShortcut("n")
        Button("Add Destination…") { add(.destination) }
            .keyboardShortcut("n", modifiers: [.command, .shift])
    }

    private func add(_ request: AppModel.AddRequest) {
        model.addRequest = request
        openWindow(id: "main")
        NSApplication.shared.activate()
    }
}

private struct BackupCommands: View {
    @Bindable var model: AppModel

    var body: some View {
        Button("Back Up Now") { model.runNow(nil) }
            .disabled(!model.canBackUp)
        Button(model.pauseTitle) { model.togglePause() }
            .disabled(!model.canPause)
    }
}
