import Foundation

/// Minimal fixed-width modular arithmetic for finite-field Diffie-Hellman.
/// Limbs are little-endian UInt32. Uses Montgomery multiplication (CIOS), so the modulus must be odd,
/// which every DH prime is.
package struct ModularContext {
    package let n: [UInt32]        // modulus, little-endian limbs
    package let limbs: Int
    package let nInv: UInt32       // -n^{-1} mod 2^32
    package let r2: [UInt32]       // R^2 mod n, R = 2^(32*limbs)

    package init(modulusBigEndian: [UInt8]) {
        var m = ModularContext.limbs(fromBigEndian: modulusBigEndian)
        while m.count > 1 && m.last == 0 { m.removeLast() }
        n = m
        limbs = m.count
        precondition(m[0] & 1 == 1, "modulus must be odd")

        // Newton iteration for n0^{-1} mod 2^32, then negate.
        var inv: UInt32 = 1
        for _ in 0..<6 { inv = inv &* (2 &- n[0] &* inv) }
        nInv = 0 &- inv

        // R^2 mod n by doubling 1 (2 * 32 * limbs) times with reduction.
        var acc = [UInt32](repeating: 0, count: limbs)
        acc[0] = 1
        for _ in 0..<(2 * 32 * limbs) {
            var carry: UInt32 = 0
            for i in 0..<limbs {
                let v = acc[i]
                acc[i] = (v << 1) | carry
                carry = v >> 31
            }
            if carry != 0 || ModularContext.compare(acc, n) >= 0 {
                ModularContext.subtract(&acc, n)
            }
        }
        r2 = acc
    }

    package static func limbs(fromBigEndian bytes: [UInt8]) -> [UInt32] {
        let count = (bytes.count + 3) / 4
        var out = [UInt32](repeating: 0, count: max(count, 1))
        for (i, b) in bytes.reversed().enumerated() {
            out[i / 4] |= UInt32(b) << (8 * UInt32(i % 4))
        }
        return out
    }

    package static func bigEndian(_ limbs: [UInt32], byteCount: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: byteCount)
        for i in 0..<byteCount {
            let limb = i / 4, shift = 8 * (i % 4)
            if limb < limbs.count { out[byteCount - 1 - i] = UInt8((limbs[limb] >> UInt32(shift)) & 0xff) }
        }
        return out
    }

    package static func compare(_ a: [UInt32], _ b: [UInt32]) -> Int {
        var i = a.count - 1
        while i >= 0 {
            if a[i] != b[i] { return a[i] < b[i] ? -1 : 1 }
            i -= 1
        }
        return 0
    }

    package static func subtract(_ a: inout [UInt32], _ b: [UInt32]) {
        var borrow: UInt64 = 0
        for i in 0..<a.count {
            let d = UInt64(a[i]) &- UInt64(b[i]) &- borrow
            a[i] = UInt32(truncatingIfNeeded: d)
            borrow = (d >> 63) & 1
        }
    }

    /// Montgomery product: a * b * R^{-1} mod n.
    package func montMul(_ a: [UInt32], _ b: [UInt32]) -> [UInt32] {
        let s = limbs
        var t = [UInt32](repeating: 0, count: s + 2)
        for i in 0..<s {
            var carry: UInt64 = 0
            let bi = UInt64(b[i])
            for j in 0..<s {
                let v = UInt64(t[j]) + UInt64(a[j]) * bi + carry
                t[j] = UInt32(truncatingIfNeeded: v)
                carry = v >> 32
            }
            var v = UInt64(t[s]) + carry
            t[s] = UInt32(truncatingIfNeeded: v)
            t[s + 1] = UInt32(truncatingIfNeeded: v >> 32)

            let m = UInt64(t[0] &* nInv)
            v = UInt64(t[0]) + m * UInt64(n[0])
            carry = v >> 32
            for j in 1..<s {
                let w = UInt64(t[j]) + m * UInt64(n[j]) + carry
                t[j - 1] = UInt32(truncatingIfNeeded: w)
                carry = w >> 32
            }
            v = UInt64(t[s]) + carry
            t[s - 1] = UInt32(truncatingIfNeeded: v)
            t[s] = t[s + 1] &+ UInt32(truncatingIfNeeded: v >> 32)
            t[s + 1] = 0
        }
        var result = Array(t[0..<s])
        if t[s] != 0 || ModularContext.compare(result, n) >= 0 {
            ModularContext.subtract(&result, n)
        }
        return result
    }

    /// base^exp mod n; inputs and output as big-endian byte arrays of the modulus width.
    package func modPow(base: [UInt8], exponent: [UInt8]) -> [UInt8] {
        var b = ModularContext.limbs(fromBigEndian: base)
        b = normalize(b)
        let baseM = montMul(b, r2)
        var one = [UInt32](repeating: 0, count: limbs); one[0] = 1
        var acc = montMul(one, r2) // 1 in Montgomery form
        for byte in exponent {
            for bit in (0..<8).reversed() {
                acc = montMul(acc, acc)
                if (byte >> UInt8(bit)) & 1 == 1 { acc = montMul(acc, baseM) }
            }
        }
        let out = montMul(acc, one) // back from Montgomery form
        return ModularContext.bigEndian(out, byteCount: n.count * 4).suffix(from: 0).map { $0 }
    }

    private func normalize(_ v: [UInt32]) -> [UInt32] {
        var x = v
        if x.count < limbs { x += [UInt32](repeating: 0, count: limbs - x.count) }
        if x.count > limbs { x = Array(x[0..<limbs]) }
        while ModularContext.compare(x, n) >= 0 { ModularContext.subtract(&x, n) }
        return x
    }
}
