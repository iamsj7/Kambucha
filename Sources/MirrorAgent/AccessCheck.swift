import Foundation
import MirrorCore

/// Records whether this launchd-started agent can read iCloud Drive and ~/Documents, and whether it has
/// Full Disk Access, to `<support>/access.json`. Read-only apart from that file, and touches no Keychain item.
func recordAccess() {
    var support = MirrorPaths.support
    #if MIRROR_PROBES
    // Proof builds only: a throwaway run must leave the real support folder alone.
    if let home = ProcessInfo.processInfo.environment["MIRROR_PROOF_HOME"] {
        support = MirrorPaths.support(home: URL(fileURLWithPath: home))
    }
    #endif
    AgentAccess.writeReport(support: support)
}
