import Foundation

/// The agent writes `<support>/agent.pid` atomically at start and deletes it at exit.
/// Running means the file exists and that process is alive; a stale file left by a crash is removed.
public enum AgentPresence {
    public static let fileName = "agent.pid"

    public static func isRunning(support: URL) -> Bool {
        let url = support.appendingPathComponent(fileName)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        guard let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 else { return false }
        if kill(pid, 0) == 0 || errno == EPERM { return true }
        try? FileManager.default.removeItem(at: url)
        return false
    }
}
