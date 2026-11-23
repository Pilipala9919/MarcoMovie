// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'mdk_platform_player.dart';
import 'ohos_runtime.dart';

export 'mdk_platform_player.dart';

/// Playback pipeline mode used by [VideoKernel] across desktop, mobile, and HarmonyOS NEXT.
enum VideoKernelMode {
  auto,
  ohosHardwareHdr,
  proxyAccelerated,
  windowsMdk,
}

/// Formats stream pixel dimensions into a crisp living-room badge (`4K UHD`, `1080P FHD`, etc.).
String formatVideoResolutionLabel(int? width, int? height) {
  final w = width ?? 0;
  final h = height ?? 0;
  if (w <= 0 || h <= 0) return '';
  if (w >= 3840 || h >= 2160) return '4K UHD';
  if (w >= 2560 || h >= 1440) return '2K QHD';
  if (w >= 1920 || h >= 1080) return '1080P FHD';
  if (w >= 1280 || h >= 720) return '720P HD';
  return 'SD ${math.min(w, h)}P';
}

extension VideoKernelPlayerStateX on PlayerState {
  /// Human-readable resolution tier badge for the active video stream.
  String get videoResolutionLabel => formatVideoResolutionLabel(width, height);
}

/// HarmonyOS NEXT native `@kit.MediaKit` `AVPlayer` implementation of [PlatformPlayer],
/// rendering frames zero-copy through Flutter's GPU `TextureRegistry`.
class OhosPlatformPlayer extends PlatformPlayer {
  static const MethodChannel _channel =
      MethodChannel('com.pilipala.marcomovie/ohos_avplayer');

  final MethodChannel _controlChannel;
  final ValueNotifier<int?> _textureId = ValueNotifier<int?>(null);
  int? _playerId;
  StreamSubscription<dynamic>? _eventSubscription;
  Future<void>? _creating;
  bool _disposed = false;
  final Map<String, String> _properties = <String, String>{};
  final Map<String, int> _audioTrackIndices = <String, int>{};
  final Map<String, int> _subtitleTrackIndices = <String, int>{};
  int? _activeSubtitleTrackIndex;
  int _bufferingPercent = 100;
  int _streamBitrate = 0;

  OhosPlatformPlayer({
    super.configuration = const PlayerConfiguration(),
    MethodChannel? controlChannel,
  }) : _controlChannel = controlChannel ?? _channel;

  ValueListenable<int?> get textureIdListenable => _textureId;
  int? get textureId => _textureId.value;
  int? get playerId => _playerId;
  int? get activeSubtitleTrackIndex => _activeSubtitleTrackIndex;
  int get bufferingPercent => _bufferingPercent;
  int get streamBitrate => _streamBitrate;
  String get videoResolutionLabel => state.videoResolutionLabel;
  Map<String, String> get properties => Map<String, String>.unmodifiable(_properties);

  /// Compatibility hook for `PlayerScreen`'s libmpv property hints (`user-agent`, `referrer`, etc.).
  Future<void> setProperty(String key, String value) async {
    _properties[key] = value;
  }

  Future<int> _ensureCreated() async {
    if (_disposed) throw StateError('OhosPlatformPlayer has been disposed');
    if (_playerId != null) return _playerId!;
    if (_creating != null) {
      await _creating;
      return _playerId!;
    }
    final completer = Completer<void>();
    _creating = completer.future;
    try {
      final res = await _controlChannel.invokeMapMethod<String, dynamic>('create');
      final pid = (res?['playerId'] as num?)?.toInt() ?? 1;
      final tid = (res?['textureId'] as num?)?.toInt() ?? pid;
      _playerId = pid;
      _textureId.value = tid;
      final eventChannel =
          EventChannel('com.pilipala.marcomovie/ohos_avplayer/events/$pid');
      try {
        _eventSubscription = eventChannel.receiveBroadcastStream().listen(
              handleNativeEvent,
              onError: (Object error) {
                if (!_disposed && error is! MissingPluginException) {
                  errorController.add(error.toString());
                }
              },
            );
      } catch (_) {}
      configuration.ready?.call();
      completer.complete();
      return pid;
    } catch (e, st) {
      _creating = null;
      completer.completeError(e, st);
      rethrow;
    }
  }

  /// Processes native EventChannel maps emitted by `OhosAvPlayerPlugin.ets`
  /// (also exposed `@visibleForTesting` for deterministic unit tests).
  @visibleForTesting
  void handleNativeEvent(dynamic raw) {
    if (_disposed || raw is! Map) return;
    final event = Map<String, dynamic>.from(raw);
    final type = event['type']?.toString() ?? '';
    switch (type) {
      case 'state':
        final playing = event['playing'] == true;
        final buffering = event['buffering'] == true;
        final completed = event['completed'] == true;
        state = state.copyWith(
          playing: playing,
          buffering: buffering,
          completed: completed,
        );
        playingController.add(playing);
        bufferingController.add(buffering);
        completedController.add(completed);
        break;
      case 'position':
        final posMs = (event['positionMs'] as num?)?.toInt() ?? 0;
        final durMs = (event['durationMs'] as num?)?.toInt() ?? 0;
        final bufMs = (event['bufferedMs'] as num?)?.toInt() ?? posMs;
        final pos = Duration(milliseconds: math.max(0, posMs));
        final dur = Duration(milliseconds: math.max(0, durMs));
        final buf = Duration(milliseconds: math.max(0, bufMs));
        state = state.copyWith(
          position: pos,
          duration: durMs > 0 ? dur : state.duration,
          buffer: buf,
        );
        positionController.add(pos);
        if (durMs > 0) {
          durationController.add(dur);
        }
        bufferController.add(buf);
        break;
      case 'videoSize':
        final w = (event['width'] as num?)?.toInt() ?? 0;
        final h = (event['height'] as num?)?.toInt() ?? 0;
        final br = (event['bitrate'] as num?)?.toInt() ?? 0;
        if (br > 0) {
          _streamBitrate = br;
        }
        if (w > 0 && h > 0) {
          state = state.copyWith(width: w, height: h);
          widthController.add(w);
          heightController.add(h);
        }
        break;
      case 'bufferingPercent':
        final pct = (event['percent'] as num?)?.toInt();
        if (pct != null) {
          _bufferingPercent = pct.clamp(0, 100);
        }
        final br = (event['bitrate'] as num?)?.toInt() ?? 0;
        if (br > 0) {
          _streamBitrate = br;
        }
        break;
      case 'tracks':
        final rawList = event['tracks'];
        if (rawList is List) {
          _applyNativeTracks(rawList);
        }
        break;
      case 'error':
        final msg = event['message']?.toString() ??
            'AVPlayer error (${event['code'] ?? 'unknown'})';
        errorController.add(msg);
        break;
    }
  }

  void _applyNativeTracks(List<dynamic> rawList) {
    final videoTracks = <VideoTrack>[VideoTrack.auto()];
    final audioTracks = <AudioTrack>[AudioTrack.auto()];
    final subtitleTracks = <SubtitleTrack>[SubtitleTrack.auto(), SubtitleTrack.no()];
    _audioTrackIndices.clear();
    _subtitleTrackIndices.clear();

    for (final item in rawList) {
      if (item is! Map) continue;
      final m = Map<String, dynamic>.from(item);
      final idx = (m['index'] as num?)?.toInt();
      if (idx == null) continue;
      final trackType = (m['trackType']?.toString() ?? '').toLowerCase();
      final codec = m['codec']?.toString();
      final language = m['language']?.toString();
      final title = m['title']?.toString() ?? 'Track $idx';
      final id = idx.toString();
      if (trackType.contains('video') || trackType == '1') {
        videoTracks.add(VideoTrack(id, title, language, codec: codec));
      } else if (trackType.contains('audio') || trackType == '0') {
        _audioTrackIndices[id] = idx;
        audioTracks.add(AudioTrack(id, title, language, codec: codec));
      } else if (trackType.contains('sub') || trackType.contains('text') || trackType == '2') {
        _subtitleTrackIndices[id] = idx;
        subtitleTracks.add(SubtitleTrack(id, title, language, codec: codec));
      }
    }

    if (_activeSubtitleTrackIndex != null &&
        !_subtitleTrackIndices.containsValue(_activeSubtitleTrackIndex)) {
      _activeSubtitleTrackIndex = null;
    }

    final nextTracks = Tracks(
      video: videoTracks,
      audio: audioTracks,
      subtitle: subtitleTracks,
    );
    state = state.copyWith(tracks: nextTracks);
    tracksController.add(nextTracks);
    if (videoTracks.length > 1 || audioTracks.length > 1) {
      final activeTrack = Track(
        video: videoTracks.length > 1 ? videoTracks[1] : VideoTrack.auto(),
        audio: audioTracks.length > 1 ? audioTracks[1] : AudioTrack.auto(),
        subtitle: state.track.subtitle,
      );
      state = state.copyWith(track: activeTrack);
      trackController.add(activeTrack);
    }
  }

  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    final pid = await _ensureCreated();
    Media? media;
    Playlist nextPlaylist;
    if (playable is Media) {
      media = playable;
      nextPlaylist = Playlist([playable], index: 0);
    } else if (playable is Playlist && playable.medias.isNotEmpty) {
      final idx = playable.index.clamp(0, playable.medias.length - 1);
      media = playable.medias[idx];
      nextPlaylist = Playlist(playable.medias, index: idx);
    } else {
      return;
    }

    final mergedHeaders = <String, String>{};
    final propUa = _properties['user-agent'] ?? '';
    final propRef = _properties['referrer'] ?? '';
    if (propUa.isNotEmpty) mergedHeaders['User-Agent'] = propUa;
    if (propRef.isNotEmpty) mergedHeaders['Referer'] = propRef;
    if (media.httpHeaders != null) {
      mergedHeaders.addAll(media.httpHeaders!);
    }

    _activeSubtitleTrackIndex = null;
    _bufferingPercent = 0;
    _streamBitrate = 0;

    final hdrRaw = _properties['hdr']?.trim().toLowerCase();
    final preferredHdr = hdrRaw == null || hdrRaw.isEmpty
        ? true
        : (hdrRaw == 'true' || hdrRaw == '1' || hdrRaw == 'yes');
    final parsedBufferSec = int.tryParse(_properties['buffer-seconds'] ?? '');
    final preferredBufferDuration =
        (parsedBufferSec != null && parsedBufferSec > 0)
            ? parsedBufferSec.clamp(1, 20)
            : 20;

    state = state.copyWith(
      playlist: nextPlaylist,
      playing: false,
      completed: false,
      buffering: true,
      position: media.start ?? Duration.zero,
      duration: Duration.zero,
    );
    playlistController.add(nextPlaylist);
    bufferingController.add(true);

    await _controlChannel.invokeMethod<void>('open', {
      'playerId': pid,
      'url': media.uri,
      'headers': mergedHeaders,
      'startPositionMs': media.start?.inMilliseconds ?? 0,
      'autoPlay': play,
      'preferredHdr': preferredHdr,
      'preferredBufferDuration': preferredBufferDuration,
    });

    // Query track metadata asynchronously once prepared.
    unawaited(_refreshTracks(pid));
  }

  Future<void> _refreshTracks(int pid) async {
    try {
      final raw = await _controlChannel
          .invokeListMethod<dynamic>('getTracks', {'playerId': pid});
      if (raw != null && !_disposed) {
        _applyNativeTracks(raw);
      }
    } catch (_) {}
  }

  @override
  Future<void> play() async {
    final pid = _playerId;
    if (pid == null || _disposed) return;
    await _controlChannel.invokeMethod<void>('play', {'playerId': pid});
    state = state.copyWith(playing: true, completed: false);
    playingController.add(true);
  }

  @override
  Future<void> pause() async {
    final pid = _playerId;
    if (pid == null || _disposed) return;
    await _controlChannel.invokeMethod<void>('pause', {'playerId': pid});
    state = state.copyWith(playing: false);
    playingController.add(false);
  }

  @override
  Future<void> playOrPause() => state.playing ? pause() : play();

  @override
  Future<void> stop() async {
    final pid = _playerId;
    if (pid == null || _disposed) return;
    await _controlChannel.invokeMethod<void>('stop', {'playerId': pid});
    state = state.copyWith(playing: false, buffering: false);
    playingController.add(false);
    bufferingController.add(false);
  }

  @override
  Future<void> seek(Duration duration) async {
    final pid = _playerId;
    if (pid == null || _disposed) return;
    final ms = math.max(0, duration.inMilliseconds);
    await _controlChannel.invokeMethod<void>('seek', {
      'playerId': pid,
      'positionMs': ms,
    });
    final clamped = Duration(milliseconds: ms);
    state = state.copyWith(position: clamped);
    positionController.add(clamped);
  }

  @override
  Future<void> setRate(double rate) async {
    final pid = _playerId;
    final clamped = rate.clamp(0.25, 3.0);
    state = state.copyWith(rate: clamped);
    rateController.add(clamped);
    if (pid == null || _disposed) return;
    await _controlChannel.invokeMethod<void>('setRate', {
      'playerId': pid,
      'rate': clamped,
    });
  }

  @override
  Future<void> setVolume(double volume) async {
    final pid = _playerId;
    final clamped = volume.clamp(0.0, 100.0);
    state = state.copyWith(volume: clamped);
    volumeController.add(clamped);
    if (pid == null || _disposed) return;
    await _controlChannel.invokeMethod<void>('setVolume', {
      'playerId': pid,
      'volume': (clamped / 100.0).clamp(0.0, 1.0),
    });
  }

  @override
  Future<void> setVideoTrack(VideoTrack track) async {
    final next = state.track.copyWith(video: track);
    state = state.copyWith(track: next);
    trackController.add(next);
  }

  @override
  Future<void> setAudioTrack(AudioTrack track) async {
    final pid = _playerId;
    final next = state.track.copyWith(audio: track);
    state = state.copyWith(track: next);
    trackController.add(next);
    final idx = _audioTrackIndices[track.id];
    if (pid != null && idx != null && !_disposed) {
      await _controlChannel.invokeMethod<void>('selectTrack', {
        'playerId': pid,
        'index': idx,
      });
    }
  }

  @override
  Future<void> setSubtitleTrack(SubtitleTrack track) async {
    final pid = _playerId;
    final next = state.track.copyWith(subtitle: track);
    state = state.copyWith(track: next);
    trackController.add(next);
    if (track == SubtitleTrack.no() || track.id == 'no') {
      final prevIdx = _activeSubtitleTrackIndex;
      _activeSubtitleTrackIndex = null;
      if (pid != null && prevIdx != null && !_disposed) {
        await _controlChannel.invokeMethod<void>('deselectTrack', {
          'playerId': pid,
          'index': prevIdx,
        });
      }
      return;
    }
    final idx = _subtitleTrackIndices[track.id];
    if (idx != null) {
      _activeSubtitleTrackIndex = idx;
      if (pid != null && !_disposed) {
        await _controlChannel.invokeMethod<void>('selectTrack', {
          'playerId': pid,
          'index': idx,
        });
      }
    }
  }

  @override
  Future<void> setPlaylistMode(PlaylistMode playlistMode) async {
    state = state.copyWith(playlistMode: playlistMode);
    playlistModeController.add(playlistMode);
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    final sub = _eventSubscription;
    _eventSubscription = null;
    if (sub != null) {
      unawaited(sub.cancel().catchError((_) {}));
    }
    final pid = _playerId;
    _playerId = null;
    _textureId.value = null;
    if (pid != null) {
      try {
        await _controlChannel.invokeMethod<void>('dispose', {'playerId': pid});
      } catch (_) {}
    }
    await super.dispose();
  }
}

/// Unified video kernel binding [PlayerScreen] to `media_kit` (`libmpv`),
/// Windows `MdkPlatformPlayer` (`libmdk` D3D11/MFT/DXVA iGPU-friendly engine),
/// or `OhosPlatformPlayer` (`AVPlayer` + GPU Texture) on HarmonyOS NEXT.
class VideoKernel {
  final Player player;
  final VideoController? mediaKitController;
  final OhosPlatformPlayer? ohosPlatform;
  final MdkPlatformPlayer? mdkPlatform;
  final Widget? debugSurface;
  final VideoKernelMode mode;

  bool get isMdk => mdkPlatform != null;

  const VideoKernel._({
    required this.player,
    required this.mode,
    this.mediaKitController,
    this.ohosPlatform,
    this.mdkPlatform,
    this.debugSurface,
  });

  factory VideoKernel.create({
    Player? debugPlayer,
    Widget? debugVideoSurface,
    required String hwdec,
    VideoKernelMode? mode,
    WindowsPlaybackEngine windowsEngine = WindowsPlaybackEngine.mpv,
    String kernelStrategy = 'exo',
    MdkNativeBackend? debugMdkBackend,
  }) {
    if (debugPlayer != null) {
      final isOhosDebug = debugPlayer.platform is OhosPlatformPlayer;
      final isMdkDebug = debugPlayer.platform is MdkPlatformPlayer;
      return VideoKernel._(
        player: debugPlayer,
        mode: mode ??
            (isOhosDebug
                ? VideoKernelMode.ohosHardwareHdr
                : (isMdkDebug
                    ? VideoKernelMode.windowsMdk
                    : VideoKernelMode.auto)),
        mediaKitController: debugVideoSurface == null &&
                !OhosRuntime.isOhos &&
                !isOhosDebug &&
                !isMdkDebug
            ? VideoController(
                debugPlayer,
                configuration: VideoControllerConfiguration(hwdec: hwdec),
              )
            : null,
        ohosPlatform: isOhosDebug
            ? debugPlayer.platform as OhosPlatformPlayer
            : null,
        mdkPlatform:
            isMdkDebug ? debugPlayer.platform as MdkPlatformPlayer : null,
        debugSurface: debugVideoSurface,
      );
    }

    if (OhosRuntime.isOhos) {
      final ohos = OhosPlatformPlayer();
      return VideoKernel._(
        player: Player(platformPlayer: ohos),
        mode: mode ?? VideoKernelMode.ohosHardwareHdr,
        ohosPlatform: ohos,
        debugSurface: debugVideoSurface,
      );
    }

    if (!kIsWeb &&
        defaultTargetPlatform == TargetPlatform.windows &&
        windowsEngine == WindowsPlaybackEngine.mdk) {
      final mdkPlayer = MdkPlatformPlayer(
        kernelStrategy: kernelStrategy,
        debugBackend: debugMdkBackend,
      );
      return VideoKernel._(
        player: Player(platformPlayer: mdkPlayer),
        mode: mode ?? VideoKernelMode.windowsMdk,
        mdkPlatform: mdkPlayer,
        debugSurface: debugVideoSurface,
      );
    }

    final nativePlayer = Player();
    return VideoKernel._(
      player: nativePlayer,
      mode: mode ?? VideoKernelMode.auto,
      mediaKitController: debugVideoSurface == null
          ? VideoController(
              nativePlayer,
              configuration: VideoControllerConfiguration(hwdec: hwdec),
            )
          : null,
      debugSurface: debugVideoSurface,
    );
  }

  Widget buildVideoSurface({
    required BoxFit fit,
    required int videoWidth,
    required int videoHeight,
    bool externalSubtitleOverlay = false,
  }) {
    if (debugSurface != null) return debugSurface!;
    if (ohosPlatform != null) {
      return ValueListenableBuilder<int?>(
        valueListenable: ohosPlatform!.textureIdListenable,
        builder: (context, tid, _) {
          if (tid == null) {
            return const ColoredBox(
              color: Colors.black,
              child: SizedBox.expand(),
            );
          }
          final w = videoWidth > 0 ? videoWidth.toDouble() : 1920.0;
          final h = videoHeight > 0 ? videoHeight.toDouble() : 1080.0;
          return ColoredBox(
            color: Colors.black,
            child: SizedBox.expand(
              child: FittedBox(
                fit: fit,
                clipBehavior: Clip.hardEdge,
                child: SizedBox(
                  width: w,
                  height: h,
                  child: Texture(textureId: tid),
                ),
              ),
            ),
          );
        },
      );
    }
    if (mdkPlatform != null) {
      return ValueListenableBuilder<int?>(
        valueListenable: mdkPlatform!.textureIdListenable,
        builder: (context, tid, _) {
          if (tid == null || tid < 0) {
            return const ColoredBox(
              key: ValueKey('windows-mdk-surface-loading'),
              color: Colors.black,
              child: SizedBox.expand(),
            );
          }
          final w = videoWidth > 0 ? videoWidth.toDouble() : 1920.0;
          final h = videoHeight > 0 ? videoHeight.toDouble() : 1080.0;
          return ColoredBox(
            key: const ValueKey('windows-mdk-surface'),
            color: Colors.black,
            child: SizedBox.expand(
              child: FittedBox(
                fit: fit,
                clipBehavior: Clip.hardEdge,
                child: SizedBox(
                  width: w,
                  height: h,
                  child: Texture(
                    textureId: tid,
                    filterQuality: FilterQuality.medium,
                  ),
                ),
              ),
            ),
          );
        },
      );
    }
    return Video(
      controller: mediaKitController!,
      fit: fit,
      controls: NoVideoControls,
      subtitleViewConfiguration: externalSubtitleOverlay
          ? const SubtitleViewConfiguration(visible: false)
          : const SubtitleViewConfiguration(),
    );
  }

  /// Renders media_kit subtitles as an independent layer strictly ABOVE
  /// `DanmuLayer` and BELOW HUD controls when `externalSubtitleOverlay` is enabled.
  Widget? buildSubtitleOverlay() {
    if (OhosRuntime.isOhos ||
        debugSurface != null ||
        ohosPlatform != null ||
        mdkPlatform != null) {
      return null;
    }
    final ctrl = mediaKitController;
    if (ctrl == null) return null;
    if (ctrl.player.platform?.configuration.libass ?? false) {
      return null;
    }
    return SubtitleView(
      controller: ctrl,
      configuration: const SubtitleViewConfiguration(),
    );
  }
}

/// Implements Marco Movie's living-room TV remote seek curve (documented in `docs/platform-releases.md`):
/// - Short tap (< 500 ms): steps ±15 seconds immediately on release.
/// - Hold (>= 500 ms): preview speed starts at 30 s/s and accelerates linearly by 30 s/s²,
///   capped at 240 s/s, integrated by elapsed wall-clock time (immune to key-repeat jitter).
/// - Reversing direction resets acceleration; cancel/back aborts without committing.
class TvRemoteSeekController {
  static const int tapStepMs = 15000;
  static const int holdThresholdMs = 500;
  static const double initialSpeedSecPerSec = 30.0;
  static const double accelSecPerSec2 = 30.0;
  static const double maxSpeedSecPerSec = 240.0;

  int _direction = 0; // -1 rewind, +1 forward, 0 idle
  int _pressStartEpochMs = 0;
  int _anchorPositionMs = 0;
  int _durationMs = 0;
  int _previewTargetMs = 0;

  bool get isActive => _direction != 0;
  int get direction => _direction;
  int get previewTargetMs => _previewTargetMs;

  /// Computes the instantaneous speed (in playback seconds per held second) for `heldAfterThresholdSec`.
  static double previewSpeedAt(double heldAfterThresholdSec) {
    if (heldAfterThresholdSec < 0) return 0;
    return (initialSpeedSecPerSec + accelSecPerSec2 * heldAfterThresholdSec)
        .clamp(initialSpeedSecPerSec, maxSpeedSecPerSec);
  }

  /// Integrates distance traveled (in playback seconds) after `heldAfterThresholdSec` past the 500 ms threshold.
  static double integratedOffsetSeconds(double heldAfterThresholdSec) {
    if (heldAfterThresholdSec <= 0) return 15.0;
    // Time to hit cap (240 = 30 + 30 * t => t = 7.0s)
    const capTimeSec =
        (maxSpeedSecPerSec - initialSpeedSecPerSec) / accelSecPerSec2;
    final accelPhase = math.min(heldAfterThresholdSec, capTimeSec);
    final distanceAccel = initialSpeedSecPerSec * accelPhase +
        0.5 * accelSecPerSec2 * accelPhase * accelPhase;
    final cappedPhase = math.max(0.0, heldAfterThresholdSec - capTimeSec);
    final distanceCapped = maxSpeedSecPerSec * cappedPhase;
    return 15.0 + distanceAccel + distanceCapped;
  }

  void onKeyDown({
    required int direction,
    required int currentPositionMs,
    required int durationMs,
    required int nowEpochMs,
  }) {
    assert(direction == -1 || direction == 1);
    if (_direction == direction) {
      // Key-repeat event in same direction: update preview using elapsed wall-clock time.
      updatePreview(nowEpochMs);
      return;
    }
    // New press or direction reversal resets anchor and acceleration curve.
    _direction = direction;
    _pressStartEpochMs = nowEpochMs;
    _anchorPositionMs =
        (_direction != 0 && _previewTargetMs > 0 && isActive)
            ? currentPositionMs
            : currentPositionMs;
    _durationMs = math.max(0, durationMs);
    _previewTargetMs = _clampTarget(_anchorPositionMs + direction * tapStepMs);
  }

  ({int targetMs, double currentSpeedX, bool isHoldPreview}) updatePreview(
    int nowEpochMs,
  ) {
    if (_direction == 0) {
      return (targetMs: _previewTargetMs, currentSpeedX: 0, isHoldPreview: false);
    }
    final elapsedMs = math.max(0, nowEpochMs - _pressStartEpochMs);
    if (elapsedMs < holdThresholdMs) {
      _previewTargetMs =
          _clampTarget(_anchorPositionMs + _direction * tapStepMs);
      return (
        targetMs: _previewTargetMs,
        currentSpeedX: 0,
        isHoldPreview: false,
      );
    }
    final heldSec = (elapsedMs - holdThresholdMs) / 1000.0;
    final offsetMs = (integratedOffsetSeconds(heldSec) * 1000.0).round();
    final speed = previewSpeedAt(heldSec);
    _previewTargetMs = _clampTarget(_anchorPositionMs + _direction * offsetMs);
    return (
      targetMs: _previewTargetMs,
      currentSpeedX: speed,
      isHoldPreview: true,
    );
  }

  /// Commits and resets the active seek, returning the target position in ms (or `null` if inactive).
  int? commitOnKeyUp(int nowEpochMs) {
    if (_direction == 0) return null;
    final updated = updatePreview(nowEpochMs);
    _direction = 0;
    _pressStartEpochMs = 0;
    return updated.targetMs;
  }

  /// Aborts an in-flight hold seek without committing.
  void cancel() {
    _direction = 0;
    _pressStartEpochMs = 0;
  }

  int _clampTarget(int rawMs) {
    if (_durationMs <= 0) return math.max(0, rawMs);
    return rawMs.clamp(0, _durationMs);
  }
}
