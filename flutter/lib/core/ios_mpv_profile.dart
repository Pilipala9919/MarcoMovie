// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
import 'package:media_kit/media_kit.dart';

typedef MpvPropertySetter = Future<void> Function(String key, String value);

/// Device RAM tier used to lift the iOS libmpv 33 MiB buffer bottleneck.
enum IosRamBufferTier {
  standardUnder6Gb(
    maxBytes: 67108864, // 64 MiB
    maxBackBytes: 16777216, // 16 MiB
    readaheadSecs: 30,
  ),
  high6GbPlusDefault(
    maxBytes: 134217728, // 128 MiB
    maxBackBytes: 33554432, // 32 MiB
    readaheadSecs: 60,
  ),
  high6GbPlusLarge(
    maxBytes: 268435456, // 256 MiB
    maxBackBytes: 67108864, // 64 MiB
    readaheadSecs: 90,
  ),
  liveLean(
    maxBytes: 16777216, // 16 MiB
    maxBackBytes: 4194304, // 4 MiB
    readaheadSecs: 5,
  );

  final int maxBytes;
  final int maxBackBytes;
  final int readaheadSecs;

  const IosRamBufferTier({
    required this.maxBytes,
    required this.maxBackBytes,
    required this.readaheadSecs,
  });
}

/// HDR tone-mapping strategy for iOS/iPadOS libmpv XDR/EDR displays.
enum IosHdrToneMappingMode {
  auto(
    id: 'auto',
    labelZh: '自动 (BT.2390 动态)',
    mpvToneMapping: 'bt.2390',
    computePeak: 'yes',
  ),
  bt2390(
    id: 'bt.2390',
    labelZh: 'BT.2390 电影动态映射',
    mpvToneMapping: 'bt.2390',
    computePeak: 'yes',
  ),
  bt2446a(
    id: 'bt.2446a',
    labelZh: 'BT.2446a 高亮保留',
    mpvToneMapping: 'bt.2446a',
    computePeak: 'yes',
  ),
  hable(
    id: 'hable',
    labelZh: 'Hable 柔和映射',
    mpvToneMapping: 'hable',
    computePeak: 'yes',
  ),
  clip(
    id: 'clip',
    labelZh: '原生高光直出 (Clip)',
    mpvToneMapping: 'clip',
    computePeak: 'no',
  );

  final String id;
  final String labelZh;
  final String mpvToneMapping;
  final String computePeak;

  const IosHdrToneMappingMode({
    required this.id,
    required this.labelZh,
    required this.mpvToneMapping,
    required this.computePeak,
  });

  static IosHdrToneMappingMode fromId(String? raw) {
    final normalized = (raw ?? '').trim().toLowerCase();
    for (final mode in IosHdrToneMappingMode.values) {
      if (mode.id == normalized) return mode;
    }
    return IosHdrToneMappingMode.auto;
  }
}

/// Cross-platform 4-tier dialogue loudness and dynamic-range normalizer
/// resolving quiet 5.1/7.1 -> stereo dialogue downmixes.
enum VocalLoudnessPreset {
  off(
    id: 'off',
    labelZh: '关闭',
    shortLabelZh: '关闭',
    descriptionZh: '保持原始音频动态范围（100% 音量上限）',
    volumeMax: 100,
    audioFilter: '',
  ),
  light(
    id: 'light',
    labelZh: '轻度',
    shortLabelZh: '轻度',
    descriptionZh: '温和提升微弱人声（上限 150%，保留影院动态）',
    volumeMax: 150,
    audioFilter: 'lavfi=[dynaudnorm=f=150:g=15:p=0.90:m=3.0]',
  ),
  standard(
    id: 'standard',
    labelZh: '标准',
    shortLabelZh: '标准',
    descriptionZh: '均衡夜间对白响度（上限 200%，抑制爆炸声刺耳）',
    volumeMax: 200,
    audioFilter: 'lavfi=[dynaudnorm=f=150:g=15:p=0.95:m=6.0]',
  ),
  cinemaVocal(
    id: 'cinema_vocal',
    labelZh: '影院人声',
    shortLabelZh: '影院人声',
    descriptionZh: '强力增强 1–3kHz 人声对白，专治 5.1/7.1 小声片源',
    volumeMax: 200,
    audioFilter:
        'lavfi=[highpass=f=90,equalizer=f=1800:t=q:w=1.2:g=3.5,dynaudnorm=f=120:g=11:p=0.95:m=8.0]',
  );

  final String id;
  final String labelZh;
  final String shortLabelZh;
  final String descriptionZh;
  final int volumeMax;
  final String audioFilter;

  const VocalLoudnessPreset({
    required this.id,
    required this.labelZh,
    required this.shortLabelZh,
    required this.descriptionZh,
    required this.volumeMax,
    required this.audioFilter,
  });

  static VocalLoudnessPreset fromId(String? raw) {
    final normalized = (raw ?? '').trim().toLowerCase();
    for (final preset in VocalLoudnessPreset.values) {
      if (preset.id == normalized) return preset;
    }
    return VocalLoudnessPreset.off;
  }
}

/// Builds and applies iOS-tuned 4K/HDR, RAM-tiered demuxer buffering,
/// frame-accurate seeking, ASS scaling, and 4-tier vocal loudness properties
/// for `libmpv` (`media_kit` [NativePlayer]).
class IosMpvProfile {
  /// iOS `ProcessInfo.physicalMemory` reports usable physical RAM slightly below
  /// the marketing 6 GB figure (~5.5–5.9 GiB due to kernel carveout), whereas
  /// 4 GB devices report ~3.6–3.9 GiB. `5.2 GiB` cleanly separates 6 GB+ vs <6 GB.
  static const int highRamPhysicalBytesThreshold = 5583457485; // ~5.2 GiB

  static const String prefKeyEngineMode = 'ios_player_engine_mode';
  static const String prefKeyHdrToneMapping = 'ios_mpv_hdr_tone_mapping';
  static const String prefKeyVocalLoudness = 'vocal_loudness_preset';
  static const String prefKeyLargeBuffer = 'ios_mpv_large_buffer';

  static bool isHighRamDevice(int? physicalMemoryBytes) {
    if (physicalMemoryBytes == null || physicalMemoryBytes <= 0) return false;
    return physicalMemoryBytes >= highRamPhysicalBytesThreshold;
  }

  static IosRamBufferTier resolveBufferTier({
    int? physicalMemoryBytes,
    bool largeBuffer = false,
    bool isLive = false,
  }) {
    if (isLive) return IosRamBufferTier.liveLean;
    if (isHighRamDevice(physicalMemoryBytes)) {
      return largeBuffer
          ? IosRamBufferTier.high6GbPlusLarge
          : IosRamBufferTier.high6GbPlusDefault;
    }
    return IosRamBufferTier.standardUnder6Gb;
  }

  /// Generates the full map of libmpv properties for iOS playback.
  static Map<String, String> buildMpvProperties({
    int? physicalMemoryBytes,
    bool largeBuffer = false,
    bool isLive = false,
    IosHdrToneMappingMode hdrToneMapping = IosHdrToneMappingMode.auto,
    VocalLoudnessPreset vocalLoudness = VocalLoudnessPreset.off,
    String hwdec = 'videotoolbox',
  }) {
    final tier = resolveBufferTier(
      physicalMemoryBytes: physicalMemoryBytes,
      largeBuffer: largeBuffer,
      isLive: isLive,
    );

    return <String, String>{
      'cache': 'yes',
      'cache-on-disk': 'no',
      'hwdec': hwdec,
      'demuxer-max-bytes': '${tier.maxBytes}',
      'demuxer-max-back-bytes': '${tier.maxBackBytes}',
      'demuxer-readahead-secs': '${tier.readaheadSecs}',
      'hr-seek': 'yes',
      'sub-ass-override': 'scale',
      'tone-mapping': hdrToneMapping.mpvToneMapping,
      'hdr-compute-peak': hdrToneMapping.computePeak,
      'gamut-mapping-mode': 'perceptual',
      'dither-depth': 'auto',
      'target-colorspace-hint': 'yes',
      ...buildVocalLoudnessProperties(vocalLoudness),
    };
  }

  /// Generates cross-platform `volume-max` and `af` properties for [preset].
  static Map<String, String> buildVocalLoudnessProperties(
    VocalLoudnessPreset preset,
  ) {
    return <String, String>{
      'volume-max': '${preset.volumeMax}',
      'af': preset.audioFilter,
    };
  }

  /// Applies the full iOS MPV profile to [player] safely.
  static Future<void> applyToPlayer(
    Player player, {
    int? physicalMemoryBytes,
    bool largeBuffer = false,
    bool isLive = false,
    IosHdrToneMappingMode hdrToneMapping = IosHdrToneMappingMode.auto,
    VocalLoudnessPreset vocalLoudness = VocalLoudnessPreset.off,
    String hwdec = 'videotoolbox',
    MpvPropertySetter? propertySetterOverride,
  }) async {
    final setter = propertySetterOverride ?? _resolveSetter(player);
    if (setter == null) return;
    final props = buildMpvProperties(
      physicalMemoryBytes: physicalMemoryBytes,
      largeBuffer: largeBuffer,
      isLive: isLive,
      hdrToneMapping: hdrToneMapping,
      vocalLoudness: vocalLoudness,
      hwdec: hwdec,
    );
    for (final entry in props.entries) {
      try {
        await setter(entry.key, entry.value);
      } catch (_) {}
    }
  }

  /// Hot-applies vocal loudness gain without restarting playback.
  static Future<void> applyVocalLoudness(
    Player player,
    VocalLoudnessPreset preset, {
    MpvPropertySetter? propertySetterOverride,
  }) async {
    final setter = propertySetterOverride ?? _resolveSetter(player);
    if (setter == null) return;
    final props = buildVocalLoudnessProperties(preset);
    for (final entry in props.entries) {
      try {
        await setter(entry.key, entry.value);
      } catch (_) {}
    }
  }

  static MpvPropertySetter? _resolveSetter(Player player) {
    final platform = player.platform;
    if (platform is NativePlayer) {
      return platform.setProperty;
    }
    return null;
  }
}
