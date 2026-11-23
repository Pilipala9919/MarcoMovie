import 'dart:async';
import '../core/emby_library.dart';
import '../core/catpaw_host.dart';
import '../core/series_scraper.dart';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Real per-episode metadata resolved from open domestic encyclopedias & media APIs
/// (360 Baike `tvplot`, Bilibili PGC `media_bangumi`/`media_ft`, and Bangumi `/v0/episodes`).
class EpisodeRealMeta {
  final int episodeNumber; // 1-based episode number
  final String title; // Real episode title, e.g. "范闲制造假死瞒天过海"
  final String summary; // Real episode plot synopsis
  final String coverUrl; // Real 16:9 episode still URL

  const EpisodeRealMeta({
    required this.episodeNumber,
    this.title = '',
    this.summary = '',
    this.coverUrl = '',
  });

  EpisodeRealMeta mergeWith({
    String? title,
    String? summary,
    String? coverUrl,
  }) {
    return EpisodeRealMeta(
      episodeNumber: episodeNumber,
      title: (title != null && title.trim().isNotEmpty)
          ? title.trim()
          : this.title,
      summary: (summary != null && summary.trim().isNotEmpty)
          ? summary.trim()
          : this.summary,
      coverUrl: (coverUrl != null && coverUrl.trim().isNotEmpty)
          ? coverUrl.trim()
          : this.coverUrl,
    );
  }
}

/// Robust cross-platform HD poster & episode still loader (Windows / macOS / iOS / iPadOS).
///
/// Key resilience & HD quality mechanisms:
/// 1. Broadcasts `cacheRevision` & `metadataRevision` whenever any poster or
///    episode still lands in memory so visible cards in scrolling lists/grids
///    repaint immediately without requiring a tab/page switch.
/// 2. Verifies actual decoded pixel dimensions (`isTrueHdPoster`: width >= 580 &&
///    height >= 780) on hero posters so low-resolution CMS thumbnails are
///    always upgraded to true 1080p/2K vertical posters.
/// 3. Resolves true HD vertical posters across Bangumi (`api.bgm.tv` `images.large`),
///    Baidu Baike OpenAPI (`BaikeLemmaCardApi` raw `bcebos.com` poster),
///    Bilibili PGC (`api.bilibili.com`), Douban (`l_ratio_poster` with `bid` cookie),
///    and Bing original `murl` high-res sources.
/// 4. Resolves real per-episode synopses (`分集剧情`), episode titles, and 16:9
///    episode frame covers via 360 Baike `tvplot`, Bilibili PGC `eps`, Bangumi
///    `/v0/episodes`, and Bing widescreen scene stills.
/// A bounded Least-Recently-Used (LRU) [Map] implementation.
///
/// When the map reaches [capacity], inserting a new key evicts the
/// least-recently-used entry. Reading an existing key via [operator []]
/// refreshes its recency to Most Recently Used (MRU).
class LruMap<K, V> extends MapBase<K, V> {
  final int capacity;
  final LinkedHashMap<K, V> _map = LinkedHashMap<K, V>();

  LruMap([this.capacity = 500]) : assert(capacity > 0);

  @override
  V? operator [](Object? key) {
    if (key == null) return null;
    if (!_map.containsKey(key)) return null;
    final value = _map.remove(key);
    _map[key as K] = value as V;
    return value;
  }

  @override
  void operator []=(K key, V value) {
    _map.remove(key);
    while (_map.length >= capacity) {
      _map.remove(_map.keys.first);
    }
    _map[key] = value;
  }

  @override
  void clear() => _map.clear();

  @override
  Iterable<K> get keys => _map.keys;

  @override
  V? remove(Object? key) => _map.remove(key);

  @override
  int get length => _map.length;

  @override
  bool containsKey(Object? key) => _map.containsKey(key);
}

class PosterLoader {
  PosterLoader._();

  static const String _mobileSafariUa =
      'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1';
  static const String _desktopSafariUa =
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15';
  static const String _desktopChromeUa =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';
  static const String _tvBoxUa = 'okhttp/3.15';
  static const String _biliCookie =
      'buvid3=58D32EBE-894C-69EE-AE53-607BE1EC3CC597728infoc; b_nut=1793900397';
  static const int _maxImageBytes = 15 * 1024 * 1024;
  static const int _maxMemoryBytes = 112 * 1024 * 1024;
  static const int _maxConcurrent = 32;

  static final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(milliseconds: 3200)
    ..idleTimeout = const Duration(seconds: 25)
    ..maxConnectionsPerHost = 18
    ..userAgent = null
    ..autoUncompress = true;

  /// Increments whenever any poster image bytes are written into [_memory].
  /// Active [PosterImage] widgets listen to this notifier so scrolling lists
  /// refresh immediately in place.
  static final ValueNotifier<int> cacheRevision = ValueNotifier<int>(0);

  /// Increments whenever series synopses, episode plots, or episode stills finish
  /// loading into memory.
  static final ValueNotifier<int> metadataRevision = ValueNotifier<int>(0);

  static final LinkedHashMap<String, Uint8List> _memory =
      LinkedHashMap<String, Uint8List>();
  static int _memoryBytes = 0;
  static final Map<String, Set<VoidCallback>> _keyListeners = {};
  static final Map<String, String> _cleanTitleMemo = {};
  static final Map<String, Future<Uint8List>> _inflight = {};
  static final Map<String, Future<Uint8List>> _inflightTitleBytes = {};
  static final Map<String, Future<Uint8List>> _inflightHdTitleBytes = {};
  static final Map<String, Future<Uint8List>> _inflightLandscapeTitleBytes = {};
  static final Map<String, List<String>> _titleCoverUrlsCache = LruMap(500);
  static final Map<String, List<String>> _landscapeCoverUrlsCache = LruMap(500);
  static final Map<String, List<String>> _verifiedTitleCoverUrlsCache = LruMap(500);
  static final Map<String, String> _titleSynopsisCache = LruMap(500);
  static final Map<String, List<String>> _seriesEpisodeStillsCache = LruMap(500);
  static final Map<String, List<String>> _seriesEpisodeCaptionsCache = LruMap(500);
  static final Map<String, Map<int, EpisodeRealMeta>> _seriesEpisodeMetaCache =
      LruMap(500);
  static final Map<String, Future<List<String>>> _inflightSeriesStills = {};
  static final Map<String, Future<Map<int, EpisodeRealMeta>>>
      _inflightEpisodeMeta = {};
  static final LinkedHashMap<String, ({double? douban, int? rt})>
      _ratingsCache = LinkedHashMap<String, ({double? douban, int? rt})>();
  static final Map<String, Future<({double? douban, int? rt})>>
      _inflightRatings = {};
  static final Map<String, ({String id, bool isTv})> _doubanSubjectIdCache =
      LruMap(500);
  static final Map<int, Color> _ambientColorCache = LruMap(500);
  static final Map<int, Color> _vibrantAmbientColorCache = LruMap(500);
  static final Map<int, bool> _hdDimensionCache = LruMap(500);
  static final Map<int, bool> _heroHdDimensionCache = LruMap(500);
  static final Map<int, bool> _landscapeDimensionCache = LruMap(500);
  static final Map<int, bool> _clearDimensionCache = LruMap(500);
  static int _active = 0;
  static final Queue<Completer<void>> _waiters = Queue<Completer<void>>();
  static Directory? _diskDir;
  static bool _diskReady = false;
  static bool _legacyDiskCleaned = false;
  static final math.Random _rng = math.Random();

  static void addKeyListener(String key, VoidCallback listener) {
    if (key.isEmpty) return;
    (_keyListeners[key] ??= <VoidCallback>{}).add(listener);
  }

  static void removeKeyListener(String key, VoidCallback listener) {
    if (key.isEmpty) return;
    final set = _keyListeners[key];
    if (set == null) return;
    set.remove(listener);
    if (set.isEmpty) {
      _keyListeners.remove(key);
    }
  }

  static String _randomDoubanBid() {
    const chars =
        'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    final sb = StringBuffer();
    for (int i = 0; i < 11; i++) {
      sb.write(chars[_rng.nextInt(chars.length)]);
    }
    return sb.toString();
  }

  /// Human-readable summary of in-memory poster cache usage for Settings UI.
  static String get memoryCacheSizeLabel {
    final mb = _memoryBytes / (1024 * 1024);
    if (_memory.isEmpty) return '0.0 MB (0 张)';
    return '${mb.toStringAsFixed(1)} MB (${_memory.length} 张)';
  }

  /// Clears both in-memory LRU cache and on-disk temporary poster files.
  static Future<void> clearCache() async {
    _memory.clear();
    _memoryBytes = 0;
    _cleanTitleMemo.clear();
    _titleCoverUrlsCache.clear();
    _landscapeCoverUrlsCache.clear();
    _verifiedTitleCoverUrlsCache.clear();
    _titleSynopsisCache.clear();
    _seriesEpisodeStillsCache.clear();
    _seriesEpisodeCaptionsCache.clear();
    _seriesEpisodeMetaCache.clear();
    _ratingsCache.clear();
    _inflightRatings.clear();
    _doubanSubjectIdCache.clear();
    _ambientColorCache.clear();
    _vibrantAmbientColorCache.clear();
    _hdDimensionCache.clear();
    _heroHdDimensionCache.clear();
    _landscapeDimensionCache.clear();
    _clearDimensionCache.clear();
    cacheRevision.value++;
    metadataRevision.value++;
    for (final folder in const [
      'marco_poster_cache_v6',
      'marco_poster_cache_v5',
      'marco_poster_cache_v4',
    ]) {
      try {
        final dir = Directory(
          '${Directory.systemTemp.path}${Platform.pathSeparator}$folder',
        );
        if (await dir.exists()) {
          await for (final entity in dir.list()) {
            if (entity is File) {
              try {
                await entity.delete();
              } catch (_) {}
            }
          }
        }
      } catch (_) {}
    }
  }

  /// Upgrades known thumbnail poster URLs to their 1080p HD counterparts.
  static String upgradeUrlToHd(String rawUrl) {
    var u = rawUrl.trim();
    if (u.isEmpty) return '';
    if (u.startsWith('//')) u = 'https:$u';
    if (u.startsWith('http://lain.bgm.tv/')) {
      u = u.replaceFirst('http://', 'https://');
    }
    if (u.contains('lain.bgm.tv/pic/cover/')) {
      u = u.replaceFirst(
        RegExp(r'/pic/cover/[csgm]/'),
        '/pic/cover/l/',
      );
    } else if (u.contains('doubanio.com')) {
      if (u.contains('qnmob3-sign.doubanio.com') &&
          u.contains('/view/photo/large/public/')) {
        final m =
            RegExp(r'/view/photo/large/public/(p\d+\.[a-z]+)').firstMatch(u);
        if (m != null) {
          u = 'https://img3.doubanio.com/view/photo/l_ratio_poster/public/${m.group(1)}';
        }
      }
      u = u
          .replaceFirst('img9.doubanio.com', 'img3.doubanio.com')
          .replaceFirst('/s_ratio_poster/', '/l_ratio_poster/')
          .replaceFirst('/m_ratio_poster/', '/l_ratio_poster/')
          .replaceFirst('/view/photo/spic/', '/view/photo/lpic/')
          .replaceFirst('/view/photo/mpic/', '/view/photo/lpic/')
          .replaceFirst('/view/photo/sqxs/', '/view/photo/l/')
          .replaceFirst('/view/photo/s/', '/view/photo/l/')
          .replaceFirst('/view/photo/m/', '/view/photo/l/')
          .replaceFirst('/view/subject/s/', '/view/subject/l/')
          .replaceFirst('/view/subject/m/', '/view/subject/l/');
      if (u.endsWith('.webp')) {
        u = '${u.substring(0, u.length - 5)}.jpg';
      }
    } else if (u.contains('hdslb.com') || u.contains('biliimg.com')) {
      if (u.startsWith('http://')) {
        u = u.replaceFirst('http://', 'https://');
      }
      final atResize = RegExp(
        r'@(?:\d+[wh]|[^/?#]+\.(?:webp|jpg|jpeg|png|avif)).*$',
        caseSensitive: false,
      ).firstMatch(u);
      if (atResize != null) {
        u = u.substring(0, atResize.start);
      }
    } else if (u.contains('bkimg.cdn.bcebos.com/pic/') ||
        (u.contains('bcebos.com') && u.contains('x-bce-process='))) {
      final qIdx = u.indexOf('?');
      if (qIdx > 0) {
        u = u.substring(0, qIdx);
      }
    } else {
      // Strip unsigned OSS / COS / Qiniu thumbnail resize directives so CMS
      // CDNs return the original full-resolution poster image.
      final qIdx = u.indexOf('?');
      if (qIdx > 0) {
        final query = u.substring(qIdx + 1);
        final lowerQ = query.toLowerCase();
        final isResizeOnly = (lowerQ.contains('x-oss-process=image/resize') ||
                lowerQ.startsWith('imageview2/') ||
                lowerQ.startsWith('imagemogr2/')) &&
            !lowerQ.contains('signature') &&
            !lowerQ.contains('sign=') &&
            !lowerQ.contains('token=') &&
            !lowerQ.contains('expires=') &&
            !lowerQ.contains('ossaccesskeyid=');
        if (isResizeOnly) {
          u = u.substring(0, qIdx);
        }
      }
    }
    return u;
  }

  static String cleanTitleForQuery(String rawTitle) => _cleanTitle(rawTitle);

  static String _cleanTitle(String rawTitle) {
    final cached = _cleanTitleMemo[rawTitle];
    if (cached != null) return cached;
    final cleaned = rawTitle
        .replaceAll(RegExp(r'[\(（\[【].*?[\)）\]】]'), '')
        .replaceAll(
          RegExp(
            r'[\s·\-—:：]*(?:更新至|更至|更新到|连载至|全\s*\d+\s*[集期话篇章]|共\s*\d+\s*[集期话篇章]|已完结|完结).*$',
          ),
          '',
        )
        .replaceAll(RegExp(r'第[0-9一二三四五六七八九十百零〇]+[季部集期篇章话]'), '')
        .replaceAll(
          RegExp(
            r'(?<![A-Za-z0-9])(?:4K|2160[pP]|1080[pP]|720[pP]|HD|BD|HDR|SDR|TC|TS)(?![A-Za-z0-9])',
            caseSensitive: false,
          ),
          '',
        )
        .replaceAll(
          RegExp(
            r'[\s·\-—:：]*(?:动态漫画|动态漫|漫动画|臻彩|杜比视界|杜比|高码|原盘|国粤双语|国语|粤语|中字|双语|超清|高清|蓝光|未删减版?|完整版?|抢先版?)\s*$',
          ),
          '',
        )
        .replaceAll(RegExp(r'(?:19|20)\d{2}\s*$'), '')
        .replaceAll(RegExp(r'[\s·\-—:：]+$'), '')
        .trim();
    if (_cleanTitleMemo.length > 1024) {
      _cleanTitleMemo.clear();
    }
    _cleanTitleMemo[rawTitle] = cleaned;
    return cleaned;
  }

  /// Rejects celebrity portraits, streamer avatars, character icons, and user
  /// avatars so a homonym person (e.g. Douban `type: "celebrity"` `/personage/`
  /// photo for《谷雨》) is never mistaken for a film or drama poster.
  @visibleForTesting
  static bool isPersonOrAvatarImageUrl(String rawUrl) {
    final lower = rawUrl.trim().toLowerCase();
    if (lower.isEmpty) return false;
    return lower.contains('/view/personage/') ||
        lower.contains('/personage/') ||
        lower.contains('/view/celebrity/') ||
        lower.contains('/celebrity/') ||
        lower.contains('/avatar/') ||
        lower.contains('/icon/u') ||
        lower.contains('lain.bgm.tv/pic/crt/') ||
        lower.contains('lain.bgm.tv/pic/user/') ||
        lower.contains('huya.com') ||
        lower.contains('douyucdn.cn');
  }

  static int? _extractTargetYear(String rawTitle, [String explicitYear = '']) {
    final mExplicit = RegExp(r'\b((?:19|20)\d{2})\b').firstMatch(explicitYear);
    if (mExplicit != null) {
      return int.tryParse(mExplicit.group(1)!);
    }
    final mTitle = RegExp(
      r'(?:[\(（\[【\s])((?:19|20)\d{2})(?:[\)）\]】]|\s*$)|((?:19|20)\d{2})\s*$',
    ).firstMatch(rawTitle);
    if (mTitle != null) {
      return int.tryParse(mTitle.group(1) ?? mTitle.group(2) ?? '');
    }
    return null;
  }

  static String _scopedTitleToken(
    String cleanTitle,
    int? targetYear, {
    bool isMotionComic = false,
  }) {
    if (cleanTitle.isEmpty) return '';
    final base = targetYear != null ? '$cleanTitle@$targetYear' : cleanTitle;
    return isMotionComic ? '$base#mc' : base;
  }

  static bool _isMotionComicTitle(String rawTitle, {String extraContext = ''}) =>
      SeriesScraper.isMotionComicText(rawTitle, extraContext: extraContext);

  static int? _extractSeasonNumber(String rawTitle) {
    final cnMap = <String, int>{
      '一': 1,
      '二': 2,
      '三': 3,
      '四': 4,
      '五': 5,
      '六': 6,
      '七': 7,
      '八': 8,
      '九': 9,
      '十': 10,
    };
    final mCn =
        RegExp(r'第\s*([0-9一二三四五六七八九十]+)\s*[季部]').firstMatch(rawTitle);
    if (mCn != null) {
      final token = mCn.group(1)!;
      final asInt = int.tryParse(token);
      if (asInt != null) return asInt;
      if (cnMap.containsKey(token)) return cnMap[token];
    }
    final mEn =
        RegExp(r'\bSeason\s*(\d+)\b', caseSensitive: false).firstMatch(rawTitle);
    if (mEn != null) {
      return int.tryParse(mEn.group(1)!);
    }
    return null;
  }

  /// Strict work-title matcher so external encyclopedias (360 Baike, Baidu Baike,
  /// Bilibili PGC, Bangumi, Douban) never attach an unrelated drama/anime or mix
  /// dynamic comics (`动态漫画`) with regular anime (`动漫` / `3D年番`).
  @visibleForTesting
  static bool isSameWorkTitle(
    String candidateRaw,
    String targetRaw, {
    bool? wantMotionComic,
    String candidateContext = '',
  }) =>
      _isSameWorkTitle(
        candidateRaw,
        targetRaw,
        wantMotionComic: wantMotionComic,
        candidateContext: candidateContext,
      );

  static bool _isSameWorkTitle(
    String candidateRaw,
    String targetRaw, {
    bool? wantMotionComic,
    String candidateContext = '',
  }) {
    final candNoHtml = candidateRaw
        .replaceAll(RegExp(r'<[^>]+>'), '')
        .replaceAll(RegExp(r'_360百科.*$|-360百科.*$|_百度百科.*$'), '')
        .trim();
    if (candNoHtml.isEmpty || targetRaw.trim().isEmpty) return false;

    final targetMc = wantMotionComic ?? _isMotionComicTitle(targetRaw);
    if (!SeriesScraper.isCompatibleWorkForm(
      targetIsMotionComic: targetMc,
      candidateTitle: candNoHtml,
      candidateContext: candidateContext,
    )) {
      return false;
    }

    final candSeason = _extractSeasonNumber(candNoHtml);
    final targetSeason = _extractSeasonNumber(targetRaw);
    if (candSeason != null &&
        targetSeason != null &&
        candSeason != targetSeason) {
      return false;
    }

    final cNorm = SeriesScraper.normalizeWorkCoreTitle(candNoHtml);
    final tNorm = SeriesScraper.normalizeWorkCoreTitle(targetRaw);
    if (cNorm.isEmpty || tNorm.isEmpty) return false;
    if (cNorm == tNorm) return true;

    if (tNorm.length >= 4 && (cNorm.startsWith(tNorm) || tNorm.startsWith(cNorm))) {
      final shorter = cNorm.length < tNorm.length ? cNorm.length : tNorm.length;
      final longer = cNorm.length > tNorm.length ? cNorm.length : tNorm.length;
      if (shorter / longer >= 0.72) return true;
    }

    // Allow matching a distinct subtitle variant (>= 4 chars, e.g. `绝世唐门`
    // for `斗罗大陆2：绝世唐门`), while never letting a bare franchise root
    // (`斗罗大陆`) hijack a numbered sequel (`斗罗大陆2：绝世唐门`).
    final cleanTarget = _cleanTitle(targetRaw);
    final subParts = cleanTarget
        .split(
          RegExp(
            r'[：:·—\-\s]+|(?<=[\u4e00-\u9fa5])(?:[0-9]+|[IⅠⅡⅢⅣⅤVⅤXⅩ]{1,4})[：:·—\-\s]*(?=[\u4e00-\u9fa5])',
          ),
        )
        .map((s) => SeriesScraper.normalizeWorkCoreTitle(s))
        .where((s) => s.length >= 4)
        .toList();
    if (subParts.length >= 2) {
      final subtitle = subParts.last;
      if (cNorm == subtitle) return true;
    }
    return false;
  }

  /// Verifies that an encyclopedia description/abstract actually describes a
  /// film, TV drama, anime, variety show, or documentary — rejecting homonym
  /// entries such as actors/streamers/directors (`演员/主播/主持人`), the 24 Solar
  /// Terms (`二十四节气·谷雨/惊蛰/清明/白露/立春`), novels, idioms, plants,
  /// dynamic-comic vs regular-anime mismatches, or mismatched-era homonym films
  /// when [targetYear] is known.
  @visibleForTesting
  static bool isFilmOrTvEncyclopediaEntry({
    required String abstractText,
    String descText = '',
    int? targetYear,
    bool wantMotionComic = false,
  }) {
    final abs = abstractText.trim();
    final desc = descText.trim();
    final combined = '$abs $desc'.trim();
    if (combined.isEmpty) return false;

    // 0. Enforce motion-comic (`动态漫画`) vs regular anime/drama separation.
    final entryIsMotionComic = SeriesScraper.isMotionComicText(
      desc,
      extraContext: abs,
    );
    if (entryIsMotionComic != wantMotionComic) {
      return false;
    }

    // 1. Reject person biographies (actors, singers, streamers, hosts, directors)
    final descHasWorkType = RegExp(
      r'电视剧|剧集|网剧|网络剧|短剧|连续剧|电影|影片|故事片|纪录片|动画|动漫|番剧|综艺|真人秀|动态漫',
    ).hasMatch(desc);
    if (!descHasWorkType &&
        RegExp(
          r'演员|歌手|主持人|主播|解说|电竞|选手|导演|编剧|制片人|作家|诗人|画家|摄影师|配音|运动员|企业家|学者|教授|人物',
        ).hasMatch(desc)) {
      return false;
    }
    final head = abs.length > 56 ? abs.substring(0, 56) : abs;
    final headLooksLikeWork = head.contains('《') ||
        RegExp(
          r'是由|是一部|是一档|是.*(?:电视剧|剧集|网剧|短剧|连续剧|电影|影片|纪录片|动画|番剧|综艺|动态漫)',
        ).hasMatch(head);
    if (!headLooksLikeWork &&
        RegExp(
          r'出生于|生于|毕业于|籍贯|中国(?:内地|大陆|香港|台湾)?(?:男|女)?(?:影视)?(?:演员|歌手|导演|主持人|编剧|音乐人|配音|主播)|(?:，|,)\s*(?:男|女)\s*(?:，|,)',
        ).hasMatch(head)) {
      return false;
    }

    // 2. Reject solar terms, novels, idioms, plants, and geography definitions
    if (RegExp(
      r'二十四节气|太阳到达黄经|节气之一|春季的最后一个节气|雨生百谷|春茶|'
      r'所著的.*小说|连载于.*小说|网络小说|起点中文网|晋江文学城|'
      r'汉语词语|成语|唐代诗人|宋代词人|草本植物|中药材|行政区划|下辖',
    ).hasMatch(combined)) {
      return false;
    }

    // 3. Require explicit film/TV work terms
    final hasWorkTerms = RegExp(
      r'电视剧|剧集|网剧|网络剧|短剧|连续剧|电视连续剧|'
      r'电影|影片|院线|故事片|纪录片|'
      r'动画|动漫|番剧|电视动画|动画片|动态漫|'
      r'综艺|真人秀|节目|'
      r'执导|领衔主演|主演|出品|播出|首播|上映|定档|杀青',
    ).hasMatch(combined);
    if (!hasWorkTerms) return false;

    // 4. Verify release/production year compatibility when targetYear is known
    if (targetYear != null) {
      final prodYears = <int>[];
      // Leading/explicit year in `desc` (e.g. `2018年童千格制作的动画片`, `2026年中国内地电视剧`).
      for (final m in RegExp(r'((?:19|20)\d{2})年').allMatches(desc)) {
        final y = int.tryParse(m.group(1) ?? '');
        if (y != null) prodYears.add(y);
      }
      final prodYearMatches = RegExp(
        r'((?:19|20)\d{2})年(?:\d{1,2}月)?(?:\d{1,2}日)?[^\n，。；]{0,16}(?:上映|首播|播出|开播|定档|出品|开机|杀青|制作|发行)',
      ).allMatches(combined);
      for (final m in prodYearMatches) {
        final y = int.tryParse(m.group(1) ?? '');
        if (y != null) prodYears.add(y);
      }
      if (prodYears.isNotEmpty &&
          !prodYears.any((y) => y >= targetYear - 2 && y <= targetYear + 1)) {
        return false;
      }
    }
    return true;
  }

  static bool _isFilmOrTvEntryText(
    String text, {
    int? targetYear,
    bool wantMotionComic = false,
  }) =>
      isFilmOrTvEncyclopediaEntry(
        abstractText: text,
        targetYear: targetYear,
        wantMotionComic: wantMotionComic,
      );

  /// Extracts the highest-scoring verified Douban `{id, isTv}` from `subject_suggest`.
  @visibleForTesting
  static ({String id, bool isTv})? parseDoubanSuggestSubject(
    Object? decoded,
    String rawTitle, {
    String year = '',
    bool? wantMotionComic,
  }) {
    if (decoded is! List || decoded.isEmpty) return null;
    final cleanTitle = _cleanTitle(rawTitle);
    if (cleanTitle.isEmpty) return null;
    final targetYear = _extractTargetYear(rawTitle, year);
    final wantMc = wantMotionComic ?? _isMotionComicTitle(rawTitle);
    final candidates = <({String id, bool isTv, int score, int order})>[];
    var order = 0;
    for (final item in decoded) {
      if (item is! Map) continue;
      final itemType = (item['type'] ?? '').toString().trim().toLowerCase();
      if (itemType.isNotEmpty && itemType != 'movie' && itemType != 'tv') {
        continue;
      }
      final itemUrl = (item['url'] ?? '').toString().trim().toLowerCase();
      if (itemUrl.contains('/celebrity/') || itemUrl.contains('/personage/')) {
        continue;
      }
      var subjectId = (item['id'] ?? '').toString().trim();
      if (!RegExp(r'^\d+$').hasMatch(subjectId)) {
        final m = RegExp(r'/subject/(\d+)').firstMatch(itemUrl);
        subjectId = m?.group(1) ?? '';
      }
      if (subjectId.isEmpty) continue;
      final itemTitle = (item['title'] ?? '').toString().trim();
      final itemSubTitle = (item['sub_title'] ?? '').toString().trim();
      if (!_isSameWorkTitle(
            itemTitle,
            rawTitle,
            wantMotionComic: wantMc,
            candidateContext: itemSubTitle,
          ) &&
          !_isSameWorkTitle(
            itemSubTitle,
            rawTitle,
            wantMotionComic: wantMc,
            candidateContext: itemTitle,
          )) {
        continue;
      }
      final itemYear = int.tryParse((item['year'] ?? '').toString().trim());
      var score = 10;
      if (targetYear != null) {
        if (itemYear != null) {
          final diff = (itemYear - targetYear).abs();
          if (diff >= 2) continue;
          score = diff == 0 ? 100 : 50;
        } else {
          score = 5;
        }
      } else if (itemYear != null) {
        score = 20;
      }
      final episodeStr = (item['episode'] ?? '').toString().trim();
      candidates.add((
        id: subjectId,
        isTv: itemType == 'tv' || episodeStr.isNotEmpty,
        score: score,
        order: order++,
      ));
    }
    if (candidates.isEmpty) return null;
    candidates.sort((a, b) {
      final cmp = b.score.compareTo(a.score);
      return cmp != 0 ? cmp : a.order.compareTo(b.order);
    });
    return (id: candidates.first.id, isTv: candidates.first.isTv);
  }

  /// Extracts the highest-scoring verified Douban `{id, isTv, coverUrl}` from
  /// Douban Mobile Rexxar search payloads (`search/weixin` or `search/subjects`),
  /// strictly enforcing dynamic-comic vs regular-anime separation and year match.
  @visibleForTesting
  static ({String id, bool isTv, String coverUrl})? parseDoubanRexxarSubject(
    Object? decoded,
    String rawTitle, {
    String year = '',
    bool? wantMotionComic,
  }) {
    if (decoded is! Map) return null;
    final subj = decoded['subjects'];
    final items = (subj is Map ? subj['items'] : null) ?? decoded['items'];
    if (items is! List || items.isEmpty) return null;
    final cleanTitle = _cleanTitle(rawTitle);
    if (cleanTitle.isEmpty) return null;
    final targetYear = _extractTargetYear(rawTitle, year);
    final wantMc = wantMotionComic ?? _isMotionComicTitle(rawTitle);
    final targetCore = SeriesScraper.normalizeWorkCoreTitle(rawTitle);
    final scored =
        <({String id, bool isTv, String coverUrl, int score, int order})>[];
    var order = 0;

    for (final entry in items.whereType<Map>()) {
      final target = entry['target'] is Map
          ? Map<String, dynamic>.from(entry['target'] as Map)
          : Map<String, dynamic>.from(entry);
      final tType =
          (entry['target_type'] ?? target['type'] ?? '').toString().toLowerCase();
      if (tType.isNotEmpty && tType != 'movie' && tType != 'tv') continue;
      final sid = (target['id'] ?? '').toString().trim();
      final candTitle = (target['title'] ?? '').toString().trim();
      final cardSub = (target['card_subtitle'] ?? '').toString().trim();
      if (sid.isEmpty || candTitle.isEmpty) continue;
      if (!_isSameWorkTitle(
        candTitle,
        rawTitle,
        wantMotionComic: wantMc,
        candidateContext: cardSub,
      )) {
        continue;
      }
      final candYear = int.tryParse((target['year'] ?? '').toString().trim());
      var score = 10;
      if (targetYear != null) {
        if (candYear != null) {
          final diff = (candYear - targetYear).abs();
          if (diff >= 2) continue;
          score += diff == 0 ? 100 : 50;
        } else {
          score += 5;
        }
      } else if (candYear != null) {
        score += 20;
      }
      if (SeriesScraper.normalizeWorkCoreTitle(candTitle) == targetCore) {
        score += 30;
      }
      final pic = target['pic'];
      final rawCover = (target['cover_url'] ??
              (pic is Map ? (pic['large'] ?? pic['normal'] ?? '') : ''))
          .toString()
          .trim();
      final hdCover =
          rawCover.isNotEmpty && !isPersonOrAvatarImageUrl(rawCover)
              ? upgradeUrlToHd(rawCover)
              : '';
      scored.add((
        id: sid,
        isTv: tType == 'tv',
        coverUrl: hdCover,
        score: score,
        order: order++,
      ));
    }
    if (scored.isEmpty) return null;
    scored.sort((a, b) {
      final cmp = b.score.compareTo(a.score);
      return cmp != 0 ? cmp : a.order.compareTo(b.order);
    });
    final best = scored.first;
    return (id: best.id, isTv: best.isTv, coverUrl: best.coverUrl);
  }

  /// Extracts verified Rotten Tomatoes Tomatometer (`1..100`) from Bing search result blocks.
  @visibleForTesting
  static int? extractRtPercentFromBingHtml(
    String html,
    String rawTitle, {
    int? targetYear,
  }) {
    final cleanTitle = _cleanTitle(rawTitle);
    if (html.isEmpty || cleanTitle.isEmpty) return null;
    final lowerClean = cleanTitle.toLowerCase();
    final compactClean =
        lowerClean.replaceAll(RegExp(r'[\s·:：\-—_（）()《》]+'), '');
    final algoBlocks = RegExp(
      r'<li\s+class="b_algo"[\s\S]*?</li>',
      caseSensitive: false,
    ).allMatches(html);
    final rtPattern = RegExp(
      r'(?:烂番茄(?:新鲜度|指数|好评率|评分|口碑)?|Rotten\s*Tomatoes[^0-9%\n]{0,24}|Tomatometer[^0-9%\n]{0,20})\s*[:：为是达获]?\s*(\d{1,3})\s*%|(\d{1,3})\s*%\s*(?:的)?(?:烂番茄|新鲜度)',
      caseSensitive: false,
    );
    for (final m in algoBlocks) {
      final plain = m
          .group(0)!
          .replaceAll(RegExp(r'<[^>]*>'), ' ')
          .replaceAll('&nbsp;', ' ')
          .replaceAll('&quot;', '"')
          .replaceAll('&amp;', '&')
          .replaceAll('&#39;', "'")
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      final lowerPlain = plain.toLowerCase();
      final compactPlain =
          lowerPlain.replaceAll(RegExp(r'[\s·:：\-—_（）()《》]+'), '');
      if (!lowerPlain.contains(lowerClean) &&
          (compactClean.isEmpty || !compactPlain.contains(compactClean))) {
        continue;
      }
      if (targetYear != null) {
        final years = RegExp(r'\b((?:19|20)\d{2})\b')
            .allMatches(plain)
            .map((ym) => int.tryParse(ym.group(1) ?? ''))
            .whereType<int>()
            .toList();
        if (years.isNotEmpty &&
            !years.any((y) => (y - targetYear).abs() <= 2) &&
            years.any((y) => (y - targetYear).abs() >= 4)) {
          continue;
        }
      }
      final rtMatch = rtPattern.firstMatch(plain);
      if (rtMatch != null) {
        final pct = int.tryParse(rtMatch.group(1) ?? rtMatch.group(2) ?? '');
        if (pct != null && pct >= 1 && pct <= 100) {
          return pct;
        }
      }
    }
    return null;
  }

  /// Parses Douban `subject_suggest` JSON list, strictly rejecting `celebrity`
  /// / `personage` entries and mismatched release years while ranking exact-year
  /// matches first.
  @visibleForTesting
  static List<String> parseDoubanSuggestCoverUrls(
    Object? decoded,
    String rawTitle, {
    String year = '',
    bool? wantMotionComic,
  }) {
    if (decoded is! List || decoded.isEmpty) return const [];
    final cleanTitle = _cleanTitle(rawTitle);
    if (cleanTitle.isEmpty) return const [];
    final targetYear = _extractTargetYear(rawTitle, year);
    final wantMc = wantMotionComic ?? _isMotionComicTitle(rawTitle);
    final scored = <({String url, int score, int order})>[];
    int order = 0;

    for (final item in decoded) {
      if (item is! Map) continue;
      final itemType = (item['type'] ?? '').toString().trim().toLowerCase();
      if (itemType.isNotEmpty && itemType != 'movie' && itemType != 'tv') {
        continue;
      }
      final itemUrl = (item['url'] ?? '').toString().trim().toLowerCase();
      if (itemUrl.contains('/celebrity/') || itemUrl.contains('/personage/')) {
        continue;
      }
      final itemTitle = (item['title'] ?? '').toString().trim();
      final itemSubTitle = (item['sub_title'] ?? '').toString().trim();
      if (!_isSameWorkTitle(
            itemTitle,
            rawTitle,
            wantMotionComic: wantMc,
            candidateContext: itemSubTitle,
          ) &&
          !_isSameWorkTitle(
            itemSubTitle,
            rawTitle,
            wantMotionComic: wantMc,
            candidateContext: itemTitle,
          )) {
        continue;
      }
      final rawImg = (item['img'] ?? '').toString().trim();
      if (!rawImg.startsWith('http') || isPersonOrAvatarImageUrl(rawImg)) {
        continue;
      }
      final hdImg = upgradeUrlToHd(rawImg);
      if (!hdImg.startsWith('http') || isPersonOrAvatarImageUrl(hdImg)) {
        continue;
      }

      final itemYear = int.tryParse((item['year'] ?? '').toString().trim());
      int score = 10;
      if (targetYear != null) {
        if (itemYear != null) {
          final diff = (itemYear - targetYear).abs();
          if (diff >= 2) continue;
          score = diff == 0 ? 100 : 50;
        } else {
          score = 5;
        }
      } else if (itemYear != null) {
        score = 20;
      }
      scored.add((url: hdImg, score: score, order: order++));
    }

    if (scored.isEmpty) return const [];
    final hasYearVerified =
        targetYear != null && scored.any((c) => c.score >= 50);
    final filtered = hasYearVerified
        ? scored.where((c) => c.score >= 50).toList()
        : scored;
    filtered.sort((a, b) {
      final cmp = b.score.compareTo(a.score);
      return cmp != 0 ? cmp : a.order.compareTo(b.order);
    });
    final seen = <String>{};
    final out = <String>[];
    for (final entry in filtered) {
      if (seen.add(entry.url)) {
        out.add(entry.url);
      }
    }
    return out;
  }

  /// Filters out non-entertainment Bing image search results (solar-term posters,
  /// graphic design templates, stock material, wallpapers, streamer/person selfies,
  /// sports/politics/business/idiom news articles).
  static bool _isNonEntertainmentBingCaption(String text) {
    return RegExp(
      r'节气|二十四节气|雨生百谷|春山雨前|春茶|茗茶|茶叶|养生|诗词|古诗|'
      r'手抄报|模板|素材|设计|海报设计|展板|易拉宝|宣传画|公众号首图|'
      r'主播|解说|电竞|自拍|头像|个人资料|简历|'
      r'千图|昵图|包图|花瓣|站酷|红动中国|图怪兽|稿定设计|壁纸|插画|矢量|PPT|'
      r'国乒|男篮|女排|国足|世界杯|奥运会|CBA|NBA|主帅|新岗位|正式任命|版主|'
      r'政协委员|董事长|获刑|港股|汉语成语|成语大全|成语解释|换帅|论坛版主|'
      r'手游网|全集下载|游戏下载|端游|官方手游',
      caseSensitive: false,
    ).hasMatch(text);
  }

  /// Generates ordered search query variants from most specific to core title,
  /// e.g. `斗罗大陆2：绝世唐门2023` -> `['斗罗大陆2：绝世唐门', '斗罗大陆2绝世唐门', '绝世唐门', '斗罗大陆']`.
  static List<String> _queryVariantsForTitle(String rawTitle) {
    final clean = _cleanTitle(rawTitle);
    if (clean.isEmpty) return const [];
    final out = <String>[clean];
    final compact = clean
        .replaceAll(RegExp(r'[：:·—\-\s]+'), '')
        .trim();
    if (compact.isNotEmpty && !out.contains(compact)) {
      out.add(compact);
    }
    final normalizedSpace = clean
        .replaceAll(RegExp(r'[：:·—\-]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (normalizedSpace.isNotEmpty && !out.contains(normalizedSpace)) {
      out.add(normalizedSpace);
    }
    final parts = clean
        .split(
          RegExp(
            r'[：:·—\-\s]+|(?<=[\u4e00-\u9fa5])(?:[0-9]+|[IⅠVⅤXⅩ]{1,4})[：:·—\-\s]*(?=[\u4e00-\u9fa5])',
          ),
        )
        .map((s) => s.trim())
        .where((s) => s.length >= 2)
        .toList();
    if (parts.length >= 2) {
      final subtitle = parts.last;
      final baseTitle = parts.first;
      if (!out.contains(subtitle)) out.add(subtitle);
      if (!out.contains(baseTitle)) out.add(baseTitle);
    }
    return out;
  }

  static String _cacheKeyFor(
    String rawUrl,
    String title, {
    int? targetYear,
    bool? wantMotionComic,
  }) {
    final u = upgradeUrlToHd(rawUrl);
    if (u.isNotEmpty) return u;
    final wantMc = wantMotionComic ?? _isMotionComicTitle(title);
    final scoped = _scopedTitleToken(
      _cleanTitle(title),
      targetYear,
      isMotionComic: wantMc,
    );
    return scoped.isEmpty ? '' : 'title:$scoped';
  }

  /// Safely extracts image dimensions from encoded bytes using [ui.ImageDescriptor]
  /// header parsing without decoding full raster pixel memory.
  /// Guarantees immediate explicit disposal of both [ui.ImageDescriptor] and [ui.ImmutableBuffer].
  static Future<({int width, int height})?> _decodeDimensions(
    Uint8List bytes,
  ) async {
    try {
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      try {
        final descriptor = await ui.ImageDescriptor.encoded(buffer);
        try {
          return (width: descriptor.width, height: descriptor.height);
        } finally {
          descriptor.dispose();
        }
      } finally {
        buffer.dispose();
      }
    } catch (_) {
      return null;
    }
  }

  /// Verifies whether [bytes] is already a clear, readable cover image (`>= 340x460`
  /// or `>= 160K` pixels or `>= 65KB`) so authentic CMS posters are kept intact
  /// rather than replaced by heuristic title searches.
  static Future<bool> isClearPosterBytes(Uint8List bytes) async {
    if (bytes.length < 14 * 1024) return false;
    if (bytes.length >= 65 * 1024) return true;
    final fp = _bytesFingerprint(bytes);
    final cached = _clearDimensionCache[fp];
    if (cached != null) return cached;
    final dims = await _decodeDimensions(bytes);
    if (dims != null) {
      final clear = (dims.width >= 340 && dims.height >= 460) ||
          (dims.width * dims.height >= 160000);
      _clearDimensionCache[fp] = clear;
      return clear;
    }
    final fallback = bytes.length >= 42 * 1024;
    _clearDimensionCache[fp] = fallback;
    return fallback;
  }

  /// Decodes the image header to verify whether [bytes] is a true high-definition
  /// vertical poster (`width >= 560 && height >= 760` or `>= 450K` pixels).
  static Future<bool> isTrueHdPoster(Uint8List bytes) async {
    if (bytes.length < 28 * 1024) return false;
    final fp = _bytesFingerprint(bytes);
    final cached = _hdDimensionCache[fp];
    if (cached != null) return cached;
    final dims = await _decodeDimensions(bytes);
    if (dims != null) {
      final isHd = (dims.width >= 560 && dims.height >= 760) ||
          (dims.width * dims.height >= 450000);
      _hdDimensionCache[fp] = isHd;
      return isHd;
    }
    final fallback = bytes.length >= 110 * 1024;
    _hdDimensionCache[fp] = fallback;
    return fallback;
  }

  /// Strict Retina HD verification for full-bleed iOS/iPadOS Home & Detail hero
  /// billboards (`width >= 640 && height >= 900` vertical poster, or
  /// `>= 1200x900` ultra-high-res artwork so vertical cropping remains crisp on
  /// 3x Retina displays).
  @visibleForTesting
  static Future<bool> isHeroHdPoster(Uint8List bytes) async {
    if (bytes.length < 28 * 1024) return false;
    final fp = _bytesFingerprint(bytes);
    final cached = _heroHdDimensionCache[fp];
    if (cached != null) return cached;
    final dims = await _decodeDimensions(bytes);
    if (dims != null) {
      final isVerticalHeroHd =
          dims.height >= dims.width * 1.05 &&
          dims.width >= 640 &&
          dims.height >= 900;
      final isUltraHighRes = dims.width >= 1200 && dims.height >= 900;
      final ok = isVerticalHeroHd || isUltraHighRes;
      _heroHdDimensionCache[fp] = ok;
      return ok;
    }
    final fallback = bytes.length >= 160 * 1024;
    _heroHdDimensionCache[fp] = fallback;
    return fallback;
  }

  /// Decoded pixel area (`width * height`) helper for preferring higher
  /// resolution artwork over bloated low-res thumbnails regardless of codec.
  static Future<int> _decodedPixelCount(Uint8List bytes) async {
    final dims = await _decodeDimensions(bytes);
    if (dims != null && dims.width > 0 && dims.height > 0) {
      return dims.width * dims.height;
    }
    return bytes.length;
  }

  /// Synchronously peeks in-memory LRU cache so already-loaded posters render
  /// on the very first frame without any async gap.
  /// When [rawUrl] is a live CMS URL, it is NEVER shadowed by unrelated title-only
  /// fallback entries unless [preferHd] finds a verified `title_hd` entry.
  static Uint8List? peekMemory(
    String rawUrl, {
    String title = '',
    String year = '',
    bool preferHd = false,
  }) {
    if (EmbyLibrary.isImage(rawUrl)) return _memory[rawUrl];
    final clean = _cleanTitle(title);
    final targetYear = _extractTargetYear(title, year);
    final wantMc = _isMotionComicTitle(title);
    final scoped = _scopedTitleToken(clean, targetYear, isMotionComic: wantMc);
    final u = upgradeUrlToHd(rawUrl);
    final hasLiveUrl = u.isNotEmpty && !_isKnownDeadPosterHost(u);

    if (hasLiveUrl) {
      if (preferHd) {
        final hdUrlKey = 'hd_url:$u';
        final hdUrlHit = _memory.remove(hdUrlKey);
        if (hdUrlHit != null) {
          _memory[hdUrlKey] = hdUrlHit;
          return hdUrlHit;
        }
        if (scoped.isNotEmpty) {
          final hdKey = 'title_hd:$scoped';
          final hdHit = _memory.remove(hdKey);
          if (hdHit != null) {
            _memory[hdKey] = hdHit;
            return hdHit;
          }
        }
      }
      final hit = _memory.remove(u);
      if (hit != null) {
        _memory[u] = hit;
        return hit;
      }
      return null;
    }

    if (scoped.isNotEmpty) {
      final hdKey = 'title_hd:$scoped';
      final hdHit = _memory.remove(hdKey);
      if (hdHit != null) {
        _memory[hdKey] = hdHit;
        return hdHit;
      }
      final tKey = 'title:$scoped';
      final hit = _memory.remove(tKey);
      if (hit != null) {
        _memory[tKey] = hit;
        return hit;
      }
    }
    return null;
  }

  /// Synchronously peeks only the verified HD cache (`hd_url:<u>` or `title_hd:<scoped>`).
  static Uint8List? peekHdMemory(
    String title, {
    String rawUrl = '',
    String year = '',
  }) {
    final u = upgradeUrlToHd(rawUrl);
    if (u.isNotEmpty && !_isKnownDeadPosterHost(u)) {
      final hdUrlKey = 'hd_url:$u';
      final hdUrlHit = _memory.remove(hdUrlKey);
      if (hdUrlHit != null) {
        _memory[hdUrlKey] = hdUrlHit;
        return hdUrlHit;
      }
    }
    final clean = _cleanTitle(title);
    final scoped = _scopedTitleToken(
      clean,
      _extractTargetYear(title, year),
      isMotionComic: _isMotionComicTitle(title),
    );
    if (scoped.isEmpty) return null;
    final hdKey = 'title_hd:$scoped';
    final hdHit = _memory.remove(hdKey);
    if (hdHit != null) {
      _memory[hdKey] = hdHit;
      return hdHit;
    }
    return null;
  }

  /// Loads poster bytes, de-duplicating concurrent requests and preserving
  /// authentic CMS poster URLs whenever available.
  static Future<Uint8List> load(
    String raw, {
    String title = '',
    String year = '',
  }) {
    if (EmbyLibrary.isImage(raw)) {
      final cached = _memory[raw];
      if (cached != null) return SynchronousFuture(cached);
      return _inflight.putIfAbsent(raw, () => _fetch(raw, const {}, timeout: const Duration(seconds: 8))
        .then((bytes) { _remember(raw, bytes); return bytes; })
        .whenComplete(() { _inflight.remove(raw); }));
    }
    final immediate = peekMemory(raw, title: title, year: year);
    if (immediate != null) {
      return SynchronousFuture<Uint8List>(immediate);
    }
    final targetYear = _extractTargetYear(title, year);
    final upgradedUrl = upgradeUrlToHd(raw);
    final key = _cacheKeyFor(upgradedUrl, title, targetYear: targetYear);
    if (key.isEmpty) {
      return Future<Uint8List>.error(const FormatException('空海报地址'));
    }
    final pending = _inflight[key];
    if (pending != null) return pending;
    final future = _loadUncached(
      upgradedUrl,
      title.trim(),
      key,
      year: year,
    ).whenComplete(() {
      _inflight.remove(key);
    });
    _inflight[key] = future;
    return future;
  }

  /// Explicitly resolves an official 1080p/2K high-definition domestic poster by
  /// [rawTitle] (via Douban official poster gallery `photos?type=R` &
  /// `l_ratio_poster`, Bangumi `images.large`, film-verified Baidu Baike raw
  /// `bcebos`, and title-verified Bilibili PGC, plus strictly-verified Bing
  /// vertical HD `murl` fallback when [strictHero] is enabled), verifying actual
  /// decoded pixel dimensions before persisting across memory and disk cache.
  /// Never overwrites the raw CMS URL entry itself.
  static Future<Uint8List> loadHdByTitle(
    String rawTitle, {
    String rawUrl = '',
    String year = '',
    bool strictHero = false,
    bool? wantMotionComic,
  }) {
    final clean = _cleanTitle(rawTitle);
    if (clean.isEmpty) {
      return Future<Uint8List>.error(const FormatException('空片名'));
    }
    final targetYear = _extractTargetYear(rawTitle, year);
    final wantMc = wantMotionComic ?? _isMotionComicTitle(rawTitle);
    final scoped = _scopedTitleToken(clean, targetYear, isMotionComic: wantMc);
    final hdKey = 'title_hd:$scoped';
    final inflightKey = strictHero ? 'hero:$scoped' : scoped;
    final hit = _memory[hdKey];
    if (hit != null && !strictHero) {
      final u = upgradeUrlToHd(rawUrl);
      if (u.isNotEmpty && !_isKnownDeadPosterHost(u)) {
        _remember('hd_url:$u', hit);
      }
      return SynchronousFuture<Uint8List>(hit);
    }
    final pending = _inflightHdTitleBytes[inflightKey];
    if (pending != null) return pending;

    Future<bool> meetsQuality(Uint8List b) =>
        strictHero ? isHeroHdPoster(b) : isTrueHdPoster(b);

    Future<Uint8List?> fetchCandidate(String candidateUrl) async {
      if (isPersonOrAvatarImageUrl(candidateUrl)) return null;
      for (final attempt in _attemptsFor(candidateUrl).take(2)) {
        try {
          return await _fetch(
            attempt.$1,
            attempt.$2,
            timeout: const Duration(milliseconds: 3600),
          );
        } catch (_) {}
      }
      return null;
    }

    final future = () async {
      if (hit != null && await meetsQuality(hit)) {
        final u = upgradeUrlToHd(rawUrl);
        if (u.isNotEmpty && !_isKnownDeadPosterHost(u)) {
          _remember('hd_url:$u', hit);
        }
        return hit;
      }

      // If the CMS provided a valid poster URL, check if its upgraded URL is
      // already a true HD poster first!
      final hasValidCmsUrl =
          rawUrl.trim().isNotEmpty && !_isKnownDeadPosterHost(rawUrl);
      if (hasValidCmsUrl) {
        final upgradedCms = upgradeUrlToHd(rawUrl);
        final inMemCms = _memory[upgradedCms];
        if (inMemCms != null && await meetsQuality(inMemCms)) {
          await _persistHdResult(scoped, rawUrl, inMemCms);
          return inMemCms;
        }
      }

      // Check disk cache for hdKey and verify actual decoded pixel dimensions
      final hdDisk = await _diskFileFor(hdKey);
      if (hdDisk != null) {
        try {
          if (await hdDisk.exists()) {
            final diskBytes = await hdDisk.readAsBytes();
            if (_looksLikeImage(diskBytes) && await meetsQuality(diskBytes)) {
              await _persistHdResult(scoped, rawUrl, diskBytes);
              return diskBytes;
            }
          }
        } catch (_) {}
      }

      // Stage 1: Official verified film/TV poster databases (Douban official
      // poster gallery + l_ratio_poster, Bangumi, Baidu Baike, Bilibili PGC).
      final resolvedYear =
          year.isNotEmpty ? year : (targetYear?.toString() ?? '');
      final verifiedUrls = await _resolveCoverUrlsByTitle(
        rawTitle,
        year: resolvedYear,
        forceRefreshHd: true,
        verifiedOnly: true,
        includeDoubanPosterGallery: strictHero,
        wantMotionComic: wantMc,
      );

      Uint8List? bestBytes;
      int bestScore = 0;

      Future<bool> probeBatch(
        List<String> urls, {
        required bool requireHeroHd,
      }) async {
        for (int offset = 0; offset < urls.length; offset += 4) {
          final batch = urls.skip(offset).take(4).toList(growable: false);
          final fetched = await Future.wait(batch.map(fetchCandidate));
          for (final bytes in fetched) {
            if (bytes == null) continue;
            final dims = await _decodeDimensions(bytes);
            final isHero = await isHeroHdPoster(bytes);
            final isTrueHd = isHero || await isTrueHdPoster(bytes);
            if (requireHeroHd && !isHero) continue;
            final pixels = dims != null ? (dims.width * dims.height) : bytes.length;
            final isPortrait = dims != null && dims.height >= dims.width * 1.05;
            final score = pixels +
                (isHero ? 3000000 : (isTrueHd ? 800000 : 0)) +
                (isPortrait ? 400000 : 0);
            if (bestBytes == null || score > bestScore) {
              bestBytes = bytes;
              bestScore = score;
            }
          }
          if (bestBytes != null) {
            final bestDims = await _decodeDimensions(bestBytes!);
            final isSharp = strictHero
                ? (await isHeroHdPoster(bestBytes!) &&
                    (bestDims == null ||
                        (bestDims.width >= 720 && bestDims.height >= 1000)))
                : await isTrueHdPoster(bestBytes!);
            if (isSharp) {
              return true;
            }
          }
        }
        return bestBytes != null && await meetsQuality(bestBytes!);
      }

      if (verifiedUrls.isNotEmpty) {
        final foundOfficial = await probeBatch(
          verifiedUrls,
          requireHeroHd: false,
        );
        if (foundOfficial && bestBytes != null) {
          await _persistHdResult(scoped, rawUrl, bestBytes!);
          return bestBytes!;
        }
      }

      // Stage 2: When official DBs didn't yield a crisp HD poster (or when the
      // CMS poster itself was dead/low-res on a full-bleed hero), query
      // strictly-verified Bing high-res vertical `murl` posters and accept
      // ONLY images passing strict caption + true portrait HD verification.
      if (!hasValidCmsUrl || strictHero) {
        final bingUrls = await _resolveVerifiedBingVerticalPosterUrls(
          clean,
          targetYear: targetYear,
          wantMotionComic: wantMc,
          strictCaptionOnly: hasValidCmsUrl,
        );
        if (bingUrls.isNotEmpty) {
          await probeBatch(
            bingUrls,
            requireHeroHd: strictHero && hasValidCmsUrl,
          );
        }
      }

      if (bestBytes != null && await meetsQuality(bestBytes!)) {
        await _persistHdResult(scoped, rawUrl, bestBytes!);
        return bestBytes!;
      }
      if (bestBytes != null && await isTrueHdPoster(bestBytes!)) {
        await _persistHdResult(scoped, rawUrl, bestBytes!);
        return bestBytes!;
      }
      if (!hasValidCmsUrl && bestBytes != null && bestBytes!.length >= 85 * 1024) {
        await _persistHdResult(scoped, rawUrl, bestBytes!);
        return bestBytes!;
      }
      throw Exception('未找到「$clean」高清封面');
    }()
        .whenComplete(() {
      _inflightHdTitleBytes.remove(inflightKey);
    });

    _inflightHdTitleBytes[inflightKey] = future;
    return future;
  }

  static Future<void> _persistHdResult(
    String scopedTitle,
    String rawUrl,
    Uint8List bytes,
  ) async {
    final hdKey = 'title_hd:$scopedTitle';
    final tKey = 'title:$scopedTitle';
    _remember(hdKey, bytes);
    _remember(tKey, bytes);
    final u = upgradeUrlToHd(rawUrl);
    if (u.isNotEmpty && !_isKnownDeadPosterHost(u)) {
      _remember('hd_url:$u', bytes);
    }
    final hdDisk = await _diskFileFor(hdKey);
    if (hdDisk != null) unawaited(_writeDisk(hdDisk, bytes));
    final titleDisk = await _diskFileFor(tKey);
    if (titleDisk != null) unawaited(_writeDisk(titleDisk, bytes));
  }

  /// Verifies that [bytes] decodes to a true high-definition landscape image
  /// (`width >= 560`, `height >= 300`, aspect ratio between `1.15` and `2.65`).
  @visibleForTesting
  static Future<bool> isLandscapeHdPoster(Uint8List bytes) async {
    if (bytes.length < 18 * 1024) return false;
    final fp = _bytesFingerprint(bytes);
    final cached = _landscapeDimensionCache[fp];
    if (cached != null) return cached;
    final dims = await _decodeDimensions(bytes);
    if (dims == null || dims.height <= 0) {
      _landscapeDimensionCache[fp] = false;
      return false;
    }
    final ratio = dims.width / dims.height;
    final ok = dims.width >= 560 &&
        dims.height >= 300 &&
        ratio >= 1.15 &&
        ratio <= 2.65;
    _landscapeDimensionCache[fp] = ok;
    return ok;
  }

  /// Strict title, work-form, year & entertainment-context matcher for Bing wide
  /// still captions so unrelated shows (e.g. TVB clips using an idiom like
  /// `走马上任`), dynamic comics (`动态漫画`) for regular anime, or stock templates
  /// never pollute a show's hero.
  @visibleForTesting
  static bool matchesBingLandscapeCaption(
    String rawCap,
    String cleanTitle, {
    int? targetYear,
    bool wantMotionComic = false,
    String imageUrl = '',
  }) {
    final cap = rawCap.trim();
    final title = cleanTitle.trim();
    if (cap.isEmpty || title.isEmpty) return false;
    if (_isNonEntertainmentBingCaption(cap)) return false;
    if (RegExp(
      r'设图网|摄图网|千图网|包图网|昵图网|站酷|花瓣|图行天下|红动中国|素材|模板|广告图|设计图库|海报设计|手抄报|年货节|节气|元旦海报|毛衫|礼盒|Canva可画|美图设计室|千库网',
    ).hasMatch(cap)) {
      return false;
    }

    // 1. Work-form guard: never mix `动态漫画` / `动态漫` with regular anime,
    // and never accept audio books / recaps / games as regular show stills.
    if (!SeriesScraper.isCompatibleWorkForm(
      targetIsMotionComic: wantMotionComic,
      candidateTitle: cap,
    )) {
      return false;
    }
    if (!wantMotionComic &&
        RegExp(r'荣耀篇|动态漫|A-SOUL创作漫画|有声书|音频', caseSensitive: false)
            .hasMatch(cap)) {
      return false;
    }

    final normCap = SeriesScraper.normalizeWorkCoreTitle(cap);
    final normTitle = SeriesScraper.normalizeWorkCoreTitle(title);
    final stripRe = RegExp(r'[\s·:：\-—_《》「」【】“”"\x27!！?？,，.。]');
    final rawNormCap =
        SeriesScraper.normalizeSequelNumerals(cap).toLowerCase().replaceAll(stripRe, '');
    final rawNormTitle =
        SeriesScraper.normalizeSequelNumerals(title).toLowerCase().replaceAll(stripRe, '');
    if (rawNormTitle.isEmpty ||
        (!rawNormCap.contains(rawNormTitle) &&
            (normTitle.isEmpty || !normCap.contains(normTitle)))) {
      return false;
    }

    // 2. Reject captions whose explicit book-quoted title `《Other》` names a
    // different work (e.g. `《溏心风暴3》...走马上任`, `《这城有良田》...走马上任`).
    final quotedTitles = RegExp(r'《([^》]{1,24})》')
        .allMatches(cap)
        .map((m) => m.group(1)!.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    if (quotedTitles.isNotEmpty) {
      final matchesAnyQuoted = quotedTitles.any((qt) {
        final nq = SeriesScraper.normalizeSequelNumerals(qt)
            .toLowerCase()
            .replaceAll(stripRe, '');
        return nq == rawNormTitle ||
            nq.contains(rawNormTitle) ||
            rawNormTitle.contains(nq);
      });
      if (!matchesAnyQuoted) return false;
    }

    // 3. Reject video-clip captions prefixed by another show's name before `：`
    // (e.g. `让子弹飞：县长走马上任`, `绍兴师爷：方敬斋走马上任`, `溏心风暴3：黄围家走马上任`).
    final colonIdx = cap.indexOf(RegExp(r'[:：]'));
    if (colonIdx >= 2 && colonIdx <= 16) {
      final prefix = cap.substring(0, colonIdx).trim();
      final normPrefix = SeriesScraper.normalizeSequelNumerals(prefix)
          .toLowerCase()
          .replaceAll(stripRe, '');
      final prefixMatchesTarget = normPrefix.contains(rawNormTitle) ||
          rawNormTitle.contains(normPrefix);
      final isGenericIntroPrefix = RegExp(
        r'预告|花絮|剧照|国漫|新剧|电视剧|电影|动漫|动画|喜剧|古装|民国|悬疑|赵本山|赵家班|精选|高清|官方|独家|专访|定档|开播|杀青|热播|重磅|精彩|高能|最新|终极',
      ).hasMatch(prefix);
      if (!prefixMatchesTarget && !isGenericIntroPrefix) {
        return false;
      }
    }

    // 4. Reject stale-year articles/images when targetYear is known
    // (e.g. 2018/2019/2021 articles/URLs for a 2023/2026 show).
    if (targetYear != null) {
      final detectedYears = <int>{};
      for (final m in RegExp(r'(?<!\d)(19\d{2}|20\d{2})(?!\d)').allMatches(cap)) {
        final y = int.tryParse(m.group(1)!);
        if (y != null && y >= 1980 && y <= 2035) detectedYears.add(y);
      }
      if (imageUrl.isNotEmpty) {
        for (final m in RegExp(
          r'(?:/|sinakd|sinacn|photo/|item/|uploads/allimg/)(19\d{2}|20\d{2})(?:\d{2,4})?(?:/|s|[-_])',
          caseSensitive: false,
        ).allMatches(imageUrl)) {
          final y = int.tryParse(m.group(1)!);
          if (y != null && y >= 1980 && y <= 2035) detectedYears.add(y);
        }
      }
      if (detectedYears.isNotEmpty &&
          !detectedYears.any((y) => y >= targetYear - 1 && y <= targetYear + 3) &&
          detectedYears.every((y) => y <= targetYear - 2)) {
        return false;
      }
    }

    final explicitlyQuoted = cap.contains('《$title》') ||
        cap.contains('「$title」') ||
        cap.contains('【$title】') ||
        cap.contains('#$title#') ||
        cap.contains('“$title”');

    final hasContext = RegExp(
      r'剧|集|电影|电视|海报|剧照|番|动画|动漫|综|片|预告|饰|演|导|独播|开机|杀青|官宣|预约|卫视|视频|腾讯|优酷|爱奇艺|芒果|喜剧|古装|民国|悬疑|新剧|定档|开播|主演',
    ).hasMatch(cap);

    if (title.length <= 2) {
      if (!hasContext) return false;
      if (!explicitlyQuoted) {
        final escaped = RegExp.escape(title);
        final standaloneMatch = RegExp(
          '(?<![\\u4e00-\\u9fff])$escaped(?![\\u4e00-\\u9fff])',
        ).hasMatch(cap);
        if (!standaloneMatch) return false;
      }
    } else if (title.length <= 4 &&
        RegExp(r'^[\u4e00-\u9fff]{3,4}$').hasMatch(title)) {
      // 3-4 character Chinese titles (often idioms/phrases like `走马上任`,
      // `生万物`) must either be quoted as a title or appear with explicit
      // drama/anime context; generic UGC clip thumbnails (`vpic_cover`) must
      // quote or lead with the title so unrelated drama clips are rejected.
      if (!explicitlyQuoted && !hasContext) return false;
      final lowerUrl = imageUrl.toLowerCase();
      final isUgcClipThumb = lowerUrl.contains('vpic_cover') ||
          lowerUrl.contains('vpic-cover');
      if (isUgcClipThumb && !explicitlyQuoted) {
        final leadsWithTitle = rawNormCap.startsWith(rawNormTitle) &&
            !cap.startsWith('$title！') &&
            !cap.startsWith('$title!');
        if (!leadsWithTitle) return false;
      }
    }
    return true;
  }

  /// Synchronously peeks cached true-landscape HD artwork for [rawTitle].
  static Uint8List? peekLandscapeMemory(
    String rawTitle, {
    String year = '',
    bool? wantMotionComic,
    String preferredBackdropUrl = '',
    String preferredDoubanId = '',
  }) {
    final pref = upgradeUrlToHd(preferredBackdropUrl);
    if (pref.isNotEmpty) {
      final prefKey = 'landscape_url:$pref';
      final prefHit = _memory.remove(prefKey);
      if (prefHit != null) {
        _memory[prefKey] = prefHit;
        return prefHit;
      }
      return null;
    }
    final prefDouban = preferredDoubanId.trim();
    if (prefDouban.isNotEmpty) {
      final dKey = 'landscape_douban:$prefDouban';
      final dHit = _memory.remove(dKey);
      if (dHit != null) {
        _memory[dKey] = dHit;
        return dHit;
      }
      return null;
    }
    final clean = _cleanTitle(rawTitle);
    if (clean.isEmpty) return null;
    final wantMc = wantMotionComic ?? _isMotionComicTitle(rawTitle);
    final scoped = _scopedTitleToken(
      clean,
      _extractTargetYear(rawTitle, year),
      isMotionComic: wantMc,
    );
    if (scoped.isEmpty) return null;
    final key = 'landscape_hd:$scoped';
    final hit = _memory.remove(key);
    if (hit != null) {
      _memory[key] = hit;
      return hit;
    }
    return null;
  }

  @visibleForTesting
  static void debugSeedLandscapeMemory(
    String rawTitle,
    Uint8List bytes, {
    String year = '',
    bool? wantMotionComic,
  }) {
    final clean = _cleanTitle(rawTitle);
    final wantMc = wantMotionComic ?? _isMotionComicTitle(rawTitle);
    final scoped = _scopedTitleToken(
      clean,
      _extractTargetYear(rawTitle, year),
      isMotionComic: wantMc,
    );
    if (scoped.isEmpty) return;
    _remember('landscape_hd:$scoped', bytes);
  }

  /// Resolves a true high-resolution horizontal/landscape poster or official
  /// key-art still (`width >= 640`, `4:3`–`16:9`) for [rawTitle] using only
  /// approved domestic endpoints in strict trust order:
  /// 1. User-bound backdrop URL (if explicitly scraped & bound)
  /// 2. Official Douban subject stills (`photos?type=S` via `subject_suggest` +
  ///    Rexxar `search/weixin`)
  /// 3. Official Bilibili PGC 16:9 covers/frames (strict work-form & year match)
  /// 4. Strictly-verified Bing wide stills ONLY if official sources found none.
  static Future<Uint8List> loadLandscapeByTitle(
    String rawTitle, {
    String year = '',
    String fallbackUrl = '',
    bool? wantMotionComic,
    String preferredBackdropUrl = '',
    String preferredDoubanId = '',
    bool preferredDoubanIsTv = true,
  }) {
    final clean = _cleanTitle(rawTitle);
    final prefBackdrop = upgradeUrlToHd(preferredBackdropUrl);
    if (clean.isEmpty && prefBackdrop.isEmpty) {
      return Future<Uint8List>.error(const FormatException('空片名'));
    }
    final targetYear = _extractTargetYear(rawTitle, year);
    final wantMc = wantMotionComic ?? _isMotionComicTitle(rawTitle);
    final scoped = _scopedTitleToken(clean, targetYear, isMotionComic: wantMc);
    final cacheKey = prefBackdrop.isNotEmpty
        ? 'landscape_url:$prefBackdrop'
        : (preferredDoubanId.trim().isNotEmpty
            ? 'landscape_douban:${preferredDoubanId.trim()}'
            : 'landscape_hd:$scoped');
    final hit = peekLandscapeMemory(
      rawTitle,
      year: year,
      wantMotionComic: wantMc,
      preferredBackdropUrl: prefBackdrop,
      preferredDoubanId: preferredDoubanId,
    );
    if (hit != null) {
      return SynchronousFuture<Uint8List>(hit);
    }
    final inflightKey = cacheKey;
    final pending = _inflightLandscapeTitleBytes[inflightKey];
    if (pending != null) return pending;

    final future = () async {
      // 1. Check disk cache first.
      final diskFile = await _diskFileFor(cacheKey);
      if (diskFile != null) {
        try {
          if (await diskFile.exists()) {
            final diskBytes = await diskFile.readAsBytes();
            if (_looksLikeImage(diskBytes) &&
                await isLandscapeHdPoster(diskBytes)) {
              _remember(cacheKey, diskBytes);
              return diskBytes;
            }
          }
        } catch (_) {}
      }

      // 2. If user bound a specific backdrop URL, fetch it directly first.
      if (prefBackdrop.isNotEmpty && !_isKnownDeadPosterHost(prefBackdrop)) {
        for (final attempt in _attemptsFor(prefBackdrop).take(3)) {
          try {
            final bytes = await _fetch(
              attempt.$1,
              attempt.$2,
              timeout: const Duration(milliseconds: 3800),
            );
            if (await isLandscapeHdPoster(bytes)) {
              _remember(cacheKey, bytes);
              if (diskFile != null) unawaited(_writeDisk(diskFile, bytes));
              return bytes;
            }
          } catch (_) {}
        }
      }

      // 3. If the provided URL is already an authentic HD landscape artwork
      // (e.g. Emby backdrop or horizontal poster), reuse it directly.
      final upgradedFallback = upgradeUrlToHd(fallbackUrl);
      if (preferredDoubanId.trim().isEmpty &&
          upgradedFallback.isNotEmpty &&
          !_isKnownDeadPosterHost(upgradedFallback)) {
        final inMem = _memory[upgradedFallback];
        if (inMem != null && await isLandscapeHdPoster(inMem)) {
          _remember(cacheKey, inMem);
          if (diskFile != null) unawaited(_writeDisk(diskFile, inMem));
          return inMem;
        }
      }

      // 4. Resolve tiered horizontal HD URLs: Official DBs first, Bing fallback second.
      final tiered = await _resolveTieredLandscapeUrlsByTitle(
        rawTitle,
        year: year.isNotEmpty ? year : (targetYear?.toString() ?? ''),
        wantMotionComic: wantMc,
        preferredDoubanId: preferredDoubanId.trim(),
        preferredDoubanIsTv: preferredDoubanIsTv,
      );

      Future<Uint8List?> probeTier(
        List<String> urls, {
        required int maxItems,
        required int fastWidthThreshold,
      }) async {
        Uint8List? bestBytes;
        int bestPixels = 0;
        for (final candidateUrl in urls.take(maxItems)) {
          if (isPersonOrAvatarImageUrl(candidateUrl)) continue;
          for (final attempt in _attemptsFor(candidateUrl).take(2)) {
            try {
              final bytes = await _fetch(
                attempt.$1,
                attempt.$2,
                timeout: const Duration(milliseconds: 3500),
              );
              if (!await isLandscapeHdPoster(bytes)) continue;
              final dims = await _decodeDimensions(bytes);
              final pixels =
                  dims != null ? dims.width * dims.height : bytes.length;
              if (bestBytes == null || pixels > bestPixels) {
                bestBytes = bytes;
                bestPixels = pixels;
              }
              if (dims != null &&
                  dims.width >= fastWidthThreshold &&
                  bytes.length >= 36 * 1024) {
                return bytes;
              }
              break;
            } catch (_) {}
          }
        }
        return bestBytes;
      }

      // Always try official verified Douban/Bilibili stills FIRST before Bing.
      final officialBytes = await probeTier(
        tiered.officialUrls,
        maxItems: 10,
        fastWidthThreshold: 800,
      );
      if (officialBytes != null) {
        _remember(cacheKey, officialBytes);
        if (diskFile != null) unawaited(_writeDisk(diskFile, officialBytes));
        return officialBytes;
      }

      final bingBytes = await probeTier(
        tiered.fallbackUrls,
        maxItems: 10,
        fastWidthThreshold: 960,
      );
      if (bingBytes != null) {
        _remember(cacheKey, bingBytes);
        if (diskFile != null) unawaited(_writeDisk(diskFile, bingBytes));
        return bingBytes;
      }

      throw Exception('未找到「$clean」横向高清海报');
    }()
        .whenComplete(() {
      _inflightLandscapeTitleBytes.remove(inflightKey);
    });

    _inflightLandscapeTitleBytes[inflightKey] = future;
    return future;
  }

  /// Unified Douban subject lookup combining `subject_suggest` and Rexxar
  /// `search/weixin` + `search/subjects`, strictly preserving dynamic-comic vs
  /// regular-anime separation and year/Roman-numeral matching.
  static Future<({String id, bool isTv, String coverUrl})?>
      _lookupDoubanSubject(
    String rawTitle, {
    String year = '',
    bool? wantMotionComic,
    String? bidCookie,
  }) async {
    final cleanTitle = _cleanTitle(rawTitle);
    if (cleanTitle.isEmpty) return null;
    final targetYear = _extractTargetYear(rawTitle, year);
    final wantMc = wantMotionComic ?? _isMotionComicTitle(rawTitle);
    final scoped = _scopedTitleToken(
      cleanTitle,
      targetYear,
      isMotionComic: wantMc,
    );
    final cached = _doubanSubjectIdCache[scoped];
    if (cached != null) {
      return (id: cached.id, isTv: cached.isTv, coverUrl: '');
    }

    final cookie = bidCookie ?? 'bid=${_randomDoubanBid()}';
    final resolvedYear = year.isNotEmpty ? year : (targetYear?.toString() ?? '');
    final baseVariants = _queryVariantsForTitle(cleanTitle);
    final queryList = <String>[
      if (wantMc) ...[
        '$cleanTitle 动态漫画',
        if (baseVariants.isNotEmpty) baseVariants.first,
      ] else ...[
        ...baseVariants.take(2),
      ],
    ];

    // 1. Try classic `subject_suggest` first (fast for popular films/dramas).
    for (final qv in queryList.take(2)) {
      final body = await _getRatingTextUrl(
        Uri.parse(
          'https://movie.douban.com/j/subject_suggest?q=${Uri.encodeQueryComponent(qv)}',
        ),
        headers: {
          'User-Agent': _desktopChromeUa,
          'Referer': 'https://movie.douban.com/',
          'Cookie': cookie,
          'Accept': 'application/json, text/plain, */*',
        },
      );
      if (body == null) continue;
      try {
        final decoded = jsonDecode(body);
        final matched = parseDoubanSuggestSubject(
          decoded,
          rawTitle,
          year: resolvedYear,
          wantMotionComic: wantMc,
        );
        if (matched != null) {
          _doubanSubjectIdCache[scoped] = matched;
          final covers = parseDoubanSuggestCoverUrls(
            decoded,
            rawTitle,
            year: resolvedYear,
            wantMotionComic: wantMc,
          );
          return (
            id: matched.id,
            isTv: matched.isTv,
            coverUrl: covers.isNotEmpty ? covers.first : '',
          );
        }
      } catch (_) {}
    }

    // 2. Fallback: Douban Mobile Rexxar `search/weixin` & `search/subjects`
    // (resolves donghua `年番`, Roman-numeral sequels like `斗罗大陆Ⅱ绝世唐门`,
    // and recent 2025/2026 dramas where `subject_suggest` returns `[]`).
    for (final qv in queryList.take(2)) {
      final endpoints = <String>[
        'https://m.douban.com/rexxar/api/v2/search/weixin?q=${Uri.encodeQueryComponent(qv)}&count=8',
        'https://m.douban.com/rexxar/api/v2/search/subjects?type=tv&q=${Uri.encodeQueryComponent(qv)}',
        'https://m.douban.com/rexxar/api/v2/search/subjects?type=movie&q=${Uri.encodeQueryComponent(qv)}',
      ];
      for (final endpoint in endpoints) {
        final body = await _getRatingTextUrl(
          Uri.parse(endpoint),
          headers: {
            'User-Agent': _mobileSafariUa,
            'Referer': 'https://m.douban.com/',
            'Cookie': cookie,
            'Accept': 'application/json',
          },
          timeout: const Duration(milliseconds: 2500),
        );
        if (body == null) continue;
        try {
          final decoded = jsonDecode(body);
          final matched = parseDoubanRexxarSubject(
            decoded,
            rawTitle,
            year: resolvedYear,
            wantMotionComic: wantMc,
          );
          if (matched != null) {
            _doubanSubjectIdCache[scoped] = (
              id: matched.id,
              isTv: matched.isTv,
            );
            return matched;
          }
        } catch (_) {}
      }
    }
    return null;
  }

  /// Combines official verified URLs strictly ahead of Bing fallback URLs so
  /// Bing's faster HTTP response can NEVER overtake Douban or Bilibili official
  /// stills in a `Future.wait` race.
  @visibleForTesting
  static List<String> mergeTieredLandscapeUrls({
    required List<String> doubanUrls,
    required List<String> bilibiliUrls,
    required List<String> bingPrimaryUrls,
    required List<String> bingSecondaryUrls,
  }) {
    final out = <String>[];
    final seen = <String>{};
    for (final list in [
      doubanUrls,
      bilibiliUrls,
      bingPrimaryUrls,
      bingSecondaryUrls,
    ]) {
      for (final u in list) {
        if (u.startsWith('http') &&
            !isPersonOrAvatarImageUrl(u) &&
            seen.add(u)) {
          out.add(u);
        }
      }
    }
    return out;
  }

  static Future<({List<String> officialUrls, List<String> fallbackUrls})>
      _resolveTieredLandscapeUrlsByTitle(
    String rawTitle, {
    String year = '',
    bool? wantMotionComic,
    String preferredDoubanId = '',
    bool preferredDoubanIsTv = true,
  }) async {
    final cleanTitle = _cleanTitle(rawTitle);
    final targetYear = _extractTargetYear(rawTitle, year);
    final wantMc = wantMotionComic ?? _isMotionComicTitle(rawTitle);
    final scoped = _scopedTitleToken(
      cleanTitle,
      targetYear,
      isMotionComic: wantMc,
    );
    final cacheId = preferredDoubanId.isNotEmpty
        ? 'douban:$preferredDoubanId'
        : scoped;
    final cached = _landscapeCoverUrlsCache[cacheId];
    if (cached != null && cached.isNotEmpty) {
      final official = <String>[];
      final fallback = <String>[];
      for (final u in cached) {
        final lower = u.toLowerCase();
        if (lower.contains('doubanio.com') ||
            lower.contains('hdslb.com') ||
            lower.contains('biliimg.com')) {
          official.add(u);
        } else {
          fallback.add(u);
        }
      }
      return (officialUrls: official, fallbackUrls: fallback);
    }

    final doubanUrls = <String>[];
    final biliUrls = <String>[];
    final bingPrimaryUrls = <String>[];
    final bingSecondaryUrls = <String>[];

    void addTo(List<String> target, String raw) {
      final hd = upgradeUrlToHd(raw);
      if (!hd.startsWith('http') || isPersonOrAvatarImageUrl(hd)) return;
      if (!target.contains(hd)) target.add(hd);
    }

    final variants = _queryVariantsForTitle(cleanTitle);
    final primaryQuery = variants.isNotEmpty ? variants.first : cleanTitle;
    final bidCookie = 'bid=${_randomDoubanBid()}';
    final resolvedYear = year.isNotEmpty ? year : (targetYear?.toString() ?? '');

    await Future.wait([
      // Source 1 (Official): Douban verified subject official stills (`photos?type=S`)
      () async {
        ({String id, bool isTv})? subject;
        if (preferredDoubanId.isNotEmpty) {
          subject = (id: preferredDoubanId, isTv: preferredDoubanIsTv);
        } else {
          final found = await _lookupDoubanSubject(
            rawTitle,
            year: resolvedYear,
            wantMotionComic: wantMc,
            bidCookie: bidCookie,
          );
          if (found != null) {
            subject = (id: found.id, isTv: found.isTv);
          }
        }
        if (subject != null) {
          final kinds = subject.isTv
              ? const ['tv', 'movie']
              : const ['movie', 'tv'];
          for (final kind in kinds) {
            final photoBody = await _getRatingTextUrl(
              Uri.parse(
                'https://m.douban.com/rexxar/api/v2/$kind/${subject.id}/photos?type=S&start=0&count=8',
              ),
              headers: {
                'User-Agent': _mobileSafariUa,
                'Referer': 'https://m.douban.com/movie/subject/${subject.id}/',
                'Cookie': bidCookie,
                'Accept': 'application/json, text/plain, */*',
              },
              timeout: const Duration(milliseconds: 2800),
            );
            if (photoBody == null) continue;
            try {
              final decoded = jsonDecode(photoBody);
              final photos = decoded is Map ? decoded['photos'] : null;
              if (photos is List) {
                final wideCandidates = <({String url, int area})>[];
                for (final p in photos.whereType<Map>()) {
                  final img = p['image'];
                  if (img is! Map) continue;
                  final large = img['large'] ?? img['normal'];
                  if (large is Map) {
                    final w = (large['width'] as num?)?.toInt() ?? 0;
                    final h = (large['height'] as num?)?.toInt() ?? 0;
                    final u = (large['url'] ?? '').toString().trim();
                    if (u.isNotEmpty &&
                        (w == 0 ||
                            (w > h &&
                                w >= 640 &&
                                (w / math.max(1, h)) <= 2.65))) {
                      wideCandidates.add((url: u, area: w * h));
                    }
                  }
                }
                wideCandidates.sort((a, b) => b.area.compareTo(a.area));
                for (final entry in wideCandidates) {
                  addTo(doubanUrls, entry.url);
                }
                if (doubanUrls.isNotEmpty) break;
              }
            } catch (_) {}
          }
        }
      }(),

      // Source 2 (Official): Bilibili PGC horizontal covers & 16:9 episode key frames
      // Strictly checks work-form (`动态漫画` vs regular anime) AND release year.
      if (preferredDoubanId.isEmpty && primaryQuery.isNotEmpty)
        () async {
          final biliQuery =
              wantMc ? '$primaryQuery 动态漫画' : primaryQuery;
          for (final stype in const ['media_bangumi', 'media_ft']) {
            HttpClientRequest? req;
            try {
              final uri = Uri.parse(
                'https://api.bilibili.com/x/web-interface/search/type?search_type=$stype&keyword=${Uri.encodeQueryComponent(biliQuery)}',
              );
              req = await _client
                  .getUrl(uri)
                  .timeout(const Duration(milliseconds: 2600));
              req.headers.set('User-Agent', _desktopChromeUa);
              req.headers.set('Referer', 'https://search.bilibili.com/');
              req.headers.set('Cookie', _biliCookie);
              req.headers.set('Accept', 'application/json, text/plain, */*');
              final resp =
                  await req.close().timeout(const Duration(milliseconds: 2600));
              if (resp.statusCode >= 200 && resp.statusCode < 300) {
                final body = await utf8.decoder
                    .bind(resp)
                    .join()
                    .timeout(const Duration(milliseconds: 2600));
                final decoded = jsonDecode(body);
                final list = decoded is Map && decoded['data'] is Map
                    ? decoded['data']['result']
                    : null;
                if (list is List) {
                  for (final item in list) {
                    if (item is! Map) continue;
                    final t = (item['title'] ?? '').toString().trim();
                    final styles = (item['styles'] ?? '').toString().trim();
                    final desc = (item['desc'] ?? '').toString().trim();
                    if (!_isSameWorkTitle(
                      t,
                      rawTitle,
                      wantMotionComic: wantMc,
                      candidateContext: '$styles $desc',
                    )) {
                      continue;
                    }
                    if (targetYear != null && item['pubtime'] is num) {
                      final secs = (item['pubtime'] as num).toInt();
                      if (secs > 0) {
                        final pubYear = DateTime.fromMillisecondsSinceEpoch(
                          secs * 1000,
                        ).year;
                        if ((pubYear - targetYear).abs() >= 2) continue;
                      }
                    }
                    for (final field in const [
                      'horizontal_cover_16_9',
                      'horizontal_cover_16_10',
                    ]) {
                      final u = (item[field] ?? '').toString().trim();
                      if (u.isNotEmpty) addTo(biliUrls, u);
                    }
                    final eps = item['eps'];
                    if (eps is List) {
                      for (final ep in eps.take(3)) {
                        if (ep is Map) {
                          final cov = (ep['cover'] ?? '').toString().trim();
                          if (cov.isNotEmpty) addTo(biliUrls, cov);
                        }
                      }
                    }
                    if (biliUrls.isNotEmpty) break;
                  }
                }
              } else {
                await resp.drain<void>();
              }
            } catch (_) {
              try {
                req?.abort();
              } catch (_) {}
            }
          }
        }(),

      // Source 3 (Fallback ONLY): Bing China wide high-resolution stills
      // Placed into its own lower-priority bucket so it NEVER overrides Douban/Bilibili.
      if (preferredDoubanId.isEmpty && primaryQuery.isNotEmpty)
        () async {
          final yearHint = targetYear != null ? '$targetYear ' : '';
          final queries = wantMc
              ? <String>[
                  '"$primaryQuery" 动态漫画 ${yearHint}剧照',
                  '"$primaryQuery" 动态漫画 横版海报',
                ]
              : <String>[
                  '"$primaryQuery" ${yearHint}剧照 -动态漫画 -动态漫 -手游 -成语',
                  '"$primaryQuery" ${yearHint}横版海报 -动态漫画 -动态漫 -模板 -素材 -成语',
                ];
          for (final qText in queries) {
            if (bingPrimaryUrls.length >= 4) break;
            HttpClientRequest? req;
            try {
              final uri = Uri.parse(
                'https://cn.bing.com/images/async?q=${Uri.encodeQueryComponent(qText)}&first=1&count=24&qft=+filterui:aspect-wide+filterui:imagesize-large',
              );
              req = await _client
                  .getUrl(uri)
                  .timeout(const Duration(milliseconds: 2800));
              req.headers.set('User-Agent', _desktopChromeUa);
              req.headers.set('Referer', 'https://cn.bing.com/');
              req.headers.set(
                'Accept',
                'text/html,application/xhtml+xml,*/*;q=0.8',
              );
              final resp =
                  await req.close().timeout(const Duration(milliseconds: 2800));
              if (resp.statusCode >= 200 && resp.statusCode < 300) {
                final html = await utf8.decoder
                    .bind(resp)
                    .join()
                    .timeout(const Duration(milliseconds: 2800));
                final cardMatches = RegExp(
                  r'm=(?:"|&quot;)(\{[^"]*?\})(?:"|&quot;)',
                ).allMatches(html);
                for (final cm in cardMatches) {
                  final cardJsonAttr = cm.group(1) ?? '';
                  final tMatch = RegExp(
                    r'&quot;t&quot;:&quot;([^&]{2,120})&quot;',
                  ).firstMatch(cardJsonAttr);
                  final rawCap = (tMatch?.group(1) ?? '')
                      .replaceAll(RegExp(r'[\u0000-\u001f]'), '')
                      .trim();
                  final murlMatch = RegExp(
                    r'&quot;murl&quot;:&quot;(https?://[^&"\x27]+?)&quot;',
                  ).firstMatch(cardJsonAttr);
                  final rawMurl = murlMatch != null
                      ? upgradeUrlToHd(murlMatch.group(1)!)
                      : '';
                  if (!matchesBingLandscapeCaption(
                        rawCap,
                        cleanTitle,
                        targetYear: targetYear,
                        wantMotionComic: wantMc,
                        imageUrl: rawMurl,
                      ) ||
                      _isNonEntertainmentBingCaption(cardJsonAttr)) {
                    continue;
                  }
                  if (rawMurl.isNotEmpty && !isPersonOrAvatarImageUrl(rawMurl)) {
                    if (_isFastDomesticHost(rawMurl)) {
                      addTo(bingPrimaryUrls, rawMurl);
                    } else {
                      addTo(bingSecondaryUrls, rawMurl);
                    }
                  }
                  final oipMatch = RegExp(
                    r'OIP(?:-C)?\.([A-Za-z0-9_-]+)',
                  ).firstMatch(cardJsonAttr);
                  if (oipMatch != null) {
                    final fullId = oipMatch.group(0)!;
                    final coreId = oipMatch.group(1)!;
                    if (!RegExp(r'Ha[KNLMP][A-Za-z0-9]$').hasMatch(coreId)) {
                      addTo(
                        bingSecondaryUrls,
                        'https://tse1-mm.cn.bing.net/th/id/$fullId?w=1280&h=720&c=7&r=0&o=5&pid=1.7',
                      );
                    }
                  }
                }
              } else {
                await resp.drain<void>();
              }
            } catch (_) {
              try {
                req?.abort();
              } catch (_) {}
            }
          }
        }(),
    ]);

    final officialUrls = mergeTieredLandscapeUrls(
      doubanUrls: doubanUrls,
      bilibiliUrls: biliUrls,
      bingPrimaryUrls: const [],
      bingSecondaryUrls: const [],
    );
    final fallbackUrls = mergeTieredLandscapeUrls(
      doubanUrls: const [],
      bilibiliUrls: const [],
      bingPrimaryUrls: bingPrimaryUrls,
      bingSecondaryUrls: bingSecondaryUrls,
    );
    final combined = [...officialUrls, ...fallbackUrls];
    if (combined.isNotEmpty) {
      _landscapeCoverUrlsCache[cacheId] = combined;
    }
    return (officialUrls: officialUrls, fallbackUrls: fallbackUrls);
  }

  /// Synchronously peeks cached vibrant hero atmosphere color for [bytes].
  static Color? peekVibrantAmbientColor(Uint8List bytes) {
    return _vibrantAmbientColorCache[_bytesFingerprint(bytes)];
  }

  /// Extracts the poster's true atmospheric hue & natural saturation (without
  /// crushing luminance down to near-black) so the Home Hero can melt smoothly
  /// into BOTH Light Mode and Dark Mode shelves with zero muddy dark cliff.
  static Future<Color> extractVibrantAmbientColor(Uint8List bytes) async {
    final fp = _bytesFingerprint(bytes);
    final cached = _vibrantAmbientColorCache[fp];
    if (cached != null) return cached;
    try {
      final codec = await ui.instantiateImageCodec(
        bytes,
        targetWidth: 24,
        targetHeight: 36,
      );
      final frame = await codec.getNextFrame();
      final image = frame.image;
      final byteData = await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      );
      image.dispose();
      if (byteData != null) {
        final data = byteData.buffer.asUint8List();
        const w = 24;
        const h = 36;
        double rSum = 0;
        double gSum = 0;
        double bSum = 0;
        double weightSum = 0;
        for (int y = (h * 0.56).floor(); y < h; y++) {
          final isEdgeBand = y >= (h * 0.72);
          final rowWeight = isEdgeBand ? 2.0 : 1.2;
          for (int x = 0; x < w; x++) {
            final idx = (y * w + x) * 4;
            if (idx + 3 >= data.length) continue;
            final r = data[idx].toDouble();
            final g = data[idx + 1].toDouble();
            final b = data[idx + 2].toDouble();
            final a = data[idx + 3].toDouble() / 255.0;
            if (a < 0.2) continue;
            final maxC = r > g ? (r > b ? r : b) : (g > b ? g : b);
            final minC = r < g ? (r < b ? r : b) : (g < b ? g : b);
            final sat = maxC > 0 ? (maxC - minC) / maxC : 0.0;
            final wgt = rowWeight * (0.65 + sat * 1.1) * a;
            rSum += r * wgt;
            gSum += g * wgt;
            bSum += b * wgt;
            weightSum += wgt;
          }
        }
        if (weightSum > 0) {
          final raw = Color.fromARGB(
            255,
            (rSum / weightSum).round().clamp(0, 255),
            (gSum / weightSum).round().clamp(0, 255),
            (bSum / weightSum).round().clamp(0, 255),
          );
          final hsl = HSLColor.fromColor(raw);
          final color = hsl
              .withSaturation(
                hsl.saturation < 0.05
                    ? hsl.saturation
                    : hsl.saturation.clamp(0.12, 0.52),
              )
              .withLightness(hsl.lightness.clamp(0.18, 0.72))
              .toColor();
          _vibrantAmbientColorCache[fp] = color;
          return color;
        }
      }
    } catch (_) {}
    const fallback = Color(0xFF3E5664);
    _vibrantAmbientColorCache[fp] = fallback;
    return fallback;
  }

  /// Synchronously peeks cached ambient color extracted from poster [bytes].
  static Color? peekAmbientColor(Uint8List bytes) {
    return _ambientColorCache[_bytesFingerprint(bytes)];
  }

  /// Extracts a rich, cinema-grade dark ambient background color matching the
  /// poster's top/bottom edge palette so the Detail Screen background and
  /// top/bottom poster gradients blend seamlessly with zero visual seam.
  static Future<Color> extractEdgeAmbientColor(Uint8List bytes) async {
    final fp = _bytesFingerprint(bytes);
    final cached = _ambientColorCache[fp];
    if (cached != null) return cached;
    try {
      final codec = await ui.instantiateImageCodec(
        bytes,
        targetWidth: 24,
        targetHeight: 36,
      );
      final frame = await codec.getNextFrame();
      final image = frame.image;
      final byteData = await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      );
      image.dispose();
      if (byteData != null) {
        final data = byteData.buffer.asUint8List();
        const w = 24;
        const h = 36;
        double rSum = 0;
        double gSum = 0;
        double bSum = 0;
        double weightSum = 0;
        for (int y = 0; y < h; y++) {
          final isBottomBand = y >= (h * 0.62);
          final isTopBand = y <= (h * 0.18);
          final rowWeight = isBottomBand ? 2.6 : (isTopBand ? 1.4 : 0.6);
          for (int x = 0; x < w; x++) {
            final idx = (y * w + x) * 4;
            if (idx + 3 >= data.length) continue;
            final r = data[idx].toDouble();
            final g = data[idx + 1].toDouble();
            final b = data[idx + 2].toDouble();
            final a = data[idx + 3].toDouble() / 255.0;
            if (a < 0.2) continue;
            final maxC = r > g ? (r > b ? r : b) : (g > b ? g : b);
            final minC = r < g ? (r < b ? r : b) : (g < b ? g : b);
            final sat = maxC > 0 ? (maxC - minC) / maxC : 0.0;
            final wgt = rowWeight * (0.65 + sat * 0.85) * a;
            rSum += r * wgt;
            gSum += g * wgt;
            bSum += b * wgt;
            weightSum += wgt;
          }
        }
        if (weightSum > 0) {
          var rAvg = rSum / weightSum;
          var gAvg = gSum / weightSum;
          var bAvg = bSum / weightSum;
          final luma = 0.299 * rAvg + 0.587 * gAvg + 0.114 * bAvg;
          if (luma > 44.0) {
            final scale = 40.0 / luma;
            rAvg *= scale;
            gAvg *= scale;
            bAvg *= scale;
          } else if (luma < 16.0 && luma > 0.5) {
            final scale = 20.0 / luma;
            rAvg = (rAvg * scale).clamp(12.0, 58.0);
            gAvg = (gAvg * scale).clamp(10.0, 54.0);
            bAvg = (bAvg * scale).clamp(12.0, 62.0);
          }
          final color = Color.fromARGB(
            255,
            rAvg.round().clamp(10, 68),
            gAvg.round().clamp(9, 62),
            bAvg.round().clamp(10, 72),
          );
          _ambientColorCache[fp] = color;
          return color;
        }
      }
    } catch (_) {}
    const fallback = Color(0xFF1A1512);
    _ambientColorCache[fp] = fallback;
    return fallback;
  }

  static int _bytesFingerprint(Uint8List b) {
    if (b.isEmpty) return 0;
    int h = b.length;
    final headerEnd = b.length < 32 ? b.length : 32;
    for (int i = 0; i < headerEnd; i++) {
      h = ((h ^ b[i]) * 0x01000193) & 0x7fffffff;
    }
    final step = (b.length ~/ 16).clamp(1, 4096);
    for (int i = 0; i < b.length; i += step) {
      h = ((h ^ b[i]) * 0x01000193) & 0x7fffffff;
    }
    return h;
  }

  /// Returns cached series synopsis if already resolved.
  static String peekSeriesSynopsis(
    String rawTitle, {
    String year = '',
    bool? wantMotionComic,
  }) {
    final clean = _cleanTitle(rawTitle);
    if (clean.isEmpty) return '';
    final targetYear = _extractTargetYear(rawTitle, year);
    final wantMc = wantMotionComic ?? _isMotionComicTitle(rawTitle);
    final scoped = _scopedTitleToken(clean, targetYear, isMotionComic: wantMc);
    final scopedHit = _titleSynopsisCache[scoped];
    if (scopedHit != null && scopedHit.isNotEmpty) return scopedHit;
    if (targetYear == null && !wantMc) {
      return _titleSynopsisCache[clean] ?? '';
    }
    return '';
  }

  /// Synchronously peeks cached verified Douban & Rotten Tomatoes ratings for [rawTitle].
  static ({double? douban, int? rt})? peekRatings(
    String rawTitle, {
    String year = '',
    bool? wantMotionComic,
  }) {
    final clean = _cleanTitle(rawTitle);
    if (clean.isEmpty) return null;
    final targetYear = _extractTargetYear(rawTitle, year);
    final wantMc = wantMotionComic ?? _isMotionComicTitle(rawTitle);
    final scoped = _scopedTitleToken(clean, targetYear, isMotionComic: wantMc);
    final hit = _ratingsCache.remove(scoped);
    if (hit != null) {
      _ratingsCache[scoped] = hit;
      return hit;
    }
    return null;
  }

  @visibleForTesting
  static void debugSeedRatings(
    String rawTitle, {
    String year = '',
    bool? wantMotionComic,
    double? douban,
    int? rt,
  }) {
    final clean = _cleanTitle(rawTitle);
    if (clean.isEmpty) return;
    final targetYear = _extractTargetYear(rawTitle, year);
    final wantMc = wantMotionComic ?? _isMotionComicTitle(rawTitle);
    final scoped = _scopedTitleToken(clean, targetYear, isMotionComic: wantMc);
    _ratingsCache[scoped] = (douban: douban, rt: rt);
  }

  static Future<String?> _getRatingTextUrl(
    Uri uri, {
    required Map<String, String> headers,
    Duration timeout = const Duration(milliseconds: 2300),
  }) async {
    final useEphemeral = HttpOverrides.current != null;
    final client = useEphemeral ? HttpClient() : _client;
    HttpClientRequest? req;
    try {
      req = await client.getUrl(uri).timeout(timeout);
      headers.forEach(req.headers.set);
      final resp = await req.close().timeout(timeout);
      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        return await utf8.decoder.bind(resp).join().timeout(timeout);
      }
      await resp.drain<void>();
    } catch (_) {
      try {
        req?.abort();
      } catch (_) {}
    } finally {
      if (useEphemeral) {
        client.close(force: true);
      }
    }
    return null;
  }

  /// Resolves authentic Douban (`2.0..10.0`) and Rotten Tomatoes (`1..100%`)
  /// ratings for [rawTitle] using only approved domestic/Douban endpoints.
  /// Never fabricates or hash-estimates missing scores; caches misses so absent
  /// badges stay hidden without repeated network traffic.
  static Future<({double? douban, int? rt})> fetchRatings(
    String rawTitle, {
    String year = '',
    bool? wantMotionComic,
    String preferredDoubanId = '',
    bool preferredDoubanIsTv = true,
  }) {
    final clean = _cleanTitle(rawTitle);
    if (clean.isEmpty) {
      return SynchronousFuture<({double? douban, int? rt})>(
        (douban: null, rt: null),
      );
    }
    final targetYear = _extractTargetYear(rawTitle, year);
    final wantMc = wantMotionComic ?? _isMotionComicTitle(rawTitle);
    final scoped = _scopedTitleToken(clean, targetYear, isMotionComic: wantMc);
    final cacheKey = preferredDoubanId.trim().isNotEmpty
        ? 'douban:${preferredDoubanId.trim()}'
        : scoped;
    if (preferredDoubanId.trim().isEmpty) {
      final cached = peekRatings(
        rawTitle,
        year: year,
        wantMotionComic: wantMc,
      );
      if (cached != null) {
        return SynchronousFuture<({double? douban, int? rt})>(cached);
      }
    } else if (_ratingsCache.containsKey(cacheKey)) {
      return SynchronousFuture<({double? douban, int? rt})>(
        _ratingsCache[cacheKey]!,
      );
    }
    final pending = _inflightRatings[cacheKey];
    if (pending != null) return pending;

    final future = () async {
      final variants = _queryVariantsForTitle(clean);
      final primary = variants.isNotEmpty ? variants.first : clean;
      final bidCookie = 'bid=${_randomDoubanBid()}';
      final resolvedYear =
          year.isNotEmpty ? year : (targetYear?.toString() ?? '');
      double? resolvedDouban;
      int? resolvedRt;

      await Future.wait([
        // 1. Verified Douban rating (`subject_suggest` + `rexxar/search/weixin` -> `rexxar/api/v2/{kind}/{id}`)
        () async {
          ({String id, bool isTv})? subject;
          if (preferredDoubanId.trim().isNotEmpty) {
            subject = (id: preferredDoubanId.trim(), isTv: preferredDoubanIsTv);
          } else {
            final found = await _lookupDoubanSubject(
              rawTitle,
              year: resolvedYear,
              wantMotionComic: wantMc,
              bidCookie: bidCookie,
            );
            if (found != null) {
              subject = (id: found.id, isTv: found.isTv);
            }
          }

          if (subject != null) {
            final endpoints = subject.isTv
                ? ['tv', 'movie']
                : ['movie', 'tv'];
            for (final kind in endpoints) {
              final body = await _getRatingTextUrl(
                Uri.parse(
                  'https://m.douban.com/rexxar/api/v2/$kind/${subject.id}',
                ),
                headers: {
                  'User-Agent': _mobileSafariUa,
                  'Referer': 'https://m.douban.com/movie/subject/${subject.id}/',
                  'Cookie': bidCookie,
                  'Accept': 'application/json, text/plain, */*',
                },
              );
              if (body == null) continue;
              try {
                final decoded = jsonDecode(body);
                if (decoded is Map) {
                  final intro = (decoded['intro'] ?? '').toString().trim();
                  if (intro.length >= 16 &&
                      !_titleSynopsisCache.containsKey(scoped)) {
                    _titleSynopsisCache[scoped] = intro;
                    metadataRevision.value++;
                  }
                  if (decoded['rating'] is Map) {
                    final rawVal = decoded['rating']['value'];
                    final val = rawVal is num
                        ? rawVal.toDouble()
                        : double.tryParse('$rawVal');
                    if (val != null && val >= 2.0 && val <= 10.0) {
                      resolvedDouban = val;
                      break;
                    }
                  }
                }
              } catch (_) {}
            }
          }

          if (resolvedDouban == null && preferredDoubanId.trim().isEmpty) {
            final q = Uri.encodeQueryComponent(
              wantMc ? '$primary 动态漫画' : primary,
            );
            final html = await _getRatingTextUrl(
              Uri.parse('https://m.douban.com/search/?query=$q&type=movie'),
              headers: {
                'User-Agent': _mobileSafariUa,
                'Referer': 'https://m.douban.com/',
                'Cookie': bidCookie,
              },
            );
            if (html != null && html.isNotEmpty) {
              final blockPattern = RegExp(
                r'<a\s+href="/movie/subject/(\d+)/"[^>]*>([\s\S]*?)</a>',
                caseSensitive: false,
              );
              for (final m in blockPattern.allMatches(html)) {
                final inner = m.group(2) ?? '';
                final titleMatch = RegExp(
                  r'<span\s+class="subject-title"[^>]*>([^<]+)</span>',
                  caseSensitive: false,
                ).firstMatch(inner);
                final candTitle = titleMatch?.group(1)?.trim() ?? '';
                if (candTitle.isEmpty ||
                    !_isSameWorkTitle(
                      candTitle,
                      rawTitle,
                      wantMotionComic: wantMc,
                    )) {
                  continue;
                }
                final rMatch = RegExp(
                  r'data-rating="([0-9.]+)"|<span>([2-9]\.[0-9]|10\.0)(?:分)?</span>',
                ).firstMatch(inner);
                final val = double.tryParse(
                  rMatch?.group(1) ?? rMatch?.group(2) ?? '',
                );
                if (val != null && val >= 2.0 && val <= 10.0) {
                  resolvedDouban = val;
                  break;
                }
              }
            }
          }
        }(),

        // 2. Verified Rotten Tomatoes (`烂番茄`) score from cached Baike abstract or Bing snippets
        () async {
          final cachedSyn = _titleSynopsisCache[scoped] ?? '';
          if (cachedSyn.isNotEmpty) {
            final synMatch = RegExp(
              r'(?:烂番茄(?:新鲜度|指数|好评率|评分)?|新鲜度|Tomatometer|Rotten\s*Tomatoes)\s*[:：为是达]?\s*(\d{1,3})\s*%|(\d{1,3})\s*%\s*(?:的)?(?:烂番茄|新鲜度)',
              caseSensitive: false,
            ).firstMatch(cachedSyn);
            final pct = int.tryParse(
              synMatch?.group(1) ?? synMatch?.group(2) ?? '',
            );
            if (pct != null && pct >= 1 && pct <= 100) {
              resolvedRt = pct;
              return;
            }
          }

          final yearHint = targetYear != null ? '$targetYear ' : '';
          final q = Uri.encodeQueryComponent('"$primary" ${yearHint}烂番茄 新鲜度');
          final html = await _getRatingTextUrl(
            Uri.parse('https://cn.bing.com/search?q=$q'),
            headers: {
              'User-Agent': _desktopChromeUa,
              'Referer': 'https://cn.bing.com/',
              'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
            },
            timeout: const Duration(milliseconds: 2400),
          );
          if (html != null && html.isNotEmpty) {
            resolvedRt = extractRtPercentFromBingHtml(
              html,
              clean,
              targetYear: targetYear,
            );
          }
        }(),
      ]);

      final entry = (douban: resolvedDouban, rt: resolvedRt);
      while (_ratingsCache.length >= 160) {
        _ratingsCache.remove(_ratingsCache.keys.first);
      }
      _ratingsCache[cacheKey] = entry;
      if (cacheKey != scoped) {
        _ratingsCache[scoped] = entry;
      }
      if (resolvedDouban != null || resolvedRt != null) {
        metadataRevision.value++;
      }
      return entry;
    }().whenComplete(() {
      _inflightRatings.remove(cacheKey);
    });

    _inflightRatings[cacheKey] = future;
    return future;
  }

  /// Returns cached or fetched series synopsis from Douban / Bangumi / Baidu Baike,
  /// preserving release year embedded in [rawTitle] and work-form (`动态漫画` vs
  /// regular anime).
  static Future<String> fetchSeriesSynopsis(
    String rawTitle, {
    String year = '',
    bool? wantMotionComic,
  }) async {
    final clean = _cleanTitle(rawTitle);
    if (clean.isEmpty) return '';
    final targetYear = _extractTargetYear(rawTitle, year);
    final wantMc = wantMotionComic ?? _isMotionComicTitle(rawTitle);
    final scoped = _scopedTitleToken(clean, targetYear, isMotionComic: wantMc);
    final cached = _titleSynopsisCache[scoped];
    if (cached != null && cached.isNotEmpty) return cached;
    final resolvedYear = year.isNotEmpty ? year : (targetYear?.toString() ?? '');
    await _resolveCoverUrlsByTitle(
      rawTitle,
      year: resolvedYear,
      wantMotionComic: wantMc,
    );
    final afterCover = _titleSynopsisCache[scoped] ?? '';
    if (afterCover.isNotEmpty) return afterCover;

    // Fallback: fetch official Douban `intro` from the verified subject so
    // works whose Baidu Baike default lemma is a different medium (e.g. 2018
    // dynamic comic for `斗罗大陆2：绝世唐门2023`) still receive their true synopsis.
    final subject = _doubanSubjectIdCache[scoped] ??
        await _lookupDoubanSubject(
          rawTitle,
          year: resolvedYear,
          wantMotionComic: wantMc,
        ).then((s) => s == null ? null : (id: s.id, isTv: s.isTv));
    if (subject != null) {
      final bidCookie = 'bid=${_randomDoubanBid()}';
      final endpoints = subject.isTv ? ['tv', 'movie'] : ['movie', 'tv'];
      for (final kind in endpoints) {
        final body = await _getRatingTextUrl(
          Uri.parse(
            'https://m.douban.com/rexxar/api/v2/$kind/${subject.id}',
          ),
          headers: {
            'User-Agent': _mobileSafariUa,
            'Referer': 'https://m.douban.com/movie/subject/${subject.id}/',
            'Cookie': bidCookie,
            'Accept': 'application/json, text/plain, */*',
          },
        );
        if (body == null) continue;
        try {
          final decoded = jsonDecode(body);
          if (decoded is Map) {
            final intro = (decoded['intro'] ?? '').toString().trim();
            if (intro.length >= 16) {
              _titleSynopsisCache[scoped] = intro;
              metadataRevision.value++;
              return intro;
            }
          }
        } catch (_) {}
      }
    }
    return _titleSynopsisCache[scoped] ?? '';
  }

  static String _episodeCacheKey(String clean, bool wantMotionComic) {
    return wantMotionComic ? '$clean#mc' : clean;
  }

  /// Synchronously peeks cached real metadata for 1-based [episodeNumber].
  static EpisodeRealMeta? peekEpisodeMeta(
    String rawTitle,
    int episodeNumber, {
    bool? wantMotionComic,
  }) {
    final clean = _cleanTitle(rawTitle);
    if (clean.isEmpty) return null;
    final wantMc = wantMotionComic ?? _isMotionComicTitle(rawTitle);
    final key = _episodeCacheKey(clean, wantMc);
    return _seriesEpisodeMetaCache[key]?[episodeNumber];
  }

  /// Synchronously peeks all cached real episode metadata for [rawTitle].
  static Map<int, EpisodeRealMeta> peekAllEpisodeMeta(
    String rawTitle, {
    bool? wantMotionComic,
  }) {
    final clean = _cleanTitle(rawTitle);
    if (clean.isEmpty) return const {};
    final wantMc = wantMotionComic ?? _isMotionComicTitle(rawTitle);
    final key = _episodeCacheKey(clean, wantMc);
    return _seriesEpisodeMetaCache[key] ?? const {};
  }

  /// Returns cached per-episode scene captions if available.
  static List<String> peekSeriesEpisodeCaptions(
    String rawTitle, {
    bool? wantMotionComic,
  }) {
    final clean = _cleanTitle(rawTitle);
    if (clean.isEmpty) return const [];
    final wantMc = wantMotionComic ?? _isMotionComicTitle(rawTitle);
    final key = _episodeCacheKey(clean, wantMc);
    return _seriesEpisodeCaptionsCache[key] ?? const [];
  }

  /// Resolves real per-episode plot summaries (`分集剧情`), real episode titles,
  /// and real 16:9 episode frame covers from:
  /// 1. 360 Baike `tvplot` (`baike.so.com` structured `<dl><dt>第X集</dt><dd>...</dd>`)
  /// 2. Bilibili PGC (`api.bilibili.com/x/web-interface/search/type` `media_bangumi` & `media_ft`)
  /// 3. Bangumi Official Open API (`api.bgm.tv/v0/episodes`)
  static Future<Map<int, EpisodeRealMeta>> fetchSeriesEpisodeMetadata(
    String rawTitle, {
    String year = '',
    bool? wantMotionComic,
  }) {
    final clean = _cleanTitle(rawTitle);
    if (clean.isEmpty) {
      return SynchronousFuture<Map<int, EpisodeRealMeta>>(const {});
    }
    final targetYear = _extractTargetYear(rawTitle, year);
    final wantMc = wantMotionComic ?? _isMotionComicTitle(rawTitle);
    final scoped = _scopedTitleToken(clean, targetYear, isMotionComic: wantMc);
    final epCacheKey = _episodeCacheKey(clean, wantMc);
    final cached = _seriesEpisodeMetaCache[epCacheKey];
    if (cached != null && cached.isNotEmpty) {
      return SynchronousFuture<Map<int, EpisodeRealMeta>>(cached);
    }
    final pending = _inflightEpisodeMeta[scoped];
    if (pending != null) return pending;

    final future = () async {
      final result = <int, EpisodeRealMeta>{};
      void upsert(
        int epNum, {
        String? title,
        String? summary,
        String? coverUrl,
      }) {
        if (epNum <= 0) return;
        final existing = result[epNum] ?? EpisodeRealMeta(episodeNumber: epNum);
        result[epNum] = existing.mergeWith(
          title: title,
          summary: summary,
          coverUrl: coverUrl,
        );
      }

      final variants = _queryVariantsForTitle(clean);
      final primary = variants.isNotEmpty ? variants.first : clean;

      await Future.wait([
        // Source 1: 360 Baike `tvplot` (Real per-episode titles & plot summaries)
        () async {
          final searchQueries = <String>[
            '$primary 分集剧情',
            primary,
            if (variants.length >= 2) '${variants[1]} 分集剧情',
          ];
          for (final sq in searchQueries) {
            if (result.length >= 5) break;
            HttpClientRequest? req;
            try {
              final uri = Uri.parse(
                'https://baike.so.com/search/?q=${Uri.encodeQueryComponent(sq)}',
              );
              req = await _client
                  .getUrl(uri)
                  .timeout(const Duration(milliseconds: 2800));
              req.headers.set('User-Agent', _desktopChromeUa);
              req.headers.set('Accept', 'text/html,*/*;q=0.8');
              final resp = await req
                  .close()
                  .timeout(const Duration(milliseconds: 2800));
              if (resp.statusCode >= 200 && resp.statusCode < 300) {
                final searchHtml = await utf8.decoder
                    .bind(resp)
                    .join()
                    .timeout(const Duration(milliseconds: 2800));
                final docLinks = RegExp(
                  r'https?://baike\.so\.com/doc/\d+-\d+\.html',
                )
                    .allMatches(searchHtml)
                    .map((m) => m.group(0)!)
                    .toSet()
                    .take(2)
                    .toList();
                for (final docUrl in docLinks) {
                  await _parse360BaikeDoc(
                    docUrl,
                    rawTitle,
                    upsert,
                    targetYear: targetYear,
                    wantMotionComic: wantMc,
                  );
                  if (result.isNotEmpty) break;
                }
              } else {
                await resp.drain<void>();
              }
            } catch (_) {
              try {
                req?.abort();
              } catch (_) {}
            }
          }
        }(),

        // Source 2: Bilibili PGC Search (`media_bangumi` & `media_ft`) for real 16:9 episode covers & titles
        () async {
          for (final stype in const ['media_bangumi', 'media_ft']) {
            for (final qv in variants.take(2)) {
              HttpClientRequest? req;
              try {
                final biliQuery = wantMc ? '$qv 动态漫画' : qv;
                final uri = Uri.parse(
                  'https://api.bilibili.com/x/web-interface/search/type?search_type=$stype&keyword=${Uri.encodeQueryComponent(biliQuery)}',
                );
                req = await _client
                    .getUrl(uri)
                    .timeout(const Duration(milliseconds: 2800));
                req.headers.set('User-Agent', _desktopChromeUa);
                req.headers.set('Referer', 'https://search.bilibili.com/');
                req.headers.set('Cookie', _biliCookie);
                req.headers.set('Accept', 'application/json, text/plain, */*');
                final resp = await req
                    .close()
                    .timeout(const Duration(milliseconds: 2800));
                if (resp.statusCode >= 200 && resp.statusCode < 300) {
                  final body = await utf8.decoder
                      .bind(resp)
                      .join()
                      .timeout(const Duration(milliseconds: 2800));
                  final decoded = jsonDecode(body);
                  if (decoded is Map) {
                    final data = decoded['data'];
                    final list = data is Map ? data['result'] : null;
                    if (list is List && list.isNotEmpty) {
                      Map? matchedItem;
                      for (final item in list) {
                        if (item is Map) {
                          final rawItemTitle =
                              (item['title'] ?? '').toString().trim();
                          final styles =
                              (item['styles'] ?? '').toString().trim();
                          final desc = (item['desc'] ?? '').toString().trim();
                          if (!_isSameWorkTitle(
                            rawItemTitle,
                            rawTitle,
                            wantMotionComic: wantMc,
                            candidateContext: '$styles $desc',
                          )) {
                            continue;
                          }
                          if (targetYear != null && item['pubtime'] is num) {
                            final secs = (item['pubtime'] as num).toInt();
                            if (secs > 0) {
                              final pubYear =
                                  DateTime.fromMillisecondsSinceEpoch(
                                secs * 1000,
                              ).year;
                              if ((pubYear - targetYear).abs() >= 2) {
                                continue;
                              }
                            }
                          }
                          matchedItem = item;
                          break;
                        }
                      }
                      if (matchedItem != null) {
                        final evaluate =
                            (matchedItem['desc'] ?? '').toString().trim();
                        if (evaluate.length >= 16 &&
                            !_titleSynopsisCache.containsKey(scoped)) {
                          _titleSynopsisCache[scoped] = evaluate;
                        }
                        final eps = matchedItem['eps'];
                        if (eps is List && eps.isNotEmpty) {
                          for (int i = 0; i < eps.length; i++) {
                            final ep = eps[i];
                            if (ep is Map) {
                              final rawIdx =
                                  (ep['title'] ?? ep['index_title'] ?? '')
                                      .toString()
                                      .trim();
                              final parsedNum = int.tryParse(
                                    RegExp(r'\d+')
                                            .firstMatch(rawIdx)
                                            ?.group(0) ??
                                        '',
                                  ) ??
                                  (i + 1);
                              final longTitle = (ep['long_title'] ?? '')
                                  .toString()
                                  .replaceAll(RegExp(r'<[^>]+>'), '')
                                  .trim();
                              final cover = upgradeUrlToHd(
                                (ep['cover'] ?? '').toString().trim(),
                              );
                              upsert(
                                parsedNum,
                                title: longTitle,
                                coverUrl: cover,
                              );
                            }
                          }
                          break;
                        }
                      }
                    }
                  }
                } else {
                  await resp.drain<void>();
                }
              } catch (_) {
                try {
                  req?.abort();
                } catch (_) {}
              }
            }
          }
        }(),

        // Source 3: Bangumi Official API (`/search/subject` + `/v0/episodes`)
        () async {
          HttpClientRequest? req;
          try {
            final q = Uri.encodeQueryComponent(
              wantMc ? '$primary 动态漫画' : primary,
            );
            final uri = Uri.parse(
              'https://api.bgm.tv/search/subject/$q?responseGroup=large',
            );
            req = await _client
                .getUrl(uri)
                .timeout(const Duration(milliseconds: 2800));
            req.headers.set('User-Agent', _desktopChromeUa);
            req.headers.set('Accept', 'application/json');
            final resp =
                await req.close().timeout(const Duration(milliseconds: 2800));
            if (resp.statusCode >= 200 && resp.statusCode < 300) {
              final body = await utf8.decoder
                  .bind(resp)
                  .join()
                  .timeout(const Duration(milliseconds: 2800));
              final decoded = jsonDecode(body);
              if (decoded is Map && decoded['list'] is List) {
                final list = decoded['list'] as List;
                Map? matchedSubject;
                for (final item in list) {
                  if (item is Map) {
                    final t = item['type'];
                    if (t != 2 && t != 6) continue;
                    final nameCn = (item['name_cn'] ?? '').toString().trim();
                    final name = (item['name'] ?? '').toString().trim();
                    final summary = (item['summary'] ?? '').toString().trim();
                    if (!_isSameWorkTitle(
                          nameCn,
                          rawTitle,
                          wantMotionComic: wantMc,
                          candidateContext: '$name $summary',
                        ) &&
                        !_isSameWorkTitle(
                          name,
                          rawTitle,
                          wantMotionComic: wantMc,
                          candidateContext: '$nameCn $summary',
                        )) {
                      continue;
                    }
                    if (targetYear != null) {
                      final airDate =
                          (item['air_date'] ?? '').toString().trim();
                      final airYearMatch =
                          RegExp(r'^((?:19|20)\d{2})').firstMatch(airDate);
                      if (airYearMatch != null) {
                        final airYear = int.tryParse(airYearMatch.group(1)!);
                        if (airYear != null &&
                            (airYear - targetYear).abs() >= 2) {
                          continue;
                        }
                      }
                    }
                    matchedSubject = item;
                    break;
                  }
                }
                if (matchedSubject != null) {
                  final summary =
                      (matchedSubject['summary'] ?? '').toString().trim();
                  if (summary.length >= 16 &&
                      !_titleSynopsisCache.containsKey(scoped)) {
                    _titleSynopsisCache[scoped] = summary;
                  }
                  final sid = matchedSubject['id'];
                  if (sid != null) {
                    await _fetchBangumiEpisodes(sid, upsert);
                  }
                }
              }
            } else {
              await resp.drain<void>();
            }
          } catch (_) {
            try {
              req?.abort();
            } catch (_) {}
          }
        }(),
      ]);

      if (result.isNotEmpty) {
        _seriesEpisodeMetaCache[epCacheKey] = result;
      }
      metadataRevision.value++;
      return result;
    }()
        .whenComplete(() { _inflightEpisodeMeta.remove(scoped); });

    _inflightEpisodeMeta[scoped] = future;
    return future;
  }

  static Future<void> _fetchBangumiEpisodes(
    Object subjectId,
    void Function(int, {String? title, String? summary, String? coverUrl})
        upsert,
  ) async {
    HttpClientRequest? req;
    try {
      final uri = Uri.parse(
        'https://api.bgm.tv/v0/episodes?subject_id=$subjectId&limit=100&offset=0',
      );
      req = await _client
          .getUrl(uri)
          .timeout(const Duration(milliseconds: 2600));
      req.headers.set('User-Agent', _desktopChromeUa);
      req.headers.set('Accept', 'application/json');
      final resp =
          await req.close().timeout(const Duration(milliseconds: 2600));
      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        final body = await utf8.decoder
            .bind(resp)
            .join()
            .timeout(const Duration(milliseconds: 2600));
        final decoded = jsonDecode(body);
        if (decoded is Map && decoded['data'] is List) {
          final eps = decoded['data'] as List;
          for (int i = 0; i < eps.length; i++) {
            final ep = eps[i];
            if (ep is Map) {
              final epNum = (ep['ep'] is int && (ep['ep'] as int) > 0)
                  ? ep['ep'] as int
                  : ((ep['sort'] is num && (ep['sort'] as num) > 0)
                      ? (ep['sort'] as num).toInt()
                      : (i + 1));
              final nameCn = (ep['name_cn'] ?? '').toString().trim();
              final name = (ep['name'] ?? '').toString().trim();
              final desc = (ep['desc'] ?? '').toString().trim();
              upsert(
                epNum,
                title: nameCn.isNotEmpty ? nameCn : name,
                summary: desc.length >= 8 ? desc : null,
              );
            }
          }
        }
      } else {
        await resp.drain<void>();
      }
    } catch (_) {
      try {
        req?.abort();
      } catch (_) {}
    }
  }

  static Future<void> _parse360BaikeDoc(
    String docUrl,
    String rawTitle,
    void Function(int, {String? title, String? summary, String? coverUrl})
        upsert, {
    int? targetYear,
    bool wantMotionComic = false,
  }) async {
    HttpClientRequest? req;
    try {
      final uri = Uri.parse(
        docUrl.startsWith('http://')
            ? docUrl.replaceFirst('http://', 'https://')
            : docUrl,
      );
      req = await _client
          .getUrl(uri)
          .timeout(const Duration(milliseconds: 3000));
      req.headers.set('User-Agent', _desktopChromeUa);
      req.headers.set('Accept', 'text/html,*/*;q=0.8');
      final resp =
          await req.close().timeout(const Duration(milliseconds: 3000));
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        await resp.drain<void>();
        return;
      }
      final doc = await utf8.decoder
          .bind(resp)
          .join()
          .timeout(const Duration(milliseconds: 3000));

      // Verify that this 360 Baike document is actually for [rawTitle]
      // (prevents variety shows or mismatched motion comics from polluting plots)
      final titleTagMatch =
          RegExp(r'<title>(.*?)</title>', dotAll: true).firstMatch(doc);
      final h1Match =
          RegExp(r'<h1[^>]*>(.*?)</h1>', dotAll: true).firstMatch(doc);
      final docTitleText =
          (titleTagMatch?.group(1) ?? h1Match?.group(1) ?? '').trim();
      final docLead = doc.length > 2500 ? doc.substring(0, 2500) : doc;
      if (docTitleText.isEmpty ||
          !_isSameWorkTitle(
            docTitleText,
            rawTitle,
            wantMotionComic: wantMotionComic,
            candidateContext: docLead,
          )) {
        return;
      }
      final tvplotIdx = doc.indexOf('id=tvplot');
      if (tvplotIdx < 0 &&
          !_isFilmOrTvEntryText(
            docLead,
            targetYear: targetYear,
            wantMotionComic: wantMotionComic,
          )) {
        return;
      }

      // Collect anti-scrape hidden CSS class names from <style> blocks
      final hiddenClasses = <String>{};
      final styleBlocks = RegExp(
        r'<style[^>]*>(.*?)</style>',
        dotAll: true,
      ).allMatches(doc);
      for (final sb in styleBlocks) {
        final css = sb.group(1) ?? '';
        for (final rule in css.split('}')) {
          if (rule.contains('display:none') ||
              rule.contains('font-size: 0') ||
              rule.contains('font-size:0') ||
              rule.contains('height:0') ||
              rule.contains('width:0') ||
              rule.contains('visibility:hidden') ||
              rule.contains('opacity:0')) {
            final selectorPart = rule.split('{').first;
            for (final cm
                in RegExp(r'\.([a-zA-Z0-9_-]+)').allMatches(selectorPart)) {
              hiddenClasses.add(cm.group(1)!);
            }
          }
        }
      }

      String cleanBaikeFragment(String frag) {
        var cur = frag;
        String? prev;
        final tagPattern = RegExp(
          r'<(span|em|b|strong|i)\s+class=["\x27]?([a-zA-Z0-9_-]+)["\x27]?[^>]*>(.*?)</\1>',
          dotAll: true,
        );
        int guard = 0;
        while (prev != cur && guard < 6) {
          prev = cur;
          guard++;
          cur = cur.replaceAllMapped(tagPattern, (m) {
            final cls = m.group(2)!;
            final inner = m.group(3)!;
            return hiddenClasses.contains(cls) ? '' : inner;
          });
        }
        return cur
            .replaceAll(RegExp(r'<[^>]+>'), '')
            .replaceAll('&nbsp;', ' ')
            .replaceAll('&quot;', '"')
            .replaceAll('&amp;', '&')
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();
      }

      final plotRegion = tvplotIdx >= 0 ? doc.substring(tvplotIdx) : doc;
      final dlMatches = RegExp(
        r'<dt>(.*?)</dt>\s*<dd>(.*?)</dd>',
        dotAll: true,
      ).allMatches(plotRegion);

      for (final dm in dlMatches) {
        final dtText = cleanBaikeFragment(dm.group(1) ?? '');
        final ddText = cleanBaikeFragment(dm.group(2) ?? '');
        final epMatch =
            RegExp(r'第\s*(\d+)\s*集\s*(.*)$').firstMatch(dtText);
        if (epMatch != null && ddText.length >= 12) {
          final epNum = int.tryParse(epMatch.group(1)!) ?? 0;
          final epSubTitle = epMatch
              .group(2)!
              .replaceAll(RegExp(r'^[：:·\-\s]+'), '')
              .trim();
          upsert(
            epNum,
            title: epSubTitle,
            summary: ddText,
          );
        }
      }
    } catch (_) {
      try {
        req?.abort();
      } catch (_) {}
    }
  }

  /// Resolves up to 35 distinct 16:9 widescreen scene stills (`剧照 / 画面`)
  /// for [rawTitle] so each episode card in the horizontal episode strip shows
  /// a distinct scene frame from the drama instead of repeating the main cover.
  static Future<List<String>> fetchSeriesEpisodeStills(
    String rawTitle, {
    String year = '',
    bool? wantMotionComic,
  }) {
    final clean = _cleanTitle(rawTitle);
    if (clean.isEmpty) return SynchronousFuture<List<String>>(const []);
    final targetYear = _extractTargetYear(rawTitle, year);
    final wantMc = wantMotionComic ?? _isMotionComicTitle(rawTitle);
    final scoped = _scopedTitleToken(clean, targetYear, isMotionComic: wantMc);
    final epCacheKey = _episodeCacheKey(clean, wantMc);
    final cached = _seriesEpisodeStillsCache[epCacheKey];
    if (cached != null && cached.isNotEmpty) {
      return SynchronousFuture<List<String>>(cached);
    }
    final pending = _inflightSeriesStills[scoped];
    if (pending != null) return pending;

    final future = () async {
      // Also kick off real episode metadata resolution in parallel
      unawaited(
        fetchSeriesEpisodeMetadata(
          rawTitle,
          year: year,
          wantMotionComic: wantMc,
        ),
      );

      final stills = <String>[];
      final captions = <String>[];
      final seenUrls = <String>{};
      final seenCoreIds = <String>{};
      final variants = _queryVariantsForTitle(clean);
      final primaryQuery = variants.isNotEmpty ? variants.first : clean;
      final yearHint = targetYear != null ? '$targetYear ' : '';
      final queries = wantMc
          ? <String>[
              '"$primaryQuery" 动态漫画 ${yearHint}剧照 画面 -节气 -模板 -素材 -主播',
            ]
          : <String>[
              '"$primaryQuery" ${yearHint}电视剧 剧照 画面 -动态漫画 -动态漫 -节气 -模板 -素材 -主播 -成语',
              if (variants.length >= 2)
                '"${variants[1]}" ${yearHint}剧照 画面 -动态漫画 -动态漫 -节气 -模板 -素材 -主播 -成语',
            ];

      for (final qText in queries) {
        if (stills.length >= 28) break;
        HttpClientRequest? req;
        try {
          final q = Uri.encodeQueryComponent(qText);
          final uri = Uri.parse(
            'https://cn.bing.com/images/async?q=$q&first=1&count=35&qft=+filterui:aspect-wide',
          );
          req = await _client
              .getUrl(uri)
              .timeout(const Duration(milliseconds: 2800));
          req.headers.set('User-Agent', _desktopChromeUa);
          req.headers.set('Referer', 'https://cn.bing.com/');
          req.headers.set(
            'Accept',
            'text/html,application/xhtml+xml,*/*;q=0.8',
          );
          final resp =
              await req.close().timeout(const Duration(milliseconds: 2800));
          if (resp.statusCode >= 200 && resp.statusCode < 300) {
            final html = await utf8.decoder
                .bind(resp)
                .join()
                .timeout(const Duration(milliseconds: 2800));
            // Parse each Bing image card (`m="{...}"`) so we can verify its caption
            // before accepting its OIP or murl still
            final cardMatches = RegExp(
              r'm=(?:"|&quot;)(\{[^"]*?\})(?:"|&quot;)',
            ).allMatches(html);
            for (final cm in cardMatches) {
              final cardJsonAttr = cm.group(1) ?? '';
              final tMatch = RegExp(
                r't&quot;:&quot;([^&]{2,80})&quot;',
              ).firstMatch(cardJsonAttr);
              final rawCap = (tMatch?.group(1) ?? '')
                  .replaceAll(RegExp(r'[\u0000-\u001f]'), '')
                  .trim();
              final murlMatch = RegExp(
                r'murl&quot;:&quot;(https?://[^&"\x27]+?)&quot;',
              ).firstMatch(cardJsonAttr);
              final rawMurl =
                  murlMatch != null ? upgradeUrlToHd(murlMatch.group(1)!) : '';
              if (!matchesBingLandscapeCaption(
                    rawCap,
                    clean,
                    targetYear: targetYear,
                    wantMotionComic: wantMc,
                    imageUrl: rawMurl,
                  ) ||
                  _isNonEntertainmentBingCaption(cardJsonAttr)) {
                continue;
              }
              final oipMatch = RegExp(
                r'OIP(?:-C)?\.([A-Za-z0-9_-]+)',
              ).firstMatch(cardJsonAttr);
              if (oipMatch != null) {
                final fullId = oipMatch.group(0)!;
                final coreId = oipMatch.group(1)!;
                if (!RegExp(r'Ha[KNLMP][A-Za-z0-9]$').hasMatch(coreId) &&
                    seenCoreIds.add(coreId)) {
                  final u =
                      'https://tse1-mm.cn.bing.net/th/id/$fullId?w=640&h=360&c=7&r=0&o=5&pid=1.7';
                  if (seenUrls.add(u)) {
                    stills.add(u);
                  }
                }
              }
              if (rawMurl.isNotEmpty &&
                  !isPersonOrAvatarImageUrl(rawMurl) &&
                  _isFastDomesticHost(rawMurl) &&
                  seenUrls.add(rawMurl)) {
                stills.add(rawMurl);
              }
              final cleanCap = rawCap.replaceAll(RegExp(r'[_｜|—\-].*$'), '').trim();
              if (cleanCap.length >= 4 && !captions.contains(cleanCap)) {
                captions.add(cleanCap);
              }
            }
          } else {
            await resp.drain<void>();
          }
        } catch (_) {
          try {
            req?.abort();
          } catch (_) {}
        }
      }

      if (captions.isNotEmpty) {
        _seriesEpisodeCaptionsCache[epCacheKey] = captions;
      }
      if (stills.isNotEmpty) {
        _seriesEpisodeStillsCache[epCacheKey] = stills;
      }
      metadataRevision.value++;
      return stills;
    }()
        .whenComplete(() { _inflightSeriesStills.remove(scoped); });

    _inflightSeriesStills[scoped] = future;
    return future;
  }

  static bool _isKnownDeadPosterHost(String url) {
    final lower = url.toLowerCase();
    return lower.contains('mdzypic.com') ||
        lower.contains('pic.ry-pic.com') ||
        lower.contains('macci.cc');
  }

  static bool _isFastDomesticHost(String url) {
    final lower = url.toLowerCase();
    return lower.contains('doubanio.com') ||
        lower.contains('lain.bgm.tv') ||
        lower.contains('bcebos.com') ||
        lower.contains('hdslb.com') ||
        lower.contains('biliimg.com') ||
        lower.contains('qpic.cn') ||
        lower.contains('sinaimg.cn') ||
        lower.contains('bing.net') ||
        lower.contains('tuxiaobei.com');
  }

  static Future<Uint8List> _loadUncached(
    String rawUrl,
    String rawTitle,
    String cacheKey, {
    String year = '',
  }) async {
    final cleanTitle = _cleanTitle(rawTitle);
    final targetYear = _extractTargetYear(rawTitle, year);
    final wantMc = _isMotionComicTitle(rawTitle);
    final scopedTitle = _scopedTitleToken(
      cleanTitle,
      targetYear,
      isMotionComic: wantMc,
    );
    final titleCacheKey = scopedTitle.isNotEmpty ? 'title:$scopedTitle' : '';
    final hdTitleKey = scopedTitle.isNotEmpty ? 'title_hd:$scopedTitle' : '';
    final hasLiveUrl = rawUrl.isNotEmpty && !_isKnownDeadPosterHost(rawUrl);

    // 1. When CMS provides a live poster URL, always check & fetch that exact URL
    // first so homonym titles never overwrite an authentic CMS cover.
    final diskFile = await _diskFileFor(cacheKey);
    if (hasLiveUrl) {
      if (diskFile != null) {
        try {
          if (await diskFile.exists()) {
            final bytes = await diskFile.readAsBytes();
            if (_looksLikeImage(bytes)) {
              _remember(cacheKey, bytes);
              return bytes;
            }
          }
        } catch (_) {}
      }
      try {
        final bytes = await _tryPrimaryUrlAttempts(
          rawUrl,
          maxAttempts: cleanTitle.isNotEmpty ? 2 : 4,
          perAttemptTimeout: const Duration(milliseconds: 3400),
        );
        _remember(cacheKey, bytes);
        if (diskFile != null) {
          unawaited(_writeDisk(diskFile, bytes));
        }
        return bytes;
      } catch (e) {
        if (cleanTitle.isNotEmpty) {
          final bytes = await _resolveTitleCoverBytes(
            rawTitle,
            year: year,
            cacheKey: titleCacheKey,
            wantMotionComic: wantMc,
          );
          _remember(cacheKey, bytes);
          return bytes;
        }
        rethrow;
      }
    }

    // 2. Empty or dead CMS URL: resolve from scoped HD/title cache or domestic APIs
    if (hdTitleKey.isNotEmpty) {
      final inMemHd = _memory[hdTitleKey];
      if (inMemHd != null) {
        _remember(cacheKey, inMemHd);
        return inMemHd;
      }
      final hdDiskFile = await _diskFileFor(hdTitleKey);
      if (hdDiskFile != null) {
        try {
          if (await hdDiskFile.exists()) {
            final bytes = await hdDiskFile.readAsBytes();
            if (_looksLikeImage(bytes)) {
              _remember(hdTitleKey, bytes);
              _remember(cacheKey, bytes);
              if (titleCacheKey.isNotEmpty) _remember(titleCacheKey, bytes);
              return bytes;
            }
          }
        } catch (_) {}
      }
    }

    if (titleCacheKey.isNotEmpty) {
      final inMemTitle = _memory[titleCacheKey];
      if (inMemTitle != null) {
        _remember(cacheKey, inMemTitle);
        return inMemTitle;
      }
      final titleDiskFile = await _diskFileFor(titleCacheKey);
      if (titleDiskFile != null) {
        try {
          if (await titleDiskFile.exists()) {
            final bytes = await titleDiskFile.readAsBytes();
            if (_looksLikeImage(bytes)) {
              _remember(cacheKey, bytes);
              _remember(titleCacheKey, bytes);
              return bytes;
            }
          }
        } catch (_) {}
      }
    }

    if (cleanTitle.isNotEmpty) {
      final bytes = await _resolveTitleCoverBytes(
        rawTitle,
        year: year,
        cacheKey: titleCacheKey,
        wantMotionComic: wantMc,
      );
      _remember(cacheKey, bytes);
      if (diskFile != null) {
        unawaited(_writeDisk(diskFile, bytes));
      }
      return bytes;
    }

    throw FormatException('无效的海报地址: $cacheKey');
  }

  static Future<Uint8List> _tryPrimaryUrlAttempts(
    String rawUrl, {
    required int maxAttempts,
    required Duration perAttemptTimeout,
  }) async {
    await _acquire();
    try {
      final attempts = _attemptsFor(rawUrl);
      if (attempts.isEmpty) {
        throw const FormatException('无效的海报地址');
      }
      Object? lastError;
      final count =
          attempts.length < maxAttempts ? attempts.length : maxAttempts;
      for (int i = 0; i < count; i++) {
        final attempt = attempts[i];
        try {
          return await _fetch(
            attempt.$1,
            attempt.$2,
            timeout: perAttemptTimeout,
          );
        } catch (e) {
          lastError = e;
        }
      }
      throw lastError ?? const HttpException('海报请求失败');
    } finally {
      _release();
    }
  }

  /// Deduplicated title-to-bytes resolver.
  static Future<Uint8List> _resolveTitleCoverBytes(
    String rawTitle, {
    String year = '',
    required String cacheKey,
    bool verifiedOnly = false,
    bool? wantMotionComic,
  }) {
    final cleanTitle = _cleanTitle(rawTitle);
    final targetYear = _extractTargetYear(rawTitle, year);
    final wantMc = wantMotionComic ?? _isMotionComicTitle(rawTitle);
    final scoped = _scopedTitleToken(
      cleanTitle,
      targetYear,
      isMotionComic: wantMc,
    );
    final inflightKey = verifiedOnly ? 'verified:$scoped' : scoped;
    final existing = _inflightTitleBytes[inflightKey];
    if (existing != null) return existing;

    final future = () async {
      final urls = await _resolveCoverUrlsByTitle(
        rawTitle,
        year: year.isNotEmpty ? year : (targetYear?.toString() ?? ''),
        verifiedOnly: verifiedOnly,
        wantMotionComic: wantMc,
      );
      Object? lastError;
      for (final candidateUrl in urls) {
        if (isPersonOrAvatarImageUrl(candidateUrl)) continue;
        for (final attempt in _attemptsFor(candidateUrl)) {
          try {
            final bytes = await _fetch(
              attempt.$1,
              attempt.$2,
              timeout: const Duration(milliseconds: 3500),
            );
            final tKey = 'title:$scoped';
            _remember(tKey, bytes);
            if (await isTrueHdPoster(bytes)) {
              _remember('title_hd:$scoped', bytes);
              final hdDisk = await _diskFileFor('title_hd:$scoped');
              if (hdDisk != null) unawaited(_writeDisk(hdDisk, bytes));
            }
            if (cacheKey.isNotEmpty) {
              _remember(cacheKey, bytes);
              final titleDiskFile = await _diskFileFor(cacheKey);
              if (titleDiskFile != null) {
                unawaited(_writeDisk(titleDiskFile, bytes));
              }
            }
            return bytes;
          } catch (e) {
            lastError = e;
          }
        }
      }
      throw lastError ?? Exception('未找到「$cleanTitle」海报');
    }()
        .whenComplete(() { _inflightTitleBytes.remove(inflightKey); });

    _inflightTitleBytes[inflightKey] = future;
    return future;
  }

  /// Resolves candidate 1080p/2K vertical poster URLs for [rawTitle] across:
  /// 1. Bangumi Official Open API (`api.bgm.tv` `images.large` 1080p/2K covers)
  /// 2. Baidu Baike OpenAPI (`BaikeLemmaCardApi` raw `bcebos.com` official covers, film/TV + year + work-form verified)
  /// 3. Bilibili PGC Search (`api.bilibili.com` `media_bangumi` & `media_ft` raw covers, title + year + work-form verified)
  /// 4. Douban Web Search & `subject_suggest` + Rexxar (`l_ratio_poster`, movie/tv + year + work-form verified)
  /// 5. Bing China `cn.bing.com/images/async` original `murl` high-res vertical covers (ONLY when `!verifiedOnly`)
  static Future<List<String>> _resolveCoverUrlsByTitle(
    String rawTitle, {
    String year = '',
    bool forceRefreshHd = false,
    bool verifiedOnly = false,
    bool includeDoubanPosterGallery = false,
    bool? wantMotionComic,
  }) async {
    final cleanTitle = _cleanTitle(rawTitle);
    final targetYear = _extractTargetYear(rawTitle, year);
    final wantMc = wantMotionComic ?? _isMotionComicTitle(rawTitle);
    final scopedKey = _scopedTitleToken(
      cleanTitle,
      targetYear,
      isMotionComic: wantMc,
    );
    if (!forceRefreshHd) {
      if (verifiedOnly) {
        final cachedVerified = _verifiedTitleCoverUrlsCache[scopedKey];
        if (cachedVerified != null && cachedVerified.isNotEmpty) {
          return cachedVerified;
        }
      } else {
        final cached = _titleCoverUrlsCache[scopedKey];
        if (cached != null && cached.isNotEmpty) return cached;
      }
    }

    final primaryHdResults = <String>[];
    final murlHdResults = <String>[];
    final bingOipFallbackResults = <String>[];
    final seen = <String>{};

    void addPrimaryHd(String raw) {
      final hd = upgradeUrlToHd(raw);
      if (hd.startsWith('http') &&
          !isPersonOrAvatarImageUrl(hd) &&
          seen.add(hd)) {
        primaryHdResults.add(hd);
      }
    }

    void addMurlHd(String raw) {
      final hd = upgradeUrlToHd(raw);
      if (hd.startsWith('http') &&
          !isPersonOrAvatarImageUrl(hd) &&
          seen.add(hd)) {
        murlHdResults.add(hd);
      }
    }

    void addBingOip(String raw) {
      final hd = upgradeUrlToHd(raw);
      if (hd.startsWith('http') &&
          !isPersonOrAvatarImageUrl(hd) &&
          seen.add(hd)) {
        bingOipFallbackResults.add(hd);
      }
    }

    final variants = _queryVariantsForTitle(cleanTitle);
    final primary = variants.isNotEmpty ? variants.first : cleanTitle;
    final bidCookie = 'bid=${_randomDoubanBid()}';
    final resolvedYear = year.isNotEmpty ? year : (targetYear?.toString() ?? '');

    await Future.wait([
      // Source 1: Bangumi Official Open API (`api.bgm.tv/search/subject/...`) — 1080p/2K `images.large`
      () async {
        for (final qv in variants.take(2)) {
          if (primaryHdResults.isNotEmpty) break;
          HttpClientRequest? req;
          try {
            final q = Uri.encodeQueryComponent(wantMc ? '$qv 动态漫画' : qv);
            final uri = Uri.parse(
              'https://api.bgm.tv/search/subject/$q?responseGroup=large',
            );
            req = await _client
                .getUrl(uri)
                .timeout(const Duration(milliseconds: 2600));
            req.headers.set('User-Agent', _desktopChromeUa);
            req.headers.set('Accept', 'application/json');
            final resp =
                await req.close().timeout(const Duration(milliseconds: 2600));
            if (resp.statusCode >= 200 && resp.statusCode < 300) {
              final body = await utf8.decoder
                  .bind(resp)
                  .join()
                  .timeout(const Duration(milliseconds: 2600));
              final decoded = jsonDecode(body);
              if (decoded is Map && decoded['list'] is List) {
                final list = decoded['list'] as List;
                for (final item in list) {
                  if (item is Map) {
                    final t = item['type'];
                    // Prefer anime (type=2) and TV/film (type=6), skip books (type=1)
                    if (t != 2 && t != 6) continue;
                    final nameCn = (item['name_cn'] ?? '').toString().trim();
                    final name = (item['name'] ?? '').toString().trim();
                    final summary = (item['summary'] ?? '').toString().trim();
                    if (!_isSameWorkTitle(
                          nameCn,
                          rawTitle,
                          wantMotionComic: wantMc,
                          candidateContext: '$name $summary',
                        ) &&
                        !_isSameWorkTitle(
                          name,
                          rawTitle,
                          wantMotionComic: wantMc,
                          candidateContext: '$nameCn $summary',
                        )) {
                      continue;
                    }
                    if (targetYear != null) {
                      final airDate =
                          (item['air_date'] ?? '').toString().trim();
                      final airYearMatch =
                          RegExp(r'^((?:19|20)\d{2})').firstMatch(airDate);
                      if (airYearMatch != null) {
                        final airYear = int.tryParse(airYearMatch.group(1)!);
                        if (airYear != null &&
                            (airYear - targetYear).abs() >= 2) {
                          continue;
                        }
                      }
                    }
                    final images = item['images'];
                    if (images is Map) {
                      final large = (images['large'] ?? '').toString().trim();
                      if (large.startsWith('http')) {
                        addPrimaryHd(large);
                      }
                    }
                    if (summary.length >= 16 &&
                        !_titleSynopsisCache.containsKey(scopedKey)) {
                      _titleSynopsisCache[scopedKey] = summary;
                      metadataRevision.value++;
                    }
                  }
                }
              }
            } else {
              await resp.drain<void>();
            }
          } catch (_) {
            try {
              req?.abort();
            } catch (_) {}
          }
        }
      }(),

      // Source 2: Baidu Baike OpenAPI LemmaCard (`BaikeLemmaCardApi` raw `bcebos.com` poster + official synopsis)
      // Queries explicit drama/movie keys first and strictly rejects person bios, solar terms & motion-comic mismatches.
      () async {
        final baikeKeys = <String>[
          for (final qv in variants.take(2)) ...[
            if (wantMc) '${qv}动态漫画',
            '${qv}电视剧',
            '${qv}电影',
            qv,
          ],
        ];
        for (final bkKey in baikeKeys) {
          HttpClientRequest? req;
          try {
            final q = Uri.encodeQueryComponent(bkKey);
            final uri = Uri.parse(
              'https://baike.baidu.com/api/openapi/BaikeLemmaCardApi?scope=103&format=json&appid=379020&bk_key=$q&bk_length=600',
            );
            req = await _client
                .getUrl(uri)
                .timeout(const Duration(milliseconds: 2500));
            req.headers.set('User-Agent', _desktopChromeUa);
            req.headers.set('Accept', 'application/json, text/plain, */*');
            final resp =
                await req.close().timeout(const Duration(milliseconds: 2500));
            if (resp.statusCode >= 200 && resp.statusCode < 300) {
              final body = await utf8.decoder
                  .bind(resp)
                  .join()
                  .timeout(const Duration(milliseconds: 2500));
              final decoded = jsonDecode(body);
              if (decoded is Map) {
                final lemmaTitle = (decoded['title'] ?? '')
                    .toString()
                    .replaceAll(RegExp(r'(?:电视剧|电影)$'), '')
                    .trim();
                final abstractText =
                    (decoded['abstract'] ?? '').toString().trim();
                final descText = (decoded['desc'] ?? '').toString().trim();
                final titleMatches = lemmaTitle.isEmpty ||
                    _isSameWorkTitle(
                      lemmaTitle,
                      rawTitle,
                      wantMotionComic: wantMc,
                      candidateContext: '$descText $abstractText',
                    );
                final isFilmOrTv = isFilmOrTvEncyclopediaEntry(
                  abstractText: abstractText,
                  descText: descText,
                  targetYear: targetYear,
                  wantMotionComic: wantMc,
                );
                if (titleMatches &&
                    isFilmOrTv &&
                    abstractText.length >= 18) {
                  _titleSynopsisCache[scopedKey] = abstractText;
                  metadataRevision.value++;
                }
                final rawImg = (decoded['image'] ?? '').toString().trim();
                if (titleMatches &&
                    isFilmOrTv &&
                    rawImg.startsWith('http') &&
                    !isPersonOrAvatarImageUrl(rawImg)) {
                  addPrimaryHd(rawImg);
                  break;
                }
              }
            } else {
              await resp.drain<void>();
            }
          } catch (_) {
            try {
              req?.abort();
            } catch (_) {}
          }
        }
      }(),

      // Source 3: Bilibili PGC Search (`media_bangumi` & `media_ft`) — strict title, work-form & year verification
      () async {
        final biliQuery = wantMc ? '$primary 动态漫画' : primary;
        for (final stype in const ['media_bangumi', 'media_ft']) {
          HttpClientRequest? req;
          try {
            final q = Uri.encodeQueryComponent(biliQuery);
            final uri = Uri.parse(
              'https://api.bilibili.com/x/web-interface/search/type?search_type=$stype&keyword=$q',
            );
            req = await _client
                .getUrl(uri)
                .timeout(const Duration(milliseconds: 2500));
            req.headers.set('User-Agent', _desktopChromeUa);
            req.headers.set('Referer', 'https://search.bilibili.com/');
            req.headers.set('Cookie', _biliCookie);
            req.headers.set('Accept', 'application/json');
            final resp =
                await req.close().timeout(const Duration(milliseconds: 2500));
            if (resp.statusCode >= 200 && resp.statusCode < 300) {
              final body = await utf8.decoder
                  .bind(resp)
                  .join()
                  .timeout(const Duration(milliseconds: 2500));
              final decoded = jsonDecode(body);
              if (decoded is Map) {
                final data = decoded['data'];
                final list = data is Map ? data['result'] : null;
                if (list is List && list.isNotEmpty) {
                  for (final item in list.take(4)) {
                    if (item is Map) {
                      final rawItemTitle = (item['title'] ?? '')
                          .toString()
                          .replaceAll(RegExp(r'<[^>]+>'), '')
                          .trim();
                      final styles = (item['styles'] ?? '').toString().trim();
                      final desc = (item['desc'] ?? '').toString().trim();
                      if (!_isSameWorkTitle(
                        rawItemTitle,
                        rawTitle,
                        wantMotionComic: wantMc,
                        candidateContext: '$styles $desc',
                      )) {
                        continue;
                      }
                      if (targetYear != null && item['pubtime'] is num) {
                        final secs = (item['pubtime'] as num).toInt();
                        if (secs > 0) {
                          final pubYear = DateTime.fromMillisecondsSinceEpoch(
                            secs * 1000,
                          ).year;
                          if ((pubYear - targetYear).abs() >= 2) {
                            continue;
                          }
                        }
                      }
                      final cover = (item['cover'] ?? '').toString().trim();
                      if (cover.isNotEmpty &&
                          !isPersonOrAvatarImageUrl(cover)) {
                        addPrimaryHd(cover);
                      }
                    }
                  }
                }
              }
            } else {
              await resp.drain<void>();
            }
          } catch (_) {
            try {
              req?.abort();
            } catch (_) {}
          }
        }
      }(),

      // Source 4: Unified Douban (`subject_suggest` + Rexxar `search/weixin`) + Poster Gallery (`type=R`)
      () async {
        final matched = await _lookupDoubanSubject(
          rawTitle,
          year: resolvedYear,
          wantMotionComic: wantMc,
          bidCookie: bidCookie,
        );
        if (matched != null && matched.coverUrl.isNotEmpty) {
          addPrimaryHd(matched.coverUrl);
        }

        // Official Douban Poster Gallery (`type=R`): delivers true 1080p/2K
        // theatrical & TV vertical posters (`image.large.url`) sorted by
        // highest pixel resolution for full-bleed Hero surfaces.
        if (includeDoubanPosterGallery || forceRefreshHd) {
          final subject = _doubanSubjectIdCache[scopedKey] ??
              (matched != null ? (id: matched.id, isTv: matched.isTv) : null);
          if (subject != null) {
            final kind = subject.isTv ? 'tv' : 'movie';
            final galleryBody = await _getRatingTextUrl(
              Uri.parse(
                'https://m.douban.com/rexxar/api/v2/$kind/${subject.id}/photos?type=R&start=0&count=6',
              ),
              headers: {
                'User-Agent': _mobileSafariUa,
                'Referer': 'https://m.douban.com/movie/subject/${subject.id}/',
                'Cookie': bidCookie,
                'Accept': 'application/json, text/plain, */*',
              },
            );
            if (galleryBody != null) {
              try {
                final decoded = jsonDecode(galleryBody);
                final photos = decoded is Map ? decoded['photos'] : null;
                if (photos is List) {
                  final galleryCandidates = <({String url, int pixels})>[];
                  for (final p in photos.whereType<Map>()) {
                    final img = p['image'];
                    if (img is! Map) continue;
                    final large = img['large'] ?? img['normal'];
                    if (large is! Map) continue;
                    final w = (large['width'] as num?)?.toInt() ?? 0;
                    final h = (large['height'] as num?)?.toInt() ?? 0;
                    final u = upgradeUrlToHd((large['url'] ?? '').toString());
                    if (u.startsWith('http') &&
                        !isPersonOrAvatarImageUrl(u) &&
                        (w == 0 || (h >= w * 1.05 && w >= 600 && h >= 840))) {
                      galleryCandidates.add((url: u, pixels: w * h));
                    }
                  }
                  galleryCandidates.sort((a, b) => b.pixels.compareTo(a.pixels));
                  // Prepend highest-resolution official gallery posters ahead of covers.
                  for (final entry in galleryCandidates.reversed) {
                    if (seen.add(entry.url)) {
                      primaryHdResults.insert(0, entry.url);
                    }
                  }
                }
              } catch (_) {}
            }
          }
        }
      }(),

      // Source 5: Bing China Original High-Res `murl` Vertical Posters + OIP fallback
      // (Only queried when `!verifiedOnly`, and strictly filtered against solar terms / templates / work-form mismatch)
      if (!verifiedOnly)
        () async {
          HttpClientRequest? req;
          try {
            final yearToken = targetYear != null ? '$targetYear ' : '';
            final queryStr = wantMc
                ? '"$primary" 动态漫画 ${yearToken}官方海报 竖版 -节气 -模板 -素材 -主播'
                : '"$primary" ${yearToken}电视剧 电影 官方海报 竖版 -动态漫画 -动态漫 -节气 -二十四节气 -模板 -素材 -主播 -成语';
            final query = Uri.encodeQueryComponent(queryStr);
            final uri = Uri.parse(
              'https://cn.bing.com/images/async?q=$query&first=0&count=12&qft=+filterui:aspect-tall+filterui:imagesize-large',
            );
            req = await _client
                .getUrl(uri)
                .timeout(const Duration(milliseconds: 2400));
            req.headers.set('User-Agent', _desktopChromeUa);
            req.headers.set('Referer', 'https://cn.bing.com/');
            req.headers.set(
              'Accept',
              'text/html,application/xhtml+xml,*/*;q=0.8',
            );
            final resp =
                await req.close().timeout(const Duration(milliseconds: 2400));
            if (resp.statusCode >= 200 && resp.statusCode < 300) {
              final html = await utf8.decoder
                  .bind(resp)
                  .join()
                  .timeout(const Duration(milliseconds: 2400));
              final cardMatches = RegExp(
                r'm=(?:"|&quot;)(\{[^"]*?\})(?:"|&quot;)',
              ).allMatches(html);
              for (final cm in cardMatches) {
                final cardJsonAttr = cm.group(1) ?? '';
                final tMatch = RegExp(
                  r't&quot;:&quot;([^&]{2,80})&quot;',
                ).firstMatch(cardJsonAttr);
                final rawCap = (tMatch?.group(1) ?? '').trim();
                if (_isNonEntertainmentBingCaption(rawCap) ||
                    _isNonEntertainmentBingCaption(cardJsonAttr) ||
                    !matchesBingPosterCaption(
                      rawCap,
                      cleanTitle,
                      targetYear: targetYear,
                      wantMotionComic: wantMc,
                    )) {
                  continue;
                }
                final mm = RegExp(
                  r'murl&quot;:&quot;(https?://[^&"\x27]+?)&quot;',
                ).firstMatch(cardJsonAttr);
                if (mm != null && murlHdResults.length < 5) {
                  addMurlHd(mm.group(1)!);
                }
                final om = RegExp(
                  r'OIP(?:-C)?\.[A-Za-z0-9_-]+',
                ).firstMatch(cardJsonAttr);
                if (om != null && bingOipFallbackResults.length < 3) {
                  final oipId = om.group(0)!;
                  addBingOip(
                    'https://tse1-mm.cn.bing.net/th/id/$oipId?w=720&h=1080&c=7&r=0&o=5&pid=1.7',
                  );
                }
              }
            } else {
              await resp.drain<void>();
            }
          } catch (_) {
            try {
              req?.abort();
            } catch (_) {}
          }
        }(),
    ]);

    if (primaryHdResults.isNotEmpty) {
      _verifiedTitleCoverUrlsCache[scopedKey] =
          List<String>.unmodifiable(primaryHdResults);
    }
    if (verifiedOnly) {
      return primaryHdResults;
    }

    final results = <String>[
      ...primaryHdResults,
      ...murlHdResults,
      ...bingOipFallbackResults,
    ];
    if (results.isNotEmpty) {
      _titleCoverUrlsCache[scopedKey] = results;
    }
    return results;
  }

  /// Strict caption verifier for vertical HD poster fallback candidates from
  /// Bing China so homonym titles and dynamic-comic mismatches never pollute
  /// official film/TV hero artwork.
  @visibleForTesting
  static bool matchesBingPosterCaption(
    String rawCap,
    String cleanTitle, {
    int? targetYear,
    bool wantMotionComic = false,
  }) {
    final cap = rawCap.trim();
    final title = cleanTitle.trim();
    if (cap.isEmpty || title.isEmpty) return false;
    if (_isNonEntertainmentBingCaption(cap)) return false;
    if (!SeriesScraper.isCompatibleWorkForm(
      targetIsMotionComic: wantMotionComic,
      candidateTitle: cap,
    )) {
      return false;
    }
    if (!wantMotionComic &&
        RegExp(r'荣耀篇|动态漫|A-SOUL创作漫画|有声书|音频', caseSensitive: false)
            .hasMatch(cap)) {
      return false;
    }
    final stripRe = RegExp(r'[\s·:：\-—_《》「」【】“”"\x27!！?？,，.。]');
    final normCap = SeriesScraper.normalizeSequelNumerals(cap)
        .toLowerCase()
        .replaceAll(stripRe, '');
    final normTitle = SeriesScraper.normalizeSequelNumerals(title)
        .toLowerCase()
        .replaceAll(stripRe, '');
    if (normTitle.isEmpty || !normCap.contains(normTitle)) return false;
    if (targetYear != null) {
      final years = RegExp(r'(?<!\d)(19\d{2}|20\d{2})(?!\d)')
          .allMatches(cap)
          .map((m) => int.tryParse(m.group(1)!))
          .whereType<int>()
          .where((y) => y >= 1980 && y <= 2035)
          .toList();
      if (years.isNotEmpty &&
          !years.any((y) => y >= targetYear - 1 && y <= targetYear + 3) &&
          years.every((y) => y <= targetYear - 2)) {
        return false;
      }
    }
    final hasFilmContext = RegExp(
      r'剧|集|电影|电视|海报|定档|官宣|预告|番|动画|动漫|综|主演|饰|导演|影|片|豆瓣|剧照',
    ).hasMatch(cap);
    if (title.length <= 2) {
      if (!hasFilmContext) return false;
      final explicitlyQuoted = cap.contains('《$title》') ||
          cap.contains('「$title」') ||
          cap.contains('【$title】') ||
          cap.contains('“$title”');
      if (!explicitlyQuoted) {
        final escaped = RegExp.escape(title);
        final standalone = RegExp(
          '(?<![\\u4e00-\\u9fff])$escaped(?![\\u4e00-\\u9fff])',
        ).hasMatch(cap);
        if (!standalone) return false;
      }
    }
    return hasFilmContext || normTitle.length >= 4;
  }

  /// Resolves strictly caption-verified high-resolution vertical `murl` poster
  /// URLs from Bing China (`aspect-tall` + `imagesize-large`) when official
  /// film/TV databases did not already supply a Retina hero poster.
  static Future<List<String>> _resolveVerifiedBingVerticalPosterUrls(
    String cleanTitle, {
    int? targetYear,
    bool wantMotionComic = false,
    required bool strictCaptionOnly,
  }) async {
    final variants = _queryVariantsForTitle(cleanTitle);
    final primary = variants.isNotEmpty ? variants.first : cleanTitle;
    if (primary.isEmpty) return const [];
    final yearToken = targetYear != null ? '$targetYear ' : '';
    final queryStr = wantMotionComic
        ? '"$primary" 动态漫画 ${yearToken}官方海报 竖版 -节气 -模板 -素材 -主播'
        : '"$primary" $yearToken官方海报 竖版 电视剧 电影 -动态漫画 -动态漫 -节气 -二十四节气 -模板 -素材 -主播 -成语';
    final query = Uri.encodeQueryComponent(queryStr);
    final uri = Uri.parse(
      'https://cn.bing.com/images/async?q=$query&first=0&count=16&qft=+filterui:aspect-tall+filterui:imagesize-large',
    );
    final out = <String>[];
    final seen = <String>{};
    HttpClientRequest? req;
    try {
      req = await _client
          .getUrl(uri)
          .timeout(const Duration(milliseconds: 2600));
      req.headers.set('User-Agent', _desktopChromeUa);
      req.headers.set('Referer', 'https://cn.bing.com/');
      req.headers.set(
        'Accept',
        'text/html,application/xhtml+xml,*/*;q=0.8',
      );
      final resp =
          await req.close().timeout(const Duration(milliseconds: 2600));
      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        final html = await utf8.decoder
            .bind(resp)
            .join()
            .timeout(const Duration(milliseconds: 2600));
        final cardMatches = RegExp(
          r'm=(?:"|&quot;)(\{[^"]*?\})(?:"|&quot;)',
        ).allMatches(html);
        for (final cm in cardMatches) {
          final cardJsonAttr = cm.group(1) ?? '';
          final tMatch = RegExp(
            r't&quot;:&quot;([^&]{2,100})&quot;',
          ).firstMatch(cardJsonAttr);
          final rawCap = (tMatch?.group(1) ?? '').trim();
          if (_isNonEntertainmentBingCaption(rawCap) ||
              _isNonEntertainmentBingCaption(cardJsonAttr)) {
            continue;
          }
          if (strictCaptionOnly &&
              !matchesBingPosterCaption(
                rawCap,
                cleanTitle,
                targetYear: targetYear,
                wantMotionComic: wantMotionComic,
              )) {
            continue;
          }
          final mm = RegExp(
            r'murl&quot;:&quot;(https?://[^&"\x27]+?)&quot;',
          ).firstMatch(cardJsonAttr);
          if (mm != null) {
            final hd = upgradeUrlToHd(mm.group(1)!);
            if (hd.startsWith('http') &&
                !isPersonOrAvatarImageUrl(hd) &&
                seen.add(hd)) {
              out.add(hd);
              if (out.length >= 6) break;
            }
          }
        }
      } else {
        await resp.drain<void>();
      }
    } catch (_) {
      try {
        req?.abort();
      } catch (_) {}
    }
    return out;
  }

  static Future<void> _acquire() async {
    if (_active < _maxConcurrent) {
      _active++;
      return;
    }
    final waiter = Completer<void>();
    _waiters.add(waiter);
    await waiter.future;
    _active++;
  }

  static void _release() {
    _active--;
    if (_waiters.isNotEmpty) {
      _waiters.removeLast().complete();
    }
  }

  @visibleForTesting
  static void seedMemoryForTest(
    String rawUrl,
    Uint8List bytes, {
    String title = '',
    String year = '',
    bool asHd = false,
  }) {
    final u = upgradeUrlToHd(rawUrl);
    if (u.isNotEmpty && !_isKnownDeadPosterHost(u)) {
      _remember(u, bytes);
      if (asHd) _remember('hd_url:$u', bytes);
    }
    final clean = _cleanTitle(title);
    final scoped = _scopedTitleToken(
      clean,
      _extractTargetYear(title, year),
      isMotionComic: _isMotionComicTitle(title),
    );
    if (scoped.isNotEmpty) {
      _remember('title:$scoped', bytes);
      if (asHd) _remember('title_hd:$scoped', bytes);
    }
  }

  static void _remember(String key, Uint8List bytes) {
    if (key.isEmpty) return;
    final old = _memory.remove(key);
    if (old != null) _memoryBytes -= old.length;
    _memory[key] = bytes;
    _memoryBytes += bytes.length;
    while (_memoryBytes > _maxMemoryBytes && _memory.isNotEmpty) {
      final oldestKey = _memory.keys.first;
      final removed = _memory.remove(oldestKey);
      if (removed != null) _memoryBytes -= removed.length;
    }
    final keyCallbacks = _keyListeners[key];
    if (keyCallbacks != null && keyCallbacks.isNotEmpty) {
      for (final cb in List<VoidCallback>.of(keyCallbacks)) {
        cb();
      }
    }
    cacheRevision.value++;
  }

  /// Builds an ordered list of `(url, headers)` attempts for one poster.
  static List<(String, Map<String, String>)> _attemptsFor(String raw) {
    if (CatPawHost.matches(raw)) return [(raw, const <String,String>{})];
    var url = raw;
    final embedded = <String, String>{};
    final marker = RegExp(r'@(Referer|User-Agent|referer|user-agent)=');
    final matches = marker.allMatches(raw).toList();
    if (matches.isNotEmpty) {
      url = raw.substring(0, matches.first.start);
      for (int i = 0; i < matches.length; i++) {
        final m = matches[i];
        final end = i + 1 < matches.length ? matches[i + 1].start : raw.length;
        final name =
            m.group(1)!.toLowerCase() == 'referer' ? 'Referer' : 'User-Agent';
        final value = raw.substring(m.end, end).trim();
        if (value.isNotEmpty && !value.contains('\n')) embedded[name] = value;
      }
    }
    final originalUrl = url.trim();
    url = upgradeUrlToHd(url);
    final uri = Uri.tryParse(url);
    if (uri == null ||
        !(uri.scheme == 'http' || uri.scheme == 'https') ||
        uri.host.isEmpty) {
      return const [];
    }
    final host = uri.host.toLowerCase();
    final attempts = <(String, Map<String, String>)>[];
    final seen = <String>{};
    void add(String u, Map<String, String> h) {
      final sig = '$u|${h['User-Agent']}|${h['Referer']}';
      if (seen.add(sig)) attempts.add((u, h));
    }

    if (host.endsWith('doubanio.com')) {
      final nodes = <String>[
        if (host != 'img9.doubanio.com') host,
        'img3.doubanio.com',
        'img1.doubanio.com',
        'img2.doubanio.com',
      ];
      for (final node in nodes) {
        final swapped = uri.replace(host: node, scheme: 'https').toString();
        add(swapped, const {
          'User-Agent': _desktopChromeUa,
          'Referer': 'https://movie.douban.com/',
          'Accept': 'image/avif,image/webp,image/apng,image/*,*/*;q=0.8',
        });
        add(swapped, const {
          'User-Agent': _mobileSafariUa,
          'Referer': 'https://m.douban.com/',
          'Accept': 'image/avif,image/webp,image/apng,image/*,*/*;q=0.8',
        });
      }
      if (url.contains('/l_ratio_poster/')) {
        final mUrl = uri
            .replace(
              host: 'img3.doubanio.com',
              scheme: 'https',
              path:
                  uri.path.replaceFirst('/l_ratio_poster/', '/m_ratio_poster/'),
            )
            .toString();
        add(mUrl, const {
          'User-Agent': _desktopChromeUa,
          'Referer': 'https://movie.douban.com/',
          'Accept': 'image/avif,image/webp,image/apng,image/*,*/*;q=0.8',
        });
      }
      return attempts;
    }
    if (host.endsWith('bgm.tv')) {
      add(uri.replace(scheme: 'https').toString(), const {
        'User-Agent': _desktopChromeUa,
        'Referer': 'https://bgm.tv/',
        'Accept': 'image/avif,image/webp,image/apng,image/*,*/*;q=0.8',
      });
      return attempts;
    }
    if (host.endsWith('bcebos.com')) {
      add(uri.replace(scheme: 'https').toString(), const {
        'User-Agent': _desktopChromeUa,
        'Referer': 'https://baike.baidu.com/',
        'Accept': 'image/avif,image/webp,image/apng,image/*,*/*;q=0.8',
      });
      return attempts;
    }
    if (host.endsWith('qpic.cn')) {
      add(uri.replace(scheme: 'https').toString(), const {
        'User-Agent': _desktopChromeUa,
        'Referer': 'https://v.qq.com/',
        'Accept': 'image/avif,image/webp,image/apng,image/*,*/*;q=0.8',
      });
      return attempts;
    }
    if (host.endsWith('sinaimg.cn')) {
      add(uri.replace(scheme: 'https').toString(), const {
        'User-Agent': _desktopChromeUa,
        'Referer': 'https://weibo.com/',
        'Accept': 'image/avif,image/webp,image/apng,image/*,*/*;q=0.8',
      });
      return attempts;
    }
    if (host.endsWith('bing.net')) {
      add(uri.replace(scheme: 'https').toString(), const {
        'User-Agent': _desktopSafariUa,
        'Referer': 'https://cn.bing.com/',
        'Accept': 'image/avif,image/webp,image/apng,image/*,*/*;q=0.8',
      });
      return attempts;
    }
    if (host.endsWith('hdslb.com') ||
        host.endsWith('bilibili.com') ||
        host.endsWith('biliimg.com')) {
      add(uri.replace(scheme: 'https').toString(), const {
        'User-Agent': _desktopChromeUa,
        'Referer': 'https://www.bilibili.com/',
      });
    }
    const accept = 'image/avif,image/webp,image/apng,image/*,*/*;q=0.8';
    final origin =
        '${uri.scheme}://${uri.host}${uri.hasPort ? ':${uri.port}' : ''}/';
    if (embedded.isNotEmpty) {
      add(url, {
        'User-Agent': embedded['User-Agent'] ?? _tvBoxUa,
        if (embedded['Referer'] != null) 'Referer': embedded['Referer']!,
        'Accept': accept,
      });
    }
    add(
      url,
      {'User-Agent': _mobileSafariUa, 'Referer': origin, 'Accept': accept},
    );
    add(url, const {'User-Agent': _tvBoxUa, 'Accept': accept});
    add(url, const {'User-Agent': _desktopSafariUa, 'Accept': accept});
    final altScheme = uri.scheme == 'https' ? 'http' : 'https';
    add(uri.replace(scheme: altScheme).toString(), const {
      'User-Agent': _tvBoxUa,
      'Accept': accept,
    });
    if (originalUrl.isNotEmpty &&
        originalUrl != url &&
        (originalUrl.startsWith('http://') ||
            originalUrl.startsWith('https://'))) {
      add(
        originalUrl,
        {'User-Agent': _mobileSafariUa, 'Referer': origin, 'Accept': accept},
      );
    }
    return attempts;
  }

  static Future<Uint8List> _fetch(
    String url,
    Map<String, String> headers, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    HttpClientRequest? request;
    try {
      if (CatPawHost.matches(url)) url = (await CatPawHost.instance.resolve(url)).toString();
      final privateImage = EmbyLibrary.isImage(url);
      final scopedHeaders = privateImage ? await EmbyLibrary.imageHeaders(url) : const <String,String>{};
      request = await _client.getUrl(Uri.parse(url).removeFragment()).timeout(timeout);
      request.followRedirects = !privateImage;
      request.maxRedirects = 6;
      headers.forEach((k, v) => request!.headers.set(k, v));
      scopedHeaders.forEach((k,v) => request!.headers.set(k,v));
      final response = await request.close().timeout(timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        await response.drain<void>();
        throw HttpException(
          'HTTP ${response.statusCode}',
          uri: Uri.tryParse(url),
        );
      }
      final builder = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(timeout)) {
        builder.add(chunk);
        if (builder.length > _maxImageBytes) {
          throw const HttpException('图片超过大小上限');
        }
      }
      final bytes = builder.takeBytes();
      if (!_looksLikeImage(bytes)) {
        throw const FormatException('服务器返回的不是图片');
      }
      return bytes;
    } catch (e) {
      try {
        request?.abort();
      } catch (_) {}
      rethrow;
    }
  }

  static bool _looksLikeImage(Uint8List b) {
    if (b.length < 12) return false;
    if (b[0] == 0xFF && b[1] == 0xD8) return true; // JPEG
    if (b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) {
      return true; // PNG
    }
    if (b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46) return true; // GIF
    if (b[0] == 0x52 &&
        b[1] == 0x49 &&
        b[2] == 0x46 &&
        b[3] == 0x46 &&
        b[8] == 0x57 &&
        b[9] == 0x45 &&
        b[10] == 0x42 &&
        b[11] == 0x50) {
      return true; // WEBP
    }
    if (b[0] == 0x42 && b[1] == 0x4D) return true; // BMP
    if (b[4] == 0x66 && b[5] == 0x74 && b[6] == 0x79 && b[7] == 0x70) {
      return true; // AVIF/HEIC
    }
    return false;
  }

  static Future<File?> _diskFileFor(String key) async {
    if (!_diskReady) {
      _diskReady = true;
      try {
        final dir = Directory(
          '${Directory.systemTemp.path}${Platform.pathSeparator}marco_poster_cache_v6',
        );
        if (!await dir.exists()) await dir.create(recursive: true);
        _diskDir = dir;
      } catch (_) {
        _diskDir = null;
      }
      if (!_legacyDiskCleaned) {
        _legacyDiskCleaned = true;
        unawaited(() async {
          for (final legacy in const [
            'marco_poster_cache_v5',
            'marco_poster_cache_v4',
          ]) {
            try {
              final legacyDir = Directory(
                '${Directory.systemTemp.path}${Platform.pathSeparator}$legacy',
              );
              if (await legacyDir.exists()) {
                await legacyDir.delete(recursive: true);
              }
            } catch (_) {}
          }
        }());
      }
    }
    final dir = _diskDir;
    if (dir == null) return null;
    return File('${dir.path}${Platform.pathSeparator}${_fnv1a64(key)}.img');
  }

  static Future<void> _writeDisk(File file, Uint8List bytes) async {
    try {
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsBytes(bytes, flush: true);
      await tmp.rename(file.path);
    } catch (_) {}
  }

  static String _fnv1a64(String input) {
    int h1 = 0x811C9DC5;
    int h2 = 0x050C5D1F;
    for (final unit in input.codeUnits) {
      h1 = ((h1 ^ unit) * 0x01000193) & 0xFFFFFFFF;
      h2 = ((h2 ^ (unit + 31)) * 0x01000193) & 0xFFFFFFFF;
    }
    return '${h1.toRadixString(16).padLeft(8, '0')}${h2.toRadixString(16).padLeft(8, '0')}';
  }
}

/// [ImageProvider] backed by [PosterLoader] for direct provider consumers.
@immutable
class MarcoPosterProvider extends ImageProvider<MarcoPosterProvider> {
  final String url;
  final String title;
  final String year;
  const MarcoPosterProvider(this.url, {this.title = '', this.year = ''});

  @override
  Future<MarcoPosterProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture<MarcoPosterProvider>(this);
  }

  @override
  ImageStreamCompleter loadImage(
    MarcoPosterProvider key,
    ImageDecoderCallback decode,
  ) {
    return MultiFrameImageStreamCompleter(
      codec: _loadCodec(key, decode),
      scale: 1.0,
      debugLabel: key.url,
    );
  }

  Future<ui.Codec> _loadCodec(
    MarcoPosterProvider key,
    ImageDecoderCallback decode,
  ) async {
    try {
      final bytes = await PosterLoader.load(
        key.url,
        title: key.title,
        year: key.year,
      );
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      return await decode(buffer);
    } catch (e) {
      scheduleMicrotask(() => PaintingBinding.instance.imageCache.evict(key));
      rethrow;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is MarcoPosterProvider &&
      other.url == url &&
      other.title == title &&
      other.year == year;

  @override
  int get hashCode => Object.hash(url, title, year);

  @override
  String toString() =>
      'MarcoPosterProvider("$url", title: "$title", year: "$year")';
}

/// Stateful poster widget that loads verified image bytes via [PosterLoader],
/// subscribes to targeted O(1) cache keys so scrolling lists refresh in real time
/// without waking unrelated cards, keeps loaded cards alive during scroll, and
/// upgrades genuinely blurry thumbnails when [highRes] is enabled.
class PosterImage extends StatefulWidget {
  final String url;
  final String title;
  final String year;
  final BoxFit fit;
  final AlignmentGeometry alignment;
  final Widget placeholder;
  final bool fadeIn;
  final bool highRes;
  final bool strictHighRes;
  final bool forBackdrop;
  final ValueChanged<Uint8List>? onBytesLoaded;

  const PosterImage({
    super.key,
    required this.url,
    required this.placeholder,
    this.title = '',
    this.year = '',
    this.fit = BoxFit.cover,
    this.alignment = Alignment.center,
    this.fadeIn = true,
    this.highRes = false,
    this.strictHighRes = false,
    this.forBackdrop = false,
    this.onBytesLoaded,
  });

  @override
  State<PosterImage> createState() => _PosterImageState();
}

class _PosterImageState extends State<PosterImage>
    with AutomaticKeepAliveClientMixin {
  Uint8List? _bytes;
  bool _loadedSync = false;
  bool _hasVerifiedHd = false;
  int _retryCount = 0;
  Timer? _retryTimer;
  List<String> _subscribedKeys = const [];

  bool get _wantsHd => widget.highRes || widget.strictHighRes;

  @override
  bool get wantKeepAlive => _bytes != null;

  List<String> _computeSubscribedKeys() {
    final raw = widget.url.trim();
    if (EmbyLibrary.isImage(raw)) return [raw];
    final clean = PosterLoader._cleanTitle(widget.title);
    final scoped = PosterLoader._scopedTitleToken(
      clean,
      PosterLoader._extractTargetYear(widget.title, widget.year),
    );
    final u = PosterLoader.upgradeUrlToHd(raw);
    if (u.isNotEmpty && !PosterLoader._isKnownDeadPosterHost(u)) {
      if (!_wantsHd) return <String>[u];
      return <String>[
        u,
        'hd_url:$u',
        if (scoped.isNotEmpty) 'title_hd:$scoped',
      ];
    }
    if (scoped.isNotEmpty) {
      return <String>['title:$scoped', 'title_hd:$scoped'];
    }
    return const [];
  }

  void _resubscribeKeys() {
    for (final k in _subscribedKeys) {
      PosterLoader.removeKeyListener(k, _onKeyCacheUpdated);
    }
    final nextKeys = _computeSubscribedKeys();
    _subscribedKeys = nextKeys;
    for (final k in nextKeys) {
      PosterLoader.addKeyListener(k, _onKeyCacheUpdated);
    }
  }

  @override
  void initState() {
    super.initState();
    _resubscribeKeys();
    _initLoad();
  }

  @override
  void didUpdateWidget(covariant PosterImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final sameIdentity = oldWidget.url.trim() == widget.url.trim() &&
        oldWidget.title.trim() == widget.title.trim() &&
        oldWidget.year.trim() == widget.year.trim();
    if (!sameIdentity) {
      _retryTimer?.cancel();
      _retryCount = 0;
      _hasVerifiedHd = false;
      _resubscribeKeys();
      _initLoad();
      return;
    }
    if (oldWidget.highRes != widget.highRes ||
        oldWidget.strictHighRes != widget.strictHighRes) {
      _resubscribeKeys();
      if (_wantsHd &&
          _bytes != null &&
          !widget.forBackdrop &&
          widget.title.trim().isNotEmpty) {
        unawaited(_verifyAndUpgradeIfLowRes(_bytes!, widget.title.trim()));
      } else if (_bytes == null) {
        _initLoad();
      }
    }
  }

  @override
  void dispose() {
    for (final k in _subscribedKeys) {
      PosterLoader.removeKeyListener(k, _onKeyCacheUpdated);
    }
    _subscribedKeys = const [];
    _retryTimer?.cancel();
    super.dispose();
  }

  void _onKeyCacheUpdated() {
    if (!mounted) return;
    if (_bytes == null) {
      final hit = PosterLoader.peekMemory(
        widget.url,
        title: widget.title,
        year: widget.year,
        preferHd: _wantsHd,
      );
      if (hit != null) {
        setState(() {
          _bytes = hit;
        });
        updateKeepAlive();
        _notifyBytes(hit);
      }
      return;
    }
    if (_wantsHd && widget.title.trim().isNotEmpty) {
      final hdHit = PosterLoader.peekHdMemory(
        widget.title,
        rawUrl: widget.url,
        year: widget.year,
      );
      if (hdHit != null && !identical(hdHit, _bytes)) {
        setState(() {
          _bytes = hdHit;
          _hasVerifiedHd = true;
        });
        updateKeepAlive();
        _notifyBytes(hdHit);
      }
    }
  }

  void _notifyBytes(Uint8List data) {
    final cb = widget.onBytesLoaded;
    if (cb != null) {
      scheduleMicrotask(() {
        if (mounted) cb(data);
      });
    }
  }

  void _initLoad() {
    final immediateHd = _wantsHd && widget.title.trim().isNotEmpty
        ? PosterLoader.peekHdMemory(
            widget.title,
            rawUrl: widget.url,
            year: widget.year,
          )
        : null;
    final immediate = immediateHd ??
        PosterLoader.peekMemory(
          widget.url,
          title: widget.title,
          year: widget.year,
          preferHd: _wantsHd,
        );
    if (immediate != null) {
      _bytes = immediate;
      _loadedSync = true;
      _hasVerifiedHd = immediateHd != null;
      updateKeepAlive();
      _notifyBytes(immediate);
      if (_wantsHd &&
          !widget.forBackdrop &&
          widget.title.trim().isNotEmpty) {
        unawaited(_verifyAndUpgradeIfLowRes(immediate, widget.title.trim()));
      }
      return;
    }
    _bytes = null;
    _loadedSync = false;
    _hasVerifiedHd = false;
    updateKeepAlive();
    _fetchBytes();
    if (widget.strictHighRes &&
        !widget.forBackdrop &&
        widget.title.trim().isNotEmpty &&
        !EmbyLibrary.isImage(widget.url)) {
      unawaited(_tryUpgradeToHd(widget.title.trim(), null));
    }
  }

  Future<void> _verifyAndUpgradeIfLowRes(
    Uint8List currentBytes,
    String requestedTitle,
  ) async {
    final hasLiveCmsUrl = widget.url.trim().isNotEmpty &&
        !PosterLoader._isKnownDeadPosterHost(widget.url);
    // Home & Detail heroes (`strictHighRes: true`) fill the full Retina screen
    // width and MUST resolve a true vertical HD poster (>= 640x900).
    final alreadyGood = widget.strictHighRes
        ? await PosterLoader.isHeroHdPoster(currentBytes)
        : ((hasLiveCmsUrl && !_wantsHd)
            ? await PosterLoader.isClearPosterBytes(currentBytes)
            : await PosterLoader.isTrueHdPoster(currentBytes));
    if (!mounted || widget.title.trim() != requestedTitle) return;
    if (alreadyGood) {
      _hasVerifiedHd = true;
      return;
    }
    await _tryUpgradeToHd(requestedTitle, currentBytes);
  }

  Future<void> _tryUpgradeToHd(
    String requestedTitle,
    Uint8List? currentBytes,
  ) async {
    if (EmbyLibrary.isImage(widget.url)) return;
    try {
      final hdBytes = await PosterLoader.loadHdByTitle(
        requestedTitle,
        rawUrl: widget.url,
        year: widget.year,
        strictHero: widget.strictHighRes,
      );
      if (!mounted || widget.title.trim() != requestedTitle) return;
      final isHeroHd = await PosterLoader.isHeroHdPoster(hdBytes);
      final isHd = isHeroHd || await PosterLoader.isTrueHdPoster(hdBytes);
      if (!mounted) return;
      final cur = _bytes ?? currentBytes;
      final curPixels =
          cur != null ? await PosterLoader._decodedPixelCount(cur) : 0;
      final hdPixels = await PosterLoader._decodedPixelCount(hdBytes);
      if (!mounted) return;
      final curIsHeroHd = cur != null && await PosterLoader.isHeroHdPoster(cur);
      if (!mounted) return;
      final shouldReplace = cur == null ||
          (isHeroHd && (!curIsHeroHd || hdPixels > curPixels)) ||
          (!curIsHeroHd && (isHd || hdPixels > curPixels));
      if (shouldReplace) {
        setState(() {
          _bytes = hdBytes;
          _hasVerifiedHd = widget.strictHighRes ? isHeroHd : isHd;
        });
        updateKeepAlive();
        _notifyBytes(hdBytes);
      }
    } catch (_) {}
  }

  Future<void> _fetchBytes() async {
    if (widget.url.trim().isEmpty && widget.title.trim().isEmpty) return;
    final requestedUrl = widget.url.trim();
    final requestedTitle = widget.title.trim();
    final requestedYear = widget.year.trim();
    try {
      final data = await PosterLoader.load(
        requestedUrl,
        title: requestedTitle,
        year: requestedYear,
      );
      if (!mounted) return;
      if (widget.url.trim() != requestedUrl ||
          widget.title.trim() != requestedTitle ||
          widget.year.trim() != requestedYear) {
        return;
      }
      // Never let a lower-resolution CMS fetch overwrite an already-verified HD poster.
      if (!_hasVerifiedHd) {
        final cur = _bytes;
        final shouldSet = cur == null ||
            (await PosterLoader._decodedPixelCount(data) >
                await PosterLoader._decodedPixelCount(cur));
        if (!mounted) return;
        if (shouldSet) {
          setState(() {
            _bytes = data;
          });
          updateKeepAlive();
          _notifyBytes(data);
        }
      }
      if (_wantsHd &&
          !widget.forBackdrop &&
          requestedTitle.isNotEmpty &&
          !EmbyLibrary.isImage(requestedUrl)) {
        unawaited(_verifyAndUpgradeIfLowRes(_bytes ?? data, requestedTitle));
      }
    } catch (_) {
      if (!mounted) return;
      if (_wantsHd &&
          requestedTitle.isNotEmpty &&
          !EmbyLibrary.isImage(requestedUrl) &&
          _bytes == null) {
        unawaited(_tryUpgradeToHd(requestedTitle, null));
      }
      if (_retryCount < 2) {
        _retryCount++;
        final delayMs = _retryCount == 1 ? 800 : 2000;
        _retryTimer?.cancel();
        _retryTimer = Timer(Duration(milliseconds: delayMs), () {
          if (mounted && _bytes == null) _fetchBytes();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final bytes = _bytes;
    if (bytes == null) {
      return widget.placeholder;
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        if (widget.forBackdrop) {
          final backdropImg = Image(
            image: ResizeImage.resizeIfNeeded(
              360,
              null,
              MemoryImage(bytes),
            ),
            fit: widget.fit,
            alignment: widget.alignment,
            width: constraints.maxWidth.isFinite ? constraints.maxWidth : null,
            height:
                constraints.maxHeight.isFinite ? constraints.maxHeight : null,
            gaplessPlayback: true,
            isAntiAlias: false,
            filterQuality: FilterQuality.low,
            errorBuilder: (_, __, ___) => widget.placeholder,
          );
          if (_loadedSync || !widget.fadeIn) {
            return backdropImg;
          }
          return TweenAnimationBuilder<double>(
            tween: Tween<double>(begin: 0.0, end: 1.0),
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            builder: (context, opacity, child) =>
                Opacity(opacity: opacity, child: child),
            child: backdropImg,
          );
        }
        final dpr = (MediaQuery.maybeDevicePixelRatioOf(context) ?? 2.0)
            .clamp(1.25, 3.0);
        final isLargeSurface = _wantsHd ||
            (constraints.maxWidth.isFinite && constraints.maxWidth >= 210) ||
            (constraints.maxHeight.isFinite && constraints.maxHeight >= 260);
        int? cacheWidth;
        if (!isLargeSurface &&
            constraints.maxWidth.isFinite &&
            constraints.maxWidth > 0) {
          final effectiveWidth = constraints.maxHeight.isFinite &&
                  constraints.maxHeight * 0.72 > constraints.maxWidth
              ? constraints.maxHeight * 0.72
              : constraints.maxWidth;
          final px = (effectiveWidth * dpr).ceil();
          cacheWidth = ((px + 179) ~/ 180) * 180;
        }
        final ImageProvider provider = isLargeSurface
            ? MemoryImage(bytes)
            : ResizeImage.resizeIfNeeded(
                cacheWidth,
                null,
                MemoryImage(bytes),
              );
        final img = Image(
          image: provider,
          fit: widget.fit,
          alignment: widget.alignment,
          width: constraints.maxWidth.isFinite ? constraints.maxWidth : null,
          height: constraints.maxHeight.isFinite ? constraints.maxHeight : null,
          gaplessPlayback: true,
          isAntiAlias: true,
          filterQuality:
              isLargeSurface ? FilterQuality.high : FilterQuality.medium,
          errorBuilder: (_, __, ___) => widget.placeholder,
        );
        if (_loadedSync || !widget.fadeIn) {
          return img;
        }
        return TweenAnimationBuilder<double>(
          tween: Tween<double>(begin: 0.0, end: 1.0),
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
          builder: (context, opacity, child) => Stack(
            fit: StackFit.passthrough,
            children: [
              if (opacity < 0.99) Positioned.fill(child: widget.placeholder),
              Opacity(opacity: opacity, child: child),
            ],
          ),
          child: img,
        );
      },
    );
  }
}

/// Renders a distinct 16:9 widescreen scene still (`剧照 / 画面`) for a specific
/// [episodeIndex] of [seriesTitle], prioritizing real per-episode Bilibili PGC
/// 16:9 frame covers when available and listening to [PosterLoader.metadataRevision]
/// so scrolling episode strips update immediately.
class EpisodeStillImage extends StatefulWidget {
  final String seriesTitle;
  final String year;
  final int episodeIndex;
  /// Optional real 1-based scraped episode number (when different from array
  /// position `episodeIndex + 1`, e.g. netdisk shares with missing or special
  /// episodes).
  final int? realEpisodeNumber;
  final bool? wantMotionComic;
  final String fallbackPosterUrl;
  final Widget placeholder;

  const EpisodeStillImage({
    super.key,
    required this.seriesTitle,
    required this.episodeIndex,
    required this.fallbackPosterUrl,
    required this.placeholder,
    this.year = '',
    this.realEpisodeNumber,
    this.wantMotionComic,
  });

  @override
  State<EpisodeStillImage> createState() => _EpisodeStillImageState();
}

class _EpisodeStillImageState extends State<EpisodeStillImage>
    with AutomaticKeepAliveClientMixin {
  String? _stillUrl;

  @override
  bool get wantKeepAlive => _stillUrl != null;

  @override
  void initState() {
    super.initState();
    PosterLoader.metadataRevision.addListener(_onMetadataUpdated);
    _resolveStill();
  }

  @override
  void didUpdateWidget(covariant EpisodeStillImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.seriesTitle != widget.seriesTitle ||
        oldWidget.year != widget.year ||
        oldWidget.episodeIndex != widget.episodeIndex ||
        oldWidget.realEpisodeNumber != widget.realEpisodeNumber ||
        oldWidget.wantMotionComic != widget.wantMotionComic) {
      _stillUrl = null;
      _resolveStill();
    }
  }

  @override
  void dispose() {
    PosterLoader.metadataRevision.removeListener(_onMetadataUpdated);
    super.dispose();
  }

  void _onMetadataUpdated() {
    if (!mounted) return;
    _pickFromCaches();
  }

  int get _effectiveEpisodeNumber {
    final real = widget.realEpisodeNumber;
    if (real != null && real > 0) return real;
    return widget.episodeIndex + 1;
  }

  void _pickFromCaches() {
    final title = widget.seriesTitle.trim();
    if (title.isEmpty) return;
    final wantMc =
        widget.wantMotionComic ?? PosterLoader._isMotionComicTitle(title);
    final epMeta = PosterLoader.peekEpisodeMeta(
      title,
      _effectiveEpisodeNumber,
      wantMotionComic: wantMc,
    );
    if (epMeta != null && epMeta.coverUrl.isNotEmpty) {
      if (_stillUrl != epMeta.coverUrl) {
        setState(() {
          _stillUrl = epMeta.coverUrl;
        });
        updateKeepAlive();
      }
      return;
    }
    final clean = PosterLoader.cleanTitleForQuery(title);
    final key = PosterLoader._episodeCacheKey(clean, wantMc);
    final cachedStills = PosterLoader._seriesEpisodeStillsCache[key];
    if (cachedStills != null && cachedStills.isNotEmpty) {
      final picked =
          cachedStills[(_effectiveEpisodeNumber - 1).abs() % cachedStills.length];
      if (_stillUrl != picked) {
        setState(() {
          _stillUrl = picked;
        });
        updateKeepAlive();
      }
    }
  }

  Future<void> _resolveStill() async {
    _pickFromCaches();
    if (_stillUrl != null && _stillUrl!.isNotEmpty) return;
    final title = widget.seriesTitle.trim();
    if (title.isEmpty) return;
    try {
      await Future.wait([
        PosterLoader.fetchSeriesEpisodeMetadata(
          title,
          year: widget.year,
          wantMotionComic: widget.wantMotionComic,
        ),
        PosterLoader.fetchSeriesEpisodeStills(
          title,
          year: widget.year,
          wantMotionComic: widget.wantMotionComic,
        ),
      ]);
      if (!mounted) return;
      _pickFromCaches();
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final still = _stillUrl;
    final double alignY =
        -0.72 + ((widget.episodeIndex * 3) % 7) * 0.22; // -0.72 .. +0.60
    final fallbackPosterWidget = PosterImage(
      url: widget.fallbackPosterUrl,
      title: widget.seriesTitle,
      year: widget.year,
      fit: BoxFit.cover,
      alignment: Alignment(0.0, alignY),
      highRes: false,
      placeholder: widget.placeholder,
    );
    if (still != null && still.isNotEmpty) {
      return PosterImage(
        key: ValueKey(
          'still_${widget.seriesTitle}_${widget.episodeIndex}_$still',
        ),
        url: still,
        title: '',
        fit: BoxFit.cover,
        highRes: false,
        placeholder: fallbackPosterWidget,
      );
    }
    return fallbackPosterWidget;
  }
}

/// High-resolution landscape (`4:3` / `16:9`) poster & backdrop widget for
/// Windows desktop featured recommendation cards and detail hero stages.
///
/// Actively resolves true landscape HD artwork via [PosterLoader.loadLandscapeByTitle]
/// instead of stretching a 360px low-res portrait thumbnail. While resolving (or
/// when external title lookup is disabled in private mode), renders the high-res
/// source artwork cleanly with `FilterQuality.high` and upper-center framing.
class LandscapePosterImage extends StatefulWidget {
  final String url;
  final String title;
  final String year;
  final Widget placeholder;
  final BoxFit fit;
  final AlignmentGeometry alignment;
  final bool allowExternalLookup;
  final ValueChanged<Uint8List>? onBytesLoaded;
  /// Notifies the parent whenever the displayed artwork switches between a
  /// verified true-landscape HD image (`true`) and a portrait fallback (`false`).
  final ValueChanged<bool>? onLandscapeStatusChanged;
  /// When `true` and only a portrait fallback poster is available, renders it
  /// as a deep cinema ambient blur instead of stretching/cropping a 2:3 vertical
  /// poster across a widescreen canvas.
  final bool blurPortraitFallback;
  /// When `true` alongside [blurPortraitFallback], floats a crisp uncropped
  /// vertical key-art poster card on the right side of wide hero cards.
  final bool showRightFramedPortraitFallback;
  /// Optional user-bound backdrop URL from manual series scraping.
  final String preferredBackdropUrl;
  /// Optional user-bound Douban subject ID from manual series scraping.
  final String preferredDoubanId;
  final bool preferredDoubanIsTv;
  /// Explicit work-form disambiguation (`true` = 动态漫画, `false` = regular).
  final bool? wantMotionComic;

  const LandscapePosterImage({
    super.key,
    required this.url,
    required this.placeholder,
    this.title = '',
    this.year = '',
    this.fit = BoxFit.cover,
    this.alignment = const Alignment(0.0, -0.2),
    this.allowExternalLookup = true,
    this.onBytesLoaded,
    this.onLandscapeStatusChanged,
    this.blurPortraitFallback = false,
    this.showRightFramedPortraitFallback = false,
    this.preferredBackdropUrl = '',
    this.preferredDoubanId = '',
    this.preferredDoubanIsTv = true,
    this.wantMotionComic,
  });

  @override
  State<LandscapePosterImage> createState() => _LandscapePosterImageState();
}

class _LandscapePosterImageState extends State<LandscapePosterImage>
    with AutomaticKeepAliveClientMixin {
  Uint8List? _landscapeBytes;
  Uint8List? _fallbackBytes;
  bool _loadedSync = false;
  bool? _lastNotifiedLandscape;
  String _subscribedKey = '';

  @override
  bool get wantKeepAlive => _landscapeBytes != null;

  String _computeKey() {
    if (!widget.allowExternalLookup) return '';
    final prefBackdrop =
        PosterLoader.upgradeUrlToHd(widget.preferredBackdropUrl);
    if (prefBackdrop.isNotEmpty) {
      return 'landscape_url:$prefBackdrop';
    }
    final prefDouban = widget.preferredDoubanId.trim();
    if (prefDouban.isNotEmpty) {
      return 'landscape_douban:$prefDouban';
    }
    final clean = PosterLoader.cleanTitleForQuery(widget.title);
    if (clean.isEmpty) return '';
    final wantMc =
        widget.wantMotionComic ?? PosterLoader._isMotionComicTitle(widget.title);
    final scoped = PosterLoader._scopedTitleToken(
      clean,
      PosterLoader._extractTargetYear(widget.title, widget.year),
      isMotionComic: wantMc,
    );
    return scoped.isEmpty ? '' : 'landscape_hd:$scoped';
  }

  void _resubscribe() {
    if (_subscribedKey.isNotEmpty) {
      PosterLoader.removeKeyListener(_subscribedKey, _onLandscapeUpdated);
    }
    _subscribedKey = _computeKey();
    if (_subscribedKey.isNotEmpty) {
      PosterLoader.addKeyListener(_subscribedKey, _onLandscapeUpdated);
    }
  }

  @override
  void initState() {
    super.initState();
    _resubscribe();
    _initLoad();
  }

  @override
  void didUpdateWidget(covariant LandscapePosterImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url.trim() != widget.url.trim() ||
        oldWidget.title.trim() != widget.title.trim() ||
        oldWidget.year.trim() != widget.year.trim() ||
        oldWidget.allowExternalLookup != widget.allowExternalLookup ||
        oldWidget.preferredBackdropUrl.trim() !=
            widget.preferredBackdropUrl.trim() ||
        oldWidget.preferredDoubanId.trim() != widget.preferredDoubanId.trim() ||
        oldWidget.preferredDoubanIsTv != widget.preferredDoubanIsTv ||
        oldWidget.wantMotionComic != widget.wantMotionComic) {
      _resubscribe();
      _initLoad();
    }
  }

  @override
  void dispose() {
    if (_subscribedKey.isNotEmpty) {
      PosterLoader.removeKeyListener(_subscribedKey, _onLandscapeUpdated);
    }
    super.dispose();
  }

  void _notifyLandscapeStatus(bool hasLandscape) {
    if (_lastNotifiedLandscape == hasLandscape) return;
    _lastNotifiedLandscape = hasLandscape;
    final cb = widget.onLandscapeStatusChanged;
    if (cb != null) {
      scheduleMicrotask(() {
        if (mounted) cb(hasLandscape);
      });
    }
  }

  void _onLandscapeUpdated() {
    if (!mounted || !widget.allowExternalLookup) return;
    final hit = PosterLoader.peekLandscapeMemory(
      widget.title,
      year: widget.year,
      wantMotionComic: widget.wantMotionComic,
      preferredBackdropUrl: widget.preferredBackdropUrl,
      preferredDoubanId: widget.preferredDoubanId,
    );
    if (hit != null && !identical(hit, _landscapeBytes)) {
      setState(() => _landscapeBytes = hit);
      updateKeepAlive();
      _notifyLandscapeStatus(true);
      _notify(hit);
    }
  }

  void _notify(Uint8List data) {
    final cb = widget.onBytesLoaded;
    if (cb != null) {
      scheduleMicrotask(() {
        if (mounted) cb(data);
      });
    }
  }

  void _onFallbackBytesLoaded(Uint8List data) {
    if (mounted && !identical(_fallbackBytes, data)) {
      setState(() => _fallbackBytes = data);
    }
    _notify(data);
    if (_landscapeBytes != null) return;
    final reqUrl = widget.url.trim();
    final reqTitle = widget.title.trim();
    unawaited(
      PosterLoader.isLandscapeHdPoster(data).then((isWide) {
        if (!mounted ||
            widget.url.trim() != reqUrl ||
            widget.title.trim() != reqTitle ||
            _landscapeBytes != null) {
          return;
        }
        if (isWide) {
          setState(() => _landscapeBytes = data);
          updateKeepAlive();
          _notifyLandscapeStatus(true);
        } else {
          _notifyLandscapeStatus(false);
        }
      }),
    );
  }

  void _initLoad() {
    _lastNotifiedLandscape = null;
    _fallbackBytes = null;
    final hasPreferred = widget.preferredBackdropUrl.trim().isNotEmpty ||
        widget.preferredDoubanId.trim().isNotEmpty;
    if (!widget.allowExternalLookup ||
        (widget.title.trim().isEmpty && !hasPreferred)) {
      _landscapeBytes = null;
      _loadedSync = false;
      updateKeepAlive();
      _notifyLandscapeStatus(false);
      return;
    }
    final hit = PosterLoader.peekLandscapeMemory(
      widget.title,
      year: widget.year,
      wantMotionComic: widget.wantMotionComic,
      preferredBackdropUrl: widget.preferredBackdropUrl,
      preferredDoubanId: widget.preferredDoubanId,
    );
    if (hit != null) {
      _landscapeBytes = hit;
      _loadedSync = true;
      updateKeepAlive();
      _notifyLandscapeStatus(true);
      _notify(hit);
      return;
    }
    _landscapeBytes = null;
    _loadedSync = false;
    updateKeepAlive();
    _notifyLandscapeStatus(false);
    final reqTitle = widget.title.trim();
    final reqYear = widget.year.trim();
    final reqUrl = widget.url.trim();
    final reqPrefBackdrop = widget.preferredBackdropUrl.trim();
    final reqPrefDouban = widget.preferredDoubanId.trim();
    final reqPrefIsTv = widget.preferredDoubanIsTv;
    final reqWantMc = widget.wantMotionComic;
    unawaited(
      PosterLoader.loadLandscapeByTitle(
        reqTitle,
        year: reqYear,
        fallbackUrl: reqUrl,
        wantMotionComic: reqWantMc,
        preferredBackdropUrl: reqPrefBackdrop,
        preferredDoubanId: reqPrefDouban,
        preferredDoubanIsTv: reqPrefIsTv,
      ).then((bytes) {
        if (!mounted ||
            widget.title.trim() != reqTitle ||
            widget.year.trim() != reqYear ||
            widget.preferredBackdropUrl.trim() != reqPrefBackdrop ||
            widget.preferredDoubanId.trim() != reqPrefDouban ||
            widget.wantMotionComic != reqWantMc) {
          return;
        }
        setState(() => _landscapeBytes = bytes);
        updateKeepAlive();
        _notifyLandscapeStatus(true);
        _notify(bytes);
      }).catchError((Object _) {}),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final bytes = _landscapeBytes;
    if (bytes != null) {
      final img = Image(
        image: MemoryImage(bytes),
        fit: widget.fit,
        alignment: widget.alignment,
        gaplessPlayback: true,
        isAntiAlias: true,
        filterQuality: FilterQuality.high,
        errorBuilder: (_, __, ___) => _buildFallback(),
      );
      if (_loadedSync) return img;
      return TweenAnimationBuilder<double>(
        tween: Tween<double>(begin: 0.0, end: 1.0),
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
        builder: (context, opacity, child) => Stack(
          fit: StackFit.expand,
          children: [
            if (opacity < 0.99) Positioned.fill(child: _buildFallback()),
            Opacity(opacity: opacity, child: child),
          ],
        ),
        child: img,
      );
    }
    return _buildFallback();
  }

  Widget _buildFallback() {
    final basePoster = PosterImage(
      url: widget.url,
      title: widget.allowExternalLookup ? widget.title : '',
      year: widget.year,
      fit: widget.fit,
      alignment: widget.alignment,
      highRes: true,
      forBackdrop: widget.blurPortraitFallback,
      placeholder: widget.placeholder,
      onBytesLoaded: _onFallbackBytesLoaded,
    );
    if (!widget.blurPortraitFallback) {
      return basePoster;
    }
    final blurredBackdrop = ClipRect(
      child: Stack(
        fit: StackFit.expand,
        children: [
          Transform.scale(
            scale: 1.12,
            child: ImageFiltered(
              imageFilter: ui.ImageFilter.blur(
                sigmaX: 38,
                sigmaY: 38,
                tileMode: TileMode.clamp,
              ),
              child: basePoster,
            ),
          ),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color(0x4D0A0D13),
                  Color(0x700A0D13),
                ],
              ),
            ),
          ),
        ],
      ),
    );
    if (!widget.showRightFramedPortraitFallback || _fallbackBytes == null) {
      return blurredBackdrop;
    }
    return LayoutBuilder(
      builder: (context, box) {
        final showInsetPoster = box.maxWidth.isFinite &&
            box.maxHeight.isFinite &&
            box.maxWidth >= 250 &&
            box.maxHeight >= 140;
        if (!showInsetPoster) return blurredBackdrop;
        final insetHeight = (box.maxHeight * 0.78).clamp(96.0, 210.0);
        final insetWidth = insetHeight * 0.68;
        return Stack(
          fit: StackFit.expand,
          children: [
            blurredBackdrop,
            Positioned(
              right: 18,
              top: (box.maxHeight - insetHeight) / 2,
              width: insetWidth,
              height: insetHeight,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x80000000),
                      blurRadius: 24,
                      offset: Offset(0, 10),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      PosterImage(
                        url: widget.url,
                        title: widget.allowExternalLookup ? widget.title : '',
                        year: widget.year,
                        fit: BoxFit.cover,
                        highRes: true,
                        placeholder: widget.placeholder,
                      ),
                      DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: const Color(0x38FFFFFF),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
