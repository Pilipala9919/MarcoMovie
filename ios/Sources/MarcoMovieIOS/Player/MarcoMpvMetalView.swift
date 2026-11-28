// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
// Marco Movie iOS — Zero-Copy Metal + libmpv Hardware-Accelerated Rendering View
// Renders CVPixelBuffer IOSurface frames from MMMpvNativeBridge onto CAMetalLayer via
// CVMetalTextureCache and inline-compiled MSL shaders with strict background GPU protection.

import AVFoundation
import CoreVideo
import Foundation
import MarcoIOSCore
import Metal
import QuartzCore
import UIKit

#if canImport(MarcoNativeBridges)
import MarcoNativeBridges
#endif

// MARK: - Tracks Snapshot & Delegate

public struct MarcoMpvTracksSnapshot: Equatable, Sendable {
    public let audioTracks: [MarcoMediaTrack]
    public let subtitleTracks: [MarcoMediaTrack]

    public init(audioTracks: [MarcoMediaTrack] = [], subtitleTracks: [MarcoMediaTrack] = []) {
        self.audioTracks = audioTracks
        self.subtitleTracks = subtitleTracks
    }
}

public protocol MarcoMpvMetalViewDelegate: AnyObject {
    func mpvMetalView(
        _ view: MarcoMpvMetalView,
        onPositionUpdate positionMs: Int64,
        durationMs: Int64,
        bufferedMs: Int64
    )
    func mpvMetalView(_ view: MarcoMpvMetalView, onBufferingChanged isBuffering: Bool)
    func mpvMetalView(_ view: MarcoMpvMetalView, onPlaybackStateChanged isPlaying: Bool, isBuffering: Bool, rate: Float)
    func mpvMetalView(_ view: MarcoMpvMetalView, onTracksUpdated snapshot: MarcoMpvTracksSnapshot)
    func mpvMetalView(_ view: MarcoMpvMetalView, onVideoSizeChanged size: CGSize)
    func mpvMetalViewDidComplete(_ view: MarcoMpvMetalView)
    func mpvMetalView(_ view: MarcoMpvMetalView, onError message: String)
    func mpvMetalView(_ view: MarcoMpvMetalView, onUnavailable reason: String)
}

public extension MarcoMpvMetalViewDelegate {
    func mpvMetalView(_ view: MarcoMpvMetalView, onVideoSizeChanged size: CGSize) {}
}

// MARK: - Inline Metal Viewport Uniform

private struct MarcoMetalViewportScale {
    var scaleX: Float
    var scaleY: Float
}

// MARK: - Zero-Copy Metal + libmpv View

/// Pure UIKit view backed directly by `CAMetalLayer` that blits IOSurface-backed `CVPixelBuffer`
/// frames from `MMMpvNativeBridge` with zero CPU copies, Anime4K GLSL shader support, ASS styled
/// subtitles, multi-track switching, HDR tone mapping, and FFmpeg `lavfi` vocal loudness filters.
public final class MarcoMpvMetalView: UIView {
    public override class var layerClass: AnyClass {
        CAMetalLayer.self
    }

    public var metalLayer: CAMetalLayer {
        layer as! CAMetalLayer
    }

    public static var isRuntimeAvailable: Bool {
        #if canImport(MarcoNativeBridges)
        return MMMpvNativeBridge.isRuntimeAvailable()
        #else
        return false
        #endif
    }

    public static let lightSimulatorFallbackMessage = "当前为轻量模拟器模式，已自动使用 AVPlayer 播放"

    public weak var delegate: MarcoMpvMetalViewDelegate?

    public private(set) var currentPositionMs: Int64 = 0
    public private(set) var currentDurationMs: Int64 = 0
    public private(set) var currentBufferedMs: Int64 = 0
    public private(set) var isPlaying: Bool = false
    public private(set) var isBuffering: Bool = false
    public private(set) var currentRate: Float = 1.0
    public private(set) var currentVolume: Float = 1.0
    public private(set) var videoSize: CGSize = .zero
    public private(set) var aspectMode: MarcoVideoAspectMode = .fit
    public private(set) var anime4kEnabled: Bool = false
    public private(set) var vocalLoudness: VocalLoudnessPreset = .off
    public private(set) var hdrToneMapping: IosHdrToneMappingMode = .auto

    // Metal pipeline state (zero external .metallib required).
    private let metalRenderQueue = DispatchQueue(
        label: "com.pilipala.marcomovie.ios.mpv.metal.render",
        qos: .userInteractive
    )
    private let stateLock = NSLock()
    private var mtlDevice: MTLDevice?
    private var commandQueue: MTLCommandQueue?
    private var pipelineState: MTLRenderPipelineState?
    private var textureCache: CVMetalTextureCache?

    private var isMetalPaused = false
    private var isDestroyed = false
    private var isLiveStream = false
    private var lastDrawableSize: CGSize = .zero
    private var latestPixelBuffer: CVPixelBuffer?
    private var cachedTracksSnapshot = MarcoMpvTracksSnapshot()
    private var lastVideoWidth: Int64 = 0
    private var lastVideoHeight: Int64 = 0
    private var lastDemuxerCacheDurationSec: Double = 0
    private var lastPositionDispatchTime: CFTimeInterval = 0
    private var lifecycleObservers: [NSObjectProtocol] = []

    #if canImport(MarcoNativeBridges)
    private var bridge: MMMpvNativeBridge?
    #endif

    private static let inlineMetalShaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct ViewportScale {
        float scaleX;
        float scaleY;
    };

    struct VertexOut {
        float4 position [[position]];
        float2 texCoord;
    };

    vertex VertexOut marcoMpvVertex(
        uint vertexID [[vertex_id]],
        constant ViewportScale &viewport [[buffer(0)]]
    ) {
        constexpr float2 positions[4] = {
            float2(-1.0,  1.0),
            float2(-1.0, -1.0),
            float2( 1.0,  1.0),
            float2( 1.0, -1.0)
        };
        constexpr float2 texCoords[4] = {
            float2(0.0, 0.0),
            float2(0.0, 1.0),
            float2(1.0, 0.0),
            float2(1.0, 1.0)
        };
        VertexOut out;
        float2 pos = positions[vertexID];
        out.position = float4(pos.x * viewport.scaleX, pos.y * viewport.scaleY, 0.0, 1.0);
        out.texCoord = texCoords[vertexID];
        return out;
    }

    fragment float4 marcoMpvFragment(
        VertexOut in [[stage_in]],
        texture2d<float, access::sample> colorTexture [[texture(0)]]
    ) {
        constexpr sampler linearSampler(
            mag_filter::linear,
            min_filter::linear,
            address::clamp_to_edge
        );
        return colorTexture.sample(linearSampler, in.texCoord);
    }
    """

    // MARK: - Init & Teardown

    public override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        destroy()
    }

    private func commonInit() {
        backgroundColor = .black
        isOpaque = true
        contentMode = .scaleAspectFit
        setupMetalPipeline()
        installLifecycleObservers()
    }

    private func setupMetalPipeline() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            return
        }
        mtlDevice = device
        commandQueue = device.makeCommandQueue()

        let layer = metalLayer
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.isOpaque = true
        layer.backgroundColor = UIColor.black.cgColor
        layer.maximumDrawableCount = 3
        layer.allowsNextDrawableTimeout = true
        layer.contentsScale = window?.screen.scale ?? UIScreen.main.scale

        var cache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        if status == kCVReturnSuccess {
            textureCache = cache
        }

        do {
            let library = try device.makeLibrary(source: Self.inlineMetalShaderSource, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "marcoMpvVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "marcoMpvFragment")
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            pipelineState = nil
        }
    }

    private func installLifecycleObservers() {
        let center = NotificationCenter.default
        lifecycleObservers.append(
            center.addObserver(
                forName: UIApplication.willResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.setMetalRenderingPaused(true)
            }
        )
        lifecycleObservers.append(
            center.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.setMetalRenderingPaused(true)
                self?.pause()
            }
        )
        lifecycleObservers.append(
            center.addObserver(
                forName: UIApplication.willEnterForegroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.setMetalRenderingPaused(false)
            }
        )
        lifecycleObservers.append(
            center.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.setMetalRenderingPaused(false)
            }
        )
        lifecycleObservers.append(
            center.addObserver(
                forName: ProcessInfo.thermalStateDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.applyThermalScalingPolicy()
            }
        )
        lifecycleObservers.append(
            center.addObserver(
                forName: UIApplication.didReceiveMemoryWarningNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.flushTextureCache()
            }
        )
    }

    private func setMetalRenderingPaused(_ paused: Bool) {
        var cachedBuffer: CVPixelBuffer?
        stateLock.lock()
        isMetalPaused = paused
        if !paused {
            cachedBuffer = latestPixelBuffer
        }
        stateLock.unlock()

        if paused {
            flushTextureCache()
        } else {
            if let buffer = cachedBuffer {
                enqueueRender(pixelBuffer: buffer)
            }
            #if canImport(MarcoNativeBridges)
            bridge?.renderIfNeeded()
            #endif
        }
    }

    private func flushTextureCache() {
        metalRenderQueue.async { [weak self] in
            if let cache = self?.textureCache {
                CVMetalTextureCacheFlush(cache, 0)
            }
        }
    }

    // MARK: - Layout & Drawable Sizing

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        if let screen = window?.screen {
            metalLayer.contentsScale = screen.scale
        }
        updateDrawableSizeIfNeeded()
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        updateDrawableSizeIfNeeded()
    }

    private func currentPixelDrawableSize() -> CGSize {
        let scale = window?.screen.scale ?? UIScreen.main.scale
        let width = max(64.0, min(3840.0, (bounds.width * scale).rounded()))
        let height = max(64.0, min(3840.0, (bounds.height * scale).rounded()))
        return CGSize(width: width, height: height)
    }

    private func updateDrawableSizeIfNeeded() {
        guard bounds.width > 1 && bounds.height > 1 else { return }
        let pixelSize = currentPixelDrawableSize()
        guard abs(pixelSize.width - lastDrawableSize.width) >= 1.0
            || abs(pixelSize.height - lastDrawableSize.height) >= 1.0
        else {
            return
        }
        lastDrawableSize = pixelSize
        metalLayer.drawableSize = pixelSize

        #if canImport(MarcoNativeBridges)
        bridge?.resizeDrawable(pixelSize)
        #endif

        var cachedBuffer: CVPixelBuffer?
        stateLock.lock()
        cachedBuffer = latestPixelBuffer
        stateLock.unlock()
        if let buffer = cachedBuffer {
            enqueueRender(pixelBuffer: buffer)
        }
    }

    // MARK: - Zero-Copy Metal Blit Pipeline

    private func enqueueRender(pixelBuffer: CVPixelBuffer) {
        stateLock.lock()
        let paused = isMetalPaused || isDestroyed
        if !isDestroyed {
            latestPixelBuffer = pixelBuffer
        }
        stateLock.unlock()
        guard !paused else { return }

        metalRenderQueue.async { [weak self] in
            self?.renderPixelBufferOnMetalQueue(pixelBuffer)
        }
    }

    private func renderPixelBufferOnMetalQueue(_ pixelBuffer: CVPixelBuffer) {
        stateLock.lock()
        let blocked = isMetalPaused || isDestroyed
        stateLock.unlock()
        guard !blocked else { return }

        guard let commandQueue = commandQueue,
              let pipelineState = pipelineState,
              let cache = textureCache
        else {
            return
        }

        let bufWidth = CVPixelBufferGetWidth(pixelBuffer)
        let bufHeight = CVPixelBufferGetHeight(pixelBuffer)
        guard bufWidth > 0 && bufHeight > 0 else { return }

        var cvMetalTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            cache,
            pixelBuffer,
            nil,
            .bgra8Unorm,
            bufWidth,
            bufHeight,
            0,
            &cvMetalTexture
        )
        guard status == kCVReturnSuccess,
              let metalTexRef = cvMetalTexture,
              let texture = CVMetalTextureGetTexture(metalTexRef)
        else {
            return
        }

        autoreleasepool {
            guard let drawable = metalLayer.nextDrawable() else {
                return
            }

            let drawableW = max(1.0, Float(drawable.texture.width))
            let drawableH = max(1.0, Float(drawable.texture.height))
            let sourceAspect = Float(bufWidth) / Float(bufHeight)
            let targetAspect = drawableW / drawableH
            var scale = MarcoMetalViewportScale(scaleX: 1.0, scaleY: 1.0)
            if abs(sourceAspect - targetAspect) > 0.01 {
                if sourceAspect > targetAspect {
                    scale.scaleY = targetAspect / sourceAspect
                } else {
                    scale.scaleX = sourceAspect / targetAspect
                }
            }

            let passDescriptor = MTLRenderPassDescriptor()
            passDescriptor.colorAttachments[0].texture = drawable.texture
            passDescriptor.colorAttachments[0].loadAction = .clear
            passDescriptor.colorAttachments[0].storeAction = .store
            passDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

            guard let commandBuffer = commandQueue.makeCommandBuffer(),
                  let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor)
            else {
                return
            }

            encoder.setRenderPipelineState(pipelineState)
            encoder.setVertexBytes(&scale, length: MemoryLayout<MarcoMetalViewportScale>.stride, index: 0)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.endEncoding()

            // Retain CoreVideo IOSurface texture & pixel buffer until GPU finishes sampling.
            commandBuffer.addCompletedHandler { _ in
                _ = metalTexRef
                _ = pixelBuffer
            }
            commandBuffer.present(drawable)
            commandBuffer.commit()
            CVMetalTextureCacheFlush(cache, 0)
        }
    }

    // MARK: - libmpv Runtime Initialization & Tuning

    #if canImport(MarcoNativeBridges)
    @discardableResult
    private func ensureBridgeReady() -> MMMpvNativeBridge? {
        if let existing = bridge {
            return existing
        }
        guard MMMpvNativeBridge.isRuntimeAvailable() else {
            return nil
        }

        let initialSize = currentPixelDrawableSize()
        lastDrawableSize = initialSize
        metalLayer.drawableSize = initialSize

        guard let created = MMMpvNativeBridge(renderSize: initialSize) else {
            return nil
        }

        created.setOnFrameReady { [weak self] pixelBuffer in
            self?.enqueueRender(pixelBuffer: pixelBuffer)
        }
        created.setOnEvent { [weak self] eventName, payload in
            self?.handleMpvEvent(name: eventName, payload: payload)
        }

        bridge = created
        configureOptimalMpvOptions(on: created)
        return created
    }

    private func configureOptimalMpvOptions(on target: MMMpvNativeBridge) {
        // Hardware decode & zero-copy NV12 VideoToolbox pipeline.
        target.setPropertyString("hwdec", value: "videotoolbox")
        target.setPropertyString("hwdec-image-format", value: "nv12")

        // RAM-tiered demuxer cache sizing matching physical iOS device memory.
        let memGiB = Double(ProcessInfo.processInfo.physicalMemory) / (1024.0 * 1024.0 * 1024.0)
        let maxBytes: String
        let maxBackBytes: String
        if memGiB <= 3.2 {
            maxBytes = "32MiB"
            maxBackBytes = "16MiB"
        } else if memGiB <= 4.5 {
            maxBytes = "64MiB"
            maxBackBytes = "32MiB"
        } else if memGiB <= 6.5 {
            maxBytes = "96MiB"
            maxBackBytes = "48MiB"
        } else {
            maxBytes = "128MiB"
            maxBackBytes = "64MiB"
        }
        target.setPropertyString("demuxer-max-bytes", value: maxBytes)
        target.setPropertyString("demuxer-max-back-bytes", value: maxBackBytes)

        // Styled ASS / SRT subtitle defaults for Chinese + international cinema fonts.
        target.setPropertyString("sub-ass-override", value: "scale")
        target.setPropertyString("sub-auto", value: "fuzzy")
        target.setPropertyString("sub-font", value: "PingFang SC")
        target.setPropertyString("sub-font-size", value: "44")
        target.setPropertyString("sub-border-size", value: "2.2")
        target.setPropertyString("sub-shadow-offset", value: "1")

        applyThermalScalingPolicy()
        applyAspectModeToBridge(aspectMode)
        applyHdrToneMappingToBridge(hdrToneMapping)
        applyVocalLoudnessToBridge(vocalLoudness)
    }

    private func applyAspectModeToBridge(_ mode: MarcoVideoAspectMode) {
        guard let target = bridge else { return }
        switch mode {
        case .fit:
            target.setPropertyString("keepaspect", value: "yes")
            target.setPropertyString("panscan", value: "0.0")
        case .fill:
            target.setPropertyString("keepaspect", value: "yes")
            target.setPropertyString("panscan", value: "1.0")
        case .stretch:
            target.setPropertyString("keepaspect", value: "no")
            target.setPropertyString("panscan", value: "0.0")
        }
    }

    private func applyHdrToneMappingToBridge(_ mode: IosHdrToneMappingMode) {
        guard let target = bridge else { return }
        target.setPropertyString("tone-mapping", value: mode.mpvToneMapping)
        target.setPropertyString("tone-mapping-compute-peak", value: mode.computePeak)
    }

    private func applyVocalLoudnessToBridge(_ preset: VocalLoudnessPreset) {
        guard let target = bridge else { return }
        target.setPropertyString("volume-max", value: "\(preset.volumeMax)")
        target.setPropertyString("af", value: preset.audioFilter)
    }
    #endif

    private func applyThermalScalingPolicy() {
        #if canImport(MarcoNativeBridges)
        guard let target = bridge else { return }
        let info = ProcessInfo.processInfo
        let constrained = info.isLowPowerModeEnabled
            || info.thermalState == .serious
            || info.thermalState == .critical
        target.setPropertyString("scale", value: constrained ? "bilinear" : "spline36")
        target.setPropertyString("dscale", value: constrained ? "bilinear" : "mitchell")
        if constrained && anime4kEnabled {
            target.setPropertyString("glsl-shaders", value: "")
        }
        #endif
    }

    private func configureAudioSessionForMpv() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback, options: [])
        try? session.setActive(true)
    }

    // MARK: - Public Playback API

    public func open(
        url: URL,
        headers: [String: String] = [:],
        startPositionMs: Int64 = 0,
        isLive: Bool = false
    ) {
        guard Self.isRuntimeAvailable else {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.delegate?.mpvMetalView(self, onUnavailable: Self.lightSimulatorFallbackMessage)
            }
            return
        }

        #if canImport(MarcoNativeBridges)
        configureAudioSessionForMpv()
        guard let target = ensureBridgeReady() else {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.delegate?.mpvMetalView(self, onUnavailable: "libmpv 渲染引擎初始化失败，已切换至 AVPlayer")
            }
            return
        }

        isLiveStream = isLive
        currentPositionMs = max(0, startPositionMs)
        currentDurationMs = 0
        currentBufferedMs = 0
        isBuffering = true
        cachedTracksSnapshot = MarcoMpvTracksSnapshot()
        delegate?.mpvMetalView(self, onBufferingChanged: true)

        var headerPairs: [String] = []
        var customUA: String?
        var customReferer: String?
        for (rawKey, rawVal) in headers {
            let k = rawKey
                .replacingOccurrences(of: "\r", with: "")
                .replacingOccurrences(of: "\n", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let v = rawVal
                .replacingOccurrences(of: "\r", with: "")
                .replacingOccurrences(of: "\n", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !k.isEmpty, !v.isEmpty else { continue }
            let lower = k.lowercased()
            if lower == "user-agent" {
                customUA = v
            } else if lower == "referer" || lower == "referrer" {
                customReferer = v
            } else {
                headerPairs.append("\(k): \(v)")
            }
        }
        target.setPropertyString("user-agent", value: customUA ?? CmsClient.defaultSafariUserAgent)
        target.setPropertyString("referrer", value: customReferer ?? "")
        target.setPropertyString("http-header-fields", value: headerPairs.joined(separator: ","))

        target.setPropertyString("cache", value: "yes")
        target.setPropertyString("cache-secs", value: isLive ? "6" : "28")
        if startPositionMs > 0 && !isLive {
            let startSec = String(format: "%.3f", Double(startPositionMs) / 1000.0)
            target.setPropertyString("start", value: startSec)
        } else {
            target.setPropertyString("start", value: "none")
        }

        target.setPropertyString("pause", value: "no")
        target.setPropertyString("speed", value: String(format: "%.2f", isLive ? 1.0 : currentRate))
        target.command(["loadfile", url.absoluteString, "replace"])
        #endif
    }

    public func play() {
        #if canImport(MarcoNativeBridges)
        configureAudioSessionForMpv()
        bridge?.setPropertyString("pause", value: "no")
        #endif
    }

    public func pause() {
        #if canImport(MarcoNativeBridges)
        bridge?.setPropertyString("pause", value: "yes")
        #endif
    }

    public func seek(toMs positionMs: Int64) {
        let clampedMs = max(0, positionMs)
        currentPositionMs = clampedMs
        #if canImport(MarcoNativeBridges)
        let sec = String(format: "%.3f", Double(clampedMs) / 1000.0)
        bridge?.command(["seek", sec, "absolute", "exact"])
        #endif
    }

    public func setRate(_ rate: Float) {
        let clamped = max(0.25, min(rate, 4.0))
        currentRate = clamped
        #if canImport(MarcoNativeBridges)
        if !isLiveStream {
            bridge?.setPropertyString("speed", value: String(format: "%.2f", clamped))
        }
        #endif
    }

    public func setVolume(_ volume: Float) {
        let maxScalar = Float(vocalLoudness.volumeMax) / 100.0
        let clamped = max(0.0, min(volume, max(1.0, maxScalar)))
        currentVolume = clamped
        #if canImport(MarcoNativeBridges)
        let mpvVol = Int((clamped * 100.0).rounded())
        bridge?.setPropertyString("volume", value: "\(mpvVol)")
        #endif
    }

    public func setAspectMode(_ mode: MarcoVideoAspectMode) {
        aspectMode = mode
        #if canImport(MarcoNativeBridges)
        applyAspectModeToBridge(mode)
        bridge?.renderIfNeeded()
        #endif
    }

    public func setAnime4kEnabled(_ enabled: Bool, shaderPath: String? = nil) {
        anime4kEnabled = enabled
        #if canImport(MarcoNativeBridges)
        guard let target = bridge else { return }
        if !enabled {
            target.setPropertyString("glsl-shaders", value: "")
            return
        }
        let resolvedChain: String
        if let explicit = shaderPath?.trimmingCharacters(in: .whitespacesAndNewlines), !explicit.isEmpty {
            resolvedChain = explicit
        } else {
            resolvedChain = Self.resolveBundledAnime4kShaderChain()
        }
        target.setPropertyString("glsl-shaders", value: resolvedChain)
        #endif
    }

    public func setVocalLoudness(_ preset: VocalLoudnessPreset) {
        vocalLoudness = preset
        #if canImport(MarcoNativeBridges)
        applyVocalLoudnessToBridge(preset)
        #endif
    }

    public func setHdrToneMapping(_ mode: IosHdrToneMappingMode) {
        hdrToneMapping = mode
        #if canImport(MarcoNativeBridges)
        applyHdrToneMappingToBridge(mode)
        #endif
    }

    public func selectAudioTrack(id: String?) {
        #if canImport(MarcoNativeBridges)
        let val = (id == nil || id == "off" || id == "no") ? "no" : id!
        bridge?.setPropertyString("aid", value: val)
        refreshTracksSnapshotFromBridge()
        #endif
    }

    public func selectSubtitleTrack(id: String?) {
        #if canImport(MarcoNativeBridges)
        let val = (id == nil || id == "off" || id == "no") ? "no" : id!
        bridge?.setPropertyString("sid", value: val)
        refreshTracksSnapshotFromBridge()
        #endif
    }

    public func tracksSnapshot() -> MarcoMpvTracksSnapshot {
        #if canImport(MarcoNativeBridges)
        if let json = bridge?.getPropertyString("track-list"), !json.isEmpty {
            cachedTracksSnapshot = Self.parseTrackListJson(json)
        }
        #endif
        return cachedTracksSnapshot
    }

    public func stop() {
        #if canImport(MarcoNativeBridges)
        bridge?.command(["stop"])
        #endif
        isPlaying = false
        isBuffering = false
        currentPositionMs = 0
        currentDurationMs = 0
        currentBufferedMs = 0
        stateLock.lock()
        latestPixelBuffer = nil
        stateLock.unlock()
    }

    public func destroy() {
        stateLock.lock()
        let already = isDestroyed
        isDestroyed = true
        isMetalPaused = true
        latestPixelBuffer = nil
        stateLock.unlock()
        guard !already else { return }

        for token in lifecycleObservers {
            NotificationCenter.default.removeObserver(token)
        }
        lifecycleObservers.removeAll()

        #if canImport(MarcoNativeBridges)
        let currentBridge = bridge
        bridge = nil
        currentBridge?.setOnFrameReady(nil)
        currentBridge?.setOnEvent(nil)
        currentBridge?.destroy()
        #endif

        if let cache = textureCache {
            CVMetalTextureCacheFlush(cache, 0)
            textureCache = nil
        }
        pipelineState = nil
        commandQueue = nil
        mtlDevice = nil
    }

    // MARK: - Bundled Anime4K Shader Chain Discovery

    public static func resolveBundledAnime4kShaderChain() -> String {
        let lightweightFiles = [
            "Anime4K_Clamp_Highlights.glsl",
            "Anime4K_Restore_CNN_S.glsl",
        ]
        var paths: [String] = []
        let fm = FileManager.default
        if let shadersRoot = Bundle.main.url(forResource: "shaders", withExtension: nil) {
            let animeDir = shadersRoot.appendingPathComponent("anime4k", isDirectory: true)
            for name in lightweightFiles {
                let candidate = animeDir.appendingPathComponent(name)
                if fm.fileExists(atPath: candidate.path) {
                    paths.append(candidate.path)
                }
            }
        }
        if paths.isEmpty {
            for name in lightweightFiles {
                let base = (name as NSString).deletingPathExtension
                if let url = Bundle.main.url(forResource: base, withExtension: "glsl", subdirectory: "shaders/anime4k")
                    ?? Bundle.main.url(forResource: base, withExtension: "glsl")
                {
                    paths.append(url.path)
                }
            }
        }
        return paths.joined(separator: ":")
    }

    // MARK: - Event Parsing

    #if canImport(MarcoNativeBridges)
    private func handleMpvEvent(name: String, payload: [String: Any]) {
        switch name {
        case "file-loaded":
            isBuffering = false
            delegate?.mpvMetalView(self, onBufferingChanged: false)
            refreshTracksSnapshotFromBridge()
            if anime4kEnabled {
                setAnime4kEnabled(true)
            }

        case "playback-restart":
            isBuffering = false
            delegate?.mpvMetalView(self, onBufferingChanged: false)
            delegate?.mpvMetalView(
                self,
                onPlaybackStateChanged: isPlaying,
                isBuffering: false,
                rate: currentRate
            )

        case "end-file":
            let reason = (payload["reason"] as? NSNumber)?.intValue ?? -1
            if reason == 0 {
                isPlaying = false
                isBuffering = false
                delegate?.mpvMetalView(
                    self,
                    onPlaybackStateChanged: false,
                    isBuffering: false,
                    rate: currentRate
                )
                delegate?.mpvMetalViewDidComplete(self)
            } else if reason == 4 {
                isPlaying = false
                isBuffering = false
                let errText = (payload["errorString"] as? String) ?? "libmpv 播放失败"
                delegate?.mpvMetalView(self, onError: errText)
            }

        case "property-change":
            guard let propName = payload["name"] as? String else { return }
            let rawValue = payload["value"]
            handlePropertyChange(name: propName, value: rawValue)

        default:
            break
        }
    }

    private func handlePropertyChange(name: String, value: Any?) {
        switch name {
        case "time-pos":
            if let sec = (value as? NSNumber)?.doubleValue, sec.isFinite && sec >= 0 {
                currentPositionMs = Int64((sec * 1000.0).rounded())
                currentBufferedMs = currentPositionMs + Int64((max(0, lastDemuxerCacheDurationSec) * 1000.0).rounded())
                let now = CACurrentMediaTime()
                if now - lastPositionDispatchTime >= 0.25 {
                    lastPositionDispatchTime = now
                    delegate?.mpvMetalView(
                        self,
                        onPositionUpdate: currentPositionMs,
                        durationMs: currentDurationMs,
                        bufferedMs: currentBufferedMs
                    )
                }
            }

        case "duration":
            if let sec = (value as? NSNumber)?.doubleValue, sec.isFinite && sec > 0 {
                currentDurationMs = Int64((sec * 1000.0).rounded())
                delegate?.mpvMetalView(
                    self,
                    onPositionUpdate: currentPositionMs,
                    durationMs: currentDurationMs,
                    bufferedMs: currentBufferedMs
                )
            }

        case "demuxer-cache-duration":
            if let sec = (value as? NSNumber)?.doubleValue, sec.isFinite && sec >= 0 {
                lastDemuxerCacheDurationSec = sec
                currentBufferedMs = currentPositionMs + Int64((sec * 1000.0).rounded())
            }

        case "pause":
            if let paused = (value as? NSNumber)?.boolValue {
                isPlaying = !paused
                delegate?.mpvMetalView(
                    self,
                    onPlaybackStateChanged: isPlaying,
                    isBuffering: isBuffering,
                    rate: currentRate
                )
            }

        case "paused-for-cache":
            if let caching = (value as? NSNumber)?.boolValue {
                isBuffering = caching
                delegate?.mpvMetalView(self, onBufferingChanged: caching)
                delegate?.mpvMetalView(
                    self,
                    onPlaybackStateChanged: isPlaying,
                    isBuffering: caching,
                    rate: currentRate
                )
            }

        case "speed":
            if let spd = (value as? NSNumber)?.floatValue, spd.isFinite && spd > 0 {
                currentRate = spd
                delegate?.mpvMetalView(
                    self,
                    onPlaybackStateChanged: isPlaying,
                    isBuffering: isBuffering,
                    rate: currentRate
                )
            }

        case "video-params/w":
            if let w = (value as? NSNumber)?.int64Value, w > 0 {
                lastVideoWidth = w
                notifyVideoSizeIfReady()
            }

        case "video-params/h":
            if let h = (value as? NSNumber)?.int64Value, h > 0 {
                lastVideoHeight = h
                notifyVideoSizeIfReady()
            }

        case "track-list":
            if let json = value as? String, !json.isEmpty {
                cachedTracksSnapshot = Self.parseTrackListJson(json)
                delegate?.mpvMetalView(self, onTracksUpdated: cachedTracksSnapshot)
            }

        case "aid", "sid":
            refreshTracksSnapshotFromBridge()

        default:
            break
        }
    }

    private func notifyVideoSizeIfReady() {
        guard lastVideoWidth > 0 && lastVideoHeight > 0 else { return }
        let nextSize = CGSize(width: CGFloat(lastVideoWidth), height: CGFloat(lastVideoHeight))
        guard nextSize != videoSize else { return }
        videoSize = nextSize
        delegate?.mpvMetalView(self, onVideoSizeChanged: nextSize)
    }

    private func refreshTracksSnapshotFromBridge() {
        guard let json = bridge?.getPropertyString("track-list"), !json.isEmpty else { return }
        cachedTracksSnapshot = Self.parseTrackListJson(json)
        delegate?.mpvMetalView(self, onTracksUpdated: cachedTracksSnapshot)
    }
    #endif

    public static func parseTrackListJson(_ json: String) -> MarcoMpvTracksSnapshot {
        guard let data = json.data(using: .utf8),
              let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
        else {
            return MarcoMpvTracksSnapshot()
        }
        var audio: [MarcoMediaTrack] = []
        var subs: [MarcoMediaTrack] = []
        for item in arr {
            let kind = ((item["type"] as? String) ?? "").lowercased()
            guard kind == "audio" || kind == "sub" else { continue }
            let idVal: String
            if let num = item["id"] as? NSNumber {
                idVal = num.stringValue
            } else if let str = item["id"] as? String {
                idVal = str
            } else {
                continue
            }
            let title = (item["title"] as? String) ?? ""
            let lang = (item["lang"] as? String) ?? ""
            let codec = (item["codec"] as? String) ?? ""
            let selected = (item["selected"] as? NSNumber)?.boolValue ?? false
            let lowerCodec = codec.lowercased()
            let isBitmap = lowerCodec.contains("pgs") || lowerCodec.contains("dvd_subtitle") || lowerCodec.contains("dvb")
            let track = MarcoMediaTrack(
                id: idVal,
                title: title.isEmpty ? (codec.isEmpty ? "轨道 #\(idVal)" : codec.uppercased()) : title,
                language: lang,
                isSelected: selected,
                isBitmapSubtitle: isBitmap,
                codec: codec
            )
            if kind == "audio" {
                audio.append(track)
            } else {
                subs.append(track)
            }
        }
        return MarcoMpvTracksSnapshot(audioTracks: audio, subtitleTracks: subs)
    }
}
