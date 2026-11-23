// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ohos_runtime.dart';

/// Windows x64 `libmpv` (`vo=libmpv` offscreen texture pipeline) video quality
/// and HDR tone-mapping presets.
enum WindowsQualityPreset {
  ecoCompat(
    id: 'ecoCompat',
    labelZh: '省电兼容',
    shortLabelZh: '省电',
    descriptionZh: '低功耗 / 老核显兼容：bilinear 缩放，关闭 HDR 动态峰值与去色带',
    baseScale: 'bilinear',
    baseCscale: 'bilinear',
    dscale: 'bilinear',
  ),
  balancedHq(
    id: 'balancedHq',
    labelZh: '高画质 HDR 映射',
    shortLabelZh: '高画质',
    descriptionZh:
        '默认推荐：spline36 + mitchell 缩放，开启 HDR 动态色调映射与感知色域映射',
    baseScale: 'spline36',
    baseCscale: 'spline36',
    dscale: 'mitchell',
  ),
  cinemaUltra(
    id: 'cinemaUltra',
    labelZh: '旗舰超清锐利',
    shortLabelZh: '旗舰',
    descriptionZh:
        'ewa_lanczossharp 超清缩放 + 去色带 (deband) + 高精度峰值检测与色彩提示',
    baseScale: 'ewa_lanczossharp',
    baseCscale: 'spline36',
    dscale: 'mitchell',
  );

  final String id;
  final String labelZh;
  final String shortLabelZh;
  final String descriptionZh;
  final String baseScale;
  final String baseCscale;
  final String dscale;

  const WindowsQualityPreset({
    required this.id,
    required this.labelZh,
    required this.shortLabelZh,
    required this.descriptionZh,
    required this.baseScale,
    required this.baseCscale,
    required this.dscale,
  });

  static WindowsQualityPreset fromId(String? raw) {
    final normalized = (raw ?? '').trim().toLowerCase();
    switch (normalized) {
      case 'ecocompat':
      case 'eco_compat':
      case 'eco':
        return WindowsQualityPreset.ecoCompat;
      case 'cinemaultra':
      case 'cinema_ultra':
      case 'cinema':
      case 'ultra':
        return WindowsQualityPreset.cinemaUltra;
      case 'balancedhq':
      case 'balanced_hq':
      case 'balanced':
      case '':
      default:
        return WindowsQualityPreset.balancedHq;
    }
  }
}

/// 4-tier dynamic loudness normalization & vocal dialogue boost presets for
/// multi-channel (5.1/7.1) movie tracks on stereo desktop speakers/headphones.
enum AudioLoudnessPreset {
  off(
    id: 'off',
    labelZh: '关闭',
    shortLabelZh: '关闭',
    descriptionZh: '原声动态范围，不启用响度增强',
    volumeMax: '100',
    audioFilter: '',
  ),
  light(
    id: 'light',
    labelZh: '轻度',
    shortLabelZh: '轻度',
    descriptionZh: '温和动态响度压缩，保留较多电影动态起伏',
    volumeMax: '200',
    audioFilter: 'lavfi=[dynaudnorm=f=250:g=21:p=0.90:m=4.0]',
  ),
  standard(
    id: 'standard',
    labelZh: '标准',
    shortLabelZh: '标准',
    descriptionZh: '均衡提升对白清晰度与低声部细节（推荐）',
    volumeMax: '200',
    audioFilter: 'lavfi=[dynaudnorm=f=150:g=15:p=0.95]',
  ),
  cinemaVocal(
    id: 'cinemaVocal',
    labelZh: '影院人声',
    shortLabelZh: '影院人声',
    descriptionZh: '强效人声对白增强与夜间峰值控制，抑制爆炸声突刺',
    volumeMax: '200',
    audioFilter: 'lavfi=[dynaudnorm=f=100:g=9:p=0.95:m=12.0]',
  );

  final String id;
  final String labelZh;
  final String shortLabelZh;
  final String descriptionZh;
  final String volumeMax;
  final String audioFilter;

  const AudioLoudnessPreset({
    required this.id,
    required this.labelZh,
    required this.shortLabelZh,
    required this.descriptionZh,
    required this.volumeMax,
    required this.audioFilter,
  });

  static AudioLoudnessPreset fromId(String? raw) {
    final normalized = (raw ?? '').trim().toLowerCase();
    switch (normalized) {
      case 'light':
        return AudioLoudnessPreset.light;
      case 'standard':
        return AudioLoudnessPreset.standard;
      case 'cinemavocal':
      case 'cinema_vocal':
      case 'vocal':
        return AudioLoudnessPreset.cinemaVocal;
      case 'off':
      case '':
      default:
        return AudioLoudnessPreset.off;
    }
  }
}

typedef WindowsMpvPropertySetter = Future<void> Function(
  String key,
  String value,
);

/// Manages Windows `libmpv` video quality presets, HDR tone-mapping fallback
/// chain, smart `hwdec` linkage (zero-copy `d3d11va`/`auto-safe` vs
/// `d3d11va-copy` for Anime4K / compat kernel / software filters), and 4-tier
/// `dynaudnorm` vocal loudness boosting.
class WindowsVideoQualityController extends ChangeNotifier {
  static const String prefKeyQualityPreset = 'windows_video_quality_preset';
  static const String prefKeyLoudnessPreset = 'windows_audio_loudness_preset';

  /// Ordered fallback chain for `tone-mapping` across newer and older `libmpv`
  /// / `libplacebo` builds.
  static const List<String> toneMappingFallbackChain = <String>[
    'bt.2446a',
    'bt.2390',
    'spline',
  ];

  static const String fallbackAudioFilter =
      'lavfi=[dynaudnorm=f=150:g=15:p=0.95]';

  final TargetPlatform? platformOverride;
  final bool? isOhosOverride;
  final bool? isWebOverride;
  final bool? isNativePlayerOverride;
  final WindowsMpvPropertySetter? propertySetterOverride;
  final bool persistLocally;
  SharedPreferences? _prefs;

  WindowsQualityPreset _qualityPreset;
  AudioLoudnessPreset _loudnessPreset;
  String _effectiveScale;
  String? _effectiveToneMapping;
  String _effectiveHwdec = 'auto-safe';
  String? _lastWarning;
  bool _disposed = false;
  int _qualityOpGen = 0;
  int _loudnessOpGen = 0;

  WindowsVideoQualityController({
    this.platformOverride,
    this.isOhosOverride,
    this.isWebOverride,
    this.isNativePlayerOverride,
    this.propertySetterOverride,
    SharedPreferences? prefs,
    this.persistLocally = true,
    WindowsQualityPreset initialQualityPreset = WindowsQualityPreset.balancedHq,
    AudioLoudnessPreset initialLoudnessPreset = AudioLoudnessPreset.off,
  })  : _prefs = prefs,
        _qualityPreset = initialQualityPreset,
        _loudnessPreset = initialLoudnessPreset,
        _effectiveScale = initialQualityPreset.baseScale;

  WindowsQualityPreset get qualityPreset => _qualityPreset;
  AudioLoudnessPreset get loudnessPreset => _loudnessPreset;
  String get effectiveScale => _effectiveScale;
  String? get effectiveToneMapping => _effectiveToneMapping;
  String get effectiveHwdec => _effectiveHwdec;
  String? get lastWarning => _lastWarning;

  /// Base `(scale, cscale)` corresponding to the active Windows quality preset,
  /// suitable for injecting into `Anime4kController.windowsBaseScalerResolver`.
  ({String scale, String cscale}) get activeBaseScalers {
    if (!isPlatformSupported) {
      return (scale: 'bilinear', cscale: 'bilinear');
    }
    if (_qualityPreset == WindowsQualityPreset.cinemaUltra) {
      return (
        scale: _effectiveScale,
        cscale: _qualityPreset.baseCscale,
      );
    }
    return (
      scale: _qualityPreset.baseScale,
      cscale: _qualityPreset.baseCscale,
    );
  }

  static bool isSupportedPlatform({
    TargetPlatform? platformOverride,
    bool? isOhosOverride,
    bool? isWebOverride,
  }) {
    if (isOhosOverride ?? OhosRuntime.isOhos) return false;
    if (isWebOverride ?? kIsWeb) return false;
    final platform = platformOverride ?? defaultTargetPlatform;
    return platform == TargetPlatform.windows;
  }

  bool get isPlatformSupported => isSupportedPlatform(
        platformOverride: platformOverride,
        isOhosOverride: isOhosOverride,
        isWebOverride: isWebOverride,
      );

  bool isAvailableForPlayer(Player player) {
    if (!isPlatformSupported) return false;
    if (isNativePlayerOverride != null) return isNativePlayerOverride!;
    if (propertySetterOverride != null) return true;
    return player.platform is NativePlayer;
  }

  WindowsMpvPropertySetter? _resolveSetter(Player player) {
    if (propertySetterOverride != null) return propertySetterOverride;
    final platform = player.platform;
    if (platform is NativePlayer) {
      return platform.setProperty;
    }
    return null;
  }

  /// Resolves the optimal Windows `hwdec` mode given quality preset, active
  /// shaders/software filters, and player kernel (`'ijk'` = compat kernel).
  static String resolveHardwareDecoder({
    WindowsQualityPreset qualityPreset = WindowsQualityPreset.balancedHq,
    bool anime4kActive = false,
    bool softFilterActive = false,
    String playerKernel = 'exo',
    bool preferZeroCopyD3d11 = false,
  }) {
    if (anime4kActive || softFilterActive || playerKernel == 'ijk') {
      return 'd3d11va-copy';
    }
    if (qualityPreset == WindowsQualityPreset.ecoCompat) {
      return 'd3d11va';
    }
    return preferZeroCopyD3d11 ? 'd3d11va' : 'auto-safe';
  }

  /// Convenience static loader for settings UI when no controller instance is
  /// mounted.
  static Future<WindowsQualityPreset> readSavedQualityPreset([
    SharedPreferences? prefs,
  ]) async {
    try {
      final sp = prefs ?? await SharedPreferences.getInstance();
      return WindowsQualityPreset.fromId(sp.getString(prefKeyQualityPreset));
    } catch (_) {
      return WindowsQualityPreset.balancedHq;
    }
  }

  static Future<AudioLoudnessPreset> readSavedLoudnessPreset([
    SharedPreferences? prefs,
  ]) async {
    try {
      final sp = prefs ?? await SharedPreferences.getInstance();
      return AudioLoudnessPreset.fromId(sp.getString(prefKeyLoudnessPreset));
    } catch (_) {
      return AudioLoudnessPreset.off;
    }
  }

  /// Loads persisted quality and loudness preferences on Windows.
  Future<void> loadSaved() async {
    if (!isPlatformSupported || !persistLocally || _disposed) return;
    try {
      final sp = _prefs ??= await SharedPreferences.getInstance();
      if (_disposed) return;
      final nextQuality = WindowsQualityPreset.fromId(
        sp.getString(prefKeyQualityPreset),
      );
      final nextLoudness = AudioLoudnessPreset.fromId(
        sp.getString(prefKeyLoudnessPreset),
      );
      final changed =
          nextQuality != _qualityPreset || nextLoudness != _loudnessPreset;
      _qualityPreset = nextQuality;
      _loudnessPreset = nextLoudness;
      _effectiveScale = nextQuality.baseScale;
      if (changed && !_disposed) {
        notifyListeners();
      }
    } catch (_) {}
  }

  Future<void> _saveQualityPreset(WindowsQualityPreset preset) async {
    if (!persistLocally || !isPlatformSupported || _disposed) return;
    try {
      final sp = _prefs ??= await SharedPreferences.getInstance();
      await sp.setString(prefKeyQualityPreset, preset.id);
    } catch (_) {}
  }

  Future<void> _saveLoudnessPreset(AudioLoudnessPreset preset) async {
    if (!persistLocally || !isPlatformSupported || _disposed) return;
    try {
      final sp = _prefs ??= await SharedPreferences.getInstance();
      await sp.setString(prefKeyLoudnessPreset, preset.id);
    } catch (_) {}
  }

  /// Updates and persists the quality preset without requiring an active
  /// [Player] (e.g., from desktop Settings).
  Future<void> saveQualityPreset(WindowsQualityPreset next) async {
    if (_disposed) return;
    final changed = _qualityPreset != next;
    _qualityPreset = next;
    _effectiveScale = next.baseScale;
    await _saveQualityPreset(next);
    if (changed && !_disposed) {
      notifyListeners();
    }
  }

  /// Updates and persists the audio loudness preset without requiring an active
  /// [Player] (e.g., from desktop Settings).
  Future<void> saveLoudnessPreset(AudioLoudnessPreset next) async {
    if (_disposed) return;
    final changed = _loudnessPreset != next;
    _loudnessPreset = next;
    await _saveLoudnessPreset(next);
    if (changed && !_disposed) {
      notifyListeners();
    }
  }

  /// Applies both saved/current video quality and loudness presets to [player].
  Future<bool> applyAll(
    Player player, {
    bool anime4kActive = false,
    bool softFilterActive = false,
    String playerKernel = 'exo',
    bool preferZeroCopyD3d11 = false,
  }) async {
    final qualityOk = await applyQualityPreset(
      player,
      _qualityPreset,
      persist: false,
      anime4kActive: anime4kActive,
      softFilterActive: softFilterActive,
      playerKernel: playerKernel,
      preferZeroCopyD3d11: preferZeroCopyD3d11,
    );
    final loudnessOk = await applyLoudnessPreset(
      player,
      _loudnessPreset,
      persist: false,
    );
    return qualityOk && loudnessOk;
  }

  /// Synchronizes `hwdec` on [player] when Anime4K / soft filters / player
  /// kernel state changes without re-applying the full scaler table.
  Future<String?> syncHardwareDecoder(
    Player player, {
    bool anime4kActive = false,
    bool softFilterActive = false,
    String playerKernel = 'exo',
    bool preferZeroCopyD3d11 = false,
  }) async {
    if (_disposed || !isAvailableForPlayer(player)) return null;
    final setProp = _resolveSetter(player);
    if (setProp == null) return null;
    final target = resolveHardwareDecoder(
      qualityPreset: _qualityPreset,
      anime4kActive: anime4kActive,
      softFilterActive: softFilterActive,
      playerKernel: playerKernel,
      preferZeroCopyD3d11: preferZeroCopyD3d11,
    );
    await _trySet(setProp, 'hwdec', target);
    _effectiveHwdec = target;
    return target;
  }

  /// Applies [next] quality preset properties to [player]'s `libmpv` backend
  /// with graceful fallbacks for older `libmpv` builds.
  Future<bool> applyQualityPreset(
    Player player,
    WindowsQualityPreset next, {
    bool persist = true,
    bool anime4kActive = false,
    bool softFilterActive = false,
    String playerKernel = 'exo',
    bool preferZeroCopyD3d11 = false,
  }) async {
    if (_disposed || !isAvailableForPlayer(player)) return false;
    final setProp = _resolveSetter(player);
    if (setProp == null) return false;
    final gen = ++_qualityOpGen;
    _lastWarning = null;

    final hwdec = resolveHardwareDecoder(
      qualityPreset: next,
      anime4kActive: anime4kActive,
      softFilterActive: softFilterActive,
      playerKernel: playerKernel,
      preferZeroCopyD3d11: preferZeroCopyD3d11,
    );
    await _trySet(setProp, 'hwdec', hwdec);
    if (_disposed || gen != _qualityOpGen) return false;
    _effectiveHwdec = hwdec;

    switch (next) {
      case WindowsQualityPreset.ecoCompat:
        _effectiveScale = next.baseScale;
        _effectiveToneMapping = null;
        if (!anime4kActive) {
          await _trySet(setProp, 'scale', 'bilinear');
          if (_disposed || gen != _qualityOpGen) return false;
          await _trySet(setProp, 'cscale', 'bilinear');
          if (_disposed || gen != _qualityOpGen) return false;
        }
        await _trySet(setProp, 'dscale', 'bilinear');
        if (_disposed || gen != _qualityOpGen) return false;
        await _trySet(setProp, 'correct-downscaling', 'no');
        await _trySet(setProp, 'linear-downscaling', 'no');
        await _trySet(setProp, 'sigmoid-upscaling', 'no');
        await _trySet(setProp, 'dither-depth', 'no');
        await _trySet(setProp, 'hdr-compute-peak', 'no');
        await _trySet(setProp, 'deband', 'no');
        await _trySet(setProp, 'gamut-mapping-mode', 'auto');
        await _trySet(setProp, 'tone-mapping', 'auto');
        await _trySet(setProp, 'target-colorspace-hint', 'no');
        break;

      case WindowsQualityPreset.balancedHq:
        _effectiveScale = next.baseScale;
        if (!anime4kActive) {
          await _trySet(setProp, 'scale', 'spline36');
          if (_disposed || gen != _qualityOpGen) return false;
          await _trySet(setProp, 'cscale', 'spline36');
          if (_disposed || gen != _qualityOpGen) return false;
        }
        await _trySet(setProp, 'dscale', 'mitchell');
        if (_disposed || gen != _qualityOpGen) return false;
        await _trySet(setProp, 'correct-downscaling', 'yes');
        await _trySet(setProp, 'linear-downscaling', 'yes');
        await _trySet(setProp, 'sigmoid-upscaling', 'yes');
        await _trySet(setProp, 'dither-depth', 'auto');
        await _trySet(setProp, 'hdr-compute-peak', 'yes');
        await _trySet(setProp, 'deband', 'no');
        await _trySet(setProp, 'gamut-mapping-mode', 'perceptual');
        if (_disposed || gen != _qualityOpGen) return false;
        _effectiveToneMapping = await _applyToneMappingFallback(setProp);
        if (_disposed || gen != _qualityOpGen) return false;
        await _trySet(setProp, 'target-colorspace-hint', 'no');
        break;

      case WindowsQualityPreset.cinemaUltra:
        var appliedScale = 'ewa_lanczossharp';
        if (!anime4kActive) {
          final okEwa = await _trySet(setProp, 'scale', 'ewa_lanczossharp');
          if (_disposed || gen != _qualityOpGen) return false;
          if (!okEwa) {
            appliedScale = 'spline36';
            await _trySet(setProp, 'scale', 'spline36');
            if (_disposed || gen != _qualityOpGen) return false;
          }
          await _trySet(setProp, 'cscale', 'spline36');
          if (_disposed || gen != _qualityOpGen) return false;
        }
        _effectiveScale = appliedScale;
        await _trySet(setProp, 'dscale', 'mitchell');
        if (_disposed || gen != _qualityOpGen) return false;
        await _trySet(setProp, 'correct-downscaling', 'yes');
        await _trySet(setProp, 'linear-downscaling', 'yes');
        await _trySet(setProp, 'sigmoid-upscaling', 'yes');
        await _trySet(setProp, 'dither-depth', 'auto');
        await _trySet(setProp, 'hdr-compute-peak', 'yes');
        await _trySet(setProp, 'hdr-peak-percentile', '99.995');
        await _trySet(setProp, 'deband', 'yes');
        await _trySet(setProp, 'gamut-mapping-mode', 'perceptual');
        if (_disposed || gen != _qualityOpGen) return false;
        _effectiveToneMapping = await _applyToneMappingFallback(setProp);
        if (_disposed || gen != _qualityOpGen) return false;
        await _trySet(setProp, 'target-colorspace-hint', 'yes');
        break;
    }

    if (_disposed || gen != _qualityOpGen) return false;
    _qualityPreset = next;
    if (persist) {
      await _saveQualityPreset(next);
      if (_disposed || gen != _qualityOpGen) return false;
    }
    notifyListeners();
    return true;
  }

  /// Applies [next] audio loudness & vocal dialogue preset to [player].
  Future<bool> applyLoudnessPreset(
    Player player,
    AudioLoudnessPreset next, {
    bool persist = true,
  }) async {
    if (_disposed || !isAvailableForPlayer(player)) return false;
    final setProp = _resolveSetter(player);
    if (setProp == null) return false;
    final gen = ++_loudnessOpGen;

    await _trySet(setProp, 'volume-max', next.volumeMax);
    if (_disposed || gen != _loudnessOpGen) return false;

    if (next == AudioLoudnessPreset.off) {
      await _trySet(setProp, 'af', '');
    } else {
      final ok = await _trySet(setProp, 'af', next.audioFilter);
      if (_disposed || gen != _loudnessOpGen) return false;
      if (!ok && next.audioFilter != fallbackAudioFilter) {
        final fallbackOk = await _trySet(setProp, 'af', fallbackAudioFilter);
        if (_disposed || gen != _loudnessOpGen) return false;
        if (!fallbackOk) {
          await _trySet(setProp, 'af', '');
        }
      }
    }

    if (_disposed || gen != _loudnessOpGen) return false;
    _loudnessPreset = next;
    if (persist) {
      await _saveLoudnessPreset(next);
      if (_disposed || gen != _loudnessOpGen) return false;
    }
    notifyListeners();
    return true;
  }

  Future<String?> _applyToneMappingFallback(
    WindowsMpvPropertySetter setProp,
  ) async {
    for (final candidate in toneMappingFallbackChain) {
      if (_disposed) return null;
      final ok = await _trySet(setProp, 'tone-mapping', candidate);
      if (ok) return candidate;
    }
    return null;
  }

  Future<bool> _trySet(
    WindowsMpvPropertySetter setProp,
    String key,
    String value,
  ) async {
    try {
      await setProp(key, value);
      return true;
    } catch (e) {
      _lastWarning = '$key=$value: $e';
      return false;
    }
  }

  @override
  void dispose() {
    _qualityOpGen++;
    _loudnessOpGen++;
    _disposed = true;
    super.dispose();
  }
}
