// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only

import CryptoKit
import Foundation
#if canImport(MarcoNativeBridges)
import MarcoNativeBridges
#endif

public struct CatpawRuntimeStatus: Equatable, Sendable {
    public let available: Bool
    public let started: Bool
    public let exited: Bool
    public let baseUrl: String?

    public init(available: Bool, started: Bool, exited: Bool, baseUrl: String? = nil) {
        self.available = available
        self.started = started
        self.exited = exited
        self.baseUrl = baseUrl
    }
}

public protocol CatpawNativeBridgeTransport: Sendable {
    var isAvailable: Bool { get }
    func start(root: String, script: String, ready: String) throws
    func status() -> (started: Bool, exited: Bool)
}

#if canImport(MarcoNativeBridges)
private final class NativeBridgeCatpawTransport: CatpawNativeBridgeTransport {
    var isAvailable: Bool {
        MMCatpawNativeBridge.isRuntimeAvailable()
    }

    func start(root: String, script: String, ready: String) throws {
        guard isAvailable else {
            throw MarcoError.unsupported("当前构建未包含 CatPaw Node.js 本机运行时，请安装完整版 IPA")
        }
        try MMCatpawNativeBridge.start(withRoot: root, script: script, ready: ready)
    }

    func status() -> (started: Bool, exited: Bool) {
        guard isAvailable else { return (false, false) }
        let dict = MMCatpawNativeBridge.status()
        let started = dict["started"]?.boolValue ?? false
        let exited = dict["exited"]?.boolValue ?? false
        return (started, exited)
    }
}
#endif

private final class UnavailableCatpawTransport: CatpawNativeBridgeTransport {
    var isAvailable: Bool { false }
    func start(root: String, script: String, ready: String) throws {
        throw MarcoError.unsupported("当前构建未包含 CatPaw Node.js 本机运行时")
    }
    func status() -> (started: Bool, exited: Bool) { (false, false) }
}

/// Pure-Swift host managing the embedded NodeMobile (`MMCatpawNativeBridge`) loopback server
/// for `catpaw://` bundles, including asset staging, `ready.json` handshake, `wexfnwconfig.json`
/// netdisk credential sync, and post-background XNU socket rebind recovery.
public actor CatpawSourceHost {
    public static let shared = CatpawSourceHost()

    private let transport: CatpawNativeBridgeTransport
    private let rootDirectory: URL
    private let session: URLSession
    private var baseUrl: URL?
    private var rebindSeq: Int = 0

    public init(
        transport: CatpawNativeBridgeTransport? = nil,
        rootDirectory: URL? = nil,
        session: URLSession? = nil
    ) {
        if let custom = transport {
            self.transport = custom
        } else {
            #if canImport(MarcoNativeBridges)
            self.transport = NativeBridgeCatpawTransport()
            #else
            self.transport = UnavailableCatpawTransport()
            #endif
        }
        if let customRoot = rootDirectory {
            self.rootDirectory = customRoot
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.rootDirectory = appSupport.appendingPathComponent("MarcoMovie/catpaw", isDirectory: true)
        }
        if let session = session {
            self.session = session
        } else {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = 20
            cfg.timeoutIntervalForResource = 45
            cfg.httpShouldSetCookies = false
            self.session = URLSession(configuration: cfg)
        }
    }

    public nonisolated var isRuntimeAvailable: Bool {
        transport.isAvailable
    }

    public func runtimeStatus() -> CatpawRuntimeStatus {
        let st = transport.status()
        return CatpawRuntimeStatus(
            available: transport.isAvailable,
            started: st.started,
            exited: st.exited,
            baseUrl: baseUrl?.absoluteString
        )
    }

    /// Parses `ready.json` (`{"port": 12345, "secret": "<64-hex>", "seq": 1}`) written by `host.cjs`.
    public static func parseReadyJson(_ rawText: String) -> (base: URL, seq: Int)? {
        guard let data = rawText.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let port = (obj["port"] as? NSNumber)?.intValue,
              port > 0 && port < 65536,
              let secret = obj["secret"] as? String,
              secret.count == 64,
              secret.utf8.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }),
              let url = URL(string: "http://127.0.0.1:\(port)/\(secret)")
        else {
            return nil
        }
        let seq = (obj["seq"] as? NSNumber)?.intValue ?? 0
        return (url, seq)
    }

    /// Syncs local netdisk credentials into `wexfnwconfig.json` inside CatPaw's sandbox directory.
    public func syncNetdiskConfig(from storage: IOSStorageManager) {
        try? FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        let quarkCookie = storage.netdiskCredential(for: "quark")
        let ucCookie = storage.netdiskCredential(for: "uc")
        let baiduCookie = storage.netdiskCredential(for: "baidu")
        let aliToken = storage.netdiskCredential(for: "ali")
        let drive115Cookie = storage.netdiskCredential(for: "115")
        let cfgUrl = rootDirectory.appendingPathComponent("wexfnwconfig.json")
        if quarkCookie.isEmpty && ucCookie.isEmpty && baiduCookie.isEmpty && aliToken.isEmpty && drive115Cookie.isEmpty
            && !FileManager.default.fileExists(atPath: cfgUrl.path)
        {
            return
        }
        let payload: [String: Any] = [
            "pan": [
                "quark": ["cookie": quarkCookie],
                "uc": ["cookie": ucCookie],
                "baidu": ["cookie": baiduCookie],
                "ali": ["token": aliToken],
                "115": ["cookie": drive115Cookie],
            ],
            "order": storage.preferences().netdiskDriveOrder,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) {
            try? data.write(to: cfgUrl, options: [.atomic])
        }
    }

    /// Ensures the embedded NodeMobile CatPaw host is started and healthy on loopback.
    public func ensureRunning(storage: IOSStorageManager? = nil) async throws -> URL {
        if let current = baseUrl, await probeHealth(base: current) {
            return current
        }
        guard transport.isAvailable else {
            throw MarcoError.unsupported("当前构建未包含 CatPaw Node.js 本机运行时，请安装完整版 IPA")
        }

        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        try stageBundledAssets()
        if let storage = storage {
            syncNetdiskConfig(from: storage)
        }

        let hostScript = rootDirectory.appendingPathComponent("host.cjs")
        let readyFile = rootDirectory.appendingPathComponent("ready.json")

        let st = transport.status()
        if st.exited {
            baseUrl = nil
            throw MarcoError.scriptExecutionFailed("CatPaw 本机服务已退出，请彻底关闭并重新打开应用")
        }
        if !st.started {
            try? FileManager.default.removeItem(at: readyFile)
            try transport.start(root: rootDirectory.path, script: hostScript.path, ready: readyFile.path)
        }

        let deadline = Date().addingTimeInterval(12.0)
        while Date() < deadline {
            try Task.checkCancellation()
            if FileManager.default.fileExists(atPath: readyFile.path),
               let raw = try? String(contentsOf: readyFile, encoding: .utf8),
               let parsed = Self.parseReadyJson(raw)
            {
                if parsed.seq > rebindSeq { rebindSeq = parsed.seq }
                if await probeHealth(base: parsed.base) {
                    baseUrl = parsed.base
                    return parsed.base
                }
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw MarcoError.scriptExecutionFailed("CatPaw 本机服务启动超时")
    }

    /// Proactively recovers the loopback socket after iOS background suspension (XNU socket defuncting).
    public func onAppResumed() async {
        guard let current = baseUrl else { return }
        if await probeHealth(base: current) { return }
        _ = try? await recoverLoopback(failedBase: current)
    }

    private func recoverLoopback(failedBase: URL) async throws -> URL {
        let readyFile = rootDirectory.appendingPathComponent("ready.json")
        let rebindFile = rootDirectory.appendingPathComponent("rebind.json")
        rebindSeq += 1
        let targetSeq = rebindSeq
        var body: [String: Any] = ["version": 1, "seq": targetSeq]
        if let port = failedBase.port { body["failedPort"] = port }
        if let data = try? JSONSerialization.data(withJSONObject: body) {
            try? data.write(to: rebindFile, options: [.atomic])
        }

        let deadline = Date().addingTimeInterval(6.0)
        while Date() < deadline {
            try Task.checkCancellation()
            if FileManager.default.fileExists(atPath: readyFile.path),
               let raw = try? String(contentsOf: readyFile, encoding: .utf8),
               let parsed = Self.parseReadyJson(raw),
               (parsed.seq >= targetSeq || parsed.base != failedBase),
               await probeHealth(base: parsed.base)
            {
                if parsed.seq > rebindSeq { rebindSeq = parsed.seq }
                baseUrl = parsed.base
                return parsed.base
            }
            try await Task.sleep(nanoseconds: 35_000_000)
        }
        baseUrl = nil
        throw MarcoError.scriptExecutionFailed("CatPaw 本机服务连接已中断，请重试")
    }

    /// Invokes a CatPaw Spider HTTP endpoint (`home`, `category`, `detail`, `search`, `play`).
    public func callEndpoint(
        path: String,
        body: [String: Any],
        storage: IOSStorageManager? = nil
    ) async throws -> String {
        let base = try await ensureRunning(storage: storage)
        let cleanPath = path.hasPrefix("/") ? path : "/\(path)"
        guard let url = URL(string: base.absoluteString + cleanPath) else {
            throw MarcoError.invalidFormat("无效的 CatPaw 接口路径")
        }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 25)
        req.httpMethod = "POST"
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        do {
            let (data, resp) = try await session.marcoData(for: req)
            if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw MarcoError.scriptExecutionFailed("CatPaw 接口返回 HTTP \(http.statusCode)")
            }
            return String(decoding: data, as: UTF8.self)
        } catch {
            // Attempt one loopback socket rebind retry on transport error
            let recovered = try await recoverLoopback(failedBase: base)
            guard let retryUrl = URL(string: recovered.absoluteString + cleanPath) else { throw error }
            req.url = retryUrl
            let (data, resp) = try await session.marcoData(for: req)
            if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw MarcoError.scriptExecutionFailed("CatPaw 接口返回 HTTP \(http.statusCode)")
            }
            return String(decoding: data, as: UTF8.self)
        }
    }

    private func probeHealth(base: URL) async -> Bool {
        guard let healthUrl = URL(string: "\(base.absoluteString)/health") else { return false }
        var req = URLRequest(url: healthUrl, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 1.5)
        req.httpMethod = "GET"
        guard let (_, resp) = try? await session.marcoData(for: req),
              let http = resp as? HTTPURLResponse
        else { return false }
        return http.statusCode == 200
    }

    private func stageBundledAssets() throws {
        let requiredFiles = ["host.cjs", "fetch.cjs"]
        for fileName in requiredFiles {
            if let content = CatPawAssetLoader.loadAsset(named: fileName) {
                let target = rootDirectory.appendingPathComponent(fileName)
                try Data(content.utf8).write(to: target, options: [.atomic])
            }
        }
    }
}
