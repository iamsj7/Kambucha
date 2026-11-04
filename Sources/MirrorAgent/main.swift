import Foundation
import MirrorCore

let args = CommandLine.arguments
if args.count == 2, AgentRequest.subcommands.contains(args[1]) || AgentWire.subcommands.contains(args[1]) {
    exit(await SecretCommands.run(args[1]))
}
// Every launchd run starts by recording what this process can read. Only a launchd run, as that's the access that counts.
if AgentAccess.reportsAccess(arguments: Array(args.dropFirst())) { recordAccess() }
#if MIRROR_PROBES
if args.count > 1, args[1] == "--probe" {
    await Probe.run()
    exit(0)
} else if args.count > 2, args[1] == "--probe-events" {
    Probe.events(dir: args[2], since: args.count > 3 ? UInt64(args[3]) : nil)
    exit(0)
} else if args.count > 2, args[1] == "--probe-uploaded" {
    exit(Probe.uploaded(dir: args[2], maxSeconds: args.count > 3 ? Double(args[3]) ?? 480 : 480))
} else if args.count > 2, args[1] == "--probe-blocks" {
    exit(Probe.blocks(path: args[2]))
} else if args.count > 2, args[1] == "--probe-ubiq" {
    Probe.ubiq(paths: Array(args[2...]))
    exit(0)
}
#endif
guard let command = RunCommand.parse(Array(args.dropFirst())) else {
    FileHandle.standardError.write(Data("usage: MirrorAgent [--run-now [set-id] | --allow-deletes <set-id> <destination-id> <count>] [--full-speed]\n".utf8))
    exit(64)
}
exit(await BackupRun.run(command))
