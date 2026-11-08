// Exercise the shared source loader and real product HTTP transport on iOS.
// The source itself is a bundled, app-owned package, never user input.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/services.dart';
import 'python_http_transport.dart';
import 'python_source_sessions.dart';

class NativeSourceFixture {
  NativeSourceFixture._(this.channel, this.server, this.origin, this.actors);
  final MethodChannel channel;
  final HttpServer server;
  final Uri origin;
  final bool actors;
  final pool = PythonSourceSessions();
  final handles = <String>{};
  final owners = <String, FixtureSourceOwner>{};
  final pending = <String, PythonHttpRequest>{};
  final failures = <String>[];
  final operations = <String>{};
  final slowReceived = Completer<void>();
  final blockEntered = Completer<void>();
  int sequence = 0;
  int httpRequests = 0;
  int proxyCalls = 0;

  static Future<NativeSourceFixture> start(
    MethodChannel channel, {
    bool actors = false,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final random = Random.secure();
    final token = List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final fixture = NativeSourceFixture._(
      channel,
      server,
      Uri.parse('http://127.0.0.1:${server.port}/$token'),
      actors,
    );
    server.listen(
      (request) => unawaited(fixture.serve(request)),
      onError: (Object error) => fixture.failures.add('$error'),
    );
    return fixture;
  }

  Future<Object?> onMethod(MethodCall call) async {
    if (call.method == 'owner.blockEntered' && actors) {
      if (!blockEntered.isCompleted) blockEntered.complete();
      return null;
    }
    final args = Map<String, Object?>.from(call.arguments as Map);
    if (call.method == 'transport.cancel') return null;
    final request = pending[args['callId']];
    if (call.method != 'transport.request' || request == null) {
      throw PlatformException(code: 'protocol');
    }
    try {
      operations.add(args['callId'] as String);
      httpRequests++;
      return await request(args);
    } on PythonTransportException catch (error) {
      throw PlatformException(code: error.kind);
    } on FormatException {
      throw PlatformException(code: 'protocol');
    }
  }

  Future<String> open() async {
    final key = 'owned-source-${++sequence}';
    handles.add(key);
    return key;
  }

  Future<Object?> call(
    String key,
    String method,
    List<Object?> args, {
    Completer<void>? cancellation,
  }) async {
    if (!handles.contains(key)) throw StateError('Removed fixture source');
    final value = await pool.invoke(
      sessionKey: key,
      method: method,
      arguments: args,
      expectedGeneration: pool.generation,
      cancellation: cancellation,
      allowUrl: (url) =>
          url.origin == origin.origin && url.path.startsWith('${origin.path}/'),
      open: (proxy, request) async {
        final reply = await channel.invokeMapMethod<String, Object?>(
          actors ? 'openActor' : 'openSource',
          {
            'version': 1,
            'source': 'native-source-v1',
            'origin': '$origin',
            'proxy': '$proxy',
          },
        );
        final owner = FixtureSourceOwner(
          this,
          reply!['handle'] as String,
          request,
        );
        owners[key] = owner;
        return owner;
      },
    );
    if (method == 'liveContent' && value.startsWith('#EXTM3U')) return value;
    return jsonDecode(value);
  }

  Future<bool> release(String key) async {
    final removed = handles.remove(key);
    pool.release(key);
    final owner = owners[key];
    if (owner != null)
      await owner.closed.future.timeout(const Duration(seconds: 10));
    return removed;
  }

  Future<void> serve(HttpRequest request) async {
    final response = request.response;
    try {
      await request.drain<void>();
      if (request.uri.path == '${origin.path}/echo') {
        response.headers.contentType = ContentType.json;
        response.write(jsonEncode({'method': request.method}));
      } else if (request.uri.path == '${origin.path}/slow') {
        if (!slowReceived.isCompleted) slowReceived.complete();
        return; // Owned cancellation fixture: deliberately leave response pending.
      } else {
        response.statusCode = HttpStatus.notFound;
      }
      await response.close();
    } catch (error) {
      failures.add('$error');
      try {
        response.statusCode = 500;
        await response.close();
      } catch (_) {}
    }
  }

  Future<void> close() async {
    for (final key in handles.toList()) {
      await release(key);
    }
    await pool.close();
    await server.close(force: true);
  }
}

class FixtureSourceOwner extends PythonNativeSession {
  FixtureSourceOwner(this.fixture, this.handle, this.request);
  final NativeSourceFixture fixture;
  final String handle;
  final PythonHttpRequest request;
  final closed = Completer<void>();
  int cancellations = 0;
  @override
  Future<Object?> invoke(
    String callId,
    String method,
    List<Object?> args,
    Duration budget,
  ) async {
    fixture.pending[callId] = request;
    try {
      if (method == 'proxy') fixture.proxyCalls++;
      return await fixture.channel.invokeMethod<Object?>(
        fixture.actors ? 'callActor' : 'callSource',
        {
          'version': 1,
          'handle': handle,
          'method': method,
          'args': args,
          'callId': callId,
          if (fixture.actors) 'budgetMs': budget.inMilliseconds.clamp(1, 45000),
        },
      );
    } finally {
      fixture.pending.remove(callId);
    }
  }

  @override
  Future<void> cancel(String callId) async {
    cancellations++;
    await fixture.channel.invokeMethod<Object?>(
      fixture.actors ? 'cancelActor' : 'cancelTransport',
      {'version': 1, 'callId': callId, if (fixture.actors) 'handle': handle},
    );
  }

  @override
  Future<void> close() async {
    final reply = await fixture.channel.invokeMapMethod<String, Object?>(
      fixture.actors ? 'releaseActor' : 'release',
      {'version': 1, 'handle': handle},
    );
    if (reply?['released'] != true)
      throw StateError('Native owner was not released');
    if (!closed.isCompleted) closed.complete();
  }
}

Future<void> runNativeSourceFixture(
  MethodChannel channel,
  void Function(String, bool) check,
  int Function() heartbeat,
) async {
  final fixture = await NativeSourceFixture.start(channel);
  final http = HttpClient();
  channel.setMethodCallHandler(fixture.onMethod);
  final before = heartbeat();
  try {
    final a = await fixture.open();
    final b = await fixture.open();
    Future<Map> call(String handle, String method, List<Object?> args) async =>
        await fixture.call(handle, method, args) as Map;
    final home = await call(a, 'home', [true]);
    check(
      'source_shared_host_home',
      (home['class'] as List).first['type_name'] == '电影',
    );
    check('source_raw_extension', home['raw_extension'] == true);
    check('source_relative_module', home['relative_module'] == '内存包相对模块');
    check('source_package_resource', home['resource'] == '内存包资源');
    check(
      'source_http_transport',
      home['request_method'] == 'GET' &&
          fixture.httpRequests == 1 &&
          fixture.operations.length == 1,
    );
    final again = await call(a, 'home', [false]);
    check(
      'source_init_once',
      again['initializations'] == 1 && again['module_instances'] == 1,
    );
    check('source_same_instance', home['calls'] == 1 && again['calls'] == 2);
    final other = await call(b, 'home', [false]);
    check(
      'source_same_name_isolation',
      other['calls'] == 1 && other['module_instances'] == 1,
    );
    check(
      'source_recommendations',
      ((await call(a, 'homeVod', []))['list'] as List).first['vod_name'] ==
          '内存包推荐',
    );
    final category = await call(a, 'category', [
      'film',
      7,
      true,
      {'year': '2026'},
    ]);
    check(
      'source_category_filters',
      category['page'] == '7' &&
          category['extend']['year'] == '2026' &&
          category['filtered'] == true,
    );
    final search = await call(a, 'search', ['真实中文词', false, 3]);
    check(
      'source_search_unicode',
      search['page'] == '3' &&
          (search['list'] as List).first['vod_name'] == '真实中文词',
    );
    final detail = await call(a, 'detail', [
      [r'opaque/$#?中文'],
    ]);
    check(
      'source_detail_opaque',
      (detail['list'] as List).first['vod_id'] == r'opaque/$#?中文',
    );
    final play = await call(a, 'play', ['owned', 'episode-1', []]);
    final proxy = Uri.parse(play['url'] as String);
    check(
      'source_play_proxy_url',
      fixture.pool.ownsProxyUrl(a, proxy) &&
          proxy.queryParameters['item'] == 'episode-1',
    );
    final get = await http.getUrl(proxy);
    get.headers.set(HttpHeaders.rangeHeader, 'bytes=0-5');
    final getResponse = await get.close();
    final bytes = await getResponse.fold<List<int>>(
      [],
      (all, part) => all..addAll(part),
    );
    check('source_proxy_get_bytes', base64Encode(bytes) == 'AP+ADQpB');
    check(
      'source_proxy_headers',
      getResponse.statusCode == 206 &&
          getResponse.headers.value('content-range') == 'bytes 0-5/6',
    );
    final head = await http.openUrl('HEAD', proxy);
    head.headers.set(HttpHeaders.rangeHeader, 'bytes=0-5');
    final headResponse = await head.close();
    final headBytes = await headResponse.fold<List<int>>(
      [],
      (all, part) => all..addAll(part),
    );
    check(
      'source_proxy_head',
      headResponse.statusCode == 206 &&
          headBytes.isEmpty &&
          headResponse.contentLength == 6,
    );
    check(
      'source_proxy_retains_instance',
      getResponse.headers.value('x-instance-calls') == '8' &&
          headResponse.headers.value('x-instance-calls') == '9' &&
          fixture.proxyCalls == 2,
    );
    final live = await call(a, 'liveContent', ['owned/catalog']);
    check(
      'source_live_json',
      live['url'] == 'owned/catalog' && (live['list'] as List).isEmpty,
    );
    check(
      'source_live_text',
      await fixture.call(a, 'liveContent', ['text']) ==
          '#EXTM3U\n#EXTINF:-1,Owned\nrelative/stream.m3u8\n',
    );
    check('source_release', await fixture.release(a));
    final fresh = await fixture.open();
    final stale = await http.getUrl(proxy);
    final staleResponse = await stale.close();
    await staleResponse.drain<void>();
    check(
      'source_released_proxy_not_rebound',
      staleResponse.statusCode == 404 && fresh != a && fixture.proxyCalls == 2,
    );
    try {
      await channel.invokeMethod<Object?>('callSource', {
        'version': 1,
        'handle': fixture.owners[a]!.handle,
        'method': 'home',
        'args': [false],
        'callId': '0' * 32,
      });
      check('source_stale_handle', false);
    } on PlatformException catch (error) {
      check('source_stale_handle', error.code == 'invalid_handle');
    }
    check(
      'source_other_session_survives',
      (await call(b, 'home', [false]))['calls'] == 2,
    );
    final reset = await call(fresh, 'home', [false]);
    check(
      'source_recreate_state',
      reset['calls'] == 1 &&
          reset['initializations'] == 1 &&
          reset['module_instances'] == 1,
    );
    check('source_transport_drained', fixture.pending.isEmpty);
    final stop = Completer<void>();
    final owner = fixture.owners[fresh]!;
    final slow = fixture.call(fresh, 'liveContent', [
      'slow',
    ], cancellation: stop);
    final cancellationObserved = slow.then(
      (_) => false,
      onError: (Object error) => error is StateError,
    );
    await fixture.slowReceived.future.timeout(const Duration(seconds: 5));
    stop.complete();
    check(
      'source_session_cancel_returns',
      await cancellationObserved.timeout(const Duration(seconds: 2)),
    );
    check('source_cancel_proxy_revoked', fixture.pool.activeCount == 1);
    await owner.closed.future.timeout(const Duration(seconds: 5));
    check(
      'source_cancel_other_session_survives',
      (await call(b, 'home', [false]))['calls'] == 3,
    );
    check(
      'source_cancel_actual_owner_closed',
      owner.cancellations == 1 &&
          fixture.pool.allocatedCount == 1 &&
          fixture.pending.isEmpty,
    );
    final generation = fixture.pool.generation;
    fixture.pool.retainSessions({b});
    try {
      await fixture.pool.invoke(
        sessionKey: 'deleted-loading',
        open: (_, __) async => throw StateError('Factory must not run'),
        method: 'home',
        arguments: [],
        expectedGeneration: generation,
      );
      check('source_stale_generation_rejected', false);
    } on StateError catch (error) {
      check(
        'source_stale_generation_rejected',
        !error.toString().contains('Factory'),
      );
    }
    check('source_server_clean', fixture.failures.isEmpty);
    check('source_ui_responsive', heartbeat() - before >= 2);
  } finally {
    await fixture.close();
    channel.setMethodCallHandler(null);
    http.close(force: true);
  }
}
