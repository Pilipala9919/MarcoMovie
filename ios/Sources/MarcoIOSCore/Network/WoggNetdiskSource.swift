// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// Native catalogue adapter for WoGG (`csp_Wogg` / `csp_WoggGuard`) and WoGG-family
/// 4K netdisk spiders (`csp_Wobg`, `csp_Wanou`, `csp_Panhub`, `csp_Zhizhen`, `csp_Mihdr`,
/// `csp_Muou`, `csp_Shandian`, `csp_Xiaomi`, `csp_Erxiao`, `csp_Ouge`, `csp_Tudou`,
/// `csp_Labi`, `csp_Duoduo`, `csp_Huban`, `csp_Huajuan`, `csp_Xiaopan`, `csp_Kuaiying`,
/// `csp_Qingying`, `csp_Woniu`, `csp_Zhinan`, `csp_Yidong4k`, `csp_Fengye4k`, etc.).
/// Data-only parser; never embeds default domains and relies solely on user-configured `site.ext`.
public final class WoggNetdiskSource: @unchecked Sendable {
    public static let defaultCategories: [CmsCategory] = [
        CmsCategory(id: "1", name: "电影"),
        CmsCategory(id: "2", name: "剧集"),
        CmsCategory(id: "44", name: "臻彩"),
        CmsCategory(id: "6", name: "短漫剧"),
        CmsCategory(id: "3", name: "动漫"),
        CmsCategory(id: "4", name: "综艺"),
        CmsCategory(id: "46", name: "纪录片"),
        CmsCategory(id: "5", name: "音乐"),
    ]

    private static let supportedApiPattern = try! NSRegularExpression(
        pattern: #"^csp_(?:wogg|wobg|wanou|panhub|zhizhen|mihdr|muou|shandian|xiaomi|erxiao|ouge|tudou|labi|duoduo|huban|huajuan|xiaopan|kuaiying|qingying|woniu|zhinan|yidong|yidong4k|fengye|fengye4k|fengqi4k|kaka|jike|qiwei|leijing|haimian|panta|yiso)(?:guard)?$"#,
        options: [.caseInsensitive]
    )

    private static let domainKeys: Set<String> = [
        "siteurl", "siteurls", "site", "url", "urls", "host", "hosts",
        "domain", "domains", "baseurl", "base_url", "home", "api", "server", "servers",
    ]

    public static func supports(_ site: CmsSite) -> Bool {
        guard site.type == 3 else { return false }
        let api = site.api.trimmingCharacters(in: .whitespacesAndNewlines)
        guard supportedApiPattern.firstMatch(in: api, range: NSRange(api.startIndex..., in: api)) != nil else {
            return false
        }
        return !parseDomains(from: site.ext, siteKey: api).isEmpty
            || !parseDomains(from: site.ext, siteKey: site.sourceKey).isEmpty
    }

    public static func parseDomains(from rawExt: String, siteKey: String = "") -> [URL] {
        let trimmed = rawExt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var results: [URL] = []
        var seen = Set<String>()
        let normalizedKey = siteKey
            .lowercased()
            .replacingOccurrences(of: "csp_", with: "")
            .replacingOccurrences(of: "guard", with: "")

        func considerToken(_ raw: String) {
            var token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { return }
            if token.hasPrefix("//") { token = "https:\(token)" }
            if !token.contains("://") && token.contains(".") && !token.contains(" ") {
                token = "https://\(token)"
            }
            guard let url = URL(string: token),
                  let scheme = url.scheme?.lowercased(),
                  (scheme == "http" || scheme == "https"),
                  let host = url.host, !host.isEmpty,
                  url.user == nil, url.password == nil
            else { return }
            let lowerPath = url.path.lowercased()
            let blockedExts = [".jar", ".js", ".mjs", ".py", ".zip", ".png", ".jpg", ".json", ".txt", ".conf"]
            if blockedExts.contains(where: { lowerPath.hasSuffix($0) }) { return }
            if NetdiskShareResolver.detectDriveKey(for: url.absoluteString) != nil { return }
            var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            comps?.fragment = nil
            if comps?.path.isEmpty ?? true { comps?.path = "/" }
            if let cleanUrl = comps?.url, seen.insert(cleanUrl.absoluteString).inserted {
                results.append(cleanUrl)
            }
        }

        func visit(_ any: Any, depth: Int) {
            guard depth <= 6, results.count < 8 else { return }
            if let s = any as? String {
                let sTrim = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if (sTrim.hasPrefix("{") || sTrim.hasPrefix("[")),
                   let parsed = try? JSONSerialization.jsonObject(with: Data(ConfigDecoder.stripJsonComments(sTrim).utf8))
                {
                    visit(parsed, depth: depth + 1)
                    return
                }
                for tok in sTrim.components(separatedBy: CharacterSet(charactersIn: " \t\r\n,;|")) {
                    considerToken(tok)
                    if results.count >= 8 { break }
                }
            } else if let arr = any as? [Any] {
                for item in arr { visit(item, depth: depth + 1) }
            } else if let dict = any as? [String: Any] {
                for (k, v) in dict {
                    let lk = k.lowercased()
                    if domainKeys.contains(lk) || lk == normalizedKey || lk == siteKey.lowercased() {
                        visit(v, depth: depth + 1)
                    } else if ["data", "sites", "configurations"].contains(lk) {
                        visit(v, depth: depth + 1)
                    }
                }
            }
        }

        visit(trimmed, depth: 0)
        return results
    }

    public static func homeContent(
        site: CmsSite,
        fetchText: CspTextFetcher
    ) async throws -> SiteHomePayload {
        guard let origin = parseDomains(from: site.ext, siteKey: site.api).first
            ?? parseDomains(from: site.ext, siteKey: site.sourceKey).first
        else {
            throw MarcoError.unsupportedSite("网盘站点未配置有效站点域名")
        }
        let html = try await fetchText(origin.absoluteString, defaultHeaders(for: site, origin: origin))
        let videos = extractCards(from: html, origin: origin)
        return SiteHomePayload(
            categories: defaultCategories,
            listing: CmsListing(page: 1, pageCount: videos.isEmpty ? 1 : 99, videos: videos)
        )
    }

    public static func categoryContent(
        site: CmsSite,
        categoryId: String,
        page: Int = 1,
        fetchText: CspTextFetcher
    ) async throws -> CmsListing {
        guard let origin = parseDomains(from: site.ext, siteKey: site.api).first
            ?? parseDomains(from: site.ext, siteKey: site.sourceKey).first
        else {
            return CmsListing()
        }
        let baseStr = origin.absoluteString.hasSuffix("/") ? String(origin.absoluteString.dropLast()) : origin.absoluteString
        let urlStr = "\(baseStr)/vodshow/\(categoryId)--------\(max(1, page))---.html"
        let html = try await fetchText(urlStr, defaultHeaders(for: site, origin: origin))
        let videos = extractCards(from: html, origin: origin)
        return CmsListing(page: max(1, page), pageCount: videos.isEmpty ? max(1, page) : max(1, page) + 1, videos: videos)
    }

    public static func searchContent(
        site: CmsSite,
        keyword: String,
        page: Int = 1,
        fetchText: CspTextFetcher
    ) async throws -> [CmsVideo] {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let origin = parseDomains(from: site.ext, siteKey: site.api).first
                  ?? parseDomains(from: site.ext, siteKey: site.sourceKey).first
        else {
            return []
        }
        let baseStr = origin.absoluteString.hasSuffix("/") ? String(origin.absoluteString.dropLast()) : origin.absoluteString
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#/")
        let enc = trimmed.addingPercentEncoding(withAllowedCharacters: allowed) ?? trimmed
        let urlStr = "\(baseStr)/vodsearch/\(enc)----------\(max(1, page))---.html"
        let html = try await fetchText(urlStr, defaultHeaders(for: site, origin: origin))
        return extractCards(from: html, origin: origin)
    }

    public static func detailContent(
        site: CmsSite,
        video: CmsVideo,
        fetchText: CspTextFetcher
    ) async throws -> CmsVideo {
        guard let origin = parseDomains(from: site.ext, siteKey: site.api).first
            ?? parseDomains(from: site.ext, siteKey: site.sourceKey).first
        else {
            return video
        }
        let detailUrl = CmsParser.resolveUrl(base: origin.absoluteString, relative: video.id)
        let html = try await fetchText(detailUrl, defaultHeaders(for: site, origin: origin))
        let lines = extractShareLines(from: html)
        return CmsVideo(
            id: video.id,
            title: video.title,
            poster: video.poster,
            remarks: video.remarks,
            year: video.year,
            area: video.area,
            actor: video.actor,
            director: video.director,
            description: video.description,
            tag: video.tag,
            doubanScore: video.doubanScore,
            rtScore: video.rtScore,
            lines: lines.isEmpty ? video.lines : lines
        )
    }

    private static func defaultHeaders(for site: CmsSite, origin: URL) -> [String: String] {
        var h = site.headers
        if h.keys.allSatisfy({ $0.lowercased() != "user-agent" }) {
            h["User-Agent"] = CmsClient.defaultSafariUserAgent
        }
        if h.keys.allSatisfy({ $0.lowercased() != "referer" }) {
            h["Referer"] = origin.absoluteString
        }
        return h
    }

    private static func extractCards(from html: String, origin: URL) -> [CmsVideo] {
        guard let re = try? NSRegularExpression(
            pattern: #"<a\b[^>]*href=["']([^"']*(?:/voddetail/|/index\.php/vod/detail)[^"']*)["'][^>]*title=["']([^"']+)["'][^>]*>([\s\S]*?)</a>"#,
            options: [.caseInsensitive]
        ) else { return [] }
        let imgRe = try? NSRegularExpression(
            pattern: #"(?:data-original|data-src|src)=["']([^"']+)["']"#,
            options: [.caseInsensitive]
        )
        var out: [CmsVideo] = []
        var seen = Set<String>()
        for m in re.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let rHref = Range(m.range(at: 1), in: html),
                  let rTitle = Range(m.range(at: 2), in: html),
                  let rInner = Range(m.range(at: 3), in: html)
            else { continue }
            let id = CmsParser.resolveUrl(base: origin.absoluteString, relative: String(html[rHref]))
            let title = CmsParser.cleanHtml(String(html[rTitle]))
            guard !id.isEmpty, !title.isEmpty, seen.insert(id).inserted else { continue }
            let inner = String(html[rInner])
            var poster = ""
            if let im = imgRe?.firstMatch(in: inner, range: NSRange(inner.startIndex..., in: inner)),
               let rImg = Range(im.range(at: 1), in: inner)
            {
                poster = CmsParser.cleanPosterUrl(CmsParser.resolveUrl(base: origin.absoluteString, relative: String(inner[rImg])))
            }
            out.append(CmsVideo(id: id, title: title, poster: poster))
        }
        return out
    }

    public static func extractShareLines(from html: String) -> [CmsLine] {
        guard let shareRe = try? NSRegularExpression(
            pattern: #"https?://(?:pan\.quark\.cn|drive\.uc\.cn|pan\.baidu\.com|www\.alipan\.com|www\.aliyundrive\.com|115\.com|115cdn\.com|anxia\.com)/s/[A-Za-z0-9_\-/?=&%]+"#,
            options: [.caseInsensitive]
        ) else { return [] }

        var countsByProvider: [String: Int] = [:]
        var seen = Set<String>()
        var lines: [CmsLine] = []
        for m in shareRe.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let r = Range(m.range, in: html) else { continue }
            let shareUrl = String(html[r]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard seen.insert(shareUrl).inserted,
                  let driveKey = NetdiskShareResolver.detectDriveKey(for: shareUrl),
                  let info = NetdiskDriveInfo.info(for: driveKey)
            else { continue }
            let ordinal = countsByProvider[driveKey, default: 0] + 1
            countsByProvider[driveKey] = ordinal
            let lineName = "\(info.providerName) \(ordinal)"
            lines.append(CmsLine(name: lineName, episodes: [CmsEpisode(name: "原画播放", url: shareUrl)]))
        }
        return lines
    }
}
