// Copyright 2026 Ahimsa Labs
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Metal

/// The remote desktop image. Pixels are 32-bit little-endian 0x00RRGGBB (BGRA byte order in memory), which is the
/// pixel format we ask every server for. Storage is a shared-memory MTLBuffer, so the renderer wraps it in a
/// linear texture and the GPU samples decoder output directly with no per-frame upload.
package final class Framebuffer: @unchecked Sendable {
    package let width: Int
    package let height: Int
    /// Row stride in pixels (padded for Metal linear texture alignment).
    package let stride: Int
    package let buffer: MTLBuffer
    package let pixels: UnsafeMutablePointer<UInt32>

    package static let device: MTLDevice? = MTLCreateSystemDefaultDevice()

    package init(width: Int, height: Int) {
        self.width = max(width, 1)
        self.height = max(height, 1)
        let device = Framebuffer.device!
        let align = device.minimumLinearTextureAlignment(for: .bgra8Unorm)
        let rowBytes = (self.width * 4 + align - 1) / align * align
        stride = rowBytes / 4
        buffer = device.makeBuffer(length: rowBytes * self.height, options: [.storageModeShared])!
        pixels = buffer.contents().bindMemory(to: UInt32.self, capacity: stride * self.height)
        pixels.initialize(repeating: 0xFF20_2020, count: stride * self.height)
    }

    package var bytesPerRow: Int { stride * 4 }

    @inline(__always) package func row(_ y: Int) -> UnsafeMutablePointer<UInt32> { pixels + y * stride }

    /// Clips a rectangle to the framebuffer; returns nil if nothing remains.
    package func clip(x: Int, y: Int, w: Int, h: Int) -> (x: Int, y: Int, w: Int, h: Int)? {
        let x0 = max(0, x), y0 = max(0, y)
        let x1 = min(width, x + w), y1 = min(height, y + h)
        guard x1 > x0, y1 > y0 else { return nil }
        return (x0, y0, x1 - x0, y1 - y0)
    }

    package func fill(x: Int, y: Int, w: Int, h: Int, color: UInt32) {
        guard let r = clip(x: x, y: y, w: w, h: h) else { return }
        for yy in r.y..<(r.y + r.h) {
            (row(yy) + r.x).update(repeating: color, count: r.w)
        }
    }

    /// Copies a tightly packed block of 32-bit pixels (`w` per row) into the framebuffer.
    package func blit(x: Int, y: Int, w: Int, h: Int, from src: UnsafePointer<UInt32>, srcStride: Int? = nil) {
        let ss = srcStride ?? w
        guard let r = clip(x: x, y: y, w: w, h: h) else { return }
        let dx = r.x - x, dy = r.y - y
        for yy in 0..<r.h {
            (row(r.y + yy) + r.x).update(from: src + (dy + yy) * ss + dx, count: r.w)
        }
    }

    package func copyRect(srcX: Int, srcY: Int, x: Int, y: Int, w: Int, h: Int) {
        guard let s = clip(x: srcX, y: srcY, w: w, h: h), let d = clip(x: x, y: y, w: w, h: h),
              s.w == w, s.h == h, d.w == w, d.h == h else { return }
        let rowBytes = w * 4
        if y > srcY {
            for yy in Swift.stride(from: h - 1, through: 0, by: -1) {
                memmove(row(y + yy) + x, row(srcY + yy) + srcX, rowBytes)
            }
        } else {
            for yy in 0..<h { memmove(row(y + yy) + x, row(srcY + yy) + srcX, rowBytes) }
        }
    }

    /// Copies the overlapping region of another framebuffer (used when the desktop is resized).
    package func copyContents(of other: Framebuffer) {
        let w = min(width, other.width), h = min(height, other.height)
        for y in 0..<h { (row(y)).update(from: other.row(y), count: w) }
    }
}

/// Opaque-alpha helpers for building pixels from byte components.
@inline(__always) package func pixelRGB(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> UInt32 {
    0xFF00_0000 | UInt32(r) << 16 | UInt32(g) << 8 | UInt32(b)
}
