// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only

import CryptoKit
import Foundation

public struct ParsedBindTarget: Sendable, Equatable {
    public let baseEndpointUrl: String
    public let bindUrl: String
    public let syncUrl: String
    public let key: Data

    public init(baseEndpointUrl: String, bindUrl: String, syncUrl: String, key: Data) {
        self.baseEndpointUrl = baseEndpointUrl
        self.bindUrl = bindUrl
        self.syncUrl = syncUrl
        self.key = key
    }
}

public enum WebdavBindCryptoError: Error, Sendable {
    case invalidKeyLength
    case invalidNonceLength
    case invalidInput
    case invalidEnvelope
    case authenticationFailed
}

/// Pure HMAC-SHA256 authenticated encryption (`marco-bind-box-v1`) and QR URI codecs matching
/// Java `com.pilipala.source.WebdavBindCrypto`, Dart `WebdavBindCrypto`, and tvOS byte-for-byte.
public enum WebdavBindCrypto {
    public static let bindSchemeFragment = "marco-bind=v1"
    public static let alg = "marco-bind-box-v1"
    public static let keyBytes = 32
    public static let nonceBytes = 16
    private static let encInfo = "marco-bind-v1-enc"
    private static let macInfo = "marco-bind-v1-mac"
    private static let macLabel = "marco-bind-box-v1"

    public static func generateKey() -> Data {
        var bytes = [UInt8](repeating: 0, count: keyBytes)
        for idx in 0..<keyBytes {
            bytes[idx] = UInt8.random(in: 0...255)
        }
        return Data(bytes)
    }

    public static func generateNonce() -> Data {
        var bytes = [UInt8](repeating: 0, count: nonceBytes)
        for idx in 0..<nonceBytes {
            bytes[idx] = UInt8.random(in: 0...255)
        }
        return Data(bytes)
    }

    public static func encodeBase64UrlNoPad(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func decodeBase64Url(_ text: String) throws -> Data {
        var b64 = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let rem = b64.count % 4
        if rem == 1 {
            throw WebdavBindCryptoError.invalidInput
        }
        if rem > 0 {
            b64.append(String(repeating: "=", count: 4 - rem))
        }
        guard let decoded = Data(base64Encoded: b64) else {
            throw WebdavBindCryptoError.invalidInput
        }
        return decoded
    }

    public static func buildBindQrUrl(baseEndpointUrl: String, key: Data) throws -> String {
        var cleanBase = baseEndpointUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanBase.isEmpty else {
            throw WebdavBindCryptoError.invalidInput
        }
        guard key.count == keyBytes else {
            throw WebdavBindCryptoError.invalidKeyLength
        }
        if let hashIdx = cleanBase.firstIndex(of: "#") {
            cleanBase = String(cleanBase[..<hashIdx])
        }
        return "\(cleanBase)#\(bindSchemeFragment)&k=\(encodeBase64UrlNoPad(key))"
    }

    public static func parseBindQrInput(_ rawInput: String) -> ParsedBindTarget? {
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var endpoint = ""
        var keyB64 = ""

        if trimmed.lowercased().hasPrefix("marcomovie://bind") {
            guard let comps = URLComponents(string: trimmed) else { return nil }
            for item in comps.queryItems ?? [] {
                if item.name == "u" {
                    endpoint = (item.value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                } else if item.name == "k" {
                    keyB64 = (item.value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        } else {
            guard let hashIdx = trimmed.firstIndex(of: "#") else { return nil }
            endpoint = String(trimmed[..<hashIdx]).trimmingCharacters(in: .whitespacesAndNewlines)
            let frag = String(trimmed[trimmed.index(after: hashIdx)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            for part in frag.split(separator: "&") {
                let kv = part.split(separator: "=", maxSplits: 1)
                guard kv.count == 2 else { continue }
                let name = String(kv[0])
                let val = String(kv[1]).removingPercentEncoding ?? String(kv[1])
                if name == "k" {
                    keyB64 = val.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }

        guard !endpoint.isEmpty, !keyB64.isEmpty,
              let key = try? decodeBase64Url(keyB64),
              key.count == keyBytes,
              let uri = URL(string: endpoint),
              let scheme = uri.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              let host = uri.host,
              !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }

        var base = endpoint
        while base.hasSuffix("/") {
            base.removeLast()
        }
        if base.hasSuffix("/bind") {
            base = String(base.dropLast("/bind".count))
        } else if base.hasSuffix("/sync") {
            base = String(base.dropLast("/sync".count))
        }

        return ParsedBindTarget(
            baseEndpointUrl: base,
            bindUrl: "\(base)/bind",
            syncUrl: "\(base)/sync",
            key: key
        )
    }

    public static func sealJson(key: Data, payload: [String: Any]) throws -> String {
        let jsonData = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let plaintext = String(decoding: jsonData, as: UTF8.self)
        return try sealPlaintextWithNonce(key: key, nonce: generateNonce(), plaintextJson: plaintext)
    }

    public static func sealPlaintextWithNonce(key: Data, nonce: Data, plaintextJson: String) throws -> String {
        guard key.count == keyBytes else { throw WebdavBindCryptoError.invalidKeyLength }
        guard nonce.count == nonceBytes else { throw WebdavBindCryptoError.invalidNonceLength }
        let pt = Data(plaintextJson.utf8)
        let encKey = hmacSha256(key: key, message: Data(encInfo.utf8))
        let macKey = hmacSha256(key: key, message: Data(macInfo.utf8))
        let ct = xorCtr(encKey: encKey, nonce: nonce, data: pt)
        let tag = computeTag(macKey: macKey, nonce: nonce, ct: ct)
        let env: [String: Any] = [
            "v": 1,
            "alg": alg,
            "n": encodeBase64UrlNoPad(nonce),
            "c": encodeBase64UrlNoPad(ct),
            "t": encodeBase64UrlNoPad(tag),
        ]
        let outData = try JSONSerialization.data(withJSONObject: env, options: [.sortedKeys])
        return String(decoding: outData, as: UTF8.self)
    }

    public static func openJson(key: Data, envelopeJson: String) throws -> [String: Any] {
        let raw = try openPlaintext(key: key, envelopeJson: envelopeJson)
        guard let obj = try JSONSerialization.jsonObject(with: Data(raw.utf8), options: []) as? [String: Any] else {
            throw WebdavBindCryptoError.invalidEnvelope
        }
        return obj
    }

    public static func openPlaintext(key: Data, envelopeJson: String) throws -> String {
        guard key.count == keyBytes else { throw WebdavBindCryptoError.invalidKeyLength }
        guard let rawObj = try JSONSerialization.jsonObject(
            with: Data(envelopeJson.utf8),
            options: []
        ) as? [String: Any] else {
            throw WebdavBindCryptoError.invalidEnvelope
        }
        guard (rawObj["v"] as? Int) == 1,
              (rawObj["alg"] as? String) == alg,
              let nStr = rawObj["n"] as? String,
              let cStr = rawObj["c"] as? String,
              let tStr = rawObj["t"] as? String
        else {
            throw WebdavBindCryptoError.invalidEnvelope
        }
        let nonce = try decodeBase64Url(nStr)
        let ct = try decodeBase64Url(cStr)
        let tag = try decodeBase64Url(tStr)
        guard nonce.count == nonceBytes, tag.count == 32 else {
            throw WebdavBindCryptoError.invalidEnvelope
        }
        let macKey = hmacSha256(key: key, message: Data(macInfo.utf8))
        let expectedTag = computeTag(macKey: macKey, nonce: nonce, ct: ct)
        var diff: UInt8 = 0
        for i in 0..<32 {
            diff |= expectedTag[i] ^ tag[i]
        }
        guard diff == 0 else {
            throw WebdavBindCryptoError.authenticationFailed
        }
        let encKey = hmacSha256(key: key, message: Data(encInfo.utf8))
        let pt = xorCtr(encKey: encKey, nonce: nonce, data: ct)
        return String(decoding: pt, as: UTF8.self)
    }

    private static func computeTag(macKey: Data, nonce: Data, ct: Data) -> Data {
        var input = Data(macLabel.utf8)
        input.append(nonce)
        input.append(ct)
        return hmacSha256(key: macKey, message: input)
    }

    private static func xorCtr(encKey: Data, nonce: Data, data: Data) -> Data {
        var out = Data(count: data.count)
        var blockInput = Data(nonce)
        blockInput.append(contentsOf: [0, 0, 0, 0])
        var offset = 0
        var counter: UInt32 = 0
        while offset < data.count {
            blockInput[nonce.count] = UInt8((counter >> 24) & 0xff)
            blockInput[nonce.count + 1] = UInt8((counter >> 16) & 0xff)
            blockInput[nonce.count + 2] = UInt8((counter >> 8) & 0xff)
            blockInput[nonce.count + 3] = UInt8(counter & 0xff)
            let ks = hmacSha256(key: encKey, message: blockInput)
            let take = min(ks.count, data.count - offset)
            for i in 0..<take {
                out[offset + i] = data[offset + i] ^ ks[i]
            }
            offset += take
            counter &+= 1
        }
        return out
    }

    public static func hmacSha256(key: Data, message: Data) -> Data {
        let symKey = SymmetricKey(data: key)
        let code = HMAC<SHA256>.authenticationCode(for: message, using: symKey)
        return Data(code)
    }
}
