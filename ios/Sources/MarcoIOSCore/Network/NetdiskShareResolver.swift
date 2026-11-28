// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// Resolves Netdisk share links across all 5 drives (Quark, UC, Baidu, AliyunDrive, 115)
/// into playable 4K/1080P media streams backed by `NetdiskRangeProxyServer` or `LocalHeaderProxyServer`
/// with origin-isolated credentials.
public final class NetdiskShareResolver: @unchecked Sendable {
    private static let videoExtensions: Set<String> = [
        "mkv", "mp4", "m4v", "mov", "ts", "m2ts", "avi", "flv", "webm", "m3u8",
    ]

    private let session: URLSession

    public init(session: URLSession? = nil) {
        if let session = session {
            self.session = session
        } else {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = 18
            cfg.timeoutIntervalForResource = 40
            cfg.httpShouldSetCookies = false
            cfg.httpCookieAcceptPolicy = .never
            self.session = URLSession(configuration: cfg)
        }
    }

    // MARK: - Detection & Policy

    public static func detectDriveKey(for rawUrl: String, lineName: String = "") -> String? {
        let lowerUrl = rawUrl.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lowerUrl.hasPrefix("mmquark://") || lowerUrl.hasPrefix("mmwogg://quark") || lowerUrl.contains("quark.cn/") {
            return "quark"
        }
        if lowerUrl.hasPrefix("mmwogg://uc") || lowerUrl.contains("drive.uc.cn/") || lowerUrl.contains(".uc.cn/") {
            return "uc"
        }
        if lowerUrl.hasPrefix("mmwogg://baidu") || lowerUrl.contains("pan.baidu.com/") || lowerUrl.contains(".baidu.com/") {
            return "baidu"
        }
        if lowerUrl.hasPrefix("mmwogg://ali")
            || lowerUrl.contains("alipan.com/")
            || lowerUrl.contains("aliyundrive.com/")
        {
            return "ali"
        }
        if lowerUrl.hasPrefix("mm115://")
            || lowerUrl.hasPrefix("mmwogg://115")
            || lowerUrl.contains("115.com/s/")
            || lowerUrl.contains("115cdn.com/s/")
            || lowerUrl.contains("anxia.com/s/")
        {
            return "115"
        }

        let lowerLine = lineName.lowercased()
        if lowerLine.contains("夸父") || lowerLine.contains("夸克") { return "quark" }
        if lowerLine.contains("优汐") { return "uc" }
        if lowerLine.contains("嘟嘟") { return "baidu" }
        if lowerLine.contains("阿狸") { return "ali" }
        if lowerLine.contains("115") { return "115" }
        return nil
    }

    public static func isSharePageOrCustomScheme(_ rawUrl: String) -> Bool {
        let lower = rawUrl.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
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

    public static func buildPolicy(
        driveKey: String,
        credential: String,
        extraHeaders: [String: String] = [:]
    ) -> NetdiskHeaderPolicy? {
        guard let driveInfo = NetdiskDriveInfo.info(for: driveKey),
              let originUrl = URL(string: driveInfo.defaultOrigin)
        else {
            return nil
        }

        var headers = extraHeaders.filter { key, _ in
            let lower = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return lower != "x-ali-refresh-token" && lower != "refresh-token" && lower != "x-refresh-token"
        }
        headers["Origin"] = driveInfo.defaultOrigin
        headers["Referer"] = "\(driveInfo.defaultOrigin)/"
        headers["User-Agent"] = NetdiskService.desktopChromeUA

        if driveKey != "ali" {
            let cookieHeader = NetdiskSessionValidator.extractCookieHeader(driveKey: driveKey, credential: credential)
            if !cookieHeader.isEmpty { headers["Cookie"] = cookieHeader }
        }

        return NetdiskHeaderPolicy(
            originUrl: originUrl,
            baseHeaders: headers,
            cookieDomains: driveInfo.trustedDomains
        )
    }

    // MARK: - Main Resolution Entrypoint

    public func resolvePlayback(
        rawUrl: String,
        lineName: String = "",
        extraHeaders: [String: String] = [:],
        qualityPreference: String = "auto",
        playerKernel: String = "range_proxy",
        storage: IOSStorageManager,
        rangeProxy: NetdiskRangeProxyServer?,
        headerProxy: LocalHeaderProxyServer? = nil
    ) async throws -> ResolvedPlayback {
        let trimmed = rawUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let driveKey = Self.detectDriveKey(for: trimmed, lineName: lineName),
              let driveInfo = NetdiskDriveInfo.info(for: driveKey)
        else {
            throw MarcoError.invalidFormat("无法识别的网盘分享地址")
        }

        let credential = storage.netdiskCredential(for: driveKey)
        guard NetdiskSessionValidator.isUsable(driveKey: driveKey, credential: credential) else {
            throw MarcoError.unsupportedSite("请先在「设置 -> 4K 网盘账号」登录\(driveInfo.tvName)（\(driveInfo.providerName)）")
        }

        let resolvedTarget: (streamUrl: URL, policy: NetdiskHeaderPolicy, badge: String)
        if Self.isSharePageOrCustomScheme(trimmed) {
            switch driveKey {
            case "quark":
                resolvedTarget = try await resolveQuarkShare(
                    rawUrl: trimmed,
                    credential: credential,
                    qualityPreference: qualityPreference,
                    extraHeaders: extraHeaders
                )
            case "uc":
                resolvedTarget = try await resolveUcShare(rawUrl: trimmed, credential: credential, extraHeaders: extraHeaders)
            case "baidu":
                resolvedTarget = try await resolveBaiduShare(rawUrl: trimmed, credential: credential, extraHeaders: extraHeaders)
            case "ali":
                resolvedTarget = try await resolveAliShare(
                    rawUrl: trimmed,
                    credential: credential,
                    qualityPreference: qualityPreference,
                    extraHeaders: extraHeaders
                )
            case "115":
                resolvedTarget = try await resolve115Share(rawUrl: trimmed, credential: credential, extraHeaders: extraHeaders)
            default:
                throw MarcoError.unsupportedSite("暂不支持该网盘类型：\(driveKey)")
            }
        } else {
            guard let directUrl = URL(string: CmsParser.normalizeUrl(trimmed)),
                  let policy = Self.buildPolicy(driveKey: driveKey, credential: credential, extraHeaders: extraHeaders)
            else {
                throw MarcoError.invalidFormat("无效的网盘直链地址")
            }
            let inferredBadge = Self.inferResolutionBadge(from: trimmed, fallbackQuality: qualityPreference)
            resolvedTarget = (directUrl, policy, inferredBadge)
        }

        let isHls = resolvedTarget.streamUrl.path.lowercased().hasSuffix(".m3u8")
            || resolvedTarget.streamUrl.absoluteString.lowercased().contains(".m3u8")

        if isHls, let headerProxy = headerProxy {
            let outbound = resolvedTarget.policy.headers(for: resolvedTarget.streamUrl)
            let (sessionId, loopback) = try await headerProxy.registerStreamWithId(
                url: resolvedTarget.streamUrl,
                policy: resolvedTarget.policy
            )
            return ResolvedPlayback(
                originalUrl: resolvedTarget.streamUrl.absoluteString,
                playableUrl: loopback,
                headers: outbound,
                isProxied: true,
                kernelLabel: "HLS 代理硬解",
                resolutionBadge: resolvedTarget.badge.isEmpty ? "HLS" : resolvedTarget.badge,
                headerProxySessionId: sessionId
            )
        }

        if playerKernel != "avkit", let rangeProxy = rangeProxy {
            let (resourceId, proxyUrl) = try await rangeProxy.registerStream(
                url: resolvedTarget.streamUrl,
                policy: resolvedTarget.policy
            )
            return ResolvedPlayback(
                originalUrl: resolvedTarget.streamUrl.absoluteString,
                playableUrl: proxyUrl,
                headers: [:],
                isProxied: true,
                kernelLabel: "\(rangeProxy.workers) 线程分片代理",
                resolutionBadge: resolvedTarget.badge,
                rangeProxyResourceId: resourceId
            )
        }

        let fallbackHeaders = resolvedTarget.policy.headers(for: resolvedTarget.streamUrl)
        if let headerProxy = headerProxy {
            let (sessionId, loopback) = try await headerProxy.registerStreamWithId(
                url: resolvedTarget.streamUrl,
                policy: resolvedTarget.policy
            )
            return ResolvedPlayback(
                originalUrl: resolvedTarget.streamUrl.absoluteString,
                playableUrl: loopback,
                headers: fallbackHeaders,
                isProxied: true,
                kernelLabel: "AVPlayer 硬解",
                resolutionBadge: resolvedTarget.badge,
                headerProxySessionId: sessionId
            )
        }

        return ResolvedPlayback(
            originalUrl: resolvedTarget.streamUrl.absoluteString,
            playableUrl: resolvedTarget.streamUrl,
            headers: fallbackHeaders,
            isProxied: false,
            kernelLabel: "AVPlayer 硬解",
            resolutionBadge: resolvedTarget.badge
        )
    }

    // MARK: - 1. Quark

    private func resolveQuarkShare(
        rawUrl: String,
        credential: String,
        qualityPreference: String,
        extraHeaders: [String: String]
    ) async throws -> (streamUrl: URL, policy: NetdiskHeaderPolicy, badge: String) {
        let cookie = NetdiskSessionValidator.extractCookieHeader(driveKey: "quark", credential: credential)
        let parsed = Self.parseShareDescriptor(rawUrl)
        guard !parsed.shareId.isEmpty else { throw MarcoError.invalidFormat("夸克分享链接缺少 pwd_id") }

        let commonHeaders = [
            "Accept": "application/json, text/plain, */*",
            "Content-Type": "application/json;charset=UTF-8",
            "Origin": "https://pan.quark.cn",
            "Referer": "https://pan.quark.cn/",
            "Cookie": cookie,
        ]

        let tokenResp = try await postJson(
            urlString: "https://drive-pc.quark.cn/1/clouddrive/share/sharepage/token?pr=ucpro&fr=pc",
            headers: commonHeaders,
            payload: ["pwd_id": parsed.shareId, "passcode": parsed.passcode]
        )
        let tokenData = (tokenResp["data"] as? [String: Any]) ?? [:]
        let stoken = Self.str(tokenData["stoken"])
        guard !stoken.isEmpty else {
            let msg = Self.str(tokenResp["message"])
            throw MarcoError.networkFailure(msg.isEmpty ? "获取夸克分享 stoken 失败" : msg)
        }

        let selectedFile = try await findShareVideoFile(
            detailEndpointBase: "https://drive-pc.quark.cn/1/clouddrive/share/sharepage/detail?pr=ucpro&fr=pc",
            pwdId: parsed.shareId,
            stoken: stoken,
            preferredFid: parsed.fid,
            headers: commonHeaders
        )

        var chosenStreamUrl: URL?
        var chosenBadge = ""

        if let playResp = try? await postJson(
            urlString: "https://drive-pc.quark.cn/1/clouddrive/file/v2/play?pr=ucpro&fr=pc",
            headers: commonHeaders,
            payload: [
                "fid": selectedFile.fid,
                "pwd_id": parsed.shareId,
                "stoken": stoken,
                "share_fid_token": selectedFile.shareFidToken,
                "resolutions": "normal,low,high,super,2k,4k",
                "supports": "fmp4,m3u8",
            ]
        ),
           let dataObj = playResp["data"] as? [String: Any],
           let videoList = dataObj["video_list"] as? [[String: Any]]
        {
            if let best = Self.pickBestQuarkVariant(from: videoList, qualityPreference: qualityPreference) {
                chosenStreamUrl = best.url
                chosenBadge = best.badge
            }
        }

        if chosenStreamUrl == nil || (qualityPreference == "4k_hdr" && chosenBadge != "4K HDR") {
            if let dlResp = try? await postJson(
                urlString: "https://drive-pc.quark.cn/1/clouddrive/file/download?pr=ucpro&fr=pc",
                headers: commonHeaders,
                payload: [
                    "fids": [selectedFile.fid],
                    "pwd_id": parsed.shareId,
                    "stoken": stoken,
                    "share_fid_tokens": [selectedFile.shareFidToken],
                ]
            ),
               let dlList = dlResp["data"] as? [[String: Any]],
               let firstDl = dlList.first,
               let dlUrlStr = (firstDl["download_url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               let dlUrl = URL(string: dlUrlStr)
            {
                chosenStreamUrl = dlUrl
                chosenBadge = Self.inferResolutionBadge(from: selectedFile.fileName, fallbackQuality: "4k_hdr")
            }
        }

        guard let finalStreamUrl = chosenStreamUrl else {
            throw MarcoError.networkFailure("未能从夸克网盘获取到可播放的 4K/高清媒体流地址")
        }

        var merged = extraHeaders
        merged["Cookie"] = cookie
        merged["Origin"] = "https://pan.quark.cn"
        merged["Referer"] = "https://pan.quark.cn/"
        let policy = NetdiskHeaderPolicy(
            originUrl: URL(string: "https://pan.quark.cn")!,
            baseHeaders: merged,
            cookieDomains: ["quark.cn"]
        )
        return (finalStreamUrl, policy, chosenBadge)
    }

    // MARK: - 2. UC

    private func resolveUcShare(
        rawUrl: String,
        credential: String,
        extraHeaders: [String: String]
    ) async throws -> (streamUrl: URL, policy: NetdiskHeaderPolicy, badge: String) {
        let cookie = NetdiskSessionValidator.extractCookieHeader(driveKey: "uc", credential: credential)
        let parsed = Self.parseShareDescriptor(rawUrl)
        guard !parsed.shareId.isEmpty else { throw MarcoError.invalidFormat("UC 网盘分享链接缺少 pwd_id") }

        let commonHeaders = [
            "Accept": "application/json, text/plain, */*",
            "Content-Type": "application/json;charset=UTF-8",
            "Origin": "https://drive.uc.cn",
            "Referer": "https://drive.uc.cn/",
            "Cookie": cookie,
        ]

        let tokenResp = try await postJson(
            urlString: "https://drive.uc.cn/1/clouddrive/share/sharepage/token?pr=UCBrowser&fr=pc",
            headers: commonHeaders,
            payload: ["pwd_id": parsed.shareId, "passcode": parsed.passcode]
        )
        let tokenData = (tokenResp["data"] as? [String: Any]) ?? [:]
        let stoken = Self.str(tokenData["stoken"])
        guard !stoken.isEmpty else { throw MarcoError.networkFailure("获取 UC 网盘分享 stoken 失败") }

        let selectedFile = try await findShareVideoFile(
            detailEndpointBase: "https://drive.uc.cn/1/clouddrive/share/sharepage/detail?pr=UCBrowser&fr=pc",
            pwdId: parsed.shareId,
            stoken: stoken,
            preferredFid: parsed.fid,
            headers: commonHeaders
        )

        let dlResp = try await postJson(
            urlString: "https://drive.uc.cn/1/clouddrive/file/download?pr=UCBrowser&fr=pc",
            headers: commonHeaders,
            payload: [
                "fids": [selectedFile.fid],
                "pwd_id": parsed.shareId,
                "stoken": stoken,
                "share_fid_tokens": [selectedFile.shareFidToken],
            ]
        )
        guard let dlList = dlResp["data"] as? [[String: Any]],
              let firstDl = dlList.first,
              let dlUrlStr = (firstDl["download_url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let finalUrl = URL(string: dlUrlStr)
        else {
            throw MarcoError.networkFailure("UC 网盘未返回有效下载地址（请确认登录态未过期）")
        }

        var merged = extraHeaders
        merged["Cookie"] = cookie
        merged["Origin"] = "https://drive.uc.cn"
        merged["Referer"] = "https://drive.uc.cn/"
        let policy = NetdiskHeaderPolicy(
            originUrl: URL(string: "https://drive.uc.cn")!,
            baseHeaders: merged,
            cookieDomains: ["uc.cn"]
        )
        let badge = Self.inferResolutionBadge(from: selectedFile.fileName, fallbackQuality: "auto")
        return (finalUrl, policy, badge.isEmpty ? "UC 原画" : badge)
    }

    // MARK: - 3. Baidu

    private func resolveBaiduShare(
        rawUrl: String,
        credential: String,
        extraHeaders: [String: String]
    ) async throws -> (streamUrl: URL, policy: NetdiskHeaderPolicy, badge: String) {
        let cookie = NetdiskSessionValidator.extractCookieHeader(driveKey: "baidu", credential: credential)
        let parsed = Self.parseShareDescriptor(rawUrl)
        guard !parsed.shareId.isEmpty else { throw MarcoError.invalidFormat("百度网盘分享链接格式无效") }

        let shortKey = parsed.shareId.hasPrefix("1") ? String(parsed.shareId.dropFirst()) : parsed.shareId
        let listUrl = "https://pan.baidu.com/share/list?shorturl=\(Self.queryEncode(shortKey))&root=1&page=1&num=100&channel=chunlei&web=1&clienttype=0"
        let listResp = try await getJson(
            urlString: listUrl,
            headers: [
                "Accept": "application/json, text/plain, */*",
                "Referer": "https://pan.baidu.com/",
                "Cookie": cookie,
            ]
        )
        let items = (listResp["list"] as? [[String: Any]]) ?? []
        let chosen = items.first(where: { !parsed.fid.isEmpty && Self.str($0["fs_id"]) == parsed.fid })
            ?? items.first(where: { Self.isVideoFilename(Self.str($0["server_filename"])) })
            ?? items.first

        guard let item = chosen else { throw MarcoError.networkFailure("百度网盘分享目录中未找到可播放视频") }
        let dlink = Self.str(item["dlink"])
        let filePath = Self.str(item["path"])
        let fileName = Self.str(item["server_filename"])

        let streamUrlStr: String
        if !dlink.isEmpty {
            streamUrlStr = dlink
        } else if !filePath.isEmpty {
            streamUrlStr = "https://pan.baidu.com/api/streaming?path=\(Self.queryEncode(filePath))&type=M3U8_AUTO_4K&app_id=250528"
        } else {
            throw MarcoError.networkFailure("百度网盘未返回可播放流链接")
        }

        guard let finalUrl = URL(string: streamUrlStr) else {
            throw MarcoError.invalidFormat("百度网盘播放地址无效")
        }

        var merged = extraHeaders
        merged["Cookie"] = cookie
        merged["Origin"] = "https://pan.baidu.com"
        merged["Referer"] = "https://pan.baidu.com/"
        let policy = NetdiskHeaderPolicy(
            originUrl: URL(string: "https://pan.baidu.com")!,
            baseHeaders: merged,
            cookieDomains: ["baidu.com", "baidupcs.com"]
        )
        let badge = Self.inferResolutionBadge(from: fileName, fallbackQuality: "auto")
        return (finalUrl, policy, badge.isEmpty ? "蓝光" : badge)
    }

    // MARK: - 4. AliyunDrive

    private func resolveAliShare(
        rawUrl: String,
        credential: String,
        qualityPreference: String,
        extraHeaders: [String: String]
    ) async throws -> (streamUrl: URL, policy: NetdiskHeaderPolicy, badge: String) {
        guard let refreshToken = NetdiskSessionValidator.extractAliRefreshToken(from: credential) else {
            throw MarcoError.unsupportedSite("阿里云盘 refreshToken 无效，请重新扫码登录")
        }
        let parsed = Self.parseShareDescriptor(rawUrl)
        guard !parsed.shareId.isEmpty else { throw MarcoError.invalidFormat("阿里云盘分享链接缺少 share_id") }

        let authResp = try await postJson(
            urlString: "https://www.alipan.com/v2/account/token",
            headers: [
                "Content-Type": "application/json;charset=UTF-8",
                "Origin": "https://www.alipan.com",
                "Referer": "https://www.alipan.com/",
            ],
            payload: ["refresh_token": refreshToken, "grant_type": "refresh_token"]
        )
        let accessToken = Self.str(authResp["access_token"])
        guard !accessToken.isEmpty else {
            throw MarcoError.networkFailure("阿里云盘访问令牌刷新失败，请重新扫码授权")
        }

        let shareTokenResp = try await postJson(
            urlString: "https://www.alipan.com/v2/share_link/get_share_token",
            headers: [
                "Content-Type": "application/json;charset=UTF-8",
                "Authorization": "Bearer \(accessToken)",
                "Origin": "https://www.alipan.com",
                "Referer": "https://www.alipan.com/",
            ],
            payload: ["share_id": parsed.shareId, "share_pwd": parsed.passcode]
        )
        let shareToken = Self.str(shareTokenResp["share_token"])
        guard !shareToken.isEmpty else { throw MarcoError.networkFailure("获取阿里云盘 share_token 失败") }

        let authedHeaders = [
            "Content-Type": "application/json;charset=UTF-8",
            "Authorization": "Bearer \(accessToken)",
            "X-Share-Token": shareToken,
            "Origin": "https://www.alipan.com",
            "Referer": "https://www.alipan.com/",
        ]

        var targetFileId = parsed.fid
        var targetFileName = ""
        if targetFileId.isEmpty {
            let listResp = try await postJson(
                urlString: "https://www.alipan.com/adrive/v3/file/list_by_share",
                headers: authedHeaders,
                payload: [
                    "share_id": parsed.shareId,
                    "parent_file_id": "root",
                    "limit": 100,
                    "order_by": "name",
                    "order_direction": "ASC",
                ]
            )
            let items = (listResp["items"] as? [[String: Any]]) ?? []
            let bestVideo = items.first(where: { Self.str($0["category"]) == "video" || Self.isVideoFilename(Self.str($0["name"])) })
                ?? items.first
            targetFileId = Self.str(bestVideo?["file_id"])
            targetFileName = Self.str(bestVideo?["name"])
        }
        guard !targetFileId.isEmpty else { throw MarcoError.networkFailure("阿里云盘分享中未找到可播放视频文件") }

        let playResp = try await postJson(
            urlString: "https://www.alipan.com/v2/file/get_share_link_video_preview_play_info",
            headers: authedHeaders,
            payload: [
                "share_id": parsed.shareId,
                "file_id": targetFileId,
                "category": "live_transcoding",
                "template_id": "",
                "get_subtitle_info": true,
            ]
        )
        let previewInfo = (playResp["video_preview_play_info"] as? [String: Any]) ?? playResp
        let tasks = (previewInfo["live_transcoding_task_list"] as? [[String: Any]]) ?? []

        let preferredTemplates: [String] = (qualityPreference == "1080p")
            ? ["FHD", "QHD", "HD", "UHD", "SD"]
            : ["UHD", "QHD", "FHD", "HD", "SD"]

        var selectedUrl: URL?
        var badge = ""
        for tpl in preferredTemplates {
            if let matched = tasks.first(where: { Self.str($0["template_id"]).uppercased() == tpl }),
               let urlStr = (matched["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               let parsedUrl = URL(string: urlStr)
            {
                selectedUrl = parsedUrl
                badge = (tpl == "UHD") ? "4K HDR" : (tpl == "QHD" ? "2K" : "1080P")
                break
            }
        }
        if selectedUrl == nil,
           let fallbackTask = tasks.last(where: { !Self.str($0["url"]).isEmpty }),
           let parsedUrl = URL(string: Self.str(fallbackTask["url"]))
        {
            selectedUrl = parsedUrl
            badge = Self.inferResolutionBadge(from: targetFileName, fallbackQuality: qualityPreference)
        }

        guard let finalUrl = selectedUrl else { throw MarcoError.networkFailure("阿里云盘未返回可用视频预览流") }

        var merged = extraHeaders
        merged["Authorization"] = "Bearer \(accessToken)"
        merged["Origin"] = "https://www.alipan.com"
        merged["Referer"] = "https://www.alipan.com/"
        let policy = NetdiskHeaderPolicy(
            originUrl: URL(string: "https://www.alipan.com")!,
            baseHeaders: merged,
            cookieDomains: ["alipan.com", "aliyundrive.com", "aliyundrive.net", "aliyunpds.com"]
        )
        return (finalUrl, policy, badge)
    }

    // MARK: - 5. 115 Cloud Drive

    private func resolve115Share(
        rawUrl: String,
        credential: String,
        extraHeaders: [String: String]
    ) async throws -> (streamUrl: URL, policy: NetdiskHeaderPolicy, badge: String) {
        let cookie = NetdiskSessionValidator.extractCookieHeader(driveKey: "115", credential: credential)
        let parsed = Self.parseShareDescriptor(rawUrl)
        guard !parsed.shareId.isEmpty else { throw MarcoError.invalidFormat("115 分享链接缺少 share_code") }

        let headers = [
            "Accept": "application/json, text/plain, */*",
            "Origin": "https://115.com",
            "Referer": "https://115.com/",
            "Cookie": cookie,
        ]
        let snapUrl = "https://webapi.115.com/share/snap?share_code=\(Self.queryEncode(parsed.shareId))&receive_code=\(Self.queryEncode(parsed.passcode))&offset=0&limit=100&cid=0"
        let snapResp = try await getJson(urlString: snapUrl, headers: headers)
        let dataMap = (snapResp["data"] as? [String: Any]) ?? [:]
        let list = (dataMap["list"] as? [[String: Any]]) ?? []
        let chosen = list.first(where: { !parsed.fid.isEmpty && (Self.str($0["fid"]) == parsed.fid || Self.str($0["pc"]) == parsed.fid) })
            ?? list.first(where: { Self.isVideoFilename(Self.str($0["n"])) })
            ?? list.first
        guard let item = chosen else { throw MarcoError.networkFailure("115 分享目录中未找到可播放视频") }

        let pickCode = Self.str(item["pc"])
        let fileName = Self.str(item["n"])
        let targetCode = !pickCode.isEmpty ? pickCode : parsed.fid
        guard !targetCode.isEmpty else { throw MarcoError.networkFailure("115 文件缺少 pick_code") }

        let downResp = try await getJson(
            urlString: "https://webapi.115.com/files/download?pickcode=\(Self.queryEncode(targetCode))",
            headers: headers
        )
        let directUrlStr = Self.str(downResp["file_url"])
        guard !directUrlStr.isEmpty, let finalUrl = URL(string: directUrlStr) else {
            throw MarcoError.networkFailure("115 未返回有效直链，请检查会话或 VIP 权限")
        }

        var merged = extraHeaders
        merged["Cookie"] = cookie
        merged["Origin"] = "https://115.com"
        merged["Referer"] = "https://115.com/"
        let policy = NetdiskHeaderPolicy(
            originUrl: URL(string: "https://115.com")!,
            baseHeaders: merged,
            cookieDomains: ["115.com", "115cdn.com", "anxia.com"]
        )
        let badge = Self.inferResolutionBadge(from: fileName, fallbackQuality: "auto")
        return (finalUrl, policy, badge.isEmpty ? "115 原画" : badge)
    }

    // MARK: - Internal Share Tree & Variant Helpers

    private struct ShareVideoEntry {
        let fid: String
        let shareFidToken: String
        let fileName: String
        let size: Int64
    }

    private func findShareVideoFile(
        detailEndpointBase: String,
        pwdId: String,
        stoken: String,
        preferredFid: String,
        headers: [String: String]
    ) async throws -> ShareVideoEntry {
        let rootEntries = try await fetchShareDirectory(
            detailEndpointBase: detailEndpointBase,
            pwdId: pwdId,
            stoken: stoken,
            pdirFid: "0",
            headers: headers
        )
        if let exact = rootEntries.first(where: { !preferredFid.isEmpty && $0.fid == preferredFid && !$0.isDir }) {
            return ShareVideoEntry(fid: exact.fid, shareFidToken: exact.shareFidToken, fileName: exact.fileName, size: exact.size)
        }

        var videoCandidates = rootEntries.filter { !$0.isDir && Self.isVideoFilename($0.fileName) }
        if videoCandidates.isEmpty {
            for folder in rootEntries.filter(\.isDir).prefix(3) {
                if let subEntries = try? await fetchShareDirectory(
                    detailEndpointBase: detailEndpointBase,
                    pwdId: pwdId,
                    stoken: stoken,
                    pdirFid: folder.fid,
                    headers: headers
                ) {
                    if let exactSub = subEntries.first(where: { !preferredFid.isEmpty && $0.fid == preferredFid && !$0.isDir }) {
                        return ShareVideoEntry(fid: exactSub.fid, shareFidToken: exactSub.shareFidToken, fileName: exactSub.fileName, size: exactSub.size)
                    }
                    videoCandidates.append(contentsOf: subEntries.filter { !$0.isDir && Self.isVideoFilename($0.fileName) })
                }
            }
        }

        if let best = videoCandidates.max(by: { $0.size < $1.size }) ?? rootEntries.first(where: { !$0.isDir }) {
            return ShareVideoEntry(fid: best.fid, shareFidToken: best.shareFidToken, fileName: best.fileName, size: best.size)
        }
        throw MarcoError.networkFailure("网盘分享链接中未找到可播放视频文件")
    }

    private func fetchShareDirectory(
        detailEndpointBase: String,
        pwdId: String,
        stoken: String,
        pdirFid: String,
        headers: [String: String]
    ) async throws -> [(fid: String, shareFidToken: String, fileName: String, size: Int64, isDir: Bool)] {
        let sep = detailEndpointBase.contains("?") ? "&" : "?"
        let urlStr = "\(detailEndpointBase)\(sep)pwd_id=\(Self.queryEncode(pwdId))&stoken=\(Self.queryEncode(stoken))&pdir_fid=\(Self.queryEncode(pdirFid))&force=0&_page=1&_size=100&_sort=file_type:asc,file_name:asc"
        let root = try await getJson(urlString: urlStr, headers: headers)
        let dataMap = (root["data"] as? [String: Any]) ?? [:]
        let list = (dataMap["list"] as? [[String: Any]]) ?? []
        return list.compactMap { item in
            let fid = Self.str(item["fid"])
            guard !fid.isEmpty else { return nil }
            let token = Self.str(item["share_fid_token"])
            let name = Self.str(item["file_name"])
            let size = (item["size"] as? NSNumber)?.int64Value ?? 0
            let isDir = ((item["dir"] as? Bool) == true) || ((item["file_type"] as? NSNumber)?.intValue == 0)
            return (fid, token, name, size, isDir)
        }
    }

    private static func pickBestQuarkVariant(
        from videoList: [[String: Any]],
        qualityPreference: String
    ) -> (url: URL, badge: String)? {
        let rankOrder: [String] = (qualityPreference == "1080p")
            ? ["super", "2k", "high", "4k", "normal", "low"]
            : ["4k", "2k", "super", "high", "normal", "low"]

        var available: [String: URL] = [:]
        for entry in videoList {
            let res = str(entry["resolution"]).lowercased()
            let vInfo = (entry["video_info"] as? [String: Any]) ?? entry
            let raw = str(vInfo["url"])
            if !res.isEmpty, !raw.isEmpty, let u = URL(string: raw) {
                available[res] = u
            }
        }

        for tier in rankOrder {
            if let matched = available[tier] {
                let badge: String
                switch tier {
                case "4k": badge = "4K HDR"
                case "2k": badge = "2K"
                case "super": badge = "1080P"
                case "high": badge = "720P"
                default: badge = "高清"
                }
                return (matched, badge)
            }
        }
        return nil
    }

    public static func parseShareDescriptor(_ rawUrl: String) -> (shareId: String, passcode: String, fid: String) {
        let trimmed = rawUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let comps = URLComponents(string: trimmed) else { return ("", "", "") }
        let qItems = comps.queryItems ?? []
        func qVal(_ names: [String]) -> String {
            for n in names {
                if let v = qItems.first(where: { $0.name.lowercased() == n })?.value, !v.isEmpty { return v }
            }
            return ""
        }

        var shareId = qVal(["pwd_id", "share_id", "share_code", "surl", "shorturl", "id"])
        let passcode = qVal(["pwd", "passcode", "share_pwd", "receive_code", "password", "code"])
        var fid = qVal(["fid", "file_id", "fs_id", "pc", "pick_code"])

        if shareId.isEmpty {
            let parts = comps.path.split(separator: "/").map(String.init)
            if let sIdx = parts.firstIndex(of: "s"), sIdx + 1 < parts.count {
                shareId = parts[sIdx + 1]
            }
        }
        if fid.isEmpty, let fragment = comps.fragment {
            let fragParts = fragment.split(separator: "/").map(String.init)
            if let last = fragParts.last, last.count >= 8 && last != "share" && last != "list" {
                fid = last.components(separatedBy: "-").first ?? last
            }
        }
        return (shareId, passcode, fid)
    }

    public static func inferResolutionBadge(from text: String, fallbackQuality: String) -> String {
        let lower = text.lowercased()
        if lower.contains("2160p") || lower.contains("4k") || lower.contains("uhd") {
            if lower.contains("dv") || lower.contains("dovi") || lower.contains("hdr") { return "4K HDR" }
            return "4K"
        }
        if lower.contains("1440p") || lower.contains("2k") { return "2K" }
        if lower.contains("1080p") || lower.contains("fhd") { return "1080P" }
        if lower.contains(".m3u8") { return "HLS" }
        if fallbackQuality == "4k_hdr" { return "4K HDR" }
        if fallbackQuality == "1080p" { return "1080P" }
        return ""
    }

    private static func isVideoFilename(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return videoExtensions.contains(ext)
    }

    private func getJson(urlString: String, headers: [String: String]) async throws -> [String: Any] {
        guard let url = URL(string: urlString) else { throw MarcoError.invalidFormat("无效的网盘请求地址") }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 18)
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
        guard let url = URL(string: urlString) else { throw MarcoError.invalidFormat("无效的网盘请求地址") }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 18)
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

    private static func queryEncode(_ s: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#/")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    private static func str(_ any: Any?) -> String {
        guard let any = any, !(any is NSNull) else { return "" }
        if let s = any as? String { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let n = any as? NSNumber { return n.stringValue }
        return ""
    }
}
