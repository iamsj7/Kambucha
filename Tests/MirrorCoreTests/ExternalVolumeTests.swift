import Testing
import Foundation
@testable import MirrorCore

private func volume(_ uuid: String = "AAAA", name: String = "SSD", fs: String = "apfs", free: Int64 = 1_000,
                    at mount: URL = URL(fileURLWithPath: "/Volumes/SSD")) -> VolumeInfo {
    VolumeInfo(uuid: uuid, name: name, mountPoint: mount, fileSystem: fs, freeBytes: free)
}

private func args(fs: String?) -> [String] {
    let d = Destination(name: "SSD", kind: .externalDrive, volumeUUID: "AAAA")
    let r = SyncRequest(source: URL(fileURLWithPath: "/src/my: dir"), destination: "/Volumes/SSD/Mac Backup/Sets/A",
                        backupDir: "/arch", filterFile: URL(fileURLWithPath: "/tmp/f"), logFile: URL(fileURLWithPath: "/tmp/l"),
                        mode: .mirror(maxDelete: 10), profile: .profile(for: d, fileSystem: fs),
                        context: RcloneContext(configPath: "/dev/null", environment: [:]))
    return RcloneCommand.arguments(r)
}

private func has(_ a: [String], _ f: String, _ v: String) -> Bool {
    guard let i = a.firstIndex(of: f) else { return false }
    return i + 1 < a.count && a[i + 1] == v
}

@Suite struct ExternalVolumeTests {
    @Test func externalIsNeverEncryptedByDefault() {
        #expect(Destination(name: "x", kind: .externalDrive).encrypted == false)
        #expect(Destination(name: "x", kind: .iCloudFolder).encrypted == false)
        #expect(Destination(name: "x", kind: .googleDrive).encrypted)
        #expect(Destination(name: "x", kind: .oneDrive).encrypted)
        #expect(DestinationProfile.profile(for: Destination(name: "x", kind: .externalDrive)).encrypted == false)
    }

    @Test func matchesByUUIDNotName() {
        let d = Destination(name: "SSD", kind: .externalDrive, volumeUUID: "AAAA")
        #expect(ExternalVolume.find(d, in: [volume("BBBB", name: "SSD")]) == nil)
        #expect(ExternalVolume.find(d, in: [volume("BBBB", name: "SSD"), volume("aaaa", name: "Other")])?.name == "Other")
        #expect(ExternalVolume.find(Destination(name: "SSD", kind: .externalDrive), in: [volume()]) == nil)
        #expect(ExternalVolume.find(Destination(name: "x", kind: .iCloudFolder, volumeUUID: "AAAA"), in: [volume()]) == nil)
    }

    @Test func mountPointWithSuffixIsStillTheSameDrive() throws {
        // macOS mounts a second "SSD" at /Volumes/SSD 1. Identity is the UUID, not the path.
        let e = try Env(mountName: "SSD 1")
        let vol = volume("AAAA", name: "SSD", at: e.mount)
        let d = Destination(name: "SSD", kind: .externalDrive, volumeUUID: "AAAA")
        #expect(ExternalVolume.find(d, in: [volume("BBBB", name: "SSD"), vol])?.mountPoint == e.mount)
        let set = BackupSet(name: "A", source: e.src)
        try PathGuard.forVolume(vol, iCloudDrive: e.icloud).validateRun(
            set, destination: d, marker: RootMarker(sets: [set.id: "A"]), sampleFileCount: 5, state: SetState(), volume: vol)
        #expect(ExternalVolume.backupRoot(on: vol).path.hasSuffix("SSD 1/Mac Backup"))
    }

    @Test func guardRefusesTheBootVolumeOnItsOwn() throws {
        let e = try Env()
        let set = BackupSet(name: "A", source: e.src)
        let dest = Destination(name: "Mac", kind: .externalDrive, volumeUUID: "ROOT")
        let marker = RootMarker(sets: [set.id: "A"])
        for vol in [VolumeInfo(uuid: "ROOT", name: "Macintosh HD", mountPoint: URL(fileURLWithPath: "/"), fileSystem: "apfs", freeBytes: 1),
                    VolumeInfo(uuid: "ROOT", name: "Data", mountPoint: URL(fileURLWithPath: "/System/Volumes/Data"), fileSystem: "apfs", freeBytes: 1),
                    VolumeInfo(uuid: "ROOT", name: "flagged", mountPoint: e.mount, fileSystem: "apfs", freeBytes: 1, isSystem: true)] {
            let g = PathGuard.forVolume(vol, iCloudDrive: e.icloud)
            do { try g.validateRun(set, destination: dest, marker: marker, sampleFileCount: 5, state: SetState(), volume: vol)
                 Issue.record("accepted \(vol.mountPoint.path)") }
            catch { #expect(error as? GuardFailure == .wrongDrive) }
        }
    }

    @Test func lockedDriveIsNotConnected() {
        // A locked drive never mounts, so it is absent from the list and find gives nil.
        let d = Destination(name: "SSD", kind: .externalDrive, volumeUUID: "AAAA")
        #expect(ExternalVolume.find(d, in: []) == nil)
    }

    @Test func exFATUsesTwoSecondWindow() {
        let a = args(fs: "exfat")
        #expect(has(a, "--modify-window", "2s"))
        #expect(!a.contains("--links"))
    }

    @Test func exFATStoresLinksAsRcloneLink() {
        let a = args(fs: "exfat")
        // Source-only connection string, destination a plain path. The path after the last colon is literal.
        #expect(a.contains(":local,links:/src/my: dir"))
        #expect(a.contains("/Volumes/SSD/Mac Backup/Sets/A"))
        #expect(args(fs: nil).contains(":local,links:/src/my: dir"))   // unknown file system takes the safe side
        #expect(args(fs: "msdos").contains(":local,links:/src/my: dir"))
    }

    @Test func exFATAvoidsRenameTrackingAndIgnoresAppleDouble() {
        let a = args(fs: "exfat")
        #expect(!a.contains("--track-renames") && !a.contains("--track-renames-strategy"))
        #expect(has(a, "--max-delete", "10"))
        let f = a.firstIndex(of: "--filter"), ff = a.firstIndex(of: "--filter-from")
        #expect(f != nil && ff != nil && a[f! + 1] == "- ._*" && f! < ff!)
        let apfs = args(fs: "apfs")
        #expect(apfs.contains("--track-renames") && has(apfs, "--track-renames-strategy", "hash") && !apfs.contains("--filter"))
    }

    @Test func apfsUsesOneMillisecond() {
        for fs in ["apfs", "hfs", "HFS+"] {
            let a = args(fs: fs)
            #expect(has(a, "--modify-window", "1ms"), "\(fs)")
            #expect(a.contains("--links"), "\(fs)")
            #expect(a.contains("/src/my: dir"), "\(fs)")
            #expect(!a.contains { $0.contains(":local") }, "\(fs)")
        }
    }

    @Test func checkFollowsTheSameLinkHandling() {
        func check(_ linksAsFiles: Bool) -> [String] {
            RcloneCommand.arguments(CheckRequest(source: URL(fileURLWithPath: "/s"), destination: "/d", filterFile: URL(fileURLWithPath: "/f"),
                                                 filesFrom: nil, sizeOnly: true, oneWay: false, cryptCheck: false,
                                                 context: RcloneContext(configPath: "/dev/null", environment: [:]),
                                                 logFile: URL(fileURLWithPath: "/l"), linksAsFiles: linksAsFiles,
                                                 excludeAppleDouble: linksAsFiles))
        }
        #expect(check(true).contains("- ._*") && !check(false).contains("- ._*"))
        #expect(check(true).contains(":local,links:/s") && !check(true).contains("--links"))
        #expect(check(false).contains("--links") && check(false).contains("/s"))
    }

    @Test func checkOnExFATAlwaysExcludesAppleDouble() {
        let p = DestinationProfile.profile(for: Destination(name: "x", kind: .externalDrive), fileSystem: "exfat")
        func check(filter: Bool, profile: DestinationProfile) -> [String] {
            RcloneCommand.arguments(CheckRequest(
                source: URL(fileURLWithPath: "/s"), destination: "/d", filterFile: filter ? URL(fileURLWithPath: "/f") : nil,
                filesFrom: nil, sizeOnly: true, oneWay: false, cryptCheck: false,
                context: RcloneContext(configPath: "/dev/null", environment: [:]), logFile: URL(fileURLWithPath: "/lg")).applying(profile))
        }
        #expect(check(filter: true, profile: p).contains("- ._*"))
        #expect(check(filter: false, profile: p).contains("- ._*"))   // whole-tree check has no filter file
        #expect(check(filter: false, profile: p).contains(":local,links:/s"))
        #expect(!check(filter: true, profile: p).contains("--links"))
        let apfs = DestinationProfile.profile(for: Destination(name: "x", kind: .externalDrive), fileSystem: "apfs")
        #expect(!check(filter: true, profile: apfs).contains("- ._*") && check(filter: true, profile: apfs).contains("--links"))
    }

    @Test func fitsKeepsAReserveAndCountsTheArchive() {
        let gb: Int64 = 1_000_000_000
        // Small drive: reserve is the 1 GB floor.
        let small = VolumeInfo(uuid: "A", name: "S", mountPoint: URL(fileURLWithPath: "/Volumes/S"), fileSystem: "apfs",
                               freeBytes: 10 * gb, totalBytes: 20 * gb)
        #expect(ExternalVolume.reserve(for: small) == gb)
        #expect(ExternalVolume.fits(bytesToCopy: 9 * gb, archiveBytes: 0, volume: small))
        #expect(!ExternalVolume.fits(bytesToCopy: 9 * gb + 1, archiveBytes: 0, volume: small))
        #expect(!ExternalVolume.fits(bytesToCopy: 8 * gb, archiveBytes: 2 * gb, volume: small))
        #expect(ExternalVolume.fits(bytesToCopy: 8 * gb, archiveBytes: gb, volume: small))
        // Big drive: 2% of 4 TB is 80 GB, which beats the floor.
        let big = VolumeInfo(uuid: "B", name: "B", mountPoint: URL(fileURLWithPath: "/Volumes/B"), fileSystem: "apfs",
                             freeBytes: 500 * gb, totalBytes: 4_000 * gb)
        #expect(ExternalVolume.reserve(for: big) == 80 * gb)
        #expect(ExternalVolume.fits(bytesToCopy: 420 * gb, archiveBytes: 0, volume: big))
        #expect(!ExternalVolume.fits(bytesToCopy: 421 * gb, archiveBytes: 0, volume: big))
        // Nothing to copy still needs the reserve free.
        #expect(!ExternalVolume.fits(bytesToCopy: 0, archiveBytes: 0, volume: volume(free: 0)))
    }

    @Test func symlinkSupportFollowsFileSystem() {
        #expect(ExternalVolume.supportsSymlinks(volume(fs: "apfs")))
        #expect(ExternalVolume.supportsSymlinks(volume(fs: "hfs")))
        #expect(!ExternalVolume.supportsSymlinks(volume(fs: "exfat")))
        #expect(!ExternalVolume.supportsSymlinks(volume(fs: "msdos")))
        #expect(!ExternalVolume.supportsSymlinks(volume(fs: "")))
    }

    @Test func driveProfileIsOtherwisePlain() {
        let p = DestinationProfile.profile(for: Destination(name: "x", kind: .externalDrive), fileSystem: "apfs")
        #expect(p.extraFlags.isEmpty && p.maxDuration == nil)
        let a = args(fs: "apfs")
        #expect(!a.contains("--max-duration"))
        #expect(a.contains("--track-renames") && has(a, "--max-delete", "10"))   // guard flags kept
    }

    @Test func problemsHaveHeadlines() {
        #expect(Problem.driveOverdue.headline == "Backup drive not connected")
        #expect(Problem.driveFull.headline == "Backup drive is full")
    }

    @Test func plistHasStartOnMount() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/com.shaikjaleel.mirror.agent.plist")
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any]
        #expect(plist?["StartOnMount"] as? Bool == true)
    }

    @Test func systemVolumesNeverOffersTheBootVolume() {
        let found = SystemVolumes().mounted()
        #expect(!found.contains { $0.mountPoint.path == "/" })
        #expect(!found.contains { $0.mountPoint.path.hasPrefix("/System/Volumes") })
        #expect(found.allSatisfy { !$0.uuid.isEmpty && !$0.isSystem })
    }

    /// A real disk image through the real classifier. Not a real SSD: images report external and ejectable with
    /// no internal flag, which is what a USB SSD is expected to look like, but that is not verified on one.
    @Test func realDiskImageIsOfferedAndTheBootVolumeIsNot() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mirror-ev-img-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let image = dir.appendingPathComponent("t.dmg")
        func hdiutil(_ args: [String]) throws -> String {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil"); p.arguments = args
            let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
            try p.run(); let data = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        }
        _ = try hdiutil(["create", "-size", "20m", "-fs", "APFS", "-volname", "MirrorEV", image.path])
        let attach = try hdiutil(["attach", image.path, "-nobrowse", "-plist"])
        defer { if let dev = Self.devNode(attach) { _ = try? hdiutil(["detach", "-force", dev]) } }
        let volumes = SystemVolumes(includeHidden: true).mounted()
        let img = volumes.first { $0.name == "MirrorEV" }
        #expect(img != nil)
        #expect(img?.fileSystem == "apfs" && img?.totalBytes ?? 0 > 0 && img?.mountID.isEmpty == false)
        #expect(!volumes.contains { $0.mountPoint.path == "/" || $0.mountPoint.path.hasPrefix("/System/Volumes") })
        #expect(SystemVolumes().mounted().allSatisfy { $0.name != "MirrorEV" })   // hidden mounts are skipped by default
    }

    private static func devNode(_ plist: String) -> String? {
        guard let d = try? PropertyListSerialization.propertyList(from: Data(plist.utf8), format: nil) as? [String: Any],
              let e = d["system-entities"] as? [[String: Any]] else { return nil }
        return e.compactMap { $0["dev-entry"] as? String }.first.map { String($0.prefix { !$0.isNumber } + $0.drop { !$0.isNumber }.prefix { $0.isNumber }) }
    }

    private func traits(_ path: String = "/Volumes/SSD", root: Bool = false, local: Bool = true, builtIn: Bool = false,
                        ejectable: Bool = true, readOnly: Bool = false, tm: Bool = false) -> VolumeTraits {
        VolumeTraits(path: path, isRootFileSystem: root, isLocal: local, isInternal: builtIn, isEjectable: ejectable,
                     isReadOnly: readOnly, isTimeMachine: tm)
    }

    @Test func classificationOffersOnlyWritableLocalExternalVolumes() {
        #expect(SystemVolumes.isBackupTarget(traits()))
        #expect(SystemVolumes.isBackupTarget(traits(builtIn: false, ejectable: false)))   // fixed external
        #expect(SystemVolumes.isBackupTarget(traits(builtIn: true, ejectable: true)))     // ejectable internal slot
        #expect(!SystemVolumes.isBackupTarget(traits("/", root: true, builtIn: true, ejectable: false)))
        #expect(!SystemVolumes.isBackupTarget(traits("/System/Volumes/Data", builtIn: true, ejectable: false)))
        #expect(!SystemVolumes.isBackupTarget(traits("/System/Volumes/VM")))
        #expect(!SystemVolumes.isBackupTarget(traits(builtIn: true, ejectable: false)))   // internal disk
        #expect(!SystemVolumes.isBackupTarget(traits(local: false)))                       // network share
        #expect(!SystemVolumes.isBackupTarget(traits(readOnly: true)))                     // installer, DMG
        #expect(!SystemVolumes.isBackupTarget(traits(tm: true)))                           // Time Machine
    }

    @Test func driveWithoutUUIDIsReportedUnsupported() {
        struct Fake: VolumeLocating {
            func mounted() -> [VolumeInfo] { [] }
            func unsupported() -> [UnsupportedVolume] {
                [UnsupportedVolume(name: "NoUUID", mountPoint: URL(fileURLWithPath: "/Volumes/NoUUID"), reason: .noVolumeUUID)]
            }
        }
        #expect(Fake().unsupported().first?.reason == .noVolumeUUID)
        struct Plain: VolumeLocating { func mounted() -> [VolumeInfo] { [] } }
        #expect(Plain().unsupported().isEmpty)
        let (ok, bad) = SystemVolumes.partition([("A", traits(), "UUID-1"), ("B", traits("/Volumes/B"), nil)])
        #expect(ok == [0] && bad.map(\.index) == [1] && bad.first?.reason == .noVolumeUUID)
    }

    @Test func fileSystemNameFallbackReadsMacOSExtendedAsHFS() {
        #expect(SystemVolumes.normalizedFileSystem(statfsName: nil, description: "Mac OS Extended (Journaled)") == "hfs")
        #expect(SystemVolumes.normalizedFileSystem(statfsName: nil, description: "APFS (Encrypted)") == "apfs")
        #expect(SystemVolumes.normalizedFileSystem(statfsName: nil, description: "ExFAT") == "exfat")
        #expect(SystemVolumes.normalizedFileSystem(statfsName: nil, description: "MS-DOS (FAT32)") == "msdos")
        #expect(SystemVolumes.normalizedFileSystem(statfsName: "hfs", description: "whatever") == "hfs")
        #expect(ExternalVolume.supportsSymlinks(fileSystem: SystemVolumes.normalizedFileSystem(
            statfsName: nil, description: "Mac OS Extended (Journaled)")))
    }

    // MARK: Full pass once per connection

    @Test func fullPassOnlyWhenTheMountChanges() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let v = VolumeInfo(uuid: "A", name: "S", mountPoint: URL(fileURLWithPath: "/Volumes/S"), fileSystem: "apfs",
                           freeBytes: 1, mountID: "/dev/disk5s1@1")
        // Never recorded: first connection.
        #expect(ExternalVolume.needsFullPass(lastSeenMountID: nil, volume: v, lastFullPass: nil, now: now))
        // Same mount, recent pass: the 30 minute wake-ups are ordinary runs.
        #expect(!ExternalVolume.needsFullPass(lastSeenMountID: "/dev/disk5s1@1", volume: v, lastFullPass: now.addingTimeInterval(-1800), now: now))
        // Unplugged and plugged back in.
        var again = v; again.mountID = "/dev/disk7s1@2"
        #expect(ExternalVolume.needsFullPass(lastSeenMountID: "/dev/disk5s1@1", volume: again, lastFullPass: now.addingTimeInterval(-1800), now: now))
        // Same mount for over a week: weekly backstop, since a mount ID can repeat.
        #expect(ExternalVolume.needsFullPass(lastSeenMountID: "/dev/disk5s1@1", volume: v, lastFullPass: now.addingTimeInterval(-8 * 86_400), now: now))
        // Unknown mount ID never claims "same connection".
        var unknown = v; unknown.mountID = ""
        #expect(ExternalVolume.needsFullPass(lastSeenMountID: "", volume: unknown, lastFullPass: now.addingTimeInterval(-60), now: now))
        #expect(DestinationProfile.profile(for: Destination(name: "x", kind: .externalDrive), fileSystem: "apfs").fullPassInterval == 7 * 86_400)
        var s = SetState(); #expect(s.lastSeenMountID == nil); s.lastSeenMountID = "x"
        #expect(try JSONDecoder().decode(SetState.self, from: JSONEncoder().encode(s)).lastSeenMountID == "x")
    }

    // MARK: PathGuard

    private struct Env {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("mirror-ev-\(UUID().uuidString)")
        let mount: URL, src: URL, icloud: URL
        init(mountName: String = "SSD") throws {
            mount = base.appendingPathComponent("Volumes/\(mountName)"); src = base.appendingPathComponent("src")
            icloud = base.appendingPathComponent("iCloud")
            for u in [mount.appendingPathComponent("Mac Backup/Sets/A"), src, icloud] {
                try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
            }
        }
    }

    @Test func volumeRootedGuardAllowsOnlyTheNamedDrive() throws {
        let e = try Env()
        let vol = volume("AAAA", at: e.mount)
        let g = PathGuard.forVolume(vol, iCloudDrive: e.icloud)
        #expect(g.backupRoot.path == e.mount.appendingPathComponent("Mac Backup").path)
        let set = BackupSet(name: "A", source: e.src)
        let dest = Destination(name: "SSD", kind: .externalDrive, volumeUUID: "AAAA")
        let marker = RootMarker(sets: [set.id: "A"])
        try g.validateRun(set, destination: dest, marker: marker, sampleFileCount: 5, state: SetState(), volume: vol)
        try g.validateNewSet(set, existing: [])
    }

    @Test func wrongDriveNeverWritten() throws {
        let e = try Env()
        let set = BackupSet(name: "A", source: e.src)
        let dest = Destination(name: "SSD", kind: .externalDrive, volumeUUID: "AAAA")
        let marker = RootMarker(sets: [set.id: "A"])
        let other = volume("BBBB", name: "SSD", at: e.mount)
        let g = PathGuard.forVolume(other, iCloudDrive: e.icloud)
        func refuses(_ v: VolumeInfo?) {
            do { try g.validateRun(set, destination: dest, marker: marker, sampleFileCount: 5, state: SetState(), volume: v)
                 Issue.record("should refuse") }
            catch { #expect(error as? GuardFailure == .wrongDrive) }
        }
        refuses(other)   // same name, other UUID
        refuses(nil)     // not connected
        // A volume with the right UUID but a root that isn't on it.
        let elsewhere = volume("AAAA", at: e.base.appendingPathComponent("Volumes/Else"))
        refuses(elsewhere)
    }
}
