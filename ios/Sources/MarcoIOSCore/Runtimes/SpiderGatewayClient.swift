// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only

import Foundation
import Network

public struct SpiderGatewayHealth: Equatable, Sendable {
    public let ok: Bool
    public let protocolId: String
    public let deviceName: String
    public let engine: String
    public let supportsNativeSo: Bool
    public let latencyMs: Int
    public let message: String

    public init(
        ok: Bool,
        protocolId: String = "",
        deviceName: String = "",
        engine: String = "",
        supportsNativeSo: Bool = false,
        latencyMs: Int = 0,
        message: String = ""
    ) {
        self.ok = ok
        self.protocolId = protocolId
        self.deviceName = deviceName
        self.engine = engine
        self.supportsNativeSo = supportsNativeSo
        self.latencyMs = latencyMs
        self.message = message
    }
}

public struct DiscoveredSpiderGateway: Equatable, Hashable, Identifiable, Sendable {
    public var id: String { baseUrl }
    public let baseUrl: String
    public let deviceName: String
    public let engine: String
    public let supportsNativeSo: Bool
    public let requiresToken: Bool

    public init(
        baseUrl: String,
        deviceName: String,
        engine: String = "android-csp",
        supportsNativeSo: Bool = true,
        requiresToken: Bool = true
    ) {
        self.baseUrl = baseUrl
        self.deviceName = deviceName
        self.engine = engine
        self.supportsNativeSo = supportsNativeSo
        self.requiresToken = requiresToken
    }
}

/// Client for the open `marco-spider-gateway-v1` BYO protocol allowing users to pair
/// their own LAN Android companion device or self-hosted Docker/NAS gateway for JAR/`.so` spiders.
public final class SpiderGatewayClient: @unchecked Sendable {
    public static let protocolId = "marco-spider-gateway-v1"
    public static let discoveryUdpPort: UInt16 = 41978
    public static let discoveryProbePayload = "MARCO_SPIDER_GATEWAY_PROBE_V1"
    public static let maxResponseBytes = 8 * 1024 * 1024

    private let session: URLSession

    public init(session: URLSession? = nil) {
        if let session = session {
            self.session = session
        } else {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = 15
            cfg.timeoutIntervalForResource = 30
            cfg.httpShouldSetCookies = false
            self.session = URLSession(configuration: cfg)
        }
    }

    public func checkHealth(config: SpiderGatewayConfig) async -> SpiderGatewayHealth {
        let base = config.normalizedBaseUrl
        guard !base.isEmpty, let url = URL(string: "\(base)/marco-gateway/v1/health") else {
            return SpiderGatewayHealth(ok: false, message: "请先填写有效的蜘蛛网关地址（http:// 或 https://）")
        }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        req.httpMethod = "GET"
        for (k, v) in headers(for: config, jsonBody: false) { req.setValue(v, forHTTPHeaderField: k) }

        let start = Date()
        do {
            let (data, resp) = try await session.marcoData(for: req)
            let latencyMs = Int(Date().timeIntervalSince(start) * 1000)
            guard let http = resp as? HTTPURLResponse else {
                return SpiderGatewayHealth(ok: false, latencyMs: latencyMs, message: "网关未返回有效 HTTP 响应")
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                return SpiderGatewayHealth(ok: false, latencyMs: latencyMs, message: "鉴权失败（HTTP \(http.statusCode)），请核对访问令牌")
            }
            guard (200...299).contains(http.statusCode) else {
                return SpiderGatewayHealth(ok: false, latencyMs: latencyMs, message: "网关返回异常状态码 HTTP \(http.statusCode)")
            }
            guard data.count <= Self.maxResponseBytes,
                  let doc = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else {
                return SpiderGatewayHealth(ok: false, latencyMs: latencyMs, message: "目标地址未返回合法的健康信息")
            }
            let ok = (doc["ok"] as? Bool) ?? true
            let deviceName = ((doc["deviceName"] ?? doc["name"]) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let engine = (doc["engine"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "spider-gateway"
            let supportsSo = (doc["supportsNativeSo"] as? Bool) ?? false
            let proto = (doc["protocol"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? Self.protocolId
            let msg: String
            if ok {
                let nameLabel = deviceName.isEmpty ? "" : "「\(deviceName)」"
                let soBadge = supportsSo ? " · 支持 .so" : ""
                msg = "已连接\(nameLabel)（\(latencyMs)ms\(soBadge)）"
            } else {
                msg = (doc["error"] as? String) ?? "网关状态不可用"
            }
            return SpiderGatewayHealth(
                ok: ok,
                protocolId: proto,
                deviceName: deviceName,
                engine: engine,
                supportsNativeSo: supportsSo,
                latencyMs: latencyMs,
                message: msg
            )
        } catch {
            return SpiderGatewayHealth(ok: false, message: sanitizeError(error))
        }
    }

    public func invoke(
        config: SpiderGatewayConfig,
        site: CmsSite,
        action: String,
        params: [String: Any] = [:]
    ) async throws -> String {
        guard config.isActive else {
            throw MarcoError.unsupported("蜘蛛网关未启用，请在「设置 -> 蜘蛛扩展与网关」中配置")
        }
        guard let url = URL(string: "\(config.normalizedBaseUrl)/marco-gateway/v1/invoke") else {
            throw MarcoError.invalidFormat("蜘蛛网关地址无效")
        }

        let payload: [String: Any] = [
            "protocol": Self.protocolId,
            "action": action,
            "site": [
                "key": site.sourceKey,
                "name": site.name,
                "api": site.sourceApi,
                "type": site.type,
                "ext": site.rawExtension ?? site.ext,
                "jar": site.jar,
                "spider": site.spider,
                "playUrl": site.playUrl,
            ],
            "params": params,
        ]
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        req.httpMethod = "POST"
        for (k, v) in headers(for: config, jsonBody: true) { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, resp) = try await session.marcoData(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw MarcoError.networkFailure("蜘蛛网关未返回有效响应")
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw MarcoError.networkFailure("蜘蛛网关鉴权失败（HTTP \(http.statusCode)），请检查访问令牌")
        }
        guard (200...299).contains(http.statusCode) else {
            var detail = "HTTP \(http.statusCode)"
            if let errDoc = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let msg = errDoc["error"] as? String, !msg.isEmpty
            {
                detail = msg
            }
            throw MarcoError.networkFailure("蜘蛛网关执行失败：\(detail)")
        }
        guard data.count <= Self.maxResponseBytes else {
            throw MarcoError.networkFailure("蜘蛛网关返回数据超过 8 MB 上限")
        }
        let rawText = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawText.isEmpty else {
            throw MarcoError.networkFailure("蜘蛛网关返回了空响应")
        }
        if let decoded = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            if (decoded["ok"] as? Bool) == false {
                let err = (decoded["error"] as? String) ?? "网关解析失败"
                throw MarcoError.networkFailure(err)
            }
            if let resultStr = decoded["result"] as? String {
                return resultStr
            }
            if let resultObj = decoded["result"], JSONSerialization.isValidJSONObject(resultObj),
               let encoded = try? JSONSerialization.data(withJSONObject: resultObj)
            {
                return String(decoding: encoded, as: UTF8.self)
            }
            if let dataObj = decoded["data"], JSONSerialization.isValidJSONObject(dataObj),
               let encoded = try? JSONSerialization.data(withJSONObject: dataObj)
            {
                return String(decoding: encoded, as: UTF8.self)
            }
        }
        return rawText
    }

    public static func parseDiscoveryBeacon(_ data: Data) -> DiscoveredSpiderGateway? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let baseUrl = (obj["baseUrl"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let u = URL(string: baseUrl),
              let scheme = u.scheme?.lowercased(), (scheme == "http" || scheme == "https"),
              let host = u.host, !host.isEmpty
        else { return nil }
        return DiscoveredSpiderGateway(
            baseUrl: baseUrl,
            deviceName: ((obj["deviceName"] ?? obj["name"]) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? host,
            engine: (obj["engine"] as? String) ?? "android-csp",
            supportsNativeSo: (obj["supportsNativeSo"] as? Bool) ?? true,
            requiresToken: (obj["requiresToken"] as? Bool) ?? true
        )
    }

    private func headers(for config: SpiderGatewayConfig, jsonBody: Bool) -> [String: String] {
        var h: [String: String] = [
            "Accept": "application/json",
            "X-Marco-Gateway-Protocol": Self.protocolId,
        ]
        if jsonBody { h["Content-Type"] = "application/json; charset=utf-8" }
        let tok = config.token.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tok.isEmpty { h["Authorization"] = "Bearer \(tok)" }
        return h
    }

    private func sanitizeError(_ error: Error) -> String {
        let raw = error.localizedDescription
        if let re = try? NSRegularExpression(pattern: #"Bearer\s+\S+"#, options: [.caseInsensitive]) {
            return re.stringByReplacingMatches(in: raw, range: NSRange(raw.startIndex..., in: raw), withTemplate: "Bearer ***")
        }
        return raw.isEmpty ? "网关连接失败" : raw
    }
}
