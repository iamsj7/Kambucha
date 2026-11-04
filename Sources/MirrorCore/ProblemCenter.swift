import Foundation

public enum Problem: String, Codable, CaseIterable, Sendable {
    case verificationFailed, deletionsHeld, destinationMissing, permissionLost, iCloudUnavailable
    case repeatedFailures, uploadStalled, fileRefused, signInExpired, drillFailed, drillDue

    /// Plain, specific lead-in. Never includes file contents or secrets.
    public var headline: String {
        switch self {
        case .verificationFailed: "Backup verification failed"
        case .deletionsHeld: "Backup paused"
        case .destinationMissing: "Backup destination not found"
        case .permissionLost: "Mirror needs Full Disk Access"
        case .iCloudUnavailable: "iCloud Drive is unavailable"
        case .repeatedFailures: "Backup keeps failing"
        case .uploadStalled: "Upload is stalled"
        case .fileRefused: "iCloud refused a file"
        case .signInExpired: "Sign-in expired"
        case .drillFailed: "Restore test failed"
        case .drillDue: "Restore test is due"
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

public struct ProblemCenterError: Error, Equatable { public var message: String }

/// Tracks open problems per pair in `<root>/problems.json`. A problem notifies once until cleared;
/// a notification that was not delivered is retried. All file access is serialised by `problems.lock`,
/// so the agent and the UI can both use it.
public struct ProblemCenter: Sendable {
    private let root: URL
    private let url: URL
    private let notifier: any Notifying
    public init(root: URL, notifier: any Notifying) {
        self.root = root; url = root.appendingPathComponent("problems.json"); self.notifier = notifier
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
        let ok = await notifier.post(problem, pair: pair, setName: stored?.setName ?? setName,
                                     detail: stored?.detail ?? detail)
        if ok { try markNotified(problem, pair) }
    }

    /// Retries every problem whose notification was not delivered. Call once per run.
    public func retryPending() async throws {
        for p in try active() where !p.notified {
            if await notifier.post(p.problem, pair: p.pair, setName: p.setName, detail: p.detail) {
                try markNotified(p.problem, p.pair)
            }
        }
    }

    public func clear(_ problem: Problem, pair: PairID) throws {
        try locked {
            let all = try load()
            let kept = all.filter { !($0.problem == problem && $0.pair == pair) }
            if kept.count != all.count { try save(kept) }
        }
    }

    public func active() throws -> [ActiveProblem] { try locked { try load() } }

    private func markNotified(_ problem: Problem, _ pair: PairID) throws {
        try locked {
            var all = try load()
            guard let i = all.firstIndex(where: { $0.problem == problem && $0.pair == pair }) else { return }
            all[i].notified = true
            try save(all)
        }
    }

    private func locked<T>(_ body: () throws -> T) throws -> T {
        let lock = RunLock(url: root.appendingPathComponent("problems.lock"))
        guard lock.acquire(timeout: 5) else { throw ProblemCenterError(message: "problems.lock busy") }
        defer { lock.release() }
        return try body()
    }

    /// A corrupt file is moved aside and treated as empty so it can't block every alert.
    private func load() throws -> [ActiveProblem] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        do { return try d.decode([ActiveProblem].self, from: Data(contentsOf: url)) }
        catch {
            let aside = root.appendingPathComponent("problems.corrupt-\(UUID().uuidString).json")
            try? FileManager.default.moveItem(at: url, to: aside)
            return []
        }
    }

    private func save(_ list: [ActiveProblem]) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(list).write(to: url, options: .atomic)
    }
}
