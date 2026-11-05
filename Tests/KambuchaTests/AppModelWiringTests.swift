import AppKit
import Testing
import Foundation
import KambuchaCore
@testable import Kambucha

private struct Vols: VolumeLocating {
    var list: [VolumeInfo]
    func mounted() -> [VolumeInfo] { list }
}

private final class NoEject: VolumeEjecting { func eject(_ mountPoint: URL) async throws {} }

private final class SlowEjector: VolumeEjecting {
    func eject(_ mountPoint: URL) async throws { try await Task.sleep(for: .milliseconds(300)) }
}

@MainActor
private func make(volumes: [VolumeInfo] = [], destinations: [Destination] = [], sets: [BackupSet] = [],
                  ejector: any VolumeEjecting = NoEject(), prepare: (ConfigStore, URL) throws -> Void = { _, _ in }) throws -> AppModel {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("kambucha-wiring-\(UUID().uuidString)")
    try ConfigStore(root: root).saveDestinations(destinations)
    try ConfigStore(root: root).saveSets(sets)
    try prepare(ConfigStore(root: root), root)
    let services = AppServices(preview: LivePreviewProvider(binary: URL(fileURLWithPath: "/dev/null")),
                               dryRun: AgentDeletionDryRun(client: AgentArchiveClient(transport: AgentProcessTransport(executable: URL(fileURLWithPath: "/dev/null")))),
                               inspector: nil, volumes: Vols(list: volumes), agent: AgentClient(executable: URL(fileURLWithPath: "/dev/null")),
                               archive: AgentArchiveProvider(client: AgentArchiveClient(transport: AgentProcessTransport(executable: URL(fileURLWithPath: "/dev/null")))),
                               ejector: ejector)
    let model = AppModel(support: root, services: services)
    return model
}

private func vol(_ uuid: String, internalLooking: Bool = false) -> VolumeInfo {
    VolumeInfo(uuid: uuid, name: "SSD", mountPoint: URL(fileURLWithPath: "/Volumes/SSD"), fileSystem: "apfs",
               freeBytes: 1, looksInternal: internalLooking)
}

@MainActor struct AppModelWiringTests {
    @Test func theProgressFolderIsWatchedWhileEitherSurfaceIsOpen() throws {
        let m = try make()
        #expect(!m.isWatchingProgress)
        m.windowAppeared()
        #expect(m.isWatchingProgress)
        m.panelAppeared(); m.windowDisappeared()
        #expect(m.isWatchingProgress)
        m.panelDisappeared()
        #expect(!m.isWatchingProgress)
    }

    /// One set uploading mustn't make every other set read as running, or the Overview loses their last backup.
    @Test func onlyTheSetWithLiveProgressReadsAsRunning() throws {
        let d = Destination(name: "iCloud", kind: .iCloudFolder)
        let busy = BackupSet(name: "Busy", source: URL(fileURLWithPath: "/tmp/busy"), destinationIDs: [d.id])
        let calm = BackupSet(name: "Calm", source: URL(fileURLWithPath: "/tmp/calm"), destinationIDs: [d.id])
        var accepted = [busy, calm]; for i in accepted.indices { accepted[i].acceptPreview() }
        let m = try make(destinations: [d], sets: accepted) { store, root in
            for s in accepted {
                var st = SetState(); st.lastFinished = Date(); st.lastFileCount = 1
                try store.save(st, for: PairID(set: s.id, destination: d.id))
            }
            try AgentPresence.record(for: getpid()).write(to: root.appendingPathComponent(AgentPresence.fileName), atomically: true, encoding: .utf8)
            try ProgressStore(root: root).write(TransferProgress(pair: PairID(set: busy.id, destination: d.id), phase: .transferring, bytesDone: 1, updated: Date()))
        }
        m.reload()
        let status = Dictionary(uniqueKeysWithValues: m.rows.map { ($0.name, $0.status) })
        #expect(status["Busy"] == .running)
        guard case .backedUp = status["Calm"] else { Issue.record("expected Calm backed up, got \(String(describing: status["Calm"]))"); return }
        #expect(m.status == .running)
    }

    @Test func nMoreInThePanelAsksForTheOverview() throws {
        let m = try make()
        let before = m.overviewRequests
        m.showOverview()
        #expect(m.overviewRequests == before + 1)
    }

    @Test func openingAMenuCountsAsLookingAtTheStatus() throws {
        let m = try make()
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: nil)
        #expect(m.isWatchingProgress)
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: nil)
        #expect(!m.isWatchingProgress)
    }

    @Test func aMenuItemStaysOneShortLine() {
        #expect(MenuText.short("Short.") == "Short.")
        #expect(MenuText.short("The backup agent stopped with code 1. Then a long story.") == "The backup agent stopped with code 1")
        let long = MenuText.short(String(repeating: "word ", count: 40))
        #expect(long.count <= MenuText.limit && long.hasSuffix("…"))
    }

    @Test func aRunningPairReadsAsOneMenuLine() {
        let pair = PairID(set: UUID(), destination: UUID())
        var p = TransferProgress(pair: pair, phase: .transferring, bytesDone: 1, updated: Date())
        p.bytesPerSecond = 3_000_000
        let line = ProgressPresentation(progress: p).menuLine(label: "Docs to iCloud Drive")
        #expect(line.hasPrefix("Docs to iCloud Drive: "))
        #expect(line.contains("MB/s"))
    }

    @Test func aSecondDestinationForTheSameDriveIsRefused() throws {
        let first = Destination(name: "A", kind: .externalDrive, encrypted: false, volumeUUID: "UUID-1")
        let m = try make(destinations: [first])
        m.save(destination: Destination(name: "B", kind: .externalDrive, encrypted: false, volumeUUID: "uuid-1"))
        #expect(m.destinations.count == 1)
        #expect(m.lastError == "This drive is already a destination called \"A\".")
        // Saving the same destination again (an edit) is fine.
        var edited = first; edited.internalDiskConfirmed = true
        m.save(destination: edited)
        #expect(m.destinations.first?.internalDiskConfirmed == true)
    }

    @Test func anUnconfirmedInternalLookingDriveShowsAsNeedingConfirmation() async throws {
        let d = Destination(name: "SSD", kind: .externalDrive, encrypted: false, volumeUUID: "U")
        let m = try make(volumes: [vol("U", internalLooking: true)], destinations: [d])
        await m.volumeCache.refresh()
        #expect(m.destinationStatus(d).text == "Confirm this internal disk")
        m.save(destination: ExternalDriveSetup.confirmed(d))
        #expect(m.destinationStatus(m.destinations[0]).text != "Confirm this internal disk")
    }

    @Test func aDriveThatWasNeverConnectedReadsNotConnectedYet() async throws {
        let d = Destination(name: "SSD", kind: .externalDrive, encrypted: false, volumeUUID: "U")
        let m = try make(destinations: [d], sets: [BackupSet(name: "A", source: URL(fileURLWithPath: "/tmp/a"), destinationIDs: [d.id])])
        await m.volumeCache.refresh()
        #expect(m.destinationStatus(d).text == "Not connected yet")
    }

    @Test func theStatusFollowsTheDriveBeingConnected() async throws {
        let d = Destination(name: "SSD", kind: .externalDrive, encrypted: false, volumeUUID: "U")
        var s = BackupSet(name: "A", source: URL(fileURLWithPath: "/tmp/a"), destinationIDs: [d.id])
        s.acceptPreview()
        let m = try make(destinations: [d], sets: [s]) { store, _ in
            var st = SetState(); st.lastFinished = Date(); st.syncIncomplete = true
            try store.save(st, for: PairID(set: s.id, destination: d.id))
        }
        await m.volumeCache.refresh()
        m.reload()
        guard case .driveNotConnected(let name, _) = m.status else { Issue.record("was \(m.status)"); return }
        #expect(name == "SSD")
    }

    @Test func aDriveThatIsNotMountedIsNotConnected() async throws {
        let d = Destination(name: "SSD", kind: .externalDrive, encrypted: false, volumeUUID: "U")
        let m = try make(destinations: [d])
        await m.volumeCache.refresh()
        #expect(m.destinationStatus(d).text.hasPrefix("Not connected"))
    }

    // MARK: Overview decides a destination from one value

    private func unplugged(_ change: (inout SetState) -> Void) async throws -> OverviewDestination {
        let d = Destination(name: "SSD", kind: .externalDrive, encrypted: false, volumeUUID: "U")
        var s = BackupSet(name: "A", source: URL(fileURLWithPath: "/tmp/a"), destinationIDs: [d.id])
        s.acceptPreview()
        let m = try make(destinations: [d], sets: [s]) { store, _ in
            var st = SetState(); st.lastFinished = Date()
            change(&st)
            try store.save(st, for: PairID(set: s.id, destination: d.id))
        }
        await m.volumeCache.refresh()
        return try #require(m.overviewDestinations.first)
    }

    @Test func aDrivePulledMidRunIsOnlyNotConnected() async throws {
        let row = try await unplugged { $0.syncIncomplete = true }
        #expect(row.standing == .notConnected)
        #expect(row.status.text.hasPrefix("Not connected"))
    }

    @Test func aRealProblemOnADriveThatIsAwayKeepsItsOwnWords() async throws {
        let row = try await unplugged { $0.consecutiveFailures = 2 }
        #expect(row.standing == .attention)
        #expect(row.status.text == "Needs attention")
    }

    @Test func aWarningOnTheDestinationScreenNeedsAttention() throws {
        let d = Destination(name: "Cloud", kind: .iCloudFolder, encrypted: true)
        let m = try make(destinations: [d])
        #expect(m.overviewDestinations.first?.standing == .attention)
    }

    // MARK: Destination status says what's true (final review B1)

    private func destinationText(_ change: (inout SetState) -> Void) throws -> DestinationStatus {
        let d = Destination(name: "iCloud", kind: .iCloudFolder)
        var s = BackupSet(name: "Docs", source: URL(fileURLWithPath: "/tmp/docs"), destinationIDs: [d.id])
        s.acceptPreview()
        let m = try make(destinations: [d], sets: [s]) { store, _ in
            var st = SetState()
            st.lastFinished = Date()
            change(&st)
            try store.save(st, for: PairID(set: s.id, destination: d.id))
        }
        return m.destinationStatus(d)
    }

    @Test func aFinishedDestinationWithNothingOwedIsBackedUp() throws {
        let status = try destinationText { _ in }
        #expect(status.text.hasPrefix("Backed up"))
        #expect(status.symbol == "checkmark.circle")
    }

    @Test func aDestinationStillUploadingIsNotBackedUp() throws {
        let status = try destinationText { $0.pendingUploads = 12 }
        #expect(status.text == "Uploading 12 files")
        #expect(status.symbol != "checkmark.circle")
    }

    @Test func aDestinationHoldingDeletionsSaysSo() throws {
        let status = try destinationText { $0.heldDeletions = 1 }
        #expect(status.text == "1 deletion held")
        #expect(status.symbol == "pause.circle")
    }

    @Test func aDestinationWithRefusedFilesSaysSo() throws {
        let status = try destinationText { $0.refusedSince = ["a.tmp": Date(), "b.tmp": Date()] }
        #expect(status.text == StatusSummary.notAcceptedText(count: 2))
        #expect(status.symbol != "checkmark.circle")
    }

    @Test func aDestinationWithMismatchesSaysSo() throws {
        let status = try destinationText { $0.mismatched = ["a.txt": Mismatch(since: Date())] }
        #expect(status.text == "1 file didn't match")
        #expect(status.symbol != "checkmark.circle")
    }

    @Test func aStoppedDestinationSaysWhatStoppedIt() throws {
        let status = try destinationText { $0.stoppedBy = .iCloudUnavailable }
        #expect(status.text == Problem.iCloudUnavailable.headline)
        #expect(status.symbol != "checkmark.circle")
    }

    @Test func anUnfinishedDestinationIsNotBackedUp() throws {
        for change: (inout SetState) -> Void in [{ $0.syncIncomplete = true }, { $0.wholeSetOwed = true },
                                                 { $0.verifyOwed = ["a"] }, { $0.hashWholeSet = true }] {
            #expect(try destinationText(change).text == "Backup not finished")
        }
    }

    @Test func oneUnfinishedPairStopsTheWholeDestinationReadingBackedUp() throws {
        let d = Destination(name: "iCloud", kind: .iCloudFolder)
        var a = BackupSet(name: "A", source: URL(fileURLWithPath: "/tmp/a"), destinationIDs: [d.id])
        var b = BackupSet(name: "B", source: URL(fileURLWithPath: "/tmp/b"), destinationIDs: [d.id])
        a.acceptPreview(); b.acceptPreview()
        let m = try make(destinations: [d], sets: [a, b]) { store, _ in
            var st = SetState(); st.lastFinished = Date()
            try store.save(st, for: PairID(set: a.id, destination: d.id))
        }
        #expect(m.destinationStatus(d).text == "Not backed up yet")
    }

    @Test func aPausedSetDoesNotSpeakForADestination() throws {
        let d = Destination(name: "iCloud", kind: .iCloudFolder)
        var a = BackupSet(name: "A", source: URL(fileURLWithPath: "/tmp/a"), destinationIDs: [d.id])
        a.acceptPreview(); a.isPaused = true
        let m = try make(destinations: [d], sets: [a]) { store, _ in
            var st = SetState(); st.lastFinished = Date(); st.pendingUploads = 3
            try store.save(st, for: PairID(set: a.id, destination: d.id))
        }
        #expect(m.destinationStatus(d).text == "Paused")
    }

    @Test func aSetWaitingForItsPreviewIsNotBackedUp() throws {
        let d = Destination(name: "iCloud", kind: .iCloudFolder)
        let a = BackupSet(name: "A", source: URL(fileURLWithPath: "/tmp/a"), destinationIDs: [d.id])
        let m = try make(destinations: [d], sets: [a]) { store, _ in
            var st = SetState(); st.lastFinished = Date()
            try store.save(st, for: PairID(set: a.id, destination: d.id))
        }
        #expect(m.destinationStatus(d).text == "Preview needed")
    }

    @Test func anUndecidedTrackedFolderStaysListedAndIncludingItSavesTheFolderRule() throws {
        let dest = Destination(name: "iCloud", kind: .iCloudFolder)
        let set = BackupSet(name: "Docs", source: URL(fileURLWithPath: "/tmp/docs"), destinationIDs: [dest.id])
        let item = ReviewItem(id: "tracked:proj/vendor", path: "proj/vendor", kind: .trackedInExcluded)
        let m = try make(destinations: [dest], sets: [set]) { store, _ in
            var st = SetState(); st.reviewItems = [item]
            try store.save(st, for: PairID(set: set.id, destination: dest.id))
        }
        #expect(m.reviewEntries.count == 1)
        m.resolve(m.reviewEntries[0], include: true)
        #expect(m.set(set.id)?.rules.map(\.pattern) == ["/proj/vendor/**"])
        #expect(m.reviewEntries.isEmpty)
    }

    // MARK: Allow Once while a run holds the lock (final review S10)

    private func heldModel() throws -> (AppModel, BackupSet) {
        let d = Destination(name: "iCloud", kind: .iCloudFolder)
        let s = BackupSet(name: "A", source: URL(fileURLWithPath: "/tmp/a"), destinationIDs: [d.id])
        return (try make(destinations: [d], sets: [s]), s)
    }

    @Test func allowOnceWaitsForARunningBackupAndKeepsTheSheet() throws {
        let (m, s) = try heldModel()
        m.allowDeletes(s.id)
        let lock = RunLock(url: m.support.appendingPathComponent("locks/agent.lock"))
        #expect(lock.tryAcquire())
        defer { lock.release() }
        #expect(!m.allowOnce(arguments: ["--allow-deletes"]))
        #expect(m.reviewingSet == s.id)
        #expect(m.reviewNotice == "A backup is running. Try again shortly.")
    }

    @Test func theNoticeEndsWithTheReview() throws {
        let (m, s) = try heldModel()
        m.allowDeletes(s.id)
        let lock = RunLock(url: m.support.appendingPathComponent("locks/agent.lock"))
        #expect(lock.tryAcquire())
        #expect(!m.allowOnce(arguments: ["--allow-deletes"]))
        lock.release()
        m.keepHolding()
        #expect(m.reviewNotice == nil)
    }

    @Test func aBusyExitAfterTheSheetClosedBringsItBack() throws {
        let (m, s) = try heldModel()
        m.agentExited(code: AgentExit.busy, tail: "", reviewing: s.id)
        #expect(m.reviewingSet == s.id)
        #expect(m.reviewNotice == "A backup is running. Try again shortly.")
    }

    @Test func aBusyExitWithNothingToReviewIsPlainlySaid() throws {
        let (m, _) = try heldModel()
        m.agentExited(code: AgentExit.busy, tail: "", reviewing: nil)
        #expect(m.lastError == "A backup is running. Try again shortly.")
    }

    @Test func anotherExitStillReportsItsCode() throws {
        let (m, _) = try heldModel()
        m.agentExited(code: 1, tail: "why", reviewing: nil)
        #expect(m.lastError == "The backup agent stopped with code 1. why")
    }

    // MARK: Problems end with their pair (final review S5)

    private func activeProblems(_ m: AppModel) throws -> [Problem] {
        try ProblemCenter(root: m.support, notifier: NoNotifier()).active().map(\.problem)
    }

    private func modelWithProblem() throws -> (AppModel, BackupSet, Destination, Destination) {
        let a = Destination(name: "A", kind: .iCloudFolder), b = Destination(name: "B", kind: .googleDrive, encrypted: false)
        var s = BackupSet(name: "Docs", source: URL(fileURLWithPath: "/tmp/docs"), destinationIDs: [a.id, b.id])
        s.acceptPreview()
        let m = try make(destinations: [a, b], sets: [s]) { _, root in
            try ProblemCenter(root: root, notifier: NoNotifier()).store(.verificationFailed, pair: PairID(set: s.id, destination: b.id),
                                                                        setName: "Docs", detail: "d")
        }
        return (m, s, a, b)
    }

    @Test func removingASetClearsItsProblems() throws {
        let (m, s, _, _) = try modelWithProblem()
        m.removeSet(s.id)
        #expect(try activeProblems(m).isEmpty)
    }

    @Test func removingADestinationClearsItsProblems() throws {
        let (m, _, _, b) = try modelWithProblem()
        m.removeDestination(b.id)
        #expect(try activeProblems(m).isEmpty)
    }

    @Test func untickingADestinationClearsItsProblems() throws {
        let (m, s, a, _) = try modelWithProblem()
        var updated = s; updated.destinationIDs = [a.id]
        m.save(set: updated)
        #expect(try activeProblems(m).isEmpty)
    }

    @Test func savingALivePairLeavesItsProblemOpen() throws {
        let (m, s, _, _) = try modelWithProblem()
        m.save(set: s)
        #expect(try activeProblems(m) == [.verificationFailed])
    }

    @Test func includingDuringARunQueuesARunForAfterIt() throws {
        let dest = Destination(name: "iCloud", kind: .iCloudFolder)
        var set = BackupSet(name: "Docs", source: URL(fileURLWithPath: "/tmp/docs"), destinationIDs: [dest.id])
        set.acceptPreview()
        let item = ReviewItem(id: "t", path: "vendor", kind: .trackedInExcluded)
        let m = try make(destinations: [dest], sets: [set]) { store, root in
            var st = SetState(); st.reviewItems = [item]
            try store.save(st, for: PairID(set: set.id, destination: dest.id))
            try "\(getpid())\n".write(to: root.appendingPathComponent(AgentPresence.fileName), atomically: true, encoding: .utf8)
        }
        #expect(m.isBackupActive)
        m.resolve(m.reviewEntries[0], include: true)
        #expect(m.queuedRuns == [set.id])
        m.reload()
        #expect(m.queuedRuns == [set.id])   // still running, so it waits
        try FileManager.default.removeItem(at: m.support.appendingPathComponent(AgentPresence.fileName))
        m.reload()
        #expect(m.queuedRuns.isEmpty)
    }

    @Test func resolvingAReviewItemKeepsAnAcceptedSetAccepted() throws {
        let dest = Destination(name: "iCloud", kind: .iCloudFolder)
        var set = BackupSet(name: "Docs", source: URL(fileURLWithPath: "/tmp/docs"), destinationIDs: [dest.id])
        set.acceptPreview()
        let item = ReviewItem(id: "1", path: "vendor/.env", kind: .secretInExcluded)
        let m = try make(destinations: [dest], sets: [set]) { store, _ in
            var st = SetState(); st.reviewItems = [item]
            try store.save(st, for: PairID(set: set.id, destination: dest.id))
        }
        let entry = try #require(m.reviewEntries.first)
        m.resolve(entry, include: false)
        #expect(m.sets[0].rules.count == 1)
        #expect(m.sets[0].isPreviewAccepted)
    }

    @Test func resolvingAReviewItemDoesNotAcceptASetThatWasNeverAccepted() throws {
        let dest = Destination(name: "iCloud", kind: .iCloudFolder)
        let set = BackupSet(name: "Docs", source: URL(fileURLWithPath: "/tmp/docs"), destinationIDs: [dest.id])
        let item = ReviewItem(id: "1", path: "vendor/.env", kind: .secretInExcluded)
        let m = try make(destinations: [dest], sets: [set]) { store, _ in
            var st = SetState(); st.reviewItems = [item]
            try store.save(st, for: PairID(set: set.id, destination: dest.id))
        }
        m.resolve(try #require(m.reviewEntries.first), include: true)
        #expect(!m.sets[0].isPreviewAccepted)
    }

    @Test func aLegacySetShowsPreviewNeededInTheStatus() throws {
        let dest = Destination(name: "iCloud", kind: .iCloudFolder)
        let set = BackupSet(name: "Docs", source: URL(fileURLWithPath: "/tmp/docs"), destinationIDs: [dest.id])
        let m = try make(destinations: [dest], sets: [set]) { store, _ in
            var st = SetState(); st.lastFinished = Date()
            try store.save(st, for: PairID(set: set.id, destination: dest.id))
        }
        #expect(m.status == .attention("Preview needed: Docs"))
    }

    @Test func theRunningFlagIsReadWhenStateIsLoadedNotPerRender() throws {
        let m = try make { _, root in
            try "\(getpid())\n".write(to: root.appendingPathComponent(AgentPresence.fileName), atomically: true, encoding: .utf8)
        }
        #expect(m.isBackupActive)
        // Removing the file changes nothing until the next refresh: reads of the flag touch no file.
        try? FileManager.default.removeItem(at: m.support.appendingPathComponent(AgentPresence.fileName))
        #expect(m.isBackupActive)
    }

    @Test func aBackupDoesNotStartWhileADriveIsBeingEjected() async throws {
        let m = try make(ejector: SlowEjector())
        let v = VolumeInfo(uuid: "U", name: "SSD", mountPoint: URL(fileURLWithPath: "/Volumes/SSD"), fileSystem: "apfs", freeBytes: 1)
        async let ejecting: Void = m.eject.eject(v)
        try await Task.sleep(for: .milliseconds(60))
        m.runNow(nil)
        #expect(m.lastError?.contains("eject") == true)
        await ejecting
    }

    private func dockItems(_ m: AppModel) -> [(title: String, enabled: Bool)] {
        DockMenu(model: m).menu.items.map { ($0.title, $0.isEnabled) }
    }

    @Test func theDockMenuFollowsTheMenuBarRules() throws {
        let empty = try make()
        #expect(dockItems(empty).map(\.title) == ["Back Up Now", "Pause Backups"])
        #expect(dockItems(empty).map(\.enabled) == [empty.canBackUp, false])

        let d = Destination(name: "iCloud", kind: .iCloudFolder)
        let m = try make(destinations: [d], sets: [BackupSet(name: "A", source: URL(fileURLWithPath: "/tmp/a"), destinationIDs: [d.id])])
        #expect(dockItems(m).map(\.enabled) == [m.canBackUp, true])
    }

    @Test func theDockMenuPausesAndResumes() throws {
        let d = Destination(name: "iCloud", kind: .iCloudFolder)
        let m = try make(destinations: [d], sets: [BackupSet(name: "A", source: URL(fileURLWithPath: "/tmp/a"), destinationIDs: [d.id])])
        let dock = DockMenu(model: m)
        let item = dock.menu.items[1]
        _ = (item.target as? NSObject)?.perform(item.action)
        #expect(m.isPaused)
        #expect(dockItems(m)[1].title == "Resume Backups")
        #expect(dockItems(m)[0].enabled == m.canBackUp)
    }
}
