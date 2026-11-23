import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:path_provider/path_provider.dart';
import 'cms_parser.dart';
import 'csp_bridge.dart';
import 'csp_rule_engines.dart';
import 'live_catalog_parser.dart';
import 'js_source_host.dart';
import 'python_source_assets.dart';
import 'python_source_host.dart';
import 'emby_library.dart';
import 'checksum_source.dart';
import 'catpaw_host.dart';
import 'drpy_source.dart';
import 'guard_source.dart';
import 'trailer_source.dart';
import 'wogg_source.dart';
import 'cloud_media_proxy.dart';
import 'cloud_share.dart';
import 'ali_share.dart';
import 'doh_resolver.dart';
import 'source_playback.dart';
import 'source_verification.dart';
import 'models.dart';
import 'quark_drive.dart';
import 'quark_account.dart';
import 'resilient_http_client.dart';
import 'spider_gateway.dart';
import 'spider_plugin_registry.dart';
import 'storage_service.dart';
import 'web_media_resolver.dart';

export 'doh_resolver.dart';

/// HTTP CMS client with TVBox `okhttp/3.15` User-Agent parity, system certificate validation for third-party
/// CMS hosts, multi-depot (`urls`/`storeHouse`) resolution, and bounded concurrent search.
class CmsClient {
  static const int maxResponseBytes = 16 * 1024 * 1024;
  static const int maxZipExpandedBytes = 6 * 1024 * 1024;
  static const int defaultSearchConcurrency = 6;
  static const String tvBoxUserAgent = 'okhttp/3.15';
  static const String safariUserAgent =
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.15';
  static final Object _cancelKey = Object();
  static final Object _lifetimeCancelKey = Object();

  /// Bind a screen-owned operation to its actual CMS/script requests. Leaving
  /// the screen stops the UI wait and cancels supported I/O; a late result is
  /// discarded even for a backend that cannot interrupt its current work.
  Future<T> runSourceOperation<T>(Future<T> Function() operation,
      {required Completer<void> cancellation}) async {
    if (cancellation.isCompleted) throw StateError('片源加载已取消');
    final parent = Zone.current[_cancelKey] as Completer<void>?;
    final parentLifetime = Zone.current[_lifetimeCancelKey] as bool Function()?;
    if (parent?.isCompleted == true || parentLifetime?.call() == true) throw StateError('片源加载已取消');
    final abort = Completer<void>();
    final interrupted = Completer<T>();
    void cancel() {
      if (!abort.isCompleted) abort.complete();
      if (!interrupted.isCompleted) interrupted.completeError(StateError('片源加载已取消'));
    }
    final listeners = <StreamSubscription<void>>[
      cancellation.future.asStream().listen((_) => cancel()),
      if (parent != null && !identical(parent, cancellation))
        parent.future.asStream().listen((_) => cancel()),
    ];
    try {
      // Register the error observer before beginning an operation which may
      // synchronously cancel itself or fail to create its backend.
      final work = Future<T>.sync(() => runZoned(operation,
          zoneValues: {_cancelKey: abort, _lifetimeCancelKey: () =>
              cancellation.isCompleted || parent?.isCompleted == true || parentLifetime?.call() == true}));
      final value = await Future.any([work, interrupted.future]);
      if (abort.isCompleted || cancellation.isCompleted || parent?.isCompleted == true || parentLifetime?.call() == true) {
        throw StateError('片源加载已取消');
      }
      return value;
    } finally {
      // Future-backed subscriptions stop delivering synchronously on cancel.
      // Their completion future may belong to another zone; it must not delay
      // a finished screen operation or its loading/error state update.
      for (final listener in listeners) { unawaited(listener.cancel()); }
    }
  }
  final http.Client? _http;
  final Duration timeout;
  final CatPawHost _scriptHost;
  final PythonSourceHost _pythonHost;
  final QuarkDriveClient? _quark;
  final Expando<Future<String>> _t4Extensions = Expando<Future<String>>();
  late final DrpySource _drpy = DrpySource(host: _scriptHost,
      read: (url, headers) => _getText(url, headers: headers));
  late final GuardSource _guard = GuardSource(host: _scriptHost, drpy: _drpy,
      read: _getPluginArtifactBytes);
  late final WoggSource _wogg = WoggSource(
      read: (url, headers) => _getText(url, headers: headers),
      readBytes: _getPluginArtifactBytes,
      listShare: _listCloudShare,
      listShareWithCancellation: (url, cancel) =>
          runSourceOperation(() => _listCloudShare(url), cancellation: cancel));

  Future<Uint8List> _getPluginArtifactBytes(
    String url,
    Map<String, String> headers,
  ) async {
    if (_http != null ||
        kIsWeb ||
        Platform.environment.containsKey('FLUTTER_TEST')) {
      return _getBytes(
        url,
        headers: headers,
        byteLimit: GuardSource.maxArtifactBytes,
      );
    }
    File? cacheFile;
    File? metaFile;
    try {
      final support = await getApplicationSupportDirectory();
      final dir = Directory('${support.path}/plugin_jar_cache');
      await dir.create(recursive: true);
      final sortedHeaders = headers.entries.toList()
        ..sort((a, b) => a.key.compareTo(b.key));
      final cacheKey = sha256
          .convert(
            utf8.encode(
              jsonEncode([
                url,
                [for (final e in sortedHeaders) [e.key, e.value]],
              ]),
            ),
          )
          .toString();
      cacheFile = File('${dir.path}/$cacheKey.jar');
      metaFile = File('${dir.path}/$cacheKey.json');
      if (await cacheFile.exists() && await metaFile.exists()) {
        final len = await cacheFile.length();
        if (len > 0 && len <= GuardSource.maxArtifactBytes) {
          final meta = jsonDecode(await metaFile.readAsString());
          if (meta is Map &&
              meta['sha256'] is String &&
              meta['ts'] is int &&
              DateTime.now().millisecondsSinceEpoch - (meta['ts'] as int) <=
                  24 * 3600 * 1000) {
            final diskBytes = await cacheFile.readAsBytes();
            if (sha256.convert(diskBytes).toString() == meta['sha256']) {
              return diskBytes;
            }
          }
        }
      }
    } catch (_) {
      cacheFile = null;
      metaFile = null;
    }
    try {
      final downloaded = await _getBytes(
        url,
        headers: headers,
        byteLimit: GuardSource.maxArtifactBytes,
      );
      final targetCacheFile = cacheFile;
      final targetMetaFile = metaFile;
      if (targetCacheFile != null &&
          targetMetaFile != null &&
          downloaded.isNotEmpty) {
        unawaited(() async {
          try {
            final tmp = File(
              '${targetCacheFile.path}.tmp-${DateTime.now().microsecondsSinceEpoch}',
            );
            await tmp.writeAsBytes(downloaded, flush: true);
            await tmp.rename(targetCacheFile.path);
            await targetMetaFile.writeAsString(
              jsonEncode({
                'sha256': sha256.convert(downloaded).toString(),
                'ts': DateTime.now().millisecondsSinceEpoch,
              }),
              flush: true,
            );
            final entries = await targetCacheFile.parent
                .list()
                .where((e) => e is File && e.path.endsWith('.jar'))
                .cast<File>()
                .toList();
            if (entries.length > 8) {
              final stats = <(File, DateTime)>[];
              for (final f in entries) {
                stats.add((f, (await f.stat()).modified));
              }
              stats.sort((a, b) => a.$2.compareTo(b.$2));
              for (final (old, _) in stats.take(stats.length - 8)) {
                try {
                  await old.delete();
                  final m = File(
                    '${old.path.substring(0, old.path.length - 4)}.json',
                  );
                  if (await m.exists()) await m.delete();
                } catch (_) {}
              }
            }
          } catch (_) {}
        }());
      }
      return downloaded;
    } catch (error) {
      if (cacheFile != null && metaFile != null) {
        try {
          if (await cacheFile.exists() && await metaFile.exists()) {
            final meta = jsonDecode(await metaFile.readAsString());
            final diskBytes = await cacheFile.readAsBytes();
            if (meta is Map &&
                diskBytes.isNotEmpty &&
                diskBytes.length <= GuardSource.maxArtifactBytes &&
                sha256.convert(diskBytes).toString() == meta['sha256']) {
              return diskBytes;
            }
          }
        } catch (_) {}
      }
      rethrow;
    }
  }

  bool Function() get _sourceCancelled {
    final abort = Zone.current[_cancelKey] as Completer<void>?;
    final lifetime = Zone.current[_lifetimeCancelKey] as bool Function()?;
    return () => abort?.isCompleted == true || lifetime?.call() == true;
  }

  static String cleanErrorMessage(Object error) {
    final raw = switch (error) {
      AliShareException e => e.message,
      QuarkDriveException e => e.message,
      QuarkAccountException e => e.message,
      FormatException e => e.message,
      _ => error.toString(),
    };
    final cleaned = raw
        .replaceFirst(
          RegExp(
            r'^(?:Bad state|FormatException|Exception|StateError|HttpException|SocketException|HandshakeException):\s*',
          ),
          '',
        )
        .trim();
    return cleaned.isEmpty ? error.toString().trim() : cleaned;
  }

  static String cloudPlaybackError(CmsEpisode episode, Object? error) {
    if (episode.cloudProvider == null) return '';
    final message = switch (error) {
      AliShareException e => e.message,
      QuarkDriveException e => e.message,
      QuarkAccountException e => e.message,
      FormatException e => e.message,
      _ => '',
    };
    if (message.isEmpty || message.length > 200 ||
        RegExp(r'https?://|BDUSS|STOKEN|__pu|cookie|authorization', caseSensitive: false).hasMatch(message)) return '';
    return message;
  }

  Future<String> _cloudCredential(String provider) async =>
      (await StorageService.init()).netdiskCredential(provider);

  Future<List<CmsEpisode>> _listCloudShare(String rawUrl) async {
    final url =
        ResilientHttpClient.normalizeCloudShareUrl(rawUrl) ?? rawUrl.trim();
    if (CloudShareClient.supportsShare(url)) {
      final cloud = CloudShareClient(client: _http, credentialReader: _cloudCredential, isCancelled: _sourceCancelled);
      try { return await cloud.listShare(url); } finally { cloud.close(); }
    }
    if (AliShareClient.supportsShare(url)) {
      final cloud = AliShareClient(client: _http, credentialReader: _cloudCredential, isCancelled: _sourceCancelled,
          credentialWriter: (provider, value) async =>
              (await StorageService.init()).setNetdiskCredential(provider, value));
      try { return await cloud.listShare(url); } finally { cloud.close(); }
    }
    final uri = Uri.tryParse(url);
    if (uri?.host.toLowerCase() == 'pan.quark.cn' &&
        const {'http', 'https'}.contains(uri?.scheme) && uri!.userInfo.isEmpty) {
      return QuarkDriveClient.listPublicShareEpisodes(url, httpClient: _http, isCancelled: _sourceCancelled);
    }
    throw const FormatException('此分享的网盘暂不支持');
  }

  CmsClient({
    http.Client? client,
    CatPawHost? scriptHost,
    PythonSourceHost? pythonHost,
    QuarkDriveClient? quark,
    this.timeout = const Duration(seconds: 15),
  }) : _http = client, _quark = quark, _scriptHost = scriptHost ?? CatPawHost.instance,
       _pythonHost = pythonHost ?? PythonSourceHost.instance;
  static http.Client? _sharedDefaultClient;
  static http.Client? _sharedDirectClient;
  static http.Client _createDefaultClient({bool directOnly = false}) {
    final ioHttp = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8)
      ..idleTimeout = const Duration(seconds: 20)
      ..maxConnectionsPerHost = 6;
    if (directOnly) {
      ioHttp.findProxy = (_) => 'DIRECT';
    }
    if (HttpOverrides.current == null) {
      ioHttp.connectionFactory = CmsDohResolver.shared.connect;
    }
    return IOClient(ioHttp);
  }
  static ({http.Client client, bool ephemeral}) _acquireDefaultTransport({
    required bool directOnly,
  }) {
    if (HttpOverrides.current != null) {
      return (client: _createDefaultClient(directOnly: directOnly), ephemeral: true);
    }
    final pooled = directOnly
        ? (_sharedDirectClient ??= _createDefaultClient(directOnly: true))
        : (_sharedDefaultClient ??= _createDefaultClient(directOnly: false));
    return (client: pooled, ephemeral: false);
  }

  /// Detects when an iOS/desktop system HTTP proxy points to a dead local tunnel
  /// (`127.0.0.1` / `::1` `Connection refused`) while dialing a non-loopback host.
  static bool isDeadLocalSystemProxyError(Uri targetUri, Object error) {
    if (LiveCatalogParser.isLoopbackHost(targetUri.host)) return false;
    if (error is SocketException) {
      final host = error.address?.host ?? '';
      if (error.address?.isLoopback == true ||
          LiveCatalogParser.isLoopbackHost(host)) {
        return true;
      }
    }
    if (error is http.ClientException || error is SocketException) {
      final msg = error.toString();
      final hitsLoopback = msg.contains('address = 127.0.0.1') ||
          msg.contains('address = ::1') ||
          msg.contains('address = localhost');
      final refused = msg.contains('Connection refused') ||
          msg.contains('errno = 61') ||
          msg.contains('errno = 111') ||
          msg.contains('errno = 10061');
      return hitsLoopback && refused;
    }
    return false;
  }
  Map<String, String> _buildHeaders(
    Map<String, String> custom, {
    String defaultUa = tvBoxUserAgent,
  }) {
    final headers = <String, String>{
      'User-Agent': defaultUa,
      'Accept': 'application/json, text/plain, */*',
    };
    custom.forEach((k, v) {
      if (k.toLowerCase() == 'user-agent') {
        headers['User-Agent'] = v;
      } else {
        headers[k] = v;
      }
    });
    return headers;
  }
  Future<Uint8List> _getBytes(
    String url, {
    Map<String, String> headers = const {},
    Duration? requestTimeout,
    String defaultUa = tvBoxUserAgent,
    int byteLimit = maxResponseBytes,
    Map<String, String>? form,
    void Function(Uri, Map<String, String>)? onResponse,
  }) async {
    final normalized = CmsParser.normalizeUrl(url);
    final uri = Uri.parse(normalized);
    var usedDirectFallback = LiveCatalogParser.isLoopbackHost(uri.host);
    var ephemeralTransport = false;
    late http.Client transport;
    if (_http != null) {
      transport = _http;
    } else {
      final acquired = _acquireDefaultTransport(directOnly: usedDirectFallback);
      transport = acquired.client;
      ephemeralTransport = acquired.ephemeral;
    }
    final abort = Completer<void>();
    void cancel() {
      if (!abort.isCompleted) abort.complete();
      if (ephemeralTransport) transport.close();
    }
    final sessionAbort = Zone.current[_cancelKey] as Completer<void>?;
    if (sessionAbort?.isCompleted == true) {
      cancel();
      throw http.RequestAbortedException(uri);
    }
    sessionAbort?.future.then((_) => cancel());
    final deadline = Timer(requestTimeout ?? timeout, cancel);
    try {
      final requestHeaders = _buildHeaders(headers, defaultUa: defaultUa);
      if (uri.userInfo.isNotEmpty &&
          !requestHeaders.keys.any((name) => name.toLowerCase() == 'authorization')) {
        requestHeaders['Authorization'] = 'Basic ${base64Encode(utf8.encode(Uri.decodeComponent(uri.userInfo)))}';
      }
      var current = uri.replace(userInfo: '').removeFragment();
      var requestForm = form;
      http.AbortableRequest buildRequest() {
        final req = http.AbortableRequest(
          requestForm == null ? 'GET' : 'POST',
          current,
          abortTrigger: abort.future,
        )
          ..followRedirects = false
          ..headers.addAll(requestHeaders);
        if (requestForm != null) {
          req.headers.removeWhere((key, _) => const [
                'content-type',
                'content-length',
                'transfer-encoding',
              ].contains(key.toLowerCase()));
          req.bodyFields = requestForm;
        }
        return req;
      }

      final redirectCookies = <String,
          ({String name, String value, String domain, bool hostOnly, String path})>{};
      void mergeRedirectCookiesIntoHeaders(Uri target) {
        final matched = redirectCookies.values
            .where((c) => WebMediaResolver.redirectCookieMatches(c, target))
            .toList();
        if (matched.isEmpty) return;
        final combined = <String, String>{};
        String? existingKey;
        for (final entry in requestHeaders.entries) {
          if (entry.key.toLowerCase() == 'cookie') {
            existingKey = entry.key;
            for (final pair in entry.value.split(';')) {
              final trimmed = pair.trim();
              final eq = trimmed.indexOf('=');
              if (eq > 0) {
                combined[trimmed.substring(0, eq).trim()] =
                    trimmed.substring(eq + 1).trim();
              }
            }
          }
        }
        for (final c in matched) {
          combined[c.name] = c.value;
        }
        if (existingKey != null && existingKey != 'Cookie') {
          requestHeaders.remove(existingKey);
        }
        requestHeaders['Cookie'] =
            combined.entries.map((e) => '${e.key}=${e.value}').join('; ');
      }

      late http.StreamedResponse response;
      for (var redirects = 0; ; redirects++) {
        try {
          response = await transport.send(buildRequest());
        } catch (error) {
          if (_http == null &&
              !usedDirectFallback &&
              !abort.isCompleted &&
              isDeadLocalSystemProxyError(current, error)) {
            if (ephemeralTransport) transport.close();
            usedDirectFallback = true;
            final acquired = _acquireDefaultTransport(directOnly: true);
            transport = acquired.client;
            ephemeralTransport = acquired.ephemeral;
            response = await transport.send(buildRequest());
          } else {
            rethrow;
          }
        }
        for (final c in WebMediaResolver.parseRedirectSetCookies(
            response.headers, current)) {
          redirectCookies['${c.domain}|${c.hostOnly}|${c.path}|${c.name}'] = c;
        }
        final location = response.headers['location'];
        if (![301, 302, 303, 307, 308].contains(response.statusCode) || location == null) break;
        await response.stream.listen(null).cancel();
        if (redirects >= 5) throw const FormatException('来源跳转次数过多');
        final next = Uri.parse(CmsParser.normalizeUrl(current.resolve(location).toString())).removeFragment();
        if (!['http', 'https'].contains(next.scheme) || next.host.isEmpty || next.userInfo.isNotEmpty) {
          throw const FormatException('来源返回了不支持的跳转地址');
        }
        if (current.scheme != next.scheme || current.host != next.host || current.port != next.port) {
          requestHeaders.removeWhere((name, _) => const [
            'authorization', 'proxy-authorization', 'cookie', 'cookie2',
          ].contains(name.toLowerCase()));
        }
        mergeRedirectCookiesIntoHeaders(next);
        current = next;
        if ([301, 302, 303].contains(response.statusCode)) requestForm = null;
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException('HTTP ${response.statusCode}');
      }
      mergeRedirectCookiesIntoHeaders(current);
      if ((response.contentLength ?? 0) > byteLimit) {
        throw FormatException('响应体超过大小上限（${byteLimit ~/ (1024 * 1024)} MB）');
      }
      final data = BytesBuilder(copy: false);
      await for (final bytes in response.stream) {
        if (data.length + bytes.length > byteLimit) {
          throw FormatException('响应体超过大小上限（${byteLimit ~/ (1024 * 1024)} MB）');
        }
        data.add(bytes);
      }
      onResponse?.call(current, Map<String, String>.of(requestHeaders));
      return data.takeBytes();
    } finally {
      deadline.cancel();
      cancel();
    }
  }

  Future<String> _getText(
    String url, {
    Map<String, String> headers = const {},
    Duration? requestTimeout,
    Map<String, String>? form,
  }) async {
    if (CatPawHost.matches(url)) return CatPawHost.instance.read(url);
    final bytes = await _getBytes(
      url,
      headers: headers,
      requestTimeout: requestTimeout,
      defaultUa: tvBoxUserAgent,
      form: form,
    );
    return CmsParser.decodeTextDocument(bytes);
  }
  Uri _appendQuery(
    String baseUrl,
    Map<String, String> params, {
    String ext = '',
  }) {
    final normalized = CmsParser.normalizeUrl(baseUrl);
    final base = Uri.parse(normalized);
    final merged = <String, String>{...base.queryParameters};
    if (ext.isNotEmpty && !merged.containsKey('extend')) {
      merged['extend'] = ext;
    }
    merged.addAll(params);
    return base.replace(queryParameters: merged);
  }
  bool _isHttpT4(CmsSite site) => site.type == 4 && site.isHttpApi;

  Future<String> _t4Extension(CmsSite site) async {
    final existing = _t4Extensions[site];
    if (existing != null) return existing;
    Future<String> load() async {
      final value = site.ext.trim();
      final uri = Uri.tryParse(value);
      if (uri == null || !['http', 'https'].contains(uri.scheme) || uri.host.isEmpty) return value;
      final api = Uri.parse(site.api);
      final same = api.scheme == uri.scheme && api.host == uri.host && api.port == uri.port;
      final headers = Map<String, String>.of(site.headers);
      if (!same) headers.removeWhere((key, _) => const [
        'authorization', 'proxy-authorization', 'cookie', 'cookie2',
      ].contains(key.toLowerCase()));
      return (await _getText(value, headers: headers)).trim();
    }
    final pending = load();
    _t4Extensions[site] = pending;
    try { return await pending; }
    catch (_) { if (identical(_t4Extensions[site], pending)) _t4Extensions[site] = null; rethrow; }
  }

  Future<String> _callT4(CmsSite site, Map<String, String> params) async {
    final extension = await _t4Extension(site);
    final values = {...params, if (extension.isNotEmpty) 'extend': extension};
    final raw = await _getText(extension.length > 1000 ? site.api : _appendQuery(site.api, values).toString(),
      headers: site.headers, form: extension.length > 1000 ? values : null);
    if (jsonDecode(raw) is! Map) throw const FormatException('T4 来源没有返回有效的数据');
    return raw;
  }
  static String _archivePath(String name) {
    final path = name.replaceAll('\\', '/');
    if (path.startsWith('/') || path.contains(':') ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(path) || path.split('/').contains('..')) {
      throw const FormatException('ZIP 路径无效');
    }
    final normalized = path.split('/').where((part) => part.isNotEmpty && part != '.').join('/');
    if (normalized.isEmpty) throw const FormatException('ZIP 路径无效');
    return normalized;
  }

  static Map<String, Object> _pythonPackageData(Map<String, ArchiveFile> files, String entry) {
    if (files.length > 256) throw const FormatException('Python 本地包文件数量超过 256');
    final data = <String, String>{};
    var total = 0;
    for (final item in files.entries) {
      if (item.key.contains("'") || item.key.contains('"')) {
        throw const FormatException('Python 本地包路径不能包含引号');
      }
      if (item.value.size > 2 * 1024 * 1024) {
        throw const FormatException('Python 本地包单个文件超过 2 MB');
      }
      total += item.value.size;
      if (total > maxZipExpandedBytes) throw const FormatException('Python 本地包内容超过 6 MB');
      data[item.key] = base64Encode(item.value.content);
    }
    return {'entry': entry, 'files': data};
  }

  static String readSubscriptionFile(List<int> bytes, String name) {
    if (bytes.length > maxResponseBytes) throw const FormatException('订阅文件超过 16 MB');
    if (bytes.length >= 4 && bytes[0] == 0x50 && bytes[1] == 0x4b && bytes[2] == 3 && bytes[3] == 4) {
      final archive = ZipDecoder().decodeBytes(bytes);
      if (archive.files.length > 2048) throw const FormatException('ZIP 文件数量超过限制');
      final files = <String, ArchiveFile>{};
      var unpackedSize = 0;
      for (final item in archive.files.where((f) => f.isFile)) {
        // Check before any .content access: archive entries decompress lazily.
        unpackedSize += item.size;
        if (item.size < 0 || unpackedSize > maxZipExpandedBytes) {
          throw const FormatException('ZIP 解压后的内容超过 6 MB');
        }
        final path = _archivePath(item.name);
        if (files.containsKey(path)) {
          throw const FormatException('ZIP 路径无效或重复');
        }
        files[path] = item;
      }
      final configs = files.values.where((f) {
        if (!f.name.toLowerCase().endsWith('.json')) return false;
        if (f.size > maxZipExpandedBytes) return false;
        try {
          final doc = jsonDecode(CmsParser.stripJsonComments(CmsParser.decodeConfigDocument(f.content)));
          bool site(dynamic value) => value is Map && value['api'] is String &&
              (value['name'] != null || value['key'] != null);
          bool records(dynamic value, String field) => value is List &&
              value.any((entry) => entry is Map && entry.containsKey(field));
          return doc is List ? doc.any(site) : doc is Map &&
              (site(doc) || ['sites','lives','urls','depots','storeHouse'].any(doc.containsKey) ||
               records(doc['list'], 'vod_id') || records(doc['class'], 'type_id') ||
               doc['code'] != null && (doc['list'] is List || doc['class'] is List));
        } on FormatException { return false; }
      }).toList();
      int rank(ArchiveFile f) {
        const names = ['config.json', 'tv.json', 'api.json', 'index.json', 'main.json'];
        final i = names.indexOf(f.name.toLowerCase().replaceAll('\\', '/').split('/').last);
        return i < 0 ? names.length : i;
      }
      configs.sort((a, b) => rank(a).compareTo(rank(b)));
      final playlists = files.values.where((f) => RegExp(r'\.(m3u8?|txt)$', caseSensitive: false).hasMatch(f.name) &&
          f.size <= maxZipExpandedBytes && CmsParser.parseLivePlaylist(CmsParser.decodeTextDocument(f.content)).isNotEmpty).toList();
      if (configs.isEmpty && playlists.length == 1) {
        final file = playlists.single;
        if (file.size > maxZipExpandedBytes) throw const FormatException('ZIP 中的播放列表过大');
        final text = CmsParser.decodeTextDocument(file.content);
        if (CmsParser.parseLivePlaylist(text).isEmpty) throw const FormatException('播放列表没有可用频道');
        // Keep the playlist inline even after refreshing a remote ZIP subscription.
        return jsonEncode({'sites': [{'name': '播放列表', 'key': 'playlist', 'type': 1,
          'api': 'm3u_vod://playlist', 'ext': text}], 'lives': [{'name':'播放列表',
          'url': Uri.dataFromString(text, mimeType:'text/plain', encoding:utf8, base64:true).toString()}]});
      }
      if (configs.isEmpty) {
        final scripts = files.entries.where((e) => RegExp(r'\.(?:m?js|py)$', caseSensitive: false).hasMatch(e.key)).toList();
        final preferred = scripts.where((e) => RegExp(r'^(?:main|index|spider)\.(?:m?js|py)$', caseSensitive: false).hasMatch(e.key.split('/').last)).toList();
        final entry = scripts.length == 1 ? scripts.single : preferred.length == 1 ? preferred.single : null;
        if (entry == null || scripts.length > 32) {
          throw const FormatException('ZIP 需要明确的配置、播放列表或唯一的 main/index/spider 脚本入口');
        }
        final modules = <String, String>{};
        var size = 0;
        final python = entry.key.toLowerCase().endsWith('.py');
        final resources = files.entries.where((e) => RegExp(python ? r'\.py$' : r'\.(?:m?js|py|json)$', caseSensitive: false).hasMatch(e.key));
        for (final script in resources) {
          if (modules.length >= 32) throw const FormatException('ZIP 模块数量超过限制');
          size += script.value.size;
          if (size > maxZipExpandedBytes) throw const FormatException('ZIP 脚本总大小超过 6 MB');
          modules[Uri(scheme: 'pkg', host: 'archive', path: '/${script.key}').toString()] = CmsParser.decodeTextDocument(script.value.content);
        }
        final origin = Uri(scheme: 'pkg', host: 'archive', path: '/${entry.key}').toString();
        final source = modules.remove(origin)!;
        if (!python && !CmsParser.isExecutableJs(source) && !CmsParser.looksLikeDrpyRule(source)) {
          throw const FormatException('ZIP 脚本需要兼容的 Spider 接口，当前不支持此规则宿主');
        }
        final result = jsonEncode({'sites': [{'key': 'local_script', 'name': '本地脚本', 'type': 3,
          'api': python ? 'csp_LocalScript.py' : CmsParser.looksLikeDrpyRule(source) ? 'csp_LocalRule.js' : 'csp_LocalScript.js',
          'ext': {'script': source, 'origin': origin, 'modules': modules,
            if (python) 'package': _pythonPackageData(files, entry.key)}}]});
        if (utf8.encode(result).length > maxZipExpandedBytes) throw const FormatException('展开的订阅超过 6 MB');
        return result;
      }
      if (configs.length > 1 && rank(configs.first) == rank(configs[1])) {
        throw const FormatException('ZIP 需要一个明确的订阅入口，例如 config.json');
      }
      final file = configs.first;
      if (file.size > maxZipExpandedBytes) throw const FormatException('ZIP 中的配置过大');
      var decoded = CmsParser.decodeConfigDocument(file.content);
      var doc = jsonDecode(CmsParser.stripJsonComments(decoded));
      if (doc is List) doc = <String, dynamic>{'sites': doc};
      if (doc is Map && doc['sites'] == null && doc['api'] != null &&
          (doc['name'] != null || doc['key'] != null)) {
        doc = <String, dynamic>{'sites': [doc]};
      }
      if (doc is Map) {
        final entryPath = _archivePath(file.name);
        final base = Uri(scheme: 'pkg', host: 'archive', path: '/$entryPath');
        var total = file.size;
        final liveEntries = doc['lives'];
        final sites = <dynamic>[
          if (doc['sites'] is List) ...doc['sites'] as List,
          if (liveEntries is List) ...liveEntries
          else if (liveEntries is Map) liveEntries,
        ];
        if (sites.isNotEmpty) {
          final scripts = <String, String>{};
          final scriptFile = RegExp(r'\.(?:m?js|py)$', caseSensitive: false);
          var expanded = file.size;
          for (final site in sites.whereType<Map>()) {
            final explicitRule = (site['api'] ?? '').toString().toLowerCase() == 'csp_drpy';
            final reference = explicitRule && site['ext'] is String ? site['ext'] : site['api'];
            final ref = Uri.tryParse((reference ?? '').toString());
            if (ref == null || ref.hasScheme || !scriptFile.hasMatch(ref.path)) continue;
            if (ref.hasAuthority || ref.path.startsWith('/')) throw const FormatException('ZIP 脚本路径无效');
            if (scripts.isEmpty) {
              for (final f in files.entries.where((e) => e.key != entryPath &&
                  (scriptFile.hasMatch(e.key) || e.key.toLowerCase().endsWith('.json')))) {
                if (scripts.length >= 32 || f.value.size > maxZipExpandedBytes - total) {
                  throw const FormatException('ZIP 脚本数量或总大小超过限制');
                }
                total += f.value.size;
                scripts[Uri(scheme: 'pkg', host: 'archive', path: '/${f.key}').toString()] = CmsParser.decodeTextDocument(f.value.content);
              }
            }
            final origin = base.resolveUri(ref).toString();
            final source = scripts[origin];
            if (source == null) throw const FormatException('ZIP 中缺少入口脚本');
            expanded += total - file.size;
            if (expanded > maxZipExpandedBytes) throw const FormatException('展开的订阅超过 6 MB');
            site['api'] = ref.path.toLowerCase().endsWith('.py') ? 'csp_LocalScript.py' : CmsParser.looksLikeDrpyRule(source) ? 'csp_LocalRule.js' : 'csp_LocalScript.js';
            site['ext'] = {'script': source, 'origin': origin,
              'modules': Map.of(scripts)..remove(origin), 'ext': explicitRule ? '' : site['ext'] ?? '',
              if (site['api'] == 'csp_LocalScript.py')
                'package': _pythonPackageData(files, base.resolveUri(ref).pathSegments.join('/'))};
          }
        }
        final lives = doc['lives'];
        for (final live in (lives is List ? lives : lives is Map ? [lives] : const []).whereType<Map>()) {
          // A script owns its opaque argument; it is not an archive filename.
          if ((live['api'] ?? '').toString().isNotEmpty) continue;
          final url = live['url'];
          if (url is! String || url.isEmpty || Uri.parse(url).hasScheme) continue;
          final ref = Uri.parse(url);
          if (ref.hasAuthority || ref.path.startsWith('/')) throw const FormatException('ZIP 播放列表路径无效');
          final target = files[base.resolveUri(ref).pathSegments.join('/')];
          if (target == null || target.size > maxZipExpandedBytes - total) {
            throw const FormatException('ZIP 内的播放列表不存在或过大');
          }
          total += target.size;
          final text = CmsParser.decodeTextDocument(target.content);
          if (CmsParser.parseLivePlaylist(text).isEmpty) throw const FormatException('ZIP 播放列表没有可用频道');
          live['url'] = Uri.dataFromString(text, mimeType: 'text/plain', encoding: utf8, base64: true).toString();
        }
        decoded = jsonEncode(doc);
        if (utf8.encode(decoded).length > maxZipExpandedBytes) throw const FormatException('展开的订阅超过 6 MB');
      }
      final config = CmsParser.parseConfig(decoded);
      if (config.sites.any((s) => !s.isHttpApi && !s.isM3uVodApi && !s.api.startsWith('csp_')) ||
          config.lives.any((s) => s.plugin == null && s.inlineContent.isEmpty &&
              !s.url.startsWith('http') && !s.url.startsWith('data:'))) {
        throw const FormatException('本地包包含相对路径的资源，当前客户端需要可访问的完整接口地址');
      }
      return decoded;
    }
    return CmsParser.decodeConfigDocument(bytes);
  }

  /// Fetches and unpacks a remote TVBox / Marco Movie config (supporting `okhttp/3.15` UA,
  /// Safari UA fallback, `**`+Base64 steganography, `$#...#$` AES-128-CBC, and Base64).
  Future<String> fetchRawConfig(String url) async {
    final normalized = CmsParser.extractAndNormalizeUrl(url);
    if (normalized.isEmpty) {
      throw const FormatException('请输入有效的 HTTP(S) 配置地址');
    }
    Exception? firstError;
    for (final ua in [tvBoxUserAgent, safariUserAgent]) {
      try {
        final bytes = await _getBytes(normalized, defaultUa: ua);
        final unpacked = readSubscriptionFile(bytes, normalized);
        final trimmed = unpacked.trimLeft();
        if (trimmed.startsWith('<!DOCTYPE') ||
            trimmed.toLowerCase().startsWith('<html')) {
          firstError = const FormatException('服务器返回了网页而非 JSON 配置');
          continue;
        }
        return unpacked;
      } catch (e) {
        firstError = e is Exception ? e : Exception(e.toString());
      }
    }
    throw firstError ?? Exception('无法连接配置地址');
  }
  /// Resolves either a remote URL, multi-depot URL, or pasted JSON/Base64/M3U/VOD config into
  /// a ready-to-use `(rawConfig, origin, activeDepotUrl, parsedConfig)` tuple.
  Future<({
    String rawConfig,
    String origin,
    String activeDepotName,
    List<CmsDepot> depots,
    CmsConfig config,
  })> resolveConfigInput({
    String urlInput = '',
    String rawTextInput = '',
    String defaultGroup = '默认分组',
    bool isPrivate = false,
    String subscriptionId = '',
    String defaultName = '',
  }) async {
    var trimmedText = rawTextInput.trim();
    var trimmedUrl = urlInput.trim();
    // If user pasted JSON/M3U/XML into the URL field or a URL into the JSON field, handle gracefully
    if (trimmedText.isEmpty && CmsParser.looksLikeScript(trimmedUrl)) {
      trimmedText = trimmedUrl;
      trimmedUrl = '';
    }
    final strippedUrl = CmsParser.stripJsonComments(trimmedUrl);
    final strippedText = CmsParser.stripJsonComments(trimmedText);
    if (trimmedText.isEmpty &&
        (trimmedUrl.startsWith('{') ||
            trimmedUrl.startsWith('[') ||
            strippedUrl.startsWith('{') ||
            strippedUrl.startsWith('[') ||
            trimmedUrl.startsWith('<') ||
            trimmedUrl.startsWith('#EXTM3U') ||
            trimmedUrl.contains('#EXTINF') ||
            trimmedUrl.contains(',#genre#'))) {
      trimmedText = trimmedUrl;
      trimmedUrl = '';
    } else if (trimmedUrl.isEmpty &&
        !CmsParser.looksLikeScript(trimmedText) &&
        !trimmedText.startsWith('{') &&
        !trimmedText.startsWith('[') &&
        !strippedText.startsWith('{') &&
        !strippedText.startsWith('[') &&
        !trimmedText.startsWith('<') &&
        !trimmedText.startsWith('#EXTM3U') &&
        !trimmedText.contains('#EXTINF') &&
        !trimmedText.contains(',#genre#') &&
        CmsParser.parseLivePlaylist(trimmedText).isEmpty &&
        (trimmedText.contains('http://') ||
            trimmedText.contains('https://') ||
            (trimmedText.contains('.') && !trimmedText.contains('\n')))) {
      trimmedUrl = trimmedText;
      trimmedText = '';
    }
    String origin = '';
    String rawConfig = '';
    if (trimmedText.isNotEmpty) {
      rawConfig = CmsParser.unpackConfigText(trimmedText);
      origin = CmsParser.extractAndNormalizeUrl(trimmedUrl);
    } else {
      origin = CmsParser.extractAndNormalizeUrl(trimmedUrl);
      if (origin.isEmpty) {
        throw const FormatException('请输入配置地址 (HTTP/HTTPS) 或粘贴配置内容');
      }
      final link = Uri.tryParse(origin);
      if (ChecksumSource.matches(link)) {
        final verified = await ChecksumSource.read(link!);
        if (CatPawHost.isBundle(verified.source)) {
          rawConfig = await CatPawHost.instance.install(verified.source);
        } else {
        if (!CmsParser.looksLikeScript(verified.source)) throw const FormatException('已校验的文件没有兼容的来源入口');
        // Keep only the verified body and credential-free module base in the subscription.
        final executable = CmsParser.isExecutableJs(verified.source);
        rawConfig = jsonEncode({'sites':[{'key':'verified_script','name': defaultName.isEmpty ? verified.script.host : defaultName,
          'type':3,'api':executable ? 'csp_LocalScript.js' : 'csp_LocalRule.js',
          'ext':{'script':verified.source,'origin':verified.script.toString()}}]});
        }
        origin = link.userInfo.isEmpty ? link.toString() : '';
      } else {
        rawConfig = await fetchRawConfig(origin);
      }
    }
    final initial = CmsParser.parseConfig(
      rawConfig,
      origin: origin,
      defaultGroup: defaultGroup,
      isPrivate: isPrivate,
      subscriptionId: subscriptionId,
      defaultName: defaultName,
    );
    if (!initial.isMultiDepotOnly) {
      return (
        rawConfig: rawConfig,
        origin: origin,
        activeDepotName: '',
        depots: initial.depots,
        config: initial,
      );
    }
    // Traverse nested catalogs with a shared cycle/size budget. Keep every discovered
    // branch so switching and restarting do not discard the warehouse directory.
    final visited = <String>{origin};
    final discovered = <String, CmsDepot>{};
    var requests = 0;
    final deadline = DateTime.now().add(const Duration(seconds: 60));
    Future<({String raw, String origin, String name, CmsConfig config})> visit(
        CmsConfig catalog, int depth, String parent) async {
      if (depth >= 6) throw const FormatException('多仓嵌套超过 6 层');
      for (final d in catalog.depots) {
        discovered.putIfAbsent(d.url, () => CmsDepot(
          name: parent.isEmpty ? d.name : '$parent / ${d.name}',
          url: d.url, subscriptionId: subscriptionId));
      }
      Object? lastError;
      for (final depot in catalog.depots) {
        if (requests >= 32 || DateTime.now().isAfter(deadline)) break;
        if (!visited.add(depot.url)) continue;
        requests++;
        try {
          final remaining = deadline.difference(DateTime.now());
          final raw = await fetchRawConfig(depot.url).timeout(remaining);
          final parsed = CmsParser.parseConfig(raw, origin: depot.url,
            defaultGroup: defaultGroup, isPrivate: isPrivate,
            subscriptionId: subscriptionId,
            defaultName: defaultName.isEmpty ? depot.name : defaultName);
          if (parsed.isMultiDepotOnly) {
            return await visit(parsed, depth + 1, discovered[depot.url]!.name);
          }
          return (raw: raw, origin: depot.url, name: discovered[depot.url]!.name, config: parsed);
        } catch (e) { lastError = e; }
      }
      throw FormatException(lastError == null
        ? '多仓没有可读取的子仓库，或存在循环引用'
        : '子仓库读取失败，请稍后重试（${lastError.runtimeType}）');
    }
    final leaf = await visit(initial, 0, '');
    final depots = discovered.values.toList();
    return (rawConfig: leaf.raw, origin: leaf.origin, activeDepotName: leaf.name,
      depots: depots, config: CmsConfig(sites: leaf.config.sites,
        lives: leaf.config.lives, depots: depots, parses: leaf.config.parses,
        spider: leaf.config.spider));
  }

  Future<SubscriptionEntry> switchSubscriptionDepot(SubscriptionEntry owner, CmsDepot depot) async {
    final resolved = await resolveConfigInput(urlInput: depot.url,
      defaultGroup: owner.group, isPrivate: owner.isEffectivelyPrivate,
      subscriptionId: owner.id);
    final entries = <String, CmsDepot>{for (final d in owner.depots) d.url: d};
    for (final d in resolved.depots) { entries[d.url] = d; }
    return owner.copyWith(url: resolved.origin, rawContent: resolved.rawConfig,
      activeDepotName: resolved.activeDepotName.isEmpty ? depot.name : resolved.activeDepotName,
      depots: entries.values.toList(), siteCount: resolved.config.supportedSites.length,
      liveCount: resolved.config.lives.length, updatedAt: DateTime.now().millisecondsSinceEpoch);
  }

  /// Resolves one or multiple subscription URLs / raw content into [SubscriptionEntry] items.
  Future<List<SubscriptionEntry>> resolveBatchSubscriptions({
    String urlInput = '',
    String rawTextInput = '',
    String defaultGroup = '默认分组',
    bool isPrivate = false,
    String customName = '',
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final groupLabel =
        defaultGroup.trim().isEmpty ? '默认分组' : defaultGroup.trim();
    final batchLines = CmsParser.splitBatchSubscriptionUrls(
      urlInput.trim().isNotEmpty ? urlInput : rawTextInput,
      defaultGroup: groupLabel,
    );

    if (batchLines.length > 1) {
      final results = <SubscriptionEntry>[];
      Exception? lastErr;
      for (int i = 0; i < batchLines.length; i++) {
        final item = batchLines[i];
        final subId = 'sub_${now}_$i';
        try {
          final resolved = await resolveConfigInput(
            urlInput: item.url,
            defaultGroup: item.group,
            isPrivate: isPrivate,
            subscriptionId: subId,
            defaultName: item.name,
          );
          final fmt = CmsParser.detectSubscriptionFormat(
            resolved.rawConfig,
            origin: item.url,
          );
          final effectiveName = item.name.isNotEmpty
              ? item.name
              : (resolved.activeDepotName.isNotEmpty
                  ? resolved.activeDepotName
                  : (resolved.config.sites.length == 1
                      ? resolved.config.sites.first.name
                      : '订阅源 ${i + 1}'));
          results.add(
            SubscriptionEntry(
              id: subId,
              name: effectiveName,
              url: resolved.origin,
              warehouseUrl: resolved.depots.isEmpty ? '' : item.url,
              activeDepotName: resolved.activeDepotName,
              depots: resolved.depots,
              group: item.group,
              format: resolved.depots.isNotEmpty ? '多仓' : fmt,
              isPrivate: isPrivate,
              enabled: true,
              rawContent: resolved.rawConfig,
              siteCount: resolved.config.supportedSites.length,
              liveCount: resolved.config.lives.length,
              updatedAt: now + i,
            ),
          );
        } catch (e) {
          lastErr = e is Exception ? e : Exception(e.toString());
        }
      }
      if (results.isEmpty) {
        throw lastErr ?? const FormatException('未能成功导入任何订阅地址');
      }
      return results;
    }

    // Single subscription (either URL or pasted content)
    final singleLine = batchLines.length == 1 ? batchLines.first : null;
    final subId = 'sub_$now';
    final effectiveGroup = singleLine?.group ?? groupLabel;
    final effectiveHintName = customName.trim().isNotEmpty
        ? customName.trim()
        : (singleLine?.name ?? '');
    final resolved = await resolveConfigInput(
      urlInput: singleLine != null ? singleLine.url : urlInput,
      rawTextInput: singleLine != null ? '' : rawTextInput,
      defaultGroup: effectiveGroup,
      isPrivate: isPrivate,
      subscriptionId: subId,
      defaultName: effectiveHintName,
    );
    final fmt = CmsParser.detectSubscriptionFormat(
      resolved.rawConfig,
      origin: resolved.origin,
    );
    final displayName = effectiveHintName.isNotEmpty
        ? effectiveHintName
        : (resolved.activeDepotName.isNotEmpty
            ? resolved.activeDepotName
            : (resolved.config.sites.length == 1
                ? resolved.config.sites.first.name
                : (resolved.origin.isNotEmpty
                    ? Uri.tryParse(resolved.origin)?.host ?? '订阅资源'
                    : '$fmt 订阅')));
    return [
      SubscriptionEntry(
        id: subId,
        name: displayName,
        url: resolved.origin,
        warehouseUrl: resolved.depots.isEmpty ? '' : CmsParser.extractAndNormalizeUrl(singleLine?.url ?? urlInput),
        activeDepotName: resolved.activeDepotName,
        depots: resolved.depots,
        group: effectiveGroup,
        format: resolved.depots.isNotEmpty ? '多仓' : fmt,
        isPrivate: isPrivate,
        enabled: true,
        rawContent: resolved.rawConfig,
        siteCount: resolved.config.supportedSites.length,
        liveCount: resolved.config.lives.length,
        updatedAt: now,
      ),
    ];
  }

  Future<String> _resolveM3uVodPayload(CmsSite site) async {
    if (site.ext.trim().isNotEmpty) return site.ext;
    final rawTarget = site.api.substring('m3u_vod://'.length).trim();
    if (rawTarget.startsWith('http://') || rawTarget.startsWith('https://')) {
      return _getText(rawTarget, headers: site.headers);
    }
    return '';
  }

  bool _usesJs(CmsSite site) =>
      !TrailerSource.matches(site) &&
      (WoggSource.supports(site) ||
          GuardSource.supports(site) ||
          site.isDrpySource ||
          site.isPythonSource ||
          (site.isJavaScriptSource || site.isRemoteScriptSource) &&
              !(CspBridge.isHuyaSite(site) ||
                  CspBridge.isDouyuSite(site) ||
                  CspBridge.isTuxiaobeiSite(site) ||
                  CspBridge.isMyDriveSite(site) ||
                  CspBridge.isBannerNoticeSite(site)));

  static String _scriptSessionKey(CmsSite site) => sha256.convert(utf8.encode(jsonEncode([
    site.subscriptionId, site.sourceKey, site.isEffectivelyPrivate,
    site.api, site.ext, site.pluginReference, site.headers,
    if (site.rawExtension != null) site.rawExtension,
  ]))).toString();

  /// Shared by catalogue, detail, and the player's separate CmsClient instance.
  static Future<void> retainScriptSessions(Iterable<CmsSite> sites) {
    final keys = sites.map(_scriptSessionKey).toSet();
    PythonSourceHost.instance.retainSessions(keys);
    return JsSourceHost.retainSessions(keys);
  }

  static Future<void> closeScriptSessions() {
    PythonSourceHost.instance.retainSessions({});
    return JsSourceHost.closeAll();
  }

  static Future<void> onAppResumed() async {
    await Future.wait([
      JsSourceHost.onAppResumed(),
      PythonSourceHost.instance.onAppResumed(),
    ]);
  }

  void Function() pinPlaybackSource(CmsSite site) {
    if (!_usesJs(site)) return () {};
    final key = _scriptSessionKey(site);
    final js = JsSourceHost.pinForPlayback(key);
    final python = _pythonHost.pinForPlayback(key);
    return () { js(); python(); };
  }

  static bool canVerifySource(CmsSite site) =>
      GuardSource.supports(site) &&
      const {'fy-v1', 'auete-v1'}.contains(CspBridge.guardAdapterFor(site));

  static bool needsSourceVerification(CmsSite site, Object? error) =>
      canVerifySource(site) && error is DrpySourceException &&
      error.code == 'drpy_verification_required';

  void _requireSourceAdapter(CmsSite site) {
    if (site.isScriptOrJarApi && !site.canBrowse) {
      throw FormatException(site.unsupportedReason);
    }
  }

  /// Strict Local-First adapter pack resolution: native local adapters always
  /// take priority; only unadapted `csp_*` sites matched by an enabled user
  /// adapter pack are materialized into local JS/DRPY/Python/T4 sites.
  CmsSite _resolveAdapterSite(CmsSite site) {
    if (!site.usesAdapterPack) return site;
    final rule = SpiderPluginRegistry.instance.matchAdapterRule(site);
    return rule == null ? site : rule.materializeSite(site);
  }

  bool _usesSpiderGateway(CmsSite site) => site.usesSpiderGateway;

  Future<String> _callSpiderGateway(
    CmsSite site,
    String action, [
    Map<String, dynamic> params = const <String, dynamic>{},
  ]) {
    return SpiderGatewayClient.invoke(
      SpiderPluginRegistry.instance.gatewayConfig,
      site: site,
      action: action,
      params: params,
      client: _http,
    );
  }

  /// Downloads and validates a remote `marco-adapter-pack-v1` JSON plugin pack.
  Future<SpiderAdapterPack> fetchSpiderAdapterPack(String rawUrl) async {
    final normalized = CmsParser.extractAndNormalizeUrl(rawUrl);
    if (normalized.isEmpty) {
      throw const FormatException('请输入有效的 HTTP(S) 插件包地址');
    }
    final text = await _getText(normalized);
    return SpiderAdapterPack.parseJsonString(
      text,
      fallbackSourceUrl: normalized,
    );
  }

  Future<Map<String, dynamic>> sourceVerificationAction(
    CmsSite site, Map<String, Object?> action, {Completer<void>? cancellation}
  ) async {
    if (!canVerifySource(site)) throw const FormatException('此片源暂不支持图片验证');
    if (cancellation?.isCompleted == true) throw const FormatException('验证已取消');
    final raw = await runZoned(() => _callJs(site, 'action', [jsonEncode(action)]),
        zoneValues: {_cancelKey: cancellation});
    if (cancellation?.isCompleted == true) throw const FormatException('验证已取消');
    final value = jsonDecode(raw);
    if (value is! Map<String, dynamic>) throw const FormatException('验证响应无效');
    return value;
  }

  Future<SourceImageChallenge> loadSourceChallenge(
    CmsSite site, {Completer<void>? cancellation}
  ) async => SourceImageChallenge.fromResponse(await sourceVerificationAction(site,
      {'type': 'verification', 'operation': 'challenge'}, cancellation: cancellation));

  Future<bool> submitSourceChallenge(CmsSite site, String id, String code,
      {Completer<void>? cancellation}) async {
    if (!RegExp(r'^[a-zA-Z0-9_-]{1,128}$').hasMatch(id) ||
        !RegExp(r'^[a-zA-Z0-9]{4,6}$').hasMatch(code)) {
      throw const FormatException('请输入图片中的 4 至 6 位字符');
    }
    final value = await sourceVerificationAction(site,
        {'type': 'verification', 'operation': 'submit', 'id': id, 'code': code},
        cancellation: cancellation);
    if (value['verified'] is! bool) throw const FormatException('验证响应无效');
    return value['verified'] as bool;
  }

  Future<String> _callJs(CmsSite site, String method, List<Object?> args) async {
    final cancellation = Zone.current[_cancelKey] as Completer<void>?;
    final generation = JsSourceHost.generation;
    final pythonGeneration = _pythonHost.generation;
    if (WoggSource.supports(site)) return _wogg.invoke(site, method, args, cancellation: cancellation);
    if (GuardSource.supports(site)) return _guard.invoke(site, method, args, cancellation: cancellation);
    if (site.isDrpySource) return _drpy.invoke(site, method, args, cancellation: cancellation);
    final cachedRule = await _drpy.callCached(site, method, args, cancellation: cancellation);
    if (cachedRule != null) return cachedRule;
    final sessionKey = _scriptSessionKey(site);
    final cachedPython = await _pythonHost.callCached(sessionKey: sessionKey,
        method: method, arguments: args, cancellation: cancellation);
    if (cachedPython != null) return cachedPython;
    final cachedScript = await JsSourceHost.callCached(sessionKey: sessionKey,
        method: method, arguments: args, cancellation: cancellation);
    if (cachedScript != null) return cachedScript;
    var entry = site.api;
    if (site.ext.trim().isNotEmpty &&
        RegExp(r'(?:^|/)drpy2?(?:\.min)?\.m?js(?:[?#]|$)', caseSensitive: false)
            .hasMatch(entry)) {
      try {
        return await _drpy.invoke(site, method, args, cancellation: cancellation);
      } on FormatException catch (e) {
        if (!e.message.contains('没有可用的 DRPY 规则')) rethrow;
      }
    }
    Object? extension = site.ext;
    var rawExtension = site.rawExtension ?? site.ext;
    final modules = <String, String>{};
    var pythonPackage = <String, Object?>{};
    if (entry.startsWith('csp_LocalScript.')) {
      final local = jsonDecode(site.ext) as Map;
      entry = (local['origin'] as String?) ?? '';
      if (entry.isEmpty) entry = site.isPythonSource ? 'pkg://local/source.py' : 'pkg://local/source.js';
      modules[entry] = local['script'] as String;
      if (local['modules'] is Map) modules.addAll(Map<String, String>.from(local['modules'] as Map));
      if (local['package'] is Map) pythonPackage = Map<String, Object?>.from(local['package'] as Map);
      extension = local['ext'] ?? '';
      rawExtension = extension is String ? extension : jsonEncode(extension);
    } else {
      modules[entry] = await _getText(entry, headers: site.headers);
      try { extension = jsonDecode(site.ext); } on FormatException { /* Plain-text extension. */ }
    }
    if (site.isPythonSource || CmsParser.looksLikePythonScript(modules[entry]!)) {
      if (_pythonHost.enabled) {
        return _pythonHost.invoke(sessionKey: sessionKey,
            expectedGeneration: pythonGeneration, method: method, arguments: args,
            cancellation: cancellation,
            package: PythonSourceHost.packageFromSource(entry: entry,
                source: modules[entry]!, extension: rawExtension,
                packageData: pythonPackage, headers: _buildHeaders(site.headers)));
      }
      final prelude = await loadPythonSourcePrelude();
      return JsSourceHost.invoke(entry: entry, modules: modules, method: method, arguments: args,
          extension: extension, headers: site.headers, pythonPrelude: prelude,
          pythonPackage: pythonPackage,
          sessionKey: sessionKey, expectedGeneration: generation, cancellation: cancellation);
    }
    if (CmsParser.looksLikeDrpyRule(modules[entry]!)) {
      return _drpy.invoke(site, method, args, rule: modules[entry], origin: entry, cancellation: cancellation);
    }
    if (site.ext.trim().isNotEmpty &&
        modules[entry]!.contains('assets://js/lib/cheerio.min.js')) {
      try {
        return await _drpy.invoke(site, method, args, cancellation: cancellation);
      } on FormatException catch (e) {
        if (!e.message.contains('没有可用的 DRPY 规则')) rethrow;
      }
    }
    if (site.isRemoteScriptSource && !site.isJavaScriptSource &&
        !CmsParser.looksLikeScript(modules[entry]!)) {
      throw const FormatException('片源接口未返回可识别的脚本，请检查订阅中的接口类型');
    }
    // Preload static ES imports for the synchronous QuickJS module loader.
    var total = 0;
    final queue = [entry];
    final visited = <String>{};
    for (var index = 0; index < queue.length; index++) {
      final parent = queue[index];
      if (!visited.add(parent)) continue;
      if (visited.length > 32) throw const FormatException('脚本模块过多');
      final text = modules[parent]!;
      total += utf8.encode(text).length;
      if (total > maxResponseBytes) throw const FormatException('脚本模块总大小超过 16 MB');
      if (Uri.parse(parent).path.toLowerCase().endsWith('.json')) continue;
      final required = JsSourceHost.commonJsReferences(text).toSet();
      final references = {...JsSourceHost.esModuleReferences(text), ...required};
      for (final ref in references) {
        if (ref == 'catvod' && !required.contains(ref)) continue;
        if (ref == 'catvod' || ref.startsWith('catvod:') || ref.startsWith('marco:')) {
          throw const FormatException('当前脚本需要 CatVod 宿主模块，该接口尚未适配');
        }
        final common = required.contains(ref);
        if (common && !ref.startsWith('.') && !ref.startsWith('https://') && !ref.startsWith('http://') && !ref.startsWith('assets://')) {
          throw FormatException('不支持的 Node 模块：$ref');
        }
        var url = Uri.parse(parent).resolve(ref);
        if (url.scheme == 'assets') {
          final assetRef = url.toString();
          if (!modules.containsKey(assetRef)) {
            if (assetRef == 'assets://js/lib/cheerio.min.js') {
              final deps = await rootBundle.loadString(
                'assets/catpaw/drpy-dependencies.js',
              );
              modules[assetRef] =
                  '$deps\nglobalThis.DRPYDeps = DRPYDeps;\nexport const load = DRPYDeps.cheerio.load;\nexport const jp = DRPYDeps.cheerio.jp;\nexport const jpo = DRPYDeps.cheerio.jpo;\nexport const jinja2 = DRPYDeps.cheerio.jinja2;\nexport default DRPYDeps.cheerio;\n';
            } else if (assetRef == 'assets://js/lib/crypto-js.js') {
              final cryptoSrc = await rootBundle.loadString(
                'assets/js-host/crypto-js.js',
              );
              modules[assetRef] =
                  'const module={exports:{}};let exports=module.exports;\n$cryptoSrc\nglobalThis.CryptoJS = module.exports;\nexport default module.exports;\n';
            } else if (assetRef == 'assets://js/lib/cat.js') {
              modules[assetRef] = 'export * from "catvod";\n';
              queue.add(assetRef);
            } else if (assetRef.startsWith('assets://js/lib/')) {
              final relPath = assetRef.substring('assets://js/lib/'.length);
              final entryUri = Uri.parse(entry);
              if (entryUri.scheme == 'http' || entryUri.scheme == 'https') {
                final remoteLib = entryUri.resolve(relPath);
                modules[assetRef] = await _getText(
                  remoteLib.toString(),
                  headers: site.headers,
                );
                queue.add(assetRef);
              } else {
                throw FormatException('本地包缺少脚本模块：$ref');
              }
            } else {
              throw FormatException('本地包缺少脚本模块：$ref');
            }
          }
          continue;
        }
        final candidates = [url, if (common && !RegExp(r'\.(?:m?js|json)$', caseSensitive: false).hasMatch(url.path)) ...[
          url.replace(path: '${url.path}.js'), url.replace(path: '${url.path}.json'),
          url.replace(path: '${url.path}/index.js'),
        ]];
        for (final candidate in candidates) {
          if (modules.containsKey(candidate.toString())) { url = candidate; break; }
        }
        if (!modules.containsKey(url.toString())) {
          if (url.scheme != 'https' && url.scheme != 'http') {
            throw FormatException('本地包缺少脚本模块：$ref');
          }
          for (var i = 0; i < candidates.length; i++) {
            url = candidates[i];
            final sameOrigin = Uri.parse(parent).authority == url.authority && Uri.parse(parent).scheme == url.scheme;
            try {
              modules[url.toString()] = await _getText(url.toString(), headers: sameOrigin ? site.headers : {});
              break;
            } on HttpException catch (error) {
              if (error.message != 'HTTP 404' || i == candidates.length - 1) rethrow;
            }
          }
        }
        queue.add(url.toString());
      }
    }
    final cat = JsSourceHost.isCatSpider(modules[entry]!) && !JsSourceHost.isEsModule(modules[entry]!);
    return JsSourceHost.invoke(entry: entry, modules: modules, method: method,
      arguments: args, catDetails: cat,
      extension: cat ? {'stype': 3, 'skey': site.key, 'ext': extension} : extension,
      rawExtension: rawExtension,
      headers: site.headers, sessionKey: sessionKey, expectedGeneration: generation,
      cancellation: cancellation);
  }

  String _wrapJsEpisodeIds(String raw, {String scheme = 'mmjs'}) {
    final doc = jsonDecode(raw);
    if (doc is! Map || doc['list'] is! List) return raw;
    for (final item in (doc['list'] as List).whereType<Map>()) {
      final urls = item['vod_play_url'];
      if (urls is! String || urls.isEmpty) continue;
      final flags = (item['vod_play_from'] ?? '').toString().split(r'$$$');
      final groups = urls.split(r'$$$');
      for (var i = 0; i < groups.length; i++) {
        groups[i] = groups[i].split('#').where((s) => s.trim().isNotEmpty).map((s) {
          final sep = s.indexOf(r'$');
          final label = sep < 0 ? '正片' : s.substring(0, sep);
          final epId = sep < 0 ? s : s.substring(sep + 1);
          final trimmedEpId = epId.trim();
          if (trimmedEpId.startsWith('mmshare://')) {
            final norm = ResilientHttpClient.normalizeCloudShareUrl(trimmedEpId);
            return '$label\$mmshare://${norm ?? trimmedEpId.substring('mmshare://'.length).trim()}';
          }
          if (trimmedEpId.toLowerCase().startsWith('push://') ||
              trimmedEpId.toLowerCase().startsWith('http://') ||
              trimmedEpId.toLowerCase().startsWith('https://')) {
            final normShare =
                ResilientHttpClient.normalizeCloudShareUrl(trimmedEpId);
            if (normShare != null) {
              return '$label\$mmshare://$normShare';
            }
          }
          final uri = Uri(scheme: scheme, host: 'play', queryParameters: {
            'flag': i < flags.length ? flags[i] : '',
            'id': epId,
          });
          return label + r'$' + uri.toString();
        }).join('#');
      }
      item['vod_play_url'] = groups.join(r'$$$');
    }
    return jsonEncode(doc);
  }

  String _detailAction(CmsSite site) => site.type == 0 ? 'videolist' : 'detail';

  Future<(List<CmsCategory>, CmsListing)> fetchHome(CmsSite site) async {
    site = _resolveAdapterSite(site);
    _requireSourceAdapter(site);
    if (_usesSpiderGateway(site)) {
      final raw = await _callSpiderGateway(site, 'home', {'filter': true});
      final categories = CmsParser.parseCategories(raw);
      var listing = CmsParser.parseListing(_wrapJsEpisodeIds(raw, scheme: 'mmgw'));
      if (listing.videos.isEmpty) {
        try {
          final vodRaw = await _callSpiderGateway(site, 'homeVod');
          listing = CmsParser.parseListing(_wrapJsEpisodeIds(vodRaw, scheme: 'mmgw'));
        } catch (_) {}
        if (listing.videos.isEmpty && categories.isNotEmpty) {
          listing = await fetchCategory(site, categories.first.id, 1);
        }
      }
      return (categories, listing);
    }
    if (_isHttpT4(site)) {
      final raw = await _callT4(site, {'filter': 'true'});
      final categories = CmsParser.parseCategories(raw);
      var listing = CmsParser.parseListing(_wrapJsEpisodeIds(raw, scheme: 'mmt4'));
      if (listing.videos.isEmpty && categories.isNotEmpty) listing = await fetchCategory(site, categories.first.id, 1);
      return (categories, listing);
    }
    if (site.isCatPaw) {
      final raw = await _getText(site.api);
      final categories = CmsParser.parseCategories(raw);
      var listing = CmsParser.parseListing(raw);
      if (listing.videos.isEmpty && categories.isNotEmpty) {
        listing = await fetchCategory(site, categories.first.id, 1);
      }
      return (categories, listing);
    }
    if (site.isEmby) return (await EmbyLibrary.open(site)).home();
    if (_usesJs(site)) {
      final raw = await _callJs(site, 'home', [false]);
      final categories = CmsParser.parseCategories(raw);
      var listing = CmsParser.parseListing(raw);
      if (listing.videos.isEmpty) {
        try { listing = CmsParser.parseListing(await _callJs(site, 'homeVod', [])); }
        catch (error) {
          if (categories.isEmpty || needsSourceVerification(site, error)) rethrow;
        }
        if (listing.videos.isEmpty && categories.isNotEmpty) {
          listing = await fetchCategory(site, categories.first.id, 1);
        }
      }
      return (categories, listing);
    }
    if (site.isM3uVodApi) {
      final content = await _resolveM3uVodPayload(site);
      return CmsParser.parseM3uVodHome(content, origin: site.api.substring('m3u_vod://'.length));
    }
    if (CspBridge.canHandleSite(site)) {
      return CspBridge.fetchHome(site, _getText);
    }
    List<CmsCategory> categories = const [];
    CmsListing listing = const CmsListing();
    // Step 1: Query `ac=list` first (standard MacCMS endpoint for categories)
    try {
      final listRaw = await _getText(
        _appendQuery(site.api, {'ac': 'list'}, ext: site.ext).toString(),
        headers: site.headers,
      );
      categories = CmsParser.parseCategories(listRaw);
      listing = CmsParser.parseListing(listRaw);
    } catch (_) {}
    // Step 2: Query `ac=detail` or `ac=videolist` for full video cards with posters
    if (listing.videos.isEmpty ||
        listing.videos.every((v) => v.poster.isEmpty)) {
      try {
        final detailRaw = await _getText(
          _appendQuery(site.api, {'ac': _detailAction(site)}, ext: site.ext).toString(),
          headers: site.headers,
        );
        if (categories.isEmpty) {
          categories = CmsParser.parseCategories(detailRaw);
        }
        final detailListing = CmsParser.parseListing(detailRaw);
        if (detailListing.videos.isNotEmpty) {
          listing = detailListing;
        }
      } catch (_) {
        if (categories.isEmpty && listing.videos.isEmpty) rethrow;
      }
    }
    if (listing.videos.isEmpty && categories.isNotEmpty) {
      listing = await fetchCategory(site, categories.first.id, 1);
    }
    return (categories, listing);
  }
  /// Checks whether a remote source actually honored an explicit year filter
  /// instead of returning an unchanged unfiltered feed. If cards omit year
  /// metadata we still trust the source (`true`); only when multiple cards
  /// report explicit years and zero match [filter.year] do we fall back to
  /// client-side filtering.
  static bool _looksSourceHonoredFilter(
    List<CmsVideo> videos,
    CmsFilter filter,
  ) {
    final targetYear = filter.year.trim();
    if (targetYear.isEmpty || targetYear == '全部' || videos.isEmpty) {
      return true;
    }
    final yearPattern = RegExp(r'\b((?:19|20)\d{2})\b');
    var withExplicitYear = 0;
    var yearMatched = 0;
    for (final v in videos) {
      final m = yearPattern.firstMatch('${v.year} ${v.title}');
      if (m == null) continue;
      withExplicitYear++;
      final y = int.tryParse(m.group(1)!);
      if (y == null) continue;
      if (targetYear == '更早') {
        if (y <= 2017) yearMatched++;
      } else if (m.group(1) == targetYear) {
        yearMatched++;
      }
    }
    if (withExplicitYear >= 3 && yearMatched == 0) {
      return false;
    }
    return true;
  }

  Future<CmsListing> fetchCategory(
    CmsSite site,
    String categoryId,
    int page, {
    List<String> childIds = const [],
    CmsFilter? filter,
  }) async {
    site = _resolveAdapterSite(site);
    _requireSourceAdapter(site);
    if (_usesSpiderGateway(site)) {
      final filters = <String, String>{
        if (filter != null && filter.genreLabel.isNotEmpty && filter.genreLabel != '全部') 'class': filter.genreLabel,
        if (filter != null && filter.area.isNotEmpty && filter.area != '全部') 'area': filter.area,
        if (filter != null && filter.year.isNotEmpty && filter.year != '全部') 'year': filter.year,
      };
      final raw = await _callSpiderGateway(site, 'category', {
        'tid': categoryId,
        'pg': page,
        'filter': filters,
      });
      final listing = CmsParser.parseListing(_wrapJsEpisodeIds(raw, scheme: 'mmgw'));
      return CmsListing(
        page: listing.page,
        pageCount: listing.pageCount,
        videos: listing.videos,
        sourceFiltered: filters.isNotEmpty &&
            (filter == null || _looksSourceHonoredFilter(listing.videos, filter)),
      );
    }
    if (_isHttpT4(site)) {
      final filters = <String, String>{
        if (filter != null && filter.genreLabel.isNotEmpty && filter.genreLabel != '全部') 'class': filter.genreLabel,
        if (filter != null && filter.area.isNotEmpty && filter.area != '全部') 'area': filter.area,
        if (filter != null && filter.year.isNotEmpty && filter.year != '全部') 'year': filter.year,
      };
      final raw = await _callT4(site, {'ac': 'detail', 't': categoryId, 'pg': '$page',
        'ext': base64Url.encode(utf8.encode(jsonEncode(filters)))});
      final listing = CmsParser.parseListing(_wrapJsEpisodeIds(raw, scheme: 'mmt4'));
      return CmsListing(
        page: listing.page,
        pageCount: listing.pageCount,
        videos: listing.videos,
        sourceFiltered: filters.isNotEmpty &&
            (filter == null || _looksSourceHonoredFilter(listing.videos, filter)),
      );
    }
    if (site.isEmby) return (await EmbyLibrary.open(site)).list(categoryId, '', page);
    if (_usesJs(site)) {
      final wogg = WoggSource.supports(site);
      String normalizeWoggArea(String raw) => switch (raw.trim()) {
            '大陆' || '内地' => '中国大陆',
            '香港' => '中国香港',
            '台湾' => '中国台湾',
            final other => other,
          };
      final rawYear = filter?.year.trim() ?? '';
      final exactYear = RegExp(r'^(?:19|20)\d{2}$').hasMatch(rawYear);
      final extend = <String, String>{
        if (filter != null &&
            filter.genreLabel.isNotEmpty &&
            filter.genreLabel != '全部')
          (wogg ? '3' : 'class'): filter.genreLabel,
        if (GuardSource.supports(site) &&
            filter != null &&
            filter.genreLabel.isNotEmpty)
          'type': filter.genreLabel,
        if (filter != null && filter.area.isNotEmpty && filter.area != '全部')
          (wogg ? '1' : 'area'):
              wogg ? normalizeWoggArea(filter.area) : filter.area.trim(),
        if (filter != null &&
            rawYear.isNotEmpty &&
            rawYear != '全部' &&
            (!wogg || exactYear))
          (wogg ? '11' : 'year'): rawYear,
      };
      final effectiveCategoryId =
          (wogg && !RegExp(r'^\d+$').hasMatch(categoryId.trim()))
              ? '1'
              : categoryId;
      final listing = CmsParser.parseListing(await _callJs(site, 'category', [
        effectiveCategoryId,
        page,
        extend.isNotEmpty,
        extend,
      ]));
      if (filter == null || !filter.hasSubFilter || extend.isEmpty) {
        return listing;
      }
      // When WoggSource could not send a decade bucket (`2010年代` / `更早`) in slot 11,
      // apply year-only client-side filtering on the server-filtered result.
      final filteredVideos =
          (wogg && rawYear.isNotEmpty && rawYear != '全部' && !exactYear)
              ? CmsParser.filterVideos(listing.videos, CmsFilter(year: rawYear))
              : listing.videos;
      return CmsListing(
        page: listing.page,
        pageCount: listing.pageCount,
        videos: filteredVideos,
        sourceFiltered: true,
      );
    }
    if (site.isM3uVodApi) {
      final content = await _resolveM3uVodPayload(site);
      final (_, homeListing) = CmsParser.parseM3uVodHome(content, origin: site.api.substring('m3u_vod://'.length));
      var videos = homeListing.videos;
      if (categoryId.isNotEmpty) {
        videos = videos
            .where((v) => v.remarks == categoryId || v.tag == categoryId)
            .toList();
      }
      if (filter != null && filter.hasSubFilter) {
        videos = CmsParser.filterVideos(videos, filter);
      }
      return CmsListing(page: 1, pageCount: 1, videos: videos);
    }
    if (CspBridge.canHandleSite(site)) {
      final listing = await CspBridge.fetchCategory(
        site,
        categoryId,
        page,
        _getText,
        childIds: childIds,
        filter: filter,
      );
      if (listing.sourceFiltered) {
        return listing;
      }
      if (filter != null && filter.hasSubFilter) {
        final filtered = CmsParser.filterVideos(listing.videos, filter);
        if (filtered.isNotEmpty || page > 1) {
          return CmsListing(
            page: listing.page,
            pageCount: listing.pageCount,
            videos: filtered,
            sourceFiltered: filtered.isNotEmpty,
          );
        }
      }
      return listing;
    }
    Future<CmsListing> query(String id) async {
      final params = <String, String>{
        'ac': _detailAction(site),
        'pg': page.toString(),
      };
      if (id.isNotEmpty) {
        params['t'] = id;
      }
      var sentServerFilter = false;
      if (filter != null) {
        if (filter.area.isNotEmpty && filter.area != '全部') {
          params['area'] = filter.area;
          sentServerFilter = true;
        }
        if (filter.year.isNotEmpty &&
            filter.year != '全部' &&
            filter.year != '2010年代' &&
            filter.year != '更早') {
          params['year'] = filter.year;
          sentServerFilter = true;
        }
        if (filter.genreLabel.isNotEmpty && filter.genreLabel != '全部') {
          params['class'] = filter.genreLabel;
          sentServerFilter = true;
        }
      }
      final raw = await _getText(
        _appendQuery(site.api, params, ext: site.ext).toString(),
        headers: site.headers,
      );
      final parsed = CmsParser.parseListing(raw);
      if (filter != null && filter.hasSubFilter) {
        final filtered = CmsParser.filterVideos(parsed.videos, filter);
        if (filtered.isNotEmpty) {
          return CmsListing(
            page: parsed.page,
            pageCount: parsed.pageCount,
            videos: filtered,
            sourceFiltered: true,
          );
        }
        // If server accepted filter query params and returned cards that omit
        // `vod_area`/`vod_year`/`vod_class` fields, trust the server response
        // instead of discarding every card on empty client metadata.
        if (sentServerFilter && parsed.videos.isNotEmpty) {
          final needsArea = filter.area.isNotEmpty && filter.area != '全部';
          final needsYear = filter.year.isNotEmpty && filter.year != '全部';
          final needsGenre =
              filter.genreLabel.isNotEmpty && filter.genreLabel != '全部';
          final cardsLackMetadata =
              (needsArea && parsed.videos.every((v) => v.area.trim().isEmpty)) ||
              (needsYear && parsed.videos.every((v) => v.year.trim().isEmpty)) ||
              (needsGenre && parsed.videos.every((v) => v.tag.trim().isEmpty));
          if (cardsLackMetadata) {
            return CmsListing(
              page: parsed.page,
              pageCount: parsed.pageCount,
              videos: parsed.videos,
              sourceFiltered: true,
            );
          }
        }
      }
      return parsed;
    }
    final direct = await query(categoryId);
    if (direct.videos.isNotEmpty || childIds.isEmpty) return direct;
    // Parent category returned nothing: merge its leaf categories instead.
    final children = await Future.wait(
      childIds.take(8).map(
            (id) => query(id).catchError((_) => const CmsListing()),
          ),
    );
    return CspBridge.mergeChildListings(children, page);
  }
  Future<CmsListing> fetchSearch(
    CmsSite site,
    String keyword, {
    int page = 1,
  }) async {
    site = _resolveAdapterSite(site);
    _requireSourceAdapter(site);
    if (_usesSpiderGateway(site)) {
      final raw = await _callSpiderGateway(site, 'search', {
        'wd': keyword.trim(),
        'pg': page,
      });
      return CmsParser.parseListing(_wrapJsEpisodeIds(raw, scheme: 'mmgw'));
    }
    if (_isHttpT4(site)) {
      final raw = await _callT4(site, {'wd': keyword.trim(), 'quick': 'false', 'pg': '$page'});
      return CmsParser.parseListing(_wrapJsEpisodeIds(raw, scheme: 'mmt4'));
    }
    if (site.isEmby) return (await EmbyLibrary.open(site)).list('', keyword, page);
    if (_usesJs(site)) {
      return CmsParser.parseListing(await _callJs(site, 'search', [keyword, false, page]));
    }
    if (site.isM3uVodApi) {
      final content = await _resolveM3uVodPayload(site);
      final (_, homeListing) = CmsParser.parseM3uVodHome(content, origin: site.api.substring('m3u_vod://'.length));
      final kw = keyword.trim().toLowerCase();
      final matched = homeListing.videos
          .where((v) => v.title.toLowerCase().contains(kw))
          .toList(growable: false);
      return CmsListing(page: 1, pageCount: 1, videos: matched);
    }
    if (CspBridge.canHandleSite(site)) {
      return CspBridge.fetchSearch(site, keyword, page, _getText);
    }
    final raw = await _getText(
      _appendQuery(
        site.api,
        {
          'ac': _detailAction(site),
          'wd': keyword.trim(),
          'pg': page.toString(),
        },
        ext: site.ext,
      ).toString(),
      headers: site.headers,
    );
    return CmsParser.parseListing(raw);
  }
  /// Match a catalogue-only item to a playable item from the user's visible
  /// subscriptions, or recover a same-site sibling card on a netdisk source
  /// when an edition card's shares have all been cancelled upstream.
  Future<(CmsSite, CmsVideo)> playableDetail(
    CmsSite source, CmsVideo item, Iterable<CmsSite> candidates,
  ) async {
    String normTitleOf(String raw) =>
        raw.trim().toLowerCase().replaceAll(RegExp(r'[\s·:：,，.。!！?？\-_—()（）\[\]【】《》]+'), '');

    CmsVideo? fetchedDetail;
    FormatException? deadShareError;
    StackTrace? deadShareStack;
    final canTrySameSiteSibling = !CspBridge.isDoubanSite(source) &&
        CspBridge.isPanOrNetdiskSite(source) &&
        source.searchable &&
        !CspBridge.isSearchOnlySite(source) &&
        !CspBridge.isMyDriveSite(source);

    try {
      fetchedDetail = await fetchDetail(source, item);
      if (fetchedDetail.lines.any((l) => l.episodes.isNotEmpty)) {
        return (source, fetchedDetail);
      }
    } on FormatException catch (e, st) {
      final isDeadShareMsg = e.message.contains('分享链接已失效') ||
          e.message.contains('原网盘分享暂不可用') ||
          e.message.contains('网盘暂不支持');
      if (canTrySameSiteSibling &&
          isDeadShareMsg &&
          !needsSourceVerification(source, e) &&
          !_sourceCancelled()) {
        deadShareError = e;
        deadShareStack = st;
      } else {
        rethrow;
      }
    }

    if (!CspBridge.isDoubanSite(source)) {
      if (canTrySameSiteSibling &&
          (deadShareError != null ||
              (fetchedDetail != null && fetchedDetail.sourceWarnings.isNotEmpty))) {
        final seedVideo = fetchedDetail ?? item;
        final rawTitle = CspBridge.searchTitleForVideo(seedVideo);
        final baseTitle = CspBridge.cleanNetdiskSearchTitle(rawTitle);
        final normBase = normTitleOf(baseTitle);
        if (baseTitle.isNotEmpty && normBase.isNotEmpty) {
          try {
            final searchListing = await fetchSearch(source, baseTitle);
            final siblings = searchListing.videos.where((v) {
              if (v.id.trim().isEmpty ||
                  v.id == item.id ||
                  (fetchedDetail != null && v.id == fetchedDetail.id)) {
                return false;
              }
              if (seedVideo.year.isNotEmpty &&
                  v.year.isNotEmpty &&
                  seedVideo.year != v.year) {
                return false;
              }
              final cleanedCand = CspBridge.cleanNetdiskSearchTitle(v.title);
              // Prevent matching spin-offs with middle dot subtitle (`兰香如故·花胜秋宴`)
              // when the user clicked `兰香如故（臻彩）` (`baseTitle == '兰香如故'`).
              if (!baseTitle.contains('·') && cleanedCand.contains('·')) {
                return false;
              }
              return normTitleOf(cleanedCand) == normBase;
            }).take(3);

            for (final sib in siblings) {
              if (_sourceCancelled()) break;
              try {
                final sibDetail = await fetchDetail(source, sib);
                if (sibDetail.lines.any((l) => l.episodes.isNotEmpty)) {
                  final note =
                      '当前版本原分享已失效，已自动加载同站可用片源「${sibDetail.title.isEmpty ? sib.title : sibDetail.title}」';
                  final mergedWarnings = <String>[
                    note,
                    ...sibDetail.sourceWarnings,
                  ];
                  return (
                    source,
                    CmsVideo(
                      id: sibDetail.id,
                      title: sibDetail.title,
                      poster: CmsParser.isBrokenPosterUrl(sibDetail.poster)
                          ? seedVideo.poster
                          : sibDetail.poster,
                      remarks: sibDetail.remarks,
                      year: sibDetail.year.isEmpty
                          ? seedVideo.year
                          : sibDetail.year,
                      area: sibDetail.area.isEmpty
                          ? seedVideo.area
                          : sibDetail.area,
                      actor: sibDetail.actor.isEmpty
                          ? seedVideo.actor
                          : sibDetail.actor,
                      description: sibDetail.description.isEmpty
                          ? seedVideo.description
                          : sibDetail.description,
                      tag: sibDetail.tag.isEmpty
                          ? seedVideo.tag
                          : sibDetail.tag,
                      doubanScore:
                          sibDetail.doubanScore ?? seedVideo.doubanScore,
                      rtScore: sibDetail.rtScore ?? seedVideo.rtScore,
                      lines: sibDetail.lines,
                      sourceWarnings: mergedWarnings,
                    ),
                  );
                }
              } catch (_) {
                // Continue checking remaining same-site sibling candidates.
              }
            }
          } catch (_) {
            // Same-site recovery failed; fall back to original detail/error.
          }
        }
      }
      if (deadShareError != null) {
        Error.throwWithStackTrace(deadShareError, deadShareStack!);
      }
      return (source, fetchedDetail!);
    }
    final detail = fetchedDetail!;
    final title = CspBridge.searchTitleForVideo(detail);
    if (title.isEmpty) return (source, detail);
    final normTitle = normTitleOf(title);
    final filtered = candidates.where((s) => s.key != source.key &&
        s.isEffectivelyPrivate == source.isEffectivelyPrivate && s.searchable &&
        s.canBrowse && !CspBridge.isDoubanSite(s) && !CspBridge.isMyDriveSite(s) &&
        (_usesJs(s) || s.usesAdapterPack || s.usesSpiderGateway || CspBridge.usesWoggNetdiskAdapter(s) || !CspBridge.canHandleSite(s) || CspBridge.backendsForSite(s).isNotEmpty ||
          CspRuleEngines.supports(s) || CspBridge.isBiliSite(s) ||
          CspBridge.isFirstAidSite(s) || CspBridge.isTuxiaobeiSite(s))).toList();
    int sitePriority(CmsSite s) {
      if (WoggSource.supports(s) || CspBridge.isNetdiskSite(s)) {
        return 3;
      }
      if (CspBridge.isBiliSite(s) || CspBridge.isFirstAidSite(s) || CspBridge.isTuxiaobeiSite(s)) {
        return 2;
      }
      if (!CspBridge.canHandleSite(s) ||
          CspBridge.backendsForSite(s).isNotEmpty ||
          GuardSource.supports(s)) {
        return 0;
      }
      return 1;
    }
    final indexed = filtered.indexed.toList()
      ..sort((a, b) {
        final cmp = sitePriority(a.$2).compareTo(sitePriority(b.$2));
        return cmp != 0 ? cmp : a.$1.compareTo(b.$1);
      });
    final sites = indexed.map((e) => e.$2).take(12).toList();
    if (sites.isEmpty) return (source, detail);

    Future<(CmsSite, CmsVideo)?> match(CmsSite site) async {
      try {
        final results = await fetchSearch(site, title);
        final exactMatches = results.videos.where((v) => v.title.trim() == title).toList();
        final normMatches = normTitle.isEmpty
            ? const <CmsVideo>[]
            : results.videos
                .where((v) =>
                    v.title.trim() != title &&
                    normTitleOf(v.title) == normTitle)
                .toList();
        for (final found in [...exactMatches, ...normMatches]) {
          if (detail.year.isNotEmpty && found.year.isNotEmpty && found.year != detail.year) continue;
          final video = await fetchDetail(site, found);
          if (detail.year.isNotEmpty && video.year.isNotEmpty && video.year != detail.year) continue;
          final videoTitle = video.title.trim();
          final titleMatches = videoTitle == title ||
              (normTitle.isNotEmpty && normTitleOf(videoTitle) == normTitle);
          final hasPlayable = video.lines.any((l) => l.episodes.any((e) =>
              e.isDirectPlayable ||
              e.needsSourceResolution ||
              (CspRuleEngines.supports(site) && e.url.startsWith('http'))));
          if (titleMatches && hasPlayable) {
            final enriched = (video.doubanScore == null && detail.doubanScore != null) ||
                    (video.rtScore == null && detail.rtScore != null)
                ? CmsVideo(
                    id: video.id,
                    title: video.title,
                    poster: video.poster,
                    remarks: video.remarks,
                    year: video.year,
                    area: video.area,
                    actor: video.actor,
                    description: video.description,
                    tag: video.tag,
                    doubanScore: video.doubanScore ?? detail.doubanScore,
                    rtScore: video.rtScore ?? detail.rtScore,
                    lines: video.lines,
                    sourceWarnings: video.sourceWarnings,
                  )
                : video;
            return (site, enriched);
          }
        }
      } catch (_) {
        // One failed source must not discard matches from other sources.
      }
      return null;
    }

    const maxConcurrency = 4;
    final parentAbort = Zone.current[_cancelKey] as Completer<void>?;
    final winner = Completer<(CmsSite, CmsVideo)?>();
    final activeAborts = <Completer<void>>{};
    int nextIndex = 0;
    int inFlight = 0;
    void cancelRemaining() {
      for (final a in activeAborts) {
        if (!a.isCompleted) a.complete();
      }
    }
    final parentSub = parentAbort?.future.asStream().listen((_) {
      cancelRemaining();
      if (!winner.isCompleted) winner.complete(null);
    });
    void pump() {
      if (winner.isCompleted) return;
      while (!winner.isCompleted &&
          inFlight < maxConcurrency &&
          nextIndex < sites.length) {
        final candidateSite = sites[nextIndex++];
        inFlight++;
        final taskAbort = Completer<void>();
        activeAborts.add(taskAbort);
        runZoned(() => match(candidateSite), zoneValues: {_cancelKey: taskAbort})
            .timeout(const Duration(seconds: 8), onTimeout: () {
          if (!taskAbort.isCompleted) taskAbort.complete();
          return null;
        }).then((result) {
          if (result != null && !winner.isCompleted) {
            winner.complete(result);
            cancelRemaining();
          }
        }).catchError((Object _) {}).whenComplete(() {
          if (!taskAbort.isCompleted) taskAbort.complete();
          activeAborts.remove(taskAbort);
          inFlight--;
          if (winner.isCompleted) return;
          if (nextIndex < sites.length) {
            pump();
          } else if (inFlight <= 0 && !winner.isCompleted) {
            winner.complete(null);
          }
        });
      }
    }
    try {
      pump();
      final matched = await winner.future;
      if (parentAbort?.isCompleted == true) {
        throw StateError('片源加载已取消');
      }
      return matched ?? (source, detail);
    } finally {
      cancelRemaining();
      if (parentSub != null) {
        unawaited(parentSub.cancel());
      }
    }
  }

  static const Duration _detailCacheTtl = Duration(minutes: 5);
  static const int _maxDetailCacheEntries = 48;
  final Map<String, ({CmsVideo video, DateTime expiresAt})> _detailCache = {};
  final Map<String, Future<CmsVideo>> _detailInFlight = {};

  String _detailCacheKey(CmsSite site, CmsVideo fallback) => jsonEncode([
        JsSourceHost.generation,
        _pythonHost.generation,
        SpiderPluginRegistry.instance.enabledRuleCount,
        SpiderPluginRegistry.instance.gatewayConfig.isActive,
        SpiderPluginRegistry.instance.gatewayConfig.normalizedBaseUrl,
        site.subscriptionId,
        site.sourceKey,
        site.isEffectivelyPrivate,
        site.api,
        site.ext,
        site.pluginReference,
        fallback.id,
      ]);

  void clearDetailCache() {
    _detailCache.clear();
  }

  Future<void> prefetchDetail(CmsSite site, CmsVideo fallback) async {
    if (fallback.id.trim().isEmpty ||
        CspBridge.isDoubanSite(site) ||
        CspBridge.isMyDriveSite(site) ||
        WoggSource.supports(site)) {
      return;
    }
    try {
      await fetchDetail(site, fallback);
    } catch (_) {}
  }

  Future<CmsVideo> fetchDetail(CmsSite site, CmsVideo fallback) async {
    _requireSourceAdapter(site);
    if (fallback.id.trim().isEmpty) {
      return _fetchDetailUncached(site, fallback);
    }
    final cacheKey = _detailCacheKey(site, fallback);
    final now = DateTime.now();
    final cached = _detailCache[cacheKey];
    if (cached != null) {
      if (now.isBefore(cached.expiresAt)) {
        // Refresh LRU position
        _detailCache.remove(cacheKey);
        _detailCache[cacheKey] = cached;
        return _mergeDetail(cached.video, fallback);
      }
      _detailCache.remove(cacheKey);
    }

    final existingFlight = _detailInFlight[cacheKey];
    final callerAbort = Zone.current[_cancelKey] as Completer<void>?;
    if (existingFlight != null) {
      try {
        final joined = await Future.any([
          existingFlight,
          if (callerAbort != null)
            callerAbort.future.then<CmsVideo>(
              (_) => throw StateError('片源加载已取消'),
            ),
        ]);
        return _mergeDetail(joined, fallback);
      } on StateError {
        if (callerAbort?.isCompleted == true) rethrow;
        // Primary caller was cancelled; fall through to start a fresh fetch.
      }
    }

    final flight = () async {
      final fetched = await _fetchDetailUncached(site, fallback);
      final expanded = await _expandMmShareLines(fetched);
      if (expanded.lines.any((l) => l.episodes.isNotEmpty)) {
        if (_detailCache.length >= _maxDetailCacheEntries) {
          _detailCache.remove(_detailCache.keys.first);
        }
        _detailCache[cacheKey] = (
          video: expanded,
          expiresAt: DateTime.now().add(_detailCacheTtl),
        );
      }
      return expanded;
    }();
    _detailInFlight[cacheKey] = flight;
    try {
      return await flight;
    } finally {
      if (identical(_detailInFlight[cacheKey], flight)) {
        _detailInFlight.remove(cacheKey);
      }
    }
  }

  static bool _isExpandableCloudShare(String epUrl) {
    final trimmed = epUrl.trim();
    return trimmed.startsWith('mmshare://') ||
        ResilientHttpClient.cloudProviderForShare(trimmed) != null;
  }

  Future<CmsVideo> _expandMmShareLines(CmsVideo video) async {
    final hasMmShare = video.lines.any(
      (line) => line.episodes.any((ep) => _isExpandableCloudShare(ep.url)),
    );
    if (!hasMmShare) return video;

    String canonicalShareOf(String epUrl) {
      final trimmed = epUrl.trim();
      if (trimmed.startsWith('mmshare://')) {
        final raw = trimmed.substring('mmshare://'.length).trim();
        return ResilientHttpClient.normalizeCloudShareUrl(raw) ?? raw;
      }
      return ResilientHttpClient.normalizeCloudShareUrl(trimmed) ?? trimmed;
    }

    final allUniqueShares = <String>[];
    for (final line in video.lines) {
      for (final ep in line.episodes) {
        if (_isExpandableCloudShare(ep.url)) {
          final norm = canonicalShareOf(ep.url);
          if (norm.isNotEmpty && !allUniqueShares.contains(norm)) {
            allUniqueShares.add(norm);
          }
        }
      }
    }
    if (allUniqueShares.isEmpty) return video;

    var preferredOrder = const ['quark', 'uc', 'baidu', 'ali'];
    final loggedInProviders = <String>{};
    try {
      final storage = await StorageService.init();
      preferredOrder = storage.driveOrder;
      if (storage.quarkCookie.trim().isNotEmpty) loggedInProviders.add('quark');
      if (storage.ucCookie.trim().isNotEmpty) loggedInProviders.add('uc');
      if (storage.baiduCookie.trim().isNotEmpty) loggedInProviders.add('baidu');
      if (storage.aliToken.trim().isNotEmpty) loggedInProviders.add('ali');
    } catch (_) {
      // Unit tests without initialized platform storage keep original order.
    }

    int sharePriority(String shareUrl) {
      final provider = ResilientHttpClient.cloudProviderForShare(shareUrl);
      if (provider == null) return 100;
      final orderIdx = preferredOrder.indexOf(provider);
      final rank = orderIdx < 0 ? 50 : orderIdx;
      return loggedInProviders.contains(provider) ? rank : 10 + rank;
    }

    final indexedShares = allUniqueShares.indexed.toList()
      ..sort((a, b) {
        if (loggedInProviders.isNotEmpty) {
          final cmp = sharePriority(a.$2).compareTo(sharePriority(b.$2));
          if (cmp != 0) return cmp;
        }
        return a.$1.compareTo(b.$1);
      });
    final shareUrls =
        indexedShares.take(10).map((entry) => entry.$2).toList(growable: false);

    final resolvedByShare = <String, List<CmsEpisode>>{};
    final errorsByShare = <String, String>{};
    final parentAbort = Zone.current[_cancelKey] as Completer<void>?;
    final activeTokens = <Completer<void>>{};
    final parentSub = parentAbort?.future.asStream().listen((_) {
      for (final token in activeTokens.toList()) {
        if (!token.isCompleted) token.complete();
      }
    });
    var nextShareIdx = 0;
    Future<void> shareWorker() async {
      while (nextShareIdx < shareUrls.length) {
        if (_sourceCancelled()) break;
        final shareUrl = shareUrls[nextShareIdx++];
        final token = Completer<void>();
        activeTokens.add(token);
        try {
          final eps = await runSourceOperation(
            () => _listCloudShare(shareUrl),
            cancellation: token,
          ).timeout(const Duration(seconds: 18), onTimeout: () {
            if (!token.isCompleted) token.complete();
            throw TimeoutException('网盘分享读取超时');
          });
          resolvedByShare[shareUrl] = eps;
        } catch (error) {
          errorsByShare[shareUrl] = switch (error) {
            AliShareException e => e.message,
            QuarkDriveException e => e.message,
            QuarkAccountException e => e.message,
            FormatException e => e.message,
            TimeoutException _ => '网盘分享读取超时',
            _ => '网盘分享读取失败',
          };
        } finally {
          if (!token.isCompleted) token.complete();
          activeTokens.remove(token);
        }
      }
    }

    try {
      await Future.wait([
        for (var i = 0; i < 3 && i < shareUrls.length; i++) shareWorker(),
      ]);
    } finally {
      await parentSub?.cancel();
      for (final token in activeTokens.toList()) {
        if (!token.isCompleted) token.complete();
      }
    }

    final expandedLines = <CmsLine>[];
    final warnings = <String>[...video.sourceWarnings];
    for (final line in video.lines) {
      if (!line.episodes.any((ep) => _isExpandableCloudShare(ep.url))) {
        expandedLines.add(line);
        continue;
      }
      final passthroughEps = <CmsEpisode>[];
      final resolvedShareGroups = <List<CmsEpisode>>[];
      for (final ep in line.episodes) {
        if (!_isExpandableCloudShare(ep.url)) {
          passthroughEps.add(ep);
          continue;
        }
        final rawShare = canonicalShareOf(ep.url);
        final resolved = resolvedByShare[rawShare];
        if (resolved != null && resolved.isNotEmpty) {
          resolvedShareGroups.add(resolved);
        } else if (errorsByShare.containsKey(rawShare)) {
          final msg = '${line.name}：${errorsByShare[rawShare]}';
          if (!warnings.contains(msg)) warnings.add(msg);
        } else if (resolved != null && resolved.isEmpty) {
          final msg = '${line.name}：该网盘分享目录为空，暂无可播放视频';
          if (!warnings.contains(msg)) warnings.add(msg);
        }
      }
      if (resolvedShareGroups.length == 1 && passthroughEps.isEmpty) {
        expandedLines.add(
          CmsLine(name: line.name, episodes: resolvedShareGroups.single),
        );
      } else if (resolvedShareGroups.length > 1 && passthroughEps.isEmpty) {
        for (var idx = 0; idx < resolvedShareGroups.length; idx++) {
          expandedLines.add(
            CmsLine(
              name: '${line.name} ${idx + 1}',
              episodes: resolvedShareGroups[idx],
            ),
          );
        }
      } else {
        final combined = <CmsEpisode>[
          ...passthroughEps,
          for (final g in resolvedShareGroups) ...g,
        ];
        if (combined.isNotEmpty) {
          expandedLines.add(CmsLine(name: line.name, episodes: combined));
        }
      }
    }

    if (loggedInProviders.isNotEmpty && expandedLines.length > 1) {
      int linePriority(CmsLine line) {
        final providers =
            line.episodes.map((ep) => ep.cloudProvider).whereType<String>().toSet();
        if (providers.length == 1) {
          final provider = providers.single;
          final orderIdx = preferredOrder.indexOf(provider);
          final rank = orderIdx < 0 ? 50 : orderIdx;
          return loggedInProviders.contains(provider) ? rank : 20 + rank;
        }
        return 10;
      }

      final indexedLines = expandedLines.indexed.toList()
        ..sort((a, b) {
          final cmp = linePriority(a.$2).compareTo(linePriority(b.$2));
          return cmp != 0 ? cmp : a.$1.compareTo(b.$1);
        });
      expandedLines
        ..clear()
        ..addAll(indexedLines.map((e) => e.$2));
    }

    return CmsVideo(
      id: video.id,
      title: video.title,
      poster: video.poster,
      remarks: video.remarks,
      year: video.year,
      area: video.area,
      actor: video.actor,
      description: video.description,
      tag: video.tag,
      doubanScore: video.doubanScore,
      rtScore: video.rtScore,
      lines: expandedLines,
      sourceWarnings: warnings,
    );
  }

  Future<CmsVideo> _fetchDetailUncached(CmsSite site, CmsVideo fallback) async {
    site = _resolveAdapterSite(site);
    if (fallback.id.startsWith('mmquark://owned?')) {
      return _mergeDetail(CmsVideo(id: fallback.id, title: fallback.title,
          lines: [CmsLine(name: '夸克网盘', episodes: [
            CmsEpisode(name: fallback.title, url: fallback.id),
          ])]), fallback);
    }
    if (_usesSpiderGateway(site)) {
      final raw = await _callSpiderGateway(site, 'detail', {'id': fallback.id});
      final listing = CmsParser.parseListing(_wrapJsEpisodeIds(raw, scheme: 'mmgw'));
      return listing.videos.isEmpty ? fallback : _mergeDetail(listing.videos.first, fallback);
    }
    if (_isHttpT4(site)) {
      final raw = await _callT4(site, {'ac': 'detail', 'ids': fallback.id});
      final listing = CmsParser.parseListing(_wrapJsEpisodeIds(raw, scheme: 'mmt4'));
      return listing.videos.isEmpty ? fallback : _mergeDetail(listing.videos.first, fallback);
    }
    if (site.isCatPaw) {
      if (CspBridge.isDoubanSite(site)) return fallback;
      final raw = await _getText(_appendQuery(site.api, {'ac':'detail','ids':fallback.id}).toString());
      final listing = CmsParser.parseListing(_wrapJsEpisodeIds(raw,scheme:'mmpaw'));
      return listing.videos.isEmpty ? fallback : _mergeDetail(listing.videos.first, fallback);
    }
    if (site.isEmby) return (await EmbyLibrary.open(site)).detail(fallback.id);
    if (_usesJs(site)) {
      final raw = await _callJs(site, 'detail', [fallback.id,
        if (WoggSource.supports(site)) ...[fallback.title, fallback.year],
      ]);
      final listing = CmsParser.parseListing(WoggSource.supports(site) ? raw : _wrapJsEpisodeIds(raw));
      // Old versions could cache a different provider under this source. Empty
      // plugin responses must not revive those cached playback lines.
      return _mergeDetail(listing.videos.isEmpty
          ? CmsVideo(id: fallback.id, title: fallback.title)
          : listing.videos.first, fallback);
    }
    if (site.isM3uVodApi) {
      return fallback;
    }
    if (CspBridge.canHandleSite(site)) {
      return CspBridge.fetchDetail(site, fallback, _getText);
    }
    if (fallback.lines.isNotEmpty) return fallback;
    final raw = await _getText(
      _appendQuery(
        site.api,
        {
          'ac': _detailAction(site),
          'ids': fallback.id,
        },
        ext: site.ext,
      ).toString(),
      headers: site.headers,
    );
    final listing = CmsParser.parseListing(raw);
    if (listing.videos.isEmpty) return fallback;
    return _mergeDetail(listing.videos.first, fallback);
  }
  static final RegExp _pollutedTitleSuffixRe = RegExp(
    r'^[\s·\-—:：]*(?:更新至|更至|更新到|连载至|全\s*\d+\s*[集期话]|共\s*\d+\s*[集期话]|已完结|完结).*$',
  );

  CmsVideo _mergeDetail(CmsVideo detailed, CmsVideo fallback) {
    final rawDetailTitle = detailed.title.trim();
    final cleanFallbackTitle = fallback.title.trim();
    var mergedTitle = rawDetailTitle.isEmpty ? fallback.title : detailed.title;
    var extractedRemarks = '';
    if (cleanFallbackTitle.isNotEmpty &&
        rawDetailTitle.length > cleanFallbackTitle.length &&
        rawDetailTitle.startsWith(cleanFallbackTitle)) {
      final tail = rawDetailTitle.substring(cleanFallbackTitle.length).trim();
      if (_pollutedTitleSuffixRe.hasMatch(tail)) {
        mergedTitle = cleanFallbackTitle;
        extractedRemarks = tail.replaceFirst(RegExp(r'^[\s·\-—:：]+'), '').trim();
      }
    } else if (rawDetailTitle.isNotEmpty) {
      final suffixMatch = RegExp(
        r'^(.+?)(?:[\s·\-—:：]*(?:更新至|更至|更新到|连载至)(?:第?\s*\d+\s*[集期话篇章]|[^\s]{1,12}))\s*$',
      ).firstMatch(rawDetailTitle);
      if (suffixMatch != null && suffixMatch.group(1)!.trim().isNotEmpty) {
        mergedTitle = suffixMatch.group(1)!.trim();
        extractedRemarks = rawDetailTitle
            .substring(suffixMatch.group(1)!.length)
            .replaceFirst(RegExp(r'^[\s·\-—:：]+'), '')
            .trim();
      }
    }
    final mergedRemarks = detailed.remarks.isNotEmpty
        ? detailed.remarks
        : (fallback.remarks.isNotEmpty ? fallback.remarks : extractedRemarks);
    return CmsVideo(
      id: detailed.id.isEmpty ? fallback.id : detailed.id,
      title: mergedTitle,
      poster: CmsParser.isBrokenPosterUrl(detailed.poster)
          ? fallback.poster
          : detailed.poster,
      remarks: mergedRemarks,
      year: detailed.year.isEmpty ? fallback.year : detailed.year,
      area: detailed.area.isEmpty ? fallback.area : detailed.area,
      actor: detailed.actor.isEmpty ? fallback.actor : detailed.actor,
      description: detailed.description.isEmpty
          ? fallback.description
          : detailed.description,
      tag: detailed.tag.isEmpty ? fallback.tag : detailed.tag,
      doubanScore: detailed.doubanScore ?? fallback.doubanScore,
      rtScore: detailed.rtScore ?? fallback.rtScore,
      lines: detailed.lines,
      sourceWarnings: detailed.sourceWarnings,
    );
  }
  Uri? _sourceCredentialOrigin(CmsSite site) {
    if (site.isHttpApi) return Uri.tryParse(site.api);
    Object? extension = site.ext;
    try { extension = jsonDecode(site.ext); } on FormatException { /* Text URL. */ }
    final raw = extension is Map ? extension['origin'] : extension;
    final origin = raw is String ? Uri.tryParse(raw) : null;
    return origin != null && ['http', 'https'].contains(origin.scheme) ? origin : null;
  }
  static bool _isDirectStreamUrl(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null) return false;
    if (const {'rtsp', 'rtmp', 'mms', 'udp', 'rtp'}.contains(uri.scheme.toLowerCase())) {
      return true;
    }
    if (!const {'http', 'https'}.contains(uri.scheme.toLowerCase())) return false;
    return RegExp(
      r'\.(?:m3u8?|mp4|flv|mkv|ts|webm|mpd|mov|avi)$',
      caseSensitive: false,
    ).hasMatch(uri.path);
  }

  Future<ResolverHttpDocument> _fetchResolverDocument(
    String url, {
    Map<String, String> headers = const {},
    Duration? timeout,
  }) async {
    final normalized = CmsParser.normalizeUrl(url);
    final uri = Uri.parse(normalized);
    var usedDirectFallback = LiveCatalogParser.isLoopbackHost(uri.host);
    var ephemeralTransport = false;
    late http.Client transport;
    if (_http != null) {
      transport = _http;
    } else {
      final acquired = _acquireDefaultTransport(directOnly: usedDirectFallback);
      transport = acquired.client;
      ephemeralTransport = acquired.ephemeral;
    }
    final abort = Completer<void>();
    void cancel() {
      if (!abort.isCompleted) abort.complete();
      if (ephemeralTransport) transport.close();
    }
    final sessionAbort = Zone.current[_cancelKey] as Completer<void>?;
    if (sessionAbort?.isCompleted == true) {
      cancel();
      throw http.RequestAbortedException(uri);
    }
    sessionAbort?.future.then((_) => cancel());
    final deadline = Timer(timeout ?? const Duration(seconds: 10), cancel);
    try {
      final requestHeaders = _buildHeaders(headers, defaultUa: tvBoxUserAgent);
      var current = uri.replace(userInfo: '').removeFragment();
      final redirectCookies = <String,
          ({String name, String value, String domain, bool hostOnly, String path})>{};
      void mergeRedirectCookies(Uri target) {
        final matched = redirectCookies.values
            .where((c) => WebMediaResolver.redirectCookieMatches(c, target))
            .toList();
        if (matched.isEmpty) return;
        final combined = <String, String>{};
        String? existingKey;
        for (final entry in requestHeaders.entries) {
          if (entry.key.toLowerCase() == 'cookie') {
            existingKey = entry.key;
            for (final pair in entry.value.split(';')) {
              final trimmed = pair.trim();
              final eq = trimmed.indexOf('=');
              if (eq > 0) {
                combined[trimmed.substring(0, eq).trim()] =
                    trimmed.substring(eq + 1).trim();
              }
            }
          }
        }
        for (final c in matched) {
          combined[c.name] = c.value;
        }
        if (existingKey != null && existingKey != 'Cookie') {
          requestHeaders.remove(existingKey);
        }
        requestHeaders['Cookie'] =
            combined.entries.map((e) => '${e.key}=${e.value}').join('; ');
      }

      http.AbortableRequest buildRequest() =>
          http.AbortableRequest('GET', current, abortTrigger: abort.future)
            ..followRedirects = false
            ..headers.addAll(requestHeaders);

      late http.StreamedResponse response;
      for (var redirects = 0;; redirects++) {
        try {
          response = await transport.send(buildRequest());
        } catch (error) {
          if (_http == null &&
              !usedDirectFallback &&
              !abort.isCompleted &&
              isDeadLocalSystemProxyError(current, error)) {
            if (ephemeralTransport) transport.close();
            usedDirectFallback = true;
            final acquired = _acquireDefaultTransport(directOnly: true);
            transport = acquired.client;
            ephemeralTransport = acquired.ephemeral;
            response = await transport.send(buildRequest());
          } else {
            rethrow;
          }
        }
        for (final c in WebMediaResolver.parseRedirectSetCookies(
            response.headers, current)) {
          redirectCookies['${c.domain}|${c.hostOnly}|${c.path}|${c.name}'] = c;
        }
        final location = response.headers['location'];
        if (![301, 302, 303, 307, 308].contains(response.statusCode) ||
            location == null) {
          break;
        }
        await response.stream.listen(null).cancel();
        if (redirects >= 5) throw const FormatException('来源跳转次数过多');
        final next = Uri.parse(
                CmsParser.normalizeUrl(current.resolve(location).toString()))
            .removeFragment();
        if (!['http', 'https'].contains(next.scheme) ||
            next.host.isEmpty ||
            next.userInfo.isNotEmpty) {
          throw const FormatException('来源返回了不支持的跳转地址');
        }
        if (current.scheme != next.scheme ||
            current.host != next.host ||
            current.port != next.port) {
          requestHeaders.removeWhere((name, _) => const [
                'authorization',
                'proxy-authorization',
                'cookie',
                'cookie2',
              ].contains(name.toLowerCase()));
        }
        mergeRedirectCookies(next);
        current = next;
      }

      if (response.statusCode < 200 || response.statusCode >= 300) {
        await response.stream.listen(null).cancel();
        throw HttpException('HTTP ${response.statusCode}');
      }
      mergeRedirectCookies(current);

      const maxResolverDocBytes = 1024 * 1024;
      final builder = BytesBuilder(copy: false);
      var checkedPrefix = false;
      final sub = StreamIterator<List<int>>(response.stream);
      try {
        while (await sub.moveNext()) {
          builder.add(sub.current);
          if (!checkedPrefix && builder.length >= 16) {
            checkedPrefix = true;
            if (WebMediaResolver.looksLikeBinaryMediaResponse(
                response.headers, builder.toBytes())) {
              return ResolverHttpDocument(
                finalUri: current,
                statusCode: response.statusCode,
                responseHeaders: response.headers,
                effectiveRequestHeaders: Map<String, String>.of(requestHeaders),
                body: '',
                isDirectMediaResponse: true,
              );
            }
          }
          if (builder.length > maxResolverDocBytes) {
            throw const FormatException('网页内容超过解析上限');
          }
        }
      } finally {
        try {
          await sub.cancel();
        } catch (_) {}
      }

      final allBytes = builder.takeBytes();
      if (!checkedPrefix &&
          WebMediaResolver.looksLikeBinaryMediaResponse(
              response.headers, allBytes)) {
        return ResolverHttpDocument(
          finalUri: current,
          statusCode: response.statusCode,
          responseHeaders: response.headers,
          effectiveRequestHeaders: Map<String, String>.of(requestHeaders),
          body: '',
          isDirectMediaResponse: true,
        );
      }
      return ResolverHttpDocument(
        finalUri: current,
        statusCode: response.statusCode,
        responseHeaders: response.headers,
        effectiveRequestHeaders: Map<String, String>.of(requestHeaders),
        body: CmsParser.decodeTextDocument(allBytes),
      );
    } finally {
      deadline.cancel();
      cancel();
    }
  }

  static Map<String, String> _extractPayloadHeaders(dynamic rawHeader) {
    if (rawHeader is String && rawHeader.trim().startsWith('{')) {
      try {
        rawHeader = jsonDecode(rawHeader);
      } catch (_) {
        return const {};
      }
    }
    if (rawHeader is Map) {
      return rawHeader.map((k, v) => MapEntry(k.toString(), v.toString()));
    }
    return const {};
  }

  Future<Map<String, dynamic>?> _resolveSecondaryPlayback(
    CmsSite site,
    String targetUrl, {
    String explicitPlayUrl = '',
    List<CmsParse> parses = const [],
    List<CmsSniffRule> rules = const [],
    List<String> ads = const [],
    Map<String, String> extraHeaders = const {},
  }) {
    return WebMediaResolver.resolve(
      site: site,
      targetUrl: targetUrl,
      explicitPlayUrl: explicitPlayUrl,
      parses: parses,
      rules: rules,
      ads: ads,
      extraHeaders: extraHeaders,
      sourceOrigin:
          GuardSource.supports(site) ? null : _sourceCredentialOrigin(site),
      fetchDocument: _fetchResolverDocument,
      isCancelled: _sourceCancelled,
    );
  }

  Future<Map<String, dynamic>> _maybeUnwrapSpiderPayload(
    CmsSite site,
    Map rawPayload, {
    List<CmsParse> parses = const [],
    List<CmsSniffRule> rules = const [],
    List<String> ads = const [],
  }) async {
    final payload = Map<String, dynamic>.from(rawPayload);
    final rawUrlObj = payload['url'];
    final rawUrl = rawUrlObj is String ? rawUrlObj.trim() : '';
    if (rawUrl.isNotEmpty && _isDirectStreamUrl(rawUrl)) {
      payload['parse'] = 0;
      payload['jx'] = 0;
      return payload;
    }
    if (SourcePlayback.needsParse(payload['parse']) ||
        SourcePlayback.needsParse(payload['jx'])) {
      if (rawUrl.isEmpty) return payload;
      final spiderHeaders =
          _extractPayloadHeaders(payload['header'] ?? payload['headers']);
      final parsed = await _resolveSecondaryPlayback(
        site,
        rawUrl,
        explicitPlayUrl: (payload['playUrl'] ?? '').toString(),
        parses: parses,
        rules: rules,
        ads: ads,
        extraHeaders: spiderHeaders,
      );
      if (parsed != null) {
        final parsedHeaders =
            _extractPayloadHeaders(parsed['header'] ?? parsed['headers']);
        final mergedHeaders = <String, String>{
          ...spiderHeaders,
          ...parsedHeaders,
        };
        payload
          ..addAll(parsed)
          ..['parse'] = 0
          ..['jx'] = 0;
        if (mergedHeaders.isNotEmpty) {
          payload['header'] = mergedHeaders;
        }
      }
    }
    return payload;
  }

  Future<CmsEpisode?> _tryResolveCloudShareTarget(
    CmsSite site,
    CmsEpisode episode,
    String candidateUrl, {
    List<CmsParse> parses = const [],
    List<CmsSniffRule> rules = const [],
    List<String> ads = const [],
  }) async {
    final trimmed = candidateUrl.trim();
    if (!trimmed.startsWith('mmshare://') &&
        !trimmed.toLowerCase().startsWith('push://') &&
        ResilientHttpClient.cloudProviderForShare(trimmed) == null) {
      return null;
    }
    final shareUrl = ResilientHttpClient.normalizeCloudShareUrl(trimmed);
    if (shareUrl == null) return null;
    final items = await _listCloudShare(shareUrl);
    if (items.isEmpty) {
      throw const FormatException('该网盘分享目录为空或已失效');
    }
    final wanted = episode.name.trim();
    const genericLabels = {
      '',
      '正片',
      '分享',
      '播放',
      '立即播放',
      '网盘',
      '4k',
      '原画',
    };
    CmsEpisode picked;
    final exactIdx = items.indexWhere((item) => item.name.trim() == wanted);
    if (exactIdx >= 0) {
      picked = items[exactIdx];
    } else if (items.length > 1 && !genericLabels.contains(wanted.toLowerCase())) {
      final matchedIdx = CspBridge.matchEpisodeIndexInLine(
        CmsLine(name: site.name, episodes: items),
        wanted,
        0,
      );
      picked = items[matchedIdx.clamp(0, items.length - 1)];
    } else {
      picked = items.first;
    }
    return resolveEpisodeForPlayback(
      site,
      picked,
      parses: parses,
      rules: rules,
      ads: ads,
    );
  }

  Future<CmsEpisode> _wrapAliMediaLease(CmsEpisode played) async {
    if (_http != null && _http is! ResilientHttpClient) return played;
    Uri? firstLeaseTarget;
    for (final v in played.variants) {
      final uri = Uri.tryParse(v.url);
      if (uri != null &&
          !uri.path.toLowerCase().endsWith('.m3u8') &&
          !uri.query.toLowerCase().contains('m3u8') &&
          CloudMediaLease.isTrustedAliMedia(uri)) {
        firstLeaseTarget = uri;
        break;
      }
    }
    if (firstLeaseTarget == null) {
      final mainUri = Uri.tryParse(played.url);
      if (mainUri != null &&
          !mainUri.path.toLowerCase().endsWith('.m3u8') &&
          !mainUri.query.toLowerCase().contains('m3u8') &&
          CloudMediaLease.isTrustedAliMedia(mainUri)) {
        firstLeaseTarget = mainUri;
      }
    }
    if (firstLeaseTarget == null) return played;
    final lease = await CloudMediaLease.open(
      target: firstLeaseTarget,
      provider: CloudMediaProvider.ali,
      headers: played.headers,
      isCancelled: _sourceCancelled,
      isCurrent: () async => true,
      client: _http is ResilientHttpClient
          ? CloudMediaLease.createDefaultMediaClient()
          : null,
    );
    final session = <String, Object>{'cloudMediaLease': lease};
    CmsEpisode mapVariant(CmsEpisode item) {
      final uri = Uri.tryParse(item.url);
      if (uri != null &&
          !uri.path.toLowerCase().endsWith('.m3u8') &&
          !uri.query.toLowerCase().contains('m3u8') &&
          CloudMediaLease.isTrustedAliMedia(uri)) {
        return CmsEpisode(
          name: item.name,
          url: lease.urlFor(uri).toString(),
          headers: const {},
          playbackSession: session,
        );
      }
      return CmsEpisode(
        name: item.name,
        url: item.url,
        headers: item.headers,
        playbackSession: session,
      );
    }

    final mappedVariants = played.variants.map(mapVariant).toList(growable: false);
    final primary = mappedVariants.isNotEmpty ? mappedVariants.first : mapVariant(played);
    return CmsEpisode(
      name: played.name,
      url: primary.url,
      headers: primary.headers,
      playbackSession: session,
      variants: mappedVariants,
    );
  }

  Future<CmsEpisode> resolveEpisodeForPlayback(
    CmsSite site,
    CmsEpisode episode, {
    List<CmsParse> parses = const [],
    List<CmsSniffRule> rules = const [],
    List<String> ads = const [],
  }) async {
    site = _resolveAdapterSite(site);
    if (episode.url.startsWith('mmshare://') ||
        episode.url.toLowerCase().startsWith('push://') ||
        ResilientHttpClient.cloudProviderForShare(episode.url) != null) {
      final shareResolved = await _tryResolveCloudShareTarget(
        site,
        episode,
        episode.url,
        parses: parses,
        rules: rules,
        ads: ads,
      );
      if (shareResolved != null) return shareResolved;
    }
    if (CloudShareClient.supportsEpisode(episode.url)) {
      final cloud = CloudShareClient(client: _http, credentialReader: _cloudCredential, isCancelled: _sourceCancelled);
      try { return await cloud.resolve(episode); } finally { cloud.close(); }
    }
    if (AliShareClient.supportsEpisode(episode.url)) {
      final cloud = AliShareClient(client: _http, credentialReader: _cloudCredential, isCancelled: _sourceCancelled,
          credentialWriter: (provider, value) async =>
              (await StorageService.init()).setNetdiskCredential(provider, value));
      late final CmsEpisode played;
      try { played = await cloud.resolve(episode); } finally { cloud.close(); }
      return _wrapAliMediaLease(played);
    }
    if (episode.url.startsWith('mmquark://')) {
      final drive = _quark ?? QuarkDriveClient(
          accounts: (await StorageService.init()).quarkAccounts, httpClient: _http, isCancelled: _sourceCancelled);
      try { return await drive.resolve(episode); }
      finally { if (_quark == null) drive.close(); }
    }
    if (episode.url.startsWith('mmwogg://quark?')) {
      final drive = _quark ?? QuarkDriveClient(
          accounts: (await StorageService.init()).quarkAccounts, httpClient: _http, isCancelled: _sourceCancelled);
      try { return await drive.resolveWoggShare(episode); }
      finally { if (_quark == null) drive.close(); }
    }
    if (episode.isGatewayEpisode) {
      if (!_usesSpiderGateway(site) &&
          !SpiderPluginRegistry.instance.gatewayConfig.isActive) {
        throw const FormatException('蜘蛛网关未启用，无法解析该线路播放地址');
      }
      final parameters = Uri.parse(episode.url).queryParameters;
      final raw = jsonDecode(
        await _callSpiderGateway(site, 'play', {
          'flag': parameters['flag'] ?? '',
          'id': parameters['id'] ?? '',
        }),
      );
      if (raw is! Map) throw const FormatException('蜘蛛网关没有返回有效的播放地址');
      final payloadUrl = raw['url'];
      if (payloadUrl is String) {
        final shareResolved = await _tryResolveCloudShareTarget(
          site,
          episode,
          payloadUrl,
          parses: parses,
          rules: rules,
          ads: ads,
        );
        if (shareResolved != null) return shareResolved;
      }
      final payload = await _maybeUnwrapSpiderPayload(
        site,
        raw,
        parses: parses,
        rules: rules,
        ads: ads,
      );
      return SourcePlayback.decode(
        payload,
        episode,
        localUrl: _scriptHost.resolve,
        sourceHeaders: site.headers,
        sourceOrigin: _sourceCredentialOrigin(site),
      );
    }
    if (WoggSource.supports(site)) {
      throw const FormatException('请刷新详情以读取原始网盘线路，旧缓存不能用于此源');
    }
    if (_usesJs(site) && !episode.isScriptEpisode) {
      throw const FormatException('请刷新详情以读取原始插件线路，旧缓存不能用于此源');
    }
    // A verified Quark share has its own resolver. Ordinary cached HTTP lines
    // still require the original source adapter and cannot masquerade as it.
    _requireSourceAdapter(site);
    if (_isHttpT4(site) && episode.url.startsWith('mmt4://play?')) {
      final parameters = Uri.parse(episode.url).queryParameters;
      final raw = jsonDecode(await _callT4(site,
        {'play': parameters['id'] ?? '', 'flag': parameters['flag'] ?? ''}));
      if (raw is! Map) throw const FormatException('T4 没有返回播放结果');
      final payloadUrl = raw['url'];
      if (payloadUrl is String) {
        final shareResolved = await _tryResolveCloudShareTarget(
          site,
          episode,
          payloadUrl,
          parses: parses,
          rules: rules,
          ads: ads,
        );
        if (shareResolved != null) return shareResolved;
      }
      final payload = await _maybeUnwrapSpiderPayload(
        site,
        raw,
        parses: parses,
        rules: rules,
        ads: ads,
      );
      return SourcePlayback.decode(payload, episode, localUrl: _scriptHost.resolve,
        sourceHeaders: site.headers, sourceOrigin: _sourceCredentialOrigin(site));
    }
    if (site.isCatPaw && episode.url.startsWith('mmpaw://play?')) {
      final parameters = Uri.parse(episode.url).queryParameters;
      final raw = jsonDecode(await _getText(_appendQuery(site.api,
        {'play':parameters['id'] ?? '', 'flag':parameters['flag'] ?? ''}).toString()));
      if (raw is! Map) throw const FormatException('CatPaw 没有返回播放结果');
      final payloadUrl = raw['url'];
      if (payloadUrl is String) {
        final shareResolved = await _tryResolveCloudShareTarget(
          site,
          episode,
          payloadUrl,
          parses: parses,
          rules: rules,
          ads: ads,
        );
        if (shareResolved != null) return shareResolved;
      }
      final payload = await _maybeUnwrapSpiderPayload(
        site,
        raw,
        parses: parses,
        rules: rules,
        ads: ads,
      );
      return SourcePlayback.decode(payload,episode,localUrl:CatPawHost.instance.resolve,sourceHeaders:site.headers,sourceOrigin:_sourceCredentialOrigin(site));
    }
    if (site.isEmby && episode.url.startsWith('mmemby://play?')) {
      return (await EmbyLibrary.open(site)).resolve(episode);
    }
    if (_usesJs(site) && episode.isScriptEpisode) {
      final params = Uri.parse(episode.url).queryParameters;
      final raw = jsonDecode(await _callJs(site, 'play', [params['flag'], params['id'], []]));
      if (raw is! Map) throw const FormatException('脚本没有返回播放地址');
      final payloadUrl = raw['url'];
      if (payloadUrl is String) {
        final shareResolved = await _tryResolveCloudShareTarget(
          site,
          episode,
          payloadUrl,
          parses: parses,
          rules: rules,
          ads: ads,
        );
        if (shareResolved != null) return shareResolved;
      }
      final payload = await _maybeUnwrapSpiderPayload(
        site,
        raw,
        parses: parses,
        rules: rules,
        ads: ads,
      );
      final resolved = await SourcePlayback.decode(payload, episode,
          localUrl: _scriptHost.resolve,
          // A plugin's import headers are not the adapted media server's
          // credentials. The reviewed adapter returns explicit playback headers.
          sourceHeaders: GuardSource.supports(site) ? const {} : site.headers,
          sourceOrigin: GuardSource.supports(site) ? null : _sourceCredentialOrigin(site));
      return _localScriptPlaybackHeaders(site, resolved);
    }
    var resolved = await CspBridge.resolveEpisodeForPlayback(site, episode, _getText);
    if (resolved.url != episode.url &&
        (resolved.url.startsWith('mmshare://') ||
            resolved.url.toLowerCase().startsWith('push://') ||
            ResilientHttpClient.cloudProviderForShare(resolved.url) != null)) {
      final shareResolved = await _tryResolveCloudShareTarget(
        site,
        resolved,
        resolved.url,
        parses: parses,
        rules: rules,
        ads: ads,
      );
      if (shareResolved != null) return shareResolved;
    }
    final unsupportedPushOrShare = _unsupportedPushOrShareReason(resolved.url);
    final resolvedUri = Uri.tryParse(resolved.url);
    final ownedLocalProxy = resolvedUri != null &&
        (JsSourceHost.ownsProxyUrl(_scriptSessionKey(site), resolvedUri) ||
            _pythonHost.ownsProxyUrl(_scriptSessionKey(site), resolvedUri) ||
            CatPawHost.matches(resolved.url));
    if (unsupportedPushOrShare == null &&
        !_isDirectStreamUrl(resolved.url) &&
        !ownedLocalProxy &&
        (site.playUrl.isNotEmpty ||
            parses.isNotEmpty ||
            WebMediaResolver.looksLikeWebPlayerPageUrl(resolved.url))) {
      final parsed = await _resolveSecondaryPlayback(
        site,
        resolved.url,
        parses: parses,
        rules: rules,
        ads: ads,
        extraHeaders: resolved.headers,
      );
      if (parsed != null) {
        resolved = await SourcePlayback.decode(
          parsed,
          resolved,
          localUrl: _scriptHost.resolve,
          sourceHeaders: site.headers,
          sourceOrigin: _sourceCredentialOrigin(site),
        );
      } else if (!resolved.isDirectPlayable) {
        throw const FormatException('未能从网页或解析接口提取可播放视频流，请切换其他线路');
      }
    } else if (!resolved.isDirectPlayable && !ownedLocalProxy) {
      final blockReason = unsupportedPushOrShare ??
          WebMediaResolver.episodeUnavailableReason(
            resolved,
            site: site,
            parses: parses,
          );
      throw FormatException(blockReason ?? '当前剧集缺少可用解析配置，请切换其他线路');
    }
    return SourcePlayback.inheritSourceHeaders(resolved,
        sourceHeaders: site.headers, sourceOrigin: _sourceCredentialOrigin(site));
  }

  static String? _unsupportedPushOrShareReason(String rawUrl) {
    final trimmed = rawUrl.trim();
    final lower = trimmed.toLowerCase();
    if (lower.startsWith('mmshare://')) {
      var inner = trimmed.substring('mmshare://'.length).trim();
      if (inner.contains('%')) {
        try {
          inner = Uri.decodeFull(inner);
        } on ArgumentError {
          // Keep raw string when percent-encoding is malformed.
        }
      }
      final innerLower = inner.toLowerCase();
      if (innerLower.startsWith('magnet:') ||
          innerLower.startsWith('ed2k://') ||
          innerLower.startsWith('thunder://')) {
        return '当前剧集为磁力 / P2P 下载链接，暂不支持直接播放';
      }
      return '当前剧集返回了不受支持的网盘分享链接，仅支持夸克、UC、百度与阿里云盘';
    }
    if (lower.startsWith('push://')) {
      var inner = trimmed.substring('push://'.length).trim();
      if (inner.contains('%')) {
        try {
          inner = Uri.decodeFull(inner);
        } on ArgumentError {
          // Keep raw string when percent-encoding is malformed.
        }
      }
      final innerLower = inner.toLowerCase();
      if (innerLower.isEmpty) {
        return '当前剧集返回的推送链接（push://）为空，请切换其他线路';
      }
      if (innerLower.startsWith('magnet:') ||
          innerLower.startsWith('ed2k://') ||
          innerLower.startsWith('thunder://')) {
        return '当前剧集为磁力 / P2P 推送链接（push://），暂不支持直接播放';
      }
      return '当前剧集为外部推送链接（push://），目标网盘或协议暂不支持直接播放';
    }
    return null;
  }

  CmsEpisode _localScriptPlaybackHeaders(CmsSite site, CmsEpisode episode) {
    final headers = Map<String, String>.of(episode.headers);
    final uri = Uri.tryParse(episode.url);
    if (uri != null && (JsSourceHost.ownsProxyUrl(_scriptSessionKey(site), uri) ||
        _pythonHost.ownsProxyUrl(_scriptSessionKey(site), uri))) {
      String? origin;
      final connectionHeaders = <String>{};
      for (final entry in headers.entries) {
        if (entry.key.toLowerCase() == 'origin') origin = entry.value;
        if (entry.key.toLowerCase() == 'connection') {
          connectionHeaders.addAll(entry.value.toLowerCase().split(',').map((v) => v.trim()));
        }
      }
      headers.removeWhere((key, _) => const {
        'origin', 'host', 'content-length', 'connection', 'keep-alive',
        'proxy-connection', 'transfer-encoding', 'te', 'trailer', 'upgrade',
      }.contains(key.toLowerCase()) || connectionHeaders.contains(key.toLowerCase()));
      // The listener rejects browser Origin headers. Preserve the source's
      // upstream value as private transport metadata for its own callback.
      if (origin != null) {
        headers.removeWhere((key, _) => key.toLowerCase() == 'x-marcomovie-proxy-origin');
        headers['X-MarcoMovie-Proxy-Origin'] = origin;
      }
    }
    return CmsEpisode(name: episode.name, url: episode.url, headers: headers,
        playbackSession: episode.playbackSession, externalAudioUrl: episode.externalAudioUrl,
        variants: episode.variants.map((e) => _localScriptPlaybackHeaders(site, e)).toList());
  }
  CmsEpisode resolveLiveEpisodeForPlayback(CmsSite site, CmsEpisode episode) =>
      _localScriptPlaybackHeaders(site, SourcePlayback.inheritSourceHeaders(episode,
        sourceHeaders: site.headers, sourceOrigin: _sourceCredentialOrigin(site)));

  Future<List<LiveGroup>> fetchLiveGroups(LiveSource source) async {
    final u = source.url.trim();
    String raw;
    String origin = source.origin;
    var playbackHeaders = source.headers;
    if (source.inlineContent.isNotEmpty) {
      raw = source.inlineContent;
    } else if (source.plugin != null) {
      if (!_usesJs(source.playbackSite)) {
        throw const FormatException('这条直播线路的插件尚未适配当前设备，请选择其他直播来源');
      }
      raw = await _callJs(source.playbackSite, 'liveContent', [u]);
      origin = _sourceCredentialOrigin(source.playbackSite)?.toString() ?? origin;
    } else if (u.startsWith('data:')) {
      final b64Idx = u.indexOf('base64,');
      if (b64Idx < 0) throw const FormatException('内嵌直播列表格式无效');
      final b64 = u.substring(b64Idx + 7).trim();
      if (b64.length > maxResponseBytes * 4 ~/ 3 + 4) throw const FormatException('直播列表超过 16 MB');
      raw = utf8.decode(base64Decode(b64), allowMalformed: true);
    } else {
      final targetUrl =
          LiveCatalogParser.directoryUrl(u, origin: origin) ?? u;
      if (LiveCatalogParser.isLocalPluginProxy(targetUrl)) {
        throw const FormatException('该直播线路依赖本地代理插件，当前设备暂不支持，请切换其他直播源');
      }
      raw = CmsParser.decodeConfigDocument(await _getBytes(targetUrl, headers: source.headers,
        onResponse: (uri, headers) {
          origin = uri.toString();
          playbackHeaders = headers..removeWhere((key, _) =>
              key.toLowerCase() == 'accept' && !source.headers.keys.any((k) => k.toLowerCase() == 'accept'));
        }));
    }
    final groups = CmsParser.parseLivePlaylist(raw, origin: origin, headers: playbackHeaders);
    if (groups.isEmpty) throw const FormatException('来源未返回可播放的直播频道，请重试或切换直播来源');
    return groups;
  }
  Stream<(CmsSite, List<CmsVideo>)> searchAcrossSites(
    List<CmsSite> sites,
    String keyword, {
    int maxConcurrency = defaultSearchConcurrency,
    void Function(CmsSite site, Object error)? onSourceError,
  }) {
    late final StreamController<(CmsSite, List<CmsVideo>)> controller;
    bool cancelled = false;
    final requests = <Completer<void>>{};
    controller = StreamController<(CmsSite, List<CmsVideo>)>(
      onCancel: () {
        cancelled = true;
        for (final request in requests) {
          if (!request.isCompleted) request.complete();
        }
      },
    );
    final seenBackends = <String>{};
    final runnableSites = <CmsSite>[];
    for (final s in sites) {
      if (!s.supported || !s.searchable) continue;
      if (CspBridge.isDoubanSite(s) ||
          CspBridge.isMyDriveSite(s) ||
          CspBridge.isHuyaSite(s) ||
          CspBridge.isDouyuSite(s)) {
        continue;
      }
      if (CspBridge.canHandleSite(s)) {
        final backends = CspBridge.backendsForSite(s);
        final nativeAdapter = _usesJs(s) || s.usesAdapterPack || s.usesSpiderGateway || CspRuleEngines.supports(s) || CspBridge.isBiliSite(s) || CspBridge.isFirstAidSite(s) || CspBridge.isTuxiaobeiSite(s);
        if (!nativeAdapter && backends.isEmpty) continue;
        final String sig;
        if (_usesJs(s) || s.usesAdapterPack || s.usesSpiderGateway) {
          // The same plugin key in two subscriptions can have different
          // artifacts, extensions and credentials. They are separate sources.
          sig = jsonEncode([s.subscriptionId, s.key, s.api, s.ext,
            s.pluginReference, s.headers, s.usesAdapterPack, s.usesSpiderGateway]);
        } else if (CspRuleEngines.supports(s)) {
          sig = jsonEncode(['csp_rule', s.subscriptionId, s.key, s.api, s.ext]);
        } else if (CspBridge.isBiliSite(s)) {
          sig = 'csp_bili_search';
        } else if (CspBridge.isFirstAidSite(s)) {
          sig = 'csp_firstaid_search';
        } else if (CspBridge.isTuxiaobeiSite(s)) {
          sig = 'csp_tuxiaobei_search';
        } else {
          sig = backends.first.api;
        }
        if (!seenBackends.add(sig)) continue;
      } else {
        if (!seenBackends.add(s.api)) continue;
      }
      runnableSites.add(s);
    }
    if (runnableSites.isEmpty || keyword.trim().isEmpty) {
      controller.close();
      return controller.stream;
    }
    final concurrency = maxConcurrency.clamp(1, 12);
    int nextIndex = 0;
    int inFlight = 0;
    void pump() {
      if (cancelled || controller.isClosed) return;
      while (!cancelled &&
          !controller.isClosed &&
          inFlight < concurrency &&
          nextIndex < runnableSites.length) {
        final site = runnableSites[nextIndex++];
        inFlight++;
        final abort = Completer<void>();
        requests.add(abort);
        final perSiteTimeout = Duration(
          seconds: (_usesJs(site) || site.isCatPaw) ? 20 : 12,
        );
        runZoned(() => fetchSearch(site, keyword), zoneValues: {_cancelKey: abort})
            .timeout(perSiteTimeout)
            .then((listing) {
          if (!cancelled && !controller.isClosed && listing.videos.isNotEmpty) {
            controller.add((site, listing.videos));
          }
        }).catchError((Object error) {
          if (!cancelled && !controller.isClosed) onSourceError?.call(site, error);
        }).whenComplete(() {
          if (!abort.isCompleted) abort.complete();
          requests.remove(abort);
          inFlight--;
          if (cancelled || controller.isClosed) return;
          if (nextIndex < runnableSites.length) {
            pump();
          } else if (inFlight <= 0 && !controller.isClosed) {
            controller.close();
          }
        });
      }
    }
    pump();
    return controller.stream;
  }
}
