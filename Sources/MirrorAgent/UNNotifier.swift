import Foundation
import MirrorCore
@preconcurrency import UserNotifications

/// Posts problems as macOS notifications. Swap point: if Gate 1 shows the agent cannot post directly,
/// replace this with a `Notifying` that launches `Mirror --notify <problem-id>` instead.
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
        let id = "mirror.\(problem.rawValue).\(pair.set.uuidString)-\(pair.destination.uuidString)"
        do { try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil)); return true }
        catch { return false }
    }

    func postSafeToEject(volumeName: String, volumeUUID: String) async -> Bool {
        guard Bundle.main.bundleIdentifier != nil else { return false }
        let center = UNUserNotificationCenter.current()
        guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return false }
        let eject = UNNotificationAction(identifier: DriveNotification.ejectAction, title: "Eject")
        center.setNotificationCategories([UNNotificationCategory(identifier: DriveNotification.category, actions: [eject],
                                                                 intentIdentifiers: [])])
        let content = UNMutableNotificationContent()
        content.title = "Backup finished"
        content.body = "\(volumeName) is safe to eject."
        content.categoryIdentifier = DriveNotification.category
        content.userInfo = [DriveNotification.volumeKey: volumeUUID]
        do {
            try await center.add(UNNotificationRequest(identifier: "mirror.drive-finished.\(volumeUUID)", content: content, trigger: nil))
            return true
        } catch { return false }
    }
}
