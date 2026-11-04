import SwiftUI
import AppKit
import ServiceManagement
@preconcurrency import UserNotifications
import MirrorCore

enum NotificationAccess: Equatable { case notDetermined, allowed, denied }

/// Everything onboarding reads from or asks of macOS, so the steps can be tested with a fake.
@MainActor
protocol OnboardingSystem {
    /// Reads the agent's last report (`access.json`). False means not confirmed.
    func fullDiskAccessConfirmed() async -> Bool
    /// Asks launchd to start the agent and waits (bounded) for its report.
    func checkFullDiskAccessNow() async -> AccessConfirmation.Outcome
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
    func fullDiskAccessConfirmed() async -> Bool { AgentAccess.isConfirmed(support: MirrorPaths.support) }
    func checkFullDiskAccessNow() async -> AccessConfirmation.Outcome { await AccessConfirmation.confirm(support: MirrorPaths.support) }
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

/// Runs a child process with a hard time limit. Returns the exit code, or nil if it couldn't start or
/// had to be killed. Never blocks the caller's thread beyond polling, so it can't hang `refresh()`.
enum BoundedProcess {
    static func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval) async -> Int32? {
        await Task.detached {
            let p = Process()
            p.executableURL = executable
            p.arguments = arguments
            p.standardInput = FileHandle.nullDevice; p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { return nil }
            let deadline = Date().addingTimeInterval(timeout)
            while p.isRunning {
                if Date() >= deadline {
                    p.terminate()
                    try? await Task.sleep(for: .milliseconds(200))
                    if p.isRunning { kill(p.processIdentifier, SIGKILL) }
                    return nil
                }
                try? await Task.sleep(for: .milliseconds(25))
            }
            return p.terminationStatus
        }.value
    }
}

extension BoundedProcess {
    /// Like `run`, but also returns what the process wrote to stdout (via a temp file, so a full pipe can't stall it).
    static func output(_ executable: URL, _ arguments: [String], timeout: TimeInterval) async -> (code: Int32, output: Data)? {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("mirror-out-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              let handle = try? FileHandle(forWritingTo: file) else { return nil }
        defer { try? handle.close(); try? FileManager.default.removeItem(at: file) }
        let code: Int32? = await Task.detached {
            let p = Process()
            p.executableURL = executable
            p.arguments = arguments
            p.standardInput = FileHandle.nullDevice; p.standardOutput = handle; p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { return nil }
            let deadline = Date().addingTimeInterval(timeout)
            while p.isRunning {
                if Date() >= deadline {
                    p.terminate()
                    try? await Task.sleep(for: .milliseconds(200))
                    if p.isRunning { kill(p.processIdentifier, SIGKILL) }
                    return nil
                }
                try? await Task.sleep(for: .milliseconds(25))
            }
            return p.terminationStatus
        }.value
        guard let code else { return nil }
        return (code, (try? Data(contentsOf: file)) ?? Data())
    }
}

/// Proves the launchd agent's own Full Disk Access. A child of this app can inherit the app's grant,
/// so instead launchd is asked to start the agent, which writes `access.json` at the start of each
/// run (`AgentAccess.writeReport`). Only a fresh, passing report counts. Kicking starts a real run,
/// so callers do it only on the owner's request and on the first onboarding check.
enum AccessConfirmation {
    enum Outcome: Equatable { case confirmed, notConfirmed, kickFailed }

    static func kickstartArguments(uid: uid_t) -> [String] { ["kickstart", "gui/\(uid)/\(MirrorCore.agentLabel)"] }

    /// True when launchctl accepted the request. It fails at once if the agent isn't registered.
    static func launchctlKick(uid: uid_t = getuid(), timeout: TimeInterval = 5) async -> Bool {
        await BoundedProcess.run(URL(fileURLWithPath: "/bin/launchctl"), kickstartArguments(uid: uid), timeout: timeout) == 0
    }

    /// Kicks, then waits up to `timeout` seconds (15 in the app) for a report written after the kick.
    static func confirm(support: URL, timeout: TimeInterval = 15,
                        kick: () async -> Bool = { await launchctlKick() }) async -> Outcome {
        let started = Date()
        guard await kick() else { return .kickFailed }
        let deadline = started.addingTimeInterval(timeout)
        while true {
            if AgentAccess.isConfirmed(support: support, notBefore: started.addingTimeInterval(-1)) { return .confirmed }
            if Date() >= deadline { return .notConfirmed }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }
}

enum OnboardingStep: Int, CaseIterable, Identifiable {
    case agent, fullDiskAccess, notifications, firstSet
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
    private(set) var isChecking = false
    private(set) var hasRefreshed = false
    private(set) var checkFailed = false
    private(set) var kickFailed = false
    @ObservationIgnored private var firstCheckDone = false

    @ObservationIgnored private let system: any OnboardingSystem
    @ObservationIgnored private let store: ConfigStore
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let pathGuard: PathGuard

    init(system: any OnboardingSystem = LiveOnboardingSystem(), store: ConfigStore = ConfigStore(root: MirrorPaths.support),
         settings: SettingsStore = SettingsStore(root: MirrorPaths.support),
         pathGuard: PathGuard = PathGuard(iCloudDrive: MirrorPaths.iCloudDrive, backupRoot: MirrorPaths.backupRoot)) {
        self.system = system; self.store = store; self.settings = settings; self.pathGuard = pathGuard
    }

    func isDone(_ s: OnboardingStep) -> Bool { done.contains(s) }
    var isComplete: Bool { done.count == OnboardingStep.allCases.count }
    /// The first step still to do, or nil when everything is.
    var current: OnboardingStep? { OnboardingStep.allCases.first { !done.contains($0) } }

    /// Re-reads every grant. A grant revoked later brings onboarding back.
    func refresh() async {
        var d: Set<OnboardingStep> = []
        if await system.fullDiskAccessConfirmed() { d.insert(.fullDiskAccess) }
        let status = system.agentStatus()
        agentNeedsApproval = status == .requiresApproval
        if status == .enabled { d.insert(.agent) }
        let access = await system.notificationAccess()
        notificationsDenied = access == .denied
        if access == .allowed { d.insert(.notifications) }
        if let sets = try? store.loadSets(), !sets.isEmpty { d.insert(.firstSet) }
        done = d
        hasRefreshed = true
    }

    /// Asks launchd to start the agent and waits up to 15 seconds for its access report. This starts a
    /// real run, so it is only called from "Check Again" and the first check. Needs the agent registered.
    func checkAccessNow() async {
        guard !isChecking else { return }
        guard system.agentStatus() == .enabled else {
            message = "Turn on background backups first. Mirror checks Full Disk Access through that helper."
            return
        }
        isChecking = true
        let outcome = await system.checkFullDiskAccessNow()
        isChecking = false
        checkFailed = outcome != .confirmed
        kickFailed = outcome == .kickFailed
        switch outcome {
        case .confirmed: done.insert(.fullDiskAccess); message = nil
        case .notConfirmed: done.remove(.fullDiskAccess)
        case .kickFailed:
            done.remove(.fullDiskAccess)
            message = "Mirror couldn't start its background helper. Check that it is turned on in Login Items, then try again."
        }
    }

    /// The one automatic check, once the helper is on and Full Disk Access isn't confirmed yet.
    func firstCheckIfNeeded() async {
        guard !firstCheckDone, system.agentStatus() == .enabled, !isDone(.fullDiskAccess) else { return }
        firstCheckDone = true
        await checkAccessNow()
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
            var set = BackupSet(name: name, source: folder, destinationIDs: [icloud.id])
            set.archiveDays = (try? settings.load().defaultRetentionDays) ?? AppSettings().defaultRetentionDays
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
                await model.firstCheckIfNeeded()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .onChange(of: scenePhase) { if scenePhase == .active { Task { await model.refresh() } } }   // reads only; never kicks
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
            (model.checkFailed ? "Not confirmed yet. " : "") + "This comes after turning on background backups, because the background helper is what needs the access and Mirror checks through it. Click the button, switch on Mirror in the list, then choose Check Again."
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
            HStack {
                Button("Open Full Disk Access Settings") { model.openFullDiskAccess() }.buttonStyle(.borderedProminent)
                Button("Check Again") { Task { await model.checkAccessNow() } }.disabled(model.isChecking)
                if model.isChecking { ProgressView().controlSize(.small).accessibilityLabel("Checking") }
            }
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
