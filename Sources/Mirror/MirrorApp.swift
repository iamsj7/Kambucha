import SwiftUI
import MirrorCore

@main
struct MirrorApp: App {
    var body: some Scene {
        MenuBarExtra("Mirror", systemImage: "arrow.triangle.2.circlepath") {
            Text("Mirror")
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
    }
}
