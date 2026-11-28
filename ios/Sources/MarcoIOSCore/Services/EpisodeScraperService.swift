// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only

import Foundation

public struct ParsedEpisodeBadges: Equatable, Hashable, Sendable {
    public let seasonNumber: Int?
    public let episodeNumber: Int?
    public let resolution: String
    public let hdrBadge: String
    public let audioBadge: String
    public let codecBadge: String
    public let isDolbyVision: Bool

    public init(
        seasonNumber: Int? = nil,
        episodeNumber: Int? = nil,
        resolution: String = "",
        hdrBadge: String = "",
        audioBadge: String = "",
        codecBadge: String = "",
        isDolbyVision: Bool = false
    ) {
        self.seasonNumber = seasonNumber
        self.episodeNumber = episodeNumber
        self.resolution = resolution
        self.hdrBadge = hdrBadge
        self.audioBadge = audioBadge
        self.codecBadge = codecBadge
        self.isDolbyVision = isDolbyVision
    }
}

/// Public metadata search candidate returned by Douban Rexxar, Bangumi, and Bilibili PGC.
public struct SeriesMetadataCandidate: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String { "\(source):\(subjectId)" }
    public let source: String
    public let subjectId: String
    public let title: String
    public let subtitle: String
    public let year: String
    public let isTv: Bool
    public let isMotionComic: Bool
    public let mediaBadge: String
    public let posterUrl: String
    public let backdropUrl: String
    public let synopsis: String
    public let rating: Double?
    public let episodeCount: Int?

    public init(
        source: String,
        subjectId: String,
        title: String,
        subtitle: String = "",
        year: String = "",
        isTv: Bool = true,
        isMotionComic: Bool = false,
        mediaBadge: String = "",
        posterUrl: String = "",
        backdropUrl: String = "",
        synopsis: String = "",
        rating: Double? = nil,
        episodeCount: Int? = nil
    ) {
        self.source = source
        self.subjectId = subjectId
        self.title = title
        self.subtitle = subtitle
        self.year = year
        self.isTv = isTv
        self.isMotionComic = isMotionComic
        self.mediaBadge = mediaBadge
        self.posterUrl = posterUrl
        self.backdropUrl = backdropUrl
        self.synopsis = synopsis
        self.rating = rating
        self.episodeCount = episodeCount
    }
}

/// Cleans noisy media filenames, extracts season/episode numbers and HDR/DolbyVision/resolution badges,
/// and scrapes live public series candidates, per-episode plot metadata (360 Baike `tvplot` with CSS
/// hidden-class de-obfuscation, Bangumi `/v0/episodes`, Bilibili PGC `eps`), and 16:9 widescreen stills.
public enum EpisodeScraperService {
    private static let mobileUserAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
    private static let desktopUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"

    private static let sxeRegex = try! NSRegularExpression(
        pattern: #"S(\d{1,2})[\s._\-]*E(\d{1,4})"#,
        options: [.caseInsensitive]
    )
    private static let zhEpRegex = try! NSRegularExpression(
        pattern: #"第\s*(\d{1,4})\s*[集话話期回]"#,
        options: []
    )
    private static let epOnlyRegex = try! NSRegularExpression(
        pattern: #"(?:^|[\s._\-\[\(【（])(?:EP?|#)(\d{1,4})(?=$|[\s._\-\]\)】）])"#,
        options: [.caseInsensitive]
    )
    private static let dolbyVisionRegex = try! NSRegularExpression(
        pattern: #"(?:杜比视界|Dolby[\s._\-]*Vision|\bDoVi\b|\bdvhe\b|\bdvh1\b|(?:^|[\s._\-\[\(【（])DV(?=$|[\s._\-\]\)】）]))"#,
        options: [.caseInsensitive]
    )
    private static let noiseTagsRegex = try! NSRegularExpression(
        pattern: #"(\[[^\]]*\]|【[^】]*】|\((?:19|20)\d{2}\)|\b(?:2160p|4K|1080p|720p|HDR10\+?|HDR|DoVi|DV|REMUX|BluRay|WEB-DL|WEBRip|x265|HEVC|H\.?265|x264|H\.?264|10bit|DDP5\.1|Atmos|AAC|FLAC)\b.*$)"#,
        options: [.caseInsensitive]
    )
    private static let htmlTagRegex = try! NSRegularExpression(pattern: #"<[^>]+>"#, options: [])
    private static let styleBlockRegex = try! NSRegularExpression(
        pattern: #"<style[^>]*>([\s\S]*?)</style>"#,
        options: [.caseInsensitive]
    )
    private static let cssClassRegex = try! NSRegularExpression(
        pattern: #"\.([a-zA-Z0-9_-]+)"#,
        options: []
    )
    private static let baikeInlineTagRegex = try! NSRegularExpression(
        pattern: #"<(span|em|b|strong|i)\b[^>]*\bclass\s*=\s*["']?([a-zA-Z0-9_-]+)["']?[^>]*>([\s\S]*?)</\1>"#,
        options: [.caseInsensitive]
    )
    private static let baikeDlPairRegex = try! NSRegularExpression(
        pattern: #"<dt\b[^>]*>([\s\S]*?)</dt>\s*<dd\b[^>]*>([\s\S]*?)</dd>"#,
        options: [.caseInsensitive]
    )
    private static let baikeEpTitleRegex = try! NSRegularExpression(
        pattern: #"第\s*(\d{1,4})\s*集\s*(.*)$"#,
        options: []
    )
    private static let baikeDocLinkRegex = try! NSRegularExpression(
        pattern: #"https?://baike\.so\.com/doc/\d+-\d+\.html"#,
        options: [.caseInsensitive]
    )
    private static let bingCardRegex = try! NSRegularExpression(
        pattern: #"m=(?:"|&quot;)(\{[^"]*?\})(?:"|&quot;)"#,
        options: []
    )
    private static let bingOipRegex = try! NSRegularExpression(
        pattern: #"OIP(?:-C)?\.([A-Za-z0-9_-]+)"#,
        options: []
    )
    private static let bingPortraitOipSuffixRegex = try! NSRegularExpression(
        pattern: #"Ha[KNLMP][A-Za-z0-9]$"#,
        options: []
    )
    private static let yearPrefixRegex = try! NSRegularExpression(pattern: #"^((?:19|20)\d{2})"#, options: [])
    private static let firstDigitsRegex = try! NSRegularExpression(pattern: #"\d+"#, options: [])

    // MARK: - Preserved Filename & Badge Scrapers

    public static func cleanSeriesTitle(_ rawTitle: String) -> String {
        var s = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return "" }
        s = noiseTagsRegex.stringByReplacingMatches(
            in: s,
            range: NSRange(s.startIndex..., in: s),
            withTemplate: ""
        )
        s = s
            .replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "_", with: " ")
        while s.contains("  ") { s = s.replacingOccurrences(of: "  ", with: " ") }
        return s.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "-–—")))
    }

    public static func isLikelyDolbyVision(
        url: String = "",
        episodeName: String = "",
        lineName: String = "",
        videoTitle: String = "",
        videoRemarks: String = ""
    ) -> Bool {
        let combined = "\(episodeName) \(lineName) \(videoTitle) \(videoRemarks) \(url)"
        return dolbyVisionRegex.firstMatch(in: combined, range: NSRange(combined.startIndex..., in: combined)) != nil
    }

    public static func parseEpisodeBadges(
        name: String,
        url: String = "",
        lineName: String = ""
    ) -> ParsedEpisodeBadges {
        let combined = "\(name) \(lineName) \(url)"
        let range = NSRange(name.startIndex..., in: name)

        var season: Int?
        var episode: Int?
        if let m = sxeRegex.firstMatch(in: name, range: range),
           let rs = Range(m.range(at: 1), in: name),
           let re = Range(m.range(at: 2), in: name)
        {
            season = Int(name[rs])
            episode = Int(name[re])
        } else if let m = zhEpRegex.firstMatch(in: name, range: range),
                  let re = Range(m.range(at: 1), in: name)
        {
            episode = Int(name[re])
        } else if let m = epOnlyRegex.firstMatch(in: name, range: range),
                  let re = Range(m.range(at: 1), in: name)
        {
            episode = Int(name[re])
        }

        let lower = combined.lowercased()
        let resolution: String
        if lower.contains("2160p") || lower.contains("4k") || lower.contains("uhd") { resolution = "4K" }
        else if lower.contains("1440p") || lower.contains("2k") { resolution = "2K" }
        else if lower.contains("1080p") || lower.contains("fhd") { resolution = "1080P" }
        else if lower.contains("720p") { resolution = "720P" }
        else { resolution = "" }

        let isDV = isLikelyDolbyVision(url: url, episodeName: name, lineName: lineName)
        let hdrBadge: String
        if isDV { hdrBadge = "Dolby Vision" }
        else if lower.contains("hdr10+") { hdrBadge = "HDR10+" }
        else if lower.contains("hdr10") || lower.contains("hdr") { hdrBadge = "HDR" }
        else { hdrBadge = "" }

        let audioBadge: String
        if lower.contains("atmos") || lower.contains("杜比全景声") { audioBadge = "Atmos" }
        else if lower.contains("truehd") { audioBadge = "TrueHD" }
        else if lower.contains("dts-hd") || lower.contains("dts:x") { audioBadge = "DTS-HD" }
        else if lower.contains("ddp") || lower.contains("eac3") { audioBadge = "DDP" }
        else { audioBadge = "" }

        let codecBadge: String
        if lower.contains("hevc") || lower.contains("h265") || lower.contains("h.265") || lower.contains("x265") { codecBadge = "HEVC" }
        else if lower.contains("av1") { codecBadge = "AV1" }
        else if lower.contains("h264") || lower.contains("h.264") || lower.contains("x264") { codecBadge = "AVC" }
        else { codecBadge = "" }

        return ParsedEpisodeBadges(
            seasonNumber: season,
            episodeNumber: episode,
            resolution: resolution,
            hdrBadge: hdrBadge,
            audioBadge: audioBadge,
            codecBadge: codecBadge,
            isDolbyVision: isDV
        )
    }

    public static func buildLineMetadata(for line: CmsLine) -> [EpisodeRichMetadata] {
        line.episodes.enumerated().map { idx, ep in
            let badges = parseEpisodeBadges(name: ep.name, url: ep.url, lineName: line.name)
            return EpisodeRichMetadata(
                seasonNumber: badges.seasonNumber ?? 1,
                episodeNumber: badges.episodeNumber ?? (idx + 1),
                title: ep.name
            )
        }
    }

    // MARK: - Live Series Candidate Search (Douban Rexxar + Bangumi + Bilibili PGC)

    public static func fetchSeriesCandidates(
        title: String,
        year: String = "",
        session: URLSession? = nil
    ) async -> [SeriesMetadataCandidate] {
        let cleaned = cleanSeriesTitle(title)
        guard !cleaned.isEmpty else { return [] }
        let activeSession = session ?? makeDefaultSession()
        let trimmedYear = year.trimmingCharacters(in: .whitespacesAndNewlines)

        async let douban = fetchDoubanCandidates(query: cleaned, session: activeSession)
        async let bilibili = fetchBilibiliCandidates(query: cleaned, session: activeSession)
        async let bangumi = fetchBangumiCandidates(query: cleaned, session: activeSession)

        let combined = await douban + bilibili + bangumi
        guard !trimmedYear.isEmpty else { return combined }
        return combined.sorted { lhs, rhs in
            let lhsMatch = lhs.year == trimmedYear ? 1 : 0
            let rhsMatch = rhs.year == trimmedYear ? 1 : 0
            if lhsMatch != rhsMatch { return lhsMatch > rhsMatch }
            return (lhs.rating ?? 0) > (rhs.rating ?? 0)
        }
    }

    // MARK: - Live Episode Metadata Aggregation (360 Baike + Bangumi + Bilibili PGC)

    public static func fetchEpisodeMetadata(
        title: String,
        season: Int = 1,
        year: String = "",
        session: URLSession? = nil
    ) async -> [EpisodeRichMetadata] {
        let cleaned = cleanSeriesTitle(title)
        guard !cleaned.isEmpty else { return [] }
        let safeSeason = max(1, season)
        let activeSession = session ?? makeDefaultSession()

        async let baikeTask = fetch360BaikeEpisodes(title: cleaned, season: safeSeason, session: activeSession)
        async let bangumiTask = fetchBangumiEpisodes(title: cleaned, season: safeSeason, year: year, session: activeSession)
        async let bilibiliTask = fetchBilibiliPgcEpisodes(title: cleaned, season: safeSeason, year: year, session: activeSession)

        let (baikeEps, bangumiEps, bilibiliEps) = await (baikeTask, bangumiTask, bilibiliTask)

        var mergedByEp: [Int: EpisodeRichMetadata] = [:]
        func upsert(_ incoming: EpisodeRichMetadata) {
            guard incoming.episodeNumber > 0 else { return }
            if let existing = mergedByEp[incoming.episodeNumber] {
                let title = !existing.title.isEmpty && existing.title != "第 \(incoming.episodeNumber) 集"
                    ? existing.title
                    : (!incoming.title.isEmpty ? incoming.title : existing.title)
                let overview = existing.overview.count >= incoming.overview.count ? existing.overview : incoming.overview
                let stillUrl = !existing.stillUrl.isEmpty ? existing.stillUrl : incoming.stillUrl
                let airDate = !existing.airDate.isEmpty ? existing.airDate : incoming.airDate
                let runtime = existing.runtimeMinutes ?? incoming.runtimeMinutes
                let vote = existing.voteAverage ?? incoming.voteAverage
                mergedByEp[incoming.episodeNumber] = EpisodeRichMetadata(
                    seasonNumber: safeSeason,
                    episodeNumber: incoming.episodeNumber,
                    title: title,
                    overview: overview,
                    stillUrl: stillUrl,
                    airDate: airDate,
                    runtimeMinutes: runtime,
                    voteAverage: vote
                )
            } else {
                mergedByEp[incoming.episodeNumber] = incoming
            }
        }

        for ep in baikeEps { upsert(ep) }
        for ep in bilibiliEps { upsert(ep) }
        for ep in bangumiEps { upsert(ep) }

        return mergedByEp.values.sorted { $0.episodeNumber < $1.episodeNumber }
    }

    // MARK: - Live 16:9 Widescreen Episode Stills (Bing Images Async)

    public static func fetchEpisodeStills(
        title: String,
        count: Int = 20,
        year: String = "",
        session: URLSession? = nil
    ) async -> [String] {
        let cleaned = cleanSeriesTitle(title)
        let targetCount = max(1, min(count, 35))
        guard !cleaned.isEmpty else { return [] }
        let activeSession = session ?? makeDefaultSession()

        let yearHint = year.trimmingCharacters(in: .whitespacesAndNewlines)
        let queryText = yearHint.isEmpty
            ? "\"\(cleaned)\" 电视剧 剧照 画面 -动态漫画 -模板 -素材"
            : "\"\(cleaned)\" \(yearHint) 电视剧 剧照 画面 -动态漫画 -模板 -素材"
        let encoded = encodeQueryParam(queryText)
        guard let url = URL(string: "https://cn.bing.com/images/async?q=\(encoded)&first=1&count=35&qft=+filterui:aspect-wide") else {
            return []
        }

        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 6)
        req.httpMethod = "GET"
        req.setValue(desktopUserAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("https://cn.bing.com/", forHTTPHeaderField: "Referer")
        req.setValue("text/html,application/xhtml+xml,*/*;q=0.8", forHTTPHeaderField: "Accept")

        guard let (data, resp) = try? await activeSession.marcoData(for: req),
              let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode)
        else {
            return []
        }
        let html = String(decoding: data, as: UTF8.self)
        return parseBingWidescreenStills(html: html, count: targetCount)
    }

    // MARK: - Pure Static Parsers (Deterministic & Testable)

    /// De-obfuscates 360 Baike anti-scrape `<style>` hidden CSS classes (`display:none`,
    /// `font-size:0`, `height:0`, `width:0`, `visibility:hidden`, `opacity:0`) before extracting
    /// structured `<dt>第N集</dt><dd>...</dd>` per-episode plot summaries.
    public static func parse360BaikeEpisodes(html: String, season: Int = 1) -> [EpisodeRichMetadata] {
        guard !html.isEmpty else { return [] }
        var hiddenClasses = Set<String>()
        let fullRange = NSRange(html.startIndex..., in: html)

        for styleMatch in styleBlockRegex.matches(in: html, range: fullRange) {
            guard let cssRange = Range(styleMatch.range(at: 1), in: html) else { continue }
            let css = String(html[cssRange])
            for rawRule in css.components(separatedBy: "}") {
                let compact = rawRule.lowercased().replacingOccurrences(of: " ", with: "")
                let hidesText = compact.contains("display:none")
                    || compact.contains("font-size:0")
                    || compact.contains("height:0")
                    || compact.contains("width:0")
                    || compact.contains("visibility:hidden")
                    || compact.contains("opacity:0")
                guard hidesText else { continue }
                let selectorPart = rawRule.components(separatedBy: "{").first ?? ""
                for clsMatch in cssClassRegex.matches(in: selectorPart, range: NSRange(selectorPart.startIndex..., in: selectorPart)) {
                    if let r = Range(clsMatch.range(at: 1), in: selectorPart) {
                        hiddenClasses.insert(String(selectorPart[r]))
                    }
                }
            }
        }

        func cleanFragment(_ fragment: String) -> String {
            var current = fragment
            for _ in 0..<6 {
                let ns = current as NSString
                let matches = baikeInlineTagRegex.matches(in: current, range: NSRange(location: 0, length: ns.length))
                if matches.isEmpty { break }
                let mutable = NSMutableString(string: current)
                var changed = false
                for m in matches.reversed() {
                    let clsName = ns.substring(with: m.range(at: 2))
                    let inner = ns.substring(with: m.range(at: 3))
                    let replacement = hiddenClasses.contains(clsName) ? "" : inner
                    mutable.replaceCharacters(in: m.range, with: replacement)
                    changed = true
                }
                let next = mutable as String
                if !changed || next == current { break }
                current = next
            }
            var plain = htmlTagRegex.stringByReplacingMatches(
                in: current,
                range: NSRange(current.startIndex..., in: current),
                withTemplate: ""
            )
            plain = decodeHtmlEntities(plain)
            while plain.contains("  ") { plain = plain.replacingOccurrences(of: "  ", with: " ") }
            return plain.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let plotRegion: String
        if let tvplotRange = html.range(of: "id=tvplot", options: [.caseInsensitive])
            ?? html.range(of: "id=\"tvplot\"", options: [.caseInsensitive])
            ?? html.range(of: "id='tvplot'", options: [.caseInsensitive])
        {
            plotRegion = String(html[tvplotRange.lowerBound...])
        } else {
            plotRegion = html
        }

        var out: [EpisodeRichMetadata] = []
        var seenEps = Set<Int>()
        let regionRange = NSRange(plotRegion.startIndex..., in: plotRegion)
        for pair in baikeDlPairRegex.matches(in: plotRegion, range: regionRange) {
            guard let dtRange = Range(pair.range(at: 1), in: plotRegion),
                  let ddRange = Range(pair.range(at: 2), in: plotRegion)
            else { continue }
            let dtText = cleanFragment(String(plotRegion[dtRange]))
            let ddText = cleanFragment(String(plotRegion[ddRange]))
            guard ddText.count >= 8 else { continue }
            guard let epMatch = baikeEpTitleRegex.firstMatch(in: dtText, range: NSRange(dtText.startIndex..., in: dtText)),
                  let numRange = Range(epMatch.range(at: 1), in: dtText),
                  let epNum = Int(dtText[numRange]),
                  epNum > 0,
                  seenEps.insert(epNum).inserted
            else { continue }

            var epSubTitle = ""
            if let subRange = Range(epMatch.range(at: 2), in: dtText) {
                epSubTitle = String(dtText[subRange])
                    .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "：:·-")))
            }
            out.append(
                EpisodeRichMetadata(
                    seasonNumber: max(1, season),
                    episodeNumber: epNum,
                    title: epSubTitle.isEmpty ? "第 \(epNum) 集" : epSubTitle,
                    overview: ddText
                )
            )
        }
        return out.sorted { $0.episodeNumber < $1.episodeNumber }
    }

    public static func parseDoubanCandidates(data: Data) -> [SeriesMetadataCandidate] {
        guard let decoded = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
        let subjectsMap = decoded["subjects"] as? [String: Any]
        let rawItems = (subjectsMap?["items"] ?? decoded["items"]) as? [[String: Any]] ?? []
        var out: [SeriesMetadataCandidate] = []
        for entry in rawItems {
            let target = (entry["target"] as? [String: Any]) ?? entry
            let type = (stringVal(entry["target_type"]).isEmpty ? stringVal(target["type"]) : stringVal(entry["target_type"])).lowercased()
            guard type == "movie" || type == "tv" else { continue }
            let sid = stringVal(target["id"])
            let title = stringVal(target["title"])
            guard !sid.isEmpty, !title.isEmpty else { continue }
            let year = stringVal(target["year"])
            let cardSub = stringVal(target["card_subtitle"])
            let isMc = isMotionComic(title: title, context: cardSub)
            let isAnime = cardSub.contains("动画") || cardSub.contains("动漫")
            let badge = isMc ? "动态漫画" : (isAnime ? "动漫" : (type == "tv" ? "剧集" : "电影"))
            let ratingVal: Double? = {
                if let rMap = target["rating"] as? [String: Any], let n = rMap["value"] as? NSNumber {
                    return n.doubleValue >= 2.0 && n.doubleValue <= 10.0 ? n.doubleValue : nil
                }
                if let d = Double(stringVal(target["rating"])), d >= 2.0 && d <= 10.0 {
                    return d
                }
                return nil
            }()
            let pic = target["pic"] as? [String: Any]
            let rawCover = !stringVal(target["cover_url"]).isEmpty
                ? stringVal(target["cover_url"])
                : (!stringVal(pic?["large"]).isEmpty ? stringVal(pic?["large"]) : stringVal(pic?["normal"]))
            out.append(
                SeriesMetadataCandidate(
                    source: "douban",
                    subjectId: sid,
                    title: title,
                    subtitle: cardSub,
                    year: year,
                    isTv: type == "tv",
                    isMotionComic: isMc,
                    mediaBadge: badge,
                    posterUrl: upgradeCoverUrl(rawCover),
                    rating: ratingVal
                )
            )
        }
        return out
    }

    public static func parseBangumiCandidates(data: Data) -> [SeriesMetadataCandidate] {
        guard let decoded = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let list = decoded["list"] as? [[String: Any]]
        else { return [] }
        var out: [SeriesMetadataCandidate] = []
        for item in list.prefix(10) {
            let t = (item["type"] as? NSNumber)?.intValue ?? 0
            guard t == 2 || t == 6 else { continue }
            let sid = stringVal(item["id"])
            let nameCn = stringVal(item["name_cn"])
            let name = stringVal(item["name"])
            let title = !nameCn.isEmpty ? nameCn : name
            guard !sid.isEmpty, !title.isEmpty else { continue }
            let airDate = stringVal(item["air_date"])
            let year: String = {
                if let m = yearPrefixRegex.firstMatch(in: airDate, range: NSRange(airDate.startIndex..., in: airDate)),
                   let r = Range(m.range(at: 1), in: airDate)
                {
                    return String(airDate[r])
                }
                return ""
            }()
            let summary = stringVal(item["summary"])
            let isMc = isMotionComic(title: "\(nameCn) \(name)", context: summary)
            let images = item["images"] as? [String: Any]
            let cover = !stringVal(images?["large"]).isEmpty ? stringVal(images?["large"]) : stringVal(images?["common"])
            let eps = ((item["eps_count"] ?? item["eps"]) as? NSNumber)?.intValue
            let ratingScore = ((item["rating"] as? [String: Any])?["score"] as? NSNumber)?.doubleValue
            var subParts: [String] = []
            if !name.isEmpty && name != title { subParts.append(name) }
            if let eps = eps, eps > 0 { subParts.append("共 \(eps) 集") }
            subParts.append("Bangumi")
            out.append(
                SeriesMetadataCandidate(
                    source: "bangumi",
                    subjectId: sid,
                    title: title,
                    subtitle: subParts.joined(separator: " · "),
                    year: year,
                    isTv: true,
                    isMotionComic: isMc,
                    mediaBadge: isMc ? "动态漫画" : (t == 2 ? "动漫" : "剧集"),
                    posterUrl: upgradeCoverUrl(cover),
                    synopsis: summary,
                    rating: (ratingScore != nil && ratingScore! >= 2.0 && ratingScore! <= 10.0) ? ratingScore : nil,
                    episodeCount: eps
                )
            )
        }
        return out
    }

    public static func parseBilibiliCandidates(data: Data, searchType: String) -> [SeriesMetadataCandidate] {
        guard let decoded = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let dataMap = decoded["data"] as? [String: Any],
              let list = dataMap["result"] as? [[String: Any]]
        else { return [] }
        var out: [SeriesMetadataCandidate] = []
        for item in list.prefix(6) {
            let sid = !stringVal(item["season_id"]).isEmpty ? stringVal(item["season_id"]) : stringVal(item["media_id"])
            let rawTitle = stringVal(item["title"])
            let title = htmlTagRegex.stringByReplacingMatches(
                in: rawTitle,
                range: NSRange(rawTitle.startIndex..., in: rawTitle),
                withTemplate: ""
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sid.isEmpty, !title.isEmpty else { continue }
            let desc = stringVal(item["desc"])
            let styles = stringVal(item["styles"])
            let isMc = isMotionComic(title: title, context: "\(styles) \(desc)")
            var year = ""
            if let pubtime = (item["pubtime"] as? NSNumber)?.doubleValue, pubtime > 0 {
                let cal = Calendar(identifier: .gregorian)
                year = "\(cal.component(.year, from: Date(timeIntervalSince1970: pubtime)))"
            }
            let cover = upgradeCoverUrl(stringVal(item["cover"]))
            let backdrop = upgradeCoverUrl(
                !stringVal(item["horizontal_cover_16_9"]).isEmpty
                    ? stringVal(item["horizontal_cover_16_9"])
                    : stringVal(item["horizontal_cover_16_10"])
            )
            let eps = item["eps"] as? [[String: Any]]
            let subParts = [styles, "B站官方"].filter { !$0.isEmpty }
            out.append(
                SeriesMetadataCandidate(
                    source: "bilibili",
                    subjectId: sid,
                    title: title,
                    subtitle: subParts.joined(separator: " · "),
                    year: year,
                    isTv: searchType == "media_bangumi" || (eps?.count ?? 0) > 1,
                    isMotionComic: isMc,
                    mediaBadge: isMc ? "动态漫画" : (searchType == "media_bangumi" ? "动漫" : "影视"),
                    posterUrl: cover,
                    backdropUrl: backdrop,
                    synopsis: desc,
                    episodeCount: eps?.count
                )
            )
        }
        return out
    }

    public static func parseBangumiEpisodes(data: Data, season: Int = 1) -> [EpisodeRichMetadata] {
        guard let decoded = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let eps = decoded["data"] as? [[String: Any]]
        else { return [] }
        var out: [EpisodeRichMetadata] = []
        for (idx, ep) in eps.enumerated() {
            let epNum: Int
            if let e = (ep["ep"] as? NSNumber)?.intValue, e > 0 {
                epNum = e
            } else if let s = (ep["sort"] as? NSNumber)?.intValue, s > 0 {
                epNum = s
            } else {
                epNum = idx + 1
            }
            let nameCn = stringVal(ep["name_cn"])
            let name = stringVal(ep["name"])
            let desc = stringVal(ep["desc"])
            let airDate = stringVal(ep["airdate"])
            let durationMin = parseRuntimeMinutes(stringVal(ep["duration"]))
            out.append(
                EpisodeRichMetadata(
                    seasonNumber: max(1, season),
                    episodeNumber: epNum,
                    title: !nameCn.isEmpty ? nameCn : (!name.isEmpty ? name : "第 \(epNum) 集"),
                    overview: desc.count >= 8 ? desc : "",
                    airDate: airDate,
                    runtimeMinutes: durationMin
                )
            )
        }
        return out.sorted { $0.episodeNumber < $1.episodeNumber }
    }

    public static func parseBilibiliPgcEpisodes(data: Data, title: String, season: Int = 1) -> [EpisodeRichMetadata] {
        guard let decoded = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let dataMap = decoded["data"] as? [String: Any],
              let list = dataMap["result"] as? [[String: Any]]
        else { return [] }
        let targetKey = CuratedDiscoveryService.normalizeMatchKey(title)
        let matched = list.first { item in
            let raw = htmlTagRegex.stringByReplacingMatches(
                in: stringVal(item["title"]),
                range: NSRange(location: 0, length: (stringVal(item["title"]) as NSString).length),
                withTemplate: ""
            )
            let candKey = CuratedDiscoveryService.normalizeMatchKey(raw)
            return !candKey.isEmpty && (candKey == targetKey || candKey.contains(targetKey) || targetKey.contains(candKey))
        } ?? list.first

        guard let eps = matched?["eps"] as? [[String: Any]] else { return [] }
        var out: [EpisodeRichMetadata] = []
        for (idx, ep) in eps.enumerated() {
            let rawIdx = !stringVal(ep["title"]).isEmpty ? stringVal(ep["title"]) : stringVal(ep["index_title"])
            let epNum: Int = {
                if let m = firstDigitsRegex.firstMatch(in: rawIdx, range: NSRange(rawIdx.startIndex..., in: rawIdx)),
                   let r = Range(m.range, in: rawIdx),
                   let parsed = Int(rawIdx[r]), parsed > 0
                {
                    return parsed
                }
                return idx + 1
            }()
            let rawLong = stringVal(ep["long_title"])
            let longTitle = htmlTagRegex.stringByReplacingMatches(
                in: rawLong,
                range: NSRange(rawLong.startIndex..., in: rawLong),
                withTemplate: ""
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            let cover = upgradeCoverUrl(stringVal(ep["cover"]))
            out.append(
                EpisodeRichMetadata(
                    seasonNumber: max(1, season),
                    episodeNumber: epNum,
                    title: longTitle.isEmpty ? "第 \(epNum) 集" : longTitle,
                    stillUrl: cover
                )
            )
        }
        return out.sorted { $0.episodeNumber < $1.episodeNumber }
    }

    public static func parseBingWidescreenStills(html: String, count: Int = 20) -> [String] {
        guard !html.isEmpty, count > 0 else { return [] }
        var stills: [String] = []
        var seenCoreIds = Set<String>()
        var seenUrls = Set<String>()

        let range = NSRange(html.startIndex..., in: html)
        for cardMatch in bingCardRegex.matches(in: html, range: range) {
            if stills.count >= count { break }
            guard let attrRange = Range(cardMatch.range(at: 1), in: html) else { continue }
            let cardAttr = String(html[attrRange])
            guard let oipMatch = bingOipRegex.firstMatch(in: cardAttr, range: NSRange(cardAttr.startIndex..., in: cardAttr)),
                  let fullRange = Range(oipMatch.range(at: 0), in: cardAttr),
                  let coreRange = Range(oipMatch.range(at: 1), in: cardAttr)
            else { continue }

            let fullId = String(cardAttr[fullRange])
            let coreId = String(cardAttr[coreRange])
            if bingPortraitOipSuffixRegex.firstMatch(in: coreId, range: NSRange(coreId.startIndex..., in: coreId)) != nil {
                continue
            }
            guard seenCoreIds.insert(coreId).inserted else { continue }
            let stillUrl = "https://tse1-mm.cn.bing.net/th/id/\(fullId)?w=640&h=360&c=7&r=0&o=5&pid=1.7"
            if seenUrls.insert(stillUrl).inserted {
                stills.append(stillUrl)
            }
        }
        return stills
    }

    // MARK: - Private Network Fetchers

    private static func makeDefaultSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 6
        cfg.timeoutIntervalForResource = 12
        cfg.httpShouldSetCookies = false
        return URLSession(configuration: cfg)
    }

    private static func fetchDoubanCandidates(query: String, session: URLSession) async -> [SeriesMetadataCandidate] {
        let q = encodeQueryParam(query)
        guard let url = URL(string: "https://m.douban.com/rexxar/api/v2/search/weixin?q=\(q)&count=12") else {
            return []
        }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 6)
        req.httpMethod = "GET"
        req.setValue(mobileUserAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("https://m.douban.com/", forHTTPHeaderField: "Referer")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, resp) = try? await session.marcoData(for: req),
              let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode)
        else { return [] }
        return parseDoubanCandidates(data: data)
    }

    private static func fetchBangumiCandidates(query: String, session: URLSession) async -> [SeriesMetadataCandidate] {
        let encoded = encodePathSegment(query)
        guard let url = URL(string: "https://api.bgm.tv/search/subject/\(encoded)?responseGroup=large") else {
            return []
        }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 6)
        req.httpMethod = "GET"
        req.setValue(desktopUserAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, resp) = try? await session.marcoData(for: req),
              let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode)
        else { return [] }
        return parseBangumiCandidates(data: data)
    }

    private static func fetchBilibiliCandidates(query: String, session: URLSession) async -> [SeriesMetadataCandidate] {
        var out: [SeriesMetadataCandidate] = []
        let q = encodeQueryParam(query)
        for stype in ["media_bangumi", "media_ft"] {
            guard let url = URL(string: "https://api.bilibili.com/x/web-interface/search/type?search_type=\(stype)&keyword=\(q)") else {
                continue
            }
            var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 6)
            req.httpMethod = "GET"
            req.setValue(desktopUserAgent, forHTTPHeaderField: "User-Agent")
            req.setValue("https://search.bilibili.com/", forHTTPHeaderField: "Referer")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            guard let (data, resp) = try? await session.marcoData(for: req),
                  let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode)
            else { continue }
            out.append(contentsOf: parseBilibiliCandidates(data: data, searchType: stype))
        }
        return out
    }

    private static func fetch360BaikeEpisodes(title: String, season: Int, session: URLSession) async -> [EpisodeRichMetadata] {
        for sq in ["\(title) 分集剧情", title] {
            guard let searchUrl = URL(string: "https://baike.so.com/search/?q=\(encodeQueryParam(sq))") else { continue }
            var req = URLRequest(url: searchUrl, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
            req.httpMethod = "GET"
            req.setValue(desktopUserAgent, forHTTPHeaderField: "User-Agent")
            req.setValue("text/html,*/*;q=0.8", forHTTPHeaderField: "Accept")
            guard let (data, resp) = try? await session.marcoData(for: req),
                  let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode)
            else { continue }
            let searchHtml = String(decoding: data, as: UTF8.self)
            var links: [String] = []
            var seen = Set<String>()
            for m in baikeDocLinkRegex.matches(in: searchHtml, range: NSRange(searchHtml.startIndex..., in: searchHtml)) {
                if let r = Range(m.range, in: searchHtml) {
                    var link = String(searchHtml[r])
                    if link.hasPrefix("http://") { link = "https://" + link.dropFirst(7) }
                    if seen.insert(link).inserted { links.append(link) }
                    if links.count >= 2 { break }
                }
            }
            for docLink in links {
                guard let docUrl = URL(string: docLink) else { continue }
                var docReq = URLRequest(url: docUrl, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
                docReq.httpMethod = "GET"
                docReq.setValue(desktopUserAgent, forHTTPHeaderField: "User-Agent")
                docReq.setValue("text/html,*/*;q=0.8", forHTTPHeaderField: "Accept")
                guard let (docData, docResp) = try? await session.marcoData(for: docReq),
                      let docHttp = docResp as? HTTPURLResponse, (200...299).contains(docHttp.statusCode)
                else { continue }
                let docHtml = String(decoding: docData, as: UTF8.self)
                let parsed = parse360BaikeEpisodes(html: docHtml, season: season)
                if !parsed.isEmpty { return parsed }
            }
        }
        return []
    }

    private static func fetchBangumiEpisodes(title: String, season: Int, year: String, session: URLSession) async -> [EpisodeRichMetadata] {
        let candidates = await fetchBangumiCandidates(query: title, session: session)
        guard let best = candidates.first(where: { year.isEmpty || $0.year == year }) ?? candidates.first,
              let epUrl = URL(string: "https://api.bgm.tv/v0/episodes?subject_id=\(best.subjectId)&limit=100&offset=0")
        else { return [] }
        var req = URLRequest(url: epUrl, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
        req.httpMethod = "GET"
        req.setValue(desktopUserAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, resp) = try? await session.marcoData(for: req),
              let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode)
        else { return [] }
        return parseBangumiEpisodes(data: data, season: season)
    }

    private static func fetchBilibiliPgcEpisodes(title: String, season: Int, year: String, session: URLSession) async -> [EpisodeRichMetadata] {
        let q = encodeQueryParam(title)
        for stype in ["media_bangumi", "media_ft"] {
            guard let url = URL(string: "https://api.bilibili.com/x/web-interface/search/type?search_type=\(stype)&keyword=\(q)") else {
                continue
            }
            var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
            req.httpMethod = "GET"
            req.setValue(desktopUserAgent, forHTTPHeaderField: "User-Agent")
            req.setValue("https://search.bilibili.com/", forHTTPHeaderField: "Referer")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            guard let (data, resp) = try? await session.marcoData(for: req),
                  let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode)
            else { continue }
            let eps = parseBilibiliPgcEpisodes(data: data, title: title, season: season)
            if !eps.isEmpty { return eps }
        }
        return []
    }

    // MARK: - Formatting Helpers

    private static func isMotionComic(title: String, context: String) -> Bool {
        let combined = "\(title) \(context)"
        return combined.contains("动态漫画") || combined.contains("动态漫") || combined.contains("有声漫画")
    }

    private static func upgradeCoverUrl(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return "" }
        if s.hasPrefix("//") { s = "https:\(s)" }
        else if s.hasPrefix("http://") { s = "https://" + s.dropFirst(7) }
        if s.contains("/s_ratio_poster/") {
            s = s.replacingOccurrences(of: "/s_ratio_poster/", with: "/m_ratio_poster/")
        }
        return s
    }

    private static func parseRuntimeMinutes(_ raw: String) -> Int? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.components(separatedBy: ":")
        if parts.count == 3, let h = Int(parts[0]), let m = Int(parts[1]) {
            return h * 60 + m
        }
        if parts.count == 2, let m = Int(parts[0]) {
            return m
        }
        if let m = firstDigitsRegex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
           let r = Range(m.range, in: trimmed),
           let val = Int(trimmed[r]), val > 0
        {
            return val
        }
        return nil
    }

    private static func decodeHtmlEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func encodeQueryParam(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#/")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func encodePathSegment(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#&+")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func stringVal(_ raw: Any?) -> String {
        guard let raw = raw, !(raw is NSNull) else { return "" }
        if let s = raw as? String { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let n = raw as? NSNumber { return n.stringValue }
        return ""
    }
}
