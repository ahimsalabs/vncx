// Copyright 2026 Ahimsa Labs
// SPDX-License-Identifier: Apache-2.0

import Foundation

package enum RFBError: LocalizedError, Equatable {
    case connection(String)
    /// Nothing is listening on the port (or an SSH tunnel couldn't reach it).
    case refused
    case `protocol`(String)
    case auth(String)
    case authFailed(String)
    case cancelled
    case closed

    package var errorDescription: String? {
        switch self {
        case .connection(let s): return s
        case .protocol(let s): return "Protocol error: \(s)"
        case .auth(let s): return "Authentication error: \(s)"
        case .authFailed(let s): return s.isEmpty ? "Authentication failed." : "Authentication failed: \(s)"
        case .cancelled: return "Cancelled."
        case .closed: return "The server closed the connection."
        case .refused: return "Connection refused. Is screen sharing / the VNC server running?"
        }
    }
}
