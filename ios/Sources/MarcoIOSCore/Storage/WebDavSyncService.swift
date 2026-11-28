// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only

import CryptoKit
import Foundation

public struct WebDavHttpResponse: Sendable {
    public var statusCode: Int
    public var headers: [String: String]
    public var body: Data

    public init(statusCode: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }

    public func header(_ name: String) -> String? {
        let lower = name.lowercased()
        return headers.first { $0.key.lowercased() == lower }?.value
    }
}

public protocol WebDavTransportProtocol: Sendable {
    func send(method: String, url: URL, headers: [String: String], body: Data?) async throws -> WebDavHttpResponse
}

public final class URLSessionWebDavTransport: WebDavTransportProtocol {
    private let session: URLSession

    public init(timeoutSeconds: TimeInterval = 15) {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeoutSeconds
        cfg.timeoutIntervalForResource = timeoutSeconds * 2
        cfg.httpShouldSetCookies = false
        self.session = URLSession(configuration: cfg)
    }

    public func send(method: String, url: URL, headers: [String: String], body: Data?) async throws -> WebDavHttpResponse {
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        req.httpMethod = method
        for (k, v) in headers {
            req.setValue(v, forHTTPHeaderField: k)
        }
        req.httpBody = body
        let (data, resp) = try await session.marcoData(for: req)
        let http = resp as? HTTPURLResponse
        var outHeaders: [String: String] = [:]
        if let all = http?.allHeaderFields {
            for (rk, rv) in all {
                outHeaders[String(describing: rk)] = String(describing: rv)
            }
        }
        return WebDavHttpResponse(statusCode: http?.statusCode ?? 200, headers: outHeaders, body: data)
    }
}

public struct SyncMergeSummary: Equatable, Sendable {
    public var historyCount: Int
    public var favoriteCount: Int
    public var subscriptionCount: Int
    public var changed: Bool
    public var subscriptionsChanged: Bool
    public var payloadJson: String
    public var hasPendingLocalChanges: Bool
    public var danmuSourceCount: Int?
    public var danmuError: String?

    public init(
        historyCount: Int,
        favoriteCount: Int,
        subscriptionCount: Int,
        changed: Bool,
        subscriptionsChanged: Bool,
        payloadJson: String,
        hasPendingLocalChanges: Bool = false,
        danmuSourceCount: Int? = nil,
        danmuError: String? = nil
    ) {
        self.historyCount = historyCount
        self.favoriteCount = favoriteCount
        self.subscriptionCount = subscriptionCount
        self.changed = changed
        self.subscriptionsChanged = subscriptionsChanged
        self.payloadJson = payloadJson
        self.hasPendingLocalChanges = hasPendingLocalChanges
        self.danmuSourceCount = danmuSourceCount
        self.danmuError = danmuError
    }
}

/// WebDAV Cloud Sync v2 engine compatible with Android, iOS, macOS, tvOS, and Windows:
/// - Exact `resolveWebdavFileUrl` normalization (including `jianguoyun.com` -> `/dav/MarcoMovie/marco-movie-sync.json`)
/// - Sibling `.danmu.json` sidecar 3-way merge (`syncDanmuSources`)
/// - Recursive `MKCOL` collection creation on `404` / `409`
/// - Optimistic `ETag` (`If-Match` / `If-None-Match: *`) concurrency with `412` retry and safe fail-closed first creation
/// - Cross-device subscription ID remapping, private record isolation & remote scrubbing, and Emby account metadata sync
public final class WebDavSyncService: @unchecked Sendable {
    public static let syncSchema = "marco-movie-sync"
    public static let syncVersion = 2
    public static let defaultSyncFileName = "marco-movie-sync.json"
    public static let maxSyncPayloadBytes = 8 * 1024 * 1024

    private let storage: IOSStorageManager
    private let transport: WebDavTransportProtocol

    public init(
        storage: IOSStorageManager,
        transport: WebDavTransportProtocol = URLSessionWebDavTransport()
    ) {
        self.storage = storage
        self.transport = transport
    }

    // MARK: - Canonical URL & Identity Rules

    public static func resolveWebdavFileUrl(_ rawUrl: String) throws -> String {
        var trimmed = rawUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MarcoError.invalidFormat("请填写 WebDAV 服务器地址")
        }
        let lower = trimmed.lowercased()
        if !lower.hasPrefix("http://") && !lower.hasPrefix("https://") {
            trimmed = "https://\(trimmed)"
        }
        trimmed = trimmed.replacingOccurrences(of: " ", with: "%20")

        guard let comps = URLComponents(string: trimmed),
              let scheme = comps.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              let host = comps.host?.lowercased(),
              !host.isEmpty
        else {
            throw MarcoError.invalidFormat("仅支持 HTTP 或 HTTPS WebDAV 地址")
        }

        let path = comps.path
        if path.lowercased().hasSuffix(".json") {
            return trimmed
        }

        let isJianguoyun = host == "jianguoyun.com" || host.hasSuffix(".jianguoyun.com")
        if isJianguoyun && (path.isEmpty || path == "/") {
            return trimmed.hasSuffix("/")
                ? "\(trimmed)dav/MarcoMovie/\(defaultSyncFileName)"
                : "\(trimmed)/dav/MarcoMovie/\(defaultSyncFileName)"
        }
        if isJianguoyun && (path == "/dav" || path == "/dav/") {
            return trimmed.hasSuffix("/")
                ? "\(trimmed)MarcoMovie/\(defaultSyncFileName)"
                : "\(trimmed)/MarcoMovie/\(defaultSyncFileName)"
        }
        return trimmed.hasSuffix("/")
            ? "\(trimmed)\(defaultSyncFileName)"
            : "\(trimmed)/\(defaultSyncFileName)"
    }

    /// Derives sibling danmu sidecar URL (e.g. `marco-movie-sync.json` -> `marco-movie-sync.danmu.json`).
    public static func resolveDanmuSidecarUrl(fromMainSyncUrl mainUrlStr: String) -> URL? {
        guard var comps = URLComponents(string: mainUrlStr) else { return nil }
        let path = comps.path
        let lowerPath = path.lowercased()
        if lowerPath.hasSuffix(".danmu.json") {
            return comps.url
        } else if lowerPath.hasSuffix(".json") {
            comps.path = String(path.dropLast(5)) + ".danmu.json"
        } else {
            comps.path = path + ".danmu.json"
        }
        return comps.url
    }

    public static func canonicalSubscriptionSyncKey(
        url: String,
        rawContent: String,
        warehouseUrl: String = ""
    ) -> String {
        func isHttp(_ s: String) -> Bool {
            let l = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return l.hasPrefix("http://") || l.hasPrefix("https://")
        }
        let effectiveHttp = isHttp(warehouseUrl)
            ? warehouseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
            : (isHttp(url) ? url.trimmingCharacters(in: .whitespacesAndNewlines) : "")
        if !effectiveHttp.isEmpty {
            return SHA256.hash(data: Data("url:\(effectiveHttp)".utf8)).map { String(format: "%02x", $0) }.joined()
        }
        let sanitized = CmsParser.sanitizePublicRawConfig(rawContent)
        let normalizedLocal = sanitized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? rawContent
            : sanitized
        return SHA256.hash(data: Data("local:\(normalizedLocal)".utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public static func canonicalWireSubscriptionId(
        url: String,
        rawContent: String,
        warehouseUrl: String = ""
    ) -> String? {
        let hasIdentity = !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !warehouseUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !rawContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard hasIdentity else { return nil }
        let sk = canonicalSubscriptionSyncKey(url: url, rawContent: rawContent, warehouseUrl: warehouseUrl)
        return "sub_\(sk.prefix(12))"
    }

    public static func baseCollectionDepth(rawBaseUrl: String, fileURL: URL) -> Int {
        let allSegs = fileURL.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        guard allSegs.count > 1 else { return 0 }
        let parentSegs = Array(allSegs.dropLast())

        let baseSegs: [String] = {
            var t = rawBaseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return [] }
            if !t.lowercased().hasPrefix("http://") && !t.lowercased().hasPrefix("https://") {
                t = "https://\(t)"
            }
            t = t.replacingOccurrences(of: " ", with: "%20")
            guard let u = URL(string: t), !u.path.lowercased().hasSuffix(".json") else { return [] }
            return u.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        }()

        func isPrefix(_ prefix: [String], of full: [String]) -> Bool {
            guard prefix.count <= full.count else { return false }
            return zip(prefix, full).allSatisfy { $0.lowercased() == $1.lowercased() }
        }

        let host = (fileURL.host ?? "").lowercased()
        let isJianguoyun = host == "jianguoyun.com" || host.hasSuffix(".jianguoyun.com")
        if isJianguoyun, parentSegs.first?.lowercased() == "dav" {
            var skip = 1
            if !baseSegs.isEmpty && baseSegs.count < parentSegs.count && isPrefix(baseSegs, of: parentSegs) {
                skip = max(skip, baseSegs.count)
            }
            return skip
        }
        if parentSegs.count >= 4,
           parentSegs[0].lowercased() == "remote.php",
           parentSegs[1].lowercased() == "dav",
           parentSegs[2].lowercased() == "files"
        {
            var skip = 4
            if !baseSegs.isEmpty && baseSegs.count < parentSegs.count && isPrefix(baseSegs, of: parentSegs) {
                skip = max(skip, baseSegs.count)
            }
            return skip
        }
        if !baseSegs.isEmpty && baseSegs.count < parentSegs.count && isPrefix(baseSegs, of: parentSegs) {
            return baseSegs.count
        }
        return 0
    }

    private struct ComputedSyncMerge {
        let summary: SyncMergeSummary
        let localSubscriptions: [SubscriptionEntry]
        let localWatchHistory: [WatchHistoryItem]
        let localFavorites: [FavoriteItem]
        let localTombstones: [String: Int64]
        let localEmbyAccounts: [EmbyAccount]
    }

    private static func isHistoryTombstone(_ key: String) -> Bool {
        key.hasPrefix("hist:") || key.hasPrefix("fav:") || key.hasPrefix("add:")
    }

    private static func isSubscriptionTombstone(_ key: String) -> Bool {
        key.hasPrefix("sub:")
    }

    private static func siteKeyFromHistoryTombstone(_ tombKey: String) -> String? {
        let body: Substring
        if tombKey.hasPrefix("hist:") {
            body = tombKey.dropFirst(5)
        } else if tombKey.hasPrefix("fav:") {
            body = tombKey.dropFirst(4)
        } else if tombKey.hasPrefix("add:") {
            body = tombKey.dropFirst(4)
        } else {
            return nil
        }
        guard let nl = body.firstIndex(of: "\n") else { return nil }
        return String(body[..<nl])
    }

    private static func rewriteSiteKey(_ siteKey: String, using idMap: [String: String]) -> String {
        guard !idMap.isEmpty else { return siteKey }
        if let parsed = CmsSite.parseScopedKey(siteKey),
           let mappedSub = idMap[parsed.subscriptionId],
           mappedSub != parsed.subscriptionId
        {
            return CmsSite.canonicalScopedKey(rawKey: parsed.rawKey, subscriptionId: mappedSub)
        }
        for (oldSubId, newSubId) in idMap where !oldSubId.isEmpty && oldSubId != newSubId {
            let suffix = "_\(oldSubId)"
            if siteKey.hasSuffix(suffix) && siteKey.count > suffix.count {
                let rawPrefix = String(siteKey.dropLast(suffix.count))
                return "\(rawPrefix)_\(newSubId)"
            }
        }
        return siteKey
    }

    private static func rewriteHistoryTombstoneKey(_ tombKey: String, using idMap: [String: String]) -> String {
        guard !idMap.isEmpty else { return tombKey }
        let prefix: String
        if tombKey.hasPrefix("hist:") { prefix = "hist:" }
        else if tombKey.hasPrefix("fav:") { prefix = "fav:" }
        else if tombKey.hasPrefix("add:") { prefix = "add:" }
        else { return tombKey }
        let body = String(tombKey.dropFirst(prefix.count))
        guard let nl = body.firstIndex(of: "\n") else { return tombKey }
        let sitePart = String(body[..<nl])
        let vidPart = String(body[body.index(after: nl)...])
        return "\(prefix)\(rewriteSiteKey(sitePart, using: idMap))\n\(vidPart)"
    }

    private static func buildPrivacyConfig(
        from snapshot: IOSStorageManager.SyncStorageSnapshot,
        extraPrivateSubIds: Set<String> = [],
        extraPrivateSiteKeys: Set<String> = []
    ) -> CmsConfig {
        IOSStorageManager.buildOwnershipConfig(
            from: snapshot.subscriptions,
            knownPrivateSubscriptionIds: snapshot.knownPrivateSubscriptionIds.union(extraPrivateSubIds),
            knownPrivateSiteKeys: snapshot.knownPrivateSiteKeys.union(extraPrivateSiteKeys),
            ambiguousLegacyRawKeys: snapshot.ambiguousLegacyRawKeys
        )
    }

    private static func serializePublicSubscriptions(_ entries: [SubscriptionEntry]) -> [[String: Any]] {
        let pubSubs = entries
            .compactMap { $0.sanitizedForPublicExport() }
            .filter { !$0.rawContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        var subsPayload: [[String: Any]] = []
        var seenKeys = Set<String>()
        for s in pubSubs {
            let sk = Self.canonicalSubscriptionSyncKey(
                url: s.url,
                rawContent: s.rawContent,
                warehouseUrl: s.warehouseUrl
            )
            guard seenKeys.insert(sk).inserted else { continue }
            var dict = s.toDictionary()
            dict["syncKey"] = sk
            dict["isPrivate"] = false
            if s.updatedAt <= 0 { dict["updatedAt"] = Int64(1) }
            subsPayload.append(dict)
        }
        return subsPayload
    }

    private static func encodeSyncPayloadObject(
        nowMs: Int64,
        watchHistory: [[String: Any]],
        favorites: [[String: Any]],
        tombstones: [String: Int64],
        subscriptions: [[String: Any]]?,
        embyAccounts: [[String: Any]]?
    ) throws -> String {
        var root: [String: Any] = [
            "schema": Self.syncSchema,
            "version": Self.syncVersion,
            "updated": nowMs,
            "watch_history": watchHistory,
            "favorites": favorites,
            "tombstones": tombstones,
        ]
        if let subs = subscriptions {
            root["subscriptions"] = subs
        }
        if let emby = embyAccounts, !emby.isEmpty {
            root["emby_accounts"] = emby
        }
        let data = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Export & 3-Way Timestamp Merge

    public func exportSyncPayload(
        nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        syncSubscriptions: Bool = true,
        syncHistory: Bool = true
    ) throws -> String {
        try exportSyncPayload(
            from: storage.captureSyncSnapshot(),
            nowMs: nowMs,
            syncSubscriptions: syncSubscriptions,
            syncHistory: syncHistory
        )
    }

    private func exportSyncPayload(
        from snapshot: IOSStorageManager.SyncStorageSnapshot,
        nowMs: Int64,
        syncSubscriptions: Bool,
        syncHistory: Bool
    ) throws -> String {
        let privacyConfig = Self.buildPrivacyConfig(from: snapshot)
        var localIdToOutboundId: [String: String] = [:]
        for s in snapshot.subscriptions where !s.isEffectivelyPrivate && !s.id.isEmpty {
            if let wireId = Self.canonicalWireSubscriptionId(
                url: s.url,
                rawContent: s.rawContent,
                warehouseUrl: s.warehouseUrl
            ), wireId != s.id {
                localIdToOutboundId[s.id] = wireId
            }
        }

        let publicHist = syncHistory ? snapshot.watchHistory.filter { !privacyConfig.isPrivateSiteKey($0.site) } : []
        let publicFavs = syncHistory ? snapshot.favorites.filter { !privacyConfig.isPrivateSiteKey($0.site) } : []
        let hist = publicHist.map { item -> [String: Any] in
            var out = item
            out.site = Self.rewriteSiteKey(item.site, using: localIdToOutboundId)
            return out.toDictionary()
        }
        let favs = publicFavs.map { fav -> [String: Any] in
            var out = fav
            out.site = Self.rewriteSiteKey(fav.site, using: localIdToOutboundId)
            return out.toDictionary()
        }

        var tombs: [String: Int64] = [:]
        for (k, v) in snapshot.tombstones {
            if Self.isHistoryTombstone(k) {
                if syncHistory {
                    if let siteKey = Self.siteKeyFromHistoryTombstone(k),
                       privacyConfig.isPrivateSiteKey(siteKey)
                    {
                        continue
                    }
                    let outKey = Self.rewriteHistoryTombstoneKey(k, using: localIdToOutboundId)
                    tombs[outKey] = max(v, tombs[outKey] ?? 0)
                }
            } else if Self.isSubscriptionTombstone(k) {
                if syncSubscriptions { tombs[k] = v }
            } else {
                tombs[k] = v
            }
        }
        if syncHistory {
            for f in publicFavs where f.updated > 0 {
                let mappedSite = Self.rewriteSiteKey(f.site, using: localIdToOutboundId)
                let addKey = "add:\(mappedSite)\n\(f.id)"
                if f.updated > (tombs[addKey] ?? 0) { tombs[addKey] = f.updated }
            }
        }

        let subsPayload: [[String: Any]]? = syncSubscriptions
            ? Self.serializePublicSubscriptions(snapshot.subscriptions)
            : nil
        let embyPayload: [[String: Any]]? = syncSubscriptions
            ? snapshot.embyAccounts.filter { $0.allowCloudSync }.map { $0.toCloudSyncDictionary() }
            : nil

        return try Self.encodeSyncPayloadObject(
            nowMs: nowMs,
            watchHistory: hist,
            favorites: favs,
            tombstones: tombs,
            subscriptions: subsPayload,
            embyAccounts: embyPayload
        )
    }

    public func mergeSyncPayload(
        _ remotePayloadRaw: String?,
        nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        syncSubscriptions: Bool = true,
        syncHistory: Bool = true
    ) throws -> SyncMergeSummary {
        if !syncSubscriptions && !syncHistory {
            return try computeMergedSyncState(
                snapshot: storage.captureSyncSnapshot(),
                remotePayloadRaw: remotePayloadRaw,
                nowMs: nowMs,
                syncSubscriptions: false,
                syncHistory: false
            ).summary
        }
        return try storage.commitSyncTransform { liveSnapshot in
            let computed = try self.computeMergedSyncState(
                snapshot: liveSnapshot,
                remotePayloadRaw: remotePayloadRaw,
                nowMs: nowMs,
                syncSubscriptions: syncSubscriptions,
                syncHistory: syncHistory
            )
            return (
                subscriptions: computed.localSubscriptions,
                watchHistory: computed.localWatchHistory,
                favorites: computed.localFavorites,
                tombstones: computed.localTombstones,
                embyAccounts: computed.localEmbyAccounts,
                result: computed.summary
            )
        }
    }

    private func computeMergedSyncState(
        snapshot: IOSStorageManager.SyncStorageSnapshot,
        remotePayloadRaw: String?,
        nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        syncSubscriptions: Bool = true,
        syncHistory: Bool = true
    ) throws -> ComputedSyncMerge {
        let localSubsAll = snapshot.subscriptions
        let localHist = snapshot.watchHistory
        let localFavs = snapshot.favorites
        let localTombsRaw = snapshot.tombstones
        let localEmby = snapshot.embyAccounts

        guard let remoteRaw = remotePayloadRaw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !remoteRaw.isEmpty
        else {
            let payload = try exportSyncPayload(
                from: snapshot,
                nowMs: nowMs,
                syncSubscriptions: syncSubscriptions,
                syncHistory: syncHistory
            )
            var nextLocalTombs = localTombsRaw
            if syncHistory {
                for f in localFavs where f.updated > 0 {
                    let addKey = "add:\(f.key)"
                    if f.updated > (nextLocalTombs[addKey] ?? 0) {
                        nextLocalTombs[addKey] = f.updated
                    }
                }
            }
            let summary = SyncMergeSummary(
                historyCount: localHist.count,
                favoriteCount: localFavs.count,
                subscriptionCount: localSubsAll.filter { !$0.isEffectivelyPrivate }.count,
                changed: false,
                subscriptionsChanged: false,
                payloadJson: payload
            )
            return ComputedSyncMerge(
                summary: summary,
                localSubscriptions: localSubsAll,
                localWatchHistory: localHist,
                localFavorites: localFavs,
                localTombstones: nextLocalTombs,
                localEmbyAccounts: localEmby
            )
        }

        if remoteRaw.utf8.count > Self.maxSyncPayloadBytes {
            throw MarcoError.invalidFormat("远端同步文件超过 8 MB 大小限制")
        }

        let cleanedRemote = ConfigDecoder.stripJsonComments(remoteRaw)
        guard let decoded = (try? JSONSerialization.jsonObject(with: Data(cleanedRemote.utf8))) as? [String: Any] else {
            throw MarcoError.invalidFormat("远端同步数据不是有效的 JSON 格式")
        }

        let schema = (decoded["schema"] as? String) ?? ""
        let format = (decoded["format"] as? String) ?? ""
        var remoteHist: [WatchHistoryItem] = []
        var remoteHistRaw: [[String: Any]] = []
        var remoteFavs: [FavoriteItem] = []
        var remoteFavsRaw: [[String: Any]] = []
        var remoteTombsRaw: [String: Int64] = [:]
        var remoteFavAddTombs: [String: Int64] = [:]
        var remoteSubsRaw: [[String: Any]]? = nil
        var remoteEmbyRaw: [[String: Any]]? = nil

        if schema == Self.syncSchema {
            if let rh = (decoded["watch_history"] ?? decoded["history"] ?? decoded["watchHistory"]) as? [Any] {
                for item in rh {
                    guard let map = item as? [String: Any] else { continue }
                    remoteHistRaw.append(map)
                    let entry = WatchHistoryItem.fromDictionary(map)
                    if !entry.site.isEmpty && !entry.id.isEmpty {
                        remoteHist.append(entry)
                    }
                }
            }
            if let rf = decoded["favorites"] as? [Any] {
                for item in rf {
                    guard let map = item as? [String: Any] else { continue }
                    remoteFavsRaw.append(map)
                    let fav = FavoriteItem.fromDictionary(map)
                    if !fav.site.isEmpty && !fav.id.isEmpty {
                        remoteFavs.append(fav)
                        if fav.updated > 0 {
                            let addKey = "add:\(fav.key)"
                            if fav.updated > (remoteFavAddTombs[addKey] ?? 0) {
                                remoteFavAddTombs[addKey] = fav.updated
                            }
                        }
                    }
                }
            }
            if let rs = decoded["subscriptions"] as? [Any] {
                remoteSubsRaw = rs.compactMap { $0 as? [String: Any] }
            }
            if let re = decoded["emby_accounts"] as? [Any] {
                remoteEmbyRaw = re.compactMap { $0 as? [String: Any] }
            }
            if let rt = decoded["tombstones"] as? [String: Any] {
                for (k, v) in rt {
                    if let num = v as? NSNumber, num.int64Value > 0, !k.isEmpty {
                        remoteTombsRaw[k] = num.int64Value
                    }
                }
            }
        } else if format == BackupPayload.backupFormat || schema == BackupPayload.backupSchema {
            let backup = try BackupCodec.decodeBackupJson(remoteRaw)
            remoteHist = backup.watchHistory
            remoteHistRaw = backup.watchHistory.map { $0.toDictionary() }
            remoteFavs = backup.favorites
            remoteFavsRaw = backup.favorites.map { $0.toDictionary() }
            for fav in remoteFavs where fav.updated > 0 {
                let addKey = "add:\(fav.key)"
                if fav.updated > (remoteFavAddTombs[addKey] ?? 0) {
                    remoteFavAddTombs[addKey] = fav.updated
                }
            }
            remoteSubsRaw = backup.subscriptions.map { $0.toDictionary() }
        } else {
            throw MarcoError.invalidFormat("远端同步文件格式不受支持")
        }

        var localHistTombs = localTombsRaw.filter { Self.isHistoryTombstone($0.key) }
        var localSubTombs = localTombsRaw.filter { Self.isSubscriptionTombstone($0.key) }
        let localOtherTombs = localTombsRaw.filter { !Self.isHistoryTombstone($0.key) && !Self.isSubscriptionTombstone($0.key) }

        let remoteHistTombsRaw = remoteTombsRaw.filter { Self.isHistoryTombstone($0.key) }
        let remoteSubTombsRaw = remoteTombsRaw.filter { Self.isSubscriptionTombstone($0.key) }
        let remoteOtherTombsRaw = remoteTombsRaw.filter { !Self.isHistoryTombstone($0.key) && !Self.isSubscriptionTombstone($0.key) }

        let localPrivate = localSubsAll.filter { $0.isEffectivelyPrivate }
        let localPublic = localSubsAll.filter { !$0.isEffectivelyPrivate }
        let localPrivateSubSyncKeys: Set<String> = Set(localPrivate.compactMap { s -> String? in
            let hasIdentity = !s.rawContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !s.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !s.warehouseUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            guard hasIdentity else { return nil }
            return Self.canonicalSubscriptionSyncKey(url: s.url, rawContent: s.rawContent, warehouseUrl: s.warehouseUrl)
        })
        var localPublicBySyncKey: [String: SubscriptionEntry] = [:]
        for s in localPublic {
            let hasIdentity = !s.rawContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !s.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !s.warehouseUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            guard hasIdentity else { continue }
            let sk = Self.canonicalSubscriptionSyncKey(url: s.url, rawContent: s.rawContent, warehouseUrl: s.warehouseUrl)
            if localPublicBySyncKey[sk] == nil {
                localPublicBySyncKey[sk] = s
            }
        }

        var remoteIdToLocalId: [String: String] = [:]
        var localIdToOutboundId: [String: String] = [:]
        var localIdToCanonicalWireId: [String: String] = [:]
        var remoteIdToCanonicalWireId: [String: String] = [:]
        var scrubPrivateSubIds = Set<String>()
        var scrubRemoteSubTombs: [String: Int64] = [:]

        for s in localPrivate where !s.id.isEmpty {
            if let wirePrivId = Self.canonicalWireSubscriptionId(url: s.url, rawContent: s.rawContent, warehouseUrl: s.warehouseUrl) {
                localIdToCanonicalWireId[s.id] = wirePrivId
                scrubPrivateSubIds.insert(wirePrivId)
            }
        }
        for s in localPublic where !s.id.isEmpty {
            if let wireId = Self.canonicalWireSubscriptionId(url: s.url, rawContent: s.rawContent, warehouseUrl: s.warehouseUrl) {
                localIdToCanonicalWireId[s.id] = wireId
                if wireId != s.id {
                    if remoteIdToLocalId[wireId] == nil { remoteIdToLocalId[wireId] = s.id }
                    localIdToOutboundId[s.id] = wireId
                }
            }
        }

        for rawMap in (remoteSubsRaw ?? []) {
            let candidate = SubscriptionEntry.fromDictionary(rawMap)
            let sk = Self.canonicalSubscriptionSyncKey(url: candidate.url, rawContent: candidate.rawContent, warehouseUrl: candidate.warehouseUrl)
            let candidateWireId = "sub_\(sk.prefix(12))"
            if !candidate.id.isEmpty {
                remoteIdToCanonicalWireId[candidate.id] = candidateWireId
            }
            if localPrivateSubSyncKeys.contains(sk)
                || (!candidate.id.isEmpty && snapshot.knownPrivateSubscriptionIds.contains(candidate.id))
            {
                if !candidate.id.isEmpty { scrubPrivateSubIds.insert(candidate.id) }
                scrubPrivateSubIds.insert(candidateWireId)
                scrubRemoteSubTombs["sub:\(sk)"] = max(nowMs, candidate.updatedAt + 1)
                continue
            }
            if let localMatch = localPublicBySyncKey[sk], !candidate.id.isEmpty, candidate.id != localMatch.id {
                remoteIdToLocalId[candidate.id] = localMatch.id
            }
        }

        var finalSubscriptions = localSubsAll
        var finalEmbyAccounts = localEmby
        var subscriptionsChanged = false
        let outboundSubscriptions: [[String: Any]]?
        let outboundEmbyAccounts: [[String: Any]]?
        var outboundSubTombs: [String: Int64]

        if syncSubscriptions {
            var mergedSubTombs = localSubTombs
            for (k, ts) in remoteSubTombsRaw where ts > (mergedSubTombs[k] ?? 0) {
                mergedSubTombs[k] = ts
            }

            var subOrder: [String] = []
            var subByKey: [String: SubscriptionEntry] = [:]
            var reservedIds = Set(localPrivate.map(\.id))

            for s in localPublic {
                let hasIdentity = !s.rawContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || !s.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || !s.warehouseUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                guard hasIdentity else { continue }
                let sk = Self.canonicalSubscriptionSyncKey(url: s.url, rawContent: s.rawContent, warehouseUrl: s.warehouseUrl)
                let delTs = mergedSubTombs["sub:\(sk)"] ?? 0
                if delTs > 0 {
                    if s.updatedAt > delTs {
                        mergedSubTombs.removeValue(forKey: "sub:\(sk)")
                    } else {
                        continue
                    }
                }
                if subByKey[sk] == nil { subOrder.append(sk) }
                subByKey[sk] = s
                reservedIds.insert(s.id)
            }

            for rawMap in (remoteSubsRaw ?? []) {
                let candidate = SubscriptionEntry.fromDictionary(rawMap)
                guard !candidate.isEffectivelyPrivate,
                      !candidate.rawContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let parsed = try? CmsParser.parseConfig(candidate.rawContent, origin: candidate.url)
                else { continue }
                let sk = Self.canonicalSubscriptionSyncKey(url: candidate.url, rawContent: candidate.rawContent, warehouseUrl: candidate.warehouseUrl)
                if localPrivateSubSyncKeys.contains(sk)
                    || (!candidate.id.isEmpty && snapshot.knownPrivateSubscriptionIds.contains(candidate.id))
                {
                    if !candidate.id.isEmpty { scrubPrivateSubIds.insert(candidate.id) }
                    scrubRemoteSubTombs["sub:\(sk)"] = max(nowMs, candidate.updatedAt + 1)
                    continue
                }
                let incomingTs = max(1, candidate.updatedAt)
                let delTs = mergedSubTombs["sub:\(sk)"] ?? 0
                if delTs > 0 {
                    if incomingTs > delTs {
                        mergedSubTombs.removeValue(forKey: "sub:\(sk)")
                    } else {
                        continue
                    }
                }

                if let existing = subByKey[sk] {
                    if !candidate.id.isEmpty && candidate.id != existing.id {
                        remoteIdToLocalId[candidate.id] = existing.id
                    }
                    let existingIsStub = existing.rawContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    let existingEffectiveTs = max(1, existing.updatedAt)
                    if existingIsStub || incomingTs > existingEffectiveTs {
                        var updated = candidate
                        updated.id = existing.id
                        if existingIsStub {
                            if !existing.group.isEmpty { updated.group = existing.group }
                            updated.enabled = existing.enabled
                        }
                        let existingSanitized = CmsParser.sanitizePublicRawConfig(existing.rawContent, defaultGroup: existing.group)
                        let incomingSanitized = CmsParser.sanitizePublicRawConfig(candidate.rawContent, defaultGroup: candidate.group)
                        if !existingIsStub && !existingSanitized.isEmpty && existingSanitized == incomingSanitized {
                            updated.rawContent = existing.rawContent
                            updated.siteCount = existing.siteCount
                            updated.liveCount = existing.liveCount
                        } else {
                            updated.siteCount = parsed.sites.count
                            updated.liveCount = parsed.lives.count
                        }
                        updated.updatedAt = max(existing.updatedAt, incomingTs)
                        if updated.depots.isEmpty {
                            updated.depots = !existing.depots.isEmpty ? existing.depots : parsed.depots
                        }
                        subByKey[sk] = updated
                    }
                } else {
                    var assignedId = candidate.id
                    if assignedId.isEmpty || reservedIds.contains(assignedId) {
                        assignedId = "sub_\(sk.prefix(12))"
                    }
                    if !candidate.id.isEmpty && candidate.id != assignedId {
                        remoteIdToLocalId[candidate.id] = assignedId
                    }
                    reservedIds.insert(assignedId)
                    var inserted = candidate
                    inserted.id = assignedId
                    inserted.siteCount = parsed.sites.count
                    inserted.liveCount = parsed.lives.count
                    inserted.updatedAt = incomingTs
                    if inserted.depots.isEmpty { inserted.depots = parsed.depots }
                    subOrder.append(sk)
                    subByKey[sk] = inserted
                }
            }

            let mergedPublic = subOrder.compactMap { subByKey[$0] }
            subscriptionsChanged = mergedPublic != localPublic
            finalSubscriptions = mergedPublic + localPrivate
            localSubTombs = mergedSubTombs
            outboundSubscriptions = Self.serializePublicSubscriptions(mergedPublic)
            outboundSubTombs = mergedSubTombs
            for (k, ts) in scrubRemoteSubTombs where ts > (outboundSubTombs[k] ?? 0) {
                outboundSubTombs[k] = ts
            }

            // Merge non-secret Emby metadata (tokens remain local!)
            var embyByKey: [String: EmbyAccount] = [:]
            for acc in localEmby { embyByKey[acc.key] = acc }
            for rawMap in (remoteEmbyRaw ?? []) {
                guard let remoteAcc = EmbyAccount.fromDictionary(rawMap), remoteAcc.allowCloudSync else { continue }
                if let localAcc = embyByKey[remoteAcc.key] {
                    if remoteAcc.updatedAt > localAcc.updatedAt {
                        var merged = remoteAcc
                        merged.accessToken = localAcc.accessToken
                        embyByKey[remoteAcc.key] = merged
                    }
                } else {
                    var imported = remoteAcc
                    imported.accessToken = ""
                    embyByKey[remoteAcc.key] = imported
                }
            }
            finalEmbyAccounts = embyByKey.values.sorted { $0.key < $1.key }
            outboundEmbyAccounts = finalEmbyAccounts
                .filter { $0.allowCloudSync }
                .map { $0.toCloudSyncDictionary() }
        } else {
            outboundSubscriptions = remoteSubsRaw
            outboundEmbyAccounts = remoteEmbyRaw
            outboundSubTombs = remoteSubTombsRaw
        }

        for s in finalSubscriptions where !s.id.isEmpty {
            guard let wireId = Self.canonicalWireSubscriptionId(url: s.url, rawContent: s.rawContent, warehouseUrl: s.warehouseUrl) else {
                continue
            }
            if localIdToCanonicalWireId[s.id] == nil { localIdToCanonicalWireId[s.id] = wireId }
            if s.isEffectivelyPrivate {
                scrubPrivateSubIds.insert(wireId)
            } else if wireId != s.id {
                if remoteIdToLocalId[wireId] == nil { remoteIdToLocalId[wireId] = s.id }
                if localIdToOutboundId[s.id] == nil { localIdToOutboundId[s.id] = wireId }
            }
        }

        var extraPrivateSiteKeys = Set<String>()
        for privKey in snapshot.knownPrivateSiteKeys {
            let wireKey = Self.rewriteSiteKey(privKey, using: localIdToCanonicalWireId)
            if wireKey != privKey { extraPrivateSiteKeys.insert(wireKey) }
        }

        let effectivePrivacyConfig = Self.buildPrivacyConfig(
            from: snapshot,
            extraPrivateSubIds: scrubPrivateSubIds,
            extraPrivateSiteKeys: extraPrivateSiteKeys
        )

        func canonicalWireSiteKey(_ siteKey: String) -> String {
            let step1 = Self.rewriteSiteKey(siteKey, using: remoteIdToCanonicalWireId)
            return Self.rewriteSiteKey(step1, using: localIdToCanonicalWireId)
        }

        func isTransitionedPrivateSite(_ siteKey: String) -> Bool {
            if snapshot.transitionedToPrivateSiteKeys.contains(siteKey) { return true }
            if let parsed = CmsSite.parseScopedKey(siteKey),
               snapshot.transitionedToPrivateSubIds.contains(parsed.subscriptionId)
            {
                return true
            }
            for subId in snapshot.transitionedToPrivateSubIds where !subId.isEmpty && siteKey.hasSuffix("_\(subId)") {
                return true
            }
            return false
        }

        var finalHistory = localHist
        var finalFavorites = localFavs
        let outboundWatchHistory: [[String: Any]]
        let outboundFavorites: [[String: Any]]
        var outboundHistTombs: [String: Int64]

        if syncHistory {
            let localPrivateHist = localHist.filter { effectivePrivacyConfig.isPrivateSiteKey($0.site) }
            let localPublicHist = localHist.filter { !effectivePrivacyConfig.isPrivateSiteKey($0.site) }
            let localPrivateFavs = localFavs.filter { effectivePrivacyConfig.isPrivateSiteKey($0.site) }
            let localPublicFavs = localFavs.filter { !effectivePrivacyConfig.isPrivateSiteKey($0.site) }

            var scrubRemoteHistTombs: [String: Int64] = [:]
            var scrubRemoveAddKeys = Set<String>()

            var remappedRemotePublicHist: [WatchHistoryItem] = []
            for orig in remoteHist {
                var remapped = orig
                remapped.site = Self.rewriteSiteKey(orig.site, using: remoteIdToLocalId)
                if effectivePrivacyConfig.isPrivateSiteKey(orig.site) || effectivePrivacyConfig.isPrivateSiteKey(remapped.site) {
                    let scrubTs = max(nowMs, orig.updated + 1)
                    scrubRemoteHistTombs["hist:\(orig.key)"] = max(scrubTs, scrubRemoteHistTombs["hist:\(orig.key)"] ?? 0)
                    let wireSite = canonicalWireSiteKey(remapped.site != orig.site ? remapped.site : orig.site)
                    let wireTomb = "hist:\(wireSite)\n\(orig.id)"
                    scrubRemoteHistTombs[wireTomb] = max(scrubTs, scrubRemoteHistTombs[wireTomb] ?? 0)
                    continue
                }
                remappedRemotePublicHist.append(remapped)
            }

            var remappedRemotePublicFavs: [FavoriteItem] = []
            for orig in remoteFavs {
                var remapped = orig
                remapped.site = Self.rewriteSiteKey(orig.site, using: remoteIdToLocalId)
                if effectivePrivacyConfig.isPrivateSiteKey(orig.site) || effectivePrivacyConfig.isPrivateSiteKey(remapped.site) {
                    let scrubTs = max(nowMs, orig.updated + 1)
                    scrubRemoteHistTombs["fav:\(orig.key)"] = max(scrubTs, scrubRemoteHistTombs["fav:\(orig.key)"] ?? 0)
                    scrubRemoveAddKeys.insert("add:\(orig.key)")
                    let wireSite = canonicalWireSiteKey(remapped.site != orig.site ? remapped.site : orig.site)
                    let wireTomb = "fav:\(wireSite)\n\(orig.id)"
                    scrubRemoteHistTombs[wireTomb] = max(scrubTs, scrubRemoteHistTombs[wireTomb] ?? 0)
                    scrubRemoveAddKeys.insert("add:\(wireSite)\n\(orig.id)")
                    continue
                }
                remappedRemotePublicFavs.append(remapped)
            }

            for item in localPrivateHist where isTransitionedPrivateSite(item.site) {
                let wireSite = canonicalWireSiteKey(item.site)
                let scrubTs = max(nowMs, item.updated + 1)
                let wireTomb = "hist:\(wireSite)\n\(item.id)"
                scrubRemoteHistTombs[wireTomb] = max(scrubTs, scrubRemoteHistTombs[wireTomb] ?? 0)
            }
            for fav in localPrivateFavs where isTransitionedPrivateSite(fav.site) {
                let wireSite = canonicalWireSiteKey(fav.site)
                let scrubTs = max(nowMs, fav.updated + 1)
                let wireTomb = "fav:\(wireSite)\n\(fav.id)"
                scrubRemoteHistTombs[wireTomb] = max(scrubTs, scrubRemoteHistTombs[wireTomb] ?? 0)
                scrubRemoveAddKeys.insert("add:\(wireSite)\n\(fav.id)")
            }

            var mergedHistTombs: [String: Int64] = localHistTombs
            for f in localPublicFavs where f.updated > 0 {
                let addKey = "add:\(f.key)"
                if f.updated > (mergedHistTombs[addKey] ?? 0) { mergedHistTombs[addKey] = f.updated }
            }
            for (origKey, ts) in remoteHistTombsRaw {
                let mappedKey = Self.rewriteHistoryTombstoneKey(origKey, using: remoteIdToLocalId)
                let origIsPrivate = Self.siteKeyFromHistoryTombstone(origKey).map { effectivePrivacyConfig.isPrivateSiteKey($0) } ?? false
                let mappedIsPrivate = Self.siteKeyFromHistoryTombstone(mappedKey).map { effectivePrivacyConfig.isPrivateSiteKey($0) } ?? false
                if origIsPrivate || mappedIsPrivate {
                    if origKey.hasPrefix("add:") {
                        scrubRemoveAddKeys.insert(origKey)
                        scrubRemoveAddKeys.insert(Self.rewriteHistoryTombstoneKey(origKey, using: localIdToCanonicalWireId))
                    } else {
                        scrubRemoteHistTombs[origKey] = max(ts, scrubRemoteHistTombs[origKey] ?? 0)
                        let wireKey = Self.rewriteHistoryTombstoneKey(
                            Self.rewriteHistoryTombstoneKey(origKey, using: remoteIdToCanonicalWireId),
                            using: localIdToCanonicalWireId
                        )
                        scrubRemoteHistTombs[wireKey] = max(ts, scrubRemoteHistTombs[wireKey] ?? 0)
                    }
                    continue
                }
                if ts > (mergedHistTombs[mappedKey] ?? 0) { mergedHistTombs[mappedKey] = ts }
            }
            for (origKey, ts) in remoteFavAddTombs {
                let mappedKey = Self.rewriteHistoryTombstoneKey(origKey, using: remoteIdToLocalId)
                if let origSite = Self.siteKeyFromHistoryTombstone(origKey), effectivePrivacyConfig.isPrivateSiteKey(origSite) {
                    scrubRemoveAddKeys.insert(origKey)
                    continue
                }
                if let mappedSite = Self.siteKeyFromHistoryTombstone(mappedKey), effectivePrivacyConfig.isPrivateSiteKey(mappedSite) {
                    scrubRemoveAddKeys.insert(mappedKey)
                    continue
                }
                if ts > (mergedHistTombs[mappedKey] ?? 0) { mergedHistTombs[mappedKey] = ts }
            }
            for k in Array(mergedHistTombs.keys) where k.hasPrefix("fav:") {
                let rawKey = String(k.dropFirst(4))
                if let delTs = mergedHistTombs[k], let addTs = mergedHistTombs["add:\(rawKey)"] {
                    if addTs > delTs { mergedHistTombs.removeValue(forKey: k) }
                    else { mergedHistTombs.removeValue(forKey: "add:\(rawKey)") }
                }
            }

            var histByKey: [String: WatchHistoryItem] = [:]
            for e in (localPublicHist + remappedRemotePublicHist) {
                let delTs = mergedHistTombs["hist:\(e.key)"] ?? 0
                if delTs > 0 {
                    if e.updated > delTs { mergedHistTombs.removeValue(forKey: "hist:\(e.key)") }
                    else { continue }
                }
                if let existing = histByKey[e.key] {
                    if e.updated > existing.updated || (e.updated == existing.updated && e.position > existing.position) {
                        histByKey[e.key] = e
                    }
                } else {
                    histByKey[e.key] = e
                }
            }
            let mergedPublicHistory = Array(
                histByKey.values.sorted { a, b in
                    if a.updated != b.updated { return a.updated > b.updated }
                    return a.key < b.key
                }.prefix(CmsParser.maxHistoryEntries)
            )

            var favByKey: [String: FavoriteItem] = [:]
            for f in (localPublicFavs + remappedRemotePublicFavs) {
                let delTs = mergedHistTombs["fav:\(f.key)"] ?? 0
                let addTs = mergedHistTombs["add:\(f.key)"] ?? f.updated
                if delTs > 0 && delTs >= addTs { continue }
                if let existing = favByKey[f.key] {
                    if f.updated > existing.updated {
                        var nextFav = f
                        if addTs > nextFav.updated { nextFav.updated = addTs }
                        favByKey[f.key] = nextFav
                    }
                } else {
                    var nextFav = f
                    if addTs > nextFav.updated { nextFav.updated = addTs }
                    favByKey[f.key] = nextFav
                }
            }
            let mergedPublicFavorites = Array(
                favByKey.values.sorted { a, b in
                    let ta = mergedHistTombs["add:\(a.key)"] ?? a.updated
                    let tb = mergedHistTombs["add:\(b.key)"] ?? b.updated
                    if ta != tb { return ta > tb }
                    return a.key < b.key
                }.prefix(CmsParser.maxFavoriteEntries)
            )

            for f in mergedPublicFavorites where f.updated > 0 {
                let addKey = "add:\(f.key)"
                if f.updated > (mergedHistTombs[addKey] ?? 0) { mergedHistTombs[addKey] = f.updated }
            }

            var combinedHistByKey: [String: WatchHistoryItem] = [:]
            for item in mergedPublicHistory { combinedHistByKey[item.key] = item }
            for item in localPrivateHist { combinedHistByKey[item.key] = item }
            finalHistory = Array(
                combinedHistByKey.values.sorted { a, b in
                    if a.updated != b.updated { return a.updated > b.updated }
                    return a.key < b.key
                }.prefix(CmsParser.maxHistoryEntries)
            )

            var combinedFavByKey: [String: FavoriteItem] = [:]
            for fav in mergedPublicFavorites { combinedFavByKey[fav.key] = fav }
            for fav in localPrivateFavs { combinedFavByKey[fav.key] = fav }
            finalFavorites = Array(
                combinedFavByKey.values.sorted { a, b in
                    let ta = mergedHistTombs["add:\(a.key)"] ?? a.updated
                    let tb = mergedHistTombs["add:\(b.key)"] ?? b.updated
                    if ta != tb { return ta > tb }
                    return a.key < b.key
                }.prefix(CmsParser.maxFavoriteEntries)
            )

            localHistTombs = mergedHistTombs
            outboundWatchHistory = mergedPublicHistory.map { item in
                var out = item
                out.site = Self.rewriteSiteKey(item.site, using: localIdToOutboundId)
                return out.toDictionary()
            }
            outboundFavorites = mergedPublicFavorites.map { fav in
                var out = fav
                out.site = Self.rewriteSiteKey(fav.site, using: localIdToOutboundId)
                return out.toDictionary()
            }
            var filteredOutboundTombs: [String: Int64] = [:]
            for (k, v) in mergedHistTombs {
                if let siteKey = Self.siteKeyFromHistoryTombstone(k), effectivePrivacyConfig.isPrivateSiteKey(siteKey) {
                    continue
                }
                let outKey = Self.rewriteHistoryTombstoneKey(k, using: localIdToOutboundId)
                filteredOutboundTombs[outKey] = max(v, filteredOutboundTombs[outKey] ?? 0)
            }
            for (k, ts) in scrubRemoteHistTombs where ts > (filteredOutboundTombs[k] ?? 0) {
                filteredOutboundTombs[k] = ts
            }
            for remAdd in scrubRemoveAddKeys { filteredOutboundTombs.removeValue(forKey: remAdd) }
            outboundHistTombs = filteredOutboundTombs
        } else {
            outboundWatchHistory = remoteHistRaw
            outboundFavorites = remoteFavsRaw
            outboundHistTombs = remoteHistTombsRaw
        }

        var localMergedTombs = localOtherTombs
        for (k, v) in localHistTombs { localMergedTombs[k] = v }
        for (k, v) in localSubTombs { localMergedTombs[k] = v }

        var outboundTombs = remoteOtherTombsRaw
        for (k, v) in outboundHistTombs { outboundTombs[k] = v }
        for (k, v) in outboundSubTombs { outboundTombs[k] = v }

        let payloadJson = try Self.encodeSyncPayloadObject(
            nowMs: nowMs,
            watchHistory: outboundWatchHistory,
            favorites: outboundFavorites,
            tombstones: outboundTombs,
            subscriptions: outboundSubscriptions,
            embyAccounts: outboundEmbyAccounts
        )

        let changed = subscriptionsChanged
            || finalHistory != localHist
            || finalFavorites != localFavs
            || localMergedTombs != localTombsRaw
            || finalEmbyAccounts != localEmby

        let summary = SyncMergeSummary(
            historyCount: finalHistory.count,
            favoriteCount: finalFavorites.count,
            subscriptionCount: finalSubscriptions.filter { !$0.isEffectivelyPrivate }.count,
            changed: changed,
            subscriptionsChanged: subscriptionsChanged,
            payloadJson: payloadJson
        )
        return ComputedSyncMerge(
            summary: summary,
            localSubscriptions: finalSubscriptions,
            localWatchHistory: finalHistory,
            localFavorites: finalFavorites,
            localTombstones: localMergedTombs,
            localEmbyAccounts: finalEmbyAccounts
        )
    }

    // MARK: - Full WebDAV Cycle + Danmu Sidecar Sync

    public func syncNow(maxConflictRetries: Int = 3) async throws -> SyncMergeSummary {
        var config = storage.loadWebDavConfig()
        let rawBaseUrl = config.url
        let targetUrlStr = try Self.resolveWebdavFileUrl(rawBaseUrl)
        guard let fileURL = URL(string: targetUrlStr) else {
            throw MarcoError.invalidFormat("无效的 WebDAV 目标地址")
        }

        let boundedRetries = max(0, min(maxConflictRetries, 8))
        var attempt = 0

        do {
            while true {
                var remoteBody: String?
                var remoteEtag: String?
                var fileAbsent = false

                let getResp = try await transport.send(
                    method: "GET",
                    url: fileURL,
                    headers: buildHeaders(config: config),
                    body: nil
                )
                if (200...299).contains(getResp.statusCode) {
                    if getResp.body.count > Self.maxSyncPayloadBytes {
                        throw MarcoError.webdavError("远端同步文件超过 8 MB 限制")
                    }
                    remoteBody = String(decoding: getResp.body, as: UTF8.self)
                    if let etag = getResp.header("ETag")?.trimmingCharacters(in: .whitespaces),
                       !etag.isEmpty,
                       !etag.lowercased().hasPrefix("w/")
                    {
                        remoteEtag = etag
                    }
                } else if getResp.statusCode == 404 {
                    remoteBody = nil
                    fileAbsent = true
                } else if getResp.statusCode == 401 || getResp.statusCode == 403 {
                    throw MarcoError.webdavError("WebDAV 认证失败 (HTTP \(getResp.statusCode))，请检查账号与应用密码")
                } else {
                    throw MarcoError.webdavError("WebDAV 读取失败 (HTTP \(getResp.statusCode))")
                }

                let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
                let preSnapshot = storage.captureSyncSnapshot()
                let computed = try computeMergedSyncState(
                    snapshot: preSnapshot,
                    remotePayloadRaw: remoteBody,
                    nowMs: nowMs,
                    syncSubscriptions: config.syncSubscriptions,
                    syncHistory: config.syncHistory
                )

                if !config.syncSubscriptions && !config.syncHistory {
                    var summary = computed.summary
                    if config.syncDanmu {
                        do {
                            let count = try await syncDanmuSidecar(config: config, rawBaseUrl: rawBaseUrl, mainUrlStr: targetUrlStr)
                            summary.danmuSourceCount = count
                            config.lastDanmuSyncStatus = "弹幕源同步成功（\(count) 个）"
                        } catch {
                            summary.danmuError = error.localizedDescription
                            config.lastDanmuSyncStatus = "弹幕源同步失败：\(error.localizedDescription)"
                        }
                    }
                    config.lastSyncTimeMs = nowMs
                    config.lastSyncStatus = "同步完成"
                    try? storage.saveWebDavConfig(config)
                    return summary
                }

                let payloadBytes = Data(computed.summary.payloadJson.utf8)
                var ifMatch: String?
                var ifNoneMatch: String?
                if fileAbsent {
                    ifNoneMatch = "*"
                } else if let etag = remoteEtag {
                    ifMatch = etag
                }

                let putResp = try await putWithMkcolRetry(
                    config: config,
                    rawBaseUrl: rawBaseUrl,
                    fileURL: fileURL,
                    payload: payloadBytes,
                    ifMatch: ifMatch,
                    ifNoneMatch: ifNoneMatch
                )

                if ifNoneMatch != nil && !(200...299).contains(putResp.statusCode) {
                    if putResp.statusCode == 412 || putResp.statusCode == 409 {
                        if attempt < boundedRetries {
                            attempt += 1
                            continue
                        }
                        throw MarcoError.webdavError("WebDAV 首次创建冲突（HTTP \(putResp.statusCode)），已保留本机与远端数据，请稍后重试")
                    }
                    if [400, 405, 406, 417, 428, 500, 501].contains(putResp.statusCode) {
                        let probeResp = try await transport.send(
                            method: "GET",
                            url: fileURL,
                            headers: buildHeaders(config: config),
                            body: nil
                        )
                        if (200...299).contains(probeResp.statusCode) {
                            if attempt < boundedRetries {
                                attempt += 1
                                continue
                            }
                            throw MarcoError.webdavError("WebDAV 首次创建已被其他设备抢先完成，请稍后重试")
                        }
                        throw MarcoError.webdavError("当前 WebDAV 服务端不支持安全原子创建（HTTP \(putResp.statusCode)），已中止写入")
                    }
                }

                if putResp.statusCode == 412 || (ifMatch != nil && putResp.statusCode == 409) {
                    if attempt < boundedRetries {
                        attempt += 1
                        continue
                    }
                    throw MarcoError.webdavError("WebDAV 远端持续冲突（HTTP \(putResp.statusCode)），已保留本机与远端数据")
                }

                if putResp.statusCode == 401 || putResp.statusCode == 403 {
                    throw MarcoError.webdavError("WebDAV 写入被拒绝 (HTTP \(putResp.statusCode))")
                }
                guard (200...299).contains(putResp.statusCode) else {
                    throw MarcoError.webdavError("WebDAV 写入失败 (HTTP \(putResp.statusCode))")
                }

                let commitResult: (summary: SyncMergeSummary, needsFollowUpPush: Bool) = try storage.commitSyncTransform { liveSnapshot in
                    let remerged = try self.computeMergedSyncState(
                        snapshot: liveSnapshot,
                        remotePayloadRaw: remoteBody,
                        nowMs: nowMs,
                        syncSubscriptions: config.syncSubscriptions,
                        syncHistory: config.syncHistory
                    )
                    let mutatedDuringPut = (liveSnapshot.version != preSnapshot.version)
                    let outboundDiverged = (remerged.summary.payloadJson != computed.summary.payloadJson)
                    return (
                        subscriptions: remerged.localSubscriptions,
                        watchHistory: remerged.localWatchHistory,
                        favorites: remerged.localFavorites,
                        tombstones: remerged.localTombstones,
                        embyAccounts: remerged.localEmbyAccounts,
                        result: (remerged.summary, mutatedDuringPut && outboundDiverged)
                    )
                }

                if commitResult.needsFollowUpPush && attempt < boundedRetries {
                    attempt += 1
                    continue
                }

                var finalSummary = commitResult.summary
                if config.syncDanmu {
                    do {
                        let count = try await syncDanmuSidecar(config: config, rawBaseUrl: rawBaseUrl, mainUrlStr: targetUrlStr)
                        finalSummary.danmuSourceCount = count
                        config.lastDanmuSyncStatus = "弹幕源同步成功（\(count) 个）"
                    } catch {
                        finalSummary.danmuError = error.localizedDescription
                        config.lastDanmuSyncStatus = "弹幕源同步失败：\(error.localizedDescription)"
                    }
                }

                config.lastSyncTimeMs = nowMs
                if commitResult.needsFollowUpPush {
                    finalSummary.hasPendingLocalChanges = true
                    config.lastSyncStatus = "同步完成，但上传期间有新改动待同步（历史 \(finalSummary.historyCount) · 收藏 \(finalSummary.favoriteCount) · 订阅 \(finalSummary.subscriptionCount)）"
                } else {
                    config.lastSyncStatus = "同步成功（历史 \(finalSummary.historyCount) · 收藏 \(finalSummary.favoriteCount) · 订阅 \(finalSummary.subscriptionCount)）"
                }
                try? storage.saveWebDavConfig(config)
                return finalSummary
            }
        } catch {
            config.lastSyncStatus = "同步失败：\(error.localizedDescription)"
            try? storage.saveWebDavConfig(config)
            throw error
        }
    }

    /// Synchronizes only the `.danmu.json` sidecar file using deterministic 3-way merge.
    @discardableResult
    public func syncDanmuSidecar(
        config: WebDavConfig,
        rawBaseUrl: String,
        mainUrlStr: String
    ) async throws -> Int {
        guard let sidecarUrl = Self.resolveDanmuSidecarUrl(fromMainSyncUrl: mainUrlStr) else {
            throw MarcoError.invalidFormat("无法推导弹幕同步文件路径")
        }
        let getResp = try await transport.send(
            method: "GET",
            url: sidecarUrl,
            headers: buildHeaders(config: config),
            body: nil
        )
        var remoteDoc: DanmuSourceSyncDocument?
        var remoteEtag: String?
        if (200...299).contains(getResp.statusCode) {
            if let decoded = Self.parseRemoteDanmuDocument(getResp.body) {
                remoteDoc = decoded
            }
            if let etag = getResp.header("ETag")?.trimmingCharacters(in: .whitespaces),
               !etag.isEmpty, !etag.lowercased().hasPrefix("w/")
            {
                remoteEtag = etag
            }
        } else if getResp.statusCode != 404 {
            throw MarcoError.webdavError("弹幕源同步读取失败 (HTTP \(getResp.statusCode))")
        }

        let localDoc = storage.danmuSyncDocument()
        let baseDoc = storage.danmuSyncBaseDocument()
        let merged = Self.mergeDanmuDocuments(base: baseDoc, local: localDoc, remote: remoteDoc)

        if merged.needsUpload {
            let payloadData = try JSONSerialization.data(
                withJSONObject: merged.document.toPayloadDictionary(),
                options: [.sortedKeys]
            )
            let putResp = try await putWithMkcolRetry(
                config: config,
                rawBaseUrl: rawBaseUrl,
                fileURL: sidecarUrl,
                payload: payloadData,
                ifMatch: remoteDoc == nil ? nil : remoteEtag,
                ifNoneMatch: remoteDoc == nil ? "*" : nil
            )
            guard (200...299).contains(putResp.statusCode) else {
                throw MarcoError.webdavError("弹幕源写入失败 (HTTP \(putResp.statusCode))")
            }
        }

        storage.saveDanmuSyncDocuments(current: merged.document, base: merged.document)
        var ds = storage.danmuSettings()
        let joined = merged.document.sources.map(\.url).joined(separator: "\n")
        if ds.serverUrls != joined {
            ds.serverUrls = joined
            storage.saveDanmuSettings(ds)
        }
        return merged.document.sources.count
    }

    public static func parseRemoteDanmuDocument(_ data: Data) -> DanmuSourceSyncDocument? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let schema = (obj["schemaVersion"] as? NSNumber)?.intValue,
              schema == DanmuSourceSyncDocument.currentSchemaVersion,
              let rawSources = obj["sources"] as? [Any]
        else {
            return nil
        }
        var entries: [DanmuSourceEntry] = []
        var seen = Set<String>()
        for item in rawSources {
            let urlStr: String
            let reqAuth: Bool
            if let s = item as? String {
                urlStr = s.trimmingCharacters(in: .whitespacesAndNewlines)
                reqAuth = false
            } else if let m = item as? [String: Any], let u = m["url"] as? String {
                urlStr = u.trimmingCharacters(in: .whitespacesAndNewlines)
                reqAuth = (m["requiresAuth"] as? Bool) ?? false
            } else {
                continue
            }
            guard !urlStr.isEmpty, seen.insert(urlStr).inserted else { continue }
            entries.append(DanmuSourceEntry(url: urlStr, requiresAuth: reqAuth))
        }
        let clearedAt = (obj["clearedAt"] as? NSNumber)?.int64Value ?? 0
        if entries.isEmpty && clearedAt <= 0 {
            return nil
        }
        return DanmuSourceSyncDocument(
            schemaVersion: schema,
            updatedAt: (obj["updatedAt"] as? NSNumber)?.int64Value ?? 0,
            revision: (obj["revision"] as? NSNumber)?.intValue ?? 0,
            clearedAt: clearedAt,
            initialized: true,
            sources: entries
        )
    }

    public static func mergeDanmuDocuments(
        base: DanmuSourceSyncDocument,
        local: DanmuSourceSyncDocument,
        remote: DanmuSourceSyncDocument?
    ) -> (document: DanmuSourceSyncDocument, needsUpload: Bool) {
        guard let remote = remote else {
            if local.isFreshUninitialized {
                return (local, false)
            }
            return (local, true)
        }
        if local.isFreshUninitialized {
            return (remote, false)
        }
        if local.sources == remote.sources && local.clearedAt == remote.clearedAt {
            let winner = local.updatedAt >= remote.updatedAt ? local : remote
            return (winner, false)
        }
        // Deliberate clear wins if newer than peer's updatedAt
        if local.sources.isEmpty && local.clearedAt > 0 && local.clearedAt >= remote.updatedAt {
            return (local, true)
        }
        if remote.sources.isEmpty && remote.clearedAt > 0 && remote.clearedAt >= local.updatedAt {
            return (remote, false)
        }
        // 3-way union preserving deletions relative to base
        let baseUrls = Set(base.sources.map(\.url))
        let localUrls = Set(local.sources.map(\.url))
        let remoteUrls = Set(remote.sources.map(\.url))
        let deletedLocally = baseUrls.subtracting(localUrls)
        let deletedRemotely = baseUrls.subtracting(remoteUrls)

        var mergedList: [DanmuSourceEntry] = []
        var seen = Set<String>()
        let primaryOrder = local.updatedAt >= remote.updatedAt ? local.sources + remote.sources : remote.sources + local.sources
        for entry in primaryOrder {
            if deletedLocally.contains(entry.url) && !remoteUrls.subtracting(baseUrls).contains(entry.url) {
                continue
            }
            if deletedRemotely.contains(entry.url) && !localUrls.subtracting(baseUrls).contains(entry.url) {
                continue
            }
            if seen.insert(entry.url).inserted {
                mergedList.append(entry)
            }
        }
        let nowMs = max(Int64(Date().timeIntervalSince1970 * 1000), max(local.updatedAt, remote.updatedAt) + 1)
        let mergedDoc = DanmuSourceSyncDocument(
            schemaVersion: DanmuSourceSyncDocument.currentSchemaVersion,
            updatedAt: nowMs,
            revision: max(local.revision, remote.revision) + 1,
            clearedAt: mergedList.isEmpty ? nowMs : 0,
            initialized: true,
            sources: mergedList
        )
        return (mergedDoc, mergedDoc.sources != remote.sources)
    }

    // MARK: - HTTP & MKCOL Helpers

    private func putWithMkcolRetry(
        config: WebDavConfig,
        rawBaseUrl: String,
        fileURL: URL,
        payload: Data,
        ifMatch: String?,
        ifNoneMatch: String?
    ) async throws -> WebDavHttpResponse {
        var resp = try await transport.send(
            method: "PUT",
            url: fileURL,
            headers: buildHeaders(config: config, jsonContent: true, ifMatch: ifMatch, ifNoneMatch: ifNoneMatch),
            body: payload
        )
        if resp.statusCode == 404 || resp.statusCode == 409 {
            await ensureCollections(config: config, rawBaseUrl: rawBaseUrl, fileURL: fileURL)
            resp = try await transport.send(
                method: "PUT",
                url: fileURL,
                headers: buildHeaders(config: config, jsonContent: true, ifMatch: ifMatch, ifNoneMatch: ifNoneMatch),
                body: payload
            )
        }
        return resp
    }

    private func ensureCollections(config: WebDavConfig, rawBaseUrl: String, fileURL: URL) async {
        let segs = fileURL.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        guard segs.count > 1 else { return }
        let skip = Self.baseCollectionDepth(rawBaseUrl: rawBaseUrl, fileURL: fileURL)
        guard var comps = URLComponents(url: fileURL, resolvingAgainstBaseURL: false) else { return }

        for i in skip..<(segs.count - 1) {
            let prefixPath = "/" + segs[0...i].joined(separator: "/") + "/"
            comps.path = prefixPath
            guard let collUrl = comps.url else { continue }
            if let mkResp = try? await transport.send(
                method: "MKCOL",
                url: collUrl,
                headers: buildHeaders(config: config),
                body: nil
            ), mkResp.statusCode == 401 {
                break
            }
        }
    }

    private func buildHeaders(
        config: WebDavConfig,
        jsonContent: Bool = false,
        ifMatch: String? = nil,
        ifNoneMatch: String? = nil
    ) -> [String: String] {
        var headers: [String: String] = [
            "Accept": "application/json",
            "Cache-Control": "no-store",
        ]
        if jsonContent {
            headers["Content-Type"] = "application/json; charset=utf-8"
        }
        if let im = ifMatch, !im.isEmpty {
            headers["If-Match"] = im
        }
        if let inm = ifNoneMatch, !inm.isEmpty {
            headers["If-None-Match"] = inm
        }
        if !config.username.isEmpty || !config.password.isEmpty {
            let basic = Data("\(config.username):\(config.password)".utf8).base64EncodedString()
            headers["Authorization"] = "Basic \(basic)"
        }
        return headers
    }
}
