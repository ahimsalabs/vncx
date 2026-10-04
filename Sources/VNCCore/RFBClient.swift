// Copyright 2026 Ahimsa Labs
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Network
import CoreGraphics
import os

/// Update-flow events (continuous updates, limits, quality): `log stream --predicate 'subsystem == "vncx"'`.
package let flowLog = Logger(subsystem: "vncx", category: "flow")

package enum Encoding {
    package static let raw: Int32 = 0
    package static let copyRect: Int32 = 1
    package static let rre: Int32 = 2
    package static let hextile: Int32 = 5
    package static let zlib: Int32 = 6
    package static let tight: Int32 = 7
    package static let zrle: Int32 = 16
    // Pseudo-encodings
    package static let cursor: Int32 = -239
    package static let desktopSize: Int32 = -223
    package static let lastRect: Int32 = -224
    package static let extendedDesktopSize: Int32 = -308
    package static let desktopName: Int32 = -307
    package static let extendedClipboard = Int32(bitPattern: 0xC0A1_E5CE)
    package static let fence: Int32 = -312
    package static let continuousUpdates: Int32 = -313
    package static let cursorWithAlpha: Int32 = -314

    package static func name(_ e: Int32) -> String {
        switch e {
        case raw: return "Raw"
        case copyRect: return "CopyRect"
        case rre: return "RRE"
        case hextile: return "Hextile"
        case zlib: return "Zlib"
        case tight: return "Tight"
        case zrle: return "ZRLE"
        case cursor: return "Cursor"
        default: return "\(e)"
        }
    }
    package static func jpegQuality(_ q: Int) -> Int32 { -32 + Int32(q) }
    package static func compressLevel(_ l: Int) -> Int32 { -256 + Int32(l) }
}

package enum SecurityType: UInt8 {
    case none = 1
    case vncAuth = 2
    case appleRemoteDesktop = 30

    package var name: String {
        switch self {
        case .none: return "None"
        case .vncAuth: return "VNC password"
        case .appleRemoteDesktop: return "macOS account"
        }
    }
}

/// Picture quality: lossless, or Tight with a JPEG quality from 0 (smallest) to 9. `.auto` is a setting, not a level.
package enum Quality: Hashable, Codable, CaseIterable, Identifiable, Sendable {
    case auto, lossless, jpeg(Int)

    package static let balanced = Quality.jpeg(8)
    package static let low = Quality.jpeg(4)
    package static var allCases: [Quality] { [.auto, .lossless] + (0...9).reversed().map { .jpeg($0) } }
    /// Levels from best to smallest.
    package static var levels: [Quality] { allCases.filter { $0 != .auto } }

    package var rawValue: String {
        switch self {
        case .auto: return "auto"
        case .lossless: return "lossless"
        case .jpeg(let q): return "jpeg\(q)"
        }
    }

    package init?(rawValue: String) {
        switch rawValue {
        case "auto": self = .auto
        case "lossless": self = .lossless
        case "balanced": self = .balanced // names saved by earlier versions
        case "low": self = .low
        default:
            guard rawValue.hasPrefix("jpeg"), let q = Int(rawValue.dropFirst(4)), (0...9).contains(q) else { return nil }
            self = .jpeg(q)
        }
    }

    package init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let q = Quality(rawValue: raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "unknown quality \(raw)"))
        }
        self = q
    }

    package func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }

    package var id: String { rawValue }
    package var label: String {
        switch self {
        case .auto: return "Automatic"
        case .lossless: return "Best (lossless)"
        case .jpeg(8): return "JPEG 8 · Balanced"
        case .jpeg(4): return "JPEG 4 · Low bandwidth"
        case .jpeg(0): return "JPEG 0 · Smallest"
        case .jpeg(let q): return "JPEG \(q)"
        }
    }
    /// Orders levels: lossless highest, then JPEG 9 down to 0.
    package var rank: Int {
        switch self {
        case .auto, .lossless: return 10
        case .jpeg(let q): return q
        }
    }
}

/// What the client is waiting on right now, for a "still working" indicator. Durations in seconds.
package struct RFBActivity: Sendable {
    /// How long the update now arriving has been streaming in, and its bytes so far.
    package var receivingFor: Double?
    package var receivedBytes: UInt64 = 0
    /// How long the last update request has gone unanswered (nil while none is outstanding).
    package var requestOutstandingFor: Double?
    /// How long the next request has been held back by the bandwidth limit.
    package var pacedFor: Double?
    package var limit: Double?
    /// How long the oldest latency fence has gone unanswered. Its reply should come back within a round trip, so
    /// a long wait means the server or the network has stalled.
    package var fenceUnansweredFor: Double?
}

/// A snapshot of connection statistics for the stats overlay and automatic quality.
package struct RFBStats: Sendable {
    package var bytes: UInt64 = 0
    package var updates = 0
    package var rectCount: [Int32: Int] = [:]
    package var rectBytes: [Int32: UInt64] = [:]
    /// Receive rate while an update is streaming in (bytes/s, smoothed). Approximates the usable link rate.
    package var linkRate: Double?
    /// Last fence round-trip time in seconds.
    package var rtt: Double?
    package var continuousUpdates = false
    package var fenceSupported = false
    package var level: Quality = .lossless
    /// Pixels covered by framebuffer rectangles (not pseudo-encodings), for bytes per pixel.
    package var pixels: UInt64 = 0
    /// The bandwidth limit in force (bits/s), nil when unlimited.
    package var limit: Double?
}

package struct Credentials: Sendable {
    package var username: String
    package var password: String
    package var remember: Bool
    package init(username: String, password: String, remember: Bool) {
        self.username = username; self.password = password; self.remember = remember
    }
}

package struct CredentialRequest: Sendable {
    package var needsUsername: Bool
    package var securityType: SecurityType
}

package struct RemoteCursor: @unchecked Sendable {
    package let image: CGImage
    package let hotspot: CGPoint
}

package struct ScreenLayout: Sendable, CustomStringConvertible {
    package var description: String { "screen id=\(id) \(w)x\(h)+\(x)+\(y) flags=\(flags)" }
    package var id: UInt32, x: UInt16, y: UInt16, w: UInt16, h: UInt16, flags: UInt32
}

package enum RFBEvent: @unchecked Sendable {
    case connected(name: String, framebuffer: Framebuffer, securityType: SecurityType?)
    case resized(Framebuffer)
    case updated
    /// Part of a long update has been decoded into the framebuffer; worth drawing before the rest arrives.
    case progress
    case cursor(RemoteCursor?)
    case bell
    case clipboard(String)
    case nameChanged(String)
    /// The server's screen layout (ExtendedDesktopSize), e.g. one entry per monitor.
    case screens([ScreenLayout])
    case disconnected(Error?)
}

package struct RFBOptions: Sendable {
    package var endpoint: NWEndpoint
    package var username: String = ""
    package var password: String?
    package var quality: Quality = .lossless
    package var shared = true
    /// Overrides the encoding preference list (used by the probe tool to exercise one decoder at a time).
    package var forcedEncodings: [Int32]?

    package init(endpoint: NWEndpoint, username: String = "", password: String? = nil, quality: Quality = .lossless) {
        self.endpoint = endpoint; self.username = username; self.password = password; self.quality = quality
    }
}

/// An RFB 3.3–3.8 client. Protocol I/O runs on a dedicated thread; sending input is thread-safe.
package final class RFBClient: @unchecked Sendable {
    package let options: RFBOptions
    private let transport: Transport
    private let onEvent: (RFBEvent) -> Void
    private let credentialProvider: (CredentialRequest) -> Credentials?

    private var framebuffer: Framebuffer?
    private let zrle = ZRLEDecoder()
    private let tight = TightDecoder()
    private let zlibStream = ZStream()
    private var screens: [ScreenLayout] = []
    private let lock = NSLock()
    private var _supportsResize = false
    private var serverVersion = (3, 3)

    // Stats and flow-control state (guarded by `lock`).
    private var stats = RFBStats()
    private var level: Quality = .lossless
    private var cuSupported = false
    private var cuEnabled = false
    /// We asked the server to stop continuous updates and are waiting for its EndOfContinuousUpdates.
    private var cuStopping = false
    private var fenceSupported = false
    private var limit: Double?
    /// Pacing allowance in bits: it refills at the limit, up to `burstSeconds` worth, and each update spends its size.
    private var tokens: Double = 0
    private var tokensAt: UInt64 = 0
    /// When the current paced wait began, and when the update now streaming in began (and its first byte).
    private var pacedSince: UInt64?
    private var requestSince: UInt64?
    private var updateSince: (time: UInt64, bytes: UInt64)?
    /// When the oldest unanswered latency fence was sent.
    private var fencePendingSince: UInt64?
    /// Update requests the server is still holding, counted as neatvnc counts them: every request except an
    /// incremental one while continuous updates are on, each answered by one FramebufferUpdate. See `measureLatency`.
    private var serverPending = 0
    /// Whether we last told the server to send continuous updates.
    private var serverCU = false
    /// A latency fence is due as soon as the server holds no requests.
    private var fenceWanted = false
    private let pacer = DispatchQueue(label: "vncx.pacer", qos: .userInteractive)

    package func statsSnapshot() -> RFBStats {
        lock.withLock {
            var s = stats
            s.bytes = transport.bytesReceived &- UInt64(transport.buffered)
            s.continuousUpdates = cuEnabled && !cuStopping
            s.fenceSupported = fenceSupported
            s.level = level
            s.limit = limit
            // An unanswered fence is at least as slow as its age, so a stalled stream shows rising latency.
            if let sent = fencePendingSince {
                let age = Double(DispatchTime.now().uptimeNanoseconds &- sent) / 1e9
                if age > s.rtt ?? 0 { s.rtt = age }
            }
            return s
        }
    }

    /// Changes the picture quality mid-session (re-sends SetEncodings). `.auto` is not a level.
    package func setQualityLevel(_ q: Quality) {
        guard q != .auto else { return }
        let changed = lock.withLock { () -> Bool in defer { level = q }; return level != q }
        if changed {
            flowLog.notice("quality -> \(q.rawValue, privacy: .public)")
            sendEncodings()
        }
    }

    /// Sends a fence carrying a timestamp; the reply gives the round-trip time.
    package func activity() -> RFBActivity {
        let now = DispatchTime.now().uptimeNanoseconds
        func age(_ t: UInt64?) -> Double? { t.map { Double(now &- $0) / 1e9 } }
        return lock.withLock {
            var a = RFBActivity()
            a.receivingFor = age(updateSince?.time)
            if let u = updateSince { a.receivedBytes = transport.bytesReceived &- u.bytes }
            a.pacedFor = age(pacedSince)
            a.requestOutstandingFor = age(requestSince)
            a.limit = limit
            a.fenceUnansweredFor = age(fencePendingSince)
            return a
        }
    }

    ///
    /// Only sent while the server holds no update requests. neatvnc (WayVNC) stops reading a client's messages when a
    /// fence request arrives while it has a request pending, and never resumes: from then on every update request,
    /// key and pointer event goes unread. So a fence that comes due then waits for the outstanding update.
    package func measureLatency() {
        lock.withLock {
            guard fenceSupported else { return }
            if serverPending == 0 { sendLatencyFenceLocked() } else { fenceWanted = true }
        }
    }

    /// Caller holds `lock`, so no request can slip onto the wire between the check and the fence.
    private func sendLatencyFenceLocked() {
        let now = DispatchTime.now().uptimeNanoseconds
        if fencePendingSince == nil { fencePendingSince = now }
        fenceWanted = false
        let payload = (0..<8).map { UInt8(truncatingIfNeeded: now >> (56 - 8 * UInt64($0))) }
        sendFence(flags: Fence.request | Fence.blockBefore, payload: payload)
    }

    /// The longest a paced request waits, so one big update (a full refresh) costs a slow frame, not a freeze.
    private static let maxPacingWait = 1.5
    /// How much unused allowance carries over, so an occasional big update after a quiet spell doesn't wait at all.
    private static let burstSeconds = 1.0

    /// Caps the server's sending rate (bits/s; nil for no limit). With a limit, continuous updates are turned off and
    /// update requests are paced instead, with a token bucket: the allowance refills at the limit (up to one second's
    /// worth) and each update spends its size; when it runs short, the next request waits for it to refill.
    /// Small updates (typing, pointer) go out at once; sustained big ones (video) slow to the limit.
    package func setBandwidthLimit(_ bitsPerSecond: Double?) {
        enum Change { case none, stop, start }
        let change = lock.withLock { () -> Change in
            if let bitsPerSecond, limit == nil {
                tokens = bitsPerSecond * Self.burstSeconds
                tokensAt = DispatchTime.now().uptimeNanoseconds
            }
            if (limit == nil) != (bitsPerSecond == nil) || abs((limit ?? 0) - (bitsPerSecond ?? 0)) > 1e5 {
                flowLog.notice("limit \((self.limit ?? 0) / 1e6, format: .fixed(precision: 1)) -> \((bitsPerSecond ?? 0) / 1e6, format: .fixed(precision: 1)) Mbit/s (0 = none) cu=\(self.cuEnabled) stopping=\(self.cuStopping)")
            }
            limit = bitsPerSecond
            if bitsPerSecond != nil && cuEnabled && !cuStopping { cuStopping = true; return .stop }
            if bitsPerSecond == nil && cuSupported && !cuEnabled { cuEnabled = true; return .start }
            return .none
        }
        switch change {
        case .stop: sendContinuousUpdates(enable: false)
        case .start: sendContinuousUpdates(enable: true)
        case .none: break
        }
    }

    /// Requests the next incremental update after one of `bytes` arrived, waiting first if a limit applies.
    private func requestNext(after bytes: UInt64) {
        let now = DispatchTime.now().uptimeNanoseconds
        let wait = lock.withLock { () -> Double in
            guard let limit else { return 0 }
            let elapsed = Double(now &- tokensAt) / 1e9
            tokens = min(limit * Self.burstSeconds, tokens + elapsed * limit) - Double(bytes) * 8
            tokensAt = now
            // Don't let one huge update run up more debt than the longest wait can repay.
            tokens = max(tokens, -limit * Self.maxPacingWait)
            return tokens < 0 ? -tokens / limit : 0
        }
        guard wait > 0 else { return requestUpdate(incremental: true) }
        lock.withLock { pacedSince = now }
        pacer.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self, !self.transport.isCancelled else { return }
            self.requestUpdate(incremental: true)
        }
    }

    private enum Fence {
        static let blockBefore: UInt32 = 1 << 0
        static let blockAfter: UInt32 = 1 << 1
        static let syncNext: UInt32 = 1 << 2
        static let request: UInt32 = 1 << 31
    }

    private func sendFence(flags: UInt32, payload: [UInt8]) {
        transport.send([248, 0, 0, 0] + be32(flags) + [UInt8(payload.count)] + payload)
    }

    private func sendContinuousUpdates(enable: Bool) {
        guard let fb = framebuffer else { return }
        flowLog.notice("EnableContinuousUpdates enable=\(enable)")
        lock.withLock {
            serverCU = enable
            transport.send([150, enable ? 1 : 0] + be16(0) + be16(0) + be16(fb.width) + be16(fb.height))
        }
    }

    // Extended clipboard state (guarded by `lock`).
    private var extClipboardActive = false
    private var localClipboardText: String?
    private enum Clip {
        static let text: UInt32 = 1 << 0
        static let caps: UInt32 = 1 << 24
        static let request: UInt32 = 1 << 25
        static let peek: UInt32 = 1 << 26
        static let notify: UInt32 = 1 << 27
        static let provide: UInt32 = 1 << 28
    }

    /// True once the server has announced Extended Clipboard support (UTF-8 clipboard).
    package var supportsUnicodeClipboard: Bool { lock.withLock { extClipboardActive } }

    /// Credentials actually used for a successful login (so the UI can offer to save them).
    package private(set) var usedCredentials: Credentials?

    package var supportsRemoteResize: Bool { lock.withLock { _supportsResize } }
    package var bytesReceived: UInt64 { transport.bytesReceived }
    package private(set) var isAppleServer = false
    /// Debug hook: called on the protocol thread for every rectangle header (encoding, x, y, w, h).
    package var traceRect: ((Int32, Int, Int, Int, Int) -> Void)?
    /// Debug hook: ExtendedDesktopSize screen layouts as received (reason, status, screens).
    package var traceScreens: ((Int, Int, [ScreenLayout]) -> Void)?

    package init(options: RFBOptions,
         credentialProvider: @escaping (CredentialRequest) -> Credentials?,
         onEvent: @escaping (RFBEvent) -> Void) {
        self.options = options
        self.transport = Transport(endpoint: options.endpoint)
        self.credentialProvider = credentialProvider
        self.onEvent = onEvent
    }

    package func start() {
        let thread = Thread { [self] in run() }
        thread.name = "vncx.rfb"
        thread.qualityOfService = .userInteractive
        thread.stackSize = 1 << 20
        thread.start()
    }

    package func stop() { transport.close() }

    private func run() {
        do {
            try transport.open()
            try handshake()
            try messageLoop()
        } catch RFBError.cancelled {
            onEvent(.disconnected(nil))
        } catch {
            transport.close()
            onEvent(.disconnected(error))
        }
    }

    // MARK: Handshake

    private func handshake() throws {
        let banner = String(decoding: try transport.bytes(12), as: UTF8.self)
        guard banner.hasPrefix("RFB "), let major = Int(banner.dropFirst(4).prefix(3)),
              let minor = Int(banner.dropFirst(8).prefix(3)) else {
            throw RFBError.protocol("not a VNC server (got \(banner.debugDescription))")
        }
        isAppleServer = minor == 889
        // Apple's 3.889 is a superset of 3.8; we speak plain 3.8 to it.
        let version: (Int, Int) = major > 3 || minor >= 8 ? (3, 8) : (minor == 7 ? (3, 7) : (3, 3))
        serverVersion = version
        transport.send(Array(String(format: "RFB %03d.%03d\n", version.0, version.1).utf8))

        let chosen: SecurityType
        if version.1 >= 7 {
            let count = Int(try transport.u8())
            if count == 0 { throw RFBError.connection(try readReason()) }
            let offered = try transport.bytes(count)
            chosen = try pickSecurity(offered)
            transport.send([chosen.rawValue])
        } else {
            let type = try transport.u32()
            if type == 0 { throw RFBError.connection(try readReason()) }
            guard let t = SecurityType(rawValue: UInt8(truncatingIfNeeded: type)), type < 256 else {
                throw RFBError.auth("server requires unsupported security type \(type)")
            }
            chosen = t
        }

        switch chosen {
        case .none:
            break
        case .vncAuth:
            let challenge = try transport.bytes(16)
            let creds = try credentials(for: CredentialRequest(needsUsername: false, securityType: .vncAuth))
            transport.send(try VNCAuth.respond(challenge: challenge, password: creds.password))
        case .appleRemoteDesktop:
            let generator = try transport.u16()
            let keyLength = Int(try transport.u16())
            guard keyLength > 0, keyLength <= 1024 else { throw RFBError.protocol("bad ARD key length \(keyLength)") }
            let prime = try transport.bytes(keyLength)
            let serverKey = try transport.bytes(keyLength)
            let creds = try credentials(for: CredentialRequest(needsUsername: true, securityType: .appleRemoteDesktop))
            let response = try ARDAuth.respond(
                to: .init(generator: generator, keyLength: keyLength, prime: prime, serverPublicKey: serverKey),
                username: creds.username, password: creds.password)
            transport.send(response)
        }

        if chosen != .none || version.1 >= 8 {
            let result = try transport.u32()
            if result != 0 {
                let reason = version.1 >= 8 ? (try? readReason()) ?? "" : ""
                throw RFBError.authFailed(reason)
            }
        }

        transport.send([options.shared ? 1 : 0])

        let w = Int(try transport.u16()), h = Int(try transport.u16())
        try transport.skip(16) // server pixel format; we override it below
        let nameLen = Int(try transport.u32())
        let name = String(decoding: try transport.bytes(min(nameLen, 1 << 16)), as: UTF8.self)
        if nameLen > 1 << 16 { try transport.skip(nameLen - (1 << 16)) }

        let fb = Framebuffer(width: w, height: h)
        framebuffer = fb
        level = options.quality == .auto ? .lossless : options.quality
        sendPixelFormat()
        sendEncodings()
        requestUpdate(incremental: false)
        onEvent(.connected(name: name, framebuffer: fb, securityType: chosen))
    }

    private func pickSecurity(_ offered: [UInt8]) throws -> SecurityType {
        let types = Set(offered.compactMap(SecurityType.init(rawValue:)))
        if types.contains(.none) { return .none }
        // Prefer macOS account auth when the user gave a username (or the server only does ARD).
        if types.contains(.appleRemoteDesktop) && (!options.username.isEmpty || !types.contains(.vncAuth)) {
            return .appleRemoteDesktop
        }
        if types.contains(.vncAuth) { return .vncAuth }
        if types.contains(.appleRemoteDesktop) { return .appleRemoteDesktop }
        let list = offered.map(String.init).joined(separator: ", ")
        throw RFBError.auth("no supported security type (server offers \(list)). TLS-only servers (VeNCrypt) are not supported yet.")
    }

    private func credentials(for request: CredentialRequest) throws -> Credentials {
        if let pw = options.password, !(request.needsUsername && options.username.isEmpty) {
            let c = Credentials(username: options.username, password: pw, remember: false)
            usedCredentials = c
            return c
        }
        guard let c = credentialProvider(request) else { throw RFBError.cancelled }
        usedCredentials = c
        return c
    }

    private func readReason() throws -> String {
        let len = Int(try transport.u32())
        return String(decoding: try transport.bytes(min(len, 4096)), as: UTF8.self)
    }

    // MARK: Server messages

    private func messageLoop() throws {
        while true {
            let type = try transport.u8()
            switch type {
            case 0: try framebufferUpdate()
            case 1: // SetColourMapEntries — irrelevant for true colour; consume it.
                try transport.skip(3)
                let n = Int(try transport.u16())
                try transport.skip(n * 6)
            case 2: onEvent(.bell)
            case 150: // EndOfContinuousUpdates: the first means "supported"; later ones mean updates stopped.
                enum Next { case enable, poll, none }
                let next = lock.withLock { () -> Next in
                    if !cuSupported {
                        cuSupported = true
                        // With a bandwidth limit, keep polling (the initial request is still outstanding).
                        if limit != nil { return .none }
                        cuEnabled = true
                        return .enable
                    }
                    let stopping = cuStopping
                    cuStopping = false
                    cuEnabled = false
                    // The limit may have been lifted while we waited for the server to stop.
                    if stopping && limit == nil { cuEnabled = true; return .enable }
                    return .poll
                }
                flowLog.notice("EndOfContinuousUpdates -> \(String(describing: next), privacy: .public)")
                switch next {
                case .enable: sendContinuousUpdates(enable: true)
                case .poll: requestUpdate(incremental: true)
                case .none: break
                }
            case 248: // ServerFence
                try transport.skip(3)
                let flags = try transport.u32()
                let payload = try transport.bytes(Int(try transport.u8()))
                lock.withLock { fenceSupported = true }
                if flags & Fence.request != 0 {
                    // We process messages strictly in order, so every sync flag is already satisfied: echo it back.
                    sendFence(flags: flags & (Fence.blockBefore | Fence.blockAfter | Fence.syncNext), payload: payload)
                } else if payload.count == 8 {
                    let sent = payload.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
                    let now = DispatchTime.now().uptimeNanoseconds
                    lock.withLock {
                        if now > sent { stats.rtt = Double(now - sent) / 1e9 }
                        fencePendingSince = nil
                    }
                }
            case 3:
                try transport.skip(3)
                let signed = try transport.s32()
                if signed < 0 {
                    let len = Int(signed.magnitude)
                    guard len <= 64 << 20 else { throw RFBError.protocol("clipboard message too large") }
                    try extendedClipboard(try transport.bytes(len))
                    continue
                }
                let len = Int(signed)
                let bytes = try transport.bytes(min(len, 16 << 20))
                if len > 16 << 20 { try transport.skip(len - (16 << 20)) }
                // Classic RFB clipboard text is ISO 8859-1.
                onEvent(.clipboard(String(bytes: bytes, encoding: .isoLatin1) ?? ""))
            default:
                throw RFBError.protocol("unknown server message type \(type)")
            }
        }
    }

    private var consumed: UInt64 { transport.bytesReceived &- UInt64(transport.buffered) }

    private func framebufferUpdate() throws {
        let startBytes = consumed - 1
        let startTime = DispatchTime.now().uptimeNanoseconds
        var rectCounts: [Int32: Int] = [:], rectBytes: [Int32: UInt64] = [:]
        var rectPixels: UInt64 = 0
        var lastProgress = startTime
        lock.withLock { updateSince = (startTime, startBytes); requestSince = nil }
        defer { lock.withLock { updateSince = nil } }
        try transport.skip(1)
        let count = Int(try transport.u16())
        var i = 0
        while count == 0xFFFF || i < count {
            i += 1
            let x = Int(try transport.u16()), y = Int(try transport.u16())
            let w = Int(try transport.u16()), h = Int(try transport.u16())
            let enc = try transport.s32()
            let rectStart = consumed
            defer {
                rectCounts[enc, default: 0] += 1
                rectBytes[enc, default: 0] += consumed &- rectStart
                if enc >= 0 { rectPixels += UInt64(w * h) }
                // Rectangles land in the framebuffer as they decode, so a big update (a full refresh, or video on a
                // slow link) can be shown filling in instead of all at once at the end. About once per display frame.
                let now = DispatchTime.now().uptimeNanoseconds
                if now &- lastProgress > 16_000_000 { lastProgress = now; onEvent(.progress) }
            }
            traceRect?(enc, x, y, w, h)
            guard let fb = framebuffer else { throw RFBError.protocol("update before init") }
            if enc != Encoding.tight { try tight.flush(fb) } // batched Tight JPEGs draw before anything after them
            switch enc {
            case Encoding.raw: try BasicDecoders.raw(transport, fb, x: x, y: y, w: w, h: h)
            case Encoding.copyRect: try BasicDecoders.copyRect(transport, fb, x: x, y: y, w: w, h: h)
            case Encoding.rre: try BasicDecoders.rre(transport, fb, x: x, y: y, w: w, h: h)
            case Encoding.hextile: try BasicDecoders.hextile(transport, fb, x: x, y: y, w: w, h: h)
            case Encoding.zlib: try BasicDecoders.zlib(transport, fb, stream: zlibStream, x: x, y: y, w: w, h: h)
            case Encoding.zrle: try zrle.decode(transport, fb, x: x, y: y, w: w, h: h)
            case Encoding.tight: try tight.decode(transport, fb, x: x, y: y, w: w, h: h)
            case Encoding.cursor: try cursorPseudo(x: x, y: y, w: w, h: h)
            case Encoding.cursorWithAlpha: try cursorWithAlpha(x: x, y: y, w: w, h: h)
            case Encoding.desktopSize: resize(w, h)
            case Encoding.extendedDesktopSize: try extendedDesktopSize(reason: x, status: y, w: w, h: h)
            case Encoding.desktopName:
                let len = Int(try transport.u32())
                onEvent(.nameChanged(String(decoding: try transport.bytes(min(len, 4096)), as: UTF8.self)))
            case Encoding.lastRect:
                i = count == 0xFFFF ? Int.max : count
            default:
                throw RFBError.protocol("server sent unsupported encoding \(enc)")
            }
            if enc == Encoding.lastRect { break }
        }
        if let fb = framebuffer { try tight.flush(fb) }
        let total = consumed &- startBytes
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - startTime) / 1e9
        let continuous = lock.withLock { () -> Bool in
            stats.updates += 1
            stats.pixels += rectPixels
            for (e, n) in rectCounts { stats.rectCount[e, default: 0] += n }
            for (e, b) in rectBytes { stats.rectBytes[e, default: 0] += b }
            // Only large updates say anything about the link; small ones are dominated by latency.
            if total > 48 * 1024, elapsed > 0.002 {
                let sample = Double(total) / elapsed
                stats.linkRate = stats.linkRate.map { $0 * 0.7 + sample * 0.3 } ?? sample
            }
            if serverPending > 0 { serverPending -= 1 }
            if fenceWanted && serverPending == 0 { sendLatencyFenceLocked() }
            return cuEnabled
        }
        if !continuous { requestNext(after: total) }
        onEvent(.updated)
    }

    private func resize(_ w: Int, _ h: Int) {
        guard let old = framebuffer, old.width != w || old.height != h else { return }
        let fb = Framebuffer(width: w, height: h)
        fb.copyContents(of: old)
        framebuffer = fb
        if lock.withLock({ cuEnabled && !cuStopping }) { sendContinuousUpdates(enable: true) }
        onEvent(.resized(fb))
    }

    private func extendedDesktopSize(reason: Int, status: Int, w: Int, h: Int) throws {
        let n = Int(try transport.u8())
        try transport.skip(3)
        var list: [ScreenLayout] = []
        for _ in 0..<n {
            list.append(ScreenLayout(id: try transport.u32(), x: try transport.u16(), y: try transport.u16(),
                                     w: try transport.u16(), h: try transport.u16(), flags: try transport.u32()))
        }
        lock.withLock { _supportsResize = true; if status == 0 { screens = list } }
        traceScreens?(reason, status, list)
        if status == 0 { resize(w, h); onEvent(.screens(list)) }
    }

    private func cursorPseudo(x: Int, y: Int, w: Int, h: Int) throws {
        let pixelBytes = w * h * 4
        let maskRow = (w + 7) / 8
        guard w > 0, h > 0 else { onEvent(.cursor(nil)); return }
        let px = try transport.bytes(pixelBytes)
        let mask = try transport.bytes(maskRow * h)
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        for yy in 0..<h {
            for xx in 0..<w where (mask[yy * maskRow + xx / 8] >> UInt8(7 - xx % 8)) & 1 == 1 {
                let s = (yy * w + xx) * 4
                rgba[s] = px[s + 2]; rgba[s + 1] = px[s + 1]; rgba[s + 2] = px[s]; rgba[s + 3] = 255
            }
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return }
        onEvent(.cursor(RemoteCursor(image: image, hotspot: CGPoint(x: x, y: y))))
    }

    // MARK: Extended clipboard

    private func extendedClipboard(_ payload: [UInt8]) throws {
        guard payload.count >= 4 else { return }
        let flags = UInt32(payload[0]) << 24 | UInt32(payload[1]) << 16 | UInt32(payload[2]) << 8 | UInt32(payload[3])
        if flags & Clip.caps != 0 {
            lock.withLock { extClipboardActive = true }
            // Advertise text only, with a 0-byte unsolicited limit so changes always arrive as notify (per spec advice).
            sendExtendedClipboard(Clip.caps | Clip.text | Clip.request | Clip.peek | Clip.notify | Clip.provide, body: be32(0))
            // Offer whatever the local clipboard held before the server told us it supports this.
            if lock.withLock({ localClipboardText }) != nil { sendExtendedClipboard(Clip.notify | Clip.text) }
            return
        }
        if flags & Clip.request != 0, flags & Clip.text != 0 {
            let text = lock.withLock { localClipboardText } ?? ""
            sendProvide(text)
        } else if flags & Clip.peek != 0 {
            let has = lock.withLock { localClipboardText } != nil
            sendExtendedClipboard(Clip.notify | (has ? Clip.text : 0))
        } else if flags & Clip.notify != 0 {
            if flags & Clip.text != 0 { sendExtendedClipboard(Clip.request | Clip.text) }
        } else if flags & Clip.provide != 0 {
            // A fresh zlib stream holding (u32 size, data) for each format bit set, lowest bit first.
            let data = try payload.withUnsafeBytes { raw in
                try ZStream().inflate(UnsafeRawBufferPointer(rebasing: raw[4...]), expected: max(payload.count * 4, 4096))
            }
            var offset = 0
            for bit in 0..<16 where flags & (1 << UInt32(bit)) != 0 {
                guard offset + 4 <= data.count else { break }
                let size = Int(UInt32(data[offset]) << 24 | UInt32(data[offset + 1]) << 16 | UInt32(data[offset + 2]) << 8 | UInt32(data[offset + 3]))
                offset += 4
                guard offset + size <= data.count else { break }
                if bit == 0 {
                    var bytes = Array(data[offset..<offset + size])
                    while bytes.last == 0 { bytes.removeLast() }
                    let text = String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
                    onEvent(.clipboard(text))
                }
                offset += size
            }
        }
    }

    private func sendProvide(_ text: String) {
        let utf8 = Array(text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n").utf8) + [0]
        let stream = be32(UInt32(utf8.count)) + utf8
        sendExtendedClipboard(Clip.provide | Clip.text, body: ZStream.deflate(stream))
    }

    private func sendExtendedClipboard(_ flags: UInt32, body: [UInt8] = []) {
        let payload = be32(flags) + body
        let length = -Int32(payload.count)
        transport.send([6, 0, 0, 0] + be32(UInt32(bitPattern: length)) + payload)
    }

    /// RGBA, premultiplied alpha. Only Raw sub-encoding is accepted (what TigerVNC sends); other encodings
    /// pack pixels in ways that drop the alpha byte.
    private func cursorWithAlpha(x: Int, y: Int, w: Int, h: Int) throws {
        let enc = try transport.s32()
        guard enc == Encoding.raw else { throw RFBError.protocol("alpha cursor in unsupported encoding \(enc)") }
        guard w > 0, h > 0 else { onEvent(.cursor(nil)); return }
        let rgba = try transport.bytes(w * h * 4)
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return }
        onEvent(.cursor(RemoteCursor(image: image, hotspot: CGPoint(x: x, y: y))))
    }

    // MARK: Client messages (thread-safe)

    private func sendPixelFormat() {
        // 32bpp, depth 24, little-endian, true colour, 8 bits per channel, R<<16 G<<8 B.
        transport.send([0, 0, 0, 0, 32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0])
    }

    private func sendEncodings() {
        if let forced = options.forcedEncodings {
            var msg: [UInt8] = [2, 0, UInt8(forced.count >> 8), UInt8(forced.count & 0xff)]
            for e in forced { msg += be32(UInt32(bitPattern: e)) }
            transport.send(msg)
            return
        }
        let current = lock.withLock { level }
        var encs: [Int32] = [Encoding.copyRect]
        switch current {
        case .lossless, .auto: encs += [Encoding.zrle, Encoding.tight]
        case .jpeg: encs += [Encoding.tight, Encoding.zrle]
        }
        encs += [Encoding.hextile, Encoding.zlib, Encoding.rre, Encoding.raw,
                 Encoding.cursorWithAlpha, Encoding.cursor, Encoding.desktopSize, Encoding.extendedDesktopSize,
                 Encoding.lastRect, Encoding.desktopName, Encoding.extendedClipboard,
                 Encoding.fence, Encoding.continuousUpdates]
        switch current {
        case .lossless, .auto: encs += [Encoding.compressLevel(1)]
        // Lower JPEG quality pairs with harder zlib for the tiles sent without JPEG.
        case .jpeg(let q): encs += [Encoding.jpegQuality(q), Encoding.compressLevel(q >= 8 ? 2 : q >= 5 ? 4 : 6)]
        }
        var msg: [UInt8] = [2, 0, UInt8(encs.count >> 8), UInt8(encs.count & 0xff)]
        for e in encs { msg += be32(UInt32(bitPattern: e)) }
        transport.send(msg)
    }

    package func requestUpdate(incremental: Bool) {
        guard let fb = framebuffer else { return }
        lock.withLock {
            pacedSince = nil
            if requestSince == nil { requestSince = DispatchTime.now().uptimeNanoseconds }
            if fenceWanted && serverPending == 0 { sendLatencyFenceLocked() }
            if !(incremental && serverCU) { serverPending += 1 }
            transport.send([3, incremental ? 1 : 0] + be16(0) + be16(0) + be16(fb.width) + be16(fb.height))
        }
    }

    package func sendKey(_ keysym: UInt32, down: Bool) {
        transport.send([4, down ? 1 : 0, 0, 0] + be32(keysym))
    }

    package func sendPointer(x: Int, y: Int, buttons: UInt8) {
        transport.send([5, buttons] + be16(max(0, x)) + be16(max(0, y)))
    }

    package func sendClipboard(_ text: String) {
        let extended = lock.withLock { () -> Bool in localClipboardText = text; return extClipboardActive }
        if extended {
            // Announce; the server asks for the data when it wants it.
            sendExtendedClipboard(Clip.notify | Clip.text)
            return
        }
        // Latin-1 is the only universally supported clipboard encoding; drop what doesn't fit.
        let bytes = Array(text.unicodeScalars.compactMap { $0.value < 256 ? UInt8($0.value) : UInt8(ascii: "?") }.prefix(1 << 20))
        transport.send([6, 0, 0, 0] + be32(UInt32(bytes.count)) + bytes)
    }

    /// Asks the server to change its desktop size (ExtendedDesktopSize servers only).
    package func requestDesktopSize(width: Int, height: Int) {
        let (ok, current) = lock.withLock { (_supportsResize, screens) }
        guard ok else { return }
        var layout = current.first ?? ScreenLayout(id: 0, x: 0, y: 0, w: 0, h: 0, flags: 0)
        layout.x = 0; layout.y = 0; layout.w = UInt16(width); layout.h = UInt16(height)
        var msg: [UInt8] = [251, 0] + be16(width) + be16(height) + [1, 0]
        msg += be32(layout.id) + be16(0) + be16(0) + be16(width) + be16(height) + be32(layout.flags)
        transport.send(msg)
    }
}

@inline(__always) package func be16(_ v: Int) -> [UInt8] { [UInt8((v >> 8) & 0xff), UInt8(v & 0xff)] }
@inline(__always) package func be32(_ v: UInt32) -> [UInt8] {
    [UInt8(v >> 24), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]
}
