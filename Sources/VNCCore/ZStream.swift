import Foundation
import CZlib

/// A persistent zlib inflate stream. RFB encodings (Zlib, ZRLE, Tight) keep one stream alive across
/// rectangles, so this object must outlive a single update.
package final class ZStream {
    private var stream = z_stream()
    private var initialized = false

    package init() {}

    deinit { if initialized { inflateEnd(&stream) } }

    package func reset() {
        if initialized { inflateEnd(&stream); initialized = false }
        stream = z_stream()
    }

    /// Inflate `input` and return the decompressed bytes. `expected` is a size hint for the output buffer;
    /// pass the exact size when the encoding specifies it (Zlib encoding) and an estimate otherwise.
    package func inflate(_ input: UnsafeRawBufferPointer, expected: Int) throws -> [UInt8] {
        if !initialized {
            guard inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
                throw RFBError.protocol("zlib init failed")
            }
            initialized = true
        }
        var output = [UInt8](repeating: 0, count: max(expected, 1024))
        var produced = 0
        var status: Int32 = Z_OK
        try input.withMemoryRebound(to: Bytef.self) { inPtr in
            stream.next_in = UnsafeMutablePointer(mutating: inPtr.baseAddress)
            stream.avail_in = UInt32(input.count)
            repeat {
                if produced == output.count { output.append(contentsOf: [UInt8](repeating: 0, count: output.count)) }
                try output.withUnsafeMutableBufferPointer { outPtr in
                    stream.next_out = outPtr.baseAddress! + produced
                    stream.avail_out = UInt32(outPtr.count - produced)
                    status = CZlib.inflate(&stream, Z_SYNC_FLUSH)
                    guard status == Z_OK || status == Z_STREAM_END || status == Z_BUF_ERROR else {
                        throw RFBError.protocol("zlib inflate failed (\(status))")
                    }
                    produced = outPtr.count - Int(stream.avail_out)
                }
                if status == Z_BUF_ERROR && stream.avail_in == 0 { break }
            } while stream.avail_in > 0 || (stream.avail_out == 0 && status == Z_OK)
        }
        output.removeSubrange(produced...)
        return output
    }

    /// One-shot zlib compression (a complete zlib stream).
    package static func deflate(_ input: [UInt8]) -> [UInt8] {
        var outLen = compressBound(uLong(input.count))
        var out = [UInt8](repeating: 0, count: Int(outLen))
        guard compress2(&out, &outLen, input, uLong(input.count), 6) == Z_OK else { return [] }
        return Array(out[0..<Int(outLen)])
    }
}
