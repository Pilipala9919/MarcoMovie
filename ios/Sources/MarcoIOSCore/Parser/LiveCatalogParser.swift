// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only

import Foundation

public enum LiveCatalogParser {
    public static let maxBytes = 6 * 1024 * 1024

    public static func mergeHeaders(_ layers: [[String: String]]) -> [String: String] {
        var result: [String: String] = [:]
        for layer in layers {
            for (k, v) in layer {
                guard !k.isEmpty,
                      !k.contains("\r"), !k.contains("\n"),
                      !v.contains("\r"), !v.contains("\n")
                else { continue }
                let existingKeys = result.keys.filter { $0.lowercased() == k.lowercased() }
                for ek in existingKeys { result.removeValue(forKey: ek) }
                result[k] = v
            }
        }
        return result
    }

    public static func headers(from item: [String: Any]) -> [String: String] {
        func readMap(_ raw: Any?) -> [String: String] {
            guard let raw = raw, !(raw is NSNull) else { return [:] }
            var val: Any = raw
            if let s = raw as? String,
               let parsed = try? JSONSerialization.jsonObject(with: Data(s.utf8))
            {
                val = parsed
            }
            guard let dict = val as? [String: Any] else { return [:] }
            var out: [String: String] = [:]
            for (k, v) in dict where !(v is NSNull) {
                if let sv = v as? String {
                    out[k] = sv
                } else if let nv = v as? NSNumber {
                    out[k] = nv.stringValue
                }
            }
            return out
        }

        var layers: [[String: String]] = [
            readMap(item["headers"]),
            readMap(item["header"]),
        ]
        let shortcuts: [(String, String)] = [
            ("ua", "User-Agent"),
            ("referer", "Referer"),
            ("origin", "Origin"),
        ]
        for (field, headerName) in shortcuts {
            if let s = item[field] as? String, !s.isEmpty {
                layers.append([headerName: s])
            }
        }
        return mergeHeaders(layers)
    }

    public static func isLoopbackHost(_ host: String) -> Bool {
        let lower = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lower == "127.0.0.1" || lower == "localhost" || lower == "::1" || lower == "[::1]"
    }

    public static func directoryUrl(_ raw: String, origin: String = "") -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf16.count <= 32_768 else { return nil }

        let query: String
        if value.lowercased().hasPrefix("proxy://") {
            var q = String(value.dropFirst("proxy://".count))
            while q.hasPrefix("/") || q.hasPrefix("?") {
                q.removeFirst()
            }
            query = q
        } else if let parsed = URLComponents(string: value),
                  let scheme = parsed.scheme?.lowercased(),
                  (scheme == "http" || scheme == "https"),
                  let host = parsed.host,
                  isLoopbackHost(host),
                  parsed.path == "/proxy",
                  let q = parsed.percentEncodedQuery,
                  !q.isEmpty
        {
            query = q
        } else {
            return nil
        }

        var params: [String: String] = [:]
        for pair in query.components(separatedBy: "&") where !pair.isEmpty {
            guard let eqIdx = pair.firstIndex(of: "=") else { continue }
            let rawK = String(pair[..<eqIdx]).replacingOccurrences(of: "+", with: "%2B")
            let rawV = String(pair[pair.index(after: eqIdx)...]).replacingOccurrences(of: "+", with: "%2B")
            guard let k = rawK.removingPercentEncoding,
                  let v = rawV.removingPercentEncoding,
                  params[k] == nil
            else {
                return nil
            }
            params[k] = v
        }
        guard params["do"] == "live", params["type"] == "txt",
              let rawExt = params["ext"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawExt.isEmpty, rawExt.utf16.count <= 32_768
        else {
            return nil
        }

        var decoded: String
        let lowerExt = rawExt.lowercased()
        if lowerExt.hasPrefix("http://") || lowerExt.hasPrefix("https://") || rawExt.hasPrefix("./") || rawExt.hasPrefix("../") {
            decoded = rawExt
        } else {
            var b64 = rawExt.components(separatedBy: .whitespacesAndNewlines).joined()
                .replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/")
            guard b64.count % 4 != 1 else { return nil }
            while b64.count % 4 != 0 { b64.append("=") }
            guard let data = Data(base64Encoded: b64) else { return nil }
            decoded = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if decoded.hasPrefix("./") || decoded.hasPrefix("../") {
            let cleanOrigin = origin.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanOrigin.isEmpty else { return nil }
            decoded = CmsParser.resolveUrl(base: cleanOrigin, relative: decoded)
        }
        guard let u = URL(string: decoded),
              let scheme = u.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              let host = u.host, !host.isEmpty
        else {
            return nil
        }
        return decoded
    }

    public static func tryDecodeBase64LiveText(_ raw: String) -> String? {
        var candidate = raw
        if let starRange = candidate.range(of: "**", options: .backwards) {
            candidate = String(candidate[starRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let compact = candidate.components(separatedBy: .whitespacesAndNewlines).joined()
        guard compact.count >= 16 else { return nil }
        guard compact.utf8.allSatisfy({ b in
            (b >= 0x41 && b <= 0x5A)
                || (b >= 0x61 && b <= 0x7A)
                || (b >= 0x30 && b <= 0x39)
                || b == 0x2B || b == 0x2F || b == 0x5F || b == 0x2D || b == 0x3D
        }) else {
            return nil
        }
        var normalized = compact
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while normalized.count % 4 != 0 {
            normalized.append("=")
        }
        guard let decodedData = Data(base64Encoded: normalized) else { return nil }
        var decoded = String(decoding: decodedData, as: UTF8.self)
        if decoded.hasPrefix("\u{FEFF}") { decoded.removeFirst() }
        decoded = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
        if decoded.hasPrefix("#EXTM3U")
            || decoded.contains("#EXTINF:")
            || decoded.contains(",#genre#")
            || decoded.hasPrefix("{")
            || decoded.hasPrefix("[")
        {
            return decoded
        }
        if let regex = try? NSRegularExpression(
            pattern: #"(?:^|\n)[^\r\n,]+,\s*(?:https?|rtmps?|rtsp)://"#,
            options: [.caseInsensitive]
        ), regex.firstMatch(in: decoded, range: NSRange(decoded.startIndex..., in: decoded)) != nil {
            return decoded
        }
        return nil
    }

    public static func parse(
        _ content: String,
        origin: String = "",
        sourceHeaders: [String: String] = [:],
        resolve: (String, String) -> String = { base, rel in CmsParser.resolveUrl(base: base, relative: rel) }
    ) throws -> [LiveGroup] {
        if content.utf8.count > maxBytes {
            throw MarcoError.invalidFormat("直播列表超过 6 MB")
        }

        var groupOrder: [String] = []
        var channelOrderByGroup: [String: [String]] = [:]
        var streamsByGroupAndChannel: [String: [String: [CmsEpisode]]] = [:]
        var logosByKey: [String: String] = [:]
        var totalStreamCount = 0

        func absolute(_ value: String) -> String {
            guard !origin.isEmpty,
                  let baseUrl = URL(string: origin),
                  let scheme = baseUrl.scheme?.lowercased(),
                  scheme == "http" || scheme == "https"
            else {
                return value
            }
            return resolve(origin, value)
        }

        func addStream(
            group rawGroup: String,
            name rawName: String,
            rawUrl: String,
            explicitHeaders: [String: String],
            logo: String = "",
            marked: Bool = false,
            label: String = ""
        ) throws {
            var value = rawUrl.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return }

            var streamHeaders = mergeHeaders([sourceHeaders, explicitHeaders])
            if let pipeIdx = value.firstIndex(of: "|") {
                let queryStr = String(value[value.index(after: pipeIdx)...])
                var pipeHeaders: [String: String] = [:]
                for pair in queryStr.components(separatedBy: "&") where !pair.isEmpty {
                    if let eq = pair.firstIndex(of: "=") {
                        let k = String(pair[..<eq]).removingPercentEncoding ?? String(pair[..<eq])
                        let v = String(pair[pair.index(after: eq)...]).removingPercentEncoding ?? String(pair[pair.index(after: eq)...])
                        pipeHeaders[k] = v
                    }
                }
                streamHeaders = mergeHeaders([streamHeaders, pipeHeaders])
                value = String(value[..<pipeIdx]).trimmingCharacters(in: .whitespacesAndNewlines)
            }

            if !marked {
                let hasScheme = value.contains("://")
                let isRel = value.hasPrefix("/") || value.hasPrefix("./") || value.hasPrefix("../")
                let hasMediaExt = [".m3u8", ".m3u", ".mp4", ".mkv", ".ts", ".flv", ".mp3", ".aac"].contains { ext in
                    let clean = value.components(separatedBy: "?").first?.components(separatedBy: "#").first?.lowercased() ?? ""
                    return clean.hasSuffix(ext)
                }
                if !hasScheme && !isRel && !hasMediaExt {
                    return
                }
            }

            let url = absolute(value)
            guard let parsed = URL(string: url),
                  let scheme = parsed.scheme?.lowercased(),
                  ["http", "https", "rtmp", "rtsp"].contains(scheme),
                  let host = parsed.host, !host.isEmpty
            else {
                return
            }

            let g = rawGroup.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "默认频道"
                : rawGroup.trimmingCharacters(in: .whitespacesAndNewlines)
            let c = rawName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "未命名频道"
                : rawName.trimmingCharacters(in: .whitespacesAndNewlines)

            if streamsByGroupAndChannel[g] == nil {
                groupOrder.append(g)
                streamsByGroupAndChannel[g] = [:]
                channelOrderByGroup[g] = []
            }
            if streamsByGroupAndChannel[g]?[c] == nil {
                channelOrderByGroup[g]?.append(c)
                streamsByGroupAndChannel[g]?[c] = []
            }

            var currentStreams = streamsByGroupAndChannel[g]?[c] ?? []
            let epName = label.isEmpty ? "线路 \(currentStreams.count + 1)" : label
            let episode = CmsEpisode(name: epName, url: url, headers: streamHeaders)

            let duplicate = currentStreams.contains { $0.url == url && $0.headers == episode.headers }
            if !duplicate {
                totalStreamCount += 1
                if totalStreamCount > 12_000 {
                    throw MarcoError.invalidFormat("直播线路数量超过限制")
                }
                currentStreams.append(episode)
                streamsByGroupAndChannel[g]?[c] = currentStreams
            }

            if !logo.isEmpty {
                let resolvedLogo = absolute(logo)
                if let lu = URL(string: resolvedLogo),
                   let ls = lu.scheme?.lowercased(),
                   ls == "http" || ls == "https"
                {
                    let ck = "\(g)\n\(c)"
                    if logosByKey[ck] == nil {
                        logosByKey[ck] = resolvedLogo
                    }
                }
            }
        }

        func splitMultiUrls(_ value: String) -> [String] {
            guard let regex = try? NSRegularExpression(
                pattern: #"#(?=(?:https?|rtmps?|rtsp)://)"#,
                options: [.caseInsensitive]
            ) else {
                return [value]
            }
            let ns = value as NSString
            let matches = regex.matches(in: value, range: NSRange(location: 0, length: ns.length))
            if matches.isEmpty { return [value] }
            var parts: [String] = []
            var last = 0
            for m in matches {
                parts.append(ns.substring(with: NSRange(location: last, length: m.range.location - last)))
                last = m.range.location + m.range.length
            }
            parts.append(ns.substring(from: last))
            return parts
        }

        func parseJsonItem(_ item: Any, group: String, inherited: [String: String], depth: Int) throws {
            if depth > 24 {
                throw MarcoError.invalidFormat("直播目录嵌套过深")
            }
            if let arr = item as? [Any] {
                for child in arr {
                    try parseJsonItem(child, group: group, inherited: inherited, depth: depth + 1)
                }
                return
            }
            guard let dict = item as? [String: Any] else { return }
            let h = mergeHeaders([inherited, headers(from: dict)])
            for field in ["lives", "groups", "channels"] {
                if let nested = dict[field], nested is [Any] || nested is [String: Any] {
                    let nextGroup: String
                    if field == "channels" {
                        nextGroup = (dict["name"] as? String) ?? (dict["group"] as? String) ?? group
                    } else {
                        nextGroup = group
                    }
                    try parseJsonItem(nested, group: nextGroup, inherited: h, depth: depth + 1)
                    return
                }
            }
            let g = (dict["group"] as? String) ?? (dict["group-title"] as? String) ?? group
            let name = (dict["name"] as? String) ?? (dict["title"] as? String) ?? "频道"
            let logo = (dict["logo"] as? String) ?? (dict["tvg-logo"] as? String) ?? ""
            let rawStreams: [Any] = {
                if let arr = dict["urls"] as? [Any] { return arr }
                if let single = dict["urls"] ?? dict["url"] { return [single] }
                return []
            }()
            for stream in rawStreams {
                let urlStr: String?
                let extraHeaders: [String: String]
                let label: String
                if let sDict = stream as? [String: Any] {
                    urlStr = sDict["url"] as? String
                    extraHeaders = mergeHeaders([h, headers(from: sDict)])
                    label = (sDict["name"] as? String) ?? ""
                } else {
                    urlStr = stream as? String
                    extraHeaders = h
                    label = ""
                }
                guard let validUrl = urlStr else { continue }
                for part in splitMultiUrls(validUrl) {
                    try addStream(
                        group: g,
                        name: name,
                        rawUrl: part,
                        explicitHeaders: extraHeaders,
                        logo: logo,
                        marked: true,
                        label: label
                    )
                }
            }
        }

        var text = content
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if !text.hasPrefix("{")
            && !text.hasPrefix("[")
            && !text.hasPrefix("\"")
            && !text.hasPrefix("#EXTM3U")
            && !text.hasPrefix("<")
            && !text.contains("#EXTINF:")
            && !text.contains(",#genre#")
            && !text.contains("://")
        {
            if let unpacked = tryDecodeBase64LiveText(text) {
                text = unpacked
            }
        }

        var decodedJson: Any?
        let cleanedText = ConfigDecoder.stripJsonComments(text)
        if cleanedText.hasPrefix("[") || cleanedText.hasPrefix("{") || cleanedText.hasPrefix("\"") {
            decodedJson = try? JSONSerialization.jsonObject(with: Data(cleanedText.utf8), options: [.fragmentsAllowed])
            if let innerStr = decodedJson as? String {
                text = innerStr.trimmingCharacters(in: .whitespacesAndNewlines)
                let innerClean = ConfigDecoder.stripJsonComments(text)
                if innerClean.hasPrefix("[") || innerClean.hasPrefix("{") {
                    decodedJson = try? JSONSerialization.jsonObject(with: Data(innerClean.utf8))
                } else {
                    decodedJson = nil
                }
            }
        }

        if let jsonObj = decodedJson, jsonObj is [String: Any] || jsonObj is [Any] {
            try parseJsonItem(jsonObj, group: "直播频道", inherited: [:], depth: 0)
        } else {
            let lines = text.components(separatedBy: .newlines)
            if lines.count > 60_000 {
                throw MarcoError.invalidFormat("直播列表行数超过限制")
            }
            var currentGroup = "精选频道"
            var pendingTitle = ""
            var m3uGroup = ""
            var pendingLogo = ""
            var pendingHeaders: [String: String] = [:]

            let attrRegex = try? NSRegularExpression(pattern: #"([\w-]+)\s*=\s*(?:"([^"]*)"|'([^']*)')"#)

            for rawLine in lines {
                let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                if line.isEmpty { continue }

                if line.hasPrefix("#EXTINF:") {
                    let chars = Array(line)
                    var quote: Character?
                    var commaPos = -1
                    for (idx, ch) in chars.enumerated() {
                        if let q = quote {
                            if ch == q { quote = nil }
                        } else if ch == "\"" || ch == "'" {
                            quote = ch
                        } else if ch == "," {
                            commaPos = idx
                            break
                        }
                    }
                    let headerPart = commaPos >= 0 ? String(chars[0..<commaPos]) : line
                    var attrs: [String: String] = [:]
                    if let regex = attrRegex {
                        for m in regex.matches(in: headerPart, range: NSRange(headerPart.startIndex..., in: headerPart)) {
                            guard let kRange = Range(m.range(at: 1), in: headerPart) else { continue }
                            let k = String(headerPart[kRange]).lowercased()
                            let v: String
                            if let r2 = Range(m.range(at: 2), in: headerPart) {
                                v = String(headerPart[r2])
                            } else if let r3 = Range(m.range(at: 3), in: headerPart) {
                                v = String(headerPart[r3])
                            } else {
                                v = ""
                            }
                            attrs[k] = v
                        }
                    }
                    let rawTitle = commaPos >= 0
                        ? String(chars[(commaPos + 1)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                        : (attrs["tvg-name"] ?? "频道")
                    let tvgFallback = (attrs["tvg-name"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    pendingTitle = !rawTitle.isEmpty ? rawTitle : (!tvgFallback.isEmpty ? tvgFallback : "频道")
                    let grp = (attrs["group-title"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    m3uGroup = grp.isEmpty ? "直播频道" : grp
                    pendingLogo = attrs["tvg-logo"] ?? ""
                    pendingHeaders = [:]
                    continue
                }

                if line.hasPrefix("#EXTVLCOPT:") && !pendingTitle.isEmpty {
                    let option = String(line.dropFirst("#EXTVLCOPT:".count))
                    if let eqIdx = option.firstIndex(of: "="), eqIdx > option.startIndex {
                        let optKey = String(option[..<eqIdx]).lowercased()
                        let optVal = String(option[option.index(after: eqIdx)...])
                        let mappedKey: String?
                        switch optKey {
                        case "http-user-agent":
                            mappedKey = "User-Agent"
                        case "http-referrer", "http-referer":
                            mappedKey = "Referer"
                        case "http-origin":
                            mappedKey = "Origin"
                        default:
                            mappedKey = nil
                        }
                        if let mk = mappedKey {
                            pendingHeaders[mk] = optVal
                        }
                    }
                    continue
                }

                if line.hasPrefix("#EXTGRP:") && !pendingTitle.isEmpty {
                    m3uGroup = String(line.dropFirst("#EXTGRP:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                    continue
                }

                if line.hasPrefix("#") { continue }

                if !pendingTitle.isEmpty {
                    try addStream(
                        group: m3uGroup,
                        name: pendingTitle,
                        rawUrl: line,
                        explicitHeaders: pendingHeaders,
                        logo: pendingLogo,
                        marked: true
                    )
                    pendingTitle = ""
                    pendingLogo = ""
                    pendingHeaders = [:]
                    continue
                }

                if line.lowercased().hasSuffix(",#genre#") {
                    currentGroup = String(line.dropLast(8)).trimmingCharacters(in: .whitespacesAndNewlines)
                    continue
                }

                if let commaIdx = line.firstIndex(of: ","), commaIdx > line.startIndex {
                    let chName = String(line[..<commaIdx])
                    let urlSection = String(line[line.index(after: commaIdx)...])
                    for part in splitMultiUrls(urlSection) {
                        try addStream(
                            group: currentGroup,
                            name: chName,
                            rawUrl: part,
                            explicitHeaders: [:]
                        )
                    }
                }
            }
        }

        return groupOrder.map { gName in
            let chNames = channelOrderByGroup[gName] ?? []
            let channels: [LiveChannel] = chNames.map { cName in
                let streams = streamsByGroupAndChannel[gName]?[cName] ?? []
                return LiveChannel(
                    name: cName,
                    group: gName,
                    urls: streams.map(\.url),
                    logo: logosByKey["\(gName)\n\(cName)"] ?? "",
                    streams: streams
                )
            }
            return LiveGroup(name: gName, channels: channels)
        }
    }
}
