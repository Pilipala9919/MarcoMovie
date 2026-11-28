// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only

import Foundation

public struct NetdiskDriveInfo: Hashable, Identifiable, Sendable {
    public var id: String { key }
    public let key: String
    public let tvName: String
    public let providerName: String
    public let appHint: String
    public let linePrefix: String
    public let trustedDomains: [String]
    public let defaultOrigin: String

    public init(
        key: String,
        tvName: String,
        providerName: String,
        appHint: String,
        linePrefix: String,
        trustedDomains: [String],
        defaultOrigin: String
    ) {
        self.key = key
        self.tvName = tvName
        self.providerName = providerName
        self.appHint = appHint
        self.linePrefix = linePrefix
        self.trustedDomains = trustedDomains
        self.defaultOrigin = defaultOrigin
    }

    public static let allDrives: [NetdiskDriveInfo] = [
        NetdiskDriveInfo(
            key: "quark",
            tvName: "我的夸父",
            providerName: "夸克网盘",
            appHint: "请使用夸克 App 扫描二维码授权 4K 原画播放",
            linePrefix: "夸父4K",
            trustedDomains: ["quark.cn"],
            defaultOrigin: "https://pan.quark.cn"
        ),
        NetdiskDriveInfo(
            key: "uc",
            tvName: "我的优汐",
            providerName: "UC网盘",
            appHint: "请使用 UC 浏览器 App 扫描二维码登录网盘",
            linePrefix: "优汐4K",
            trustedDomains: ["uc.cn"],
            defaultOrigin: "https://drive.uc.cn"
        ),
        NetdiskDriveInfo(
            key: "baidu",
            tvName: "我的嘟嘟",
            providerName: "百度网盘",
            appHint: "请使用百度网盘 App 扫描二维码登录",
            linePrefix: "嘟嘟4K",
            trustedDomains: ["baidu.com", "baidupcs.com"],
            defaultOrigin: "https://pan.baidu.com"
        ),
        NetdiskDriveInfo(
            key: "ali",
            tvName: "我的阿狸",
            providerName: "阿里云盘",
            appHint: "请使用阿里云盘 App 扫描二维码授权",
            linePrefix: "阿狸4K",
            trustedDomains: ["alipan.com", "aliyundrive.com", "aliyundrive.net", "aliyunpds.com"],
            defaultOrigin: "https://www.alipan.com"
        ),
        NetdiskDriveInfo(
            key: "115",
            tvName: "我的 115",
            providerName: "115 网盘",
            appHint: "请使用 115 生活 App 扫描二维码或粘贴 UID/CID/SEID Cookie 授权",
            linePrefix: "115原画",
            trustedDomains: ["115.com", "115cdn.com", "anxia.com"],
            defaultOrigin: "https://115.com"
        ),
    ]

    public static func info(for driveKey: String) -> NetdiskDriveInfo? {
        let normalized = driveKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return allDrives.first { $0.key == normalized }
    }
}

public struct NetdiskQrSession: Hashable, Sendable {
    public let driveKey: String
    public let token: String
    public let qrUrl: String
    public let ck: String
    public let timestampToken: String
    public let gid: String
    public let sign: String
    public let sessionCookies: [String: String]
    public let createdAt: Date

    public init(
        driveKey: String,
        token: String,
        qrUrl: String,
        ck: String = "",
        timestampToken: String = "",
        gid: String = "",
        sign: String = "",
        sessionCookies: [String: String] = [:],
        createdAt: Date = Date()
    ) {
        self.driveKey = driveKey
        self.token = token
        self.qrUrl = qrUrl
        self.ck = ck
        self.timestampToken = timestampToken
        self.gid = gid
        self.sign = sign
        self.sessionCookies = sessionCookies
        self.createdAt = createdAt
    }
}

public enum NetdiskPollState: String, Equatable, Sendable {
    case waiting
    case scanned
    case confirmed
    case expired
    case error
}

public struct NetdiskPollResult: Equatable, Sendable {
    public let state: NetdiskPollState
    public let message: String
    public let credential: String

    public init(state: NetdiskPollState, message: String, credential: String = "") {
        self.state = state
        self.message = message
        self.credential = credential
    }
}

/// Validates and normalizes Netdisk credentials across Quark, UC, Baidu, AliyunDrive, and 115,
/// rejecting CRLF header injection, oversized payloads, and synthetic placeholder tokens.
public enum NetdiskSessionValidator {
    public static let maxCredentialBytes = 65_536

    private static let placeholderPrefixes = [
        "qr_auth_",
        "fallback_",
        "uc_4k_",
        "baidu_qr_auth_",
        "dudu_4k_",
        "ali_refresh_token_",
        "placeholder_",
        "mock_placeholder_",
    ]

    private static func containsForbiddenControl(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            scalar.value == 0x0D || scalar.value == 0x0A || scalar.value == 0x00 || scalar.value == 0x7F
        }
    }

    public static func isUsable(driveKey: String, credential rawCredential: String) -> Bool {
        let key = driveKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let trimmed = rawCredential.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.utf8.count <= maxCredentialBytes,
              !containsForbiddenControl(trimmed)
        else {
            return false
        }

        let lower = trimmed.lowercased()
        if placeholderPrefixes.contains(where: { lower.hasPrefix($0) }) {
            return false
        }

        switch key {
        case "quark", "uc":
            let cookieStr = extractCookieHeader(driveKey: key, credential: trimmed)
            guard !cookieStr.isEmpty, !containsForbiddenControl(cookieStr) else { return false }
            let pairs = parseCookiePairs(cookieStr)
            let pus = pairs["__pus"] ?? ""
            let puus = pairs["__puus"] ?? ""
            if pus.isEmpty && puus.isEmpty { return false }
            if placeholderPrefixes.contains(where: { pus.lowercased().hasPrefix($0) || puus.lowercased().hasPrefix($0) }) {
                return false
            }
            return true

        case "baidu":
            let pairs = parseCookiePairs(trimmed)
            guard let bduss = pairs["BDUSS"], bduss.count >= 6 else { return false }
            if placeholderPrefixes.contains(where: { bduss.lowercased().hasPrefix($0) }) { return false }
            return true

        case "ali":
            guard let token = extractAliRefreshToken(from: trimmed) else { return false }
            return token.count >= 16

        case "115":
            let cookieStr = extractCookieHeader(driveKey: key, credential: trimmed)
            guard !cookieStr.isEmpty, !containsForbiddenControl(cookieStr) else { return false }
            let pairs = parseCookiePairs(cookieStr)
            let uid = pairs["UID"] ?? pairs["uid"] ?? ""
            let cid = pairs["CID"] ?? pairs["cid"] ?? ""
            let seid = pairs["SEID"] ?? pairs["seid"] ?? ""
            guard uid.count >= 4, cid.count >= 6, seid.count >= 8 else { return false }
            return true

        default:
            return false
        }
    }

    public static func normalizeCredential(driveKey: String, rawCredential: String) -> String {
        let key = driveKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let trimmed = rawCredential.trimmingCharacters(in: .whitespacesAndNewlines)
        if key == "ali", let token = extractAliRefreshToken(from: trimmed) {
            return "ali_token=\(token)"
        }
        return trimmed
    }

    public static func extractCookieHeader(driveKey: String, credential: String) -> String {
        let trimmed = credential.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{"),
           let data = trimmed.data(using: .utf8),
           let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let nestedCookie = (json["cookie"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !nestedCookie.isEmpty
        {
            return nestedCookie
        }
        return trimmed
    }

    public static func extractAliRefreshToken(from credential: String) -> String? {
        var token = credential.trimmingCharacters(in: .whitespacesAndNewlines)
        if token.lowercased().hasPrefix("ali_token=") {
            token = String(token.dropFirst("ali_token=".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard token.count >= 16,
              !token.contains(" "),
              !token.contains(";"),
              !token.contains("\""),
              !token.contains("{"),
              !token.contains("}"),
              !token.contains("\r"),
              !token.contains("\n")
        else { return nil }
        let lower = token.lowercased()
        if placeholderPrefixes.contains(where: { lower.hasPrefix($0) }) { return nil }
        return token
    }

    public static func parseCookiePairs(_ header: String) -> [String: String] {
        var out: [String: String] = [:]
        for part in header.split(separator: ";") {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            let name = String(trimmed[..<eq]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty && !value.isEmpty { out[name] = value }
        }
        return out
    }
}

private final class NoRedirectSessionDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// Native QR authentication service supporting all 5 netdisks:
/// Quark, UC, Baidu, AliyunDrive, and 115.
public final class NetdiskService: @unchecked Sendable {
    public static let desktopChromeUA =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"

    private let session: URLSession
    private let redirectDelegate = NoRedirectSessionDelegate()

    public init(session: URLSession) {
        self.session = session
    }

    public init(configuration: URLSessionConfiguration? = nil) {
        let cfg = configuration ?? {
            let c = URLSessionConfiguration.ephemeral
            c.timeoutIntervalForRequest = 15
            c.timeoutIntervalForResource = 30
            c.httpShouldSetCookies = false
            c.httpCookieAcceptPolicy = .never
            return c
        }()
        self.session = URLSession(configuration: cfg, delegate: redirectDelegate, delegateQueue: nil)
    }

    public func startQrSession(driveKey: String) async throws -> NetdiskQrSession {
        switch driveKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "quark": return try await startQuarkQrSession()
        case "uc": return try await startUcQrSession()
        case "baidu": return try await startBaiduQrSession()
        case "ali": return try await startAliQrSession()
        case "115": return try await start115QrSession()
        default: throw MarcoError.invalidFormat("不支持的网盘类型：\(driveKey)")
        }
    }

    public func pollQrSession(_ qrSession: NetdiskQrSession) async -> NetdiskPollResult {
        switch qrSession.driveKey.lowercased() {
        case "quark": return await pollQuarkQrSession(qrSession)
        case "uc": return await pollUcQrSession(qrSession)
        case "baidu": return await pollBaiduQrSession(qrSession)
        case "ali": return await pollAliQrSession(qrSession)
        case "115": return await poll115QrSession(qrSession)
        default: return NetdiskPollResult(state: .error, message: "未知的网盘会话类型")
        }
    }

    // MARK: - 1. Quark

    private func startQuarkQrSession() async throws -> NetdiskQrSession {
        let ts = nowMs()
        let urlStr = "https://uop.quark.cn/cas/ajax/getTokenForQrcodeLogin?client_id=532&v=1.2&request_id=\(ts)"
        let (data, resp) = try await sendRequest(
            urlString: urlStr,
            headers: [
                "Accept": "application/json, text/plain, */*",
                "Origin": "https://pan.quark.cn",
                "Referer": "https://pan.quark.cn/",
            ]
        )
        let root = try parseJsonObject(data)
        let status = intValue(root["status"])
        let dataMap = (root["data"] as? [String: Any]) ?? [:]
        let members = (dataMap["members"] as? [String: Any]) ?? dataMap
        let token = stringValue(members["token"])
        guard (status == 2_000_000 || status == 0 || status == 200), !token.isEmpty else {
            let msg = stringValue(root["message"])
            throw MarcoError.networkFailure(msg.isEmpty ? "获取夸克扫码令牌失败" : msg)
        }
        let encodedToken = queryEncode(token)
        let qrUrl = "https://su.quark.cn/4_eMHBJ?uc_param_str=dsdnfrpfbivesscpgimibtbmnijblauputogpintnwktprchmt&token=\(encodedToken)&client_id=532&ssb=weblogin&uc_biz_str=S%3Acustom%7COPT%3ASAREA%400%7COPT%3AIMMERSIVE%401%7COPT%3ABACK_BTN_STYLE%400"
        let cookies = extractSetCookies(from: resp, for: URL(string: "https://pan.quark.cn")!)
        return NetdiskQrSession(driveKey: "quark", token: token, qrUrl: qrUrl, sessionCookies: cookies)
    }

    private func pollQuarkQrSession(_ qrSession: NetdiskQrSession) async -> NetdiskPollResult {
        do {
            let ts = nowMs()
            let encodedToken = queryEncode(qrSession.token)
            let pollUrl = "https://uop.quark.cn/cas/ajax/getServiceTicketByQrcodeToken?client_id=532&v=1.2&token=\(encodedToken)&request_id=\(ts)"
            var pollHeaders = [
                "Accept": "application/json, text/plain, */*",
                "Origin": "https://pan.quark.cn",
                "Referer": "https://pan.quark.cn/",
            ]
            if !qrSession.sessionCookies.isEmpty { pollHeaders["Cookie"] = formatCookieHeader(qrSession.sessionCookies) }
            let (data, pollResp) = try await sendRequest(urlString: pollUrl, headers: pollHeaders)
            let root = try parseJsonObject(data)
            let status = intValue(root["status"])

            if status == 50_004_001 { return NetdiskPollResult(state: .waiting, message: "等待夸克 App 扫码…") }
            if status == 50_004_002 { return NetdiskPollResult(state: .expired, message: "二维码已过期，请点击刷新") }
            if status == 50_004_003 || status == 2_000_001 { return NetdiskPollResult(state: .scanned, message: "已扫码，请在手机端确认登录") }
            guard status == 2_000_000 else {
                let msg = stringValue(root["message"])
                return NetdiskPollResult(state: .waiting, message: msg.isEmpty ? "等待手机确认…" : msg)
            }

            let dataMap = (root["data"] as? [String: Any]) ?? [:]
            let members = (dataMap["members"] as? [String: Any]) ?? dataMap
            let serviceTicket = stringValue(members["service_ticket"])
            guard !serviceTicket.isEmpty else { return NetdiskPollResult(state: .error, message: "夸克服务票据为空") }

            var mergedCookies = qrSession.sessionCookies
            for (k, v) in extractSetCookies(from: pollResp, for: URL(string: "https://uop.quark.cn")!) { mergedCookies[k] = v }

            let encodedSt = queryEncode(serviceTicket)
            let exchangeUrl = "https://pan.quark.cn/account/info?st=\(encodedSt)&lw=scan"
            var exchangeHeaders = ["Accept": "application/json, text/plain, */*", "Referer": "https://pan.quark.cn/"]
            if !mergedCookies.isEmpty { exchangeHeaders["Cookie"] = formatCookieHeader(mergedCookies) }
            let (infoData, infoResp) = try await sendRequest(urlString: exchangeUrl, headers: exchangeHeaders)
            for (k, v) in extractSetCookies(from: infoResp, for: URL(string: "https://pan.quark.cn")!) { mergedCookies[k] = v }
            if let infoJson = try? parseJsonObject(infoData), let infoBody = infoJson["data"] as? [String: Any] {
                let pus = stringValue(infoBody["__pus"])
                let puus = stringValue(infoBody["__puus"])
                if !pus.isEmpty { mergedCookies["__pus"] = pus }
                if !puus.isEmpty { mergedCookies["__puus"] = puus }
            }

            if mergedCookies["__puus"] == nil, mergedCookies["__pus"] != nil {
                if let (_, touchResp) = try? await sendRequest(
                    urlString: "https://drive-pc.quark.cn/1/clouddrive/config?pr=ucpro&fr=pc",
                    headers: ["Referer": "https://pan.quark.cn/", "Cookie": formatCookieHeader(mergedCookies)]
                ) {
                    for (k, v) in extractSetCookies(from: touchResp, for: URL(string: "https://drive-pc.quark.cn")!) { mergedCookies[k] = v }
                }
            }

            let credential = formatCookieHeader(mergedCookies)
            guard NetdiskSessionValidator.isUsable(driveKey: "quark", credential: credential) else {
                return NetdiskPollResult(state: .error, message: "夸克登录未返回有效会话 Cookie（__pus / __puus）")
            }
            return NetdiskPollResult(state: .confirmed, message: "夸克网盘已登录", credential: credential)
        } catch {
            return NetdiskPollResult(state: .error, message: "夸克扫码轮询异常：\(error.localizedDescription)")
        }
    }

    // MARK: - 2. UC

    private func startUcQrSession() async throws -> NetdiskQrSession {
        let ts = nowMs()
        let urlStr = "https://api.open.uc.cn/cas/ajax/getTokenForQrcodeLogin?client_id=381&v=1.2&request_id=\(ts)"
        let (data, resp) = try await sendRequest(
            urlString: urlStr,
            headers: [
                "Accept": "application/json, text/plain, */*",
                "Origin": "https://drive.uc.cn",
                "Referer": "https://drive.uc.cn/",
            ]
        )
        let root = try parseJsonObject(data)
        let status = intValue(root["status"])
        let dataMap = (root["data"] as? [String: Any]) ?? [:]
        let members = (dataMap["members"] as? [String: Any]) ?? dataMap
        let token = stringValue(members["token"])
        guard (status == 2_000_000 || status == 0 || status == 200), !token.isEmpty else {
            let msg = stringValue(root["message"])
            throw MarcoError.networkFailure(msg.isEmpty ? "获取 UC 扫码令牌失败" : msg)
        }
        let encodedToken = queryEncode(token)
        let qrUrl = "https://su.uc.cn/1_n0ZCv?uc_param_str=dsdnfrpfbivesscpgimibtbmnijblauputogpintnwktprchmt&token=\(encodedToken)&client_id=381&uc_biz_str=S%3Acustom%7CC%3Atitlebar_fix"
        let cookies = extractSetCookies(from: resp, for: URL(string: "https://drive.uc.cn")!)
        return NetdiskQrSession(driveKey: "uc", token: token, qrUrl: qrUrl, sessionCookies: cookies)
    }

    private func pollUcQrSession(_ qrSession: NetdiskQrSession) async -> NetdiskPollResult {
        do {
            let ts = nowMs()
            let encodedToken = queryEncode(qrSession.token)
            let pollUrl = "https://api.open.uc.cn/cas/ajax/getServiceTicketByQrcodeToken?client_id=381&v=1.2&token=\(encodedToken)&request_id=\(ts)"
            let (data, pollResp) = try await sendRequest(
                urlString: pollUrl,
                headers: [
                    "Accept": "application/json, text/plain, */*",
                    "Origin": "https://drive.uc.cn",
                    "Referer": "https://drive.uc.cn/",
                ]
            )
            let root = try parseJsonObject(data)
            let status = intValue(root["status"])

            if status == 50_004_001 { return NetdiskPollResult(state: .waiting, message: "等待 UC 浏览器扫码…") }
            if status == 50_004_002 { return NetdiskPollResult(state: .expired, message: "二维码已过期，请刷新重试") }
            if status == 50_004_003 || status == 2_000_001 { return NetdiskPollResult(state: .scanned, message: "已扫码，请在手机端确认登录") }
            guard status == 2_000_000 else { return NetdiskPollResult(state: .waiting, message: "等待 UC 扫码授权…") }

            let dataMap = (root["data"] as? [String: Any]) ?? [:]
            let members = (dataMap["members"] as? [String: Any]) ?? dataMap
            let serviceTicket = stringValue(members["service_ticket"])
            guard !serviceTicket.isEmpty else { return NetdiskPollResult(state: .error, message: "UC 服务票据为空") }

            var mergedCookies = qrSession.sessionCookies
            for (k, v) in extractSetCookies(from: pollResp, for: URL(string: "https://api.open.uc.cn")!) { mergedCookies[k] = v }

            let encodedSt = queryEncode(serviceTicket)
            let exchangeUrl = "https://drive.uc.cn/account/mobileinfo?pr=UCBrowser&fr=h5&st=\(encodedSt)"
            var exchangeHeaders = ["Accept": "application/json, text/plain, */*", "Referer": "https://drive.uc.cn/"]
            if !mergedCookies.isEmpty { exchangeHeaders["Cookie"] = formatCookieHeader(mergedCookies) }
            let (exData, exResp) = try await sendRequest(urlString: exchangeUrl, headers: exchangeHeaders)
            for (k, v) in extractSetCookies(from: exResp, for: URL(string: "https://drive.uc.cn")!) { mergedCookies[k] = v }
            if let exJson = try? parseJsonObject(exData) {
                let inner = (exJson["data"] as? [String: Any]) ?? exJson
                let pus = stringValue(inner["__pus"])
                let puus = stringValue(inner["__puus"])
                if !pus.isEmpty { mergedCookies["__pus"] = pus }
                if !puus.isEmpty { mergedCookies["__puus"] = puus }
            }

            let credential = formatCookieHeader(mergedCookies)
            guard NetdiskSessionValidator.isUsable(driveKey: "uc", credential: credential) else {
                return NetdiskPollResult(state: .error, message: "UC 登录未返回有效会话 Cookie（__pus）")
            }
            return NetdiskPollResult(state: .confirmed, message: "UC 网盘已登录", credential: credential)
        } catch {
            return NetdiskPollResult(state: .error, message: "UC 扫码轮询异常：\(error.localizedDescription)")
        }
    }

    // MARK: - 3. Baidu

    private func startBaiduQrSession() async throws -> NetdiskQrSession {
        let ts = nowMs()
        let sec = ts / 1000
        let gid = UUID().uuidString.uppercased()
        let urlStr = "https://passport.baidu.com/v2/api/getqrcode?lp=pc&qrloginfrom=pc&gid=\(gid)&callback=tangram_guid_\(ts)&apiver=v3&tt=\(ts)&tpl=netdisk&_=\(ts)"
        let (data, resp) = try await sendRequest(urlString: urlStr, headers: ["Referer": "https://pan.baidu.com/"])
        let root = try parseJsonOrJsonpObject(data)
        let sign = stringValue(root["sign"])
        guard !sign.isEmpty else { throw MarcoError.networkFailure("获取百度网盘二维码标识失败") }
        let encodedSign = queryEncode(sign)
        let qrUrl = "https://wappass.baidu.com/wp/?qrlogin&t=\(sec)&error=0&sign=\(encodedSign)&cmd=login&lp=pc&adapter=3&qrloginfrom=pc"
        let isolatedCookies = extractSetCookies(from: resp, for: URL(string: "https://passport.baidu.com")!)
        return NetdiskQrSession(driveKey: "baidu", token: sign, qrUrl: qrUrl, gid: gid, sessionCookies: isolatedCookies)
    }

    private func pollBaiduQrSession(_ qrSession: NetdiskQrSession) async -> NetdiskPollResult {
        do {
            let ts = nowMs()
            let sec = ts / 1000
            let encodedSign = queryEncode(qrSession.token)
            let encodedGid = queryEncode(qrSession.gid)
            let pollUrl = "https://passport.baidu.com/channel/unicast?channel_id=\(encodedSign)&gid=\(encodedGid)&tpl=netdisk&_sdkFrom=1&callback=tangram_guid_\(ts)&apiver=v3&tt=\(ts)&_=\(ts)"
            var pollHeaders = ["Referer": "https://pan.baidu.com/"]
            if !qrSession.sessionCookies.isEmpty { pollHeaders["Cookie"] = formatCookieHeader(qrSession.sessionCookies) }
            let (data, pollResp) = try await sendRequest(urlString: pollUrl, headers: pollHeaders)
            let root = try parseJsonOrJsonpObject(data)
            let errno = intValue(root["errno"], defaultValue: -1)
            if errno == 1 { return NetdiskPollResult(state: .waiting, message: "等待百度网盘 App 扫码…") }
            guard errno == 0 else { return NetdiskPollResult(state: .waiting, message: "等待百度扫码响应…") }

            let channelMap: [String: Any]
            if let cvStr = root["channel_v"] as? String,
               let cvData = cvStr.data(using: .utf8),
               let parsed = (try? JSONSerialization.jsonObject(with: cvData)) as? [String: Any]
            {
                channelMap = parsed
            } else if let cvObj = root["channel_v"] as? [String: Any] {
                channelMap = cvObj
            } else {
                return NetdiskPollResult(state: .waiting, message: "等待扫码确认…")
            }

            let status = intValue(channelMap["status"], defaultValue: -1)
            if status == 1 { return NetdiskPollResult(state: .scanned, message: "已扫码，请在手机百度网盘上点击确认") }
            if status == 2 { return NetdiskPollResult(state: .expired, message: "百度二维码已过期，请刷新") }
            guard status == 0 else { return NetdiskPollResult(state: .waiting, message: "等待手机确认授权…") }

            let vTicket = stringValue(channelMap["v"])
            guard !vTicket.isEmpty else { return NetdiskPollResult(state: .error, message: "百度授权票据为空") }

            var isolatedJar = qrSession.sessionCookies
            for (k, v) in extractSetCookies(from: pollResp, for: URL(string: "https://passport.baidu.com")!) { isolatedJar[k] = v }

            let encodedV = queryEncode(vTicket)
            let loginUrl = "https://passport.baidu.com/v3/login/main/qrbdusslogin?v=\(ts)&bduss=\(encodedV)&u=https%3A%2F%2Fpan.baidu.com%2Fdisk%2Fhome&loginVersion=v4&qrcode=1&tpl=netdisk&apiver=v3&tt=\(ts)&alg=v3&time=\(sec)&callback=bd__cbs__4wi6y6"
            var loginHeaders = ["Referer": "https://pan.baidu.com/"]
            if !isolatedJar.isEmpty { loginHeaders["Cookie"] = formatCookieHeader(isolatedJar) }
            let (loginData, loginResp) = try await sendRequest(urlString: loginUrl, headers: loginHeaders)
            for (k, v) in extractSetCookies(from: loginResp, for: URL(string: "https://passport.baidu.com")!) { isolatedJar[k] = v }
            if let loginJson = try? parseJsonOrJsonpObject(loginData) {
                let dataSection = (loginJson["data"] as? [String: Any]) ?? loginJson
                let sessionSection = (dataSection["session"] as? [String: Any]) ?? dataSection
                let bduss = stringValue(sessionSection["bduss"])
                let stoken = stringValue(sessionSection["stoken"])
                let ptoken = stringValue(sessionSection["ptoken"])
                if !bduss.isEmpty && isolatedJar["BDUSS"] == nil { isolatedJar["BDUSS"] = bduss }
                if !stoken.isEmpty && isolatedJar["STOKEN"] == nil { isolatedJar["STOKEN"] = stoken }
                if !ptoken.isEmpty && isolatedJar["PTOKEN"] == nil { isolatedJar["PTOKEN"] = ptoken }
            }

            if isolatedJar["BDUSS"] != nil && isolatedJar["STOKEN"] == nil {
                if let (_, homeResp) = try? await sendRequest(
                    urlString: "https://pan.baidu.com/disk/home",
                    headers: ["Referer": "https://pan.baidu.com/", "Cookie": formatCookieHeader(isolatedJar)]
                ) {
                    for (k, v) in extractSetCookies(from: homeResp, for: URL(string: "https://pan.baidu.com")!) { isolatedJar[k] = v }
                }
            }

            let credential = formatCookieHeader(isolatedJar)
            guard NetdiskSessionValidator.isUsable(driveKey: "baidu", credential: credential) else {
                return NetdiskPollResult(state: .error, message: "百度网盘登录未返回有效 BDUSS 凭据")
            }
            return NetdiskPollResult(state: .confirmed, message: "百度网盘已登录", credential: credential)
        } catch {
            return NetdiskPollResult(state: .error, message: "百度扫码轮询异常：\(error.localizedDescription)")
        }
    }

    // MARK: - 4. AliyunDrive

    private func startAliQrSession() async throws -> NetdiskQrSession {
        let ts = nowMs()
        let urlStr = "https://passport.aliyundrive.com/newlogin/qrcode/generate.do?appName=aliyun_drive&fromSite=52&appEntrance=web&_csrf_token=&isMobile=false&lang=zh_CN&returnUrl=&hsbegin=\(ts)"
        let (data, resp) = try await sendRequest(
            urlString: urlStr,
            headers: ["Accept": "application/json, text/plain, */*", "Referer": "https://passport.aliyundrive.com/"]
        )
        let root = try parseJsonObject(data)
        let content = (root["content"] as? [String: Any]) ?? root
        let inner = (content["data"] as? [String: Any]) ?? content
        let codeContent = stringValue(inner["codeContent"])
        let ck = stringValue(inner["ck"])
        let tVal = stringValue(inner["t"])
        guard !codeContent.isEmpty, !ck.isEmpty, !tVal.isEmpty else {
            throw MarcoError.networkFailure("获取阿里云盘二维码参数失败")
        }
        let cookies = extractSetCookies(from: resp, for: URL(string: "https://passport.aliyundrive.com")!)
        return NetdiskQrSession(driveKey: "ali", token: ck, qrUrl: codeContent, ck: ck, timestampToken: tVal, sessionCookies: cookies)
    }

    private func pollAliQrSession(_ qrSession: NetdiskQrSession) async -> NetdiskPollResult {
        do {
            let pollUrl = "https://passport.aliyundrive.com/newlogin/qrcode/query.do?appName=aliyun_drive&fromSite=52&_bx-v=2.2.3"
            let formBody = [
                "ck=\(queryEncode(qrSession.ck))",
                "t=\(queryEncode(qrSession.timestampToken))",
                "appName=aliyun_drive",
                "appEntrance=web",
                "fromSite=52",
                "isMobile=false",
                "lang=zh_CN",
                "returnUrl=",
                "navlanguage=zh-CN",
            ].joined(separator: "&")
            var headers = [
                "Accept": "application/json, text/plain, */*",
                "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8",
                "Origin": "https://passport.aliyundrive.com",
                "Referer": "https://passport.aliyundrive.com/",
            ]
            if !qrSession.sessionCookies.isEmpty { headers["Cookie"] = formatCookieHeader(qrSession.sessionCookies) }
            let (data, _) = try await sendRequest(urlString: pollUrl, method: "POST", headers: headers, body: Data(formBody.utf8))
            let root = try parseJsonObject(data)
            let content = (root["content"] as? [String: Any]) ?? root
            let inner = (content["data"] as? [String: Any]) ?? content
            let qrStatus = stringValue(inner["qrCodeStatus"]).uppercased()

            switch qrStatus {
            case "NEW": return NetdiskPollResult(state: .waiting, message: "等待阿里云盘 App 扫码…")
            case "SCANED", "SCANNED": return NetdiskPollResult(state: .scanned, message: "已扫码，请在手机阿里云盘上点击确认")
            case "EXPIRED", "CANCELED", "CANCELLED": return NetdiskPollResult(state: .expired, message: "阿里云盘二维码已失效，请刷新")
            case "CONFIRMED":
                let bizExtRaw = stringValue(inner["bizExt"])
                guard let refreshToken = Self.extractAliRefreshTokenFromBizExt(bizExtRaw) else {
                    return NetdiskPollResult(state: .error, message: "解析阿里云盘授权 bizExt 失败")
                }
                let credential = "ali_token=\(refreshToken)"
                guard NetdiskSessionValidator.isUsable(driveKey: "ali", credential: credential) else {
                    return NetdiskPollResult(state: .error, message: "阿里云盘返回的 refreshToken 格式无效")
                }
                return NetdiskPollResult(state: .confirmed, message: "阿里云盘已登录", credential: credential)
            default:
                return NetdiskPollResult(state: .waiting, message: "等待阿里云盘扫码状态…")
            }
        } catch {
            return NetdiskPollResult(state: .error, message: "阿里云盘轮询异常：\(error.localizedDescription)")
        }
    }

    // MARK: - 5. 115 Cloud Drive

    private func start115QrSession() async throws -> NetdiskQrSession {
        let (data, resp) = try await sendRequest(
            urlString: "https://qrcodeapi.115.com/api/1.0/web/1.0/token",
            headers: ["Accept": "application/json, text/plain, */*", "Referer": "https://115.com/"]
        )
        let root = try parseJsonObject(data)
        let inner = (root["data"] as? [String: Any]) ?? root
        let uid = stringValue(inner["uid"])
        let timeStr = stringValue(inner["time"])
        let sign = stringValue(inner["sign"])
        let qrcode = stringValue(inner["qrcode"])
        guard !uid.isEmpty, !timeStr.isEmpty, !sign.isEmpty else {
            throw MarcoError.networkFailure("获取 115 网盘扫码令牌失败")
        }
        let qrUrl = !qrcode.isEmpty ? qrcode : "https://115.com/scan/dg-\(queryEncode(uid))"
        let cookies = extractSetCookies(from: resp, for: URL(string: "https://115.com")!)
        return NetdiskQrSession(
            driveKey: "115",
            token: uid,
            qrUrl: qrUrl,
            timestampToken: timeStr,
            sign: sign,
            sessionCookies: cookies
        )
    }

    private func poll115QrSession(_ qrSession: NetdiskQrSession) async -> NetdiskPollResult {
        do {
            let pollUrl = "https://qrcodeapi.115.com/get/status/?uid=\(queryEncode(qrSession.token))&time=\(queryEncode(qrSession.timestampToken))&sign=\(queryEncode(qrSession.sign))&_=\(nowMs())"
            let (data, _) = try await sendRequest(
                urlString: pollUrl,
                headers: ["Accept": "application/json, text/plain, */*", "Referer": "https://115.com/"]
            )
            let root = try parseJsonObject(data)
            let inner = (root["data"] as? [String: Any]) ?? root
            let status = intValue(inner["status"], defaultValue: -1)
            if status == 0 { return NetdiskPollResult(state: .waiting, message: "等待 115 生活 App 扫码…") }
            if status == 1 { return NetdiskPollResult(state: .scanned, message: "已扫码，请在手机 115 App 确认登录") }
            if status == -1 || status == -2 { return NetdiskPollResult(state: .expired, message: "115 二维码已过期，请刷新") }
            guard status == 2 else { return NetdiskPollResult(state: .waiting, message: "等待 115 扫码状态…") }

            let formBody = "account=\(queryEncode(qrSession.token))&app=web"
            let (loginData, loginResp) = try await sendRequest(
                urlString: "https://passportapi.115.com/app/1.0/web/1.0/login/qrcode",
                method: "POST",
                headers: [
                    "Accept": "application/json, text/plain, */*",
                    "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8",
                    "Referer": "https://115.com/",
                ],
                body: Data(formBody.utf8)
            )
            var jar = qrSession.sessionCookies
            for (k, v) in extractSetCookies(from: loginResp, for: URL(string: "https://115.com")!) { jar[k] = v }
            if let loginJson = try? parseJsonObject(loginData),
               let lData = loginJson["data"] as? [String: Any],
               let cookieObj = lData["cookie"] as? [String: Any]
            {
                for (k, v) in cookieObj {
                    let s = stringValue(v)
                    if !s.isEmpty { jar[k] = s }
                }
            }
            let credential = formatCookieHeader(jar)
            guard NetdiskSessionValidator.isUsable(driveKey: "115", credential: credential) else {
                return NetdiskPollResult(state: .error, message: "115 登录未返回有效 UID/CID/SEID 会话 Cookie")
            }
            return NetdiskPollResult(state: .confirmed, message: "115 网盘已登录", credential: credential)
        } catch {
            return NetdiskPollResult(state: .error, message: "115 扫码轮询异常：\(error.localizedDescription)")
        }
    }

    public static func extractAliRefreshTokenFromBizExt(_ bizExtBase64: String) -> String? {
        var b64 = bizExtBase64.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        guard !b64.isEmpty else { return nil }
        while b64.count % 4 != 0 { b64.append("=") }
        guard let rawBytes = Data(base64Encoded: b64), !rawBytes.isEmpty else { return nil }

        let decodedString: String
        if let utf8 = String(data: rawBytes, encoding: .utf8) {
            decodedString = utf8
        } else {
            let bytes = [UInt8](rawBytes)
            var asciiSafe: [UInt8] = []
            asciiSafe.reserveCapacity(bytes.count)
            var idx = 0
            while idx < bytes.count {
                let b0 = bytes[idx]
                if b0 < 0x80 {
                    asciiSafe.append(b0)
                    idx += 1
                } else if b0 >= 0x81 && b0 <= 0xFE && idx + 1 < bytes.count {
                    let b1 = bytes[idx + 1]
                    if b1 >= 0x40 && b1 <= 0xFE && b1 != 0x7F {
                        asciiSafe.append(0x3F)
                        idx += 2
                        continue
                    }
                    asciiSafe.append(0x3F)
                    idx += 1
                } else {
                    asciiSafe.append(0x3F)
                    idx += 1
                }
            }
            decodedString = String(decoding: asciiSafe, as: UTF8.self)
        }

        if let jsonData = decodedString.data(using: .utf8),
           let obj = (try? JSONSerialization.jsonObject(with: jsonData)) as? [String: Any]
        {
            let pds = (obj["pds_login_result"] as? [String: Any]) ?? obj
            let token = ((pds["refreshToken"] as? String) ?? (pds["refresh_token"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !token.isEmpty { return token }
        }

        if let regex = try? NSRegularExpression(pattern: #""refresh_?[tT]oken"\s*:\s*"([^"]+)""#),
           let match = regex.firstMatch(in: decodedString, range: NSRange(decodedString.startIndex..., in: decodedString)),
           let range = Range(match.range(at: 1), in: decodedString)
        {
            return String(decodedString[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    // MARK: - Internal Transport & Parsing Helpers

    private func sendRequest(
        urlString: String,
        method: String = "GET",
        headers: [String: String] = [:],
        body: Data? = nil
    ) async throws -> (Data, HTTPURLResponse?) {
        guard let url = URL(string: urlString) else {
            throw MarcoError.invalidFormat("无效的网盘接口地址")
        }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        req.httpMethod = method
        req.httpShouldHandleCookies = false
        req.setValue(Self.desktopChromeUA, forHTTPHeaderField: "User-Agent")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = body
        let (data, resp) = try await session.marcoData(for: req)
        return (data, resp as? HTTPURLResponse)
    }

    private func parseJsonObject(_ data: Data) throws -> [String: Any] {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw MarcoError.invalidFormat("网盘服务响应不是有效的 JSON 对象")
        }
        return obj
    }

    private func parseJsonOrJsonpObject(_ data: Data) throws -> [String: Any] {
        var text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.hasPrefix("{"),
           let openParen = text.firstIndex(of: "("),
           let closeParen = text.lastIndex(of: ")"),
           openParen < closeParen
        {
            text = String(text[text.index(after: openParen)..<closeParen]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else {
            throw MarcoError.invalidFormat("网盘 JSONP 响应格式无效")
        }
        return obj
    }

    private func extractSetCookies(from response: HTTPURLResponse?, for fallbackUrl: URL) -> [String: String] {
        guard let response = response else { return [:] }
        var out: [String: String] = [:]
        var stringHeaders: [String: String] = [:]
        for (k, v) in response.allHeaderFields {
            stringHeaders[String(describing: k)] = String(describing: v)
        }
        let targetUrl = response.url ?? fallbackUrl
        for cookie in HTTPCookie.cookies(withResponseHeaderFields: stringHeaders, for: targetUrl) {
            if !cookie.name.isEmpty && !cookie.value.isEmpty { out[cookie.name] = cookie.value }
        }
        for (k, v) in stringHeaders where k.lowercased() == "set-cookie" {
            let attrNames: Set<String> = [
                "path", "domain", "expires", "max-age", "samesite", "secure", "httponly", "version", "priority",
            ]
            for segment in v.components(separatedBy: CharacterSet(charactersIn: ";\n")) {
                let piece = segment.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let eq = piece.firstIndex(of: "=") else { continue }
                let rawName = String(piece[..<eq]).trimmingCharacters(in: .whitespacesAndNewlines)
                let cleanName: String
                if let commaIdx = rawName.lastIndex(of: ",") {
                    cleanName = String(rawName[rawName.index(after: commaIdx)...]).trimmingCharacters(in: .whitespaces)
                } else {
                    cleanName = rawName
                }
                let val = String(piece[piece.index(after: eq)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleanName.isEmpty && !val.isEmpty && !attrNames.contains(cleanName.lowercased()) {
                    if out[cleanName] == nil { out[cleanName] = val }
                }
            }
        }
        return out
    }

    private func formatCookieHeader(_ cookies: [String: String]) -> String {
        let priorityOrder = ["__pus", "__puus", "BDUSS", "BDUSS_BFESS", "STOKEN", "PTOKEN", "UID", "CID", "SEID", "KID"]
        var orderedKeys: [String] = []
        for p in priorityOrder where cookies[p] != nil { orderedKeys.append(p) }
        for k in cookies.keys.sorted() where !orderedKeys.contains(k) { orderedKeys.append(k) }
        return orderedKeys.compactMap { k in
            guard let v = cookies[k], !v.isEmpty else { return nil }
            return "\(k)=\(v)"
        }.joined(separator: "; ")
    }

    private func queryEncode(_ s: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#/")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    private func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    private func intValue(_ any: Any?, defaultValue: Int = -1) -> Int {
        if let i = any as? Int { return i }
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String, let parsed = Int(s.trimmingCharacters(in: .whitespacesAndNewlines)) { return parsed }
        return defaultValue
    }

    private func stringValue(_ any: Any?) -> String {
        guard let any = any, !(any is NSNull) else { return "" }
        if let s = any as? String { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let n = any as? NSNumber { return n.stringValue }
        return ""
    }
}
