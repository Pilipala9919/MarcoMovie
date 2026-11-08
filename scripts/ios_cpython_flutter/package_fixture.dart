import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'python_source_channel.dart';
import 'python_source_sessions.dart';

Future<void> runGenericPackageFixture(void Function(String, bool) check) async {
  const channel = MethodChannel('marco_movie/python_source');
  final bridge = PythonSourceChannel(channel: channel);
  final pool = PythonSourceSessions();
  final owners = <PythonNativeSession>[];
  final encoded =
      jsonDecode(await rootBundle.loadString('assets/python-package.json'))
          as Map;
  final files = <String, Uint8List>{
    for (final entry in encoded.entries)
      entry.key as String: base64Decode(entry.value as String),
  };
  final remotePaths = <String>[];
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final slowEntered = Completer<void>();
  server.listen((request) async {
    if (request.uri.path == '/slow') {
      if (!slowEntered.isCompleted) slowEntered.complete();
      return;
    }
    await request.drain<void>();
    if (request.uri.path.startsWith('/remote/')) {
      remotePaths.add(request.uri.toString());
      final bytes = files[request.uri.path.substring(1)];
      request.response.statusCode =
          request.headers.value('authorization') != 'owned-package'
          ? 403
          : bytes == null
          ? 404
          : 200;
      if (request.response.statusCode == 200) request.response.add(bytes!);
      await request.response.close();
      return;
    }
    request.response.headers.contentType = ContentType.json;
    request.response.write(
      jsonEncode({
        'method': request.method,
        'authorization': request.headers.value('authorization'),
        'agent': request.headers.value('user-agent'),
      }),
    );
    await request.response.close();
  });
  final origin = 'http://127.0.0.1:${server.port}';
  final rawExtension = '  ${jsonEncode({'origin': origin})}\n';
  final package = NativePythonPackage(
    entry: 'catalog/main.py',
    files: files,
    extension: rawExtension,
  );
  final http = HttpClient();
  Future<Object?> call(
    String key,
    String method,
    List<Object?> args, {
    Completer<void>? cancellation,
  }) async {
    final output = await pool.invoke(
      sessionKey: key,
      expectedGeneration: pool.generation,
      method: method,
      arguments: args,
      cancellation: cancellation,
      allowUrl: (url) => url.origin == origin,
      open: (proxy, request) async {
        final owner = await bridge.open(package, proxy, request);
        owners.add(owner);
        return owner;
      },
    );
    return output.startsWith('#EXTM3U') ? output : jsonDecode(output);
  }

  try {
    final capabilities = await channel.invokeMapMethod<String, Object?>(
      'python.capabilities',
    );
    check(
      'package_registered_native_plugin',
      capabilities?['version'] == 1 &&
          (capabilities?['runtime'] as String? ?? '').startsWith('3.14.10 ') &&
          capabilities?['maxSessions'] == 2 &&
          capabilities?['hardCancel'] == false,
    );
    final a = await call('a', 'home', [true]) as Map;
    final b = await call('b', 'home', [true]) as Map;
    check(
      'package_channel_real_http',
      a['http']['method'] == 'GET' && b['http']['method'] == 'GET',
    );
    check(
      'package_relative_module_and_resource',
      a['class'][0]['type_name'] == '通用 Python 包' &&
          a['resource'] == 'package-resource',
    );
    check('package_raw_extension', a['raw'] == rawExtension);
    check(
      'package_independent_instances',
      a['calls'] == 1 &&
          b['calls'] == 1 &&
          (await call('a', 'home', [false]) as Map)['calls'] == 2,
    );
    check(
      'package_recommendations',
      (await call('a', 'homeVod', []) as Map)['list'][0]['vod_id'] == 'one',
    );
    final category =
        await call('a', 'category', [
              'film',
              3,
              true,
              {'year': '2026'},
            ])
            as Map;
    check(
      'package_category_filter',
      category['page'] == '3' && category['filter']['year'] == '2026',
    );
    final search = await call('a', 'search', ['中文检索', false, 2]) as Map;
    check(
      'package_search_unicode',
      search['list'][0]['vod_name'] == '中文检索' && search['page'] == '2',
    );
    final detail =
        await call('a', 'detail', [
              [r'opaque/$#?中文'],
            ])
            as Map;
    check(
      'package_detail_and_episodes',
      detail['list'][0]['vod_id'] == r'opaque/$#?中文' &&
          detail['list'][0]['vod_play_url'] == '第一集\$one',
    );
    final play = await call('a', 'play', ['owned', 'one', []]) as Map;
    final proxy = Uri.parse(play['url'] as String);
    check(
      'package_play_owned_proxy',
      play['parse'] == 0 && pool.ownsProxyUrl('a', proxy),
    );
    final get = await http.getUrl(proxy);
    final response = await get.close();
    final bytes = await response.fold<List<int>>(
      [],
      (all, part) => all..addAll(part),
    );
    var exact = bytes.length == 1280000;
    for (var i = 0; i < bytes.length; i++) {
      if (bytes[i] != i % 256) {
        exact = false;
        break;
      }
    }
    check(
      'package_large_binary_proxy',
      exact &&
          response.statusCode == 206 &&
          response.headers.value('x-instance-calls') == '3',
    );
    final head = await http.openUrl('HEAD', proxy);
    final headResponse = await head.close();
    final headBytes = await headResponse.fold<List<int>>(
      [],
      (all, part) => all..addAll(part),
    );
    check(
      'package_proxy_head_retains_owner',
      headBytes.isEmpty &&
          headResponse.contentLength == 1280000 &&
          headResponse.headers.value('x-instance-calls') == '4',
    );
    check(
      'package_live_text',
      (await call('a', 'liveContent', ['text']) as String).startsWith(
        '#EXTM3U\n',
      ),
    );
    final stop = Completer<void>();
    final cancelled = call(
      'a',
      'liveContent',
      ['slow'],
      cancellation: stop,
    ).then((_) => false, onError: (Object e) => e is StateError);
    await slowEntered.future.timeout(const Duration(seconds: 5));
    stop.complete();
    check(
      'package_cancel_active_http',
      await cancelled.timeout(const Duration(seconds: 2)),
    );
    await owners.first.close().timeout(const Duration(seconds: 5));
    final old = await (await http.getUrl(proxy)).close();
    await old.drain<void>();
    check('package_revoked_proxy', old.statusCode == 404);
    final baseQuery = Map<String, String>.from(proxy.queryParameters)
      ..remove('id');
    final bad = NativePythonPackage(
      entry: 'catalog/main.py',
      files: {...files, 'native_source_entry.py': Uint8List(0)},
      extension: rawExtension,
    );
    try {
      await bridge.open(
        bad,
        proxy.replace(queryParameters: baseQuery),
        (_) async => throw StateError('Failed package cannot use HTTP'),
      );
      check('package_failed_open_released', false);
    } on PlatformException catch (error) {
      check('package_failed_open_released', error.code == 'python_error');
    }
    final fresh = await call('fresh', 'home', [false]) as Map;
    check(
      'package_capacity_after_failed_open',
      fresh['calls'] == 1 && fresh['resource'] == 'package-resource',
    );
    check(
      'package_other_owner_survives',
      (await call('b', 'home', [false]) as Map)['calls'] == 2,
    );
    final remotePackage = NativePythonPackage(
      entry: 'main.py',
      files: {'main.py': files['remote/main.py']!},
      extension: rawExtension,
      remote: PythonRemoteSource(
        Uri.parse('$origin/remote/index.php?entry_only=true'),
        headers: {
          'Authorization': 'owned-package',
          'User-Agent': 'owned-agent',
        },
      ),
    );
    Future<Map> remoteCall(String method, List<Object?> args) async =>
        jsonDecode(
              await pool.invoke(
                sessionKey: 'remote',
                expectedGeneration: pool.generation,
                method: method,
                arguments: args,
                allowUrl: (url) => url.origin == origin,
                open: (proxy, request) async {
                  final owner = await bridge.open(
                    remotePackage,
                    proxy,
                    request,
                  );
                  owners.add(owner);
                  return owner;
                },
              ),
            )
            as Map;
    final remoteHome = await remoteCall('home', [false]);
    check(
      'remote_native_package_modules',
      remoteHome['name'] == 'remote sibling',
    );
    check('remote_native_resources', remoteHome['resource'] == '远程模块资源');
    check(
      'remote_native_default_headers',
      remoteHome['request']['authorization'] == 'owned-package' &&
          remoteHome['request']['agent'] == 'owned-agent',
    );
    final remoteDetail = await remoteCall('detail', ['opaque/id']);
    await remoteCall('home', [false]);
    check(
      'remote_native_deferred_import_cache',
      remoteDetail['episode'] == 'opaque/episode' &&
          remotePaths
                  .where((path) => path == '/remote/helpers/value.py')
                  .length ==
              1 &&
          remotePaths.where((path) => path == '/remote/later.py').length == 1 &&
          remotePaths.every((path) => !path.contains('entry_only')),
    );
  } finally {
    await pool.close();
    for (final owner in owners) {
      await owner.close();
    }
    channel.setMethodCallHandler(null);
    await server.close(force: true);
    http.close(force: true);
  }
}
