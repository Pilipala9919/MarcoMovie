// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
// Marco Movie iOS — Native AVPlayer Low-Power Cinema Engine
// Supports iOS 14.0–26.0, PiP, AirPlay 2, Lock Screen / Dynamic Island Now Playing,
// EDR/HDR telemetry, thermal monitoring, dialogue enhancement, and AVPlayerItemLegibleOutput.

import AVFoundation
import AVKit
import CoreMedia
import Foundation
import MarcoIOSCore
import MediaPlayer
import UIKit

// MARK: - Shared Video Aspect Mode & Track Models

/// Unified video aspect ratio scaling mode shared across AVPlayer and libmpv engines.
public enum MarcoVideoAspectMode: String, CaseIterable, Hashable, Sendable {
    case fit = "contain"
    case fill = "cover"
    case stretch = "fill"

    public var displayTitle: String {
        switch self {
        case .fit: return "适应屏幕"
        case .fill: return "铺满裁切"
        case .stretch: return "拉伸填充"
        }
    }

    public var symbolName: String {
        switch self {
        case .fit: return "rectangle.arrowtriangle.2.inward"
        case .fill: return "rectangle.arrowtriangle.2.outward"
        case .stretch: return "arrow.up.left.and.arrow.down.right"
        }
    }

    public var avVideoGravity: AVLayerVideoGravity {
        switch self {
        case .fit: return .resizeAspect
        case .fill: return .resizeAspectFill
        case .stretch: return .resize
        }
    }

    public static func fromPreference(_ raw: String?) -> MarcoVideoAspectMode {
        let normalized = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "cover", "fill_crop", "resizeaspectfill":
            return .fill
        case "fill", "stretch", "resize":
            return .stretch
        default:
            return .fit
        }
    }
}

/// Unified audio/subtitle track descriptor shared by AVPlayer and libmpv.
public struct MarcoMediaTrack: Equatable, Hashable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let language: String
    public let isSelected: Bool
    public let isBitmapSubtitle: Bool
    public let codec: String

    public init(
        id: String,
        title: String,
        language: String = "",
        isSelected: Bool = false,
        isBitmapSubtitle: Bool = false,
        codec: String = ""
    ) {
        self.id = id
        self.title = title
        self.language = language
        self.isSelected = isSelected
        self.isBitmapSubtitle = isBitmapSubtitle
        self.codec = codec
    }

    public var displayLabel: String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedLang = language.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty && !trimmedLang.isEmpty && !trimmedTitle.lowercased().contains(trimmedLang.lowercased()) {
            return "\(trimmedTitle) (\(trimmedLang))"
        }
        if !trimmedTitle.isEmpty {
            return trimmedTitle
        }
        if !trimmedLang.isEmpty {
            return trimmedLang
        }
        return "轨道 #\(id)"
    }
}

// MARK: - AVPlayer State & Telemetry Snapshots

public struct MarcoAvPlayerState: Equatable, Sendable {
    public var isPlaying: Bool
    public var isBuffering: Bool
    public var isReady: Bool
    public var positionMs: Int64
    public var durationMs: Int64
    public var bufferedMs: Int64
    public var rate: Float
    public var volume: Float
    public var videoSize: CGSize
    public var isHdr: Bool
    public var isPipSupported: Bool
    public var isPipPossible: Bool
    public var isPipActive: Bool
    public var isAirPlayActive: Bool
    public var airPlayDeviceName: String
    public var thermalState: ProcessInfo.ThermalState
    public var potentialEdrHeadroom: Double
    public var vocalLoudness: VocalLoudnessPreset

    public init(
        isPlaying: Bool = false,
        isBuffering: Bool = false,
        isReady: Bool = false,
        positionMs: Int64 = 0,
        durationMs: Int64 = 0,
        bufferedMs: Int64 = 0,
        rate: Float = 1.0,
        volume: Float = 1.0,
        videoSize: CGSize = .zero,
        isHdr: Bool = false,
        isPipSupported: Bool = AVPictureInPictureController.isPictureInPictureSupported(),
        isPipPossible: Bool = false,
        isPipActive: Bool = false,
        isAirPlayActive: Bool = false,
        airPlayDeviceName: String = "",
        thermalState: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState,
        potentialEdrHeadroom: Double = 1.0,
        vocalLoudness: VocalLoudnessPreset = .off
    ) {
        self.isPlaying = isPlaying
        self.isBuffering = isBuffering
        self.isReady = isReady
        self.positionMs = positionMs
        self.durationMs = durationMs
        self.bufferedMs = bufferedMs
        self.rate = rate
        self.volume = volume
        self.videoSize = videoSize
        self.isHdr = isHdr
        self.isPipSupported = isPipSupported
        self.isPipPossible = isPipPossible
        self.isPipActive = isPipActive
        self.isAirPlayActive = isAirPlayActive
        self.airPlayDeviceName = airPlayDeviceName
        self.thermalState = thermalState
        self.potentialEdrHeadroom = potentialEdrHeadroom
        self.vocalLoudness = vocalLoudness
    }
}

public struct MarcoAvTelemetrySnapshot: Equatable, Sendable {
    public let thermalState: String
    public let thermalStateCode: Int
    public let physicalMemoryBytes: Int64
    public let processorCount: Int
    public let machineIdentifier: String
    public let supportsHdrDisplay: Bool
    public let potentialEdrHeadroom: Double
    public let isLowPowerMode: Bool
    public let isPipSupported: Bool
    public let isPipPossible: Bool
    public let isPipActive: Bool
    public let systemVolume: Double
    public let isAirPlayActive: Bool
    public let airPlayDeviceName: String
}

// MARK: - Delegate Protocol

public protocol MarcoAvPlayerEngineDelegate: AnyObject {
    func avPlayerEngine(
        _ engine: MarcoAvPlayerEngine,
        onPositionUpdate positionMs: Int64,
        durationMs: Int64,
        bufferedMs: Int64
    )
    func avPlayerEngine(_ engine: MarcoAvPlayerEngine, onBufferingChanged isBuffering: Bool)
    func avPlayerEngine(_ engine: MarcoAvPlayerEngine, onPlaybackStateChanged state: MarcoAvPlayerState)
    func avPlayerEngine(
        _ engine: MarcoAvPlayerEngine,
        onTracksUpdated audioTracks: [MarcoMediaTrack],
        subtitleTracks: [MarcoMediaTrack]
    )
    func avPlayerEngine(_ engine: MarcoAvPlayerEngine, onSubtitleCue lines: [String], hasNativeSamples: Bool)
    func avPlayerEngine(
        _ engine: MarcoAvPlayerEngine,
        onPipStateChanged isActive: Bool,
        isPossible: Bool,
        phase: String,
        error: String?
    )
    func avPlayerEngine(_ engine: MarcoAvPlayerEngine, onAirPlayChanged isActive: Bool, deviceName: String)
    func avPlayerEngineDidComplete(_ engine: MarcoAvPlayerEngine)
    func avPlayerEngine(_ engine: MarcoAvPlayerEngine, onFallbackToMpv positionMs: Int64, reason: String)

    // Optional remote / system hooks with default no-op implementations.
    func avPlayerEngineDidRequestNextTrack(_ engine: MarcoAvPlayerEngine)
    func avPlayerEngineDidRequestPreviousTrack(_ engine: MarcoAvPlayerEngine)
    func avPlayerEngineDidRequestPipRestoreForeground(_ engine: MarcoAvPlayerEngine)
    func avPlayerEngine(_ engine: MarcoAvPlayerEngine, onThermalStateChanged state: ProcessInfo.ThermalState)
    func avPlayerEngine(_ engine: MarcoAvPlayerEngine, onSystemVolumeChanged volume: Float)
}

public extension MarcoAvPlayerEngineDelegate {
    func avPlayerEngineDidRequestNextTrack(_ engine: MarcoAvPlayerEngine) {}
    func avPlayerEngineDidRequestPreviousTrack(_ engine: MarcoAvPlayerEngine) {}
    func avPlayerEngineDidRequestPipRestoreForeground(_ engine: MarcoAvPlayerEngine) {}
    func avPlayerEngine(_ engine: MarcoAvPlayerEngine, onThermalStateChanged state: ProcessInfo.ThermalState) {}
    func avPlayerEngine(_ engine: MarcoAvPlayerEngine, onSystemVolumeChanged volume: Float) {}
}

// MARK: - AVPlayerLayer Host View

/// Pure UIKit view hosting `AVPlayerLayer` with Core Animation implicit resize actions disabled
/// so device rotations and iPad Split View transitions stay locked to 120fps without elastic jitter.
public final class MarcoAvPlayerLayerView: UIView {
    public let playerLayer = AVPlayerLayer()

    public var videoGravity: AVLayerVideoGravity {
        get { playerLayer.videoGravity }
        set {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playerLayer.videoGravity = newValue
            CATransaction.commit()
        }
    }

    public override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isOpaque = true
        playerLayer.videoGravity = .resizeAspect
        playerLayer.needsDisplayOnBoundsChange = true
        layer.addSublayer(playerLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func setAspectMode(_ mode: MarcoVideoAspectMode) {
        videoGravity = mode.avVideoGravity
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
}

// MARK: - Native AVPlayer Engine

public final class MarcoAvPlayerEngine: NSObject,
    AVPictureInPictureControllerDelegate,
    AVPlayerItemLegibleOutputPushDelegate
{
    public weak var delegate: MarcoAvPlayerEngineDelegate?
    public private(set) var state = MarcoAvPlayerState()

    private enum LegibleTrackFormatKind {
        case text
        case bitmap
        case unknown
    }

    private var queuePlayer: AVQueuePlayer?
    private weak var visiblePlayerLayer: AVPlayerLayer?
    private var pipSourceLayer: AVPlayerLayer?
    private var pipController: AVPictureInPictureController?
    private var legibleOutput: AVPlayerItemLegibleOutput?
    private weak var legibleOutputItem: AVPlayerItem?

    private var hiddenAirPlayPicker: AVRoutePickerView?
    private var hiddenVolumeView: MPVolumeView?

    private var audioSessionConfigured = false
    private var audioSessionActive = false
    private var autoPipEnabled = true
    private var pipStarting = false
    private var cancelPendingPipStart = false
    private var isAppForegroundActive = true

    private var currentSessionId = 0
    private var currentUrlString = ""
    private var isLiveStream = false
    private var pendingStartPositionMs: Int64 = 0
    private var fallbackEmittedForCurrentItem = false
    private var requestedRate: Float = 1.0
    private var requestedVolume: Float = 1.0
    private var vocalLoudnessPreset: VocalLoudnessPreset = .off

    private var nowPlayingTitle = ""
    private var nowPlayingSubtitle = ""
    private var nowPlayingPosterImage: UIImage?
    private var remoteCommandsRegistered = false
    private var remoteCommandTokens: [(MPRemoteCommand, Any)] = []
    private var lastNowPlayingPushTime: CFTimeInterval = 0

    private var lastLegibleLines: [String] = []
    private var lastLegibleHasNativeSamples = false
    private var selectedLegibleStaticFormat: LegibleTrackFormatKind = .unknown
    private var legibleTrackConfirmedText = false
    private var legibleTrackConfirmedNonText = false
    private var suppressNativeSubtitleRenderingRequested = false
    private var suppressNativeSubtitleAllowNonText = false

    private var lastProgressPositionMs: Int64 = -1
    private var lastProgressBufferedMs: Int64 = -1
    private var lastProgressPlaying = false
    private var volumeConfirmWorkItem: DispatchWorkItem?

    private var timeObserverToken: Any?
    private var statusObservation: NSKeyValueObservation?
    private var likelyToKeepUpObservation: NSKeyValueObservation?
    private var bufferEmptyObservation: NSKeyValueObservation?
    private var presentationSizeObservation: NSKeyValueObservation?
    private var timeControlStatusObservation: NSKeyValueObservation?
    private var externalPlaybackObservation: NSKeyValueObservation?
    private var pipPossibleObservation: NSKeyValueObservation?
    private var systemVolumeObservation: NSKeyValueObservation?
    private var itemNotificationTokens: [NSObjectProtocol] = []
    private var globalNotificationTokens: [NSObjectProtocol] = []

    private var isPipActiveOrStarting: Bool {
        pipStarting || (pipController?.isPictureInPictureActive == true)
    }

    public override init() {
        super.init()
        state.potentialEdrHeadroom = Self.potentialEdrHeadroom()
        state.thermalState = ProcessInfo.processInfo.thermalState
        installGlobalObservers()
    }

    deinit {
        cleanupPlaybackObservers()
        unregisterRemoteCommands()
        clearNowPlayingInfo()
        volumeConfirmWorkItem?.cancel()
        volumeConfirmWorkItem = nil
        systemVolumeObservation?.invalidate()
        systemVolumeObservation = nil
        detachHiddenVolumeView()
        for token in globalNotificationTokens {
            NotificationCenter.default.removeObserver(token)
        }
        globalNotificationTokens.removeAll()
    }

    // MARK: - Static System Telemetry & Engine Precheck Helpers

    public static func activeWindowScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
    }

    public static func activeKeyWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let activeScene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
        if let win = activeScene?.windows.first(where: { $0.isKeyWindow }) {
            return win
        }
        if let anyKey = scenes.flatMap({ $0.windows }).first(where: { $0.isKeyWindow }) {
            return anyKey
        }
        return activeScene?.windows.first ?? scenes.flatMap({ $0.windows }).first
    }

    public static func potentialEdrHeadroom() -> Double {
        let screen = activeWindowScene()?.screen ?? UIScreen.main
        if #available(iOS 16.0, *) {
            return Double(screen.potentialEDRHeadroom)
        }
        return screen.traitCollection.displayGamut == .P3 ? 1.25 : 1.0
    }

    public static func thermalStateString(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "nominal"
        }
    }

    public static func thermalStateCode(_ state: ProcessInfo.ThermalState) -> Int {
        switch state {
        case .nominal: return 0
        case .fair: return 1
        case .serious: return 2
        case .critical: return 3
        @unknown default: return 0
        }
    }

    public static func machineIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        let chars = mirror.children.compactMap { elem -> Character? in
            guard let value = elem.value as? Int8, value != 0 else { return nil }
            return Character(UnicodeScalar(UInt8(value)))
        }
        return String(chars)
    }

    /// Static precheck identifying containers/protocols where libmpv should be preferred over AVPlayer.
    public static func shouldPreferMpvForURL(_ urlString: String) -> (preferMpv: Bool, reason: String?) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return (false, nil) }
        if trimmed.hasPrefix("rtmp://") || trimmed.hasPrefix("rtsp://") || trimmed.hasPrefix("mms://") {
            return (true, "实时流协议需由 libmpv 解码")
        }
        let noFragment = trimmed.components(separatedBy: "#").first ?? trimmed
        let pathOnly = noFragment.components(separatedBy: "?").first ?? noFragment
        let mpvPreferredExts = [".mkv", ".flv", ".avi", ".rmvb", ".rm", ".wmv", ".webm", ".ogv", ".vob", ".iso"]
        for ext in mpvPreferredExts where pathOnly.hasSuffix(ext) {
            return (true, "容器格式 \(ext.uppercased()) 推荐由 libmpv 播放")
        }
        return (false, nil)
    }

    // MARK: - Layer Binding & PiP Lifecycle

    public func attach(to layerView: MarcoAvPlayerLayerView) {
        let layer = layerView.playerLayer
        performOnMain { [weak self] in
            guard let self = self else { return }
            self.visiblePlayerLayer = layer
            let player = self.ensurePlayer()
            layer.player = player
            if self.isPipActiveOrStarting {
                self.emitPipState()
                return
            }
            if self.pipSourceLayer !== layer || self.pipController == nil {
                if let oldSource = self.pipSourceLayer, oldSource !== layer {
                    oldSource.player = nil
                }
                self.configurePictureInPicture(for: layer)
            } else {
                self.emitPipState()
            }
        }
    }

    public func detach(from layerView: MarcoAvPlayerLayerView) {
        let layer = layerView.playerLayer
        performOnMain { [weak self] in
            guard let self = self else { return }
            if self.visiblePlayerLayer === layer {
                self.visiblePlayerLayer = nil
            }
            let isProtectedPipSource = self.isPipActiveOrStarting && self.pipSourceLayer === layer
            if isProtectedPipSource {
                // Strongly retain pipSourceLayer & pipController across rotations and Split View rebuilds.
                return
            }
            if self.visiblePlayerLayer !== layer {
                layer.player = nil
            }
            if self.pipSourceLayer === layer {
                self.teardownPictureInPicture(detachSourceLayer: false)
                if let currentVisible = self.visiblePlayerLayer {
                    self.configurePictureInPicture(for: currentVisible)
                } else {
                    self.emitPipState()
                }
            }
        }
    }

    // MARK: - Public Playback Controls

    public func open(
        url: URL,
        headers: [String: String] = [:],
        startPositionMs: Int64 = 0,
        isLive: Bool = false,
        title: String = "",
        subtitle: String = "",
        posterImage: UIImage? = nil,
        autoPlay: Bool = true,
        preferredForwardBufferDuration: TimeInterval = 24.0
    ) {
        performOnMain { [weak self] in
            guard let self = self else { return }
            let scheme = (url.scheme ?? "").lowercased()
            guard scheme == "http" || scheme == "https" || scheme == "file" else {
                self.triggerFallbackToMpv(reason: "AVPlayer 不支持协议：\(scheme)")
                return
            }

            self.isLiveStream = isLive
            self.nowPlayingTitle = title
            self.nowPlayingSubtitle = subtitle
            self.nowPlayingPosterImage = posterImage

            self.configureAudioSession()
            self.registerRemoteCommandsIfNeeded()

            self.currentSessionId += 1
            let sessionId = self.currentSessionId
            self.currentUrlString = url.absoluteString
            self.pendingStartPositionMs = max(0, startPositionMs)
            self.fallbackEmittedForCurrentItem = false
            self.lastProgressPositionMs = -1
            self.lastProgressBufferedMs = -1
            self.lastProgressPlaying = false

            self.cleanupItemObservers()

            var assetOptions: [String: Any] = [
                AVURLAssetAllowsCellularAccessKey: true,
                AVURLAssetAllowsExpensiveNetworkAccessKey: true,
                AVURLAssetAllowsConstrainedNetworkAccessKey: true,
            ]
            var sanitizedHeaders: [String: String] = [:]
            for (k, v) in headers {
                let ck = k.trimmingCharacters(in: .whitespacesAndNewlines)
                let cv = v.trimmingCharacters(in: .whitespacesAndNewlines)
                if !ck.isEmpty && !cv.isEmpty {
                    sanitizedHeaders[ck] = cv
                }
            }
            if !sanitizedHeaders.isEmpty {
                assetOptions["AVURLAssetHTTPHeaderFieldsKey"] = sanitizedHeaders
            }

            let asset = AVURLAsset(url: url, options: assetOptions)
            let item = AVPlayerItem(asset: asset)
            item.preferredForwardBufferDuration = isLive ? 4.0 : max(4.0, preferredForwardBufferDuration)
            item.canUseNetworkResourcesForLiveStreamingWhilePaused = !isLive

            self.selectedLegibleStaticFormat = .unknown
            self.legibleTrackConfirmedText = false
            self.legibleTrackConfirmedNonText = false
            self.lastLegibleLines = []
            self.lastLegibleHasNativeSamples = false

            let output = AVPlayerItemLegibleOutput()
            output.setDelegate(self, queue: .main)
            item.add(output)
            self.legibleOutput = output
            self.legibleOutputItem = item
            self.refreshSelectedLegibleTrackCapability(for: item)
            self.applyEffectiveLegibleSuppression()

            let player = self.ensurePlayer()
            player.volume = self.effectivePlayerVolume()
            if let layer = self.visiblePlayerLayer {
                if layer.player !== player {
                    layer.player = player
                }
                if self.pipController == nil || (self.pipSourceLayer !== layer && !self.isPipActiveOrStarting) {
                    self.configurePictureInPicture(for: layer)
                }
            }

            self.state.isReady = false
            self.state.isBuffering = true
            self.state.positionMs = max(0, startPositionMs)
            self.state.durationMs = 0
            self.state.bufferedMs = 0
            self.delegate?.avPlayerEngine(self, onBufferingChanged: true)

            self.observePlayerItem(item, sessionId: sessionId)
            player.replaceCurrentItem(with: item)

            if autoPlay {
                player.play()
                if self.requestedRate != 1.0 && !isLive {
                    player.rate = self.requestedRate
                }
            } else {
                player.pause()
            }

            self.pushNowPlayingInfo(force: true)
            self.emitPlaybackState()
        }
    }

    public func updateNowPlayingMetadata(
        title: String,
        subtitle: String = "",
        posterImage: UIImage? = nil,
        isLive: Bool? = nil
    ) {
        performOnMain { [weak self] in
            guard let self = self else { return }
            self.nowPlayingTitle = title
            self.nowPlayingSubtitle = subtitle
            if let posterImage = posterImage {
                self.nowPlayingPosterImage = posterImage
            }
            if let isLive = isLive {
                self.isLiveStream = isLive
            }
            self.pushNowPlayingInfo(force: true)
        }
    }

    public func play() {
        performOnMain { [weak self] in
            guard let self = self else { return }
            self.configureAudioSession()
            let player = self.ensurePlayer()
            player.play()
            if self.requestedRate != 1.0 && !self.isLiveStream {
                player.rate = self.requestedRate
            }
            self.pushNowPlayingInfo(force: true)
        }
    }

    public func pause() {
        performOnMain { [weak self] in
            guard let self = self else { return }
            self.queuePlayer?.pause()
            self.pushNowPlayingInfo(force: true)
        }
    }

    public func togglePlayPause() {
        performOnMain { [weak self] in
            guard let self = self else { return }
            if self.state.isPlaying {
                self.pause()
            } else {
                self.play()
            }
        }
    }

    public func seek(toMs positionMs: Int64, completion: ((Bool) -> Void)? = nil) {
        performOnMain { [weak self] in
            guard let self = self, let player = self.queuePlayer else {
                completion?(false)
                return
            }
            let clampedMs = max(0, positionMs)
            let seekSession = self.currentSessionId
            self.clearLegibleSubtitleState(forceEmit: true)
            let target = CMTime(value: CMTimeValue(clampedMs), timescale: 1000)
            player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
                DispatchQueue.main.async {
                    guard let self = self, self.currentSessionId == seekSession else {
                        completion?(false)
                        return
                    }
                    if finished {
                        self.state.positionMs = self.currentPositionMs()
                        self.pushNowPlayingInfo(force: true)
                        self.delegate?.avPlayerEngine(
                            self,
                            onPositionUpdate: self.state.positionMs,
                            durationMs: self.currentDurationMs(),
                            bufferedMs: self.currentBufferedMs()
                        )
                    }
                    completion?(finished)
                }
            }
        }
    }

    public func setRate(_ rate: Float) {
        performOnMain { [weak self] in
            guard let self = self else { return }
            let clamped = max(0.25, min(rate, 4.0))
            self.requestedRate = clamped
            self.state.rate = clamped
            if let player = self.queuePlayer, !self.isLiveStream,
               player.timeControlStatus == .playing || player.rate > 0
            {
                player.rate = clamped
            }
            self.pushNowPlayingInfo(force: true)
            self.emitPlaybackState()
        }
    }

    public func setVolume(_ volume: Float) {
        performOnMain { [weak self] in
            guard let self = self else { return }
            let clamped = max(0.0, min(volume, 1.0))
            self.requestedVolume = clamped
            self.state.volume = clamped
            self.queuePlayer?.volume = self.effectivePlayerVolume()
            self.emitPlaybackState()
        }
    }

    public func setVideoGravity(_ gravity: AVLayerVideoGravity) {
        performOnMain { [weak self] in
            guard let layer = self?.visiblePlayerLayer else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.videoGravity = gravity
            CATransaction.commit()
        }
    }

    public func setAspectMode(_ mode: MarcoVideoAspectMode) {
        setVideoGravity(mode.avVideoGravity)
    }

    /// Configures dialogue/vocal loudness enhancement for AVPlayer.
    /// Tunes `AVAudioSession` mode (`.spokenAudio` for `.cinemaVocal`, `.moviePlayback` otherwise)
    /// and applies track-level gain via `AVMutableAudioMix` where supported by the asset.
    public func setVocalLoudness(_ preset: VocalLoudnessPreset) {
        performOnMain { [weak self] in
            guard let self = self else { return }
            self.vocalLoudnessPreset = preset
            self.state.vocalLoudness = preset
            self.audioSessionConfigured = false
            self.configureAudioSession()
            self.queuePlayer?.volume = self.effectivePlayerVolume()
            if let item = self.queuePlayer?.currentItem {
                self.applyAudioDialogueMixIfSupported(to: item)
            }
            self.emitPlaybackState()
        }
    }

    public func selectAudioTrack(_ trackId: String?) {
        performOnMain { [weak self] in
            self?.selectMediaTrack(characteristic: .audible, trackId: trackId)
        }
    }

    public func selectSubtitleTrack(_ trackId: String?) {
        performOnMain { [weak self] in
            self?.selectMediaTrack(characteristic: .legible, trackId: trackId)
        }
    }

    public func currentAudioTracks() -> [MarcoMediaTrack] {
        readMediaSelectionTracks(characteristic: .audible)
    }

    public func currentSubtitleTracks() -> [MarcoMediaTrack] {
        readMediaSelectionTracks(characteristic: .legible)
    }

    public func setSuppressNativeSubtitleRendering(_ suppress: Bool, allowNonText: Bool = false) {
        performOnMain { [weak self] in
            guard let self = self else { return }
            self.suppressNativeSubtitleRenderingRequested = suppress
            self.suppressNativeSubtitleAllowNonText = suppress && allowNonText
            self.applyEffectiveLegibleSuppression()
        }
    }

    // MARK: - Picture-in-Picture

    @discardableResult
    public func startPictureInPicture() -> Bool {
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            emitPipState()
            return false
        }
        guard configureAudioSession(forceActivate: true) else {
            delegate?.avPlayerEngine(
                self,
                onPipStateChanged: false,
                isPossible: pipController?.isPictureInPicturePossible ?? false,
                phase: "failed",
                error: "音频会话激活失败，暂无法开启画中画"
            )
            return false
        }
        if let visible = visiblePlayerLayer,
           pipController == nil || (pipSourceLayer !== visible && !isPipActiveOrStarting)
        {
            configurePictureInPicture(for: visible)
        }
        guard let pip = pipController else {
            emitPipState()
            return false
        }
        if pip.isPictureInPictureActive {
            pipStarting = false
            emitPipState(phase: "didStart")
            return true
        }
        if pipStarting {
            return true
        }
        guard pip.isPictureInPicturePossible else {
            delegate?.avPlayerEngine(
                self,
                onPipStateChanged: false,
                isPossible: false,
                phase: "notReady",
                error: "视频画面准备完成后即可开启画中画"
            )
            return false
        }
        cancelPendingPipStart = false
        pipStarting = true
        pip.startPictureInPicture()
        return true
    }

    public func stopPictureInPicture() {
        performOnMain { [weak self] in
            guard let self = self else { return }
            if let pip = self.pipController, pip.isPictureInPictureActive {
                self.cancelPendingPipStart = false
                pip.stopPictureInPicture()
            } else if self.pipStarting {
                self.cancelPendingPipStart = true
            }
        }
    }

    public func setAutoPictureInPictureEnabled(_ enabled: Bool) {
        performOnMain { [weak self] in
            guard let self = self else { return }
            self.autoPipEnabled = enabled
            if #available(iOS 14.2, *) {
                self.pipController?.canStartPictureInPictureAutomaticallyFromInline = enabled
            }
        }
    }

    // MARK: - AirPlay 2

    /// Creates a styled native `AVRoutePickerView` suitable for direct placement in the cinema HUD.
    public func makeAirPlayRoutePickerView(
        tintColor: UIColor = .white,
        activeTintColor: UIColor = MarcoColors.accentTint
    ) -> AVRoutePickerView {
        let picker = AVRoutePickerView(frame: CGRect(x: 0, y: 0, width: 36, height: 36))
        picker.prioritizesVideoDevices = true
        picker.tintColor = tintColor
        picker.activeTintColor = activeTintColor
        return picker
    }

    /// Programmatically opens the native iOS AirPlay 2 route picker sheet.
    public func presentAirPlayPicker(from hostView: UIView? = nil) {
        performOnMain { [weak self] in
            guard let self = self else { return }
            guard let container = hostView ?? Self.activeKeyWindow()?.rootViewController?.view else { return }
            let bounds = container.bounds
            let anchorFrame = CGRect(
                x: max(8.0, bounds.midX - 22.0),
                y: max(8.0, bounds.midY - 22.0),
                width: 44.0,
                height: 44.0
            )
            let picker = self.hiddenAirPlayPicker ?? AVRoutePickerView(frame: anchorFrame)
            self.hiddenAirPlayPicker = picker
            picker.frame = anchorFrame
            picker.prioritizesVideoDevices = true
            picker.alpha = 0.001
            picker.isUserInteractionEnabled = false
            if picker.superview !== container {
                picker.removeFromSuperview()
                container.addSubview(picker)
            }
            for sub in picker.subviews {
                if let btn = sub as? UIButton {
                    btn.sendActions(for: .touchUpInside)
                    return
                }
            }
        }
    }

    // MARK: - System Volume (MPVolumeView + AVAudioSession)

    public func currentSystemVolume() -> Float {
        max(0.0, min(AVAudioSession.sharedInstance().outputVolume, 1.0))
    }

    @discardableResult
    public func setSystemVolume(_ volume: Float) -> Float {
        let clamped = max(0.0, min(volume, 1.0))
        let sessionReady = (audioSessionConfigured && audioSessionActive)
            ? true
            : configureAudioSession(forceActivate: true)
        guard sessionReady, let slider = ensureHiddenVolumeSlider() else {
            return currentSystemVolume()
        }
        let before = currentSystemVolume()
        slider.setValue(clamped, animated: false)
        slider.sendActions(for: [.valueChanged, .touchUpInside])
        let observed = currentSystemVolume()
        let confirmedNow = abs(observed - before) > 0.001 || abs(observed - clamped) <= 0.02
        let reported = confirmedNow ? observed : clamped

        volumeConfirmWorkItem?.cancel()
        let confirmWork = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.delegate?.avPlayerEngine(self, onSystemVolumeChanged: self.currentSystemVolume())
        }
        volumeConfirmWorkItem = confirmWork
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: confirmWork)
        return reported
    }

    // MARK: - Telemetry & Stop

    public func telemetrySnapshot() -> MarcoAvTelemetrySnapshot {
        let info = ProcessInfo.processInfo
        let routeName = activeAirPlayRouteName()
        let airPlayActive = (queuePlayer?.isExternalPlaybackActive ?? false) || routeName != nil
        let headroom = Self.potentialEdrHeadroom()
        return MarcoAvTelemetrySnapshot(
            thermalState: Self.thermalStateString(info.thermalState),
            thermalStateCode: Self.thermalStateCode(info.thermalState),
            physicalMemoryBytes: Int64(info.physicalMemory),
            processorCount: info.processorCount,
            machineIdentifier: Self.machineIdentifier(),
            supportsHdrDisplay: headroom > 1.05,
            potentialEdrHeadroom: headroom,
            isLowPowerMode: info.isLowPowerModeEnabled,
            isPipSupported: AVPictureInPictureController.isPictureInPictureSupported(),
            isPipPossible: pipController?.isPictureInPicturePossible ?? false,
            isPipActive: pipController?.isPictureInPictureActive ?? false,
            systemVolume: Double(currentSystemVolume()),
            isAirPlayActive: airPlayActive,
            airPlayDeviceName: routeName ?? ""
        )
    }

    public func currentPositionMs() -> Int64 {
        guard let player = queuePlayer else { return 0 }
        let sec = CMTimeGetSeconds(player.currentTime())
        guard sec.isFinite && sec >= 0 else { return 0 }
        return Int64((sec * 1000.0).rounded())
    }

    public func currentDurationMs() -> Int64 {
        guard let item = queuePlayer?.currentItem else { return 0 }
        let sec = CMTimeGetSeconds(item.duration)
        guard sec.isFinite && sec > 0 else { return 0 }
        return Int64((sec * 1000.0).rounded())
    }

    public func currentBufferedMs() -> Int64 {
        guard let item = queuePlayer?.currentItem,
              let range = item.loadedTimeRanges.first?.timeRangeValue
        else {
            return 0
        }
        let endSec = CMTimeGetSeconds(CMTimeAdd(range.start, range.duration))
        guard endSec.isFinite && endSec > 0 else { return 0 }
        return Int64((endSec * 1000.0).rounded())
    }

    public func stop() {
        performOnMain { [weak self] in
            guard let self = self else { return }
            let wasStartingPip = self.pipStarting
            let wasActivePip = self.pipController?.isPictureInPictureActive == true
            self.pipStarting = false
            self.currentSessionId += 1
            self.lastProgressPositionMs = -1
            self.lastProgressBufferedMs = -1
            self.lastProgressPlaying = false
            self.suppressNativeSubtitleRenderingRequested = false
            self.suppressNativeSubtitleAllowNonText = false
            self.selectedLegibleStaticFormat = .unknown
            self.legibleTrackConfirmedText = false
            self.legibleTrackConfirmedNonText = false
            self.legibleOutput?.suppressesPlayerRendering = false
            self.cleanupItemObservers()
            if let pip = self.pipController, wasActivePip {
                pip.stopPictureInPicture()
            } else if wasStartingPip {
                self.delegate?.avPlayerEngine(
                    self,
                    onPipStateChanged: false,
                    isPossible: false,
                    phase: "cancelled",
                    error: nil
                )
            }
            if #available(iOS 14.2, *) {
                self.pipController?.canStartPictureInPictureAutomaticallyFromInline = false
            }
            self.teardownPictureInPicture(detachSourceLayer: true)
            self.queuePlayer?.pause()
            self.queuePlayer?.removeAllItems()
            self.detachHiddenVolumeView()
            self.unregisterRemoteCommands()
            self.clearNowPlayingInfo()
            self.audioSessionActive = false
            self.state.isPlaying = false
            self.state.isBuffering = false
            self.state.isReady = false
            self.state.isPipActive = false
            self.state.isPipPossible = false
            self.emitPlaybackState()
        }
    }

    // MARK: - Internal Player & Audio Session Setup

    private func ensurePlayer() -> AVQueuePlayer {
        if let existing = queuePlayer {
            return existing
        }
        let player = AVQueuePlayer()
        player.automaticallyWaitsToMinimizeStalling = true
        player.preventsDisplaySleepDuringVideoPlayback = true
        player.allowsExternalPlayback = true
        player.usesExternalPlaybackWhileExternalScreenIsActive = true
        player.actionAtItemEnd = .pause
        player.volume = effectivePlayerVolume()

        externalPlaybackObservation = player.observe(\.isExternalPlaybackActive, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.emitAirPlayState()
            }
        }

        timeControlStatusObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] p, _ in
            let item = p.currentItem
            DispatchQueue.main.async {
                guard let self = self, let item = item, p.currentItem === item else { return }
                let playing = p.timeControlStatus == .playing
                let buffering = p.timeControlStatus == .waitingToPlayAtSpecifiedRate
                self.state.isPlaying = playing
                self.state.isBuffering = buffering
                self.state.rate = p.rate > 0 ? p.rate : self.requestedRate
                self.state.positionMs = self.currentPositionMs()
                self.state.durationMs = self.currentDurationMs()
                self.delegate?.avPlayerEngine(self, onBufferingChanged: buffering)
                self.emitPlaybackState()
                self.pushNowPlayingInfo(force: true)
            }
        }

        let interval = CMTime(seconds: 0.5, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] _ in
            self?.emitProgressTick()
        }

        queuePlayer = player
        return player
    }

    @discardableResult
    private func configureAudioSession(forceActivate: Bool = false) -> Bool {
        let session = AVAudioSession.sharedInstance()
        let desiredMode: AVAudioSession.Mode = (vocalLoudnessPreset == .cinemaVocal) ? .spokenAudio : .moviePlayback
        if !audioSessionConfigured || session.category != .playback || session.mode != desiredMode {
            do {
                try session.setCategory(.playback, mode: desiredMode, options: [])
                audioSessionConfigured = true
            } catch {
                audioSessionConfigured = false
            }
        }
        if forceActivate || !audioSessionActive {
            do {
                try session.setActive(true)
                audioSessionActive = true
            } catch {
                audioSessionActive = false
                return false
            }
        }
        return audioSessionActive
    }

    private func effectivePlayerVolume() -> Float {
        switch vocalLoudnessPreset {
        case .off:
            return requestedVolume
        case .light:
            return min(1.0, requestedVolume * 1.10)
        case .standard:
            return min(1.0, requestedVolume * 1.22)
        case .cinemaVocal:
            return min(1.0, requestedVolume * 1.32)
        }
    }

    private func applyAudioDialogueMixIfSupported(to item: AVPlayerItem) {
        let audioTracks = item.asset.tracks(withMediaType: .audio)
        guard !audioTracks.isEmpty else {
            item.audioMix = nil
            return
        }
        guard vocalLoudnessPreset != .off else {
            item.audioMix = nil
            return
        }
        let mix = AVMutableAudioMix()
        let gainFactor: Float = {
            switch vocalLoudnessPreset {
            case .off: return 1.0
            case .light: return 1.0
            case .standard: return 1.0
            case .cinemaVocal: return 1.0
            }
        }()
        mix.inputParameters = audioTracks.map { track in
            let params = AVMutableAudioMixInputParameters(track: track)
            params.setVolume(gainFactor, at: .zero)
            return params
        }
        item.audioMix = mix
    }

    private func teardownPictureInPicture(detachSourceLayer: Bool) {
        pipPossibleObservation?.invalidate()
        pipPossibleObservation = nil
        pipController?.delegate = nil
        pipController = nil
        if detachSourceLayer, let source = pipSourceLayer, source !== visiblePlayerLayer {
            source.player = nil
        }
        pipSourceLayer = nil
    }

    private func configurePictureInPicture(for layer: AVPlayerLayer) {
        if isPipActiveOrStarting {
            emitPipState()
            return
        }
        teardownPictureInPicture(detachSourceLayer: true)
        guard AVPictureInPictureController.isPictureInPictureSupported(),
              let controller = AVPictureInPictureController(playerLayer: layer)
        else {
            emitPipState()
            return
        }
        controller.delegate = self
        if #available(iOS 14.2, *) {
            controller.canStartPictureInPictureAutomaticallyFromInline = autoPipEnabled
        }
        pipSourceLayer = layer
        pipController = controller
        pipPossibleObservation = controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.emitPipState()
            }
        }
        emitPipState()
    }

    // MARK: - Lock Screen & Dynamic Island (MPNowPlayingInfoCenter + MPRemoteCommandCenter)

    private func registerRemoteCommandsIfNeeded() {
        guard !remoteCommandsRegistered else { return }
        remoteCommandsRegistered = true
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.isEnabled = true
        let playToken = center.playCommand.addTarget { [weak self] _ in
            self?.play()
            return .success
        }
        remoteCommandTokens.append((center.playCommand, playToken))

        center.pauseCommand.isEnabled = true
        let pauseToken = center.pauseCommand.addTarget { [weak self] _ in
            self?.pause()
            return .success
        }
        remoteCommandTokens.append((center.pauseCommand, pauseToken))

        center.togglePlayPauseCommand.isEnabled = true
        let toggleToken = center.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.togglePlayPause()
            return .success
        }
        remoteCommandTokens.append((center.togglePlayPauseCommand, toggleToken))

        center.skipForwardCommand.isEnabled = !isLiveStream
        center.skipForwardCommand.preferredIntervals = [15]
        let skipFwdToken = center.skipForwardCommand.addTarget { [weak self] _ in
            guard let self = self, !self.isLiveStream else { return .commandFailed }
            let target = self.currentPositionMs() + 15_000
            self.seek(toMs: target)
            return .success
        }
        remoteCommandTokens.append((center.skipForwardCommand, skipFwdToken))

        center.skipBackwardCommand.isEnabled = !isLiveStream
        center.skipBackwardCommand.preferredIntervals = [15]
        let skipBwdToken = center.skipBackwardCommand.addTarget { [weak self] _ in
            guard let self = self, !self.isLiveStream else { return .commandFailed }
            let target = max(0, self.currentPositionMs() - 15_000)
            self.seek(toMs: target)
            return .success
        }
        remoteCommandTokens.append((center.skipBackwardCommand, skipBwdToken))

        center.changePlaybackPositionCommand.isEnabled = !isLiveStream
        let scrubToken = center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self = self,
                  !self.isLiveStream,
                  let posEvent = event as? MPChangePlaybackPositionCommandEvent
            else {
                return .commandFailed
            }
            let targetMs = Int64((posEvent.positionTime * 1000.0).rounded())
            self.seek(toMs: targetMs)
            return .success
        }
        remoteCommandTokens.append((center.changePlaybackPositionCommand, scrubToken))

        center.nextTrackCommand.isEnabled = true
        let nextToken = center.nextTrackCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            self.delegate?.avPlayerEngineDidRequestNextTrack(self)
            return .success
        }
        remoteCommandTokens.append((center.nextTrackCommand, nextToken))

        center.previousTrackCommand.isEnabled = true
        let prevToken = center.previousTrackCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            self.delegate?.avPlayerEngineDidRequestPreviousTrack(self)
            return .success
        }
        remoteCommandTokens.append((center.previousTrackCommand, prevToken))
    }

    private func unregisterRemoteCommands() {
        guard remoteCommandsRegistered else { return }
        remoteCommandsRegistered = false
        for (command, token) in remoteCommandTokens {
            command.removeTarget(token)
        }
        remoteCommandTokens.removeAll()
    }

    private func pushNowPlayingInfo(force: Bool) {
        let now = CACurrentMediaTime()
        if !force && (now - lastNowPlayingPushTime) < 1.5 {
            return
        }
        lastNowPlayingPushTime = now

        let center = MPRemoteCommandCenter.shared()
        center.skipForwardCommand.isEnabled = !isLiveStream
        center.skipBackwardCommand.isEnabled = !isLiveStream
        center.changePlaybackPositionCommand.isEnabled = !isLiveStream

        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = nowPlayingTitle.isEmpty ? "Marco Movie" : nowPlayingTitle
        if !nowPlayingSubtitle.isEmpty {
            info[MPMediaItemPropertyArtist] = nowPlayingSubtitle
        }
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.video.rawValue
        info[MPNowPlayingInfoPropertyIsLiveStream] = isLiveStream

        let durSec = Double(currentDurationMs()) / 1000.0
        let posSec = Double(currentPositionMs()) / 1000.0
        if !isLiveStream && durSec > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = durSec
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = posSec
        }
        let effectiveRate: Double = state.isPlaying ? Double(queuePlayer?.rate ?? requestedRate) : 0.0
        info[MPNowPlayingInfoPropertyPlaybackRate] = effectiveRate
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = Double(requestedRate)

        if let artworkImage = nowPlayingPosterImage {
            let artwork = MPMediaItemArtwork(boundsSize: artworkImage.size) { _ in artworkImage }
            info[MPMediaItemPropertyArtwork] = artwork
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func clearNowPlayingInfo() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: - Observers & Item Lifecycle

    private func installGlobalObservers() {
        let center = NotificationCenter.default
        globalNotificationTokens.append(
            center.addObserver(
                forName: ProcessInfo.thermalStateDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self = self else { return }
                let thermal = ProcessInfo.processInfo.thermalState
                self.state.thermalState = thermal
                self.delegate?.avPlayerEngine(self, onThermalStateChanged: thermal)
            }
        )
        globalNotificationTokens.append(
            center.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.isAppForegroundActive = false
            }
        )
        globalNotificationTokens.append(
            center.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.isAppForegroundActive = true
            }
        )
        globalNotificationTokens.append(
            center.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self = self else { return }
                self.emitAirPlayState()
                self.delegate?.avPlayerEngine(self, onSystemVolumeChanged: self.currentSystemVolume())
            }
        )
        globalNotificationTokens.append(
            center.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: nil,
                queue: .main
            ) { [weak self] notif in
                guard let rawType = notif.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      let type = AVAudioSession.InterruptionType(rawValue: rawType)
                else { return }
                if type == .began {
                    self?.audioSessionActive = false
                }
            }
        )
        systemVolumeObservation = AVAudioSession.sharedInstance().observe(
            \.outputVolume,
            options: [.new]
        ) { [weak self] session, _ in
            let vol = max(0.0, min(session.outputVolume, 1.0))
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.delegate?.avPlayerEngine(self, onSystemVolumeChanged: vol)
            }
        }
    }

    private func observePlayerItem(_ item: AVPlayerItem, sessionId: Int) {
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] observedItem, _ in
            DispatchQueue.main.async {
                guard let self = self, self.currentSessionId == sessionId else { return }
                switch observedItem.status {
                case .readyToPlay:
                    self.state.isReady = true
                    self.state.isBuffering = false
                    if self.pendingStartPositionMs > 0 && !self.isLiveStream {
                        let seekTarget = CMTime(value: CMTimeValue(self.pendingStartPositionMs), timescale: 1000)
                        self.pendingStartPositionMs = 0
                        self.queuePlayer?.seek(to: seekTarget, toleranceBefore: .zero, toleranceAfter: .zero)
                    }
                    self.applyAudioDialogueMixIfSupported(to: observedItem)
                    self.inspectPlayabilityAndHdr(for: observedItem, sessionId: sessionId)
                    self.refreshSelectedLegibleTrackCapability(for: observedItem)
                    self.applyEffectiveLegibleSuppression()

                    self.state.durationMs = self.currentDurationMs()
                    self.state.positionMs = self.currentPositionMs()
                    self.state.videoSize = observedItem.presentationSize
                    self.state.isHdr = self.isHdrItem(observedItem)
                    self.state.potentialEdrHeadroom = Self.potentialEdrHeadroom()

                    self.delegate?.avPlayerEngine(self, onBufferingChanged: false)
                    self.delegate?.avPlayerEngine(
                        self,
                        onTracksUpdated: self.readMediaSelectionTracks(characteristic: .audible),
                        subtitleTracks: self.readMediaSelectionTracks(characteristic: .legible)
                    )
                    self.emitPlaybackState()
                    self.pushNowPlayingInfo(force: true)

                case .failed:
                    let message = observedItem.error?.localizedDescription ?? "AVPlayerItem 播放失败"
                    self.triggerFallbackToMpv(reason: message)

                case .unknown:
                    break

                @unknown default:
                    break
                }
            }
        }

        presentationSizeObservation = item.observe(\.presentationSize, options: [.new]) { [weak self] observedItem, _ in
            DispatchQueue.main.async {
                guard let self = self, self.currentSessionId == sessionId else { return }
                let size = observedItem.presentationSize
                if size.width > 0 && size.height > 0 {
                    self.state.videoSize = size
                    self.state.isHdr = self.isHdrItem(observedItem)
                    self.emitPlaybackState()
                }
            }
        }

        likelyToKeepUpObservation = item.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { [weak self] observedItem, _ in
            DispatchQueue.main.async {
                guard let self = self, self.currentSessionId == sessionId else { return }
                let buffering = !observedItem.isPlaybackLikelyToKeepUp
                self.state.isBuffering = buffering
                self.delegate?.avPlayerEngine(self, onBufferingChanged: buffering)
            }
        }

        bufferEmptyObservation = item.observe(\.isPlaybackBufferEmpty, options: [.new]) { [weak self] observedItem, _ in
            DispatchQueue.main.async {
                guard let self = self, self.currentSessionId == sessionId else { return }
                if observedItem.isPlaybackBufferEmpty {
                    self.state.isBuffering = true
                    self.delegate?.avPlayerEngine(self, onBufferingChanged: true)
                }
            }
        }

        let center = NotificationCenter.default
        itemNotificationTokens.append(
            center.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak self] _ in
                guard let self = self, self.currentSessionId == sessionId else { return }
                self.state.isPlaying = false
                self.state.positionMs = self.currentDurationMs()
                self.emitPlaybackState()
                self.pushNowPlayingInfo(force: true)
                self.delegate?.avPlayerEngineDidComplete(self)
            }
        )

        itemNotificationTokens.append(
            center.addObserver(
                forName: .AVPlayerItemFailedToPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak self] notif in
                guard let self = self, self.currentSessionId == sessionId else { return }
                let err = notif.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError
                self.triggerFallbackToMpv(reason: err?.localizedDescription ?? "流媒体播放中断")
            }
        )
    }

    private func inspectPlayabilityAndHdr(for item: AVPlayerItem, sessionId: Int) {
        let asset = item.asset
        asset.loadValuesAsynchronously(forKeys: ["playable", "tracks"]) { [weak self] in
            DispatchQueue.main.async {
                guard let self = self, self.currentSessionId == sessionId else { return }
                var err: NSError?
                if asset.statusOfValue(forKey: "playable", error: &err) == .loaded, !asset.isPlayable {
                    self.triggerFallbackToMpv(reason: err?.localizedDescription ?? "AVPlayer 无法解码此视频容器")
                    return
                }
                let audioTracks = asset.tracks(withMediaType: .audio)
                let hasDisabledAudio = !audioTracks.isEmpty && audioTracks.allSatisfy { !$0.isPlayable }
                if hasDisabledAudio {
                    self.triggerFallbackToMpv(reason: "AVPlayer 不支持当前音轨编码")
                }
            }
        }
    }

    private func isHdrItem(_ item: AVPlayerItem) -> Bool {
        for track in item.asset.tracks(withMediaType: .video) {
            if track.hasMediaCharacteristic(.containsHDRVideo) {
                return true
            }
        }
        return false
    }

    private func triggerFallbackToMpv(reason: String) {
        guard !fallbackEmittedForCurrentItem else { return }
        fallbackEmittedForCurrentItem = true
        let posMs = max(pendingStartPositionMs, currentPositionMs())
        queuePlayer?.pause()
        state.isPlaying = false
        state.isBuffering = false
        emitPlaybackState()
        delegate?.avPlayerEngine(self, onFallbackToMpv: posMs, reason: reason)
    }

    private func cleanupItemObservers() {
        if let output = legibleOutput {
            output.setDelegate(nil, queue: nil)
            legibleOutputItem?.remove(output)
        }
        legibleOutput = nil
        legibleOutputItem = nil
        lastLegibleLines = []
        statusObservation?.invalidate()
        statusObservation = nil
        likelyToKeepUpObservation?.invalidate()
        likelyToKeepUpObservation = nil
        bufferEmptyObservation?.invalidate()
        bufferEmptyObservation = nil
        presentationSizeObservation?.invalidate()
        presentationSizeObservation = nil
        let center = NotificationCenter.default
        for token in itemNotificationTokens {
            center.removeObserver(token)
        }
        itemNotificationTokens.removeAll()
    }

    private func cleanupPlaybackObservers() {
        cleanupItemObservers()
        timeControlStatusObservation?.invalidate()
        timeControlStatusObservation = nil
        externalPlaybackObservation?.invalidate()
        externalPlaybackObservation = nil
        pipPossibleObservation?.invalidate()
        pipPossibleObservation = nil
        if let token = timeObserverToken, let player = queuePlayer {
            player.removeTimeObserver(token)
        }
        timeObserverToken = nil
    }

    // MARK: - Media Selection & Legible Subtitles

    private func classifyLegibleOption(_ option: AVMediaSelectionOption, in item: AVPlayerItem) -> LegibleTrackFormatKind {
        if option.mediaType == .closedCaption || option.mediaType == .text {
            return .text
        }
        let textSubTypes: Set<FourCharCode> = [
            0x74783367, 0x77767474, 0x74657874, 0x73747070,
            0x63363038, 0x63373038, 0x61743638, 0x73727420,
            0x73736120, 0x61737320,
        ]
        let bitmapSubTypes: Set<FourCharCode> = [
            0x64766220, 0x70677373, 0x73756270, 0x6D703473,
            0x766F6220, 0x68646D76, 0x64766473,
        ]
        let optionSubTypes: [FourCharCode] = option.mediaSubTypes.map { $0.uint32Value }
        if !optionSubTypes.isEmpty {
            if optionSubTypes.contains(where: { textSubTypes.contains($0) }) { return .text }
            if optionSubTypes.contains(where: { bitmapSubTypes.contains($0) }) { return .bitmap }
        }
        let nameLower = option.displayName.lowercased()
        if nameLower.contains("pgs") || nameLower.contains("vobsub") || nameLower.contains("dvb")
            || nameLower.contains("bitmap") || nameLower.contains("dvdsub") || nameLower.contains("hdmv")
        {
            return .bitmap
        }
        if nameLower.contains("webvtt") || nameLower.contains("vtt") || nameLower.contains("srt")
            || nameLower.contains("tx3g") || nameLower.contains("closed caption") || nameLower.contains("ttml")
        {
            return .text
        }
        let optionLang = (option.locale?.identifier ?? option.extendedLanguageTag ?? "").lowercased()
        var sawText = false
        var sawBitmap = false
        var sawUnknown = false
        for track in item.asset.tracks(withMediaType: .subtitle) {
            let trackLang = (track.extendedLanguageTag ?? track.languageCode ?? "").lowercased()
            if !optionLang.isEmpty && !trackLang.isEmpty
                && !optionLang.hasPrefix(trackLang) && !trackLang.hasPrefix(optionLang)
            {
                continue
            }
            var trackHasFormat = false
            for rawDesc in track.formatDescriptions {
                trackHasFormat = true
                let cfObj = rawDesc as CFTypeRef
                if CFGetTypeID(cfObj) == CMFormatDescriptionGetTypeID() {
                    let desc = rawDesc as! CMFormatDescription
                    let subType = CMFormatDescriptionGetMediaSubType(desc)
                    if bitmapSubTypes.contains(subType) {
                        sawBitmap = true
                    } else if textSubTypes.contains(subType) {
                        sawText = true
                    } else {
                        sawUnknown = true
                    }
                } else {
                    sawUnknown = true
                }
            }
            if !trackHasFormat { sawUnknown = true }
        }
        if sawBitmap && !sawText && !sawUnknown { return .bitmap }
        if sawText && !sawBitmap && !sawUnknown { return .text }
        return .unknown
    }

    private func refreshSelectedLegibleTrackCapability(for item: AVPlayerItem) {
        guard let group = item.asset.mediaSelectionGroup(forMediaCharacteristic: .legible),
              let selected = item.currentMediaSelection.selectedMediaOption(in: group)
        else {
            selectedLegibleStaticFormat = .unknown
            return
        }
        selectedLegibleStaticFormat = classifyLegibleOption(selected, in: item)
        switch selectedLegibleStaticFormat {
        case .bitmap:
            legibleTrackConfirmedNonText = true
            legibleTrackConfirmedText = false
        case .text, .unknown:
            if !lastLegibleHasNativeSamples {
                legibleTrackConfirmedNonText = false
            }
        }
    }

    private func readMediaSelectionTracks(characteristic: AVMediaCharacteristic) -> [MarcoMediaTrack] {
        guard let item = queuePlayer?.currentItem,
              let group = item.asset.mediaSelectionGroup(forMediaCharacteristic: characteristic)
        else {
            return []
        }
        let selected = item.currentMediaSelection.selectedMediaOption(in: group)
        return group.options.enumerated().map { idx, option in
            let lang = option.locale?.identifier ?? option.extendedLanguageTag ?? ""
            var isBitmap = false
            if characteristic == .legible {
                var kind = classifyLegibleOption(option, in: item)
                if option == selected {
                    if legibleTrackConfirmedText { kind = .text }
                    else if legibleTrackConfirmedNonText { kind = .bitmap }
                }
                isBitmap = (kind == .bitmap)
            }
            return MarcoMediaTrack(
                id: "\(idx)",
                title: option.displayName,
                language: lang,
                isSelected: option == selected,
                isBitmapSubtitle: isBitmap
            )
        }
    }

    private func selectMediaTrack(characteristic: AVMediaCharacteristic, trackId: String?) {
        guard let item = queuePlayer?.currentItem,
              let group = item.asset.mediaSelectionGroup(forMediaCharacteristic: characteristic)
        else {
            return
        }
        if trackId == nil || trackId == "off" || trackId == "no" {
            if group.allowsEmptySelection {
                item.select(nil, in: group)
            }
            if characteristic == .legible {
                selectedLegibleStaticFormat = .unknown
                legibleTrackConfirmedText = false
                legibleTrackConfirmedNonText = false
                clearLegibleSubtitleState(forceEmit: true)
                applyEffectiveLegibleSuppression()
            }
            delegate?.avPlayerEngine(
                self,
                onTracksUpdated: readMediaSelectionTracks(characteristic: .audible),
                subtitleTracks: readMediaSelectionTracks(characteristic: .legible)
            )
            return
        }
        if let rawId = trackId, let idx = Int(rawId), idx >= 0 && idx < group.options.count {
            item.select(group.options[idx], in: group)
            if characteristic == .legible {
                selectedLegibleStaticFormat = .unknown
                legibleTrackConfirmedText = false
                legibleTrackConfirmedNonText = false
                clearLegibleSubtitleState(forceEmit: true)
                refreshSelectedLegibleTrackCapability(for: item)
                applyEffectiveLegibleSuppression()
            }
            delegate?.avPlayerEngine(
                self,
                onTracksUpdated: readMediaSelectionTracks(characteristic: .audible),
                subtitleTracks: readMediaSelectionTracks(characteristic: .legible)
            )
        }
    }

    private func applyEffectiveLegibleSuppression() {
        let liveTextTrackReady = !legibleTrackConfirmedNonText
            && (legibleTrackConfirmedText || selectedLegibleStaticFormat == .text)
        let shouldSuppress = suppressNativeSubtitleRenderingRequested
            && !isPipActiveOrStarting
            && (suppressNativeSubtitleAllowNonText || liveTextTrackReady)
        legibleOutput?.suppressesPlayerRendering = shouldSuppress
    }

    private func clearLegibleSubtitleState(forceEmit: Bool = false) {
        if forceEmit || !lastLegibleLines.isEmpty || lastLegibleHasNativeSamples {
            lastLegibleLines = []
            lastLegibleHasNativeSamples = false
            delegate?.avPlayerEngine(self, onSubtitleCue: [], hasNativeSamples: false)
        }
    }

    // MARK: - AVPlayerItemLegibleOutputPushDelegate

    public func legibleOutput(
        _ output: AVPlayerItemLegibleOutput,
        didOutputAttributedStrings strings: [NSAttributedString],
        nativeSampleBuffers nativeSamples: [Any],
        forItemTime itemTime: CMTime
    ) {
        guard output === legibleOutput else { return }
        let lines = strings
            .map { $0.string.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let hasNativeSamples = !nativeSamples.isEmpty
        let prevText = legibleTrackConfirmedText
        let prevNonText = legibleTrackConfirmedNonText
        if !lines.isEmpty {
            legibleTrackConfirmedText = true
            legibleTrackConfirmedNonText = false
            applyEffectiveLegibleSuppression()
        } else if hasNativeSamples {
            legibleTrackConfirmedNonText = true
            legibleTrackConfirmedText = false
            applyEffectiveLegibleSuppression()
        }
        if legibleTrackConfirmedText != prevText || legibleTrackConfirmedNonText != prevNonText {
            delegate?.avPlayerEngine(
                self,
                onTracksUpdated: readMediaSelectionTracks(characteristic: .audible),
                subtitleTracks: readMediaSelectionTracks(characteristic: .legible)
            )
        }
        if lines == lastLegibleLines && hasNativeSamples == lastLegibleHasNativeSamples {
            return
        }
        lastLegibleLines = lines
        lastLegibleHasNativeSamples = hasNativeSamples
        delegate?.avPlayerEngine(self, onSubtitleCue: lines, hasNativeSamples: hasNativeSamples)
    }

    public func outputSequenceWasFlushed(_ output: AVPlayerItemOutput) {
        guard let legible = output as? AVPlayerItemLegibleOutput, legible === legibleOutput else { return }
        clearLegibleSubtitleState(forceEmit: true)
    }

    // MARK: - AVPictureInPictureControllerDelegate

    public func pictureInPictureControllerWillStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        pipStarting = true
        applyEffectiveLegibleSuppression()
        emitPipState(phase: "willStart")
    }

    public func pictureInPictureControllerDidStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        pipStarting = false
        if cancelPendingPipStart {
            cancelPendingPipStart = false
            pictureInPictureController.stopPictureInPicture()
            applyEffectiveLegibleSuppression()
            emitPipState(phase: "cancelled")
            return
        }
        applyEffectiveLegibleSuppression()
        emitPipState(phase: "didStart")
    }

    public func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        pipStarting = false
        cancelPendingPipStart = false
        applyEffectiveLegibleSuppression()
        if pipSourceLayer !== visiblePlayerLayer {
            teardownPictureInPicture(detachSourceLayer: true)
            if let currentVisible = visiblePlayerLayer {
                configurePictureInPicture(for: currentVisible)
            }
        }
        state.isPipActive = false
        state.isPipPossible = pipController?.isPictureInPicturePossible ?? false
        delegate?.avPlayerEngine(
            self,
            onPipStateChanged: false,
            isPossible: state.isPipPossible,
            phase: "failed",
            error: error.localizedDescription
        )
    }

    public func pictureInPictureControllerWillStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        pipStarting = false
        applyEffectiveLegibleSuppression()
        emitPipState(phase: "willStop")
    }

    public func pictureInPictureControllerDidStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        pipStarting = false
        applyEffectiveLegibleSuppression()
        if pipSourceLayer !== visiblePlayerLayer {
            teardownPictureInPicture(detachSourceLayer: true)
            if let currentVisible = visiblePlayerLayer {
                configurePictureInPicture(for: currentVisible)
            }
        }
        emitPipState(phase: "didStop")
    }

    public func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        delegate?.avPlayerEngineDidRequestPipRestoreForeground(self)
        completionHandler(true)
    }

    // MARK: - Internal Helpers

    private func emitPipState(phase: String = "update") {
        let active = pipController?.isPictureInPictureActive ?? false
        let possible = pipController?.isPictureInPicturePossible ?? false
        state.isPipSupported = AVPictureInPictureController.isPictureInPictureSupported()
        state.isPipActive = active
        state.isPipPossible = possible
        delegate?.avPlayerEngine(
            self,
            onPipStateChanged: active,
            isPossible: possible,
            phase: phase,
            error: nil
        )
    }

    private func activeAirPlayRouteName() -> String? {
        for output in AVAudioSession.sharedInstance().currentRoute.outputs where output.portType == .airPlay {
            return output.portName
        }
        return nil
    }

    private func emitAirPlayState() {
        let routeName = activeAirPlayRouteName()
        let active = (queuePlayer?.isExternalPlaybackActive ?? false) || routeName != nil
        state.isAirPlayActive = active
        state.airPlayDeviceName = routeName ?? ""
        delegate?.avPlayerEngine(self, onAirPlayChanged: active, deviceName: routeName ?? "")
    }

    private func emitProgressTick() {
        guard let player = queuePlayer, player.currentItem != nil else { return }
        if !isAppForegroundActive && !isPipActiveOrStarting {
            return
        }
        let playing = player.timeControlStatus == .playing
        let posMs = currentPositionMs()
        let durMs = currentDurationMs()
        let bufMs = currentBufferedMs()
        if !playing && !lastProgressPlaying
            && posMs == lastProgressPositionMs
            && bufMs == lastProgressBufferedMs
        {
            return
        }
        lastProgressPlaying = playing
        lastProgressPositionMs = posMs
        lastProgressBufferedMs = bufMs
        state.positionMs = posMs
        state.durationMs = durMs
        state.bufferedMs = bufMs
        state.isPlaying = playing
        delegate?.avPlayerEngine(self, onPositionUpdate: posMs, durationMs: durMs, bufferedMs: bufMs)
        pushNowPlayingInfo(force: false)
    }

    private func emitPlaybackState() {
        delegate?.avPlayerEngine(self, onPlaybackStateChanged: state)
    }

    private func findSlider(in view: UIView) -> UISlider? {
        for sub in view.subviews {
            if let slider = sub as? UISlider { return slider }
            if let nested = findSlider(in: sub) { return nested }
        }
        return nil
    }

    private func ensureHiddenVolumeSlider() -> UISlider? {
        let volumeView: MPVolumeView
        if let existing = hiddenVolumeView {
            volumeView = existing
        } else {
            let created = MPVolumeView(frame: CGRect(x: -2000.0, y: -2000.0, width: 1.0, height: 1.0))
            created.showsVolumeSlider = true
            created.alpha = 0.01
            created.isUserInteractionEnabled = false
            hiddenVolumeView = created
            volumeView = created
        }
        if volumeView.superview == nil, let window = Self.activeKeyWindow() {
            window.addSubview(volumeView)
            volumeView.layoutIfNeeded()
        }
        return findSlider(in: volumeView)
    }

    private func detachHiddenVolumeView() {
        volumeConfirmWorkItem?.cancel()
        volumeConfirmWorkItem = nil
        let viewToRemove = hiddenVolumeView
        hiddenVolumeView = nil
        guard let view = viewToRemove else { return }
        if Thread.isMainThread {
            view.removeFromSuperview()
        } else {
            DispatchQueue.main.async {
                view.removeFromSuperview()
            }
        }
    }

    private func performOnMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }
}
