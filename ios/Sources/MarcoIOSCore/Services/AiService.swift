// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only

import CryptoKit
import Foundation

public struct AiProviderPreset: Equatable, Hashable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let description: String
    public let protocolType: AiApiProtocol
    public let authMode: AiAuthMode
    public let defaultBaseUrl: String
    public let defaultModel: String
    public let defaultFastModel: String
    public let suggestedModels: [String]

    public init(
        id: String,
        name: String,
        description: String,
        protocolType: AiApiProtocol,
        authMode: AiAuthMode,
        defaultBaseUrl: String,
        defaultModel: String,
        defaultFastModel: String = "",
        suggestedModels: [String] = []
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.protocolType = protocolType
        self.authMode = authMode
        self.defaultBaseUrl = defaultBaseUrl
        self.defaultModel = defaultModel
        self.defaultFastModel = defaultFastModel
        self.suggestedModels = suggestedModels
    }
}

public struct AiCompletionResult: Equatable, Sendable {
    public let text: String
    public let promptTokens: Int
    public let completionTokens: Int

    public init(text: String, promptTokens: Int = 0, completionTokens: Int = 0) {
        self.text = text
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
    }
}

// MARK: - Offline Ed25519 AI Lab Passcode Verifier

public struct AiLabPasscodePayload: Equatable, Hashable, Sendable {
    public let version: Int
    public let tag: String
    public let issuedAtEpochSec: Int64
    public let expiresAtEpochSec: Int64
    public let platform: String
    public let shared: Bool
    public let experimentalOAuth: Bool
    public let minVersionCode: Int
    public let nonce: String

    public init(
        version: Int,
        tag: String = "",
        issuedAtEpochSec: Int64 = 0,
        expiresAtEpochSec: Int64 = 0,
        platform: String = "all",
        shared: Bool = false,
        experimentalOAuth: Bool = false,
        minVersionCode: Int = 0,
        nonce: String = ""
    ) {
        self.version = version
        self.tag = tag
        self.issuedAtEpochSec = max(0, issuedAtEpochSec)
        self.expiresAtEpochSec = max(0, expiresAtEpochSec)
        self.platform = platform.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "all" : platform.trimmingCharacters(in: .whitespacesAndNewlines)
        self.shared = shared
        self.experimentalOAuth = experimentalOAuth
        self.minVersionCode = max(0, minVersionCode)
        self.nonce = nonce
    }

    public var hasExpiry: Bool { expiresAtEpochSec > 0 }
    public var isPermanent: Bool { !hasExpiry }

    public func isExpired(at date: Date = Date()) -> Bool {
        guard hasExpiry else { return false }
        return Int64(date.timeIntervalSince1970) > expiresAtEpochSec
    }

    public func requiresNewerVersion(_ currentVersionCode: Int) -> Bool {
        minVersionCode > 0 && currentVersionCode > 0 && currentVersionCode < minVersionCode
    }

    public static func normalizePlatformName(_ raw: String) -> String {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "android-mobile", "mobile": return "android"
        case "win", "pc": return "windows"
        case "iphone", "ipad": return "ios"
        case "mac", "osx": return "macos"
        case "*": return "all"
        case let other: return other
        }
    }

    public func matchesPlatform(_ targetPlatform: String) -> Bool {
        let rawPlat = platform.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if rawPlat.isEmpty || rawPlat == "all" || rawPlat == "*" { return true }
        let normTarget = Self.normalizePlatformName(targetPlatform)
        if normTarget.isEmpty || normTarget == "all" || normTarget == "*" { return true }
        let separators = CharacterSet(charactersIn: ",;/ \t\r\n")
        let parts = rawPlat.components(separatedBy: separators).filter { !$0.isEmpty }
        if parts.isEmpty { return true }
        for part in parts {
            if part == "all" || part == "*" { return true }
            if Self.normalizePlatformName(part) == normTarget { return true }
        }
        return false
    }

    public var platformScopeLabelZh: String {
        let p = platform.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if p.isEmpty || p == "all" || p == "*" { return "三端通用" }
        var hasAnd = false
        var hasIos = false
        var hasWin = false
        var extras: [String] = []
        for part in p.components(separatedBy: CharacterSet(charactersIn: ",;/ \t\r\n")) {
            let tok = Self.normalizePlatformName(part)
            guard !tok.isEmpty else { continue }
            if tok == "all" { return "三端通用" }
            if tok == "android" { hasAnd = true }
            else if tok == "ios" { hasIos = true }
            else if tok == "windows" { hasWin = true }
            else if !extras.contains(tok) { extras.append(tok) }
        }
        if hasAnd && hasIos && hasWin && extras.isEmpty { return "三端通用" }
        var names: [String] = []
        if hasAnd { names.append("安卓") }
        if hasIos { names.append("iOS") }
        if hasWin { names.append("Windows") }
        names.append(contentsOf: extras)
        return names.isEmpty ? "三端通用" : "仅限 \(names.joined(separator: "/"))"
    }

    public var expiryLabelZh: String {
        guard hasExpiry else { return "永久有效" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        let dt = Date(timeIntervalSince1970: TimeInterval(expiresAtEpochSec))
        return "有效至 \(formatter.string(from: dt))"
    }

    public var summaryBadgeZh: String {
        let labelTag = tag.isEmpty ? "内测口令" : tag
        let channel = shared ? "频道通用" : "专属内测"
        let oauthPart = experimentalOAuth ? " · 含实验性 OAuth" : ""
        return "\(labelTag) · \(platformScopeLabelZh) · \(channel)\(oauthPart) · \(expiryLabelZh)"
    }
}

public enum AiLabPasscodeStatus: String, Equatable, Sendable {
    case valid
    case empty
    case malformed
    case invalidSignature
    case unsupportedVersion
    case wrongPlatform
    case versionTooOld
    case expired
    case missingPublicKey
}

public struct AiLabPasscodeVerifyResult: Equatable, Sendable {
    public let status: AiLabPasscodeStatus
    public let payload: AiLabPasscodePayload?
    public let canonicalToken: String
    public let messageZh: String

    public init(
        status: AiLabPasscodeStatus,
        messageZh: String,
        payload: AiLabPasscodePayload? = nil,
        canonicalToken: String = ""
    ) {
        self.status = status
        self.messageZh = messageZh
        self.payload = payload
        self.canonicalToken = canonicalToken
    }

    public var isValid: Bool {
        status == .valid && payload != nil
    }
}

/// Pure offline RFC 8032 Ed25519 verifier for Marco Movie AI Lab passcodes:
/// `MMAILAB1.<payload_b64url_nopad>.<sig_b64url_nopad>`
/// Signature covers `utf8("marco-ai-lab-v1:") + decoded_payload_bytes`.
public enum AiLabPasscodeVerifier {
    public static let tokenPrefix = "MMAILAB1"
    public static let signingDomainPrefix = "marco-ai-lab-v1:"
    public static let defaultPublicKeyHex = "1dbeaed851b873d7c327d30d718fca0ac1509ef5ac4061b9bd1aa90c841c6929"

    private static let tokenExtractRegex = try! NSRegularExpression(
        pattern: #"MMAILAB1\.([A-Za-z0-9_-]+)\.([A-Za-z0-9_-]+)"#,
        options: []
    )

    public static func extractToken(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if let m = tokenExtractRegex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
           let r = Range(m.range(at: 0), in: trimmed)
        {
            return String(trimmed[r])
        }
        let collapsed = trimmed.components(separatedBy: .whitespacesAndNewlines).joined()
        if let m = tokenExtractRegex.firstMatch(in: collapsed, range: NSRange(collapsed.startIndex..., in: collapsed)),
           let r = Range(m.range(at: 0), in: collapsed)
        {
            return String(collapsed[r])
        }
        return collapsed
    }

    public static func verify(
        _ rawPasscode: String,
        publicKeyHex: String? = nil,
        targetPlatform: String = "ios",
        currentVersionCode: Int? = nil,
        now: Date = Date()
    ) -> AiLabPasscodeVerifyResult {
        let cleaned = extractToken(rawPasscode)
        guard !cleaned.isEmpty else {
            return AiLabPasscodeVerifyResult(status: .empty, messageZh: "请输入 AI 观影实验室解锁口令")
        }

        let effectiveHex = (publicKeyHex ?? defaultPublicKeyHex).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pubBytes = decodeHex32(effectiveHex),
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: pubBytes)
        else {
            return AiLabPasscodeVerifyResult(status: .missingPublicKey, messageZh: "当前构建未配置有效的 Ed25519 验签公钥")
        }

        let nsRange = NSRange(cleaned.startIndex..., in: cleaned)
        guard let match = tokenExtractRegex.firstMatch(in: cleaned, range: nsRange),
              let fullRange = Range(match.range(at: 0), in: cleaned),
              String(cleaned[fullRange]) == cleaned,
              let payloadRange = Range(match.range(at: 1), in: cleaned),
              let sigRange = Range(match.range(at: 2), in: cleaned)
        else {
            return AiLabPasscodeVerifyResult(
                status: .malformed,
                messageZh: "口令格式无效，应为 \(tokenPrefix).<载荷>.<签名>"
            )
        }

        let payloadB64 = String(cleaned[payloadRange])
        let sigB64 = String(cleaned[sigRange])
        guard let payloadBytes = try? WebdavBindCrypto.decodeBase64Url(payloadB64),
              !payloadBytes.isEmpty,
              let sigBytes = try? WebdavBindCrypto.decodeBase64Url(sigB64),
              sigBytes.count == 64
        else {
            return AiLabPasscodeVerifyResult(status: .malformed, messageZh: "口令编码损坏，请确认完整复制了整段口令")
        }

        var messageBytes = Data(signingDomainPrefix.utf8)
        messageBytes.append(payloadBytes)
        guard publicKey.isValidSignature(sigBytes, for: messageBytes) else {
            return AiLabPasscodeVerifyResult(
                status: .invalidSignature,
                messageZh: "口令 Ed25519 离线签名校验失败，请确认来源为官方渠道"
            )
        }

        guard let decoded = (try? JSONSerialization.jsonObject(with: payloadBytes)) as? [String: Any] else {
            return AiLabPasscodeVerifyResult(status: .malformed, messageZh: "口令载荷无法解析")
        }

        let version = (decoded["v"] as? NSNumber)?.intValue ?? 0
        guard version == 1 else {
            return AiLabPasscodeVerifyResult(
                status: .unsupportedVersion,
                messageZh: "不支持的口令版本（v\(version)），请前往官网更新应用"
            )
        }

        let tag = ((decoded["tag"] ?? decoded["id"]) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let iat = (decoded["iat"] as? NSNumber)?.int64Value ?? 0
        let exp = (decoded["exp"] as? NSNumber)?.int64Value ?? 0
        let plat = (decoded["plat"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "all"
        let shared = parseBoolFlag(decoded["shared"])
        let expOAuth = parseBoolFlag(decoded["exp_oauth"])
        let minVc = (decoded["min_vc"] as? NSNumber)?.intValue ?? 0
        let nonce = (decoded["n"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let payload = AiLabPasscodePayload(
            version: version,
            tag: tag,
            issuedAtEpochSec: iat,
            expiresAtEpochSec: exp,
            platform: plat.isEmpty ? "all" : plat,
            shared: shared,
            experimentalOAuth: expOAuth,
            minVersionCode: minVc,
            nonce: nonce
        )

        if !payload.matchesPlatform(targetPlatform) {
            return AiLabPasscodeVerifyResult(
                status: .wrongPlatform,
                messageZh: "该内测口令适用范围为「\(payload.platformScopeLabelZh)」，不适用于当前设备平台（\(targetPlatform)）",
                payload: payload
            )
        }

        if let curVc = currentVersionCode, payload.requiresNewerVersion(curVc) {
            return AiLabPasscodeVerifyResult(
                status: .versionTooOld,
                messageZh: "该口令要求更高版本客户端（最低构建号 \(payload.minVersionCode)），请先更新应用",
                payload: payload
            )
        }

        if payload.isExpired(at: now) {
            return AiLabPasscodeVerifyResult(
                status: .expired,
                messageZh: "该内测口令已过期，请获取新口令",
                payload: payload
            )
        }

        let canonical = "\(tokenPrefix).\(payloadB64).\(sigB64)"
        let msg = tag.isEmpty
            ? "Ed25519 离线验签通过 · 已开启 AI 观影实验室"
            : "Ed25519 离线验签通过 · 已开启 AI 观影实验室（\(tag)）"
        return AiLabPasscodeVerifyResult(
            status: .valid,
            messageZh: msg,
            payload: payload,
            canonicalToken: canonical
        )
    }

    /// Generates a valid signed `MMAILAB1.<payload>.<sig>` passcode for unit tests using an ephemeral key.
    public static func signForTesting(
        payload: [String: Any],
        privateKey: Curve25519.Signing.PrivateKey
    ) throws -> String {
        let payloadBytes = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        var message = Data(signingDomainPrefix.utf8)
        message.append(payloadBytes)
        let sig = try privateKey.signature(for: message)
        let payloadB64 = WebdavBindCrypto.encodeBase64UrlNoPad(payloadBytes)
        let sigB64 = WebdavBindCrypto.encodeBase64UrlNoPad(sig)
        return "\(tokenPrefix).\(payloadB64).\(sigB64)"
    }

    private static func decodeHex32(_ hex: String) -> Data? {
        let bytes = Array(hex.utf8)
        guard bytes.count == 64 else { return nil }
        var out = Data(capacity: 32)
        var i = 0
        while i < 64 {
            guard let hi = hexVal(bytes[i]), let lo = hexVal(bytes[i + 1]) else { return nil }
            out.append((hi << 4) | lo)
            i += 2
        }
        return out
    }

    private static func hexVal(_ b: UInt8) -> UInt8? {
        if b >= 0x30 && b <= 0x39 { return b - 0x30 }
        if b >= 0x41 && b <= 0x46 { return b - 0x41 + 10 }
        if b >= 0x61 && b <= 0x66 { return b - 0x61 + 10 }
        return nil
    }

    private static func parseBoolFlag(_ raw: Any?) -> Bool {
        if let b = raw as? Bool { return b }
        if let n = raw as? NSNumber { return n.intValue != 0 }
        if let s = raw as? String {
            let l = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return l == "true" || l == "1"
        }
        return false
    }
}

// MARK: - AI Lab Feature Result Models

public struct AiWatchBriefResult: Equatable, Sendable {
    public let oneLineHook: String
    public let highlights: [String]
    public let backgroundContext: [String]
    public let viewingNote: String

    public init(oneLineHook: String, highlights: [String], backgroundContext: [String], viewingNote: String) {
        self.oneLineHook = oneLineHook
        self.highlights = highlights
        self.backgroundContext = backgroundContext
        self.viewingNote = viewingNote
    }
}

public struct AiCharacterNote: Equatable, Hashable, Sendable {
    public let name: String
    public let factionOrRole: String
    public let summary: String

    public init(name: String, factionOrRole: String, summary: String) {
        self.name = name
        self.factionOrRole = factionOrRole
        self.summary = summary
    }
}

public struct AiEpisodeCompanionResult: Equatable, Sendable {
    public let boundaryLabel: String
    public let recap: String
    public let characters: [AiCharacterNote]
    public let trivia: String

    public init(boundaryLabel: String, recap: String, characters: [AiCharacterNote], trivia: String) {
        self.boundaryLabel = boundaryLabel
        self.recap = recap
        self.characters = characters
        self.trivia = trivia
    }
}

public struct AiCuratedPick: Equatable, Hashable, Sendable {
    public let title: String
    public let year: String
    public let moodTag: String
    public let reason: String

    public init(title: String, year: String = "", moodTag: String = "", reason: String = "") {
        self.title = title
        self.year = year
        self.moodTag = moodTag
        self.reason = reason
    }
}

public struct AiMoodSommelierResult: Equatable, Sendable {
    public let tastePortrait: String
    public let picks: [AiCuratedPick]

    public init(tastePortrait: String, picks: [AiCuratedPick]) {
        self.tastePortrait = tastePortrait
        self.picks = picks
    }
}

public struct AiDiagnosticReport: Equatable, Sendable {
    public let rootCauseZh: String
    public let stepsZh: [String]
    public let suggestedActions: [String]

    public init(rootCauseZh: String, stepsZh: [String], suggestedActions: [String] = []) {
        self.rootCauseZh = rootCauseZh
        self.stepsZh = stepsZh
        self.suggestedActions = suggestedActions
    }
}

public struct AiEpisodeCuratePlan: Equatable, Sendable {
    public let canonicalTitle: String
    public let seasonNumber: Int
    public let episodeOffset: Int
    public let specialIndices: [Int]
    public let summaryZh: String

    public init(
        canonicalTitle: String,
        seasonNumber: Int = 1,
        episodeOffset: Int = 0,
        specialIndices: [Int] = [],
        summaryZh: String = ""
    ) {
        self.canonicalTitle = canonicalTitle
        self.seasonNumber = seasonNumber
        self.episodeOffset = episodeOffset
        self.specialIndices = specialIndices
        self.summaryZh = summaryZh
    }
}

// MARK: - AI Assistant Service

/// Bring-Your-Own-API (BYO-API) multi-protocol AI assistant client supporting:
/// - OpenAI-compatible (`/chat/completions`)
/// - Anthropic Messages (`/v1/messages`)
/// - Google Gemini (`generateContent`)
/// - Offline Ed25519 AI Lab passcode verification (`AiLabPasscodeVerifier`)
/// - Strict zero-URL output filtering (`containsForbiddenUrl`) & diagnostic desensitization
/// - Hard privacy-space gating (ALL AI requests are rejected in Privacy Space).
public final class AiService: @unchecked Sendable {
    private static let labPasscodeKeychainKey = "marco_ai_lab_token_v1"

    private static let forbiddenUrlRegex = try! NSRegularExpression(
        pattern: #"(?:https?://|ftp://|magnet:\?|ed2k://|thunder://|mms://|rtmp://|rtsp://|\bwww\.[a-z0-9-]+\.[a-z]{2,})"#,
        options: [.caseInsensitive]
    )

    public static let presets: [AiProviderPreset] = [
        AiProviderPreset(
            id: "openrouter",
            name: "OpenRouter",
            description: "支持官方 PKCE 授权与多模型聚合",
            protocolType: .openaiCompatible,
            authMode: .openRouterOAuth,
            defaultBaseUrl: "https://openrouter.ai/api/v1",
            defaultModel: "openai/gpt-4o-mini",
            defaultFastModel: "openai/gpt-4o-mini",
            suggestedModels: ["openai/gpt-4o-mini", "anthropic/claude-3.5-haiku", "google/gemini-2.5-flash", "deepseek/deepseek-chat"]
        ),
        AiProviderPreset(
            id: "github_copilot",
            name: "GitHub Copilot",
            description: "使用官方 GitHub 设备码登录已有 Copilot 订阅",
            protocolType: .openaiCompatible,
            authMode: .githubCopilotDeviceFlow,
            defaultBaseUrl: "https://api.githubcopilot.com",
            defaultModel: "gpt-4o",
            defaultFastModel: "gpt-4o-mini",
            suggestedModels: ["gpt-4o", "gpt-4o-mini", "claude-3.5-sonnet"]
        ),
        AiProviderPreset(
            id: "ollama",
            name: "本地 Ollama",
            description: "本机离线推理（127.0.0.1:11434），无需 API Key",
            protocolType: .openaiCompatible,
            authMode: .localNoAuth,
            defaultBaseUrl: "http://127.0.0.1:11434/v1",
            defaultModel: "qwen2.5:7b",
            defaultFastModel: "qwen2.5:7b"
        ),
        AiProviderPreset(
            id: "lm_studio",
            name: "本地 LM Studio",
            description: "本机 OpenAI 兼容服务（127.0.0.1:1234），无需 API Key",
            protocolType: .openaiCompatible,
            authMode: .localNoAuth,
            defaultBaseUrl: "http://127.0.0.1:1234/v1",
            defaultModel: "local-model",
            defaultFastModel: "local-model"
        ),
        AiProviderPreset(
            id: "deepseek",
            name: "DeepSeek",
            description: "DeepSeek 官方 OpenAI 兼容接口",
            protocolType: .openaiCompatible,
            authMode: .apiKey,
            defaultBaseUrl: "https://api.deepseek.com/v1",
            defaultModel: "deepseek-chat",
            defaultFastModel: "deepseek-chat",
            suggestedModels: ["deepseek-chat", "deepseek-reasoner"]
        ),
        AiProviderPreset(
            id: "dashscope",
            name: "通义千问 DashScope",
            description: "阿里云百炼 OpenAI 兼容接口",
            protocolType: .openaiCompatible,
            authMode: .apiKey,
            defaultBaseUrl: "https://dashscope.aliyuncs.com/compatible-mode/v1",
            defaultModel: "qwen-plus",
            defaultFastModel: "qwen-turbo",
            suggestedModels: ["qwen-plus", "qwen-turbo", "qwen-max"]
        ),
        AiProviderPreset(
            id: "moonshot",
            name: "Kimi Moonshot",
            description: "月之暗面 Kimi 官方 API",
            protocolType: .openaiCompatible,
            authMode: .apiKey,
            defaultBaseUrl: "https://api.moonshot.cn/v1",
            defaultModel: "moonshot-v1-8k",
            defaultFastModel: "moonshot-v1-8k",
            suggestedModels: ["moonshot-v1-8k"]
        ),
        AiProviderPreset(
            id: "siliconflow",
            name: "硅基流动 SiliconFlow",
            description: "SiliconFlow 托管开源模型接口",
            protocolType: .openaiCompatible,
            authMode: .apiKey,
            defaultBaseUrl: "https://api.siliconflow.cn/v1",
            defaultModel: "Qwen/Qwen2.5-7B-Instruct",
            defaultFastModel: "Qwen/Qwen2.5-7B-Instruct"
        ),
        AiProviderPreset(
            id: "bigmodel",
            name: "智谱 BigModel",
            description: "智谱 GLM 开放平台接口",
            protocolType: .openaiCompatible,
            authMode: .apiKey,
            defaultBaseUrl: "https://open.bigmodel.cn/api/paas/v4",
            defaultModel: "glm-4-flash",
            defaultFastModel: "glm-4-flash"
        ),
        AiProviderPreset(
            id: "openai",
            name: "OpenAI",
            description: "OpenAI 官方 API",
            protocolType: .openaiCompatible,
            authMode: .apiKey,
            defaultBaseUrl: "https://api.openai.com/v1",
            defaultModel: "gpt-4o-mini",
            defaultFastModel: "gpt-4o-mini",
            suggestedModels: ["gpt-4o-mini", "gpt-4o", "gpt-4.1-mini"]
        ),
        AiProviderPreset(
            id: "anthropic",
            name: "Anthropic Claude",
            description: "Anthropic Messages 官方 API",
            protocolType: .anthropicMessages,
            authMode: .apiKey,
            defaultBaseUrl: "https://api.anthropic.com",
            defaultModel: "claude-3-5-haiku-latest",
            defaultFastModel: "claude-3-5-haiku-latest",
            suggestedModels: ["claude-3-5-haiku-latest", "claude-3-7-sonnet-latest"]
        ),
        AiProviderPreset(
            id: "gemini",
            name: "Google Gemini",
            description: "Google AI Studio Gemini 官方 API",
            protocolType: .geminiGenerateContent,
            authMode: .apiKey,
            defaultBaseUrl: "https://generativelanguage.googleapis.com/v1beta",
            defaultModel: "gemini-2.5-flash",
            defaultFastModel: "gemini-2.5-flash",
            suggestedModels: ["gemini-2.5-flash", "gemini-2.5-pro"]
        ),
        AiProviderPreset(
            id: "custom",
            name: "自定义兼容接口",
            description: "支持任意 OpenAI / Anthropic / Gemini 兼容服务或私有网关",
            protocolType: .openaiCompatible,
            authMode: .apiKey,
            defaultBaseUrl: "",
            defaultModel: "",
            defaultFastModel: ""
        ),
    ]

    public let storage: IOSStorageManager
    private let session: URLSession

    public init(storage: IOSStorageManager, session: URLSession? = nil) {
        self.storage = storage
        if let session = session {
            self.session = session
        } else {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = 30
            cfg.timeoutIntervalForResource = 120
            cfg.httpShouldSetCookies = false
            self.session = URLSession(configuration: cfg)
        }
    }

    // MARK: - AI Lab Passcode Persistence

    @discardableResult
    public func saveLabPasscode(
        _ rawPasscode: String,
        publicKeyHex: String? = nil,
        targetPlatform: String = "ios",
        currentVersionCode: Int? = nil,
        now: Date = Date()
    ) throws -> AiLabPasscodeVerifyResult {
        let result = AiLabPasscodeVerifier.verify(
            rawPasscode,
            publicKeyHex: publicKeyHex,
            targetPlatform: targetPlatform,
            currentVersionCode: currentVersionCode,
            now: now
        )
        guard result.isValid else {
            throw MarcoError.invalidFormat(result.messageZh)
        }
        try storage.keychain.setData(Data(result.canonicalToken.utf8), forAccount: Self.labPasscodeKeychainKey)
        return result
    }

    public func verifyStoredLabPasscode(
        publicKeyHex: String? = nil,
        targetPlatform: String = "ios",
        currentVersionCode: Int? = nil,
        now: Date = Date()
    ) -> AiLabPasscodeVerifyResult {
        guard let data = try? storage.keychain.data(forAccount: Self.labPasscodeKeychainKey),
              let token = String(data: data, encoding: .utf8),
              !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return AiLabPasscodeVerifyResult(status: .empty, messageZh: "未设置 AI 观影实验室解锁口令")
        }
        return AiLabPasscodeVerifier.verify(
            token,
            publicKeyHex: publicKeyHex,
            targetPlatform: targetPlatform,
            currentVersionCode: currentVersionCode,
            now: now
        )
    }

    public func isLabUnlocked(publicKeyHex: String? = nil, now: Date = Date()) -> Bool {
        verifyStoredLabPasscode(publicKeyHex: publicKeyHex, now: now).isValid
    }

    public func clearLabPasscode() {
        try? storage.keychain.removeData(forAccount: Self.labPasscodeKeychainKey)
    }

    // MARK: - Safety, Redaction & JSON Utilities

    public static func isLoopbackBaseUrl(_ baseUrl: String) -> Bool {
        guard let url = URL(string: baseUrl.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), (scheme == "http" || scheme == "https"),
              let host = url.host?.lowercased()
        else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }

    /// Strict zero-URL output filter rejecting HTTP(S)/FTP/Magnet/ED2K/RTSP/www links from AI output.
    public static func containsForbiddenUrl(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        return forbiddenUrlRegex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
    }

    public static func extractJsonObjectSlice(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = trimmed.firstIndex(of: "{"),
              let end = trimmed.lastIndex(of: "}"),
              start < end
        else { return nil }
        return String(trimmed[start...end])
    }

    public static func desensitizeDiagnosticText(_ raw: String) -> String {
        var out = redactSecret(raw)
        let scrubPatterns: [(String, String)] = [
            (#"https?://[^\s"'<>]+"#, "[URL_REDACTED]"),
            (#"\b(?:\d{1,3}\.){3}\d{1,3}(?::\d+)?\b"#, "[IP_REDACTED]"),
            (#"(?:cookie|authorization)\s*[:=]\s*[^\r\n;]+"#, "[AUTH_REDACTED]"),
        ]
        for (pattern, repl) in scrubPatterns {
            if let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: repl)
            }
        }
        return String(out.prefix(600))
    }

    public static func redactSecret(_ input: String) -> String {
        guard !input.isEmpty else { return input }
        var out = input
        let patterns: [(String, String)] = [
            (#"\bsk-(?:or-v1-|ant-|proj-)?[A-Za-z0-9_\-]{8,}"#, "[REDACTED]"),
            (#"\bgh[pousr]_[A-Za-z0-9]{10,}"#, "[REDACTED]"),
            (#"\bAIza[0-9A-Za-z\-_]{16,}"#, "[REDACTED]"),
            (#"(Bearer\s+)[A-Za-z0-9\-._~+/]+=*"#, "$1[REDACTED]"),
            (#"((?:x-api-key|x-goog-api-key|api[_-]?key|access_token|token)\s*[:=]\s*)[^\s,;"}]+ "#, "$1[REDACTED] "),
        ]
        for (pattern, replacement) in patterns {
            if let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: replacement)
            }
        }
        return out
    }

    // MARK: - Core Completion & Multi-Protocol Adapters

    public func complete(
        systemPrompt: String,
        userPrompt: String,
        preferFastModel: Bool = false,
        isPrivateSpace: Bool = false
    ) async throws -> AiCompletionResult {
        guard !isPrivateSpace else {
            throw MarcoError.unsupported("隐私空间已自动禁用 AI 网络请求以保护隐私")
        }
        let config = storage.aiConfig()
        guard config.enabled else {
            throw MarcoError.unsupported("AI 助手尚未启用")
        }

        let activeProfile = storage.aiProfiles().first(where: { $0.id == config.activeProfileId })
        let baseUrl = (activeProfile?.baseUrl.isEmpty == false ? activeProfile!.baseUrl : config.baseUrl)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let proto = activeProfile?.protocolType ?? config.protocolType
        let authMode = activeProfile?.authMode ?? config.authMode
        let primaryModel = (activeProfile?.model.isEmpty == false ? activeProfile!.model : config.model)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fastModel = (activeProfile?.fastModel.isEmpty == false ? activeProfile!.fastModel : config.fastModel)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let model = (preferFastModel && !fastModel.isEmpty) ? fastModel : primaryModel

        guard !baseUrl.isEmpty, !model.isEmpty else {
            throw MarcoError.invalidFormat("请先在 AI 设置中填写接口地址与模型名称")
        }

        let requiresKey = authMode != .localNoAuth && !Self.isLoopbackBaseUrl(baseUrl)
        let secret = activeProfile != nil
            ? storage.aiSecret(forProfileId: activeProfile!.id)
            : storage.aiSecret()
        if requiresKey && secret.isEmpty {
            throw MarcoError.invalidFormat("请先填写对应 AI 服务的 API Key 或完成授权")
        }

        let monthKey = currentMonthKey()
        var usage = storage.aiUsage()
        if usage.monthKey != monthKey {
            usage = AiUsageSummary(monthKey: monthKey)
        }
        if config.monthlyTokenBudget > 0 && usage.totalTokens >= config.monthlyTokenBudget {
            throw MarcoError.unsupported("本月 AI Token 预算已用尽，可在设置中调整上限")
        }

        let result: AiCompletionResult
        switch proto {
        case .openaiCompatible:
            result = try await callOpenAi(
                baseUrl: baseUrl,
                model: model,
                apiKey: secret,
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                timeout: TimeInterval(config.timeoutSeconds)
            )
        case .anthropicMessages:
            result = try await callAnthropic(
                baseUrl: baseUrl,
                model: model,
                apiKey: secret,
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                timeout: TimeInterval(config.timeoutSeconds)
            )
        case .geminiGenerateContent:
            result = try await callGemini(
                baseUrl: baseUrl,
                model: model,
                apiKey: secret,
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                timeout: TimeInterval(config.timeoutSeconds)
            )
        }

        usage.promptTokens += result.promptTokens
        usage.completionTokens += result.completionTokens
        usage.requestCount += 1
        usage.updatedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
        storage.saveAiUsage(usage)
        return result
    }

    // MARK: - AI Lab High-Level Flows (Zero-URL + Privacy Gated)

    public func suggestSearchQueries(
        naturalLanguageQuery: String,
        isPrivateSpace: Bool = false
    ) async throws -> [AiSearchSuggestion] {
        let sys = "你是影视检索助手。根据用户的自然语言描述，返回 JSON 数组：[{\"title\":\"片名\",\"year\":\"年份\",\"reason\":\"简短推荐理由\",\"keywords\":[\"检索词\"]}]，仅输出纯 JSON，不要包含 Markdown 代码块或任何网址。"
        let completion = try await complete(
            systemPrompt: sys,
            userPrompt: naturalLanguageQuery,
            preferFastModel: true,
            isPrivateSpace: isPrivateSpace
        )
        if Self.containsForbiddenUrl(completion.text) {
            throw MarcoError.invalidFormat("AI 检索建议包含不安全链接，已拦截")
        }
        return Self.parseSearchSuggestionsJson(completion.text)
    }

    public static func parseSearchSuggestionsJson(_ raw: String) -> [AiSearchSuggestion] {
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = cleaned.firstIndex(of: "["), let end = cleaned.lastIndex(of: "]"), start < end {
            cleaned = String(cleaned[start...end])
        }
        guard let data = cleaned.data(using: .utf8),
              let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
        else { return [] }
        return arr.compactMap { item in
            let title = (item["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !title.isEmpty, !containsForbiddenUrl(title) else { return nil }
            let year = (item["year"] as? String) ?? (item["year"] as? NSNumber)?.stringValue ?? ""
            let reason = (item["reason"] as? String) ?? ""
            if containsForbiddenUrl(reason) { return nil }
            let keywords = ((item["keywords"] as? [String]) ?? [title]).filter { !containsForbiddenUrl($0) }
            return AiSearchSuggestion(title: title, year: year, reason: reason, keywords: keywords.isEmpty ? [title] : keywords)
        }
    }

    public func generateWatchBrief(
        title: String,
        year: String = "",
        area: String = "",
        actors: String = "",
        genreOrRemarks: String = "",
        overview: String = "",
        isPrivateSpace: Bool = false
    ) async throws -> AiWatchBriefResult {
        let sys = "你是专业影评导览员。严格基于公开信息生成零剧透观影导览，严禁泄露结局或输出任何网址。仅输出合法 JSON：{\"oneLineHook\":\"28字内吸引点\",\"highlights\":[\"看点1\",\"看点2\"],\"background\":[\"背景科普\"],\"viewingNote\":\"观赏建议\"}。"
        let user = "片名：《\(title)》\(year.isEmpty ? "" : " (\(year))")\n地区：\(area.isEmpty ? "未知" : area)\n类型：\(genreOrRemarks.isEmpty ? "未知" : genreOrRemarks)\n主演：\(actors.isEmpty ? "未知" : actors)\n简介：\(overview.isEmpty ? "暂无" : overview)"
        let res = try await complete(systemPrompt: sys, userPrompt: user, isPrivateSpace: isPrivateSpace)
        guard let slice = Self.extractJsonObjectSlice(res.text),
              let map = (try? JSONSerialization.jsonObject(with: Data(slice.utf8))) as? [String: Any]
        else {
            throw MarcoError.invalidFormat("未能解析看点导览内容")
        }
        let hook = (map["oneLineHook"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let highlights = (map["highlights"] as? [String]) ?? []
        let background = (map["background"] as? [String]) ?? (map["backgroundContext"] as? [String]) ?? []
        let tip = ((map["viewingNote"] ?? map["viewingTip"]) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let check = ([hook, tip] + highlights + background).joined(separator: " ")
        if Self.containsForbiddenUrl(check) {
            throw MarcoError.invalidFormat("看点导览包含不安全链接，已拦截")
        }
        return AiWatchBriefResult(
            oneLineHook: hook.isEmpty ? "《\(title)》零剧透观影导览" : hook,
            highlights: highlights,
            backgroundContext: background,
            viewingNote: tip
        )
    }

    public func generateEpisodeCompanion(
        title: String,
        year: String = "",
        currentEpisodeNumber: Int,
        seasonNumber: Int = 1,
        overview: String = "",
        includeCurrentEpisodePostWatch: Bool = false,
        isPrivateSpace: Bool = false
    ) async throws -> AiEpisodeCompanionResult {
        let safeEp = max(1, currentEpisodeNumber)
        let boundary = includeCurrentEpisodePostWatch
            ? "第 \(seasonNumber) 季 第 1 集 ～ 第 \(safeEp) 集（已看完本集）"
            : (safeEp <= 1
                ? "第 \(seasonNumber) 季开篇背景（第 1 集正片前零剧透导览）"
                : "第 \(seasonNumber) 季 第 1 集 ～ 第 \(safeEp - 1) 集（严禁剧透第 \(safeEp) 集及之后任何剧情）")
        let sys = "你是严守防剧透纪律的剧集导览助手。仅输出合法 JSON：{\"recap\":\"150字内前情提要\",\"characters\":[{\"name\":\"角色名\",\"role\":\"身份\",\"summary\":\"关系简述\"}],\"trivia\":\"80字内幕后看点\"}。严禁输出任何网址。"
        let user = "作品：《\(title)》\(year.isEmpty ? "" : " (\(year))")\n信息边界：\(boundary)\n简介：\(overview.isEmpty ? "无" : overview)"
        let res = try await complete(systemPrompt: sys, userPrompt: user, isPrivateSpace: isPrivateSpace)
        guard let slice = Self.extractJsonObjectSlice(res.text),
              let map = (try? JSONSerialization.jsonObject(with: Data(slice.utf8))) as? [String: Any]
        else {
            throw MarcoError.invalidFormat("未能解析前情提要内容")
        }
        let recap = (map["recap"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trivia = (map["trivia"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if Self.containsForbiddenUrl(recap) || Self.containsForbiddenUrl(trivia) {
            throw MarcoError.invalidFormat("前情提要包含不安全链接，已拦截")
        }
        var chars: [AiCharacterNote] = []
        if let rawChars = map["characters"] as? [[String: Any]] {
            for c in rawChars.prefix(8) {
                let name = (c["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let role = (c["role"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let summary = (c["summary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !name.isEmpty && !Self.containsForbiddenUrl(summary) {
                    chars.append(AiCharacterNote(name: name, factionOrRole: role, summary: summary))
                }
            }
        }
        return AiEpisodeCompanionResult(
            boundaryLabel: boundary,
            recap: recap.isEmpty ? "暂无前情提要记录。" : recap,
            characters: chars,
            trivia: trivia
        )
    }

    public func curateMoodWatchlist(
        recentHistoryTitles: [String],
        favoriteTitles: [String],
        availableCatalogTitles: [String] = [],
        moodPrompt: String = "",
        isPrivateSpace: Bool = false
    ) async throws -> AiMoodSommelierResult {
        let sys = "你是私人电影策展师。仅输出合法 JSON：{\"tastePortrait\":\"60字内口味画像\",\"picks\":[{\"title\":\"片名\",\"year\":\"年份\",\"moodTag\":\"氛围标签\",\"reason\":\"推荐理由\"}]}。严禁输出任何网址。"
        let effMood = moodPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "今晚想看一部契合我近期口味的高口碑佳作"
            : moodPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = "近期观看：\(recentHistoryTitles.prefix(15).joined(separator: "、"))\n收藏：\(favoriteTitles.prefix(15).joined(separator: "、"))\n需求：\(effMood)\n自有片库候选：\(availableCatalogTitles.prefix(60).joined(separator: "、"))"
        let res = try await complete(systemPrompt: sys, userPrompt: user, isPrivateSpace: isPrivateSpace)
        guard let slice = Self.extractJsonObjectSlice(res.text),
              let map = (try? JSONSerialization.jsonObject(with: Data(slice.utf8))) as? [String: Any]
        else {
            throw MarcoError.invalidFormat("未能解析私人影单策展结果")
        }
        let portrait = (map["tastePortrait"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if Self.containsForbiddenUrl(portrait) {
            throw MarcoError.invalidFormat("输出包含不安全链接，已拦截")
        }
        var picks: [AiCuratedPick] = []
        if let arr = map["picks"] as? [[String: Any]] {
            for item in arr.prefix(6) {
                let t = (item["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let y = (item["year"] as? String) ?? (item["year"] as? NSNumber)?.stringValue ?? ""
                let tag = (item["moodTag"] as? String) ?? ""
                let reason = (item["reason"] as? String) ?? ""
                guard !t.isEmpty, !Self.containsForbiddenUrl(t), !Self.containsForbiddenUrl(reason) else { continue }
                picks.append(AiCuratedPick(title: t, year: y, moodTag: tag, reason: reason))
            }
        }
        return AiMoodSommelierResult(
            tastePortrait: portrait.isEmpty ? "偏爱叙事细腻、氛围沉浸的口碑佳作。" : portrait,
            picks: picks
        )
    }

    public func diagnosePlaybackIssue(
        rawErrorText: String,
        engineName: String,
        mediaFormatHint: String = "",
        hasBackupLines: Bool = false,
        isPrivateSpace: Bool = false
    ) async throws -> AiDiagnosticReport {
        let safeError = Self.desensitizeDiagnosticText(rawErrorText)
        let safeFormat = mediaFormatHint.isEmpty ? "未知" : Self.desensitizeDiagnosticText(mediaFormatHint)
        let sys = "你是 iOS 影音播放器排障专家。仅输出 JSON：{\"rootCause\":\"一句话根因\",\"steps\":[\"建议1\",\"建议2\"],\"actions\":[\"switch_to_mpv\",\"switch_to_avplayer\",\"enable_vocal_loudness\",\"switch_backup_line\",\"open_episode_scrape\"]}。严禁输出任何网址。"
        let user = "当前内核：\(engineName)\n格式提示：\(safeFormat)\n有备用线路：\(hasBackupLines ? "是" : "否")\n脱敏错误：\(safeError)"
        let res = try await complete(systemPrompt: sys, userPrompt: user, preferFastModel: true, isPrivateSpace: isPrivateSpace)
        guard let slice = Self.extractJsonObjectSlice(res.text),
              let map = (try? JSONSerialization.jsonObject(with: Data(slice.utf8))) as? [String: Any]
        else {
            throw MarcoError.invalidFormat("未能解析排障报告")
        }
        let rootCause = (map["rootCause"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "流媒体连接或编码兼容性异常"
        if Self.containsForbiddenUrl(rootCause) {
            throw MarcoError.invalidFormat("排障结果包含不安全链接，已拦截")
        }
        let steps = ((map["steps"] as? [String]) ?? []).filter { !$0.isEmpty && !Self.containsForbiddenUrl($0) }
        let allowedActions: Set<String> = [
            "switch_to_mpv", "switch_to_avplayer", "enable_vocal_loudness", "switch_backup_line", "open_episode_scrape",
        ]
        let actions = ((map["actions"] as? [String]) ?? []).filter { allowedActions.contains($0) }
        return AiDiagnosticReport(
            rootCauseZh: rootCause,
            stepsZh: steps.isEmpty ? ["建议尝试切换播放内核或备用线路后重试。"] : steps,
            suggestedActions: actions
        )
    }

    public func curateMessyEpisodes(
        rawSeriesTitle: String,
        year: String = "",
        episodes: [CmsEpisode],
        isPrivateSpace: Bool = false
    ) async throws -> AiEpisodeCuratePlan {
        let sample = episodes.prefix(60).enumerated().map { ["idx": $0.offset, "name": $0.element.name] }
        let sampleJson = (try? JSONSerialization.data(withJSONObject: sample)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
        let sys = "你是影视媒体库整理专家。仅输出 JSON：{\"canonicalTitle\":\"标准剧名\",\"seasonNumber\":1,\"episodeOffset\":0,\"specialIndices\":[],\"summary\":\"整理说明\"}。严禁输出任何网址。"
        let user = "原始标题：\(rawSeriesTitle) \(year.isEmpty ? "" : "(\(year))")\n样本：\(sampleJson)"
        let res = try await complete(systemPrompt: sys, userPrompt: user, preferFastModel: true, isPrivateSpace: isPrivateSpace)
        guard let slice = Self.extractJsonObjectSlice(res.text),
              let map = (try? JSONSerialization.jsonObject(with: Data(slice.utf8))) as? [String: Any]
        else {
            throw MarcoError.invalidFormat("未能解析剧集智能编排结果")
        }
        let canonical = (map["canonicalTitle"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let summary = (map["summary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "已完成标准剧名与集序校准"
        if Self.containsForbiddenUrl(canonical) || Self.containsForbiddenUrl(summary) {
            throw MarcoError.invalidFormat("剧集编排结果包含不安全链接，已拦截")
        }
        let season = min(max((map["seasonNumber"] as? NSNumber)?.intValue ?? 1, 1), 99)
        let offset = min(max((map["episodeOffset"] as? NSNumber)?.intValue ?? 0, -500), 500)
        let specials = ((map["specialIndices"] as? [NSNumber]) ?? []).map(\.intValue).filter { $0 >= 0 && $0 < episodes.count }
        return AiEpisodeCuratePlan(
            canonicalTitle: canonical.isEmpty ? rawSeriesTitle : canonical,
            seasonNumber: season,
            episodeOffset: offset,
            specialIndices: specials,
            summaryZh: summary
        )
    }

    // MARK: - Wire Protocol Adapters

    private func callOpenAi(
        baseUrl: String,
        model: String,
        apiKey: String,
        systemPrompt: String,
        userPrompt: String,
        timeout: TimeInterval
    ) async throws -> AiCompletionResult {
        let cleanBase = baseUrl.hasSuffix("/") ? String(baseUrl.dropLast()) : baseUrl
        let endpoint = cleanBase.lowercased().hasSuffix("/chat/completions") ? cleanBase : "\(cleanBase)/chat/completions"
        guard let url = URL(string: endpoint) else { throw MarcoError.invalidFormat("AI 接口地址格式无效") }

        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        let body: [String: Any] = [
            "model": model,
            "temperature": 0.3,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt],
            ],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await session.marcoData(for: req)
        try validateHttpStatus(resp, data: data)

        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let msg = choices.first?["message"] as? [String: Any],
              let content = msg["content"] as? String
        else {
            throw MarcoError.invalidFormat("AI 返回的数据格式无法解析")
        }
        let usageMap = obj["usage"] as? [String: Any]
        return AiCompletionResult(
            text: content.trimmingCharacters(in: .whitespacesAndNewlines),
            promptTokens: (usageMap?["prompt_tokens"] as? NSNumber)?.intValue ?? 0,
            completionTokens: (usageMap?["completion_tokens"] as? NSNumber)?.intValue ?? 0
        )
    }

    private func callAnthropic(
        baseUrl: String,
        model: String,
        apiKey: String,
        systemPrompt: String,
        userPrompt: String,
        timeout: TimeInterval
    ) async throws -> AiCompletionResult {
        let cleanBase = baseUrl.hasSuffix("/") ? String(baseUrl.dropLast()) : baseUrl
        let endpoint = cleanBase.lowercased().hasSuffix("/messages") ? cleanBase : "\(cleanBase)/v1/messages"
        guard let url = URL(string: endpoint) else { throw MarcoError.invalidFormat("Anthropic 接口地址无效") }

        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        if !apiKey.isEmpty { req.setValue(apiKey, forHTTPHeaderField: "x-api-key") }
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1024,
            "system": systemPrompt,
            "messages": [["role": "user", "content": userPrompt]],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await session.marcoData(for: req)
        try validateHttpStatus(resp, data: data)

        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let contentArr = obj["content"] as? [[String: Any]]
        else {
            throw MarcoError.invalidFormat("Anthropic 响应格式无法解析")
        }
        let text = contentArr.compactMap { $0["text"] as? String }.joined(separator: "\n")
        let usageMap = obj["usage"] as? [String: Any]
        return AiCompletionResult(
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            promptTokens: (usageMap?["input_tokens"] as? NSNumber)?.intValue ?? 0,
            completionTokens: (usageMap?["output_tokens"] as? NSNumber)?.intValue ?? 0
        )
    }

    private func callGemini(
        baseUrl: String,
        model: String,
        apiKey: String,
        systemPrompt: String,
        userPrompt: String,
        timeout: TimeInterval
    ) async throws -> AiCompletionResult {
        let cleanBase = baseUrl.hasSuffix("/") ? String(baseUrl.dropLast()) : baseUrl
        let endpoint = "\(cleanBase)/models/\(model):generateContent"
        guard let url = URL(string: endpoint) else { throw MarcoError.invalidFormat("Gemini 接口地址无效") }

        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty { req.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key") }
        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": systemPrompt]]],
            "contents": [["role": "user", "parts": [["text": userPrompt]]]],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await session.marcoData(for: req)
        try validateHttpStatus(resp, data: data)

        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let candidates = obj["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]]
        else {
            throw MarcoError.invalidFormat("Gemini 响应格式无法解析")
        }
        let text = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
        let usage = obj["usageMetadata"] as? [String: Any]
        return AiCompletionResult(
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            promptTokens: (usage?["promptTokenCount"] as? NSNumber)?.intValue ?? 0,
            completionTokens: (usage?["candidatesTokenCount"] as? NSNumber)?.intValue ?? 0
        )
    }

    private func validateHttpStatus(_ resp: URLResponse, data: Data) throws {
        guard let http = resp as? HTTPURLResponse else { return }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw MarcoError.networkFailure("AI 服务鉴权失败（HTTP \(http.statusCode)），请检查 API Key 或授权状态")
        }
        if http.statusCode == 429 {
            throw MarcoError.networkFailure("AI 服务请求过于频繁（HTTP 429），请稍后重试")
        }
        guard (200...299).contains(http.statusCode) else {
            let detail = Self.redactSecret(String(decoding: data.prefix(256), as: UTF8.self))
            throw MarcoError.networkFailure("AI 接口异常（HTTP \(http.statusCode)）：\(detail)")
        }
    }

    private func currentMonthKey() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM"
        return formatter.string(from: Date())
    }
}

// MARK: - AI Online Danmaku Matcher

public struct AiDanmuQueryPlan: Equatable, Hashable, Sendable {
    public let canonicalTitle: String
    public let altTitles: [String]
    public let seasonNumber: Int?
    public let episodeNumber: Int
    public let year: String
    public let isMovie: Bool
    public let usedAi: Bool

    public init(
        canonicalTitle: String,
        altTitles: [String] = [],
        seasonNumber: Int? = nil,
        episodeNumber: Int = 1,
        year: String = "",
        isMovie: Bool = false,
        usedAi: Bool = false
    ) {
        self.canonicalTitle = canonicalTitle
        self.altTitles = altTitles
        self.seasonNumber = seasonNumber
        self.episodeNumber = max(1, episodeNumber)
        self.year = year
        self.isMovie = isMovie
        self.usedAi = usedAi
    }
}

public struct AiOnlineDanmuCandidate: Equatable, Hashable, Identifiable, Sendable {
    public var id: String { "\(sourceKey)|\(fetchKind)|\(fetchTarget)" }
    public let sourceKey: String
    public let sourceLabel: String
    public let workTitle: String
    public let episodeTitle: String
    public let episodeNumber: Int
    public let confidence: Double
    public let fetchKind: String
    public let fetchTarget: String
    public let origin: String

    public init(
        sourceKey: String,
        sourceLabel: String,
        workTitle: String,
        episodeTitle: String,
        episodeNumber: Int,
        confidence: Double,
        fetchKind: String,
        fetchTarget: String,
        origin: String
    ) {
        self.sourceKey = sourceKey
        self.sourceLabel = sourceLabel
        self.workTitle = workTitle
        self.episodeTitle = episodeTitle
        self.episodeNumber = episodeNumber
        self.confidence = confidence
        self.fetchKind = fetchKind
        self.fetchTarget = fetchTarget
        self.origin = origin
    }
}

/// AI-assisted online danmaku matcher supporting AI query extraction, Bilibili PGC + user-configured
/// DandanPlay origins (zero hardcoded third-party danmaku servers), and RFC 1951 raw-deflate / gzip XML decoding.
public final class AiDanmuMatcher: @unchecked Sendable {
    private let aiService: AiService
    private let danmuService: DanmuService
    private let session: URLSession

    public init(
        aiService: AiService,
        danmuService: DanmuService = DanmuService(),
        session: URLSession? = nil
    ) {
        self.aiService = aiService
        self.danmuService = danmuService
        if let session = session {
            self.session = session
        } else {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = 8
            cfg.timeoutIntervalForResource = 15
            cfg.httpShouldSetCookies = false
            self.session = URLSession(configuration: cfg)
        }
    }

    /// Decodes Bilibili `list.so` danmaku XML bytes (plain UTF-8, UTF-8 BOM, GZIP, ZLIB, or raw RFC 1951 deflate).
    public static func decodeBilibiliDanmuXml(_ data: Data) -> String {
        guard !data.isEmpty else { return "" }
        let bytes = [UInt8](data)
        if bytes[0] == 0x3C {
            return String(decoding: data, as: UTF8.self)
        }
        if bytes.count >= 4 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF && bytes[3] == 0x3C {
            return String(decoding: data.dropFirst(3), as: UTF8.self)
        }
        let gunzipped = ConfigDecoder.gunzipIfNeeded(data)
        if gunzipped != data {
            return String(decoding: gunzipped, as: UTF8.self)
        }
        if let deflated = ConfigDecoder.decompressDeflate(data) {
            return String(decoding: deflated, as: UTF8.self)
        }
        return String(decoding: data, as: UTF8.self)
    }

    public func extractQueryPlan(
        rawTitle: String,
        rawEpisodeName: String = "",
        fallbackEpisodeIndex: Int = 1,
        year: String = "",
        durationSec: Int = 0,
        manualKeywordOverride: String = "",
        manualEpisodeOverride: Int? = nil,
        isPrivateSpace: Bool = false
    ) async throws -> AiDanmuQueryPlan {
        guard !isPrivateSpace else {
            throw MarcoError.unsupported("隐私空间已硬性禁用外部弹幕搜索与 AI 请求")
        }

        let badges = EpisodeScraperService.parseEpisodeBadges(name: rawEpisodeName)
        let localTitle = EpisodeScraperService.cleanSeriesTitle(rawTitle)
        let baselineTitle = localTitle.isEmpty ? rawTitle.trimmingCharacters(in: .whitespacesAndNewlines) : localTitle
        let localEp = manualEpisodeOverride ?? badges.episodeNumber ?? max(1, fallbackEpisodeIndex)
        let localSeason = badges.seasonNumber
        let manualKw = manualKeywordOverride.trimmingCharacters(in: .whitespacesAndNewlines)

        let cfg = aiService.storage.aiConfig()
        guard cfg.enabled && cfg.danmuMatchEnabled else {
            return AiDanmuQueryPlan(
                canonicalTitle: manualKw.isEmpty ? baselineTitle : manualKw,
                altTitles: [],
                seasonNumber: localSeason,
                episodeNumber: localEp,
                year: year,
                isMovie: durationSec >= 3900 && localEp <= 1,
                usedAi: false
            )
        }

        do {
            let promptTitle = manualKw.isEmpty ? rawTitle.trimmingCharacters(in: .whitespacesAndNewlines) : manualKw
            let res = try await aiService.complete(
                systemPrompt: "你是影视作品与弹幕搜索关键词提炼助手。仅输出合法 JSON：{\"title\":\"标准中文主片名\",\"alt_titles\":[\"别名\"],\"season\":1,\"episode\":1,\"year\":\"2024\",\"is_movie\":false}。严禁输出任何网址。",
                userPrompt: "原始片名：\(promptTitle)\n分集名：\(rawEpisodeName)\n识别集号：\(localEp)\n年份：\(year)\n时长秒：\(durationSec)",
                preferFastModel: true,
                isPrivateSpace: isPrivateSpace
            )
            if let slice = AiService.extractJsonObjectSlice(res.text),
               !AiService.containsForbiddenUrl(slice),
               let obj = (try? JSONSerialization.jsonObject(with: Data(slice.utf8))) as? [String: Any]
            {
                let parsedTitle = (obj["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let alts = ((obj["alt_titles"] as? [String]) ?? [])
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty && $0 != parsedTitle && !AiService.containsForbiddenUrl($0) }
                let aiSeason = (obj["season"] as? NSNumber)?.intValue
                let aiEp = manualEpisodeOverride ?? ((obj["episode"] as? NSNumber)?.intValue ?? localEp)
                let aiYear = (obj["year"] as? String) ?? year
                let isMovie = (obj["is_movie"] as? Bool) ?? false
                return AiDanmuQueryPlan(
                    canonicalTitle: parsedTitle.isEmpty ? baselineTitle : parsedTitle,
                    altTitles: Array(alts.prefix(3)),
                    seasonNumber: aiSeason ?? localSeason,
                    episodeNumber: max(1, aiEp),
                    year: aiYear,
                    isMovie: isMovie,
                    usedAi: !parsedTitle.isEmpty
                )
            }
        } catch let err as MarcoError {
            if case .unsupported = err { throw err }
        } catch {}

        return AiDanmuQueryPlan(
            canonicalTitle: manualKw.isEmpty ? baselineTitle : manualKw,
            altTitles: [],
            seasonNumber: localSeason,
            episodeNumber: localEp,
            year: year,
            isMovie: durationSec >= 3900 && localEp <= 1,
            usedAi: false
        )
    }

    public func searchCandidates(
        plan: AiDanmuQueryPlan,
        danmuSettings: DanmuSettings,
        isPrivateSpace: Bool = false
    ) async throws -> [AiOnlineDanmuCandidate] {
        guard !isPrivateSpace else {
            throw MarcoError.unsupported("隐私空间已硬性禁用外部弹幕搜索与 AI 请求")
        }
        guard !plan.canonicalTitle.isEmpty else { return [] }

        var results: [AiOnlineDanmuCandidate] = []

        // 1. User-configured DandanPlay-compatible origins
        if let customMatches = try? await danmuService.searchEpisodes(
            title: plan.canonicalTitle,
            episodeIndex: plan.episodeNumber,
            settings: danmuSettings
        ) {
            for m in customMatches {
                results.append(
                    AiOnlineDanmuCandidate(
                        sourceKey: "custom_origin",
                        sourceLabel: "自定弹幕源",
                        workTitle: m.animeTitle,
                        episodeTitle: m.episodeTitle,
                        episodeNumber: plan.episodeNumber,
                        confidence: m.confidence,
                        fetchKind: "dandan_ep",
                        fetchTarget: m.episodeId,
                        origin: m.sourceOrigin
                    )
                )
            }
        }

        // 2. Public Bilibili PGC (`api.bilibili.com`)
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#/")
        let q = plan.canonicalTitle.addingPercentEncoding(withAllowedCharacters: allowed) ?? plan.canonicalTitle
        for stype in ["media_bangumi", "media_ft"] {
            guard let url = URL(string: "https://api.bilibili.com/x/web-interface/search/type?search_type=\(stype)&keyword=\(q)") else {
                continue
            }
            var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 6)
            req.httpMethod = "GET"
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
            guard let (data, resp) = try? await session.marcoData(for: req),
                  let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let dataMap = root["data"] as? [String: Any],
                  let list = dataMap["result"] as? [[String: Any]]
            else { continue }

            for item in list.prefix(4) {
                let rawTitle = ((item["title"] as? String) ?? "").replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                let eps = (item["eps"] as? [[String: Any]]) ?? []
                for (idx, ep) in eps.enumerated() {
                    let cid = (ep["cid"] as? NSNumber)?.stringValue ?? (ep["id"] as? NSNumber)?.stringValue ?? ""
                    guard !cid.isEmpty else { continue }
                    let epNum = idx + 1
                    let score = epNum == plan.episodeNumber ? 0.92 : 0.55
                    let epTitle = (ep["long_title"] as? String) ?? (ep["title"] as? String) ?? "第 \(epNum) 集"
                    results.append(
                        AiOnlineDanmuCandidate(
                            sourceKey: "bilibili_pgc",
                            sourceLabel: stype == "media_bangumi" ? "哔哩哔哩番剧" : "哔哩哔哩影视",
                            workTitle: rawTitle,
                            episodeTitle: epTitle,
                            episodeNumber: epNum,
                            confidence: score,
                            fetchKind: "bilibili_cid",
                            fetchTarget: cid,
                            origin: "https://api.bilibili.com"
                        )
                    )
                }
            }
        }

        return results.sorted { $0.confidence > $1.confidence }
    }

    public func fetchCandidateComments(
        _ candidate: AiOnlineDanmuCandidate,
        danmuSettings: DanmuSettings = DanmuSettings(),
        isPrivateSpace: Bool = false
    ) async throws -> [DanmuComment] {
        guard !isPrivateSpace else {
            throw MarcoError.unsupported("隐私空间已硬性禁用外部弹幕搜索与 AI 请求")
        }
        if candidate.fetchKind == "bilibili_cid" {
            guard let url = URL(string: "https://api.bilibili.com/x/v1/dm/list.so?oid=\(candidate.fetchTarget)") else {
                return []
            }
            var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
            req.httpMethod = "GET"
            req.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
            let (data, resp) = try await session.marcoData(for: req)
            if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw MarcoError.networkFailure("在线弹幕拉取失败 (HTTP \(http.statusCode))")
            }
            let xml = Self.decodeBilibiliDanmuXml(data)
            return try DanmuService.parseCommentsPayload(Data(xml.utf8), settings: danmuSettings)
        }
        return try await danmuService.fetchComments(
            origin: candidate.origin,
            episodeId: candidate.fetchTarget,
            settings: danmuSettings
        )
    }
}
