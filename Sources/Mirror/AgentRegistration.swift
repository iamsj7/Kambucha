import Foundation
import ServiceManagement
import MirrorCore

/// What Settings needs from the launch-at-login service, so it can be faked in tests.
@MainActor
protocol LoginItemControlling {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

/// Registers the background agent and the login item with `SMAppService`.
struct AgentRegistration {
    static let plistName = "\(MirrorCore.agentLabel).plist"

    private static var agent: SMAppService { .agent(plistName: plistName) }

    /// Registers the LaunchAgent that runs backups. The first time, macOS may ask the owner to allow it
    /// in Login Items, in which case `status()` reads `.requiresApproval` afterwards.
    static func enable() throws {
        if agent.status == .enabled { return }
        try agent.register()
    }

    static func status() -> SMAppService.Status { agent.status }

    static func openLoginItemsSettings() { SMAppService.openSystemSettingsLoginItems() }

    /// Launch at login uses the main app service, separate from the backup agent.
    struct LoginItem: LoginItemControlling {
        var status: SMAppService.Status { SMAppService.mainApp.status }
        func register() throws { try SMAppService.mainApp.register() }
        func unregister() throws { try SMAppService.mainApp.unregister() }
    }
}
