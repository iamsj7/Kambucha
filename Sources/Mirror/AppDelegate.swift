import AppKit

/// What SwiftUI's scenes don't offer: reopening from Finder, Spotlight or the Dock, and the Dock menu.
/// Set up from statics, as the adaptor makes this object itself. No view can do it: with the icon hidden and
/// the window closed, none exists.
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    static var model: AppModel?
    static var showMainWindow: (() -> Void)?

    private var dockMenu: DockMenu?

    /// Always the main window, not only when nothing's showing: Settings alone counts as a visible window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        Self.showMainWindow?()
        sender.activate()
        return false
    }

    /// Backups don't depend on it, but the owner's way back does.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        guard let model = Self.model else { return nil }
        let built = DockMenu(model: model)
        dockMenu = built
        return built.menu
    }
}

/// Built fresh each time the Dock asks, so it's never stale. Same items and rules as the menu bar menu.
@MainActor final class DockMenu: NSObject {
    private let model: AppModel
    let menu = NSMenu()

    init(model: AppModel) {
        self.model = model
        super.init()
        menu.autoenablesItems = false
        add("Back Up Now", #selector(backUp), enabled: model.canBackUp)
        add(model.pauseTitle, #selector(togglePause), enabled: model.canPause)
    }

    private func add(_ title: String, _ action: Selector, enabled: Bool) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = enabled
        menu.addItem(item)
    }

    @objc private func backUp() { model.runNow(nil) }
    @objc private func togglePause() { model.togglePause() }
}
