import Testing
import Foundation
import Darwin
@testable import MirrorCore

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
}
