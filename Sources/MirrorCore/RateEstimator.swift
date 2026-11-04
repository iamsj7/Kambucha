import Foundation

/// Smooths a cumulative byte counter into bytes per second. The first sample gives no rate, and a
/// counter that goes backwards (wrap or reset) rebases instead of producing a negative or huge rate.
public struct RateEstimator: Sendable {
    private let smoothing: Double
    private var last: (bytes: UInt64, at: Date)?
    public private(set) var rate: Double?

    /// `smoothing` is the weight of the newest sample, in (0, 1].
    public init(smoothing: Double = 0.3) { self.smoothing = min(max(smoothing, 0.01), 1) }

    @discardableResult
    public mutating func add(bytes: UInt64, at: Date) -> Double? {
        defer { last = (bytes, at) }
        guard let previous = last else { return nil }
        guard bytes >= previous.bytes else { rate = nil; return nil }   // wrap or reset: start over
        let dt = at.timeIntervalSince(previous.at)
        guard dt > 0 else { return rate }
        let instant = Double(bytes - previous.bytes) / dt
        rate = rate.map { smoothing * instant + (1 - smoothing) * $0 } ?? instant
        return rate
    }

    /// Seconds to move `remaining` bytes at the current rate. Nil with no rate, a zero rate or no remainder figure.
    public func eta(remaining: Int64) -> TimeInterval? {
        guard let rate, rate > 0, remaining >= 0 else { return nil }
        return Double(remaining) / rate
    }
}
