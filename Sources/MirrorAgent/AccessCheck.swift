import Foundation
import MirrorCore

/// Records whether this launchd-started agent can read iCloud Drive and ~/Documents, to
/// `<support>/access.json`. Read-only apart from that file, and touches no Keychain item.
func recordAccess() {
    AgentAccess.writeReport(support: MirrorPaths.support)
}
