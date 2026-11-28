// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only

import CoreFoundation
import Foundation

public enum CmsParser {
    public static let maxHistoryEntries = 60
    public static let maxFavoriteEntries = 120
    public static let episodePageSize = 50

    // MARK: - URL Normalization & RFC 3986 Relative Resolution

    public static func extractAndNormalizeUrl(_ rawInput: String) -> String {
        var s = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "“", with: "\"")
            .replacingOccurrences(of: "”", with: "\"")
            .replacingOccurrences(of: "‘", with: "'")
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "：", with: ":")
            .replacingOccurrences(of: "／", with: "/")
        if s.isEmpty { return "" }

        if let regex = try? NSRegularExpression(pattern: #"https?://[^\s"'<>`|]+"#, options: [.caseInsensitive]),
           let match = regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
           let range = Range(match.range, in: s)
        {
            s = String(s[range])
        } else if !s.hasPrefix("{")
            && !s.hasPrefix("[")
            && !s.lowercased().hasPrefix("http://")
            && !s.lowercased().hasPrefix("https://")
            && s.contains(".")
            && !s.contains("\n")
        {
            let token = s.components(separatedBy: .whitespacesAndNewlines).first ?? s
            s = ["http", "://", token].joined()
        }
        return normalizeUrl(s)
    }

    public static func normalizeUrl(_ rawUrl: String) -> String {
        let trimmed = rawUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        guard let schemeEnd = trimmed.range(of: "://") else { return trimmed }
        let scheme = trimmed[..<schemeEnd.lowerBound].lowercased()
        guard scheme == "http" || scheme == "https" else { return trimmed }

        let afterScheme = String(trimmed[schemeEnd.upperBound...])
        let boundaryIdx = afterScheme.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) ?? afterScheme.endIndex
        let authority = String(afterScheme[..<boundaryIdx])
        let rest = String(afterScheme[boundaryIdx...])

        var userInfo = ""
        var hostPort = authority
        if let atIdx = authority.lastIndex(of: "@") {
            userInfo = String(authority[...atIdx])
            hostPort = String(authority[authority.index(after: atIdx)...])
        }

        var host = hostPort
        var port = ""
        if !hostPort.hasPrefix("[") {
            if let colonIdx = hostPort.lastIndex(of: ":"), colonIdx > hostPort.startIndex {
                host = String(hostPort[..<colonIdx])
                port = String(hostPort[colonIdx...])
            }
            host = idnToAscii(host)
        }
        return "\(scheme)://\(userInfo)\(host)\(port)\(rest)"
    }

    public static func resolveUrl(base: String, relative: String) -> String {
        let trimmed = relative.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            return normalizeUrl(trimmed)
        }
        if lower.hasPrefix("csp_") {
            return trimmed
        }
        let cleanBase = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanBase.isEmpty else { return trimmed }
        let normBase = normalizeUrl(cleanBase)
        guard let schemeRange = normBase.range(of: "://") else { return trimmed }
        let baseScheme = String(normBase[..<schemeRange.lowerBound]).lowercased()
        guard baseScheme == "http" || baseScheme == "https" else { return trimmed }

        if trimmed.hasPrefix("//") {
            return normalizeUrl("\(baseScheme):\(trimmed)")
        }

        let afterScheme = String(normBase[schemeRange.upperBound...])
        let pathStart = afterScheme.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) ?? afterScheme.endIndex
        let baseAuthority = String(afterScheme[..<pathStart])
        guard !baseAuthority.isEmpty else { return trimmed }

        let baseRemainder = String(afterScheme[pathStart...])
        let basePathOnly: String = {
            let cut = baseRemainder.firstIndex(where: { $0 == "?" || $0 == "#" }) ?? baseRemainder.endIndex
            let p = String(baseRemainder[..<cut])
            return p.isEmpty ? "/" : p
        }()

        let relSuffixIdx = trimmed.firstIndex(where: { $0 == "?" || $0 == "#" }) ?? trimmed.endIndex
        let relPath = String(trimmed[..<relSuffixIdx])
        let relSuffix = String(trimmed[relSuffixIdx...])

        let mergedPath: String
        if relPath.isEmpty {
            mergedPath = basePathOnly
        } else if relPath.hasPrefix("/") {
            mergedPath = removeDotSegments(relPath)
        } else {
            let baseDir: String
            if let lastSlash = basePathOnly.lastIndex(of: "/") {
                baseDir = String(basePathOnly[...lastSlash])
            } else {
                baseDir = "/"
            }
            mergedPath = removeDotSegments(baseDir + relPath)
        }
        return normalizeUrl("\(baseScheme)://\(baseAuthority)\(mergedPath)\(relSuffix)")
    }

    private static func removeDotSegments(_ path: String) -> String {
        var input = path
        var output: [String] = []
        while !input.isEmpty {
            if input.hasPrefix("../") {
                input.removeFirst(3)
            } else if input.hasPrefix("./") {
                input.removeFirst(2)
            } else if input.hasPrefix("/./") {
                input = "/" + String(input.dropFirst(3))
            } else if input == "/." {
                input = "/"
            } else if input.hasPrefix("/../") {
                input = "/" + String(input.dropFirst(4))
                if !output.isEmpty { output.removeLast() }
            } else if input == "/.." {
                input = "/"
                if !output.isEmpty { output.removeLast() }
            } else if input == "." || input == ".." {
                input = ""
            } else {
                var segStart = input.startIndex
                var hasLeadingSlash = false
                if input.first == "/" {
                    hasLeadingSlash = true
                    segStart = input.index(after: segStart)
                }
                let nextSlash = input[segStart...].firstIndex(of: "/") ?? input.endIndex
                let segment = (hasLeadingSlash ? "/" : "") + String(input[segStart..<nextSlash])
                output.append(segment)
                input = String(input[nextSlash...])
            }
        }
        let joined = output.joined()
        return joined.hasPrefix("/") ? joined : "/" + joined
    }

    public static func normalizeJarDeclaration(origin: String, declaration: String) -> String {
        let trimmed = declaration.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if let range = trimmed.range(of: ";md5;", options: [.caseInsensitive]) {
            let urlPart = String(trimmed[..<range.lowerBound])
            let suffix = String(trimmed[range.lowerBound...])
            return resolveUrl(base: origin, relative: urlPart) + suffix
        }
        return resolveUrl(base: origin, relative: trimmed)
    }

    private static func idnToAscii(_ domain: String) -> String {
        let normalized = domain
            .replacingOccurrences(of: "\u{3002}", with: ".")
            .replacingOccurrences(of: "\u{FF0E}", with: ".")
            .replacingOccurrences(of: "\u{FF61}", with: ".")
        return normalized.components(separatedBy: ".").map { label in
            guard !label.isEmpty else { return "" }
            if label.unicodeScalars.allSatisfy({ $0.value < 0x80 }) {
                return label
            }
            return "xn--" + punycodeEncode(label.lowercased())
        }.joined(separator: ".")
    }

    private static func punycodeEncode(_ input: String) -> String {
        let base = 36, tMin = 1, tMax = 26, skew = 38, damp = 700, initialBias = 72, initialN = 0x80
        func adapt(_ delta: Int, _ numPoints: Int, _ firstTime: Bool) -> Int {
            var d = firstTime ? (delta / damp) : (delta >> 1)
            d += d / numPoints
            var k = 0
            while d > ((base - tMin) * tMax) / 2 {
                d /= (base - tMin)
                k += base
            }
            return k + (((base - tMin + 1) * d) / (d + skew))
        }
        func encodeDigit(_ d: Int) -> UnicodeScalar {
            UnicodeScalar(d + 22 + 75 * (d < 26 ? 1 : 0))!
        }
        let cps = input.unicodeScalars.map { Int($0.value) }
        var out = ""
        var basicCount = 0
        for cp in cps where cp < 0x80 {
            out.unicodeScalars.append(UnicodeScalar(cp)!)
            basicCount += 1
        }
        if basicCount > 0 { out.append("-") }
        var n = initialN
        var delta = 0
        var bias = initialBias
        var handled = basicCount
        while handled < cps.count {
            var m = Int.max
            for cp in cps where cp >= n && cp < m { m = cp }
            delta += (m - n) * (handled + 1)
            n = m
            for cp in cps {
                if cp < n {
                    delta += 1
                } else if cp == n {
                    var q = delta
                    var k = base
                    while true {
                        let t = k <= bias ? tMin : (k >= bias + tMax ? tMax : k - bias)
                        if q < t { break }
                        out.unicodeScalars.append(encodeDigit(t + ((q - t) % (base - t))))
                        q = (q - t) / (base - t)
                        k += base
                    }
                    out.unicodeScalars.append(encodeDigit(q))
                    bias = adapt(delta, handled + 1, handled == basicCount)
                    delta = 0
                    handled += 1
                }
            }
            delta += 1
            n += 1
        }
        return out
    }

    // MARK: - Config Parsing

    public static func decodeConfigDocument(_ rawBytes: Data) throws -> String {
        try ConfigDecoder.decodeConfigDocument(rawBytes)
    }

    public static func decodeTextDocument(_ rawBytes: Data) throws -> String {
        try ConfigDecoder.decodeTextDocument(rawBytes)
    }

    private enum ConfigJsonRootShape {
        case topLevelSitesArray([Any])
        case singleSiteObject([String: Any])
        case standardObject([String: Any])
    }

    private static func classifyConfigJsonRoot(_ rawAny: Any) -> ConfigJsonRootShape? {
        if let arr = rawAny as? [Any] {
            return .topLevelSitesArray(arr)
        }
        guard let obj = rawAny as? [String: Any] else {
            return nil
        }
        let isDirectVodListing = isMissing(obj["sites"])
            && isMissing(obj["lives"])
            && isMissing(obj["urls"])
            && isMissing(obj["storeHouse"])
            && isMissing(obj["depots"])
            && (obj["list"] is [Any] || obj["class"] is [Any])
        if !isDirectVodListing
            && isMissing(obj["sites"])
            && !isMissing(obj["api"])
            && (!isMissing(obj["name"]) || !isMissing(obj["key"]))
        {
            return .singleSiteObject(obj)
        }
        return .standardObject(obj)
    }

    private static func isPrivateChildConfigItem(_ item: [String: Any], defaultGroup: String) -> Bool {
        let privFlag = item["isPrivate"] ?? item["private"] ?? item["hidden"]
        if asBool(privFlag, fallback: false) {
            return true
        }
        if nonNullString(item["space"]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "private" {
            return true
        }
        let itemGroup = nonNullString(item["group"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveGroup = itemGroup.isEmpty ? defaultGroup : itemGroup
        return effectiveGroup.contains("隐私") || effectiveGroup.contains("私密")
    }

    public static func sanitizePublicRawConfig(_ rawContent: String, defaultGroup: String = "") -> String {
        let trimmed = rawContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return rawContent }
        if defaultGroup.contains("隐私") || defaultGroup.contains("私密") {
            return ""
        }
        let cleaned = ConfigDecoder.stripJsonComments(ConfigDecoder.unpackConfigText(trimmed))
        guard let data = cleaned.data(using: .utf8),
              let rawAny = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let rootShape = classifyConfigJsonRoot(rawAny)
        else {
            return rawContent
        }

        switch rootShape {
        case .topLevelSitesArray(let arr):
            var removedAny = false
            let filtered = arr.filter { entry in
                guard let dict = entry as? [String: Any] else { return true }
                if isPrivateChildConfigItem(dict, defaultGroup: defaultGroup) {
                    removedAny = true
                    return false
                }
                return true
            }
            guard removedAny else { return rawContent }
            guard !filtered.isEmpty else { return "" }
            guard let sanitizedData = try? JSONSerialization.data(
                withJSONObject: filtered,
                options: [.sortedKeys, .withoutEscapingSlashes]
            ) else {
                return ""
            }
            return String(decoding: sanitizedData, as: UTF8.self)

        case .singleSiteObject(let obj):
            if isPrivateChildConfigItem(obj, defaultGroup: defaultGroup) {
                return ""
            }
            return rawContent

        case .standardObject(var root):
            var removedAny = false

            if let rawSites = root["sites"] as? [Any] {
                var sitesChanged = false
                let filteredSites = rawSites.filter { entry in
                    guard let dict = entry as? [String: Any] else { return true }
                    if isPrivateChildConfigItem(dict, defaultGroup: defaultGroup) {
                        removedAny = true
                        sitesChanged = true
                        return false
                    }
                    return true
                }
                if sitesChanged {
                    root["sites"] = filteredSites
                }
            }

            if let rawLives = root["lives"] as? [Any] {
                var livesChanged = false
                let filteredLives = rawLives.filter { entry in
                    guard let dict = entry as? [String: Any] else { return true }
                    if isPrivateChildConfigItem(dict, defaultGroup: defaultGroup) {
                        removedAny = true
                        livesChanged = true
                        return false
                    }
                    return true
                }
                if livesChanged {
                    root["lives"] = filteredLives
                }
            } else if let singleLive = root["lives"] as? [String: Any],
                      isPrivateChildConfigItem(singleLive, defaultGroup: defaultGroup)
            {
                removedAny = true
                root["lives"] = []
            }

            for depotField in ["urls", "storeHouse", "depots"] {
                if let rawDepots = root[depotField] as? [Any] {
                    var depotsChanged = false
                    let filteredDepots = rawDepots.filter { entry in
                        guard let dict = entry as? [String: Any] else { return true }
                        if isPrivateChildConfigItem(dict, defaultGroup: defaultGroup) {
                            removedAny = true
                            depotsChanged = true
                            return false
                        }
                        return true
                    }
                    if depotsChanged {
                        root[depotField] = filteredDepots
                    }
                }
            }

            guard removedAny else { return rawContent }
            let remainingSites = (root["sites"] as? [Any])?.count ?? 0
            let remainingLives: Int = {
                if let arr = root["lives"] as? [Any] { return arr.count }
                if let val = root["lives"], !(val is NSNull) { return 1 }
                return 0
            }()
            let remainingDepots = ["urls", "storeHouse", "depots"].reduce(0) { acc, field in
                acc + ((root[field] as? [Any])?.count ?? 0)
            }
            if remainingSites == 0 && remainingLives == 0 && remainingDepots == 0 {
                return ""
            }
            guard let sanitizedData = try? JSONSerialization.data(
                withJSONObject: root,
                options: [.sortedKeys, .withoutEscapingSlashes]
            ) else {
                return ""
            }
            return String(decoding: sanitizedData, as: UTF8.self)
        }
    }

    public static func parseConfig(
        _ rawJson: String,
        origin: String = "",
        defaultGroup: String = "默认分组",
        isPrivate: Bool = false,
        subscriptionId: String = "",
        defaultName: String = ""
    ) throws -> CmsConfig {
        let groupLabel = defaultGroup.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "默认分组"
            : defaultGroup.trimmingCharacters(in: .whitespacesAndNewlines)
        let parentPrivate = isPrivate || groupLabel.contains("隐私") || groupLabel.contains("私密")
        let unpacked = ConfigDecoder.unpackConfigText(rawJson)
        let trimmedUnpacked = unpacked.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedUnpacked.isEmpty {
            throw MarcoError.emptyConfiguration
        }

        if ConfigDecoder.looksLikeScript(trimmedUnpacked) {
            let isPython = trimmedUnpacked.contains("class Spider")
            let apiName: String
            if isPython {
                apiName = "csp_LocalScript.py"
            } else if trimmedUnpacked.contains("export default")
                || trimmedUnpacked.contains("module.exports")
                || trimmedUnpacked.contains("__jsEvalReturn")
            {
                apiName = "csp_LocalScript.js"
            } else {
                apiName = "csp_LocalRule.js"
            }
            let extObj: [String: String] = ["script": trimmedUnpacked, "origin": origin]
            let extData = (try? JSONSerialization.data(withJSONObject: extObj)) ?? Data()
            let extStr = String(decoding: extData, as: UTF8.self)
            return CmsConfig(sites: [
                CmsSite(
                    key: "script_\(subscriptionId.isEmpty ? "imported" : subscriptionId)",
                    name: defaultName.isEmpty ? (isPython ? "Python 订阅" : "JavaScript 订阅") : defaultName,
                    type: 3,
                    api: apiName,
                    ext: extStr,
                    group: groupLabel,
                    isPrivate: parentPrivate,
                    subscriptionId: subscriptionId
                ),
            ])
        }

        if trimmedUnpacked.hasPrefix("<") {
            let lowerXml = trimmedUnpacked.lowercased()
            if lowerXml.contains("<rss") || lowerXml.contains("<list") || lowerXml.contains("<video") {
                let apiUrl = origin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? ""
                    : cleanVodEndpointUrl(origin)
                let siteName = !defaultName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? defaultName.trimmingCharacters(in: .whitespacesAndNewlines)
                    : inferSiteNameFromUrl(apiUrl, fallback: "XML 影视源")
                let siteKey = "xml_\(shortHash(apiUrl.isEmpty ? trimmedUnpacked : apiUrl))"
                return CmsConfig(sites: [
                    CmsSite(
                        key: siteKey,
                        name: siteName,
                        type: 0,
                        api: apiUrl.isEmpty ? "m3u_vod://xml_inline" : apiUrl,
                        ext: apiUrl.isEmpty ? trimmedUnpacked : "",
                        group: groupLabel,
                        isPrivate: parentPrivate,
                        subscriptionId: subscriptionId
                    ),
                ])
            }
        }

        let cleaned = ConfigDecoder.stripJsonComments(unpacked)
        if cleaned.isEmpty {
            throw MarcoError.emptyConfiguration
        }
        let isJsonStructure = cleaned.hasPrefix("{") || cleaned.hasPrefix("[")

        if !isJsonStructure
            && (trimmedUnpacked.hasPrefix("#EXTM3U")
                || trimmedUnpacked.contains("#EXTINF")
                || trimmedUnpacked.contains(",#genre#"))
        {
            if let liveCfg = tryParseM3uOrTxtConfig(
                trimmedUnpacked,
                origin: origin,
                groupLabel: groupLabel,
                isPrivate: parentPrivate,
                subscriptionId: subscriptionId,
                defaultName: defaultName
            ) {
                return liveCfg
            }
        }

        let rawAny: Any
        do {
            rawAny = try JSONSerialization.jsonObject(with: Data(cleaned.utf8), options: [.fragmentsAllowed])
        } catch {
            if let liveCfg = tryParseM3uOrTxtConfig(
                trimmedUnpacked,
                origin: origin,
                groupLabel: groupLabel,
                isPrivate: parentPrivate,
                subscriptionId: subscriptionId,
                defaultName: defaultName
            ) {
                return liveCfg
            }
            throw MarcoError.invalidFormat("不是有效的 JSON / VOD / M3U 配置格式：\(error.localizedDescription)")
        }

        guard let rootShape = classifyConfigJsonRoot(rawAny) else {
            throw MarcoError.invalidFormat("配置根节点必须是 JSON 对象")
        }

        var decoded: [String: Any]
        switch rootShape {
        case .topLevelSitesArray(let arr):
            decoded = ["sites": arr]
        case .singleSiteObject(let obj):
            let sp = nonNullString(obj["spider"]).isEmpty ? nonNullString(obj["jar"]) : nonNullString(obj["spider"])
            decoded = [
                "spider": sp,
                "sites": [obj],
            ]
        case .standardObject(let obj):
            decoded = obj
        }

        if isMissing(decoded["sites"])
            && isMissing(decoded["lives"])
            && isMissing(decoded["urls"])
            && isMissing(decoded["storeHouse"])
            && isMissing(decoded["depots"])
            && (decoded["list"] is [Any] || decoded["class"] is [Any])
        {
            let apiUrl = origin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? ""
                : cleanVodEndpointUrl(origin)
            let siteName = !defaultName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? defaultName.trimmingCharacters(in: .whitespacesAndNewlines)
                : inferSiteNameFromUrl(apiUrl, fallback: "VOD 影视源")
            let siteKey = "vod_\(shortHash(apiUrl.isEmpty ? cleaned : apiUrl))"
            return CmsConfig(sites: [
                CmsSite(
                    key: siteKey,
                    name: siteName,
                    type: 1,
                    api: apiUrl.isEmpty ? "m3u_vod://json_inline" : apiUrl,
                    ext: apiUrl.isEmpty ? cleaned : "",
                    group: groupLabel,
                    isPrivate: parentPrivate,
                    subscriptionId: subscriptionId
                ),
            ])
        }

        var depots: [CmsDepot] = []
        var seenDepotUrls = Set<String>()
        for field in ["urls", "storeHouse", "depots"] {
            guard let rawDepots = decoded[field] as? [Any] else { continue }
            for entry in rawDepots {
                guard let item = entry as? [String: Any] else { continue }
                let rawUrl = firstNonEmpty(item["url"], item["sourceUrl"], item["api"])
                guard !rawUrl.isEmpty, looksLikeDepotUrl(rawUrl) else { continue }
                let normalizedInput = rawUrl.lowercased().hasPrefix("http") ? normalizeUrl(rawUrl) : rawUrl
                let resolved = resolveUrl(base: origin, relative: normalizedInput)
                let lowerResolved = resolved.lowercased()
                guard lowerResolved.hasPrefix("http://") || lowerResolved.hasPrefix("https://") else { continue }
                guard seenDepotUrls.insert(resolved).inserted else { continue }
                let rawName = firstNonEmpty(item["name"], item["sourceName"])
                let depotName = rawName.isEmpty ? "仓库 \(depots.count + 1)" : rawName
                let depotPrivate = parentPrivate || isPrivateChildConfigItem(item, defaultGroup: groupLabel)
                depots.append(CmsDepot(name: depotName, url: resolved, subscriptionId: subscriptionId, isPrivate: depotPrivate))
            }
        }

        let spiderDecl = firstNonEmpty(decoded["spider"], decoded["jar"])
        let spider = normalizeJarDeclaration(origin: origin, declaration: spiderDecl)

        var parses: [CmsParse] = []
        var defaultJsonParseUrl = ""
        if let rawParses = decoded["parses"] as? [Any] {
            for entry in rawParses {
                guard let p = entry as? [String: Any] else { continue }
                let pUrl = nonNullString(p["url"]).trimmingCharacters(in: .whitespacesAndNewlines)
                let pType = asInt(p["type"], fallback: 0)
                let lowerPUrl = pUrl.lowercased()
                if lowerPUrl.hasPrefix("http://") || lowerPUrl.hasPrefix("https://") {
                    let pName = nonNullString(p["name"]).trimmingCharacters(in: .whitespacesAndNewlines)
                    parses.append(
                        CmsParse(
                            name: pName.isEmpty ? "解析" : pName,
                            url: pUrl,
                            type: pType,
                            headers: extractSiteHeaders(p)
                        )
                    )
                    if defaultJsonParseUrl.isEmpty && (pType == 1 || pType == 2 || pType == 3) {
                        defaultJsonParseUrl = pUrl
                    }
                }
            }
        }

        var sniffRules: [CmsSniffRule] = []
        if let rawRules = decoded["rules"] as? [Any] {
            for entry in rawRules {
                guard let map = entry as? [String: Any] else { continue }
                let rule = CmsSniffRule.fromDictionary(map)
                if !rule.isEmpty {
                    sniffRules.append(rule)
                }
            }
        }

        var adHosts: [String] = []
        if let rawAds = decoded["ads"] as? [Any] {
            var seenAds = Set<String>()
            for entry in rawAds {
                let s = nonNullString(entry).trimmingCharacters(in: .whitespacesAndNewlines)
                if !s.isEmpty && seenAds.insert(s.lowercased()).inserted {
                    adHosts.append(s)
                }
            }
        }

        var sites: [CmsSite] = []
        var seenKeys = Set<String>()
        if let rawSites = decoded["sites"] as? [Any] {
            for (i, entry) in rawSites.enumerated() {
                guard let item = entry as? [String: Any] else { continue }
                var key = firstNonEmpty(item["key"], item["name"])
                if key.isEmpty { key = "site-\(i)" }
                let rawName = nonNullString(item["name"]).trimmingCharacters(in: .whitespacesAndNewlines)
                let name = rawName.isEmpty ? key : rawName
                var type = asInt(item["type"], fallback: -1)
                let api = resolveUrl(base: origin, relative: nonNullString(item["api"]))
                if key.isEmpty || api.isEmpty { continue }

                let lowerApi = api.lowercased()
                if type == -1 && (lowerApi.hasPrefix("http://") || lowerApi.hasPrefix("https://")) {
                    let path = (URL(string: api)?.path ?? api).lowercased()
                    type = (path.contains("xml") || path.hasSuffix(".xml")) ? 0 : 1
                }
                if !seenKeys.insert(key).inserted {
                    key = "\(key)-\(i)"
                    seenKeys.insert(key)
                }

                var rawItemExt = item["ext"]
                if let extMap = rawItemExt as? [String: Any],
                   !origin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                {
                    var normalizedMap = extMap
                    for field in ["json", "url", "rule"] {
                        if let val = normalizedMap[field] as? String {
                            let trimmedVal = val.trimmingCharacters(in: .whitespacesAndNewlines)
                            if trimmedVal.hasPrefix("./") || trimmedVal.hasPrefix("../") {
                                normalizedMap[field] = resolveUrl(base: origin, relative: trimmedVal)
                            }
                        }
                    }
                    rawItemExt = normalizedMap
                }

                var extStr = stringifyExt(rawItemExt)
                if api.lowercased() == "csp_drpy",
                   item["ext"] is String,
                   !ConfigDecoder.looksLikeScript(extStr),
                   !extStr.drop(while: { $0.isWhitespace }).hasPrefix("{")
                {
                    extStr = resolveUrl(base: origin, relative: extStr)
                } else if (extStr.hasPrefix("./") || extStr.hasPrefix("../"))
                    && !origin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                {
                    extStr = resolveUrl(base: origin, relative: extStr)
                }

                let itemGroup = nonNullString(item["group"]).trimmingCharacters(in: .whitespacesAndNewlines)
                let itemPrivate = parentPrivate || isPrivateChildConfigItem(item, defaultGroup: groupLabel)
                let itemPlayUrl = nonNullString(item["playUrl"]).trimmingCharacters(in: .whitespacesAndNewlines)
                let itemParse = asInt(item["parse"], fallback: 0)
                let itemJx = asInt(item["jx"], fallback: 0)
                let requiresParser = !itemPlayUrl.isEmpty || itemParse == 1 || itemJx == 1
                let extTooLarge = extStr.utf16.count > CmsSite.maxExtSize
                let itemHeaders = extractSiteHeaders(item)
                let itemUa = itemHeaders["User-Agent"] ?? nonNullString(item["ua"]).trimmingCharacters(in: .whitespacesAndNewlines)
                let itemCategories: [String] = {
                    if let arr = item["categories"] as? [Any] {
                        return arr.map { nonNullString($0).trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                    }
                    return []
                }()

                sites.append(
                    CmsSite(
                        key: key,
                        name: name.isEmpty ? key : name,
                        type: type,
                        api: api,
                        playUrl: !itemPlayUrl.isEmpty ? itemPlayUrl : defaultJsonParseUrl,
                        searchable: asBool(item["searchable"], fallback: true),
                        ext: extStr,
                        extTooLarge: extTooLarge,
                        requiresParser: requiresParser,
                        rawExtension: item["ext"] as? String,
                        jar: normalizeJarDeclaration(origin: origin, declaration: nonNullString(item["jar"])),
                        spider: spider,
                        headers: itemHeaders,
                        ua: itemUa,
                        categories: itemCategories,
                        group: itemGroup.isEmpty ? groupLabel : itemGroup,
                        isPrivate: itemPrivate,
                        subscriptionId: subscriptionId
                    )
                )
            }
        }

        var lives: [LiveSource] = []
        let rawLivesList: [Any] = {
            if let arr = decoded["lives"] as? [Any] { return arr }
            if let single = decoded["lives"], !(single is NSNull) { return [single] }
            return []
        }()
        for (index, entry) in rawLivesList.enumerated() {
            let item: [String: Any]
            if let s = entry as? String {
                item = ["url": s]
            } else if let m = entry as? [String: Any] {
                item = m
            } else {
                continue
            }
            let rawLiveName = nonNullString(item["name"]).trimmingCharacters(in: .whitespacesAndNewlines)
            let name = rawLiveName.isEmpty ? "直播源 \(index + 1)" : rawLiveName
            let itemGroup = nonNullString(item["group"]).trimmingCharacters(in: .whitespacesAndNewlines)
            let group = itemGroup.isEmpty ? groupLabel : itemGroup
            let hidden = parentPrivate || isPrivateChildConfigItem(item, defaultGroup: groupLabel)
            let headers = LiveCatalogParser.headers(from: item)
            let rawUrl = nonNullString(item["url"]).trimmingCharacters(in: .whitespacesAndNewlines)
            let api = nonNullString(item["api"]).trimmingCharacters(in: .whitespacesAndNewlines)

            var plugin: CmsSite?
            if !api.isEmpty {
                let rawExtVal = item["ext"]
                var extResolved = stringifyExt(rawExtVal)
                if (extResolved.hasPrefix("./") || extResolved.hasPrefix("../")) && !origin.isEmpty {
                    extResolved = resolveUrl(base: origin, relative: extResolved)
                }
                plugin = CmsSite(
                    key: "live-plugin:\(shortHash("\(origin)|\(index)|\(api)"))",
                    name: name,
                    type: 3,
                    api: resolveUrl(base: origin, relative: api),
                    ext: extResolved,
                    rawExtension: rawExtVal as? String,
                    jar: normalizeJarDeclaration(origin: origin, declaration: nonNullString(item["jar"])),
                    spider: spider,
                    headers: headers,
                    group: group,
                    isPrivate: hidden,
                    subscriptionId: subscriptionId
                )
            }

            var inlineContent = ""
            if let children = (item["groups"] as? [Any]) ?? (item["channels"] as? [Any]),
               !children.isEmpty || plugin == nil
            {
                let fieldKey = item["groups"] != nil ? "groups" : "channels"
                let inlineObj: [String: Any] = ["name": name, fieldKey: children]
                if let inlineData = try? JSONSerialization.data(withJSONObject: inlineObj) {
                    inlineContent = String(decoding: inlineData, as: UTF8.self)
                }
            }

            let resolvedUrl: String
            if plugin != nil {
                resolvedUrl = rawUrl
            } else if let dirUrl = LiveCatalogParser.directoryUrl(rawUrl, origin: origin) {
                resolvedUrl = dirUrl
            } else {
                resolvedUrl = resolveUrl(base: origin, relative: rawUrl)
            }

            let lowerResolved = resolvedUrl.lowercased()
            let isDataBase64 = lowerResolved.hasPrefix("data:text/plain") && lowerResolved.contains("base64,")
            if plugin != nil
                || !inlineContent.isEmpty
                || lowerResolved.hasPrefix("http://")
                || lowerResolved.hasPrefix("https://")
                || isDataBase64
            {
                lives.append(
                    LiveSource(
                        name: name,
                        url: resolvedUrl,
                        headers: headers,
                        group: group,
                        isPrivate: hidden,
                        subscriptionId: subscriptionId,
                        origin: origin,
                        inlineContent: inlineContent,
                        plugin: plugin
                    )
                )
            }
        }

        if sites.isEmpty && lives.isEmpty && depots.isEmpty {
            if let liveCatalogCfg = tryParseM3uOrTxtConfig(
                cleaned,
                origin: origin,
                groupLabel: groupLabel,
                isPrivate: parentPrivate,
                subscriptionId: subscriptionId,
                defaultName: defaultName
            ) {
                return liveCatalogCfg
            }
            throw MarcoError.invalidFormat("配置中未找到可用的 sites（片源）、lives（直播）或 urls（多仓列表）")
        }

        return CmsConfig(
            sites: sites,
            lives: lives,
            depots: depots,
            parses: parses,
            rules: sniffRules,
            ads: adHosts,
            spider: spider
        )
    }

    // MARK: - Categories, Filters & Listings (JSON + XML)

    public static func parseCategories(_ rawText: String) -> [CmsCategory] {
        let trimmed = String(rawText.drop(while: { $0.isWhitespace }))
        if trimmed.hasPrefix("<") {
            return parseXmlCategories(trimmed)
        }
        let cleaned = ConfigDecoder.stripJsonComments(rawText)
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(cleaned.utf8))) as? [String: Any] else {
            return []
        }
        let rawClassAny: Any? = {
            if let c = obj["class"] { return c }
            if let dataArr = obj["data"] as? [Any] { return dataArr }
            if let dataMap = obj["data"] as? [String: Any] {
                return dataMap["list"] ?? dataMap["class"] ?? dataMap["typelist"] ?? dataMap["type_list"]
            }
            return nil
        }()
        guard let rawClass = rawClassAny as? [Any] else { return [] }
        var categories: [CmsCategory] = []
        for entry in rawClass {
            guard let item = entry as? [String: Any] else { continue }
            let id = nonNullString(item["type_id"]).trimmingCharacters(in: .whitespacesAndNewlines)
            let name = nonNullString(item["type_name"]).trimmingCharacters(in: .whitespacesAndNewlines)
            let pid = nonNullString(item["type_pid"]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !id.isEmpty && !name.isEmpty {
                categories.append(CmsCategory(id: id, name: name, parentId: pid))
            }
        }
        return categories
    }

    public static func parseFilters(_ rawText: String) -> [String: [CmsFilterGroup]] {
        let cleaned = ConfigDecoder.stripJsonComments(rawText)
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(cleaned.utf8))) as? [String: Any],
              let rawFilters = obj["filters"] as? [String: Any]
        else {
            return [:]
        }
        var out: [String: [CmsFilterGroup]] = [:]
        for (typeId, rawGroupList) in rawFilters {
            guard let arr = rawGroupList as? [Any] else { continue }
            var groups: [CmsFilterGroup] = []
            for gAny in arr {
                guard let gMap = gAny as? [String: Any] else { continue }
                let key = nonNullString(gMap["key"]).trimmingCharacters(in: .whitespacesAndNewlines)
                let name = nonNullString(gMap["name"]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.isEmpty else { continue }
                var opts: [CmsFilterOption] = []
                if let vals = gMap["value"] as? [Any] {
                    for vAny in vals {
                        guard let vMap = vAny as? [String: Any] else { continue }
                        let optName = firstNonEmpty(vMap["n"], vMap["name"])
                        let optVal = firstNonEmpty(vMap["v"], vMap["value"])
                        if !optName.isEmpty {
                            opts.append(CmsFilterOption(name: optName, value: optVal))
                        }
                    }
                }
                if !opts.isEmpty {
                    groups.append(CmsFilterGroup(key: key, name: name.isEmpty ? key : name, options: opts))
                }
            }
            if !groups.isEmpty {
                out[typeId] = groups
            }
        }
        return out
    }

    public static func parseListing(_ rawText: String) throws -> CmsListing {
        let trimmed = String(rawText.drop(while: { $0.isWhitespace }))
        if trimmed.hasPrefix("<") {
            return parseXmlListing(trimmed)
        }
        let cleaned = ConfigDecoder.stripJsonComments(rawText)
        guard let decoded = (try? JSONSerialization.jsonObject(with: Data(cleaned.utf8))) as? [String: Any] else {
            return CmsListing()
        }

        let dataMap = decoded["data"] as? [String: Any]
        let page = max(1, asInt(decoded["page"] ?? dataMap?["page"], fallback: 1))
        let total = asInt(dataMap?["total"], fallback: 0)
        let limit = max(1, asInt(dataMap?["limit"], fallback: 20))
        let computedPages = (total > 0 && limit > 0) ? ((total + limit - 1) / limit) : 1
        let pageCount = max(1, asInt(decoded["pagecount"] ?? dataMap?["pagecount"], fallback: computedPages))
        let parsedFilters = parseFilters(cleaned)

        let rawListAny: Any? = {
            if let l = decoded["list"] as? [Any] { return l }
            if let dataArr = decoded["data"] as? [Any] { return dataArr }
            if let dm = dataMap {
                if let dl = dm["list"] as? [Any] { return dl }
                if !isMissing(dm["vod_id"]) || !isMissing(dm["vod_name"]) { return [dm] }
            }
            return nil
        }()
        guard let rawList = rawListAny as? [Any] else {
            return CmsListing(page: page, pageCount: pageCount, filters: parsedFilters)
        }

        var videos: [CmsVideo] = []
        for entry in rawList {
            guard let item = entry as? [String: Any] else { continue }
            let id = nonNullString(item["vod_id"]).trimmingCharacters(in: .whitespacesAndNewlines)
            let title = nonNullString(item["vod_name"]).trimmingCharacters(in: .whitespacesAndNewlines)
            if id.isEmpty && title.isEmpty { continue }

            var playFrom = nonNullString(item["vod_play_from"])
            var playUrl = nonNullString(item["vod_play_url"])

            if playUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let withPlayer = item["vod_url_with_player"] as? [Any]
            {
                var froms: [String] = []
                var urls: [String] = []
                for pAny in withPlayer {
                    guard let p = pAny as? [String: Any] else { continue }
                    let u = nonNullString(p["url"]).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !u.isEmpty else { continue }
                    let fromName = firstNonEmpty(p["name"], p["code"])
                    froms.append(fromName.isEmpty ? "默认线路" : fromName)
                    urls.append(u)
                }
                playFrom = froms.joined(separator: "$$$")
                playUrl = urls.joined(separator: "$$$")
            }

            if playUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let rawPlayList = item["vod_play_list"],
               !(rawPlayList is NSNull)
            {
                let entries: [[String: Any]]
                if let listArr = rawPlayList as? [Any] {
                    entries = listArr.compactMap { $0 as? [String: Any] }
                } else if let listDict = rawPlayList as? [String: Any] {
                    let sortedKeys = sortNaturalKeys(Array(listDict.keys))
                    entries = sortedKeys.compactMap { listDict[$0] as? [String: Any] }
                } else {
                    entries = []
                }

                var froms: [String] = []
                var urls: [String] = []
                for p in entries {
                    var u = nonNullString(p["url"]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if u.isEmpty, let urlsMap = p["urls"] as? [String: Any] {
                        let sortedKeys = sortNaturalKeys(Array(urlsMap.keys))
                        var segs: [String] = []
                        for k in sortedKeys {
                            guard let ep = urlsMap[k] as? [String: Any] else { continue }
                            let epUrl = nonNullString(ep["url"]).trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !epUrl.isEmpty else { continue }
                            let rawEpName = nonNullString(ep["name"]).trimmingCharacters(in: .whitespacesAndNewlines)
                            let epName = rawEpName.isEmpty ? "正片" : rawEpName
                            segs.append("\(epName)$\(epUrl)")
                        }
                        u = segs.joined(separator: "#")
                    }
                    guard !u.isEmpty else { continue }
                    let pInfo = p["player_info"] as? [String: Any]
                    let showName = firstNonEmpty(pInfo?["show"], pInfo?["from"])
                    let fallbackFrom = firstNonEmpty(p["from"], p["name"])
                    let finalFrom = !showName.isEmpty
                        ? showName
                        : (!fallbackFrom.isEmpty ? fallbackFrom : "默认线路")
                    froms.append(finalFrom)
                    urls.append(u)
                }
                playFrom = froms.joined(separator: "$$$")
                playUrl = urls.joined(separator: "$$$")
            }

            let remarks = nonNullString(item["vod_remarks"]).trimmingCharacters(in: .whitespacesAndNewlines)
            let desc = cleanHtml(nonNullString(item["vod_content"]))
            let douban = parseDoubanField(item["vod_douban_score"])

            let parsedLines: [CmsLine]
            if let structured = item["lines"] as? [Any] {
                parsedLines = parseStructuredLines(structured)
            } else {
                parsedLines = parseLines(playFrom: playFrom, playUrl: playUrl)
            }

            videos.append(
                CmsVideo(
                    id: id,
                    title: title,
                    poster: cleanPosterUrl(nonNullString(item["vod_pic"])),
                    remarks: remarks,
                    year: nonNullString(item["vod_year"]).trimmingCharacters(in: .whitespacesAndNewlines),
                    area: nonNullString(item["vod_area"]).trimmingCharacters(in: .whitespacesAndNewlines),
                    actor: nonNullString(item["vod_actor"]).trimmingCharacters(in: .whitespacesAndNewlines),
                    director: nonNullString(item["vod_director"]).trimmingCharacters(in: .whitespacesAndNewlines),
                    description: desc,
                    tag: nonNullString(item["vod_tag"]).trimmingCharacters(in: .whitespacesAndNewlines),
                    doubanScore: douban,
                    lines: parsedLines
                )
            )
        }

        return CmsListing(page: page, pageCount: pageCount, videos: videos, filters: parsedFilters)
    }

    public static func parseLivePlaylist(
        _ content: String,
        origin: String = "",
        headers: [String: String] = [:]
    ) throws -> [LiveGroup] {
        let unpacked = content.utf8.count <= LiveCatalogParser.maxBytes
            ? ConfigDecoder.unpackConfigText(content)
            : content
        return try LiveCatalogParser.parse(
            unpacked,
            origin: origin,
            sourceHeaders: headers,
            resolve: { base, rel in resolveUrl(base: base, relative: rel) }
        )
    }

    public static func parseM3uVodHome(_ content: String, origin: String = "") throws -> ([CmsCategory], CmsListing) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("<") {
            return (parseCategories(trimmed), try parseListing(trimmed))
        }
        let groups = try parseLivePlaylist(trimmed, origin: origin)
        let categories = groups.map { CmsCategory(id: $0.name, name: $0.name) }
        var videos: [CmsVideo] = []
        for g in groups {
            for ch in g.channels {
                let eps: [CmsEpisode]
                if !ch.streams.isEmpty {
                    eps = ch.streams.enumerated().map { idx, stream in
                        CmsEpisode(
                            name: ch.streams.count == 1 ? "正片" : "线路 \(idx + 1)",
                            url: stream.url,
                            headers: stream.headers
                        )
                    }
                } else {
                    eps = ch.urls.enumerated().map { idx, u in
                        CmsEpisode(name: ch.urls.count == 1 ? "正片" : "线路 \(idx + 1)", url: u)
                    }
                }
                videos.append(
                    CmsVideo(
                        id: "\(g.name)::\(ch.name)",
                        title: ch.name,
                        poster: ch.logo,
                        remarks: g.name,
                        tag: g.name,
                        lines: [CmsLine(name: g.name, episodes: eps)]
                    )
                )
            }
        }
        return (categories, CmsListing(page: 1, pageCount: 1, videos: videos))
    }

    // MARK: - Line & Episode Helpers

    public static func parseLines(playFrom: String, playUrl: String) -> [CmsLine] {
        guard !playUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let fromParts = playFrom.components(separatedBy: "$$$")
        let urlParts = playUrl.components(separatedBy: "$$$")
        var lines: [CmsLine] = []

        for (i, rawGroupPart) in urlParts.enumerated() {
            let rawGroup = rawGroupPart.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawGroup.isEmpty else { continue }
            let rawFrom = i < fromParts.count ? fromParts[i].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            let lineName = !rawFrom.isEmpty ? friendlyLineName(rawFrom) : "线路 \(i + 1)"
            var episodes: [CmsEpisode] = []

            for segment in rawGroup.components(separatedBy: "#") {
                let s = segment.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !s.isEmpty else { continue }
                let epName: String
                let rawEpUrl: String
                if let dollarIdx = s.firstIndex(of: "$") {
                    epName = String(s[..<dollarIdx]).trimmingCharacters(in: .whitespacesAndNewlines)
                    rawEpUrl = String(s[s.index(after: dollarIdx)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                } else {
                    epName = "正片"
                    rawEpUrl = s
                }
                let epUrl = cleanStreamUrl(rawEpUrl)
                if !epUrl.isEmpty {
                    episodes.append(
                        CmsEpisode(
                            name: epName.isEmpty ? "第 \(episodes.count + 1) 集" : epName,
                            url: epUrl
                        )
                    )
                }
            }
            if !episodes.isEmpty {
                lines.append(CmsLine(name: lineName, episodes: episodes))
            }
        }

        if lines.count > 1 {
            var directLines: [CmsLine] = []
            var indirectLines: [CmsLine] = []
            for line in lines {
                if line.episodes.contains(where: { $0.isDirectPlayable }) {
                    directLines.append(line)
                } else {
                    indirectLines.append(line)
                }
            }
            if !directLines.isEmpty {
                directLines.sort { a, b in
                    let aM3u8 = a.isM3u8Preferred
                    let bM3u8 = b.isM3u8Preferred
                    if aM3u8 != bM3u8 { return aM3u8 && !bM3u8 }
                    return false
                }
                return directLines + indirectLines
            }
        }
        return lines
    }

    public static func friendlyLineName(_ rawFlag: String) -> String {
        let trimmed = rawFlag.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "高清专线" }
        let lower = trimmed.lowercased()
        let map: [String: String] = [
            "modum3u8": "魔都超清", "modu": "魔都专线",
            "bfzym3u8": "暴风蓝光", "bfzy": "暴风专线",
            "dyttm3u8": "电影天堂", "dytt": "天堂蓝光",
            "ffm3u8": "非凡超清", "ffzy": "非凡专线",
            "lzm3u8": "量子超清", "lzi": "量子专线",
            "snm3u8": "索尼蓝光", "suoni": "索尼专线",
            "ryzym3u8": "如意超清", "rycj": "如意专线",
            "hhzym3u8": "豪华蓝光", "hhzy": "豪华专线",
            "jsm3u8": "极速蓝光", "jszy": "极速专线",
            "ikm3u8": "爱坤超清", "ikun": "爱坤专线",
            "subm3u8": "速播超清", "subo": "速播专线",
            "xlm3u8": "新浪蓝光", "xinlang": "新浪专线",
            "hnm3u8": "红牛超清", "hongniu": "红牛专线",
            "360zy": "360超清",
            "zuidam3u8": "最大蓝光", "zuidazy": "最大专线",
            "tyyszy": "天涯超清", "tyysm3u8": "天涯蓝光",
            "wjm3u8": "无尽超清", "kuaikan": "快看蓝光",
            "ukm3u8": "U酷超清", "sdm3u8": "闪电蓝光",
            "jinyingm3u8": "金鹰超清", "bdxm3u8": "北斗蓝光",
            "qhm3u8": "奇虎超清", "hym3u8": "虎牙直连",
        ]
        if let mapped = map[lower] { return mapped }
        if lower.hasSuffix("m3u8"),
           lower.utf8.allSatisfy({ ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x5F })
        {
            let prefix = String(lower.dropLast(4))
            if let mapped = map[prefix] { return mapped }
            return "超清直连"
        }
        return trimmed
    }

    public static func upsertHistory(_ existing: [WatchHistoryItem], entry: WatchHistoryItem) -> [WatchHistoryItem] {
        var result: [WatchHistoryItem] = [entry]
        for item in existing where item.key != entry.key && result.count < maxHistoryEntries {
            result.append(item)
        }
        return result
    }

    // MARK: - Private XML & JSON Helpers

    private static func parseXmlCategories(_ xml: String) -> [CmsCategory] {
        guard let regex = try? NSRegularExpression(
            pattern: #"<ty\b[^>]*\bid\s*=\s*["']([^"']+)["'][^>]*>([\s\S]*?)</ty>"#,
            options: [.caseInsensitive]
        ) else {
            return []
        }
        let nsRange = NSRange(xml.startIndex..., in: xml)
        var out: [CmsCategory] = []
        for match in regex.matches(in: xml, range: nsRange) {
            guard let r1 = Range(match.range(at: 1), in: xml),
                  let r2 = Range(match.range(at: 2), in: xml)
            else { continue }
            let id = String(xml[r1]).trimmingCharacters(in: .whitespacesAndNewlines)
            let name = cleanXmlText(String(xml[r2]))
            if !id.isEmpty && !name.isEmpty {
                out.append(CmsCategory(id: id, name: name))
            }
        }
        return out
    }

    private static func parseXmlListing(_ xml: String) -> CmsListing {
        var page = 1
        var pageCount = 1
        if let listRegex = try? NSRegularExpression(pattern: #"<list\b([^>]*)>"#, options: [.caseInsensitive]),
           let listMatch = listRegex.firstMatch(in: xml, range: NSRange(xml.startIndex..., in: xml)),
           let attrRange = Range(listMatch.range(at: 1), in: xml)
        {
            let attrs = String(xml[attrRange])
            if let pgVal = extractXmlAttrInt(attrs, name: "page") { page = max(1, pgVal) }
            if let pcVal = extractXmlAttrInt(attrs, name: "pagecount") { pageCount = max(1, pcVal) }
        }

        guard let videoRegex = try? NSRegularExpression(pattern: #"<video\b[^>]*>([\s\S]*?)</video>"#, options: [.caseInsensitive]),
              let ddRegex = try? NSRegularExpression(pattern: #"<dd\b([^>]*)>([\s\S]*?)</dd>"#, options: [.caseInsensitive]),
              let flagRegex = try? NSRegularExpression(pattern: #"\bflag\s*=\s*["']([^"']*)["']"#, options: [.caseInsensitive])
        else {
            return CmsListing(page: page, pageCount: pageCount)
        }

        var videos: [CmsVideo] = []
        for vMatch in videoRegex.matches(in: xml, range: NSRange(xml.startIndex..., in: xml)) {
            guard let blockRange = Range(vMatch.range(at: 1), in: xml) else { continue }
            let block = String(xml[blockRange])
            let id = extractXmlTag(block, tag: "id")
            let title = extractXmlTag(block, tag: "name")
            if id.isEmpty && title.isEmpty { continue }

            var fromParts: [String] = []
            var urlParts: [String] = []
            for ddMatch in ddRegex.matches(in: block, range: NSRange(block.startIndex..., in: block)) {
                guard let ddAttrRange = Range(ddMatch.range(at: 1), in: block),
                      let ddBodyRange = Range(ddMatch.range(at: 2), in: block)
                else { continue }
                let ddAttrs = String(block[ddAttrRange])
                var flag = ""
                if let fMatch = flagRegex.firstMatch(in: ddAttrs, range: NSRange(ddAttrs.startIndex..., in: ddAttrs)),
                   let fRange = Range(fMatch.range(at: 1), in: ddAttrs)
                {
                    flag = String(ddAttrs[fRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                let body = cleanXmlText(String(block[ddBodyRange]))
                if !body.isEmpty {
                    fromParts.append(flag.isEmpty ? "线路 \(fromParts.count + 1)" : flag)
                    urlParts.append(body)
                }
            }

            let remarks = extractXmlTag(block, tag: "note")
            let desc = cleanHtml(extractXmlTag(block, tag: "des"))
            videos.append(
                CmsVideo(
                    id: id,
                    title: title,
                    poster: cleanPosterUrl(extractXmlTag(block, tag: "pic")),
                    remarks: remarks,
                    year: extractXmlTag(block, tag: "year"),
                    area: extractXmlTag(block, tag: "area"),
                    actor: extractXmlTag(block, tag: "actor"),
                    director: extractXmlTag(block, tag: "director"),
                    description: desc,
                    doubanScore: parseDoubanField(extractXmlTag(block, tag: "douban")),
                    lines: parseLines(playFrom: fromParts.joined(separator: "$$$"), playUrl: urlParts.joined(separator: "$$$"))
                )
            )
        }
        return CmsListing(page: page, pageCount: pageCount, videos: videos)
    }

    private static func extractXmlAttrInt(_ attrs: String, name: String) -> Int? {
        guard let regex = try? NSRegularExpression(
            pattern: "\\b\(name)\\s*=\\s*[\"']?(\\d+)",
            options: [.caseInsensitive]
        ),
            let match = regex.firstMatch(in: attrs, range: NSRange(attrs.startIndex..., in: attrs)),
            let range = Range(match.range(at: 1), in: attrs)
        else {
            return nil
        }
        return Int(attrs[range])
    }

    private static func extractXmlTag(_ block: String, tag: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: "<\(tag)\\b[^>]*>([\\s\\S]*?)</\(tag)>",
            options: [.caseInsensitive]
        ),
            let match = regex.firstMatch(in: block, range: NSRange(block.startIndex..., in: block)),
            let range = Range(match.range(at: 1), in: block)
        else {
            return ""
        }
        return cleanXmlText(String(block[range]))
    }

    private static func cleanXmlText(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("<![CDATA[") && s.hasSuffix("]]>") {
            let inner = s.dropFirst(9).dropLast(3)
            return String(inner).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return s
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    public static func cleanHtml(_ html: String) -> String {
        var s = html
        if let regex = try? NSRegularExpression(pattern: #"<[^>]*>"#) {
            s = regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
        }
        return s
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func cleanStreamUrl(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for pattern in [#"(\.m3u8(?:\?[^@\s]*)?)@"#, #"(\.mp4(?:\?[^@\s]*)?)@"#] {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
               let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
               let fullRange = Range(match.range, in: trimmed)
            {
                let cutIndex = trimmed.index(before: fullRange.upperBound)
                trimmed = String(trimmed[..<cutIndex])
            }
        }
        return trimmed
    }

    public static func cleanPosterUrl(_ raw: String) -> String {
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let regex = try? NSRegularExpression(pattern: #"@(?:Referer|User-Agent)="#, options: [.caseInsensitive]),
           let match = regex.firstMatch(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned)),
           let range = Range(match.range, in: cleaned),
           range.lowerBound > cleaned.startIndex
        {
            cleaned = String(cleaned[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if cleaned.hasPrefix("//") {
            cleaned = "https:\(cleaned)"
        }
        let lower = cleaned.lowercased()
        if lower.isEmpty || (!lower.hasPrefix("http://") && !lower.hasPrefix("https://")) {
            return ""
        }
        return cleaned
    }

    private static func parseStructuredLines(_ values: [Any]) -> [CmsLine] {
        var out: [CmsLine] = []
        for entry in values {
            guard let line = entry as? [String: Any],
                  let epsArr = line["episodes"] as? [Any]
            else { continue }
            var episodes: [CmsEpisode] = []
            for epAny in epsArr {
                guard let ep = epAny as? [String: Any] else { continue }
                let u = nonNullString(ep["url"])
                guard !u.isEmpty else { continue }
                var hdrs: [String: String] = [:]
                if let hMap = ep["headers"] as? [String: Any] {
                    for (k, v) in hMap {
                        hdrs[k] = nonNullString(v)
                    }
                }
                episodes.append(CmsEpisode(name: nonNullString(ep["name"]), url: u, headers: hdrs))
            }
            let lineName = nonNullString(line["name"])
            let lineId = nonNullString(line["id"])
            out.append(CmsLine(id: lineId.isEmpty ? lineName : lineId, name: lineName, episodes: episodes))
        }
        return out
    }

    private static func extractSiteHeaders(_ item: [String: Any]) -> [String: String] {
        var result: [String: String] = [:]
        for (k, v) in stringHeaders(item["headers"] ?? item["header"]) {
            result[k] = v
        }
        let ua = nonNullString(item["ua"]).trimmingCharacters(in: .whitespacesAndNewlines)
        if !ua.isEmpty && !ua.contains("\r") && !ua.contains("\n") {
            result["User-Agent"] = ua
        }
        var extObj: Any? = item["ext"]
        if let extStr = extObj as? String, extStr.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") {
            let cleanedExt = ConfigDecoder.stripJsonComments(extStr)
            extObj = try? JSONSerialization.jsonObject(with: Data(cleanedExt.utf8))
        }
        if let extMap = extObj as? [String: Any] {
            for (k, v) in stringHeaders(extMap["headers"] ?? extMap["header"]) {
                result[k] = v
            }
            let extUa = firstNonEmpty(extMap["ua"], extMap["User-Agent"])
            if !extUa.isEmpty && !extUa.contains("\r") && !extUa.contains("\n") {
                result["User-Agent"] = extUa
            }
        }
        return result
    }

    private static func stringHeaders(_ raw: Any?) -> [String: String] {
        guard let raw = raw, !(raw is NSNull) else { return [:] }
        var candidate: Any = raw
        if let s = raw as? String, s.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") {
            let cleaned = ConfigDecoder.stripJsonComments(s)
            if let decoded = try? JSONSerialization.jsonObject(with: Data(cleaned.utf8)) {
                candidate = decoded
            }
        }
        guard let map = candidate as? [String: Any] else { return [:] }
        let allowed: [String: String] = [
            "user-agent": "User-Agent",
            "referer": "Referer",
            "cookie": "Cookie",
            "origin": "Origin",
            "authorization": "Authorization",
        ]
        var out: [String: String] = [:]
        for (k, v) in map {
            guard !(v is NSNull) else { continue }
            let valStr = nonNullString(v).trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = k.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let canonical = allowed[lower], !valStr.contains("\r"), !valStr.contains("\n") {
                out[canonical] = valStr
            }
        }
        return out
    }

    private static func tryParseM3uOrTxtConfig(
        _ content: String,
        origin: String,
        groupLabel: String,
        isPrivate: Bool,
        subscriptionId: String,
        defaultName: String
    ) -> CmsConfig? {
        guard let groups = try? parseLivePlaylist(content, origin: origin), !groups.isEmpty else {
            return nil
        }
        let cleanOrigin = origin.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseName = !defaultName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? defaultName.trimmingCharacters(in: .whitespacesAndNewlines)
            : inferSiteNameFromUrl(cleanOrigin, fallback: "M3U 订阅源")
        let liveUrl = !cleanOrigin.isEmpty
            ? normalizeUrl(cleanOrigin)
            : "data:text/plain;base64,\(Data(content.utf8).base64EncodedString())"
        let siteKey = "m3u_\(shortHash(cleanOrigin.isEmpty ? content : cleanOrigin))"
        return CmsConfig(
            sites: [
                CmsSite(
                    key: siteKey,
                    name: baseName,
                    type: 1,
                    api: "m3u_vod://\(!cleanOrigin.isEmpty ? normalizeUrl(cleanOrigin) : siteKey)",
                    ext: content,
                    group: groupLabel,
                    isPrivate: isPrivate,
                    subscriptionId: subscriptionId
                ),
            ],
            lives: [
                LiveSource(
                    name: baseName,
                    url: liveUrl,
                    group: groupLabel,
                    isPrivate: isPrivate,
                    subscriptionId: subscriptionId
                ),
            ]
        )
    }

    private static func cleanVodEndpointUrl(_ rawUrl: String) -> String {
        let normalized = normalizeUrl(rawUrl)
        guard !normalized.isEmpty, var comps = URLComponents(string: normalized) else { return normalized }
        guard let items = comps.queryItems, !items.isEmpty else { return normalized }
        let dropped: Set<String> = ["ac", "pg", "t", "wd", "ids", "h"]
        let remaining = items.filter { !dropped.contains($0.name.lowercased()) }
        comps.queryItems = remaining.isEmpty ? nil : remaining
        return comps.string ?? normalized
    }

    private static func inferSiteNameFromUrl(_ url: String, fallback: String) -> String {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let parsed = URL(string: normalizeUrl(trimmed)), let host = parsed.host?.lowercased(), !host.isEmpty else {
            return fallback
        }
        let parts = host.split(separator: ".").map(String.init)
        if parts.count >= 2 {
            let main = parts[parts.count - 2]
            if !["com", "cn", "net", "org"].contains(main) {
                return main.uppercased()
            }
        }
        return host
    }

    private static func looksLikeDepotUrl(_ rawUrl: String) -> Bool {
        let lower = rawUrl.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://")
            || rawUrl.hasPrefix("//")
            || rawUrl.hasPrefix("/")
            || rawUrl.hasPrefix("./")
            || rawUrl.hasPrefix("../")
        {
            return true
        }
        if let regex = try? NSRegularExpression(pattern: #"^[^\s]+\.[a-zA-Z0-9]{1,8}(?:[?#].*)?$"#) {
            return regex.firstMatch(in: rawUrl, range: NSRange(rawUrl.startIndex..., in: rawUrl)) != nil
        }
        return false
    }

    private static func shortHash(_ input: String) -> String {
        var h: UInt32 = 0x811C_9DC5
        for code in input.utf16 {
            h ^= UInt32(code)
            h = (h &* 0x0100_0193) & 0x7FFF_FFFF
        }
        return String(h, radix: 36)
    }

    private static func isMissing(_ raw: Any?) -> Bool {
        raw == nil || (raw is NSNull)
    }

    private static func nonNullString(_ raw: Any?) -> String {
        guard let raw = raw, !(raw is NSNull) else { return "" }
        if let s = raw as? String { return s }
        if let n = raw as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                return n.boolValue ? "true" : "false"
            }
            return n.stringValue
        }
        return ""
    }

    private static func firstNonEmpty(_ values: Any?...) -> String {
        for val in values {
            let s = nonNullString(val).trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty { return s }
        }
        return ""
    }

    private static func stringifyExt(_ raw: Any?) -> String {
        guard let raw = raw, !(raw is NSNull) else { return "" }
        if let s = raw as? String {
            return s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if JSONSerialization.isValidJSONObject(raw),
           let data = try? JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys])
        {
            return String(decoding: data, as: UTF8.self)
        }
        return nonNullString(raw).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func asInt(_ raw: Any?, fallback: Int) -> Int {
        guard let raw = raw, !(raw is NSNull) else { return fallback }
        if let n = raw as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                return n.boolValue ? 1 : 0
            }
            return n.intValue
        }
        if let s = raw as? String {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if trimmed == "true" { return 1 }
            if trimmed == "false" { return 0 }
            if let v = Int(trimmed) { return v }
        }
        return fallback
    }

    private static func asBool(_ raw: Any?, fallback: Bool) -> Bool {
        guard let raw = raw, !(raw is NSNull) else { return fallback }
        if let n = raw as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                return n.boolValue
            }
            return n.intValue != 0
        }
        if let s = raw as? String {
            let lower = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ["0", "false", "no"].contains(lower) { return false }
            if ["1", "true", "yes"].contains(lower) { return true }
        }
        return fallback
    }

    private static func parseDoubanField(_ raw: Any?) -> Double? {
        let s = nonNullString(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let val = Double(s), val >= 2.0, val <= 9.9 else { return nil }
        return val
    }

    private static func sortNaturalKeys(_ keys: [String]) -> [String] {
        keys.sorted { a, b in
            if let ia = Int(a), let ib = Int(b) {
                return ia < ib
            }
            return a.localizedStandardCompare(b) == .orderedAscending
        }
    }
}
