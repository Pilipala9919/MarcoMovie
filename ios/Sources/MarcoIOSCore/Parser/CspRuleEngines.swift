// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only

import Foundation

public typealias CspTextFetcher = @Sendable (_ url: String, _ headers: [String: String]) async throws -> String

/// Declarative data-only rule engine for TVBox `csp_XBPQ`, `csp_XYQ`, and `csp_XPath*`
/// subscription sources. Evaluates HTML/JSON extraction templates from `site.ext`
/// without executing third-party code or bypassing verification challenges.
public final class CspRuleEngines: @unchecked Sendable {
    private static let desktopUA =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
    private static let mobileUA =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    private static let cacheLock = NSLock()
    private static var ruleCache: [String: [String: Any]] = [:]

    public static func isXbpqSite(_ site: CmsSite) -> Bool {
        let api = site.api.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return api == "csp_xbpq" || api == "csp_xbpqguard"
    }

    public static func isXyqSite(_ site: CmsSite) -> Bool {
        let api = site.api.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return api == "csp_xyq" || api == "csp_xyqguard"
    }

    public static func isXpathSite(_ site: CmsSite) -> Bool {
        let api = site.api.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let allowed: Set<String> = [
            "csp_xpath", "csp_xpathguard",
            "csp_xpathfilter", "csp_xpathfilterguard",
            "csp_xpathmac", "csp_xpathmacfilter",
        ]
        return allowed.contains(api)
    }

    public static func supports(_ site: CmsSite) -> Bool {
        guard !site.ext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return isXbpqSite(site) || isXyqSite(site) || isXpathSite(site)
    }

    public static func parseLenientJsonObject(_ raw: String) throws -> [String: Any] {
        let cleaned = ConfigDecoder.stripJsonComments(raw)
        guard !cleaned.isEmpty,
              let data = cleaned.data(using: .utf8),
              let decoded = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any]
        else {
            throw MarcoError.invalidFormat("规则格式不是有效的 JSON 对象")
        }
        return decoded
    }

    private static func cacheKey(for site: CmsSite) -> String {
        "\(site.subscriptionId)|\(site.sourceKey)|\(site.isEffectivelyPrivate)|\(site.api.lowercased())|\(site.ext.hashValue)"
    }

    private static func loadRule(site: CmsSite, fetchText: CspTextFetcher) async throws -> [String: Any] {
        let key = cacheKey(for: site)
        cacheLock.lock()
        let cached = ruleCache[key]
        cacheLock.unlock()
        if let cached = cached { return cached }

        let ext = site.ext.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ext.isEmpty else {
            throw MarcoError.invalidFormat("缺少规则扩展配置")
        }

        var loaded: [String: Any]?
        if ext.hasPrefix("{") {
            let parsed = try parseLenientJsonObject(ext)
            let remoteUrl = firstString(parsed, keys: ["url", "rule", "json"])
            if (remoteUrl.lowercased().hasPrefix("http://") || remoteUrl.lowercased().hasPrefix("https://"))
                && parsed.count <= 3
                && parsed["分类url"] == nil
                && parsed["分类链接"] == nil
                && parsed["cateUrl"] == nil
            {
                let remoteRaw = try await fetchText(remoteUrl, site.headers)
                var merged = try parseLenientJsonObject(remoteRaw)
                for (k, v) in parsed { merged[k] = v }
                loaded = merged
            } else {
                loaded = parsed
            }
        } else if ext.lowercased().hasPrefix("http://") || ext.lowercased().hasPrefix("https://") {
            let remoteRaw = try await fetchText(ext, site.headers)
            loaded = try parseLenientJsonObject(remoteRaw)
        } else {
            var b64 = ext.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            while b64.count % 4 != 0 { b64.append("=") }
            if let data = Data(base64Encoded: b64) {
                let decoded = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                if decoded.hasPrefix("{") {
                    loaded = try parseLenientJsonObject(decoded)
                } else if decoded.lowercased().hasPrefix("http://") || decoded.lowercased().hasPrefix("https://") {
                    let remoteRaw = try await fetchText(decoded, site.headers)
                    loaded = try parseLenientJsonObject(remoteRaw)
                }
            }
        }

        guard let rule = loaded else {
            throw MarcoError.invalidFormat("无法解析规则扩展配置")
        }

        cacheLock.lock()
        if ruleCache.count >= 64 {
            ruleCache.removeAll()
        }
        ruleCache[key] = rule
        cacheLock.unlock()
        return rule
    }

    // MARK: - Public CMS Operations

    public static func homeContent(
        site: CmsSite,
        fetchText: CspTextFetcher
    ) async throws -> SiteHomePayload {
        let rule = try await loadRule(site: site, fetchText: fetchText)
        let origin = originOf(rule)
        let headers = headersForRule(site: site, rule: rule, refererOrigin: origin)

        var categories = extractInlineCategories(rule)
        let homeUrl = firstString(rule, keys: ["主页url", "首页推荐链接", "homeUrl"])
        var videos: [CmsVideo] = []

        if !homeUrl.isEmpty, homeUrl.lowercased().hasPrefix("http") {
            let html = try await fetchText(homeUrl, headers)
            try checkChallenge(html)
            if categories.isEmpty {
                categories = extractCategoriesFromHtml(html, rule: rule, origin: origin)
            }
            videos = extractVideosFromHtml(html, rule: rule, origin: origin)
        }

        if videos.isEmpty, let firstCat = categories.first {
            let listing = try await categoryContent(
                site: site,
                categoryId: firstCat.id,
                page: 1,
                fetchText: fetchText
            )
            videos = listing.videos
        }

        if categories.isEmpty && !videos.isEmpty {
            categories = [CmsCategory(id: "all", name: "精选")]
        }
        return SiteHomePayload(
            categories: categories,
            listing: CmsListing(page: 1, pageCount: videos.isEmpty ? 1 : 99, videos: videos)
        )
    }

    public static func categoryContent(
        site: CmsSite,
        categoryId: String,
        page: Int = 1,
        fetchText: CspTextFetcher
    ) async throws -> CmsListing {
        let rule = try await loadRule(site: site, fetchText: fetchText)
        let origin = originOf(rule)
        let headers = headersForRule(site: site, rule: rule, refererOrigin: origin)

        let rawTemplate = firstString(rule, keys: ["分类url", "分类链接", "cateUrl"])
        guard !rawTemplate.isEmpty else {
            return CmsListing(page: page, pageCount: 1, videos: [])
        }
        let template = rawTemplate.components(separatedBy: ";;").first ?? rawTemplate
        let expandedUrl = expandUrlTemplate(template, cateId: categoryId, page: max(1, page), keyword: "")
        let resolvedUrl = resolveHref(baseOrigin: origin, raw: expandedUrl)
        guard resolvedUrl.lowercased().hasPrefix("http") else {
            return CmsListing(page: page, pageCount: 1, videos: [])
        }
        let html = try await fetchText(resolvedUrl, headers)
        try checkChallenge(html)
        let videos = extractVideosFromHtml(html, rule: rule, origin: origin)
        return CmsListing(page: max(1, page), pageCount: videos.isEmpty ? max(1, page) : max(1, page) + 1, videos: videos)
    }

    public static func searchContent(
        site: CmsSite,
        keyword: String,
        page: Int = 1,
        fetchText: CspTextFetcher
    ) async throws -> [CmsVideo] {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let rule = try await loadRule(site: site, fetchText: fetchText)
        let origin = originOf(rule)
        let headers = headersForRule(site: site, rule: rule, refererOrigin: origin)

        let template = firstString(rule, keys: ["搜索url", "搜索链接", "searchUrl"])
        guard !template.isEmpty else { return [] }
        let cleanTpl = template.components(separatedBy: ";").first ?? template
        let encodedKw = queryEncode(trimmed)
        let expanded = expandUrlTemplate(cleanTpl, cateId: "", page: max(1, page), keyword: encodedKw)
        let url = resolveHref(baseOrigin: origin, raw: expanded)
        guard url.lowercased().hasPrefix("http") else { return [] }

        let body = try await fetchText(url, headers)
        try checkChallenge(body)

        // MacCMS JSON search response (`{"list":[...]}`)
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedBody.hasPrefix("{") || trimmedBody.hasPrefix("[") {
            if let listing = try? CmsParser.parseListing(trimmedBody), !listing.videos.isEmpty {
                return listing.videos
            }
            if let data = trimmedBody.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let list = obj["list"] as? [[String: Any]]
            {
                let idPrefix = firstString(rule, keys: ["搜索链接前缀", "链接前缀"])
                let idSuffix = firstString(rule, keys: ["搜索链接后缀", "链接后缀"])
                return list.compactMap { item in
                    let rawId = stringVal(item["id"] ?? item["vod_id"])
                    let name = stringVal(item["name"] ?? item["vod_name"])
                    guard !rawId.isEmpty, !name.isEmpty else { return nil }
                    let fullId = resolveHref(baseOrigin: origin, raw: rawId, prefix: idPrefix, suffix: idSuffix)
                    let pic = resolveHref(baseOrigin: origin, raw: stringVal(item["pic"] ?? item["vod_pic"]))
                    return CmsVideo(id: fullId, title: name, poster: pic)
                }
            }
        }
        return extractVideosFromHtml(body, rule: rule, origin: origin, isSearch: true)
    }

    public static func detailContent(
        site: CmsSite,
        video: CmsVideo,
        fetchText: CspTextFetcher
    ) async throws -> CmsVideo {
        let rule = try await loadRule(site: site, fetchText: fetchText)
        let origin = originOf(rule)
        let headers = headersForRule(site: site, rule: rule, refererOrigin: origin)

        let detailUrl = resolveHref(baseOrigin: origin, raw: video.id)
        guard detailUrl.lowercased().hasPrefix("http") else {
            return video
        }
        let html = try await fetchText(detailUrl, headers)
        try checkChallenge(html)

        let title = extractPatternValue(html, pattern: firstString(rule, keys: ["影片名称", "dtNameR"]))
            .nonEmptyOr(video.title)
        let desc = CmsParser.cleanHtml(extractPatternValue(html, pattern: firstString(rule, keys: ["简介", "剧情简介", "dtDescR"])))
            .nonEmptyOr(video.description)
        let actor = CmsParser.cleanHtml(extractPatternValue(html, pattern: firstString(rule, keys: ["主演", "dtActorR"])))
            .nonEmptyOr(video.actor)
        let director = CmsParser.cleanHtml(extractPatternValue(html, pattern: firstString(rule, keys: ["导演", "dtDirectorR"])))
            .nonEmptyOr(video.director)
        let year = CmsParser.cleanHtml(extractPatternValue(html, pattern: firstString(rule, keys: ["影片年代", "dtYearR"])))
            .nonEmptyOr(video.year)
        let area = CmsParser.cleanHtml(extractPatternValue(html, pattern: firstString(rule, keys: ["影片地区", "dtAreaR"])))
            .nonEmptyOr(video.area)

        let lines = extractDetailLines(html: html, rule: rule, origin: origin)
        return CmsVideo(
            id: video.id,
            title: title,
            poster: video.poster,
            remarks: video.remarks,
            year: year,
            area: area,
            actor: actor,
            director: director,
            description: desc,
            tag: video.tag,
            doubanScore: video.doubanScore,
            rtScore: video.rtScore,
            lines: lines.isEmpty ? video.lines : lines
        )
    }

    public static func resolvePlayUrl(
        site: CmsSite,
        episodeUrl: String,
        fetchText: CspTextFetcher
    ) async throws -> (url: String, headers: [String: String]) {
        let rule = try await loadRule(site: site, fetchText: fetchText)
        let origin = originOf(rule)
        let headers = headersForRule(site: site, rule: rule, refererOrigin: origin)
        let targetUrl = resolveHref(baseOrigin: origin, raw: episodeUrl)
        guard targetUrl.lowercased().hasPrefix("http") else {
            return (episodeUrl, headers)
        }
        let html = try await fetchText(targetUrl, headers)
        try checkChallenge(html)

        // Extract standard player_aaaa JSON or direct m3u8/mp4 URL
        if let playerRegex = try? NSRegularExpression(
            pattern: #"player_aaaa\s*=\s*(\{[\s\S]*?\})\s*(?:;|</script>)"#,
            options: [.caseInsensitive]
        ),
           let match = playerRegex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
           let r1 = Range(match.range(at: 1), in: html),
           let data = String(html[r1]).data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let rawUrl = obj["url"] as? String
        {
            var decodedUrl = rawUrl.trimmingCharacters(in: .whitespacesAndNewlines)
            let encryptMode = (obj["encrypt"] as? NSNumber)?.intValue ?? 0
            if encryptMode == 1 {
                decodedUrl = decodedUrl.removingPercentEncoding ?? decodedUrl
            } else if encryptMode == 2 {
                if let b64 = Data(base64Encoded: decodedUrl) {
                    let s = String(decoding: b64, as: UTF8.self)
                    decodedUrl = s.removingPercentEncoding ?? s
                }
            }
            if decodedUrl.lowercased().hasPrefix("http") {
                return (decodedUrl, headers)
            }
        }

        if let directRe = try? NSRegularExpression(
            pattern: #"https?://[^\s"'<>\\]+?\.(?:m3u8|mp4|flv|mkv)(?:\?[^\s"'<>\\]*)?"#,
            options: [.caseInsensitive]
        ),
           let match = directRe.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
           let r = Range(match.range, in: html)
        {
            return (String(html[r]).replacingOccurrences(of: "\\/", with: "/"), headers)
        }

        return (targetUrl, headers)
    }

    // MARK: - Declarative Extraction Helpers

    private static func checkChallenge(_ html: String) throws {
        guard !html.isEmpty else { return }
        let pattern = #"(?:SafeLineChallenge|__cdn_pow|sl-challenge-jwt|Checking your browser|challenges\.cloudflare\.com|<title>\s*Just a moment\.\.\.\s*</title>|cf-turnstile|系统安全验证|正在验证您的浏览器|人机验证|verify you are human|请完成滑块验证)"#
        if let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
           re.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)) != nil
        {
            throw MarcoError.unsupportedSite("该站点启用了人机验证，请稍后重试或切换其他片源")
        }
    }

    private static func headersForRule(
        site: CmsSite,
        rule: [String: Any],
        refererOrigin: String
    ) -> [String: String] {
        var out: [String: String] = ["User-Agent": desktopUA]
        for (k, v) in site.headers { out[k] = v }

        let rawUa = firstString(rule, keys: ["请求头", "请求头参数", "ua", "User-Agent"])
        let lowerUa = rawUa.lowercased()
        if rawUa == "手机" || lowerUa == "mobile" || rawUa == "MOBILE_UA" {
            out["User-Agent"] = mobileUA
        } else if rawUa == "电脑" || lowerUa == "pc" || rawUa == "PC_UA" {
            out["User-Agent"] = desktopUA
        } else if rawUa.contains("#") {
            for part in rawUa.components(separatedBy: "#") {
                if let sep = part.firstIndex(of: "$") {
                    let hk = String(part[..<sep]).trimmingCharacters(in: .whitespacesAndNewlines)
                    let hv = String(part[part.index(after: sep)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !hk.isEmpty && !hv.isEmpty { out[hk] = hv }
                }
            }
        } else if rawUa.hasPrefix("Mozilla/") || rawUa.hasPrefix("okhttp/") {
            out["User-Agent"] = rawUa
        }

        if refererOrigin.lowercased().hasPrefix("http"),
           out.keys.allSatisfy({ $0.lowercased() != "referer" })
        {
            out["Referer"] = refererOrigin.hasSuffix("/") ? refererOrigin : "\(refererOrigin)/"
        }
        return out
    }

    private static func originOf(_ rule: [String: Any]) -> String {
        let keys = ["主页url", "首页推荐链接", "homeUrl", "分类url", "分类链接", "cateUrl", "搜索url", "搜索链接", "searchUrl"]
        guard let re = try? NSRegularExpression(pattern: #"^(https?://[^/?#\s\[]+)"#, options: [.caseInsensitive]) else {
            return ""
        }
        for k in keys {
            let raw = stringVal(rule[k])
            if let m = re.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
               let r = Range(m.range(at: 1), in: raw)
            {
                return String(raw[r])
            }
        }
        return ""
    }

    private static func extractInlineCategories(_ rule: [String: Any]) -> [CmsCategory] {
        if let cateManual = rule["cateManual"] as? [String: Any], !cateManual.isEmpty {
            return cateManual.compactMap { k, v in
                let name = k.trimmingCharacters(in: .whitespacesAndNewlines)
                let val = stringVal(v)
                return (!name.isEmpty && !val.isEmpty) ? CmsCategory(id: val, name: name) : nil
            }
        }
        let rawClass = firstString(rule, keys: ["分类", "手工分类"])
        if !rawClass.isEmpty {
            var out: [CmsCategory] = []
            for part in rawClass.components(separatedBy: "#") {
                let seg = part.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let dollar = seg.firstIndex(of: "$") else { continue }
                let name = String(seg[..<dollar]).trimmingCharacters(in: .whitespacesAndNewlines)
                let id = String(seg[seg.index(after: dollar)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty && !id.isEmpty {
                    out.append(CmsCategory(id: id, name: name))
                }
            }
            if !out.isEmpty { return out }
        }
        let namesStr = firstString(rule, keys: ["分类名称"])
        let idsStr = firstString(rule, keys: ["分类名称替换词", "分类值"])
        if !namesStr.isEmpty && !idsStr.isEmpty {
            let names = namesStr.components(separatedBy: "&")
            let ids = idsStr.components(separatedBy: "&")
            var out: [CmsCategory] = []
            for i in 0..<min(names.count, ids.count) {
                let n = names[i].trimmingCharacters(in: .whitespacesAndNewlines)
                let cid = ids[i].trimmingCharacters(in: .whitespacesAndNewlines)
                if !n.isEmpty && !cid.isEmpty {
                    out.append(CmsCategory(id: cid, name: n))
                }
            }
            return out
        }
        return []
    }

    private static func extractCategoriesFromHtml(_ html: String, rule: [String: Any], origin: String) -> [CmsCategory] {
        let blockRule = firstString(rule, keys: ["分类二次截取"])
        let scope = blockRule.isEmpty ? html : sliceBetween(html, rule: blockRule)
        let itemRule = firstString(rule, keys: ["分类数组"])
        guard !itemRule.isEmpty else { return [] }
        let chunks = extractAllBetween(scope, rule: itemRule)
        var out: [CmsCategory] = []
        for chunk in chunks {
            let title = CmsParser.cleanHtml(extractPatternValue(chunk, pattern: firstString(rule, keys: ["分类标题"]).nonEmptyOr(">&&<")))
            let id = extractPatternValue(chunk, pattern: firstString(rule, keys: ["分类ID"]).nonEmptyOr("href=\"&&\""))
            if !title.isEmpty && !id.isEmpty {
                out.append(CmsCategory(id: id, name: title))
            }
        }
        return out
    }

    private static func extractVideosFromHtml(
        _ html: String,
        rule: [String: Any],
        origin: String,
        isSearch: Bool = false
    ) -> [CmsVideo] {
        let scopeRule = isSearch
            ? firstString(rule, keys: ["搜索二次截取", "二次截取"])
            : firstString(rule, keys: ["二次截取"])
        let scope = scopeRule.isEmpty ? html : sliceBetween(html, rule: scopeRule)

        let arrayRule = isSearch
            ? firstString(rule, keys: ["搜索数组", "数组"])
            : firstString(rule, keys: ["数组"])

        let chunks: [String]
        if !arrayRule.isEmpty {
            chunks = extractAllBetween(scope, rule: arrayRule)
        } else {
            chunks = extractAnchorCardsFallback(scope)
        }

        let titlePattern = (isSearch ? firstString(rule, keys: ["搜索标题", "标题"]) : firstString(rule, keys: ["标题"]))
            .nonEmptyOr("title=\"&&\"")
        let picPattern = (isSearch ? firstString(rule, keys: ["搜索图片", "图片"]) : firstString(rule, keys: ["图片"]))
            .nonEmptyOr("data-original=\"&&\"||src=\"&&\"")
        let linkPattern = (isSearch ? firstString(rule, keys: ["搜索链接", "链接"]) : firstString(rule, keys: ["链接"]))
            .nonEmptyOr("href=\"&&\"")
        let remarkPattern = isSearch ? firstString(rule, keys: ["搜索副标题", "副标题"]) : firstString(rule, keys: ["副标题"])
        let linkPrefix = isSearch ? firstString(rule, keys: ["搜索链接前缀", "链接前缀"]) : firstString(rule, keys: ["链接前缀"])
        let linkSuffix = isSearch ? firstString(rule, keys: ["搜索链接后缀", "链接后缀"]) : firstString(rule, keys: ["链接后缀"])

        var videos: [CmsVideo] = []
        var seen = Set<String>()
        for chunk in chunks {
            let rawTitle = CmsParser.cleanHtml(extractPatternValue(chunk, pattern: titlePattern))
            let rawLink = extractPatternValue(chunk, pattern: linkPattern)
            let resolvedId = resolveHref(baseOrigin: origin, raw: rawLink, prefix: linkPrefix, suffix: linkSuffix)
            guard !rawTitle.isEmpty, !resolvedId.isEmpty, seen.insert(resolvedId).inserted else { continue }
            let rawPic = extractPatternValue(chunk, pattern: picPattern)
            let resolvedPic = CmsParser.cleanPosterUrl(resolveHref(baseOrigin: origin, raw: rawPic))
            let remarks = remarkPattern.isEmpty ? "" : CmsParser.cleanHtml(extractPatternValue(chunk, pattern: remarkPattern))
            videos.append(CmsVideo(id: resolvedId, title: rawTitle, poster: resolvedPic, remarks: remarks))
        }
        return videos
    }

    private static func extractDetailLines(html: String, rule: [String: Any], origin: String) -> [CmsLine] {
        let lineNames: [String] = {
            let tabScopeRule = firstString(rule, keys: ["线路二次截取"])
            let tabScope = tabScopeRule.isEmpty ? html : sliceBetween(html, rule: tabScopeRule)
            let tabArrRule = firstString(rule, keys: ["线路数组"])
            guard !tabArrRule.isEmpty else { return [] }
            let titleRule = firstString(rule, keys: ["线路标题"]).nonEmptyOr(">&&<")
            return extractAllBetween(tabScope, rule: tabArrRule)
                .map { CmsParser.cleanHtml(extractPatternValue($0, pattern: titleRule)) }
                .filter { !$0.isEmpty }
        }()

        let playScopeRule = firstString(rule, keys: ["播放二次截取"])
        let playScope = playScopeRule.isEmpty ? html : sliceBetween(html, rule: playScopeRule)
        let playArrRule = firstString(rule, keys: ["播放数组"])
        let playLinkPrefix = firstString(rule, keys: ["播放链接前缀", "链接前缀"])
        let playLinkSuffix = firstString(rule, keys: ["播放链接后缀", "链接后缀"])

        let listBlocks = playArrRule.isEmpty ? [playScope] : extractAllBetween(playScope, rule: playArrRule)
        var lines: [CmsLine] = []

        for (idx, block) in listBlocks.enumerated() {
            let epListRule = firstString(rule, keys: ["播放列表"]).nonEmptyOr("<a&&/a>")
            let epTitleRule = firstString(rule, keys: ["播放标题"]).nonEmptyOr(">&&<")
            let epLinkRule = firstString(rule, keys: ["播放链接"]).nonEmptyOr("href=\"&&\"")
            let epChunks = extractAllBetween(block, rule: epListRule)
            var episodes: [CmsEpisode] = []
            for epChunk in epChunks {
                let epName = CmsParser.cleanHtml(extractPatternValue(epChunk, pattern: epTitleRule))
                let rawHref = extractPatternValue(epChunk, pattern: epLinkRule)
                let href = resolveHref(baseOrigin: origin, raw: rawHref, prefix: playLinkPrefix, suffix: playLinkSuffix)
                if !href.isEmpty {
                    episodes.append(CmsEpisode(name: epName.isEmpty ? "第 \(episodes.count + 1) 集" : epName, url: href))
                }
            }
            if !episodes.isEmpty {
                let name = idx < lineNames.count ? lineNames[idx] : "线路 \(lines.count + 1)"
                lines.append(CmsLine(name: name, episodes: episodes))
            }
        }
        return lines
    }

    private static func extractAnchorCardsFallback(_ html: String) -> [String] {
        guard let re = try? NSRegularExpression(
            pattern: #"<a\b[^>]*href=["'][^"']+["'][^>]*>[\s\S]*?</a>"#,
            options: [.caseInsensitive]
        ) else {
            return []
        }
        return re.matches(in: html, range: NSRange(html.startIndex..., in: html)).compactMap { m in
            Range(m.range, in: html).map { String(html[$0]) }
        }
    }

    private static func expandUrlTemplate(_ template: String, cateId: String, page: Int, keyword: String) -> String {
        var out = template
            .replacingOccurrences(of: "{cateId}", with: cateId)
            .replacingOccurrences(of: "{catePg}", with: "\(page)")
            .replacingOccurrences(of: "{pg}", with: "\(page)")
            .replacingOccurrences(of: "{wd}", with: keyword)
            .replacingOccurrences(of: "**", with: keyword)
            .replacingOccurrences(of: "fypage", with: "\(page)")
        // Strip optional filter placeholders like `{area}`, `{year}`, `{by}`, `{class}`, `{lang}`
        if let re = try? NSRegularExpression(pattern: #"\{[a-zA-Z0-9_]+\}"#) {
            out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "")
        }
        return out
    }

    private static func sliceBetween(_ text: String, rule: String) -> String {
        let parts = rule.components(separatedBy: "&&")
        guard parts.count == 2 else { return text }
        let startMarker = parts[0]
        let endMarker = parts[1]
        var cursor = text.startIndex
        if !startMarker.isEmpty {
            guard let sRange = text.range(of: startMarker) else { return text }
            cursor = sRange.upperBound
        }
        if !endMarker.isEmpty, let eRange = text.range(of: endMarker, range: cursor..<text.endIndex) {
            return String(text[cursor..<eRange.lowerBound])
        }
        return String(text[cursor...])
    }

    private static func extractAllBetween(_ text: String, rule: String) -> [String] {
        let alternatives = rule.components(separatedBy: "||")
        for alt in alternatives {
            let trimmed = alt.trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = trimmed.components(separatedBy: "&&")
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { continue }
            var results: [String] = []
            var searchStart = text.startIndex
            while searchStart < text.endIndex,
                  let sRange = text.range(of: parts[0], range: searchStart..<text.endIndex)
            {
                let contentStart = sRange.upperBound
                guard let eRange = text.range(of: parts[1], range: contentStart..<text.endIndex) else { break }
                results.append(String(text[contentStart..<eRange.lowerBound]))
                searchStart = eRange.upperBound
                if results.count >= 200 { break }
            }
            if !results.isEmpty { return results }
        }
        return []
    }

    private static func extractPatternValue(_ text: String, pattern: String) -> String {
        guard !pattern.isEmpty else { return "" }
        for alt in pattern.components(separatedBy: "||") {
            let trimmed = alt.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.contains("&&") {
                let parts = trimmed.components(separatedBy: "&&")
                if parts.count == 2 {
                    var startIdx = text.startIndex
                    if !parts[0].isEmpty {
                        guard let sr = text.range(of: parts[0]) else { continue }
                        startIdx = sr.upperBound
                    }
                    if !parts[1].isEmpty {
                        guard let er = text.range(of: parts[1], range: startIdx..<text.endIndex) else { continue }
                        let val = String(text[startIdx..<er.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                        if !val.isEmpty { return val }
                    } else {
                        let val = String(text[startIdx...]).trimmingCharacters(in: .whitespacesAndNewlines)
                        if !val.isEmpty { return val }
                    }
                }
            } else if let re = try? NSRegularExpression(pattern: trimmed, options: [.caseInsensitive]),
                      let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
            {
                let groupIdx = m.numberOfRanges > 1 ? 1 : 0
                if let r = Range(m.range(at: groupIdx), in: text) {
                    let val = String(text[r]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !val.isEmpty { return val }
                }
            }
        }
        return ""
    }

    private static func resolveHref(baseOrigin: String, raw: String, prefix: String = "", suffix: String = "") -> String {
        var v = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty else { return "" }
        if !prefix.isEmpty && !v.lowercased().hasPrefix("http://") && !v.lowercased().hasPrefix("https://") {
            v = prefix + v
        }
        if !suffix.isEmpty && !v.hasSuffix(suffix) {
            v = v + suffix
        }
        return CmsParser.resolveUrl(base: baseOrigin, relative: v)
    }

    private static func firstString(_ dict: [String: Any], keys: [String]) -> String {
        for k in keys {
            let v = stringVal(dict[k])
            if !v.isEmpty { return v }
        }
        return ""
    }

    private static func stringVal(_ any: Any?) -> String {
        guard let any = any, !(any is NSNull) else { return "" }
        if let s = any as? String { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let n = any as? NSNumber { return n.stringValue }
        return ""
    }

    private static func queryEncode(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#/")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

private extension String {
    func nonEmptyOr(_ fallback: String) -> String {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }
}
