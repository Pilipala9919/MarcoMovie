// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only

import Foundation

public struct PersonalCloudPageResult: Hashable, Sendable {
    public let provider: NetdiskProvider
    public let folderId: String
    public let items: [PersonalCloudFile]
    public let page: Int
    public let hasMore: Bool
    public let nextMarker: String
    public let driveId: String

    public init(
        provider: NetdiskProvider,
        folderId: String,
        items: [PersonalCloudFile],
        page: Int,
        hasMore: Bool,
        nextMarker: String = "",
        driveId: String = ""
    ) {
        self.provider = provider
        self.folderId = folderId
        self.items = items
        self.page = page
        self.hasMore = hasMore
        self.nextMarker = nextMarker
        self.driveId = driveId
    }
}

/// Unified personal cloud drive browser & playback resolver for all 5 providers:
/// Quark, UC, Baidu, AliyunDrive, and 115.
public final class PersonalNetdiskLibrary: @unchecked Sendable {
    private static let ucUA =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) uc-cloud-drive/2.5.20 Chrome/100.0.4896.160 Safari/537.36"

    private let storage: IOSStorageManager
    private let session: URLSession

    public init(storage: IOSStorageManager, session: URLSession? = nil) {
        self.storage = storage
        if let session = session {
            self.session = session
        } else {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = 20
            cfg.timeoutIntervalForResource = 45
            cfg.httpShouldSetCookies = false
            cfg.httpCookieAcceptPolicy = .never
            self.session = URLSession(configuration: cfg)
        }
    }

    public func listFolder(
        provider: NetdiskProvider,
        folderId: String = "",
        page: Int = 1,
        marker: String = "",
        driveId: String = ""
    ) async throws -> PersonalCloudPageResult {
        let cred = storage.netdiskCredential(for: provider.rawValue)
        guard NetdiskSessionValidator.isUsable(driveKey: provider.rawValue, credential: cred) else {
            throw MarcoError.unsupportedSite("请先登录\(provider.displayName)账号后再浏览个人网盘")
        }
        let targetFolder = folderId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? provider.rootFolderId
            : folderId.trimmingCharacters(in: .whitespacesAndNewlines)

        switch provider {
        case .quark:
            return try await listQuarkFolder(cookie: NetdiskSessionValidator.extractCookieHeader(driveKey: "quark", credential: cred), folderId: targetFolder, page: max(1, page))
        case .uc:
            return try await listUcFolder(cookie: NetdiskSessionValidator.extractCookieHeader(driveKey: "uc", credential: cred), folderId: targetFolder, page: max(1, page))
        case .baidu:
            return try await listBaiduFolder(cookie: NetdiskSessionValidator.extractCookieHeader(driveKey: "baidu", credential: cred), folderPath: targetFolder, page: max(1, page))
        case .ali:
            guard let refresh = NetdiskSessionValidator.extractAliRefreshToken(from: cred) else {
                throw MarcoError.unsupportedSite("阿里云盘刷新令牌无效，请重新扫码登录")
            }
            return try await listAliFolder(refreshToken: refresh, folderId: targetFolder, page: max(1, page), marker: marker, driveId: driveId)
        case .drive115:
            return try await list115Folder(cookie: NetdiskSessionValidator.extractCookieHeader(driveKey: "115", credential: cred), cid: targetFolder, page: max(1, page))
        }
    }

    public func resolveFile(
        _ file: PersonalCloudFile,
        rangeProxy: NetdiskRangeProxyServer? = nil,
        headerProxy: LocalHeaderProxyServer? = nil
    ) async throws -> ResolvedPlayback {
        let cred = storage.netdiskCredential(for: file.provider.rawValue)
        guard NetdiskSessionValidator.isUsable(driveKey: file.provider.rawValue, credential: cred) else {
            throw MarcoError.unsupportedSite("请先登录\(file.provider.displayName)账号")
        }

        let resolved: (url: URL, policy: NetdiskHeaderPolicy)
        switch file.provider {
        case .quark:
            resolved = try await resolveQuarkFile(cookie: NetdiskSessionValidator.extractCookieHeader(driveKey: "quark", credential: cred), fid: file.id)
        case .uc:
            resolved = try await resolveUcFile(cookie: NetdiskSessionValidator.extractCookieHeader(driveKey: "uc", credential: cred), fid: file.id)
        case .baidu:
            resolved = try await resolveBaiduFile(cookie: NetdiskSessionValidator.extractCookieHeader(driveKey: "baidu", credential: cred), path: file.path)
        case .ali:
            guard let refresh = NetdiskSessionValidator.extractAliRefreshToken(from: cred) else {
                throw MarcoError.unsupportedSite("阿里云盘刷新令牌无效")
            }
            resolved = try await resolveAliFile(refreshToken: refresh, fileId: file.id, driveId: file.driveId)
        case .drive115:
            resolved = try await resolve115File(
                cookie: NetdiskSessionValidator.extractCookieHeader(driveKey: "115", credential: cred),
                pickCode: file.pickCode.isEmpty ? file.id : file.pickCode
            )
        }

        let badge = NetdiskShareResolver.inferResolutionBadge(from: file.name, fallbackQuality: "auto")
        let isHls = resolved.url.path.lowercased().hasSuffix(".m3u8")
        if isHls, let headerProxy = headerProxy {
            let (sid, loopback) = try await headerProxy.registerStreamWithId(url: resolved.url, policy: resolved.policy)
            return ResolvedPlayback(
                originalUrl: resolved.url.absoluteString,
                playableUrl: loopback,
                headers: resolved.policy.headers(for: resolved.url),
                isProxied: true,
                kernelLabel: "HLS 代理硬解",
                resolutionBadge: badge.isEmpty ? "HLS" : badge,
                headerProxySessionId: sid
            )
        }
        if let rangeProxy = rangeProxy {
            let (rid, loopback) = try await rangeProxy.registerStream(url: resolved.url, policy: resolved.policy)
            return ResolvedPlayback(
                originalUrl: resolved.url.absoluteString,
                playableUrl: loopback,
                headers: [:],
                isProxied: true,
                kernelLabel: "\(rangeProxy.workers) 线程分片代理",
                resolutionBadge: badge,
                rangeProxyResourceId: rid
            )
        }
        return ResolvedPlayback(
            originalUrl: resolved.url.absoluteString,
            playableUrl: resolved.url,
            headers: resolved.policy.headers(for: resolved.url),
            isProxied: false,
            kernelLabel: "AVPlayer 硬解",
            resolutionBadge: badge
        )
    }

    // MARK: - Provider Directory Implementations

    private func listQuarkFolder(cookie: String, folderId: String, page: Int) async throws -> PersonalCloudPageResult {
        let urlStr = "https://drive-pc.quark.cn/1/clouddrive/file/sort?pr=ucpro&fr=pc&pdir_fid=\(qEnc(folderId))&_page=\(page)&_size=100&_fetch_total=1&_sort=file_type:asc,file_name:asc"
        let root = try await getJson(
            urlString: urlStr,
            headers: ["Origin": "https://pan.quark.cn", "Referer": "https://pan.quark.cn/", "Cookie": cookie]
        )
        let dataMap = (root["data"] as? [String: Any]) ?? [:]
        let list = (dataMap["list"] as? [[String: Any]]) ?? []
        let items: [PersonalCloudFile] = list.compactMap { item in
            let fid = str(item["fid"])
            let name = str(item["file_name"])
            guard !fid.isEmpty, !name.isEmpty else { return nil }
            let isDir = ((item["dir"] as? Bool) == true) || ((item["file_type"] as? NSNumber)?.intValue == 0)
            return PersonalCloudFile(
                id: fid,
                provider: .quark,
                name: name,
                isDir: isDir,
                size: (item["size"] as? NSNumber)?.int64Value ?? 0,
                thumbnail: str(item["preview_url"])
            )
        }
        let total = ((root["metadata"] as? [String: Any])?["_total"] as? NSNumber)?.intValue ?? items.count
        return PersonalCloudPageResult(provider: .quark, folderId: folderId, items: items, page: page, hasMore: page * 100 < total)
    }

    private func resolveQuarkFile(cookie: String, fid: String) async throws -> (url: URL, policy: NetdiskHeaderPolicy) {
        let resp = try await postJson(
            urlString: "https://drive-pc.quark.cn/1/clouddrive/file/download?pr=ucpro&fr=pc",
            headers: [
                "Content-Type": "application/json;charset=UTF-8",
                "Origin": "https://pan.quark.cn",
                "Referer": "https://pan.quark.cn/",
                "Cookie": cookie,
            ],
            payload: ["fids": [fid]]
        )
        guard let list = resp["data"] as? [[String: Any]],
              let first = list.first,
              let dl = first["download_url"] as? String,
              let url = URL(string: dl)
        else {
            throw MarcoError.networkFailure("夸克个人网盘未返回下载地址")
        }
        let policy = NetdiskHeaderPolicy(
            originUrl: URL(string: "https://pan.quark.cn")!,
            baseHeaders: ["Cookie": cookie, "Origin": "https://pan.quark.cn", "Referer": "https://pan.quark.cn/"],
            cookieDomains: ["quark.cn"]
        )
        return (url, policy)
    }

    private func listUcFolder(cookie: String, folderId: String, page: Int) async throws -> PersonalCloudPageResult {
        let urlStr = "https://pc-api.uc.cn/1/clouddrive/file/sort?pr=UCBrowser&fr=pc&pdir_fid=\(qEnc(folderId))&_page=\(page)&_size=100&_fetch_total=1&_sort=file_type:asc,file_name:asc"
        let root = try await getJson(
            urlString: urlStr,
            headers: [
                "User-Agent": Self.ucUA,
                "Origin": "https://drive.uc.cn",
                "Referer": "https://drive.uc.cn/",
                "Cookie": cookie,
            ]
        )
        let dataMap = (root["data"] as? [String: Any]) ?? [:]
        let list = (dataMap["list"] as? [[String: Any]]) ?? []
        let items: [PersonalCloudFile] = list.compactMap { item in
            let fid = str(item["fid"])
            let name = str(item["file_name"])
            guard !fid.isEmpty, !name.isEmpty else { return nil }
            let isDir = ((item["dir"] as? Bool) == true) || ((item["file_type"] as? NSNumber)?.intValue == 0)
            return PersonalCloudFile(id: fid, provider: .uc, name: name, isDir: isDir, size: (item["size"] as? NSNumber)?.int64Value ?? 0)
        }
        let total = ((root["metadata"] as? [String: Any])?["_total"] as? NSNumber)?.intValue ?? items.count
        return PersonalCloudPageResult(provider: .uc, folderId: folderId, items: items, page: page, hasMore: page * 100 < total)
    }

    private func resolveUcFile(cookie: String, fid: String) async throws -> (url: URL, policy: NetdiskHeaderPolicy) {
        let resp = try await postJson(
            urlString: "https://pc-api.uc.cn/1/clouddrive/file/download?pr=UCBrowser&fr=pc",
            headers: [
                "User-Agent": Self.ucUA,
                "Content-Type": "application/json;charset=UTF-8",
                "Origin": "https://drive.uc.cn",
                "Referer": "https://drive.uc.cn/",
                "Cookie": cookie,
            ],
            payload: ["fids": [fid]]
        )
        guard let list = resp["data"] as? [[String: Any]],
              let first = list.first,
              let dl = first["download_url"] as? String,
              let url = URL(string: dl)
        else {
            throw MarcoError.networkFailure("UC 个人网盘未返回下载地址")
        }
        let policy = NetdiskHeaderPolicy(
            originUrl: URL(string: "https://drive.uc.cn")!,
            baseHeaders: ["Cookie": cookie, "User-Agent": Self.ucUA, "Origin": "https://drive.uc.cn", "Referer": "https://drive.uc.cn/"],
            cookieDomains: ["uc.cn"],
            defaultUserAgent: Self.ucUA
        )
        return (url, policy)
    }

    private func listBaiduFolder(cookie: String, folderPath: String, page: Int) async throws -> PersonalCloudPageResult {
        let urlStr = "https://pan.baidu.com/api/list?dir=\(qEnc(folderPath))&order=name&desc=0&web=1&page=\(page)&num=100&channel=chunlei&clienttype=0"
        let root = try await getJson(
            urlString: urlStr,
            headers: ["Referer": "https://pan.baidu.com/disk/main", "Cookie": cookie]
        )
        let list = (root["list"] as? [[String: Any]]) ?? []
        let items: [PersonalCloudFile] = list.compactMap { item in
            let fsId = str(item["fs_id"])
            let name = str(item["server_filename"])
            let path = str(item["path"])
            guard !fsId.isEmpty, !name.isEmpty else { return nil }
            let isDir = ((item["isdir"] as? NSNumber)?.intValue ?? 0) == 1
            return PersonalCloudFile(
                id: fsId,
                provider: .baidu,
                name: name,
                isDir: isDir,
                size: (item["size"] as? NSNumber)?.int64Value ?? 0,
                path: path
            )
        }
        return PersonalCloudPageResult(provider: .baidu, folderId: folderPath, items: items, page: page, hasMore: items.count >= 100)
    }

    private func resolveBaiduFile(cookie: String, path: String) async throws -> (url: URL, policy: NetdiskHeaderPolicy) {
        guard !path.isEmpty else { throw MarcoError.invalidFormat("百度网盘文件路径为空") }
        let streamStr = "https://pan.baidu.com/api/streaming?path=\(qEnc(path))&type=M3U8_AUTO_4K&app_id=250528"
        guard let url = URL(string: streamStr) else { throw MarcoError.invalidFormat("百度网盘流地址无效") }
        let policy = NetdiskHeaderPolicy(
            originUrl: URL(string: "https://pan.baidu.com")!,
            baseHeaders: ["Cookie": cookie, "Referer": "https://pan.baidu.com/"],
            cookieDomains: ["baidu.com", "baidupcs.com"]
        )
        return (url, policy)
    }

    private func exchangeAliToken(refreshToken: String) async throws -> (accessToken: String, driveId: String) {
        let resp = try await postJson(
            urlString: "https://auth.aliyundrive.com/v2/account/token",
            headers: ["Content-Type": "application/json;charset=UTF-8", "Referer": "https://www.aliyundrive.com/"],
            payload: ["refresh_token": refreshToken, "grant_type": "refresh_token"]
        )
        let accessToken = str(resp["access_token"])
        let driveId = str(resp["resource_drive_id"]).isEmpty ? str(resp["default_drive_id"]) : str(resp["resource_drive_id"])
        guard !accessToken.isEmpty else { throw MarcoError.networkFailure("阿里云盘访问令牌刷新失败") }
        return (accessToken, driveId)
    }

    private func listAliFolder(refreshToken: String, folderId: String, page: Int, marker: String, driveId: String) async throws -> PersonalCloudPageResult {
        let sessionInfo = try await exchangeAliToken(refreshToken: refreshToken)
        let activeDrive = driveId.isEmpty ? sessionInfo.driveId : driveId
        var payload: [String: Any] = [
            "drive_id": activeDrive,
            "parent_file_id": folderId,
            "limit": 100,
            "order_by": "name",
            "order_direction": "ASC",
        ]
        if !marker.isEmpty { payload["marker"] = marker }
        let root = try await postJson(
            urlString: "https://api.aliyundrive.com/adrive/v3/file/list",
            headers: [
                "Content-Type": "application/json;charset=UTF-8",
                "Authorization": "Bearer \(sessionInfo.accessToken)",
                "Referer": "https://www.aliyundrive.com/",
            ],
            payload: payload
        )
        let list = (root["items"] as? [[String: Any]]) ?? []
        let items: [PersonalCloudFile] = list.compactMap { item in
            let fid = str(item["file_id"])
            let name = str(item["name"])
            guard !fid.isEmpty, !name.isEmpty else { return nil }
            let isDir = str(item["type"]).lowercased() == "folder"
            return PersonalCloudFile(
                id: fid,
                provider: .ali,
                name: name,
                isDir: isDir,
                size: (item["size"] as? NSNumber)?.int64Value ?? 0,
                thumbnail: str(item["thumbnail"]),
                driveId: activeDrive
            )
        }
        let nextMarker = str(root["next_marker"])
        return PersonalCloudPageResult(
            provider: .ali,
            folderId: folderId,
            items: items,
            page: page,
            hasMore: !nextMarker.isEmpty,
            nextMarker: nextMarker,
            driveId: activeDrive
        )
    }

    private func resolveAliFile(refreshToken: String, fileId: String, driveId: String) async throws -> (url: URL, policy: NetdiskHeaderPolicy) {
        let sessionInfo = try await exchangeAliToken(refreshToken: refreshToken)
        let activeDrive = driveId.isEmpty ? sessionInfo.driveId : driveId
        let resp = try await postJson(
            urlString: "https://api.aliyundrive.com/v2/file/get_download_url",
            headers: [
                "Content-Type": "application/json;charset=UTF-8",
                "Authorization": "Bearer \(sessionInfo.accessToken)",
                "Referer": "https://www.aliyundrive.com/",
            ],
            payload: ["drive_id": activeDrive, "file_id": fileId]
        )
        guard let urlStr = resp["url"] as? String, let url = URL(string: urlStr) else {
            throw MarcoError.networkFailure("阿里云盘未返回有效文件下载地址")
        }
        let policy = NetdiskHeaderPolicy(
            originUrl: URL(string: "https://www.alipan.com")!,
            baseHeaders: ["Authorization": "Bearer \(sessionInfo.accessToken)", "Referer": "https://www.alipan.com/"],
            cookieDomains: ["alipan.com", "aliyundrive.com", "aliyundrive.net", "aliyunpds.com"]
        )
        return (url, policy)
    }

    private func list115Folder(cookie: String, cid: String, page: Int) async throws -> PersonalCloudPageResult {
        let offset = max(0, (page - 1) * 100)
        let urlStr = "https://webapi.115.com/files?aid=1&cid=\(qEnc(cid))&o=file_name&asc=1&offset=\(offset)&limit=100&show_dir=1&format=json"
        let root = try await getJson(
            urlString: urlStr,
            headers: ["Referer": "https://115.com/", "Cookie": cookie]
        )
        let list = (root["data"] as? [[String: Any]]) ?? []
        let items: [PersonalCloudFile] = list.compactMap { item in
            let fid = str(item["fid"])
            let childCid = str(item["cid"])
            let name = str(item["n"])
            guard !name.isEmpty else { return nil }
            let isDir = fid.isEmpty
            let id = isDir ? childCid : fid
            guard !id.isEmpty else { return nil }
            return PersonalCloudFile(
                id: id,
                provider: .drive115,
                name: name,
                isDir: isDir,
                size: (item["s"] as? NSNumber)?.int64Value ?? 0,
                pickCode: str(item["pc"])
            )
        }
        let total = (root["count"] as? NSNumber)?.intValue ?? items.count
        return PersonalCloudPageResult(provider: .drive115, folderId: cid, items: items, page: page, hasMore: offset + items.count < total)
    }

    private func resolve115File(cookie: String, pickCode: String) async throws -> (url: URL, policy: NetdiskHeaderPolicy) {
        let resp = try await getJson(
            urlString: "https://webapi.115.com/files/download?pickcode=\(qEnc(pickCode))",
            headers: ["Referer": "https://115.com/", "Cookie": cookie]
        )
        let urlStr = str(resp["file_url"])
        guard !urlStr.isEmpty, let url = URL(string: urlStr) else {
            throw MarcoError.networkFailure("115 个人网盘未返回下载地址")
        }
        let policy = NetdiskHeaderPolicy(
            originUrl: URL(string: "https://115.com")!,
            baseHeaders: ["Cookie": cookie, "Origin": "https://115.com", "Referer": "https://115.com/"],
            cookieDomains: ["115.com", "115cdn.com", "anxia.com"]
        )
        return (url, policy)
    }

    // MARK: - HTTP Helpers

    private func getJson(urlString: String, headers: [String: String]) async throws -> [String: Any] {
        guard let url = URL(string: urlString) else { throw MarcoError.invalidFormat("无效的个人网盘请求地址") }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        req.httpMethod = "GET"
        req.httpShouldHandleCookies = false
        req.setValue(NetdiskService.desktopChromeUA, forHTTPHeaderField: "User-Agent")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let (data, resp) = try await session.marcoData(for: req)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw MarcoError.networkFailure("网盘接口返回 HTTP \(http.statusCode)")
        }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw MarcoError.invalidFormat("网盘接口未返回有效 JSON")
        }
        return obj
    }

    private func postJson(urlString: String, headers: [String: String], payload: [String: Any]) async throws -> [String: Any] {
        guard let url = URL(string: urlString) else { throw MarcoError.invalidFormat("无效的个人网盘请求地址") }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.httpShouldHandleCookies = false
        req.setValue(NetdiskService.desktopChromeUA, forHTTPHeaderField: "User-Agent")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, resp) = try await session.marcoData(for: req)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw MarcoError.networkFailure("网盘接口返回 HTTP \(http.statusCode)")
        }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw MarcoError.invalidFormat("网盘接口未返回有效 JSON")
        }
        return obj
    }

    private func qEnc(_ s: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#/")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    private func str(_ any: Any?) -> String {
        guard let any = any, !(any is NSNull) else { return "" }
        if let s = any as? String { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let n = any as? NSNumber { return n.stringValue }
        return ""
    }
}
