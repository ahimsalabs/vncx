// Copyright 2026 Ahimsa Labs
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Network
import CoreGraphics

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

package enum Quality: String, Codable, CaseIterable, Identifiable {
    case auto, lossless, balanced, low
    package var id: String { rawValue }
    package var label: String {
        switch self {
        case .auto: return "Automatic"
        case .lossless: return "Best (lossless)"
        case .balanced: return "Balanced"
        case .low: return "Low bandwidth"
        }
    }
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
    private var lastRequestAt: UInt64 = 0
    /// When the oldest unanswered latency fence was sent.
    private var fencePendingSince: UInt64?
    /// A latency fence to send just before the next update request (see `measureLatency`).
    private var fenceBeforeRequest = false
    private let pacer = DispatchQueue(label: "vncx.pacer", qos: .userInteractive)

    package func statsSnapshot() -> RFBStats {
        lock.withLock {
            var s = stats
            s.bytes = transport.bytesReceived &- UInt64(transport.buffered)
            s.continuousUpdates = cuEnabled && !cuStopping
            s.fenceSupported = fenceSupported
            s.level = level
            s.limit = limit
            // An unanswered fence is at least as slow as its age, so a stalled stream shows rising latency. Only
            // with continuous updates: when polling, an idle server may hold the reply until it has an update.
            if cuEnabled && !cuStopping, let sent = fencePendingSince {
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
        if changed { sendEncodings() }
    }

    /// Sends a fence carrying a timestamp; the reply gives the round-trip time.
    /// When polling, the fence waits for the next update request instead: some servers (WayVNC) hold a fence reply
    /// behind an outstanding request until the screen changes, which would read as seconds of latency.
    package func measureLatency() {
        let now = lock.withLock { () -> Bool in
            guard fenceSupported else { return false }
            if cuEnabled && !cuStopping { return true }
            fenceBeforeRequest = true
            return false
        }
        if now { sendLatencyFence() }
    }

    private func sendLatencyFence() {
        let now = DispatchTime.now().uptimeNanoseconds
        lock.withLock { if fencePendingSince == nil { fencePendingSince = now } }
        let payload = (0..<8).map { UInt8(truncatingIfNeeded: now >> (56 - 8 * UInt64($0))) }
        sendFence(flags: Fence.request | Fence.blockBefore, payload: payload)
    }

    /// The longest a paced request waits, so one big update (a full refresh) costs a slow frame, not a freeze.
    private static let maxPacingWait = 1.5

    /// Caps the server's sending rate (bits/s; nil for no limit). With a limit, continuous updates are turned off and
    /// update requests are paced instead: after an update of B bytes, the next request waits until B / limit has
    /// passed since the previous one. Small updates (typing, pointer) go out at once; big ones (video) slow down.
    package func setBandwidthLimit(_ bitsPerSecond: Double?) {
        enum Change { case none, stop, start }
        let change = lock.withLock { () -> Change in
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
        let due = lock.withLock { () -> UInt64? in
            guard let limit else { return nil }
            return lastRequestAt &+ UInt64(min(Double(bytes) * 8 / limit, Self.maxPacingWait) * 1e9)
        }
        guard let due, due > now else { return requestUpdate(incremental: true) }
        pacer.asyncAfter(deadline: DispatchTime(uptimeNanoseconds: due)) { [weak self] in
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
        transport.send([150, enable ? 1 : 0] + be16(0) + be16(0) + be16(fb.width) + be16(fb.height))
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
            }
            traceRect?(enc, x, y, w, h)
            guard let fb = framebuffer else { throw RFBError.protocol("update before init") }
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
        let total = consumed &- startBytes
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - startTime) / 1e9
        let continuous = lock.withLock { () -> Bool in
            stats.updates += 1
            for (e, n) in rectCounts { stats.rectCount[e, default: 0] += n }
            for (e, b) in rectBytes { stats.rectBytes[e, default: 0] += b }
            // Only large updates say anything about the link; small ones are dominated by latency.
            if total > 48 * 1024, elapsed > 0.002 {
                let sample = Double(total) / elapsed
                stats.linkRate = stats.linkRate.map { $0 * 0.7 + sample * 0.3 } ?? sample
            }
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
        case .balanced, .low: encs += [Encoding.tight, Encoding.zrle]
        }
        encs += [Encoding.hextile, Encoding.zlib, Encoding.rre, Encoding.raw,
                 Encoding.cursorWithAlpha, Encoding.cursor, Encoding.desktopSize, Encoding.extendedDesktopSize,
                 Encoding.lastRect, Encoding.desktopName, Encoding.extendedClipboard,
                 Encoding.fence, Encoding.continuousUpdates]
        switch current {
        case .lossless, .auto: encs += [Encoding.compressLevel(1)]
        case .balanced: encs += [Encoding.jpegQuality(8), Encoding.compressLevel(2)]
        case .low: encs += [Encoding.jpegQuality(4), Encoding.compressLevel(6)]
        }
        var msg: [UInt8] = [2, 0, UInt8(encs.count >> 8), UInt8(encs.count & 0xff)]
        for e in encs { msg += be32(UInt32(bitPattern: e)) }
        transport.send(msg)
    }

    package func requestUpdate(incremental: Bool) {
        guard let fb = framebuffer else { return }
        let fence = lock.withLock { () -> Bool in
            lastRequestAt = DispatchTime.now().uptimeNanoseconds
            defer { fenceBeforeRequest = false }
            return fenceBeforeRequest
        }
        if fence { sendLatencyFence() }
        transport.send([3, incremental ? 1 : 0] + be16(0) + be16(0) + be16(fb.width) + be16(fb.height))
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
