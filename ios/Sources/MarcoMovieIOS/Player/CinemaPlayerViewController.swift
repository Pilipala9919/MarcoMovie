// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
// Marco Movie iOS — Dual-Engine Cinema Player View Controller
// Orchestrates AVPlayer (low-power PiP/AirPlay/Now Playing) + libmpv Metal (Anime4K/ASS/HDR/lavfi),
// 120Hz DanmakuMetalLayerView, Apple TV+ / Infuse 8 Liquid Glass HUD, Gesture State Machine,
// 3s Cancellable Skip Intro/Outro, Sleep Timer (30s Warning), DLNA Cast, and Magic Keyboard Shortcuts.

import AVFoundation
import AVKit
import Darwin
import Foundation
import MarcoIOSCore
import MediaPlayer
import UIKit

#if canImport(MarcoNativeBridges)
import MarcoNativeBridges
#endif

// MARK: - Public Launch Context Contract

public struct CinemaPlayerLaunchContext {
    public let video: CmsVideo
    public let site: CmsSite?
    public let lines: [CmsLine]
    public let initialLineIndex: Int
    public let initialEpisodeIndex: Int
    public let startPositionMs: Int64
    public let isLive: Bool
    public let isPrivate: Bool
    public let liveChannelName: String?
    public let directStreamURL: String?
    public let directHeaders: [String: String]
    public let demoPreviewMode: Bool

    public init(
        video: CmsVideo,
        site: CmsSite? = nil,
        lines: [CmsLine] = [],
        initialLineIndex: Int = 0,
        initialEpisodeIndex: Int = 0,
        startPositionMs: Int64 = 0,
        isLive: Bool = false,
        isPrivate: Bool = false,
        liveChannelName: String? = nil,
        directStreamURL: String? = nil,
        directHeaders: [String: String] = [:],
        demoPreviewMode: Bool = false
    ) {
        self.video = video
        self.site = site
        self.lines = lines
        self.initialLineIndex = max(0, initialLineIndex)
        self.initialEpisodeIndex = max(0, initialEpisodeIndex)
        self.startPositionMs = max(0, startPositionMs)
        self.isLive = isLive
        self.isPrivate = isPrivate
        self.liveChannelName = liveChannelName
        self.directStreamURL = directStreamURL
        self.directHeaders = directHeaders
        self.demoPreviewMode = demoPreviewMode
    }
}

// MARK: - Sleep Timer Mode

private enum CinemaSleepTimerMode: Equatable {
    case off
    case countdown(remainingSeconds: Int)
    case endOfEpisode

    var isActive: Bool {
        if case .off = self { return false }
        return true
    }
}

// MARK: - Cinema Player View Controller

public final class CinemaPlayerViewController: UIViewController,
    MarcoAvPlayerEngineDelegate,
    MarcoMpvMetalViewDelegate,
    UIGestureRecognizerDelegate
{
    // MARK: Dependencies & Context

    private let context: CinemaPlayerLaunchContext
    private let cmsClient: CmsClient
    private let storage: IOSStorageManager
    private let danmuService: DanmuService
    private let castService: CastService
    private let onPlaybackStateChanged: ((Int, Int, Int64, Int64) -> Void)?

    private var lines: [CmsLine]
    private var currentLineIndex: Int
    private var currentEpisodeIndex: Int

    // MARK: Dual Engines & Proxies

    private let avLayerView = MarcoAvPlayerLayerView()
    private let avEngine = MarcoAvPlayerEngine()
    private let mpvMetalView = MarcoMpvMetalView()
    private let danmakuView = DanmakuMetalLayerView()
    private let demoBackdropView = CinemaDemoBackdropView()

    private let headerProxy = LocalHeaderProxyServer()
    private let rangeProxy = NetdiskRangeProxyServer()
    private var activeOfflineHlsLease: OfflineHlsLease?
    private var activeHeaderProxySessionId: String?
    private var activeRangeProxyResourceId: String?

    private var activeEngineMode: IosPlaybackEngineMode = .avplayer
    private var currentResolvedURL: URL?
    private var currentResolvedHeaders: [String: String] = [:]
    private var currentResolutionBadge: String = ""
    private var hasFallbackOccurredForCurrentLoad = false

    // MARK: Playback & Settings State

    private var isPlaying = false
    private var isBuffering = false
    private var isScrubbing = false
    private var currentPositionMs: Int64 = 0
    private var currentDurationMs: Int64 = 0
    private var currentBufferedMs: Int64 = 0
    private var currentRate: Float = 1.0
    private var aspectMode: MarcoVideoAspectMode = .fit
    private var anime4kEnabled = false
    private var vocalLoudness: VocalLoudnessPreset = .off
    private var hdrToneMapping: IosHdrToneMappingMode = .auto
    private var showRemainingTime = false
    private var danmuSettings = DanmuSettings()
    private var audioTracks: [MarcoMediaTrack] = []
    private var subtitleTracks: [MarcoMediaTrack] = []
    private var posterImageToken: PosterImageLoadToken?
    private var loadedPosterImage: UIImage?

    private var resolveTask: Task<Void, Never>?
    private var danmuTask: Task<Void, Never>?
    private var lastHistoryPersistTime: CFTimeInterval = 0
    private var isDismissing = false

    // Demo preview simulation
    private var demoTimer: Timer?
    private var demoSimulatedPosMs: Int64 = 504_000 // 08:24
    private let demoSimulatedDurationMs: Int64 = 2_520_000 // 42:00

    // MARK: HUD, Gesture & Overlay State

    private var isHudVisible = true
    private var isScreenLocked = false
    private var hudAutoHideWorkItem: DispatchWorkItem?
    private var toastHideWorkItem: DispatchWorkItem?
    private var preferredOrientationMask: UIInterfaceOrientationMask = .allButUpsideDown

    private enum PanGestureAxis {
        case undecided
        case horizontalSeek
        case verticalBrightness
        case verticalVolume
    }

    private var panAxis: PanGestureAxis = .undecided
    private var panStartPositionMs: Int64 = 0
    private var panTargetPositionMs: Int64 = 0
    private var panStartBrightness: CGFloat = 0.5
    private var panStartVolume: Float = 0.5
    private var rateBeforeLongPress: Float?

    // Skip Intro / Outro State
    private var privateMemorySkipRecord: VideoSkipRecord?
    private var introHandledForEpisode = false
    private var outroHandledForEpisode = false
    private var skipCountdownTimer: Timer?
    private var skipCountdownRemainingSec = 0
    private var skipBannerKind: SkipBannerKind?

    private enum SkipBannerKind {
        case intro(targetMs: Int64)
        case outro
    }

    // Sleep Timer State
    private var sleepTimerMode: CinemaSleepTimerMode = .off
    private var sleepTickTimer: Timer?
    private var clockUpdateTimer: Timer?

    // MARK: UI Hierarchy

    private let stageContainer = UIView()
    private let gestureOverlayView = UIView()
    private let subtitleBackdropView = UIView()
    private let subtitleLabel = UILabel()

    private let topScrimLayer = CAGradientLayer()
    private let bottomScrimLayer = CAGradientLayer()

    private let hudContainerView = UIView()
    private let topBarSurface = MarcoGlassSurfaceView(style: .chrome, cornerRadius: 20, isInteractive: true)
    private let bottomBarSurface = MarcoGlassSurfaceView(style: .chrome, cornerRadius: 22, isInteractive: true)

    // Top bar controls
    private let closeButton = CinemaHudButton(symbolName: "chevron.backward", pointSize: 15, diameter: 34)
    private let topTitleStack = UIStackView()
    private let titleLabel = UILabel()
    private let subtitleMetaLabel = UILabel()
    private let topRightControlsStack = UIStackView()
    private let clockLabel = UILabel()
    private let engineSwitchButton = CinemaHudPillButton(title: "AVPlayer", symbolName: "play.tv")
    private let pipButton = CinemaHudButton(symbolName: "pip.enter", pointSize: 14, diameter: 34)
    private let airplayContainer = UIView()
    private lazy var airPlayPickerView: AVRoutePickerView = avEngine.makeAirPlayRoutePickerView(
        tintColor: .white,
        activeTintColor: MarcoColors.accentTint
    )
    private let castButton = CinemaHudButton(symbolName: "tv.badge.wifi", pointSize: 14, diameter: 34)
    private let moreMenuButton = CinemaHudButton(symbolName: "ellipsis.circle", pointSize: 15, diameter: 34)
    private var lastCompactHudLayout: Bool?

    // Center transport controls
    private let centerTransportStack = UIStackView()
    private let skipBackwardButton = CinemaHudButton(symbolName: "gobackward.15", pointSize: 22, diameter: 48)
    private let centerPlayPauseButton = CinemaCenterPlayButton()
    private let skipForwardButton = CinemaHudButton(symbolName: "goforward.15", pointSize: 22, diameter: 48)
    private let lockToggleButton = CinemaHudButton(symbolName: "lock.open", pointSize: 16, diameter: 44)
    private let bufferingContainer = MarcoGlassSurfaceView(style: .capsule, cornerRadius: 20)
    private let bufferingIndicator = UIActivityIndicatorView(style: .medium)
    private let bufferingLabel = UILabel()

    // Bottom bar controls
    private let scrubberContainer = UIView()
    private let elapsedTimeLabel = UILabel()
    private let remainingTimeLabel = UILabel()
    private let bufferedProgressView = UIProgressView(progressViewStyle: .default)
    private let progressSlider = UISlider()
    private let liveBadgeView = UIView()
    private let liveDotView = UIView()
    private let liveStatusLabel = UILabel()

    private let bottomActionsScroll = UIScrollView()
    private let bottomActionsStack = UIStackView()
    private let nextEpisodeButton = CinemaHudPillButton(title: "下一集", symbolName: "forward.end.fill")
    private let speedButton = CinemaHudPillButton(title: "1.0x", symbolName: "gauge.medium")
    private let episodesButton = CinemaHudPillButton(title: "选集", symbolName: "list.bullet.rectangle")
    private let linesButton = CinemaHudPillButton(title: "线路", symbolName: "arrow.triangle.branch")
    private let danmakuToggleButton = CinemaHudPillButton(title: "弹幕", symbolName: "captions.bubble")
    private let danmakuSettingsButton = CinemaHudButton(symbolName: "slider.horizontal.3", pointSize: 14, diameter: 34)
    private let tracksButton = CinemaHudPillButton(title: "音轨/字幕", symbolName: "waveform")
    private let orientationButton = CinemaHudButton(symbolName: "rotate.right", pointSize: 14, diameter: 34)

    // Floating Pills & Banners
    private let gestureHudSurface = MarcoGlassSurfaceView(style: .capsule, cornerRadius: 20)
    private let gestureHudIconView = UIImageView()
    private let gestureHudLabel = UILabel()
    private let gestureHudBarTrack = UIView()
    private let gestureHudBarFill = UIView()
    private var gestureHudBarFillWidthConstraint: NSLayoutConstraint?

    private let longPressPill = MarcoGlassSurfaceView(style: .capsule, cornerRadius: 18)
    private let longPressLabel = UILabel()

    private let toastPill = MarcoGlassSurfaceView(style: .capsule, cornerRadius: 18)
    private let toastLabel = UILabel()

    private let skipBannerSurface = MarcoGlassSurfaceView(style: .chrome, cornerRadius: 18, isInteractive: true)
    private let skipBannerLabel = UILabel()
    private let skipNowButton = UIButton(type: .system)
    private let skipCancelButton = UIButton(type: .system)

    private let sleepBannerSurface = MarcoGlassSurfaceView(style: .chrome, cornerRadius: 18, isInteractive: true)
    private let sleepBannerLabel = UILabel()
    private let sleepExtendButton = UIButton(type: .system)
    private let sleepCancelButton = UIButton(type: .system)

    private let errorOverlaySurface = MarcoGlassSurfaceView(style: .chrome, cornerRadius: 20, isInteractive: true)
    private let errorTitleLabel = UILabel()
    private let errorDetailLabel = UILabel()
    private let errorRetryButton = MarcoPrimaryButton(title: "重试播放", symbolName: "arrow.clockwise", appearance: .heroWhite)
    private let errorSwitchLineButton = MarcoSecondaryGlassButton(title: "切换线路", symbolName: "arrow.triangle.branch", tone: .onDarkBackdrop)

    // MARK: - Initializer

    public init(
        context: CinemaPlayerLaunchContext,
        cmsClient: CmsClient,
        storage: IOSStorageManager,
        danmuService: DanmuService,
        castService: CastService,
        onPlaybackStateChanged: ((Int, Int, Int64, Int64) -> Void)? = nil
    ) {
        self.context = context
        self.cmsClient = cmsClient
        self.storage = storage
        self.danmuService = danmuService
        self.castService = castService
        self.onPlaybackStateChanged = onPlaybackStateChanged

        let resolvedLines = context.lines.isEmpty ? context.video.lines : context.lines
        self.lines = resolvedLines
        self.currentLineIndex = resolvedLines.isEmpty ? 0 : min(max(0, context.initialLineIndex), resolvedLines.count - 1)
        if !resolvedLines.isEmpty {
            let eps = resolvedLines[self.currentLineIndex].episodes
            self.currentEpisodeIndex = eps.isEmpty ? 0 : min(max(0, context.initialEpisodeIndex), eps.count - 1)
        } else {
            self.currentEpisodeIndex = 0
        }

        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
        modalPresentationCapturesStatusBarAppearance = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        teardownAllResources()
    }

    // MARK: - View Controller Overrides

    public override var prefersStatusBarHidden: Bool {
        true
    }

    public override var prefersHomeIndicatorAutoHidden: Bool {
        !isHudVisible
    }

    public override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        preferredOrientationMask
    }

    public override var canBecomeFirstResponder: Bool {
        true
    }

    public override var keyCommands: [UIKeyCommand]? {
        let specs: [(input: String, title: String, selector: Selector)] = [
            (" ", "播放 / 暂停", #selector(handleKeyTogglePlayPause)),
            (UIKeyCommand.inputLeftArrow, "快退 10 秒", #selector(handleKeySeekBackward)),
            (UIKeyCommand.inputRightArrow, "快进 10 秒", #selector(handleKeySeekForward)),
            (UIKeyCommand.inputUpArrow, "增大音量", #selector(handleKeyVolumeUp)),
            (UIKeyCommand.inputDownArrow, "减小音量", #selector(handleKeyVolumeDown)),
            (UIKeyCommand.inputEscape, "退出播放", #selector(handleKeyClose)),
            ("d", "开关弹幕", #selector(handleKeyToggleDanmaku)),
            ("e", "打开选集", #selector(handleKeyOpenEpisodes)),
        ]
        return specs.map { spec in
            let cmd = UIKeyCommand(input: spec.input, modifierFlags: [], action: spec.selector)
            cmd.discoverabilityTitle = spec.title
            if #available(iOS 15.0, *) {
                cmd.wantsPriorityOverSystemBehavior = true
            }
            return cmd
        }
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = .dark
        view.backgroundColor = .black

        loadPreferencesSnapshot()
        buildHierarchy()
        installGestures()
        configureDelegates()
        refreshMetadataLabels()
        rebuildMenus()
        updateResponsiveHudMetrics(force: true)
        loadPosterArtworkForNowPlaying()
        startClockTimerIfNeeded()

        openCurrentEpisode(startPositionMs: context.startPositionMs)
        scheduleHudAutoHide()
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }

    public override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.horizontalSizeClass != traitCollection.horizontalSizeClass {
            updateResponsiveHudMetrics()
        }
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateResponsiveHudMetrics()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let topHeight = min(140.0, view.bounds.height * 0.28)
        let bottomHeight = min(180.0, view.bounds.height * 0.36)
        topScrimLayer.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: topHeight)
        bottomScrimLayer.frame = CGRect(
            x: 0,
            y: view.bounds.height - bottomHeight,
            width: view.bounds.width,
            height: bottomHeight
        )
        CATransaction.commit()
    }

    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isBeingDismissed || isMovingFromParent {
            persistWatchHistoryIfAllowed(force: true)
            teardownAllResources()
        }
    }

    // MARK: - Preferences & State Bootstrap

    private func loadPreferencesSnapshot() {
        let prefs = storage.preferences()
        currentRate = Float(prefs.playSpeed)
        aspectMode = MarcoVideoAspectMode.fromPreference(prefs.defaultAspectMode)
        anime4kEnabled = prefs.anime4kLightweight
        vocalLoudness = prefs.vocalLoudness
        hdrToneMapping = prefs.hdrToneMapping
        activeEngineMode = prefs.iosEngineMode

        danmuSettings = storage.danmuSettings()
        danmakuView.applySettings(danmuSettings)
        danmakuView.isDanmakuEnabled = context.demoPreviewMode ? true : danmuSettings.enabled

        avLayerView.setAspectMode(aspectMode)
        avEngine.setRate(currentRate)
        avEngine.setVocalLoudness(vocalLoudness)

        mpvMetalView.setAspectMode(aspectMode)
        mpvMetalView.setRate(currentRate)
        mpvMetalView.setVocalLoudness(vocalLoudness)
        mpvMetalView.setHdrToneMapping(hdrToneMapping)
        mpvMetalView.setAnime4kEnabled(anime4kEnabled)
    }

    private func configureDelegates() {
        avEngine.delegate = self
        avEngine.attach(to: avLayerView)
        mpvMetalView.delegate = self
    }

    // MARK: - UI Hierarchy Construction

    private func buildHierarchy() {
        // 1. Video stage container (AVPlayerLayer + Metal libmpv + Demo Preview Stage)
        stageContainer.translatesAutoresizingMaskIntoConstraints = false
        stageContainer.backgroundColor = .black
        view.addSubview(stageContainer)
        NSLayoutConstraint.activate([
            stageContainer.topAnchor.constraint(equalTo: view.topAnchor),
            stageContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stageContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stageContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        for sub in [avLayerView, mpvMetalView, demoBackdropView, danmakuView] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            stageContainer.addSubview(sub)
            NSLayoutConstraint.activate([
                sub.topAnchor.constraint(equalTo: stageContainer.topAnchor),
                sub.leadingAnchor.constraint(equalTo: stageContainer.leadingAnchor),
                sub.trailingAnchor.constraint(equalTo: stageContainer.trailingAnchor),
                sub.bottomAnchor.constraint(equalTo: stageContainer.bottomAnchor),
            ])
        }
        mpvMetalView.isHidden = true
        demoBackdropView.isHidden = !context.demoPreviewMode

        // 2. Gesture capture overlay above video/danmaku and beneath interactive HUD
        gestureOverlayView.translatesAutoresizingMaskIntoConstraints = false
        gestureOverlayView.backgroundColor = .clear
        view.addSubview(gestureOverlayView)
        NSLayoutConstraint.activate([
            gestureOverlayView.topAnchor.constraint(equalTo: view.topAnchor),
            gestureOverlayView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            gestureOverlayView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            gestureOverlayView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        // 3. Cinema subtitle overlay pill
        subtitleBackdropView.translatesAutoresizingMaskIntoConstraints = false
        subtitleBackdropView.backgroundColor = UIColor.black.withAlphaComponent(0.56)
        subtitleBackdropView.applyContinuousCorners(10)
        subtitleBackdropView.isHidden = true
        subtitleBackdropView.isUserInteractionEnabled = false
        view.addSubview(subtitleBackdropView)

        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.font = UIFont.systemFont(ofSize: 18, weight: .semibold)
        subtitleLabel.textColor = .white
        subtitleLabel.textAlignment = .center
        subtitleLabel.numberOfLines = 3
        subtitleLabel.shadowColor = UIColor.black.withAlphaComponent(0.85)
        subtitleLabel.shadowOffset = CGSize(width: 0, height: 1)
        subtitleBackdropView.addSubview(subtitleLabel)
        NSLayoutConstraint.activate([
            subtitleLabel.topAnchor.constraint(equalTo: subtitleBackdropView.topAnchor, constant: 6),
            subtitleLabel.bottomAnchor.constraint(equalTo: subtitleBackdropView.bottomAnchor, constant: -6),
            subtitleLabel.leadingAnchor.constraint(equalTo: subtitleBackdropView.leadingAnchor, constant: 14),
            subtitleLabel.trailingAnchor.constraint(equalTo: subtitleBackdropView.trailingAnchor, constant: -14),
            subtitleBackdropView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            subtitleBackdropView.widthAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.widthAnchor, constant: -48),
            subtitleBackdropView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -128),
        ])

        // 4. Scrims & HUD Container
        topScrimLayer.colors = [
            UIColor.black.withAlphaComponent(0.68).cgColor,
            UIColor.clear.cgColor,
        ]
        bottomScrimLayer.colors = [
            UIColor.clear.cgColor,
            UIColor.black.withAlphaComponent(0.76).cgColor,
        ]
        hudContainerView.translatesAutoresizingMaskIntoConstraints = false
        hudContainerView.backgroundColor = .clear
        hudContainerView.layer.addSublayer(topScrimLayer)
        hudContainerView.layer.addSublayer(bottomScrimLayer)
        view.addSubview(hudContainerView)
        NSLayoutConstraint.activate([
            hudContainerView.topAnchor.constraint(equalTo: view.topAnchor),
            hudContainerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hudContainerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hudContainerView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        buildTopHudBar()
        buildCenterTransportControls()
        buildBottomHudBar()
        buildFloatingOverlays()
    }

    private var isCompactHudWidth: Bool {
        if traitCollection.horizontalSizeClass == .compact {
            return true
        }
        if traitCollection.horizontalSizeClass == .regular {
            return false
        }
        let width = view.bounds.width > 0 ? view.bounds.width : UIScreen.main.bounds.width
        return width < 520
    }

    private func buildTopHudBar() {
        topBarSurface.translatesAutoresizingMaskIntoConstraints = false
        hudContainerView.addSubview(topBarSurface)

        closeButton.addTarget(self, action: #selector(handleCloseTapped), for: .touchUpInside)
        engineSwitchButton.addTarget(self, action: #selector(handleEngineHotSwitchTapped), for: .touchUpInside)
        pipButton.addTarget(self, action: #selector(handlePipTapped), for: .touchUpInside)
        castButton.addTarget(self, action: #selector(handleDlnaCastTapped), for: .touchUpInside)
        moreMenuButton.showsMenuAsPrimaryAction = true

        titleLabel.font = MarcoTypography.bodySemibold
        titleLabel.textColor = .white
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        subtitleMetaLabel.font = MarcoTypography.caption
        subtitleMetaLabel.textColor = UIColor.white.withAlphaComponent(0.74)
        subtitleMetaLabel.numberOfLines = 1
        subtitleMetaLabel.lineBreakMode = .byTruncatingTail
        subtitleMetaLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subtitleMetaLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        topTitleStack.translatesAutoresizingMaskIntoConstraints = false
        topTitleStack.axis = .vertical
        topTitleStack.alignment = .fill
        topTitleStack.spacing = 1
        topTitleStack.addArrangedSubview(titleLabel)
        topTitleStack.addArrangedSubview(subtitleMetaLabel)
        topTitleStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        topTitleStack.setContentHuggingPriority(.defaultLow, for: .horizontal)

        clockLabel.font = MarcoTypography.monospacedDigits(size: 12, weight: .semibold)
        clockLabel.textColor = UIColor.white.withAlphaComponent(0.84)
        clockLabel.isHidden = !storage.preferences().playerAlwaysShowClock
        clockLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        clockLabel.setContentHuggingPriority(.required, for: .horizontal)

        airplayContainer.translatesAutoresizingMaskIntoConstraints = false
        airplayContainer.backgroundColor = UIColor.white.withAlphaComponent(0.10)
        airplayContainer.layer.cornerCurve = .continuous
        airplayContainer.layer.cornerRadius = 17
        airplayContainer.clipsToBounds = true
        airplayContainer.setContentCompressionResistancePriority(.required, for: .horizontal)
        airplayContainer.setContentHuggingPriority(.required, for: .horizontal)

        airPlayPickerView.translatesAutoresizingMaskIntoConstraints = false
        airplayContainer.addSubview(airPlayPickerView)
        NSLayoutConstraint.activate([
            airplayContainer.widthAnchor.constraint(equalToConstant: 34),
            airplayContainer.heightAnchor.constraint(equalToConstant: 34),
            airPlayPickerView.centerXAnchor.constraint(equalTo: airplayContainer.centerXAnchor),
            airPlayPickerView.centerYAnchor.constraint(equalTo: airplayContainer.centerYAnchor),
            airPlayPickerView.widthAnchor.constraint(equalToConstant: 30),
            airPlayPickerView.heightAnchor.constraint(equalToConstant: 30),
        ])

        topRightControlsStack.translatesAutoresizingMaskIntoConstraints = false
        topRightControlsStack.axis = .horizontal
        topRightControlsStack.alignment = .center
        topRightControlsStack.distribution = .fill
        topRightControlsStack.spacing = isCompactHudWidth ? 6 : 10
        topRightControlsStack.setContentCompressionResistancePriority(.required, for: .horizontal)
        topRightControlsStack.setContentHuggingPriority(.required, for: .horizontal)
        for item in [
            clockLabel,
            engineSwitchButton,
            pipButton,
            airplayContainer,
            castButton,
            moreMenuButton,
        ] {
            item.setContentCompressionResistancePriority(.required, for: .horizontal)
            item.setContentHuggingPriority(.required, for: .horizontal)
            topRightControlsStack.addArrangedSubview(item)
        }

        let content = topBarSurface.contentView
        content.addSubview(closeButton)
        content.addSubview(topTitleStack)
        content.addSubview(topRightControlsStack)

        NSLayoutConstraint.activate([
            content.heightAnchor.constraint(greaterThanOrEqualToConstant: 50),

            closeButton.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            closeButton.centerYAnchor.constraint(equalTo: content.centerYAnchor),

            topRightControlsStack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            topRightControlsStack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            topRightControlsStack.topAnchor.constraint(greaterThanOrEqualTo: content.topAnchor, constant: 8),
            topRightControlsStack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -8),

            topTitleStack.leadingAnchor.constraint(equalTo: closeButton.trailingAnchor, constant: 8),
            topTitleStack.trailingAnchor.constraint(lessThanOrEqualTo: topRightControlsStack.leadingAnchor, constant: -8),
            topTitleStack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            topTitleStack.topAnchor.constraint(greaterThanOrEqualTo: content.topAnchor, constant: 7),
            topTitleStack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -7),

            topBarSurface.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
            topBarSurface.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 14),
            topBarSurface.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -14),
        ])
    }

    private func updateResponsiveHudMetrics(force: Bool = false) {
        let isCompact = isCompactHudWidth
        if !force && lastCompactHudLayout == isCompact {
            return
        }
        lastCompactHudLayout = isCompact
        topRightControlsStack.spacing = isCompact ? 6 : 10
        bottomActionsStack.spacing = isCompact ? 6 : 10

        for pill in [
            engineSwitchButton,
            nextEpisodeButton,
            speedButton,
            episodesButton,
            linesButton,
            danmakuToggleButton,
            tracksButton,
        ] {
            pill.setCompactMode(isCompact)
        }
        updateEngineBadge(animated: false)
    }

    private func buildCenterTransportControls() {
        skipBackwardButton.addTarget(self, action: #selector(handleSkipBackward15), for: .touchUpInside)
        centerPlayPauseButton.addTarget(self, action: #selector(handlePlayPauseTapped), for: .touchUpInside)
        skipForwardButton.addTarget(self, action: #selector(handleSkipForward15), for: .touchUpInside)

        skipBackwardButton.isHidden = context.isLive
        skipForwardButton.isHidden = context.isLive

        centerTransportStack.translatesAutoresizingMaskIntoConstraints = false
        centerTransportStack.axis = .horizontal
        centerTransportStack.alignment = .center
        centerTransportStack.spacing = 34
        centerTransportStack.addArrangedSubview(skipBackwardButton)
        centerTransportStack.addArrangedSubview(centerPlayPauseButton)
        centerTransportStack.addArrangedSubview(skipForwardButton)
        hudContainerView.addSubview(centerTransportStack)

        NSLayoutConstraint.activate([
            centerTransportStack.centerXAnchor.constraint(equalTo: hudContainerView.centerXAnchor),
            centerTransportStack.centerYAnchor.constraint(equalTo: hudContainerView.centerYAnchor),
        ])

        // Lock button stays in `view` directly so it stays accessible even when `hudContainerView` is locked/hidden.
        lockToggleButton.translatesAutoresizingMaskIntoConstraints = false
        lockToggleButton.addTarget(self, action: #selector(handleLockToggleTapped), for: .touchUpInside)
        view.addSubview(lockToggleButton)
        NSLayoutConstraint.activate([
            lockToggleButton.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            lockToggleButton.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])

        // Buffering glass pill
        bufferingContainer.translatesAutoresizingMaskIntoConstraints = false
        bufferingContainer.isHidden = true
        bufferingContainer.isUserInteractionEnabled = false
        view.addSubview(bufferingContainer)

        bufferingIndicator.color = .white
        bufferingLabel.font = MarcoTypography.caption
        bufferingLabel.textColor = .white
        bufferingLabel.text = "正在加载..."

        let bufStack = UIStackView(arrangedSubviews: [bufferingIndicator, bufferingLabel])
        bufStack.translatesAutoresizingMaskIntoConstraints = false
        bufStack.axis = .horizontal
        bufStack.alignment = .center
        bufStack.spacing = 8
        bufferingContainer.contentView.addSubview(bufStack)
        NSLayoutConstraint.activate([
            bufStack.topAnchor.constraint(equalTo: bufferingContainer.contentView.topAnchor, constant: 8),
            bufStack.bottomAnchor.constraint(equalTo: bufferingContainer.contentView.bottomAnchor, constant: -8),
            bufStack.leadingAnchor.constraint(equalTo: bufferingContainer.contentView.leadingAnchor, constant: 14),
            bufStack.trailingAnchor.constraint(equalTo: bufferingContainer.contentView.trailingAnchor, constant: -14),
            bufferingContainer.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            bufferingContainer.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: 62),
        ])
    }

    private func buildBottomHudBar() {
        bottomBarSurface.translatesAutoresizingMaskIntoConstraints = false
        hudContainerView.addSubview(bottomBarSurface)

        // Row 1: Scrubber or Live badge
        scrubberContainer.translatesAutoresizingMaskIntoConstraints = false
        elapsedTimeLabel.translatesAutoresizingMaskIntoConstraints = false
        elapsedTimeLabel.font = MarcoTypography.monospacedDigits(size: 12.5, weight: .semibold)
        elapsedTimeLabel.textColor = .white
        elapsedTimeLabel.text = "00:00"
        elapsedTimeLabel.textAlignment = .left

        remainingTimeLabel.translatesAutoresizingMaskIntoConstraints = false
        remainingTimeLabel.font = MarcoTypography.monospacedDigits(size: 12.5, weight: .semibold)
        remainingTimeLabel.textColor = UIColor.white.withAlphaComponent(0.78)
        remainingTimeLabel.text = "00:00"
        remainingTimeLabel.textAlignment = .right
        remainingTimeLabel.isUserInteractionEnabled = true
        remainingTimeLabel.addGestureRecognizer(
            UITapGestureRecognizer(target: self, action: #selector(handleToggleRemainingTimeDisplay))
        )

        bufferedProgressView.translatesAutoresizingMaskIntoConstraints = false
        bufferedProgressView.progressTintColor = UIColor.white.withAlphaComponent(0.35)
        bufferedProgressView.trackTintColor = UIColor.white.withAlphaComponent(0.16)
        bufferedProgressView.layer.cornerRadius = 2
        bufferedProgressView.clipsToBounds = true

        progressSlider.translatesAutoresizingMaskIntoConstraints = false
        progressSlider.minimumValue = 0
        progressSlider.maximumValue = 1
        progressSlider.minimumTrackTintColor = .white
        progressSlider.maximumTrackTintColor = .clear
        progressSlider.setThumbImage(Self.makeScrubberThumbImage(diameter: 14), for: .normal)
        progressSlider.setThumbImage(Self.makeScrubberThumbImage(diameter: 18), for: .highlighted)
        progressSlider.addTarget(self, action: #selector(handleScrubberTouchDown), for: .touchDown)
        progressSlider.addTarget(self, action: #selector(handleScrubberValueChanged), for: .valueChanged)
        progressSlider.addTarget(self, action: #selector(handleScrubberTouchUp), for: [.touchUpInside, .touchUpOutside, .touchCancel])

        scrubberContainer.addSubview(elapsedTimeLabel)
        scrubberContainer.addSubview(bufferedProgressView)
        scrubberContainer.addSubview(progressSlider)
        scrubberContainer.addSubview(remainingTimeLabel)

        NSLayoutConstraint.activate([
            elapsedTimeLabel.leadingAnchor.constraint(equalTo: scrubberContainer.leadingAnchor),
            elapsedTimeLabel.centerYAnchor.constraint(equalTo: scrubberContainer.centerYAnchor),
            elapsedTimeLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 46),

            remainingTimeLabel.trailingAnchor.constraint(equalTo: scrubberContainer.trailingAnchor),
            remainingTimeLabel.centerYAnchor.constraint(equalTo: scrubberContainer.centerYAnchor),
            remainingTimeLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 48),

            progressSlider.leadingAnchor.constraint(equalTo: elapsedTimeLabel.trailingAnchor, constant: 10),
            progressSlider.trailingAnchor.constraint(equalTo: remainingTimeLabel.leadingAnchor, constant: -10),
            progressSlider.topAnchor.constraint(equalTo: scrubberContainer.topAnchor),
            progressSlider.bottomAnchor.constraint(equalTo: scrubberContainer.bottomAnchor),

            bufferedProgressView.leadingAnchor.constraint(equalTo: progressSlider.leadingAnchor, constant: 2),
            bufferedProgressView.trailingAnchor.constraint(equalTo: progressSlider.trailingAnchor, constant: -2),
            bufferedProgressView.centerYAnchor.constraint(equalTo: progressSlider.centerYAnchor),
            bufferedProgressView.heightAnchor.constraint(equalToConstant: 3.5),
        ])

        // Live badge row (shown when `context.isLive`)
        liveBadgeView.translatesAutoresizingMaskIntoConstraints = false
        liveDotView.translatesAutoresizingMaskIntoConstraints = false
        liveDotView.backgroundColor = MarcoColors.destructive
        liveDotView.layer.cornerRadius = 4
        liveStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        liveStatusLabel.font = MarcoTypography.badge
        liveStatusLabel.textColor = .white
        liveStatusLabel.text = "LIVE · 实时直播"
        liveBadgeView.addSubview(liveDotView)
        liveBadgeView.addSubview(liveStatusLabel)
        NSLayoutConstraint.activate([
            liveDotView.leadingAnchor.constraint(equalTo: liveBadgeView.leadingAnchor),
            liveDotView.centerYAnchor.constraint(equalTo: liveBadgeView.centerYAnchor),
            liveDotView.widthAnchor.constraint(equalToConstant: 8),
            liveDotView.heightAnchor.constraint(equalToConstant: 8),
            liveStatusLabel.leadingAnchor.constraint(equalTo: liveDotView.trailingAnchor, constant: 8),
            liveStatusLabel.centerYAnchor.constraint(equalTo: liveBadgeView.centerYAnchor),
            liveStatusLabel.trailingAnchor.constraint(lessThanOrEqualTo: liveBadgeView.trailingAnchor),
            liveBadgeView.heightAnchor.constraint(equalToConstant: 24),
        ])
        scrubberContainer.isHidden = context.isLive
        liveBadgeView.isHidden = !context.isLive

        // Row 2: Action buttons
        nextEpisodeButton.addTarget(self, action: #selector(handleNextEpisodeTapped), for: .touchUpInside)
        speedButton.showsMenuAsPrimaryAction = true
        episodesButton.addTarget(self, action: #selector(handleEpisodesTapped), for: .touchUpInside)
        linesButton.showsMenuAsPrimaryAction = true
        danmakuToggleButton.addTarget(self, action: #selector(handleDanmakuToggleTapped), for: .touchUpInside)
        danmakuSettingsButton.addTarget(self, action: #selector(handleDanmakuSettingsTapped), for: .touchUpInside)
        tracksButton.showsMenuAsPrimaryAction = true
        orientationButton.addTarget(self, action: #selector(handleOrientationToggleTapped), for: .touchUpInside)

        speedButton.isHidden = context.isLive
        danmakuToggleButton.isHidden = context.isLive
        danmakuSettingsButton.isHidden = context.isLive

        bottomActionsScroll.translatesAutoresizingMaskIntoConstraints = false
        bottomActionsScroll.showsHorizontalScrollIndicator = false
        bottomActionsScroll.alwaysBounceHorizontal = true
        bottomActionsScroll.clipsToBounds = true
        bottomActionsScroll.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 6)

        bottomActionsStack.translatesAutoresizingMaskIntoConstraints = false
        bottomActionsStack.axis = .horizontal
        bottomActionsStack.alignment = .center
        bottomActionsStack.distribution = .fill
        bottomActionsStack.spacing = isCompactHudWidth ? 6 : 10
        for control in [
            nextEpisodeButton,
            speedButton,
            episodesButton,
            linesButton,
            danmakuToggleButton,
            danmakuSettingsButton,
            tracksButton,
            orientationButton,
        ] {
            control.setContentCompressionResistancePriority(.required, for: .horizontal)
            control.setContentHuggingPriority(.required, for: .horizontal)
            bottomActionsStack.addArrangedSubview(control)
        }
        bottomActionsScroll.addSubview(bottomActionsStack)

        NSLayoutConstraint.activate([
            bottomActionsStack.topAnchor.constraint(equalTo: bottomActionsScroll.contentLayoutGuide.topAnchor),
            bottomActionsStack.bottomAnchor.constraint(equalTo: bottomActionsScroll.contentLayoutGuide.bottomAnchor),
            bottomActionsStack.leadingAnchor.constraint(equalTo: bottomActionsScroll.contentLayoutGuide.leadingAnchor),
            bottomActionsStack.trailingAnchor.constraint(equalTo: bottomActionsScroll.contentLayoutGuide.trailingAnchor),
            bottomActionsStack.heightAnchor.constraint(equalTo: bottomActionsScroll.frameLayoutGuide.heightAnchor),
            bottomActionsScroll.heightAnchor.constraint(equalToConstant: 38),
        ])

        let bottomVStack = UIStackView(arrangedSubviews: [scrubberContainer, liveBadgeView, bottomActionsScroll])
        bottomVStack.translatesAutoresizingMaskIntoConstraints = false
        bottomVStack.axis = .vertical
        bottomVStack.spacing = 8
        bottomBarSurface.contentView.addSubview(bottomVStack)

        NSLayoutConstraint.activate([
            bottomVStack.topAnchor.constraint(equalTo: bottomBarSurface.contentView.topAnchor, constant: 10),
            bottomVStack.bottomAnchor.constraint(equalTo: bottomBarSurface.contentView.bottomAnchor, constant: -10),
            bottomVStack.leadingAnchor.constraint(equalTo: bottomBarSurface.contentView.leadingAnchor, constant: 14),
            bottomVStack.trailingAnchor.constraint(equalTo: bottomBarSurface.contentView.trailingAnchor, constant: -14),

            bottomBarSurface.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 14),
            bottomBarSurface.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -14),
            bottomBarSurface.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -10),
        ])

        refreshDanmakuButtonAppearance()
        refreshEpisodeNavigationVisibility()
    }

    private func buildFloatingOverlays() {
        // 1. Gesture HUD Pill (Brightness / Volume / Seek Preview)
        gestureHudSurface.translatesAutoresizingMaskIntoConstraints = false
        gestureHudSurface.isHidden = true
        gestureHudSurface.isUserInteractionEnabled = false
        view.addSubview(gestureHudSurface)

        gestureHudIconView.translatesAutoresizingMaskIntoConstraints = false
        gestureHudIconView.tintColor = .white
        gestureHudIconView.contentMode = .scaleAspectFit

        gestureHudLabel.translatesAutoresizingMaskIntoConstraints = false
        gestureHudLabel.font = MarcoTypography.monospacedDigits(size: 14, weight: .semibold)
        gestureHudLabel.textColor = .white

        gestureHudBarTrack.translatesAutoresizingMaskIntoConstraints = false
        gestureHudBarTrack.backgroundColor = UIColor.white.withAlphaComponent(0.24)
        gestureHudBarTrack.layer.cornerRadius = 2.5
        gestureHudBarTrack.clipsToBounds = true

        gestureHudBarFill.translatesAutoresizingMaskIntoConstraints = false
        gestureHudBarFill.backgroundColor = .white
        gestureHudBarFill.layer.cornerRadius = 2.5
        gestureHudBarTrack.addSubview(gestureHudBarFill)

        let fillWidth = gestureHudBarFill.widthAnchor.constraint(equalToConstant: 60)
        gestureHudBarFillWidthConstraint = fillWidth
        NSLayoutConstraint.activate([
            gestureHudBarFill.leadingAnchor.constraint(equalTo: gestureHudBarTrack.leadingAnchor),
            gestureHudBarFill.topAnchor.constraint(equalTo: gestureHudBarTrack.topAnchor),
            gestureHudBarFill.bottomAnchor.constraint(equalTo: gestureHudBarTrack.bottomAnchor),
            fillWidth,
            gestureHudBarTrack.widthAnchor.constraint(equalToConstant: 112),
            gestureHudBarTrack.heightAnchor.constraint(equalToConstant: 5),
            gestureHudIconView.widthAnchor.constraint(equalToConstant: 20),
            gestureHudIconView.heightAnchor.constraint(equalToConstant: 20),
        ])

        let gestureStack = UIStackView(arrangedSubviews: [gestureHudIconView, gestureHudLabel, gestureHudBarTrack])
        gestureStack.translatesAutoresizingMaskIntoConstraints = false
        gestureStack.axis = .horizontal
        gestureStack.alignment = .center
        gestureStack.spacing = 10
        gestureHudSurface.contentView.addSubview(gestureStack)
        NSLayoutConstraint.activate([
            gestureStack.topAnchor.constraint(equalTo: gestureHudSurface.contentView.topAnchor, constant: 10),
            gestureStack.bottomAnchor.constraint(equalTo: gestureHudSurface.contentView.bottomAnchor, constant: -10),
            gestureStack.leadingAnchor.constraint(equalTo: gestureHudSurface.contentView.leadingAnchor, constant: 16),
            gestureStack.trailingAnchor.constraint(equalTo: gestureHudSurface.contentView.trailingAnchor, constant: -16),
            gestureHudSurface.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            gestureHudSurface.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -72),
        ])

        // 2. Long-Press 2.0x Pill
        longPressPill.translatesAutoresizingMaskIntoConstraints = false
        longPressPill.isHidden = true
        longPressPill.isUserInteractionEnabled = false
        longPressLabel.translatesAutoresizingMaskIntoConstraints = false
        longPressLabel.font = MarcoTypography.badge
        longPressLabel.textColor = .white
        longPressLabel.text = "2.0x 倍速播放中"
        longPressPill.contentView.addSubview(longPressLabel)
        view.addSubview(longPressPill)
        NSLayoutConstraint.activate([
            longPressLabel.topAnchor.constraint(equalTo: longPressPill.contentView.topAnchor, constant: 7),
            longPressLabel.bottomAnchor.constraint(equalTo: longPressPill.contentView.bottomAnchor, constant: -7),
            longPressLabel.leadingAnchor.constraint(equalTo: longPressPill.contentView.leadingAnchor, constant: 14),
            longPressLabel.trailingAnchor.constraint(equalTo: longPressPill.contentView.trailingAnchor, constant: -14),
            longPressPill.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            longPressPill.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 68),
        ])

        // 3. Toast Pill
        toastPill.translatesAutoresizingMaskIntoConstraints = false
        toastPill.isHidden = true
        toastPill.isUserInteractionEnabled = false
        toastLabel.translatesAutoresizingMaskIntoConstraints = false
        toastLabel.font = MarcoTypography.caption
        toastLabel.textColor = .white
        toastLabel.numberOfLines = 2
        toastLabel.textAlignment = .center
        toastPill.contentView.addSubview(toastLabel)
        view.addSubview(toastPill)
        NSLayoutConstraint.activate([
            toastLabel.topAnchor.constraint(equalTo: toastPill.contentView.topAnchor, constant: 8),
            toastLabel.bottomAnchor.constraint(equalTo: toastPill.contentView.bottomAnchor, constant: -8),
            toastLabel.leadingAnchor.constraint(equalTo: toastPill.contentView.leadingAnchor, constant: 16),
            toastLabel.trailingAnchor.constraint(equalTo: toastPill.contentView.trailingAnchor, constant: -16),
            toastPill.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            toastPill.widthAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.widthAnchor, constant: -48),
            toastPill.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 74),
        ])

        // 4. 3s Cancellable Skip Intro / Outro Banner
        skipBannerSurface.translatesAutoresizingMaskIntoConstraints = false
        skipBannerSurface.isHidden = true
        skipBannerLabel.font = MarcoTypography.cardTitle
        skipBannerLabel.textColor = .white

        configureInlineBannerButton(skipNowButton, title: "立即跳过", primary: true)
        skipNowButton.addTarget(self, action: #selector(handleSkipBannerExecute), for: .touchUpInside)
        configureInlineBannerButton(skipCancelButton, title: "取消", primary: false)
        skipCancelButton.addTarget(self, action: #selector(handleSkipBannerCancel), for: .touchUpInside)

        let skipStack = UIStackView(arrangedSubviews: [skipBannerLabel, skipNowButton, skipCancelButton])
        skipStack.translatesAutoresizingMaskIntoConstraints = false
        skipStack.axis = .horizontal
        skipStack.alignment = .center
        skipStack.spacing = 10
        skipBannerSurface.contentView.addSubview(skipStack)
        view.addSubview(skipBannerSurface)
        NSLayoutConstraint.activate([
            skipStack.topAnchor.constraint(equalTo: skipBannerSurface.contentView.topAnchor, constant: 10),
            skipStack.bottomAnchor.constraint(equalTo: skipBannerSurface.contentView.bottomAnchor, constant: -10),
            skipStack.leadingAnchor.constraint(equalTo: skipBannerSurface.contentView.leadingAnchor, constant: 14),
            skipStack.trailingAnchor.constraint(equalTo: skipBannerSurface.contentView.trailingAnchor, constant: -12),
            skipBannerSurface.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -18),
            skipBannerSurface.bottomAnchor.constraint(equalTo: bottomBarSurface.topAnchor, constant: -14),
        ])

        // 5. Sleep Timer 30s Pre-Expiry Warning Banner
        sleepBannerSurface.translatesAutoresizingMaskIntoConstraints = false
        sleepBannerSurface.isHidden = true
        sleepBannerLabel.font = MarcoTypography.cardTitle
        sleepBannerLabel.textColor = .white

        configureInlineBannerButton(sleepExtendButton, title: "+15分钟", primary: true)
        sleepExtendButton.addTarget(self, action: #selector(handleSleepTimerExtend15), for: .touchUpInside)
        configureInlineBannerButton(sleepCancelButton, title: "取消", primary: false)
        sleepCancelButton.addTarget(self, action: #selector(handleSleepTimerCancel), for: .touchUpInside)

        let sleepStack = UIStackView(arrangedSubviews: [sleepBannerLabel, sleepExtendButton, sleepCancelButton])
        sleepStack.translatesAutoresizingMaskIntoConstraints = false
        sleepStack.axis = .horizontal
        sleepStack.alignment = .center
        sleepStack.spacing = 10
        sleepBannerSurface.contentView.addSubview(sleepStack)
        view.addSubview(sleepBannerSurface)
        NSLayoutConstraint.activate([
            sleepStack.topAnchor.constraint(equalTo: sleepBannerSurface.contentView.topAnchor, constant: 10),
            sleepStack.bottomAnchor.constraint(equalTo: sleepBannerSurface.contentView.bottomAnchor, constant: -10),
            sleepStack.leadingAnchor.constraint(equalTo: sleepBannerSurface.contentView.leadingAnchor, constant: 14),
            sleepStack.trailingAnchor.constraint(equalTo: sleepBannerSurface.contentView.trailingAnchor, constant: -12),
            sleepBannerSurface.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            sleepBannerSurface.topAnchor.constraint(equalTo: topBarSurface.bottomAnchor, constant: 12),
        ])

        // 6. Error Recovery Surface
        errorOverlaySurface.translatesAutoresizingMaskIntoConstraints = false
        errorOverlaySurface.isHidden = true
        errorTitleLabel.font = MarcoTypography.sectionHeader
        errorTitleLabel.textColor = .white
        errorTitleLabel.textAlignment = .center
        errorTitleLabel.text = "播放暂时遇到问题"

        errorDetailLabel.font = MarcoTypography.cardSubtitle
        errorDetailLabel.textColor = UIColor.white.withAlphaComponent(0.75)
        errorDetailLabel.textAlignment = .center
        errorDetailLabel.numberOfLines = 3

        errorRetryButton.addTarget(self, action: #selector(handleErrorRetryTapped), for: .touchUpInside)
        errorSwitchLineButton.addTarget(self, action: #selector(handleErrorSwitchLineTapped), for: .touchUpInside)

        let errActions = UIStackView(arrangedSubviews: [errorRetryButton, errorSwitchLineButton])
        errActions.axis = .horizontal
        errActions.spacing = 12
        errActions.distribution = .fillEqually

        let errStack = UIStackView(arrangedSubviews: [errorTitleLabel, errorDetailLabel, errActions])
        errStack.translatesAutoresizingMaskIntoConstraints = false
        errStack.axis = .vertical
        errStack.spacing = 12
        errorOverlaySurface.contentView.addSubview(errStack)
        view.addSubview(errorOverlaySurface)
        NSLayoutConstraint.activate([
            errStack.topAnchor.constraint(equalTo: errorOverlaySurface.contentView.topAnchor, constant: 20),
            errStack.bottomAnchor.constraint(equalTo: errorOverlaySurface.contentView.bottomAnchor, constant: -20),
            errStack.leadingAnchor.constraint(equalTo: errorOverlaySurface.contentView.leadingAnchor, constant: 20),
            errStack.trailingAnchor.constraint(equalTo: errorOverlaySurface.contentView.trailingAnchor, constant: -20),
            errorOverlaySurface.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            errorOverlaySurface.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            errorOverlaySurface.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
            errorOverlaySurface.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            errorOverlaySurface.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
        ])
    }

    private func configureInlineBannerButton(_ button: UIButton, title: String, primary: Bool) {
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = MarcoTypography.badge
        button.applyContinuousCorners(12)
        if primary {
            button.backgroundColor = .white
            button.setTitleColor(UIColor(red: 0.05, green: 0.06, blue: 0.08, alpha: 1.0), for: .normal)
        } else {
            button.backgroundColor = UIColor.white.withAlphaComponent(0.16)
            button.setTitleColor(.white, for: .normal)
        }
        if #available(iOS 15.0, *) {
            var attr = AttributedString(title)
            attr.font = MarcoTypography.badge
            var cfg = UIButton.Configuration.plain()
            cfg.attributedTitle = attr
            cfg.baseForegroundColor = primary ? UIColor(red: 0.05, green: 0.06, blue: 0.08, alpha: 1.0) : .white
            cfg.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12)
            button.configuration = cfg
        } else {
            button.contentEdgeInsets = UIEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        }
    }

    // MARK: - Gesture State Machine

    private func installGestures() {
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.delegate = self

        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap(_:)))
        singleTap.numberOfTapsRequired = 1
        singleTap.require(toFail: doubleTap)
        singleTap.delegate = self

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.45
        longPress.delegate = self

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePanGesture(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = self

        gestureOverlayView.addGestureRecognizer(singleTap)
        gestureOverlayView.addGestureRecognizer(doubleTap)
        gestureOverlayView.addGestureRecognizer(longPress)
        gestureOverlayView.addGestureRecognizer(pan)
    }

    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if let touchedView = touch.view {
            if touchedView is UIControl || touchedView is AVRoutePickerView {
                return false
            }
            if touchedView.isDescendant(of: topBarSurface)
                || touchedView.isDescendant(of: bottomBarSurface)
                || touchedView.isDescendant(of: skipBannerSurface)
                || touchedView.isDescendant(of: sleepBannerSurface)
                || touchedView.isDescendant(of: errorOverlaySurface)
            {
                return false
            }
        }
        return true
    }

    @objc private func handleSingleTap(_ recognizer: UITapGestureRecognizer) {
        if isScreenLocked {
            flashLockButton()
            return
        }
        setHudVisible(!isHudVisible, animated: true)
    }

    @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        guard !isScreenLocked else {
            flashLockButton()
            return
        }
        let location = recognizer.location(in: view)
        let width = max(1, view.bounds.width)
        if !context.isLive && location.x < width * 0.32 {
            seekRelative(deltaMs: -15_000)
            showTemporaryGesturePill(symbol: "gobackward.15", text: "-15秒", progress: nil)
            MarcoHaptics.light()
        } else if !context.isLive && location.x > width * 0.68 {
            seekRelative(deltaMs: 15_000)
            showTemporaryGesturePill(symbol: "goforward.15", text: "+15秒", progress: nil)
            MarcoHaptics.light()
        } else {
            togglePlayPause()
            showTemporaryGesturePill(
                symbol: isPlaying ? "play.fill" : "pause.fill",
                text: isPlaying ? "播放" : "已暂停",
                progress: nil
            )
            MarcoHaptics.medium()
        }
    }

    @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
        guard !isScreenLocked, !context.isLive else { return }
        switch recognizer.state {
        case .began:
            guard rateBeforeLongPress == nil else { return }
            rateBeforeLongPress = currentRate
            applyPlaybackRate(2.0, persist: false)
            longPressPill.isHidden = false
            longPressPill.alpha = 0
            UIView.animate(withDuration: 0.16) {
                self.longPressPill.alpha = 1
            }
            MarcoHaptics.medium()
        case .ended, .cancelled, .failed:
            if let original = rateBeforeLongPress {
                rateBeforeLongPress = nil
                applyPlaybackRate(original, persist: false)
            }
            UIView.animate(withDuration: 0.16, animations: {
                self.longPressPill.alpha = 0
            }) { _ in
                self.longPressPill.isHidden = true
            }
        default:
            break
        }
    }

    @objc private func handlePanGesture(_ recognizer: UIPanGestureRecognizer) {
        guard !isScreenLocked else { return }
        let translation = recognizer.translation(in: view)
        let location = recognizer.location(in: view)

        switch recognizer.state {
        case .began:
            panAxis = .undecided
            panStartPositionMs = currentPositionMs
            panTargetPositionMs = currentPositionMs
            panStartBrightness = UIScreen.main.brightness
            panStartVolume = avEngine.currentSystemVolume()

        case .changed:
            if panAxis == .undecided {
                let absX = abs(translation.x)
                let absY = abs(translation.y)
                guard max(absX, absY) >= 10 else { return }
                if absX > absY && !context.isLive && currentDurationMs > 0 {
                    panAxis = .horizontalSeek
                } else if absY >= absX {
                    panAxis = location.x < view.bounds.width * 0.5 ? .verticalBrightness : .verticalVolume
                } else {
                    return
                }
            }

            switch panAxis {
            case .horizontalSeek:
                let width = max(240.0, view.bounds.width)
                let maxSpanMs = min(Double(currentDurationMs), 180_000.0)
                let deltaMs = Int64((Double(translation.x / width) * maxSpanMs).rounded())
                panTargetPositionMs = min(max(0, panStartPositionMs + deltaMs), currentDurationMs)
                let sign = deltaMs >= 0 ? "+" : "-"
                let label = "\(Self.formatTime(ms: panTargetPositionMs))  (\(sign)\(Self.formatTime(ms: abs(deltaMs))))"
                let progress = currentDurationMs > 0 ? Float(panTargetPositionMs) / Float(currentDurationMs) : 0
                showGestureHud(
                    symbol: deltaMs >= 0 ? "goforward" : "gobackward",
                    text: label,
                    progress: progress
                )

            case .verticalBrightness:
                let height = max(220.0, view.bounds.height * 0.65)
                let nextBrightness = min(max(0.0, panStartBrightness - (translation.y / height)), 1.0)
                UIScreen.main.brightness = nextBrightness
                showGestureHud(
                    symbol: nextBrightness < 0.3 ? "sun.min.fill" : "sun.max.fill",
                    text: "\(Int((nextBrightness * 100).rounded()))%",
                    progress: Float(nextBrightness)
                )

            case .verticalVolume:
                let height = max(220.0, view.bounds.height * 0.65)
                let nextVol = Float(min(max(0.0, Double(panStartVolume) - Double(translation.y / height)), 1.0))
                let applied = avEngine.setSystemVolume(nextVol)
                showGestureHud(
                    symbol: applied <= 0.01 ? "speaker.slash.fill" : "speaker.wave.2.fill",
                    text: "\(Int((applied * 100).rounded()))%",
                    progress: applied
                )

            case .undecided:
                break
            }

        case .ended, .cancelled, .failed:
            if panAxis == .horizontalSeek {
                seekToPosition(ms: panTargetPositionMs)
            }
            panAxis = .undecided
            hideGestureHud()

        default:
            break
        }
    }

    private func showGestureHud(symbol: String, text: String, progress: Float?) {
        gestureHudIconView.image = MarcoSymbols.image(symbol, pointSize: 18, weight: .semibold)
        gestureHudLabel.text = text
        if let progress = progress {
            gestureHudBarTrack.isHidden = false
            gestureHudBarFillWidthConstraint?.constant = CGFloat(min(max(progress, 0), 1)) * 112.0
        } else {
            gestureHudBarTrack.isHidden = true
        }
        gestureHudSurface.isHidden = false
        gestureHudSurface.alpha = 1
    }

    private func showTemporaryGesturePill(symbol: String, text: String, progress: Float?) {
        showGestureHud(symbol: symbol, text: text, progress: progress)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [weak self] in
            guard let self = self, self.panAxis == .undecided else { return }
            self.hideGestureHud()
        }
    }

    private func hideGestureHud() {
        UIView.animate(withDuration: 0.18, animations: {
            self.gestureHudSurface.alpha = 0
        }) { _ in
            if self.gestureHudSurface.alpha == 0 {
                self.gestureHudSurface.isHidden = true
            }
        }
    }

    // MARK: - Episode Loading & Dual-Engine Orchestration

    private func currentLine() -> CmsLine? {
        guard lines.indices.contains(currentLineIndex) else { return nil }
        return lines[currentLineIndex]
    }

    private func currentEpisode() -> CmsEpisode? {
        guard let line = currentLine(), line.episodes.indices.contains(currentEpisodeIndex) else { return nil }
        return line.episodes[currentEpisodeIndex]
    }

    private func openCurrentEpisode(startPositionMs: Int64) {
        resolveTask?.cancel()
        danmuTask?.cancel()
        dismissSkipBanner()
        errorOverlaySurface.isHidden = true
        introHandledForEpisode = false
        outroHandledForEpisode = false
        hasFallbackOccurredForCurrentLoad = false
        audioTracks = []
        subtitleTracks = []
        currentPositionMs = max(0, startPositionMs)
        currentDurationMs = 0
        currentBufferedMs = 0

        refreshMetadataLabels()
        refreshEpisodeNavigationVisibility()
        rebuildMenus()

        if context.demoPreviewMode {
            startDemoPreviewPlayback(startPositionMs: startPositionMs)
            return
        }

        setBufferingOverlay(visible: true, text: "正在解析片源...")
        revokeActiveProxyLeases()

        let line = currentLine()
        let episode = currentEpisode()
        let directUrl = context.directStreamURL?.trimmingCharacters(in: .whitespacesAndNewlines)

        resolveTask = Task { [weak self] in
            guard let self = self else { return }
            do {
                let resolvedURL: URL
                let resolvedHeaders: [String: String]
                let badge: String

                if let rawDirect = directUrl, !rawDirect.isEmpty {
                    let (url, hdrs) = try await self.prepareDirectStreamURL(rawDirect, headers: self.context.directHeaders)
                    resolvedURL = url
                    resolvedHeaders = hdrs
                    badge = self.context.isLive ? "LIVE" : ""
                } else if let site = self.context.site, let ep = episode {
                    let configParses = self.storage.mergedConfig().parses
                    let resolved = try await self.cmsClient.resolvePlayableStream(
                        site: site,
                        lineName: line?.name ?? "",
                        episode: ep,
                        parses: configParses,
                        storage: self.storage,
                        headerProxy: self.headerProxy,
                        rangeProxy: self.rangeProxy
                    )
                    try Task.checkCancellation()
                    self.activeHeaderProxySessionId = resolved.headerProxySessionId
                    self.activeRangeProxyResourceId = resolved.rangeProxyResourceId
                    resolvedURL = try await self.wrapOfflineHlsIfNeeded(url: resolved.playableUrl)
                    resolvedHeaders = resolved.headers
                    badge = resolved.resolutionBadge
                } else if let ep = episode, !ep.url.isEmpty {
                    let (url, hdrs) = try await self.prepareDirectStreamURL(ep.url, headers: ep.headers)
                    resolvedURL = url
                    resolvedHeaders = hdrs
                    badge = ""
                } else {
                    throw MarcoError.invalidFormat("当前剧集缺少可播放地址")
                }

                try Task.checkCancellation()
                await MainActor.run {
                    self.currentResolvedURL = resolvedURL
                    self.currentResolvedHeaders = resolvedHeaders
                    self.currentResolutionBadge = badge
                    self.refreshMetadataLabels()

                    let desiredEngine = self.selectInitialEngine(for: resolvedURL.absoluteString)
                    self.startPlayback(
                        on: desiredEngine,
                        url: resolvedURL,
                        headers: resolvedHeaders,
                        startPositionMs: startPositionMs
                    )
                }

                if !self.context.isLive && self.danmuSettings.enabled {
                    self.fetchDanmakuForCurrentEpisode()
                }
            } catch is CancellationError {
                return
            } catch {
                await MainActor.run {
                    self.setBufferingOverlay(visible: false, text: nil)
                    self.showPlaybackError(error.localizedDescription)
                }
            }
        }
    }

    private func prepareDirectStreamURL(_ raw: String, headers: [String: String]) async throws -> (URL, [String: String]) {
        if OfflineHlsLease.isLocalM3u8(raw) {
            let lease = try await OfflineHlsLease.open(path: raw)
            activeOfflineHlsLease = lease
            return (lease.url, [:])
        }
        if raw.hasPrefix("/") || raw.lowercased().hasPrefix("file://") {
            let fileURL = raw.lowercased().hasPrefix("file://")
                ? (URL(string: raw) ?? URL(fileURLWithPath: raw))
                : URL(fileURLWithPath: raw)
            return (fileURL, [:])
        }
        guard let url = URL(string: CmsParser.normalizeUrl(raw)) else {
            throw MarcoError.invalidFormat("无法识别视频地址")
        }
        return (url, headers)
    }

    private func wrapOfflineHlsIfNeeded(url: URL) async throws -> URL {
        if url.isFileURL && OfflineHlsLease.isLocalM3u8(url.path) {
            let lease = try await OfflineHlsLease.open(path: url.path)
            activeOfflineHlsLease = lease
            return lease.url
        }
        return url
    }

    private func selectInitialEngine(for urlString: String) -> IosPlaybackEngineMode {
        let preferred = storage.preferences().iosEngineMode
        let precheck = MarcoAvPlayerEngine.shouldPreferMpvForURL(urlString)
        let wantMpv = (preferred == .mpv) || precheck.preferMpv

        if wantMpv {
            if MarcoMpvMetalView.isRuntimeAvailable {
                return .mpv
            }
            showToast(MarcoMpvMetalView.lightSimulatorFallbackMessage)
            return .avplayer
        }
        return .avplayer
    }

    private func startPlayback(
        on engine: IosPlaybackEngineMode,
        url: URL,
        headers: [String: String],
        startPositionMs: Int64
    ) {
        activeEngineMode = engine
        updateEngineBadge(animated: false)
        setBufferingOverlay(visible: true, text: engine == .mpv ? "libmpv 正在缓冲..." : "正在缓冲...")

        switch engine {
        case .avplayer:
            mpvMetalView.stop()
            mpvMetalView.isHidden = true
            avLayerView.isHidden = false
            avLayerView.setAspectMode(aspectMode)
            avEngine.setRate(currentRate)
            avEngine.setVocalLoudness(vocalLoudness)
            avEngine.open(
                url: url,
                headers: headers,
                startPositionMs: startPositionMs,
                isLive: context.isLive,
                title: effectiveDisplayTitle(),
                subtitle: effectiveDisplaySubtitle(),
                posterImage: loadedPosterImage,
                autoPlay: true
            )

        case .mpv:
            avEngine.stop()
            avLayerView.isHidden = true
            mpvMetalView.isHidden = false
            mpvMetalView.setAspectMode(aspectMode)
            mpvMetalView.setRate(currentRate)
            mpvMetalView.setVocalLoudness(vocalLoudness)
            mpvMetalView.setHdrToneMapping(hdrToneMapping)
            mpvMetalView.setAnime4kEnabled(anime4kEnabled)
            mpvMetalView.open(
                url: url,
                headers: headers,
                startPositionMs: startPositionMs,
                isLive: context.isLive
            )
        }
        rebuildMenus()
    }

    // MARK: - One-Tap Dual-Engine Hot Switch (AVPlayer <-> libmpv)

    @objc private func handleEngineHotSwitchTapped() {
        MarcoHaptics.selection()
        let target: IosPlaybackEngineMode = (activeEngineMode == .avplayer) ? .mpv : .avplayer
        hotSwitchEngine(to: target, persistPreference: true, reason: nil)
    }

    private func hotSwitchEngine(
        to target: IosPlaybackEngineMode,
        persistPreference: Bool,
        reason: String?
    ) {
        if target == .mpv && !MarcoMpvMetalView.isRuntimeAvailable {
            showToast(MarcoMpvMetalView.lightSimulatorFallbackMessage)
            if let iconView = engineSwitchButton.iconView {
                MarcoSymbols.bounce(iconView)
            }
            return
        }

        if persistPreference {
            storage.updatePreferences { $0.iosEngineMode = target }
        }

        if context.demoPreviewMode {
            activeEngineMode = target
            updateEngineBadge(animated: true)
            showToast(target == .mpv ? "已热切换至 libmpv Metal 渲染引擎" : "已热切换至 Apple 原生 AVPlayer")
            return
        }

        guard let url = currentResolvedURL else {
            activeEngineMode = target
            updateEngineBadge(animated: true)
            return
        }

        let exactPositionMs = currentPositionMs
        let wasPlaying = isPlaying

        if activeEngineMode == .avplayer {
            avEngine.stop()
        } else {
            mpvMetalView.stop()
        }

        activeEngineMode = target
        updateEngineBadge(animated: true)
        startPlayback(
            on: target,
            url: url,
            headers: currentResolvedHeaders,
            startPositionMs: exactPositionMs
        )
        if !wasPlaying {
            pausePlayback()
        }

        let message = reason ?? (target == .mpv
            ? "已无缝切换至 libmpv · \(Self.formatTime(ms: exactPositionMs))"
            : "已无缝切换至 AVPlayer · \(Self.formatTime(ms: exactPositionMs))")
        showToast(message)
    }

    private func updateEngineBadge(animated: Bool) {
        let title: String
        if isCompactHudWidth {
            title = (activeEngineMode == .mpv) ? "MPV" : "AV"
        } else {
            title = (activeEngineMode == .mpv) ? "libmpv" : "AVPlayer"
        }
        let symbol = (activeEngineMode == .mpv) ? "cpu" : "play.tv"
        engineSwitchButton.setContent(title: title, symbolName: symbol)
        if animated, let iconView = engineSwitchButton.iconView {
            MarcoSymbols.bounce(iconView)
        }
    }

    // MARK: - Demo Preview Mode (CI Simulator & Offline Stage)

    private func startDemoPreviewPlayback(startPositionMs: Int64) {
        demoBackdropView.isHidden = false
        avLayerView.isHidden = true
        mpvMetalView.isHidden = true
        setBufferingOverlay(visible: false, text: nil)

        demoSimulatedPosMs = startPositionMs > 0 ? startPositionMs : 504_000
        currentPositionMs = demoSimulatedPosMs
        currentDurationMs = demoSimulatedDurationMs
        currentBufferedMs = min(demoSimulatedDurationMs, demoSimulatedPosMs + 240_000)
        isPlaying = true
        centerPlayPauseButton.setPlaying(true)

        demoBackdropView.configure(
            title: effectiveDisplayTitle(),
            subtitle: effectiveDisplaySubtitle(),
            engineBadge: activeEngineMode == .mpv ? "libmpv Metal" : "AVPlayer HDR"
        )
        updateScrubberUI()

        // Seed crisp sample danmaku timeline for live 120Hz verification.
        let baseMs = Int(demoSimulatedPosMs)
        let sampleComments: [DanmuComment] = [
            DanmuComment(id: "demo_1", timeMs: baseMs + 200, mode: .scroll, colorRgb: 0xFFFFFF, text: "这画质和 HDR 光影太通透了！"),
            DanmuComment(id: "demo_2", timeMs: baseMs + 500, mode: .top, colorRgb: 0xFFE066, text: "前方高能名场面预警"),
            DanmuComment(id: "demo_3", timeMs: baseMs + 900, mode: .scroll, colorRgb: 0x74C0FC, text: "120Hz ProMotion 弹幕丝滑无卡顿"),
            DanmuComment(id: "demo_4", timeMs: baseMs + 1400, mode: .scroll, colorRgb: 0xFFFFFF, text: "Apple TV+ 级别的观影质感"),
            DanmuComment(id: "demo_5", timeMs: baseMs + 2100, mode: .scroll, colorRgb: 0xB2F2BB, text: "一键切换 AVPlayer / libmpv 双引擎太稳了"),
            DanmuComment(id: "demo_6", timeMs: baseMs + 2800, mode: .bottom, colorRgb: 0xFFD8A8, text: "配乐响起的瞬间鸡皮疙瘩起来了"),
            DanmuComment(id: "demo_7", timeMs: baseMs + 3500, mode: .scroll, colorRgb: 0xFFFFFF, text: "iPad 键盘快捷键支持好评"),
        ]
        danmakuView.isDanmakuEnabled = true
        danmakuView.load(comments: sampleComments)
        danmakuView.updatePlaybackTime(ms: demoSimulatedPosMs, isPlaying: true)
        danmakuView.sendLocalPreviewDanmaku("影院模式已就绪 · 120Hz 硬件合成弹幕", colorRgb: 0xFFFFFF, mode: .scroll)
        danmakuView.sendLocalPreviewDanmaku("双引擎随时热切换", colorRgb: 0x74C0FC, mode: .scroll)

        demoTimer?.invalidate()
        demoTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self, self.isPlaying else { return }
            self.demoSimulatedPosMs += Int64((500.0 * Double(self.currentRate)).rounded())
            if self.demoSimulatedPosMs >= self.demoSimulatedDurationMs {
                self.demoSimulatedPosMs = 0
            }
            self.handleUnifiedPositionUpdate(
                positionMs: self.demoSimulatedPosMs,
                durationMs: self.demoSimulatedDurationMs,
                bufferedMs: min(self.demoSimulatedDurationMs, self.demoSimulatedPosMs + 240_000)
            )
        }
    }

    // MARK: - Unified Playback Operations

    private func playPlayback() {
        isPlaying = true
        centerPlayPauseButton.setPlaying(true)
        if context.demoPreviewMode {
            danmakuView.setPaused(false)
            danmakuView.updatePlaybackTime(ms: currentPositionMs, isPlaying: true)
        } else if activeEngineMode == .avplayer {
            avEngine.play()
        } else {
            mpvMetalView.play()
        }
        scheduleHudAutoHide()
    }

    private func pausePlayback() {
        isPlaying = false
        centerPlayPauseButton.setPlaying(false)
        if context.demoPreviewMode {
            danmakuView.setPaused(true)
        } else if activeEngineMode == .avplayer {
            avEngine.pause()
        } else {
            mpvMetalView.pause()
        }
        persistWatchHistoryIfAllowed(force: true)
        cancelHudAutoHide()
    }

    private func togglePlayPause() {
        if isPlaying {
            pausePlayback()
        } else {
            playPlayback()
        }
    }

    private func seekToPosition(ms targetMs: Int64) {
        guard !context.isLive else { return }
        let clamped = currentDurationMs > 0 ? min(max(0, targetMs), currentDurationMs) : max(0, targetMs)
        currentPositionMs = clamped
        if context.demoPreviewMode {
            demoSimulatedPosMs = clamped
        } else if activeEngineMode == .avplayer {
            avEngine.seek(toMs: clamped)
        } else {
            mpvMetalView.seek(toMs: clamped)
        }
        danmakuView.updatePlaybackTime(ms: clamped, isPlaying: isPlaying)
        updateScrubberUI()
        scheduleHudAutoHide()
    }

    private func seekRelative(deltaMs: Int64) {
        seekToPosition(ms: currentPositionMs + deltaMs)
    }

    private func applyPlaybackRate(_ rate: Float, persist: Bool) {
        let clamped = max(0.5, min(rate, 3.0))
        currentRate = clamped
        speedButton.setContent(title: Self.formatRate(clamped), symbolName: "gauge.medium")
        if !context.demoPreviewMode {
            if activeEngineMode == .avplayer {
                avEngine.setRate(clamped)
            } else {
                mpvMetalView.setRate(clamped)
            }
        }
        if persist {
            storage.updatePreferences { $0.playSpeed = Double(clamped) }
        }
        rebuildMenus()
    }

    private func applyAspectMode(_ mode: MarcoVideoAspectMode) {
        aspectMode = mode
        avLayerView.setAspectMode(mode)
        mpvMetalView.setAspectMode(mode)
        storage.updatePreferences { $0.defaultAspectMode = mode.rawValue }
        showToast("画面比例：\(mode.displayTitle)")
        rebuildMenus()
    }

    private func applyVocalLoudness(_ preset: VocalLoudnessPreset) {
        vocalLoudness = preset
        avEngine.setVocalLoudness(preset)
        mpvMetalView.setVocalLoudness(preset)
        storage.updatePreferences { $0.vocalLoudness = preset }
        if activeEngineMode == .avplayer && preset != .off && MarcoMpvMetalView.isRuntimeAvailable {
            showToast("人声增强：\(preset.labelZh)（切换 libmpv 可享完整动态均衡）")
        } else {
            showToast("人声增强：\(preset.labelZh)")
        }
        rebuildMenus()
    }

    private func applyHdrToneMapping(_ mode: IosHdrToneMappingMode) {
        hdrToneMapping = mode
        mpvMetalView.setHdrToneMapping(mode)
        storage.updatePreferences { $0.hdrToneMapping = mode }
        showToast("HDR 色调映射：\(mode.labelZh)")
        rebuildMenus()
    }

    private func toggleAnime4k() {
        anime4kEnabled.toggle()
        mpvMetalView.setAnime4kEnabled(anime4kEnabled)
        storage.updatePreferences { $0.anime4kLightweight = self.anime4kEnabled }
        if anime4kEnabled && activeEngineMode == .avplayer {
            showToast(MarcoMpvMetalView.isRuntimeAvailable
                ? "已开启 Anime4K，切换至 libmpv 引擎后生效"
                : "已记录 Anime4K 偏好（完整版 libmpv 引擎生效）")
        } else {
            showToast(anime4kEnabled ? "Anime4K 轻量超分已开启" : "Anime4K 超分已关闭")
        }
        rebuildMenus()
    }

    // MARK: - Unified Position, Skip Intro/Outro & Sleep Timer Evaluation

    private func handleUnifiedPositionUpdate(positionMs: Int64, durationMs: Int64, bufferedMs: Int64) {
        currentPositionMs = max(0, positionMs)
        if durationMs > 0 {
            currentDurationMs = durationMs
        }
        currentBufferedMs = max(0, bufferedMs)

        if !isScrubbing {
            updateScrubberUI()
        }
        danmakuView.updatePlaybackTime(ms: currentPositionMs, isPlaying: isPlaying)
        evaluateSkipIntroOutroIfNeeded()
        persistWatchHistoryIfAllowed(force: false)
        onPlaybackStateChanged?(currentLineIndex, currentEpisodeIndex, currentPositionMs, currentDurationMs)
    }

    private func videoSkipStorageKey() -> String {
        let siteKey = context.site?.key ?? "direct"
        return "\(siteKey)\n\(context.video.id)"
    }

    private func effectiveSkipSeconds() -> (intro: Int, outro: Int) {
        if context.isPrivate, let mem = privateMemorySkipRecord {
            return (mem.intro, mem.outro)
        }
        if !context.isPrivate, let rec = storage.videoSkipRecord(for: videoSkipStorageKey()) {
            return (rec.intro, rec.outro)
        }
        let prefs = storage.preferences()
        return (prefs.skipIntroSec, prefs.skipOutroSec)
    }

    private func saveSkipRecord(intro: Int?, outro: Int?) {
        let existing = effectiveSkipSeconds()
        let next = VideoSkipRecord(
            intro: intro ?? existing.intro,
            outro: outro ?? existing.outro,
            updated: Int64(Date().timeIntervalSince1970 * 1000)
        )
        if context.isPrivate {
            privateMemorySkipRecord = next
        } else {
            storage.setVideoSkipRecord(next, for: videoSkipStorageKey())
        }
    }

    private func clearSkipRecord() {
        if context.isPrivate {
            privateMemorySkipRecord = nil
        } else {
            storage.setVideoSkipRecord(nil, for: videoSkipStorageKey())
        }
    }

    private func evaluateSkipIntroOutroIfNeeded() {
        guard !context.isLive, !context.demoPreviewMode, isPlaying, currentDurationMs > 30_000 else { return }
        let skip = effectiveSkipSeconds()

        if !introHandledForEpisode, skip.intro > 0 {
            let introMs = Int64(skip.intro) * 1000
            if currentPositionMs < introMs - 1_500 && currentDurationMs > introMs + 10_000 {
                introHandledForEpisode = true
                presentSkipBanner(kind: .intro(targetMs: introMs))
                return
            }
        }

        if !outroHandledForEpisode, skip.outro > 0, hasNextEpisode() {
            let outroMs = Int64(skip.outro) * 1000
            let remainingMs = currentDurationMs - currentPositionMs
            if remainingMs > 1_000 && remainingMs <= outroMs && currentPositionMs > 30_000 {
                outroHandledForEpisode = true
                presentSkipBanner(kind: .outro)
            }
        }
    }

    private func presentSkipBanner(kind: SkipBannerKind) {
        skipCountdownTimer?.invalidate()
        skipBannerKind = kind
        skipCountdownRemainingSec = 3
        updateSkipBannerText()
        skipBannerSurface.isHidden = false
        skipBannerSurface.alpha = 0
        UIView.animate(withDuration: 0.2) {
            self.skipBannerSurface.alpha = 1
        }
        skipCountdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.skipCountdownRemainingSec -= 1
            if self.skipCountdownRemainingSec <= 0 {
                self.executeActiveSkipBanner()
            } else {
                self.updateSkipBannerText()
            }
        }
    }

    private func updateSkipBannerText() {
        guard let kind = skipBannerKind else { return }
        switch kind {
        case .intro:
            skipBannerLabel.text = "即将跳过片头 (\(skipCountdownRemainingSec)s)"
        case .outro:
            skipBannerLabel.text = "即将跳片尾进入下一集 (\(skipCountdownRemainingSec)s)"
        }
    }

    private func executeActiveSkipBanner() {
        guard let kind = skipBannerKind else { return }
        dismissSkipBanner()
        switch kind {
        case .intro(let targetMs):
            seekToPosition(ms: targetMs)
            showToast("已跳过片头")
        case .outro:
            advanceToNextEpisode(autoTriggered: true)
        }
    }

    private func dismissSkipBanner() {
        skipCountdownTimer?.invalidate()
        skipCountdownTimer = nil
        skipBannerKind = nil
        skipBannerSurface.isHidden = true
    }

    @objc private func handleSkipBannerExecute() {
        MarcoHaptics.light()
        executeActiveSkipBanner()
    }

    @objc private func handleSkipBannerCancel() {
        MarcoHaptics.selection()
        dismissSkipBanner()
    }

    // MARK: - Sleep Timer (with 30s Pre-Expiry Warning)

    private func configureSleepTimer(_ mode: CinemaSleepTimerMode) {
        sleepTickTimer?.invalidate()
        sleepTickTimer = nil
        sleepTimerMode = mode
        sleepBannerSurface.isHidden = true

        switch mode {
        case .off:
            showToast("睡眠定时已关闭")
        case .endOfEpisode:
            showToast("睡眠定时：播完本集后暂停")
        case .countdown(let seconds):
            let mins = max(1, seconds / 60)
            showToast("睡眠定时：\(mins) 分钟后自动暂停")
            sleepTickTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                self?.tickSleepTimer()
            }
        }
        rebuildMenus()
    }

    private func tickSleepTimer() {
        guard case .countdown(let remaining) = sleepTimerMode else { return }
        let next = remaining - 1
        if next <= 0 {
            sleepTickTimer?.invalidate()
            sleepTickTimer = nil
            sleepTimerMode = .off
            sleepBannerSurface.isHidden = true
            pausePlayback()
            showToast("睡眠定时已结束，已暂停播放")
            rebuildMenus()
            return
        }
        sleepTimerMode = .countdown(remainingSeconds: next)
        if next <= 30 {
            sleepBannerLabel.text = "睡眠定时将在 \(next) 秒后暂停"
            if sleepBannerSurface.isHidden {
                sleepBannerSurface.isHidden = false
                sleepBannerSurface.alpha = 0
                UIView.animate(withDuration: 0.22) {
                    self.sleepBannerSurface.alpha = 1
                }
                MarcoHaptics.warning()
            }
        } else {
            sleepBannerSurface.isHidden = true
        }
    }

    @objc private func handleSleepTimerExtend15() {
        MarcoHaptics.light()
        if case .countdown(let remaining) = sleepTimerMode {
            configureSleepTimer(.countdown(remainingSeconds: remaining + 15 * 60))
        } else {
            configureSleepTimer(.countdown(remainingSeconds: 15 * 60))
        }
    }

    @objc private func handleSleepTimerCancel() {
        MarcoHaptics.selection()
        configureSleepTimer(.off)
    }

    // MARK: - Episode & Line Switching

    private func hasNextEpisode() -> Bool {
        guard let line = currentLine() else { return false }
        return currentEpisodeIndex + 1 < line.episodes.count
    }

    private func hasPreviousEpisode() -> Bool {
        currentEpisodeIndex > 0
    }

    private func advanceToNextEpisode(autoTriggered: Bool) {
        if autoTriggered, case .endOfEpisode = sleepTimerMode {
            sleepTimerMode = .off
            pausePlayback()
            showToast("本集已播完，睡眠定时已暂停播放")
            rebuildMenus()
            return
        }
        guard hasNextEpisode() else {
            let repeatMode = storage.preferences().repeatMode
            if repeatMode == "one" {
                seekToPosition(ms: 0)
                playPlayback()
            } else if repeatMode == "all", let line = currentLine(), !line.episodes.isEmpty {
                switchToEpisode(index: 0, startPositionMs: 0)
            } else {
                showToast("已是最后一集")
            }
            return
        }
        switchToEpisode(index: currentEpisodeIndex + 1, startPositionMs: 0)
    }

    private func switchToEpisode(index: Int, startPositionMs: Int64) {
        guard let line = currentLine(), line.episodes.indices.contains(index) else { return }
        persistWatchHistoryIfAllowed(force: true)
        currentEpisodeIndex = index
        openCurrentEpisode(startPositionMs: startPositionMs)
    }

    private func switchToLine(index: Int) {
        guard lines.indices.contains(index), index != currentLineIndex else { return }
        let carryPos = currentPositionMs
        currentLineIndex = index
        let epCount = lines[index].episodes.count
        if epCount > 0 {
            currentEpisodeIndex = min(currentEpisodeIndex, epCount - 1)
        } else {
            currentEpisodeIndex = 0
        }
        showToast("已切换线路：\(lines[index].name)")
        openCurrentEpisode(startPositionMs: carryPos)
    }

    // MARK: - Watch History & Danmaku

    private func persistWatchHistoryIfAllowed(force: Bool) {
        guard !context.isPrivate, !context.isLive, !context.demoPreviewMode else { return }
        guard currentDurationMs >= 30_000, currentPositionMs > 0 else { return }
        guard let site = context.site else { return }

        let now = CACurrentMediaTime()
        if !force && (now - lastHistoryPersistTime) < 10.0 {
            return
        }
        lastHistoryPersistTime = now

        let line = currentLine()
        let ep = currentEpisode()
        let item = WatchHistoryItem(
            site: site.key,
            id: context.video.id,
            title: context.video.title,
            poster: context.video.poster,
            line: line?.name ?? "",
            lineId: line?.id ?? "",
            episode: ep?.name ?? "",
            episodeMediaId: WatchHistoryItem.mediaIdentityForUrl(ep?.url ?? ""),
            subscriptionId: site.subscriptionId,
            sourceKey: site.sourceKey,
            sourceApi: site.sourceApi,
            index: currentEpisodeIndex,
            position: Int(min(currentPositionMs, Int64(Int.max))),
            duration: Int(min(currentDurationMs, Int64(Int.max))),
            updated: Int64(Date().timeIntervalSince1970 * 1000)
        )
        storage.upsertWatchHistory(item)
    }

    private func fetchDanmakuForCurrentEpisode() {
        let settings = danmuSettings
        guard settings.enabled, !settings.serverUrls.isEmpty else { return }
        let title = context.video.title
        let epNum = currentEpisodeIndex + 1

        danmuTask?.cancel()
        danmuTask = Task { [weak self] in
            guard let self = self else { return }
            do {
                let candidates = try await self.danmuService.searchEpisodes(
                    title: title,
                    episodeIndex: epNum,
                    settings: settings
                )
                guard let best = candidates.first else { return }
                let comments = try await self.danmuService.fetchComments(
                    origin: best.sourceOrigin,
                    episodeId: best.episodeId,
                    settings: settings
                )
                try Task.checkCancellation()
                await MainActor.run {
                    self.danmakuView.load(comments: comments)
                    self.danmakuView.updatePlaybackTime(ms: self.currentPositionMs, isPlaying: self.isPlaying)
                    if !comments.isEmpty {
                        self.showToast("已加载 \(comments.count) 条弹幕")
                    }
                }
            } catch {
                // Silent failure for optional danmaku servers
            }
        }
    }

    private func loadPosterArtworkForNowPlaying() {
        guard !context.video.poster.isEmpty else { return }
        posterImageToken = PosterImageLoader.shared.loadImage(
            urlString: context.video.poster,
            isPrivate: context.isPrivate
        ) { [weak self] image in
            guard let self = self, let img = image else { return }
            self.loadedPosterImage = img
            self.avEngine.updateNowPlayingMetadata(
                title: self.effectiveDisplayTitle(),
                subtitle: self.effectiveDisplaySubtitle(),
                posterImage: img,
                isLive: self.context.isLive
            )
        }
    }

    // MARK: - HUD Actions & Menus

    private func rebuildMenus() {
        // 1. Speed menu
        let rates: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0]
        let speedActions = rates.map { rate in
            UIAction(
                title: Self.formatRate(rate),
                state: abs(currentRate - rate) < 0.01 ? .on : .off
            ) { [weak self] _ in
                self?.applyPlaybackRate(rate, persist: true)
            }
        }
        speedButton.menu = UIMenu(title: "播放倍速", children: speedActions)
        speedButton.setContent(title: Self.formatRate(currentRate), symbolName: "gauge.medium")

        // 2. Lines switcher menu
        if lines.count > 1 {
            linesButton.isHidden = false
            let lineActions = lines.enumerated().map { idx, line in
                UIAction(
                    title: "\(line.name) (\(line.episodes.count))",
                    state: idx == currentLineIndex ? .on : .off
                ) { [weak self] _ in
                    self?.switchToLine(index: idx)
                }
            }
            linesButton.menu = UIMenu(title: "切换播放线路", children: lineActions)
            linesButton.setContent(title: currentLine()?.name ?? "线路", symbolName: "arrow.triangle.branch")
        } else {
            linesButton.isHidden = true
        }

        // 3. Audio & Subtitle tracks menu
        var trackSubmenus: [UIMenuElement] = []
        if !audioTracks.isEmpty {
            let audioActions = audioTracks.map { track in
                UIAction(title: track.displayLabel, state: track.isSelected ? .on : .off) { [weak self] _ in
                    self?.selectAudioTrack(track.id)
                }
            }
            trackSubmenus.append(UIMenu(title: "音轨", options: .displayInline, children: audioActions))
        }
        var subActions: [UIAction] = [
            UIAction(
                title: "关闭字幕",
                state: subtitleTracks.allSatisfy({ !$0.isSelected }) ? .on : .off
            ) { [weak self] _ in
                self?.selectSubtitleTrack(nil)
            },
        ]
        for track in subtitleTracks {
            subActions.append(
                UIAction(title: track.displayLabel, state: track.isSelected ? .on : .off) { [weak self] _ in
                    self?.selectSubtitleTrack(track.id)
                }
            )
        }
        trackSubmenus.append(UIMenu(title: "字幕", options: .displayInline, children: subActions))
        tracksButton.menu = UIMenu(title: "音轨与字幕", children: trackSubmenus)

        // 4. More cinema settings menu
        let aspectMenu = UIMenu(
            title: "画面比例",
            image: MarcoSymbols.image("aspectratio", pointSize: 14),
            children: MarcoVideoAspectMode.allCases.map { mode in
                UIAction(
                    title: mode.displayTitle,
                    image: MarcoSymbols.image(mode.symbolName, pointSize: 14),
                    state: aspectMode == mode ? .on : .off
                ) { [weak self] _ in
                    self?.applyAspectMode(mode)
                }
            }
        )

        let vocalMenu = UIMenu(
            title: "影院人声增强",
            image: MarcoSymbols.image("person.wave.2", pointSize: 14),
            children: VocalLoudnessPreset.allCases.map { preset in
                UIAction(title: preset.labelZh, state: vocalLoudness == preset ? .on : .off) { [weak self] _ in
                    self?.applyVocalLoudness(preset)
                }
            }
        )

        let hdrMenu = UIMenu(
            title: "HDR 色调映射",
            image: MarcoSymbols.image("sparkles.tv", pointSize: 14),
            children: IosHdrToneMappingMode.allCases.map { mode in
                UIAction(title: mode.labelZh, state: hdrToneMapping == mode ? .on : .off) { [weak self] _ in
                    self?.applyHdrToneMapping(mode)
                }
            }
        )

        let anime4kAction = UIAction(
            title: anime4kEnabled ? "关闭 Anime4K 超分" : "开启 Anime4K 轻量超分",
            image: MarcoSymbols.image("wand.and.stars", pointSize: 14),
            state: anime4kEnabled ? .on : .off
        ) { [weak self] _ in
            self?.toggleAnime4k()
        }

        let sleepMenu = UIMenu(
            title: "睡眠定时",
            image: MarcoSymbols.image("moon.zzz", pointSize: 14),
            children: [
                UIAction(title: "关闭", state: sleepTimerMode == .off ? .on : .off) { [weak self] _ in
                    self?.configureSleepTimer(.off)
                },
                UIAction(title: "15 分钟后") { [weak self] _ in
                    self?.configureSleepTimer(.countdown(remainingSeconds: 15 * 60))
                },
                UIAction(title: "30 分钟后") { [weak self] _ in
                    self?.configureSleepTimer(.countdown(remainingSeconds: 30 * 60))
                },
                UIAction(title: "60 分钟后") { [weak self] _ in
                    self?.configureSleepTimer(.countdown(remainingSeconds: 60 * 60))
                },
                UIAction(title: "播完本集", state: sleepTimerMode == .endOfEpisode ? .on : .off) { [weak self] _ in
                    self?.configureSleepTimer(.endOfEpisode)
                },
            ]
        )

        var moreChildren: [UIMenuElement] = [aspectMenu, anime4kAction, vocalMenu, hdrMenu, sleepMenu]

        if !context.isLive {
            let skip = effectiveSkipSeconds()
            let skipMenu = UIMenu(
                title: "片头 / 片尾跳过",
                image: MarcoSymbols.image("forward.frame", pointSize: 14),
                children: [
                    UIAction(title: "将当前位置设为片头（当前 \(skip.intro)s）") { [weak self] _ in
                        guard let self = self else { return }
                        let sec = min(600, max(0, Int(self.currentPositionMs / 1000)))
                        self.saveSkipRecord(intro: sec, outro: nil)
                        self.showToast("已设置跳过片头：\(sec) 秒" + (self.context.isPrivate ? "（仅本次内存生效）" : ""))
                        self.rebuildMenus()
                    },
                    UIAction(title: "将剩余时长设为片尾（当前 \(skip.outro)s）") { [weak self] _ in
                        guard let self = self else { return }
                        let rem = self.currentDurationMs > self.currentPositionMs
                            ? Int((self.currentDurationMs - self.currentPositionMs) / 1000)
                            : 0
                        let sec = min(600, max(0, rem))
                        self.saveSkipRecord(intro: nil, outro: sec)
                        self.showToast("已设置跳过片尾：\(sec) 秒" + (self.context.isPrivate ? "（仅本次内存生效）" : ""))
                        self.rebuildMenus()
                    },
                    UIAction(title: "清除本片跳过设置", attributes: .destructive) { [weak self] _ in
                        self?.clearSkipRecord()
                        self?.showToast("已清除本片跳过设置")
                        self?.rebuildMenus()
                    },
                ]
            )
            moreChildren.append(skipMenu)
        }

        moreMenuButton.menu = UIMenu(title: "影院设置", children: moreChildren)
    }

    private func selectAudioTrack(_ id: String?) {
        if activeEngineMode == .avplayer {
            avEngine.selectAudioTrack(id)
        } else {
            mpvMetalView.selectAudioTrack(id: id)
        }
        showToast("已切换音轨")
    }

    private func selectSubtitleTrack(_ id: String?) {
        if activeEngineMode == .avplayer {
            avEngine.selectSubtitleTrack(id)
        } else {
            mpvMetalView.selectSubtitleTrack(id: id)
        }
        showToast(id == nil ? "已关闭字幕" : "已切换字幕")
    }

    // MARK: - Button Handlers

    @objc private func handleCloseTapped() {
        MarcoHaptics.light()
        closePlayer()
    }

    private func closePlayer() {
        guard !isDismissing else { return }
        isDismissing = true
        persistWatchHistoryIfAllowed(force: true)
        onPlaybackStateChanged?(currentLineIndex, currentEpisodeIndex, currentPositionMs, currentDurationMs)
        teardownAllResources()
        dismiss(animated: true)
    }

    @objc private func handlePlayPauseTapped() {
        MarcoHaptics.light()
        togglePlayPause()
    }

    @objc private func handleSkipBackward15() {
        MarcoHaptics.light()
        seekRelative(deltaMs: -15_000)
    }

    @objc private func handleSkipForward15() {
        MarcoHaptics.light()
        seekRelative(deltaMs: 15_000)
    }

    @objc private func handleNextEpisodeTapped() {
        MarcoHaptics.light()
        advanceToNextEpisode(autoTriggered: false)
    }

    @objc private func handlePipTapped() {
        MarcoHaptics.selection()
        if context.demoPreviewMode {
            showToast("预览模式下不支持系统画中画")
            return
        }
        if activeEngineMode == .mpv {
            hotSwitchEngine(to: .avplayer, persistPreference: false, reason: "已切换至 AVPlayer 以支持系统画中画")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                _ = self?.avEngine.startPictureInPicture()
            }
            return
        }
        if avEngine.state.isPipActive {
            avEngine.stopPictureInPicture()
        } else {
            if !avEngine.startPictureInPicture() {
                showToast("请等待画面缓冲就绪后再开启画中画")
            }
        }
    }

    @objc private func handleDlnaCastTapped() {
        MarcoHaptics.selection()
        let sheet = CinemaDlnaCastSheetController(
            castService: castService,
            mediaURL: currentResolvedURL,
            mediaTitle: effectiveDisplayTitle()
        )
        MarcoModalPresenter.present(
            sheet,
            from: self,
            options: MarcoModalOptions(
                detents: [.medium, .large],
                preferredFormSheetSize: CGSize(width: 460, height: 520),
                sourceView: castButton,
                wrapInNavigationController: true
            )
        )
    }

    @objc private func handleEpisodesTapped() {
        MarcoHaptics.selection()
        guard let line = currentLine(), !line.episodes.isEmpty else {
            showToast("当前片源暂无剧集列表")
            return
        }
        let sheet = CinemaEpisodesSheetController(
            lineName: line.name,
            episodes: line.episodes,
            selectedIndex: currentEpisodeIndex,
            descending: storage.preferences().episodesDescending,
            onToggleOrder: { [weak self] desc in
                self?.storage.updatePreferences { $0.episodesDescending = desc }
            },
            onSelectEpisode: { [weak self] idx in
                self?.switchToEpisode(index: idx, startPositionMs: 0)
            }
        )
        MarcoModalPresenter.present(
            sheet,
            from: self,
            options: MarcoModalOptions(
                detents: [.medium, .large],
                preferredFormSheetSize: CGSize(width: 480, height: 540),
                sourceView: episodesButton,
                wrapInNavigationController: true
            )
        )
    }

    @objc private func handleDanmakuToggleTapped() {
        MarcoHaptics.selection()
        let nextEnabled = !danmakuView.isDanmakuEnabled
        danmakuView.isDanmakuEnabled = nextEnabled
        danmuSettings.enabled = nextEnabled
        storage.saveDanmuSettings(danmuSettings)
        refreshDanmakuButtonAppearance()
        if nextEnabled && !context.demoPreviewMode {
            fetchDanmakuForCurrentEpisode()
        }
        showToast(nextEnabled ? "弹幕已开启" : "弹幕已关闭")
    }

    @objc private func handleDanmakuSettingsTapped() {
        MarcoHaptics.selection()
        let sheet = CinemaDanmakuSettingsSheetController(
            settings: danmuSettings,
            onChange: { [weak self] updated in
                guard let self = self else { return }
                self.danmuSettings = updated
                self.danmakuView.applySettings(updated)
                self.danmakuView.isDanmakuEnabled = updated.enabled
                self.storage.saveDanmuSettings(updated)
                self.refreshDanmakuButtonAppearance()
            }
        )
        MarcoModalPresenter.present(
            sheet,
            from: self,
            options: MarcoModalOptions(
                detents: [.medium],
                preferredFormSheetSize: CGSize(width: 420, height: 460),
                sourceView: danmakuSettingsButton,
                wrapInNavigationController: true
            )
        )
    }

    @objc private func handleLockToggleTapped() {
        MarcoHaptics.medium()
        isScreenLocked.toggle()
        let symbol = isScreenLocked ? "lock.fill" : "lock.open"
        lockToggleButton.setSymbol(symbol, pointSize: 16)
        if isScreenLocked {
            setHudVisible(false, animated: true)
            showToast("已锁定屏幕手势")
        } else {
            setHudVisible(true, animated: true)
            showToast("已解除屏幕锁定")
        }
    }

    @objc private func handleOrientationToggleTapped() {
        MarcoHaptics.light()
        let isCurrentlyLandscape = view.bounds.width > view.bounds.height
        let targetMask: UIInterfaceOrientationMask = isCurrentlyLandscape ? .portrait : .landscapeRight
        preferredOrientationMask = targetMask

        if #available(iOS 16.0, *) {
            setNeedsUpdateOfSupportedInterfaceOrientations()
            if let windowScene = view.window?.windowScene {
                let prefs = UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: targetMask)
                windowScene.requestGeometryUpdate(prefs) { _ in }
            }
        } else {
            let value = isCurrentlyLandscape
                ? UIInterfaceOrientation.portrait.rawValue
                : UIInterfaceOrientation.landscapeRight.rawValue
            UIDevice.current.setValue(value, forKey: "orientation")
            UIViewController.attemptRotationToDeviceOrientation()
        }
    }

    @objc private func handleToggleRemainingTimeDisplay() {
        showRemainingTime.toggle()
        updateScrubberUI()
    }

    @objc private func handleErrorRetryTapped() {
        errorOverlaySurface.isHidden = true
        openCurrentEpisode(startPositionMs: currentPositionMs)
    }

    @objc private func handleErrorSwitchLineTapped() {
        guard lines.count > 1 else {
            showToast("暂无其他备用线路")
            return
        }
        errorOverlaySurface.isHidden = true
        let nextLine = (currentLineIndex + 1) % lines.count
        switchToLine(index: nextLine)
    }

    // MARK: - Scrubber Handlers

    @objc private func handleScrubberTouchDown() {
        isScrubbing = true
        cancelHudAutoHide()
    }

    @objc private func handleScrubberValueChanged() {
        guard currentDurationMs > 0 else { return }
        let targetMs = Int64((Double(progressSlider.value) * Double(currentDurationMs)).rounded())
        elapsedTimeLabel.text = Self.formatTime(ms: targetMs)
        let remMs = max(0, currentDurationMs - targetMs)
        remainingTimeLabel.text = showRemainingTime ? "-\(Self.formatTime(ms: remMs))" : Self.formatTime(ms: currentDurationMs)
        showGestureHud(symbol: "clock.arrow.circlepath", text: Self.formatTime(ms: targetMs), progress: progressSlider.value)
    }

    @objc private func handleScrubberTouchUp() {
        isScrubbing = false
        hideGestureHud()
        guard currentDurationMs > 0 else { return }
        let targetMs = Int64((Double(progressSlider.value) * Double(currentDurationMs)).rounded())
        seekToPosition(ms: targetMs)
    }

    // MARK: - Magic Keyboard Shortcuts

    @objc private func handleKeyTogglePlayPause() { togglePlayPause() }
    @objc private func handleKeySeekBackward() { seekRelative(deltaMs: -10_000) }
    @objc private func handleKeySeekForward() { seekRelative(deltaMs: 10_000) }
    @objc private func handleKeyVolumeUp() {
        let next = avEngine.setSystemVolume(avEngine.currentSystemVolume() + 0.1)
        showTemporaryGesturePill(symbol: "speaker.wave.2.fill", text: "\(Int((next * 100).rounded()))%", progress: next)
    }
    @objc private func handleKeyVolumeDown() {
        let next = avEngine.setSystemVolume(avEngine.currentSystemVolume() - 0.1)
        showTemporaryGesturePill(
            symbol: next <= 0.01 ? "speaker.slash.fill" : "speaker.wave.1.fill",
            text: "\(Int((next * 100).rounded()))%",
            progress: next
        )
    }
    @objc private func handleKeyClose() { closePlayer() }
    @objc private func handleKeyToggleDanmaku() { handleDanmakuToggleTapped() }
    @objc private func handleKeyOpenEpisodes() { handleEpisodesTapped() }

    // MARK: - HUD Visibility & Visual Updates

    private func setHudVisible(_ visible: Bool, animated: Bool) {
        isHudVisible = visible
        let changes = {
            self.hudContainerView.alpha = visible ? 1.0 : 0.0
            self.lockToggleButton.alpha = (visible || self.isScreenLocked) ? (self.isScreenLocked ? 0.65 : 1.0) : 0.0
        }
        if animated && !UIAccessibility.isReduceMotionEnabled {
            UIView.animate(withDuration: 0.22, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState], animations: changes)
        } else {
            changes()
        }
        hudContainerView.isUserInteractionEnabled = visible
        setNeedsUpdateOfHomeIndicatorAutoHidden()
        if visible {
            scheduleHudAutoHide()
        } else {
            cancelHudAutoHide()
        }
    }

    private func flashLockButton() {
        lockToggleButton.alpha = 1.0
        UIView.animate(withDuration: 0.25, delay: 1.6, options: [.allowUserInteraction], animations: {
            self.lockToggleButton.alpha = self.isScreenLocked ? 0.35 : 0.0
        })
    }

    private func scheduleHudAutoHide() {
        cancelHudAutoHide()
        guard isPlaying, !isScrubbing, !context.demoPreviewMode else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.isPlaying, !self.isScrubbing else { return }
            self.setHudVisible(false, animated: true)
        }
        hudAutoHideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.5, execute: work)
    }

    private func cancelHudAutoHide() {
        hudAutoHideWorkItem?.cancel()
        hudAutoHideWorkItem = nil
    }

    private func showToast(_ message: String) {
        toastHideWorkItem?.cancel()
        toastLabel.text = message
        toastPill.isHidden = false
        toastPill.alpha = 0
        UIView.animate(withDuration: 0.18) {
            self.toastPill.alpha = 1
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            UIView.animate(withDuration: 0.22, animations: {
                self.toastPill.alpha = 0
            }) { _ in
                if self.toastPill.alpha == 0 {
                    self.toastPill.isHidden = true
                }
            }
        }
        toastHideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4, execute: work)
    }

    private func setBufferingOverlay(visible: Bool, text: String?) {
        isBuffering = visible
        if let text = text {
            bufferingLabel.text = text
        }
        bufferingContainer.isHidden = !visible
        if visible {
            bufferingIndicator.startAnimating()
        } else {
            bufferingIndicator.stopAnimating()
        }
    }

    private func showPlaybackError(_ detail: String) {
        errorDetailLabel.text = detail
        errorSwitchLineButton.isHidden = lines.count <= 1
        errorOverlaySurface.isHidden = false
        setHudVisible(true, animated: true)
    }

    private func refreshMetadataLabels() {
        titleLabel.text = effectiveDisplayTitle()
        subtitleMetaLabel.text = effectiveDisplaySubtitle()
        liveStatusLabel.text = "LIVE · \(context.liveChannelName ?? context.video.title)"
    }

    private func effectiveDisplayTitle() -> String {
        if context.isLive, let ch = context.liveChannelName, !ch.isEmpty {
            return ch
        }
        return context.video.title.isEmpty ? "Marco Cinema" : context.video.title
    }

    private func effectiveDisplaySubtitle() -> String {
        if context.isLive {
            return context.site?.name ?? "电视直播"
        }
        var parts: [String] = []
        if let ep = currentEpisode(), !ep.name.isEmpty {
            parts.append(ep.name)
        }
        if let line = currentLine(), !line.name.isEmpty {
            parts.append(line.name)
        }
        if !currentResolutionBadge.isEmpty {
            parts.append(currentResolutionBadge)
        }
        if activeEngineMode == .avplayer && avEngine.state.isHdr {
            parts.append("HDR")
        }
        return parts.isEmpty ? (context.demoPreviewMode ? "4K HDR · 影院演示模式" : "影院播放") : parts.joined(separator: " · ")
    }

    private func refreshDanmakuButtonAppearance() {
        let on = danmakuView.isDanmakuEnabled
        danmakuToggleButton.setContent(
            title: on ? "弹幕开" : "弹幕关",
            symbolName: on ? "captions.bubble.fill" : "captions.bubble"
        )
    }

    private func refreshEpisodeNavigationVisibility() {
        let epCount = currentLine()?.episodes.count ?? 0
        episodesButton.isHidden = context.isLive || epCount <= 1
        nextEpisodeButton.isHidden = context.isLive || !hasNextEpisode()
    }

    private func updateScrubberUI() {
        guard !context.isLive else { return }
        elapsedTimeLabel.text = Self.formatTime(ms: currentPositionMs)
        if currentDurationMs > 0 {
            let fraction = Float(min(max(0, Double(currentPositionMs) / Double(currentDurationMs)), 1.0))
            progressSlider.value = fraction
            let bufFraction = Float(min(max(0, Double(currentBufferedMs) / Double(currentDurationMs)), 1.0))
            bufferedProgressView.progress = bufFraction
            let remMs = max(0, currentDurationMs - currentPositionMs)
            remainingTimeLabel.text = showRemainingTime
                ? "-\(Self.formatTime(ms: remMs))"
                : Self.formatTime(ms: currentDurationMs)
        } else {
            progressSlider.value = 0
            bufferedProgressView.progress = 0
            remainingTimeLabel.text = "--:--"
        }
    }

    private func startClockTimerIfNeeded() {
        guard storage.preferences().playerAlwaysShowClock else { return }
        updateClockText()
        clockUpdateTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.updateClockText()
        }
    }

    private func updateClockText() {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        clockLabel.text = fmt.string(from: Date())
    }

    // MARK: - MarcoAvPlayerEngineDelegate

    public func avPlayerEngine(
        _ engine: MarcoAvPlayerEngine,
        onPositionUpdate positionMs: Int64,
        durationMs: Int64,
        bufferedMs: Int64
    ) {
        guard activeEngineMode == .avplayer else { return }
        handleUnifiedPositionUpdate(positionMs: positionMs, durationMs: durationMs, bufferedMs: bufferedMs)
    }

    public func avPlayerEngine(_ engine: MarcoAvPlayerEngine, onBufferingChanged isBuffering: Bool) {
        guard activeEngineMode == .avplayer else { return }
        setBufferingOverlay(visible: isBuffering, text: "正在缓冲...")
    }

    public func avPlayerEngine(_ engine: MarcoAvPlayerEngine, onPlaybackStateChanged state: MarcoAvPlayerState) {
        guard activeEngineMode == .avplayer else { return }
        isPlaying = state.isPlaying
        centerPlayPauseButton.setPlaying(state.isPlaying)
        danmakuView.setPaused(!state.isPlaying)
        refreshMetadataLabels()
        if state.isPlaying {
            scheduleHudAutoHide()
        }
    }

    public func avPlayerEngine(
        _ engine: MarcoAvPlayerEngine,
        onTracksUpdated audioTracks: [MarcoMediaTrack],
        subtitleTracks: [MarcoMediaTrack]
    ) {
        guard activeEngineMode == .avplayer else { return }
        self.audioTracks = audioTracks
        self.subtitleTracks = subtitleTracks
        rebuildMenus()
    }

    public func avPlayerEngine(_ engine: MarcoAvPlayerEngine, onSubtitleCue lines: [String], hasNativeSamples: Bool) {
        guard activeEngineMode == .avplayer else { return }
        if lines.isEmpty {
            subtitleBackdropView.isHidden = true
            subtitleLabel.text = nil
        } else {
            subtitleLabel.text = lines.joined(separator: "\n")
            subtitleBackdropView.isHidden = false
        }
    }

    public func avPlayerEngine(
        _ engine: MarcoAvPlayerEngine,
        onPipStateChanged isActive: Bool,
        isPossible: Bool,
        phase: String,
        error: String?
    ) {
        pipButton.setSymbol(isActive ? "pip.exit" : "pip.enter", pointSize: 14)
        if let err = error, !err.isEmpty, phase == "failed" {
            showToast(err)
        }
    }

    public func avPlayerEngine(_ engine: MarcoAvPlayerEngine, onAirPlayChanged isActive: Bool, deviceName: String) {
        if isActive {
            let target = deviceName.isEmpty ? "AirPlay 设备" : deviceName
            showToast("正在通过 AirPlay 投屏至 \(target)")
        }
    }

    public func avPlayerEngineDidComplete(_ engine: MarcoAvPlayerEngine) {
        guard activeEngineMode == .avplayer else { return }
        if storage.preferences().autoNext {
            advanceToNextEpisode(autoTriggered: true)
        } else {
            showToast("本集播放完成")
            setHudVisible(true, animated: true)
        }
    }

    public func avPlayerEngine(_ engine: MarcoAvPlayerEngine, onFallbackToMpv positionMs: Int64, reason: String) {
        guard activeEngineMode == .avplayer else { return }
        if MarcoMpvMetalView.isRuntimeAvailable && !hasFallbackOccurredForCurrentLoad {
            hasFallbackOccurredForCurrentLoad = true
            currentPositionMs = max(currentPositionMs, positionMs)
            hotSwitchEngine(
                to: .mpv,
                persistPreference: false,
                reason: "AVPlayer 无法解码，已自动切换至 libmpv"
            )
        } else {
            setBufferingOverlay(visible: false, text: nil)
            showPlaybackError(reason)
        }
    }

    public func avPlayerEngineDidRequestNextTrack(_ engine: MarcoAvPlayerEngine) {
        advanceToNextEpisode(autoTriggered: false)
    }

    public func avPlayerEngineDidRequestPreviousTrack(_ engine: MarcoAvPlayerEngine) {
        if hasPreviousEpisode() {
            switchToEpisode(index: currentEpisodeIndex - 1, startPositionMs: 0)
        }
    }

    // MARK: - MarcoMpvMetalViewDelegate

    public func mpvMetalView(
        _ view: MarcoMpvMetalView,
        onPositionUpdate positionMs: Int64,
        durationMs: Int64,
        bufferedMs: Int64
    ) {
        guard activeEngineMode == .mpv else { return }
        handleUnifiedPositionUpdate(positionMs: positionMs, durationMs: durationMs, bufferedMs: bufferedMs)
    }

    public func mpvMetalView(_ view: MarcoMpvMetalView, onBufferingChanged isBuffering: Bool) {
        guard activeEngineMode == .mpv else { return }
        setBufferingOverlay(visible: isBuffering, text: "libmpv 正在缓冲...")
    }

    public func mpvMetalView(
        _ view: MarcoMpvMetalView,
        onPlaybackStateChanged isPlaying: Bool,
        isBuffering: Bool,
        rate: Float
    ) {
        guard activeEngineMode == .mpv else { return }
        self.isPlaying = isPlaying
        centerPlayPauseButton.setPlaying(isPlaying)
        danmakuView.setPaused(!isPlaying)
        if isPlaying {
            scheduleHudAutoHide()
        }
    }

    public func mpvMetalView(_ view: MarcoMpvMetalView, onTracksUpdated snapshot: MarcoMpvTracksSnapshot) {
        guard activeEngineMode == .mpv else { return }
        audioTracks = snapshot.audioTracks
        subtitleTracks = snapshot.subtitleTracks
        rebuildMenus()
    }

    public func mpvMetalViewDidComplete(_ view: MarcoMpvMetalView) {
        guard activeEngineMode == .mpv else { return }
        if storage.preferences().autoNext {
            advanceToNextEpisode(autoTriggered: true)
        } else {
            showToast("本集播放完成")
            setHudVisible(true, animated: true)
        }
    }

    public func mpvMetalView(_ view: MarcoMpvMetalView, onError message: String) {
        guard activeEngineMode == .mpv else { return }
        setBufferingOverlay(visible: false, text: nil)
        showPlaybackError(message)
    }

    public func mpvMetalView(_ view: MarcoMpvMetalView, onUnavailable reason: String) {
        showToast(reason)
        if let url = currentResolvedURL {
            startPlayback(
                on: .avplayer,
                url: url,
                headers: currentResolvedHeaders,
                startPositionMs: currentPositionMs
            )
        }
    }

    // MARK: - Cleanup & Formatters

    private func revokeActiveProxyLeases() {
        activeOfflineHlsLease?.close()
        activeOfflineHlsLease = nil
        if let sid = activeHeaderProxySessionId {
            headerProxy.revokeSession(sid)
            activeHeaderProxySessionId = nil
        }
        if let rid = activeRangeProxyResourceId {
            activeRangeProxyResourceId = nil
            let proxy = rangeProxy
            Task {
                await proxy.revokeResource(rid)
            }
        }
    }

    private func teardownAllResources() {
        resolveTask?.cancel()
        resolveTask = nil
        danmuTask?.cancel()
        danmuTask = nil
        posterImageToken?.cancel()
        posterImageToken = nil

        demoTimer?.invalidate()
        demoTimer = nil
        skipCountdownTimer?.invalidate()
        skipCountdownTimer = nil
        sleepTickTimer?.invalidate()
        sleepTickTimer = nil
        clockUpdateTimer?.invalidate()
        clockUpdateTimer = nil
        cancelHudAutoHide()
        toastHideWorkItem?.cancel()
        toastHideWorkItem = nil

        danmakuView.clear()
        avEngine.stop()
        mpvMetalView.destroy()
        revokeActiveProxyLeases()
        headerProxy.stop()
        rangeProxy.stop()
    }

    private static func formatTime(ms: Int64) -> String {
        let totalSec = max(0, Int(ms / 1000))
        let h = totalSec / 3600
        let m = (totalSec % 3600) / 60
        let s = totalSec % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }

    private static func formatRate(_ rate: Float) -> String {
        if abs(rate - Float(Int(rate))) < 0.01 {
            return String(format: "%.1fx", rate)
        }
        return String(format: "%.2gx", rate)
    }

    private static func makeScrubberThumbImage(diameter: CGFloat) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: diameter, height: diameter))
        return renderer.image { ctx in
            let rect = CGRect(x: 1, y: 1, width: diameter - 2, height: diameter - 2)
            ctx.cgContext.setShadow(offset: CGSize(width: 0, height: 1), blur: 3, color: UIColor.black.withAlphaComponent(0.45).cgColor)
            UIColor.white.setFill()
            UIBezierPath(ovalIn: rect).fill()
        }
    }
}

// MARK: - HUD Control Components

private final class CinemaHudButton: UIButton {
    private let diameter: CGFloat

    init(symbolName: String, pointSize: CGFloat, diameter: CGFloat = 36) {
        self.diameter = diameter
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        tintColor = .white
        backgroundColor = UIColor.white.withAlphaComponent(0.10)
        layer.cornerCurve = .continuous
        setSymbol(symbolName, pointSize: pointSize)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: diameter),
            heightAnchor.constraint(equalToConstant: diameter),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setSymbol(_ name: String, pointSize: CGFloat) {
        let img = MarcoSymbols.image(name, pointSize: pointSize, weight: .semibold)
        setImage(img, for: .normal)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = diameter * 0.5
    }

    override var isHighlighted: Bool {
        didSet {
            alpha = isHighlighted ? 0.65 : 1.0
        }
    }
}

private final class CinemaCenterPlayButton: UIButton {
    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = UIColor.white.withAlphaComponent(0.92)
        tintColor = UIColor(red: 0.05, green: 0.06, blue: 0.08, alpha: 1.0)
        layer.cornerCurve = .continuous
        setPlaying(false)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 64),
            heightAnchor.constraint(equalToConstant: 64),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setPlaying(_ playing: Bool) {
        let symbol = playing ? "pause.fill" : "play.fill"
        setImage(MarcoSymbols.image(symbol, pointSize: 26, weight: .bold), for: .normal)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height * 0.5
    }

    override var isHighlighted: Bool {
        didSet {
            UIView.animate(withDuration: 0.14) {
                self.transform = self.isHighlighted ? CGAffineTransform(scaleX: 0.93, y: 0.93) : .identity
            }
        }
    }
}

private final class CinemaHudPillButton: UIButton {
    private var currentTitleText: String
    private var currentSymbolName: String?
    private var isCompact = false

    var iconView: UIImageView? {
        imageView
    }

    init(title: String, symbolName: String? = nil) {
        self.currentTitleText = title
        self.currentSymbolName = symbolName
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        layer.cornerCurve = .continuous
        titleLabel?.numberOfLines = 1
        titleLabel?.lineBreakMode = .byClipping
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .horizontal)
        rebuildAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setContent(title: String, symbolName: String? = nil) {
        currentTitleText = title
        currentSymbolName = symbolName
        rebuildAppearance()
    }

    func setCompactMode(_ compact: Bool) {
        guard isCompact != compact else { return }
        isCompact = compact
        rebuildAppearance()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        #if compiler(>=6.2)
        if #available(iOS 26.0, *), !UIAccessibility.isReduceTransparencyEnabled {
            return
        }
        #endif
        layer.cornerRadius = bounds.height * 0.5
    }

    private func rebuildAppearance() {
        let symbol = currentSymbolName.flatMap {
            MarcoSymbols.image($0, pointSize: 12.5, weight: .semibold)
        }
        let horizontalInset: CGFloat = isCompact ? 8 : 11
        let imagePadding: CGFloat = isCompact ? 4 : 5

        if #available(iOS 15.0, *) {
            var attr = AttributedString(currentTitleText)
            attr.font = MarcoTypography.badge
            #if compiler(>=6.2)
            if #available(iOS 26.0, *), !UIAccessibility.isReduceTransparencyEnabled {
                var cfg = UIButton.Configuration.glass()
                cfg.attributedTitle = attr
                cfg.titleLineBreakMode = .byClipping
                cfg.image = symbol
                cfg.imagePadding = imagePadding
                cfg.baseForegroundColor = .white
                cfg.baseBackgroundColor = UIColor.white.withAlphaComponent(0.14)
                cfg.cornerStyle = .capsule
                cfg.contentInsets = NSDirectionalEdgeInsets(
                    top: 6,
                    leading: horizontalInset,
                    bottom: 6,
                    trailing: horizontalInset
                )
                self.configuration = cfg
                self.cornerConfiguration = .capsule()
                return
            }
            #endif
            var cfg = UIButton.Configuration.filled()
            cfg.attributedTitle = attr
            cfg.titleLineBreakMode = .byClipping
            cfg.image = symbol
            cfg.imagePadding = imagePadding
            cfg.baseForegroundColor = .white
            cfg.baseBackgroundColor = UIColor.white.withAlphaComponent(0.14)
            cfg.cornerStyle = .capsule
            cfg.contentInsets = NSDirectionalEdgeInsets(
                top: 6,
                leading: horizontalInset,
                bottom: 6,
                trailing: horizontalInset
            )
            self.configuration = cfg
        } else {
            backgroundColor = UIColor.white.withAlphaComponent(0.16)
            tintColor = .white
            setTitleColor(.white, for: .normal)
            setTitle(currentTitleText, for: .normal)
            titleLabel?.font = MarcoTypography.badge
            titleLabel?.numberOfLines = 1
            titleLabel?.lineBreakMode = .byClipping
            setImage(symbol, for: .normal)
            contentEdgeInsets = UIEdgeInsets(
                top: 6,
                left: horizontalInset,
                bottom: 6,
                right: horizontalInset
            )
            if symbol != nil {
                imageEdgeInsets = UIEdgeInsets(top: 0, left: -2, bottom: 0, right: 2)
                titleEdgeInsets = UIEdgeInsets(top: 0, left: 2, bottom: 0, right: -2)
            }
        }
    }
}

// MARK: - Demo Preview Cinema Stage (Zero Network Required)

private final class CinemaDemoBackdropView: UIView {
    private let artworkImageView = UIImageView()
    private let vignetteLayer = CAGradientLayer()
    private let badgeSurface = MarcoGlassSurfaceView(style: .capsule, cornerRadius: 14)
    private let badgeLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(red: 0.04, green: 0.05, blue: 0.08, alpha: 1.0)
        isUserInteractionEnabled = false

        artworkImageView.translatesAutoresizingMaskIntoConstraints = false
        artworkImageView.contentMode = .scaleAspectFill
        artworkImageView.clipsToBounds = true
        addSubview(artworkImageView)
        NSLayoutConstraint.activate([
            artworkImageView.topAnchor.constraint(equalTo: topAnchor),
            artworkImageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            artworkImageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            artworkImageView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        vignetteLayer.colors = [
            UIColor.black.withAlphaComponent(0.35).cgColor,
            UIColor.clear.cgColor,
            UIColor.black.withAlphaComponent(0.50).cgColor,
        ]
        layer.addSublayer(vignetteLayer)

        badgeSurface.translatesAutoresizingMaskIntoConstraints = false
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        badgeLabel.font = MarcoTypography.badge
        badgeLabel.textColor = UIColor.white.withAlphaComponent(0.88)
        badgeSurface.contentView.addSubview(badgeLabel)
        addSubview(badgeSurface)
        NSLayoutConstraint.activate([
            badgeLabel.topAnchor.constraint(equalTo: badgeSurface.contentView.topAnchor, constant: 6),
            badgeLabel.bottomAnchor.constraint(equalTo: badgeSurface.contentView.bottomAnchor, constant: -6),
            badgeLabel.leadingAnchor.constraint(equalTo: badgeSurface.contentView.leadingAnchor, constant: 12),
            badgeLabel.trailingAnchor.constraint(equalTo: badgeSurface.contentView.trailingAnchor, constant: -12),
            badgeSurface.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -20),
            badgeSurface.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 74),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(title: String, subtitle: String, engineBadge: String) {
        artworkImageView.image = PosterImageLoader.makeStudioPlaceholder(
            title: title,
            subtitle: subtitle,
            seed: title,
            aspectRatio: 16.0 / 9.0,
            size: CGSize(width: 960, height: 540)
        )
        badgeLabel.text = "CINEMA PREVIEW · \(engineBadge)"
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        vignetteLayer.frame = bounds
        CATransaction.commit()
    }
}

// MARK: - Episodes Drawer Sheet

private final class CinemaEpisodesSheetController: UIViewController,
    UICollectionViewDataSource,
    UICollectionViewDelegateFlowLayout
{
    private let lineName: String
    private let episodes: [CmsEpisode]
    private var selectedIndex: Int
    private var descending: Bool
    private let onToggleOrder: (Bool) -> Void
    private let onSelectEpisode: (Int) -> Void

    private lazy var collectionView: UICollectionView = {
        let layout = UICollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 10
        layout.minimumLineSpacing = 10
        layout.sectionInset = UIEdgeInsets(top: 14, left: 16, bottom: 20, right: 16)
        let cv = UICollectionView(frame: .zero, collectionViewLayout: layout)
        cv.translatesAutoresizingMaskIntoConstraints = false
        cv.backgroundColor = .clear
        cv.dataSource = self
        cv.delegate = self
        cv.register(EpisodePillCell.self, forCellWithReuseIdentifier: EpisodePillCell.reuseId)
        return cv
    }()

    init(
        lineName: String,
        episodes: [CmsEpisode],
        selectedIndex: Int,
        descending: Bool,
        onToggleOrder: @escaping (Bool) -> Void,
        onSelectEpisode: @escaping (Int) -> Void
    ) {
        self.lineName = lineName
        self.episodes = episodes
        self.selectedIndex = selectedIndex
        self.descending = descending
        self.onToggleOrder = onToggleOrder
        self.onSelectEpisode = onSelectEpisode
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = .dark
        view.backgroundColor = MarcoColors.canvasBackground
        title = "选集 · \(lineName)"

        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: descending ? "倒序" : "正序",
            style: .plain,
            target: self,
            action: #selector(handleToggleOrder)
        )
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "完成",
            style: .done,
            target: self,
            action: #selector(handleDismiss)
        )

        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func actualIndex(for row: Int) -> Int {
        descending ? (episodes.count - 1 - row) : row
    }

    @objc private func handleToggleOrder() {
        descending.toggle()
        navigationItem.leftBarButtonItem?.title = descending ? "倒序" : "正序"
        onToggleOrder(descending)
        collectionView.reloadData()
    }

    @objc private func handleDismiss() {
        dismiss(animated: true)
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        episodes.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: EpisodePillCell.reuseId, for: indexPath) as! EpisodePillCell
        let idx = actualIndex(for: indexPath.item)
        cell.configure(title: episodes[idx].name, isCurrent: idx == selectedIndex)
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        let idx = actualIndex(for: indexPath.item)
        MarcoHaptics.selection()
        dismiss(animated: true) { [onSelectEpisode] in
            onSelectEpisode(idx)
        }
    }

    func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> CGSize {
        let columns: CGFloat = collectionView.bounds.width >= 420 ? 4 : 3
        let totalSpacing = 32 + (columns - 1) * 10
        let width = floor((collectionView.bounds.width - totalSpacing) / columns)
        return CGSize(width: max(84, width), height: 42)
    }

    private final class EpisodePillCell: UICollectionViewCell {
        static let reuseId = "EpisodePillCell"
        private let label = UILabel()

        override init(frame: CGRect) {
            super.init(frame: frame)
            contentView.applyContinuousCorners(11)
            label.translatesAutoresizingMaskIntoConstraints = false
            label.font = MarcoTypography.cardSubtitle
            label.textAlignment = .center
            label.lineBreakMode = .byTruncatingMiddle
            contentView.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
                label.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
                label.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            ])
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        func configure(title: String, isCurrent: Bool) {
            label.text = title
            if isCurrent {
                contentView.backgroundColor = .white
                label.textColor = UIColor(red: 0.05, green: 0.06, blue: 0.08, alpha: 1.0)
                label.font = MarcoTypography.badge
            } else {
                contentView.backgroundColor = MarcoColors.elevatedSurface
                label.textColor = .white
                label.font = MarcoTypography.cardSubtitle
            }
        }
    }
}

// MARK: - Danmaku Live Settings Sheet

private final class CinemaDanmakuSettingsSheetController: UIViewController {
    private var settings: DanmuSettings
    private let onChange: (DanmuSettings) -> Void

    private let enableSwitch = UISwitch()
    private let opacitySlider = UISlider()
    private let fontSlider = UISlider()
    private let areaSlider = UISlider()
    private let speedSlider = UISlider()
    private let scrollSwitch = UISwitch()
    private let topSwitch = UISwitch()
    private let bottomSwitch = UISwitch()

    private let opacityValueLabel = UILabel()
    private let fontValueLabel = UILabel()
    private let areaValueLabel = UILabel()
    private let speedValueLabel = UILabel()

    init(settings: DanmuSettings, onChange: @escaping (DanmuSettings) -> Void) {
        self.settings = settings
        self.onChange = onChange
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = .dark
        view.backgroundColor = MarcoColors.canvasBackground
        title = "弹幕显示设置"
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "完成", style: .done, target: self, action: #selector(handleClose))

        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)

        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 14
        scroll.addSubview(stack)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
            stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -18),
        ])

        enableSwitch.isOn = settings.enabled
        enableSwitch.addTarget(self, action: #selector(handleAnyChange), for: .valueChanged)
        stack.addArrangedSubview(makeSwitchRow(title: "开启弹幕叠加", toggle: enableSwitch))

        opacitySlider.minimumValue = 0.2
        opacitySlider.maximumValue = 1.0
        opacitySlider.value = Float(settings.opacity)
        opacitySlider.addTarget(self, action: #selector(handleAnyChange), for: .valueChanged)
        stack.addArrangedSubview(makeSliderRow(title: "不透明度", slider: opacitySlider, valueLabel: opacityValueLabel))

        fontSlider.minimumValue = 14
        fontSlider.maximumValue = 30
        fontSlider.value = Float(settings.fontSize)
        fontSlider.addTarget(self, action: #selector(handleAnyChange), for: .valueChanged)
        stack.addArrangedSubview(makeSliderRow(title: "字体大小", slider: fontSlider, valueLabel: fontValueLabel))

        areaSlider.minimumValue = 0.25
        areaSlider.maximumValue = 1.0
        areaSlider.value = Float(settings.displayArea)
        areaSlider.addTarget(self, action: #selector(handleAnyChange), for: .valueChanged)
        stack.addArrangedSubview(makeSliderRow(title: "显示区域", slider: areaSlider, valueLabel: areaValueLabel))

        speedSlider.minimumValue = 0.75
        speedSlider.maximumValue = 1.5
        speedSlider.value = Float(settings.speedMultiplier)
        speedSlider.addTarget(self, action: #selector(handleAnyChange), for: .valueChanged)
        stack.addArrangedSubview(makeSliderRow(title: "弹幕流速", slider: speedSlider, valueLabel: speedValueLabel))

        scrollSwitch.isOn = settings.showScroll
        scrollSwitch.addTarget(self, action: #selector(handleAnyChange), for: .valueChanged)
        topSwitch.isOn = settings.showTop
        topSwitch.addTarget(self, action: #selector(handleAnyChange), for: .valueChanged)
        bottomSwitch.isOn = settings.showBottom
        bottomSwitch.addTarget(self, action: #selector(handleAnyChange), for: .valueChanged)

        stack.addArrangedSubview(makeSwitchRow(title: "滚动弹幕", toggle: scrollSwitch))
        stack.addArrangedSubview(makeSwitchRow(title: "顶部固定弹幕", toggle: topSwitch))
        stack.addArrangedSubview(makeSwitchRow(title: "底部固定弹幕", toggle: bottomSwitch))

        refreshLabels()
    }

    private func makeSwitchRow(title: String, toggle: UISwitch) -> UIView {
        let label = UILabel()
        label.text = title
        label.font = MarcoTypography.body
        label.textColor = .white
        let row = UIStackView(arrangedSubviews: [label, toggle])
        row.axis = .horizontal
        row.alignment = .center
        return row
    }

    private func makeSliderRow(title: String, slider: UISlider, valueLabel: UILabel) -> UIView {
        let titleLbl = UILabel()
        titleLbl.text = title
        titleLbl.font = MarcoTypography.cardTitle
        titleLbl.textColor = .white

        valueLabel.font = MarcoTypography.monospacedDigits(size: 13, weight: .semibold)
        valueLabel.textColor = UIColor.white.withAlphaComponent(0.75)

        let header = UIStackView(arrangedSubviews: [titleLbl, valueLabel])
        header.axis = .horizontal

        let container = UIStackView(arrangedSubviews: [header, slider])
        container.axis = .vertical
        container.spacing = 4
        return container
    }

    private func refreshLabels() {
        opacityValueLabel.text = "\(Int((opacitySlider.value * 100).rounded()))%"
        fontValueLabel.text = "\(Int(fontSlider.value.rounded())) pt"
        areaValueLabel.text = "\(Int((areaSlider.value * 100).rounded()))%"
        speedValueLabel.text = String(format: "%.2fx", speedSlider.value)
    }

    @objc private func handleAnyChange() {
        refreshLabels()
        settings.enabled = enableSwitch.isOn
        settings.opacity = Double(opacitySlider.value)
        settings.fontSize = Double(fontSlider.value.rounded())
        settings.displayArea = Double(areaSlider.value)
        settings.speedMultiplier = Double(speedSlider.value)
        settings.showScroll = scrollSwitch.isOn
        settings.showTop = topSwitch.isOn
        settings.showBottom = bottomSwitch.isOn
        onChange(settings)
    }

    @objc private func handleClose() {
        dismiss(animated: true)
    }
}

// MARK: - DLNA / UPnP Cast Sheet (SSDP LAN Discovery + AVTransport Control)

private final class CinemaDlnaCastSheetController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private let castService: CastService
    private let mediaURL: URL?
    private let mediaTitle: String

    private var discoveredDevices: [CastDevice] = []
    private var activeDevice: CastDevice?
    private var scanTask: Task<Void, Never>?

    private let statusLabel = UILabel()
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let remoteControlsStack = UIStackView()

    init(castService: CastService, mediaURL: URL?, mediaTitle: String) {
        self.castService = castService
        self.mediaURL = mediaURL
        self.mediaTitle = mediaTitle
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        scanTask?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = .dark
        view.backgroundColor = MarcoColors.canvasBackground
        title = "DLNA / 电视投屏"

        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .refresh,
            target: self,
            action: #selector(handleRescan)
        )
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "完成",
            style: .done,
            target: self,
            action: #selector(handleDismiss)
        )

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = MarcoTypography.cardSubtitle
        statusLabel.textColor = UIColor.white.withAlphaComponent(0.72)
        statusLabel.textAlignment = .center
        statusLabel.text = "正在扫描局域网 DLNA 投屏设备..."

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.backgroundColor = .clear
        tableView.dataSource = self
        tableView.delegate = self

        remoteControlsStack.translatesAutoresizingMaskIntoConstraints = false
        remoteControlsStack.axis = .horizontal
        remoteControlsStack.spacing = 12
        remoteControlsStack.distribution = .fillEqually
        remoteControlsStack.isHidden = true

        let playBtn = MarcoSecondaryGlassButton(title: "播放", symbolName: "play.fill", tone: .onDarkBackdrop)
        playBtn.addTarget(self, action: #selector(handleRemotePlay), for: .touchUpInside)
        let pauseBtn = MarcoSecondaryGlassButton(title: "暂停", symbolName: "pause.fill", tone: .onDarkBackdrop)
        pauseBtn.addTarget(self, action: #selector(handleRemotePause), for: .touchUpInside)
        let stopBtn = MarcoSecondaryGlassButton(title: "停止", symbolName: "stop.fill", tone: .onDarkBackdrop)
        stopBtn.addTarget(self, action: #selector(handleRemoteStop), for: .touchUpInside)
        remoteControlsStack.addArrangedSubview(playBtn)
        remoteControlsStack.addArrangedSubview(pauseBtn)
        remoteControlsStack.addArrangedSubview(stopBtn)

        view.addSubview(statusLabel)
        view.addSubview(tableView)
        view.addSubview(remoteControlsStack)

        NSLayoutConstraint.activate([
            statusLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            tableView.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 8),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: remoteControlsStack.topAnchor, constant: -12),

            remoteControlsStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            remoteControlsStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            remoteControlsStack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
            remoteControlsStack.heightAnchor.constraint(equalToConstant: 46),
        ])

        startSsdpDiscovery()
    }

    @objc private func handleRescan() {
        startSsdpDiscovery()
    }

    @objc private func handleDismiss() {
        dismiss(animated: true)
    }

    private func startSsdpDiscovery() {
        scanTask?.cancel()
        statusLabel.text = "正在扫描局域网 DLNA 设备（AirPlay 可点击顶栏投屏图标）..."
        scanTask = Task { [weak self] in
            guard let self = self else { return }
            let locations = await Self.discoverSsdpLocations(timeoutSec: 2.2)
            var found: [CastDevice] = []
            var seenIds = Set<String>()
            for loc in locations {
                if Task.isCancelled { return }
                if let dev = try? await self.castService.fetchDeviceDescription(from: loc),
                   seenIds.insert(dev.id).inserted
                {
                    found.append(dev)
                }
            }
            await MainActor.run {
                self.discoveredDevices = found
                self.tableView.reloadData()
                self.statusLabel.text = found.isEmpty
                    ? "未发现局域网 DLNA 设备，请确认手机与电视处于同一 Wi-Fi"
                    : "发现 \(found.count) 台可投屏设备，点击即可推送播放"
            }
        }
    }

    private static func discoverSsdpLocations(timeoutSec: TimeInterval) async -> [URL] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let fd = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
                guard fd >= 0 else {
                    continuation.resume(returning: [])
                    return
                }
                defer { Darwin.close(fd) }

                var tv = timeval(tv_sec: 0, tv_usec: 350_000)
                setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                var ttl: UInt8 = 2
                setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size))

                var dest = sockaddr_in()
                dest.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                dest.sin_family = sa_family_t(AF_INET)
                dest.sin_port = CastService.ssdpPort.bigEndian
                inet_pton(AF_INET, CastService.ssdpAddress, &dest.sin_addr)

                let packet = CastService.buildSsdpSearchPacket()
                packet.withUnsafeBytes { rawBuf in
                    guard let base = rawBuf.baseAddress else { return }
                    withUnsafePointer(to: &dest) { ptr in
                        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                            _ = sendto(fd, base, packet.count, 0, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                }

                var urls: [URL] = []
                var seen = Set<String>()
                var buffer = [UInt8](repeating: 0, count: 4096)
                let deadline = Date().addingTimeInterval(timeoutSec)
                while Date() < deadline {
                    let received = recv(fd, &buffer, buffer.count, 0)
                    if received <= 0 {
                        continue
                    }
                    let text = String(decoding: buffer.prefix(received), as: UTF8.self)
                    if let url = CastService.parseSsdpLocation(from: text),
                       seen.insert(url.absoluteString).inserted
                    {
                        urls.append(url)
                    }
                }
                continuation.resume(returning: urls)
            }
        }
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        discoveredDevices.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "dlnaCell")
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: "dlnaCell")
        let dev = discoveredDevices[indexPath.row]
        cell.textLabel?.text = dev.name
        cell.detailTextLabel?.text = dev.host
        cell.accessoryType = (activeDevice?.id == dev.id) ? .checkmark : .disclosureIndicator
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let device = discoveredDevices[indexPath.row]
        guard let url = mediaURL else {
            statusLabel.text = "当前暂无可投屏的视频流地址"
            return
        }
        statusLabel.text = "正在投屏至 \(device.name)..."
        Task { [weak self] in
            guard let self = self else { return }
            do {
                try await self.castService.castMedia(to: device, mediaUrl: url, title: self.mediaTitle)
                await MainActor.run {
                    self.activeDevice = device
                    self.remoteControlsStack.isHidden = false
                    self.statusLabel.text = "正在投屏至 \(device.name)"
                    self.tableView.reloadData()
                }
            } catch {
                await MainActor.run {
                    self.statusLabel.text = "投屏失败：\(error.localizedDescription)"
                }
            }
        }
    }

    @objc private func handleRemotePlay() {
        guard let dev = activeDevice else { return }
        Task { try? await castService.play(on: dev) }
    }

    @objc private func handleRemotePause() {
        guard let dev = activeDevice else { return }
        Task { try? await castService.pause(on: dev) }
    }

    @objc private func handleRemoteStop() {
        guard let dev = activeDevice else { return }
        Task {
            try? await castService.stop(on: dev)
            await MainActor.run {
                self.activeDevice = nil
                self.remoteControlsStack.isHidden = true
                self.statusLabel.text = "已停止投屏"
                self.tableView.reloadData()
            }
        }
    }
}
