// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
// Marco Movie iOS — 120Hz ProMotion Core Animation Danmaku Renderer
// Uses CADisplayLink (CAFrameRateRange 60–120Hz on iOS 15+) driving a recycled CATextLayer pool
// with multi-lane collision avoidance and zero Auto Layout churn.

import Foundation
import MarcoIOSCore
import QuartzCore
import UIKit

// MARK: - Weak CADisplayLink Proxy (Zero Retain Cycle)

private final class DanmakuDisplayLinkProxy: NSObject {
    weak var target: DanmakuMetalLayerView?

    init(target: DanmakuMetalLayerView) {
        self.target = target
    }

    @objc func handleDisplayLinkTick(_ link: CADisplayLink) {
        target?.stepFrame(link)
    }
}

// MARK: - 120Hz Hardware-Accelerated Danmaku Overlay View

/// Hardware-composited danmaku layer view driven at up to 120Hz by `CADisplayLink`.
/// Recycles `CATextLayer` nodes directly on the layer tree so scrolling bullet comments remain
/// razor-sharp and stutter-free across iPhone ProMotion displays and iPad Split View.
public final class DanmakuMetalLayerView: UIView {
    private struct ActiveDanmakuNode {
        let layer: CATextLayer
        let mode: DanmuMode
        let laneIndex: Int
        let width: CGFloat
        let height: CGFloat
        var x: CGFloat
        let y: CGFloat
        let velocityPxPerSec: CGFloat
        var remainingPinnedSec: CFTimeInterval
    }

    private static let maxPoolSize = 96
    private static let maxSimultaneousActive = 90
    private static let horizontalLaneGap: CGFloat = 28.0
    private static let topSafeInset: CGFloat = 10.0
    private static let bottomSafeInset: CGFloat = 64.0

    public private(set) var settings: DanmuSettings = DanmuSettings()
    public var isDanmakuEnabled: Bool = true {
        didSet {
            guard oldValue != isDanmakuEnabled else { return }
            isHidden = !isDanmakuEnabled
            if !isDanmakuEnabled {
                recycleAllActiveNodes()
            }
            updateDisplayLinkActivity()
        }
    }

    private var comments: [DanmuComment] = []
    private var nextCommentIndex: Int = 0
    private var loadedTimeOffsetMs: Int = 0
    private var blockFilter = DanmuBlockFilter(rules: [])

    private var activeNodes: [ActiveDanmakuNode] = []
    private var recycledLayers: [CATextLayer] = []

    private var displayLink: CADisplayLink?
    private var lastFrameTimestamp: CFTimeInterval = 0

    private var isExternallyPaused: Bool = false
    private var isAppBackgrounded: Bool = false
    private var isPlaybackPlaying: Bool = false
    private var playbackAnchorMs: Int64 = 0
    private var playbackAnchorHostTime: CFTimeInterval = 0
    private var lastSubmittedPlaybackMs: Int64 = -1

    private var lifecycleObservers: [NSObjectProtocol] = []

    // MARK: - Init & Lifecycle

    public override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        invalidateDisplayLink()
        for token in lifecycleObservers {
            NotificationCenter.default.removeObserver(token)
        }
        lifecycleObservers.removeAll()
    }

    private func commonInit() {
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
        clipsToBounds = true
        layer.allowsGroupOpacity = false

        let center = NotificationCenter.default
        lifecycleObservers.append(
            center.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.isAppBackgrounded = true
                self?.updateDisplayLinkActivity()
            }
        )
        lifecycleObservers.append(
            center.addObserver(
                forName: UIApplication.willEnterForegroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.isAppBackgrounded = false
                self?.lastFrameTimestamp = 0
                self?.updateDisplayLinkActivity()
            }
        )
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        let scale = window?.screen.scale ?? UIScreen.main.scale
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for node in activeNodes {
            node.layer.contentsScale = scale
        }
        for pooled in recycledLayers {
            pooled.contentsScale = scale
        }
        CATransaction.commit()
        updateDisplayLinkActivity()
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        realignPinnedNodesAfterBoundsChange()
    }

    // MARK: - Public API

    /// Replaces the loaded danmaku track with `comments` (auto-sorted by timestamp and filtered).
    public func load(comments newComments: [DanmuComment]) {
        recycleAllActiveNodes()
        blockFilter = DanmuBlockFilter(rules: settings.blockRules)
        loadedTimeOffsetMs = settings.timeOffsetMs
        comments = newComments
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !blockFilter.shouldBlock($0.text) }
            .sorted { $0.timeMs < $1.timeMs }
        seekCursor(toMs: currentInterpolatedTimeMs())
        updateDisplayLinkActivity()
    }

    /// Synchronizes playback clock with the active player engine; automatically detects seeks.
    public func updatePlaybackTime(ms: Int64, isPlaying: Bool) {
        let now = CACurrentMediaTime()
        let clampedMs = max(0, ms)
        let prevMs = lastSubmittedPlaybackMs

        let didJumpBackward = prevMs >= 0 && clampedMs < prevMs - 1_200
        let didJumpForward = prevMs >= 0 && clampedMs > prevMs + 2_500

        lastSubmittedPlaybackMs = clampedMs
        playbackAnchorMs = clampedMs
        playbackAnchorHostTime = now
        isPlaybackPlaying = isPlaying

        if didJumpBackward || didJumpForward {
            recycleAllActiveNodes()
            seekCursor(toMs: clampedMs)
        } else if prevMs < 0 {
            seekCursor(toMs: clampedMs)
        }

        updateDisplayLinkActivity()
    }

    public func setPaused(_ paused: Bool) {
        guard isExternallyPaused != paused else { return }
        isExternallyPaused = paused
        if !paused {
            lastFrameTimestamp = 0
            playbackAnchorHostTime = CACurrentMediaTime()
        }
        updateDisplayLinkActivity()
    }

    public func clear() {
        comments.removeAll()
        nextCommentIndex = 0
        lastSubmittedPlaybackMs = -1
        playbackAnchorMs = 0
        recycleAllActiveNodes()
        updateDisplayLinkActivity()
    }

    public func applySettings(_ newSettings: DanmuSettings) {
        let offsetChanged = newSettings.timeOffsetMs != settings.timeOffsetMs
        let blockRulesChanged = newSettings.blockRules != settings.blockRules
        settings = newSettings
        blockFilter = DanmuBlockFilter(rules: newSettings.blockRules)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let alpha = Float(newSettings.opacity)
        for node in activeNodes {
            node.layer.opacity = alpha
            switch node.mode {
            case .scroll:
                node.layer.isHidden = !newSettings.showScroll
            case .top:
                node.layer.isHidden = !newSettings.showTop
            case .bottom:
                node.layer.isHidden = !newSettings.showBottom
            }
        }
        CATransaction.commit()

        if blockRulesChanged && !comments.isEmpty {
            comments = comments.filter { !blockFilter.shouldBlock($0.text) }
            seekCursor(toMs: currentInterpolatedTimeMs())
        } else if offsetChanged {
            seekCursor(toMs: currentInterpolatedTimeMs())
        }
        updateDisplayLinkActivity()
    }

    /// Injects an immediate on-screen comment (useful for user-sent or demo preview danmaku).
    public func sendLocalPreviewDanmaku(
        _ text: String,
        colorRgb: UInt32 = 0xFFFFFF,
        mode: DanmuMode = .scroll
    ) {
        guard isDanmakuEnabled, bounds.width > 40, bounds.height > 40 else { return }
        let comment = DanmuComment(
            id: "local_\(UUID().uuidString)",
            timeMs: Int(currentInterpolatedTimeMs()),
            mode: mode,
            colorRgb: colorRgb,
            text: text
        )
        spawnCommentIfPossible(comment, allowOverflowFallback: true)
        updateDisplayLinkActivity()
    }

    // MARK: - DisplayLink Management

    private func ensureDisplayLink() {
        guard displayLink == nil else { return }
        let proxy = DanmakuDisplayLinkProxy(target: self)
        let link = CADisplayLink(target: proxy, selector: #selector(DanmakuDisplayLinkProxy.handleDisplayLinkTick(_:)))
        if #available(iOS 15.0, *) {
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        } else {
            link.preferredFramesPerSecond = 60
        }
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func invalidateDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
        lastFrameTimestamp = 0
    }

    private func updateDisplayLinkActivity() {
        let shouldRun = isDanmakuEnabled
            && !isExternallyPaused
            && !isAppBackgrounded
            && window != nil
            && (isPlaybackPlaying || !activeNodes.isEmpty)

        if shouldRun {
            ensureDisplayLink()
            if displayLink?.isPaused == true {
                lastFrameTimestamp = 0
                displayLink?.isPaused = false
            }
        } else {
            displayLink?.isPaused = true
            lastFrameTimestamp = 0
        }
    }

    // MARK: - Frame Stepping (120Hz)

    fileprivate func stepFrame(_ link: CADisplayLink) {
        let now = link.timestamp
        let dt: CFTimeInterval
        if lastFrameTimestamp <= 0 {
            dt = 1.0 / 60.0
        } else {
            dt = min(max(now - lastFrameTimestamp, 0.001), 0.05)
        }
        lastFrameTimestamp = now

        guard isDanmakuEnabled && !isExternallyPaused && !isAppBackgrounded else {
            updateDisplayLinkActivity()
            return
        }

        let viewWidth = bounds.width
        guard viewWidth > 40 && bounds.height > 40 else { return }

        // 1. Emit due comments up to current interpolated playback timestamp.
        if isPlaybackPlaying && !comments.isEmpty {
            let currentMs = currentInterpolatedTimeMs()
            let offsetDeltaMs = Int64(settings.timeOffsetMs - loadedTimeOffsetMs)
            var emittedThisFrame = 0
            while nextCommentIndex < comments.count && emittedThisFrame < 6 {
                let candidate = comments[nextCommentIndex]
                let fireTimeMs = Int64(candidate.timeMs) + offsetDeltaMs
                if fireTimeMs > currentMs {
                    break
                }
                nextCommentIndex += 1
                // Skip stale comments older than 1.2s behind the playhead.
                if currentMs - fireTimeMs <= 1_200 {
                    spawnCommentIfPossible(candidate, allowOverflowFallback: false)
                    emittedThisFrame += 1
                }
            }
        }

        // 2. Advance active CATextLayer positions with zero implicit animations.
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        var writeIdx = 0
        for readIdx in 0..<activeNodes.count {
            var node = activeNodes[readIdx]
            var alive = true

            switch node.mode {
            case .scroll:
                node.x -= node.velocityPxPerSec * CGFloat(dt)
                if node.x + node.width < -16.0 {
                    alive = false
                } else {
                    node.layer.frame = CGRect(
                        x: node.x,
                        y: node.y,
                        width: node.width,
                        height: node.height
                    )
                }

            case .top, .bottom:
                node.remainingPinnedSec -= dt
                if node.remainingPinnedSec <= 0 {
                    alive = false
                } else {
                    let centeredX = floor((viewWidth - node.width) * 0.5)
                    node.x = centeredX
                    node.layer.frame = CGRect(
                        x: centeredX,
                        y: node.y,
                        width: node.width,
                        height: node.height
                    )
                }
            }

            if alive {
                activeNodes[writeIdx] = node
                writeIdx += 1
            } else {
                recycleLayer(node.layer)
            }
        }
        if writeIdx < activeNodes.count {
            activeNodes.removeSubrange(writeIdx..<activeNodes.count)
        }

        CATransaction.commit()

        if !isPlaybackPlaying && activeNodes.isEmpty {
            updateDisplayLinkActivity()
        }
    }

    // MARK: - Spawning & Multi-Lane Collision Avoidance

    private func spawnCommentIfPossible(_ comment: DanmuComment, allowOverflowFallback: Bool) {
        guard activeNodes.count < Self.maxSimultaneousActive else { return }
        switch comment.mode {
        case .scroll where !settings.showScroll: return
        case .top where !settings.showTop: return
        case .bottom where !settings.showBottom: return
        default: break
        }

        let fontSize = CGFloat(settings.fontSize)
        let attributed = makeAttributedText(for: comment, fontSize: fontSize)
        let measured = attributed.boundingRect(
            with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: fontSize * 1.6),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
        let itemWidth = ceil(measured.width) + 12.0
        let itemHeight = ceil(max(measured.height, fontSize * 1.32)) + 4.0
        let laneHeight = ceil(fontSize * 1.42) + 6.0

        let usableHeight = max(laneHeight, bounds.height * CGFloat(settings.displayArea) - Self.topSafeInset)
        let maxLanes = min(settings.maxRows, max(1, Int(floor(usableHeight / laneHeight))))
        let viewWidth = bounds.width

        switch comment.mode {
        case .scroll:
            let baseDuration = max(4.2, min(11.0, (7.6 / max(0.5, settings.speedMultiplier))))
            // Longer comments travel slightly faster so screen crossing time feels uniform.
            let velocity = (viewWidth + itemWidth) / CGFloat(baseDuration)
            guard let lane = allocateScrollLane(
                maxLanes: maxLanes,
                incomingWidth: itemWidth,
                incomingVelocity: velocity,
                viewWidth: viewWidth,
                allowOverflowFallback: allowOverflowFallback
            ) else {
                return
            }
            let y = Self.topSafeInset + CGFloat(lane) * laneHeight
            let textLayer = dequeueLayer()
            configure(layer: textLayer, attributedString: attributed, alignment: .left)

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            textLayer.frame = CGRect(x: viewWidth + 8.0, y: y, width: itemWidth, height: itemHeight)
            CATransaction.commit()

            activeNodes.append(
                ActiveDanmakuNode(
                    layer: textLayer,
                    mode: .scroll,
                    laneIndex: lane,
                    width: itemWidth,
                    height: itemHeight,
                    x: viewWidth + 8.0,
                    y: y,
                    velocityPxPerSec: velocity,
                    remainingPinnedSec: 0
                )
            )

        case .top:
            let pinnedLanes = max(1, min(maxLanes, 5))
            guard let lane = allocatePinnedLane(mode: .top, maxLanes: pinnedLanes) else { return }
            let y = Self.topSafeInset + CGFloat(lane) * laneHeight
            let x = floor((viewWidth - itemWidth) * 0.5)
            let holdSec = min(5.5, max(2.6, 4.0 / max(0.5, settings.speedMultiplier)))

            let textLayer = dequeueLayer()
            configure(layer: textLayer, attributedString: attributed, alignment: .center)

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            textLayer.frame = CGRect(x: x, y: y, width: itemWidth, height: itemHeight)
            CATransaction.commit()

            activeNodes.append(
                ActiveDanmakuNode(
                    layer: textLayer,
                    mode: .top,
                    laneIndex: lane,
                    width: itemWidth,
                    height: itemHeight,
                    x: x,
                    y: y,
                    velocityPxPerSec: 0,
                    remainingPinnedSec: holdSec
                )
            )

        case .bottom:
            let bottomMaxLanes = max(1, min(settings.maxRows, 4))
            guard let lane = allocatePinnedLane(mode: .bottom, maxLanes: bottomMaxLanes) else { return }
            let y = max(
                Self.topSafeInset,
                bounds.height - Self.bottomSafeInset - CGFloat(lane + 1) * laneHeight
            )
            let x = floor((viewWidth - itemWidth) * 0.5)
            let holdSec = min(5.5, max(2.6, 4.0 / max(0.5, settings.speedMultiplier)))

            let textLayer = dequeueLayer()
            configure(layer: textLayer, attributedString: attributed, alignment: .center)

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            textLayer.frame = CGRect(x: x, y: y, width: itemWidth, height: itemHeight)
            CATransaction.commit()

            activeNodes.append(
                ActiveDanmakuNode(
                    layer: textLayer,
                    mode: .bottom,
                    laneIndex: lane,
                    width: itemWidth,
                    height: itemHeight,
                    x: x,
                    y: y,
                    velocityPxPerSec: 0,
                    remainingPinnedSec: holdSec
                )
            )
        }
    }

    private func allocateScrollLane(
        maxLanes: Int,
        incomingWidth: CGFloat,
        incomingVelocity: CGFloat,
        viewWidth: CGFloat,
        allowOverflowFallback: Bool
    ) -> Int? {
        for lane in 0..<maxLanes {
            // Find the rightmost active scrolling node currently occupying `lane`.
            var rightmost: ActiveDanmakuNode?
            for node in activeNodes where node.mode == .scroll && node.laneIndex == lane {
                if let existing = rightmost {
                    if (node.x + node.width) > (existing.x + existing.width) {
                        rightmost = node
                    }
                } else {
                    rightmost = node
                }
            }
            guard let prev = rightmost else {
                return lane
            }
            let prevTailX = prev.x + prev.width
            // Condition 1: previous comment's tail must already have entered screen with margin.
            guard prevTailX <= viewWidth - Self.horizontalLaneGap else {
                continue
            }
            // Condition 2: if incoming is faster than previous, ensure no catch-up before exit.
            if incomingVelocity > prev.velocityPxPerSec {
                let prevRemainingExitSec = max(0, prevTailX) / max(1.0, prev.velocityPxPerSec)
                let catchupDistance = viewWidth - prevTailX - Self.horizontalLaneGap
                let catchupTime = catchupDistance / (incomingVelocity - prev.velocityPxPerSec)
                if catchupTime < prevRemainingExitSec {
                    continue
                }
            }
            return lane
        }
        return allowOverflowFallback ? Int.random(in: 0..<max(1, maxLanes)) : nil
    }

    private func allocatePinnedLane(mode: DanmuMode, maxLanes: Int) -> Int? {
        var occupied = Set<Int>()
        for node in activeNodes where node.mode == mode {
            occupied.insert(node.laneIndex)
        }
        for lane in 0..<maxLanes where !occupied.contains(lane) {
            return lane
        }
        return nil
    }

    // MARK: - Layer Pool & Styling

    private func dequeueLayer() -> CATextLayer {
        if let reused = recycledLayers.popLast() {
            reused.isHidden = false
            return reused
        }
        let textLayer = CATextLayer()
        textLayer.contentsScale = window?.screen.scale ?? UIScreen.main.scale
        textLayer.isWrapped = false
        textLayer.truncationMode = .none
        textLayer.shadowColor = UIColor.black.cgColor
        textLayer.shadowOpacity = 0.85
        textLayer.shadowRadius = 1.6
        textLayer.shadowOffset = CGSize(width: 0, height: 1.0)
        layer.addSublayer(textLayer)
        return textLayer
    }

    private func configure(
        layer textLayer: CATextLayer,
        attributedString: NSAttributedString,
        alignment: CATextLayerAlignmentMode
    ) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        textLayer.string = attributedString
        textLayer.alignmentMode = alignment
        textLayer.opacity = Float(settings.opacity)
        textLayer.contentsScale = window?.screen.scale ?? UIScreen.main.scale
        textLayer.isHidden = false
        CATransaction.commit()
    }

    private func recycleLayer(_ textLayer: CATextLayer) {
        textLayer.isHidden = true
        textLayer.string = nil
        if recycledLayers.count < Self.maxPoolSize {
            recycledLayers.append(textLayer)
        } else {
            textLayer.removeFromSuperlayer()
        }
    }

    private func recycleAllActiveNodes() {
        guard !activeNodes.isEmpty else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for node in activeNodes {
            recycleLayer(node.layer)
        }
        activeNodes.removeAll(keepingCapacity: true)
        CATransaction.commit()
    }

    private func realignPinnedNodesAfterBoundsChange() {
        guard !activeNodes.isEmpty, bounds.width > 40 else { return }
        let viewWidth = bounds.width
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for idx in 0..<activeNodes.count {
            if activeNodes[idx].mode == .top || activeNodes[idx].mode == .bottom {
                let centeredX = floor((viewWidth - activeNodes[idx].width) * 0.5)
                activeNodes[idx].x = centeredX
                activeNodes[idx].layer.frame = CGRect(
                    x: centeredX,
                    y: activeNodes[idx].y,
                    width: activeNodes[idx].width,
                    height: activeNodes[idx].height
                )
            }
        }
        CATransaction.commit()
    }

    private func makeAttributedText(for comment: DanmuComment, fontSize: CGFloat) -> NSAttributedString {
        let r = CGFloat((comment.colorRgb >> 16) & 0xFF) / 255.0
        let g = CGFloat((comment.colorRgb >> 8) & 0xFF) / 255.0
        let b = CGFloat(comment.colorRgb & 0xFF) / 255.0
        let fgColor = UIColor(red: r, green: g, blue: b, alpha: 1.0)
        let font = UIFont.systemFont(ofSize: fontSize, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: fgColor,
            .strokeColor: UIColor.black.withAlphaComponent(0.76),
            .strokeWidth: -2.6,
        ]
        return NSAttributedString(string: comment.text, attributes: attrs)
    }

    // MARK: - Clock & Binary Search Cursor

    private func currentInterpolatedTimeMs() -> Int64 {
        guard isPlaybackPlaying && !isExternallyPaused else {
            return playbackAnchorMs
        }
        let elapsedSec = max(0, CACurrentMediaTime() - playbackAnchorHostTime)
        // Clamp extrapolation so a stalled engine doesn't run danmaku ahead indefinitely.
        let clampedElapsedMs = Int64((min(elapsedSec, 1.5) * 1000.0).rounded())
        return playbackAnchorMs + clampedElapsedMs
    }

    private func seekCursor(toMs targetMs: Int64) {
        let offsetDeltaMs = Int64(settings.timeOffsetMs - loadedTimeOffsetMs)
        var low = 0
        var high = comments.count
        while low < high {
            let mid = (low + high) >> 1
            let fireMs = Int64(comments[mid].timeMs) + offsetDeltaMs
            if fireMs < targetMs {
                low = mid + 1
            } else {
                high = mid
            }
        }
        nextCommentIndex = low
    }
}
