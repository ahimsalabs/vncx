// Copyright 2026 Ahimsa Labs
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Raw, CopyRect, RRE, Hextile and Zlib decoding. All assume the negotiated 32bpp little-endian pixel format.
package enum BasicDecoders {
    package static func raw(_ t: Transport, _ fb: Framebuffer, x: Int, y: Int, w: Int, h: Int) throws {
        // Read row by row so a huge raw rectangle doesn't need one giant buffer.
        let rowBytes = w * 4
        let rowsPerChunk = max(1, (1 << 20) / max(rowBytes, 1))
        var row = 0
        while row < h {
            let n = min(rowsPerChunk, h - row)
            try t.withBytes(n * rowBytes) { buf in
                fb.blit(x: x, y: y + row, w: w, h: n, from: buf.baseAddress!.assumingMemoryBound(to: UInt32.self))
            }
            row += n
        }
    }

    package static func copyRect(_ t: Transport, _ fb: Framebuffer, x: Int, y: Int, w: Int, h: Int) throws {
        let sx = Int(try t.u16()), sy = Int(try t.u16())
        fb.copyRect(srcX: sx, srcY: sy, x: x, y: y, w: w, h: h)
    }

    @inline(__always) package static func pixel(_ t: Transport) throws -> UInt32 {
        let p = try t.peek(4).loadUnaligned(as: UInt32.self); t.consume(4); return p | 0xFF00_0000
    }

    package static func rre(_ t: Transport, _ fb: Framebuffer, x: Int, y: Int, w: Int, h: Int) throws {
        let n = Int(try t.u32())
        fb.fill(x: x, y: y, w: w, h: h, color: try pixel(t))
        for _ in 0..<n {
            let c = try pixel(t)
            let sx = Int(try t.u16()), sy = Int(try t.u16()), sw = Int(try t.u16()), sh = Int(try t.u16())
            fb.fill(x: x + sx, y: y + sy, w: sw, h: sh, color: c)
        }
    }

    package static func hextile(_ t: Transport, _ fb: Framebuffer, x: Int, y: Int, w: Int, h: Int) throws {
        var bg: UInt32 = 0xFF00_0000, fg: UInt32 = 0xFFFF_FFFF
        var ty = y
        while ty < y + h {
            let th = min(16, y + h - ty)
            var tx = x
            while tx < x + w {
                let tw = min(16, x + w - tx)
                let mask = try t.u8()
                if mask & 1 != 0 {
                    try t.withBytes(tw * th * 4) { buf in
                        fb.blit(x: tx, y: ty, w: tw, h: th, from: buf.baseAddress!.assumingMemoryBound(to: UInt32.self))
                    }
                } else {
                    if mask & 2 != 0 { bg = try pixel(t) }
                    fb.fill(x: tx, y: ty, w: tw, h: th, color: bg)
                    if mask & 4 != 0 { fg = try pixel(t) }
                    if mask & 8 != 0 {
                        let count = Int(try t.u8())
                        let coloured = mask & 16 != 0
                        for _ in 0..<count {
                            let c = coloured ? try pixel(t) : fg
                            let xy = try t.u8(), wh = try t.u8()
                            fb.fill(x: tx + Int(xy >> 4), y: ty + Int(xy & 15),
                                    w: Int(wh >> 4) + 1, h: Int(wh & 15) + 1, color: c)
                        }
                    }
                }
                tx += 16
            }
            ty += 16
        }
    }

    package static func zlib(_ t: Transport, _ fb: Framebuffer, stream: ZStream, x: Int, y: Int, w: Int, h: Int) throws {
        let len = Int(try t.u32())
        let data = try t.withBytes(len) { try stream.inflate($0, expected: w * h * 4) }
        guard data.count >= w * h * 4 else { throw RFBError.protocol("short zlib rectangle") }
        data.withUnsafeBytes { fb.blit(x: x, y: y, w: w, h: h, from: $0.baseAddress!.assumingMemoryBound(to: UInt32.self)) }
    }
}
