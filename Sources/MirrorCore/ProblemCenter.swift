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
    func post(_ problem: Problem, setName: String, detail: String)
}

public struct ActiveProblem: Codable, Equatable, Sendable {
    public var problem: Problem
    public var pair: PairID
    public var setName: String
    public var detail: String
    public var since: Date
    public init(problem: Problem, pair: PairID, setName: String, detail: String, since: Date) {
        self.problem = problem; self.pair = pair; self.setName = setName; self.detail = detail; self.since = since
    }
}

/// Tracks open problems per pair in `<root>/problems.json`. A problem notifies once until cleared.
public struct ProblemCenter: Sendable {
    private let url: URL
    private let notifier: any Notifying
    public init(root: URL, notifier: any Notifying) {
        url = root.appendingPathComponent("problems.json"); self.notifier = notifier
    }

    public func raise(_ problem: Problem, pair: PairID, setName: String, detail: String) throws {
        var all = try active()
        if all.contains(where: { $0.problem == problem && $0.pair == pair }) { return }
        all.append(ActiveProblem(problem: problem, pair: pair, setName: setName, detail: detail, since: Date()))
        try save(all)
        notifier.post(problem, setName: setName, detail: detail)
    }

    public func clear(_ problem: Problem, pair: PairID) throws {
        let all = try active()
        let kept = all.filter { !($0.problem == problem && $0.pair == pair) }
        if kept.count != all.count { try save(kept) }
    }

    public func active() throws -> [ActiveProblem] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try d.decode([ActiveProblem].self, from: Data(contentsOf: url))
    }

    private func save(_ list: [ActiveProblem]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(list).write(to: url, options: .atomic)
    }
}
