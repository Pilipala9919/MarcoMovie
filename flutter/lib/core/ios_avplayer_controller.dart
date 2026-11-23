// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'ohos_runtime.dart';

/// User-selectable iOS playback kernel mode.
enum IosPlaybackEngineMode {
  avPlayer(
    id: 'avplayer',
    labelZh: 'Apple 原生 (AVPlayer 低功耗)',
    shortLabel: 'AVPlayer',
  ),
  mpv(
    id: 'mpv',
    labelZh: 'MPV 全能解码',
    shortLabel: 'MPV',
  );

  final String id;
  final String labelZh;
  final String shortLabel;

  const IosPlaybackEngineMode({
    required this.id,
    required this.labelZh,
    required this.shortLabel,
  });

  static IosPlaybackEngineMode fromId(String? raw) {
    final normalized = (raw ?? '').trim().toLowerCase();
    for (final mode in IosPlaybackEngineMode.values) {
      if (mode.id == normalized) return mode;
    }
    return IosPlaybackEngineMode.avPlayer;
  }
}

/// Device thermal pressure reported by iOS `ProcessInfo.processInfo.thermalState`.
enum IosThermalState {
  nominal(code: 0, wireName: 'nominal', labelZh: '正常'),
  fair(code: 1, wireName: 'fair', labelZh: '轻微升温'),
  serious(code: 2, wireName: 'serious', labelZh: '严重发热'),
  critical(code: 3, wireName: 'critical', labelZh: '临界高温');

  final int code;
  final String wireName;
  final String labelZh;

  const IosThermalState({
    required this.code,
    required this.wireName,
    required this.labelZh,
  });

  bool get isThrottled =>
      this == IosThermalState.serious || this == IosThermalState.critical;

  static IosThermalState fromWire(Object? raw) {
    if (raw is int) {
      for (final state in IosThermalState.values) {
        if (state.code == raw) return state;
      }
    }
    final normalized = (raw?.toString() ?? '').trim().toLowerCase();
    for (final state in IosThermalState.values) {
      if (state.wireName == normalized) return state;
    }
    return IosThermalState.nominal;
  }
}

/// Event emitted when `AVPlayer` cannot handle the stream statically or fails
/// during runtime decoding so the player can seamlessly resume on `libmpv`.
@immutable
class FallbackToMpvRequested {
  final int positionMs;
  final String reason;
  final bool isStaticPrecheck;

  const FallbackToMpvRequested({
    required this.positionMs,
    required this.reason,
    this.isStaticPrecheck = false,
  });

  @override
  String toString() =>
      'FallbackToMpvRequested(positionMs: $positionMs, reason: $reason, isStaticPrecheck: $isStaticPrecheck)';
}

/// Result of static pre-check determining whether `AVPlayer` is suitable.
@immutable
class IosAvPlayerPrecheckResult {
  final bool supported;
  final String? reason;
  final String? detectedExtension;

  const IosAvPlayerPrecheckResult({
    required this.supported,
    this.reason,
    this.detectedExtension,
  });
}

/// Snapshot of device thermal state, RAM capacity, PiP, and AirPlay 2 status.
@immutable
class IosAvPlayerTelemetry {
  final IosThermalState thermalState;
  final int physicalMemoryBytes;
  final bool isPipSupported;
  final bool isPipActive;
  final bool isAirPlayActive;
  final String? airPlayDeviceName;

  const IosAvPlayerTelemetry({
    required this.thermalState,
    required this.physicalMemoryBytes,
    required this.isPipSupported,
    required this.isPipActive,
    required this.isAirPlayActive,
    this.airPlayDeviceName,
  });

  double get physicalMemoryGb =>
      physicalMemoryBytes / (1024.0 * 1024.0 * 1024.0);

  factory IosAvPlayerTelemetry.fromMap(Map<Object?, Object?> map) {
    final memRaw = map['physicalMemoryBytes'];
    final memBytes = memRaw is num ? memRaw.toInt() : 0;
    final devRaw = map['airPlayDeviceName']?.toString().trim() ?? '';
    return IosAvPlayerTelemetry(
      thermalState: IosThermalState.fromWire(
        map['thermalState'] ?? map['thermalStateCode'],
      ),
      physicalMemoryBytes: memBytes,
      isPipSupported: map['isPipSupported'] == true,
      isPipActive: map['isPipActive'] == true,
      isAirPlayActive: map['isAirPlayActive'] == true,
      airPlayDeviceName: devRaw.isEmpty ? null : devRaw,
    );
  }
}

/// Audio or subtitle track reported by `AVMediaSelectionGroup`.
@immutable
class IosAvPlayerTrack {
  final String id;
  final String title;
  final String language;
  final bool selected;

  const IosAvPlayerTrack({
    required this.id,
    required this.title,
    this.language = '',
    this.selected = false,
  });

  factory IosAvPlayerTrack.fromMap(Map<Object?, Object?> map) {
    return IosAvPlayerTrack(
      id: (map['id'] ?? '').toString(),
      title: (map['title'] ?? '').toString(),
      language: (map['language'] ?? '').toString(),
      selected: map['selected'] == true,
    );
  }
}

/// Controller bridging `MarcoAvPlayerEngine.swift` (`AVQueuePlayer` +
/// `AVPlayerLayer` + `AVPictureInPictureController` + AirPlay 2 + thermal
/// telemetry) to Flutter.
class IosAvPlayerController extends ChangeNotifier {
  static const String viewType = 'marco_movie/ios_avplayer_view';
  static const MethodChannel defaultChannel = MethodChannel(
    'marco_movie/ios_avplayer',
  );
  static const EventChannel defaultEventChannel = EventChannel(
    'marco_movie/ios_avplayer_events',
  );

  static const Set<String> incompatibleContainerExtensions = <String>{
    '.mkv',
    '.flv',
    '.avi',
    '.wmv',
    '.rmvb',
    '.rm',
    '.webm',
    '.vob',
    '.ogv',
    '.divx',
    '.asf',
    '.3gp',
  };

  static const Set<String> avPlayerNativeExtensions = <String>{
    '.m3u8',
    '.mp4',
    '.mov',
    '.m4v',
    '.mp3',
    '.aac',
    '.m4a',
  };

  static const Set<String> incompatibleSubtitleExtensions = <String>{
    '.ass',
    '.ssa',
    '.sup',
    '.pgs',
    '.idx',
    '.sub',
  };

  final MethodChannel _channel;
  final EventChannel _eventChannel;
  final TargetPlatform? platformOverride;
  final bool? isOhosOverride;
  final bool? isWebOverride;

  final StreamController<FallbackToMpvRequested> _fallbackCtrl =
      StreamController<FallbackToMpvRequested>.broadcast();
  final StreamController<IosThermalState> _thermalCtrl =
      StreamController<IosThermalState>.broadcast();
  final StreamController<bool> _pipCtrl = StreamController<bool>.broadcast();
  final StreamController<void> _pipRestoreCtrl =
      StreamController<void>.broadcast();
  final StreamController<bool> _airPlayCtrl =
      StreamController<bool>.broadcast();

  StreamSubscription<dynamic>? _eventSub;
  bool _initialized = false;
  bool _disposed = false;
  bool _fallbackEmittedForCurrentItem = false;

  bool _playing = false;
  bool _buffering = false;
  bool _ready = false;
  bool _completed = false;
  bool _hasError = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  Duration _bufferedPosition = Duration.zero;
  double _rate = 1.0;
  double _volume = 1.0;
  int _videoWidth = 0;
  int _videoHeight = 0;
  bool _isHdr = false;
  bool _isPipSupported = false;
  bool _isPipActive = false;
  bool _autoPipEnabled = true;
  bool _isAirPlayActive = false;
  String? _airPlayDeviceName;
  IosThermalState _thermalState = IosThermalState.nominal;
  int _physicalMemoryBytes = 0;
  List<IosAvPlayerTrack> _audioTracks = const <IosAvPlayerTrack>[];
  List<IosAvPlayerTrack> _subtitleTracks = const <IosAvPlayerTrack>[];
  String? _lastError;

  IosAvPlayerController({
    MethodChannel? channelOverride,
    EventChannel? eventChannelOverride,
    this.platformOverride,
    this.isOhosOverride,
    this.isWebOverride,
  })  : _channel = channelOverride ?? defaultChannel,
        _eventChannel = eventChannelOverride ?? defaultEventChannel;

  bool get isSupportedPlatform {
    if (isWebOverride ?? kIsWeb) return false;
    if (isOhosOverride ?? OhosRuntime.isOhos) return false;
    final platform = platformOverride ?? defaultTargetPlatform;
    return platform == TargetPlatform.iOS;
  }

  bool get initialized => _initialized;
  bool get playing => _playing;
  bool get buffering => _buffering;
  bool get ready => _ready;
  bool get completed => _completed;
  bool get hasError => _hasError;
  Duration get position => _position;
  Duration get duration => _duration;
  Duration get bufferedPosition => _bufferedPosition;
  double get rate => _rate;
  double get volume => _volume;
  int get videoWidth => _videoWidth;
  int get videoHeight => _videoHeight;
  bool get isHdr => _isHdr;
  bool get isPipSupported => _isPipSupported;
  bool get isPipActive => _isPipActive;
  bool get autoPipEnabled => _autoPipEnabled;
  bool get isAirPlayActive => _isAirPlayActive;
  String? get airPlayDeviceName => _airPlayDeviceName;
  IosThermalState get thermalState => _thermalState;
  int get physicalMemoryBytes => _physicalMemoryBytes;
  List<IosAvPlayerTrack> get audioTracks => _audioTracks;
  List<IosAvPlayerTrack> get subtitleTracks => _subtitleTracks;
  String? get lastError => _lastError;

  Stream<FallbackToMpvRequested> get onFallbackToMpvRequested =>
      _fallbackCtrl.stream;
  Stream<IosThermalState> get onThermalStateChanged => _thermalCtrl.stream;
  Stream<bool> get onPipStateChanged => _pipCtrl.stream;
  Stream<void> get onPipRestoreForeground => _pipRestoreCtrl.stream;
  Stream<bool> get onAirPlayStateChanged => _airPlayCtrl.stream;

  /// Static pre-check before launching `AVPlayer`.
  ///
  /// Returns `supported: false` when external subtitles contain `.ass`/`.ssa`
  /// (or PGS/VobSub) or when the container format (e.g. `.mkv`, `.flv`,
  /// `.avi`, `.webm`) requires `libmpv` decoding.
  static IosAvPlayerPrecheckResult checkUrlCompatibility(
    String url, {
    String? episodeName,
    String? lineName,
    List<String> externalSubtitles = const <String>[],
  }) {
    for (final sub in externalSubtitles) {
      final subExt = _extractExtension(sub);
      if (subExt != null && incompatibleSubtitleExtensions.contains(subExt)) {
        return IosAvPlayerPrecheckResult(
          supported: false,
          reason: '外挂特效/图形字幕 ($subExt) 需要 libmpv 渲染',
          detectedExtension: subExt,
        );
      }
    }

    final cleanUrl = url.trim();
    if (cleanUrl.isEmpty) {
      return const IosAvPlayerPrecheckResult(
        supported: false,
        reason: '播放地址为空',
      );
    }

    final urlExt = _extractExtension(cleanUrl);
    if (urlExt != null) {
      if (incompatibleContainerExtensions.contains(urlExt)) {
        return IosAvPlayerPrecheckResult(
          supported: false,
          reason: '容器格式 $urlExt 不受系统 AVPlayer 支持，已自动切换 MPV',
          detectedExtension: urlExt,
        );
      }
      if (avPlayerNativeExtensions.contains(urlExt)) {
        return IosAvPlayerPrecheckResult(
          supported: true,
          detectedExtension: urlExt,
        );
      }
    }

    // Check query parameters (e.g. `?format=mkv` or `filename=video.flv`) when
    // the URL path has no explicit media extension.
    final uri = Uri.tryParse(cleanUrl);
    if (uri != null) {
      for (final val in uri.queryParameters.values) {
        final trimmedVal = val.trim().toLowerCase();
        final qExt = _extractExtension(trimmedVal) ??
            (RegExp(r'^[a-z0-9]{2,5}$').hasMatch(trimmedVal)
                ? '.$trimmedVal'
                : null);
        if (qExt != null && incompatibleContainerExtensions.contains(qExt)) {
          return IosAvPlayerPrecheckResult(
            supported: false,
            reason: '流格式参数 $qExt 不受系统 AVPlayer 支持，已自动切换 MPV',
            detectedExtension: qExt,
          );
        }
      }
    }

    // Fall back to episode/line hints only when URL itself had no extension.
    if (urlExt == null) {
      for (final hint in <String?>[episodeName, lineName]) {
        final hintExt = _extractExtension(hint ?? '');
        if (hintExt != null &&
            incompatibleContainerExtensions.contains(hintExt)) {
          return IosAvPlayerPrecheckResult(
            supported: false,
            reason: '片源标识 $hintExt 建议使用 libmpv 解码',
            detectedExtension: hintExt,
          );
        }
      }
    }

    return IosAvPlayerPrecheckResult(
      supported: true,
      detectedExtension: urlExt,
    );
  }

  static String? _extractExtension(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    final parsed = Uri.tryParse(trimmed);
    final path = (parsed?.path.isNotEmpty == true ? parsed!.path : trimmed)
        .split('?')
        .first
        .split('#')
        .first
        .toLowerCase();
    final match = RegExp(r'(\.[a-z0-9]{2,5})$').firstMatch(path);
    return match?.group(1);
  }

  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  Future<void> initialize() async {
    if (_disposed || _initialized) return;
    _initialized = true;

    _channel.setMethodCallHandler(_handleMethodCallback);

    if (isSupportedPlatform) {
      try {
        _eventSub = _eventChannel.receiveBroadcastStream().listen(
          (dynamic event) {
            if (event is Map) {
              handleNativeEvent(Map<Object?, Object?>.from(event));
            }
          },
          onError: (_) {},
        );
      } catch (_) {}
      await refreshTelemetry();
    }
  }

  Future<dynamic> _handleMethodCallback(MethodCall call) async {
    if (_disposed) return null;
    if (call.method == 'onFallbackToMpv' && call.arguments is Map) {
      final args = Map<Object?, Object?>.from(call.arguments as Map);
      handleNativeEvent(<Object?, Object?>{
        'type': 'fallbackToMpv',
        ...args,
      });
    } else if (call.method == 'onPipRestoreForeground') {
      handleNativeEvent(const <Object?, Object?>{'type': 'pipRestoreForeground'});
    } else if (call.method == 'onEvent' && call.arguments is Map) {
      handleNativeEvent(Map<Object?, Object?>.from(call.arguments as Map));
    }
    return null;
  }

  /// Processes a native event map (from EventChannel, MethodChannel, or tests).
  @visibleForTesting
  void handleNativeEvent(Map<Object?, Object?> event) {
    if (_disposed) return;
    final type = event['type']?.toString() ?? '';
    switch (type) {
      case 'telemetry':
        _applyTelemetry(IosAvPlayerTelemetry.fromMap(event));
        _notify();
        break;
      case 'thermalStateChanged':
        final nextThermal = IosThermalState.fromWire(
          event['thermalState'] ?? event['thermalStateCode'],
        );
        if (nextThermal != _thermalState) {
          _thermalState = nextThermal;
          if (!_thermalCtrl.isClosed) _thermalCtrl.add(nextThermal);
          _notify();
        }
        break;
      case 'pipStateChanged':
        final active = event['active'] == true;
        if (event.containsKey('supported')) {
          _isPipSupported = event['supported'] == true;
        }
        if (active != _isPipActive) {
          _isPipActive = active;
          if (!_pipCtrl.isClosed) _pipCtrl.add(active);
          _notify();
        }
        break;
      case 'pipRestoreForeground':
        if (!_pipRestoreCtrl.isClosed) _pipRestoreCtrl.add(null);
        break;
      case 'airPlayStateChanged':
        final active = event['isAirPlayActive'] == true;
        final dev = event['deviceName']?.toString().trim() ?? '';
        final nextName = dev.isEmpty ? null : dev;
        final changed =
            active != _isAirPlayActive || nextName != _airPlayDeviceName;
        _isAirPlayActive = active;
        _airPlayDeviceName = nextName;
        if (changed) {
          if (!_airPlayCtrl.isClosed) _airPlayCtrl.add(active);
          _notify();
        }
        break;
      case 'ready':
        _ready = true;
        _buffering = false;
        _hasError = false;
        _lastError = null;
        _updateMetricsFromMap(event);
        if (event['audioTracks'] is List) {
          _audioTracks = _parseTrackList(event['audioTracks'] as List);
        }
        if (event['subtitleTracks'] is List) {
          _subtitleTracks = _parseTrackList(event['subtitleTracks'] as List);
        }
        _notify();
        break;
      case 'videoSize':
        _updateMetricsFromMap(event);
        _notify();
        break;
      case 'playbackState':
        _playing = event['playing'] == true;
        _buffering = event['buffering'] == true;
        if (event['rate'] is num) {
          final r = (event['rate'] as num).toDouble();
          if (r > 0) _rate = r;
        }
        _updateMetricsFromMap(event);
        _notify();
        break;
      case 'progress':
        _playing = event['playing'] == true;
        _updateMetricsFromMap(event);
        _notify();
        break;
      case 'buffering':
        final nextBuf = event['buffering'] == true;
        if (nextBuf != _buffering) {
          _buffering = nextBuf;
          _notify();
        }
        break;
      case 'completed':
        _playing = false;
        _completed = true;
        _updateMetricsFromMap(event);
        _notify();
        break;
      case 'fallbackToMpv':
        final posMs = (event['positionMs'] is num)
            ? (event['positionMs'] as num).toInt()
            : _position.inMilliseconds;
        final reason = event['reason']?.toString() ?? 'AVPlayer playback failed';
        _playing = false;
        _buffering = false;
        _hasError = true;
        _lastError = reason;
        if (!_fallbackEmittedForCurrentItem && !_fallbackCtrl.isClosed) {
          _fallbackEmittedForCurrentItem = true;
          _fallbackCtrl.add(
            FallbackToMpvRequested(
              positionMs: posMs,
              reason: reason,
              isStaticPrecheck: false,
            ),
          );
        }
        _notify();
        break;
    }
  }

  List<IosAvPlayerTrack> _parseTrackList(List<dynamic> raw) {
    final out = <IosAvPlayerTrack>[];
    for (final entry in raw) {
      if (entry is Map) {
        out.add(IosAvPlayerTrack.fromMap(Map<Object?, Object?>.from(entry)));
      }
    }
    return out;
  }

  void _updateMetricsFromMap(Map<Object?, Object?> map) {
    if (map['positionMs'] is num) {
      _position = Duration(milliseconds: (map['positionMs'] as num).toInt());
    }
    if (map['durationMs'] is num) {
      _duration = Duration(milliseconds: (map['durationMs'] as num).toInt());
    }
    if (map['bufferedMs'] is num) {
      _bufferedPosition =
          Duration(milliseconds: (map['bufferedMs'] as num).toInt());
    }
    if (map['width'] is num) {
      _videoWidth = (map['width'] as num).toInt();
    }
    if (map['height'] is num) {
      _videoHeight = (map['height'] as num).toInt();
    }
    if (map.containsKey('isHdr')) {
      _isHdr = map['isHdr'] == true;
    }
  }

  void _applyTelemetry(IosAvPlayerTelemetry t) {
    _thermalState = t.thermalState;
    if (t.physicalMemoryBytes > 0) {
      _physicalMemoryBytes = t.physicalMemoryBytes;
    }
    _isPipSupported = t.isPipSupported;
    _isPipActive = t.isPipActive;
    _isAirPlayActive = t.isAirPlayActive;
    _airPlayDeviceName = t.airPlayDeviceName;
  }

  /// Opens [url] with custom HTTP [headers] on `AVPlayer`.
  ///
  /// Performs static compatibility pre-check first; if incompatible (`.mkv`,
  /// `.flv`, `.avi`, `.ass`/`.ssa` subtitles), immediately emits
  /// [FallbackToMpvRequested] and returns `false`.
  Future<bool> open(
    String url, {
    Map<String, String> headers = const <String, String>{},
    Duration startPosition = Duration.zero,
    bool autoPlay = true,
    double preferredForwardBufferDuration = 24.0,
    String? episodeName,
    String? lineName,
    List<String> externalSubtitles = const <String>[],
  }) async {
    if (_disposed) return false;
    await initialize();
    _fallbackEmittedForCurrentItem = false;

    final precheck = checkUrlCompatibility(
      url,
      episodeName: episodeName,
      lineName: lineName,
      externalSubtitles: externalSubtitles,
    );
    if (!precheck.supported) {
      final reason = precheck.reason ?? 'AVPlayer 不支持当前格式';
      _lastError = reason;
      if (!_fallbackEmittedForCurrentItem && !_fallbackCtrl.isClosed) {
        _fallbackEmittedForCurrentItem = true;
        _fallbackCtrl.add(
          FallbackToMpvRequested(
            positionMs: startPosition.inMilliseconds,
            reason: reason,
            isStaticPrecheck: true,
          ),
        );
      }
      _notify();
      return false;
    }

    if (!isSupportedPlatform) return false;
    _ready = false;
    _completed = false;
    _hasError = false;
    _lastError = null;
    _position = startPosition;
    _notify();

    try {
      final ok = await _channel.invokeMethod<bool>(
        'open',
        <String, dynamic>{
          'url': url,
          'headers': headers,
          'startPositionMs': startPosition.inMilliseconds,
          'autoPlay': autoPlay,
          'preferredForwardBufferDuration': preferredForwardBufferDuration,
        },
      );
      return ok == true;
    } on MissingPluginException {
      return false;
    } catch (e) {
      _hasError = true;
      _lastError = e.toString();
      if (!_fallbackEmittedForCurrentItem && !_fallbackCtrl.isClosed) {
        _fallbackEmittedForCurrentItem = true;
        _fallbackCtrl.add(
          FallbackToMpvRequested(
            positionMs: startPosition.inMilliseconds,
            reason: e.toString(),
            isStaticPrecheck: false,
          ),
        );
      }
      _notify();
      return false;
    }
  }

  Future<void> play() async {
    if (!isSupportedPlatform || _disposed) return;
    _playing = true;
    _notify();
    try {
      await _channel.invokeMethod<void>('play');
    } on MissingPluginException {
      // Ignore in widget tests without native host.
    } catch (_) {}
  }

  Future<void> pause() async {
    if (!isSupportedPlatform || _disposed) return;
    _playing = false;
    _notify();
    try {
      await _channel.invokeMethod<void>('pause');
    } on MissingPluginException {
      // Ignore in widget tests without native host.
    } catch (_) {}
  }

  Future<void> playOrPause() => _playing ? pause() : play();

  Future<void> seek(Duration target) async {
    if (!isSupportedPlatform || _disposed) return;
    final clampedMs = target.inMilliseconds < 0 ? 0 : target.inMilliseconds;
    _position = Duration(milliseconds: clampedMs);
    _notify();
    try {
      await _channel.invokeMethod<bool>('seek', clampedMs);
    } on MissingPluginException {
      // Ignore in tests.
    } catch (_) {}
  }

  Future<void> setRate(double nextRate) async {
    if (!isSupportedPlatform || _disposed) return;
    _rate = nextRate.clamp(0.25, 4.0);
    _notify();
    try {
      await _channel.invokeMethod<void>('setRate', _rate);
    } on MissingPluginException {
      // Ignore in tests.
    } catch (_) {}
  }

  Future<void> setVolume(double nextVolume) async {
    if (!isSupportedPlatform || _disposed) return;
    _volume = nextVolume.clamp(0.0, 1.0);
    _notify();
    try {
      await _channel.invokeMethod<void>('setVolume', _volume);
    } on MissingPluginException {
      // Ignore in tests.
    } catch (_) {}
  }

  Future<void> setVideoGravity(String gravity) async {
    if (!isSupportedPlatform || _disposed) return;
    try {
      await _channel.invokeMethod<void>('setVideoGravity', gravity);
    } on MissingPluginException {
      // Ignore in tests.
    } catch (_) {}
  }

  Future<bool> startPip() async {
    if (!isSupportedPlatform || _disposed) return false;
    try {
      final ok = await _channel.invokeMethod<bool>('startPip');
      if (ok == true) {
        _isPipActive = true;
        _notify();
      }
      return ok == true;
    } on MissingPluginException {
      return false;
    } catch (_) {
      return false;
    }
  }

  Future<void> stopPip() async {
    if (!isSupportedPlatform || _disposed) return;
    try {
      await _channel.invokeMethod<void>('stopPip');
      _isPipActive = false;
      _notify();
    } on MissingPluginException {
      // Ignore in tests.
    } catch (_) {}
  }

  Future<void> setAutoPip(bool enabled) async {
    _autoPipEnabled = enabled;
    _notify();
    if (!isSupportedPlatform || _disposed) return;
    try {
      await _channel.invokeMethod<void>('setAutoPip', enabled);
    } on MissingPluginException {
      // Ignore in tests.
    } catch (_) {}
  }

  Future<bool> presentAirPlayPicker() async {
    if (!isSupportedPlatform || _disposed) return false;
    try {
      final ok = await _channel.invokeMethod<bool>('presentAirPlayPicker');
      return ok == true;
    } on MissingPluginException {
      return false;
    } catch (_) {
      return false;
    }
  }

  Future<void> setAudioTrack(String trackId) async {
    if (!isSupportedPlatform || _disposed) return;
    try {
      await _channel.invokeMethod<void>('setAudioTrack', trackId);
    } on MissingPluginException {
      // Ignore in tests.
    } catch (_) {}
  }

  Future<void> setSubtitleTrack(String? trackId) async {
    if (!isSupportedPlatform || _disposed) return;
    try {
      await _channel.invokeMethod<void>('setSubtitleTrack', trackId);
    } on MissingPluginException {
      // Ignore in tests.
    } catch (_) {}
  }

  Future<IosAvPlayerTelemetry?> refreshTelemetry() async {
    if (!isSupportedPlatform || _disposed) return null;
    try {
      final raw = await _channel.invokeMapMethod<Object?, Object?>(
        'getTelemetry',
      );
      if (raw == null) return null;
      final telemetry = IosAvPlayerTelemetry.fromMap(raw);
      _applyTelemetry(telemetry);
      _notify();
      return telemetry;
    } on MissingPluginException {
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<void> stop() async {
    _playing = false;
    _buffering = false;
    _notify();
    if (!isSupportedPlatform || _disposed) return;
    try {
      await _channel.invokeMethod<void>('stop');
    } on MissingPluginException {
      // Ignore in tests.
    } catch (_) {}
  }

  /// Renders the native zero-copy `AVPlayerLayer` `UiKitView` on iOS.
  Widget buildView({
    Key? key,
    VoidCallback? onPlatformViewCreated,
  }) {
    if (!isSupportedPlatform) {
      return SizedBox.expand(key: key);
    }
    return UiKitView(
      key: key,
      viewType: viewType,
      creationParams: const <String, dynamic>{},
      creationParamsCodec: const StandardMessageCodec(),
      onPlatformViewCreated: (_) => onPlatformViewCreated?.call(),
    );
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _eventSub?.cancel();
    _eventSub = null;
    _channel.setMethodCallHandler(null);
    _fallbackCtrl.close();
    _thermalCtrl.close();
    _pipCtrl.close();
    _pipRestoreCtrl.close();
    _airPlayCtrl.close();
    super.dispose();
  }
}
