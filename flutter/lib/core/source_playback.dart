import 'dart:convert';
import 'models.dart';

/// Normalizes the Spider protocol's URL, alternating label/URL and object forms.
class SourcePlayback {
  static Map<String, String> headersForOrigin(Map<String, String> sourceHeaders,
      Uri? sourceOrigin, Uri? target) {
    final sameOrigin = sourceOrigin != null && target != null &&
        sourceOrigin.scheme == target.scheme && sourceOrigin.host == target.host &&
        sourceOrigin.port == target.port;
    return Map.fromEntries(sourceHeaders.entries.where((entry) => sameOrigin ||
        !const ['authorization', 'proxy-authorization', 'cookie', 'cookie2',
          'x-api-key', 'x-emby-token', 'x-plex-token'].contains(entry.key.toLowerCase())));
  }

  static Map<String, String> _mergeHeaders(Iterable<Map<String, String>> layers) {
    final merged = <String, String>{};
    for (final layer in layers) {
      for (final entry in layer.entries) {
        merged.removeWhere((key, _) => key.toLowerCase() == entry.key.toLowerCase());
        merged[entry.key] = entry.value;
      }
    }
    return merged;
  }

  /// Apply import headers once at the resolver boundary, including plain CMS
  /// streams. Headers explicitly returned for this media always take precedence.
  static CmsEpisode inheritSourceHeaders(CmsEpisode episode,
      {required Map<String, String> sourceHeaders, Uri? sourceOrigin}) {
    return CmsEpisode(name: episode.name, url: episode.url,
        headers: _mergeHeaders([
          headersForOrigin(sourceHeaders, sourceOrigin, Uri.tryParse(episode.url)), episode.headers]),
        playbackSession: episode.playbackSession,
        externalAudioUrl: episode.externalAudioUrl,
        variants: episode.variants.map((item) => inheritSourceHeaders(item,
          sourceHeaders: sourceHeaders, sourceOrigin: sourceOrigin)).toList());
  }

  static bool needsParse(Object? value) {
    if (value == null || value == false || value == 0) return false;
    final text = value.toString().trim().toLowerCase();
    return text.isNotEmpty &&
        text != '0' &&
        text != 'false' &&
        text != 'null';
  }

  static Future<CmsEpisode> decode(Map raw, CmsEpisode episode,
      {required Future<Uri> Function(String) localUrl,
      Map<String,String> sourceHeaders = const {}, Uri? sourceOrigin}) async {
    if (needsParse(raw['parse']) || needsParse(raw['jx'])) {
      throw const FormatException('此线路还需要网页解析，请选择其他播放线路');
    }
    Map<String,String> headers(dynamic value) {
      if (value is String) {try {value=jsonDecode(value);} catch (_) {value=null;}}
      return value is Map ? value.map((k,v)=>MapEntry(k.toString(),v.toString())) : {};
    }
    final explicit = headers(raw['header'] ?? raw['headers']);
    final choices = <CmsEpisode>[];
    final seen = <String>{};
    ({String url, Uri uri, Map<String, String> inlineHeaders})? parseCandidate(
        dynamic value) {
      if (value is! String) return null;
      var text = value.trim();
      if (text.isEmpty) return null;
      final inline = <String, String>{};
      final pipe = text.indexOf('|');
      if (pipe > 0) {
        final tail = text.substring(pipe + 1);
        final looksLikeHeaders = RegExp(
          r'(?:^|&)\s*(?:cookie|referer|user-agent|origin|authorization)\s*=',
          caseSensitive: false,
        ).hasMatch(tail);
        if (looksLikeHeaders) {
          text = text.substring(0, pipe).trim();
          for (final pair in tail.split('&')) {
            final eq = pair.indexOf('=');
            if (eq <= 0) continue;
            final k = pair.substring(0, eq).trim();
            final v = pair.substring(eq + 1).trim();
            if (RegExp(r'^[A-Za-z0-9-]+$').hasMatch(k) &&
                !v.contains('\r') &&
                !v.contains('\n')) {
              inline[k] = v;
            }
          }
        }
      }
      final atMatches = RegExp(
        r'@(?:Referer|User-Agent|Cookie|Origin|Authorization)=',
        caseSensitive: false,
      ).allMatches(text).toList();
      if (atMatches.isNotEmpty) {
        final prefix = text.substring(0, atMatches.first.start).trim();
        for (var i = 0; i < atMatches.length; i++) {
          final m = atMatches[i];
          final key = text.substring(m.start + 1, m.end - 1);
          final end = i + 1 < atMatches.length ? atMatches[i + 1].start : text.length;
          final val = text.substring(m.end, end).trim();
          if (!val.contains('\r') && !val.contains('\n')) {
            inline[key] = val;
          }
        }
        text = prefix;
      }
      if (sourceOrigin != null &&
          RegExp(
            r'^/(?:proxy(?:/|\?|$)|api/proxy(?:/|\?|$)|spider/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+/proxy(?:/|\?|$))',
          ).hasMatch(text)) {
        final safeRelative = Uri.tryParse(text) != null
            ? text
            : Uri.encodeFull(text).replaceAll('[', '%5B').replaceAll(']', '%5D');
        text = sourceOrigin.resolve(safeRelative).toString();
      }
      var uri = Uri.tryParse(text);
      if (uri == null) {
        final schemeEnd = text.indexOf('://');
        if (schemeEnd > 0) {
          final pathStart = text.indexOf('/', schemeEnd + 3);
          final encoded = pathStart > 0
              ? text.substring(0, pathStart) +
                  Uri.encodeFull(text.substring(pathStart))
                      .replaceAll('[', '%5B')
                      .replaceAll(']', '%5D')
              : Uri.encodeFull(text);
          uri = Uri.tryParse(encoded);
          if (uri != null) text = encoded;
        }
      }
      if (uri == null ||
          !const ['http', 'https', 'rtsp', 'rtmp', 'catpaw']
              .contains(uri.scheme) ||
          uri.host.isEmpty) {
        return null;
      }
      return (url: text, uri: uri, inlineHeaders: inline);
    }

    bool valid(dynamic value) => parseCandidate(value) != null;
    final extra = raw['extra'];
    final audio = extra is Map ? extra['audio'] : null;
    final parsedAudio = parseCandidate(audio);
    final audioUrl = parsedAudio != null
        ? (parsedAudio.url.startsWith('catpaw://')
            ? (await localUrl(parsedAudio.url)).toString()
            : parsedAudio.url)
        : '';
    Future<void> add(dynamic value,String name,Map<String,String> extra) async {
      if (value is String) {
        final trimmed = value.trim();
        if (trimmed.startsWith('[') || trimmed.startsWith('{')) {
          try {
            final decoded = jsonDecode(trimmed);
            if (decoded is List || decoded is Map) {
              await add(decoded, name, extra);
              return;
            }
          } catch (_) {}
        }
        final candidate = parseCandidate(trimmed);
        if (candidate != null) {
          final isCatPaw = candidate.url.startsWith('catpaw://');
          final url = isCatPaw ? await localUrl(candidate.url) : candidate.uri;
          if (seen.add(url.toString())) {
            choices.add(CmsEpisode(
              name: name,
              url: url.toString(),
              headers: _mergeHeaders([
                headersForOrigin(sourceHeaders, sourceOrigin, url),
                explicit,
                extra,
                candidate.inlineHeaders,
              ]),
              playbackSession: isCatPaw
                  ? {'catpawLogicalUrl': candidate.url}
                  : const {},
              externalAudioUrl: audioUrl,
            ));
          }
        }
      } else if (value is Map) {
        await add(value['url'] ?? value['urls'] ?? value['values'] ?? value['playUrl'],
            '${value['name'] ?? value['label'] ?? name}',{...extra,...headers(value['header'] ?? value['headers'])});
      } else if (value is List) {
        for (var i=0;i<value.length;i++) {
          if (value[i] is String && !valid(value[i]) && i+1<value.length && valid(value[i+1])) {
            await add(value[i+1],value[i].toString(),extra);i++;
          } else {await add(value[i],'画质 ${choices.length+1}',extra);}
        }
      }
    }
    await add(raw['url'] ?? raw['urls'],'默认画质',{});
    if (choices.isEmpty) throw const FormatException('来源没有返回可播放的媒体地址');
    return CmsEpisode(
      name: episode.name,
      url: choices.first.url,
      headers: choices.first.headers,
      playbackSession: choices.first.playbackSession,
      variants: choices,
      externalAudioUrl: audioUrl,
    );
  }
}
