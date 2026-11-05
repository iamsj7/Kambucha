import Testing
import Foundation
import Darwin
@testable import KambuchaCore

struct InterfaceCountersTests {
    let up = UInt32(IFF_UP | IFF_RUNNING)

    @Test func countersIncludeOnlyActiveNonLoopback() {
        let list: [InterfaceCounters.Interface] = [
            .init(name: "en0", flags: up, bytesIn: 100, bytesOut: 10),
            .init(name: "en1", flags: up, bytesIn: 5, bytesOut: 1),
            .init(name: "lo0", flags: up | UInt32(IFF_LOOPBACK), bytesIn: 9999, bytesOut: 9999),
            .init(name: "utun3", flags: up | UInt32(IFF_POINTOPOINT), bytesIn: 9999, bytesOut: 9999),
            .init(name: "en2", flags: UInt32(IFF_UP), bytesIn: 9999, bytesOut: 9999),   // not running
            .init(name: "awdl0", flags: up, bytesIn: 9999, bytesOut: 9999),
        ]
        #expect(InterfaceCounters.total(of: list) == InterfaceCounters(bytesOut: 11, bytesIn: 105))
    }

    @Test func liveSampleReads() {
        let a = InterfaceCounters.sample()
        #expect(a.bytesIn > 0 || a.bytesOut > 0 || InterfaceCounters.interfaces().isEmpty == false)
    }

    func en(_ name: String, _ i: UInt64, _ o: UInt64) -> InterfaceCounters.Interface {
        .init(name: name, flags: up, bytesIn: i, bytesOut: o)
    }

    @Test func trackerFirstSampleIsZeroThenDeltas() {
        var t = InterfaceDeltaTracker()
        #expect(t.add([en("en0", 100, 10)]) == InterfaceCounters())
        #expect(t.add([en("en0", 150, 30)]) == InterfaceCounters(bytesOut: 20, bytesIn: 50))
    }

    @Test func trackerHandles32BitWrapPerInterface() {
        var t = InterfaceDeltaTracker()
        _ = t.add([en("en0", 0, 4_294_967_290), en("en1", 0, 0)])
        let d = t.add([en("en0", 0, 4), en("en1", 0, 100)])   // en0 wrapped: 10 bytes, not a drop
        #expect(d.bytesOut == 110)
    }

    @Test func trackerNewInterfaceDoesNotSpike() {
        var t = InterfaceDeltaTracker()
        _ = t.add([en("en0", 0, 0)])
        let d = t.add([en("en0", 0, 5), en("en5", 0, 9_000_000_000)])
        #expect(d.bytesOut == 5)
        #expect(t.add([en("en0", 0, 6), en("en5", 0, 9_000_000_100)]).bytesOut == 101)
    }

    @Test func trackerIgnoresLoopbackAndTunnels() {
        var t = InterfaceDeltaTracker()
        _ = t.add([en("en0", 0, 0), .init(name: "lo0", flags: up | UInt32(IFF_LOOPBACK), bytesIn: 0, bytesOut: 0)])
        let d = t.add([en("en0", 0, 1), .init(name: "lo0", flags: up | UInt32(IFF_LOOPBACK), bytesIn: 0, bytesOut: 999)])
        #expect(d.bytesOut == 1)
    }
}
