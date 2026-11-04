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

    @Test func fitsComparesBytesToFreeSpace() {
        #expect(ExternalVolume.fits(bytesToCopy: 1_000, volume: volume(free: 1_000)))
        #expect(!ExternalVolume.fits(bytesToCopy: 1_001, volume: volume(free: 1_000)))
        #expect(ExternalVolume.fits(bytesToCopy: 0, volume: volume(free: 0)))
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

    @Test func systemVolumesReportsTheStartupVolume() {
        let root = SystemVolumes().mounted().first { $0.mountPoint.path == "/" }
        #expect(root != nil)
        #expect(root?.fileSystem == "apfs")
        #expect(root?.uuid.isEmpty == false)
        #expect((root?.freeBytes ?? 0) > 0)
    }

    // MARK: PathGuard

    private struct Env {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("mirror-ev-\(UUID().uuidString)")
        let mount: URL, src: URL, icloud: URL
        init() throws {
            mount = base.appendingPathComponent("Volumes/SSD"); src = base.appendingPathComponent("src")
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
