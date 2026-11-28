// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only

import CryptoKit
import Foundation
import Network

public struct ProxyUpstreamResponse: Sendable {
    public var statusCode: Int
    public var headers: [String: String]
    public var body: Data

    public init(statusCode: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }
}

public typealias ProxyUpstreamFetcher = @Sendable (
    _ url: URL,
    _ method: String,
    _ headers: [String: String]
) async throws -> ProxyUpstreamResponse

private final class LocalHeaderNoRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
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

private final class CancellableDataTaskState: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var cancelled = false

    func attach(_ dataTask: URLSessionDataTask) {
        lock.lock()
        let shouldCancel = cancelled
        task = dataTask
        lock.unlock()
        if shouldCancel {
            dataTask.cancel()
        } else {
            dataTask.resume()
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let current = task
        lock.unlock()
        current?.cancel()
    }
}

/// 256 KiB block-aligned LRU disk cache for media proxy streaming.
public actor DiskBlockCache {
    public static let blockSize = 256 * 1024
    public static let defaultMaxBytes = 256 * 1024 * 1024

    public let directory: URL
    public private(set) var maxBytes: Int
    public private(set) var currentBytes: Int = 0
    private var accessOrder: [String] = []
    private var blockSizes: [String: Int] = [:]

    public init(directory: URL? = nil, maxBytes: Int = DiskBlockCache.defaultMaxBytes) {
        if let dir = directory {
            self.directory = dir
        } else {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.directory = caches.appendingPathComponent("MarcoMovieMediaBlocks", isDirectory: true)
        }
        self.maxBytes = max(0, maxBytes)
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    public static func cacheKey(for urlString: String) -> String {
        let hex = SHA256.hash(data: Data(urlString.utf8)).map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(32))
    }

    public func configureMaxBytes(_ bytes: Int) {
        maxBytes = max(0, bytes)
        if maxBytes == 0 {
            clearAll()
        } else {
            evictIfNeeded()
        }
    }

    public func readBlock(key: String, blockIndex: Int) -> Data? {
        guard maxBytes > 0 else { return nil }
        let name = "\(key)_\(blockIndex).blk"
        let fileUrl = directory.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: fileUrl) else { return nil }
        touch(name: name, size: data.count)
        return data
    }

    public func writeBlock(key: String, blockIndex: Int, data: Data) {
        guard maxBytes > 0, !data.isEmpty, data.count <= Self.blockSize * 2 else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = "\(key)_\(blockIndex).blk"
        let fileUrl = directory.appendingPathComponent(name)
        do {
            try data.write(to: fileUrl, options: [.atomic])
            touch(name: name, size: data.count)
            evictIfNeeded()
        } catch {}
    }

    public func clearAll() {
        accessOrder.removeAll()
        blockSizes.removeAll()
        currentBytes = 0
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func touch(name: String, size: Int) {
        if let prev = blockSizes[name] {
            currentBytes = max(0, currentBytes - prev)
        }
        if let idx = accessOrder.firstIndex(of: name) {
            accessOrder.remove(at: idx)
        }
        accessOrder.append(name)
        blockSizes[name] = size
        currentBytes += size
    }

    private func evictIfNeeded() {
        while currentBytes > maxBytes, !accessOrder.isEmpty {
            let oldest = accessOrder.removeFirst()
            let size = blockSizes.removeValue(forKey: oldest) ?? 0
            currentBytes = max(0, currentBytes - size)
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(oldest))
        }
    }
}

/// Loopback-only (`127.0.0.1`) HTTP proxy for iOS `AVPlayer` and `libmpv` that evaluates per-target
/// `NetdiskHeaderPolicy` isolation across HLS manifests, sub-playlists, segments, and redirects,
/// supports HLS VOD discontinuity ad stripping (`stripHlsAdsIfVod`), and disguised MPEG-TS `0x47` header stripping.
public final class LocalHeaderProxyServer: @unchecked Sendable {
    private static let maxRedirects = 8

    private struct StreamSession: Sendable {
        let id: String
        let rootUrl: URL
        let policy: NetdiskHeaderPolicy
        let isLive: Bool
        let stripHlsAds: Bool
        let adHosts: [String]
        let createdAt: Date
    }

    private struct ActiveRequestHandle {
        let cancel: @Sendable () -> Void
    }

    private let queue = DispatchQueue(label: "com.pilipala.marcoMovie.ios.header-proxy")
    private let lock = NSLock()
    private var sessions: [String: StreamSession] = [:]
    private var activeRequestsBySession: [String: [UUID: ActiveRequestHandle]] = [:]
    private var cancelledRequestsTotal: Int = 0
    private var listener: NWListener?
    private(set) public var port: UInt16 = 0
    private let redirectDelegate: LocalHeaderNoRedirectDelegate
    private let urlSession: URLSession?
    private let upstreamFetcher: ProxyUpstreamFetcher

    public init(upstreamFetcher: ProxyUpstreamFetcher? = nil) {
        let delegate = LocalHeaderNoRedirectDelegate()
        self.redirectDelegate = delegate
        if let custom = upstreamFetcher {
            self.urlSession = nil
            self.upstreamFetcher = custom
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 20
            config.timeoutIntervalForResource = 60
            config.httpShouldSetCookies = false
            config.httpCookieAcceptPolicy = .never
            let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
            self.urlSession = session
            self.upstreamFetcher = { url, method, headers in
                try Task.checkCancellation()
                var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
                request.httpMethod = method
                request.httpShouldHandleCookies = false
                for (k, v) in headers {
                    request.setValue(v, forHTTPHeaderField: k)
                }
                let state = CancellableDataTaskState()
                return try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { continuation in
                        let dataTask = session.dataTask(with: request) { data, resp, error in
                            if let error = error {
                                let nsErr = error as NSError
                                if nsErr.domain == NSURLErrorDomain && nsErr.code == NSURLErrorCancelled {
                                    continuation.resume(throwing: CancellationError())
                                } else {
                                    continuation.resume(throwing: error)
                                }
                                return
                            }
                            let httpResp = resp as? HTTPURLResponse
                            var respHeaders: [String: String] = [:]
                            if let all = httpResp?.allHeaderFields {
                                for (rk, rv) in all {
                                    respHeaders[String(describing: rk)] = String(describing: rv)
                                }
                            }
                            continuation.resume(
                                returning: ProxyUpstreamResponse(
                                    statusCode: httpResp?.statusCode ?? 200,
                                    headers: respHeaders,
                                    body: data ?? Data()
                                )
                            )
                        }
                        state.attach(dataTask)
                    }
                } onCancel: {
                    state.cancel()
                }
            }
        }
    }

    deinit {
        stop()
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    public func startIfNeeded() async throws -> UInt16 {
        if let existingPort = withLock({ (listener != nil && port > 0) ? port : nil }) {
            return existingPort
        }

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)

        let nwListener = try NWListener(using: params)
        nwListener.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
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
                        continuation.resume(throwing: MarcoError.networkFailure("本地代理端口分配失败"))
                    }
                case .failed(let err):
                    guard once.tryClaim() else { return }
                    continuation.resume(throwing: MarcoError.networkFailure("本地代理启动失败：\(err)"))
                case .cancelled:
                    guard once.tryClaim() else { return }
                    continuation.resume(throwing: MarcoError.networkFailure("本地代理已取消"))
                default:
                    break
                }
            }
            nwListener.start(queue: self.queue)
        }

        withLock {
            self.listener = nwListener
            self.port = boundPort
        }
        return boundPort
    }

    public func stop() {
        let (current, allHandles) = withLock { () -> (NWListener?, [ActiveRequestHandle]) in
            let existing = listener
            listener = nil
            port = 0
            sessions.removeAll()
            let handles = activeRequestsBySession.values.flatMap(\.values)
            activeRequestsBySession.removeAll()
            return (existing, handles)
        }
        current?.cancel()
        for h in allHandles { h.cancel() }
        urlSession?.invalidateAndCancel()
    }

    public func revokeSession(_ sessionId: String) {
        let handles = withLock { () -> [ActiveRequestHandle] in
            _ = sessions.removeValue(forKey: sessionId)
            let removed = activeRequestsBySession.removeValue(forKey: sessionId)
            if let removed = removed, !removed.isEmpty {
                cancelledRequestsTotal += removed.count
                return Array(removed.values)
            }
            return []
        }
        for h in handles { h.cancel() }
    }

    public func activeSessionCount() -> Int {
        withLock { sessions.count }
    }

    public func hasActiveSession(_ sessionId: String) -> Bool {
        withLock { sessions[sessionId] != nil }
    }

    public func activeRequestCount(for sessionId: String? = nil) -> Int {
        withLock {
            if let sid = sessionId {
                return activeRequestsBySession[sid]?.count ?? 0
            }
            return activeRequestsBySession.values.reduce(0) { $0 + $1.count }
        }
    }

    public func cancelledRequestCount() -> Int {
        withLock { cancelledRequestsTotal }
    }

    public func registerStreamWithId(
        url: URL,
        policy: NetdiskHeaderPolicy,
        isLive: Bool = false,
        stripHlsAds: Bool = true,
        adHosts: [String] = []
    ) async throws -> (sessionId: String, proxyUrl: URL) {
        let activePort = try await startIfNeeded()
        var tokenBytes = [UInt8](repeating: 0, count: 12)
        for i in 0..<tokenBytes.count {
            tokenBytes[i] = UInt8.random(in: 0...255)
        }
        let sessionId = tokenBytes.map { String(format: "%02x", $0) }.joined()
        let session = StreamSession(
            id: sessionId,
            rootUrl: url,
            policy: policy,
            isLive: isLive,
            stripHlsAds: stripHlsAds,
            adHosts: adHosts,
            createdAt: Date()
        )

        let evictedHandles = withLock { () -> [ActiveRequestHandle] in
            var evicted: [ActiveRequestHandle] = []
            if sessions.count >= 64,
               let oldest = sessions.min(by: { $0.value.createdAt < $1.value.createdAt })?.key
            {
                sessions.removeValue(forKey: oldest)
                if let removed = activeRequestsBySession.removeValue(forKey: oldest) {
                    evicted = Array(removed.values)
                }
            }
            sessions[sessionId] = session
            return evicted
        }
        for h in evictedHandles { h.cancel() }

        let ext = url.pathExtension.lowercased()
        let leaf = (ext == "mp4" || ext == "mkv" || ext == "mov" || ext == "ts") ? "stream.\(ext)" : "master.m3u8"
        guard let proxyUrl = URL(string: "http://127.0.0.1:\(activePort)/proxy/\(sessionId)/\(leaf)") else {
            throw MarcoError.networkFailure("无法构造本地代理播放地址")
        }
        return (sessionId, proxyUrl)
    }

    public func registerStreamWithId(
        url: URL,
        headers: [String: String],
        isLive: Bool = false,
        stripHlsAds: Bool = true,
        adHosts: [String] = []
    ) async throws -> (sessionId: String, proxyUrl: URL) {
        let host = (url.host ?? "").lowercased()
        let isLoopback = (host == "127.0.0.1" || host == "localhost" || host == "::1")
        let policy = NetdiskHeaderPolicy(
            originUrl: url,
            baseHeaders: headers,
            cookieDomains: [],
            allowInsecureLoopbackCredentials: isLoopback,
            defaultUserAgent: CmsClient.defaultSafariUserAgent
        )
        return try await registerStreamWithId(
            url: url,
            policy: policy,
            isLive: isLive,
            stripHlsAds: stripHlsAds,
            adHosts: adHosts
        )
    }

    public func registerStream(url: URL, policy: NetdiskHeaderPolicy) async throws -> URL {
        try await registerStreamWithId(url: url, policy: policy).proxyUrl
    }

    public func registerStream(url: URL, headers: [String: String]) async throws -> URL {
        try await registerStreamWithId(url: url, headers: headers).proxyUrl
    }

    // MARK: - Disguised MPEG-TS Header Stripping (`0x47` Sync Lock)

    /// Detects a fake image/padding prefix (e.g. PNG/JPG/GIF/BMP) prepended before an unencrypted
    /// 188-byte MPEG-TS packet stream and returns its byte offset. Returns `0` for standard media.
    public static func findDisguisedTsOffset(_ prefix: Data) -> Int {
        let bytes = [UInt8](prefix.prefix(3500))
        guard bytes.count >= 189, bytes[0] != 0x47 else { return 0 }

        // Never strip ID3, FLV, EBML (MKV/WebM), MP4/fMP4 boxes, #EXTM3U, WEBVTT
        if bytes.count >= 3 && bytes[0] == 0x49 && bytes[1] == 0x44 && bytes[2] == 0x33 { return 0 }
        if bytes.count >= 4 {
            if bytes[0] == 0x46 && bytes[1] == 0x4C && bytes[2] == 0x56 { return 0 }
            if bytes[0] == 0x1A && bytes[1] == 0x45 && bytes[2] == 0xDF && bytes[3] == 0xA3 { return 0 }
        }
        if bytes.count >= 8 {
            let box = String(bytes: bytes[4..<8], encoding: .isoLatin1) ?? ""
            if ["ftyp", "styp", "moof", "moov", "mdat", "sidx", "free", "wide"].contains(box) {
                return 0
            }
        }
        if bytes.count >= 7 {
            var s = 0
            if bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF { s = 3 }
            while s < bytes.count && (bytes[s] == 0x20 || bytes[s] == 0x09 || bytes[s] == 0x0D || bytes[s] == 0x0A) {
                s += 1
            }
            if s + 7 <= bytes.count, String(bytes: bytes[s..<(s + 7)], encoding: .isoLatin1) == "#EXTM3U" { return 0 }
            if s + 6 <= bytes.count, String(bytes: bytes[s..<(s + 6)], encoding: .isoLatin1) == "WEBVTT" { return 0 }
        }

        let maxOffset = min(bytes.count - 189, 3072)
        guard maxOffset >= 1 else { return 0 }
        for i in 1...maxOffset {
            if bytes[i] != 0x47 { continue }
            if bytes.count >= i + 377 {
                if bytes[i + 188] == 0x47 && bytes[i + 376] == 0x47 { return i }
            } else if bytes[i + 188] == 0x47 {
                return i
            }
        }
        return 0
    }

    // MARK: - Heuristic HLS VOD Discontinuity Ad Stripping

    private struct HlsSegmentEntry {
        let duration: Double
        let tagLines: [String]
        let uriLine: String
        let resolvedUrl: URL
        let keyTag: String?
    }

    private struct HlsBlock {
        let hasPrecedingDiscontinuity: Bool
        var segments: [HlsSegmentEntry] = []
    }

    public static func stripHlsAdsIfVod(
        _ text: String,
        origin: URL,
        enabled: Bool = true,
        isLive: Bool = false,
        adHosts: [String] = []
    ) -> (playlist: String, removedSegments: Int, removedDuration: Double) {
        guard enabled, !isLive else { return (text, 0, 0.0) }
        let normalizedLines = text.components(separatedBy: "\n").map { raw in
            raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
        }

        var isMaster = false
        var isVod = false
        var hasDiscontinuity = false
        for raw in normalizedLines {
            let upper = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            if upper.hasPrefix("#EXT-X-STREAM-INF") {
                isMaster = true
                break
            }
            if upper == "#EXT-X-ENDLIST" || upper.hasPrefix("#EXT-X-PLAYLIST-TYPE:VOD") {
                isVod = true
            } else if upper == "#EXT-X-DISCONTINUITY" {
                hasDiscontinuity = true
            }
        }
        guard !isMaster, isVod, hasDiscontinuity else { return (text, 0, 0.0) }

        var headerLines: [String] = []
        var footerLines: [String] = []
        var blocks: [HlsBlock] = []
        var currentBlock = HlsBlock(hasPrecedingDiscontinuity: false)
        var seenFirst = false
        var pendingSegTags: [String] = []
        var pendingDuration: Double?
        var currentKeyTag: String?
        var inFooter = false

        for line in normalizedLines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let upper = trimmed.uppercased()
            if upper == "#EXT-X-ENDLIST" {
                inFooter = true
                footerLines.append(line)
                continue
            }
            if inFooter {
                footerLines.append(line)
                continue
            }
            if trimmed.isEmpty {
                if !seenFirst && pendingSegTags.isEmpty { headerLines.append(line) }
                continue
            }
            if upper == "#EXT-X-DISCONTINUITY" {
                if seenFirst {
                    blocks.append(currentBlock)
                    currentBlock = HlsBlock(hasPrecedingDiscontinuity: true)
                } else {
                    seenFirst = true
                }
                pendingSegTags.removeAll()
                pendingDuration = nil
                continue
            }
            if trimmed.hasPrefix("#") {
                if upper.hasPrefix("#EXTINF:") {
                    seenFirst = true
                    let afterColon = String(trimmed.dropFirst(8))
                    let numText = (afterColon.components(separatedBy: ",").first ?? afterColon)
                        .trimmingCharacters(in: .whitespaces)
                    pendingDuration = Double(numText) ?? 0.0
                    pendingSegTags.append(line)
                } else if upper.hasPrefix("#EXT-X-KEY:") {
                    currentKeyTag = line
                    if !seenFirst { headerLines.append(line) }
                    else { pendingSegTags.append(line) }
                } else if upper.hasPrefix("#EXT-X-MAP:")
                    || upper.hasPrefix("#EXT-X-BYTERANGE:")
                    || upper.hasPrefix("#EXT-X-PROGRAM-DATE-TIME:")
                {
                    seenFirst = true
                    pendingSegTags.append(line)
                } else if !seenFirst {
                    headerLines.append(line)
                } else {
                    pendingSegTags.append(line)
                }
                continue
            }

            seenFirst = true
            let resolvedUrl = URL(string: CmsParser.resolveUrl(base: origin.absoluteString, relative: trimmed)) ?? origin
            currentBlock.segments.append(
                HlsSegmentEntry(
                    duration: pendingDuration ?? 0.0,
                    tagLines: pendingSegTags,
                    uriLine: line,
                    resolvedUrl: resolvedUrl,
                    keyTag: currentKeyTag
                )
            )
            pendingSegTags.removeAll()
            pendingDuration = nil
        }
        if !currentBlock.segments.isEmpty { blocks.append(currentBlock) }
        guard blocks.count >= 2 else { return (text, 0, 0.0) }

        var totalDuration = 0.0
        var totalSegments = 0
        var hostDurations: [String: Double] = [:]
        for block in blocks {
            for seg in block.segments {
                totalSegments += 1
                let d = max(0.0, seg.duration)
                totalDuration += d
                let h = (seg.resolvedUrl.host ?? "").lowercased()
                hostDurations[h, default: 0.0] += d
            }
        }
        guard totalSegments > 0, totalDuration > 0.0 else { return (text, 0, 0.0) }

        var primaryHost = (origin.host ?? "").lowercased()
        var maxHostDur = -1.0
        for (h, d) in hostDurations where d > maxHostDur {
            maxHostDur = d
            primaryHost = h
        }

        var removeBlock = [Bool](repeating: false, count: blocks.count)
        var removedSegments = 0
        var removedDuration = 0.0
        let adPathTokens = ["/ad/", "/ads/", "/advert/", "/promo/", "/guanggao/", "ad_", "_ad.", "adjump"]

        for i in 0..<blocks.count {
            let block = blocks[i]
            guard !block.segments.isEmpty, block.segments.count <= 20 else { continue }
            let blockDur = block.segments.reduce(0.0) { $0 + max(0.0, $1.duration) }
            guard blockDur / totalDuration <= 0.40 else { continue }
            guard block.segments.allSatisfy({ $0.duration > 0 && $0.duration <= 60.0 }) else { continue }

            let hitsAd = block.segments.contains { seg in
                let h = (seg.resolvedUrl.host ?? "").lowercased()
                let path = seg.resolvedUrl.path.lowercased()
                if !adHosts.isEmpty && adHosts.contains(where: { pat in
                    let p = pat.lowercased()
                    return h == p || h.hasSuffix(".\(p)") || path.contains(p)
                }) {
                    return true
                }
                if adPathTokens.contains(where: { path.contains($0) }) { return true }
                if !primaryHost.isEmpty && !h.isEmpty && h != primaryHost && blockDur <= 45.0 {
                    return true
                }
                return false
            }
            if hitsAd {
                removeBlock[i] = true
                removedSegments += block.segments.count
                removedDuration += blockDur
            }
        }

        if removedSegments == 0 || removedSegments >= totalSegments || (removedDuration / totalDuration) > 0.40 {
            return (text, 0, 0.0)
        }

        var out = headerLines
        var emittedAnyBlock = false
        var prevWasRemoved = false
        var lastEmittedKeyTag: String? = headerLines.last(where: {
            $0.trimmingCharacters(in: .whitespaces).uppercased().hasPrefix("#EXT-X-KEY:")
        })

        for i in 0..<blocks.count {
            if removeBlock[i] {
                prevWasRemoved = true
                continue
            }
            let block = blocks[i]
            let wasPrecededByRemovedAd = prevWasRemoved
            if emittedAnyBlock && block.hasPrecedingDiscontinuity && !wasPrecededByRemovedAd {
                out.append("#EXT-X-DISCONTINUITY")
            }
            prevWasRemoved = false
            emittedAnyBlock = true
            for (sIdx, seg) in block.segments.enumerated() {
                let blockHasOwnKey = seg.tagLines.contains {
                    $0.trimmingCharacters(in: .whitespaces).uppercased().hasPrefix("#EXT-X-KEY:")
                }
                if sIdx == 0 && !blockHasOwnKey && wasPrecededByRemovedAd,
                   let kTag = seg.keyTag, kTag != lastEmittedKeyTag
                {
                    out.append(kTag)
                    lastEmittedKeyTag = kTag
                }
                for t in seg.tagLines {
                    out.append(t)
                    if t.trimmingCharacters(in: .whitespaces).uppercased().hasPrefix("#EXT-X-KEY:") {
                        lastEmittedKeyTag = t
                    }
                }
                out.append(seg.uriLine)
            }
        }
        out.append(contentsOf: footerLines)
        return (out.joined(separator: "\n"), removedSegments, removedDuration)
    }

    /// Rewrites an HLS `.m3u8` manifest so all variant playlists, media segments, and `#EXT-X-KEY` / `#EXT-X-MAP` URIs route through loopback.
    public static func rewriteM3u8Playlist(
        _ manifest: String,
        baseUrl: URL,
        proxyPort: UInt16,
        sessionId: String
    ) -> String {
        let baseStr = baseUrl.absoluteString
        func makeProxyUrl(_ rawRef: String) -> String {
            let trimmed = rawRef.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return rawRef }
            let resolved = CmsParser.resolveUrl(base: baseStr, relative: trimmed)
            let b64 = Data(resolved.utf8)
                .base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
            let pathLower = (URL(string: resolved)?.path ?? "").lowercased()
            let suffix = pathLower.hasSuffix(".m3u8") ? "sub.m3u8" : "seg"
            return "http://127.0.0.1:\(proxyPort)/proxy/\(sessionId)/\(suffix)?u=\(b64)"
        }

        let uriAttrRegex = try? NSRegularExpression(pattern: #"URI="([^"]+)""#, options: [.caseInsensitive])
        let lines = manifest.components(separatedBy: .newlines)
        var rewritten: [String] = []
        rewritten.reserveCapacity(lines.count)

        for rawLine in lines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                rewritten.append("")
                continue
            }
            if trimmed.hasPrefix("#") {
                if let regex = uriAttrRegex, trimmed.uppercased().contains("URI=\"") {
                    let ns = trimmed as NSString
                    let matches = regex.matches(in: trimmed, range: NSRange(location: 0, length: ns.length))
                    if !matches.isEmpty {
                        let mutable = NSMutableString(string: trimmed)
                        for m in matches.reversed() {
                            let innerUri = ns.substring(with: m.range(at: 1))
                            let proxied = makeProxyUrl(innerUri)
                            mutable.replaceCharacters(in: m.range, with: "URI=\"\(proxied)\"")
                        }
                        rewritten.append(mutable as String)
                        continue
                    }
                }
                rewritten.append(trimmed)
                continue
            }
            rewritten.append(makeProxyUrl(trimmed))
        }
        return rewritten.joined(separator: "\n")
    }

    // MARK: - Loopback Connection Handling

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveHttpRequest(connection: connection, accumulated: Data())
    }

    private func receiveHttpRequest(connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 32_768) { [weak self] data, _, isComplete, error in
            guard let self = self else {
                connection.cancel()
                return
            }
            if error != nil {
                connection.cancel()
                return
            }
            var buffer = accumulated
            if let chunk = data, !chunk.isEmpty { buffer.append(chunk) }
            if buffer.count > 65_536 {
                self.sendError(connection: connection, status: 413, message: "Request header too large")
                return
            }
            if let headerEnd = buffer.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A])) {
                let headerData = buffer.subdata(in: 0..<headerEnd.lowerBound)
                self.processRequestHeader(headerData, connection: connection)
            } else if isComplete {
                connection.cancel()
            } else {
                self.receiveHttpRequest(connection: connection, accumulated: buffer)
            }
        }
    }

    private func processRequestHeader(_ headerData: Data, connection: NWConnection) {
        let headerText = String(decoding: headerData, as: UTF8.self)
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            sendError(connection: connection, status: 400, message: "Bad Request")
            return
        }
        let parts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else {
            sendError(connection: connection, status: 400, message: "Bad Request")
            return
        }
        let method = parts[0].uppercased()
        guard method == "GET" || method == "HEAD" else {
            sendError(connection: connection, status: 405, message: "Method Not Allowed")
            return
        }
        let rawTarget = parts[1]

        var clientHeaders: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
            let val = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            clientHeaders[key] = val
        }

        guard let comps = URLComponents(string: "http://127.0.0.1\(rawTarget.hasPrefix("/") ? "" : "/")\(rawTarget)") else {
            sendError(connection: connection, status: 400, message: "Invalid Target")
            return
        }
        let segments = comps.path.split(separator: "/").map(String.init)
        guard segments.count >= 2, segments[0] == "proxy" else {
            sendError(connection: connection, status: 404, message: "Not Found")
            return
        }
        let sessionId = segments[1]

        lock.lock()
        let session = sessions[sessionId]
        let activePort = port
        lock.unlock()

        guard let streamSession = session else {
            sendError(connection: connection, status: 404, message: "Expired stream session")
            return
        }

        let targetUrl: URL
        if let encodedU = comps.queryItems?.first(where: { $0.name == "u" })?.value, !encodedU.isEmpty {
            var b64 = encodedU
                .replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/")
            while b64.count % 4 != 0 { b64.append("=") }
            guard let decodedData = Data(base64Encoded: b64),
                  let decodedStr = String(data: decodedData, encoding: .utf8),
                  let resolvedUrl = URL(string: decodedStr),
                  let scheme = resolvedUrl.scheme?.lowercased(),
                  (scheme == "http" || scheme == "https")
            else {
                sendError(connection: connection, status: 400, message: "Invalid sub-resource URL")
                return
            }
            targetUrl = resolvedUrl
        } else {
            targetUrl = streamSession.rootUrl
        }

        let requestedRange = clientHeaders["range"]
        let fetcher = self.upstreamFetcher
        let requestId = UUID()

        let requestTask = Task { [weak self] in
            guard let self = self else {
                connection.cancel()
                return
            }
            defer {
                self.unregisterActiveRequest(sessionId: sessionId, requestId: requestId)
            }
            do {
                var currentUrl = targetUrl
                var currentMethod = method
                var resolvedUpstream: ProxyUpstreamResponse?

                for _ in 0...Self.maxRedirects {
                    try Task.checkCancellation()
                    guard self.hasActiveSession(sessionId) else { throw CancellationError() }
                    guard let scheme = currentUrl.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
                        self.sendError(connection: connection, status: 502, message: "Unsupported redirect scheme")
                        return
                    }
                    let hopHeaders = streamSession.policy.headers(for: currentUrl, range: requestedRange)
                    let hopResponse = try await fetcher(currentUrl, currentMethod, hopHeaders)
                    try Task.checkCancellation()
                    guard self.hasActiveSession(sessionId) else { throw CancellationError() }
                    if [301, 302, 303, 307, 308].contains(hopResponse.statusCode),
                       let rawLoc = hopResponse.headers.first(where: { $0.key.lowercased() == "location" })?.value
                           .trimmingCharacters(in: .whitespacesAndNewlines),
                       !rawLoc.isEmpty,
                       let nextUrl = URL(string: rawLoc, relativeTo: currentUrl)?.absoluteURL
                    {
                        if hopResponse.statusCode == 303 && currentMethod != "HEAD" {
                            currentMethod = "GET"
                        }
                        currentUrl = nextUrl
                        continue
                    }
                    resolvedUpstream = hopResponse
                    break
                }

                try Task.checkCancellation()
                guard self.hasActiveSession(sessionId) else { throw CancellationError() }
                guard let upstream = resolvedUpstream else {
                    self.sendError(connection: connection, status: 502, message: "Too many upstream redirects")
                    return
                }

                let contentType = upstream.headers.first(where: { $0.key.lowercased() == "content-type" })?.value ?? ""
                let bodyPrefix = String(decoding: upstream.body.prefix(32), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let isHls = currentUrl.path.lowercased().hasSuffix(".m3u8")
                    || contentType.lowercased().contains("mpegurl")
                    || bodyPrefix.hasPrefix("#EXTM3U")

                if isHls && upstream.statusCode >= 200 && upstream.statusCode < 300 {
                    let manifestText = String(decoding: upstream.body, as: UTF8.self)
                    let cleanedManifest: String
                    if streamSession.stripHlsAds && !streamSession.isLive {
                        cleanedManifest = Self.stripHlsAdsIfVod(
                            manifestText,
                            origin: currentUrl,
                            enabled: true,
                            isLive: false,
                            adHosts: streamSession.adHosts
                        ).playlist
                    } else {
                        cleanedManifest = manifestText
                    }
                    let rewritten = Self.rewriteM3u8Playlist(
                        cleanedManifest,
                        baseUrl: currentUrl,
                        proxyPort: activePort,
                        sessionId: sessionId
                    )
                    let payload = Data(rewritten.utf8)
                    self.sendResponse(
                        connection: connection,
                        status: 200,
                        headers: [
                            "Content-Type": "application/vnd.apple.mpegurl; charset=utf-8",
                            "Cache-Control": "no-store",
                            "Content-Length": "\(payload.count)",
                        ],
                        body: method == "HEAD" ? Data() : payload
                    )
                } else {
                    var bodyOut = upstream.body
                    var outContentType = upstream.headers.first(where: { $0.key.lowercased() == "content-type" })?.value
                    if requestedRange == nil && upstream.statusCode == 200 {
                        let tsOffset = Self.findDisguisedTsOffset(bodyOut)
                        if tsOffset > 0 && tsOffset < bodyOut.count {
                            bodyOut = bodyOut.subdata(in: tsOffset..<bodyOut.count)
                            outContentType = "video/mp2t"
                        }
                    }
                    var respHeaders: [String: String] = [
                        "Cache-Control": "no-store",
                        "Content-Length": "\(bodyOut.count)",
                    ]
                    for forwarded in ["content-range", "accept-ranges"] {
                        if let match = upstream.headers.first(where: { $0.key.lowercased() == forwarded }) {
                            respHeaders[match.key] = match.value
                        }
                    }
                    respHeaders["Content-Type"] = outContentType ?? "application/octet-stream"
                    self.sendResponse(
                        connection: connection,
                        status: upstream.statusCode,
                        headers: respHeaders,
                        body: method == "HEAD" ? Data() : bodyOut
                    )
                }
            } catch is CancellationError {
                connection.cancel()
            } catch {
                if Task.isCancelled || !self.hasActiveSession(sessionId) {
                    connection.cancel()
                } else {
                    self.sendError(connection: connection, status: 502, message: "Upstream fetch failed")
                }
            }
        }

        let registered = registerActiveRequest(sessionId: sessionId, requestId: requestId) {
            requestTask.cancel()
            connection.cancel()
        }
        if !registered {
            requestTask.cancel()
            connection.cancel()
            return
        }

        connection.stateUpdateHandler = { state in
            switch state {
            case .failed, .cancelled:
                requestTask.cancel()
            default:
                break
            }
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { _, _, isComplete, error in
            if isComplete || error != nil {
                requestTask.cancel()
            }
        }
    }

    private func registerActiveRequest(
        sessionId: String,
        requestId: UUID,
        onCancel: @escaping @Sendable () -> Void
    ) -> Bool {
        withLock {
            guard sessions[sessionId] != nil else { return false }
            var map = activeRequestsBySession[sessionId] ?? [:]
            map[requestId] = ActiveRequestHandle(cancel: onCancel)
            activeRequestsBySession[sessionId] = map
            return true
        }
    }

    private func unregisterActiveRequest(sessionId: String, requestId: UUID) {
        withLock {
            guard var map = activeRequestsBySession[sessionId] else { return }
            map.removeValue(forKey: requestId)
            if map.isEmpty {
                activeRequestsBySession.removeValue(forKey: sessionId)
            } else {
                activeRequestsBySession[sessionId] = map
            }
        }
    }

    private func sendError(connection: NWConnection, status: Int, message: String) {
        let body = Data(message.utf8)
        sendResponse(
            connection: connection,
            status: status,
            headers: [
                "Content-Type": "text/plain; charset=utf-8",
                "Content-Length": "\(body.count)",
            ],
            body: body
        )
    }

    private func sendResponse(
        connection: NWConnection,
        status: Int,
        headers: [String: String],
        body: Data
    ) {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 206: reason = "Partial Content"
        case 400: reason = "Bad Request"
        case 404: reason = "Not Found"
        case 405: reason = "Method Not Allowed"
        case 413: reason = "Payload Too Large"
        case 502: reason = "Bad Gateway"
        default: reason = "Response"
        }
        var headerLines = ["HTTP/1.1 \(status) \(reason)", "Connection: close"]
        for (k, v) in headers {
            headerLines.append("\(k): \(v)")
        }
        let headerBlock = headerLines.joined(separator: "\r\n") + "\r\n\r\n"
        var packet = Data(headerBlock.utf8)
        packet.append(body)
        connection.send(content: packet, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

/// Pure-offline loopback HTTP server serving downloaded local `.m3u8` packages strictly
/// within their canonical parent directory (path-traversal protected, zero network egress).
public final class OfflineHlsLease: @unchecked Sendable {
    public let url: URL
    private let queue = DispatchQueue(label: "com.pilipala.marcoMovie.ios.offline-hls")
    private let listener: NWListener
    private let capability: String
    private let masterFile: URL
    private let rootDirPath: String
    private let lock = NSLock()
    private var closed = false

    private init(
        listener: NWListener,
        port: UInt16,
        capability: String,
        masterFile: URL,
        rootDirPath: String
    ) {
        self.listener = listener
        self.capability = capability
        self.masterFile = masterFile
        self.rootDirPath = rootDirPath
        self.url = URL(string: "http://127.0.0.1:\(port)/offline/\(capability)/master.m3u8")!
    }

    deinit {
        close()
    }

    public static func isLocalM3u8(_ rawPath: String) -> Bool {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("rtmp://") || lower.hasPrefix("rtsp://") {
            return false
        }
        let path: String
        if lower.hasPrefix("file://"), let u = URL(string: trimmed) {
            path = u.path
        } else {
            path = trimmed
        }
        return path.lowercased().hasSuffix(".m3u8") && FileManager.default.fileExists(atPath: path)
    }

    public static func open(path rawPath: String) async throws -> OfflineHlsLease {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let fileUrl = trimmed.lowercased().hasPrefix("file://")
            ? (URL(string: trimmed) ?? URL(fileURLWithPath: trimmed))
            : URL(fileURLWithPath: trimmed)
        let canonicalMaster = fileUrl.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: canonicalMaster.path) else {
            throw MarcoError.storageError("离线 HLS 清单不存在：\(canonicalMaster.path)")
        }
        let canonicalRoot = canonicalMaster.deletingLastPathComponent().resolvingSymlinksInPath().path

        var capBytes = [UInt8](repeating: 0, count: 16)
        for i in 0..<capBytes.count { capBytes[i] = UInt8.random(in: 0...255) }
        let capability = capBytes.map { String(format: "%02x", $0) }.joined()

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        let nwListener = try NWListener(using: params)
        let queue = DispatchQueue(label: "com.pilipala.marcoMovie.ios.offline-hls.start")

        let boundPort: UInt16 = try await withCheckedThrowingContinuation { cont in
            let once = MarcoOnceFlag()
            nwListener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard once.tryClaim() else { return }
                    if let p = nwListener.port?.rawValue, p > 0 {
                        cont.resume(returning: p)
                    } else {
                        cont.resume(throwing: MarcoError.networkFailure("离线 HLS 端口分配失败"))
                    }
                case .failed(let err):
                    guard once.tryClaim() else { return }
                    cont.resume(throwing: MarcoError.networkFailure("离线 HLS 服务启动失败：\(err)"))
                case .cancelled:
                    guard once.tryClaim() else { return }
                    cont.resume(throwing: MarcoError.networkFailure("离线 HLS 服务已关闭"))
                default:
                    break
                }
            }
            nwListener.start(queue: queue)
        }

        let lease = OfflineHlsLease(
            listener: nwListener,
            port: boundPort,
            capability: capability,
            masterFile: canonicalMaster,
            rootDirPath: canonicalRoot
        )
        nwListener.newConnectionHandler = { [weak lease] conn in
            lease?.handle(conn)
        }
        return lease
    }

    public func close() {
        lock.lock()
        let already = closed
        closed = true
        lock.unlock()
        if !already {
            listener.cancel()
        }
    }

    private func resolveTargetFile(requestPath: String) -> URL? {
        let prefix = "/offline/\(capability)/"
        guard requestPath.hasPrefix(prefix) else { return nil }
        let rel = String(requestPath.dropFirst(prefix.count))
        guard !rel.isEmpty, !rel.contains("\0"), !rel.contains("\\") else { return nil }
        if rel == "master.m3u8" { return masterFile }
        let segs = rel.split(separator: "/").map(String.init)
        for s in segs where s.isEmpty || s == "." || s == ".." {
            return nil
        }
        let candidate = URL(fileURLWithPath: rootDirPath).appendingPathComponent(segs.joined(separator: "/"))
        guard FileManager.default.fileExists(atPath: candidate.path) else { return nil }
        let resolved = candidate.resolvingSymlinksInPath()
        let rootPrefix = rootDirPath.hasSuffix("/") ? rootDirPath : "\(rootDirPath)/"
        guard resolved.path.hasPrefix(rootPrefix) else { return nil }
        return resolved
    }

    private func contentTypeFor(_ path: String) -> String {
        let lower = path.lowercased()
        if lower.hasSuffix(".m3u8") { return "application/vnd.apple.mpegurl; charset=utf-8" }
        if lower.hasSuffix(".ts") { return "video/mp2t" }
        if lower.hasSuffix(".m4s") || lower.hasSuffix(".mp4") { return "video/mp4" }
        if lower.hasSuffix(".m4a") { return "audio/mp4" }
        if lower.hasSuffix(".aac") { return "audio/aac" }
        return "application/octet-stream"
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, err in
            guard let self = self, err == nil, let data = data, !data.isEmpty else {
                conn.cancel()
                return
            }
            let text = String(decoding: data, as: UTF8.self)
            let lines = text.components(separatedBy: "\r\n")
            guard let reqLine = lines.first else {
                conn.cancel()
                return
            }
            let parts = reqLine.split(separator: " ", maxSplits: 2).map(String.init)
            guard parts.count >= 2 else {
                conn.cancel()
                return
            }
            let method = parts[0].uppercased()
            let rawPath = parts[1].components(separatedBy: "?").first ?? parts[1]
            guard method == "GET" || method == "HEAD",
                  let target = self.resolveTargetFile(requestPath: rawPath),
                  let fileData = try? Data(contentsOf: target)
            else {
                let nf = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                conn.send(content: Data(nf.utf8), completion: .contentProcessed { _ in conn.cancel() })
                return
            }
            let hdr = [
                "HTTP/1.1 200 OK",
                "Content-Type: \(self.contentTypeFor(target.path))",
                "Accept-Ranges: bytes",
                "Cache-Control: no-store",
                "Content-Length: \(fileData.count)",
                "Connection: close",
                "",
                "",
            ].joined(separator: "\r\n")
            var pkt = Data(hdr.utf8)
            if method == "GET" { pkt.append(fileData) }
            conn.send(content: pkt, completion: .contentProcessed { _ in conn.cancel() })
        }
    }
}
