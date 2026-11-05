import Testing
import Foundation
import AppKit
import ServiceManagement
import MirrorCore
@testable import Mirror

@MainActor
private final class FakeLogin: LoginItemControlling {
    var status: SMAppService.Status = .notRegistered
    var error: (any Error)?
    func register() throws { if let error { throw error }; status = .enabled }
    func unregister() throws { if let error { throw error }; status = .notRegistered }
}

@MainActor
struct SettingsModelTests {
    func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("mirror-test-\(UUID().uuidString)") }

    @Test func changesPersistToSettingsFile() throws {
        let r = root()
        let m = SettingsModel(store: SettingsStore(root: r), login: FakeLogin())
        m.update { $0.fullSpeed = true; $0.deepCheck = .weekly }
        let reloaded = try SettingsStore(root: r).load()
        #expect(reloaded.fullSpeed && reloaded.deepCheck == .weekly)
        #expect(SettingsModel(store: SettingsStore(root: r), login: FakeLogin()).settings.fullSpeed)
    }

    @Test func hidingTheMenuBarIconPersists() throws {
        let r = root()
        let m = SettingsModel(store: SettingsStore(root: r), login: FakeLogin())
        #expect(m.settings.showInMenuBar)
        m.update { $0.showInMenuBar = false }
        #expect(!SettingsModel(store: SettingsStore(root: r), login: FakeLogin()).settings.showInMenuBar)
    }

    /// Damage never hides the icon: it reads as the default, which keeps the way back.
    @Test func damagedSettingsKeepTheIcon() throws {
        let r = root()
        try FileManager.default.createDirectory(at: r, withIntermediateDirectories: true)
        try Data("garbage".utf8).write(to: r.appendingPathComponent("settings.json"))
        #expect(SettingsModel(store: SettingsStore(root: r), login: FakeLogin()).settings.showInMenuBar)
    }

    @Test func damagedSettingsFileIsSurfaced() throws {
        let r = root()
        try FileManager.default.createDirectory(at: r, withIntermediateDirectories: true)
        try Data("garbage".utf8).write(to: r.appendingPathComponent("settings.json"))
        let m = SettingsModel(store: SettingsStore(root: r), login: FakeLogin())
        #expect(m.error != nil && m.settings == AppSettings())
    }

    @Test func launchAtLoginFollowsTheSystemService() {
        let login = FakeLogin()
        let m = SettingsModel(store: SettingsStore(root: root()), login: login)
        #expect(!m.launchAtLogin)
        m.setLaunchAtLogin(true)
        #expect(m.launchAtLogin && login.status == .enabled)
        m.setLaunchAtLogin(false)
        #expect(!m.launchAtLogin)
    }

    @Test func launchAtLoginFailureRevertsAndExplains() {
        let login = FakeLogin(); login.error = URLError(.unknown)
        let m = SettingsModel(store: SettingsStore(root: root()), login: login)
        m.setLaunchAtLogin(true)
        #expect(!m.launchAtLogin && m.error != nil)
    }
}

@MainActor
struct ActivityScanTests {
    func run(_ t: TimeInterval, _ status: RunRecord.Status) -> RunRecord {
        RunRecord(setID: UUID(), setName: "S", destinationID: UUID(), destinationName: "D", start: Date(timeIntervalSince1970: t),
                  end: Date(timeIntervalSince1970: t + 5), trigger: .schedule, scope: "all", status: status)
    }

    /// An empty list here would otherwise read as "no problems".
    @Test func aHistoryTooLongToSearchIsSaid() async throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("mirror-activity-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: support) }
        let store = RunRecordStore(root: support)
        try store.append(run(1_700_000_000, .failed))
        for i in 1...3 { try store.append(run(1_700_000_000 + Double(i) * 60, .success)) }
        let model = ActivityModel(support: support, maxRead: 2)
        model.filter.result = .problems
        await model.reload()
        #expect(model.records.isEmpty && model.reachedScanLimit)
        let whole = ActivityModel(support: support, maxRead: 10)
        whole.filter.result = .problems
        await whole.reload()
        #expect(whole.records.count == 1 && !whole.reachedScanLimit)
    }
}

struct ActivityPresentationTests {
    @Test func everyStatusHasASymbolThatExistsAndWords() {
        for s: RunRecord.Status in [.skipped, .success, .partial, .held, .failed, .verificationFailed] {
            let p = RunResultPresentation(s)
            #expect(NSImage(systemSymbolName: p.symbol, accessibilityDescription: nil) != nil, "\(p.symbol)")
            #expect(!p.title.isEmpty)
        }
    }

    @Test func countsSkipZeros() {
        var r = RunRecord(setID: UUID(), setName: "S", destinationID: UUID(), destinationName: "D", start: Date(), end: Date(),
                          trigger: .manual, scope: "all", status: .success)
        #expect(RunResultPresentation.counts(r) == "No changes")
        r.copied = 3; r.deleted = 1
        #expect(RunResultPresentation.counts(r) == "3 copied, 1 deleted")
    }

    private func skipped(_ scope: String) -> RunRecord {
        RunRecord(setID: UUID(), setName: "S", destinationID: UUID(), destinationName: "D", start: Date(), end: Date(),
                  trigger: .manual, scope: scope, status: .skipped)
    }

    @Test func aSkippedRunSaysWhy() {
        #expect(RunResultPresentation.counts(skipped("not connected")) == "Not connected")
        #expect(RunResultPresentation.counts(skipped("waiting for preview")) == "Waiting for preview")
        #expect(RunResultPresentation.counts(skipped("paused")) == "Paused")
        #expect(RunResultPresentation.counts(skipped("none")) == "Nothing to do")
    }

    @Test func aReadFailureOutranksAnyFilter() {
        #expect(ActivityEmptyState(loadFailed: true, isFiltering: true, search: "x") == .loadFailed)
        #expect(ActivityEmptyState(loadFailed: true, isFiltering: false, search: "") == .loadFailed)
    }

    @Test func onlyASearchIsToldToCheckItsSpelling() {
        #expect(ActivityEmptyState(loadFailed: false, isFiltering: true, search: "x") == .noSearchResults)
        #expect(ActivityEmptyState(loadFailed: false, isFiltering: true, search: "") == .noMatchingRuns)
        #expect(ActivityEmptyState(loadFailed: false, isFiltering: false, search: "") == .noActivity)
    }

    @MainActor @Test func theFirstReadDoesNotWaitForTyping() async {
        let m = ActivityModel(support: FileManager.default.temporaryDirectory.appendingPathComponent("mirror-activity-\(UUID().uuidString)"))
        #expect(m.readDelay == .zero)
        await m.reload()
        #expect(m.readDelay == .milliseconds(250))
    }

    @MainActor @Test func aFilterOnARemovedSetIsDropped() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mirror-activity-\(UUID().uuidString)")
        let kept = BackupSet(name: "Kept", source: URL(fileURLWithPath: "/tmp/kept"))
        try ConfigStore(root: root).saveSets([kept])
        let m = ActivityModel(support: root)
        m.filter.setID = kept.id
        await m.reload()
        #expect(m.filter.setID == kept.id)
        try ConfigStore(root: root).saveSets([])
        await m.reload()
        #expect(m.filter.setID == nil)
    }

    @Test func allSymbolsUsedByTheViewsExist() {
        for name in ["checkmark.circle", "arrow.counterclockwise", "externaldrive.badge.checkmark", "folder", "lock.shield",
                     "bell.badge", "person.badge.key", "plus.rectangle.on.folder", "exclamationmark.triangle", "questionmark.circle",
                     "xmark.octagon", "internaldrive", "clock.arrow.circlepath", "pause.circle", "minus.circle", "key.horizontal",
                     "doc.text.magnifyingglass", "arrow.clockwise", "square.and.arrow.down", "bolt", "gearshape"] {
            #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "\(name)")
        }
    }
}
