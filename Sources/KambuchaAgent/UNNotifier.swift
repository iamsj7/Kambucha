import Foundation
import KambuchaCore
@preconcurrency import UserNotifications

/// Posts problems as macOS notifications. Swap point: if Gate 1 shows the agent cannot post directly,
/// replace this with a `Notifying` that launches `Kambucha --notify <problem-id>` instead.
struct UNNotifier: Notifying {
    func post(_ problem: Problem, pair: PairID, setName: String, detail: String) async -> Bool {
        // UNUserNotificationCenter traps in a process with no bundle identifier.
        guard Bundle.main.bundleIdentifier != nil else { return false }
        let center = UNUserNotificationCenter.current()
        guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return false }
        let content = UNMutableNotificationContent()
        content.title = setName
        content.body = NotificationText.body(problem, setName: setName, detail: detail)
        // Stable identifier per problem and pair: a repeat replaces rather than stacks.
        let id = "kambucha.\(problem.rawValue).\(pair.set.uuidString)-\(pair.destination.uuidString)"
        do { try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil)); return true }
        catch { return false }
    }

    func postSafeToEject(volumeName: String, volumeUUID: String) async -> Bool {
        guard Bundle.main.bundleIdentifier != nil else { return false }
        let center = UNUserNotificationCenter.current()
        guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return false }
        let content = UNMutableNotificationContent()
        content.title = "Backup finished"
        content.body = "\(volumeName) is safe to eject."
        do {
            try await center.add(UNNotificationRequest(identifier: "kambucha.drive-finished.\(volumeUUID)", content: content, trigger: nil))
            return true
        } catch { return false }
    }
}
