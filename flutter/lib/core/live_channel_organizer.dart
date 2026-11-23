import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'models.dart';

/// Visual emblem specification for a TV channel badge (used when a playlist
/// does not supply a `tvg-logo` image or while the image loads/falls back).
class LiveStationEmblem {
  final int colorStart;
  final int colorEnd;
  final int accentColor;
  final String topLine;
  final String mainText;
  final String categoryLabel;

  const LiveStationEmblem({
    required this.colorStart,
    required this.colorEnd,
    required this.accentColor,
    required this.topLine,
    required this.mainText,
    required this.categoryLabel,
  });
}

/// Probe result for a single live stream URL.
class LiveStreamProbeResult {
  final String url;
  final bool reachable;
  final int? latencyMs;
  final int? statusCode;
  final bool isHls;
  final LiveStreamHealth health;

  const LiveStreamProbeResult({
    required this.url,
    required this.reachable,
    this.latencyMs,
    this.statusCode,
    this.isHls = false,
    required this.health,
  });

  static LiveStreamHealth healthFromLatency(int latencyMs) {
    if (latencyMs <= 550) return LiveStreamHealth.fast;
    if (latencyMs <= 1600) return LiveStreamHealth.smooth;
    return LiveStreamHealth.slow;
  }
}

/// Progress snapshot emitted while probing live channels.
class LiveProbeProgress {
  final int completedChannels;
  final int totalChannels;
  final int reachableChannels;
  final int unreachableChannels;

  const LiveProbeProgress({
    required this.completedChannels,
    required this.totalChannels,
    required this.reachableChannels,
    required this.unreachableChannels,
  });

  double get fraction =>
      totalChannels <= 0 ? 0.0 : (completedChannels / totalChannels).clamp(0.0, 1.0);
}

typedef LiveStreamProbeFn = Future<LiveStreamProbeResult> Function(
  CmsEpisode stream, {
  required Duration timeout,
  required bool Function() isCancelled,
});

/// Pure-Dart automatic channel organizer, station logo matcher, and
/// connectivity/latency prober for standalone and subscription live playlists.
class LiveChannelOrganizer {
  static const String failedGroupName = '失效频道';

  static const List<String> canonicalGroupOrder = [
    '央视',
    '卫视',
    '4K 超清',
    '港澳台',
    '体育赛事',
    '影视轮播',
    '少儿动漫',
    '纪录科教',
    '新闻财经',
    '音乐戏曲',
    '地方频道',
    '国际频道',
    '综合频道',
  ];

  static const Set<String> _genericGroups = {
    '',
    '默认频道',
    '默认分组',
    '直播频道',
    '精选频道',
    '电视直播',
    '未分组',
    '其他',
    '其它',
    '其他频道',
    '其它频道',
    '综合',
    '综合频道',
    '全部',
    'default',
    'other',
    'others',
    'ungrouped',
    'undefined',
    'live',
    'iptv',
    'tv',
    'all',
  };

  static bool isGenericGroupName(String group) =>
      _genericGroups.contains(group.trim().toLowerCase());

  /// Extracts a clean display/lookup stem by removing resolution & line tags
  /// (e.g. `CCTV-1 综合 [4K]` -> `CCTV-1`).
  static String cleanChannelTitle(String rawName) {
    var s = rawName.trim();
    if (s.isEmpty) return '';
    s = s.replaceAll(RegExp(r'[\[\(（【][^\]\)）】]*[\]\)）】]'), ' ');
    s = s.replaceAll(
      RegExp(
        r'\b(?:4K|8K|UHD|FHD|HD|SD|1080P?|720P?|2160P?|50FPS|60FPS|HDR|HEVC|H265|H264|IPV6|IPV4)\b',
        caseSensitive: false,
      ),
      ' ',
    );
    s = s.replaceAll(
      RegExp(r'(?:超清|高清|标清|蓝光|原画|高码|流畅|测试|备用|主用|线路\d+|源\d+)'),
      ' ',
    );
    return s.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  /// Canonical lookup key shared across aliases (`CCTV-1 综合 HD` == `CCTV1`).
  static String canonicalChannelKey(String rawName) {
    final cleaned = cleanChannelTitle(rawName).toUpperCase();
    final cctv = RegExp(
      r'CCTV[-\s]*(\d+\+?|[48]K|NEWS|MUSIC|MOVIE|OPERA|SPORTS?)',
      caseSensitive: false,
    ).firstMatch(cleaned);
    if (cctv != null) {
      return 'CCTV${cctv.group(1)!.toUpperCase()}';
    }
    final cgtn = RegExp(r'CGTN[-\s]*([A-Z]+)?', caseSensitive: false)
        .firstMatch(cleaned);
    if (cgtn != null) {
      final suffix = (cgtn.group(1) ?? '').toUpperCase();
      return suffix.isEmpty ? 'CGTN' : 'CGTN$suffix';
    }
    if (cleaned.contains('卫视')) {
      final idx = cleaned.indexOf('卫视');
      final prefix = cleaned
          .substring(0, idx)
          .replaceAll(RegExp(r'[\s\-_·]+'), '');
      if (prefix.isNotEmpty) return '$prefix卫视';
    }
    return cleaned.replaceAll(RegExp(r'[\s\-_·]+'), '');
  }

  /// Automatically categorizes a channel using its name and existing group.
  static String classifyChannel(
    LiveChannel channel, {
    bool forceAuto = false,
  }) {
    final existing = channel.group.trim();
    if (existing == failedGroupName) return failedGroupName;

    final name = channel.name.trim();
    final upper = name.toUpperCase();
    final combined = '$name $existing';
    final combinedUpper = combined.toUpperCase();

    // If the user/playlist already assigned a meaningful non-generic group and
    // auto-recategorization is not forced, normalize common synonyms only.
    if (!forceAuto && !isGenericGroupName(existing)) {
      return _normalizeGroupSynonym(existing);
    }

    // 1. 央视 (CCTV / CGTN / 中央 / 风云剧场 / CHC)
    if (RegExp(r'(?:^|[^A-Z])(?:CCTV|CGTN|CETV)', caseSensitive: false)
            .hasMatch(upper) ||
        name.contains('央视') ||
        name.contains('中央') ||
        upper.contains('CCTV') ||
        RegExp(r'风云(?:剧场|音乐|足球)|怀旧剧场|第一剧场|兵器科技|世界地理|央视文化|国防军事')
            .hasMatch(name)) {
      if ((upper.contains('4K') || upper.contains('8K')) &&
          !RegExp(r'CCTV[-\s]*\d+', caseSensitive: false).hasMatch(upper)) {
        return '4K 超清';
      }
      return '央视';
    }

    // 2. 4K / 8K UHD showcase channels
    if (RegExp(r'(?:^|[^A-Z0-9])(?:4K|8K|UHD|2160P)(?:$|[^A-Z0-9])',
            caseSensitive: false)
        .hasMatch(upper) &&
        !name.contains('卫视')) {
      return '4K 超清';
    }

    // 3. 港澳台 (Hong Kong / Macau / Taiwan)
    if (RegExp(
      r'翡翠|明珠|凤凰|鳳凰|TVB|J2|VIUTV|NOW\s*TV|HOY|RTHK|香港|澳门|澳門|澳视|澳視|莲花|蓮花|星空卫视|华娱|華娛|东森|東森|纬来|緯來|中天|三立|民视|民視|华视|華視|中视|中視|台视|台視|公视|公視|年代|非凡|大爱|大愛|龙祥|龍祥|靖天|八大|东森|美亚|美亞|天映|千禧|珠江台|明珠台|翡翠台|无线|無線|星河|华丽|華麗|港台|港澳台|台湾|台灣',
      caseSensitive: false,
    ).hasMatch(combined)) {
      return '港澳台';
    }

    // 4. 卫视 (Provincial satellite TV)
    if (name.contains('卫视') || name.contains('衛視')) {
      return '卫视';
    }

    // 5. 体育赛事
    if (RegExp(
      r'体育|體育|足球|篮球|籃球|赛事|賽事|咪咕|五星|劲爆|勁爆|高尔夫|网球|網球|NBA|CBA|F1|UFC|ESPN|BEIN|FOX\s*SPORT|SKY\s*SPORT|EUROSPORT|DAZN|SPORT|英超|西甲|欧冠|歐冠|德甲|意甲|中超',
      caseSensitive: false,
    ).hasMatch(combined)) {
      return '体育赛事';
    }

    // 6. 少儿动漫
    if (RegExp(
      r'少儿|少兒|卡通|动漫|動漫|动画|動畫|金鹰卡通|卡酷|炫动|哈哈|优漫|嘉佳|迪士尼|DISNEY|NICK|CARTOON|BABY|ANIME|萌娃|贝瓦|巧虎|熊出没|蜡笔小新|柯南|海贼王',
      caseSensitive: false,
    ).hasMatch(combined)) {
      return '少儿动漫';
    }

    // 7. 纪录科教
    if (RegExp(
      r'纪录|紀錄|纪实|紀實|探索|科教|地理|人文|历史|歷史|考古|自然|动物|動物|科普|教育|空中课堂|DISCOVERY|NGC|NATIONAL\s*GEO|BBC\s*EARTH|HISTORY|ANIMAL\s*PLANET',
      caseSensitive: false,
    ).hasMatch(combined)) {
      return '纪录科教';
    }

    // 8. 新闻财经
    if (RegExp(
      r'新闻|新聞|财经|財經|资讯|資訊|证券|證券|第一财经|凤凰资讯|CNN|BBC\s*WORLD|BLOOMBERG|CNBC|AL\s*JAZEERA|FRANCE\s*24|DW\s|NHK|NEWS',
      caseSensitive: false,
    ).hasMatch(combined)) {
      return '新闻财经';
    }

    // 9. 音乐戏曲
    if (RegExp(
      r'音乐|音樂|戏曲|戲曲|梨园|梨園|相声|相聲|小品|春晚|演唱会|演唱會|MTV|MUSIC|MV\b|经典老歌|民歌|曲艺|评书',
      caseSensitive: false,
    ).hasMatch(combined)) {
      return '音乐戏曲';
    }

    // 10. 影视轮播
    if (RegExp(
      r'电影|電影|影院|影视|影視|剧场|劇場|轮播|輪播|大片|动作|動作|喜剧|喜劇|科幻|悬疑|懸疑|恐怖|爱情|愛情|武侠|武俠|经典|經典|CHC|NEWTV|IHOT|BES\s*TV|百视通|埋堆堆|华数|華數|欢笑|歡笑|求索|HBO|CINEMAX|AXN|STAR\s*MOVIES|MOVIE|CINEMA|DRAMA',
      caseSensitive: false,
    ).hasMatch(combined)) {
      return '影视轮播';
    }

    // 11. 国际频道
    if (RegExp(
      r'KBS|MBC|SBS|TVN|NHK|FUJI|TBS|ARIRANG|CNN|BBC|FOX|ABC|NBC|CBS|HBO|DISCOVERY|RT\s|EURONEWS|JAPAN|KOREA|USA|UK\s|国际|國際|海外|日本|韩国|韓國|欧美|歐美',
      caseSensitive: false,
    ).hasMatch(combinedUpper)) {
      return '国际频道';
    }

    // 12. 地方频道 (Provincial/municipal channels)
    if (RegExp(
      r'北京|BRTV|BTV|上海|东方|東方|天津|重庆|重慶|广东|廣東|广州|廣州|深圳|珠江|浙江|杭州|宁波|江苏|江蘇|南京|苏州|湖南|长沙|湖北|武汉|四川|成都|山东|山東|济南|青岛|河南|郑州|河北|山西|陕西|陝西|西安|辽宁|遼寧|沈阳|大连|吉林|长春|黑龙江|黑龍江|哈尔滨|福建|福州|厦门|安徽|合肥|江西|南昌|云南|雲南|昆明|贵州|貴州|广西|廣西|南宁|海南|甘肃|甘肅|青海|宁夏|寧夏|新疆|西藏|内蒙古|內蒙古|都市|民生|公共|经视|經視|经济|經濟|生活|交通|文旅|农科|影视频道|新闻综合|综合频道',
    ).hasMatch(name)) {
      return '地方频道';
    }

    if (!isGenericGroupName(existing)) {
      return _normalizeGroupSynonym(existing);
    }
    return '综合频道';
  }

  static String _normalizeGroupSynonym(String rawGroup) {
    final g = rawGroup.trim();
    final lower = g.toLowerCase();
    if (RegExp(r'央视|央視|中央|cctv').hasMatch(lower)) return '央视';
    if (RegExp(r'卫视|衛視').hasMatch(lower) && !lower.contains('港澳')) {
      return '卫视';
    }
    if (RegExp(r'4k|8k|uhd|超高清').hasMatch(lower)) return '4K 超清';
    if (RegExp(r'港澳|港台|台湾|台灣|香港|澳门|澳門').hasMatch(lower)) {
      return '港澳台';
    }
    if (RegExp(r'体育|體育|sport|赛事|賽事').hasMatch(lower)) return '体育赛事';
    if (RegExp(r'影视|影視|电影|電影|轮播|輪播|剧场|劇場|movie').hasMatch(lower)) {
      return '影视轮播';
    }
    if (RegExp(r'少儿|少兒|动漫|動漫|卡通|动画|動畫|kids').hasMatch(lower)) {
      return '少儿动漫';
    }
    if (RegExp(r'纪录|紀錄|纪实|紀實|科教|探索|doc').hasMatch(lower)) {
      return '纪录科教';
    }
    if (RegExp(r'新闻|新聞|财经|財經|资讯|資訊|news').hasMatch(lower)) {
      return '新闻财经';
    }
    if (RegExp(r'音乐|音樂|戏曲|戲曲|曲艺|music').hasMatch(lower)) {
      return '音乐戏曲';
    }
    if (RegExp(r'地方|省市|省内|本地').hasMatch(lower)) return '地方频道';
    if (RegExp(r'国际|國際|海外|日韩|欧美').hasMatch(lower)) return '国际频道';
    return g;
  }

  /// Organizes parsed live groups:
  /// 1. Cross-propagates `tvg-logo` across canonical channel aliases & applies
  ///    optional user-configured `logoTemplate`.
  /// 2. Auto-categorizes channels into clean canonical groups.
  /// 3. Deduplicates channels & merges multiple stream lines per channel.
  /// 4. Sorts groups and channels naturally (CCTV-1..17, health/latency first).
  static List<LiveGroup> organize(
    List<LiveGroup> input, {
    bool autoCategorize = true,
    bool mergeDuplicates = true,
    String logoTemplate = '',
  }) {
    if (input.isEmpty) return const [];

    // Pass 1: Collect best known logo per canonical channel key so channels
    // missing tvg-logo inherit the logo from another entry of the same station.
    final logoByCanonical = <String, String>{};
    for (final g in input) {
      for (final ch in g.channels) {
        if (ch.logo.trim().isNotEmpty) {
          final key = canonicalChannelKey(ch.name);
          if (key.isNotEmpty) {
            logoByCanonical.putIfAbsent(key, () => ch.logo.trim());
          }
        }
      }
    }

    // Pass 2: Bucket channels into target groups and optionally merge aliases.
    final buckets = <String, Map<String, LiveChannel>>{};
    final customGroupOrder = <String>[];

    for (final g in input) {
      for (final ch in g.channels) {
        final targetGroup = autoCategorize
            ? classifyChannel(ch, forceAuto: true)
            : classifyChannel(ch, forceAuto: false);
        if (!canonicalGroupOrder.contains(targetGroup) &&
            targetGroup != failedGroupName &&
            !customGroupOrder.contains(targetGroup)) {
          customGroupOrder.add(targetGroup);
        }
        final canonical = canonicalChannelKey(ch.name);
        final resolvedLogo = _resolveLogoUrl(
          ch.logo,
          canonicalKey: canonical,
          cleanName: cleanChannelTitle(ch.name),
          rawName: ch.name,
          logoByCanonical: logoByCanonical,
          logoTemplate: logoTemplate,
        );
        final normalized = ch.copyWith(
          group: targetGroup,
          logo: resolvedLogo,
        );
        final groupMap = buckets.putIfAbsent(targetGroup, () => {});
        final bucketKey = mergeDuplicates && canonical.isNotEmpty
            ? canonical
            : ch.name.trim().toLowerCase();

        final existing = groupMap[bucketKey];
        if (existing == null) {
          groupMap[bucketKey] = normalized;
        } else {
          // Merge backup streams while keeping unique (url, headers) pairs.
          final mergedStreams = <CmsEpisode>[...existing.episodes];
          final seenSig = <String>{
            for (final s in mergedStreams) '${s.url}|${jsonEncode(s.headers)}',
          };
          for (final s in normalized.episodes) {
            final sig = '${s.url}|${jsonEncode(s.headers)}';
            if (seenSig.add(sig)) {
              mergedStreams.add(
                CmsEpisode(
                  name: '线路 ${mergedStreams.length + 1}',
                  url: s.url,
                  headers: s.headers,
                ),
              );
            }
          }
          final bestHealth = _betterHealth(existing.health, normalized.health);
          final bestLatency = _minNullable(existing.latencyMs, normalized.latencyMs);
          final bestReachable = _sumReachable(
            existing.reachableCount,
            normalized.reachableCount,
          );
          groupMap[bucketKey] = existing.copyWith(
            logo: existing.logo.isNotEmpty ? existing.logo : normalized.logo,
            urls: mergedStreams.map((e) => e.url).toList(growable: false),
            streams: mergedStreams,
            health: bestHealth,
            latencyMs: bestLatency,
            reachableCount: bestReachable,
          );
        }
      }
    }

    // Pass 3: Sort groups in canonical order, custom groups next, failed last.
    final orderedNames = <String>[
      for (final name in canonicalGroupOrder)
        if (buckets.containsKey(name)) name,
      for (final name in customGroupOrder)
        if (buckets.containsKey(name)) name,
      if (buckets.containsKey(failedGroupName)) failedGroupName,
    ];

    return [
      for (final groupName in orderedNames)
        LiveGroup(
          name: groupName,
          channels: _sortChannelsInGroup(
            groupName,
            buckets[groupName]!.values.toList(),
          ),
        ),
    ];
  }

  static String _resolveLogoUrl(
    String explicitLogo, {
    required String canonicalKey,
    required String cleanName,
    required String rawName,
    required Map<String, String> logoByCanonical,
    required String logoTemplate,
  }) {
    final trimmed = explicitLogo.trim();
    if (trimmed.isNotEmpty) return trimmed;
    final matched = logoByCanonical[canonicalKey];
    if (matched != null && matched.isNotEmpty) return matched;
    final tpl = logoTemplate.trim();
    if (tpl.isNotEmpty &&
        (tpl.startsWith('http://') || tpl.startsWith('https://'))) {
      final token = cleanName.isNotEmpty ? cleanName : rawName.trim();
      final candidate = tpl
          .replaceAll('{name}', Uri.encodeComponent(token))
          .replaceAll('{raw}', Uri.encodeComponent(rawName.trim()))
          .replaceAll('{key}', Uri.encodeComponent(canonicalKey));
      final uri = Uri.tryParse(candidate);
      if (uri != null &&
          (uri.scheme == 'http' || uri.scheme == 'https') &&
          uri.host.isNotEmpty) {
        return uri.toString();
      }
    }
    return '';
  }

  static int _healthPriority(LiveStreamHealth h) => switch (h) {
        LiveStreamHealth.fast => 0,
        LiveStreamHealth.smooth => 1,
        LiveStreamHealth.slow => 2,
        LiveStreamHealth.unknown => 3,
        LiveStreamHealth.unreachable => 4,
      };

  static LiveStreamHealth _betterHealth(
    LiveStreamHealth a,
    LiveStreamHealth b,
  ) =>
      _healthPriority(a) <= _healthPriority(b) ? a : b;

  static int? _minNullable(int? a, int? b) {
    if (a == null) return b;
    if (b == null) return a;
    return a < b ? a : b;
  }

  static int? _sumReachable(int? a, int? b) {
    if (a == null && b == null) return null;
    return (a ?? 0) + (b ?? 0);
  }

  static int _cctvSortKey(String name) {
    final m = RegExp(r'CCTV[-\s]*(\d+)(\+)?', caseSensitive: false)
        .firstMatch(name);
    if (m != null) {
      final numPart = int.tryParse(m.group(1)!) ?? 99;
      final plus = m.group(2) != null ? 1 : 0;
      return numPart * 10 + plus;
    }
    final upper = name.toUpperCase();
    if (upper.contains('4K')) return 900;
    if (upper.contains('8K')) return 901;
    if (upper.contains('CGTN')) return 950;
    return 999;
  }

  static List<LiveChannel> _sortChannelsInGroup(
    String groupName,
    List<LiveChannel> channels,
  ) {
    if (groupName == '央视') {
      channels.sort((a, b) {
        final ka = _cctvSortKey(a.name);
        final kb = _cctvSortKey(b.name);
        if (ka != kb) return ka.compareTo(kb);
        return _compareHealthThenLatency(a, b);
      });
      return channels;
    }
    final hasAnyProbed =
        channels.any((c) => c.health != LiveStreamHealth.unknown);
    if (hasAnyProbed) {
      channels.sort(_compareHealthThenLatency);
    }
    return channels;
  }

  static int _compareHealthThenLatency(LiveChannel a, LiveChannel b) {
    final pa = _healthPriority(a.health);
    final pb = _healthPriority(b.health);
    if (pa != pb) return pa.compareTo(pb);
    final la = a.latencyMs ?? 999999;
    final lb = b.latencyMs ?? 999999;
    if (la != lb) return la.compareTo(lb);
    return a.name.compareTo(b.name);
  }

  /// Resolves a rich, brand-accurate TV station emblem for any channel name,
  /// ensuring every channel has a crisp visual logo even without `tvg-logo`.
  static LiveStationEmblem resolveStationEmblem(LiveChannel channel) {
    final name = channel.name.trim();
    final upper = name.toUpperCase();

    // 1. CCTV / CGTN
    final cctvMatch =
        RegExp(r'CCTV[-\s]*(\d+\+?|[48]K|[A-Z0-9]+)', caseSensitive: false)
            .firstMatch(upper);
    if (cctvMatch != null) {
      final numTag = cctvMatch.group(1)!;
      final isSport = numTag == '5' || numTag == '5+';
      final isUhd = numTag == '4K' || numTag == '8K';
      return LiveStationEmblem(
        colorStart: isUhd
            ? 0xFF7C3AED
            : (isSport ? 0xFF0284C7 : 0xFFE11D48),
        colorEnd: isUhd
            ? 0xFF4C1D95
            : (isSport ? 0xFF0369A1 : 0xFF9F1239),
        accentColor: isUhd ? 0xFFFBBF24 : 0xFFFFFFFF,
        topLine: 'CCTV',
        mainText: numTag.length > 4 ? numTag.substring(0, 4) : numTag,
        categoryLabel: '央视',
      );
    }
    if (upper.contains('CGTN')) {
      return const LiveStationEmblem(
        colorStart: 0xFF1D4ED8,
        colorEnd: 0xFF1E3A8A,
        accentColor: 0xFF93C5FD,
        topLine: 'CGTN',
        mainText: '国际',
        categoryLabel: '央视',
      );
    }

    // 2. Signature Provincial Satellite Stations (brand colors!)
    if (name.contains('卫视') || name.contains('衛視')) {
      final prefix = name
          .replaceAll(RegExp(r'(?:卫视|衛視).*$'), '')
          .replaceAll(RegExp(r'[\[\(（【].*?[\]\)）】]'), '')
          .trim();
      final shortPrefix = prefix.length >= 2
          ? prefix.substring(0, 2)
          : (prefix.isNotEmpty ? prefix : '卫视');
      final brand = _satelliteBrands[shortPrefix];
      return LiveStationEmblem(
        colorStart: brand?.$1 ?? 0xFFF59E0B,
        colorEnd: brand?.$2 ?? 0xFFB45309,
        accentColor: 0xFFFFFFFF,
        topLine: '卫视',
        mainText: shortPrefix,
        categoryLabel: '卫视',
      );
    }

    // 3. Hong Kong / Macau / Taiwan iconic stations
    if (upper.contains('TVB') || name.contains('翡翠') || name.contains('明珠')) {
      return LiveStationEmblem(
        colorStart: 0xFF059669,
        colorEnd: 0xFF047857,
        accentColor: 0xFF38BDF8,
        topLine: 'TVB',
        mainText: name.contains('明珠')
            ? '明珠'
            : (name.contains('翡翠') ? '翡翠' : 'TVB'),
        categoryLabel: '港澳台',
      );
    }
    if (name.contains('凤凰') || name.contains('鳳凰')) {
      return LiveStationEmblem(
        colorStart: 0xFFEA580C,
        colorEnd: 0xFF9A3412,
        accentColor: 0xFFFDE047,
        topLine: 'PHOENIX',
        mainText: name.contains('资讯') || name.contains('資訊')
            ? '资讯'
            : (name.contains('香港') ? '香港' : '凤凰'),
        categoryLabel: '港澳台',
      );
    }
    if (RegExp(r'VIUTV|NOW|HOY|RTHK|澳视|莲花|东森|纬来|中天|三立|民视|华视|中视|台视|公视|八大',
            caseSensitive: false)
        .hasMatch(name)) {
      final clean = cleanChannelTitle(name);
      final short = clean.length >= 2 ? clean.substring(0, 2) : '港台';
      return LiveStationEmblem(
        colorStart: 0xFF10B981,
        colorEnd: 0xFF065F46,
        accentColor: 0xFFA7F3D0,
        topLine: '港澳台',
        mainText: short,
        categoryLabel: '港澳台',
      );
    }

    // 4. 4K / 8K UHD
    if (upper.contains('8K') || upper.contains('4K') || upper.contains('UHD')) {
      return LiveStationEmblem(
        colorStart: 0xFF8B5CF6,
        colorEnd: 0xFF5B21B6,
        accentColor: 0xFFFBBF24,
        topLine: 'UHD',
        mainText: upper.contains('8K') ? '8K' : '4K',
        categoryLabel: '4K 超清',
      );
    }

    // 5. Sports
    if (RegExp(r'体育|足球|篮球|赛事|咪咕|五星|劲爆|NBA|ESPN|BEIN|SPORT',
            caseSensitive: false)
        .hasMatch(name)) {
      final clean = cleanChannelTitle(name);
      final short = upper.contains('NBA')
          ? 'NBA'
          : (upper.contains('ESPN')
              ? 'ESPN'
              : (clean.length >= 2 ? clean.substring(0, 2) : '体育'));
      return LiveStationEmblem(
        colorStart: 0xFF06B6D4,
        colorEnd: 0xFF0E7490,
        accentColor: 0xFFA5F3FC,
        topLine: 'SPORT',
        mainText: short,
        categoryLabel: '体育赛事',
      );
    }

    // 6. Movies / CHC / HBO / Cinema
    if (RegExp(r'电影|影院|剧场|影视|CHC|HBO|AXN|MOVIE|CINEMA',
            caseSensitive: false)
        .hasMatch(name)) {
      final clean = cleanChannelTitle(name);
      final short = upper.contains('CHC')
          ? 'CHC'
          : (upper.contains('HBO')
              ? 'HBO'
              : (clean.length >= 2 ? clean.substring(0, 2) : '影院'));
      return LiveStationEmblem(
        colorStart: 0xFFDC2626,
        colorEnd: 0xFF7F1D1D,
        accentColor: 0xFFFCA5A5,
        topLine: 'MOVIE',
        mainText: short,
        categoryLabel: '影视轮播',
      );
    }

    // 7. Kids / Anime
    if (RegExp(r'少儿|卡通|动漫|动画|卡酷|金鹰|炫动|哈哈|优漫|嘉佳|DISNEY',
            caseSensitive: false)
        .hasMatch(name)) {
      final clean = cleanChannelTitle(name);
      final short = clean.length >= 2 ? clean.substring(0, 2) : '少儿';
      return LiveStationEmblem(
        colorStart: 0xFFEC4899,
        colorEnd: 0xFFBE185D,
        accentColor: 0xFFFBCFE8,
        topLine: 'KIDS',
        mainText: short,
        categoryLabel: '少儿动漫',
      );
    }

    // 8. Documentary / Science
    if (RegExp(r'纪录|纪实|探索|科教|地理|DISCOVERY|NGC|BBC',
            caseSensitive: false)
        .hasMatch(name)) {
      final clean = cleanChannelTitle(name);
      final short = clean.length >= 2 ? clean.substring(0, 2) : '纪实';
      return LiveStationEmblem(
        colorStart: 0xFF0D9488,
        colorEnd: 0xFF115E59,
        accentColor: 0xFF99F6E4,
        topLine: 'DOC',
        mainText: short,
        categoryLabel: '纪录科教',
      );
    }

    // 9. News / Finance
    if (RegExp(r'新闻|财经|资讯|CNN|BLOOMBERG|CNBC|NHK',
            caseSensitive: false)
        .hasMatch(name)) {
      final clean = cleanChannelTitle(name);
      final short = clean.length >= 2 ? clean.substring(0, 2) : '新闻';
      return LiveStationEmblem(
        colorStart: 0xFF2563EB,
        colorEnd: 0xFF1E40AF,
        accentColor: 0xFFBFDBFE,
        topLine: 'NEWS',
        mainText: short,
        categoryLabel: '新闻财经',
      );
    }

    // 10. Music / Opera
    if (RegExp(r'音乐|戏曲|梨园|相声|MTV|MUSIC', caseSensitive: false)
        .hasMatch(name)) {
      final clean = cleanChannelTitle(name);
      final short = clean.length >= 2 ? clean.substring(0, 2) : '音乐';
      return LiveStationEmblem(
        colorStart: 0xFFA855F7,
        colorEnd: 0xFF6B21A8,
        accentColor: 0xFFE9D5FF,
        topLine: 'MUSIC',
        mainText: short,
        categoryLabel: '音乐戏曲',
      );
    }

    // 11. Local / General fallback with deterministic station-color hash
    final cleaned = cleanChannelTitle(name);
    final short = cleaned.length >= 2
        ? cleaned.substring(0, 2)
        : (cleaned.isNotEmpty ? cleaned : 'TV');
    final palette = _fallbackPalettes[short.hashCode.abs() % _fallbackPalettes.length];
    return LiveStationEmblem(
      colorStart: palette.$1,
      colorEnd: palette.$2,
      accentColor: 0xFFFFFFFF,
      topLine: channel.group.length <= 4 ? channel.group : 'LIVE',
      mainText: short,
      categoryLabel: channel.group,
    );
  }

  static const Map<String, (int, int)> _satelliteBrands = {
    '湖南': (0xFFF97316, 0xFFC2410C), // 芒果橙
    '浙江': (0xFF2563EB, 0xFF1D4ED8), // 蓝莓蓝
    '东方': (0xFFEF4444, 0xFFB91C1C), // 番茄红
    '江苏': (0xFFE11D48, 0xFF9F1239), // 荔枝红
    '北京': (0xFFDC2626, 0xFF991B1B), // 北京红
    '广东': (0xFF0284C7, 0xFF075985), // 南海蓝
    '深圳': (0xFFEA580C, 0xFF9A3412), // 先锋橙红
    '安徽': (0xFF0EA5E9, 0xFF0369A1), // 海豚蓝
    '山东': (0xFF0891B2, 0xFF155E75), // 海浪青
    '河南': (0xFFD97706, 0xFF92400E), // 中原金
    '湖北': (0xFF4F46E5, 0xFF3730A3), // 楚天紫蓝
    '四川': (0xFF059669, 0xFF065F46), // 熊猫青绿
    '辽宁': (0xFF1D4ED8, 0xFF1E3A8A),
    '天津': (0xFF0284C7, 0xFF0C4A6E),
    '重庆': (0xFFE11D48, 0xFF881337),
    '福建': (0xFF0D9488, 0xFF115E59),
    '东南': (0xFF0D9488, 0xFF115E59),
    '江西': (0xFFDC2626, 0xFF7F1D1D),
    '云南': (0xFF10B981, 0xFF047857),
    '贵州': (0xFF0891B2, 0xFF164E63),
    '广西': (0xFF0EA5E9, 0xFF075985),
    '海南': (0xFF06B6D4, 0xFF0E7490),
    '旅游': (0xFF06B6D4, 0xFF0E7490),
    '黑龙江': (0xFF2563EB, 0xFF1E3A8A),
    '黑龙': (0xFF2563EB, 0xFF1E3A8A),
    '吉林': (0xFF7C3AED, 0xFF5B21B6),
    '河北': (0xFFEA580C, 0xFF9A3412),
    '山西': (0xFF9333EA, 0xFF6B21A8),
    '陕西': (0xFFD97706, 0xFF92400E),
    '甘肃': (0xFFF59E0B, 0xFFB45309),
    '青海': (0xFF0EA5E9, 0xFF0369A1),
    '宁夏': (0xFF16A34A, 0xFF166534),
    '新疆': (0xFFDC2626, 0xFF991B1B),
    '西藏': (0xFFEAB308, 0xFFA16207),
    '内蒙': (0xFF15803D, 0xFF14532D),
    '兵团': (0xFFB91C1C, 0xFF7F1D1D),
  };

  static const List<(int, int)> _fallbackPalettes = [
    (0xFF3B82F6, 0xFF1D4ED8),
    (0xFF6366F1, 0xFF4338CA),
    (0xFF0EA5E9, 0xFF0369A1),
    (0xFF14B8A6, 0xFF0F766E),
    (0xFFF59E0B, 0xFFB45309),
    (0xFFEC4899, 0xFFBE185D),
  ];
}

/// Fast, bounded-concurrency live stream health prober that verifies stream
/// reachability and RTT latency without downloading full media payloads, then
/// reorders backup lines fastest-first and groups unreachable channels.
class LiveStreamProber {
  static const String defaultLiveUserAgent = 'okhttp/4.12.0';

  /// Probes a single stream endpoint (HTTP/HTTPS streaming header+first-chunk
  /// peek, or TCP connect for RTMP/RTSP). Never downloads the whole video.
  static Future<LiveStreamProbeResult> probeStreamDefault(
    CmsEpisode stream, {
    required Duration timeout,
    required bool Function() isCancelled,
  }) async {
    final uri = Uri.tryParse(stream.url.trim());
    if (uri == null || uri.host.isEmpty) {
      return LiveStreamProbeResult(
        url: stream.url,
        reachable: false,
        health: LiveStreamHealth.unreachable,
      );
    }
    final scheme = uri.scheme.toLowerCase();
    if (scheme == 'rtmp' || scheme == 'rtsp') {
      final port = uri.hasPort ? uri.port : (scheme == 'rtsp' ? 554 : 1935);
      final sw = Stopwatch()..start();
      Socket? socket;
      try {
        socket = await Socket.connect(uri.host, port, timeout: timeout);
        sw.stop();
        if (isCancelled()) {
          return LiveStreamProbeResult(
            url: stream.url,
            reachable: false,
            health: LiveStreamHealth.unreachable,
          );
        }
        final ms = sw.elapsedMilliseconds.clamp(1, 60000);
        return LiveStreamProbeResult(
          url: stream.url,
          reachable: true,
          latencyMs: ms,
          health: LiveStreamProbeResult.healthFromLatency(ms),
        );
      } catch (_) {
        return LiveStreamProbeResult(
          url: stream.url,
          reachable: false,
          health: LiveStreamHealth.unreachable,
        );
      } finally {
        socket?.destroy();
      }
    }

    if (scheme != 'http' && scheme != 'https') {
      return LiveStreamProbeResult(
        url: stream.url,
        reachable: false,
        health: LiveStreamHealth.unreachable,
      );
    }

    final client = HttpClient()
      ..connectionTimeout = timeout
      ..idleTimeout = const Duration(seconds: 2)
      ..autoUncompress = true
      ..badCertificateCallback = (_, __, ___) => true;

    final sw = Stopwatch()..start();
    try {
      var current = uri;
      for (var hop = 0; hop <= 3; hop++) {
        if (isCancelled()) {
          return LiveStreamProbeResult(
            url: stream.url,
            reachable: false,
            health: LiveStreamHealth.unreachable,
          );
        }
        final req = await client.getUrl(current).timeout(timeout);
        req.followRedirects = false;
        var hasUa = false;
        stream.headers.forEach((k, v) {
          final lower = k.toLowerCase();
          if (lower == 'host' ||
              lower == 'content-length' ||
              lower == 'connection') {
            return;
          }
          if (lower == 'user-agent') hasUa = true;
          try {
            req.headers.set(k, v);
          } catch (_) {}
        });
        if (!hasUa) {
          req.headers.set(HttpHeaders.userAgentHeader, defaultLiveUserAgent);
        }
        req.headers.set(HttpHeaders.acceptHeader, '*/*');
        req.headers.set(HttpHeaders.connectionHeader, 'close');

        final resp = await req.close().timeout(timeout);
        if (const [301, 302, 303, 307, 308].contains(resp.statusCode)) {
          final loc = resp.headers.value(HttpHeaders.locationHeader);
          await resp.drain<void>().catchError((_) {});
          if (loc == null || loc.trim().isEmpty || hop == 3) {
            return LiveStreamProbeResult(
              url: stream.url,
              reachable: false,
              statusCode: resp.statusCode,
              health: LiveStreamHealth.unreachable,
            );
          }
          current = current.resolve(loc.trim());
          continue;
        }

        if (resp.statusCode < 200 || resp.statusCode >= 300) {
          await resp.drain<void>().catchError((_) {});
          return LiveStreamProbeResult(
            url: stream.url,
            reachable: false,
            statusCode: resp.statusCode,
            health: LiveStreamHealth.unreachable,
          );
        }

        // Read only the first small chunk (<= 2 KB) to confirm the server
        // actually sends stream/playlist bytes rather than hanging or returning
        // an HTML error page with HTTP 200.
        final sample = <int>[];
        final completer = Completer<void>();
        late final StreamSubscription<List<int>> sub;
        sub = resp.listen(
          (chunk) {
            if (chunk.isNotEmpty) {
              final remain = 2048 - sample.length;
              if (remain > 0) {
                sample.addAll(
                  chunk.length <= remain ? chunk : chunk.sublist(0, remain),
                );
              }
            }
            if (sample.length >= 64 && !completer.isCompleted) {
              completer.complete();
              unawaited(sub.cancel());
            }
          },
          onDone: () {
            if (!completer.isCompleted) completer.complete();
          },
          onError: (_) {
            if (!completer.isCompleted) completer.complete();
          },
          cancelOnError: true,
        );
        try {
          await completer.future.timeout(timeout);
        } catch (_) {
          // If server sent 200 headers but never sent bytes within timeout,
          // treat as dead/stalled.
        } finally {
          await sub.cancel().catchError((_) {});
        }
        sw.stop();
        if (isCancelled() || sample.isEmpty) {
          return LiveStreamProbeResult(
            url: stream.url,
            reachable: false,
            statusCode: resp.statusCode,
            health: LiveStreamHealth.unreachable,
          );
        }

        final mime = (resp.headers.contentType?.mimeType ?? '').toLowerCase();
        final textHead = utf8.decode(sample, allowMalformed: true).trimLeft();
        final isHls = textHead.startsWith('#EXTM3U') ||
            mime.contains('mpegurl') ||
            current.path.toLowerCase().endsWith('.m3u8');
        final looksLikeHtmlError = !isHls &&
            (mime.contains('html') ||
                textHead.toLowerCase().startsWith('<!doctype html') ||
                textHead.toLowerCase().startsWith('<html'));
        if (looksLikeHtmlError) {
          return LiveStreamProbeResult(
            url: stream.url,
            reachable: false,
            statusCode: resp.statusCode,
            health: LiveStreamHealth.unreachable,
          );
        }

        final ms = sw.elapsedMilliseconds.clamp(1, 60000);
        return LiveStreamProbeResult(
          url: stream.url,
          reachable: true,
          latencyMs: ms,
          statusCode: resp.statusCode,
          isHls: isHls,
          health: LiveStreamProbeResult.healthFromLatency(ms),
        );
      }
      return LiveStreamProbeResult(
        url: stream.url,
        reachable: false,
        health: LiveStreamHealth.unreachable,
      );
    } catch (_) {
      return LiveStreamProbeResult(
        url: stream.url,
        reachable: false,
        health: LiveStreamHealth.unreachable,
      );
    } finally {
      client.close(force: true);
    }
  }

  /// Concurrently probes every channel in [groups], reorders each channel's
  /// backup lines fastest-first, marks channel health & latency, and
  /// automatically regroups unreachable channels into [LiveChannelOrganizer.failedGroupName].
  static Future<List<LiveGroup>> probeAndOrganize(
    List<LiveGroup> groups, {
    int concurrency = 8,
    Duration timeout = const Duration(milliseconds: 3200),
    int maxLinesPerChannel = 4,
    bool autoCategorize = true,
    String logoTemplate = '',
    Completer<void>? cancellation,
    void Function(LiveProbeProgress progress)? onProgress,
    LiveStreamProbeFn? probeStream,
  }) async {
    bool isCancelled() => cancellation?.isCompleted == true;
    final probeFn = probeStream ?? probeStreamDefault;

    final flat = <LiveChannel>[];
    for (final g in groups) {
      flat.addAll(g.channels);
    }
    if (flat.isEmpty) return const [];

    final updated = List<LiveChannel?>.filled(flat.length, null);
    final urlCache = <String, Future<LiveStreamProbeResult>>{};

    Future<LiveStreamProbeResult> probeCached(CmsEpisode ep) {
      final key = '${ep.url}|${jsonEncode(ep.headers)}';
      return urlCache.putIfAbsent(
        key,
        () => probeFn(ep, timeout: timeout, isCancelled: isCancelled),
      );
    }

    var nextIdx = 0;
    var doneCount = 0;
    var reachableChannels = 0;
    var unreachableChannels = 0;
    final workerCount = concurrency.clamp(1, 16);

    Future<void> worker() async {
      while (!isCancelled()) {
        final idx = nextIdx++;
        if (idx >= flat.length) return;
        final ch = flat[idx];
        final lines = ch.episodes;
        final probeLimit = lines.length < maxLinesPerChannel
            ? lines.length
            : maxLinesPerChannel;
        final scored = <({CmsEpisode ep, LiveStreamProbeResult res, int origIdx})>[];

        for (var i = 0; i < probeLimit; i++) {
          if (isCancelled()) return;
          final res = await probeCached(lines[i]);
          scored.add((ep: lines[i], res: res, origIdx: i));
        }
        // Keep unprobed tail lines intact behind probed reachable lines.
        final unprobed = lines.length > probeLimit
            ? lines.sublist(probeLimit)
            : const <CmsEpisode>[];

        final reachableLines = scored.where((s) => s.res.reachable).toList()
          ..sort((a, b) =>
              (a.res.latencyMs ?? 999999).compareTo(b.res.latencyMs ?? 999999));
        final deadLines = scored.where((s) => !s.res.reachable).toList();

        final reordered = <CmsEpisode>[
          for (var i = 0; i < reachableLines.length; i++)
            CmsEpisode(
              name: reachableLines[i].res.latencyMs != null
                  ? '线路 ${i + 1} (${reachableLines[i].res.latencyMs}ms)'
                  : '线路 ${i + 1}',
              url: reachableLines[i].ep.url,
              headers: reachableLines[i].ep.headers,
            ),
          for (var i = 0; i < unprobed.length; i++)
            CmsEpisode(
              name: '线路 ${reachableLines.length + i + 1}',
              url: unprobed[i].url,
              headers: unprobed[i].headers,
            ),
          for (var i = 0; i < deadLines.length; i++)
            CmsEpisode(
              name: '线路 ${reachableLines.length + unprobed.length + i + 1} (不可用)',
              url: deadLines[i].ep.url,
              headers: deadLines[i].ep.headers,
            ),
        ];

        final isReachable = reachableLines.isNotEmpty;
        final bestLatency =
            isReachable ? reachableLines.first.res.latencyMs : null;
        final health = isReachable
            ? (bestLatency != null
                ? LiveStreamProbeResult.healthFromLatency(bestLatency)
                : LiveStreamHealth.smooth)
            : LiveStreamHealth.unreachable;

        final targetGroup = isReachable
            ? (autoCategorize
                ? LiveChannelOrganizer.classifyChannel(
                    ch.group == LiveChannelOrganizer.failedGroupName
                        ? ch.copyWith(group: '')
                        : ch,
                    forceAuto: true,
                  )
                : (ch.group == LiveChannelOrganizer.failedGroupName
                    ? LiveChannelOrganizer.classifyChannel(
                        ch.copyWith(group: ''),
                        forceAuto: true,
                      )
                    : ch.group))
            : LiveChannelOrganizer.failedGroupName;

        updated[idx] = ch.copyWith(
          group: targetGroup,
          urls: reordered.map((e) => e.url).toList(growable: false),
          streams: reordered,
          health: health,
          latencyMs: bestLatency,
          clearLatency: bestLatency == null,
          reachableCount: reachableLines.length,
        );

        doneCount++;
        if (isReachable) {
          reachableChannels++;
        } else {
          unreachableChannels++;
        }
        onProgress?.call(
          LiveProbeProgress(
            completedChannels: doneCount,
            totalChannels: flat.length,
            reachableChannels: reachableChannels,
            unreachableChannels: unreachableChannels,
          ),
        );
      }
    }

    await Future.wait([for (var w = 0; w < workerCount; w++) worker()]);

    final resolvedChannels = <LiveChannel>[
      for (var i = 0; i < flat.length; i++) updated[i] ?? flat[i],
    ];
    return LiveChannelOrganizer.organize(
      [LiveGroup(name: '', channels: resolvedChannels)],
      autoCategorize: false,
      mergeDuplicates: false,
      logoTemplate: logoTemplate,
    );
  }
}
