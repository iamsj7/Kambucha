import Foundation
import MirrorCore

/// The subcommands Mirror.app spawns for anything touching secrets, so this binary is the only one
/// that ever reads the Keychain. One JSON request on stdin, one JSON response on stdout.
enum SecretCommands {
    static func run(_ subcommand: String) async -> Int32 {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        // Never derive the executable path from argv: resolve it from the enclosing bundle.
        let rclone = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/rclone")
        let service = AgentService(secrets: KeychainStore(), binary: rclone)
        let task = Task { await service.respond(subcommand: subcommand, input: input) }

        // Cancelling the app's call sends SIGTERM. Dying at once would strand rclone and its config,
        // so it cancels the work instead, which stops the child and cleans up.
        signal(SIGTERM, SIG_IGN)
        let terminated = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        terminated.setEventHandler { task.cancel() }
        terminated.resume()

        let output = await task.value
        terminated.cancel()
        FileHandle.standardOutput.write(output)
        return 0
    }
}
