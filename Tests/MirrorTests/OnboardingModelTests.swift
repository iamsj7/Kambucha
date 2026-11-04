import Testing
import Foundation
import ServiceManagement
import MirrorCore
@testable import Mirror

@MainActor
private final class FakeSystem: OnboardingSystem {
    var fda = false
    var agent: SMAppService.Status = .notRegistered
    var notes: NotificationAccess = .notDetermined
    var enableError: (any Error)?
    func fullDiskAccessConfirmed() async -> Bool { fda }
    var report: AccessReport?
    func accessReport() -> AccessReport? { report }
    var checked = 0
    var kickOutcome: AccessConfirmation.Outcome?
    func checkFullDiskAccessNow() async -> AccessConfirmation.Outcome { checked += 1; return kickOutcome ?? (fda ? .confirmed : .notConfirmed) }
    func agentStatus() -> SMAppService.Status { agent }
    func enableAgent() throws { if let enableError { throw enableError }; agent = .enabled }
    func notificationAccess() async -> NotificationAccess { notes }
    func requestNotifications() async -> NotificationAccess { notes = .allowed; return notes }
    private(set) var opened: [String] = []
    func openFullDiskAccessPane() { opened.append("fda") }
    func openLoginItemsSettings() { opened.append("login") }
    func openNotificationSettings() { opened.append("notes") }
}

@MainActor
struct OnboardingModelTests {
    fileprivate func make(_ system: FakeSystem) -> (OnboardingModel, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mirror-test-\(UUID().uuidString)")
        let icloud = root.appendingPathComponent("iCloud")
        try? FileManager.default.createDirectory(at: icloud, withIntermediateDirectories: true)
        let guardrail = PathGuard(iCloudDrive: icloud, backupRoot: MirrorPaths.backupRoot(iCloudDrive: icloud))
        return (OnboardingModel(system: system, store: ConfigStore(root: root), settings: SettingsStore(root: root), pathGuard: guardrail), root)
    }

    @Test func staysUntilEveryStepIsDone() async throws {
        let sys = FakeSystem()
        let (m, root) = make(sys)
        await m.refresh()
        #expect(!m.isComplete && m.current == .agent)
        m.enableAgent(); await m.refresh()
        #expect(m.current == .fullDiskAccess)
        sys.fda = true; await m.refresh()
        #expect(m.current == .notifications)
        await m.allowNotifications()
        #expect(m.current == .firstSet && !m.isComplete)
        let folder = root.appendingPathComponent("Projects")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        m.addFirstSet(folder: folder)
        await m.refresh()
        #expect(m.isComplete && m.current == nil)
    }

    @Test func detectsGrantsMadeInSystemSettings() async {
        let sys = FakeSystem()
        let (m, _) = make(sys)
        await m.refresh()
        #expect(!m.isDone(.fullDiskAccess))
        sys.fda = true
        await m.refresh()
        #expect(m.isDone(.fullDiskAccess))
        sys.fda = false   // revoked later: onboarding comes back
        await m.refresh()
        #expect(!m.isDone(.fullDiskAccess))
    }

    @Test func checkNowKicksTheAgentAndConfirms() async {
        let sys = FakeSystem(); sys.agent = .enabled
        let (m, _) = make(sys)
        await m.checkAccessNow()
        #expect(sys.checked == 1 && !m.isDone(.fullDiskAccess) && !m.isChecking)
        sys.fda = true
        await m.checkAccessNow()
        #expect(m.isDone(.fullDiskAccess))
    }

    @Test func checkNowNeedsTheAgentFirstAndNeverKicksWithoutIt() async {
        let sys = FakeSystem()
        let (m, _) = make(sys)
        await m.checkAccessNow()
        #expect(sys.checked == 0 && m.message != nil)
    }

    @Test func aFailedKickIsAClearMessage() async {
        let sys = FakeSystem(); sys.agent = .enabled; sys.kickOutcome = .kickFailed
        let (m, _) = make(sys)
        await m.checkAccessNow()
        #expect(m.message != nil && m.kickFailed && !m.isChecking)
    }

    @Test func theFirstCheckHappensOnceOnly() async {
        let sys = FakeSystem(); sys.agent = .enabled
        let (m, _) = make(sys)
        await m.refresh()
        await m.firstCheckIfNeeded()
        await m.firstCheckIfNeeded()
        await m.refresh()
        #expect(sys.checked == 1)
    }

    @Test func readingFoldersWithoutFullDiskAccessIsSaidApart() async {
        let sys = FakeSystem(); sys.agent = .enabled
        sys.report = AccessReport(folders: true, fullDiskAccess: false, checkedAt: Date())
        let (m, _) = make(sys)
        await m.refresh()
        #expect(!m.isDone(.fullDiskAccess))
        #expect(m.accessIsPartial)
        sys.report = AccessReport(folders: false, fullDiskAccess: false, checkedAt: Date())
        await m.refresh()
        #expect(!m.accessIsPartial)
    }

    @Test func agentNeedingApprovalIsNotDone() async {
        let sys = FakeSystem(); sys.agent = .requiresApproval
        let (m, _) = make(sys)
        await m.refresh()
        #expect(!m.isDone(.agent) && m.agentNeedsApproval)
    }

    @Test func registrationErrorIsShown() async {
        let sys = FakeSystem(); sys.enableError = URLError(.unknown)
        let (m, _) = make(sys)
        m.enableAgent()
        #expect(m.message != nil)
    }

    @Test func deniedNotificationsStayNotDone() async {
        let sys = FakeSystem(); sys.notes = .denied
        let (m, _) = make(sys)
        await m.refresh()
        #expect(!m.isDone(.notifications) && m.notificationsDenied)
    }

    @Test func firstSetUsesICloudAndRefusesBadFolders() async throws {
        let sys = FakeSystem()
        let (m, root) = make(sys)
        m.addFirstSet(folder: root.appendingPathComponent("missing"))
        #expect(m.message != nil)
        let folder = root.appendingPathComponent("Docs")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        m.addFirstSet(folder: folder)
        let store = ConfigStore(root: root)
        let sets = try store.loadSets(), dests = try store.loadDestinations()
        #expect(sets.count == 1 && sets[0].name == "Docs")
        #expect(dests.count == 1 && dests[0].kind == .iCloudFolder && sets[0].destinationIDs == [dests[0].id])
    }

    @Test func firstSetUsesTheDefaultRetention() throws {
        let sys = FakeSystem()
        let (m, root) = make(sys)
        var s = AppSettings(); s.defaultRetentionDays = 90
        try SettingsStore(root: root).save(s)
        let folder = root.appendingPathComponent("Docs")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        m.addFirstSet(folder: folder)
        #expect(try ConfigStore(root: root).loadSets().first?.archiveDays == 90)
    }

    @Test func firstSetTurnsOnTheStacksItFinds() throws {
        let sys = FakeSystem()
        let (m, root) = make(sys)
        let folder = root.appendingPathComponent("Docs")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("site"), withIntermediateDirectories: true)
        try "{}".write(to: folder.appendingPathComponent("site/package.json"), atomically: true, encoding: .utf8)
        m.addFirstSet(folder: folder)
        #expect(try ConfigStore(root: root).loadSets().first?.presets.contains("node") == true)
    }

    @Test func firstSetGoesStraightToItsPreview() throws {
        let sys = FakeSystem()
        let (m, root) = make(sys)
        m.addFirstSet(folder: root.appendingPathComponent("missing"))
        #expect(m.setAwaitingPreview == nil)
        let folder = root.appendingPathComponent("Docs")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        m.addFirstSet(folder: folder)
        let set = try #require(try ConfigStore(root: root).loadSets().first)
        #expect(m.setAwaitingPreview == set.id)
        #expect(!set.isPreviewAccepted)
        m.previewShown()
        #expect(m.setAwaitingPreview == nil)
    }
}
