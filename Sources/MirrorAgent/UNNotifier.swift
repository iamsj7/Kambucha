import Foundation
import MirrorCore
@preconcurrency import UserNotifications

/// Posts problems as macOS notifications. Swap point: if Gate 1 shows the agent cannot post directly,
/// replace this with a `Notifying` that launches `Mirror --notify <problem-id>` instead.
struct UNNotifier: Notifying {
    func post(_ problem: Problem, setName: String, detail: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = setName
            content.body = NotificationText.body(problem, setName: setName, detail: detail)
            // Stable identifier per problem and set: a repeat replaces rather than stacks.
            let req = UNNotificationRequest(identifier: "mirror.\(problem.rawValue).\(setName)",
                                            content: content, trigger: nil)
            center.add(req)
        }
    }
}
