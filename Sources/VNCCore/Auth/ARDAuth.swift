// Copyright 2026 Ahimsa Labs
// SPDX-License-Identifier: Apache-2.0

import Foundation
import CommonCrypto
import CryptoKit
import Security

/// Apple Remote Desktop / macOS Screen Sharing authentication (RFB security type 30).
///
/// Wire format from server: generator (u16), key length (u16), prime (keyLength bytes),
/// server public key (keyLength bytes). Client replies with AES-128-ECB(MD5(shared secret))
/// over a 128-byte credential block (64 bytes username, 64 bytes password, NUL-terminated,
/// random-padded) followed by its own public key.
package enum ARDAuth {
    package struct Challenge {
        let generator: UInt16
        let keyLength: Int
        let prime: [UInt8]
        let serverPublicKey: [UInt8]
        package init(generator: UInt16, keyLength: Int, prime: [UInt8], serverPublicKey: [UInt8]) {
            self.generator = generator; self.keyLength = keyLength; self.prime = prime; self.serverPublicKey = serverPublicKey
        }
    }

    package static func respond(to challenge: Challenge, username: String, password: String) throws -> [UInt8] {
        let keyLength = challenge.keyLength
        let ctx = ModularContext(modulusBigEndian: challenge.prime)

        var privateKey = [UInt8](repeating: 0, count: keyLength)
        guard SecRandomCopyBytes(kSecRandomDefault, keyLength, &privateKey) == errSecSuccess else {
            throw RFBError.auth("secure random generation failed")
        }
        var generator = [UInt8](repeating: 0, count: keyLength)
        generator[keyLength - 2] = UInt8(challenge.generator >> 8)
        generator[keyLength - 1] = UInt8(challenge.generator & 0xff)

        let publicKey = fit(ctx.modPow(base: generator, exponent: privateKey), to: keyLength)
        let shared = fit(ctx.modPow(base: challenge.serverPublicKey, exponent: privateKey), to: keyLength)

        let aesKey = Data(Insecure.MD5.hash(data: Data(shared)))

        var creds = [UInt8](repeating: 0, count: 128)
        _ = SecRandomCopyBytes(kSecRandomDefault, 128, &creds)
        let u = Array(username.utf8.prefix(63)), p = Array(password.utf8.prefix(63))
        creds.replaceSubrange(0..<u.count, with: u); creds[u.count] = 0
        creds.replaceSubrange(64..<(64 + p.count), with: p); creds[64 + p.count] = 0

        var encrypted = [UInt8](repeating: 0, count: 128)
        var moved = 0
        let status = aesKey.withUnsafeBytes { keyPtr in
            CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES128), CCOptions(kCCOptionECBMode),
                    keyPtr.baseAddress, kCCKeySizeAES128, nil,
                    creds, 128, &encrypted, 128, &moved)
        }
        guard status == kCCSuccess, moved == 128 else { throw RFBError.auth("AES encryption failed (\(status))") }
        return encrypted + publicKey
    }

    private static func fit(_ bytes: [UInt8], to length: Int) -> [UInt8] {
        if bytes.count == length { return bytes }
        if bytes.count > length { return Array(bytes.suffix(length)) }
        return [UInt8](repeating: 0, count: length - bytes.count) + bytes
    }
}
