/// Core domain models shared across macOS, iOS, iPadOS, Windows, and Android backup schemas.
library;

import 'dart:convert';

import 'csp_bridge.dart';
import 'live_catalog_parser.dart';
import 'spider_plugin_registry.dart';

class CmsDepot {
  final String name;
  final String url;
  final String subscriptionId;
  const CmsDepot({
    required this.name,
    required this.url,
    this.subscriptionId = '',
  });
  Map<String, dynamic> toJson() => {
    'name': name,
    'url': url,
    'subscriptionId': subscriptionId,
  };
  factory CmsDepot.fromJson(Map<String, dynamic> json) {
    return CmsDepot(
      name: (json['name'] ?? '').toString().trim(),
      url: (json['url'] ?? '').toString().trim(),
      subscriptionId: (json['subscriptionId'] ?? '').toString(),
    );
  }
}

class SubscriptionEntry {
  final String id;
  final String name;
  final String url;
  final String group;
  final String format;
  final bool isPrivate;
  final bool enabled;
  final String rawContent;
  final int siteCount;
  final int liveCount;
  final int updatedAt;
  final String warehouseUrl;
  final String activeDepotName;
  final List<CmsDepot> depots;
  const SubscriptionEntry({
    required this.id,
    required this.name,
    this.url = '',
    this.group = '默认分组',
    this.format = 'JSON',
    this.isPrivate = false,
    this.enabled = true,
    this.rawContent = '',
    this.siteCount = 0,
    this.liveCount = 0,
    this.updatedAt = 0,
    this.warehouseUrl = '',
    this.activeDepotName = '',
    this.depots = const [],
  });
  SubscriptionEntry copyWith({
    String? id,
    String? name,
    String? url,
    String? group,
    String? format,
    bool? isPrivate,
    bool? enabled,
    String? rawContent,
    int? siteCount,
    int? liveCount,
    int? updatedAt,
    String? warehouseUrl,
    String? activeDepotName,
    List<CmsDepot>? depots,
  }) {
    return SubscriptionEntry(
      id: id ?? this.id,
      name: name ?? this.name,
      url: url ?? this.url,
      group: group ?? this.group,
      format: format ?? this.format,
      isPrivate: isPrivate ?? this.isPrivate,
      enabled: enabled ?? this.enabled,
      rawContent: rawContent ?? this.rawContent,
      siteCount: siteCount ?? this.siteCount,
      liveCount: liveCount ?? this.liveCount,
      updatedAt: updatedAt ?? this.updatedAt,
      warehouseUrl: warehouseUrl ?? this.warehouseUrl,
      activeDepotName: activeDepotName ?? this.activeDepotName,
      depots: depots ?? this.depots,
    );
  }

  bool get isEffectivelyPrivate =>
      isPrivate || group.contains('隐私') || group.contains('私密');
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'url': url,
    'group': group,
    'format': format,
    'isPrivate': isEffectivelyPrivate,
    'enabled': enabled,
    'rawContent': rawContent,
    'siteCount': siteCount,
    'liveCount': liveCount,
    'updatedAt': updatedAt,
    'warehouseUrl': warehouseUrl,
    'activeDepotName': activeDepotName,
    'depots': depots.map((d) => d.toJson()).toList(),
  };
  factory SubscriptionEntry.fromJson(Map<String, dynamic> json) {
    final g = (json['group'] ?? '').toString().trim();
    final f = (json['format'] ?? '').toString().trim();
    final cleanGroup = g.isEmpty ? '默认分组' : g;
    return SubscriptionEntry(
      id: (json['id'] ?? '').toString().trim(),
      name: (json['name'] ?? '订阅源').toString().trim(),
      url: (json['url'] ?? '').toString().trim(),
      group: cleanGroup,
      format: f.isEmpty ? 'JSON' : f,
      isPrivate:
          json['isPrivate'] == true ||
          json['private'] == true ||
          json['hidden'] == true ||
          (json['space'] ?? '').toString().trim().toLowerCase() == 'private' ||
          cleanGroup.contains('隐私') ||
          cleanGroup.contains('私密'),
      enabled: json['enabled'] != false,
      rawContent: (json['rawContent'] ?? '').toString(),
      siteCount: (json['siteCount'] as num?)?.toInt() ?? 0,
      liveCount: (json['liveCount'] as num?)?.toInt() ?? 0,
      updatedAt: (json['updatedAt'] as num?)?.toInt() ?? 0,
      warehouseUrl: (json['warehouseUrl'] ?? '').toString(),
      activeDepotName: (json['activeDepotName'] ?? '').toString(),
      depots: (json['depots'] as List? ?? const [])
          .whereType<Map>()
          .map((d) => CmsDepot.fromJson(Map<String, dynamic>.from(d)))
          .toList(),
    );
  }
}

class CmsFilter {
  final String primaryTab;
  final String categoryId;
  final String genreLabel;
  final String area;
  final String year;
  const CmsFilter({
    this.primaryTab = 'recommend',
    this.categoryId = '',
    this.genreLabel = '',
    this.area = '',
    this.year = '',
  });
  bool get hasSubFilter =>
      categoryId.isNotEmpty ||
      genreLabel.isNotEmpty ||
      area.isNotEmpty ||
      year.isNotEmpty;
  int get activeDimensionCount =>
      (categoryId.isNotEmpty || genreLabel.isNotEmpty ? 1 : 0) +
      (area.isNotEmpty ? 1 : 0) +
      (year.isNotEmpty ? 1 : 0);
  CmsFilter copyWith({
    String? primaryTab,
    String? categoryId,
    String? genreLabel,
    String? area,
    String? year,
  }) {
    return CmsFilter(
      primaryTab: primaryTab ?? this.primaryTab,
      categoryId: categoryId ?? this.categoryId,
      genreLabel: genreLabel ?? this.genreLabel,
      area: area ?? this.area,
      year: year ?? this.year,
    );
  }
}

class CmsSite {
  static const String statusOk = 'ok';
  static const String statusNeedsJar = 'needs-jar';
  static const String statusUnsupportedType = 'unsupported-type';
  static const String statusAdapterMissing = 'adapter-missing';
  static const String statusExtTooLarge = 'ext-too-large';
  static const String statusCustomSiteUrl = 'custom-site-url';
  static const String statusParserRequired = 'parser-required';
  static const int maxExtSize = 128 * 1024;

  final String key;
  final String? originalKey;
  String get sourceKey => originalKey ?? key;
  final String name;
  final int type;
  final String api;
  final String? originalApi;
  String get sourceApi => originalApi ?? api;
  final String playUrl;
  final bool searchable;
  final String ext;
  final bool extTooLarge;
  final bool requiresParser;
  /// Original JSON string value for full-name JS Spider init. [ext] keeps the
  /// existing normalized URL/plugin representation; object values have no raw string.
  final String? rawExtension;
  /// Site override and the owning subscription's plugin declaration, respectively.
  /// Keep both on the site: a merged subscription has no single global plugin.
  final String jar;
  final String spider;
  String get pluginReference => jar.isNotEmpty ? jar : spider;
  final Map<String, String> headers;
  final String group;
  final bool isPrivate;
  final String subscriptionId;
  const CmsSite({
    required this.key,
    this.originalKey,
    this.originalApi,
    required this.name,
    required this.type,
    required this.api,
    this.playUrl = '',
    this.searchable = true,
    this.ext = '',
    this.extTooLarge = false,
    this.requiresParser = false,
    this.rawExtension,
    this.jar = '',
    this.spider = '',
    this.headers = const {},
    this.group = '默认分组',
    this.isPrivate = false,
    this.subscriptionId = '',
  });

  bool get isExtTooLarge => extTooLarge || ext.length > maxExtSize;

  CmsSite copyWith({
    String? key,
    String? name,
    int? type,
    String? api,
    String? playUrl,
    bool? searchable,
    String? ext,
    bool? extTooLarge,
    bool? requiresParser,
    String? rawExtension,
    String? jar,
    String? spider,
    Map<String, String>? headers,
    String? group,
    bool? isPrivate,
    String? subscriptionId,
  }) {
    return CmsSite(
      key: key ?? this.key,
      originalKey: originalKey ?? this.key,
      originalApi: originalApi ?? this.api,
      name: name ?? this.name,
      type: type ?? this.type,
      api: api ?? this.api,
      playUrl: playUrl ?? this.playUrl,
      searchable: searchable ?? this.searchable,
      ext: ext ?? this.ext,
      extTooLarge: extTooLarge ?? this.extTooLarge,
      requiresParser: requiresParser ?? this.requiresParser,
      rawExtension: rawExtension ?? (ext == null ? this.rawExtension : null),
      jar: jar ?? this.jar,
      spider: spider ?? this.spider,
      headers: headers ?? this.headers,
      group: group ?? this.group,
      isPrivate: isPrivate ?? this.isPrivate,
      subscriptionId: subscriptionId ?? this.subscriptionId,
    );
  }

  bool get isHttpApi {
    final lower = api.trim().toLowerCase();
    return lower.startsWith('http://') || lower.startsWith('https://');
  }

  bool get isM3uVodApi {
    return api.trim().toLowerCase().startsWith('m3u_vod://');
  }

  bool get isScriptOrJarApi {
    final lower = api.trim().toLowerCase().split('?').first;
    return isRemoteScriptSource || lower.startsWith('csp_') ||
        lower.endsWith('.js') ||
        lower.endsWith('.mjs') ||
        lower.endsWith('.jar') ||
        lower.endsWith('.py');
  }

  bool get isJavaScriptSource {
    final path = api.toLowerCase().split(RegExp(r'[?#]')).first;
    return api == 'csp_LocalScript.js' ||
        (type == 3 &&
            isHttpApi &&
            (path.endsWith('.js') || path.endsWith('.mjs')));
  }

  /// TVBox type 3 declares a script, even when a gateway hides its extension.
  /// Android JARs still require their own runtime/explicit portable adapter.
  bool get isRemoteScriptSource => type == 3 && isHttpApi &&
      Uri.tryParse(api)?.path.toLowerCase().endsWith('.jar') != true;

  bool get isDrpySource => api == 'csp_LocalRule.js' || api.toLowerCase() == 'csp_drpy';

  bool get isPythonSource =>
      api == 'csp_LocalScript.py' ||
      (type == 3 &&
          isHttpApi &&
          Uri.tryParse(api)?.path.toLowerCase().endsWith('.py') == true);

  /// Supports standard JSON/XML CMS (`type` 0 or 1), remote HTTP spider endpoints (`type` 4),
  /// M3U/TXT VOD playlists (`m3u_vod://`), and TVBox `csp_*` / `.js` spider sites via `CspBridge`.
  bool get isEmby => api.startsWith('emby://account/');
  bool get isCatPaw => api.startsWith('catpaw://');
  bool get usesAdapterPack =>
      key != 'mydrive' &&
      !isExtTooLarge &&
      (type == 3 || isScriptOrJarApi) &&
      !CspBridge.hasAdapter(this) &&
      SpiderPluginRegistry.instance.matchAdapterRule(this) != null;

  bool get usesSpiderGateway =>
      key != 'mydrive' &&
      !isExtTooLarge &&
      (type == 3 || isScriptOrJarApi) &&
      !CspBridge.hasAdapter(this) &&
      SpiderPluginRegistry.instance.matchAdapterRule(this) == null &&
      SpiderPluginRegistry.instance.canGatewayHandle(this);

  bool get canBrowse =>
      key != 'mydrive' &&
      (isEmby ||
          isCatPaw ||
          (type == 4 && isHttpApi) ||
          (isScriptOrJarApi
              ? (CspBridge.hasAdapter(this) ||
                    SpiderPluginRegistry.instance.hasPluginOrGatewaySupport(
                      this,
                    ))
              : isM3uVodApi ||
                    ((isHttpApi || isScriptOrJarApi) &&
                        (type == 0 ||
                            type == 1 ||
                            type == 4 ||
                            type == 3 ||
                            type == -1))));
  bool get isEffectivelyPrivate =>
      isPrivate || group.contains('隐私') || group.contains('私密');
  bool get requiresPluginRuntime => !canBrowse;
  String get capabilityStatus {
    if (isExtTooLarge) {
      return statusExtTooLarge;
    }
    if (key == 'mydrive') {
      return statusUnsupportedType;
    }
    if ((type == 3 || isScriptOrJarApi) &&
        (CspBridge.hasAdapter(this) ||
            SpiderPluginRegistry.instance.hasPluginOrGatewaySupport(this))) {
      return statusOk;
    }
    if (isEmby || isCatPaw || isM3uVodApi || (type == 4 && isHttpApi)) {
      return statusOk;
    }
    if ((type == 3 || isScriptOrJarApi) && CspBridge.isNetdiskSite(this)) {
      return statusAdapterMissing;
    }
    if (type == 3 || isScriptOrJarApi) {
      return statusNeedsJar;
    }
    if (type != 0 && type != 1 && type != 4 && !(type == -1 && isHttpApi)) {
      return statusUnsupportedType;
    }
    if (!isHttpApi) {
      return statusCustomSiteUrl;
    }
    return statusOk;
  }

  /// Non-blocking playback-stage hint for sites marked `parse: 1` without a built-in `playUrl`.
  String get playbackHint {
    if (requiresParser && playUrl.trim().isEmpty) {
      return capabilityReason(statusParserRequired);
    }
    return '';
  }

  static String capabilityReason(String status) {
    return switch (status) {
      statusOk => '正常可用',
      statusNeedsJar => '此来源需要 Spider / JS / JAR 运行环境，基础版尚未支持',
      statusUnsupportedType => '暂不支持此类型来源，已保留在列表中',
      statusAdapterMissing => '此网盘源的原始插件尚未适配当前设备，无法读取原始网盘线路',
      statusExtTooLarge => '扩展参数超过大小上限，无法加载',
      statusCustomSiteUrl => '此来源不是可直接请求的 HTTP(S) CMS',
      statusParserRequired => '需要解析器，当前环境缺少可用解析配置',
      _ => '此来源暂不可用',
    };
  }

  String get limitation => unsupportedReason;

  bool get supported => capabilityStatus == statusOk;

  String get unsupportedReason {
    final status = capabilityStatus;
    if (status == statusOk || status == statusExtTooLarge) {
      return capabilityReason(status);
    }
    final lowerApi = api.trim().toLowerCase();
    if (lowerApi.startsWith('csp_sixv')) {
      return '该线路依赖 P2P / 磁力种子协议，受当前系统沙盒限制暂不支持';
    }
    if (lowerApi == 'csp_music' ||
        lowerApi == 'csp_musicguard' ||
        lowerApi.startsWith('csp_wexaiyueyue') ||
        lowerApi.startsWith('csp_ainewguanying') ||
        lowerApi.startsWith('csp_ainewlibvio') ||
        lowerApi.startsWith('csp_soaipansoo')) {
      return '该线路依赖交互式人机验证，当前设备暂不支持';
    }
    if (lowerApi.startsWith('csp_aipan1me')) {
      return '该线路依赖论坛回复解锁，当前设备暂不支持';
    }
    if (lowerApi.startsWith('csp_aidj') ||
        lowerApi.startsWith('csp_manjuaihongguo') ||
        lowerApi.startsWith('csp_bookhongguo')) {
      return '该线路使用专有加密流保护，当前设备暂不支持';
    }
    if (lowerApi.startsWith('csp_emby') ||
        lowerApi.startsWith('csp_alist') ||
        lowerApi.startsWith('csp_webdav') ||
        lowerApi.startsWith('csp_diyvod') ||
        lowerApi.startsWith('csp_fakeai115')) {
      return '该线路为自建服务模板（Emby / AList / WebDAV），需配置私有服务器参数';
    }
    if (lowerApi.startsWith('csp_maiduidui')) {
      return '该线路上游接口启用了专有设备签名限制，当前设备暂不支持';
    }
    if (lowerApi.startsWith('csp_sportaifeiqiu')) {
      return '该线路上游接口已失效或停服，当前暂不可用';
    }
    if (lowerApi.startsWith('csp_sssp')) {
      return '该线路包含受限第三方插件接口，当前设备暂不支持';
    }
    if (CspBridge.guardAdapterFor(this) != null) {
      return capabilityReason(status);
    }
    if (lowerApi.startsWith('csp_manjuai') ||
        lowerApi.startsWith('csp_duanjuai') ||
        lowerApi.startsWith('csp_anime') ||
        lowerApi.startsWith('csp_book') ||
        lowerApi.startsWith('csp_childrenai') ||
        lowerApi.startsWith('csp_musicai') ||
        lowerApi.startsWith('csp_sportai') ||
        lowerApi.startsWith('csp_liveaibili')) {
      return '该线路依赖 Android 原生加密组件（.so），iOS 与桌面端暂不支持';
    }
    return capabilityReason(capabilityStatus);
  }
}

class SiteOverride {
  final String? name;
  final String? group;
  final String? api;
  final String? playUrl;
  final String? ext;
  final bool? searchable;

  const SiteOverride({
    this.name,
    this.group,
    this.api,
    this.playUrl,
    this.ext,
    this.searchable,
  });

  bool get isEmpty =>
      name == null &&
      group == null &&
      api == null &&
      playUrl == null &&
      ext == null &&
      searchable == null;

  SiteOverride copyWith({
    String? name,
    bool clearName = false,
    String? group,
    bool clearGroup = false,
    String? api,
    bool clearApi = false,
    String? playUrl,
    bool clearPlayUrl = false,
    String? ext,
    bool clearExt = false,
    bool? searchable,
    bool clearSearchable = false,
  }) {
    return SiteOverride(
      name: clearName ? null : (name ?? this.name),
      group: clearGroup ? null : (group ?? this.group),
      api: clearApi ? null : (api ?? this.api),
      playUrl: clearPlayUrl ? null : (playUrl ?? this.playUrl),
      ext: clearExt ? null : (ext ?? this.ext),
      searchable: clearSearchable ? null : (searchable ?? this.searchable),
    );
  }

  Map<String, dynamic> toJson() => {
    if (name != null) 'name': name,
    if (group != null) 'group': group,
    if (api != null) 'api': api,
    if (playUrl != null) 'playUrl': playUrl,
    if (ext != null) 'ext': ext,
    if (searchable != null) 'searchable': searchable,
  };

  factory SiteOverride.fromJson(Map<String, dynamic> json) {
    String? optStr(String key, {bool allowEmpty = false}) {
      if (!json.containsKey(key) || json[key] == null) return null;
      if (json[key] is! String) {
        throw FormatException('线路覆盖字段 $key 类型无效');
      }
      final v = (json[key] as String).trim();
      if (!allowEmpty && v.isEmpty) return null;
      return v;
    }

    bool? optBool(String key) {
      if (!json.containsKey(key) || json[key] == null) return null;
      if (json[key] is! bool) {
        throw FormatException('线路覆盖字段 $key 类型无效');
      }
      return json[key] as bool;
    }

    return SiteOverride(
      name: optStr('name'),
      group: optStr('group'),
      api: optStr('api'),
      playUrl: optStr('playUrl', allowEmpty: true),
      ext: json.containsKey('ext') && json['ext'] is String
          ? json['ext'] as String
          : (json.containsKey('ext') && json['ext'] != null
                ? throw const FormatException('线路覆盖字段 ext 类型无效')
                : null),
      searchable: optBool('searchable'),
    );
  }

  CmsSite applyTo(CmsSite site) {
    if (isEmpty) return site;
    var nextType = site.type;
    final nextApi = api?.trim();
    if (nextApi != null && nextApi.isNotEmpty && nextApi != site.api) {
      final lower = nextApi.toLowerCase();
      if ((lower.startsWith('http://') || lower.startsWith('https://')) &&
          !lower.endsWith('.js') &&
          !lower.endsWith('.mjs') &&
          !lower.endsWith('.py') &&
          !lower.endsWith('.jar') &&
          nextType != 0 &&
          nextType != 1 &&
          nextType != 4) {
        nextType = lower.contains('xml') ? 0 : 1;
      }
    }
    final nextPlayUrl = playUrl != null ? playUrl!.trim() : site.playUrl;
    final nextExt = ext != null ? ext! : site.ext;
    return CmsSite(
      key: site.key,
      originalKey: site.sourceKey,
      originalApi: site.sourceApi,
      name: (name != null && name!.trim().isNotEmpty) ? name!.trim() : site.name,
      type: nextType,
      api: (nextApi != null && nextApi.isNotEmpty) ? nextApi : site.api,
      playUrl: nextPlayUrl,
      searchable: searchable ?? site.searchable,
      ext: nextExt,
      extTooLarge: ext != null
          ? nextExt.length > CmsSite.maxExtSize
          : site.extTooLarge,
      requiresParser: playUrl != null
          ? nextPlayUrl.isNotEmpty
          : site.requiresParser,
      rawExtension: ext != null
          ? (nextExt.isEmpty ? null : nextExt)
          : site.rawExtension,
      jar: site.jar,
      spider: site.spider,
      headers: site.headers,
      group: (group != null && group!.trim().isNotEmpty)
          ? group!.trim()
          : site.group,
      isPrivate: site.isPrivate,
      subscriptionId: site.subscriptionId,
    );
  }
}

class LiveSource {
  final String name;
  final String url;
  final Map<String, String> headers;
  final String group;
  final bool isPrivate;
  final String subscriptionId;
  /// Catalogue base URL and script owner survive subscription reloads.
  final String origin;
  final String inlineContent;
  final CmsSite? plugin;
  const LiveSource({
    required this.name,
    required this.url,
    this.headers = const {},
    this.group = '默认分组',
    this.isPrivate = false,
    this.subscriptionId = '',
    this.origin = '',
    this.inlineContent = '',
    this.plugin,
  });
  CmsSite get playbackSite => plugin ?? CmsSite(
    key: 'live:$subscriptionId:$name:$url', name: name, type: 1,
    api: url.startsWith('http') ? url : origin, headers: headers,
    group: group, isPrivate: isEffectivelyPrivate, subscriptionId: subscriptionId,
  );
  bool get isEffectivelyPrivate =>
      isPrivate || group.contains('隐私') || group.contains('私密');
  bool get isLocalPluginProxy =>
      plugin == null &&
      inlineContent.isEmpty &&
      LiveCatalogParser.isLocalPluginProxy(url);
  bool get supported {
    if (inlineContent.isNotEmpty) return true;
    if (plugin != null) return CspBridge.supportsLivePlugin(playbackSite);
    final u = url.trim();
    if (u.isEmpty || LiveCatalogParser.isLocalPluginProxy(u)) return false;
    if (u.startsWith('data:')) return u.contains('base64,');
    final uri = Uri.tryParse(u);
    return uri != null &&
        const {'http', 'https'}.contains(uri.scheme.toLowerCase()) &&
        uri.host.isNotEmpty;
  }
  LiveSource copyWith({
    String? name,
    String? url,
    Map<String, String>? headers,
    String? group,
    bool? isPrivate,
    String? subscriptionId,
    String? origin,
    String? inlineContent,
    CmsSite? plugin,
  }) {
    return LiveSource(
      name: name ?? this.name,
      url: url ?? this.url,
      headers: headers ?? this.headers,
      group: group ?? this.group,
      isPrivate: isPrivate ?? this.isPrivate,
      subscriptionId: subscriptionId ?? this.subscriptionId,
      origin: origin ?? this.origin,
      inlineContent: inlineContent ?? this.inlineContent,
      plugin: (plugin ?? this.plugin)?.copyWith(
        group: group ?? this.group, isPrivate: isPrivate ?? this.isPrivate,
        subscriptionId: subscriptionId ?? this.subscriptionId,
      ),
    );
  }
}

class CmsParse {
  final String name;
  final String url;
  final int type;
  final Map<String, String> headers;
  const CmsParse({
    required this.name,
    required this.url,
    this.type = 0,
    this.headers = const {},
  });
}

class CmsSniffRule {
  final String name;
  final List<String> hosts;
  final List<String> regex;
  final List<String> exclude;
  final String script;
  final String click;

  const CmsSniffRule({
    this.name = '',
    this.hosts = const [],
    this.regex = const [],
    this.exclude = const [],
    this.script = '',
    this.click = '',
  });

  bool get isEmpty =>
      name.trim().isEmpty &&
      hosts.isEmpty &&
      regex.isEmpty &&
      exclude.isEmpty &&
      script.trim().isEmpty &&
      click.trim().isEmpty;

  String get effectiveScript =>
      click.trim().isNotEmpty ? click.trim() : script.trim();

  String get combinedClickScript {
    final s = script.trim();
    final c = click.trim();
    final normalizedClick = c.isEmpty ? '' : _normalizeClickSnippet(c);
    if (s.isNotEmpty && normalizedClick.isNotEmpty) {
      return s == normalizedClick ? s : '$s\n$normalizedClick';
    }
    return s.isNotEmpty ? s : normalizedClick;
  }

  static String _normalizeClickSnippet(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return '';
    final looksLikeJs = trimmed.contains('(') ||
        trimmed.contains(';') ||
        trimmed.contains('=') ||
        trimmed.contains('{') ||
        trimmed.contains('=>') ||
        trimmed.contains('\n');
    if (looksLikeJs) return trimmed;
    final quoted = jsonEncode(trimmed);
    return 'try{var _el=document.querySelector($quoted);if(_el)_el.click();}catch(_){}';
  }

  bool matchesHost(String host) {
    final normalizedHost = host.trim().toLowerCase();
    if (normalizedHost.isEmpty || hosts.isEmpty) return false;
    for (final rawPattern in hosts) {
      final pattern = rawPattern.trim().toLowerCase();
      if (pattern.isEmpty) continue;
      if (pattern == '*') return true;
      if (pattern.startsWith('*.')) {
        final suffix = pattern.substring(2);
        if (suffix.isNotEmpty &&
            (normalizedHost == suffix || normalizedHost.endsWith('.$suffix'))) {
          return true;
        }
        continue;
      }
      if (pattern.startsWith('.')) {
        final suffix = pattern.substring(1);
        if (suffix.isNotEmpty &&
            (normalizedHost == suffix || normalizedHost.endsWith('.$suffix'))) {
          return true;
        }
        continue;
      }
      if (pattern.contains('*')) {
        final escaped = RegExp.escape(pattern).replaceAll(r'\*', '.*');
        if (RegExp('^$escaped\$', caseSensitive: false).hasMatch(normalizedHost)) {
          return true;
        }
        continue;
      }
      if (normalizedHost == pattern || normalizedHost.endsWith('.$pattern')) {
        return true;
      }
    }
    return false;
  }

  static List<String> _stringList(dynamic raw) {
    if (raw is List) {
      return List<String>.unmodifiable(
        raw
            .map((e) => (e ?? '').toString().trim())
            .where((s) => s.isNotEmpty),
      );
    }
    if (raw is String) {
      final trimmed = raw.trim();
      if (trimmed.isEmpty) return const [];
      return List<String>.unmodifiable([trimmed]);
    }
    return const [];
  }

  Map<String, dynamic> toJson() => {
        if (name.isNotEmpty) 'name': name,
        if (hosts.isNotEmpty) 'hosts': hosts,
        if (regex.isNotEmpty) 'regex': regex,
        if (exclude.isNotEmpty) 'exclude': exclude,
        if (script.isNotEmpty) 'script': script,
        if (click.isNotEmpty) 'click': click,
      };

  factory CmsSniffRule.fromJson(Map<String, dynamic> json) {
    return CmsSniffRule(
      name: (json['name'] ?? '').toString().trim(),
      hosts: _stringList(json['hosts'] ?? json['host']),
      regex: _stringList(json['regex']),
      exclude: _stringList(json['exclude'] ?? json['excludes']),
      script: (json['script'] ?? '').toString().trim(),
      click: (json['click'] ?? '').toString().trim(),
    );
  }
}

class CmsConfig {
  final List<CmsSite> sites;
  final List<LiveSource> lives;
  final List<CmsDepot> depots;
  final List<CmsParse> parses;
  final List<CmsSniffRule> rules;
  final List<String> ads;
  final String spider;
  const CmsConfig({
    this.sites = const [],
    this.lives = const [],
    this.depots = const [],
    this.parses = const [],
    this.rules = const [],
    this.ads = const [],
    this.spider = '',
  });
  List<CmsSniffRule> sniffRulesForHost(String host) =>
      rules.where((r) => r.matchesHost(host)).toList(growable: false);
  List<CmsSite> get supportedSites => List<CmsSite>.unmodifiable(sites);
  List<CmsSite> get publicSupportedSites => sites
      .where((s) => !s.isEffectivelyPrivate)
      .toList(growable: false);
  List<CmsSite> get privateSupportedSites => sites
      .where((s) => s.isEffectivelyPrivate)
      .toList(growable: false);

  List<CmsSite> get availableSites =>
      sites.where((s) => s.supported).toList(growable: false);
  List<CmsSite> get publicAvailableSites => sites
      .where((s) => s.supported && !s.isEffectivelyPrivate)
      .toList(growable: false);
  List<CmsSite> get privateAvailableSites => sites
      .where((s) => s.supported && s.isEffectivelyPrivate)
      .toList(growable: false);

  int get availableSiteCount => availableSites.length;
  int get publicAvailableSiteCount => publicAvailableSites.length;
  List<LiveSource> get publicLives =>
      lives.where((l) => !l.isEffectivelyPrivate).toList(growable: false);
  List<LiveSource> get privateLives =>
      lives.where((l) => l.isEffectivelyPrivate).toList(growable: false);
  List<LiveSource> get supportedLives =>
      lives.where((l) => l.supported).toList(growable: false);
  List<LiveSource> get publicSupportedLives => lives
      .where((l) => l.supported && !l.isEffectivelyPrivate)
      .toList(growable: false);
  List<LiveSource> get privateSupportedLives => lives
      .where((l) => l.supported && l.isEffectivelyPrivate)
      .toList(growable: false);
  List<CmsSite> get pluginOnlySites => sites
      .where(
        (s) =>
            !s.supported &&
            !CspBridge.isMyDriveSite(s) &&
            !CspBridge.isNetdiskSite(s) &&
            !s.api.toLowerCase().startsWith('csp_sixv') &&
            !(s.api.toLowerCase().startsWith('csp_xpathguard') && s.ext.trim().isEmpty),
      )
      .toList(growable: false);
  Iterable<CmsSite> get scriptOwners sync* {
    yield* sites;
    for (final live in lives) {
      if (live.plugin != null) yield live.playbackSite;
    }
  }
  bool get isMultiDepotOnly =>
      sites.isEmpty && lives.isEmpty && depots.isNotEmpty;
}

class CmsCategory {
  final String id;
  final String name;

  /// MacCMS `type_pid`; empty or `0` for top-level categories.
  final String parentId;
  const CmsCategory({required this.id, required this.name, this.parentId = ''});
  bool get isTopLevel => parentId.isEmpty || parentId == '0';
}

class CmsEpisode {
  final String name;
  final String url;
  final Map<String, String> headers;

  /// Ephemeral server playback metadata; never part of subscription/history backups.
  final Map<String, dynamic> playbackSession;
  /// Short-lived quality choices returned for one episode; not saved in history.
  final List<CmsEpisode> variants;
  final String externalAudioUrl;
  const CmsEpisode({
    required this.name,
    required this.url,
    this.headers = const {},
    this.playbackSession = const {},
    this.variants = const [],
    this.externalAudioUrl = '',
  });
  String? get cloudProvider {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.userInfo.isNotEmpty || uri.hasPort) return null;
    if (uri.scheme == 'mmcloud' && const {'uc', 'baidu', 'ali'}.contains(uri.host)) return uri.host;
    if ((uri.scheme == 'mmwogg' && uri.host == 'quark') ||
        (uri.scheme == 'mmquark' && uri.host == 'owned')) return 'quark';
    return null;
  }

  bool get isScriptEpisode => url.startsWith('mmjs://play?');
  bool get isGatewayEpisode => url.startsWith('mmgw://play?');
  bool get needsSourceResolution =>
      isScriptEpisode || isGatewayEpisode || url.startsWith('mmcloud://') || url.startsWith('mmemby://play?') || url.startsWith('mmpaw://play?') || url.startsWith('mmt4://play?') || url.startsWith('mmquark://owned?') || url.startsWith('mmwogg://quark?');

  /// Whether [url] points to an already-downloaded local file (offline playback).
  bool get isLocalFile {
    final raw = url.trim();
    return raw.startsWith('/') ||
        RegExp(r'^[a-zA-Z]:[\\/]').hasMatch(raw) ||
        raw.toLowerCase().startsWith('file://');
  }

  bool get isDirectPlayable {
    if (isLocalFile) return true;
    final u = url.trim().toLowerCase();
    if (!u.startsWith('http://') &&
        !u.startsWith('https://') &&
        !u.startsWith('rtmp://') &&
        !u.startsWith('rtsp://')) {
      return false;
    }
    if (u.contains('tuxiaobei.com/play/') ||
        u.contains('youlai.cn/jijiu/article/') ||
        u.contains('api.bilibili.com/x/player/playurl')) {
      return true;
    }
    final pathOnly = u.split('?').first.split('#').first;
    if (pathOnly.endsWith('.html') ||
        pathOnly.endsWith('.htm') ||
        pathOnly.contains('/share/')) {
      return false;
    }
    if (pathOnly.contains('/play/') &&
        !RegExp(
          r'\.(?:m3u8?|mp4|flv|mkv|ts|webm|mpd|mov|avi)$',
          caseSensitive: false,
        ).hasMatch(pathOnly)) {
      return false;
    }
    return true;
  }
}

class CmsLine {
  final String name;
  final List<CmsEpisode> episodes;
  const CmsLine({required this.name, required this.episodes});
}

class CmsVideo {
  final String id;
  final String title;
  final String poster;
  final String remarks;
  final String year;
  final String area;
  final String actor;
  final String description;
  final String tag;
  final double? doubanScore;
  final int? rtScore;
  final List<CmsLine> lines;
  final List<String> sourceWarnings;
  const CmsVideo({
    required this.id,
    required this.title,
    this.poster = '',
    this.remarks = '',
    this.year = '',
    this.area = '',
    this.actor = '',
    this.description = '',
    this.tag = '',
    this.doubanScore,
    this.rtScore,
    this.lines = const [],
    this.sourceWarnings = const [],
  });
}

class CmsListing {
  final int page;
  final int pageCount;
  final List<CmsVideo> videos;
  /// The requested subfilters were delegated to this source's category method.
  /// Its opaque filter values need not appear in returned video metadata.
  final bool sourceFiltered;
  const CmsListing({this.page = 1, this.pageCount = 1, this.videos = const [],
    this.sourceFiltered = false});
}

enum LiveStreamHealth {
  unknown,
  fast,
  smooth,
  slow,
  unreachable,
}

class StandaloneLiveSource {
  final String id;
  final String name;
  final String url;
  final String inlineContent;
  final String userAgent;
  final String logoTemplate;
  final bool autoCategorize;
  final bool enabled;
  final int updatedAt;

  const StandaloneLiveSource({
    required this.id,
    required this.name,
    this.url = '',
    this.inlineContent = '',
    this.userAgent = '',
    this.logoTemplate = '',
    this.autoCategorize = true,
    this.enabled = true,
    this.updatedAt = 0,
  });

  LiveSource toLiveSource() {
    final trimmedUa = userAgent.trim();
    return LiveSource(
      name: name.trim().isEmpty ? '自建直播源' : name.trim(),
      url: url.trim(),
      headers: trimmedUa.isNotEmpty ? {'User-Agent': trimmedUa} : const {},
      group: '电视直播',
      subscriptionId: 'standalone_live:$id',
      origin: url.trim(),
      inlineContent: inlineContent,
    );
  }

  StandaloneLiveSource copyWith({
    String? id,
    String? name,
    String? url,
    String? inlineContent,
    String? userAgent,
    String? logoTemplate,
    bool? autoCategorize,
    bool? enabled,
    int? updatedAt,
  }) {
    return StandaloneLiveSource(
      id: id ?? this.id,
      name: name ?? this.name,
      url: url ?? this.url,
      inlineContent: inlineContent ?? this.inlineContent,
      userAgent: userAgent ?? this.userAgent,
      logoTemplate: logoTemplate ?? this.logoTemplate,
      autoCategorize: autoCategorize ?? this.autoCategorize,
      enabled: enabled ?? this.enabled,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'url': url,
        if (inlineContent.isNotEmpty) 'inlineContent': inlineContent,
        if (userAgent.isNotEmpty) 'userAgent': userAgent,
        if (logoTemplate.isNotEmpty) 'logoTemplate': logoTemplate,
        'autoCategorize': autoCategorize,
        'enabled': enabled,
        'updatedAt': updatedAt,
      };

  static StandaloneLiveSource? fromJson(dynamic raw) {
    if (raw is! Map) return null;
    final id = (raw['id'] ?? '').toString().trim();
    final name = (raw['name'] ?? '').toString().trim();
    final url = (raw['url'] ?? '').toString().trim();
    final inlineContent = (raw['inlineContent'] ?? '').toString();
    if (id.isEmpty || (url.isEmpty && inlineContent.trim().isEmpty)) {
      return null;
    }
    return StandaloneLiveSource(
      id: id,
      name: name.isEmpty ? '自建直播源' : name,
      url: url,
      inlineContent: inlineContent,
      userAgent: (raw['userAgent'] ?? '').toString().trim(),
      logoTemplate: (raw['logoTemplate'] ?? '').toString().trim(),
      autoCategorize: raw['autoCategorize'] != false,
      enabled: raw['enabled'] != false,
      updatedAt: (raw['updatedAt'] as num?)?.toInt() ?? 0,
    );
  }
}

class LiveChannel {
  final String name;
  final String group;
  final List<String> urls;
  final String logo;
  final List<CmsEpisode> streams;
  final LiveStreamHealth health;
  final int? latencyMs;
  final int? reachableCount;
  const LiveChannel({
    required this.name,
    required this.group,
    required this.urls,
    this.logo = '',
    this.streams = const [],
    this.health = LiveStreamHealth.unknown,
    this.latencyMs,
    this.reachableCount,
  });
  List<CmsEpisode> get episodes => streams.isNotEmpty ? streams : [
    for (var i = 0; i < urls.length; i++)
      CmsEpisode(name: '线路 ${i + 1}', url: urls[i]),
  ];

  LiveChannel copyWith({
    String? name,
    String? group,
    List<String>? urls,
    String? logo,
    List<CmsEpisode>? streams,
    LiveStreamHealth? health,
    int? latencyMs,
    bool clearLatency = false,
    int? reachableCount,
    bool clearReachableCount = false,
  }) {
    return LiveChannel(
      name: name ?? this.name,
      group: group ?? this.group,
      urls: urls ?? this.urls,
      logo: logo ?? this.logo,
      streams: streams ?? this.streams,
      health: health ?? this.health,
      latencyMs: clearLatency ? null : (latencyMs ?? this.latencyMs),
      reachableCount: clearReachableCount
          ? null
          : (reachableCount ?? this.reachableCount),
    );
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'group': group,
        'urls': urls,
        if (logo.isNotEmpty) 'logo': logo,
        if (streams.isNotEmpty)
          'streams': [
            for (final s in streams)
              {
                'name': s.name,
                'url': s.url,
                if (s.headers.isNotEmpty) 'headers': s.headers,
              },
          ],
        if (health != LiveStreamHealth.unknown) 'health': health.name,
        if (latencyMs != null) 'latencyMs': latencyMs,
        if (reachableCount != null) 'reachableCount': reachableCount,
      };

  static LiveChannel? fromJson(dynamic raw) {
    if (raw is! Map) return null;
    final name = (raw['name'] ?? '').toString().trim();
    final group = (raw['group'] ?? '').toString().trim();
    final urlsRaw = raw['urls'];
    final urls = urlsRaw is List
        ? urlsRaw.map((e) => e.toString()).where((e) => e.isNotEmpty).toList()
        : <String>[];
    final streamsRaw = raw['streams'];
    final streams = <CmsEpisode>[];
    if (streamsRaw is List) {
      for (final item in streamsRaw.whereType<Map>()) {
        final u = (item['url'] ?? '').toString().trim();
        if (u.isEmpty) continue;
        final hRaw = item['headers'];
        final headers = hRaw is Map
            ? hRaw.map((k, v) => MapEntry(k.toString(), v.toString()))
            : const <String, String>{};
        streams.add(CmsEpisode(
          name: (item['name'] ?? '线路 ${streams.length + 1}').toString(),
          url: u,
          headers: headers,
        ));
      }
    }
    if (name.isEmpty || (urls.isEmpty && streams.isEmpty)) return null;
    final healthStr = (raw['health'] ?? '').toString();
    final health = LiveStreamHealth.values.firstWhere(
      (h) => h.name == healthStr,
      orElse: () => LiveStreamHealth.unknown,
    );
    return LiveChannel(
      name: name,
      group: group.isEmpty ? '综合频道' : group,
      urls: urls.isNotEmpty ? urls : streams.map((s) => s.url).toList(),
      logo: (raw['logo'] ?? '').toString(),
      streams: streams,
      health: health,
      latencyMs: (raw['latencyMs'] as num?)?.toInt(),
      reachableCount: (raw['reachableCount'] as num?)?.toInt(),
    );
  }
}

class LiveGroup {
  final String name;
  final List<LiveChannel> channels;
  const LiveGroup({required this.name, required this.channels});

  Map<String, dynamic> toJson() => {
        'name': name,
        'channels': [for (final ch in channels) ch.toJson()],
      };

  static LiveGroup? fromJson(dynamic raw) {
    if (raw is! Map) return null;
    final name = (raw['name'] ?? '').toString().trim();
    final chRaw = raw['channels'];
    if (name.isEmpty || chRaw is! List) return null;
    final channels = <LiveChannel>[];
    for (final item in chRaw) {
      final parsed = LiveChannel.fromJson(item);
      if (parsed != null) channels.add(parsed);
    }
    if (channels.isEmpty) return null;
    return LiveGroup(name: name, channels: channels);
  }
}

class WatchHistoryEntry {
  final String site;
  final String id;
  final String title;
  final String poster;
  final String line;
  final String episode;
  final int index;
  final int position;
  final int duration;
  final int updated;
  const WatchHistoryEntry({
    required this.site,
    required this.id,
    required this.title,
    this.poster = '',
    this.line = '',
    this.episode = '',
    this.index = 0,
    this.position = 0,
    this.duration = 0,
    this.updated = 0,
  });
  String get key => '$site\n$id';
  bool get complete =>
      duration >= 60000 &&
      position >= duration - (duration * 0.05).round().clamp(15000, 120000);
  int get resumePosition => complete ? 0 : (position < 0 ? 0 : position);
  double get progressFraction {
    if (duration <= 0) return 0.0;
    return (position / duration).clamp(0.0, 1.0);
  }

  Map<String, dynamic> toJson() => {
    'site': site,
    'id': id,
    'title': title,
    'poster': poster,
    'line': line,
    'episode': episode,
    'index': index,
    'position': position < 0 ? 0 : position,
    'duration': duration < 0 ? 0 : duration,
    'updated': updated,
  };
  factory WatchHistoryEntry.fromJson(Map<String, dynamic> json) {
    final pos = (json['position'] as num?)?.toInt() ?? 0;
    final dur = (json['duration'] as num?)?.toInt() ?? 0;
    return WatchHistoryEntry(
      site: (json['site'] ?? '').toString(),
      id: (json['id'] ?? '').toString(),
      title: (json['title'] ?? '').toString(),
      poster: (json['poster'] ?? '').toString(),
      line: (json['line'] ?? '').toString(),
      episode: (json['episode'] ?? '').toString(),
      index: (json['index'] as num?)?.toInt() ?? 0,
      position: pos < 0 ? 0 : pos,
      duration: dur < 0 ? 0 : dur,
      updated: (json['updated'] as num?)?.toInt() ?? 0,
    );
  }
}

class FavoriteEntry {
  final String site;
  final String id;
  final String title;
  final String poster;
  final String remarks;
  final int updated;
  const FavoriteEntry({
    required this.site,
    required this.id,
    required this.title,
    this.poster = '',
    this.remarks = '',
    this.updated = 0,
  });
  String get key => '$site\n$id';
  Map<String, dynamic> toJson() => {
    'site': site,
    'id': id,
    'title': title,
    'poster': poster,
    'remarks': remarks,
    'updated': updated,
  };
  factory FavoriteEntry.fromJson(Map<String, dynamic> json) {
    return FavoriteEntry(
      site: (json['site'] ?? '').toString(),
      id: (json['id'] ?? '').toString(),
      title: (json['title'] ?? '').toString(),
      poster: (json['poster'] ?? '').toString(),
      remarks: (json['remarks'] ?? '').toString(),
      updated: (json['updated'] as num?)?.toInt() ?? 0,
    );
  }
}
