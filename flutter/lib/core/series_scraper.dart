import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'models.dart';

/// Broad media work form used to prevent cross-medium mismatches (especially
/// separating `动态漫画 / 动态漫` from regular 3D/2D `动漫 / 动画` and live-action
/// dramas, plus rejecting audio books, recaps, and games).
enum MediaWorkForm {
  standard,
  motionComic,
  audioBook,
  recap,
  game,
}

/// Result of scraping an individual episode filename/label within a [CmsLine].
class ScrapedEpisodeInfo {
  final int originalIndex;
  final String rawName;
  final int? seasonNumber;
  final int? rawEpisodeNumber;
  final int? endEpisodeNumber;
  final int? effectiveEpisodeNumber;
  final bool isSpecial;
  final String specialTag;
  final String qualityTag;
  final String displayLabel;
  final double confidence;
  final bool hasManualOverride;

  const ScrapedEpisodeInfo({
    required this.originalIndex,
    required this.rawName,
    this.seasonNumber,
    this.rawEpisodeNumber,
    this.endEpisodeNumber,
    this.effectiveEpisodeNumber,
    this.isSpecial = false,
    this.specialTag = '',
    this.qualityTag = '',
    required this.displayLabel,
    this.confidence = 0.0,
    this.hasManualOverride = false,
  });

  /// Effective 1-based episode number used for episode metadata lookup & danmu.
  int? get resolvedEpisodeNumber =>
      isSpecial ? null : (effectiveEpisodeNumber ?? rawEpisodeNumber);
}

/// Line-level episode scrape report with natural numeric ordering & diagnostics.
class LineEpisodeScrapeResult {
  final List<ScrapedEpisodeInfo> byOriginalIndex;
  final List<int> sortedRegularIndices;
  final List<int> specialIndices;
  final List<int> unparsedIndices;
  final bool sourceOrderScrambled;
  final int regularCount;
  final int specialCount;
  final int? minEpisodeNumber;
  final int? maxEpisodeNumber;

  const LineEpisodeScrapeResult({
    required this.byOriginalIndex,
    required this.sortedRegularIndices,
    required this.specialIndices,
    required this.unparsedIndices,
    required this.sourceOrderScrambled,
    required this.regularCount,
    required this.specialCount,
    this.minEpisodeNumber,
    this.maxEpisodeNumber,
  });

  bool get hasMissingNumbers =>
      minEpisodeNumber != null &&
      maxEpisodeNumber != null &&
      regularCount >= 2 &&
      (maxEpisodeNumber! - minEpisodeNumber! + 1) > regularCount;

  ScrapedEpisodeInfo? infoForOriginalIndex(int index) {
    if (index < 0 || index >= byOriginalIndex.length) return null;
    return byOriginalIndex[index];
  }

  /// Returns ordered indices into `line.episodes` according to [sortByScraped]
  /// and [hideSpecials]. Never mutates `line.episodes`.
  List<int> orderedIndices({
    required bool sortByScraped,
    bool hideSpecials = false,
  }) {
    if (byOriginalIndex.isEmpty) return const [];
    if (sortByScraped && regularCount >= 2) {
      return <int>[
        ...sortedRegularIndices,
        ...unparsedIndices,
        if (!hideSpecials) ...specialIndices,
      ];
    }
    if (hideSpecials && specialCount > 0 && regularCount > 0) {
      return <int>[
        for (final info in byOriginalIndex)
          if (!info.isSpecial) info.originalIndex,
      ];
    }
    return List<int>.generate(
      byOriginalIndex.length,
      (i) => i,
      growable: false,
    );
  }
}

/// Search candidate returned by in-series manual scraping (Douban / Bangumi /
/// Bilibili PGC) so the user can inspect and bind the exact official work.
class SeriesScrapeCandidate {
  final String source; // 'douban' | 'bangumi' | 'bilibili'
  final String subjectId;
  final String title;
  final String subtitle;
  final String year;
  final bool isTv;
  final bool isMotionComic;
  final String mediaBadge; // e.g. '动漫' | '动态漫画' | '剧集' | '电影'
  final String posterUrl;
  final String backdropUrl;
  final String synopsis;
  final double? rating;
  final int? episodeCount;

  const SeriesScrapeCandidate({
    required this.source,
    required this.subjectId,
    required this.title,
    this.subtitle = '',
    this.year = '',
    this.isTv = true,
    this.isMotionComic = false,
    this.mediaBadge = '',
    this.posterUrl = '',
    this.backdropUrl = '',
    this.synopsis = '',
    this.rating,
    this.episodeCount,
  });

  SeriesScrapeCandidate copyWith({
    String? title,
    String? subtitle,
    String? year,
    bool? isTv,
    bool? isMotionComic,
    String? mediaBadge,
    String? posterUrl,
    String? backdropUrl,
    String? synopsis,
    double? rating,
    int? episodeCount,
  }) {
    return SeriesScrapeCandidate(
      source: source,
      subjectId: subjectId,
      title: title ?? this.title,
      subtitle: subtitle ?? this.subtitle,
      year: year ?? this.year,
      isTv: isTv ?? this.isTv,
      isMotionComic: isMotionComic ?? this.isMotionComic,
      mediaBadge: mediaBadge ?? this.mediaBadge,
      posterUrl: posterUrl ?? this.posterUrl,
      backdropUrl: backdropUrl ?? this.backdropUrl,
      synopsis: synopsis ?? this.synopsis,
      rating: rating ?? this.rating,
      episodeCount: episodeCount ?? this.episodeCount,
    );
  }
}

/// Persisted per-series manual scrape binding & episode calibration override.
class SeriesScrapeOverride {
  final String matchedTitle;
  final String matchedYear;
  final String source; // 'douban' | 'bangumi' | 'bilibili' | 'custom' | ''
  final String subjectId;
  final bool isTv;
  final bool isMotionComic;
  final String posterUrl;
  final String backdropUrl;
  final String synopsis;
  final double? doubanScore;
  final int episodeOffset;
  final bool? sortByScrapedEpisode;
  final bool hideSpecials;
  final String danmuTitleOverride;
  final String danmuAnimeId;
  final String danmuOrigin;
  final Map<String, int> episodeNumberOverrides;
  final int updatedAtMs;

  const SeriesScrapeOverride({
    this.matchedTitle = '',
    this.matchedYear = '',
    this.source = '',
    this.subjectId = '',
    this.isTv = true,
    this.isMotionComic = false,
    this.posterUrl = '',
    this.backdropUrl = '',
    this.synopsis = '',
    this.doubanScore,
    this.episodeOffset = 0,
    this.sortByScrapedEpisode,
    this.hideSpecials = false,
    this.danmuTitleOverride = '',
    this.danmuAnimeId = '',
    this.danmuOrigin = '',
    this.episodeNumberOverrides = const {},
    this.updatedAtMs = 0,
  });

  bool get hasWorkBinding =>
      matchedTitle.trim().isNotEmpty ||
      subjectId.trim().isNotEmpty ||
      posterUrl.trim().isNotEmpty ||
      backdropUrl.trim().isNotEmpty;

  bool get hasEpisodeCalibration =>
      episodeOffset != 0 ||
      sortByScrapedEpisode != null ||
      hideSpecials ||
      episodeNumberOverrides.isNotEmpty ||
      danmuTitleOverride.trim().isNotEmpty ||
      danmuAnimeId.trim().isNotEmpty;

  bool get isEmpty => !hasWorkBinding && !hasEpisodeCalibration;

  String get effectiveDanmuTitle {
    if (danmuTitleOverride.trim().isNotEmpty) return danmuTitleOverride.trim();
    if (matchedTitle.trim().isNotEmpty) return matchedTitle.trim();
    return '';
  }

  String get doubanId => source == 'douban' ? subjectId.trim() : '';

  SeriesScrapeOverride copyWith({
    String? matchedTitle,
    String? matchedYear,
    String? source,
    String? subjectId,
    bool? isTv,
    bool? isMotionComic,
    String? posterUrl,
    String? backdropUrl,
    String? synopsis,
    double? doubanScore,
    bool clearDoubanScore = false,
    int? episodeOffset,
    bool? sortByScrapedEpisode,
    bool clearSortByScrapedEpisode = false,
    bool? hideSpecials,
    String? danmuTitleOverride,
    String? danmuAnimeId,
    String? danmuOrigin,
    Map<String, int>? episodeNumberOverrides,
    int? updatedAtMs,
  }) {
    return SeriesScrapeOverride(
      matchedTitle: matchedTitle ?? this.matchedTitle,
      matchedYear: matchedYear ?? this.matchedYear,
      source: source ?? this.source,
      subjectId: subjectId ?? this.subjectId,
      isTv: isTv ?? this.isTv,
      isMotionComic: isMotionComic ?? this.isMotionComic,
      posterUrl: posterUrl ?? this.posterUrl,
      backdropUrl: backdropUrl ?? this.backdropUrl,
      synopsis: synopsis ?? this.synopsis,
      doubanScore:
          clearDoubanScore ? null : (doubanScore ?? this.doubanScore),
      episodeOffset: episodeOffset ?? this.episodeOffset,
      sortByScrapedEpisode: clearSortByScrapedEpisode
          ? null
          : (sortByScrapedEpisode ?? this.sortByScrapedEpisode),
      hideSpecials: hideSpecials ?? this.hideSpecials,
      danmuTitleOverride: danmuTitleOverride ?? this.danmuTitleOverride,
      danmuAnimeId: danmuAnimeId ?? this.danmuAnimeId,
      danmuOrigin: danmuOrigin ?? this.danmuOrigin,
      episodeNumberOverrides:
          episodeNumberOverrides ?? this.episodeNumberOverrides,
      updatedAtMs: updatedAtMs ?? this.updatedAtMs,
    );
  }

  Map<String, dynamic> toJson() => {
        'matchedTitle': matchedTitle,
        'matchedYear': matchedYear,
        'source': source,
        'subjectId': subjectId,
        'isTv': isTv,
        'isMotionComic': isMotionComic,
        'posterUrl': posterUrl,
        'backdropUrl': backdropUrl,
        'synopsis': synopsis,
        if (doubanScore != null) 'doubanScore': doubanScore,
        'episodeOffset': episodeOffset,
        if (sortByScrapedEpisode != null)
          'sortByScrapedEpisode': sortByScrapedEpisode,
        'hideSpecials': hideSpecials,
        'danmuTitleOverride': danmuTitleOverride,
        'danmuAnimeId': danmuAnimeId,
        'danmuOrigin': danmuOrigin,
        if (episodeNumberOverrides.isNotEmpty)
          'episodeNumberOverrides': episodeNumberOverrides,
        'updatedAtMs': updatedAtMs,
      };

  factory SeriesScrapeOverride.fromJson(Map<String, dynamic> json) {
    final rawOverrides = json['episodeNumberOverrides'];
    final epOverrides = <String, int>{};
    if (rawOverrides is Map) {
      for (final entry in rawOverrides.entries) {
        final k = entry.key.toString();
        final v = entry.value is num
            ? (entry.value as num).toInt()
            : int.tryParse(entry.value.toString());
        if (k.isNotEmpty && v != null && v > 0) {
          epOverrides[k] = v;
        }
      }
    }
    final rawScore = json['doubanScore'];
    final score = rawScore is num
        ? rawScore.toDouble()
        : (rawScore != null ? double.tryParse(rawScore.toString()) : null);
    return SeriesScrapeOverride(
      matchedTitle: (json['matchedTitle'] ?? '').toString().trim(),
      matchedYear: (json['matchedYear'] ?? '').toString().trim(),
      source: (json['source'] ?? '').toString().trim(),
      subjectId: (json['subjectId'] ?? '').toString().trim(),
      isTv: json['isTv'] != false,
      isMotionComic: json['isMotionComic'] == true,
      posterUrl: (json['posterUrl'] ?? '').toString().trim(),
      backdropUrl: (json['backdropUrl'] ?? '').toString().trim(),
      synopsis: (json['synopsis'] ?? '').toString().trim(),
      doubanScore: score,
      episodeOffset: (json['episodeOffset'] as num?)?.toInt() ?? 0,
      sortByScrapedEpisode: json['sortByScrapedEpisode'] is bool
          ? json['sortByScrapedEpisode'] as bool
          : null,
      hideSpecials: json['hideSpecials'] == true,
      danmuTitleOverride: (json['danmuTitleOverride'] ?? '').toString().trim(),
      danmuAnimeId: (json['danmuAnimeId'] ?? '').toString().trim(),
      danmuOrigin: (json['danmuOrigin'] ?? '').toString().trim(),
      episodeNumberOverrides: epOverrides,
      updatedAtMs: (json['updatedAtMs'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Unified series-identity classifier, episode-number scraper, and interactive
/// multi-source scraper (Douban Rexxar / Bangumi / Bilibili PGC).
class SeriesScraper {
  SeriesScraper._();

  static const String _mobileUa =
      'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1';
  static const String _desktopUa =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';
  static const String _biliCookie =
      'buvid3=58D32EBE-894C-69EE-AE53-607BE1EC3CC597728infoc; b_nut=1793900397';

  static final math.Random _rng = math.Random();
  static final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 5)
    ..idleTimeout = const Duration(seconds: 20)
    ..maxConnectionsPerHost = 10
    ..autoUncompress = true;

  static final RegExp _motionComicRe = RegExp(
    r'动态漫画|动态漫|漫动画|有声漫画|有声漫|条漫|沙雕动画|动画漫画|国产动态漫',
    caseSensitive: false,
  );
  static final RegExp _audioBookRe = RegExp(
    r'[\(（\[【·\s](?:音频|有声书|有声小说|广播剧|多人有声剧)[\)）\]】\s$]|（音频）|\(音频\)',
    caseSensitive: false,
  );
  static final RegExp _recapRe = RegExp(
    r'(?:^|[\s_·\-—:：\(（\[【])(?:解说|速看|剧情解析|合集解说|深度解说|一口气看完)',
    caseSensitive: false,
  );
  static final RegExp _gameRe = RegExp(
    r'手游网|游戏下载|全集下载|端游|网游|手游攻略|客户端下载|官方手游',
    caseSensitive: false,
  );

  // ---------------------------------------------------------------------------
  // 1. Work-Form Classification & Roman/Season/Year Title Normalization
  // ---------------------------------------------------------------------------

  /// Detects whether [rawTitle] (and optional [extraContext] like `tag`,
  /// `remarks`, `subtitle`, or `abstract`) refers to a dynamic comic
  /// (`动态漫画` / `动态漫`), audio book, recap, game, or standard film/TV/anime.
  static MediaWorkForm detectWorkForm(
    String rawTitle, {
    String extraContext = '',
  }) {
    final combined = '$rawTitle $extraContext';
    if (_motionComicRe.hasMatch(combined)) {
      return MediaWorkForm.motionComic;
    }
    if (_audioBookRe.hasMatch(combined)) {
      return MediaWorkForm.audioBook;
    }
    if (_recapRe.hasMatch(rawTitle)) {
      return MediaWorkForm.recap;
    }
    if (_gameRe.hasMatch(combined)) {
      return MediaWorkForm.game;
    }
    return MediaWorkForm.standard;
  }

  /// Shorthand checking if the raw title / metadata explicitly indicates a
  /// motion comic (`动态漫画` / `动态漫` / `漫动画`).
  static bool isMotionComicText(
    String rawTitle, {
    String extraContext = '',
  }) =>
      detectWorkForm(rawTitle, extraContext: extraContext) ==
      MediaWorkForm.motionComic;

  /// Checks whether a candidate work form is compatible with the target work
  /// form. Dynamic comics (`动态漫画`) NEVER match regular anime/dramas and vice
  /// versa; audio books / recaps / games never match standard works.
  static bool isCompatibleWorkForm({
    required bool targetIsMotionComic,
    required String candidateTitle,
    String candidateContext = '',
  }) {
    final candForm = detectWorkForm(
      candidateTitle,
      extraContext: candidateContext,
    );
    if (targetIsMotionComic) {
      return candForm == MediaWorkForm.motionComic;
    }
    return candForm == MediaWorkForm.standard;
  }

  /// Normalizes Roman numerals used as sequel markers (`斗罗大陆Ⅱ绝世唐门` /
  /// `斗罗大陆II绝世唐门` / `庆余年Ⅱ` -> `斗罗大陆2绝世唐门` / `庆余年2`) without
  /// mangling English words like `VIP` or `AI`.
  static String normalizeSequelNumerals(String raw) {
    var s = raw
        .replaceAll('Ⅰ', '1')
        .replaceAll('Ⅱ', '2')
        .replaceAll('Ⅲ', '3')
        .replaceAll('Ⅳ', '4')
        .replaceAll('Ⅴ', '5')
        .replaceAll('Ⅵ', '6')
        .replaceAll('Ⅶ', '7')
        .replaceAll('Ⅷ', '8')
        .replaceAll('Ⅸ', '9')
        .replaceAll('Ⅹ', '10');
    // ASCII Roman numerals adjacent to CJK characters or at trailing sequel position.
    s = s.replaceAllMapped(
      RegExp(
        r'(?<=[\u4e00-\u9fff\s·:：\-—])(III|II|IV|VI|V)(?=$|[\u4e00-\u9fff\s·:：\-—\(（\[【])',
      ),
      (m) => switch (m.group(1)) {
        'II' => '2',
        'III' => '3',
        'IV' => '4',
        'V' => '5',
        'VI' => '6',
        _ => m.group(0)!,
      },
    );
    return s;
  }

  /// Cleans a series title for comparison while normalizing sequel Roman
  /// numerals and stripping broadcast suffixes (`年番1`, `动态漫画`, quality tags,
  /// trailing year). Call [isMotionComicText] BEFORE calling this.
  static String normalizeWorkCoreTitle(String rawTitle) {
    var s = rawTitle
        .replaceAll(RegExp(r'<[^>]+>'), '')
        .replaceAll(RegExp(r'_360百科.*$|-360百科.*$|_百度百科.*$'), '')
        .replaceAll(RegExp(r'[\(（\[【].*?[\)）\]】]'), '')
        .replaceAll(_motionComicRe, '')
        .replaceAll(
          RegExp(
            r'[\s·\-—:：]*(?:更新至|更至|更新到|连载至|全\s*\d+\s*[集期话篇章]|共\s*\d+\s*[集期话篇章]|已完结|完结).*$',
          ),
          '',
        )
        .replaceAll(
          RegExp(
            r'[\s·\-—:：]*(?:年番\s*[0-9一二三四五六七八九十]*|第[0-9一二三四五六七八九十百零〇]+[季部集期篇章话])',
          ),
          '',
        )
        .replaceAll(
          RegExp(
            r'(?<![A-Za-z0-9])(?:4K|2160[pP]|1080[pP]|720[pP]|HD|BD|HDR|SDR|TC|TS)(?![A-Za-z0-9])',
            caseSensitive: false,
          ),
          '',
        )
        .replaceAll(
          RegExp(
            r'[\s·\-—:：]*(?:臻彩|杜比视界|杜比|高码|原盘|国粤双语|国语|粤语|中字|双语|超清|高清|蓝光|未删减版?|完整版?|抢先版?)\s*$',
          ),
          '',
        )
        .replaceAll(RegExp(r'(?:19|20)\d{2}\s*$'), '')
        .trim();
    s = normalizeSequelNumerals(s);
    return s
        .replaceAll(RegExp(r'[《》〈〉「」『』"“”\x27‘’：:·—\-\s_!！?？,，.。]'), '')
        .toLowerCase();
  }

  /// Extracts a clean display/search title suitable for Danmu & external APIs,
  /// preserving spaces/colons and stripping resolution/edition clutter.
  static String cleanSearchTitle(String rawTitle) {
    return rawTitle
        .replaceAll(RegExp(r'<[^>]+>'), '')
        .replaceAll(RegExp(r'[\(（\[【].*?[\)）\]】]'), '')
        .replaceAll(_motionComicRe, '')
        .replaceAll(
          RegExp(
            r'[\s·\-—:：]*(?:更新至|更至|更新到|连载至|全\s*\d+\s*[集期话篇章]|共\s*\d+\s*[集期话篇章]|已完结|完结).*$',
          ),
          '',
        )
        .replaceAll(
          RegExp(
            r'(?<![A-Za-z0-9])(?:4K|2160[pP]|1080[pP]|720[pP]|HD|BD|HDR|SDR|TC|TS)(?![A-Za-z0-9])',
            caseSensitive: false,
          ),
          '',
        )
        .replaceAll(
          RegExp(
            r'[\s·\-—:：]*(?:臻彩|杜比视界|杜比|高码|原盘|国粤双语|国语|粤语|中字|双语|超清|高清|蓝光|未删减版?|完整版?|抢先版?)\s*$',
          ),
          '',
        )
        .replaceAll(RegExp(r'(?:19|20)\d{2}\s*$'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  // ---------------------------------------------------------------------------
  // 2. In-Series Episode Number & Special Scraper
  // ---------------------------------------------------------------------------

  static final RegExp _specialKeywordRe = RegExp(
    r'(?:预告|抢先看|片花|花絮|特辑|彩蛋|幕后|采访|访谈|宣发|宣传片|定档|先导片?|总集篇|精编|纯享|加更|合集说明|群聊|二维码|广告|'
    r'番外|特别篇|剧场版|'
    r'(?<![A-Za-z])(?:SP|OVA|OAD|PV|CM|OP|ED|MV|OST|NCOP|NCED|Trailer|Preview|Teaser|Extras?)(?![A-Za-z]))',
    caseSensitive: false,
  );

  static final RegExp _techNoiseRe = RegExp(
    r'\[\s*\d+(?:\.\d+)?\s*[KMGT]?B\s*\]|'
    r'\(\s*\d+(?:\.\d+)?\s*[KMGT]?B\s*\)|'
    r'(?<![A-Za-z0-9])(?:'
    r'4K|8K|2K|UHD|FHD|HD|BD|BluRay|Blu-?Ray|WEB-?DL|WEBRip|BDRip|HDRip|DVDRip|REMUX|'
    r'2160[pP]|1440[pP]|1080[pPiI]|720[pP]|576[pP]|480[pP]|360[pP]|'
    r'(?:24|25|30|50|60|120)\s*(?:fps|帧|Hz)|'
    r'(?:8|10|12)\s*bit|'
    r'[HxXx]\.?26[45]|HEVC|AVC|AV1|VP9|MPEG[24]|'
    r'HDR10\+?|HDR|SDR|DoVi|DV|Dolby|Atmos|DDP\s*5\.1|DD\s*5\.1|DTS(?:-?HD)?|AAC\s*2\.0|FLAC|AC3|5\.1|7\.1|2\.0|'
    r'60帧|120帧|高帧率|高码率?|臻彩|杜比视界|杜比|原盘|蓝光|超清|高清|国粤双语|国语|粤语|中字|双语|简繁|内封|内嵌|无水印|官中'
    r')(?![A-Za-z0-9])',
    caseSensitive: false,
  );

  static String _extractQualityTag(String rawName) {
    final upper = rawName.toUpperCase();
    final parts = <String>[];
    if (upper.contains('4K') || upper.contains('2160P')) {
      parts.add('4K');
    } else if (upper.contains('1080P')) {
      parts.add('1080P');
    } else if (upper.contains('720P')) {
      parts.add('720P');
    }
    if (upper.contains('DOVI') ||
        upper.contains('杜比视界') ||
        RegExp(r'(?<![A-Z])DV(?![A-Z])').hasMatch(upper)) {
      parts.add('杜比');
    } else if (upper.contains('HDR')) {
      parts.add('HDR');
    }
    if (RegExp(r'60\s*(?:FPS|帧)', caseSensitive: false).hasMatch(rawName)) {
      parts.add('60帧');
    }
    final sizeMatch = RegExp(
      r'[\[\(]\s*(\d+(?:\.\d+)?\s*[GM]B)\s*[\]\)]',
      caseSensitive: false,
    ).firstMatch(rawName);
    if (sizeMatch != null && parts.isEmpty) {
      parts.add(sizeMatch.group(1)!.toUpperCase());
    }
    return parts.take(2).join(' · ');
  }

  static String _stripFileExtension(String raw) {
    return raw
        .replaceAll(
          RegExp(
            r'\.(?:mp4|mkv|ts|m2ts|flv|avi|mov|rmvb|wmv|webm|m3u8|iso)$',
            caseSensitive: false,
          ),
          '',
        )
        .trim();
  }

  static int? _parseChineseInt(String token) {
    final trimmed = token.trim();
    final arabic = int.tryParse(trimmed);
    if (arabic != null) return arabic;
    const digits = <String, int>{
      '零': 0,
      '〇': 0,
      '一': 1,
      '二': 2,
      '两': 2,
      '三': 3,
      '四': 4,
      '五': 5,
      '六': 6,
      '七': 7,
      '八': 8,
      '九': 9,
    };
    int total = 0;
    int current = 0;
    bool seen = false;
    for (int i = 0; i < trimmed.length; i++) {
      final ch = trimmed[i];
      if (digits.containsKey(ch)) {
        current = digits[ch]!;
        seen = true;
      } else if (ch == '十') {
        total += (current == 0 ? 1 : current) * 10;
        current = 0;
        seen = true;
      } else if (ch == '百') {
        total += (current == 0 ? 1 : current) * 100;
        current = 0;
        seen = true;
      } else if (ch == '千') {
        total += (current == 0 ? 1 : current) * 1000;
        current = 0;
        seen = true;
      } else {
        return null;
      }
    }
    if (!seen) return null;
    return total + current;
  }

  static String _stripSeriesTitleFromEpisode(
    String cleanedName,
    String seriesTitle,
  ) {
    var text = normalizeSequelNumerals(cleanedName);
    final cleanSeries = cleanSearchTitle(seriesTitle);
    if (cleanSeries.isEmpty) return text;

    final candidates = <String>{
      seriesTitle.trim(),
      cleanSeries,
      normalizeSequelNumerals(cleanSeries),
      cleanSeries.replaceAll(RegExp(r'[\s:：·\-—_]+'), ''),
      normalizeSequelNumerals(cleanSeries)
          .replaceAll(RegExp(r'[\s:：·\-—_]+'), ''),
    }..removeWhere((s) => s.length < 2);

    final sorted = candidates.toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    for (final c in sorted) {
      final escaped = RegExp.escape(c);
      final stripped = text.replaceAll(
        RegExp(escaped, caseSensitive: false),
        ' ',
      );
      if (stripped.trim().isNotEmpty) {
        text = stripped;
      }
    }
    // Also strip individual CJK title segments separated by colons/spaces when
    // length >= 3 (e.g. `斗罗大陆2：绝世唐门` -> `斗罗大陆2`, `绝世唐门`).
    for (final part in cleanSeries.split(RegExp(r'[:：·\-—\s]+'))) {
      final p = part.trim();
      if (p.length >= 3) {
        final stripped = text.replaceAll(
          RegExp(RegExp.escape(p), caseSensitive: false),
          ' ',
        );
        if (stripped.trim().isNotEmpty) {
          text = stripped;
        }
      }
    }
    return text.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  /// Scrapes a single episode filename/label into structured season, episode
  /// number, special classification, and clean display label.
  static ScrapedEpisodeInfo scrapeEpisodeName(
    String rawName, {
    int originalIndex = 0,
    String seriesTitle = '',
    int episodeOffset = 0,
    int? manualEpisodeOverride,
    Set<int> constantNumbers = const {},
    String sharedPrefix = '',
  }) {
    final trimmed = rawName.trim();
    final qualityTag = _extractQualityTag(trimmed);
    var work = _stripFileExtension(trimmed);

    // 1. Detect explicit manual override first.
    if (manualEpisodeOverride != null && manualEpisodeOverride > 0) {
      return ScrapedEpisodeInfo(
        originalIndex: originalIndex,
        rawName: rawName,
        rawEpisodeNumber: manualEpisodeOverride,
        effectiveEpisodeNumber: manualEpisodeOverride,
        isSpecial: false,
        qualityTag: qualityTag,
        displayLabel: '第 $manualEpisodeOverride 集',
        confidence: 1.0,
        hasManualOverride: true,
      );
    }

    // Remove series title prefix so sequel numbers (`斗罗大陆2`, `庆余年2`) or
    // special-sounding words inside the series title don't cause false hits.
    var withoutSeries = _stripSeriesTitleFromEpisode(work, seriesTitle);
    if (sharedPrefix.length >= 2 &&
        withoutSeries.startsWith(sharedPrefix) &&
        withoutSeries.length > sharedPrefix.length) {
      withoutSeries = withoutSeries.substring(sharedPrefix.length).trim();
    }

    // 2. Detect explicit specials / trailers / previews / SP / OVA / extras.
    final specialMatch = _specialKeywordRe.firstMatch(withoutSeries);
    if (specialMatch != null) {
      final matchedToken = specialMatch.group(0)!.trim();
      final spNumMatch = RegExp(
        '(?:${RegExp.escape(matchedToken)})\\s*0*(\\d{1,3})',
        caseSensitive: false,
      ).firstMatch(withoutSeries);
      final spTag = spNumMatch != null
          ? '${matchedToken.toUpperCase() == matchedToken ? matchedToken : matchedToken}${spNumMatch.group(1)}'
          : matchedToken;
      final cleanLabel = withoutSeries
          .replaceAll(_techNoiseRe, '')
          .replaceAll(RegExp(r'[\[\(【（]\s*[\]\)】）]'), '')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      return ScrapedEpisodeInfo(
        originalIndex: originalIndex,
        rawName: rawName,
        isSpecial: true,
        specialTag: spTag,
        qualityTag: qualityTag,
        displayLabel: cleanLabel.isNotEmpty ? cleanLabel : spTag,
        confidence: 0.95,
      );
    }

    // 3. Extract explicit season number if present (`S02E05`, `第2季`).
    int? seasonNum;
    final cnSeason = RegExp(
      r'第\s*([0-9一二三四五六七八九十两]+)\s*[季部]',
    ).firstMatch(withoutSeries);
    if (cnSeason != null) {
      final n = _parseChineseInt(cnSeason.group(1)!);
      if (n != null && n > 0 && n <= 99) seasonNum = n;
    }

    int? rawEp;
    int? endEp;
    double confidence = 0.0;

    // Pattern A: SxxExx / Sxx.Exx / Sxx-EPxx (highest precision)
    final seMatch = RegExp(
      r'(?:^|[^A-Za-z0-9])[Ss]0*(\d{1,2})[\s._\-]*[Ee][Pp]?0*(\d{1,4})(?:\s*[-~]\s*[Ee]?[Pp]?0*(\d{1,4}))?(?![0-9])',
    ).firstMatch(withoutSeries);
    if (seMatch != null) {
      seasonNum = int.tryParse(seMatch.group(1)!) ?? seasonNum;
      rawEp = int.tryParse(seMatch.group(2)!);
      if (seMatch.group(3) != null) {
        endEp = int.tryParse(seMatch.group(3)!);
      }
      confidence = 1.0;
    }

    // Pattern B: Chinese explicit `第180集` / `第01-02集` / `第12话` / `第一百八十集`
    if (rawEp == null) {
      final cnEpMatch = RegExp(
        r'第\s*0*([0-9一二三四五六七八九十百千万两〇零]{1,6})\s*(?:[-~至到]\s*0*([0-9]{1,4})\s*)?[集话話回章]',
      ).firstMatch(withoutSeries);
      if (cnEpMatch != null) {
        rawEp = _parseChineseInt(cnEpMatch.group(1)!);
        if (cnEpMatch.group(2) != null) {
          endEp = int.tryParse(cnEpMatch.group(2)!);
        }
        confidence = 0.98;
      }
    }

    // Strip technical noise & release years before looser numeric patterns.
    final denoised = withoutSeries
        .replaceAll(_techNoiseRe, ' ')
        // Remove standalone 4-digit years (1950-2039) when bounded.
        .replaceAll(
          RegExp(r'(?<![0-9])(?:19[5-9]\d|20[0-3]\d)(?![0-9])'),
          ' ',
        )
        // Remove season labels already extracted so `第2季` doesn't match `2`.
        .replaceAll(RegExp(r'第\s*[0-9一二三四五六七八九十两]+\s*[季部]'), ' ')
        .replaceAll(RegExp(r'(?<![A-Za-z0-9])[Ss]0*\d{1,2}(?![A-Za-z0-9])'), ' ')
        // Remove resolution pixel dimensions like `1920x1080` or `3840x2160`.
        .replaceAll(RegExp(r'\b\d{3,4}\s*[xX×]\s*\d{3,4}\b'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    // Pattern C: Explicit `EP180` / `E180` / `E01-E02`
    if (rawEp == null) {
      final epPrefixMatch = RegExp(
        r'(?:^|[\s._\-\[\(【（])(?:EP|Ep|ep|E)\s*0*(\d{1,4})(?:\s*[-~]\s*(?:EP|Ep|ep|E)?0*(\d{1,4}))?(?![0-9A-Za-z])',
      ).firstMatch(denoised);
      if (epPrefixMatch != null) {
        rawEp = int.tryParse(epPrefixMatch.group(1)!);
        if (epPrefixMatch.group(2) != null) {
          endEp = int.tryParse(epPrefixMatch.group(2)!);
        }
        confidence = 0.95;
      }
    }

    // Pattern D: Explicit variety show date issue (`20260315期`) — keep label as-is.
    if (rawEp == null &&
        RegExp(r'(?:19|20)\d{6}\s*期|第\s*\d+\s*期').hasMatch(withoutSeries)) {
      final cleanVariety = withoutSeries
          .replaceAll(_techNoiseRe, ' ')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      return ScrapedEpisodeInfo(
        originalIndex: originalIndex,
        rawName: rawName,
        seasonNumber: seasonNum,
        qualityTag: qualityTag,
        displayLabel: cleanVariety.isNotEmpty ? cleanVariety : trimmed,
        confidence: 0.7,
      );
    }

    // Pattern E: Bracketed episode number (`[180]`, `【05】`, `(12完)`)
    if (rawEp == null) {
      final bracketMatches = RegExp(
        r'[\[\(【（]\s*0*(\d{1,4})\s*(?:[-~]\s*0*(\d{1,4})\s*)?(?:集|话|完|完结|END|v\d)?\s*[\]\)】）]',
        caseSensitive: false,
      ).allMatches(denoised);
      for (final m in bracketMatches) {
        final n = int.tryParse(m.group(1)!);
        if (n != null && n >= 0 && n <= 3000 && !constantNumbers.contains(n)) {
          rawEp = n;
          if (m.group(2) != null) endEp = int.tryParse(m.group(2)!);
          confidence = 0.90;
          break;
        }
      }
    }

    // Pattern F: Delimited or standalone episode number (`180 4K.mp4` -> `180`,
    // `绝世唐门 - 180` -> `180`, `01.mp4` -> `1`, `180_HDR` -> `180`).
    if (rawEp == null) {
      // Collect all candidate numbers in denoised text.
      final numMatches = RegExp(
        r'(?<![0-9A-Za-z])0*(\d{1,4})(?:\s*[-~]\s*0*(\d{1,4}))?(?![0-9A-Za-z])',
      ).allMatches(denoised).toList();
      final filtered = <({int n, int? end, int pos})>[];
      for (final m in numMatches) {
        final n = int.tryParse(m.group(1)!);
        if (n == null || n < 0 || n > 3000) continue;
        if (constantNumbers.contains(n)) continue;
        final e = m.group(2) != null ? int.tryParse(m.group(2)!) : null;
        filtered.add((n: n, end: e, pos: m.start));
      }
      if (filtered.isNotEmpty) {
        // When the entire denoised string is just a number (e.g. `180 4K.mp4`),
        // confidence is very high; otherwise prefer the rightmost non-constant
        // episode token (common in `Title - 180` or `Title_01`).
        final picked = filtered.last;
        rawEp = picked.n;
        endEp = picked.end;
        confidence =
            RegExp(r'^0*\d{1,4}(?:\s*[-~]\s*0*\d{1,4})?$').hasMatch(denoised)
                ? 0.92
                : 0.82;
      }
    }

    // Treat Episode 0 (`00.mp4`, `E00`, `第0集`) as a prologue/special so it
    // does not collide with Episode 1 or shift episode numbering.
    if (rawEp == 0) {
      return ScrapedEpisodeInfo(
        originalIndex: originalIndex,
        rawName: rawName,
        seasonNumber: seasonNum,
        rawEpisodeNumber: 0,
        isSpecial: true,
        specialTag: '第0集',
        qualityTag: qualityTag,
        displayLabel: '第 0 集',
        confidence: confidence,
      );
    }

    if (rawEp != null && rawEp > 0) {
      final effective = math.max(1, rawEp + episodeOffset);
      final effectiveEnd =
          (endEp != null && endEp > rawEp) ? (endEp + episodeOffset) : null;
      final label = effectiveEnd != null
          ? '第 $effective–$effectiveEnd 集'
          : '第 $effective 集';
      return ScrapedEpisodeInfo(
        originalIndex: originalIndex,
        rawName: rawName,
        seasonNumber: seasonNum,
        rawEpisodeNumber: rawEp,
        endEpisodeNumber: endEp,
        effectiveEpisodeNumber: effective,
        isSpecial: false,
        qualityTag: qualityTag,
        displayLabel: label,
        confidence: confidence,
      );
    }

    final fallbackLabel = work
        .replaceAll(_techNoiseRe, ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return ScrapedEpisodeInfo(
      originalIndex: originalIndex,
      rawName: rawName,
      seasonNumber: seasonNum,
      qualityTag: qualityTag,
      displayLabel: fallbackLabel.isNotEmpty ? fallbackLabel : trimmed,
      confidence: 0.0,
    );
  }

  /// Scrapes every episode in [episodes] together, detecting shared prefixes,
  /// constant series/release numbers (so e.g. `2` in `斗罗大陆2` is never mistaken
  /// for Episode 2), specials/trailers, and lexicographically scrambled order.
  static LineEpisodeScrapeResult scrapeLineEpisodes(
    List<CmsEpisode> episodes, {
    String seriesTitle = '',
    int episodeOffset = 0,
    Map<String, int> manualOverrides = const {},
  }) {
    if (episodes.isEmpty) {
      return const LineEpisodeScrapeResult(
        byOriginalIndex: [],
        sortedRegularIndices: [],
        specialIndices: [],
        unparsedIndices: [],
        sourceOrderScrambled: false,
        regularCount: 0,
        specialCount: 0,
      );
    }

    // 1. Find shared prefix and numbers that appear in >= 80% of filenames
    // (e.g. franchise number `2` in `斗罗大陆2_01.mp4`, `斗罗大陆2_02.mp4`, ...).
    final strippedNames = episodes
        .map((e) => _stripSeriesTitleFromEpisode(
              _stripFileExtension(e.name.trim()),
              seriesTitle,
            ))
        .toList(growable: false);

    String sharedPrefix = '';
    if (strippedNames.length >= 3) {
      var prefix = strippedNames.first;
      for (int i = 1; i < strippedNames.length && prefix.isNotEmpty; i++) {
        final cur = strippedNames[i];
        int j = 0;
        final limit = math.min(prefix.length, cur.length);
        while (j < limit && prefix.codeUnitAt(j) == cur.codeUnitAt(j)) {
          j++;
        }
        prefix = prefix.substring(0, j);
      }
      // Trim trailing digits from sharedPrefix so `E0` in `E01..E09` isn't stripped!
      prefix = prefix.replaceAll(RegExp(r'(?:[Ss]\d*[Ee]?|[Ee][Pp]?|\d+)$'), '');
      if (prefix.trim().length >= 2) {
        sharedPrefix = prefix;
      }
    }

    final constantNumbers = <int>{};
    if (episodes.length >= 4) {
      final numFreq = <int, int>{};
      for (final raw in strippedNames) {
        final denoised = raw.replaceAll(_techNoiseRe, ' ');
        final uniqueNums = <int>{};
        for (final m in RegExp(r'(?<![0-9])\d{1,4}(?![0-9])').allMatches(denoised)) {
          final n = int.tryParse(m.group(0)!);
          if (n != null) uniqueNums.add(n);
        }
        for (final n in uniqueNums) {
          numFreq[n] = (numFreq[n] ?? 0) + 1;
        }
      }
      final threshold = (episodes.length * 0.8).ceil();
      for (final entry in numFreq.entries) {
        if (entry.value >= threshold) {
          constantNumbers.add(entry.key);
        }
      }
    }

    // 2. Scrape each episode.
    final scraped = <ScrapedEpisodeInfo>[];
    final regularInfos = <ScrapedEpisodeInfo>[];
    final specialIndices = <int>[];
    final unparsedIndices = <int>[];

    for (int i = 0; i < episodes.length; i++) {
      final ep = episodes[i];
      final manual = manualOverrides[ep.name];
      final info = scrapeEpisodeName(
        ep.name,
        originalIndex: i,
        seriesTitle: seriesTitle,
        episodeOffset: episodeOffset,
        manualEpisodeOverride: manual,
        constantNumbers: constantNumbers,
        sharedPrefix: sharedPrefix,
      );
      scraped.add(info);
      if (info.isSpecial) {
        specialIndices.add(i);
      } else if (info.effectiveEpisodeNumber != null) {
        regularInfos.add(info);
      } else {
        unparsedIndices.add(i);
      }
    }

    // 3. Detect if the source order is scrambled (e.g. lexicographical
    // `1, 10, 100, 11, 2` or mixed specials in front of Episode 1).
    bool scrambled = false;
    if (regularInfos.length >= 3) {
      int ascSteps = 0;
      int descSteps = 0;
      for (int i = 1; i < regularInfos.length; i++) {
        final prev = regularInfos[i - 1];
        final cur = regularInfos[i];
        final prevKey = (prev.seasonNumber ?? 0) * 100000 +
            (prev.effectiveEpisodeNumber ?? 0);
        final curKey = (cur.seasonNumber ?? 0) * 100000 +
            (cur.effectiveEpisodeNumber ?? 0);
        if (curKey > prevKey) ascSteps++;
        if (curKey < prevKey) descSteps++;
      }
      // Scrambled if neither cleanly ascending nor cleanly descending, OR if
      // specials were intermixed before regular episodes (causing index shift).
      final isCleanAsc = descSteps == 0;
      final isCleanDesc = ascSteps == 0;
      if (!isCleanAsc && !isCleanDesc) {
        scrambled = true;
      } else if (isCleanDesc && regularInfos.length >= 3) {
        // Reverse-sorted shares (180..01) are also normalized to ascending so
        // the user's 正序/倒序 toggle behaves predictably.
        scrambled = true;
      }
    }
    if (!scrambled &&
        specialIndices.isNotEmpty &&
        regularInfos.isNotEmpty &&
        specialIndices.first < regularInfos.last.originalIndex) {
      scrambled = true;
    }

    final sortedRegular = List<ScrapedEpisodeInfo>.from(regularInfos)
      ..sort((a, b) {
        final sCmp = (a.seasonNumber ?? 0).compareTo(b.seasonNumber ?? 0);
        if (sCmp != 0) return sCmp;
        final eCmp = (a.effectiveEpisodeNumber ?? 0)
            .compareTo(b.effectiveEpisodeNumber ?? 0);
        if (eCmp != 0) return eCmp;
        return a.originalIndex.compareTo(b.originalIndex);
      });

    int? minEp;
    int? maxEp;
    for (final r in sortedRegular) {
      final n = r.effectiveEpisodeNumber;
      if (n != null) {
        minEp = minEp == null ? n : math.min(minEp, n);
        maxEp = maxEp == null ? n : math.max(maxEp, n);
      }
    }

    return LineEpisodeScrapeResult(
      byOriginalIndex: List<ScrapedEpisodeInfo>.unmodifiable(scraped),
      sortedRegularIndices: List<int>.unmodifiable(
        sortedRegular.map((e) => e.originalIndex),
      ),
      specialIndices: List<int>.unmodifiable(specialIndices),
      unparsedIndices: List<int>.unmodifiable(unparsedIndices),
      sourceOrderScrambled: scrambled,
      regularCount: regularInfos.length,
      specialCount: specialIndices.length,
      minEpisodeNumber: minEp,
      maxEpisodeNumber: maxEp,
    );
  }

  // ---------------------------------------------------------------------------
  // 3. Interactive Multi-Source Series Scraping (Douban / Bangumi / Bilibili)
  // ---------------------------------------------------------------------------

  static String _randomBid() {
    const chars =
        'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    final sb = StringBuffer();
    for (int i = 0; i < 11; i++) {
      sb.write(chars[_rng.nextInt(chars.length)]);
    }
    return sb.toString();
  }

  static String _upgradeCoverUrl(String raw) {
    var u = raw.trim();
    if (u.isEmpty) return '';
    if (u.startsWith('//')) u = 'https:$u';
    if (u.contains('doubanio.com')) {
      u = u
          .replaceFirst('img9.doubanio.com', 'img3.doubanio.com')
          .replaceFirst('/s_ratio_poster/', '/l_ratio_poster/')
          .replaceFirst('/m_ratio_poster/', '/l_ratio_poster/');
      // Strip Rexxar `qnmob3-sign` small h/120 resize when unsigned, or normalize.
      if (u.contains('qnmob3-sign.doubanio.com') &&
          u.contains('/view/photo/large/public/')) {
        final match = RegExp(r'/view/photo/large/public/(p\d+\.[a-z]+)')
            .firstMatch(u);
        if (match != null) {
          u = 'https://img3.doubanio.com/view/photo/l_ratio_poster/public/${match.group(1)}';
        }
      }
      if (u.endsWith('.webp')) {
        u = '${u.substring(0, u.length - 5)}.jpg';
      }
    } else if (u.contains('lain.bgm.tv/pic/cover/')) {
      u = u.replaceFirst('http://', 'https://').replaceFirst(
            RegExp(r'/pic/cover/[csgm]/'),
            '/pic/cover/l/',
          );
    } else if (u.contains('hdslb.com') || u.contains('biliimg.com')) {
      if (u.startsWith('http://')) {
        u = u.replaceFirst('http://', 'https://');
      }
      final atIdx = u.indexOf('@');
      if (atIdx > 0) u = u.substring(0, atIdx);
    }
    return u;
  }

  static Future<String?> _getText(
    Uri uri, {
    required Map<String, String> headers,
    Duration timeout = const Duration(milliseconds: 3500),
  }) async {
    HttpClientRequest? req;
    try {
      req = await _client.getUrl(uri).timeout(timeout);
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
    }
    return null;
  }

  /// Searches Douban Rexxar (`search/weixin`), Bangumi (`api.bgm.tv`), and
  /// Bilibili PGC (`media_bangumi` / `media_ft`) for interactive in-series
  /// scraping. [filter] may be `'all'`, `'standard'`, `'motion_comic'`, or
  /// `'movie'`.
  static Future<List<SeriesScrapeCandidate>> searchCandidates(
    String keyword, {
    String filter = 'all',
  }) async {
    final q = keyword.trim();
    if (q.isEmpty) return const [];
    if (Platform.environment.containsKey('FLUTTER_TEST')) {
      return const [];
    }

    final doubanList = <SeriesScrapeCandidate>[];
    final bangumiList = <SeriesScrapeCandidate>[];
    final biliList = <SeriesScrapeCandidate>[];
    final bidCookie = 'bid=${_randomBid()}';

    await Future.wait([
      // 1. Douban Rexxar weixin search
      () async {
        final body = await _getText(
          Uri.https('m.douban.com', '/rexxar/api/v2/search/weixin', {
            'q': q,
            'count': '12',
          }),
          headers: {
            'User-Agent': _mobileUa,
            'Referer': 'https://m.douban.com/',
            'Cookie': bidCookie,
            'Accept': 'application/json',
          },
        );
        if (body == null) return;
        try {
          final decoded = jsonDecode(body);
          if (decoded is! Map) return;
          final subjects = decoded['subjects'];
          final items =
              (subjects is Map ? subjects['items'] : null) ?? decoded['items'];
          if (items is! List) return;
          for (final entry in items.whereType<Map>()) {
            final target = entry['target'] is Map
                ? Map<String, dynamic>.from(entry['target'] as Map)
                : Map<String, dynamic>.from(entry);
            final type =
                (entry['target_type'] ?? target['type'] ?? '')
                    .toString()
                    .toLowerCase();
            if (type != 'movie' && type != 'tv') continue;
            final id = (target['id'] ?? '').toString().trim();
            final title = (target['title'] ?? '').toString().trim();
            if (id.isEmpty || title.isEmpty) continue;
            final year = (target['year'] ?? '').toString().trim();
            final cardSub = (target['card_subtitle'] ?? '').toString().trim();
            final isMc = isMotionComicText(title, extraContext: cardSub);
            final isAnime = cardSub.contains('动画') || cardSub.contains('动漫');
            final badge = isMc
                ? '动态漫画'
                : (isAnime ? '动漫' : (type == 'tv' ? '剧集' : '电影'));
            final ratingMap = target['rating'];
            final rawRating =
                ratingMap is Map ? ratingMap['value'] : target['rating'];
            final rating = rawRating is num
                ? rawRating.toDouble()
                : double.tryParse('$rawRating');
            final pic = target['pic'];
            final rawCover = (target['cover_url'] ??
                    (pic is Map ? (pic['large'] ?? pic['normal'] ?? '') : ''))
                .toString()
                .trim();
            doubanList.add(
              SeriesScrapeCandidate(
                source: 'douban',
                subjectId: id,
                title: title,
                subtitle: cardSub,
                year: year,
                isTv: type == 'tv',
                isMotionComic: isMc,
                mediaBadge: badge,
                posterUrl: _upgradeCoverUrl(rawCover),
                rating:
                    (rating != null && rating >= 2.0 && rating <= 10.0)
                        ? rating
                        : null,
              ),
            );
          }
        } catch (_) {}
      }(),

      // 2. Bangumi Open API (great for anime & donghua)
      () async {
        final body = await _getText(
          Uri.parse(
            'https://api.bgm.tv/search/subject/${Uri.encodeComponent(q)}?responseGroup=large',
          ),
          headers: {
            'User-Agent': _desktopUa,
            'Accept': 'application/json',
          },
        );
        if (body == null) return;
        try {
          final decoded = jsonDecode(body);
          final list = decoded is Map ? decoded['list'] : null;
          if (list is! List) return;
          for (final item in list.whereType<Map>().take(10)) {
            final t = item['type'];
            if (t != 2 && t != 6) continue;
            final id = (item['id'] ?? '').toString().trim();
            final nameCn = (item['name_cn'] ?? '').toString().trim();
            final name = (item['name'] ?? '').toString().trim();
            final title = nameCn.isNotEmpty ? nameCn : name;
            if (id.isEmpty || title.isEmpty) continue;
            final airDate = (item['air_date'] ?? '').toString().trim();
            final yMatch = RegExp(r'^((?:19|20)\d{2})').firstMatch(airDate);
            final year = yMatch?.group(1) ?? '';
            final summary = (item['summary'] ?? '').toString().trim();
            final isMc = isMotionComicText(
              '$nameCn $name',
              extraContext: summary,
            );
            final badge = isMc ? '动态漫画' : (t == 2 ? '动漫' : '剧集');
            final images = item['images'];
            final cover = images is Map
                ? (images['large'] ?? images['common'] ?? '').toString().trim()
                : '';
            final eps = (item['eps_count'] ?? item['eps']) as num?;
            final ratingMap = item['rating'];
            final rawScore = ratingMap is Map ? ratingMap['score'] : null;
            final score = rawScore is num ? rawScore.toDouble() : null;
            bangumiList.add(
              SeriesScrapeCandidate(
                source: 'bangumi',
                subjectId: id,
                title: title,
                subtitle: [
                  if (name.isNotEmpty && name != title) name,
                  if (eps != null && eps.toInt() > 0) '共 ${eps.toInt()} 集',
                  'Bangumi',
                ].join(' · '),
                year: year,
                isTv: true,
                isMotionComic: isMc,
                mediaBadge: badge,
                posterUrl: _upgradeCoverUrl(cover),
                synopsis: summary,
                rating: (score != null && score >= 2.0 && score <= 10.0)
                    ? score
                    : null,
                episodeCount: eps?.toInt(),
              ),
            );
          }
        } catch (_) {}
      }(),

      // 3. Bilibili PGC (`media_bangumi` + `media_ft`)
      () async {
        for (final stype in const ['media_bangumi', 'media_ft']) {
          final body = await _getText(
            Uri.parse(
              'https://api.bilibili.com/x/web-interface/search/type?search_type=$stype&keyword=${Uri.encodeQueryComponent(q)}',
            ),
            headers: {
              'User-Agent': _desktopUa,
              'Referer': 'https://search.bilibili.com/',
              'Cookie': _biliCookie,
              'Accept': 'application/json',
            },
          );
          if (body == null) continue;
          try {
            final decoded = jsonDecode(body);
            final list = decoded is Map && decoded['data'] is Map
                ? decoded['data']['result']
                : null;
            if (list is! List) continue;
            for (final item in list.whereType<Map>().take(6)) {
              final sid =
                  (item['season_id'] ?? item['media_id'] ?? '').toString().trim();
              final title = (item['title'] ?? '')
                  .toString()
                  .replaceAll(RegExp(r'<[^>]+>'), '')
                  .trim();
              if (sid.isEmpty || title.isEmpty) continue;
              final desc = (item['desc'] ?? '').toString().trim();
              final styles = (item['styles'] ?? '').toString().trim();
              final isMc = isMotionComicText(title, extraContext: '$styles $desc');
              String year = '';
              if (item['pubtime'] is num && (item['pubtime'] as num).toInt() > 0) {
                year = DateTime.fromMillisecondsSinceEpoch(
                  (item['pubtime'] as num).toInt() * 1000,
                ).year.toString();
              }
              final cover = _upgradeCoverUrl((item['cover'] ?? '').toString());
              final backdrop = _upgradeCoverUrl(
                (item['horizontal_cover_16_9'] ??
                        item['horizontal_cover_16_10'] ??
                        '')
                    .toString(),
              );
              final eps = item['eps'];
              biliList.add(
                SeriesScrapeCandidate(
                  source: 'bilibili',
                  subjectId: sid,
                  title: title,
                  subtitle: [
                    if (styles.isNotEmpty) styles,
                    'B站官方',
                  ].join(' · '),
                  year: year,
                  isTv: stype == 'media_bangumi' ||
                      (eps is List && eps.length > 1),
                  isMotionComic: isMc,
                  mediaBadge: isMc
                      ? '动态漫画'
                      : (stype == 'media_bangumi' ? '动漫' : '影视'),
                  posterUrl: cover,
                  backdropUrl: backdrop,
                  synopsis: desc,
                  episodeCount: eps is List ? eps.length : null,
                ),
              );
            }
          } catch (_) {}
        }
      }(),
    ]);

    final combined = <SeriesScrapeCandidate>[
      ...doubanList,
      ...biliList,
      ...bangumiList,
    ];

    return combined.where((c) {
      return switch (filter) {
        'motion_comic' => c.isMotionComic,
        'standard' => !c.isMotionComic,
        'movie' => !c.isTv && !c.isMotionComic,
        _ => true,
      };
    }).toList(growable: false);
  }

  /// Enriches a user-selected [SeriesScrapeCandidate] with official high-res
  /// landscape backdrop, synopsis, and rating (e.g. from Douban Rexxar detail &
  /// `photos?type=S`) before persisting it as a [SeriesScrapeOverride].
  static Future<SeriesScrapeCandidate> hydrateCandidate(
    SeriesScrapeCandidate candidate,
  ) async {
    if (Platform.environment.containsKey('FLUTTER_TEST') ||
        candidate.source != 'douban' ||
        candidate.subjectId.isEmpty) {
      return candidate;
    }
    final bidCookie = 'bid=${_randomBid()}';
    final kind = candidate.isTv ? 'tv' : 'movie';
    var enriched = candidate;

    await Future.wait([
      // Official detail (intro, rating, high-res cover)
      () async {
        final body = await _getText(
          Uri.parse(
            'https://m.douban.com/rexxar/api/v2/$kind/${candidate.subjectId}',
          ),
          headers: {
            'User-Agent': _mobileUa,
            'Referer': 'https://m.douban.com/movie/subject/${candidate.subjectId}/',
            'Cookie': bidCookie,
            'Accept': 'application/json',
          },
        );
        if (body == null) return;
        try {
          final decoded = jsonDecode(body);
          if (decoded is! Map) return;
          final intro = (decoded['intro'] ?? '').toString().trim();
          final pic = decoded['pic'];
          final rawCover = (pic is Map
                  ? (pic['large'] ?? pic['normal'] ?? '')
                  : (decoded['cover_url'] ?? ''))
              .toString()
              .trim();
          final ratingMap = decoded['rating'];
          final rawVal = ratingMap is Map ? ratingMap['value'] : null;
          final score = rawVal is num
              ? rawVal.toDouble()
              : double.tryParse('$rawVal');
          final epCount = (decoded['episodes_count'] as num?)?.toInt();
          enriched = enriched.copyWith(
            synopsis: intro.isNotEmpty ? intro : enriched.synopsis,
            posterUrl: rawCover.isNotEmpty
                ? _upgradeCoverUrl(rawCover)
                : enriched.posterUrl,
            rating: (score != null && score >= 2.0 && score <= 10.0)
                ? score
                : enriched.rating,
            episodeCount: epCount ?? enriched.episodeCount,
          );
        } catch (_) {}
      }(),

      // Official wide landscape still (`photos?type=S`)
      () async {
        final body = await _getText(
          Uri.parse(
            'https://m.douban.com/rexxar/api/v2/$kind/${candidate.subjectId}/photos?type=S&start=0&count=8',
          ),
          headers: {
            'User-Agent': _mobileUa,
            'Referer': 'https://m.douban.com/movie/subject/${candidate.subjectId}/',
            'Cookie': bidCookie,
            'Accept': 'application/json',
          },
        );
        if (body == null) return;
        try {
          final decoded = jsonDecode(body);
          final photos = decoded is Map ? decoded['photos'] : null;
          if (photos is! List) return;
          String bestUrl = '';
          int bestArea = 0;
          for (final p in photos.whereType<Map>()) {
            final img = p['image'];
            if (img is! Map) continue;
            final large = img['large'] ?? img['normal'];
            if (large is! Map) continue;
            final w = (large['width'] as num?)?.toInt() ?? 0;
            final h = (large['height'] as num?)?.toInt() ?? 0;
            final u = _upgradeCoverUrl((large['url'] ?? '').toString());
            if (u.isEmpty) continue;
            if (w > h && w >= 640 && (w / math.max(1, h)) <= 2.65) {
              final area = w * h;
              if (area > bestArea) {
                bestArea = area;
                bestUrl = u;
              }
            }
          }
          if (bestUrl.isNotEmpty) {
            enriched = enriched.copyWith(backdropUrl: bestUrl);
          }
        } catch (_) {}
      }(),
    ]);

    return enriched;
  }
}
