import Foundation

/// Owner preferences the agent also needs to read, so they live in `<support>/settings.json` beside the
/// other state files rather than in the app's `UserDefaults`, which the agent process can't see.
/// Launch at login is not stored here: `SMAppService` is its source of truth.
public struct AppSettings: Codable, Equatable, Sendable {
    public enum DeepCheckFrequency: String, Codable, CaseIterable, Sendable {
        case weekly, monthly, quarterly
        public var days: Int {
            switch self { case .weekly: 7; case .monthly: 30; case .quarterly: 90 }
        }
    }

    /// How often the Deep check runs (spec section 12: monthly by default).
    public var deepCheck: DeepCheckFrequency = .monthly
    /// Archive retention for sets created from now on. Each set keeps its own `archiveDays`.
    public var defaultRetentionDays = 30
    /// Scheduled runs wait while macOS is in Low Power Mode.
    public var pauseInLowPowerMode = false
    /// Scheduled iCloud and cloud runs lower themselves to background priority unless this is on; then they use
    /// normal priority with `--transfers 4 --checkers 8`. Back Up Now and every external drive run always do.
    public var fullSpeed = false
    /// A drive away for longer than this gets one quiet reminder.
    public var driveReminderDays = 7
    /// Off, Mirror lives in the Dock instead (see `AppPresence`). Backups run either way.
    public var showInMenuBar = true

    public static let retentionChoices = [7, 14, 30, 60, 90]

    public init() {}

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        deepCheck = try c.decodeIfPresent(DeepCheckFrequency.self, forKey: .deepCheck) ?? .monthly
        defaultRetentionDays = try c.decodeIfPresent(Int.self, forKey: .defaultRetentionDays) ?? 30
        pauseInLowPowerMode = try c.decodeIfPresent(Bool.self, forKey: .pauseInLowPowerMode) ?? false
        fullSpeed = try c.decodeIfPresent(Bool.self, forKey: .fullSpeed) ?? false
        driveReminderDays = try c.decodeIfPresent(Int.self, forKey: .driveReminderDays) ?? 7
        showInMenuBar = try c.decodeIfPresent(Bool.self, forKey: .showInMenuBar) ?? true
    }
}

public struct SettingsStore: Sendable {
    private let url: URL
    public init(root: URL) { url = root.appendingPathComponent("settings.json") }

    /// Defaults when nothing has been saved. A damaged file throws rather than silently resetting.
    public func load() throws -> AppSettings {
        guard FileManager.default.fileExists(atPath: url.path) else { return AppSettings() }
        return try JSONDecoder().decode(AppSettings.self, from: Data(contentsOf: url))
    }

    public func save(_ settings: AppSettings) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(settings).write(to: url, options: .atomic)
    }
}

/// When the restore drill reminder is due (spec section 8a): after the first backup to an encrypted
/// destination, then every 6 months. A reminder only; it never blocks anything.
public enum DrillSchedule {
    public static let intervalMonths = 6

    /// `states` are the states of every set-and-destination pair that uses `destination`.
    public static func isDue(_ destination: Destination, states: [SetState], now: Date = Date(),
                             calendar: Calendar = .current) -> Bool {
        guard destination.encrypted, states.contains(where: { $0.lastFinished != nil }) else { return false }
        guard let last = states.compactMap(\.lastDrill).max() else { return true }
        guard let due = calendar.date(byAdding: .month, value: intervalMonths, to: last) else { return false }
        return now >= due
    }
}
