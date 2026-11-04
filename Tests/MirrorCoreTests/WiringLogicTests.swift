import Testing
import Foundation
@testable import MirrorCore

private func vol(_ uuid: String, _ name: String = "SSD", fs: String = "apfs", looksInternal: Bool = false) -> VolumeInfo {
    VolumeInfo(uuid: uuid, name: name, mountPoint: URL(fileURLWithPath: "/Volumes/\(name)"), fileSystem: fs,
               freeBytes: 5_000_000_000, looksInternal: looksInternal)
}

private func drive(_ uuid: String, name: String = "SSD", confirmed: Bool = false) -> Destination {
    Destination(name: name, kind: .externalDrive, encrypted: false, volumeUUID: uuid, internalDiskConfirmed: confirmed)
}

// MARK: Wording for agent failures

@Test func busyHasItsOwnClearMessage() {
    let text = SetupFailureText.message(for: AgentFailure.busy)
    #expect(text == "Another Mirror action is using your sign-in. Wait for it to finish, then try again.")
    #expect(SetupFailureText.isBusy(AgentFailure.busy))
    #expect(!SetupFailureText.isBusy(AgentFailure.presenceRefused))
}

@Test func agentFailuresReadAsSentencesNotAsSwiftTypes() {
    let all: [AgentFailure] = [.untrustedCaller, .untrustedHelper, .presenceRefused, .configUnreadable, .busy,
                               .lockFailed, .invalidRequest, .cancelled, .other]
    for f in all {
        let text = SetupFailureText.message(for: f)
        #expect(!text.isEmpty && !text.contains("MirrorCore") && !text.contains("AgentFailure"), "\(f)")
    }
    #expect(SetupFailureText.message(for: AgentFailure.presenceRefused).contains("Touch ID"))
}

@Test func inspectorAndRestoreErrorsHaveWords() {
    #expect(SetupFailureText.message(for: LocalMirrorInspectorError.backupRunning).contains("backup is running"))
    #expect(!SetupFailureText.message(for: LocalMirrorInspectorError.unsafePath("../x")).contains("MirrorCore"))
    #expect(!SetupFailureText.message(for: RestoreError.destinationNotEmpty("/x")).contains("MirrorCore"))
    #expect(!SetupFailureText.message(for: ArchiveError.outsideArchive("/x")).contains("MirrorCore"))
}

@Test func theInternalDiskMessagePointsToTheDestinationNotToRemovingIt() {
    let text = SetupFailureText.message(for: GuardFailure.internalDiskNotConfirmed)
    #expect(!text.contains("Remove the destination"))
    #expect(text.contains("confirm"))
}

// MARK: Kit restore with the unproven question

@MainActor private final class RestoreRecorder {
    var calls: [(String, Bool)] = []
    var results: [(any Error)?] = []
    func run(_ d: Destination, _ text: String, _ accept: Bool) async throws {
        calls.append((text, accept))
        if !results.isEmpty, let e = results.removeFirst() { throw e }
    }
}

@MainActor private func restoreModel(_ r: RestoreRecorder) -> KitRestoreModel {
    KitRestoreModel(destination: Destination(name: "Drive", kind: .googleDrive)) { try await r.run($0, $1, $2) }
}

@MainActor @Test func aKitThatProvesItselfRestoresAtOnce() async {
    let r = RestoreRecorder()
    let m = restoreModel(r)
    m.text = "KIT"
    await m.submit()
    #expect(m.phase == .done)
    #expect(m.text.isEmpty)
    #expect(r.calls.count == 1 && r.calls[0].0 == "KIT" && r.calls[0].1 == false)
}

@MainActor @Test func anUnprovenKitAsksBeforeItIsUsed() async {
    let r = RestoreRecorder(); r.results = [RemoteSetupError.kitUnproven]
    let m = restoreModel(r)
    m.text = "KIT"
    await m.submit()
    #expect(m.phase == .askingUnproven)
    #expect(m.text == "KIT")   // still there for the second try
    #expect(r.calls.count == 1)
    await m.acceptUnproven()
    #expect(m.phase == .done)
    #expect(r.calls.count == 2 && r.calls[1].0 == "KIT" && r.calls[1].1 == true)
    #expect(m.text.isEmpty)
}

@MainActor @Test func decliningTheUnprovenQuestionGoesBackToEditingWithoutUsingTheKit() async {
    let r = RestoreRecorder(); r.results = [RemoteSetupError.kitUnproven]
    let m = restoreModel(r)
    m.text = "KIT"
    await m.submit()
    m.declineUnproven()
    #expect(m.phase == .editing)
    #expect(r.calls.count == 1)
}

@MainActor @Test func acceptUnprovenDoesNothingUnlessAsked() async {
    let r = RestoreRecorder()
    let m = restoreModel(r)
    m.text = "KIT"
    await m.acceptUnproven()
    #expect(r.calls.isEmpty)
}

@MainActor @Test func aFailedRestoreShowsWordsAndBusyIsClear() async {
    let r = RestoreRecorder(); r.results = [AgentFailure.busy, RemoteSetupError.kitDoesNotOpenBackup]
    let m = restoreModel(r)
    m.text = "KIT"
    await m.submit()
    #expect(m.phase == .failed(SetupFailureText.message(for: AgentFailure.busy)))
    await m.submit()
    #expect(m.phase == .failed(SetupFailureText.message(for: RemoteSetupError.kitDoesNotOpenBackup)))
}

@MainActor @Test func cancellingForgetsTheKitText() async {
    let r = RestoreRecorder()
    let m = restoreModel(r)
    m.text = "KIT"
    m.cancel()
    #expect(m.text.isEmpty)
}

// MARK: Kit reveal asks for presence first

@MainActor @Test func revealAsksThenShowsTheKit() async {
    let m = KitRevealModel(destination: Destination(name: "Drive", kind: .googleDrive)) { _ in "THE KIT" }
    #expect(m.phase == .idle)
    await m.begin()
    #expect(m.phase == .shown)
    #expect(m.kitText == "THE KIT")
    m.clear()
    #expect(m.kitText == nil && m.phase == .idle)
}

@MainActor @Test func aRefusedTouchIDCanBeTriedAgain() async {
    nonisolated(unsafe) var refuse = true
    let m = KitRevealModel(destination: Destination(name: "Drive", kind: .googleDrive)) { _ in
        if refuse { throw AgentFailure.presenceRefused }
        return "KIT"
    }
    await m.begin()
    #expect(m.phase == .failed(SetupFailureText.message(for: AgentFailure.presenceRefused)))
    #expect(m.kitText == nil)
    refuse = false
    await m.begin()
    #expect(m.phase == .shown && m.kitText == "KIT")
}

@MainActor @Test func aSecondBeginWhileAskingDoesNotAskAgain() async {
    nonisolated(unsafe) var asked = 0
    let m = KitRevealModel(destination: Destination(name: "Drive", kind: .googleDrive)) { _ in
        asked += 1
        try await Task.sleep(for: .milliseconds(150))
        return "KIT"
    }
    async let first: Void = m.begin()
    try? await Task.sleep(for: .milliseconds(30))
    #expect(m.phase == .asking)
    await m.begin()
    await first
    #expect(asked == 1)
}

// MARK: Drives

@Test func aConnectedInternalLookingDriveNeedsConfirmationUntilConfirmed() {
    let v = vol("U", looksInternal: true)
    #expect(ExternalDriveSetup.needsConfirmation(drive("U"), volume: v))
    #expect(!ExternalDriveSetup.needsConfirmation(drive("U", confirmed: true), volume: v))
    #expect(!ExternalDriveSetup.needsConfirmation(drive("U"), volume: vol("U")))
    #expect(!ExternalDriveSetup.needsConfirmation(drive("U"), volume: nil))
    #expect(!ExternalDriveSetup.needsConfirmation(Destination(name: "iCloud", kind: .iCloudFolder), volume: v))
    #expect(ExternalDriveSetup.confirmed(drive("U")).internalDiskConfirmed)
}

@Test func noTwoDestinationsMayNameTheSameDrive() {
    let a = drive("ABC-1", name: "A")
    #expect(DestinationRules.duplicateDrive(of: "abc-1", in: [a], excluding: nil)?.id == a.id)
    #expect(DestinationRules.duplicateDrive(of: "ABC-1", in: [a], excluding: a.id) == nil)
    #expect(DestinationRules.duplicateDrive(of: "OTHER", in: [a], excluding: nil) == nil)
    #expect(DestinationRules.duplicateDrive(of: "", in: [drive("")], excluding: nil) == nil)
    #expect(DestinationRules.duplicateDriveMessage(a) == "This drive is already a destination called \"A\".")
}

@Test func exFATWarnsThatAppleDoubleFilesAreNotBackedUp() {
    let d = drive("U", name: "SSD")
    var set = BackupSet(name: "Docs", source: URL(fileURLWithPath: "/x"), destinationIDs: [d.id])
    let exfat = PreviewWarnings.appleDouble(set: set, destinations: [d], volumes: [vol("U", fs: "exfat")])
    #expect(exfat.count == 1)
    #expect(exfat[0].contains("._*") && exfat[0].contains("SSD") && exfat[0].contains("exFAT"))
    #expect(PreviewWarnings.appleDouble(set: set, destinations: [d], volumes: [vol("U", fs: "apfs")]).isEmpty)
    #expect(PreviewWarnings.appleDouble(set: set, destinations: [d], volumes: []).isEmpty)   // not connected: nothing known
    set.destinationIDs = []
    #expect(PreviewWarnings.appleDouble(set: set, destinations: [d], volumes: [vol("U", fs: "exfat")]).isEmpty)
}

// MARK: Volume cache

private final class CountingLocator: VolumeLocating, @unchecked Sendable {
    private let lock = NSLock()
    private var list: [VolumeInfo]
    private var count = 0
    private var onMain = false
    init(_ list: [VolumeInfo]) { self.list = list }
    var calls: Int { lock.withLock { count } }
    var calledOnMainThread: Bool { lock.withLock { onMain } }
    func set(_ v: [VolumeInfo]) { lock.withLock { list = v } }
    func mounted() -> [VolumeInfo] {
        lock.withLock { count += 1; if Thread.isMainThread { onMain = true }; return list }
    }
}

@MainActor @Test func theCacheIsReadOnceAndNotOnTheMainThread() async {
    let loc = CountingLocator([vol("A")])
    let cache = VolumeCache(locator: loc, center: NotificationCenter(), names: [])
    await cache.refresh()
    #expect(cache.volumes.map(\.uuid) == ["A"])
    _ = cache.volumes; _ = cache.volumes
    #expect(loc.calls == 1)
    #expect(!loc.calledOnMainThread)
}

@MainActor @Test func mountAndUnmountNotificationsRefreshTheCache() async {
    let center = NotificationCenter()
    let mount = Notification.Name("test.mount"), unmount = Notification.Name("test.unmount")
    let loc = CountingLocator([])
    let cache = VolumeCache(locator: loc, center: center, names: [mount, unmount])
    await cache.refresh()
    loc.set([vol("A")])
    center.post(name: mount, object: nil)
    await cache.waitForRefresh()
    #expect(cache.volumes.map(\.uuid) == ["A"])
    loc.set([])
    center.post(name: unmount, object: nil)
    await cache.waitForRefresh()
    #expect(cache.volumes.isEmpty)
}

// MARK: Eject

private final class FakeEjector: VolumeEjecting, @unchecked Sendable {
    var error: (any Error)?
    private let lock = NSLock()
    private var urls: [URL] = []
    private var main = false
    var ejected: [URL] { lock.withLock { urls } }
    var ranOnMain: Bool { lock.withLock { main } }
    func eject(_ mountPoint: URL) async throws {
        lock.withLock { urls.append(mountPoint); if Thread.isMainThread { main = true } }
        if let error { throw error }
    }
}

@MainActor private final class RefreshCounter { var n = 0 }

@MainActor private func ejectController(_ e: FakeEjector, running: Bool, counter: RefreshCounter) -> EjectController {
    EjectController(ejector: e, isBackupRunning: { running }, refresh: { counter.n += 1 })
}

@MainActor @Test func ejectingUnmountsThenRefreshesTheVolumeList() async {
    let e = FakeEjector(), c = RefreshCounter()
    let ctl = ejectController(e, running: false, counter: c)
    await ctl.eject(vol("U"))
    #expect(e.ejected == [URL(fileURLWithPath: "/Volumes/SSD")])
    #expect(!e.ranOnMain)
    #expect(ctl.phase == .idle)
    #expect(c.n == 1)
}

@MainActor @Test func ejectIsBlockedWhileABackupRuns() async {
    let e = FakeEjector(), c = RefreshCounter()
    let ctl = ejectController(e, running: true, counter: c)
    await ctl.eject(vol("U"))
    #expect(e.ejected.isEmpty)
    #expect(ctl.phase == .failed(EjectText.blockedByRun("SSD")))
    #expect(EjectText.blockedByRun("SSD").contains("backup is running"))
}

@MainActor @Test func anEjectErrorHasItsOwnMessageAndIsNotAReconnectError() async {
    let e = FakeEjector(); e.error = CocoaError(.fileWriteVolumeReadOnly)
    let ctl = ejectController(e, running: false, counter: RefreshCounter())
    await ctl.eject(vol("U"))
    #expect(ctl.phase == .failed(EjectText.failed("SSD")))
    #expect(EjectText.failed("SSD") == "Couldn't eject \"SSD\". Something may still be using it.")
    ctl.dismiss()
    #expect(ctl.phase == .idle)
}

// MARK: Visibility of the places that show progress

@Test func progressIsWatchedWhileEitherSurfaceIsVisible() {
    var v = SurfaceVisibility()
    #expect(!v.anyVisible)
    v.appeared(.panel); v.appeared(.window)
    #expect(v.anyVisible)
    v.disappeared(.panel)
    #expect(v.anyVisible)
    v.disappeared(.window)
    #expect(!v.anyVisible)
    v.disappeared(.window)   // a stray second disappear changes nothing
    #expect(!v.anyVisible)
}

@Test func aDriveThatIsAlreadyADestinationCanNotBePickedAgain() {
    struct Loc: VolumeLocating { func mounted() -> [VolumeInfo] { [vol("A", "One"), vol("B", "Two")] } }
    let rows = ExternalDriveSetup.choices(from: Loc(), existing: [drive("a", name: "Work SSD")])
    #expect(rows.count == 2)
    #expect(!rows[0].selectable)
    #expect(rows[0].unavailableReason == "This drive is already a destination called \"Work SSD\".")
    #expect(rows[1].selectable)
}

// MARK: Review items

@Test func otherKindsKeepTheirRuleActions() {
    let secret = ReviewItem(id: "1", path: "a/.env", kind: .secretInExcluded)
    #expect(ReviewActions.rule(for: secret, include: true)?.action == .include)
    #expect(ReviewActions.rule(for: secret, include: false)?.action == .exclude)
    let refused = ReviewItem(id: "2", path: "x.tmp", kind: .refusedByICloud)
    #expect(ReviewActions.rule(for: refused, include: true) == nil)   // iCloud won't take it, so Include is not offered
    #expect(ReviewActions.rule(for: refused, include: false)?.action == .exclude)
}

// MARK: Fix round 1

@Test func aLegacySetWithoutAnAcceptedPreviewShowsAsNeedingOne() {
    let ok = BackupSet(name: "Done", source: URL(fileURLWithPath: "/a"))
    var accepted = ok; accepted.acceptPreview()
    let legacy = BackupSet(name: "Legacy", source: URL(fileURLWithPath: "/b"))
    let backedUp = OverallStatus.backedUp(last: Date(), files: 1)
    #expect(StatusSummary.withPreviewNeeded(backedUp, sets: [accepted]) == backedUp)
    #expect(StatusSummary.withPreviewNeeded(backedUp, sets: [accepted, legacy]) == .attention("Preview needed: Legacy"))
    #expect(StatusSummary.withPreviewNeeded(.attention("Not backed up yet"), sets: [legacy]) == .attention("Preview needed: Legacy"))
    // Problems, held deletions and runs keep their own message; a paused set needs nothing.
    #expect(StatusSummary.withPreviewNeeded(.held(3), sets: [legacy]) == .held(3))
    #expect(StatusSummary.withPreviewNeeded(.attention("Sign-in expired"), sets: [legacy]) == .attention("Sign-in expired"))
    var paused = legacy; paused.isPaused = true
    #expect(StatusSummary.withPreviewNeeded(backedUp, sets: [paused]) == backedUp)
}

@Test func theAgentLockProbeSeesAHeldLockWithoutTakingIt() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("mirror-probe-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(!AgentLockProbe.isHeld(support: root))                      // no file: nothing holds it, and none is created
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("locks/agent.lock").path))
    let lock = RunLock(url: root.appendingPathComponent("locks/agent.lock"))
    #expect(lock.tryAcquire())
    #expect(AgentLockProbe.isHeld(support: root))
    lock.release()
    #expect(!AgentLockProbe.isHeld(support: root))
    let again = RunLock(url: root.appendingPathComponent("locks/agent.lock"))
    #expect(again.tryAcquire())                                          // the probe left it free
}

@MainActor @Test func theCacheSaysItIsLoadingUntilTheFirstRead() async {
    let cache = VolumeCache(locator: CountingLocator([vol("A")]), center: NotificationCenter(), names: [])
    #expect(!cache.hasLoaded)
    await cache.refresh()
    #expect(cache.hasLoaded)
}

@Test func driveChoicesAreReadOffTheMainThread() async {
    let loc = CountingLocator([vol("A")])
    let rows = await ExternalDriveSetup.loadChoices(from: loc, existing: [])
    #expect(rows.count == 1)
    #expect(!loc.calledOnMainThread)
}

@MainActor @Test func aCancelledRevealCanBeTriedAgain() async {
    nonisolated(unsafe) var cancel = true
    let m = KitRevealModel(destination: Destination(name: "Drive", kind: .googleDrive)) { _ in
        if cancel { throw CancellationError() }
        return "KIT"
    }
    await m.begin()
    #expect(m.phase == .cancelled)
    #expect(m.kitText == nil)
    cancel = false
    await m.begin()
    #expect(m.phase == .shown && m.kitText == "KIT")
}

private struct Names: SetNameListing {
    var byDestination: [UUID?: [String]]
    func names(in destination: UUID?) async throws -> [String] {
        guard let list = byDestination[destination] else { throw AgentFailure.driveNotConnected }
        return list
    }
}

@Test func aNameInUseIsFoundWhateverItsCase() async {
    let a = Destination(name: "iCloud", kind: .iCloudFolder), b = Destination(name: "Drive", kind: .googleDrive)
    let names = Names(byDestination: [a.id: ["projects"], b.id: ["Other"]])
    let found = await SetNameConflict.destinations(holding: "Projects", among: [a, b], stored: [a, b], names: names)
    #expect(found == [a])
}

@Test func aDestinationThatCantBeAskedIsLeftToTheRun() async {
    let a = Destination(name: "SSD", kind: .externalDrive)
    let found = await SetNameConflict.destinations(holding: "Projects", among: [a], stored: [a], names: Names(byDestination: [:]))
    #expect(found.isEmpty)
}

@Test func aDestinationNotSavedYetIsAskedAsTheICloudFolder() async {
    let a = Destination(name: "iCloud Drive", kind: .iCloudFolder)
    let found = await SetNameConflict.destinations(holding: "Docs", among: [a], stored: [], names: Names(byDestination: [nil: ["Docs"]]))
    #expect(found == [a])
}

@Test func theConflictWordingNamesTheDestinationsAndWhatAdoptingDoes() {
    let a = Destination(name: "iCloud", kind: .iCloudFolder), b = Destination(name: "SSD", kind: .externalDrive)
    #expect(SetNameConflict.title(name: "Docs", in: [a]) == "\"Docs\" is still in use in iCloud")
    #expect(SetNameConflict.title(name: "Docs", in: [a, b]) == "\"Docs\" is still in use in iCloud and SSD")
    #expect(SetNameConflict.message(name: "Docs").contains("move to the archive"))
}
