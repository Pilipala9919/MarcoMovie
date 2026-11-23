import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'series_scraper.dart';

/// A single cast or crew member displayed in the avatar carousel on the Detail
/// and Portrait Player screens.
class CastMember {
  final String name;
  final String role;
  final String avatarUrl;

  const CastMember({
    required this.name,
    this.role = '',
    this.avatarUrl = '',
  });

  CastMember copyWith({String? name, String? role, String? avatarUrl}) {
    return CastMember(
      name: name ?? this.name,
      role: role ?? this.role,
      avatarUrl: avatarUrl ?? this.avatarUrl,
    );
  }
}

/// Resolves real actor/director portraits using public domestic metadata
/// endpoints (Douban Rexxar search + credits + Baidu Baike OpenAPI — all within
/// the repository's allowed metadata hosts) and loads portrait bytes directly
/// without movie-poster aspect/personage rejections.
class CastAvatarService {
  CastAvatarService._();

  static const String _mobileUa =
      'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1';
  static const String _desktopUa =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';
  static const int _maxCache = 220;
  static const int _maxActorPhotoCache = 600;
  static const int _maxAvatarBytesCache = 240;

  static final LinkedHashMap<String, List<CastMember>> _cache =
      LinkedHashMap<String, List<CastMember>>();
  static final LinkedHashMap<String, String> _actorPhotoCache =
      LinkedHashMap<String, String>();
  static final LinkedHashMap<String, Uint8List> _avatarBytesCache =
      LinkedHashMap<String, Uint8List>();
  static final Map<String, Future<List<CastMember>>> _inflight = {};
  static final Map<String, Future<Uint8List?>> _inflightBytes = {};
  static final math.Random _rng = math.Random();
  static final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 5)
    ..idleTimeout = const Duration(seconds: 20)
    ..maxConnectionsPerHost = 12
    ..autoUncompress = true;

  static String _randomBid() {
    const chars =
        'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    final sb = StringBuffer();
    for (int i = 0; i < 11; i++) {
      sb.write(chars[_rng.nextInt(chars.length)]);
    }
    return sb.toString();
  }

  /// Parses raw CMS `vod_actor` strings (`"张三, 李四 / 王五"`) into immediate
  /// placeholder [CastMember] items so the UI renders without layout jump
  /// before remote avatars arrive.
  static List<CastMember> parseRawActors(String actorRaw) {
    final cleaned = actorRaw.trim();
    if (cleaned.isEmpty) return const [];
    final tokens = cleaned
        .split(RegExp(r'[,，/、;；|]+'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty && s != '未知' && s != '内详' && s.length <= 28)
        .toList();
    final seen = <String>{};
    final out = <CastMember>[];
    for (final t in tokens) {
      if (seen.add(t)) {
        final cachedPhoto = _actorPhotoCache[t] ?? '';
        out.add(CastMember(name: t, role: '主演', avatarUrl: cachedPhoto));
      }
      if (out.length >= 16) break;
    }
    return out;
  }

  /// Synchronously returns cached cast members for [title] if already loaded.
  static List<CastMember>? peekCached(String title) {
    final key = _normalizeTitle(title);
    return _cache[key];
  }

  /// Seeds the cast cache synchronously for deterministic widget tests.
  @visibleForTesting
  static void debugSeedCache(String title, List<CastMember> members) {
    final key = _normalizeTitle(title);
    if (key.isEmpty) return;
    _putCache(key, List<CastMember>.unmodifiable(members));
  }

  /// Clears in-memory cast & portrait caches between tests.
  @visibleForTesting
  static void debugClearCache() {
    _cache.clear();
    _actorPhotoCache.clear();
    _avatarBytesCache.clear();
  }

  /// Synchronously peeks cached portrait bytes for [url].
  static Uint8List? peekAvatarBytes(String url) {
    final clean = _normalizePortraitUrl(url);
    if (clean.isEmpty) return null;
    final hit = _avatarBytesCache.remove(clean);
    if (hit != null) {
      _avatarBytesCache[clean] = hit;
    }
    return hit;
  }

  /// Resolves cast members with real portrait avatar URLs for [title].
  static Future<List<CastMember>> resolveCast({
    required String title,
    String actorRaw = '',
    String year = '',
    String doubanId = '',
    bool? wantMotionComic,
    void Function(List<CastMember> members)? onProgress,
  }) async {
    final fallback = parseRawActors(actorRaw);
    final key = _normalizeTitle(title);
    if (key.isEmpty && fallback.isEmpty && doubanId.trim().isEmpty) {
      return const [];
    }
    final wantMc = wantMotionComic ?? SeriesScraper.isMotionComicText(title);
    final cleanDouban = doubanId.trim();
    final cacheKey = cleanDouban.isNotEmpty
        ? 'douban:$cleanDouban|${fallback.map((e) => e.name).take(4).join(",")}'
        : (key.isNotEmpty
            ? '$key|${year.trim()}|${wantMc ? "mc" : "std"}|${fallback.map((e) => e.name).take(4).join(",")}'
            : fallback.map((e) => e.name).join(','));

    final cached = _cache[cacheKey] ??
        (cleanDouban.isEmpty && key.isNotEmpty && !wantMc ? _cache[key] : null);
    if (cached != null &&
        cached.isNotEmpty &&
        (cached.any((m) => m.avatarUrl.isNotEmpty) ||
            Platform.environment.containsKey('FLUTTER_TEST'))) {
      return cached;
    }

    final existing = _inflight[cacheKey];
    if (existing != null) return existing;

    final future = _fetchCastForTitle(
      cleanTitle: key,
      year: year.trim(),
      doubanId: cleanDouban,
      wantMotionComic: wantMc,
      fallback: fallback,
    );
    _inflight[cacheKey] = future;
    try {
      final result = await future;
      if (result.isNotEmpty) {
        _putCache(cacheKey, result);
        if (cleanDouban.isEmpty && key.isNotEmpty && !wantMc) {
          _putCache(key, result);
        }
        onProgress?.call(result);
      }
      return result.isNotEmpty ? result : fallback;
    } finally {
      _inflight.remove(cacheKey);
    }
  }

  /// Downloads and caches portrait bytes with proper Referer & UA headers for
  /// Douban (`img*.doubanio.com`) and Baidu Baike (`bkimg.cdn.bcebos.com`).
  static Future<Uint8List?> loadAvatarBytes(String rawUrl) async {
    final url = _normalizePortraitUrl(rawUrl);
    if (url.isEmpty) return null;
    final cached = peekAvatarBytes(url);
    if (cached != null) return cached;
    if (Platform.environment.containsKey('FLUTTER_TEST')) return null;

    final pending = _inflightBytes[url];
    if (pending != null) return pending;

    final future = _downloadAvatarBytes(url);
    _inflightBytes[url] = future;
    try {
      final bytes = await future;
      if (bytes != null && bytes.length >= 256) {
        _avatarBytesCache.remove(url);
        while (_avatarBytesCache.length >= _maxAvatarBytesCache) {
          _avatarBytesCache.remove(_avatarBytesCache.keys.first);
        }
        _avatarBytesCache[url] = bytes;
        return bytes;
      }
      return null;
    } finally {
      _inflightBytes.remove(url);
    }
  }

  static Future<Uint8List?> _downloadAvatarBytes(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      return null;
    }
    final host = uri.host.toLowerCase();
    final attempts = <({Uri uri, Map<String, String> headers})>[];
    if (host.endsWith('doubanio.com')) {
      final fixed = uri.host == 'img9.doubanio.com'
          ? uri.replace(host: 'img3.doubanio.com', scheme: 'https')
          : uri.replace(scheme: 'https');
      attempts.add((
        uri: fixed,
        headers: {
          HttpHeaders.userAgentHeader: _desktopUa,
          HttpHeaders.refererHeader: 'https://movie.douban.com/',
          HttpHeaders.cookieHeader: 'bid=${_randomBid()}',
          HttpHeaders.acceptHeader: 'image/webp,image/apng,image/*,*/*;q=0.8',
        },
      ));
      attempts.add((
        uri: fixed.replace(host: 'img1.doubanio.com'),
        headers: {
          HttpHeaders.userAgentHeader: _mobileUa,
          HttpHeaders.refererHeader: 'https://m.douban.com/',
          HttpHeaders.acceptHeader: 'image/*,*/*;q=0.8',
        },
      ));
    } else if (host.endsWith('bcebos.com')) {
      final httpsUri = uri.replace(scheme: 'https');
      attempts.add((
        uri: httpsUri,
        headers: {
          HttpHeaders.userAgentHeader: _mobileUa,
          HttpHeaders.refererHeader: 'https://baike.baidu.com/',
          HttpHeaders.acceptHeader: 'image/webp,image/jpeg,image/png,image/*,*/*;q=0.8',
        },
      ));
      if (httpsUri.hasQuery) {
        attempts.add((
          uri: httpsUri.replace(query: ''),
          headers: {
            HttpHeaders.userAgentHeader: _mobileUa,
            HttpHeaders.refererHeader: 'https://baike.baidu.com/',
            HttpHeaders.acceptHeader: 'image/jpeg,image/png,image/*,*/*;q=0.8',
          },
        ));
      }
    } else {
      attempts.add((
        uri: uri,
        headers: {
          HttpHeaders.userAgentHeader: _mobileUa,
          HttpHeaders.acceptHeader: 'image/*,*/*;q=0.8',
        },
      ));
    }

    for (final attempt in attempts) {
      HttpClientRequest? req;
      try {
        req = await _client
            .getUrl(attempt.uri)
            .timeout(const Duration(seconds: 4));
        attempt.headers.forEach(req.headers.set);
        final resp = await req.close().timeout(const Duration(seconds: 5));
        if (resp.statusCode >= 200 && resp.statusCode < 300) {
          final builder = BytesBuilder(copy: false);
          await for (final chunk in resp) {
            builder.add(chunk);
            if (builder.length > 4 * 1024 * 1024) break;
          }
          final bytes = builder.takeBytes();
          if (_looksLikeImage(bytes)) {
            return bytes;
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
    return null;
  }

  static bool _looksLikeImage(Uint8List b) {
    if (b.length < 16) return false;
    // JPEG
    if (b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) return true;
    // PNG
    if (b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) {
      return true;
    }
    // WebP ("RIFF....WEBP")
    if (b[0] == 0x52 &&
        b[1] == 0x49 &&
        b[2] == 0x46 &&
        b[3] == 0x46 &&
        b[8] == 0x57 &&
        b[9] == 0x45 &&
        b[10] == 0x42 &&
        b[11] == 0x50) {
      return true;
    }
    // GIF
    if (b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46) return true;
    return false;
  }

  static void _putCache(String key, List<CastMember> list) {
    _cache.remove(key);
    while (_cache.length >= _maxCache) {
      _cache.remove(_cache.keys.first);
    }
    _cache[key] = list;
  }

  static void _putActorPhoto(String name, String url) {
    final trimmed = name.trim();
    if (trimmed.isEmpty || url.isEmpty) return;
    _actorPhotoCache.remove(trimmed);
    while (_actorPhotoCache.length >= _maxActorPhotoCache) {
      _actorPhotoCache.remove(_actorPhotoCache.keys.first);
    }
    _actorPhotoCache[trimmed] = url;
  }

  static String _normalizeTitle(String raw) {
    final cleaned = SeriesScraper.cleanSearchTitle(raw);
    if (cleaned.isNotEmpty) return cleaned;
    return raw.trim().replaceAll(RegExp(r'\s+'), ' ');
  }

  static String _normalizePortraitUrl(String raw) {
    var u = raw.trim();
    if (u.isEmpty) return '';
    if (u.startsWith('//')) u = 'https:$u';
    final lower = u.toLowerCase();
    // Reject known generic Douban silhouette placeholder avatars.
    if (lower.contains('celebrity-default') ||
        lower.contains('personage-default') ||
        lower.contains('user_normal.jpg') ||
        lower.contains('default_avatar')) {
      return '';
    }
    if (lower.contains('doubanio.com')) {
      u = u.replaceFirst('img9.doubanio.com', 'img3.doubanio.com');
      if (u.startsWith('http://')) {
        u = u.replaceFirst('http://', 'https://');
      }
      if (u.endsWith('.webp')) {
        u = '${u.substring(0, u.length - 5)}.jpg';
      }
    } else if (lower.contains('bcebos.com')) {
      if (u.startsWith('http://')) {
        u = u.replaceFirst('http://', 'https://');
      }
    }
    return u;
  }

  static Future<List<CastMember>> _fetchCastForTitle({
    required String cleanTitle,
    required String year,
    required String doubanId,
    required bool wantMotionComic,
    required List<CastMember> fallback,
  }) async {
    if (Platform.environment.containsKey('FLUTTER_TEST')) {
      return fallback;
    }
    List<CastMember> doubanMembers = const [];
    try {
      String id = doubanId;
      String kind = 'tv';
      if (id.isEmpty && cleanTitle.isNotEmpty) {
        final match = await _lookupDoubanSubject(
          cleanTitle,
          year,
          wantMotionComic: wantMotionComic,
        );
        if (match != null) {
          id = match.id;
          kind = match.kind;
        }
      }
      if (id.isNotEmpty) {
        final primary = await _fetchDoubanCredits(id, kind);
        if (primary.isNotEmpty) {
          doubanMembers = primary;
        } else {
          final altKind = kind == 'tv' ? 'movie' : 'tv';
          doubanMembers = await _fetchDoubanCredits(id, altKind);
        }
      }
    } catch (e) {
      debugPrint('CastAvatarService Douban lookup warning: $e');
    }

    // Merge Douban credits & CMS actorRaw preserving rich photo URLs.
    final merged = <CastMember>[];
    final byName = <String, int>{};

    void upsert(CastMember member) {
      final n = member.name.trim();
      if (n.isEmpty) return;
      final existingIdx = byName[n];
      final cleanUrl = _normalizePortraitUrl(member.avatarUrl);
      if (cleanUrl.isNotEmpty) {
        _putActorPhoto(n, cleanUrl);
      }
      if (existingIdx != null) {
        final prev = merged[existingIdx];
        if (prev.avatarUrl.isEmpty && cleanUrl.isNotEmpty) {
          merged[existingIdx] = prev.copyWith(
            avatarUrl: cleanUrl,
            role: prev.role == '主演' && member.role.isNotEmpty
                ? member.role
                : prev.role,
          );
        }
        return;
      }
      if (merged.length >= 16) return;
      byName[n] = merged.length;
      merged.add(
        member.copyWith(
          avatarUrl: cleanUrl.isNotEmpty ? cleanUrl : (_actorPhotoCache[n] ?? ''),
        ),
      );
    }

    // When CMS provides the main leads list, lead with those names if Douban
    // returned directors/crew first; enrich every matching actor from Douban.
    final doubanPhotoByName = <String, CastMember>{
      for (final m in doubanMembers) m.name.trim(): m,
    };
    for (final raw in fallback) {
      final enriched = doubanPhotoByName[raw.name.trim()];
      if (enriched != null) {
        upsert(enriched);
      } else {
        upsert(raw);
      }
    }
    for (final m in doubanMembers) {
      upsert(m);
    }

    // Backfill missing actor portraits via Baidu Baike OpenAPI (fast, reliable
    // in Mainland China & globally, zero API key required).
    final missingIndices = <int>[];
    for (int i = 0; i < merged.length; i++) {
      if (merged[i].avatarUrl.isEmpty) {
        missingIndices.add(i);
      }
      if (missingIndices.length >= 10) break;
    }
    if (missingIndices.isNotEmpty) {
      await Future.wait(
        missingIndices.map((idx) async {
          final actorName = merged[idx].name;
          final baikePhoto = await _lookupBaiduBaikePortrait(actorName);
          if (baikePhoto != null && baikePhoto.isNotEmpty) {
            _putActorPhoto(actorName, baikePhoto);
            merged[idx] = merged[idx].copyWith(avatarUrl: baikePhoto);
          }
        }),
      );
    }

    return merged;
  }

  /// Resolves Douban subject ID using `m.douban.com/rexxar/api/v2/search/weixin`
  /// first (reliable 200 OK even when `search/subjects` rate-limits with 403),
  /// then `search/subjects`, then `movie.douban.com/j/subject_suggest`.
  static Future<({String id, String kind})?> _lookupDoubanSubject(
    String title,
    String year, {
    bool wantMotionComic = false,
  }) async {
    final searchQ = wantMotionComic ? '$title 动态漫画' : title;
    // 1. Mobile Rexxar weixin subject search (high hit rate & low rate-limit)
    final weixinUri = Uri.https(
      'm.douban.com',
      '/rexxar/api/v2/search/weixin',
      {'q': searchQ, 'count': '6'},
    );
    final weixinText = await _getJsonText(
      weixinUri,
      referer: 'https://m.douban.com/',
    );
    if (weixinText != null && weixinText.isNotEmpty) {
      try {
        final decoded = jsonDecode(weixinText);
        final items = _extractRexxarSearchItems(decoded);
        final match = _pickBestRexxarSubject(
          items,
          title,
          year,
          wantMotionComic: wantMotionComic,
        );
        if (match != null) return match;
      } catch (_) {}
    }

    // 2. Fallback: Mobile Rexxar subjects search
    final rexxarUri = Uri.https(
      'm.douban.com',
      '/rexxar/api/v2/search/subjects',
      {'type': 'movie', 'q': searchQ},
    );
    final rexxarText = await _getJsonText(
      rexxarUri,
      referer: 'https://m.douban.com/',
    );
    if (rexxarText != null && rexxarText.isNotEmpty) {
      try {
        final decoded = jsonDecode(rexxarText);
        final items = _extractRexxarSearchItems(decoded);
        final match = _pickBestRexxarSubject(
          items,
          title,
          year,
          wantMotionComic: wantMotionComic,
        );
        if (match != null) return match;
      } catch (_) {}
    }

    // 3. Fallback: classic movie.douban.com/j/subject_suggest
    final suggestUri = Uri.https('movie.douban.com', '/j/subject_suggest', {
      'q': searchQ,
    });
    final jsonText = await _getJsonText(
      suggestUri,
      referer: 'https://movie.douban.com/',
    );
    if (jsonText == null || jsonText.isEmpty) return null;
    try {
      final decoded = jsonDecode(jsonText);
      if (decoded is! List || decoded.isEmpty) return null;
      Map<String, dynamic>? best;
      int bestScore = -1;
      final normTarget = SeriesScraper.normalizeWorkCoreTitle(title);
      for (final item in decoded.whereType<Map>()) {
        final map = Map<String, dynamic>.from(item);
        final type = (map['type'] ?? '').toString().toLowerCase();
        if (type != 'movie' && type != 'tv') continue;
        final itemTitle = (map['title'] ?? '').toString().trim();
        final subTitle = (map['sub_title'] ?? '').toString().trim();
        final itemYear = (map['year'] ?? '').toString().trim();
        if (!SeriesScraper.isCompatibleWorkForm(
          targetIsMotionComic: wantMotionComic,
          candidateTitle: itemTitle,
          candidateContext: subTitle,
        )) {
          continue;
        }
        final normItem = SeriesScraper.normalizeWorkCoreTitle(itemTitle);
        int score = 0;
        if (normItem == normTarget) {
          score = 100;
        } else if (normItem.contains(normTarget) ||
            normTarget.contains(normItem)) {
          score = 70;
        } else {
          continue;
        }
        if (year.isNotEmpty && itemYear.isNotEmpty) {
          if (itemYear == year) {
            score += 40;
          } else {
            final yA = int.tryParse(year);
            final yB = int.tryParse(itemYear);
            if (yA != null && yB != null && (yA - yB).abs() >= 2) {
              score -= 35;
            }
          }
        }
        if (score > bestScore) {
          bestScore = score;
          best = map;
        }
      }
      if (best == null) return null;
      final id = (best['id'] ?? '').toString().trim();
      if (id.isEmpty) return null;
      final type = (best['type'] ?? '').toString().toLowerCase();
      final episode = (best['episode'] ?? '').toString().trim();
      final kind = (type == 'tv' || episode.isNotEmpty) ? 'tv' : 'movie';
      return (id: id, kind: kind);
    } catch (_) {
      return null;
    }
  }

  static List<Map<String, dynamic>> _extractRexxarSearchItems(Object? decoded) {
    if (decoded is! Map) return const [];
    final subjects = decoded['subjects'];
    final rawList = (subjects is Map ? subjects['items'] : null) ??
        decoded['items'];
    if (rawList is! List) return const [];
    return rawList
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  static ({String id, String kind})? _pickBestRexxarSubject(
    List<Map<String, dynamic>> items,
    String title,
    String year, {
    bool wantMotionComic = false,
  }) {
    ({String id, String kind})? best;
    int bestScore = -1;
    final normTarget = SeriesScraper.normalizeWorkCoreTitle(title);
    if (normTarget.isEmpty) return null;
    final targetYearNum = int.tryParse(year);
    for (final entry in items) {
      final targetRaw = entry['target'];
      final target = targetRaw is Map
          ? Map<String, dynamic>.from(targetRaw)
          : entry;
      final type =
          (entry['target_type'] ?? target['type'] ?? '').toString().toLowerCase();
      if (type.isNotEmpty && type != 'movie' && type != 'tv') continue;
      final id = (target['id'] ?? '').toString().trim();
      final itemTitle = (target['title'] ?? '').toString().trim();
      final itemYear = (target['year'] ?? '').toString().trim();
      final cardSub = (target['card_subtitle'] ?? '').toString().trim();
      if (id.isEmpty || itemTitle.isEmpty) continue;
      if (!SeriesScraper.isCompatibleWorkForm(
        targetIsMotionComic: wantMotionComic,
        candidateTitle: itemTitle,
        candidateContext: cardSub,
      )) {
        continue;
      }
      final kind = type == 'tv' ? 'tv' : 'movie';
      final normItem = SeriesScraper.normalizeWorkCoreTitle(itemTitle);
      if (normItem.isEmpty) continue;
      int score = 0;
      if (normItem == normTarget) {
        score = 120;
      } else if (normItem.contains(normTarget) ||
          normTarget.contains(normItem)) {
        // Avoid bare root title (`斗罗大陆`) hijacking numbered sequel (`斗罗大陆2绝世唐门`)
        if (normTarget.length >= 6 &&
            normItem.length <= 4 &&
            RegExp(r'\d').hasMatch(normTarget) &&
            !RegExp(r'\d').hasMatch(normItem)) {
          continue;
        }
        score = 80;
      } else {
        continue;
      }
      if (targetYearNum != null && itemYear.isNotEmpty) {
        final iy = int.tryParse(itemYear);
        if (iy != null) {
          final diff = (iy - targetYearNum).abs();
          if (diff == 0) {
            score += 45;
          } else if (diff == 1) {
            score += 20;
          } else {
            score -= 40;
          }
        }
      }
      if (score > bestScore) {
        bestScore = score;
        best = (id: id, kind: kind);
      }
    }
    return best;
  }

  /// Parses BOTH current Douban Rexxar `items` format AND legacy `credits`
  /// grouped format.
  @visibleForTesting
  static List<CastMember> parseDoubanCreditsPayload(Object? decoded) {
    if (decoded is! Map) return const [];
    final members = <CastMember>[];
    final seen = <String>{};

    void addRawCeleb(Map raw, {String defaultRole = '主演'}) {
      final name = (raw['name'] ?? '').toString().trim();
      if (name.isEmpty || !seen.add(name)) return;
      final character = (raw['character'] ?? '').toString().trim();
      final roles = raw['roles'];
      String role = character;
      if (role.isEmpty && roles is List && roles.isNotEmpty) {
        role = roles.first.toString().trim();
      }
      if (role.isEmpty) role = defaultRole;
      // Clean trailing English duplicate labels like "导演 Director" -> "导演"
      role = role.replaceAll(RegExp(r'\s+[A-Za-z][A-Za-z\s/]+$'), '').trim();
      if (role.isEmpty) role = defaultRole;

      final avatarMap = raw['avatar'];
      String avatarUrl = '';
      if (avatarMap is Map) {
        avatarUrl = (avatarMap['large'] ??
                avatarMap['normal'] ??
                avatarMap['small'] ??
                '')
            .toString()
            .trim();
      } else if (raw['cover_url'] != null) {
        avatarUrl = raw['cover_url'].toString().trim();
      }
      avatarUrl = _normalizePortraitUrl(avatarUrl);
      members.add(CastMember(name: name, role: role, avatarUrl: avatarUrl));
    }

    // Current Douban Rexxar schema: { "items": [ { name, character, avatar: {large, normal} }, ... ] }
    final flatItems = decoded['items'];
    if (flatItems is List) {
      for (final raw in flatItems.whereType<Map>()) {
        addRawCeleb(raw);
        if (members.length >= 16) break;
      }
    }

    // Legacy grouped schema: { "credits": [ { title, celebrities: [...] }, ... ] }
    final grouped = decoded['credits'];
    if (grouped is List && members.length < 16) {
      for (final section in grouped.whereType<Map>()) {
        final sectionTitle = (section['title'] ?? '').toString().trim();
        final celebList = section['celebrities'];
        if (celebList is! List) continue;
        for (final raw in celebList.whereType<Map>()) {
          addRawCeleb(
            raw,
            defaultRole: sectionTitle.isNotEmpty ? sectionTitle : '主演',
          );
          if (members.length >= 16) break;
        }
        if (members.length >= 16) break;
      }
    }

    return members;
  }

  static Future<List<CastMember>> _fetchDoubanCredits(
    String subjectId,
    String kind,
  ) async {
    final uri = Uri.https(
      'm.douban.com',
      '/rexxar/api/v2/$kind/$subjectId/credits',
    );
    final jsonText = await _getJsonText(
      uri,
      referer: 'https://m.douban.com/movie/subject/$subjectId/',
    );
    if (jsonText == null || jsonText.isEmpty) return const [];
    try {
      final decoded = jsonDecode(jsonText);
      return parseDoubanCreditsPayload(decoded);
    } catch (_) {
      return const [];
    }
  }

  /// Queries Baidu Baike public OpenAPI for an actor's portrait photo URL.
  static Future<String?> _lookupBaiduBaikePortrait(String actorName) async {
    final clean = actorName.trim();
    if (clean.isEmpty) return null;
    final cached = _actorPhotoCache[clean];
    if (cached != null && cached.isNotEmpty) return cached;

    final uri = Uri.https(
      'baike.baidu.com',
      '/api/openapi/BaikeLemmaCardApi',
      {
        'scope': '103',
        'format': 'json',
        'appid': '379020',
        'bk_key': clean,
      },
    );
    final body = await _getJsonText(
      uri,
      referer: 'https://baike.baidu.com/',
    );
    if (body == null || body.isEmpty) return null;
    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map) return null;
      final image = (decoded['image'] ?? '').toString().trim();
      if (image.isEmpty) return null;
      // Ensure the returned lemma matches the actor name closely.
      final lemmaTitle = (decoded['title'] ?? '').toString().trim();
      if (lemmaTitle.isNotEmpty &&
          lemmaTitle != clean &&
          !lemmaTitle.contains(clean) &&
          !clean.contains(lemmaTitle)) {
        return null;
      }
      final normalized = _normalizePortraitUrl(image);
      return normalized.isNotEmpty ? normalized : null;
    } catch (_) {
      return null;
    }
  }

  static Future<String?> _getJsonText(
    Uri uri, {
    required String referer,
  }) async {
    HttpClientRequest? req;
    try {
      req = await _client.getUrl(uri).timeout(const Duration(seconds: 4));
      req.headers.set(HttpHeaders.userAgentHeader, _mobileUa);
      req.headers.set(HttpHeaders.refererHeader, referer);
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      if (uri.host.endsWith('douban.com')) {
        req.headers.set(HttpHeaders.cookieHeader, 'bid=${_randomBid()}');
      }
      final resp = await req.close().timeout(const Duration(seconds: 4));
      if (resp.statusCode != 200) {
        await resp.drain<void>();
        return null;
      }
      return await utf8.decoder
          .bind(resp)
          .join()
          .timeout(const Duration(seconds: 4));
    } catch (_) {
      try {
        req?.abort();
      } catch (_) {}
      return null;
    }
  }
}
