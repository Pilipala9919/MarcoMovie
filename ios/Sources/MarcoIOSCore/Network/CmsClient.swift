// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only

import Foundation

public struct SiteHomePayload: Sendable {
    public var categories: [CmsCategory]
    public var listing: CmsListing

    public init(categories: [CmsCategory], listing: CmsListing) {
        self.categories = categories
        self.listing = listing
    }
}

/// Unified async HTTP & script-runtime CMS client for iOS 14+ and macOS 13+.
/// Dispatches standard MacCMS JSON/XML/Type-4/M3U_VOD, QuickJS, DRPY2/Guard,
/// CspRuleEngines, WoggNetdiskSource, CPython (`PythonSourceHost`), CatPaw (`CatpawSourceHost`),
/// BYO Spider Gateway (`SpiderGatewayClient`), External Media Libraries, and all 5 Netdisks.
public final class CmsClient: @unchecked Sendable {
    public static let defaultSafariUserAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
    public static let fallbackOkHttpUserAgent = "okhttp/4.12.0"

    private let session: URLSession
    private let timeoutSeconds: TimeInterval
    private let jsHostLock = NSLock()
    private var jsHostsBySiteKey: [String: JsSourceHost] = [:]
    private var drpyHostsBySiteKey: [String: DrpySourceHost] = [:]
    private var pythonSourceBySiteKey: [String: String] = [:]
    private let netdiskResolver: NetdiskShareResolver
    private let pythonHost: PythonSourceHost
    private let catpawHost: CatpawSourceHost
    private let gatewayClient: SpiderGatewayClient

    public init(
        timeoutSeconds: TimeInterval = 15,
        session: URLSession? = nil,
        pythonHost: PythonSourceHost = .shared,
        catpawHost: CatpawSourceHost = .shared,
        gatewayClient: SpiderGatewayClient? = nil
    ) {
        self.timeoutSeconds = timeoutSeconds
        if let session = session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = timeoutSeconds
            config.timeoutIntervalForResource = timeoutSeconds * 2
            config.httpShouldSetCookies = false
            self.session = URLSession(configuration: config)
        }
        self.netdiskResolver = NetdiskShareResolver(session: self.session)
        self.pythonHost = pythonHost
        self.catpawHost = catpawHost
        self.gatewayClient = gatewayClient ?? SpiderGatewayClient(session: self.session)
    }

    // MARK: - Generic Fetch Helpers

    public func fetchRawData(
        from rawUrl: String,
        headers: [String: String] = [:],
        method: String = "GET",
        body: Data? = nil,
        maxBytes: Int = 16 * 1024 * 1024
    ) async throws -> (data: Data, response: HTTPURLResponse?) {
        let normalized = CmsParser.normalizeUrl(rawUrl)
        guard let url = URL(string: normalized),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else {
            throw MarcoError.invalidFormat("无效的 HTTP(S) 地址：\(rawUrl)")
        }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeoutSeconds)
        request.httpMethod = method
        request.httpShouldHandleCookies = false
        request.setValue(Self.defaultSafariUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        request.httpBody = body

        let (data, response) = try await session.marcoData(for: request)
        let http = response as? HTTPURLResponse
        if let status = http?.statusCode, status >= 400 {
            throw MarcoError.networkFailure("服务器返回 HTTP \(status)")
        }
        if data.count > maxBytes {
            throw MarcoError.invalidFormat("响应体积超过 \(maxBytes / (1024 * 1024)) MB 上限")
        }
        return (data, http)
    }

    public func fetchText(
        from rawUrl: String,
        headers: [String: String] = [:],
        maxBytes: Int = 16 * 1024 * 1024
    ) async throws -> String {
        let (data, _) = try await fetchRawData(from: rawUrl, headers: headers, maxBytes: maxBytes)
        return try ConfigDecoder.decodeTextDocument(data)
    }

    public func fetchConfig(
        from rawUrl: String,
        defaultGroup: String = "默认分组",
        isPrivate: Bool = false,
        subscriptionId: String = "",
        defaultName: String = ""
    ) async throws -> (rawContent: String, config: CmsConfig) {
        let normalized = CmsParser.extractAndNormalizeUrl(rawUrl)
        do {
            let (data, _) = try await fetchRawData(from: normalized, headers: ["User-Agent": Self.fallbackOkHttpUserAgent])
            let decoded = try ConfigDecoder.decodeConfigDocument(data)
            let config = try CmsParser.parseConfig(
                decoded,
                origin: normalized,
                defaultGroup: defaultGroup,
                isPrivate: isPrivate,
                subscriptionId: subscriptionId,
                defaultName: defaultName
            )
            return (decoded, config)
        } catch {
            let (data, _) = try await fetchRawData(from: normalized, headers: ["User-Agent": Self.defaultSafariUserAgent])
            let decoded = try ConfigDecoder.decodeConfigDocument(data)
            let config = try CmsParser.parseConfig(
                decoded,
                origin: normalized,
                defaultGroup: defaultGroup,
                isPrivate: isPrivate,
                subscriptionId: subscriptionId,
                defaultName: defaultName
            )
            return (decoded, config)
        }
    }

    public func fetchDepotConfig(_ depot: CmsDepot) async throws -> (rawContent: String, config: CmsConfig) {
        try await fetchConfig(
            from: depot.url,
            isPrivate: depot.isPrivate,
            subscriptionId: depot.subscriptionId,
            defaultName: depot.name
        )
    }

    // MARK: - CMS Browse / Detail / Search

    public func fetchHome(
        site: CmsSite,
        storage: IOSStorageManager? = nil
    ) async throws -> SiteHomePayload {
        if site.isExternalMediaLibrary, let storage = storage {
            return try await ExternalMediaLibraryDispatcher.home(site: site, storage: storage, session: session)
        }
        if site.isM3uVodApi {
            let raw = try await loadM3uVodPayload(site: site)
            let (cats, listing) = try CmsParser.parseM3uVodHome(raw, origin: m3uOrigin(for: site))
            return SiteHomePayload(categories: cats, listing: listing)
        }
        if site.isCatPaw {
            let raw = try await catpawHost.callEndpoint(
                path: "/home",
                body: ["site": sitePayloadDict(site)],
                storage: storage
            )
            return SiteHomePayload(categories: CmsParser.parseCategories(raw), listing: try CmsParser.parseListing(raw))
        }
        if site.isPythonSource {
            let src = try await loadPythonSource(for: site)
            return try await pythonHost.homeContent(site: site, scriptSource: src)
        }
        if site.isCspRuleEngine {
            return try await CspRuleEngines.homeContent(site: site, fetchText: makeTextFetcher())
        }
        if site.isWoggNetdiskSource {
            return try await WoggNetdiskSource.homeContent(site: site, fetchText: makeTextFetcher())
        }
        if site.hasQuickJsAdapter {
            switch try await getOrCreateScriptHost(for: site) {
            case .js(let host): return try await host.homeContent(filter: true)
            case .drpy(let host): return try await host.homeContent(filter: true)
            }
        }
        if !site.supported, let storage = storage, storage.spiderGatewayConfig().isActive {
            let raw = try await gatewayClient.invoke(
                config: storage.spiderGatewayConfig(),
                site: site,
                action: "home",
                params: ["filter": true]
            )
            return SiteHomePayload(categories: CmsParser.parseCategories(raw), listing: try CmsParser.parseListing(raw))
        }

        guard site.supported else {
            throw MarcoError.unsupportedSite(site.unsupportedReason)
        }

        if site.type == 4 {
            let body = try await fetchText(from: site.api, headers: site.headers)
            var categories = CmsParser.parseCategories(body)
            var listing = try CmsParser.parseListing(body)
            if listing.videos.isEmpty, let firstCat = categories.first {
                let firstListing = try await fetchCategory(site: site, categoryId: firstCat.id, page: 1, storage: storage)
                listing = firstListing
            }
            if categories.isEmpty && !listing.videos.isEmpty {
                categories = [CmsCategory(id: "all", name: "精选")]
            }
            return SiteHomePayload(categories: categories, listing: listing)
        }

        let catUrl = appendQuery(site.api, params: ["ac": "list"])
        let catBody = try await fetchText(from: catUrl, headers: site.headers)
        var categories = CmsParser.parseCategories(catBody)

        let detailUrl = appendQuery(site.api, params: ["ac": "detail", "pg": "1"])
        var listing: CmsListing
        if let detailBody = try? await fetchText(from: detailUrl, headers: site.headers),
           let parsed = try? CmsParser.parseListing(detailBody),
           !parsed.videos.isEmpty
        {
            listing = parsed
        } else {
            listing = try CmsParser.parseListing(catBody)
        }

        if categories.isEmpty && !listing.videos.isEmpty {
            categories = [CmsCategory(id: "all", name: "精选")]
        }
        return SiteHomePayload(categories: categories, listing: listing)
    }

    public func fetchCategory(
        site: CmsSite,
        categoryId: String,
        page: Int = 1,
        filters: [String: String] = [:],
        storage: IOSStorageManager? = nil
    ) async throws -> CmsListing {
        if site.isExternalMediaLibrary, let storage = storage {
            return try await ExternalMediaLibraryDispatcher.list(
                site: site,
                categoryId: categoryId,
                query: "",
                page: page,
                storage: storage,
                session: session
            )
        }
        if site.isM3uVodApi {
            let raw = try await loadM3uVodPayload(site: site)
            let (_, allListing) = try CmsParser.parseM3uVodHome(raw, origin: m3uOrigin(for: site))
            if categoryId.isEmpty || categoryId == "all" { return allListing }
            let filtered = allListing.videos.filter { $0.tag == categoryId || $0.remarks == categoryId }
            return CmsListing(page: 1, pageCount: 1, videos: filtered)
        }
        if site.isCatPaw {
            let raw = try await catpawHost.callEndpoint(
                path: "/category",
                body: ["site": sitePayloadDict(site), "tid": categoryId, "pg": max(1, page), "ext": filters],
                storage: storage
            )
            return try CmsParser.parseListing(raw)
        }
        if site.isPythonSource {
            let src = try await loadPythonSource(for: site)
            return try await pythonHost.categoryContent(site: site, scriptSource: src, tid: categoryId, page: page, extend: filters)
        }
        if site.isCspRuleEngine {
            return try await CspRuleEngines.categoryContent(site: site, categoryId: categoryId, page: page, fetchText: makeTextFetcher())
        }
        if site.isWoggNetdiskSource {
            return try await WoggNetdiskSource.categoryContent(site: site, categoryId: categoryId, page: page, fetchText: makeTextFetcher())
        }
        if site.hasQuickJsAdapter {
            switch try await getOrCreateScriptHost(for: site) {
            case .js(let host): return try await host.categoryContent(tid: categoryId, page: page, filter: true, extend: filters)
            case .drpy(let host): return try await host.categoryContent(tid: categoryId, page: page, filter: true, extend: filters)
            }
        }
        if !site.supported, let storage = storage, storage.spiderGatewayConfig().isActive {
            let raw = try await gatewayClient.invoke(
                config: storage.spiderGatewayConfig(),
                site: site,
                action: "category",
                params: ["tid": categoryId, "pg": max(1, page), "filter": true, "extend": filters]
            )
            return try CmsParser.parseListing(raw)
        }

        guard site.supported else { throw MarcoError.unsupportedSite(site.unsupportedReason) }

        if site.type == 4 {
            var params: [String: String] = ["pg": "\(max(1, page))"]
            if !categoryId.isEmpty && categoryId != "all" { params["t"] = categoryId }
            if !filters.isEmpty, let extData = try? JSONSerialization.data(withJSONObject: filters) {
                params["ext"] = extData.base64EncodedString()
            }
            let body = try await fetchText(from: appendQuery(site.api, params: params), headers: site.headers)
            return try CmsParser.parseListing(body)
        }

        var params: [String: String] = ["ac": "detail", "pg": "\(max(1, page))"]
        if !categoryId.isEmpty && categoryId != "all" { params["t"] = categoryId }
        let body = try await fetchText(from: appendQuery(site.api, params: params), headers: site.headers)
        return try CmsParser.parseListing(body)
    }

    public func fetchDetail(
        site: CmsSite,
        video: CmsVideo,
        storage: IOSStorageManager? = nil
    ) async throws -> CmsVideo {
        if site.isExternalMediaLibrary, let storage = storage {
            return try await ExternalMediaLibraryDispatcher.detail(site: site, fallback: video, storage: storage, session: session)
        }
        if site.isM3uVodApi { return video }
        if site.isCatPaw {
            let raw = try await catpawHost.callEndpoint(
                path: "/detail",
                body: ["site": sitePayloadDict(site), "id": video.id],
                storage: storage
            )
            if let detailed = try CmsParser.parseListing(raw).videos.first {
                return mergeVideoFallback(primary: detailed, fallback: video)
            }
            return video
        }
        if site.isPythonSource {
            let src = try await loadPythonSource(for: site)
            if let detailed = try await pythonHost.detailContent(site: site, scriptSource: src, ids: [video.id]) {
                return mergeVideoFallback(primary: detailed, fallback: video)
            }
            return video
        }
        if site.isCspRuleEngine {
            return try await CspRuleEngines.detailContent(site: site, video: video, fetchText: makeTextFetcher())
        }
        if site.isWoggNetdiskSource {
            return try await WoggNetdiskSource.detailContent(site: site, video: video, fetchText: makeTextFetcher())
        }
        if site.hasQuickJsAdapter {
            let detailed: CmsVideo?
            switch try await getOrCreateScriptHost(for: site) {
            case .js(let host): detailed = try await host.detailContent(ids: [video.id])
            case .drpy(let host): detailed = try await host.detailContent(ids: [video.id])
            }
            if let detailed = detailed {
                return mergeVideoFallback(primary: detailed, fallback: video)
            }
            return video
        }
        if !site.supported, let storage = storage, storage.spiderGatewayConfig().isActive {
            let raw = try await gatewayClient.invoke(
                config: storage.spiderGatewayConfig(),
                site: site,
                action: "detail",
                params: ["ids": [video.id]]
            )
            if let detailed = try CmsParser.parseListing(raw).videos.first {
                return mergeVideoFallback(primary: detailed, fallback: video)
            }
            return video
        }

        guard site.supported else { throw MarcoError.unsupportedSite(site.unsupportedReason) }

        let params: [String: String] = (site.type == 4)
            ? ["ids": video.id]
            : ["ac": "detail", "ids": video.id]
        let body = try await fetchText(from: appendQuery(site.api, params: params), headers: site.headers)
        if let detailed = try CmsParser.parseListing(body).videos.first {
            return mergeVideoFallback(primary: detailed, fallback: video)
        }
        return video
    }

    public static func isGenericPlaceholderVodId(_ rawId: String) -> Bool {
        let lower = rawId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lower.isEmpty || lower == "msearch" || lower == "search" || lower == "vod_search"
    }

    public func fetchDetailWithSameSiteRecovery(
        site: CmsSite,
        video: CmsVideo,
        storage: IOSStorageManager? = nil
    ) async throws -> CmsVideo {
        let primaryError: Error?
        do {
            let detailed = try await fetchDetail(site: site, video: video, storage: storage)
            if !detailed.lines.isEmpty && !Self.isGenericPlaceholderVodId(detailed.id) {
                return detailed
            }
            if !detailed.lines.isEmpty && detailed.lines.contains(where: { !$0.episodes.isEmpty }) {
                return detailed
            }
            primaryError = nil
        } catch {
            primaryError = error
        }

        let cleanTitle = video.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty, site.searchable else {
            if let err = primaryError { throw err }
            return video
        }

        if let candidates = try? await search(site: site, keyword: cleanTitle, page: 1, storage: storage),
           !candidates.isEmpty
        {
            let normTarget = Self.normalizeTitleForMatch(cleanTitle)
            let exactMatches = candidates.filter {
                !Self.isGenericPlaceholderVodId($0.id)
                    && Self.normalizeTitleForMatch($0.title) == normTarget
            }
            let bestCandidate = exactMatches.first
                ?? candidates.first(where: { !Self.isGenericPlaceholderVodId($0.id) })
            if let matched = bestCandidate, matched.id != video.id {
                if let recovered = try? await fetchDetail(site: site, video: matched, storage: storage),
                   !recovered.lines.isEmpty
                {
                    return recovered
                }
            }
        }

        if let err = primaryError { throw err }
        return video
    }

    private static func normalizeTitleForMatch(_ title: String) -> String {
        title
            .lowercased()
            .components(separatedBy: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
            .joined()
    }

    public func search(
        site: CmsSite,
        keyword: String,
        page: Int = 1,
        storage: IOSStorageManager? = nil
    ) async throws -> [CmsVideo] {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        if site.isExternalMediaLibrary, let storage = storage {
            return try await ExternalMediaLibraryDispatcher.list(
                site: site,
                categoryId: "",
                query: trimmed,
                page: page,
                storage: storage,
                session: session
            ).videos
        }
        if site.isM3uVodApi {
            let raw = try await loadM3uVodPayload(site: site)
            let (_, allListing) = try CmsParser.parseM3uVodHome(raw, origin: m3uOrigin(for: site))
            let lower = trimmed.lowercased()
            return allListing.videos.filter { $0.title.lowercased().contains(lower) || $0.tag.lowercased().contains(lower) }
        }
        if site.isCatPaw {
            let raw = try await catpawHost.callEndpoint(
                path: "/search",
                body: ["site": sitePayloadDict(site), "wd": trimmed, "pg": max(1, page)],
                storage: storage
            )
            return try CmsParser.parseListing(raw).videos
        }
        if site.isPythonSource {
            let src = try await loadPythonSource(for: site)
            return try await pythonHost.searchContent(site: site, scriptSource: src, keyword: trimmed, page: page)
        }
        if site.isCspRuleEngine {
            return try await CspRuleEngines.searchContent(site: site, keyword: trimmed, page: page, fetchText: makeTextFetcher())
        }
        if site.isWoggNetdiskSource {
            return try await WoggNetdiskSource.searchContent(site: site, keyword: trimmed, page: page, fetchText: makeTextFetcher())
        }
        if site.hasQuickJsAdapter {
            switch try await getOrCreateScriptHost(for: site) {
            case .js(let host): return try await host.searchContent(keyword: trimmed, quick: false, page: page)
            case .drpy(let host): return try await host.searchContent(keyword: trimmed, quick: false, page: page)
            }
        }
        if !site.supported, let storage = storage, storage.spiderGatewayConfig().isActive {
            let raw = try await gatewayClient.invoke(
                config: storage.spiderGatewayConfig(),
                site: site,
                action: "search",
                params: ["key": trimmed, "quick": false, "pg": max(1, page)]
            )
            return try CmsParser.parseListing(raw).videos
        }

        guard site.supported else { return [] }

        if site.type == 4 {
            let url = appendQuery(site.api, params: ["wd": trimmed, "pg": "\(max(1, page))"])
            let body = try await fetchText(from: url, headers: site.headers)
            return try CmsParser.parseListing(body).videos
        }

        let detailSearchUrl = appendQuery(site.api, params: ["ac": "detail", "wd": trimmed, "pg": "\(max(1, page))"])
        if let detailBody = try? await fetchText(from: detailSearchUrl, headers: site.headers),
           let parsed = try? CmsParser.parseListing(detailBody),
           !parsed.videos.isEmpty
        {
            return parsed.videos
        }
        let listSearchUrl = appendQuery(site.api, params: ["ac": "list", "wd": trimmed, "pg": "\(max(1, page))"])
        let body = try await fetchText(from: listSearchUrl, headers: site.headers)
        return try CmsParser.parseListing(body).videos
    }

    public func fetchLiveGroups(source: LiveSource) async throws -> [LiveGroup] {
        if !source.inlineContent.isEmpty {
            return try CmsParser.parseLivePlaylist(source.inlineContent, origin: source.origin, headers: source.headers)
        }
        let rawUrl = source.url.trimmingCharacters(in: .whitespacesAndNewlines)
        if rawUrl.lowercased().hasPrefix("data:"),
           let range = rawUrl.range(of: "base64,")
        {
            let b64 = String(rawUrl[range.upperBound...])
            guard let data = Data(base64Encoded: b64) else {
                throw MarcoError.invalidFormat("无效的 Base64 直播列表")
            }
            let text = String(decoding: data, as: UTF8.self)
            return try CmsParser.parseLivePlaylist(text, origin: source.origin, headers: source.headers)
        }
        let text = try await fetchText(from: rawUrl, headers: source.headers, maxBytes: LiveCatalogParser.maxBytes)
        return try CmsParser.parseLivePlaylist(text, origin: rawUrl, headers: source.headers)
    }

    // MARK: - Playback Resolution

    public func resolvePlayableStream(
        site: CmsSite,
        lineName: String,
        episode: CmsEpisode,
        parses: [CmsParse] = [],
        storage: IOSStorageManager? = nil,
        headerProxy: LocalHeaderProxyServer? = nil,
        rangeProxy: NetdiskRangeProxyServer? = nil
    ) async throws -> ResolvedPlayback {
        if site.isExternalMediaLibrary || episode.isExternalLibraryUrl, let storage = storage {
            let resolvedEp = try await ExternalMediaLibraryDispatcher.resolve(
                site: site,
                episode: episode,
                storage: storage,
                session: session
            )
            return try await finalizePlayableUrl(
                urlStr: resolvedEp.url,
                headers: resolvedEp.headers,
                lineName: lineName,
                storage: storage,
                headerProxy: headerProxy,
                rangeProxy: rangeProxy
            )
        }

        var urlStr = episode.url.trimmingCharacters(in: .whitespacesAndNewlines)
        var mergedHeaders = LiveCatalogParser.mergeHeaders([site.headers, episode.headers])

        if site.isCatPaw {
            let raw = try await catpawHost.callEndpoint(
                path: "/play",
                body: ["site": sitePayloadDict(site), "flag": lineName, "id": urlStr],
                storage: storage
            )
            if let data = raw.data(using: .utf8),
               let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let resolved = obj["url"] as? String, !resolved.isEmpty
            {
                urlStr = resolved
                if let hMap = (obj["header"] ?? obj["headers"]) as? [String: Any] {
                    var extra: [String: String] = [:]
                    for (k, v) in hMap where !(v is NSNull) { extra[k] = String(describing: v) }
                    mergedHeaders = LiveCatalogParser.mergeHeaders([mergedHeaders, extra])
                }
            }
        } else if site.isPythonSource {
            let src = try await loadPythonSource(for: site)
            let resolved = try await pythonHost.playerContent(site: site, scriptSource: src, flag: lineName, id: urlStr)
            if !resolved.url.isEmpty { urlStr = resolved.url }
            mergedHeaders = LiveCatalogParser.mergeHeaders([mergedHeaders, resolved.headers])
        } else if site.isCspRuleEngine && !episode.isDirectPlayable {
            let resolved = try await CspRuleEngines.resolvePlayUrl(site: site, episodeUrl: urlStr, fetchText: makeTextFetcher())
            urlStr = resolved.url
            mergedHeaders = LiveCatalogParser.mergeHeaders([mergedHeaders, resolved.headers])
        } else if site.hasQuickJsAdapter && (!episode.isDirectPlayable || episode.isScriptEpisode) {
            let resolved: JsResolvedPlayStream
            switch try await getOrCreateScriptHost(for: site) {
            case .js(let host): resolved = try await host.playerContent(flag: lineName, id: urlStr)
            case .drpy(let host): resolved = try await host.playerContent(flag: lineName, id: urlStr)
            }
            if !resolved.url.isEmpty { urlStr = resolved.url }
            mergedHeaders = LiveCatalogParser.mergeHeaders([mergedHeaders, resolved.headers])
        } else if !site.supported, let storage = storage, storage.spiderGatewayConfig().isActive {
            let raw = try await gatewayClient.invoke(
                config: storage.spiderGatewayConfig(),
                site: site,
                action: "play",
                params: ["flag": lineName, "id": urlStr]
            )
            if let data = raw.data(using: .utf8),
               let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let resolved = obj["url"] as? String, !resolved.isEmpty
            {
                urlStr = resolved
            }
        }

        if let storage = storage,
           NetdiskShareResolver.detectDriveKey(for: urlStr, lineName: lineName) != nil
        {
            let prefs = storage.preferences()
            return try await netdiskResolver.resolvePlayback(
                rawUrl: urlStr,
                lineName: lineName,
                extraHeaders: mergedHeaders,
                qualityPreference: prefs.netdiskQuality,
                playerKernel: prefs.playerKernel,
                storage: storage,
                rangeProxy: rangeProxy,
                headerProxy: headerProxy
            )
        }

        if !CmsEpisode(name: episode.name, url: urlStr).isDirectPlayable {
            var parseCandidates: [(url: String, headers: [String: String])] = []
            if !site.playUrl.isEmpty {
                parseCandidates.append((site.playUrl, site.headers))
            }
            for p in parses where p.type == 1 || p.type == 2 || p.type == 3 {
                parseCandidates.append((p.url, p.headers))
            }
            for candidate in parseCandidates {
                if let parsedUrl = await tryJsonParseEndpoint(
                    parseBase: candidate.url,
                    rawEpisodeUrl: urlStr,
                    headers: candidate.headers
                ) {
                    urlStr = parsedUrl.url
                    mergedHeaders = LiveCatalogParser.mergeHeaders([mergedHeaders, parsedUrl.headers])
                    break
                }
            }
        }

        return try await finalizePlayableUrl(
            urlStr: urlStr,
            headers: mergedHeaders,
            lineName: lineName,
            storage: storage,
            headerProxy: headerProxy,
            rangeProxy: rangeProxy
        )
    }

    private func finalizePlayableUrl(
        urlStr: String,
        headers: [String: String],
        lineName: String,
        storage: IOSStorageManager?,
        headerProxy: LocalHeaderProxyServer?,
        rangeProxy: NetdiskRangeProxyServer?
    ) async throws -> ResolvedPlayback {
        let trimmed = urlStr.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("/") || trimmed.lowercased().hasPrefix("file://") {
            let localUrl = trimmed.lowercased().hasPrefix("file://")
                ? (URL(string: trimmed) ?? URL(fileURLWithPath: trimmed))
                : URL(fileURLWithPath: trimmed)
            return ResolvedPlayback(
                originalUrl: trimmed,
                playableUrl: localUrl,
                headers: [:],
                isProxied: false,
                kernelLabel: "本地离线直放",
                resolutionBadge: NetdiskShareResolver.inferResolutionBadge(from: trimmed, fallbackQuality: "auto")
            )
        }

        guard let finalUrl = URL(string: CmsParser.normalizeUrl(trimmed)),
              let scheme = finalUrl.scheme?.lowercased(),
              ["http", "https", "rtmp", "rtsp"].contains(scheme)
        else {
            throw MarcoError.invalidFormat("无法解析出可播放的视频流地址")
        }

        let prefs = storage?.preferences() ?? PlaybackPreferences()
        let needsProxy = !headers.isEmpty || (prefs.hlsAdStripEnabled && finalUrl.path.lowercased().hasSuffix(".m3u8"))
        if needsProxy, let proxy = headerProxy, (scheme == "http" || scheme == "https") {
            let (sessionId, proxiedUrl) = try await proxy.registerStreamWithId(
                url: finalUrl,
                headers: headers,
                isLive: false,
                stripHlsAds: prefs.hlsAdStripEnabled,
                adHosts: storage?.mergedConfig().ads ?? []
            )
            return ResolvedPlayback(
                originalUrl: finalUrl.absoluteString,
                playableUrl: proxiedUrl,
                headers: headers,
                isProxied: true,
                kernelLabel: "本地代理硬解",
                resolutionBadge: NetdiskShareResolver.inferResolutionBadge(from: finalUrl.absoluteString, fallbackQuality: "auto"),
                headerProxySessionId: sessionId
            )
        }

        return ResolvedPlayback(
            originalUrl: finalUrl.absoluteString,
            playableUrl: finalUrl,
            headers: headers,
            isProxied: false,
            kernelLabel: "AVPlayer 硬解",
            resolutionBadge: NetdiskShareResolver.inferResolutionBadge(from: finalUrl.absoluteString, fallbackQuality: "auto")
        )
    }

    // MARK: - Private Script Host & Parse Helpers

    private enum ScriptHost {
        case js(JsSourceHost)
        case drpy(DrpySourceHost)
    }

    private func makeTextFetcher() -> CspTextFetcher {
        return { [weak self] url, headers in
            guard let self = self else { throw MarcoError.cancelled }
            return try await self.fetchText(from: url, headers: headers)
        }
    }

    private func sitePayloadDict(_ site: CmsSite) -> [String: Any] {
        [
            "key": site.sourceKey,
            "name": site.name,
            "api": site.sourceApi,
            "type": site.type,
            "ext": site.rawExtension ?? site.ext,
            "jar": site.jar,
            "spider": site.spider,
        ]
    }

    private func loadPythonSource(for site: CmsSite) async throws -> String {
        jsHostLock.lock()
        let cached = pythonSourceBySiteKey[site.key]
        jsHostLock.unlock()
        if let cached = cached { return cached }

        let source: String
        if site.api == "csp_LocalScript.py",
           let data = site.ext.data(using: .utf8),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let inline = obj["script"] as? String
        {
            source = inline
        } else if site.isHttpApi {
            source = try await fetchText(from: site.api, headers: site.headers)
        } else {
            throw MarcoError.unsupportedSite("无法加载 Python 片源脚本")
        }

        jsHostLock.lock()
        pythonSourceBySiteKey[site.key] = source
        jsHostLock.unlock()
        return source
    }

    private func getOrCreateScriptHost(for site: CmsSite) async throws -> ScriptHost {
        jsHostLock.lock()
        if let drpy = drpyHostsBySiteKey[site.key] {
            jsHostLock.unlock()
            return .drpy(drpy)
        }
        if let js = jsHostsBySiteKey[site.key] {
            jsHostLock.unlock()
            return .js(js)
        }
        jsHostLock.unlock()

        if let adapter = site.guardAdapterKey,
           let parsedRef = GuardPluginExtractor.parsePluginReference(site.pluginReference)
        {
            let (jarBytes, _) = try await fetchRawData(
                from: parsedRef.url,
                headers: site.headers,
                maxBytes: GuardPluginExtractor.maxArtifactBytes
            )
            try GuardPluginExtractor.verifyOptionalMd5(data: jarBytes, expectedMd5: parsedRef.expectedMd5)
            let extracted = try GuardPluginExtractor.extract(
                artifactBytes: jarBytes,
                adapter: adapter,
                extension: site.rawExtension ?? (site.ext.isEmpty ? nil : site.ext)
            )
            let drpyHost = try DrpySourceHost(
                site: site,
                ruleSource: extracted.rule,
                origin: extracted.origin
            )
            jsHostLock.lock()
            drpyHostsBySiteKey[site.key] = drpyHost
            jsHostLock.unlock()
            return .drpy(drpyHost)
        }

        let scriptSource: String
        var resolvedOrigin = site.api
        if site.api == "csp_LocalScript.js" || site.api == "csp_LocalRule.js" {
            if let data = site.ext.data(using: .utf8),
               let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let inline = obj["script"] as? String
            {
                scriptSource = inline
                if let orig = obj["origin"] as? String, !orig.isEmpty { resolvedOrigin = orig }
            } else {
                scriptSource = site.ext
            }
        } else if site.isDrpySource && !site.ext.isEmpty {
            let trimmedExt = site.ext.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedExt.lowercased().hasPrefix("http://") || trimmedExt.lowercased().hasPrefix("https://") {
                scriptSource = try await fetchText(from: trimmedExt, headers: site.headers)
                resolvedOrigin = trimmedExt
            } else {
                scriptSource = trimmedExt
            }
        } else {
            scriptSource = try await fetchText(from: site.api, headers: site.headers)
        }

        if DrpySourceHost.looksLikeDrpyRule(scriptSource) || site.isDrpySource {
            let drpyHost = try DrpySourceHost(
                site: site,
                ruleSource: scriptSource,
                origin: resolvedOrigin
            )
            jsHostLock.lock()
            drpyHostsBySiteKey[site.key] = drpyHost
            jsHostLock.unlock()
            return .drpy(drpyHost)
        }

        let host = try JsSourceHost(site: site, scriptSource: scriptSource)
        jsHostLock.lock()
        jsHostsBySiteKey[site.key] = host
        jsHostLock.unlock()
        return .js(host)
    }

    private func loadM3uVodPayload(site: CmsSite) async throws -> String {
        if !site.ext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return site.ext }
        let origin = m3uOrigin(for: site)
        guard origin.lowercased().hasPrefix("http") else {
            throw MarcoError.invalidFormat("M3U 点播源缺少可读取内容")
        }
        return try await fetchText(from: origin, headers: site.headers)
    }

    private func m3uOrigin(for site: CmsSite) -> String {
        let lower = site.api.lowercased()
        if lower.hasPrefix("m3u_vod://") {
            return String(site.api.dropFirst("m3u_vod://".count))
        }
        return site.api
    }

    private func tryJsonParseEndpoint(
        parseBase: String,
        rawEpisodeUrl: String,
        headers: [String: String]
    ) async -> (url: String, headers: [String: String])? {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#/")
        let encoded = rawEpisodeUrl.addingPercentEncoding(withAllowedCharacters: allowed) ?? rawEpisodeUrl
        let target: String
        if parseBase.contains("=") && (parseBase.hasSuffix("=") || parseBase.hasSuffix("&")) {
            target = parseBase + encoded
        } else if parseBase.contains("?") {
            target = "\(parseBase)&url=\(encoded)"
        } else {
            target = "\(parseBase)?url=\(encoded)"
        }
        guard let body = try? await fetchText(from: target, headers: headers),
              let data = ConfigDecoder.stripJsonComments(body).data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            return nil
        }
        let resolvedUrl = ((obj["url"] as? String) ?? ((obj["data"] as? [String: Any])?["url"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard resolvedUrl.lowercased().hasPrefix("http://") || resolvedUrl.lowercased().hasPrefix("https://") else {
            return nil
        }
        var extraHeaders: [String: String] = [:]
        if let hMap = (obj["header"] ?? obj["headers"]) as? [String: Any] {
            for (k, v) in hMap where !(v is NSNull) { extraHeaders[k] = String(describing: v) }
        }
        return (resolvedUrl, extraHeaders)
    }

    private func mergeVideoFallback(primary: CmsVideo, fallback: CmsVideo) -> CmsVideo {
        CmsVideo(
            id: primary.id.isEmpty ? fallback.id : primary.id,
            title: primary.title.isEmpty ? fallback.title : primary.title,
            poster: primary.poster.isEmpty ? fallback.poster : primary.poster,
            remarks: primary.remarks.isEmpty ? fallback.remarks : primary.remarks,
            year: primary.year.isEmpty ? fallback.year : primary.year,
            area: primary.area.isEmpty ? fallback.area : primary.area,
            actor: primary.actor.isEmpty ? fallback.actor : primary.actor,
            director: primary.director.isEmpty ? fallback.director : primary.director,
            description: primary.description.isEmpty ? fallback.description : primary.description,
            tag: primary.tag.isEmpty ? fallback.tag : primary.tag,
            doubanScore: primary.doubanScore ?? fallback.doubanScore,
            rtScore: primary.rtScore ?? fallback.rtScore,
            lines: primary.lines.isEmpty ? fallback.lines : primary.lines,
            sourceWarnings: primary.sourceWarnings.isEmpty ? fallback.sourceWarnings : primary.sourceWarnings
        )
    }

    private func appendQuery(_ rawBase: String, params: [String: String]) -> String {
        let normalized = CmsParser.normalizeUrl(rawBase)
        guard var comps = URLComponents(string: normalized) else { return normalized }
        var items = comps.queryItems ?? []
        for (k, v) in params.sorted(by: { $0.key < $1.key }) {
            items.removeAll { $0.name == k }
            items.append(URLQueryItem(name: k, value: v))
        }
        comps.queryItems = items
        return comps.string ?? normalized
    }
}
