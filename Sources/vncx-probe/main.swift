// vncx-probe: connects to a VNC server headlessly, receives frames, and writes a PNG of the framebuffer.
// Exercises auth and decoders against real servers without the UI.
//
//   vncx-probe host[:port] [--password PW] [--user NAME] [--encoding raw|copyrect|rre|hextile|zlib|tight|zrle|tightjpeg]
//              [--frames N] [--seconds S] [--out file.png] [--resize WxH]
import Foundation
import Network
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import VNCCore

var args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let v = args[i + 1]; args.removeSubrange(i...i + 1); return v
}
let password = option("--password") ?? ProcessInfo.processInfo.environment["VNC_PASSWORD"]
let user = option("--user") ?? ""
let encodingName = option("--encoding")
let frames = Int(option("--frames") ?? "3") ?? 3
let seconds = Double(option("--seconds") ?? "20") ?? 20
let out = option("--out")
let resize = option("--resize")
let clipboardOut = option("--clipboard")
let move = args.contains("--move")
args.removeAll { $0 == "--move" }
guard let target = args.first, let addr = Address.parse(target) else {
    FileHandle.standardError.write("usage: vncx-probe host[:port] [--password PW] [--user NAME] [--encoding E] [--frames N] [--out file.png]\n".data(using: .utf8)!)
    exit(2)
}

var options = RFBOptions(endpoint: .hostPort(host: .init(addr.host), port: .init(integerLiteral: UInt16(addr.port))),
                         username: user, password: password)
let pseudo: [Int32] = [Encoding.cursor, Encoding.desktopSize, Encoding.extendedDesktopSize, Encoding.lastRect, Encoding.desktopName]
if let e = encodingName {
    let map: [String: [Int32]] = [
        "raw": [Encoding.raw], "copyrect": [Encoding.copyRect, Encoding.raw], "rre": [Encoding.rre, Encoding.raw],
        "hextile": [Encoding.hextile, Encoding.raw], "zlib": [Encoding.zlib, Encoding.raw],
        "tight": [Encoding.tight, Encoding.raw], "zrle": [Encoding.zrle, Encoding.raw],
        "tightjpeg": [Encoding.tight, Encoding.raw, Encoding.jpegQuality(6)],
    ]
    guard let list = map[e] else { print("unknown encoding \(e)"); exit(2) }
    options.forcedEncodings = list + pseudo
}

let done = DispatchSemaphore(value: 0)
var framebuffer: Framebuffer?
var updates = 0
var failure: Error?
var client: RFBClient!
let start = Date()
var resized = false

client = RFBClient(options: options, credentialProvider: { req in
    // Ask on the terminal (no echo) so passwords stay out of shell history.
    guard isatty(STDIN_FILENO) != 0, let pw = getpass("Password for \(user.isEmpty ? target : "\(user)@\(target)"): ") else {
        print("server wants credentials (\(req.securityType.name)) and none were given")
        return nil
    }
    return Credentials(username: user, password: String(cString: pw), remember: false)
}, onEvent: { event in
    switch event {
    case .connected(let name, let fb, let sec):
        framebuffer = fb
        print(String(format: "connected in %.2fs: \"%@\" %dx%d security=%@ apple=%@",
                     Date().timeIntervalSince(start), name, fb.width, fb.height, sec?.name ?? "?", client.isAppleServer ? "yes" : "no"))
    case .resized(let fb):
        framebuffer = fb
        print("resized to \(fb.width)x\(fb.height)")
        if resize != nil { resized = true }
    case .updated:
        updates += 1
        if updates == 1 { print(String(format: "first update after %.2fs, %d bytes", Date().timeIntervalSince(start), client.bytesReceived)) }
        if updates == 1, let r = resize, let x = r.firstIndex(of: "x"), let w = Int(r[..<x]), let h = Int(r[r.index(after: x)...]) {
            print("requesting desktop size \(w)x\(h) (supported=\(client.supportsRemoteResize))")
            client.requestDesktopSize(width: w, height: h)
        }
        if updates == 2 { client.measureLatency() }
        if updates == 1, let clip = clipboardOut {
            print("sending clipboard \(clip.debugDescription) (unicode=\(client.supportsUnicodeClipboard))")
            client.sendClipboard(clip)
        }
        if updates == 1 && move {
            // Sweep the pointer diagonally across the desktop so the server sends cursor shape changes.
            DispatchQueue.global().async {
                guard let fb = framebuffer else { return }
                for i in 0...60 {
                    client.sendPointer(x: fb.width * i / 60, y: fb.height * i / 60, buttons: 0)
                    usleep(30_000)
                }
            }
        }
        if updates >= frames && (resize == nil || resized) { DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { client.stop() } }
    case .cursor(let c):
        if let c { print("cursor \(c.image.width)x\(c.image.height) hotspot \(c.hotspot)") }
    case .clipboard(let text):
        print("clipboard from server: \(text.debugDescription)")
    case .bell, .nameChanged:
        break
    case .disconnected(let err):
        failure = err
        done.signal()
    }
})
var histogram: [Int32: Int] = [:]
if ProcessInfo.processInfo.environment["TRACE"] != nil {
    client.traceRect = { enc, x, y, w, h in
        histogram[enc, default: 0] += 1
        if enc < 0 || histogram[enc]! <= 3 { print("  rect enc=\(enc) \(x),\(y) \(w)x\(h)") }
    }
}
client.traceScreens = { reason, status, list in
    print("  layout reason=\(reason) status=\(status): \(list.map(\.description).joined(separator: ", "))")
}
client.start()
if done.wait(timeout: .now() + seconds) == .timedOut {
    print("timeout after \(seconds)s with \(updates) updates")
    client.stop()
    _ = done.wait(timeout: .now() + 2)
}
do {
    let st = client.statsSnapshot()
    let enc = st.rectCount.sorted { $0.key < $1.key }.map { "\(Encoding.name($0.key))×\($0.value)/\(st.rectBytes[$0.key] ?? 0)B" }.joined(separator: " ")
    print(String(format: "stats: updates=%d bytes=%llu link=%@ rtt=%@ continuous=%@ fence=%@ level=%@",
                 st.updates, st.bytes, st.linkRate.map { String(format: "%.1f Mbit/s", $0 * 8 / 1e6) } ?? "-",
                 st.rtt.map { String(format: "%.1f ms", $0 * 1000) } ?? "-", st.continuousUpdates ? "yes" : "no",
                 st.fenceSupported ? "yes" : "no", st.level.rawValue))
    print("  rects: \(enc)")
}
if !histogram.isEmpty { print("encodings seen:", histogram.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: " ")) }
let elapsed = Date().timeIntervalSince(start)
print(String(format: "%d updates, %.1f KB in %.2fs", updates, Double(client.bytesReceived) / 1024, elapsed))

if let fb = framebuffer, let out {
    let ctx = CGContext(data: fb.pixels, width: fb.width, height: fb.height, bitsPerComponent: 8, bytesPerRow: fb.bytesPerRow,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue)!
    let image = ctx.makeImage()!
    let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
    print("wrote \(out)")
}
if let failure {
    print("error: \(failure.localizedDescription)")
    exit(1)
}
exit(updates > 0 ? 0 : 1)
