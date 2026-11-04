import Foundation
import MirrorCore

/// Records whether this launchd-started agent can read iCloud Drive and ~/Documents, to
/// `<support>/access.json`. Read-only apart from that file, and touches no Keychain item.
/// Not yet called: main.swift must call it at the start of every launchd run (see the report).
func recordAccess() {
    AgentAccess.writeReport(support: MirrorPaths.support)
}
