import Testing
import Foundation
@testable import KambuchaCore

private func ctx(_ config: String = "/dev/null") -> RcloneContext {
    RcloneContext(configPath: config, environment: [:])
}

private func request(kind: DestinationKind = .iCloudFolder, mode: SyncMode = .mirror(maxDelete: 50),
                     encrypted: Bool = false, dryRun: Bool = false,
                     context: RcloneContext? = nil) -> SyncRequest {
    let profile = DestinationProfile.profile(for: Destination(name: "d", kind: kind, encrypted: encrypted))
    return SyncRequest(source: URL(fileURLWithPath: "/src/dir"), destination: "/dst/dir", backupDir: "/arch/ts",
                       filterFile: URL(fileURLWithPath: "/tmp/f.filter"), logFile: URL(fileURLWithPath: "/tmp/run.log"),
                       mode: mode, profile: profile, context: context ?? ctx(), dryRun: dryRun)
}

/// True when `flag` is followed by `value` in `args`.
private func has(_ args: [String], _ flag: String, _ value: String? = nil) -> Bool {
    guard let i = args.firstIndex(of: flag) else { return false }
    guard let value else { return true }
    return i + 1 < args.count && args[i + 1] == value
}

@Suite struct RcloneCommandTests {
    @Test func mirrorHasRequiredFlags() {
        let a = RcloneCommand.arguments(request(context: ctx("/run/cfg")))
        #expect(a.first == "sync")
        #expect(has(a, "--modify-window", "1ms"))
        #expect(has(a, "--track-renames"))
        #expect(has(a, "--track-renames-strategy", "hash"))
        #expect(!a.contains("modtime"))
        #expect(has(a, "--links"))
        #expect(has(a, "--backup-dir", "/arch/ts"))
        #expect(has(a, "--filter-from", "/tmp/f.filter"))
        #expect(has(a, "--checkers", "2"))
        #expect(has(a, "--transfers", "2"))
        #expect(has(a, "--retries", "3"))
        #expect(has(a, "--retries-sleep", "30s"))
        #expect(has(a, "--low-level-retries", "10"))
        #expect(has(a, "--max-delete", "50"))
        #expect(has(a, "--use-json-log"))
        #expect(has(a, "-v"))
        #expect(has(a, "--log-file", "/tmp/run.log"))
        #expect(has(a, "--config", "/run/cfg"))
        #expect(a.contains("/src/dir") && a.contains("/dst/dir"))
        // --links is a plain global flag, never a connection string.
        #expect(!a.contains { $0.contains(":local") })
    }

    @Test func profilesMatchSpec() {
        func flags(_ k: DestinationKind) -> [String] { RcloneCommand.arguments(request(kind: k)) }
        let i = flags(.iCloudFolder)
        #expect(has(i, "--modify-window", "1ms"))
        #expect(!i.contains("--max-duration") && !i.contains("--cutoff-mode"))
        let g = flags(.googleDrive)
        #expect(has(g, "--modify-window", "1ms"))
        for f in ["--fast-list", "--drive-stop-on-upload-limit", "--drive-use-trash=false", "--cutoff-mode"] {
            #expect(g.contains(f), "\(f)")
        }
        #expect(has(g, "--max-duration", "25m"))
        #expect(has(g, "--cutoff-mode", "soft"))
        let o = flags(.oneDrive)
        #expect(has(o, "--modify-window", "1s"))
        #expect(o.contains("--onedrive-no-versions") && o.contains("--onedrive-hard-delete"))
        #expect(has(o, "--max-duration", "25m") && has(o, "--cutoff-mode", "soft"))
        // Rename tracking: hash strategy only where both sides have a hash; never modtime.
        for (d, fs, expected) in [(Destination(name: "x", kind: .iCloudFolder), nil as String?, true),
                                  (Destination(name: "x", kind: .googleDrive, encrypted: false), nil, true),
                                  (Destination(name: "x", kind: .googleDrive), nil, false),
                                  (Destination(name: "x", kind: .oneDrive, encrypted: false), nil, true),
                                  (Destination(name: "x", kind: .oneDrive), nil, false),
                                  (Destination(name: "x", kind: .externalDrive), "apfs", true),
                                  (Destination(name: "x", kind: .externalDrive), "hfs", true),
                                  (Destination(name: "x", kind: .externalDrive), "exfat", false)] {
            let p = DestinationProfile.profile(for: d, fileSystem: fs)
            #expect(p.trackRenames == expected, "\(d.kind) \(d.encrypted) \(fs ?? "")")
            let sync = SyncRequest(source: URL(fileURLWithPath: "/s"), destination: "/d", backupDir: "/b",
                                   filterFile: URL(fileURLWithPath: "/f"), logFile: URL(fileURLWithPath: "/l"),
                                   mode: .mirror(maxDelete: 5), profile: p, context: ctx())
            let a = RcloneCommand.arguments(sync)
            #expect(a.contains("--track-renames") == expected)
            #expect(!a.contains("modtime"))
            if expected { #expect(has(a, "--track-renames-strategy", "hash")) }
        }
        #expect(DestinationProfile.profile(for: Destination(name: "x", kind: .iCloudFolder)).fullPassInterval == 86_400)
        #expect(DestinationProfile.profile(for: Destination(name: "x", kind: .googleDrive)).fullPassInterval == 7 * 86_400)
        #expect(DestinationProfile.profile(for: Destination(name: "x", kind: .oneDrive)).fullPassInterval == 7 * 86_400)
    }

    @Test func environmentNeverInArguments() {
        let c = RcloneContext(configPath: "/run/cfg", environment: [
            "RCLONE_CONFIG_CRYPT_PASSWORD": "s3cretpass", "RCLONE_CONFIG_CRYPT_PASSWORD2": "s4lt"])
        let a = RcloneCommand.arguments(request(kind: .googleDrive, encrypted: true, context: c))
        let joined = a.joined(separator: " ")
        #expect(!joined.contains("s3cretpass") && !joined.contains("s4lt"))
        #expect(!joined.contains("RCLONE_CONFIG_"))
        let check = CheckRequest(source: URL(fileURLWithPath: "/s"), destination: "crypt:x", filterFile: nil, filesFrom: nil,
                                 sizeOnly: false, oneWay: true, cryptCheck: true, context: c,
                                 logFile: URL(fileURLWithPath: "/l"))
        #expect(!RcloneCommand.arguments(check).joined(separator: " ").contains("s3cretpass"))
    }

    @Test func cryptCheckUsesCryptcheckCommand() {
        func check(_ crypt: Bool) -> CheckRequest {
            CheckRequest(source: URL(fileURLWithPath: "/s"), destination: "crypt:x", filterFile: nil, filesFrom: nil,
                         sizeOnly: false, oneWay: false, cryptCheck: crypt, context: ctx(),
                         logFile: URL(fileURLWithPath: "/l"))
        }
        #expect(RcloneCommand.arguments(check(true)).first == "cryptcheck")
        #expect(RcloneCommand.arguments(check(false)).first == "check")
    }

    @Test func neverDeleteExcluded() {
        for mode in [SyncMode.mirror(maxDelete: 5), .copyOnly] {
            let a = RcloneCommand.arguments(request(mode: mode))
            #expect(!a.contains("--delete-excluded"))
        }
    }

    @Test func copyOnlyUsesCopyWithoutRenameOrMaxDelete() {
        let a = RcloneCommand.arguments(request(mode: .copyOnly))
        #expect(a.first == "copy")
        #expect(has(a, "--backup-dir", "/arch/ts"))
        #expect(!a.contains("--track-renames") && !a.contains("--track-renames-strategy"))
        #expect(!a.contains("--max-delete"))
    }

    @Test func dryRunAddsFlag() {
        #expect(RcloneCommand.arguments(request(dryRun: true)).contains("--dry-run"))
        #expect(!RcloneCommand.arguments(request(dryRun: false)).contains("--dry-run"))
    }

    @Test func checkHonoursOneWayAndSizeOnly() {
        func a(_ one: Bool, _ size: Bool) -> [String] {
            RcloneCommand.arguments(CheckRequest(source: URL(fileURLWithPath: "/s"), destination: "/d",
                filterFile: URL(fileURLWithPath: "/f"), filesFrom: nil, sizeOnly: size, oneWay: one, cryptCheck: false,
                context: ctx(), logFile: URL(fileURLWithPath: "/l")))
        }
        #expect(a(true, true).contains("--one-way") && a(true, true).contains("--size-only"))
        #expect(!a(false, false).contains("--one-way") && !a(false, false).contains("--size-only"))
        #expect(has(a(false, false), "--filter-from", "/f"))
        #expect(has(a(false, false), "--links"))
    }

    @Test func filesFromCheckDropsFilterFrom() {
        let a = RcloneCommand.arguments(CheckRequest(source: URL(fileURLWithPath: "/s"), destination: "/d",
            filterFile: URL(fileURLWithPath: "/f"), filesFrom: URL(fileURLWithPath: "/list"), sizeOnly: false,
            oneWay: false, cryptCheck: false, context: ctx(), logFile: URL(fileURLWithPath: "/l")))
        #expect(has(a, "--files-from-raw", "/list"))
        #expect(!a.contains("--filter-from"))
    }
}
