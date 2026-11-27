import 'dart:io';
import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart' show SubtitleViewState;
import '../core/ai_lab_features.dart';
import '../core/ai_service.dart';
import '../core/anime4k_controller.dart';
import '../core/bluray_iso_proxy.dart';
import '../core/cast_service.dart';
import '../core/catpaw_host.dart';
import '../core/cms_client.dart';
import '../core/container_metadata_reader.dart';
import '../core/download_service.dart';
import '../core/danmu/dandanplay_provider.dart';
import '../core/danmu/danmu_prefs.dart';
import '../core/danmu/provider.dart';
import '../core/danmu/segment_cache.dart';
import '../core/emby_library.dart';
import '../core/csp_bridge.dart';
import '../core/episode_scraper.dart' hide ScrapedEpisodeInfo;
import '../core/episode_scraper.dart' as ep_scraper show ScrapedEpisodeInfo;
import '../core/cloud_media_proxy.dart';
import '../core/ios_avplayer_controller.dart';
import '../core/ios_mpv_profile.dart';
import '../core/local_media_proxy.dart';
import '../core/models.dart';
import '../core/smb2_client.dart';
import '../core/playback_recovery_policy.dart';
import '../core/playback_startup.dart';
import '../core/playback_wakelock.dart';
import '../core/ohos_runtime.dart';
import '../core/series_scraper.dart';
import '../core/subtitle_layout.dart';
import '../core/video_kernel.dart';
import '../core/web_media_resolver.dart';
import '../core/windows_tray_service.dart';
import '../core/windows_video_quality.dart';
import '../core/wogg_source.dart';
import '../core/work_aggregation.dart';
import 'player_interaction_layers.dart';
import '../core/storage_service.dart';
import 'apple_theme.dart';
import 'cast_avatar_section.dart';
import 'danmu/danmu_layer.dart';
import 'danmu/danmu_settings_sheet.dart';
import 'episode_scrape_sheet.dart';
import 'favorite_postcard_animation.dart';
import 'ios_ai_lab_sheets.dart';
import 'ios_glass_popover.dart';
import 'ios_liquid_glass.dart';
import 'live_station_badge.dart';
import 'motion/brand_logo_loader.dart';
import 'onboarding/first_play_gesture_hint.dart';
import 'onboarding/onboarding_prefs.dart';
import 'windows_appearance.dart';
import 'desktop_horizontal_scroller.dart';
import 'desktop_player_window.dart';
import 'mobile_player_chrome.dart';
import 'netdisk_sheet.dart';
import 'player/desktop_player_hud.dart';
import 'player/gesture_state_machine.dart';
import 'player/ios_cast_panel.dart';
import 'player/ios_player_chrome.dart';
import 'player/ios_player_toolbar_sheet.dart';
import 'player/player_hud_prefs.dart';
import 'player/skip_countdown.dart';
import 'player/sleep_timer.dart';
import 'player/slim_progress_bar.dart';
import 'player/speed_capsule.dart';
import 'player/start_spec_overlay.dart';
import 'poster_image.dart';
import 'series_scrape_sheet.dart';
import 'source_verification_dialog.dart';
import 'tv/tv_player_overlay.dart';
import 'windows_title_bar.dart';

/// Explicit live playback startup phases so early audio/position events cannot
/// masquerade as audio-only radio before track discovery completes, and
/// clockless video streams that render real frames do not trigger spurious
/// startup failover.
enum _LiveStartupPhase {
  tracksUnknown,
  confirmedAudioOnly,
  awaitingVideoFrame,
  videoFrameRendered,
}

/// Snapshot of the embedded mini-player's live/VOD playback state handed off
/// when the user expands into the full player window.
class EmbeddedPlaybackState {
  final LiveChannel? liveChannel;
  final int lineIndex;
  final int episodeIndex;
  final int positionMs;

  const EmbeddedPlaybackState({
    this.liveChannel,
    required this.lineIndex,
    required this.episodeIndex,
    this.positionMs = 0,
  });
}

/// Apple AVPlayerViewController / iOS 26 Concentric Spatial Cinema video player:
/// - Unified iOS/iPadOS 26 Liquid Glass HUD (`IosPlayerChrome`) with zero
///   scattered `UiKitView` overlays over the active video surface
/// - Deterministic touch & desktop keyboard gesture state machine
/// - Desktop HUD preserving Windows `winFastGlass` blur-free panels
/// - Reserved Wave 2 slots for `DanmuLayer`, `FirstPlayGestureHint`, and
///   `BrandLogoLoader`.
/// Confirmed playback identity emitted by [PlayerScreen] only AFTER actual
/// media playback starts (or switches/auto-advances and starts). Failed opens
/// never emit this so Detail screens never prematurely move the active-episode
/// marker.
class PlayerPlaybackConfirmation {
  final String siteKey;
  final String videoId;
  final int lineIndex;
  final String lineId;
  final String lineName;
  final int episodeIndex;
  final String episodeName;
  final String episodeUrl;

  const PlayerPlaybackConfirmation({
    required this.siteKey,
    required this.videoId,
    required this.lineIndex,
    required this.lineId,
    required this.lineName,
    required this.episodeIndex,
    required this.episodeName,
    required this.episodeUrl,
  });
}

class PlayerScreen extends StatefulWidget {
  final CmsSite site;
  final CmsVideo video;
  final int initialLineIndex;
  final int initialEpisodeIndex;
  final int initialPositionMs;
  final StorageService storage;
  final CmsClient? client;
  final List<WorkSourceRef> alternativeSources;
  final Map<String, CmsVideo> preloadedSourceDetails;
  final bool isLive;
  final List<LiveGroup> liveGroups;
  final LiveChannel? initialLiveChannel;
  final bool embedded;
  final VoidCallback? onEmbeddedClose;
  final VoidCallback? onEmbeddedExpand;
  final void Function(EmbeddedPlaybackState state)? onEmbeddedExpandWithState;
  /// Wave 2 reserved slot: mounted strictly below subtitles & HUD controls.
  final Widget? danmuLayer;
  /// Wave 2 reserved slot: first-play interactive gesture guidance overlay.
  final Widget? firstPlayGestureHint;
  /// Wave 2 reserved slot: replaces default spinner with BrandLogoLoader.
  final Widget? loadingIndicator;
  /// Wave 2 reserved callbacks & state for danmu controls.
  final bool danmuEnabled;
  final VoidCallback? onToggleDanmu;
  final VoidCallback? onOpenDanmuSettings;
  final ValueChanged<PlayerPlaybackConfirmation>? onPlaybackConfirmed;
  @visibleForTesting
  final Player? debugPlayer;
  @visibleForTesting
  final IosAvPlayerController? debugIosAvPlayerController;
  @visibleForTesting
  final Widget? debugVideoSurface;
  @visibleForTesting
  final Widget? debugSubtitleLayer;
  @visibleForTesting
  final PlayerHudPrefs? debugHudPrefs;
  @visibleForTesting
  final DanmuProvider? debugDanmuProvider;
  @visibleForTesting
  final DandanplayProvider Function(DanmuSettings)? debugDanmuProviderFactory;
  @visibleForTesting
  final DanmuSettings? debugDanmuSettings;
  @visibleForTesting
  final OnboardingPrefs? debugOnboardingPrefs;
  @visibleForTesting
  final Anime4kController? debugAnime4kController;
  @visibleForTesting
  final Stream<bool>? debugLiveVideoOutputStream;
  @visibleForTesting
  final WindowsVideoQualityController? debugWinQualityController;
  @visibleForTesting
  final VideoKernel Function(WindowsPlaybackEngine engine)?
      debugWindowsKernelFactory;
  @visibleForTesting
  final VideoKernel Function(bool useIosMdk)? debugIosKernelFactory;
  @visibleForTesting
  final List<AiSubtitleCue>? debugInitialAiOverlayCues;
  @visibleForTesting
  final ValueChanged<Future<void> Function(AiCuratedPick)>?
      debugOnBindSwitchPickForTest;
  @visibleForTesting
  final ValueChanged<Map<String, Object?> Function()>?
      debugOnBindStateInspectorForTest;

  const PlayerScreen({
    super.key,
    required this.site,
    required this.video,
    required this.initialLineIndex,
    required this.initialEpisodeIndex,
    required this.storage,
    this.client,
    this.alternativeSources = const [],
    this.preloadedSourceDetails = const {},
    this.initialPositionMs = 0,
    this.isLive = false,
    this.liveGroups = const [],
    this.initialLiveChannel,
    this.embedded = false,
    this.onEmbeddedClose,
    this.onEmbeddedExpand,
    this.onEmbeddedExpandWithState,
    this.danmuLayer,
    this.firstPlayGestureHint,
    this.loadingIndicator,
    this.danmuEnabled = false,
    this.onToggleDanmu,
    this.onOpenDanmuSettings,
    this.onPlaybackConfirmed,
    this.debugPlayer,
    this.debugIosAvPlayerController,
    this.debugVideoSurface,
    this.debugSubtitleLayer,
    this.debugHudPrefs,
    this.debugDanmuProvider,
    this.debugDanmuProviderFactory,
    this.debugDanmuSettings,
    this.debugOnboardingPrefs,
    this.debugAnime4kController,
    this.debugLiveVideoOutputStream,
    this.debugWinQualityController,
    this.debugWindowsKernelFactory,
    this.debugIosKernelFactory,
    this.debugInitialAiOverlayCues,
    this.debugOnBindSwitchPickForTest,
    this.debugOnBindStateInspectorForTest,
  });

  /// The resolver already applies origin rules and explicit playback headers.
  /// Re-merging subscription headers here would restore filtered credentials.
  Media mediaForPlayback(CmsEpisode episode, {Duration? start}) => Media(
    episode.url,
    httpHeaders: Map<String, String>.of(episode.headers),
    start: start,
  );

  static ({int? season, int episode})? _extractSeasonEpisodeFromText(
    String rawText,
  ) {
    final trimmed = rawText.trim();
    if (trimmed.isEmpty) return null;

    // 1. Explicit English Season + Episode (`S01E09`, `S2.EP09`, `S01 E09`).
    final seMatch = RegExp(
      r'(?:^|[^A-Za-z0-9])S\s*0*(\d{1,3})\s*[._\-\s]*E(?:P)?\s*0*(\d{1,4})(?=$|[^0-9])',
      caseSensitive: false,
    ).firstMatch(trimmed);
    if (seMatch != null) {
      final s = int.tryParse(seMatch.group(1)!);
      final e = int.tryParse(seMatch.group(2)!);
      if (s != null && e != null) return (season: s, episode: e);
    }

    // 2. `1x09` / `2x09` notation.
    final xMatch = RegExp(
      r'(?:^|[^A-Za-z0-9])0*(\d{1,2})[xX]0*(\d{1,4})(?=$|[^0-9])',
    ).firstMatch(trimmed);
    if (xMatch != null) {
      final s = int.tryParse(xMatch.group(1)!);
      final e = int.tryParse(xMatch.group(2)!);
      if (s != null && e != null) return (season: s, episode: e);
    }

    // Extract optional standalone season marker (`第2季` / `Season 2` / `S02`).
    int? parsedSeason;
    final cnSeason = RegExp(
      r'第\s*([0-9一二三四五六七八九十百零〇]+)\s*[季部]',
    ).firstMatch(trimmed);
    if (cnSeason != null) {
      parsedSeason = EpisodeScraper.parseChineseOrArabicNumber(
        cnSeason.group(1)!,
      );
    } else {
      final enSeason = RegExp(
        r'(?:^|[^A-Za-z0-9])(?:Season|S)\s*0*(\d{1,3})(?=$|[^0-9])',
        caseSensitive: false,
      ).firstMatch(trimmed);
      if (enSeason != null) {
        parsedSeason = int.tryParse(enSeason.group(1)!);
      }
    }

    // 3. Chinese episode marker (`第9集`, `第二季 第09集`).
    final cnEp = RegExp(
      r'第\s*([0-9一二三四五六七八九十百零〇]+)\s*[集话期回]',
    ).firstMatch(trimmed);
    if (cnEp != null) {
      final e = EpisodeScraper.parseChineseOrArabicNumber(cnEp.group(1)!);
      if (e != null) return (season: parsedSeason, episode: e);
    }

    // 4. Standalone `EP09` / `E09`.
    final epMatch = RegExp(
      r'(?:^|[^A-Za-z0-9])EP?\s*0*(\d{1,4})(?=$|[^0-9])',
      caseSensitive: false,
    ).firstMatch(trimmed);
    if (epMatch != null) {
      final e = int.tryParse(epMatch.group(1)!);
      if (e != null) return (season: parsedSeason, episode: e);
    }

    // 5. Bare episode number (`09`).
    final bareNum = RegExp(r'^0*(\d{1,4})$').firstMatch(trimmed);
    if (bareNum != null) {
      final e = int.tryParse(bareNum.group(1)!);
      if (e != null) return (season: parsedSeason, episode: e);
    }

    return null;
  }

  static ({int? season, int episode})? _extractSeasonEpisodeFromEpisode(
    CmsEpisode ep,
  ) {
    if (ep.sourceEpisodeNumber != null && ep.sourceEpisodeNumber! > 0) {
      return (
        season: ep.sourceSeasonNumber,
        episode: ep.sourceEpisodeNumber!,
      );
    }
    if (!ep.nameIsGenerated) {
      final fromName = _extractSeasonEpisodeFromText(ep.name);
      if (fromName != null) return fromName;
    }
    if (ep.originalFileName.trim().isNotEmpty) {
      final fromOrig = _extractSeasonEpisodeFromText(ep.originalFileName);
      if (fromOrig != null) return fromOrig;
    }
    return null;
  }

  /// Resolves a single unambiguous episode index in [eps] matching [history]
  /// using strict 3-tier precedence:
  ///   1. Stable media identity (`WatchHistoryEntry.effectiveMediaId`),
  ///      preserving identity even when duplicate-named files (e.g. `video.mkv`)
  ///      are reordered;
  ///   2. Complete `(season, episode)` match (so `S01E09` never matches `S02E09`),
  ///      requiring a unique candidate;
  ///   3. Unique exact name match (never guessing across duplicate-named files
  ///      such as two `video.mkv` without a matching media ID).
  static int? _matchRecommendedEpisodeIndex(
    List<CmsEpisode> eps,
    WatchHistoryEntry history, {
    required bool sameLine,
  }) {
    if (eps.isEmpty) return null;
    final cleanMediaId = history.effectiveMediaId;
    final histName = history.episode.trim();
    final histNameLower = histName.toLowerCase();

    // Tier 1: Stable media identity (highest priority).
    if (cleanMediaId.isNotEmpty) {
      final mediaMatches = <int>[
        for (var i = 0; i < eps.length; i++)
          if (WatchHistoryEntry.matchesEpisodeUrl(cleanMediaId, eps[i].url)) i,
      ];
      if (mediaMatches.length == 1) {
        return mediaMatches.first;
      }
      if (mediaMatches.length > 1) {
        if (histNameLower.isNotEmpty) {
          final narrowed = mediaMatches
              .where((i) => eps[i].name.trim().toLowerCase() == histNameLower)
              .toList();
          if (narrowed.length == 1) return narrowed.first;
        }
        return null;
      }
    }

    // Tier 2: Complete (season, episode) match.
    final histSE = _extractSeasonEpisodeFromText(histName);
    if (histSE != null) {
      final seMatches = <int>[
        for (var i = 0; i < eps.length; i++)
          if (() {
            final epSE = _extractSeasonEpisodeFromEpisode(eps[i]);
            return epSE != null &&
                epSE.episode == histSE.episode &&
                epSE.season == histSE.season;
          }())
            i,
      ];
      if (seMatches.length == 1) {
        return seMatches.first;
      }
      if (seMatches.length > 1 && histNameLower.isNotEmpty) {
        final exact = seMatches
            .where((i) => eps[i].name.trim().toLowerCase() == histNameLower)
            .toList();
        if (exact.length == 1) return exact.first;
      }
      return null;
    }

    // Tier 3: Unique exact episode name (refuses ambiguous duplicate names).
    if (histNameLower.isNotEmpty) {
      final nameMatches = <int>[
        for (var i = 0; i < eps.length; i++)
          if (!eps[i].nameIsGenerated &&
              eps[i].name.trim().toLowerCase() == histNameLower)
            i,
      ];
      if (nameMatches.length == 1) {
        final candidate = eps[nameMatches.first];
        // On the same line, if history recorded a stable media ID and the sole
        // same-named file carries a different stable media ID, do not guess.
        if (sameLine &&
            cleanMediaId.isNotEmpty &&
            candidate.url.trim().isNotEmpty &&
            !WatchHistoryEntry.matchesEpisodeUrl(cleanMediaId, candidate.url)) {
          return null;
        }
        return nameMatches.first;
      }
    }

    return null;
  }

  /// Resolves the target line, episode index, and resume position for an AI
  /// recommended pick switch. Matches stable media identity first, then
  /// complete `(season, episode)`, then unique exact episode name; restores
  /// [historyEntry.resumePosition] ONLY on an unambiguous match, otherwise
  /// falls back cleanly to `(targetLine, 0, resumeMs: 0)`.
  @visibleForTesting
  static ({int lineIndex, int episodeIndex, int resumeMs})
      resolveRecommendedSwitchTarget({
    required List<CmsLine> playableLines,
    required int recommendedLineIndex,
    WatchHistoryEntry? historyEntry,
  }) {
    if (playableLines.isEmpty) {
      return (lineIndex: 0, episodeIndex: 0, resumeMs: 0);
    }
    final safeRecLine = recommendedLineIndex.clamp(0, playableLines.length - 1);
    if (historyEntry == null ||
        historyEntry.complete ||
        historyEntry.resumePosition <= 0) {
      return (lineIndex: safeRecLine, episodeIndex: 0, resumeMs: 0);
    }

    final cleanLineId = historyEntry.lineId.trim();
    final cleanLineName = historyEntry.line.trim();
    final cleanMediaId = historyEntry.effectiveMediaId;

    int? matchedLineIdx;
    if (cleanLineId.isNotEmpty) {
      final idMatches = <int>[
        for (var i = 0; i < playableLines.length; i++)
          if (playableLines[i].id.trim() == cleanLineId) i,
      ];
      if (idMatches.length == 1) {
        matchedLineIdx = idMatches.first;
      } else if (idMatches.length > 1 && cleanMediaId.isNotEmpty) {
        final narrowed = idMatches
            .where(
              (i) => playableLines[i].episodes.any(
                (e) => WatchHistoryEntry.matchesEpisodeUrl(cleanMediaId, e.url),
              ),
            )
            .toList();
        if (narrowed.length == 1) matchedLineIdx = narrowed.first;
      }
    }
    if (matchedLineIdx == null && cleanLineName.isNotEmpty) {
      final nameMatches = <int>[
        for (var i = 0; i < playableLines.length; i++)
          if (playableLines[i].name.trim() == cleanLineName) i,
      ];
      if (nameMatches.length == 1) {
        matchedLineIdx = nameMatches.first;
      } else if (nameMatches.length > 1 && cleanMediaId.isNotEmpty) {
        final narrowed = nameMatches
            .where(
              (i) => playableLines[i].episodes.any(
                (e) => WatchHistoryEntry.matchesEpisodeUrl(cleanMediaId, e.url),
              ),
            )
            .toList();
        if (narrowed.length == 1) matchedLineIdx = narrowed.first;
      }
    }

    List<(int, int)> findGlobalMediaIdHits() {
      if (cleanMediaId.isEmpty) return const <(int, int)>[];
      final hits = <(int, int)>[];
      for (var li = 0; li < playableLines.length; li++) {
        final eps = playableLines[li].episodes;
        for (var ei = 0; ei < eps.length; ei++) {
          if (WatchHistoryEntry.matchesEpisodeUrl(cleanMediaId, eps[ei].url)) {
            hits.add((li, ei));
          }
        }
      }
      return hits;
    }

    if (matchedLineIdx != null) {
      final matchedEp = _matchRecommendedEpisodeIndex(
        playableLines[matchedLineIdx].episodes,
        historyEntry,
        sameLine: true,
      );
      if (matchedEp != null) {
        return (
          lineIndex: matchedLineIdx,
          episodeIndex: matchedEp,
          resumeMs: historyEntry.resumePosition,
        );
      }
      final globalHits = findGlobalMediaIdHits();
      if (globalHits.length == 1) {
        return (
          lineIndex: globalHits.first.$1,
          episodeIndex: globalHits.first.$2,
          resumeMs: historyEntry.resumePosition,
        );
      }
      return (lineIndex: matchedLineIdx, episodeIndex: 0, resumeMs: 0);
    }

    // Old line no longer exists (or history had no recorded line).
    // First scan ALL playable lines for a unique stable media identity so a
    // same-named unrelated file on the recommended line (e.g. `video.mkv`)
    // never steals the resume position from the real historical file on
    // another playable line.
    if (cleanMediaId.isNotEmpty) {
      final globalHits = findGlobalMediaIdHits();
      if (globalHits.length == 1) {
        return (
          lineIndex: globalHits.first.$1,
          episodeIndex: globalHits.first.$2,
          resumeMs: historyEntry.resumePosition,
        );
      }
      if (globalHits.length > 1) {
        return (lineIndex: safeRecLine, episodeIndex: 0, resumeMs: 0);
      }
    }

    // No playable line holds the original stable media ID: fall back to
    // complete (season, episode) or unique exact episode name on the
    // recommended line; ambiguous candidates start cleanly from 0.
    final fallbackMatchedEp = _matchRecommendedEpisodeIndex(
      playableLines[safeRecLine].episodes,
      historyEntry,
      sameLine: false,
    );
    if (fallbackMatchedEp != null) {
      return (
        lineIndex: safeRecLine,
        episodeIndex: fallbackMatchedEp,
        resumeMs: historyEntry.resumePosition,
      );
    }
    return (lineIndex: safeRecLine, episodeIndex: 0, resumeMs: 0);
  }

  /// Formats an actionable Chinese diagnostic message when a live IPTV stream
  /// fails, surfacing upstream HTTP failure codes (e.g. 404/403/502) recorded
  /// by [LocalMediaLease] instead of a vague generic failure.
  static String formatLivePlaybackError(
    Object? error, {
    int? upstreamStatusCode,
  }) {
    if (upstreamStatusCode != null && upstreamStatusCode >= 400) {
      if (upstreamStatusCode == 404 || upstreamStatusCode == 410) {
        return '当前频道源已失效（上游返回 HTTP $upstreamStatusCode），请切换其他频道或更换直播源';
      }
      if (upstreamStatusCode == 401 || upstreamStatusCode == 403) {
        return '当前直播源拒绝访问（上游返回 HTTP $upstreamStatusCode），可能存在防盗链或地区限制';
      }
      if (upstreamStatusCode >= 500) {
        return '上游直播服务器异常（HTTP $upstreamStatusCode），请稍后重试或切换其他源';
      }
      return '直播源请求失败（HTTP $upstreamStatusCode），请切换其他频道/线路';
    }
    if (error is TimeoutException) {
      return '直播源连接超时，请重试或切换其他频道/线路';
    }
    return '直播源暂不可用，请重试或切换其他频道/线路';
  }

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

class _CrossSiteRollbackSnapshot {
  final CmsSite site;
  final CmsVideo video;
  final List<CmsLine> lines;
  final int lineIndex;
  final int episodeIndex;
  final int resumeMs;
  final int targetSession;
  final String failedSiteName;

  const _CrossSiteRollbackSnapshot({
    required this.site,
    required this.video,
    required this.lines,
    required this.lineIndex,
    required this.episodeIndex,
    required this.resumeMs,
    required this.targetSession,
    required this.failedSiteName,
  });
}

class _PlayerScreenState extends State<PlayerScreen>
    with WidgetsBindingObserver {
  late VideoKernel _videoKernel;
  late Player _player;
  bool _playerDisposed = false;
  late Future<void> _playerConfiguration;
  WindowsPlaybackEngine _windowsEngine = WindowsPlaybackEngine.mpv;
  int _mdkFallbackTriggeredSession = -1;
  final Set<String> _mdkAutoFallbackMediaKeys = <String>{};
  int _intendedStartPositionMs = 0;
  bool _hasVideoOutputForSession = false;
  bool _switchingWindowsEngine = false;
  late final CmsClient _client = widget.client ?? CmsClient();
  late CmsSite _activeSite;
  late CmsVideo _activeVideo;
  List<WorkSourceRef> _crossSiteSources = const [];
  final Map<String, CmsVideo> _crossSiteDetails = {};
  final Map<String, String> _crossSiteErrors = {};
  bool _loadingCrossSiteSources = false;
  int _userNavigationGen = 0;
  Completer<void>? _crossSiteAbort;
  _CrossSiteRollbackSnapshot? _pendingCrossSiteRollback;
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
  bool _hudFadingOut = false;
  bool _hudAutoHidden = false;
  Timer? _hudUnmountTimer;
  final GlobalKey<SubtitleViewState> _subtitleViewKey =
      GlobalKey<SubtitleViewState>();
  double _measuredDesktopBottomBarHeight = 0.0;
  SubtitleRenderMode _subtitleRenderMode =
      SubtitleRenderMode.flutterTextOverlay;
  int _lastAppliedMpvSubPos = 100;
  bool? _lastAppliedMpvSubVisible;
  bool _mpvSubtitleAssInitialized = false;
  double _lastAppliedSubtitleOverlayBottomPadding = -1.0;
  Size _lastVideoStackViewport = Size.zero;
  bool _subtitleSyncScheduled = false;
  int _subtitleSyncEpoch = 0;
  bool _screenLocked = false;
  bool _lockButtonVisible = false;
  Timer? _lockHideTimer;
  Timer? _hudTimer;
  bool _speedBoosting = false;
  String _hudText = '';
  late final FocusScopeNode _playerFocusScopeNode = FocusScopeNode();
  late final FocusNode _playerFocusNode = FocusNode();
  late final FocusNode _desktopSliderFocusNode = FocusNode(
    canRequestFocus: false,
  );
  final Set<int> _globalActivePointers = <int>{};
  bool _appInForeground = true;
  bool _resumeOhosOnForeground = false;
  int _ohosBackgroundResumeMs = 0;
  double _previousVolume = 100.0;
  final ScrollController _portraitToolsScrollController = ScrollController();
  String _playbackError = '';
  Object? _playbackErrorCause;
  int? _lastLiveUpstreamStatus;
  bool _allowEvents = false;
  bool _windowsDarkSurfaceApplied = false;
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
  Duration _positionValue = Duration.zero;
  final ValueNotifier<int> _danmuPositionMs = ValueNotifier<int>(0);
  Duration get _position => _positionValue;
  set _position(Duration value) {
    _positionValue = value;
    final ms = value.inMilliseconds;
    if (_danmuPositionMs.value != ms) {
      _danmuPositionMs.value = ms;
    }
  }
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
  SmbMediaStreamProxy? _smbStreamProxy;
  final _startup = PlaybackStartup();
  final _tvSeek = TvRemoteSeekController();
  final GlobalKey _playerStageKey = GlobalKey();
  late final CastController _castController = CastController()
    ..addListener(_onCastStateChanged);
  bool _isFavorite = false;
  bool _portraitSynopsisExpanded = false;
  String _activeResolvedMediaUrl = '';
  Map<String, String> _activeResolvedHeaders = const {};
  int _lastManualOrientationMs = 0;

  bool get _useIosPortraitCompanionMode =>
      !kIsWeb &&
      defaultTargetPlatform == TargetPlatform.iOS &&
      !OhosRuntime.isOhos &&
      !widget.embedded;

  bool _shouldShowPortraitCompanion(Size? size) {
    if (!_useIosPortraitCompanionMode || size == null) return false;
    if (size.height <= size.width) return false;
    // Live TV uses top mini-window + channel/line companion in portrait across
    // both iPhone and iPad portrait so users never face a giant black screen.
    // VOD keeps iPad portrait fullscreen while using portrait companion on iPhone.
    return _isLiveStream || size.shortestSide < 600;
  }

  double _iosDeviceVolume = 0.5;
  double _iosConfirmedDeviceVolume = 0.5;
  bool _iosDeviceVolumeSynced = false;
  bool _iosVolumeReadInFlight = false;
  bool _iosPendingVolumeDragActive = false;
  double _iosPendingVolumeDragDelta = 0.0;
  double? _iosFsmVolumeBaseline;
  double? _iosLegacyVolumeBaseline;
  double? _iosPendingSystemVolume;
  bool _iosSystemVolumeFlushing = false;
  int? _pendingAutoStartPipSession;
  int? _pendingAutoStartPipMediaId;
  int? _cancelStartingPipSession;
  int? _cancelStartingPipMediaId;
  int _iosPipRequestGen = 0;
  bool _iosPipRefreshInFlight = false;
  bool _sessionForceAvPlayerForPip = false;
  Timer? _pendingPipTimeoutTimer;
  int _avClockAnchorMs = 0;
  int? _avObservedPlayingMinPosMs;
  int? _avPendingSeekTargetMs;
  int _avPendingSeekGen = 0;
  bool _avDispatchingSeek = false;
  int _avLastProcessedClockSeq = 0;
  int? _avLastProcessedClockMediaId;
  final ValueNotifier<String> _liveCompanionGroupNotifier =
      ValueNotifier<String>('');
  final ValueNotifier<String> _liveCompanionQueryNotifier =
      ValueNotifier<String>('');
  final TextEditingController _liveCompanionSearchCtrl =
      TextEditingController();

  bool get _hasPendingAutoStartPip =>
      _pendingAutoStartPipSession != null &&
      _pendingAutoStartPipSession == _playSession;

  IosPlaybackEngineMode get _effectiveIosEngineMode =>
      _sessionForceAvPlayerForPip
          ? IosPlaybackEngineMode.avPlayer
          : _iosEngineMode;
  late final PlayerHudPrefs _hudPrefs;
  late final bool _ownsHudPrefs;
  late final PlayerGestureStateMachine _gestureFsm;
  final DesktopKeySeekStateMachine _desktopKeySeek =
      DesktopKeySeekStateMachine();
  late final SleepTimerController _sleepTimer;
  final SkipCountdownController _skipCountdown = SkipCountdownController();
  final StartSpecDisplayController _startSpecController =
      StartSpecDisplayController();
  Timer? _gestureTickTimer;
  Timer? _desktopKeyTickTimer;
  Timer? _verticalHudClearTimer;
  int _gestureClockFloorMs = 0;
  int _desktopKeyClockMs = 0;
  KeySeekPreview? _activeDesktopScrubPreview;
  String _extraTrackSpecInfo = '';
  DanmuSettings _danmuSettings = const DanmuSettings();
  DanmuProvider? _danmuProvider;
  bool _ownsDanmuProvider = false;
  DanmuSegmentCache? _danmuCache;
  final List<DanmuSegmentCache> _deferredDisposedDanmuCaches =
      <DanmuSegmentCache>[];
  DanmuCancelToken? _danmuMatchToken;
  int _danmuSessionGen = 0;
  bool _danmuBoundForEpisode = false;
  EpisodeScrapeOverride _episodeScrapeOverride = const EpisodeScrapeOverride();

  String get _effectiveScrapeTitle {
    if (widget.site.isEffectivelyPrivate) return widget.video.title;
    final custom = _episodeScrapeOverride.customTitle.trim();
    return custom.isNotEmpty ? custom : widget.video.title;
  }

  ScrapedLineResult _scrapeCurrentLine() {
    return EpisodeScraper.scrapeLine(
      _currentLine.episodes,
      override: _episodeScrapeOverride,
      seriesTitle: _effectiveScrapeTitle,
    );
  }

  ep_scraper.ScrapedEpisodeInfo _currentScrapedEpisode() {
    return EpisodeScraper.parseEpisode(
      _currentEpisode.name,
      rawIndex: _episodeIndex,
      episodeOffset: _episodeScrapeOverride.episodeOffset,
      manualEpisodeNumber: _episodeScrapeOverride.manualEpisodeMap[_episodeIndex],
      seriesTitle: _effectiveScrapeTitle,
    );
  }

  Future<void> _showEpisodeScrapeSheet() async {
    if (_isLiveStream || _currentLine.episodes.isEmpty) return;
    _cancelTransientInteractions(GestureInterruptReason.dialogOpened);
    final next = await showEpisodeScrapeSheet(
      context: context,
      seriesTitle: widget.video.title,
      year: widget.video.year,
      episodes: _currentLine.episodes,
      currentOverride: _episodeScrapeOverride,
      forceDark: true,
    );
    if (next == null || !mounted) return;
    await widget.storage.setEpisodeScrapeOverride(
      siteKey: widget.site.key,
      videoId: widget.video.id,
      videoTitle: widget.video.title,
      override: next,
    );
    if (!mounted) return;
    setState(() => _episodeScrapeOverride = next);
    _resetDanmuForEpisode();
    final cur = _currentScrapedEpisode();
    _showHud(
      cur.isSpecial
          ? '已更新剧集刮削（当前：${cur.specialTag ?? '特辑'}）'
          : '已校准集数并重新匹配弹幕（第 ${cur.effectiveEpisodeNumber} 集）',
    );
  }

  DanmuCandidate? _matchedDanmuCandidate;
  List<DanmuCandidate> _pendingDanmuCandidates = const <DanmuCandidate>[];
  int? _scrapedDanmuEpisodeNumber;
  int _activeDanmuEpisodeOffset = 0;
  final Map<String, Map<String, String>> _runtimeContainerTags =
      <String, Map<String, String>>{};
  int _containerProbeGen = 0;
  OnboardingPrefs? _onboardingPrefs;
  bool _hasStartedVodPlayback = false;
  bool _firstPlayHintDismissedThisSession = false;
  late final Anime4kController _anime4kController;
  late final bool _ownsAnime4kController;
  late final WindowsVideoQualityController _winQualityController;
  late final bool _ownsWinQualityController;
  BlurayIsoLease? _blurayIsoLease;
  OfflineHlsLease? _offlineHlsLease;
  List<BlurayChapter> _blurayChapters = const [];

  bool get _isIosPlayerPlatform =>
      !kIsWeb &&
      defaultTargetPlatform == TargetPlatform.iOS &&
      !OhosRuntime.isOhos;
  bool get _isWindowsPlayerPlatform =>
      !kIsWeb &&
      defaultTargetPlatform == TargetPlatform.windows &&
      !OhosRuntime.isOhos;
  bool get _isMacosPlayerPlatform =>
      !kIsWeb &&
      defaultTargetPlatform == TargetPlatform.macOS &&
      !OhosRuntime.isOhos;
  bool get _canUseIosAvPlayerEngine =>
      _isIosPlayerPlatform &&
      (widget.debugIosAvPlayerController != null ||
          (widget.debugPlayer == null && widget.debugVideoSurface == null));
  IosAvPlayerController? _iosAvPlayerController;
  IosPlaybackEngineMode _iosEngineMode = IosPlaybackEngineMode.avPlayer;
  IosHdrToneMappingMode _iosHdrToneMapping = IosHdrToneMappingMode.auto;
  VocalLoudnessPreset _vocalLoudness = VocalLoudnessPreset.off;
  bool _iosLargeBuffer = false;
  bool _usingAvPlayer = false;
  bool _fallbackInFlight = false;
  String _lastAvExternalAudioUrl = '';
  final List<StreamSubscription<dynamic>> _iosAvSubscriptions = [];
  int? _avPhysicalMemoryBytes;
  bool _wasAvPlaying = false;
  bool _wasAvBuffering = false;
  bool _wasAvCompleted = false;
  bool _lastAppliedIosMpvLowPowerThermal = false;
  int _lastRenderedPositionMs = -1;
  bool _lastAvPipStarting = false;
  bool _lastAvPipPossible = false;
  bool _lastAvAirPlayActive = false;
  bool _userPausedPlayback = false;
  bool _pausedEngineInvalidated = false;
  bool _ohosRenderedFirstFrame = false;
  bool _switchingIosKernel = false;
  late List<String> _iosToolbarItems;

  // Universal cross-engine AI Subtitle Overlay state (renders identically on AVPlayer, MDK & MPV).
  final ValueNotifier<int> _aiSubtitleClockMsNotifier = ValueNotifier<int>(0);
  final ValueNotifier<int> _aiSubtitleStateRevision = ValueNotifier<int>(0);
  List<AiSubtitleCue> _aiOverlayCues = const <AiSubtitleCue>[];
  Map<String, String> _aiOverlayGlossary = const <String, String>{};
  List<AiSubtitleCue> _aiStudioDraftCues = const <AiSubtitleCue>[];
  Map<String, String> _aiStudioDraftGlossary = const <String, String>{};
  Duration _aiStudioDraftOffset = Duration.zero;
  bool _aiStudioDraftMatchesOverlay = false;
  int _aiOverlayMountGen = 0;
  String _aiOverlayMediaKey = '';
  int _aiSubtitleMediaGen = 0;
  bool _aiOverlayBilingual = true;
  Duration _aiOverlayOffset = Duration.zero;
  String _aiOverlayLabel = '';
  bool _aiLiveEmbeddedTranslateEnabled = false;
  bool _avConfirmedTextSubtitleTrackForSession = false;
  String? _avConfirmedTextSubtitleTrackId;
  String? _lastAvSelectedSubtitleTrackId;
  String _lastAvSubtitleTrackSignature = '';
  String _aiLiveRawLine = '';
  String _aiLiveTranslatedLine = '';
  int _aiLiveTranslateGen = 0;
  bool _aiNonTextTrackNotifiedForSession = false;
  int _iosAutoFallbackCountForOpen = 0;

  bool get _isPrivateBackdrop =>
      _activeSite.isEffectivelyPrivate ||
      widget.site.isEffectivelyPrivate ||
      AiService.instance.isPrivacySessionActive;

  String get _currentAiSubtitleMediaKey =>
      '${_activeSite.key}::${_activeVideo.id}::$_episodeIndex';

  AiSubtitleSessionState? get _currentAiSubtitleSessionSnapshot {
    if (_aiOverlayMediaKey != _currentAiSubtitleMediaKey) return null;
    if (_aiOverlayCues.isEmpty &&
        _aiOverlayGlossary.isEmpty &&
        _aiStudioDraftCues.isEmpty &&
        !_aiLiveEmbeddedTranslateEnabled &&
        _aiOverlayOffset == Duration.zero) {
      return null;
    }
    final hasMountedOverlay = _aiOverlayCues.isNotEmpty;
    return AiSubtitleSessionState(
      cues: _aiOverlayCues,
      glossary: _aiOverlayGlossary,
      bilingual: _aiOverlayBilingual,
      offset: _aiOverlayOffset,
      label: _aiOverlayLabel,
      overlayActive: hasMountedOverlay,
      liveEmbeddedTranslateEnabled: _aiLiveEmbeddedTranslateEnabled,
      draftCues: _aiStudioDraftCues.isNotEmpty
          ? _aiStudioDraftCues
          : _aiOverlayCues,
      draftGlossary: _aiStudioDraftGlossary.isNotEmpty
          ? _aiStudioDraftGlossary
          : _aiOverlayGlossary,
      draftOffset: _aiStudioDraftMatchesOverlay
          ? _aiOverlayOffset
          : _aiStudioDraftOffset,
      draftMatchesOverlay: hasMountedOverlay && _aiStudioDraftMatchesOverlay,
    );
  }

  bool _canExtractCurrentAvSubtitleText(IosAvPlayerController avCtrl) {
    if (avCtrl.currentSubtitleHasNonTextSamples &&
        avCtrl.activeSubtitleLines.isEmpty) {
      return false;
    }
    IosAvPlayerTrack? selected;
    for (final t in avCtrl.subtitleTracks) {
      if (t.selected) {
        selected = t;
        break;
      }
    }
    if (selected != null) {
      if (selected.subtitleFormat == IosAvSubtitleFormat.bitmap ||
          selected.isBitmap ||
          selected.isTextExtractable == false ||
          MdkPlatformPlayer.isBitmapSubtitleCodec(selected.title)) {
        return false;
      }
      if (selected.subtitleFormat == IosAvSubtitleFormat.text ||
          selected.isTextExtractable == true) {
        return true;
      }
      // Unknown format: keep native subtitle rendering visible until THIS
      // selected track actually emits real text lines.
      return avCtrl.activeSubtitleLines.isNotEmpty ||
          (_avConfirmedTextSubtitleTrackId != null &&
              _avConfirmedTextSubtitleTrackId == selected.id);
    }
    return avCtrl.activeSubtitleLines.isNotEmpty ||
        _avConfirmedTextSubtitleTrackForSession;
  }

  ({bool suppress, bool allowNonText}) _resolveAvNativeSubtitleSuppression(
    IosAvPlayerController avCtrl,
  ) {
    if (avCtrl.isPipActive || avCtrl.isPipStarting) {
      return (suppress: false, allowNonText: false);
    }
    // Explicit external SRT / AI full-track overlay replaces native rendering
    // even when the embedded track is graphical/bitmap (PGS/VobSub).
    if (_aiOverlayCues.isNotEmpty) {
      return (suppress: true, allowNonText: true);
    }
    // Live embedded translation only suppresses native rendering when the
    // selected track is text-extractable; graphical tracks stay natively visible.
    if (_aiLiveEmbeddedTranslateEnabled) {
      return (
        suppress: _canExtractCurrentAvSubtitleText(avCtrl),
        allowNonText: false,
      );
    }
    return (suppress: false, allowNonText: false);
  }

  void _syncAvPlayerSubtitleSuppression({bool force = false}) {
    if (!_usingAvPlayer) return;
    final avCtrl = _iosAvPlayerController;
    if (avCtrl == null) return;
    final decision = _resolveAvNativeSubtitleSuppression(avCtrl);
    unawaited(
      avCtrl.setSuppressNativeSubtitleRendering(
        decision.suppress,
        allowNonText: decision.allowNonText,
        force: force,
      ),
    );
  }

  void _clearAiLiveSubtitleLine({bool notify = true}) {
    final changed =
        _aiLiveRawLine.isNotEmpty || _aiLiveTranslatedLine.isNotEmpty;
    _aiLiveRawLine = '';
    _aiLiveTranslatedLine = '';
    _aiLiveTranslateGen++;
    if (notify && changed) {
      _aiSubtitleStateRevision.value++;
    }
  }

  List<String> get _currentActiveEmbeddedSubtitleLines {
    if (_usingAvPlayer) {
      return _iosAvPlayerController?.activeSubtitleLines ?? const <String>[];
    }
    try {
      return _player.state.subtitle;
    } catch (_) {
      return const <String>[];
    }
  }

  bool get _hasActiveAiSubtitleOverlay =>
      _aiOverlayCues.isNotEmpty || _aiLiveEmbeddedTranslateEnabled;

  bool get _isMultiVersionMovie =>
      !_isLiveStream &&
      EpisodeScraper.isLikelyMultiVersionMovie(
        _currentLine.episodes,
        videoTitle: _activeVideo.title,
        videoTag: _activeVideo.tag,
        videoRemarks: _activeVideo.remarks,
        override: _episodeScrapeOverride,
      );

  String get _activeIosEngineBadgeLabel {
    if (_usingAvPlayer) return 'AVPlayer';
    if (_videoKernel.isMdk) return 'MDK';
    return 'MPV';
  }

  static String _avGravityForFit(BoxFit fit) => switch (fit) {
    BoxFit.cover => 'resizeAspectFill',
    BoxFit.fill => 'resize',
    _ => 'resizeAspect',
  };

  void _setFit(BoxFit nextFit) {
    setState(() => _fit = nextFit);
    if (_usingAvPlayer) {
      unawaited(
        _iosAvPlayerController?.setVideoGravity(_avGravityForFit(nextFit)),
      );
    } else {
      unawaited(_syncNativeSubtitleState());
    }
  }

  double get _engineVolume100 => _usingAvPlayer
      ? ((_iosAvPlayerController?.volume ?? 1.0) * 100.0).clamp(0.0, 100.0)
      : _player.state.volume;

  Future<void> _enginePlay() {
    _userPausedPlayback = false;
    _startup.setUserPaused(false);
    if (_hudText.startsWith('已暂停')) {
      _hudTimer?.cancel();
      if (mounted) {
        setState(() => _hudText = '');
      } else {
        _hudText = '';
      }
    }
    if (_pausedEngineInvalidated && _playbackError.isEmpty) {
      _pausedEngineInvalidated = false;
      final resumeMs = _isLiveStream
          ? 0
          : (_position.inMilliseconds > 0
                ? _position.inMilliseconds
                : _lastKnownPositionMs);
      return _openCurrentEpisode(resumeMs: resumeMs);
    }
    return _usingAvPlayer
        ? (_iosAvPlayerController?.play() ?? Future<void>.value())
        : _player.play();
  }

  Future<void> _enginePause() {
    _userPausedPlayback = true;
    _startup.setUserPaused(true);
    return _usingAvPlayer
        ? (_iosAvPlayerController?.pause() ?? Future<void>.value())
        : _player.pause();
  }

  Future<void> _enginePlayOrPause() {
    final shouldPause = _playing ||
        (!_userPausedPlayback &&
            (_loading || _buffering) &&
            _playbackError.isEmpty);
    if (_usesOhosAvPlayer || _usingAvPlayer || _pausedEngineInvalidated) {
      return shouldPause ? _enginePause() : _enginePlay();
    }
    if (shouldPause) {
      _userPausedPlayback = true;
      _startup.setUserPaused(true);
      if (!_playing) return _player.pause();
    } else {
      _userPausedPlayback = false;
      _startup.setUserPaused(false);
      if (_hudText.startsWith('已暂停')) {
        _hudTimer?.cancel();
        if (mounted) {
          setState(() => _hudText = '');
        } else {
          _hudText = '';
        }
      }
    }
    return _player.playOrPause();
  }

  bool get _usesOhosAvPlayer =>
      _player.platform is OhosPlatformPlayer || OhosRuntime.isOhos;

  List<double> get _supportedPlaybackSpeeds => _usesOhosAvPlayer
      ? OhosPlatformPlayer.supportedSpeeds
      : const <double>[0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0];

  double _normalizePlaybackSpeed(double rate) {
    if (_usesOhosAvPlayer) {
      return OhosPlatformPlayer.normalizeSupportedRate(rate);
    }
    return double.parse(
      rate
          .clamp(StorageService.minPlaySpeed, StorageService.maxPlaySpeed)
          .toStringAsFixed(2),
    );
  }

  Future<void> _engineSetRate(double rate) => _usingAvPlayer
      ? (_iosAvPlayerController?.setRate(rate) ?? Future<void>.value())
      : _player.setRate(_normalizePlaybackSpeed(rate));

  Future<void> _engineSetVolume100(double vol100) {
    if (_isWindowsPlayerPlatform && _isLiveStream) {
      unawaited(widget.storage.setWindowsLiveVolume(vol100));
    }
    return _usingAvPlayer
        ? (_iosAvPlayerController?.setVolume((vol100 / 100.0).clamp(0.0, 1.0)) ??
            Future<void>.value())
        : _player.setVolume(vol100);
  }

  bool get _useEnhancedHud =>
      !OhosRuntime.isOhos && !OhosRuntime.shouldUseTvUi(widget.storage.tvUiMode);

  bool get _useIos26PlayerChrome =>
      _useEnhancedHud &&
      !kIsWeb &&
      defaultTargetPlatform == TargetPlatform.iOS &&
      !widget.embedded;

  bool get _storageReduceTransparency =>
      widget.storage.glassBlurLevel == 'solid';

  bool get _canUseNativeIosSheet =>
      _useIos26PlayerChrome && IosLiquidGlassBridge.isAvailable;

  bool get _effectiveSheetForceOpaque =>
      _storageReduceTransparency ||
      (!OhosRuntime.isOhos && IosLiquidGlassBridge.reduceTransparency) ||
      GlassworkBackdrop.reduceTransparency.value ||
      GlassworkBackdrop.intensity.value <= 0.02;

  bool _isEffectiveReduceTransparency(BuildContext context) =>
      _storageReduceTransparency ||
      (!OhosRuntime.isOhos && IosLiquidGlassBridge.reduceTransparency) ||
      GlassworkBackdrop.reduceTransparency.value ||
      GlassworkBackdrop.intensity.value <= 0.02 ||
      MediaQuery.highContrastOf(context);

  bool get _canRunSkipCountdown =>
      mounted &&
      _appInForeground &&
      _playing &&
      !_screenLocked &&
      !widget.embedded &&
      !_isLiveStream;

  void _suspendSkipCountdown() {
    if (_skipCountdown.isActive) {
      _skipCountdown.reset();
    }
  }

  void _maybeEvaluateSkipTriggers({
    Duration? positionOverride,
    Duration? durationOverride,
  }) {
    if (!_canRunSkipCountdown || _skipCountdown.isActive) return;
    final pos = positionOverride ?? _position;
    final effectiveDur = durationOverride ??
        (_duration.inMilliseconds > 0
            ? _duration
            : Duration(milliseconds: _lastKnownDurationMs));
    if (effectiveDur <= Duration.zero) return;

    if (!_outroSkippedForSession &&
        _skipOutroSec > 0 &&
        effectiveDur.inSeconds > _skipOutroSec + 30 &&
        pos.inSeconds > 10 &&
        (effectiveDur - pos).inSeconds <= _skipOutroSec) {
      final sessionAtTrigger = _playSession;
      if (_hudPrefs.effectiveSkipCountdown) {
        _skipCountdown.start(
          kind: SkipCountdownKind.outro,
          onConfirm: () {
            if (!mounted ||
                sessionAtTrigger != _playSession ||
                !_canRunSkipCountdown) {
              return;
            }
            _outroSkippedForSession = true;
            unawaited(_saveProgress(immediate: true, syncImmediate: false));
            _showHud('已自动跳过片尾 ${_skipOutroSec}s');
            _handleEpisodeEnd();
          },
          onCancel: () {
            _outroSkippedForSession = true;
            if (mounted) _showHud('已取消跳过片尾');
          },
        );
      } else {
        _outroSkippedForSession = true;
        unawaited(_saveProgress(immediate: true, syncImmediate: false));
        _showHud('已自动跳过片尾 ${_skipOutroSec}s');
        _handleEpisodeEnd();
      }
      return;
    }

    if (!_introSkippedForSession &&
        _pendingResumeMs <= 0 &&
        _skipIntroSec > 0 &&
        effectiveDur.inSeconds > _skipIntroSec + 30 &&
        pos.inMilliseconds < _skipIntroSec * 1000) {
      final sessionAtTrigger = _playSession;
      final skipSec = _skipIntroSec;
      if (_hudPrefs.effectiveSkipCountdown) {
        _skipCountdown.start(
          kind: SkipCountdownKind.intro,
          onConfirm: () {
            if (!mounted ||
                sessionAtTrigger != _playSession ||
                !_canRunSkipCountdown) {
              return;
            }
            _introSkippedForSession = true;
            _startup.reanchor(Duration(seconds: skipSec));
            _seekPlayer(Duration(seconds: skipSec));
            _showHud('已自动跳过片头 ${skipSec}s');
          },
          onCancel: () {
            _introSkippedForSession = true;
            if (mounted) _showHud('已取消跳过片头');
          },
        );
      } else {
        _introSkippedForSession = true;
        _startup.reanchor(Duration(seconds: skipSec));
        _seekPlayer(Duration(seconds: skipSec));
        _showHud('已自动跳过片头 ${skipSec}s');
      }
    }
  }

  void _restorePlayerFocusIfCurrent() {
    if (!mounted) return;
    if (widget.embedded ||
        FocusManager.instance.primaryFocus?.context?.widget is EditableText) {
      return;
    }
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return;
    if (!_playerFocusNode.hasFocus) {
      _playerFocusNode.requestFocus();
    }
  }

  void _resetSliderDraggingSafe({bool scheduleHide = false}) {
    if (!_isSliderDragging) return;
    _isSliderDragging = false;
    if (!mounted) return;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() {});
        if (scheduleHide) _scheduleHide();
      });
    } else {
      setState(() {});
      if (scheduleHide) _scheduleHide();
    }
  }

  void _onGlobalPointerDown(PointerDownEvent event) {
    if (event.kind == PointerDeviceKind.mouse &&
        (event.buttons & kPrimaryMouseButton) == 0) {
      return;
    }
    _globalActivePointers.add(event.pointer);
    if (_globalActivePointers.length >= 2) {
      _cancelTransientInteractions(GestureInterruptReason.multiTouch);
    }
  }

  void _onGlobalPointerUp(PointerUpEvent event) {
    _globalActivePointers.remove(event.pointer);
    if (_useEnhancedHud) {
      _gestureFsm.onPointerCancelOrRemoved(event.pointer);
    }
  }

  void _onGlobalPointerCancel(PointerCancelEvent event) {
    _globalActivePointers.remove(event.pointer);
    if (_useEnhancedHud) {
      _gestureFsm.onPointerCancelOrRemoved(event.pointer);
    }
  }

  List<PlayerSpecBadge> get _fusedSpecBadges => MediaSpecFusion.fuse(
        videoWidth: _videoWidth,
        videoHeight: _videoHeight,
        videoCodec: _videoCodec,
        audioCodec: _audioCodec,
        extraTrackInfo: _extraTrackSpecInfo,
        lineName: _currentLine.name,
        episodeName: _currentEpisode.name,
        streamUrl: _activeStreamUrl,
      );

  SpeedCapsuleMode get _speedCapsuleMode {
    if (!_useEnhancedHud || _screenLocked) return SpeedCapsuleMode.hidden;
    if (_gestureFsm.isSpeedLockReady) return SpeedCapsuleMode.lockReady;
    if (_gestureFsm.isSpeedBoosting) return SpeedCapsuleMode.boosting;
    if (_gestureFsm.isSpeedLocked) return SpeedCapsuleMode.locked;
    return SpeedCapsuleMode.hidden;
  }

  TouchGestureConfig _buildGestureConfig() {
    final prefs = _hudPrefs.data;
    return TouchGestureConfig(
      doubleTapCenterAction: prefs.doubleTapCenter,
      doubleTapSidesAction: prefs.doubleTapSides,
      longPressRestoreMode: prefs.longPressRestoreMode,
      enableVerticalDrags: !_desktop,
      enableLongPressSpeed: !_desktop,
    );
  }

  int _nowGestureMs() {
    final wall = DateTime.now().millisecondsSinceEpoch;
    if (wall > _gestureClockFloorMs) {
      _gestureClockFloorMs = wall;
    }
    return _gestureClockFloorMs;
  }

  void _syncGestureTimer() {
    _gestureTickTimer?.cancel();
    _gestureTickTimer = null;
    final deadline = _gestureFsm.nextTimerDeadlineMs;
    if (deadline == null || !mounted) return;
    final delayMs = math.max(0, deadline - _nowGestureMs());
    _gestureTickTimer = Timer(Duration(milliseconds: delayMs), () {
      _gestureTickTimer = null;
      if (!mounted) return;
      if (deadline > _gestureClockFloorMs) {
        _gestureClockFloorMs = deadline;
      }
      final events = _gestureFsm.onTick(_gestureClockFloorMs);
      _applyGestureEvents(events);
      _syncGestureTimer();
    });
  }

  void _onHudSubstateChanged() {
    if (!mounted) return;
    _gestureFsm.config = _buildGestureConfig();
    setState(() {});
  }

  void _onReduceTransparencyChanged() {
    if (mounted) setState(() {});
  }

  void _onSleepTimerExpired() {
    if (!mounted) return;
    _cancelTransientInteractions(GestureInterruptReason.playbackPaused);
    unawaited(_enginePause());
    PlaybackWakelock.setEnabled(false);
    _showHud('定时关闭已暂停播放');
  }

  void _cancelTransientInteractions(GestureInterruptReason reason) {
    if (reason == GestureInterruptReason.dialogOpened) {
      _hideTimer?.cancel();
      _hudUnmountTimer?.cancel();
      if (_hudFadingOut || _hudAutoHidden || !_controlsVisible) {
        if (mounted) {
          setState(() {
            _hudFadingOut = false;
            _hudAutoHidden = false;
            _controlsVisible = true;
          });
        }
      }
    }
    _gestureTickTimer?.cancel();
    _gestureTickTimer = null;
    _verticalHudClearTimer?.cancel();
    _verticalHudClearTimer = null;
    _iosPendingVolumeDragActive = false;
    _iosPendingVolumeDragDelta = 0.0;
    _iosFsmVolumeBaseline = null;
    _iosLegacyVolumeBaseline = null;
    if (reason != GestureInterruptReason.multiTouch) {
      _globalActivePointers.clear();
    }
    _resetSliderDraggingSafe();
    _cancelDesktopKeyScrub(showToast: false);
    if (_useEnhancedHud) {
      final events = _gestureFsm.cancel(reason);
      _applyGestureEvents(events);
    }
  }

  void _cancelDesktopKeyScrub({bool showToast = false}) {
    _desktopKeyTickTimer?.cancel();
    _desktopKeyTickTimer = null;
    final cancelled = _desktopKeySeek.cancel();
    if (cancelled || _activeDesktopScrubPreview != null) {
      if (mounted) {
        setState(() {
          _activeDesktopScrubPreview = null;
          _isDraggingSeek = false;
          if (showToast) {
            _hudText = '已取消快进预览';
          }
        });
        if (showToast) {
          _showHud('已取消快进预览');
        }
      } else {
        _activeDesktopScrubPreview = null;
        _isDraggingSeek = false;
      }
    }
  }
  int _pendingResumeMs = 0;
  int _lastKnownPositionMs = 0;
  int _lastKnownDurationMs = 0;
  int _lastPositionUiUpdateMs = 0;
  int _videoWidth = 0;
  int _videoHeight = 0;
  String _videoCodec = '';
  String _audioCodec = '';
  String _activeStreamUrl = '';
  String _activeQualityLogicalUrl = '';
  String _activeMediaUri = '';

  static String _normalizePlayStreamUrl(String rawUrl) =>
      (rawUrl.startsWith('http://') || rawUrl.startsWith('https://')) &&
              RegExp(r'[^\x00-\x7F]').hasMatch(rawUrl)
          ? Uri.encodeFull(rawUrl)
          : rawUrl;

  bool _matchesActiveQuality(CmsEpisode choice) {
    if (_normalizePlayStreamUrl(choice.url) == _activeStreamUrl ||
        choice.url == _activeStreamUrl) {
      return true;
    }
    final logical = choice.playbackSession['catpawLogicalUrl'];
    return logical is String &&
        logical.isNotEmpty &&
        logical == _activeQualityLogicalUrl;
  }
  bool get _matchesActiveMedia {
    if (_usingAvPlayer) return false;
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
  bool _lastIosPipActive = false;
  bool _currentEpisodePlaybackConfirmed = false;
  int _confirmedPlaybackSession = -1;
  int _episodeResumeAnchorMs = 0;
  ({bool wantLandscape, int expiresAtMs})? _pendingIosOrientationFeedback;

  void _markCurrentEpisodePlaybackConfirmed() {
    if (_isLiveStream) return;
    final alreadyForSession =
        _currentEpisodePlaybackConfirmed &&
        _confirmedPlaybackSession == _playSession;
    _currentEpisodePlaybackConfirmed = true;
    _confirmedPlaybackSession = _playSession;
    if (alreadyForSession) return;
    final line = _currentLine;
    final ep = _currentEpisode;
    widget.onPlaybackConfirmed?.call(
      PlayerPlaybackConfirmation(
        siteKey: widget.site.key,
        videoId: widget.video.id,
        lineIndex: _lineIndex,
        lineId: line.id,
        lineName: line.name,
        episodeIndex: _episodeIndex,
        episodeName: ep.name,
        episodeUrl: ep.url,
      ),
    );
    if (!_initialHistoryRecorded) {
      _initialHistoryRecorded = true;
      unawaited(_saveProgress(immediate: true, syncImmediate: false));
    }
  }
  final List<int> _midPlaybackStallEpochsMs = <int>[];
  Timer? _midPlaybackStallTimer;
  int _lastPointerScheduleMs = 0;
  double _pointerWakeAccumulatedPx = 0;
  int _pointerWakeWindowStartMs = 0;
  int _pointerWakeLastEventMs = 0;
  double _pointerVisibleAccumulatedPx = 0;
  final Set<int> _failedLinesForEpisode = <int>{};
  final Set<int> _failedLiveEpisodes = <int>{};
  final Set<String> _failedQualityUrls = <String>{};
  bool _liveDirectFallbackTried = false;
  bool _activeEpisodeUsedLocalProxy = false;
  bool _liveSessionHasProgress = false;
  _LiveStartupPhase _liveStartupPhase = _LiveStartupPhase.tracksUnknown;
  int _liveSessionVideoOutputCount = 0;
  bool _hasLiveVideoOutputObserver = false;
  bool _liveVoConfigured = false;
  bool _liveStartSpecTriggered = false;
  final Set<String> _observedMpvVideoProps = <String>{};
  VoidCallback? _videoRectListener;
  VoidCallback? _mdkTextureListener;
  VoidCallback? _ohosTextureListener;
  LiveChannel? _activeLiveChannel;

  static bool _isRealTrackId(String id) {
    final trimmed = id.trim();
    return trimmed.isNotEmpty && trimmed != 'auto' && trimmed != 'no';
  }

  bool get _liveSessionReadyForDisplay =>
      !_isLiveStream ||
      !_hasLiveVideoOutputObserver ||
      _liveStartupPhase == _LiveStartupPhase.videoFrameRendered ||
      (_player.platform is OhosPlatformPlayer && _liveSessionHasProgress) ||
      (_liveStartupPhase == _LiveStartupPhase.confirmedAudioOnly &&
          _liveSessionHasProgress);

  String get _displayTitle => _activeLiveChannel?.name ?? _activeVideo.title;
  bool get _hasLiveChannelCatalog =>
      _isLiveStream && widget.liveGroups.any((g) => g.channels.isNotEmpty);

  CmsLine get _currentLine => _lines[_lineIndex.clamp(0, _lines.length - 1)];
  CmsEpisode get _currentEpisode =>
      _currentLine.episodes[_episodeIndex.clamp(0, _currentLine.episodes.length - 1)];

  bool get _isLiveStream =>
      widget.isLive ||
      _activeSite.key == 'live' ||
      (_activeSite.api.isEmpty && _activeSite.type == 1) ||
      CspBridge.isHuyaSite(_activeSite) ||
      CspBridge.isDouyuSite(_activeSite);

  int get _effectiveDiskCacheLimitMb => _desktop
      ? widget.storage.diskCacheMaxMb
      : widget.storage.mediaDiskCacheLimitMb;

  VoidCallback? _releaseRootTabSuppression;
  bool _preparedForWindowExit = false;

  void _onHideToTray() {
    if (!mounted) return;
    if (_playing) {
      unawaited(_enginePause());
    }
    unawaited(_saveProgress(immediate: true, triggerSync: false));
  }

  bool get _isWindowsExitHookHost =>
      !kIsWeb &&
      !OhosRuntime.isOhos &&
      (Platform.environment.containsKey('FLUTTER_TEST')
          ? defaultTargetPlatform == TargetPlatform.windows
          : Platform.isWindows);

  Future<void> _prepareForWindowExit() async {
    if (_preparedForWindowExit ||
        !mounted ||
        WindowsTrayService.isNativeDestroyStarted) {
      return;
    }
    _preparedForWindowExit = true;
    _allowEvents = false;
    _historyTimer?.cancel();
    await _saveProgress(immediate: true, triggerSync: false);
    if (WindowsTrayService.isNativeDestroyStarted) return;
    final activePlatform = _player.platform;
    if (activePlatform is MdkPlatformPlayer) {
      activePlatform.cancelPendingOpen();
    }
    try {
      await _player.stop().timeout(const Duration(milliseconds: 220));
    } catch (_) {}
    if (WindowsTrayService.isNativeDestroyStarted) return;
    if (!_playerDisposed) {
      _playerDisposed = true;
      try {
        await _player.dispose();
      } catch (_) {}
    }
  }

  @override
  void initState() {
    super.initState();
    if (!widget.embedded &&
        !OhosRuntime.isOhos &&
        defaultTargetPlatform == TargetPlatform.iOS) {
      _releaseRootTabSuppression =
          IosLiquidGlassBridge.acquireRootTabSuppression();
    }
    WidgetsBinding.instance.addObserver(this);
    if (_isWindowsExitHookHost) {
      WindowsTrayService.hideToTrayRevision.addListener(_onHideToTray);
      WindowsTrayService.registerBeforeExitHook(_prepareForWindowExit);
    }
    _activeSite = widget.site;
    _activeVideo = WoggSource.normalizeCachedVideoLabels(
      widget.site,
      widget.video,
    );
    _seedCrossSiteSources();
    _lines = List<CmsLine>.of(_activeVideo.lines);
    _activeLiveChannel = widget.initialLiveChannel;
    _lineIndex = widget.initialLineIndex.clamp(
      0,
      _lines.length - 1,
    );
    _episodeIndex = widget.initialEpisodeIndex.clamp(
      0,
      _currentLine.episodes.length - 1,
    );
    _episodeScrapeOverride = _isLiveStream
        ? const EpisodeScrapeOverride()
        : widget.storage.getEpisodeScrapeOverride(
            siteKey: widget.site.key,
            videoId: widget.video.id,
            videoTitle: widget.video.title,
          );
    final initUsesOhos =
        OhosRuntime.isOhos || widget.debugPlayer?.platform is OhosPlatformPlayer;
    _normalSpeed = _isLiveStream
        ? 1.0
        : (initUsesOhos
            ? OhosPlatformPlayer.normalizeSupportedRate(widget.storage.playSpeed)
            : widget.storage.playSpeed);
    _skipIntroSec = widget.storage.getVideoSkipIntroSec(
      _activeSite.key,
      _activeVideo.id,
      isPrivate: _activeSite.isEffectivelyPrivate,
    );
    _skipOutroSec = widget.storage.getVideoSkipOutroSec(
      _activeSite.key,
      _activeVideo.id,
      isPrivate: _activeSite.isEffectivelyPrivate,
    );
    _alwaysShowClock = widget.storage.playerAlwaysShowClock;
    if (widget.debugInitialAiOverlayCues != null &&
        widget.debugInitialAiOverlayCues!.isNotEmpty) {
      _aiOverlayMediaKey = _currentAiSubtitleMediaKey;
      _aiOverlayCues =
          List<AiSubtitleCue>.unmodifiable(widget.debugInitialAiOverlayCues!);
      _aiOverlayBilingual = true;
      _aiOverlayLabel = 'AI 双语字幕';
      _aiSubtitleStateRevision.value++;
    }
    widget.debugOnBindSwitchPickForTest?.call(_switchToRecommendedPick);
    widget.debugOnBindStateInspectorForTest?.call(() => <String, Object?>{
          'activeSiteKey': _activeSite.key,
          'activeVideoId': _activeVideo.id,
          'activeVideoTitle': _activeVideo.title,
          'skipIntroSec': _skipIntroSec,
          'skipOutroSec': _skipOutroSec,
          'crossSiteSourceIds': _crossSiteSources
              .map((s) => '${s.site.key}:${s.videoId}')
              .toList(growable: false),
          'crossSiteDetailKeys': _crossSiteDetails.keys.toList(growable: false),
          'aiOverlayCueCount': _aiOverlayCues.length,
          'aiOverlayGlossary': Map<String, String>.of(_aiOverlayGlossary),
          'aiOverlayOffsetMs': _aiOverlayOffset.inMilliseconds,
          'aiLiveRawLine': _aiLiveRawLine,
          'aiLiveTranslatedLine': _aiLiveTranslatedLine,
          'aiLiveEnabled': _aiLiveEmbeddedTranslateEnabled,
        });
    _ownsWinQualityController = widget.debugWinQualityController == null;
    _winQualityController =
        widget.debugWinQualityController ?? WindowsVideoQualityController();
    _winQualityController.addListener(_onHudSubstateChanged);
    _ownsAnime4kController = widget.debugAnime4kController == null;
    _anime4kController = widget.debugAnime4kController ??
        Anime4kController(
          windowsBaseScalerResolver: () =>
              _winQualityController.activeBaseScalers,
        );
    if (widget.debugAnime4kController == null && _isWindowsPlayerPlatform) {
      _anime4kController.setWindowsBaseScalerResolver(
        () => _winQualityController.activeBaseScalers,
      );
    }
    _anime4kController.addListener(_onHudSubstateChanged);
    final initialCfg = widget.storage.loadSavedConfig();
    WebMediaResolver.defaultSniffRules = initialCfg?.rules ?? const [];
    WebMediaResolver.defaultAdRules = initialCfg?.ads ?? const [];
    LocalMediaLease.defaultHlsAdStripEnabled =
        widget.storage.hlsAdStripEnabled;
    if (!OhosRuntime.isOhos) {
      final cacheLimitMb = _effectiveDiskCacheLimitMb;
      final desiredDiskCacheBytes = cacheLimitMb <= 0
          ? 0
          : cacheLimitMb * 1024 * 1024;
      if (DiskBlockCache.shared.maxBytes != desiredDiskCacheBytes) {
        unawaited(DiskBlockCache.shared.setCapacityMb(cacheLimitMb));
      }
      if (widget.debugDanmuSettings != null) {
        _danmuSettings = widget.debugDanmuSettings!;
        _rebuildDanmuPipeline();
      } else {
        unawaited(_loadDanmuSettings());
      }
      if (!_isLiveStream && !widget.embedded) {
        if (widget.debugOnboardingPrefs != null) {
          _onboardingPrefs = widget.debugOnboardingPrefs;
        } else {
          unawaited(_loadOnboardingPrefs());
        }
      }
    }
    _ownsHudPrefs = widget.debugHudPrefs == null;
    _hudPrefs = widget.debugHudPrefs ?? PlayerHudPrefs(isDesktop: _desktop);
    _hudPrefs.addListener(_onHudSubstateChanged);
    unawaited(_hudPrefs.load());
    _gestureFsm = PlayerGestureStateMachine(config: _buildGestureConfig());
    _sleepTimer = SleepTimerController(onTriggered: _onSleepTimerExpired)
      ..addListener(_onHudSubstateChanged);
    _skipCountdown.addListener(_onHudSubstateChanged);
    _startSpecController.addListener(_onHudSubstateChanged);
    widget.storage.seriesScrapeRevision.addListener(
      _onPlayerSeriesScrapeRevision,
    );
    if (!OhosRuntime.isOhos) {
      widget.storage.danmuSourcesRevision.addListener(
        _onDanmuSourcesRevisionChanged,
      );
    }
    IosLiquidGlassBridge.reduceTransparencyNotifier.addListener(
      _onReduceTransparencyChanged,
    );
    GlassworkBackdrop.reduceTransparency.addListener(
      _onReduceTransparencyChanged,
    );
    GlassworkBackdrop.intensity.addListener(_onReduceTransparencyChanged);
    IosLiquidGlassBridge.activeSheetNotifier.addListener(
      _onPlayerOverlayStateChanged,
    );
    IosLiquidGlassBridge.thermalThrottledNotifier.addListener(
      _onIosThermalPressureChanged,
    );
    IosLiquidGlassBridge.thermalLevelNotifier.addListener(
      _onIosThermalPressureChanged,
    );
    activeIosGlassPopoverCount.addListener(_onPlayerOverlayStateChanged);
    activeAppleModalSheetCount.addListener(_onPlayerOverlayStateChanged);
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
    _windowsEngine = WindowsPlaybackEngine.fromId(
      widget.storage.windowsPlaybackEngine,
    );
    _iosEngineMode = IosPlaybackEngineMode.fromId(
      widget.storage.iosPlaybackEngineMode,
    );
    _iosToolbarItems = List<String>.of(widget.storage.iosPlayerToolbarItems);
    _iosHdrToneMapping = IosHdrToneMappingMode.fromId(
      widget.storage.iosHdrToneMappingMode,
    );
    _vocalLoudness = VocalLoudnessPreset.fromId(
      widget.storage.vocalLoudnessPreset,
    );
    _iosLargeBuffer = widget.storage.iosLargeBufferEnabled;
    _isFavorite = widget.storage.isFavorite(
      _activeSite.key,
      _activeVideo.id,
      forPrivate: _activeSite.isEffectivelyPrivate,
    );
    _liveCompanionGroupNotifier.value = widget.initialLiveChannel?.group ?? '';
    if (_canUseIosAvPlayerEngine) {
      final avCtrl = widget.debugIosAvPlayerController ?? IosAvPlayerController();
      _iosAvPlayerController = avCtrl;
      avCtrl.addListener(_onIosAvPlayerChanged);
      _iosAvSubscriptions.add(
        avCtrl.onSystemVolumeChanged.listen((vol) {
          if (!mounted) return;
          _applyObservedIosSystemVolume(vol);
        }),
      );
      _iosAvSubscriptions.add(
        avCtrl.onPipError.listen((errorMsg) {
          if (!mounted) return;
          _clearPendingAutoStartPip();
          final detail = errorMsg.trim().isNotEmpty ? errorMsg.trim() : '系统暂不允许开启画中画';
          _showHud('画中画开启失败：$detail');
          setState(() {});
        }),
      );
      _iosAvSubscriptions.add(
        avCtrl.onFallbackToMpvRequested.listen((event) {
          if (!mounted ||
              event.isStaticPrecheck ||
              !_usingAvPlayer ||
              _fallbackInFlight) {
            return;
          }
          unawaited(_handleRuntimeFallbackToMpv(event));
        }),
      );
      _iosAvSubscriptions.add(
        avCtrl.onPipRestoreForeground.listen((_) {
          if (!mounted) return;
          _syncMobileSystemBars(force: true);
          if (_controlsVisible) _scheduleHide();
        }),
      );
      _iosAvSubscriptions.add(
        avCtrl.onThermalStateChanged.listen((_) {
          if (!mounted) return;
          _onIosThermalPressureChanged();
        }),
      );
      _iosAvSubscriptions.add(
        avCtrl.onSubtitleCueChanged.listen((cue) {
          if (!mounted || !_usingAvPlayer || !_allowEvents) return;
          String? selectedId;
          for (final t in avCtrl.subtitleTracks) {
            if (t.selected) {
              selectedId = t.id;
              break;
            }
          }
          if (cue.lines.isNotEmpty) {
            _avConfirmedTextSubtitleTrackForSession = true;
            _avConfirmedTextSubtitleTrackId = selectedId;
          } else if (cue.hasNativeSamples) {
            _avConfirmedTextSubtitleTrackForSession = false;
            _avConfirmedTextSubtitleTrackId = null;
          }
          _syncAvPlayerSubtitleSuppression();
          _handleEmbeddedSubtitleLines(
            cue.lines,
            nonTextSamples: cue.hasNativeSamples,
          );
        }),
      );
      unawaited(_initIosAvPlayerTelemetry());
    } else if (_isIosPlayerPlatform) {
      unawaited(_primeIosSystemVolume());
    }
    if (_shouldMonitorIosPhysicalOrientation) {
      unawaited(
        _mobileChrome.setOrientationMonitoring(
          true,
          onPhysicalOrientation: _handlePhysicalOrientation,
        ),
      );
    }
    _fit = switch (widget.storage.defaultAspectMode) {
      'cover' => BoxFit.cover,
      'fill' => BoxFit.fill,
      _ => BoxFit.contain,
    };

    if (_desktop && !widget.embedded) {
      _desktopWindow = DesktopPlayerWindow()..addListener(_windowChanged);
      _desktopWindow!.initialize().catchError(_windowError);
    }
    if (!widget.embedded && isWindowsDesktopUi) {
      scheduleMicrotask(() {
        if (!mounted || _windowsDarkSurfaceApplied) return;
        _windowsDarkSurfaceApplied = true;
        WindowsImmersiveFrame.darkSurfaceDepth.value += 1;
      });
    }
    final initIosMdk = _isIosPlayerPlatform &&
        !_isLiveStream &&
        _iosEngineMode == IosPlaybackEngineMode.mdk &&
        (widget.debugPlayer == null || widget.debugIosKernelFactory != null);
    _videoKernel = widget.debugWindowsKernelFactory?.call(_windowsEngine) ??
        widget.debugIosKernelFactory?.call(initIosMdk) ??
        VideoKernel.create(
          debugPlayer: widget.debugPlayer,
          debugVideoSurface: widget.debugVideoSurface,
          hwdec: _hardwareDecoder(_playerKernel),
          windowsEngine: _windowsEngine,
          kernelStrategy: _playerKernel,
          useIosMdk: initIosMdk,
        );
    _player = _videoKernel.player;
    _playerDisposed = false;
    // Keep one source lease for this page, including pause and overlapping
    // episode/quality transitions. Release only after the decoder is disposed.
    _releaseSourceSession = _client.pinPlaybackSource(_activeSite);
    _playerConfiguration = _applyPlayerKernel(_playerKernel);
    if (!OhosRuntime.isOhos &&
        (_anime4kController.isAvailableForPlayer(_player) ||
            _anime4kController.isIosLightweightAvailableForPlayer(_player))) {
      unawaited(_initAnime4kAfterKernel());
    }

    _attachPlayerStreams();

    _openCurrentEpisode(resumeMs: widget.initialPositionMs);
    _historyTimer = Timer.periodic(
      const Duration(seconds: 15),
      (_) => _saveProgress(immediate: false),
    );
  }

  void _detachLiveVideoOutputObservers() {
    if (_videoRectListener != null) {
      _videoKernel.mediaKitController?.rect.removeListener(_videoRectListener!);
      _videoRectListener = null;
    }
    if (_mdkTextureListener != null) {
      _videoKernel.mdkPlatform?.textureIdListenable
          .removeListener(_mdkTextureListener!);
      _mdkTextureListener = null;
    }
    if (_ohosTextureListener != null) {
      _videoKernel.ohosPlatform?.textureIdListenable
          .removeListener(_ohosTextureListener!);
      _ohosTextureListener = null;
    }
    if (_observedMpvVideoProps.isNotEmpty) {
      final platform = _player.platform;
      final props = List<String>.of(_observedMpvVideoProps);
      _observedMpvVideoProps.clear();
      if (platform != null) {
        for (final prop in props) {
          try {
            unawaited((platform as dynamic).unobserveProperty(prop));
          } catch (_) {}
        }
      }
    }
  }

  void _armStartupWatchdog(int session) {
    final hasFallback = _isLiveStream
        ? (_currentLine.episodes.length > 1 &&
            _failedLiveEpisodes.length <
                math.min(_currentLine.episodes.length - 1, 8))
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
          _changeMedia(
            session,
            () => _usingAvPlayer
                ? (_iosAvPlayerController?.stop() ?? Future<void>.value())
                : _player.stop(),
          ).catchError((_) {});
        }
      },
      hasFallback: hasFallback || (_isLiveStream && !_liveDirectFallbackTried),
      startOffset: _pendingResumeMs > 0
          ? Duration(milliseconds: _pendingResumeMs)
          : Duration.zero,
      timeoutOverride: _isLiveStream
          ? Duration(seconds: !_liveDirectFallbackTried ? 7 : 8)
          : null,
    );
  }

  void _markLiveVideoTrackDiscovered() {
    if (!_isLiveStream) return;
    if (_liveStartupPhase == _LiveStartupPhase.videoFrameRendered) return;
    final wasAudioOnly =
        _liveStartupPhase == _LiveStartupPhase.confirmedAudioOnly;
    _liveStartupPhase = _LiveStartupPhase.awaitingVideoFrame;
    if (wasAudioOnly) {
      if (mounted && !_loading) {
        setState(() {
          _loading = true;
        });
      } else {
        _loading = true;
      }
      if (_allowEvents && _matchesActiveMedia) {
        _armStartupWatchdog(_playSession);
        _startup.updateState(
          playing: _playing,
          buffering: _buffering,
          userPaused: _userPausedPlayback,
        );
      }
    }
  }

  void _markLiveTracksConfirmedAudioOnly() {
    if (!_isLiveStream ||
        _videoWidth > 0 ||
        _videoHeight > 0 ||
        _liveStartupPhase == _LiveStartupPhase.videoFrameRendered ||
        _liveStartupPhase == _LiveStartupPhase.awaitingVideoFrame) {
      return;
    }
    final changed = _liveStartupPhase != _LiveStartupPhase.confirmedAudioOnly;
    _liveStartupPhase = _LiveStartupPhase.confirmedAudioOnly;
    if (changed && _liveSessionHasProgress) {
      if (_position > Duration.zero) {
        _startup.position(_position);
      }
      if (_loading) {
        setState(() {
          _loading = false;
        });
        if (_playing &&
            !_buffering &&
            _controlsVisible &&
            (_hideTimer == null || !_hideTimer!.isActive)) {
          _scheduleHide();
        }
      }
    }
  }

  void _confirmLiveVideoOutput() {
    if (!mounted || !_allowEvents || !_matchesActiveMedia || !_isLiveStream) {
      return;
    }
    final alreadyReady =
        _liveStartupPhase == _LiveStartupPhase.videoFrameRendered;
    _liveStartupPhase = _LiveStartupPhase.videoFrameRendered;
    _liveSessionVideoOutputCount++;
    _startup.confirmVideoOutput(sustained: _liveSessionVideoOutputCount >= 2);
    if (_position > Duration.zero) {
      _startup.position(_position);
    }
    if (!alreadyReady) {
      final clearStaleBuffering =
          _buffering && _position.inMilliseconds >= 250;
      if (_loading || clearStaleBuffering) {
        setState(() {
          _loading = false;
          if (clearStaleBuffering) {
            _buffering = false;
          }
        });
        if (_playing &&
            !_buffering &&
            _controlsVisible &&
            (_hideTimer == null || !_hideTimer!.isActive)) {
          _scheduleHide();
        }
      }
      if (_videoWidth > 0 && _videoHeight > 0 && !_liveStartSpecTriggered) {
        _liveStartSpecTriggered = true;
        _startSpecController.onFirstFrameReady(
          enabled: _hudPrefs.effectiveStartSpecHud,
          isLive: true,
        );
      }
    }
  }

  void _attachLiveVideoOutputObservers() {
    _detachLiveVideoOutputObservers();
    _hasLiveVideoOutputObserver = false;
    if (widget.debugLiveVideoOutputStream != null) {
      _hasLiveVideoOutputObserver = true;
      _playerSubscriptions.add(
        widget.debugLiveVideoOutputStream!.listen((hasOutput) {
          if (!mounted || !_allowEvents || !_matchesActiveMedia) return;
          if (hasOutput) {
            _confirmLiveVideoOutput();
          }
        }),
      );
    }
    final mkCtrl = _videoKernel.mediaKitController;
    if (mkCtrl != null) {
      _hasLiveVideoOutputObserver = true;
      void onRectChanged() {
        if (!mounted || !_allowEvents || !_matchesActiveMedia || !_isLiveStream) {
          return;
        }
        final r = mkCtrl.rect.value;
        if (r != null && r.width > 0 && r.height > 0) {
          _confirmLiveVideoOutput();
        }
      }

      _videoRectListener = onRectChanged;
      mkCtrl.rect.addListener(onRectChanged);
    }
    final mdk = _videoKernel.mdkPlatform;
    if (mdk != null) {
      _hasLiveVideoOutputObserver = true;
      void onMdkTexture() {
        if (!mounted || !_allowEvents || !_matchesActiveMedia || !_isLiveStream) {
          return;
        }
        final tid = mdk.textureIdListenable.value;
        if (tid != null && tid >= 0 && _videoWidth > 0 && _videoHeight > 0) {
          _confirmLiveVideoOutput();
        }
      }

      _mdkTextureListener = onMdkTexture;
      mdk.textureIdListenable.addListener(onMdkTexture);
    }
    final ohos = _videoKernel.ohosPlatform;
    if (ohos != null) {
      _hasLiveVideoOutputObserver = true;
      void onOhosTexture() {
        if (!mounted || !_allowEvents || !_matchesActiveMedia || !_isLiveStream) {
          return;
        }
        final tid = ohos.textureIdListenable.value;
        if (tid != null && tid >= 0 && _videoWidth > 0 && _videoHeight > 0) {
          _confirmLiveVideoOutput();
        }
      }

      _ohosTextureListener = onOhosTexture;
      ohos.textureIdListenable.addListener(onOhosTexture);
    }
    if (_isLiveStream) {
      final platform = _player.platform;
      if (platform is NativePlayer) {
        _hasLiveVideoOutputObserver = true;
        Future<void> observe(
          String prop,
          void Function(String val) handler,
        ) async {
          if (!mounted || _playerDisposed) return;
          try {
            await platform.observeProperty(prop, (String val) async {
              if (!mounted || _playerDisposed) return;
              handler(val);
            });
            if (mounted && !_playerDisposed) {
              _observedMpvVideoProps.add(prop);
            }
          } catch (_) {}
        }

        unawaited(observe('vo-configured', (val) {
          if (!_allowEvents || !_matchesActiveMedia) return;
          final configured = val.trim().toLowerCase() == 'yes';
          _liveVoConfigured = configured;
          if (configured && _videoWidth > 0 && _videoHeight > 0) {
            _confirmLiveVideoOutput();
          }
        }));
        unawaited(observe('estimated-vf-fps', (val) {
          if (!_allowEvents || !_matchesActiveMedia) return;
          final fps = double.tryParse(val.trim()) ?? 0;
          if (fps > 0.1) {
            _confirmLiveVideoOutput();
          }
        }));
        unawaited(observe('video-frame-info/picture-type', (val) {
          if (!_allowEvents || !_matchesActiveMedia) return;
          if (val.trim().isNotEmpty) {
            _confirmLiveVideoOutput();
          }
        }));
      }
    }
  }

  String get _currentMdkMediaKey =>
      '${_activeSite.key}::${_activeVideo.id}::$_lineIndex::$_episodeIndex';

  void _syncAiSubtitleClockMs(int posMs) {
    final safe = posMs < 0 ? 0 : posMs;
    if (_aiSubtitleClockMsNotifier.value != safe) {
      _aiSubtitleClockMsNotifier.value = safe;
    }
  }

  void _handleEmbeddedSubtitleLines(
    List<String> lines, {
    bool nonTextSamples = false,
  }) {
    if (!mounted ||
        !_allowEvents ||
        !_aiLiveEmbeddedTranslateEnabled ||
        !_canUsePlayerAi) {
      return;
    }
    final joined = lines
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .join('\n')
        .trim();
    if (joined.isEmpty && nonTextSamples && !_aiNonTextTrackNotifiedForSession) {
      _aiNonTextTrackNotifiedForSession = true;
      _showHud('当前内嵌字幕轨为图形/非文本字幕，无法提取文本实时翻译，请切换文本字幕轨或导入外挂 .srt/.ass');
    }
    if (joined == _aiLiveRawLine) return;
    _aiLiveRawLine = joined;
    final reqGen = ++_aiLiveTranslateGen;
    final capturedMediaKey = _currentAiSubtitleMediaKey;
    final capturedMediaGen = _aiSubtitleMediaGen;
    if (joined.isEmpty) {
      if (_aiLiveTranslatedLine.isNotEmpty) {
        _aiLiveTranslatedLine = '';
      }
      _aiSubtitleStateRevision.value++;
      return;
    }
    _aiLiveTranslatedLine = '';
    _aiSubtitleStateRevision.value++;
    unawaited(() async {
      try {
        final zh = await AiLabService.instance.translateLiveSubtitleLine(
          seriesTitle: _activeVideo.title,
          rawLine: joined,
        );
        if (!mounted ||
            reqGen != _aiLiveTranslateGen ||
            capturedMediaKey != _currentAiSubtitleMediaKey ||
            capturedMediaGen != _aiSubtitleMediaGen) {
          return;
        }
        _aiLiveTranslatedLine = zh.trim();
        _aiSubtitleStateRevision.value++;
      } catch (_) {}
    }());
  }

  int _resolveFallbackResumePositionMs() {
    if (_isLiveStream) return 0;
    if (_hasVideoOutputForSession && _position.inMilliseconds >= 1000) {
      return _position.inMilliseconds;
    }
    if (_pendingResumeMs > 0) return _pendingResumeMs;
    if (_intendedStartPositionMs > 0) return _intendedStartPositionMs;
    if (_position.inMilliseconds >= 1000) return _position.inMilliseconds;
    return _lastKnownPositionMs > 0 ? _lastKnownPositionMs : 0;
  }

  void _attachPlayerStreams() {
    _detachLiveVideoOutputObservers();
    for (final sub in _playerSubscriptions) {
      unawaited(sub.cancel());
    }
    _playerSubscriptions.clear();
    _attachLiveVideoOutputObservers();
    final boundPlayer = _player;
    if (_isWindowsPlayerPlatform &&
        _winQualityController.isAvailableForPlayer(boundPlayer)) {
      _winQualityController.attachPlayer(
        boundPlayer,
        onLoudnessFallbackToOff: () {
          if (!mounted) return;
          setState(() {});
          _showHud(
            _winQualityController.lastWarning ??
                WindowsVideoQualityController.audioFallbackWarningZh,
          );
        },
      );
    } else {
      _winQualityController.detachPlayer();
    }
    final isOhosPlatform = boundPlayer.platform is OhosPlatformPlayer;
    if (isOhosPlatform) {
      final ohosPlatform = boundPlayer.platform as OhosPlatformPlayer;
      _playerSubscriptions.add(ohosPlatform.firstFrameStream.listen((_) {
        if (!mounted ||
            !identical(boundPlayer, _player) ||
            !_allowEvents ||
            !_matchesActiveMedia) {
          return;
        }
        _ohosRenderedFirstFrame = true;
        if (_isLiveStream) {
          _confirmLiveVideoOutput();
          if (!_userPausedPlayback) {
            _startup.markLiveFrameReady();
          }
        } else if (_loading) {
          setState(() => _loading = false);
        }
        _startSpecController.onFirstFrameReady(
          enabled: _hudPrefs.effectiveStartSpecHud,
          isLive: _isLiveStream,
        );
      }));
      _playerSubscriptions.add(boundPlayer.stream.rate.listen((rate) {
        if (!mounted ||
            !identical(boundPlayer, _player) ||
            !_allowEvents ||
            !_matchesActiveMedia ||
            _isLiveStream ||
            _speedBoosting) {
          return;
        }
        final normalized = OhosPlatformPlayer.normalizeSupportedRate(rate);
        if ((_normalSpeed - normalized).abs() >= 0.01) {
          setState(() => _normalSpeed = normalized);
        }
      }));
    }
    _playerSubscriptions.add(boundPlayer.stream.width.listen((w) {
      if (!mounted ||
          !identical(boundPlayer, _player) ||
          !_allowEvents ||
          !_matchesActiveMedia) {
        return;
      }
      if (w == null || w <= 0 || w == _videoWidth) return;
      setState(() {
        _videoWidth = w;
      });
      if (_isLiveStream) _markLiveVideoTrackDiscovered();
      if (_liveVoConfigured && _videoWidth > 0 && _videoHeight > 0) {
        _confirmLiveVideoOutput();
      }
      if (_videoWidth > 0 &&
          _videoHeight > 0 &&
          _liveSessionReadyForDisplay &&
          (!isOhosPlatform || _ohosRenderedFirstFrame) &&
          !_liveStartSpecTriggered) {
        _liveStartSpecTriggered = true;
        _startSpecController.onFirstFrameReady(
          enabled: _hudPrefs.effectiveStartSpecHud,
          isLive: _isLiveStream,
        );
      }
    }));
    _playerSubscriptions.add(boundPlayer.stream.height.listen((h) {
      if (!mounted ||
          !identical(boundPlayer, _player) ||
          !_allowEvents ||
          !_matchesActiveMedia) {
        return;
      }
      if (h == null || h <= 0 || h == _videoHeight) return;
      setState(() {
        _videoHeight = h;
      });
      if (_isLiveStream) _markLiveVideoTrackDiscovered();
      if (_liveVoConfigured && _videoWidth > 0 && _videoHeight > 0) {
        _confirmLiveVideoOutput();
      }
      if (_videoWidth > 0 &&
          _videoHeight > 0 &&
          _liveSessionReadyForDisplay &&
          (!isOhosPlatform || _ohosRenderedFirstFrame) &&
          !_liveStartSpecTriggered) {
        _liveStartSpecTriggered = true;
        _startSpecController.onFirstFrameReady(
          enabled: _hudPrefs.effectiveStartSpecHud,
          isLive: _isLiveStream,
        );
      }
    }));
    _playerSubscriptions.add(_player.stream.track.listen((track) {
      if (!mounted || !_allowEvents || !_matchesActiveMedia) return;
      if (_isLiveStream) {
        final vid = track.video.id.trim();
        final aid = track.audio.id.trim();
        if (_isRealTrackId(vid)) {
          _markLiveVideoTrackDiscovered();
        } else if (vid == 'no') {
          _markLiveTracksConfirmedAudioOnly();
        } else if (_isRealTrackId(aid)) {
          final knownVideos = _player.state.tracks.video;
          if (knownVideos.isNotEmpty &&
              !knownVideos.any((t) => _isRealTrackId(t.id))) {
            _markLiveTracksConfirmedAudioOnly();
          }
        }
      }
      final vCodec = (track.video.codec ?? track.video.decoder ?? '').trim();
      final aCodec = (track.audio.codec ?? track.audio.decoder ?? '').trim();
      final extraParts = <String>[
        if ((track.video.title ?? '').trim().isNotEmpty)
          track.video.title!.trim(),
        if ((track.audio.title ?? '').trim().isNotEmpty)
          track.audio.title!.trim(),
        if ((track.audio.channels ?? '').trim().isNotEmpty)
          track.audio.channels!.trim(),
      ];
      final extra = extraParts.join(' ');
      if ((vCodec.isNotEmpty && vCodec != _videoCodec) ||
          (aCodec.isNotEmpty && aCodec != _audioCodec) ||
          (extra.isNotEmpty && extra != _extraTrackSpecInfo)) {
        setState(() {
          if (vCodec.isNotEmpty) _videoCodec = vCodec;
          if (aCodec.isNotEmpty) _audioCodec = aCodec;
          if (extra.isNotEmpty) _extraTrackSpecInfo = extra;
        });
      }
      _scheduleSyncNativeSubtitleState();
      Future<void>.microtask(() {
        if (mounted) unawaited(_syncNativeSubtitleState());
      });
    }));
    _playerSubscriptions.add(_player.stream.tracks.listen((tracks) {
      if (!mounted || !_allowEvents || !_matchesActiveMedia) return;
      if (_isLiveStream) {
        final hasRealVideo = tracks.video.any((t) => _isRealTrackId(t.id));
        final hasRealAudio = tracks.audio.any((t) => _isRealTrackId(t.id));
        if (hasRealVideo) {
          _markLiveVideoTrackDiscovered();
        } else if (!hasRealVideo && hasRealAudio) {
          _markLiveTracksConfirmedAudioOnly();
        }
      }
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
      _scheduleSyncNativeSubtitleState();
      Future<void>.microtask(() {
        if (mounted) unawaited(_syncNativeSubtitleState());
      });
      _probeCurrentEpisodeContainerTags(_playSession);
    }));

    try {
      _playerSubscriptions.add(boundPlayer.stream.subtitle.listen((lines) {
        if (!mounted ||
            !identical(boundPlayer, _player) ||
            _usingAvPlayer ||
            !_allowEvents) {
          return;
        }
        _handleEmbeddedSubtitleLines(lines);
      }));
    } catch (_) {}

    _playerSubscriptions.add(boundPlayer.stream.position.listen((pos) {
      if (!mounted ||
          !identical(boundPlayer, _player) ||
          !_allowEvents ||
          !_matchesActiveMedia) {
        return;
      }
      if (!_isLiveStream ||
          isOhosPlatform ||
          _liveStartupPhase == _LiveStartupPhase.confirmedAudioOnly ||
          _liveStartupPhase == _LiveStartupPhase.videoFrameRendered) {
        _startup.position(pos);
      }
      if (!_hasVideoOutputForSession && _startup.hasProgressed) {
        _hasVideoOutputForSession = true;
        _pendingCrossSiteRollback = null;
      }
      final nextPos = (!_isDraggingSeek && !_isSliderDragging)
          ? ((_pendingResumeMs > 0 && pos.inMilliseconds < 2000)
                ? Duration(milliseconds: _pendingResumeMs)
                : pos)
          : _position;
      if (pos.inMilliseconds >= 1000) {
        _lastKnownPositionMs = pos.inMilliseconds;
        if (_playing &&
            !_buffering &&
            pos.inMilliseconds > _episodeResumeAnchorMs + 250) {
          _markCurrentEpisodePlaybackConfirmed();
        }
        if (_currentEpisodePlaybackConfirmed && !_initialHistoryRecorded) {
          _initialHistoryRecorded = true;
          unawaited(_saveProgress());
        }
      }
      if (_isLiveStream && pos > Duration.zero && !_liveSessionHasProgress) {
        _liveSessionHasProgress = true;
      }
      final liveReady = _liveSessionReadyForDisplay;
      final shouldClearLoading = pos > Duration.zero && _loading && liveReady;
      if (_isLiveStream &&
          liveReady &&
          _videoWidth > 0 &&
          _videoHeight > 0 &&
          !_liveStartSpecTriggered) {
        _liveStartSpecTriggered = true;
        _startSpecController.onFirstFrameReady(
          enabled: _hudPrefs.effectiveStartSpecHud,
          isLive: true,
        );
      }
      final shouldClearStaleLiveBuffering =
          _isLiveStream &&
          liveReady &&
          _buffering &&
          pos > _position &&
          pos.inMilliseconds >= 250;
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final slimBarVisible = _useEnhancedHud &&
          !_controlsVisible &&
          !_screenLocked &&
          !_isLiveStream &&
          !widget.embedded &&
          _hudPrefs.effectiveSlimProgress &&
          (_duration.inMilliseconds > 0 || _lastKnownDurationMs > 0);
      final hudNeedsPositionTick = IosMpvProfile.shouldRebuildPositionUi(
        isIos: _isIosPlayerPlatform,
        controlsVisible: _controlsVisible,
        screenLocked: _screenLocked,
        slimBarVisible: slimBarVisible,
        isPipActive: false,
        playing: _playing,
        nowMs: nowMs,
        lastUpdateMs: _lastPositionUiUpdateMs,
        nextPositionMs: nextPos.inMilliseconds,
        lastRenderedPositionMs: _lastRenderedPositionMs,
        iosThermalElevated:
            _isIosPlayerPlatform && IosLiquidGlassBridge.thermalElevated,
      );
      final shouldRebuildUi =
          shouldClearLoading ||
          shouldClearStaleLiveBuffering ||
          (hudNeedsPositionTick && !_isDraggingSeek && !_isSliderDragging);
      if (shouldRebuildUi) {
        _lastPositionUiUpdateMs = nowMs;
        _lastRenderedPositionMs = nextPos.inMilliseconds;
        setState(() {
          _position = nextPos;
          if (shouldClearLoading) {
            _loading = false;
          }
          if (shouldClearStaleLiveBuffering) {
            _buffering = false;
          }
        });
        if ((shouldClearLoading || shouldClearStaleLiveBuffering) &&
            _playing &&
            !_buffering &&
            _controlsVisible &&
            (_hideTimer == null || !_hideTimer!.isActive)) {
          _scheduleHide();
        }
      } else {
        _position = nextPos;
      }
      _syncAiSubtitleClockMs(nextPos.inMilliseconds);
      _embySession?.update(pos.inMilliseconds, !_playing);
      if (!OhosRuntime.isOhos && _danmuSettings.effectiveEnabled) {
        _danmuCache?.onPlaybackTick(nextPos.inMilliseconds, playing: _playing);
      }
      if (!OhosRuntime.isOhos &&
          !_hasStartedVodPlayback &&
          !_isLiveStream &&
          !widget.embedded &&
          !_loading &&
          pos > Duration.zero) {
        setState(() => _hasStartedVodPlayback = true);
      }
      _maybeEvaluateSkipTriggers(positionOverride: pos);
    }));

    _playerSubscriptions.add(boundPlayer.stream.duration.listen((dur) {
      if (!mounted ||
          !identical(boundPlayer, _player) ||
          !_allowEvents ||
          !_matchesActiveMedia) {
        return;
      }
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
        final clearedLoading = !_isLiveStream && dur > Duration.zero && _loading;
        if (clearedLoading) {
          _loading = false;
        }
      });
      if (dur > Duration.zero &&
          _playing &&
          !_buffering &&
          _controlsVisible &&
          (_hideTimer == null || !_hideTimer!.isActive)) {
        _scheduleHide();
      }
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
          _seekPlayer(Duration(milliseconds: targetMs));
          _showHud(
            '已为您续播至 ${_formatDuration(Duration(milliseconds: targetMs))}',
          );
          // Reinforce seek after 550ms in case an HLS stream resets to 0 on initial segment decode
          Future.delayed(const Duration(milliseconds: 550), () {
            if (!mounted || sessionAtSeek != _playSession) return;
            if (_position.inMilliseconds < targetMs - 3000) {
              _seekPlayer(Duration(milliseconds: targetMs));
            }
          });
        }
      } else if (!_isLiveStream && dur > Duration.zero) {
        _maybeEvaluateSkipTriggers(durationOverride: dur);
      }
    }));

    _playerSubscriptions.add(boundPlayer.stream.playing.listen((playing) {
      if (mounted &&
          identical(boundPlayer, _player) &&
          _allowEvents &&
          _matchesActiveMedia) {
        if (playing && _userPausedPlayback) {
          // A late async play() settled after the user explicitly paused.
          // Preserve the user's pause intent and drive the native player back
          // to paused so UI and audio stay aligned.
          _startup.updateState(playing: false, userPaused: true);
          if (_playing) {
            setState(() => _playing = false);
          }
          PlaybackWakelock.setEnabled(false);
          unawaited(boundPlayer.pause());
          return;
        }
        if (playing && _activeSite.isEmby && _embySession == null) {
          _openCurrentEpisode(resumeMs: 0);
          return;
        }
        final effectivePaused =
            _userPausedPlayback || (!isOhosPlatform && !playing && _playing);
        _startup.updateState(
          playing: playing,
          userPaused: effectivePaused,
        );
        setState(() {
          _playing = playing;
          if (playing && _liveSessionReadyForDisplay) {
            _loading = false;
            if (!OhosRuntime.isOhos && !_isLiveStream && !widget.embedded) {
              _hasStartedVodPlayback = true;
            }
          }
        });
        if (playing && !_buffering) {
          _markCurrentEpisodePlaybackConfirmed();
        }
        if (!OhosRuntime.isOhos && _danmuSettings.effectiveEnabled) {
          _danmuCache?.onPlaybackTick(
            _position.inMilliseconds,
            playing: playing,
          );
        }
        PlaybackWakelock.setEnabled(playing);
        if (!playing) {
          _suspendSkipCountdown();
          if (_useEnhancedHud &&
              (_gestureFsm.state == TouchGestureState.downPending ||
                  _gestureFsm.isSpeedBoosting ||
                  _gestureFsm.isSpeedLockReady ||
                  _gestureFsm.isSpeedLocked)) {
            _cancelTransientInteractions(
              GestureInterruptReason.playbackPaused,
            );
          }
          _saveProgress(immediate: true, syncImmediate: false);
        } else {
          _maybeEvaluateSkipTriggers();
          if (!_loading && !_buffering) {
            _scheduleHide();
          }
        }
        if (playing || _position > Duration.zero) {
          _embySession?.update(_position.inMilliseconds, !playing, force: true);
        }
      }
    }));

    _playerSubscriptions.add(boundPlayer.stream.buffering.listen((buffering) {
      if (mounted &&
          identical(boundPlayer, _player) &&
          _allowEvents &&
          _matchesActiveMedia) {
        _startup.updateState(
          buffering: buffering,
          userPaused: _userPausedPlayback,
        );
        setState(() => _buffering = buffering);
        if (!buffering) {
          _midPlaybackStallTimer?.cancel();
          if (_playing) {
            _markCurrentEpisodePlaybackConfirmed();
          }
          if (_playing && _liveSessionReadyForDisplay) {
            if (_isLiveStream &&
                (!isOhosPlatform || _ohosRenderedFirstFrame) &&
                _videoWidth > 0 &&
                _videoHeight > 0 &&
                !_userPausedPlayback) {
              _startup.markLiveFrameReady();
            }
            _scheduleHide();
          }
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

    _playerSubscriptions.add(boundPlayer.stream.completed.listen((completed) {
      if (completed &&
          mounted &&
          identical(boundPlayer, _player) &&
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

    _playerSubscriptions.add(boundPlayer.stream.error.listen((message) {
      if (!mounted ||
          !identical(boundPlayer, _player) ||
          message.isEmpty) {
        return;
      }
      if (_isWindowsPlayerPlatform &&
          _allowEvents &&
          _matchesActiveMedia &&
          WindowsVideoQualityController.isAudioFilterFailureMessage(message)) {
        unawaited(
          _winQualityController.handleRuntimeAudioFilterFailure(
            boundPlayer,
            reason: message,
            immediate: true,
          ),
        );
        return;
      }
      if (!_allowEvents || !_matchesActiveMedia) {
        return;
      }
      final lower = message.toLowerCase();
      // Only treat terminal open/format failures as immediate startup errors;
      // do not abort live HLS/FLV streams on transient sliding-window segment
      // 404s or harmless initial decoder warnings (e.g. missing SPS before keyframe).
      // Use `_hasVideoOutputForSession` instead of `_position <= Duration.zero`
      // so breakpoint-resume playback (where UI pre-populates `_position`) still
      // triggers startup error recovery and MDK -> MPV fallback.
      final isOhosAvPlayerError =
          boundPlayer.platform is OhosPlatformPlayer ||
          lower.contains('avplayer error') ||
          lower.contains('ohos avplayer') ||
          lower.contains('无法保留必要请求头');
      final isFatalStartupError = !_startup.isPastStartupWindow &&
          !_hasVideoOutputForSession &&
          (isOhosAvPlayerError ||
              lower.contains('failed to open') ||
              lower.contains('failed to recognize file format') ||
              lower.contains('could not open') ||
              lower.contains('cannot open') ||
              lower.contains('unable to open') ||
              lower.contains('connection refused') ||
              lower.contains('connection reset') ||
              lower.contains('network is unreachable') ||
              lower.contains('could not resolve') ||
              lower.contains('timed out') ||
              lower.contains('broken pipe') ||
              lower.contains('protocol not found') ||
              lower.contains('invalid data found') ||
              lower.contains('server returned 401') ||
              lower.contains('server returned 403') ||
              lower.contains('server returned 404') ||
              lower.contains('server returned 410') ||
              lower.contains('server returned 5') ||
              lower.contains('mdk reader.open') ||
              lower.contains('mdk reader.read') ||
              lower.contains('mdk decoder.video') ||
              lower.contains('mdk failed'));
      final shouldHandleError = isFatalStartupError ||
          isOhosAvPlayerError ||
          (!_isLiveStream &&
              !_playing &&
              _duration <= Duration.zero &&
              !_hasVideoOutputForSession);
      if (shouldHandleError) {
        if (_userPausedPlayback) {
          // A late error arriving after an explicit user pause must NEVER
          // auto-open, auto-play, or switch live sources. Mark the underlying
          // engine as needing reopen when the user explicitly resumes.
          _pausedEngineInvalidated = true;
          _startup.cancel();
          _midPlaybackStallTimer?.cancel();
          _midPlaybackStallEpochsMs.clear();
          PlaybackWakelock.setEnabled(false);
          setState(() {
            _loading = false;
            _buffering = false;
            _playing = false;
            _controlsVisible = true;
          });
          _showHud('已暂停 · 当前源已断开，继续播放将重新连接', persistent: true);
          return;
        }
        if (_isWindowsPlayerPlatform &&
            _videoKernel.isMdk &&
            (widget.debugPlayer == null ||
                widget.debugWindowsKernelFactory != null)) {
          if (_switchingWindowsEngine ||
              _mdkFallbackTriggeredSession == _playSession) {
            // Suppress duplicate error events while fallback is already in flight
            // or already triggered for this open session.
            return;
          }
          final mediaKey = _currentMdkMediaKey;
          if (!_mdkAutoFallbackMediaKeys.contains(mediaKey)) {
            _mdkFallbackTriggeredSession = _playSession;
            _mdkAutoFallbackMediaKeys.add(mediaKey);
            final resumePosMs = _resolveFallbackResumePositionMs();
            unawaited(
              _switchWindowsPlaybackEngine(
                WindowsPlaybackEngine.mpv,
                persist: false,
                resumeMsOverride: resumePosMs,
                customToast: 'MDK 引擎不支持当前流，已自动切回 MPV 播放',
              ),
            );
            return;
          }
        }
        if (_isIosPlayerPlatform &&
            _videoKernel.isMdk &&
            (widget.debugPlayer == null ||
                widget.debugIosKernelFactory != null)) {
          if (_switchingIosKernel ||
              _mdkFallbackTriggeredSession == _playSession) {
            return;
          }
          final mediaKey = _currentMdkMediaKey;
          if (_iosAutoFallbackCountForOpen < 1 &&
              !_mdkAutoFallbackMediaKeys.contains(mediaKey)) {
            _iosAutoFallbackCountForOpen++;
            _mdkFallbackTriggeredSession = _playSession;
            _mdkAutoFallbackMediaKeys.add(mediaKey);
            final resumePosMs = _resolveFallbackResumePositionMs();
            unawaited(
              _switchIosEngineMode(
                IosPlaybackEngineMode.mpv,
                persist: false,
                isAutoFallback: true,
                resumeMsOverride: resumePosMs,
                customToast: 'MDK 引擎不支持当前流，已自动切换至 MPV 播放',
              ),
            );
            return;
          }
        }
        _failPlayback(message);
      }
    }));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncMobileSystemBars();
  }

  bool get _shouldMonitorIosPhysicalOrientation =>
      !_desktop &&
      !widget.embedded &&
      defaultTargetPlatform == TargetPlatform.iOS &&
      !OhosRuntime.isOhos;

  @override
  void didUpdateWidget(covariant PlayerScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.embedded && widget.embedded) {
      _suspendSkipCountdown();
      _cancelTransientInteractions(GestureInterruptReason.pipEntered);
      unawaited(_mobileChrome.setOrientationMonitoring(false));
    } else if (oldWidget.embedded && !widget.embedded) {
      _maybeEvaluateSkipTriggers();
      if (_shouldMonitorIosPhysicalOrientation) {
        unawaited(
          _mobileChrome.setOrientationMonitoring(
            true,
            onPhysicalOrientation: _handlePhysicalOrientation,
          ),
        );
      }
    }
  }

  void _applyObservedIosSystemVolume(double rawVol) {
    final vol = rawVol.clamp(0.0, 1.0);
    final wasSynced = _iosDeviceVolumeSynced;
    _iosDeviceVolumeSynced = true;
    // Always record the latest hardware-confirmed volume even while a drag is
    // still held so lifting the finger or starting the next drag never reuses
    // an unconfirmed preview value.
    _iosConfirmedDeviceVolume = vol;
    if (_iosPendingVolumeDragActive) {
      final pendingDelta = _iosPendingVolumeDragDelta;
      _iosPendingVolumeDragActive = false;
      _iosPendingVolumeDragDelta = 0.0;
      final target = (vol + pendingDelta).clamp(0.0, 1.0);
      _iosDeviceVolume = target;
      if (_isVerticalDragging && !_isDraggingLeftBrightness) {
        _iosFsmVolumeBaseline = vol;
        _iosLegacyVolumeBaseline = vol;
        _verticalDragStartValue = vol;
      }
      _pushIosSystemVolume(target);
      if (mounted) {
        setState(() {
          _hudText = '设备音量 ${(target * 100.0).round()}%';
        });
        if (!_isVerticalDragging) {
          _scheduleVerticalHudClear();
        }
      }
      return;
    }
    if (!wasSynced || !(_isVerticalDragging && !_isDraggingLeftBrightness)) {
      _iosDeviceVolume = vol;
      if (mounted && _hudText.startsWith('设备音量 ')) {
        setState(() {
          _hudText = '设备音量 ${(vol * 100.0).round()}%';
        });
      }
    }
  }

  Future<void> _primeIosSystemVolume() async {
    if (!_isIosPlayerPlatform || !mounted || _iosVolumeReadInFlight) return;
    _iosVolumeReadInFlight = true;
    try {
      final vol = _iosAvPlayerController != null
          ? await _iosAvPlayerController!.getSystemVolume()
          : await IosAvPlayerController.readDefaultSystemVolume();
      if (!mounted || vol == null) return;
      _applyObservedIosSystemVolume(vol);
    } finally {
      _iosVolumeReadInFlight = false;
    }
  }

  void _pushIosSystemVolume(double volume01) {
    final clamped = volume01.clamp(0.0, 1.0);
    _iosPendingSystemVolume = clamped;
    if (_iosSystemVolumeFlushing) return;
    _iosSystemVolumeFlushing = true;
    unawaited(() async {
      try {
        while (mounted && _iosPendingSystemVolume != null) {
          final target = _iosPendingSystemVolume!;
          _iosPendingSystemVolume = null;
          final res = _iosAvPlayerController != null
              ? await _iosAvPlayerController!.setSystemVolumeDetailed(target)
              : await IosAvPlayerController.writeDefaultSystemVolumeDetailed(
                  target,
                );
          if (!mounted) return;
          if (!res.applied) {
            final confirmed = res.observedVolume ?? res.confirmedVolume;
            if (confirmed != null) {
              _iosConfirmedDeviceVolume = confirmed;
              _iosDeviceVolume = confirmed;
              _iosDeviceVolumeSynced = true;
              if (_iosPendingSystemVolume == null) {
                setState(() {
                  _hudText = '设备音量 ${(confirmed * 100.0).round()}%';
                });
                if (!_isVerticalDragging) _scheduleVerticalHudClear();
              }
            } else if (_iosPendingSystemVolume == null) {
              setState(() => _hudText = '系统音量暂不可调');
              if (!_isVerticalDragging) _scheduleVerticalHudClear();
            }
          } else {
            if (res.observedVolume != null) {
              _iosConfirmedDeviceVolume = res.observedVolume!;
              _iosDeviceVolumeSynced = true;
            } else if (res.confirmedVolume != null) {
              _iosConfirmedDeviceVolume = res.confirmedVolume!;
              _iosDeviceVolumeSynced = true;
            }
            if (_iosPendingSystemVolume == null &&
                !(_isVerticalDragging && !_isDraggingLeftBrightness)) {
              _iosDeviceVolume = _iosConfirmedDeviceVolume;
            }
          }
        }
      } finally {
        _iosSystemVolumeFlushing = false;
      }
    }());
  }

  void _clearPendingAutoStartPip() {
    _iosPipRequestGen++;
    _iosPipRefreshInFlight = false;
    _pendingAutoStartPipSession = null;
    _pendingAutoStartPipMediaId = null;
    _cancelStartingPipSession = null;
    _cancelStartingPipMediaId = null;
    _pendingPipTimeoutTimer?.cancel();
    _pendingPipTimeoutTimer = null;
  }

  void _armPendingAutoStartPip({int? session, int? mediaId}) {
    final boundSession = session ?? _playSession;
    _pendingAutoStartPipSession = boundSession;
    _pendingAutoStartPipMediaId = mediaId;
    _pendingPipTimeoutTimer?.cancel();
    _pendingPipTimeoutTimer = Timer(const Duration(seconds: 6), () {
      if (!mounted || _pendingAutoStartPipSession != boundSession) return;
      _clearPendingAutoStartPip();
      if (_usingAvPlayer &&
          !(_iosAvPlayerController?.isPipActive ?? false) &&
          !(_iosAvPlayerController?.isPipStarting ?? false)) {
        _showHud('画中画暂不可用，请确认视频已正常播放');
      }
    });
  }

  Future<void> _submitIosPipStart(
    IosAvPlayerController avCtrl, {
    required int session,
    required int requestGen,
    int? mediaId,
  }) async {
    final started = await avCtrl.startPip();
    if (!mounted ||
        !_usingAvPlayer ||
        !identical(_iosAvPlayerController, avCtrl) ||
        session != _playSession ||
        requestGen != _iosPipRequestGen) {
      return;
    }
    if (mediaId != null && avCtrl.currentMediaId != mediaId) return;
    if (!started) {
      if (!avCtrl.isPipPossible || _loading || _buffering) {
        _armPendingAutoStartPip(session: session, mediaId: avCtrl.currentMediaId);
      } else {
        final err = avCtrl.lastPipError?.trim() ?? '';
        _showHud(
          err.isNotEmpty ? '画中画开启失败：$err' : '画中画暂不可用，请确认视频已开始播放',
        );
      }
    }
  }

  Future<void> _handleIosPipTap() async {
    if (!_isIosPlayerPlatform || !mounted) return;
    final avCtrl = _iosAvPlayerController;
    if (_usingAvPlayer && avCtrl != null) {
      if (avCtrl.isPipActive) {
        _clearPendingAutoStartPip();
        await avCtrl.stopPip();
        return;
      }
      if (avCtrl.isPipStarting) {
        // Native has already accepted startPictureInPicture() and is inside the
        // willStart -> didStart transition. Do NOT issue a duplicate startPip();
        // record cancellation intent so we call stopPip() at the earliest moment
        // iOS allows (upon didStart, or immediately if native already activated).
        _iosPipRequestGen++;
        _iosPipRefreshInFlight = false;
        _pendingAutoStartPipSession = null;
        _pendingAutoStartPipMediaId = null;
        _pendingPipTimeoutTimer?.cancel();
        _pendingPipTimeoutTimer = null;
        _cancelStartingPipSession = _playSession;
        _cancelStartingPipMediaId = avCtrl.currentMediaId;
        _showHud('正在取消画中画…');
        if (mounted) setState(() {});
        return;
      }
      if (_hasPendingAutoStartPip || _iosPipRefreshInFlight) {
        _clearPendingAutoStartPip();
        _showHud('已取消画中画准备');
        return;
      }
      _cancelStartingPipSession = null;
      _cancelStartingPipMediaId = null;
      // Bind this PiP request to the active playback session, controller, media
      // item, and generation BEFORE any async capability refresh so switching
      // episodes/channels/lines or cancelling while refreshTelemetry() is
      // suspended can never leak startPip() onto a newer item.
      final tapCtrl = avCtrl;
      final tapSession = _playSession;
      final tapMediaId = tapCtrl.currentMediaId;
      final tapGen = ++_iosPipRequestGen;
      bool isStaleRequest() =>
          !mounted ||
          !_usingAvPlayer ||
          !identical(_iosAvPlayerController, tapCtrl) ||
          tapSession != _playSession ||
          tapGen != _iosPipRequestGen ||
          (tapMediaId != null && tapCtrl.currentMediaId != tapMediaId);

      if (!tapCtrl.isPipSupported) {
        _iosPipRefreshInFlight = true;
        try {
          await tapCtrl.refreshTelemetry();
        } finally {
          if (tapGen == _iosPipRequestGen) {
            _iosPipRefreshInFlight = false;
          }
        }
        if (isStaleRequest()) return;
      }
      if (!tapCtrl.isPipSupported) {
        _showHud('当前设备不支持系统画中画');
        return;
      }
      final started = await tapCtrl.startPip();
      if (isStaleRequest()) return;
      if (started) {
        _clearPendingAutoStartPip();
        return;
      }
      if (_loading || _buffering || !tapCtrl.isPipPossible) {
        _armPendingAutoStartPip(session: tapSession, mediaId: tapMediaId);
        _showHud('正在准备画中画，缓冲就绪后将自动开启…');
      } else {
        final err = tapCtrl.lastPipError?.trim() ?? '';
        _showHud(
          err.isNotEmpty ? '画中画开启失败：$err' : '画中画暂不可用，请确认视频已开始播放',
        );
      }
      return;
    }

    // Currently playing on MPV: temporarily switch THIS playback session to
    // AVPlayer when compatible so Picture-in-Picture works in one tap without
    // overwriting the user's saved global MPV engine preference.
    if (avCtrl == null) {
      _showHud('当前播放会话暂不支持系统画中画');
      return;
    }
    if (_lastAvExternalAudioUrl.isNotEmpty) {
      _showHud('当前片源包含独立外挂音轨，需使用 MPV 解码，暂不支持画中画');
      return;
    }
    final precheck = IosAvPlayerController.checkUrlCompatibility(
      _activeStreamUrl,
      episodeName: _currentEpisode.name,
      lineName: _currentLine.name,
    );
    if (!precheck.supported) {
      _showHud('当前流格式仅支持 MPV 解码，暂不支持系统画中画');
      return;
    }
    final keepPos = _isLiveStream
        ? 0
        : (_position.inMilliseconds >= 1000
            ? _position.inMilliseconds
            : _lastKnownPositionMs);
    setState(() => _sessionForceAvPlayerForPip = true);
    _showHud('正在临时切换原生内核以开启画中画…');
    unawaited(
      _openCurrentEpisode(
        resumeMs: keepPos,
        armPendingPipForThisSession: true,
      ),
    );
  }

  Future<void> _initIosAvPlayerTelemetry() async {
    final ctrl = _iosAvPlayerController;
    if (ctrl == null || !mounted) return;
    await ctrl.initialize();
    if (!mounted) return;
    if (ctrl.hasSystemVolume) {
      _applyObservedIosSystemVolume(ctrl.systemVolume);
    } else {
      unawaited(_primeIosSystemVolume());
    }
    final memBytes = ctrl.physicalMemoryBytes;
    if (memBytes > 0 && memBytes != _avPhysicalMemoryBytes) {
      _avPhysicalMemoryBytes = memBytes;
      if (!_usingAvPlayer) {
        _playerConfiguration = _playerConfiguration.then(
          (_) => _applyPlayerKernel(_playerKernel),
        );
      }
    }
    if (mounted) setState(() {});
  }

  void _dispatchAvSeek(
    IosAvPlayerController ctrl,
    int targetMs, {
    bool showResumeHudOnSuccess = false,
    bool saveProgressOnSuccess = false,
  }) {
    final clampedMs = math.max(0, targetMs);
    final seekSession = _playSession;
    final seekMediaId = ctrl.currentMediaId;
    final seekGen = ++_avPendingSeekGen;
    if (!_currentEpisodePlaybackConfirmed) {
      _avClockAnchorMs = math.max(_avClockAnchorMs, clampedMs);
      _avObservedPlayingMinPosMs = null;
      _avPendingSeekTargetMs = clampedMs > 0 ? clampedMs : null;
    }
    _avDispatchingSeek = true;
    late final Future<bool> seekFuture;
    try {
      seekFuture = ctrl.seek(Duration(milliseconds: clampedMs));
    } finally {
      _avDispatchingSeek = false;
    }
    unawaited(
      seekFuture.then((finished) {
        if (!mounted ||
            !_usingAvPlayer ||
            !identical(_iosAvPlayerController, ctrl) ||
            seekSession != _playSession ||
            (seekMediaId != null && ctrl.currentMediaId != seekMediaId)) {
          return;
        }
        final isLatest = seekGen == _avPendingSeekGen;
        final confirmedMs = ctrl.confirmedPosition?.inMilliseconds;
        // Once no seek remains in flight, sync displayed position and history
        // cache directly from `IosAvPlayerController`'s single resolved state—
        // including when an earlier seek succeeds AFTER a newer seek already
        // failed.
        if (!ctrl.hasInFlightSeek) {
          _lastKnownPositionMs = confirmedMs ?? 0;
          if (!_isDraggingSeek &&
              !_isSliderDragging &&
              _position != ctrl.position) {
            setState(() => _position = ctrl.position);
          }
        }
        if (finished) {
          if (!isLatest) {
            return;
          }
          _lastKnownPositionMs = confirmedMs ?? clampedMs;
          if (showResumeHudOnSuccess && clampedMs > 0) {
            _showHud(
              '已为您续播至 ${_formatDuration(Duration(milliseconds: clampedMs))}',
            );
          }
          if (saveProgressOnSuccess) {
            unawaited(_saveProgress(immediate: true, triggerSync: false));
          }
          return;
        }
        if (!isLatest) {
          return;
        }
        // Native explicitly rejected/cancelled the latest seek: never show a
        // resume success toast, and re-anchor playback confirmation if not yet
        // confirmed.
        final nativeSample =
            ctrl.nativePositionSampleMediaId == ctrl.currentMediaId
                ? ctrl.nativePositionSample
                : null;
        if (_currentEpisodePlaybackConfirmed) {
          return;
        }
        _avPendingSeekTargetMs = null;
        if (ctrl.playing && !ctrl.buffering && nativeSample != null) {
          final curMs = nativeSample.inMilliseconds;
          _avClockAnchorMs = curMs;
          _avObservedPlayingMinPosMs = curMs;
        } else {
          _avClockAnchorMs = 0;
          _avObservedPlayingMinPosMs = null;
        }
      }),
    );
  }

  void _onIosAvPlayerChanged() {
    final ctrl = _iosAvPlayerController;
    if (!mounted || ctrl == null || !_usingAvPlayer || !_allowEvents) return;

    final prevW = _videoWidth;
    final prevH = _videoHeight;
    final prevDurSec = _duration.inSeconds;
    final prevLoading = _loading;
    final prevStartedVod = _hasStartedVodPlayback;
    final prevPlaying = _playing;
    final prevBuffering = _buffering;
    final prevCompleted = _wasAvCompleted;
    final prevPipActive = _lastIosPipActive;
    final prevPipStarting = _lastAvPipStarting;
    final prevPipPossible = _lastAvPipPossible;
    final prevAirPlay = _lastAvAirPlayActive;

    final nextW = ctrl.videoWidth;
    final nextH = ctrl.videoHeight;
    final nextPlaying = ctrl.playing;
    final nextBuffering = ctrl.buffering;
    final nextDur = ctrl.duration;
    final nextPos = ctrl.position;
    final nextCompleted = ctrl.completed;
    final nextReady = ctrl.ready;

    if (nextW > 0 && nextH > 0 && (nextW != _videoWidth || nextH != _videoHeight)) {
      _videoWidth = nextW;
      _videoHeight = nextH;
      if (_isLiveStream && nextPlaying && !nextBuffering) {
        _confirmLiveVideoOutput();
        _startup.markLiveFrameReady();
      }
      _startSpecController.onFirstFrameReady(
        enabled: _hudPrefs.effectiveStartSpecHud,
        isLive: _isLiveStream,
      );
    }

    if (nextDur > Duration.zero) {
      if (nextDur.inMilliseconds > _lastKnownDurationMs) {
        _lastKnownDurationMs = nextDur.inMilliseconds;
      }
      _duration = (!_isLiveStream && _lastKnownDurationMs > nextDur.inMilliseconds)
          ? Duration(milliseconds: _lastKnownDurationMs)
          : nextDur;
    }

    if (!_isDraggingSeek && !_isSliderDragging) {
      _position = (_pendingResumeMs > 0 && nextPos.inMilliseconds < 2000)
          ? Duration(milliseconds: _pendingResumeMs)
          : nextPos;
      _syncAiSubtitleClockMs(_position.inMilliseconds);
    }

    if (!_isLiveStream && nextDur > Duration.zero && _pendingResumeMs > 0) {
      final maxSeek = math.max(0, nextDur.inMilliseconds - 2000);
      final targetMs = _pendingResumeMs.clamp(0, maxSeek);
      _pendingResumeMs = 0;
      _introSkippedForSession = true;
      if (targetMs > 0) {
        _startup.reanchor(Duration(milliseconds: targetMs));
        _position = Duration(milliseconds: targetMs);
        _dispatchAvSeek(ctrl, targetMs, showResumeHudOnSuccess: true);
      } else {
        _avPendingSeekGen++;
        _avClockAnchorMs = 0;
        _avObservedPlayingMinPosMs = null;
        _avPendingSeekTargetMs = null;
      }
    }

    // AVPlayer confirmation MUST wait for genuine native media clock samples
    // (`ready` / `playbackState` / `progress` / `completed`) matching the
    // active mediaId while playing (`nextPlaying && !nextBuffering`).
    // Non-clock notifications (such as `pipStateChanged`, `systemVolumeChanged`,
    // `airPlayStateChanged`, or optimistic `seek()` display position updates)
    // NEVER advance confirmation state or consume a pending seek landing.
    final nativeSample = ctrl.nativePositionSample;
    final nativeSampleMediaId = ctrl.nativePositionSampleMediaId;
    final nativeSampleSeq = ctrl.nativePositionSampleSeq;
    final hasFreshNativeClockSample =
        nativeSample != null &&
        nativeSampleMediaId == ctrl.currentMediaId &&
        (nativeSampleSeq != _avLastProcessedClockSeq ||
            nativeSampleMediaId != _avLastProcessedClockMediaId);
    if (hasFreshNativeClockSample) {
      _avLastProcessedClockSeq = nativeSampleSeq;
      _avLastProcessedClockMediaId = nativeSampleMediaId;
    }

    if (!_avDispatchingSeek &&
        hasFreshNativeClockSample &&
        nextPlaying &&
        !nextBuffering) {
      final posMs = nativeSample.inMilliseconds;
      final pendingSeekTarget = _avPendingSeekTargetMs;
      if (pendingSeekTarget != null) {
        // Keyframe-snapped seek tolerance: at most 1500ms or 25% of target,
        // and ALWAYS strictly >= 1ms when target > 0 so pre-seek 0ms ticks
        // can NEVER consume a short resume seek (e.g. 1000ms -> floor 750ms).
        final toleranceMs = math.min(1500, (pendingSeekTarget * 0.25).round());
        final landingFloorMs = math.max(1, pendingSeekTarget - toleranceMs);
        if (posMs >= landingFloorMs) {
          _avPendingSeekTargetMs = null;
          _avClockAnchorMs = math.max(_avClockAnchorMs, posMs);
          _avObservedPlayingMinPosMs = posMs;
        }
      } else {
        final advancedPastAnchor = posMs > _avClockAnchorMs;
        final advancedDuringPlaying =
            _avObservedPlayingMinPosMs != null &&
            posMs > _avObservedPlayingMinPosMs!;
        if (_avObservedPlayingMinPosMs == null ||
            posMs < _avObservedPlayingMinPosMs!) {
          _avObservedPlayingMinPosMs = posMs;
        }
        if (advancedPastAnchor || advancedDuringPlaying) {
          _markCurrentEpisodePlaybackConfirmed();
        }
      }
    }

    // Never let an unconfirmed optimistic seek target dirty `_lastKnownPositionMs`
    // or trigger initial history recording; rely solely on confirmed native clock
    // samples or accepted seek targets.
    final confirmedPosMs = ctrl.confirmedPosition?.inMilliseconds;
    if (!ctrl.hasInFlightSeek && confirmedPosMs != null && confirmedPosMs >= 1000) {
      _lastKnownPositionMs = confirmedPosMs;
      if (_currentEpisodePlaybackConfirmed && !_initialHistoryRecorded) {
        _initialHistoryRecorded = true;
        unawaited(_saveProgress());
      }
    }

    if (nextReady || nextPlaying || nextPos > Duration.zero || nextDur > Duration.zero) {
      if (_loading && (nextPlaying || !nextBuffering)) {
        _loading = false;
      }
      if (!OhosRuntime.isOhos &&
          !_hasStartedVodPlayback &&
          !_isLiveStream &&
          !widget.embedded &&
          nextPlaying &&
          nextPos > Duration.zero) {
        _hasStartedVodPlayback = true;
      }
    }

    _startup.position(nextPos);
    if (nextPlaying && _userPausedPlayback) {
      _startup.updateState(
        playing: false,
        buffering: nextBuffering,
        userPaused: true,
      );
      _playing = false;
      _buffering = nextBuffering;
      PlaybackWakelock.setEnabled(false);
      unawaited(ctrl.pause());
      if (mounted) setState(() {});
      return;
    }
    _startup.updateState(
      playing: nextPlaying,
      buffering: nextBuffering,
      userPaused: _userPausedPlayback,
    );
    _playing = nextPlaying;
    _buffering = nextBuffering;

    if (nextPlaying != _wasAvPlaying) {
      _wasAvPlaying = nextPlaying;
      PlaybackWakelock.setEnabled(nextPlaying);
      unawaited(ctrl.setAutoPip(nextPlaying));
      if (!nextPlaying) {
        _suspendSkipCountdown();
        _saveProgress(immediate: true, syncImmediate: false);
      } else {
        _maybeEvaluateSkipTriggers();
        if (!_loading && !_buffering) _scheduleHide();
      }
      if (nextPlaying || _position > Duration.zero) {
        _embySession?.update(_position.inMilliseconds, !nextPlaying, force: true);
      }
    }

    final currentMediaId = ctrl.currentMediaId;
    if (_cancelStartingPipSession == _playSession &&
        (_cancelStartingPipMediaId == null ||
            _cancelStartingPipMediaId == currentMediaId)) {
      if (ctrl.isPipActive) {
        _cancelStartingPipSession = null;
        _cancelStartingPipMediaId = null;
        unawaited(ctrl.stopPip());
        _showHud('已取消画中画');
      } else if (!ctrl.isPipStarting) {
        _cancelStartingPipSession = null;
        _cancelStartingPipMediaId = null;
      }
    }
    final pendingMediaMatches = _pendingAutoStartPipMediaId == null ||
        _pendingAutoStartPipMediaId == currentMediaId;
    if (_hasPendingAutoStartPip &&
        pendingMediaMatches &&
        !ctrl.isPipActive &&
        !ctrl.isPipStarting &&
        ctrl.isPipSupported &&
        ctrl.isPipPossible) {
      final activeSession = _playSession;
      _clearPendingAutoStartPip();
      final reqGen = _iosPipRequestGen;
      unawaited(
        _submitIosPipStart(
          ctrl,
          session: activeSession,
          requestGen: reqGen,
          mediaId: currentMediaId,
        ),
      );
    }

    if (nextBuffering != _wasAvBuffering) {
      _wasAvBuffering = nextBuffering;
      if (!nextBuffering && _playing) _scheduleHide();
    }

    _embySession?.update(_position.inMilliseconds, !_playing);
    if (!OhosRuntime.isOhos && _danmuSettings.effectiveEnabled) {
      _danmuCache?.onPlaybackTick(_position.inMilliseconds, playing: _playing);
    }
    _maybeEvaluateSkipTriggers(
      positionOverride: _position,
      durationOverride: _duration,
    );

    if (nextCompleted && !_wasAvCompleted && !_outroSkippedForSession) {
      _wasAvCompleted = true;
      _embySession?.stop(_position.inMilliseconds);
      _embySession = null;
      unawaited(
        _saveProgress(completed: true, immediate: true, syncImmediate: false),
      );
      _handleEpisodeEnd();
    } else if (!nextCompleted) {
      _wasAvCompleted = false;
    }

    final pipTransitioned = ctrl.isPipActive != _lastIosPipActive ||
        ctrl.isPipStarting != _lastAvPipStarting;
    if (ctrl.isPipActive != _lastIosPipActive) {
      _lastIosPipActive = ctrl.isPipActive;
      _syncMobileSystemBars(force: true);
    }
    _lastAvPipStarting = ctrl.isPipStarting;
    String? nextSelectedSubTrackId;
    for (final t in ctrl.subtitleTracks) {
      if (t.selected) {
        nextSelectedSubTrackId = t.id;
        break;
      }
    }
    final nextSubTrackSig = ctrl.subtitleTracks
        .map(
          (t) =>
              '${t.id}:${t.selected}:${t.subtitleFormat.name}:${t.isBitmap}:${t.isTextExtractable}',
        )
        .join('|');
    final subTracksChanged = nextSubTrackSig != _lastAvSubtitleTrackSignature;
    if (nextSelectedSubTrackId != _lastAvSelectedSubtitleTrackId) {
      _lastAvSelectedSubtitleTrackId = nextSelectedSubTrackId;
      _avConfirmedTextSubtitleTrackForSession = false;
      _avConfirmedTextSubtitleTrackId = null;
    }
    if (subTracksChanged) {
      _lastAvSubtitleTrackSignature = nextSubTrackSig;
    }
    if (pipTransitioned || subTracksChanged) {
      _syncAvPlayerSubtitleSuppression();
      _aiSubtitleStateRevision.value++;
    }
    _lastAvPipPossible = ctrl.isPipPossible;
    _lastAvAirPlayActive = ctrl.isAirPlayActive;

    final nonPositionVisualChanged = _videoWidth != prevW ||
        _videoHeight != prevH ||
        _duration.inSeconds != prevDurSec ||
        _loading != prevLoading ||
        _hasStartedVodPlayback != prevStartedVod ||
        _playing != prevPlaying ||
        _buffering != prevBuffering ||
        _wasAvCompleted != prevCompleted ||
        _lastIosPipActive != prevPipActive ||
        _lastAvPipStarting != prevPipStarting ||
        _lastAvPipPossible != prevPipPossible ||
        _lastAvAirPlayActive != prevAirPlay;

    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final slimBarVisible = _useEnhancedHud &&
        !_controlsVisible &&
        !_screenLocked &&
        !_isLiveStream &&
        !widget.embedded &&
        _hudPrefs.effectiveSlimProgress &&
        (_duration.inMilliseconds > 0 || _lastKnownDurationMs > 0);
    final shouldRebuildPosition = !_isDraggingSeek &&
        !_isSliderDragging &&
        IosMpvProfile.shouldRebuildPositionUi(
          isIos: true,
          controlsVisible: _controlsVisible,
          screenLocked: _screenLocked,
          slimBarVisible: slimBarVisible,
          isPipActive: ctrl.isPipActive,
          playing: _playing,
          nowMs: nowMs,
          lastUpdateMs: _lastPositionUiUpdateMs,
          nextPositionMs: _position.inMilliseconds,
          lastRenderedPositionMs: _lastRenderedPositionMs,
          iosThermalElevated:
              ctrl.thermalState.isElevated || IosLiquidGlassBridge.thermalElevated,
        );

    if (mounted && (nonPositionVisualChanged || shouldRebuildPosition)) {
      _lastPositionUiUpdateMs = nowMs;
      _lastRenderedPositionMs = _position.inMilliseconds;
      setState(() {});
    }
  }

  static bool _isRtspFamilyUrl(String url) {
    final scheme = Uri.tryParse(url.trim())?.scheme.toLowerCase() ?? '';
    return scheme == 'rtsp' || scheme == 'rtsps';
  }

  static bool _isNonHttpStreamUrl(String url) {
    final scheme = Uri.tryParse(url.trim())?.scheme.toLowerCase() ?? '';
    return scheme.isNotEmpty &&
        scheme != 'http' &&
        scheme != 'https' &&
        scheme != 'file';
  }

  static String _sanitizeFallbackReason(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      return 'Apple 原生内核不支持当前片源，已自动切换 MPV 续播';
    }
    final lower = trimmed.toLowerCase();
    if (lower.contains('unsupported url') ||
        trimmed.contains('不支持的URL') ||
        trimmed.contains('不支持的 URL') ||
        lower.contains('nsurlerror')) {
      return '已自动切换至 MPV 内核播放';
    }
    return trimmed;
  }

  Future<void> _configureMpvStreamProperties(
    String url,
    Map<String, String> headers, {
    bool isProxied = false,
    bool preferUdpRtsp = false,
  }) async {
    try {
      final dyn = _player.platform as dynamic;
      final isRtsp = _isRtspFamilyUrl(url);
      final isNonHttp = _isNonHttpStreamUrl(url);
      await dyn.setProperty('tls-verify', _isLiveStream ? 'no' : 'yes');
      if (isRtsp) {
        final transport = preferUdpRtsp ? 'udp' : 'tcp';
        try {
          await dyn.setProperty('rtsp-transport', transport);
        } catch (_) {}
        try {
          await dyn.setProperty('network-timeout', '12');
        } catch (_) {}
        try {
          await dyn.setProperty(
            'demuxer-lavf-o',
            'rtsp_transport=$transport,stimeout=10000000',
          );
        } catch (_) {}
      } else {
        try {
          await dyn.setProperty('demuxer-lavf-o', '');
        } catch (_) {}
      }
      final ua = headers.entries
          .firstWhere(
            (e) => e.key.toLowerCase() == 'user-agent',
            orElse: () => const MapEntry('User-Agent', ''),
          )
          .value;
      if (ua.isNotEmpty) {
        await dyn.setProperty('user-agent', ua);
      }
      final ref = (isProxied || isNonHttp)
          ? ''
          : headers.entries
              .firstWhere(
                (e) => e.key.toLowerCase() == 'referer',
                orElse: () => const MapEntry('Referer', ''),
              )
              .value;
      await dyn.setProperty('referrer', ref);
    } catch (_) {}
  }

  Future<void> _handleRuntimeFallbackToMpv(FallbackToMpvRequested event) async {
    final avCtrl = _iosAvPlayerController;
    if (!mounted || avCtrl == null || !_usingAvPlayer || _fallbackInFlight) {
      return;
    }
    if (_iosAutoFallbackCountForOpen >= 1) {
      _failPlayback(event.reason);
      return;
    }
    _iosAutoFallbackCountForOpen++;
    _fallbackInFlight = true;
    _clearPendingAutoStartPip();
    _sessionForceAvPlayerForPip = false;
    final resumeMs = event.positionMs > 0
        ? event.positionMs
        : (_position.inMilliseconds > 0
              ? _position.inMilliseconds
              : _lastKnownPositionMs);
    final url = _activeResolvedMediaUrl;
    final headers = _activeResolvedHeaders;
    final session = _playSession;
    _usingAvPlayer = false;
    setState(() {
      _loading = true;
      _playing = false;
      _buffering = false;
      _wasAvPlaying = false;
      _wasAvBuffering = false;
      _wasAvCompleted = false;
    });
    try {
      await avCtrl.stop();
      if (!mounted || session != _playSession) return;
      final wantMdk = _shouldUseIosMdkForMedia(url);
      await _ensureIosUnderlyingKernel(wantMdk: wantMdk);
      if (!mounted || session != _playSession) return;
      _showHud(
        wantMdk
            ? '检测到高规格/杜比视界封装，已自动切换 Metal MDK 硬解播放'
            : _sanitizeFallbackReason(event.reason),
      );
      await _applyPlayerKernel(_playerKernel);
      if (!mounted || session != _playSession || url.isEmpty) return;
      await _changeMedia(session, () async {
        _allowEvents = true;
        _winQualityController.resumeAudioFilterRecovery();
        _activeMediaUri = Media(url).uri;
        await _configureMpvStreamProperties(url, headers);
        await _player.open(
          Media(
            url,
            httpHeaders: _isNonHttpStreamUrl(url)
                ? const <String, String>{}
                : headers,
            start: resumeMs > 0 ? Duration(milliseconds: resumeMs) : null,
          ),
          play: !_castController.isCasting,
        );
        if (_lastAvExternalAudioUrl.isNotEmpty) {
          await _player.setAudioTrack(AudioTrack.uri(_lastAvExternalAudioUrl));
        }
        await _player.setRate(_isLiveStream ? 1.0 : _normalSpeed);
      });
    } finally {
      _fallbackInFlight = false;
      if (mounted) {
        _lastIosPipActive = false;
        _syncMobileSystemBars(force: true);
      }
    }
  }

  bool _shouldUseIosMdkForMedia(String url) {
    if (!_isIosPlayerPlatform || _isLiveStream) return false;
    if (widget.debugPlayer != null && widget.debugIosKernelFactory == null) {
      return false;
    }
    if (_mdkAutoFallbackMediaKeys.contains(_currentMdkMediaKey)) {
      return false;
    }
    if (_effectiveIosEngineMode == IosPlaybackEngineMode.mdk) {
      return true;
    }
    if (_effectiveIosEngineMode == IosPlaybackEngineMode.mpv) {
      return false;
    }
    return IosMpvProfile.prefersIosMetalMdkWhenAvPlayerUnsupported(
      url: url,
      episodeName: _currentEpisode.name,
      lineName: _currentLine.name,
    );
  }

  Future<void> _ensureIosUnderlyingKernel({required bool wantMdk}) async {
    if (!_isIosPlayerPlatform) return;
    if (widget.debugPlayer != null && widget.debugIosKernelFactory == null) {
      return;
    }
    if (_videoKernel.isMdk == wantMdk || _switchingIosKernel) return;
    _switchingIosKernel = true;
    try {
      final keepVolume = _engineVolume100;
      final activePlatform = _player.platform;
      if (activePlatform is MdkPlatformPlayer) {
        activePlatform.cancelPendingOpen();
      }
      _detachLiveVideoOutputObservers();
      for (final sub in _playerSubscriptions) {
        unawaited(sub.cancel());
      }
      _playerSubscriptions.clear();
      final oldPlayer = _player;
      try {
        await oldPlayer.stop();
      } catch (_) {}
      if (!_playerDisposed) {
        _playerDisposed = true;
        try {
          await oldPlayer.dispose();
        } catch (_) {}
      }
      if (!mounted) return;
      final nextKernel = widget.debugIosKernelFactory?.call(wantMdk) ??
          VideoKernel.create(
            debugVideoSurface: widget.debugVideoSurface,
            hwdec: _hardwareDecoder(_playerKernel),
            windowsEngine: _windowsEngine,
            kernelStrategy: _playerKernel,
            useIosMdk: wantMdk,
          );
      _videoKernel = nextKernel;
      _player = nextKernel.player;
      _playerDisposed = false;
      _attachPlayerStreams();
      _playerConfiguration = _applyPlayerKernel(_playerKernel);
      await _playerConfiguration;
      if (!mounted) return;
      await _player.setVolume(keepVolume);
      if (!wantMdk &&
          _anime4kController.isIosLightweightAvailableForPlayer(_player)) {
        unawaited(_initAnime4kAfterKernel());
      }
    } finally {
      _switchingIosKernel = false;
    }
  }

  Future<void> _switchIosEngineMode(
    IosPlaybackEngineMode nextMode, {
    bool persist = true,
    bool isAutoFallback = false,
    int? resumeMsOverride,
    String? customToast,
  }) async {
    if (!_isIosPlayerPlatform) return;
    if (nextMode == IosPlaybackEngineMode.avPlayer &&
        _lastAvExternalAudioUrl.isNotEmpty) {
      _showHud('当前片源包含独立外挂音轨，需使用 MDK 或 MPV 内核');
      return;
    }
    if (nextMode == IosPlaybackEngineMode.avPlayer && !_isLiveStream) {
      final precheck = IosAvPlayerController.checkUrlCompatibility(
        _activeStreamUrl,
        episodeName: _currentEpisode.name,
        lineName: _currentLine.name,
      );
      if (!precheck.supported) {
        _showHud(precheck.reason ?? '当前格式不支持 Apple 原生 AVPlayer，建议使用 MDK 或 MPV');
        return;
      }
    }
    if (nextMode == IosPlaybackEngineMode.mdk && !isAutoFallback) {
      _mdkFallbackTriggeredSession = -1;
      _mdkAutoFallbackMediaKeys.remove(_currentMdkMediaKey);
    }
    final keepPos = resumeMsOverride ??
        (_position.inMilliseconds >= 1000
            ? _position.inMilliseconds
            : _lastKnownPositionMs);
    _clearPendingAutoStartPip();
    setState(() {
      _sessionForceAvPlayerForPip = false;
      _iosEngineMode = nextMode;
    });
    if (persist) {
      await widget.storage.setIosPlaybackEngineMode(nextMode.id);
    }
    if (!mounted) return;
    _showHud(customToast ?? '已切换至 ${nextMode.labelZh}');
    _syncMobileSystemBars(force: true);
    unawaited(
      _openCurrentEpisode(
        resumeMs: keepPos,
        isAutoFallback: isAutoFallback,
      ),
    );
  }

  Future<void> _toggleIosEngine() async {
    if (!_isIosPlayerPlatform) return;
    final nextMode = switch (_iosEngineMode) {
      IosPlaybackEngineMode.avPlayer => IosPlaybackEngineMode.mdk,
      IosPlaybackEngineMode.mdk => IosPlaybackEngineMode.mpv,
      IosPlaybackEngineMode.mpv => IosPlaybackEngineMode.avPlayer,
    };
    await _switchIosEngineMode(nextMode);
  }

  void _showIosEnginePickerSheet({Rect? anchorRect}) {
    if (!_isIosPlayerPlatform) return;
    _cancelTransientInteractions(GestureInterruptReason.dialogOpened);
    final activeMode = _usingAvPlayer
        ? IosPlaybackEngineMode.avPlayer
        : (_videoKernel.isMdk
              ? IosPlaybackEngineMode.mdk
              : IosPlaybackEngineMode.mpv);
    final options = <AppleNativePickerOption<IosPlaybackEngineMode>>[
      AppleNativePickerOption<IosPlaybackEngineMode>(
        value: IosPlaybackEngineMode.avPlayer,
        title: 'Apple 原生 AVPlayer',
        subtitle: '系统零拷贝硬解 · 超低发热 · 支持画中画',
        symbol: 'play.rectangle.fill',
        checked: activeMode == IosPlaybackEngineMode.avPlayer,
      ),
      if (!_isLiveStream)
        AppleNativePickerOption<IosPlaybackEngineMode>(
          value: IosPlaybackEngineMode.mdk,
          title: 'MDK (Metal 4K 杜比视界)',
          subtitle: 'Apple Metal 硬解 · 解决 4K 杜比 MKV 偏绿与慢放',
          symbol: 'sparkles.tv.fill',
          checked: activeMode == IosPlaybackEngineMode.mdk,
        ),
      AppleNativePickerOption<IosPlaybackEngineMode>(
        value: IosPlaybackEngineMode.mpv,
        title: 'MPV 全能解码',
        subtitle: '全封装兼容 · 支持人声响度增强与轻超分',
        symbol: 'cpu',
        checked: activeMode == IosPlaybackEngineMode.mpv,
      ),
    ];
    if (_canUseNativeIosSheet) {
      final session = _playSession;
      unawaited(() async {
        final picked = await showAppleNativeOptionSheet<IosPlaybackEngineMode>(
          context,
          title: '选择播放内核',
          forceOpaque: _effectiveSheetForceOpaque,
          anchorRect: anchorRect,
          forceDark: true,
          options: options,
          fallback: () async {
            _showIosEngineFallbackPopover(options, anchorRect: anchorRect);
            return null;
          },
        );
        if (!mounted || session != _playSession || picked == null) return;
        await _switchIosEngineMode(picked);
      }());
      return;
    }
    _showIosEngineFallbackPopover(options, anchorRect: anchorRect);
  }

  void _showIosEngineFallbackPopover(
    List<AppleNativePickerOption<IosPlaybackEngineMode>> options, {
    Rect? anchorRect,
  }) {
    showIosGlassPopover<void>(
      context: context,
      anchorRect: anchorRect,
      title: '选择播放内核',
      maxWidth: 300,
      maxHeight: 320,
      forceDark: true,
      builder: (ctx) => ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.all(4),
        children: [
          AppleGroupedSection(
            children: [
              for (final opt in options)
                AppleGroupedTile(
                  icon: CupertinoIcons.play_rectangle_fill,
                  iconBgColor: opt.checked
                      ? AppleColors.systemBlue
                      : AppleColors.groupedTertiary,
                  title: opt.title,
                  subtitle: opt.subtitle,
                  trailing: opt.checked
                      ? const Icon(
                          CupertinoIcons.checkmark_alt,
                          color: AppleColors.systemBlue,
                          size: 18,
                        )
                      : null,
                  onTap: () {
                    Navigator.of(ctx).pop();
                    unawaited(_switchIosEngineMode(opt.value));
                  },
                ),
            ],
          ),
        ],
      ),
    );
  }

  void _showVocalLoudnessSheet({Rect? anchorRect}) {
    _cancelTransientInteractions(GestureInterruptReason.dialogOpened);
    Future<void> applyPreset(VocalLoudnessPreset preset) async {
      setState(() => _vocalLoudness = preset);
      await widget.storage.setVocalLoudnessPreset(preset.id);
      await IosMpvProfile.applyVocalLoudness(_player, preset);
      if (!mounted) return;
      _showHud(
        _usingAvPlayer
            ? '人声响度：${preset.labelZh}（将在 MPV 模式生效）'
            : '人声响度增强：${preset.labelZh}',
      );
    }

    if (_canUseNativeIosSheet) {
      final session = _playSession;
      unawaited(() async {
        final picked = await showAppleNativeOptionSheet<VocalLoudnessPreset>(
          context,
          title: '人声响度增强',
          forceOpaque: _effectiveSheetForceOpaque,
          anchorRect: anchorRect,
          forceDark: true,
          options: [
            for (final preset in VocalLoudnessPreset.values)
              AppleNativePickerOption<VocalLoudnessPreset>(
                value: preset,
                title: preset.labelZh,
                subtitle: preset.descriptionZh,
                symbol: 'waveform.badge.plus',
                checked: _vocalLoudness == preset,
              ),
          ],
          fallback: () async {
            _showVocalLoudnessFallbackSheet(applyPreset, anchorRect: anchorRect);
            return null;
          },
        );
        if (!mounted || session != _playSession || picked == null) return;
        await applyPreset(picked);
      }());
      return;
    }
    _showVocalLoudnessFallbackSheet(applyPreset, anchorRect: anchorRect);
  }

  void _showVocalLoudnessFallbackSheet(
    Future<void> Function(VocalLoudnessPreset) applyPreset, {
    Rect? anchorRect,
  }) {
    Widget buildContent(BuildContext ctx) => ListView(
      shrinkWrap: true,
      padding: EdgeInsets.all(_useIos26PlayerChrome ? 4 : 16),
      children: [
        AppleGroupedSection(
          children: [
            for (final preset in VocalLoudnessPreset.values)
              AppleGroupedTile(
                icon: CupertinoIcons.waveform,
                iconBgColor: _vocalLoudness == preset
                    ? AppleColors.systemBlue
                    : AppleColors.groupedTertiary,
                title: preset.labelZh,
                subtitle: preset.descriptionZh,
                trailing: _vocalLoudness == preset
                    ? const Icon(
                        CupertinoIcons.checkmark_alt,
                        color: AppleColors.systemBlue,
                        size: 18,
                      )
                    : null,
                onTap: () {
                  Navigator.of(ctx).pop();
                  unawaited(applyPreset(preset));
                },
              ),
          ],
        ),
      ],
    );
    if (_useIos26PlayerChrome) {
      showIosGlassPopover<void>(
        context: context,
        anchorRect: anchorRect,
        title: '人声响度增强',
        maxWidth: 280,
        maxHeight: 320,
        forceDark: true,
        builder: buildContent,
      );
      return;
    }
    showAppleModalSheet<void>(
      context: context,
      title: '人声响度增强',
      builder: buildContent,
    );
  }

  void _syncMobileSystemBars({bool force = false}) {
    if (_desktop ||
        widget.embedded ||
        OhosRuntime.shouldUseTvUi(widget.storage.tvUiMode)) {
      return;
    }
    final size = MediaQuery.maybeSizeOf(context);
    final isLandscape = size != null && size.width > size.height;
    final isTablet = size != null && size.shortestSide >= 600;
    final isPipActive =
        _usingAvPlayer && (_iosAvPlayerController?.isPipActive ?? false);
    final showPortraitCompanion = _shouldShowPortraitCompanion(size);
    final isFullscreen =
        !widget.embedded && !isPipActive && !showPortraitCompanion;
    final immersive = isFullscreen &&
        (_screenLocked || !_controlsVisible || isLandscape || isTablet);
    unawaited(_mobileChrome.setImmersive(immersive, force: force));
  }

  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    if (!mounted || _desktop || widget.embedded) return;
    if (_shouldMonitorIosPhysicalOrientation && _appInForeground) {
      unawaited(
        _mobileChrome.retryOrientationMonitoringIfNeeded(resetBackoff: true),
      );
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _syncMobileSystemBars(force: true);
      final pending = _pendingIosOrientationFeedback;
      if (pending != null && _isIosPlayerPlatform) {
        final nowMs = DateTime.now().millisecondsSinceEpoch;
        if (nowMs > pending.expiresAtMs) {
          _pendingIosOrientationFeedback = null;
        } else {
          final nextSize = MediaQuery.maybeSizeOf(context);
          if (nextSize != null) {
            final nowLandscape = nextSize.width > nextSize.height;
            if (nowLandscape == pending.wantLandscape) {
              _pendingIosOrientationFeedback = null;
              _showHud(
                nowLandscape ? '已切换为全屏横屏观看' : '已切换为竖屏观看',
              );
              _scheduleHide();
            }
          }
        }
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      _appInForeground = false;
      _mobileChrome.pauseOrientationMonitoringRetry();
      _suspendSkipCountdown();
      _cancelTransientInteractions(GestureInterruptReason.lifecyclePause);
      if (state == AppLifecycleState.paused ||
          state == AppLifecycleState.hidden) {
        if (_usesOhosAvPlayer && !_usingAvPlayer) {
          _resumeOhosOnForeground = _playing && _playbackError.isEmpty;
          _ohosBackgroundResumeMs = _position.inMilliseconds > 0
              ? _position.inMilliseconds
              : _lastKnownPositionMs;
          if (_resumeOhosOnForeground) {
            unawaited(_enginePause());
          }
        }
        _saveProgress(immediate: true);
        widget.storage.flushPendingHistory();
        widget.storage.scheduleAutoWebdavSync(immediate: true);
      }
    } else if (state == AppLifecycleState.resumed) {
      final wasInactive = !_appInForeground;
      _appInForeground = true;
      unawaited(IosLiquidGlassBridge.refreshReduceTransparency());
      _syncMobileSystemBars(force: true);
      if (_shouldMonitorIosPhysicalOrientation) {
        unawaited(
          _mobileChrome.retryOrientationMonitoringIfNeeded(
            resetBackoff: true,
            forceHostReconcile: wasInactive,
          ),
        );
      }
      if (_usesOhosAvPlayer && !_usingAvPlayer && _resumeOhosOnForeground) {
        _resumeOhosOnForeground = false;
        if (_playbackError.isEmpty) {
          if (_isLiveStream) {
            unawaited(_openCurrentEpisode(resumeMs: 0));
          } else if (_ohosBackgroundResumeMs > 0 &&
              _position.inMilliseconds == 0) {
            unawaited(_openCurrentEpisode(resumeMs: _ohosBackgroundResumeMs));
          } else {
            unawaited(_enginePlay());
            unawaited(_engineSetRate(_normalSpeed));
          }
        }
      }
      _maybeEvaluateSkipTriggers();
    }
  }

  WatchHistoryEntry? _historyForCurrentEpisode() {
    if (_activeSite.isEffectivelyPrivate) return null;
    for (final entry in widget.storage.getWatchHistory()) {
      if (entry.site != _activeSite.key || entry.id != _activeVideo.id) continue;
      final wogg = WoggSource.supports(_activeSite);
      if (wogg || _isIosPlayerPlatform) {
        final video = CmsVideo(id: _activeVideo.id, title: _activeVideo.title, lines: _lines);
        final target = wogg
            ? WoggSource.resolveCachedBookmarkTarget(_activeSite, video, entry)
            : resolveIosWatchHistoryTarget(video, entry);
        return target == (_lineIndex, _episodeIndex) ? entry : null;
      }
      if ((entry.line == _currentLine.name && entry.index == _episodeIndex) ||
          entry.episode == _currentEpisode.name) return entry;
      break;
    }
    return null;
  }

  void _handleEpisodeEnd() {
    if (_sleepTimer.handleEpisodeCompleted()) {
      return;
    }
    if (_repeatMode == 'one') {
      _userNavigationGen++;
      if (_activeSite.isEmby) {
        _openCurrentEpisode(resumeMs: 0);
        return;
      }
      _seekPlayer(Duration.zero);
      _enginePlay();
      _outroSkippedForSession = false;
      return;
    }
    if (_autoNext && !_isMultiVersionMovie) {
      final nextIdx = _adjacentVisibleEpisodeIndex(1);
      if (nextIdx != null) {
        _stepEpisode(1);
      } else if (_repeatMode == 'all' && _currentLine.episodes.isNotEmpty) {
        final order = _visibleOrderedEpisodeIndices();
        final firstVisible = order.isNotEmpty ? order.first : 0;
        _userNavigationGen++;
        _saveProgress(immediate: true, syncImmediate: false);
        setState(() => _episodeIndex = firstVisible);
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
    final curIdx = _qualityChoices.indexWhere(_matchesActiveQuality);
    if (curIdx >= 0) {
      for (int i = curIdx + 1; i < _qualityChoices.length; i++) {
        final candidate = _qualityChoices[i];
        final normalized = _normalizePlayStreamUrl(candidate.url);
        if (!_matchesActiveQuality(candidate) &&
            !_failedQualityUrls.contains(candidate.url) &&
            !_failedQualityUrls.contains(normalized)) {
          return candidate;
        }
      }
    }
    CmsEpisode? best;
    int bestRank = -1;
    for (final candidate in _qualityChoices) {
      final normalized = _normalizePlayStreamUrl(candidate.url);
      if (_matchesActiveQuality(candidate) ||
          _failedQualityUrls.contains(candidate.url) ||
          _failedQualityUrls.contains(normalized)) {
        continue;
      }
      final rank = StorageService.rankQualityVariantScore(candidate);
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
          final targetMatch = _resolveTargetLineEpisodeMatch(nextLineIdx);
          final nextEpIdx = targetMatch.matchedIndex;
          if (nextEpIdx == null) {
            continue;
          }
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
    final proxyStatus = _localMedia.current?.lastUpstreamStatusCode;
    if (proxyStatus != null && proxyStatus >= 400) {
      _lastLiveUpstreamStatus = proxyStatus;
    }
    if (!_userPausedPlayback &&
        _isLiveStream &&
        !_startup.isPastStartupWindow &&
        !_liveDirectFallbackTried) {
      _liveDirectFallbackTried = true;
      final scheme = Uri.tryParse(_activeStreamUrl)?.scheme.toLowerCase() ?? '';
      if (scheme == 'rtsp' || scheme == 'rtsps') {
        _showHud('正在切换 RTSP UDP 传输模式重试…');
        unawaited(
          _openCurrentEpisode(
            resumeMs: 0,
            preferUdpRtsp: true,
          ),
        );
        return;
      }
      final usedProxy =
          _localMedia.current != null || _activeEpisodeUsedLocalProxy;
      // Direct-first live playback on iOS/macOS/Android avoids unnecessary
      // loopback proxy copying. If direct fails (e.g. PNG-disguised TS or
      // redirect Set-Cookie), fall back once to LocalMediaLease; if proxy was
      // used first (e.g. Windows HTTPS), retry with alternate browser UA.
      final nextForceProxy = !usedProxy &&
          LocalMediaLease.shouldProxy(Uri.tryParse(_activeStreamUrl));
      final nextBypassProxy =
          usedProxy && (scheme == 'http' || !Platform.isWindows);
      _showHud(
        nextForceProxy
            ? '正在切换代理兼容模式…'
            : (nextBypassProxy ? '正在切换直连直播流…' : '正在切换兼容模式重试…'),
      );
      unawaited(
        _openCurrentEpisode(
          resumeMs: 0,
          bypassLocalProxy: nextBypassProxy,
          forceLiveLocalProxy: nextForceProxy,
          useAlternateLiveUa: true,
        ),
      );
      return;
    }
    if (!_userPausedPlayback &&
        _isLiveStream &&
        !_startup.isPastStartupWindow &&
        _currentLine.episodes.length > 1 &&
        _failedLiveEpisodes.length < 8) {
      _failedLiveEpisodes.add(_episodeIndex);
      final total = _currentLine.episodes.length;
      for (var step = 1; step < total; step++) {
        final nextIdx = (_episodeIndex + step) % total;
        if (_failedLiveEpisodes.contains(nextIdx)) continue;
        final candidate = _currentLine.episodes[nextIdx];
        final sameHeaders =
            mapEquals(candidate.headers, _currentEpisode.headers);
        if ((candidate.url == _activeStreamUrl ||
                candidate.url == _currentEpisode.url) &&
            sameHeaders) {
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
    if (!_isLiveStream &&
        !_hasVideoOutputForSession &&
        _pendingCrossSiteRollback != null &&
        _pendingCrossSiteRollback!.targetSession == _playSession) {
      final rb = _pendingCrossSiteRollback!;
      _pendingCrossSiteRollback = null;
      _restoreCrossSiteRollback(rb);
      return;
    }
    if (!_userPausedPlayback &&
        cloudError.isEmpty &&
        !_isLiveStream &&
        !_startup.isPastStartupWindow &&
        !CmsClient.needsSourceVerification(_activeSite, error)) {
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
              _enginePause();
            }
          }),
        );
        return;
      }
    }
    _clearPendingAutoStartPip();
    String? specificHeaderError;
    if (error is PlatformException &&
        (error.message ?? '').contains('请求头')) {
      specificHeaderError = error.message!.trim();
    } else if (error is String && error.contains('请求头')) {
      specificHeaderError = error.trim();
    }
    setState(() {
      _allowEvents = false;
      _allowHistory = false;
      _loading = false;
      _buffering = false;
      _playing = false;
      _controlsVisible = true;
      _hudTimer?.cancel();
      _hudText = '';
      _playbackError = cloudError.isNotEmpty
          ? cloudError
          : specificHeaderError != null
          ? specificHeaderError
          : _isLiveStream
          ? PlayerScreen.formatLivePlaybackError(
              error,
              upstreamStatusCode: _lastLiveUpstreamStatus,
            )
          : error is TimeoutException
          ? '媒体加载超时，请重试或选择其他画质'
          : '播放失败，请重试或切换线路';
      _playbackErrorCause = error;
      if (CmsClient.needsSourceVerification(_activeSite, error)) {
        _playbackError = '此片源需要完成验证码后继续播放';
      }
    });
    _enginePause();
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
    CmsEpisode? preResolvedEpisode,
    bool userSelectedQuality = false,
    bool bypassLocalProxy = false,
    bool forceLiveLocalProxy = false,
    bool useAlternateLiveUa = false,
    bool preferUdpRtsp = false,
    bool armPendingPipForThisSession = false,
    bool isAutoFallback = false,
  }) async {
    if (!isAutoFallback) {
      _iosAutoFallbackCountForOpen = 0;
    }
    _aiNonTextTrackNotifiedForSession = false;
    _userPausedPlayback = false;
    _pausedEngineInvalidated = false;
    _ohosRenderedFirstFrame = false;
    if (_hudText.startsWith('已暂停')) {
      _hudTimer?.cancel();
      _hudText = '';
    }
    _startup.reset();
    _currentEpisodePlaybackConfirmed = false;
    _confirmedPlaybackSession = -1;
    _initialHistoryRecorded = false;
    _avPendingSeekGen++;
    _avClockAnchorMs = 0;
    _avObservedPlayingMinPosMs = null;
    _avPendingSeekTargetMs = null;
    _avLastProcessedClockSeq = 0;
    _avLastProcessedClockMediaId = null;
    if (!armPendingPipForThisSession) {
      _clearPendingAutoStartPip();
      _sessionForceAvPlayerForPip = false;
    }
    if (quality == null) {
      _lastKnownPositionMs = 0;
      _lastKnownDurationMs = 0;
      final nextAiMediaKey = _currentAiSubtitleMediaKey;
      if (nextAiMediaKey != _aiOverlayMediaKey) {
        _aiOverlayMediaKey = nextAiMediaKey;
        _aiSubtitleMediaGen++;
        _aiOverlayMountGen++;
        _aiOverlayCues = const <AiSubtitleCue>[];
        _aiOverlayGlossary = const <String, String>{};
        _aiStudioDraftCues = const <AiSubtitleCue>[];
        _aiStudioDraftGlossary = const <String, String>{};
        _aiStudioDraftOffset = Duration.zero;
        _aiStudioDraftMatchesOverlay = false;
        _aiOverlayOffset = Duration.zero;
        _aiOverlayLabel = '';
        _aiLiveRawLine = '';
        _aiLiveTranslatedLine = '';
        _aiLiveTranslateGen++;
        _avConfirmedTextSubtitleTrackForSession = false;
        _avConfirmedTextSubtitleTrackId = null;
        _lastAvSelectedSubtitleTrackId = null;
        _lastAvSubtitleTrackSignature = '';
        _aiNonTextTrackNotifiedForSession = false;
        _aiSubtitleStateRevision.value++;
        _syncAvPlayerSubtitleSuppression(force: true);
      } else {
        // Switching engine/stream on the same film/episode preserves external
        // AI subtitle cues while resetting only transient live cue text.
        _aiLiveRawLine = '';
        _aiLiveTranslatedLine = '';
        _aiLiveTranslateGen++;
        _avConfirmedTextSubtitleTrackForSession = false;
        _avConfirmedTextSubtitleTrackId = null;
        _lastAvSelectedSubtitleTrackId = null;
        _aiSubtitleStateRevision.value++;
        _syncAvPlayerSubtitleSuppression(force: true);
      }
    }
    _liveSessionHasProgress = false;
    _liveStartupPhase = _LiveStartupPhase.tracksUnknown;
    _liveSessionVideoOutputCount = 0;
    _liveVoConfigured = false;
    _liveStartSpecTriggered = false;
    _videoWidth = 0;
    _videoHeight = 0;
    if (!bypassLocalProxy &&
        !forceLiveLocalProxy &&
        !useAlternateLiveUa &&
        !preferUdpRtsp) {
      _liveDirectFallbackTried = false;
      _lastLiveUpstreamStatus = null;
    }
    _skipCountdown.reset();
    _startSpecController.resetForNewSession();
    _resetDanmuForEpisode();
    _winQualityController.onMediaChanged(suspendRecoveryUntilOpen: true);
    _cancelTransientInteractions(GestureInterruptReason.episodeSwitch);
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
    if (armPendingPipForThisSession) {
      _armPendingAutoStartPip(session: session, mediaId: null);
    }
    final activePlatform = _player.platform;
    if (activePlatform is MdkPlatformPlayer) {
      activePlatform.cancelPendingOpen();
    }
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
      final previousIsoLease = _blurayIsoLease;
      final previousOfflineHlsLease = _offlineHlsLease;
      _blurayIsoLease = null;
      final previousSmbProxy = _smbStreamProxy;
      _smbStreamProxy = null;
      _offlineHlsLease = null;
      _blurayChapters = const [];
      await _playerConfiguration;
      await _changeMedia(session, () async {
        if (_usingAvPlayer) {
          await _iosAvPlayerController?.stop();
          _usingAvPlayer = false;
        }
        await _player.stop();
        await _cloudMedia.releaseUnless(qualityLease);
        await _localMedia.releaseUnless(null);
        await previousIsoLease?.close();
        await previousSmbProxy?.close();
        await previousOfflineHlsLease?.close();
      });
    } catch (_) {
      if (session == _playSession) _failPlayback();
      return;
    }
    if (!mounted || session != _playSession) return;
    final history = _isLiveStream ? null : _historyForCurrentEpisode();
    if (history != null && history.duration > 0) {
      _lastKnownDurationMs = history.duration;
    }
    final effectiveResumeMs =
        _isLiveStream ? 0 : (resumeMs ?? history?.resumePosition ?? 0);
    _intendedStartPositionMs = effectiveResumeMs > 0 ? effectiveResumeMs : 0;
    _hasVideoOutputForSession = false;
    _pendingResumeMs = _intendedStartPositionMs;
    _episodeResumeAnchorMs = _pendingResumeMs;
    _avClockAnchorMs = _pendingResumeMs;
    _avObservedPlayingMinPosMs = null;
    _avPendingSeekTargetMs = _pendingResumeMs > 0 ? _pendingResumeMs : null;
    _lastKnownPositionMs = _pendingResumeMs;
    _lastKnownDurationMs = history?.duration ?? 0;
    _currentEpisodePlaybackConfirmed = false;
    _confirmedPlaybackSession = -1;
    _introSkippedForSession = _pendingResumeMs > 0;
    _outroSkippedForSession = false;
    _initialHistoryRecorded = false;

    final savedConfig = widget.storage.loadSavedConfig();
    final configuredParses = savedConfig?.parses ?? const [];
    final configuredRules = savedConfig?.rules ?? const [];
    final configuredAds = savedConfig?.ads ?? const [];
    WebMediaResolver.defaultSniffRules = configuredRules;
    WebMediaResolver.defaultAdRules = configuredAds;
    LocalMediaLease.defaultHlsAdStripEnabled =
        widget.storage.hlsAdStripEnabled;
    final canOpenDirectly = _isLiveStream
        ? (_currentEpisode.isLocalFile ||
            const {
              'http',
              'https',
              'rtmp',
              'rtmps',
              'rtsp',
              'rtsps',
              'rtp',
              'udp',
              'mms',
              'mmsh',
              'mmst',
            }.contains(
              Uri.tryParse(_currentEpisode.url.trim())?.scheme.toLowerCase(),
            ))
        : _currentEpisode.isDirectPlayable;
    final unavailableReason = _isLiveStream
        ? (canOpenDirectly ? null : '当前直播源地址格式不受支持，请切换线路')
        : WebMediaResolver.episodeUnavailableReason(
            _currentEpisode,
            site: _activeSite,
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
        _extraTrackSpecInfo = '';
        _activeStreamUrl = _currentEpisode.url;
        _position = _pendingResumeMs > 0
            ? Duration(milliseconds: _pendingResumeMs)
            : Duration.zero;
        _syncAiSubtitleClockMs(_position.inMilliseconds);
        _duration = Duration.zero;
      });
    }

    CloudMediaLease? pendingLease;
    LocalMediaLease? pendingLocalLease;
    BlurayIsoLease? pendingBlurayLease;
    OfflineHlsLease? pendingOfflineHlsLease;
    List<BlurayChapter> pendingBlurayChapters = const [];
    try {
      var resolvedEpisode = quality ??
          preResolvedEpisode ??
          (_currentEpisode.isLocalFile
              ? _currentEpisode
              : widget.isLive
                  ? _client.resolveLiveEpisodeForPlayback(
                      _activeSite,
                      _currentEpisode,
                    )
                  : await _client
                      .runSourceOperation<CmsEpisode>(
                        () async {
                          final result =
                              await _client.resolveEpisodeForPlayback(
                            _activeSite,
                            _currentEpisode,
                            parses: configuredParses,
                            rules: configuredRules,
                            ads: configuredAds,
                          );
                          if (!mounted ||
                              session != _playSession ||
                              sourceAbort.isCompleted) {
                            await _cloudMedia.discard(
                              PlayerCloudMediaSession.of(result),
                            );
                            throw StateError('片源加载已取消');
                          }
                          return result;
                        },
                        cancellation: sourceAbort,
                      )
                      .timeout(
                        const Duration(seconds: 90),
                        onTimeout: () {
                          if (!sourceAbort.isCompleted) sourceAbort.complete();
                          throw const FormatException('片源解析超时，请重试');
                        },
                      ));
      pendingLease = PlayerCloudMediaSession.of(resolvedEpisode);
      if (quality == null && resolvedEpisode.variants.length > 1) {
        resolvedEpisode = _selectBestQualityVariant(resolvedEpisode);
      }
      if (quality != null && _activeSite.isCatPaw) {
        final logicalCatpaw = resolvedEpisode.playbackSession['catpawLogicalUrl'];
        if (logicalCatpaw is String && CatPawHost.matches(logicalCatpaw)) {
          final refreshedUri = await CatPawHost.instance.resolve(
            logicalCatpaw,
            cancellation: sourceAbort,
          );
          final refreshedUrl = refreshedUri.toString();
          if (refreshedUrl != resolvedEpisode.url) {
            final updatedVariant = CmsEpisode(
              name: resolvedEpisode.name,
              url: refreshedUrl,
              headers: resolvedEpisode.headers,
              playbackSession: resolvedEpisode.playbackSession,
              variants: resolvedEpisode.variants,
              externalAudioUrl: resolvedEpisode.externalAudioUrl,
            );
            resolvedEpisode = updatedVariant;
            _qualityChoices = [
              for (final choice in _qualityChoices)
                choice.playbackSession['catpawLogicalUrl'] == logicalCatpaw
                    ? updatedVariant
                    : choice,
            ];
          }
        }
      }
      EmbyPlaybackSession? report;
      if (_activeSite.isEmby && resolvedEpisode.playbackSession.isNotEmpty) {
        report = (await EmbyLibrary.open(_activeSite)).track(resolvedEpisode);
      }
      if (!mounted || session != _playSession) {
        report?.stop();
        await _cloudMedia.discard(pendingLease);
        return;
      }
      _embySession = report;
      if (quality == null) _qualityChoices = resolvedEpisode.variants;
      final rawResolvedUrl = resolvedEpisode.url;
      final safePlayUrl = _normalizePlayStreamUrl(rawResolvedUrl);
      final resolvedLogical = resolvedEpisode.playbackSession['catpawLogicalUrl'];
      final baseMedia = widget.mediaForPlayback(
        resolvedEpisode,
        start: _pendingResumeMs > 0
            ? Duration(milliseconds: _pendingResumeMs)
            : null,
      );
      final headers = Map<String, String>.of(baseMedia.httpHeaders ?? const {});
      if (useAlternateLiveUa) {
        headers.removeWhere((k, _) => k.toLowerCase() == 'user-agent');
        headers['User-Agent'] =
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';
      } else if (!headers.keys.any((k) => k.toLowerCase() == 'user-agent')) {
        // IPTV live sources (TVBox/Kimentanm) predominantly expect OkHttp on
        // first connect, falling back to desktop Chrome UA on retry.
        headers['User-Agent'] = _isLiveStream
            ? 'okhttp/4.12.0'
            : 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';
      }
      final parsedTargetUri = Uri.tryParse(safePlayUrl);
      _activeEpisodeUsedLocalProxy = false;
      if (!_isLiveStream &&
          pendingLease == null &&
          BlurayIsoProxy.isIsoTarget(safePlayUrl)) {
        pendingBlurayLease = await BlurayIsoProxy.open(
          target: safePlayUrl,
          headers: headers,
          isCancelled: () => !mounted || session != _playSession,
        );
        pendingBlurayChapters = pendingBlurayLease.chapters;
      } else if (_currentEpisode.isLocalFile &&
          OfflineHlsLease.isLocalM3u8(safePlayUrl)) {
        pendingOfflineHlsLease = await OfflineHlsLease.open(safePlayUrl);
      }
      final forceProxyForWindowsHttps =
          Platform.isWindows && parsedTargetUri?.scheme.toLowerCase() == 'https';
      // Live streams on iOS/macOS/Android (and HTTP everywhere) play directly
      // through libmpv first to eliminate extra loopback proxy copying & delay,
      // falling back to LocalMediaLease automatically only if direct fails.
      final preferDirectLive =
          _isLiveStream && !forceLiveLocalProxy && !forceProxyForWindowsHttps;
      if (pendingBlurayLease == null &&
          (!bypassLocalProxy && !preferDirectLive || forceProxyForWindowsHttps) &&
          pendingLease == null &&
          parsedTargetUri != null &&
          LocalMediaLease.shouldProxy(parsedTargetUri)) {
        _activeEpisodeUsedLocalProxy = true;
        final cacheLimitMb = _effectiveDiskCacheLimitMb;
        final desiredDiskCacheBytes = cacheLimitMb <= 0
            ? 0
            : cacheLimitMb * 1024 * 1024;
        if (DiskBlockCache.shared.maxBytes != desiredDiskCacheBytes) {
          await DiskBlockCache.shared.setCapacityMb(cacheLimitMb);
        }
        final effectiveAdHosts = configuredAds.isNotEmpty
            ? configuredAds
            : widget.storage.cachedAdDomains;
        pendingLocalLease = await LocalMediaLease.open(
          target: parsedTargetUri,
          headers: headers,
          isLive: _isLiveStream,
          removeHlsAds: !_isLiveStream && widget.storage.hlsAdRemovalEnabled,
          adHosts: effectiveAdHosts,
          enableDiskCache: !_isLiveStream &&
              cacheLimitMb > 0 &&
              !parsedTargetUri.path.toLowerCase().endsWith('.m3u8'),
          isCancelled: () => !mounted || session != _playSession,
        );
      }
      if (!mounted || session != _playSession) {
        report?.stop();
        await _cloudMedia.discard(pendingLease);
        await _localMedia.discard(pendingLocalLease);
        await pendingBlurayLease?.close();
        await pendingOfflineHlsLease?.close();
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
      final effectiveOpenUrl = pendingOfflineHlsLease?.url.toString() ??
          pendingBlurayLease?.url.toString() ??
          pendingLocalLease?.url.toString() ??
          safePlayUrl;
      final effectiveOpenHeaders =
          (pendingOfflineHlsLease != null ||
                  pendingBlurayLease != null ||
                  pendingLocalLease != null)
              ? const <String, String>{}
              : headers;
      _activeStreamUrl = safePlayUrl;
      _activeQualityLogicalUrl = resolvedLogical is String ? resolvedLogical : '';
      _activeMediaUri = Media(effectiveOpenUrl).uri;
      _lastAvExternalAudioUrl = effectiveAudioUrl;

      final pendingSmbRaw = resolvedEpisode.playbackSession['smbStreamProxy'];
      final pendingSmbProxy =
          pendingSmbRaw is SmbMediaStreamProxy ? pendingSmbRaw : null;
      await _changeMedia(session, () async {
        _cloudMedia.adopt(pendingLease);
        _localMedia.adopt(pendingLocalLease);
        _blurayIsoLease = pendingBlurayLease;
        _smbStreamProxy = pendingSmbProxy;
        _offlineHlsLease = pendingOfflineHlsLease;
        _blurayChapters = pendingBlurayChapters;
        _allowEvents = true;
        _winQualityController.resumeAudioFilterRecovery();
        _armStartupWatchdog(session);
        _activeResolvedMediaUrl = effectiveOpenUrl;
        _activeResolvedHeaders = Map<String, String>.from(effectiveOpenHeaders);
        if (_castController.isCasting) {
          unawaited(
            _castController.switchMedia(
              mediaUrl: effectiveOpenUrl,
              title: '$_displayTitle · ${_currentEpisode.name}',
              headers: _activeResolvedHeaders,
              totalDuration: _duration,
            ),
          );
        }

        final avCtrl = _iosAvPlayerController;
        var openedWithAvPlayer = false;
        if (_canUseIosAvPlayerEngine &&
            avCtrl != null &&
            _effectiveIosEngineMode == IosPlaybackEngineMode.avPlayer &&
            effectiveAudioUrl.isEmpty &&
            !_castController.isCasting) {
          final precheck = IosAvPlayerController.checkUrlCompatibility(
            safePlayUrl,
            episodeName: _currentEpisode.name,
            lineName: _currentLine.name,
          );
          if (precheck.supported) {
            await avCtrl.setVideoGravity(_avGravityForFit(_fit));
            final openStart = baseMedia.start ?? Duration.zero;
            _avClockAnchorMs =
                math.max(_avClockAnchorMs, openStart.inMilliseconds);
            _avObservedPlayingMinPosMs = null;
            if (openStart.inMilliseconds > 0) {
              _avPendingSeekTargetMs = math.max(
                _avPendingSeekTargetMs ?? 0,
                openStart.inMilliseconds,
              );
            }
            openedWithAvPlayer = await avCtrl.open(
              effectiveOpenUrl,
              headers: effectiveOpenHeaders,
              startPosition: openStart,
              autoPlay: !_castController.isCasting,
              episodeName: _currentEpisode.name,
              lineName: _currentLine.name,
              suppressNativeSubtitleRendering:
                  _resolveAvNativeSubtitleSuppression(avCtrl).suppress,
              suppressNativeSubtitleAllowNonText:
                  _resolveAvNativeSubtitleSuppression(avCtrl).allowNonText,
            );
          } else if (!precheck.silentFallback &&
              (precheck.reason ?? '').isNotEmpty) {
            _showHud(precheck.reason!);
          }
        }

        if (openedWithAvPlayer && avCtrl != null) {
          if (_pendingAutoStartPipSession == session) {
            _pendingAutoStartPipMediaId = avCtrl.currentMediaId;
          }
          if (mounted) {
            setState(() {
              _usingAvPlayer = true;
              _wasAvPlaying = false;
              _wasAvBuffering = false;
              _wasAvCompleted = false;
            });
          } else {
            _usingAvPlayer = true;
          }
          _syncAvPlayerSubtitleSuppression(force: true);
        } else {
          if (_pendingAutoStartPipSession == session) {
            _clearPendingAutoStartPip();
          }
          _sessionForceAvPlayerForPip = false;
          if (mounted && _usingAvPlayer) {
            setState(() => _usingAvPlayer = false);
          } else {
            _usingAvPlayer = false;
          }
          if (_isIosPlayerPlatform) {
            final wantMdk = _shouldUseIosMdkForMedia(safePlayUrl);
            await _ensureIosUnderlyingKernel(wantMdk: wantMdk);
            if (!mounted || session != _playSession) return;
          }
          await _configureMpvStreamProperties(
            effectiveOpenUrl,
            headers,
            isProxied: pendingLocalLease != null || pendingBlurayLease != null,
            preferUdpRtsp: preferUdpRtsp,
          );
          if (_isWindowsPlayerPlatform && _isLiveStream) {
            final volume = widget.storage.windowsLiveVolume;
            if (_engineVolume100 != volume) {
              await _player.setVolume(volume);
              if (!mounted || session != _playSession) return;
            }
          }
          await _player.open(
            Media(
              effectiveOpenUrl,
              httpHeaders: _isNonHttpStreamUrl(effectiveOpenUrl)
                  ? const <String, String>{}
                  : effectiveOpenHeaders,
              start: baseMedia.start,
            ),
            play: !_castController.isCasting,
          );
          if (effectiveAudioUrl.isNotEmpty) {
            await _player.setAudioTrack(AudioTrack.uri(effectiveAudioUrl));
          }
        }
      });
      if (!mounted || session != _playSession || !_allowEvents) {
        await _cloudMedia.discard(pendingLease);
        await _localMedia.discard(pendingLocalLease);
        if (!identical(_blurayIsoLease, pendingBlurayLease)) {
          await pendingBlurayLease?.close();
        }
        if (!identical(_offlineHlsLease, pendingOfflineHlsLease)) {
          await pendingOfflineHlsLease?.close();
        }
        return;
      }
      _allowHistory = true;
      await _engineSetRate(_isLiveStream ? 1.0 : _normalSpeed);
      if (!mounted || session != _playSession) return;
      _probeCurrentEpisodeContainerTags(session);
      _scheduleHide();
    } catch (error) {
      await _cloudMedia.discard(pendingLease);
      await _localMedia.discard(pendingLocalLease);
      if (!identical(_blurayIsoLease, pendingBlurayLease)) {
        await pendingBlurayLease?.close();
      }
      if (!identical(_offlineHlsLease, pendingOfflineHlsLease)) {
        await pendingOfflineHlsLease?.close();
      }
      if (mounted && session == _playSession) _failPlayback(error);
    }
  }

  static String _formatClockNow() {
    final now = DateTime.now();
    return '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
  }

  int? _confirmedAvPositionMsOrNull() =>
      _iosAvPlayerController?.confirmedPosition?.inMilliseconds;

  Future<void> _saveProgress({
    bool completed = false,
    bool immediate = false,
    bool triggerSync = true,
    bool? syncImmediate,
    bool allowUnconfirmedWithPosition = false,
  }) async {
    if (!_allowHistory ||
        _isLiveStream ||
        _activeSite.key == 'live' ||
        _activeSite.isEffectivelyPrivate) {
      return;
    }
    if (!_currentEpisodePlaybackConfirmed &&
        !(allowUnconfirmedWithPosition &&
            (_position.inMilliseconds >= 1000 ||
                _lastKnownPositionMs >= 1000))) {
      return;
    }
    final avConfirmedPosMs =
        _usingAvPlayer ? _confirmedAvPositionMsOrNull() : null;
    final avSeekInFlight = _iosAvPlayerController?.hasInFlightSeek ?? false;
    // On AVPlayer, scrubber, ±15s, and route/widget exit all share the latest
    // confirmed position resolved by `IosAvPlayerController` (never an
    // unconfirmed optimistic target).
    final livePosMs = _usingAvPlayer
        ? (avConfirmedPosMs ??
              (avSeekInFlight
                  ? _lastKnownPositionMs
                  : _position.inMilliseconds))
        : _position.inMilliseconds;
    final effectiveDurMs = _duration.inMilliseconds > 0
        ? _duration.inMilliseconds
        : _lastKnownDurationMs;
    final rawPosMs = _pendingResumeMs > 0
        ? _pendingResumeMs
        : (_usingAvPlayer && avConfirmedPosMs != null
              ? avConfirmedPosMs
              : (livePosMs >= 1000
                    ? livePosMs
                    : (_lastKnownPositionMs > 0
                          ? _lastKnownPositionMs
                          : livePosMs)));
    final effectivePosMs = completed
        ? (effectiveDurMs > 0 ? effectiveDurMs : math.max(1000, rawPosMs))
        : rawPosMs;
    if (!_currentEpisodePlaybackConfirmed &&
        effectiveDurMs <= 0 &&
        effectivePosMs <= 0) {
      return;
    }
    var resolvedPoster = _activeVideo.poster.trim();
    if (resolvedPoster.isEmpty) {
      for (final existing in widget.storage.getWatchHistory()) {
        if ((existing.site == _activeSite.key &&
                existing.id == _activeVideo.id) ||
            existing.title == _activeVideo.title) {
          if (existing.poster.trim().isNotEmpty) {
            resolvedPoster = existing.poster.trim();
            break;
          }
        }
      }
    }
    await widget.storage.upsertWatchHistory(
      WatchHistoryEntry(
        site: _activeSite.key,
        id: _activeVideo.id,
        title: _activeVideo.title,
        poster: resolvedPoster,
        line: _currentLine.name,
        lineId: _currentLine.id,
        episode: _currentEpisode.name,
        episodeMediaId: WatchHistoryEntry.mediaIdentityForUrl(_currentEpisode.url),
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

  bool get _hasActivePlayerOverlay {
    return IosLiquidGlassBridge.activeSheetNotifier.value ||
        activeIosGlassPopoverCount.value > 0 ||
        activeAppleModalSheetCount.value > 0;
  }

  void _onPlayerOverlayStateChanged() {
    if (!mounted) return;
    if (_hasActivePlayerOverlay) {
      _hideTimer?.cancel();
      _hudUnmountTimer?.cancel();
      if (_hudFadingOut || _hudAutoHidden || !_controlsVisible) {
        void restoreHud() {
          if (!mounted) return;
          setState(() {
            _hudFadingOut = false;
            _hudAutoHidden = false;
            _controlsVisible = true;
          });
        }
        if (SchedulerBinding.instance.schedulerPhase ==
            SchedulerPhase.persistentCallbacks) {
          WidgetsBinding.instance.addPostFrameCallback((_) => restoreHud());
        } else {
          restoreHud();
        }
      }
    } else if (_controlsVisible && !_screenLocked && _playing) {
      _scheduleHide();
    }
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hudUnmountTimer?.cancel();
    if (_hudFadingOut || _hudAutoHidden) {
      _hudFadingOut = false;
      _hudAutoHidden = false;
    }
    if (_screenLocked ||
        _isSliderDragging ||
        _hasActivePlayerOverlay ||
        ((isWindowsDesktopUi || _isMacosPlayerPlatform) &&
            _windowsMoreControls)) {
      return;
    }
    final hideDelay = _desktop
        ? const Duration(milliseconds: 2200)
        : const Duration(milliseconds: 3500);
    _hideTimer = Timer(hideDelay, () {
      if (mounted &&
          !_screenLocked &&
          !_isSliderDragging &&
          !_hasActivePlayerOverlay &&
          _playing &&
          !_loading &&
          !_buffering &&
          _playbackError.isEmpty) {
        setState(() => _hudFadingOut = true);
        _hudUnmountTimer?.cancel();
        _hudUnmountTimer = Timer(const Duration(milliseconds: 190), () {
          if (mounted &&
              _hudFadingOut &&
              !_screenLocked &&
              !_isSliderDragging &&
              !_hasActivePlayerOverlay &&
              _playing &&
              !_loading &&
              !_buffering &&
              _playbackError.isEmpty) {
            setState(() {
              _hudFadingOut = false;
              _hudAutoHidden = true;
              _controlsVisible = false;
            });
            _syncMobileSystemBars();
            if (_desktop) {
              _restorePlayerFocusIfCurrent();
            }
          }
        });
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
    _hudUnmountTimer?.cancel();
    _lockHideTimer?.cancel();
    if (!widget.embedded) WindowsImmersiveFrame.interactionLocked.value = locked;
    if (locked) {
      _suspendSkipCountdown();
      _globalActivePointers.clear();
      _cancelDesktopKeyScrub(showToast: false);
      if (_useEnhancedHud) {
        final events = _gestureFsm.setScreenLocked(true);
        _applyGestureEvents(events);
      }
      if (_speedBoosting) {
        _engineSetRate(_normalSpeed);
      }
      setState(() {
        _screenLocked = true;
        _controlsVisible = false;
        _hudFadingOut = false;
        _hudAutoHidden = false;
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
      _syncMobileSystemBars();
      _scheduleLockHide();
    } else {
      if (_useEnhancedHud) {
        _gestureFsm.setScreenLocked(false);
      }
      setState(() {
        _screenLocked = false;
        _lockButtonVisible = false;
        _controlsVisible = true;
      });
      if (!_playerFocusNode.hasFocus) {
        _playerFocusNode.requestFocus();
      }
      _showHud('已解锁屏幕');
      _syncMobileSystemBars();
      _scheduleHide();
      _maybeEvaluateSkipTriggers();
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
    _hideTimer?.cancel();
    _hudUnmountTimer?.cancel();
    if (_usesDesktopSubtitleHudLayout) {
      if (_controlsVisible && !_hudFadingOut) {
        final reduceMotion = MediaQuery.disableAnimationsOf(context);
        if (reduceMotion) {
          setState(() {
            _hudFadingOut = false;
            _hudAutoHidden = true;
            _controlsVisible = false;
          });
          _syncMobileSystemBars();
          if (_desktop) _restorePlayerFocusIfCurrent();
          return;
        }
        // Match the auto-hide fade-out state machine so bottom subtitles stay
        // lifted throughout the 180ms fade-out and only return to the bottom
        // baseline after the bottom controls have completely faded & unmounted.
        setState(() {
          _hudFadingOut = true;
          _hudAutoHidden = false;
        });
        _hudUnmountTimer = Timer(const Duration(milliseconds: 190), () {
          if (mounted &&
              _hudFadingOut &&
              !_screenLocked &&
              !_isSliderDragging &&
              !_hasActivePlayerOverlay) {
            setState(() {
              _hudFadingOut = false;
              _hudAutoHidden = true;
              _controlsVisible = false;
            });
            _syncMobileSystemBars();
            if (_desktop) {
              _restorePlayerFocusIfCurrent();
            }
          }
        });
        return;
      }
      setState(() {
        _hudFadingOut = false;
        _hudAutoHidden = false;
        _controlsVisible = true;
      });
      _syncMobileSystemBars();
      _scheduleHide();
      return;
    }
    setState(() {
      _hudFadingOut = false;
      _hudAutoHidden = false;
      _controlsVisible = !_controlsVisible;
    });
    _syncMobileSystemBars();
    if (_controlsVisible) _scheduleHide();
  }

  void _onPointerMove(Offset delta) {
    final dist = delta.distance;
    if (!_desktop || dist <= 0.001) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final hidden = _screenLocked
        ? !_lockButtonVisible
        : (!_controlsVisible || _hudFadingOut);
    if (hidden) {
      if (_pointerWakeWindowStartMs == 0 ||
          now - _pointerWakeLastEventMs > 350 ||
          now - _pointerWakeWindowStartMs > 350) {
        _pointerWakeWindowStartMs = now;
        _pointerWakeAccumulatedPx = 0;
      }
      _pointerWakeLastEventMs = now;
      _pointerWakeAccumulatedPx += dist;
      if (_pointerWakeAccumulatedPx < 12.0) return;
      _pointerWakeAccumulatedPx = 0;
      _pointerWakeWindowStartMs = 0;
      _pointerWakeLastEventMs = 0;
    } else {
      _pointerVisibleAccumulatedPx += dist;
      if (_pointerVisibleAccumulatedPx < 2.0) return;
      _pointerVisibleAccumulatedPx = 0;
    }
    if (_screenLocked) {
      if (!_lockButtonVisible) {
        setState(() => _lockButtonVisible = true);
        _lastPointerScheduleMs = now;
        _restorePlayerFocusIfCurrent();
        _scheduleLockHide();
        return;
      }
      if (now - _lastPointerScheduleMs >= 250) {
        _lastPointerScheduleMs = now;
        _scheduleLockHide();
      }
      return;
    }
    if (!_controlsVisible || _hudFadingOut) {
      _hudUnmountTimer?.cancel();
      setState(() {
        _hudFadingOut = false;
        _hudAutoHidden = false;
        _controlsVisible = true;
      });
      _lastPointerScheduleMs = now;
      _restorePlayerFocusIfCurrent();
      _scheduleHide();
      return;
    }
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

  void _exitPlayer() {
    _cancelTransientInteractions(GestureInterruptReason.backExit);
    if (widget.embedded) { widget.onEmbeddedClose?.call(); }
    else { Navigator.of(context).maybePop(); }
  }

  Future<void> _desktopEscape() async {
    if (widget.embedded) { _exitPlayer(); return; }
    try {
      final exited = await _desktopWindow!.exitFullscreen();
      if (!exited) {
        await _saveProgress(immediate: true);
        if (mounted) _exitPlayer();
      }
    } catch (error) {
      _windowError(error);
    }
  }

  void _onCastStateChanged() {
    if (mounted) setState(() {});
  }

  void _handlePhysicalOrientation(String orientation) {
    if (!mounted || _screenLocked || _desktop || widget.embedded) return;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (nowMs - _lastManualOrientationMs < 2400) return;
    final size = MediaQuery.maybeSizeOf(context);
    if (size == null) return;
    final currentlyLandscape = size.width > size.height;
    final isIos = _isIosPlayerPlatform;
    if ((orientation == 'landscapeLeft' || orientation == 'landscapeRight') &&
        !currentlyLandscape) {
      if (isIos) {
        unawaited(_mobileChrome.setOrientation(true));
        _syncMobileSystemBars(force: true);
      } else {
        unawaited(_mobileChrome.setLandscape(true));
      }
    } else if (orientation == 'portrait' && currentlyLandscape) {
      if (isIos) {
        unawaited(_mobileChrome.setOrientation(false));
        _syncMobileSystemBars(force: true);
      } else {
        unawaited(_mobileChrome.setLandscape(false));
      }
    }
  }

  EmbeddedPlaybackState _currentEmbeddedPlaybackState() {
    final currentChannel = _activeLiveChannel ?? widget.initialLiveChannel;
    final currentEpisodes = _currentLine.episodes;
    final safeEpisodeIdx = currentEpisodes.isEmpty
        ? 0
        : _episodeIndex.clamp(0, currentEpisodes.length - 1);
    return EmbeddedPlaybackState(
      liveChannel: currentChannel,
      lineIndex: _lineIndex,
      episodeIndex: safeEpisodeIdx,
      positionMs: _position.inMilliseconds,
    );
  }

  Future<void> _toggleOrientation() async {
    if (widget.embedded) {
      if (widget.onEmbeddedExpandWithState != null) {
        widget.onEmbeddedExpandWithState!(_currentEmbeddedPlaybackState());
      } else {
        widget.onEmbeddedExpand?.call();
      }
      return;
    }
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
    final isIos = _isIosPlayerPlatform;
    _lastManualOrientationMs = DateTime.now().millisecondsSinceEpoch;
    try {
      if (isIos) {
        final wantLandscape = !currentlyLandscape;
        _pendingIosOrientationFeedback = (
          wantLandscape: wantLandscape,
          expiresAtMs: DateTime.now().millisecondsSinceEpoch + 900,
        );
        final applied = await _mobileChrome.setOrientation(wantLandscape);
        if (!mounted) return;
        _syncMobileSystemBars(force: true);
        if (!applied) {
          _pendingIosOrientationFeedback = null;
          return;
        }
        // Only show orientation-changed feedback if the actual window geometry
        // changed (checked here and on subsequent `didChangeMetrics`). In iPad
        // Split View / Stage Manager where iPadOS ignores rotation requests,
        // never display a false "已切换为全屏横屏观看" banner.
        final afterSize = MediaQuery.maybeSizeOf(context);
        if (afterSize != null &&
            (afterSize.width > afterSize.height) == wantLandscape) {
          _pendingIosOrientationFeedback = null;
          _showHud(wantLandscape ? '已切换为全屏横屏观看' : '已切换为竖屏观看');
        }
        _scheduleHide();
        return;
      }
      final applied = await _mobileChrome.setLandscape(!currentlyLandscape);
      if (!mounted) return;
      if (!applied) return;
      _showHud(currentlyLandscape ? '已切换为竖屏观看' : '已切换为全屏横屏观看');
      _scheduleHide();
    } catch (error) {
      _pendingIosOrientationFeedback = null;
      _windowError(error);
    }
  }

  void _handleCastTap(Rect? anchorRect) {
    _cancelTransientInteractions(GestureInterruptReason.dialogOpened);
    final castUrl = _activeResolvedMediaUrl.isNotEmpty
        ? _activeResolvedMediaUrl
        : _currentEpisode.url;
    unawaited(
      showIosCastPopover(
        context: context,
        anchorRect: anchorRect,
        controller: _castController,
        isAirPlayActive: _iosAvPlayerController?.isAirPlayActive ?? false,
        airPlayDeviceName: _iosAvPlayerController?.airPlayDeviceName,
        onOpenAirPlayPicker: _isIosPlayerPlatform
            ? () => (_iosAvPlayerController?.presentAirPlayPicker() ??
                  IosLiquidGlassBridge.presentAirPlayPicker())
            : null,
        onSelectDevice: (device) async {
          if (castUrl.isEmpty) {
            _showHud('当前视频流尚未就绪，请稍后再试');
            return;
          }
          await _enginePause();
          final ok = await _castController.castToDevice(
            device: device,
            mediaUrl: castUrl,
            title: '${_activeVideo.title} · ${_currentEpisode.name}',
            headers: _activeResolvedHeaders,
            initialPosition: _position,
            totalDuration: _duration,
          );
          if (!mounted) return;
          if (!ok) {
            _showHud(_castController.statusMessage ?? '投屏连接失败');
          }
        },
      ),
    );
  }

  Future<void> _handleExitCast() async {
    final resumePos = _castController.position;
    await _castController.stopCasting();
    if (!mounted) return;
    if (resumePos > Duration.zero) {
      _seekPlayer(resumePos);
    }
    await _enginePlay();
    _showHud('已退出投屏，恢复本机播放');
  }

  Future<void> _handleFavoriteTap(Rect? anchorRect) async {
    final next = await widget.storage.toggleFavorite(_activeSite, _activeVideo);
    if (!mounted) return;
    setState(() => _isFavorite = next);
    if (next) {
      unawaited(
        FavoritePostcardFlightOverlay.show(
          context,
          title: _activeVideo.title,
          posterUrl: _activeVideo.poster,
          year: _activeVideo.year,
          originRect: anchorRect,
          isPrivate: _isPrivateBackdrop,
        ),
      );
    } else {
      _showHud('已取消收藏');
    }
  }

  void _handleDownloadTap(Rect? anchorRect) {
    if (_isLiveStream) return;
    if (_activeSite.isEffectivelyPrivate ||
        widget.site.isEffectivelyPrivate ||
        AiService.instance.isPrivacySessionActive) {
      _showHud('隐私分组暂不支持离线下载');
      return;
    }
    _cancelTransientInteractions(GestureInterruptReason.dialogOpened);
    final parses = widget.storage.loadSavedConfig()?.parses ?? const [];
    final line = _currentLine;
    final currentEp = _currentEpisode;
    final existingCurrent = DownloadService.instance.taskFor(
      _activeSite.key,
      _activeVideo.id,
      line.name,
      _episodeIndex,
    );

    unawaited(
      showIosGlassPopover<void>(
        context: context,
        anchorRect: anchorRect,
        title: '离线下载 · ${line.name}',
        maxWidth: 300,
        maxHeight: 310,
        forceDark: true,
        builder: (ctx) {
          return SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                GestureDetector(
                  key: const Key('ios-download-current-episode'),
                  onTap: () {
                    HapticFeedback.lightImpact();
                    final added = DownloadService.instance.enqueue(
                      site: _activeSite,
                      video: _activeVideo,
                      line: line,
                      episodeIndexes: [_episodeIndex],
                      parses: parses,
                    );
                    Navigator.of(ctx).pop();
                    _showHud(
                      added > 0
                          ? '已加入下载队列：${currentEp.name}'
                          : '已在下载队列中：${currentEp.name}',
                    );
                    setState(() {});
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: AppleColors.systemBlue.withValues(alpha: 0.22),
                      borderRadius: BorderRadius.circular(13),
                      border: Border.all(
                        color: AppleColors.systemBlue.withValues(alpha: 0.5),
                        width: 0.8,
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          existingCurrent?.status == DownloadStatus.completed
                              ? CupertinoIcons.checkmark_circle_fill
                              : CupertinoIcons.arrow_down_circle_fill,
                          color: existingCurrent?.status == DownloadStatus.completed
                              ? AppleColors.systemGreen
                              : AppleColors.systemBlue,
                          size: 18,
                        ),
                        const SizedBox(width: 9),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                existingCurrent?.status == DownloadStatus.completed
                                    ? '当前集已下载'
                                    : '下载当前集',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              Text(
                                currentEp.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white60,
                                  fontSize: 11,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (line.episodes.length > 1) ...[
                  const SizedBox(height: 10),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 2),
                    child: Text(
                      '点选剧集加入缓存',
                      style: TextStyle(
                        color: Colors.white54,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (var i = 0; i < math.min(line.episodes.length, 30); i++)
                        GestureDetector(
                          onTap: () {
                            HapticFeedback.selectionClick();
                            final added = DownloadService.instance.enqueue(
                              site: _activeSite,
                              video: _activeVideo,
                              line: line,
                              episodeIndexes: [i],
                              parses: parses,
                            );
                            Navigator.of(ctx).pop();
                            _showHud(
                              added > 0
                                  ? '已加入下载：${line.episodes[i].name}'
                                  : '已在下载列表：${line.episodes[i].name}',
                            );
                            setState(() {});
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 9,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color: i == _episodeIndex
                                  ? AppleColors.systemBlue.withValues(alpha: 0.25)
                                  : Colors.white.withValues(alpha: 0.08),
                              borderRadius: BorderRadius.circular(9),
                              border: Border.all(
                                color: Colors.white.withValues(alpha: 0.12),
                                width: 0.7,
                              ),
                            ),
                            child: Text(
                              line.episodes[i].name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }

  List<LiveChannel> get _allLiveCatalogChannels => [
    for (final g in widget.liveGroups)
      for (final ch in g.channels)
        if (ch.episodes.isNotEmpty) ch,
  ];

  bool get _canStepLiveChannel =>
      _hasLiveChannelCatalog && _allLiveCatalogChannels.length > 1;

  void _stepLiveChannel(int delta) {
    if (!mounted || !_hasLiveChannelCatalog || delta == 0) return;
    final channels = _allLiveCatalogChannels;
    if (channels.length <= 1) return;
    final active = _activeLiveChannel;
    var currentIdx = -1;
    if (active != null) {
      currentIdx = channels.indexWhere((ch) => identical(ch, active));
      if (currentIdx < 0) {
        currentIdx = channels.indexWhere(
          (ch) => ch.name == active.name && ch.group == active.group,
        );
      }
    }
    if (currentIdx < 0) {
      currentIdx = channels.indexWhere(
        (ch) => ch.name == _displayTitle && ch.group == _currentLine.name,
      );
    }
    if (currentIdx < 0) {
      currentIdx = 0;
    }
    final nextIdx = (currentIdx + delta) % channels.length;
    final safeNext = nextIdx < 0 ? nextIdx + channels.length : nextIdx;
    _switchLiveChannel(channels[safeNext], lineIdx: 0);
  }

  void _stepEpisode(int delta) {
    final next = _adjacentVisibleEpisodeIndex(delta);
    if (next == null || next < 0 || next >= _currentLine.episodes.length) {
      return;
    }
    _userNavigationGen++;
    _saveProgress(immediate: true, syncImmediate: false);
    _failedLinesForEpisode.clear();
    _failedLiveEpisodes.clear();
    setState(() => _episodeIndex = next);
    _openCurrentEpisode(resumeMs: 0);
  }

  void _seekRelative(int seconds) {
    if (_duration.inMilliseconds <= 0) return;
    final avCtrl = _usingAvPlayer ? _iosAvPlayerController : null;
    final baseMs = (avCtrl != null && !avCtrl.hasInFlightSeek)
        ? (avCtrl.confirmedPosition?.inMilliseconds ?? _position.inMilliseconds)
        : _position.inMilliseconds;
    final targetMs = (baseMs + seconds * 1000).clamp(
      0,
      _duration.inMilliseconds,
    );
    setState(() => _position = Duration(milliseconds: targetMs));
    _seekPlayer(
      Duration(milliseconds: targetMs),
      saveProgressOnSuccess: true,
    );
    _showHud(
      '${seconds >= 0 ? "快进" : "快退"} ${_formatDuration(Duration(milliseconds: targetMs))}',
    );
    _scheduleHide();
  }

  void _showHud(String text, {bool persistent = false}) {
    if (!mounted) return;
    _hudTimer?.cancel();
    setState(() => _hudText = text);
    if (persistent) return;
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
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
      return kernel == 'ijk' ? 'd3d11va-copy' : 'auto-safe';
    }
    if (!kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.iOS ||
            defaultTargetPlatform == TargetPlatform.macOS)) {
      return kernel == 'ijk' ? 'videotoolbox-copy' : 'videotoolbox';
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
      final platform = _player.platform;
      if (platform is MdkPlatformPlayer) {
        platform.applyKernelStrategy(kernel, isLive: _isLiveStream);
        await platform.setProperty('tls-verify', _isLiveStream ? 'no' : 'yes');
        return;
      }
      final dyn = platform as dynamic;
      await dyn.setProperty('tls-verify', _isLiveStream ? 'no' : 'yes');
      await dyn.setProperty('hwdec', _hardwareDecoder(kernel));
      await dyn.setProperty('cache-on-disk', 'no');
      await dyn.setProperty('cache-pause', 'yes');
      await dyn.setProperty('cache-pause-initial', 'no');
      await dyn.setProperty(
        'cache-pause-wait',
        _isLiveStream ? '1' : (kernel == 'mpv' ? '5' : '4'),
      );
      if (_isWindowsPlayerPlatform) {
        await dyn.setProperty('vd-lavc-threads', '0');
        await dyn.setProperty('vd-lavc-dr', 'yes');
        if (_winQualityController.isAvailableForPlayer(_player)) {
          await _winQualityController.loadSaved();
          final anime4kActive =
              _anime4kController.isAvailableForPlayer(_player) &&
              _anime4kController.preset != Anime4kPreset.off;
          await _winQualityController.applyAll(
            _player,
            anime4kActive: anime4kActive,
            playerKernel: kernel,
          );
        }
        if (_anime4kController.isAvailableForPlayer(_player) &&
            _anime4kController.preset != Anime4kPreset.off) {
          await _anime4kController.reapplyActivePreset(_player);
        }
      }
      await dyn.setProperty('vid', 'auto');
      await dyn.setProperty('audio-display', 'no');
      if (_isMacosPlayerPlatform) {
        // Keep libass prepared on macOS so embedded ASS fonts load on file open
        // and `sub-pos` can shift bottom ASS/PGS subtitles without moving top
        // signs. Windows mpv and iOS mpv keep their original subtitle config.
        await dyn.setProperty('sub-ass', 'yes');
        await dyn.setProperty('sub-ass-override', 'yes');
        await dyn.setProperty('sub-pos', '$_lastAppliedMpvSubPos');
        _mpvSubtitleAssInitialized = true;
      }
      if (_isIosPlayerPlatform) {
        final bool iosLowPowerThermal =
            IosMpvProfile.shouldUseLowPowerThermalMode(
          avThermalState: _iosAvPlayerController?.thermalState,
          bridgeThermalElevated: IosLiquidGlassBridge.thermalElevated,
          iosMajorVersion: IosLiquidGlassBridge.majorVersion,
        );
        _lastAppliedIosMpvLowPowerThermal = iosLowPowerThermal;
        await IosMpvProfile.applyToPlayer(
          _player,
          physicalMemoryBytes:
              _avPhysicalMemoryBytes ?? _iosAvPlayerController?.physicalMemoryBytes,
          largeBuffer: _iosLargeBuffer || kernel == 'mpv',
          isLive: _isLiveStream,
          hdrToneMapping: _iosHdrToneMapping,
          vocalLoudness: _vocalLoudness,
          hwdec: _hardwareDecoder(kernel),
          lowPowerThermalMode: iosLowPowerThermal,
        );
      } else if (!_isWindowsPlayerPlatform &&
          _vocalLoudness != VocalLoudnessPreset.off) {
        await IosMpvProfile.applyVocalLoudness(_player, _vocalLoudness);
      }
      if (_isLiveStream) {
        // Live-tuned libmpv profile: lean 16 MiB/4 MiB ring buffer, fast
        // stream-layer reconnect + tolerant live TLS, 1s/1MB probe, and smooth
        // hardware frame queueing for instant channel zapping.
        await dyn.setProperty('cache', 'yes');
        await dyn.setProperty('stream-buffer-size', '4MiB');
        await dyn.setProperty('demuxer-lavf-buffersize', '4194304');
        await dyn.setProperty('demuxer-max-bytes', '16777216');
        await dyn.setProperty('demuxer-max-back-bytes', '4194304');
        await dyn.setProperty('demuxer-readahead-secs', '5');
        await dyn.setProperty('hwdec-extra-frames', '8');
        await dyn.setProperty('vd-lavc-fast', 'yes');
        await dyn.setProperty('network-timeout', '10');
        await dyn.setProperty(
          'stream-lavf-o',
          'tls_verify=0,reconnect=1,reconnect_streamed=1,reconnect_on_network_error=1,reconnect_delay_max=2',
        );
        await dyn.setProperty(
          'demuxer-lavf-o',
          '$_baseLavfOptions,tls_verify=0,reconnect=1,reconnect_streamed=1,reconnect_on_network_error=1,reconnect_delay_max=2,analyzeduration=1000000,probesize=1000000',
        );
        return;
      }
      switch (kernel) {
        case 'ijk':
          await dyn.setProperty('cache', 'yes');
          if (!_isIosPlayerPlatform) {
            await dyn.setProperty(
              'demuxer-max-bytes',
              _desktop ? '134217728' : '67108864',
            );
            await dyn.setProperty(
              'demuxer-max-back-bytes',
              _desktop ? '33554432' : '16777216',
            );
            await dyn.setProperty('demuxer-readahead-secs', '30');
          }
          await dyn.setProperty('network-timeout', '25');
          await dyn.setProperty(
            'demuxer-lavf-o',
            '$_baseLavfOptions,reconnect=1,reconnect_delay_max=5,analyzeduration=2000000,probesize=2000000',
          );
          break;
        case 'mpv':
          await dyn.setProperty('cache', 'yes');
          if (!_isIosPlayerPlatform) {
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
          }
          await dyn.setProperty('network-timeout', '25');
          await dyn.setProperty(
            'demuxer-lavf-o',
            '$_baseLavfOptions,reconnect=1,reconnect_delay_max=4',
          );
          break;
        case 'exo':
        default:
          await dyn.setProperty('cache', 'yes');
          if (!_isIosPlayerPlatform) {
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
          }
          await dyn.setProperty('network-timeout', '20');
          await dyn.setProperty(
            'demuxer-lavf-o',
            '$_baseLavfOptions,reconnect=1,reconnect_delay_max=4',
          );
          break;
      }
    } catch (_) {}
  }

  CmsEpisode _selectBestQualityVariant(CmsEpisode resolved) {
    if (resolved.variants.isEmpty) return resolved;
    final orderedVariants = widget.storage.orderQualityVariants(
      resolved.variants,
    );
    if (widget.storage.preferredQuality == 'default') {
      return resolved;
    }
    final best = orderedVariants.first;
    if (best.url == resolved.url) {
      return CmsEpisode(
        name: resolved.name,
        url: resolved.url,
        headers: resolved.headers,
        variants: orderedVariants,
        externalAudioUrl: resolved.externalAudioUrl,
        playbackSession: resolved.playbackSession,
      );
    }
    return CmsEpisode(
      name: resolved.name,
      url: best.url,
      headers: best.headers,
      variants: orderedVariants,
      externalAudioUrl: best.externalAudioUrl.isNotEmpty
          ? best.externalAudioUrl
          : resolved.externalAudioUrl,
      playbackSession: {
        ...resolved.playbackSession,
        ...best.playbackSession,
      },
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
    _releaseRootTabSuppression?.call();
    _releaseRootTabSuppression = null;
    WindowsTrayService.hideToTrayRevision.removeListener(_onHideToTray);
    WindowsTrayService.unregisterBeforeExitHook(_prepareForWindowExit);
    if (!widget.embedded) WindowsImmersiveFrame.interactionLocked.value = false;
    if (_windowsDarkSurfaceApplied) {
      _windowsDarkSurfaceApplied = false;
      scheduleMicrotask(() {
        final next = WindowsImmersiveFrame.darkSurfaceDepth.value - 1;
        WindowsImmersiveFrame.darkSurfaceDepth.value = next < 0 ? 0 : next;
      });
    }
    if (!OhosRuntime.isOhos && defaultTargetPlatform == TargetPlatform.iOS) {
      unawaited(IosLiquidGlassBridge.dismissActiveSheets());
    }
    _lockHideTimer?.cancel();
    _hudTimer?.cancel();
    _gestureTickTimer?.cancel();
    _desktopKeyTickTimer?.cancel();
    _verticalHudClearTimer?.cancel();
    _clearPendingAutoStartPip();
    _liveCompanionGroupNotifier.dispose();
    _liveCompanionQueryNotifier.dispose();
    _liveCompanionSearchCtrl.dispose();
    if (_isIosPlayerPlatform) {
      unawaited(
        _iosAvPlayerController?.detachSystemVolume() ??
            IosAvPlayerController.detachDefaultSystemVolume(),
      );
    }
    IosLiquidGlassBridge.reduceTransparencyNotifier.removeListener(
      _onReduceTransparencyChanged,
    );
    GlassworkBackdrop.reduceTransparency.removeListener(
      _onReduceTransparencyChanged,
    );
    GlassworkBackdrop.intensity.removeListener(_onReduceTransparencyChanged);
    IosLiquidGlassBridge.activeSheetNotifier.removeListener(
      _onPlayerOverlayStateChanged,
    );
    IosLiquidGlassBridge.thermalThrottledNotifier.removeListener(
      _onIosThermalPressureChanged,
    );
    IosLiquidGlassBridge.thermalLevelNotifier.removeListener(
      _onIosThermalPressureChanged,
    );
    activeIosGlassPopoverCount.removeListener(_onPlayerOverlayStateChanged);
    activeAppleModalSheetCount.removeListener(_onPlayerOverlayStateChanged);
    _hudPrefs.removeListener(_onHudSubstateChanged);
    if (_ownsHudPrefs) {
      _hudPrefs.dispose();
    }
    _sleepTimer.removeListener(_onHudSubstateChanged);
    _sleepTimer.dispose();
    _danmuPositionMs.dispose();
    _skipCountdown.removeListener(_onHudSubstateChanged);
    _skipCountdown.dispose();
    _startSpecController.removeListener(_onHudSubstateChanged);
    _startSpecController.dispose();
    widget.storage.seriesScrapeRevision.removeListener(
      _onPlayerSeriesScrapeRevision,
    );
    if (!OhosRuntime.isOhos) {
      widget.storage.danmuSourcesRevision.removeListener(
        _onDanmuSourcesRevisionChanged,
      );
    }
    _castController.removeListener(_onCastStateChanged);
    _castController.dispose();
    _danmuMatchToken?.cancel();
    _danmuMatchToken = null;
    for (final oldCache in List<DanmuSegmentCache>.of(
      _deferredDisposedDanmuCaches,
    )) {
      if (!oldCache.isDisposed) {
        oldCache.dispose();
      }
    }
    _deferredDisposedDanmuCaches.clear();
    final activeDanmuCache = _danmuCache;
    _danmuCache = null;
    if (activeDanmuCache != null && !activeDanmuCache.isDisposed) {
      activeDanmuCache.dispose();
    }
    final activeDanmuProvider = _danmuProvider;
    final ownsDanmuProvider = _ownsDanmuProvider;
    _danmuProvider = null;
    _ownsDanmuProvider = false;
    if (ownsDanmuProvider && activeDanmuProvider is DandanplayProvider) {
      activeDanmuProvider.close();
    }
    _anime4kController.removeListener(_onHudSubstateChanged);
    final anime4kController = _anime4kController;
    final ownsAnime4kController = _ownsAnime4kController;
    final embyStopPosMs = _usingAvPlayer
        ? (_confirmedAvPositionMsOrNull() ?? _lastKnownPositionMs)
        : _position.inMilliseconds;
    // Save confirmed playback progress BEFORE detaching `_iosAvPlayerController`
    // so exit-before-seek-reply always reads the live confirmed native clock.
    _saveProgress(immediate: true);
    for (final sub in _iosAvSubscriptions) {
      unawaited(sub.cancel());
    }
    _iosAvSubscriptions.clear();
    final iosAvPlayerController = _iosAvPlayerController;
    _iosAvPlayerController = null;
    iosAvPlayerController?.removeListener(_onIosAvPlayerChanged);
    _winQualityController.removeListener(_onHudSubstateChanged);
    _winQualityController.detachPlayer();
    if (_ownsWinQualityController) {
      _winQualityController.dispose();
    }
    _detachLiveVideoOutputObservers();
    for (final sub in _playerSubscriptions) {
      unawaited(sub.cancel());
    }
    _playerSubscriptions.clear();
    _playerFocusScopeNode.dispose();
    _playerFocusNode.dispose();
    _desktopSliderFocusNode.dispose();
    _portraitToolsScrollController.dispose();
    _startup.cancel();
    _midPlaybackStallTimer?.cancel();
    PlaybackWakelock.setEnabled(false);
    if (_sourceAbort?.isCompleted == false) _sourceAbort!.complete();
    if (_crossSiteAbort?.isCompleted == false) _crossSiteAbort!.complete();
    WidgetsBinding.instance.removeObserver(this);
    _hideTimer?.cancel();
    _hudUnmountTimer?.cancel();
    _historyTimer?.cancel();
    _clockTimer?.cancel();
    widget.storage.flushPendingHistory();
    widget.storage.scheduleAutoWebdavSync(immediate: true);
    _embySession?.stop(embyStopPosMs);
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
    final blurayIsoLease = _blurayIsoLease;
    final offlineHlsLease = _offlineHlsLease;
    _blurayIsoLease = null;
    final smbStreamProxy = _smbStreamProxy;
    _smbStreamProxy = null;
    _offlineHlsLease = null;
    _blurayChapters = const [];
    final disposingPlatform = _player.platform;
    if (disposingPlatform is MdkPlatformPlayer) {
      disposingPlatform.cancelPendingOpen();
    }
    _aiSubtitleClockMsNotifier.dispose();
    _aiSubtitleStateRevision.dispose();
    final playerAtDispose = _player;
    _mediaChanges.whenComplete(() async {
      try {
        try {
          if (!OhosRuntime.isOhos &&
              (anime4kController.isAvailableForPlayer(_player) ||
                  anime4kController.isIosLightweightAvailableForPlayer(
                    _player,
                  ))) {
            await anime4kController.resetSession(_player);
          }
        } catch (_) {
        } finally {
          if (ownsAnime4kController) {
            anime4kController.dispose();
          }
        }
        if (iosAvPlayerController != null) {
          try {
            await iosAvPlayerController.setSuppressNativeSubtitleRendering(
              false,
              force: true,
            );
          } catch (_) {}
          if (widget.debugIosAvPlayerController == null) {
            try {
              await iosAvPlayerController.stop();
            } catch (_) {}
            iosAvPlayerController.dispose();
          }
        }
        if (!_playerDisposed &&
            !(_isWindowsExitHookHost &&
                WindowsTrayService.isNativeDestroyStarted)) {
          _playerDisposed = true;
          await _player.dispose();
          if (!identical(playerAtDispose, _player)) {
            try {
              await playerAtDispose.dispose();
            } catch (_) {}
          }
        }
      } finally {
        try {
          await cloudLease?.close();
        } finally {
          try {
            await localLease?.close();
          } finally {
            try {
              await blurayIsoLease?.close();
            } finally {
              try {
                await smbStreamProxy?.close();
                await offlineHlsLease?.close();
              } finally {
                releaseSource?.call();
              }
            }
          }
        }
      }
    });
    super.dispose();
  }

  void _applyGestureEvents(List<TouchGestureEvent> events) {
    if (!mounted || events.isEmpty) return;
    for (final event in events) {
      switch (event) {
        case ToggleControlsEvent():
          _toggleControls();
        case ToggleLockedControlsEvent():
          _onLockedSurfaceTap();
        case TogglePlayPauseEvent():
          if (_playing && _gestureFsm.isSpeedLocked) {
            final unlock = _gestureFsm.cancel(
              GestureInterruptReason.playbackPaused,
            );
            _applyGestureEvents(unlock);
          }
          _enginePlayOrPause();
          setState(() => _controlsVisible = true);
          _scheduleHide();
        case ToggleFullscreenEvent():
          unawaited(_toggleOrientation());
        case DoubleTapSeekEvent():
          final effectiveDurMs = _duration.inMilliseconds > 0
              ? _duration.inMilliseconds
              : _lastKnownDurationMs;
          if (effectiveDurMs > 0) {
            final targetMs =
                (_position.inMilliseconds + event.deltaSec * 1000)
                    .clamp(0, effectiveDurMs);
            setState(() => _position = Duration(milliseconds: targetMs));
            _seekPlayer(
              Duration(milliseconds: targetMs),
              saveProgressOnSuccess: true,
            );
            final sign = event.totalAccumulatedSec >= 0 ? '+' : '';
            _showHud(
              '${event.totalAccumulatedSec >= 0 ? "快进" : "快退"} $sign${event.totalAccumulatedSec}s · ${_formatDuration(Duration(milliseconds: targetMs))}',
            );
          }
        case MultiTapSeekEndEvent():
          break;
        case HorizontalSeekStartEvent():
          setState(() {
            _isDraggingSeek = true;
            _dragTargetPosMs = event.startPositionMs;
          });
        case HorizontalSeekUpdateEvent():
          final effectiveDur = _duration.inMilliseconds > 0
              ? _duration
              : Duration(milliseconds: _lastKnownDurationMs);
          setState(() {
            _isDraggingSeek = true;
            _dragTargetPosMs = event.previewPositionMs;
            _hudText =
                '${event.deltaMs >= 0 ? "快进至" : "快退至"} ${_formatDuration(Duration(milliseconds: event.previewPositionMs))} / ${_formatDuration(effectiveDur)}';
          });
        case HorizontalSeekCommitEvent():
          final effectiveDurMs = _duration.inMilliseconds > 0
              ? _duration.inMilliseconds
              : _lastKnownDurationMs;
          final targetMs = effectiveDurMs > 0
              ? event.targetPositionMs.clamp(0, effectiveDurMs)
              : event.targetPositionMs;
          setState(() {
            _isDraggingSeek = false;
            _position = Duration(milliseconds: targetMs);
            _hudText = '';
          });
          _seekPlayer(
            Duration(milliseconds: targetMs),
            saveProgressOnSuccess: true,
          );
          _scheduleHide();
        case HorizontalSeekCancelEvent():
          setState(() {
            _isDraggingSeek = false;
            _hudText = '';
          });
        case VerticalBrightnessUpdateEvent():
          _verticalHudClearTimer?.cancel();
          setState(() {
            _isVerticalDragging = true;
            _isDraggingLeftBrightness = true;
            _playerBrightness = event.brightness;
            _hudText = '亮度 ${(event.brightness * 100).round()}%';
          });
        case VerticalBrightnessEndEvent():
          _isVerticalDragging = false;
          _scheduleVerticalHudClear();
        case VerticalVolumeUpdateEvent():
          _verticalHudClearTimer?.cancel();
          if (_isIosPlayerPlatform) {
            if (!_iosDeviceVolumeSynced) {
              _iosPendingVolumeDragActive = true;
              _iosPendingVolumeDragDelta = event.delta;
              unawaited(_primeIosSystemVolume());
              setState(() {
                _isVerticalDragging = true;
                _isDraggingLeftBrightness = false;
                _hudText = '正在同步设备音量…';
              });
            } else {
              final baseline = _iosFsmVolumeBaseline;
              final nextRatio = baseline != null
                  ? (baseline + event.delta).clamp(0.0, 1.0)
                  : event.volume.clamp(0.0, 1.0);
              _iosDeviceVolume = nextRatio;
              _pushIosSystemVolume(nextRatio);
              setState(() {
                _isVerticalDragging = true;
                _isDraggingLeftBrightness = false;
                _hudText = '设备音量 ${(nextRatio * 100.0).round()}%';
              });
            }
          } else {
            final nextRatio = event.volume.clamp(0.0, 1.0);
            final nextVol = nextRatio * 100.0;
            _engineSetVolume100(nextVol);
            setState(() {
              _isVerticalDragging = true;
              _isDraggingLeftBrightness = false;
              _hudText = '音量 ${nextVol.round()}%';
            });
          }
        case VerticalVolumeEndEvent():
          _isVerticalDragging = false;
          _iosFsmVolumeBaseline = null;
          if (_isIosPlayerPlatform && _iosDeviceVolumeSynced) {
            _iosDeviceVolume = _iosConfirmedDeviceVolume;
            if (_hudText.startsWith('设备音量 ')) {
              setState(() {
                _hudText =
                    '设备音量 ${(_iosConfirmedDeviceVolume * 100.0).round()}%';
              });
            }
          }
          _scheduleVerticalHudClear();
        case SpeedBoostStartEvent():
          if (event.haptic) HapticFeedback.selectionClick();
          _engineSetRate(event.speed);
          setState(() {
            _speedBoosting = true;
            _hudText = '';
          });
        case SpeedBoostChangeEvent():
          if (event.haptic) HapticFeedback.selectionClick();
          _engineSetRate(event.speed);
          setState(() => _speedBoosting = true);
        case SpeedLockReadyChangedEvent():
          if (event.haptic) HapticFeedback.mediumImpact();
          setState(() {});
        case SpeedBoostEndEvent():
          _engineSetRate(event.restoreSpeed);
          setState(() {
            _normalSpeed = event.restoreSpeed;
            _speedBoosting = false;
            _hudText = '';
          });
        case SpeedLockedEvent():
          if (event.haptic) HapticFeedback.mediumImpact();
          _engineSetRate(event.speed);
          setState(() {
            _speedBoosting = false;
            _hudText = '';
          });
        case SpeedUnlockedEvent():
          if (event.reason != GestureInterruptReason.manualSpeedChange) {
            _engineSetRate(event.restoreSpeed);
          }
          setState(() {
            if (event.reason != GestureInterruptReason.manualSpeedChange) {
              _normalSpeed = event.restoreSpeed;
            }
            _speedBoosting = false;
          });
          if (event.reason == null) {
            _showHud(
              '已恢复 ${PlayerSpeedCapsule.formatSpeed(event.restoreSpeed)}× 播放',
            );
          }
        case GestureCancelledEvent():
          setState(() {
            _speedBoosting = false;
            _isDraggingSeek = false;
            _isVerticalDragging = false;
          });
      }
    }
  }

  void _scheduleVerticalHudClear() {
    _verticalHudClearTimer?.cancel();
    _verticalHudClearTimer = Timer(const Duration(milliseconds: 700), () {
      if (mounted &&
          !_isVerticalDragging &&
          !_speedBoosting &&
          !_gestureFsm.isSpeedBoosting) {
        setState(() => _hudText = '');
      }
    });
  }

  void _handleDesktopArrowKeyDown(int direction, {bool isRepeat = false}) {
    final effectiveDurMs = _duration.inMilliseconds > 0
        ? _duration.inMilliseconds
        : _lastKnownDurationMs;
    if (_isLiveStream || effectiveDurMs <= 0) return;

    // S-07: Only a fresh KeyDownEvent may initiate a new hold-seek session.
    // Ignore stale KeyRepeatEvents arriving after Escape or opposite-key cancel.
    if (isRepeat &&
        (!_desktopKeySeek.isActive || _desktopKeySeek.direction != direction)) {
      return;
    }

    final wall = DateTime.now().millisecondsSinceEpoch;
    if (!_desktopKeySeek.isActive) {
      _desktopKeyClockMs = wall;
    } else if (wall > _desktopKeyClockMs) {
      _desktopKeyClockMs = wall;
    }

    final preview = _desktopKeySeek.onKeyDownOrRepeat(
      direction: direction,
      currentPositionMs: _position.inMilliseconds,
      durationMs: effectiveDurMs,
      nowMs: _desktopKeyClockMs,
      isRepeat: isRepeat,
    );

    if (!_desktopKeySeek.isActive) return;

    if (preview.isHoldPreview) {
      setState(() {
        _isDraggingSeek = true;
        _dragTargetPosMs = preview.targetMs;
        _activeDesktopScrubPreview = preview;
      });
    }

    _desktopKeyTickTimer ??= Timer.periodic(
      const Duration(milliseconds: 50),
      (_) {
        if (!mounted || !_desktopKeySeek.isActive) {
          _desktopKeyTickTimer?.cancel();
          _desktopKeyTickTimer = null;
          return;
        }
        final nowWall = DateTime.now().millisecondsSinceEpoch;
        _desktopKeyClockMs = math.max(nowWall, _desktopKeyClockMs + 50);
        final updated = _desktopKeySeek.updatePreview(_desktopKeyClockMs);
        if (updated.isHoldPreview) {
          setState(() {
            _isDraggingSeek = true;
            _dragTargetPosMs = updated.targetMs;
            _activeDesktopScrubPreview = updated;
          });
        }
      },
    );
  }

  void _handleDesktopArrowKeyUp(int direction) {
    // S-07: Strictly verify released key direction matches the active seek.
    if (!_desktopKeySeek.isActive || _desktopKeySeek.direction != direction) {
      return;
    }
    _desktopKeyTickTimer?.cancel();
    _desktopKeyTickTimer = null;
    final wall = DateTime.now().millisecondsSinceEpoch;
    if (wall > _desktopKeyClockMs) {
      _desktopKeyClockMs = wall;
    }
    final wasHold = _desktopKeySeek.isScrubbing;
    final dir = _desktopKeySeek.direction;
    final targetMs = _desktopKeySeek.onKeyUp(
      _desktopKeyClockMs,
      direction: direction,
    );
    if (targetMs == null) {
      if (_activeDesktopScrubPreview != null) {
        setState(() {
          _activeDesktopScrubPreview = null;
          _isDraggingSeek = false;
        });
      }
      return;
    }
    setState(() {
      _activeDesktopScrubPreview = null;
      _isDraggingSeek = false;
      _position = Duration(milliseconds: targetMs);
    });
    _seekPlayer(
      Duration(milliseconds: targetMs),
      saveProgressOnSuccess: true,
    );
    final fmt = _formatDuration(Duration(milliseconds: targetMs));
    _showHud(
      wasHold ? '跳转至 $fmt' : '${dir >= 0 ? "快进" : "快退"} $fmt',
    );
    _scheduleHide();
  }

  void _cycleDesktopSpeedKey() {
    if (_isLiveStream) return;
    final nextSpeed = DesktopKeySeekStateMachine.cycleDesktopSpeed(_normalSpeed);
    _applyManualSpeed(nextSpeed);
  }

  void _applyManualSpeed(double newSpeed) {
    final clamped = _normalizePlaybackSpeed(newSpeed);
    if (_useEnhancedHud) {
      final events = _gestureFsm.onManualSpeedChanged(clamped);
      _applyGestureEvents(events);
    }
    setState(() => _normalSpeed = clamped);
    _engineSetRate(clamped);
    if (_castController.isCasting) {
      unawaited(_castController.setSpeed(clamped));
    }
    widget.storage.setPlaySpeed(clamped);
    final speedLabel = clamped.toString().replaceAll(RegExp(r'\.0$'), '');
    _showHud('倍速 ${speedLabel}x');
  }

  void _handleDesktopPointerSignal(PointerSignalEvent event) {
    if (!_desktop || !_useEnhancedHud || _screenLocked) return;
    if (event is PointerScrollEvent && event.scrollDelta.dy != 0) {
      GestureBinding.instance.pointerSignalResolver.register(
        event,
        (PointerSignalEvent resolved) {
          if (!mounted || _screenLocked) return;
          if (resolved is PointerScrollEvent && resolved.scrollDelta.dy != 0) {
            final delta = resolved.scrollDelta.dy < 0 ? 5.0 : -5.0;
            final nextVol = (_engineVolume100 + delta).clamp(0.0, 100.0);
            _engineSetVolume100(nextVol);
            _showHud('音量 ${nextVol.round()}%');
          }
        },
      );
    }
  }

  void _seekPlayer(Duration target, {bool saveProgressOnSuccess = false}) {
    final clampedMs = math.max(0, target.inMilliseconds);
    final clamped = Duration(milliseconds: clampedMs);
    _clearAiLiveSubtitleLine();
    _syncAiSubtitleClockMs(clampedMs);
    if (_usingAvPlayer) {
      final avCtrl = _iosAvPlayerController;
      if (avCtrl != null) {
        _dispatchAvSeek(
          avCtrl,
          clampedMs,
          saveProgressOnSuccess: saveProgressOnSuccess,
        );
      }
    } else {
      _player.seek(clamped);
      if (saveProgressOnSuccess) {
        unawaited(_saveProgress(immediate: true, triggerSync: false));
      }
    }
    if (!OhosRuntime.isOhos && _danmuSettings.effectiveEnabled) {
      _danmuCache?.onSeekChanged(clampedMs);
    }
  }

  Future<void> _loadOnboardingPrefs() async {
    if (OhosRuntime.isOhos || _isLiveStream || widget.embedded) return;
    try {
      final prefs = await OnboardingPrefs.load();
      if (!mounted) return;
      setState(() => _onboardingPrefs = prefs);
    } catch (_) {}
  }

  void _onIosThermalPressureChanged() {
    if (!mounted || !_isIosPlayerPlatform || _playerDisposed) return;
    final avThermal = _iosAvPlayerController?.thermalState;
    final effectiveThermal = switch (IosLiquidGlassBridge.thermalLevel) {
      >= 3 => IosThermalState.critical,
      2 => IosThermalState.serious,
      1 => IosThermalState.fair,
      _ => avThermal ?? IosThermalState.nominal,
    };
    final resolvedThermal =
        (avThermal != null && avThermal.code > effectiveThermal.code)
            ? avThermal
            : effectiveThermal;
    if (resolvedThermal.isThrottled &&
        _anime4kController.isIosLightweightAvailableForPlayer(_player)) {
      unawaited(
        _anime4kController.handleThermalState(_player, resolvedThermal),
      );
    }
    if (!_usingAvPlayer) {
      final nextLowPower = IosMpvProfile.shouldUseLowPowerThermalMode(
        avThermalState: resolvedThermal,
        bridgeThermalElevated: IosLiquidGlassBridge.thermalElevated,
        iosMajorVersion: IosLiquidGlassBridge.majorVersion,
      );
      if (nextLowPower != _lastAppliedIosMpvLowPowerThermal) {
        _lastAppliedIosMpvLowPowerThermal = nextLowPower;
        unawaited(
          IosMpvProfile.applyToPlayer(
            _player,
            physicalMemoryBytes:
                _avPhysicalMemoryBytes ??
                _iosAvPlayerController?.physicalMemoryBytes,
            largeBuffer: _iosLargeBuffer || _playerKernel == 'mpv',
            isLive: _isLiveStream,
            hdrToneMapping: _iosHdrToneMapping,
            vocalLoudness: _vocalLoudness,
            hwdec: _hardwareDecoder(_playerKernel),
            lowPowerThermalMode: nextLowPower,
          ),
        );
      }
    }
  }

  Future<void> _initAnime4kAfterKernel() async {
    if (OhosRuntime.isOhos) return;
    final desktopAvail = _anime4kController.isAvailableForPlayer(_player);
    final iosAvail =
        _isIosPlayerPlatform &&
        _anime4kController.isIosLightweightAvailableForPlayer(_player);
    if (!desktopAvail && !iosAvail) {
      return;
    }
    try {
      if (desktopAvail) {
        await _anime4kController.loadSavedPreset();
        await _playerConfiguration;
        if (!mounted) return;
        if (_anime4kController.preset != Anime4kPreset.off) {
          await _anime4kController.reapplyActivePreset(_player);
          if (_isWindowsPlayerPlatform &&
              _winQualityController.isAvailableForPlayer(_player)) {
            await _winQualityController.syncHardwareDecoder(
              _player,
              anime4kActive: true,
              playerKernel: _playerKernel,
            );
          }
        }
      } else if (iosAvail) {
        final avCtrl = _iosAvPlayerController;
        if (avCtrl != null) {
          _anime4kController.bindThermalStream(
            _player,
            avCtrl.onThermalStateChanged,
          );
          await _anime4kController.handleThermalState(
            _player,
            avCtrl.thermalState,
          );
        } else if (IosLiquidGlassBridge.thermalThrottled) {
          await _anime4kController.handleThermalState(
            _player,
            IosLiquidGlassBridge.thermalLevel >= 3
                ? IosThermalState.critical
                : IosThermalState.serious,
          );
        }
        _anime4kController.onThermalAutoDisabled = (state) {
          if (mounted) {
            _showHud('设备温度过高（${state.labelZh}），已自动关闭 Anime4K 轻超分');
          }
        };
        await _anime4kController.loadSavedIosLightweight();
        await _playerConfiguration;
        if (!mounted) return;
        if (_anime4kController.iosLightweightEnabled) {
          await _anime4kController.reapplyIosLightweight(_player);
        }
      }
    } catch (_) {}
  }

  Future<void> _loadDanmuSettings() async {
    if (OhosRuntime.isOhos) return;
    try {
      final loaded = await DanmuPrefs.load();
      if (!mounted) return;
      setState(() {
        _danmuSettings = widget.danmuEnabled && !loaded.enabled
            ? loaded.copyWith(enabled: true)
            : loaded;
      });
      _rebuildDanmuPipeline();
      if (_danmuSettings.effectiveEnabled && !_isLiveStream) {
        _bindDanmuForCurrentEpisode();
      }
    } catch (_) {}
  }

  void _rebuildDanmuPipeline() {
    if (OhosRuntime.isOhos) return;
    _danmuMatchToken?.cancel();
    _danmuMatchToken = null;
    final oldCache = _danmuCache;
    _danmuCache = null;
    if (oldCache != null && !oldCache.isDisposed) {
      oldCache.cancelPendingRequests();
      unawaited(oldCache.bindSession(''));
      _deferredDisposedDanmuCaches.add(oldCache);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _deferredDisposedDanmuCaches.remove(oldCache);
        if (!oldCache.isDisposed) {
          oldCache.dispose();
        }
      });
    }
    final oldProvider = _danmuProvider;
    final ownedOldProvider = _ownsDanmuProvider;
    _danmuProvider = null;
    _ownsDanmuProvider = false;
    if (ownedOldProvider && oldProvider is DandanplayProvider) {
      oldProvider.close();
    }
    _danmuBoundForEpisode = false;
    final ownsNextProvider = widget.debugDanmuProvider == null;
    final DanmuProvider provider = widget.debugDanmuProvider ??
        (widget.debugDanmuProviderFactory != null
            ? widget.debugDanmuProviderFactory!(_danmuSettings)
            : _danmuSettings.buildProvider());
    _danmuProvider = provider;
    _ownsDanmuProvider = ownsNextProvider;
    final cache = DanmuSegmentCache(provider: provider)
      ..setTimeOffsetMs(_danmuSettings.timeOffsetMs)
      ..setBlockFilter(_danmuSettings.buildBlockFilter());
    _danmuCache = cache;
  }

  void _resetDanmuForEpisode() {
    if (OhosRuntime.isOhos) return;
    _danmuMatchToken?.cancel();
    _danmuMatchToken = null;
    _danmuSessionGen++;
    _danmuBoundForEpisode = false;
    _matchedDanmuCandidate = null;
    _pendingDanmuCandidates = const <DanmuCandidate>[];
    _scrapedDanmuEpisodeNumber = null;
    final cache = _danmuCache;
    if (cache != null) {
      unawaited(cache.bindSession(''));
    }
    if (!_isLiveStream && _danmuSettings.effectiveEnabled) {
      _bindDanmuForCurrentEpisode();
    }
  }

  void _onPlayerSeriesScrapeRevision() {
    if (!mounted) return;
    setState(() {});
    if (!_isLiveStream && _danmuSettings.effectiveEnabled) {
      _reloadDanmuAfterCalibration();
    }
  }

  void _onDanmuSourcesRevisionChanged() {
    if (!mounted || OhosRuntime.isOhos) return;
    unawaited(_reloadDanmuSettingsFromStorage());
  }

  Future<void> _reloadDanmuSettingsFromStorage() async {
    try {
      final loaded = await DanmuPrefs.load();
      if (!mounted) return;
      final next = _danmuSettings.copyWith(
        serverUrls: loaded.serverUrls,
        appId: loaded.appId,
        appSecret: loaded.appSecret,
        authorizedCredentialOrigins: loaded.authorizedCredentialOrigins,
      );
      final serverChanged = next.serverUrls != _danmuSettings.serverUrls ||
          next.appId != _danmuSettings.appId ||
          next.appSecret != _danmuSettings.appSecret ||
          next.authorizedCredentialOrigins !=
              _danmuSettings.authorizedCredentialOrigins;
      setState(() {
        _danmuSettings = next;
      });
      if (serverChanged && widget.debugDanmuProvider == null) {
        _rebuildDanmuPipeline();
      }
      if (!_isLiveStream && _danmuSettings.effectiveEnabled) {
        _bindDanmuForCurrentEpisode();
      }
    } catch (_) {}
  }

  void _reloadDanmuAfterCalibration() {
    if (OhosRuntime.isOhos || _isLiveStream) return;
    _danmuMatchToken?.cancel();
    _danmuMatchToken = null;
    _danmuSessionGen++;
    _danmuBoundForEpisode = false;
    _matchedDanmuCandidate = null;
    _pendingDanmuCandidates = const <DanmuCandidate>[];
    if (_danmuSettings.effectiveEnabled) {
      _bindDanmuForCurrentEpisode();
    } else {
      final cache = _danmuCache;
      if (cache != null) {
        unawaited(cache.bindSession(''));
      }
    }
  }

  List<int> _visibleOrderedEpisodeIndices() {
    final count = _currentLine.episodes.length;
    if (count == 0) return const <int>[];
    if (_isLiveStream) {
      return List<int>.generate(count, (i) => i, growable: false);
    }
    final override = widget.storage.getSeriesScrapeOverride(
      _activeSite.key,
      _activeVideo.id,
      isPrivate: _activeSite.isEffectivelyPrivate,
    );
    final scrape = _scrapeLineEpisodesFor(_currentLine, override: override);
    final sortByScraped =
        override?.sortByScrapedEpisode ?? scrape.sourceOrderScrambled;
    final hideSpecials = override?.hideSpecials ?? false;
    return scrape.orderedIndices(
      sortByScraped: sortByScraped,
      hideSpecials: hideSpecials,
    );
  }

  int? _adjacentVisibleEpisodeIndex(int delta) {
    if (delta == 0) return null;
    final order = _visibleOrderedEpisodeIndices();
    if (order.isEmpty) return null;
    final pos = order.indexOf(_episodeIndex);
    if (pos >= 0) {
      final targetPos = pos + delta;
      if (targetPos < 0 || targetPos >= order.length) return null;
      return order[targetPos];
    }
    if (delta > 0) return order.first;
    return null;
  }

  LineEpisodeScrapeResult _scrapeLineEpisodesFor(
    CmsLine line, {
    SeriesScrapeOverride? override,
  }) {
    final ov = override ??
        widget.storage.getSeriesScrapeOverride(
          widget.site.key,
          widget.video.id,
          isPrivate: widget.site.isEffectivelyPrivate,
        );
    final effectiveTitle = (ov != null && ov.effectiveDanmuTitle.isNotEmpty)
        ? ov.effectiveDanmuTitle
        : widget.video.title;
    return SeriesScraper.scrapeLineEpisodes(
      line.episodes,
      seriesTitle: effectiveTitle,
      episodeOffset: ov?.episodeOffset ?? 0,
      manualOverrides: ov?.episodeNumberOverrides ?? const {},
      episodeCalibrations: ov?.episodeCalibrations ?? const {},
      runtimeContainerTags: _runtimeContainerTags,
    );
  }

  ScrapedEpisodeInfo? _currentScrapedEpisodeInfo({
    SeriesScrapeOverride? override,
  }) {
    if (_isLiveStream) return null;
    final scrape = _scrapeLineEpisodesFor(_currentLine, override: override);
    return scrape.infoForOriginalIndex(_episodeIndex);
  }

  ({int? matchedIndex, bool seasonConflict, String conflictSummary})
      _resolveTargetLineEpisodeMatch(int targetLineIndex) {
    final targetLine = _lines[targetLineIndex];
    if (targetLine.episodes.isEmpty) {
      return (matchedIndex: null, seasonConflict: false, conflictSummary: '');
    }
    if (_isLiveStream) {
      return (
        matchedIndex: CspBridge.matchEpisodeIndexInLine(
          targetLine,
          _currentEpisode.name,
          _episodeIndex,
        ),
        seasonConflict: false,
        conflictSummary: '',
      );
    }
    final srcInfo = _currentScrapedEpisodeInfo();
    final targetScrape = _scrapeLineEpisodesFor(targetLine);
    if (srcInfo != null) {
      final matched = SeriesScraper.matchEpisodeIndexInScrapedLine(
        srcInfo,
        targetScrape,
      );
      if (matched != null &&
          matched >= 0 &&
          matched < targetLine.episodes.length) {
        return (
          matchedIndex: matched,
          seasonConflict: false,
          conflictSummary: '',
        );
      }
      final srcSeason = srcInfo.seasonNumber;
      final srcEp = srcInfo.resolvedEpisodeNumber;
      if (!srcInfo.isSpecial && !srcInfo.needsConfirmation && srcEp != null) {
        final targetHasWrongWork = targetScrape.byOriginalIndex.any(
          (c) =>
              !c.isSpecial &&
              c.resolvedEpisodeNumber == srcEp &&
              !SeriesScraper.areWorkTitlesCompatible(srcInfo, c),
        );
        final targetHasOtherSeason = srcSeason != null &&
            targetScrape.byOriginalIndex.any(
              (c) =>
                  !c.isSpecial &&
                  c.seasonNumber != null &&
                  c.seasonNumber != srcSeason,
            );
        final targetHasExplicitEpisodes = targetScrape.regularCount > 0;
        final targetHasExplicitSpecials = targetScrape.specialCount > 0;
        if (targetHasWrongWork ||
            targetHasOtherSeason ||
            targetHasExplicitEpisodes ||
            targetHasExplicitSpecials) {
          final String summary;
          if (targetHasWrongWork) {
            summary =
                '目标线路「${targetLine.name}」的 ${srcInfo.formattedSeasonEpisode} 属于其他作品，请手动选集';
          } else if (targetHasExplicitSpecials && !targetHasExplicitEpisodes) {
            summary =
                '目标线路「${targetLine.name}」仅有预告/特别篇，未找到正片 ${srcInfo.formattedSeasonEpisode}，请手动选集';
          } else {
            summary =
                '目标线路「${targetLine.name}」未找到 ${srcInfo.formattedSeasonEpisode}，请手动选集';
          }
          return (
            matchedIndex: null,
            seasonConflict: true,
            conflictSummary: summary,
          );
        }
      }
    }
    final fallbackIdx = CspBridge.matchEpisodeIndexInLine(
      targetLine,
      _currentEpisode.name,
      _episodeIndex,
    );
    if (srcInfo != null &&
        !srcInfo.isSpecial &&
        fallbackIdx >= 0 &&
        fallbackIdx < targetLine.episodes.length) {
      final fallbackInfo = targetScrape.infoForOriginalIndex(fallbackIdx);
      if (fallbackInfo != null) {
        if (fallbackInfo.isSpecial) {
          return (
            matchedIndex: null,
            seasonConflict: true,
            conflictSummary:
                '目标线路「${targetLine.name}」仅匹配到预告/特别篇，请手动选集',
          );
        }
        if (!SeriesScraper.areWorkTitlesCompatible(srcInfo, fallbackInfo)) {
          return (
            matchedIndex: null,
            seasonConflict: true,
            conflictSummary:
                '目标线路「${targetLine.name}」对应条目作品不一致，请手动选集',
          );
        }
      }
    }
    return (
      matchedIndex: fallbackIdx,
      seasonConflict: false,
      conflictSummary: '',
    );
  }

  void _switchToLineWithConflictGuard(int targetLineIndex) {
    if (targetLineIndex < 0 || targetLineIndex >= _lines.length) return;
    final match = _resolveTargetLineEpisodeMatch(targetLineIndex);
    if (match.matchedIndex == null) {
      final msg = match.conflictSummary.isNotEmpty
          ? match.conflictSummary
          : '目标线路「${_lines[targetLineIndex].name}」未找到对应集数，请手动选集';
      _showHud(msg);
      _showEpisodesSheet(
        initialLineIndex: targetLineIndex,
        initialNotice: msg,
      );
      return;
    }
    _failedLinesForEpisode.clear();
    _failedLiveEpisodes.clear();
    final keepPos = _position.inMilliseconds >= 1000
        ? _position.inMilliseconds
        : _lastKnownPositionMs;
    _saveProgress(immediate: true, syncImmediate: false);
    setState(() {
      _lineIndex = targetLineIndex;
      _episodeIndex = match.matchedIndex!;
    });
    _openCurrentEpisode(resumeMs: keepPos);
  }

  void _probeCurrentEpisodeContainerTags(int session) {
    if (!mounted ||
        _isLiveStream ||
        session != _playSession ||
        OhosRuntime.isOhos ||
        _usingAvPlayer ||
        _videoKernel.mdkPlatform != null ||
        _videoKernel.ohosPlatform != null) {
      return;
    }
    final platform = _player.platform;
    if (platform == null) return;
    final ep = _currentEpisode;
    final stableKey = SeriesScraper.stableEpisodeKey(ep);
    if (stableKey.isEmpty) return;
    final gen = ++_containerProbeGen;
    final beforeInfo = _currentScrapedEpisodeInfo();

    unawaited(() async {
      try {
        final dyn = platform as dynamic;
        String? rawMeta;
        String? mediaTitle;
        try {
          final m = await dyn.getProperty('metadata');
          if (m != null) rawMeta = m.toString();
        } catch (_) {}
        try {
          final mt = await dyn.getProperty('media-title');
          if (mt != null) mediaTitle = mt.toString();
        } catch (_) {}
        if (!mounted || session != _playSession || gen != _containerProbeGen) {
          return;
        }
        final parsed = ContainerMetadataReader.parseMpvMetadataJson(
          rawMeta,
          mediaTitle: mediaTitle,
          fallbackFileName:
              ep.originalFileName.isNotEmpty ? ep.originalFileName : ep.name,
        );
        if (parsed.isEmpty) return;
        final existing = _runtimeContainerTags[stableKey];
        bool changed = existing == null || existing.length != parsed.length;
        if (!changed) {
          for (final entry in parsed.entries) {
            if (existing[entry.key] != entry.value) {
              changed = true;
              break;
            }
          }
        }
        if (!changed) return;
        _runtimeContainerTags[stableKey] = parsed;
        ContainerMetadataCache.putByStableKey(stableKey, parsed);
        final afterInfo = _currentScrapedEpisodeInfo();
        setState(() {});
        final identityChanged =
            beforeInfo?.seasonNumber != afterInfo?.seasonNumber ||
                beforeInfo?.resolvedEpisodeNumber !=
                    afterInfo?.resolvedEpisodeNumber ||
                beforeInfo?.recognizedWorkTitle !=
                    afterInfo?.recognizedWorkTitle ||
                beforeInfo?.status != afterInfo?.status;
        if (identityChanged && _danmuSettings.effectiveEnabled) {
          _reloadDanmuAfterCalibration();
        }
      } catch (_) {}
    }());
  }

  Future<void> _openPlayerSeriesScrapeSheet() async {
    if (_isLiveStream || widget.site.isEffectivelyPrivate) return;
    _cancelTransientInteractions(GestureInterruptReason.dialogOpened);
    final beforeOverride = widget.storage.getSeriesScrapeOverride(
      widget.site.key,
      widget.video.id,
      isPrivate: false,
    );
    await showSeriesScrapeSheet(
      context,
      site: widget.site,
      video: widget.video,
      storage: widget.storage,
      activeLine: _currentLine,
      initialOverride: beforeOverride,
      initialTab: 1,
      focusEpisodeIndex: _episodeIndex,
      runtimeContainerTags: _runtimeContainerTags,
      pendingDanmuCandidates: _pendingDanmuCandidates,
      onSelectDanmuCandidate: _manualBindDanmuCandidate,
    );
    // Note: seriesScrapeRevision listener immediately updates UI & reloads
    // danmu from current playback timestamp while preserving play/pause state.
  }

  ({
    DanmuMatchQuery query,
    int? scrapedEpisodeNumber,
    int episodeOffset,
    String effectiveTitle,
    bool isMotionComic,
    SeriesScrapeOverride? override,
    ScrapedEpisodeInfo? episodeInfo,
    EpisodeManualCalibration? manualCalibration,
    bool canAutoMatch,
  }) _resolveDanmuMatchContext() {
    final override = widget.storage.getSeriesScrapeOverride(
      widget.site.key,
      widget.video.id,
      isPrivate: widget.site.isEffectivelyPrivate,
    );
    final scrape = _scrapeLineEpisodesFor(_currentLine, override: override);
    final epInfo = scrape.infoForOriginalIndex(_episodeIndex);
    final stableKey = SeriesScraper.stableEpisodeKey(_currentEpisode);
    final manualCalibration =
        stableKey.isNotEmpty ? override?.episodeCalibrations[stableKey] : null;
    // Propagate confirmed / container-recognized work title into the actual
    // danmu query: per-episode user calibration > series user binding >
    // container SHOW/SERIES/TVSH tag > catalog title.
    final String effectiveTitle;
    if (manualCalibration != null &&
        manualCalibration.workTitle.trim().isNotEmpty) {
      effectiveTitle = manualCalibration.workTitle.trim();
    } else if (override != null && override.effectiveDanmuTitle.isNotEmpty) {
      effectiveTitle = override.effectiveDanmuTitle;
    } else if (epInfo != null &&
        epInfo.recognizedWorkTitle.trim().isNotEmpty) {
      effectiveTitle = epInfo.recognizedWorkTitle.trim();
    } else {
      effectiveTitle = widget.video.title;
    }
    final isMotionComic = (override != null && override.hasWorkBinding)
        ? override.isMotionComic
        : SeriesScraper.isMotionComicText(
            effectiveTitle,
            extraContext: '${widget.video.tag} ${widget.video.remarks}',
          );
    final episodeOffset = override?.episodeOffset ?? 0;
    final int? scrapedEpNum = epInfo?.resolvedEpisodeNumber;
    final bool needsConfirmation = epInfo?.needsConfirmation ?? false;
    final bool isUnoverriddenSpecial =
        epInfo != null && epInfo.isSpecial && !epInfo.hasManualOverride;

    final int effectiveEpNum;
    final bool canAutoMatch;
    if (scrapedEpNum != null && scrapedEpNum > 0) {
      effectiveEpNum = scrapedEpNum;
      canAutoMatch = true;
    } else if (needsConfirmation || isUnoverriddenSpecial) {
      // Never auto-fabricate an episode number from list index when the file
      // is 待确认 or a trailer/special.
      effectiveEpNum = 0;
      canAutoMatch = false;
    } else {
      effectiveEpNum = 0;
      canAutoMatch = false;
    }
    final effectiveDurMs = _duration.inMilliseconds > 0
        ? _duration.inMilliseconds
        : _lastKnownDurationMs;
    final year = (override != null && override.matchedYear.isNotEmpty)
        ? override.matchedYear
        : widget.video.year;
    final query = DanmuMatchQuery(
      title: effectiveTitle,
      episodeTitle: epInfo != null &&
              !epInfo.needsConfirmation &&
              epInfo.formattedSeasonEpisode.isNotEmpty
          ? epInfo.formattedSeasonEpisode
          : _currentEpisode.name,
      episodeIndex: effectiveEpNum,
      durationSec: effectiveDurMs > 0 ? effectiveDurMs ~/ 1000 : 0,
      seasonNumber: epInfo?.seasonNumber,
      isMotionComic: isMotionComic,
      year: year,
      animeIdOverride: override?.danmuAnimeId ?? '',
      originOverride: override?.danmuOrigin ?? '',
    );
    return (
      query: query,
      scrapedEpisodeNumber: effectiveEpNum > 0 ? effectiveEpNum : null,
      episodeOffset: episodeOffset,
      effectiveTitle: effectiveTitle,
      isMotionComic: isMotionComic,
      override: override,
      episodeInfo: epInfo,
      manualCalibration: manualCalibration,
      canAutoMatch: canAutoMatch,
    );
  }

  String _currentDanmuMatchSummary() {
    final matched = _matchedDanmuCandidate;
    if (matched != null) {
      final parts = <String>[
        if (matched.animeTitle.isNotEmpty) matched.animeTitle,
        if (matched.episodeTitle.isNotEmpty) matched.episodeTitle,
      ];
      return parts.isNotEmpty
          ? '当前匹配：${parts.join(" · ")}'
          : '已绑定弹幕（ID ${matched.animeId}）';
    }
    final epInfo = _currentScrapedEpisodeInfo();
    if (epInfo != null && epInfo.needsConfirmation) {
      return '当前识别：待确认（请在选集 → 识别／校准本集确认）';
    }
    if (_pendingDanmuCandidates.isNotEmpty) {
      return '弹幕服务仅返回相近/邻集候选，请手动选择';
    }
    final epNum = _scrapedDanmuEpisodeNumber;
    if (epNum != null && epNum > 0) {
      final label = epInfo?.readableSeasonEpisodeZh ?? '第 $epNum 集';
      return '当前识别：$label（${_danmuBoundForEpisode ? "已加载" : "待匹配"}）';
    }
    return '当前集：${_currentEpisode.name}';
  }

  Future<List<DanmuCandidate>> _searchDanmuCandidatesManually(
    String keyword,
    int? episodeNumber,
  ) async {
    if (_danmuProvider == null || _danmuCache == null) {
      _rebuildDanmuPipeline();
    }
    final provider = _danmuProvider;
    if (provider == null) return const <DanmuCandidate>[];
    final ctx = _resolveDanmuMatchContext();
    final query = DanmuMatchQuery(
      title: keyword.trim().isNotEmpty ? keyword.trim() : ctx.effectiveTitle,
      episodeTitle: _currentEpisode.name,
      episodeIndex: episodeNumber ?? ctx.query.episodeIndex,
      durationSec: ctx.query.durationSec,
      seasonNumber: ctx.query.seasonNumber,
      isMotionComic: SeriesScraper.isMotionComicText(keyword)
          ? true
          : ctx.isMotionComic,
      year: ctx.query.year,
    );
    return provider.matchOrSearch(query);
  }

  void _manualBindDanmuCandidate(DanmuCandidate candidate) {
    final boundId = candidate.boundEpisodeId.trim();
    if (boundId.isEmpty) return;
    if (_danmuProvider == null || _danmuCache == null) {
      _rebuildDanmuPipeline();
    }
    final cache = _danmuCache;
    if (cache == null) return;
    _danmuMatchToken?.cancel();
    final gen = ++_danmuSessionGen;
    _matchedDanmuCandidate = candidate;
    _pendingDanmuCandidates = const <DanmuCandidate>[];
    unawaited(() async {
      try {
        await cache.bindSession(boundId);
        if (!mounted || gen != _danmuSessionGen) return;
        _danmuBoundForEpisode = true;
        final tickMs = _position.inMilliseconds > 0
            ? _position.inMilliseconds
            : (_pendingResumeMs > 0 ? _pendingResumeMs : _lastKnownPositionMs);
        cache.onPlaybackTick(tickMs, playing: _playing);
        _showHud(
          '已切换弹幕：${candidate.animeTitle} ${candidate.episodeTitle}'.trim(),
        );
      } catch (_) {}
    }());
    // Persist BOTH the per-episode manually chosen danmu binding (source +
    // boundEpisodeId) keyed by stable file/item identity AND the series-level
    // anime binding so saving, refreshing, or resuming keeps this exact choice.
    if (!_activeSite.isEffectivelyPrivate) {
      final existing = widget.storage.getSeriesScrapeOverride(
            _activeSite.key,
            _activeVideo.id,
            isPrivate: false,
          ) ??
          const SeriesScrapeOverride();
      final stableKey = SeriesScraper.stableEpisodeKey(_currentEpisode);
      final nextCalibs = Map<String, EpisodeManualCalibration>.from(
        existing.episodeCalibrations,
      );
      if (stableKey.isNotEmpty) {
        final prev =
            nextCalibs[stableKey] ?? const EpisodeManualCalibration();
        nextCalibs[stableKey] = prev.copyWith(
          danmuBoundEpisodeId: boundId,
          danmuSourceOrigin: candidate.sourceOrigin.trim(),
          danmuAnimeId: candidate.animeId.trim(),
          danmuAnimeTitle: candidate.animeTitle.trim(),
          danmuEpisodeTitle: candidate.episodeTitle.trim(),
          updatedAtMs: DateTime.now().millisecondsSinceEpoch,
        );
      }
      final updated = existing.copyWith(
        danmuAnimeId: candidate.animeId.isNotEmpty
            ? candidate.animeId
            : existing.danmuAnimeId,
        danmuOrigin: candidate.sourceOrigin.isNotEmpty
            ? candidate.sourceOrigin
            : existing.danmuOrigin,
        danmuTitleOverride: candidate.animeTitle.isNotEmpty
            ? candidate.animeTitle
            : existing.danmuTitleOverride,
        episodeCalibrations: nextCalibs,
      );
      unawaited(
        widget.storage.saveSeriesScrapeOverride(
          _activeSite.key,
          _activeVideo.id,
          updated,
        ),
      );
    }
  }

  void _updateDanmuEpisodeOffset(int nextOffset) {
    final clamped = nextOffset.clamp(-500, 500);
    _activeDanmuEpisodeOffset = clamped;
    if (!_activeSite.isEffectivelyPrivate) {
      final existing = widget.storage.getSeriesScrapeOverride(
        _activeSite.key,
        _activeVideo.id,
        isPrivate: false,
      );
      final updated = (existing ?? const SeriesScrapeOverride())
          .copyWith(episodeOffset: clamped);
      unawaited(
        widget.storage.saveSeriesScrapeOverride(
          _activeSite.key,
          _activeVideo.id,
          updated,
        ),
      );
    }
    _matchedDanmuCandidate = null;
    _danmuBoundForEpisode = false;
    _pendingDanmuCandidates = const <DanmuCandidate>[];
    _bindDanmuForCurrentEpisode();
  }

  void _bindDanmuForCurrentEpisode() {
    if (OhosRuntime.isOhos ||
        _isLiveStream ||
        !_danmuSettings.effectiveEnabled) {
      return;
    }
    if (widget.debugDanmuProvider == null &&
        _danmuSettings.normalizedOrigins.isEmpty) {
      // Default danmu server URL is strictly "" — zero network requests until configured.
      return;
    }
    if (_danmuProvider == null || _danmuCache == null) {
      _rebuildDanmuPipeline();
    }
    final provider = _danmuProvider;
    final cache = _danmuCache;
    if (provider == null || cache == null) return;

    _danmuMatchToken?.cancel();
    final token = DanmuCancelToken();
    _danmuMatchToken = token;
    final gen = ++_danmuSessionGen;
    final DanmuMatchQuery query;
    if (!_episodeScrapeOverride.isDefault) {
      final effectiveDurMs = _duration.inMilliseconds > 0
          ? _duration.inMilliseconds
          : _lastKnownDurationMs;
      final scrapedEp = _currentScrapedEpisode();
      query = DanmuMatchQuery(
        title: _effectiveScrapeTitle,
        episodeTitle: scrapedEp.danmuEpisodeTitle,
        episodeIndex:
            scrapedEp.isSpecial ? 0 : scrapedEp.effectiveEpisodeNumber,
        durationSec: effectiveDurMs > 0 ? effectiveDurMs ~/ 1000 : 0,
      );
    } else {
      final ctx = _resolveDanmuMatchContext();
      _scrapedDanmuEpisodeNumber = ctx.scrapedEpisodeNumber;
      _activeDanmuEpisodeOffset = ctx.episodeOffset;
      _pendingDanmuCandidates = const <DanmuCandidate>[];

      // Honor explicit per-episode manual danmu candidate choice across saves,
      // refreshes, and app restarts, loading directly from current playback time.
      final manualCalib = ctx.manualCalibration;
      if (manualCalib != null && manualCalib.hasDanmuBinding) {
        final savedOrigin = manualCalib.danmuSourceOrigin.trim();
        final originAvailable = widget.debugDanmuProvider != null ||
            savedOrigin.isEmpty ||
            _danmuSettings.normalizedOrigins.contains(savedOrigin);
        if (originAvailable) {
          final manualCand = DanmuCandidate(
            sourceOrigin: savedOrigin,
            animeId: manualCalib.danmuAnimeId,
            animeTitle: manualCalib.danmuAnimeTitle.isNotEmpty
                ? manualCalib.danmuAnimeTitle
                : ctx.effectiveTitle,
            boundEpisodeId: manualCalib.danmuBoundEpisodeId,
            episodeTitle: manualCalib.danmuEpisodeTitle,
            confidence: 1.0,
          );
          unawaited(() async {
            try {
              await cache.bindSession(manualCand.boundEpisodeId);
              if (!mounted || gen != _danmuSessionGen || token.isCancelled) {
                return;
              }
              _matchedDanmuCandidate = manualCand;
              _pendingDanmuCandidates = const <DanmuCandidate>[];
              _danmuBoundForEpisode = true;
              final tickMs = _position.inMilliseconds > 0
                  ? _position.inMilliseconds
                  : (_pendingResumeMs > 0
                      ? _pendingResumeMs
                      : _lastKnownPositionMs);
              cache.onPlaybackTick(tickMs, playing: _playing);
              if (mounted) setState(() {});
            } catch (_) {}
          }());
          return;
        }
      }

      if (!ctx.canAutoMatch) {
        _matchedDanmuCandidate = null;
        _danmuBoundForEpisode = false;
        unawaited(cache.bindSession(''));
        return;
      }
      query = ctx.query;
    }

    unawaited(() async {
      try {
        final candidates = await provider.matchOrSearch(
          query,
          cancelToken: token,
        );
        if (!mounted || gen != _danmuSessionGen || token.isCancelled) return;
        if (candidates.isEmpty) {
          _matchedDanmuCandidate = null;
          _danmuBoundForEpisode = false;
          unawaited(cache.bindSession(''));
          return;
        }
        final best = DandanplayProvider.selectUniqueAutoBindCandidate(
          candidates,
          query: query,
          preferredOrigins: _danmuSettings.normalizedOrigins,
        );
        if (best == null) {
          // Server only returned neighbor/unrelated/low-confidence or ambiguous
          // multi-season candidates: do NOT silently bind based on response
          // order; retain them for explicit user choice.
          _matchedDanmuCandidate = null;
          _danmuBoundForEpisode = false;
          _pendingDanmuCandidates = List<DanmuCandidate>.unmodifiable(
            candidates.where((c) => c.boundEpisodeId.trim().isNotEmpty),
          );
          unawaited(cache.bindSession(''));
          if (mounted) setState(() {});
          return;
        }
        await cache.bindSession(best.boundEpisodeId);
        if (!mounted || gen != _danmuSessionGen || token.isCancelled) return;
        _matchedDanmuCandidate = best;
        _pendingDanmuCandidates = const <DanmuCandidate>[];
        _danmuBoundForEpisode = true;
        cache.onPlaybackTick(_position.inMilliseconds, playing: _playing);
        if (mounted) setState(() {});
      } catch (_) {
        // Isolated danmu fetch failure must never disturb video playback.
      }
    }());
  }

  void _applyDanmuSettings(DanmuSettings next, {bool persist = true}) {
    if (OhosRuntime.isOhos) return;
    final prev = _danmuSettings;
    final serverChanged = prev.serverUrls != next.serverUrls ||
        prev.appId != next.appId ||
        prev.appSecret != next.appSecret;
    setState(() {
      _danmuSettings = next;
    });
    if (persist) {
      unawaited(
        DanmuPrefs.save(next, saveSourcesAndCredentials: serverChanged),
      );
    }
    if (serverChanged && widget.debugDanmuProvider == null) {
      _rebuildDanmuPipeline();
    } else {
      _danmuCache?.setTimeOffsetMs(next.timeOffsetMs);
      _danmuCache?.setBlockFilter(next.buildBlockFilter());
    }
    if (next.effectiveEnabled && !_isLiveStream) {
      if (!_danmuBoundForEpisode || serverChanged) {
        _bindDanmuForCurrentEpisode();
      } else {
        _danmuCache?.onPlaybackTick(_position.inMilliseconds, playing: _playing);
      }
    } else {
      _danmuMatchToken?.cancel();
      _danmuMatchToken = null;
      _danmuCache?.cancelPendingRequests();
    }
  }

  void _handleDanmuToggle() {
    if (OhosRuntime.isOhos) return;
    if (widget.onToggleDanmu != null) {
      widget.onToggleDanmu!.call();
      return;
    }
    final next = _danmuSettings.copyWith(enabled: !_danmuSettings.enabled);
    _applyDanmuSettings(next, persist: true);
    _showHud(next.enabled ? '弹幕已开启' : '弹幕已关闭');
  }

  void _handleDanmuSettingsTap({Rect? anchorRect}) {
    if (OhosRuntime.isOhos) return;
    if (widget.onOpenDanmuSettings != null) {
      widget.onOpenDanmuSettings!.call();
      return;
    }
    _cancelTransientInteractions(GestureInterruptReason.dialogOpened);
    final session = _playSession;
    final matchCtx = _isLiveStream ? null : _resolveDanmuMatchContext();
    final matchSummary = _isLiveStream ? '' : _currentDanmuMatchSummary();
    if (_useIos26PlayerChrome) {
      unawaited(
        showIosGlassPopover<void>(
          context: context,
          anchorRect: anchorRect,
          title: '弹幕设置',
          maxWidth: 348,
          maxHeight: 340,
          forceDark: true,
          contentPadding: const EdgeInsets.fromLTRB(4, 2, 4, 8),
          builder: (ctx) => DanmuSettingsSheet(
            initialSettings: _danmuSettings,
            currentMatchSummary: matchSummary,
            episodeOffset: matchCtx?.episodeOffset ?? _activeDanmuEpisodeOffset,
            initialSearchKeyword: matchCtx?.effectiveTitle ?? _activeVideo.title,
            initialEpisodeNumber: matchCtx?.scrapedEpisodeNumber,
            onEpisodeOffsetChanged: _isLiveStream
                ? null
                : (offset) {
                    if (!mounted || session != _playSession) return;
                    _updateDanmuEpisodeOffset(offset);
                  },
            onSearchCandidates: _isLiveStream
                ? null
                : _searchDanmuCandidatesManually,
            onSelectCandidate: _isLiveStream
                ? null
                : (cand) {
                    if (!mounted || session != _playSession) return;
                    _manualBindDanmuCandidate(cand);
                  },
            onChanged: (updated) {
              if (!mounted || session != _playSession) return;
              _applyDanmuSettings(updated, persist: false);
            },
          ),
        ),
      );
      return;
    }
    unawaited(
      DanmuSettingsSheet.show(
        context,
        initialSettings: _danmuSettings,
        currentMatchSummary: matchSummary,
        episodeOffset: matchCtx?.episodeOffset ?? _activeDanmuEpisodeOffset,
        initialSearchKeyword: matchCtx?.effectiveTitle ?? _activeVideo.title,
        initialEpisodeNumber: matchCtx?.scrapedEpisodeNumber,
        onEpisodeOffsetChanged: _isLiveStream
            ? null
            : (offset) {
                if (!mounted || session != _playSession) return;
                _updateDanmuEpisodeOffset(offset);
              },
        onSearchCandidates:
            _isLiveStream ? null : _searchDanmuCandidatesManually,
        onSelectCandidate: _isLiveStream
            ? null
            : (cand) {
                if (!mounted || session != _playSession) return;
                _manualBindDanmuCandidate(cand);
              },
        onChanged: (updated) {
          if (!mounted || session != _playSession) return;
          _applyDanmuSettings(updated, persist: false);
        },
      ),
    );
  }

  bool get _anime4kAvailable =>
      !OhosRuntime.isOhos && _anime4kController.isAvailableForPlayer(_player);

  void _showAnime4kSheet() {
    if (!_anime4kAvailable) return;
    _cancelTransientInteractions(GestureInterruptReason.dialogOpened);
    final session = _playSession;
    final showUltraHdWarning =
        Anime4kController.shouldShowUltraHdWarning(_videoHeight);
    showAppleModalSheet<void>(
      context: context,
      title: 'Anime4K 画质增强',
      maxWidth: 480,
      builder: (ctx) => ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.all(16),
        children: [
          if (showUltraHdWarning) ...[
            Container(
              key: const Key('anime4k-ultrahd-warning'),
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0x33FF9F0A),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: const Color(0x73FF9F0A),
                  width: 0.9,
                ),
              ),
              child: Row(
                children: [
                  const Icon(
                    CupertinoIcons.exclamationmark_triangle_fill,
                    color: AppleColors.systemOrange,
                    size: 16,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      Anime4kController.ultraHdWarningText(zh: true),
                      style: const TextStyle(
                        color: AppleColors.labelPrimary,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
          AppleGroupedSection(
            footer: '基于开源 MIT 协议 bloc97/Anime4K v4.0.1，实时热切换不中断当前播放进度。',
            children: Anime4kPreset.values.map((preset) {
              final selected = _anime4kController.preset == preset;
              return AppleGroupedTile(
                key: ValueKey('anime4k-preset-${preset.id}'),
                icon: CupertinoIcons.wand_stars,
                iconBgColor: selected
                    ? AppleColors.systemBlue
                    : AppleColors.groupedTertiary,
                title: preset.labelZh,
                subtitle: preset.descriptionZh,
                trailing: selected
                    ? const Icon(
                        CupertinoIcons.checkmark_alt,
                        color: AppleColors.systemBlue,
                        size: 18,
                      )
                    : null,
                onTap: () {
                  Navigator.of(ctx).pop();
                  unawaited(() async {
                    if (!mounted || session != _playSession) return;
                    final ok = await _anime4kController.applyPreset(
                      _player,
                      preset,
                    );
                    if (!mounted || session != _playSession) return;
                    if (_isWindowsPlayerPlatform &&
                        _winQualityController.isAvailableForPlayer(_player)) {
                      await _winQualityController.syncHardwareDecoder(
                        _player,
                        anime4kActive:
                            ok && preset != Anime4kPreset.off,
                        playerKernel: _playerKernel,
                      );
                    }
                    if (!mounted || session != _playSession) return;
                    if (ok) {
                      _showHud(
                        preset == Anime4kPreset.off
                            ? 'Anime4K 已关闭'
                            : 'Anime4K：${preset.labelZh}',
                      );
                    } else {
                      _showHud('Anime4K 着色器加载失败，已自动恢复关闭');
                    }
                  }());
                },
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  String _formatSignedDelta(int deltaMs) {
    final sign = deltaMs >= 0 ? '+' : '-';
    final absSec = (deltaMs.abs() / 1000.0).round();
    final m = absSec ~/ 60;
    final s = absSec % 60;
    if (m > 0) {
      return '$sign$m:${s.toString().padLeft(2, '0')}';
    }
    return '$sign${absSec}s';
  }

  bool get _usesDesktopSubtitleHudLayout =>
      _isMacosPlayerPlatform &&
      !OhosRuntime.shouldUseTvUi(widget.storage.tvUiMode);

  // Keep subtitles lifted throughout the entire HUD fade-out transition
  // (`_hudFadingOut == true` while `_controlsVisible == true`) and only restore
  // to baseline once `_controlsVisible` becomes `false` after fade-out finishes.
  bool get _isDesktopBottomControlsVisible =>
      _usesDesktopSubtitleHudLayout &&
      !_screenLocked &&
      !_castController.isCasting &&
      (_controlsVisible || _isSliderDragging);

  double _effectiveDesktopBottomControlsHeight(EdgeInsets viewPadding) {
    if (_measuredDesktopBottomBarHeight > 0.0) {
      return _measuredDesktopBottomBarHeight;
    }
    final fallback = widget.embedded ? 64.0 : (_isLiveStream ? 50.0 : 86.0);
    return fallback + viewPadding.bottom;
  }

  double _computeSubtitleBottomPadding(EdgeInsets viewPadding) {
    if (!_usesDesktopSubtitleHudLayout) {
      return SubtitleLayoutGeometry.defaultBottomPadding;
    }
    return SubtitleLayoutGeometry.computeTextOverlayBottomPadding(
      hudControlsVisible: _isDesktopBottomControlsVisible,
      measuredBottomBarHeight:
          _effectiveDesktopBottomControlsHeight(viewPadding),
      bottomSafeInset: viewPadding.bottom,
    );
  }

  void _handleDesktopBottomControlsHeightChanged(double height) {
    if (!mounted || height <= 0.0) return;
    if ((height - _measuredDesktopBottomBarHeight).abs() < 0.5) return;
    setState(() {
      _measuredDesktopBottomBarHeight = height;
    });
    _scheduleSyncNativeSubtitleState();
  }

  void _scheduleSyncNativeSubtitleState() {
    if (!_isMacosPlayerPlatform || _subtitleSyncScheduled || !mounted) return;
    _subtitleSyncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _subtitleSyncScheduled = false;
      if (!mounted) return;
      unawaited(_syncNativeSubtitleState());
    });
  }

  Future<void> _syncNativeSubtitleState() async {
    if (!mounted ||
        !_isMacosPlayerPlatform ||
        OhosRuntime.isOhos ||
        _usingAvPlayer ||
        _videoKernel.mdkPlatform != null ||
        _videoKernel.ohosPlatform != null) {
      return;
    }
    final platform = _player.platform;
    if (platform == null) return;
    final epoch = ++_subtitleSyncEpoch;
    final selected = _player.state.track.subtitle;
    final available = _player.state.tracks.subtitle;

    String? liveSid;
    if (selected.id == 'auto') {
      try {
        final rawSid = await (platform as dynamic).getProperty('sid');
        if (rawSid != null) {
          liveSid = rawSid.toString().trim();
        }
      } catch (_) {}
    }
    if (!mounted || epoch != _subtitleSyncEpoch) return;

    final resolved = SubtitleLayoutGeometry.resolveActiveTrack(
      selected: selected,
      available: available,
      mpvSid: liveSid,
    );
    final mode = SubtitleLayoutGeometry.classifyTrack(resolved);
    if (mode != _subtitleRenderMode) {
      setState(() {
        _subtitleRenderMode = mode;
      });
    }

    final wantsNative = mode == SubtitleRenderMode.mpvNativeAss ||
        mode == SubtitleRenderMode.mpvNativeBitmap;
    final viewPadding = MediaQuery.viewPaddingOf(context);
    final viewport = _lastVideoStackViewport.isEmpty
        ? MediaQuery.sizeOf(context)
        : _lastVideoStackViewport;
    final targetSubPos = wantsNative
        ? SubtitleLayoutGeometry.computeMpvSubPos(
            viewport: viewport,
            videoWidth: _videoWidth,
            videoHeight: _videoHeight,
            fit: _fit,
            hudControlsVisible: _isDesktopBottomControlsVisible,
            measuredBottomBarHeight:
                _effectiveDesktopBottomControlsHeight(viewPadding),
          )
        : 100;

    try {
      final dyn = platform as dynamic;
      if (wantsNative && !_mpvSubtitleAssInitialized) {
        await dyn.setProperty('sub-ass', 'yes');
        await dyn.setProperty('sub-ass-override', 'yes');
        _mpvSubtitleAssInitialized = true;
      }
      if (_lastAppliedMpvSubVisible != wantsNative) {
        await dyn.setProperty('sub-visibility', wantsNative ? 'yes' : 'no');
        _lastAppliedMpvSubVisible = wantsNative;
      }
      if (_lastAppliedMpvSubPos != targetSubPos) {
        await dyn.setProperty('sub-pos', '$targetSubPos');
        _lastAppliedMpvSubPos = targetSubPos;
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final viewPadding = MediaQuery.viewPaddingOf(context);
    final systemGestureInsets = MediaQuery.systemGestureInsetsOf(context);
    final screenSize = MediaQuery.sizeOf(context);
    final isLandscape = screenSize.width > screenSize.height;
    final showPortraitCompanion = _shouldShowPortraitCompanion(screenSize);
    final effectiveReduceTransparency = _isEffectiveReduceTransparency(context);
    final effectiveDurMs = _duration.inMilliseconds > 0
        ? _duration.inMilliseconds
        : _lastKnownDurationMs;
    final speedCapsuleMode = _speedCapsuleMode;
    final desktopPreview = _activeDesktopScrubPreview;
    // M-06: Offset top capsules below the top HUD header whenever controls are
    // visible so PlayerSpeedCapsule / SleepTimerWarningBanner never overlap
    // IosPlayerChrome's top bar or title capsule.
    final bool topBarVisible = _controlsVisible && !_screenLocked;
    final bool isPadLikeOverlay = _isIosPlayerPlatform &&
        (screenSize.shortestSide >= 600 ||
            (screenSize.height >= 900 && screenSize.width >= 300));
    final double effectiveTopOverlaySafe = isPadLikeOverlay
        ? math.max(viewPadding.top, 28.0)
        : viewPadding.top;
    final double topOverlayOffset = topBarVisible
        ? (_useIos26PlayerChrome
            ? effectiveTopOverlaySafe +
                (isLandscape ? 12.0 : 10.0) +
                (screenSize.width < 440 ? 96.0 : 76.0) +
                8.0
            : (_desktop && !widget.embedded
                ? math.max(16.0, effectiveTopOverlaySafe + 84.0)
                : math.max(16.0, effectiveTopOverlaySafe + 76.0)))
        : math.max(16.0, effectiveTopOverlaySafe + 16.0);

    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final subtitleBottomPadding = _computeSubtitleBottomPadding(viewPadding);
    final subtitleAnimDuration =
        reduceMotion ? Duration.zero : const Duration(milliseconds: 200);
    final showFlutterTextSubtitles = !_isMacosPlayerPlatform ||
        (_subtitleRenderMode != SubtitleRenderMode.mpvNativeAss &&
            _subtitleRenderMode != SubtitleRenderMode.mpvNativeBitmap);
    final subtitleOverlay = widget.debugSubtitleLayer ??
        _videoKernel.buildSubtitleOverlay(
          subtitleViewKey: _subtitleViewKey,
          padding: EdgeInsets.fromLTRB(
            SubtitleLayoutGeometry.defaultHorizontalPadding,
            0.0,
            SubtitleLayoutGeometry.defaultHorizontalPadding,
            subtitleBottomPadding,
          ),
          visible: showFlutterTextSubtitles,
        );
    if (widget.debugSubtitleLayer == null &&
        subtitleOverlay != null &&
        (subtitleBottomPadding - _lastAppliedSubtitleOverlayBottomPadding)
                .abs() >=
            0.5) {
      _lastAppliedSubtitleOverlayBottomPadding = subtitleBottomPadding;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _subtitleViewKey.currentState?.setPadding(
          EdgeInsets.fromLTRB(
            SubtitleLayoutGeometry.defaultHorizontalPadding,
            0.0,
            SubtitleLayoutGeometry.defaultHorizontalPadding,
            subtitleBottomPadding,
          ),
          duration: subtitleAnimDuration,
        );
      });
    }
    _scheduleSyncNativeSubtitleState();

    final effectiveDanmuSpeed = (_gestureFsm.isSpeedBoosting ||
            _gestureFsm.isSpeedLockReady ||
            _gestureFsm.isSpeedLocked)
        ? _gestureFsm.activeSpeed
        : _normalSpeed;
    final Widget? activeDanmuWidget = OhosRuntime.isOhos
        ? null
        : (widget.danmuLayer ??
            (!_isLiveStream
                ? DanmuLayer(
                    settings: _danmuSettings,
                    positionMs: _position.inMilliseconds,
                    positionListenable: _danmuPositionMs,
                    playing: _playing,
                    playSpeed: effectiveDanmuSpeed,
                    segmentCache: _danmuCache,
                    topInset: math.max(8.0, viewPadding.top + 8.0),
                    bottomSafeInset: math.max(
                      DanmuLayoutEngine.minBottomSafeInset,
                      viewPadding.bottom + 48.0,
                    ),
                  )
                : null));

    final Widget? positionedSubtitleChild = subtitleOverlay == null
        ? null
        : (widget.debugSubtitleLayer != null && _usesDesktopSubtitleHudLayout
            ? AnimatedPadding(
                key: const Key('player-subtitle-padding'),
                duration: subtitleAnimDuration,
                curve: Curves.easeOutCubic,
                padding: EdgeInsets.only(bottom: subtitleBottomPadding),
                child: subtitleOverlay,
              )
            : subtitleOverlay);

    final videoStack = LayoutBuilder(
      builder: (stackCtx, stackConstraints) {
        final nextViewport = stackConstraints.biggest;
        if (nextViewport.width > 0 &&
            nextViewport.height > 0 &&
            ((nextViewport.width - _lastVideoStackViewport.width).abs() >= 1.0 ||
                (nextViewport.height - _lastVideoStackViewport.height).abs() >=
                    1.0)) {
          _lastVideoStackViewport = nextViewport;
          _scheduleSyncNativeSubtitleState();
        }
        return Stack(
          key: const Key('player-video-stack'),
          fit: StackFit.expand,
          children: [
            Center(
              key: const Key('player-video-surface-layer'),
              child: RepaintBoundary(
                child: _usingAvPlayer &&
                        widget.debugVideoSurface == null &&
                        _iosAvPlayerController != null
                    ? _iosAvPlayerController!.buildView(
                        key: const Key('ios-avplayer-surface'),
                      )
                    : _videoKernel.buildVideoSurface(
                        fit: _fit,
                        videoWidth: _videoWidth,
                        videoHeight: _videoHeight,
                        externalSubtitleOverlay: !OhosRuntime.isOhos,
                      ),
              ),
            ),
            // M3b: DanmuLayer strictly ABOVE video surface and BELOW subtitles & HUD.
            if (activeDanmuWidget != null && !OhosRuntime.isOhos)
              Positioned.fill(
                key: const Key('player-danmu-layer'),
                child: IgnorePointer(child: activeDanmuWidget),
              ),
            // M3b: Subtitles strictly ABOVE DanmuLayer and BELOW HUD overlays.
            if (positionedSubtitleChild != null && !_hasActiveAiSubtitleOverlay)
              Positioned.fill(
                key: const Key('player-subtitle-layer'),
                child: IgnorePointer(child: positionedSubtitleChild),
              ),
            if (_hasActiveAiSubtitleOverlay)
              Positioned.fill(
                key: const Key('player-ai-subtitle-overlay'),
                child: IgnorePointer(
                  child: _buildAiSubtitleOverlayWidget(
                    bottomPadding: subtitleBottomPadding,
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
        // Bubble-free playback toast with adaptive contrast text.
        if (_hudText.isNotEmpty &&
            speedCapsuleMode == SpeedCapsuleMode.hidden &&
            desktopPreview == null)
          Positioned.fill(
            child: IgnorePointer(
              child: Align(
                alignment: const Alignment(0, -0.70),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 28),
                  child: Text(
                    _hudText,
                    key: const ValueKey<String>('player-hud-toast:visible'),
                    maxLines: 2,
                    textAlign: TextAlign.center,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Color(0xF7FFFFFF),
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.1,
                      height: 1.32,
                      shadows: [
                        Shadow(
                          color: Color(0xE0000000),
                          blurRadius: 8,
                          offset: Offset(0, 1.5),
                        ),
                        Shadow(
                          color: Color(0x9E000000),
                          blurRadius: 20,
                          offset: Offset(0, 2),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        // Bubble-free loading indicator (zero white pill, clear of side lock button).
        if (_useIos26PlayerChrome &&
            widget.loadingIndicator == null &&
            !_isLiveStream)
          Positioned.fill(
            child: IgnorePointer(
              child: Center(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                    showPortraitCompanion ? 54 : 32,
                    (_desktop &&
                            _controlsVisible &&
                            !_screenLocked &&
                            !widget.embedded)
                        ? 152
                        : 0,
                    showPortraitCompanion ? 54 : 32,
                    0,
                  ),
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 220),
                    switchInCurve: Curves.easeOutCubic,
                    switchOutCurve: Curves.easeInCubic,
                    child: (_loading || _buffering)
                        ? KeyedSubtree(
                            key: const Key('player-loading-indicator'),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const BrandLogoLoader(
                                  key: Key('player-brand-logo-loader'),
                                  size: 22,
                                ),
                                const SizedBox(width: 9),
                                Flexible(
                                  child: Text(
                                    '正在加载 ${_currentScrapedEpisode().compactLabel(singleItemMovie: _currentLine.episodes.length <= 1, multiVersionMovie: _isMultiVersionMovie)}…',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: Color(0xF5FFFFFF),
                                      fontSize: 13.5,
                                      fontWeight: FontWeight.w600,
                                      letterSpacing: 0.1,
                                      shadows: [
                                        Shadow(
                                          color: Color(0xE0000000),
                                          blurRadius: 8,
                                          offset: Offset(0, 1.5),
                                        ),
                                        Shadow(
                                          color: Color(0x9E000000),
                                          blurRadius: 18,
                                          offset: Offset(0, 2),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          )
                        : const SizedBox.shrink(
                            key: ValueKey<String>('player-loading-empty'),
                          ),
                  ),
                ),
              ),
            ),
          )
        else if (_loading || _buffering)
          Positioned.fill(
            child: IgnorePointer(
              child: Center(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                    showPortraitCompanion ? 54 : 32,
                    (_desktop &&
                            _controlsVisible &&
                            !_screenLocked &&
                            !widget.embedded)
                        ? 152
                        : 0,
                    showPortraitCompanion ? 54 : 32,
                    0,
                  ),
                  child: KeyedSubtree(
                    key: const Key('player-loading-indicator'),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        widget.loadingIndicator ??
                            (!OhosRuntime.isOhos
                                ? const BrandLogoLoader(
                                    key: Key('player-brand-logo-loader'),
                                    size: 22,
                                  )
                                : const CupertinoActivityIndicator(
                                    radius: 10,
                                    color: Colors.white,
                                  )),
                        const SizedBox(width: 9),
                        Flexible(
                          child: Text(
                            '正在加载 ${_isLiveStream ? _currentEpisode.name : _currentScrapedEpisode().compactLabel(singleItemMovie: _currentLine.episodes.length <= 1, multiVersionMovie: _isMultiVersionMovie)}…',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Color(0xF5FFFFFF),
                              fontSize: 13.5,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 0.1,
                              shadows: [
                                Shadow(
                                  color: Color(0xE0000000),
                                  blurRadius: 8,
                                  offset: Offset(0, 1.5),
                                ),
                                Shadow(
                                  color: Color(0x9E000000),
                                  blurRadius: 18,
                                  offset: Offset(0, 2),
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
      ],
    );
      },
    );

    final Widget surfaceWidget = _useEnhancedHud
        ? Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: (event) {
              if (event.kind == PointerDeviceKind.mouse &&
                  (event.buttons & kPrimaryMouseButton) == 0) {
                return;
              }
              // S-01: Cross-layer multi-touch guard — if another pointer is
              // already active on HUD controls/scrubber/slider, cancel active
              // transient interactions and do NOT start a single-tap/long-press.
              if (_globalActivePointers.any((id) => id != event.pointer) ||
                  _isSliderDragging) {
                _globalActivePointers.add(event.pointer);
                _cancelTransientInteractions(GestureInterruptReason.multiTouch);
                return;
              }
              if (_isIosPlayerPlatform) {
                if (_iosDeviceVolumeSynced) {
                  _iosDeviceVolume = _iosConfirmedDeviceVolume;
                  _iosFsmVolumeBaseline =
                      _iosConfirmedDeviceVolume.clamp(0.0, 1.0);
                } else {
                  _iosFsmVolumeBaseline = null;
                  unawaited(_primeIosSystemVolume());
                }
              }
              final ctx = TouchPointerContext(
                pointerId: event.pointer,
                x: event.localPosition.dx,
                y: event.localPosition.dy,
                viewportWidth: screenSize.width,
                viewportHeight: screenSize.height,
                systemGestureInsetLeft: systemGestureInsets.left,
                systemGestureInsetRight: systemGestureInsets.right,
                systemInsetTop: math.max(
                  viewPadding.top,
                  systemGestureInsets.top,
                ),
                systemInsetBottom: math.max(
                  viewPadding.bottom,
                  systemGestureInsets.bottom,
                ),
                nowMs: _nowGestureMs(),
                screenLocked: _screenLocked,
                isLive: _isLiveStream,
                isPipOrMini: false,
                playing: _playing,
                durationMs: effectiveDurMs,
                positionMs: _position.inMilliseconds,
                userNormalSpeed: _normalSpeed,
                brightness: _playerBrightness,
                volume: _isIosPlayerPlatform
                    ? _iosDeviceVolume.clamp(0.0, 1.0)
                    : (_engineVolume100 / 100.0).clamp(0.0, 1.0),
                isTouchPointer: event.kind == PointerDeviceKind.touch ||
                    event.kind == PointerDeviceKind.stylus,
              );
              final events = _gestureFsm.onPointerDown(ctx);
              _applyGestureEvents(events);
              _syncGestureTimer();
            },
            onPointerMove: (event) {
              final events = _gestureFsm.onPointerMove(
                pointerId: event.pointer,
                x: event.localPosition.dx,
                y: event.localPosition.dy,
                nowMs: _nowGestureMs(),
              );
              _applyGestureEvents(events);
              _syncGestureTimer();
            },
            onPointerUp: (event) {
              final events = _gestureFsm.onPointerUp(
                pointerId: event.pointer,
                x: event.localPosition.dx,
                y: event.localPosition.dy,
                nowMs: _nowGestureMs(),
              );
              _applyGestureEvents(events);
              _syncGestureTimer();
            },
            onPointerCancel: (event) {
              final events = _gestureFsm.cancel(
                GestureInterruptReason.pointerCancel,
              );
              _gestureFsm.onPointerCancelOrRemoved(event.pointer);
              _applyGestureEvents(events);
              _syncGestureTimer();
            },
            child: videoStack,
          )
        : GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _toggleControls,
            onDoubleTap: _screenLocked
                ? null
                : () {
                    if (_desktop) {
                      _toggleOrientation();
                      return;
                    }
                    _enginePlayOrPause();
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
                      _engineSetRate(2.0);
                    }
                  },
            onLongPressEnd: _screenLocked
                ? null
                : (_) {
                    if (_speedBoosting) {
                      _engineSetRate(_normalSpeed);
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
                    _seekPlayer(
                      Duration(milliseconds: targetMs),
                      saveProgressOnSuccess: true,
                    );
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
                    if (_isDraggingLeftBrightness) {
                      _verticalDragStartValue = _playerBrightness;
                    } else if (_isIosPlayerPlatform) {
                      if (_iosDeviceVolumeSynced) {
                        _iosDeviceVolume = _iosConfirmedDeviceVolume;
                        _iosLegacyVolumeBaseline = _iosConfirmedDeviceVolume;
                        _verticalDragStartValue = _iosConfirmedDeviceVolume;
                      } else {
                        _iosLegacyVolumeBaseline = null;
                        _verticalDragStartValue = _iosConfirmedDeviceVolume;
                        unawaited(_primeIosSystemVolume());
                      }
                    } else {
                      _verticalDragStartValue =
                          (_engineVolume100 / 100.0).clamp(0.0, 1.0);
                    }
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
                    } else if (_isIosPlayerPlatform) {
                      if (!_iosDeviceVolumeSynced) {
                        _iosPendingVolumeDragActive = true;
                        _iosPendingVolumeDragDelta = delta;
                        unawaited(_primeIosSystemVolume());
                        setState(() {
                          _hudText = '正在同步设备音量…';
                        });
                      } else {
                        final base =
                            _iosLegacyVolumeBaseline ?? _verticalDragStartValue;
                        final nextVolRatio = (base + delta).clamp(0.0, 1.0);
                        _iosDeviceVolume = nextVolRatio;
                        _pushIosSystemVolume(nextVolRatio);
                        setState(() {
                          _hudText = '设备音量 ${(nextVolRatio * 100).round()}%';
                        });
                      }
                    } else {
                      final nextVolRatio =
                          (_verticalDragStartValue + delta).clamp(0.0, 1.0);
                      final nextVol = nextVolRatio * 100.0;
                      _engineSetVolume100(nextVol);
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
                    _iosLegacyVolumeBaseline = null;
                    if (_isIosPlayerPlatform && _iosDeviceVolumeSynced) {
                      _iosDeviceVolume = _iosConfirmedDeviceVolume;
                      if (_hudText.startsWith('设备音量 ')) {
                        setState(() {
                          _hudText =
                              '设备音量 ${(_iosConfirmedDeviceVolume * 100.0).round()}%';
                        });
                      }
                    }
                    _scheduleVerticalHudClear();
                  },
            onVerticalDragCancel: (_desktop || _screenLocked)
                ? null
                : () {
                    if (!_isVerticalDragging) return;
                    _iosLegacyVolumeBaseline = null;
                    _iosPendingVolumeDragActive = false;
                    _iosPendingVolumeDragDelta = 0.0;
                    if (_isIosPlayerPlatform && _iosDeviceVolumeSynced) {
                      _iosDeviceVolume = _iosConfirmedDeviceVolume;
                    }
                    setState(() {
                      _isVerticalDragging = false;
                      _hudText = '';
                    });
                  },
            child: videoStack,
          );

    return PopScope(
      canPop: !_screenLocked,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) {
          _cancelTransientInteractions(GestureInterruptReason.backExit);
          unawaited(_mobileChrome.setOrientationMonitoring(false));
          unawaited(_saveProgress(immediate: true));
          return;
        }
        if (_screenLocked) {
          _revealLockedHint();
        }
      },
      child: Scaffold(
      backgroundColor: showPortraitCompanion
          ? ApplePalette.of(context).background
          : Colors.black,
      body: FocusScope(
        node: _playerFocusScopeNode,
        autofocus: !widget.embedded,
        child: Focus(
        focusNode: _playerFocusNode,
        autofocus: !widget.embedded,
        onFocusChange: (hasFocus) {
          if (!hasFocus) {
            _cancelDesktopKeyScrub(showToast: false);
            if (_useEnhancedHud &&
                (_gestureFsm.state == TouchGestureState.downPending ||
                    _gestureFsm.isSpeedBoosting ||
                    _gestureFsm.isSpeedLockReady ||
                    _isDraggingSeek)) {
              _cancelTransientInteractions(GestureInterruptReason.focusLost);
            }
          }
        },
        onKeyEvent: (node, event) {
          if (_screenLocked) {
            if (event is KeyDownEvent || event is KeyRepeatEvent) {
              _revealLockedHint();
            }
            return KeyEventResult.handled;
          }
          final isTvMode = OhosRuntime.shouldUseTvUi(widget.storage.tvUiMode);
          if (isTvMode) {
            final nowMs = DateTime.now().millisecondsSinceEpoch;
            if (event is KeyUpEvent &&
                (event.logicalKey == LogicalKeyboardKey.arrowRight ||
                    event.logicalKey == LogicalKeyboardKey.arrowLeft)) {
              final committedMs = _tvSeek.commitOnKeyUp(nowMs);
              if (committedMs != null && !_isLiveStream) {
                setState(() {
                  _isDraggingSeek = false;
                  _position = Duration(milliseconds: committedMs);
                });
                _seekPlayer(Duration(milliseconds: committedMs));
                _showHud('跳转至 ${_formatDuration(Duration(milliseconds: committedMs))}');
                _scheduleHide();
              }
              return KeyEventResult.handled;
            }
            if ((event is KeyDownEvent || event is KeyRepeatEvent) &&
                !_isLiveStream &&
                (event.logicalKey == LogicalKeyboardKey.arrowRight ||
                    event.logicalKey == LogicalKeyboardKey.arrowLeft)) {
              final dir =
                  event.logicalKey == LogicalKeyboardKey.arrowRight ? 1 : -1;
              final effectiveDurMs = _duration.inMilliseconds > 0
                  ? _duration.inMilliseconds
                  : _lastKnownDurationMs;
              _tvSeek.onKeyDown(
                direction: dir,
                currentPositionMs: _position.inMilliseconds,
                durationMs: effectiveDurMs,
                nowEpochMs: nowMs,
              );
              final preview = _tvSeek.updatePreview(nowMs);
              final targetFmt =
                  _formatDuration(Duration(milliseconds: preview.targetMs));
              setState(() {
                _isDraggingSeek = true;
                _dragTargetPosMs = preview.targetMs;
                _hudText = preview.isHoldPreview
                    ? '${dir > 0 ? "⏩" : "⏪"} $targetFmt · ${preview.currentSpeedX.round()}s/s'
                    : '${dir > 0 ? "快进" : "快退"} 15s -> $targetFmt';
              });
              return KeyEventResult.handled;
            }
            if (event is KeyDownEvent &&
                (event.logicalKey == LogicalKeyboardKey.channelUp ||
                    event.logicalKey == LogicalKeyboardKey.channelDown)) {
              if (_isLiveStream) {
                final delta =
                    event.logicalKey == LogicalKeyboardKey.channelUp ? 1 : -1;
                if (_hasLiveChannelCatalog) {
                  _stepLiveChannel(delta);
                } else {
                  _stepEpisode(delta);
                }
                return KeyEventResult.handled;
              }
            }
            if (event is KeyDownEvent &&
                _isLiveStream &&
                _hasLiveChannelCatalog &&
                (event.logicalKey == LogicalKeyboardKey.pageUp ||
                    event.logicalKey == LogicalKeyboardKey.pageDown)) {
              _stepLiveChannel(
                event.logicalKey == LogicalKeyboardKey.pageDown ? 1 : -1,
              );
              return KeyEventResult.handled;
            }
            if (event is KeyDownEvent &&
                (event.logicalKey == LogicalKeyboardKey.arrowUp ||
                    event.logicalKey == LogicalKeyboardKey.arrowDown)) {
              if (_isLiveStream && !_controlsVisible) {
                final delta =
                    event.logicalKey == LogicalKeyboardKey.arrowUp ? -1 : 1;
                if (_hasLiveChannelCatalog) {
                  _stepLiveChannel(delta);
                } else {
                  _stepEpisode(delta);
                }
              } else if (!_isLiveStream &&
                  event.logicalKey == LogicalKeyboardKey.arrowDown) {
                _openTvPlayerControlSheet();
              } else {
                setState(() => _controlsVisible = !_controlsVisible);
                if (_controlsVisible) _scheduleHide();
              }
              return KeyEventResult.handled;
            }
            if (event is KeyDownEvent &&
                (event.logicalKey == LogicalKeyboardKey.contextMenu ||
                    event.logicalKey == LogicalKeyboardKey.f1)) {
              _openTvPlayerControlSheet();
              return KeyEventResult.handled;
            }
            if (event is KeyDownEvent &&
                (event.logicalKey == LogicalKeyboardKey.goBack ||
                    event.logicalKey == LogicalKeyboardKey.escape)) {
              if (_tvSeek.isActive) {
                _tvSeek.cancel();
                setState(() {
                  _isDraggingSeek = false;
                  _hudText = '已取消跳转';
                });
                return KeyEventResult.handled;
              }
              if (_controlsVisible) {
                setState(() => _controlsVisible = false);
                return KeyEventResult.handled;
              }
              unawaited(
                _saveProgress(immediate: true).whenComplete(() {
                  if (context.mounted) _exitPlayer();
                }),
              );
              return KeyEventResult.handled;
            }
          }

          // Pass KeyUpEvent through for desktop left/right arrow seek commit,
          // strictly verifying released direction matches active seek.
          if (_useEnhancedHud &&
              event is KeyUpEvent &&
              (event.logicalKey == LogicalKeyboardKey.arrowRight ||
                  event.logicalKey == LogicalKeyboardKey.arrowLeft)) {
            final dir =
                event.logicalKey == LogicalKeyboardKey.arrowRight ? 1 : -1;
            if (_desktopKeySeek.isActive && _desktopKeySeek.direction == dir) {
              _handleDesktopArrowKeyUp(dir);
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          }

          if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
            return KeyEventResult.ignored;
          }
          final isCtrlOrCmd = HardwareKeyboard.instance.isControlPressed ||
              HardwareKeyboard.instance.isMetaPressed;
          if (isCtrlOrCmd && event.logicalKey == LogicalKeyboardKey.keyW) {
            unawaited(
              _saveProgress(immediate: true).whenComplete(() {
                if (context.mounted) _exitPlayer();
              }),
            );
            return KeyEventResult.handled;
          }
          if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
            if (_useEnhancedHud && !_isLiveStream) {
              _handleDesktopArrowKeyDown(1, isRepeat: event is KeyRepeatEvent);
            } else {
              _seekRelative(15);
            }
            return KeyEventResult.handled;
          }
          if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
            if (_useEnhancedHud && !_isLiveStream) {
              _handleDesktopArrowKeyDown(-1, isRepeat: event is KeyRepeatEvent);
            } else {
              _seekRelative(-15);
            }
            return KeyEventResult.handled;
          }
          if (event.logicalKey == LogicalKeyboardKey.arrowUp ||
              event.logicalKey == LogicalKeyboardKey.arrowDown) {
            final volume =
                (_engineVolume100 +
                        (event.logicalKey == LogicalKeyboardKey.arrowUp
                            ? 5
                            : -5))
                    .clamp(0.0, 100.0);
            _engineSetVolume100(volume);
            _showHud('音量 ${volume.round()}%');
            return KeyEventResult.handled;
          }
          if (event.logicalKey == LogicalKeyboardKey.bracketLeft ||
              event.logicalKey == LogicalKeyboardKey.bracketRight) {
            final delta = event.logicalKey == LogicalKeyboardKey.bracketRight
                ? 0.25
                : -0.25;
            _applyManualSpeed(_normalSpeed + delta);
            return KeyEventResult.handled;
          }
          if (event is! KeyDownEvent) return KeyEventResult.ignored;
          final editingText =
              FocusManager.instance.primaryFocus?.context?.widget
                  is EditableText;
          if (!isCtrlOrCmd &&
              !editingText &&
              _useEnhancedHud &&
              event.logicalKey == LogicalKeyboardKey.keyS) {
            _cycleDesktopSpeedKey();
            return KeyEventResult.handled;
          }
          if (!isCtrlOrCmd &&
              !editingText &&
              !OhosRuntime.isOhos &&
              _useEnhancedHud &&
              event.logicalKey == LogicalKeyboardKey.keyD) {
            _handleDanmuToggle();
            return KeyEventResult.handled;
          }
          if (event.logicalKey == LogicalKeyboardKey.keyM) {
            if (_engineVolume100 > 0) {
              _previousVolume = _engineVolume100;
              _engineSetVolume100(0);
              _showHud('静音');
            } else {
              final restore = _previousVolume > 0 ? _previousVolume : 100.0;
              _engineSetVolume100(restore);
              _showHud('音量 ${restore.round()}%');
            }
            return KeyEventResult.handled;
          }
          if (event.logicalKey == LogicalKeyboardKey.channelUp) {
            if (_isLiveStream && _hasLiveChannelCatalog) {
              _stepLiveChannel(1);
            } else {
              _stepEpisode(1);
            }
            return KeyEventResult.handled;
          }
          if (event.logicalKey == LogicalKeyboardKey.channelDown) {
            if (_isLiveStream && _hasLiveChannelCatalog) {
              _stepLiveChannel(-1);
            } else {
              _stepEpisode(-1);
            }
            return KeyEventResult.handled;
          }
          if (event.logicalKey == LogicalKeyboardKey.keyN ||
              event.logicalKey == LogicalKeyboardKey.pageDown) {
            if (_isLiveStream && _hasLiveChannelCatalog) {
              _stepLiveChannel(1);
            } else {
              _stepEpisode(1);
            }
            return KeyEventResult.handled;
          }
          if (event.logicalKey == LogicalKeyboardKey.keyP ||
              event.logicalKey == LogicalKeyboardKey.pageUp) {
            if (_isLiveStream && _hasLiveChannelCatalog) {
              _stepLiveChannel(-1);
            } else {
              _stepEpisode(-1);
            }
            return KeyEventResult.handled;
          }
          if (event.logicalKey == LogicalKeyboardKey.space ||
              event.logicalKey == LogicalKeyboardKey.enter ||
              event.logicalKey == LogicalKeyboardKey.select) {
            _enginePlayOrPause();
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
            if (_useEnhancedHud && _desktopKeySeek.isActive) {
              _cancelDesktopKeyScrub(showToast: true);
              return KeyEventResult.handled;
            }
            if (_windowsMoreControls) {
              setState(() => _windowsMoreControls = false);
              _scheduleHide();
              return KeyEventResult.handled;
            }
            if (_desktop) {
              _desktopEscape();
            } else {
              unawaited(
                _saveProgress(immediate: true).whenComplete(() {
                  if (context.mounted) _exitPlayer();
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
            behavior: HitTestBehavior.translucent,
            onPointerDown: _onGlobalPointerDown,
            onPointerUp: _onGlobalPointerUp,
            onPointerCancel: _onGlobalPointerCancel,
            onPointerSignal: _handleDesktopPointerSignal,
            onPointerMove: (event) {
              if (event.down) _onPointerMove(event.delta);
            },
            child: Column(
              children: [
                if (showPortraitCompanion && viewPadding.top > 0)
                  Container(
                    width: double.infinity,
                    height: viewPadding.top,
                    color: Colors.black,
                  ),
                if (showPortraitCompanion)
                  AnimatedContainer(
                    key: const Key('ios-portrait-video-box'),
                    duration: const Duration(milliseconds: 300),
                    curve: Curves.easeOutCubic,
                    width: screenSize.width,
                    height: _castController.isCasting
                        ? math.min(
                            math.max(
                              (screenSize.height - viewPadding.top) * 0.54,
                              376.0,
                            ),
                            math.max(
                              screenSize.height - viewPadding.top - 180.0,
                              360.0,
                            ),
                          )
                        : math.min(
                            screenSize.width * 9 / 16,
                            math.max(
                              200.0,
                              (screenSize.height - viewPadding.top) * 0.42,
                            ),
                          ),
                    child: Theme(
                      data: Theme.of(context).copyWith(
                        brightness: Brightness.dark,
                      ),
                      child: KeyedSubtree(
                        key: _playerStageKey,
                        child: PlayerInteractionLayers(
                        controls: Stack(
                          fit: StackFit.expand,
                          children: [
                            if (_alwaysShowClock && !_castController.isCasting)
                              Positioned.fill(
                                child: IgnorePointer(
                                  child: Align(
                                    alignment: Alignment.topRight,
                                    child: Padding(
                                      padding: EdgeInsets.only(
                                        top: _controlsVisible && !_screenLocked
                                            ? 46
                                            : 10,
                                        right: 12,
                                      ),
                                      child: Container(
                                        key: const Key('player-persistent-clock'),
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 8,
                                          vertical: 3.5,
                                        ),
                                        decoration: BoxDecoration(
                                          color: const Color(0x88101218),
                                          borderRadius:
                                              BorderRadius.circular(999),
                                        ),
                                        child: Text(
                                          _clockText.isEmpty
                                              ? _formatClockNow()
                                              : _clockText,
                                          style: const TextStyle(
                                            color: Color(0xEBFFFFFF),
                                            fontSize: 11,
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
                            if (!_castController.isCasting)
                              _AnimatedPlayerHudVisibility(
                                key: const Key('player-hud-animated-visibility'),
                                visible: _controlsVisible &&
                                    !_screenLocked &&
                                    !_hudFadingOut,
                                immediateHide: _screenLocked ||
                                    (!_controlsVisible && _hudAutoHidden),
                                childBuilder: (ctx) => ExcludeFocus(
                                  excluding: _desktop &&
                                      !OhosRuntime.shouldUseTvUi(
                                        widget.storage.tvUiMode,
                                      ),
                                  child: _buildAppleChromeOverlay(
                                    ctx,
                                    portraitCompanionBox: true,
                                  ),
                                ),
                              ),
                            if (_useEnhancedHud && !_castController.isCasting)
                              Positioned(
                                left: 0,
                                right: 0,
                                bottom: 0,
                                child: SlimProgressBar(
                                  visible: !_controlsVisible && !_screenLocked,
                                  enabled: _hudPrefs.effectiveSlimProgress,
                                  isLive: _isLiveStream,
                                  isEmbeddedOrPip: true,
                                  positionMs: _position.inMilliseconds,
                                  durationMs: effectiveDurMs,
                                  skipIntroSec: _skipIntroSec,
                                  skipOutroSec: _skipOutroSec,
                                  reduceTransparency:
                                      _storageReduceTransparency,
                                ),
                              ),
                            if (_screenLocked && _lockButtonVisible)
                              _buildLockedOverlay(context),
                            if (_useEnhancedHud &&
                                !_screenLocked &&
                                !_castController.isCasting &&
                                _skipCountdown.isActive &&
                                _skipCountdown.kind != null)
                              Positioned(
                                left: 16,
                                right: 16,
                                bottom: _controlsVisible ? 52.0 : 12.0,
                                child: Align(
                                  alignment: Alignment.bottomLeft,
                                  child: ConstrainedBox(
                                    constraints:
                                        const BoxConstraints(maxWidth: 300),
                                    child: SkipCountdownOverlay(
                                      kind: _skipCountdown.kind!,
                                      remainingSeconds:
                                          _skipCountdown.remainingSeconds,
                                      progress: _skipCountdown.progress,
                                      reduceTransparency:
                                          _storageReduceTransparency,
                                      reduceMotion:
                                          MediaQuery.disableAnimationsOf(
                                        context,
                                      ),
                                      onSkipNow: _skipCountdown.confirmNow,
                                      onCancel: _skipCountdown.cancel,
                                    ),
                                  ),
                                ),
                              ),
                            if (_playbackError.isNotEmpty &&
                                !_screenLocked &&
                                !_castController.isCasting)
                              Center(
                                child: FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: AppleGlassSurface(
                                    key: const Key('player-error-card'),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 16,
                                      vertical: 12,
                                    ),
                                    borderRadius: BorderRadius.circular(18),
                                    child:
                                        _buildPlaybackErrorCardContent(context),
                                  ),
                                ),
                              ),
                            if (_castController.isCasting)
                              Positioned.fill(
                                child: IosCastingRemoteStage(
                                  controller: _castController,
                                  episodeLabel:
                                      '${_currentEpisode.name} · ${_currentLine.name}',
                                  posterUrl: _activeVideo.poster,
                                  isPrivate: _isPrivateBackdrop,
                                  halfScreen: true,
                                  onBack: () async {
                                    await _saveProgress(immediate: true);
                                    if (context.mounted) _exitPlayer();
                                  },
                                  onSwitchDevice: () => _handleCastTap(null),
                                  onExitCast: _handleExitCast,
                                  onPreviousEpisode:
                                      _adjacentVisibleEpisodeIndex(-1) != null
                                          ? () => _stepEpisode(-1)
                                          : null,
                                  onNextEpisode:
                                      _adjacentVisibleEpisodeIndex(1) != null
                                          ? () => _stepEpisode(1)
                                          : null,
                                  onOpenEpisodes:
                                      _currentLine.episodes.length > 1
                                          ? _showEpisodesSheet
                                          : null,
                                  onOpenLines: _lines.length > 1
                                      ? _showLinesSheet
                                      : null,
                                ),
                              ),
                          ],
                        ),
                        surface: surfaceWidget,
                      ),
                    ),
                    ),
                  )
                else
                  Expanded(
                    child: Theme(
                      data: Theme.of(context).copyWith(
                        brightness: Brightness.dark,
                      ),
                      child: KeyedSubtree(
                        key: _playerStageKey,
                        child: PlayerInteractionLayers(
                        controls: Stack(
                          fit: StackFit.expand,
                          children: [
                            if (_alwaysShowClock && !_castController.isCasting)
                              Positioned.fill(
                                child: IgnorePointer(
                                  child: SafeArea(
                                    child: Align(
                                      alignment: Alignment.topRight,
                                      child: AnimatedPadding(
                                        duration:
                                            const Duration(milliseconds: 200),
                                        curve: Curves.easeOutCubic,
                                        padding: EdgeInsets.only(
                                          top: defaultTargetPlatform ==
                                                      TargetPlatform.macOS &&
                                                  !(_desktopWindow?.fullscreen ??
                                                      false)
                                              ? 38
                                              : (_useIos26PlayerChrome &&
                                                      _controlsVisible &&
                                                      !_screenLocked
                                                  ? 58
                                                  : 12),
                                          right: (!_screenLocked &&
                                                  _controlsVisible &&
                                                  !_useIos26PlayerChrome &&
                                                  isLandscape)
                                              ? 76
                                              : 16,
                                        ),
                                        child: Container(
                                          key: const Key(
                                            'player-persistent-clock',
                                          ),
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 10,
                                            vertical: 4.5,
                                          ),
                                          decoration: BoxDecoration(
                                            color: const Color(0x88101218),
                                            borderRadius:
                                                BorderRadius.circular(999),
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
                            // Start-of-playback spec banner: ONLY mounted when controls
                            // are hidden so it never overlaps the top-left return capsule.
                            if (_useEnhancedHud &&
                                !_screenLocked &&
                                !_castController.isCasting)
                              StartSpecOverlay(
                                badges: _fusedSpecBadges,
                                highlightActive:
                                    _startSpecController.highlightActive,
                                controlsVisible: _controlsVisible,
                                concentric: _useIos26PlayerChrome,
                                reduceTransparency: _storageReduceTransparency,
                              ),
                            if (!_castController.isCasting)
                              _AnimatedPlayerHudVisibility(
                                key: const Key('player-hud-animated-visibility'),
                                visible: _controlsVisible &&
                                    !_screenLocked &&
                                    !_hudFadingOut,
                                immediateHide: _screenLocked ||
                                    (!_controlsVisible && _hudAutoHidden),
                                childBuilder: (ctx) => ExcludeFocus(
                                  excluding: _desktop &&
                                      !OhosRuntime.shouldUseTvUi(
                                        widget.storage.tvUiMode,
                                      ),
                                  child: _buildAppleChromeOverlay(ctx),
                                ),
                              ),
                            // Persistent slim bottom progress bar when HUD is hidden.
                            if (_useEnhancedHud && !_castController.isCasting)
                              Positioned(
                                left: 0,
                                right: 0,
                                bottom: 0,
                                child: SlimProgressBar(
                                  visible: !_controlsVisible && !_screenLocked,
                                  enabled: _hudPrefs.effectiveSlimProgress,
                                  isLive: _isLiveStream,
                                  isEmbeddedOrPip: widget.embedded,
                                  positionMs: _position.inMilliseconds,
                                  durationMs: effectiveDurMs,
                                  skipIntroSec: _skipIntroSec,
                                  skipOutroSec: _skipOutroSec,
                                  reduceTransparency:
                                      _storageReduceTransparency,
                                ),
                              ),
                            // Top-center long-press speed boost / swipe-up lock capsule.
                            if (speedCapsuleMode != SpeedCapsuleMode.hidden &&
                                !_castController.isCasting)
                              Positioned(
                                top: topOverlayOffset,
                                left: 16,
                                right: 16,
                                child: Align(
                                  alignment: Alignment.topCenter,
                                  child: PlayerSpeedCapsule(
                                    mode: speedCapsuleMode,
                                    speed: _gestureFsm.activeSpeed,
                                    activeDetentIndex:
                                        _gestureFsm.activeDetentIndex,
                                    detents: _gestureFsm.config.speedDetents,
                                    reduceTransparency:
                                        _storageReduceTransparency,
                                    onUnlockTap: () {
                                      final events = _gestureFsm.unlockSpeed();
                                      _applyGestureEvents(events);
                                    },
                                  ),
                                ),
                              ),
                            // Top-center desktop keyboard arrow hold scrub preview capsule.
                            if (desktopPreview != null && !_screenLocked)
                              Positioned(
                                top: topOverlayOffset,
                                left: 16,
                                right: 16,
                                child: Align(
                                  alignment: Alignment.topCenter,
                                  child: DesktopScrubPreviewCapsule(
                                    direction: desktopPreview.direction,
                                    targetTimeText: _formatDuration(
                                      Duration(
                                        milliseconds: desktopPreview.targetMs,
                                      ),
                                    ),
                                    deltaText: _formatSignedDelta(
                                      desktopPreview.deltaMs,
                                    ),
                                    speedSecPerSec:
                                        desktopPreview.speedSecPerSec,
                                    isHoldPreview: desktopPreview.isHoldPreview,
                                    reduceTransparency:
                                        _storageReduceTransparency,
                                  ),
                                ),
                              ),
                            // Sleep timer 30-second pre-expiry warning banner.
                            if (_useEnhancedHud &&
                                !_screenLocked &&
                                _sleepTimer.showWarningBanner)
                              Positioned(
                                top: speedCapsuleMode == SpeedCapsuleMode.hidden
                                    ? topOverlayOffset
                                    : topOverlayOffset +
                                        (speedCapsuleMode ==
                                                SpeedCapsuleMode.locked
                                            ? 52.0
                                            : 96.0),
                                left: 16,
                                right: 16,
                                child: Align(
                                  alignment: Alignment.topCenter,
                                  child: ExcludeFocus(
                                    excluding: _desktop &&
                                        !OhosRuntime.shouldUseTvUi(
                                          widget.storage.tvUiMode,
                                        ),
                                    child: SleepTimerWarningBanner(
                                      remainingSeconds:
                                          _sleepTimer.remainingSeconds,
                                      reduceTransparency:
                                          _storageReduceTransparency,
                                      onExtend15m: () {
                                        _sleepTimer.extend15Minutes();
                                        _showHud('定时关闭已延长 15 分钟');
                                      },
                                      onCancel: () {
                                        _sleepTimer.cancel();
                                        _showHud('已取消定时关闭');
                                      },
                                    ),
                                  ),
                                ),
                              ),
                            // Cancellable 3-second skip intro/outro countdown card.
                            if (_useEnhancedHud &&
                                !_screenLocked &&
                                !_castController.isCasting &&
                                _skipCountdown.isActive &&
                                _skipCountdown.kind != null)
                              Positioned(
                                left: math.max(16.0, viewPadding.left + 12.0),
                                right: math.max(16.0, viewPadding.right + 12.0),
                                bottom: _controlsVisible
                                    ? (isLandscape ? 112.0 : 132.0)
                                    : math.max(24.0, viewPadding.bottom + 18.0),
                                child: Align(
                                  alignment: Alignment.bottomLeft,
                                  child: ConstrainedBox(
                                    constraints:
                                        const BoxConstraints(maxWidth: 310),
                                    child: ExcludeFocus(
                                      excluding: _desktop &&
                                          !OhosRuntime.shouldUseTvUi(
                                            widget.storage.tvUiMode,
                                          ),
                                      child: SkipCountdownOverlay(
                                        kind: _skipCountdown.kind!,
                                        remainingSeconds:
                                            _skipCountdown.remainingSeconds,
                                        progress: _skipCountdown.progress,
                                        reduceTransparency:
                                            _storageReduceTransparency,
                                        reduceMotion:
                                            MediaQuery.disableAnimationsOf(
                                          context,
                                        ),
                                        onSkipNow: _skipCountdown.confirmNow,
                                        onCancel: _skipCountdown.cancel,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            if (_screenLocked && _lockButtonVisible)
                              ExcludeFocus(
                                excluding: _desktop &&
                                    !OhosRuntime.shouldUseTvUi(
                                      widget.storage.tvUiMode,
                                    ),
                                child: _buildLockedOverlay(context),
                              ),
                            if (_playbackError.isNotEmpty &&
                                !_screenLocked &&
                                !_castController.isCasting)
                              Center(
                                child: effectiveReduceTransparency
                                    ? Container(
                                        key: const Key('player-error-card'),
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 22,
                                          vertical: 18,
                                        ),
                                        decoration: BoxDecoration(
                                          color: const Color(0xF51E1E22),
                                          borderRadius:
                                              BorderRadius.circular(22),
                                          border: Border.all(
                                            color: Colors.white
                                                .withValues(alpha: 0.48),
                                            width: 1.0,
                                          ),
                                        ),
                                        child: _buildPlaybackErrorCardContent(
                                          context,
                                        ),
                                      )
                                    : AppleGlassSurface(
                                        key: const Key('player-error-card'),
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 22,
                                          vertical: 18,
                                        ),
                                        borderRadius: BorderRadius.circular(22),
                                        child: _buildPlaybackErrorCardContent(
                                          context,
                                        ),
                                      ),
                              ),
                            // Wave 2 FirstPlayGestureHint slot
                            if (!OhosRuntime.isOhos &&
                                widget.firstPlayGestureHint != null)
                              Positioned.fill(
                                child: widget.firstPlayGestureHint!,
                              )
                            else if (!OhosRuntime.isOhos &&
                                !_isLiveStream &&
                                !widget.embedded &&
                                !_screenLocked &&
                                !_castController.isCasting &&
                                !_windowsMoreControls &&
                                _hasStartedVodPlayback &&
                                _onboardingPrefs != null &&
                                _onboardingPrefs!.shouldShowFirstPlayHint() &&
                                !_firstPlayHintDismissedThisSession)
                              Positioned(
                                left: 16,
                                right: 16,
                                bottom: _controlsVisible
                                    ? (isLandscape ? 116.0 : 136.0)
                                    : math.max(36.0, viewPadding.bottom + 28.0),
                                child: Align(
                                  alignment: Alignment.bottomCenter,
                                  child: FirstPlayGestureHint(
                                    prefs: _onboardingPrefs!,
                                    reduceTransparency:
                                        effectiveReduceTransparency,
                                    onDismissed: () {
                                      if (mounted) {
                                        setState(
                                          () =>
                                              _firstPlayHintDismissedThisSession =
                                                  true,
                                        );
                                      }
                                    },
                                  ),
                                ),
                              ),
                            if (_castController.isCasting)
                              Positioned.fill(
                                child: IosCastingRemoteStage(
                                  controller: _castController,
                                  episodeLabel:
                                      '${_currentEpisode.name} · ${_currentLine.name}',
                                  posterUrl: _activeVideo.poster,
                                  isPrivate: _isPrivateBackdrop,
                                  onBack: () async {
                                    await _saveProgress(immediate: true);
                                    if (context.mounted) _exitPlayer();
                                  },
                                  onSwitchDevice: () => _handleCastTap(null),
                                  onExitCast: _handleExitCast,
                                  onPreviousEpisode:
                                      _adjacentVisibleEpisodeIndex(-1) != null
                                          ? () => _stepEpisode(-1)
                                          : null,
                                  onNextEpisode:
                                      _adjacentVisibleEpisodeIndex(1) != null
                                          ? () => _stepEpisode(1)
                                          : null,
                                  onOpenEpisodes: _showEpisodesSheet,
                                  onOpenLines: _lines.length > 1
                                      ? _showLinesSheet
                                      : null,
                                ),
                              ),
                          ],
                        ),
                        surface: surfaceWidget,
                      ),
                    ),
                    ),
                  ),
                if (showPortraitCompanion)
                  Expanded(
                    child: _buildIosPortraitCompanionSheet(context),
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

  /// Apple-native iOS / iPadOS Live TV portrait companion panel rendered below
  /// the top 16:9 live player box: active station header, quick live actions
  /// (PiP / Cast / Engine / Reconnect), 1-tap signal line switcher, and inline
  /// searchable multi-group channel browser for zero-flash channel zapping.
  Widget _buildIosLivePortraitCompanionSheet(BuildContext context) {
    final palette = ApplePalette.of(context);
    final isDark = palette.isDark;
    final episodes = _currentLine.episodes;
    final activeCh = _activeLiveChannel ??
        LiveChannel(
          name: _displayTitle,
          group: _currentLine.name.trim().isNotEmpty
              ? _currentLine.name.trim()
              : '直播频道',
          urls: [for (final e in episodes) e.url],
        );
    final activeName = activeCh.name;
    final activeGroup = activeCh.group;
    final groups =
        widget.liveGroups.where((g) => g.channels.isNotEmpty).toList();
    final totalChannels = groups.fold<int>(0, (sum, g) => sum + g.channels.length);

    final isPipActive =
        _usingAvPlayer && (_iosAvPlayerController?.isPipActive ?? false);
    final statusColor = _playbackError.isNotEmpty
        ? AppleColors.systemOrange
        : (_loading || _buffering
            ? AppleColors.systemBlue
            : (_playing ? AppleColors.systemRed : palette.labelTertiary));
    final statusLabel = _playbackError.isNotEmpty
        ? '连接异常'
        : (_loading
            ? '正在连接'
            : (_buffering
                ? '缓冲中'
                : (_playing ? '正在直播' : '已暂停')));
    final activeLatency = LiveHealthVisual.badgeText(activeCh);

    final glassCardBg = isDark
        ? Colors.white.withValues(alpha: 0.075)
        : Colors.white.withValues(alpha: 0.78);
    final glassCardBorder = isDark
        ? Colors.white.withValues(alpha: 0.14)
        : Colors.black.withValues(alpha: 0.06);

    final bottomPad = math.max(24.0, MediaQuery.paddingOf(context).bottom + 18.0);

    return ClipRect(
      key: const Key('ios-live-portrait-companion-sheet'),
      child: Stack(
        fit: StackFit.expand,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: isDark
                    ? const [
                        Color(0xFF171B26),
                        Color(0xFF0F1219),
                        Color(0xFF090B10),
                      ]
                    : const [
                        Color(0xFFE7ECF6),
                        Color(0xFFF1F4FA),
                        Color(0xFFF5F7FC),
                      ],
              ),
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: 22,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.black.withValues(alpha: isDark ? 0.36 : 0.14),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),
          ),
          LayoutBuilder(
            builder: (ctx, sheetBox) {
              final textScale =
                  MediaQuery.textScalerOf(ctx).scale(14.0) / 14.0;
              final contentWidth = math.max(200.0, sheetBox.maxWidth - 32.0);
              final cols = contentWidth >= 660
                  ? 3
                  : (contentWidth >= 320 && textScale <= 1.35 ? 2 : 1);
              return ListenableBuilder(
                listenable: Listenable.merge(<Listenable>[
                  _liveCompanionGroupNotifier,
                  _liveCompanionQueryNotifier,
                ]),
                builder: (ctx, _) {
                  final rawGroup = _liveCompanionGroupNotifier.value;
                  final effectiveGroupName = rawGroup.isNotEmpty &&
                          groups.any((g) => g.name == rawGroup)
                      ? rawGroup
                      : (groups.any((g) => g.name == activeGroup)
                          ? activeGroup
                          : (groups.isNotEmpty ? groups.first.name : activeGroup));
                  final selectedGroupIdx = groups.isEmpty
                      ? 0
                      : math.max(
                          0,
                          groups.indexWhere((g) => g.name == effectiveGroupName),
                        );
                  final query =
                      _liveCompanionQueryNotifier.value.trim().toLowerCase();
                  final visibleChannels = groups.isEmpty
                      ? const <LiveChannel>[]
                      : (query.isNotEmpty
                          ? [
                              for (final g in groups)
                                for (final ch in g.channels)
                                  if (ch.name.toLowerCase().contains(query) ||
                                      g.name.toLowerCase().contains(query))
                                    ch,
                            ]
                          : groups[selectedGroupIdx].channels);
                  final rowCount = (visibleChannels.length / cols).ceil();

                  return CustomScrollView(
                    slivers: [
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
                        sliver: SliverToBoxAdapter(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
              // 1. Active Channel Header Card
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: glassCardBg,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: glassCardBorder, width: 0.8),
                  boxShadow: isDark
                      ? null
                      : [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.045),
                            blurRadius: 14,
                            offset: const Offset(0, 4),
                          ),
                        ],
                ),
                child: Builder(
                  builder: (_) {
                    final compactHeader =
                        contentWidth < 340 || textScale >= 1.35;
                    final statusBadge = Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: statusColor.withValues(alpha: 0.16),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 6,
                            height: 6,
                            decoration: BoxDecoration(
                              color: statusColor,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 4),
                          Flexible(
                            child: Text(
                              statusLabel,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: statusColor,
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                    final metaWrap = Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        statusBadge,
                        if (activeGroup.isNotEmpty)
                          Text(
                            activeGroup,
                            style: TextStyle(
                              color: palette.labelSecondary,
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        Text(
                          '· ${_usingAvPlayer ? "AVPlayer" : "MPV"}',
                          style: TextStyle(
                            color: palette.labelTertiary,
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (activeLatency != null)
                          Text(
                            '· $activeLatency',
                            style: TextStyle(
                              color: palette.labelTertiary,
                              fontSize: 11.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                      ],
                    );
                    final fullscreenButton = GestureDetector(
                      key: const Key('ios-portrait-companion-fullscreen-btn'),
                      onTap: _toggleOrientation,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 11,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: palette.accent.withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              CupertinoIcons.fullscreen,
                              size: 13,
                              color: palette.accent,
                            ),
                            const SizedBox(width: 4),
                            Flexible(
                              child: Text(
                                '全屏',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: palette.accent,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (compactHeader) ...[
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              LiveStationBadge(
                                channel: activeCh,
                                size: 46,
                                radius: 12,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  activeName,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: palette.labelPrimary,
                                    fontSize: 19,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: -0.35,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          SizedBox(
                            width: double.infinity,
                            child: Wrap(
                              spacing: 8,
                              runSpacing: 6,
                              alignment: WrapAlignment.spaceBetween,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                metaWrap,
                                fullscreenButton,
                              ],
                            ),
                          ),
                        ] else
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              LiveStationBadge(
                                channel: activeCh,
                                size: 46,
                                radius: 12,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      activeName,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: palette.labelPrimary,
                                        fontSize: 19,
                                        fontWeight: FontWeight.w800,
                                        letterSpacing: -0.35,
                                      ),
                                    ),
                                    const SizedBox(height: 5),
                                    metaWrap,
                                  ],
                                ),
                              ),
                              const SizedBox(width: 8),
                              fullscreenButton,
                            ],
                          ),
                        if (_fusedSpecBadges.isNotEmpty) ...[
                          const SizedBox(height: 10),
                          InlineSpecBadgeRow(
                            badges: _fusedSpecBadges,
                            expanded: true,
                            concentric: true,
                            reduceTransparency: _storageReduceTransparency,
                          ),
                        ],
                      ],
                    );
                  },
                ),
              ),
              const SizedBox(height: 12),

              // 2. Quick Live Actions Bar (PiP / Cast / Engine / Reconnect)
              if (contentWidth < 340 || textScale >= 1.35)
                Column(
                  children: [
                    Row(
                      children: [
                        _CompanionActionChip(
                          key: const Key('ios-live-companion-pip-btn'),
                          icon: isPipActive
                              ? CupertinoIcons.rectangle_fill_on_rectangle_fill
                              : CupertinoIcons.rectangle_on_rectangle,
                          label: isPipActive ? '画中画中' : '画中画',
                          active: isPipActive,
                          activeColor: palette.accent,
                          palette: palette,
                          onTap: () => unawaited(_handleIosPipTap()),
                        ),
                        const SizedBox(width: 8),
                        _CompanionActionChip(
                          key: const Key('ios-live-companion-cast-btn'),
                          icon: CupertinoIcons.tv,
                          label: _castController.isCasting ? '投屏中' : '投屏',
                          active: _castController.isCasting,
                          activeColor: palette.accent,
                          palette: palette,
                          onTap: () => _handleCastTap(null),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        _CompanionActionChip(
                          key: const Key('ios-live-companion-engine-btn'),
                          icon: CupertinoIcons.bolt_fill,
                          label: _usingAvPlayer ? 'AVPlayer' : 'MPV',
                          active: _usingAvPlayer,
                          activeColor: palette.accent,
                          palette: palette,
                          onTap: () => unawaited(_toggleIosEngine()),
                        ),
                        const SizedBox(width: 8),
                        _CompanionActionChip(
                          key: const Key('ios-live-companion-reload-btn'),
                          icon: CupertinoIcons.refresh,
                          label: '重连',
                          palette: palette,
                          onTap: () {
                            _showHud('正在重新连接 $activeName…');
                            unawaited(_openCurrentEpisode(resumeMs: 0));
                          },
                        ),
                      ],
                    ),
                  ],
                )
              else
                Row(
                  children: [
                    _CompanionActionChip(
                      key: const Key('ios-live-companion-pip-btn'),
                      icon: isPipActive
                          ? CupertinoIcons.rectangle_fill_on_rectangle_fill
                          : CupertinoIcons.rectangle_on_rectangle,
                      label: isPipActive ? '画中画中' : '画中画',
                      active: isPipActive,
                      activeColor: palette.accent,
                      palette: palette,
                      onTap: () => unawaited(_handleIosPipTap()),
                    ),
                    const SizedBox(width: 8),
                    _CompanionActionChip(
                      key: const Key('ios-live-companion-cast-btn'),
                      icon: CupertinoIcons.tv,
                      label: _castController.isCasting ? '投屏中' : '投屏',
                      active: _castController.isCasting,
                      activeColor: palette.accent,
                      palette: palette,
                      onTap: () => _handleCastTap(null),
                    ),
                    const SizedBox(width: 8),
                    _CompanionActionChip(
                      key: const Key('ios-live-companion-engine-btn'),
                      icon: CupertinoIcons.bolt_fill,
                      label: _usingAvPlayer ? 'AVPlayer' : 'MPV',
                      active: _usingAvPlayer,
                      activeColor: palette.accent,
                      palette: palette,
                      onTap: () => unawaited(_toggleIosEngine()),
                    ),
                    const SizedBox(width: 8),
                    _CompanionActionChip(
                      key: const Key('ios-live-companion-reload-btn'),
                      icon: CupertinoIcons.refresh,
                      label: '重连',
                      palette: palette,
                      onTap: () {
                        _showHud('正在重新连接 $activeName…');
                        unawaited(_openCurrentEpisode(resumeMs: 0));
                      },
                    ),
                  ],
                ),

              // 3. Signal Lines Switcher (1-tap live line switch)
              if (episodes.isNotEmpty) ...[
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                  decoration: BoxDecoration(
                    color: glassCardBg,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: glassCardBorder, width: 0.8),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: double.infinity,
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 4,
                          alignment: WrapAlignment.spaceBetween,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  CupertinoIcons.antenna_radiowaves_left_right,
                                  size: 15,
                                  color: palette.accent,
                                ),
                                const SizedBox(width: 6),
                                Flexible(
                                  child: Text(
                                    '信号线路',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: palette.labelPrimary,
                                      fontSize: 14.5,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            Text(
                              '当前 ${_episodeIndex + 1}/${episodes.length}',
                              style: TextStyle(
                                color: palette.labelTertiary,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 10),
                      SizedBox(
                        height: math.max(36.0, 20.0 * textScale + 18.0),
                        child: ListView.separated(
                          scrollDirection: Axis.horizontal,
                          itemCount: episodes.length,
                          separatorBuilder: (_, __) => const SizedBox(width: 8),
                          itemBuilder: (_, idx) {
                            final selected = idx == _episodeIndex;
                            final rawName = episodes[idx].name.trim();
                            final lineLabel = rawName.isNotEmpty
                                ? rawName
                                : '线路 ${idx + 1}';
                            return Semantics(
                              button: true,
                              selected: selected,
                              label: '切换直播$lineLabel',
                              child: GestureDetector(
                                key: ValueKey('ios-live-line-chip-$idx'),
                                behavior: HitTestBehavior.opaque,
                                onTap: () {
                                  if (selected) return;
                                  HapticFeedback.selectionClick();
                                  setState(() => _episodeIndex = idx);
                                  _showHud('已切换至 $lineLabel');
                                  unawaited(_openCurrentEpisode(resumeMs: 0));
                                },
                                child: AnimatedContainer(
                                  duration: MediaQuery.disableAnimationsOf(context)
                                      ? Duration.zero
                                      : const Duration(milliseconds: 160),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 13,
                                    vertical: 7,
                                  ),
                                  decoration: BoxDecoration(
                                    color: selected
                                        ? palette.accent
                                        : (isDark
                                            ? Colors.white.withValues(alpha: 0.08)
                                            : Colors.black.withValues(alpha: 0.05)),
                                    borderRadius: BorderRadius.circular(11),
                                    border: Border.all(
                                      color: selected
                                          ? palette.accent
                                          : glassCardBorder,
                                      width: 0.8,
                                    ),
                                  ),
                                  alignment: Alignment.center,
                                  child: Text(
                                    lineLabel,
                                    style: TextStyle(
                                      color: selected
                                          ? Colors.white
                                          : palette.labelPrimary,
                                      fontSize: 12.5,
                                      fontWeight: selected
                                          ? FontWeight.w700
                                          : FontWeight.w500,
                                    ),
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ],

              // 4. Inline Searchable Live Channel Browser (lazy SliverList)
              if (groups.isNotEmpty) ...[
                const SizedBox(height: 16),
                Wrap(
                  spacing: 6,
                  runSpacing: 2,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      '频道列表',
                      style: TextStyle(
                        color: palette.labelPrimary,
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      '共 $totalChannels 台',
                      style: TextStyle(
                        color: palette.labelTertiary,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                CupertinoSearchTextField(
                  key: const Key('ios-live-companion-search'),
                  controller: _liveCompanionSearchCtrl,
                  placeholder: '搜索频道名或分组…',
                  style: TextStyle(
                    color: palette.labelPrimary,
                    fontSize: 14,
                  ),
                  placeholderStyle: TextStyle(
                    color: palette.labelTertiary,
                    fontSize: 13.5,
                  ),
                  backgroundColor: isDark
                      ? Colors.white.withValues(alpha: 0.09)
                      : Colors.white.withValues(alpha: 0.86),
                  onChanged: (v) => _liveCompanionQueryNotifier.value = v,
                ),
                if (query.isEmpty && groups.length > 1) ...[
                  const SizedBox(height: 10),
                  SizedBox(
                    height: math.max(34.0, 19.0 * textScale + 16.0),
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: groups.length,
                      separatorBuilder: (_, __) => const SizedBox(width: 8),
                      itemBuilder: (_, idx) {
                        final g = groups[idx];
                        final sel = idx == selectedGroupIdx;
                        return GestureDetector(
                          key: ValueKey('ios-live-group-pill-$idx'),
                          behavior: HitTestBehavior.opaque,
                          onTap: () {
                            HapticFeedback.selectionClick();
                            _liveCompanionGroupNotifier.value = g.name;
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color: sel
                                  ? palette.accent
                                  : (isDark
                                      ? Colors.white.withValues(alpha: 0.08)
                                      : Colors.white.withValues(alpha: 0.72)),
                              borderRadius: BorderRadius.circular(999),
                              border: Border.all(
                                color: sel ? palette.accent : glassCardBorder,
                                width: 0.7,
                              ),
                            ),
                            alignment: Alignment.center,
                            child: Text(
                              '${g.name} (${g.channels.length})',
                              style: TextStyle(
                                color: sel
                                    ? Colors.white
                                    : palette.labelSecondary,
                                fontSize: 12,
                                fontWeight:
                                    sel ? FontWeight.w700 : FontWeight.w500,
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                if (visibleChannels.isEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 28,
                    ),
                    decoration: BoxDecoration(
                      color: glassCardBg,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: glassCardBorder, width: 0.8),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      '未找到匹配的直播频道',
                      style: TextStyle(
                        color: palette.labelSecondary,
                        fontSize: 13.5,
                      ),
                    ),
                  ),
              ] else ...[
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: glassCardBg,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: glassCardBorder, width: 0.8),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        CupertinoIcons.info_circle,
                        size: 17,
                        color: palette.labelSecondary,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          '右侧上下滑动可直接调节设备音量，点击上方「画中画」或「全屏」可随时切换观看模式。',
                          style: TextStyle(
                            color: palette.labelSecondary,
                            fontSize: 12.5,
                            height: 1.4,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
                            ],
                          ),
                        ),
                      ),
                      if (groups.isNotEmpty && visibleChannels.isNotEmpty)
                        SliverPadding(
                          padding: EdgeInsets.fromLTRB(16, 0, 16, bottomPad),
                          sliver: SliverList.builder(
                            itemCount: rowCount,
                            itemBuilder: (_, r) {
                              const spacing = 10.0;
                              return Padding(
                                padding: EdgeInsets.only(
                                  bottom: r < rowCount - 1 ? spacing : 0,
                                ),
                                child: Row(
                                  children: [
                                    for (var c = 0; c < cols; c++) ...[
                                      if (c > 0) const SizedBox(width: spacing),
                                      Expanded(
                                        child: (r * cols + c) < visibleChannels.length
                                            ? () {
                                                final ch =
                                                    visibleChannels[r * cols + c];
                                                final isCurrent =
                                                    ch.name == activeName &&
                                                        ch.group == activeGroup;
                                                final lat =
                                                    LiveHealthVisual.badgeText(ch);
                                                return RepaintBoundary(
                                                  child: GestureDetector(
                                                    key: ValueKey(
                                                      'ios-live-channel-card-${ch.group}-${ch.name}',
                                                    ),
                                                    behavior:
                                                        HitTestBehavior.opaque,
                                                    onTap: () {
                                                      HapticFeedback
                                                          .selectionClick();
                                                      _switchLiveChannel(ch);
                                                    },
                                                    child: Container(
                                                      padding:
                                                          const EdgeInsets.symmetric(
                                                        horizontal: 10,
                                                        vertical: 9,
                                                      ),
                                                      decoration: BoxDecoration(
                                                        color: isCurrent
                                                            ? palette.accent
                                                                .withValues(
                                                                  alpha: isDark
                                                                      ? 0.22
                                                                      : 0.13,
                                                                )
                                                            : glassCardBg,
                                                        borderRadius:
                                                            BorderRadius.circular(
                                                          14,
                                                        ),
                                                        border: Border.all(
                                                          color: isCurrent
                                                              ? palette.accent
                                                              : glassCardBorder,
                                                          width: isCurrent
                                                              ? 1.2
                                                              : 0.75,
                                                        ),
                                                      ),
                                                      child: Row(
                                                        children: [
                                                          LiveStationBadge(
                                                            channel: ch,
                                                            size: 36,
                                                            radius: 9,
                                                          ),
                                                          const SizedBox(width: 9),
                                                          Expanded(
                                                            child: Column(
                                                              crossAxisAlignment:
                                                                  CrossAxisAlignment
                                                                      .start,
                                                              mainAxisSize:
                                                                  MainAxisSize.min,
                                                              children: [
                                                                Text(
                                                                  ch.name,
                                                                  maxLines: 1,
                                                                  overflow:
                                                                      TextOverflow
                                                                          .ellipsis,
                                                                  style: TextStyle(
                                                                    color: isCurrent
                                                                        ? palette
                                                                            .accent
                                                                        : palette
                                                                            .labelPrimary,
                                                                    fontSize: 13.5,
                                                                    fontWeight: isCurrent
                                                                        ? FontWeight
                                                                            .w700
                                                                        : FontWeight
                                                                            .w600,
                                                                  ),
                                                                ),
                                                                const SizedBox(
                                                                  height: 2,
                                                                ),
                                                                Text(
                                                                  [
                                                                    '${ch.urls.length} 路信号',
                                                                    if (lat != null)
                                                                      lat,
                                                                  ].join(' · '),
                                                                  maxLines: 1,
                                                                  overflow:
                                                                      TextOverflow
                                                                          .ellipsis,
                                                                  style: TextStyle(
                                                                    color: palette
                                                                        .labelTertiary,
                                                                    fontSize: 11,
                                                                    fontWeight:
                                                                        FontWeight
                                                                            .w500,
                                                                  ),
                                                                ),
                                                              ],
                                                            ),
                                                          ),
                                                          if (isCurrent) ...[
                                                            const SizedBox(width: 4),
                                                            Icon(
                                                              CupertinoIcons
                                                                  .waveform,
                                                              size: 14,
                                                              color: palette.accent,
                                                            ),
                                                          ],
                                                        ],
                                                      ),
                                                    ),
                                                  ),
                                                );
                                              }()
                                            : const SizedBox.shrink(),
                                      ),
                                    ],
                                  ],
                                ),
                              );
                            },
                          ),
                        )
                      else
                        SliverToBoxAdapter(
                          child: SizedBox(height: bottomPad),
                        ),
                    ],
                  );
                },
              );
            },
          ),
        ],
      ),
    );
  }

  /// Tencent-Video-style iOS portrait companion sheet below the top 16:9
  /// cinema player box (title, synopsis, circular actor avatars, quick actions,
  /// line selector, and episode grid).
  Widget _buildIosPortraitCompanionSheet(BuildContext context) {
    if (_isLiveStream) {
      return _buildIosLivePortraitCompanionSheet(context);
    }
    final palette = ApplePalette.of(context);
    final episodes = _currentLine.episodes;
    final metaParts = <String>[
      if (widget.video.year.trim().isNotEmpty) widget.video.year.trim(),
      if (widget.video.area.trim().isNotEmpty) widget.video.area.trim(),
      if (widget.video.remarks.trim().isNotEmpty) widget.video.remarks.trim(),
      if (widget.video.doubanScore != null)
        '豆瓣 ${widget.video.doubanScore!.toStringAsFixed(1)}',
    ];
    final cleanDesc = widget.video.description
        .replaceAll(RegExp(r'<[^>]*>'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    final isDark = palette.isDark;
    final glassCardBg = isDark
        ? Colors.white.withValues(alpha: 0.085)
        : const Color(0x96F8F9FC);
    final glassCardBorder = isDark
        ? Colors.white.withValues(alpha: 0.16)
        : Colors.white.withValues(alpha: 0.62);
    final glassChipBg = isDark
        ? Colors.white.withValues(alpha: 0.09)
        : const Color(0xA4F8F9FC);

    return ClipRect(
      key: const Key('ios-portrait-companion-sheet'),
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Base poster-tinted frosted glass backdrop (柔和渐变毛玻璃质感)
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: isDark
                    ? const [
                        Color(0xFF1A1E2A),
                        Color(0xFF10121A),
                        Color(0xFF090A0F),
                      ]
                    : const [
                        Color(0xFFCCD5E6),
                        Color(0xFFD9E0EC),
                        Color(0xFFE3E7F0),
                      ],
              ),
            ),
          ),
          if (_activeVideo.poster.trim().isNotEmpty ||
              (!_isPrivateBackdrop && _activeVideo.title.trim().isNotEmpty))
            Positioned.fill(
              child: IgnorePointer(
                child: RepaintBoundary(
                  child: Opacity(
                    opacity: isDark ? 0.44 : 0.58,
                    child: ImageFiltered(
                      imageFilter: ImageFilter.blur(
                        sigmaX: _isIosPlayerPlatform ? 22 : 44,
                        sigmaY: _isIosPlayerPlatform ? 22 : 44,
                        tileMode: TileMode.decal,
                      ),
                      child: PosterImage(
                        url: _activeVideo.poster,
                        title: _isPrivateBackdrop ? '' : _activeVideo.title,
                        year: _isPrivateBackdrop ? '' : _activeVideo.year,
                        fit: BoxFit.cover,
                        forBackdrop: true,
                        isPrivate: _isPrivateBackdrop,
                        placeholder: const SizedBox.shrink(),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          Positioned.fill(
            child: IgnorePointer(
              child: _isIosPlayerPlatform
                  ? DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: isDark
                              ? const [
                                  Color(0xB8141720),
                                  Color(0xDC0E1018),
                                  Color(0xF0090A0F),
                                ]
                              : const [
                                  Color(0x88CED7E8),
                                  Color(0xB5D9DFEC),
                                  Color(0xD8E3E7F0),
                                ],
                          stops: const [0.0, 0.42, 1.0],
                        ),
                      ),
                    )
                  : BackdropFilter(
                      filter: ImageFilter.blur(
                        sigmaX: _storageReduceTransparency ? 0.0 : 28.0,
                        sigmaY: _storageReduceTransparency ? 0.0 : 28.0,
                      ),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: isDark
                                ? const [
                                    Color(0xB8141720),
                                    Color(0xDC0E1018),
                                    Color(0xF0090A0F),
                                  ]
                                : const [
                                    Color(0x88CED7E8),
                                    Color(0xB5D9DFEC),
                                    Color(0xD8E3E7F0),
                                  ],
                            stops: const [0.0, 0.42, 1.0],
                          ),
                        ),
                      ),
                    ),
            ),
          ),
          // Soft cinema-edge seam gradient from top 16:9 video frame into glass
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: 24,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.black.withValues(alpha: isDark ? 0.38 : 0.16),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),
          ),
          ListView(
        padding: EdgeInsets.fromLTRB(
          0,
          14,
          0,
          math.max(24, MediaQuery.paddingOf(context).bottom + 16),
        ),
        children: [
          // 1. Title + compact spec badges + metadata
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(
                      child: Text(
                        _activeVideo.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: palette.labelPrimary,
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.35,
                          height: 1.2,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    GestureDetector(
                      key: const Key('ios-portrait-companion-fullscreen-btn'),
                      onTap: _toggleOrientation,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          color: palette.accent.withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              CupertinoIcons.fullscreen,
                              size: 13,
                              color: palette.accent,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              '全屏',
                              style: TextStyle(
                                color: palette.accent,
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 5,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (metaParts.isNotEmpty)
                      Text(
                        metaParts.join(' · '),
                        style: TextStyle(
                          color: palette.labelSecondary,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    if (_fusedSpecBadges.isNotEmpty)
                      InlineSpecBadgeRow(
                        badges: _fusedSpecBadges,
                        expanded: true,
                        concentric: true,
                        reduceTransparency: _storageReduceTransparency,
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                // Quick action pills bar
                Row(
                  children: [
                    _CompanionActionChip(
                      icon: _isFavorite
                          ? CupertinoIcons.heart_fill
                          : CupertinoIcons.heart,
                      label: _isFavorite ? '已收藏' : '收藏',
                      active: _isFavorite,
                      activeColor: AppleColors.systemPink,
                      palette: palette,
                      onTap: () => unawaited(_handleFavoriteTap(null)),
                    ),
                    const SizedBox(width: 6),
                    _CompanionActionChip(
                      key: const Key('ios-vod-companion-pip-btn'),
                      icon: (_usingAvPlayer &&
                              (_iosAvPlayerController?.isPipActive ?? false))
                          ? CupertinoIcons.rectangle_fill_on_rectangle_fill
                          : CupertinoIcons.rectangle_on_rectangle,
                      label: (_usingAvPlayer &&
                              (_iosAvPlayerController?.isPipActive ?? false))
                          ? '画中画中'
                          : '画中画',
                      active: _usingAvPlayer &&
                          (_iosAvPlayerController?.isPipActive ?? false),
                      activeColor: palette.accent,
                      palette: palette,
                      onTap: () => unawaited(_handleIosPipTap()),
                    ),
                    const SizedBox(width: 6),
                    _CompanionActionChip(
                      icon: CupertinoIcons.tv,
                      label: _castController.isCasting ? '投屏中' : '投屏',
                      active: _castController.isCasting,
                      activeColor: palette.accent,
                      palette: palette,
                      onTap: () => _handleCastTap(null),
                    ),
                    const SizedBox(width: 6),
                    _CompanionActionChip(
                      icon: CupertinoIcons.arrow_down_circle,
                      label: '下载',
                      palette: palette,
                      onTap: () => _handleDownloadTap(null),
                    ),
                    const SizedBox(width: 6),
                    _CompanionActionChip(
                      icon: CupertinoIcons.speedometer,
                      label: IosPlayerChrome.formatSpeedBadge(
                        _castController.isCasting
                            ? _castController.speed
                            : _normalSpeed,
                      ),
                      active: ((_castController.isCasting
                                  ? _castController.speed
                                  : _normalSpeed) -
                              1.0)
                          .abs() >
                          0.01,
                      activeColor: palette.accent,
                      palette: palette,
                      onTap: () => _showSpeedSheet(),
                    ),
                  ],
                ),
                if (cleanDesc.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  GestureDetector(
                    onTap: () => setState(
                      () => _portraitSynopsisExpanded = !_portraitSynopsisExpanded,
                    ),
                    behavior: HitTestBehavior.opaque,
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: glassCardBg,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: glassCardBorder,
                          width: 0.85,
                        ),
                        boxShadow: isDark
                            ? null
                            : [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.04),
                                  blurRadius: 12,
                                  offset: const Offset(0, 4),
                                ),
                              ],
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            cleanDesc,
                            maxLines: _portraitSynopsisExpanded ? null : 3,
                            overflow: _portraitSynopsisExpanded
                                ? TextOverflow.visible
                                : TextOverflow.ellipsis,
                            style: TextStyle(
                              color: palette.labelSecondary,
                              fontSize: 13,
                              height: 1.48,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            _portraitSynopsisExpanded ? '收起简介' : '展开简介',
                            style: TextStyle(
                              color: palette.accent,
                              fontSize: 11.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 18),

          // 2. Circular Actor Avatar Cast List (Req 8)
          CastAvatarSection(
            title: _activeVideo.title,
            actorRaw: _activeVideo.actor,
            year: _activeVideo.year,
          ),
          const SizedBox(height: 18),

          // 3. Lines & Episodes Selector (Req 8)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      '选集',
                      style: TextStyle(
                        color: palette.labelPrimary,
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '共 ${episodes.length} 集',
                      style: TextStyle(
                        color: palette.labelTertiary,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          if (!_isLiveStream) ...[
                            GestureDetector(
                              key: const Key('ios-portrait-episode-scrape-btn'),
                              onTap: () => unawaited(_showEpisodeScrapeSheet()),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: _episodeScrapeOverride.enabled ||
                                          !_episodeScrapeOverride.isDefault
                                      ? palette.accent.withValues(alpha: 0.18)
                                      : glassChipBg,
                                  borderRadius: BorderRadius.circular(999),
                                  border: Border.all(
                                    color: _episodeScrapeOverride.enabled ||
                                            !_episodeScrapeOverride.isDefault
                                        ? palette.accent.withValues(alpha: 0.6)
                                        : glassCardBorder,
                                    width: 0.75,
                                  ),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      CupertinoIcons.sparkles,
                                      size: 11.5,
                                      color: palette.accent,
                                    ),
                                    const SizedBox(width: 3),
                                    Text(
                                      '刮削',
                                      style: TextStyle(
                                        color: palette.accent,
                                        fontSize: 11.5,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                          ],
                          Flexible(
                            child: Text(
                              _currentLine.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.end,
                              style: TextStyle(
                                color: palette.accent,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                if (_lines.length > 1) ...[
                  const SizedBox(height: 10),
                  SizedBox(
                    height: 32,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: _lines.length,
                      separatorBuilder: (_, __) => const SizedBox(width: 8),
                      itemBuilder: (context, idx) {
                        final selected = idx == _lineIndex;
                        return GestureDetector(
                          onTap: () {
                            if (selected) return;
                            HapticFeedback.selectionClick();
                            _switchToLineWithConflictGuard(idx);
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color: selected
                                  ? palette.accent.withValues(alpha: 0.18)
                                  : glassChipBg,
                              borderRadius: BorderRadius.circular(999),
                              border: Border.all(
                                color: selected
                                    ? palette.accent.withValues(alpha: 0.65)
                                    : glassCardBorder,
                                width: 0.85,
                              ),
                            ),
                            child: Text(
                              _lines[idx].name,
                              style: TextStyle(
                                color: selected
                                    ? palette.accent
                                    : palette.labelSecondary,
                                fontSize: 12,
                                fontWeight:
                                    selected ? FontWeight.w700 : FontWeight.w500,
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final scrapedLine = _scrapeCurrentLine();
                    final visibleIndices = scrapedLine.visibleRawIndices;
                    final displayLabels = <int, String>{
                      for (final rawIdx in visibleIndices)
                        rawIdx: scrapedLine.items[rawIdx].compactLabel(
                          singleItemMovie: visibleIndices.length <= 1,
                        ),
                    };
                    final maxNameLen = visibleIndices.fold<int>(
                      0,
                      (prev, rawIdx) => math.max(
                        prev,
                        (displayLabels[rawIdx] ?? episodes[rawIdx].name)
                            .trim()
                            .length,
                      ),
                    );
                    const gap = 8.0;
                    final cols = maxNameLen <= 5
                        ? (constraints.maxWidth >= 420 ? 6 : 5)
                        : (maxNameLen <= 8
                            ? (constraints.maxWidth >= 420 ? 4 : 3)
                            : (constraints.maxWidth >= 540 ? 3 : 2));
                    final cellWidth = math.max(
                      52.0,
                      (constraints.maxWidth - gap * (cols - 1)) / cols,
                    );
                    return Wrap(
                      spacing: gap,
                      runSpacing: gap,
                      children: [
                        for (final i in visibleIndices)
                          GestureDetector(
                            key: Key('ios-portrait-episode-$i'),
                            onTap: () {
                              if (i == _episodeIndex) return;
                              HapticFeedback.selectionClick();
                              _failedLinesForEpisode.clear();
                              _saveProgress(
                                immediate: true,
                                syncImmediate: false,
                              );
                              setState(() => _episodeIndex = i);
                              _openCurrentEpisode(resumeMs: 0);
                            },
                            child: Container(
                              width: cellWidth,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 9,
                              ),
                              decoration: BoxDecoration(
                                color: i == _episodeIndex
                                    ? palette.accent
                                    : glassChipBg,
                                borderRadius: BorderRadius.circular(11),
                                border: Border.all(
                                  color: i == _episodeIndex
                                      ? palette.accent
                                      : glassCardBorder,
                                  width: 0.85,
                                ),
                              ),
                              child: Text(
                                displayLabels[i] ?? episodes[i].name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: i == _episodeIndex
                                      ? Colors.white
                                      : palette.labelPrimary,
                                  fontSize: 12.5,
                                  fontWeight: i == _episodeIndex
                                      ? FontWeight.w700
                                      : FontWeight.w500,
                                ),
                              ),
                            ),
                          ),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
        ],
      ),
        ],
      ),
    );
  }

  Widget _buildPlaybackErrorCardContent(BuildContext context) {
    return Column(
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
          _activeSite,
          _playbackErrorCause,
        )) ...[
          SourceVerificationButton(
            key: ValueKey('verification-$_playSession'),
            client: _client,
            site: _activeSite,
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
            if (_canStepLiveChannel)
              AppleCapsuleButton(
                key: const ValueKey('live-error-next-channel'),
                label: '下一台',
                icon: CupertinoIcons.forward_end_fill,
                compact: true,
                onPressed: () => _stepLiveChannel(1),
              ),
            if (_isWindowsPlayerPlatform && widget.debugPlayer == null)
              AppleCapsuleButton(
                label: _videoKernel.isMdk ? '切回 MPV 重试' : '切换 MDK 核显重试',
                icon: CupertinoIcons.desktopcomputer,
                compact: true,
                onPressed: () {
                  _failedLinesForEpisode.clear();
                  _failedLiveEpisodes.clear();
                  _failedQualityUrls.clear();
                  unawaited(
                    _switchWindowsPlaybackEngine(
                      _videoKernel.isMdk
                          ? WindowsPlaybackEngine.mpv
                          : WindowsPlaybackEngine.mdk,
                      persist: false,
                    ),
                  );
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
            if (!_isLiveStream)
              AppleCapsuleButton(
                label: '网盘扫码配置',
                icon: CupertinoIcons.qrcode_viewfinder,
                compact: true,
                onPressed: () => showNetdiskAccountSheet(
                  context,
                  widget.storage,
                  initialDriveKey: _currentEpisode.cloudProvider,
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
    );
  }

  Widget _buildLockedOverlay(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final isLandscape = size.width > size.height;
    final scale = _desktopScale(size);
    final leftInset = _desktop
        ? 20.0
        : (isLandscape ? 16.0 : 14.0) * scale;
    final reduceTransparency = _isEffectiveReduceTransparency(context);
    final innerRow = Row(
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
    );
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
              child: reduceTransparency
                  ? Container(
                      padding: EdgeInsets.symmetric(
                        horizontal: 15 * scale,
                        vertical: 10.5 * scale,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xF51E1E22),
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.48),
                          width: 1.0,
                        ),
                      ),
                      child: innerRow,
                    )
                  : AppleGlassSurface(
                      padding: EdgeInsets.symmetric(
                        horizontal: 15 * scale,
                        vertical: 10.5 * scale,
                      ),
                      borderRadius: BorderRadius.circular(999),
                      backgroundColor: const Color(0xCC181A22),
                      child: innerRow,
                    ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFloatingLockEntryButton(double scale) {
    final reduceTransparency = _isEffectiveReduceTransparency(context);
    final iconCenter = Center(
      child: Icon(
        CupertinoIcons.lock_open_fill,
        color: AppleColors.labelPrimary,
        size: 19 * scale,
      ),
    );
    return Tooltip(
      message: '锁定屏幕',
      child: CupertinoButton(
        key: const Key('player-lock-button'),
        padding: EdgeInsets.zero,
        minimumSize: Size.square(44 * scale),
        onPressed: () => _setScreenLocked(true),
        child: reduceTransparency
            ? Container(
                width: 44 * scale,
                height: 44 * scale,
                decoration: BoxDecoration(
                  color: const Color(0xF51E1E22),
                  borderRadius: BorderRadius.circular(22 * scale),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.48),
                    width: 1.0,
                  ),
                ),
                child: iconCenter,
              )
            : AppleGlassSurface(
                width: 44 * scale,
                height: 44 * scale,
                padding: EdgeInsets.zero,
                borderRadius: BorderRadius.circular(22 * scale),
                backgroundColor: const Color(0x9920222A),
                child: iconCenter,
              ),
      ),
    );
  }

  Widget _buildAppleChromeOverlay(
    BuildContext context, {
    bool portraitCompanionBox = false,
  }) {
    if (_useIos26PlayerChrome) {
      final size = MediaQuery.sizeOf(context);
      final isLandscape = size.width > size.height;
      final effectiveDur = _duration.inMilliseconds > 0
          ? _duration
          : Duration(milliseconds: _lastKnownDurationMs);
      final activeSpeed = _gestureFsm.isSpeedLocked
          ? _gestureFsm.activeSpeed
          : _normalSpeed;
      final currentDownload = _isLiveStream
          ? null
          : DownloadService.instance.taskFor(
              _activeSite.key,
              _activeVideo.id,
              _currentLine.name,
              _episodeIndex,
            );
      return IosPlayerChrome(
        title: _displayTitle,
        episodeName: _isMultiVersionMovie
            ? _currentScrapedEpisode().movieVersionLabel
            : _currentEpisode.name,
        lineName: _currentLine.name,
        isLive: _isLiveStream,
        playing: _playing,
        loading: _loading,
        buffering: _buffering,
        hasError: _playbackError.isNotEmpty,
        position: _position,
        duration: effectiveDur,
        isScrubbing: _isDraggingSeek || _isSliderDragging,
        scrubPositionMs:
            _isSliderDragging ? _sliderDragPosMs.round() : _dragTargetPosMs,
        playbackSpeed: activeSpeed,
        skipIntroSec: _skipIntroSec,
        skipOutroSec: _skipOutroSec,
        specBadges: _fusedSpecBadges,
        fallbackSpecsLabel: _videoSpecsLabel,
        specBadgesExpanded: _startSpecController.highlightActive,
        isLandscape: isLandscape,
        portraitCompanionBox: portraitCompanionBox,
        danmuEnabled: widget.onToggleDanmu != null
            ? widget.danmuEnabled
            : (!OhosRuntime.isOhos && _danmuSettings.effectiveEnabled),
        sleepTimerActive: _sleepTimer.isActive,
        hasMultipleLines: _lines.length > 1 || _hasLiveChannelCatalog,
        isFavorite: _isFavorite,
        isCasting: _castController.isCasting,
        isDownloading: currentDownload != null &&
            (currentDownload.isActive ||
                currentDownload.status == DownloadStatus.completed),
        storageReduceTransparency: _storageReduceTransparency,
        isPipSupported:
            _isIosPlayerPlatform &&
            (_iosAvPlayerController?.isPipSupported ?? false),
        isPipActive:
            _usingAvPlayer && (_iosAvPlayerController?.isPipActive ?? false),
        onPipTap: _isIosPlayerPlatform
            ? () => unawaited(_handleIosPipTap())
            : null,
        engineLabel: _activeIosEngineBadgeLabel,
        isAvPlayerActive: _usingAvPlayer,
        onEngineSwitchTap: _isIosPlayerPlatform
            ? () => _showIosEnginePickerSheet()
            : null,
        onEngineSwitchAnchoredTap: _isIosPlayerPlatform
            ? (rect) => _showIosEnginePickerSheet(anchorRect: rect)
            : null,
        vocalLoudnessLabel: _vocalLoudness.shortLabelZh,
        vocalLoudnessActive: _vocalLoudness != VocalLoudnessPreset.off,
        onVocalLoudnessTap: () => _showVocalLoudnessSheet(),
        onVocalLoudnessAnchoredTap: (rect) =>
            _showVocalLoudnessSheet(anchorRect: rect),
        toolbarItems: _iosToolbarItems,
        isMultiVersionMovie: _isMultiVersionMovie,
        subtitleOverlayActive: _hasActiveAiSubtitleOverlay,
        anime4kActive: _anime4kController.iosLightweightEnabled,
        showAiAssistantButton: _isIosPlayerPlatform &&
            !_isLiveStream &&
            !_activeSite.isEffectivelyPrivate &&
            !widget.site.isEffectivelyPrivate &&
            !AiService.instance.isPrivacySessionActive &&
            AiService.instance.isLabUnlocked,
        onAiAssistantTap: () => _showIosPlayerAiPopover(),
        onAiAssistantAnchoredTap: (rect) =>
            _showIosPlayerAiPopover(anchorRect: rect),
        onAudioTracksTap: () => _showAudioTracksSheet(),
        onAudioTracksAnchoredTap: (rect) =>
            _showAudioTracksSheet(anchorRect: rect),
        onSkipIntroOutroTap: () => _showSkipIntroOutroQuickPopover(),
        onSkipIntroOutroAnchoredTap: (rect) =>
            _showSkipIntroOutroQuickPopover(anchorRect: rect),
        onAnime4kTap: _toggleIosAnime4kQuick,
        onAnime4kAnchoredTap: (_) => _toggleIosAnime4kQuick(),
        onSleepTimerTap: () => _showSleepTimerSheet(),
        onSleepTimerAnchoredTap: (rect) =>
            _showSleepTimerSheet(anchorRect: rect),
        onBack: () async {
          await _saveProgress(immediate: true);
          if (context.mounted) {
            _exitPlayer();
          }
        },
        onPlayPause: () {
          if (_playing && _gestureFsm.isSpeedLocked) {
            final unlock = _gestureFsm.cancel(
              GestureInterruptReason.playbackPaused,
            );
            _applyGestureEvents(unlock);
          }
          _enginePlayOrPause();
          _scheduleHide();
        },
        onRewind15: () => _seekRelative(-15),
        onForward15: () => _seekRelative(15),
        onScrubStart: (ms) {
          _hideTimer?.cancel();
          setState(() {
            _isSliderDragging = true;
            _sliderDragPosMs = ms;
          });
        },
        onScrubUpdate: (ms) {
          setState(() {
            _isSliderDragging = true;
            _sliderDragPosMs = ms;
          });
        },
        onScrubEnd: (ms) {
          final maxMs = effectiveDur.inMilliseconds;
          final targetMs = maxMs > 0 ? ms.round().clamp(0, maxMs) : 0;
          setState(() {
            _isSliderDragging = false;
            _position = Duration(milliseconds: targetMs);
          });
          _seekPlayer(
            Duration(milliseconds: targetMs),
            saveProgressOnSuccess: true,
          );
          _scheduleHide();
        },
        onScrubCancel: () {
          _resetSliderDraggingSafe(scheduleHide: true);
        },
        onEpisodesTap: _showEpisodesSheet,
        onLinesTap: _showLinesSheet,
        onSpeedTap: _showSpeedSheet,
        onDanmuToggle: _handleDanmuToggle,
        onDanmuSettingsTap: () => _showDanmuAndSubtitleQuickPopover(),
        onAspectAndStrategyTap: _showAspectAndStrategySheet,
        onAudioSubtitleTap: _showAudioSubtitleQuickSheet,
        onMoreTap: _showIosMoreMenu,
        onLockTap: () => _setScreenLocked(true),
        onFullscreenToggle: _toggleOrientation,
        onInteraction: _scheduleHide,
        onCastTap: _handleCastTap,
        onFavoriteTap: (rect) => unawaited(_handleFavoriteTap(rect)),
        onDownloadTap: _handleDownloadTap,
        onMoreAnchoredTap: (rect) => _showIosMoreMenu(anchorRect: rect),
        onSpeedAnchoredTap: (rect) => _showSpeedSheet(anchorRect: rect),
        onEpisodesAnchoredTap: (rect) => _showEpisodesSheet(anchorRect: rect),
        onLinesAnchoredTap: (rect) => _showLinesSheet(anchorRect: rect),
        onDanmuSettingsAnchoredTap: (rect) =>
            _showDanmuAndSubtitleQuickPopover(anchorRect: rect),
        onAspectAnchoredTap: (rect) =>
            _showAspectAndStrategySheet(anchorRect: rect),
        onAudioSubtitleAnchoredTap: (rect) =>
            _showAudioSubtitleQuickSheet(anchorRect: rect),
      );
    }
    if (isWindowsDesktopUi && WindowsAppearanceScope.maybeOf(context) != null) {
      return _buildWindowsChrome(context);
    }
    if (_isMacosPlayerPlatform) {
      return _buildMacosChrome(context);
    }
    final size = MediaQuery.sizeOf(context);
    final isLandscape = size.width > size.height;
    final showLeftLockButton = isLandscape && size.width >= 480;
    final scale = _desktopScale(size);
    final leftInset = _desktop
        ? 20.0
        : (isLandscape ? 16.0 : 14.0) * scale;
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

  bool _windowsMoreControls = false;

  Stream<double>? _safePlayerVolumeStream() {
    try {
      return _player.stream.volume;
    } catch (_) {
      return null;
    }
  }

  void _toggleDesktopMute() {
    if (_engineVolume100 > 0) {
      _previousVolume = _engineVolume100;
      _engineSetVolume100(0);
      _showHud('静音');
    } else {
      final restore = _previousVolume > 0 ? _previousVolume : 100.0;
      _engineSetVolume100(restore);
      _showHud('音量 ${restore.round()}%');
    }
    if (mounted) setState(() {});
    _scheduleHide();
  }

  void _showWindowsVolume() {
    _cancelTransientInteractions(GestureInterruptReason.dialogOpened);
    showAppleModalSheet<void>(context: context, title: '音量', maxWidth: 420,
      builder: (_) => StreamBuilder<double>(stream: _safePlayerVolumeStream(),
        initialData: _engineVolume100, builder: (context, snapshot) =>
          Padding(padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text('${(snapshot.data ?? 100).round()}%',
                style: const TextStyle(color: Colors.white)),
              Slider(value: (snapshot.data ?? 100).clamp(0, 100), max: 100,
                label: '${(snapshot.data ?? 100).round()}%', onChanged: _engineSetVolume100),
            ]))));
  }

  Widget _buildDesktopLockButton(double scale) {
    final btnSize = (44.0 * scale).clamp(38.0, 46.0);
    return Tooltip(
      message: '锁定屏幕',
      child: CupertinoButton(
        key: const Key('player-lock-button'),
        padding: EdgeInsets.zero,
        minimumSize: Size.square(btnSize),
        onPressed: () => _setScreenLocked(true),
        child: Container(
          width: btnSize,
          height: btnSize,
          decoration: BoxDecoration(
            color: const Color(0xB8141821),
            shape: BoxShape.circle,
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.22),
              width: 1.0,
            ),
            boxShadow: const [
              BoxShadow(
                color: Color(0x55000000),
                blurRadius: 14,
                offset: Offset(0, 4),
              ),
            ],
          ),
          alignment: Alignment.center,
          child: Icon(
            CupertinoIcons.lock_open_fill,
            color: AppleColors.labelPrimary,
            size: (18.0 * scale).clamp(16.0, 19.0),
          ),
        ),
      ),
    );
  }

  Widget _buildDesktopFullWidthProgressBar(BuildContext context, double scale) {
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

    return SizedBox(
      key: const Key('player-progress-bar'),
      height: 30,
      child: Row(
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 10),
            child: Text(
              _formatDuration(activeDuration),
              maxLines: 1,
              softWrap: false,
              style: const TextStyle(
                color: Color(0xE6FFFFFF),
                fontSize: 12.5,
                fontWeight: FontWeight.w500,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ),
          Expanded(
            child: Stack(
              alignment: Alignment.center,
              children: [
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 4.0,
                    thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: 6.5,
                    ),
                    overlayShape: const RoundSliderOverlayShape(
                      overlayRadius: 13.0,
                    ),
                    activeTrackColor: const Color(0xFF4C9AFF),
                    inactiveTrackColor: const Color(0x42FFFFFF),
                    thumbColor: Colors.white,
                    overlayColor: const Color(0x284C9AFF),
                  ),
                  child: Slider(
                    focusNode: _desktop ? _desktopSliderFocusNode : null,
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
                            _seekPlayer(
                              Duration(milliseconds: targetMs),
                              saveProgressOnSuccess: true,
                            );
                            if (_desktop) {
                              _restorePlayerFocusIfCurrent();
                            }
                            _scheduleHide();
                          }
                        : null,
                  ),
                ),
                if (_blurayChapters.isNotEmpty && hasDuration)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 13),
                        child: CustomPaint(
                          painter: _BlurayChapterTickPainter(
                            chapters: _blurayChapters,
                            durationMs: effectiveDurationMs,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(left: 10),
            child: Text(
              hasDuration ? _formatDuration(totalDuration) : '--:--',
              maxLines: 1,
              softWrap: false,
              textAlign: TextAlign.end,
              style: const TextStyle(
                color: Color(0xB8FFFFFF),
                fontSize: 12.5,
                fontWeight: FontWeight.w500,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showBlurayChaptersSheet() {
    if (_blurayChapters.isEmpty) return;
    _cancelTransientInteractions(GestureInterruptReason.dialogOpened);
    final session = _playSession;
    showAppleModalSheet<void>(
      context: context,
      title: '蓝光原盘章节（${_blurayChapters.length}）',
      maxWidth: 460,
      builder: (ctx) => ListView.builder(
        shrinkWrap: true,
        padding: const EdgeInsets.all(16),
        itemCount: _blurayChapters.length,
        itemBuilder: (_, i) {
          final ch = _blurayChapters[i];
          return AppleGroupedTile(
            key: ValueKey('bluray-chapter-${ch.index}'),
            icon: CupertinoIcons.bookmark_fill,
            iconBgColor: AppleColors.systemBlue,
            title: ch.title.isNotEmpty ? ch.title : '第 ${ch.index + 1} 章',
            trailingText: _formatDuration(ch.position),
            onTap: () {
              Navigator.of(ctx).pop();
              if (!mounted || session != _playSession) return;
              _seekPlayer(ch.position);
              _showHud(
                '章节：${ch.title.isNotEmpty ? ch.title : "第 ${ch.index + 1} 章"} (${_formatDuration(ch.position)})',
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildDesktopMoreMenuPopover(BuildContext context, double width) {
    final live = _isLiveStream;
    final danmuEnabled = widget.onToggleDanmu != null
        ? widget.danmuEnabled
        : (!OhosRuntime.isOhos && _danmuSettings.effectiveEnabled);
    final winQualityAvailable = _isWindowsPlayerPlatform &&
        _winQualityController.isAvailableForPlayer(_player);
    final visibility = DesktopHudBarVisibility.forWidth(
      width,
      isLive: live,
      danmuAvailable: !OhosRuntime.isOhos,
      anime4kAvailable: _anime4kAvailable,
      videoQualityAvailable: winQualityAvailable,
      audioLoudnessAvailable: winQualityAvailable,
    );

    void closeAndRun(VoidCallback fn) {
      setState(() => _windowsMoreControls = false);
      fn();
    }

    final overflowItems = <Widget>[
      if (!live && !visibility.showSpeed)
        DesktopMoreMenuRow(
          icon: CupertinoIcons.speedometer,
          label: '播放倍速',
          valueText: '${_normalSpeed}×',
          active: _normalSpeed != 1.0,
          onTap: () => closeAndRun(_showSpeedSheet),
        ),
      if (!live && !OhosRuntime.isOhos && !visibility.showDanmu)
        DesktopMoreMenuRow(
          icon: danmuEnabled
              ? CupertinoIcons.chat_bubble_text_fill
              : CupertinoIcons.chat_bubble_text,
          label: '弹幕开关',
          valueText: danmuEnabled ? '已开启' : '已关闭',
          active: danmuEnabled,
          onTap: () => _handleDanmuToggle(),
        ),
      if (!live && !visibility.showSubtitles)
        DesktopMoreMenuRow(
          icon: CupertinoIcons.captions_bubble,
          label: '字幕选择',
          onTap: () => closeAndRun(_showSubtitleTracksSheet),
        ),
      if (_anime4kAvailable && !visibility.showAnime4k)
        DesktopMoreMenuRow(
          icon: CupertinoIcons.wand_stars,
          label: 'Anime4K 画质增强',
          valueText: _anime4kController.preset == Anime4kPreset.off
              ? '关闭'
              : _anime4kController.preset.labelZh,
          active: _anime4kController.preset != Anime4kPreset.off,
          onTap: () => closeAndRun(_showAnime4kSheet),
        ),
      if (_useEnhancedHud && !visibility.showSleepTimer)
        DesktopMoreMenuRow(
          icon: CupertinoIcons.moon_zzz_fill,
          label: '定时关闭',
          valueText: _sleepTimer.isActive ? _sleepTimer.shortStatusLabel : '未开启',
          active: _sleepTimer.isActive,
          onTap: () => closeAndRun(_showSleepTimerSheet),
        ),
    ];

    final aspectSection = Padding(
      padding: const EdgeInsets.fromLTRB(14, 4, 14, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '画面比例',
            style: TextStyle(
              color: Color(0x99FFFFFF),
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              for (final item in const [
                (BoxFit.contain, '适应'),
                (BoxFit.cover, '裁切'),
                (BoxFit.fill, '铺满'),
              ])
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.only(
                      right: item.$1 == BoxFit.fill ? 0 : 6,
                    ),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: () {
                        _setFit(item.$1);
                        _showHud('画面比例：${item.$2}');
                      },
                      child: Container(
                        height: 32,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: _fit == item.$1
                              ? const Color(0xFF2D4364)
                              : Colors.white.withValues(alpha: 0.06),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: _fit == item.$1
                                ? const Color(0xFF4C9AFF)
                                : Colors.white.withValues(alpha: 0.08),
                          ),
                        ),
                        child: Text(
                          item.$2,
                          style: TextStyle(
                            color: _fit == item.$1
                                ? Colors.white
                                : const Color(0xCCFFFFFF),
                            fontSize: 12.5,
                            fontWeight: _fit == item.$1
                                ? FontWeight.w600
                                : FontWeight.w500,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );

    final trackSection = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_lines.length > 1 || _hasLiveChannelCatalog || !live)
          DesktopMoreMenuRow(
            icon: CupertinoIcons.layers_alt,
            label: _hasLiveChannelCatalog ? '切换频道' : '切换线路',
            valueText: _hasLiveChannelCatalog ? _displayTitle : _currentLine.name,
            onTap: () => closeAndRun(_showLinesSheet),
          ),
        if (_qualityChoices.length > 1)
          DesktopMoreMenuRow(
            icon: CupertinoIcons.sparkles,
            label: '清晰度切换',
            onTap: () => closeAndRun(_showQualityChoices),
          ),
        if (_blurayChapters.isNotEmpty)
          DesktopMoreMenuRow(
            icon: CupertinoIcons.bookmark,
            label: '蓝光章节',
            valueText: '${_blurayChapters.length} 章',
            onTap: () => closeAndRun(_showBlurayChaptersSheet),
          ),
        DesktopMoreMenuRow(
          icon: CupertinoIcons.speaker_2,
          label: '音轨选择',
          onTap: () => closeAndRun(_showAudioTracksSheet),
        ),
        if (_isWindowsPlayerPlatform)
          DesktopMoreMenuRow(
            key: const ValueKey('windows-more-engine-switch'),
            icon: CupertinoIcons.desktopcomputer,
            label: '播放引擎',
            valueText: _windowsEngine == WindowsPlaybackEngine.mdk
                ? 'MDK 核显'
                : 'MPV 旗舰',
            active: _windowsEngine == WindowsPlaybackEngine.mdk,
            onTap: () => closeAndRun(_showWindowsEngineSheet),
          ),
        DesktopMoreMenuRow(
          icon: CupertinoIcons.slider_horizontal_3,
          label: '播放策略',
          valueText: _kernelShortLabel,
          active: _playerKernel != 'exo',
          onTap: () => closeAndRun(_showKernelSheet),
        ),
      ],
    );

    final playbackSection = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!live) ...[
          DesktopMoreMenuRow(
            icon: CupertinoIcons.forward_fill,
            label: '跳过片头',
            valueText: _skipIntroSec > 0 ? '${_skipIntroSec}s' : '未设置',
            active: _skipIntroSec > 0,
            onTap: () => closeAndRun(_showSkipIntroSheet),
          ),
          DesktopMoreMenuRow(
            icon: CupertinoIcons.forward_end_alt_fill,
            label: '跳过片尾',
            valueText: _skipOutroSec > 0 ? '${_skipOutroSec}s' : '未设置',
            active: _skipOutroSec > 0,
            onTap: () => closeAndRun(_showSkipOutroSheet),
          ),
          DesktopMoreMenuRow(
            icon: CupertinoIcons.repeat,
            label: '自动连播下一集',
            active: _autoNext,
            trailing: Icon(
              _autoNext
                  ? CupertinoIcons.checkmark_circle_fill
                  : CupertinoIcons.circle,
              size: 17,
              color: _autoNext
                  ? AppleColors.systemCyan
                  : const Color(0x66FFFFFF),
            ),
            onTap: _toggleAutoNext,
          ),
          DesktopMoreMenuRow(
            icon: CupertinoIcons.arrow_2_squarepath,
            label: '循环模式',
            valueText: _repeatLabel,
            active: _repeatMode == 'one' || _repeatMode == 'all',
            onTap: _cycleRepeatMode,
          ),
          if (!OhosRuntime.isOhos)
            DesktopMoreMenuRow(
              icon: CupertinoIcons.slider_horizontal_below_rectangle,
              label: '弹幕详细设置',
              onTap: () => closeAndRun(_handleDanmuSettingsTap),
            ),
        ],
        DesktopMoreMenuRow(
          icon: CupertinoIcons.clock,
          label: '右上角常显时间',
          active: _alwaysShowClock,
          trailing: Icon(
            _alwaysShowClock
                ? CupertinoIcons.checkmark_circle_fill
                : CupertinoIcons.circle,
            size: 17,
            color: _alwaysShowClock
                ? AppleColors.systemCyan
                : const Color(0x66FFFFFF),
          ),
          onTap: _toggleAlwaysShowClock,
        ),
        DesktopMoreMenuRow(
          icon: CupertinoIcons.refresh,
          label: live ? '刷新直播流' : '从头重播',
          onTap: () => closeAndRun(() {
            if (live) {
              _openCurrentEpisode();
              _showHud('正在刷新直播流…');
            } else {
              _seekPlayer(Duration.zero);
              _enginePlay();
              _showHud('已从头开始播放');
            }
          }),
        ),
      ],
    );

    return DesktopPlayerMorePopover(
      sections: [
        if (overflowItems.isNotEmpty)
          Column(mainAxisSize: MainAxisSize.min, children: overflowItems),
        if (winQualityAvailable && !visibility.showVideoQuality)
          DesktopVideoQualitySection(
            currentPreset: _winQualityController.qualityPreset,
            anime4kActive: _anime4kController.preset != Anime4kPreset.off,
            onSelected: (preset) {
              unawaited(() async {
                final anime4kActive =
                    _anime4kController.preset != Anime4kPreset.off;
                await _winQualityController.applyQualityPreset(
                  _player,
                  preset,
                  anime4kActive: anime4kActive,
                  playerKernel: _playerKernel,
                );
                if (mounted) _showHud('画质：${preset.labelZh}');
              }());
            },
          ),
        if (winQualityAvailable && !visibility.showAudioLoudness)
          DesktopAudioLoudnessSection(
            currentPreset: _winQualityController.loudnessPreset,
            onSelected: (preset) {
              unawaited(() async {
                final ok = await _winQualityController.applyLoudnessPreset(
                  _player,
                  preset,
                );
                if (!mounted) return;
                if (ok) {
                  _showHud(
                    '人声增强：${_winQualityController.loudnessPreset.labelZh}',
                  );
                } else {
                  _showHud(
                    _winQualityController.lastWarning ??
                        WindowsVideoQualityController.audioFallbackWarningZh,
                  );
                }
              }());
            },
          ),
        aspectSection,
        trackSection,
        playbackSection,
      ],
    );
  }

  Widget _buildWindowsChrome(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final scale = (width / 1280).clamp(.78, 1.0);
    final winQualityAvailable = _isWindowsPlayerPlatform &&
        _winQualityController.isAvailableForPlayer(_player);
    return DesktopPlayerHud(
      embedded: widget.embedded,
      title: _displayTitle,
      playing: _playing,
      isLive: _isLiveStream,
      isFullscreen: _desktopWindow?.fullscreen == true,
      normalSpeed: _normalSpeed,
      volume: _engineVolume100,
      volumeStream: _usingAvPlayer ? null : _safePlayerVolumeStream(),
      onVolumeChanged: (v) {
        final next = v.clamp(0.0, 100.0);
        _engineSetVolume100(next);
        if (mounted) setState(() {});
        _showHud('音量 ${next.round()}%');
        _scheduleHide();
      },
      onMuteToggle: _toggleDesktopMute,
      hasPrevEpisode: _adjacentVisibleEpisodeIndex(-1) != null,
      hasNextEpisode: _adjacentVisibleEpisodeIndex(1) != null,
      onPrevEpisode: () => _stepEpisode(-1),
      onNextEpisode: () => _stepEpisode(1),
      moreControlsOpen: _windowsMoreControls,
      sleepTimerActive: _sleepTimer.isActive,
      sleepTimerLabel: _sleepTimer.shortStatusLabel,
      danmuEnabled: widget.onToggleDanmu != null
          ? widget.danmuEnabled
          : (!OhosRuntime.isOhos && _danmuSettings.effectiveEnabled),
      onDanmuToggle: OhosRuntime.isOhos ? null : _handleDanmuToggle,
      onDanmuSettingsTap: OhosRuntime.isOhos ? null : _handleDanmuSettingsTap,
      anime4kVisible: _anime4kAvailable,
      anime4kActive: _anime4kController.preset != Anime4kPreset.off,
      anime4kLabel: _anime4kController.preset == Anime4kPreset.off
          ? 'Anime4K'
          : 'Anime4K·${_anime4kController.preset.labelZh}',
      onAnime4kTap: _anime4kAvailable ? _showAnime4kSheet : null,
      videoQualityVisible: winQualityAvailable,
      videoQualityActive:
          _winQualityController.qualityPreset != WindowsQualityPreset.ecoCompat,
      videoQualityPreset: _winQualityController.qualityPreset,
      onVideoQualityChanged: (preset) {
        unawaited(() async {
          final anime4kActive =
              _anime4kController.preset != Anime4kPreset.off;
          await _winQualityController.applyQualityPreset(
            _player,
            preset,
            anime4kActive: anime4kActive,
            playerKernel: _playerKernel,
          );
          if (mounted) _showHud('画质：${preset.labelZh}');
        }());
      },
      audioLoudnessVisible: winQualityAvailable,
      audioLoudnessActive:
          _winQualityController.loudnessPreset != AudioLoudnessPreset.off,
      audioLoudnessPreset: _winQualityController.loudnessPreset,
      onAudioLoudnessChanged: (preset) {
        unawaited(() async {
          final ok = await _winQualityController.applyLoudnessPreset(
            _player,
            preset,
          );
          if (!mounted) return;
          if (ok) {
            _showHud('人声增强：${_winQualityController.loudnessPreset.labelZh}');
          } else {
            _showHud(
              _winQualityController.lastWarning ??
                  WindowsVideoQualityController.audioFallbackWarningZh,
            );
          }
        }());
      },
      topHeader: _buildTopHeader(
        context,
        true,
        scale,
        includeLockButton: false,
        includeLiveFullscreen: false,
      ),
      lockButton: widget.embedded ? null : _buildDesktopLockButton(scale),
      progressBar: _isLiveStream
          ? null
          : _buildDesktopFullWidthProgressBar(context, scale),
      transportButtons: _buildCenterTransportButtons(scale),
      moreToolsDock: _buildDesktopMoreMenuPopover(context, width),
      onExit: _exitPlayer,
      onPlayPause: _enginePlayOrPause,
      onVolumeTap: _showWindowsVolume,
      onEpisodesTap: _showEpisodesSheet,
      onSwitchSourceTap: _isLiveStream ? null : _showCrossSiteSourcesSheet,
      onSpeedTap: _showSpeedSheet,
      onSubtitlesTap: _showSubtitleTracksSheet,
      onSleepTimerTap: _showSleepTimerSheet,
      onToggleMore: () {
        setState(() => _windowsMoreControls = !_windowsMoreControls);
        if (_windowsMoreControls && !widget.embedded) {
          _hideTimer?.cancel();
        } else {
          _scheduleHide();
        }
      },
      onCloseMore: () {
        if (!_windowsMoreControls) return;
        setState(() => _windowsMoreControls = false);
        _scheduleHide();
      },
      onToggleExpand: _toggleOrientation,
      onBottomControlsHeightChanged: _handleDesktopBottomControlsHeightChanged,
    );
  }

  /// macOS desktop cinema player HUD:
  /// - Reuses [DesktopPlayerHud] with easy-to-click full-width progress bar,
  ///   inline volume + wheel volume, keyboard hold scrub preview, subtitles,
  ///   4-tier Anime4K, compact anchored "More" popover, and native fullscreen.
  /// - Adds windowed top clearance (`28pt`) so the Back button & title never
  ///   collide with macOS traffic-light buttons; clears automatically in
  ///   native fullscreen.
  /// - Deliberately keeps Windows HDR (`videoQualityVisible`) and vocal boost
  ///   (`audioLoudnessVisible`) hidden on macOS pending Mac output/power eval.
  Widget _buildMacosChrome(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final scale = (width / 1280).clamp(.78, 1.0);
    final isFullscreen = _desktopWindow?.fullscreen == true;
    return Theme(
      data: Theme.of(context).copyWith(brightness: Brightness.dark),
      child: CupertinoTheme(
        data: CupertinoTheme.of(context).copyWith(brightness: Brightness.dark),
        child: Builder(
          builder: (darkContext) => DesktopPlayerHud(
            embedded: widget.embedded,
            topSafeInset: (!widget.embedded && !isFullscreen) ? 28.0 : 0.0,
            title: _displayTitle,
            playing: _playing,
            isLive: _isLiveStream,
            isFullscreen: isFullscreen,
            normalSpeed: _normalSpeed,
            volume: _engineVolume100,
            volumeStream: _usingAvPlayer ? null : _safePlayerVolumeStream(),
            onVolumeChanged: (v) {
              final next = v.clamp(0.0, 100.0);
              _engineSetVolume100(next);
              if (mounted) setState(() {});
              _showHud('音量 ${next.round()}%');
              _scheduleHide();
            },
            onMuteToggle: _toggleDesktopMute,
            hasPrevEpisode: _adjacentVisibleEpisodeIndex(-1) != null,
            hasNextEpisode: _adjacentVisibleEpisodeIndex(1) != null,
            onPrevEpisode: () => _stepEpisode(-1),
            onNextEpisode: () => _stepEpisode(1),
            moreControlsOpen: _windowsMoreControls,
            sleepTimerActive: _sleepTimer.isActive,
            sleepTimerLabel: _sleepTimer.shortStatusLabel,
            danmuEnabled: widget.onToggleDanmu != null
                ? widget.danmuEnabled
                : (!OhosRuntime.isOhos && _danmuSettings.effectiveEnabled),
            onDanmuToggle: OhosRuntime.isOhos ? null : _handleDanmuToggle,
            onDanmuSettingsTap:
                OhosRuntime.isOhos ? null : _handleDanmuSettingsTap,
            anime4kVisible: _anime4kAvailable,
            anime4kActive: _anime4kController.preset != Anime4kPreset.off,
            anime4kLabel: _anime4kController.preset == Anime4kPreset.off
                ? 'Anime4K'
                : 'Anime4K·${_anime4kController.preset.labelZh}',
            onAnime4kTap: _anime4kAvailable ? _showAnime4kSheet : null,
            videoQualityVisible: false,
            audioLoudnessVisible: false,
            topHeader: _buildTopHeader(
              darkContext,
              true,
              scale,
              includeLockButton: false,
              includeLiveFullscreen: false,
            ),
            lockButton: widget.embedded ? null : _buildDesktopLockButton(scale),
            progressBar: _isLiveStream
                ? null
                : _buildDesktopFullWidthProgressBar(darkContext, scale),
            transportButtons: _buildCenterTransportButtons(scale),
            moreToolsDock: _buildDesktopMoreMenuPopover(darkContext, width),
            onExit: _exitPlayer,
            onPlayPause: _enginePlayOrPause,
            onVolumeTap: _showWindowsVolume,
            onEpisodesTap: _showEpisodesSheet,
            onSpeedTap: _showSpeedSheet,
            onSubtitlesTap: _showSubtitleTracksSheet,
            onSleepTimerTap: _showSleepTimerSheet,
            onToggleMore: () {
              setState(() => _windowsMoreControls = !_windowsMoreControls);
              if (_windowsMoreControls && !widget.embedded) {
                _hideTimer?.cancel();
              } else {
                _scheduleHide();
              }
            },
            onCloseMore: () {
              if (!_windowsMoreControls) return;
              setState(() => _windowsMoreControls = false);
              _scheduleHide();
            },
            onToggleExpand: _toggleOrientation,
            onBottomControlsHeightChanged:
                _handleDesktopBottomControlsHeightChanged,
          ),
        ),
      ),
    );
  }

  Widget _buildTopHeader(
    BuildContext context,
    bool isLandscape,
    double scale, {
    bool includeLockButton = false,
    bool includeLiveFullscreen = true,
  }) {
    return Row(
      children: [
        CupertinoButton(
          padding: EdgeInsets.zero,
          minSize: 36 * scale,
          onPressed: () async {
            await _saveProgress(immediate: true);
            if (context.mounted) {
              _exitPlayer();
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
                      _displayTitle,
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
                  if (_useEnhancedHud && _fusedSpecBadges.isNotEmpty) ...[
                    SizedBox(width: 8 * scale),
                    InlineSpecBadgeRow(
                      badges: _fusedSpecBadges,
                      expanded: _startSpecController.highlightActive,
                      concentric: false,
                      reduceTransparency: _storageReduceTransparency,
                    ),
                  ] else if (_videoSpecsLabel.isNotEmpty) ...[
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
              Builder(
                builder: (_) {
                  final epInfo = _currentScrapedEpisodeInfo();
                  final rawFile = epInfo != null &&
                          epInfo.originalFileName.isNotEmpty
                      ? epInfo.originalFileName
                      : _currentEpisode.name;
                  final parts = <String>[
                    if (epInfo != null && !epInfo.isSpecial)
                      epInfo.formattedSeasonEpisode
                    else if (epInfo != null && epInfo.isSpecial)
                      epInfo.displayLabel,
                    if (rawFile.isNotEmpty &&
                        (epInfo == null ||
                            rawFile != epInfo.formattedSeasonEpisode &&
                                rawFile != epInfo.displayLabel))
                      rawFile,
                    _currentLine.name,
                  ];
                  return Text(
                    parts.join(' · '),
                    key: const Key('player-header-episode-label'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AppleColors.labelSecondary,
                      fontSize: 12 * scale,
                    ),
                  );
                },
              ),
            ],
          ),
        ),
        if (_isLiveStream && includeLiveFullscreen) ...[
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
          _enginePlayOrPause();
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
            _enginePlayOrPause();
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
    if (isWindowsDesktopUi) {
      return CupertinoButton(
        key: key,
        padding: EdgeInsets.zero,
        minimumSize: Size.square(size),
        onPressed: () {
          _scheduleHide();
          onTap();
        },
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: hero ? const Color(0xF2FFFFFF) : const Color(0xB8141821),
            shape: BoxShape.circle,
            border: Border.all(
              color: hero
                  ? Colors.white
                  : Colors.white.withValues(alpha: 0.22),
              width: 1.0,
            ),
            boxShadow: const [
              BoxShadow(
                color: Color(0x66000000),
                blurRadius: 18,
                offset: Offset(0, 6),
              ),
            ],
          ),
          alignment: Alignment.center,
          child: Icon(
            icon,
            color: hero ? const Color(0xFF10141B) : Colors.white,
            size: iconSize,
          ),
        ),
      );
    }
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
                  focusNode: _desktop ? _desktopSliderFocusNode : null,
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
                          _seekPlayer(
                            Duration(milliseconds: targetMs),
                            saveProgressOnSuccess: true,
                          );
                          if (_desktop) {
                            _restorePlayerFocusIfCurrent();
                          }
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
      if (_adjacentVisibleEpisodeIndex(-1) != null)
        _PlayerAction(
          CupertinoIcons.backward_end_fill,
          live ? '上源' : '上集',
          () => _stepEpisode(-1),
        ),
      if (_adjacentVisibleEpisodeIndex(1) != null)
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
      if (_lines.length > 1 || _hasLiveChannelCatalog || !live)
        _PlayerAction(
          CupertinoIcons.layers_alt_fill,
          _hasLiveChannelCatalog ? '频道' : '线路',
          _showLinesSheet,
        ),
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
      if (!live && !OhosRuntime.isOhos) ...[
        _PlayerAction(
          CupertinoIcons.chat_bubble_text_fill,
          (widget.onToggleDanmu != null
                  ? widget.danmuEnabled
                  : _danmuSettings.effectiveEnabled)
              ? '弹幕·开'
              : '弹幕·关',
          _handleDanmuToggle,
          shortLabel: '弹幕',
          active: widget.onToggleDanmu != null
              ? widget.danmuEnabled
              : _danmuSettings.effectiveEnabled,
        ),
        _PlayerAction(
          CupertinoIcons.slider_horizontal_below_rectangle,
          '弹幕设置',
          _handleDanmuSettingsTap,
          shortLabel: '弹幕设',
        ),
      ],
      if (_anime4kAvailable)
        _PlayerAction(
          CupertinoIcons.wand_stars,
          _anime4kController.preset == Anime4kPreset.off
              ? 'Anime4K·关'
              : 'Anime4K·${_anime4kController.preset.labelZh}',
          _showAnime4kSheet,
          shortLabel: 'A4K',
          active: _anime4kController.preset != Anime4kPreset.off,
        ),
      if (_useEnhancedHud)
        _PlayerAction(
          CupertinoIcons.moon_zzz_fill,
          _sleepTimer.isActive ? '定时·${_sleepTimer.shortStatusLabel}' : '定时关闭',
          _showSleepTimerSheet,
          shortLabel: '定时',
          active: _sleepTimer.isActive,
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
          _seekPlayer(Duration.zero);
          _enginePlay();
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
          return Listener(
            onPointerSignal: (event) {
              if (_desktop && event is PointerScrollEvent) {
                GestureBinding.instance.pointerSignalResolver.register(
                  event,
                  (_) {},
                );
              }
            },
            child: LiquidGlass(
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
            ),
          );
        },
      );
    }

    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: 740 * scale),
      child: Listener(
        onPointerSignal: (event) {
          if (_desktop && event is PointerScrollEvent) {
            GestureBinding.instance.pointerSignalResolver.register(
              event,
              (_) {},
            );
          }
        },
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
    if (!_usingAvPlayer) {
      unawaited(_syncNativeSubtitleState());
    }
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
    _cancelTransientInteractions(GestureInterruptReason.dialogOpened);
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
          _activeSite.key,
          _activeVideo.id,
          clamped,
          isPrivate: _activeSite.isEffectivelyPrivate,
        );
      } else {
        widget.storage.setVideoSkipOutroSec(
          _activeSite.key,
          _activeVideo.id,
          clamped,
          isPrivate: _activeSite.isEffectivelyPrivate,
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
                              ? '已优先默认设为当前时间 $formatted · 仅对《${_activeVideo.title}》独立生效'
                              : '独立记录 · 仅对《${_activeVideo.title}》生效，不影响其他影片',
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
    _cancelTransientInteractions(GestureInterruptReason.dialogOpened);
    final session = _playSession;
    final selected = await showAppleNativeActionSheet<CmsEpisode>(
      context,
      title: '切换画质',
      options: [
        for (final choice in _qualityChoices)
          AppleNativeSheetOption<CmsEpisode>(
            value: choice,
            title: choice.name,
            isDefault: _matchesActiveQuality(choice),
          ),
      ],
      cancelLabel: '取消',
    );
    if (!mounted ||
        session != _playSession ||
        selected == null ||
        _matchesActiveQuality(selected)) {
      return;
    }
    _failedQualityUrls
      ..remove(selected.url)
      ..remove(_normalizePlayStreamUrl(selected.url));
    final keepPos = _position.inMilliseconds >= 1000
        ? _position.inMilliseconds
        : _lastKnownPositionMs;
    await _openCurrentEpisode(
      resumeMs: keepPos,
      quality: selected,
      userSelectedQuality: true,
    );
  }

  void _showAudioTracksSheet({Rect? anchorRect}) {
    _cancelTransientInteractions(GestureInterruptReason.dialogOpened);
    if (_usingAvPlayer) {
      final avCtrl = _iosAvPlayerController;
      final tracks = avCtrl?.audioTracks ?? const <IosAvPlayerTrack>[];
      if (avCtrl == null || tracks.isEmpty) {
        _showHud('当前片源仅包含单一音轨');
        return;
      }
      if (_canUseNativeIosSheet) {
        final session = _playSession;
        unawaited(() async {
          final picked = await showAppleNativeOptionSheet<IosAvPlayerTrack>(
            context,
            title: '切换音轨',
            forceOpaque: _effectiveSheetForceOpaque,
            anchorRect: anchorRect,
            forceDark: true,
            options: [
              for (final t in tracks)
                AppleNativePickerOption<IosAvPlayerTrack>(
                  value: t,
                  title: t.title.trim().isNotEmpty
                      ? t.title.trim()
                      : (t.language.trim().isNotEmpty
                            ? t.language.trim()
                            : '音轨 ${t.id}'),
                  symbol: 'speaker.wave.2.fill',
                  checked: t.selected,
                ),
            ],
            fallback: () async {
              _showAvAudioTracksFallbackSheet(avCtrl, tracks);
              return null;
            },
          );
          if (!mounted || session != _playSession || picked == null) return;
          final label = picked.title.trim().isNotEmpty
              ? picked.title.trim()
              : (picked.language.trim().isNotEmpty
                    ? picked.language.trim()
                    : picked.id);
          await avCtrl.setAudioTrack(picked.id);
          _showHud('已切换音轨：$label');
        }());
        return;
      }
      _showAvAudioTracksFallbackSheet(avCtrl, tracks);
      return;
    }
    final tracks = _player.state.tracks.audio;
    final active = _player.state.track.audio;
    if (_canUseNativeIosSheet) {
      final session = _playSession;
      unawaited(() async {
        if (tracks.isEmpty) {
          _showHud('当前片源仅包含单一音轨');
          return;
        }
        final picked = await showAppleNativeOptionSheet<AudioTrack>(
          context,
          title: '切换音轨',
          forceOpaque: _effectiveSheetForceOpaque,
          anchorRect: anchorRect,
          forceDark: true,
          options: [
            for (final t in tracks)
              AppleNativePickerOption<AudioTrack>(
                value: t,
                title: (t.title ?? t.language ?? t.id).trim().isEmpty
                    ? '音轨 ${t.id}'
                    : (t.title ?? t.language ?? t.id).trim(),
                symbol: 'speaker.wave.2.fill',
                checked: t == active,
              ),
          ],
          fallback: () async {
            _showAudioTracksFallbackSheet(tracks, active);
            return null;
          },
        );
        if (!mounted || session != _playSession || picked == null) return;
        final label = (picked.title ?? picked.language ?? picked.id).trim();
        _player.setAudioTrack(picked);
        _showHud('已切换音轨：${label.isEmpty ? picked.id : label}');
      }());
      return;
    }
    _showAudioTracksFallbackSheet(tracks, active);
  }

  void _showAudioTracksFallbackSheet(
    List<AudioTrack> tracks,
    AudioTrack active,
  ) {
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

  void _showAvAudioTracksFallbackSheet(
    IosAvPlayerController avCtrl,
    List<IosAvPlayerTrack> tracks,
  ) {
    showAppleModalSheet<void>(
      context: context,
      title: '切换音轨',
      builder: (ctx) => ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.all(16),
        children: [
          AppleGroupedSection(
            children: tracks.map((t) {
              final label = t.title.trim().isNotEmpty
                  ? t.title.trim()
                  : (t.language.trim().isNotEmpty ? t.language.trim() : t.id);
              return AppleGroupedTile(
                icon: CupertinoIcons.speaker_2_fill,
                iconBgColor: t.selected
                    ? AppleColors.systemBlue
                    : AppleColors.groupedTertiary,
                title: label.isEmpty ? '音轨 ${t.id}' : label,
                trailing: t.selected
                    ? const Icon(
                        CupertinoIcons.checkmark_alt,
                        color: AppleColors.systemBlue,
                        size: 18,
                      )
                    : null,
                onTap: () {
                  Navigator.of(ctx).pop();
                  unawaited(avCtrl.setAudioTrack(t.id));
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
    _cancelTransientInteractions(GestureInterruptReason.dialogOpened);
    if (_usingAvPlayer) {
      final avCtrl = _iosAvPlayerController;
      final tracks = avCtrl?.subtitleTracks ?? const <IosAvPlayerTrack>[];
      if (avCtrl == null) {
        _showHud('当前播放器暂不支持切换内嵌字幕');
        return;
      }
      final hasSelected = tracks.any((t) => t.selected);
      if (_canUseNativeIosSheet) {
        final session = _playSession;
        unawaited(() async {
          final picked = await showAppleNativeOptionSheet<String>(
            context,
            title: '切换字幕',
            forceOpaque: _effectiveSheetForceOpaque,
            options: [
              AppleNativePickerOption<String>(
                value: '',
                title: '关闭内嵌字幕',
                symbol: 'captions.bubble',
                checked: !hasSelected,
              ),
              for (final t in tracks)
                AppleNativePickerOption<String>(
                  value: t.id,
                  title: t.title.trim().isNotEmpty
                      ? t.title.trim()
                      : (t.language.trim().isNotEmpty
                            ? t.language.trim()
                            : '字幕 ${t.id}'),
                  symbol: 'captions.bubble.fill',
                  checked: t.selected,
                ),
            ],
            fallback: () async {
              _showAvSubtitleTracksFallbackSheet(avCtrl, tracks);
              return null;
            },
          );
          if (!mounted || session != _playSession || picked == null) return;
          _clearAiLiveSubtitleLine();
          if (picked.isEmpty) {
            await avCtrl.setSubtitleTrack(null);
            _showHud('已关闭内嵌字幕');
          } else {
            await avCtrl.setSubtitleTrack(picked);
            final matched = tracks.where((t) => t.id == picked).firstOrNull;
            final label = matched?.title.trim().isNotEmpty == true
                ? matched!.title.trim()
                : (matched?.language.trim().isNotEmpty == true
                      ? matched!.language.trim()
                      : picked);
            _showHud('已切换字幕：$label');
          }
        }());
        return;
      }
      _showAvSubtitleTracksFallbackSheet(avCtrl, tracks);
      return;
    }
    final tracks = _player.state.tracks.subtitle;
    final active = _player.state.track.subtitle;
    if (_canUseNativeIosSheet) {
      final session = _playSession;
      unawaited(() async {
        final picked = await showAppleNativeOptionSheet<SubtitleTrack>(
          context,
          title: '切换字幕',
          forceOpaque: _effectiveSheetForceOpaque,
          options: [
            AppleNativePickerOption<SubtitleTrack>(
              value: SubtitleTrack.no(),
              title: '关闭内嵌字幕',
              symbol: 'captions.bubble',
              checked: active == SubtitleTrack.no(),
            ),
            for (final t in tracks)
              AppleNativePickerOption<SubtitleTrack>(
                value: t,
                title: (t.title ?? t.language ?? t.id).trim().isEmpty
                    ? '字幕 ${t.id}'
                    : (t.title ?? t.language ?? t.id).trim(),
                symbol: 'captions.bubble.fill',
                checked: t == active,
              ),
          ],
          fallback: () async {
            _showSubtitleTracksFallbackSheet(tracks, active);
            return null;
          },
        );
        if (!mounted || session != _playSession || picked == null) return;
        _clearAiLiveSubtitleLine();
        _player.setSubtitleTrack(picked);
        _scheduleSyncNativeSubtitleState();
        if (picked == SubtitleTrack.no()) {
          _showHud('已关闭内嵌字幕');
        } else {
          final label = (picked.title ?? picked.language ?? picked.id).trim();
          final isBitmap = MdkPlatformPlayer.isBitmapSubtitleCodec(picked.codec);
          if (isBitmap && _aiLiveEmbeddedTranslateEnabled) {
            _showHud(
              '已切换字幕：${label.isEmpty ? picked.id : label}（图形字幕无法提取文本实时翻译，可导入外挂 .srt/.ass）',
            );
          } else {
            _showHud('已切换字幕：${label.isEmpty ? picked.id : label}');
          }
        }
      }());
      return;
    }
    _showSubtitleTracksFallbackSheet(tracks, active);
  }

  void _showAvSubtitleTracksFallbackSheet(
    IosAvPlayerController avCtrl,
    List<IosAvPlayerTrack> tracks,
  ) {
    final hasSelected = tracks.any((t) => t.selected);
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
                iconBgColor: !hasSelected
                    ? AppleColors.systemBlue
                    : AppleColors.groupedTertiary,
                title: '关闭内嵌字幕',
                onTap: () {
                  Navigator.of(ctx).pop();
                  _clearAiLiveSubtitleLine();
                  unawaited(avCtrl.setSubtitleTrack(null));
                  _showHud('已关闭内嵌字幕');
                },
              ),
              ...tracks.map((t) {
                final label = t.title.trim().isNotEmpty
                    ? t.title.trim()
                    : (t.language.trim().isNotEmpty
                          ? t.language.trim()
                          : t.id);
                return AppleGroupedTile(
                  icon: CupertinoIcons.captions_bubble_fill,
                  iconBgColor: t.selected
                      ? AppleColors.systemBlue
                      : AppleColors.groupedTertiary,
                  title: label.isEmpty ? '字幕 ${t.id}' : label,
                  trailing: t.selected
                      ? const Icon(
                          CupertinoIcons.checkmark_alt,
                          color: AppleColors.systemBlue,
                          size: 18,
                        )
                      : null,
                  onTap: () {
                    Navigator.of(ctx).pop();
                    _clearAiLiveSubtitleLine();
                    unawaited(avCtrl.setSubtitleTrack(t.id));
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

  void _showSubtitleTracksFallbackSheet(
    List<SubtitleTrack> tracks,
    SubtitleTrack active,
  ) {
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
                  _clearAiLiveSubtitleLine();
                  _player.setSubtitleTrack(SubtitleTrack.no());
                  _scheduleSyncNativeSubtitleState();
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
                    _clearAiLiveSubtitleLine();
                    _player.setSubtitleTrack(t);
                    _scheduleSyncNativeSubtitleState();
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

  Future<void> _selectKernel(String key, String title) async {
    if (_playerKernel == key) return;
    final keepPos = _position.inMilliseconds >= 1000
        ? _position.inMilliseconds
        : _lastKnownPositionMs;
    setState(() => _playerKernel = key);
    await widget.storage.setPlayerKernel(key);
    _playerConfiguration = _playerConfiguration.then(
      (_) => _applyPlayerKernel(key),
    );
    await _playerConfiguration;
    if (!mounted) return;
    _showHud('已切换至 $title');
    unawaited(_openCurrentEpisode(resumeMs: keepPos));
  }

  void _showKernelSheet() {
    _cancelTransientInteractions(GestureInterruptReason.dialogOpened);
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
    if (_canUseNativeIosSheet) {
      final session = _playSession;
      unawaited(() async {
        final picked = await showAppleNativeOptionSheet<
            ({String key, String title, String subtitle})>(
          context,
          title: '切换播放策略',
          forceOpaque: _effectiveSheetForceOpaque,
          options: [
            for (final k in kernels)
              AppleNativePickerOption(
                value: k,
                title: k.title,
                subtitle: k.subtitle,
                symbol: 'slider.horizontal.3',
                checked: _playerKernel == k.key,
              ),
          ],
          fallback: () async {
            _showKernelFallbackSheet(kernels);
            return null;
          },
        );
        if (!mounted || session != _playSession || picked == null) return;
        await _selectKernel(picked.key, picked.title);
      }());
      return;
    }
    _showKernelFallbackSheet(kernels);
  }

  void _showKernelFallbackSheet(
    List<({String key, String title, String subtitle})> kernels,
  ) {
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
                  await _selectKernel(k.key, k.title);
                },
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  Future<void> _switchWindowsPlaybackEngine(
    WindowsPlaybackEngine next, {
    bool persist = true,
    int? resumeMsOverride,
    String? customToast,
  }) async {
    if (!_isWindowsPlayerPlatform) return;
    if (widget.debugPlayer != null &&
        widget.debugWindowsKernelFactory == null) {
      if (persist) {
        await widget.storage.setWindowsPlaybackEngine(next.id);
      }
      if (!mounted) return;
      setState(() => _windowsEngine = next);
      _showHud(customToast ?? '已切换至 ${next.labelZh}');
      return;
    }
    if (_switchingWindowsEngine) return;
    final alreadyTarget =
        _windowsEngine == next &&
        _videoKernel.isMdk == (next == WindowsPlaybackEngine.mdk);
    if (alreadyTarget) return;
    _switchingWindowsEngine = true;
    _userNavigationGen++;
    final keepPos = resumeMsOverride ?? _resolveFallbackResumePositionMs();
    final keepVolume = _engineVolume100;
    final session = ++_playSession;
    final activePlatform = _player.platform;
    if (activePlatform is MdkPlatformPlayer) {
      activePlatform.cancelPendingOpen();
    }
    _allowEvents = false;
    _hasVideoOutputForSession = false;
    if (next == WindowsPlaybackEngine.mdk) {
      _mdkFallbackTriggeredSession = -1;
      _mdkAutoFallbackMediaKeys.clear();
    }
    try {
      if (persist) {
        await widget.storage.setWindowsPlaybackEngine(next.id);
      }
      _winQualityController.detachPlayer();
      for (final sub in _playerSubscriptions) {
        unawaited(sub.cancel());
      }
      _playerSubscriptions.clear();
      final oldPlayer = _player;
      await _changeMedia(session, () async {
        try {
          if (!OhosRuntime.isOhos &&
              _anime4kController.isAvailableForPlayer(oldPlayer)) {
            await _anime4kController.resetSession(oldPlayer);
          }
        } catch (_) {}
        try {
          await oldPlayer.stop();
        } catch (_) {}
        if (!_playerDisposed) {
          _playerDisposed = true;
          try {
            await oldPlayer.dispose();
          } catch (_) {}
        }
      });
      if (!mounted || session != _playSession) return;
      final nextKernel = widget.debugWindowsKernelFactory?.call(next) ??
          VideoKernel.create(
            debugVideoSurface: widget.debugVideoSurface,
            hwdec: _hardwareDecoder(_playerKernel),
            windowsEngine: next,
            kernelStrategy: _playerKernel,
          );
      _videoKernel = nextKernel;
      _player = nextKernel.player;
      _playerDisposed = false;
      _attachPlayerStreams();
      setState(() {
        _windowsEngine = next;
        _loading = true;
        _playing = false;
        _buffering = false;
        _playbackError = '';
        _playbackErrorCause = null;
        _videoWidth = 0;
        _videoHeight = 0;
        _videoCodec = '';
        _audioCodec = '';
      });
      _playerConfiguration = _applyPlayerKernel(_playerKernel);
      await _playerConfiguration;
      if (!mounted || session != _playSession) return;
      await _player.setVolume(keepVolume);
      if (!OhosRuntime.isOhos &&
          !_videoKernel.isMdk &&
          _anime4kController.isAvailableForPlayer(_player)) {
        unawaited(_initAnime4kAfterKernel());
      }
      _showHud(customToast ?? '已切换至 ${next.labelZh}，正在续播…');
      unawaited(_openCurrentEpisode(resumeMs: keepPos));
    } finally {
      _switchingWindowsEngine = false;
    }
  }

  void _showWindowsEngineSheet() {
    if (!_isWindowsPlayerPlatform) return;
    _cancelTransientInteractions(GestureInterruptReason.dialogOpened);
    const engines = <WindowsPlaybackEngine>[
      WindowsPlaybackEngine.mdk,
      WindowsPlaybackEngine.mpv,
    ];
    showAppleModalSheet<void>(
      context: context,
      title: '切换 Windows 播放引擎',
      maxWidth: 500,
      builder: (ctx) => ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.all(16),
        children: [
          AppleGroupedSection(
            children: engines.map((engine) {
              final selected = _windowsEngine == engine;
              return AppleGroupedTile(
                key: ValueKey('player-engine-option-${engine.id}'),
                icon: engine == WindowsPlaybackEngine.mdk
                    ? CupertinoIcons.bolt_fill
                    : CupertinoIcons.sparkles,
                iconBgColor: selected
                    ? AppleColors.systemBlue
                    : AppleColors.groupedTertiary,
                title: engine.labelZh,
                subtitle: engine.descriptionZh,
                trailing: selected
                    ? const Icon(
                        CupertinoIcons.checkmark_alt,
                        color: AppleColors.systemBlue,
                        size: 18,
                      )
                    : null,
                onTap: () async {
                  Navigator.of(ctx).pop();
                  await _switchWindowsPlaybackEngine(engine);
                },
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  void _openTvPlayerControlSheet() {
    unawaited(
      showTvPlayerControlSheet(
        context: context,
        player: _player,
        currentSpeed: _normalSpeed,
        onSpeedSelected: (nextSpeed) {
          if (!mounted) return;
          final normalized = _normalizePlaybackSpeed(nextSpeed);
          setState(() => _normalSpeed = normalized);
          widget.storage.setPlaySpeed(normalized);
          final speedLabel =
              normalized.toString().replaceAll(RegExp(r'\.0$'), '');
          _showHud('倍速 ${speedLabel}x');
        },
        currentFit: _fit,
        onFitSelected: (nextFit) {
          if (!mounted) return;
          _setFit(nextFit);
          _showHud('画面比例：$_fitLabel');
        },
        onOpenEpisodes: _showEpisodesSheet,
        isLiveStream: _isLiveStream,
      ),
    );
  }

  void _showSpeedSheet({Rect? anchorRect}) {
    _cancelTransientInteractions(GestureInterruptReason.dialogOpened);
    final speeds = _supportedPlaybackSpeeds;
    if (_canUseNativeIosSheet) {
      final session = _playSession;
      unawaited(() async {
        final picked = await showAppleNativeOptionSheet<double>(
          context,
          title: '播放倍速',
          forceOpaque: _effectiveSheetForceOpaque,
          anchorRect: anchorRect,
          forceDark: true,
          options: [
            for (final s in speeds)
              AppleNativePickerOption<double>(
                value: s,
                title: '$s× 倍速',
                symbol: 'speedometer',
                checked: (_normalSpeed - s).abs() < 0.01,
              ),
          ],
          fallback: () async {
            _showSpeedFallbackSheet(speeds, anchorRect: anchorRect);
            return null;
          },
        );
        if (!mounted || session != _playSession || picked == null) return;
        _applyManualSpeed(picked);
      }());
      return;
    }
    _showSpeedFallbackSheet(speeds, anchorRect: anchorRect);
  }

  void _showSpeedFallbackSheet(List<double> speeds, {Rect? anchorRect}) {
    Widget buildContent(BuildContext ctx) => ListView(
      shrinkWrap: true,
      padding: EdgeInsets.all(_useIos26PlayerChrome ? 4 : 16),
      children: [
        AppleGroupedSection(
          children: speeds.map((s) {
            final selected = (_normalSpeed - s).abs() < 0.01;
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
                _applyManualSpeed(s);
              },
            );
          }).toList(),
        ),
      ],
    );
    if (_useIos26PlayerChrome) {
      showIosGlassPopover<void>(
        context: context,
        anchorRect: anchorRect,
        title: '播放倍速',
        maxWidth: 250,
        maxHeight: 310,
        forceDark: true,
        builder: buildContent,
      );
      return;
    }
    showAppleModalSheet<void>(
      context: context,
      title: '播放倍速',
      builder: buildContent,
    );
  }

  void _showSleepTimerSheet({Rect? anchorRect}) {
    _cancelTransientInteractions(GestureInterruptReason.dialogOpened);
    const modes = SleepTimerMode.values;
    if (_canUseNativeIosSheet) {
      final session = _playSession;
      unawaited(() async {
        final picked = await showAppleNativeOptionSheet<SleepTimerMode>(
          context,
          title: '定时关闭',
          subtitle: _sleepTimer.isActive
              ? '当前：${_sleepTimer.shortStatusLabel}'
              : '仅在本次播放会话生效',
          forceOpaque: _effectiveSheetForceOpaque,
          anchorRect: anchorRect,
          forceDark: true,
          options: [
            for (final m in modes)
              AppleNativePickerOption<SleepTimerMode>(
                value: m,
                title: m.label,
                symbol: m == SleepTimerMode.off ? 'moon' : 'moon.zzz.fill',
                checked: _sleepTimer.mode == m,
              ),
          ],
          fallback: () async {
            _showSleepTimerFallbackSheet(modes, anchorRect: anchorRect);
            return null;
          },
        );
        if (!mounted || session != _playSession || picked == null) return;
        _sleepTimer.setMode(picked);
        _showHud(
          picked == SleepTimerMode.off
              ? '已关闭定时关闭'
              : '定时关闭：${picked.label}',
        );
      }());
      return;
    }
    _showSleepTimerFallbackSheet(modes, anchorRect: anchorRect);
  }

  void _showSleepTimerFallbackSheet(
    List<SleepTimerMode> modes, {
    Rect? anchorRect,
  }) {
    Widget buildContent(BuildContext ctx) => ListView(
      shrinkWrap: true,
      padding: EdgeInsets.all(_useIos26PlayerChrome ? 4 : 16),
      children: [
        AppleGroupedSection(
          children: modes.map((m) {
            final selected = _sleepTimer.mode == m;
            return AppleGroupedTile(
              icon: CupertinoIcons.moon_zzz_fill,
              iconBgColor: selected
                  ? AppleColors.systemBlue
                  : AppleColors.groupedTertiary,
              title: m.label,
              trailing: selected
                  ? const Icon(
                      CupertinoIcons.checkmark_alt,
                      color: AppleColors.systemBlue,
                      size: 18,
                    )
                  : null,
              onTap: () {
                Navigator.of(ctx).pop();
                _sleepTimer.setMode(m);
                _showHud(
                  m == SleepTimerMode.off
                      ? '已关闭定时关闭'
                      : '定时关闭：${m.label}',
                );
              },
            );
          }).toList(),
        ),
      ],
    );
    if (_useIos26PlayerChrome) {
      showIosGlassPopover<void>(
        context: context,
        anchorRect: anchorRect,
        title: '定时关闭',
        maxWidth: 260,
        maxHeight: 300,
        forceDark: true,
        builder: buildContent,
      );
      return;
    }
    showAppleModalSheet<void>(
      context: context,
      title: '定时关闭',
      builder: buildContent,
    );
  }

  void _showAspectAndStrategySheet({Rect? anchorRect}) {
    _cancelTransientInteractions(GestureInterruptReason.dialogOpened);
    final options = <AppleNativePickerOption<String>>[
      AppleNativePickerOption<String>(
        value: 'fit:contain',
        title: '画面适应（默认）',
        symbol: 'rectangle.arrowtriangle.2.inward',
        checked: _fit == BoxFit.contain,
        section: 0,
        sectionTitle: '画面比例',
      ),
      AppleNativePickerOption<String>(
        value: 'fit:cover',
        title: '画面裁切填充',
        symbol: 'rectangle.arrowtriangle.2.outward',
        checked: _fit == BoxFit.cover,
        section: 0,
      ),
      AppleNativePickerOption<String>(
        value: 'fit:fill',
        title: '画面铺满屏幕',
        symbol: 'aspectratio',
        checked: _fit == BoxFit.fill,
        section: 0,
      ),
      AppleNativePickerOption<String>(
        value: 'kernel:exo',
        title: '均衡播放（默认）',
        subtitle: '自动选择解码方式，64 MB 前向缓冲',
        symbol: 'slider.horizontal.3',
        checked: _playerKernel == 'exo',
        section: 1,
        sectionTitle: '播放策略',
      ),
      AppleNativePickerOption<String>(
        value: 'kernel:ijk',
        title: '兼容缓冲',
        subtitle: '硬件解码拷贝输出，增加媒体探测时间',
        symbol: 'slider.horizontal.3',
        checked: _playerKernel == 'ijk',
        section: 1,
      ),
      AppleNativePickerOption<String>(
        value: 'kernel:mpv',
        title: '大容量缓冲',
        subtitle: '128 MB 前向缓冲，适合高码率 4K',
        symbol: 'slider.horizontal.3',
        checked: _playerKernel == 'mpv',
        section: 1,
      ),
    ];

    void applyChoice(String choice) {
      if (choice == 'fit:contain') {
        _setFit(BoxFit.contain);
        _showHud('画面：适应屏幕');
      } else if (choice == 'fit:cover') {
        _setFit(BoxFit.cover);
        _showHud('画面：裁切填充');
      } else if (choice == 'fit:fill') {
        _setFit(BoxFit.fill);
        _showHud('画面：铺满屏幕');
      } else if (choice.startsWith('kernel:')) {
        final key = choice.substring('kernel:'.length);
        final title = switch (key) {
          'ijk' => '兼容缓冲',
          'mpv' => '大容量缓冲',
          _ => '均衡播放（默认）',
        };
        unawaited(_selectKernel(key, title));
      }
    }

    if (_canUseNativeIosSheet) {
      final session = _playSession;
      unawaited(() async {
        final picked = await showAppleNativeOptionSheet<String>(
          context,
          title: '画面与播放策略',
          forceOpaque: _effectiveSheetForceOpaque,
          anchorRect: anchorRect,
          forceDark: true,
          options: options,
          fallback: () async {
            _showAspectAndStrategyFallbackSheet(
              applyChoice,
              anchorRect: anchorRect,
            );
            return null;
          },
        );
        if (!mounted || session != _playSession || picked == null) return;
        applyChoice(picked);
      }());
      return;
    }
    _showAspectAndStrategyFallbackSheet(applyChoice, anchorRect: anchorRect);
  }

  void _showAspectAndStrategyFallbackSheet(
    ValueChanged<String> applyChoice, {
    Rect? anchorRect,
  }) {
    Widget buildContent(BuildContext ctx) => ListView(
      shrinkWrap: true,
      padding: EdgeInsets.all(_useIos26PlayerChrome ? 4 : 16),
      children: [
        AppleGroupedSection(
          children: [
            for (final item in const [
              ('fit:contain', '画面适应（默认）', BoxFit.contain),
              ('fit:cover', '画面裁切填充', BoxFit.cover),
              ('fit:fill', '画面铺满屏幕', BoxFit.fill),
            ])
              AppleGroupedTile(
                icon: CupertinoIcons.play_rectangle,
                iconBgColor: _fit == item.$3
                    ? AppleColors.systemBlue
                    : AppleColors.groupedTertiary,
                title: item.$2,
                trailing: _fit == item.$3
                    ? const Icon(
                        CupertinoIcons.checkmark_alt,
                        color: AppleColors.systemBlue,
                        size: 18,
                      )
                    : null,
                onTap: () {
                  Navigator.of(ctx).pop();
                  applyChoice(item.$1);
                },
              ),
          ],
        ),
        const SizedBox(height: 10),
        AppleGroupedSection(
          children: [
            for (final item in const [
              ('kernel:exo', '均衡播放（默认）', 'exo'),
              ('kernel:ijk', '兼容缓冲', 'ijk'),
              ('kernel:mpv', '大容量缓冲', 'mpv'),
            ])
              AppleGroupedTile(
                icon: CupertinoIcons.slider_horizontal_3,
                iconBgColor: _playerKernel == item.$3
                    ? AppleColors.systemBlue
                    : AppleColors.groupedTertiary,
                title: item.$2,
                trailing: _playerKernel == item.$3
                    ? const Icon(
                        CupertinoIcons.checkmark_alt,
                        color: AppleColors.systemBlue,
                        size: 18,
                      )
                    : null,
                onTap: () {
                  Navigator.of(ctx).pop();
                  applyChoice(item.$1);
                },
              ),
          ],
        ),
      ],
    );
    if (_useIos26PlayerChrome) {
      showIosGlassPopover<void>(
        context: context,
        anchorRect: anchorRect,
        title: '画面与播放策略',
        maxWidth: 280,
        maxHeight: 330,
        forceDark: true,
        builder: buildContent,
      );
      return;
    }
    showAppleModalSheet<void>(
      context: context,
      title: '画面与播放策略',
      builder: buildContent,
    );
  }

  void _showAudioSubtitleQuickSheet({Rect? anchorRect}) {
    _cancelTransientInteractions(GestureInterruptReason.dialogOpened);
    final options = <AppleNativePickerOption<String>>[
      const AppleNativePickerOption<String>(
        value: 'audio',
        title: '切换音轨',
        symbol: 'speaker.wave.2.fill',
      ),
      if (!_isLiveStream)
        const AppleNativePickerOption<String>(
          value: 'subtitle',
          title: '切换内嵌字幕',
          symbol: 'captions.bubble.fill',
        ),
    ];
    void showQuickFallbackSheet() {
      Widget buildContent(BuildContext ctx) => ListView(
        shrinkWrap: true,
        padding: EdgeInsets.all(_useIos26PlayerChrome ? 4 : 16),
        children: [
          AppleGroupedSection(
            children: [
              AppleGroupedTile(
                icon: CupertinoIcons.speaker_2_fill,
                title: '切换音轨',
                onTap: () {
                  Navigator.of(ctx).pop();
                  _showAudioTracksSheet();
                },
              ),
              if (!_isLiveStream)
                AppleGroupedTile(
                  icon: CupertinoIcons.captions_bubble_fill,
                  title: '切换内嵌字幕',
                  onTap: () {
                    Navigator.of(ctx).pop();
                    _showSubtitleTracksSheet();
                  },
                ),
            ],
          ),
        ],
      );
      if (_useIos26PlayerChrome) {
        showIosGlassPopover<void>(
          context: context,
          anchorRect: anchorRect,
          title: '音轨与字幕',
          maxWidth: 250,
          maxHeight: 220,
          forceDark: true,
          builder: buildContent,
        );
        return;
      }
      showAppleModalSheet<void>(
        context: context,
        title: '音轨与字幕',
        builder: buildContent,
      );
    }
    if (_canUseNativeIosSheet) {
      final session = _playSession;
      unawaited(() async {
        final picked = await showAppleNativeOptionSheet<String>(
          context,
          title: '音轨与字幕',
          forceOpaque: _effectiveSheetForceOpaque,
          anchorRect: anchorRect,
          forceDark: true,
          options: options,
          fallback: () async {
            showQuickFallbackSheet();
            return null;
          },
        );
        if (!mounted || session != _playSession || picked == null) return;
        if (picked == 'audio') {
          _showAudioTracksSheet();
        } else {
          _showSubtitleTracksSheet();
        }
      }());
      return;
    }
    showQuickFallbackSheet();
  }

  void _showDoubleTapSettingsSheet() {
    _cancelTransientInteractions(GestureInterruptReason.dialogOpened);
    final currentSides = _hudPrefs.data.doubleTapSides;
    final options = <AppleNativePickerOption<String>>[
      AppleNativePickerOption<String>(
        value: 'seek_10s',
        title: '左右侧双击快进/快退 10 秒（默认）',
        subtitle: '中央双击播放/暂停，侧边支持连击累加',
        symbol: 'goforward.10',
        checked: currentSides == 'seek_10s',
      ),
      AppleNativePickerOption<String>(
        value: 'seek_15s',
        title: '左右侧双击快进/快退 15 秒',
        symbol: 'goforward.15',
        checked: currentSides == 'seek_15s',
      ),
      AppleNativePickerOption<String>(
        value: 'seek_5s',
        title: '左右侧双击快进/快退 5 秒',
        symbol: 'goforward.5',
        checked: currentSides == 'seek_5s',
      ),
      AppleNativePickerOption<String>(
        value: 'play_pause',
        title: '全屏任意区域双击播放/暂停',
        subtitle: '恢复经典双击暂停行为',
        symbol: 'playpause.fill',
        checked: currentSides == 'play_pause',
      ),
    ];
    if (_canUseNativeIosSheet) {
      final session = _playSession;
      unawaited(() async {
        final picked = await showAppleNativeOptionSheet<String>(
          context,
          title: '双击手势行为',
          forceOpaque: _effectiveSheetForceOpaque,
          options: options,
          fallback: () async {
            _showDoubleTapFallbackSheet(options);
            return null;
          },
        );
        if (!mounted || session != _playSession || picked == null) return;
        await _hudPrefs.setDoubleTapSides(picked);
        _showHud('已更新双击手势设置');
      }());
      return;
    }
    _showDoubleTapFallbackSheet(options);
  }

  void _showDoubleTapFallbackSheet(
    List<AppleNativePickerOption<String>> options,
  ) {
    showAppleModalSheet<void>(
      context: context,
      title: '双击手势行为',
      builder: (ctx) => ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.all(16),
        children: [
          AppleGroupedSection(
            children: [
              for (final opt in options)
                AppleGroupedTile(
                  icon: CupertinoIcons.hand_draw_fill,
                  iconBgColor: opt.checked
                      ? AppleColors.systemBlue
                      : AppleColors.groupedTertiary,
                  title: opt.title,
                  subtitle: opt.subtitle,
                  trailing: opt.checked
                      ? const Icon(
                          CupertinoIcons.checkmark_alt,
                          color: AppleColors.systemBlue,
                          size: 18,
                        )
                      : null,
                  onTap: () {
                    Navigator.of(ctx).pop();
                    unawaited(_hudPrefs.setDoubleTapSides(opt.value));
                    _showHud('已更新双击手势设置');
                  },
                ),
            ],
          ),
        ],
      ),
    );
  }

  void _showIosMoreMenu({Rect? anchorRect}) {
    _cancelTransientInteractions(GestureInterruptReason.dialogOpened);
    final live = _isLiveStream;
    final options = <AppleNativePickerOption<String>>[
      AppleNativePickerOption<String>(
        value: 'sleep_timer',
        title: '定时关闭',
        subtitle: _sleepTimer.shortStatusLabel,
        symbol: 'moon.zzz.fill',
        checked: _sleepTimer.isActive,
        section: 0,
        sectionTitle: '播放增强',
      ),
      if (_isIosPlayerPlatform &&
          _anime4kController.isIosLightweightAvailableForPlayer(_player))
        AppleNativePickerOption<String>(
          value: 'anime4k_lightweight',
          title: 'Anime4K 轻超分',
          subtitle: _anime4kController.iosLightweightEnabled
              ? '已开启（过热自动降级）'
              : '适用于 A15 及以上 Apple Silicon',
          symbol: 'wand.and.stars',
          checked: _anime4kController.iosLightweightEnabled,
          section: 0,
        ),
      AppleNativePickerOption<String>(
        value: 'vocal_loudness',
        title: '人声响度：${_vocalLoudness.shortLabelZh}',
        subtitle: _vocalLoudness.descriptionZh,
        symbol: 'waveform.badge.plus',
        checked: _vocalLoudness != VocalLoudnessPreset.off,
        section: 0,
      ),
      if (_isIosPlayerPlatform)
        AppleNativePickerOption<String>(
          value: 'engine_switch',
          title: '播放内核：$_activeIosEngineBadgeLabel',
          subtitle: _usingAvPlayer
              ? '系统零拷贝硬解 · 点击切换 MDK / MPV'
              : (_videoKernel.isMdk
                    ? 'Metal 4K 杜比视界渲染 · 点击切换其他内核'
                    : 'MPV 全格式解码 · 点击切换 AVPlayer / MDK'),
          symbol: _usingAvPlayer ? 'play.rectangle.fill' : 'cpu',
          checked: true,
          section: 0,
        ),
      if (_qualityChoices.length > 1)
        AppleNativePickerOption<String>(
          value: 'quality',
          title: '切换画质 (${_qualityChoices.length})',
          symbol: 'sparkles',
          section: 0,
        ),
      AppleNativePickerOption<String>(
        value: 'audio',
        title: '切换音轨',
        symbol: 'speaker.wave.2.fill',
        section: 0,
      ),
      if (!live)
        AppleNativePickerOption<String>(
          value: 'subtitle',
          title: '切换字幕',
          symbol: 'captions.bubble.fill',
          section: 0,
        ),
      if (!live) ...[
        AppleNativePickerOption<String>(
          value: 'skip_intro',
          title: _skipIntroSec > 0 ? '跳过片头 (${_skipIntroSec}s)' : '设置跳过片头',
          symbol: 'forward.fill',
          checked: _skipIntroSec > 0,
          section: 1,
          sectionTitle: '跳过与连播',
        ),
        AppleNativePickerOption<String>(
          value: 'skip_outro',
          title: _skipOutroSec > 0 ? '跳过片尾 (${_skipOutroSec}s)' : '设置跳过片尾',
          symbol: 'forward.end.alt.fill',
          checked: _skipOutroSec > 0,
          section: 1,
        ),
        AppleNativePickerOption<String>(
          value: 'skip_countdown_toggle',
          title: '跳过前 3 秒可取消倒计时',
          subtitle: _hudPrefs.data.skipCountdown ? '已开启' : '静默立即跳过',
          symbol: 'timer',
          checked: _hudPrefs.data.skipCountdown,
          section: 1,
        ),
        AppleNativePickerOption<String>(
          value: 'episode_scrape',
          title: '剧集刮削与集数校准',
          subtitle: _episodeScrapeOverride.episodeOffset != 0
              ? '当前第 ${_currentScrapedEpisode().effectiveEpisodeNumber} 集 · 偏移 ${_episodeScrapeOverride.episodeOffset > 0 ? '+${_episodeScrapeOverride.episodeOffset}' : '${_episodeScrapeOverride.episodeOffset}'}'
              : (_currentScrapedEpisode().isSpecial
                    ? '当前：${_currentScrapedEpisode().specialTag ?? '特辑'}'
                    : '当前识别：第 ${_currentScrapedEpisode().effectiveEpisodeNumber} 集'),
          symbol: 'sparkles',
          checked: !_episodeScrapeOverride.isDefault,
          section: 1,
        ),
        AppleNativePickerOption<String>(
          value: 'auto_next',
          title: '自动连播下一集',
          subtitle: _autoNext ? '已开启' : '已关闭',
          symbol: 'repeat',
          checked: _autoNext,
          section: 1,
        ),
        AppleNativePickerOption<String>(
          value: 'repeat',
          title: '循环模式：$_repeatLabel',
          symbol: 'arrow.2.squarepath',
          checked: _repeatMode != 'off',
          section: 1,
        ),
      ],
      AppleNativePickerOption<String>(
        value: 'clock',
        title: '播放页常显时间',
        subtitle: _alwaysShowClock ? '已开启' : '已关闭',
        symbol: 'clock.fill',
        checked: _alwaysShowClock,
        section: 2,
        sectionTitle: '手势与显示',
      ),
      AppleNativePickerOption<String>(
        value: 'slim_progress',
        title: '隐藏主控栏时显示底部细进度条',
        subtitle: _hudPrefs.data.slimProgress ? '已开启' : '已关闭',
        symbol: 'minus',
        checked: _hudPrefs.data.slimProgress,
        section: 2,
      ),
      AppleNativePickerOption<String>(
        value: 'double_tap',
        title: '双击手势行为',
        symbol: 'hand.tap.fill',
        section: 2,
      ),
      if (_isIosPlayerPlatform)
        AppleNativePickerOption<String>(
          value: 'customize_toolbar',
          title: '自定义工具栏按钮与排序',
          subtitle: '当前已启用 ${_iosToolbarItems.length} 项按钮',
          symbol: 'slider.horizontal.below.rectangle',
          section: 2,
        ),
      AppleNativePickerOption<String>(
        value: 'replay',
        title: live ? '刷新直播流' : (_isMultiVersionMovie ? '从头重播本片' : '从头重播本集'),
        symbol: 'arrow.clockwise',
        section: 2,
      ),
      if (_canUsePlayerAi) ...[
        if (!live && AiService.instance.config.subtitleTranslateEnabled)
          AppleNativePickerOption<String>(
            value: 'ai_subtitle_studio',
            title: 'AI 双语字幕（实时/外挂）',
            subtitle: _hasActiveAiSubtitleOverlay
                ? '正在画面直显双语字幕'
                : '支持内封实时双语精译与外挂字幕直显',
            symbol: 'captions.bubble.fill',
            checked: _hasActiveAiSubtitleOverlay,
            section: 3,
            sectionTitle: 'AI 观影助手',
          ),
        if (!live && AiService.instance.config.spoilerFreeRecapEnabled) ...[
          const AppleNativePickerOption<String>(
            value: 'ai_watch_brief',
            title: 'AI 零剧透看点与设定科普',
            subtitle: '创作渊源、世界观设定与视听看点',
            symbol: 'film.fill',
            section: 3,
            sectionTitle: 'AI 观影助手',
          ),
          const AppleNativePickerOption<String>(
            value: 'ai_post_credits',
            title: 'AI 片尾彩蛋与版本提示',
            subtitle: '查询是否有片尾彩蛋及杜比/IMAX版本差异',
            symbol: 'sparkles',
            section: 3,
            sectionTitle: 'AI 观影助手',
          ),
          const AppleNativePickerOption<String>(
            value: 'ai_work_qa',
            title: 'AI 自由观影问答（防剧透）',
            subtitle: '围绕本片设定、背景或疑问自由提问',
            symbol: 'bubble.left.and.bubble.right.fill',
            section: 3,
            sectionTitle: 'AI 观影助手',
          ),
        ],
        if (AiService.instance.config.smartDiagnosticsEnabled)
          const AppleNativePickerOption<String>(
            value: 'ai_diagnostics',
            title: 'AI 播放与源智能排障',
            subtitle: '脱敏分析卡顿、音画异常或加载失败',
            symbol: 'wrench.and.screwdriver.fill',
            section: 3,
            sectionTitle: 'AI 观影助手',
          ),
        if (!live)
          for (final skill in AiService.instance.config.effectiveSkills
              .where((s) => s.target.showsInPlayer))
            AppleNativePickerOption<String>(
              value: 'ai_skill:${skill.id}',
              title: 'AI 技能：${skill.name}',
              symbol: 'sparkles',
              section: 3,
              sectionTitle: 'AI 观影助手',
            ),
      ],
    ];

    void handleAction(String action) {
      switch (action) {
        case 'sleep_timer':
          _showSleepTimerSheet(anchorRect: anchorRect);
        case 'anime4k_lightweight':
          _toggleIosAnime4kQuick();
        case 'vocal_loudness':
          _showVocalLoudnessSheet(anchorRect: anchorRect);
        case 'engine_switch':
          _showIosEnginePickerSheet(anchorRect: anchorRect);
        case 'quality':
          unawaited(_showQualityChoices());
        case 'audio':
          _showAudioTracksSheet(anchorRect: anchorRect);
        case 'subtitle':
          _showSubtitleTracksSheet();
        case 'skip_intro':
          _showSkipIntroSheet();
        case 'skip_outro':
          _showSkipOutroSheet();
        case 'skip_countdown_toggle':
          final next = !_hudPrefs.data.skipCountdown;
          unawaited(_hudPrefs.setSkipCountdown(next));
          _showHud(next ? '已开启跳过 3 秒倒计时' : '已切换为静默立即跳过');
        case 'episode_scrape':
          unawaited(_showEpisodeScrapeSheet());
        case 'auto_next':
          _toggleAutoNext();
        case 'repeat':
          _cycleRepeatMode();
        case 'clock':
          _toggleAlwaysShowClock();
        case 'slim_progress':
          final next = !_hudPrefs.data.slimProgress;
          unawaited(_hudPrefs.setSlimProgress(next));
          _showHud(next ? '已开启底部常驻细进度条' : '已关闭底部常驻细进度条');
        case 'double_tap':
          _showDoubleTapSettingsSheet();
        case 'customize_toolbar':
          unawaited(
            showIosPlayerToolbarCustomizeSheet(
              context,
              storage: widget.storage,
              onChanged: (nextItems) {
                if (!mounted) return;
                setState(() => _iosToolbarItems = List<String>.of(nextItems));
              },
            ),
          );
        case 'replay':
          if (live) {
            unawaited(_openCurrentEpisode());
            _showHud('正在刷新直播流…');
          } else {
            _seekPlayer(Duration.zero);
            _enginePlay();
            _showHud('已从头开始播放');
          }
        case 'ai_subtitle_studio':
          _openAiSubtitleStudio();
        case 'ai_watch_brief':
          unawaited(
            showIosAiWatchBriefSheet(
              context,
              title: _activeVideo.title,
              year: _activeVideo.year,
              genreOrRemarks: '${_activeVideo.tag} ${_activeVideo.remarks}'.trim(),
              overview: _activeVideo.description,
            ),
          );
        case 'ai_post_credits':
          unawaited(
            showIosAiPostCreditsSheet(
              context,
              title: _activeVideo.title,
              year: _activeVideo.year,
              overview: _activeVideo.description,
            ),
          );
        case 'ai_work_qa':
          unawaited(
            showIosAiWorkQaSheet(
              context,
              title: _activeVideo.title,
              year: _activeVideo.year,
              overview: _activeVideo.description,
            ),
          );
        case 'ai_similar_curate':
          _openPlayerAiSimilarCurate();
        case 'ai_diagnostics':
          unawaited(
            showIosAiDiagnosticsSheet(
              context,
              rawErrorText: _playbackError.trim().isNotEmpty
                  ? _playbackError
                  : '播放流畅度与兼容性巡检',
              engineName: _activeIosEngineBadgeLabel,
              mediaFormatHint: _currentScrapedEpisode().rawName,
              hasBackupLines: _lines.length > 1,
              onExecuteAction: (act) {
                switch (act) {
                  case AiDiagnosticActionId.switchToMpv:
                    unawaited(
                      _switchIosEngineMode(IosPlaybackEngineMode.mpv),
                    );
                  case AiDiagnosticActionId.switchToAvPlayer:
                    unawaited(
                      _switchIosEngineMode(IosPlaybackEngineMode.avPlayer),
                    );
                  case AiDiagnosticActionId.enableVocalLoudness:
                    _showVocalLoudnessSheet();
                  case AiDiagnosticActionId.switchBackupLine:
                    _showLinesSheet();
                  case AiDiagnosticActionId.openEpisodeScrape:
                    unawaited(_showEpisodeScrapeSheet());
                }
              },
            ),
          );
        default:
          if (action.startsWith('ai_skill:')) {
            final skillId = action.substring('ai_skill:'.length);
            final matched = AiService.instance.config.effectiveSkills
                .where((s) => s.id == skillId)
                .firstOrNull;
            if (matched != null) {
              unawaited(
                showIosAiCustomSkillOutputSheet(
                  context,
                  skill: matched,
                  title: _activeVideo.title,
                  year: _activeVideo.year,
                  episode: _isMultiVersionMovie
                      ? ''
                      : '第 ${_currentScrapedEpisode().effectiveEpisodeNumber} 集',
                  overview: _activeVideo.description,
                  subtitles: _player.state.subtitle.join('\n'),
                ),
              );
            }
          }
      }
    }

    if (_canUseNativeIosSheet) {
      final session = _playSession;
      unawaited(() async {
        final picked = await showAppleNativeOptionSheet<String>(
          context,
          title: '播放选项',
          forceOpaque: _effectiveSheetForceOpaque,
          anchorRect: anchorRect,
          forceDark: true,
          options: options,
          fallback: () async {
            _showIosMoreFallbackSheet(
              options,
              handleAction,
              anchorRect: anchorRect,
            );
            return null;
          },
        );
        if (!mounted || session != _playSession || picked == null) return;
        handleAction(picked);
      }());
      return;
    }
    _showIosMoreFallbackSheet(options, handleAction, anchorRect: anchorRect);
  }

  void _showIosMoreFallbackSheet(
    List<AppleNativePickerOption<String>> options,
    ValueChanged<String> handleAction, {
    Rect? anchorRect,
  }) {
    Widget buildContent(BuildContext ctx) {
      if (_useIos26PlayerChrome) {
        return ListView.separated(
          shrinkWrap: true,
          padding: const EdgeInsets.symmetric(vertical: 2),
          itemCount: options.length,
          separatorBuilder: (_, __) => Divider(
            height: 1,
            thickness: 0.5,
            indent: 34,
            color: Colors.white.withValues(alpha: 0.10),
          ),
          itemBuilder: (_, idx) {
            final opt = options[idx];
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                Navigator.of(ctx).pop();
                handleAction(opt.value);
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
                child: Row(
                  children: [
                    Icon(
                      opt.checked
                          ? CupertinoIcons.checkmark_circle_fill
                          : CupertinoIcons.slider_horizontal_3,
                      size: 15,
                      color: opt.checked
                          ? AppleColors.systemBlue
                          : const Color(0xCCFFFFFF),
                    ),
                    const SizedBox(width: 9),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            opt.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 12.5,
                              fontWeight: opt.checked
                                  ? FontWeight.w600
                                  : FontWeight.w500,
                              height: 1.2,
                            ),
                          ),
                          if ((opt.subtitle ?? '').trim().isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 1.5),
                              child: Text(
                                opt.subtitle!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.62),
                                  fontSize: 10.5,
                                  height: 1.15,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    if (opt.checked)
                      const Padding(
                        padding: EdgeInsets.only(left: 6),
                        child: Icon(
                          CupertinoIcons.checkmark_alt,
                          color: AppleColors.systemBlue,
                          size: 14,
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        );
      }
      return ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.all(16),
        children: [
          AppleGroupedSection(
            children: [
              for (final opt in options)
                AppleGroupedTile(
                  icon: CupertinoIcons.slider_horizontal_3,
                  iconBgColor: opt.checked
                      ? AppleColors.systemBlue
                      : AppleColors.groupedTertiary,
                  title: opt.title,
                  subtitle: opt.subtitle,
                  trailing: opt.checked
                      ? const Icon(
                          CupertinoIcons.checkmark_alt,
                          color: AppleColors.systemBlue,
                          size: 18,
                        )
                      : null,
                  onTap: () {
                    Navigator.of(ctx).pop();
                    handleAction(opt.value);
                  },
                ),
            ],
          ),
        ],
      );
    }
    if (_useIos26PlayerChrome) {
      showIosGlassPopover<void>(
        context: context,
        anchorRect: anchorRect,
        title: '播放选项',
        maxWidth: 304,
        maxHeight: 488,
        forceDark: true,
        contentPadding: const EdgeInsets.fromLTRB(6, 2, 6, 6),
        builder: buildContent,
      );
      return;
    }
    showAppleModalSheet<void>(
      context: context,
      title: '播放选项',
      builder: buildContent,
    );
  }

  void _toggleIosAnime4kQuick() {
    final next = !_anime4kController.iosLightweightEnabled;
    unawaited(() async {
      await _anime4kController.setIosLightweightEnabled(_player, next);
      await widget.storage.setIosAnime4kLightweightEnabled(next);
      if (!mounted) return;
      setState(() {});
      _showHud(
        next
            ? (_usingAvPlayer || _videoKernel.isMdk
                  ? '已开启 Anime4K 轻超分（切至 MPV 内核生效）'
                  : '已开启 Anime4K 轻超分')
            : '已关闭 Anime4K 轻超分',
      );
    }());
  }

  bool get _canUsePlayerAi =>
      _isIosPlayerPlatform &&
      !_isLiveStream &&
      !_activeSite.isEffectivelyPrivate &&
      !widget.site.isEffectivelyPrivate &&
      !AiService.instance.isPrivacySessionActive &&
      AiService.instance.isLabUnlocked;

  void _openAiSubtitleStudio() {
    if (!_canUsePlayerAi) return;
    final capturedMediaKey = _currentAiSubtitleMediaKey;
    final capturedMediaGen = _aiSubtitleMediaGen;
    final activeLines = _currentActiveEmbeddedSubtitleLines;
    final currentPosMs = _position.inMilliseconds > 0
        ? _position.inMilliseconds
        : (_aiSubtitleClockMsNotifier.value > 0
              ? _aiSubtitleClockMsNotifier.value
              : _lastKnownPositionMs);
    unawaited(
      showIosAiSubtitleStudioSheet(
        context,
        seriesTitle: _activeVideo.title,
        episodeLabel: _isMultiVersionMovie
            ? _currentScrapedEpisode().movieVersionLabel
            : '第 ${_currentScrapedEpisode().effectiveEpisodeNumber} 集',
        skipIntroSeconds: _skipIntroSec,
        currentPlaybackPosition: Duration(milliseconds: currentPosMs),
        currentActiveCueLines: activeLines,
        initialSession: _currentAiSubtitleSessionSnapshot,
        getOverlayMountGen: () => _aiOverlayMountGen,
        onSessionChanged: (session) {
          if (!mounted ||
              capturedMediaKey != _currentAiSubtitleMediaKey ||
              capturedMediaGen != _aiSubtitleMediaGen) {
            return;
          }
          // Studio draft edits (importing a file or pasting text) update ONLY
          // the studio draft state and NEVER mutate the currently mounted
          // on-screen subtitle overlay until explicitly applied/mounted.
          setState(() {
            _aiOverlayMediaKey = capturedMediaKey;
            _aiStudioDraftCues = List<AiSubtitleCue>.unmodifiable(
              session.draftCues.isNotEmpty ? session.draftCues : session.cues,
            );
            _aiStudioDraftGlossary = Map<String, String>.unmodifiable(
              session.draftGlossary.isNotEmpty
                  ? session.draftGlossary
                  : session.glossary,
            );
            _aiStudioDraftOffset = session.draftMatchesOverlay
                ? session.offset
                : session.draftOffset;
            _aiStudioDraftMatchesOverlay =
                session.overlayActive && session.draftMatchesOverlay;
            if (session.overlayActive &&
                session.draftMatchesOverlay &&
                _aiOverlayCues.isNotEmpty) {
              _aiOverlayGlossary = Map<String, String>.unmodifiable(
                session.glossary,
              );
              _aiOverlayBilingual = session.bilingual;
              _aiOverlayOffset = session.offset;
              _aiOverlayLabel = session.label;
            }
          });
          _aiSubtitleStateRevision.value++;
          _syncAvPlayerSubtitleSuppression();
        },
        liveEmbeddedTranslateEnabled: _aiLiveEmbeddedTranslateEnabled,
        hasActiveSubtitleOverlay: _aiOverlayCues.isNotEmpty,
        onToggleLiveEmbeddedTranslate: (enabled) {
          if (!mounted ||
              capturedMediaKey != _currentAiSubtitleMediaKey ||
              capturedMediaGen != _aiSubtitleMediaGen) {
            return;
          }
          setState(() {
            _aiLiveEmbeddedTranslateEnabled = enabled;
            _aiOverlayMediaKey = capturedMediaKey;
            if (!enabled) {
              _clearAiLiveSubtitleLine(notify: false);
            }
          });
          _aiSubtitleStateRevision.value++;
          _syncAvPlayerSubtitleSuppression();
          if (enabled) {
            if (_usingAvPlayer &&
                _iosAvPlayerController != null &&
                !_canExtractCurrentAvSubtitleText(_iosAvPlayerController!) &&
                (_iosAvPlayerController!.currentSubtitleHasNonTextSamples ||
                    _iosAvPlayerController!.subtitleTracks.any(
                      (t) =>
                          t.selected &&
                          (t.isBitmap ||
                              t.isTextExtractable == false ||
                              MdkPlatformPlayer.isBitmapSubtitleCodec(t.title)),
                    ))) {
              _showHud('当前内嵌字幕为图形字幕，无法提取文本实时翻译，已保留原字幕显示');
              return;
            }
            if (!_usingAvPlayer &&
                MdkPlatformPlayer.isBitmapSubtitleCodec(
                  _player.state.track.subtitle.codec,
                )) {
              _showHud('当前内嵌字幕为图形字幕（PGS/VobSub），无法提取文本实时翻译，已保留原字幕显示');
              return;
            }
            final currentLines = _currentActiveEmbeddedSubtitleLines;
            if (currentLines.isNotEmpty) {
              _handleEmbeddedSubtitleLines(currentLines);
            }
            _showHud('已开启内封字幕实时双语显示');
          } else {
            _showHud('已关闭内封字幕实时双语显示');
          }
        },
        onClearSubtitleOverlay: () {
          if (!mounted ||
              capturedMediaKey != _currentAiSubtitleMediaKey ||
              capturedMediaGen != _aiSubtitleMediaGen) {
            return;
          }
          setState(() {
            _aiOverlayMountGen++;
            _aiOverlayCues = const <AiSubtitleCue>[];
            _aiOverlayGlossary = const <String, String>{};
            _aiStudioDraftCues = const <AiSubtitleCue>[];
            _aiStudioDraftGlossary = const <String, String>{};
            _aiStudioDraftOffset = Duration.zero;
            _aiStudioDraftMatchesOverlay = false;
            _aiOverlayOffset = Duration.zero;
            _aiOverlayLabel = '';
            _clearAiLiveSubtitleLine(notify: false);
          });
          _aiSubtitleStateRevision.value++;
          _syncAvPlayerSubtitleSuppression(force: true);
          _showHud('已清除 AI 字幕叠层');
        },
        onApplySubtitleOverlay: (
          cues, {
          required bilingual,
          required offset,
          required label,
        }) async {
          if (!mounted ||
              capturedMediaKey != _currentAiSubtitleMediaKey ||
              capturedMediaGen != _aiSubtitleMediaGen) {
            return;
          }
          setState(() {
            _aiOverlayMountGen++;
            _aiOverlayMediaKey = capturedMediaKey;
            _aiOverlayCues = List<AiSubtitleCue>.unmodifiable(cues);
            _aiOverlayBilingual = bilingual;
            _aiOverlayOffset = offset;
            _aiOverlayLabel = label;
            if (_aiStudioDraftMatchesOverlay || _aiStudioDraftCues.isEmpty) {
              _aiStudioDraftCues = _aiOverlayCues;
              _aiStudioDraftOffset = offset;
              _aiStudioDraftMatchesOverlay = true;
            }
          });
          _aiSubtitleStateRevision.value++;
          _syncAvPlayerSubtitleSuppression(force: true);
          _showHud('已在画面启用 $label（共 ${cues.length} 条）');
        },
      ),
    );
  }

  Future<void> _switchToRecommendedPick(AiCuratedPick pick) async {
    final targetSite = pick.matchedSite;
    final targetVideo = pick.matchedVideo;
    if (targetSite == null || targetVideo == null) {
      _showHud('可在首页搜索《${pick.title}》播放');
      return;
    }
    if (targetSite.isEffectivelyPrivate ||
        AiService.instance.isPrivacySessionActive) {
      _showHud('私密片源不支持通过 AI 推荐直接切换');
      return;
    }
    final prevNavGen = _userNavigationGen;
    _showHud('正在校验《${pick.title}》播放线路…');
    try {
      var resolved = targetVideo;
      final hasPlayableLines =
          resolved.lines.any((l) => l.episodes.isNotEmpty);
      if (!hasPlayableLines) {
        resolved = await _client
            .fetchDetail(targetSite, targetVideo)
            .timeout(const Duration(seconds: 25));
      }
      if (!mounted || _userNavigationGen != prevNavGen) return;
      final normalizedResolved = WoggSource.normalizeCachedVideoLabels(
        targetSite,
        resolved,
      );
      final playableLines = normalizedResolved.lines
          .where((l) => l.episodes.isNotEmpty)
          .toList(growable: false);
      if (playableLines.isEmpty) {
        _showHud('《${pick.title}》暂未获取到可播线路，已保留当前影片');
        return;
      }
      // Persist Film A's exact resume record before mutating any active state.
      await _saveProgress(
        immediate: true,
        syncImmediate: false,
        allowUnconfirmedWithPosition: true,
      );
      if (!mounted || _userNavigationGen != prevNavGen) return;
      _userNavigationGen++;

      // Cancel in-flight Film A cross-site hydration and clear stale rollback
      // or error states, then release Film A's source lease and pin Film B.
      if (_crossSiteAbort?.isCompleted == false) {
        _crossSiteAbort!.complete();
      }
      _crossSiteAbort = null;
      _pendingCrossSiteRollback = null;
      _failedLinesForEpisode.clear();
      _failedLiveEpisodes.clear();
      _crossSiteDetails.clear();
      _crossSiteErrors.clear();
      _releaseSourceSession?.call();
      _releaseSourceSession = _client.pinPlaybackSource(targetSite);

      final recommendedLineIdx = widget.storage
          .pickRecommendedLineIndex(playableLines)
          .clamp(0, playableLines.length - 1);
      final nextSkipIntro = widget.storage.getVideoSkipIntroSec(
        targetSite.key,
        normalizedResolved.id,
        isPrivate: targetSite.isEffectivelyPrivate,
      );
      final nextSkipOutro = widget.storage.getVideoSkipOutroSec(
        targetSite.key,
        normalizedResolved.id,
        isPrivate: targetSite.isEffectivelyPrivate,
      );
      final targetRef = _workSourceRefFor(targetSite, normalizedResolved);

      // Look up Film B's own watch history and restore resume time ONLY when
      // the historical episode genuinely matches the resolved target episode.
      WatchHistoryEntry? targetHistory;
      for (final entry in widget.storage.getWatchHistory()) {
        if (entry.site == targetSite.key &&
            entry.id == normalizedResolved.id) {
          targetHistory = entry;
          break;
        }
      }
      final resolvedTarget = PlayerScreen.resolveRecommendedSwitchTarget(
        playableLines: playableLines,
        recommendedLineIndex: recommendedLineIdx,
        historyEntry: targetHistory,
      );
      final targetResumeMs = resolvedTarget.resumeMs;
      final targetLineIdx = resolvedTarget.lineIndex;
      final targetEpIdx = resolvedTarget.episodeIndex;

      setState(() {
        _activeSite = targetSite;
        _activeVideo = normalizedResolved;
        _lines = List<CmsLine>.of(playableLines);
        _lineIndex = targetLineIdx;
        _episodeIndex = targetEpIdx;
        _crossSiteSources = <WorkSourceRef>[targetRef];
        _crossSiteDetails[targetRef.identityKey] = normalizedResolved;
        _skipIntroSec = nextSkipIntro;
        _skipOutroSec = nextSkipOutro;
        _introSkippedForSession = false;
        _outroSkippedForSession = false;
        _pendingResumeMs = 0;
        _intendedStartPositionMs = 0;
        _episodeResumeAnchorMs = 0;
        _position = Duration.zero;
        _duration = Duration.zero;
        _lastKnownPositionMs = 0;
        _lastKnownDurationMs = 0;
        _episodeScrapeOverride = widget.storage.getEpisodeScrapeOverride(
          siteKey: targetSite.key,
          videoId: normalizedResolved.id,
          videoTitle: normalizedResolved.title,
        );
        _isFavorite = widget.storage.isFavorite(
          targetSite.key,
          normalizedResolved.id,
          forPrivate: targetSite.isEffectivelyPrivate,
        );
      });
      _showHud(
        '已为您切换至《${normalizedResolved.title.isNotEmpty ? normalizedResolved.title : pick.title}》',
      );
      unawaited(_openCurrentEpisode(resumeMs: targetResumeMs));
    } catch (_) {
      if (!mounted || _userNavigationGen != prevNavGen) return;
      _showHud('《${pick.title}》详情加载失败，已保留当前影片');
    }
  }

  void _openPlayerAiSimilarCurate() {
    if (!_canUsePlayerAi) return;
    final historyTitles = widget.storage
        .getWatchHistory()
        .map((e) => e.title)
        .take(12)
        .toList();
    final favs = widget.storage.getFavorites();
    final favTitles = favs.map((e) => e.title).take(12).toList();
    final snap = <(CmsSite, CmsVideo)>[];
    final cfg = widget.storage.loadSavedConfig();
    final siteByKey = <String, CmsSite>{
      if (cfg != null)
        for (final s in cfg.availableSites)
          if (!s.isEffectivelyPrivate) s.key: s,
    };
    for (final f in favs.take(30)) {
      final s = siteByKey[f.site];
      if (s != null) {
        snap.add((s, CmsVideo(id: f.id, title: f.title, poster: f.poster)));
      }
    }
    unawaited(
      showIosAiMoodSommelierSheet(
        context,
        sheetTitle: 'AI 看完《${_activeVideo.title}》看什么',
        initialMoodPrompt: '与《${_activeVideo.title}》气质相近的高口碑佳作',
        recentHistoryTitles: <String>[_activeVideo.title, ...historyTitles],
        favoriteTitles: favTitles,
        availableLibrarySnapshot: snap,
        onSelectPick: (pick) {
          unawaited(_switchToRecommendedPick(pick));
        },
      ),
    );
  }

  Widget _buildAiSubtitleOverlayWidget({required double bottomPadding}) {
    return AnimatedBuilder(
      animation: Listenable.merge(<Listenable>[
        _aiSubtitleClockMsNotifier,
        _aiSubtitleStateRevision,
      ]),
      builder: (context, _) {
        if (_usingAvPlayer && (_iosAvPlayerController?.isPipActive == true)) {
          return const SizedBox.shrink();
        }
        String primaryZh = '';
        String secondaryRaw = '';
        if (_aiOverlayCues.isNotEmpty) {
          final currentPos = Duration(
            milliseconds: _aiSubtitleClockMsNotifier.value,
          );
          final adjusted = currentPos - _aiOverlayOffset;
          for (final cue in _aiOverlayCues) {
            if (adjusted >= cue.start && adjusted <= cue.end) {
              final zh = cue.translatedText.trim();
              final raw = cue.text.trim();
              if (zh.isNotEmpty) {
                primaryZh = zh;
                if (_aiOverlayBilingual && raw.isNotEmpty && raw != zh) {
                  secondaryRaw = raw;
                }
              } else {
                primaryZh = raw;
              }
              break;
            }
          }
        }
        if (primaryZh.isEmpty &&
            _aiLiveEmbeddedTranslateEnabled &&
            _aiLiveRawLine.isNotEmpty) {
          if (_aiLiveTranslatedLine.isNotEmpty) {
            primaryZh = _aiLiveTranslatedLine;
            if (_aiOverlayBilingual && _aiLiveRawLine != _aiLiveTranslatedLine) {
              secondaryRaw = _aiLiveRawLine;
            }
          } else {
            primaryZh = _aiLiveRawLine;
          }
        }
        if (primaryZh.isEmpty) return const SizedBox.shrink();
        return Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              24,
              0,
              24,
              math.max(18.0, bottomPadding + 4.0),
            ),
            child: Container(
              key: const ValueKey('player-ai-subtitle-box'),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
              decoration: BoxDecoration(
                color: const Color(0xAD0B0D13),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.14),
                  width: 0.6,
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    primaryZh,
                    key: const ValueKey('player-ai-subtitle-primary'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      height: 1.34,
                      shadows: [
                        Shadow(
                          color: Color(0xE0000000),
                          blurRadius: 6,
                          offset: Offset(0, 1),
                        ),
                      ],
                    ),
                  ),
                  if (secondaryRaw.isNotEmpty) ...[
                    const SizedBox(height: 2.5),
                    Text(
                      secondaryRaw,
                      key: const ValueKey('player-ai-subtitle-secondary'),
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Color(0xD8E2E8F0),
                        fontSize: 12.5,
                        fontWeight: FontWeight.w500,
                        height: 1.28,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  void _showDanmuAndSubtitleQuickPopover({Rect? anchorRect}) {
    if (_isLiveStream) {
      _handleDanmuSettingsTap(anchorRect: anchorRect);
      return;
    }
    _cancelTransientInteractions(GestureInterruptReason.dialogOpened);
    final danmuOn = widget.onToggleDanmu != null
        ? widget.danmuEnabled
        : (!OhosRuntime.isOhos && _danmuSettings.effectiveEnabled);
    final aiUnlocked = _canUsePlayerAi &&
        AiService.instance.config.subtitleTranslateEnabled;
    final options = <AppleNativePickerOption<String>>[
      AppleNativePickerOption<String>(
        value: 'toggle_danmu',
        title: danmuOn ? '关闭弹幕' : '开启弹幕（默认关闭）',
        subtitle: danmuOn ? '当前弹幕已开启' : '点击立即开启实时弹幕渲染',
        symbol: danmuOn ? 'captions.bubble.fill' : 'captions.bubble',
        checked: danmuOn,
        section: 0,
        sectionTitle: '弹幕控制',
      ),
      const AppleNativePickerOption<String>(
        value: 'danmu_settings',
        title: '弹幕样式、字号与屏蔽设置',
        symbol: 'slider.horizontal.3',
        section: 0,
      ),
      const AppleNativePickerOption<String>(
        value: 'subtitle_tracks',
        title: '切换片源内嵌字幕',
        subtitle: '选择视频封装自带的中英字幕轨',
        symbol: 'text.bubble.fill',
        section: 1,
        sectionTitle: '字幕与双语翻译',
      ),
      if (aiUnlocked)
        AppleNativePickerOption<String>(
          value: 'ai_subtitle',
          title: 'AI 双语字幕（实时内封 / 外挂精译）',
          subtitle: _hasActiveAiSubtitleOverlay
              ? '正在画面直显双语字幕${_aiOverlayLabel.isNotEmpty ? " · $_aiOverlayLabel" : ""}'
              : '支持外语内封字幕实时直显与 .srt/.ass 导入精翻',
          symbol: 'sparkles',
          checked: _hasActiveAiSubtitleOverlay,
          section: 1,
        ),
    ];
    void onSelect(String v) {
      switch (v) {
        case 'toggle_danmu':
          _handleDanmuToggle();
        case 'danmu_settings':
          _handleDanmuSettingsTap(anchorRect: anchorRect);
        case 'subtitle_tracks':
          _showSubtitleTracksSheet();
        case 'ai_subtitle':
          _openAiSubtitleStudio();
      }
    }
    if (_canUseNativeIosSheet) {
      final session = _playSession;
      unawaited(() async {
        final picked = await showAppleNativeOptionSheet<String>(
          context,
          title: '弹幕与字幕',
          forceOpaque: _effectiveSheetForceOpaque,
          anchorRect: anchorRect,
          forceDark: true,
          options: options,
          fallback: () async {
            _showIosMoreFallbackSheet(options, onSelect, anchorRect: anchorRect);
            return null;
          },
        );
        if (!mounted || session != _playSession || picked == null) return;
        onSelect(picked);
      }());
      return;
    }
    _showIosMoreFallbackSheet(options, onSelect, anchorRect: anchorRect);
  }

  void _showSkipIntroOutroQuickPopover({Rect? anchorRect}) {
    if (_isLiveStream) return;
    _cancelTransientInteractions(GestureInterruptReason.dialogOpened);
    final options = <AppleNativePickerOption<String>>[
      AppleNativePickerOption<String>(
        value: 'skip_intro',
        title: _skipIntroSec > 0
            ? '跳过片头：已设 ${_skipIntroSec}s'
            : '设置跳过片头（可取当前播放时间）',
        symbol: 'forward.fill',
        checked: _skipIntroSec > 0,
      ),
      AppleNativePickerOption<String>(
        value: 'skip_outro',
        title: _skipOutroSec > 0
            ? '跳过片尾：已设 ${_skipOutroSec}s'
            : '设置跳过片尾',
        symbol: 'forward.end.alt.fill',
        checked: _skipOutroSec > 0,
      ),
      if (_skipIntroSec > 0 || _skipOutroSec > 0)
        const AppleNativePickerOption<String>(
          value: 'clear_skip',
          title: '清除本片片头与片尾设置',
          symbol: 'xmark.circle',
        ),
      if (!_isMultiVersionMovie)
        AppleNativePickerOption<String>(
          value: 'auto_next',
          title: '自动连播下一集：${_autoNext ? "已开启" : "已关闭"}',
          symbol: 'repeat',
          checked: _autoNext,
        ),
    ];
    void onSelect(String v) {
      switch (v) {
        case 'skip_intro':
          _showSkipIntroSheet();
        case 'skip_outro':
          _showSkipOutroSheet();
        case 'clear_skip':
          setState(() {
            _skipIntroSec = 0;
            _skipOutroSec = 0;
          });
          widget.storage.setVideoSkipIntroSec(
            _activeSite.key,
            _activeVideo.id,
            0,
            isPrivate: _activeSite.isEffectivelyPrivate,
          );
          widget.storage.setVideoSkipOutroSec(
            _activeSite.key,
            _activeVideo.id,
            0,
            isPrivate: _activeSite.isEffectivelyPrivate,
          );
          _showHud('已清除本片跳过片头与片尾');
        case 'auto_next':
          _toggleAutoNext();
      }
    }
    if (_canUseNativeIosSheet) {
      final session = _playSession;
      unawaited(() async {
        final picked = await showAppleNativeOptionSheet<String>(
          context,
          title: '片头片尾与连播',
          forceOpaque: _effectiveSheetForceOpaque,
          anchorRect: anchorRect,
          forceDark: true,
          options: options,
          fallback: () async {
            _showIosMoreFallbackSheet(options, onSelect, anchorRect: anchorRect);
            return null;
          },
        );
        if (!mounted || session != _playSession || picked == null) return;
        onSelect(picked);
      }());
      return;
    }
    _showIosMoreFallbackSheet(options, onSelect, anchorRect: anchorRect);
  }

  void _showIosPlayerAiPopover({Rect? anchorRect}) {
    if (!_canUsePlayerAi) {
      return;
    }
    _cancelTransientInteractions(GestureInterruptReason.dialogOpened);
    final cfg = AiService.instance.config;
    final options = <AppleNativePickerOption<String>>[
      if (cfg.subtitleTranslateEnabled)
        AppleNativePickerOption<String>(
          value: 'ai_subtitle_studio',
          title: 'AI 双语字幕（实时内封 / 外挂精译）',
          subtitle: _hasActiveAiSubtitleOverlay
              ? '正在画面直显双语字幕'
              : '全内核直接渲染双语台词，支持时间轴校准',
          symbol: 'captions.bubble.fill',
          checked: _hasActiveAiSubtitleOverlay,
          section: 0,
          sectionTitle: 'AI 观影助手',
        ),
      if (cfg.spoilerFreeRecapEnabled) ...[
        const AppleNativePickerOption<String>(
          value: 'ai_watch_brief',
          title: '零剧透看点与设定背景科普',
          subtitle: '创作渊源、世界观设定与视听看点',
          symbol: 'film.fill',
          section: 0,
        ),
        const AppleNativePickerOption<String>(
          value: 'ai_post_credits',
          title: '片尾彩蛋与版本差异提示',
          subtitle: '查询是否有彩蛋及 IMAX / 杜比视界版本差异',
          symbol: 'sparkles',
          section: 0,
        ),
        const AppleNativePickerOption<String>(
          value: 'ai_work_qa',
          title: '自由观影问答（防剧透）',
          subtitle: '围绕本片改编背景、设定或疑问自由提问',
          symbol: 'bubble.left.and.bubble.right.fill',
          section: 0,
        ),
      ],
      if (cfg.moodCurationEnabled)
        const AppleNativePickerOption<String>(
          value: 'ai_similar_curate',
          title: '看完这部看什么（自有源直达）',
          subtitle: '匹配本地已配片源中气质相近的高分佳作',
          symbol: 'wand.and.stars',
          section: 1,
          sectionTitle: '发现与排障',
        ),
      if (cfg.smartDiagnosticsEnabled)
        const AppleNativePickerOption<String>(
          value: 'ai_diagnostics',
          title: '播放与源故障智能排障',
          subtitle: '一键诊断偏色、卡顿、无声或加载失败',
          symbol: 'wrench.and.screwdriver.fill',
          section: 1,
        ),
      for (final skill
          in cfg.effectiveSkills.where((s) => s.target.showsInPlayer))
        AppleNativePickerOption<String>(
          value: 'ai_skill:${skill.id}',
          title: skill.name,
          symbol: 'sparkles',
          section: 2,
          sectionTitle: '扩展技能卡',
        ),
    ];

    void runPicked(String action) {
      switch (action) {
        case 'ai_subtitle_studio':
          _openAiSubtitleStudio();
        case 'ai_watch_brief':
          unawaited(
            showIosAiWatchBriefSheet(
              context,
              title: _activeVideo.title,
              year: _activeVideo.year,
              genreOrRemarks:
                  '${_activeVideo.tag} ${_activeVideo.remarks}'.trim(),
              overview: _activeVideo.description,
            ),
          );
        case 'ai_post_credits':
          unawaited(
            showIosAiPostCreditsSheet(
              context,
              title: _activeVideo.title,
              year: _activeVideo.year,
              overview: _activeVideo.description,
            ),
          );
        case 'ai_work_qa':
          unawaited(
            showIosAiWorkQaSheet(
              context,
              title: _activeVideo.title,
              year: _activeVideo.year,
              overview: _activeVideo.description,
            ),
          );
        case 'ai_similar_curate':
          _openPlayerAiSimilarCurate();
        case 'ai_diagnostics':
          unawaited(
            showIosAiDiagnosticsSheet(
              context,
              rawErrorText: _playbackError.trim().isNotEmpty
                  ? _playbackError
                  : '播放流畅度与兼容性巡检',
              engineName: _activeIosEngineBadgeLabel,
              mediaFormatHint: _currentScrapedEpisode().rawName,
              hasBackupLines: _lines.length > 1,
              onExecuteAction: (act) {
                switch (act) {
                  case AiDiagnosticActionId.switchToMpv:
                    unawaited(
                      _switchIosEngineMode(IosPlaybackEngineMode.mpv),
                    );
                  case AiDiagnosticActionId.switchToAvPlayer:
                    unawaited(
                      _switchIosEngineMode(IosPlaybackEngineMode.avPlayer),
                    );
                  case AiDiagnosticActionId.enableVocalLoudness:
                    _showVocalLoudnessSheet();
                  case AiDiagnosticActionId.switchBackupLine:
                    _showLinesSheet();
                  case AiDiagnosticActionId.openEpisodeScrape:
                    unawaited(_showEpisodeScrapeSheet());
                }
              },
            ),
          );
        default:
          if (action.startsWith('ai_skill:')) {
            final skillId = action.substring('ai_skill:'.length);
            final matched = cfg.effectiveSkills
                .where((s) => s.id == skillId)
                .firstOrNull;
            if (matched != null) {
              unawaited(
                showIosAiCustomSkillOutputSheet(
                  context,
                  skill: matched,
                  title: _activeVideo.title,
                  year: _activeVideo.year,
                  episode: _isMultiVersionMovie
                      ? ''
                      : '第 ${_currentScrapedEpisode().effectiveEpisodeNumber} 集',
                  overview: _activeVideo.description,
                  subtitles: _player.state.subtitle.join('\n'),
                ),
              );
            }
          }
      }
    }

    if (_canUseNativeIosSheet) {
      final session = _playSession;
      unawaited(() async {
        final picked = await showAppleNativeOptionSheet<String>(
          context,
          title: 'AI 观影助手',
          forceOpaque: _effectiveSheetForceOpaque,
          anchorRect: anchorRect,
          forceDark: true,
          options: options,
          fallback: () async {
            _showIosMoreFallbackSheet(
              options,
              runPicked,
              anchorRect: anchorRect,
            );
            return null;
          },
        );
        if (!mounted || session != _playSession || picked == null) return;
        runPicked(picked);
      }());
      return;
    }
    _showIosMoreFallbackSheet(options, runPicked, anchorRect: anchorRect);
  }

  String? _episodeUnavailableReason(
    CmsEpisode episode,
    List<CmsParse> parses,
  ) {
    if (_isLiveStream) return null;
    return WebMediaResolver.episodeUnavailableReason(
      episode,
      site: _activeSite,
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

  void _switchLiveChannel(LiveChannel channel, {int lineIdx = 0}) {
    if (!mounted || channel.episodes.isEmpty) return;
    _clearPendingAutoStartPip();
    _userNavigationGen++;
    _failedLinesForEpisode.clear();
    _failedLiveEpisodes.clear();
    _liveDirectFallbackTried = false;
    _lastLiveUpstreamStatus = null;
    _liveCompanionGroupNotifier.value = channel.group;
    setState(() {
      _activeLiveChannel = channel;
      _lines = [CmsLine(name: channel.group, episodes: channel.episodes)];
      _lineIndex = 0;
      _episodeIndex = lineIdx.clamp(0, channel.episodes.length - 1);
      _lastKnownDurationMs = 0;
      _duration = Duration.zero;
    });
    _showHud('正在切换至 ${channel.name}');
    unawaited(_openCurrentEpisode(resumeMs: 0));
  }

  void _showLiveChannelDrawer({Rect? anchorRect}) {
    final groups = widget.liveGroups.where((g) => g.channels.isNotEmpty).toList();
    if (groups.isEmpty) return;
    final activeName = _activeLiveChannel?.name ?? _activeVideo.title;
    final activeGroup = _activeLiveChannel?.group ?? _currentLine.name;
    var selectedGroupIdx = groups.indexWhere((g) => g.name == activeGroup);
    if (selectedGroupIdx < 0) selectedGroupIdx = 0;
    var query = '';

    Widget buildContent(BuildContext ctx) => StatefulBuilder(
      builder: (ctx, setSheetState) {
        final q = query.trim().toLowerCase();
        final channels = q.isNotEmpty
            ? [
                for (final g in groups)
                  for (final ch in g.channels)
                    if (ch.name.toLowerCase().contains(q) ||
                        g.name.toLowerCase().contains(q))
                      ch,
              ]
            : groups[selectedGroupIdx.clamp(0, groups.length - 1)].channels;
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              child: CupertinoSearchTextField(
                placeholder: '搜索频道名或分类…',
                style: const TextStyle(color: Colors.white, fontSize: 13.5),
                placeholderStyle:
                    const TextStyle(color: Color(0x88FFFFFF), fontSize: 13),
                backgroundColor: const Color(0x22FFFFFF),
                onChanged: (v) => setSheetState(() => query = v),
              ),
            ),
            if (q.isEmpty)
              SizedBox(
                height: 32,
                child: ListView.separated(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  scrollDirection: Axis.horizontal,
                  itemCount: groups.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 6),
                  itemBuilder: (_, idx) {
                    final sel = idx == selectedGroupIdx;
                    final g = groups[idx];
                    return GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => setSheetState(() => selectedGroupIdx = idx),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          color: sel
                              ? AppleColors.systemBlue
                              : const Color(0x22FFFFFF),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          '${g.name} (${g.channels.length})',
                          style: TextStyle(
                            color: sel ? Colors.white : const Color(0xCCFFFFFF),
                            fontSize: 11.5,
                            fontWeight: sel ? FontWeight.w700 : FontWeight.w500,
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            const SizedBox(height: 8),
            Flexible(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 340),
                child: channels.isEmpty
                    ? const Padding(
                        padding: EdgeInsets.all(24),
                        child: Text(
                          '未找到匹配频道',
                          style: TextStyle(
                            color: Color(0x99FFFFFF),
                            fontSize: 13,
                          ),
                        ),
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
                        itemCount: channels.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 6),
                        itemBuilder: (_, idx) {
                          final ch = channels[idx];
                          final isCurrent = ch.name == activeName &&
                              ch.group == activeGroup;
                          final latencyBadge = LiveHealthVisual.badgeText(ch);
                          return GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () {
                              Navigator.of(ctx).pop();
                              _switchLiveChannel(ch);
                            },
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 8,
                              ),
                              decoration: BoxDecoration(
                                color: isCurrent
                                    ? const Color(0x380A84FF)
                                    : const Color(0x18FFFFFF),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: isCurrent
                                      ? const Color(0xAA0A84FF)
                                      : const Color(0x1FFFFFFF),
                                  width: 0.7,
                                ),
                              ),
                              child: Row(
                                children: [
                                  LiveStationBadge(
                                    channel: ch,
                                    size: 34,
                                    radius: 9,
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          ch.name,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 13.5,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                        const SizedBox(height: 2),
                                        Row(
                                          children: [
                                            Container(
                                              width: 6,
                                              height: 6,
                                              decoration: BoxDecoration(
                                                color: LiveHealthVisual.dotColor(
                                                  ch.health,
                                                ),
                                                shape: BoxShape.circle,
                                              ),
                                            ),
                                            const SizedBox(width: 5),
                                            Text(
                                              '${ch.group} · ${ch.episodes.length}路信号',
                                              style: const TextStyle(
                                                color: Color(0xAAFFFFFF),
                                                fontSize: 11,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ],
                                    ),
                                  ),
                                  if (latencyBadge != null) ...[
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 6,
                                        vertical: 2,
                                      ),
                                      decoration: BoxDecoration(
                                        color: LiveHealthVisual.dotColor(
                                          ch.health,
                                        ).withValues(alpha: 0.2),
                                        borderRadius:
                                            BorderRadius.circular(999),
                                      ),
                                      child: Text(
                                        latencyBadge,
                                        style: TextStyle(
                                          color: LiveHealthVisual.dotColor(
                                            ch.health,
                                          ),
                                          fontSize: 10.5,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                  ],
                                  if (isCurrent)
                                    const Icon(
                                      CupertinoIcons.checkmark_alt,
                                      color: AppleColors.systemBlue,
                                      size: 16,
                                    ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ),
          ],
        );
      },
    );

    if (_useIos26PlayerChrome) {
      showIosGlassPopover<void>(
        context: context,
        title: '切换频道',
        anchorRect: anchorRect,
        maxWidth: 340,
        maxHeight: 460,
        forceDark: true,
        builder: buildContent,
      );
      return;
    }
    showAppleModalSheet<void>(
      context: context,
      title: '切换频道',
      maxWidth: 480,
      builder: buildContent,
    );
  }

  int _currentLineSwitchResumeMs() {
    if (_isLiveStream) return 0;
    if (_position.inMilliseconds >= 1000) return _position.inMilliseconds;
    if (_pendingResumeMs >= 1000) return _pendingResumeMs;
    if (_lastKnownPositionMs >= 1000) return _lastKnownPositionMs;
    return 0;
  }

  void _switchToLine(int targetLineIndex, {Rect? anchorRect}) {
    if (!mounted ||
        targetLineIndex < 0 ||
        targetLineIndex >= _lines.length ||
        targetLineIndex == _lineIndex) {
      return;
    }
    _userNavigationGen++;
    final originalLine = _currentLine;
    final originalEpisodeIndex = _episodeIndex;
    final targetLine = _lines[targetLineIndex];
    final keepPos = _currentLineSwitchResumeMs();
    final override = widget.storage.getSeriesScrapeOverride(
      _activeSite.key,
      _activeVideo.id,
      isPrivate: _activeSite.isEffectivelyPrivate,
    );
    final match = SeriesScraper.matchEpisodeAcrossLines(
      fromLine: originalLine,
      fromEpisodeIndex: originalEpisodeIndex,
      targetLine: targetLine,
      seriesTitle: _activeVideo.title,
      override: override,
    );
    if (!match.isMatched) {
      final notice = match.kind == CrossLineEpisodeMatchKind.ambiguous
          ? '「${targetLine.name}」存在多个候选剧集，请手动选择要播放的剧集'
          : '未能在「${targetLine.name}」中唯一匹配当前剧集，请手动选集';
      _showHud(notice);
      _showEpisodesSheet(
        anchorRect: anchorRect,
        initialLineIndex: targetLineIndex,
        initialNotice: notice,
      );
      return;
    }
    _failedLinesForEpisode.clear();
    _failedLiveEpisodes.clear();
    _saveProgress(immediate: true, syncImmediate: false);
    setState(() {
      _lineIndex = targetLineIndex;
      _episodeIndex = match.episodeIndex!;
    });
    _openCurrentEpisode(resumeMs: keepPos);
  }

  WorkSourceRef _workSourceRefFor(CmsSite site, CmsVideo video) =>
      WorkSourceRef(
        subscriptionId: site.subscriptionId,
        site: site,
        videoId: video.id,
        video: video,
        sourceLabel: site.name,
      );

  void _seedCrossSiteSources() {
    final currentRef = _workSourceRefFor(_activeSite, _activeVideo);
    final activeId = WorkAggregation.extractIdentity(
      _activeVideo,
      site: _activeSite,
    );
    final seen = <String>{currentRef.identityKey};
    final sources = <WorkSourceRef>[currentRef];
    final refByKey = <String, WorkSourceRef>{currentRef.identityKey: currentRef};
    for (final ref in widget.alternativeSources) {
      if (ref.identityKey == currentRef.identityKey) continue;
      final refId = WorkAggregation.extractIdentity(ref.video, site: ref.site);
      if (!WorkAggregation.isSameWorkIdentity(activeId, refId)) {
        continue;
      }
      if (seen.add(ref.identityKey)) {
        sources.add(ref);
        refByKey[ref.identityKey] = ref;
      }
    }
    _crossSiteSources = sources;
    for (final entry in widget.preloadedSourceDetails.entries) {
      if (entry.key == currentRef.identityKey) {
        _crossSiteDetails[entry.key] = entry.value;
        continue;
      }
      final ref = refByKey[entry.key];
      final detailId = WorkAggregation.extractIdentity(
        entry.value,
        site: ref?.site,
      );
      if (WorkAggregation.isSameWorkIdentity(activeId, detailId)) {
        _crossSiteDetails[entry.key] = entry.value;
      }
    }
    if (_activeVideo.lines.any((l) => l.episodes.isNotEmpty)) {
      _crossSiteDetails[currentRef.identityKey] = _activeVideo;
    }
  }

  bool _matchesActiveWorkIdentity(CmsVideo candidate, {CmsSite? site}) {
    final activeId = WorkAggregation.extractIdentity(
      _activeVideo,
      site: _activeSite,
    );
    final candidateId = WorkAggregation.extractIdentity(candidate, site: site);
    return WorkAggregation.isSameWorkIdentity(activeId, candidateId);
  }

  Future<void> _ensureCrossSiteSourcesLoaded(VoidCallback onSheetUpdate) async {
    if (!mounted || _isLiveStream || _activeSite.isEmby) return;
    if (_crossSiteAbort?.isCompleted == false) _crossSiteAbort!.complete();
    final abort = _crossSiteAbort = Completer<void>();
    _loadingCrossSiteSources = true;
    onSheetUpdate();

    Future<void> hydrate(WorkSourceRef ref) async {
      if (!mounted || abort.isCompleted) return;
      final existing = _crossSiteDetails[ref.identityKey];
      if (existing != null && existing.lines.any((l) => l.episodes.isNotEmpty)) {
        if (_matchesActiveWorkIdentity(existing, site: ref.site)) {
          return;
        }
        _crossSiteDetails.remove(ref.identityKey);
        _crossSiteSources = _crossSiteSources
            .where((r) => r.identityKey != ref.identityKey)
            .toList(growable: false);
        _crossSiteErrors[ref.identityKey] = '目标作品版本不一致';
        onSheetUpdate();
        return;
      }
      final reqAbort = Completer<void>();
      final timer = Timer(const Duration(seconds: 8), () {
        if (!reqAbort.isCompleted) reqAbort.complete();
      });
      try {
        final (owner, detailed) = await _client.runSourceOperation(
          () => _client.playableDetail(ref.site, ref.video, const []),
          cancellation: reqAbort,
        );
        if (!mounted || abort.isCompleted) return;
        final normalized = WoggSource.normalizeCachedVideoLabels(owner, detailed);
        if (!_matchesActiveWorkIdentity(normalized, site: owner)) {
          _crossSiteDetails.remove(ref.identityKey);
          _crossSiteSources = _crossSiteSources
              .where((r) => r.identityKey != ref.identityKey)
              .toList(growable: false);
          _crossSiteErrors[ref.identityKey] = '目标作品版本不一致';
          onSheetUpdate();
          return;
        }
        if (owner.key == ref.site.key &&
            normalized.lines.any((l) => l.episodes.isNotEmpty)) {
          _crossSiteDetails[ref.identityKey] = normalized;
          _crossSiteErrors.remove(ref.identityKey);
          onSheetUpdate();
        } else if (ref.video.lines.any((l) => l.episodes.isNotEmpty) &&
            _matchesActiveWorkIdentity(ref.video, site: ref.site)) {
          _crossSiteDetails[ref.identityKey] =
              WoggSource.normalizeCachedVideoLabels(ref.site, ref.video);
          _crossSiteErrors.remove(ref.identityKey);
          onSheetUpdate();
        }
      } catch (e) {
        if (!mounted || abort.isCompleted) return;
        if (ref.video.lines.any((l) => l.episodes.isNotEmpty) &&
            _matchesActiveWorkIdentity(ref.video, site: ref.site)) {
          _crossSiteDetails[ref.identityKey] =
              WoggSource.normalizeCachedVideoLabels(ref.site, ref.video);
          _crossSiteErrors.remove(ref.identityKey);
        } else {
          _crossSiteErrors[ref.identityKey] = CmsClient.cleanErrorMessage(e);
        }
        onSheetUpdate();
      } finally {
        timer.cancel();
      }
    }

    try {
      // Phase 1: Hydrate sibling sources passed from Detail / Search.
      final pending = _crossSiteSources
          .where((r) =>
              r.siteIdentityKey !=
                  '${_activeSite.subscriptionId}:${_activeSite.key}' &&
              !(_crossSiteDetails[r.identityKey]
                      ?.lines
                      .any((l) => l.episodes.isNotEmpty) ??
                  false))
          .toList();
      for (var i = 0; i < pending.length && !abort.isCompleted; i += 2) {
        await Future.wait(pending.skip(i).take(2).map(hydrate));
      }

      // Phase 2: If only the active site is known so far on Windows desktop,
      // discover sibling sources across enabled searchable sites.
      if (!mounted || abort.isCompleted) return;
      if (_isWindowsPlayerPlatform &&
          _crossSiteSources.length <= 1 &&
          _activeVideo.title.trim().isNotEmpty) {
        final keyword = WorkAggregation.searchKeywordFor(_activeVideo);
        final primaryId = WorkAggregation.extractIdentity(
          _activeVideo,
          site: _activeSite,
        );
        final knownSiteKeys = <String>{
          for (final r in _crossSiteSources) r.siteIdentityKey,
        };
        final knownRawSiteKeys = <String>{
          for (final r in _crossSiteSources) r.site.key,
        };
        final savedSites = widget.storage.prioritizeSites(
          widget.storage.loadSavedConfig()?.availableSites ?? const <CmsSite>[],
        );
        final targets = savedSites
            .where((s) =>
                s.supported &&
                s.searchable &&
                !s.isEmby &&
                s.isEffectivelyPrivate == _activeSite.isEffectivelyPrivate &&
                !knownSiteKeys.contains('${s.subscriptionId}:${s.key}') &&
                !knownRawSiteKeys.contains(s.key))
            .take(6)
            .toList();

        for (var i = 0; i < targets.length && !abort.isCompleted; i += 2) {
          final batch = targets.skip(i).take(2).toList();
          final found = <WorkSourceRef>[];
          await Future.wait(batch.map((site) async {
            if (abort.isCompleted) return;
            final reqAbort = Completer<void>();
            final timer = Timer(const Duration(seconds: 6), () {
              if (!reqAbort.isCompleted) reqAbort.complete();
            });
            try {
              final listing = await _client.runSourceOperation(
                () => _client.fetchSearch(site, keyword),
                cancellation: reqAbort,
              );
              if (!mounted || abort.isCompleted) return;
              for (final cand in listing.videos) {
                final candId =
                    WorkAggregation.extractIdentity(cand, site: site);
                if (WorkAggregation.isSameWorkIdentity(primaryId, candId)) {
                  found.add(_workSourceRefFor(site, cand));
                  break;
                }
              }
            } catch (_) {
            } finally {
              timer.cancel();
            }
          }));
          if (!mounted || abort.isCompleted) return;
          if (found.isNotEmpty) {
            final seenKeys = <String>{
              for (final r in _crossSiteSources) r.identityKey,
            };
            final added = <WorkSourceRef>[
              for (final r in found)
                if (seenKeys.add(r.identityKey)) r,
            ];
            if (added.isNotEmpty) {
              _crossSiteSources = <WorkSourceRef>[
                ..._crossSiteSources,
                ...added,
              ];
              onSheetUpdate();
              await Future.wait(added.map(hydrate));
            }
          }
        }
      }
    } finally {
      _loadingCrossSiteSources = false;
      onSheetUpdate();
    }
  }

  void _restoreCrossSiteRollback(_CrossSiteRollbackSnapshot rb) {
    if (!mounted) return;
    _releaseSourceSession?.call();
    _releaseSourceSession = _client.pinPlaybackSource(rb.site);
    setState(() {
      _activeSite = rb.site;
      _activeVideo = rb.video;
      _lines = List<CmsLine>.of(rb.lines);
      _lineIndex = rb.lineIndex.clamp(0, math.max(0, _lines.length - 1));
      _episodeIndex = rb.episodeIndex.clamp(
        0,
        math.max(0, _currentLine.episodes.length - 1),
      );
      _isFavorite = widget.storage.isFavorite(
        _activeSite.key,
        _activeVideo.id,
        forPrivate: _activeSite.isEffectivelyPrivate,
      );
      _skipIntroSec = widget.storage.getVideoSkipIntroSec(
        _activeSite.key,
        _activeVideo.id,
        isPrivate: _activeSite.isEffectivelyPrivate,
      );
      _skipOutroSec = widget.storage.getVideoSkipOutroSec(
        _activeSite.key,
        _activeVideo.id,
        isPrivate: _activeSite.isEffectivelyPrivate,
      );
    });
    _showHud('${rb.failedSiteName} 播放失败，已保留原片源 ${rb.site.name} 继续播放');
    unawaited(_openCurrentEpisode(resumeMs: rb.resumeMs));
  }

  Future<void> _switchToCrossSiteSource(
    WorkSourceRef targetRef, {
    int? targetLineIndex,
    int? explicitEpisodeIndex,
    bool forceRefreshDetail = false,
  }) async {
    if (!mounted) return;
    final prevSite = _activeSite;
    final prevVideo = _activeVideo;
    final prevLines = List<CmsLine>.of(_lines);
    final prevLineIndex = _lineIndex;
    final prevEpisodeIndex = _episodeIndex;
    final prevResumeMs = _currentLineSwitchResumeMs();
    final prevWorkId = WorkAggregation.extractIdentity(
      prevVideo,
      site: prevSite,
    );

    if (targetRef.siteIdentityKey ==
            '${prevSite.subscriptionId}:${prevSite.key}' &&
        targetRef.videoId == prevVideo.id &&
        targetLineIndex != null) {
      _switchToLine(targetLineIndex);
      return;
    }

    final switchGen = ++_userNavigationGen;
    final startPlaySession = _playSession;

    bool isSuperseded() =>
        !mounted ||
        switchGen != _userNavigationGen ||
        _playSession != startPlaySession;

    try {
      // 1. Verify cached detail (if any) or fetch target site's own detail.
      CmsVideo? targetVideo = forceRefreshDetail
          ? null
          : _crossSiteDetails[targetRef.identityKey];
      if (targetVideo != null &&
          !WorkAggregation.isSameWorkIdentity(
            prevWorkId,
            WorkAggregation.extractIdentity(targetVideo, site: targetRef.site),
          )) {
        _crossSiteDetails.remove(targetRef.identityKey);
        _crossSiteSources = _crossSiteSources
            .where((r) => r.identityKey != targetRef.identityKey)
            .toList(growable: false);
        _crossSiteErrors[targetRef.identityKey] = '目标作品版本不一致';
        _showHud('${targetRef.site.name} 详情与当前作品不一致，已保留当前播放');
        return;
      }
      if (targetVideo == null ||
          !targetVideo.lines.any((l) => l.episodes.isNotEmpty)) {
        _showHud('正在连接 ${targetRef.site.name}…');
        try {
          final (owner, detailed) = await _client
              .playableDetail(targetRef.site, targetRef.video, const [])
              .timeout(const Duration(seconds: 15));
          if (isSuperseded()) return;
          final normalized =
              WoggSource.normalizeCachedVideoLabels(owner, detailed);
          if (!WorkAggregation.isSameWorkIdentity(
            prevWorkId,
            WorkAggregation.extractIdentity(normalized, site: owner),
          )) {
            _crossSiteDetails.remove(targetRef.identityKey);
            _crossSiteSources = _crossSiteSources
                .where((r) => r.identityKey != targetRef.identityKey)
                .toList(growable: false);
            _crossSiteErrors[targetRef.identityKey] = '目标作品版本不一致';
            _showHud('${targetRef.site.name} 详情与当前作品不一致，已保留当前播放');
            return;
          }
          if (owner.key != targetRef.site.key ||
              !normalized.lines.any((l) => l.episodes.isNotEmpty)) {
            throw const FormatException('目标片源未返回可播放剧集');
          }
          targetVideo = normalized;
          _crossSiteDetails[targetRef.identityKey] = normalized;
          _crossSiteErrors.remove(targetRef.identityKey);
        } catch (e) {
          if (isSuperseded()) return;
          final errMsg = CmsClient.cleanErrorMessage(e);
          _crossSiteErrors[targetRef.identityKey] = errMsg;
          _showHud('切换至 ${targetRef.site.name} 失败：$errMsg，已保留当前播放');
          return;
        }
      }

      if (isSuperseded()) return;
      if (!WorkAggregation.isSameWorkIdentity(
        prevWorkId,
        WorkAggregation.extractIdentity(targetVideo, site: targetRef.site),
      )) {
        _crossSiteDetails.remove(targetRef.identityKey);
        _crossSiteSources = _crossSiteSources
            .where((r) => r.identityKey != targetRef.identityKey)
            .toList(growable: false);
        _crossSiteErrors[targetRef.identityKey] = '目标作品版本不一致';
        _showHud('${targetRef.site.name} 详情与当前作品不一致，已保留当前播放');
        return;
      }
      final targetLines = targetVideo.lines
          .where((l) => l.episodes.isNotEmpty)
          .toList(growable: false);
      if (targetLines.isEmpty) {
        _showHud('切换至 ${targetRef.site.name} 失败：暂无可用线路，已保留当前播放');
        return;
      }
      final safeTargetLineIdx =
          (targetLineIndex ?? 0).clamp(0, targetLines.length - 1);
      final targetLine = targetLines[safeTargetLineIdx];

      // 2. Match current episode across sites using SeriesScraper identity.
      final match = SeriesScraper.matchEpisodeAcrossLines(
        fromLine: prevLines[prevLineIndex],
        fromEpisodeIndex: prevEpisodeIndex,
        targetLine: targetLine,
        seriesTitle: targetVideo.title.isNotEmpty
            ? targetVideo.title
            : prevVideo.title,
      );

      late final int matchedEpIndex;
      late final bool shouldInheritProgress;
      if (explicitEpisodeIndex != null) {
        matchedEpIndex =
            explicitEpisodeIndex.clamp(0, targetLine.episodes.length - 1);
        shouldInheritProgress =
            match.isMatched && match.episodeIndex == matchedEpIndex;
      } else if (!match.isMatched) {
        final notice = match.kind == CrossLineEpisodeMatchKind.ambiguous
            ? '「${targetRef.site.name} · ${targetLine.name}」存在多个候选剧集，请手动选择要播放的剧集'
            : '未能在「${targetRef.site.name} · ${targetLine.name}」中唯一匹配当前剧集，请手动选集';
        _showHud(notice);
        _showCrossSiteEpisodeDisambiguationSheet(
          targetRef: targetRef,
          targetVideo: targetVideo,
          targetLines: targetLines,
          targetLineIndex: safeTargetLineIdx,
          notice: notice,
        );
        return;
      } else {
        matchedEpIndex = match.episodeIndex!;
        shouldInheritProgress = true;
      }

      // 3. Pre-resolve target episode using targetSite's OWN parser & headers
      // BEFORE interrupting current Site A playback!
      final targetEpisode = targetLine.episodes[matchedEpIndex];
      final savedCfg = widget.storage.loadSavedConfig();
      CmsEpisode resolvedTarget;
      if (targetEpisode.isLocalFile) {
        resolvedTarget = targetEpisode;
      } else {
        try {
          resolvedTarget = await _client
              .resolveEpisodeForPlayback(
                targetRef.site,
                targetEpisode,
                parses: savedCfg?.parses ?? const [],
                rules: savedCfg?.rules ?? const [],
                ads: savedCfg?.ads ?? const [],
              )
              .timeout(const Duration(seconds: 25));
          if (isSuperseded()) {
            await _cloudMedia.discard(
              PlayerCloudMediaSession.of(resolvedTarget),
            );
            return;
          }
          if (resolvedTarget.url.trim().isEmpty) {
            await _cloudMedia.discard(
              PlayerCloudMediaSession.of(resolvedTarget),
            );
            throw const FormatException('目标片源解析结果为空');
          }
        } catch (e) {
          if (isSuperseded()) return;
          final errMsg = CmsClient.cleanErrorMessage(e);
          _crossSiteErrors[targetRef.identityKey] = errMsg;
          _showHud('切换至 ${targetRef.site.name} 失败：$errMsg，已保留当前播放');
          return;
        }
      }

      // 4. Final guard before commit: reject if superseded by a newer user
      // action or if target detail identity no longer matches active work.
      if (isSuperseded() ||
          !WorkAggregation.isSameWorkIdentity(
            prevWorkId,
            WorkAggregation.extractIdentity(targetVideo, site: targetRef.site),
          )) {
        await _cloudMedia.discard(PlayerCloudMediaSession.of(resolvedTarget));
        return;
      }

      final latestResumeMs =
          shouldInheritProgress ? _currentLineSwitchResumeMs() : 0;
      final commitResumeMs = shouldInheritProgress
          ? (latestResumeMs > 0 ? latestResumeMs : prevResumeMs)
          : 0;

      // Commit cross-site switch atomically with stream-failure rollback guard.
      _saveProgress(immediate: true, syncImmediate: false);
      _pendingCrossSiteRollback = _CrossSiteRollbackSnapshot(
        site: prevSite,
        video: prevVideo,
        lines: prevLines,
        lineIndex: prevLineIndex,
        episodeIndex: prevEpisodeIndex,
        resumeMs: commitResumeMs,
        targetSession: _playSession + 1,
        failedSiteName: targetRef.site.name,
      );
      _releaseSourceSession?.call();
      _releaseSourceSession = _client.pinPlaybackSource(targetRef.site);
      _failedLinesForEpisode.clear();
      _failedLiveEpisodes.clear();
      setState(() {
        _activeSite = targetRef.site;
        _activeVideo = targetVideo!;
        _lines = List<CmsLine>.of(targetLines);
        _lineIndex = safeTargetLineIdx;
        _episodeIndex = matchedEpIndex;
        _isFavorite = widget.storage.isFavorite(
          _activeSite.key,
          _activeVideo.id,
          forPrivate: _activeSite.isEffectivelyPrivate,
        );
        _skipIntroSec = widget.storage.getVideoSkipIntroSec(
          _activeSite.key,
          _activeVideo.id,
          isPrivate: _activeSite.isEffectivelyPrivate,
        );
        _skipOutroSec = widget.storage.getVideoSkipOutroSec(
          _activeSite.key,
          _activeVideo.id,
          isPrivate: _activeSite.isEffectivelyPrivate,
        );
      });
      _showHud(
        '已切换至 ${_activeSite.name} · ${targetLine.name}${commitResumeMs > 0 ? '，正在续播…' : ''}',
      );
      unawaited(
        _openCurrentEpisode(
          resumeMs: commitResumeMs,
          preResolvedEpisode: resolvedTarget,
        ),
      );
    } finally {}
  }

  void _showCrossSiteEpisodeDisambiguationSheet({
    required WorkSourceRef targetRef,
    required CmsVideo targetVideo,
    required List<CmsLine> targetLines,
    required int targetLineIndex,
    required String notice,
  }) {
    final targetLine = targetLines[targetLineIndex];
    showAppleModalSheet<void>(
      context: context,
      title: '选择剧集 · ${targetRef.site.name} · ${targetLine.name}',
      maxWidth: 520,
      builder: (ctx) => ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.all(16),
        children: [
          Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(
              color: AppleColors.systemOrange.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: AppleColors.systemOrange.withValues(alpha: 0.35),
              ),
            ),
            child: Text(
              notice,
              style: const TextStyle(
                color: Color(0xFFFFD8A8),
                fontSize: 12.5,
                height: 1.4,
              ),
            ),
          ),
          AppleGroupedSection(
            children: List.generate(targetLine.episodes.length, (i) {
              final ep = targetLine.episodes[i];
              return AppleGroupedTile(
                key: ValueKey('cross-site-disambig-ep-${targetRef.site.key}-$i'),
                icon: CupertinoIcons.play_circle,
                iconBgColor: AppleColors.systemBlue,
                title: ep.name,
                subtitle: '${targetRef.site.name} · ${targetLine.name}',
                onTap: () {
                  Navigator.of(ctx).pop();
                  unawaited(
                    _switchToCrossSiteSource(
                      targetRef,
                      targetLineIndex: targetLineIndex,
                      explicitEpisodeIndex: i,
                    ),
                  );
                },
              );
            }),
          ),
        ],
      ),
    );
  }

  void _showCrossSiteSourcesSheet({Rect? anchorRect}) {
    _cancelTransientInteractions(GestureInterruptReason.dialogOpened);
    if (_hasLiveChannelCatalog) {
      _showLiveChannelDrawer(anchorRect: anchorRect);
      return;
    }
    final parses = widget.storage.loadSavedConfig()?.parses ?? const [];
    final lineReasons = List<String?>.generate(
      _lines.length,
      (i) => _lineUnavailableReason(_lines[i], parses),
      growable: false,
    );
    var kickedOffLoad = false;

    Widget buildContent(BuildContext ctx) => StatefulBuilder(
          builder: (sheetCtx, setSheetState) {
            if (!kickedOffLoad) {
              kickedOffLoad = true;
              unawaited(
                _ensureCrossSiteSourcesLoaded(() {
                  if (sheetCtx.mounted) setSheetState(() {});
                }),
              );
            }
            final otherSources = _crossSiteSources
                .where((r) =>
                    r.siteIdentityKey !=
                        '${_activeSite.subscriptionId}:${_activeSite.key}' ||
                    r.videoId != _activeVideo.id)
                .toList();
            return ListView(
              key: const Key('cross-site-sources-sheet'),
              shrinkWrap: true,
              padding: EdgeInsets.all(_useIos26PlayerChrome ? 4 : 16),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
                  child: Text(
                    '当前站点 · ${_activeSite.name}',
                    style: const TextStyle(
                      color: AppleColors.labelSecondary,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
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
                          unawaited(
                            showAppleNativeAlert(
                              ctx,
                              title: _lines[i].name,
                              message: lineReason,
                              actions: const [
                                AppleNativeAlertAction(
                                  id: 'ok',
                                  title: '我知道了',
                                  isDefault: true,
                                ),
                              ],
                            ),
                          );
                          return;
                        }
                        Navigator.of(ctx).pop();
                        _switchToLine(i, anchorRect: anchorRect);
                      },
                    );
                    return lineReason != null
                        ? Opacity(opacity: 0.48, child: tile)
                        : tile;
                  }),
                ),
                if (otherSources.isNotEmpty || _loadingCrossSiteSources) ...[
                  const SizedBox(height: 16),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            otherSources.isNotEmpty
                                ? '其他站片源 (${otherSources.length})'
                                : '正在查找其他站同剧片源…',
                            style: const TextStyle(
                              color: AppleColors.labelSecondary,
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        if (_loadingCrossSiteSources)
                          const SizedBox(
                            width: 14,
                            height: 14,
                            child: CupertinoActivityIndicator(radius: 7),
                          ),
                      ],
                    ),
                  ),
                  if (otherSources.isNotEmpty)
                    AppleGroupedSection(
                      children: [
                        for (final ref in otherSources)
                          ...() {
                            final hydrated = _crossSiteDetails[ref.identityKey];
                            final err = _crossSiteErrors[ref.identityKey];
                            if (hydrated != null && hydrated.lines.isNotEmpty) {
                              return List<Widget>.generate(
                                hydrated.lines.length,
                                (lineIdx) {
                                  final line = hydrated.lines[lineIdx];
                                  return AppleGroupedTile(
                                    key: ValueKey(
                                      'cross-site-line-${ref.site.key}-$lineIdx',
                                    ),
                                    icon: CupertinoIcons.arrow_2_squarepath,
                                    iconBgColor: AppleColors.systemIndigo,
                                    title: '${ref.site.name} · ${line.name}',
                                    subtitle:
                                        '共 ${line.episodes.length} 集 · 点此跨站续播',
                                    onTap: () {
                                      Navigator.of(ctx).pop();
                                      unawaited(
                                        _switchToCrossSiteSource(
                                          ref,
                                          targetLineIndex: lineIdx,
                                        ),
                                      );
                                    },
                                  );
                                },
                              );
                            }
                            return <Widget>[
                              AppleGroupedTile(
                                key: ValueKey(
                                  'cross-site-source-${ref.site.key}',
                                ),
                                icon: CupertinoIcons.globe,
                                iconBgColor: err != null
                                    ? AppleColors.systemOrange
                                    : AppleColors.groupedTertiary,
                                title: ref.site.name,
                                subtitle: err != null
                                    ? '连接失败：$err（点此重试）'
                                    : (_loadingCrossSiteSources
                                        ? '正在读取该站线路…（点此直接尝试切换）'
                                        : '点此拉取该站线路并续播'),
                                onTap: () {
                                  Navigator.of(ctx).pop();
                                  unawaited(
                                    _switchToCrossSiteSource(
                                      ref,
                                      forceRefreshDetail: err != null,
                                    ),
                                  );
                                },
                              ),
                            ];
                          }(),
                      ],
                    ),
                ],
              ],
            );
          },
        );

    if (_useIos26PlayerChrome) {
      showIosGlassPopover<void>(
        context: context,
        anchorRect: anchorRect,
        title: '切换片源与线路',
        maxWidth: 320,
        maxHeight: 380,
        forceDark: true,
        builder: buildContent,
      );
      return;
    }
    showAppleModalSheet<void>(
      context: context,
      title: '切换片源与线路',
      maxWidth: 520,
      builder: buildContent,
    );
  }

  void _showLinesSheet({Rect? anchorRect}) {
    if (!_isLiveStream && !_hasLiveChannelCatalog && !_useIos26PlayerChrome) {
      _showCrossSiteSourcesSheet(anchorRect: anchorRect);
      return;
    }
    _cancelTransientInteractions(GestureInterruptReason.dialogOpened);
    if (_hasLiveChannelCatalog) {
      _showLiveChannelDrawer(anchorRect: anchorRect);
      return;
    }
    final parses = widget.storage.loadSavedConfig()?.parses ?? const [];
    final lineReasons = List<String?>.generate(
      _lines.length,
      (i) => _lineUnavailableReason(_lines[i], parses),
      growable: false,
    );
    Widget buildContent(BuildContext ctx) => ListView(
      shrinkWrap: true,
      padding: EdgeInsets.all(_useIos26PlayerChrome ? 4 : 16),
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
                  unawaited(
                    showAppleNativeAlert(
                      ctx,
                      title: _lines[i].name,
                      message: lineReason,
                      actions: const [
                        AppleNativeAlertAction(
                          id: 'ok',
                          title: '我知道了',
                          isDefault: true,
                        ),
                      ],
                    ),
                  );
                  return;
                }
                Navigator.of(ctx).pop();
                _switchToLineWithConflictGuard(i);
              },
            );
            return lineReason != null
                ? Opacity(opacity: 0.48, child: tile)
                : tile;
          }),
        ),
      ],
    );
    if (_useIos26PlayerChrome) {
      showIosGlassPopover<void>(
        context: context,
        anchorRect: anchorRect,
        title: '切换播放线路',
        maxWidth: 290,
        maxHeight: 300,
        forceDark: true,
        builder: buildContent,
      );
      return;
    }
    showAppleModalSheet<void>(
      context: context,
      title: '切换播放线路',
      builder: buildContent,
    );
  }

  void _showEpisodesSheet({
    Rect? anchorRect,
    int? initialLineIndex,
    String? initialNotice,
  }) {
    _cancelTransientInteractions(GestureInterruptReason.dialogOpened);
    final screenSize = MediaQuery.sizeOf(context);
    final isLandscape = screenSize.width > screenSize.height;
    final parses = widget.storage.loadSavedConfig()?.parses ?? const [];
    final previewLineIdx = (initialLineIndex ?? _lineIndex)
        .clamp(0, math.max(0, _lines.length - 1))
        .toInt();
    String? episodeChecker(CmsEpisode ep) =>
        _episodeUnavailableReason(ep, parses);
    final override = widget.storage.getSeriesScrapeOverride(
      widget.site.key,
      widget.video.id,
      isPrivate: widget.site.isEffectivelyPrivate,
    );
    final scrapeResults = _isLiveStream
        ? null
        : List<LineEpisodeScrapeResult>.generate(
            _lines.length,
            (i) => _scrapeLineEpisodesFor(_lines[i], override: override),
            growable: false,
          );
    final canCalibrate = !_isLiveStream && !widget.site.isEffectivelyPrivate;
    final startLineIndex = (initialLineIndex ?? _lineIndex)
        .clamp(0, math.max(0, _lines.length - 1))
        .toInt();
    final isMovieVersions = _isMultiVersionMovie;
    Widget buildPicker(BuildContext ctx) => PlayerEpisodePickerSheet(
      lines: _lines,
      initialLineIndex: startLineIndex,
      activeLineIndex: _lineIndex,
      activeEpisodeIndex: _episodeIndex,
      initialNotice: initialNotice,
      episodeUnavailableReason: episodeChecker,
      episodeScrapeOverride: _episodeScrapeOverride,
      seriesTitle: _effectiveScrapeTitle,
      isMultiVersionMovie: isMovieVersions,
      onOpenScrape: (_isLiveStream || isMovieVersions)
          ? null
          : () {
              Navigator.of(ctx).pop();
              unawaited(_showEpisodeScrapeSheet());
            },
      lineScrapeResults: scrapeResults,
      scrapeOverride: override,
      onCalibrateCurrent: (canCalibrate && !isMovieVersions)
          ? () {
              Navigator.of(ctx).pop();
              unawaited(_openPlayerSeriesScrapeSheet());
            }
          : null,
      onSelect: (lineIdx, epIdx) {
        Navigator.of(ctx).pop();
        _userNavigationGen++;
        final originalLineIndex = _lineIndex;
        final originalLine = _currentLine;
        final originalEpisodeIndex = _episodeIndex;
        final targetLine = _lines[lineIdx];
        final keepPosCandidate = _currentLineSwitchResumeMs();
        final override = widget.storage.getSeriesScrapeOverride(
          _activeSite.key,
          _activeVideo.id,
          isPrivate: _activeSite.isEffectivelyPrivate,
        );
        final sameEpisode = !_isLiveStream &&
            ((lineIdx == originalLineIndex && epIdx == originalEpisodeIndex) ||
                SeriesScraper.isSameEpisodeAcrossLines(
                  fromLine: originalLine,
                  fromEpisodeIndex: originalEpisodeIndex,
                  targetLine: targetLine,
                  targetEpisodeIndex: epIdx,
                  seriesTitle: _activeVideo.title,
                  override: override,
                ));
        final curInfo = _currentScrapedEpisodeInfo(override: override);
        final nextInfo = (scrapeResults != null &&
                lineIdx >= 0 &&
                lineIdx < scrapeResults.length)
            ? scrapeResults[lineIdx].infoForOriginalIndex(epIdx)
            : null;
        final sameLogicalEpisode = !_isLiveStream &&
            ((lineIdx == originalLineIndex && epIdx == originalEpisodeIndex) ||
                (curInfo != null &&
                    nextInfo != null &&
                    !curInfo.needsConfirmation &&
                    !nextInfo.needsConfirmation &&
                    curInfo.resolvedEpisodeNumber != null &&
                    curInfo.resolvedEpisodeNumber ==
                        nextInfo.resolvedEpisodeNumber &&
                    curInfo.seasonNumber == nextInfo.seasonNumber));
        final keepPos =
            (sameEpisode || sameLogicalEpisode) ? keepPosCandidate : 0;
        _failedLinesForEpisode.clear();
        _failedLiveEpisodes.clear();
        _saveProgress(immediate: true, syncImmediate: false);
        setState(() {
          _lineIndex = lineIdx;
          _episodeIndex = epIdx;
        });
        _openCurrentEpisode(resumeMs: keepPos);
      },
    );
    final pickerTitle = isMovieVersions
        ? '切换片源版本 (${_lines[previewLineIdx].episodes.length})'
        : '选集与线路 (${_lines[previewLineIdx].episodes.length})';
    if (_useIos26PlayerChrome) {
      showIosGlassPopover<void>(
        context: context,
        anchorRect: anchorRect,
        title: pickerTitle,
        maxWidth: math.min(screenSize.width - 32, isLandscape ? 380.0 : 320.0),
        maxHeight: math.min(screenSize.height - 80, 340.0),
        forceDark: true,
        contentPadding: const EdgeInsets.fromLTRB(6, 4, 6, 8),
        builder: buildPicker,
      );
      return;
    }
    showAppleModalSheet<void>(
      context: context,
      title: pickerTitle,
      maxWidth: isLandscape ? math.min(screenSize.width - 24, 760.0) : 560.0,
      builder: buildPicker,
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
  final String? initialNotice;
  final String? Function(CmsEpisode episode)? episodeUnavailableReason;
  final EpisodeScrapeOverride episodeScrapeOverride;
  final String seriesTitle;
  final bool isMultiVersionMovie;
  final VoidCallback? onOpenScrape;
  final List<LineEpisodeScrapeResult>? lineScrapeResults;
  final SeriesScrapeOverride? scrapeOverride;
  final VoidCallback? onCalibrateCurrent;
  final void Function(int lineIndex, int episodeIndex) onSelect;

  const PlayerEpisodePickerSheet({
    super.key,
    required this.lines,
    required this.initialLineIndex,
    required this.activeLineIndex,
    required this.activeEpisodeIndex,
    this.initialNotice,
    this.episodeUnavailableReason,
    this.episodeScrapeOverride = const EpisodeScrapeOverride(),
    this.seriesTitle = '',
    this.isMultiVersionMovie = false,
    this.onOpenScrape,
    this.lineScrapeResults,
    this.scrapeOverride,
    this.onCalibrateCurrent,
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
    _groupIndex = _previewLineIndex == widget.activeLineIndex
        ? (widget.activeEpisodeIndex ~/ _groupSize)
        : 0;
    _blockedEpisodeNotice = widget.initialNotice;
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
    final scraped = EpisodeScraper.scrapeLine(
      episodes,
      override: widget.episodeScrapeOverride,
      seriesTitle: widget.seriesTitle,
    );
    final safeLineIdx = widget.lines.isEmpty
        ? 0
        : _previewLineIndex.clamp(0, widget.lines.length - 1).toInt();
    final lineScrape = (widget.lineScrapeResults != null &&
            safeLineIdx < widget.lineScrapeResults!.length)
        ? widget.lineScrapeResults![safeLineIdx]
        : null;
    final useEpisodeScraper =
        !widget.episodeScrapeOverride.isDefault || lineScrape == null;
    final List<int> orderedAll;
    if (useEpisodeScraper) {
      orderedAll = _descending
          ? scraped.visibleRawIndices.reversed.toList(growable: false)
          : List<int>.of(scraped.visibleRawIndices);
    } else {
      final sortByScraped = widget.scrapeOverride?.sortByScrapedEpisode ??
          lineScrape.sourceOrderScrambled;
      final hideSpecials = widget.scrapeOverride?.hideSpecials ?? false;
      orderedAll = List<int>.of(
        lineScrape.orderedIndices(
          sortByScraped: sortByScraped,
          hideSpecials: hideSpecials,
        ),
      );
      if (safeLineIdx == widget.activeLineIndex &&
          widget.activeEpisodeIndex >= 0 &&
          widget.activeEpisodeIndex < episodes.length &&
          !orderedAll.contains(widget.activeEpisodeIndex)) {
        orderedAll.insert(0, widget.activeEpisodeIndex);
      }
    }
    final total = orderedAll.length;
    final groupCount = total <= 0 ? 1 : ((total - 1) ~/ _groupSize) + 1;
    final safeGroup = _groupIndex.clamp(0, math.max(0, groupCount - 1)).toInt();
    final int startIdx = safeGroup * _groupSize;
    final int endIdx = math.min(startIdx + _groupSize, total);

    final indices = orderedAll.sublist(startIdx, endIdx);
    if (!useEpisodeScraper && _descending) {
      indices.setAll(0, indices.reversed.toList(growable: false));
    }

    final screenSize = MediaQuery.sizeOf(context);
    final isLandscape = screenSize.width > screenSize.height;
    final crossAxisCount = isLandscape
        ? (screenSize.width >= 820 ? 5 : 4)
        : (screenSize.width >= 580
            ? 4
            : (screenSize.width < 360 ? 2 : 3));
    final lineBlockedReason = safeLineIdx < _cachedLineBlockedReasons.length
        ? _cachedLineBlockedReasons[safeLineIdx]
        : null;
    final activeNotice = _blockedEpisodeNotice ??
        lineBlockedReason ??
        (_previewLineIndex == widget.initialLineIndex
            ? widget.initialNotice
            : null);

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
            const SizedBox(width: 6),
            if (widget.onCalibrateCurrent != null) ...[
              GestureDetector(
                key: const Key('player-episode-calibrate-btn'),
                onTap: widget.onCalibrateCurrent,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 11,
                    vertical: 7,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0x380A84FF),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                      color: const Color(0x8060A5FA),
                      width: 0.7,
                    ),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        CupertinoIcons.sparkles,
                        size: 13,
                        color: Color(0xFF93C5FD),
                      ),
                      SizedBox(width: 4),
                      Text(
                        '识别／校准本集',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 6),
            ],
            if (widget.onOpenScrape != null) ...[
              GestureDetector(
                onTap: widget.onOpenScrape,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 7,
                  ),
                  decoration: BoxDecoration(
                    color: !widget.episodeScrapeOverride.isDefault
                        ? const Color(0x330A84FF)
                        : const Color(0xCC26262C),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                      color: !widget.episodeScrapeOverride.isDefault
                          ? AppleColors.systemBlue
                          : const Color(0x30FFFFFF),
                      width: 0.65,
                    ),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        CupertinoIcons.sparkles,
                        size: 12.5,
                        color: Color(0xFF64B5FF),
                      ),
                      SizedBox(width: 3),
                      Text(
                        '刮削',
                        style: TextStyle(
                          color: AppleColors.labelPrimary,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 6),
            ],
              GestureDetector(
                key: const ValueKey('player-episodes-sort-toggle'),
                onTap: () => setState(() {
                  _descending = !_descending;
                  _groupIndex = 0;
                }),
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
                  final rangeText = _descending
                      ? '${total - gStart + 1}-${total - gEnd + 1}'
                      : '$gStart-$gEnd';
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
                          rangeText,
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
              child: LayoutBuilder(
                builder: (context, gridConstraints) {
                  final effectiveCols = math.min(
                    crossAxisCount,
                    math.max(2, (gridConstraints.maxWidth / 110).floor()),
                  );
                  return GridView.builder(
                shrinkWrap: true,
                physics: const BouncingScrollPhysics(),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: effectiveCols,
                  mainAxisSpacing: 8,
                  crossAxisSpacing: 8,
                  mainAxisExtent: 56,
                ),
                itemCount: indices.length,
                itemBuilder: (ctx, idx) {
                  final epIndex = indices[idx];
                  final ep = episodes[epIndex];
                  final epInfo = scraped.infoForRawIndex(epIndex);
                  final unavailReason =
                      widget.episodeUnavailableReason?.call(ep);
                  final isUnavailable = unavailReason != null;
                  final selected =
                      !isUnavailable &&
                      _previewLineIndex == widget.activeLineIndex &&
                      epIndex == widget.activeEpisodeIndex;
                  final parsed = _ParsedEpisodeLabel.parse(ep.name, epIndex);
                  final seriesEpInfo = lineScrape?.infoForOriginalIndex(epIndex);
                  final numBadge = widget.isMultiVersionMovie
                      ? (epInfo?.movieVersionLabel ?? '版本 ${epIndex + 1}')
                      : (useEpisodeScraper
                            ? (epInfo?.badgeLabel ??
                                '#${(epIndex + 1).toString().padLeft(2, '0')}')
                            : (seriesEpInfo != null
                                  ? seriesEpInfo.formattedSeasonEpisode
                                  : '#${(epIndex + 1).toString().padLeft(2, '0')}'));
                  final tileTitle = !useEpisodeScraper &&
                          seriesEpInfo != null &&
                          seriesEpInfo.originalFileName.isNotEmpty
                      ? seriesEpInfo.originalFileName
                      : parsed.title;
                  final badgeText = isUnavailable
                      ? '不可解析'
                      : (useEpisodeScraper
                          ? (parsed.sizeBadge.isNotEmpty
                              ? parsed.sizeBadge
                              : (epInfo?.qualityBadge ?? ''))
                          : (seriesEpInfo != null &&
                                  seriesEpInfo.hasManualOverride
                              ? '已校准'
                              : (seriesEpInfo != null &&
                                      seriesEpInfo.qualityTag.isNotEmpty
                                  ? seriesEpInfo.qualityTag
                                  : parsed.sizeBadge)));

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
                              Expanded(
                                child: Text(
                                  numBadge,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: selected
                                        ? const Color(0xE6FFFFFF)
                                        : AppleColors.labelTertiary,
                                    fontSize: 10.5,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                              if (badgeText.isNotEmpty) ...[
                                const SizedBox(width: 4),
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
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
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
                            ],
                          ),
                          const SizedBox(height: 3),
                          Text(
                            tileTitle,
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
              );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Smoothly animates player HUD show/hide with fade + subtle spatial scale,
/// and strictly unmounts [childBuilder] on `AnimationStatus.dismissed` so
/// `GlassworkBackdrop` shaders incur zero GPU cost while hidden.
class _AnimatedPlayerHudVisibility extends StatefulWidget {
  final bool visible;
  final bool immediateHide;
  final WidgetBuilder childBuilder;

  const _AnimatedPlayerHudVisibility({
    super.key,
    required this.visible,
    this.immediateHide = false,
    required this.childBuilder,
  });

  @override
  State<_AnimatedPlayerHudVisibility> createState() =>
      _AnimatedPlayerHudVisibilityState();
}

class _AnimatedPlayerHudVisibilityState
    extends State<_AnimatedPlayerHudVisibility>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    value: widget.visible ? 1.0 : 0.0,
    duration: const Duration(milliseconds: 220),
    reverseDuration: const Duration(milliseconds: 180),
  );
  late final CurvedAnimation _opacity = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeInCubic,
  );
  late final Animation<double> _scale = Tween<double>(
    begin: 0.985,
    end: 1.0,
  ).animate(_opacity);

  @override
  void initState() {
    super.initState();
    _controller.addStatusListener(_onStatus);
  }

  void _onStatus(AnimationStatus status) {
    if (status == AnimationStatus.dismissed && mounted) {
      setState(() {});
    }
  }

  @override
  void didUpdateWidget(covariant _AnimatedPlayerHudVisibility oldWidget) {
    super.didUpdateWidget(oldWidget);
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (!widget.visible && (widget.immediateHide || reduceMotion)) {
      _controller.stop();
      if (_controller.value != 0.0) {
        _controller.value = 0.0;
      }
      return;
    }
    if (oldWidget.visible == widget.visible) return;
    if (widget.visible) {
      if (reduceMotion) {
        _controller.value = 1.0;
      } else {
        _controller.forward();
      }
    } else {
      _controller.reverse();
    }
  }

  @override
  void dispose() {
    _controller.removeStatusListener(_onStatus);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.visible && (widget.immediateHide || _controller.isDismissed)) {
      return const SizedBox.shrink();
    }
    return IgnorePointer(
      ignoring: !widget.visible,
      child: FadeTransition(
        opacity: _opacity,
        child: ScaleTransition(
          scale: _scale,
          child: Builder(builder: widget.childBuilder),
        ),
      ),
    );
  }
}

class _CompanionActionChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;
  final Color? activeColor;
  final ApplePalette palette;
  final VoidCallback onTap;

  const _CompanionActionChip({
    super.key,
    required this.icon,
    required this.label,
    this.active = false,
    this.activeColor,
    required this.palette,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = active
        ? (activeColor ?? palette.accent)
        : palette.labelPrimary;
    return Expanded(
      child: GestureDetector(
        onTap: () {
          HapticFeedback.selectionClick();
          onTap();
        },
        behavior: HitTestBehavior.opaque,
        child: Container(
          constraints: const BoxConstraints(minHeight: 36),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: active
                ? color.withValues(alpha: palette.isDark ? 0.22 : 0.16)
                : (palette.isDark
                    ? Colors.white.withValues(alpha: 0.085)
                    : Colors.white.withValues(alpha: 0.62)),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: active
                  ? color.withValues(alpha: 0.5)
                  : (palette.isDark
                      ? Colors.white.withValues(alpha: 0.16)
                      : Colors.white.withValues(alpha: 0.85)),
              width: 0.85,
            ),
            boxShadow: palette.isDark
                ? null
                : [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.04),
                      blurRadius: 10,
                      offset: const Offset(0, 3),
                    ),
                  ],
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 15, color: color),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: active ? color : palette.labelPrimary,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BlurayChapterTickPainter extends CustomPainter {
  final List<BlurayChapter> chapters;
  final int durationMs;

  const _BlurayChapterTickPainter({
    required this.chapters,
    required this.durationMs,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty || durationMs <= 0 || chapters.isEmpty) return;
    final paint = Paint()..color = const Color(0xCCFFD60A);
    final centerY = size.height * 0.5;
    for (final ch in chapters) {
      final frac = (ch.position.inMilliseconds / durationMs).clamp(0.0, 1.0);
      if (frac <= 0.005 || frac >= 0.995) continue;
      final x = size.width * frac;
      canvas.drawRect(
        Rect.fromCenter(center: Offset(x, centerY), width: 2.0, height: 8.0),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _BlurayChapterTickPainter oldDelegate) =>
      oldDelegate.durationMs != durationMs ||
      oldDelegate.chapters.length != chapters.length;
}
