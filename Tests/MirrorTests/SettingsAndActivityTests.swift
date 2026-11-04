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

    @Test func allSymbolsUsedByTheViewsExist() {
        for name in ["checkmark.circle", "arrow.counterclockwise", "externaldrive.badge.checkmark", "folder", "lock.shield",
                     "bell.badge", "person.badge.key", "plus.rectangle.on.folder", "exclamationmark.triangle", "questionmark.circle",
                     "xmark.octagon", "internaldrive", "clock.arrow.circlepath", "pause.circle", "minus.circle", "key.horizontal",
                     "doc.text.magnifyingglass", "arrow.clockwise", "square.and.arrow.down", "bolt", "gearshape"] {
            #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "\(name)")
        }
    }
}
