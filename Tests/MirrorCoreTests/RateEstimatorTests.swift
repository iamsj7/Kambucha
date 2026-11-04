import Testing
import Foundation
@testable import MirrorCore

struct RateEstimatorTests {
    let t0 = Date(timeIntervalSince1970: 1000)

    @Test func firstSampleHasNoRate() {
        var r = RateEstimator()
        #expect(r.add(bytes: 5000, at: t0) == nil)
    }

    @Test func secondSampleGivesRate() {
        var r = RateEstimator()
        _ = r.add(bytes: 0, at: t0)
        #expect(r.add(bytes: 2000, at: t0 + 2) == 1000)
    }

    @Test func counterWrapDoesNotGiveNegativeRate() {
        var r = RateEstimator()
        _ = r.add(bytes: 4_000_000_000, at: t0)
        #expect(r.add(bytes: 100, at: t0 + 1) == nil)
        #expect(r.add(bytes: 1100, at: t0 + 2) == 1000)   // rebased, so the next sample works
    }

    @Test func etaNilWhenRateZeroOrUnknown() {
        var r = RateEstimator()
        #expect(r.eta(remaining: 100) == nil)
        _ = r.add(bytes: 10, at: t0)
        _ = r.add(bytes: 10, at: t0 + 1)   // rate 0
        #expect(r.eta(remaining: 100) == nil)
    }

    @Test func etaFromRate() {
        var r = RateEstimator()
        _ = r.add(bytes: 0, at: t0); _ = r.add(bytes: 1000, at: t0 + 1)
        #expect(r.eta(remaining: 5000) == 5)
    }

    @Test func smoothingDampsSpike() {
        var r = RateEstimator(smoothing: 0.3)
        _ = r.add(bytes: 0, at: t0); _ = r.add(bytes: 1000, at: t0 + 1)
        let spiked = r.add(bytes: 1000 + 100_000, at: t0 + 2)!
        #expect(spiked < 100_000 / 2)
        #expect(spiked > 1000)
    }
}
