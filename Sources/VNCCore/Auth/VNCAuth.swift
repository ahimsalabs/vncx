// Copyright 2026 Ahimsa Labs
// SPDX-License-Identifier: Apache-2.0

import Foundation
import CommonCrypto

/// Classic VNC authentication (security type 2): DES-encrypt a 16-byte challenge with the password,
/// where each key byte has its bits mirrored (a historical quirk of the original VNC implementation).
package enum VNCAuth {
    package static func respond(challenge: [UInt8], password: String) throws -> [UInt8] {
        precondition(challenge.count == 16)
        var key = [UInt8](repeating: 0, count: 8)
        for (i, b) in password.utf8.prefix(8).enumerated() { key[i] = reverseBits(b) }

        var out = [UInt8](repeating: 0, count: 16)
        var moved = 0
        let status = CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmDES), CCOptions(kCCOptionECBMode),
                             key, kCCKeySizeDES, nil, challenge, 16, &out, 16, &moved)
        guard status == kCCSuccess, moved == 16 else { throw RFBError.auth("DES encryption failed (\(status))") }
        return out
    }

    package static func reverseBits(_ b: UInt8) -> UInt8 {
        var v = b, r: UInt8 = 0
        for _ in 0..<8 { r = (r << 1) | (v & 1); v >>= 1 }
        return r
    }
}
