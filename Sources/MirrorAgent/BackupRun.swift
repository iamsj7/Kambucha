import Foundation
import MirrorCore
import os

/// Builds the real graph and hands over to `RunCoordinator`. All run logic lives there, so the engine
/// can move into the app if Gate 1 needs it to.
enum BackupRun {
    private static let log = Logger(subsystem: MirrorCore.bundleID, category: "BackupRun")

    static func run(_ command: RunCommand) async -> Int32 {
        let places = Places()
        let presets: [Preset]
        do { presets = try PresetCatalog.all() } catch {
            // Without them junk would upload and ambiguous folders change meaning. Better to stop.
            log.error("cannot load presets")
            return 1
        }
        // Never derive the executable path from argv: resolve it from the enclosing bundle.
        let binary = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/rclone")
        let rclone = RcloneRunner(binary: binary)
        let secrets = KeychainStore()
        let work = RcloneSession.defaultWorkDir
        let coordinator = RunCoordinator(
            store: ConfigStore(root: places.support), records: RunRecordStore(root: places.support),
            problems: ProblemCenter(root: places.support, notifier: UNNotifier()), rclone: rclone,
            feed: FSEventsFeed(), verifier: Verifier(rclone: rclone, auditor: ICloudAuditor()),
            guard: PathGuard(iCloudDrive: places.iCloudDrive, backupRoot: places.backupRoot),
            detector: StackDetector(presets: presets), filters: FilterBuilder(presets: presets), clock: { Date() },
            sessions: { RcloneSession(destination: $0, secrets: secrets, binary: binary, workDir: work) },
            remote: RcloneRemoteFiles(binary: binary),
            paths: RunPaths(support: places.support, logs: places.logs, work: work))

        if command.fullSpeed { AgentPriority.raiseToNormal() }
        // launchd sends SIGTERM at logout. Dying at once would strand rclone, any sign-in config and
        // the pid file, so it cancels the work instead, which stops the child and cleans up.
        signal(SIGTERM, SIG_IGN)
        let task = Task(priority: command.taskPriority) { await coordinator.runAll(command: command) }
        let terminated = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        terminated.setEventHandler { task.cancel() }
        terminated.resume()
        await task.value
        terminated.cancel()
        return 0
    }

    private struct Places {
        var support = MirrorPaths.support
        var logs = MirrorPaths.logs
        var iCloudDrive = MirrorPaths.iCloudDrive
        var backupRoot = MirrorPaths.backupRoot

        init() {
            #if MIRROR_PROBES
            // Proof builds only: lets the end-to-end run use a throwaway root and support folder.
            let env = ProcessInfo.processInfo.environment
            if let home = env["MIRROR_PROOF_HOME"] {
                let url = URL(fileURLWithPath: home)
                support = MirrorPaths.support(home: url)
                logs = MirrorPaths.logs(home: url)
            }
            if let name = env["MIRROR_PROOF_ROOT"] { backupRoot = iCloudDrive.appendingPathComponent(name, isDirectory: true) }
            #endif
        }
    }
}
