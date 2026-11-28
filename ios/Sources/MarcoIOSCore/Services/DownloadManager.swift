// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only

import CommonCrypto
import CryptoKit
import Foundation

public struct DownloadProgressEvent: Equatable, Sendable {
    public let taskId: String
    public let status: DownloadTaskStatus
    public let progress: Double
    public let receivedBytes: Int64
    public let totalBytes: Int64
    public let filePath: String
    public let error: String

    public init(
        taskId: String,
        status: DownloadTaskStatus,
        progress: Double,
        receivedBytes: Int64,
        totalBytes: Int64,
        filePath: String,
        error: String = ""
    ) {
        self.taskId = taskId
        self.status = status
        self.progress = progress
        self.receivedBytes = receivedBytes
        self.totalBytes = totalBytes
        self.filePath = filePath
        self.error = error
    }
}

/// Canonical series grouping of offline download tasks (strictly isolated from private sources).
public struct DownloadSeriesGroup: Equatable, Hashable, Identifiable, Sendable {
    public let id: String
    public let canonicalTitle: String
    public let displayTitle: String
    public let poster: String
    public let isPrivate: Bool
    public let allowExternalPosterScrape: Bool
    public let tasks: [DownloadTask]

    public var completedCount: Int {
        tasks.filter { $0.status == .completed }.count
    }

    public var totalBytes: Int64 {
        tasks.reduce(0) { $0 + max($1.receivedBytes, $1.totalBytes) }
    }

    public init(
        id: String,
        canonicalTitle: String,
        displayTitle: String,
        poster: String,
        isPrivate: Bool,
        tasks: [DownloadTask]
    ) {
        self.id = id
        self.canonicalTitle = canonicalTitle
        self.displayTitle = displayTitle
        self.poster = isPrivate ? "" : poster
        self.isPrivate = isPrivate
        self.allowExternalPosterScrape = !isPrivate
        self.tasks = tasks
    }
}

private struct HlsParsedSegment {
    let index: Int
    let url: URL
    let duration: Double
    let keyMethod: String
    let keyUri: URL?
    let keyIvHex: String?
    let mapUri: URL?
    let discontinuity: Bool
}

private struct HlsParsedPlaylist {
    let targetDuration: Int
    let mediaSequence: Int
    let segments: [HlsParsedSegment]
}

private struct HlsMasterSelection {
    let videoUrl: URL
    let bandwidth: Int
    let audioUrl: URL?
    let audioName: String
    let audioLanguage: String
}

/// Offline HLS (`.m3u8` + `CommonCrypto` `AES-128-CBC` decryption + separate-audio
/// `#EXT-X-MEDIA:TYPE=AUDIO` offline bundles) and resumable Range MP4/MKV download manager.
///
/// Security invariants:
/// - **Hard privacy source isolation**: refuses and rejects any download where `task.isPrivate == true`
///   or `sourceSite.isEffectivelyPrivate == true`. Private sources are never queued, persisted, or downloaded.
/// - Rejects `SAMPLE-AES` / DRM-encrypted HLS streams cleanly.
/// - Atomic `.part` -> final rename and atomic `marco_downloads.json` persistence.
public actor DownloadManager {
    public static let privacyBlockedMessage = "隐私空间来源禁止离线下载到本地"
    public static let manifestFileName = "marco_downloads.json"

    private let storage: IOSStorageManager
    private let downloadsDirectory: URL
    private let session: URLSession
    private let maxConcurrentTasks: Int
    private var activeTasks: [String: Task<Void, Never>] = [:]
    private var onProgress: (@Sendable (DownloadProgressEvent) -> Void)?

    public init(
        storage: IOSStorageManager,
        downloadsDirectory: URL? = nil,
        session: URLSession? = nil,
        maxConcurrentTasks: Int = 2,
        onProgress: (@Sendable (DownloadProgressEvent) -> Void)? = nil
    ) {
        self.storage = storage
        if let dir = downloadsDirectory {
            self.downloadsDirectory = dir
        } else {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
                ?? storage.storageDirectory
            self.downloadsDirectory = docs.appendingPathComponent("MarcoDownloads", isDirectory: true)
        }
        if let session = session {
            self.session = session
        } else {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = 30
            cfg.timeoutIntervalForResource = 300
            cfg.httpShouldSetCookies = false
            self.session = URLSession(configuration: cfg)
        }
        self.maxConcurrentTasks = max(1, min(maxConcurrentTasks, 4))
        self.onProgress = onProgress
        try? FileManager.default.createDirectory(at: self.downloadsDirectory, withIntermediateDirectories: true)
    }

    public func setProgressHandler(_ handler: (@Sendable (DownloadProgressEvent) -> Void)?) {
        self.onProgress = handler
    }

    public static func isTaskPrivate(_ task: DownloadTask, site: CmsSite? = nil) -> Bool {
        if task.isPrivate { return true }
        if task.sourceSite?.isEffectivelyPrivate == true { return true }
        if site?.isEffectivelyPrivate == true { return true }
        return false
    }

    public func allTasks(includePrivate: Bool = false) -> [DownloadTask] {
        let all = storage.downloadTasks()
        return includePrivate ? all : all.filter { !Self.isTaskPrivate($0) }
    }

    /// Groups offline tasks by canonical series title with strict privacy isolation
    /// (private tasks are excluded by default and NEVER allowed to trigger external poster scraping).
    public func groupedTasks(includePrivate: Bool = false) -> [DownloadSeriesGroup] {
        Self.groupTasks(allTasks(includePrivate: includePrivate), includePrivate: includePrivate)
    }

    public static func groupTasks(_ tasks: [DownloadTask], includePrivate: Bool = false) -> [DownloadSeriesGroup] {
        let filtered = includePrivate ? tasks : tasks.filter { !isTaskPrivate($0) }
        var order: [String] = []
        var buckets: [String: [DownloadTask]] = [:]

        for task in filtered {
            let priv = isTaskPrivate(task)
            let cleaned = EpisodeScraperService.cleanSeriesTitle(task.title)
            let canonical = (cleaned.isEmpty ? task.title : cleaned)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let groupKey = priv ? "private:\(task.siteKey):\(task.videoId):\(canonical)" : "public:\(canonical)"
            if buckets[groupKey] == nil {
                order.append(groupKey)
            }
            buckets[groupKey, default: []].append(task)
        }

        return order.compactMap { key in
            guard let items = buckets[key], !items.isEmpty else { return nil }
            let sortedItems = items.sorted { lhs, rhs in
                if lhs.episodeIndex != rhs.episodeIndex { return lhs.episodeIndex < rhs.episodeIndex }
                return lhs.createdAt < rhs.createdAt
            }
            let first = sortedItems[0]
            let priv = sortedItems.contains { isTaskPrivate($0) }
            let cleaned = EpisodeScraperService.cleanSeriesTitle(first.title)
            let display = cleaned.isEmpty ? first.title : cleaned
            let poster = priv ? "" : (sortedItems.first(where: { !$0.poster.isEmpty })?.poster ?? "")
            return DownloadSeriesGroup(
                id: key,
                canonicalTitle: display.lowercased(),
                displayTitle: display,
                poster: poster,
                isPrivate: priv,
                tasks: sortedItems
            )
        }
    }

    /// Preserved non-throwing enqueue signature for UI backward compatibility.
    /// Hard privacy isolation: strictly refuses private tasks without persisting or scheduling them.
    @discardableResult
    public func enqueue(_ task: DownloadTask) -> DownloadTask {
        if Self.isTaskPrivate(task) {
            var rejected = task
            rejected.status = .failed
            rejected.error = Self.privacyBlockedMessage
            rejected.isPrivate = true
            emitProgress(for: rejected)
            return rejected
        }
        return enqueuePublicUnchecked(task)
    }

    /// Strict throwing enqueue enforcing hard privacy source isolation (`isPrivate == true` or
    /// `site.isEffectivelyPrivate == true` throws `MarcoError.unsupported`).
    @discardableResult
    public func enqueueValidated(_ task: DownloadTask, site: CmsSite? = nil) throws -> DownloadTask {
        guard !Self.isTaskPrivate(task, site: site) else {
            throw MarcoError.unsupported(Self.privacyBlockedMessage)
        }
        return enqueuePublicUnchecked(task)
    }

    private func enqueuePublicUnchecked(_ task: DownloadTask) -> DownloadTask {
        var tasks = storage.downloadTasks()
        if let existing = tasks.first(where: { $0.id == task.id }) {
            if existing.status == .paused || existing.status == .failed {
                resume(taskId: existing.id)
            }
            return existing
        }
        var queued = task
        queued.status = .queued
        queued.error = ""
        tasks.insert(queued, at: 0)
        persistTasks(tasks)
        emitProgress(for: queued)
        scheduleNext()
        return queued
    }

    public func pause(taskId: String) {
        activeTasks.removeValue(forKey: taskId)?.cancel()
        updateTask(id: taskId) { task in
            if task.status == .downloading || task.status == .queued {
                task.status = .paused
            }
        }
        scheduleNext()
    }

    public func resume(taskId: String) {
        updateTask(id: taskId) { task in
            if Self.isTaskPrivate(task) {
                task.status = .failed
                task.error = Self.privacyBlockedMessage
                return
            }
            if task.status == .paused || task.status == .failed {
                task.status = .queued
                task.error = ""
            }
        }
        scheduleNext()
    }

    public func delete(taskId: String, removeFiles: Bool = true) {
        activeTasks.removeValue(forKey: taskId)?.cancel()
        var tasks = storage.downloadTasks()
        if let idx = tasks.firstIndex(where: { $0.id == taskId }) {
            let removed = tasks.remove(at: idx)
            persistTasks(tasks)
            if removeFiles {
                if !removed.filePath.isEmpty {
                    let target = URL(fileURLWithPath: removed.filePath)
                    if target.pathExtension.lowercased() == "m3u8" {
                        try? FileManager.default.removeItem(at: target.deletingLastPathComponent())
                    } else {
                        try? FileManager.default.removeItem(at: target)
                    }
                }
                let dir = taskDirectory(for: taskId)
                try? FileManager.default.removeItem(at: dir)
            }
        }
        scheduleNext()
    }

    public func cancelAll() {
        for (_, t) in activeTasks { t.cancel() }
        activeTasks.removeAll()
        var tasks = storage.downloadTasks()
        var changed = false
        for idx in tasks.indices where tasks[idx].status == .downloading || tasks[idx].status == .queued {
            tasks[idx].status = .paused
            changed = true
        }
        if changed { persistTasks(tasks) }
    }

    /// Waits for a specific task to leave `.queued`/`.downloading` (useful in deterministic tests).
    public func waitUntilFinished(taskId: String) async {
        if let running = activeTasks[taskId] {
            await running.value
        }
    }

    // MARK: - AES-128-CBC Crypto Helpers (CommonCrypto)

    public static func deriveHlsIv(explicitHex: String?, mediaSequence: Int) -> Data {
        if let rawHex = explicitHex?.trimmingCharacters(in: .whitespacesAndNewlines), !rawHex.isEmpty {
            let cleaned = rawHex.lowercased().hasPrefix("0x") ? String(rawHex.dropFirst(2)) : rawHex
            let padded = cleaned.count < 32 ? String(repeating: "0", count: 32 - cleaned.count) + cleaned : String(cleaned.suffix(32))
            if let decoded = hexDecode(padded), decoded.count == kCCBlockSizeAES128 {
                return decoded
            }
        }
        var iv = [UInt8](repeating: 0, count: kCCBlockSizeAES128)
        let seq = UInt64(max(0, mediaSequence))
        for i in 0..<8 {
            iv[15 - i] = UInt8((seq >> (i * 8)) & 0xFF)
        }
        return Data(iv)
    }

    public static func decryptAes128Cbc(data: Data, key: Data, iv: Data) throws -> Data {
        guard key.count == kCCKeySizeAES128, iv.count == kCCBlockSizeAES128 else {
            throw MarcoError.invalidFormat("HLS AES-128 密钥或 IV 长度无效")
        }
        guard !data.isEmpty, data.count % kCCBlockSizeAES128 == 0 else {
            throw MarcoError.invalidFormat("AES-128 加密分片长度不是 16 字节对齐")
        }
        let outCapacity = data.count + kCCBlockSizeAES128
        var outBytes = [UInt8](repeating: 0, count: outCapacity)
        var outLength: size_t = 0

        let status: CCCryptorStatus = data.withUnsafeBytes { dataPtr in
            key.withUnsafeBytes { keyPtr in
                iv.withUnsafeBytes { ivPtr in
                    CCCrypt(
                        CCOperation(kCCDecrypt),
                        CCAlgorithm(kCCAlgorithmAES128),
                        CCOptions(kCCOptionPKCS7Padding),
                        keyPtr.baseAddress,
                        kCCKeySizeAES128,
                        ivPtr.baseAddress,
                        dataPtr.baseAddress,
                        data.count,
                        &outBytes,
                        outCapacity,
                        &outLength
                    )
                }
            }
        }
        guard status == kCCSuccess else {
            throw MarcoError.invalidFormat("HLS AES-128-CBC 分片解密失败 (status=\(status))")
        }
        return Data(outBytes.prefix(outLength))
    }

    public static func encryptAes128Cbc(data: Data, key: Data, iv: Data) throws -> Data {
        guard key.count == kCCKeySizeAES128, iv.count == kCCBlockSizeAES128 else {
            throw MarcoError.invalidFormat("AES-128 密钥或 IV 长度无效")
        }
        let outCapacity = data.count + kCCBlockSizeAES128
        var outBytes = [UInt8](repeating: 0, count: outCapacity)
        var outLength: size_t = 0

        let status: CCCryptorStatus = data.withUnsafeBytes { dataPtr in
            key.withUnsafeBytes { keyPtr in
                iv.withUnsafeBytes { ivPtr in
                    CCCrypt(
                        CCOperation(kCCEncrypt),
                        CCAlgorithm(kCCAlgorithmAES128),
                        CCOptions(kCCOptionPKCS7Padding),
                        keyPtr.baseAddress,
                        kCCKeySizeAES128,
                        ivPtr.baseAddress,
                        dataPtr.baseAddress,
                        data.count,
                        &outBytes,
                        outCapacity,
                        &outLength
                    )
                }
            }
        }
        guard status == kCCSuccess else {
            throw MarcoError.invalidFormat("AES-128-CBC 加密失败 (status=\(status))")
        }
        return Data(outBytes.prefix(outLength))
    }

    // MARK: - Scheduling & Execution

    private func scheduleNext() {
        while activeTasks.count < maxConcurrentTasks {
            let tasks = storage.downloadTasks()
            guard let next = tasks.first(where: { $0.status == .queued && activeTasks[$0.id] == nil }) else {
                break
            }
            if Self.isTaskPrivate(next) {
                failTask(id: next.id, message: Self.privacyBlockedMessage)
                continue
            }
            let id = next.id
            updateTask(id: id) { $0.status = .downloading; $0.error = "" }
            let runner = Task { [weak self] in
                guard let self = self else { return }
                await self.executeDownload(taskId: id)
            }
            activeTasks[id] = runner
        }
    }

    private func executeDownload(taskId: String) async {
        defer {
            activeTasks.removeValue(forKey: taskId)
            scheduleNext()
        }
        guard let task = storage.downloadTasks().first(where: { $0.id == taskId }) else { return }
        if Self.isTaskPrivate(task) {
            failTask(id: taskId, message: Self.privacyBlockedMessage)
            return
        }
        guard let sourceUrl = URL(string: CmsParser.normalizeUrl(task.sourceUrl)),
              let scheme = sourceUrl.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else {
            failTask(id: taskId, message: "无效的下载地址")
            return
        }

        do {
            try FileManager.default.createDirectory(at: downloadsDirectory, withIntermediateDirectories: true)
            let isHls = sourceUrl.path.lowercased().hasSuffix(".m3u8")
                || task.sourceUrl.lowercased().contains(".m3u8")

            if isHls {
                try await downloadHls(task: task, manifestUrl: sourceUrl)
            } else {
                try await downloadDirectFile(task: task, mediaUrl: sourceUrl)
            }
        } catch is CancellationError {
            updateTask(id: taskId) { t in
                if t.status == .downloading { t.status = .paused }
            }
        } catch {
            failTask(id: taskId, message: error.localizedDescription)
        }
    }

    // MARK: - Direct File Resumable Range Download (`.part` -> Atomic Rename)

    private func downloadDirectFile(task: DownloadTask, mediaUrl: URL) async throws {
        let dir = taskDirectory(for: task.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ext = mediaUrl.pathExtension.isEmpty ? "mp4" : mediaUrl.pathExtension.lowercased()
        let baseName = sanitizedBaseName(for: task)
        let destUrl = dir.appendingPathComponent("\(baseName).\(ext)")
        let partUrl = dir.appendingPathComponent("\(baseName).\(ext).part")

        var existingBytes: Int64 = 0
        if FileManager.default.fileExists(atPath: partUrl.path),
           let attrs = try? FileManager.default.attributesOfItem(atPath: partUrl.path),
           let size = (attrs[.size] as? NSNumber)?.int64Value
        {
            existingBytes = size
        }

        var req = URLRequest(url: mediaUrl, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        req.httpMethod = "GET"
        req.setValue(CmsClient.defaultSafariUserAgent, forHTTPHeaderField: "User-Agent")
        for (k, v) in task.headers { req.setValue(v, forHTTPHeaderField: k) }
        if existingBytes > 0 {
            req.setValue("bytes=\(existingBytes)-", forHTTPHeaderField: "Range")
        }

        let (data, resp) = try await session.marcoData(for: req)
        try Task.checkCancellation()
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            throw MarcoError.networkFailure("下载请求失败 (HTTP \(code))")
        }

        if http.statusCode == 206 && existingBytes > 0 {
            let fh = try FileHandle(forWritingTo: partUrl)
            defer { try? fh.close() }
            _ = try fh.seekToEnd()
            try fh.write(contentsOf: data)
        } else {
            try data.write(to: partUrl, options: [.atomic])
        }

        if FileManager.default.fileExists(atPath: destUrl.path) {
            try? FileManager.default.removeItem(at: destUrl)
        }
        try FileManager.default.moveItem(at: partUrl, to: destUrl)

        let finalSize: Int64 = ((try? FileManager.default.attributesOfItem(atPath: destUrl.path))?[.size] as? NSNumber)?.int64Value ?? Int64(data.count)
        updateTask(id: task.id) { t in
            t.status = .completed
            t.progress = 1.0
            t.receivedBytes = finalSize
            t.totalBytes = finalSize
            t.filePath = destUrl.path
            t.error = ""
        }
    }

    // MARK: - HLS Download (AES-128-CBC Decryption & Separate-Audio Bundles)

    private func downloadHls(task: DownloadTask, manifestUrl: URL) async throws {
        let dir = taskDirectory(for: task.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let baseName = sanitizedBaseName(for: task)

        let rootText = try await fetchText(url: manifestUrl, headers: task.headers)
        var videoPlaylistUrl = manifestUrl
        var videoManifestText = rootText
        var audioSelection: HlsMasterSelection?

        if rootText.contains("#EXT-X-STREAM-INF") {
            let selected = selectBestMasterVariant(rootText, baseUrl: manifestUrl)
            videoPlaylistUrl = selected.videoUrl
            videoManifestText = try await fetchText(url: videoPlaylistUrl, headers: task.headers)
            if selected.audioUrl != nil {
                audioSelection = selected
            }
        }

        let videoPlaylist = try parseMediaPlaylist(videoManifestText, baseUrl: videoPlaylistUrl, isAudio: false)
        guard !videoPlaylist.segments.isEmpty else {
            throw MarcoError.invalidFormat("HLS 清单中未包含有效媒体分片")
        }

        var keyCache: [String: Data] = [:]

        if let audioSel = audioSelection, let audioPlaylistUrl = audioSel.audioUrl {
            let audioManifestText = try await fetchText(url: audioPlaylistUrl, headers: task.headers)
            let audioPlaylist = try parseMediaPlaylist(audioManifestText, baseUrl: audioPlaylistUrl, isAudio: true)
            guard !audioPlaylist.segments.isEmpty else {
                throw MarcoError.invalidFormat("独立音轨清单中未包含有效分片")
            }

            let hlsDir = dir.appendingPathComponent("hls", isDirectory: true)
            try FileManager.default.createDirectory(at: hlsDir, withIntermediateDirectories: true)

            let totalSegCount = videoPlaylist.segments.count + audioPlaylist.segments.count
            var completedSegs = 0
            var totalReceived: Int64 = 0

            let videoLocal = try await downloadHlsTrackSegments(
                playlist: videoPlaylist,
                outputDir: hlsDir,
                prefix: "v",
                headers: task.headers,
                keyCache: &keyCache
            ) { bytesDelta in
                completedSegs += 1
                totalReceived += bytesDelta
                let prog = min(0.98, Double(completedSegs) / Double(max(1, totalSegCount)))
                self.updateTask(id: task.id) { t in
                    t.progress = prog
                    t.receivedBytes = totalReceived
                    t.totalBytes = Int64(Double(totalReceived) / max(prog, 0.01))
                }
            }

            let audioLocal = try await downloadHlsTrackSegments(
                playlist: audioPlaylist,
                outputDir: hlsDir,
                prefix: "a",
                headers: task.headers,
                keyCache: &keyCache
            ) { bytesDelta in
                completedSegs += 1
                totalReceived += bytesDelta
                let prog = min(0.98, Double(completedSegs) / Double(max(1, totalSegCount)))
                self.updateTask(id: task.id) { t in
                    t.progress = prog
                    t.receivedBytes = totalReceived
                    t.totalBytes = Int64(Double(totalReceived) / max(prog, 0.01))
                }
            }

            try Data(videoLocal.utf8).write(to: hlsDir.appendingPathComponent("video.m3u8"), options: [.atomic])
            try Data(audioLocal.utf8).write(to: hlsDir.appendingPathComponent("audio.m3u8"), options: [.atomic])

            let safeAudioName = audioSel.audioName.replacingOccurrences(of: "\"", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            let displayAudioName = safeAudioName.isEmpty ? "Default" : safeAudioName
            let safeLang = audioSel.audioLanguage.replacingOccurrences(of: "\"", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            let langAttr = safeLang.isEmpty ? "" : ",LANGUAGE=\"\(safeLang)\""
            let hasMap = videoPlaylist.segments.contains { $0.mapUri != nil } || audioPlaylist.segments.contains { $0.mapUri != nil }
            let masterText = [
                "#EXTM3U",
                "#EXT-X-VERSION:\(hasMap ? 7 : 3)",
                "#EXT-X-INDEPENDENT-SEGMENTS",
                "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"audio\",NAME=\"\(displayAudioName)\"\(langAttr),DEFAULT=YES,AUTOSELECT=YES,URI=\"hls/audio.m3u8\"",
                "#EXT-X-STREAM-INF:BANDWIDTH=\(max(audioSel.bandwidth, 2_000_000)),AUDIO=\"audio\"",
                "hls/video.m3u8",
                "",
            ].joined(separator: "\n")

            let masterUrl = dir.appendingPathComponent("\(baseName).m3u8")
            try Data(masterText.utf8).write(to: masterUrl, options: [.atomic])
            updateTask(id: task.id) { t in
                t.status = .completed
                t.progress = 1.0
                t.receivedBytes = totalReceived
                t.totalBytes = totalReceived
                t.filePath = masterUrl.path
                t.error = ""
            }
            return
        }

        // Muxed HLS track (decrypted AES-128-CBC segments + clean offline playlist)
        var completedSegs = 0
        var totalReceived: Int64 = 0
        let totalSegCount = videoPlaylist.segments.count
        let localPlaylistText = try await downloadHlsTrackSegments(
            playlist: videoPlaylist,
            outputDir: dir,
            prefix: "seg",
            headers: task.headers,
            keyCache: &keyCache
        ) { bytesDelta in
            completedSegs += 1
            totalReceived += bytesDelta
            let prog = min(0.99, Double(completedSegs) / Double(max(1, totalSegCount)))
            self.updateTask(id: task.id) { t in
                t.progress = prog
                t.receivedBytes = totalReceived
                t.totalBytes = Int64(Double(totalReceived) / max(prog, 0.01))
            }
        }

        let masterUrl = dir.appendingPathComponent("\(baseName).m3u8")
        try Data(localPlaylistText.utf8).write(to: masterUrl, options: [.atomic])
        updateTask(id: task.id) { t in
            t.status = .completed
            t.progress = 1.0
            t.receivedBytes = totalReceived
            t.totalBytes = totalReceived
            t.filePath = masterUrl.path
            t.error = ""
        }
    }

    private func downloadHlsTrackSegments(
        playlist: HlsParsedPlaylist,
        outputDir: URL,
        prefix: String,
        headers: [String: String],
        keyCache: inout [String: Data],
        onSegmentDone: (Int64) -> Void
    ) async throws -> String {
        var mapLocalNames: [String: String] = [:]
        var activeMapKey: String?
        let hasMap = playlist.segments.contains { $0.mapUri != nil }

        var lines: [String] = [
            "#EXTM3U",
            "#EXT-X-VERSION:\(hasMap ? 7 : 3)",
            "#EXT-X-TARGETDURATION:\(max(1, playlist.targetDuration))",
            "#EXT-X-MEDIA-SEQUENCE:0",
            "#EXT-X-PLAYLIST-TYPE:VOD",
        ]

        for seg in playlist.segments {
            try Task.checkCancellation()
            if let mapUrl = seg.mapUri {
                let mapKey = mapUrl.absoluteString
                let localMapName: String
                if let existing = mapLocalNames[mapKey] {
                    localMapName = existing
                } else {
                    localMapName = "\(prefix)_init_\(mapLocalNames.count).mp4"
                    let mapDest = outputDir.appendingPathComponent(localMapName)
                    if !FileManager.default.fileExists(atPath: mapDest.path) {
                        let mapBytes = try await fetchData(url: mapUrl, headers: headers)
                        try mapBytes.write(to: mapDest, options: [.atomic])
                    }
                    mapLocalNames[mapKey] = localMapName
                }
                if activeMapKey != mapKey {
                    lines.append("#EXT-X-MAP:URI=\"\(localMapName)\"")
                    activeMapKey = mapKey
                }
            }

            let segExt = inferSegmentExtension(url: seg.url, hasMap: hasMap)
            let localName = String(format: "%@_%05d%@", prefix, seg.index, segExt)
            let segDest = outputDir.appendingPathComponent(localName)
            let segPart = outputDir.appendingPathComponent("\(localName).part")

            let writtenBytes: Int64
            if FileManager.default.fileExists(atPath: segDest.path),
               let attrs = try? FileManager.default.attributesOfItem(atPath: segDest.path),
               let sz = (attrs[.size] as? NSNumber)?.int64Value, sz > 0
            {
                writtenBytes = sz
            } else {
                var bytes = try await fetchData(url: seg.url, headers: headers)
                if seg.keyMethod == "AES-128", let keyUrl = seg.keyUri {
                    let keyData: Data
                    if let cached = keyCache[keyUrl.absoluteString] {
                        keyData = cached
                    } else {
                        let fetchedKey = try await fetchData(url: keyUrl, headers: headers)
                        guard fetchedKey.count == kCCKeySizeAES128 else {
                            throw MarcoError.invalidFormat("HLS AES-128 密钥长度无效（预期 16 字节）")
                        }
                        keyCache[keyUrl.absoluteString] = fetchedKey
                        keyData = fetchedKey
                    }
                    let iv = Self.deriveHlsIv(
                        explicitHex: seg.keyIvHex,
                        mediaSequence: playlist.mediaSequence + seg.index
                    )
                    bytes = try Self.decryptAes128Cbc(data: bytes, key: keyData, iv: iv)
                }

                let tsOff = LocalHeaderProxyServer.findDisguisedTsOffset(bytes)
                if tsOff > 0 && tsOff < bytes.count {
                    bytes = bytes.subdata(in: tsOff..<bytes.count)
                }
                try bytes.write(to: segPart, options: [.atomic])
                if FileManager.default.fileExists(atPath: segDest.path) {
                    try? FileManager.default.removeItem(at: segDest)
                }
                try FileManager.default.moveItem(at: segPart, to: segDest)
                writtenBytes = Int64(bytes.count)
            }

            if seg.discontinuity {
                lines.append("#EXT-X-DISCONTINUITY")
            }
            let dur = seg.duration > 0 ? seg.duration : 4.0
            lines.append(String(format: "#EXTINF:%.3f,", dur))
            lines.append(localName)
            onSegmentDone(writtenBytes)
        }
        lines.append("#EXT-X-ENDLIST")
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private func selectBestMasterVariant(_ masterText: String, baseUrl: URL) -> HlsMasterSelection {
        struct AudioRendition {
            let groupId: String
            let name: String
            let language: String
            let url: URL?
            let isDefault: Bool
            let autoselect: Bool
        }

        let lines = masterText.components(separatedBy: .newlines)
        var audioGroups: [String: [AudioRendition]] = [:]

        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.uppercased().hasPrefix("#EXT-X-MEDIA:") else { continue }
            let attrs = parseHlsAttributes(String(line.dropFirst("#EXT-X-MEDIA:".count)))
            guard (attrs["TYPE"] ?? "").uppercased() == "AUDIO",
                  let groupId = attrs["GROUP-ID"], !groupId.isEmpty
            else { continue }
            let uriStr = attrs["URI"] ?? ""
            let resolvedUri: URL? = uriStr.isEmpty
                ? nil
                : URL(string: CmsParser.resolveUrl(base: baseUrl.absoluteString, relative: uriStr))
            let rendition = AudioRendition(
                groupId: groupId,
                name: attrs["NAME"] ?? "Default",
                language: attrs["LANGUAGE"] ?? "",
                url: resolvedUri,
                isDefault: (attrs["DEFAULT"] ?? "").uppercased() == "YES",
                autoselect: (attrs["AUTOSELECT"] ?? "").uppercased() == "YES"
            )
            audioGroups[groupId, default: []].append(rendition)
        }

        var bestBw = -1
        var bestVariantUrl = baseUrl
        var bestAudioGroup: String?
        var pendingBw = 0
        var pendingAudioGroup: String?
        var expectUri = false

        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.uppercased().hasPrefix("#EXT-X-STREAM-INF:") {
                let attrs = parseHlsAttributes(String(line.dropFirst("#EXT-X-STREAM-INF:".count)))
                pendingBw = Int(attrs["BANDWIDTH"] ?? "") ?? 0
                pendingAudioGroup = attrs["AUDIO"]
                expectUri = true
            } else if expectUri && !line.isEmpty && !line.hasPrefix("#") {
                expectUri = false
                if pendingBw >= bestBw,
                   let resolved = URL(string: CmsParser.resolveUrl(base: baseUrl.absoluteString, relative: line))
                {
                    bestBw = pendingBw
                    bestVariantUrl = resolved
                    bestAudioGroup = pendingAudioGroup
                }
            }
        }

        var chosenAudioUrl: URL?
        var chosenAudioName = "Default"
        var chosenAudioLang = ""
        if let grp = bestAudioGroup, let candidates = audioGroups[grp], !candidates.isEmpty {
            let picked = candidates.first(where: { $0.isDefault && $0.url != nil })
                ?? candidates.first(where: { $0.autoselect && $0.url != nil })
                ?? candidates.first(where: { $0.url != nil })
            if let picked = picked {
                chosenAudioUrl = picked.url
                chosenAudioName = picked.name
                chosenAudioLang = picked.language
            }
        }

        return HlsMasterSelection(
            videoUrl: bestVariantUrl,
            bandwidth: max(0, bestBw),
            audioUrl: chosenAudioUrl,
            audioName: chosenAudioName,
            audioLanguage: chosenAudioLang
        )
    }

    private func parseMediaPlaylist(_ text: String, baseUrl: URL, isAudio: Bool) throws -> HlsParsedPlaylist {
        let lines = text.components(separatedBy: .newlines)
        var targetDuration = 6
        var mediaSequence = 0
        var currentKeyMethod = "NONE"
        var currentKeyUri: URL?
        var currentKeyIv: String?
        var currentMapUri: URL?
        var pendingDuration = 4.0
        var pendingDiscontinuity = false
        var segments: [HlsParsedSegment] = []

        for raw in lines {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let upper = trimmed.uppercased()

            if upper.hasPrefix("#EXT-X-TARGETDURATION:") {
                let val = String(trimmed.dropFirst("#EXT-X-TARGETDURATION:".count)).trimmingCharacters(in: .whitespaces)
                targetDuration = max(1, Int(Double(val) ?? 6))
                continue
            }
            if upper.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                let val = String(trimmed.dropFirst("#EXT-X-MEDIA-SEQUENCE:".count)).trimmingCharacters(in: .whitespaces)
                mediaSequence = max(0, Int(val) ?? 0)
                continue
            }
            if upper.hasPrefix("#EXT-X-KEY:") {
                let attrs = parseHlsAttributes(String(trimmed.dropFirst("#EXT-X-KEY:".count)))
                let method = (attrs["METHOD"] ?? "NONE").uppercased()
                if method != "NONE" && method != "AES-128" {
                    let msg = isAudio
                        ? "独立音轨使用 SAMPLE-AES 等专有加密，暂不支持下载"
                        : "该视频使用 SAMPLE-AES 等专有加密，暂不支持下载"
                    throw MarcoError.unsupported(msg)
                }
                currentKeyMethod = method
                if method == "AES-128", let rawUri = attrs["URI"], !rawUri.isEmpty {
                    currentKeyUri = URL(string: CmsParser.resolveUrl(base: baseUrl.absoluteString, relative: rawUri))
                    currentKeyIv = attrs["IV"]
                } else {
                    currentKeyUri = nil
                    currentKeyIv = nil
                }
                continue
            }
            if upper.hasPrefix("#EXT-X-MAP:") {
                let attrs = parseHlsAttributes(String(trimmed.dropFirst("#EXT-X-MAP:".count)))
                if let rawUri = attrs["URI"], !rawUri.isEmpty {
                    currentMapUri = URL(string: CmsParser.resolveUrl(base: baseUrl.absoluteString, relative: rawUri))
                }
                continue
            }
            if upper == "#EXT-X-DISCONTINUITY" {
                pendingDiscontinuity = true
                continue
            }
            if upper.hasPrefix("#EXTINF:") {
                let body = String(trimmed.dropFirst("#EXTINF:".count))
                let durPart = body.components(separatedBy: ",").first?.trimmingCharacters(in: .whitespaces) ?? ""
                pendingDuration = Double(durPart) ?? 4.0
                continue
            }
            if trimmed.hasPrefix("#") { continue }

            let absStr = CmsParser.resolveUrl(base: baseUrl.absoluteString, relative: trimmed)
            guard let segUrl = URL(string: absStr) else { continue }
            segments.append(
                HlsParsedSegment(
                    index: segments.count,
                    url: segUrl,
                    duration: pendingDuration,
                    keyMethod: currentKeyMethod,
                    keyUri: currentKeyUri,
                    keyIvHex: currentKeyIv,
                    mapUri: currentMapUri,
                    discontinuity: pendingDiscontinuity
                )
            )
            pendingDuration = 4.0
            pendingDiscontinuity = false
        }

        return HlsParsedPlaylist(
            targetDuration: targetDuration,
            mediaSequence: mediaSequence,
            segments: segments
        )
    }

    private func parseHlsAttributes(_ raw: String) -> [String: String] {
        var out: [String: String] = [:]
        var idx = raw.startIndex
        while idx < raw.endIndex {
            while idx < raw.endIndex && (raw[idx] == "," || raw[idx] == " " || raw[idx] == "\t") {
                idx = raw.index(after: idx)
            }
            guard idx < raw.endIndex else { break }
            let keyStart = idx
            while idx < raw.endIndex && raw[idx] != "=" && raw[idx] != "," {
                idx = raw.index(after: idx)
            }
            let key = String(raw[keyStart..<idx]).trimmingCharacters(in: .whitespaces).uppercased()
            guard idx < raw.endIndex && raw[idx] == "=" else { continue }
            idx = raw.index(after: idx)
            guard idx < raw.endIndex else { break }
            let value: String
            if raw[idx] == "\"" {
                idx = raw.index(after: idx)
                let valStart = idx
                while idx < raw.endIndex && raw[idx] != "\"" {
                    idx = raw.index(after: idx)
                }
                value = String(raw[valStart..<idx])
                if idx < raw.endIndex { idx = raw.index(after: idx) }
            } else {
                let valStart = idx
                while idx < raw.endIndex && raw[idx] != "," {
                    idx = raw.index(after: idx)
                }
                value = String(raw[valStart..<idx]).trimmingCharacters(in: .whitespaces)
            }
            if !key.isEmpty { out[key] = value }
        }
        return out
    }

    private func inferSegmentExtension(url: URL, hasMap: Bool) -> String {
        let ext = url.pathExtension.lowercased()
        if ["ts", "m4s", "mp4", "aac", "m4a"].contains(ext) {
            return ".\(ext)"
        }
        return hasMap ? ".m4s" : ".ts"
    }

    // MARK: - HTTP & Persistence Helpers

    private func fetchData(url: URL, headers: [String: String]) async throws -> Data {
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        req.httpMethod = "GET"
        req.setValue(CmsClient.defaultSafariUserAgent, forHTTPHeaderField: "User-Agent")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let (data, resp) = try await session.marcoData(for: req)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw MarcoError.networkFailure("分片下载失败 (HTTP \(http.statusCode))")
        }
        return data
    }

    private func fetchText(url: URL, headers: [String: String]) async throws -> String {
        let data = try await fetchData(url: url, headers: headers)
        return String(decoding: data, as: UTF8.self)
    }

    private func taskDirectory(for taskId: String) -> URL {
        let safe = SHA256.hash(data: Data(taskId.utf8)).map { String(format: "%02x", $0) }.joined().prefix(24)
        return downloadsDirectory.appendingPathComponent("dl_\(safe)", isDirectory: true)
    }

    private func sanitizedBaseName(for task: DownloadTask) -> String {
        let raw = "\(task.title)_\(task.episodeName)"
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        let cleaned = raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let s = String(cleaned).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        if s.isEmpty { return "video" }
        return String(s.prefix(48))
    }

    private func persistTasks(_ tasks: [DownloadTask]) {
        let publicTasks = tasks.filter { !Self.isTaskPrivate($0) }
        storage.saveDownloadTasks(publicTasks)
        do {
            try FileManager.default.createDirectory(at: downloadsDirectory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(publicTasks)
            let manifestUrl = downloadsDirectory.appendingPathComponent(Self.manifestFileName)
            try data.write(to: manifestUrl, options: [.atomic])
        } catch {}
    }

    private func updateTask(id: String, mutate: (inout DownloadTask) -> Void) {
        var tasks = storage.downloadTasks()
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        mutate(&tasks[idx])
        let updated = tasks[idx]
        persistTasks(tasks)
        emitProgress(for: updated)
    }

    private func failTask(id: String, message: String) {
        updateTask(id: id) { t in
            t.status = .failed
            t.error = message
        }
    }

    private func emitProgress(for task: DownloadTask) {
        onProgress?(
            DownloadProgressEvent(
                taskId: task.id,
                status: task.status,
                progress: task.progress,
                receivedBytes: task.receivedBytes,
                totalBytes: task.totalBytes,
                filePath: task.filePath,
                error: task.error
            )
        )
    }

    private static func hexDecode(_ hex: String) -> Data? {
        let chars = Array(hex.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var out = Data(capacity: chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let hi = hexVal(chars[i]), let lo = hexVal(chars[i + 1]) else { return nil }
            out.append((hi << 4) | lo)
            i += 2
        }
        return out
    }

    private static func hexVal(_ b: UInt8) -> UInt8? {
        if b >= 0x30 && b <= 0x39 { return b - 0x30 }
        if b >= 0x41 && b <= 0x46 { return b - 0x41 + 10 }
        if b >= 0x61 && b <= 0x66 { return b - 0x61 + 10 }
        return nil
    }
}
