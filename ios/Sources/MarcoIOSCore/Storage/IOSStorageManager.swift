// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only

import CryptoKit
import Foundation
import Security

public protocol KeychainStoreProtocol: Sendable {
    func setData(_ data: Data, forAccount account: String) throws
    func data(forAccount account: String) throws -> Data?
    func removeData(forAccount account: String) throws
}

/// System Keychain store backed by Apple Security (`kSecClassGenericPassword`).
public final class SystemKeychainStore: KeychainStoreProtocol {
    public let service: String

    public init(service: String = "com.pilipala.marcomovie") {
        self.service = service
    }

    public func setData(_ data: Data, forAccount account: String) throws {
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributesToUpdate: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributesToUpdate as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        if updateStatus == errSecItemNotFound {
            var insertQuery = baseQuery
            for (k, v) in attributesToUpdate { insertQuery[k] = v }
            let addStatus = SecItemAdd(insertQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw MarcoError.storageError("Keychain write failed (\(addStatus))")
            }
            return
        }
        throw MarcoError.storageError("Keychain update failed (\(updateStatus))")
    }

    public func data(forAccount account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw MarcoError.storageError("Keychain read failed (\(status))")
        }
        return result as? Data
    }

    public func removeData(forAccount account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw MarcoError.storageError("Keychain delete failed (\(status))")
        }
    }
}

/// Deterministic in-memory Keychain double for isolated CI and unit tests.
public final class InMemoryKeychainStore: KeychainStoreProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [String: Data] = [:]

    public init(initial: [String: Data] = [:]) {
        self.records = initial
    }

    public func setData(_ data: Data, forAccount account: String) throws {
        lock.lock()
        records[account] = data
        lock.unlock()
    }

    public func data(forAccount account: String) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return records[account]
    }

    public func removeData(forAccount account: String) throws {
        lock.lock()
        records.removeValue(forKey: account)
        lock.unlock()
    }

    public func allAccounts() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return Array(records.keys).sorted()
    }
}

/// Lossless `marco-movie-backup` (`MarcoMovie-1`) serializer interoperable with Android, Flutter, and tvOS.
public enum BackupCodec {
    public static let keySubscriptions = "saved_subscriptions"
    public static let keyWatchHistory = "watch_history"
    public static let keyFavorites = "favorites"
    public static let keySearchHistory = "global_search_history"
    public static let keySkipIntroSec = "skip_intro_sec"
    public static let keySkipOutroSec = "skip_outro_sec"
    public static let keyPlaySpeed = "play_speed"
    public static let keyAutoNext = "auto_next"
    public static let keyEpisodesDescending = "episodes_descending"
    public static let keyRepeatMode = "repeat_mode"
    public static let keySelectedSite = "selected_site"
    public static let keyPreferredSite = "preferred_site"
    public static let keyNetdiskQuality = "netdisk_quality"
    public static let keyPlayerKernel = "player_kernel"
    public static let keyAmbientTheme = "ambient_theme"
    public static let keyAmbientIntensity = "ambient_intensity"
    public static let keyAmbientPosterSync = "ambient_poster_sync"

    public static func encodeBackupJson(_ payload: BackupPayload) throws -> String {
        let publicSubs = payload.subscriptions.compactMap { $0.sanitizedForPublicExport() }
        let privateSubs = payload.subscriptions.filter { $0.isEffectivelyPrivate }
        let privateConfig = IOSStorageManager.buildOwnershipConfig(
            from: payload.subscriptions,
            knownPrivateSubscriptionIds: Set(privateSubs.map(\.id)),
            knownPrivateSiteKeys: [],
            ambiguousLegacyRawKeys: []
        )
        let safeWatchHistory = payload.watchHistory.filter { !privateConfig.isPrivateSiteKey($0.site) }
        let safeFavorites = payload.favorites.filter { !privateConfig.isPrivateSiteKey($0.site) }
        let safeSelectedSite = privateConfig.isPrivateSiteKey(payload.preferences.selectedSiteKey)
            ? ""
            : payload.preferences.selectedSiteKey
        let safePreferredSite = privateConfig.isPrivateSiteKey(payload.preferences.preferredSiteKey)
            ? ""
            : payload.preferences.preferredSiteKey

        let rawPrimary = !payload.rawConfig.isEmpty ? payload.rawConfig : (publicSubs.first?.rawContent ?? "")
        let primaryRawConfig = CmsParser.sanitizePublicRawConfig(rawPrimary)
        let primaryOrigin: String = {
            if !rawPrimary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && primaryRawConfig.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                return publicSubs.first?.url ?? ""
            }
            return !payload.origin.isEmpty ? payload.origin : (publicSubs.first?.url ?? "")
        }()

        let configField: Any = {
            let trimmed = primaryRawConfig.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return NSNull() }
            let cleaned = ConfigDecoder.stripJsonComments(ConfigDecoder.unpackConfigText(trimmed))
            if let jsonObj = try? JSONSerialization.jsonObject(with: Data(cleaned.utf8)) {
                return jsonObj
            }
            return trimmed
        }()

        let histJson = try stringifyJsonArray(safeWatchHistory.map { $0.toDictionary() })
        let favJson = try stringifyJsonArray(safeFavorites.map { $0.toDictionary() })
        let searchJson = try stringifyJsonArray(payload.searchHistory)

        var settings: [String: Any] = [
            keyWatchHistory: histJson,
            keyFavorites: favJson,
            keySearchHistory: searchJson,
            keySkipIntroSec: payload.preferences.skipIntroSec,
            keySkipOutroSec: payload.preferences.skipOutroSec,
            keyPlaySpeed: payload.preferences.playSpeed,
            keyAutoNext: payload.preferences.autoNext,
            keyEpisodesDescending: payload.preferences.episodesDescending,
            keyRepeatMode: payload.preferences.repeatMode,
            keySelectedSite: safeSelectedSite,
            keyPreferredSite: safePreferredSite,
            keyNetdiskQuality: payload.preferences.netdiskQuality,
            keyPlayerKernel: payload.preferences.playerKernel,
            keyAmbientTheme: payload.preferences.ambientTheme,
            keyAmbientIntensity: payload.preferences.ambientIntensity,
            keyAmbientPosterSync: payload.preferences.ambientPosterSync,
        ]
        if !publicSubs.isEmpty {
            settings[keySubscriptions] = publicSubs.map { $0.toDictionary() }
        }

        let root: [String: Any] = [
            "format": BackupPayload.backupFormat,
            "schema": BackupPayload.backupSchema,
            "version": BackupPayload.currentVersion,
            "exportedAt": payload.exportedAt,
            "origin": primaryOrigin,
            "config": configField,
            "settings": settings,
        ]
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    public static func isBackupPayload(_ rawText: String) -> Bool {
        let cleaned = ConfigDecoder.stripJsonComments(rawText)
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(cleaned.utf8))) as? [String: Any] else {
            return false
        }
        return (obj["format"] as? String) == BackupPayload.backupFormat
            || (obj["schema"] as? String) == BackupPayload.backupSchema
    }

    public static func decodeBackupJson(_ rawBackup: String) throws -> BackupPayload {
        let cleaned = ConfigDecoder.stripJsonComments(rawBackup)
        guard let decoded = (try? JSONSerialization.jsonObject(with: Data(cleaned.utf8))) as? [String: Any] else {
            throw MarcoError.invalidFormat("不是有效的 Marco Movie 备份文件")
        }
        let fmt = (decoded["format"] as? String) ?? ""
        let sch = (decoded["schema"] as? String) ?? ""
        guard fmt == BackupPayload.backupFormat || sch == BackupPayload.backupSchema else {
            throw MarcoError.invalidFormat("不是有效的 Marco Movie 备份文件")
        }

        let origin = ((decoded["origin"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let exportedAt = (decoded["exportedAt"] as? NSNumber)?.int64Value ?? Int64(Date().timeIntervalSince1970 * 1000)

        let rawConfigText: String
        if let rawField = decoded["config"], !(rawField is NSNull) {
            if let s = rawField as? String {
                rawConfigText = s.trimmingCharacters(in: .whitespacesAndNewlines)
            } else if JSONSerialization.isValidJSONObject(rawField),
                      let d = try? JSONSerialization.data(withJSONObject: rawField)
            {
                rawConfigText = String(decoding: d, as: UTF8.self)
            } else {
                throw MarcoError.invalidFormat("备份中的配置字段格式无效")
            }
        } else {
            rawConfigText = ""
        }

        if !rawConfigText.isEmpty {
            _ = try CmsParser.parseConfig(rawConfigText, origin: origin)
        }

        let settings = (decoded["settings"] as? [String: Any]) ?? [:]
        let watchHistory = try parseRecordList(settings[keyWatchHistory]).map { dict -> WatchHistoryItem in
            try validateMediaRecord(dict)
            return WatchHistoryItem.fromDictionary(dict)
        }
        let favorites = try parseRecordList(settings[keyFavorites]).map { dict -> FavoriteItem in
            try validateMediaRecord(dict)
            return FavoriteItem.fromDictionary(dict)
        }
        let searchHistory = try parseStringList(settings[keySearchHistory])

        var subscriptions: [SubscriptionEntry] = []
        if let rawSubs = settings[keySubscriptions], !(rawSubs is NSNull) {
            guard let subArr = rawSubs as? [Any] else {
                throw MarcoError.invalidFormat("订阅列表格式无效")
            }
            var seenIds = Set<String>()
            for item in subArr {
                guard let map = item as? [String: Any] else {
                    throw MarcoError.invalidFormat("订阅条目格式无效")
                }
                let sub = SubscriptionEntry.fromDictionary(map)
                if sub.id.isEmpty || !seenIds.insert(sub.id).inserted || sub.isEffectivelyPrivate || sub.rawContent.isEmpty {
                    throw MarcoError.invalidFormat("常规备份包含无效订阅")
                }
                _ = try CmsParser.parseConfig(sub.rawContent, origin: sub.url)
                subscriptions.append(sub)
            }
        } else if !rawConfigText.isEmpty {
            let parsed = try CmsParser.parseConfig(rawConfigText, origin: origin)
            subscriptions.append(
                SubscriptionEntry(
                    id: "restored_primary",
                    name: "已恢复的订阅",
                    url: origin,
                    rawContent: rawConfigText,
                    siteCount: parsed.sites.count,
                    liveCount: parsed.lives.count,
                    updatedAt: exportedAt,
                    depots: parsed.depots
                )
            )
        }

        let prefs = PlaybackPreferences(
            skipIntroSec: (settings[keySkipIntroSec] as? NSNumber)?.intValue ?? 0,
            skipOutroSec: (settings[keySkipOutroSec] as? NSNumber)?.intValue ?? 0,
            playSpeed: (settings[keyPlaySpeed] as? NSNumber)?.doubleValue ?? 1.0,
            autoNext: (settings[keyAutoNext] as? Bool) ?? true,
            episodesDescending: (settings[keyEpisodesDescending] as? Bool) ?? false,
            repeatMode: (settings[keyRepeatMode] as? String) ?? "off",
            selectedSiteKey: (settings[keySelectedSite] as? String) ?? "",
            preferredSiteKey: (settings[keyPreferredSite] as? String) ?? "",
            netdiskQuality: (settings[keyNetdiskQuality] as? String) ?? "auto",
            playerKernel: (settings[keyPlayerKernel] as? String) ?? "range_proxy",
            ambientTheme: (settings[keyAmbientTheme] as? String) ?? "aurora",
            ambientIntensity: (settings[keyAmbientIntensity] as? String) ?? "standard",
            ambientPosterSync: (settings[keyAmbientPosterSync] as? Bool) ?? true
        )

        return BackupPayload(
            format: fmt.isEmpty ? BackupPayload.backupFormat : fmt,
            schema: sch.isEmpty ? BackupPayload.backupSchema : sch,
            version: (decoded["version"] as? NSNumber)?.intValue ?? BackupPayload.currentVersion,
            exportedAt: exportedAt,
            origin: origin,
            rawConfig: rawConfigText,
            subscriptions: subscriptions,
            watchHistory: watchHistory,
            favorites: favorites,
            searchHistory: searchHistory,
            preferences: prefs
        )
    }

    private static func stringifyJsonArray(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value)
        return String(decoding: data, as: UTF8.self)
    }

    private static func parseRecordList(_ raw: Any?) throws -> [[String: Any]] {
        guard let raw = raw, !(raw is NSNull) else { return [] }
        let decoded: Any
        if let s = raw as? String {
            guard let parsed = try? JSONSerialization.jsonObject(with: Data(s.utf8)) else {
                throw MarcoError.invalidFormat("备份记录 JSON 格式无效")
            }
            decoded = parsed
        } else {
            decoded = raw
        }
        guard let list = decoded as? [Any] else {
            throw MarcoError.invalidFormat("备份记录必须是列表")
        }
        return try list.map { elem in
            guard let dict = elem as? [String: Any] else {
                throw MarcoError.invalidFormat("备份记录条目格式无效")
            }
            return dict
        }
    }

    private static func parseStringList(_ raw: Any?) throws -> [String] {
        guard let raw = raw, !(raw is NSNull) else { return [] }
        let decoded: Any
        if let s = raw as? String {
            guard let parsed = try? JSONSerialization.jsonObject(with: Data(s.utf8)) else {
                throw MarcoError.invalidFormat("搜索记录 JSON 格式无效")
            }
            decoded = parsed
        } else {
            decoded = raw
        }
        guard let list = decoded as? [Any] else {
            throw MarcoError.invalidFormat("搜索记录必须是列表")
        }
        return try list.map { elem in
            guard let str = elem as? String else {
                throw MarcoError.invalidFormat("搜索记录格式无效")
            }
            return str
        }
    }

    private static func validateMediaRecord(_ dict: [String: Any]) throws {
        guard let site = dict["site"] as? String, !site.isEmpty,
              let id = dict["id"] as? String, !id.isEmpty
        else {
            throw MarcoError.invalidFormat("观看记录或收藏缺少来源及影片标识")
        }
        for field in ["position", "duration", "index", "updated"] where dict[field] != nil {
            guard let num = dict[field] as? NSNumber, num.doubleValue >= 0 else {
                throw MarcoError.invalidFormat("备份记录的 \(field) 无效")
            }
        }
    }
}

public struct WebDavConfig: Codable, Hashable, Sendable {
    public var url: String
    public var username: String
    public var password: String
    public var autoSync: Bool
    public var syncSubscriptions: Bool
    public var syncHistory: Bool
    public var syncDanmu: Bool
    public var lastSyncTimeMs: Int64
    public var lastSyncStatus: String
    public var lastDanmuSyncStatus: String

    private enum CodingKeys: String, CodingKey {
        case url, username, password, autoSync, syncSubscriptions, syncHistory
        case syncDanmu, lastSyncTimeMs, lastSyncStatus, lastDanmuSyncStatus
    }

    public init(
        url: String = "",
        username: String = "",
        password: String = "",
        autoSync: Bool = true,
        syncSubscriptions: Bool = true,
        syncHistory: Bool = true,
        syncDanmu: Bool = true,
        lastSyncTimeMs: Int64 = 0,
        lastSyncStatus: String = "",
        lastDanmuSyncStatus: String = ""
    ) {
        self.url = url
        self.username = username
        self.password = password
        self.autoSync = autoSync
        self.syncSubscriptions = syncSubscriptions
        self.syncHistory = syncHistory
        self.syncDanmu = syncDanmu
        self.lastSyncTimeMs = lastSyncTimeMs
        self.lastSyncStatus = lastSyncStatus
        self.lastDanmuSyncStatus = lastDanmuSyncStatus
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        self.username = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
        self.password = try c.decodeIfPresent(String.self, forKey: .password) ?? ""
        self.autoSync = try c.decodeIfPresent(Bool.self, forKey: .autoSync) ?? true
        self.syncSubscriptions = try c.decodeIfPresent(Bool.self, forKey: .syncSubscriptions) ?? true
        self.syncHistory = try c.decodeIfPresent(Bool.self, forKey: .syncHistory) ?? true
        self.syncDanmu = try c.decodeIfPresent(Bool.self, forKey: .syncDanmu) ?? true
        self.lastSyncTimeMs = try c.decodeIfPresent(Int64.self, forKey: .lastSyncTimeMs) ?? 0
        self.lastSyncStatus = try c.decodeIfPresent(String.self, forKey: .lastSyncStatus) ?? ""
        self.lastDanmuSyncStatus = try c.decodeIfPresent(String.self, forKey: .lastDanmuSyncStatus) ?? ""
    }

    public var isConfigured: Bool {
        !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public struct SpiderGatewayConfig: Codable, Hashable, Sendable {
    public var enabled: Bool
    public var baseUrl: String
    public var deviceName: String
    public var token: String

    public init(
        enabled: Bool = false,
        baseUrl: String = "",
        deviceName: String = "",
        token: String = ""
    ) {
        self.enabled = enabled
        self.baseUrl = baseUrl
        self.deviceName = deviceName
        self.token = token
    }

    public var normalizedBaseUrl: String {
        var trimmed = baseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let u = URL(string: trimmed),
              let scheme = u.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              let host = u.host, !host.isEmpty
        else {
            return ""
        }
        return trimmed
    }

    public var isActive: Bool {
        enabled && !normalizedBaseUrl.isEmpty
    }
}

/// PBKDF2-SHA256 Privacy PIN hash & verification codec matching Flutter `StorageService` byte-for-byte.
/// Supports:
/// - `pbkdf2:sha256:<len>:<iterations>:<32-hex-salt>:<64-hex-hash>` (current)
/// - `sha256:<len>:<64-hex-sha256("mm_pin_v1:<pin>")>` (legacy Flutter)
/// - Plain 64-hex `sha256("<pin>")` (legacy tvOS)
public enum PrivacyPinCrypto {
    public static let defaultIterations = 100_000

    private static let pbkdf2Regex = try! NSRegularExpression(
        pattern: #"^pbkdf2:sha256:(?:(\d+):)?(\d+):([0-9a-fA-F]{32}):([0-9a-fA-F]{64})$"#
    )
    private static let legacySha256Regex = try! NSRegularExpression(
        pattern: #"^sha256:(\d+):([0-9a-fA-F]{64})$"#
    )

    public static func pbkdf2Sha256(
        password: Data,
        salt: Data,
        iterations: Int,
        keyLength: Int = 32
    ) -> Data {
        let symKey = SymmetricKey(data: password)
        var s1 = Data(salt)
        s1.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
        var u = Data(HMAC<SHA256>.authenticationCode(for: s1, using: symKey))
        var result = [UInt8](u)
        if iterations > 1 {
            for _ in 1..<iterations {
                u = Data(HMAC<SHA256>.authenticationCode(for: u, using: symKey))
                u.withUnsafeBytes { rawBuf in
                    let ptr = rawBuf.bindMemory(to: UInt8.self)
                    for j in 0..<result.count {
                        result[j] ^= ptr[j]
                    }
                }
            }
        }
        return Data(result.prefix(keyLength))
    }

    public static func hashPin(_ pin: String, iterations: Int = defaultIterations) -> String {
        let trimmed = pin.trimmingCharacters(in: .whitespacesAndNewlines)
        var saltBytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, 16, &saltBytes)
        return hashPinWithSalt(trimmed, salt: Data(saltBytes), iterations: iterations)
    }

    public static func hashPinWithSalt(_ trimmedPin: String, salt: Data, iterations: Int = defaultIterations) -> String {
        let derived = pbkdf2Sha256(password: Data(trimmedPin.utf8), salt: salt, iterations: iterations, keyLength: 32)
        let saltHex = salt.map { String(format: "%02x", $0) }.joined()
        let hashHex = derived.map { String(format: "%02x", $0) }.joined()
        return "pbkdf2:sha256:\(trimmedPin.count):\(iterations):\(saltHex):\(hashHex)"
    }

    public static func expectedLength(fromStored stored: String) -> Int {
        let s = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(s.startIndex..., in: s)
        if let m = pbkdf2Regex.firstMatch(in: s, range: range),
           m.range(at: 1).location != NSNotFound,
           let r = Range(m.range(at: 1), in: s),
           let v = Int(s[r])
        {
            return min(max(v, 4), 8)
        }
        if let m = legacySha256Regex.firstMatch(in: s, range: range),
           let r = Range(m.range(at: 1), in: s),
           let v = Int(s[r])
        {
            return min(max(v, 4), 8)
        }
        return min(max(s.count, 4), 8)
    }

    public static func verify(input: String, stored: String) -> (matched: Bool, needsUpgrade: Bool) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let saved = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !saved.isEmpty else { return (false, false) }

        let range = NSRange(saved.startIndex..., in: saved)
        if let m = pbkdf2Regex.firstMatch(in: saved, range: range) {
            if m.range(at: 1).location != NSNotFound,
               let lenR = Range(m.range(at: 1), in: saved),
               let expectedLen = Int(saved[lenR]),
               trimmed.count != expectedLen
            {
                return (false, false)
            }
            guard let iterR = Range(m.range(at: 2), in: saved),
                  let iterations = Int(saved[iterR]),
                  iterations >= 100_000, iterations <= 1_000_000,
                  let saltR = Range(m.range(at: 3), in: saved),
                  let hashR = Range(m.range(at: 4), in: saved),
                  let saltBytes = hexDecode(String(saved[saltR])),
                  let expectedBytes = hexDecode(String(saved[hashR]))
            else {
                return (false, false)
            }
            let derived = pbkdf2Sha256(password: Data(trimmed.utf8), salt: saltBytes, iterations: iterations, keyLength: 32)
            return (constantTimeEquals(derived, expectedBytes), false)
        }

        if let m = legacySha256Regex.firstMatch(in: saved, range: range),
           let lenR = Range(m.range(at: 1), in: saved),
           let hashR = Range(m.range(at: 2), in: saved),
           let expectedLen = Int(saved[lenR])
        {
            let expectedHex = String(saved[hashR]).lowercased()
            let actualHex = SHA256.hash(data: Data("mm_pin_v1:\(trimmed)".utf8))
                .map { String(format: "%02x", $0) }
                .joined()
            let ok = trimmed.count == expectedLen && constantTimeEquals(Data(actualHex.utf8), Data(expectedHex.utf8))
            return (ok, ok)
        }

        if saved.count == 64 && saved.allSatisfy({ $0.isHexDigit }) {
            let actualHex = SHA256.hash(data: Data(trimmed.utf8))
                .map { String(format: "%02x", $0) }
                .joined()
            let ok = constantTimeEquals(Data(actualHex.utf8), Data(saved.lowercased().utf8))
            return (ok, ok)
        }

        if saved.hasPrefix("pbkdf2:") || saved.hasPrefix("sha256:") || saved.contains(":") {
            return (false, false)
        }

        let ok = constantTimeEquals(Data(trimmed.utf8), Data(saved.utf8))
        return (ok, ok)
    }

    private static func constantTimeEquals(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for (x, y) in zip(a, b) {
            diff |= x ^ y
        }
        return diff == 0
    }

    private static func hexDecode(_ hex: String) -> Data? {
        let chars = Array(hex.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var out = Data(capacity: chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let hi = hexVal(chars[i]), let lo = hexVal(chars[i + 1]) else { return nil }
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
}

/// Persistent iOS storage manager backed by `Application Support/MarcoMovie/`,
/// Apple Keychain (`com.pilipala.marcomovie`), and `UserDefaults`.
public final class IOSStorageManager: @unchecked Sendable {
    private struct PrivacyAndIdentityMetadata: Codable {
        var knownPrivateSubscriptionIds: [String] = []
        var knownPrivateSiteKeys: [String] = []
        var ambiguousLegacyRawKeys: [String] = []
        var transitionedToPrivateSubIds: [String]?
        var transitionedToPrivateSiteKeys: [String]?
    }

    private static let accountWebDavSecret = "webdav_credentials_v1"
    private static let accountPrivacyPin = "privacy_pin_v2"
    private static let accountSpiderGatewaySecret = "spider_gateway_token_v1"
    private static let accountAiApiKey = "marco_ai_api_key_v1"
    private static let accountAiOAuthSession = "marco_ai_oauth_session_v1"
    private static let accountAiLabToken = "marco_ai_lab_token_v1"
    private static let accountDanmuAppSecret = "danmu_app_secret_v1"

    public static let maxSyncTombstones = 300
    public static let maxVideoSkipRecords = 500

    private let lock = NSRecursiveLock()
    public let storageDirectory: URL
    public let keychain: KeychainStoreProtocol
    public let defaults: UserDefaults

    private var subscriptionsCache: [SubscriptionEntry] = []
    private var favoritesCache: [FavoriteItem] = []
    private var privateFavoritesCache: [FavoriteItem] = []
    private var historyCache: [WatchHistoryItem] = []
    private var searchHistoryCache: [String] = []
    private var privateSearchHistoryCache: [String] = []
    private var preferencesCache = PlaybackPreferences()
    private var tombstonesCache: [String: Int64] = [:]
    private var videoSkipRecordsCache: [String: VideoSkipRecord] = [:]
    private var standaloneLivesCache: [StandaloneLiveSource] = []
    private var siteOverridesCache: [String: SiteOverride] = [:]
    private var danmuSettingsCache = DanmuSettings()
    private var danmuSyncDocCache = DanmuSourceSyncDocument()
    private var danmuSyncBaseDocCache = DanmuSourceSyncDocument()
    private var aiConfigCache = AiConfig()
    private var aiProfilesCache: [AiProviderProfile] = []
    private var aiUsageCache = AiUsageSummary()
    private var embyAccountsCache: [EmbyAccount] = []
    private var mediaLibraryAccountsCache: [MediaLibraryAccount] = []
    private var downloadTasksCache: [DownloadTask] = []
    private var spiderGatewayCache = SpiderGatewayConfig()

    private var knownPrivateSubscriptionIdsCache: Set<String> = []
    private var knownPrivateSiteKeysCache: Set<String> = []
    private var ambiguousLegacyRawKeysCache: Set<String> = []
    private var transitionedToPrivateSubIdsCache: Set<String> = []
    private var transitionedToPrivateSiteKeysCache: Set<String> = []
    private var mutationVersionCounter: UInt64 = 0

    internal struct SyncStorageSnapshot: Sendable {
        let subscriptions: [SubscriptionEntry]
        let watchHistory: [WatchHistoryItem]
        let favorites: [FavoriteItem]
        let tombstones: [String: Int64]
        let embyAccounts: [EmbyAccount]
        let knownPrivateSubscriptionIds: Set<String>
        let knownPrivateSiteKeys: Set<String>
        let ambiguousLegacyRawKeys: Set<String>
        let transitionedToPrivateSubIds: Set<String>
        let transitionedToPrivateSiteKeys: Set<String>
        let version: UInt64
    }

    public init(
        storageDirectory: URL? = nil,
        keychain: KeychainStoreProtocol = SystemKeychainStore(),
        defaults: UserDefaults = .standard
    ) {
        if let customDir = storageDirectory {
            self.storageDirectory = customDir
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.storageDirectory = appSupport.appendingPathComponent("MarcoMovie", isDirectory: true)
        }
        self.keychain = keychain
        self.defaults = defaults
        loadFromDisk()
    }

    // MARK: - Boot & Disk Loading

    public func loadFromDisk() {
        lock.lock()
        defer { lock.unlock() }

        try? FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)

        subscriptionsCache = readCodable(from: file("subscriptions.json")) ?? []
        favoritesCache = readCodable(from: file("favorites.json")) ?? []
        privateFavoritesCache = readCodable(from: file("private_favorites.json")) ?? []
        historyCache = readCodable(from: file("history.json")) ?? []
        searchHistoryCache = readCodable(from: file("search_history.json")) ?? []
        privateSearchHistoryCache = readCodable(from: file("private_search_history.json")) ?? []
        preferencesCache = readCodable(from: file("preferences.json")) ?? PlaybackPreferences()
        tombstonesCache = readCodable(from: file("tombstones.json")) ?? [:]
        videoSkipRecordsCache = readCodable(from: file("video_skip_records.json")) ?? [:]
        standaloneLivesCache = readCodable(from: file("standalone_lives.json")) ?? []
        siteOverridesCache = readCodable(from: file("site_overrides.json")) ?? [:]
        danmuSettingsCache = readCodable(from: file("danmu_settings.json")) ?? DanmuSettings()
        if let secretData = try? keychain.data(forAccount: Self.accountDanmuAppSecret),
           let secret = String(data: secretData, encoding: .utf8),
           !secret.isEmpty
        {
            danmuSettingsCache.appSecret = secret
        }
        danmuSyncDocCache = readCodable(from: file("danmu_sync_doc.json")) ?? DanmuSourceSyncDocument()
        danmuSyncBaseDocCache = readCodable(from: file("danmu_sync_base.json")) ?? DanmuSourceSyncDocument()
        aiConfigCache = readCodable(from: file("ai_config.json")) ?? AiConfig()
        aiProfilesCache = readCodable(from: file("ai_profiles.json")) ?? []
        aiUsageCache = readCodable(from: file("ai_usage.json")) ?? AiUsageSummary()
        embyAccountsCache = readCodable(from: file("emby_accounts.json")) ?? []
        mediaLibraryAccountsCache = readCodable(from: file("media_library_accounts.json")) ?? []
        downloadTasksCache = readCodable(from: file("downloads.json")) ?? []
        spiderGatewayCache = readCodable(from: file("spider_gateway.json")) ?? SpiderGatewayConfig()
        if let tokData = try? keychain.data(forAccount: Self.accountSpiderGatewaySecret),
           let tok = String(data: tokData, encoding: .utf8),
           !tok.isEmpty
        {
            spiderGatewayCache.token = tok
        }

        if let meta: PrivacyAndIdentityMetadata = readCodable(from: file("privacy_meta.json")) {
            knownPrivateSubscriptionIdsCache = Set(meta.knownPrivateSubscriptionIds)
            knownPrivateSiteKeysCache = Set(meta.knownPrivateSiteKeys)
            ambiguousLegacyRawKeysCache = Set(meta.ambiguousLegacyRawKeys)
            transitionedToPrivateSubIdsCache = Set(meta.transitionedToPrivateSubIds ?? [])
            transitionedToPrivateSiteKeysCache = Set(meta.transitionedToPrivateSiteKeys ?? [])
        } else {
            knownPrivateSubscriptionIdsCache = []
            knownPrivateSiteKeysCache = []
            ambiguousLegacyRawKeysCache = []
            transitionedToPrivateSubIdsCache = []
            transitionedToPrivateSiteKeysCache = []
        }
        syncMetadataTrackersLocked()
    }

    // MARK: - Subscriptions & Ownership Config

    public func subscriptions() -> [SubscriptionEntry] {
        lock.lock()
        defer { lock.unlock() }
        return subscriptionsCache
    }

    public func saveSubscriptions(_ entries: [SubscriptionEntry]) {
        lock.lock()
        defer { lock.unlock() }
        let previousSubs = subscriptionsCache
        syncMetadataTrackersLocked(additionalSubs: previousSubs)
        for nextSub in entries where !nextSub.id.isEmpty && nextSub.isEffectivelyPrivate {
            if let prev = previousSubs.first(where: { $0.id == nextSub.id }), !prev.isEffectivelyPrivate {
                transitionedToPrivateSubIdsCache.insert(nextSub.id)
            }
        }
        subscriptionsCache = entries
        syncMetadataTrackersLocked(additionalSubs: previousSubs)
        mutationVersionCounter &+= 1
        writeCodableAtomically(subscriptionsCache, to: file("subscriptions.json"))
        persistPrivacyMetaLocked()
    }

    @discardableResult
    public func upsertSubscription(
        id existingTargetId: String? = nil,
        name: String,
        url: String,
        rawContent: String,
        group: String? = nil,
        isPrivate: Bool? = nil,
        enabled: Bool? = nil,
        warehouseUrl: String = "",
        activeDepotUrl: String = "",
        activeDepotName: String = "",
        depots: [CmsDepot]? = nil,
        nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) throws -> (entry: SubscriptionEntry, config: CmsConfig) {
        let cleanUrl = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanWarehouse = warehouseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanDepotUrl = activeDepotUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanDepotName = activeDepotName.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanTargetId = existingTargetId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        lock.lock()
        let existingSnapshot: SubscriptionEntry? = {
            if !cleanTargetId.isEmpty, let byId = subscriptionsCache.first(where: { $0.id == cleanTargetId }) {
                return byId
            }
            if !cleanWarehouse.isEmpty,
               let byWh = subscriptionsCache.first(where: { $0.warehouseUrl == cleanWarehouse || $0.url == cleanWarehouse })
            {
                return byWh
            }
            if !cleanUrl.isEmpty, let byUrl = subscriptionsCache.first(where: { $0.url == cleanUrl }) {
                return byUrl
            }
            return nil
        }()
        let existingIdsSnapshot = Set(subscriptionsCache.map(\.id))
        lock.unlock()

        let effectiveWarehouseForId = !cleanWarehouse.isEmpty ? cleanWarehouse : (existingSnapshot?.warehouseUrl ?? "")
        let subId: String = {
            if let prevId = existingSnapshot?.id, !prevId.isEmpty { return prevId }
            if !cleanTargetId.isEmpty { return cleanTargetId }
            if let deterministic = WebDavSyncService.canonicalWireSubscriptionId(
                url: cleanUrl,
                rawContent: rawContent,
                warehouseUrl: effectiveWarehouseForId
            ), !existingIdsSnapshot.contains(deterministic) {
                return deterministic
            }
            return "sub_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10).lowercased())"
        }()

        let effectiveGroup: String = {
            if let explicit = group?.trimmingCharacters(in: .whitespacesAndNewlines), !explicit.isEmpty {
                return explicit
            }
            if let prev = existingSnapshot?.group.trimmingCharacters(in: .whitespacesAndNewlines), !prev.isEmpty {
                return prev
            }
            return "默认分组"
        }()
        let effectivePrivate = (isPrivate ?? existingSnapshot?.isEffectivelyPrivate ?? false)
            || effectiveGroup.contains("隐私")
            || effectiveGroup.contains("私密")
        let effectiveEnabled = enabled ?? existingSnapshot?.enabled ?? true
        let effectiveWarehouse = !cleanWarehouse.isEmpty ? cleanWarehouse : (existingSnapshot?.warehouseUrl ?? "")
        let effectiveActiveDepotUrl = !cleanDepotUrl.isEmpty ? cleanDepotUrl : (existingSnapshot?.activeDepotUrl ?? "")
        let effectiveActiveDepot = !cleanDepotName.isEmpty ? cleanDepotName : (existingSnapshot?.activeDepotName ?? "")

        let displayName: String = {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
            if let prevName = existingSnapshot?.name.trimmingCharacters(in: .whitespacesAndNewlines), !prevName.isEmpty {
                return prevName
            }
            if !effectiveActiveDepot.isEmpty { return effectiveActiveDepot }
            if let host = URL(string: cleanUrl)?.host, !host.isEmpty { return host }
            return "iOS 订阅源"
        }()

        let parsed = try CmsParser.parseConfig(
            rawContent,
            origin: cleanUrl,
            defaultGroup: effectiveGroup,
            isPrivate: effectivePrivate,
            subscriptionId: subId,
            defaultName: displayName
        )

        lock.lock()
        defer { lock.unlock() }

        let existingIdx: Int? = {
            if !cleanTargetId.isEmpty, let idx = subscriptionsCache.firstIndex(where: { $0.id == cleanTargetId }) {
                return idx
            }
            if let snap = existingSnapshot, let idx = subscriptionsCache.firstIndex(where: { $0.id == snap.id }) {
                return idx
            }
            if !cleanWarehouse.isEmpty,
               let idx = subscriptionsCache.firstIndex(where: { $0.warehouseUrl == cleanWarehouse || $0.url == cleanWarehouse })
            {
                return idx
            }
            if !cleanUrl.isEmpty, let idx = subscriptionsCache.firstIndex(where: { $0.url == cleanUrl }) {
                return idx
            }
            return nil
        }()

        let rawDepots: [CmsDepot] = {
            if let explicitDepots = depots, !explicitDepots.isEmpty { return explicitDepots }
            if !parsed.depots.isEmpty { return parsed.depots }
            if let idx = existingIdx { return subscriptionsCache[idx].depots }
            return []
        }()
        let normalizedDepots = rawDepots.map { d in
            CmsDepot(
                name: d.name,
                url: d.url,
                subscriptionId: subId,
                isPrivate: effectivePrivate || d.isPrivate
            )
        }

        let effectiveFormat: String = {
            if !normalizedDepots.isEmpty || !effectiveWarehouse.isEmpty { return "多仓" }
            if let idx = existingIdx, !subscriptionsCache[idx].format.isEmpty {
                return subscriptionsCache[idx].format
            }
            return "JSON"
        }()

        let entry = SubscriptionEntry(
            id: subId,
            name: displayName,
            url: cleanUrl,
            group: effectiveGroup,
            format: effectiveFormat,
            isPrivate: effectivePrivate,
            enabled: effectiveEnabled,
            rawContent: rawContent,
            siteCount: parsed.sites.count,
            liveCount: parsed.lives.count,
            updatedAt: nowMs,
            warehouseUrl: effectiveWarehouse,
            activeDepotUrl: effectiveActiveDepotUrl,
            activeDepotName: effectiveActiveDepot,
            depots: normalizedDepots
        )

        let previousEntry = existingIdx.map { subscriptionsCache[$0] }
        if let prev = previousEntry, !prev.isEffectivelyPrivate && effectivePrivate && !subId.isEmpty {
            transitionedToPrivateSubIdsCache.insert(subId)
        }
        if let idx = existingIdx {
            subscriptionsCache[idx] = entry
        } else {
            subscriptionsCache.insert(entry, at: 0)
        }

        if effectiveEnabled,
           !effectivePrivate,
           preferencesCache.selectedSiteKey.isEmpty,
           let firstAvail = parsed.publicAvailableSites.first(where: { !$0.isBannerNoticeSite })
               ?? parsed.publicAvailableSites.first
        {
            preferencesCache.selectedSiteKey = CmsSite.canonicalScopedKey(
                rawKey: firstAvail.rawKey,
                subscriptionId: subId
            )
            writeCodableAtomically(preferencesCache, to: file("preferences.json"))
        }

        if !effectivePrivate {
            let syncKey = WebDavSyncService.canonicalSubscriptionSyncKey(
                url: entry.url,
                rawContent: entry.rawContent,
                warehouseUrl: entry.warehouseUrl
            )
            tombstonesCache.removeValue(forKey: "sub:\(syncKey)")
            writeCodableAtomically(tombstonesCache, to: file("tombstones.json"))
        }
        writeCodableAtomically(subscriptionsCache, to: file("subscriptions.json"))
        syncMetadataTrackersLocked(additionalSubs: previousEntry.map { [$0] } ?? [])
        persistPrivacyMetaLocked()
        mutationVersionCounter &+= 1
        return (entry, parsed)
    }

    public func removeSubscription(id: String, nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) {
        lock.lock()
        defer { lock.unlock() }
        let removedTarget = subscriptionsCache.first(where: { $0.id == id })
        syncMetadataTrackersLocked(additionalSubs: removedTarget.map { [$0] } ?? [])
        if let target = removedTarget,
           (!target.rawContent.isEmpty || !target.url.isEmpty || !target.warehouseUrl.isEmpty),
           !target.isEffectivelyPrivate
        {
            let syncKey = WebDavSyncService.canonicalSubscriptionSyncKey(
                url: target.url,
                rawContent: target.rawContent,
                warehouseUrl: target.warehouseUrl
            )
            recordTombstoneLocked(key: "sub:\(syncKey)", timestampMs: max(nowMs, target.updatedAt + 1))
        }
        subscriptionsCache.removeAll { $0.id == id }
        syncMetadataTrackersLocked(additionalSubs: removedTarget.map { [$0] } ?? [])
        mutationVersionCounter &+= 1
        writeCodableAtomically(subscriptionsCache, to: file("subscriptions.json"))
        persistPrivacyMetaLocked()
    }

    internal static func buildOwnershipConfig(
        from allSubsSnapshot: [SubscriptionEntry],
        standaloneLives: [StandaloneLiveSource] = [],
        siteOverrides: [String: SiteOverride] = [:],
        knownPrivateSubscriptionIds: Set<String>,
        knownPrivateSiteKeys: Set<String>,
        ambiguousLegacyRawKeys: Set<String>
    ) -> CmsConfig {
        var allSites: [CmsSite] = []
        var allLives: [LiveSource] = []
        var allDepots: [CmsDepot] = []
        var allParses: [CmsParse] = []
        var allRules: [CmsSniffRule] = []
        var allAds: [String] = []
        var allOwners: [SiteOwnershipRecord] = []
        var privateSubIds = knownPrivateSubscriptionIds
        var publicSubIds = Set<String>()
        var unhydratedPublicSubIds = Set<String>()
        var primarySpider = ""
        var seenDepotUrls = Set<String>()
        var seenAds = Set<String>()

        for live in standaloneLives where live.enabled {
            allLives.append(live.toLiveSource())
        }

        for sub in allSubsSnapshot {
            let subPriv = sub.isEffectivelyPrivate
            if !sub.id.isEmpty {
                if subPriv {
                    privateSubIds.insert(sub.id)
                } else {
                    publicSubIds.insert(sub.id)
                    if sub.rawContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        unhydratedPublicSubIds.insert(sub.id)
                    }
                    privateSubIds.remove(sub.id)
                }
            }

            if sub.enabled && !sub.rawContent.isEmpty {
                for d in sub.depots where seenDepotUrls.insert(d.url).inserted {
                    allDepots.append(CmsDepot(name: d.name, url: d.url, subscriptionId: sub.id, isPrivate: subPriv || d.isPrivate))
                }
            }

            guard !sub.rawContent.isEmpty,
                  let cfg = try? CmsParser.parseConfig(
                      sub.rawContent,
                      origin: sub.url,
                      defaultGroup: sub.group,
                      isPrivate: subPriv,
                      subscriptionId: sub.id,
                      defaultName: sub.name
                  )
            else {
                continue
            }

            var intraSubRawCounts: [String: Int] = [:]
            var scopedSites: [CmsSite] = []
            for var site in cfg.sites {
                let originalRawKey = site.rawKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? site.key
                    : site.rawKey
                let occurrence = intraSubRawCounts[originalRawKey, default: 0]
                intraSubRawCounts[originalRawKey] = occurrence + 1
                let disambiguatedRaw = occurrence == 0 ? originalRawKey : "\(originalRawKey)#\(occurrence + 1)"
                let canonicalKey = CmsSite.canonicalScopedKey(rawKey: disambiguatedRaw, subscriptionId: sub.id)

                site.rawKey = originalRawKey
                site.key = canonicalKey
                site.subscriptionId = sub.id
                site.isPrivate = subPriv || site.isEffectivelyPrivate

                if let override = siteOverrides[canonicalKey] ?? siteOverrides[originalRawKey] {
                    site = override.applyTo(site)
                }

                allOwners.append(
                    SiteOwnershipRecord(
                        canonicalKey: canonicalKey,
                        rawKey: originalRawKey,
                        subscriptionId: sub.id,
                        subscriptionName: sub.name,
                        siteName: site.name,
                        isEnabled: sub.enabled,
                        isPrivate: site.isEffectivelyPrivate,
                        isSupported: site.supported,
                        unsupportedReason: site.unsupportedReason
                    )
                )
                scopedSites.append(site)
            }

            guard sub.enabled else { continue }

            if primarySpider.isEmpty && !cfg.spider.isEmpty {
                primarySpider = cfg.spider
            }
            for d in cfg.depots where seenDepotUrls.insert(d.url).inserted {
                allDepots.append(CmsDepot(name: d.name, url: d.url, subscriptionId: sub.id, isPrivate: subPriv || d.isPrivate))
            }
            for p in cfg.parses where !allParses.contains(where: { $0.url == p.url }) {
                allParses.append(p)
            }
            allRules.append(contentsOf: cfg.rules)
            for ad in cfg.ads where seenAds.insert(ad.lowercased()).inserted {
                allAds.append(ad)
            }
            allSites.append(contentsOf: scopedSites)
            for var live in cfg.lives {
                live.isPrivate = subPriv || live.isEffectivelyPrivate
                live.subscriptionId = sub.id
                if var plugin = live.plugin {
                    plugin.isPrivate = subPriv || plugin.isEffectivelyPrivate
                    plugin.subscriptionId = sub.id
                    live.plugin = plugin
                }
                allLives.append(live)
            }
        }

        return CmsConfig(
            sites: allSites,
            lives: allLives,
            depots: allDepots,
            parses: allParses,
            rules: allRules,
            ads: allAds,
            spider: primarySpider,
            siteOwners: allOwners,
            privateSubscriptionIds: privateSubIds,
            publicSubscriptionIds: publicSubIds,
            unhydratedPublicSubscriptionIds: unhydratedPublicSubIds,
            knownPrivateSiteKeys: knownPrivateSiteKeys,
            ambiguousLegacyRawKeys: ambiguousLegacyRawKeys
        )
    }

    public func mergedConfig() -> CmsConfig {
        lock.lock()
        syncMetadataTrackersLocked()
        let allSubsSnapshot = subscriptionsCache
        let livesSnap = standaloneLivesCache
        let overridesSnap = siteOverridesCache
        let privSubs = knownPrivateSubscriptionIdsCache
        let privKeys = knownPrivateSiteKeysCache
        let ambigRaw = ambiguousLegacyRawKeysCache
        lock.unlock()

        return Self.buildOwnershipConfig(
            from: allSubsSnapshot,
            standaloneLives: livesSnap,
            siteOverrides: overridesSnap,
            knownPrivateSubscriptionIds: privSubs,
            knownPrivateSiteKeys: privKeys,
            ambiguousLegacyRawKeys: ambigRaw
        )
    }

    // MARK: - Watch History & Favorites

    public func watchHistory() -> [WatchHistoryItem] {
        lock.lock()
        defer { lock.unlock() }
        return historyCache
    }

    public func saveWatchHistoryRaw(_ items: [WatchHistoryItem]) {
        lock.lock()
        defer { lock.unlock() }
        historyCache = Array(items.prefix(CmsParser.maxHistoryEntries))
        mutationVersionCounter &+= 1
        writeCodableAtomically(historyCache, to: file("history.json"))
    }

    public func upsertWatchHistory(_ item: WatchHistoryItem) {
        lock.lock()
        defer { lock.unlock() }
        var normalized = item
        if let prevDel = tombstonesCache["hist:\(item.key)"], normalized.updated <= prevDel {
            normalized.updated = prevDel + 1
        }
        if let prevExisting = historyCache.first(where: { $0.key == item.key }),
           normalized.updated <= prevExisting.updated
        {
            normalized.updated = prevExisting.updated + 1
        }

        if let parsed = CmsSite.parseScopedKey(normalized.site) {
            let legacySuffixed = "\(parsed.rawKey)_\(parsed.subscriptionId)"
            let bareAllowed = isUnambiguousLegacyRawKeyLocked(parsed.rawKey, forSubscriptionId: parsed.subscriptionId)
            let legacyMatches = historyCache.filter { existing in
                guard existing.id == normalized.id, existing.site != normalized.site else { return false }
                if existing.site == legacySuffixed { return true }
                if bareAllowed && existing.site == parsed.rawKey { return true }
                return false
            }
            if !legacyMatches.isEmpty {
                for old in legacyMatches {
                    if normalized.updated <= old.updated {
                        normalized.updated = old.updated + 1
                    }
                    tombstonesCache["hist:\(old.key)"] = max(normalized.updated, old.updated + 1)
                }
                let legacyKeys = Set(legacyMatches.map(\.key))
                historyCache.removeAll { legacyKeys.contains($0.key) }
                boundTombstonesLocked()
            }
        }

        historyCache = CmsParser.upsertHistory(historyCache, entry: normalized)
        tombstonesCache.removeValue(forKey: "hist:\(normalized.key)")
        mutationVersionCounter &+= 1
        writeCodableAtomically(historyCache, to: file("history.json"))
        writeCodableAtomically(tombstonesCache, to: file("tombstones.json"))
    }

    public func removeWatchHistory(site: String, id: String, nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) {
        lock.lock()
        defer { lock.unlock() }
        let targetKey = "\(site)\n\(id)"
        let existingTs = historyCache.first(where: { $0.key == targetKey })?.updated ?? 0
        historyCache.removeAll { $0.key == targetKey }
        recordTombstoneLocked(key: "hist:\(targetKey)", timestampMs: max(nowMs, existingTs + 1))
        mutationVersionCounter &+= 1
        writeCodableAtomically(historyCache, to: file("history.json"))
    }

    public func clearWatchHistory(nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) {
        lock.lock()
        defer { lock.unlock() }
        for item in historyCache {
            tombstonesCache["hist:\(item.key)"] = max(nowMs, item.updated + 1)
        }
        boundTombstonesLocked()
        historyCache = []
        mutationVersionCounter &+= 1
        writeCodableAtomically(historyCache, to: file("history.json"))
        writeCodableAtomically(tombstonesCache, to: file("tombstones.json"))
    }

    public func favorites() -> [FavoriteItem] {
        lock.lock()
        defer { lock.unlock() }
        return favoritesCache
    }

    public func saveFavoritesRaw(_ items: [FavoriteItem]) {
        lock.lock()
        defer { lock.unlock() }
        favoritesCache = Array(items.prefix(CmsParser.maxFavoriteEntries))
        mutationVersionCounter &+= 1
        writeCodableAtomically(favoritesCache, to: file("favorites.json"))
    }

    public func privateFavorites() -> [FavoriteItem] {
        lock.lock()
        defer { lock.unlock() }
        return privateFavoritesCache
    }

    public func savePrivateFavorites(_ items: [FavoriteItem]) {
        lock.lock()
        defer { lock.unlock() }
        privateFavoritesCache = Array(items.prefix(CmsParser.maxFavoriteEntries))
        writeCodableAtomically(privateFavoritesCache, to: file("private_favorites.json"))
    }

    public func isFavorite(site: String, id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let targetKey = "\(site)\n\(id)"
        return favoritesCache.contains { $0.key == targetKey }
    }

    @discardableResult
    public func toggleFavorite(
        site: String,
        video: CmsVideo,
        isPrivateSpace: Bool = false,
        nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let targetKey = "\(site)\n\(video.id)"

        if isPrivateSpace {
            if let idx = privateFavoritesCache.firstIndex(where: { $0.key == targetKey }) {
                privateFavoritesCache.remove(at: idx)
                writeCodableAtomically(privateFavoritesCache, to: file("private_favorites.json"))
                return false
            }
            let fav = FavoriteItem(
                site: site,
                id: video.id,
                title: video.title,
                poster: video.poster,
                remarks: video.remarks,
                updated: nowMs
            )
            privateFavoritesCache.insert(fav, at: 0)
            if privateFavoritesCache.count > CmsParser.maxFavoriteEntries {
                privateFavoritesCache = Array(privateFavoritesCache.prefix(CmsParser.maxFavoriteEntries))
            }
            writeCodableAtomically(privateFavoritesCache, to: file("private_favorites.json"))
            return true
        }

        let nowFav: Bool
        if let idx = favoritesCache.firstIndex(where: { $0.key == targetKey }) {
            let removedTs = favoritesCache[idx].updated
            let prevAddTs = tombstonesCache["add:\(targetKey)"] ?? 0
            let effectiveDelTs = max(nowMs, max(removedTs, prevAddTs) + 1)
            favoritesCache.remove(at: idx)
            tombstonesCache["fav:\(targetKey)"] = effectiveDelTs
            tombstonesCache.removeValue(forKey: "add:\(targetKey)")
            nowFav = false
        } else if let parsed = CmsSite.parseScopedKey(site),
                  let legacyIdx = favoritesCache.firstIndex(where: { existing in
                      guard existing.id == video.id, existing.site != site else { return false }
                      if existing.site == "\(parsed.rawKey)_\(parsed.subscriptionId)" { return true }
                      if existing.site == parsed.rawKey {
                          return isUnambiguousLegacyRawKeyLocked(parsed.rawKey, forSubscriptionId: parsed.subscriptionId)
                      }
                      return false
                  })
        {
            let removed = favoritesCache.remove(at: legacyIdx)
            let prevAddTs = tombstonesCache["add:\(removed.key)"] ?? 0
            let effectiveDelTs = max(nowMs, max(removed.updated, prevAddTs) + 1)
            tombstonesCache["fav:\(removed.key)"] = effectiveDelTs
            tombstonesCache.removeValue(forKey: "add:\(removed.key)")
            nowFav = false
        } else {
            let prevDelTs = tombstonesCache["fav:\(targetKey)"] ?? 0
            let effectiveAddTs = max(nowMs, prevDelTs + 1)
            let fav = FavoriteItem(
                site: site,
                id: video.id,
                title: video.title,
                poster: video.poster,
                remarks: video.remarks,
                updated: effectiveAddTs
            )
            favoritesCache.insert(fav, at: 0)
            if favoritesCache.count > CmsParser.maxFavoriteEntries {
                favoritesCache = Array(favoritesCache.prefix(CmsParser.maxFavoriteEntries))
            }
            tombstonesCache["add:\(targetKey)"] = effectiveAddTs
            tombstonesCache.removeValue(forKey: "fav:\(targetKey)")
            nowFav = true
        }
        mutationVersionCounter &+= 1
        boundTombstonesLocked()
        writeCodableAtomically(favoritesCache, to: file("favorites.json"))
        writeCodableAtomically(tombstonesCache, to: file("tombstones.json"))
        return nowFav
    }

    public func removeFavorite(site: String, id: String, nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) {
        lock.lock()
        defer { lock.unlock() }
        let targetKey = "\(site)\n\(id)"
        let removedTs = favoritesCache.first(where: { $0.key == targetKey })?.updated ?? 0
        let prevAddTs = tombstonesCache["add:\(targetKey)"] ?? 0
        let effectiveDelTs = max(nowMs, max(removedTs, prevAddTs) + 1)
        favoritesCache.removeAll { $0.key == targetKey }
        tombstonesCache["fav:\(targetKey)"] = effectiveDelTs
        tombstonesCache.removeValue(forKey: "add:\(targetKey)")
        mutationVersionCounter &+= 1
        boundTombstonesLocked()
        writeCodableAtomically(favoritesCache, to: file("favorites.json"))
        writeCodableAtomically(tombstonesCache, to: file("tombstones.json"))
    }

    public func clearFavorites(nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) {
        lock.lock()
        defer { lock.unlock() }
        for fav in favoritesCache {
            let prevAdd = tombstonesCache["add:\(fav.key)"] ?? 0
            tombstonesCache["fav:\(fav.key)"] = max(nowMs, max(fav.updated, prevAdd) + 1)
            tombstonesCache.removeValue(forKey: "add:\(fav.key)")
        }
        boundTombstonesLocked()
        favoritesCache = []
        mutationVersionCounter &+= 1
        writeCodableAtomically(favoritesCache, to: file("favorites.json"))
        writeCodableAtomically(tombstonesCache, to: file("tombstones.json"))
    }

    // MARK: - Search History, Skip Records, Overrides, Standalone Lives

    public func searchHistory(isPrivateSpace: Bool = false) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return isPrivateSpace ? privateSearchHistoryCache : searchHistoryCache
    }

    public func saveSearchHistory(_ items: [String], isPrivateSpace: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        let bounded = Array(items.prefix(24))
        if isPrivateSpace {
            privateSearchHistoryCache = bounded
            writeCodableAtomically(privateSearchHistoryCache, to: file("private_search_history.json"))
        } else {
            searchHistoryCache = bounded
            writeCodableAtomically(searchHistoryCache, to: file("search_history.json"))
        }
    }

    public func addSearchKeyword(_ keyword: String, isPrivateSpace: Bool = false) {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        if isPrivateSpace {
            privateSearchHistoryCache.removeAll { $0 == trimmed }
            privateSearchHistoryCache.insert(trimmed, at: 0)
            if privateSearchHistoryCache.count > 24 {
                privateSearchHistoryCache = Array(privateSearchHistoryCache.prefix(24))
            }
            writeCodableAtomically(privateSearchHistoryCache, to: file("private_search_history.json"))
        } else {
            searchHistoryCache.removeAll { $0 == trimmed }
            searchHistoryCache.insert(trimmed, at: 0)
            if searchHistoryCache.count > 24 {
                searchHistoryCache = Array(searchHistoryCache.prefix(24))
            }
            writeCodableAtomically(searchHistoryCache, to: file("search_history.json"))
        }
    }

    public func clearSearchHistory(isPrivateSpace: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        if isPrivateSpace {
            privateSearchHistoryCache = []
            writeCodableAtomically(privateSearchHistoryCache, to: file("private_search_history.json"))
        } else {
            searchHistoryCache = []
            writeCodableAtomically(searchHistoryCache, to: file("search_history.json"))
        }
    }

    public func videoSkipRecord(for key: String) -> VideoSkipRecord? {
        lock.lock()
        defer { lock.unlock() }
        return videoSkipRecordsCache[key]
    }

    public func allVideoSkipRecords() -> [String: VideoSkipRecord] {
        lock.lock()
        defer { lock.unlock() }
        return videoSkipRecordsCache
    }

    public func setVideoSkipRecord(_ record: VideoSkipRecord?, for key: String) {
        lock.lock()
        defer { lock.unlock() }
        if let rec = record {
            videoSkipRecordsCache[key] = rec
            if videoSkipRecordsCache.count > Self.maxVideoSkipRecords {
                let kept = videoSkipRecordsCache.sorted { $0.value.updated > $1.value.updated }.prefix(Self.maxVideoSkipRecords)
                videoSkipRecordsCache = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
            }
        } else {
            videoSkipRecordsCache.removeValue(forKey: key)
        }
        writeCodableAtomically(videoSkipRecordsCache, to: file("video_skip_records.json"))
    }

    public func standaloneLiveSources() -> [StandaloneLiveSource] {
        lock.lock()
        defer { lock.unlock() }
        return standaloneLivesCache
    }

    public func saveStandaloneLiveSources(_ sources: [StandaloneLiveSource]) {
        lock.lock()
        defer { lock.unlock() }
        standaloneLivesCache = sources
        writeCodableAtomically(standaloneLivesCache, to: file("standalone_lives.json"))
    }

    public func siteOverrides() -> [String: SiteOverride] {
        lock.lock()
        defer { lock.unlock() }
        return siteOverridesCache
    }

    public func saveSiteOverrides(_ overrides: [String: SiteOverride]) {
        lock.lock()
        defer { lock.unlock() }
        siteOverridesCache = overrides.filter { !$0.value.isEmpty }
        writeCodableAtomically(siteOverridesCache, to: file("site_overrides.json"))
    }

    // MARK: - Preferences

    public func preferences() -> PlaybackPreferences {
        lock.lock()
        defer { lock.unlock() }
        return preferencesCache
    }

    public func updatePreferences(_ transform: (inout PlaybackPreferences) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        var next = preferencesCache
        transform(&next)
        preferencesCache = next
        writeCodableAtomically(preferencesCache, to: file("preferences.json"))
    }

    // MARK: - Danmaku, AI, Media Libraries & Downloads

    public func danmuSettings() -> DanmuSettings {
        lock.lock()
        defer { lock.unlock() }
        return danmuSettingsCache
    }

    public func saveDanmuSettings(_ settings: DanmuSettings) {
        lock.lock()
        defer { lock.unlock() }
        danmuSettingsCache = settings
        var sanitized = settings
        sanitized.appSecret = ""
        writeCodableAtomically(sanitized, to: file("danmu_settings.json"))
        if settings.appSecret.isEmpty {
            try? keychain.removeData(forAccount: Self.accountDanmuAppSecret)
        } else {
            try? keychain.setData(Data(settings.appSecret.utf8), forAccount: Self.accountDanmuAppSecret)
        }
    }

    public func danmuSyncDocument() -> DanmuSourceSyncDocument {
        lock.lock()
        defer { lock.unlock() }
        return danmuSyncDocCache
    }

    public func danmuSyncBaseDocument() -> DanmuSourceSyncDocument {
        lock.lock()
        defer { lock.unlock() }
        return danmuSyncBaseDocCache
    }

    public func saveDanmuSyncDocuments(current: DanmuSourceSyncDocument, base: DanmuSourceSyncDocument? = nil) {
        lock.lock()
        defer { lock.unlock() }
        danmuSyncDocCache = current
        writeCodableAtomically(danmuSyncDocCache, to: file("danmu_sync_doc.json"))
        if let base = base {
            danmuSyncBaseDocCache = base
            writeCodableAtomically(danmuSyncBaseDocCache, to: file("danmu_sync_base.json"))
        }
    }

    public func aiConfig() -> AiConfig {
        lock.lock()
        defer { lock.unlock() }
        return aiConfigCache
    }

    public func saveAiConfig(_ config: AiConfig) {
        lock.lock()
        defer { lock.unlock() }
        aiConfigCache = config
        writeCodableAtomically(aiConfigCache, to: file("ai_config.json"))
    }

    public func aiProfiles() -> [AiProviderProfile] {
        lock.lock()
        defer { lock.unlock() }
        return aiProfilesCache
    }

    public func saveAiProfiles(_ profiles: [AiProviderProfile]) {
        lock.lock()
        defer { lock.unlock() }
        aiProfilesCache = profiles
        writeCodableAtomically(aiProfilesCache, to: file("ai_profiles.json"))
    }

    public func aiUsage() -> AiUsageSummary {
        lock.lock()
        defer { lock.unlock() }
        return aiUsageCache
    }

    public func saveAiUsage(_ usage: AiUsageSummary) {
        lock.lock()
        defer { lock.unlock() }
        aiUsageCache = usage
        writeCodableAtomically(aiUsageCache, to: file("ai_usage.json"))
    }

    public func aiSecret(forProfileId profileId: String? = nil) -> String {
        let key = profileId.map { "marco_ai_profile_secret_\($0)" } ?? Self.accountAiApiKey
        guard let data = try? keychain.data(forAccount: key) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    public func setAiSecret(_ secret: String, forProfileId profileId: String? = nil) throws {
        let key = profileId.map { "marco_ai_profile_secret_\($0)" } ?? Self.accountAiApiKey
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try keychain.removeData(forAccount: key)
        } else {
            try keychain.setData(Data(trimmed.utf8), forAccount: key)
        }
    }

    public func embyAccounts() -> [EmbyAccount] {
        lock.lock()
        defer { lock.unlock() }
        return embyAccountsCache
    }

    public func saveEmbyAccounts(_ accounts: [EmbyAccount]) {
        lock.lock()
        defer { lock.unlock() }
        embyAccountsCache = accounts
        writeCodableAtomically(embyAccountsCache, to: file("emby_accounts.json"))
    }

    public func mediaLibraryAccounts() -> [MediaLibraryAccount] {
        lock.lock()
        defer { lock.unlock() }
        return mediaLibraryAccountsCache
    }

    public func saveMediaLibraryAccounts(_ accounts: [MediaLibraryAccount]) {
        lock.lock()
        defer { lock.unlock() }
        mediaLibraryAccountsCache = accounts
        writeCodableAtomically(mediaLibraryAccountsCache, to: file("media_library_accounts.json"))
    }

    public func mediaLibrarySecret(for account: MediaLibraryAccount) -> String {
        guard let data = try? keychain.data(forAccount: account.secretKeychainKey) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    public func setMediaLibrarySecret(_ secret: String, for account: MediaLibraryAccount) throws {
        if secret.isEmpty {
            try keychain.removeData(forAccount: account.secretKeychainKey)
        } else {
            try keychain.setData(Data(secret.utf8), forAccount: account.secretKeychainKey)
        }
    }

    public func downloadTasks() -> [DownloadTask] {
        lock.lock()
        defer { lock.unlock() }
        return downloadTasksCache
    }

    public func saveDownloadTasks(_ tasks: [DownloadTask]) {
        lock.lock()
        defer { lock.unlock() }
        downloadTasksCache = tasks
        writeCodableAtomically(downloadTasksCache, to: file("downloads.json"))
    }

    public func spiderGatewayConfig() -> SpiderGatewayConfig {
        lock.lock()
        defer { lock.unlock() }
        return spiderGatewayCache
    }

    public func saveSpiderGatewayConfig(_ config: SpiderGatewayConfig) throws {
        lock.lock()
        spiderGatewayCache = config
        var diskCopy = config
        diskCopy.token = ""
        writeCodableAtomically(diskCopy, to: file("spider_gateway.json"))
        lock.unlock()
        if config.token.isEmpty {
            try keychain.removeData(forAccount: Self.accountSpiderGatewaySecret)
        } else {
            try keychain.setData(Data(config.token.utf8), forAccount: Self.accountSpiderGatewaySecret)
        }
    }

    // MARK: - Tombstones & Sync Snapshots

    public func tombstones() -> [String: Int64] {
        lock.lock()
        defer { lock.unlock() }
        return tombstonesCache
    }

    public func saveTombstones(_ tombstones: [String: Int64]) {
        lock.lock()
        defer { lock.unlock() }
        tombstonesCache = tombstones
        boundTombstonesLocked()
        writeCodableAtomically(tombstonesCache, to: file("tombstones.json"))
    }

    internal func captureSyncSnapshot() -> SyncStorageSnapshot {
        lock.lock()
        defer { lock.unlock() }
        syncMetadataTrackersLocked()
        return SyncStorageSnapshot(
            subscriptions: subscriptionsCache,
            watchHistory: historyCache,
            favorites: favoritesCache,
            tombstones: tombstonesCache,
            embyAccounts: embyAccountsCache,
            knownPrivateSubscriptionIds: knownPrivateSubscriptionIdsCache,
            knownPrivateSiteKeys: knownPrivateSiteKeysCache,
            ambiguousLegacyRawKeys: ambiguousLegacyRawKeysCache,
            transitionedToPrivateSubIds: transitionedToPrivateSubIdsCache,
            transitionedToPrivateSiteKeys: transitionedToPrivateSiteKeysCache,
            version: mutationVersionCounter
        )
    }

    internal func commitSyncTransform<Result>(
        _ transform: (SyncStorageSnapshot) throws -> (
            subscriptions: [SubscriptionEntry],
            watchHistory: [WatchHistoryItem],
            favorites: [FavoriteItem],
            tombstones: [String: Int64],
            embyAccounts: [EmbyAccount],
            result: Result
        )
    ) throws -> Result {
        lock.lock()
        defer { lock.unlock() }
        syncMetadataTrackersLocked()
        let live = SyncStorageSnapshot(
            subscriptions: subscriptionsCache,
            watchHistory: historyCache,
            favorites: favoritesCache,
            tombstones: tombstonesCache,
            embyAccounts: embyAccountsCache,
            knownPrivateSubscriptionIds: knownPrivateSubscriptionIdsCache,
            knownPrivateSiteKeys: knownPrivateSiteKeysCache,
            ambiguousLegacyRawKeys: ambiguousLegacyRawKeysCache,
            transitionedToPrivateSubIds: transitionedToPrivateSubIdsCache,
            transitionedToPrivateSiteKeys: transitionedToPrivateSiteKeysCache,
            version: mutationVersionCounter
        )
        let outcome = try transform(live)
        let previousSubs = subscriptionsCache
        subscriptionsCache = outcome.subscriptions
        historyCache = Array(outcome.watchHistory.prefix(CmsParser.maxHistoryEntries))
        favoritesCache = Array(outcome.favorites.prefix(CmsParser.maxFavoriteEntries))
        tombstonesCache = outcome.tombstones
        embyAccountsCache = outcome.embyAccounts
        syncMetadataTrackersLocked(additionalSubs: previousSubs.filter { prev in
            !outcome.subscriptions.contains(where: { $0.id == prev.id })
        })
        boundTombstonesLocked()
        persistAllFilesLocked()
        return outcome.result
    }

    // MARK: - Keychain Credentials (WebDAV, 5 Netdisks & Privacy PIN)

    private static func netdiskAccountKey(for driveKey: String) -> String {
        if let provider = NetdiskProvider.fromKey(driveKey) {
            return provider.keychainKey
        }
        return "netdisk.\(driveKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
    }

    public func setNetdiskCredential(_ credential: String, for driveKey: String) throws {
        let key = driveKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard NetdiskProvider.fromKey(key) != nil else {
            throw MarcoError.invalidFormat("不支持的网盘类型：\(driveKey)")
        }
        guard NetdiskSessionValidator.isUsable(driveKey: key, credential: credential) else {
            throw MarcoError.invalidFormat("网盘凭据格式无效或缺少核心会话字段")
        }
        let normalized = NetdiskSessionValidator.normalizeCredential(driveKey: key, rawCredential: credential)
        try keychain.setData(Data(normalized.utf8), forAccount: Self.netdiskAccountKey(for: key))
    }

    public func netdiskCredential(for driveKey: String) -> String {
        let key = driveKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard NetdiskProvider.fromKey(key) != nil else { return "" }
        let primaryAccount = Self.netdiskAccountKey(for: key)
        if let data = try? keychain.data(forAccount: primaryAccount),
           let raw = String(data: data, encoding: .utf8),
           NetdiskSessionValidator.isUsable(driveKey: key, credential: raw)
        {
            return raw
        }
        let legacyAccount = "netdisk.\(key)"
        if legacyAccount != primaryAccount,
           let data = try? keychain.data(forAccount: legacyAccount),
           let raw = String(data: data, encoding: .utf8),
           NetdiskSessionValidator.isUsable(driveKey: key, credential: raw)
        {
            return raw
        }
        return ""
    }

    public func removeNetdiskCredential(for driveKey: String) throws {
        let key = driveKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        try keychain.removeData(forAccount: Self.netdiskAccountKey(for: key))
        try? keychain.removeData(forAccount: "netdisk.\(key)")
    }

    public func isNetdiskLoggedIn(_ driveKey: String) -> Bool {
        !netdiskCredential(for: driveKey).isEmpty
    }

    public func loggedInNetdiskDrives() -> [String] {
        NetdiskProvider.defaultOrder.map(\.rawValue).filter { isNetdiskLoggedIn($0) }
    }

    public func loadWebDavConfig() -> WebDavConfig {
        guard let data = try? keychain.data(forAccount: Self.accountWebDavSecret),
              let cfg = try? JSONDecoder().decode(WebDavConfig.self, from: data)
        else {
            return WebDavConfig()
        }
        return cfg
    }

    public func saveWebDavConfig(_ config: WebDavConfig) throws {
        let encoded = try JSONEncoder().encode(config)
        try keychain.setData(encoded, forAccount: Self.accountWebDavSecret)
    }

    public func hasPrivacyPin() -> Bool {
        guard let stored = storedPrivacyPinHash(), !stored.isEmpty else { return false }
        return true
    }

    public func privacyPinExpectedLength() -> Int {
        guard let stored = storedPrivacyPinHash(), !stored.isEmpty else { return 4 }
        return PrivacyPinCrypto.expectedLength(fromStored: stored)
    }

    public func storedPrivacyPinHash() -> String? {
        guard let data = try? keychain.data(forAccount: Self.accountPrivacyPin),
              let str = String(data: data, encoding: .utf8),
              !str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }
        return str.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func setStoredPrivacyPinHashVerbatim(_ storedHash: String) throws {
        let trimmed = storedHash.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try keychain.removeData(forAccount: Self.accountPrivacyPin)
        } else {
            try keychain.setData(Data(trimmed.utf8), forAccount: Self.accountPrivacyPin)
        }
    }

    public func setPrivacyPin(_ pin: String) throws {
        let trimmed = pin.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try keychain.removeData(forAccount: Self.accountPrivacyPin)
            return
        }
        let encoded = PrivacyPinCrypto.hashPin(trimmed)
        try keychain.setData(Data(encoded.utf8), forAccount: Self.accountPrivacyPin)
    }

    public func verifyPrivacyPin(_ pin: String) -> Bool {
        guard let stored = storedPrivacyPinHash(), !stored.isEmpty else {
            return true
        }
        let outcome = PrivacyPinCrypto.verify(input: pin, stored: stored)
        if outcome.matched && outcome.needsUpgrade {
            try? setPrivacyPin(pin)
        }
        return outcome.matched
    }

    // MARK: - Backup Export, Import & Reset

    public func exportBackupJson(exportedAt: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) throws -> String {
        let cfg = mergedConfig()
        lock.lock()
        let pubSubs = subscriptionsCache.compactMap { $0.sanitizedForPublicExport() }
        let safeHist = historyCache.filter { cfg.isPublicDisplayAllowed($0.site) }
        let safeFavs = favoritesCache.filter { cfg.isPublicDisplayAllowed($0.site) }
        var safePrefs = preferencesCache
        if cfg.isPrivateSiteKey(safePrefs.selectedSiteKey) { safePrefs.selectedSiteKey = "" }
        if cfg.isPrivateSiteKey(safePrefs.preferredSiteKey) { safePrefs.preferredSiteKey = "" }
        let payload = BackupPayload(
            exportedAt: exportedAt,
            origin: pubSubs.first?.url ?? "",
            rawConfig: pubSubs.first?.rawContent ?? "",
            subscriptions: pubSubs,
            watchHistory: safeHist,
            favorites: safeFavs,
            searchHistory: searchHistoryCache,
            preferences: safePrefs
        )
        lock.unlock()
        return try BackupCodec.encodeBackupJson(payload)
    }

    @discardableResult
    public func importBackupJson(_ rawBackup: String) throws -> CmsConfig {
        let decoded = try BackupCodec.decodeBackupJson(rawBackup)
        lock.lock()
        let retainedPrivateSubs = subscriptionsCache.filter { $0.isEffectivelyPrivate }
        let previousSubs = subscriptionsCache
        subscriptionsCache = decoded.subscriptions + retainedPrivateSubs
        syncMetadataTrackersLocked(additionalSubs: previousSubs)
        let privateCfg = Self.buildOwnershipConfig(
            from: subscriptionsCache,
            knownPrivateSubscriptionIds: knownPrivateSubscriptionIdsCache,
            knownPrivateSiteKeys: knownPrivateSiteKeysCache,
            ambiguousLegacyRawKeys: ambiguousLegacyRawKeysCache
        )
        let retainedPrivateHist = historyCache.filter { privateCfg.isPrivateSiteKey($0.site) }
        let retainedPrivateFavs = favoritesCache.filter { privateCfg.isPrivateSiteKey($0.site) }
        let incomingPublicHist = decoded.watchHistory.filter { !privateCfg.isPrivateSiteKey($0.site) }
        let incomingPublicFavs = decoded.favorites.filter { !privateCfg.isPrivateSiteKey($0.site) }
        historyCache = Array((incomingPublicHist + retainedPrivateHist).prefix(CmsParser.maxHistoryEntries))
        favoritesCache = Array((incomingPublicFavs + retainedPrivateFavs).prefix(CmsParser.maxFavoriteEntries))
        searchHistoryCache = Array(decoded.searchHistory.prefix(24))
        preferencesCache = decoded.preferences
        persistAllFilesLocked()
        lock.unlock()
        return mergedConfig()
    }

    public func resetAllData() throws {
        lock.lock()
        defer { lock.unlock() }
        subscriptionsCache = []
        favoritesCache = []
        privateFavoritesCache = []
        historyCache = []
        searchHistoryCache = []
        privateSearchHistoryCache = []
        preferencesCache = PlaybackPreferences()
        tombstonesCache = [:]
        videoSkipRecordsCache = [:]
        standaloneLivesCache = []
        siteOverridesCache = [:]
        danmuSettingsCache = DanmuSettings()
        danmuSyncDocCache = DanmuSourceSyncDocument()
        danmuSyncBaseDocCache = DanmuSourceSyncDocument()
        aiConfigCache = AiConfig()
        aiProfilesCache = []
        aiUsageCache = AiUsageSummary()
        embyAccountsCache = []
        mediaLibraryAccountsCache = []
        downloadTasksCache = []
        spiderGatewayCache = SpiderGatewayConfig()
        knownPrivateSubscriptionIdsCache = []
        knownPrivateSiteKeysCache = []
        ambiguousLegacyRawKeysCache = []
        transitionedToPrivateSubIdsCache = []
        transitionedToPrivateSiteKeysCache = []

        try? FileManager.default.removeItem(at: storageDirectory)
        try? FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
        try? keychain.removeData(forAccount: Self.accountWebDavSecret)
        try? keychain.removeData(forAccount: Self.accountPrivacyPin)
        try? keychain.removeData(forAccount: Self.accountSpiderGatewaySecret)
        try? keychain.removeData(forAccount: Self.accountAiApiKey)
        try? keychain.removeData(forAccount: Self.accountAiOAuthSession)
        try? keychain.removeData(forAccount: Self.accountAiLabToken)
        try? keychain.removeData(forAccount: Self.accountDanmuAppSecret)
        for provider in NetdiskProvider.allCases {
            try? keychain.removeData(forAccount: provider.keychainKey)
        }
    }

    // MARK: - Private Identity Trackers & Persistence Helpers

    private func syncMetadataTrackersLocked(additionalSubs: [SubscriptionEntry] = []) {
        var rawOwnersByKey: [String: Set<String>] = [:]
        var activePublicRawKeys = Set<String>()
        var activePrivateRawKeys = Set<String>()
        var activePublicSubIds = Set<String>()
        var previousPublicSiteKeys = Set<String>()
        var currentParsedSitesBySubId: [String: (isPrivate: Bool, sites: [(rawKey: String, canonicalKey: String, isPrivate: Bool)])] = [:]

        func inspectSub(_ sub: SubscriptionEntry, isCurrent: Bool) {
            let subPriv = sub.isEffectivelyPrivate
            if !sub.id.isEmpty {
                if subPriv {
                    knownPrivateSubscriptionIdsCache.insert(sub.id)
                } else if isCurrent {
                    activePublicSubIds.insert(sub.id)
                }
            }
            guard !sub.rawContent.isEmpty,
                  let cfg = try? CmsParser.parseConfig(
                      sub.rawContent,
                      origin: sub.url,
                      defaultGroup: sub.group,
                      isPrivate: subPriv,
                      subscriptionId: sub.id,
                      defaultName: sub.name
                  )
            else {
                return
            }
            var intraCounts: [String: Int] = [:]
            var entries: [(rawKey: String, canonicalKey: String, isPrivate: Bool)] = []
            for site in cfg.sites {
                let raw = site.rawKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? site.key : site.rawKey
                let occ = intraCounts[raw, default: 0]
                intraCounts[raw] = occ + 1
                let disambig = occ == 0 ? raw : "\(raw)#\(occ + 1)"
                let canonical = CmsSite.canonicalScopedKey(rawKey: disambig, subscriptionId: sub.id)
                let ownerTag = sub.id.isEmpty ? sub.url : sub.id
                let sitePriv = subPriv || site.isEffectivelyPrivate
                rawOwnersByKey[raw, default: []].insert(ownerTag)
                if sitePriv {
                    activePrivateRawKeys.insert(raw)
                    knownPrivateSiteKeysCache.insert(canonical)
                    if !sub.id.isEmpty {
                        knownPrivateSiteKeysCache.insert("\(raw)_\(sub.id)")
                    }
                } else if isCurrent {
                    activePublicRawKeys.insert(raw)
                } else {
                    previousPublicSiteKeys.insert(canonical)
                }
                entries.append((raw, canonical, sitePriv))
            }
            if isCurrent {
                currentParsedSitesBySubId[sub.id] = (subPriv, entries)
            }
        }

        for prevSub in additionalSubs { inspectSub(prevSub, isCurrent: false) }
        for curSub in subscriptionsCache { inspectSub(curSub, isCurrent: true) }

        for curKey in previousPublicSiteKeys where knownPrivateSiteKeysCache.contains(curKey) {
            transitionedToPrivateSiteKeysCache.insert(curKey)
        }
        for (rawKey, ownerIds) in rawOwnersByKey where ownerIds.count > 1 {
            ambiguousLegacyRawKeysCache.insert(rawKey)
        }
        for raw in activePrivateRawKeys where !activePublicRawKeys.contains(raw) {
            knownPrivateSiteKeysCache.insert(raw)
        }
        for pubSubId in activePublicSubIds {
            knownPrivateSubscriptionIdsCache.remove(pubSubId)
            transitionedToPrivateSubIdsCache.remove(pubSubId)
            if let info = currentParsedSitesBySubId[pubSubId], !info.isPrivate {
                for entry in info.sites where !entry.isPrivate {
                    knownPrivateSiteKeysCache.remove(entry.canonicalKey)
                    knownPrivateSiteKeysCache.remove("\(entry.rawKey)_\(pubSubId)")
                    transitionedToPrivateSiteKeysCache.remove(entry.canonicalKey)
                    if !activePrivateRawKeys.contains(entry.rawKey) {
                        knownPrivateSiteKeysCache.remove(entry.rawKey)
                    }
                }
            }
        }
    }

    private func isUnambiguousLegacyRawKeyLocked(_ rawKey: String, forSubscriptionId subId: String) -> Bool {
        let clean = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty,
              !ambiguousLegacyRawKeysCache.contains(clean),
              !knownPrivateSiteKeysCache.contains(clean)
        else {
            return false
        }
        var matchingSubIds = Set<String>()
        for sub in subscriptionsCache where !sub.rawContent.isEmpty {
            guard let cfg = try? CmsParser.parseConfig(
                sub.rawContent,
                origin: sub.url,
                defaultGroup: sub.group,
                isPrivate: sub.isEffectivelyPrivate,
                subscriptionId: sub.id,
                defaultName: sub.name
            ) else { continue }
            if cfg.sites.contains(where: {
                let raw = $0.rawKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? $0.key : $0.rawKey
                return raw == clean
            }) {
                matchingSubIds.insert(sub.id)
            }
        }
        return matchingSubIds == [subId]
    }

    private func persistPrivacyMetaLocked() {
        let meta = PrivacyAndIdentityMetadata(
            knownPrivateSubscriptionIds: Array(knownPrivateSubscriptionIdsCache).sorted(),
            knownPrivateSiteKeys: Array(knownPrivateSiteKeysCache).sorted(),
            ambiguousLegacyRawKeys: Array(ambiguousLegacyRawKeysCache).sorted(),
            transitionedToPrivateSubIds: Array(transitionedToPrivateSubIdsCache).sorted(),
            transitionedToPrivateSiteKeys: Array(transitionedToPrivateSiteKeysCache).sorted()
        )
        writeCodableAtomically(meta, to: file("privacy_meta.json"))
    }

    private func persistAllFilesLocked() {
        try? FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
        writeCodableAtomically(subscriptionsCache, to: file("subscriptions.json"))
        writeCodableAtomically(favoritesCache, to: file("favorites.json"))
        writeCodableAtomically(privateFavoritesCache, to: file("private_favorites.json"))
        writeCodableAtomically(historyCache, to: file("history.json"))
        writeCodableAtomically(preferencesCache, to: file("preferences.json"))
        writeCodableAtomically(tombstonesCache, to: file("tombstones.json"))
        writeCodableAtomically(searchHistoryCache, to: file("search_history.json"))
        writeCodableAtomically(embyAccountsCache, to: file("emby_accounts.json"))
        persistPrivacyMetaLocked()
    }

    private func recordTombstoneLocked(key: String, timestampMs: Int64) {
        guard !key.isEmpty, timestampMs > 0 else { return }
        tombstonesCache[key] = timestampMs
        boundTombstonesLocked()
        writeCodableAtomically(tombstonesCache, to: file("tombstones.json"))
    }

    private func boundTombstonesLocked() {
        guard tombstonesCache.count > Self.maxSyncTombstones else { return }
        let sorted = tombstonesCache.sorted { $0.value > $1.value }.prefix(Self.maxSyncTombstones)
        tombstonesCache = Dictionary(uniqueKeysWithValues: sorted.map { ($0.key, $0.value) })
    }

    private func file(_ name: String) -> URL {
        storageDirectory.appendingPathComponent(name)
    }

    private func readCodable<T: Decodable>(from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func writeCodableAtomically<T: Encodable>(_ value: T, to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url, options: [.atomic])
    }
}
