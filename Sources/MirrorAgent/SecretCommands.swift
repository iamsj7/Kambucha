import Foundation
import MirrorCore
import MirrorSecrets

/// The subcommands Mirror.app spawns for anything touching secrets, so this binary is the only one
/// that ever reads the Keychain. One JSON request on stdin, one JSON response on stdout.
enum SecretCommands {
    static func run(_ subcommand: String) async -> Int32 {
        // First of all: cancelling the app's call sends SIGTERM, and dying then would strand rclone
        // and its config. Cancelling the work instead stops the child and cleans up.
        let cancel = PendingCancel()
        signal(SIGTERM, SIG_IGN)
        let terminated = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        terminated.setEventHandler { cancel.fire() }
        terminated.resume()

        // The environment comes from whoever spawned us, so nothing below may depend on it.
        MirrorPaths.scrubEnvironment()

        // Never derive the executable path from argv: resolve it from the enclosing bundle.
        let rclone = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/rclone")
        let service = AgentService(secrets: KeychainStore(), binary: rclone, trust: SignedCodeTrust(),
                                   presence: DevicePresence(), support: MirrorPaths.support, notifier: UNNotifier())
        let task = Task {
            await service.respond(subcommand: subcommand, input: { FileHandle.standardInput.readDataToEndOfFile() })
        }
        cancel.attach { task.cancel() }

        let output = await task.value
        terminated.cancel()
        FileHandle.standardOutput.write(output)
        return 0
    }
}

/// Holds a SIGTERM that arrives before the work has started.
private final class PendingCancel: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private var action: (@Sendable () -> Void)?

    func fire() {
        let run: (@Sendable () -> Void)? = lock.withLock { fired = true; return action }
        run?()
    }

    func attach(_ newAction: @escaping @Sendable () -> Void) {
        let alreadyFired = lock.withLock { action = newAction; return fired }
        if alreadyFired { newAction() }
    }
}
