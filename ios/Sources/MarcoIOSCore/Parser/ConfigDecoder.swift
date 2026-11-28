// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only

import Foundation

public enum ConfigDecoder {
    /// Returns `true` if `data` begins with a PKZIP local file header (`PK\x03\x04`).
    public static func isZipBundle(_ data: Data) -> Bool {
        let bytes = [UInt8](data.prefix(4))
        return bytes.count >= 4
            && bytes[0] == 0x50
            && bytes[1] == 0x4B
            && bytes[2] == 0x03
            && bytes[3] == 0x04
    }

    /// Decompresses GZIP (`1F 8B`) or ZLIB (`78 01/5E/9C/DA`) wrappers into raw bytes.
    public static func gunzipIfNeeded(_ rawData: Data) -> Data {
        let bytes = [UInt8](rawData)
        // RFC 1952 GZIP (`1F 8B 08 ...`)
        if bytes.count >= 18 && bytes[0] == 0x1F && bytes[1] == 0x8B && bytes[2] == 0x08 {
            let flg = bytes[3]
            var idx = 10
            if (flg & 0x04) != 0 {
                guard idx + 2 <= bytes.count else { return rawData }
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
            if idx < bytes.count - 8 {
                let rawDeflate = Data(bytes[idx..<(bytes.count - 8)])
                if let inflated = try? (rawDeflate as NSData).decompressed(using: .zlib) as Data {
                    return inflated
                }
            }
        }
        // RFC 1950 ZLIB (`78 01 / 78 5E / 78 9C / 78 DA`)
        if bytes.count >= 6
            && bytes[0] == 0x78
            && (bytes[1] == 0x01 || bytes[1] == 0x5E || bytes[1] == 0x9C || bytes[1] == 0xDA)
            && (((Int(bytes[0]) << 8) | Int(bytes[1])) % 31 == 0)
        {
            let headerLen = (bytes[1] & 0x20) != 0 ? 6 : 2
            if bytes.count > headerLen + 4 {
                let rawDeflate = Data(bytes[headerLen..<(bytes.count - 4)])
                if let inflated = try? (rawDeflate as NSData).decompressed(using: .zlib) as Data {
                    return inflated
                }
            }
        }
        return rawData
    }

    /// Compresses data with RFC 1951 raw DEFLATE (`NSData.CompressionAlgorithm.zlib`).
    public static func compressDeflate(_ data: Data) -> Data? {
        try? (data as NSData).compressed(using: .zlib) as Data
    }

    /// Decompresses RFC 1951 raw DEFLATE (`NSData.CompressionAlgorithm.zlib`).
    public static func decompressDeflate(_ data: Data) -> Data? {
        try? (data as NSData).decompressed(using: .zlib) as Data
    }

    /// Decodes UTF-8 (with optional BOM) or UTF-16LE/BE text documents.
    public static func decodeTextDocument(_ rawData: Data) throws -> String {
        let data = gunzipIfNeeded(rawData)
        let bytes = [UInt8](data)
        if bytes.count >= 2 && ((bytes[0] == 0xFF && bytes[1] == 0xFE) || (bytes[0] == 0xFE && bytes[1] == 0xFF)) {
            if bytes.count % 2 != 0 {
                throw MarcoError.invalidFormat("UTF-16 文本长度无效")
            }
            let littleEndian = bytes[0] == 0xFF
            var units: [UInt16] = []
            units.reserveCapacity((bytes.count - 2) / 2)
            var idx = 2
            while idx + 1 < bytes.count {
                let u: UInt16 = littleEndian
                    ? (UInt16(bytes[idx]) | (UInt16(bytes[idx + 1]) << 8))
                    : ((UInt16(bytes[idx]) << 8) | UInt16(bytes[idx + 1]))
                units.append(u)
                idx += 2
            }
            return String(utf16CodeUnits: units, count: units.count)
        }
        var text = String(decoding: bytes, as: UTF8.self)
        if text.hasPrefix("\u{FEFF}") {
            text.removeFirst()
        }
        return text
    }

    /// Decodes binary/steganographic/gzipped/zlib/encrypted/base64 TVBox config bytes into clean text.
    public static func decodeConfigDocument(_ rawData: Data) throws -> String {
        let data = gunzipIfNeeded(rawData)
        let bytes = [UInt8](data)
        // 1. Check for `**` marker in raw bytes (JPEG/PNG steganography + `**` + Base64)
        if bytes.count >= 18 {
            var starMarker = -1
            var i = bytes.count - 2
            while i >= 0 {
                if bytes[i] == 0x2A && bytes[i + 1] == 0x2A {
                    let tailLen = bytes.count - (i + 2)
                    if tailLen >= 16 {
                        starMarker = i + 2
                        break
                    }
                }
                i -= 1
            }
            if starMarker >= 0 {
                let tailBytes = Array(bytes[starMarker...])
                let tailAscii = String(bytes: tailBytes, encoding: .isoLatin1) ?? String(decoding: tailBytes, as: UTF8.self)
                if let decoded = tryDecodeBase64Json(tailAscii) {
                    return decoded
                }
            }
        }
        let text = try decodeTextDocument(data)
        return unpackConfigText(text)
    }

    /// Unpacks obfuscated or encrypted config text (`**` Base64, `2423...2324` AES-128-CBC, Base64).
    public static func unpackConfigText(_ rawText: String) -> String {
        var s = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("\u{FEFF}") {
            s.removeFirst()
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if s.isEmpty { return "" }
        if looksLikeScript(s) { return s }
        let cleanedJson = stripJsonComments(s)
        if cleanedJson.hasPrefix("{") || cleanedJson.hasPrefix("[") {
            return s
        }
        // 1. `**` + Base64 inside text
        if let range = s.range(of: "**", options: .backwards) {
            let candidate = String(s[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !candidate.isEmpty, let decoded = tryDecodeBase64Json(candidate) {
                return decoded
            }
        }
        // 2. Hex-encoded `$#...#$` (`2423...`) AES-128-CBC TVBox payload
        let compact = s.components(separatedBy: .whitespacesAndNewlines).joined()
        if looksLikeHex(compact) && compact.lowercased().hasPrefix("2423") {
            if let decrypted = tryDecryptTvBoxHexAes(compact) {
                return unpackConfigText(decrypted)
            }
        }
        // 3. Literal `$#...#$` prefix
        if s.hasPrefix("$#") && s.contains("#$") {
            let hexEncoded = bytesToHex([UInt8](s.utf8))
            if let decrypted = tryDecryptTvBoxHexAes(hexEncoded) {
                return unpackConfigText(decrypted)
            }
        }
        // 4. `data:...;base64,` or pure Base64
        var b64Candidate = s
        if let dataRange = b64Candidate.range(of: "base64,") {
            b64Candidate = String(b64Candidate[dataRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if !b64Candidate.hasPrefix("{") && !b64Candidate.hasPrefix("[") && !b64Candidate.hasPrefix("<") {
            if let decoded = tryDecodeBase64Json(b64Candidate) {
                return decoded
            }
        }
        return s
    }

    /// Strips UTF-8 BOM, `//` line comments, `/* */` block comments, and trailing commas before `}` or `]`.
    public static func stripJsonComments(_ input: String) -> String {
        var source = input
        if source.hasPrefix("\u{FEFF}") {
            source.removeFirst()
        }
        let chars = Array(source)
        var out: [Character] = []
        out.reserveCapacity(chars.count)
        var inString = false
        var escaped = false
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inString {
                out.append(c)
                if escaped {
                    escaped = false
                } else if c == "\\" {
                    escaped = true
                } else if c == "\"" {
                    inString = false
                }
                i += 1
                continue
            }
            if c == "\"" {
                inString = true
                out.append(c)
                i += 1
                continue
            }
            if c == "/" && i + 1 < chars.count {
                let next = chars[i + 1]
                if next == "/" {
                    i += 2
                    while i < chars.count && chars[i] != "\n" {
                        i += 1
                    }
                    if i < chars.count {
                        out.append("\n")
                        i += 1
                    }
                    continue
                }
                if next == "*" {
                    i += 2
                    while i + 1 < chars.count && !(chars[i] == "*" && chars[i + 1] == "/") {
                        i += 1
                    }
                    i += 2
                    continue
                }
            }
            out.append(c)
            i += 1
        }
        return stripTrailingCommas(String(out).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func stripTrailingCommas(_ input: String) -> String {
        let chars = Array(input)
        var out: [Character] = []
        out.reserveCapacity(chars.count)
        var inString = false
        var escaped = false
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inString {
                out.append(c)
                if escaped {
                    escaped = false
                } else if c == "\\" {
                    escaped = true
                } else if c == "\"" {
                    inString = false
                }
                i += 1
                continue
            }
            if c == "\"" {
                inString = true
                out.append(c)
                i += 1
                continue
            }
            if c == "," {
                var j = i + 1
                while j < chars.count {
                    let nc = chars[j]
                    if nc == " " || nc == "\t" || nc == "\r" || nc == "\n" {
                        j += 1
                    } else {
                        break
                    }
                }
                if j < chars.count && (chars[j] == "}" || chars[j] == "]") {
                    i += 1
                    continue
                }
            }
            out.append(c)
            i += 1
        }
        return String(out)
    }

    public static func isCatPawBundle(_ code: String) -> Bool {
        code.contains("catServerFactory") && code.contains("catDartServerPort")
    }

    public static func looksLikeScript(_ raw: String) -> Bool {
        let trimmed = raw.drop(while: { $0.isWhitespace })
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            return false
        }
        let s = String(trimmed)
        if s.contains("export default")
            || s.contains("module.exports")
            || s.contains("__jsEvalReturn")
            || s.contains("var rule")
            || s.contains("let rule")
            || s.contains("const rule")
            || s.contains("class Spider")
        {
            return true
        }
        return false
    }

    public static func tryDecodeBase64Json(_ input: String) -> String? {
        let cleaned = input.components(separatedBy: .whitespacesAndNewlines).joined()
        guard cleaned.count >= 8 else { return nil }
        var prefixChars: [Character] = []
        for ch in cleaned {
            if ch.isASCII && (ch.isLetter || ch.isNumber || ch == "+" || ch == "/" || ch == "_" || ch == "-" || ch == "=") {
                prefixChars.append(ch)
            } else {
                break
            }
        }
        guard prefixChars.count >= 8 else { return nil }
        var b64 = String(prefixChars)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 {
            b64.append("=")
        }
        guard let rawDecoded = Data(base64Encoded: b64) else { return nil }
        let decodedData = gunzipIfNeeded(rawDecoded)
        var text = String(decoding: decodedData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("\u{FEFF}") {
            text.removeFirst()
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let strippedComments = stripJsonComments(text)
        if text.hasPrefix("{")
            || text.hasPrefix("[")
            || text.contains("\"sites\"")
            || text.contains("\"urls\"")
            || text.contains("\"storeHouse\"")
            || text.contains("\"depots\"")
            || text.contains("\"lives\"")
            || text.hasPrefix("#EXTM3U")
            || text.contains("#EXTINF:")
            || text.contains(",#genre#")
            || strippedComments.hasPrefix("{")
            || strippedComments.hasPrefix("[")
        {
            return text
        }
        return nil
    }

    // MARK: - TVBox 2423...2324 Hex AES-128-CBC Decryptor

    public static func tryDecryptTvBoxHexAes(_ hexInput: String) -> String? {
        let lowerChars = Array(hexInput.components(separatedBy: .whitespacesAndNewlines).joined().lowercased())
        guard lowerChars.count >= 36, lowerChars.count % 2 == 0 else { return nil }
        let lower = String(lowerChars)
        guard lower.hasPrefix("2423") else { return nil }

        var keyEndIdx = -1
        var searchStart = 4
        while searchStart + 4 <= lowerChars.count {
            if lowerChars[searchStart] == "2"
                && lowerChars[searchStart + 1] == "3"
                && lowerChars[searchStart + 2] == "2"
                && lowerChars[searchStart + 3] == "4"
            {
                if searchStart % 2 == 0 {
                    keyEndIdx = searchStart
                    break
                }
            }
            searchStart += 1
        }
        guard keyEndIdx >= 4, lowerChars.count > keyEndIdx + 4 + 26 else {
            return nil
        }

        let keyHex = String(lowerChars[4..<keyEndIdx])
        let ivHex = String(lowerChars[(lowerChars.count - 26)..<lowerChars.count])
        let cipherHex = String(lowerChars[(keyEndIdx + 4)..<(lowerChars.count - 26)])

        guard let keyRaw = hexToBytes(keyHex),
              let ivRaw = hexToBytes(ivHex),
              let cipherBytes = hexToBytes(cipherHex)
        else {
            return nil
        }

        let keyStr = String(decoding: keyRaw, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let ivStr = String(decoding: ivRaw, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let keyBytes = padRightBytes(Array(keyStr.utf8), length: 16, padByte: 0x30)
        let ivBytes = padRightBytes(Array(ivStr.utf8), length: 16, padByte: 0x30)

        guard let plainBytes = aes128CbcDecrypt(cipher: cipherBytes, key: keyBytes, iv: ivBytes) else {
            return nil
        }
        let text = String(decoding: plainBytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#EXTM3U") || text.contains("#EXTINF:") || text.contains(",#genre#") {
            return text
        }
        if let openBrace = text.firstIndex(of: "{") {
            return String(text[openBrace...])
        }
        return text
    }

    private static func looksLikeHex(_ s: String) -> Bool {
        guard s.count >= 32, s.count % 2 == 0 else { return false }
        return s.utf8.allSatisfy { b in
            (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x46) || (b >= 0x61 && b <= 0x66)
        }
    }

    private static func bytesToHex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func hexToBytes(_ hex: String) -> [UInt8]? {
        let utf8 = Array(hex.utf8)
        guard utf8.count % 2 == 0 else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(utf8.count / 2)
        var i = 0
        while i < utf8.count {
            guard let hi = hexNibble(utf8[i]), let lo = hexNibble(utf8[i + 1]) else { return nil }
            out.append((hi << 4) | lo)
            i += 2
        }
        return out
    }

    private static func hexNibble(_ b: UInt8) -> UInt8? {
        if b >= 0x30 && b <= 0x39 { return b - 0x30 }
        if b >= 0x41 && b <= 0x46 { return b - 0x41 + 10 }
        if b >= 0x61 && b <= 0x66 { return b - 0x61 + 10 }
        return nil
    }

    private static func padRightBytes(_ src: [UInt8], length: Int, padByte: UInt8) -> [UInt8] {
        var out = [UInt8](repeating: padByte, count: length)
        for i in 0..<min(src.count, length) {
            out[i] = src[i]
        }
        return out
    }

    // MARK: - Pure Swift Portable AES-128-CBC (FIPS 197 / PKCS7)

    private static let sBox: [UInt8] = [
        0x63, 0x7c, 0x77, 0x7b, 0xf2, 0x6b, 0x6f, 0xc5, 0x30, 0x01, 0x67, 0x2b, 0xfe, 0xd7, 0xab, 0x76,
        0xca, 0x82, 0xc9, 0x7d, 0xfa, 0x59, 0x47, 0xf0, 0xad, 0xd4, 0xa2, 0xaf, 0x9c, 0xa4, 0x72, 0xc0,
        0xb7, 0xfd, 0x93, 0x26, 0x36, 0x3f, 0xf7, 0xcc, 0x34, 0xa5, 0xe5, 0xf1, 0x71, 0xd8, 0x31, 0x15,
        0x04, 0xc7, 0x23, 0xc3, 0x18, 0x96, 0x05, 0x9a, 0x07, 0x12, 0x80, 0xe2, 0xeb, 0x27, 0xb2, 0x75,
        0x09, 0x83, 0x2c, 0x1a, 0x1b, 0x6e, 0x5a, 0xa0, 0x52, 0x3b, 0xd6, 0xb3, 0x29, 0xe3, 0x2f, 0x84,
        0x53, 0xd1, 0x00, 0xed, 0x20, 0xfc, 0xb1, 0x5b, 0x6a, 0xcb, 0xbe, 0x39, 0x4a, 0x4c, 0x58, 0xcf,
        0xd0, 0xef, 0xaa, 0xfb, 0x43, 0x4d, 0x33, 0x85, 0x45, 0xf9, 0x02, 0x7f, 0x50, 0x3c, 0x9f, 0xa8,
        0x51, 0xa3, 0x40, 0x8f, 0x92, 0x9d, 0x38, 0xf5, 0xbc, 0xb6, 0xda, 0x21, 0x10, 0xff, 0xf3, 0xd2,
        0xcd, 0x0c, 0x13, 0xec, 0x5f, 0x97, 0x44, 0x17, 0xc4, 0xa7, 0x7e, 0x3d, 0x64, 0x5d, 0x19, 0x73,
        0x60, 0x81, 0x4f, 0xdc, 0x22, 0x2a, 0x90, 0x88, 0x46, 0xee, 0xb8, 0x14, 0xde, 0x5e, 0x0b, 0xdb,
        0xe0, 0x32, 0x3a, 0x0a, 0x49, 0x06, 0x24, 0x5c, 0xc2, 0xd3, 0xac, 0x62, 0x91, 0x95, 0xe4, 0x79,
        0xe7, 0xc8, 0x37, 0x6d, 0x8d, 0xd5, 0x4e, 0xa9, 0x6c, 0x56, 0xf4, 0xea, 0x65, 0x7a, 0xae, 0x08,
        0xba, 0x78, 0x25, 0x2e, 0x1c, 0xa6, 0xb4, 0xc6, 0xe8, 0xdd, 0x74, 0x1f, 0x4b, 0xbd, 0x8b, 0x8a,
        0x70, 0x3e, 0xb5, 0x66, 0x48, 0x03, 0xf6, 0x0e, 0x61, 0x35, 0x57, 0xb9, 0x86, 0xc1, 0x1d, 0x9e,
        0xe1, 0xf8, 0x98, 0x11, 0x69, 0xd9, 0x8e, 0x94, 0x9b, 0x1e, 0x87, 0xe9, 0xce, 0x55, 0x28, 0xdf,
        0x8c, 0xa1, 0x89, 0x0d, 0xbf, 0xe6, 0x42, 0x68, 0x41, 0x99, 0x2d, 0x0f, 0xb0, 0x54, 0xbb, 0x16,
    ]

    private static let invSBox: [UInt8] = [
        0x52, 0x09, 0x6a, 0xd5, 0x30, 0x36, 0xa5, 0x38, 0xbf, 0x40, 0xa3, 0x9e, 0x81, 0xf3, 0xd7, 0xfb,
        0x7c, 0xe3, 0x39, 0x82, 0x9b, 0x2f, 0xff, 0x87, 0x34, 0x8e, 0x43, 0x44, 0xc4, 0xde, 0xe9, 0xcb,
        0x54, 0x7b, 0x94, 0x32, 0xa6, 0xc2, 0x23, 0x3d, 0xee, 0x4c, 0x95, 0x0b, 0x42, 0xfa, 0xc3, 0x4e,
        0x08, 0x2e, 0xa1, 0x66, 0x28, 0xd9, 0x24, 0xb2, 0x76, 0x5b, 0xa2, 0x49, 0x6d, 0x8b, 0xd1, 0x25,
        0x72, 0xf8, 0xf6, 0x64, 0x86, 0x68, 0x98, 0x16, 0xd4, 0xa4, 0x5c, 0xcc, 0x5d, 0x65, 0xb6, 0x92,
        0x6c, 0x70, 0x48, 0x50, 0xfd, 0xed, 0xb9, 0xda, 0x5e, 0x15, 0x46, 0x57, 0xa7, 0x8d, 0x9d, 0x84,
        0x90, 0xd8, 0xab, 0x00, 0x8c, 0xbc, 0xd3, 0x0a, 0xf7, 0xe4, 0x58, 0x05, 0xb8, 0xb3, 0x45, 0x06,
        0xd0, 0x2c, 0x1e, 0x8f, 0xca, 0x3f, 0x0f, 0x02, 0xc1, 0xaf, 0xbd, 0x03, 0x01, 0x13, 0x8a, 0x6b,
        0x3a, 0x91, 0x11, 0x41, 0x4f, 0x67, 0xdc, 0xea, 0x97, 0xf2, 0xcf, 0xce, 0xf0, 0xb4, 0xe6, 0x73,
        0x96, 0xac, 0x74, 0x22, 0xe7, 0xad, 0x35, 0x85, 0xe2, 0xf9, 0x37, 0xe8, 0x1c, 0x75, 0xdf, 0x6e,
        0x47, 0xf1, 0x1a, 0x71, 0x1d, 0x29, 0xc5, 0x89, 0x6f, 0xb7, 0x62, 0x0e, 0xaa, 0x18, 0xbe, 0x1b,
        0xfc, 0x56, 0x3e, 0x4b, 0xc6, 0xd2, 0x79, 0x20, 0x9a, 0xdb, 0xc0, 0xfe, 0x78, 0xcd, 0x5a, 0xf4,
        0x1f, 0xdd, 0xa8, 0x33, 0x88, 0x07, 0xc7, 0x31, 0xb1, 0x12, 0x10, 0x59, 0x27, 0x80, 0xec, 0x5f,
        0x60, 0x51, 0x7f, 0xa9, 0x19, 0xb5, 0x4a, 0x0d, 0x2d, 0xe5, 0x7a, 0x9f, 0x93, 0xc9, 0x9c, 0xef,
        0xa0, 0xe0, 0x3b, 0x4d, 0xae, 0x2a, 0xf5, 0xb0, 0xc8, 0xeb, 0xbb, 0x3c, 0x83, 0x53, 0x99, 0x61,
        0x17, 0x2b, 0x04, 0x7e, 0xba, 0x77, 0xd6, 0x26, 0xe1, 0x69, 0x14, 0x63, 0x55, 0x21, 0x0c, 0x7d,
    ]

    private static let rCon: [UInt8] = [
        0x00, 0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1b, 0x36,
    ]

    public static func aes128CbcDecrypt(cipher: [UInt8], key: [UInt8], iv: [UInt8]) -> [UInt8]? {
        guard !cipher.isEmpty, cipher.count % 16 == 0, key.count == 16, iv.count == 16 else {
            return nil
        }
        let roundKeys = aesKeyExpansion(key)
        var out = [UInt8](repeating: 0, count: cipher.count)
        var prevBlock = iv
        var offset = 0
        while offset < cipher.count {
            let block = Array(cipher[offset..<(offset + 16)])
            let decrypted = aesDecryptBlock(block, roundKeys: roundKeys)
            for i in 0..<16 {
                out[offset + i] = decrypted[i] ^ prevBlock[i]
            }
            prevBlock = block
            offset += 16
        }
        if let padByte = out.last {
            let padLen = Int(padByte)
            if padLen >= 1 && padLen <= 16 && padLen <= out.count {
                let valid = out[(out.count - padLen)..<out.count].allSatisfy { $0 == padByte }
                if valid {
                    return Array(out[0..<(out.count - padLen)])
                }
            }
        }
        return out
    }

    private static func aesKeyExpansion(_ key: [UInt8]) -> [UInt8] {
        var w = [UInt8](repeating: 0, count: 176)
        for i in 0..<16 { w[i] = key[i] }
        var temp = [UInt8](repeating: 0, count: 4)
        var bytesGenerated = 16
        var rconIter = 1
        while bytesGenerated < 176 {
            for i in 0..<4 {
                temp[i] = w[bytesGenerated - 4 + i]
            }
            if bytesGenerated % 16 == 0 {
                let k = temp[0]
                temp[0] = sBox[Int(temp[1])] ^ rCon[rconIter]
                rconIter += 1
                temp[1] = sBox[Int(temp[2])]
                temp[2] = sBox[Int(temp[3])]
                temp[3] = sBox[Int(k)]
            }
            for i in 0..<4 {
                w[bytesGenerated] = w[bytesGenerated - 16] ^ temp[i]
                bytesGenerated += 1
            }
        }
        return w
    }

    private static func gfMul(_ a: UInt8, _ b: UInt8) -> UInt8 {
        var p: UInt8 = 0
        var aa = a
        var bb = b
        for _ in 0..<8 {
            if (bb & 1) != 0 { p ^= aa }
            let hiBit = aa & 0x80
            aa = aa &<< 1
            if hiBit != 0 { aa ^= 0x1b }
            bb >>= 1
        }
        return p
    }

    private static func aesDecryptBlock(_ input: [UInt8], roundKeys w: [UInt8]) -> [UInt8] {
        var state = input
        func addRoundKey(_ round: Int) {
            let base = round * 16
            for i in 0..<16 {
                state[i] ^= w[base + i]
            }
        }
        func invShiftRows() {
            var t = state[13]
            state[13] = state[9]
            state[9] = state[5]
            state[5] = state[1]
            state[1] = t

            t = state[2]
            state[2] = state[10]
            state[10] = t
            t = state[6]
            state[6] = state[14]
            state[14] = t

            t = state[3]
            state[3] = state[7]
            state[7] = state[11]
            state[11] = state[15]
            state[15] = t
        }
        func invSubBytes() {
            for i in 0..<16 {
                state[i] = invSBox[Int(state[i])]
            }
        }
        func invMixColumns() {
            for c in 0..<4 {
                let i = c * 4
                let s0 = state[i]
                let s1 = state[i + 1]
                let s2 = state[i + 2]
                let s3 = state[i + 3]
                state[i] = gfMul(s0, 0x0e) ^ gfMul(s1, 0x0b) ^ gfMul(s2, 0x0d) ^ gfMul(s3, 0x09)
                state[i + 1] = gfMul(s0, 0x09) ^ gfMul(s1, 0x0e) ^ gfMul(s2, 0x0b) ^ gfMul(s3, 0x0d)
                state[i + 2] = gfMul(s0, 0x0d) ^ gfMul(s1, 0x09) ^ gfMul(s2, 0x0e) ^ gfMul(s3, 0x0b)
                state[i + 3] = gfMul(s0, 0x0b) ^ gfMul(s1, 0x0d) ^ gfMul(s2, 0x09) ^ gfMul(s3, 0x0e)
            }
        }

        addRoundKey(10)
        for round in stride(from: 9, through: 1, by: -1) {
            invShiftRows()
            invSubBytes()
            addRoundKey(round)
            invMixColumns()
        }
        invShiftRows()
        invSubBytes()
        addRoundKey(0)
        return state
    }
}
