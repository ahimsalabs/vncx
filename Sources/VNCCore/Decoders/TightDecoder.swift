// Copyright 2026 Ahimsa Labs
// SPDX-License-Identifier: Apache-2.0

import Foundation
import ImageIO
import CoreGraphics

/// Tight (encoding 7): fill, JPEG, or zlib-compressed basic data with copy/palette/gradient filters
/// over four persistent zlib streams. TPIXELs are 3 bytes in R, G, B order for our 24-bit depth format.
package final class TightDecoder {
    private var streams = (0..<4).map { _ in ZStream() }
    private var scratch = [UInt32]()
    /// JPEG rectangles read but not yet decoded. Decoding a JPEG costs about 100 µs however small it is, and some
    /// servers (WayVNC) send every 64×64 tile as its own JPEG, so a scroll repaint is a thousand of them: decoding
    /// them one by one on the reader thread caps the frame rate. They cover separate areas, so a batch is decoded
    /// in parallel. Call `flush` before anything else draws (another rectangle) and at the end of each update.
    private var pendingJPEG: [(data: Data, x: Int, y: Int, w: Int, h: Int)] = []
    private static let batchSize = 64

    package init() {}

    /// Decodes the JPEG rectangles read so far into the framebuffer.
    package func flush(_ fb: Framebuffer) throws {
        guard !pendingJPEG.isEmpty else { return }
        let batch = pendingJPEG
        pendingJPEG.removeAll(keepingCapacity: true)
        let failed = ManagedAtomicFlag()
        DispatchQueue.concurrentPerform(iterations: batch.count) { i in
            let j = batch[i]
            do { try Self.decodeJPEG(j.data, fb, x: j.x, y: j.y, w: j.w, h: j.h) } catch { failed.set() }
        }
        if failed.isSet { throw RFBError.protocol("invalid JPEG rectangle") }
    }

    package func reset() { streams.forEach { $0.reset() } }

    package func decode(_ t: Transport, _ fb: Framebuffer, x: Int, y: Int, w: Int, h: Int) throws {
        let control = try t.u8()
        for i in 0..<4 where control & (1 << i) != 0 { streams[i].reset() }
        let kind = control >> 4
        if kind != 0x09 { try flush(fb) } // keep drawing order: pending JPEGs land first

        if kind == 0x08 { // fill
            let p = try t.bytes(3)
            fb.fill(x: x, y: y, w: w, h: h, color: pixelRGB(p[0], p[1], p[2]))
            return
        }
        if kind == 0x09 { // JPEG
            let len = try compactLength(t)
            pendingJPEG.append((try t.withBytes(len) { Data($0) }, x, y, w, h))
            if pendingJPEG.count >= Self.batchSize { try flush(fb) }
            return
        }
        guard kind & 0x08 == 0 else { throw RFBError.protocol("unsupported Tight compression \(kind)") }

        let streamID = Int(kind & 0x03)
        let filter: UInt8 = kind & 0x04 != 0 ? try t.u8() : 0
        var palette: [UInt32] = []
        let dataSize: Int
        switch filter {
        case 0, 2:
            dataSize = w * h * 3
        case 1:
            let count = Int(try t.u8()) + 1
            let p = try t.bytes(count * 3)
            palette = (0..<count).map { pixelRGB(p[$0 * 3], p[$0 * 3 + 1], p[$0 * 3 + 2]) }
            dataSize = count == 2 ? ((w + 7) / 8) * h : w * h
        default:
            throw RFBError.protocol("unknown Tight filter \(filter)")
        }

        let data: [UInt8]
        if dataSize < 12 {
            data = try t.bytes(dataSize)
        } else {
            let len = try compactLength(t)
            data = try t.withBytes(len) { try streams[streamID].inflate($0, expected: dataSize) }
        }
        guard data.count >= dataSize else { throw RFBError.protocol("short Tight data (\(data.count) < \(dataSize))") }

        let n = w * h
        if scratch.count < n { scratch = [UInt32](repeating: 0, count: n) }
        scratch.withUnsafeMutableBufferPointer { outBuf in
            let out = outBuf.baseAddress!
            data.withUnsafeBufferPointer { inBuf in
                let src = inBuf.baseAddress!
                switch filter {
                case 1 where palette.count == 2:
                    let rowBytes = (w + 7) / 8
                    for yy in 0..<h {
                        for xx in 0..<w {
                            let bit = (src[yy * rowBytes + xx / 8] >> UInt8(7 - (xx & 7))) & 1
                            out[yy * w + xx] = palette[Int(bit)]
                        }
                    }
                case 1:
                    let last = palette.count - 1
                    for i in 0..<n { out[i] = palette[min(Int(src[i]), last)] }
                case 2:
                    // Gradient: each component predicted as left + above - aboveLeft, clamped.
                    var prev = [Int](repeating: 0, count: (w + 1) * 3)
                    var cur = [Int](repeating: 0, count: (w + 1) * 3)
                    for yy in 0..<h {
                        for xx in 0..<w {
                            var rgb = [0, 0, 0]
                            for ch in 0..<3 {
                                let left = cur[xx * 3 + ch], above = prev[(xx + 1) * 3 + ch], aboveLeft = prev[xx * 3 + ch]
                                let predicted = min(255, max(0, left + above - aboveLeft))
                                let v = (predicted + Int(src[(yy * w + xx) * 3 + ch])) & 0xff
                                cur[(xx + 1) * 3 + ch] = v
                                rgb[ch] = v
                            }
                            out[yy * w + xx] = pixelRGB(UInt8(rgb[0]), UInt8(rgb[1]), UInt8(rgb[2]))
                        }
                        swap(&prev, &cur)
                        for i in 0..<3 { cur[i] = 0 }
                    }
                default:
                    for i in 0..<n { out[i] = pixelRGB(src[i * 3], src[i * 3 + 1], src[i * 3 + 2]) }
                }
            }
            fb.blit(x: x, y: y, w: w, h: h, from: out)
        }
    }

    private func compactLength(_ t: Transport) throws -> Int {
        var b = Int(try t.u8())
        var len = b & 0x7f
        if b & 0x80 != 0 {
            b = Int(try t.u8())
            len |= (b & 0x7f) << 7
            if b & 0x80 != 0 { len |= Int(try t.u8()) << 14 }
        }
        return len
    }

    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    private static func decodeJPEG(_ data: Data, _ fb: Framebuffer, x: Int, y: Int, w: Int, h: Int) throws {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw RFBError.protocol("invalid JPEG rectangle")
        }
        guard let r = fb.clip(x: x, y: y, w: w, h: h) else { return }
        // Draw straight into the framebuffer memory: BGRA little-endian == 32-bit host order, premultipliedFirst.
        let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue
        guard let ctx = CGContext(data: fb.row(r.y) + r.x, width: r.w, height: r.h, bitsPerComponent: 8,
                                  bytesPerRow: fb.bytesPerRow, space: Self.sRGB,
                                  bitmapInfo: info) else { return }
        ctx.interpolationQuality = .none
        // CG's origin is bottom-left and memory row 0 is the top, so flip the image's bottom edge into context space.
        ctx.draw(image, in: CGRect(x: x - r.x, y: r.h - (y + h - r.y), width: w, height: h))
    }
}

/// A set-once flag that's safe to set from several threads at once.
private final class ManagedAtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}
