// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only

import Darwin
import Foundation
import Network

public struct LanConfigAppliedEvent: Equatable, Sendable {
    public var historyCount: Int
    public var favoriteCount: Int
    public var subscriptionCount: Int
    public var message: String

    public init(historyCount: Int, favoriteCount: Int, subscriptionCount: Int, message: String) {
        self.historyCount = historyCount
        self.favoriteCount = favoriteCount
        self.subscriptionCount = subscriptionCount
        self.message = message
    }
}

/// Token-scoped LAN HTTP receiver (`/configure/<token>`, `/push`, `/sync`, `/bind`, `/netdisk`)
/// enabling cross-device QR configuration, WebDAV encrypted binding, and peer-to-peer sync on iOS.
public final class LanConfigServer: @unchecked Sendable {
    public let storage: IOSStorageManager
    public let syncService: WebDavSyncService
    public let cmsClient: CmsClient
    public let token: String
    public let tokenPath: String
    public let bindKey: Data
    public let expiresAt: Date
    public var onApplied: (@Sendable (LanConfigAppliedEvent) -> Void)?
    public var onWebDavBound: (@Sendable (WebDavConfig) -> Void)?

    private let queue = DispatchQueue(label: "com.pilipala.marcoMovie.ios.lan-config")
    private let lock = NSLock()
    private var listener: NWListener?
    private(set) public var port: UInt16 = 0
    private var isClosed = false

    public init(
        storage: IOSStorageManager,
        syncService: WebDavSyncService? = nil,
        cmsClient: CmsClient = CmsClient(),
        ttlSeconds: TimeInterval = 600,
        onApplied: (@Sendable (LanConfigAppliedEvent) -> Void)? = nil,
        onWebDavBound: (@Sendable (WebDavConfig) -> Void)? = nil
    ) {
        self.storage = storage
        self.syncService = syncService ?? WebDavSyncService(storage: storage)
        self.cmsClient = cmsClient
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in 0..<bytes.count { bytes[i] = UInt8.random(in: 0...255) }
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        self.token = hex
        self.tokenPath = "/configure/\(hex)"
        self.bindKey = WebdavBindCrypto.generateKey()
        self.expiresAt = Date().addingTimeInterval(ttlSeconds)
        self.onApplied = onApplied
        self.onWebDavBound = onWebDavBound
    }

    deinit {
        stop()
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    public var isExpired: Bool {
        let closed = withLock { isClosed }
        return closed || Date() > expiresAt
    }

    public func configureUrl(forHost host: String) -> String {
        "http://\(host):\(port)\(tokenPath)"
    }

    public func syncUrl(forHost host: String) -> String {
        "\(configureUrl(forHost: host))/sync"
    }

    public func bindQrUrl(forHost host: String) -> String {
        (try? WebdavBindCrypto.buildBindQrUrl(baseEndpointUrl: configureUrl(forHost: host), key: bindKey))
            ?? configureUrl(forHost: host)
    }

    public func netdiskUrl(forHost host: String) -> String {
        "\(configureUrl(forHost: host))/netdisk"
    }

    public func start(loopbackOnly: Bool = false) async throws -> UInt16 {
        if let p = withLock({ (listener != nil && port > 0) ? port : nil }) {
            return p
        }

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        if loopbackOnly {
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        }

        let nwListener = try NWListener(using: params)
        nwListener.newConnectionHandler = { [weak self] conn in
            self?.handleConnection(conn)
        }

        let boundPort: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let once = MarcoOnceFlag()
            nwListener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard once.tryClaim() else { return }
                    if let p = nwListener.port?.rawValue, p > 0 {
                        continuation.resume(returning: p)
                    } else {
                        continuation.resume(throwing: MarcoError.networkFailure("局域网配置服务端口分配失败"))
                    }
                case .failed(let err):
                    guard once.tryClaim() else { return }
                    continuation.resume(throwing: MarcoError.networkFailure("局域网配置服务启动失败：\(err)"))
                case .cancelled:
                    guard once.tryClaim() else { return }
                    continuation.resume(throwing: MarcoError.networkFailure("局域网配置服务已停止"))
                default:
                    break
                }
            }
            nwListener.start(queue: self.queue)
        }

        withLock {
            self.listener = nwListener
            self.port = boundPort
            self.isClosed = false
        }
        return boundPort
    }

    public func stop() {
        let current = withLock { () -> NWListener? in
            isClosed = true
            let existing = listener
            listener = nil
            port = 0
            return existing
        }
        current?.cancel()
    }

    // MARK: - Private/LAN Peer Guard & Interface Discovery

    public static func isAllowedPeerHost(_ rawHost: String) -> Bool {
        var host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let pct = host.firstIndex(of: "%") {
            host = String(host[..<pct])
        }
        if host.hasPrefix("[") && host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        if host == "localhost" || host == "::1" {
            return true
        }
        if host.hasPrefix("::ffff:") {
            host = String(host.dropFirst("::ffff:".count))
        }
        if host.contains(":") {
            return host.hasPrefix("fe80:") || host.hasPrefix("fc") || host.hasPrefix("fd")
        }

        let octets = host.split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4 else { return false }
        let b0 = octets[0]
        let b1 = octets[1]
        if b0 == 127 { return true }
        if b0 == 10 { return true }
        if b0 == 172 && (16...31).contains(b1) { return true }
        if b0 == 192 && b1 == 168 { return true }
        if b0 == 169 && b1 == 254 { return true }
        if b0 == 100 && (64...127).contains(b1) { return true }
        return false
    }

    public static func discoverLanAddresses() -> [String] {
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let firstAddr = ifaddrPtr else {
            return []
        }
        defer { freeifaddrs(firstAddr) }

        var candidates: [(ip: String, score: Int)] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let entry = cursor {
            let iface = entry.pointee
            cursor = iface.ifa_next
            guard let sa = iface.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            let flags = Int32(iface.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0 else { continue }

            let name = String(cString: iface.ifa_name).lowercased()
            if name.hasPrefix("utun") || name.hasPrefix("llw") || name.hasPrefix("awdl") || name.hasPrefix("bridge") {
                continue
            }

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let res = getnameinfo(
                sa,
                socklen_t(sa.pointee.sa_len),
                &hostname,
                socklen_t(hostname.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard res == 0 else { continue }
            let ip = String(cString: hostname)
            guard isAllowedPeerHost(ip) else { continue }
            let octets = ip.split(separator: ".").compactMap { UInt8($0) }
            guard octets.count == 4, !(octets[0] == 169 && octets[1] == 254) else { continue }

            var score = 100
            if octets[0] == 192 && octets[1] == 168 { score += 30 }
            else if octets[0] == 10 { score += 20 }
            else if octets[0] == 172 { score += 15 }
            if name == "en0" || name == "en1" { score += 20 }
            candidates.append((ip: ip, score: score))
        }

        candidates.sort { $0.score > $1.score }
        var seen = Set<String>()
        return candidates.compactMap { seen.insert($0.ip).inserted ? $0.ip : nil }
    }

    // MARK: - HTTP Handling

    private func handleConnection(_ connection: NWConnection) {
        if case let .hostPort(host, _) = connection.endpoint {
            let peerStr = "\(host)"
            if !Self.isAllowedPeerHost(peerStr) {
                connection.start(queue: queue)
                sendText(connection: connection, status: 403, text: "仅允许局域网设备访问")
                return
            }
        }
        connection.start(queue: queue)
        readHttpMessage(connection: connection, buffer: Data(), expectedBodyLength: nil, headerEndOffset: nil)
    }

    private func readHttpMessage(
        connection: NWConnection,
        buffer: Data,
        expectedBodyLength: Int?,
        headerEndOffset: Int?
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] chunk, _, isComplete, error in
            guard let self = self else {
                connection.cancel()
                return
            }
            if error != nil {
                connection.cancel()
                return
            }
            var data = buffer
            if let chunk = chunk, !chunk.isEmpty {
                data.append(chunk)
            }
            if data.count > WebDavSyncService.maxSyncPayloadBytes + 16_384 {
                self.sendText(connection: connection, status: 413, text: "同步数据超过 8 MB 限制")
                return
            }

            var hdrEnd = headerEndOffset
            var bodyLen = expectedBodyLength

            if hdrEnd == nil, let sepRange = data.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A])) {
                hdrEnd = sepRange.upperBound
                let headerSlice = data.subdata(in: 0..<sepRange.lowerBound)
                let headerStr = String(decoding: headerSlice, as: UTF8.self)
                bodyLen = Self.extractContentLength(from: headerStr)
            }

            if let hEnd = hdrEnd {
                let targetLen = bodyLen ?? 0
                if data.count - hEnd >= targetLen || isComplete {
                    let headerSlice = data.subdata(in: 0..<(hEnd - 4))
                    let actualBodyEnd = min(data.count, hEnd + targetLen)
                    let bodySlice = targetLen > 0 ? data.subdata(in: hEnd..<actualBodyEnd) : Data()
                    self.dispatchHttpRequest(connection: connection, headerData: headerSlice, bodyData: bodySlice)
                    return
                }
            } else if isComplete {
                connection.cancel()
                return
            }

            self.readHttpMessage(
                connection: connection,
                buffer: data,
                expectedBodyLength: bodyLen,
                headerEndOffset: hdrEnd
            )
        }
    }

    private static func extractContentLength(from headerText: String) -> Int {
        for line in headerText.components(separatedBy: "\r\n").dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            if key == "content-length",
               let val = Int(line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)),
               val >= 0
            {
                return val
            }
        }
        return 0
    }

    private func dispatchHttpRequest(connection: NWConnection, headerData: Data, bodyData: Data) {
        let headerStr = String(decoding: headerData, as: UTF8.self)
        let lines = headerStr.components(separatedBy: "\r\n")
        guard let reqLine = lines.first else {
            sendText(connection: connection, status: 400, text: "Bad Request")
            return
        }
        let parts = reqLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else {
            sendText(connection: connection, status: 400, text: "Bad Request")
            return
        }
        let method = parts[0].uppercased()
        let rawPath = parts[1].components(separatedBy: "?").first ?? parts[1]

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let k = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let v = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[k] = v
        }

        let pushPath = "\(tokenPath)/push"
        let syncPath = "\(tokenPath)/sync"
        let bindPath = "\(tokenPath)/bind"
        let netdiskPath = "\(tokenPath)/netdisk"
        let isNetdiskApi = (rawPath == netdiskPath)
        guard rawPath == tokenPath || rawPath == pushPath || rawPath == syncPath || rawPath == bindPath || isNetdiskApi else {
            sendText(connection: connection, status: 404, text: "页面不存在")
            return
        }

        if isExpired {
            sendText(connection: connection, status: 410, text: "局域网配置会话已过期，请重新打开二维码")
            return
        }

        if rawPath == bindPath {
            if let originHeader = headers["origin"], !originHeader.isEmpty {
                sendText(connection: connection, status: 403, text: "禁止跨站绑定")
                return
            }
            handleBindRequest(connection: connection, method: method, bodyData: bodyData)
            return
        }

        if let originHeader = headers["origin"], !originHeader.isEmpty {
            let hostHeader = headers["host"] ?? "127.0.0.1:\(port)"
            if originHeader != "http://\(hostHeader)" {
                sendText(connection: connection, status: 403, text: "来源校验未通过")
                return
            }
        }

        if isNetdiskApi {
            guard method == "POST" else {
                sendText(connection: connection, status: 405, text: "请求方式不支持")
                return
            }
            guard let json = (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any] else {
                sendJsonObject(connection: connection, status: 400, obj: ["ok": false, "error": "无效的 JSON 请求"])
                return
            }
            let driveKey = ((json["drive"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let credential = ((json["credential"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard let driveInfo = NetdiskDriveInfo.info(for: driveKey) else {
                sendJsonObject(connection: connection, status: 400, obj: ["ok": false, "error": "不支持的网盘类型"])
                return
            }
            do {
                try storage.setNetdiskCredential(credential, for: driveInfo.key)
                let evt = LanConfigAppliedEvent(
                    historyCount: storage.watchHistory().count,
                    favoriteCount: storage.favorites().count,
                    subscriptionCount: storage.subscriptions().count,
                    message: "已绑定 \(driveInfo.tvName)（\(driveInfo.providerName)）"
                )
                onApplied?(evt)
                sendJsonObject(
                    connection: connection,
                    status: 200,
                    obj: ["ok": true, "drive": driveInfo.key, "message": evt.message]
                )
            } catch {
                sendJsonObject(
                    connection: connection,
                    status: 400,
                    obj: ["ok": false, "error": error.localizedDescription]
                )
            }
            return
        }

        if rawPath == tokenPath {
            guard method == "GET" else {
                sendText(connection: connection, status: 405, text: "请求方式不支持")
                return
            }
            let hostHeader = headers["host"] ?? "127.0.0.1:\(port)"
            let fullUrl = "http://\(hostHeader)\(tokenPath)"
            sendHtml(connection: connection, status: 200, html: Self.buildMobileWebConsoleHtml(fullUrl: fullUrl))
            return
        }

        if rawPath == syncPath {
            if method == "GET" {
                do {
                    let payload = try syncService.exportSyncPayload()
                    sendJson(connection: connection, status: 200, json: payload)
                } catch {
                    sendText(connection: connection, status: 500, text: error.localizedDescription)
                }
                return
            }
            guard method == "POST" else {
                sendText(connection: connection, status: 405, text: "请求方式不支持")
                return
            }
            do {
                let bodyText = String(decoding: bodyData, as: UTF8.self)
                let merged = try syncService.mergeSyncPayload(bodyText)
                onApplied?(
                    LanConfigAppliedEvent(
                        historyCount: merged.historyCount,
                        favoriteCount: merged.favoriteCount,
                        subscriptionCount: merged.subscriptionCount,
                        message: "局域网双向同步完成"
                    )
                )
                sendJson(connection: connection, status: 200, json: merged.payloadJson)
            } catch {
                sendText(connection: connection, status: 400, text: error.localizedDescription)
            }
            return
        }

        guard method == "POST" else {
            sendText(connection: connection, status: 405, text: "请求方式不支持")
            return
        }
        Task {
            do {
                guard let json = (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any] else {
                    self.sendJsonObject(connection: connection, status: 400, obj: ["ok": false, "error": "无效的 JSON 请求"])
                    return
                }
                let subUrl = ((json["url"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let rawConfig = ((json["rawConfig"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let backupJson = ((json["backupJson"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let customName = ((json["name"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

                if !backupJson.isEmpty || BackupCodec.isBackupPayload(rawConfig) {
                    let backupText = !backupJson.isEmpty ? backupJson : rawConfig
                    let cfg = try self.storage.importBackupJson(backupText)
                    let evt = LanConfigAppliedEvent(
                        historyCount: self.storage.watchHistory().count,
                        favoriteCount: self.storage.favorites().count,
                        subscriptionCount: self.storage.subscriptions().count,
                        message: "备份恢复成功（可用片源 \(cfg.availableSites.count) / 共 \(cfg.sites.count)）"
                    )
                    self.onApplied?(evt)
                    self.sendJsonObject(connection: connection, status: 200, obj: ["ok": true, "message": evt.message])
                    return
                }

                if !rawConfig.isEmpty {
                    let (_, cfg) = try self.storage.upsertSubscription(
                        name: customName,
                        url: subUrl,
                        rawContent: rawConfig
                    )
                    let evt = LanConfigAppliedEvent(
                        historyCount: self.storage.watchHistory().count,
                        favoriteCount: self.storage.favorites().count,
                        subscriptionCount: self.storage.subscriptions().count,
                        message: "配置已导入（可用片源 \(cfg.availableSites.count) / 共 \(cfg.sites.count)）"
                    )
                    self.onApplied?(evt)
                    self.sendJsonObject(connection: connection, status: 200, obj: ["ok": true, "message": evt.message])
                    return
                }

                if !subUrl.isEmpty {
                    let normalized = CmsParser.extractAndNormalizeUrl(subUrl)
                    let (fetchedRaw, firstCfg) = try await self.cmsClient.fetchConfig(from: normalized, defaultName: customName)
                    if firstCfg.isMultiDepotOnly, let firstDepot = firstCfg.depots.first {
                        let (depotRaw, depotCfg) = try await self.cmsClient.fetchDepotConfig(firstDepot)
                        _ = try self.storage.upsertSubscription(
                            name: customName.isEmpty ? firstDepot.name : customName,
                            url: firstDepot.url,
                            rawContent: depotRaw,
                            warehouseUrl: normalized,
                            activeDepotUrl: firstDepot.url,
                            activeDepotName: firstDepot.name,
                            depots: firstCfg.depots
                        )
                        let evt = LanConfigAppliedEvent(
                            historyCount: self.storage.watchHistory().count,
                            favoriteCount: self.storage.favorites().count,
                            subscriptionCount: self.storage.subscriptions().count,
                            message: "多仓已加载（默认仓：\(firstDepot.name)，可用片源 \(depotCfg.availableSites.count)）"
                        )
                        self.onApplied?(evt)
                        self.sendJsonObject(connection: connection, status: 200, obj: ["ok": true, "message": evt.message])
                    } else {
                        let (_, cfg) = try self.storage.upsertSubscription(
                            name: customName,
                            url: normalized,
                            rawContent: fetchedRaw
                        )
                        let evt = LanConfigAppliedEvent(
                            historyCount: self.storage.watchHistory().count,
                            favoriteCount: self.storage.favorites().count,
                            subscriptionCount: self.storage.subscriptions().count,
                            message: "订阅源已推送（可用片源 \(cfg.availableSites.count) / 共 \(cfg.sites.count)）"
                        )
                        self.onApplied?(evt)
                        self.sendJsonObject(connection: connection, status: 200, obj: ["ok": true, "message": evt.message])
                    }
                    return
                }

                self.sendJsonObject(connection: connection, status: 400, obj: ["ok": false, "error": "请输入订阅地址、JSON 配置或上传备份文件"])
            } catch {
                self.sendJsonObject(connection: connection, status: 400, obj: ["ok": false, "error": error.localizedDescription])
            }
        }
    }

    private func handleBindRequest(connection: NWConnection, method: String, bodyData: Data) {
        if method == "GET" {
            do {
                let cfg = storage.loadWebDavConfig()
                let trimmedUrl = cfg.url.trimmingCharacters(in: .whitespacesAndNewlines)
                let parsed = URL(string: trimmedUrl)
                let scheme = parsed?.scheme?.lowercased() ?? ""
                let valid = cfg.isConfigured && (scheme == "http" || scheme == "https") && !(parsed?.host ?? "").isEmpty
                let payload: [String: Any]
                if valid {
                    payload = [
                        "v": 1,
                        "type": "webdav_bind",
                        "mode": "config",
                        "url": trimmedUrl,
                        "username": cfg.username,
                        "password": cfg.password,
                        "auto": cfg.autoSync,
                        "syncSubs": cfg.syncSubscriptions,
                        "syncHistory": cfg.syncHistory,
                    ]
                } else {
                    payload = [
                        "v": 1,
                        "type": "webdav_bind",
                        "mode": "unconfigured",
                    ]
                }
                let sealed = try WebdavBindCrypto.sealJson(key: bindKey, payload: payload)
                sendJson(connection: connection, status: 200, json: sealed)
            } catch {
                sendText(connection: connection, status: 500, text: error.localizedDescription)
            }
            return
        }
        guard method == "POST" else {
            sendText(connection: connection, status: 405, text: "请求方式不支持")
            return
        }
        guard bodyData.count >= 2 && bodyData.count <= 65_536 else {
            sendText(connection: connection, status: 413, text: "绑定请求大小不合法")
            return
        }
        do {
            let envelopeStr = String(decoding: bodyData, as: UTF8.self)
            let obj = try WebdavBindCrypto.openJson(key: bindKey, envelopeJson: envelopeStr)
            guard (obj["type"] as? String) == "webdav_bind",
                  let rawUrl = obj["url"] as? String
            else {
                sendText(connection: connection, status: 400, text: "不支持的绑定载荷")
                return
            }
            let url = rawUrl.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let parsed = URL(string: url),
                  let scheme = parsed.scheme?.lowercased(),
                  (scheme == "http" || scheme == "https"),
                  let host = parsed.host,
                  !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                sendText(connection: connection, status: 400, text: "WebDAV 地址仅支持 HTTP/HTTPS")
                return
            }
            var cfg = storage.loadWebDavConfig()
            cfg.url = url
            cfg.username = ((obj["username"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            cfg.password = (obj["password"] as? String) ?? ""
            cfg.autoSync = (obj["auto"] as? Bool) ?? true
            cfg.syncSubscriptions = (obj["syncSubs"] as? Bool) ?? true
            cfg.syncHistory = (obj["syncHistory"] as? Bool) ?? true
            try storage.saveWebDavConfig(cfg)
            onWebDavBound?(cfg)
            let ack = try WebdavBindCrypto.sealJson(key: bindKey, payload: [
                "v": 1,
                "type": "webdav_bind_ack",
                "ok": true,
                "url": url,
            ])
            sendJson(connection: connection, status: 200, json: ack)
        } catch {
            sendText(connection: connection, status: 400, text: "绑定处理失败")
        }
    }

    // MARK: - Responses & Mobile HTML Console

    private func sendText(connection: NWConnection, status: Int, text: String) {
        sendRaw(connection: connection, status: status, contentType: "text/plain; charset=utf-8", body: Data(text.utf8))
    }

    private func sendHtml(connection: NWConnection, status: Int, html: String) {
        sendRaw(connection: connection, status: status, contentType: "text/html; charset=utf-8", body: Data(html.utf8))
    }

    private func sendJson(connection: NWConnection, status: Int, json: String) {
        sendRaw(connection: connection, status: status, contentType: "application/json; charset=utf-8", body: Data(json.utf8))
    }

    private func sendJsonObject(connection: NWConnection, status: Int, obj: [String: Any]) {
        let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
        sendRaw(connection: connection, status: status, contentType: "application/json; charset=utf-8", body: data)
    }

    private func sendRaw(connection: NWConnection, status: Int, contentType: String, body: Data) {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 400: reason = "Bad Request"
        case 403: reason = "Forbidden"
        case 404: reason = "Not Found"
        case 405: reason = "Method Not Allowed"
        case 410: reason = "Gone"
        case 413: reason = "Payload Too Large"
        default: reason = "Server Error"
        }
        let header = [
            "HTTP/1.1 \(status) \(reason)",
            "Content-Type: \(contentType)",
            "Cache-Control: no-store",
            "X-Content-Type-Options: nosniff",
            "Content-Length: \(body.count)",
            "Connection: close",
            "",
            "",
        ].joined(separator: "\r\n")
        var packet = Data(header.utf8)
        packet.append(body)
        connection.send(content: packet, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func escapeHtml(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    public static func buildMobileWebConsoleHtml(fullUrl: String) -> String {
        let safeUrl = escapeHtml(fullUrl)
        return """
        <!doctype html>
        <html lang="zh-CN">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <title>Marco Movie iOS 局域网配置推送</title>
        <style>
        body{margin:0;background:#0d0e14;color:#f5f5f7;font:15px -apple-system,BlinkMacSystemFont,system-ui,sans-serif;padding:20px}
        main{max-width:560px;margin:2vh auto;background:#171923;border:1px solid #2b2f42;border-radius:20px;padding:24px}
        h1{font-size:22px;margin:0 0 8px}
        p{color:#a8b0c2;line-height:1.6;margin:6px 0 16px}
        label{display:block;font-weight:600;margin:16px 0 8px;color:#dbe1f0}
        input,textarea,select{width:100%;box-sizing:border-box;background:#0f1118;border:1px solid #32384f;border-radius:12px;color:#fff;padding:12px;font-size:14px}
        textarea{min-height:110px;font-family:ui-monospace,monospace}
        button{margin-top:12px;width:100%;background:linear-gradient(135deg,#3b82f6,#6366f1);color:#fff;border:0;border-radius:12px;padding:13px;font-size:15px;font-weight:600;cursor:pointer}
        .status{margin-top:14px;padding:12px;border-radius:12px;display:none;background:#1e293b;color:#93c5fd}
        code{display:block;background:#0f1118;padding:10px 12px;border-radius:10px;color:#60a5fa;word-break:break-all;font-size:13px}
        </style>
        </head>
        <body>
        <main>
          <h1>Marco Movie · iOS 局域网快传</h1>
          <p>粘贴订阅链接、JSON/M3U 配置、网盘会话凭据，或上传 <b>marco-movie-backup.json</b> 备份文件一键同步至本机。</p>
          <label>1. 订阅 / 多仓地址</label>
          <input id="subUrl" type="url" placeholder="粘贴 HTTP(S) 订阅或仓库地址">
          <input id="subName" type="text" placeholder="可选备注名称" style="margin-top:8px">
          <button onclick="pushUrl()">推送订阅地址</button>
          <label>2. 粘贴配置 JSON / M3U / 备份内容</label>
          <textarea id="rawText" placeholder="可直接粘贴 TVBox JSON、M3U 直播列表或 marco-movie-backup JSON"></textarea>
          <button onclick="pushRaw()">推送文本配置</button>
          <label>3. 上传 marco-movie-backup.json 文件</label>
          <input id="backupFile" type="file" accept=".json,application/json">
          <button onclick="pushFile()">上传并恢复备份</button>
          <label>4. 推送 4K 网盘 Cookie / 刷新令牌（仅存系统钥匙串）</label>
          <select id="netdiskDrive">
            <option value="quark">夸克网盘 (__pus / __puus)</option>
            <option value="uc">UC 网盘 (__pus)</option>
            <option value="baidu">百度网盘 (BDUSS)</option>
            <option value="ali">阿里云盘 (refreshToken)</option>
            <option value="115">115 网盘 (UID / CID / SEID)</option>
          </select>
          <textarea id="netdiskCred" style="min-height:76px;margin-top:8px" placeholder="粘贴对应网盘 Cookie 或阿里云盘 refreshToken"></textarea>
          <button onclick="pushNetdisk()">推送网盘凭据</button>
          <div id="statusBox" class="status"></div>
          <label>多端双向同步接口地址</label>
          <code>\(safeUrl)</code>
        </main>
        <script>
        const basePath = location.pathname.replace(/\\/$/, '');
        const pushEndpoint = basePath + '/push';
        const netdiskEndpoint = basePath + '/netdisk';
        function showMsg(msg, isErr) {
          const box = document.getElementById('statusBox');
          box.style.display = 'block';
          box.style.color = isErr ? '#fca5a5' : '#86efac';
          box.textContent = msg;
        }
        async function postPayload(body, endpoint) {
          showMsg('正在推送…', false);
          try {
            const r = await fetch(endpoint || pushEndpoint, {
              method: 'POST',
              headers: {'Content-Type': 'application/json'},
              body: JSON.stringify(body)
            });
            const rawText = await r.text();
            let data = null;
            try { data = JSON.parse(rawText); } catch (_) {}
            if (r.ok && data && data.ok) showMsg(data.message || '推送成功！', false);
            else showMsg((data && data.error) || rawText || ('推送失败 (HTTP ' + r.status + ')'), true);
          } catch (e) {
            showMsg('网络请求失败：' + e, true);
          }
        }
        function pushUrl() { postPayload({ url: document.getElementById('subUrl').value, name: document.getElementById('subName').value }); }
        function pushRaw() { postPayload({ rawConfig: document.getElementById('rawText').value, name: document.getElementById('subName').value }); }
        function pushFile() {
          const f = document.getElementById('backupFile').files[0];
          if (!f) { showMsg('请先选择备份 JSON 文件', true); return; }
          const reader = new FileReader();
          reader.onload = () => postPayload({ backupJson: String(reader.result || '') });
          reader.readAsText(f, 'utf-8');
        }
        function pushNetdisk() { postPayload({ drive: document.getElementById('netdiskDrive').value, credential: document.getElementById('netdiskCred').value }, netdiskEndpoint); }
        </script>
        </body>
        </html>
        """
    }
}
