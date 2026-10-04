// Copyright 2026 Ahimsa Labs
// SPDX-License-Identifier: Apache-2.0

import Foundation
import CommonCrypto
import CryptoKit
import VNCCore
import CZlib

private func hex(_ s: String) -> [UInt8] {
    var out: [UInt8] = []
    var i = s.startIndex
    while i < s.endIndex {
        let j = s.index(i, offsetBy: 2)
        out.append(UInt8(s[i..<j], radix: 16)!)
        i = j
    }
    return out
}

// RFC 2409 Oakley group 2, the same size (128 bytes) macOS Screen Sharing uses.
let oakley2 = hex("FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74020BBEA63B139B22514A08798E3404DDEF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7EDEE386BFB5A899FA5AE9F24117C4B1FE649286651ECE65381FFFFFFFFFFFFFFFF")

struct ModularTests {
    let x = hex("6b65a6a48b8148f6b38a088ca65ed389b74d0fb132e706298fadc1a606cb0fb39a1de644815ef6d13b8faa1837f8a88b17fc695a07a0ca6e0822e8f36c031199972a846916419f828b9d2434e465e150bd9c66b3ad3c2d6d1a3d1fa7bc8960a923b8c1e9392456de3eb13b9046685257bdd640fb06671ad11c80317fa3b1799d")

    func generatorPowerMatchesPython() {
        let ctx = ModularContext(modulusBigEndian: oakley2)
        var g = [UInt8](repeating: 0, count: 128); g[127] = 2
        let r = ctx.modPow(base: g, exponent: x)
        expect(r == hex("4ca9287fbc019392051d6f88c4f9150d5fef8bc97f2d884dfa9d2346fed7852051266e4b0d83167a6d6fb3657ab197c2ffc73bda6b65a52cd3012ed79a0aea54fbcd3b0f49564cce45ef0bf10e819b6f99c8a9810af385d45a3daf7224b25370bfba7174a6c9a661426d27d22f4e0d3f1cb17d0732920dc8c5ebcff2cf4679d5"))
    }

    func arbitraryBaseMatchesPython() {
        let ctx = ModularContext(modulusBigEndian: oakley2)
        let base = hex("759cde66bacfb3d00b1f9163ce9ff57f43b7a3a69a8dca03580d7b71d8f564135be6128e18c267976142ea7d17be31111a2a73ed562b0f79c37459eef50bea63371ecd7b27cd813047229389571aa8766c307511b2b9437a28df6ec4ce4a2bbdc241330b01a9e71fde8a774bcf36d58b4737819096da1dac72ff5d2a386ecbe0")
        expect(ctx.modPow(base: base, exponent: x) == hex("c88e15aaa683aa75b6fd22b4ef6bf748f7b7bf5350c2210f4f5c06b44a8814f7344e1133a05cbb22f65f4a6231c1de7312711976a46c91fe2a2673af5d0cfc09bbc5cb0e21f54ab68e9f1c508c84f56ae2ae1828c6108b2c3b7d0f5e2aeaf78a40f037cbd8447c085afc8adaca94a5bb9cca74456a7921d8b04a6001f979db86"))
    }

    func smallModulus() {
        // 7^560 mod 561 = 1 (Carmichael number); 3^200 mod 1009 = 985 (Python).
        let ctx = ModularContext(modulusBigEndian: [0x02, 0x31])
        expect(ctx.modPow(base: [7], exponent: [0x02, 0x30]).last == 1)
        let ctx2 = ModularContext(modulusBigEndian: [0x03, 0xf1])
        let r = ctx2.modPow(base: [3], exponent: [200])
        expect(Int(r[r.count - 2]) << 8 | Int(r[r.count - 1]) == 985)
    }
}

struct AuthTests {
    func vncAuthMatchesOpenSSL() throws {
        let challenge = hex("00112233445566778899aabbccddeeff")
        let response = try VNCAuth.respond(challenge: challenge, password: "testpass")
        expect(response == hex("2d745afb7db563e1055ec273fe91e9d6"))
    }

    /// Plays the server side of Apple's DH handshake and checks it can decrypt what the client sent.
    func ardRoundTrip() throws {
        let ctx = ModularContext(modulusBigEndian: oakley2)
        var serverPrivate = [UInt8](repeating: 0, count: 128)
        for i in 0..<128 { serverPrivate[i] = UInt8((i * 37 + 11) & 0xff) }
        var g = [UInt8](repeating: 0, count: 128); g[127] = 2
        let serverPublic = ctx.modPow(base: g, exponent: serverPrivate)

        let response = try ARDAuth.respond(to: .init(generator: 2, keyLength: 128, prime: oakley2, serverPublicKey: serverPublic),
                                           username: "alice", password: "s3cret pw")
        expect(response.count == 256)
        let encrypted = Array(response[0..<128])
        let clientPublic = Array(response[128..<256])
        let shared = ctx.modPow(base: clientPublic, exponent: serverPrivate)
        let key = Array(Insecure.MD5.hash(data: Data(shared)))

        var plain = [UInt8](repeating: 0, count: 128)
        var moved = 0
        let status = CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES128), CCOptions(kCCOptionECBMode),
                             key, kCCKeySizeAES128, nil, encrypted, 128, &plain, 128, &moved)
        expect(status == kCCSuccess)
        expect(Array(plain[0..<6]) == Array("alice".utf8) + [0])
        expect(Array(plain[64..<74]) == Array("s3cret pw".utf8) + [0])
    }
}

struct AddressTests {
    static let cases: [(String, String, Int, String)] = [
        ("mac.example.ts.net", "mac.example.ts.net", 5900, ""),
        ("host:1", "host", 5901, ""),
        ("host:5905", "host", 5905, ""),
        ("host::42", "host", 42, ""),
        ("bob@host", "host", 5900, "bob"),
        ("vnc://bob@mac.local:5901", "mac.local", 5901, "bob"),
        ("vnc://10.0.0.2", "10.0.0.2", 5900, ""),
        ("[fe80::1]:5902", "fe80::1", 5902, ""),
        ("fd7a:115c:a1e0::1", "fd7a:115c:a1e0::1", 5900, ""),
    ]
    func parse() {
        for (input, host, port, user) in Self.cases {
            expect(Address.parse(input) == Address(host: host, port: port, username: user), input)
        }
    }

    func rejectsGarbage() {
        expect(Address.parse("") == nil)
        expect(Address.parse("host:abc") == nil)
    }
}

private func deflate(_ input: [UInt8]) -> [UInt8] {
    var outLen = compressBound(uLong(input.count))
    var out = [UInt8](repeating: 0, count: Int(outLen))
    precondition(compress2(&out, &outLen, input, uLong(input.count), 6) == Z_OK)
    return Array(out[0..<Int(outLen)])
}

private func be32(_ v: Int) -> [UInt8] { [UInt8(v >> 24 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)] }

struct DecoderTests {
    let red: UInt32 = 0xFFFF_0000, green: UInt32 = 0xFF00_FF00, blue: UInt32 = 0xFF00_00FF, white: UInt32 = 0xFFFF_FFFF

    /// One 70x10 rectangle = two tiles: solid red (64x10) then a 2-colour packed palette tile (6x10).
    /// Then a 64x2 rectangle with plain RLE, and a 5x1 rectangle with palette RLE.
    func zrleTiles() throws {
        let fb = Framebuffer(width: 80, height: 20)
        let bgr = { (c: UInt32) -> [UInt8] in [UInt8(c & 0xff), UInt8(c >> 8 & 0xff), UInt8(c >> 16 & 0xff)] }
        var raw: [UInt8] = [1] + bgr(red)
        raw += [2] + bgr(green) + bgr(blue)
        for y in 0..<10 { raw.append(y % 2 == 0 ? 0b1010_1000 : 0b0101_0100) } // 6 px per row, 1 bit each
        let compressed1 = deflate(raw)
        let decoder = ZRLEDecoder()
        try decoder.decode(Transport(bytes: be32(compressed1.count) + compressed1), fb, x: 2, y: 3, w: 70, h: 10)
        expect(fb.row(3)[2] == red && fb.row(12)[65] == red, "solid tile")
        expect(fb.row(3)[66] == blue && fb.row(3)[67] == green && fb.row(4)[66] == green && fb.row(4)[67] == blue, "packed palette")
        expect(fb.row(3)[1] != red && fb.row(13)[2] != red, "no overdraw outside the rectangle")

        // Plain RLE: 100 white then 28 red over 64x2 = 128 pixels. Run lengths are (len-1) as 255-continued bytes.
        // Each rectangle uses a fresh decoder because a decoder's zlib stream persists across rectangles.
        let d2 = ZRLEDecoder()
        let fb2 = Framebuffer(width: 64, height: 3)
        let onlyRLE: [UInt8] = [128] + bgr(white) + [99] + bgr(red) + [27]
        let c3 = deflate(onlyRLE)
        try d2.decode(Transport(bytes: be32(c3.count) + c3), fb2, x: 0, y: 0, w: 64, h: 2)
        expect(fb2.row(0)[0] == white && fb2.row(1)[35] == white && fb2.row(1)[36] == red && fb2.row(1)[63] == red, "plain RLE")

        let fb3 = Framebuffer(width: 5, height: 1)
        // Built in steps: one long `+` chain times out Swift 6.0's type checker.
        var palRLE: [UInt8] = [131] // palette RLE, 3 colours
        palRLE += bgr(green) + bgr(blue) + bgr(white)
        palRLE += [0x81, 2, 0, 2] // index 1 run of 3, then 0, then 2
        let c4 = deflate(palRLE)
        try ZRLEDecoder().decode(Transport(bytes: be32(c4.count) + c4), fb3, x: 0, y: 0, w: 5, h: 1)
        expect(Array(UnsafeBufferPointer(start: fb3.row(0), count: 5)) == [blue, blue, blue, green, white], "palette RLE")
    }

    func tightFilters() throws {
        // Palette filter, 2 colours => 1 bit per pixel, 4x2 => 2 bytes (< 12, so sent uncompressed).
        let fb = Framebuffer(width: 4, height: 2)
        let tight = TightDecoder()
        let control: UInt8 = 0x40           // basic compression, stream 0, explicit filter
        var msg: [UInt8] = [control, 1, 1]  // filter = palette, (2 colours - 1)
        msg += [255, 0, 0, 0, 0, 255]       // red, blue (RGB order)
        msg += [0b1001_0000, 0b0110_0000]
        try tight.decode(Transport(bytes: msg), fb, x: 0, y: 0, w: 4, h: 2)
        expect(Array(UnsafeBufferPointer(start: fb.row(0), count: 4)) == [blue, red, red, blue], "tight mono palette row 0")
        expect(Array(UnsafeBufferPointer(start: fb.row(1), count: 4)) == [red, blue, blue, red], "tight mono palette row 1")

        // Gradient filter on a 5x4 image, compressed.
        let w = 5, h = 4
        var img = [[UInt8]](repeating: [0, 0, 0], count: w * h)
        for y in 0..<h { for x in 0..<w { img[y * w + x] = [UInt8(x * 40 + y), UInt8(200 - y * 30), UInt8((x * y * 17) & 0xff)] } }
        var encoded: [UInt8] = []
        func px(_ x: Int, _ y: Int, _ c: Int) -> Int { x < 0 || y < 0 ? 0 : Int(img[y * w + x][c]) }
        for y in 0..<h { for x in 0..<w { for c in 0..<3 {
            let pred = min(255, max(0, px(x - 1, y, c) + px(x, y - 1, c) - px(x - 1, y - 1, c)))
            encoded.append(UInt8((Int(img[y * w + x][c]) - pred) & 0xff))
        } } }
        let z = deflate(encoded)
        var msg2: [UInt8] = [0x40, 2] // stream 0 (fresh decoder), gradient filter
        precondition(z.count < 128)
        msg2 += [UInt8(z.count)] + z
        let fb2 = Framebuffer(width: w, height: h)
        try TightDecoder().decode(Transport(bytes: msg2), fb2, x: 0, y: 0, w: w, h: h)
        var ok = true
        for y in 0..<h { for x in 0..<w {
            let p = img[y * w + x]
            if fb2.row(y)[x] != 0xFF00_0000 | UInt32(p[0]) << 16 | UInt32(p[1]) << 8 | UInt32(p[2]) { ok = false }
        } }
        expect(ok, "gradient filter reconstructs the image")

        // Fill
        let fb3 = Framebuffer(width: 3, height: 3)
        try TightDecoder().decode(Transport(bytes: [0x80, 1, 2, 3]), fb3, x: 1, y: 1, w: 2, h: 2)
        expect(fb3.row(1)[1] == 0xFF01_0203 && fb3.row(2)[2] == 0xFF01_0203 && fb3.row(0)[0] != 0xFF01_0203, "tight fill")
    }
}

struct WakeTests {
    func macParsing() {
        let m: [UInt8] = [0xaa, 0xbb, 0xcc, 0x01, 0x02, 0x03]
        expect(WakeOnLAN.parseMAC("aa:bb:cc:01:02:03") == m)
        expect(WakeOnLAN.parseMAC("AA-BB-CC-01-02-03") == m)
        expect(WakeOnLAN.parseMAC("aabb.cc01.0203") == m)
        expect(WakeOnLAN.parseMAC("aa:bb:cc:01:02") == nil)
        expect(WakeOnLAN.parseMAC("zz:bb:cc:01:02:03") == nil)
        let p = WakeOnLAN.packet(m)
        expect(p.count == 102 && p.prefix(6).allSatisfy { $0 == 0xff } && Array(p[96..<102]) == m)
    }
}

struct QualityTests {
    func rawValues() throws {
        expect(Quality(rawValue: "balanced") == .jpeg(8), "earlier 'balanced' reads as JPEG 8")
        expect(Quality(rawValue: "low") == .jpeg(4), "earlier 'low' reads as JPEG 4")
        expect(Quality(rawValue: "jpeg10") == nil && Quality(rawValue: "jpeg") == nil)
        for q in Quality.allCases { expect(Quality(rawValue: q.rawValue) == q, "\(q.rawValue) round-trips") }
        let data = try JSONEncoder().encode([Quality.jpeg(3), .lossless])
        expect(String(decoding: data, as: UTF8.self) == #"["jpeg3","lossless"]"#)
        expect(try JSONDecoder().decode([Quality].self, from: Data(#"["balanced","auto"]"#.utf8)) == [.jpeg(8), .auto])
        expect(Quality.levels.map(\.rank) == Array((0...10).reversed()), "levels run from lossless down to JPEG 0")
    }
}

struct MotionTests {
    func cellRects() {
        // 10×5 grid of 100-pixel cells over a 1000×450 framebuffer (the last row is clipped to 50 pixels).
        let cols = 10
        var cells = Set<Int>()
        for row in 1...3 { for col in 2...4 { cells.insert(row * cols + col) } } // a 3×3 block
        cells.insert(4 * cols + 9) // a lone cell in the clipped bottom-right corner
        let rects = RFBClient.cellRects(cells, cell: 100, width: 1000, height: 450)
        expect(rects == [CGRect(x: 200, y: 100, width: 300, height: 300), CGRect(x: 900, y: 400, width: 100, height: 50)],
               "block merges into one rect, corner cell is clipped: \(rects)")
        // Rows with different spans stay separate.
        let stairs = RFBClient.cellRects([0, 1, 11], cell: 100, width: 1000, height: 450)
        expect(stairs == [CGRect(x: 0, y: 0, width: 200, height: 100), CGRect(x: 100, y: 100, width: 100, height: 100)], "\(stairs)")
    }
}
