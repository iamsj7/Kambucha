import Darwin
import Foundation
import os

/// Peak memory, as Activity Monitor's Memory column counts it (physical footprint), for the run records.
///
/// rclone's peak is sampled while each rclone process runs, because a child's figures are gone once it has
/// been reaped. The figure sampled is the kernel's lifetime maximum, so a sample only misses growth in the
/// last `interval` before rclone exits. Each rclone adds its peak to the `pair` the calling task carries.
public enum RunMemory {
    static let interval: Duration = .milliseconds(250)

    /// The largest rclone footprint seen while one pair ran.
    public final class Peak: Sendable {
        private let bytes = OSAllocatedUnfairLock<UInt64>(initialState: 0)
        public init() {}
        /// Nil until an rclone has run.
        public var value: UInt64? { bytes.withLock { $0 == 0 ? nil : $0 } }
        func note(_ b: UInt64) { bytes.withLock { $0 = max($0, b) } }
    }

    /// Set by the coordinator around each pair. Task-local, so concurrent work can't mix up two pairs' figures.
    @TaskLocal public static var pair: Peak?

    /// This process's peak since it started. One agent run can cover several pairs, so it is the peak so far.
    public static var ownPeak: UInt64? { peakFootprint(pid: getpid()) }

    /// The lifetime peak physical footprint of `pid`, or nil if it can't be read (gone, or not ours).
    public static func peakFootprint(pid: pid_t) -> UInt64? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        return result == 0 ? info.ri_lifetime_max_phys_footprint : nil
    }

    /// Samples `state`'s child until cancelled, and returns the largest figure seen (0 if it never ran).
    static func follow(_ state: RunState) -> Task<UInt64, Never> {
        Task.detached(priority: .utility) {
            var peak: UInt64 = 0
            func sample() {
                if let pid = state.runningPID, let bytes = peakFootprint(pid: pid) { peak = max(peak, bytes) }
            }
            while !Task.isCancelled {
                sample()
                try? await Task.sleep(for: interval)
            }
            sample()
            return peak
        }
    }

    /// Ends sampling and adds the child's peak to the calling task's pair, if it has one.
    @discardableResult
    static func stop(_ task: Task<UInt64, Never>) async -> UInt64 {
        task.cancel()
        let peak = await task.value
        if peak > 0 { pair?.note(peak) }
        return peak
    }
}
