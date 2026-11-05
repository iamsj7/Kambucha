import Foundation

public enum Problem: String, Codable, CaseIterable, Sendable {
    case verificationFailed, deletionsHeld, destinationMissing, permissionLost, iCloudUnavailable
    case repeatedFailures, uploadStalled, fileRefused, signInExpired, drillFailed, drillDue
    case agentFailed
    case driveOverdue, driveFull
    case setNameInUse

    /// Plain, specific lead-in. Never includes file contents or secrets.
    public var headline: String {
        switch self {
        case .verificationFailed: "Backup verification failed"
        case .deletionsHeld: "Backup paused"
        case .destinationMissing: "Backup destination not found"
        case .permissionLost: "Kambucha needs Full Disk Access"
        case .iCloudUnavailable: "iCloud Drive is unavailable"
        case .repeatedFailures: "Backup keeps failing"
        case .uploadStalled: "Upload is stalled"
        case .fileRefused: "iCloud refused a file"
        case .signInExpired: "Sign-in expired"
        case .drillFailed: "Restore test failed"
        case .drillDue: "Restore test is due"
        case .agentFailed: "Kambucha could not run"
        case .driveOverdue: "Backup drive not connected"
        case .driveFull: "Backup drive is full"
        case .setNameInUse: "Set name is already in use"
        }
    }
}

public enum NotificationText {
    /// For example "Backup paused: 1,240 deletions held".
    public static func body(_ p: Problem, setName: String, detail: String) -> String {
        detail.isEmpty ? p.headline : "\(p.headline): \(detail)"
    }
}

public protocol Notifying: Sendable {
    /// Returns true only if the notification was handed to the system. False means "try again later".
    func post(_ problem: Problem, pair: PairID, setName: String, detail: String) async -> Bool
    /// A drive finished its backup. Not a problem, so nothing is stored or retried.
    func postSafeToEject(volumeName: String, volumeUUID: String) async -> Bool
}

public extension Notifying {
    func postSafeToEject(volumeName: String, volumeUUID: String) async -> Bool { false }
}

/// For a process that only reads problems, or a test that doesn't care.
public struct NoNotifier: Notifying {
    public init() {}
    public func post(_ problem: Problem, pair: PairID, setName: String, detail: String) async -> Bool { false }
}

public struct ActiveProblem: Codable, Equatable, Sendable {
    public var problem: Problem
    public var pair: PairID
    public var setName: String
    public var detail: String
    public var since: Date
    /// False until a notification was actually delivered.
    public var notified: Bool
    public init(problem: Problem, pair: PairID, setName: String, detail: String, since: Date, notified: Bool = false) {
        self.problem = problem; self.pair = pair; self.setName = setName; self.detail = detail
        self.since = since; self.notified = notified
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        problem = try c.decode(Problem.self, forKey: .problem)
        pair = try c.decode(PairID.self, forKey: .pair)
        setName = try c.decode(String.self, forKey: .setName)
        detail = try c.decode(String.self, forKey: .detail)
        since = try c.decode(Date.self, forKey: .since)
        notified = try c.decodeIfPresent(Bool.self, forKey: .notified) ?? true
    }
}

/// A problem about a destination as a whole still sits on one pair. A paused set wouldn't show it.
public enum ProblemAnchor {
    public static func set(for destination: UUID, in sets: [BackupSet]) -> BackupSet? {
        let using = sets.filter { $0.destinationIDs.contains(destination) }
        return using.first { !$0.isPaused } ?? using.first
    }
}

public struct ProblemCenterError: Error, Equatable { public var message: String }

/// Tracks open problems per pair in `<root>/problems.json`. A problem notifies once until cleared;
/// a notification that was not delivered is retried. All file access is serialised by `problems.lock`,
/// so the agent and the UI can both use it.
public struct ProblemCenter: Sendable {
    private let root: URL
    private let url: URL
    private let notifier: any Notifying
    private let postTimeout: Duration
    public static let defaultPostTimeout: Duration = .seconds(10)
    public init(root: URL, notifier: any Notifying, postTimeout: Duration = ProblemCenter.defaultPostTimeout) {
        self.root = root; url = root.appendingPathComponent("problems.json"); self.notifier = notifier
        self.postTimeout = postTimeout
    }

    /// Saves a problem without notifying, for moments a notification mustn't delay. `raise` or the
    /// next run's `retryPending` delivers it, so a kill right after this loses nothing.
    public func store(_ problem: Problem, pair: PairID, setName: String, detail: String) throws {
        try locked {
            var all = try load()
            guard !all.contains(where: { $0.problem == problem && $0.pair == pair }) else { return }
            all.append(ActiveProblem(problem: problem, pair: pair, setName: setName, detail: detail, since: Date()))
            try save(all)
        }
    }

    /// News an open problem's first alert couldn't carry: its detail changes and the next `raise` or
    /// `retryPending` posts it again. With nothing open, it's a new problem.
    public func restate(_ problem: Problem, pair: PairID, setName: String, detail: String) throws {
        try locked {
            var all = try load()
            if let i = all.firstIndex(where: { $0.problem == problem && $0.pair == pair }) {
                all[i].detail = detail
                all[i].notified = false
            } else {
                all.append(ActiveProblem(problem: problem, pair: pair, setName: setName, detail: detail, since: Date()))
            }
            try save(all)
        }
    }

    public func raise(_ problem: Problem, pair: PairID, setName: String, detail: String) async throws {
        let toPost: Bool = try locked {
            var all = try load()
            if let existing = all.first(where: { $0.problem == problem && $0.pair == pair }) {
                return !existing.notified
            }
            all.append(ActiveProblem(problem: problem, pair: pair, setName: setName, detail: detail, since: Date()))
            try save(all)
            return true
        }
        guard toPost else { return }
        let stored = try active().first { $0.problem == problem && $0.pair == pair }
        let ok = await deliver(problem, pair: pair, setName: stored?.setName ?? setName, detail: stored?.detail ?? detail)
        // Duplicate posts are harmless: the notification identifier is stable, so a repeat replaces the first.
        if ok, let since = stored?.since { try markNotified(problem, pair, since: since) }
    }

    /// Retries every problem whose notification was not delivered. Call once per run.
    public func retryPending() async throws {
        for p in try active() where !p.notified {
            if await deliver(p.problem, pair: p.pair, setName: p.setName, detail: p.detail) {
                try markNotified(p.problem, p.pair, since: p.since)
            }
        }
    }

    /// A notifier that never answers counts as not delivered, so it's retried. It can't be cancelled
    /// (a permission prompt, say), so it's left behind, and ends with the process.
    private func deliver(_ problem: Problem, pair: PairID, setName: String, detail: String) async -> Bool {
        await bounded { await $0.post(problem, pair: pair, setName: setName, detail: detail) }
    }

    /// Best effort, under the same time limit, so it can never hold the agent open.
    public func announceSafeToEject(volumeName: String, volumeUUID: String) async {
        _ = await bounded { await $0.postSafeToEject(volumeName: volumeName, volumeUUID: volumeUUID) }
    }

    private func bounded(_ post: @escaping @Sendable (any Notifying) async -> Bool) async -> Bool {
        let (notifier, timeout) = (self.notifier, postTimeout)
        let answer = FirstAnswer()
        return await withCheckedContinuation { continuation in
            answer.attach(continuation)
            Task { answer.give(await post(notifier)) }
            // A dispatch timer, not a task: a timeout mustn't wait for the pool that may be what's stuck.
            let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { answer.give(false) }
        }
    }

    public func clear(_ problem: Problem, pair: PairID) throws {
        try locked {
            let all = try load()
            let kept = all.filter { !($0.problem == problem && $0.pair == pair) }
            if kept.count != all.count { try save(kept) }
        }
    }

    /// Lets go of problems whose pair no longer exists, so nothing is left that no run could ever clear.
    /// The agent's own problems belong to no pair and stay.
    public func retain(pairs: Set<PairID>) throws {
        try locked {
            let all = try load()
            let kept = all.filter { $0.pair == .agent || pairs.contains($0.pair) }
            if kept.count != all.count { try save(kept) }
        }
    }

    public func active() throws -> [ActiveProblem] { try locked { try load() } }

    /// Only marks the same occurrence that was posted, not one raised again after a clear.
    private func markNotified(_ problem: Problem, _ pair: PairID, since: Date) throws {
        try locked {
            var all = try load()
            guard let i = all.firstIndex(where: { $0.problem == problem && $0.pair == pair && $0.since == since }) else { return }
            all[i].notified = true
            try save(all)
        }
    }

    private func locked<T>(_ body: () throws -> T) throws -> T {
        let lock = RunLock(url: root.appendingPathComponent("problems.lock"))
        guard try lock.acquire(timeout: 5) else { throw ProblemCenterError(message: "problems.lock busy") }
        defer { lock.release() }
        return try body()
    }

    /// A corrupt file is moved aside and treated as empty so it can't block every alert.
    private func load() throws -> [ActiveProblem] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)  // a read failure throws; it is not corruption
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        do { return try d.decode([ActiveProblem].self, from: data) }
        catch {
            let aside = root.appendingPathComponent("problems.corrupt-\(UUID().uuidString).json")
            try? FileManager.default.moveItem(at: url, to: aside)
            return []
        }
    }

    private func save(_ list: [ActiveProblem]) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970  // full precision, so `since` identifies an occurrence
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(list).write(to: url, options: .atomic)
    }
}

/// Resumes one continuation with whichever answer comes first.
private final class FirstAnswer: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    func attach(_ c: CheckedContinuation<Bool, Never>) { lock.withLock { continuation = c } }
    func give(_ value: Bool) {
        let waiting: CheckedContinuation<Bool, Never>? = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        waiting?.resume(returning: value)
    }
}
