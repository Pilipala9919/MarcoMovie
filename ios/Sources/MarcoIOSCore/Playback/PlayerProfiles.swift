// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only

import CryptoKit
import Foundation

/// Device thermal pressure state mapped from `ProcessInfo.ThermalState`.
public enum IosThermalState: Int, Codable, CaseIterable, Hashable, Sendable {
    case nominal = 0
    case fair = 1
    case serious = 2
    case critical = 3

    public var isElevated: Bool {
        rawValue >= IosThermalState.fair.rawValue
    }

    public var isThrottled: Bool {
        self == .serious || self == .critical
    }

    public var labelZh: String {
        switch self {
        case .nominal: return "正常"
        case .fair: return "轻微升温"
        case .serious: return "严重发热"
        case .critical: return "临界高温"
        }
    }

    public static func from(_ state: ProcessInfo.ThermalState) -> IosThermalState {
        switch state {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .nominal
        }
    }
}

/// RAM-tiered libmpv demuxer cache sizing resolving the default 33 MiB mobile buffer bottleneck.
public enum IosRamBufferTier: String, CaseIterable, Hashable, Sendable {
    case standardUnder6Gb
    case high6GbPlusDefault
    case high6GbPlusLarge
    case liveLean

    public var maxBytes: Int {
        switch self {
        case .standardUnder6Gb: return 67_108_864 // 64 MiB
        case .high6GbPlusDefault: return 134_217_728 // 128 MiB
        case .high6GbPlusLarge: return 268_435_456 // 256 MiB
        case .liveLean: return 16_777_216 // 16 MiB
        }
    }

    public var maxBackBytes: Int {
        switch self {
        case .standardUnder6Gb: return 16_777_216 // 16 MiB
        case .high6GbPlusDefault: return 33_554_432 // 32 MiB
        case .high6GbPlusLarge: return 67_108_864 // 64 MiB
        case .liveLean: return 4_194_304 // 4 MiB
        }
    }

    public var readaheadSecs: Int {
        switch self {
        case .standardUnder6Gb: return 30
        case .high6GbPlusDefault: return 60
        case .high6GbPlusLarge: return 90
        case .liveLean: return 5
        }
    }
}

/// Builds iOS-tuned libmpv properties for 4K/10-bit NV12 zero-copy VideoToolbox decoding,
/// RAM-tiered demuxer buffering, HDR tone mapping, thermal backoff, and 4-tier vocal loudness.
public enum IosMpvProfile {
    /// ~5.2 GiB threshold cleanly separating 6 GB+ devices (~5.5-5.9 GiB reported) from 4 GB devices (~3.6-3.9 GiB).
    public static let highRamPhysicalBytesThreshold: UInt64 = 5_583_457_485

    public static func isHighRamDevice(_ physicalMemoryBytes: UInt64?) -> Bool {
        guard let bytes = physicalMemoryBytes, bytes > 0 else { return false }
        return bytes >= highRamPhysicalBytesThreshold
    }

    public static func resolveBufferTier(
        physicalMemoryBytes: UInt64? = nil,
        largeBuffer: Bool = false,
        isLive: Bool = false
    ) -> IosRamBufferTier {
        if isLive { return .liveLean }
        if isHighRamDevice(physicalMemoryBytes) {
            return largeBuffer ? .high6GbPlusLarge : .high6GbPlusDefault
        }
        return .standardUnder6Gb
    }

    /// Activates low-power thermal mode (`hdr-compute-peak=no`, `dither-depth=no`, `video-sync=audio`)
    /// when thermal state reaches `.fair` or higher, or on legacy iOS < 16.
    public static func shouldUseLowPowerThermalMode(
        thermalState: IosThermalState = .nominal,
        iosMajorVersion: Int = 0
    ) -> Bool {
        if thermalState.isElevated { return true }
        if iosMajorVersion > 0 && iosMajorVersion < 16 { return true }
        return false
    }

    public static func buildVocalLoudnessProperties(_ preset: VocalLoudnessPreset) -> [String: String] {
        [
            "volume-max": "\(preset.volumeMax)",
            "af": preset.audioFilter,
        ]
    }

    public static func buildMpvProperties(
        physicalMemoryBytes: UInt64? = nil,
        largeBuffer: Bool = false,
        isLive: Bool = false,
        hdrToneMapping: IosHdrToneMappingMode = .auto,
        vocalLoudness: VocalLoudnessPreset = .off,
        hwdec: String = "videotoolbox",
        lowPowerThermalMode: Bool = false
    ) -> [String: String] {
        let tier = resolveBufferTier(
            physicalMemoryBytes: physicalMemoryBytes,
            largeBuffer: largeBuffer,
            isLive: isLive
        )
        var props: [String: String] = [
            "cache": "yes",
            "cache-on-disk": "no",
            "hwdec": hwdec,
            "hwdec-image-format": "nv12",
            "vd-lavc-threads": "0",
            "vd-lavc-dr": "yes",
            "framedrop": "vo",
            "demuxer-max-bytes": "\(tier.maxBytes)",
            "demuxer-max-back-bytes": "\(tier.maxBackBytes)",
            "demuxer-readahead-secs": "\(tier.readaheadSecs)",
            "hr-seek": "yes",
            "sub-ass-override": "scale",
            "tone-mapping": hdrToneMapping.mpvToneMapping,
            "hdr-compute-peak": lowPowerThermalMode ? "no" : hdrToneMapping.computePeak,
            "gamut-mapping-mode": "perceptual",
            "dither-depth": lowPowerThermalMode ? "no" : "auto",
            "target-colorspace-hint": "yes",
        ]
        if lowPowerThermalMode {
            props["video-sync"] = "audio"
        }
        for (k, v) in buildVocalLoudnessProperties(vocalLoudness) {
            props[k] = v
        }
        return props
    }
}

/// Manages SHA-256 integrity verification and thermal throttling guard for bundled
/// `bloc97/Anime4K v4.0.1` GLSL shaders (`Anime4K_Upscale_CNN_x2_S.glsl` single-pass tier on iOS).
public enum Anime4kShaderManager {
    public static let upstreamTag = "v4.0.1"
    public static let iosSinglePassShaderFile = "Anime4K_Upscale_CNN_x2_S.glsl"

    /// Pinned SHA-256 digests matching `flutter/assets/shaders/anime4k/manifest.json`.
    public static let expectedShaderSha256: [String: String] = [
        "Anime4K_Clamp_Highlights.glsl":
            "8c5fb67c76bed3021f8a27b050c3b97a6ac1b284f9ce91c04189015c354c0217",
        "Anime4K_Restore_CNN_S.glsl":
            "97c24dc370ab300c108bfaa09db7f175aeff343674842c299cf3940a3d330427",
        "Anime4K_Restore_CNN_M.glsl":
            "67ea3ed26539e8de3b7d307688535d2ff17e8d147e11dda0247da7770dbecf41",
        "Anime4K_Restore_CNN_VL.glsl":
            "35036722733305cd4d4e57660b883bbe2569ba2914033c254327107d7b77e35e",
        "Anime4K_Upscale_CNN_x2_S.glsl":
            "4c53ec2e287908f7ee7bcb266b0170421626d663576468b7d7dafc62962649a4",
        "Anime4K_Upscale_CNN_x2_M.glsl":
            "716e02098a68f0d648761f2b96b4dd139e1cb09b174bb369fca3aa34328fff7e",
    ]

    public static func isAllowed(thermalState: IosThermalState) -> Bool {
        !thermalState.isThrottled
    }

    public static func shouldShowUltraHdWarning(videoHeight: Int) -> Bool {
        videoHeight > 1080
    }

    public static func verifyShaderIntegrity(fileName: String, data: Data) -> Bool {
        guard let expected = expectedShaderSha256[fileName], !data.isEmpty else { return false }
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return actual == expected
    }

    public static func candidateShaderDirectories() -> [URL] {
        var dirs: [URL] = []
        #if SWIFT_PACKAGE
        if let resUrl = Bundle.module.resourceURL {
            dirs.append(resUrl.appendingPathComponent("shaders/anime4k", isDirectory: true))
            dirs.append(resUrl.appendingPathComponent("anime4k", isDirectory: true))
        }
        #endif
        if let mainRes = Bundle.main.resourceURL {
            dirs.append(mainRes.appendingPathComponent("shaders/anime4k", isDirectory: true))
            dirs.append(mainRes.appendingPathComponent("anime4k", isDirectory: true))
        }
        let coreRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        dirs.append(coreRoot.appendingPathComponent("Resources/shaders/anime4k", isDirectory: true))
        let repoRoot = coreRoot
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        dirs.append(repoRoot.appendingPathComponent("flutter/assets/shaders/anime4k", isDirectory: true))
        return dirs
    }

    /// Resolves and verifies the SHA-256 digest of a bundled Anime4K GLSL shader file.
    /// Throws when throttled (`serious`/`critical`), missing, or integrity check fails.
    public static func resolveVerifiedShaderPath(
        fileName: String = iosSinglePassShaderFile,
        searchDirectories: [URL]? = nil,
        thermalState: IosThermalState = .nominal
    ) throws -> URL {
        guard isAllowed(thermalState: thermalState) else {
            throw MarcoError.unsupported("设备发热达到 \(thermalState.labelZh)，已自动暂停 Anime4K 超分着色器")
        }
        guard expectedShaderSha256[fileName] != nil else {
            throw MarcoError.invalidFormat("未知的 Anime4K 着色器文件：\(fileName)")
        }
        let dirs = searchDirectories ?? candidateShaderDirectories()
        var foundTampered = false
        for dir in dirs {
            let candidate = dir.appendingPathComponent(fileName)
            guard FileManager.default.fileExists(atPath: candidate.path),
                  let data = try? Data(contentsOf: candidate)
            else { continue }
            if verifyShaderIntegrity(fileName: fileName, data: data) {
                return candidate
            }
            foundTampered = true
        }
        if foundTampered {
            throw MarcoError.invalidFormat("Anime4K 着色器 SHA-256 完整性校验失败：\(fileName)")
        }
        throw MarcoError.storageError("未找到内置 Anime4K 着色器资源：\(fileName)")
    }

    /// Returns the verified single-pass shader path for iOS `libmpv` `glsl-shaders`, or `nil`
    /// if thermally throttled or unavailable.
    public static func resolveIosLightweightShaderChain(
        searchDirectories: [URL]? = nil,
        thermalState: IosThermalState = .nominal
    ) -> String? {
        guard let url = try? resolveVerifiedShaderPath(
            fileName: iosSinglePassShaderFile,
            searchDirectories: searchDirectories,
            thermalState: thermalState
        ) else {
            return nil
        }
        return url.path
    }
}

// MARK: - AVPlayer vs libmpv Static Precheck & Engine Selector

public struct IosAvPlayerPrecheckResult: Equatable, Sendable {
    public let supported: Bool
    public let reason: String?
    public let detectedExtension: String?

    public init(supported: Bool, reason: String? = nil, detectedExtension: String? = nil) {
        self.supported = supported
        self.reason = reason
        self.detectedExtension = detectedExtension
    }
}

public struct IosPlaybackEngineDecision: Equatable, Sendable {
    public let engine: IosPlaybackEngineMode
    public let reason: String
    public let fellBackFromPreferred: Bool

    public init(engine: IosPlaybackEngineMode, reason: String, fellBackFromPreferred: Bool = false) {
        self.engine = engine
        self.reason = reason
        self.fellBackFromPreferred = fellBackFromPreferred
    }
}

/// Deterministic playback kernel router deciding between Apple native `AVPlayer` (low-power
/// VideoToolbox, native Dolby Vision, PiP, AirPlay 2) and `libmpv` (MKV/FLV/TS/RTSP/ASS/PGS).
public enum IosPlaybackEngineSelector {
    public static let incompatibleSchemes: Set<String> = [
        "rtsp", "rtsps", "rtmp", "rtmps", "rtp", "udp", "mms", "mmsh", "mmst", "igmp",
    ]

    public static let incompatibleContainers: Set<String> = [
        ".mkv", ".flv", ".avi", ".wmv", ".rmvb", ".rm", ".webm", ".vob",
        ".ogv", ".divx", ".asf", ".3gp", ".smil", ".ts", ".m2ts", ".mts",
        ".mpeg", ".mpg", ".mxf", ".iso",
    ]

    public static let incompatibleSubtitles: Set<String> = [
        ".ass", ".ssa", ".sup", ".pgs", ".idx", ".sub",
    ]

    public static func precheckAvPlayer(
        url rawUrl: String,
        episodeName: String = "",
        subtitleUrl: String = ""
    ) -> IosAvPlayerPrecheckResult {
        let trimmedUrl = rawUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        if let parsed = URL(string: trimmedUrl), let scheme = parsed.scheme?.lowercased() {
            if incompatibleSchemes.contains(scheme) {
                return IosAvPlayerPrecheckResult(
                    supported: false,
                    reason: "AVPlayer 不支持 \(scheme.uppercased()) 流媒体协议，切换至 libmpv",
                    detectedExtension: scheme
                )
            }
            let pathLower = parsed.path.lowercased()
            for ext in incompatibleContainers where pathLower.hasSuffix(ext) {
                return IosAvPlayerPrecheckResult(
                    supported: false,
                    reason: "AVPlayer 不支持 \(ext.uppercased()) 容器格式，切换至 libmpv",
                    detectedExtension: ext
                )
            }
        }

        let epLower = episodeName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for ext in incompatibleContainers where epLower.hasSuffix(ext) {
            return IosAvPlayerPrecheckResult(
                supported: false,
                reason: "分集文件为 \(ext.uppercased()) 容器格式，切换至 libmpv",
                detectedExtension: ext
            )
        }

        let subLower = subtitleUrl.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !subLower.isEmpty {
            let cleanSubPath = URL(string: subLower)?.path.lowercased() ?? subLower
            for ext in incompatibleSubtitles where cleanSubPath.hasSuffix(ext) {
                return IosAvPlayerPrecheckResult(
                    supported: false,
                    reason: "外挂 \(ext.uppercased()) 特效/图形字幕需要 libmpv 渲染",
                    detectedExtension: ext
                )
            }
        }

        return IosAvPlayerPrecheckResult(supported: true)
    }

    public static func selectEngine(
        preferredMode: IosPlaybackEngineMode,
        url: String,
        episodeName: String = "",
        lineName: String = "",
        videoTitle: String = "",
        videoRemarks: String = "",
        subtitleUrl: String = "",
        isLive: Bool = false,
        mpvAvailable: Bool = MarcoBuildCapabilities.hasMpv
    ) -> IosPlaybackEngineDecision {
        let precheck = precheckAvPlayer(url: url, episodeName: episodeName, subtitleUrl: subtitleUrl)

        if preferredMode == .mpv {
            if mpvAvailable {
                return IosPlaybackEngineDecision(engine: .mpv, reason: "用户首选用 libmpv 全能内核")
            }
            return IosPlaybackEngineDecision(
                engine: .avplayer,
                reason: "当前轻量构建未链接 libmpv，回退至 Apple AVPlayer",
                fellBackFromPreferred: true
            )
        }

        if !precheck.supported {
            if mpvAvailable {
                return IosPlaybackEngineDecision(
                    engine: .mpv,
                    reason: precheck.reason ?? "AVPlayer 不支持当前格式，自动回退至 libmpv",
                    fellBackFromPreferred: true
                )
            }
            return IosPlaybackEngineDecision(
                engine: .avplayer,
                reason: "检测到 \(precheck.detectedExtension ?? "非原生容器") 但未链接 libmpv，继续尝试 AVPlayer"
            )
        }

        if EpisodeScraperService.isLikelyDolbyVision(
            url: url,
            episodeName: episodeName,
            lineName: lineName,
            videoTitle: videoTitle,
            videoRemarks: videoRemarks
        ) {
            return IosPlaybackEngineDecision(
                engine: .avplayer,
                reason: "杜比视界兼容封装优先使用 Apple AVPlayer 硬件渲染"
            )
        }

        return IosPlaybackEngineDecision(
            engine: .avplayer,
            reason: isLive ? "直播流优先使用低功耗 Apple AVPlayer" : "原生封装优先使用低功耗 Apple AVPlayer"
        )
    }
}
