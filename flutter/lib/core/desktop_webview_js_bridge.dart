import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'script_proxy_protocol.dart';
import 'script_proxy_server.dart';

typedef DesktopWebViewHttpHandler =
    Future<Map<String, dynamic>> Function(
      String url,
      Map<String, dynamic> options, {
      String? entryOrigin,
      Map<String, String> sourceHeaders,
      bool catvod,
      Duration budget,
    });

/// Windows Edge WebView2 off-screen async JS / DRPY2 fallback bridge.
///
/// Communicates with the native C++ plugin over `marco_movie/webview_js` using
/// `PostWebMessageAsJson` / `WebMessageReceived` and bridges spider `req()` HTTP
/// requests back to Dart so proxy, DOH, redirect isolation, and custom headers
/// stay consistent with [JsSourceHost].
class DesktopWebViewJsBridge {
  static const MethodChannel channel = MethodChannel('marco_movie/webview_js');
  static const MethodChannel snifferChannel = MethodChannel(
    'marco_movie/web_sniffer',
  );
  static const int maxBytes = 6 * 1024 * 1024;

  static DesktopWebViewJsBridge instance = DesktopWebViewJsBridge();

  DesktopWebViewJsBridge({
    MethodChannel? jsChannel,
    MethodChannel? webSnifferChannel,
    this.httpHandler,
  }) : _channel = jsChannel ?? channel,
       _snifferChannel = webSnifferChannel ?? snifferChannel;

  final MethodChannel _channel;
  final MethodChannel _snifferChannel;

  /// Optional test hook to simulate Windows in headless cross-platform tests.
  static bool? debugForcePlatformSupported;

  /// Optional HTTP handler override (defaults to Dart [HttpClient] transport).
  DesktopWebViewHttpHandler? httpHandler;

  bool _handlerAttached = false;
  bool? _cachedAvailable;
  int _nextCallId = 0;
  ScriptProxyServer? _proxyServer;
  final _sessions = <String, _WebViewSessionContext>{};
  final _playbackPins = <String, Set<Object>>{};

  static bool get _isPlatformSupported =>
      debugForcePlatformSupported ??
      (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows);

  /// Returns `true` when [error] from QuickJS indicates a missing browser API
  /// (`window`, `document`, `DOMParser`, `crypto.subtle`, `fetch`, `TextEncoder`,
  /// `localStorage`, ES2022+ syntax, or async top-level capability).
  ///
  /// Explicitly rejects timeouts, user cancellations, CatVod host boundaries,
  /// result-size rejections, and plain user string/object throws.
  static bool shouldFallbackFromError(Object error) {
    if (error is TimeoutException) return false;
    final msg = error.toString();
    if (msg.isEmpty) return false;
    final lower = msg.toLowerCase();
    if (lower.contains('脚本操作已取消') ||
        lower.contains('脚本会话已失效') ||
        lower.contains('脚本会话已关闭') ||
        lower.contains('脚本请求超时') ||
        lower.contains('等待脚本运行环境超时') ||
        lower.contains('脚本不能覆盖内置宿主模块') ||
        lower.contains('当前脚本需要 catvod 宿主模块') ||
        lower.contains('脚本结果过大') ||
        lower.contains('commonjs 不提供 node 内置模块') ||
        lower.contains('脚本依赖未加载') ||
        lower.contains('单次脚本操作的网络请求过多')) {
      return false;
    }

    const browserSignals = <String>[
      'domparser',
      'crypto.subtle',
      'subtle',
      'document',
      'localstorage',
      'sessionstorage',
      'navigator',
      'htmlelement',
      'xmlserializer',
      'textencoder',
      'textdecoder',
      'urlsearchparams',
      'abortcontroller',
      'formdata',
      'matchmedia',
      'webassembly',
      'referenceerror',
      'syntaxerror',
      'not defined',
      'unexpected token',
      'unexpected identifier',
      'drpy rule 需要对应宿主适配',
    ];
    for (final signal in browserSignals) {
      if (lower.contains(signal)) return true;
    }
    if (lower.contains('typeerror') &&
        (lower.contains('subtle') ||
            lower.contains('crypto') ||
            lower.contains('document') ||
            lower.contains('domparser') ||
            lower.contains('fetch') ||
            lower.contains('textencoder') ||
            lower.contains('url') ||
            lower.contains('cannot read propert') ||
            lower.contains('not a function'))) {
      return true;
    }
    return false;
  }

  static bool get _inFlutterTest => Platform.environment.containsKey('FLUTTER_TEST');

  Future<T?> _withOptionalTimeout<T>(Future<T?> future) {
    if (_inFlutterTest) return future;
    return future.timeout(const Duration(seconds: 2), onTimeout: () => null);
  }

  /// Queries whether Edge WebView2 Runtime is available on this Windows host.
  /// Never throws on stripped Windows LTSC systems or missing plugin handlers.
  Future<bool> isAvailable({bool refresh = false}) async {
    if (!_isPlatformSupported) return false;
    if (!refresh && _cachedAvailable != null) return _cachedAvailable!;
    try {
      final result = await _withOptionalTimeout(
        _channel.invokeMethod<bool>('isAvailable'),
      );
      _cachedAvailable = result == true;
      return _cachedAvailable!;
    } on MissingPluginException {
      _cachedAvailable = false;
      return false;
    } on PlatformException {
      _cachedAvailable = false;
      return false;
    } catch (_) {
      _cachedAvailable = false;
      return false;
    }
  }

  /// Queries detailed Edge WebView2 JS engine status for settings/diagnostics UI.
  Future<Map<String, dynamic>> getStatus() async {
    if (!_isPlatformSupported) {
      return const {'available': false, 'reason': 'unsupported_platform'};
    }
    try {
      final raw = await _withOptionalTimeout(
        _channel.invokeMapMethod<String, dynamic>('getStatus'),
      );
      if (raw == null) {
        return const {'available': false, 'reason': 'webview2_unavailable'};
      }
      _cachedAvailable = raw['available'] == true;
      return raw;
    } on MissingPluginException {
      _cachedAvailable = false;
      return const {'available': false, 'reason': 'missing_plugin'};
    } on PlatformException catch (e) {
      _cachedAvailable = false;
      return {'available': false, 'reason': e.code};
    } catch (_) {
      _cachedAvailable = false;
      return const {'available': false, 'reason': 'unknown_error'};
    }
  }

  /// Queries detailed Edge WebView2 Stage-3 sniffer status for settings UI.
  Future<Map<String, dynamic>> getSnifferStatus() async {
    if (!_isPlatformSupported) {
      return const {'available': false, 'reason': 'unsupported_platform'};
    }
    try {
      final raw = await _withOptionalTimeout(
        _snifferChannel.invokeMapMethod<String, dynamic>('getStatus'),
      );
      return raw ?? const {'available': false, 'reason': 'webview2_unavailable'};
    } on MissingPluginException {
      return const {'available': false, 'reason': 'missing_plugin'};
    } on PlatformException catch (e) {
      return {'available': false, 'reason': e.code};
    } catch (_) {
      return const {'available': false, 'reason': 'unknown_error'};
    }
  }

  void _ensureHttpBridgeAttached() {
    if (_handlerAttached) return;
    _handlerAttached = true;
    _channel.setMethodCallHandler((MethodCall call) async {
      if (call.method == 'httpRequest') {
        final args = call.arguments is Map
            ? Map<String, dynamic>.from(call.arguments as Map)
            : const <String, dynamic>{};
        return _handleNativeHttpRequest(args);
      }
      throw MissingPluginException('Method ${call.method} not implemented');
    });
  }

  Future<Map<String, dynamic>> _handleNativeHttpRequest(
    Map<String, dynamic> args,
  ) async {
    final url = (args['url'] ?? '').toString();
    final sessionId = (args['sessionId'] ?? '').toString();
    final catvod = args['catvod'] == true;
    final options = args['options'] is Map
        ? Map<String, dynamic>.from(args['options'] as Map)
        : const <String, dynamic>{};
    final ctx = _sessions[sessionId];
    final entryOrigin = ctx?.entry;
    final sourceHeaders = ctx?.headers ?? const <String, String>{};
    final budget = ctx?.budget ?? const Duration(seconds: 15);

    if (httpHandler != null) {
      return httpHandler!(
        url,
        options,
        entryOrigin: entryOrigin,
        sourceHeaders: sourceHeaders,
        catvod: catvod,
        budget: budget,
      );
    }
    return executeHttpRequest(
      url: url,
      options: options,
      entryOrigin: entryOrigin,
      sourceHeaders: sourceHeaders,
      catvod: catvod,
      budget: budget,
    );
  }

  bool ownsProxyUrl(String sessionKey, Uri uri) {
    final ctx = _sessions[sessionKey];
    final proxy = ctx?.proxy;
    if (ctx == null ||
        ctx.closed ||
        proxy == null ||
        !proxy.isActive ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment ||
        uri.scheme != proxy.url.scheme ||
        uri.host != proxy.url.host ||
        uri.port != proxy.url.port) {
      return false;
    }
    final path = uri.pathSegments;
    final expected = proxy.url.pathSegments;
    return path.length >= 3 &&
        path[0] == expected[0] &&
        path[1] == expected[1] &&
        !path.any(
          (part) =>
              part == '.' ||
              part == '..' ||
              RegExp(
                r'[/\\\x00-\x1f\x7f]|%(?:2e|2f|5c|00)',
                caseSensitive: false,
              ).hasMatch(part),
        );
  }

  void Function() pinForPlayback(String sessionKey) {
    final pins = _playbackPins.putIfAbsent(sessionKey, () => <Object>{});
    final token = Object();
    pins.add(token);
    return () {
      if (!pins.remove(token)) return;
      if (pins.isEmpty && identical(_playbackPins[sessionKey], pins)) {
        _playbackPins.remove(sessionKey);
      }
    };
  }

  Future<void> retainSessions(Set<String> keys) async {
    _playbackPins.removeWhere((k, _) => !keys.contains(k));
    final removed = _sessions.keys.where((k) => !keys.contains(k)).toList();
    for (final k in removed) {
      await disposeSession(k);
    }
  }

  Future<void> disposeSession(String sessionKey) async {
    final ctx = _sessions.remove(sessionKey);
    if (ctx == null) return;
    ctx.closed = true;
    await ctx.proxy?.unregister();
    if (!_isPlatformSupported) return;
    try {
      await _withOptionalTimeout(
        _channel.invokeMethod<dynamic>('evalSpider', <String, dynamic>{
          'callId': 'dispose_${++_nextCallId}',
          'action': 'disposeSession',
          'type': 'disposeSession',
          'sessionId': sessionKey,
          'timeoutMs': 2000,
        }),
      );
    } catch (_) {}
  }

  Future<void> sleep() async {
    if (!_isPlatformSupported) return;
    try {
      await _withOptionalTimeout(_channel.invokeMethod<dynamic>('sleep'));
    } catch (_) {}
  }

  Future<void> closeAll() async {
    final server = _proxyServer;
    _proxyServer = null;
    final hadActivity =
        _handlerAttached || _sessions.isNotEmpty || _cachedAvailable == true;
    await retainSessions({});
    if (hadActivity) {
      await sleep();
    }
    await server?.close();
  }

  Future<String?> callCached({
    required String sessionKey,
    required String method,
    required List<Object?> arguments,
    Duration budget = const Duration(seconds: 15),
    Completer<void>? cancellation,
  }) async {
    final ctx = _sessions[sessionKey];
    if (ctx == null || ctx.closed) return null;
    return invoke(
      entry: ctx.entry,
      modules: ctx.modules,
      method: method,
      arguments: arguments,
      extension: ctx.extension,
      rawExtension: ctx.rawExtension,
      headers: ctx.headers,
      budget: budget,
      sessionKey: sessionKey,
      catDetails: ctx.catDetails,
      cancellation: cancellation,
      loadModules: false,
    );
  }

  Future<String> invoke({
    required String entry,
    required Map<String, String> modules,
    required String method,
    required List<Object?> arguments,
    Object? extension,
    String? rawExtension,
    Map<String, String> headers = const {},
    Duration budget = const Duration(seconds: 15),
    String? sessionKey,
    bool catDetails = false,
    Completer<void>? cancellation,
    bool loadModules = true,
  }) async {
    if (cancellation?.isCompleted == true) {
      throw StateError('脚本操作已取消');
    }
    if (!await isAvailable()) {
      throw StateError('Edge WebView2 运行环境不可用');
    }
    _ensureHttpBridgeAttached();

    final effectiveSessionId = sessionKey ?? 'oneshot_${++_nextCallId}';
    _WebViewSessionContext? ctx = sessionKey != null
        ? _sessions[sessionKey]
        : null;

    var shouldSendModules = loadModules || ctx == null;
    if (ctx == null) {
      final server = _proxyServer ??= ScriptProxyServer();
      final proxy = await server.register((request) async {
        final params = <String, String>{
          for (final e in request.queryParametersAll.entries)
            e.key: e.value.last,
          ...request.headers,
        };
        final upstreamOrigin = params.remove('x-marcomovie-proxy-origin');
        if (upstreamOrigin != null) params['origin'] = upstreamOrigin;
        if (request.path != '/proxy') {
          params.putIfAbsent('path', () => request.path);
        }
        final result = await callCached(
          sessionKey: effectiveSessionId,
          method: 'proxy',
          arguments: [params],
          budget: const Duration(seconds: 18),
          cancellation: request.cancellation,
        );
        if (result == null) {
          throw StateError('脚本代理会话已关闭');
        }
        return ScriptProxyProtocol.decode(result);
      });
      final proxyBase = proxy.url.replace(
        queryParameters: {'do': 'js', 'siteKey': proxy.url.pathSegments[1]},
      );
      ctx = _WebViewSessionContext(
        entry: entry,
        modules: Map<String, String>.from(modules),
        extension: extension,
        rawExtension: rawExtension,
        headers: Map<String, String>.from(headers),
        catDetails: catDetails,
        proxy: proxy,
        proxyBase: proxyBase.toString(),
        budget: budget,
      );
      if (sessionKey != null) {
        _sessions[sessionKey] = ctx;
      }
      shouldSendModules = true;
    } else {
      ctx.budget = budget;
    }

    final hostBundle = await _loadBootstrapScripts();
    final callId = 'wv_${++_nextCallId}';
    final adaptedArgs = catDetails && method == 'detail'
        ? <Object?>[arguments]
        : arguments;

    final payload = <String, dynamic>{
      'callId': callId,
      'action': 'eval',
      'sessionId': effectiveSessionId,
      'entry': ctx.entry,
      'method': method,
      'arguments': adaptedArgs,
      'extension': ctx.extension,
      if (ctx.rawExtension != null) 'rawExtension': ctx.rawExtension,
      'proxyBase': ctx.proxyBase,
      'timeoutMs': budget.inMilliseconds,
      'cryptoJs': hostBundle.cryptoJs,
      'hostScript': hostBundle.hostScript,
      if (shouldSendModules) 'modules': ctx.modules,
    };

    try {
      final invokeFuture = _channel.invokeMapMethod<String, dynamic>(
        'evalSpider',
        payload,
      );
      Map<String, dynamic>? response;
      if (cancellation != null) {
        response = await Future.any<Map<String, dynamic>?>([
          invokeFuture,
          cancellation.future.then<Map<String, dynamic>?>(
            (_) => throw StateError('脚本操作已取消'),
          ),
        ]).timeout(
          budget + const Duration(seconds: 2),
          onTimeout: () => throw TimeoutException('WebView2 JS 调用超时'),
        );
      } else {
        response = await invokeFuture.timeout(
          budget + const Duration(seconds: 2),
          onTimeout: () => throw TimeoutException('WebView2 JS 调用超时'),
        );
      }
      if (cancellation?.isCompleted == true) {
        throw StateError('脚本操作已取消');
      }
      if (response == null || response['available'] == false) {
        throw StateError('Edge WebView2 运行环境不可用');
      }
      if (response['ok'] != true) {
        final err = (response['error'] ?? 'WebView2 脚本执行失败').toString();
        throw StateError(err);
      }
      final text = (response['result'] ?? '').toString();
      final resultLimit = method == 'proxy'
          ? 8 * 1024 * 1024 + 32 * 1024
          : maxBytes;
      if (utf8.encode(text).length > resultLimit) {
        throw const FormatException('脚本结果过大');
      }
      return text;
    } finally {
      if (sessionKey == null) {
        ctx.closed = true;
        await ctx.proxy?.unregister();
      }
    }
  }

  /// Executes an HTTP request on behalf of the off-screen WebView2 JS host,
  /// matching [JsSourceHost]'s redirect isolation, header merging, and size caps.
  static Future<Map<String, dynamic>> executeHttpRequest({
    required String url,
    Map<String, dynamic> options = const {},
    String? entryOrigin,
    Map<String, String> sourceHeaders = const {},
    bool catvod = false,
    Duration budget = const Duration(seconds: 15),
  }) async {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      throw const FormatException('脚本网络请求只支持 HTTP/HTTPS');
    }

    var remaining = budget;
    final reqTimeout = num.tryParse((options['timeout'] ?? '').toString());
    if (reqTimeout != null && reqTimeout.isFinite && reqTimeout > 0) {
      final d = Duration(milliseconds: reqTimeout.ceil());
      if (d < remaining) remaining = d;
    }
    if (catvod && options['callTimeout'] is num) {
      final d = Duration(milliseconds: (options['callTimeout'] as num).toInt());
      if (d < remaining) remaining = d;
    }
    if (remaining <= Duration.zero) {
      throw TimeoutException('脚本请求超时');
    }

    var verb = (options['method'] ?? 'GET').toString().toUpperCase();
    if (!<String>[
      'GET',
      'POST',
      'HEAD',
      'PUT',
      'PATCH',
      'DELETE',
      if (catvod) 'OPTIONS',
    ].contains(verb)) {
      throw const FormatException('脚本请求方法暂不支持');
    }

    final requestHeaders = <String, String>{'user-agent': 'okhttp/3.15'};
    final origin = entryOrigin != null ? Uri.tryParse(entryOrigin) : null;
    bool sameOrigin(Uri a, Uri b) =>
        a.scheme == b.scheme &&
        a.host.toLowerCase() == b.host.toLowerCase() &&
        a.port == b.port;
    if (origin != null && sameOrigin(origin, uri)) {
      sourceHeaders.forEach(
        (key, value) => requestHeaders[key.toLowerCase()] = value,
      );
    }
    if (options['headers'] is Map) {
      (options['headers'] as Map).forEach((k, v) {
        requestHeaders[k.toString().toLowerCase()] = v.toString();
      });
    }
    if (uri.userInfo.isNotEmpty) {
      requestHeaders.putIfAbsent(
        'authorization',
        () =>
            'Basic ${base64Encode(utf8.encode(Uri.decodeComponent(uri.userInfo)))}',
      );
    }

    final body = options['data'] ?? options['body'];
    List<int>? payload;
    if (options['bodyBase64'] is String) {
      payload = base64Decode(options['bodyBase64'] as String);
    } else if (body != null) {
      payload = utf8.encode(body is String ? body : jsonEncode(body));
    }
    if (payload != null && payload.length > maxBytes) {
      throw const FormatException('脚本请求体过大');
    }

    final client = HttpClient()..connectionTimeout = const Duration(seconds: 4);
    HttpClientRequest? active;
    final timer = Timer(remaining, () {
      active?.abort(TimeoutException('脚本请求超时'));
      client.close(force: true);
    });
    try {
      var current = uri.replace(userInfo: '').removeFragment();
      for (var hop = 0; hop <= 8; hop++) {
        final req = active = await client.openUrl(verb, current);
        req.followRedirects = false;
        requestHeaders.forEach(req.headers.set);
        if (payload != null) req.add(payload);
        final response = await req.close();
        if (response.contentLength > maxBytes) {
          throw const FormatException('脚本响应超过 6 MB');
        }
        final bytes = <int>[];
        await for (final chunk in response) {
          if (bytes.length + chunk.length > maxBytes) {
            throw const FormatException('脚本响应超过 6 MB');
          }
          bytes.addAll(chunk);
        }
        final code = response.statusCode;
        final location = response.headers.value(HttpHeaders.locationHeader);
        if (options['redirect'] != 0 &&
            location != null &&
            const [301, 302, 303, 307, 308].contains(code)) {
          if (hop == 8) throw const HttpException('脚本请求重定向过多');
          final next = current
              .resolve(location)
              .replace(userInfo: '')
              .removeFragment();
          if (next.scheme != 'http' && next.scheme != 'https') {
            throw const FormatException('脚本重定向只支持 HTTP/HTTPS');
          }
          if (!sameOrigin(current, next)) {
            for (final key in [
              'authorization',
              'cookie',
              'cookie2',
              'proxy-authorization',
              'host',
            ]) {
              requestHeaders.remove(key);
            }
          }
          if ((code == 303 && verb != 'HEAD') ||
              ((code == 301 || code == 302) && verb == 'POST')) {
            verb = 'GET';
            payload = null;
            for (final key in [
              'content-type',
              'content-length',
              'transfer-encoding',
            ]) {
              requestHeaders.remove(key);
            }
          }
          current = next;
          continue;
        }
        final responseHeaders = <String, String>{};
        response.headers.forEach((k, v) => responseHeaders[k] = v.join(', '));
        return <String, dynamic>{
          'code': code,
          'url': current.toString(),
          'headers': responseHeaders,
          'content': options['buffer'] == 2
              ? base64Encode(bytes)
              : utf8.decode(bytes, allowMalformed: true),
        };
      }
      throw const HttpException('脚本请求重定向过多');
    } finally {
      timer.cancel();
      client.close(force: true);
    }
  }

  static Future<({String cryptoJs, String hostScript})>? _bootstrapFuture;

  static Future<({String cryptoJs, String hostScript})>
  _loadBootstrapScripts() {
    return _bootstrapFuture ??= () async {
      var cryptoJs = '';
      var interopJs = '';
      var drpyHostJs = '';
      try {
        cryptoJs = await rootBundle.loadString('assets/js-host/crypto-js.js');
        cryptoJs =
            'var module={exports:{}};var exports=module.exports;\n$cryptoJs\nwindow.CryptoJS=module.exports;';
      } catch (_) {}
      try {
        interopJs = await rootBundle.loadString(
          'assets/js-host/module-interop.js',
        );
      } catch (_) {}
      try {
        drpyHostJs = await rootBundle.loadString(
          'assets/js-host/webview-drpy-host.js',
        );
      } catch (_) {
        drpyHostJs = defaultWebViewHostScript;
      }
      final combined = '$interopJs\n;\n$drpyHostJs';
      return (cryptoJs: cryptoJs, hostScript: combined);
    }();
  }

  @visibleForTesting
  void resetForTesting() {
    _cachedAvailable = null;
    _handlerAttached = false;
    _sessions.clear();
    _playbackPins.clear();
  }

  /// Embedded clean-room fallback copy of `webview-drpy-host.js` so
  /// `DesktopWebViewJsBridge` works without requiring `pubspec.yaml` changes.
  static const String defaultWebViewHostScript = r'''
(function () {
  'use strict';
  if (window.__marcoWebViewJsHostInstalled) return;
  window.__marcoWebViewJsHostInstalled = true;

  var sessions = Object.create(null);
  var pendingHttp = Object.create(null);
  var nextHttpId = 1;
  var docCacheKeys = [];
  var docCacheMap = Object.create(null);
  var MAX_DOC_CACHE = 16;

  function postToNative(payload) {
    if (window.chrome && window.chrome.webview && window.chrome.webview.postMessage) {
      window.chrome.webview.postMessage(payload);
    }
  }

  function hashString(str) {
    var h = 2166136261;
    var s = String(str || '');
    for (var i = 0; i < s.length; i++) {
      h ^= s.charCodeAt(i);
      h = Math.imul(h, 16777619);
    }
    return (h >>> 0).toString(16) + ':' + s.length;
  }

  function parseHtmlDoc(html) {
    if (html && typeof html === 'object' && html.querySelectorAll) return html;
    var text = String(html || '');
    var key = hashString(text);
    if (docCacheMap[key]) return docCacheMap[key];
    var doc = new DOMParser().parseFromString(text, 'text/html');
    docCacheKeys.push(key);
    docCacheMap[key] = doc;
    while (docCacheKeys.length > MAX_DOC_CACHE) {
      delete docCacheMap[docCacheKeys.shift()];
    }
    return doc;
  }

  function pdfa(html, rule) {
    if (!html || !rule) return [];
    var doc = parseHtmlDoc(html);
    var alts = String(rule).split('||');
    for (var i = 0; i < alts.length; i++) {
      var sel = alts[i].trim();
      if (!sel) continue;
      try {
        var els = Array.prototype.slice.call(doc.querySelectorAll(sel));
        if (els.length > 0) return els.map(function (el) { return el.outerHTML; });
      } catch (_) {}
    }
    return [];
  }

  function pdfh(html, rule, baseUrl) {
    if (!html || !rule) return '';
    var doc = parseHtmlDoc(html);
    var alts = String(rule).split('||');
    for (var i = 0; i < alts.length; i++) {
      var candidate = alts[i].trim();
      if (!candidate) continue;
      var parts = candidate.split('&&');
      var sel = parts[0].trim();
      var attr = parts.length > 1 ? parts[1].trim() : 'Text';
      var el = sel ? doc.querySelector(sel) : (doc.body || doc.documentElement);
      if (!el) continue;
      var val = (!attr || attr === 'Text' || attr === 'text')
        ? (el.textContent || '').trim()
        : (attr === 'Html' || attr === 'html')
          ? (el.innerHTML || '')
          : (el.getAttribute(attr) || '').trim();
      if (val) {
        if (!baseUrl) return val;
        try { return new URL(val, baseUrl).href; } catch (_) { return val; }
      }
    }
    return '';
  }

  function sendHttpRequest(sessionId, url, opt, isCatvod) {
    return new Promise(function (resolve, reject) {
      var reqId = 'hr_' + (nextHttpId++);
      pendingHttp[reqId] = { resolve: resolve, reject: reject };
      postToNative({
        type: 'httpRequest',
        reqId: reqId,
        sessionId: sessionId || '',
        url: String(url || ''),
        options: opt || {},
        catvod: !!isCatvod
      });
    });
  }

  window.pdfa = pdfa;
  window.pdfh = pdfh;
  window.pd = function (html, rule, baseUrl) { return pdfh(html, rule, baseUrl || ''); };
  window.Crypto = window.CryptoJS;
  window.log = function () {};
  window.print = window.log;
  window.req = function (url, opt) {
    return sendHttpRequest(window.__marcoCurrentSessionId || '', url, opt, false);
  };
  window.getProxy = function () { return window.__movieProxyBase || ''; };
  window.proxyUrl = function (params) {
    var url = window.__movieProxyBase || '';
    var keys = Object.keys(params || {});
    for (var i = 0; i < keys.length; i++) {
      url += '&' + encodeURIComponent(keys[i]) + '=' + encodeURIComponent(params[keys[i]]);
    }
    return url;
  };
  window.__movieEncodeProxyResult = function (value) {
    if (!Array.isArray(value) || value.length < 3 || value.length > 5) return value;
    var body = value[2];
    var bytes = body instanceof ArrayBuffer ? new Uint8Array(body) :
      ArrayBuffer.isView(body) ? new Uint8Array(body.buffer, body.byteOffset, body.byteLength) :
      Array.isArray(body) && body.every(function (v) { return Number.isInteger(v) && v >= 0 && v <= 255; }) ? new Uint8Array(body) : null;
    if (!bytes) return value;
    var bin = '';
    for (var i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
    return [value[0], value[1], btoa(bin), value[3] || {}, 1];
  };

  function resolveCommonJsPath(parent, ref, modules) {
    var base = new URL(ref, parent).href;
    var candidates = [base, base + '.js', base + '.json', base + '/index.js'];
    for (var i = 0; i < candidates.length; i++) {
      if (Object.prototype.hasOwnProperty.call(modules, candidates[i])) return candidates[i];
    }
    throw new Error('Script dependency is unavailable: ' + ref);
  }

  function resolveModuleKey(parent, spec, modules) {
    if (Object.prototype.hasOwnProperty.call(modules, spec)) return spec;
    try {
      var resolved = new URL(spec, parent).href;
      if (Object.prototype.hasOwnProperty.call(modules, resolved)) return resolved;
      var cands = [resolved + '.js', resolved + '.mjs', resolved + '.json', resolved + '/index.js'];
      for (var i = 0; i < cands.length; i++) {
        if (Object.prototype.hasOwnProperty.call(modules, cands[i])) return cands[i];
      }
    } catch (_) {}
    return spec;
  }

  async function importEsModuleTree(entry, modules) {
    var blobUrls = Object.create(null);
    function buildBlobUrl(key) {
      if (blobUrls[key]) return blobUrls[key];
      var src = modules[key];
      if (src == null) throw new Error('Script dependency is unavailable: ' + key);
      if (/\.json(?:[?#].*)?$/i.test(key)) src = 'export default ' + src + ';';
      var rewritten = String(src).replace(
        /(\b(?:import|export)\b[^;'"`]*?\bfrom\s*['"]|\bimport\s*['"])([^'"]+)(['"])/g,
        function (_, prefix, spec, suffix) {
          var depKey = resolveModuleKey(key, spec, modules);
          if (Object.prototype.hasOwnProperty.call(modules, depKey)) {
            return prefix + buildBlobUrl(depKey) + suffix;
          }
          return prefix + spec + suffix;
        }
      );
      var url = URL.createObjectURL(new Blob([rewritten], { type: 'text/javascript' }));
      blobUrls[key] = url;
      return url;
    }
    try {
      return await import(buildBlobUrl(entry));
    } finally {
      Object.keys(blobUrls).forEach(function (k) { URL.revokeObjectURL(blobUrls[k]); });
    }
  }

  async function loadSpiderSession(msg) {
    var entry = msg.entry || 'pkg://local/source.js';
    var modules = msg.modules || {};
    var source = modules[entry];
    if (typeof source !== 'string') throw new Error('Spider entry source missing');
    var proxyBase = msg.proxyBase || '';
    window.__movieProxyBase = proxyBase;
    window.__marcoCurrentSessionId = msg.sessionId || '';
    if (Object.prototype.hasOwnProperty.call(modules, 'catvod')) {
      var siteKey = '';
      try { siteKey = new URL(proxyBase, 'http://127.0.0.1').searchParams.get('siteKey') || ''; } catch (_) {}
      window.__movieCatvodBridge = Object.freeze({
        siteKey: siteKey || 'wv_site',
        request: function (url, options) { return sendHttpRequest(msg.sessionId || '', url, options, true); },
        proxyUrl: function (params) {
          var u = proxyBase;
          Object.entries(params || {}).forEach(function (kv) {
            u += '&' + encodeURIComponent(kv[0]) + '=' + encodeURIComponent(kv[1]);
          });
          return u;
        }
      });
    }
    var opts = msg.rawExtension != null ? { rawExtension: msg.rawExtension } : {};
    var isEsModule = /(?:^|[;\n])\s*(?:export\s+(?:default\b|(?:async\s+)?function\b|const\b|let\b|var\b|class\b|\{|\*)|import\s)/.test(source);
    var isCommonJs = /\bmodule\.exports\b|\bexports\s*(?:\.|\[)/.test(source);
    var isCat = /\b__jsEvalReturn\b/.test(source) && !isEsModule;
    var spider;
    if (isCat) {
      (0, eval)(source);
      spider = window.__movieSelectSpider(window.__jsEvalReturn(), { preserveInit: true });
    } else if (isEsModule) {
      spider = window.__movieSelectSpider(await importEsModuleTree(entry, modules), opts);
    } else if (isCommonJs) {
      var exported = window.__movieLoadCommonJS(entry, function (ref, parent) {
        var resolved = resolveCommonJsPath(parent, ref, modules);
        return { name: resolved, source: modules[resolved] };
      });
      spider = window.__movieSelectSpider(exported, opts);
    } else {
      throw new Error('Unsupported JS spider format');
    }
    if (typeof spider.init === 'function') await Promise.resolve(spider.init(msg.extension));
    return spider;
  }

  async function handleEvalSpider(msg) {
    var callId = msg.callId || '';
    try {
      var sid = msg.sessionId || ('anon_' + callId);
      var session = sessions[sid];
      if (!session && msg.modules) {
        var spider = await loadSpiderSession(msg);
        session = { spider: spider, proxyBase: msg.proxyBase || '' };
        if (msg.sessionId) sessions[sid] = session;
      }
      if (!session || !session.spider) throw new Error('WebView2 spider session not initialized');
      window.__movieProxyBase = session.proxyBase || msg.proxyBase || '';
      window.__marcoCurrentSessionId = sid;
      var fn = session.spider[msg.method || ''];
      if (typeof fn !== 'function') throw new Error('脚本缺少 ' + msg.method + ' 接口');
      var val = await Promise.resolve(fn.apply(session.spider, Array.isArray(msg.arguments) ? msg.arguments : []));
      if (msg.method === 'proxy') val = window.__movieEncodeProxyResult(val);
      var out = typeof val === 'string' ? val : JSON.stringify(val);
      postToNative({ type: 'result', callId: callId, ok: true, result: out || '' });
    } catch (err) {
      postToNative({ type: 'result', callId: callId, ok: false, error: err && err.message ? String(err.message) : String(err) });
    }
  }

  if (window.chrome && window.chrome.webview) {
    window.chrome.webview.addEventListener('message', function (event) {
      var msg = event && event.data;
      if (!msg || typeof msg !== 'object') return;
      if (msg.type === 'httpResponse') {
        var slot = pendingHttp[msg.reqId];
        if (!slot) return;
        delete pendingHttp[msg.reqId];
        if (msg.ok) slot.resolve(msg.data);
        else slot.reject(new Error(msg.error || 'HTTP request failed'));
        return;
      }
      if (msg.type === 'disposeSession') {
        var s = sessions[msg.sessionId];
        delete sessions[msg.sessionId];
        if (s && s.spider && typeof s.spider.destroy === 'function') {
          try { Promise.resolve(s.spider.destroy()); } catch (_) {}
        }
        postToNative({ type: 'result', callId: msg.callId || '', ok: true, result: 'ok' });
        return;
      }
      if (msg.type === 'evalSpider') handleEvalSpider(msg);
    });
  }
})();
''';
}

class _WebViewSessionContext {
  _WebViewSessionContext({
    required this.entry,
    required this.modules,
    required this.extension,
    required this.rawExtension,
    required this.headers,
    required this.catDetails,
    required this.proxy,
    required this.proxyBase,
    required this.budget,
  });

  final String entry;
  final Map<String, String> modules;
  final Object? extension;
  final String? rawExtension;
  final Map<String, String> headers;
  final bool catDetails;
  final ScriptProxyRegistration? proxy;
  final String proxyBase;
  Duration budget;
  bool closed = false;
}
