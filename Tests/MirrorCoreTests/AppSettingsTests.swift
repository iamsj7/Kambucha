import Testing
import Foundation
@testable import MirrorCore

struct AppSettingsTests {
    func tempRoot() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("mirror-test-\(UUID().uuidString)") }

    @Test func defaultsWhenNothingSaved() throws {
        let s = try SettingsStore(root: tempRoot()).load()
        #expect(s == AppSettings())
        #expect(s.deepCheck == .monthly && s.defaultRetentionDays == 30)
        #expect(!s.pauseInLowPowerMode && !s.fullSpeed)
    }

    @Test func roundTrips() throws {
        let store = SettingsStore(root: tempRoot())
        var s = AppSettings(); s.deepCheck = .weekly; s.defaultRetentionDays = 90; s.fullSpeed = true; s.pauseInLowPowerMode = true
        try store.save(s)
        #expect(try store.load() == s)
    }

    @Test func missingKeysFallBackToDefaults() throws {
        let root = tempRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(#"{"fullSpeed":true}"#.utf8).write(to: root.appendingPathComponent("settings.json"))
        let s = try SettingsStore(root: root).load()
        #expect(s.fullSpeed && s.deepCheck == .monthly && s.defaultRetentionDays == 30)
    }

    @Test func drillIsDueSixMonthsAfterTheLastOne() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let cloud = Destination(name: "Drive", kind: .googleDrive)
        func state(finished: Date?, drill: Date?) -> SetState { var s = SetState(); s.lastFinished = finished; s.lastDrill = drill; return s }
        let day: TimeInterval = 86_400
        // Not before the first backup finishes.
        #expect(!DrillSchedule.isDue(cloud, states: [state(finished: nil, drill: nil)], now: now))
        // Straight after the first backup.
        #expect(DrillSchedule.isDue(cloud, states: [state(finished: now - day, drill: nil)], now: now))
        // Recent drill, then an old one.
        #expect(!DrillSchedule.isDue(cloud, states: [state(finished: now - day, drill: now - 90 * day)], now: now))
        #expect(DrillSchedule.isDue(cloud, states: [state(finished: now - day, drill: now - 200 * day)], now: now))
        // The newest drill across pairs counts.
        #expect(!DrillSchedule.isDue(cloud, states: [state(finished: now - day, drill: now - 200 * day),
                                                      state(finished: now - day, drill: now - day)], now: now))
        // Unencrypted destinations have nothing to test.
        let icloud = Destination(name: "iCloud", kind: .iCloudFolder)
        #expect(!DrillSchedule.isDue(icloud, states: [state(finished: now - day, drill: nil)], now: now))
    }

    @Test func settingsFileThatIsDamagedThrows() throws {
        let root = tempRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: root.appendingPathComponent("settings.json"))
        #expect(throws: (any Error).self) { try SettingsStore(root: root).load() }
    }

    @Test func olderSettingsGetTheDefaultDriveReminder() throws {
        #expect(try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8)).driveReminderDays == 7)
    }
}
