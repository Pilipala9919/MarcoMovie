import 'dart:async';
import 'dart:convert';

import 'package:html/dom.dart';
import 'package:html/parser.dart' as html;
import 'package:http/http.dart' show RequestAbortedException;

import 'cms_parser.dart';
import 'models.dart';
import 'resilient_http_client.dart';

typedef WoggTextFetcher = Future<String> Function(
  String url, {
  Map<String, String> headers,
  Duration? requestTimeout,
});
typedef WoggPostFetcher = Future<String> Function(
  String url,
  Map<String, dynamic> body, {
  Map<String, String> headers,
  Duration? requestTimeout,
});

class WoggSiteUnavailable implements Exception {
  final bool allowVodFallback;
  const WoggSiteUnavailable({required this.allowVodFallback});
  @override
  String toString() => '网盘站点暂不可用，请检查站点域名或稍后重试';
}

/// Native catalogue adapter for configured WoGG-family 4K netdisk spiders on
/// iOS/desktop. Emits `mmshare://` links expanded by `CmsClient.fetchDetail`.
class WoggNetdiskAdapter {
  final CmsSite site;
  final WoggTextFetcher fetchText;
  final WoggPostFetcher? postJson;
  Uri? _credentialOrigin;
  final _prefetched = <Uri, String>{};

  WoggNetdiskAdapter(this.site, this.fetchText, {this.postJson});

  static bool supports(CmsSite site) {
    if (site.type != 3 || site.ext.trim().isEmpty) return false;
    final api = site.api.trim();
    if (!RegExp(
      r'^csp_(?:wobg|zhizhen|mihdr|muou|shandian|xiaomi|erxiao|ouge|tudou|labi|duoduo|huban|huajuan|xiaopan|kuaiying|qingying|woniu|zhinan|yidong|qiwei|leijing|haimian|panta|yiso)(?:guard)?$',
      caseSensitive: false,
    ).hasMatch(api)) {
      return false;
    }
    return parseDomains(site.ext, siteKey: api).isNotEmpty ||
        parseDomains(site.ext, siteKey: site.sourceKey).isNotEmpty ||
        _addresses(site.ext, siteKey: api, configsOnly: true).isNotEmpty ||
        _addresses(site.ext, siteKey: site.sourceKey, configsOnly: true)
            .isNotEmpty;
  }

  static const _domainKeys = {
    'siteurl',
    'siteurls',
    'site',
    'url',
    'urls',
    'host',
    'hosts',
    'domain',
    'domains',
    'baseurl',
    'base_url',
    'home',
    'api',
    'server',
    'servers',
  };
  static const _configKeys = {
    'config',
    'configurl',
    'domainconfig',
    'domainurl',
  };

  static Object? _decode(Object? value) {
    if (value is! String) return value;
    final text = value.trim();
    if (text.startsWith('{') || text.startsWith('[') || text.startsWith('"')) {
      try {
        return jsonDecode(CmsParser.stripJsonComments(text));
      } on FormatException {
        return null;
      }
    }
    return text;
  }

  static Uri? _domain(String raw) {
    var value = raw.trim();
    if (value.startsWith('//')) value = 'https:$value';
    if (!value.contains('://') &&
        RegExp(r'^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}(?::\d+)?(?:/[^\s]*)?$')
            .hasMatch(value)) {
      value = 'https://$value';
    }
    final uri = Uri.tryParse(value);
    if (uri == null ||
        !['https', 'http'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        ResilientHttpClient.cloudProviderForShare(value) != null ||
        RegExp(r'\.(?:jar|js|mjs|py|zip|png|jpg)$', caseSensitive: false)
            .hasMatch(uri.path)) {
      return null;
    }
    return uri
        .removeFragment()
        .replace(path: uri.path.isEmpty ? '/' : uri.path);
  }

  static bool _configFile(Uri uri) =>
      RegExp(r'\.(?:json|txt|conf)$', caseSensitive: false).hasMatch(uri.path);

  static List<Uri> parseDomains(Object? extension, {String siteKey = ''}) =>
      _addresses(extension, siteKey: siteKey)
          .where((u) => !_configFile(u))
          .toList();

  static List<Uri> _addresses(
    Object? extension, {
    String siteKey = '',
    bool configsOnly = false,
  }) {
    final result = <Uri>[];
    final seen = <String>{};
    final key = siteKey
        .toLowerCase()
        .replaceFirst('csp_', '')
        .replaceFirst(RegExp(r'guard$'), '');
    void visit(Object? value, int depth, {bool config = false}) {
      if (depth > 6 || result.length >= 8) return;
      value = _decode(value);
      if (value is List) {
        for (final child in value) {
          visit(child, depth + 1, config: config);
        }
      } else if (value is Map) {
        for (final entry in value.entries) {
          final field = entry.key.toString().toLowerCase();
          if (_domainKeys.contains(field) ||
              _configKeys.contains(field) ||
              field == key ||
              field == siteKey.toLowerCase()) {
            visit(entry.value, depth + 1, config: _configKeys.contains(field));
          } else if (const {'data', 'sites', 'configurations'}
                  .contains(field) &&
              entry.value is Map) {
            visit(entry.value, depth + 1);
          }
        }
      } else if (value is String && value.length < 256 * 1024) {
        for (final token in value.split(RegExp(r'[\s,;|]+'))) {
          final uri = _domain(token);
          if (uri != null &&
              (configsOnly ? config || _configFile(uri) : !config) &&
              seen.add(uri.toString())) {
            result.add(uri);
          }
          if (result.length >= 8) break;
        }
      }
    }

    visit(extension, 0);
    return result;
  }

  Map get _options {
    final decoded = _decode(site.ext);
    return decoded is Map ? decoded : const {};
  }

  Map<String, String> _headers(Uri target, Uri? credentialOrigin) => {
        'User-Agent':
            'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Version/18.0 Safari/605.1.15',
        ...Map.fromEntries(site.headers.entries.where((entry) =>
            credentialOrigin != null &&
                target.origin == credentialOrigin.origin ||
            !const {
              'authorization',
              'cookie',
              'cookie2',
              'proxy-authorization',
              'host',
            }.contains(entry.key.toLowerCase()))),
      };

  Future<({List<Uri> domains, bool configured, Uri? credentials})>
      _configuration() async {
    final domains = [
      ...parseDomains(site.ext, siteKey: site.api),
      ...parseDomains(site.ext, siteKey: site.sourceKey),
    ];
    final ambiguous = domains
        .where((uri) =>
            uri.path != '/' &&
            !uri.path.endsWith('/') &&
            !RegExp(r'\.(?:html?|php)$|/api(?:/|$)', caseSensitive: false)
                .hasMatch(uri.path))
        .toSet();
    final refs = <Uri>{
      ..._addresses(site.ext, siteKey: site.api, configsOnly: true),
      ..._addresses(site.ext, siteKey: site.sourceKey, configsOnly: true),
      ...ambiguous,
    }.toList();
    final credentials = domains.isNotEmpty
        ? domains.first
        : (refs.isNotEmpty ? refs.first : null);
    final visited = <String>{};
    var reachedConfig = false;
    for (var index = 0; index < refs.length && index < 4; index++) {
      final ref = refs[index];
      if (!visited.add(ref.toString())) continue;
      try {
        final text = await fetchText(
          ref.toString(),
          headers: _headers(ref, credentials),
          requestTimeout: const Duration(seconds: 5),
        );
        if (ambiguous.contains(ref) && text.trimLeft().startsWith('<')) {
          _prefetched[ref] = text;
          continue;
        }
        reachedConfig = true;
        if (text.length > 256 * 1024) throw const FormatException('域名配置文件过大');
        final found = [
          ...parseDomains(text, siteKey: site.api),
          ...parseDomains(text, siteKey: site.sourceKey),
        ];
        final nested = _addresses(text, siteKey: site.api, configsOnly: true);
        if (ambiguous.contains(ref)) {
          if (found.isEmpty && nested.isEmpty) {
            _prefetched[ref] = text;
          } else {
            domains.removeWhere((uri) => uri == ref);
          }
        }
        domains.addAll(found);
        refs.addAll(nested.where((uri) => !refs.contains(uri)));
      } on RequestAbortedException {
        rethrow;
      } on Exception {
        // Try remaining explicit mirrors/config files.
      }
    }
    final configured = domains.isNotEmpty || reachedConfig;
    _credentialOrigin = credentials;
    final unique = {for (final uri in domains) uri.toString(): uri};
    return (
      domains: unique.values.take(8).toList(),
      configured: configured,
      credentials: credentials,
    );
  }

  bool get _postSearch =>
      '${_options['searchMethod'] ?? _options['method']}'.toUpperCase() ==
          'POST' ||
      _options['mode'] == 'pansou';

  bool _api(Uri base) =>
      _options['mode'] == 'api' ||
      _postSearch ||
      base.path.contains('/api') ||
      (base.path.endsWith('.php') && !base.path.endsWith('/index.php')) ||
      RegExp(r'panta|yiso', caseSensitive: false).hasMatch(site.api);

  Uri _query(Uri base, Map<String, String> params) =>
      base.replace(queryParameters: {...base.queryParameters, ...params});

  static String _normalizeMacCmsArea(String raw, {bool longForm = true}) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty || trimmed == '全部') return '';
    if (longForm) {
      return switch (trimmed) {
        '大陆' || '内地' => '中国大陆',
        '香港' => '中国香港',
        '台湾' => '中国台湾',
        _ => trimmed,
      };
    }
    return switch (trimmed) {
      '中国大陆' => '大陆',
      '中国香港' => '香港',
      '中国台湾' => '台湾',
      _ => trimmed,
    };
  }

  static String _extractNumericCategoryId(String rawId) {
    final trimmed = rawId.trim();
    if (trimmed.isEmpty) return '';
    if (RegExp(r'^\d+$').hasMatch(trimmed)) return trimmed;
    final match = RegExp(
      r'(?:/id/|/vodtype/|/vodshow/|/type/)(\d+)',
      caseSensitive: false,
    ).firstMatch(trimmed);
    return match?.group(1) ?? trimmed;
  }

  List<Uri> _routes(
    Uri base,
    String action, {
    String id = '',
    String keyword = '',
    int page = 1,
    CmsFilter? filter,
  }) {
    final hasSubFilter = filter != null && filter.hasSubFilter;
    final filterArea = hasSubFilter && filter.area.trim() != '全部'
        ? filter.area.trim()
        : '';
    final filterGenre = hasSubFilter && filter.genreLabel.trim() != '全部'
        ? filter.genreLabel.trim()
        : '';
    final filterYearRaw = hasSubFilter && filter.year.trim() != '全部'
        ? filter.year.trim()
        : '';
    final filterYear =
        RegExp(r'^(?:19|20)\d{2}$').hasMatch(filterYearRaw) ? filterYearRaw : '';
    final hasServerFilter =
        filterArea.isNotEmpty || filterGenre.isNotEmpty || filterYear.isNotEmpty;

    final configured = _options['${action}Path'];
    if (configured is String && configured.isNotEmpty && !hasServerFilter) {
      final path = configured
          .replaceAll('{id}', Uri.encodeComponent(id))
          .replaceAll('{wd}', Uri.encodeComponent(keyword))
          .replaceAll('{page}', '$page');
      final target = base.resolve(path);
      if (target.origin != base.origin) {
        throw const FormatException('站点路径不能指向其他域名');
      }
      return [target];
    }
    final api = _api(base);
    final cmsApi = base.path.contains('provide/vod');
    if (action == 'home') {
      return [
        base,
        if (api && !cmsApi) ...[
          base.resolve('/api/list?page=1'),
          base.resolve('/api/categories'),
        ],
      ];
    }
    if (action == 'detail') {
      final old = Uri.tryParse(id);
      if (old != null && (old.hasScheme || id.startsWith('/'))) {
        return [
          base.resolveUri(
            Uri(path: old.path, query: old.hasQuery ? old.query : null),
          ),
        ];
      }
      if (api) {
        return [
          cmsApi
              ? _query(base, {'ac': 'detail', 'ids': id})
              : _query(base.resolve('/api/detail'), {'id': id}),
        ];
      }
      return [
        base.resolve('/index.php/vod/detail/id/${Uri.encodeComponent(id)}.html'),
        base.resolve('/voddetail/${Uri.encodeComponent(id)}.html'),
      ];
    }
    if (action == 'search') {
      if (cmsApi) {
        return [
          _query(base, {'ac': 'detail', 'wd': keyword, 'pg': '$page'}),
        ];
      }
      return [
        if (api)
          _query(
            base.path.contains('/api') ? base : base.resolve('/api/search'),
            {'q': keyword, 'keyword': keyword, 'page': '$page'},
          ),
        _query(
          base.resolve('/index.php/vod/search.html'),
          {'wd': keyword, 'page': '$page'},
        ),
        base.resolve(
          '/vodsearch/${Uri.encodeComponent(keyword)}----------$page---.html',
        ),
      ];
    }
    if (cmsApi) {
      return [
        _query(base, {
          'ac': 'detail',
          if (id.isNotEmpty) 't': id,
          'pg': '$page',
          if (filterArea.isNotEmpty) 'area': filterArea,
          if (filterGenre.isNotEmpty) 'class': filterGenre,
          if (filterYear.isNotEmpty) 'year': filterYear,
        }),
      ];
    }
    if (api) {
      return [
        _query(
          base.path.contains('/api') ? base : base.resolve('/api/list'),
          {
            if (id.isNotEmpty) 'type': id,
            'page': '$page',
            if (filterArea.isNotEmpty) 'area': filterArea,
            if (filterGenre.isNotEmpty) 'class': filterGenre,
            if (filterYear.isNotEmpty) 'year': filterYear,
          },
        ),
      ];
    }
    if (hasServerFilter) {
      final catId = _extractNumericCategoryId(id);
      final effectiveCat = catId.isNotEmpty ? catId : '1';
      final longArea = _normalizeMacCmsArea(filterArea, longForm: true);
      final shortArea = _normalizeMacCmsArea(filterArea, longForm: false);

      Uri buildVodShow(String areaToken) {
        final slots = List<String>.filled(12, '');
        slots[0] = Uri.encodeComponent(effectiveCat);
        if (areaToken.isNotEmpty) slots[1] = Uri.encodeComponent(areaToken);
        if (filterGenre.isNotEmpty) slots[3] = Uri.encodeComponent(filterGenre);
        slots[8] = '$page';
        if (filterYear.isNotEmpty) slots[11] = Uri.encodeComponent(filterYear);
        return base.resolve('/vodshow/${slots.join('-')}.html');
      }

      Uri buildIndexShow(String areaToken) {
        final segs = <String>[
          if (areaToken.isNotEmpty) ...['area', Uri.encodeComponent(areaToken)],
          if (filterGenre.isNotEmpty) ...[
            'class',
            Uri.encodeComponent(filterGenre),
          ],
          'id',
          Uri.encodeComponent(effectiveCat),
          'page',
          '$page',
          if (filterYear.isNotEmpty) ...[
            'year',
            Uri.encodeComponent(filterYear),
          ],
        ];
        return base.resolve('/index.php/vod/show/${segs.join('/')}.html');
      }

      return [
        buildVodShow(longArea),
        if (shortArea != longArea) buildVodShow(shortArea),
        buildIndexShow(longArea),
        if (shortArea != longArea) buildIndexShow(shortArea),
      ];
    }
    if (id.contains('/')) {
      final old = Uri.parse(id);
      var path = old.path;
      if (page > 1 && RegExp(r'/vod/type/id/\d+\.html$').hasMatch(path)) {
        path = path.replaceFirst('.html', '/page/$page.html');
      }
      final target = base.resolve(path).replace(queryParameters: {
        ...old.queryParameters,
        if (page > 1 && !path.contains('/page/')) 'page': '$page',
      });
      return [target];
    }
    return [
      base.resolve(
        '/index.php/vod/type/id/${Uri.encodeComponent(id)}/page/$page.html',
      ),
      base.resolve('/vodshow/${Uri.encodeComponent(id)}--------$page---.html'),
    ];
  }

  Future<T> _request<T>(
    String action,
    FutureOr<T> Function(String, Uri) parse, {
    String id = '',
    String keyword = '',
    int page = 1,
    CmsFilter? filter,
    bool Function(T)? acceptResult,
  }) async {
    final config = await _configuration();
    var reachedSite = false;
    T? fallbackEmpty;
    final clock = Stopwatch()..start();
    for (var route = 0; route < 4; route++) {
      for (var domainIndex = 0;
          domainIndex < config.domains.length && domainIndex < 8;
          domainIndex++) {
        final base = config.domains[domainIndex];
        final routes = _routes(
          base,
          action,
          id: id,
          keyword: keyword,
          page: page < 1 ? 1 : page,
          filter: filter,
        );
        if (route >= routes.length || clock.elapsedMilliseconds >= 18000) {
          continue;
        }
        final target = routes[route];
        try {
          final remaining = 18000 - clock.elapsedMilliseconds;
          final timeout = Duration(milliseconds: remaining.clamp(1, 7000));
          final headers = _headers(target, config.credentials);
          final String raw;
          if (action == 'search' && _postSearch) {
            if (postJson == null) {
              throw const FormatException('此盘搜 API 需要 POST 请求支持');
            }
            final endpointQuery = Map<String, String>.of(target.queryParameters)
              ..removeWhere(
                  (key, _) => const {'q', 'keyword', 'page'}.contains(key));
            raw = await postJson!(
              target
                  .replace(
                    query: endpointQuery.isEmpty
                        ? ''
                        : Uri(queryParameters: endpointQuery).query,
                  )
                  .toString(),
              {
                '${_options['keywordField'] ?? 'kw'}': keyword,
                'page': page,
                'res': 'merge',
              },
              headers: headers,
              requestTimeout: timeout,
            );
          } else {
            raw = _prefetched.remove(target) ??
                await fetchText(
                  target.toString(),
                  headers: headers,
                  requestTimeout: timeout,
                );
          }
          reachedSite = true;
          final decoded = _decode(raw);
          if (decoded is Map &&
              !decoded.keys.any((key) => const {
                    'list',
                    'results',
                    'items',
                    'vod_name',
                  }.contains(key))) {
            final discovered = parseDomains(decoded, siteKey: site.api);
            var added = false;
            for (final domain in discovered) {
              if (config.domains.length < 8 &&
                  !config.domains.contains(domain)) {
                config.domains.add(domain);
                added = true;
              }
            }
            if (added) continue;
          }
          final parsed = await parse(raw, target);
          if (acceptResult != null && !acceptResult(parsed)) {
            fallbackEmpty ??= parsed;
            continue;
          }
          return parsed;
        } on RequestAbortedException {
          rethrow;
        } on Exception {
          // Try remaining mirrors/routes.
        }
      }
    }
    if (fallbackEmpty != null) return fallbackEmpty;
    throw WoggSiteUnavailable(
      allowVodFallback: !config.configured && !reachedSite,
    );
  }

  Future<(List<CmsCategory>, CmsListing)> home() =>
      _request('home', (raw, uri) async {
        final categories = parseCategories(raw, uri);
        var listing = parseListing(raw, uri);
        if (listing.videos.isEmpty && categories.isNotEmpty) {
          try {
            listing = await category(categories.first.id, 1);
          } on RequestAbortedException {
            rethrow;
          } on WoggSiteUnavailable {
            // Keep reachable categories.
          }
        }
        return (categories, listing);
      });

  Future<CmsListing> category(
    String id,
    int page, {
    CmsFilter? filter,
  }) {
    final hasSubFilter = filter != null && filter.hasSubFilter;
    final hasNonNumericYear = hasSubFilter &&
        filter.year.trim().isNotEmpty &&
        filter.year.trim() != '全部' &&
        !RegExp(r'^(?:19|20)\d{2}$').hasMatch(filter.year.trim());
    final serverApplied = hasSubFilter && !hasNonNumericYear;
    return _request<CmsListing>(
      'category',
      (raw, uri) {
        final parsed = parseListing(raw, uri, page: page);
        if (!serverApplied) return parsed;
        return CmsListing(
          page: parsed.page,
          pageCount: parsed.pageCount,
          videos: parsed.videos,
          sourceFiltered: true,
        );
      },
      id: id,
      page: page,
      filter: filter,
      acceptResult: hasSubFilter ? (listing) => listing.videos.isNotEmpty : null,
    );
  }

  Future<CmsListing> search(String keyword, int page) async {
    if (keyword.trim().isEmpty) return const CmsListing();
    return _request('search', (raw, uri) => parseListing(raw, uri, page: page),
        keyword: keyword.trim(), page: page);
  }

  Future<CmsVideo> detail(CmsVideo fallback) async {
    final existingShares = fallback.lines
        .expand((line) => line.episodes)
        .where((ep) =>
            ep.url.startsWith('mmshare://') ||
            ResilientHttpClient.cloudProviderForShare(ep.url) != null)
        .toList();
    if (existingShares.isNotEmpty) {
      return _copy(fallback, lines: [
        ..._groupShares(existingShares),
        ...fallback.lines.where((line) => !line.episodes.any((ep) =>
            ep.url.startsWith('mmshare://') ||
            ResilientHttpClient.cloudProviderForShare(ep.url) != null)),
      ]);
    }
    if (ResilientHttpClient.cloudProviderForShare(fallback.id) != null) {
      return _copy(
        fallback,
        lines: _groupShares([CmsEpisode(name: fallback.title, url: fallback.id)]),
      );
    }
    return _request('detail', (raw, uri) async {
      final detail = parseDetail(raw, uri, fallback);
      if (detail.lines.isNotEmpty || !raw.trimLeft().startsWith('<')) {
        return detail;
      }
      final links = <String, String>{};
      for (final a in html.parse(raw).querySelectorAll('a[href]')) {
        final target = uri.resolve(a.attributes['href']!);
        if (target.origin == uri.origin &&
            RegExp(r'/(?:vodplay|vod/play|play)/').hasMatch(target.path)) {
          links.putIfAbsent(
            target.toString(),
            () => cleanEpisodeName(a.text, fallback: detail.title),
          );
        }
      }
      final shares = <CmsEpisode>[];
      for (final link in links.entries.take(8)) {
        try {
          final target = Uri.parse(link.key);
          final page = await fetchText(
            link.key,
            headers: _headers(target, _credentialOrigin),
            requestTimeout: const Duration(seconds: 5),
          );
          final parsed = parseDetail(
            page,
            target,
            CmsVideo(id: link.key, title: link.value),
          );
          shares.addAll(parsed.lines.expand((l) => l.episodes));
        } on RequestAbortedException {
          rethrow;
        } on Exception {
          // Keep other season/provider links.
        }
      }
      return _copy(detail, lines: _groupShares(shares));
    }, id: fallback.id);
  }

  static String cleanEpisodeName(String value, {String fallback = '网盘资源'}) {
    final text = html.parseFragment(value).text ?? '';
    final clean = text
        .replaceAll(RegExp(r'(?:提取码|访问码|密码)\s*[:：]?\s*[a-zA-Z0-9]+'), '')
        .replaceAll(
          RegExp(
            r'(?:夸克|UC|阿里云?|阿里|百度|迅雷)\s*网盘|复制链接|点击(?:下载|播放|查看|获取)|立即播放',
            caseSensitive: false,
          ),
          '',
        )
        .replaceAll(RegExp(r'[【\[（(]\s*[】\]）)]'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim()
        .replaceAll(RegExp(r'^[\s·|:：\-_]+|[\s·|:：\-_]+$'), '');
    return clean.isEmpty ? fallback : clean;
  }

  static List<CmsCategory> parseCategories(String raw, Uri base) {
    if (!raw.trimLeft().startsWith('<')) {
      final data = jsonDecode(raw);
      final list = data is Map
          ? data['class'] ??
              data['categories'] ??
              (data['data'] is Map ? data['data']['categories'] : null)
          : null;
      if (list is! List) return const [];
      return [
        for (final item in list.whereType<Map>())
          if ((item['type_id'] ?? item['id']) != null &&
              (item['type_name'] ?? item['name']) != null)
            CmsCategory(
              id: '${item['type_id'] ?? item['id']}',
              name: '${item['type_name'] ?? item['name']}',
            ),
      ];
    }
    final result = <String, CmsCategory>{};
    for (final a in html.parse(raw).querySelectorAll('a[href]')) {
      final target = base.resolve(a.attributes['href']!);
      if (target.origin == base.origin &&
          RegExp(r'/(?:vodtype|vodshow|vod/type|vod/show|type|category)[/\-]')
              .hasMatch(target.path)) {
        final name = a.text.trim();
        if (name.isNotEmpty) {
          result.putIfAbsent(
            target.toString(),
            () => CmsCategory(id: target.toString(), name: name),
          );
        }
      }
    }
    return result.values.toList();
  }

  static List<Map> _records(Object? data, [int depth = 0]) {
    if (depth > 6) return const [];
    if (data is List) {
      return data
          .whereType<Map>()
          .where((item) => item.keys.any((key) => const {
                'vod_name',
                'title',
                'name',
                'thread_title',
                'url',
                'links',
              }.contains(key)))
          .toList();
    }
    if (data is! Map) return const [];
    for (final key in const [
      'list',
      'results',
      'items',
      'rows',
      'resources',
      'data',
      'result',
    ]) {
      if (data[key] is List || data[key] is Map) {
        return _records(data[key], depth + 1);
      }
    }
    if (data['merged_by_type'] is Map) {
      return [
        for (final value in (data['merged_by_type'] as Map).values)
          ..._records(value, depth + 1),
      ];
    }
    if (data.keys.any(
        (k) => const {'vod_name', 'title', 'name', 'thread_title'}.contains(k))) {
      return [data];
    }
    return const [];
  }

  static Element? _closest(
    Element element,
    Set<String> classes, {
    bool listItem = false,
  }) {
    for (Element? node = element; node != null; node = node.parent) {
      if (node.classes.any(classes.contains) ||
          (listItem && node.localName == 'li')) {
        return node;
      }
    }
    return null;
  }

  static CmsListing parseListing(String raw, Uri base, {int page = 1}) {
    if (!raw.trimLeft().startsWith('<')) {
      final data = jsonDecode(raw);
      final envelope =
          data is Map && data['data'] is Map ? data['data'] as Map : data;
      int number(Object? value, int fallback) =>
          int.tryParse('$value') ?? fallback;
      return CmsListing(
        page: envelope is Map ? number(envelope['page'], page) : page,
        pageCount: envelope is Map
            ? number(
                envelope['pagecount'] ??
                    envelope['total_pages'] ??
                    envelope['last_page'],
                page,
              )
            : page,
        videos: [for (final item in _records(data)) _jsonVideo(item, base)],
      );
    }
    final doc = html.parse(raw);
    final videos = <String, CmsVideo>{};
    for (final a in doc.querySelectorAll('a[href]')) {
      final uri = base.resolve(a.attributes['href']!);
      if (uri.origin != base.origin ||
          !RegExp(r'/(?:voddetail|vod/detail|detail|movie|subject)[/\-]')
              .hasMatch(uri.path)) {
        continue;
      }
      final card = _closest(
            a,
            {
              'module-item',
              'module-search-item',
              'stui-vodlist__box',
              'myui-vodlist__box',
              'hl-list-item',
            },
            listItem: true,
          ) ??
          a;
      final img = card.querySelector('img');
      final title = cleanEpisodeName(
        a.attributes['title'] ??
            img?.attributes['alt'] ??
            card.querySelector('.module-item-title, .title, h3, h4')?.text ??
            a.text,
        fallback: '',
      );
      if (title.isEmpty || videos.containsKey(uri.toString())) continue;
      final poster = img?.attributes['data-original'] ??
          img?.attributes['data-src'] ??
          img?.attributes['src'] ??
          a.attributes['data-original'] ??
          '';
      videos[uri.toString()] = CmsVideo(
        id: uri.toString(),
        title: title,
        poster: poster.isEmpty ? '' : base.resolve(poster).toString(),
        remarks: card
                .querySelector(
                  '.module-item-note, .video-serial, .pic-text, .remarks, .hl-lc-1',
                )
                ?.text
                .trim() ??
            '',
      );
    }
    if (videos.isEmpty &&
        doc.querySelector('html') != null &&
        !RegExp(r'module-|stui-|myui-|hl-|vod|搜索|暂无|没有|未找到',
                caseSensitive: false)
            .hasMatch(raw)) {
      throw const FormatException('无法识别网盘站页面');
    }
    var pages = page;
    for (final a in doc.querySelectorAll(
        '.page a, .pagination a, .stui-page a, .hl-page a, a[rel="next"]')) {
      final n = int.tryParse(a.text.trim());
      if (n != null && n > pages) pages = n;
      if (a.attributes['rel'] == 'next' || a.text.contains('下一页')) {
        pages = pages > page ? pages : page + 1;
      }
    }
    return CmsListing(
      page: page,
      pageCount: pages,
      videos: videos.values.toList(),
    );
  }

  static CmsVideo _jsonVideo(Map item, Uri base) {
    final title = cleanEpisodeName(
      '${item['vod_name'] ?? item['title'] ?? item['name'] ?? item['thread_title'] ?? ''}',
      fallback: '网盘资源',
    );
    final shares = <CmsEpisode>[];
    void walk(Object? value, String label, [int depth = 0]) {
      if (depth > 8) return;
      if (value is Map) {
        var name =
            '${value['name'] ?? value['title'] ?? value['episode'] ?? label}';
        if (RegExp(
          r'^(?:quark|uc|baidu|ali(?:yun)?|夸克(?:网盘)?|UC网盘|百度(?:网盘)?|阿里(?:云盘|网盘)?)$',
          caseSensitive: false,
        ).hasMatch(name)) {
          name = label;
        }
        final season =
            RegExp(r'第[零一二三四五六七八九十百\d]+季|S\d{1,2}(?!\d)', caseSensitive: false)
                .firstMatch(label)
                ?.group(0);
        if (season != null &&
            !RegExp(r'第[零一二三四五六七八九十百\d]+季|S\d{1,2}', caseSensitive: false)
                .hasMatch(name)) {
          name = '$season $name';
        }
        final code =
            '${value['pwd'] ?? value['password'] ?? value['passcode'] ?? value['code'] ?? ''}';
        for (final entry in value.entries) {
          if (const {'cookie', 'token', 'headers', 'header'}
              .contains(entry.key)) {
            continue;
          }
          if (entry.value is String) {
            for (final url in _shareUrls(entry.value as String)) {
              shares.add(CmsEpisode(
                name: cleanEpisodeName(name, fallback: title),
                url: _withPassword(url, code),
              ));
            }
          } else {
            walk(entry.value, name, depth + 1);
          }
        }
      } else if (value is List) {
        for (final child in value) {
          walk(child, label, depth + 1);
        }
      } else if (value is String) {
        for (final url in _shareUrls(value)) {
          shares.add(CmsEpisode(name: label, url: url));
        }
      }
    }

    if (item['vod_play_url'] is String) {
      final parsed = CmsParser.parseListing(jsonEncode({
        'list': [item],
      }));
      for (final line in parsed.videos.expand((v) => v.lines)) {
        for (final ep in line.episodes) {
          final norm = ResilientHttpClient.normalizeCloudShareUrl(ep.url);
          if (norm != null) {
            shares.add(CmsEpisode(
              name: cleanEpisodeName(ep.name, fallback: title),
              url: norm,
            ));
          }
        }
      }
    }
    walk(item, title);
    final poster = '${item['vod_pic'] ?? item['pic'] ?? item['cover'] ?? ''}';
    return CmsVideo(
      id: '${item['vod_id'] ?? item['id'] ?? item['url'] ?? (shares.isNotEmpty ? shares.first.url : title)}',
      title: title,
      poster: poster.isEmpty ? '' : base.resolve(poster).toString(),
      remarks: '${item['vod_remarks'] ?? item['remarks'] ?? ''}',
      year: '${item['vod_year'] ?? item['year'] ?? ''}',
      area: '${item['vod_area'] ?? item['area'] ?? ''}',
      actor: '${item['vod_actor'] ?? item['actor'] ?? ''}',
      description:
          '${item['vod_content'] ?? item['description'] ?? item['content'] ?? ''}',
      lines: _groupShares(shares),
    );
  }

  static Iterable<String> _shareUrls(String raw) sync* {
    var text = raw
        .replaceAll(r'\/', '/')
        .replaceAll(r'\u002F', '/')
        .replaceAll(r'\u002f', '/')
        .replaceAll(r'\u003A', ':')
        .replaceAll(r'\u003a', ':')
        .replaceAll(r'\u0026', '&');
    text = html.parseFragment(text).text ?? text;
    for (var i = 0;
        i < 2 && RegExp(r'https?%3a', caseSensitive: false).hasMatch(text);
        i++) {
      try {
        text = Uri.decodeComponent(text);
      } on FormatException {
        break;
      }
    }
    final pattern = RegExp(
      r'(?:push://)?https?://(?:www\.)?(?:pan\.quark\.cn/(?:s/[A-Za-z0-9_-]+)|(?:drive|fast)\.uc\.cn/s/[A-Za-z0-9_-]+|(?:alipan|aliyundrive)\.com/s/[A-Za-z0-9_-]+(?:/folder/[A-Za-z0-9_-]+)?|pan\.baidu\.com/(?:s/[A-Za-z0-9_-]+|share/init\?[A-Za-z0-9%&=._~:+/?@-]+))(?:\?[A-Za-z0-9%&=._~:+/?@-]+)?(?:#[A-Za-z0-9%&=._~:+/?@-]+)?',
      caseSensitive: false,
    );
    for (final match in pattern.allMatches(text)) {
      var url = ResilientHttpClient.normalizeCloudShareUrl(match.group(0)!);
      if (url != null) {
        final tailEnd =
            match.end + 48 < text.length ? match.end + 48 : text.length;
        final tail = text.substring(match.end, tailEnd);
        final inlineCode = RegExp(
          r'(?:提取码|访问码|密码|pwd|passcode|code)\s*[:：=]?\s*([a-zA-Z0-9]{4})(?![a-zA-Z0-9])',
          caseSensitive: false,
        ).firstMatch(tail)?.group(1);
        if (inlineCode != null) {
          url = _withPassword(url, inlineCode);
        }
        yield url;
      }
    }
  }

  static String _withPassword(String url, String code) {
    final uri = Uri.parse(url);
    if (!RegExp(r'^[a-zA-Z0-9]{4}$').hasMatch(code) ||
        uri.queryParameters.keys.any(
            (k) => const {'pwd', 'password', 'passcode', 'code'}.contains(k))) {
      return url;
    }
    return uri.replace(
      queryParameters: {...uri.queryParameters, 'pwd': code},
    ).toString();
  }

  static String _providerLabel(String provider) => switch (provider) {
        'quark' => '夸克',
        'uc' => 'UC',
        'ali' => '阿里云盘',
        'baidu' => '百度',
        _ => '网盘',
      };

  static List<CmsLine> _groupShares(Iterable<CmsEpisode> shares) {
    final providers = <String, List<CmsEpisode>>{};
    final seen = <String, int>{};
    for (final ep in shares) {
      final raw = ep.url.startsWith('mmshare://')
          ? ep.url.substring('mmshare://'.length).trim()
          : ep.url;
      final url = ResilientHttpClient.normalizeCloudShareUrl(raw);
      if (url == null) continue;
      final provider = ResilientHttpClient.cloudProviderForShare(url);
      if (provider == null) continue;
      final uri = Uri.parse(url);
      final query = Map<String, String>.of(uri.queryParameters)
        ..removeWhere((key, _) =>
            const {'pwd', 'password', 'passcode', 'code'}.contains(key));
      final identity = uri
          .replace(
              query: query.isEmpty ? '' : Uri(queryParameters: query).query)
          .toString();
      final label = _providerLabel(provider);
      final entries = providers.putIfAbsent(label, () => []);
      final index = seen[identity];
      final mmShareUrl = 'mmshare://$url';
      if (index != null) {
        if (!entries[index].url.contains('pwd=') &&
            uri.queryParameters.containsKey('pwd')) {
          entries[index] = CmsEpisode(
            name: entries[index].name,
            url: mmShareUrl,
            headers: ep.headers,
          );
        }
        continue;
      }
      seen[identity] = entries.length;
      entries.add(CmsEpisode(
        name: ep.name,
        url: mmShareUrl,
        headers: ep.headers,
      ));
    }
    return [
      for (final provider in const ['夸克', 'UC', '阿里云盘', '百度'])
        if (providers.containsKey(provider))
          CmsLine(name: '4K 网盘 · $provider', episodes: providers[provider]!),
    ];
  }

  static CmsVideo parseDetail(String raw, Uri base, CmsVideo fallback) {
    if (!raw.trimLeft().startsWith('<')) {
      final listing = parseListing(raw, base);
      if (listing.videos.isEmpty) return fallback;
      final detail =
          listing.videos.where((v) => v.id == fallback.id).firstOrNull ??
              listing.videos.first;
      return _copy(
        fallback,
        title: detail.title,
        poster: detail.poster,
        description: detail.description,
        lines: detail.lines,
      );
    }
    final doc = html.parse(raw);
    final shares = <CmsEpisode>[];
    for (final element in doc.querySelectorAll(
        'a, [data-url], [data-clipboard-text], [onclick], input, textarea')) {
      final values = [
        element.attributes['href'],
        element.attributes['data-url'],
        element.attributes['data-clipboard-text'],
        element.attributes['onclick'],
        element.attributes['value'],
        if (element.localName == 'textarea') element.text,
      ];
      var label = element.attributes['title'] ?? element.text;
      final container = _closest(
        element,
        {
          'module-play-list',
          'stui-content__playlist',
          'myui-content__list',
          'hl-plays-list',
        },
        listItem: true,
      );
      final heading = container?.attributes['data-title'] ??
          container?.previousElementSibling?.text ??
          '';
      final season =
          RegExp(r'第[零一二三四五六七八九十百\d]+季|S\d{1,2}', caseSensitive: false)
              .firstMatch(heading)
              ?.group(0);
      if (season != null && !label.contains(season)) label = '$season $label';
      final nearby = element.parent?.text ?? '';
      final code = element.attributes['data-pwd'] ??
          element.attributes['data-code'] ??
          (nearby.length < 200
              ? RegExp(r'(?:提取码|访问码|密码)\s*[:：]?\s*([a-zA-Z0-9]{4})')
                  .firstMatch(nearby)
                  ?.group(1)
              : null) ??
          '';
      for (final value in values.whereType<String>()) {
        for (final url in _shareUrls(value)) {
          shares.add(CmsEpisode(
            name: cleanEpisodeName(label, fallback: fallback.title),
            url: _withPassword(url, code),
          ));
        }
      }
    }
    for (final script in doc.querySelectorAll('script')) {
      final json =
          RegExp(r'(?:player_\w+\s*=\s*|^\s*)(\{[^;]*\})', dotAll: true)
              .firstMatch(script.text)
              ?.group(1);
      if (json != null) {
        try {
          final data = jsonDecode(json);
          if (data is Map && data['url'] is String) {
            var value = data['url'] as String;
            if ('${data['encrypt']}' == '2') {
              value = utf8.decode(base64.decode(value));
            }
            if ('${data['encrypt']}' == '1') {
              value = Uri.decodeComponent(value);
            }
            for (final url in _shareUrls(value)) {
              shares.add(CmsEpisode(name: fallback.title, url: url));
            }
          }
        } on FormatException {
          // Continue with plaintext URLs.
        }
      }
      for (final url in _shareUrls(script.text)) {
        shares.add(CmsEpisode(name: fallback.title, url: url));
      }
    }
    for (final url in _shareUrls(doc.body?.text ?? '')) {
      shares.add(CmsEpisode(name: fallback.title, url: url));
    }
    final title = doc
            .querySelector(
                'h1, .module-info-heading h1, .stui-content__detail .title, .hl-dc-title')
            ?.text
            .trim() ??
        '';
    final poster =
        doc.querySelector('meta[property="og:image"]')?.attributes['content'] ??
            '';
    final description = doc.querySelector(
        '.module-info-introduction, .stui-content__desc, .hl-content-wrap, meta[name="description"]');
    return _copy(
      fallback,
      title: title,
      poster: poster.isEmpty ? '' : base.resolve(poster).toString(),
      description:
          description?.attributes['content'] ?? description?.text.trim() ?? '',
      lines: _groupShares(shares),
    );
  }

  static CmsVideo _copy(
    CmsVideo original, {
    String title = '',
    String poster = '',
    String description = '',
    required List<CmsLine> lines,
  }) =>
      CmsVideo(
        id: original.id,
        title: title.isEmpty ? original.title : title,
        poster: poster.isEmpty ? original.poster : poster,
        description: description.isEmpty ? original.description : description,
        remarks: original.remarks,
        year: original.year,
        area: original.area,
        actor: original.actor,
        tag: original.tag,
        doubanScore: original.doubanScore,
        rtScore: original.rtScore,
        lines: lines,
        sourceWarnings: original.sourceWarnings,
      );
}
