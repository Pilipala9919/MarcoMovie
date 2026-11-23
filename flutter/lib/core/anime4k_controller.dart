// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ios_avplayer_controller.dart';
import 'ohos_runtime.dart';

/// Desktop-only (Windows & macOS) Anime4K GLSL real-time upscaling presets
/// using unmodified MIT-licensed `bloc97/Anime4K v4.0.1` shaders.
enum Anime4kPreset {
  off(
    id: 'off',
    labelZh: '关闭',
    labelEn: 'Off',
    descriptionZh: '默认关闭，Windows 保持低开销 bilinear 采样',
    shaderFiles: <String>[],
  ),
  performance(
    id: 'performance',
    labelZh: '性能',
    labelEn: 'Performance',
    descriptionZh: 'Clamp + Restore_CNN_S（轻度降噪与线条修复）',
    shaderFiles: <String>[
      'Anime4K_Clamp_Highlights.glsl',
      'Anime4K_Restore_CNN_S.glsl',
    ],
  ),
  balanced(
    id: 'balanced',
    labelZh: '均衡',
    labelEn: 'Balanced',
    descriptionZh: 'Clamp + Restore_CNN_M + Upscale_CNN_x2_S（推荐均衡档）',
    shaderFiles: <String>[
      'Anime4K_Clamp_Highlights.glsl',
      'Anime4K_Restore_CNN_M.glsl',
      'Anime4K_Upscale_CNN_x2_S.glsl',
    ],
  ),
  quality(
    id: 'quality',
    labelZh: '画质',
    labelEn: 'Quality',
    descriptionZh: 'Clamp + Restore_CNN_VL + Upscale_CNN_x2_M（高画质超分，较高显卡负载）',
    shaderFiles: <String>[
      'Anime4K_Clamp_Highlights.glsl',
      'Anime4K_Restore_CNN_VL.glsl',
      'Anime4K_Upscale_CNN_x2_M.glsl',
    ],
  );

  final String id;
  final String labelZh;
  final String labelEn;
  final String descriptionZh;
  final List<String> shaderFiles;

  const Anime4kPreset({
    required this.id,
    required this.labelZh,
    required this.labelEn,
    required this.descriptionZh,
    required this.shaderFiles,
  });

  static Anime4kPreset fromId(String? raw) {
    final normalized = (raw ?? '').trim().toLowerCase();
    for (final preset in Anime4kPreset.values) {
      if (preset.id == normalized) return preset;
    }
    return Anime4kPreset.off;
  }
}

typedef Anime4kPropertySetter = Future<void> Function(String key, String value);
typedef Anime4kAssetLoader = Future<ByteData> Function(String assetKey);
typedef Anime4kCacheDirResolver = Future<Directory> Function();
typedef WindowsBaseScalerResolver = ({String scale, String cscale}) Function();

/// Manages desktop-only (Windows & macOS) Anime4K `v4.0.1` shader extraction,
/// SHA-256 verification, libmpv `glsl-shaders` hot-switching, and the Windows
/// scaler restoration contract via [windowsBaseScalerResolver] (defaulting to
/// `bilinear` when no quality controller resolver is injected).
///
/// Strictly disabled and hidden on iOS, iPadOS, Android, Web, HarmonyOS NEXT
/// (`OhosRuntime.isOhos`), and any player whose platform is not [NativePlayer].
class Anime4kController extends ChangeNotifier {
  static const String upstreamTag = 'v4.0.1';
  static const String assetPrefix = 'assets/shaders/anime4k/';
  static const String cacheSubdirName = 'anime4k_v4.0.1';
  static const String prefKeyPreset = 'desktop_anime4k_preset';
  static const String prefKeyIosLightweight = 'ios_anime4k_lightweight';
  static const String iosSinglePassShaderFile =
      'Anime4K_Upscale_CNN_x2_S.glsl';
  static const List<String> iosSinglePassShaderFiles = <String>[
    iosSinglePassShaderFile,
  ];

  /// Pinned SHA-256 digests of the official `bloc97/Anime4K v4.0.1` GLSL files,
  /// matching `flutter/assets/shaders/anime4k/manifest.json`.
  static const Map<String, String> expectedShaderSha256 = <String, String>{
    'Anime4K_Clamp_Highlights.glsl':
        '8c5fb67c76bed3021f8a27b050c3b97a6ac1b284f9ce91c04189015c354c0217',
    'Anime4K_Restore_CNN_S.glsl':
        '97c24dc370ab300c108bfaa09db7f175aeff343674842c299cf3940a3d330427',
    'Anime4K_Restore_CNN_M.glsl':
        '67ea3ed26539e8de3b7d307688535d2ff17e8d147e11dda0247da7770dbecf41',
    'Anime4K_Restore_CNN_VL.glsl':
        '35036722733305cd4d4e57660b883bbe2569ba2914033c254327107d7b77e35e',
    'Anime4K_Upscale_CNN_x2_S.glsl':
        '4c53ec2e287908f7ee7bcb266b0170421626d663576468b7d7dafc62962649a4',
    'Anime4K_Upscale_CNN_x2_M.glsl':
        '716e02098a68f0d648761f2b96b4dd139e1cb09b174bb369fca3aa34328fff7e',
  };

  final TargetPlatform? platformOverride;
  final bool? isOhosOverride;
  final bool? isWebOverride;
  final bool? isNativePlayerOverride;
  final Anime4kCacheDirResolver? cacheDirResolver;
  final Anime4kAssetLoader? assetLoader;
  final Anime4kPropertySetter? propertySetterOverride;
  WindowsBaseScalerResolver? _windowsBaseScalerResolver;
  final bool persistLocally;
  void Function(IosThermalState state)? onThermalAutoDisabled;
  SharedPreferences? _prefs;

  Anime4kPreset _preset = Anime4kPreset.off;
  bool _iosLightweightEnabled = false;
  IosThermalState _thermalState = IosThermalState.nominal;
  StreamSubscription<IosThermalState>? _thermalSub;
  String? _lastError;
  bool _disposed = false;
  int _opGen = 0;

  Anime4kController({
    this.platformOverride,
    this.isOhosOverride,
    this.isWebOverride,
    this.isNativePlayerOverride,
    this.cacheDirResolver,
    this.assetLoader,
    this.propertySetterOverride,
    this.onThermalAutoDisabled,
    WindowsBaseScalerResolver? windowsBaseScalerResolver,
    SharedPreferences? prefs,
    this.persistLocally = true,
  })  : _windowsBaseScalerResolver = windowsBaseScalerResolver,
        _prefs = prefs;

  /// Updates the Windows base scaler resolver used when returning to
  /// [Anime4kPreset.off] (e.g., bound from `WindowsVideoQualityController`).
  void setWindowsBaseScalerResolver(WindowsBaseScalerResolver? resolver) {
    _windowsBaseScalerResolver = resolver;
  }

  ({String scale, String cscale}) _resolveWindowsBaseScalers() {
    final resolved = _windowsBaseScalerResolver?.call();
    final scale = (resolved?.scale ?? '').trim();
    final cscale = (resolved?.cscale ?? '').trim();
    return (
      scale: scale.isNotEmpty ? scale : 'bilinear',
      cscale: cscale.isNotEmpty ? cscale : 'bilinear',
    );
  }

  Anime4kPreset get preset => _preset;
  bool get iosLightweightEnabled => _iosLightweightEnabled;
  IosThermalState get thermalState => _thermalState;
  bool get isThermalThrottled => _thermalState.isThrottled;
  String? get lastError => _lastError;

  /// Only Windows and macOS desktop support full multi-pass Anime4K presets.
  /// Strictly false on iOS, iPadOS, Android, Linux, Web, and HarmonyOS NEXT.
  static bool isSupportedPlatform({
    TargetPlatform? platformOverride,
    bool? isOhosOverride,
    bool? isWebOverride,
  }) {
    if (isOhosOverride ?? OhosRuntime.isOhos) return false;
    if (isWebOverride ?? kIsWeb) return false;
    final platform = platformOverride ?? defaultTargetPlatform;
    return platform == TargetPlatform.windows ||
        platform == TargetPlatform.macOS;
  }

  /// Lightweight single-pass `Anime4K_Upscale_CNN_x2_S.glsl` tier for iOS/iPadOS
  /// Apple Silicon devices, guarded by device thermal telemetry.
  static bool isIosLightweightSupported({
    TargetPlatform? platformOverride,
    bool? isOhosOverride,
    bool? isWebOverride,
  }) {
    if (isOhosOverride ?? OhosRuntime.isOhos) return false;
    if (isWebOverride ?? kIsWeb) return false;
    final platform = platformOverride ?? defaultTargetPlatform;
    return platform == TargetPlatform.iOS;
  }

  /// Platform separator expected by libmpv's `glsl-shaders` option (`;` on
  /// Windows, `:` on macOS/POSIX).
  static String pathSeparatorFor({TargetPlatform? platformOverride}) {
    final platform = platformOverride ?? defaultTargetPlatform;
    return platform == TargetPlatform.windows ? ';' : ':';
  }

  /// Lightweight warning shown when source height exceeds 1080p.
  static bool shouldShowUltraHdWarning(int videoHeight) => videoHeight > 1080;

  static String ultraHdWarningText({bool zh = true}) {
    return zh
        ? '当前已是超清分辨率，开启 Anime4K 会显著增加显卡负载'
        : 'Video is already above 1080p; enabling Anime4K significantly increases GPU load';
  }

  bool get _isWindows =>
      (platformOverride ?? defaultTargetPlatform) == TargetPlatform.windows;

  bool get isPlatformSupported => isSupportedPlatform(
        platformOverride: platformOverride,
        isOhosOverride: isOhosOverride,
        isWebOverride: isWebOverride,
      );

  bool get isIosLightweightPlatformSupported => isIosLightweightSupported(
        platformOverride: platformOverride,
        isOhosOverride: isOhosOverride,
        isWebOverride: isWebOverride,
      );

  /// True only when running on supported desktop OS AND backed by `NativePlayer`.
  bool isAvailableForPlayer(Player player) {
    if (!isPlatformSupported) return false;
    if (isNativePlayerOverride != null) return isNativePlayerOverride!;
    if (propertySetterOverride != null) return true;
    return player.platform is NativePlayer;
  }

  /// True when running on iOS/iPadOS AND backed by `NativePlayer` (libmpv).
  bool isIosLightweightAvailableForPlayer(Player player) {
    if (!isIosLightweightPlatformSupported) return false;
    if (isNativePlayerOverride != null) return isNativePlayerOverride!;
    if (propertySetterOverride != null) return true;
    return player.platform is NativePlayer;
  }

  /// Loads the saved iOS lightweight single-pass toggle.
  Future<bool> loadSavedIosLightweight() async {
    if (!isIosLightweightPlatformSupported || !persistLocally || _disposed) {
      _iosLightweightEnabled = false;
      return false;
    }
    try {
      final sp = _prefs ??= await SharedPreferences.getInstance();
      final saved = sp.getBool(prefKeyIosLightweight) ?? false;
      if (!_disposed && saved != _iosLightweightEnabled) {
        _iosLightweightEnabled = saved;
        notifyListeners();
      }
    } catch (_) {}
    return _iosLightweightEnabled;
  }

  Future<void> _saveIosLightweight(bool enabled) async {
    if (!persistLocally || !isIosLightweightPlatformSupported || _disposed) {
      return;
    }
    try {
      final sp = _prefs ??= await SharedPreferences.getInstance();
      await sp.setBool(prefKeyIosLightweight, enabled);
    } catch (_) {}
  }

  /// Loads the local device-only preset (always [Anime4kPreset.off] when
  /// unsupported or on HarmonyOS NEXT).
  Future<Anime4kPreset> loadSavedPreset() async {
    if (!isPlatformSupported || !persistLocally || _disposed) {
      _preset = Anime4kPreset.off;
      return _preset;
    }
    try {
      final sp = _prefs ??= await SharedPreferences.getInstance();
      final saved = Anime4kPreset.fromId(sp.getString(prefKeyPreset));
      if (!_disposed && saved != _preset) {
        _preset = saved;
        notifyListeners();
      }
    } catch (_) {}
    return _preset;
  }

  Future<void> _savePreset(Anime4kPreset preset) async {
    if (!persistLocally || !isPlatformSupported || _disposed) return;
    try {
      final sp = _prefs ??= await SharedPreferences.getInstance();
      await sp.setString(prefKeyPreset, preset.id);
    } catch (_) {}
  }

  Anime4kPropertySetter? _resolveSetter(Player player) {
    if (propertySetterOverride != null) return propertySetterOverride;
    final platform = player.platform;
    if (platform is NativePlayer) {
      return platform.setProperty;
    }
    return null;
  }

  /// Ensures all shader files for [preset] exist in the app cache directory
  /// and match their pinned `v4.0.1` SHA-256 digests.
  Future<List<String>> ensureCachedShaderPaths(Anime4kPreset preset) async {
    if (preset == Anime4kPreset.off || preset.shaderFiles.isEmpty) {
      return const <String>[];
    }
    return ensureCachedShaderPathsForFiles(preset.shaderFiles);
  }

  /// Extracts and verifies the SHA-256 integrity of [shaderFiles].
  Future<List<String>> ensureCachedShaderPathsForFiles(
    List<String> shaderFiles,
  ) async {
    if (shaderFiles.isEmpty) {
      return const <String>[];
    }
    final rootDir = cacheDirResolver != null
        ? await cacheDirResolver!()
        : await getTemporaryDirectory();
    final targetDir = Directory(
      '${rootDir.path}${Platform.pathSeparator}$cacheSubdirName',
    );
    if (!await targetDir.exists()) {
      await targetDir.create(recursive: true);
    }
    final loader = assetLoader ?? rootBundle.load;
    final resolvedPaths = <String>[];

    for (final fileName in shaderFiles) {
      final expectedHash = expectedShaderSha256[fileName];
      if (expectedHash == null || expectedHash.isEmpty) {
        throw StateError('Unknown Anime4K shader asset: $fileName');
      }
      final file = File('${targetDir.path}${Platform.pathSeparator}$fileName');
      bool validOnDisk = false;
      if (await file.exists()) {
        final existingBytes = await file.readAsBytes();
        if (existingBytes.isNotEmpty &&
            sha256.convert(existingBytes).toString() == expectedHash) {
          validOnDisk = true;
        }
      }
      if (!validOnDisk) {
        final data = await loader('$assetPrefix$fileName');
        final bytes = data.buffer.asUint8List(
          data.offsetInBytes,
          data.lengthInBytes,
        );
        final actualHash = sha256.convert(bytes).toString();
        if (bytes.isEmpty || actualHash != expectedHash) {
          throw StateError(
            'Anime4K shader integrity mismatch for $fileName '
            '(expected $expectedHash, got $actualHash)',
          );
        }
        await file.writeAsBytes(bytes, flush: true);
      }
      resolvedPaths.add(file.path);
    }
    return resolvedPaths;
  }

  /// Hot-switches Anime4K shaders on [player] without restarting playback.
  ///
  /// Windows `bilinear <-> spline36` contract:
  /// - Switching to any non-Off preset on Windows sets `scale=spline36` and
  ///   `cscale=spline36` alongside `glsl-shaders`.
  /// - Switching back to [Anime4kPreset.off] (or falling back on error) clears
  ///   `glsl-shaders=""` and IMMEDIATELY restores `scale=bilinear` and
  ///   `cscale=bilinear` on Windows.
  Future<bool> applyPreset(
    Player player,
    Anime4kPreset next, {
    bool persist = true,
  }) async {
    if (_disposed || !isAvailableForPlayer(player)) return false;
    final setProp = _resolveSetter(player);
    if (setProp == null) return false;
    final gen = ++_opGen;

    if (next == Anime4kPreset.off) {
      await _applyOffLocked(setProp);
      if (_disposed || gen != _opGen) return false;
      _preset = Anime4kPreset.off;
      _lastError = null;
      if (persist) {
        await _savePreset(Anime4kPreset.off);
        if (_disposed || gen != _opGen) return false;
      }
      notifyListeners();
      return true;
    }

    try {
      final paths = await ensureCachedShaderPaths(next);
      if (_disposed || gen != _opGen) return false;
      final sep = pathSeparatorFor(platformOverride: platformOverride);
      final joined = paths.join(sep);
      if (_isWindows) {
        await setProp('scale', 'spline36');
        if (_disposed || gen != _opGen) return false;
        await setProp('cscale', 'spline36');
        if (_disposed || gen != _opGen) return false;
      }
      await setProp('glsl-shaders', joined);
      if (_disposed || gen != _opGen) return false;
      _preset = next;
      _lastError = null;
      if (persist) {
        await _savePreset(next);
        if (_disposed || gen != _opGen) return false;
      }
      notifyListeners();
      return true;
    } catch (e) {
      if (_disposed || gen != _opGen) return false;
      _lastError = e.toString();
      await _applyOffLocked(setProp);
      if (_disposed || gen != _opGen) return false;
      _preset = Anime4kPreset.off;
      if (persist) {
        await _savePreset(Anime4kPreset.off);
        if (_disposed || gen != _opGen) return false;
      }
      notifyListeners();
      return false;
    }
  }

  /// Re-applies the active preset after kernel reconfiguration (keeping Windows
  /// on `bilinear` when [preset] is [Anime4kPreset.off], or upgrading to
  /// `spline36` + shaders when non-Off).
  Future<void> reapplyActivePreset(Player player) async {
    if (_disposed || !isAvailableForPlayer(player)) return;
    if (_preset == Anime4kPreset.off) {
      final setProp = _resolveSetter(player);
      if (setProp != null) {
        await _applyOffLocked(setProp);
      }
      return;
    }
    await applyPreset(player, _preset, persist: false);
  }

  /// Enables or disables iOS single-pass `Anime4K_Upscale_CNN_x2_S.glsl`
  /// super-resolution on [player] with Apple Silicon thermal guard.
  Future<bool> setIosLightweightEnabled(
    Player player,
    bool enabled, {
    bool persist = true,
  }) async {
    if (_disposed || !isIosLightweightAvailableForPlayer(player)) return false;
    final setProp = _resolveSetter(player);
    if (setProp == null) return false;
    final gen = ++_opGen;

    if (!enabled) {
      await _applyOffLocked(setProp);
      if (_disposed || gen != _opGen) return false;
      _iosLightweightEnabled = false;
      _lastError = null;
      if (persist) {
        await _saveIosLightweight(false);
        if (_disposed || gen != _opGen) return false;
      }
      notifyListeners();
      return true;
    }

    if (_thermalState.isThrottled) {
      await _applyOffLocked(setProp);
      if (_disposed || gen != _opGen) return false;
      _iosLightweightEnabled = false;
      _lastError = '设备温度过高（${_thermalState.labelZh}），已限制开启 Anime4K 超分';
      notifyListeners();
      onThermalAutoDisabled?.call(_thermalState);
      return false;
    }

    try {
      final paths =
          await ensureCachedShaderPathsForFiles(iosSinglePassShaderFiles);
      if (_disposed || gen != _opGen) return false;
      if (_thermalState.isThrottled) {
        await _applyOffLocked(setProp);
        if (_disposed || gen != _opGen) return false;
        _iosLightweightEnabled = false;
        _lastError = '设备温度过高（${_thermalState.labelZh}），已限制开启 Anime4K 超分';
        notifyListeners();
        onThermalAutoDisabled?.call(_thermalState);
        return false;
      }
      await setProp('glsl-shaders', paths.single);
      if (_disposed || gen != _opGen) return false;
      _iosLightweightEnabled = true;
      _lastError = null;
      if (persist) {
        await _saveIosLightweight(true);
        if (_disposed || gen != _opGen) return false;
      }
      notifyListeners();
      return true;
    } catch (e) {
      if (_disposed || gen != _opGen) return false;
      _lastError = e.toString();
      await _applyOffLocked(setProp);
      if (_disposed || gen != _opGen) return false;
      _iosLightweightEnabled = false;
      if (persist) {
        await _saveIosLightweight(false);
        if (_disposed || gen != _opGen) return false;
      }
      notifyListeners();
      return false;
    }
  }

  /// Re-applies the active iOS lightweight single-pass shader when not throttled.
  Future<void> reapplyIosLightweight(Player player) async {
    if (_disposed || !isIosLightweightAvailableForPlayer(player)) return;
    if (!_iosLightweightEnabled || _thermalState.isThrottled) {
      final setProp = _resolveSetter(player);
      if (setProp != null) {
        await _applyOffLocked(setProp);
      }
      if (_iosLightweightEnabled && _thermalState.isThrottled) {
        _iosLightweightEnabled = false;
        notifyListeners();
        onThermalAutoDisabled?.call(_thermalState);
      }
      return;
    }
    await setIosLightweightEnabled(player, true, persist: false);
  }

  /// Responds to iOS `ProcessInfo.thermalStateDidChangeNotification` updates.
  ///
  /// When the device enters `.serious` or `.critical`, immediately clears any
  /// active Anime4K GLSL shaders and invokes [onThermalAutoDisabled].
  Future<void> handleThermalState(
    Player player,
    IosThermalState nextState,
  ) async {
    if (_disposed) return;
    final stateChanged = _thermalState != nextState;
    _thermalState = nextState;

    if (nextState.isThrottled &&
        (_iosLightweightEnabled || _preset != Anime4kPreset.off)) {
      _opGen++;
      final setProp = _resolveSetter(player);
      if (setProp != null) {
        await _applyOffLocked(setProp);
      }
      if (_disposed) return;
      _iosLightweightEnabled = false;
      _preset = Anime4kPreset.off;
      _lastError = '设备温度过高（${nextState.labelZh}），已自动关闭 Anime4K 超分';
      notifyListeners();
      onThermalAutoDisabled?.call(nextState);
      return;
    }

    if (stateChanged) {
      notifyListeners();
    }
  }

  /// Binds a live [IosThermalState] stream (such as
  /// `IosAvPlayerController.onThermalStateChanged`) so thermal pressure
  /// automatically disables active shaders on [player].
  void bindThermalStream(Player player, Stream<IosThermalState> stream) {
    _thermalSub?.cancel();
    _thermalSub = stream.listen((state) {
      unawaited(handleThermalState(player, state));
    });
  }

  Future<void> unbindThermalStream() async {
    await _thermalSub?.cancel();
    _thermalSub = null;
  }

  /// Resets the current playback session back to Off (`glsl-shaders=""` and
  /// Windows `scale=bilinear` / `cscale=bilinear`) without touching saved prefs.
  Future<void> resetSession(Player player) async {
    if (_disposed) return;
    final desktopAvail = isAvailableForPlayer(player);
    final iosAvail = isIosLightweightAvailableForPlayer(player);
    if (!desktopAvail && !iosAvail) return;
    final gen = ++_opGen;
    final setProp = _resolveSetter(player);
    if (setProp != null) {
      await _applyOffLocked(setProp);
    }
    if (_disposed || gen != _opGen) return;
    _preset = Anime4kPreset.off;
    _iosLightweightEnabled = false;
    notifyListeners();
  }

  Future<void> _applyOffLocked(Anime4kPropertySetter setProp) async {
    try {
      await setProp('glsl-shaders', '');
    } catch (_) {}
    if (_isWindows) {
      final base = _resolveWindowsBaseScalers();
      try {
        await setProp('scale', base.scale);
      } catch (_) {}
      try {
        await setProp('cscale', base.cscale);
      } catch (_) {}
    }
  }

  @override
  void dispose() {
    _opGen++;
    _disposed = true;
    _thermalSub?.cancel();
    _thermalSub = null;
    super.dispose();
  }
}
