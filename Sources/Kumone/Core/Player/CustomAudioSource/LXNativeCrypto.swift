import CommonCrypto
import Compression
import CryptoKit
import Foundation
import Security

/// The `lx.utils.crypto` / `lx.utils.zlib` edge, implemented on Apple's own
/// primitives.
///
/// LX exposes exactly the handful of Node primitives community scripts actually
/// reach for — MD5, AES-CBC/ECB, RSA public-key encryption, random bytes and
/// zlib — and most of the older sources use at least one of them to sign a
/// request. Everything here mirrors Node's own defaults (PKCS#7 padding, PKCS#1
/// v1.5 RSA) so a script written against LX behaves the same way.
enum LXCrypto {
    // MARK: - Hash & random

    static func md5Hex(_ input: String) -> String {
        Insecure.MD5.hash(data: Data(input.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func randomBytes(_ count: Int) throws -> Data {
        let bounded = max(0, min(count, 1 << 20))
        guard bounded > 0 else { return Data() }
        var bytes = [UInt8](repeating: 0, count: bounded)
        let status = SecRandomCopyBytes(kSecRandomDefault, bounded, &bytes)
        guard status == errSecSuccess else { throw LXCryptoError.randomFailed(Int(status)) }
        return Data(bytes)
    }

    // MARK: - AES

    enum AESMode {
        case cbc
        case ecb
    }

    /// Parses Node's `aes-128-cbc` / `aes-256-ecb` / `aes-192-cbc` spelling.
    /// When the mode omits the key size the supplied key decides it, which is
    /// what a script that builds its key from a passphrase effectively expects.
    static func parseAESMode(_ raw: String, keyByteCount: Int) throws -> (mode: AESMode, keyLength: Int) {
        let normalized = raw.lowercased()
        let mode: AESMode
        if normalized.contains("ecb") {
            mode = .ecb
        } else if normalized.contains("cbc") {
            mode = .cbc
        } else {
            throw LXCryptoError.unsupportedMode(raw)
        }

        let declared: Int?
        if normalized.contains("256") {
            declared = 32
        } else if normalized.contains("192") {
            declared = 24
        } else if normalized.contains("128") {
            declared = 16
        } else {
            declared = nil
        }

        let keyLength = declared ?? keyByteCount
        guard [16, 24, 32].contains(keyLength), keyByteCount == keyLength else {
            throw LXCryptoError.badKeyLength(keyByteCount)
        }
        return (mode, keyLength)
    }

    static func aes(
        _ data: Data,
        mode: AESMode,
        key: Data,
        iv: Data?,
        encrypt: Bool
    ) throws -> Data {
        if mode == .cbc, iv == nil {
            throw LXCryptoError.missingIV
        }
        if let iv, iv.count != kCCBlockSizeAES128, mode == .cbc {
            throw LXCryptoError.badIVLength(iv.count)
        }

        var options = CCOptions(kCCOptionPKCS7Padding)
        if mode == .ecb { options |= CCOptions(kCCOptionECBMode) }

        var output = Data(count: data.count + kCCBlockSizeAES128)
        var moved = 0

        let status: CCCryptorStatus = output.withUnsafeMutableBytes { outputRaw in
            let outputPointer = outputRaw.bindMemory(to: UInt8.self).baseAddress
            return data.withUnsafeBytes { dataRaw in
                let dataPointer = dataRaw.bindMemory(to: UInt8.self).baseAddress
                return key.withUnsafeBytes { keyRaw in
                    let keyPointer = keyRaw.bindMemory(to: UInt8.self).baseAddress
                    guard mode == .cbc, let iv else {
                        return CCCrypt(
                            CCOperation(encrypt ? kCCEncrypt : kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            options,
                            keyPointer, key.count, nil,
                            dataPointer, data.count,
                            outputPointer, output.count, &moved
                        )
                    }
                    return iv.withUnsafeBytes { ivRaw in
                        CCCrypt(
                            CCOperation(encrypt ? kCCEncrypt : kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            options,
                            keyPointer, key.count,
                            ivRaw.bindMemory(to: UInt8.self).baseAddress,
                            dataPointer, data.count,
                            outputPointer, output.count, &moved
                        )
                    }
                }
            }
        }

        guard status == kCCSuccess else { throw LXCryptoError.aesFailed(Int(status)) }
        output.removeSubrange(moved..<output.count)
        return output
    }

    // MARK: - RSA

    /// `lx.utils.crypto.rsaEncrypt(buffer, key)` — always public-key encryption
    /// with PKCS#1 v1.5 padding, which is what Node's `crypto.publicEncrypt`
    /// does by default and what the sources that sign an API call expect.
    static func rsaPublicEncrypt(_ data: Data, pem: String) throws -> Data {
        let der = try pkcs1PublicKeyDER(fromPEM: pem)
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(der as CFData, attributes as CFDictionary, &error) else {
            throw LXCryptoError.rsaKeyRejected(describe(error))
        }
        guard let encrypted = SecKeyCreateEncryptedData(key, .rsaEncryptionPKCS1, data as CFData, &error) else {
            throw LXCryptoError.rsaEncryptFailed(describe(error))
        }
        return encrypted as Data
    }

    private static func describe(_ error: Unmanaged<CFError>?) -> String {
        guard let error else { return "unknown" }
        return (error.takeRetainedValue() as Error).localizedDescription
    }

    /// Apple's `SecKeyCreateWithData` wants a bare `RSAPublicKey` (PKCS#1), while
    /// every key you find in the wild is wrapped in a `SubjectPublicKeyInfo`
    /// (`-----BEGIN PUBLIC KEY-----`). Unwrapping means walking two DER levels,
    /// which is cheaper and safer than assuming a fixed 27-byte RSA-2048 header.
    private static func pkcs1PublicKeyDER(fromPEM pem: String) throws -> Data {
        // Scripts embed their keys as escaped single-line strings.
        let normalized = pem
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\r\n", with: "\n")
        let isPKCS1 = normalized.contains("BEGIN RSA PUBLIC KEY")
        let isSPKI = normalized.contains("BEGIN PUBLIC KEY")

        let body = normalized
            .split(separator: "\n")
            .filter { !$0.contains("-----") }
            .joined()
        guard let der = Data(base64Encoded: body, options: [.ignoreUnknownCharacters]), !der.isEmpty else {
            throw LXCryptoError.rsaKeyMalformed
        }
        if isPKCS1 { return der }
        // A bare base64 blob is assumed to be SPKI, which is the common case.
        _ = isSPKI
        return try unwrapSubjectPublicKeyInfo(der)
    }

    private static func unwrapSubjectPublicKeyInfo(_ der: Data) throws -> Data {
        let bytes = [UInt8](der)
        var outerCursor = 0
        guard let outer = readTLV(bytes, &outerCursor), outer.tag == 0x30 else {
            throw LXCryptoError.rsaKeyMalformed
        }

        var innerCursor = 0
        guard let algorithm = readTLV(outer.content, &innerCursor), algorithm.tag == 0x30,
              let bitString = readTLV(outer.content, &innerCursor), bitString.tag == 0x03,
              bitString.content.count > 1, bitString.content[0] == 0x00
        else { throw LXCryptoError.rsaKeyMalformed }

        let pkcs1 = [UInt8](bitString.content.dropFirst())
        guard pkcs1.first == 0x30 else { throw LXCryptoError.rsaKeyMalformed }
        return Data(pkcs1)
    }

    private static func readTLV(_ bytes: [UInt8], _ cursor: inout Int) -> (tag: UInt8, content: [UInt8])? {
        guard cursor < bytes.count else { return nil }
        let tag = bytes[cursor]
        cursor += 1
        guard cursor < bytes.count else { return nil }

        var length = Int(bytes[cursor])
        cursor += 1
        if length & 0x80 != 0 {
            let lengthBytes = length & 0x7F
            guard lengthBytes > 0, lengthBytes <= 4, cursor + lengthBytes <= bytes.count else { return nil }
            length = 0
            for _ in 0..<lengthBytes {
                length = (length << 8) | Int(bytes[cursor])
                cursor += 1
            }
        }
        guard length >= 0, cursor + length <= bytes.count else { return nil }
        let content = Array(bytes[cursor..<(cursor + length)])
        cursor += length
        return (tag, content)
    }

    // MARK: - zlib

    /// Node's `zlib.inflate` takes a zlib-wrapped stream; Apple's
    /// `COMPRESSION_ZLIB` is raw DEFLATE. The two differ by a 2-byte header and
    /// a 4-byte Adler-32 trailer, which are dropped here when present.
    static func inflate(_ data: Data) throws -> Data {
        try runzlib(dropZlibWrapper(data), operation: .decode)
    }

    /// Node's `zlib.deflate` emits a zlib wrapper; Apple's encoder does not, so
    /// the header and the Adler-32 trailer are rebuilt here. Scripts that feed
    /// the result straight back into `inflate` therefore round-trip exactly.
    static func deflate(_ data: Data) throws -> Data {
        let raw = try runzlib(data, operation: .encode)
        var wrapped = Data([0x78, 0x9C])
        wrapped.append(raw)
        var checksum = adler32(data).bigEndian
        withUnsafeBytes(of: &checksum) { wrapped.append(contentsOf: $0) }
        return wrapped
    }

    private enum ZlibOperation {
        case encode
        case decode
    }

    private static func dropZlibWrapper(_ data: Data) -> Data {
        guard data.count >= 6 else { return data }
        let bytes = [UInt8](data.prefix(2))
        // A zlib header is two bytes whose big-endian value is a multiple of 31,
        // with 0x78 as the overwhelmingly common CMF byte.
        let header = Int(bytes[0]) << 8 | Int(bytes[1])
        guard bytes[0] == 0x78, header % 31 == 0 else { return data }
        return data.dropFirst(2).dropLast(4)
    }

    static func adler32(_ data: Data) -> UInt32 {
        let modulus: UInt32 = 65_521
        var low: UInt32 = 1
        var high: UInt32 = 0
        for byte in data {
            low = (low &+ UInt32(byte)) % modulus
            high = (high &+ low) % modulus
        }
        return (high << 16) | low
    }

    private static func runzlib(_ data: Data, operation: ZlibOperation) throws -> Data {
        guard !data.isEmpty else { return Data() }

        var capacity = max(data.count * 8, 16 * 1024)
        let capacityLimit = 64 * 1024 * 1024

        while capacity <= capacityLimit {
            var output = [UInt8](repeating: 0, count: capacity)
            let written: Int = data.withUnsafeBytes { raw -> Int in
                guard let source = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                switch operation {
                case .decode:
                    return compression_decode_buffer(
                        source, data.count, &output, capacity, nil, COMPRESSION_ZLIB
                    )
                case .encode:
                    return compression_encode_buffer(
                        &output, capacity, source, data.count, nil, COMPRESSION_ZLIB
                    )
                }
            }

            // A full destination buffer means "probably truncated" — grow and
            // retry rather than handing back a short read.
            if written > 0, written < capacity {
                return Data(output[0..<written])
            }
            if written == 0 {
                // Decode returns 0 on malformed input; retrying cannot help.
                throw LXCryptoError.zlibFailed
            }
            capacity *= 2
        }
        throw LXCryptoError.zlibFailed
    }
}

enum LXCryptoError: LocalizedError {
    case randomFailed(Int)
    case unsupportedMode(String)
    case badKeyLength(Int)
    case badIVLength(Int)
    case missingIV
    case aesFailed(Int)
    case rsaKeyMalformed
    case rsaKeyRejected(String)
    case rsaEncryptFailed(String)
    case zlibFailed
    case notBase64

    var errorDescription: String? {
        switch self {
        case .randomFailed(let status): return "Secure random failed (\(status))"
        case .unsupportedMode(let mode): return "Unsupported AES mode: \(mode)"
        case .badKeyLength(let length): return "AES key must be 16/24/32 bytes, got \(length)"
        case .badIVLength(let length): return "AES IV must be 16 bytes, got \(length)"
        case .missingIV: return "AES-CBC needs an IV"
        case .aesFailed(let status): return "AES operation failed (\(status))"
        case .rsaKeyMalformed: return "RSA public key is not valid PEM/DER"
        case .rsaKeyRejected(let detail): return "RSA key rejected: \(detail)"
        case .rsaEncryptFailed(let detail): return "RSA encrypt failed: \(detail)"
        case .zlibFailed: return "zlib operation failed"
        case .notBase64: return "Expected base64 data"
        }
    }
}
