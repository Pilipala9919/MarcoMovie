// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only

import Foundation
#if canImport(MarcoNativeBridges)
import MarcoNativeBridges
#endif

public struct PythonRuntimeStatus: Equatable, Sendable {
    public let ready: Bool
    public let backend: String
    public let version: String
    public let maxSessions: Int

    public init(ready: Bool, backend: String, version: String, maxSessions: Int = 2) {
        self.ready = ready
        self.backend = backend
        self.version = version
        self.maxSessions = maxSessions
    }
}

public struct PythonPackageDescriptor: Sendable {
    public let entryModule: String
    public let files: [String: Data]
    public let extensionValue: String
    public let remoteUrl: String?
    public let remoteHeaders: [String: String]

    public init(
        entryModule: String,
        files: [String: Data],
        extensionValue: String = "",
        remoteUrl: String? = nil,
        remoteHeaders: [String: String] = [:]
    ) throws {
        guard !files.isEmpty, files.count <= 256,
              files[entryModule] != nil,
              entryModule.hasSuffix(".py"),
              extensionValue.utf8.count <= 64 * 1024
        else {
            throw MarcoError.invalidFormat("无效的 Python 片源包结构")
        }
        var totalBytes = 0
        for (name, data) in files {
            guard !name.isEmpty, name.count <= 1024,
                  !name.hasPrefix("/"),
                  !name.contains("\\"),
                  !name.contains(":"),
                  data.count <= 2 * 1024 * 1024
            else {
                throw MarcoError.invalidFormat("Python 片源包内包含非法文件路径或过大文件")
            }
            let segs = name.split(separator: "/").map(String.init)
            if segs.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) {
                throw MarcoError.invalidFormat("Python 片源包路径包含非法目录跳转")
            }
            totalBytes += data.count
        }
        guard totalBytes <= 6 * 1024 * 1024 else {
            throw MarcoError.invalidFormat("Python 片源包总大小超过 6 MB 限制")
        }
        self.entryModule = entryModule
        self.files = files
        self.extensionValue = extensionValue
        self.remoteUrl = remoteUrl
        self.remoteHeaders = remoteHeaders
    }
}

public protocol PythonNativeBridgeTransport: Sendable {
    var isAvailable: Bool { get }
    func capabilities() -> PythonRuntimeStatus
    func openSession(
        sessionId: String,
        package: PythonPackageDescriptor,
        proxyBaseURL: String?
    ) async throws
    func callSession(
        sessionId: String,
        callId: String,
        method: String,
        argumentsJSON: String,
        timeoutMs: Int
    ) async throws -> String
    func cancelCall(sessionId: String, callId: String)
    func closeSession(sessionId: String) async
}

#if canImport(MarcoNativeBridges)
private final class NativeBridgePythonTransport: PythonNativeBridgeTransport {
    var isAvailable: Bool {
        MMPythonNativeBridge.isRuntimeAvailable()
    }

    func capabilities() -> PythonRuntimeStatus {
        guard isAvailable else {
            return PythonRuntimeStatus(ready: false, backend: "cpython-unavailable", version: "", maxSessions: 0)
        }
        let caps = MMPythonNativeBridge.capabilities()
        let runtime = (caps["runtime"] as? String) ?? "3.14"
        let maxSess = (caps["maxSessions"] as? NSNumber)?.intValue ?? 2
        return PythonRuntimeStatus(ready: true, backend: "cpython-3.14-ios", version: runtime, maxSessions: max(1, maxSess))
    }

    func openSession(
        sessionId: String,
        package: PythonPackageDescriptor,
        proxyBaseURL: String?
    ) async throws {
        guard isAvailable else {
            throw MarcoError.unsupported("当前轻量版未嵌入 CPython 运行库，请安装完整版 IPA")
        }
        var remoteDesc: [String: Any]?
        if let rUrl = package.remoteUrl, !rUrl.isEmpty {
            remoteDesc = ["url": rUrl, "headers": package.remoteHeaders]
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            MMPythonNativeBridge.openSession(
                withSessionId: sessionId,
                packageFiles: package.files,
                entryModule: package.entryModule,
                extension: package.extensionValue,
                proxyBaseURL: proxyBaseURL,
                remoteDescriptor: remoteDesc
            ) { _, error in
                if let error = error {
                    cont.resume(throwing: MarcoError.scriptExecutionFailed(error.localizedDescription))
                } else {
                    cont.resume(returning: ())
                }
            }
        }
    }

    func callSession(
        sessionId: String,
        callId: String,
        method: String,
        argumentsJSON: String,
        timeoutMs: Int
    ) async throws -> String {
        guard isAvailable else {
            throw MarcoError.unsupported("当前轻量版未嵌入 CPython 运行库，请安装完整版 IPA")
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
                MMPythonNativeBridge.callSession(
                    withSessionId: sessionId,
                    callId: callId,
                    method: method,
                    argumentsJSON: argumentsJSON,
                    timeoutMs: timeoutMs
                ) { jsonResult, error in
                    if let error = error {
                        cont.resume(throwing: MarcoError.scriptExecutionFailed(error.localizedDescription))
                    } else {
                        cont.resume(returning: jsonResult ?? "{}")
                    }
                }
            }
        } onCancel: {
            MMPythonNativeBridge.cancelCall(withSessionId: sessionId, callId: callId)
        }
    }

    func cancelCall(sessionId: String, callId: String) {
        if isAvailable {
            MMPythonNativeBridge.cancelCall(withSessionId: sessionId, callId: callId)
        }
    }

    func closeSession(sessionId: String) async {
        guard isAvailable else { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            MMPythonNativeBridge.closeSession(withSessionId: sessionId) {
                cont.resume()
            }
        }
    }
}
#endif

private final class UnavailablePythonTransport: PythonNativeBridgeTransport {
    var isAvailable: Bool { false }

    func capabilities() -> PythonRuntimeStatus {
        PythonRuntimeStatus(ready: false, backend: "cpython-unavailable", version: "", maxSessions: 0)
    }

    func openSession(sessionId: String, package: PythonPackageDescriptor, proxyBaseURL: String?) async throws {
        throw MarcoError.unsupported("当前构建未启用 CPython 运行时")
    }

    func callSession(sessionId: String, callId: String, method: String, argumentsJSON: String, timeoutMs: Int) async throws -> String {
        throw MarcoError.unsupported("当前构建未启用 CPython 运行时")
    }

    func cancelCall(sessionId: String, callId: String) {}
    func closeSession(sessionId: String) async {}
}

/// Manages session-pooled native CPython 3.14 TVBox Spider execution on iOS (`MMPythonNativeBridge`).
public actor PythonSourceHost {
    public static let shared = PythonSourceHost()

    private let transport: PythonNativeBridgeTransport
    private var openSessionsByKey: [String: String] = [:]
    private var sessionAccessOrder: [String] = []

    public init(transport: PythonNativeBridgeTransport? = nil) {
        if let custom = transport {
            self.transport = custom
        } else {
            #if canImport(MarcoNativeBridges)
            self.transport = NativeBridgePythonTransport()
            #else
            self.transport = UnavailablePythonTransport()
            #endif
        }
    }

    public nonisolated var isRuntimeAvailable: Bool {
        transport.isAvailable
    }

    public nonisolated func runtimeStatus() -> PythonRuntimeStatus {
        transport.capabilities()
    }

    public func ensureSession(
        for site: CmsSite,
        scriptSource: String,
        proxyBaseURL: String? = nil
    ) async throws -> String {
        guard transport.isAvailable else {
            throw MarcoError.unsupported("当前轻量模式未嵌入 Python 运行库，请安装完整版 IPA")
        }
        let sessionKey = "\(site.subscriptionId)|\(site.key)|\(site.api)|\(site.ext.hashValue)"
        if let existingId = openSessionsByKey[sessionKey] {
            touchSessionOrder(sessionKey)
            return existingId
        }

        let maxSessions = max(1, transport.capabilities().maxSessions)
        while openSessionsByKey.count >= maxSessions, let oldestKey = sessionAccessOrder.first {
            sessionAccessOrder.removeFirst()
            if let oldId = openSessionsByKey.removeValue(forKey: oldestKey) {
                await transport.closeSession(sessionId: oldId)
            }
        }

        let entryName = "spider.py"
        let pkg = try PythonPackageDescriptor(
            entryModule: entryName,
            files: [entryName: Data(scriptSource.utf8)],
            extensionValue: site.rawExtension ?? site.ext,
            remoteUrl: site.isHttpApi ? site.api : nil,
            remoteHeaders: site.headers
        )
        let sessionId = UUID().uuidString.lowercased()
        try await transport.openSession(sessionId: sessionId, package: pkg, proxyBaseURL: proxyBaseURL)
        openSessionsByKey[sessionKey] = sessionId
        touchSessionOrder(sessionKey)
        return sessionId
    }

    public func invoke(
        sessionId: String,
        method: String,
        arguments: [Any],
        timeoutMs: Int = 20_000
    ) async throws -> String {
        let argData = try JSONSerialization.data(withJSONObject: arguments)
        let argsJson = String(decoding: argData, as: UTF8.self)
        let callId = Self.randomCallId()
        return try await transport.callSession(
            sessionId: sessionId,
            callId: callId,
            method: method,
            argumentsJSON: argsJson,
            timeoutMs: min(max(1_000, timeoutMs), 45_000)
        )
    }

    public func homeContent(site: CmsSite, scriptSource: String) async throws -> SiteHomePayload {
        let sid = try await ensureSession(for: site, scriptSource: scriptSource)
        let rawHome = try await invoke(sessionId: sid, method: "homeContent", arguments: [true])
        var categories = CmsParser.parseCategories(rawHome)
        var listing = try CmsParser.parseListing(rawHome)
        if listing.videos.isEmpty {
            if let rawVod = try? await invoke(sessionId: sid, method: "homeVideoContent", arguments: []),
               let vodListing = try? CmsParser.parseListing(rawVod),
               !vodListing.videos.isEmpty
            {
                listing = vodListing
            } else if let firstCat = categories.first,
                      let catListing = try? await categoryContent(site: site, scriptSource: scriptSource, tid: firstCat.id, page: 1),
                      !catListing.videos.isEmpty
            {
                listing = catListing
            }
        }
        if categories.isEmpty && !listing.videos.isEmpty {
            categories = [CmsCategory(id: "all", name: "精选")]
        }
        return SiteHomePayload(categories: categories, listing: listing)
    }

    public func categoryContent(
        site: CmsSite,
        scriptSource: String,
        tid: String,
        page: Int = 1,
        extend: [String: String] = [:]
    ) async throws -> CmsListing {
        let sid = try await ensureSession(for: site, scriptSource: scriptSource)
        let raw = try await invoke(
            sessionId: sid,
            method: "categoryContent",
            arguments: [tid, "\(max(1, page))", true, extend]
        )
        return try CmsParser.parseListing(raw)
    }

    public func detailContent(site: CmsSite, scriptSource: String, ids: [String]) async throws -> CmsVideo? {
        let sid = try await ensureSession(for: site, scriptSource: scriptSource)
        let raw = try await invoke(sessionId: sid, method: "detailContent", arguments: [ids])
        return try CmsParser.parseListing(raw).videos.first
    }

    public func searchContent(site: CmsSite, scriptSource: String, keyword: String, page: Int = 1) async throws -> [CmsVideo] {
        let sid = try await ensureSession(for: site, scriptSource: scriptSource)
        let raw = try await invoke(sessionId: sid, method: "searchContent", arguments: [keyword, false, "\(max(1, page))"])
        return try CmsParser.parseListing(raw).videos
    }

    public func playerContent(
        site: CmsSite,
        scriptSource: String,
        flag: String,
        id: String,
        vipFlags: [String] = []
    ) async throws -> JsResolvedPlayStream {
        let sid = try await ensureSession(for: site, scriptSource: scriptSource)
        let raw = try await invoke(sessionId: sid, method: "playerContent", arguments: [flag, id, vipFlags])
        let cleaned = ConfigDecoder.stripJsonComments(raw)
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(cleaned.utf8))) as? [String: Any] else {
            return JsResolvedPlayStream(url: id)
        }
        let url = (obj["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? id
        let parseFlag = (obj["parse"] as? NSNumber)?.intValue ?? 0
        var hdrs: [String: String] = [:]
        if let hMap = (obj["header"] ?? obj["headers"]) as? [String: Any] {
            for (k, v) in hMap where !(v is NSNull) { hdrs[k] = String(describing: v) }
        }
        return JsResolvedPlayStream(url: url, headers: hdrs, parse: parseFlag)
    }

    public func closeAll() async {
        let allIds = Array(openSessionsByKey.values)
        openSessionsByKey.removeAll()
        sessionAccessOrder.removeAll()
        for sid in allIds {
            await transport.closeSession(sessionId: sid)
        }
    }

    private func touchSessionOrder(_ key: String) {
        if let idx = sessionAccessOrder.firstIndex(of: key) {
            sessionAccessOrder.remove(at: idx)
        }
        sessionAccessOrder.append(key)
    }

    private static func randomCallId() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in 0..<bytes.count { bytes[i] = UInt8.random(in: 0...255) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
