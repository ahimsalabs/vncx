// Copyright 2026 Ahimsa Labs
// SPDX-License-Identifier: Apache-2.0

import VNCCore
import Foundation

struct WakeSettings: Codable, Hashable {
    /// MAC address, any common notation (aa:bb:cc:dd:ee:ff, aa-bb-…, aabb.ccdd.eeff).
    var mac = ""
    /// Broadcast address for the local send (directed broadcasts like 192.168.1.255 also work).
    var broadcast = "255.255.255.255"
    /// Optional SSH destination on the sleeping machine's LAN that sends the packet for us.
    var relay = ""

    var isConfigured: Bool { WakeOnLAN.parseMAC(mac) != nil }

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mac = (try? c.decode(String.self, forKey: .mac)) ?? ""
        broadcast = (try? c.decode(String.self, forKey: .broadcast)) ?? "255.255.255.255"
        relay = (try? c.decode(String.self, forKey: .relay)) ?? ""
    }
}

extension WakeOnLAN {
    /// Sends the packet from another machine over SSH (python3, wakeonlan, or etherwake, whichever exists).
    static func sendViaRelay(_ relay: String, mac: [UInt8], completion: @escaping (Result<String, Error>) -> Void) {
        let macText = mac.map { String(format: "%02x", $0) }.joined(separator: ":")
        let script = """
        if command -v python3 >/dev/null; then
          python3 -c 'import socket,sys; m=bytes.fromhex(sys.argv[1].replace(":","")); s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.setsockopt(socket.SOL_SOCKET,socket.SO_BROADCAST,1); [s.sendto(b"\\xff"*6+m*16,("255.255.255.255",p)) for p in (9,7)]' \(macText)
        elif command -v wakeonlan >/dev/null; then wakeonlan \(macText)
        elif command -v etherwake >/dev/null; then etherwake \(macText)
        else echo "no python3, wakeonlan or etherwake on relay" >&2; exit 1; fi
        """
        SSH.run(relay, command: script, timeout: 20, completion: completion)
    }
}
