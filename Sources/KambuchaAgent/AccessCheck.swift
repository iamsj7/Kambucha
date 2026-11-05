import Foundation
import KambuchaCore

/// Records whether this launchd-started agent can read iCloud Drive and ~/Documents, and whether it has
/// Full Disk Access, to `<support>/access.json`. Read-only apart from that file, and touches no Keychain item.
func recordAccess() {
    var support = KambuchaPaths.support
    #if KAMBUCHA_PROBES
    // Proof builds only: a throwaway run must leave the real support folder alone.
    if let home = ProcessInfo.processInfo.environment["KAMBUCHA_PROOF_HOME"] {
        support = KambuchaPaths.support(home: URL(fileURLWithPath: home))
    }
    #endif
    AgentAccess.writeReport(support: support)
}
