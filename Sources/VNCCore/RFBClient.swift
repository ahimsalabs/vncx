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
    case lossless, balanced, low
    package var id: String { rawValue }
    package var label: String {
        switch self {
        case .lossless: return "Best (lossless)"
        case .balanced: return "Balanced"
        case .low: return "Low bandwidth"
        }
    }
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

package struct ScreenLayout: Sendable {
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

    /// Credentials actually used for a successful login (so the UI can offer to save them).
    package private(set) var usedCredentials: Credentials?

    package var supportsRemoteResize: Bool { lock.withLock { _supportsResize } }
    package var bytesReceived: UInt64 { transport.bytesReceived }
    package private(set) var isAppleServer = false
    /// Debug hook: called on the protocol thread for every rectangle header (encoding, x, y, w, h).
    package var traceRect: ((Int32, Int, Int, Int, Int) -> Void)?

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
            case 3:
                try transport.skip(3)
                let len = Int(try transport.u32())
                let bytes = try transport.bytes(min(len, 16 << 20))
                if len > 16 << 20 { try transport.skip(len - (16 << 20)) }
                // RFB clipboard text is ISO 8859-1.
                onEvent(.clipboard(String(bytes: bytes, encoding: .isoLatin1) ?? ""))
            default:
                throw RFBError.protocol("unknown server message type \(type)")
            }
        }
    }

    private func framebufferUpdate() throws {
        try transport.skip(1)
        let count = Int(try transport.u16())
        var i = 0
        while count == 0xFFFF || i < count {
            i += 1
            let x = Int(try transport.u16()), y = Int(try transport.u16())
            let w = Int(try transport.u16()), h = Int(try transport.u16())
            let enc = try transport.s32()
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
        requestUpdate(incremental: true)
        onEvent(.updated)
    }

    private func resize(_ w: Int, _ h: Int) {
        guard let old = framebuffer, old.width != w || old.height != h else { return }
        let fb = Framebuffer(width: w, height: h)
        fb.copyContents(of: old)
        framebuffer = fb
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
        if status == 0 { resize(w, h) }
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
        var encs: [Int32] = [Encoding.copyRect]
        switch options.quality {
        case .lossless: encs += [Encoding.zrle, Encoding.tight]
        case .balanced, .low: encs += [Encoding.tight, Encoding.zrle]
        }
        encs += [Encoding.hextile, Encoding.zlib, Encoding.rre, Encoding.raw,
                 Encoding.cursor, Encoding.desktopSize, Encoding.extendedDesktopSize,
                 Encoding.lastRect, Encoding.desktopName]
        switch options.quality {
        case .lossless: encs += [Encoding.compressLevel(1)]
        case .balanced: encs += [Encoding.jpegQuality(8), Encoding.compressLevel(2)]
        case .low: encs += [Encoding.jpegQuality(4), Encoding.compressLevel(6)]
        }
        var msg: [UInt8] = [2, 0, UInt8(encs.count >> 8), UInt8(encs.count & 0xff)]
        for e in encs { msg += be32(UInt32(bitPattern: e)) }
        transport.send(msg)
    }

    package func requestUpdate(incremental: Bool) {
        guard let fb = framebuffer else { return }
        transport.send([3, incremental ? 1 : 0] + be16(0) + be16(0) + be16(fb.width) + be16(fb.height))
    }

    package func sendKey(_ keysym: UInt32, down: Bool) {
        transport.send([4, down ? 1 : 0, 0, 0] + be32(keysym))
    }

    package func sendPointer(x: Int, y: Int, buttons: UInt8) {
        transport.send([5, buttons] + be16(max(0, x)) + be16(max(0, y)))
    }

    package func sendClipboard(_ text: String) {
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
