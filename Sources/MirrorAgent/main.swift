import Foundation
import MirrorCore

let args = CommandLine.arguments
if args.count > 1, args[1] == "--probe" {
    await Probe.run()
} else if args.count > 2, args[1] == "--probe-events" {
    Probe.events(dir: args[2], since: args.count > 3 ? UInt64(args[3]) : nil)
} else if args.count > 2, args[1] == "--probe-uploaded" {
    exit(Probe.uploaded(dir: args[2], maxSeconds: args.count > 3 ? Double(args[3]) ?? 480 : 480))
} else {
    print("MirrorAgent \(MirrorCore.agentLabel)")
}
