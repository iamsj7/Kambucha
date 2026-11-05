import Foundation

/// The agent writes `<support>/agent.pid` atomically at start and deletes it at exit: its pid, then when that process
/// started. Running means that same process is alive. A crash leaves the file behind, and macOS may by then have given the
/// pid to something else, so a live pid isn't enough. A stale file is removed.
public enum AgentPresence {
    public static let fileName = "agent.pid"

    /// What the file holds for this process. The second line is the process's start, which a reused pid can't match.
    public static func record(for pid: pid_t) -> String {
        startTime(of: pid).map { "\(pid)\n\($0)\n" } ?? "\(pid)\n"
    }

    public static func isRunning(support: URL) -> Bool {
        let url = support.appendingPathComponent(fileName)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let first = lines.first, let pid = pid_t(first), pid > 0 else { return false }
        let alive = kill(pid, 0) == 0 || errno == EPERM
        // A file with no start time, or a process whose start can't be read, goes by the pid alone.
        let same = lines.count < 2 || startTime(of: pid).map { String($0) == lines[1] } ?? true
        if alive && same { return true }
        try? FileManager.default.removeItem(at: url)
        return false
    }

    /// Microseconds since the epoch, from the kernel. Nil when there's no such process.
    private static func startTime(of pid: pid_t) -> Int64? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&name, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return Int64(start.tv_sec) * 1_000_000 + Int64(start.tv_usec)
    }
}
