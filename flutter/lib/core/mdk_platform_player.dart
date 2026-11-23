// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:fvp/fvp.dart' as fvp;
import 'package:fvp/mdk.dart' as mdk;
import 'package:media_kit/media_kit.dart';

import 'ohos_runtime.dart';

/// User-selectable Windows desktop playback engine.
///
/// - [mpv]: `media_kit` (`libmpv`) pipeline with Anime4K real-time shaders,
///   custom HDR tone-mapping, and `dynaudnorm` vocal loudness filters.
/// - [mdk]: `libmdk` (`fvp`) native Direct3D 11 / MFT / DXVA zero-copy hardware
///   decoder & renderer, specifically tuned for Intel/AMD integrated GPUs (`核显`)
///   and thin-and-light Windows laptops.
enum WindowsPlaybackEngine {
  mpv(
    id: 'mpv',
    labelZh: 'MPV 旗舰画质（libmpv）',
    shortLabel: 'MPV',
    descriptionZh:
        '支持 Anime4K 实时超分、自定义 HDR 色调映射与人声响度增强，适合独立显卡与进阶画质调校',
  ),
  mdk(
    id: 'mdk',
    labelZh: 'MDK 核显兼容（推荐核显）',
    shortLabel: 'MDK',
    descriptionZh:
        '原生 D3D11 / MFT / DXVA 零拷贝硬件解码，GPU 与显存占用极低，专为 Intel/AMD 核显及老显卡流畅播放 4K/HDR 优化',
  );

  static const String prefKey = 'windows_playback_engine';

  final String id;
  final String labelZh;
  final String shortLabel;
  final String descriptionZh;

  const WindowsPlaybackEngine({
    required this.id,
    required this.labelZh,
    required this.shortLabel,
    required this.descriptionZh,
  });

  static WindowsPlaybackEngine fromId(String? raw) {
    final normalized = (raw ?? '').trim().toLowerCase();
    if (normalized == 'mdk' || normalized == 'fvp') {
      return WindowsPlaybackEngine.mdk;
    }
    return WindowsPlaybackEngine.mpv;
  }
}

/// Snapshot of MDK media metadata abstracted for deterministic unit testing.
class MdkMediaSnapshot {
  final int durationMs;
  final int videoWidth;
  final int videoHeight;
  final List<VideoTrack> videoTracks;
  final List<AudioTrack> audioTracks;
  final List<SubtitleTrack> subtitleTracks;

  const MdkMediaSnapshot({
    this.durationMs = 0,
    this.videoWidth = 0,
    this.videoHeight = 0,
    this.videoTracks = const <VideoTrack>[],
    this.audioTracks = const <AudioTrack>[],
    this.subtitleTracks = const <SubtitleTrack>[],
  });
}

/// Abstract native backend interface wrapping `fvp/mdk.dart`'s [mdk.Player] so
/// [MdkPlatformPlayer] can be thoroughly tested without a live D3D11 GPU.
abstract class MdkNativeBackend {
  ValueListenable<int?> get textureIdListenable;
  Stream<({int oldStatus, int newStatus})> get onStatusChanged;
  Stream<mdk.PlaybackState> get onStateChanged;
  Stream<({int error, String category, String detail})> get onEvent;

  int get positionMs;
  int get bufferedMs;
  bool get isLive;
  MdkMediaSnapshot readMediaSnapshot();

  set media(String uri);
  set state(mdk.PlaybackState value);
  set playbackRate(double value);
  set volume(double value);
  set mute(bool value);
  set loop(int value);
  set videoDecoders(List<String> decoders);
  set activeAudioTracks(List<int> tracks);
  set activeSubtitleTracks(List<int> tracks);
  set activeVideoTracks(List<int> tracks);

  void setProperty(String key, String value);
  void setBufferRange({int min = -1, int max = -1, bool drop = false});
  void setMediaForType(String uri, mdk.MediaType type);
  Future<int> prepare({int position = 0});
  Future<int> seek({required int position, required mdk.SeekFlag flags});
  Future<int> updateTexture({int? width, int? height});
  Future<void> disposeAsync();
}

class _RealMdkNativeBackend implements MdkNativeBackend {
  final mdk.Player _inner = mdk.Player();
  final StreamController<({int oldStatus, int newStatus})> _statusCtl =
      StreamController<({int oldStatus, int newStatus})>.broadcast();
  final StreamController<mdk.PlaybackState> _stateCtl =
      StreamController<mdk.PlaybackState>.broadcast();
  final StreamController<({int error, String category, String detail})>
      _eventCtl = StreamController<
          ({int error, String category, String detail})>.broadcast();
  late final StreamSubscription<dynamic> _statusSub;
  late final StreamSubscription<dynamic> _stateSub;
  late final StreamSubscription<dynamic> _eventSub;
  bool _disposed = false;

  _RealMdkNativeBackend() {
    _statusSub = _inner.onMediaStatus.listen((ev) {
      if (!_statusCtl.isClosed) {
        _statusCtl.add((
          oldStatus: ev.oldValue.rawValue,
          newStatus: ev.newValue.rawValue,
        ));
      }
    });
    _stateSub = _inner.onStateChanged.listen((ev) {
      if (!_stateCtl.isClosed) {
        _stateCtl.add(ev.newValue);
      }
    });
    _eventSub = _inner.onEvent.listen((ev) {
      if (!_eventCtl.isClosed) {
        _eventCtl.add((
          error: ev.error,
          category: ev.category,
          detail: ev.detail,
        ));
      }
    });
  }

  @override
  ValueListenable<int?> get textureIdListenable => _inner.textureId;

  @override
  Stream<({int oldStatus, int newStatus})> get onStatusChanged =>
      _statusCtl.stream;

  @override
  Stream<mdk.PlaybackState> get onStateChanged => _stateCtl.stream;

  @override
  Stream<({int error, String category, String detail})> get onEvent =>
      _eventCtl.stream;

  @override
  int get positionMs => _disposed ? 0 : _inner.position;

  @override
  int get bufferedMs => _disposed ? 0 : _inner.buffered();

  @override
  bool get isLive => _disposed ? false : _inner.isLive;

  @override
  MdkMediaSnapshot readMediaSnapshot() {
    if (_disposed) return const MdkMediaSnapshot();
    final info = _inner.mediaInfo;
    int width = 0;
    int height = 0;
    final videoTracks = <VideoTrack>[VideoTrack.auto()];
    final rawVideos = info.video ?? const <mdk.VideoStreamInfo>[];
    for (int i = 0; i < rawVideos.length; i++) {
      final v = rawVideos[i];
      final w = v.codec.width;
      final h = v.codec.height;
      final rotated = v.rotation == 90 || v.rotation == 270;
      final displayW = rotated ? h : w;
      final displayH = rotated ? w : h;
      if (width <= 0 && displayW > 0 && displayH > 0) {
        width = displayW;
        height = displayH;
      }
      final title = (v.metadata['title'] ?? '').trim();
      final lang = (v.metadata['language'] ?? '').trim();
      final codec = v.codec.codec.trim();
      videoTracks.add(
        VideoTrack(
          '$i',
          title.isNotEmpty ? title : 'Video ${i + 1}',
          lang.isNotEmpty ? lang : null,
          codec: codec.isNotEmpty ? codec : null,
          w: displayW > 0 ? displayW : null,
          h: displayH > 0 ? displayH : null,
        ),
      );
    }

    final audioTracks = <AudioTrack>[AudioTrack.auto()];
    final rawAudios = info.audio ?? const <mdk.AudioStreamInfo>[];
    for (int i = 0; i < rawAudios.length; i++) {
      final a = rawAudios[i];
      final title = (a.metadata['title'] ?? '').trim();
      final lang = (a.metadata['language'] ?? '').trim();
      final codec = a.codec.codec.trim();
      final channels = a.codec.channels > 0 ? '${a.codec.channels}ch' : null;
      audioTracks.add(
        AudioTrack(
          '$i',
          title.isNotEmpty ? title : (lang.isNotEmpty ? lang : '音轨 ${i + 1}'),
          lang.isNotEmpty ? lang : null,
          codec: codec.isNotEmpty ? codec : null,
          channels: channels,
        ),
      );
    }

    final subtitleTracks = <SubtitleTrack>[
      SubtitleTrack.auto(),
      SubtitleTrack.no(),
    ];
    final rawSubs = info.subtitle ?? const <mdk.SubtitleStreamInfo>[];
    for (int i = 0; i < rawSubs.length; i++) {
      final s = rawSubs[i];
      final title = (s.metadata['title'] ?? '').trim();
      final lang = (s.metadata['language'] ?? '').trim();
      final codec = s.codec.codec.trim();
      subtitleTracks.add(
        SubtitleTrack(
          '$i',
          title.isNotEmpty ? title : (lang.isNotEmpty ? lang : '字幕 ${i + 1}'),
          lang.isNotEmpty ? lang : null,
          codec: codec.isNotEmpty ? codec : null,
        ),
      );
    }

    return MdkMediaSnapshot(
      durationMs: math.max(0, info.duration),
      videoWidth: width,
      videoHeight: height,
      videoTracks: videoTracks,
      audioTracks: audioTracks,
      subtitleTracks: subtitleTracks,
    );
  }

  @override
  set media(String uri) {
    if (!_disposed) _inner.media = uri;
  }

  @override
  set state(mdk.PlaybackState value) {
    if (!_disposed) _inner.state = value;
  }

  @override
  set playbackRate(double value) {
    if (!_disposed) _inner.playbackRate = value;
  }

  @override
  set volume(double value) {
    if (!_disposed) _inner.volume = value;
  }

  @override
  set mute(bool value) {
    if (!_disposed) _inner.mute = value;
  }

  @override
  set loop(int value) {
    if (!_disposed) _inner.loop = value;
  }

  @override
  set videoDecoders(List<String> decoders) {
    if (!_disposed) _inner.videoDecoders = decoders;
  }

  @override
  set activeAudioTracks(List<int> tracks) {
    if (!_disposed) _inner.activeAudioTracks = tracks;
  }

  @override
  set activeSubtitleTracks(List<int> tracks) {
    if (!_disposed) _inner.activeSubtitleTracks = tracks;
  }

  @override
  set activeVideoTracks(List<int> tracks) {
    if (!_disposed) _inner.activeVideoTracks = tracks;
  }

  @override
  void setProperty(String key, String value) {
    if (!_disposed) _inner.setProperty(key, value);
  }

  @override
  void setBufferRange({int min = -1, int max = -1, bool drop = false}) {
    if (!_disposed) _inner.setBufferRange(min: min, max: max, drop: drop);
  }

  @override
  void setMediaForType(String uri, mdk.MediaType type) {
    if (!_disposed) _inner.setMedia(uri, type);
  }

  @override
  Future<int> prepare({int position = 0}) {
    if (_disposed) return Future<int>.value(-10);
    return _inner.prepare(position: position);
  }

  @override
  Future<int> seek({required int position, required mdk.SeekFlag flags}) {
    if (_disposed) return Future<int>.value(-10);
    return _inner.seek(position: position, flags: flags);
  }

  @override
  Future<int> updateTexture({int? width, int? height}) {
    if (_disposed) return Future<int>.value(-1);
    return _inner.updateTexture(width: width, height: height);
  }

  @override
  Future<void> disposeAsync() async {
    if (_disposed) return;
    _disposed = true;
    await _statusSub.cancel();
    await _stateSub.cancel();
    await _eventSub.cancel();
    await _statusCtl.close();
    await _stateCtl.close();
    await _eventCtl.close();
    await _inner.disposeAsync();
  }
}

/// Windows `libmdk` (`fvp`) implementation of `media_kit`'s [PlatformPlayer].
///
/// Renders frames zero-copy through Flutter's GPU `TextureRegistry` via D3D11 /
/// MFT / DXVA hardware decoders, tuned specifically for Intel UHD / Iris Xe /
/// older Intel HD and AMD Radeon integrated GPUs (`核显`) so 4K/HDR & netdisk
/// streams play smoothly with low GPU/CPU footprint and full compatibility with
/// PlayerScreen (danmu, seek, speed, tracks, subtitles, resume, live streams).
class MdkPlatformPlayer extends PlatformPlayer {
  /// Default Windows decoder priority tuned for integrated GPUs (`核显`) first
  /// (MFT D3D11 -> FFmpeg D3D11VA -> DXVA2 for older iGPUs -> CUDA -> CPU/AV1).
  static const List<String> defaultIgpuDecoders = <String>[
    'MFT:d3d=11',
    'D3D11',
    'DXVA',
    'CUDA',
    'FFmpeg',
    'dav1d',
  ];

  /// Compatibility decoder priority for older Intel HD 4000–620 / older AMD APU
  /// drivers where DXVA2 / D3D11 copy path avoids SRV driver crashes.
  static const List<String> legacyIgpuCompatDecoders = <String>[
    'DXVA',
    'D3D11',
    'MFT:d3d=11',
    'FFmpeg',
    'dav1d',
  ];

  static bool _globalInitialized = false;

  /// Resolves the decoder priority list for the user's playback strategy.
  static List<String> decodersForKernelStrategy(String kernelStrategy) {
    if (kernelStrategy.trim().toLowerCase() == 'ijk') {
      return legacyIgpuCompatDecoders;
    }
    return defaultIgpuDecoders;
  }

  static String _resolveWindowsSubtitleFont() {
    if (kIsWeb || !Platform.isWindows) return '';
    const candidates = <String>[
      r'C:\Windows\Fonts\msyh.ttc',
      r'C:\Windows\Fonts\msyh.ttf',
      r'C:\Windows\Fonts\simhei.ttf',
      r'C:\Windows\Fonts\simsun.ttc',
    ];
    for (final path in candidates) {
      try {
        if (File(path).existsSync()) return path;
      } catch (_) {}
    }
    return '';
  }

  /// Idempotently initializes `fvp` / `libmdk` global options on Windows
  /// (activating bundled MDK key, `d3d11.sync.cpu=1` for smooth iGPU texture
  /// sync, and Windows CJK subtitle font fallback).
  static void ensureInitialized() {
    if (_globalInitialized ||
        kIsWeb ||
        OhosRuntime.isOhos ||
        !Platform.isWindows ||
        Platform.environment.containsKey('FLUTTER_TEST')) {
      return;
    }
    _globalInitialized = true;
    try {
      final fontPath = _resolveWindowsSubtitleFont();
      fvp.registerWith(
        options: <String, dynamic>{
          'platforms': <String>['windows'],
          'fastSeek': true,
          'video.decoders': defaultIgpuDecoders,
          'global': <String, Object>{
            'd3d11.sync.cpu': 1,
            'log': 'warning',
            if (fontPath.isNotEmpty) 'subtitle.fonts.file': fontPath,
          },
        },
      );
    } catch (e) {
      debugPrint('MdkPlatformPlayer.ensureInitialized warning: $e');
    }
  }

  final MdkNativeBackend _backend;
  final Map<String, String> _properties = <String, String>{};
  final String _initialKernelStrategy;
  StreamSubscription<({int oldStatus, int newStatus})>? _statusSub;
  StreamSubscription<mdk.PlaybackState>? _stateSub;
  StreamSubscription<({int error, String category, String detail})>? _eventSub;
  Timer? _positionTimer;
  int _openGeneration = 0;
  bool _disposed = false;
  bool _isLiveHint = false;
  String _activeVideoDecoderName = '';

  MdkPlatformPlayer({
    super.configuration = const PlayerConfiguration(),
    String kernelStrategy = 'exo',
    MdkNativeBackend? debugBackend,
  })  : _initialKernelStrategy = kernelStrategy,
        _backend = debugBackend ?? _createRealBackend() {
    _configureBaselineProperties(_initialKernelStrategy);
    _attachBackendListeners();
    configuration.ready?.call();
  }

  static MdkNativeBackend _createRealBackend() {
    ensureInitialized();
    return _RealMdkNativeBackend();
  }

  ValueListenable<int?> get textureIdListenable => _backend.textureIdListenable;
  int? get textureId => _backend.textureIdListenable.value;
  String get activeVideoDecoderName => _activeVideoDecoderName;
  Map<String, String> get properties =>
      Map<String, String>.unmodifiable(_properties);

  void _configureBaselineProperties(String kernelStrategy) {
    _backend.videoDecoders = decodersForKernelStrategy(kernelStrategy);
    // Crucial for Intel/AMD iGPU drivers: avoid D3D11 SRV format mismatch.
    _backend.setProperty('video.decoder', 'shader_resource=0');
    _backend.setProperty('keep_open', '1');
    _backend.setProperty('avformat.strict', 'experimental');
    _backend.setProperty('avformat.safe', '0');
    _backend.setProperty('avformat.extension_picky', '0');
    _backend.setProperty('avformat.allowed_segment_extensions', 'ALL');
    _backend.setProperty('avformat.rtsp_transport', 'tcp');
    _backend.setProperty('avio.reconnect', '1');
    _backend.setProperty('avio.reconnect_streamed', '1');
    _backend.setProperty('avio.reconnect_on_network_error', '1');
    _backend.setProperty('avio.reconnect_delay_max', '7');
    _backend.setProperty(
      'avio.protocol_whitelist',
      'file,ftp,rtmp,http,https,tls,rtp,tcp,udp,crypto,httpproxy,data,concatf,concat,subfile',
    );
    _applyBufferPolicy(kernelStrategy: kernelStrategy, isLive: _isLiveHint);
  }

  void _applyBufferPolicy({
    required String kernelStrategy,
    required bool isLive,
  }) {
    if (isLive) {
      _backend.setBufferRange(min: 500, max: 3000, drop: true);
      _backend.setProperty('avformat.analyzeduration', '1000000');
      _backend.setProperty('avformat.probesize', '1000000');
      return;
    }
    switch (kernelStrategy.trim().toLowerCase()) {
      case 'mpv':
        _backend.setBufferRange(min: 2000, max: 32000, drop: false);
        break;
      case 'ijk':
        _backend.setBufferRange(min: 2000, max: 20000, drop: false);
        break;
      default:
        _backend.setBufferRange(min: 1500, max: 16000, drop: false);
        break;
    }
  }

  void _attachBackendListeners() {
    _statusSub = _backend.onStatusChanged.listen((ev) {
      if (_disposed) return;
      final oldS = mdk.MediaStatus(ev.oldStatus);
      final newS = mdk.MediaStatus(ev.newStatus);

      if (!oldS.test(mdk.MediaStatus.loaded) &&
          newS.test(mdk.MediaStatus.loaded)) {
        _syncMediaSnapshot();
        unawaited(_refreshTextureSafely());
      }

      final nowBuffering = newS.test(mdk.MediaStatus.buffering) ||
          newS.test(mdk.MediaStatus.stalled);
      final wasBuffering = oldS.test(mdk.MediaStatus.buffering) ||
          oldS.test(mdk.MediaStatus.stalled);
      if (nowBuffering != wasBuffering) {
        state = state.copyWith(buffering: nowBuffering);
        bufferingController.add(nowBuffering);
      } else if (newS.test(mdk.MediaStatus.buffered) && state.buffering) {
        state = state.copyWith(buffering: false);
        bufferingController.add(false);
      }

      if (!oldS.test(mdk.MediaStatus.end) &&
          newS.test(mdk.MediaStatus.end) &&
          !newS.test(mdk.MediaStatus.seeking)) {
        _stopPositionTimer();
        state = state.copyWith(
          playing: false,
          buffering: false,
          completed: true,
        );
        playingController.add(false);
        bufferingController.add(false);
        completedController.add(true);
      }

      if (!oldS.test(mdk.MediaStatus.invalid) &&
          newS.test(mdk.MediaStatus.invalid)) {
        _stopPositionTimer();
        state = state.copyWith(playing: false, buffering: false);
        playingController.add(false);
        bufferingController.add(false);
        errorController.add('MDK failed to open or decode media stream');
      }
    });

    _stateSub = _backend.onStateChanged.listen((nextState) {
      if (_disposed) return;
      final playing = nextState == mdk.PlaybackState.playing;
      if (playing) {
        _startPositionTimer();
      } else {
        _stopPositionTimer();
      }
      if (state.playing != playing) {
        state = state.copyWith(
          playing: playing,
          completed: playing ? false : state.completed,
        );
        playingController.add(playing);
      }
    });

    _eventSub = _backend.onEvent.listen((ev) {
      if (_disposed) return;
      if (ev.category == 'decoder.video' && ev.detail.isNotEmpty) {
        _activeVideoDecoderName = ev.detail;
        _syncMediaSnapshot();
      } else if (ev.category == 'reader.buffering') {
        _emitPositionAndBuffer();
      } else if (ev.error < 0 &&
          (ev.category == 'reader.open' ||
              ev.category == 'decoder.video' ||
              ev.category == 'reader.read')) {
        final detail = ev.detail.trim();
        errorController.add(
          detail.isNotEmpty
              ? 'MDK ${ev.category}: $detail (${ev.error})'
              : 'MDK failed to open stream (${ev.category}: ${ev.error})',
        );
      }
    });
  }

  Future<void> _refreshTextureSafely() async {
    if (_disposed) return;
    try {
      await _backend.updateTexture();
    } catch (e) {
      debugPrint('MdkPlatformPlayer updateTexture warning: $e');
    }
  }

  void _syncMediaSnapshot() {
    if (_disposed) return;
    final snap = _backend.readMediaSnapshot();
    if (snap.durationMs > 0) {
      final dur = Duration(milliseconds: snap.durationMs);
      if (state.duration != dur) {
        state = state.copyWith(duration: dur);
        durationController.add(dur);
      }
    }
    if (snap.videoWidth > 0 && snap.videoHeight > 0) {
      if (state.width != snap.videoWidth || state.height != snap.videoHeight) {
        state = state.copyWith(
          width: snap.videoWidth,
          height: snap.videoHeight,
        );
        widthController.add(snap.videoWidth);
        heightController.add(snap.videoHeight);
      }
    }
    if (snap.videoTracks.isNotEmpty ||
        snap.audioTracks.isNotEmpty ||
        snap.subtitleTracks.isNotEmpty) {
      final nextTracks = Tracks(
        video: snap.videoTracks.isNotEmpty
            ? snap.videoTracks
            : <VideoTrack>[VideoTrack.auto()],
        audio: snap.audioTracks.isNotEmpty
            ? snap.audioTracks
            : <AudioTrack>[AudioTrack.auto()],
        subtitle: snap.subtitleTracks.isNotEmpty
            ? snap.subtitleTracks
            : <SubtitleTrack>[SubtitleTrack.auto(), SubtitleTrack.no()],
      );
      final activeVideo = nextTracks.video.length > 1
          ? nextTracks.video[1]
          : VideoTrack.auto();
      final activeAudio = nextTracks.audio.length > 1
          ? nextTracks.audio[1]
          : AudioTrack.auto();
      final activeSub = nextTracks.subtitle.length > 2
          ? nextTracks.subtitle[2]
          : state.track.subtitle;
      final nextTrack = Track(
        video: activeVideo,
        audio: activeAudio,
        subtitle: activeSub,
      );
      state = state.copyWith(tracks: nextTracks, track: nextTrack);
      tracksController.add(nextTracks);
      trackController.add(nextTrack);
    }
  }

  void _startPositionTimer() {
    if (_disposed) return;
    if (_positionTimer?.isActive ?? false) return;
    _positionTimer = Timer.periodic(
      const Duration(milliseconds: 120),
      (_) => _emitPositionAndBuffer(),
    );
  }

  void _stopPositionTimer() {
    _positionTimer?.cancel();
    _positionTimer = null;
  }

  void _emitPositionAndBuffer() {
    if (_disposed) return;
    final posMs = math.max(0, _backend.positionMs);
    final bufDeltaMs = math.max(0, _backend.bufferedMs);
    final pos = Duration(milliseconds: posMs);
    final buf = Duration(milliseconds: posMs + bufDeltaMs);
    state = state.copyWith(position: pos, buffer: buf);
    positionController.add(pos);
    bufferController.add(buf);
    if (state.duration <= Duration.zero && !_backend.isLive) {
      final snap = _backend.readMediaSnapshot();
      if (snap.durationMs > 0) {
        final dur = Duration(milliseconds: snap.durationMs);
        state = state.copyWith(duration: dur);
        durationController.add(dur);
      }
    }
  }

  /// Compatibility shim for `PlayerScreen`'s libmpv property hints (`user-agent`,
  /// `referrer`, `tls-verify`, `hwdec`, buffer strategy, etc.).
  Future<void> setProperty(String key, String value) async {
    if (_disposed) return;
    _properties[key] = value;
    switch (key) {
      case 'tls-verify':
        final liveLike = value.trim().toLowerCase() == 'no';
        _isLiveHint = liveLike;
        _backend.setProperty('avio.tls_verify', liveLike ? '0' : '1');
        _applyBufferPolicy(
          kernelStrategy: _initialKernelStrategy,
          isLive: liveLike,
        );
        break;
      case 'hwdec':
        final compat = value.contains('copy');
        _backend.videoDecoders =
            compat ? legacyIgpuCompatDecoders : defaultIgpuDecoders;
        break;
      case 'user-agent':
        _backend.setProperty('avio.user_agent', value.trim());
        break;
      case 'referrer':
        _backend.setProperty('avio.referer', value.trim());
        break;
      default:
        break;
    }
  }

  /// Updates the MDK decoder & buffer strategy at runtime (e.g. switching
  /// between `exo` 均衡 / `ijk` 老核显兼容 / `mpv` 大容量缓冲).
  void applyKernelStrategy(String kernelStrategy, {bool isLive = false}) {
    if (_disposed) return;
    _isLiveHint = isLive;
    _backend.videoDecoders = decodersForKernelStrategy(kernelStrategy);
    _applyBufferPolicy(kernelStrategy: kernelStrategy, isLive: isLive);
  }

  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    if (_disposed) return;
    Media? media;
    Playlist nextPlaylist;
    if (playable is Media) {
      media = playable;
      nextPlaylist = Playlist(<Media>[playable], index: 0);
    } else if (playable is Playlist && playable.medias.isNotEmpty) {
      final idx = playable.index.clamp(0, playable.medias.length - 1);
      media = playable.medias[idx];
      nextPlaylist = Playlist(playable.medias, index: idx);
    } else {
      return;
    }

    final gen = ++_openGeneration;
    _stopPositionTimer();
    _activeVideoDecoderName = '';

    final mergedHeaders = <String, String>{};
    final lowerToKey = <String, String>{};
    void putHeader(String key, String value) {
      final k = key.trim();
      final v = value.trim();
      if (k.isEmpty || v.isEmpty) return;
      final lower = k.toLowerCase();
      final existing = lowerToKey[lower];
      if (existing != null) {
        mergedHeaders.remove(existing);
      }
      lowerToKey[lower] = k;
      mergedHeaders[k] = v;
    }

    putHeader('User-Agent', _properties['user-agent'] ?? '');
    putHeader('Referer', _properties['referrer'] ?? '');
    if (media.httpHeaders != null) {
      for (final e in media.httpHeaders!.entries) {
        putHeader(e.key, e.value);
      }
    }

    if (mergedHeaders.isNotEmpty) {
      final headerBuf = StringBuffer();
      mergedHeaders.forEach((k, v) {
        headerBuf.write('$k: $v\r\n');
      });
      _backend.setProperty('avio.headers', headerBuf.toString());
    } else {
      _backend.setProperty('avio.headers', '');
    }
    final uaKey = lowerToKey['user-agent'];
    _backend.setProperty('avio.user_agent', uaKey != null ? mergedHeaders[uaKey]! : '');
    final refKey = lowerToKey['referer'];
    _backend.setProperty('avio.referer', refKey != null ? mergedHeaders[refKey]! : '');

    final startMs = math.max(0, media.start?.inMilliseconds ?? 0);
    state = state.copyWith(
      playlist: nextPlaylist,
      playing: false,
      completed: false,
      buffering: true,
      position: Duration(milliseconds: startMs),
      duration: Duration.zero,
      buffer: Duration(milliseconds: startMs),
    );
    playlistController.add(nextPlaylist);
    bufferingController.add(true);
    completedController.add(false);
    positionController.add(Duration(milliseconds: startMs));

    _backend.state = mdk.PlaybackState.stopped;
    _backend.media = media.uri;
    final ret = await _backend.prepare(position: startMs);
    if (_disposed || gen != _openGeneration) return;
    if (ret < 0) {
      state = state.copyWith(playing: false, buffering: false);
      bufferingController.add(false);
      errorController.add('MDK failed to open media (code $ret)');
      return;
    }

    _syncMediaSnapshot();
    await _refreshTextureSafely();
    if (_disposed || gen != _openGeneration) return;

    _backend.playbackRate = state.rate.clamp(0.25, 4.0);
    _backend.volume = (state.volume / 100.0).clamp(0.0, 2.0);
    if (play) {
      _backend.state = mdk.PlaybackState.playing;
      state = state.copyWith(playing: true, buffering: false, completed: false);
      playingController.add(true);
      bufferingController.add(false);
      _startPositionTimer();
    } else {
      _backend.state = mdk.PlaybackState.paused;
      state = state.copyWith(playing: false, buffering: false);
      playingController.add(false);
      bufferingController.add(false);
    }
  }

  @override
  Future<void> stop() async {
    if (_disposed) return;
    _openGeneration++;
    _stopPositionTimer();
    _backend.state = mdk.PlaybackState.stopped;
    state = state.copyWith(
      playing: false,
      buffering: false,
      completed: false,
      position: Duration.zero,
    );
    playingController.add(false);
    bufferingController.add(false);
  }

  @override
  Future<void> play() async {
    if (_disposed) return;
    _backend.state = mdk.PlaybackState.playing;
    state = state.copyWith(playing: true, completed: false);
    playingController.add(true);
    _startPositionTimer();
  }

  @override
  Future<void> pause() async {
    if (_disposed) return;
    _backend.state = mdk.PlaybackState.paused;
    _stopPositionTimer();
    state = state.copyWith(playing: false);
    playingController.add(false);
  }

  @override
  Future<void> playOrPause() async {
    if (state.playing) {
      await pause();
    } else {
      await play();
    }
  }

  @override
  Future<void> seek(Duration duration) async {
    if (_disposed) return;
    final targetMs = math.max(0, duration.inMilliseconds);
    final clamped = Duration(milliseconds: targetMs);
    state = state.copyWith(position: clamped, completed: false);
    positionController.add(clamped);
    await _backend.seek(
      position: targetMs,
      flags: const mdk.SeekFlag(
        mdk.SeekFlag.fromStart | mdk.SeekFlag.inCache | mdk.SeekFlag.keyFrame,
      ),
    );
    if (!_disposed && state.playing) {
      _emitPositionAndBuffer();
    }
  }

  @override
  Future<void> setRate(double rate) async {
    if (_disposed) return;
    final clamped = rate.clamp(0.25, 4.0);
    _backend.playbackRate = clamped;
    state = state.copyWith(rate: clamped);
    rateController.add(clamped);
  }

  @override
  Future<void> setVolume(double volume) async {
    if (_disposed) return;
    final clamped100 = volume.clamp(0.0, 200.0);
    _backend.volume = (clamped100 / 100.0).clamp(0.0, 2.0);
    _backend.mute = clamped100 <= 0.01;
    state = state.copyWith(volume: clamped100);
    volumeController.add(clamped100);
  }

  @override
  Future<void> setAudioTrack(AudioTrack track) async {
    if (_disposed) return;
    if (track.uri) {
      _backend.setMediaForType(track.id, mdk.MediaType.audio);
    } else if (track == AudioTrack.no()) {
      _backend.activeAudioTracks = const <int>[];
    } else if (track == AudioTrack.auto()) {
      _backend.activeAudioTracks = const <int>[0];
    } else {
      final idx = int.tryParse(track.id);
      if (idx != null && idx >= 0) {
        _backend.activeAudioTracks = <int>[idx];
      }
    }
    final nextTrack = state.track.copyWith(audio: track);
    state = state.copyWith(track: nextTrack);
    trackController.add(nextTrack);
  }

  @override
  Future<void> setSubtitleTrack(SubtitleTrack track) async {
    if (_disposed) return;
    if (track.uri) {
      _backend.setMediaForType(track.id, mdk.MediaType.subtitle);
    } else if (track == SubtitleTrack.no()) {
      _backend.activeSubtitleTracks = const <int>[];
    } else if (track == SubtitleTrack.auto()) {
      _backend.activeSubtitleTracks = const <int>[0];
    } else {
      final idx = int.tryParse(track.id);
      if (idx != null && idx >= 0) {
        _backend.activeSubtitleTracks = <int>[idx];
      }
    }
    final nextTrack = state.track.copyWith(subtitle: track);
    state = state.copyWith(track: nextTrack);
    trackController.add(nextTrack);
  }

  @override
  Future<void> setVideoTrack(VideoTrack track) async {
    if (_disposed) return;
    if (track == VideoTrack.no()) {
      _backend.activeVideoTracks = const <int>[];
    } else if (track == VideoTrack.auto()) {
      _backend.activeVideoTracks = const <int>[0];
    } else {
      final idx = int.tryParse(track.id);
      if (idx != null && idx >= 0) {
        _backend.activeVideoTracks = <int>[idx];
      }
    }
    final nextTrack = state.track.copyWith(video: track);
    state = state.copyWith(track: nextTrack);
    trackController.add(nextTrack);
  }

  @override
  Future<void> setPlaylistMode(PlaylistMode playlistMode) async {
    if (_disposed) return;
    _backend.loop = playlistMode == PlaylistMode.single ? -1 : 0;
    state = state.copyWith(playlistMode: playlistMode);
    playlistModeController.add(playlistMode);
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _openGeneration++;
    _stopPositionTimer();
    await _statusSub?.cancel();
    await _stateSub?.cancel();
    await _eventSub?.cancel();
    _statusSub = null;
    _stateSub = null;
    _eventSub = null;
    try {
      await _backend.disposeAsync();
    } catch (e) {
      debugPrint('MdkPlatformPlayer dispose warning: $e');
    }
    await super.dispose();
  }
}
