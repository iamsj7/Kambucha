/// Where the owner finds Kambucha. The menu bar icon can be turned off, so whatever else is true there's always
/// a menu bar icon or a Dock icon, and the app can't end up running with no way back.
public struct AppPresence: Equatable, Sendable {
    public var showInMenuBar: Bool
    public var windowOpen: Bool

    public init(showInMenuBar: Bool, windowOpen: Bool) {
        self.showInMenuBar = showInMenuBar; self.windowOpen = windowOpen
    }

    public var showsInDock: Bool { windowOpen || !showInMenuBar }

    public static func opensWindowAtLaunch(onboardingFinished: Bool, showInMenuBar: Bool) -> Bool {
        !onboardingFinished || !showInMenuBar
    }
}
