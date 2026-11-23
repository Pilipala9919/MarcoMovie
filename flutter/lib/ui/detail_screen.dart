import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show ImageFilter;
import 'dart:ui' as ui show FragmentProgram, Image;
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, visibleForTesting;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemUiOverlayStyle;
import '../core/cms_client.dart';
import '../core/cms_parser.dart';
import '../core/csp_bridge.dart';
import '../core/curated_discovery.dart';
import '../core/download_service.dart';
import '../core/media_badges.dart';
import '../core/models.dart';
import '../core/ohos_runtime.dart';
import '../core/series_scraper.dart';
import '../core/storage_service.dart';
import '../core/web_media_resolver.dart';
import '../core/wogg_source.dart';
import 'apple_theme.dart';
import 'cast_avatar_section.dart';
import 'desktop_horizontal_scroller.dart';
import 'favorite_postcard_animation.dart';
import 'ios_liquid_glass.dart';
import 'media_badge.dart';
import 'motion/ios27_springs.dart';
import 'motion/player_enter_transition.dart';
import 'netdisk_sheet.dart';
import 'player_screen.dart';
import 'poster_image.dart';
import 'series_scrape_sheet.dart';
import 'source_verification_dialog.dart';
import 'windows_appearance.dart';
import 'windows_title_bar.dart';
part 'windows_detail.dart';

/// Apple TV+ / Infuse inspired responsive video detail page for iPhone, iPad, Mac, and Windows.
/// Features:
/// - Full-screen `Positioned.fill` ambient canvas & backdrop (zero horizontal or vertical seam lines
///   in both portrait and landscape when scrolling/blurring)
/// - Top solid-color transition with downward-shifted hero poster framing, plus bottom progressive
///   frosted-glass blur transition (`ShaderMask` + `BackdropFilter`) behind overlaid typography
/// - Real per-episode 16:9 frame stills & real per-episode plot synopses (`分集剧情`) from
///   360 Baike `tvplot`, Bilibili PGC, and Bangumi, with honest non-repetitive display
class DetailScreen extends StatefulWidget {
  final CmsSite site;
  final CmsVideo initialVideo;
  final CmsClient client;
  final StorageService storage;
  @visibleForTesting
  final Widget Function(
    BuildContext context,
    CmsSite site,
    CmsVideo video,
    int lineIndex,
    int episodeIndex,
    int resumeMs,
  )? debugPlayerBuilder;
  @visibleForTesting
  final BackdropImageCapturer? debugTransitionCapturer;
  @visibleForTesting
  final ui.FragmentProgram? debugTransitionShaderProgram;
  @visibleForTesting
  final ValueChanged<PlayerTransitionMode>? debugOnTransitionModeResolved;
  const DetailScreen({
    super.key,
    required this.site,
    required this.initialVideo,
    required this.client,
    required this.storage,
    this.debugPlayerBuilder,
    this.debugTransitionCapturer,
    this.debugTransitionShaderProgram,
    this.debugOnTransitionModeResolved,
  });

  static List<CmsSite> selectRelatedSeasonSiblings(
    CmsSite site,
    Iterable<CmsSite> allSites, {
    int limit = 6,
  }) {
    return allSites
        .where(
          (s) =>
              s.supported &&
              s.key != site.key &&
              s.searchable &&
              s.isEffectivelyPrivate == site.isEffectivelyPrivate &&
              (s.group == site.group || !site.isEffectivelyPrivate),
        )
        .take(limit)
        .toList();
  }

  @override
  State<DetailScreen> createState() => _DetailScreenState();
}

class _OtherSourceResults extends StatefulWidget {
  final Stream<(CmsSite, List<CmsVideo>)> results;
  const _OtherSourceResults({required this.results});

  @override
  State<_OtherSourceResults> createState() => _OtherSourceResultsState();
}

class _OtherSourceResultsState extends State<_OtherSourceResults> {
  final _matches = <(CmsSite, CmsVideo)>[];
  late final StreamSubscription<(CmsSite, List<CmsVideo>)> _search;
  bool _done = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _search = widget.results.listen((result) {
      if (mounted) setState(() {
        _matches.addAll(result.$2.map((v) => (result.$1, v)));
      });
    }, onDone: () { if (mounted) setState(() => _done = true); },
       onError: (Object error) { if (mounted) setState(() => _failed = true); });
  }

  @override
  void dispose() {
    _search.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      shrinkWrap: true,
      itemCount: _matches.length + (_done && _matches.isNotEmpty ? 0 : 1),
      itemBuilder: (context, index) {
        if (index == _matches.length) {
          return Padding(padding: const EdgeInsets.all(20), child: Center(
            child: _done ? Text(_failed ? '搜索失败，可关闭后重试' : '已导入的可搜索片源没有返回匹配影片')
                : const CupertinoActivityIndicator(),
          ));
        }
        final (site, video) = _matches[index];
        return ListTile(title: Text(video.title), subtitle: Text(
          [site.name, video.year, video.remarks].where((s) => s.isNotEmpty).join(' · ')),
          onTap: () => Navigator.of(context).pop((site, video)),
        );
      },
    );
  }
}

class _DetailScreenState extends State<DetailScreen> {
  late CmsSite _activeSite;
  late CmsVideo _video;
  bool _loading = true;
  String? _error;
  Object? _errorCause;
  String? _curatedUnavailableMessage;
  int _selectedLine = 0;
  int _selectedPage = 0;
  int? _selectedInLineSeason;
  List<({int seasonNumber, String seasonLabel, CmsSite site, CmsVideo video})>
      _relatedSeasons = const [];
  bool _discoveringSeasons = false;
  String _discoveredFranchiseKey = '';
  bool _synopsisExpanded = false;
  bool _sourceWarningsExpanded = false;
  bool _windowsLinesExpanded = false;
  bool _windowsEpisodesExpanded = false;
  bool _windowsSynopsisExpanded = false;
  bool _windowsHeroHasLandscape = false;
  late bool _descending;
  late bool _isFavorite;
  final ValueNotifier<double> _scrollOffset = ValueNotifier<double>(0.0);
  final ScrollController _seasonsScrollController = ScrollController();
  final ScrollController _quickEpisodesScrollController = ScrollController();
  final ScrollController _previewCardsScrollController = ScrollController();
  final ScrollController _pageRangeScrollController = ScrollController();
  Color? _posterAmbientColor;
  String _externalSynopsis = '';
  double? _resolvedDoubanScore;
  int? _resolvedRtScore;
  int _lastMetadataSnapshotSig = 0;
  Completer<void>? _detailAbort;
  Completer<void>? _seasonAbort;
  int _detailEpoch = 0;
  final GlobalKey _transitionBackdropKey = GlobalKey();
  final GlobalKey _transitionPosterKey = GlobalKey();
  Uint8List? _loadedPosterBytes;
  String _loadedPosterIdentity = '';
  SeriesScrapeOverride? _scrapeOverride;
  final TextEditingController _windowsEpisodeQueryCtrl = TextEditingController();
  String _windowsEpisodeQuery = '';
  CmsLine? _cachedScrapeLine;
  String _cachedScrapeSig = '';
  LineEpisodeScrapeResult? _cachedScrapeResult;

  void _loadScrapeOverride() {
    _scrapeOverride = widget.storage.getSeriesScrapeOverride(
      _activeSite.key,
      _video.id,
      isPrivate: _activeSite.isEffectivelyPrivate,
    );
    _cachedScrapeLine = null;
    _cachedScrapeSig = '';
    _cachedScrapeResult = null;
  }

  bool get _effectiveWantMotionComic {
    final ov = _scrapeOverride;
    if (ov != null && ov.hasWorkBinding) return ov.isMotionComic;
    return SeriesScraper.isMotionComicText(
      _video.title,
      extraContext: '${_video.tag} ${_video.remarks}',
    );
  }

  String get _effectiveLookupTitle {
    if (_activeSite.isEffectivelyPrivate) return '';
    final ov = _scrapeOverride;
    if (ov != null && ov.matchedTitle.trim().isNotEmpty) {
      return ov.matchedTitle.trim();
    }
    return _video.title;
  }

  String get _effectiveLookupYear {
    final ov = _scrapeOverride;
    if (!_activeSite.isEffectivelyPrivate &&
        ov != null &&
        ov.matchedYear.trim().isNotEmpty) {
      return ov.matchedYear.trim();
    }
    return _video.year;
  }

  String get _effectiveDoubanId {
    if (_activeSite.isEffectivelyPrivate) return '';
    return _scrapeOverride?.doubanId.trim() ?? '';
  }

  bool get _effectiveDoubanIsTv => _scrapeOverride?.isTv ?? true;

  String get _effectiveBackdropUrl {
    if (_activeSite.isEffectivelyPrivate) return '';
    return _scrapeOverride?.backdropUrl.trim() ?? '';
  }

  String get _effectivePosterUrl {
    final ov = _scrapeOverride;
    if (!_activeSite.isEffectivelyPrivate &&
        ov != null &&
        ov.posterUrl.trim().isNotEmpty) {
      return ov.posterUrl.trim();
    }
    return _video.poster;
  }

  LineEpisodeScrapeResult _scrapeResultForLine(CmsLine line) {
    final ov = _scrapeOverride;
    final title = _effectiveLookupTitle.isNotEmpty
        ? _effectiveLookupTitle
        : _video.title;
    final offset = ov?.episodeOffset ?? 0;
    final overrides = ov?.episodeNumberOverrides ?? const <String, int>{};
    final sig =
        '${line.name}|${line.episodes.length}|$title|$offset|${overrides.entries.map((e) => "${e.key}:${e.value}").join(",")}';
    if (identical(_cachedScrapeLine, line) &&
        _cachedScrapeSig == sig &&
        _cachedScrapeResult != null) {
      return _cachedScrapeResult!;
    }
    final result = SeriesScraper.scrapeLineEpisodes(
      line.episodes,
      seriesTitle: title,
      episodeOffset: offset,
      manualOverrides: overrides,
    );
    _cachedScrapeLine = line;
    _cachedScrapeSig = sig;
    _cachedScrapeResult = result;
    return result;
  }

  Future<void> _openSeriesScrapeSheet({int initialTab = 0}) async {
    if (_activeSite.isEffectivelyPrivate) return;
    final activeLine = _video.lines.isNotEmpty
        ? _video.lines[_selectedLine.clamp(0, _video.lines.length - 1)]
        : null;
    await showSeriesScrapeSheet(
      context,
      site: _activeSite,
      video: _video,
      storage: widget.storage,
      activeLine: activeLine,
      initialOverride: _scrapeOverride,
      initialTab: initialTab,
    );
  }

  void _onSeriesScrapeRevision() {
    if (!mounted) return;
    _loadScrapeOverride();
    _externalSynopsis = '';
    _resolvedDoubanScore = null;
    _resolvedRtScore = null;
    _seedCachedExternalFields();
    _windowsHeroHasLandscape = !_activeSite.isEffectivelyPrivate &&
        PosterLoader.peekLandscapeMemory(
              _effectiveLookupTitle,
              year: _effectiveLookupYear,
              wantMotionComic: _effectiveWantMotionComic,
              preferredBackdropUrl: _effectiveBackdropUrl,
              preferredDoubanId: _effectiveDoubanId,
            ) !=
            null;
    setState(() {
      _selectedPage = 0;
    });
    _warmRatings(_effectiveLookupTitle, year: _effectiveLookupYear);
    _warmExternalMetadata(_effectiveLookupTitle);
  }

  static bool _canShowInitialLinesImmediately(CmsSite site, CmsVideo video) {
    if (!video.lines.any((l) => l.episodes.isNotEmpty)) return false;
    if (WoggSource.supports(site) ||
        CspBridge.isDoubanSite(site) ||
        CspBridge.isMyDriveSite(site)) {
      return false;
    }
    if (site.isScriptOrJarApi) {
      return video.lines.every(
        (l) => l.episodes.every(
          (e) => !e.url.startsWith('mmshare://') && e.needsSourceResolution,
        ),
      );
    }
    return true;
  }

  void _seedCachedExternalFields() {
    if (_activeSite.isEffectivelyPrivate || _activeSite.isEmby) {
      _resolvedDoubanScore = null;
      _resolvedRtScore = null;
      return;
    }
    final lookupTitle = _effectiveLookupTitle;
    final lookupYear = _effectiveLookupYear;
    final wantMc = _effectiveWantMotionComic;
    final syn = PosterLoader.peekSeriesSynopsis(
      lookupTitle,
      year: lookupYear,
      wantMotionComic: wantMc,
    );
    if (syn.isNotEmpty) {
      _externalSynopsis = syn;
    }
    final cachedRatings = PosterLoader.peekRatings(
      lookupTitle,
      year: lookupYear,
      wantMotionComic: wantMc,
    );
    _resolvedDoubanScore = _scrapeOverride?.doubanScore ?? cachedRatings?.douban;
    _resolvedRtScore = cachedRatings?.rt;
  }

  bool _windowsDarkSurfaceApplied = false;

  void _updateWindowsState(VoidCallback change) => setState(change);
  @override
  void initState() {
    super.initState();
    if (isWindowsDesktopUi) {
      scheduleMicrotask(() {
        if (!mounted || _windowsDarkSurfaceApplied) return;
        _windowsDarkSurfaceApplied = true;
        WindowsImmersiveFrame.darkSurfaceDepth.value += 1;
      });
    }
    _activeSite = widget.site;
    _video = WoggSource.normalizeCachedVideoLabels(widget.site, widget.initialVideo);
    final curInfo = CmsParser.parseSeriesSeasonInfo(_video.title);
    _relatedSeasons = [
      (
        seasonNumber: curInfo.seasonNumber,
        seasonLabel: curInfo.seasonLabel,
        site: _activeSite,
        video: _video,
      ),
    ];
    _descending = widget.storage.episodesDescending;
    if (!OhosRuntime.isOhos) {
      unawaited(MediaBadges.ensureInitialized().then((_) {
        if (mounted) setState(() {});
      }));
      if (!isWindowsDesktopUi) {
        unawaited(PlayerEnterTransition.prewarmShader());
      }
    }
    _isFavorite = widget.storage.isFavorite(
      _activeSite.key,
      _video.id,
      forPrivate: _activeSite.isEffectivelyPrivate,
    );
    _loadScrapeOverride();
    _seedCachedExternalFields();
    _windowsHeroHasLandscape = !_activeSite.isEffectivelyPrivate &&
        PosterLoader.peekLandscapeMemory(
              _effectiveLookupTitle,
              year: _effectiveLookupYear,
              wantMotionComic: _effectiveWantMotionComic,
              preferredBackdropUrl: _effectiveBackdropUrl,
              preferredDoubanId: _effectiveDoubanId,
            ) !=
            null;
    PosterLoader.metadataRevision.addListener(_onExternalMetadataRevision);
    widget.storage.watchHistoryRevision.addListener(_onWatchHistoryChanged);
    widget.storage.seriesScrapeRevision.addListener(_onSeriesScrapeRevision);
    final immediateBytes = PosterLoader.peekMemory(
      _effectivePosterUrl,
      title: _effectiveLookupTitle,
      year: _effectiveLookupYear,
      preferHd: true,
    );
    if (immediateBytes != null) {
      _loadedPosterBytes = immediateBytes;
      _loadedPosterIdentity = _currentPosterIdentity;
      _posterAmbientColor = PosterLoader.peekAmbientColor(immediateBytes);
      if (_posterAmbientColor == null) {
        unawaited(_updateAmbientFromBytes(immediateBytes));
      }
    }
    _loadDetail();
    _warmRatings(_effectiveLookupTitle, year: _effectiveLookupYear);
    if (!_loading) {
      _warmExternalMetadata(_effectiveLookupTitle);
    }
  }

  String get _publicLookupTitle => _effectiveLookupTitle;

  String get _currentPosterIdentity =>
      '${_activeSite.key}|${_video.id}|$_effectivePosterUrl|$_effectiveLookupTitle|$_effectiveLookupYear|$_effectiveDoubanId';

  void _onPosterCardBytesLoaded(Uint8List bytes) {
    _loadedPosterBytes = bytes;
    _loadedPosterIdentity = _currentPosterIdentity;
    unawaited(_updateAmbientFromBytes(bytes));
  }

  Future<ui.Image?> _obtainTransitionPosterImage() async {
    if (OhosRuntime.isOhos || isWindowsDesktopUi) return null;
    final currentId = _currentPosterIdentity;
    final bytes = (_loadedPosterIdentity == currentId
            ? _loadedPosterBytes
            : null) ??
        PosterLoader.peekMemory(
          _video.poster,
          title: _publicLookupTitle,
          year: _video.year,
          preferHd: true,
        );
    if (bytes == null || bytes.isEmpty) {
      return null;
    }
    final cloned =
        PlayerEnterTransition.cloneRenderedImage(_transitionPosterKey);
    if (cloned != null) {
      return cloned;
    }
    return PlayerEnterTransition.decodePosterBytes(bytes);
  }

  @override
  void dispose() {
    if (_windowsDarkSurfaceApplied) {
      _windowsDarkSurfaceApplied = false;
      scheduleMicrotask(() {
        final next = WindowsImmersiveFrame.darkSurfaceDepth.value - 1;
        WindowsImmersiveFrame.darkSurfaceDepth.value = next < 0 ? 0 : next;
      });
    }
    _cancelDetailWork();
    PosterLoader.metadataRevision.removeListener(_onExternalMetadataRevision);
    widget.storage.watchHistoryRevision.removeListener(_onWatchHistoryChanged);
    widget.storage.seriesScrapeRevision.removeListener(_onSeriesScrapeRevision);
    _windowsEpisodeQueryCtrl.dispose();
    _scrollOffset.dispose();
    _seasonsScrollController.dispose();
    _quickEpisodesScrollController.dispose();
    _previewCardsScrollController.dispose();
    _pageRangeScrollController.dispose();
    super.dispose();
  }

  void _onWatchHistoryChanged() {
    if (mounted) setState(() {});
  }

  void _cancelDetailWork() {
    if (_detailAbort?.isCompleted == false) _detailAbort!.complete();
    if (_seasonAbort?.isCompleted == false) _seasonAbort!.complete();
  }

  void _onExternalMetadataRevision() {
    if (!mounted || _activeSite.isEffectivelyPrivate) return;
    final lookupTitle = _effectiveLookupTitle;
    final lookupYear = _effectiveLookupYear;
    final wantMc = _effectiveWantMotionComic;
    final syn = PosterLoader.peekSeriesSynopsis(
      lookupTitle,
      year: lookupYear,
      wantMotionComic: wantMc,
    );
    final epMetaLen = PosterLoader.peekAllEpisodeMeta(
      lookupTitle,
      wantMotionComic: wantMc,
    ).length;
    final capLen = PosterLoader.peekSeriesEpisodeCaptions(
      lookupTitle,
      wantMotionComic: wantMc,
    ).length;
    final ratings = PosterLoader.peekRatings(
      lookupTitle,
      year: lookupYear,
      wantMotionComic: wantMc,
    );
    final sig = Object.hash(
      syn,
      epMetaLen,
      capLen,
      ratings?.douban,
      ratings?.rt,
    );
    if (sig == _lastMetadataSnapshotSig) return;
    _lastMetadataSnapshotSig = sig;
    if (syn.isNotEmpty && syn != _externalSynopsis) {
      _externalSynopsis = syn;
    }
    if (ratings != null) {
      _resolvedDoubanScore =
          _scrapeOverride?.doubanScore ?? ratings.douban ?? _resolvedDoubanScore;
      _resolvedRtScore = ratings.rt ?? _resolvedRtScore;
    }
    setState(() {});
  }

  Future<void> _updateAmbientFromBytes(Uint8List bytes) async {
    final extracted = await PosterLoader.extractEdgeAmbientColor(bytes);
    if (!mounted) return;
    if (_posterAmbientColor != extracted) {
      setState(() {
        _posterAmbientColor = extracted;
      });
    }
  }

  bool get _isVarietyShow {
    final metaText =
        '${_video.tag} ${_video.remarks} ${_video.title}'.toLowerCase();
    if (metaText.contains('综艺') ||
        metaText.contains('真人秀') ||
        metaText.contains('脱口秀') ||
        metaText.contains('晚会') ||
        metaText.contains('选秀') ||
        metaText.contains('演唱会')) {
      return true;
    }
    if (_video.lines.isNotEmpty) {
      final eps = _video.lines.first.episodes;
      int issueLikeCount = 0;
      final sampleCount = eps.length < 6 ? eps.length : 6;
      for (int i = 0; i < sampleCount; i++) {
        final n = eps[i].name;
        if (n.contains('期') ||
            n.contains('先导') ||
            n.contains('加更') ||
            n.contains('纯享') ||
            RegExp(r'\b20\d{6}\b').hasMatch(n)) {
          issueLikeCount++;
        }
      }
      if (sampleCount > 0 && issueLikeCount * 2 >= sampleCount) {
        return true;
      }
    }
    return false;
  }

  Future<void> _warmRatings(String title, {String year = ''}) async {
    if (_activeSite.isEmby || _activeSite.isEffectivelyPrivate) return;
    final trimmed = _effectiveLookupTitle.trim().isNotEmpty
        ? _effectiveLookupTitle.trim()
        : title.trim();
    if (trimmed.isEmpty) return;
    final effectiveYear =
        _effectiveLookupYear.isNotEmpty ? _effectiveLookupYear : year;
    final epoch = _detailEpoch;
    final ratings = await PosterLoader.fetchRatings(
      trimmed,
      year: effectiveYear,
      wantMotionComic: _effectiveWantMotionComic,
      preferredDoubanId: _effectiveDoubanId,
      preferredDoubanIsTv: _effectiveDoubanIsTv,
    );
    if (!mounted || epoch != _detailEpoch) return;
    if ((ratings.douban != null && ratings.douban != _resolvedDoubanScore) ||
        (ratings.rt != null && ratings.rt != _resolvedRtScore)) {
      setState(() {
        _resolvedDoubanScore =
            _scrapeOverride?.doubanScore ?? ratings.douban ?? _resolvedDoubanScore;
        _resolvedRtScore = ratings.rt ?? _resolvedRtScore;
      });
    }
  }

  Future<void> _warmExternalMetadata(String title) async {
    if (_activeSite.isEmby || _activeSite.isEffectivelyPrivate) return;
    final lookupTitle = _effectiveLookupTitle.trim().isNotEmpty
        ? _effectiveLookupTitle.trim()
        : title.trim();
    if (lookupTitle.isEmpty) return;
    final lookupYear = _effectiveLookupYear;
    final wantMc = _effectiveWantMotionComic;
    unawaited(
      PosterLoader.fetchSeriesSynopsis(
        lookupTitle,
        year: lookupYear,
        wantMotionComic: wantMc,
      ).then((syn) {
        if (!mounted || syn.isEmpty) return;
        if (_externalSynopsis != syn) {
          setState(() {
            _externalSynopsis = syn;
          });
        }
      }),
    );
    if (!_isVarietyShow) {
      unawaited(
        PosterLoader.fetchSeriesEpisodeMetadata(
          lookupTitle,
          year: lookupYear,
          wantMotionComic: wantMc,
        ),
      );
    }
    unawaited(
      PosterLoader.fetchSeriesEpisodeStills(
        lookupTitle,
        year: lookupYear,
        wantMotionComic: wantMc,
      ),
    );
  }

  final Map<(CmsLine, String, List<CmsParse>), String?> _lineUnavailableCache =
      {};

  List<CmsParse> get _configuredParses =>
      widget.storage.loadSavedConfig()?.parses ?? const [];

  String? _episodeUnavailableReason(
    CmsEpisode episode, {
    CmsSite? siteOverride,
  }) =>
      WebMediaResolver.episodeUnavailableReason(
        episode,
        site: siteOverride ?? _activeSite,
        parses: _configuredParses,
      );

  String? _lineUnavailableReason(CmsLine line, {CmsSite? siteOverride}) {
    if (line.episodes.isEmpty) return '当前线路暂无剧集';
    final effectiveSite = siteOverride ?? _activeSite;
    final parses = _configuredParses;
    final cacheKey = (line, effectiveSite.key, parses);
    if (_lineUnavailableCache.containsKey(cacheKey)) {
      return _lineUnavailableCache[cacheKey];
    }
    String? firstReason;
    for (final ep in line.episodes) {
      final r = WebMediaResolver.episodeUnavailableReason(
        ep,
        site: effectiveSite,
        parses: parses,
      );
      if (r == null) {
        _lineUnavailableCache[cacheKey] = null;
        return null;
      }
      firstReason ??= r;
    }
    _lineUnavailableCache[cacheKey] = firstReason;
    return firstReason;
  }

  int _pickRecommendedPlayableLineIndex(
    List<CmsLine> lines, {
    CmsSite? siteOverride,
  }) {
    if (lines.isEmpty) return 0;
    final picked = widget.storage.pickRecommendedLineIndex(lines);
    if (_lineUnavailableReason(lines[picked], siteOverride: siteOverride) ==
        null) {
      return picked;
    }
    for (var i = 0; i < lines.length; i++) {
      if (_lineUnavailableReason(lines[i], siteOverride: siteOverride) ==
          null) {
        return i;
      }
    }
    return picked;
  }

  Future<void> _loadDetail() async {
    _cancelDetailWork();
    final epoch = ++_detailEpoch;
    final abort = _detailAbort = Completer<void>();
    final targetSite = _activeSite;
    final targetVideo = _video;
    final showImmediately = _canShowInitialLinesImmediately(
      targetSite,
      targetVideo,
    );
    int initialImmediateLine = _selectedLine;
    if (showImmediately && targetVideo.lines.isNotEmpty) {
      final immediateBookmark = _findBookmark(targetVideo);
      if (immediateBookmark != null) {
        final found = targetVideo.lines.indexWhere(
          (l) => l.name == immediateBookmark.line,
        );
        initialImmediateLine = found >= 0 &&
                _lineUnavailableReason(
                      targetVideo.lines[found],
                      siteOverride: targetSite,
                    ) ==
                    null
            ? found
            : _pickRecommendedPlayableLineIndex(
                targetVideo.lines,
                siteOverride: targetSite,
              );
      } else {
        initialImmediateLine = _pickRecommendedPlayableLineIndex(
          targetVideo.lines,
          siteOverride: targetSite,
        );
      }
    }
    setState(() {
      _loading = !showImmediately;
      if (showImmediately) {
        _selectedLine = initialImmediateLine;
      }
      _error = null;
      _errorCause = null;
      _curatedUnavailableMessage = null;
      _discoveringSeasons = false;
    });
    if (CuratedDiscoveryService.isCuratedSite(targetSite)) {
      await _resolveCuratedFromUserSources(
        targetVideo: targetVideo,
        epoch: epoch,
        abort: abort,
      );
      return;
    }
    try {
      final (owner, detailed) = await widget.client.runSourceOperation(
        () => widget.client.playableDetail(targetSite, targetVideo,
            widget.storage.prioritizeSites(widget.storage.loadSavedConfig()?.availableSites ?? const [])),
        cancellation: abort,
      );
      if (!mounted || abort.isCompleted || epoch != _detailEpoch ||
          targetSite.key != _activeSite.key ||
          targetVideo.id != _video.id) {
        return;
      }
      _activeSite = owner;
      _isFavorite = widget.storage.isFavorite(owner.key, detailed.id, forPrivate: owner.isEffectivelyPrivate);
      final bookmark = _findBookmark(detailed);
      int initialLine = 0;
      if (bookmark != null && detailed.lines.isNotEmpty) {
        final found =
            detailed.lines.indexWhere((l) => l.name == bookmark.line);
        initialLine = found >= 0 &&
                _lineUnavailableReason(
                      detailed.lines[found],
                      siteOverride: owner,
                    ) ==
                    null
            ? found
            : _pickRecommendedPlayableLineIndex(
                detailed.lines,
                siteOverride: owner,
              );
      } else if (detailed.lines.isNotEmpty) {
        initialLine = _pickRecommendedPlayableLineIndex(
          detailed.lines,
          siteOverride: owner,
        );
      }
      setState(() {
        _video = detailed;
        _selectedLine = initialLine;
        _loading = false;
      });
      _mergeSeasonCandidates(_activeSite, [detailed]);
      if (detailed.title.trim().isNotEmpty) {
        _warmRatings(detailed.title, year: detailed.year);
        _warmExternalMetadata(detailed.title);
        unawaited(_discoverRelatedSeasons(detailed.title));
      }
    } catch (e) {
      if (!mounted || abort.isCompleted || epoch != _detailEpoch ||
          targetSite != _activeSite || targetVideo.id != _video.id) return;
      setState(() {
        _loading = false;
        if (!showImmediately || _video.lines.isEmpty) {
          _error = '读取详情失败：${CmsClient.cleanErrorMessage(e)}';
          _errorCause = e;
        }
      });
    }
  }

  /// Resolves a curated Rex-style discovery card STRICTLY against the user's
  /// own added CMS sources. Never supplies built-in stream URLs; when no user
  /// source contains the title, clearly marks playback unavailable.
  Future<void> _resolveCuratedFromUserSources({
    required CmsVideo targetVideo,
    required int epoch,
    required Completer<void> abort,
  }) async {
    if (targetVideo.title.trim().isNotEmpty) {
      _warmRatings(targetVideo.title, year: targetVideo.year);
      _warmExternalMetadata(targetVideo.title);
    }
    final userSites = widget.storage
        .prioritizeSites(
          widget.storage.loadSavedConfig()?.publicAvailableSites ?? const [],
        )
        .where((s) => s.searchable && !CuratedDiscoveryService.isCuratedSite(s))
        .toList();
    if (userSites.isEmpty) {
      if (!mounted || abort.isCompleted || epoch != _detailEpoch) return;
      setState(() {
        _loading = false;
        _curatedUnavailableMessage =
            '您暂未添加可用片源，无法播放《${targetVideo.title}》。请先在「片源」中添加片源。';
      });
      return;
    }

    final query = targetVideo.title
        .replaceAll(RegExp(r'\s+第[一二三四五六七八九十0-9]+季$'), '')
        .trim();
    final searchTargets = userSites.take(8).toList();
    ({int score, CmsSite site, CmsVideo video})? bestMatch;

    try {
      await widget.client.runSourceOperation(() async {
        for (var i = 0; i < searchTargets.length && !abort.isCompleted; i += 2) {
          final batch = searchTargets.skip(i).take(2).toList();
          await Future.wait(
            batch.map((site) async {
              if (abort.isCompleted) return;
              final reqAbort = Completer<void>();
              final timer = Timer(const Duration(seconds: 5), () {
                if (!reqAbort.isCompleted) reqAbort.complete();
              });
              try {
                final listing = await widget.client.runSourceOperation(
                  () => widget.client.fetchSearch(
                    site,
                    query.isEmpty ? targetVideo.title : query,
                  ),
                  cancellation: reqAbort,
                );
                for (final candidate in listing.videos) {
                  final score = CuratedDiscoveryService.titleMatchScore(
                    targetVideo.title,
                    candidate.title,
                  );
                  if (score >= 60 &&
                      (bestMatch == null || score > bestMatch!.score)) {
                    bestMatch = (score: score, site: site, video: candidate);
                  }
                }
              } catch (_) {
              } finally {
                timer.cancel();
              }
            }),
          );
          if (bestMatch != null && bestMatch!.score >= 100) break;
        }
      }, cancellation: abort);
    } catch (_) {}

    if (!mounted || abort.isCompleted || epoch != _detailEpoch) return;
    if (bestMatch == null) {
      setState(() {
        _loading = false;
        _curatedUnavailableMessage =
            '您已添加的片源中暂未找到《${targetVideo.title}》的播放资源，无法播放';
      });
      return;
    }

    try {
      final (owner, detailed) = await widget.client.runSourceOperation(
        () => widget.client.playableDetail(
          bestMatch!.site,
          bestMatch!.video,
          userSites,
        ),
        cancellation: abort,
      );
      if (!mounted || abort.isCompleted || epoch != _detailEpoch) return;
      if (detailed.lines.isEmpty) {
        setState(() {
          _loading = false;
          _curatedUnavailableMessage =
              '片源「${owner.name}」暂未提供《${targetVideo.title}》的可播放线路，无法播放';
        });
        return;
      }
      final mergedVideo = CmsVideo(
        id: detailed.id,
        title: detailed.title.isNotEmpty ? detailed.title : targetVideo.title,
        poster:
            detailed.poster.isNotEmpty ? detailed.poster : targetVideo.poster,
        remarks:
            detailed.remarks.isNotEmpty ? detailed.remarks : targetVideo.remarks,
        year: detailed.year.isNotEmpty ? detailed.year : targetVideo.year,
        area: detailed.area.isNotEmpty ? detailed.area : targetVideo.area,
        actor: detailed.actor.isNotEmpty ? detailed.actor : targetVideo.actor,
        description: detailed.description.isNotEmpty
            ? detailed.description
            : targetVideo.description,
        tag: detailed.tag.isNotEmpty ? detailed.tag : targetVideo.tag,
        doubanScore: detailed.doubanScore ?? targetVideo.doubanScore,
        rtScore: detailed.rtScore ?? targetVideo.rtScore,
        lines: detailed.lines,
        sourceWarnings: detailed.sourceWarnings,
      );
      _activeSite = owner;
      _isFavorite = widget.storage.isFavorite(
        owner.key,
        mergedVideo.id,
        forPrivate: owner.isEffectivelyPrivate,
      );
      final initialLine = _pickRecommendedPlayableLineIndex(
        mergedVideo.lines,
        siteOverride: owner,
      );
      setState(() {
        _video = mergedVideo;
        _selectedLine = initialLine;
        _loading = false;
        _curatedUnavailableMessage = null;
      });
    } catch (_) {
      if (!mounted || abort.isCompleted || epoch != _detailEpoch) return;
      setState(() {
        _loading = false;
        _curatedUnavailableMessage =
            '您已添加的片源中暂无法解析《${targetVideo.title}》的播放资源，无法播放';
      });
    }
  }

  Widget _buildDetailError() => Padding(
    padding: const EdgeInsets.symmetric(vertical: 12),
    child: Column(children: [
      Text(_error!, textAlign: TextAlign.center,
          style: const TextStyle(color: AppleColors.systemRed, fontSize: 14)),
      if (CmsClient.needsSourceVerification(_activeSite, _errorCause))
        Padding(padding: const EdgeInsets.only(top: 12), child: SourceVerificationButton(
          client: widget.client, site: _activeSite, onVerified: _loadDetail)),
    ]),
  );

  Future<void> _discoverRelatedSeasons(String title) async {
    final site = _activeSite;
    final epoch = _detailEpoch;
    if (site.isEmby) return;
    final info = CmsParser.parseSeriesSeasonInfo(title);
    if (!info.hasExplicitSeason) return;
    final base = info.baseTitle.trim();
    if (base.isEmpty) return;
    _mergeSeasonCandidates(site, [_video]);
    final normKey = '${site.isEffectivelyPrivate}_${base.toLowerCase()}';
    if (_discoveredFranchiseKey == normKey && _relatedSeasons.length > 1) return;
    if (_seasonAbort?.isCompleted == false) _seasonAbort!.complete();
    final abort = _seasonAbort = Completer<void>();
    bool current() => mounted && !abort.isCompleted &&
        identical(_seasonAbort, abort) && epoch == _detailEpoch;
    try {
      // Let the episode list become usable before optional season discovery.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      if (!current()) return;
      _discoveredFranchiseKey = normKey;
      setState(() => _discoveringSeasons = true);
      await widget.client.runSourceOperation(() async {
        Future<void> search(CmsSite candidate) async {
          if (!current()) return;
          final requestAbort = Completer<void>();
          final timer = Timer(const Duration(seconds: 6), () {
            if (!requestAbort.isCompleted) requestAbort.complete();
          });
          try {
            final result = await widget.client.runSourceOperation(
              () => widget.client.fetchSearch(candidate, base),
              cancellation: requestAbort,
            );
            if (current() && result.videos.isNotEmpty) {
              _mergeSeasonCandidates(candidate, result.videos);
            }
          } catch (_) {
            // Optional discovery cannot turn a usable episode list into an error.
          } finally {
            timer.cancel();
          }
        }
        if (site.supported && site.searchable) await search(site);
        if (!current() || !(_relatedSeasons.length < 3 ||
            (info.seasonNumber > 1 && _relatedSeasons.length < info.seasonNumber))) return;
        final allSites = widget.storage.loadSavedConfig()?.supportedSites ?? const <CmsSite>[];
        final siblings = DetailScreen.selectRelatedSeasonSiblings(site, allSites);
        // Leave capacity for the foreground detail/player instead of starting
        // six background source runtimes at once on a phone.
        for (var i = 0; i < siblings.length && current(); i += 2) {
          await Future.wait(siblings.skip(i).take(2).map(search));
        }
      }, cancellation: abort);
    } catch (_) {
      // Closing or replacing this screen cancels the discovery operation.
    } finally {
      if (current()) setState(() => _discoveringSeasons = false);
    }
  }

  void _mergeSeasonCandidates(
    CmsSite candidateSite,
    List<CmsVideo> candidates,
  ) {
    final bySeason = <int,
        ({int seasonNumber, String seasonLabel, CmsSite site, CmsVideo video})>{
      for (final item in _relatedSeasons) item.seasonNumber: item,
    };
    final curInfo = CmsParser.parseSeriesSeasonInfo(_video.title);
    bySeason[curInfo.seasonNumber] = (
      seasonNumber: curInfo.seasonNumber,
      seasonLabel: curInfo.seasonLabel,
      site: _activeSite,
      video: _video,
    );
    for (final cand in candidates) {
      if (!CmsParser.isSameFranchiseSeasonCandidate(_video.title, cand.title)) {
        continue;
      }
      final candInfo = CmsParser.parseSeriesSeasonInfo(cand.title);
      if (!curInfo.hasExplicitSeason &&
          !candInfo.hasExplicitSeason &&
          cand.id != _video.id) {
        continue;
      }
      final existing = bySeason[candInfo.seasonNumber];
      if (existing == null) {
        bySeason[candInfo.seasonNumber] = (
          seasonNumber: candInfo.seasonNumber,
          seasonLabel: candInfo.seasonLabel,
          site: candidateSite,
          video: cand,
        );
      } else if (existing.video.id == _video.id &&
          existing.site.key == _activeSite.key) {
        bySeason[candInfo.seasonNumber] = (
          seasonNumber: candInfo.seasonNumber,
          seasonLabel: candInfo.seasonLabel,
          site: _activeSite,
          video: _video,
        );
      } else if (existing.site.key != _activeSite.key &&
          candidateSite.key == _activeSite.key) {
        bySeason[candInfo.seasonNumber] = (
          seasonNumber: candInfo.seasonNumber,
          seasonLabel: candInfo.seasonLabel,
          site: candidateSite,
          video: cand,
        );
      }
    }
    final sorted = bySeason.values.toList()
      ..sort((a, b) => a.seasonNumber.compareTo(b.seasonNumber));
    if (mounted) {
      setState(() {
        _relatedSeasons = sorted;
      });
    } else {
      _relatedSeasons = sorted;
    }
  }

  void _switchToRelatedSeason(
    ({int seasonNumber, String seasonLabel, CmsSite site, CmsVideo video})
        option,
  ) {
    if (option.video.id == _video.id && option.site.key == _activeSite.key) {
      if (_selectedInLineSeason != null) {
        setState(() {
          _selectedInLineSeason = null;
          _selectedPage = 0;
        });
      }
      return;
    }
    setState(() {
      _activeSite = option.site;
      _video = WoggSource.normalizeCachedVideoLabels(option.site, option.video);
      _selectedLine = 0;
      _selectedPage = 0;
      _selectedInLineSeason = null;
      _windowsEpisodeQuery = '';
      _windowsEpisodeQueryCtrl.clear();
      _externalSynopsis = '';
      _loadScrapeOverride();
      _seedCachedExternalFields();
      _isFavorite = widget.storage.isFavorite(
        _activeSite.key,
        _video.id,
        forPrivate: _activeSite.isEffectivelyPrivate,
      );
    });
    final immediateBytes = PosterLoader.peekMemory(
      _video.poster,
      title: _publicLookupTitle,
      year: _video.year,
      preferHd: true,
    );
    _loadedPosterBytes = immediateBytes;
    _loadedPosterIdentity =
        immediateBytes != null ? _currentPosterIdentity : '';
    if (immediateBytes != null) {
      final cachedColor = PosterLoader.peekAmbientColor(immediateBytes);
      if (cachedColor != null) {
        _posterAmbientColor = cachedColor;
      } else {
        unawaited(_updateAmbientFromBytes(immediateBytes));
      }
    }
    _loadDetail();
    _warmRatings(_video.title, year: _video.year);
    if (!_loading) {
      _warmExternalMetadata(_video.title);
    }
  }

  String _currentSeasonLabel([CmsLine? activeLine]) {
    if (activeLine != null) {
      final inLine = CmsParser.extractInLineSeasons(activeLine.episodes);
      if (inLine.length >= 2) {
        final activeNum = _selectedInLineSeason ?? inLine.first.seasonNumber;
        final matched = inLine.where((s) => s.seasonNumber == activeNum);
        if (matched.isNotEmpty) {
          return matched.first.seasonLabel;
        }
        return inLine.first.seasonLabel;
      }
    }
    return CmsParser.parseSeriesSeasonInfo(_video.title).seasonLabel;
  }

  WatchHistoryEntry? _findBookmark([CmsVideo? currentVideo]) {
    if (_activeSite.isEffectivelyPrivate) return null;
    final video = currentVideo ?? _video;
    for (final item in widget.storage.getWatchHistory()) {
      if (item.site == _activeSite.key && item.id == video.id) {
        final bookmark = WoggSource.normalizeCachedBookmark(_activeSite, video, item);
        if (WoggSource.supports(_activeSite) &&
            WoggSource.resolveCachedBookmarkTarget(_activeSite, video, bookmark) == null) return null;
        return bookmark;
      }
    }
    return null;
  }

  Color _resolveBaseAmbientColor() {
    if (_posterAmbientColor != null) return _posterAmbientColor!;
    const fallbackPalettes = <Color>[
      Color(0xFF1F1610),
      Color(0xFF211518),
      Color(0xFF131A26),
      Color(0xFF1B1511),
      Color(0xFF111D1B),
      Color(0xFF1C1321),
    ];
    final key = '${_video.title}_${_video.id}';
    int hash = 0;
    for (final unit in key.codeUnits) {
      hash = (hash * 31 + unit) & 0x7fffffff;
    }
    return fallbackPalettes[hash % fallbackPalettes.length];
  }

  String _effectiveSeriesSynopsis() {
    final raw = _video.description.trim();
    if (_activeSite.isEffectivelyPrivate) return raw;
    final boundSyn = _scrapeOverride?.synopsis.trim() ?? '';
    if (boundSyn.isNotEmpty) return boundSyn;
    final ext = _externalSynopsis.trim().isNotEmpty
        ? _externalSynopsis.trim()
        : PosterLoader.peekSeriesSynopsis(
            _effectiveLookupTitle,
            year: _effectiveLookupYear,
            wantMotionComic: _effectiveWantMotionComic,
          ).trim();
    // Always preserve the CMS's own authentic description unless it is empty
    // or a generic placeholder slogan (e.g. "正式启动！", "敬请期待", "暂无简介").
    final isPlaceholderSlogan = raw.length < 14 ||
        raw.contains('正式启动') ||
        raw.contains('敬请期待') ||
        raw.contains('即将开播') ||
        raw.contains('暂无简介') ||
        raw.contains('暂缺');
    if (!isPlaceholderSlogan) {
      return raw;
    }
    if (ext.isNotEmpty && ext.length > raw.length) {
      return ext;
    }
    return raw;
  }

  (String, String?) _parseEpisodeDisplay(String rawName, int oneBasedIndex) {
    final trimmed = rawName.trim();
    String? sizeOrSpec;
    var cleaned = trimmed;
    final sizeMatch =
        RegExp(r'\[(\d+(?:\.\d+)?\s*[GM]B)\]', caseSensitive: false)
            .firstMatch(cleaned);
    if (sizeMatch != null) {
      sizeOrSpec = sizeMatch.group(1)!.toUpperCase();
      cleaned = cleaned.replaceFirst(sizeMatch.group(0)!, '').trim();
    } else if (cleaned.toUpperCase().contains('4K') ||
        cleaned.toUpperCase().contains('2160P')) {
      sizeOrSpec = '4K';
    } else if (cleaned.toUpperCase().contains('1080P')) {
      sizeOrSpec = '1080P';
    }
    cleaned = cleaned
        .replaceAll(
          RegExp(r'\.(mkv|mp4|ts|flv|avi|m3u8)$', caseSensitive: false),
          '',
        )
        .trim();
    if (cleaned.isEmpty) {
      cleaned = '第$oneBasedIndex集';
    }
    return (cleaned, sizeOrSpec);
  }

  /// Extracts any meaningful episode subtitle embedded in [cleanEpName].
  String _extractEmbeddedSubtitle(String cleanEpName) {
    final stripped = cleanEpName
        .replaceAll(
          RegExp(
            r'^(?:[Ee][Pp]?\s*0*\d+|第\s*0*\d+\s*[集话期章节回]|0*\d+)\s*[·:：\-_]*\s*',
          ),
          '',
        )
        .trim();
    if (stripped.isNotEmpty &&
        !RegExp(r'^(?:[Ee][Pp]?\s*)?\d+$').hasMatch(stripped)) {
      return stripped;
    }
    return '';
  }

  /// Builds a clean, authentic episode card headline:
  /// 1. For variety shows (`综艺`), preserves the real issue/date/guest name (e.g. `20261105期`, `先导片`)
  /// 2. Uses real subtitle from CMS episode name if present
  /// 3. Uses real episode title from verified 360 Baike / Bilibili PGC / Bangumi if present
  /// 4. Falls back cleanly to `第 X 集` / `第 X 期` (never fabricated text)
  String _formatEpisodeCardHeadline(String cleanEpName, int oneBasedIndex) {
    if (_isVarietyShow) {
      final trimmed = cleanEpName.trim();
      if (trimmed.isNotEmpty &&
          !RegExp(r'^(?:[Ee][Pp]?\s*)?\d+$').hasMatch(trimmed)) {
        return trimmed;
      }
      return '第 $oneBasedIndex 期';
    }
    final embedded = _extractEmbeddedSubtitle(cleanEpName);
    if (embedded.isNotEmpty) {
      return 'E$oneBasedIndex · $embedded';
    }
    final realMeta = PosterLoader.peekEpisodeMeta(_video.title, oneBasedIndex);
    if (realMeta != null && realMeta.title.trim().isNotEmpty) {
      return 'E$oneBasedIndex · ${realMeta.title.trim()}';
    }
    return '第 $oneBasedIndex 集';
  }

  /// Resolves the authentic per-episode plot synopsis (`分集剧情`).
  /// Returns an empty string if no real per-episode plot exists yet so we NEVER
  /// display fake/repeated series slogans or mismatched plots under episode cards.
  String _resolveAuthenticEpisodeSummary(
    int oneBasedIndex,
    String cleanEpName,
  ) {
    if (_isVarietyShow) {
      final embedded = _extractEmbeddedSubtitle(cleanEpName);
      if (embedded.length >= 16 && embedded != cleanEpName.trim()) {
        return embedded;
      }
      return '';
    }
    final realMeta = PosterLoader.peekEpisodeMeta(_video.title, oneBasedIndex);
    if (realMeta != null && realMeta.summary.trim().isNotEmpty) {
      return realMeta.summary.trim();
    }
    final embedded = _extractEmbeddedSubtitle(cleanEpName);
    if (embedded.length >= 14) {
      return embedded;
    }
    return '';
  }

  String _formatBookmarkTime(int ms) {
    final totalSec = ms <= 0 ? 0 : ms ~/ 1000;
    final h = totalSec ~/ 3600;
    final m = (totalSec % 3600) ~/ 60;
    final s = totalSec % 60;
    if (h > 0) {
      return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  Future<void> _openPlayer(int lineIdx, int epIdx, {int? resumeMs}) async {
    if (_video.lines.isEmpty) return;
    final targetSite = _activeSite;
    final targetVideo = _video;
    final safeLine = lineIdx.clamp(0, _video.lines.length - 1);
    final line = _video.lines[safeLine];
    if (line.episodes.isEmpty) return;
    final safeEp = epIdx.clamp(0, line.episodes.length - 1);
    final targetEp = line.episodes[safeEp];
    final blockReason = _episodeUnavailableReason(targetEp);
    if (blockReason != null) {
      _toast(blockReason);
      return;
    }
    final provider = targetEp.cloudProvider;
    if (provider != null && provider != 'uc' &&
        !widget.storage.isNetdiskLoggedIn(provider)) {
      await showNetdiskAccountSheet(
        context,
        widget.storage,
        initialDriveKey: provider,
      );
      if (!mounted || !widget.storage.isNetdiskLoggedIn(provider)) return;
      if (!identical(_activeSite, targetSite) || !identical(_video, targetVideo)) {
        _toast('剧集信息已更新，请重新选择要播放的文件');
        return;
      }
    }
    int effectiveResumeMs = resumeMs ?? 0;
    if (resumeMs == null) {
      final bm = _findBookmark();
      if (bm != null) {
        final ep = line.episodes[safeEp];
        final target = WoggSource.supports(_activeSite)
            ? WoggSource.resolveCachedBookmarkTarget(_activeSite, _video, bm)
            : null;
        final matches = WoggSource.supports(_activeSite)
            ? target?.$1 == safeLine && target?.$2 == safeEp
            : (bm.line == line.name && bm.index == safeEp) || bm.episode == ep.name;
        if (matches) {
          effectiveResumeMs = bm.resumePosition;
        }
      }
    }
    if (!mounted) return;
    Widget buildPlayer(BuildContext routeCtx) {
      final debugBuilder = widget.debugPlayerBuilder;
      if (debugBuilder != null) {
        return debugBuilder(
          routeCtx,
          targetSite,
          targetVideo,
          safeLine,
          safeEp,
          effectiveResumeMs,
        );
      }
      return PlayerScreen(
        site: targetSite,
        video: targetVideo,
        initialLineIndex: safeLine,
        initialEpisodeIndex: safeEp,
        initialPositionMs: effectiveResumeMs,
        storage: widget.storage,
      );
    }

    if (OhosRuntime.isOhos) {
      await Navigator.of(context).push(
        buildApplePageRoute<void>(builder: buildPlayer),
      );
    } else {
      final hasWindowsAppearance =
          isWindowsDesktopUi && WindowsAppearanceScope.maybeOf(context) != null;
      final hasIndependentPosterCard =
          hasWindowsAppearance ||
          AppleViewportLayout.of(context).prefersWideDetail;
      final reduceMotion = MediaQuery.disableAnimationsOf(context);
      final activeProgram = widget.debugTransitionShaderProgram ??
          PlayerEnterTransition.cachedProgram;

      ui.Image? transitionPoster;
      bool posterTransferred = false;
      try {
        if (hasIndependentPosterCard &&
            !isWindowsDesktopUi &&
            !reduceMotion &&
            activeProgram != null &&
            !PlayerEnterTransition.preferFastTransition &&
            !PlayerEnterTransition.shaderLoadFailed) {
          transitionPoster = await _obtainTransitionPosterImage();
          if (!mounted) return;
        }
        final GlobalKey? activePosterKey =
            hasIndependentPosterCard ? _transitionPosterKey : null;
        final ui.Image? passedPoster =
            activePosterKey != null ? transitionPoster : null;
        final bool passedOwnsPoster = passedPoster != null;
        if (passedOwnsPoster) {
          posterTransferred = true;
        }
        await pushPlayerRoute<void>(
          context: context,
          backdropBoundaryKey: _transitionBackdropKey,
          posterKey: activePosterKey,
          posterRadiusLogical: isWindowsDesktopUi ? 16.0 : 18.0,
          posterImage: passedPoster,
          ownsPoster: passedOwnsPoster,
          useFastWindowsMode: isWindowsDesktopUi,
          debugCapturer: widget.debugTransitionCapturer,
          debugShaderProgram: widget.debugTransitionShaderProgram,
          onModeResolved: widget.debugOnTransitionModeResolved,
          builder: buildPlayer,
        );
      } finally {
        if (!posterTransferred && transitionPoster != null) {
          transitionPoster.dispose();
        }
      }
    }
    if (mounted) setState(() {});
  }

  List<int> _activeEpisodeIndicesFor(CmsLine line) {
    final scrape = _scrapeResultForLine(line);
    final sortByScraped =
        _scrapeOverride?.sortByScrapedEpisode ?? scrape.sourceOrderScrambled;
    final hideSpecials = _scrapeOverride?.hideSpecials ?? false;
    final inLine = CmsParser.extractInLineSeasons(line.episodes);
    if (inLine.length >= 2) {
      final activeNum = _selectedInLineSeason ?? inLine.first.seasonNumber;
      List<int> base = inLine.first.episodeIndexes;
      for (final s in inLine) {
        if (s.seasonNumber == activeNum) {
          base = s.episodeIndexes;
          break;
        }
      }
      var list = hideSpecials
          ? base.where((i) => !scrape.byOriginalIndex[i].isSpecial).toList()
          : List<int>.from(base);
      if (list.isEmpty) list = List<int>.from(base);
      if (sortByScraped) {
        list.sort((a, b) {
          final ea = scrape.byOriginalIndex[a];
          final eb = scrape.byOriginalIndex[b];
          if (ea.isSpecial != eb.isSpecial) return ea.isSpecial ? 1 : -1;
          final na = ea.resolvedEpisodeNumber;
          final nb = eb.resolvedEpisodeNumber;
          if (na != null && nb != null && na != nb) return na.compareTo(nb);
          return a.compareTo(b);
        });
      }
      return list;
    }
    return scrape.orderedIndices(
      sortByScraped: sortByScraped,
      hideSpecials: hideSpecials,
    );
  }

  void _playPrimaryAction(WatchHistoryEntry? bookmark) {
    if (_video.lines.isEmpty) return;
    if (bookmark != null && WoggSource.supports(_activeSite)) {
      final target = WoggSource.resolveCachedBookmarkTarget(_activeSite, _video, bookmark);
      if (target == null || target.$1 != _selectedLine) {
        _toast('原观看文件或线路已变更，请重新选择剧集');
        return;
      }
      _openPlayer(target.$1, target.$2, resumeMs: bookmark.resumePosition);
      return;
    }
    if (bookmark != null) {
      final foundLine =
          _video.lines.indexWhere((l) => l.name == bookmark.line);
      final lineIdx = (foundLine < 0 ? _selectedLine : foundLine)
          .clamp(0, _video.lines.length - 1);
      final eps = _video.lines[lineIdx].episodes;
      final byNameIdx = eps.indexWhere((e) => e.name == bookmark.episode);
      final epIdx = (byNameIdx >= 0 ? byNameIdx : bookmark.index).clamp(
        0,
        eps.length - 1,
      );
      _openPlayer(
        lineIdx,
        epIdx,
        resumeMs: bookmark.resumePosition,
      );
    } else {
      final lineIdx = _selectedLine.clamp(0, _video.lines.length - 1);
      final indices = _activeEpisodeIndicesFor(_video.lines[lineIdx]);
      final firstEpIdx = indices.isNotEmpty ? indices.first : 0;
      _openPlayer(lineIdx, firstEpIdx, resumeMs: 0);
    }
  }

  void _toast(String message) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: const TextStyle(color: AppleColors.labelPrimary, fontSize: 14),
        ),
        behavior: SnackBarBehavior.floating,
        backgroundColor: const Color(0xF22C2C2E),
        elevation: 0,
        shape: const StadiumBorder(),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  void _showSeasonPickerSheet() {
    if (_video.lines.isEmpty) return;
    final safeLineIdx = _selectedLine.clamp(0, _video.lines.length - 1);
    final currentLine = _video.lines[safeLineIdx];
    final inLineSeasons = CmsParser.extractInLineSeasons(currentLine.episodes);
    final hasInLineSeasons = inLineSeasons.length >= 2;
    final activeInLineSeasonNum = hasInLineSeasons
        ? (_selectedInLineSeason ?? inLineSeasons.first.seasonNumber)
        : null;
    final curSeasonInfo = CmsParser.parseSeriesSeasonInfo(_video.title);
    final totalSeasons = hasInLineSeasons
        ? inLineSeasons.length
        : _relatedSeasons.length;

    showIos27LiquidSheet<void>(
      context: context,
      title: totalSeasons > 1 ? '选择季数（共 $totalSeasons 季）' : '选择季数',
      builder: (ctx) {
        final palette = ApplePalette.of(ctx);
        final isDark = palette.isDark;
        final tileBg = isDark ? const Color(0xFF242429) : Colors.white;
        final tileBorder = isDark
            ? const Color(0x22FFFFFF)
            : Colors.black.withValues(alpha: 0.08);
        return ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 10),
              child: Row(
                children: [
                  const Icon(
                    CupertinoIcons.rectangle_stack_fill,
                    color: AppleColors.systemBlue,
                    size: 15,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      totalSeasons > 1
                          ? '连续剧集选季 · 点击切换对应季'
                          : (_discoveringSeasons
                              ? '正在检索同系列其他季…'
                              : '当前仅检索到单季资源'),
                      style: TextStyle(
                        color: palette.labelSecondary,
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (_discoveringSeasons)
                    const CupertinoActivityIndicator(radius: 7)
                  else
                    CupertinoButton(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      minimumSize: const Size(24, 24),
                      onPressed: () {
                        Navigator.of(ctx).pop();
                        _discoveredFranchiseKey = '';
                        unawaited(_discoverRelatedSeasons(_video.title));
                        _toast('正在重新检索同系列季数…');
                      },
                      child: const Text(
                        '重新检索',
                        style: TextStyle(
                          color: AppleColors.systemBlue,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            if (hasInLineSeasons)
              Column(
                children: [
                  for (int idx = 0; idx < inLineSeasons.length; idx++) ...[
                    if (idx > 0) const SizedBox(height: 8),
                    Builder(
                      builder: (_) {
                        final s = inLineSeasons[idx];
                        final isSelected =
                            s.seasonNumber == activeInLineSeasonNum;
                        return Container(
                          decoration: BoxDecoration(
                            color: isSelected
                                ? AppleColors.systemBlue.withValues(
                                    alpha: isDark ? 0.24 : 0.12,
                                  )
                                : tileBg,
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: isSelected
                                  ? AppleColors.systemBlue.withValues(
                                      alpha: 0.45,
                                    )
                                  : tileBorder,
                              width: 0.65,
                            ),
                          ),
                          child: AppleGroupedTile(
                            icon: CupertinoIcons.tv_fill,
                            iconBgColor: isSelected
                                ? AppleColors.systemBlue
                                : (isDark
                                    ? const Color(0xFF3A3A3F)
                                    : const Color(0xFF8E8E93)),
                            title: s.seasonLabel,
                            subtitle:
                                '共 ${s.episodeIndexes.length} 集 · ${currentLine.name}',
                            trailing: isSelected
                                ? const Icon(
                                    CupertinoIcons.checkmark_alt,
                                    color: AppleColors.systemBlue,
                                    size: 18,
                                  )
                                : Icon(
                                    CupertinoIcons.chevron_right,
                                    color: palette.labelTertiary,
                                    size: 15,
                                  ),
                            onTap: () {
                              Navigator.of(ctx).pop();
                              setState(() {
                                _selectedInLineSeason = s.seasonNumber;
                                _selectedPage = 0;
                              });
                            },
                          ),
                        );
                      },
                    ),
                  ],
                ],
              )
            else
              Column(
                children: [
                  for (int idx = 0; idx < _relatedSeasons.length; idx++) ...[
                    if (idx > 0) const SizedBox(height: 8),
                    Builder(
                      builder: (_) {
                        final opt = _relatedSeasons[idx];
                        final isCurrentSeason =
                            (opt.video.id == _video.id &&
                                    opt.site.key == _activeSite.key) ||
                                opt.seasonNumber == curSeasonInfo.seasonNumber;
                        final subParts = <String>[
                          opt.video.title,
                          if (opt.video.remarks.trim().isNotEmpty)
                            opt.video.remarks.trim(),
                          opt.site.name,
                        ];
                        return Container(
                          decoration: BoxDecoration(
                            color: isCurrentSeason
                                ? AppleColors.systemBlue.withValues(
                                    alpha: isDark ? 0.24 : 0.12,
                                  )
                                : tileBg,
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: isCurrentSeason
                                  ? AppleColors.systemBlue.withValues(
                                      alpha: 0.45,
                                    )
                                  : tileBorder,
                              width: 0.65,
                            ),
                          ),
                          child: AppleGroupedTile(
                            icon: CupertinoIcons.tv_fill,
                            iconBgColor: isCurrentSeason
                                ? AppleColors.systemBlue
                                : (isDark
                                    ? const Color(0xFF3A3A3F)
                                    : const Color(0xFF8E8E93)),
                            title: opt.seasonLabel,
                            subtitle: subParts.join(' · '),
                            trailing: isCurrentSeason
                                ? const Icon(
                                    CupertinoIcons.checkmark_alt,
                                    color: AppleColors.systemBlue,
                                    size: 18,
                                  )
                                : Icon(
                                    CupertinoIcons.chevron_right,
                                    color: palette.labelTertiary,
                                    size: 15,
                                  ),
                            onTap: () {
                              Navigator.of(ctx).pop();
                              _switchToRelatedSeason(opt);
                            },
                          ),
                        );
                      },
                    ),
                  ],
                ],
              ),
          ],
        );
      },
    );
  }

  void _showSourcePickerSheet() {
    if (_video.lines.isEmpty) {
      if (!_loading) _searchOtherSources();
      return;
    }
    final safeLineIdx = _selectedLine.clamp(0, _video.lines.length - 1);

    showIos27LiquidSheet<void>(
      context: context,
      title: '切换播放源 (${_video.lines.length})',
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, updateSheet) {
          final palette = ApplePalette.of(ctx);
          final isDark = palette.isDark;
          final tileBg = isDark ? const Color(0xFF242429) : Colors.white;
          final tileBorder = isDark
              ? const Color(0x22FFFFFF)
              : Colors.black.withValues(alpha: 0.08);
          return ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
            children: [
              Padding(
                padding: const EdgeInsets.only(left: 4, bottom: 10),
                child: Row(
                  children: [
                    const Icon(
                      CupertinoIcons.layers_alt_fill,
                      color: AppleColors.systemBlue,
                      size: 15,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '当前站点：${_activeSite.name} · 共 ${_video.lines.length} 条播放线路',
                        style: TextStyle(
                          color: palette.labelSecondary,
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              for (int i = 0; i < _video.lines.length; i++) ...[
                if (i > 0) const SizedBox(height: 8),
                Builder(
                  builder: (_) {
                    final line = _video.lines[i];
                    final selected = i == safeLineIdx;
                    final lineReason = _lineUnavailableReason(line);
                    final lineSpec = OhosRuntime.isOhos
                        ? ''
                        : MediaBadges.formatDotJoined(
                            _specBadgesForLineOnly(line),
                            maxBadges: 3,
                          );
                    final baseSubtitle = lineReason != null
                        ? '共 ${line.episodes.length} 集 · $lineReason'
                        : '共 ${line.episodes.length} 集 · ${_activeSite.name}';
                    final tile = Container(
                      decoration: BoxDecoration(
                        color: selected
                            ? AppleColors.systemBlue.withValues(
                                alpha: isDark ? 0.24 : 0.12,
                              )
                            : tileBg,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: selected
                              ? AppleColors.systemBlue.withValues(alpha: 0.45)
                              : tileBorder,
                          width: 0.65,
                        ),
                      ),
                      child: AppleGroupedTile(
                        icon: CupertinoIcons.layers_alt_fill,
                        iconBgColor: selected
                            ? AppleColors.systemBlue
                            : (isDark
                                ? const Color(0xFF3A3A3F)
                                : const Color(0xFF8E8E93)),
                        title: line.name,
                        subtitle: lineSpec.isEmpty
                            ? baseSubtitle
                            : '$baseSubtitle · $lineSpec',
                        trailing: _activeSite.isEffectivelyPrivate
                            ? null
                            : IconButton(
                                tooltip:
                                    widget.storage.preferredLineName ==
                                            line.name
                                        ? '取消默认播放线路'
                                        : '设为默认播放线路',
                                icon: Icon(
                                  widget.storage.preferredLineName == line.name
                                      ? Icons.star_rounded
                                      : Icons.star_border_rounded,
                                  color: widget.storage.preferredLineName ==
                                          line.name
                                      ? Colors.amber
                                      : palette.labelSecondary,
                                ),
                                onPressed: () async {
                                  await widget.storage.setPreferredLineName(
                                    widget.storage.preferredLineName ==
                                            line.name
                                        ? ''
                                        : line.name,
                                  );
                                  if (ctx.mounted) updateSheet(() {});
                                },
                              ),
                        onTap: () {
                          Navigator.of(ctx).pop();
                          setState(() {
                            _selectedLine = i;
                            _selectedPage = 0;
                            _selectedInLineSeason = null;
                          });
                        },
                      ),
                    );
                    return lineReason != null
                        ? Opacity(opacity: 0.52, child: tile)
                        : tile;
                  },
                ),
              ],
            ],
          );
        },
      ),
    );
  }

  Future<void> _searchOtherSources() async {
    final sites = widget.storage.loadSavedConfig()?.availableSites ?? const <CmsSite>[];
    final candidates = sites.where((s) => s.supported && s.key != _activeSite.key &&
        s.searchable && s.isEffectivelyPrivate == _activeSite.isEffectivelyPrivate).toList();
    final cleanedQuery = CspBridge.cleanNetdiskSearchTitle(_video.title);
    final query = cleanedQuery.isNotEmpty ? cleanedQuery : _video.title;
    final results = widget.client.searchAcrossSites(widget.storage.prioritizeSites(candidates), query);
    final pick = await showIos27LiquidSheet<(CmsSite, CmsVideo)>(
      context: context,
      title: '在其他片源搜索《$query》',
      builder: (_) => _OtherSourceResults(
        results: results,
      ),
    );
    if (pick == null || !mounted) return;
    await Navigator.of(context).push(buildApplePageRoute<void>(
      builder: (_) => DetailScreen(site: pick.$1, initialVideo: pick.$2,
        client: widget.client, storage: widget.storage),
    ));
  }

  void _showAllEpisodesGridSheet(WatchHistoryEntry? bookmark) {
    if (_video.lines.isEmpty) return;
    final safeLineIdx = _selectedLine.clamp(0, _video.lines.length - 1);
    final line = _video.lines[safeLineIdx];
    final scrape = _scrapeResultForLine(line);
    final activeIndices = _activeEpisodeIndicesFor(line);
    final ordered =
        _descending ? activeIndices.reversed.toList() : activeIndices;
    final total = ordered.length;
    String filterQuery = '';
    showIos27LiquidSheet<void>(
      context: context,
      title: '全部剧集 · ${_currentSeasonLabel(line)} · ${line.name} ($total)',
      builder: (ctx) => StatefulBuilder(
        builder: (sheetCtx, setSheetState) {
          final q = filterQuery.trim().toLowerCase();
          final filtered = q.isEmpty
              ? ordered
              : ordered.where((origIdx) {
                  final ep = line.episodes[origIdx];
                  final info = scrape.byOriginalIndex[origIdx];
                  final epNumStr = info.resolvedEpisodeNumber?.toString() ?? '';
                  return ep.name.toLowerCase().contains(q) ||
                      info.displayLabel.toLowerCase().contains(q) ||
                      epNumStr == q;
                }).toList();
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (total >= 12)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: TextField(
                    decoration: InputDecoration(
                      hintText: '输入集数或关键词快速定位（如 180）',
                      prefixIcon: const Icon(CupertinoIcons.search, size: 16),
                      isDense: true,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    onChanged: (v) => setSheetState(() => filterQuery = v),
                  ),
                ),
              Flexible(
                child: GridView.builder(
                  shrinkWrap: true,
                  padding: const EdgeInsets.all(16),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 152,
                    mainAxisSpacing: 10,
                    crossAxisSpacing: 10,
                    childAspectRatio: 2.35,
                  ),
                  itemCount: filtered.length,
                  itemBuilder: (ctx, idx) {
                    final originalIdx = filtered[idx];
                    final ep = line.episodes[originalIdx];
                    final info = scrape.byOriginalIndex[originalIdx];
                    final unavailReason = _episodeUnavailableReason(ep);
                    final isUnavailable = unavailReason != null;
                    final isBookmarked = !isUnavailable &&
                        bookmark != null &&
                        bookmark.line == line.name &&
                        bookmark.index == originalIdx;
                    final showScrapedSub = info.resolvedEpisodeNumber != null &&
                        !info.isSpecial &&
                        ep.name.trim() != info.displayLabel &&
                        !ep.name.contains('第${info.resolvedEpisodeNumber}集');
                    final cell = GestureDetector(
                      onTap: () {
                        if (unavailReason != null) {
                          unawaited(
                            showAppleNativeAlert(
                              ctx,
                              title: ep.name,
                              message: unavailReason,
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
                        _openPlayer(safeLineIdx, originalIdx);
                      },
                      child: Builder(
                        builder: (cellCtx) {
                          final palette = ApplePalette.of(cellCtx);
                          final isDark = palette.isDark;
                          return Tooltip(
                            message: showScrapedSub
                                ? '${info.displayLabel} · ${ep.name}'
                                : ep.name,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: isBookmarked
                                    ? AppleColors.systemBlue
                                    : (isDark
                                        ? const Color(0xFF28282E)
                                        : Colors.white),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: isBookmarked
                                      ? AppleColors.systemBlue
                                      : (isDark
                                          ? const Color(0x26FFFFFF)
                                          : Colors.black.withValues(alpha: 0.09)),
                                  width: isBookmarked ? 1.2 : 0.65,
                                ),
                              ),
                              alignment: Alignment.center,
                              child: showScrapedSub
                                  ? Column(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(
                                          isUnavailable
                                              ? '${info.displayLabel} (不可解析)'
                                              : info.displayLabel,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            color: isBookmarked
                                                ? Colors.white
                                                : palette.labelPrimary,
                                            fontSize: 13,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                        Text(
                                          ep.name,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            color: isBookmarked
                                                ? Colors.white70
                                                : palette.labelSecondary,
                                            fontSize: 10.5,
                                          ),
                                        ),
                                      ],
                                    )
                                  : Text(
                                      isUnavailable
                                          ? '${ep.name} (不可解析)'
                                          : ep.name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: isBookmarked
                                            ? Colors.white
                                            : palette.labelPrimary,
                                        fontSize: 13.5,
                                        fontWeight: isBookmarked
                                            ? FontWeight.w700
                                            : FontWeight.w500,
                                      ),
                                    ),
                            ),
                          );
                        },
                      ),
                    );
                    return isUnavailable
                        ? Opacity(opacity: 0.48, child: cell)
                        : cell;
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  void _showDownloadSheet() {
    if (_activeSite.isEffectivelyPrivate) {
      _toast('隐私分组暂不支持离线下载');
      return;
    }
    if (_video.lines.isEmpty) {
      _toast('暂未获取到可下载的剧集资源');
      return;
    }
    final lineIdx = _selectedLine.clamp(0, _video.lines.length - 1);
    final line = _video.lines[lineIdx];
    final service = DownloadService.instance;
    final selected = <int>{};
    showIos27LiquidSheet<void>(
      context: context,
      title: '下载 · ${line.name}',
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          final palette = ApplePalette.of(ctx);
          final isDark = palette.isDark;
          final total = line.episodes.length;
          final downloadable = <int>[
            for (int i = 0; i < total; i++)
              if (service.taskFor(_activeSite.key, _video.id, line.name, i) ==
                  null)
                i,
          ];
          final allSelected = downloadable.isNotEmpty &&
              downloadable.every(selected.contains);
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 12, 12, 2),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        downloadable.isEmpty
                            ? '本线路的剧集都已在下载列表中'
                            : '选择要下载的剧集 · 已选 ${selected.length}',
                        style: TextStyle(
                          color: palette.labelSecondary,
                          fontSize: 13.5,
                        ),
                      ),
                    ),
                    if (downloadable.isNotEmpty)
                      CupertinoButton(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        minimumSize: const Size(28, 28),
                        onPressed: () => setSheet(() {
                          if (allSelected) {
                            selected.clear();
                          } else {
                            selected.addAll(downloadable);
                          }
                        }),
                        child: Text(
                          allSelected ? '取消全选' : '全选',
                          style: const TextStyle(
                            color: AppleColors.systemBlue,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              Flexible(
                child: GridView.builder(
                  shrinkWrap: true,
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 124,
                    mainAxisSpacing: 8,
                    crossAxisSpacing: 8,
                    childAspectRatio: 2.4,
                  ),
                  itemCount: total,
                  itemBuilder: (context, i) {
                    final ep = line.episodes[i];
                    final task = service.taskFor(
                      _activeSite.key,
                      _video.id,
                      line.name,
                      i,
                    );
                    final exists = task != null;
                    final done = task?.status == DownloadStatus.completed;
                    final isSelected = selected.contains(i);
                    return GestureDetector(
                      onTap: exists
                          ? null
                          : () => setSheet(() {
                                if (isSelected) {
                                  selected.remove(i);
                                } else {
                                  selected.add(i);
                                }
                              }),
                      child: DecoratedBox(
                        decoration: ShapeDecoration(
                          color: isSelected
                              ? AppleColors.systemBlue.withValues(
                                  alpha: isDark ? 0.28 : 0.14,
                                )
                              : (isDark
                                  ? const Color(0xFF28282E)
                                  : Colors.white),
                          shape: RoundedSuperellipseBorder(
                            borderRadius: BorderRadius.circular(11),
                            side: BorderSide(
                              color: isSelected
                                  ? AppleColors.systemBlue
                                  : (isDark
                                      ? const Color(0x26FFFFFF)
                                      : Colors.black.withValues(alpha: 0.09)),
                              width: isSelected ? 1.2 : 0.65,
                            ),
                          ),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              if (exists) ...[
                                Icon(
                                  done
                                      ? CupertinoIcons.checkmark_circle_fill
                                      : CupertinoIcons.arrow_down_circle,
                                  size: 13,
                                  color: done
                                      ? AppleColors.systemGreen
                                      : palette.labelSecondary,
                                ),
                                const SizedBox(width: 4),
                              ],
                              Flexible(
                                child: Text(
                                  ep.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: exists
                                        ? palette.labelTertiary
                                        : (isSelected && !isDark
                                            ? AppleColors.systemBlue
                                            : palette.labelPrimary),
                                    fontSize: 13.5,
                                    fontWeight: isSelected
                                        ? FontWeight.w600
                                        : FontWeight.w500,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                child: Center(
                  child: AppleCapsuleButton(
                    label: selected.isEmpty
                        ? '请选择剧集'
                        : '开始下载（${selected.length} 集）',
                    icon: CupertinoIcons.arrow_down_circle_fill,
                    primary: true,
                    onPressed: selected.isEmpty
                        ? null
                        : () {
                            final list = selected.toList()..sort();
                            final added = service.enqueue(
                              site: _activeSite,
                              video: _video,
                              line: line,
                              episodeIndexes: list,
                              parses: widget.storage.loadSavedConfig()?.parses ?? const [],
                            );
                            Navigator.of(ctx).pop();
                            _toast(
                              added > 0
                                  ? '已加入下载队列 $added 集，可在「片库 › 离线下载」查看'
                                  : '所选剧集已在下载列表中',
                            );
                          },
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final Widget screen;
    if (isWindowsDesktopUi && WindowsAppearanceScope.maybeOf(context) != null) {
      screen = _buildWindowsDetail(context);
    } else {
      final wideLayout = AppleViewportLayout.of(context).prefersWideDetail;
      screen = wideLayout
          ? _buildWideDesktopScreen(context)
          : _buildPortraitImmersiveScreen(context);
    }
    if (OhosRuntime.isOhos) return screen;
    final wrapped = isWindowsDesktopUi
        ? screen
        : AnnotatedRegion<SystemUiOverlayStyle>(
            value: SystemUiOverlayStyle.light,
            child: screen,
          );
    return RepaintBoundary(
      key: _transitionBackdropKey,
      child: wrapped,
    );
  }

  /// Portrait immersive layout:
  /// - True full-bleed poster from `top: 0` down to `77%` of screen height so there is
  ///   zero dead blank space at top or bottom and zero internal top container edge
  /// - Breathable 28% top status-bar scrim so artwork extends behind the clock & top buttons
  /// - Compact progressive frosted glass blur (`ShaderMask` + `BackdropFilter`) + ambient
  ///   color fusion strictly in the lower `58%..100%` text & play-button overlap zone
  Widget _buildPortraitImmersiveScreen(BuildContext context) {
    final targetBg = _resolveBaseAmbientColor();
    final bookmark = _findBookmark();
    final topPad = math.max(
      MediaQuery.paddingOf(context).top,
      defaultTargetPlatform == TargetPlatform.macOS ? 28.0 : 0.0,
    );
    final viewport = AppleViewportLayout.of(context);
    final screenHeight = viewport.height;
    final double posterWindowHeight;
    final double foregroundHeroHeight;
    if (viewport.isShortPortrait) {
      // iPhone Duo 5.4" outer cover (`466×678 pt`) & compact phones:
      // keep title, badges, synopsis, and Play CTA visible above the fold.
      posterWindowHeight = (screenHeight * 0.72).clamp(390.0, 540.0);
      foregroundHeroHeight = (posterWindowHeight * 0.68).clamp(280.0, 390.0);
    } else if (viewport.isExpandedPortrait) {
      // iPhone Duo 7.6" unfolded inner portrait (`669×951 pt`) & iPad portrait:
      // balance full-bleed cinema poster with immediate episode/cast access.
      posterWindowHeight = (screenHeight * 0.62).clamp(540.0, 640.0);
      foregroundHeroHeight = (posterWindowHeight * 0.72).clamp(390.0, 470.0);
    } else {
      posterWindowHeight = (screenHeight * 0.77).clamp(590.0, 740.0);
      foregroundHeroHeight = (posterWindowHeight * 0.74).clamp(430.0, 535.0);
    }
    final double portraitContentPad = viewport.isExpandedPortrait
        ? 28.0
        : (viewport.isCompactSplit ? 14.0 : 18.0);

    return TweenAnimationBuilder<Color?>(
      tween: ColorTween(begin: targetBg, end: targetBg),
      duration: Ios27ConcentricGeometry.isReduceMotion(context)
          ? Ios27ConcentricGeometry.reducedMotionDuration
          : Ios27Spring.smooth.nominalDuration,
      curve: Ios27Spring.smooth.curve,
      builder: (context, animatedBg, _) {
        final bgColor = animatedBg ?? targetBg;
        return Scaffold(
          backgroundColor: bgColor,
          body: Stack(
            fit: StackFit.expand,
            children: [
              // 1. Unified Solid Ambient Canvas Matching Poster Edge Color
              ColoredBox(color: bgColor),

              // 2. Full-Screen Backdrop Layer (true full-bleed from top: 0)
              Positioned.fill(
                child: ValueListenableBuilder<double>(
                  valueListenable: _scrollOffset,
                  builder: (context, offset, child) {
                    final progress = (offset / 340.0).clamp(0.0, 1.0);
                    final blurSigma = progress * 9.5;
                    final scrollVeilAlpha = progress * 0.38;

                    Widget posterStack = Stack(
                      fit: StackFit.expand,
                      children: [
                        ColoredBox(color: bgColor),
                        // Full-bleed poster starting at physical screen top (top: 0)
                        // with 100% clarity across the upper 62% and intrinsic alpha
                        // feathering in the lower text-overlap region
                        Positioned(
                          top: 0,
                          left: 0,
                          right: 0,
                          height: posterWindowHeight,
                          child: ShaderMask(
                            blendMode: BlendMode.dstIn,
                            shaderCallback: (rect) => const LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                Color(0xFFFFFFFF),
                                Color(0xFFFFFFFF),
                                Color(0xBFFFFFFF),
                                Color(0x4DFFFFFF),
                                Color(0x00FFFFFF),
                                Color(0x00FFFFFF),
                              ],
                              stops: [0.0, 0.62, 0.78, 0.90, 0.98, 1.0],
                            ).createShader(rect),
                            child: child!,
                          ),
                        ),
                        // Ultra-light breathable top status-bar scrim (keeps poster
                        // visible right up to y = 0 while ensuring white clock legibility)
                        Positioned(
                          top: 0,
                          left: 0,
                          right: 0,
                          height: topPad + 54,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [
                                  bgColor.withValues(alpha: 0.28),
                                  bgColor.withValues(alpha: 0.10),
                                  bgColor.withValues(alpha: 0.0),
                                ],
                                stops: const [0.0, 0.55, 1.0],
                              ),
                            ),
                          ),
                        ),
                        // Compact Progressive Frosted Glass Blur Transition strictly
                        // behind the lower title / synopsis / play button overlap zone
                        Positioned(
                          top: posterWindowHeight * 0.58,
                          left: 0,
                          right: 0,
                          height: posterWindowHeight * 0.42,
                          child: ShaderMask(
                            blendMode: BlendMode.dstIn,
                            shaderCallback: (rect) => const LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                Color(0x00FFFFFF),
                                Color(0x8CFFFFFF),
                                Color(0xFFFFFFFF),
                                Color(0x00FFFFFF),
                              ],
                              stops: [0.0, 0.36, 0.84, 1.0],
                            ).createShader(rect),
                            child: ClipRect(
                              child: BackdropFilter(
                                filter: ImageFilter.blur(
                                  sigmaX: 6.5,
                                  sigmaY: 6.5,
                                  tileMode: TileMode.clamp,
                                ),
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    gradient: LinearGradient(
                                      begin: Alignment.topCenter,
                                      end: Alignment.bottomCenter,
                                      colors: [
                                        bgColor.withValues(alpha: 0.0),
                                        bgColor.withValues(alpha: 0.46),
                                        bgColor.withValues(alpha: 0.86),
                                        bgColor,
                                      ],
                                      stops: const [0.0, 0.38, 0.76, 0.96],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    );

                    if (blurSigma > 0.15) {
                      posterStack = ImageFiltered(
                        imageFilter: ImageFilter.blur(
                          sigmaX: blurSigma,
                          sigmaY: blurSigma,
                          tileMode: TileMode.clamp,
                        ),
                        child: posterStack,
                      );
                    }

                    return Stack(
                      fit: StackFit.expand,
                      children: [
                        posterStack,
                        // Post-blur bottom lock gradient strictly in the lower overlap &
                        // episode list zone, guaranteeing zero bottom seam when scrolling
                        Positioned(
                          top: posterWindowHeight * 0.64,
                          left: 0,
                          right: 0,
                          bottom: 0,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [
                                  bgColor.withValues(alpha: 0.0),
                                  bgColor.withValues(alpha: 0.50),
                                  bgColor.withValues(alpha: 0.90),
                                  bgColor,
                                  bgColor,
                                ],
                                stops: const [0.0, 0.24, 0.42, 0.54, 1.0],
                              ),
                            ),
                          ),
                        ),
                        if (scrollVeilAlpha > 0.01)
                          Positioned.fill(
                            child: ColoredBox(
                              color: bgColor.withValues(alpha: scrollVeilAlpha),
                            ),
                          ),
                      ],
                    );
                  },
                  child: PosterImage(
                    url: _video.poster,
                    title: _publicLookupTitle,
                    year: _video.year,
                    fit: BoxFit.cover,
                    alignment: const Alignment(0.0, -0.32),
                    highRes: true,
                    strictHighRes: true,
                    onBytesLoaded: _updateAmbientFromBytes,
                    placeholder: _posterPlaceholder(bgColor),
                  ),
                ),
              ),

              // 3. Main Scrollable Foreground Content
              MediaQuery.removePadding(
                context: context,
                removeTop: true,
                child: NotificationListener<ScrollNotification>(
                  onNotification: (notification) {
                    if (notification.metrics.axis == Axis.vertical) {
                      final next =
                          notification.metrics.pixels.clamp(0.0, 500.0);
                      if ((_scrollOffset.value - next).abs() > 0.5) {
                        _scrollOffset.value = next;
                      }
                    }
                    return false;
                  },
                  child: SingleChildScrollView(
                    physics: const BouncingScrollPhysics(),
                    padding: const EdgeInsets.only(bottom: 44),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _buildPortraitHeroForeground(
                          context,
                          heroHeight: foregroundHeroHeight,
                        ),
                        Center(
                          child: ConstrainedBox(
                            constraints: BoxConstraints(
                              maxWidth: viewport.isExpandedPortrait
                                  ? 640.0
                                  : double.infinity,
                            ),
                            child: Padding(
                              padding: EdgeInsets.symmetric(
                                horizontal: portraitContentPad,
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  _buildPortraitSynopsis(),
                                  const SizedBox(height: 14),
                                  _buildPortraitActionRow(bookmark),
                                  if (bookmark != null) ...[
                                    const SizedBox(height: 10),
                                    _buildPortraitBookmarkProgress(bookmark),
                                  ],
                                  const SizedBox(height: 18),
                                  CastAvatarSection(
                                    title: _effectiveLookupTitle.isNotEmpty
                                        ? _effectiveLookupTitle
                                        : _video.title,
                                    actorRaw: _video.actor,
                                    year: _effectiveLookupYear,
                                    doubanId: _effectiveDoubanId,
                                    wantMotionComic: _effectiveWantMotionComic,
                                    allowExternalLookup:
                                        !_activeSite.isEffectivelyPrivate,
                                    forceDark: true,
                                    padding: EdgeInsets.zero,
                                  ),
                                  const SizedBox(height: 18),
                                  if (!_loading && _video.sourceWarnings.isNotEmpty)
                                    _buildSourceWarningsSection(),
                                  if (!_loading &&
                                      _activeSite.playbackHint.isNotEmpty &&
                                      _configuredParses.isEmpty)
                                    _buildPlaybackHintBanner(),
                                  if (_loading)
                                    Padding(
                                      padding: const EdgeInsets.symmetric(vertical: 32),
                                      child: Center(
                                        child: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            const CupertinoActivityIndicator(radius: 14),
                                            if (CuratedDiscoveryService.isCuratedSite(
                                                _activeSite)) ...[
                                              const SizedBox(height: 10),
                                              const Text(
                                                '正在您添加的片源中匹配播放资源…',
                                                style: TextStyle(
                                                  color: AppleColors.labelSecondary,
                                                  fontSize: 13,
                                                ),
                                              ),
                                            ],
                                          ],
                                        ),
                                      ),
                                    )
                                  else if (_curatedUnavailableMessage != null)
                                    _buildCuratedUnavailableCard()
                                  else if (_error != null)
                                    _buildDetailError()
                                  else if (_video.lines.isEmpty)
                                    const Padding(
                                      padding: EdgeInsets.symmetric(vertical: 20),
                                      child: Text(
                                        '当前片源未提供可播放剧集，请重试或手动切换片源',
                                        textAlign: TextAlign.center,
                                        style: TextStyle(
                                          color: AppleColors.labelSecondary,
                                          fontSize: 14,
                                        ),
                                      ),
                                    )
                                  else
                                    _buildPortraitEpisodesSection(bookmark),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),

              // 4. Floating Liquid Glass Top Navigation Bar (Back on Left, Source Picker + Download/Favorite on Right)
              Positioned(
                top: topPad + 8,
                left: viewport.isCompactSplit ? 12 : 16,
                right: viewport.isCompactSplit ? 12 : 16,
                child: Row(
                  children: [
                    _buildFloatingGlassCircleButton(
                      icon: CupertinoIcons.chevron_back,
                      onTap: () => Navigator.of(context).maybePop(),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: _buildFloatingSourceButton(
                          maxWidth: viewport.isCompactSplit ? 112.0 : 168.0,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    _buildFloatingTopRightPill(),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildPlaybackHintBanner() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Container(
        key: const ValueKey('detail-playback-hint-banner'),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0x22FF9F0A),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0x45FF9F0A), width: 0.6),
        ),
        child: Row(
          children: [
            const Icon(
              CupertinoIcons.info_circle,
              size: 14,
              color: Color(0xFFFFD60A),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                _activeSite.playbackHint,
                style: const TextStyle(
                  color: Color(0xFFFFD60A),
                  fontSize: 12.5,
                  height: 1.35,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSourceWarningsSection() {
    if (_video.lines.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Text(
          _video.sourceWarnings.join('\n'),
          style: const TextStyle(color: AppleColors.labelSecondary, fontSize: 13),
        ),
      );
    }
    final primaryWarnings = <String>[];
    final backupWarnings = <String>[];
    for (final warning in _video.sourceWarnings) {
      if (warning.startsWith('观看记录：') || warning.contains('目录返回不完整')) {
        primaryWarnings.add(warning);
      } else {
        backupWarnings.add(warning);
      }
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (primaryWarnings.isNotEmpty)
            Padding(
              padding: EdgeInsets.only(bottom: backupWarnings.isNotEmpty ? 6 : 0),
              child: Text(
                primaryWarnings.join('\n'),
                style: const TextStyle(
                  color: AppleColors.labelSecondary,
                  fontSize: 13,
                ),
              ),
            ),
          if (backupWarnings.isNotEmpty) ...[
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(
                () => _sourceWarningsExpanded = !_sourceWarningsExpanded,
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    const Icon(
                      CupertinoIcons.info_circle,
                      size: 14,
                      color: AppleColors.labelTertiary,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '已加载 ${_video.lines.length} 条可用线路（另有 ${backupWarnings.length} 条备用分享已跳过）',
                        style: const TextStyle(
                          color: AppleColors.labelTertiary,
                          fontSize: 12,
                        ),
                      ),
                    ),
                    Icon(
                      _sourceWarningsExpanded
                          ? CupertinoIcons.chevron_up
                          : CupertinoIcons.chevron_down,
                      size: 13,
                      color: AppleColors.labelTertiary,
                    ),
                  ],
                ),
              ),
            ),
            if (_sourceWarningsExpanded)
              Padding(
                padding: const EdgeInsets.only(top: 6, left: 20),
                child: Text(
                  backupWarnings.join('\n'),
                  style: const TextStyle(
                    color: AppleColors.labelTertiary,
                    fontSize: 12,
                    height: 1.4,
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _buildFloatingGlassCircleButton({
    required IconData icon,
    required VoidCallback onTap,
    String symbol = 'chevron.backward',
    String accessibilityLabel = '返回',
  }) {
    final fallback = Ios27Pressable(
      pressedScale: Ios27Spring.pressSwellScale,
      borderRadius: 20,
      onTap: onTap,
      child: LiquidGlass(
        width: 40,
        height: 40,
        borderRadius: 20,
        elevated: false,
        tint: const Color(0x5E1E1E22),
        child: Center(
          child: Icon(
            icon,
            color: AppleColors.labelPrimary,
            size: 20,
          ),
        ),
      ),
    );
    return IosNativeGlassButton(
      style: 'circle',
      symbol: symbol,
      symbolSize: 17,
      foregroundColor: Colors.white,
      forceDark: true,
      width: 40,
      height: 40,
      accessibilityLabel: accessibilityLabel,
      onTap: onTap,
      fallback: fallback,
    );
  }

  /// Top-right floating Liquid Glass source selector button (`选源`):
  /// Displays the active playback source/line name and opens `_showSourcePickerSheet`.
  Widget _buildFloatingSourceButton({double maxWidth = 168.0}) {
    final hasLines = _video.lines.isNotEmpty;
    final safeLineIdx = hasLines
        ? _selectedLine.clamp(0, _video.lines.length - 1)
        : 0;
    final activeLineName = hasLines
        ? _video.lines[safeLineIdx].name
        : (_loading ? '加载片源…' : _activeSite.name);

    final fallback = Ios27Pressable(
      key: const ValueKey('source_picker_button'),
      pressedScale: Ios27Spring.pressSwellScale,
      borderRadius: 999,
      onTap: _showSourcePickerSheet,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: LiquidGlass(
          height: 40,
          borderRadius: 999,
          elevated: false,
          tint: const Color(0x5E1E1E22),
          padding: const EdgeInsets.symmetric(horizontal: 13),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                CupertinoIcons.layers_alt_fill,
                color: AppleColors.labelPrimary,
                size: 15,
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  activeLineName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppleColors.labelPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.2,
                  ),
                ),
              ),
              const SizedBox(width: 4),
              const Icon(
                CupertinoIcons.chevron_down,
                color: Color(0xCCFFFFFF),
                size: 12,
              ),
            ],
          ),
        ),
      ),
    );

    return IosNativeGlassButton(
      style: 'capsule',
      symbol: 'square.3.layers.3d',
      trailingSymbol: 'chevron.down',
      label: activeLineName,
      symbolSize: 14,
      foregroundColor: Colors.white,
      forceDark: true,
      maxWidth: maxWidth,
      height: 40,
      accessibilityLabel: '切换片源 $activeLineName',
      onTap: _showSourcePickerSheet,
      fallback: fallback,
    );
  }

  /// Top-right floating Liquid Glass capsule:
  /// Left button = Netdisk QR Login (`网盘扫码`)
  /// Middle button = Offline Download (`离线缓存`)
  /// Right button = Favorite (`收藏`)
  Widget _buildFloatingTopRightPill() {
    final currentLine = _video.lines.isEmpty
        ? null
        : _video.lines[_selectedLine.clamp(0, _video.lines.length - 1)];
    final driveKey = currentLine != null && currentLine.episodes.isNotEmpty
        ? currentLine.episodes.first.cloudProvider
        : null;

    void onOpenNetdisk() => showNetdiskAccountSheet(
          context,
          widget.storage,
          initialDriveKey: driveKey ??
              CspBridge.netdiskDriveKeyForLineName(currentLine?.name ?? ''),
          onChanged: () {
            if (mounted) setState(() {});
          },
        );

    Future<void> onToggleFavorite() async {
      final fav = await widget.storage.toggleFavorite(
        _activeSite,
        _video,
      );
      if (mounted) {
        setState(() => _isFavorite = fav);
        if (fav) {
          unawaited(
            FavoritePostcardFlightOverlay.show(
              context,
              title: _video.title,
              posterUrl: _video.poster,
              year: _video.year,
              cachedBytes: _loadedPosterBytes,
            ),
          );
        } else {
          _toast('已从片库移除');
        }
      }
    }

    final fallback = LiquidGlass(
      height: 40,
      borderRadius: 999,
      elevated: false,
      tint: const Color(0x5E1E1E22),
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Ios27Pressable(
            key: const ValueKey('detail-netdisk-qr-button'),
            pressedScale: Ios27Spring.pressSwellScale,
            borderRadius: 999,
            onTap: onOpenNetdisk,
            child: const SizedBox(
              width: 38,
              height: 36,
              child: Center(
                child: Icon(
                  CupertinoIcons.qrcode_viewfinder,
                  color: AppleColors.labelPrimary,
                  size: 19,
                ),
              ),
            ),
          ),
          Container(
            width: 0.6,
            height: 18,
            color: const Color(0x36FFFFFF),
          ),
          Ios27Pressable(
            pressedScale: Ios27Spring.pressSwellScale,
            borderRadius: 999,
            onTap: _showDownloadSheet,
            child: const SizedBox(
              width: 38,
              height: 36,
              child: Center(
                child: Icon(
                  CupertinoIcons.arrow_down_to_line,
                  color: AppleColors.labelPrimary,
                  size: 19,
                ),
              ),
            ),
          ),
          Container(
            width: 0.6,
            height: 18,
            color: const Color(0x36FFFFFF),
          ),
          Ios27Pressable(
            pressedScale: Ios27Spring.pressSwellScale,
            borderRadius: 999,
            onTap: () => unawaited(onToggleFavorite()),
            child: SizedBox(
              width: 38,
              height: 36,
              child: Center(
                child: Icon(
                  _isFavorite
                      ? CupertinoIcons.heart_fill
                      : CupertinoIcons.heart,
                  color: _isFavorite
                      ? AppleColors.systemRed
                      : AppleColors.labelPrimary,
                  size: 19,
                ),
              ),
            ),
          ),
        ],
      ),
    );

    return IosNativeGlassPill(
      height: 40,
      forceDark: true,
      actions: [
        IosNativeGlassPillAction(
          symbol: 'qrcode.viewfinder',
          color: Colors.white,
          accessibilityLabel: '网盘扫码',
          onTap: onOpenNetdisk,
        ),
        IosNativeGlassPillAction(
          symbol: 'arrow.down.to.line',
          color: Colors.white,
          accessibilityLabel: '离线下载',
          onTap: _showDownloadSheet,
        ),
        IosNativeGlassPillAction(
          symbol: _isFavorite ? 'heart.fill' : 'heart',
          color: _isFavorite ? AppleColors.systemRed : Colors.white,
          accessibilityLabel: _isFavorite ? '取消收藏' : '收藏',
          onTap: () => unawaited(onToggleFavorite()),
        ),
      ],
      fallback: fallback,
    );
  }

  Widget _buildPortraitHeroForeground(
    BuildContext context, {
    required double heroHeight,
  }) {
    final safeLineIdx = _video.lines.isEmpty
        ? 0
        : _selectedLine.clamp(0, _video.lines.length - 1);
    final epCount = _video.lines.isEmpty
        ? 0
        : _video.lines[safeLineIdx].episodes.length;
    final pills = <String>[
      if (_video.year.trim().isNotEmpty) _video.year.trim(),
      if (_video.area.trim().isNotEmpty) _video.area.trim(),
      if (_video.tag.trim().isNotEmpty) _video.tag.trim(),
      if (_video.remarks.trim().isNotEmpty)
        _video.remarks.trim()
      else if (epCount > 1)
        '共$epCount集',
    ];

    return SizedBox(
      height: heroHeight,
      child: Align(
        alignment: Alignment.bottomCenter,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Text(
                _video.title,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 30,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.5,
                  height: 1.18,
                  shadows: [
                    Shadow(
                      color: Color(0xB3000000),
                      blurRadius: 18,
                      offset: Offset(0, 4),
                    ),
                  ],
                ),
              ),
              if (pills.isNotEmpty) ...[
                const SizedBox(height: 12),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    for (final tag in pills.take(4))
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0x38FFFFFF),
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(
                            color: const Color(0x33FFFFFF),
                            width: 0.5,
                          ),
                        ),
                        child: Text(
                          tag,
                          style: const TextStyle(
                            color: Color(0xF2FFFFFF),
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 10),
              _buildRatingsAndSiteWrap(alignment: WrapAlignment.center),
              if (!OhosRuntime.isOhos) ...[
                Builder(
                  builder: (_) {
                    final activeLine = _video.lines.isEmpty
                        ? null
                        : _video.lines[safeLineIdx];
                    final specBadges = _specBadgesForHero(activeLine);
                    if (specBadges.isEmpty) return const SizedBox.shrink();
                    return Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: MediaBadgeRow(
                        badges: specBadges,
                        maxBadges: 5,
                        alignment: WrapAlignment.center,
                      ),
                    );
                  },
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  List<MediaBadge> _specBadgesForLineOnly(CmsLine? line) {
    if (OhosRuntime.isOhos || line == null) return const <MediaBadge>[];
    final firstEp = line.episodes.isNotEmpty ? line.episodes.first : null;
    return MediaBadges.extractBadgesFromSources(<String?>[
      line.name,
      firstEp?.name,
      firstEp?.url,
    ]);
  }

  List<MediaBadge> _specBadgesForHero(CmsLine? line) {
    if (OhosRuntime.isOhos) return const <MediaBadge>[];
    final lineBadges = _specBadgesForLineOnly(line);
    if (lineBadges.isNotEmpty) return lineBadges;
    return MediaBadges.extractBadges(_video.remarks);
  }

  double? _effectiveDoubanScore() {
    if (!_activeSite.isEffectivelyPrivate) {
      final boundRating = _scrapeOverride?.doubanScore;
      if (boundRating != null && boundRating >= 2.0 && boundRating <= 10.0) {
        return boundRating;
      }
    }
    final direct = _video.doubanScore;
    if (direct != null && direct >= 2.0 && direct <= 10.0) return direct;
    if (!_activeSite.isEffectivelyPrivate) {
      final resolved = _resolvedDoubanScore;
      if (resolved != null && resolved >= 2.0 && resolved <= 10.0) {
        return resolved;
      }
    }
    final textBlob = _activeSite.isEffectivelyPrivate
        ? '${_video.remarks} ${_video.description}'
        : '${_video.remarks} ${_video.description} $_externalSynopsis';
    return CmsParser.extractDoubanScoreFromText(textBlob);
  }

  int? _effectiveRtScore() {
    final direct = _video.rtScore;
    if (direct != null && direct >= 1 && direct <= 100) return direct;
    if (!_activeSite.isEffectivelyPrivate) {
      final resolved = _resolvedRtScore;
      if (resolved != null && resolved >= 1 && resolved <= 100) {
        return resolved;
      }
    }
    final textBlob = _activeSite.isEffectivelyPrivate
        ? '${_video.remarks} ${_video.description}'
        : '${_video.remarks} ${_video.description} $_externalSynopsis';
    return CmsParser.extractRtScoreFromText(textBlob);
  }

  Widget _buildRatingsAndSiteWrap({required WrapAlignment alignment}) {
    final doubanScore = _effectiveDoubanScore();
    final rtPercent = _effectiveRtScore();
    final siteName = _activeSite.name.trim();
    return Wrap(
      alignment: alignment,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 8,
      runSpacing: 6,
      children: [
        if (doubanScore != null && doubanScore >= 2.0 && doubanScore <= 10.0)
          Container(
            key: const ValueKey('detail-douban-badge'),
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
            decoration: BoxDecoration(
              color: const Color(0x3800B51D),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(
                color: const Color(0x6634D399),
                width: 0.8,
              ),
            ),
            child: Text(
              '豆瓣 ★ ${doubanScore.toStringAsFixed(1)}',
              style: const TextStyle(
                color: Color(0xFF6EE7B7),
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        if (rtPercent != null && rtPercent >= 1 && rtPercent <= 100)
          Container(
            key: const ValueKey('detail-rt-badge'),
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
            decoration: BoxDecoration(
              color: const Color(0x38FA320A),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(
                color: const Color(0x66FF6B4A),
                width: 0.8,
              ),
            ),
            child: Text(
              '烂番茄 $rtPercent%',
              style: const TextStyle(
                color: Color(0xFFFFB4A2),
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        if (siteName.isNotEmpty)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
            decoration: BoxDecoration(
              color: const Color(0x26FFFFFF),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(
                color: const Color(0x38FFFFFF),
                width: 0.8,
              ),
            ),
            child: Text(
              siteName,
              style: const TextStyle(
                color: Color(0xE6FFFFFF),
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildPortraitSynopsis() {
    final desc = _effectiveSeriesSynopsis();
    final cast = _video.actor.trim().isNotEmpty
        ? '演职员：${_video.actor.trim()}'
        : '';
    if (desc.isEmpty && cast.isEmpty) {
      return const SizedBox.shrink();
    }
    return GestureDetector(
      onTap: () => setState(() => _synopsisExpanded = !_synopsisExpanded),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (desc.isNotEmpty)
            Text(
              desc,
              textAlign: TextAlign.center,
              maxLines: _synopsisExpanded ? 18 : 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Color(0xD9FFFFFF),
                fontSize: 13.5,
                height: 1.55,
              ),
            ),
          if (_synopsisExpanded && cast.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              cast,
              textAlign: TextAlign.center,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Color(0x99FFFFFF),
                fontSize: 12,
                height: 1.4,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildCuratedUnavailableCard() {
    return Container(
      key: const Key('curated-no-source-card'),
      margin: const EdgeInsets.symmetric(vertical: 10),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.14),
          width: 0.8,
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            CupertinoIcons.exclamationmark_circle,
            color: AppleColors.systemOrange,
            size: 26,
          ),
          const SizedBox(height: 8),
          Text(
            _curatedUnavailableMessage ?? '暂无可播放资源',
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13.5,
              fontWeight: FontWeight.w600,
              height: 1.45,
            ),
          ),
          const SizedBox(height: 10),
          CupertinoButton(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            color: Colors.white.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(999),
            onPressed: _searchOtherSources,
            child: const Text(
              '手动检索其他片源',
              style: TextStyle(
                color: Colors.white,
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPortraitActionRow(WatchHistoryEntry? bookmark) {
    final hasLines = _video.lines.isNotEmpty;
    final curatedBlocked = _curatedUnavailableMessage != null && !hasLines;
    final selectedBookmark = hasLines &&
            bookmark?.line ==
                _video.lines[_selectedLine.clamp(0, _video.lines.length - 1)].name
        ? bookmark
        : null;
    String playLabel = CuratedDiscoveryService.isCuratedSite(_activeSite)
        ? '正在匹配已添加片源…'
        : '加载片源中…';
    if (curatedBlocked) {
      playLabel = '暂无片源资源 · 无法播放';
    } else if (!_loading && !hasLines) {
      playLabel = '搜索其他片源';
    } else if (selectedBookmark != null) {
      final (cleanEp, _) =
          _parseEpisodeDisplay(selectedBookmark.episode, selectedBookmark.index + 1);
      final resumeMs = selectedBookmark.resumePosition;
      playLabel = resumeMs > 0
          ? '播放 · $cleanEp · 续播 ${_formatBookmarkTime(resumeMs)}'
          : '播放 · $cleanEp';
    } else if (hasLines) {
      final safeLineIdx = _selectedLine.clamp(0, _video.lines.length - 1);
      final line = _video.lines[safeLineIdx];
      final indices = _activeEpisodeIndicesFor(line);
      if (indices.isNotEmpty) {
        final firstEp = line.episodes[indices.first];
        final (cleanFirst, _) = _parseEpisodeDisplay(firstEp.name, 1);
        playLabel = '播放 · $cleanFirst';
      } else {
        playLabel = '立即播放';
      }
    }

    return Ios27Pressable(
      key: const Key('detail-primary-play-button'),
      pressedScale: Ios27Spring.pressSwellScale,
      borderRadius: 999,
      onTap: hasLines
          ? () => _playPrimaryAction(selectedBookmark)
          : (_loading || curatedBlocked ? null : _searchOtherSources),
      child: Container(
        height: 48,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        decoration: BoxDecoration(
          color: hasLines
              ? const Color(0xF5FFFFFF)
              : const Color(0x38FFFFFF),
          borderRadius: BorderRadius.circular(999),
          boxShadow: hasLines
              ? const [
                  BoxShadow(
                    color: Color(0x40000000),
                    blurRadius: 16,
                    offset: Offset(0, 6),
                  ),
                ]
              : null,
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (hasLines) ...[
              const Icon(
                CupertinoIcons.play_fill,
                color: Color(0xFF121215),
                size: 17,
              ),
              const SizedBox(width: 8),
            ],
            Flexible(
              child: Text(
                playLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: hasLines
                      ? const Color(0xFF121215)
                      : const Color(0xCCFFFFFF),
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.2,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPortraitBookmarkProgress(WatchHistoryEntry bookmark) {
    final ratio = bookmark.progressFraction.clamp(0.05, 1.0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(
              CupertinoIcons.play_circle_fill,
              color: Color(0xCCFFFFFF),
              size: 14,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                bookmark.position > 0
                    ? '已观看 [${bookmark.episode}] 至 ${_formatBookmarkTime(bookmark.position)} · 线路：${bookmark.line}'
                    : '已观看 [${bookmark.episode}] · 线路：${bookmark.line}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Color(0xCCFFFFFF),
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(999),
          child: LinearProgressIndicator(
            value: ratio,
            minHeight: 3.5,
            backgroundColor: const Color(0x26FFFFFF),
            valueColor: const AlwaysStoppedAnimation<Color>(Color(0xF2FFFFFF)),
          ),
        ),
      ],
    );
  }

  Widget _buildPortraitEpisodesSection(WatchHistoryEntry? bookmark) {
    final safeLineIdx = _selectedLine.clamp(0, _video.lines.length - 1);
    final line = _video.lines[safeLineIdx];
    final inLineSeasons = CmsParser.extractInLineSeasons(line.episodes);
    final hasInLineSeasons = inLineSeasons.length >= 2;
    final activeIndices = _activeEpisodeIndicesFor(line);
    final total = activeIndices.length;
    final pageCount =
        (total + CmsParser.episodePageSize - 1) ~/ CmsParser.episodePageSize;
    final safePage = _selectedPage.clamp(0, pageCount > 0 ? pageCount - 1 : 0);
    final start = safePage * CmsParser.episodePageSize;
    final end = (start + CmsParser.episodePageSize).clamp(0, total);
    final currentActiveEpIdx =
        (bookmark != null && bookmark.line == line.name)
            ? bookmark.index.clamp(0, line.episodes.length - 1)
            : (activeIndices.isNotEmpty ? activeIndices.first : 0);
    final seasonLabel = _currentSeasonLabel(line);
    final totalSeasons =
        hasInLineSeasons ? inLineSeasons.length : _relatedSeasons.length;
    final curSeasonInfo = CmsParser.parseSeriesSeasonInfo(_video.title);
    final activeInLineSeasonNum = hasInLineSeasons
        ? (_selectedInLineSeason ?? inLineSeasons.first.seasonNumber)
        : null;

    // Check if any episode in the current range has an authentic plot summary
    bool anyHasSummary = false;
    for (int idx = 0; idx < (end - start); idx++) {
      final visualIdx = start + idx;
      final posIdx = _descending ? (total - 1 - visualIdx) : visualIdx;
      final originalIdx = activeIndices[posIdx];
      final ep = line.episodes[originalIdx];
      final (cleanTitle, _) = _parseEpisodeDisplay(ep.name, posIdx + 1);
      if (_resolveAuthenticEpisodeSummary(posIdx + 1, cleanTitle).isNotEmpty) {
        anyHasSummary = true;
        break;
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 1. Dedicated Season Selector Header + Sort + All Episodes Grid trigger
        Row(
          children: [
            Flexible(
              child: GestureDetector(
                key: const ValueKey('season_picker_button'),
                onTap: _showSeasonPickerSheet,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(
                        seasonLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.3,
                        ),
                      ),
                    ),
                    if (totalSeasons > 1) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0x2EFFFFFF),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          '共$totalSeasons季',
                          style: const TextStyle(
                            color: Color(0xF2FFFFFF),
                            fontSize: 10.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ] else if (_discoveringSeasons) ...[
                      const SizedBox(width: 6),
                      const CupertinoActivityIndicator(radius: 6.5),
                    ],
                    const SizedBox(width: 5),
                    const Icon(
                      CupertinoIcons.chevron_down,
                      color: Color(0xCCFFFFFF),
                      size: 15,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: () {
                final next = !_descending;
                widget.storage.setEpisodesDescending(next);
                setState(() {
                  _descending = next;
                  _selectedPage = 0;
                });
              },
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: const Color(0x24FFFFFF),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(
                    color: const Color(0x30FFFFFF),
                    width: 0.5,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _descending
                          ? CupertinoIcons.arrow_down
                          : CupertinoIcons.arrow_up,
                      color: const Color(0xE6FFFFFF),
                      size: 12,
                    ),
                    const SizedBox(width: 3),
                    Text(
                      _descending ? '倒序' : '正序',
                      style: const TextStyle(
                        color: Color(0xE6FFFFFF),
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: () => _showAllEpisodesGridSheet(bookmark),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 11,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: const Color(0x24FFFFFF),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(
                    color: const Color(0x30FFFFFF),
                    width: 0.5,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      CupertinoIcons.square_grid_2x2_fill,
                      color: Color(0xE6FFFFFF),
                      size: 12,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '全部剧集 ($total)',
                      style: const TextStyle(
                        color: Color(0xE6FFFFFF),
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

        // 1b. Direct Multi-Season Selector Strip (visible whenever >= 2 seasons exist)
        if (totalSeasons > 1) ...[
          const SizedBox(height: 11),
          SizedBox(
            height: 32,
            child: DesktopHorizontalScroller(
              controller: _seasonsScrollController,
              child: ListView.separated(
                controller: _seasonsScrollController,
                scrollDirection: Axis.horizontal,
                physics: const BouncingScrollPhysics(),
                itemCount: totalSeasons,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (ctx, sIdx) {
                if (hasInLineSeasons) {
                  final s = inLineSeasons[sIdx];
                  final isSelected = s.seasonNumber == activeInLineSeasonNum;
                  return Ios27Pressable(
                    key: ValueKey('season_pill_inline_${s.seasonNumber}'),
                    pressedScale: Ios27Spring.pressSwellScale,
                    borderRadius: 999,
                    onTap: () {
                      setState(() {
                        _selectedInLineSeason = s.seasonNumber;
                        _selectedPage = 0;
                      });
                    },
                    child: AnimatedContainer(
                      duration: Ios27ConcentricGeometry.isReduceMotion(ctx)
                          ? Ios27ConcentricGeometry.reducedMotionDuration
                          : Ios27Spring.snappy.nominalDuration,
                      curve: Ios27Spring.snappy.curve,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: isSelected
                            ? Colors.white
                            : const Color(0x24FFFFFF),
                        borderRadius: BorderRadius.circular(999),
                        border: isSelected
                            ? null
                            : Border.all(
                                color: const Color(0x30FFFFFF),
                                width: 0.5,
                              ),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        '${s.seasonLabel} (${s.episodeIndexes.length})',
                        style: TextStyle(
                          color: isSelected
                              ? const Color(0xFF121215)
                              : const Color(0xE6FFFFFF),
                          fontSize: 12.5,
                          fontWeight:
                              isSelected ? FontWeight.w800 : FontWeight.w600,
                        ),
                      ),
                    ),
                  );
                }
                final opt = _relatedSeasons[sIdx];
                final isSelected = (opt.video.id == _video.id &&
                        opt.site.key == _activeSite.key) ||
                    opt.seasonNumber == curSeasonInfo.seasonNumber;
                return Ios27Pressable(
                  key: ValueKey('season_pill_${opt.seasonNumber}'),
                  pressedScale: Ios27Spring.pressSwellScale,
                  borderRadius: 999,
                  onTap: () => _switchToRelatedSeason(opt),
                  child: AnimatedContainer(
                    duration: Ios27ConcentricGeometry.isReduceMotion(ctx)
                        ? Ios27ConcentricGeometry.reducedMotionDuration
                        : Ios27Spring.snappy.nominalDuration,
                    curve: Ios27Spring.snappy.curve,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color:
                          isSelected ? Colors.white : const Color(0x24FFFFFF),
                      borderRadius: BorderRadius.circular(999),
                      border: isSelected
                          ? null
                          : Border.all(
                              color: const Color(0x30FFFFFF),
                              width: 0.5,
                            ),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      opt.seasonLabel,
                      style: TextStyle(
                        color: isSelected
                            ? const Color(0xFF121215)
                            : const Color(0xE6FFFFFF),
                        fontSize: 12.5,
                        fontWeight:
                            isSelected ? FontWeight.w800 : FontWeight.w600,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ],
        if (_lineUnavailableReason(line) case final lineReason?) ...[
          const SizedBox(height: 10),
          Container(
            key: const ValueKey('detail-line-unavailable-banner'),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0x26FF9F0A),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0x4DFF9F0A), width: 0.6),
            ),
            child: Text(
              lineReason,
              style: const TextStyle(
                color: Color(0xFFFFD60A),
                fontSize: 12.5,
                height: 1.35,
              ),
            ),
          ),
        ],
        const SizedBox(height: 12),

        // 2. Quick Episode Number Strip (12 13 14 [15] 16 17 ...)
        SizedBox(
          height: 30,
          child: DesktopHorizontalScroller(
            controller: _quickEpisodesScrollController,
            child: ListView.separated(
              controller: _quickEpisodesScrollController,
              scrollDirection: Axis.horizontal,
              itemCount: end - start,
              separatorBuilder: (_, __) => const SizedBox(width: 7),
              itemBuilder: (ctx, idx) {
              final visualIdx = start + idx;
              final posIdx = _descending ? (total - 1 - visualIdx) : visualIdx;
              final originalIdx = activeIndices[posIdx];
              final unavailReason =
                  _episodeUnavailableReason(line.episodes[originalIdx]);
              final isUnavailable = unavailReason != null;
              final isCurrent = !isUnavailable && originalIdx == currentActiveEpIdx;
              final pill = Ios27Pressable(
                pressedScale: Ios27Spring.pressSwellScale,
                borderRadius: 999,
                onTap: () => _openPlayer(safeLineIdx, originalIdx),
                child: AnimatedContainer(
                  duration: Ios27ConcentricGeometry.isReduceMotion(ctx)
                      ? Ios27ConcentricGeometry.reducedMotionDuration
                      : Ios27Spring.snappy.nominalDuration,
                  curve: Ios27Spring.snappy.curve,
                  constraints: const BoxConstraints(minWidth: 34),
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  decoration: BoxDecoration(
                    color: isCurrent
                        ? Colors.white
                        : const Color(0x24FFFFFF),
                    borderRadius: BorderRadius.circular(999),
                    border: isCurrent
                        ? null
                        : Border.all(
                            color: const Color(0x28FFFFFF),
                            width: 0.5,
                          ),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    '${posIdx + 1}',
                    style: TextStyle(
                      color: isCurrent
                          ? const Color(0xFF121215)
                          : const Color(0xD9FFFFFF),
                      fontSize: 12.5,
                      fontWeight:
                          isCurrent ? FontWeight.w800 : FontWeight.w600,
                    ),
                  ),
                ),
              );
              return isUnavailable ? Opacity(opacity: 0.45, child: pill) : pill;
            },
          ),
        ),
      ),
      const SizedBox(height: 14),

        // 3. Horizontal 16:9 Landscape Episode Preview Cards with Authentic Scene Stills
        //    and Authentic Per-Episode Plot Synopsis
        SizedBox(
          height: anyHasSummary ? 222 : 186,
          child: DesktopHorizontalScroller(
            controller: _previewCardsScrollController,
            child: ListView.separated(
              controller: _previewCardsScrollController,
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              itemCount: end - start,
              separatorBuilder: (_, __) => const SizedBox(width: 14),
              itemBuilder: (ctx, idx) {
              final visualIdx = start + idx;
              final posIdx = _descending ? (total - 1 - visualIdx) : visualIdx;
              final originalIdx = activeIndices[posIdx];
              final ep = line.episodes[originalIdx];
              final epScrape =
                  _scrapeResultForLine(line).byOriginalIndex[originalIdx];
              final realEpNum = epScrape.resolvedEpisodeNumber ?? (posIdx + 1);
              final unavailReason = _episodeUnavailableReason(ep);
              final isUnavailable = unavailReason != null;
              final isCurrent = !isUnavailable && originalIdx == currentActiveEpIdx;
              final (cleanTitle, parsedBadge) =
                  _parseEpisodeDisplay(ep.name, realEpNum);
              final specBadge = isUnavailable ? '不可解析' : parsedBadge;
              final unitLabel = epScrape.isSpecial
                  ? epScrape.displayLabel
                  : (_isVarietyShow ? '第$realEpNum期' : '第$realEpNum集');
              final subMeta = isUnavailable
                  ? unavailReason
                  : [
                      if (_effectiveLookupYear.trim().isNotEmpty)
                        _effectiveLookupYear.trim(),
                      unitLabel,
                      if (specBadge != null) specBadge,
                    ].join(' · ');
              final headline =
                  _formatEpisodeCardHeadline(cleanTitle, realEpNum);
              final epDesc = _resolveAuthenticEpisodeSummary(
                realEpNum,
                cleanTitle,
              );

              final card = GestureDetector(
                key: ValueKey('ep_card_${safeLineIdx}_$originalIdx'),
                onTap: () => _openPlayer(safeLineIdx, originalIdx),
                child: SizedBox(
                  width: 226,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(14),
                          boxShadow: const [
                            BoxShadow(
                              color: Color(0x4D000000),
                              blurRadius: 12,
                              offset: Offset(0, 5),
                            ),
                          ],
                        ),
                        child: SizedBox(
                          height: 126,
                          width: 226,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(14),
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                EpisodeStillImage(
                                  seriesTitle: _effectiveLookupTitle,
                                  year: _effectiveLookupYear,
                                  episodeIndex: posIdx,
                                  realEpisodeNumber: realEpNum,
                                  wantMotionComic: _effectiveWantMotionComic,
                                  fallbackPosterUrl: _effectivePosterUrl,
                                  placeholder: _posterPlaceholder(
                                    _resolveBaseAmbientColor(),
                                  ),
                                ),
                                const DecoratedBox(
                                  decoration: BoxDecoration(
                                    gradient: LinearGradient(
                                      begin: Alignment.topCenter,
                                      end: Alignment.bottomCenter,
                                      colors: [
                                        Color(0x14000000),
                                        Color(0x84000000),
                                      ],
                                    ),
                                  ),
                                ),
                                if (specBadge != null)
                                  Positioned(
                                    top: 8,
                                    right: 8,
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 7,
                                        vertical: 2,
                                      ),
                                      decoration: BoxDecoration(
                                        color: const Color(0xB3121215),
                                        borderRadius: BorderRadius.circular(6),
                                        border: Border.all(
                                          color: const Color(0x40FFFFFF),
                                          width: 0.5,
                                        ),
                                      ),
                                      child: Text(
                                        specBadge,
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 10,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ),
                                  ),
                                Positioned(
                                  left: 9,
                                  bottom: 8,
                                  right: 9,
                                  child: Row(
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 7,
                                          vertical: 2.5,
                                        ),
                                        decoration: BoxDecoration(
                                          color: isCurrent
                                              ? Colors.white
                                              : const Color(0xA6121215),
                                          borderRadius:
                                              BorderRadius.circular(6),
                                        ),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(
                                              CupertinoIcons.play_fill,
                                              size: 10,
                                              color: isCurrent
                                                  ? const Color(0xFF121215)
                                                  : Colors.white,
                                            ),
                                            const SizedBox(width: 3),
                                            Text(
                                              'E${(posIdx + 1).toString().padLeft(2, '0')}',
                                              style: TextStyle(
                                                color: isCurrent
                                                    ? const Color(0xFF121215)
                                                    : Colors.white,
                                                fontSize: 10.5,
                                                fontWeight: FontWeight.w800,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      const Spacer(),
                                      Flexible(
                                        child: Text(
                                          line.name,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            color: Color(0xD9FFFFFF),
                                            fontSize: 10.5,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                // Foreground rounded border overlay (never shrinks or insets the image)
                                Positioned.fill(
                                  child: IgnorePointer(
                                    child: DecoratedBox(
                                      decoration: BoxDecoration(
                                        borderRadius: BorderRadius.circular(14),
                                        border: Border.all(
                                          color: isCurrent
                                              ? Colors.white
                                              : const Color(0x33FFFFFF),
                                          width: isCurrent ? 2.0 : 0.7,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        subMeta,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Color(0x99FFFFFF),
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        headline,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.2,
                        ),
                      ),
                      if (epDesc.isNotEmpty) ...[
                        const SizedBox(height: 3),
                        Text(
                          epDesc,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Color(0xB3FFFFFF),
                            fontSize: 11.5,
                            height: 1.34,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              );
              return isUnavailable ? Opacity(opacity: 0.48, child: card) : card;
            },
          ),
        ),
      ),

        // 4. Range Capsules (1 · 50, 51 · 100 ...)
        if (pageCount > 1) ...[
          const SizedBox(height: 12),
          SizedBox(
            height: 34,
            child: DesktopHorizontalScroller(
              controller: _pageRangeScrollController,
              child: ListView.separated(
                controller: _pageRangeScrollController,
                scrollDirection: Axis.horizontal,
                itemCount: pageCount,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (ctx, p) {
                final pStart = p * CmsParser.episodePageSize + 1;
                final pEnd =
                    ((p + 1) * CmsParser.episodePageSize).clamp(1, total);
                final selected = p == safePage;
                return GestureDetector(
                  onTap: () => setState(() => _selectedPage = p),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 15,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: selected ? Colors.white : const Color(0x24FFFFFF),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      '$pStart · $pEnd',
                      style: TextStyle(
                        color: selected
                            ? const Color(0xFF121215)
                            : const Color(0xD9FFFFFF),
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ],
      ],
    );
  }

  /// Wide desktop / iPad / phone landscape immersive cinema showcase layout:
  /// - Full-screen `Positioned.fill` backdrop (zero internal 66%-width vertical edge
  ///   or `heroStageHeight` horizontal edge!)
  /// - Left-to-right and top-to-bottom solid-color gradients placed ON TOP OF the
  ///   blurred backdrop so the backdrop melts seamlessly into `bgColor`
  Widget _buildWideDesktopScreen(BuildContext context) {
    final targetBg = _resolveBaseAmbientColor();
    final bookmark = _findBookmark();
    final size = MediaQuery.sizeOf(context);
    final safePad = MediaQuery.paddingOf(context);
    final topPad = math.max(
      safePad.top,
      defaultTargetPlatform == TargetPlatform.macOS ? 28.0 : 0.0,
    );
    final horizontalPad = (size.width * 0.045).clamp(24.0, 56.0);
    final compactWideH = size.height < 520;
    final heroStageHeight = compactWideH
        ? (size.height * 0.68).clamp(290.0, 360.0)
        : (size.height * 0.58).clamp(380.0, 500.0);
    final posterCardW = compactWideH
        ? (heroStageHeight * 0.43).clamp(132.0, 176.0)
        : (heroStageHeight * 0.48).clamp(168.0, 224.0);

    return TweenAnimationBuilder<Color?>(
      tween: ColorTween(begin: targetBg, end: targetBg),
      duration: Ios27ConcentricGeometry.isReduceMotion(context)
          ? Ios27ConcentricGeometry.reducedMotionDuration
          : Ios27Spring.smooth.nominalDuration,
      curve: Ios27Spring.smooth.curve,
      builder: (context, animatedBg, _) {
        final bgColor = animatedBg ?? targetBg;
        return Scaffold(
          backgroundColor: bgColor,
          body: Stack(
            fit: StackFit.expand,
            children: [
              // 1. Unified Solid Ambient Canvas Matching Poster Edge Color
              ColoredBox(color: bgColor),

              // 2. Full-Screen Widescreen Backdrop (`Positioned.fill` eliminates both
              //    the vertical 34% line and the horizontal heroStageHeight line, while
              //    keeping right-side poster artwork clearly visible with low blur!)
              Positioned.fill(
                child: isWindowsDesktopUi
                    ? Stack(
                        fit: StackFit.expand,
                        children: [
                          RepaintBoundary(
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                ImageFiltered(
                                  imageFilter: ImageFilter.blur(
                                    sigmaX: 2.2,
                                    sigmaY: 2.2,
                                    tileMode: TileMode.decal,
                                  ),
                                  child: PosterImage(
                                    url: _video.poster,
                                    title: _publicLookupTitle,
                                    year: _video.year,
                                    fit: BoxFit.cover,
                                    alignment: const Alignment(0.35, -0.2),
                                    forBackdrop: true,
                                    onBytesLoaded: _updateAmbientFromBytes,
                                    placeholder: _posterPlaceholder(bgColor),
                                  ),
                                ),
                                DecoratedBox(
                                  decoration: BoxDecoration(
                                    gradient: LinearGradient(
                                      begin: Alignment.centerLeft,
                                      end: Alignment.centerRight,
                                      colors: [
                                        bgColor,
                                        bgColor.withValues(alpha: 0.94),
                                        bgColor.withValues(alpha: 0.46),
                                        bgColor.withValues(alpha: 0.14),
                                        bgColor.withValues(alpha: 0.05),
                                      ],
                                      stops: const [0.0, 0.24, 0.46, 0.72, 1.0],
                                    ),
                                  ),
                                ),
                                DecoratedBox(
                                  decoration: BoxDecoration(
                                    gradient: LinearGradient(
                                      begin: Alignment.topCenter,
                                      end: Alignment.bottomCenter,
                                      colors: [
                                        bgColor.withValues(alpha: 0.56),
                                        bgColor.withValues(alpha: 0.04),
                                        bgColor.withValues(alpha: 0.32),
                                        bgColor.withValues(alpha: 0.90),
                                        bgColor,
                                      ],
                                      stops: const [0.0, 0.18, 0.58, 0.80, 1.0],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          ValueListenableBuilder<double>(
                            valueListenable: _scrollOffset,
                            builder: (context, offset, _) {
                              final veil =
                                  (offset / 320.0).clamp(0.0, 1.0) * 0.52;
                              if (veil <= 0.01) return const SizedBox.shrink();
                              return ColoredBox(
                                color: bgColor.withValues(alpha: veil),
                              );
                            },
                          ),
                        ],
                      )
                    : ValueListenableBuilder<double>(
                        valueListenable: _scrollOffset,
                        builder: (context, offset, child) {
                          final progress = (offset / 320.0).clamp(0.0, 1.0);
                          final blurSigma = 1.6 + progress * 7.5;
                          final scrollVeilAlpha = progress * 0.36;

                          final backdropImage = ImageFiltered(
                            imageFilter: ImageFilter.blur(
                              sigmaX: blurSigma,
                              sigmaY: blurSigma,
                              tileMode: TileMode.decal,
                            ),
                            child: child!,
                          );

                          return Stack(
                            fit: StackFit.expand,
                            children: [
                              backdropImage,
                              DecoratedBox(
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: Alignment.centerLeft,
                                    end: Alignment.centerRight,
                                    colors: [
                                      bgColor,
                                      bgColor.withValues(alpha: 0.94),
                                      bgColor.withValues(alpha: 0.46),
                                      bgColor.withValues(alpha: 0.14),
                                      bgColor.withValues(alpha: 0.05),
                                    ],
                                    stops: const [0.0, 0.24, 0.46, 0.72, 1.0],
                                  ),
                                ),
                              ),
                              DecoratedBox(
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: Alignment.topCenter,
                                    end: Alignment.bottomCenter,
                                    colors: [
                                      bgColor.withValues(alpha: 0.56),
                                      bgColor.withValues(alpha: 0.04),
                                      bgColor.withValues(alpha: 0.32),
                                      bgColor.withValues(alpha: 0.90),
                                      bgColor,
                                    ],
                                    stops: const [0.0, 0.18, 0.58, 0.80, 1.0],
                                  ),
                                ),
                              ),
                              if (scrollVeilAlpha > 0.01)
                                Positioned.fill(
                                  child: ColoredBox(
                                    color: bgColor.withValues(
                                      alpha: scrollVeilAlpha,
                                    ),
                                  ),
                                ),
                            ],
                          );
                        },
                        child: PosterImage(
                          url: _video.poster,
                          title: _publicLookupTitle,
                          year: _video.year,
                          fit: BoxFit.cover,
                          alignment: const Alignment(0.35, -0.2),
                          forBackdrop: true,
                          onBytesLoaded: _updateAmbientFromBytes,
                          placeholder: _posterPlaceholder(bgColor),
                        ),
                      ),
              ),

              // 3. Main Scrollable Widescreen Foreground Content
              MediaQuery.removePadding(
                context: context,
                removeTop: true,
                child: NotificationListener<ScrollNotification>(
                  onNotification: (notification) {
                    if (notification.metrics.axis == Axis.vertical) {
                      final next =
                          notification.metrics.pixels.clamp(0.0, 500.0);
                      if ((_scrollOffset.value - next).abs() > 0.5) {
                        _scrollOffset.value = next;
                      }
                    }
                    return false;
                  },
                  child: SingleChildScrollView(
                    physics: const BouncingScrollPhysics(),
                    padding: const EdgeInsets.only(bottom: 44),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        ConstrainedBox(
                          constraints: BoxConstraints(
                            minHeight: heroStageHeight + topPad,
                          ),
                          child: Padding(
                            padding: EdgeInsets.fromLTRB(
                              horizontalPad + safePad.left,
                              topPad + 58,
                              horizontalPad + safePad.right,
                              18,
                            ),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                SizedBox(
                                  width: posterCardW,
                                  child: _buildPosterCard(bgColor),
                                ),
                                SizedBox(width: compactWideH ? 20 : 28),
                                Expanded(
                                  child: _buildWideHeroShowcaseColumn(bookmark),
                                ),
                              ],
                            ),
                          ),
                        ),
                        Padding(
                          padding:
                              EdgeInsets.symmetric(horizontal: horizontalPad),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              const SizedBox(height: 8),
                              CastAvatarSection(
                                title: _effectiveLookupTitle.isNotEmpty
                                    ? _effectiveLookupTitle
                                    : _video.title,
                                actorRaw: _video.actor,
                                year: _effectiveLookupYear,
                                doubanId: _effectiveDoubanId,
                                wantMotionComic: _effectiveWantMotionComic,
                                allowExternalLookup:
                                    !_activeSite.isEffectivelyPrivate,
                                forceDark: true,
                                padding: EdgeInsets.zero,
                              ),
                              const SizedBox(height: 18),
                              if (!_loading && _video.sourceWarnings.isNotEmpty)
                                _buildSourceWarningsSection(),
                              if (!_loading &&
                                  _activeSite.playbackHint.isNotEmpty &&
                                  _configuredParses.isEmpty)
                                _buildPlaybackHintBanner(),
                              if (_loading)
                                const Padding(
                                  padding: EdgeInsets.symmetric(vertical: 32),
                                  child: Center(
                                    child:
                                        CupertinoActivityIndicator(radius: 14),
                                  ),
                                )
                              else if (_curatedUnavailableMessage != null)
                                _buildCuratedUnavailableCard()
                              else if (_error != null)
                                _buildDetailError()
                              else if (_video.lines.isEmpty)
                                const Padding(
                                  padding: EdgeInsets.symmetric(vertical: 20),
                                  child: Text(
                                    '当前片源未提供可播放剧集，请重试或手动切换片源',
                                    style: TextStyle(
                                      color: AppleColors.labelSecondary,
                                      fontSize: 14,
                                    ),
                                  ),
                                )
                              else
                                _buildPortraitEpisodesSection(bookmark),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),

              // 4. Floating Liquid Glass Top Navigation Bar (Back on Left, Source Picker + Download/Favorite on Right)
              Positioned(
                top: topPad + 10,
                left: horizontalPad + safePad.left,
                right: horizontalPad + safePad.right,
                child: Row(
                  children: [
                    _buildFloatingGlassCircleButton(
                      icon: CupertinoIcons.chevron_back,
                      onTap: () => Navigator.of(context).maybePop(),
                    ),
                    const Spacer(),
                    _buildFloatingSourceButton(),
                    const SizedBox(width: 10),
                    _buildFloatingTopRightPill(),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildPosterCard(Color bgColor) {
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        boxShadow: const [
          BoxShadow(
            color: Color(0x80000000),
            blurRadius: 28,
            offset: Offset(0, 12),
          ),
        ],
      ),
      child: ClipRRect(
        key: _transitionPosterKey,
        borderRadius: BorderRadius.circular(18),
        child: AspectRatio(
          aspectRatio: 2 / 3,
          child: Stack(
            fit: StackFit.expand,
            children: [
              PosterImage(
                url: _video.poster,
                title: _publicLookupTitle,
                year: _video.year,
                highRes: true,
                strictHighRes: true,
                onBytesLoaded: _onPosterCardBytesLoaded,
                placeholder: _posterPlaceholder(bgColor),
              ),
              Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(
                        color: const Color(0x4DFFFFFF),
                        width: 0.8,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _posterPlaceholder(Color bgColor) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Color.lerp(bgColor, const Color(0xFF283448), 0.35)!,
            bgColor,
          ],
        ),
      ),
      alignment: Alignment.center,
      child: const Icon(
        CupertinoIcons.film,
        color: AppleColors.labelTertiary,
        size: 38,
      ),
    );
  }

  Widget _buildWideHeroShowcaseColumn(WatchHistoryEntry? bookmark) {
    final safeLineIdx = _video.lines.isEmpty
        ? 0
        : _selectedLine.clamp(0, _video.lines.length - 1);
    final epCount = _video.lines.isEmpty
        ? 0
        : _video.lines[safeLineIdx].episodes.length;
    final pills = <String>[
      if (_video.year.trim().isNotEmpty) _video.year.trim(),
      if (_video.area.trim().isNotEmpty) _video.area.trim(),
      if (_video.tag.trim().isNotEmpty) _video.tag.trim(),
      if (_video.remarks.trim().isNotEmpty)
        _video.remarks.trim()
      else if (epCount > 1)
        '共$epCount集',
    ];
    final desc = _effectiveSeriesSynopsis();
    final cast = _video.actor.trim();

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _video.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 32,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.6,
            height: 1.15,
            shadows: [
              Shadow(
                color: Color(0xB3000000),
                blurRadius: 18,
                offset: Offset(0, 4),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (final tag in pills.take(4))
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 11,
                  vertical: 3.5,
                ),
                decoration: BoxDecoration(
                  color: const Color(0x33FFFFFF),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(
                    color: const Color(0x38FFFFFF),
                    width: 0.5,
                  ),
                ),
                child: Text(
                  tag,
                  style: const TextStyle(
                    color: Color(0xF2FFFFFF),
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 10),
        _buildRatingsAndSiteWrap(alignment: WrapAlignment.start),
        if (!OhosRuntime.isOhos) ...[
          Builder(
            builder: (_) {
              final activeLine = _video.lines.isEmpty
                  ? null
                  : _video
                      .lines[_selectedLine.clamp(0, _video.lines.length - 1)];
              final specBadges = _specBadgesForHero(activeLine);
              if (specBadges.isEmpty) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.only(top: 8),
                child: MediaBadgeRow(
                  badges: specBadges,
                  maxBadges: 5,
                  alignment: WrapAlignment.start,
                ),
              );
            },
          ),
        ],
        if (desc.isNotEmpty || cast.isNotEmpty) ...[
          const SizedBox(height: 12),
          GestureDetector(
            onTap: () => setState(() => _synopsisExpanded = !_synopsisExpanded),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 680),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (desc.isNotEmpty)
                    Text(
                      desc,
                      maxLines: _synopsisExpanded ? 8 : 3,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0xE0FFFFFF),
                        fontSize: 13.5,
                        height: 1.52,
                      ),
                    ),
                  if (cast.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      '演职员：$cast',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0xA6FFFFFF),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
        const SizedBox(height: 16),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: _buildPortraitActionRow(bookmark),
        ),
        if (bookmark != null) ...[
          const SizedBox(height: 10),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: _buildPortraitBookmarkProgress(bookmark),
          ),
        ],
      ],
    );
  }
}
