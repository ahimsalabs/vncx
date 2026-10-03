import Foundation

/// Bounds-checked sequential reader over an in-memory buffer (decompressed ZRLE/Tight data).
package struct ByteCursor {
    package let base: UnsafePointer<UInt8>
    package let count: Int
    package var offset = 0

    package init(_ p: UnsafeRawBufferPointer) {
        base = p.baseAddress?.assumingMemoryBound(to: UInt8.self) ?? UnsafePointer(bitPattern: 1)!
        count = p.count
    }

    package var remaining: Int { count - offset }

    @inline(__always) package mutating func need(_ n: Int) throws {
        if offset + n > count { throw RFBError.protocol("truncated encoded data") }
    }
    @inline(__always) package mutating func u8() throws -> UInt8 {
        try need(1); defer { offset += 1 }; return base[offset]
    }
    /// 3-byte compact pixel in little-endian byte order: B, G, R.
    @inline(__always) package mutating func cpixelBGR() throws -> UInt32 {
        try need(3); defer { offset += 3 }
        return 0xFF00_0000 | UInt32(base[offset + 2]) << 16 | UInt32(base[offset + 1]) << 8 | UInt32(base[offset])
    }
    @inline(__always) package mutating func pointer(_ n: Int) throws -> UnsafePointer<UInt8> {
        try need(n); defer { offset += n }; return base + offset
    }
}
