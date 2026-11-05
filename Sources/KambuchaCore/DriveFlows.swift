import Foundation
import Observation

// MARK: Warnings in the preview

public enum PreviewWarnings {
    /// exFAT stores extended attributes as `._*` files, which sync and checks hide on both sides. A real `._*` file in
    /// the folder is therefore not backed up there. Only drives that are connected, and so known to be exFAT, are named.
    public static func appleDouble(set: BackupSet, destinations: [Destination], volumes: [VolumeInfo]) -> [String] {
        set.destinationIDs.compactMap { id in
            guard let d = destinations.first(where: { $0.id == id }), d.kind == .externalDrive,
                  let v = ExternalVolume.find(d, in: volumes),
                  DestinationProfile.profile(for: d, fileSystem: v.fileSystem).excludeAppleDouble else { return nil }
            return "\"\(d.name)\" is formatted as \(ExternalDriveSetup.displayName(fileSystem: v.fileSystem)). Files named ._* in this folder are not backed up to it."
        }
    }
}

// MARK: Which volumes are mounted

/// The mounted drives, read off the main thread and kept until the system says one was mounted or unmounted.
/// Screens read `volumes`, which costs nothing.
@MainActor @Observable
public final class VolumeCache {
    public private(set) var volumes: [VolumeInfo] = []
    /// False until the first read finishes, so a screen can say "Looking for drives" instead of "none".
    public private(set) var hasLoaded = false
    /// After each read, for what's worked out from the list and not observed directly.
    @ObservationIgnored public var onChange: (@MainActor () -> Void)?

    @ObservationIgnored private let locator: any VolumeLocating
    @ObservationIgnored private let observers: Observers
    @ObservationIgnored private var running: Task<Void, Never>?
    @ObservationIgnored private var pending: Task<Void, Never>?

    /// `names` are the system's mount and unmount notifications, posted on `center`
    /// (`NSWorkspace.shared.notificationCenter` in the app).
    public init(locator: any VolumeLocating, center: NotificationCenter, names: [Notification.Name]) {
        self.locator = locator
        observers = Observers(center: center)
        for name in names {
            observers.add(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleRefresh() }
            })
        }
    }

    /// Reads are queued one after another, so the last one asked for is the last applied, and this returns after
    /// its own read has been applied.
    public func refresh() async {
        let previous = running
        let locator = locator
        let task = Task { [weak self] in
            await previous?.value
            let list = await Task.detached(priority: .utility) { locator.mounted() }.value
            self?.volumes = list
            self?.hasLoaded = true
            self?.onChange?()
        }
        running = task
        await task.value
    }

    private func scheduleRefresh() {
        pending = Task { [weak self] in await self?.refresh() }
    }

    /// For tests: returns once the refresh a notification started has finished.
    public func waitForRefresh() async { await pending?.value }
}

/// Removes the notification observers when the cache goes away.
private final class Observers: @unchecked Sendable {
    private let center: NotificationCenter
    private var tokens: [any NSObjectProtocol] = []
    init(center: NotificationCenter) { self.center = center }
    func add(_ token: any NSObjectProtocol) { tokens.append(token) }
    deinit { for t in tokens { center.removeObserver(t) } }
}

// MARK: Is the agent working

public enum AgentLockProbe {
    /// True while the agent holds `locks/agent.lock`. Never creates the file. It tries a shared lock without waiting and lets
    /// go at once, so it can only fail the agent's own try-lock for the instant it holds it.
    public static func isHeld(support: URL) -> Bool {
        let fd = open(support.appendingPathComponent("locks/agent.lock").path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        if flock(fd, LOCK_SH | LOCK_NB) == 0 { flock(fd, LOCK_UN); return false }
        return errno == EWOULDBLOCK
    }
}

// MARK: Eject

public protocol VolumeEjecting: Sendable {
    /// Unmounts and ejects. May take a while, so it is never called on the main thread.
    func eject(_ mountPoint: URL) async throws
}

public enum EjectText {
    public static func blockedByRun(_ name: String) -> String { "A backup is running. Eject \"\(name)\" when it finishes." }
    public static func failed(_ name: String) -> String { "Couldn't eject \"\(name)\". Something may still be using it." }
}

@MainActor @Observable
public final class EjectController {
    public enum Phase: Equatable, Sendable { case idle, ejecting, failed(String) }
    public private(set) var phase: Phase = .idle

    @ObservationIgnored private let ejector: any VolumeEjecting
    /// Set by the owner of the controller once it can answer; until then nothing is running.
    @ObservationIgnored public var isBackupRunning: @MainActor () -> Bool
    @ObservationIgnored private let refresh: @MainActor () async -> Void

    public init(ejector: any VolumeEjecting, isBackupRunning: @escaping @MainActor () -> Bool,
                refresh: @escaping @MainActor () async -> Void) {
        self.ejector = ejector; self.isBackupRunning = isBackupRunning; self.refresh = refresh
    }

    public var isEjecting: Bool { phase == .ejecting }
    public func dismiss() { if case .failed = phase { phase = .idle } }

    public func eject(_ volume: VolumeInfo) async {
        guard phase != .ejecting else { return }
        guard !isBackupRunning() else { phase = .failed(EjectText.blockedByRun(volume.name)); return }
        phase = .ejecting
        let ejector = ejector, url = volume.mountPoint
        do {
            try await Task.detached { try await ejector.eject(url) }.value
            phase = .idle
        } catch {
            phase = .failed(EjectText.failed(volume.name))
        }
        await refresh()
    }
}

// MARK: Where progress is shown

public struct SurfaceVisibility: Sendable {
    public enum Surface: Hashable, Sendable { case panel, window }
    private var visible: Set<Surface> = []
    public init() {}
    public var anyVisible: Bool { !visible.isEmpty }
    public mutating func appeared(_ s: Surface) { visible.insert(s) }
    public mutating func disappeared(_ s: Surface) { visible.remove(s) }
}
