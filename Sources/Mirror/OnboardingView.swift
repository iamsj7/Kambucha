import SwiftUI
import AppKit
import ServiceManagement
@preconcurrency import UserNotifications
import MirrorCore

enum NotificationAccess: Equatable { case notDetermined, allowed, denied }

/// Everything onboarding reads from or asks of macOS, so the steps can be tested with a fake.
@MainActor
protocol OnboardingSystem {
    func fullDiskAccessGranted() -> Bool
    func agentStatus() -> SMAppService.Status
    func enableAgent() throws
    func notificationAccess() async -> NotificationAccess
    func requestNotifications() async -> NotificationAccess
    func openFullDiskAccessPane()
    func openLoginItemsSettings()
    func openNotificationSettings()
}

@MainActor
struct LiveOnboardingSystem: OnboardingSystem {
    /// There is no API for this grant. Opening the system TCC database fails with EPERM unless the app
    /// has Full Disk Access, and the file exists on every Mac. Read-only; nothing is read from it.
    func fullDiskAccessGranted() -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for path in ["/Library/Application Support/com.apple.TCC/TCC.db", "\(home)/Library/Application Support/com.apple.TCC/TCC.db"] {
            let fd = Darwin.open(path, O_RDONLY)
            if fd >= 0 { Darwin.close(fd); return true }
            if errno == EPERM || errno == EACCES { return false }
        }
        return false
    }
    func agentStatus() -> SMAppService.Status { AgentRegistration.status() }
    func enableAgent() throws { try AgentRegistration.enable() }

    func notificationAccess() async -> NotificationAccess {
        guard Bundle.main.bundleIdentifier != nil else { return .notDetermined }   // the center traps without a bundle
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: return .allowed
        case .denied: return .denied
        default: return .notDetermined
        }
    }
    func requestNotifications() async -> NotificationAccess {
        guard Bundle.main.bundleIdentifier != nil else { return .notDetermined }
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        return await notificationAccess()
    }

    func openFullDiskAccessPane() { open("x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") }
    func openLoginItemsSettings() { AgentRegistration.openLoginItemsSettings() }
    func openNotificationSettings() { open("x-apple.systempreferences:com.apple.Notifications-Settings.extension") }
    private func open(_ s: String) { if let u = URL(string: s) { NSWorkspace.shared.open(u) } }
}

enum OnboardingStep: Int, CaseIterable, Identifiable {
    case fullDiskAccess, agent, notifications, firstSet
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .fullDiskAccess: "Allow Full Disk Access"
        case .agent: "Turn On Background Backups"
        case .notifications: "Allow Notifications"
        case .firstSet: "Add Your First Set"
        }
    }
    var symbol: String {
        switch self {
        case .fullDiskAccess: "lock.shield"
        case .agent: "gearshape"
        case .notifications: "bell.badge"
        case .firstSet: "plus.rectangle.on.folder"
        }
    }
}

@MainActor @Observable
final class OnboardingModel {
    private(set) var done: Set<OnboardingStep> = []
    private(set) var agentNeedsApproval = false
    private(set) var notificationsDenied = false
    private(set) var message: String?

    @ObservationIgnored private let system: any OnboardingSystem
    @ObservationIgnored private let store: ConfigStore
    @ObservationIgnored private let pathGuard: PathGuard

    init(system: any OnboardingSystem = LiveOnboardingSystem(), store: ConfigStore = ConfigStore(root: MirrorPaths.support),
         pathGuard: PathGuard = PathGuard(iCloudDrive: MirrorPaths.iCloudDrive, backupRoot: MirrorPaths.backupRoot)) {
        self.system = system; self.store = store; self.pathGuard = pathGuard
    }

    func isDone(_ s: OnboardingStep) -> Bool { done.contains(s) }
    var isComplete: Bool { done.count == OnboardingStep.allCases.count }
    /// The first step still to do, or nil when everything is.
    var current: OnboardingStep? { OnboardingStep.allCases.first { !done.contains($0) } }

    /// Re-reads every grant. A grant revoked later brings onboarding back.
    func refresh() async {
        var d: Set<OnboardingStep> = []
        if system.fullDiskAccessGranted() { d.insert(.fullDiskAccess) }
        let status = system.agentStatus()
        agentNeedsApproval = status == .requiresApproval
        if status == .enabled { d.insert(.agent) }
        let access = await system.notificationAccess()
        notificationsDenied = access == .denied
        if access == .allowed { d.insert(.notifications) }
        if let sets = try? store.loadSets(), !sets.isEmpty { d.insert(.firstSet) }
        done = d
    }

    func openFullDiskAccess() { system.openFullDiskAccessPane() }
    func openLoginItems() { system.openLoginItemsSettings() }
    func openNotificationSettings() { system.openNotificationSettings() }

    func enableAgent() {
        do { try system.enableAgent(); message = nil }
        catch { message = "Mirror couldn't turn on background backups. \(error.localizedDescription)" }
        let status = system.agentStatus()
        agentNeedsApproval = status == .requiresApproval
        if status == .enabled { done.insert(.agent) }
    }

    func allowNotifications() async {
        let access = await system.requestNotifications()
        notificationsDenied = access == .denied
        if access == .allowed { done.insert(.notifications) }
    }

    /// Adds a set that backs up to iCloud Drive, the destination that needs no sign-in.
    func addFirstSet(folder: URL) {
        do {
            var destinations = try store.loadDestinations()
            let icloud = destinations.first { $0.kind == .iCloudFolder } ?? Destination(name: "iCloud Drive", kind: .iCloudFolder)
            let name = PathGuard.sanitizedComponent(folder.lastPathComponent)
            let set = BackupSet(name: name, source: folder, destinationIDs: [icloud.id])
            let existing = try store.loadSets()
            try pathGuard.validateNewSet(set, existing: existing)
            if !destinations.contains(where: { $0.id == icloud.id }) { destinations.append(icloud); try store.saveDestinations(destinations) }
            try store.saveSets(existing + [set])
            message = nil
            done.insert(.firstSet)
        } catch let e as GuardFailure {
            message = Self.explain(e)
        } catch {
            message = "Mirror couldn't add this folder."
        }
    }

    static func explain(_ e: GuardFailure) -> String {
        switch e {
        case .sourceMissing: "That folder no longer exists."
        case .sourceUnreadable: "Mirror can't read that folder. Check Full Disk Access first."
        case .sourceInsideICloud: "That folder is already in iCloud Drive. Choose one on this Mac."
        case .sourceContainsBackupRoot: "That folder contains the backup itself. Choose a different one."
        case .setsOverlap(let n): "That folder overlaps the set \(n)."
        case .setNameTaken(let n): "A set called \(n) already exists."
        case .iCloudUnavailable: "iCloud Drive isn't available on this Mac."
        default: "Mirror can't back up that folder."
        }
    }
}

struct OnboardingView: View {
    @Bindable var model: OnboardingModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Welcome to Mirror").font(.largeTitle).bold()
                Text("Four steps, and your files are backed up. Mirror stays here until each one is done.")
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: 0) {
                ForEach(OnboardingStep.allCases) { step in
                    StepRow(step: step, model: model)
                    if step != OnboardingStep.allCases.last { Divider() }
                }
            }
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
            if let m = model.message {
                Label(m, systemImage: "exclamationmark.triangle").font(.callout)
            }
            if model.isComplete {
                Label("All set. Mirror is ready.", systemImage: "checkmark.circle").font(.headline)
            }
        }
        .padding(24)
        .frame(minWidth: 520, idealWidth: 560)
        .task {
            // Grants happen in System Settings, so look again once a second while this is open.
            while !Task.isCancelled {
                await model.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .onChange(of: scenePhase) { Task { await model.refresh() } }
    }
}

private struct StepRow: View {
    let step: OnboardingStep
    let model: OnboardingModel

    var body: some View {
        let done = model.isDone(step)
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: done ? "checkmark.circle" : step.symbol)
                .font(.title2).frame(width: 30).foregroundStyle(done ? .secondary : .primary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(step.title).font(.headline)
                Text(done ? doneText : explanation).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if !done && model.current == step { action }
            }
            Spacer(minLength: 0)
            if done { Text("Done").font(.callout).foregroundStyle(.secondary) }
        }
        .padding(14)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(step.title), \(done ? "done" : "not done")")
    }

    private var explanation: String {
        switch step {
        case .fullDiskAccess:
            "macOS protects folders like Documents and Desktop. Mirror needs Full Disk Access to back them up. Click the button, then switch on Mirror in the list."
        case .agent:
            model.agentNeedsApproval
                ? "macOS needs your approval. Switch on Mirror in Login Items, then come back."
                : "A small background helper runs backups on a schedule, even when Mirror is closed."
        case .notifications:
            model.notificationsDenied
                ? "Notifications are off for Mirror. Switch them on in System Settings so you hear about problems."
                : "Mirror tells you when something needs attention, such as held deletions or a failed check."
        case .firstSet:
            "Choose a folder to back up. It is copied to iCloud Drive and checked after every run."
        }
    }

    private var doneText: String {
        switch step {
        case .fullDiskAccess: "Mirror can read your folders."
        case .agent: "Backups will run in the background."
        case .notifications: "You'll hear about problems."
        case .firstSet: "Your first set is ready."
        }
    }

    @ViewBuilder private var action: some View {
        switch step {
        case .fullDiskAccess:
            Button("Open Full Disk Access Settings") { model.openFullDiskAccess() }.buttonStyle(.borderedProminent)
        case .agent:
            if model.agentNeedsApproval {
                Button("Open Login Items Settings") { model.openLoginItems() }.buttonStyle(.borderedProminent)
            } else {
                Button("Turn On") { model.enableAgent() }.buttonStyle(.borderedProminent)
            }
        case .notifications:
            if model.notificationsDenied {
                Button("Open Notification Settings") { model.openNotificationSettings() }.buttonStyle(.borderedProminent)
            } else {
                Button("Allow Notifications") { Task { await model.allowNotifications() } }.buttonStyle(.borderedProminent)
            }
        case .firstSet:
            Button("Choose Folder…") { chooseFolder() }.buttonStyle(.borderedProminent)
        }
    }

    @MainActor private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.prompt = "Back Up This Folder"
        panel.message = "Choose a folder on this Mac to back up."
        if panel.runModal() == .OK, let url = panel.url { model.addFirstSet(folder: url) }
    }
}
