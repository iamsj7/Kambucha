import CoreServices
import Foundation

public struct ChangeBatch: Equatable {
    public var paths: [String]
    public var mustRescan: Bool
    public var latestEventID: UInt64
    public init(paths: [String], mustRescan: Bool, latestEventID: UInt64) {
        self.paths = paths; self.mustRescan = mustRescan; self.latestEventID = latestEventID
    }
}

public protocol ChangeFeeding: Sendable {
    func changes(in: URL, since: UInt64?) async throws -> ChangeBatch
}

/// Replays FSEvents history from a stored event ID. No stored ID, a dropped event or a timeout
/// all set `mustRescan`.
public struct FSEventsFeed: ChangeFeeding {
    public let timeout: Duration
    public init(timeout: Duration = .seconds(30)) { self.timeout = timeout }

    private final class State: @unchecked Sendable {
        // All access happens on `queue`.
        var paths = Set<String>()
        var rescan = false
        var maxID: UInt64
        var finished = false
        var timedOut = false
        var startFailed = false
        var continuation: CheckedContinuation<Void, Never>?
        init(start: UInt64) { maxID = start }
        func finish() {
            guard !finished else { return }
            finished = true
            continuation?.resume()
            continuation = nil
        }
    }

    public func changes(in dir: URL, since: UInt64?) async throws -> ChangeBatch {
        let start = FSEventsGetCurrentEventId()
        // No stored ID, or one ahead of the current ID (volume reset or restore): cannot replay.
        guard let since, since <= start else {
            return ChangeBatch(paths: [], mustRescan: true, latestEventID: start)
        }
        let state = State(start: start)
        let queue = DispatchQueue(label: "kambucha.fsevents.feed")
        let cb: FSEventStreamCallback = { _, info, count, paths, flags, ids in
            let state = Unmanaged<State>.fromOpaque(info!).takeUnretainedValue()
            let arr = unsafeBitCast(paths, to: NSArray.self)
            for i in 0..<count {
                let f = flags[i]
                if f & UInt32(kFSEventStreamEventFlagHistoryDone) != 0 {
                    state.finish()
                    continue
                }
                if ids[i] > state.maxID { state.maxID = UInt64(ids[i]) }
                let widen = UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
                    | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagEventIdsWrapped
                    | kFSEventStreamEventFlagRootChanged)
                if f & widen != 0 {
                    state.rescan = true
                }
                if let p = arr[i] as? String { state.paths.insert(p) } else { state.rescan = true }
            }
        }
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(state).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
            | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot)
        guard let stream = FSEventStreamCreate(nil, cb, &ctx, [dir.path] as CFArray, since, 0.1, flags) else {
            return ChangeBatch(paths: [], mustRescan: true, latestEventID: start)
        }
        FSEventStreamSetDispatchQueue(stream, queue)

        let box = StreamBox(stream)
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            queue.async {
                state.continuation = c
                if !FSEventStreamStart(box.stream) { state.startFailed = true; state.finish() }
            }
            let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
            queue.asyncAfter(deadline: .now() + seconds) {
                if !state.finished { state.timedOut = true; state.finish() }
            }
        }
        // Stop on the queue so no callback runs after we read the state.
        queue.sync {
            FSEventStreamStop(box.stream)
            FSEventStreamInvalidate(box.stream)
            FSEventStreamRelease(box.stream)
        }
        return queue.sync {
            ChangeBatch(paths: state.paths.sorted(),
                        mustRescan: state.rescan || state.timedOut || state.startFailed,
                        latestEventID: state.maxID)
        }
    }

    private final class StreamBox: @unchecked Sendable {
        let stream: FSEventStreamRef
        init(_ s: FSEventStreamRef) { stream = s }
    }
}
