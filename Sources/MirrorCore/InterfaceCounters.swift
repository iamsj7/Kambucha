import Foundation
import Darwin

/// Bytes sent and received across the Mac's active network interfaces. This covers the whole Mac,
/// not one app.
public struct InterfaceCounters: Equatable, Sendable {
    public var bytesOut: UInt64
    public var bytesIn: UInt64
    public init(bytesOut: UInt64 = 0, bytesIn: UInt64 = 0) { self.bytesOut = bytesOut; self.bytesIn = bytesIn }

    public struct Interface: Equatable, Sendable {
        public var name: String
        public var flags: UInt32
        public var bytesIn: UInt64
        public var bytesOut: UInt64
        public init(name: String, flags: UInt32, bytesIn: UInt64, bytesOut: UInt64) {
            self.name = name; self.flags = flags; self.bytesIn = bytesIn; self.bytesOut = bytesOut
        }
    }

    private static let tunnelPrefixes = ["utun", "ipsec", "gif", "stf", "ppp", "lo", "awdl", "llw", "ap"]

    /// Up, running, not loopback, not point-to-point, and not a tunnel (a VPN's traffic is already
    /// counted on the real interface underneath it).
    static func counts(_ i: Interface) -> Bool {
        let f = Int32(bitPattern: i.flags)
        guard f & IFF_UP != 0, f & IFF_RUNNING != 0, f & IFF_LOOPBACK == 0, f & IFF_POINTOPOINT == 0 else { return false }
        return !tunnelPrefixes.contains { i.name.hasPrefix($0) }
    }

    public static func total(of interfaces: [Interface]) -> InterfaceCounters {
        var c = InterfaceCounters()
        for i in interfaces where counts(i) { c.bytesIn &+= i.bytesIn; c.bytesOut &+= i.bytesOut }
        return c
    }

    /// Reads the kernel's per-interface counters. Cheap: one `getifaddrs` call.
    public static func sample() -> InterfaceCounters { total(of: interfaces()) }

    static func interfaces() -> [Interface] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var out: [Interface] = []
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let a = ptr.pointee
            guard let addr = a.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK), let raw = a.ifa_data else { continue }
            let data = raw.assumingMemoryBound(to: if_data.self).pointee
            out.append(Interface(name: String(cString: a.ifa_name), flags: a.ifa_flags,
                                 bytesIn: UInt64(data.ifi_ibytes), bytesOut: UInt64(data.ifi_obytes)))
        }
        return out
    }
}
