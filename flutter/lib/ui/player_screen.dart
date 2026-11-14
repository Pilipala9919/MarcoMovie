import 'dart:io';
import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import '../core/cms_client.dart';
import '../core/emby_library.dart';
import '../core/csp_bridge.dart';
import '../core/cloud_media_proxy.dart';
import '../core/local_media_proxy.dart';
import '../core/models.dart';
import '../core/playback_recovery_policy.dart';
import '../core/playback_startup.dart';
import '../core/playback_wakelock.dart';
import '../core/web_media_resolver.dart';
import '../core/wogg_source.dart';
import 'player_interaction_layers.dart';
import '../core/storage_service.dart';
import 'apple_theme.dart';
import 'desktop_horizontal_scroller.dart';
import 'desktop_player_window.dart';
import 'mobile_player_chrome.dart';
import 'netdisk_sheet.dart';
import 'source_verification_dialog.dart';
import 'windows_title_bar.dart';

/// Apple AVPlayerViewController / Apple TV+ inspired video player with:
/// - Large center transport controls (Rewind 15s, Play/Pause, Fast-Forward 15s)
/// - Dedicated floating Progress Bar capsule (automatically hidden during Live TV)
/// - Compact scrollable Tool Dock (Bottom horizontal in Portrait, Right edge in Landscape)
/// - Full-width iOS 27 Liquid Glass Episode & Line Picker sheet.
class PlayerScreen extends StatefulWidget {
  final CmsSite site;
  final CmsVideo video;
  final int initialLineIndex;
  final int initialEpisodeIndex;
  final int initialPositionMs;
  final StorageService storage;
  final bool isLive;
  @visibleForTesting
  final Player? debugPlayer;
  @visibleForTesting
  final Widget? debugVideoSurface;

  const PlayerScreen({
    super.key,
    required this.site,
    required this.video,
    required this.initialLineIndex,
    required this.initialEpisodeIndex,
    required this.storage,
    this.initialPositionMs = 0,
    this.isLive = false,
    this.debugPlayer,
    this.debugVideoSurface,
  });

  /// The resolver already applies origin rules and explicit playback headers.
  /// Re-merging subscription headers here would restore filtered credentials.
  Media mediaForPlayback(CmsEpisode episode, {Duration? start}) => Media(
    episode.url,
    httpHeaders: Map<String, String>.of(episode.headers),
    start: start,
  );

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

/// Owns the active file's temporary HTTP transport independently of the UI.
/// Media must stop before [releaseUnless]; [discard] handles late resolutions.
class PlayerCloudMediaSession {
  CloudMediaLease? _current;
  CloudMediaLease? get current => _current;

  static CloudMediaLease? of(CmsEpisode episode) {
    final value = episode.playbackSession['cloudMediaLease'];
    return value is CloudMediaLease ? value : null;
  }

  bool owns(CloudMediaLease? lease) => lease != null && identical(lease, _current);

  void adopt(CloudMediaLease? lease) => _current = lease;

  CloudMediaLease? detach() {
    final previous = _current;
    _current = null;
    return previous;
  }

  Future<void> releaseUnless(CloudMediaLease? keep) async {
    if (!owns(keep)) await detach()?.close();
  }

  Future<void> discard(CloudMediaLease? lease) async {
    if (lease != null && !owns(lease)) await lease.close();
  }
}

class _PlayerScreenState extends State<PlayerScreen>
    with WidgetsBindingObserver {
  late final Player _player;
  VideoController? _controller;
  late Future<void> _playerConfiguration;
  final CmsClient _client = CmsClient();
  final List<StreamSubscription<dynamic>> _playerSubscriptions = [];

  late List<CmsLine> _lines;
  late int _lineIndex;
  late int _episodeIndex;
  late double _normalSpeed;
  late int _skipIntroSec;
  late int _skipOutroSec;
  late bool _alwaysShowClock;
  late bool _autoNext;
  late String _repeatMode;
  late String _playerKernel;
  Timer? _clockTimer;
  String _clockText = '';
  bool _initialHistoryRecorded = false;
  double _playerBrightness = 1.0;
  bool _isVerticalDragging = false;
  bool _isDraggingLeftBrightness = false;
  double _verticalDragStartY = 0;
  double _verticalDragStartValue = 0;

  bool _allowHistory = false;
  bool _controlsVisible = true;
  bool _screenLocked = false;
  bool _lockButtonVisible = false;
  Timer? _lockHideTimer;
  Timer? _hudTimer;
  bool _speedBoosting = false;
  String _hudText = '';
  late final FocusNode _playerFocusNode = FocusNode();
  double _previousVolume = 100.0;
  final ScrollController _portraitToolsScrollController = ScrollController();
  String _playbackError = '';
  Object? _playbackErrorCause;
  bool _allowEvents = false;
  DesktopPlayerWindow? _desktopWindow;
  final MobilePlayerChrome _mobileChrome = MobilePlayerChrome();
  Future<void> _mediaChanges = Future<void>.value();
  void Function()? _releaseSourceSession;
  List<CmsEpisode> _qualityChoices = const [];
  bool get _desktop =>
      defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.linux;
  BoxFit _fit = BoxFit.contain;
  Timer? _hideTimer;
  Timer? _historyTimer;
  EmbyPlaybackSession? _embySession;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _playing = false;
  bool _loading = true;
  bool _buffering = false;
  double _dragStartPosMs = 0;
  double _dragStartX = 0;
  int _dragTargetPosMs = 0;
  bool _isDraggingSeek = false;
  bool _isSliderDragging = false;
  double _sliderDragPosMs = 0;
  int _playSession = 0;
  Completer<void>? _sourceAbort;
  final _cloudMedia = PlayerCloudMediaSession();
  final _localMedia = PlayerLocalMediaSession();
  final _startup = PlaybackStartup();
  int _pendingResumeMs = 0;
  int _lastKnownPositionMs = 0;
  int _lastKnownDurationMs = 0;
  int _lastPositionUiUpdateMs = 0;
  int _videoWidth = 0;
  int _videoHeight = 0;
  String _videoCodec = '';
  String _audioCodec = '';
  String _activeStreamUrl = '';
  String _activeMediaUri = '';
  bool get _matchesActiveMedia {
    if (_activeMediaUri.isEmpty) return false;
    final playlist = _player.state.playlist;
    if (playlist.medias.isEmpty) return _allowEvents;
    return playlist.index >= 0 &&
        playlist.index < playlist.medias.length &&
        playlist.medias[playlist.index].uri == _activeMediaUri;
  }

  bool _introSkippedForSession = false;
  bool _outroSkippedForSession = false;
  bool _userSelectedQuality = false;
  final List<int> _midPlaybackStallEpochsMs = <int>[];
  Timer? _midPlaybackStallTimer;
  int _lastPointerScheduleMs = 0;
  final Set<int> _failedLinesForEpisode = <int>{};
  final Set<int> _failedLiveEpisodes = <int>{};
  final Set<String> _failedQualityUrls = <String>{};

  CmsLine get _currentLine => _lines[_lineIndex.clamp(0, _lines.length - 1)];
  CmsEpisode get _currentEpisode =>
      _currentLine.episodes[_episodeIndex.clamp(0, _currentLine.episodes.length - 1)];

  bool get _isLiveStream =>
      widget.isLive ||
      widget.site.key == 'live' ||
      (widget.site.api.isEmpty && widget.site.type == 1) ||
      CspBridge.isHuyaSite(widget.site) ||
      CspBridge.isDouyuSite(widget.site);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _lines = List<CmsLine>.of(
      WoggSource.normalizeCachedVideoLabels(widget.site, widget.video).lines,
    );
    _lineIndex = widget.initialLineIndex.clamp(
      0,
      _lines.length - 1,
    );
    _episodeIndex = widget.initialEpisodeIndex.clamp(
      0,
      _currentLine.episodes.length - 1,
    );
    _normalSpeed = _isLiveStream ? 1.0 : widget.storage.playSpeed;
    _skipIntroSec = widget.storage.getVideoSkipIntroSec(
      widget.site.key,
      widget.video.id,
      isPrivate: widget.site.isEffectivelyPrivate,
    );
    _skipOutroSec = widget.storage.getVideoSkipOutroSec(
      widget.site.key,
      widget.video.id,
      isPrivate: widget.site.isEffectivelyPrivate,
    );
    _alwaysShowClock = widget.storage.playerAlwaysShowClock;
    _clockText = _formatClockNow();
    _clockTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (!mounted || !_alwaysShowClock) return;
      final next = _formatClockNow();
      if (next != _clockText) {
        setState(() => _clockText = next);
      }
    });
    _autoNext = widget.storage.autoNext;
    _repeatMode = widget.storage.repeatMode;
    _playerKernel = widget.storage.playerKernel;
    _fit = switch (widget.storage.defaultAspectMode) {
      'cover' => BoxFit.cover,
      'fill' => BoxFit.fill,
      _ => BoxFit.contain,
    };

    if (_desktop) {
      _desktopWindow = DesktopPlayerWindow()..addListener(_windowChanged);
      _desktopWindow!.initialize().catchError(_windowError);
    }
    _player = widget.debugPlayer ?? Player();
    // Keep one source lease for this page, including pause and overlapping
    // episode/quality transitions. Release only after the decoder is disposed.
    _releaseSourceSession = _client.pinPlaybackSource(widget.site);
    if (widget.debugVideoSurface == null) {
      _controller = VideoController(
        _player,
        configuration: VideoControllerConfiguration(
          hwdec: _hardwareDecoder(_playerKernel),
        ),
      );
    }
    _playerConfiguration = _applyPlayerKernel(_playerKernel);

    _playerSubscriptions.add(_player.stream.width.listen((w) {
      if (!mounted || w == null || w <= 0 || w == _videoWidth) return;
      setState(() => _videoWidth = w);
    }));
    _playerSubscriptions.add(_player.stream.height.listen((h) {
      if (!mounted || h == null || h <= 0 || h == _videoHeight) return;
      setState(() => _videoHeight = h);
    }));
    _playerSubscriptions.add(_player.stream.track.listen((track) {
      if (!mounted || !_allowEvents || !_matchesActiveMedia) return;
      final vCodec = (track.video.codec ?? track.video.decoder ?? '').trim();
      final aCodec = (track.audio.codec ?? track.audio.decoder ?? '').trim();
      if ((vCodec.isNotEmpty && vCodec != _videoCodec) ||
          (aCodec.isNotEmpty && aCodec != _audioCodec)) {
        setState(() {
          if (vCodec.isNotEmpty) _videoCodec = vCodec;
          if (aCodec.isNotEmpty) _audioCodec = aCodec;
        });
      }
    }));
    _playerSubscriptions.add(_player.stream.tracks.listen((tracks) {
      if (!mounted || !_allowEvents || !_matchesActiveMedia) return;
      String pickCodec(Iterable<({String id, String? codec, String? decoder})> list) {
        for (final item in list) {
          if (item.id == 'auto' || item.id == 'no') continue;
          final c = (item.codec ?? item.decoder ?? '').trim();
          if (c.isNotEmpty) return c;
        }
        return '';
      }
      final vCodec = pickCodec(
        tracks.video.map((t) => (id: t.id, codec: t.codec, decoder: t.decoder)),
      );
      final aCodec = pickCodec(
        tracks.audio.map((t) => (id: t.id, codec: t.codec, decoder: t.decoder)),
      );
      if ((_videoCodec.isEmpty && vCodec.isNotEmpty) ||
          (_audioCodec.isEmpty && aCodec.isNotEmpty)) {
        setState(() {
          if (_videoCodec.isEmpty && vCodec.isNotEmpty) _videoCodec = vCodec;
          if (_audioCodec.isEmpty && aCodec.isNotEmpty) _audioCodec = aCodec;
        });
      }
    }));

    _playerSubscriptions.add(_player.stream.position.listen((pos) {
      if (!mounted || !_allowEvents || !_matchesActiveMedia) return;
      _startup.position(pos);
      final nextPos = (!_isDraggingSeek && !_isSliderDragging)
          ? ((_pendingResumeMs > 0 && pos.inMilliseconds < 2000)
                ? Duration(milliseconds: _pendingResumeMs)
                : pos)
          : _position;
      if (pos.inMilliseconds >= 1000) {
        _lastKnownPositionMs = pos.inMilliseconds;
        if (!_initialHistoryRecorded) {
          _initialHistoryRecorded = true;
          unawaited(_saveProgress());
        }
      }
      final shouldClearLoading = pos > Duration.zero && _loading;
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final shouldRebuildUi =
          shouldClearLoading ||
          (_controlsVisible &&
              !_isDraggingSeek &&
              !_isSliderDragging &&
              (nowMs - _lastPositionUiUpdateMs >= 250 || !_playing));
      if (shouldRebuildUi) {
        _lastPositionUiUpdateMs = nowMs;
        setState(() {
          _position = nextPos;
          if (shouldClearLoading) {
            _loading = false;
          }
        });
      } else {
        _position = nextPos;
      }
      _embySession?.update(pos.inMilliseconds, !_playing);
      final effectiveDur = _duration.inMilliseconds > 0
          ? _duration
          : Duration(milliseconds: _lastKnownDurationMs);
      if (!_isLiveStream &&
          !_outroSkippedForSession &&
          _skipOutroSec > 0 &&
          effectiveDur.inSeconds > _skipOutroSec + 30 &&
          pos.inSeconds > 10 &&
          (effectiveDur - pos).inSeconds <= _skipOutroSec) {
        _outroSkippedForSession = true;
        unawaited(_saveProgress(immediate: true, syncImmediate: false));
        _showHud('已自动跳过片尾 ${_skipOutroSec}s');
        _handleEpisodeEnd();
      }
    }));

    _playerSubscriptions.add(_player.stream.duration.listen((dur) {
      if (!mounted || !_allowEvents || !_matchesActiveMedia) return;
      if (!_isLiveStream && _currentEpisode.playbackSession['isTrial'] == true) {
        unawaited(
          _recoverFromNetdiskTrialOrFailure(_playSession, isTrial: true),
        );
      }
      setState(() {
        if (dur.inMilliseconds > 0) {
          if (dur.inMilliseconds > _lastKnownDurationMs) {
            _lastKnownDurationMs = dur.inMilliseconds;
          }
          _duration =
              (!_isLiveStream && _lastKnownDurationMs > dur.inMilliseconds)
              ? Duration(milliseconds: _lastKnownDurationMs)
              : dur;
        } else if (!_isLiveStream && _lastKnownDurationMs > 0) {
          _duration = Duration(milliseconds: _lastKnownDurationMs);
        } else {
          _duration = dur;
        }
        if (dur > Duration.zero && _loading) {
          _loading = false;
        }
      });
      if (!_isLiveStream && dur > Duration.zero && _pendingResumeMs > 0) {
        final sessionAtSeek = _playSession;
        final maxSeek = math.max(0, dur.inMilliseconds - 2000);
        final targetMs = _pendingResumeMs.clamp(0, maxSeek);
        _pendingResumeMs = 0;
        _introSkippedForSession = true;
        if (targetMs > 0) {
          _lastKnownPositionMs = targetMs;
          _startup.reanchor(Duration(milliseconds: targetMs));
          setState(() {
            _position = Duration(milliseconds: targetMs);
          });
          _player.seek(Duration(milliseconds: targetMs));
          _showHud(
            '已为您续播至 ${_formatDuration(Duration(milliseconds: targetMs))}',
          );
          // Reinforce seek after 550ms in case an HLS stream resets to 0 on initial segment decode
          Future.delayed(const Duration(milliseconds: 550), () {
            if (!mounted || sessionAtSeek != _playSession) return;
            if (_position.inMilliseconds < targetMs - 3000) {
              _player.seek(Duration(milliseconds: targetMs));
            }
          });
        }
      } else if (!_isLiveStream &&
          dur > Duration.zero &&
          !_introSkippedForSession &&
          _skipIntroSec > 0 &&
          dur.inSeconds > _skipIntroSec + 30) {
        _introSkippedForSession = true;
        _startup.reanchor(Duration(seconds: _skipIntroSec));
        _player.seek(Duration(seconds: _skipIntroSec));
        _showHud('已自动跳过片头 ${_skipIntroSec}s');
      }
    }));

    _playerSubscriptions.add(_player.stream.playing.listen((playing) {
      if (mounted && _allowEvents && _matchesActiveMedia) {
        if (playing && widget.site.isEmby && _embySession == null) {
          _openCurrentEpisode(resumeMs: 0);
          return;
        }
        _startup.updateState(playing: playing);
        setState(() {
          _playing = playing;
          if (playing) _loading = false;
        });
        PlaybackWakelock.setEnabled(playing);
        if (!playing) {
          _saveProgress(immediate: true, syncImmediate: false);
        } else if (!_loading && !_buffering) {
          _scheduleHide();
        }
        if (playing || _position > Duration.zero) {
          _embySession?.update(_position.inMilliseconds, !playing, force: true);
        }
      }
    }));

    _playerSubscriptions.add(_player.stream.buffering.listen((buffering) {
      if (mounted && _allowEvents && _matchesActiveMedia) {
        _startup.updateState(buffering: buffering);
        setState(() => _buffering = buffering);
        if (!buffering) {
          _midPlaybackStallTimer?.cancel();
          if (_playing) _scheduleHide();
        } else if (!_isLiveStream &&
            !_loading &&
            !_userSelectedQuality &&
            _startup.isPastStartupWindow &&
            _position.inMilliseconds >= 2500 &&
            _nextFallbackQuality() != null) {
          final now = DateTime.now().millisecondsSinceEpoch;
          _midPlaybackStallEpochsMs.removeWhere((t) => now - t > 22000);
          if (_midPlaybackStallEpochsMs.isEmpty ||
              now - _midPlaybackStallEpochsMs.last >= 700) {
            _midPlaybackStallEpochsMs.add(now);
          }
          if (_midPlaybackStallEpochsMs.length >= 3) {
            _downgradeOnSustainedBuffering(_playSession);
          } else {
            final stallSession = _playSession;
            _midPlaybackStallTimer?.cancel();
            _midPlaybackStallTimer = Timer(const Duration(seconds: 9), () {
              if (mounted && _buffering && stallSession == _playSession) {
                _downgradeOnSustainedBuffering(stallSession);
              }
            });
          }
        }
      }
    }));

    _playerSubscriptions.add(_player.stream.completed.listen((completed) {
      if (completed &&
          mounted &&
          _allowEvents &&
          _matchesActiveMedia &&
          !_outroSkippedForSession) {
        _embySession?.stop(_position.inMilliseconds);
        _embySession = null;
        unawaited(
          _saveProgress(
            completed: true,
            immediate: true,
            syncImmediate: false,
          ),
        );
        _handleEpisodeEnd();
      }
    }));

    _playerSubscriptions.add(_player.stream.error.listen((message) {
      if (mounted &&
          _allowEvents &&
          _matchesActiveMedia &&
          message.isNotEmpty &&
          !_playing &&
          _duration <= Duration.zero &&
          _position <= Duration.zero) {
        _failPlayback();
      }
    }));

    _openCurrentEpisode(resumeMs: widget.initialPositionMs);
    _historyTimer = Timer.periodic(
      const Duration(seconds: 15),
      (_) => _saveProgress(immediate: false),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _saveProgress(immediate: true);
      widget.storage.flushPendingHistory();
      widget.storage.scheduleAutoWebdavSync(immediate: true);
    }
  }

  int _lookupSavedResumeForCurrentEpisode() {
    if (widget.site.isEffectivelyPrivate) return 0;
    for (final entry in widget.storage.getWatchHistory()) {
      if (entry.site == widget.site.key && entry.id == widget.video.id) {
        final target = WoggSource.supports(widget.site)
            ? WoggSource.resolveCachedBookmarkTarget(widget.site,
                CmsVideo(id: widget.video.id, title: widget.video.title, lines: _lines), entry)
            : null;
        final matches = WoggSource.supports(widget.site)
            ? target?.$1 == _lineIndex && target?.$2 == _episodeIndex
            : (entry.line == _currentLine.name && entry.index == _episodeIndex) ||
                entry.episode == _currentEpisode.name;
        if (matches) {
          if (entry.duration > 0) {
            _lastKnownDurationMs = entry.duration;
          }
          return entry.resumePosition;
        }
        break;
      }
    }
    return 0;
  }

  void _handleEpisodeEnd() {
    if (_repeatMode == 'one') {
      if (widget.site.isEmby) {
        _openCurrentEpisode(resumeMs: 0);
        return;
      }
      _player.seek(Duration.zero);
      _player.play();
      _outroSkippedForSession = false;
      return;
    }
    if (_autoNext) {
      if (_episodeIndex < _currentLine.episodes.length - 1) {
        _stepEpisode(1);
      } else if (_repeatMode == 'all' && _currentLine.episodes.isNotEmpty) {
        _saveProgress(immediate: true, syncImmediate: false);
        setState(() => _episodeIndex = 0);
        _openCurrentEpisode(resumeMs: 0);
      }
    }
  }

  int? _recoveringSession;
  Future<bool> _recoverFromNetdiskTrialOrFailure(
    int session, {
    required bool isTrial,
    Object? error,
  }) async {
    if (!mounted || session != _playSession) return true;
    if (_recoveringSession == session) return true;
    _recoveringSession = session;
    try {
      return await _performNetdiskRecovery(
        session,
        isTrial: isTrial,
        error: error,
      );
    } finally {
      if (_recoveringSession == session) _recoveringSession = null;
    }
  }

  CmsEpisode? _nextFallbackQuality() {
    if (_qualityChoices.length <= 1) return null;
    final curIdx = _qualityChoices.indexWhere((v) => v.url == _activeStreamUrl);
    if (curIdx >= 0) {
      for (int i = curIdx + 1; i < _qualityChoices.length; i++) {
        final candidate = _qualityChoices[i];
        if (candidate.url != _activeStreamUrl &&
            !_failedQualityUrls.contains(candidate.url)) {
          return candidate;
        }
      }
    }
    CmsEpisode? best;
    int bestRank = -1;
    for (final candidate in _qualityChoices) {
      if (candidate.url == _activeStreamUrl ||
          _failedQualityUrls.contains(candidate.url)) {
        continue;
      }
      final rank = _rankVariantQuality(candidate);
      if (rank > bestRank) {
        best = candidate;
        bestRank = rank;
      }
    }
    return best;
  }

  Future<bool> _performNetdiskRecovery(
    int session, {
    required bool isTrial,
    Object? error,
  }) async {
    if (!mounted || session != _playSession) return true;
    if (_isLiveStream) return false;
    final currentEpName = _currentEpisode.name.trim();
    final savedResume = isTrial
        ? 0
        : (_position.inMilliseconds >= 1000
              ? _position.inMilliseconds
              : (_pendingResumeMs > 0 ? _pendingResumeMs : _lastKnownPositionMs));

    if (_activeStreamUrl.isNotEmpty) {
      _failedQualityUrls.add(_activeStreamUrl);
    }
    final nextVariant = _nextFallbackQuality();
    final decision = PlaybackRecoveryPolicy.decide(
      episode: _currentEpisode,
      isTrial: isTrial,
      hasNextQuality: nextVariant != null,
    );
    if (decision == PlaybackRecoveryDecision.nextQuality) {
      _showHud(
        error is TimeoutException
            ? '当前画质缓冲过慢，已自动切换至 ${nextVariant!.name}'
            : '已自动切换至 ${nextVariant!.name}',
      );
      await _openCurrentEpisode(resumeMs: savedResume, quality: nextVariant);
      return true;
    }
    if (decision == PlaybackRecoveryDecision.stop) return false;

    if (_lines.length > 1 && _failedLinesForEpisode.length < 6) {
      _failedLinesForEpisode.add(_lineIndex);
      final totalLines = _lines.length;
      for (int pass = 0; pass < 2; pass++) {
        for (int step = 1; step < totalLines; step++) {
          final nextLineIdx = (_lineIndex + step) % totalLines;
          if (_failedLinesForEpisode.contains(nextLineIdx)) continue;
          final nextLine = _lines[nextLineIdx];
          if (nextLine.episodes.isEmpty) continue;
          if (pass == 0 &&
              isTrial &&
              CspBridge.netdiskDriveKeyForLineName(nextLine.name) != null &&
              nextLine.episodes.any((e) => !e.isDirectPlayable)) {
            continue;
          }
          final nextEpIdx = CspBridge.matchEpisodeIndexInLine(
            nextLine,
            currentEpName,
            _episodeIndex,
          );
          final candidateEp = nextLine.episodes[nextEpIdx];
          if (!PlaybackRecoveryPolicy.isAutomaticLineCandidate(candidateEp)) {
            continue;
          }
          if (candidateEp.url == _activeStreamUrl ||
              candidateEp.url == _currentEpisode.url) {
            continue;
          }
          setState(() {
            _lineIndex = nextLineIdx;
            _episodeIndex = nextEpIdx;
            _lastKnownDurationMs = 0;
            _duration = Duration.zero;
          });
          _showHud('已自动切换至 ${_currentLine.name}');
          await _openCurrentEpisode(resumeMs: savedResume);
          return true;
        }
      }
    }
    return false;
  }

  void _downgradeOnSustainedBuffering(int session) {
    if (!mounted ||
        session != _playSession ||
        !_allowEvents ||
        _isLiveStream ||
        _userSelectedQuality) {
      return;
    }
    final nextVariant = _nextFallbackQuality();
    if (nextVariant == null) return;
    _midPlaybackStallTimer?.cancel();
    _midPlaybackStallEpochsMs.clear();
    if (_activeStreamUrl.isNotEmpty) {
      _failedQualityUrls.add(_activeStreamUrl);
    }
    final keepPos = _position.inMilliseconds >= 1000
        ? _position.inMilliseconds
        : _lastKnownPositionMs;
    _showHud('当前码率较高频繁缓冲，已自动切换至 ${nextVariant.name}');
    unawaited(_openCurrentEpisode(resumeMs: keepPos, quality: nextVariant));
  }

  void _failPlayback([Object? error]) {
    if (!mounted) return;
    _startup.cancel();
    _midPlaybackStallTimer?.cancel();
    _midPlaybackStallEpochsMs.clear();
    PlaybackWakelock.setEnabled(false);
    _embySession?.stop(_position.inMilliseconds);
    _embySession = null;
    final cloudError = CmsClient.cloudPlaybackError(_currentEpisode, error);
    if (_isLiveStream &&
        !_startup.isPastStartupWindow &&
        _currentLine.episodes.length > 1 &&
        _failedLiveEpisodes.length < 4) {
      _failedLiveEpisodes.add(_episodeIndex);
      final total = _currentLine.episodes.length;
      for (var step = 1; step < total; step++) {
        final nextIdx = (_episodeIndex + step) % total;
        if (_failedLiveEpisodes.contains(nextIdx)) continue;
        final candidate = _currentLine.episodes[nextIdx];
        if (candidate.url == _activeStreamUrl ||
            candidate.url == _currentEpisode.url) {
          continue;
        }
        setState(() {
          _episodeIndex = nextIdx;
          _lastKnownDurationMs = 0;
          _duration = Duration.zero;
        });
        _showHud('当前线路连接失败，已自动切换至 ${_currentEpisode.name}');
        unawaited(_openCurrentEpisode(resumeMs: 0));
        return;
      }
    }
    if (cloudError.isEmpty &&
        !_isLiveStream &&
        !_startup.isPastStartupWindow &&
        !CmsClient.needsSourceVerification(widget.site, error)) {
      if (_nextFallbackQuality() != null ||
          (_lines.length > 1 && _failedLinesForEpisode.length < 6)) {
        final recoverySession = _playSession;
        unawaited(
          _recoverFromNetdiskTrialOrFailure(
            _playSession,
            isTrial: false,
            error: error,
          ).then((recovered) {
            if (!recovered && mounted && recoverySession == _playSession) {
              setState(() {
                _allowEvents = false;
                _allowHistory = false;
                _loading = false;
                _buffering = false;
                _playing = false;
                _controlsVisible = true;
                _playbackError = error is TimeoutException
                    ? '媒体加载超时，请重试或选择其他画质'
                    : '播放失败，请重试或切换线路';
                _playbackErrorCause = error;
              });
              _player.pause();
            }
          }),
        );
        return;
      }
    }
    setState(() {
      _allowEvents = false;
      _allowHistory = false;
      _loading = false;
      _buffering = false;
      _playing = false;
      _controlsVisible = true;
      _playbackError = cloudError.isNotEmpty
          ? cloudError
          : error is TimeoutException
          ? '媒体加载超时，请重试或选择其他画质'
          : '播放失败，请重试或切换线路';
      _playbackErrorCause = error;
      if (CmsClient.needsSourceVerification(widget.site, error)) {
        _playbackError = '此片源需要完成验证码后继续播放';
      }
    });
    _player.pause();
  }

  Future<void> _changeMedia(int session, Future<void> Function() action) {
    final next = _mediaChanges.then((_) async {
      if (mounted && session == _playSession) await action();
    });
    _mediaChanges = next.catchError((_) {});
    return next;
  }

  Future<void> _openCurrentEpisode({
    int? resumeMs,
    CmsEpisode? quality,
    bool userSelectedQuality = false,
  }) async {
    _startup.reset();
    _midPlaybackStallTimer?.cancel();
    _midPlaybackStallEpochsMs.clear();
    if (quality == null) {
      _userSelectedQuality = false;
    } else if (userSelectedQuality) {
      _userSelectedQuality = true;
    }
    final qualityLease = quality == null ? null : PlayerCloudMediaSession.of(quality);
    final keepsLease = _cloudMedia.owns(qualityLease);
    // Quality variants of one cloud file share their proxy and cancellation
    // owner. Cancelling that owner here would revoke the next quality as well.
    if (!keepsLease && _sourceAbort?.isCompleted == false) _sourceAbort!.complete();
    final sourceAbort = keepsLease && _sourceAbort != null
        ? _sourceAbort!
        : (_sourceAbort = Completer<void>());
    final session = ++_playSession;
    if (quality == null) {
      _qualityChoices = const [];
      _failedQualityUrls.clear();
    }
    _embySession?.stop(_position.inMilliseconds);
    _embySession = null;
    _allowHistory = false;
    _allowEvents = false;
    _playbackError = '';
    _playbackErrorCause = null;
    try {
      await _playerConfiguration;
      await _changeMedia(session, () async {
        await _player.stop();
        await _cloudMedia.releaseUnless(qualityLease);
        await _localMedia.releaseUnless(null);
      });
    } catch (_) {
      if (session == _playSession) _failPlayback();
      return;
    }
    if (!mounted || session != _playSession) return;
    final effectiveResumeMs = _isLiveStream
        ? 0
        : (resumeMs != null && resumeMs > 0)
            ? resumeMs
            : (resumeMs == null ? _lookupSavedResumeForCurrentEpisode() : 0);
    _pendingResumeMs = effectiveResumeMs > 0 ? effectiveResumeMs : 0;
    _lastKnownPositionMs = _pendingResumeMs;
    _lastKnownDurationMs = 0;
    if (!_isLiveStream) _lookupSavedResumeForCurrentEpisode();
    _introSkippedForSession = _pendingResumeMs > 0;
    _outroSkippedForSession = false;
    _initialHistoryRecorded = false;

    final configuredParses =
        widget.storage.loadSavedConfig()?.parses ?? const [];
    final canOpenDirectly = _isLiveStream
        ? (_currentEpisode.isLocalFile ||
            const {'http', 'https', 'rtmp', 'rtsp'}.contains(
              Uri.tryParse(_currentEpisode.url.trim())?.scheme.toLowerCase(),
            ))
        : _currentEpisode.isDirectPlayable;
    final unavailableReason = _isLiveStream
        ? (canOpenDirectly ? null : '当前直播源地址格式不受支持，请切换线路')
        : WebMediaResolver.episodeUnavailableReason(
            _currentEpisode,
            site: widget.site,
            parses: configuredParses,
          );
    if (!canOpenDirectly &&
        !_currentEpisode.needsSourceResolution &&
        unavailableReason != null) {
      _pendingResumeMs = 0;
      if (mounted) {
        setState(() {
          _loading = false;
          _playing = false;
          _position = Duration.zero;
          _duration = Duration.zero;
          _playbackError = unavailableReason;
          _controlsVisible = true;
        });
      }
      return;
    }

    if (mounted) {
      setState(() {
        _loading = true;
        _videoWidth = 0;
        _videoHeight = 0;
        _videoCodec = '';
        _audioCodec = '';
        _activeStreamUrl = _currentEpisode.url;
        _position = _pendingResumeMs > 0
            ? Duration(milliseconds: _pendingResumeMs)
            : Duration.zero;
        _duration = Duration.zero;
      });
    }

    CloudMediaLease? pendingLease;
    LocalMediaLease? pendingLocalLease;
    try {
      var resolvedEpisode = quality ?? (_currentEpisode.isLocalFile
          ? _currentEpisode
          : widget.isLive
          ? _client.resolveLiveEpisodeForPlayback(widget.site, _currentEpisode)
          : await _client.runSourceOperation<CmsEpisode>(
              () async {
                final result = await _client.resolveEpisodeForPlayback(
                  widget.site,
                  _currentEpisode,
                  parses: configuredParses,
                );
                if (!mounted || session != _playSession || sourceAbort.isCompleted) {
                  await _cloudMedia.discard(PlayerCloudMediaSession.of(result));
                  throw StateError('片源加载已取消');
                }
                return result;
              },
              cancellation: sourceAbort,
            ).timeout(const Duration(seconds: 90), onTimeout: () {
              if (!sourceAbort.isCompleted) sourceAbort.complete();
              throw const FormatException('片源解析超时，请重试');
            }));
      pendingLease = PlayerCloudMediaSession.of(resolvedEpisode);
      if (quality == null &&
          resolvedEpisode.variants.length > 1 &&
          widget.storage.preferredQuality == '4k_netdisk') {
        resolvedEpisode = _selectBestQualityVariant(resolvedEpisode);
      }
      EmbyPlaybackSession? report;
      if (widget.site.isEmby && resolvedEpisode.playbackSession.isNotEmpty) {
        report = (await EmbyLibrary.open(widget.site)).track(resolvedEpisode);
      }
      if (!mounted || session != _playSession) {
        report?.stop();
        await _cloudMedia.discard(pendingLease);
        return;
      }
      _embySession = report;
      if (quality == null) _qualityChoices = resolvedEpisode.variants;
      final rawResolvedUrl = resolvedEpisode.url;
      final safePlayUrl = (rawResolvedUrl.startsWith('http://') ||
                  rawResolvedUrl.startsWith('https://')) &&
              RegExp(r'[^\x00-\x7F]').hasMatch(rawResolvedUrl)
          ? Uri.encodeFull(rawResolvedUrl)
          : rawResolvedUrl;
      final baseMedia = widget.mediaForPlayback(
        resolvedEpisode,
        start: _pendingResumeMs > 0
            ? Duration(milliseconds: _pendingResumeMs)
            : null,
      );
      final headers = Map<String, String>.of(baseMedia.httpHeaders ?? const {});
      if (!headers.keys.any((k) => k.toLowerCase() == 'user-agent')) {
        headers['User-Agent'] =
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';
      }
      final parsedTargetUri = Uri.tryParse(safePlayUrl);
      if (pendingLease == null &&
          parsedTargetUri != null &&
          LocalMediaLease.shouldProxy(parsedTargetUri)) {
        pendingLocalLease = await LocalMediaLease.open(
          target: parsedTargetUri,
          headers: headers,
          isCancelled: () => !mounted || session != _playSession,
        );
      }
      if (!mounted || session != _playSession) {
        report?.stop();
        await _cloudMedia.discard(pendingLease);
        await _localMedia.discard(pendingLocalLease);
        return;
      }
      var effectiveAudioUrl = resolvedEpisode.externalAudioUrl;
      if (pendingLocalLease != null && effectiveAudioUrl.isNotEmpty) {
        final proxiedAudio =
            pendingLocalLease.tryRegisterCompanionMedia(effectiveAudioUrl);
        if (proxiedAudio != null) {
          effectiveAudioUrl = proxiedAudio.toString();
        }
      }
      final effectiveOpenUrl = pendingLocalLease?.url.toString() ?? safePlayUrl;
      final effectiveOpenHeaders =
          pendingLocalLease != null ? const <String, String>{} : headers;
      _activeStreamUrl = safePlayUrl;
      _activeMediaUri = Media(effectiveOpenUrl).uri;

      await _changeMedia(session, () async {
        _cloudMedia.adopt(pendingLease);
        _localMedia.adopt(pendingLocalLease);
        _allowEvents = true;
        final hasFallback = _isLiveStream
            ? (_currentLine.episodes.length > 1 &&
                _failedLiveEpisodes.length <
                    math.min(_currentLine.episodes.length - 1, 4))
            : (_nextFallbackQuality() != null ||
                (PlaybackRecoveryPolicy.decide(
                          episode: _currentEpisode,
                          isTrial: false,
                          hasNextQuality: false,
                        ) ==
                        PlaybackRecoveryDecision.alternateLine &&
                    _lines.length > 1 &&
                    _failedLinesForEpisode.length < 6));
        _startup.waitForProgress(
          () {
            if (mounted && session == _playSession && _allowEvents) {
              _failPlayback(TimeoutException('media startup'));
              _changeMedia(session, _player.stop).catchError((_) {});
            }
          },
          hasFallback: hasFallback,
          startOffset: _pendingResumeMs > 0
              ? Duration(milliseconds: _pendingResumeMs)
              : Duration.zero,
        );
        try {
          final dyn = _player.platform as dynamic;
          await dyn.setProperty('tls-verify', 'yes');
          final ua = headers.entries
              .firstWhere(
                (e) => e.key.toLowerCase() == 'user-agent',
                orElse: () => const MapEntry('User-Agent', ''),
              )
              .value;
          if (ua.isNotEmpty) {
            await dyn.setProperty('user-agent', ua);
          }
          final ref = pendingLocalLease != null
              ? ''
              : headers.entries
                  .firstWhere(
                    (e) => e.key.toLowerCase() == 'referer',
                    orElse: () => const MapEntry('Referer', ''),
                  )
                  .value;
          await dyn.setProperty('referrer', ref);
        } catch (_) {}
        await _player.open(
          Media(
            effectiveOpenUrl,
            httpHeaders: effectiveOpenHeaders,
            start: baseMedia.start,
          ),
          play: true,
        );
        if (effectiveAudioUrl.isNotEmpty) {
          await _player.setAudioTrack(AudioTrack.uri(effectiveAudioUrl));
        }
      });
      if (!mounted || session != _playSession || !_allowEvents) {
        await _cloudMedia.discard(pendingLease);
        await _localMedia.discard(pendingLocalLease);
        return;
      }
      _allowHistory = true;
      await _player.setRate(_isLiveStream ? 1.0 : _normalSpeed);
      if (!mounted || session != _playSession) return;
      _scheduleHide();
    } catch (error) {
      await _cloudMedia.discard(pendingLease);
      await _localMedia.discard(pendingLocalLease);
      if (mounted && session == _playSession) _failPlayback(error);
    }
  }

  static String _formatClockNow() {
    final now = DateTime.now();
    return '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
  }

  Future<void> _saveProgress({
    bool completed = false,
    bool immediate = false,
    bool triggerSync = true,
    bool? syncImmediate,
  }) async {
    if (!_allowHistory ||
        _isLiveStream ||
        widget.site.key == 'live' ||
        widget.site.isEffectivelyPrivate) {
      return;
    }
    final livePosMs = _position.inMilliseconds;
    final effectiveDurMs = _duration.inMilliseconds > 0
        ? _duration.inMilliseconds
        : _lastKnownDurationMs;
    final rawPosMs = _pendingResumeMs > 0
        ? _pendingResumeMs
        : (livePosMs >= 1000
              ? livePosMs
              : (_lastKnownPositionMs > 0 ? _lastKnownPositionMs : livePosMs));
    final effectivePosMs = completed
        ? (effectiveDurMs > 0 ? effectiveDurMs : math.max(1000, rawPosMs))
        : rawPosMs;
    if (effectiveDurMs <= 0 && effectivePosMs <= 0) {
      return;
    }
    var resolvedPoster = widget.video.poster.trim();
    if (resolvedPoster.isEmpty) {
      for (final existing in widget.storage.getWatchHistory()) {
        if ((existing.site == widget.site.key &&
                existing.id == widget.video.id) ||
            existing.title == widget.video.title) {
          if (existing.poster.trim().isNotEmpty) {
            resolvedPoster = existing.poster.trim();
            break;
          }
        }
      }
    }
    await widget.storage.upsertWatchHistory(
      WatchHistoryEntry(
        site: widget.site.key,
        id: widget.video.id,
        title: widget.video.title,
        poster: resolvedPoster,
        line: _currentLine.name,
        episode: _currentEpisode.name,
        index: _episodeIndex,
        position: effectivePosMs,
        duration: effectiveDurMs,
        updated: DateTime.now().millisecondsSinceEpoch,
      ),
      immediate: immediate,
      triggerSync: triggerSync,
      syncImmediate: syncImmediate,
    );
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    if (_screenLocked) return;
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted &&
          !_screenLocked &&
          _playing &&
          !_loading &&
          !_buffering &&
          _playbackError.isEmpty) {
        setState(() => _controlsVisible = false);
      }
    });
  }

  void _scheduleLockHide() {
    _lockHideTimer?.cancel();
    _lockHideTimer = Timer(const Duration(milliseconds: 3500), () {
      if (mounted && _screenLocked && _lockButtonVisible) {
        setState(() => _lockButtonVisible = false);
      }
    });
  }

  void _revealLockedHint({bool showToast = true}) {
    if (!_playerFocusNode.hasFocus) {
      _playerFocusNode.requestFocus();
    }
    setState(() => _lockButtonVisible = true);
    _scheduleLockHide();
    if (showToast) {
      _showHud('屏幕已锁定 · 点击解锁按钮恢复操作');
    }
  }

  void _onLockedSurfaceTap() {
    if (!_playerFocusNode.hasFocus) {
      _playerFocusNode.requestFocus();
    }
    final nextVisible = !_lockButtonVisible;
    setState(() {
      _lockButtonVisible = nextVisible;
      if (!nextVisible && _hudText.contains('锁定')) {
        _hudText = '';
      }
    });
    if (nextVisible) {
      _scheduleLockHide();
    } else {
      _lockHideTimer?.cancel();
    }
  }

  void _setScreenLocked(bool locked) {
    if (_screenLocked == locked) return;
    _hideTimer?.cancel();
    _lockHideTimer?.cancel();
    WindowsImmersiveFrame.interactionLocked.value = locked;
    if (locked) {
      if (_speedBoosting) {
        _player.setRate(_normalSpeed);
      }
      setState(() {
        _screenLocked = true;
        _controlsVisible = false;
        _lockButtonVisible = true;
        _speedBoosting = false;
        _isDraggingSeek = false;
        _isSliderDragging = false;
        _isVerticalDragging = false;
      });
      if (!_playerFocusNode.hasFocus) {
        _playerFocusNode.requestFocus();
      }
      _showHud('已锁定屏幕 · 防误触开启');
      _scheduleLockHide();
    } else {
      setState(() {
        _screenLocked = false;
        _lockButtonVisible = false;
        _controlsVisible = true;
      });
      if (!_playerFocusNode.hasFocus) {
        _playerFocusNode.requestFocus();
      }
      _showHud('已解锁屏幕');
      _scheduleHide();
    }
  }

  void _toggleControls() {
    if (_screenLocked) {
      _onLockedSurfaceTap();
      return;
    }
    if (!_playerFocusNode.hasFocus) {
      _playerFocusNode.requestFocus();
    }
    setState(() => _controlsVisible = !_controlsVisible);
    if (_controlsVisible) _scheduleHide();
  }

  void _onPointerMove(Offset delta) {
    if (!_desktop || delta.distanceSquared < 0.25) return;
    if (_screenLocked) {
      if (!_lockButtonVisible) {
        setState(() => _lockButtonVisible = true);
        _lastPointerScheduleMs = DateTime.now().millisecondsSinceEpoch;
        _scheduleLockHide();
        return;
      }
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - _lastPointerScheduleMs >= 250) {
        _lastPointerScheduleMs = now;
        _scheduleLockHide();
      }
      return;
    }
    if (!_controlsVisible) {
      setState(() => _controlsVisible = true);
      _lastPointerScheduleMs = DateTime.now().millisecondsSinceEpoch;
      _scheduleHide();
      return;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastPointerScheduleMs >= 250) {
      _lastPointerScheduleMs = now;
      _scheduleHide();
    }
  }

  void _windowChanged() {
    if (mounted) setState(() {});
  }

  void _windowError(Object error) {
    debugPrint('Player fullscreen failed: $error');
    if (mounted) _showHud('窗口切换失败，请重试');
  }

  String _fullscreenLabel(bool isLandscape) => _desktop
      ? (_desktopWindow?.fullscreen == true ? '退出全屏' : '全屏')
      : (isLandscape ? '竖屏' : '全屏');

  Future<void> _desktopEscape() async {
    try {
      final exited = await _desktopWindow!.exitFullscreen();
      if (!exited) {
        await _saveProgress(immediate: true);
        if (mounted) Navigator.of(context).maybePop();
      }
    } catch (error) {
      _windowError(error);
    }
  }

  Future<void> _toggleOrientation() async {
    if (_desktop) {
      try {
        await _desktopWindow!.toggle();
        if (mounted) _scheduleHide();
      } catch (error) {
        _windowError(error);
      }
      return;
    }
    final size = MediaQuery.sizeOf(context);
    final currentlyLandscape = size.width > size.height;
    try {
      final applied = await _mobileChrome.setLandscape(!currentlyLandscape);
      if (!mounted || !applied) return;
      _showHud(currentlyLandscape ? '已切换为竖屏观看' : '已切换为全屏横屏观看');
      _scheduleHide();
    } catch (error) {
      _windowError(error);
    }
  }

  void _stepEpisode(int delta) {
    final next = _episodeIndex + delta;
    if (next < 0 || next >= _currentLine.episodes.length) return;
    _saveProgress(immediate: true, syncImmediate: false);
    _failedLinesForEpisode.clear();
    _failedLiveEpisodes.clear();
    setState(() => _episodeIndex = next);
    _openCurrentEpisode(resumeMs: 0);
  }

  void _seekRelative(int seconds) {
    if (_duration.inMilliseconds <= 0) return;
    final targetMs = (_position.inMilliseconds + seconds * 1000).clamp(
      0,
      _duration.inMilliseconds,
    );
    setState(() => _position = Duration(milliseconds: targetMs));
    _player.seek(Duration(milliseconds: targetMs));
    _saveProgress(immediate: true, triggerSync: false);
    _showHud(
      '${seconds >= 0 ? "快进" : "快退"} ${_formatDuration(Duration(milliseconds: targetMs))}',
    );
    _scheduleHide();
  }

  void _showHud(String text) {
    if (!mounted) return;
    _hudTimer?.cancel();
    setState(() => _hudText = text);
    _hudTimer = Timer(const Duration(milliseconds: 1100), () {
      if (mounted && !_speedBoosting && _hudText == text) {
        setState(() => _hudText = '');
      }
    });
  }

  String _formatDuration(Duration d) {
    final totalSeconds = d.inSeconds < 0 ? 0 : d.inSeconds;
    final h = totalSeconds ~/ 3600;
    final m = (totalSeconds % 3600) ~/ 60;
    final s = totalSeconds % 60;
    if (h > 0) {
      return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  String get _fitLabel {
    if (_fit == BoxFit.cover) return '裁切';
    if (_fit == BoxFit.fill) return '铺满';
    return '适应';
  }

  String get _repeatLabel {
    if (_repeatMode == 'one') return '单集';
    if (_repeatMode == 'all') return '列表';
    return '关闭';
  }

  String get _kernelShortLabel => switch (_playerKernel) {
    'ijk' => '兼容',
    'mpv' => '大缓冲',
    _ => '均衡',
  };

  double _desktopScale(Size size) {
    if (!_desktop || size.width <= 1200) return 1.0;
    return (1.0 + (size.width - 1200) / 1400.0).clamp(1.0, 1.38);
  }

  static String _hardwareDecoder(String kernel) {
    if (Platform.isIOS || Platform.isMacOS) {
      return kernel == 'exo' ? 'videotoolbox' : 'auto-safe';
    }
    if (Platform.isWindows) {
      return kernel == 'ijk' ? 'd3d11va-copy' : 'auto-safe';
    }
    return switch (kernel) {
      'ijk' => 'auto-copy',
      'mpv' => 'auto-safe',
      _ => 'auto',
    };
  }

  static const String _baseLavfOptions =
      'seg_max_retry=5,strict=experimental,allowed_extensions=ALL,'
      'protocol_whitelist=[udp,rtp,tcp,tls,data,file,http,https,crypto]';

  Future<void> _applyPlayerKernel(String kernel) async {
    try {
      final dyn = _player.platform as dynamic;
      await dyn.setProperty('tls-verify', 'yes');
      await dyn.setProperty('hwdec', _hardwareDecoder(kernel));
      await dyn.setProperty('cache-on-disk', 'no');
      await dyn.setProperty('cache-pause', 'yes');
      await dyn.setProperty('cache-pause-initial', 'no');
      await dyn.setProperty(
        'cache-pause-wait',
        _isLiveStream ? '1' : (kernel == 'mpv' ? '5' : '4'),
      );
      if (Platform.isWindows) {
        await dyn.setProperty('vd-lavc-threads', '0');
        await dyn.setProperty('vd-lavc-dr', 'yes');
        await dyn.setProperty('scale', 'bilinear');
        await dyn.setProperty('cscale', 'bilinear');
        await dyn.setProperty('dscale', 'bilinear');
        await dyn.setProperty('correct-downscaling', 'no');
        await dyn.setProperty('linear-downscaling', 'no');
        await dyn.setProperty('sigmoid-upscaling', 'no');
        await dyn.setProperty('dither-depth', 'no');
        await dyn.setProperty('hdr-compute-peak', 'no');
      }
      switch (kernel) {
        case 'ijk':
          await dyn.setProperty('cache', 'yes');
          await dyn.setProperty(
            'demuxer-max-bytes',
            _desktop ? '134217728' : '67108864',
          );
          await dyn.setProperty(
            'demuxer-max-back-bytes',
            _desktop ? '33554432' : '16777216',
          );
          await dyn.setProperty('demuxer-readahead-secs', '30');
          await dyn.setProperty('network-timeout', '25');
          await dyn.setProperty(
            'demuxer-lavf-o',
            '$_baseLavfOptions,reconnect=1,reconnect_delay_max=5,analyzeduration=2000000,probesize=2000000',
          );
          break;
        case 'mpv':
          await dyn.setProperty('cache', 'yes');
          await dyn.setProperty(
            'demuxer-max-bytes',
            (Platform.isWindows || Platform.isLinux)
                ? '536870912'
                : (Platform.isMacOS ? '268435456' : '134217728'),
          );
          await dyn.setProperty(
            'demuxer-max-back-bytes',
            _desktop ? '134217728' : '33554432',
          );
          await dyn.setProperty(
            'demuxer-readahead-secs',
            _desktop ? '90' : '45',
          );
          await dyn.setProperty('network-timeout', '25');
          await dyn.setProperty(
            'demuxer-lavf-o',
            '$_baseLavfOptions,reconnect=1,reconnect_delay_max=4',
          );
          break;
        case 'exo':
        default:
          await dyn.setProperty('cache', 'yes');
          await dyn.setProperty(
            'demuxer-max-bytes',
            (Platform.isWindows || Platform.isLinux)
                ? '268435456'
                : (Platform.isMacOS
                      ? '134217728'
                      : (Platform.isIOS ? '33554432' : '67108864')),
          );
          await dyn.setProperty(
            'demuxer-max-back-bytes',
            _desktop ? '67108864' : '16777216',
          );
          await dyn.setProperty(
            'demuxer-readahead-secs',
            _desktop ? '45' : '20',
          );
          await dyn.setProperty('network-timeout', '20');
          await dyn.setProperty(
            'demuxer-lavf-o',
            '$_baseLavfOptions,reconnect=1,reconnect_delay_max=4',
          );
          break;
      }
    } catch (_) {}
  }

  static int _rankVariantQuality(CmsEpisode v) {
    final lower = '${v.name} ${v.url}'.toLowerCase();
    if (lower.contains('原画') || lower.contains('raw') || lower.contains('original')) {
      return 100;
    }
    if (lower.contains('4k') || lower.contains('2160') || lower.contains('uhd')) {
      return 90;
    }
    if (lower.contains('2k') || lower.contains('1440')) {
      return 80;
    }
    if (lower.contains('蓝光') || lower.contains('高码') || lower.contains('hdr')) {
      return 75;
    }
    if (lower.contains('超清') || lower.contains('super') || lower.contains('1080')) {
      return 60;
    }
    if (lower.contains('高清') || lower.contains('high') || lower.contains('720')) {
      return 40;
    }
    if (lower.contains('标清') || lower.contains('low') || lower.contains('480')) {
      return 20;
    }
    return 10;
  }

  CmsEpisode _selectBestQualityVariant(CmsEpisode resolved) {
    if (resolved.variants.isEmpty) return resolved;
    CmsEpisode best = resolved.variants.first;
    int bestRank = _rankVariantQuality(best);
    for (final v in resolved.variants.skip(1)) {
      final r = _rankVariantQuality(v);
      if (r > bestRank) {
        best = v;
        bestRank = r;
      }
    }
    if (best.url == resolved.url) return resolved;
    return CmsEpisode(
      name: resolved.name,
      url: best.url,
      headers: best.headers,
      variants: resolved.variants,
      externalAudioUrl: best.externalAudioUrl.isNotEmpty
          ? best.externalAudioUrl
          : resolved.externalAudioUrl,
      playbackSession: resolved.playbackSession,
    );
  }

  String get _videoSpecsLabel {
    final parts = <String>[];
    if (_videoWidth > 0 && _videoHeight > 0) {
      final maxDim = math.max(_videoWidth, _videoHeight);
      final minDim = math.min(_videoWidth, _videoHeight);
      final tier = (maxDim >= 3800 || minDim >= 2100)
          ? '4K '
          : (maxDim >= 2500 || minDim >= 1400)
          ? '2K '
          : (maxDim >= 1900 || minDim >= 1000)
          ? '1080P '
          : (maxDim >= 1200 || minDim >= 700)
          ? '720P '
          : '';
      parts.add('$tier$_videoWidth × $_videoHeight');
    }
    final vc = _videoCodec.toLowerCase();
    if (vc.isNotEmpty) {
      if (vc.contains('hevc') ||
          vc.contains('h265') ||
          vc.contains('hev1')) {
        parts.add('HEVC');
      } else if (vc.contains('avc') || vc.contains('h264')) {
        parts.add('H.264');
      } else if (vc.contains('av01') || vc.contains('av1')) {
        parts.add('AV1');
      } else if (vc.contains('vp9')) {
        parts.add('VP9');
      } else {
        parts.add(_videoCodec.toUpperCase());
      }
    }
    final ac = _audioCodec.toLowerCase();
    if (ac.isNotEmpty) {
      if (ac.contains('eac3') || ac.contains('ec-3')) {
        parts.add('EAC3');
      } else if (ac.contains('ac3') || ac.contains('ac-3')) {
        parts.add('AC3');
      } else if (ac.contains('aac') || ac.contains('mp4a')) {
        parts.add('AAC');
      } else if (ac.contains('flac')) {
        parts.add('FLAC');
      } else if (ac.contains('opus')) {
        parts.add('OPUS');
      }
    }
    final hint = '${_activeStreamUrl.split('?').first} ${_currentEpisode.name}'
        .toLowerCase();
    if (hint.contains('.mkv')) {
      parts.add('MKV');
    } else if (hint.contains('.mp4')) {
      parts.add('MP4');
    } else if (hint.contains('.m3u8')) {
      parts.add('HLS');
    } else if (hint.contains('.flv')) {
      parts.add('FLV');
    } else if (hint.contains('.ts')) {
      parts.add('TS');
    }
    return parts.join(' · ');
  }

  @override
  void dispose() {
    WindowsImmersiveFrame.interactionLocked.value = false;
    _lockHideTimer?.cancel();
    _hudTimer?.cancel();
    for (final sub in _playerSubscriptions) {
      unawaited(sub.cancel());
    }
    _playerSubscriptions.clear();
    _playerFocusNode.dispose();
    _portraitToolsScrollController.dispose();
    _startup.cancel();
    _midPlaybackStallTimer?.cancel();
    PlaybackWakelock.setEnabled(false);
    if (_sourceAbort?.isCompleted == false) _sourceAbort!.complete();
    WidgetsBinding.instance.removeObserver(this);
    _hideTimer?.cancel();
    _historyTimer?.cancel();
    _clockTimer?.cancel();
    _saveProgress(immediate: true);
    widget.storage.flushPendingHistory();
    widget.storage.scheduleAutoWebdavSync(immediate: true);
    _embySession?.stop(_position.inMilliseconds);
    _embySession = null;
    _mobileChrome.close().catchError((Object error) {
      debugPrint('Player system UI restore failed: $error');
    });
    _allowEvents = false;
    _desktopWindow?.removeListener(_windowChanged);
    _desktopWindow?.close().catchError((Object error) {
      debugPrint('Player window restore failed: $error');
    });
    final releaseSource = _releaseSourceSession;
    _releaseSourceSession = null;
    final cloudLease = _cloudMedia.detach();
    final localLease = _localMedia.detach();
    _mediaChanges.whenComplete(() async {
      try {
        await _player.dispose();
      } finally {
        try {
          await cloudLease?.close();
        } finally {
          try {
            await localLease?.close();
          } finally {
            releaseSource?.call();
          }
        }
      }
    });
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_screenLocked,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) {
          unawaited(_saveProgress(immediate: true));
          return;
        }
        if (_screenLocked) {
          _revealLockedHint();
        }
      },
      child: Scaffold(
      backgroundColor: Colors.black,
      body: Focus(
        focusNode: _playerFocusNode,
        autofocus: true,
        onKeyEvent: (node, event) {
          if (_screenLocked) {
            if (event is KeyDownEvent || event is KeyRepeatEvent) {
              _revealLockedHint();
            }
            return KeyEventResult.handled;
          }
          if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
            return KeyEventResult.ignored;
          }
          final isCtrlOrCmd = HardwareKeyboard.instance.isControlPressed ||
              HardwareKeyboard.instance.isMetaPressed;
          if (isCtrlOrCmd && event.logicalKey == LogicalKeyboardKey.keyW) {
            unawaited(
              _saveProgress(immediate: true).whenComplete(() {
                if (context.mounted) Navigator.of(context).maybePop();
              }),
            );
            return KeyEventResult.handled;
          }
          if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
            _seekRelative(15);
            return KeyEventResult.handled;
          }
          if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
            _seekRelative(-15);
            return KeyEventResult.handled;
          }
          if (event.logicalKey == LogicalKeyboardKey.arrowUp ||
              event.logicalKey == LogicalKeyboardKey.arrowDown) {
            final volume =
                (_player.state.volume +
                        (event.logicalKey == LogicalKeyboardKey.arrowUp
                            ? 5
                            : -5))
                    .clamp(0.0, 100.0);
            _player.setVolume(volume);
            _showHud('音量 ${volume.round()}%');
            return KeyEventResult.handled;
          }
          if (event.logicalKey == LogicalKeyboardKey.bracketLeft ||
              event.logicalKey == LogicalKeyboardKey.bracketRight) {
            final delta = event.logicalKey == LogicalKeyboardKey.bracketRight
                ? 0.25
                : -0.25;
            final newSpeed = double.parse(
              ((_normalSpeed + delta).clamp(
                StorageService.minPlaySpeed,
                StorageService.maxPlaySpeed,
              )).toStringAsFixed(2),
            );
            setState(() => _normalSpeed = newSpeed);
            _player.setRate(newSpeed);
            widget.storage.setPlaySpeed(newSpeed);
            final speedLabel =
                newSpeed.toString().replaceAll(RegExp(r'\.0$'), '');
            _showHud('倍速 ${speedLabel}x');
            return KeyEventResult.handled;
          }
          if (event is! KeyDownEvent) return KeyEventResult.ignored;
          if (event.logicalKey == LogicalKeyboardKey.keyM) {
            if (_player.state.volume > 0) {
              _previousVolume = _player.state.volume;
              _player.setVolume(0);
              _showHud('静音');
            } else {
              final restore = _previousVolume > 0 ? _previousVolume : 100.0;
              _player.setVolume(restore);
              _showHud('音量 ${restore.round()}%');
            }
            return KeyEventResult.handled;
          }
          if (event.logicalKey == LogicalKeyboardKey.keyN ||
              event.logicalKey == LogicalKeyboardKey.pageDown) {
            _stepEpisode(1);
            return KeyEventResult.handled;
          }
          if (event.logicalKey == LogicalKeyboardKey.keyP ||
              event.logicalKey == LogicalKeyboardKey.pageUp) {
            _stepEpisode(-1);
            return KeyEventResult.handled;
          }
          if (event.logicalKey == LogicalKeyboardKey.space ||
              event.logicalKey == LogicalKeyboardKey.enter ||
              event.logicalKey == LogicalKeyboardKey.select) {
            _player.playOrPause();
            setState(() => _controlsVisible = true);
            _scheduleHide();
            return KeyEventResult.handled;
          }
          if (event.logicalKey == LogicalKeyboardKey.keyF ||
              (_desktop && event.logicalKey == LogicalKeyboardKey.f11)) {
            _toggleOrientation();
            return KeyEventResult.handled;
          }
          if (event.logicalKey == LogicalKeyboardKey.escape) {
            if (_desktop) {
              _desktopEscape();
            } else {
              unawaited(
                _saveProgress(immediate: true).whenComplete(() {
                  if (context.mounted) Navigator.of(context).maybePop();
                }),
              );
            }
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: MouseRegion(
          cursor: _desktop &&
                  (_screenLocked ? !_lockButtonVisible : !_controlsVisible) &&
                  _playing
              ? SystemMouseCursors.none
              : SystemMouseCursors.basic,
          onHover: (event) => _onPointerMove(event.delta),
          child: Listener(
            onPointerMove: (event) => _onPointerMove(event.delta),
            child: PlayerInteractionLayers(
              controls: Stack(
                fit: StackFit.expand,
                children: [
                  if (_alwaysShowClock)
                    Positioned.fill(
                      child: IgnorePointer(
                        child: SafeArea(
                          child: Align(
                            alignment: Alignment.topRight,
                            child: AnimatedPadding(
                              duration: const Duration(milliseconds: 200),
                              curve: Curves.easeOutCubic,
                              padding: EdgeInsets.only(
                                top: defaultTargetPlatform ==
                                            TargetPlatform.macOS &&
                                        !(_desktopWindow?.fullscreen ?? false)
                                    ? 38
                                    : 12,
                                right: (!_screenLocked &&
                                        _controlsVisible &&
                                        MediaQuery.sizeOf(context).width >
                                            MediaQuery.sizeOf(context).height)
                                    ? 76
                                    : 16,
                              ),
                              child: Container(
                                key: const Key('player-persistent-clock'),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 4.5,
                                ),
                                decoration: BoxDecoration(
                                  color: const Color(0x88101218),
                                  borderRadius: BorderRadius.circular(999),
                                  border: Border.all(
                                    color: const Color(0x2EFFFFFF),
                                    width: 0.6,
                                  ),
                                ),
                                child: Text(
                                  _clockText.isEmpty
                                      ? _formatClockNow()
                                      : _clockText,
                                  style: const TextStyle(
                                    color: Color(0xEBFFFFFF),
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w600,
                                    fontFeatures: [
                                      FontFeature.tabularFigures(),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  if (_controlsVisible && !_screenLocked)
                    _buildAppleChromeOverlay(context),
                  if (_screenLocked && _lockButtonVisible)
                    _buildLockedOverlay(context),
                  if (_playbackError.isNotEmpty && !_screenLocked)
                    Center(
                      child: AppleGlassSurface(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 22,
                          vertical: 18,
                        ),
                        borderRadius: BorderRadius.circular(22),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              CupertinoIcons.exclamationmark_circle_fill,
                              color: AppleColors.systemOrange,
                              size: 28,
                            ),
                            const SizedBox(height: 10),
                            Text(
                              _playbackError,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: AppleColors.labelPrimary,
                                fontSize: 14.5,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 14),
                            if (CmsClient.needsSourceVerification(
                              widget.site,
                              _playbackErrorCause,
                            )) ...[
                              SourceVerificationButton(
                                key: ValueKey('verification-$_playSession'),
                                client: _client,
                                site: widget.site,
                                onVerified: () => _openCurrentEpisode(
                                  resumeMs: _pendingResumeMs,
                                ),
                              ),
                              const SizedBox(height: 8),
                            ],
                            Wrap(
                              spacing: 10,
                              runSpacing: 8,
                              alignment: WrapAlignment.center,
                              children: [
                                AppleCapsuleButton(
                                  label: '重试播放',
                                  icon: CupertinoIcons.refresh,
                                  primary: true,
                                  compact: true,
                                  onPressed: () {
                                    _failedLinesForEpisode.clear();
    _failedLiveEpisodes.clear();
                                    _failedQualityUrls.clear();
                                    _openCurrentEpisode();
                                  },
                                ),
                                if (_qualityChoices.length > 1)
                                  AppleCapsuleButton(
                                    label: '切换画质 (${_qualityChoices.length})',
                                    icon: CupertinoIcons.sparkles,
                                    compact: true,
                                    onPressed: _showQualityChoices,
                                  ),
                                if (_lines.length > 1)
                                  AppleCapsuleButton(
                                    label: '切换线路 (${_lines.length})',
                                    icon: CupertinoIcons.layers_alt_fill,
                                    compact: true,
                                    onPressed: _showLinesSheet,
                                  ),
                                AppleCapsuleButton(
                                  label: '网盘扫码配置',
                                  icon: CupertinoIcons.qrcode_viewfinder,
                                  compact: true,
                                  onPressed: () => showNetdiskAccountSheet(
                                    context,
                                    widget.storage,
                                    initialDriveKey:
                                        _currentEpisode.cloudProvider,
                                    onChanged: () {
                                      if (mounted) {
                                        _failedLinesForEpisode.clear();
    _failedLiveEpisodes.clear();
                                        _failedQualityUrls.clear();
                                        _openCurrentEpisode();
                                      }
                                    },
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
              surface: GestureDetector(
              behavior: HitTestBehavior.opaque,
          onTap: _toggleControls,
          onDoubleTap: _screenLocked
              ? null
              : () {
                  if (_desktop) {
                    _toggleOrientation();
                    return;
                  }
                  _player.playOrPause();
                  setState(() => _controlsVisible = true);
                  _scheduleHide();
                },
          onLongPressStart: _screenLocked
              ? null
              : (_) {
                  if (_isLiveStream) return;
                  if (_playing && _duration.inMilliseconds > 0) {
                    setState(() {
                      _speedBoosting = true;
                      _hudText = '2.0× 倍速播放中 · 松手恢复';
                    });
                    _player.setRate(2.0);
                  }
                },
          onLongPressEnd: _screenLocked
              ? null
              : (_) {
                  if (_speedBoosting) {
                    _player.setRate(_normalSpeed);
                    setState(() {
                      _speedBoosting = false;
                      _hudText = '';
                    });
                  }
                },
          onHorizontalDragStart: _screenLocked
              ? null
              : (details) {
                  if (_isLiveStream || _duration.inMilliseconds <= 0) return;
                  _dragStartPosMs = _position.inMilliseconds.toDouble();
                  _dragStartX = details.localPosition.dx;
                  _dragTargetPosMs = _position.inMilliseconds;
                  _isDraggingSeek = true;
                },
          onHorizontalDragUpdate: _screenLocked
              ? null
              : (details) {
                  if (_isLiveStream ||
                      _duration.inMilliseconds <= 0 ||
                      !_isDraggingSeek) {
                    return;
                  }
                  final width =
                      MediaQuery.sizeOf(context).width.clamp(200.0, 4000.0);
                  final dx = details.localPosition.dx - _dragStartX;
                  final ratio = (dx.abs() / width).clamp(0.0, 1.0);
                  final speedScale = 0.55 + 1.35 * ratio;
                  final spanMs = (_duration.inMilliseconds / 5.0).clamp(
                    60000.0,
                    300000.0,
                  );
                  final deltaMs = (dx / width) * spanMs * speedScale;
                  final previewMs = (_dragStartPosMs + deltaMs).round().clamp(
                    0,
                    _duration.inMilliseconds,
                  );
                  setState(() {
                    _dragTargetPosMs = previewMs;
                    _hudText =
                        '${dx >= 0 ? "快进至" : "快退至"} ${_formatDuration(Duration(milliseconds: previewMs))} / ${_formatDuration(_duration)}';
                  });
                },
          onHorizontalDragEnd: _screenLocked
              ? null
              : (_) {
                  if (_isLiveStream || !_isDraggingSeek) return;
                  final targetMs = _dragTargetPosMs.clamp(
                    0,
                    _duration.inMilliseconds,
                  );
                  setState(() {
                    _isDraggingSeek = false;
                    _position = Duration(milliseconds: targetMs);
                    _hudText = '';
                  });
                  _player.seek(Duration(milliseconds: targetMs));
                  _saveProgress(immediate: true, triggerSync: false);
                  _scheduleHide();
                },
          onHorizontalDragCancel: _screenLocked
              ? null
              : () {
                  if (!_isDraggingSeek) return;
                  setState(() {
                    _isDraggingSeek = false;
                    _hudText = '';
                  });
                },
          onVerticalDragStart: (_desktop || _screenLocked)
              ? null
              : (details) {
                  final width = MediaQuery.sizeOf(context).width;
                  _isVerticalDragging = true;
                  _isDraggingLeftBrightness =
                      details.localPosition.dx < width / 2;
                  _verticalDragStartY = details.localPosition.dy;
                  _verticalDragStartValue = _isDraggingLeftBrightness
                      ? _playerBrightness
                      : (_player.state.volume / 100.0).clamp(0.0, 1.0);
                },
          onVerticalDragUpdate: (_desktop || _screenLocked)
              ? null
              : (details) {
                  if (!_isVerticalDragging) return;
                  final height =
                      MediaQuery.sizeOf(context).height.clamp(220.0, 2000.0);
                  final dy = _verticalDragStartY - details.localPosition.dy;
                  final delta = dy / (height * 0.72);
                  if (_isDraggingLeftBrightness) {
                    final nextBrightness =
                        (_verticalDragStartValue + delta).clamp(0.08, 1.0);
                    setState(() {
                      _playerBrightness = nextBrightness;
                      _hudText = '亮度 ${(nextBrightness * 100).round()}%';
                    });
                  } else {
                    final nextVolRatio =
                        (_verticalDragStartValue + delta).clamp(0.0, 1.0);
                    final nextVol = nextVolRatio * 100.0;
                    _player.setVolume(nextVol);
                    setState(() {
                      _hudText = '音量 ${nextVol.round()}%';
                    });
                  }
                },
          onVerticalDragEnd: (_desktop || _screenLocked)
              ? null
              : (_) {
                  if (!_isVerticalDragging) return;
                  _isVerticalDragging = false;
                  Future.delayed(const Duration(milliseconds: 700), () {
                    if (mounted && !_isVerticalDragging && !_speedBoosting) {
                      setState(() => _hudText = '');
                    }
                  });
                },
          onVerticalDragCancel: (_desktop || _screenLocked)
              ? null
              : () {
                  if (!_isVerticalDragging) return;
                  setState(() {
                    _isVerticalDragging = false;
                    _hudText = '';
                  });
                },
          child: Stack(
            fit: StackFit.expand,
            children: [
              Center(
                child: RepaintBoundary(
                  child: widget.debugVideoSurface ??
                      Video(
                        controller: _controller!,
                        fit: _fit,
                        controls: NoVideoControls,
                      ),
                ),
              ),
              if (_playerBrightness < 0.995)
                IgnorePointer(
                  child: ColoredBox(
                    color: Colors.black.withValues(
                      alpha: ((1.0 - _playerBrightness) * 0.78).clamp(0.0, 0.78),
                    ),
                    child: const SizedBox.expand(),
                  ),
                ),
              if (_hudText.isNotEmpty)
                Align(
                  alignment: const Alignment(0, -0.74),
                  child: AppleGlassSurface(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 10,
                    ),
                    borderRadius: BorderRadius.circular(999),
                    child: Text(
                      _hudText,
                      style: const TextStyle(
                        color: AppleColors.labelPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              if (_loading || _buffering)
                Center(
                  child: AppleGlassSurface(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 22,
                      vertical: 15,
                    ),
                    borderRadius: BorderRadius.circular(999),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const CupertinoActivityIndicator(radius: 11),
                        const SizedBox(width: 12),
                        Text(
                          '正在加载 ${_currentEpisode.name}…',
                          style: const TextStyle(
                            color: AppleColors.labelPrimary,
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
              ),
            ),
          ),
        ),
      ),
      ),
    );
  }

  Widget _buildLockedOverlay(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final isLandscape = size.width > size.height;
    final scale = _desktopScale(size);
    final leftInset = (isLandscape ? 16.0 : 14.0) * scale;
    return SizedBox.expand(
      child: SafeArea(
        child: Align(
          alignment: Alignment.centerLeft,
          child: Padding(
            padding: EdgeInsets.only(left: leftInset),
            child: CupertinoButton(
              key: const Key('player-unlock-button'),
              padding: EdgeInsets.zero,
              minimumSize: Size.square(44 * scale),
              onPressed: () => _setScreenLocked(false),
              child: AppleGlassSurface(
                padding: EdgeInsets.symmetric(
                  horizontal: 15 * scale,
                  vertical: 10.5 * scale,
                ),
                borderRadius: BorderRadius.circular(999),
                backgroundColor: const Color(0xCC181A22),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      CupertinoIcons.lock_fill,
                      color: AppleColors.systemOrange,
                      size: 18 * scale,
                    ),
                    SizedBox(width: 7 * scale),
                    Text(
                      '点击解锁',
                      style: TextStyle(
                        color: AppleColors.labelPrimary,
                        fontSize: 13.5 * scale,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFloatingLockEntryButton(double scale) {
    return Tooltip(
      message: '锁定屏幕',
      child: CupertinoButton(
        key: const Key('player-lock-button'),
        padding: EdgeInsets.zero,
        minimumSize: Size.square(44 * scale),
        onPressed: () => _setScreenLocked(true),
        child: AppleGlassSurface(
          width: 44 * scale,
          height: 44 * scale,
          padding: EdgeInsets.zero,
          borderRadius: BorderRadius.circular(22 * scale),
          backgroundColor: const Color(0x9920222A),
          child: Center(
            child: Icon(
              CupertinoIcons.lock_open_fill,
              color: AppleColors.labelPrimary,
              size: 19 * scale,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildAppleChromeOverlay(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final isLandscape = size.width > size.height;
    final showLeftLockButton = isLandscape && size.width >= 480;
    final scale = _desktopScale(size);
    final leftInset = (isLandscape ? 16.0 : 14.0) * scale;
    final rightDockEdge = (isLandscape ? 8.0 : 14.0) * scale;
    final dockReserve = 64.0 * scale;

    final macTrafficLightInset = defaultTargetPlatform == TargetPlatform.macOS &&
            !(_desktopWindow?.fullscreen ?? false)
        ? 28.0
        : 0.0;

    return SizedBox.expand(
      child: SafeArea(
        child: Stack(
          fit: StackFit.expand,
          children: [
            // 1. Top Header Bar (Back + Title + Live Badge / Orientation / Portrait Lock)
            Positioned(
              left: leftInset,
              right: isLandscape ? rightDockEdge + dockReserve : 14 * scale,
              top: 10 * scale + macTrafficLightInset,
              child: _buildTopHeader(
                context,
                isLandscape,
                scale,
                includeLockButton: !showLeftLockButton,
              ),
            ),

            // 1b. Left-side Floating Lock Entry Button in Landscape / Desktop
            if (showLeftLockButton)
              Positioned(
                left: leftInset,
                top: 0,
                bottom: 0,
                child: Center(
                  child: _buildFloatingLockEntryButton(scale),
                ),
              ),

            // 2. Large Center Transport Buttons (Rewind 15s / Play-Pause / Fast-Forward 15s)
            if (!_loading && !_buffering && _playbackError.isEmpty)
              Center(
                child: Padding(
                  padding: EdgeInsets.only(right: isLandscape ? 32 * scale : 0),
                  child: _buildCenterTransportButtons(scale),
                ),
              ),

            // 3. Landscape Right-side Compact Scrollable Tool Dock (tucked near right edge)
            if (isLandscape)
              Positioned(
                right: rightDockEdge,
                top: 14 * scale,
                bottom: 14 * scale,
                child: Center(
                  child: _buildScrollableToolDock(isLandscape: true, scale: scale),
                ),
              ),

            // 4. Bottom Floating Progress Bar Capsule (hidden during Live TV)
            //    + Bottom Scrollable Tool Dock in Portrait
            Positioned(
              left: leftInset,
              right: isLandscape ? rightDockEdge + dockReserve : 14 * scale,
              bottom: 10 * scale,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (!_isLiveStream)
                    _buildProgressBarCapsule(context, isLandscape, scale),
                  if (!isLandscape) ...[
                    if (!_isLiveStream) SizedBox(height: 10 * scale),
                    _buildScrollableToolDock(isLandscape: false, scale: scale),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTopHeader(
    BuildContext context,
    bool isLandscape,
    double scale, {
    bool includeLockButton = false,
  }) {
    return Row(
      children: [
        CupertinoButton(
          padding: EdgeInsets.zero,
          minSize: 36 * scale,
          onPressed: () async {
            await _saveProgress(immediate: true);
            if (context.mounted) {
              Navigator.of(context).maybePop();
            }
          },
          child: AppleGlassSurface(
            padding: EdgeInsets.symmetric(
              horizontal: 13 * scale,
              vertical: 7.5 * scale,
            ),
            borderRadius: const BorderRadius.all(Radius.circular(999)),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  CupertinoIcons.chevron_back,
                  color: AppleColors.labelPrimary,
                  size: 16 * scale,
                ),
                SizedBox(width: 4 * scale),
                Text(
                  '返回',
                  style: TextStyle(
                    color: AppleColors.labelPrimary,
                    fontSize: 13 * scale,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
        SizedBox(width: 12 * scale),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      widget.video.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: AppleColors.labelPrimary,
                        fontSize: 16.5 * scale,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.3,
                      ),
                    ),
                  ),
                  if (_videoSpecsLabel.isNotEmpty) ...[
                    SizedBox(width: 8 * scale),
                    AppleGlassSurface(
                      key: const Key('player-video-specs'),
                      padding: EdgeInsets.symmetric(
                        horizontal: 7.5 * scale,
                        vertical: 2.5 * scale,
                      ),
                      borderRadius: BorderRadius.circular(999),
                      child: Text(
                        _videoSpecsLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: const Color(0xFFE5E7EB),
                          fontSize: 10.5 * scale,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                  if (_isLiveStream) ...[
                    SizedBox(width: 8 * scale),
                    Container(
                      padding: EdgeInsets.symmetric(
                        horizontal: 7 * scale,
                        vertical: 2 * scale,
                      ),
                      decoration: BoxDecoration(
                        color: AppleColors.systemRed.withValues(alpha: 0.85),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        '直播中',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 10.5 * scale,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              SizedBox(height: 2 * scale),
              Text(
                '${_currentEpisode.name} · ${_currentLine.name}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: AppleColors.labelSecondary,
                  fontSize: 12 * scale,
                ),
              ),
            ],
          ),
        ),
        if (_isLiveStream) ...[
          SizedBox(width: 10 * scale),
          CupertinoButton(
            key: const Key('player-fullscreen-toggle'),
            padding: EdgeInsets.zero,
            minSize: 34 * scale,
            onPressed: _toggleOrientation,
            child: AppleGlassSurface(
              padding: EdgeInsets.symmetric(
                horizontal: 11 * scale,
                vertical: 7 * scale,
              ),
              borderRadius: BorderRadius.circular(999),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    (_desktop ? _desktopWindow?.fullscreen == true : isLandscape)
                        ? CupertinoIcons.fullscreen_exit
                        : CupertinoIcons.fullscreen,
                    color: AppleColors.labelPrimary,
                    size: 15 * scale,
                  ),
                  SizedBox(width: 4 * scale),
                  Text(
                    _fullscreenLabel(isLandscape),
                    style: TextStyle(
                      color: AppleColors.labelPrimary,
                      fontSize: 12 * scale,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
        if (includeLockButton) ...[
          SizedBox(width: 8 * scale),
          CupertinoButton(
            key: const Key('player-lock-button'),
            padding: EdgeInsets.zero,
            minimumSize: Size.square(34 * scale),
            onPressed: () => _setScreenLocked(true),
            child: AppleGlassSurface(
              padding: EdgeInsets.symmetric(
                horizontal: 11 * scale,
                vertical: 7 * scale,
              ),
              borderRadius: BorderRadius.circular(999),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    CupertinoIcons.lock_open_fill,
                    color: AppleColors.labelPrimary,
                    size: 14.5 * scale,
                  ),
                  SizedBox(width: 4 * scale),
                  Text(
                    '锁定',
                    style: TextStyle(
                      color: AppleColors.labelPrimary,
                      fontSize: 12 * scale,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }

  /// Large center screen transport controls: Rewind 15s, Play/Pause, Fast-Forward 15s.
  /// For Live TV streams, only the central Play/Pause button is shown.
  Widget _buildCenterTransportButtons([double scale = 1.0]) {
    if (_isLiveStream) {
      return _buildCenterCircleButton(
        key: const Key('player-center-play-pause'),
        icon: _playing ? CupertinoIcons.pause_fill : CupertinoIcons.play_fill,
        size: 78 * scale,
        iconSize: 36 * scale,
        hero: true,
        onTap: () {
          _player.playOrPause();
          _scheduleHide();
        },
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildCenterCircleButton(
          key: const Key('player-center-rewind'),
          icon: CupertinoIcons.gobackward_15,
          size: 60 * scale,
          iconSize: 26 * scale,
          hero: false,
          onTap: () => _seekRelative(-15),
        ),
        SizedBox(width: 30 * scale),
        _buildCenterCircleButton(
          key: const Key('player-center-play-pause'),
          icon: _playing ? CupertinoIcons.pause_fill : CupertinoIcons.play_fill,
          size: 78 * scale,
          iconSize: 36 * scale,
          hero: true,
          onTap: () {
            _player.playOrPause();
            _scheduleHide();
          },
        ),
        SizedBox(width: 30 * scale),
        _buildCenterCircleButton(
          key: const Key('player-center-forward'),
          icon: CupertinoIcons.goforward_15,
          size: 60 * scale,
          iconSize: 26 * scale,
          hero: false,
          onTap: () => _seekRelative(15),
        ),
      ],
    );
  }

  Widget _buildCenterCircleButton({
    Key? key,
    required IconData icon,
    required double size,
    required double iconSize,
    required bool hero,
    required VoidCallback onTap,
  }) {
    return CupertinoButton(
      key: key,
      padding: EdgeInsets.zero,
      minSize: size,
      onPressed: () {
        _scheduleHide();
        onTap();
      },
      child: AppleGlassSurface(
        width: size,
        height: size,
        padding: EdgeInsets.zero,
        borderRadius: BorderRadius.circular(size / 2),
        backgroundColor: hero
            ? const Color(0xD8FFFFFF)
            : const Color(0x78242429),
        child: Center(
          child: Icon(
            icon,
            color: hero ? Colors.black : AppleColors.labelPrimary,
            size: iconSize,
          ),
        ),
      ),
    );
  }

  /// Standalone floating Progress Bar capsule with Fullscreen / Orientation toggle button.
  Widget _buildProgressBarCapsule(
    BuildContext context,
    bool isLandscape, [
    double scale = 1.0,
  ]) {
    final effectiveDurationMs = _duration.inMilliseconds > 0
        ? _duration.inMilliseconds
        : _lastKnownDurationMs;
    final hasDuration = effectiveDurationMs > 0;
    final maxMs = hasDuration ? effectiveDurationMs.toDouble() : 1.0;
    final activePosMs = _isDraggingSeek
        ? _dragTargetPosMs.toDouble()
        : (_isSliderDragging
              ? _sliderDragPosMs
              : _position.inMilliseconds.toDouble());
    final curMs = hasDuration ? activePosMs.clamp(0.0, maxMs) : 0.0;
    final activeDuration = Duration(
      milliseconds: activePosMs.clamp(0.0, 86400000.0).round(),
    );
    final totalDuration = Duration(milliseconds: effectiveDurationMs);

    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: 740 * scale),
      child: AppleGlassSurface(
        key: const Key('player-progress-bar'),
        padding: EdgeInsets.symmetric(
          horizontal: 16 * scale,
          vertical: 8 * scale,
        ),
        borderRadius: BorderRadius.circular(22 * scale),
        child: Row(
          children: [
            Text(
              _formatDuration(activeDuration),
              style: TextStyle(
                color: AppleColors.labelSecondary,
                fontSize: 12 * scale,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            Expanded(
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 4.5 * scale,
                  thumbShape: RoundSliderThumbShape(
                    enabledThumbRadius: 6.5 * scale,
                  ),
                  overlayShape: RoundSliderOverlayShape(
                    overlayRadius: 13 * scale,
                  ),
                  activeTrackColor: AppleColors.labelPrimary,
                  inactiveTrackColor: const Color(0x44FFFFFF),
                  thumbColor: AppleColors.labelPrimary,
                ),
                child: Slider(
                  value: curMs,
                  min: 0,
                  max: maxMs,
                  onChangeStart: hasDuration
                      ? (value) {
                          setState(() {
                            _isSliderDragging = true;
                            _sliderDragPosMs = value;
                          });
                          _hideTimer?.cancel();
                        }
                      : null,
                  onChanged: hasDuration
                      ? (value) {
                          setState(() {
                            _isSliderDragging = true;
                            _sliderDragPosMs = value;
                          });
                        }
                      : null,
                  onChangeEnd: hasDuration
                      ? (value) {
                          final targetMs = value.round().clamp(
                            0,
                            effectiveDurationMs,
                          );
                          setState(() {
                            _isSliderDragging = false;
                            _position = Duration(milliseconds: targetMs);
                          });
                          _player.seek(Duration(milliseconds: targetMs));
                          unawaited(
                            _saveProgress(immediate: true, triggerSync: false),
                          );
                          _scheduleHide();
                        }
                      : null,
                ),
              ),
            ),
            Text(
              hasDuration ? _formatDuration(totalDuration) : '--:--',
              style: TextStyle(
                color: AppleColors.labelSecondary,
                fontSize: 12 * scale,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            SizedBox(width: 10 * scale),
            CupertinoButton(
              key: const Key('player-fullscreen-toggle'),
              padding: EdgeInsets.zero,
              minSize: 34 * scale,
              onPressed: _toggleOrientation,
              child: Container(
                padding: EdgeInsets.symmetric(
                  horizontal: 10 * scale,
                  vertical: 6 * scale,
                ),
                decoration: BoxDecoration(
                  color: const Color(0x28FFFFFF),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(
                    color: AppleColors.glassBorder,
                    width: 0.5,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      (_desktop ? _desktopWindow?.fullscreen == true : isLandscape)
                          ? CupertinoIcons.fullscreen_exit
                          : CupertinoIcons.fullscreen,
                      color: AppleColors.labelPrimary,
                      size: 15 * scale,
                    ),
                    SizedBox(width: 4 * scale),
                    Text(
                      _fullscreenLabel(isLandscape),
                      style: TextStyle(
                        color: AppleColors.labelPrimary,
                        fontSize: 12 * scale,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Separate Scrollable Tool Dock:
  /// - Portrait: horizontal scrollable glass strip at the bottom.
  /// - Landscape: slim vertical Liquid Glass capsule near the right edge.
  /// Exposes all adjustable playback controls (omitting VOD-only items during
  /// Live TV). The orientation toggle lives only on the progress bar (or the
  /// header during Live TV), so it is intentionally not duplicated here.
  Widget _buildScrollableToolDock({
    required bool isLandscape,
    double scale = 1.0,
  }) {
    final live = _isLiveStream;
    final actions = <_PlayerAction>[
      _PlayerAction(
        CupertinoIcons.lock_open_fill,
        '锁定屏幕',
        () => _setScreenLocked(true),
        shortLabel: '锁定',
      ),
      if (_episodeIndex > 0)
        _PlayerAction(
          CupertinoIcons.backward_end_fill,
          live ? '上源' : '上集',
          () => _stepEpisode(-1),
        ),
      if (_episodeIndex < _currentLine.episodes.length - 1)
        _PlayerAction(
          CupertinoIcons.forward_end_fill,
          live ? '下源' : '下集',
          () => _stepEpisode(1),
        ),
      if (_currentLine.episodes.length > 1 || !live)
        _PlayerAction(
          CupertinoIcons.square_grid_2x2_fill,
          live ? '信号' : '选集',
          _showEpisodesSheet,
        ),
      if (_lines.length > 1 || !live)
        _PlayerAction(CupertinoIcons.layers_alt_fill, '线路', _showLinesSheet),
      _PlayerAction(
        CupertinoIcons.slider_horizontal_3,
        '策略·$_kernelShortLabel',
        _showKernelSheet,
        shortLabel: _kernelShortLabel,
        active: _playerKernel != 'exo',
      ),
      if (!live)
        _PlayerAction(
          CupertinoIcons.speedometer,
          '${_normalSpeed}×',
          _showSpeedSheet,
          active: _normalSpeed != 1.0,
        ),
      _PlayerAction(
        CupertinoIcons.play_rectangle,
        '画面·$_fitLabel',
        _cycleAspect,
        shortLabel: _fitLabel,
      ),
      if (!live) ...[
        _PlayerAction(
          CupertinoIcons.forward_fill,
          _skipIntroSec > 0 ? '片头${_skipIntroSec}s' : '跳片头',
          _showSkipIntroSheet,
          shortLabel: '片头',
          active: _skipIntroSec > 0,
        ),
        _PlayerAction(
          CupertinoIcons.forward_end_alt_fill,
          _skipOutroSec > 0 ? '片尾${_skipOutroSec}s' : '跳片尾',
          _showSkipOutroSheet,
          shortLabel: '片尾',
          active: _skipOutroSec > 0,
        ),
        _PlayerAction(
          CupertinoIcons.repeat,
          '连播·${_autoNext ? "开" : "关"}',
          _toggleAutoNext,
          shortLabel: '连播',
          active: _autoNext,
        ),
        _PlayerAction(
          CupertinoIcons.arrow_2_squarepath,
          '循环·$_repeatLabel',
          _cycleRepeatMode,
          shortLabel: '循环',
          active: _repeatMode == 'one' || _repeatMode == 'all',
        ),
      ],
      _PlayerAction(
        CupertinoIcons.clock_fill,
        '时间·${_alwaysShowClock ? "显" : "隐"}',
        _toggleAlwaysShowClock,
        shortLabel: '时间',
        active: _alwaysShowClock,
      ),
      if (_qualityChoices.length > 1)
        _PlayerAction(CupertinoIcons.slider_horizontal_3, '画质', _showQualityChoices),
      _PlayerAction(CupertinoIcons.speaker_2_fill, '音轨', _showAudioTracksSheet),
      if (!live)
        _PlayerAction(
          CupertinoIcons.captions_bubble_fill,
          '字幕',
          _showSubtitleTracksSheet,
        ),
      _PlayerAction(CupertinoIcons.refresh, live ? '刷新' : '重播', () {
        if (live) {
          _openCurrentEpisode();
          _showHud('正在刷新直播流…');
        } else {
          _player.seek(Duration.zero);
          _player.play();
          _showHud('已从头开始播放');
        }
      }),
    ];

    if (isLandscape) {
      return LayoutBuilder(
        builder: (context, constraints) {
          final itemExtent = 50.0 * scale;
          final vertPad = 8.0 * scale;
          final contentH = actions.length * itemExtent + vertPad * 2;
          final maxH = constraints.maxHeight.isFinite
              ? constraints.maxHeight
              : contentH;
          final scrollable = contentH > maxH;
          final dockWidth = 54.0 * scale;
          return LiquidGlass(
            key: const Key('player-tool-dock-landscape'),
            width: dockWidth,
            height: math.min(contentH, maxH),
            borderRadius: dockWidth / 2,
            tint: const Color(0x47141418),
            blur: 18,
            child: AppleEdgeFade(
              axis: Axis.vertical,
              fadeWidth: scrollable ? 18 * scale : 0,
              child: ListView.builder(
                padding: EdgeInsets.symmetric(vertical: vertPad),
                physics: const BouncingScrollPhysics(),
                itemExtent: itemExtent,
                itemCount: actions.length,
                itemBuilder: (ctx, i) => _buildRailButton(actions[i], scale),
              ),
            ),
          );
        },
      );
    }

    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: 740 * scale),
      child: LiquidGlass(
        key: const Key('player-tool-dock-portrait'),
        borderRadius: 24 * scale,
        tint: const Color(0x47141418),
        blur: 18,
        child: AppleEdgeFade(
          fadeWidth: 14 * scale,
          child: DesktopHorizontalScroller(
            controller: _portraitToolsScrollController,
            showArrows: false,
            child: SingleChildScrollView(
              controller: _portraitToolsScrollController,
              physics: const BouncingScrollPhysics(),
              scrollDirection: Axis.horizontal,
              padding: EdgeInsets.symmetric(
                horizontal: 10 * scale,
                vertical: 7 * scale,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (int i = 0; i < actions.length; i++) ...[
                    if (i > 0) SizedBox(width: 7 * scale),
                    _buildToolTile(actions[i], scale),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Landscape rail button: icon in a soft circular glass well with a short
  /// caption underneath; active toggles take the system tint.
  Widget _buildRailButton(_PlayerAction action, [double scale = 1.0]) {
    final tint = action.active
        ? const Color(0xFF3E9BFF)
        : AppleColors.labelPrimary;
    return CupertinoButton(
      padding: EdgeInsets.zero,
      minSize: 44 * scale,
      pressedOpacity: 0.6,
      onPressed: () {
        _scheduleHide();
        action.onTap();
      },
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 30 * scale,
            height: 30 * scale,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: action.active
                  ? const Color(0x2E3E9BFF)
                  : const Color(0x1FFFFFFF),
            ),
            alignment: Alignment.center,
            child: Icon(action.icon, color: tint, size: 15 * scale),
          ),
          SizedBox(height: 3 * scale),
          Text(
            action.shortLabel ?? action.label,
            maxLines: 1,
            overflow: TextOverflow.fade,
            softWrap: false,
            style: TextStyle(
              color: action.active ? tint : AppleColors.labelSecondary,
              fontSize: 9 * scale,
              fontWeight: FontWeight.w600,
              letterSpacing: -0.1,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildToolTile(_PlayerAction action, [double scale = 1.0]) {
    final tint = action.active
        ? const Color(0xFF3E9BFF)
        : AppleColors.labelPrimary;
    return CupertinoButton(
      padding: EdgeInsets.zero,
      minSize: 34 * scale,
      onPressed: () {
        _scheduleHide();
        action.onTap();
      },
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: 11 * scale,
          vertical: 6.5 * scale,
        ),
        decoration: BoxDecoration(
          color: action.active
              ? const Color(0x2E3E9BFF)
              : const Color(0x1FFFFFFF),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(action.icon, color: tint, size: 14 * scale),
            SizedBox(width: 5 * scale),
            Text(
              action.label,
              style: TextStyle(
                color: tint,
                fontSize: 12 * scale,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _cycleAspect() {
    setState(() {
      if (_fit == BoxFit.contain) {
        _fit = BoxFit.cover;
        _showHud('画面：裁切填充');
      } else if (_fit == BoxFit.cover) {
        _fit = BoxFit.fill;
        _showHud('画面：铺满屏幕');
      } else {
        _fit = BoxFit.contain;
        _showHud('画面：适应屏幕');
      }
    });
  }

  void _toggleAutoNext() {
    final next = !_autoNext;
    setState(() => _autoNext = next);
    widget.storage.setAutoNext(next);
    _showHud('自动连播：${next ? "已开启" : "已关闭"}');
  }

  void _cycleRepeatMode() {
    final next = _repeatMode == 'off'
        ? 'one'
        : (_repeatMode == 'one' ? 'all' : 'off');
    setState(() => _repeatMode = next);
    widget.storage.setRepeatMode(next);
    _showHud('循环模式：$_repeatLabel');
  }

  void _toggleAlwaysShowClock() {
    final next = !_alwaysShowClock;
    setState(() {
      _alwaysShowClock = next;
      if (next) _clockText = _formatClockNow();
    });
    widget.storage.setPlayerAlwaysShowClock(next);
    _showHud('播放页常显时间：${next ? "已开启" : "已关闭"}');
  }

  void _showSkipIntroSheet() {
    _showPrecisionSkipSheet(isIntro: true);
  }

  void _showSkipOutroSheet() {
    _showPrecisionSkipSheet(isIntro: false);
  }

  void _showPrecisionSkipSheet({required bool isIntro}) {
    const presets = [0, 15, 30, 45, 60, 90, 120, 150, 180, 240];
    final previousSec = (isIntro ? _skipIntroSec : _skipOutroSec).clamp(0, 600);
    final effectiveDur = _duration.inMilliseconds > 0
        ? _duration
        : Duration(milliseconds: _lastKnownDurationMs);
    final defaultSec = StorageService.defaultSkipSecondsFromPlayback(
      isIntro: isIntro,
      savedSec: previousSec,
      position: _position,
      duration: effectiveDur,
    );
    int tempSec = defaultSec.clamp(0, 600);
    final bool autoAppliedCurrentTime =
        defaultSec > 0 && defaultSec != previousSec;

    void persistSec(int sec) {
      final clamped = sec.clamp(0, 600);
      setState(() {
        if (isIntro) {
          _skipIntroSec = clamped;
        } else {
          _skipOutroSec = clamped;
        }
      });
      if (isIntro) {
        widget.storage.setVideoSkipIntroSec(
          widget.site.key,
          widget.video.id,
          clamped,
          isPrivate: widget.site.isEffectivelyPrivate,
        );
      } else {
        widget.storage.setVideoSkipOutroSec(
          widget.site.key,
          widget.video.id,
          clamped,
          isPrivate: widget.site.isEffectivelyPrivate,
        );
      }
    }

    if (autoAppliedCurrentTime) {
      persistSec(tempSec);
      _showHud(
        '本片${isIntro ? "片头" : "片尾"}已默认设为当前时间 ${_formatDuration(Duration(seconds: tempSec))}',
      );
    }

    void applySec(int sec, void Function(void Function()) setSheetState) {
      final clamped = sec.clamp(0, 600);
      setSheetState(() => tempSec = clamped);
      persistSec(clamped);
    }

    showAppleModalSheet<void>(
      context: context,
      title: isIntro ? '本片跳过片头节点' : '本片跳过片尾节点',
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          final formatted = _formatDuration(Duration(seconds: tempSec));
          final liveDur = _duration.inMilliseconds > 0
              ? _duration
              : Duration(milliseconds: _lastKnownDurationMs);
          final currentPlaySec = StorageService.defaultSkipSecondsFromPlayback(
            isIntro: isIntro,
            savedSec: tempSec,
            position: _position,
            duration: liveDur,
          );
          return SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 9,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0x260A84FF),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: const Color(0x4D0A84FF),
                      width: 0.7,
                    ),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        CupertinoIcons.film_fill,
                        color: Color(0xFF5AC8FA),
                        size: 15,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          autoAppliedCurrentTime && tempSec == defaultSec
                              ? '已优先默认设为当前时间 $formatted · 仅对《${widget.video.title}》独立生效'
                              : '独立记录 · 仅对《${widget.video.title}》生效，不影响其他影片',
                          style: const TextStyle(
                            color: Color(0xFFE5F1FF),
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            height: 1.35,
                          ),
                        ),
                      ),
                      if (previousSec != tempSec) ...[
                        const SizedBox(width: 8),
                        CupertinoButton(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 9,
                            vertical: 4,
                          ),
                          minSize: 24,
                          color: const Color(0x33FFFFFF),
                          borderRadius: BorderRadius.circular(999),
                          onPressed: () {
                            applySec(previousSec, setSheetState);
                            _showHud(
                              previousSec == 0
                                  ? '已恢复本片${isIntro ? "片头" : "片尾"}为不跳过'
                                  : '已恢复原值 ${_formatDuration(Duration(seconds: previousSec))}',
                            );
                          },
                          child: Text(
                            previousSec == 0 ? '恢复关闭' : '恢复${previousSec}s',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                AppleGlassSurface(
                  padding: const EdgeInsets.all(14),
                  borderRadius: BorderRadius.circular(18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            isIntro ? '微调本片片头节点' : '微调本片片尾节点',
                            style: const TextStyle(
                              color: AppleColors.labelSecondary,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          Text(
                            tempSec == 0
                                ? '不跳过 (00:00)'
                                : '$formatted ($tempSec秒)',
                            style: const TextStyle(
                              color: AppleColors.systemBlue,
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                              fontFeatures: [FontFeature.tabularFigures()],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      SliderTheme(
                        data: SliderTheme.of(ctx).copyWith(
                          trackHeight: 5,
                          activeTrackColor: AppleColors.systemBlue,
                          inactiveTrackColor: const Color(0x38FFFFFF),
                          thumbColor: Colors.white,
                        ),
                        child: Slider(
                          value: tempSec.clamp(0, 600).toDouble(),
                          min: 0,
                          max: 600,
                          divisions: 600,
                          onChanged: (v) => applySec(v.round(), setSheetState),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          for (final step in const [
                            -15,
                            -5,
                            -1,
                            1,
                            5,
                            15,
                          ]) ...[
                            Expanded(
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 2.5,
                                ),
                                child: CupertinoButton(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 7,
                                  ),
                                  minSize: 32,
                                  color: const Color(0x28FFFFFF),
                                  borderRadius: BorderRadius.circular(10),
                                  onPressed: () =>
                                      applySec(tempSec + step, setSheetState),
                                  child: Text(
                                    step > 0 ? '+${step}s' : '${step}s',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      if (_position.inSeconds > 0 && currentPlaySec > 0) ...[
                        const SizedBox(height: 10),
                        CupertinoButton(
                          padding: const EdgeInsets.symmetric(vertical: 9),
                          minSize: 36,
                          color: AppleColors.systemBlue,
                          borderRadius: BorderRadius.circular(12),
                          onPressed: () {
                            applySec(currentPlaySec, setSheetState);
                            _showHud(
                              '本片${isIntro ? "片头" : "片尾"}已设为当前时间 ${_formatDuration(Duration(seconds: currentPlaySec))}',
                            );
                          },
                          child: Text(
                            isIntro
                                ? '设为当前播放位置 (${_formatDuration(Duration(seconds: currentPlaySec))})'
                                : '设为当前剩余时长 (${_formatDuration(Duration(seconds: currentPlaySec))})',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: presets.map((sec) {
                    final selected = tempSec == sec;
                    return GestureDetector(
                      onTap: () {
                        applySec(sec, setSheetState);
                        _showHud(
                          sec == 0
                              ? '已清除本片跳过${isIntro ? "片头" : "片尾"}'
                              : '本片${isIntro ? "片头" : "片尾"}已设为 ${_formatDuration(Duration(seconds: sec))}',
                        );
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 13,
                          vertical: 7.5,
                        ),
                        decoration: BoxDecoration(
                          color: selected
                              ? AppleColors.systemBlue
                              : const Color(0x24FFFFFF),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          sec == 0
                              ? '清除本片'
                              : '${_formatDuration(Duration(seconds: sec))} (${sec}s)',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: selected
                                ? FontWeight.w700
                                : FontWeight.w500,
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> _showQualityChoices() async {
    final session = _playSession;
    final selected = await showCupertinoModalPopup<CmsEpisode>(
      context:context,
      builder:(sheet)=>CupertinoActionSheet(
        title:const Text('切换画质'),
        actions:[for(final choice in _qualityChoices) CupertinoActionSheetAction(
          isDefaultAction:choice.url == _activeStreamUrl,
          onPressed:()=>Navigator.pop(sheet,choice),child:Text(choice.name))],
        cancelButton:CupertinoActionSheetAction(onPressed:()=>Navigator.pop(sheet),child:const Text('取消')),
      ),
    );
    if (!mounted ||
        session != _playSession ||
        selected == null ||
        selected.url == _activeStreamUrl) {
      return;
    }
    _failedQualityUrls.remove(selected.url);
    final keepPos = _position.inMilliseconds >= 1000
        ? _position.inMilliseconds
        : _lastKnownPositionMs;
    await _openCurrentEpisode(
      resumeMs: keepPos,
      quality: selected,
      userSelectedQuality: true,
    );
  }

  void _showAudioTracksSheet() {
    final tracks = _player.state.tracks.audio;
    final active = _player.state.track.audio;
    showAppleModalSheet<void>(
      context: context,
      title: '切换音轨',
      builder: (ctx) => ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.all(16),
        children: [
          AppleGroupedSection(
            children: tracks.isEmpty
                ? [
                    const AppleGroupedTile(
                      icon: CupertinoIcons.speaker_2_fill,
                      title: '默认音轨',
                      subtitle: '当前片源仅包含单一音轨',
                    ),
                  ]
                : tracks.map((t) {
                    final selected = t == active;
                    final label = (t.title ?? t.language ?? t.id).trim();
                    return AppleGroupedTile(
                      icon: CupertinoIcons.speaker_2_fill,
                      iconBgColor: selected
                          ? AppleColors.systemBlue
                          : AppleColors.groupedTertiary,
                      title: label.isEmpty ? '音轨 ${t.id}' : label,
                      trailing: selected
                          ? const Icon(
                              CupertinoIcons.checkmark_alt,
                              color: AppleColors.systemBlue,
                              size: 18,
                            )
                          : null,
                      onTap: () {
                        Navigator.of(ctx).pop();
                        _player.setAudioTrack(t);
                        _showHud('已切换音轨：${label.isEmpty ? t.id : label}');
                      },
                    );
                  }).toList(),
          ),
        ],
      ),
    );
  }

  void _showSubtitleTracksSheet() {
    final tracks = _player.state.tracks.subtitle;
    final active = _player.state.track.subtitle;
    showAppleModalSheet<void>(
      context: context,
      title: '切换字幕',
      builder: (ctx) => ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.all(16),
        children: [
          AppleGroupedSection(
            children: [
              AppleGroupedTile(
                icon: CupertinoIcons.captions_bubble,
                iconBgColor: active == SubtitleTrack.no()
                    ? AppleColors.systemBlue
                    : AppleColors.groupedTertiary,
                title: '关闭内嵌字幕',
                onTap: () {
                  Navigator.of(ctx).pop();
                  _player.setSubtitleTrack(SubtitleTrack.no());
                  _showHud('已关闭内嵌字幕');
                },
              ),
              ...tracks.map((t) {
                final selected = t == active;
                final label = (t.title ?? t.language ?? t.id).trim();
                return AppleGroupedTile(
                  icon: CupertinoIcons.captions_bubble_fill,
                  iconBgColor: selected
                      ? AppleColors.systemBlue
                      : AppleColors.groupedTertiary,
                  title: label.isEmpty ? '字幕 ${t.id}' : label,
                  trailing: selected
                      ? const Icon(
                          CupertinoIcons.checkmark_alt,
                          color: AppleColors.systemBlue,
                          size: 18,
                        )
                      : null,
                  onTap: () {
                    Navigator.of(ctx).pop();
                    _player.setSubtitleTrack(t);
                    _showHud('已切换字幕：${label.isEmpty ? t.id : label}');
                  },
                );
              }),
            ],
          ),
        ],
      ),
    );
  }

  void _showKernelSheet() {
    final kernels = <({String key, String title, String subtitle})>[
      (
        key: 'exo',
        title: '均衡播放（默认）',
        subtitle: _desktop
            ? '硬件解码优先，桌面端使用 256 MB 高速前向缓冲'
            : '自动选择解码方式，使用 64 MB 前向缓冲',
      ),
      (
        key: 'ijk',
        title: '兼容缓冲',
        subtitle: '硬件解码拷贝输出，增加媒体探测时间',
      ),
      (
        key: 'mpv',
        title: '大容量缓冲',
        subtitle: _desktop
            ? '桌面端使用 512 MB 超大前向缓冲，适合高码率 4K 原盘'
            : '使用 128 MB 前向缓冲，占用更多内存',
      ),
    ];
    showAppleModalSheet<void>(
      context: context,
      title: '切换播放策略',
      builder: (ctx) => ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.all(16),
        children: [
          AppleGroupedSection(
            children: kernels.map((k) {
              final selected = _playerKernel == k.key;
              return AppleGroupedTile(
                icon: CupertinoIcons.slider_horizontal_3,
                iconBgColor: selected
                    ? AppleColors.systemBlue
                    : AppleColors.groupedTertiary,
                title: k.title,
                subtitle: k.subtitle,
                trailing: selected
                    ? const Icon(
                        CupertinoIcons.checkmark_alt,
                        color: AppleColors.systemBlue,
                        size: 18,
                      )
                    : null,
                onTap: () async {
                  Navigator.of(ctx).pop();
                  if (_playerKernel == k.key) return;
                  final keepPos = _position.inMilliseconds >= 1000
                      ? _position.inMilliseconds
                      : _lastKnownPositionMs;
                  setState(() => _playerKernel = k.key);
                  await widget.storage.setPlayerKernel(k.key);
                  _playerConfiguration = _playerConfiguration.then(
                    (_) => _applyPlayerKernel(k.key),
                  );
                  await _playerConfiguration;
                  if (!mounted) return;
                  _showHud('已切换至 ${k.title}');
                  unawaited(_openCurrentEpisode(resumeMs: keepPos));
                },
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  void _showSpeedSheet() {
    const speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0];
    showAppleModalSheet<void>(
      context: context,
      title: '播放倍速',
      builder: (ctx) => ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.all(16),
        children: [
          AppleGroupedSection(
            children: speeds.map((s) {
              final selected = _normalSpeed == s;
              return AppleGroupedTile(
                icon: CupertinoIcons.speedometer,
                iconBgColor: selected
                    ? AppleColors.systemBlue
                    : AppleColors.groupedTertiary,
                title: '$s× 倍速',
                trailing: selected
                    ? const Icon(
                        CupertinoIcons.checkmark_alt,
                        color: AppleColors.systemBlue,
                        size: 18,
                      )
                    : null,
                onTap: () {
                  Navigator.of(ctx).pop();
                  setState(() => _normalSpeed = s);
                  _player.setRate(s);
                  widget.storage.setPlaySpeed(s);
                },
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  String? _episodeUnavailableReason(
    CmsEpisode episode,
    List<CmsParse> parses,
  ) {
    if (_isLiveStream) return null;
    return WebMediaResolver.episodeUnavailableReason(
      episode,
      site: widget.site,
      parses: parses,
    );
  }

  String? _lineUnavailableReason(CmsLine line, List<CmsParse> parses) {
    if (_isLiveStream) return null;
    if (line.episodes.isEmpty) return '当前线路暂无剧集';
    String? firstReason;
    for (final ep in line.episodes) {
      final r = _episodeUnavailableReason(ep, parses);
      if (r == null) return null;
      firstReason ??= r;
    }
    return firstReason;
  }

  void _showLinesSheet() {
    final parses = widget.storage.loadSavedConfig()?.parses ?? const [];
    final lineReasons = List<String?>.generate(
      _lines.length,
      (i) => _lineUnavailableReason(_lines[i], parses),
      growable: false,
    );
    showAppleModalSheet<void>(
      context: context,
      title: '切换播放线路',
      builder: (ctx) => ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.all(16),
        children: [
          AppleGroupedSection(
            children: List.generate(_lines.length, (i) {
              final selected = i == _lineIndex;
              final lineReason = lineReasons[i];
              final tile = AppleGroupedTile(
                icon: CupertinoIcons.layers_alt_fill,
                iconBgColor: selected
                    ? AppleColors.systemBlue
                    : AppleColors.groupedTertiary,
                title: _lines[i].name,
                subtitle: lineReason != null
                    ? '${_lines[i].episodes.length} 集 · $lineReason'
                    : '${_lines[i].episodes.length} 集',
                trailing: selected
                    ? const Icon(
                        CupertinoIcons.checkmark_alt,
                        color: AppleColors.systemBlue,
                        size: 18,
                      )
                    : null,
                onTap: () {
                  if (lineReason != null) {
                    showCupertinoDialog<void>(
                      context: ctx,
                      builder: (dCtx) => CupertinoAlertDialog(
                        title: Text(_lines[i].name),
                        content: Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(lineReason),
                        ),
                        actions: [
                          CupertinoDialogAction(
                            isDefaultAction: true,
                            onPressed: () => Navigator.of(dCtx).pop(),
                            child: const Text('我知道了'),
                          ),
                        ],
                      ),
                    );
                    return;
                  }
                  Navigator.of(ctx).pop();
                  _failedLinesForEpisode.clear();
                  _failedLiveEpisodes.clear();
                  final keepPos = _position.inMilliseconds >= 1000
                      ? _position.inMilliseconds
                      : _lastKnownPositionMs;
                  _saveProgress(immediate: true, syncImmediate: false);
                  setState(() {
                    _lineIndex = i;
                    _episodeIndex = CspBridge.matchEpisodeIndexInLine(
                      _lines[i],
                      _currentEpisode.name,
                      _episodeIndex,
                    );
                  });
                  _openCurrentEpisode(resumeMs: keepPos);
                },
              );
              return lineReason != null
                  ? Opacity(opacity: 0.48, child: tile)
                  : tile;
            }),
          ),
        ],
      ),
    );
  }

  void _showEpisodesSheet() {
    final screenSize = MediaQuery.sizeOf(context);
    final isLandscape = screenSize.width > screenSize.height;
    final parses = widget.storage.loadSavedConfig()?.parses ?? const [];
    String? episodeChecker(CmsEpisode ep) =>
        _episodeUnavailableReason(ep, parses);
    showAppleModalSheet<void>(
      context: context,
      title: '选集与线路 (${_currentLine.episodes.length})',
      maxWidth: isLandscape ? math.min(screenSize.width - 24, 760.0) : 560.0,
      builder: (ctx) => PlayerEpisodePickerSheet(
        lines: _lines,
        initialLineIndex: _lineIndex,
        activeLineIndex: _lineIndex,
        activeEpisodeIndex: _episodeIndex,
        episodeUnavailableReason: episodeChecker,
        onSelect: (lineIdx, epIdx) {
          Navigator.of(ctx).pop();
          _failedLinesForEpisode.clear();
          _failedLiveEpisodes.clear();
          final sameEpisode = epIdx == _episodeIndex;
          final keepPos = sameEpisode
              ? (_position.inMilliseconds >= 1000
                    ? _position.inMilliseconds
                    : _lastKnownPositionMs)
              : 0;
          _saveProgress(immediate: true, syncImmediate: false);
          setState(() {
            _lineIndex = lineIdx;
            _episodeIndex = epIdx;
          });
          _openCurrentEpisode(resumeMs: keepPos);
        },
      ),
    );
  }
}

/// One adjustable playback control shown in the tool dock.
class _PlayerAction {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  /// Compact caption for the narrow landscape rail.
  final String? shortLabel;

  /// Highlights toggles that are currently on (连播、循环、跳片头…).
  final bool active;
  const _PlayerAction(
    this.icon,
    this.label,
    this.onTap, {
    this.shortLabel,
    this.active = false,
  });
}

class _ParsedEpisodeLabel {
  final String title;
  final String sizeBadge;

  const _ParsedEpisodeLabel({required this.title, required this.sizeBadge});

  factory _ParsedEpisodeLabel.parse(String raw, int index) {
    var text = raw.trim();
    var badge = '';
    final bracketMatch = RegExp(r'^\[([^\]]+)\]\s*(.*)$').firstMatch(text);
    if (bracketMatch != null) {
      badge = (bracketMatch.group(1) ?? '').trim();
      text = (bracketMatch.group(2) ?? '').trim();
    }
    if (text.isEmpty) {
      text = raw.trim().isNotEmpty ? raw.trim() : '第${index + 1}集';
    }
    return _ParsedEpisodeLabel(title: text, sizeBadge: badge);
  }
}

@visibleForTesting
class PlayerEpisodePickerSheet extends StatefulWidget {
  final List<CmsLine> lines;
  final int initialLineIndex;
  final int activeLineIndex;
  final int activeEpisodeIndex;
  final String? Function(CmsEpisode episode)? episodeUnavailableReason;
  final void Function(int lineIndex, int episodeIndex) onSelect;

  const PlayerEpisodePickerSheet({
    super.key,
    required this.lines,
    required this.initialLineIndex,
    required this.activeLineIndex,
    required this.activeEpisodeIndex,
    this.episodeUnavailableReason,
    required this.onSelect,
  });

  @override
  State<PlayerEpisodePickerSheet> createState() =>
      _PlayerEpisodePickerSheetState();
}

class _PlayerEpisodePickerSheetState extends State<PlayerEpisodePickerSheet> {
  static const int _groupSize = 40;
  late int _previewLineIndex;
  late int _groupIndex;
  bool _descending = false;
  String? _blockedEpisodeNotice;
  late List<String?> _cachedLineBlockedReasons;
  final ScrollController _linesScrollController = ScrollController();
  final ScrollController _groupScrollController = ScrollController();

  @override
  void dispose() {
    _linesScrollController.dispose();
    _groupScrollController.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _previewLineIndex = widget.initialLineIndex
        .clamp(0, math.max(0, widget.lines.length - 1))
        .toInt();
    _groupIndex = (widget.activeEpisodeIndex ~/ _groupSize);
    _cachedLineBlockedReasons = _computeLineBlockedReasons();
  }

  @override
  void didUpdateWidget(covariant PlayerEpisodePickerSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_sameLines(oldWidget.lines, widget.lines) ||
        oldWidget.episodeUnavailableReason != widget.episodeUnavailableReason) {
      _cachedLineBlockedReasons = _computeLineBlockedReasons();
    }
  }

  static bool _sameLines(List<CmsLine> a, List<CmsLine> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!identical(a[i], b[i])) return false;
    }
    return true;
  }

  List<String?> _computeLineBlockedReasons() {
    final checker = widget.episodeUnavailableReason;
    if (checker == null) {
      return List<String?>.filled(widget.lines.length, null);
    }
    return List<String?>.generate(widget.lines.length, (idx) {
      final eps = widget.lines[idx].episodes;
      if (eps.isEmpty) return null;
      String? firstReason;
      for (final ep in eps) {
        final r = checker(ep);
        if (r == null) return null;
        firstReason ??= r;
      }
      return firstReason;
    }, growable: false);
  }

  CmsLine get _line => widget.lines.isEmpty
      ? const CmsLine(name: '默认线路', episodes: [])
      : widget.lines[_previewLineIndex
            .clamp(0, widget.lines.length - 1)
            .toInt()];

  @override
  Widget build(BuildContext context) {
    final episodes = _line.episodes;
    final total = episodes.length;
    final groupCount = total <= 0 ? 1 : ((total - 1) ~/ _groupSize) + 1;
    final safeGroup = _groupIndex.clamp(0, math.max(0, groupCount - 1)).toInt();
    final int startIdx = safeGroup * _groupSize;
    final int endIdx = math.min(startIdx + _groupSize, total);

    final indices = <int>[for (int i = startIdx; i < endIdx; i++) i];
    if (_descending) {
      indices.sort((a, b) => b.compareTo(a));
    }

    final screenSize = MediaQuery.sizeOf(context);
    final isLandscape = screenSize.width > screenSize.height;
    final crossAxisCount = isLandscape ? 5 : 3;
    final safeLineIdx = widget.lines.isEmpty
        ? 0
        : _previewLineIndex.clamp(0, widget.lines.length - 1).toInt();
    final lineBlockedReason = safeLineIdx < _cachedLineBlockedReasons.length
        ? _cachedLineBlockedReasons[safeLineIdx]
        : null;
    final activeNotice = _blockedEpisodeNotice ?? lineBlockedReason;

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 顶部线路切换 + 当前播放状态 + 正倒序切换
          Row(
            children: [
              Expanded(
                child: DesktopHorizontalScroller(
                  controller: _linesScrollController,
                  showArrows: false,
                  child: SingleChildScrollView(
                    controller: _linesScrollController,
                    scrollDirection: Axis.horizontal,
                    physics: const BouncingScrollPhysics(),
                    child: Row(
                    children: List.generate(widget.lines.length, (i) {
                      final line = widget.lines[i];
                      final selected = i == _previewLineIndex;
                      final isPlayingLine = i == widget.activeLineIndex;
                      final isLineUnavailable =
                          i < _cachedLineBlockedReasons.length &&
                          _cachedLineBlockedReasons[i] != null;
                      return Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: Opacity(
                          opacity: isLineUnavailable ? 0.52 : 1.0,
                          child: GestureDetector(
                            onTap: () {
                              setState(() {
                                _previewLineIndex = i;
                                _blockedEpisodeNotice = null;
                                final newGroupCount = line.episodes.isEmpty
                                    ? 1
                                    : ((line.episodes.length - 1) ~/ _groupSize) +
                                          1;
                                if (_groupIndex >= newGroupCount) {
                                  _groupIndex = 0;
                                }
                              });
                            },
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 200),
                            curve: Curves.easeOutCubic,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 13,
                              vertical: 7,
                            ),
                            decoration: BoxDecoration(
                              gradient: selected
                                  ? const LinearGradient(
                                      begin: Alignment.topLeft,
                                      end: Alignment.bottomRight,
                                      colors: [
                                        Color(0xFF2897FF),
                                        Color(0xFF0A84FF),
                                      ],
                                    )
                                  : const LinearGradient(
                                      begin: Alignment.topCenter,
                                      end: Alignment.bottomCenter,
                                      colors: [
                                        Color(0xD82C2C32),
                                        Color(0xCC1E1E24),
                                      ],
                                    ),
                              borderRadius: BorderRadius.circular(999),
                              border: Border.all(
                                color: selected
                                    ? const Color(0x90FFFFFF)
                                    : const Color(0x2EFFFFFF),
                                width: 0.7,
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (isPlayingLine) ...[
                                  Icon(
                                    CupertinoIcons.play_fill,
                                    size: 11.5,
                                    color: selected
                                        ? Colors.white
                                        : AppleColors.systemBlue,
                                  ),
                                  const SizedBox(width: 5),
                                ],
                                Text(
                                  '${line.name} (${line.episodes.length})',
                                  style: TextStyle(
                                    color: selected
                                        ? Colors.white
                                        : AppleColors.labelPrimary,
                                    fontSize: 12.5,
                                    fontWeight: selected
                                        ? FontWeight.w700
                                        : FontWeight.w500,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        ),
                      );
                    }),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
              GestureDetector(
                onTap: () => setState(() => _descending = !_descending),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 11,
                    vertical: 7,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xCC26262C),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                      color: const Color(0x30FFFFFF),
                      width: 0.65,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        _descending
                            ? CupertinoIcons.sort_down
                            : CupertinoIcons.sort_up,
                        size: 13.5,
                        color: AppleColors.labelSecondary,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        _descending ? '倒序' : '正序',
                        style: const TextStyle(
                          color: AppleColors.labelPrimary,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          // 分段区间快速切换（超过 40 集自动显示分段胶囊）
          if (groupCount > 1) ...[
            const SizedBox(height: 10),
            DesktopHorizontalScroller(
              controller: _groupScrollController,
              showArrows: false,
              child: SingleChildScrollView(
                controller: _groupScrollController,
                scrollDirection: Axis.horizontal,
                physics: const BouncingScrollPhysics(),
                child: Row(
                children: List.generate(groupCount, (g) {
                  final gStart = g * _groupSize + 1;
                  final gEnd = math.min((g + 1) * _groupSize, total);
                  final active = g == safeGroup;
                  return Padding(
                    padding: const EdgeInsets.only(right: 7),
                    child: GestureDetector(
                      onTap: () => setState(() => _groupIndex = g),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 180),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 5.5,
                        ),
                        decoration: BoxDecoration(
                          color: active
                              ? const Color(0x330A84FF)
                              : const Color(0x99202026),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: active
                                ? AppleColors.systemBlue
                                : const Color(0x24FFFFFF),
                            width: 0.75,
                          ),
                        ),
                        child: Text(
                          '$gStart-$gEnd',
                          style: TextStyle(
                            color: active
                                ? const Color(0xFF64B5FF)
                                : AppleColors.labelSecondary,
                            fontSize: 12,
                            fontWeight: active
                                ? FontWeight.w700
                                : FontWeight.w500,
                          ),
                        ),
                      ),
                    ),
                  );
                }),
              ),
            ),
          ),
        ],
          if (activeNotice != null) ...[
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              decoration: BoxDecoration(
                color: const Color(0x26FF9F0A),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0x4DFF9F0A), width: 0.6),
              ),
              child: Text(
                activeNotice,
                style: const TextStyle(
                  color: Color(0xFFFFD60A),
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
          const SizedBox(height: 10),
          // 剧集网格卡片
          Flexible(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: isLandscape
                    ? math.min(screenSize.height * 0.6, 300.0)
                    : math.min(screenSize.height * 0.52, 420.0),
              ),
              child: GridView.builder(
                shrinkWrap: true,
                physics: const BouncingScrollPhysics(),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: crossAxisCount,
                  mainAxisSpacing: 8,
                  crossAxisSpacing: 8,
                  mainAxisExtent: 56,
                ),
                itemCount: indices.length,
                itemBuilder: (ctx, idx) {
                  final epIndex = indices[idx];
                  final ep = episodes[epIndex];
                  final unavailReason =
                      widget.episodeUnavailableReason?.call(ep);
                  final isUnavailable = unavailReason != null;
                  final selected =
                      !isUnavailable &&
                      _previewLineIndex == widget.activeLineIndex &&
                      epIndex == widget.activeEpisodeIndex;
                  final parsed = _ParsedEpisodeLabel.parse(ep.name, epIndex);
                  final numBadge =
                      '#${(epIndex + 1).toString().padLeft(2, '0')}';
                  final badgeText = isUnavailable ? '不可解析' : parsed.sizeBadge;

                  final tile = GestureDetector(
                    onTap: () {
                      if (unavailReason != null) {
                        setState(() => _blockedEpisodeNotice = unavailReason);
                        return;
                      }
                      widget.onSelect(_previewLineIndex, epIndex);
                    },
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 11,
                        vertical: 7,
                      ),
                      decoration: BoxDecoration(
                        gradient: selected
                            ? const LinearGradient(
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                                colors: [Color(0xFF1D8BFF), Color(0xFF0A6CE8)],
                              )
                            : const LinearGradient(
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                                colors: [Color(0xCC28282F), Color(0xB81D1D23)],
                              ),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: selected
                              ? const Color(0xAAFFFFFF)
                              : const Color(0x28FFFFFF),
                          width: selected ? 0.9 : 0.65,
                        ),
                        boxShadow: selected
                            ? const [
                                BoxShadow(
                                  color: Color(0x450A84FF),
                                  blurRadius: 12,
                                  offset: Offset(0, 4),
                                ),
                              ]
                            : null,
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              if (selected) ...[
                                const Icon(
                                  CupertinoIcons.play_fill,
                                  size: 11,
                                  color: Colors.white,
                                ),
                                const SizedBox(width: 4),
                              ],
                              Text(
                                numBadge,
                                style: TextStyle(
                                  color: selected
                                      ? const Color(0xE6FFFFFF)
                                      : AppleColors.labelTertiary,
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const Spacer(),
                              if (badgeText.isNotEmpty)
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 5.5,
                                    vertical: 1.5,
                                  ),
                                  decoration: BoxDecoration(
                                    color: selected
                                        ? const Color(0x33FFFFFF)
                                        : const Color(0x22FFFFFF),
                                    borderRadius: BorderRadius.circular(5),
                                  ),
                                  child: Text(
                                    badgeText,
                                    style: TextStyle(
                                      color: selected
                                          ? Colors.white
                                          : AppleColors.labelSecondary,
                                      fontSize: 9.5,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 3),
                          Text(
                            parsed.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 12.5,
                              fontWeight: selected
                                  ? FontWeight.w700
                                  : FontWeight.w600,
                              letterSpacing: -0.2,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                  return isUnavailable
                      ? Opacity(opacity: 0.48, child: tile)
                      : tile;
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}
