import Foundation

/// `archive-list`, `archive-restore` and `dry-run-deletions`: read-only looks at a destination, and restores out of
/// it. They live in the agent because an encrypted destination needs secrets, and the app never holds those.
/// Sets and destinations come from the stored config, so a request can only name them.
struct AgentRecovery: Sendable {
    let store: ConfigStore
    let tokenLock: URL
    let secrets: any SecretStoring
    let binary: URL
    let trust: any AgentTrust
    let workDir: URL
    let volumes: any VolumeLocating
    let iCloudDrive: URL
    let presets: @Sendable () throws -> [Preset]

    private var rclone: RcloneRunner { RcloneRunner(binary: binary, helper: trust) }

    func answer(_ subcommand: String, _ input: Data) async throws -> AgentWire.Response {
        let decoder = JSONDecoder()
        switch subcommand {
        case AgentWire.archiveList:
            guard let r = try? decoder.decode(AgentWire.PairRequest.self, from: input) else { throw AgentFailure.invalidRequest }
            return try await list(r)
        case AgentWire.archiveRestore:
            guard let r = try? decoder.decode(AgentWire.RestoreRequest.self, from: input) else { throw AgentFailure.invalidRequest }
            return try await restore(r)
        case AgentWire.dryRunDeletions:
            guard let r = try? decoder.decode(AgentWire.PairRequest.self, from: input) else { throw AgentFailure.invalidRequest }
            return try await dryRun(r)
        default:
            throw AgentFailure.invalidRequest
        }
    }

    // MARK: The destination

    private struct Access {
        var endpoint: String
        var context: RcloneContext
        var session: RcloneSession?
        var volume: VolumeInfo?
        /// The backup root on this Mac, for what's read straight from disk.
        var localRoot: URL?
    }

    private func resolve(set id: UUID, destination: UUID) throws -> (BackupSet, Destination) {
        guard let sets = try? store.loadSets(), let destinations = try? store.loadDestinations() else { throw AgentFailure.configUnreadable }
        guard let set = sets.first(where: { $0.id == id }), set.destinationIDs.contains(destination),
              let found = destinations.first(where: { $0.id == destination }) else { throw AgentFailure.notFound }
        return (set, found)
    }

    /// No source check, as a restore is often why the source is gone. Only the guard gives a drive's path.
    private func open(_ destination: Destination) throws -> Access {
        let local = RcloneContext(configPath: "/dev/null", environment: [:])
        switch destination.kind {
        case .iCloudFolder:
            let root = MirrorPaths.backupRoot(iCloudDrive: iCloudDrive)
            return Access(endpoint: root.path, context: local, localRoot: root)
        case .externalDrive:
            guard let volume = ExternalVolume.find(destination, in: volumes.mounted()) else { throw AgentFailure.driveNotConnected }
            let root = try PathGuard.forVolume(volume, iCloudDrive: iCloudDrive).driveRoot(destination, volume: volume)
            return Access(endpoint: root.path, context: local, volume: volume, localRoot: root.url)
        case .googleDrive, .oneDrive:
            let session = RcloneSession(destination: destination, secrets: secrets, binary: binary, helper: trust, workDir: workDir,
                                        tokenLock: tokenLock)
            let (endpoint, context) = try session.open()
            return Access(endpoint: endpoint, context: context, session: session)
        }
    }

    /// Closes a session whatever happens, as it holds a sign-in on disk.
    private func withAccess<T>(_ destination: Destination, _ body: (Access) async throws -> T) async throws -> T {
        let access = try open(destination)
        do {
            let result = try await body(access)
            try access.session?.close()
            return result
        } catch {
            try? access.session?.close()
            throw error
        }
    }

    // MARK: Commands

    private func list(_ r: AgentWire.PairRequest) async throws -> AgentWire.Response {
        let (set, destination) = try resolve(set: r.set, destination: r.destination)
        let entries = try await withAccess(destination) { access in
            try await ArchiveManager(rclone: rclone, endpoint: access.endpoint, context: access.context, kind: destination.kind).list(set: set)
        }
        return AgentWire.Response(ok: true, entries: entries.map {
            AgentWire.Entry(id: $0.id, setName: $0.setName, stamp: $0.stamp, path: $0.path, size: $0.size)
        })
    }

    private func restore(_ r: AgentWire.RestoreRequest) async throws -> AgentWire.Response {
        let (set, destination) = try resolve(set: r.set, destination: r.destination)
        try ArchiveScope.checkName(set.name)
        // `..` is refused outright. `PathGuard` resolves it, but only after the name has already been trusted.
        guard r.to.hasPrefix("/"), !r.to.contains("\0"), !r.to.split(separator: "/").contains(".."),
              Self.isInside(set, r.path) else { throw AgentFailure.invalidRequest }
        let sources = ((try? store.loadSets()) ?? [set]).map(\.source)
        try await withAccess(destination) { access in
            let from = ArchiveScope.join(access.endpoint, r.path)
            // The endpoint pins it: the backup root, or the crypt remote, whose names and contents are decrypted.
            let service = RestoreService(rclone: rclone, backupRoot: access.endpoint)
            let manifest = access.localRoot.flatMap { try? SymlinkManifest.read(set: set.name, backupRoot: $0) }
            let mirror = MirrorPaths.mirrorPath(set)
            let inMirror = r.path == mirror || r.path.hasPrefix(mirror + "/")
            let result = try await service.restore(
                from: from, context: access.context, to: URL(fileURLWithPath: r.to), sources: sources,
                asFile: try await isFile(from, context: access.context),
                manifest: inMirror ? manifest : nil,
                manifestSubpath: inMirror ? String(r.path.dropFirst(mirror.count + 1)) : "")
            switch result.outcome {
            case .success: break
            case .authExpired: throw RcloneSessionError.notSignedIn
            default: throw AgentFailure.restoreFailed
            }
        }
        return AgentWire.Response(ok: true)
    }

    /// `Archive/<set>/...` or `Sets/<set>[/...]` of this set, and nothing that climbs back out.
    private static func isInside(_ set: BackupSet, _ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, parts[1] == set.name, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return false }
        return parts[0] == "Sets" || (parts[0] == ArchiveScope.folder && parts.count >= 3)
    }

    /// A save panel names a file, and `rclone copy` would make a folder of that name.
    private func isFile(_ path: String, context: RcloneContext) async throws -> Bool {
        let out = try await rclone.capture(["lsjson", "--stat", "--links", "--use-json-log", "--config", context.configPath, "--", path], context: context)
        if RcloneLogParser.outcome(exitCode: out.exitCode, log: Data(out.stderr.utf8)) == .authExpired { throw RcloneSessionError.notSignedIn }
        guard out.exitCode == 0, let item = (try? JSONSerialization.jsonObject(with: Data(out.stdout.utf8))) as? [String: Any],
              let isDirectory = item["IsDir"] as? Bool else { throw AgentFailure.notFound }
        return !isDirectory
    }

    /// The same dry run as a run's deletion check, so the owner reviews what the gate counts: nothing under `.git`.
    private func dryRun(_ r: AgentWire.PairRequest) async throws -> AgentWire.Response {
        let (set, destination) = try resolve(set: r.set, destination: r.destination)
        try ArchiveScope.checkName(set.name)
        let known = try presets()
        let filters = FilterBuilder(presets: known)
        let dir = try RcloneTool.makePrivateDirectory(in: workDir)
        defer { try? FileManager.default.removeItem(at: dir) }
        let filter = dir.appendingPathComponent("filter.txt")
        try filters.write(filters.lines(for: set, projects: StackDetector(presets: known).detect(in: set.source), scope: nil), to: filter)
        let files = try await withAccess(destination) { access in
            var profile = DestinationProfile.profile(for: destination, fileSystem: access.volume?.fileSystem)
            profile.retries = 1   // someone is waiting on this, and rclone's retries sleep for a minute
            let request = SyncRequest(
                source: set.source, destination: ArchiveScope.join(access.endpoint, MirrorPaths.mirrorPath(set)),
                backupDir: ArchiveScope.join(access.endpoint, MirrorPaths.archivePath(set, stamp: ArchiveScope.stampString(Date()))),
                filterFile: filter, logFile: dir.appendingPathComponent("dry-run.log"), mode: .mirror(maxDelete: -1),
                profile: profile, context: access.context, dryRun: true)
            let result = try await rclone.sync(request)
            switch result.outcome {
            case .success: return result.summary.deleted
            case .authExpired: throw RcloneSessionError.notSignedIn
            default: throw AgentFailure.archive
            }
        }
        return AgentWire.Response(ok: true, files: files.filter { !DeletionGate.isUnderGit($0) }.sorted())
    }
}
