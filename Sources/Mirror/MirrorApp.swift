import SwiftUI
import ServiceManagement
import MirrorCore

@main
struct MirrorApp: App {
    init() {
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
        MenuBarExtra("Mirror", systemImage: "arrow.triangle.2.circlepath") {
            Text("Mirror")
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
    }
}
