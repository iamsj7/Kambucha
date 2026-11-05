import Testing
import Foundation
@testable import KambuchaCore

@Suite struct RunCommandTests {
    private let id = UUID()

    @Test func noArgumentIsAScheduledPass() {
        #expect(RunCommand.parse([]) == RunCommand())
    }

    @Test func runNowWithAndWithoutSet() {
        #expect(RunCommand.parse(["--run-now"]) == RunCommand(force: true))
        #expect(RunCommand.parse(["--run-now", id.uuidString]) == RunCommand(setID: id, force: true))
    }

    @Test func allowDeletesNeedsSetDestinationAndCount() {
        let d = UUID()
        #expect(RunCommand.parse(["--allow-deletes", id.uuidString, d.uuidString, "240"])
            == RunCommand(setID: id, approvedDeletions: 240, approvedDestination: d, force: true))
        #expect(RunCommand.parse(["--allow-deletes", id.uuidString, "240"]) == nil)   // the old form names no pair
        #expect(RunCommand.parse(["--allow-deletes", id.uuidString, d.uuidString]) == nil)
        #expect(RunCommand.parse(["--allow-deletes", id.uuidString, d.uuidString, "many"]) == nil)
        #expect(RunCommand.parse(["--allow-deletes", id.uuidString, d.uuidString, "-1"]) == nil)
        #expect(RunCommand.parse(["--allow-deletes", "not-a-uuid", d.uuidString, "3"]) == nil)
        #expect(RunCommand.parse(["--allow-deletes", id.uuidString, "not-a-uuid", "3"]) == nil)
        #expect(RunCommand.parse(["--allow-deletes", id.uuidString, d.uuidString, "3", "extra"]) == nil)
        #expect(RunCommand.parse(["--allow-deletes"]) == nil)
    }

    @Test func fullSpeedRidesOnManualRunsOnly() {
        #expect(RunCommand.parse(["--run-now", "--full-speed"]) == RunCommand(force: true, fullSpeed: true))
        #expect(RunCommand.parse(["--full-speed", "--run-now", id.uuidString])
            == RunCommand(setID: id, force: true, fullSpeed: true))
        let d = UUID()
        #expect(RunCommand.parse(["--allow-deletes", id.uuidString, d.uuidString, "2", "--full-speed"])
            == RunCommand(setID: id, approvedDeletions: 2, approvedDestination: d, force: true, fullSpeed: true))
        #expect(RunCommand.parse(["--full-speed"]) == nil)   // a scheduled pass stays at background priority
    }

    @Test func unknownInputIsRefused() {
        #expect(RunCommand.parse(["--nonsense"]) == nil)
        #expect(RunCommand.parse(["--run-now", "not-a-uuid"]) == nil)
        #expect(RunCommand.parse(["--run-now", id.uuidString, "extra"]) == nil)
    }

    @Test func onlyAScheduledPassStaysInTheBackground() {
        #expect(RunCommand().taskPriority == .background)
        #expect(!RunCommand().isFast)
        #expect(RunCommand(force: true).taskPriority == .medium)
        #expect(RunCommand(fullSpeed: true).taskPriority == .medium)
        #expect(RunCommand(force: true, fullSpeed: true).isFast)
    }

    @Test func theBundledPlistLeavesPriorityToTheAgent() throws {
        // A Background job and everything it spawns stay at priority 4, and Nice can't be undone without root.
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/com.shaikjaleel.kambucha.agent.plist")
        let plist = try #require(try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
        #expect(plist["ProcessType"] as? String == "Standard")
        #expect(plist["Nice"] == nil && plist["LowPriorityIO"] == nil)
        #expect(plist["StartOnMount"] as? Bool == true && plist["StartInterval"] as? Int == 1800)
    }

    @Test func raisedRunsGiveRcloneNormalPriorityWhateverTheTask() {
        #expect(RcloneRunner.qos(.background, raised: false) == .background)
        #expect(RcloneRunner.qos(.background, raised: true) == .default)
        #expect(RcloneRunner.qos(.medium, raised: false) == .default)
    }

    @Test func fullSpeedRaisesTransfersAndCheckers() {
        let ctx = RcloneContext(configPath: "/dev/null", environment: [:])
        let u = URL(fileURLWithPath: "/tmp/x")
        func args(_ fast: Bool) -> [String] {
            RcloneCommand.arguments(SyncRequest(source: u, destination: "/d", backupDir: "/b", filterFile: u, logFile: u,
                                                mode: .copyOnly, profile: .profile(for: Destination(name: "i", kind: .iCloudFolder)),
                                                context: ctx, fullSpeed: fast))
        }
        func value(_ flag: String, _ a: [String]) -> String? { a.firstIndex(of: flag).map { a[$0 + 1] } }
        #expect(value("--transfers", args(false)) == "2" && value("--checkers", args(false)) == "2")
        #expect(value("--transfers", args(true)) == "4" && value("--checkers", args(true)) == "8")
    }
}

@Suite struct FilterMatcherTests {
    @Test func anythingUnderAnExcludedFolderIsExcluded() {
        let m = FilterMatcher(lines: ["- node_modules/**", "- /app/build/**"])
        #expect(m.isExcluded("app/node_modules/x/y.js"))
        #expect(m.isExcluded("node_modules/a"))
        #expect(m.isExcluded("app/build/out/z.o"))
        #expect(!m.isExcluded("other/build/z.o"))    // anchored rule
        #expect(!m.isExcluded("app/src/main.swift"))
    }

    @Test func firstMatchWins() {
        let m = FilterMatcher(lines: ["+ build/keep.txt", "- build/**"])
        #expect(!m.isExcluded("a/build/keep.txt"))
        #expect(m.isExcluded("a/build/other.txt"))
    }

    @Test func starStaysInsideOneFolderAndNamesMatchWhole() {
        let m = FilterMatcher(lines: ["- *.pem", "- /a*/x", "- .DS_Store"])
        #expect(m.isExcluded("p/q/key.pem"))
        #expect(m.isExcluded("abc/x"))
        #expect(!m.isExcluded("a/b/x"))
        #expect(m.isExcluded("p/.DS_Store"))
        #expect(!m.isExcluded("p/not.DS_Store"))
    }

    @Test func escapedAndBracedPatterns() {
        let m = FilterMatcher(lines: [#"- /a\[1\]/**"#, "- *.{log,tmp}"])
        #expect(m.isExcluded("a[1]/f"))
        #expect(m.isExcluded("x/y.log") && m.isExcluded("y.tmp"))
        #expect(!m.isExcluded("y.txt"))
    }

    @Test func aFolderRuleWithATrailingSlashCoversItsContents() {
        #expect(FilterMatcher(lines: ["- cache/"]).isExcluded("a/cache/f"))
    }

    @Test func anUnreadablePatternExcludesNothing() {
        #expect(!FilterMatcher(lines: ["- [", "- a(b"]).isExcluded("["))
    }
}

private struct Caller: AgentTrust {
    let trusted: Bool
    func verifyCaller() throws { if !trusted { throw AgentFailure.untrustedCaller } }
    func verifyHelper(at url: URL) throws {}
}

@Suite struct RunRequestTrustTests {
    @Test func aScheduledRunNeedsNoCaller() throws {
        #expect(AgentExit.allows(try #require(RunCommand.parse([])), trust: Caller(trusted: false)))
    }

    @Test func aRequestOnlyComesFromTheApp() throws {
        let set = UUID().uuidString, destination = UUID().uuidString
        for arguments in [["--run-now"], ["--run-now", set], ["--allow-deletes", set, destination, "999999"]] {
            let command = try #require(RunCommand.parse(arguments))
            #expect(!AgentExit.allows(command, trust: Caller(trusted: false)))
            #expect(AgentExit.allows(command, trust: Caller(trusted: true)))
        }
    }
}
