import SwiftUI
import ServiceManagement
import MirrorCore

@main
struct MirrorApp: App {
    @State private var model: AppModel

    init() {
        #if DEBUG
        // Debug builds only: --fixture <name> runs against fixture state files in a temp folder, and
        // --snapshot <dir> renders every fixture in light and dark to PNGs, then exits.
        let dbg = CommandLine.arguments
        if let i = dbg.firstIndex(of: "--snapshot"), i + 1 < dbg.count {
            DebugFixtures.snapshotAll(to: URL(fileURLWithPath: dbg[i + 1]))
            exit(0)
        }
        if let i = dbg.firstIndex(of: "--snapshot-main"), i + 1 < dbg.count {
            _ = NSApplication.shared
            DebugFixtures.snapshotMain(to: URL(fileURLWithPath: dbg[i + 1]))
            exit(0)
        }
        if let i = dbg.firstIndex(of: "--snapshot-progress"), i + 1 < dbg.count {
            DebugFixtures.snapshotProgress(to: URL(fileURLWithPath: dbg[i + 1]))
            exit(0)
        }
        if let i = dbg.firstIndex(of: "--fixture"), i + 1 < dbg.count, let f = DebugFixtures.Name(rawValue: dbg[i + 1]) {
            _model = State(initialValue: AppModel(support: DebugFixtures.make(f)))
        } else {
            _model = State(initialValue: AppModel())
        }
        #else
        _model = State(initialValue: AppModel())
        #endif
        #if MIRROR_PROBES
        // Command-line helpers for the permission proofs; the app has no UI for these yet.
        let args = CommandLine.arguments
        if args.contains("--register-agent") {
            let svc = SMAppService.agent(plistName: "\(MirrorCore.agentLabel).plist")
            do { try svc.register() } catch { print("register error: \(error)") }
            print("agent status: \(svc.status.rawValue) (0 notRegistered, 1 enabled, 2 requiresApproval, 3 notFound)")
            exit(0)
        }
        if args.contains("--unregister-agent") {
            let svc = SMAppService.agent(plistName: "\(MirrorCore.agentLabel).plist")
            do { try svc.unregister() } catch { print("unregister error: \(error)") }
            print("agent status: \(svc.status.rawValue)")
            exit(0)
        }
        #endif
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarPanel(model: model)
        } label: {
            Image(systemName: StatusPresentation(model.status).symbol)
                .accessibilityLabel("Mirror, \(StatusPresentation(model.status).title)")
        }
        .menuBarExtraStyle(.window)

        Window("Mirror", id: "main") { MainWindow(model: model) }
    }
}
