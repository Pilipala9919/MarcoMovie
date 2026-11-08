import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/cms_parser.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/core/python_source_channel.dart';
import 'package:marco_movie/core/python_source_host.dart';

// The widget binding otherwise replaces every HTTP request with status 400.
// Only the source-owned loopback revocation check uses real sockets here.
class _OwnedLoopbackHttp extends HttpOverrides {}

class NativeBackend {
  final channel = const MethodChannel('owned.python.dispatch');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final opened = <Map>[];
  final methods = <String>[];
  final arguments = <List>[];
  int capabilityCalls = 0;
  bool compatible = true;
  bool fail = false;
  String failureCode = 'source_error';
  String? openingFailure;
  int closes = 0;
  Completer<void>? pending;
  late final PythonSourceHost host;
  NativeBackend() {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'python.capabilities') {
        capabilityCalls++;
        return {
          'version': compatible ? 1 : 99,
          'runtime': '3.14.10 fixture',
          'maxSessions': 2,
          'hardCancel': false,
          'sourceThreads': false,
        };
      }
      final args = call.arguments as Map;
      if (call.method == 'python.open') {
        if (openingFailure != null) {
          throw PlatformException(
            code: openingFailure!,
            message: 'private native detail',
          );
        }
        opened.add(args);
        return {
          'handle':
              '${opened.length.toRadixString(16).padLeft(8, '0')}-0000-0000-0000-000000000000',
        };
      }
      if (call.method == 'python.close') {
        closes++;
        return {'closed': true};
      }
      if (call.method == 'python.cancel') return {'cancelled': 'active'};
      if (call.method == 'python.call') {
        final method = args['method'] as String;
        methods.add(method);
        arguments.add(List.of(args['args'] as List));
        if (pending != null) await pending!.future;
        if (fail)
          throw PlatformException(
            code: failureCode,
            message: 'https://secret.example/path?token=must-not-display',
            details: {'cookie': 'must-not-display'},
          );
        if (method == 'play')
          return {
            'parse': 0,
            'url': opened.last['proxy'],
            'header': {
              'Origin': 'https://media.example',
              'Connection': 'X-Internal',
              'X-Internal': 'discard',
            },
          };
        if (method == 'liveContent') {
          return jsonEncode([
            {
              'name': 'Native',
              'channels': [
                {
                  'name': 'Owned',
                  'url': opened.last['proxy'],
                  'header': {
                    'Origin': 'https://media.example',
                    'Connection': 'X-Internal',
                    'X-Internal': 'discard',
                  },
                },
              ],
            },
          ]);
        }
        if (method == 'detail')
          return {
            'list': [
              {
                'vod_id': 'one',
                'vod_name': 'Owned',
                'vod_play_from': 'local',
                'vod_play_url': '第一集\$episode',
              },
            ],
          };
        return {
          'class': [
            {'type_id': 'film', 'type_name': '电影'},
          ],
          'list': [
            {'vod_id': 'one', 'vod_name': 'Owned'},
          ],
        };
      }
      throw MissingPluginException();
    });
    host = PythonSourceHost(
      enabled: true,
      channel: PythonSourceChannel(channel: channel),
    );
  }
  Future<void> dispose() async {
    pending?.complete();
    await host.close();
    // Closing is deliberately asynchronous while the native owner exits.
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    channel.setMethodCallHandler(null);
    messenger.setMockMethodCallHandler(channel, null);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const code = 'class Spider:\n def homeContent(self, f): return {}\n';
  const site = CmsSite(
    key: 'native',
    name: 'Owned',
    type: 3,
    api: 'https://source.example/api.php?entry=1',
    ext: '  {"value":1}\n',
    headers: {'Authorization': 'owned'},
  );

  test(
    'ZIP live Python keeps package files and opaque input on the native route',
    () async {
      final backend = NativeBackend();
      addTearDown(backend.dispose);
      final archive = Archive();
      void add(String name, List<int> bytes) =>
          archive.addFile(ArchiveFile(name, bytes.length, bytes));
      add(
        'bundle/config.json',
        utf8.encode(
          '{"lives":[{"api":"./main.py","url":"opaque/channel","ext":{"mode":1}}]}',
        ),
      );
      add('bundle/main.py', utf8.encode(code));
      add('bundle/data.bin', [0, 255, 128]);
      final live = CmsParser.parseConfig(
        CmsClient.readSubscriptionFile(
          ZipEncoder().encode(archive),
          'owned.zip',
        ),
      ).lives.single;
      final client = CmsClient(
        pythonHost: backend.host,
        client: MockClient(
          (_) async => throw StateError('package must remain offline'),
        ),
      );
      await client.fetchLiveGroups(live);
      expect(backend.methods, ['liveContent']);
      expect(backend.arguments.single, ['opaque/channel']);
      expect(backend.opened.single['entry'], 'bundle/main.py');
      expect((backend.opened.single['files'] as Map)['bundle/data.bin'], [
        0,
        255,
        128,
      ]);
      expect(jsonDecode(backend.opened.single['extension'] as String), {
        'mode': 1,
      });
      expect(backend.opened.single.containsKey('remote'), false);
    },
  );

  test(
    'native liveContent reaches playlist and player with the same retained owner',
    () async {
      final backend = NativeBackend();
      addTearDown(backend.dispose);
      var downloads = 0;
      final transport = MockClient((request) async {
        downloads++;
        expect(request.url.toString(), 'https://source.example/live.php');
        return http.Response(code, 200);
      });
      final client = CmsClient(client: transport, pythonHost: backend.host);
      final config = CmsParser.parseConfig(
        '{"lives":[{"name":"Native","api":"https://source.example/live.php","url":"opaque-input"}]}',
        subscriptionId: 'live-owner',
      );
      final live = config.lives.single;
      final channel = (await client.fetchLiveGroups(
        live,
      )).single.channels.single;
      expect(backend.methods, ['liveContent']);
      expect(backend.arguments.single, ['opaque-input']);
      final release = client.pinPlaybackSource(live.playbackSite);
      addTearDown(release);
      final play = CmsClient(client: transport, pythonHost: backend.host)
          .resolveLiveEpisodeForPlayback(
            live.playbackSite,
            channel.episodes.single,
          );
      expect(play.url, backend.opened.single['proxy']);
      expect(play.headers, {
        'X-MarcoMovie-Proxy-Origin': 'https://media.example',
      });
      await client.fetchLiveGroups(live);
      expect(downloads, 1);
      expect(backend.opened.length, 1);
      backend.host.retainSessions({});
      await HttpOverrides.runWithHttpOverrides(() async {
        final socket = HttpClient();
        try {
          final removed = await (await socket.getUrl(
            Uri.parse(play.url),
          )).close();
          await removed.drain<void>();
          expect(removed.statusCode, 404);
        } finally {
          socket.close(force: true);
        }
      }, _OwnedLoopbackHttp());
    },
  );

  test(
    'native catalogue failure stays readable and does not download its opaque argument',
    () async {
      final backend = NativeBackend()..fail = true;
      addTearDown(backend.dispose);
      var downloads = 0;
      final client = CmsClient(
        pythonHost: backend.host,
        client: MockClient((_) async {
          downloads++;
          return http.Response(code, 200);
        }),
      );
      final live = CmsParser.parseConfig(
        '{"lives":[{"api":"https://source.example/live.py","url":"https://media.example/not-a-catalogue"}]}',
      ).lives.single;
      await expectLater(
        client.fetchLiveGroups(live),
        throwsA(isA<PythonSourceException>()),
      );
      expect(downloads, 1);
      expect(backend.methods, ['liveContent']);
    },
  );

  test(
    'CMS routes content-detected PHP Python through one retained native owner',
    () async {
      final backend = NativeBackend();
      addTearDown(backend.dispose);
      var downloads = 0;
      final transport = MockClient((request) async {
        downloads++;
        expect(request.headers['Authorization'], 'owned');
        return http.Response(code, 200);
      });
      final client = CmsClient(client: transport, pythonHost: backend.host);
      final home = await client.fetchHome(site);
      final detail = await CmsClient(
        client: transport,
        pythonHost: backend.host,
      ).fetchDetail(site, home.$2.videos.single);
      final release = client.pinPlaybackSource(site);
      final play = await client.resolveEpisodeForPlayback(
        site,
        detail.lines.single.episodes.single,
      );
      release();
      expect(downloads, 1);
      expect(backend.capabilityCalls, 1);
      expect(backend.opened, hasLength(1));
      expect(backend.methods, ['home', 'detail', 'play']);
      expect(backend.opened.single['extension'], site.ext);
      final remote = backend.opened.single['remote'] as Map;
      expect(remote['url'], site.api);
      expect((remote['headers'] as Map)['Authorization'], 'owned');
      expect((backend.opened.single['files'] as Map).keys, ['main.py']);
      expect(play.headers.containsKey('Origin'), false);
      expect(play.headers.containsKey('X-Internal'), false);
      expect(
        play.headers['X-MarcoMovie-Proxy-Origin'],
        'https://media.example',
      );
      backend.host.retainSessions({});
      await HttpOverrides.runWithHttpOverrides(() async {
        final socket = HttpClient();
        try {
          final removed = await (await socket.getUrl(
            Uri.parse(play.url),
          )).close();
          await removed.drain<void>();
          expect(removed.statusCode, 404);
        } finally {
          socket.close(force: true);
        }
      }, _OwnedLoopbackHttp());
    },
  );

  test(
    'imported ZIP keeps entry directory and exact binary package files',
    () async {
      final backend = NativeBackend();
      addTearDown(backend.dispose);
      final archive = Archive()
        ..addFile(ArchiveFile.string('bundle/main.py', code))
        ..addFile(ArchiveFile.string('bundle/helper.py', 'value=1'))
        ..addFile(ArchiveFile('bundle/data.bin', 3, [0, 255, 128]));
      final client = CmsClient(pythonHost: backend.host);
      final imported = await client.resolveConfigInput(
        rawTextInput: CmsClient.readSubscriptionFile(
          ZipEncoder().encode(archive),
          'owned.zip',
        ),
      );
      await client.fetchHome(imported.config.sites.single);
      final package = backend.opened.single;
      expect(package['entry'], 'bundle/main.py');
      expect((package['files'] as Map)['bundle/data.bin'], [0, 255, 128]);
      expect(package.containsKey('remote'), false);
    },
  );

  test(
    'unsupported native capability cannot execute or fall back to QuickJS',
    () async {
      final backend = NativeBackend()..compatible = false;
      addTearDown(backend.dispose);
      final client = CmsClient(
        pythonHost: backend.host,
        client: MockClient((_) async => http.Response(code, 200)),
      );
      await expectLater(client.fetchHome(site), throwsFormatException);
      expect(backend.opened, isEmpty);
      expect(backend.methods, isEmpty);
    },
  );

  test(
    'native execution failure reaches CMS once without alternate-engine replay',
    () async {
      final backend = NativeBackend()..fail = true;
      addTearDown(backend.dispose);
      final client = CmsClient(
        pythonHost: backend.host,
        client: MockClient((_) async => http.Response(code, 200)),
      );
      await expectLater(
        client.fetchHome(site),
        throwsA(
          isA<PythonSourceException>().having(
            (error) => error.toString(),
            'safe failure',
            'Python 片源执行失败，请重试或切换其他片源',
          ),
        ),
      );
      expect(backend.methods, ['home']);
      expect(backend.opened, hasLength(1));
    },
  );

  test(
    'cached native timeout gives a readable message without replay or private details',
    () async {
      final backend = NativeBackend();
      addTearDown(backend.dispose);
      var downloads = 0;
      final client = CmsClient(
        pythonHost: backend.host,
        client: MockClient((_) async {
          downloads++;
          return http.Response(code, 200);
        }),
      );
      await client.fetchHome(site);
      backend
        ..fail = true
        ..failureCode = 'timeout';
      await expectLater(
        client.fetchHome(site),
        throwsA(
          isA<PythonSourceException>()
              .having((error) => error.code, 'failure category', 'timeout')
              .having(
                (error) => error.toString(),
                'readable timeout',
                '片源响应超时，请重试或切换其他片源',
              ),
        ),
      );
      expect(downloads, 1);
      expect(backend.methods, ['home', 'home']);
      expect(backend.opened, hasLength(1));
    },
  );

  test(
    'native owner capacity error is explained before source execution',
    () async {
      final backend = NativeBackend()..openingFailure = 'runtime_limit';
      addTearDown(backend.dispose);
      final client = CmsClient(
        pythonHost: backend.host,
        client: MockClient((_) async => http.Response(code, 200)),
      );
      await expectLater(
        client.fetchHome(site),
        throwsA(
          isA<PythonSourceException>().having(
            (error) => error.toString(),
            'busy message',
            'Python 片源正在处理其他请求，请稍后重试',
          ),
        ),
      );
      expect(backend.methods, isEmpty);
      expect(backend.opened, isEmpty);
    },
  );

  test(
    'application deadline explains timeout while the native call is still finishing',
    () async {
      final backend = NativeBackend()..pending = Completer<void>();
      addTearDown(backend.dispose);
      final client = CmsClient(
        pythonHost: backend.host,
        client: MockClient((_) async => http.Response(code, 200)),
      );
      await expectLater(
        client.fetchHome(site),
        throwsA(
          isA<PythonSourceException>().having(
            (error) => error.toString(),
            'deadline message',
            '片源响应超时，请重试或切换其他片源',
          ),
        ),
      );
      expect(backend.methods, ['home']);
      expect(backend.pending!.isCompleted, false);
      // Let the owned call end before disposal; UI timeout is not native termination.
      backend.pending!.complete();
      backend.pending = null;
    },
  );

  test(
    'subscription removal during entry download prevents native execution',
    () async {
      final backend = NativeBackend();
      addTearDown(backend.dispose);
      final entered = Completer<void>();
      final reply = Completer<http.Response>();
      final client = CmsClient(
        pythonHost: backend.host,
        client: MockClient((_) {
          entered.complete();
          return reply.future;
        }),
      );
      final result = expectLater(client.fetchHome(site), throwsStateError);
      await entered.future;
      backend.host.retainSessions({});
      reply.complete(http.Response(code, 200));
      await result;
      expect(backend.opened, isEmpty);
    },
  );

  test(
    'same subscription opens a fresh owner after explicit removal',
    () async {
      final backend = NativeBackend();
      addTearDown(backend.dispose);
      var downloads = 0;
      final client = CmsClient(
        pythonHost: backend.host,
        client: MockClient((_) async {
          downloads++;
          return http.Response(code, 200);
        }),
      );
      await client.fetchHome(site);
      backend.host.retainSessions({});
      await client.fetchHome(site);
      expect(backend.opened, hasLength(2));
      expect(downloads, 2);
    },
  );

  test('remote credentials become headers while archive paths are bounded', () {
    final uri = Uri(
      scheme: 'https',
      host: 'source.example',
      userInfo: 'owned:fixture',
      path: '/script.php',
    );
    final package = PythonSourceHost.packageFromSource(
      entry: '$uri',
      source: code,
      extension: '',
    );
    expect(package.remote!.url.userInfo, isEmpty);
    expect(
      package.remote!.headers['Authorization'],
      'Basic ${base64Encode(utf8.encode('owned:fixture'))}',
    );
    expect(
      () => PythonSourceHost.packageFromSource(
        entry: 'pkg://local/main.py',
        source: code,
        extension: '',
        packageData: {
          'entry': '../main.py',
          'files': {
            '../main.py': base64Encode([1]),
          },
        },
      ),
      throwsFormatException,
    );
  });
}
