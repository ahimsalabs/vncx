// Copyright 2026 Ahimsa Labs
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A parsed connection address. Accepts `host`, `host:port`, `host:display` (display < 100 means 5900+display),
/// `host::port`, `[ipv6]:port`, and `vnc://user@host:port` URLs.
package struct Address: Equatable {
    package var host: String
    package var port: Int
    package var username: String = ""

    package init(host: String, port: Int, username: String = "") {
        self.host = host; self.port = port; self.username = username
    }

    package static func parse(_ input: String) -> Address? {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        var user = ""

        if s.lowercased().hasPrefix("vnc://") {
            if let url = URLComponents(string: s), let host = url.host, !host.isEmpty {
                return Address(host: host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")),
                               port: url.port ?? 5900, username: url.user?.removingPercentEncoding ?? "")
            }
            s = String(s.dropFirst(6))
        }
        if let at = s.lastIndex(of: "@") {
            user = String(s[..<at])
            s = String(s[s.index(after: at)...])
        }
        // Bracketed IPv6
        if s.hasPrefix("[") , let close = s.firstIndex(of: "]") {
            let host = String(s[s.index(after: s.startIndex)..<close])
            let rest = s[s.index(after: close)...]
            let port = rest.hasPrefix(":") ? Int(rest.dropFirst()) ?? 5900 : 5900
            return Address(host: host, port: port, username: user)
        }
        // host::port means an explicit port.
        if let r = s.range(of: "::"), s.filter({ $0 == ":" }).count == 2 {
            guard let port = Int(s[r.upperBound...]) else { return nil }
            return Address(host: String(s[..<r.lowerBound]), port: port, username: user)
        }
        let colons = s.filter { $0 == ":" }.count
        if colons == 1, let c = s.firstIndex(of: ":") {
            let host = String(s[..<c])
            guard let n = Int(s[s.index(after: c)...]), !host.isEmpty else { return nil }
            return Address(host: host, port: n < 100 ? 5900 + n : n, username: user)
        }
        if colons > 1 { return Address(host: s, port: 5900, username: user) } // bare IPv6
        return Address(host: s, port: 5900, username: user)
    }

    package var display: String {
        let h = host.contains(":") ? "[\(host)]" : host
        return port == 5900 ? h : "\(h):\(port)"
    }
}
