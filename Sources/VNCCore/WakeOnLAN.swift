import Foundation
import Darwin

/// Wake-on-LAN magic packets.
package enum WakeOnLAN {
    package static func parseMAC(_ s: String) -> [UInt8]? {
        let hex = s.lowercased().filter { "0123456789abcdef".contains($0) }
        guard hex.count == 12, s.filter({ !":-. ".contains($0) }).count == 12 else { return nil }
        var bytes: [UInt8] = []
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            bytes.append(UInt8(hex[i..<j], radix: 16)!)
            i = j
        }
        return bytes
    }

    /// The magic packet: 6 × 0xFF followed by the MAC repeated 16 times.
    package static func packet(_ mac: [UInt8]) -> [UInt8] {
        [UInt8](repeating: 0xff, count: 6) + Array([[UInt8]](repeating: mac, count: 16).joined())
    }

    /// Broadcasts the packet from this Mac (UDP ports 9 and 7). Returns false if sending failed.
    @discardableResult
    package static func sendLocal(mac: [UInt8], broadcast: String) -> Bool {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))
        let data = packet(mac)
        var ok = false
        for port in [UInt16(9), 7] {
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            addr.sin_addr.s_addr = inet_addr(broadcast.isEmpty ? "255.255.255.255" : broadcast)
            let sent = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, data, data.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if sent == data.count { ok = true }
        }
        return ok
    }
}
