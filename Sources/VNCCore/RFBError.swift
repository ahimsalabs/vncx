import Foundation

package enum RFBError: LocalizedError, Equatable {
    case connection(String)
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
        }
    }
}
