// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only

import CryptoKit
import Foundation

// MARK: - Core Error Domain

public enum MarcoError: LocalizedError, Equatable, Sendable {
    case emptyConfiguration
    case invalidFormat(String)
    case networkFailure(String)
    case unsupportedSite(String)
    case unsupported(String)
    case scriptExecutionFailed(String)
    case webdavError(String)
    case storageError(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .emptyConfiguration:
            return "配置内容为空"
        case .invalidFormat(let detail):
            return detail
        case .networkFailure(let detail):
            return detail
        case .unsupportedSite(let detail):
            return detail
        case .unsupported(let detail):
            return detail
        case .scriptExecutionFailed(let detail):
            return detail
        case .webdavError(let detail):
            return detail
        case .storageError(let detail):
            return detail
        case .cancelled:
            return "操作已取消"
        }
    }
}

// MARK: - Subscriptions, Depots & Sites

public struct CmsDepot: Codable, Hashable, Identifiable, Sendable {
    public var id: String { "\(subscriptionId)|\(name)|\(url)" }
    public var name: String
    public var url: String
    public var subscriptionId: String
    public var isPrivate: Bool

    private enum CodingKeys: String, CodingKey {
        case name
        case url
        case subscriptionId
        case isPrivate
    }

    public init(name: String, url: String, subscriptionId: String = "", isPrivate: Bool = false) {
        self.name = name
        self.url = url
        self.subscriptionId = subscriptionId
        self.isPrivate = isPrivate
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        self.url = try container.decodeIfPresent(String.self, forKey: .url) ?? ""
        self.subscriptionId = try container.decodeIfPresent(String.self, forKey: .subscriptionId) ?? ""
        self.isPrivate = try container.decodeIfPresent(Bool.self, forKey: .isPrivate) ?? false
    }
}

public struct SubscriptionEntry: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var url: String
    public var group: String
    public var format: String
    public var isPrivate: Bool
    public var enabled: Bool
    public var rawContent: String
    public var siteCount: Int
    public var liveCount: Int
    public var updatedAt: Int64
    public var warehouseUrl: String
    public var activeDepotUrl: String
    public var activeDepotName: String
    public var depots: [CmsDepot]

    private enum CodingKeys: String, CodingKey {
        case id, name, url, group, format, isPrivate, enabled, rawContent
        case siteCount, liveCount, updatedAt, warehouseUrl, activeDepotUrl, activeDepotName, depots
    }

    public init(
        id: String,
        name: String,
        url: String = "",
        group: String = "默认分组",
        format: String = "JSON",
        isPrivate: Bool = false,
        enabled: Bool = true,
        rawContent: String = "",
        siteCount: Int = 0,
        liveCount: Int = 0,
        updatedAt: Int64 = 0,
        warehouseUrl: String = "",
        activeDepotUrl: String = "",
        activeDepotName: String = "",
        depots: [CmsDepot] = []
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.group = group.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "默认分组" : group
        self.format = format.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "JSON" : format
        self.isPrivate = isPrivate
        self.enabled = enabled
        self.rawContent = rawContent
        self.siteCount = siteCount
        self.liveCount = liveCount
        self.updatedAt = updatedAt
        self.warehouseUrl = warehouseUrl
        self.activeDepotUrl = activeDepotUrl
        self.activeDepotName = activeDepotName
        self.depots = depots
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawGroup = try c.decodeIfPresent(String.self, forKey: .group) ?? "默认分组"
        let rawFmt = try c.decodeIfPresent(String.self, forKey: .format) ?? "JSON"
        self.id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        self.name = try c.decodeIfPresent(String.self, forKey: .name) ?? "订阅源"
        self.url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        self.group = rawGroup.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "默认分组" : rawGroup
        self.format = rawFmt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "JSON" : rawFmt
        self.isPrivate = try c.decodeIfPresent(Bool.self, forKey: .isPrivate) ?? false
        self.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        self.rawContent = try c.decodeIfPresent(String.self, forKey: .rawContent) ?? ""
        self.siteCount = try c.decodeIfPresent(Int.self, forKey: .siteCount) ?? 0
        self.liveCount = try c.decodeIfPresent(Int.self, forKey: .liveCount) ?? 0
        self.updatedAt = try c.decodeIfPresent(Int64.self, forKey: .updatedAt) ?? 0
        self.warehouseUrl = try c.decodeIfPresent(String.self, forKey: .warehouseUrl) ?? ""
        self.activeDepotUrl = try c.decodeIfPresent(String.self, forKey: .activeDepotUrl) ?? ""
        self.activeDepotName = try c.decodeIfPresent(String.self, forKey: .activeDepotName) ?? ""
        self.depots = try c.decodeIfPresent([CmsDepot].self, forKey: .depots) ?? []
    }

    public var isEffectivelyPrivate: Bool {
        isPrivate || group.contains("隐私") || group.contains("私密")
    }

    public func sanitizedForPublicExport() -> SubscriptionEntry? {
        guard !isEffectivelyPrivate else { return nil }
        var copy = self
        copy.isPrivate = false
        copy.depots = depots.filter { !$0.isPrivate }
        let sanitizedRaw = CmsParser.sanitizePublicRawConfig(rawContent, defaultGroup: group)
        if !rawContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && sanitizedRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && copy.depots.isEmpty
        {
            return nil
        }
        if sanitizedRaw != rawContent {
            copy.rawContent = sanitizedRaw
            if let parsed = try? CmsParser.parseConfig(
                sanitizedRaw,
                origin: url,
                defaultGroup: group,
                isPrivate: false,
                subscriptionId: id,
                defaultName: name
            ) {
                copy.siteCount = parsed.sites.count
                copy.liveCount = parsed.lives.count
            } else {
                copy.siteCount = 0
                copy.liveCount = 0
            }
        }
        return copy
    }

    public func toDictionary() -> [String: Any] {
        var out: [String: Any] = [
            "id": id,
            "name": name,
            "url": url,
            "group": group,
            "format": format,
            "isPrivate": isEffectivelyPrivate,
            "enabled": enabled,
            "rawContent": rawContent,
            "siteCount": siteCount,
            "liveCount": liveCount,
            "updatedAt": updatedAt,
            "warehouseUrl": warehouseUrl,
            "activeDepotName": activeDepotName,
            "depots": depots.map { [
                "name": $0.name,
                "url": $0.url,
                "subscriptionId": $0.subscriptionId,
            ] },
        ]
        if !activeDepotUrl.isEmpty {
            out["activeDepotUrl"] = activeDepotUrl
        }
        return out
    }

    public static func fromDictionary(_ dict: [String: Any]) -> SubscriptionEntry {
        let rawGroup = Self.cleanString(dict["group"])
        let cleanGroup = rawGroup.isEmpty ? "默认分组" : rawGroup
        let rawFmt = Self.cleanString(dict["format"])
        let cleanFmt = rawFmt.isEmpty ? "JSON" : rawFmt
        let space = Self.cleanString(dict["space"]).lowercased()
        let priv = Self.cleanBool(dict["isPrivate"], fallback: false)
            || Self.cleanBool(dict["private"], fallback: false)
            || Self.cleanBool(dict["hidden"], fallback: false)
            || space == "private"
            || cleanGroup.contains("隐私")
            || cleanGroup.contains("私密")
        let depotsRaw = dict["depots"] as? [[String: Any]] ?? []
        let depots = depotsRaw.map { d in
            CmsDepot(
                name: Self.cleanString(d["name"]),
                url: Self.cleanString(d["url"]),
                subscriptionId: Self.cleanString(d["subscriptionId"]),
                isPrivate: priv || Self.cleanBool(d["isPrivate"], fallback: false)
            )
        }
        let parsedName = Self.cleanString(dict["name"])
        return SubscriptionEntry(
            id: Self.cleanString(dict["id"]),
            name: parsedName.isEmpty ? "订阅源" : parsedName,
            url: Self.cleanString(dict["url"]),
            group: cleanGroup,
            format: cleanFmt,
            isPrivate: priv,
            enabled: Self.cleanBool(dict["enabled"], fallback: true),
            rawContent: Self.rawString(dict["rawContent"]),
            siteCount: Int(Self.cleanInt64(dict["siteCount"], fallback: 0)),
            liveCount: Int(Self.cleanInt64(dict["liveCount"], fallback: 0)),
            updatedAt: Self.cleanInt64(dict["updatedAt"], fallback: 0),
            warehouseUrl: Self.cleanString(dict["warehouseUrl"]),
            activeDepotUrl: Self.cleanString(dict["activeDepotUrl"]),
            activeDepotName: Self.cleanString(dict["activeDepotName"]),
            depots: depots
        )
    }

    private static func rawString(_ any: Any?) -> String {
        guard let any = any, !(any is NSNull) else { return "" }
        if let s = any as? String { return s }
        if let n = any as? NSNumber { return n.stringValue }
        return ""
    }

    private static func cleanString(_ any: Any?) -> String {
        rawString(any).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func cleanBool(_ any: Any?, fallback: Bool) -> Bool {
        guard let any = any, !(any is NSNull) else { return fallback }
        if let b = any as? Bool { return b }
        if let n = any as? NSNumber { return n.intValue != 0 }
        if let s = any as? String {
            let lower = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ["1", "true", "yes"].contains(lower) { return true }
            if ["0", "false", "no"].contains(lower) { return false }
        }
        return fallback
    }

    private static func cleanInt64(_ any: Any?, fallback: Int64) -> Int64 {
        guard let any = any, !(any is NSNull) else { return fallback }
        if let n = any as? NSNumber { return n.int64Value }
        if let s = any as? String, let v = Int64(s.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return v
        }
        return fallback
    }
}

public struct SiteOverride: Codable, Hashable, Sendable {
    public var name: String?
    public var group: String?
    public var api: String?
    public var playUrl: String?
    public var ext: String?
    public var searchable: Bool?

    public init(
        name: String? = nil,
        group: String? = nil,
        api: String? = nil,
        playUrl: String? = nil,
        ext: String? = nil,
        searchable: Bool? = nil
    ) {
        self.name = name
        self.group = group
        self.api = api
        self.playUrl = playUrl
        self.ext = ext
        self.searchable = searchable
    }

    public var isEmpty: Bool {
        name == nil && group == nil && api == nil && playUrl == nil && ext == nil && searchable == nil
    }

    public func applyTo(_ site: CmsSite) -> CmsSite {
        guard !isEmpty else { return site }
        var nextType = site.type
        let nextApiTrimmed = api?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let nextApi = nextApiTrimmed, !nextApi.isEmpty, nextApi != site.api {
            let lower = nextApi.lowercased()
            if (lower.hasPrefix("http://") || lower.hasPrefix("https://"))
                && !lower.hasSuffix(".js")
                && !lower.hasSuffix(".mjs")
                && !lower.hasSuffix(".py")
                && !lower.hasSuffix(".jar")
                && nextType != 0
                && nextType != 1
                && nextType != 4
            {
                nextType = lower.contains("xml") ? 0 : 1
            }
        }
        let nextPlayUrl = playUrl.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? site.playUrl
        let nextExt = ext ?? site.ext
        let nextName: String = {
            if let n = name?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty { return n }
            return site.name
        }()
        let nextGroup: String = {
            if let g = group?.trimmingCharacters(in: .whitespacesAndNewlines), !g.isEmpty { return g }
            return site.group
        }()
        return CmsSite(
            key: site.key,
            rawKey: site.rawKey,
            originalKey: site.sourceKey,
            originalApi: site.sourceApi,
            name: nextName,
            type: nextType,
            api: (nextApiTrimmed != nil && !nextApiTrimmed!.isEmpty) ? nextApiTrimmed! : site.api,
            playUrl: nextPlayUrl,
            searchable: searchable ?? site.searchable,
            ext: nextExt,
            extTooLarge: ext != nil ? (nextExt.utf16.count > CmsSite.maxExtSize) : site.extTooLarge,
            requiresParser: playUrl != nil ? !nextPlayUrl.isEmpty : site.requiresParser,
            rawExtension: ext != nil ? (nextExt.isEmpty ? nil : nextExt) : site.rawExtension,
            jar: site.jar,
            spider: site.spider,
            headers: site.headers,
            ua: site.ua,
            categories: site.categories,
            group: nextGroup,
            isPrivate: site.isPrivate,
            subscriptionId: site.subscriptionId
        )
    }
}

public struct CmsParse: Codable, Hashable, Identifiable, Sendable {
    public var id: String { "\(name)|\(type)|\(url)" }
    public var name: String
    public var url: String
    public var type: Int
    public var headers: [String: String]

    public init(name: String, url: String, type: Int = 0, headers: [String: String] = [:]) {
        self.name = name
        self.url = url
        self.type = type
        self.headers = headers
    }
}

public struct CmsSniffRule: Codable, Hashable, Sendable {
    public var name: String
    public var hosts: [String]
    public var regex: [String]
    public var exclude: [String]
    public var script: String
    public var click: String

    private enum CodingKeys: String, CodingKey {
        case name, hosts, regex, exclude, script, click
    }

    public init(
        name: String = "",
        hosts: [String] = [],
        regex: [String] = [],
        exclude: [String] = [],
        script: String = "",
        click: String = ""
    ) {
        self.name = name
        self.hosts = hosts
        self.regex = regex
        self.exclude = exclude
        self.script = script
        self.click = click
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        self.hosts = try c.decodeIfPresent([String].self, forKey: .hosts) ?? []
        self.regex = try c.decodeIfPresent([String].self, forKey: .regex) ?? []
        self.exclude = try c.decodeIfPresent([String].self, forKey: .exclude) ?? []
        self.script = try c.decodeIfPresent(String.self, forKey: .script) ?? ""
        self.click = try c.decodeIfPresent(String.self, forKey: .click) ?? ""
    }

    public var isEmpty: Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && hosts.isEmpty
            && regex.isEmpty
            && exclude.isEmpty
            && script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && click.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var effectiveScript: String {
        let c = click.trimmingCharacters(in: .whitespacesAndNewlines)
        return c.isEmpty ? script.trimmingCharacters(in: .whitespacesAndNewlines) : c
    }

    public var combinedClickScript: String {
        let s = script.trimmingCharacters(in: .whitespacesAndNewlines)
        let c = click.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedClick = c.isEmpty ? "" : Self.normalizeClickSnippet(c)
        if !s.isEmpty && !normalizedClick.isEmpty {
            return s == normalizedClick ? s : "\(s)\n\(normalizedClick)"
        }
        return !s.isEmpty ? s : normalizedClick
    }

    private static func normalizeClickSnippet(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let looksLikeJs = trimmed.contains("(")
            || trimmed.contains(";")
            || trimmed.contains("=")
            || trimmed.contains("{")
            || trimmed.contains("=>")
            || trimmed.contains("\n")
        if looksLikeJs { return trimmed }
        if let jsonData = try? JSONSerialization.data(withJSONObject: [trimmed]),
           let arr = String(data: jsonData, encoding: .utf8),
           arr.count >= 2
        {
            let quoted = String(arr.dropFirst().dropLast())
            return "try{var _el=document.querySelector(\(quoted));if(_el)_el.click();}catch(_){}"
        }
        return ""
    }

    public func matchesHost(_ host: String) -> Bool {
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedHost.isEmpty, !hosts.isEmpty else { return false }
        for rawPattern in hosts {
            let pattern = rawPattern.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !pattern.isEmpty else { continue }
            if pattern == "*" { return true }
            if pattern.hasPrefix("*.") {
                let suffix = String(pattern.dropFirst(2))
                if !suffix.isEmpty && (normalizedHost == suffix || normalizedHost.hasSuffix(".\(suffix)")) {
                    return true
                }
                continue
            }
            if pattern.hasPrefix(".") {
                let suffix = String(pattern.dropFirst())
                if !suffix.isEmpty && (normalizedHost == suffix || normalizedHost.hasSuffix(".\(suffix)")) {
                    return true
                }
                continue
            }
            if pattern.contains("*") {
                let escaped = NSRegularExpression.escapedPattern(for: pattern).replacingOccurrences(of: "\\*", with: ".*")
                if let re = try? NSRegularExpression(pattern: "^\(escaped)$", options: [.caseInsensitive]),
                   re.firstMatch(in: normalizedHost, range: NSRange(normalizedHost.startIndex..., in: normalizedHost)) != nil
                {
                    return true
                }
                continue
            }
            if normalizedHost == pattern || normalizedHost.hasSuffix(".\(pattern)") {
                return true
            }
        }
        return false
    }

    public static func fromDictionary(_ dict: [String: Any]) -> CmsSniffRule {
        func strList(_ raw: Any?) -> [String] {
            if let arr = raw as? [Any] {
                return arr.compactMap { item -> String? in
                    guard !(item is NSNull) else { return nil }
                    let s = String(describing: item).trimmingCharacters(in: .whitespacesAndNewlines)
                    return s.isEmpty ? nil : s
                }
            }
            if let s = raw as? String {
                let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? [] : [trimmed]
            }
            return []
        }
        return CmsSniffRule(
            name: (dict["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            hosts: strList(dict["hosts"] ?? dict["host"]),
            regex: strList(dict["regex"]),
            exclude: strList(dict["exclude"] ?? dict["excludes"]),
            script: (dict["script"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            click: (dict["click"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        )
    }

    public func toDictionary() -> [String: Any] {
        var out: [String: Any] = [:]
        if !name.isEmpty { out["name"] = name }
        if !hosts.isEmpty { out["hosts"] = hosts }
        if !regex.isEmpty { out["regex"] = regex }
        if !exclude.isEmpty { out["exclude"] = exclude }
        if !script.isEmpty { out["script"] = script }
        if !click.isEmpty { out["click"] = click }
        return out
    }
}

public struct CmsSite: Codable, Hashable, Identifiable, Sendable {
    public static let statusOk = "ok"
    public static let statusNeedsJar = "needs-jar"
    public static let statusUnsupportedType = "unsupported-type"
    public static let statusAdapterMissing = "adapter-missing"
    public static let statusExtTooLarge = "ext-too-large"
    public static let statusCustomSiteUrl = "custom-site-url"
    public static let statusParserRequired = "parser-required"
    public static let statusCatPawNodeRequired = "catpaw-node-required"
    public static let statusPythonRuntimeRequired = "python-runtime-required"
    public static let maxExtSize = 128 * 1024

    public static let scopedSiteKeyPrefix = "sub::"

    public static func canonicalScopedKey(rawKey: String, subscriptionId: String) -> String {
        let cleanRaw = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanSub = subscriptionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanSub.isEmpty else { return cleanRaw }
        if cleanRaw.hasPrefix(scopedSiteKeyPrefix) { return cleanRaw }
        return "\(scopedSiteKeyPrefix)\(cleanSub)::\(cleanRaw)"
    }

    public static func parseScopedKey(_ siteKey: String) -> (subscriptionId: String, rawKey: String)? {
        guard siteKey.hasPrefix(scopedSiteKeyPrefix) else { return nil }
        let rest = siteKey.dropFirst(scopedSiteKeyPrefix.count)
        guard let sep = rest.range(of: "::") else { return nil }
        let subId = String(rest[..<sep.lowerBound])
        let raw = String(rest[sep.upperBound...])
        guard !subId.isEmpty, !raw.isEmpty else { return nil }
        return (subId, raw)
    }

    public var id: String { key }
    public var key: String
    public var rawKey: String
    public var originalKey: String?
    public var originalApi: String?
    public var name: String
    public var type: Int
    public var api: String
    public var playUrl: String
    public var searchable: Bool
    public var ext: String
    public var extTooLarge: Bool
    public var requiresParser: Bool
    public var rawExtension: String?
    public var jar: String
    public var spider: String
    public var headers: [String: String]
    public var ua: String
    public var categories: [String]
    public var group: String
    public var isPrivate: Bool
    public var subscriptionId: String

    public var sourceKey: String { originalKey ?? rawKey }
    public var sourceApi: String { originalApi ?? api }

    private enum CodingKeys: String, CodingKey {
        case key, rawKey, originalKey, originalApi, name, type, api, playUrl, searchable
        case ext, extTooLarge, requiresParser, rawExtension, jar, spider, headers, ua
        case categories, group, isPrivate, subscriptionId
    }

    public init(
        key: String,
        rawKey: String? = nil,
        originalKey: String? = nil,
        originalApi: String? = nil,
        name: String,
        type: Int,
        api: String,
        playUrl: String = "",
        searchable: Bool = true,
        ext: String = "",
        extTooLarge: Bool = false,
        requiresParser: Bool = false,
        rawExtension: String? = nil,
        jar: String = "",
        spider: String = "",
        headers: [String: String] = [:],
        ua: String = "",
        categories: [String] = [],
        group: String = "默认分组",
        isPrivate: Bool = false,
        subscriptionId: String = ""
    ) {
        self.key = key
        self.rawKey = rawKey ?? CmsSite.parseScopedKey(key)?.rawKey ?? key
        self.originalKey = originalKey
        self.originalApi = originalApi
        self.name = name
        self.type = type
        self.api = api
        self.playUrl = playUrl
        self.searchable = searchable
        self.ext = ext
        self.extTooLarge = extTooLarge
        self.requiresParser = requiresParser
        self.rawExtension = rawExtension
        self.jar = jar
        self.spider = spider
        self.headers = headers
        self.ua = ua
        self.categories = categories
        self.group = group
        self.isPrivate = isPrivate
        self.subscriptionId = subscriptionId
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let decodedKey = try c.decode(String.self, forKey: .key)
        self.key = decodedKey
        self.rawKey = try c.decodeIfPresent(String.self, forKey: .rawKey)
            ?? CmsSite.parseScopedKey(decodedKey)?.rawKey
            ?? decodedKey
        self.originalKey = try c.decodeIfPresent(String.self, forKey: .originalKey)
        self.originalApi = try c.decodeIfPresent(String.self, forKey: .originalApi)
        self.name = try c.decode(String.self, forKey: .name)
        self.type = try c.decode(Int.self, forKey: .type)
        self.api = try c.decode(String.self, forKey: .api)
        self.playUrl = try c.decodeIfPresent(String.self, forKey: .playUrl) ?? ""
        self.searchable = try c.decodeIfPresent(Bool.self, forKey: .searchable) ?? true
        self.ext = try c.decodeIfPresent(String.self, forKey: .ext) ?? ""
        self.extTooLarge = try c.decodeIfPresent(Bool.self, forKey: .extTooLarge) ?? false
        self.requiresParser = try c.decodeIfPresent(Bool.self, forKey: .requiresParser) ?? false
        self.rawExtension = try c.decodeIfPresent(String.self, forKey: .rawExtension)
        self.jar = try c.decodeIfPresent(String.self, forKey: .jar) ?? ""
        self.spider = try c.decodeIfPresent(String.self, forKey: .spider) ?? ""
        self.headers = try c.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
        self.ua = try c.decodeIfPresent(String.self, forKey: .ua) ?? ""
        self.categories = try c.decodeIfPresent([String].self, forKey: .categories) ?? []
        self.group = try c.decodeIfPresent(String.self, forKey: .group) ?? "默认分组"
        self.isPrivate = try c.decodeIfPresent(Bool.self, forKey: .isPrivate) ?? false
        self.subscriptionId = try c.decodeIfPresent(String.self, forKey: .subscriptionId) ?? ""
    }

    public var pluginReference: String {
        !jar.isEmpty ? jar : spider
    }

    public var isExtTooLarge: Bool {
        extTooLarge || ext.utf16.count > Self.maxExtSize
    }

    public var isHttpApi: Bool {
        let lower = api.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lower.hasPrefix("http://") || lower.hasPrefix("https://")
    }

    public var isM3uVodApi: Bool {
        api.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("m3u_vod://")
    }

    public var isCatPaw: Bool {
        api.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("catpaw://")
    }

    public var isExternalMediaLibrary: Bool {
        let lower = api.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let prefixes = [
            "emby://account/",
            "jellyfin://account/",
            "plex://account/",
            "webdavlib://account/",
            "alist://account/",
            "smbnas://account/",
            "localfile://account/",
            "cloudlib://account/",
        ]
        return prefixes.contains { lower.hasPrefix($0) }
    }

    private var cleanApiPath: String {
        let trimmed = api.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let noFragment = trimmed.components(separatedBy: "#").first ?? trimmed
        let noQuery = noFragment.components(separatedBy: "?").first ?? noFragment
        return noQuery
    }

    public var isJavaScriptSource: Bool {
        api == "csp_LocalScript.js"
            || (type == 3 && isHttpApi && (cleanApiPath.hasSuffix(".js") || cleanApiPath.hasSuffix(".mjs")))
    }

    public var isPythonSource: Bool {
        api == "csp_LocalScript.py"
            || (type == 3 && isHttpApi && cleanApiPath.hasSuffix(".py"))
    }

    public var isRemoteScriptSource: Bool {
        type == 3
            && isHttpApi
            && !cleanApiPath.hasSuffix(".jar")
            && !cleanApiPath.hasSuffix(".py")
    }

    public var isDrpySource: Bool {
        let lower = api.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return api == "csp_LocalRule.js"
            || lower == "csp_drpy"
            || (type == 3 && isHttpApi && (cleanApiPath.hasSuffix("drpy2.min.js") || cleanApiPath.hasSuffix("drpy2.js")))
    }

    public var isCspRuleEngine: Bool {
        let lower = api.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let engines: Set<String> = [
            "csp_xbpq", "csp_xbpqguard",
            "csp_xyq", "csp_xyqguard",
            "csp_xpath", "csp_xpathguard",
            "csp_xpathfilter", "csp_xpathfilterguard",
            "csp_xpathmac", "csp_xpathmacfilter",
        ]
        return engines.contains(lower) && !ext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var isWoggNetdiskSource: Bool {
        WoggNetdiskSource.supports(self)
    }

    public var guardAdapterKey: String? {
        guard type == 3 else { return nil }
        return Self.guardAdapterMap[api.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()]
    }

    public var isGuardPortedSource: Bool {
        guardAdapterKey != nil && !pluginReference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public static let guardAdapterMap: [String: String] = [
        "csp_dm84guard": "dm84-v1",
        "csp_dm84": "dm84-v1",
        "csp_aueteguard": "auete-v1",
        "csp_auete": "auete-v1",
        "csp_bttwooguard": "bttwoo-v1",
        "csp_bttwoo": "bttwoo-v1",
        "csp_appgzguard": "appgz-v1",
        "csp_appgz": "appgz-v1",
        "csp_t4guard": "t4-v1",
        "csp_t4": "t4-v1",
        "csp_appttguard": "apptt-v1",
        "csp_apptt": "apptt-v1",
        "csp_fyguard": "fy-v1",
        "csp_fy": "fy-v1",
        "csp_jpysguard": "jpys-v1",
        "csp_jpys": "jpys-v1",
        "csp_jpjguard": "jpj-v1",
        "csp_jpj": "jpj-v1",
        "csp_nmyswvguard": "nmyswv-v1",
        "csp_nmyswv": "nmyswv-v1",
        "csp_hmysguard": "hmys-v1",
        "csp_hmys": "hmys-v1",
        "csp_app99guard": "app99-v1",
        "csp_app99": "app99-v1",
        "csp_appsxguard": "appsx-v1",
        "csp_appsx": "appsx-v1",
        "csp_newczguard": "newcz-v1",
        "csp_newcz": "newcz-v1",
        "csp_libvioguard": "libvio-v1",
        "csp_libvio": "libvio-v1",
        "csp_ygpguard": "ygp-v1",
        "csp_ygp": "ygp-v1",
        "csp_kanqiuguard": "kanqiu-v1",
        "csp_kanqiu": "kanqiu-v1",
        "csp_doubaoguard": "doubao-v1",
        "csp_doubao": "doubao-v1",
        "csp_livegzguard": "livegz-v1",
        "csp_livegz": "livegz-v1",
        "csp_allliveguard": "alllive-v1",
        "csp_alllive": "alllive-v1",
        "csp_tingshu275guard": "tingshu275-v1",
        "csp_tingshu275": "tingshu275-v1",
        "csp_yuetingguard": "yueting-v1",
        "csp_yueting": "yueting-v1",
        "csp_seedhubguard": "seedhub-v1",
        "csp_seedhub": "seedhub-v1",
        "csp_s_zpsguard": "szps-v1",
        "csp_s_zps": "szps-v1",
        "csp_ypansoguard": "ypanso-v1",
        "csp_ypanso": "ypanso-v1",
        "csp_bpansoguard": "bpanso-v1",
        "csp_bpanso": "bpanso-v1",
        "csp_kkssguard": "kkss-v1",
        "csp_kkss": "kkss-v1",
        "csp_uussguard": "uuss-v1",
        "csp_uuss": "uuss-v1",
        "csp_wexappv7guard": "wexappv7-v1",
        "csp_wexappv7": "wexappv7-v1",
        "csp_wexaiguaziguard": "wexguazi-v1",
        "csp_wexaiguazi": "wexguazi-v1",
        "csp_wexaidubokuguard": "wexduboku-v1",
        "csp_wexaiduboku": "wexduboku-v1",
        "csp_wexaiwencaiguard": "wexwencai-v1",
        "csp_wexaiwencai": "wexwencai-v1",
        "csp_wexfengye4kguard": "wexfengye-v1",
        "csp_wexfengye4k": "wexfengye-v1",
        "csp_wexaifengyeguard": "wexfengye-v1",
        "csp_wexaifengye": "wexfengye-v1",
        "csp_wexaijianpianguard": "wexjianpian-v1",
        "csp_wexaijianpian": "wexjianpian-v1",
        "csp_wexaijuxiafanguard": "wexjuxiafan-v1",
        "csp_wexaijuxiafan": "wexjuxiafan-v1",
        "csp_wexaireboguard": "wexrebo-v1",
        "csp_wexairebo": "wexrebo-v1",
        "csp_wexaiboboguard": "wexbobo-v1",
        "csp_wexaibobo": "wexbobo-v1",
        "csp_wexaiikanbotguard": "wexikanbot-v1",
        "csp_wexaiikanbot": "wexikanbot-v1",
        "csp_ainewikanbotguard": "wexikanbot-v1",
        "csp_ainewikanbot": "wexikanbot-v1",
        "csp_wexaiyiysguard": "wexyiys-v1",
        "csp_wexaiyiys": "wexyiys-v1",
        "csp_ainewyiysguard": "wexyiys-v1",
        "csp_ainewyiys": "wexyiys-v1",
        "csp_wexaihanxiaoquanguard": "wexhanxiaoquan-v1",
        "csp_wexaihanxiaoquan": "wexhanxiaoquan-v1",
        "csp_ainewduoduoguard": "wexduoduo-v1",
        "csp_ainewduoduo": "wexduoduo-v1",
        "csp_ainewhubanguard": "wexhuban-v1",
        "csp_ainewhuban": "wexhuban-v1",
        "csp_ainewkuaiyingguard": "wexkuaiying-v1",
        "csp_ainewkuaiying": "wexkuaiying-v1",
        "csp_ainewlabiguard": "wexlabi-v1",
        "csp_ainewlabi": "wexlabi-v1",
        "csp_ainewmuouguard": "wexmuou-v1",
        "csp_ainewmuou": "wexmuou-v1",
        "csp_ainewshandianguard": "wexshandian-v1",
        "csp_ainewshandian": "wexshandian-v1",
        "csp_ainewxiaopanguard": "wexxiaopan-v1",
        "csp_ainewxiaopan": "wexxiaopan-v1",
        "csp_ainewzhizhenguard": "wexzhizhen-v1",
        "csp_ainewzhizhen": "wexzhizhen-v1",
        "csp_ainewwoggguard": "wexwogg-v1",
        "csp_ainewwogg": "wexwogg-v1",
        "csp_ainewhuajuanguard": "wexhuajuan-v1",
        "csp_ainewhuajuan": "wexhuajuan-v1",
        "csp_ainewjutouguard": "wexjutou-v1",
        "csp_ainewjutou": "wexjutou-v1",
        "csp_ainewzhinan4kguard": "wexzhinan-v1",
        "csp_ainewzhinan4k": "wexzhinan-v1",
        "csp_ainewwoniu4kguard": "wexwoniu-v1",
        "csp_ainewwoniu4k": "wexwoniu-v1",
        "csp_ainewpiankuguard": "wexpianku-v1",
        "csp_ainewpianku": "wexpianku-v1",
        "csp_aiqwmkvguard": "wexqiwei-v1",
        "csp_aiqwmkv": "wexqiwei-v1",
        "csp_ainewyidong4kguard": "wexyidong-v1",
        "csp_ainewyidong4k": "wexyidong-v1",
        "csp_soaiaipansoguard": "wexaipanso-v1",
        "csp_soaiaipanso": "wexaipanso-v1",
        "csp_soaihaiyinguard": "wexhaiyin-v1",
        "csp_soaihaiyin": "wexhaiyin-v1",
        "csp_soaiquanpanguard": "wexquanpan-v1",
        "csp_soaiquanpan": "wexquanpan-v1",
        "csp_sokakaguard": "wexkaka-v1",
        "csp_sokaka": "wexkaka-v1",
        "csp_jumitvguard": "jumitv-v1",
        "csp_jumitv": "jumitv-v1",
        "csp_animeaimoduguard": "wexmodu-v1",
        "csp_animeaimodu": "wexmodu-v1",
        "csp_duanjuaihaokanguard": "wexhaokan-v1",
        "csp_duanjuaihaokan": "wexhaokan-v1",
        "csp_duanjuaiqimiaoguard": "wexqimiao-v1",
        "csp_duanjuaiqimiao": "wexqimiao-v1",
        "csp_musicaikuwoaguard": "wexkuwoa-v1",
        "csp_musicaikuwoa": "wexkuwoa-v1",
        "csp_musicaiqingtingguard": "wexqingting-v1",
        "csp_musicaiqingting": "wexqingting-v1",
        "csp_sportaiguaziguard": "wexsportguazi-v1",
        "csp_sportaiguazi": "wexsportguazi-v1",
        "csp_sportaikafeiguard": "wexkafei-v1",
        "csp_sportaikafei": "wexkafei-v1",
        "csp_sportaikanqiutongguard": "wexkanqiutong-v1",
        "csp_sportaikanqiutong": "wexkanqiutong-v1",
        "csp_sportaikanqiuguard": "wexkanqiu-v1",
        "csp_sportaikanqiu": "wexkanqiu-v1",
        "csp_sportaiwweguard": "wexwwe-v1",
        "csp_sportaiwwe": "wexwwe-v1",
    ]

    public var isScriptOrJarApi: Bool {
        let lower = cleanApiPath
        return isRemoteScriptSource
            || lower.hasPrefix("csp_")
            || lower.hasSuffix(".js")
            || lower.hasSuffix(".mjs")
            || lower.hasSuffix(".jar")
            || lower.hasSuffix(".py")
    }

    public var isNetdiskSite: Bool {
        let lower = api.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let netdiskPrefixes = [
            "csp_wogg", "csp_ali", "csp_alipan", "csp_quark", "csp_uc",
            "csp_baidu", "csp_pan", "csp_tudou", "csp_wanou", "csp_mogg", "csp_115",
        ]
        return netdiskPrefixes.contains { lower.hasPrefix($0) }
    }

    public var hasQuickJsAdapter: Bool {
        isJavaScriptSource || isRemoteScriptSource || isDrpySource || isGuardPortedSource
    }

    public var isEffectivelyPrivate: Bool {
        isPrivate || group.contains("隐私") || group.contains("私密")
    }

    public var capabilityStatus: String {
        if isExtTooLarge {
            return Self.statusExtTooLarge
        }
        if key == "mydrive" {
            return Self.statusUnsupportedType
        }
        if isExternalMediaLibrary {
            return Self.statusOk
        }
        if isCatPaw {
            return MarcoBuildCapabilities.hasCatpaw ? Self.statusOk : Self.statusCatPawNodeRequired
        }
        if isPythonSource {
            return MarcoBuildCapabilities.hasCPython ? Self.statusOk : Self.statusPythonRuntimeRequired
        }
        if isCspRuleEngine || isWoggNetdiskSource {
            return Self.statusOk
        }
        if (type == 3 || isScriptOrJarApi) && hasQuickJsAdapter {
            return Self.statusOk
        }
        if isM3uVodApi || (type == 4 && isHttpApi) {
            return Self.statusOk
        }
        if (type == 3 || isScriptOrJarApi) && isNetdiskSite {
            return Self.statusAdapterMissing
        }
        if type == 3 || isScriptOrJarApi {
            return Self.statusNeedsJar
        }
        if type != 0 && type != 1 && type != 4 && !(type == -1 && isHttpApi) {
            return Self.statusUnsupportedType
        }
        if !isHttpApi {
            return Self.statusCustomSiteUrl
        }
        return Self.statusOk
    }

    public var supported: Bool {
        capabilityStatus == Self.statusOk
    }

    public static func capabilityReason(_ status: String) -> String {
        switch status {
        case statusOk:
            return "正常可用"
        case statusCatPawNodeRequired:
            return "当前构建未包含 CatPaw Node.js 本机运行时，请安装完整版 IPA"
        case statusPythonRuntimeRequired:
            return "当前轻量模式未嵌入 CPython 运行时，请安装完整版 IPA"
        case statusNeedsJar:
            return "此来源依赖 Android JAR / 原生插件运行环境，可配置蜘蛛网关运行"
        case statusUnsupportedType:
            return "暂不支持此类型来源，已保留在列表中"
        case statusAdapterMissing:
            return "此网盘源插件尚未适配当前设备"
        case statusExtTooLarge:
            return "扩展参数超过 128 KB 上限，无法加载"
        case statusCustomSiteUrl:
            return "此来源不是可直接请求的 HTTP(S) CMS"
        case statusParserRequired:
            return "需要解析器，当前环境缺少可用解析配置"
        default:
            return "此来源暂不可用"
        }
    }

    public var unsupportedReason: String {
        Self.capabilityReason(capabilityStatus)
    }

    public var isBannerNoticeSite: Bool {
        let n = name.lowercased()
        return n.contains("免费分享")
            || n.contains("更新日期")
            || n.contains("防失联")
            || n.contains("公众号")
            || n.contains("发布页")
            || n.contains("网址发布")
            || n.contains("谨防")
            || n.contains("禁商用")
            || n.contains("仅供学习")
            || (n.contains("请先点击") && n.contains("配置"))
    }
}

public struct CmsCategory: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var parentId: String

    public init(id: String, name: String, parentId: String = "") {
        self.id = id
        self.name = name
        self.parentId = parentId
    }

    public var isTopLevel: Bool {
        parentId.isEmpty || parentId == "0"
    }
}

public struct CmsFilterOption: Codable, Hashable, Sendable {
    public var name: String
    public var value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

public struct CmsFilterGroup: Codable, Hashable, Identifiable, Sendable {
    public var id: String { key }
    public var key: String
    public var name: String
    public var options: [CmsFilterOption]

    public init(key: String, name: String, options: [CmsFilterOption] = []) {
        self.key = key
        self.name = name
        self.options = options
    }
}

public struct CmsEpisode: Codable, Hashable, Identifiable, Sendable {
    public var id: String { "\(name)|\(url)" }
    public var name: String
    public var url: String
    public var headers: [String: String]

    public init(name: String, url: String, headers: [String: String] = [:]) {
        self.name = name
        self.url = url
        self.headers = headers
    }

    public var isScriptEpisode: Bool {
        url.hasPrefix("mmjs://play?") || url.hasPrefix("mmpy://play?") || url.hasPrefix("mmcsp://play?")
    }

    public var isExternalLibraryUrl: Bool {
        let lower = url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lower.hasPrefix("mmemby://")
            || lower.hasPrefix("mmjellyfin://")
            || lower.hasPrefix("mmplex://")
            || lower.hasPrefix("mmwebdav://")
            || lower.hasPrefix("mmalist://")
            || lower.hasPrefix("mmsmb://")
            || lower.hasPrefix("mmlocal://")
            || lower.hasPrefix("mmcloudlib://")
    }

    public var isNetdiskUrl: Bool {
        let lower = url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower.hasPrefix("mmquark://")
            || lower.hasPrefix("mmwogg://")
            || lower.hasPrefix("mmcloud://")
            || lower.hasPrefix("mmshare://")
            || lower.hasPrefix("mm115://")
        {
            return true
        }
        let sharePatterns = [
            "pan.quark.cn/s/",
            "drive.uc.cn/s/",
            "pan.baidu.com/s/",
            "www.alipan.com/s/",
            "www.aliyundrive.com/s/",
            "115.com/s/",
            "115cdn.com/s/",
            "anxia.com/s/",
        ]
        return sharePatterns.contains { lower.contains($0) }
    }

    public var isDirectPlayable: Bool {
        if isNetdiskUrl || isExternalLibraryUrl || isScriptEpisode {
            return false
        }
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("/") || trimmed.lowercased().hasPrefix("file://") {
            return true
        }
        let lower = trimmed.lowercased()
        guard lower.hasPrefix("http://")
            || lower.hasPrefix("https://")
            || lower.hasPrefix("rtmp://")
            || lower.hasPrefix("rtsp://")
        else {
            return false
        }
        if lower.contains("tuxiaobei.com/play/")
            || lower.contains("youlai.cn/jijiu/article/")
            || lower.contains("api.bilibili.com/x/player/playurl")
        {
            return true
        }
        let noFragment = lower.components(separatedBy: "#").first ?? lower
        let pathOnly = noFragment.components(separatedBy: "?").first ?? noFragment
        if pathOnly.hasSuffix(".html") || pathOnly.hasSuffix(".htm") || pathOnly.contains("/share/") {
            return false
        }
        if pathOnly.contains("/play/") {
            let directExts = [".m3u8", ".m3u", ".mp4", ".flv", ".mkv", ".ts", ".webm", ".mpd", ".mov", ".avi"]
            if !directExts.contains(where: { pathOnly.hasSuffix($0) }) {
                return false
            }
        }
        return true
    }
}

public struct CmsLine: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var episodes: [CmsEpisode]

    private enum CodingKeys: String, CodingKey {
        case id, name, episodes
    }

    public init(id: String? = nil, name: String, episodes: [CmsEpisode]) {
        self.id = id ?? name
        self.name = name
        self.episodes = episodes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let name = try c.decode(String.self, forKey: .name)
        self.id = try c.decodeIfPresent(String.self, forKey: .id) ?? name
        self.name = name
        self.episodes = try c.decodeIfPresent([CmsEpisode].self, forKey: .episodes) ?? []
    }

    public var isM3u8Preferred: Bool {
        name.lowercased().contains("m3u8")
            || (episodes.first?.url.lowercased().contains(".m3u8") ?? false)
    }

    public var netdiskDriveKey: String? {
        let lowerName = name.lowercased()
        let firstUrl = episodes.first?.url.lowercased() ?? ""
        if lowerName.contains("夸父") || lowerName.contains("夸克") || lowerName.contains("quark")
            || firstUrl.contains("quark.cn") || firstUrl.hasPrefix("mmquark://") || firstUrl.hasPrefix("mmwogg://quark")
        {
            return "quark"
        }
        if lowerName.contains("优汐") || lowerName.contains("uc网盘") || lowerName.contains("uc原画")
            || firstUrl.contains("drive.uc.cn") || firstUrl.hasPrefix("mmwogg://uc")
        {
            return "uc"
        }
        if lowerName.contains("嘟嘟") || lowerName.contains("百度") || lowerName.contains("baidu")
            || firstUrl.contains("pan.baidu.com") || firstUrl.hasPrefix("mmwogg://baidu")
        {
            return "baidu"
        }
        if lowerName.contains("阿狸") || lowerName.contains("阿里") || lowerName.contains("alipan") || lowerName.contains("aliyundrive")
            || firstUrl.contains("alipan.com") || firstUrl.contains("aliyundrive.com") || firstUrl.hasPrefix("mmwogg://ali")
        {
            return "ali"
        }
        if lowerName.contains("115")
            || firstUrl.contains("115.com/s/")
            || firstUrl.contains("115cdn.com/s/")
            || firstUrl.contains("anxia.com/s/")
            || firstUrl.hasPrefix("mm115://")
            || firstUrl.hasPrefix("mmwogg://115")
        {
            return "115"
        }
        return nil
    }

    public var isNetdiskLine: Bool {
        netdiskDriveKey != nil || (episodes.first?.isNetdiskUrl ?? false)
    }
}

public struct CmsVideo: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var poster: String
    public var remarks: String
    public var year: String
    public var area: String
    public var actor: String
    public var director: String
    public var description: String
    public var tag: String
    public var doubanScore: Double?
    public var rtScore: Int?
    public var lines: [CmsLine]
    public var sourceWarnings: [String]

    private enum CodingKeys: String, CodingKey {
        case id, title, poster, remarks, year, area, actor, director
        case description, tag, doubanScore, rtScore, lines, sourceWarnings
    }

    public init(
        id: String,
        title: String,
        poster: String = "",
        remarks: String = "",
        year: String = "",
        area: String = "",
        actor: String = "",
        director: String = "",
        description: String = "",
        tag: String = "",
        doubanScore: Double? = nil,
        rtScore: Int? = nil,
        lines: [CmsLine] = [],
        sourceWarnings: [String] = []
    ) {
        self.id = id
        self.title = title
        self.poster = poster
        self.remarks = remarks
        self.year = year
        self.area = area
        self.actor = actor
        self.director = director
        self.description = description
        self.tag = tag
        self.doubanScore = doubanScore
        self.rtScore = rtScore
        self.lines = lines
        self.sourceWarnings = sourceWarnings
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.title = try c.decode(String.self, forKey: .title)
        self.poster = try c.decodeIfPresent(String.self, forKey: .poster) ?? ""
        self.remarks = try c.decodeIfPresent(String.self, forKey: .remarks) ?? ""
        self.year = try c.decodeIfPresent(String.self, forKey: .year) ?? ""
        self.area = try c.decodeIfPresent(String.self, forKey: .area) ?? ""
        self.actor = try c.decodeIfPresent(String.self, forKey: .actor) ?? ""
        self.director = try c.decodeIfPresent(String.self, forKey: .director) ?? ""
        self.description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        self.tag = try c.decodeIfPresent(String.self, forKey: .tag) ?? ""
        self.doubanScore = try c.decodeIfPresent(Double.self, forKey: .doubanScore)
        self.rtScore = try c.decodeIfPresent(Int.self, forKey: .rtScore)
        self.lines = try c.decodeIfPresent([CmsLine].self, forKey: .lines) ?? []
        self.sourceWarnings = try c.decodeIfPresent([String].self, forKey: .sourceWarnings) ?? []
    }
}

public struct CmsListing: Codable, Hashable, Sendable {
    public var page: Int
    public var pageCount: Int
    public var videos: [CmsVideo]
    public var sourceFiltered: Bool
    public var filters: [String: [CmsFilterGroup]]

    private enum CodingKeys: String, CodingKey {
        case page, pageCount, videos, sourceFiltered, filters
    }

    public init(
        page: Int = 1,
        pageCount: Int = 1,
        videos: [CmsVideo] = [],
        sourceFiltered: Bool = false,
        filters: [String: [CmsFilterGroup]] = [:]
    ) {
        self.page = max(1, page)
        self.pageCount = max(1, pageCount)
        self.videos = videos
        self.sourceFiltered = sourceFiltered
        self.filters = filters
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.page = max(1, try c.decodeIfPresent(Int.self, forKey: .page) ?? 1)
        self.pageCount = max(1, try c.decodeIfPresent(Int.self, forKey: .pageCount) ?? 1)
        self.videos = try c.decodeIfPresent([CmsVideo].self, forKey: .videos) ?? []
        self.sourceFiltered = try c.decodeIfPresent(Bool.self, forKey: .sourceFiltered) ?? false
        self.filters = try c.decodeIfPresent([String: [CmsFilterGroup]].self, forKey: .filters) ?? [:]
    }
}

// MARK: - Live TV

public enum LiveStreamHealth: String, Codable, Hashable, Sendable {
    case unknown
    case reachable
    case unreachable
    case checking
}

public struct LiveSource: Codable, Hashable, Identifiable, Sendable {
    public var id: String { "\(subscriptionId)|\(name)|\(url)" }
    public var name: String
    public var url: String
    public var headers: [String: String]
    public var group: String
    public var isPrivate: Bool
    public var subscriptionId: String
    public var origin: String
    public var inlineContent: String
    public var plugin: CmsSite?

    public init(
        name: String,
        url: String,
        headers: [String: String] = [:],
        group: String = "默认分组",
        isPrivate: Bool = false,
        subscriptionId: String = "",
        origin: String = "",
        inlineContent: String = "",
        plugin: CmsSite? = nil
    ) {
        self.name = name
        self.url = url
        self.headers = headers
        self.group = group
        self.isPrivate = isPrivate
        self.subscriptionId = subscriptionId
        self.origin = origin
        self.inlineContent = inlineContent
        self.plugin = plugin
    }

    public var isEffectivelyPrivate: Bool {
        isPrivate || group.contains("隐私") || group.contains("私密")
    }

    public var supported: Bool {
        if !inlineContent.isEmpty { return true }
        if let plugin = plugin { return plugin.hasQuickJsAdapter }
        let u = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if u.isEmpty { return false }
        if u.hasPrefix("data:") { return u.contains("base64,") }
        guard let parsed = URL(string: u),
              let scheme = parsed.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = parsed.host,
              !host.isEmpty
        else {
            return false
        }
        return true
    }
}

public struct StandaloneLiveSource: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var url: String
    public var inlineContent: String
    public var userAgent: String
    public var logoTemplate: String
    public var autoCategorize: Bool
    public var enabled: Bool
    public var updatedAt: Int64

    public init(
        id: String,
        name: String,
        url: String = "",
        inlineContent: String = "",
        userAgent: String = "",
        logoTemplate: String = "",
        autoCategorize: Bool = true,
        enabled: Bool = true,
        updatedAt: Int64 = 0
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.inlineContent = inlineContent
        self.userAgent = userAgent
        self.logoTemplate = logoTemplate
        self.autoCategorize = autoCategorize
        self.enabled = enabled
        self.updatedAt = updatedAt
    }

    public func toLiveSource() -> LiveSource {
        let trimmedUa = userAgent.trimmingCharacters(in: .whitespacesAndNewlines)
        return LiveSource(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "自建直播源" : name.trimmingCharacters(in: .whitespacesAndNewlines),
            url: url.trimmingCharacters(in: .whitespacesAndNewlines),
            headers: trimmedUa.isEmpty ? [:] : ["User-Agent": trimmedUa],
            group: "电视直播",
            isPrivate: false,
            subscriptionId: "standalone_live:\(id)",
            origin: url.trimmingCharacters(in: .whitespacesAndNewlines),
            inlineContent: inlineContent
        )
    }

    public static func fromDictionary(_ dict: [String: Any]) -> StandaloneLiveSource? {
        let id = (dict["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let url = (dict["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let inline = (dict["inlineContent"] as? String) ?? ""
        guard !id.isEmpty, (!url.isEmpty || !inline.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) else {
            return nil
        }
        let rawName = (dict["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return StandaloneLiveSource(
            id: id,
            name: rawName.isEmpty ? "自建直播源" : rawName,
            url: url,
            inlineContent: inline,
            userAgent: (dict["userAgent"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            logoTemplate: (dict["logoTemplate"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            autoCategorize: (dict["autoCategorize"] as? Bool) ?? true,
            enabled: (dict["enabled"] as? Bool) ?? true,
            updatedAt: (dict["updatedAt"] as? NSNumber)?.int64Value ?? 0
        )
    }
}

public struct LiveChannel: Codable, Hashable, Identifiable, Sendable {
    public var id: String { "\(group)|\(name)" }
    public var name: String
    public var group: String
    public var urls: [String]
    public var logo: String
    public var streams: [CmsEpisode]
    public var health: LiveStreamHealth
    public var latencyMs: Int?
    public var reachableCount: Int?

    private enum CodingKeys: String, CodingKey {
        case name, group, urls, logo, streams, health, latencyMs, reachableCount
    }

    public init(
        name: String,
        group: String,
        urls: [String],
        logo: String = "",
        streams: [CmsEpisode] = [],
        health: LiveStreamHealth = .unknown,
        latencyMs: Int? = nil,
        reachableCount: Int? = nil
    ) {
        self.name = name
        self.group = group
        self.urls = urls
        self.logo = logo
        self.streams = streams
        self.health = health
        self.latencyMs = latencyMs
        self.reachableCount = reachableCount
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try c.decode(String.self, forKey: .name)
        self.group = try c.decode(String.self, forKey: .group)
        self.urls = try c.decodeIfPresent([String].self, forKey: .urls) ?? []
        self.logo = try c.decodeIfPresent(String.self, forKey: .logo) ?? ""
        self.streams = try c.decodeIfPresent([CmsEpisode].self, forKey: .streams) ?? []
        self.health = try c.decodeIfPresent(LiveStreamHealth.self, forKey: .health) ?? .unknown
        self.latencyMs = try c.decodeIfPresent(Int.self, forKey: .latencyMs)
        self.reachableCount = try c.decodeIfPresent(Int.self, forKey: .reachableCount)
    }

    public var episodes: [CmsEpisode] {
        if !streams.isEmpty { return streams }
        return urls.enumerated().map { idx, u in
            CmsEpisode(name: "线路 \(idx + 1)", url: u)
        }
    }
}

public struct LiveGroup: Codable, Hashable, Identifiable, Sendable {
    public var id: String { name }
    public var name: String
    public var channels: [LiveChannel]

    public init(name: String, channels: [LiveChannel]) {
        self.name = name
        self.channels = channels
    }
}

// MARK: - Ownership & Aggregated CmsConfig

public struct SiteOwnershipRecord: Codable, Hashable, Sendable {
    public var canonicalKey: String
    public var rawKey: String
    public var subscriptionId: String
    public var subscriptionName: String
    public var siteName: String
    public var isEnabled: Bool
    public var isPrivate: Bool
    public var isSupported: Bool
    public var unsupportedReason: String

    public init(
        canonicalKey: String,
        rawKey: String,
        subscriptionId: String,
        subscriptionName: String = "",
        siteName: String,
        isEnabled: Bool,
        isPrivate: Bool,
        isSupported: Bool,
        unsupportedReason: String = ""
    ) {
        self.canonicalKey = canonicalKey
        self.rawKey = rawKey
        self.subscriptionId = subscriptionId
        self.subscriptionName = subscriptionName
        self.siteName = siteName
        self.isEnabled = isEnabled
        self.isPrivate = isPrivate
        self.isSupported = isSupported
        self.unsupportedReason = unsupportedReason
    }
}

public struct CmsConfig: Codable, Hashable, Sendable {
    public var sites: [CmsSite]
    public var lives: [LiveSource]
    public var depots: [CmsDepot]
    public var parses: [CmsParse]
    public var rules: [CmsSniffRule]
    public var ads: [String]
    public var spider: String
    public var siteOwners: [SiteOwnershipRecord]
    public var privateSubscriptionIds: Set<String>
    public var publicSubscriptionIds: Set<String>
    public var unhydratedPublicSubscriptionIds: Set<String>
    public var knownPrivateSiteKeys: Set<String>
    public var ambiguousLegacyRawKeys: Set<String>

    private enum CodingKeys: String, CodingKey {
        case sites, lives, depots, parses, rules, ads, spider, siteOwners, privateSubscriptionIds
        case publicSubscriptionIds, unhydratedPublicSubscriptionIds, knownPrivateSiteKeys, ambiguousLegacyRawKeys
    }

    public init(
        sites: [CmsSite] = [],
        lives: [LiveSource] = [],
        depots: [CmsDepot] = [],
        parses: [CmsParse] = [],
        rules: [CmsSniffRule] = [],
        ads: [String] = [],
        spider: String = "",
        siteOwners: [SiteOwnershipRecord] = [],
        privateSubscriptionIds: Set<String> = [],
        publicSubscriptionIds: Set<String> = [],
        unhydratedPublicSubscriptionIds: Set<String> = [],
        knownPrivateSiteKeys: Set<String> = [],
        ambiguousLegacyRawKeys: Set<String> = []
    ) {
        self.sites = sites
        self.lives = lives
        self.depots = depots
        self.parses = parses
        self.rules = rules
        self.ads = ads
        self.spider = spider
        self.siteOwners = siteOwners
        self.privateSubscriptionIds = privateSubscriptionIds
        self.publicSubscriptionIds = publicSubscriptionIds
        self.unhydratedPublicSubscriptionIds = unhydratedPublicSubscriptionIds
        self.knownPrivateSiteKeys = knownPrivateSiteKeys
        self.ambiguousLegacyRawKeys = ambiguousLegacyRawKeys
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.sites = try c.decodeIfPresent([CmsSite].self, forKey: .sites) ?? []
        self.lives = try c.decodeIfPresent([LiveSource].self, forKey: .lives) ?? []
        self.depots = try c.decodeIfPresent([CmsDepot].self, forKey: .depots) ?? []
        self.parses = try c.decodeIfPresent([CmsParse].self, forKey: .parses) ?? []
        self.rules = try c.decodeIfPresent([CmsSniffRule].self, forKey: .rules) ?? []
        self.ads = try c.decodeIfPresent([String].self, forKey: .ads) ?? []
        self.spider = try c.decodeIfPresent(String.self, forKey: .spider) ?? ""
        self.siteOwners = try c.decodeIfPresent([SiteOwnershipRecord].self, forKey: .siteOwners) ?? []
        self.privateSubscriptionIds = try c.decodeIfPresent(Set<String>.self, forKey: .privateSubscriptionIds) ?? []
        self.publicSubscriptionIds = try c.decodeIfPresent(Set<String>.self, forKey: .publicSubscriptionIds) ?? []
        self.unhydratedPublicSubscriptionIds = try c.decodeIfPresent(Set<String>.self, forKey: .unhydratedPublicSubscriptionIds) ?? []
        self.knownPrivateSiteKeys = try c.decodeIfPresent(Set<String>.self, forKey: .knownPrivateSiteKeys) ?? []
        self.ambiguousLegacyRawKeys = try c.decodeIfPresent(Set<String>.self, forKey: .ambiguousLegacyRawKeys) ?? []
    }

    public var effectiveSiteOwners: [SiteOwnershipRecord] {
        if !siteOwners.isEmpty {
            return siteOwners
        }
        return sites.map { s in
            SiteOwnershipRecord(
                canonicalKey: s.key,
                rawKey: s.rawKey,
                subscriptionId: s.subscriptionId,
                subscriptionName: "",
                siteName: s.name,
                isEnabled: true,
                isPrivate: s.isEffectivelyPrivate,
                isSupported: s.supported,
                unsupportedReason: s.unsupportedReason
            )
        }
    }

    public func isPrivateSiteKey(_ recordSiteKey: String) -> Bool {
        let clean = recordSiteKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return false }

        if knownPrivateSiteKeys.contains(clean) {
            return true
        }

        let owners = effectiveSiteOwners
        if let exact = owners.first(where: { $0.canonicalKey == clean }) {
            return exact.isPrivate
        }
        if let legacyDisambig = owners.first(where: {
            !$0.subscriptionId.isEmpty && "\($0.rawKey)_\($0.subscriptionId)" == clean
        }) {
            return legacyDisambig.isPrivate
        }
        if let parsed = CmsSite.parseScopedKey(clean) {
            if privateSubscriptionIds.contains(parsed.subscriptionId) {
                return true
            }
            if let byPair = owners.first(where: {
                $0.subscriptionId == parsed.subscriptionId && $0.rawKey == parsed.rawKey
            }) {
                return byPair.isPrivate
            }
            return false
        }
        for privSubId in privateSubscriptionIds where !privSubId.isEmpty && clean.hasSuffix("_\(privSubId)") {
            return true
        }
        let byRaw = owners.filter { $0.rawKey == clean }
        if !byRaw.isEmpty && byRaw.contains(where: { $0.isPrivate }) {
            return true
        }
        return false
    }

    public func isPublicDisplayAllowed(_ recordSiteKey: String) -> Bool {
        let clean = recordSiteKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return false }
        if isPrivateSiteKey(clean) {
            return false
        }

        let owners = effectiveSiteOwners
        if let exact = owners.first(where: { $0.canonicalKey == clean }) {
            return !exact.isPrivate
        }
        if let legacyDisambig = owners.first(where: {
            !$0.subscriptionId.isEmpty && "\($0.rawKey)_\($0.subscriptionId)" == clean
        }) {
            return !legacyDisambig.isPrivate
        }
        if let parsed = CmsSite.parseScopedKey(clean) {
            if let byPair = owners.first(where: {
                $0.subscriptionId == parsed.subscriptionId && $0.rawKey == parsed.rawKey
            }) {
                return !byPair.isPrivate
            }
            return unhydratedPublicSubscriptionIds.contains(parsed.subscriptionId)
        }
        let byRaw = owners.filter { $0.rawKey == clean }
        if !byRaw.isEmpty {
            return !byRaw.contains(where: { $0.isPrivate })
        }
        return false
    }

    public var availableSites: [CmsSite] {
        sites.filter { $0.supported }
    }

    public var publicAvailableSites: [CmsSite] {
        sites.filter { $0.supported && !$0.isEffectivelyPrivate }
    }

    public var unsupportedSites: [CmsSite] {
        sites.filter { !$0.supported }
    }

    public var allSupportedLives: [LiveSource] {
        lives.filter { $0.supported }
    }

    public var publicSupportedLives: [LiveSource] {
        lives.filter { $0.supported && !$0.isEffectivelyPrivate }
    }

    public var supportedLives: [LiveSource] {
        publicSupportedLives
    }

    public var publicDepots: [CmsDepot] {
        depots.filter { !$0.isPrivate }
    }

    public var isMultiDepotOnly: Bool {
        sites.isEmpty && lives.isEmpty && !depots.isEmpty
    }
}

// MARK: - Watch History, Favorites & Skip Records

public struct WatchHistoryItem: Codable, Hashable, Identifiable, Sendable {
    public static let mediaIdPrefix = "mid:v1:"

    private static let safeIdentityQueryKeys: Set<String> = [
        "id", "fid", "file_id", "fileid", "vid", "item_id", "itemid",
        "share_id", "shareid", "fs_id", "fsid", "path", "name", "ep",
        "episode", "sid", "v", "p", "cid", "bvid", "aid", "playid",
        "media_id", "mediaid", "file", "dir", "folder", "drive_id",
        "driveid", "pan_id", "panid", "uk", "surl", "pwd_id", "vod_id",
        "nid", "part", "part_id", "partid", "ratingkey", "rating_key",
        "episode_id", "episodeid", "stream_id", "streamid", "asset_id",
        "assetid", "provider", "drive", "ref", "account", "fids",
        "channel_id", "channelid",
    ]

    public var id: String
    public var site: String
    public var title: String
    public var poster: String
    public var line: String
    public var lineId: String
    public var episode: String
    public var episodeMediaId: String
    public var audioTrackId: String
    public var subtitleTrackId: String
    public var subtitleOffsetMs: Int
    public var subscriptionId: String
    public var sourceKey: String
    public var sourceApi: String
    public var sourceExt: String
    public var index: Int
    public var position: Int
    public var duration: Int
    public var updated: Int64

    private enum CodingKeys: String, CodingKey {
        case id, site, title, poster, line, lineId, episode, episodeMediaId
        case audioTrackId, subtitleTrackId, subtitleOffsetMs
        case subscriptionId, sourceKey, sourceApi, sourceExt
        case index, position, duration, updated
    }

    public init(
        site: String,
        id: String,
        title: String,
        poster: String = "",
        line: String = "",
        lineId: String = "",
        episode: String = "",
        episodeMediaId: String = "",
        audioTrackId: String = "",
        subtitleTrackId: String = "",
        subtitleOffsetMs: Int = 0,
        subscriptionId: String = "",
        sourceKey: String = "",
        sourceApi: String = "",
        sourceExt: String = "",
        index: Int = 0,
        position: Int = 0,
        duration: Int = 0,
        updated: Int64 = 0
    ) {
        self.site = site
        self.id = id
        self.title = title
        self.poster = poster
        self.line = line
        self.lineId = lineId
        self.episode = episode
        self.episodeMediaId = Self.normalizeMediaId(episodeMediaId)
        self.audioTrackId = audioTrackId
        self.subtitleTrackId = subtitleTrackId
        self.subtitleOffsetMs = subtitleOffsetMs
        self.subscriptionId = subscriptionId
        self.sourceKey = sourceKey
        self.sourceApi = sourceApi
        self.sourceExt = sourceExt
        self.index = max(0, index)
        self.position = max(0, position)
        self.duration = max(0, duration)
        self.updated = updated
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.site = try c.decodeIfPresent(String.self, forKey: .site) ?? ""
        self.id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        self.title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        self.poster = try c.decodeIfPresent(String.self, forKey: .poster) ?? ""
        self.line = try c.decodeIfPresent(String.self, forKey: .line) ?? ""
        self.lineId = try c.decodeIfPresent(String.self, forKey: .lineId) ?? ""
        self.episode = try c.decodeIfPresent(String.self, forKey: .episode) ?? ""
        let rawMid = try c.decodeIfPresent(String.self, forKey: .episodeMediaId) ?? ""
        self.episodeMediaId = Self.normalizeMediaId(rawMid)
        self.audioTrackId = try c.decodeIfPresent(String.self, forKey: .audioTrackId) ?? ""
        self.subtitleTrackId = try c.decodeIfPresent(String.self, forKey: .subtitleTrackId) ?? ""
        self.subtitleOffsetMs = try c.decodeIfPresent(Int.self, forKey: .subtitleOffsetMs) ?? 0
        self.subscriptionId = try c.decodeIfPresent(String.self, forKey: .subscriptionId) ?? ""
        self.sourceKey = try c.decodeIfPresent(String.self, forKey: .sourceKey) ?? ""
        self.sourceApi = try c.decodeIfPresent(String.self, forKey: .sourceApi) ?? ""
        self.sourceExt = try c.decodeIfPresent(String.self, forKey: .sourceExt) ?? ""
        self.index = max(0, try c.decodeIfPresent(Int.self, forKey: .index) ?? 0)
        self.position = max(0, try c.decodeIfPresent(Int.self, forKey: .position) ?? 0)
        self.duration = max(0, try c.decodeIfPresent(Int.self, forKey: .duration) ?? 0)
        self.updated = max(0, try c.decodeIfPresent(Int64.self, forKey: .updated) ?? 0)
    }

    public static func isCanonicalMediaId(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(mediaIdPrefix) else { return false }
        let hex = trimmed.dropFirst(mediaIdPrefix.count)
        guard hex.count == 32 else { return false }
        return hex.utf8.allSatisfy { b in
            (b >= 0x30 && b <= 0x39) || (b >= 0x61 && b <= 0x66)
        }
    }

    public static func normalizeMediaId(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if isCanonicalMediaId(trimmed) { return trimmed }
        return mediaIdentityForUrl(trimmed)
    }

    public static func mediaIdentityForUrl(_ rawUrl: String) -> String {
        let trimmed = rawUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if isCanonicalMediaId(trimmed) { return trimmed }

        var canonical = trimmed
        if let comps = URLComponents(string: trimmed), let scheme = comps.scheme?.lowercased(), !scheme.isEmpty {
            let host = (comps.host ?? "").lowercased()
            let explicitPort: String
            if let p = comps.port, !((scheme == "http" && p == 80) || (scheme == "https" && p == 443)) {
                explicitPort = ":\(p)"
            } else {
                explicitPort = ""
            }
            var keptPairs: [(String, String)] = []
            if let qItems = comps.queryItems {
                let sorted = qItems.sorted { $0.name.lowercased() < $1.name.lowercased() }
                for item in sorted {
                    let lk = item.name.lowercased()
                    if safeIdentityQueryKeys.contains(lk) {
                        keptPairs.append((lk, item.value ?? ""))
                    }
                }
            }
            var built = "\(scheme):"
            if !host.isEmpty {
                built += "//\(host)\(explicitPort)"
            }
            built += comps.percentEncodedPath
            if !keptPairs.isEmpty {
                var allowed = CharacterSet.urlQueryAllowed
                allowed.remove(charactersIn: "&+=?#/")
                let qs = keptPairs.map { k, v in
                    let ek = k.addingPercentEncoding(withAllowedCharacters: allowed) ?? k
                    let ev = v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v
                    return "\(ek)=\(ev)"
                }.joined(separator: "&")
                built += "?\(qs)"
            }
            canonical = built
        } else if let re = try? NSRegularExpression(
            pattern: #"([?&|;\s])(token|sign|sig|signature|auth|auth_key|access_token|secret|pass|password|pwd|cookie|session|expires|expire|exp|key|api_key|apikey)=[^&|;\s]*"#,
            options: [.caseInsensitive]
        ) {
            canonical = re.stringByReplacingMatches(
                in: trimmed,
                range: NSRange(trimmed.startIndex..., in: trimmed),
                withTemplate: "$1"
            )
        }

        let digestHex = SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
        return "\(mediaIdPrefix)\(digestHex.prefix(32))"
    }

    public static func matchesEpisodeUrl(_ storedIdOrUrl: String, _ candidateEpisodeUrl: String) -> Bool {
        let storedId = mediaIdentityForUrl(storedIdOrUrl)
        let candidateId = mediaIdentityForUrl(candidateEpisodeUrl)
        return !storedId.isEmpty && storedId == candidateId
    }

    public var effectiveMediaId: String {
        let clean = episodeMediaId.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? "" : Self.normalizeMediaId(clean)
    }

    public var key: String {
        "\(site)\n\(id)"
    }

    public var complete: Bool {
        guard duration >= 60_000 else { return false }
        let threshold = min(max(Int((Double(duration) * 0.05).rounded()), 15_000), 120_000)
        return position >= duration - threshold
    }

    public var resumePosition: Int {
        complete ? 0 : max(0, position)
    }

    public var progressFraction: Double {
        guard duration > 0 else { return 0 }
        return min(max(Double(position) / Double(duration), 0.0), 1.0)
    }

    public func toDictionary() -> [String: Any] {
        var out: [String: Any] = [
            "site": site,
            "id": id,
            "title": title,
            "poster": poster,
            "line": line,
            "episode": episode,
            "index": max(0, index),
            "position": max(0, position),
            "duration": max(0, duration),
            "updated": updated,
        ]
        if !lineId.isEmpty { out["lineId"] = lineId }
        let mid = effectiveMediaId
        if !mid.isEmpty { out["episodeMediaId"] = mid }
        if !audioTrackId.isEmpty { out["audioTrackId"] = audioTrackId }
        if !subtitleTrackId.isEmpty { out["subtitleTrackId"] = subtitleTrackId }
        if subtitleOffsetMs != 0 { out["subtitleOffsetMs"] = subtitleOffsetMs }
        if !subscriptionId.isEmpty { out["subscriptionId"] = subscriptionId }
        if !sourceKey.isEmpty { out["sourceKey"] = sourceKey }
        if !sourceApi.isEmpty { out["sourceApi"] = sourceApi }
        if !sourceExt.isEmpty { out["sourceExt"] = sourceExt }
        return out
    }

    public static func fromDictionary(_ dict: [String: Any]) -> WatchHistoryItem {
        let pos = Int(Self.num(dict["position"]))
        let dur = Int(Self.num(dict["duration"]))
        let idx = Int(Self.num(dict["index"]))
        let upd = Self.num(dict["updated"])
        let storedMid = Self.str(dict["episodeMediaId"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let legacyUrl = Self.str(dict["episodeUrl"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedMid = !storedMid.isEmpty ? normalizeMediaId(storedMid) : mediaIdentityForUrl(legacyUrl)
        return WatchHistoryItem(
            site: Self.str(dict["site"]),
            id: Self.str(dict["id"]),
            title: Self.str(dict["title"]),
            poster: Self.str(dict["poster"]),
            line: Self.str(dict["line"]),
            lineId: Self.str(dict["lineId"]),
            episode: Self.str(dict["episode"]),
            episodeMediaId: resolvedMid,
            audioTrackId: Self.str(dict["audioTrackId"]),
            subtitleTrackId: Self.str(dict["subtitleTrackId"]),
            subtitleOffsetMs: Int(Self.num(dict["subtitleOffsetMs"])),
            subscriptionId: Self.str(dict["subscriptionId"]),
            sourceKey: Self.str(dict["sourceKey"]),
            sourceApi: Self.str(dict["sourceApi"]),
            sourceExt: Self.str(dict["sourceExt"]),
            index: max(0, idx),
            position: max(0, pos),
            duration: max(0, dur),
            updated: max(0, upd)
        )
    }

    private static func str(_ v: Any?) -> String {
        guard let v = v, !(v is NSNull) else { return "" }
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return ""
    }

    private static func num(_ v: Any?) -> Int64 {
        guard let v = v, !(v is NSNull) else { return 0 }
        if let n = v as? NSNumber { return n.int64Value }
        if let s = v as? String, let parsed = Int64(s.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return parsed
        }
        return 0
    }
}

public typealias WatchHistoryEntry = WatchHistoryItem

public struct FavoriteItem: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var site: String
    public var title: String
    public var poster: String
    public var remarks: String
    public var updated: Int64

    public init(
        site: String,
        id: String,
        title: String,
        poster: String = "",
        remarks: String = "",
        updated: Int64 = 0
    ) {
        self.site = site
        self.id = id
        self.title = title
        self.poster = poster
        self.remarks = remarks
        self.updated = updated
    }

    public var key: String {
        "\(site)\n\(id)"
    }

    public func toDictionary() -> [String: Any] {
        [
            "site": site,
            "id": id,
            "title": title,
            "poster": poster,
            "remarks": remarks,
            "updated": updated,
        ]
    }

    public static func fromDictionary(_ dict: [String: Any]) -> FavoriteItem {
        let upd = Self.num(dict["updated"] ?? dict["addedAt"])
        return FavoriteItem(
            site: Self.str(dict["site"]),
            id: Self.str(dict["id"]),
            title: Self.str(dict["title"]),
            poster: Self.str(dict["poster"]),
            remarks: Self.str(dict["remarks"]),
            updated: max(0, upd)
        )
    }

    private static func str(_ v: Any?) -> String {
        guard let v = v, !(v is NSNull) else { return "" }
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return ""
    }

    private static func num(_ v: Any?) -> Int64 {
        guard let v = v, !(v is NSNull) else { return 0 }
        if let n = v as? NSNumber { return n.int64Value }
        if let s = v as? String, let parsed = Int64(s.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return parsed
        }
        return 0
    }
}

public typealias FavoriteEntry = FavoriteItem

public struct VideoSkipRecord: Codable, Hashable, Sendable {
    public var intro: Int
    public var outro: Int
    public var updated: Int64

    public init(intro: Int = 0, outro: Int = 0, updated: Int64 = 0) {
        self.intro = min(max(0, intro), 600)
        self.outro = min(max(0, outro), 600)
        self.updated = max(0, updated)
    }
}

// MARK: - Playback & Appearance Preferences

public enum IosPlaybackEngineMode: String, Codable, CaseIterable, Hashable, Sendable {
    case avplayer
    case mpv

    public var labelZh: String {
        switch self {
        case .avplayer: return "Apple 原生 (AVPlayer 低功耗)"
        case .mpv: return "MPV 全能解码"
        }
    }

    public var shortLabel: String {
        switch self {
        case .avplayer: return "AVPlayer"
        case .mpv: return "MPV"
        }
    }

    public static func fromId(_ raw: String?) -> IosPlaybackEngineMode {
        let norm = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch norm {
        case "mpv": return .mpv
        case "avplayer", "avkit", "mdk": return .avplayer
        default: return .avplayer
        }
    }
}

public enum IosHdrToneMappingMode: String, Codable, CaseIterable, Hashable, Sendable {
    case auto
    case bt2390 = "bt.2390"
    case bt2446a = "bt.2446a"
    case hable
    case clip

    public var labelZh: String {
        switch self {
        case .auto: return "自动 (BT.2390 动态)"
        case .bt2390: return "BT.2390 电影动态映射"
        case .bt2446a: return "BT.2446a 高亮保留"
        case .hable: return "Hable 柔和映射"
        case .clip: return "原生高光直出 (Clip)"
        }
    }

    public var mpvToneMapping: String {
        switch self {
        case .auto, .bt2390: return "bt.2390"
        case .bt2446a: return "bt.2446a"
        case .hable: return "hable"
        case .clip: return "clip"
        }
    }

    public var computePeak: String {
        self == .clip ? "no" : "yes"
    }

    public static func fromId(_ raw: String?) -> IosHdrToneMappingMode {
        let norm = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch norm {
        case "bt.2390", "bt2390": return .bt2390
        case "bt.2446a", "bt2446a": return .bt2446a
        case "hable": return .hable
        case "clip": return .clip
        default: return .auto
        }
    }
}

public enum VocalLoudnessPreset: String, Codable, CaseIterable, Hashable, Sendable {
    case off
    case light
    case standard
    case cinemaVocal = "cinema_vocal"

    public var labelZh: String {
        switch self {
        case .off: return "关闭"
        case .light: return "轻度"
        case .standard: return "标准"
        case .cinemaVocal: return "影院人声"
        }
    }

    public var volumeMax: Int {
        switch self {
        case .off: return 100
        case .light: return 150
        case .standard, .cinemaVocal: return 200
        }
    }

    public var audioFilter: String {
        switch self {
        case .off:
            return ""
        case .light:
            return "lavfi=[dynaudnorm=f=150:g=15:p=0.90:m=3.0]"
        case .standard:
            return "lavfi=[dynaudnorm=f=150:g=15:p=0.95:m=6.0]"
        case .cinemaVocal:
            return "lavfi=[highpass=f=90,equalizer=f=1800:t=q:w=1.2:g=3.5,dynaudnorm=f=120:g=11:p=0.95:m=8.0]"
        }
    }

    public static func fromId(_ raw: String?) -> VocalLoudnessPreset {
        let norm = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch norm {
        case "light": return .light
        case "standard": return .standard
        case "cinema_vocal", "cinemavocal": return .cinemaVocal
        default: return .off
        }
    }
}

public enum AppThemeMode: String, Codable, CaseIterable, Hashable, Sendable {
    case system
    case light
    case dark

    public static func fromId(_ raw: String?) -> AppThemeMode {
        let norm = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch norm {
        case "light": return .light
        case "dark": return .dark
        default: return .system
        }
    }
}

public struct PlaybackPreferences: Codable, Hashable, Sendable {
    public static let supportedAmbientThemes = ["aurora", "twilight", "ocean", "amber", "nebula", "frost"]
    public static let supportedAmbientIntensities = ["soft", "standard", "vivid"]
    public static let defaultToolbarItems: [String] = [
        "episodes", "lines", "speed", "danmu_subtitle", "aspect", "engine", "audio", "skip_intro_outro", "more",
    ]
    public static let defaultHomeSectionOrder: [String] = [
        "watch_history",
        "disc_widescreen_radar",
        "disc_editorial_picks",
        "disc_hot_stream",
        "disc_mood_capsules",
        "disc_studio_galleries",
        "disc_poster_mosaics",
        "source_updates",
    ]

    public var skipIntroSec: Int
    public var skipOutroSec: Int
    public var playSpeed: Double
    public var autoNext: Bool
    public var episodesDescending: Bool
    public var repeatMode: String
    public var selectedSiteKey: String
    public var preferredSiteKey: String
    public var preferredLine: String
    public var netdiskQuality: String
    public var playerKernel: String
    public var iosEngineMode: IosPlaybackEngineMode
    public var hdrToneMapping: IosHdrToneMappingMode
    public var vocalLoudness: VocalLoudnessPreset
    public var anime4kLightweight: Bool
    public var appThemeMode: AppThemeMode
    public var ambientGlowEnabled: Bool
    public var ambientTheme: String
    public var ambientIntensity: String
    public var ambientPosterSync: Bool
    public var hlsAdStripEnabled: Bool
    public var diskCacheMaxMb: Int
    public var defaultAspectMode: String
    public var playerAlwaysShowClock: Bool
    public var showHeroBanner: Bool
    public var showContinueWatching: Bool
    public var showCuratedDiscovery: Bool
    public var homeSectionOrder: [String]
    public var homeSectionHidden: [String]
    public var iosPlayerToolbarItems: [String]
    public var netdiskDriveOrder: [String]
    public var prioritizeLoggedInDrives: Bool
    public var liveAutoCategorize: Bool
    public var liveHideUnreachable: Bool

    private enum CodingKeys: String, CodingKey {
        case skipIntroSec, skipOutroSec, playSpeed, autoNext, episodesDescending, repeatMode
        case selectedSiteKey, preferredSiteKey, preferredLine, netdiskQuality, playerKernel
        case iosEngineMode, hdrToneMapping, vocalLoudness, anime4kLightweight
        case appThemeMode, ambientGlowEnabled, ambientTheme, ambientIntensity, ambientPosterSync
        case hlsAdStripEnabled, diskCacheMaxMb, defaultAspectMode, playerAlwaysShowClock
        case showHeroBanner, showContinueWatching, showCuratedDiscovery
        case homeSectionOrder, homeSectionHidden, iosPlayerToolbarItems
        case netdiskDriveOrder, prioritizeLoggedInDrives, liveAutoCategorize, liveHideUnreachable
    }

    public init(
        skipIntroSec: Int = 0,
        skipOutroSec: Int = 0,
        playSpeed: Double = 1.0,
        autoNext: Bool = true,
        episodesDescending: Bool = false,
        repeatMode: String = "off",
        selectedSiteKey: String = "",
        preferredSiteKey: String = "",
        preferredLine: String = "",
        netdiskQuality: String = "auto",
        playerKernel: String = "range_proxy",
        iosEngineMode: IosPlaybackEngineMode = .avplayer,
        hdrToneMapping: IosHdrToneMappingMode = .auto,
        vocalLoudness: VocalLoudnessPreset = .off,
        anime4kLightweight: Bool = false,
        appThemeMode: AppThemeMode = .system,
        ambientGlowEnabled: Bool = true,
        ambientTheme: String = "aurora",
        ambientIntensity: String = "standard",
        ambientPosterSync: Bool = true,
        hlsAdStripEnabled: Bool = true,
        diskCacheMaxMb: Int = 512,
        defaultAspectMode: String = "contain",
        playerAlwaysShowClock: Bool = false,
        showHeroBanner: Bool = true,
        showContinueWatching: Bool = true,
        showCuratedDiscovery: Bool = true,
        homeSectionOrder: [String] = PlaybackPreferences.defaultHomeSectionOrder,
        homeSectionHidden: [String] = [],
        iosPlayerToolbarItems: [String] = PlaybackPreferences.defaultToolbarItems,
        netdiskDriveOrder: [String] = NetdiskProvider.defaultOrder.map(\.rawValue),
        prioritizeLoggedInDrives: Bool = true,
        liveAutoCategorize: Bool = true,
        liveHideUnreachable: Bool = false
    ) {
        self.skipIntroSec = min(max(skipIntroSec, 0), 600)
        self.skipOutroSec = min(max(skipOutroSec, 0), 600)
        self.playSpeed = min(max(playSpeed, 0.5), 3.0)
        self.autoNext = autoNext
        self.episodesDescending = episodesDescending
        self.repeatMode = ["off", "one", "all"].contains(repeatMode) ? repeatMode : "off"
        self.selectedSiteKey = selectedSiteKey
        self.preferredSiteKey = preferredSiteKey
        self.preferredLine = preferredLine
        self.netdiskQuality = ["auto", "4k_hdr", "1080p"].contains(netdiskQuality) ? netdiskQuality : "auto"
        self.playerKernel = ["avkit", "range_proxy"].contains(playerKernel) ? playerKernel : "range_proxy"
        self.iosEngineMode = iosEngineMode
        self.hdrToneMapping = hdrToneMapping
        self.vocalLoudness = vocalLoudness
        self.anime4kLightweight = anime4kLightweight
        self.appThemeMode = appThemeMode
        self.ambientGlowEnabled = ambientGlowEnabled
        self.ambientTheme = Self.supportedAmbientThemes.contains(ambientTheme) ? ambientTheme : "aurora"
        self.ambientIntensity = Self.supportedAmbientIntensities.contains(ambientIntensity) ? ambientIntensity : "standard"
        self.ambientPosterSync = ambientPosterSync
        self.hlsAdStripEnabled = hlsAdStripEnabled
        self.diskCacheMaxMb = max(0, min(diskCacheMaxMb, 4096))
        self.defaultAspectMode = defaultAspectMode.isEmpty ? "contain" : defaultAspectMode
        self.playerAlwaysShowClock = playerAlwaysShowClock
        self.showHeroBanner = showHeroBanner
        self.showContinueWatching = showContinueWatching
        self.showCuratedDiscovery = showCuratedDiscovery
        self.homeSectionOrder = homeSectionOrder.isEmpty ? Self.defaultHomeSectionOrder : homeSectionOrder
        self.homeSectionHidden = homeSectionHidden
        self.iosPlayerToolbarItems = iosPlayerToolbarItems.isEmpty ? Self.defaultToolbarItems : iosPlayerToolbarItems
        self.netdiskDriveOrder = netdiskDriveOrder.isEmpty ? NetdiskProvider.defaultOrder.map(\.rawValue) : netdiskDriveOrder
        self.prioritizeLoggedInDrives = prioritizeLoggedInDrives
        self.liveAutoCategorize = liveAutoCategorize
        self.liveHideUnreachable = liveHideUnreachable
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            skipIntroSec: try c.decodeIfPresent(Int.self, forKey: .skipIntroSec) ?? 0,
            skipOutroSec: try c.decodeIfPresent(Int.self, forKey: .skipOutroSec) ?? 0,
            playSpeed: try c.decodeIfPresent(Double.self, forKey: .playSpeed) ?? 1.0,
            autoNext: try c.decodeIfPresent(Bool.self, forKey: .autoNext) ?? true,
            episodesDescending: try c.decodeIfPresent(Bool.self, forKey: .episodesDescending) ?? false,
            repeatMode: try c.decodeIfPresent(String.self, forKey: .repeatMode) ?? "off",
            selectedSiteKey: try c.decodeIfPresent(String.self, forKey: .selectedSiteKey) ?? "",
            preferredSiteKey: try c.decodeIfPresent(String.self, forKey: .preferredSiteKey) ?? "",
            preferredLine: try c.decodeIfPresent(String.self, forKey: .preferredLine) ?? "",
            netdiskQuality: try c.decodeIfPresent(String.self, forKey: .netdiskQuality) ?? "auto",
            playerKernel: try c.decodeIfPresent(String.self, forKey: .playerKernel) ?? "range_proxy",
            iosEngineMode: try c.decodeIfPresent(IosPlaybackEngineMode.self, forKey: .iosEngineMode) ?? .avplayer,
            hdrToneMapping: try c.decodeIfPresent(IosHdrToneMappingMode.self, forKey: .hdrToneMapping) ?? .auto,
            vocalLoudness: try c.decodeIfPresent(VocalLoudnessPreset.self, forKey: .vocalLoudness) ?? .off,
            anime4kLightweight: try c.decodeIfPresent(Bool.self, forKey: .anime4kLightweight) ?? false,
            appThemeMode: try c.decodeIfPresent(AppThemeMode.self, forKey: .appThemeMode) ?? .system,
            ambientGlowEnabled: try c.decodeIfPresent(Bool.self, forKey: .ambientGlowEnabled) ?? true,
            ambientTheme: try c.decodeIfPresent(String.self, forKey: .ambientTheme) ?? "aurora",
            ambientIntensity: try c.decodeIfPresent(String.self, forKey: .ambientIntensity) ?? "standard",
            ambientPosterSync: try c.decodeIfPresent(Bool.self, forKey: .ambientPosterSync) ?? true,
            hlsAdStripEnabled: try c.decodeIfPresent(Bool.self, forKey: .hlsAdStripEnabled) ?? true,
            diskCacheMaxMb: try c.decodeIfPresent(Int.self, forKey: .diskCacheMaxMb) ?? 512,
            defaultAspectMode: try c.decodeIfPresent(String.self, forKey: .defaultAspectMode) ?? "contain",
            playerAlwaysShowClock: try c.decodeIfPresent(Bool.self, forKey: .playerAlwaysShowClock) ?? false,
            showHeroBanner: try c.decodeIfPresent(Bool.self, forKey: .showHeroBanner) ?? true,
            showContinueWatching: try c.decodeIfPresent(Bool.self, forKey: .showContinueWatching) ?? true,
            showCuratedDiscovery: try c.decodeIfPresent(Bool.self, forKey: .showCuratedDiscovery) ?? true,
            homeSectionOrder: try c.decodeIfPresent([String].self, forKey: .homeSectionOrder) ?? Self.defaultHomeSectionOrder,
            homeSectionHidden: try c.decodeIfPresent([String].self, forKey: .homeSectionHidden) ?? [],
            iosPlayerToolbarItems: try c.decodeIfPresent([String].self, forKey: .iosPlayerToolbarItems) ?? Self.defaultToolbarItems,
            netdiskDriveOrder: try c.decodeIfPresent([String].self, forKey: .netdiskDriveOrder) ?? NetdiskProvider.defaultOrder.map(\.rawValue),
            prioritizeLoggedInDrives: try c.decodeIfPresent(Bool.self, forKey: .prioritizeLoggedInDrives) ?? true,
            liveAutoCategorize: try c.decodeIfPresent(Bool.self, forKey: .liveAutoCategorize) ?? true,
            liveHideUnreachable: try c.decodeIfPresent(Bool.self, forKey: .liveHideUnreachable) ?? false
        )
    }
}

// MARK: - Netdisk & External Media Libraries

public enum NetdiskProvider: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case quark = "quark"
    case uc = "uc"
    case baidu = "baidu"
    case ali = "ali"
    case drive115 = "115"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .quark: return "夸克网盘"
        case .uc: return "UC 网盘"
        case .baidu: return "百度网盘"
        case .ali: return "阿里云盘"
        case .drive115: return "115 网盘"
        }
    }

    public var tvName: String {
        switch self {
        case .quark: return "我的夸父"
        case .uc: return "我的优汐"
        case .baidu: return "我的嘟嘟"
        case .ali: return "我的阿狸"
        case .drive115: return "我的 115"
        }
    }

    public var keychainKey: String {
        switch self {
        case .quark: return "netdisk_quark_cookie"
        case .uc: return "netdisk_uc_cookie"
        case .baidu: return "netdisk_baidu_cookie"
        case .ali: return "netdisk_ali_token"
        case .drive115: return "netdisk_115_cookie"
        }
    }

    public var rootFolderId: String {
        switch self {
        case .quark, .uc, .drive115: return "0"
        case .baidu: return "/"
        case .ali: return "root"
        }
    }

    public var trustedDomains: [String] {
        switch self {
        case .quark: return ["quark.cn"]
        case .uc: return ["uc.cn"]
        case .baidu: return ["baidu.com", "baidupcs.com"]
        case .ali: return ["alipan.com", "aliyundrive.com", "aliyundrive.net", "aliyunpds.com"]
        case .drive115: return ["115.com", "115cdn.com", "anxia.com"]
        }
    }

    public static let defaultOrder: [NetdiskProvider] = [.quark, .uc, .baidu, .ali, .drive115]

    public static func fromKey(_ raw: String) -> NetdiskProvider? {
        let norm = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch norm {
        case "quark": return .quark
        case "uc": return .uc
        case "baidu": return .baidu
        case "ali", "alipan", "aliyundrive": return .ali
        case "115", "drive115": return .drive115
        default: return nil
        }
    }
}

public struct PersonalCloudAccount: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var provider: NetdiskProvider
    public var label: String
    public var rootFolderId: String
    public var rootFolderName: String
    public var driveId: String
    public var accountId: String
    public var updatedAt: Int64

    public init(
        id: String,
        provider: NetdiskProvider,
        label: String,
        rootFolderId: String? = nil,
        rootFolderName: String = "",
        driveId: String = "",
        accountId: String = "",
        updatedAt: Int64 = 0
    ) {
        self.id = id
        self.provider = provider
        self.label = label
        self.rootFolderId = rootFolderId ?? provider.rootFolderId
        self.rootFolderName = rootFolderName
        self.driveId = driveId
        self.accountId = accountId
        self.updatedAt = updatedAt
    }
}

public struct PersonalCloudFile: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var provider: NetdiskProvider
    public var name: String
    public var isDir: Bool
    public var size: Int64
    public var thumbnail: String
    public var driveId: String
    public var path: String
    public var pickCode: String
    public var rawRef: String

    public init(
        id: String,
        provider: NetdiskProvider,
        name: String,
        isDir: Bool,
        size: Int64 = 0,
        thumbnail: String = "",
        driveId: String = "",
        path: String = "",
        pickCode: String = "",
        rawRef: String = ""
    ) {
        self.id = id
        self.provider = provider
        self.name = name
        self.isDir = isDir
        self.size = size
        self.thumbnail = thumbnail
        self.driveId = driveId
        self.path = path
        self.pickCode = pickCode
        self.rawRef = rawRef
    }
}

public struct EmbyAccount: Codable, Hashable, Identifiable, Sendable {
    public var id: String { key }
    public var key: String
    public var label: String
    public var baseUrl: String
    public var username: String
    public var userId: String
    public var accessToken: String
    public var deviceId: String
    public var allowCloudSync: Bool
    public var allowInvalidCert: Bool
    public var updatedAt: Int64

    public init(
        key: String,
        label: String,
        baseUrl: String,
        username: String = "",
        userId: String = "",
        accessToken: String = "",
        deviceId: String = "",
        allowCloudSync: Bool = true,
        allowInvalidCert: Bool = false,
        updatedAt: Int64 = 0
    ) {
        self.key = key
        self.label = label
        self.baseUrl = baseUrl
        self.username = username
        self.userId = userId
        self.accessToken = accessToken
        self.deviceId = deviceId
        self.allowCloudSync = allowCloudSync
        self.allowInvalidCert = allowInvalidCert
        self.updatedAt = updatedAt
    }

    public func toCloudSyncDictionary() -> [String: Any] {
        [
            "key": key,
            "label": label,
            "baseUrl": baseUrl,
            "username": username,
            "userId": userId,
            "deviceId": deviceId,
            "allowCloudSync": allowCloudSync,
            "allowInvalidCert": allowInvalidCert,
            "updatedAt": updatedAt,
        ]
    }

    public static func fromDictionary(_ dict: [String: Any]) -> EmbyAccount? {
        let key = (dict["key"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let base = ((dict["baseUrl"] ?? dict["serverUrl"] ?? dict["url"]) as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !key.isEmpty, !base.isEmpty else { return nil }
        return EmbyAccount(
            key: key,
            label: ((dict["label"] ?? dict["name"]) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? key,
            baseUrl: base,
            username: (dict["username"] as? String) ?? "",
            userId: (dict["userId"] as? String) ?? "",
            accessToken: (dict["accessToken"] ?? dict["token"]) as? String ?? "",
            deviceId: (dict["deviceId"] as? String) ?? "",
            allowCloudSync: (dict["allowCloudSync"] as? Bool) ?? true,
            allowInvalidCert: (dict["allowInvalidCert"] as? Bool) ?? false,
            updatedAt: (dict["updatedAt"] as? NSNumber)?.int64Value ?? 0
        )
    }
}

public enum MediaLibraryKind: String, Codable, CaseIterable, Hashable, Sendable {
    case emby
    case jellyfin
    case plex
    case webdav
    case alist
    case smb2
    case local
    case personalCloud = "cloudlib"

    public var displayName: String {
        switch self {
        case .emby: return "Emby"
        case .jellyfin: return "Jellyfin"
        case .plex: return "Plex"
        case .webdav: return "WebDAV 媒体库"
        case .alist: return "AList / OpenList"
        case .smb2: return "SMB2 / NAS 共享"
        case .local: return "本机媒体文件夹"
        case .personalCloud: return "个人网盘库"
        }
    }
}

public struct MediaLibraryAccount: Codable, Hashable, Identifiable, Sendable {
    public var id: String { "\(kind.rawValue):\(key)" }
    public var kind: MediaLibraryKind
    public var key: String
    public var label: String
    public var baseUrl: String
    public var host: String
    public var port: Int?
    public var path: String
    public var shareName: String
    public var username: String
    public var domain: String
    public var userId: String
    public var deviceId: String
    public var allowInvalidCert: Bool
    public var allowCloudSync: Bool
    public var extra: [String: String]
    public var updatedAt: Int64

    public init(
        kind: MediaLibraryKind,
        key: String,
        label: String,
        baseUrl: String = "",
        host: String = "",
        port: Int? = nil,
        path: String = "",
        shareName: String = "",
        username: String = "",
        domain: String = "",
        userId: String = "",
        deviceId: String = "",
        allowInvalidCert: Bool = false,
        allowCloudSync: Bool = false,
        extra: [String: String] = [:],
        updatedAt: Int64 = 0
    ) {
        self.kind = kind
        self.key = key
        self.label = label
        self.baseUrl = baseUrl
        self.host = host
        self.port = port
        self.path = path
        self.shareName = shareName
        self.username = username
        self.domain = domain
        self.userId = userId
        self.deviceId = deviceId
        self.allowInvalidCert = allowInvalidCert
        self.allowCloudSync = allowCloudSync
        self.extra = extra
        self.updatedAt = updatedAt
    }

    public var secretKeychainKey: String {
        "medialib_secret_\(kind.rawValue)_\(key)"
    }
}

// MARK: - Offline Downloads

public enum DownloadTaskStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case queued
    case downloading
    case paused
    case completed
    case failed
}

public struct DownloadTask: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var siteKey: String
    public var siteName: String
    public var siteApi: String
    public var siteType: Int
    public var videoId: String
    public var title: String
    public var poster: String
    public var lineName: String
    public var episodeName: String
    public var episodeIndex: Int
    public var sourceUrl: String
    public var headers: [String: String]
    public var sourceSite: CmsSite?
    public var sourceParses: [CmsParse]
    public var createdAt: Int64
    public var status: DownloadTaskStatus
    public var progress: Double
    public var receivedBytes: Int64
    public var totalBytes: Int64
    public var filePath: String
    public var error: String
    public var isPrivate: Bool
    public var subscriptionId: String
    public var sourceKey: String
    public var sourceApi: String

    private enum CodingKeys: String, CodingKey {
        case id, siteKey, siteName, siteApi, siteType, videoId, title, poster
        case lineName, episodeName, episodeIndex, sourceUrl, headers, sourceSite
        case sourceParses, createdAt, status, progress, receivedBytes, totalBytes
        case filePath, error, isPrivate, subscriptionId, sourceKey, sourceApi
    }

    public init(
        id: String,
        siteKey: String,
        siteName: String,
        siteApi: String = "",
        siteType: Int = 1,
        videoId: String,
        title: String,
        poster: String = "",
        lineName: String = "",
        episodeName: String = "",
        episodeIndex: Int = 0,
        sourceUrl: String = "",
        headers: [String: String] = [:],
        sourceSite: CmsSite? = nil,
        sourceParses: [CmsParse] = [],
        createdAt: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        status: DownloadTaskStatus = .queued,
        progress: Double = 0,
        receivedBytes: Int64 = 0,
        totalBytes: Int64 = 0,
        filePath: String = "",
        error: String = "",
        isPrivate: Bool = false,
        subscriptionId: String = "",
        sourceKey: String = "",
        sourceApi: String = ""
    ) {
        self.id = id
        self.siteKey = siteKey
        self.siteName = siteName
        self.siteApi = siteApi
        self.siteType = siteType
        self.videoId = videoId
        self.title = title
        self.poster = poster
        self.lineName = lineName
        self.episodeName = episodeName
        self.episodeIndex = episodeIndex
        self.sourceUrl = sourceUrl
        self.headers = headers
        self.sourceSite = sourceSite
        self.sourceParses = sourceParses
        self.createdAt = createdAt
        self.status = status
        self.progress = progress
        self.receivedBytes = receivedBytes
        self.totalBytes = totalBytes
        self.filePath = filePath
        self.error = error
        self.isPrivate = isPrivate || (sourceSite?.isEffectivelyPrivate ?? false)
        self.subscriptionId = subscriptionId.isEmpty ? (sourceSite?.subscriptionId ?? "") : subscriptionId
        self.sourceKey = sourceKey.isEmpty ? (sourceSite?.sourceKey ?? siteKey) : sourceKey
        self.sourceApi = sourceApi.isEmpty ? (sourceSite?.sourceApi ?? siteApi) : sourceApi
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let siteKey = try c.decodeIfPresent(String.self, forKey: .siteKey) ?? ""
        let siteApi = try c.decodeIfPresent(String.self, forKey: .siteApi) ?? ""
        let sourceSite = try c.decodeIfPresent(CmsSite.self, forKey: .sourceSite)
        let decodedPrivate = try c.decodeIfPresent(Bool.self, forKey: .isPrivate) ?? false
        let decodedSubId = try c.decodeIfPresent(String.self, forKey: .subscriptionId) ?? ""
        let decodedSrcKey = try c.decodeIfPresent(String.self, forKey: .sourceKey) ?? ""
        let decodedSrcApi = try c.decodeIfPresent(String.self, forKey: .sourceApi) ?? ""

        self.id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        self.siteKey = siteKey
        self.siteName = try c.decodeIfPresent(String.self, forKey: .siteName) ?? ""
        self.siteApi = siteApi
        self.siteType = try c.decodeIfPresent(Int.self, forKey: .siteType) ?? 1
        self.videoId = try c.decodeIfPresent(String.self, forKey: .videoId) ?? ""
        self.title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        self.poster = try c.decodeIfPresent(String.self, forKey: .poster) ?? ""
        self.lineName = try c.decodeIfPresent(String.self, forKey: .lineName) ?? ""
        self.episodeName = try c.decodeIfPresent(String.self, forKey: .episodeName) ?? ""
        self.episodeIndex = try c.decodeIfPresent(Int.self, forKey: .episodeIndex) ?? 0
        self.sourceUrl = try c.decodeIfPresent(String.self, forKey: .sourceUrl) ?? ""
        self.headers = try c.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
        self.sourceSite = sourceSite
        self.sourceParses = try c.decodeIfPresent([CmsParse].self, forKey: .sourceParses) ?? []
        self.createdAt = try c.decodeIfPresent(Int64.self, forKey: .createdAt) ?? 0
        self.status = try c.decodeIfPresent(DownloadTaskStatus.self, forKey: .status) ?? .paused
        self.progress = try c.decodeIfPresent(Double.self, forKey: .progress) ?? 0
        self.receivedBytes = try c.decodeIfPresent(Int64.self, forKey: .receivedBytes) ?? 0
        self.totalBytes = try c.decodeIfPresent(Int64.self, forKey: .totalBytes) ?? 0
        self.filePath = try c.decodeIfPresent(String.self, forKey: .filePath) ?? ""
        self.error = try c.decodeIfPresent(String.self, forKey: .error) ?? ""
        self.isPrivate = decodedPrivate || (sourceSite?.isEffectivelyPrivate ?? false)
        self.subscriptionId = decodedSubId.isEmpty ? (sourceSite?.subscriptionId ?? "") : decodedSubId
        self.sourceKey = decodedSrcKey.isEmpty ? (sourceSite?.sourceKey ?? siteKey) : decodedSrcKey
        self.sourceApi = decodedSrcApi.isEmpty ? (sourceSite?.sourceApi ?? siteApi) : decodedSrcApi
    }

    public var isActive: Bool {
        status == .queued || status == .downloading
    }
}

// MARK: - Danmaku

public enum DanmuMode: Int, Codable, CaseIterable, Hashable, Sendable {
    case scroll = 1
    case bottom = 4
    case top = 5
}

public struct DanmuComment: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var timeMs: Int
    public var mode: DanmuMode
    public var colorRgb: UInt32
    public var text: String

    public init(
        id: String = UUID().uuidString,
        timeMs: Int,
        mode: DanmuMode = .scroll,
        colorRgb: UInt32 = 0xFFFFFF,
        text: String
    ) {
        self.id = id
        self.timeMs = max(0, timeMs)
        self.mode = mode
        self.colorRgb = colorRgb & 0x00FF_FFFF
        self.text = text
    }
}

public struct DanmuSettings: Codable, Hashable, Sendable {
    public var enabled: Bool
    public var serverUrls: String
    public var appId: String
    public var appSecret: String
    public var opacity: Double
    public var displayArea: Double
    public var fontSize: Double
    public var speedMultiplier: Double
    public var timeOffsetMs: Int
    public var showScroll: Bool
    public var showTop: Bool
    public var showBottom: Bool
    public var maxRows: Int
    public var blockRules: [String]
    public var authorizedCredentialOrigins: [String]
    public var pendingAuthOrigins: [String]
    public var dismissedAuthOrigins: [String]

    public init(
        enabled: Bool = false,
        serverUrls: String = "",
        appId: String = "",
        appSecret: String = "",
        opacity: Double = 0.85,
        displayArea: Double = 0.50,
        fontSize: Double = 20.0,
        speedMultiplier: Double = 1.0,
        timeOffsetMs: Int = 0,
        showScroll: Bool = true,
        showTop: Bool = true,
        showBottom: Bool = true,
        maxRows: Int = 14,
        blockRules: [String] = [],
        authorizedCredentialOrigins: [String] = [],
        pendingAuthOrigins: [String] = [],
        dismissedAuthOrigins: [String] = []
    ) {
        self.enabled = enabled
        self.serverUrls = serverUrls.trimmingCharacters(in: .whitespacesAndNewlines)
        self.appId = appId.trimmingCharacters(in: .whitespacesAndNewlines)
        self.appSecret = appSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        self.opacity = min(max(opacity, 0.20), 1.00)
        self.displayArea = min(max(displayArea, 0.25), 1.00)
        self.fontSize = min(max(fontSize, 14.0), 32.0)
        self.speedMultiplier = min(max(speedMultiplier, 0.75), 1.50)
        self.timeOffsetMs = min(max(timeOffsetMs, -30_000), 30_000)
        self.showScroll = showScroll
        self.showTop = showTop
        self.showBottom = showBottom
        self.maxRows = min(max(maxRows, 2), 14)
        self.blockRules = blockRules
        self.authorizedCredentialOrigins = authorizedCredentialOrigins
        self.pendingAuthOrigins = pendingAuthOrigins
        self.dismissedAuthOrigins = dismissedAuthOrigins
    }
}

public struct DanmuSourceEntry: Codable, Hashable, Sendable {
    public var url: String
    public var requiresAuth: Bool

    public init(url: String, requiresAuth: Bool = false) {
        self.url = url
        self.requiresAuth = requiresAuth
    }
}

public struct DanmuSourceSyncDocument: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var updatedAt: Int64
    public var revision: Int
    public var clearedAt: Int64
    public var initialized: Bool
    public var sources: [DanmuSourceEntry]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, updatedAt, revision, clearedAt, initialized, sources
    }

    public init(
        schemaVersion: Int = DanmuSourceSyncDocument.currentSchemaVersion,
        updatedAt: Int64 = 0,
        revision: Int = 0,
        clearedAt: Int64 = 0,
        initialized: Bool = false,
        sources: [DanmuSourceEntry] = []
    ) {
        self.schemaVersion = schemaVersion
        self.updatedAt = max(0, updatedAt)
        self.revision = max(0, revision)
        self.clearedAt = max(0, clearedAt)
        self.initialized = initialized
        self.sources = sources
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? Self.currentSchemaVersion
        self.updatedAt = max(0, try c.decodeIfPresent(Int64.self, forKey: .updatedAt) ?? 0)
        self.revision = max(0, try c.decodeIfPresent(Int.self, forKey: .revision) ?? 0)
        self.clearedAt = max(0, try c.decodeIfPresent(Int64.self, forKey: .clearedAt) ?? 0)
        self.sources = try c.decodeIfPresent([DanmuSourceEntry].self, forKey: .sources) ?? []
        let initFlag = try c.decodeIfPresent(Bool.self, forKey: .initialized)
        self.initialized = initFlag ?? (self.updatedAt > 0 || self.revision > 0 || !self.sources.isEmpty)
    }

    public var isFreshUninitialized: Bool {
        !initialized && updatedAt <= 0 && revision <= 0 && sources.isEmpty
    }

    public func toPayloadDictionary() -> [String: Any] {
        [
            "schemaVersion": schemaVersion,
            "updatedAt": updatedAt,
            "revision": revision,
            "clearedAt": clearedAt,
            "sources": sources.map { ["url": $0.url, "requiresAuth": $0.requiresAuth] },
        ]
    }
}

// MARK: - AI Assistant

public enum AiAuthMode: String, Codable, CaseIterable, Hashable, Sendable {
    case apiKey = "api_key"
    case codexOAuth = "codex_oauth"
    case openRouterOAuth = "openrouter_oauth"
    case githubCopilotDeviceFlow = "github_copilot_device"
    case localNoAuth = "local_no_auth"

    public static func fromId(_ raw: String?) -> AiAuthMode {
        let norm = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return AiAuthMode(rawValue: norm) ?? .apiKey
    }
}

public enum AiApiProtocol: String, Codable, CaseIterable, Hashable, Sendable {
    case openaiCompatible = "openai_compatible"
    case anthropicMessages = "anthropic_messages"
    case geminiGenerateContent = "gemini_generate_content"

    public static func fromId(_ raw: String?) -> AiApiProtocol {
        let norm = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return AiApiProtocol(rawValue: norm) ?? .openaiCompatible
    }
}

public struct AiProviderProfile: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var presetId: String
    public var protocolType: AiApiProtocol
    public var authMode: AiAuthMode
    public var baseUrl: String
    public var model: String
    public var fastModel: String
    public var accountLabel: String
    public var createdAtMs: Int64
    public var updatedAtMs: Int64

    private enum CodingKeys: String, CodingKey {
        case id, name, presetId
        case protocolType = "protocol"
        case authMode, baseUrl, model, fastModel, accountLabel, createdAtMs, updatedAtMs
    }

    public init(
        id: String,
        name: String,
        presetId: String = "custom",
        protocolType: AiApiProtocol = .openaiCompatible,
        authMode: AiAuthMode = .apiKey,
        baseUrl: String = "",
        model: String = "",
        fastModel: String = "",
        accountLabel: String = "",
        createdAtMs: Int64 = 0,
        updatedAtMs: Int64 = 0
    ) {
        self.id = id
        self.name = name
        self.presetId = presetId
        self.protocolType = protocolType
        self.authMode = authMode
        self.baseUrl = baseUrl
        self.model = model
        self.fastModel = fastModel
        self.accountLabel = accountLabel
        self.createdAtMs = createdAtMs
        self.updatedAtMs = updatedAtMs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        self.name = try c.decodeIfPresent(String.self, forKey: .name) ?? "AI 服务"
        self.presetId = try c.decodeIfPresent(String.self, forKey: .presetId) ?? "custom"
        let rawProto = try c.decodeIfPresent(String.self, forKey: .protocolType)
        self.protocolType = AiApiProtocol.fromId(rawProto)
        let rawAuth = try c.decodeIfPresent(String.self, forKey: .authMode)
        self.authMode = AiAuthMode.fromId(rawAuth)
        self.baseUrl = try c.decodeIfPresent(String.self, forKey: .baseUrl) ?? ""
        self.model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
        self.fastModel = try c.decodeIfPresent(String.self, forKey: .fastModel) ?? ""
        self.accountLabel = try c.decodeIfPresent(String.self, forKey: .accountLabel) ?? ""
        self.createdAtMs = try c.decodeIfPresent(Int64.self, forKey: .createdAtMs) ?? 0
        self.updatedAtMs = try c.decodeIfPresent(Int64.self, forKey: .updatedAtMs) ?? 0
    }

    public var secretKeychainKey: String {
        "marco_ai_profile_secret_\(id)"
    }
}

public struct AiConfig: Codable, Hashable, Sendable {
    public var enabled: Bool
    public var authMode: AiAuthMode
    public var protocolType: AiApiProtocol
    public var baseUrl: String
    public var model: String
    public var fastModel: String
    public var activeProfileId: String
    public var timeoutSeconds: Int
    public var monthlyTokenBudget: Int
    public var nlSearchEnabled: Bool
    public var titleCleanupEnabled: Bool
    public var subtitleTranslateEnabled: Bool
    public var spoilerFreeRecapEnabled: Bool
    public var moodCurationEnabled: Bool
    public var smartDiagnosticsEnabled: Bool
    public var danmuMatchEnabled: Bool

    private enum CodingKeys: String, CodingKey {
        case enabled, authMode
        case protocolType = "protocol"
        case baseUrl, model, fastModel, activeProfileId, timeoutSeconds, monthlyTokenBudget
        case nlSearchEnabled, titleCleanupEnabled, subtitleTranslateEnabled
        case spoilerFreeRecapEnabled, moodCurationEnabled, smartDiagnosticsEnabled, danmuMatchEnabled
    }

    public init(
        enabled: Bool = false,
        authMode: AiAuthMode = .apiKey,
        protocolType: AiApiProtocol = .openaiCompatible,
        baseUrl: String = "",
        model: String = "",
        fastModel: String = "",
        activeProfileId: String = "",
        timeoutSeconds: Int = 25,
        monthlyTokenBudget: Int = 500_000,
        nlSearchEnabled: Bool = true,
        titleCleanupEnabled: Bool = true,
        subtitleTranslateEnabled: Bool = true,
        spoilerFreeRecapEnabled: Bool = true,
        moodCurationEnabled: Bool = true,
        smartDiagnosticsEnabled: Bool = true,
        danmuMatchEnabled: Bool = true
    ) {
        self.enabled = enabled
        self.authMode = authMode
        self.protocolType = protocolType
        self.baseUrl = baseUrl
        self.model = model
        self.fastModel = fastModel
        self.activeProfileId = activeProfileId
        self.timeoutSeconds = min(max(timeoutSeconds, 5), 120)
        self.monthlyTokenBudget = max(0, monthlyTokenBudget)
        self.nlSearchEnabled = nlSearchEnabled
        self.titleCleanupEnabled = titleCleanupEnabled
        self.subtitleTranslateEnabled = subtitleTranslateEnabled
        self.spoilerFreeRecapEnabled = spoilerFreeRecapEnabled
        self.moodCurationEnabled = moodCurationEnabled
        self.smartDiagnosticsEnabled = smartDiagnosticsEnabled
        self.danmuMatchEnabled = danmuMatchEnabled
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            enabled: try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false,
            authMode: AiAuthMode.fromId(try c.decodeIfPresent(String.self, forKey: .authMode)),
            protocolType: AiApiProtocol.fromId(try c.decodeIfPresent(String.self, forKey: .protocolType)),
            baseUrl: try c.decodeIfPresent(String.self, forKey: .baseUrl) ?? "",
            model: try c.decodeIfPresent(String.self, forKey: .model) ?? "",
            fastModel: try c.decodeIfPresent(String.self, forKey: .fastModel) ?? "",
            activeProfileId: try c.decodeIfPresent(String.self, forKey: .activeProfileId) ?? "",
            timeoutSeconds: try c.decodeIfPresent(Int.self, forKey: .timeoutSeconds) ?? 25,
            monthlyTokenBudget: try c.decodeIfPresent(Int.self, forKey: .monthlyTokenBudget) ?? 500_000,
            nlSearchEnabled: try c.decodeIfPresent(Bool.self, forKey: .nlSearchEnabled) ?? true,
            titleCleanupEnabled: try c.decodeIfPresent(Bool.self, forKey: .titleCleanupEnabled) ?? true,
            subtitleTranslateEnabled: try c.decodeIfPresent(Bool.self, forKey: .subtitleTranslateEnabled) ?? true,
            spoilerFreeRecapEnabled: try c.decodeIfPresent(Bool.self, forKey: .spoilerFreeRecapEnabled) ?? true,
            moodCurationEnabled: try c.decodeIfPresent(Bool.self, forKey: .moodCurationEnabled) ?? true,
            smartDiagnosticsEnabled: try c.decodeIfPresent(Bool.self, forKey: .smartDiagnosticsEnabled) ?? true,
            danmuMatchEnabled: try c.decodeIfPresent(Bool.self, forKey: .danmuMatchEnabled) ?? true
        )
    }
}

public struct AiSearchSuggestion: Codable, Hashable, Identifiable, Sendable {
    public var id: String { "\(title)|\(year)" }
    public var title: String
    public var year: String
    public var reason: String
    public var keywords: [String]

    public init(title: String, year: String = "", reason: String = "", keywords: [String] = []) {
        self.title = title
        self.year = year
        self.reason = reason
        self.keywords = keywords
    }
}

public struct AiUsageSummary: Codable, Hashable, Sendable {
    public var monthKey: String
    public var promptTokens: Int
    public var completionTokens: Int
    public var requestCount: Int
    public var updatedAtMs: Int64

    public init(
        monthKey: String = "",
        promptTokens: Int = 0,
        completionTokens: Int = 0,
        requestCount: Int = 0,
        updatedAtMs: Int64 = 0
    ) {
        self.monthKey = monthKey
        self.promptTokens = max(0, promptTokens)
        self.completionTokens = max(0, completionTokens)
        self.requestCount = max(0, requestCount)
        self.updatedAtMs = max(0, updatedAtMs)
    }

    public var totalTokens: Int {
        promptTokens + completionTokens
    }
}

// MARK: - Discovery, Metadata, Casting, Updates, Backup, Playback, Migration

public struct CuratedModule: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var subtitle: String
    public var layout: String
    public var items: [CmsVideo]
    public var updatedAt: Int64

    public init(
        id: String,
        title: String,
        subtitle: String = "",
        layout: String = "poster_row",
        items: [CmsVideo] = [],
        updatedAt: Int64 = 0
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.layout = layout
        self.items = items
        self.updatedAt = updatedAt
    }
}

public struct EpisodeRichMetadata: Codable, Hashable, Identifiable, Sendable {
    public var id: String { "\(seasonNumber)x\(episodeNumber)|\(title)" }
    public var seasonNumber: Int
    public var episodeNumber: Int
    public var title: String
    public var overview: String
    public var stillUrl: String
    public var airDate: String
    public var runtimeMinutes: Int?
    public var voteAverage: Double?

    public init(
        seasonNumber: Int = 1,
        episodeNumber: Int,
        title: String,
        overview: String = "",
        stillUrl: String = "",
        airDate: String = "",
        runtimeMinutes: Int? = nil,
        voteAverage: Double? = nil
    ) {
        self.seasonNumber = seasonNumber
        self.episodeNumber = episodeNumber
        self.title = title
        self.overview = overview
        self.stillUrl = stillUrl
        self.airDate = airDate
        self.runtimeMinutes = runtimeMinutes
        self.voteAverage = voteAverage
    }
}

public struct CastDevice: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var host: String
    public var controlUrl: String
    public var serviceType: String
    public var protocolKind: String

    public init(
        id: String,
        name: String,
        host: String,
        controlUrl: String = "",
        serviceType: String = "urn:schemas-upnp-org:service:AVTransport:1",
        protocolKind: String = "dlna"
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.controlUrl = controlUrl
        self.serviceType = serviceType
        self.protocolKind = protocolKind
    }
}

public struct AppUpdateRelease: Codable, Hashable, Sendable {
    public var version: String
    public var buildNumber: Int
    public var releaseNotes: String
    public var downloadUrl: String
    public var sha256: String
    public var mandatory: Bool
    public var publishedAt: String

    public init(
        version: String,
        buildNumber: Int = 0,
        releaseNotes: String = "",
        downloadUrl: String = "",
        sha256: String = "",
        mandatory: Bool = false,
        publishedAt: String = ""
    ) {
        self.version = version
        self.buildNumber = buildNumber
        self.releaseNotes = releaseNotes
        self.downloadUrl = downloadUrl
        self.sha256 = sha256
        self.mandatory = mandatory
        self.publishedAt = publishedAt
    }
}

public struct BackupPayload: Codable, Hashable, Sendable {
    public static let backupFormat = "MarcoMovie-1"
    public static let backupSchema = "marco-movie-backup"
    public static let currentVersion = 1

    public var format: String
    public var schema: String
    public var version: Int
    public var exportedAt: Int64
    public var origin: String
    public var rawConfig: String
    public var subscriptions: [SubscriptionEntry]
    public var watchHistory: [WatchHistoryItem]
    public var favorites: [FavoriteItem]
    public var searchHistory: [String]
    public var preferences: PlaybackPreferences

    public init(
        format: String = Self.backupFormat,
        schema: String = Self.backupSchema,
        version: Int = Self.currentVersion,
        exportedAt: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        origin: String = "",
        rawConfig: String = "",
        subscriptions: [SubscriptionEntry] = [],
        watchHistory: [WatchHistoryItem] = [],
        favorites: [FavoriteItem] = [],
        searchHistory: [String] = [],
        preferences: PlaybackPreferences = PlaybackPreferences()
    ) {
        self.format = format
        self.schema = schema
        self.version = version
        self.exportedAt = exportedAt
        self.origin = origin
        self.rawConfig = rawConfig
        self.subscriptions = subscriptions
        self.watchHistory = watchHistory
        self.favorites = favorites
        self.searchHistory = searchHistory
        self.preferences = preferences
    }
}

public struct ResolvedPlayback: Hashable, Sendable {
    public var originalUrl: String
    public var playableUrl: URL
    public var headers: [String: String]
    public var isProxied: Bool
    public var kernelLabel: String
    public var resolutionBadge: String
    public var rangeProxyResourceId: String?
    public var headerProxySessionId: String?

    public init(
        originalUrl: String,
        playableUrl: URL,
        headers: [String: String] = [:],
        isProxied: Bool = false,
        kernelLabel: String = "AVPlayer 硬解",
        resolutionBadge: String = "",
        rangeProxyResourceId: String? = nil,
        headerProxySessionId: String? = nil
    ) {
        self.originalUrl = originalUrl
        self.playableUrl = playableUrl
        self.headers = headers
        self.isProxied = isProxied
        self.kernelLabel = kernelLabel
        self.resolutionBadge = resolutionBadge
        self.rangeProxyResourceId = rangeProxyResourceId
        self.headerProxySessionId = headerProxySessionId
    }
}

public struct LegacyMigrationReport: Codable, Hashable, Sendable {
    public var performed: Bool
    public var alreadyCompleted: Bool
    public var subscriptionsMigrated: Int
    public var watchHistoryMigrated: Int
    public var favoritesMigrated: Int
    public var privateFavoritesMigrated: Int
    public var standaloneLivesMigrated: Int
    public var downloadsMigrated: Int
    public var credentialsMigrated: Int
    public var mediaAccountsMigrated: Int
    public var aiProfilesMigrated: Int
    public var privacyPinMigrated: Bool
    public var warnings: [String]

    public init(
        performed: Bool = false,
        alreadyCompleted: Bool = false,
        subscriptionsMigrated: Int = 0,
        watchHistoryMigrated: Int = 0,
        favoritesMigrated: Int = 0,
        privateFavoritesMigrated: Int = 0,
        standaloneLivesMigrated: Int = 0,
        downloadsMigrated: Int = 0,
        credentialsMigrated: Int = 0,
        mediaAccountsMigrated: Int = 0,
        aiProfilesMigrated: Int = 0,
        privacyPinMigrated: Bool = false,
        warnings: [String] = []
    ) {
        self.performed = performed
        self.alreadyCompleted = alreadyCompleted
        self.subscriptionsMigrated = subscriptionsMigrated
        self.watchHistoryMigrated = watchHistoryMigrated
        self.favoritesMigrated = favoritesMigrated
        self.privateFavoritesMigrated = privateFavoritesMigrated
        self.standaloneLivesMigrated = standaloneLivesMigrated
        self.downloadsMigrated = downloadsMigrated
        self.credentialsMigrated = credentialsMigrated
        self.mediaAccountsMigrated = mediaAccountsMigrated
        self.aiProfilesMigrated = aiProfilesMigrated
        self.privacyPinMigrated = privacyPinMigrated
        self.warnings = warnings
    }
}
