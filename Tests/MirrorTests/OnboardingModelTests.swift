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
    func fullDiskAccessGranted() -> Bool { fda }
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
        return (OnboardingModel(system: system, store: ConfigStore(root: root), pathGuard: guardrail), root)
    }

    @Test func staysUntilEveryStepIsDone() async throws {
        let sys = FakeSystem()
        let (m, root) = make(sys)
        await m.refresh()
        #expect(!m.isComplete && m.current == .fullDiskAccess)
        sys.fda = true; await m.refresh()
        #expect(m.current == .agent)
        m.enableAgent(); await m.refresh()
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
}
