import Foundation
import MirrorCore

/// `MirrorAgent --check-access`: lists iCloud Drive and ~/Documents and exits 0 if both worked, else 1.
/// Read-only, touches no Keychain item. Not yet reachable: main.swift must call it (see the report).
func runCheckAccess() -> Never {
    exit(AgentAccess.check(paths: AgentAccess.defaultPaths()) ? 0 : 1)
}
