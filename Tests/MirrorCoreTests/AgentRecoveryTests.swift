import Testing
import Foundation
@testable import MirrorCore

private final class Trust: AgentTrust, @unchecked Sendable {
    var callerFailure: AgentFailure?
    var helperFailure: AgentFailure?
    func verifyCaller() throws { if let callerFailure { throw callerFailure } }
    func verifyHelper(at: URL) throws { if let helperFailure { throw helperFailure } }
}

private struct NoPresence: UserPresence {
    func confirm(reason: String) async throws { throw AgentFailure.presenceRefused }
}

private final class Volumes: VolumeLocating, @unchecked Sendable {
    var list: [VolumeInfo] = []
    func mounted() -> [VolumeInfo] { list }
}

private final class Flag: @unchecked Sendable { var read = false }

/// Real rclone against temp folders, through `AgentService.respond`, the agent's actual entry point.
private final class Rig: @unchecked Sendable {
    let tmp: TempDir, support: URL, work: URL, iCloud: URL, source: URL, root: URL
    let secrets = MemorySecrets(), trust = Trust(), volumes = Volumes()
    let iCloudDest = Destination(name: "iCloud", kind: .iCloudFolder)
    var set: BackupSet
    var retriesBusy = true
    let binary: URL

    init(binary: URL = vendoredRclone) throws {
        self.binary = binary
        tmp = try TempDir()
        support = try tmp.sub("support"); work = try tmp.sub("work"); iCloud = try tmp.sub("icloud"); source = try tmp.sub("src")
        root = iCloud.appendingPathComponent("Mac Backup")
        set = BackupSet(name: "Docs", source: source, destinationIDs: [iCloudDest.id])
        try save()
    }

    func save(extra: [Destination] = []) throws {
        let store = ConfigStore(root: support)
        try store.saveSets([set]); try store.saveDestinations([iCloudDest] + extra)
    }

    var service: AgentService {
        AgentService(secrets: secrets, binary: binary, trust: trust, presence: NoPresence(), support: support, workDir: work,
                     volumes: volumes, iCloudDrive: iCloud, presets: { [] })
    }

    func put(_ rel: String, _ text: String = "data", in base: URL? = nil) throws {
        let url = (base ?? root).appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func ask(_ subcommand: String, _ body: some Encodable) async throws -> AgentWire.Response {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        let input = try e.encode(body)
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        // As in `ServiceRig.send`: a sibling test's spawn can briefly keep a released flock alive, which only
        // happens in one process. Anything but `busy` returns at once, and a stuck lock still fails after 2 seconds.
        var answer = try d.decode(AgentWire.Response.self, from: await service.respond(subcommand: subcommand, input: { input }))
        let deadline = Date().addingTimeInterval(2)
        while retriesBusy, answer.failure == .busy, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
            answer = try d.decode(AgentWire.Response.self, from: await service.respond(subcommand: subcommand, input: { input }))
        }
        return answer
    }

    func list(_ destination: UUID? = nil) async throws -> AgentWire.Response {
        try await ask(AgentWire.archiveList, AgentWire.PairRequest(set: set.id, destination: destination ?? iCloudDest.id))
    }

    func restore(_ path: String, to: String, destination: UUID? = nil) async throws -> AgentWire.Response {
        try await ask(AgentWire.archiveRestore, AgentWire.RestoreRequest(set: set.id, destination: destination ?? iCloudDest.id, path: path, to: to))
    }

    func dryRun(_ destination: UUID? = nil) async throws -> AgentWire.Response {
        try await ask(AgentWire.dryRunDeletions, AgentWire.PairRequest(set: set.id, destination: destination ?? iCloudDest.id))
    }
}

private let stamp = "2026-11-04T10-00-00"

@Suite struct AgentRecoveryTests {
    // MARK: Looking inside the latest backup

    fileprivate func browse(_ r: Rig, _ path: String) async throws -> AgentWire.Response {
        try await r.ask(AgentWire.setList, AgentWire.BrowseRequest(set: r.set.id, destination: r.iCloudDest.id, path: path))
    }

    @Test func browsingListsOneLevelFoldersFirst() async throws {
        let r = try Rig()
        try r.put("Sets/Docs/a.txt", "12345")
        try r.put("Sets/Docs/p/inner/f.txt")
        let top = try await browse(r, "Sets/Docs")
        #expect(top.ok == true)
        #expect(top.items == [BackupItem(name: "p", isFolder: true, size: 0), BackupItem(name: "a.txt", isFolder: false, size: 5)])
        #expect(try await browse(r, "Sets/Docs/p").items?.map(\.name) == ["inner"])
    }

    @Test func aFolderGoneFromTheBackupIsNotFound() async throws {
        let r = try Rig()
        try r.put("Sets/Docs/a.txt")
        #expect(try await browse(r, "Sets/Docs/nope").failure == .notFound)
    }

    @Test(arguments: ["Sets/Other", "Sets/Docs/../Other", "Archive/Docs/\(stamp)", "Sets", "", "/etc", "Manifests/Docs.json"])
    func onlyThisSetsMirrorCanBeBrowsed(path: String) async throws {
        let r = try Rig()
        try r.put("Sets/Other/a.txt"); try r.put("Sets/Docs/b.txt"); try r.put("Archive/Docs/\(stamp)/a.txt")
        #expect(try await browse(r, path).failure == .invalidRequest)
    }

    // MARK: Names in a destination

    @Test func setNamesListsTheFoldersInTheDestination() async throws {
        let r = try Rig()
        try r.put("Sets/Old Work/a.txt")
        try r.put("Sets/Docs/b.txt")
        let stored = try await r.ask(AgentWire.setNames, AgentWire.NamesRequest(destination: r.iCloudDest.id))
        #expect(stored.ok == true)
        #expect(stored.files?.sorted() == ["Docs", "Old Work"])
        // No iCloud destination saved yet, as with the first set: the folder is still the one to look in.
        let unsaved = try await r.ask(AgentWire.setNames, AgentWire.NamesRequest(destination: nil))
        #expect(unsaved.files?.sorted() == ["Docs", "Old Work"])
    }

    @Test func setNamesOfAnEmptyDestinationIsEmpty() async throws {
        let r = try Rig()
        #expect(try await r.ask(AgentWire.setNames, AgentWire.NamesRequest(destination: r.iCloudDest.id)).files == [])
    }

    @Test func setNamesNeedsAStoredDestination() async throws {
        let r = try Rig()
        #expect(try await r.ask(AgentWire.setNames, AgentWire.NamesRequest(destination: UUID())).failure == .notFound)
    }

    // MARK: Who may ask

    @Test(arguments: [AgentWire.archiveList, AgentWire.archiveRestore, AgentWire.dryRunDeletions, AgentWire.setNames, AgentWire.setList])
    func aRefusedCallerGetsNothingAndItsInputIsNeverRead(subcommand: String) async throws {
        let r = try Rig()
        r.trust.callerFailure = .untrustedCaller
        let flag = Flag()
        let out = await r.service.respond(subcommand: subcommand, input: { flag.read = true; return Data() })
        let answer = try JSONDecoder().decode(AgentWire.Response.self, from: out)
        #expect(answer.failure == .untrustedCaller && answer.ok != true)
        #expect(!flag.read)
    }

    @Test func aSwappedRcloneIsRefusedBeforeAnything() async throws {
        let r = try Rig()
        r.trust.helperFailure = .untrustedHelper
        #expect(try await r.list().failure == .untrustedHelper)
    }

    @Test func theSubcommandsReachTheAgentsEntryPoint() {
        #expect(AgentWire.subcommands.isDisjoint(with: AgentRequest.subcommands))
    }

    @Test func badInputIsAnswered() async throws {
        let r = try Rig()
        let out = await r.service.respond(subcommand: AgentWire.archiveList, input: { Data("nonsense".utf8) })
        #expect(try JSONDecoder().decode(AgentWire.Response.self, from: out).failure == .invalidRequest)
    }

    @Test func storedConfigDecidesNotTheRequest() async throws {
        let r = try Rig()
        #expect(try await r.list(UUID()).failure == .notFound)
        let elsewhere = Destination(name: "Other", kind: .iCloudFolder)
        try r.save(extra: [elsewhere])   // exists, but this set doesn't use it
        #expect(try await r.list(elsewhere.id).failure == .notFound)
        let body = AgentWire.PairRequest(set: UUID(), destination: r.iCloudDest.id)
        #expect(try await r.ask(AgentWire.archiveList, body).failure == .notFound)
    }

    @Test func aSignInInProgressReadsAsBusy() async throws {
        let r = try Rig()
        let folder = r.support.appendingPathComponent("locks")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fd = open(folder.appendingPathComponent("secrets.lock").path, O_CREAT | O_RDWR, 0o600)
        defer { close(fd) }
        #expect(flock(fd, LOCK_EX | LOCK_NB) == 0)
        r.retriesBusy = false
        #expect(try await r.list().failure == .busy)
    }

    // MARK: archive-list

    @Test func listingAnswersOkWithEntries() async throws {
        let r = try Rig()
        try r.put("Archive/Docs/\(stamp)/p/a.txt", "12345")
        try r.put("Sets/Docs/p/live.txt")
        let answer = try await r.list()
        #expect(answer.ok == true && answer.failure == nil)
        let entry = try #require(answer.entries?.first)
        #expect(answer.entries?.count == 1)
        #expect(entry.path == "Archive/Docs/\(stamp)/p/a.txt" && entry.size == 5 && entry.setName == "Docs")
        #expect(entry.stamp == ArchiveScope.parseStamp(stamp))
    }

    @Test func anEmptyArchiveIsAnEmptyList() async throws {
        let r = try Rig()
        let answer = try await r.list()
        #expect(answer.ok == true && answer.entries == [])
    }

    // MARK: archive-restore

    private func target(_ r: Rig, _ name: String = "a.txt") throws -> URL { try r.tmp.sub("out").appendingPathComponent(name) }

    @Test func aFileLandsAtExactlyThePathTheSavePanelGave() async throws {
        let r = try Rig()
        try r.put("Archive/Docs/\(stamp)/p/a.txt", "old words")
        let to = try target(r, "renamed.txt")
        let answer = try await r.restore("Archive/Docs/\(stamp)/p/a.txt", to: to.path)
        #expect(answer.ok == true)
        #expect(try String(contentsOf: to, encoding: .utf8) == "old words")
    }

    @Test func anExistingFileIsNeverOverwritten() async throws {
        let r = try Rig()
        try r.put("Archive/Docs/\(stamp)/a.txt", "old")
        let to = try target(r)
        try Data("precious".utf8).write(to: to)
        #expect(try await r.restore("Archive/Docs/\(stamp)/a.txt", to: to.path).failure == .restore(.destinationNotEmpty(to.path)))
        #expect(try String(contentsOf: to, encoding: .utf8) == "precious")
    }

    @Test func nothingIsRestoredOverASource() async throws {
        let r = try Rig()
        try r.put("Archive/Docs/\(stamp)/a.txt", "old")
        let to = r.source.appendingPathComponent("a.txt")
        let answer = try await r.restore("Archive/Docs/\(stamp)/a.txt", to: to.path)
        #expect(answer.ok != true)
        #expect(!FileManager.default.fileExists(atPath: to.path))
    }

    @Test(arguments: ["Archive/Other/\(stamp)/a.txt", "Manifests/Docs.json", ".mirror-root", "/etc/hosts", "Sets/Other/a.txt",
                      "Archive/Docs/../../Sets/Other/a.txt", "other:Archive/Docs/\(stamp)/a.txt", "-rf", ""])
    func onlyThisSetsArchiveAndMirrorCanBeRead(path: String) async throws {
        let r = try Rig()
        try r.put("Archive/Other/\(stamp)/a.txt"); try r.put("Sets/Other/a.txt"); try r.put(".mirror-root"); try r.put("Manifests/Docs.json")
        let to = try target(r)
        let answer = try await r.restore(path, to: to.path)
        #expect(answer.ok != true && answer.failure != nil)
        #expect(!FileManager.default.fileExists(atPath: to.path))
    }

    @Test func aWholeRunFromTheArchiveRestoresAsAFolder() async throws {
        let r = try Rig()
        try r.put("Archive/Docs/\(stamp)/a.txt", "one"); try r.put("Archive/Docs/\(stamp)/p/b.txt", "two")
        let to = try r.tmp.sub("out").appendingPathComponent("run")
        #expect(try await r.restore("Archive/Docs/\(stamp)", to: to.path).ok == true)
        #expect(try String(contentsOf: to.appendingPathComponent("p/b.txt"), encoding: .utf8) == "two")
    }

    @Test func aFolderIsNotRestoredOverAFolderWithFilesInIt() async throws {
        let r = try Rig()
        try r.put("Sets/Docs/p/f.txt")
        let to = try r.tmp.sub("out")
        try r.put("mine.txt", in: to)
        #expect(try await r.restore("Sets/Docs/p", to: to.path).failure == .restore(.destinationNotEmpty(to.path)))
    }

    @Test func aWholeSetIsNotRestoredOverItsSource() async throws {
        let r = try Rig()
        try r.put("Sets/Docs/f.txt")
        guard case .restore(.overSource) = try await r.restore("Sets/Docs", to: r.source.path).failure else {
            Issue.record("expected the source to be refused"); return
        }
    }

    @Test func aRelativeTargetIsRefused() async throws {
        let r = try Rig()
        try r.put("Archive/Docs/\(stamp)/a.txt")
        #expect(try await r.restore("Archive/Docs/\(stamp)/a.txt", to: "out/a.txt").failure == .invalidRequest)
    }

    @Test func aFolderRestoresWithItsManifestLinks() async throws {
        let r = try Rig()
        try r.put("Sets/Docs/p/f.txt")
        try SymlinkManifest(set: "Docs", entries: [.init(path: "p/link", target: "f.txt", isAbsolute: false, isBroken: false)])
            .write(backupRoot: r.root)
        let to = try r.tmp.sub("out").appendingPathComponent("restored")
        #expect(try await r.restore("Sets/Docs/p", to: to.path).ok == true)
        #expect(FileManager.default.fileExists(atPath: to.appendingPathComponent("f.txt").path))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: to.appendingPathComponent("link").path) == "f.txt")
    }

    @Test func aWholeSetRestoreRecreatesLinksFromTheManifest() async throws {
        let r = try Rig()
        try r.put("Sets/Docs/p/f.txt")
        try SymlinkManifest(set: "Docs", entries: [.init(path: "p/link", target: "f.txt", isAbsolute: false, isBroken: false)])
            .write(backupRoot: r.root)
        let to = try r.tmp.sub("out").appendingPathComponent("everything")
        #expect(try await r.restore("Sets/Docs", to: to.path).ok == true)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: to.appendingPathComponent("p/link").path) == "f.txt")
    }

    @Test(arguments: ["/../etc/x", "/tmp/../Users/x/y", "/tmp/out/.."])
    func aTargetWithDotDotIsRefusedBeforeAnythingElse(to: String) async throws {
        let r = try Rig()
        try r.put("Archive/Docs/\(stamp)/a.txt")
        #expect(try await r.restore("Archive/Docs/\(stamp)/a.txt", to: to).failure == .invalidRequest)
    }

    @Test func aTargetCanHoldDotsInItsNames() async throws {
        let r = try Rig()
        try r.put("Archive/Docs/\(stamp)/a.txt", "kept")
        let to = try r.tmp.sub("out").appendingPathComponent("..hidden..txt")
        #expect(try await r.restore("Archive/Docs/\(stamp)/a.txt", to: to.path).ok == true)
    }

    @Test func aMissingArchiveFileIsAFailureNotAnEmptySuccess() async throws {
        let r = try Rig()
        try FileManager.default.createDirectory(at: r.root, withIntermediateDirectories: true)
        let answer = try await r.restore("Archive/Docs/\(stamp)/gone.txt", to: try target(r).path)
        #expect(answer.ok != true && answer.failure != nil)
    }

    // MARK: Drives

    private func drive(_ r: Rig, looksInternal: Bool = false) throws -> (Destination, URL) {
        let mount = try r.tmp.sub("Volumes/SSD")
        let d = Destination(name: "SSD", kind: .externalDrive, volumeUUID: "U-1")
        r.set.destinationIDs.append(d.id)
        try r.save(extra: [d])
        r.volumes.list = [VolumeInfo(uuid: "U-1", name: "SSD", mountPoint: mount, fileSystem: "apfs", freeBytes: 1 << 40, looksInternal: looksInternal)]
        return (d, mount.appendingPathComponent("Mac Backup"))
    }

    @Test func aDriveIsReadOnlyThroughItsLiveVolume() async throws {
        let r = try Rig()
        let (d, root) = try drive(r)
        try r.put("Archive/Docs/\(stamp)/a.txt", "on the drive", in: root)
        #expect(try await r.list(d.id).entries?.count == 1)
        let to = try target(r)
        let answer = try await r.restore("Archive/Docs/\(stamp)/a.txt", to: to.path, destination: d.id)
        #expect(answer.ok == true, "failure: \(String(describing: answer.failure))")
        #expect(try String(contentsOf: to, encoding: .utf8) == "on the drive")
    }

    @Test func aDriveThatIsNotConnectedSaysSo() async throws {
        let r = try Rig()
        let (d, _) = try drive(r)
        r.volumes.list = []
        #expect(try await r.list(d.id).failure == .driveNotConnected)
    }

    @Test func anUnconfirmedInternalLookingDriveIsRefusedHereToo() async throws {
        let r = try Rig()
        let (d, root) = try drive(r, looksInternal: true)
        try r.put("Archive/Docs/\(stamp)/a.txt", in: root)
        #expect(try await r.list(d.id).failure == .driveNotConnected)
    }

    @Test func aRestoreWorksWithTheSourceGone() async throws {
        let r = try Rig()
        try r.put("Archive/Docs/\(stamp)/a.txt", "saved")
        try FileManager.default.removeItem(at: r.source)
        let to = try target(r)
        #expect(try await r.restore("Archive/Docs/\(stamp)/a.txt", to: to.path).ok == true)
    }

    // MARK: Encrypted destinations

    private func logging(in dir: URL) throws -> URL {
        try fakeRclone(in: dir, body: #"""
            here="$(/usr/bin/dirname "$0")"
            case "$1" in
              obscure) cat >/dev/null; echo obscured-stand-in; exit 0 ;;
              lsjson) echo "$*" >> "$here/calls"; echo '{"IsDir":false}'; exit 0 ;;
              *) echo "$*" >> "$here/calls"; exit 0 ;;
            esac
            """#)
    }

    private func encrypted(_ r: Rig) throws -> Destination {
        var d = Destination(name: "Drive", kind: .googleDrive)
        d.recoveryKitConfirmed = true
        r.set.destinationIDs.append(d.id)
        try r.save(extra: [d])
        try r.secrets.saveSignIn(["token": #"{"access_token":"a","refresh_token":"r"}"#], for: d)
        try r.secrets.saveVault(VaultSecrets(passphrase: "the-passphrase", salt: "the-salt"), for: d)
        return d
    }

    @Test func anEncryptedRestoreIsPinnedToTheCryptEndpointAndSecretsStayInside() async throws {
        let tmp = try TempDir()
        let r = try Rig(binary: try logging(in: tmp.url))
        let d = try encrypted(r)
        let to = try target(r)
        let crypt = RcloneBackend.cryptName(d)
        let answer = try await r.restore("Archive/Docs/\(stamp)/a.txt", to: to.path, destination: d.id)
        #expect(answer.ok == true)
        let calls = try String(contentsOf: tmp.url.appendingPathComponent("calls"), encoding: .utf8)
        #expect(calls.contains("\(crypt):Archive/Docs/\(stamp)/a.txt"))
        #expect(!calls.contains("mirrorbase"))
        #expect(!calls.contains("the-passphrase") && !calls.contains("the-salt") && !calls.contains("refresh_token"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: r.work.path).isEmpty)   // the sign-in config is gone
    }

    @Test func anEncryptedDestinationWithoutItsKeysIsRefused() async throws {
        let tmp = try TempDir()
        let r = try Rig(binary: try logging(in: tmp.url))
        let d = try encrypted(r)
        try r.secrets.delete(SecretKeys.vault(d.id))
        #expect(try await r.list(d.id).failure == .session(.encryptionKeysMissing))
    }

    // MARK: dry-run-deletions

    private func mirrored(_ r: Rig) throws {
        try r.put("keep.txt", in: r.source)
        try r.put("Sets/Docs/keep.txt")
        for name in ["gone1.txt", "p/gone2.txt", "p/.git/objects/x", ".git/index"] { try r.put("Sets/Docs/\(name)") }
        try RootMarker(sets: [r.set.id: r.set.name]).save(backupRoot: r.root)
    }

    @Test func theDeletionListHoldsNoGitFilesSoItsCountIsTheGates() async throws {
        let r = try Rig()
        try mirrored(r)
        let answer = try await r.dryRun()
        #expect(answer.ok == true)
        #expect(answer.files == ["gone1.txt", "p/gone2.txt"])
        #expect(AgentWire.nonGitCount(answer.files ?? []) == answer.files?.count)
        #expect(answer.gitFiles == 2)
    }

    @Test func aDryRunChangesNothing() async throws {
        let r = try Rig()
        try mirrored(r)
        _ = try await r.dryRun()
        #expect(FileManager.default.fileExists(atPath: r.root.appendingPathComponent("Sets/Docs/gone1.txt").path))
        #expect(!FileManager.default.fileExists(atPath: r.root.appendingPathComponent("Archive").path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: r.work.path).isEmpty)
    }

    @Test func excludedFilesAreNotReportedAsDeletions() async throws {
        let r = try Rig()
        try mirrored(r)
        r.set.rules = [UserRule(pattern: "gone1.txt", action: .exclude)]
        try r.save()
        #expect(try await r.dryRun().files == ["p/gone2.txt"])
    }

    @Test func aFailedDryRunIsNeverAnEmptyList() async throws {
        let r = try Rig()
        try mirrored(r)
        try FileManager.default.removeItem(at: r.source)
        let answer = try await r.dryRun()
        #expect(answer.ok != true && answer.files == nil && answer.failure != nil)
    }
}

@Suite struct AgentRecoveryClientShapeTests {
    @Test func everyNewFailureHasItsOwnWords() {
        let generic = SetupFailureText.message(for: AgentFailure.other)
        for failure: AgentFailure in [.notFound, .driveNotConnected, .archive, .restoreFailed, .restore(.overSource("/x"))] {
            #expect(SetupFailureText.message(for: failure) != generic)
        }
        #expect(SetupFailureText.message(for: AgentFailure.driveNotConnected).contains("drive"))
    }

    @Test func aFailureCarriesNoRcloneText() {
        #expect(AgentFailure(ArchiveError.rcloneFailed("token=SECRET")) == .archive)
        #expect(AgentFailure(ArchiveError.authExpired) == .session(.notSignedIn))
        #expect(AgentFailure(GuardFailure.wrongDrive) == .driveNotConnected)
    }
}
