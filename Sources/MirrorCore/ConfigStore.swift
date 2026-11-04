import Foundation

/// JSON storage under `root` (Application Support/Mirror in the app). Holds no secrets.
public final class ConfigStore: Sendable {
    private let root: URL
    public init(root: URL) { self.root = root }

    private var setsURL: URL { root.appendingPathComponent("sets.json") }
    private var destinationsURL: URL { root.appendingPathComponent("destinations.json") }
    private var onboardingMark: URL { root.appendingPathComponent("onboarding-finished") }
    private var noAccessMark: URL { root.appendingPathComponent("continued-without-full-disk-access") }
    private func stateURL(_ p: PairID) -> URL {
        root.appendingPathComponent("state/\(p.set.uuidString)-\(p.destination.uuidString).json")
    }

    public func loadSets() throws -> [BackupSet] { try load([BackupSet].self, at: setsURL) ?? [] }
    public func saveSets(_ sets: [BackupSet]) throws { try save(sets, to: setsURL) }
    public func loadDestinations() throws -> [Destination] { try load([Destination].self, at: destinationsURL) ?? [] }
    public func saveDestinations(_ d: [Destination]) throws { try save(d, to: destinationsURL) }
    /// Every step of the first-run screen was done once. Kept apart from `settings.json`, which the Settings
    /// window writes back whole from what it loaded at launch.
    public var onboardingFinished: Bool { FileManager.default.fileExists(atPath: onboardingMark.path) }

    public func noteOnboardingFinished() throws {
        try FileManager.default.createDirectory(at: onboardingMark.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: onboardingMark, options: .atomic)
    }

    /// The owner chose to go on after a check found no Full Disk Access. A later passing report ends it.
    public var continuedWithoutFullDiskAccess: Bool { FileManager.default.fileExists(atPath: noAccessMark.path) }

    public func noteContinuedWithoutFullDiskAccess() throws {
        try FileManager.default.createDirectory(at: noAccessMark.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: noAccessMark, options: .atomic)
    }

    public func clearContinuedWithoutFullDiskAccess() { try? FileManager.default.removeItem(at: noAccessMark) }

    public func state(for pair: PairID) throws -> SetState { try load(SetState.self, at: stateURL(pair)) ?? SetState() }
    public func save(_ state: SetState, for pair: PairID) throws { try save(state, to: stateURL(pair)) }

    private func load<T: Decodable>(_ type: T.Type, at url: URL) throws -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try d.decode(type, from: Data(contentsOf: url))
    }

    private func save<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(value).write(to: url, options: .atomic)
    }
}
