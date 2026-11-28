// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only

import CommonCrypto
import Compression
import CryptoKit
import Foundation
import Security

/// Native Apple Security / CryptoKit / CommonCrypto / Compression primitives
/// matching `shared/catpaw/drpy-worker.cjs`, `drpy-rsa.cjs`, and the Guard
/// plugin extractors on iOS 14+ and macOS 13+.
public enum CatPawCrypto {
    public static let maxZlibOutputBytes = 2 * 1024 * 1024
    public static let maxCipherInputBytes = 6 * 1024 * 1024

    public enum CryptoError: Error, LocalizedError {
        case invalidInput(String)
        case randomSizeInvalid

        public var errorDescription: String? {
            switch self {
            case .invalidInput(let code): return code
            case .randomSizeInvalid: return "drpy_random_size"
            }
        }
    }

    // MARK: - Random & Hashing

    public static func randomBytes(count: Int) throws -> [UInt8] {
        guard count >= 0 && count <= 65536 else {
            throw CryptoError.randomSizeInvalid
        }
        if count == 0 { return [] }
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        guard status == errSecSuccess else {
            throw CryptoError.invalidInput("drpy_crypto_invalid")
        }
        return bytes
    }

    public static func hash(algorithm: String, data: Data) throws -> Data {
        let normalized = algorithm
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "")
        switch normalized {
        case "sha256":
            return Data(SHA256.hash(data: data))
        case "sha384":
            return Data(SHA384.hash(data: data))
        case "sha512":
            return Data(SHA512.hash(data: data))
        case "sha1":
            return Data(Insecure.SHA1.hash(data: data))
        case "md5":
            return Data(Insecure.MD5.hash(data: data))
        default:
            throw CryptoError.invalidInput("drpy_crypto_invalid")
        }
    }

    // MARK: - Zlib / Raw Deflate / Gzip Decompression

    public static func zlibInflate(
        mode: String,
        input: Data,
        maxOutputLength: Int = maxZlibOutputBytes
    ) throws -> Data {
        guard maxOutputLength > 0 && maxOutputLength <= 16 * 1024 * 1024 else {
            throw CryptoError.invalidInput("drpy_crypto_invalid")
        }
        let rawDeflate: Data
        switch mode {
        case "inflateRaw":
            rawDeflate = input
        case "inflate":
            rawDeflate = try stripZlibWrapper(input)
        case "gunzip":
            rawDeflate = try stripGzipWrapper(input)
        default:
            throw CryptoError.invalidInput("drpy_crypto_invalid")
        }
        return try inflateRawDeflate(rawDeflate, maxOutputLength: maxOutputLength)
    }

    public static func zlibInflateBase64(mode: String, inputBase64: String) throws -> String {
        guard inputBase64.count <= maxCipherInputBytes,
              let bytes = decodeLooseBase64(inputBase64)
        else {
            throw CryptoError.invalidInput("drpy_crypto_invalid")
        }
        let inflated = try zlibInflate(mode: mode, input: bytes, maxOutputLength: maxZlibOutputBytes)
        return inflated.base64EncodedString()
    }

    private static func stripZlibWrapper(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes.count >= 6 else {
            throw CryptoError.invalidInput("drpy_crypto_invalid")
        }
        let cmf = bytes[0]
        let flg = bytes[1]
        guard (cmf & 0x0F) == 8, ((Int(cmf) << 8) | Int(flg)) % 31 == 0 else {
            throw CryptoError.invalidInput("drpy_crypto_invalid")
        }
        let headerLen = (flg & 0x20) != 0 ? 6 : 2
        guard bytes.count >= headerLen + 4 else {
            throw CryptoError.invalidInput("drpy_crypto_invalid")
        }
        return Data(bytes[headerLen..<(bytes.count - 4)])
    }

    private static func stripGzipWrapper(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes.count >= 18, bytes[0] == 0x1F, bytes[1] == 0x8B, bytes[2] == 0x08 else {
            throw CryptoError.invalidInput("drpy_crypto_invalid")
        }
        let flg = bytes[3]
        var idx = 10
        if (flg & 0x04) != 0 {
            guard idx + 2 <= bytes.count else { throw CryptoError.invalidInput("drpy_crypto_invalid") }
            let xlen = Int(bytes[idx]) | (Int(bytes[idx + 1]) << 8)
            idx += 2 + xlen
        }
        if (flg & 0x08) != 0 {
            while idx < bytes.count && bytes[idx] != 0 { idx += 1 }
            idx += 1
        }
        if (flg & 0x10) != 0 {
            while idx < bytes.count && bytes[idx] != 0 { idx += 1 }
            idx += 1
        }
        if (flg & 0x02) != 0 {
            idx += 2
        }
        guard idx < bytes.count - 8 else {
            throw CryptoError.invalidInput("drpy_crypto_invalid")
        }
        return Data(bytes[idx..<(bytes.count - 8)])
    }

    private static func inflateRawDeflate(_ rawDeflate: Data, maxOutputLength: Int) throws -> Data {
        if rawDeflate.isEmpty { return Data() }
        let streamPtr = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { streamPtr.deallocate() }

        let initStatus = compression_stream_init(streamPtr, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
        guard initStatus != COMPRESSION_STATUS_ERROR else {
            throw CryptoError.invalidInput("drpy_crypto_invalid")
        }
        defer { compression_stream_destroy(streamPtr) }

        let chunkSize = 64 * 1024
        let dstBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        defer { dstBuf.deallocate() }

        var output = Data()
        try rawDeflate.withUnsafeBytes { rawBuf in
            guard let baseAddr = rawBuf.bindMemory(to: UInt8.self).baseAddress else { return }
            streamPtr.pointee.src_ptr = baseAddr
            streamPtr.pointee.src_size = rawDeflate.count

            while true {
                streamPtr.pointee.dst_ptr = dstBuf
                streamPtr.pointee.dst_size = chunkSize
                let status = compression_stream_process(streamPtr, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = chunkSize - streamPtr.pointee.dst_size
                if produced > 0 {
                    if output.count + produced > maxOutputLength {
                        throw CryptoError.invalidInput("drpy_crypto_invalid")
                    }
                    output.append(dstBuf, count: produced)
                }
                if status == COMPRESSION_STATUS_END {
                    break
                }
                if status == COMPRESSION_STATUS_ERROR {
                    throw CryptoError.invalidInput("drpy_crypto_invalid")
                }
                if produced == 0 && streamPtr.pointee.src_size == 0 {
                    break
                }
            }
        }
        return output
    }

    // MARK: - Symmetric Ciphers (`nodeCipher` parity)

    public static func nodeCipher(
        op: String,
        algo: String,
        keyBase64: String,
        ivBase64: String,
        dataBase64: String,
        tagBase64: String = ""
    ) throws -> [String: String] {
        let allowed: Set<String> = [
            "aes-128-cbc",
            "aes-256-cbc",
            "aes-128-ecb",
            "aes-256-ecb",
            "aes-256-gcm",
            "chacha20-poly1305",
        ]
        guard allowed.contains(algo),
              op == "encrypt" || op == "decrypt",
              dataBase64.count <= maxCipherInputBytes,
              let key = decodeLooseBase64(keyBase64),
              let iv = ivBase64.isEmpty ? Data() : decodeLooseBase64(ivBase64),
              let data = decodeLooseBase64(dataBase64),
              let tag = tagBase64.isEmpty ? Data() : decodeLooseBase64(tagBase64)
        else {
            throw CryptoError.invalidInput("drpy_crypto_invalid")
        }

        let isEncrypt = op == "encrypt"
        switch algo {
        case "aes-128-cbc":
            guard key.count == 16, iv.count == 16 else {
                throw CryptoError.invalidInput("drpy_crypto_invalid")
            }
            let out = try ccAesCrypt(encrypt: isEncrypt, key: key, iv: iv, ecb: false, data: data)
            return isEncrypt ? ["data": out.base64EncodedString(), "tag": ""] : ["data": out.base64EncodedString()]

        case "aes-256-cbc":
            guard key.count == 32, iv.count == 16 else {
                throw CryptoError.invalidInput("drpy_crypto_invalid")
            }
            let out = try ccAesCrypt(encrypt: isEncrypt, key: key, iv: iv, ecb: false, data: data)
            return isEncrypt ? ["data": out.base64EncodedString(), "tag": ""] : ["data": out.base64EncodedString()]

        case "aes-128-ecb":
            guard key.count == 16 else {
                throw CryptoError.invalidInput("drpy_crypto_invalid")
            }
            let out = try ccAesCrypt(encrypt: isEncrypt, key: key, iv: nil, ecb: true, data: data)
            return isEncrypt ? ["data": out.base64EncodedString(), "tag": ""] : ["data": out.base64EncodedString()]

        case "aes-256-ecb":
            guard key.count == 32 else {
                throw CryptoError.invalidInput("drpy_crypto_invalid")
            }
            let out = try ccAesCrypt(encrypt: isEncrypt, key: key, iv: nil, ecb: true, data: data)
            return isEncrypt ? ["data": out.base64EncodedString(), "tag": ""] : ["data": out.base64EncodedString()]

        case "aes-256-gcm":
            guard key.count == 32, !iv.isEmpty else {
                throw CryptoError.invalidInput("drpy_crypto_invalid")
            }
            do {
                let symKey = SymmetricKey(data: key)
                let nonce = try AES.GCM.Nonce(data: iv)
                if isEncrypt {
                    let sealed = try AES.GCM.seal(data, using: symKey, nonce: nonce)
                    return [
                        "data": sealed.ciphertext.base64EncodedString(),
                        "tag": sealed.tag.base64EncodedString(),
                    ]
                } else {
                    guard tag.count == 16 else {
                        throw CryptoError.invalidInput("drpy_crypto_invalid")
                    }
                    let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: data, tag: tag)
                    let plain = try AES.GCM.open(box, using: symKey)
                    return ["data": plain.base64EncodedString()]
                }
            } catch {
                throw CryptoError.invalidInput("drpy_crypto_invalid")
            }

        case "chacha20-poly1305":
            guard key.count == 32, iv.count == 12 else {
                throw CryptoError.invalidInput("drpy_crypto_invalid")
            }
            do {
                let symKey = SymmetricKey(data: key)
                let nonce = try ChaChaPoly.Nonce(data: iv)
                if isEncrypt {
                    let sealed = try ChaChaPoly.seal(data, using: symKey, nonce: nonce)
                    return [
                        "data": sealed.ciphertext.base64EncodedString(),
                        "tag": sealed.tag.base64EncodedString(),
                    ]
                } else {
                    guard tag.count == 16 else {
                        throw CryptoError.invalidInput("drpy_crypto_invalid")
                    }
                    let box = try ChaChaPoly.SealedBox(nonce: nonce, ciphertext: data, tag: tag)
                    let plain = try ChaChaPoly.open(box, using: symKey)
                    return ["data": plain.base64EncodedString()]
                }
            } catch {
                throw CryptoError.invalidInput("drpy_crypto_invalid")
            }

        default:
            throw CryptoError.invalidInput("drpy_crypto_invalid")
        }
    }

    private static func ccAesCrypt(
        encrypt: Bool,
        key: Data,
        iv: Data?,
        ecb: Bool,
        data: Data
    ) throws -> Data {
        let operation = CCOperation(encrypt ? kCCEncrypt : kCCDecrypt)
        var options = CCOptions(kCCOptionPKCS7Padding)
        if ecb {
            options |= CCOptions(kCCOptionECBMode)
        }
        let outCapacity = data.count + kCCBlockSizeAES128
        var outBytes = [UInt8](repeating: 0, count: outCapacity)
        var outMoved = 0

        let status: CCCryptorStatus = key.withUnsafeBytes { keyBuf in
            data.withUnsafeBytes { dataBuf in
                if let iv = iv {
                    return iv.withUnsafeBytes { ivBuf in
                        CCCrypt(
                            operation,
                            CCAlgorithm(kCCAlgorithmAES),
                            options,
                            keyBuf.baseAddress,
                            key.count,
                            ivBuf.baseAddress,
                            dataBuf.baseAddress,
                            data.count,
                            &outBytes,
                            outCapacity,
                            &outMoved
                        )
                    }
                } else {
                    return CCCrypt(
                        operation,
                        CCAlgorithm(kCCAlgorithmAES),
                        options,
                        keyBuf.baseAddress,
                        key.count,
                        nil,
                        dataBuf.baseAddress,
                        data.count,
                        &outBytes,
                        outCapacity,
                        &outMoved
                    )
                }
            }
        }
        guard status == kCCSuccess else {
            throw CryptoError.invalidInput("drpy_crypto_invalid")
        }
        return Data(outBytes.prefix(outMoved))
    }

    // MARK: - RSA PKCS#1 v1.5 (`rsaPkcs1` & `rsaPublicEncrypt` parity)

    public static func rsaPkcs1(operation: String, keyBase64: String, inputBase64: String) throws -> String {
        let isEncrypt = operation == "encrypt"
        guard isEncrypt || operation == "decrypt" else {
            throw CryptoError.invalidInput("drpy_crypto_invalid")
        }
        let der = try strictBase64(keyBase64, maxBytes: 2048)
        let data = try strictBase64(inputBase64, maxBytes: isEncrypt ? 117 : 1024)

        if isEncrypt {
            let (pkcs1Der, bitLength) = try unwrapSpkiToPkcs1Public(der)
            guard bitLength == 1023 || bitLength == 1024 else {
                throw CryptoError.invalidInput("drpy_crypto_invalid")
            }
            let secKey = try makeSecKey(pkcs1Der: pkcs1Der, isPrivate: false)
            var cfError: Unmanaged<CFError>?
            guard let encrypted = SecKeyCreateEncryptedData(secKey, .rsaEncryptionPKCS1, data as CFData, &cfError) as Data? else {
                throw CryptoError.invalidInput("drpy_crypto_invalid")
            }
            return encrypted.base64EncodedString()
        } else {
            let (pkcs1Der, bitLength) = try unwrapPkcs8ToPkcs1Private(der)
            guard (bitLength == 1023 || bitLength == 1024), data.count % 128 == 0 else {
                throw CryptoError.invalidInput("drpy_crypto_invalid")
            }
            let secKey = try makeSecKey(pkcs1Der: pkcs1Der, isPrivate: true)
            var output = Data()
            var offset = 0
            while offset < data.count {
                let slice = data.subdata(in: offset..<(offset + 128))
                var cfError: Unmanaged<CFError>?
                guard let rawBlock = SecKeyCreateDecryptedData(secKey, .rsaEncryptionRaw, slice as CFData, &cfError) as Data? else {
                    throw CryptoError.invalidInput("drpy_crypto_invalid")
                }
                let block = [UInt8](rawBlock)
                var sep = -1
                if block.count == 128 && block[0] == 0 && block[1] == 2 {
                    for i in 2..<block.count {
                        if block[i] == 0 {
                            sep = i
                            break
                        }
                    }
                }
                guard block.count == 128, block[0] == 0, block[1] == 2, sep >= 10, sep < 127 else {
                    throw CryptoError.invalidInput("drpy_crypto_invalid")
                }
                output.append(contentsOf: block[(sep + 1)...])
                offset += 128
            }
            guard output.count <= 512 else {
                throw CryptoError.invalidInput("drpy_crypto_invalid")
            }
            return output.base64EncodedString()
        }
    }

    public static func rsaPublicEncrypt(pem: String, dataBase64: String) throws -> String {
        guard !pem.isEmpty, pem.count <= 8192, dataBase64.count <= 8192,
              let data = decodeLooseBase64(dataBase64)
        else {
            throw CryptoError.invalidInput("drpy_crypto_invalid")
        }
        let trimmed = pem.trimmingCharacters(in: .whitespacesAndNewlines)
        let isPkcs1 = trimmed.contains("BEGIN RSA PUBLIC KEY")
        let isSpki = trimmed.contains("BEGIN PUBLIC KEY")
        guard isPkcs1 || isSpki else {
            throw CryptoError.invalidInput("drpy_crypto_invalid")
        }
        let body = trimmed
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("-----") }
            .joined()
        guard let der = decodeLooseBase64(body) else {
            throw CryptoError.invalidInput("drpy_crypto_invalid")
        }
        let pkcs1Der: Data
        if isPkcs1 {
            _ = try validatePkcs1PublicModulusBits(der)
            pkcs1Der = der
        } else {
            pkcs1Der = try unwrapSpkiToPkcs1Public(der).pkcs1
        }
        let secKey = try makeSecKey(pkcs1Der: pkcs1Der, isPrivate: false)
        var cfError: Unmanaged<CFError>?
        guard let encrypted = SecKeyCreateEncryptedData(secKey, .rsaEncryptionPKCS1, data as CFData, &cfError) as Data? else {
            throw CryptoError.invalidInput("drpy_crypto_invalid")
        }
        return encrypted.base64EncodedString()
    }

    private static func makeSecKey(pkcs1Der: Data, isPrivate: Bool) throws -> SecKey {
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: isPrivate ? kSecAttrKeyClassPrivate : kSecAttrKeyClassPublic,
        ]
        var cfError: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(pkcs1Der as CFData, attributes as CFDictionary, &cfError) else {
            throw CryptoError.invalidInput("drpy_crypto_invalid")
        }
        return key
    }

    // MARK: - Minimal ASN.1 DER Unwrapper for RSA SPKI / PKCS#8

    private static let rsaOid: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01]

    private static func readDerElement(_ bytes: [UInt8], offset: inout Int, expectedTag: UInt8) throws -> [UInt8] {
        guard offset < bytes.count, bytes[offset] == expectedTag else {
            throw CryptoError.invalidInput("drpy_crypto_invalid")
        }
        offset += 1
        guard offset < bytes.count else { throw CryptoError.invalidInput("drpy_crypto_invalid") }
        let firstLen = bytes[offset]
        offset += 1
        let length: Int
        if (firstLen & 0x80) == 0 {
            length = Int(firstLen)
        } else {
            let count = Int(firstLen & 0x7F)
            guard count > 0, count <= 4, offset + count <= bytes.count else {
                throw CryptoError.invalidInput("drpy_crypto_invalid")
            }
            var acc = 0
            for _ in 0..<count {
                acc = (acc << 8) | Int(bytes[offset])
                offset += 1
            }
            length = acc
        }
        guard offset + length <= bytes.count else {
            throw CryptoError.invalidInput("drpy_crypto_invalid")
        }
        let slice = Array(bytes[offset..<(offset + length)])
        offset += length
        return slice
    }

    private static func positiveAsn1BitLength(_ intBytes: [UInt8]) throws -> Int {
        guard !intBytes.isEmpty, (intBytes[0] & 0x80) == 0 else {
            throw CryptoError.invalidInput("drpy_crypto_invalid")
        }
        var idx = 0
        while idx < intBytes.count - 1 && intBytes[idx] == 0 {
            idx += 1
        }
        let first = intBytes[idx]
        guard first > 0 else { return 0 }
        let leadingBits = 8 - first.leadingZeroBitCount
        return leadingBits + (intBytes.count - idx - 1) * 8
    }

    private static func validatePkcs1PublicModulusBits(_ der: Data) throws -> Int {
        let bytes = [UInt8](der)
        var off = 0
        let seq = try readDerElement(bytes, offset: &off, expectedTag: 0x30)
        guard off == bytes.count else { throw CryptoError.invalidInput("drpy_crypto_invalid") }
        var seqOff = 0
        let nBytes = try readDerElement(seq, offset: &seqOff, expectedTag: 0x02)
        _ = try readDerElement(seq, offset: &seqOff, expectedTag: 0x02)
        return try positiveAsn1BitLength(nBytes)
    }

    private static func unwrapSpkiToPkcs1Public(_ der: Data) throws -> (pkcs1: Data, bitLength: Int) {
        let bytes = [UInt8](der)
        var off = 0
        let seq = try readDerElement(bytes, offset: &off, expectedTag: 0x30)
        guard off == bytes.count else { throw CryptoError.invalidInput("drpy_crypto_invalid") }
        var seqOff = 0
        let algSeq = try readDerElement(seq, offset: &seqOff, expectedTag: 0x30)
        var algOff = 0
        let oid = try readDerElement(algSeq, offset: &algOff, expectedTag: 0x06)
        guard oid == rsaOid else { throw CryptoError.invalidInput("drpy_crypto_invalid") }
        let bitStr = try readDerElement(seq, offset: &seqOff, expectedTag: 0x03)
        guard bitStr.count > 1, bitStr[0] == 0 else {
            throw CryptoError.invalidInput("drpy_crypto_invalid")
        }
        let pkcs1 = Data(bitStr.dropFirst())
        let bits = try validatePkcs1PublicModulusBits(pkcs1)
        return (pkcs1, bits)
    }

    private static func unwrapPkcs8ToPkcs1Private(_ der: Data) throws -> (pkcs1: Data, bitLength: Int) {
        let bytes = [UInt8](der)
        var off = 0
        let seq = try readDerElement(bytes, offset: &off, expectedTag: 0x30)
        guard off == bytes.count else { throw CryptoError.invalidInput("drpy_crypto_invalid") }
        var seqOff = 0
        let ver = try readDerElement(seq, offset: &seqOff, expectedTag: 0x02)
        guard ver == [0x00] else { throw CryptoError.invalidInput("drpy_crypto_invalid") }
        let algSeq = try readDerElement(seq, offset: &seqOff, expectedTag: 0x30)
        var algOff = 0
        let oid = try readDerElement(algSeq, offset: &algOff, expectedTag: 0x06)
        guard oid == rsaOid else { throw CryptoError.invalidInput("drpy_crypto_invalid") }
        let octet = try readDerElement(seq, offset: &seqOff, expectedTag: 0x04)

        var privOff = 0
        let privSeq = try readDerElement(octet, offset: &privOff, expectedTag: 0x30)
        var pSeqOff = 0
        _ = try readDerElement(privSeq, offset: &pSeqOff, expectedTag: 0x02)
        let nBytes = try readDerElement(privSeq, offset: &pSeqOff, expectedTag: 0x02)
        let bits = try positiveAsn1BitLength(nBytes)
        return (Data(octet), bits)
    }

    // MARK: - Base64 Helpers

    private static func strictBase64(_ value: String, maxBytes: Int) throws -> Data {
        guard !value.isEmpty, value.count <= maxBytes * 2 else {
            throw CryptoError.invalidInput("drpy_crypto_invalid")
        }
        guard let decoded = Data(base64Encoded: value),
              !decoded.isEmpty,
              decoded.count <= maxBytes,
              decoded.base64EncodedString() == value
        else {
            throw CryptoError.invalidInput("drpy_crypto_invalid")
        }
        return decoded
    }

    public static func decodeLooseBase64(_ input: String) -> Data? {
        if input.isEmpty { return Data() }
        var cleaned = input
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let rem = cleaned.count % 4
        if rem != 0 {
            cleaned.append(String(repeating: "=", count: 4 - rem))
        }
        return Data(base64Encoded: cleaned)
    }
}
