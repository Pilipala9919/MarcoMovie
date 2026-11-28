// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// Unified external media library protocol dispatcher supporting Emby, Jellyfin, Plex,
/// WebDAV media folders, AList/OpenList NAS, SMB2 NAS shares, and local on-device folders.
public enum ExternalMediaLibraryDispatcher {
    public static let embyPrefix = "emby://account/"
    public static let jellyfinPrefix = "jellyfin://account/"
    public static let plexPrefix = "plex://account/"
    public static let webdavPrefix = "webdavlib://account/"
    public static let alistPrefix = "alist://account/"
    public static let smbPrefix = "smbnas://account/"
    public static let localPrefix = "localfile://account/"
    public static let folderTag = "media-folder"

    public static let videoExtensions: Set<String> = [
        "mp4", "mkv", "mov", "m4v", "avi", "ts", "m2ts", "flv", "webm", "wmv", "rmvb", "m3u8", "iso",
    ]

    public static func isVideoFileName(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return videoExtensions.contains(ext)
    }

    public static func cleanMediaTitle(_ fileName: String) -> String {
        let decoded = fileName.removingPercentEncoding ?? fileName
        let leaf = (decoded as NSString).lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        let ext = (leaf as NSString).pathExtension.lowercased()
        if videoExtensions.contains(ext) {
            return (leaf as NSString).deletingPathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return leaf
    }

    public static func home(
        site: CmsSite,
        storage: IOSStorageManager,
        session: URLSession
    ) async throws -> SiteHomePayload {
        if site.api.hasPrefix(embyPrefix) {
            let key = String(site.api.dropFirst(embyPrefix.count))
            guard let account = storage.embyAccounts().first(where: { $0.key == key }) else {
                throw MarcoError.unsupportedSite("未找到对应的 Emby 账号配置")
            }
            return try await embyOrJellyfinHome(baseUrl: account.baseUrl, userId: account.userId, token: account.accessToken, isJellyfin: false, session: session)
        }
        if site.api.hasPrefix(jellyfinPrefix) {
            let key = String(site.api.dropFirst(jellyfinPrefix.count))
            guard let acc = storage.mediaLibraryAccounts().first(where: { $0.kind == .jellyfin && $0.key == key }) else {
                throw MarcoError.unsupportedSite("未找到对应的 Jellyfin 账号配置")
            }
            let token = storage.mediaLibrarySecret(for: acc)
            return try await embyOrJellyfinHome(baseUrl: acc.baseUrl, userId: acc.userId, token: token, isJellyfin: true, session: session)
        }
        if site.api.hasPrefix(plexPrefix) {
            let key = String(site.api.dropFirst(plexPrefix.count))
            guard let acc = storage.mediaLibraryAccounts().first(where: { $0.kind == .plex && $0.key == key }) else {
                throw MarcoError.unsupportedSite("未找到对应的 Plex 账号配置")
            }
            let token = storage.mediaLibrarySecret(for: acc)
            return try await plexHome(baseUrl: acc.baseUrl, token: token, session: session)
        }
        if site.api.hasPrefix(webdavPrefix) {
            let key = String(site.api.dropFirst(webdavPrefix.count))
            guard let acc = storage.mediaLibraryAccounts().first(where: { $0.kind == .webdav && $0.key == key }) else {
                throw MarcoError.unsupportedSite("未找到对应的 WebDAV 媒体库配置")
            }
            let pass = storage.mediaLibrarySecret(for: acc)
            let listing = try await webdavList(account: acc, password: pass, subPath: acc.path, session: session)
            return SiteHomePayload(categories: [CmsCategory(id: acc.path, name: "根目录")], listing: listing)
        }
        if site.api.hasPrefix(alistPrefix) {
            let key = String(site.api.dropFirst(alistPrefix.count))
            guard let acc = storage.mediaLibraryAccounts().first(where: { $0.kind == .alist && $0.key == key }) else {
                throw MarcoError.unsupportedSite("未找到对应的 AList 媒体库配置")
            }
            let token = storage.mediaLibrarySecret(for: acc)
            let listing = try await alistList(account: acc, token: token, path: acc.path.isEmpty ? "/" : acc.path, page: 1, session: session)
            return SiteHomePayload(categories: [CmsCategory(id: acc.path.isEmpty ? "/" : acc.path, name: "根目录")], listing: listing)
        }
        if site.api.hasPrefix(smbPrefix) {
            let key = String(site.api.dropFirst(smbPrefix.count))
            guard let acc = storage.mediaLibraryAccounts().first(where: { $0.kind == .smb2 && $0.key == key }) else {
                throw MarcoError.unsupportedSite("未找到对应的 SMB 共享配置")
            }
            let pass = storage.mediaLibrarySecret(for: acc)
            let listing = try await smbList(account: acc, password: pass, relativePath: acc.path)
            return SiteHomePayload(categories: [CmsCategory(id: acc.path, name: acc.shareName.isEmpty ? "共享目录" : acc.shareName)], listing: listing)
        }
        if site.api.hasPrefix(localPrefix) {
            let key = String(site.api.dropFirst(localPrefix.count))
            guard let acc = storage.mediaLibraryAccounts().first(where: { $0.kind == .local && $0.key == key }) else {
                throw MarcoError.unsupportedSite("未找到对应的本机媒体目录配置")
            }
            let listing = localList(rootPath: acc.path, subPath: "")
            return SiteHomePayload(categories: [CmsCategory(id: "", name: acc.label)], listing: listing)
        }
        throw MarcoError.unsupportedSite("不支持的外部媒体库协议")
    }

    public static func list(
        site: CmsSite,
        categoryId: String,
        query: String,
        page: Int,
        storage: IOSStorageManager,
        session: URLSession
    ) async throws -> CmsListing {
        if site.api.hasPrefix(embyPrefix) {
            let key = String(site.api.dropFirst(embyPrefix.count))
            guard let acc = storage.embyAccounts().first(where: { $0.key == key }) else { return CmsListing() }
            return try await embyOrJellyfinList(baseUrl: acc.baseUrl, userId: acc.userId, token: acc.accessToken, parentId: categoryId, query: query, page: page, session: session)
        }
        if site.api.hasPrefix(jellyfinPrefix) {
            let key = String(site.api.dropFirst(jellyfinPrefix.count))
            guard let acc = storage.mediaLibraryAccounts().first(where: { $0.kind == .jellyfin && $0.key == key }) else { return CmsListing() }
            return try await embyOrJellyfinList(baseUrl: acc.baseUrl, userId: acc.userId, token: storage.mediaLibrarySecret(for: acc), parentId: categoryId, query: query, page: page, session: session)
        }
        if site.api.hasPrefix(plexPrefix) {
            let key = String(site.api.dropFirst(plexPrefix.count))
            guard let acc = storage.mediaLibraryAccounts().first(where: { $0.kind == .plex && $0.key == key }) else { return CmsListing() }
            return try await plexList(baseUrl: acc.baseUrl, token: storage.mediaLibrarySecret(for: acc), sectionKey: categoryId, query: query, session: session)
        }
        if site.api.hasPrefix(webdavPrefix) {
            let key = String(site.api.dropFirst(webdavPrefix.count))
            guard let acc = storage.mediaLibraryAccounts().first(where: { $0.kind == .webdav && $0.key == key }) else { return CmsListing() }
            return try await webdavList(account: acc, password: storage.mediaLibrarySecret(for: acc), subPath: categoryId, session: session)
        }
        if site.api.hasPrefix(alistPrefix) {
            let key = String(site.api.dropFirst(alistPrefix.count))
            guard let acc = storage.mediaLibraryAccounts().first(where: { $0.kind == .alist && $0.key == key }) else { return CmsListing() }
            return try await alistList(account: acc, token: storage.mediaLibrarySecret(for: acc), path: categoryId.isEmpty ? "/" : categoryId, page: page, session: session)
        }
        if site.api.hasPrefix(smbPrefix) {
            let key = String(site.api.dropFirst(smbPrefix.count))
            guard let acc = storage.mediaLibraryAccounts().first(where: { $0.kind == .smb2 && $0.key == key }) else { return CmsListing() }
            return try await smbList(account: acc, password: storage.mediaLibrarySecret(for: acc), relativePath: categoryId)
        }
        if site.api.hasPrefix(localPrefix) {
            let key = String(site.api.dropFirst(localPrefix.count))
            guard let acc = storage.mediaLibraryAccounts().first(where: { $0.kind == .local && $0.key == key }) else { return CmsListing() }
            return localList(rootPath: acc.path, subPath: categoryId)
        }
        return CmsListing()
    }

    public static func detail(
        site: CmsSite,
        fallback: CmsVideo,
        storage: IOSStorageManager,
        session: URLSession
    ) async throws -> CmsVideo {
        if site.api.hasPrefix(embyPrefix) {
            let key = String(site.api.dropFirst(embyPrefix.count))
            guard let acc = storage.embyAccounts().first(where: { $0.key == key }) else { return fallback }
            return try await embyOrJellyfinDetail(baseUrl: acc.baseUrl, userId: acc.userId, token: acc.accessToken, fallback: fallback, scheme: "mmemby", accountKey: key, session: session)
        }
        if site.api.hasPrefix(jellyfinPrefix) {
            let key = String(site.api.dropFirst(jellyfinPrefix.count))
            guard let acc = storage.mediaLibraryAccounts().first(where: { $0.kind == .jellyfin && $0.key == key }) else { return fallback }
            return try await embyOrJellyfinDetail(baseUrl: acc.baseUrl, userId: acc.userId, token: storage.mediaLibrarySecret(for: acc), fallback: fallback, scheme: "mmjellyfin", accountKey: key, session: session)
        }
        return fallback
    }

    public static func resolve(
        site: CmsSite,
        episode: CmsEpisode,
        storage: IOSStorageManager,
        session: URLSession
    ) async throws -> CmsEpisode {
        let lower = episode.url.lowercased()
        if lower.hasPrefix("mmemby://play?") || lower.hasPrefix("mmjellyfin://play?") {
            let isJf = lower.hasPrefix("mmjellyfin://")
            guard let comps = URLComponents(string: episode.url),
                  let key = comps.queryItems?.first(where: { $0.name == "key" })?.value,
                  let itemId = comps.queryItems?.first(where: { $0.name == "id" })?.value
            else { return episode }
            let baseUrl: String
            let token: String
            if isJf {
                guard let acc = storage.mediaLibraryAccounts().first(where: { $0.kind == .jellyfin && $0.key == key }) else { return episode }
                baseUrl = acc.baseUrl
                token = storage.mediaLibrarySecret(for: acc)
            } else {
                guard let acc = storage.embyAccounts().first(where: { $0.key == key }) else { return episode }
                baseUrl = acc.baseUrl
                token = acc.accessToken
            }
            let cleanBase = baseUrl.hasSuffix("/") ? String(baseUrl.dropLast()) : baseUrl
            let direct = "\(cleanBase)/Videos/\(itemId)/stream?static=true"
            return CmsEpisode(name: episode.name, url: direct, headers: ["X-Emby-Token": token])
        }
        if lower.hasPrefix("mmalist://play?") {
            guard let comps = URLComponents(string: episode.url),
                  let key = comps.queryItems?.first(where: { $0.name == "key" })?.value,
                  let path = comps.queryItems?.first(where: { $0.name == "path" })?.value,
                  let acc = storage.mediaLibraryAccounts().first(where: { $0.kind == .alist && $0.key == key })
            else { return episode }
            let cleanBase = acc.baseUrl.hasSuffix("/") ? String(acc.baseUrl.dropLast()) : acc.baseUrl
            let token = storage.mediaLibrarySecret(for: acc)
            let obj = try await postJson(
                urlString: "\(cleanBase)/api/fs/get",
                headers: token.isEmpty ? [:] : ["Authorization": token],
                payload: ["path": path, "password": ""],
                session: session
            )
            if let dataMap = obj["data"] as? [String: Any],
               let rawUrl = dataMap["raw_url"] as? String, !rawUrl.isEmpty
            {
                return CmsEpisode(name: episode.name, url: rawUrl)
            }
        }
        if lower.hasPrefix("mmlocal://play?") {
            if let comps = URLComponents(string: episode.url),
               let path = comps.queryItems?.first(where: { $0.name == "path" })?.value
            {
                return CmsEpisode(name: episode.name, url: URL(fileURLWithPath: path).absoluteString)
            }
        }
        return episode
    }

    // MARK: - Emby / Jellyfin

    private static func embyOrJellyfinHome(
        baseUrl: String,
        userId: String,
        token: String,
        isJellyfin: Bool,
        session: URLSession
    ) async throws -> SiteHomePayload {
        let cleanBase = baseUrl.hasSuffix("/") ? String(baseUrl.dropLast()) : baseUrl
        let viewsObj = try await getJson(
            urlString: "\(cleanBase)/Users/\(userId)/Views",
            headers: ["X-Emby-Token": token],
            session: session
        )
        let items = (viewsObj["Items"] as? [[String: Any]]) ?? []
        let cats: [CmsCategory] = items.compactMap { item in
            guard let id = item["Id"] as? String, let name = item["Name"] as? String else { return nil }
            return CmsCategory(id: id, name: name)
        }
        let firstListing: CmsListing
        if let first = cats.first {
            firstListing = try await embyOrJellyfinList(baseUrl: cleanBase, userId: userId, token: token, parentId: first.id, query: "", page: 1, session: session)
        } else {
            firstListing = CmsListing()
        }
        return SiteHomePayload(categories: cats, listing: firstListing)
    }

    private static func embyOrJellyfinList(
        baseUrl: String,
        userId: String,
        token: String,
        parentId: String,
        query: String,
        page: Int,
        session: URLSession
    ) async throws -> CmsListing {
        let cleanBase = baseUrl.hasSuffix("/") ? String(baseUrl.dropLast()) : baseUrl
        let limit = 40
        let startIdx = max(0, (page - 1) * limit)
        var urlStr = "\(cleanBase)/Users/\(userId)/Items?Recursive=true&IncludeItemTypes=Movie,Series&Fields=Overview,ProductionYear,CommunityRating&Limit=\(limit)&StartIndex=\(startIdx)&SortBy=DateCreated&SortOrder=Descending"
        if !parentId.isEmpty { urlStr += "&ParentId=\(qEnc(parentId))" }
        if !query.isEmpty { urlStr += "&SearchTerm=\(qEnc(query))" }

        let obj = try await getJson(urlString: urlStr, headers: ["X-Emby-Token": token], session: session)
        let total = (obj["TotalRecordCount"] as? NSNumber)?.intValue ?? 0
        let items = (obj["Items"] as? [[String: Any]]) ?? []
        let videos: [CmsVideo] = items.compactMap { item in
            guard let id = item["Id"] as? String, let name = item["Name"] as? String else { return nil }
            let poster = "\(cleanBase)/Items/\(id)/Images/Primary?maxHeight=600"
            let year = (item["ProductionYear"] as? NSNumber)?.stringValue ?? ""
            let overview = (item["Overview"] as? String) ?? ""
            let score = (item["CommunityRating"] as? NSNumber)?.doubleValue
            let typeName = (item["Type"] as? String) ?? ""
            return CmsVideo(
                id: id,
                title: name,
                poster: poster,
                remarks: typeName == "Series" ? "剧集" : "电影",
                year: year,
                description: overview,
                doubanScore: score
            )
        }
        return CmsListing(page: max(1, page), pageCount: max(1, (total + limit - 1) / limit), videos: videos)
    }

    private static func embyOrJellyfinDetail(
        baseUrl: String,
        userId: String,
        token: String,
        fallback: CmsVideo,
        scheme: String,
        accountKey: String,
        session: URLSession
    ) async throws -> CmsVideo {
        let cleanBase = baseUrl.hasSuffix("/") ? String(baseUrl.dropLast()) : baseUrl
        let item = try await getJson(
            urlString: "\(cleanBase)/Users/\(userId)/Items/\(fallback.id)",
            headers: ["X-Emby-Token": token],
            session: session
        )
        let itemType = (item["Type"] as? String) ?? ""
        var lines: [CmsLine] = []
        if itemType == "Series" {
            let epsObj = try await getJson(
                urlString: "\(cleanBase)/Shows/\(fallback.id)/Episodes?UserId=\(userId)",
                headers: ["X-Emby-Token": token],
                session: session
            )
            let epsList = (epsObj["Items"] as? [[String: Any]]) ?? []
            var bySeason: [Int: [CmsEpisode]] = [:]
            for ep in epsList {
                guard let epId = ep["Id"] as? String else { continue }
                let seasonNum = (ep["ParentIndexNumber"] as? NSNumber)?.intValue ?? 1
                let epNum = (ep["IndexNumber"] as? NSNumber)?.intValue ?? 0
                let epTitle = (ep["Name"] as? String) ?? "第 \(epNum) 集"
                let label = epNum > 0 ? "第\(epNum)集 \(epTitle)" : epTitle
                let playUrl = "\(scheme)://play?key=\(qEnc(accountKey))&id=\(qEnc(epId))"
                bySeason[seasonNum, default: []].append(CmsEpisode(name: label, url: playUrl))
            }
            for seasonNum in bySeason.keys.sorted() {
                lines.append(CmsLine(name: "第 \(seasonNum) 季", episodes: bySeason[seasonNum] ?? []))
            }
        } else {
            let playUrl = "\(scheme)://play?key=\(qEnc(accountKey))&id=\(qEnc(fallback.id))"
            lines = [CmsLine(name: "直连原画", episodes: [CmsEpisode(name: "正片", url: playUrl)])]
        }
        return CmsVideo(
            id: fallback.id,
            title: (item["Name"] as? String) ?? fallback.title,
            poster: fallback.poster,
            remarks: fallback.remarks,
            year: (item["ProductionYear"] as? NSNumber)?.stringValue ?? fallback.year,
            description: (item["Overview"] as? String) ?? fallback.description,
            doubanScore: (item["CommunityRating"] as? NSNumber)?.doubleValue ?? fallback.doubanScore,
            lines: lines
        )
    }

    // MARK: - Plex

    private static func plexHome(baseUrl: String, token: String, session: URLSession) async throws -> SiteHomePayload {
        let cleanBase = baseUrl.hasSuffix("/") ? String(baseUrl.dropLast()) : baseUrl
        let obj = try await getJson(
            urlString: "\(cleanBase)/library/sections",
            headers: ["X-Plex-Token": token, "Accept": "application/json"],
            session: session
        )
        let mc = (obj["MediaContainer"] as? [String: Any]) ?? [:]
        let dirs = (mc["Directory"] as? [[String: Any]]) ?? []
        let cats: [CmsCategory] = dirs.compactMap { d in
            guard let k = d["key"] as? String, let t = d["title"] as? String else { return nil }
            return CmsCategory(id: k, name: t)
        }
        let listing = cats.first != nil
            ? (try await plexList(baseUrl: cleanBase, token: token, sectionKey: cats[0].id, query: "", session: session))
            : CmsListing()
        return SiteHomePayload(categories: cats, listing: listing)
    }

    private static func plexList(
        baseUrl: String,
        token: String,
        sectionKey: String,
        query: String,
        session: URLSession
    ) async throws -> CmsListing {
        let cleanBase = baseUrl.hasSuffix("/") ? String(baseUrl.dropLast()) : baseUrl
        let urlStr = query.isEmpty
            ? "\(cleanBase)/library/sections/\(sectionKey)/all"
            : "\(cleanBase)/search?query=\(qEnc(query))"
        let obj = try await getJson(
            urlString: urlStr,
            headers: ["X-Plex-Token": token, "Accept": "application/json"],
            session: session
        )
        let mc = (obj["MediaContainer"] as? [String: Any]) ?? [:]
        let items = (mc["Metadata"] as? [[String: Any]]) ?? []
        let videos: [CmsVideo] = items.compactMap { item in
            guard let rk = item["ratingKey"] as? String, let title = item["title"] as? String else { return nil }
            let thumb = (item["thumb"] as? String).map { "\(cleanBase)\($0)?X-Plex-Token=\(token)" } ?? ""
            var lines: [CmsLine] = []
            if let medias = item["Media"] as? [[String: Any]],
               let firstPart = (medias.first?["Part"] as? [[String: Any]])?.first,
               let partKey = firstPart["key"] as? String
            {
                let playUrl = "\(cleanBase)\(partKey)?X-Plex-Token=\(token)"
                lines = [CmsLine(name: "Plex 原画", episodes: [CmsEpisode(name: "正片", url: playUrl)])]
            }
            return CmsVideo(
                id: rk,
                title: title,
                poster: thumb,
                year: (item["year"] as? NSNumber)?.stringValue ?? "",
                description: (item["summary"] as? String) ?? "",
                lines: lines
            )
        }
        return CmsListing(page: 1, pageCount: 1, videos: videos)
    }

    // MARK: - WebDAV Media Folder

    private static func webdavList(
        account: MediaLibraryAccount,
        password: String,
        subPath: String,
        session: URLSession
    ) async throws -> CmsListing {
        let cleanBase = account.baseUrl.hasSuffix("/") ? String(account.baseUrl.dropLast()) : account.baseUrl
        let cleanSub = subPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let targetStr = cleanSub.isEmpty ? "\(cleanBase)/" : "\(cleanBase)/\(cleanSub)/"
        guard let url = URL(string: targetStr) else { throw MarcoError.invalidFormat("无效的 WebDAV 目录地址") }

        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        req.httpMethod = "PROPFIND"
        req.setValue("1", forHTTPHeaderField: "Depth")
        if !account.username.isEmpty || !password.isEmpty {
            let auth = Data("\(account.username):\(password)".utf8).base64EncodedString()
            req.setValue("Basic \(auth)", forHTTPHeaderField: "Authorization")
        }
        let (data, resp) = try await session.marcoData(for: req)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw MarcoError.networkFailure("WebDAV PROPFIND 返回 HTTP \(http.statusCode)")
        }
        let xml = String(decoding: data, as: UTF8.self)
        guard let hrefRe = try? NSRegularExpression(pattern: #"<(?:[a-zA-Z0-9_-]+:)?href>([^<]+)</(?:[a-zA-Z0-9_-]+:)?href>"#, options: [.caseInsensitive]) else {
            return CmsListing()
        }
        var videos: [CmsVideo] = []
        let authHeaders: [String: String] = (!account.username.isEmpty || !password.isEmpty)
            ? ["Authorization": "Basic \(Data("\(account.username):\(password)".utf8).base64EncodedString())"]
            : [:]
        for m in hrefRe.matches(in: xml, range: NSRange(xml.startIndex..., in: xml)) {
            guard let r = Range(m.range(at: 1), in: xml) else { continue }
            let href = String(xml[r]).trimmingCharacters(in: .whitespacesAndNewlines)
            let fullUrl = CmsParser.resolveUrl(base: targetStr, relative: href)
            if fullUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == targetStr.trimmingCharacters(in: CharacterSet(charactersIn: "/")) {
                continue
            }
            let decodedName = (href.removingPercentEncoding ?? href).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let leaf = (decodedName as NSString).lastPathComponent
            guard !leaf.isEmpty else { continue }
            if isVideoFileName(leaf) {
                videos.append(
                    CmsVideo(
                        id: fullUrl,
                        title: cleanMediaTitle(leaf),
                        remarks: (leaf as NSString).pathExtension.uppercased(),
                        lines: [CmsLine(name: "WebDAV 原画", episodes: [CmsEpisode(name: "正片", url: fullUrl, headers: authHeaders)])]
                    )
                )
            }
        }
        return CmsListing(page: 1, pageCount: 1, videos: videos)
    }

    // MARK: - AList / OpenList

    private static func alistList(
        account: MediaLibraryAccount,
        token: String,
        path: String,
        page: Int,
        session: URLSession
    ) async throws -> CmsListing {
        let cleanBase = account.baseUrl.hasSuffix("/") ? String(account.baseUrl.dropLast()) : account.baseUrl
        let obj = try await postJson(
            urlString: "\(cleanBase)/api/fs/list",
            headers: token.isEmpty ? [:] : ["Authorization": token],
            payload: ["path": path, "password": "", "page": max(1, page), "per_page": 100, "refresh": false],
            session: session
        )
        let dataMap = (obj["data"] as? [String: Any]) ?? [:]
        let content = (dataMap["content"] as? [[String: Any]]) ?? []
        let cleanParent = path == "/" ? "" : (path.hasSuffix("/") ? String(path.dropLast()) : path)
        var videos: [CmsVideo] = []
        for entry in content {
            guard let name = entry["name"] as? String, !name.isEmpty else { continue }
            let isDir = (entry["is_dir"] as? Bool) ?? false
            let fullPath = "\(cleanParent)/\(name)"
            if isDir {
                videos.append(CmsVideo(id: fullPath, title: name, remarks: "文件夹", tag: folderTag))
            } else if isVideoFileName(name) {
                let playUrl = "mmalist://play?key=\(qEnc(account.key))&path=\(qEnc(fullPath))"
                videos.append(
                    CmsVideo(
                        id: fullPath,
                        title: cleanMediaTitle(name),
                        poster: (entry["thumb"] as? String) ?? "",
                        remarks: (name as NSString).pathExtension.uppercased(),
                        lines: [CmsLine(name: "AList 原画", episodes: [CmsEpisode(name: "正片", url: playUrl)])]
                    )
                )
            }
        }
        return CmsListing(page: max(1, page), pageCount: 1, videos: videos)
    }

    // MARK: - SMB2 & Local

    private static func smbList(account: MediaLibraryAccount, password: String, relativePath: String) async throws -> CmsListing {
        let client = try await Smb2Client.connect(
            host: account.host,
            port: UInt16(account.port ?? 445),
            share: account.shareName,
            username: account.username,
            password: password,
            domain: account.domain
        )
        defer { Task { await client.close() } }
        let entries = try await client.listDirectory(relativePath)
        let videos: [CmsVideo] = entries.compactMap { entry in
            if entry.isDir {
                return CmsVideo(id: entry.relativePath, title: entry.name, remarks: "SMB 文件夹", tag: folderTag)
            }
            guard isVideoFileName(entry.name) else { return nil }
            let playUrl = "mmsmb://play?key=\(qEnc(account.key))&path=\(qEnc(entry.relativePath))"
            return CmsVideo(
                id: entry.relativePath,
                title: cleanMediaTitle(entry.name),
                remarks: (entry.name as NSString).pathExtension.uppercased(),
                lines: [CmsLine(name: "SMB2 直连", episodes: [CmsEpisode(name: "正片", url: playUrl)])]
            )
        }
        return CmsListing(page: 1, pageCount: 1, videos: videos)
    }

    private static func localList(rootPath: String, subPath: String) -> CmsListing {
        let targetDir = subPath.isEmpty ? rootPath : (rootPath as NSString).appendingPathComponent(subPath)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: targetDir) else {
            return CmsListing()
        }
        var videos: [CmsVideo] = []
        for name in names.sorted() where !name.hasPrefix(".") {
            let full = (targetDir as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: full, isDirectory: &isDir)
            if isDir.boolValue {
                let rel = subPath.isEmpty ? name : "\(subPath)/\(name)"
                videos.append(CmsVideo(id: rel, title: name, remarks: "本地文件夹", tag: folderTag))
            } else if isVideoFileName(name) {
                let playUrl = "mmlocal://play?path=\(qEnc(full))"
                videos.append(
                    CmsVideo(
                        id: full,
                        title: cleanMediaTitle(name),
                        remarks: (name as NSString).pathExtension.uppercased(),
                        lines: [CmsLine(name: "本地原画", episodes: [CmsEpisode(name: "正片", url: playUrl)])]
                    )
                )
            }
        }
        return CmsListing(page: 1, pageCount: 1, videos: videos)
    }

    // MARK: - HTTP Helpers

    private static func getJson(urlString: String, headers: [String: String], session: URLSession) async throws -> [String: Any] {
        guard let url = URL(string: urlString) else { throw MarcoError.invalidFormat("无效的媒体库请求地址") }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        req.httpMethod = "GET"
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let (data, resp) = try await session.marcoData(for: req)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw MarcoError.networkFailure("媒体库返回 HTTP \(http.statusCode)")
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private static func postJson(urlString: String, headers: [String: String], payload: [String: Any], session: URLSession) async throws -> [String: Any] {
        guard let url = URL(string: urlString) else { throw MarcoError.invalidFormat("无效的媒体库请求地址") }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, resp) = try await session.marcoData(for: req)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw MarcoError.networkFailure("媒体库返回 HTTP \(http.statusCode)")
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private static func qEnc(_ s: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#/")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}
