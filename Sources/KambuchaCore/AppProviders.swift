import Foundation

// The real services behind the main window. The screens take protocols (SharedViewTypes, MainWindowLogic);
// these are the implementations the app wires in. Kambucha.app never reads the Keychain, so anything that needs a
// secret goes through the agent.

// MARK: Agent calls for archive, restore and the deletion list

/// How the app reaches the agent for the three read and restore commands. The request body is JSON on stdin and the
/// answer is JSON on stdout, exactly like the secret commands. A body holds identifiers and paths only, never a secret.
public protocol AgentTransport: Sendable {
    func call(subcommand: String, body: Data) async throws -> Data
}

/// Spawns the bundled agent with `subcommand` as its one argument. Cancelling the task stops it.
public struct AgentProcessTransport: AgentTransport {
    public let executable: URL
    public init(executable: URL) { self.executable = executable }

    public func call(subcommand: String, body: Data) async throws -> Data {
        guard body.count < RcloneTool.maxStdin else { throw AgentClientError.requestTooLarge }
        let (code, output) = try await RcloneTool.execute(
            [subcommand], binary: executable, helper: nil,
            context: RcloneContext(configPath: "/dev/null", environment: [:]),
            stdin: body, capture: true, killGrace: AgentClient.killGrace)
        // An answer counts only with exit code 0, or with an explicit `ok` or `failure` of its own; a crash or a stray
        // non-zero exit never reads as success.
        let answer = try? JSONDecoder().decode(AgentWire.Response.self, from: output)
        guard code == 0 || answer?.ok != nil || answer?.failure != nil else { throw AgentClientError.noResponse(exitCode: code) }
        if output.isEmpty { throw AgentClientError.noResponse(exitCode: code) }
        return output
    }
}

/// What the archive and deletion-list providers need from the agent. Injected so they can be tested with fakes.
public protocol ArchiveAgentCalling: Sendable {
    func archiveList(set: UUID, destination: UUID) async throws -> [ArchiveEntry]
    /// `path` is the entry's path below the backup root (`Archive/<set>/<stamp>/...`). The agent pins the backup root
    /// itself, or the crypt endpoint for an encrypted destination.
    func archiveRestore(set: UUID, destination: UUID, path: String, to: URL, replacing: Bool) async throws
    func setList(set: UUID, destination: UUID, path: String) async throws -> [BackupItem]
    func dryRunDeletions(set: UUID, destination: UUID) async throws -> HeldFiles
}

/// Subcommands `archive-list`, `archive-restore` and `dry-run-deletions`.
///
/// The shapes are `AgentWire`. An answer needs `ok: true`; `failure` is thrown as the same typed error the agent hit.
public struct AgentArchiveClient: ArchiveAgentCalling {
    private let transport: any AgentTransport
    public init(transport: any AgentTransport) { self.transport = transport }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.withoutEscapingSlashes]; return e
    }
    private static var decoder: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }

    private func ask<B: Encodable>(_ subcommand: String, _ body: B) async throws -> AgentWire.Response {
        let output = try await transport.call(subcommand: subcommand, body: try Self.encoder.encode(body))
        guard let answer = try? Self.decoder.decode(AgentWire.Response.self, from: output) else {
            throw AgentClientError.noResponse(exitCode: 0)
        }
        if let failure = answer.failure { throw failure.underlying }
        guard answer.ok == true else { throw AgentClientError.noResponse(exitCode: 0) }
        return answer
    }

    public func archiveList(set: UUID, destination: UUID) async throws -> [ArchiveEntry] {
        let answer = try await ask(AgentWire.archiveList, AgentWire.PairRequest(set: set, destination: destination))
        guard let entries = answer.entries else { throw AgentClientError.noResponse(exitCode: 0) }
        return entries.map { ArchiveEntry(id: $0.id, setName: $0.setName, stamp: $0.stamp, path: $0.path, size: $0.size) }
    }

    public func archiveRestore(set: UUID, destination: UUID, path: String, to: URL, replacing: Bool = false) async throws {
        _ = try await ask(AgentWire.archiveRestore, AgentWire.RestoreRequest(set: set, destination: destination, path: path, to: to.path, replacing: replacing))
    }

    public func setList(set: UUID, destination: UUID, path: String) async throws -> [BackupItem] {
        let answer = try await ask(AgentWire.setList, AgentWire.BrowseRequest(set: set, destination: destination, path: path))
        guard let items = answer.items else { throw AgentClientError.noResponse(exitCode: 0) }
        return items
    }

    public func dryRunDeletions(set: UUID, destination: UUID) async throws -> HeldFiles {
        let answer = try await ask(AgentWire.dryRunDeletions, AgentWire.PairRequest(set: set, destination: destination))
        guard let files = answer.files else { throw AgentClientError.noResponse(exitCode: 0) }
        return HeldFiles(files: files, gitCount: answer.gitFiles ?? 0)
    }
}

extension AgentArchiveClient: SetNameListing {
    public func names(in destination: UUID?) async throws -> [String] {
        let answer = try await ask(AgentWire.setNames, AgentWire.NamesRequest(destination: destination))
        guard let files = answer.files else { throw AgentClientError.noResponse(exitCode: 0) }
        return files
    }
}

public struct AgentArchiveProvider: ArchiveProviding {
    private let client: any ArchiveAgentCalling
    public init(client: any ArchiveAgentCalling) { self.client = client }

    public func list(set: BackupSet, destination: Destination) async throws -> [ArchiveEntry] {
        try await client.archiveList(set: set.id, destination: destination.id)
    }

    public func browse(path: String, set: BackupSet, destination: Destination) async throws -> [BackupItem] {
        try await client.setList(set: set.id, destination: destination.id, path: path)
    }

    public func restore(entry: ArchiveEntry, set: BackupSet, destination: Destination, to: URL, replacing: Bool) async throws {
        try await client.archiveRestore(set: set.id, destination: destination.id, path: entry.path, to: to, replacing: replacing)
    }
}

/// The files a held backup to one destination would remove, from the agent's dry run.
public struct AgentDeletionDryRun: DeletionDryRunProviding {
    private let client: any ArchiveAgentCalling
    public init(client: any ArchiveAgentCalling) { self.client = client }

    public func heldDeletions(set: BackupSet, destination: Destination) async throws -> HeldFiles {
        var held = try await client.dryRunDeletions(set: set.id, destination: destination.id)
        held.files.sort()
        return held
    }
}

// MARK: Preview

/// The preview, built by `PreviewBuilder` over the bundled rclone. Nothing here is secret: the source is local, so the
/// runner is the local-only one (config `/dev/null`, empty environment) and needs no sign-in.
public struct LivePreviewProvider: PreviewProviding {
    private let binary: URL
    private let loadPresets: @Sendable () throws -> [Preset]

    public init(binary: URL, loadPresets: @escaping @Sendable () throws -> [Preset] = { try PresetCatalog.all() }) {
        self.binary = binary; self.loadPresets = loadPresets
    }

    private func builder() throws -> PreviewBuilder {
        PreviewBuilder(rclone: RcloneRunner.localOnly(binary: binary),
                       context: RcloneContext(configPath: "/dev/null", environment: [:]), presets: try loadPresets())
    }

    public func preview(set: BackupSet) async throws -> PreviewResult { try await builder().build(set: set) }

    public func rule(for group: PreviewGroup, included: Bool) -> UserRule {
        UserRule(pattern: group.pattern, action: included ? .include : .exclude)
    }

    /// Mirrored files the set's current rules would now skip, for one local mirror folder.
    public func newlyExcluded(set: BackupSet, mirror: String) async throws -> [String] {
        try await builder().newlyExcluded(set: set, mirror: mirror)
    }
}

// MARK: New excludes against what is already mirrored

public enum LocalMirrorInspectorError: Error, Equatable, Sendable {
    /// The agent holds its lock: moving files under it could race the run.
    case backupRunning
    case unsafePath(String)
}

/// Finds files already mirrored that a new exclude would now skip, and moves them to the archive when the owner asks.
/// Local destinations only (iCloud Drive and connected drives): an encrypted cloud mirror can't be read without the
/// agent, so those are left alone. The set handed in already holds the new rule.
public struct LocalMirrorInspector: MirroredExcludeInspecting {
    private let store: ConfigStore
    private let iCloudDrive: URL
    private let volumes: any VolumeLocating
    private let support: URL
    private let listNewlyExcluded: @Sendable (BackupSet, String) async throws -> [String]
    private let now: @Sendable () -> Date

    init(store: ConfigStore, iCloudDrive: URL, volumes: any VolumeLocating, support: URL,
         listNewlyExcluded: @escaping @Sendable (BackupSet, String) async throws -> [String],
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store; self.iCloudDrive = iCloudDrive; self.volumes = volumes; self.support = support
        self.listNewlyExcluded = listNewlyExcluded; self.now = now
    }

    public init(store: ConfigStore, preview: LivePreviewProvider, volumes: any VolumeLocating, support: URL,
                iCloudDrive: URL = KambuchaPaths.iCloudDrive) {
        self.init(store: store, iCloudDrive: iCloudDrive, volumes: volumes, support: support,
                  listNewlyExcluded: { try await preview.newlyExcluded(set: $0, mirror: $1) })
    }

    private struct Local { var backupRoot: URL; var mirror: URL }

    /// The backup roots this set mirrors into on this Mac right now, with the set's mirror folder that exists.
    private func locals(for set: BackupSet) throws -> [Local] {
        try ArchiveScope.checkName(set.name)
        let destinations = (try? store.loadDestinations()) ?? []
        let mounted = volumes.mounted()
        var out: [Local] = []
        for id in set.destinationIDs {
            guard let d = destinations.first(where: { $0.id == id }) else { continue }
            let root: URL
            switch d.kind {
            case .iCloudFolder: root = KambuchaPaths.backupRoot(iCloudDrive: iCloudDrive)
            case .externalDrive:
                guard let v = ExternalVolume.find(d, in: mounted), !v.isSystem,
                      !v.looksInternal || d.internalDiskConfirmed else { continue }
                root = ExternalVolume.backupRoot(on: v)
            case .googleDrive, .oneDrive: continue
            }
            // A folder of this name that the marker gives to another set is that backup's, unless the owner took it over.
            if (try? RootMarker.load(backupRoot: root))?.claims(set.id) == false, set.adoptsBackupIn?.contains(id) != true { continue }
            let mirror = root.appendingPathComponent("Sets", isDirectory: true).appendingPathComponent(set.name, isDirectory: true)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: mirror.path, isDirectory: &isDir), isDir.boolValue else { continue }
            out.append(Local(backupRoot: root, mirror: mirror))
        }
        return out
    }

    public func mirroredFiles(matching excludes: [UserRule], set: BackupSet) async throws -> [String] {
        var all = Set<String>()
        for local in try locals(for: set) {
            all.formUnion(try await listNewlyExcluded(set, local.mirror.path))
        }
        return all.sorted()
    }

    public func archive(_ files: [String], set: BackupSet) async throws {
        let relatives = try files.map(Self.relativeComponents)
        let lock = RunLock(url: support.appendingPathComponent("locks/agent.lock"))
        switch lock.attempt() {
        case .acquired: break
        case .held: throw LocalMirrorInspectorError.backupRunning
        case .openFailed: throw CocoaError(.fileWriteNoPermission)
        }
        defer { lock.release() }
        let stamp = ArchiveScope.stampString(now())
        for local in try locals(for: set) {
            let canonicalMirror = PathGuard.canonical(local.mirror)
            let archiveRoot = local.backupRoot.appendingPathComponent(ArchiveScope.folder, isDirectory: true)
            let stampFolder = archiveRoot.appendingPathComponent(set.name, isDirectory: true)
                .appendingPathComponent(stamp, isDirectory: true)
            for (file, comps) in zip(files, relatives) {
                let source = comps.reduce(local.mirror) { $0.appendingPathComponent($1) }
                // A folder in the path that is a symlink must not lead out of the mirror.
                let parent = PathGuard.canonical(source.deletingLastPathComponent()).pathComponents
                let root = canonicalMirror.pathComponents
                guard parent.count >= root.count, Array(parent.prefix(root.count)) == root else {
                    throw LocalMirrorInspectorError.unsafePath(file)
                }
                guard (try? FileManager.default.attributesOfItem(atPath: source.path)) != nil else { continue }
                let target = comps.reduce(stampFolder) { $0.appendingPathComponent($1) }
                do { try ArchiveScope.validate(target.path, archiveRoot: archiveRoot.path) }
                catch { throw LocalMirrorInspectorError.unsafePath(file) }
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: source, to: target)
            }
        }
    }

    /// Relative, with no empty, `.` or `..` component and no NUL.
    private static func relativeComponents(_ path: String) throws -> [String] {
        let comps = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0"),
              comps.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw LocalMirrorInspectorError.unsafePath(path)
        }
        return comps
    }
}
