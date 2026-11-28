// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only

import Combine
import Foundation

/// Immutable identity & playback context for a single VOD episode or Live TV channel/line.
public struct PlaybackTargetDescriptor: Equatable, Hashable, Sendable {
    public var site: CmsSite
    public var video: CmsVideo
    public var lineIndex: Int
    public var episodeIndex: Int
    public var initialSeekMs: Int
    public var isLiveStream: Bool
    public var liveFlatChannels: [LiveChannel]
    public var liveChannelIndex: Int

    public init(
        site: CmsSite,
        video: CmsVideo,
        lineIndex: Int,
        episodeIndex: Int,
        initialSeekMs: Int = 0,
        isLiveStream: Bool = false,
        liveFlatChannels: [LiveChannel] = [],
        liveChannelIndex: Int = 0
    ) {
        self.site = site
        self.video = video
        self.lineIndex = lineIndex
        self.episodeIndex = episodeIndex
        self.initialSeekMs = initialSeekMs
        self.isLiveStream = isLiveStream
        self.liveFlatChannels = liveFlatChannels
        self.liveChannelIndex = liveChannelIndex
    }

    public var currentLine: CmsLine? {
        guard video.lines.indices.contains(lineIndex) else { return nil }
        return video.lines[lineIndex]
    }

    public var currentEpisode: CmsEpisode? {
        guard let line = currentLine, line.episodes.indices.contains(episodeIndex) else { return nil }
        return line.episodes[episodeIndex]
    }

    public var hasAlternativeLines: Bool {
        if isLiveStream {
            return (currentLine?.episodes.count ?? 0) > 1
        }
        return video.lines.count > 1
    }

    public var liveLineCount: Int {
        isLiveStream ? (currentLine?.episodes.count ?? 0) : 0
    }
}

/// Token-scoped playback engine interface binding progress, completion, and failure callbacks
/// strictly to the active playback item so stale callbacks from replaced items are discarded.
@MainActor
public protocol PlaybackEngineAdapterProtocol: AnyObject {
    var activeItemToken: UInt64? { get }
    var hasReadyCurrentItem: Bool { get }
    var currentTimeMs: Int { get }
    var durationMs: Int { get }
    var onProgressTick: ((_ token: UInt64, _ positionMs: Int, _ durationMs: Int) -> Void)? { get set }
    var onPlaybackEnded: ((_ token: UInt64) -> Void)? { get set }
    var onPlaybackFailed: ((_ token: UInt64, _ message: String) -> Void)? { get set }
    func load(token: UInt64, url: URL, initialSeekMs: Int, rate: Float)
    func stopCurrentItem()
    func setPlaybackRate(_ rate: Float)
    func teardown()
}

public extension PlaybackEngineAdapterProtocol {
    var hasReadyCurrentItem: Bool {
        activeItemToken != nil
    }
}

public typealias PlaybackStreamResolver = @Sendable (
    _ descriptor: PlaybackTargetDescriptor
) async throws -> ResolvedPlayback

public typealias PlaybackResourceReleaser = @Sendable (
    _ resolved: ResolvedPlayback
) async -> Void

public typealias PlaybackProgressRecorder = @MainActor (
    _ descriptor: PlaybackTargetDescriptor,
    _ positionMs: Int,
    _ durationMs: Int
) -> Void

public struct VodLineSwitchMissingEpisodeInfo: Equatable, Hashable, Sendable {
    public let targetLineIndex: Int
    public let targetLineName: String
    public let requestedEpisodeIndex: Int
    public let requestedEpisodeName: String
    public let availableEpisodeCount: Int
    public let carrySeekMs: Int
    public let fallbackEpisodeName: String

    public init(
        targetLineIndex: Int,
        targetLineName: String,
        requestedEpisodeIndex: Int,
        requestedEpisodeName: String,
        availableEpisodeCount: Int,
        carrySeekMs: Int,
        fallbackEpisodeName: String = ""
    ) {
        self.targetLineIndex = targetLineIndex
        self.targetLineName = targetLineName
        self.requestedEpisodeIndex = requestedEpisodeIndex
        self.requestedEpisodeName = requestedEpisodeName
        self.availableEpisodeCount = availableEpisodeCount
        self.carrySeekMs = carrySeekMs
        self.fallbackEpisodeName = fallbackEpisodeName
    }
}

public enum VodLineSwitchOutcome: Equatable, Sendable {
    case switched(lineIndex: Int, episodeIndex: Int, seekMs: Int)
    case missingEpisode(VodLineSwitchMissingEpisodeInfo)
    case unchanged
    case unavailable(String)
}

/// Deterministic single-active-item playback coordinator for Marco Movie iOS VOD & Live TV.
/// Guarantees:
/// - Stream resolution, player status, progress ticks, end notifications, and item failures are bound to a monotonic `UInt64` item token.
/// - Rapid episode / line / channel switches or player exit cancel previous resolve tasks and drop late responses & callbacks.
/// - Per-session proxy resources (`rangeProxyResourceId` / `headerProxySessionId`) are released strictly for the replaced or exited playback session.
/// - Watch progress is only ever persisted against the actually-playing item (never attributed to a newly selected or resolving item).
/// - Manual & error-overlay VOD line switches share a single current-position policy and verify episode existence before switching.
/// - Outro auto-skip and end-of-item auto-advance trigger at most once per playback item.
/// - Same-channel live line switching keeps the active channel fixed while rotating stream URLs.
@MainActor
public final class PlaybackSessionCoordinator: ObservableObject {
    @Published public private(set) var target: PlaybackTargetDescriptor
    @Published public private(set) var activeLoaded: PlaybackTargetDescriptor?
    @Published public private(set) var isResolving: Bool = true
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var errorIsPlaybackFailure: Bool = false
    @Published public private(set) var activeKernelLabel: String = "AVPlayer 硬解"
    @Published public private(set) var activeResolutionBadge: String = ""

    public var playbackSpeed: Double
    public var skipIntroSec: Int
    public var skipOutroSec: Int
    public var autoNext: Bool
    public var onTargetTransition: (() -> Void)?

    private let engine: PlaybackEngineAdapterProtocol
    private let resolver: PlaybackStreamResolver
    private let resourceReleaser: PlaybackResourceReleaser?
    private let progressRecorder: PlaybackProgressRecorder

    private var nextToken: UInt64 = 0
    private var pendingToken: UInt64?
    private var activeLoadedToken: UInt64?
    private var activeResolvedPlayback: ResolvedPlayback?
    private var lastObservedPositionMs: Int?
    private var autoAdvanceConsumedToken: UInt64?
    private var resolveTask: Task<Void, Never>?
    private var pendingReleaseTasks: [UUID: Task<Void, Never>] = [:]
    private var isTornDown: Bool = false

    public init(
        initialTarget: PlaybackTargetDescriptor,
        engine: PlaybackEngineAdapterProtocol,
        resolver: @escaping PlaybackStreamResolver,
        progressRecorder: @escaping PlaybackProgressRecorder,
        resourceReleaser: PlaybackResourceReleaser? = nil,
        playbackSpeed: Double = 1.0,
        skipIntroSec: Int = 0,
        skipOutroSec: Int = 0,
        autoNext: Bool = true
    ) {
        self.target = initialTarget
        self.engine = engine
        self.resolver = resolver
        self.resourceReleaser = resourceReleaser
        self.progressRecorder = progressRecorder
        self.playbackSpeed = playbackSpeed
        self.skipIntroSec = skipIntroSec
        self.skipOutroSec = skipOutroSec
        self.autoNext = autoNext
        bindEngineCallbacks()
    }

    public func startInitialLoad() {
        guard !isTornDown else { return }
        beginResolveCurrentTarget()
    }

    public func retryCurrent() {
        guard !isTornDown else { return }
        persistActiveProgressIfBound()
        beginResolveCurrentTarget()
    }

    public func switchToEpisode(lineIndex: Int, episodeIndex: Int, seekMs: Int) {
        guard !isTornDown,
              !target.isLiveStream,
              target.video.lines.indices.contains(lineIndex),
              target.video.lines[lineIndex].episodes.indices.contains(episodeIndex)
        else {
            return
        }
        if lineIndex == target.lineIndex
            && episodeIndex == target.episodeIndex
            && errorMessage == nil
            && (isResolving || activeLoaded != nil)
        {
            return
        }

        persistActiveProgressIfBound()
        cancelPendingAndDetachActiveItem()

        var next = target
        next.lineIndex = lineIndex
        next.episodeIndex = episodeIndex
        next.initialSeekMs = seekMs > 0 ? seekMs : (skipIntroSec * 1000)
        target = next
        beginResolveCurrentTarget()
    }

    /// Unified viewing-position policy shared by manual line switch and error-overlay line switch.
    public func resolvedCarrySeekMsForLineSwitch() -> Int {
        if activeLoaded != nil && engine.hasReadyCurrentItem {
            return max(0, engine.currentTimeMs)
        }
        if let observed = lastObservedPositionMs {
            return max(0, observed)
        }
        return max(0, target.initialSeekMs)
    }

    @discardableResult
    public func switchVodLine(to targetLineIndex: Int) -> VodLineSwitchOutcome {
        guard !isTornDown, !target.isLiveStream else {
            return .unavailable("当前非点播会话")
        }
        guard target.video.lines.indices.contains(targetLineIndex) else {
            return .unavailable("目标线路不存在")
        }
        if targetLineIndex == target.lineIndex && errorMessage == nil && (isResolving || activeLoaded != nil) {
            return .unchanged
        }

        let targetLine = target.video.lines[targetLineIndex]
        let carrySeekMs = resolvedCarrySeekMsForLineSwitch()
        let currentEpisode = target.currentEpisode

        guard let matchedEpIndex = Self.matchingEpisodeIndex(
            for: currentEpisode,
            currentIndex: target.episodeIndex,
            sourceEpisodeCount: target.currentLine?.episodes.count ?? 0,
            in: targetLine.episodes
        ) else {
            let requestedName = currentEpisode?.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let fallbackName = (requestedName?.isEmpty == false)
                ? requestedName!
                : "第 \(target.episodeIndex + 1) 集"
            return .missingEpisode(
                VodLineSwitchMissingEpisodeInfo(
                    targetLineIndex: targetLineIndex,
                    targetLineName: targetLine.name,
                    requestedEpisodeIndex: target.episodeIndex,
                    requestedEpisodeName: fallbackName,
                    availableEpisodeCount: targetLine.episodes.count,
                    carrySeekMs: carrySeekMs,
                    fallbackEpisodeName: targetLine.episodes.last?.name ?? ""
                )
            )
        }

        persistActiveProgressIfBound()
        cancelPendingAndDetachActiveItem()

        var next = target
        next.lineIndex = targetLineIndex
        next.episodeIndex = matchedEpIndex
        next.initialSeekMs = carrySeekMs
        target = next
        beginResolveCurrentTarget()
        return .switched(lineIndex: targetLineIndex, episodeIndex: matchedEpIndex, seekMs: carrySeekMs)
    }

    @discardableResult
    public func forceSwitchVodLine(to targetLineIndex: Int, episodeIndex: Int, seekMs: Int = 0) -> Bool {
        guard !isTornDown,
              !target.isLiveStream,
              target.video.lines.indices.contains(targetLineIndex),
              target.video.lines[targetLineIndex].episodes.indices.contains(episodeIndex)
        else {
            return false
        }
        persistActiveProgressIfBound()
        cancelPendingAndDetachActiveItem()

        var next = target
        next.lineIndex = targetLineIndex
        next.episodeIndex = episodeIndex
        next.initialSeekMs = max(0, seekMs)
        target = next
        beginResolveCurrentTarget()
        return true
    }

    @discardableResult
    public func switchToNextVodLineOutcome() -> VodLineSwitchOutcome {
        guard !isTornDown,
              !target.isLiveStream,
              target.video.lines.count > 1
        else {
            return .unavailable("当前影片没有其他可用线路")
        }
        let lineCount = target.video.lines.count
        let currentEpisode = target.currentEpisode
        for offset in 1..<lineCount {
            let candidateIdx = (target.lineIndex + offset) % lineCount
            let candidateLine = target.video.lines[candidateIdx]
            if Self.matchingEpisodeIndex(
                for: currentEpisode,
                currentIndex: target.episodeIndex,
                sourceEpisodeCount: target.currentLine?.episodes.count ?? 0,
                in: candidateLine.episodes
            ) != nil {
                return switchVodLine(to: candidateIdx)
            }
        }
        let immediateNextIdx = (target.lineIndex + 1) % lineCount
        return switchVodLine(to: immediateNextIdx)
    }

    @discardableResult
    public func switchToNextVodLine() -> Bool {
        if case .switched = switchToNextVodLineOutcome() {
            return true
        }
        return false
    }

    public func switchLiveChannel(delta: Int) {
        guard !isTornDown, target.isLiveStream else { return }
        let count = target.liveFlatChannels.count
        guard count > 0 else { return }

        cancelPendingAndDetachActiveItem()

        let nextIdx = (target.liveChannelIndex + delta % count + count) % count
        let nextChannel = target.liveFlatChannels[nextIdx]
        var next = target
        next.liveChannelIndex = nextIdx
        next.video = CmsVideo(
            id: nextChannel.id,
            title: nextChannel.name,
            poster: nextChannel.logo,
            remarks: nextChannel.group,
            lines: [CmsLine(name: nextChannel.group, episodes: nextChannel.episodes)]
        )
        next.lineIndex = 0
        next.episodeIndex = 0
        next.initialSeekMs = 0
        target = next
        beginResolveCurrentTarget()
    }

    @discardableResult
    public func switchLiveLine(to streamIndex: Int) -> Bool {
        guard !isTornDown,
              target.isLiveStream,
              let line = target.currentLine,
              line.episodes.indices.contains(streamIndex)
        else {
            return false
        }
        if streamIndex == target.episodeIndex && errorMessage == nil && (isResolving || activeLoaded != nil) {
            return false
        }

        cancelPendingAndDetachActiveItem()

        var next = target
        next.episodeIndex = streamIndex
        next.initialSeekMs = 0
        target = next
        beginResolveCurrentTarget()
        return true
    }

    @discardableResult
    public func switchToNextLiveLine() -> Bool {
        guard !isTornDown,
              target.isLiveStream,
              let line = target.currentLine,
              line.episodes.count > 1
        else {
            return false
        }
        let nextIndex = (target.episodeIndex + 1) % line.episodes.count
        return switchLiveLine(to: nextIndex)
    }

    public func applyPlaybackSpeed(_ speed: Double) {
        playbackSpeed = speed
        if !target.isLiveStream {
            engine.setPlaybackRate(Float(speed))
        }
    }

    public func persistActiveProgressIfBound(explicitPosMs: Int? = nil, explicitDurMs: Int? = nil) {
        guard !isTornDown,
              let activeDesc = activeLoaded,
              !activeDesc.isLiveStream,
              activeLoadedToken != nil
        else {
            return
        }
        let pos: Int
        if let explicitPosMs = explicitPosMs {
            pos = explicitPosMs
        } else if engine.hasReadyCurrentItem {
            pos = engine.currentTimeMs
        } else {
            pos = lastObservedPositionMs ?? 0
        }
        let dur = explicitDurMs ?? engine.durationMs
        guard pos > 0 else { return }
        progressRecorder(activeDesc, pos, dur)
    }

    public func teardownAndPersist() {
        guard !isTornDown else { return }
        persistActiveProgressIfBound()
        isTornDown = true
        resolveTask?.cancel()
        resolveTask = nil
        pendingToken = nil
        activeLoadedToken = nil
        activeLoaded = nil
        lastObservedPositionMs = nil
        isResolving = false
        engine.teardown()
        releaseActiveResolvedPlayback()
    }

    public func waitForPendingResourceReleases() async {
        while !pendingReleaseTasks.isEmpty {
            let batch = Array(pendingReleaseTasks.values)
            for task in batch {
                await task.value
            }
        }
    }

    // MARK: - Episode Matching Helper

    public static func matchingEpisodeIndex(
        for currentEpisode: CmsEpisode?,
        currentIndex: Int,
        sourceEpisodeCount: Int = 1,
        in targetEpisodes: [CmsEpisode]
    ) -> Int? {
        guard !targetEpisodes.isEmpty else { return nil }
        guard let cur = currentEpisode else {
            return targetEpisodes.indices.contains(currentIndex) ? currentIndex : nil
        }

        let curNorm = normalizeEpisodeTitle(cur.name)
        guard !curNorm.isEmpty else {
            return targetEpisodes.indices.contains(currentIndex) ? currentIndex : nil
        }

        if targetEpisodes.indices.contains(currentIndex),
           normalizeEpisodeTitle(targetEpisodes[currentIndex].name) == curNorm
        {
            return currentIndex
        }
        if let exactIdx = targetEpisodes.firstIndex(where: { normalizeEpisodeTitle($0.name) == curNorm }) {
            return exactIdx
        }

        if let curNum = extractCanonicalEpisodeNumber(curNorm) {
            if targetEpisodes.indices.contains(currentIndex),
               extractCanonicalEpisodeNumber(normalizeEpisodeTitle(targetEpisodes[currentIndex].name)) == curNum
            {
                return currentIndex
            }
            if let numIdx = targetEpisodes.firstIndex(where: {
                extractCanonicalEpisodeNumber(normalizeEpisodeTitle($0.name)) == curNum
            }) {
                return numIdx
            }
            return nil
        }

        if sourceEpisodeCount == 1,
           targetEpisodes.count == 1,
           currentIndex == 0,
           isGenericSingleFeatureLabel(curNorm),
           isGenericSingleFeatureLabel(normalizeEpisodeTitle(targetEpisodes[0].name))
        {
            return 0
        }

        return nil
    }

    private static func normalizeEpisodeTitle(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static let nonEpisodeSpecialMarkers: [String] = [
        "预告", "花絮", "彩蛋", "特辑", "番外", "访谈", "幕后", "删减", "解读",
        "先导", "片花", "纪录", "剪辑", "pv", "cm", "sp", "ova", "oad", "mv",
    ]

    private static let genericCjkFeatureTokens: [String] = [
        "中英双字", "中文字幕", "国粤双语", "蓝光原盘", "未删减版", "未删减",
        "完整版", "抢先版", "高清版", "超清版", "蓝光版", "无水印",
        "正片", "全集", "电影", "高清", "超清", "蓝光", "原画",
        "国语", "粤语", "英语", "日语", "韩语", "中字", "双语", "中英",
    ].sorted { $0.count > $1.count }

    private static let genericAsciiFeatureTokens: [String] = [
        "2160p", "1080p", "720p", "480p", "blu-ray", "bluray", "remux", "fullhd",
        "web-dl", "webdl", "hdrip", "bdrip", "dvdrip", "uhd", "fhd", "hdr", "sdr",
        "4k", "8k", "2k", "hd", "bd", "ts", "tc", "cam", "dvd",
    ].sorted { $0.count > $1.count }

    private static func isGenericSingleFeatureLabel(_ normalized: String) -> Bool {
        guard !normalized.isEmpty else { return false }
        if nonEpisodeSpecialMarkers.contains(where: { normalized.contains($0) }) {
            return false
        }

        var residual = normalized
        var matchedAnyToken = false

        for token in genericAsciiFeatureTokens {
            let escaped = NSRegularExpression.escapedPattern(for: token)
            let pattern = "(?<![a-z0-9])\(escaped)(?![a-z0-9])"
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                let nsRange = NSRange(residual.startIndex..<residual.endIndex, in: residual)
                if regex.firstMatch(in: residual, options: [], range: nsRange) != nil {
                    matchedAnyToken = true
                    residual = regex.stringByReplacingMatches(in: residual, options: [], range: nsRange, withTemplate: " ")
                }
            }
        }

        for token in genericCjkFeatureTokens {
            if residual.contains(token) {
                matchedAnyToken = true
                residual = residual.replacingOccurrences(of: token, with: " ")
            }
        }

        guard matchedAnyToken else { return false }

        let allowedSeparators = CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: "-_/·•|+.,:;()[]【】（）「」『』<>《》"))
        let remaining = residual.unicodeScalars.filter { !allowedSeparators.contains($0) }
        return remaining.isEmpty
    }

    private static func extractCanonicalEpisodeNumber(_ normalized: String) -> Int? {
        guard !normalized.isEmpty else { return nil }
        if nonEpisodeSpecialMarkers.contains(where: { normalized.contains($0) }) {
            return nil
        }
        let patterns = [
            #"^第\s*0*(\d+)\s*[集话話期回]$"#,
            #"^(?:ep|e)\s*0*(\d+)$"#,
            #"^0*(\d+)$"#,
        ]
        let range = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: normalized, options: [], range: range),
                  match.numberOfRanges >= 2,
                  let numRange = Range(match.range(at: 1), in: normalized),
                  let num = Int(normalized[numRange])
            else {
                continue
            }
            return num
        }
        return nil
    }

    // MARK: - Internal Token-Bound State Transitions

    private func bindEngineCallbacks() {
        engine.onProgressTick = { [weak self] token, posMs, durMs in
            self?.handleProgressTick(token: token, posMs: posMs, durMs: durMs)
        }
        engine.onPlaybackEnded = { [weak self] token in
            self?.handlePlaybackEnded(token: token)
        }
        engine.onPlaybackFailed = { [weak self] token, message in
            self?.handlePlaybackFailed(token: token, message: message)
        }
    }

    private func scheduleRelease(_ resolved: ResolvedPlayback?) {
        guard let resolved = resolved, let releaser = resourceReleaser else { return }
        guard resolved.rangeProxyResourceId != nil || resolved.headerProxySessionId != nil else { return }
        let releaseId = UUID()
        let task = Task { [weak self] in
            await releaser(resolved)
            await MainActor.run { [weak self] in
                self?.pendingReleaseTasks.removeValue(forKey: releaseId)
            }
        }
        pendingReleaseTasks[releaseId] = task
    }

    private func releaseActiveResolvedPlayback() {
        let old = activeResolvedPlayback
        activeResolvedPlayback = nil
        scheduleRelease(old)
    }

    private func cancelPendingAndDetachActiveItem() {
        resolveTask?.cancel()
        resolveTask = nil
        pendingToken = nil
        activeLoadedToken = nil
        activeLoaded = nil
        lastObservedPositionMs = nil
        autoAdvanceConsumedToken = nil
        engine.stopCurrentItem()
        releaseActiveResolvedPlayback()
    }

    private func beginResolveCurrentTarget() {
        guard !isTornDown else { return }
        cancelPendingAndDetachActiveItem()

        let descriptor = target
        guard descriptor.currentLine != nil, descriptor.currentEpisode != nil else {
            errorIsPlaybackFailure = false
            errorMessage = "未找到有效的剧集线路"
            isResolving = false
            return
        }

        nextToken &+= 1
        let requestToken = nextToken
        pendingToken = requestToken
        isResolving = true
        errorMessage = nil
        errorIsPlaybackFailure = false
        onTargetTransition?()

        let streamResolver = self.resolver
        let streamReleaser = self.resourceReleaser
        resolveTask = Task { @MainActor [weak self] in
            do {
                let resolved = try await streamResolver(descriptor)
                guard let self = self,
                      !Task.isCancelled,
                      !self.isTornDown,
                      self.pendingToken == requestToken
                else {
                    if let strongSelf = self {
                        strongSelf.scheduleRelease(resolved)
                    } else if let streamReleaser = streamReleaser,
                              resolved.rangeProxyResourceId != nil || resolved.headerProxySessionId != nil
                    {
                        Task { await streamReleaser(resolved) }
                    }
                    return
                }
                self.pendingToken = nil
                self.activeLoadedToken = requestToken
                self.activeLoaded = descriptor
                self.activeResolvedPlayback = resolved
                self.lastObservedPositionMs = nil
                self.autoAdvanceConsumedToken = nil
                self.activeKernelLabel = resolved.kernelLabel
                self.activeResolutionBadge = resolved.resolutionBadge
                self.errorMessage = nil
                self.errorIsPlaybackFailure = false
                self.isResolving = false
                let rate = descriptor.isLiveStream ? Float(1.0) : Float(self.playbackSpeed)
                self.engine.load(
                    token: requestToken,
                    url: resolved.playableUrl,
                    initialSeekMs: descriptor.initialSeekMs,
                    rate: rate
                )
            } catch is CancellationError {
                return
            } catch {
                guard let self = self,
                      !Task.isCancelled,
                      !self.isTornDown,
                      self.pendingToken == requestToken
                else {
                    return
                }
                self.pendingToken = nil
                self.activeLoadedToken = nil
                self.activeLoaded = nil
                self.lastObservedPositionMs = nil
                self.errorIsPlaybackFailure = false
                self.errorMessage = error.localizedDescription
                self.isResolving = false
            }
        }
    }

    private func handleProgressTick(token: UInt64, posMs: Int, durMs: Int) {
        guard !isTornDown,
              let activeTok = activeLoadedToken,
              activeTok == token,
              let activeDesc = activeLoaded
        else {
            return
        }
        if !activeDesc.isLiveStream {
            lastObservedPositionMs = max(0, posMs)
            if posMs > 0 {
                progressRecorder(activeDesc, posMs, durMs)
            }
        }

        let outroMs = skipOutroSec * 1000
        if !activeDesc.isLiveStream,
           outroMs > 0,
           durMs > outroMs + 30_000,
           posMs >= durMs - outroMs
        {
            triggerAutoAdvanceOnce(forToken: token, posMs: posMs, durMs: durMs)
        }
    }

    private func handlePlaybackEnded(token: UInt64) {
        guard !isTornDown,
              let activeTok = activeLoadedToken,
              activeTok == token
        else {
            return
        }
        triggerAutoAdvanceOnce(
            forToken: token,
            posMs: engine.currentTimeMs,
            durMs: engine.durationMs
        )
    }

    private func handlePlaybackFailed(token: UInt64, message: String) {
        guard !isTornDown,
              let activeTok = activeLoadedToken,
              activeTok == token
        else {
            return
        }
        if !target.isLiveStream {
            if engine.hasReadyCurrentItem {
                target.initialSeekMs = max(0, engine.currentTimeMs)
            } else if let observed = lastObservedPositionMs {
                target.initialSeekMs = max(0, observed)
            }
        }
        persistActiveProgressIfBound()
        engine.stopCurrentItem()
        releaseActiveResolvedPlayback()
        activeLoadedToken = nil
        activeLoaded = nil
        lastObservedPositionMs = nil
        isResolving = false
        errorIsPlaybackFailure = true
        let clean = message.trimmingCharacters(in: .whitespacesAndNewlines)
        errorMessage = clean.isEmpty ? "视频加载或播放中断" : clean
    }

    private func triggerAutoAdvanceOnce(forToken token: UInt64, posMs: Int, durMs: Int) {
        guard autoAdvanceConsumedToken != token,
              let activeDesc = activeLoaded,
              !activeDesc.isLiveStream
        else {
            return
        }
        autoAdvanceConsumedToken = token
        persistActiveProgressIfBound(explicitPosMs: posMs, explicitDurMs: durMs)

        guard autoNext,
              let line = activeDesc.currentLine,
              activeDesc.episodeIndex + 1 < line.episodes.count
        else {
            return
        }

        cancelPendingAndDetachActiveItem()
        var next = activeDesc
        next.episodeIndex = activeDesc.episodeIndex + 1
        next.initialSeekMs = skipIntroSec * 1000
        target = next
        beginResolveCurrentTarget()
    }
}
