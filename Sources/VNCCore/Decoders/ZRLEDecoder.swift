import Foundation

/// ZRLE (encoding 16): a zlib stream of 64x64 tiles, each raw, solid, packed-palette, or run-length encoded.
package final class ZRLEDecoder {
    private let stream = ZStream()
    private var tile = [UInt32](repeating: 0, count: 64 * 64)

    package init() {}

    package func reset() { stream.reset() }

    package func decode(_ t: Transport, _ fb: Framebuffer, x: Int, y: Int, w: Int, h: Int) throws {
        let len = Int(try t.u32())
        let data = try t.withBytes(len) { try stream.inflate($0, expected: w * h * 3 + 1024) }
        try data.withUnsafeBytes { raw in
            var c = ByteCursor(raw)
            try tile.withUnsafeMutableBufferPointer { tileBuf in
                let tp = tileBuf.baseAddress!
                var ty = y
                while ty < y + h {
                    let th = min(64, y + h - ty)
                    var tx = x
                    while tx < x + w {
                        let tw = min(64, x + w - tx)
                        try decodeTile(&c, tp, tw, th)
                        fb.blit(x: tx, y: ty, w: tw, h: th, from: tp)
                        tx += 64
                    }
                    ty += 64
                }
            }
        }
    }

    private func decodeTile(_ c: inout ByteCursor, _ out: UnsafeMutablePointer<UInt32>, _ w: Int, _ h: Int) throws {
        let sub = Int(try c.u8())
        let n = w * h
        switch sub {
        case 0:
            let p = try c.pointer(n * 3)
            for i in 0..<n {
                out[i] = 0xFF00_0000 | UInt32(p[i * 3 + 2]) << 16 | UInt32(p[i * 3 + 1]) << 8 | UInt32(p[i * 3])
            }
        case 1:
            out.update(repeating: try c.cpixelBGR(), count: n)
        case 2...16:
            var palette = [UInt32](repeating: 0, count: sub)
            for i in 0..<sub { palette[i] = try c.cpixelBGR() }
            let bits = sub == 2 ? 1 : (sub <= 4 ? 2 : 4)
            let mask = UInt8((1 << bits) - 1)
            let rowBytes = (w * bits + 7) / 8
            let p = try c.pointer(rowBytes * h)
            for yy in 0..<h {
                let row = p + yy * rowBytes
                for xx in 0..<w {
                    let bitPos = xx * bits
                    let shift = 8 - bits - (bitPos & 7)
                    let idx = Int((row[bitPos >> 3] >> UInt8(shift)) & mask)
                    out[yy * w + xx] = palette[min(idx, sub - 1)]
                }
            }
        case 128:
            var i = 0
            while i < n {
                let color = try c.cpixelBGR()
                let run = try runLength(&c)
                guard i + run <= n else { throw RFBError.protocol("ZRLE run overflow") }
                (out + i).update(repeating: color, count: run)
                i += run
            }
        case 130...255:
            let size = sub - 128
            var palette = [UInt32](repeating: 0, count: size)
            for i in 0..<size { palette[i] = try c.cpixelBGR() }
            var i = 0
            while i < n {
                let b = try c.u8()
                let color = palette[min(Int(b & 0x7f), size - 1)]
                let run = b & 0x80 != 0 ? try runLength(&c) : 1
                guard i + run <= n else { throw RFBError.protocol("ZRLE run overflow") }
                (out + i).update(repeating: color, count: run)
                i += run
            }
        default:
            throw RFBError.protocol("invalid ZRLE subencoding \(sub)")
        }
    }

    @inline(__always) private func runLength(_ c: inout ByteCursor) throws -> Int {
        var len = 1
        while true {
            let b = try c.u8()
            len += Int(b)
            if b != 255 { return len }
        }
    }
}
