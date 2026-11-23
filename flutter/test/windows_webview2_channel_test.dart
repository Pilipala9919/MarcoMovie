import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/core/desktop_webview_js_bridge.dart';
import 'package:marco_movie/core/js_source_host.dart';

class _DirectHttpOverrides extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const jsChannel = MethodChannel('marco_movie/webview_js');
  const snifferChannel = MethodChannel('marco_movie/web_sniffer');

  setUp(() {
    DesktopWebViewJsBridge.debugForcePlatformSupported = true;
    DesktopWebViewJsBridge.instance.resetForTesting();
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(jsChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(snifferChannel, null);
    await JsSourceHost.closeAll();
    DesktopWebViewJsBridge.instance.resetForTesting();
    DesktopWebViewJsBridge.debugForcePlatformSupported = null;
  });

  test(
    'gracefully degrades when Edge WebView2 plugin or runtime is absent (Windows LTSC)',
    () async {
      // No mock handler -> MissingPluginException
      expect(await DesktopWebViewJsBridge.instance.isAvailable(), isFalse);
      final jsStatus = await DesktopWebViewJsBridge.instance.getStatus();
      expect(jsStatus['available'], isFalse);
      final snifferStatus = await DesktopWebViewJsBridge.instance
          .getSnifferStatus();
      expect(snifferStatus['available'], isFalse);

      // Explicit PlatformException / unavailable status
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(jsChannel, (call) async {
            if (call.method == 'isAvailable') return false;
            if (call.method == 'getStatus') {
              return <String, dynamic>{
                'available': false,
                'version': '',
                'reason': 'webview2_runtime_not_found',
              };
            }
            return null;
          });
      DesktopWebViewJsBridge.instance.resetForTesting();
      expect(await DesktopWebViewJsBridge.instance.isAvailable(), isFalse);
      final status = await DesktopWebViewJsBridge.instance.getStatus();
      expect(status['available'], isFalse);
      expect(status['reason'], 'webview2_runtime_not_found');
    },
  );

  test(
    'web_sniffer channel serializes rules, ads, clickScript, headers, and handles timeout null',
    () async {
      final capturedCalls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(snifferChannel, (call) async {
            capturedCalls.add(call);
            if (call.method == 'isAvailable') return true;
            if (call.method == 'getStatus') {
              return <String, dynamic>{
                'available': true,
                'version': '131.0.2903.86',
                'userDataDir': r'C:\ProgramData\MarcoMovie\cache\webview2',
              };
            }
            if (call.method == 'sniffMedia') {
              final args = Map<String, dynamic>.from(call.arguments as Map);
              if (args['url'] == 'https://timeout.test/play.html') {
                return null;
              }
              return <String, dynamic>{
                'url': 'https://cdn.test/live/index.m3u8?token=abc',
                'headers': <String, String>{
                  'Referer': args['url'] as String,
                  'User-Agent': 'CustomUA/1.0',
                  'Cookie': 'sid=xyz',
                },
              };
            }
            return null;
          });

      expect(
        await snifferChannel.invokeMethod<bool>('isAvailable'),
        isTrue,
      );
      final status = await DesktopWebViewJsBridge.instance.getSnifferStatus();
      expect(status['available'], isTrue);
      expect(status['version'], '131.0.2903.86');

      final sniffRes = await snifferChannel.invokeMapMethod<String, dynamic>(
        'sniffMedia',
        <String, dynamic>{
          'url': 'https://player.test/watch/123.html',
          'headers': <String, String>{'User-Agent': 'CustomUA/1.0'},
          'timeoutMs': 8000,
          'rules': <Map<String, dynamic>>[
            <String, dynamic>{
              'name': 'hls',
              'hosts': <String>['player.test'],
              'regex': <String>[r'https://cdn\.test/.*\.m3u8'],
              'exclude': <String>[r'preview\.m3u8'],
            },
          ],
          'ads': <String>['doubleclick.net', 'ad.player.test'],
          'clickScript': 'document.querySelector(".play-btn")?.click();',
        },
      );

      expect(sniffRes, isNotNull);
      expect(sniffRes!['url'], 'https://cdn.test/live/index.m3u8?token=abc');
      final hdrs = Map<String, dynamic>.from(sniffRes['headers'] as Map);
      expect(hdrs['Cookie'], 'sid=xyz');
      expect(hdrs['User-Agent'], 'CustomUA/1.0');

      final sent = Map<String, dynamic>.from(
        capturedCalls.last.arguments as Map,
      );
      expect(sent['timeoutMs'], 8000);
      expect(sent['ads'], ['doubleclick.net', 'ad.player.test']);
      expect(
        sent['clickScript'],
        'document.querySelector(".play-btn")?.click();',
      );
      expect((sent['rules'] as List).single['hosts'], ['player.test']);

      // Timeout returns null cleanly
      final timeoutRes = await snifferChannel.invokeMapMethod<String, dynamic>(
        'sniffMedia',
        <String, dynamic>{
          'url': 'https://timeout.test/play.html',
          'timeoutMs': 1500,
        },
      );
      expect(timeoutRes, isNull);
    },
  );

  test(
    'DesktopWebViewJsBridge.executeHttpRequest enforces headers, redirect isolation, and buffer=2 base64',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final crossOrigin = await HttpServer.bind(
          InternetAddress.loopbackIPv4,
          0,
        );
        addTearDown(() => crossOrigin.close(force: true));
        final sameOrigin = await HttpServer.bind(
          InternetAddress.loopbackIPv4,
          0,
        );
        addTearDown(() => sameOrigin.close(force: true));

        final crossBase = 'http://127.0.0.1:${crossOrigin.port}';
        final sameBase = 'http://127.0.0.1:${sameOrigin.port}';

        crossOrigin.listen((req) async {
          // Must strip cookie & authorization on cross-origin redirect
          expect(req.headers.value('cookie'), isNull);
          expect(req.headers.value('authorization'), isNull);
          req.response.write('redirected-ok');
          await req.response.close();
        });

        sameOrigin.listen((req) async {
          if (req.uri.path == '/api') {
            expect(req.headers.value('x-source-token'), 'secret123');
            req.response.write('{"ok":true}');
          } else if (req.uri.path == '/bin') {
            req.response.add([1, 2, 3, 4]);
          } else if (req.uri.path == '/redir') {
            req.response.statusCode = 302;
            req.response.headers.set('location', '$crossBase/target');
          }
          await req.response.close();
        });

        final apiResp = await DesktopWebViewJsBridge.executeHttpRequest(
          url: '$sameBase/api',
          entryOrigin: '$sameBase/spider.js',
          sourceHeaders: const {'X-Source-Token': 'secret123'},
        );
        expect(apiResp['code'], 200);
        expect(apiResp['content'], '{"ok":true}');

        final binResp = await DesktopWebViewJsBridge.executeHttpRequest(
          url: '$sameBase/bin',
          options: const {'buffer': 2},
        );
        expect(binResp['code'], 200);
        expect(binResp['content'], base64Encode([1, 2, 3, 4]));

        final redirResp = await DesktopWebViewJsBridge.executeHttpRequest(
          url: '$sameBase/redir',
          entryOrigin: '$sameBase/spider.js',
          sourceHeaders: const {'Cookie': 'a=1', 'Authorization': 'Bearer tok'},
        );
        expect(redirResp['code'], 200);
        expect(redirResp['content'], 'redirected-ok');
      }, _DirectHttpOverrides());
    },
  );

  test(
    'JsSourceHost automatically falls back to DesktopWebViewJsBridge on browser API errors and cleans up sessions',
    () async {
      final evalCalls = <Map<String, dynamic>>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(jsChannel, (call) async {
            if (call.method == 'isAvailable') return true;
            if (call.method == 'sleep') return true;
            if (call.method == 'evalSpider') {
              final args = Map<String, dynamic>.from(call.arguments as Map);
              evalCalls.add(args);
              if (args['action'] == 'disposeSession') {
                return <String, dynamic>{'available': true, 'ok': true};
              }
              return <String, dynamic>{
                'available': true,
                'ok': true,
                'result': jsonEncode({
                  'list': [
                    {'vod_id': 'wv1', 'vod_name': 'WebView2 DOM 解析成功'},
                  ],
                }),
              };
            }
            return null;
          });

      const entry = 'pkg://local/dom_spider.mjs';
      const domSpider = '''
export default {
  home() {
    const doc = new DOMParser().parseFromString('<b>WebView2</b>', 'text/html');
    return { list: [{ vod_id: 'wv1', vod_name: doc.body.textContent }] };
  },
  play(flag, id) {
    return { url: 'https://cdn.test/' + id + '.m3u8' };
  }
};
''';

      final homeOut = await JsSourceHost.invoke(
        entry: entry,
        modules: const {entry: domSpider},
        method: 'home',
        arguments: const [],
        sessionKey: 'dom-session',
      );
      expect(jsonDecode(homeOut)['list'][0]['vod_name'], 'WebView2 DOM 解析成功');
      expect(evalCalls, hasLength(1));
      expect(evalCalls.single['method'], 'home');
      expect(evalCalls.single['modules'], isA<Map>());
      expect(evalCalls.single['proxyBase'], isNotEmpty);

      // Subsequent callCached routes directly to the fallback WebView2 session
      // without re-sending modules.
      final playOut = await JsSourceHost.callCached(
        sessionKey: 'dom-session',
        method: 'play',
        arguments: const ['HD', 'ep1'],
      );
      expect(playOut, isNotNull);
      expect(evalCalls, hasLength(2));
      expect(evalCalls[1]['method'], 'play');
      expect(evalCalls[1].containsKey('modules'), isFalse);

      // Session retention/cleanup disposes fallback sessions too.
      await JsSourceHost.retainSessions({});
      expect(
        evalCalls.any((c) => c['action'] == 'disposeSession' && c['sessionId'] == 'dom-session'),
        isTrue,
      );
    },
  );

  test(
    'JsSourceHost.callCached falls back when a cached QuickJS session hits browser-only APIs mid-lifecycle',
    () async {
      final evalCalls = <Map<String, dynamic>>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(jsChannel, (call) async {
            if (call.method == 'isAvailable') return true;
            if (call.method == 'sleep') return true;
            if (call.method == 'evalSpider') {
              final args = Map<String, dynamic>.from(call.arguments as Map);
              evalCalls.add(args);
              return <String, dynamic>{
                'available': true,
                'ok': true,
                'result': '{"url":"https://cdn.test/subtle.m3u8"}',
              };
            }
            return null;
          });

      const entry = 'pkg://local/subtle_spider.mjs';
      const spider = '''
export default {
  home() {
    return { list: [{ vod_id: '1', vod_name: 'OK' }] };
  },
  async play() {
    await crypto.subtle.digest('SHA-256', new TextEncoder().encode('abc'));
    return { url: 'https://cdn.test/subtle.m3u8' };
  }
};
''';

      // home() works in QuickJS directly without touching WebView2.
      final homeOut = await JsSourceHost.invoke(
        entry: entry,
        modules: const {entry: spider},
        method: 'home',
        arguments: const [],
        sessionKey: 'subtle-session',
      );
      expect(jsonDecode(homeOut)['list'][0]['vod_name'], 'OK');
      expect(evalCalls, isEmpty);

      // play() hits crypto.subtle -> fails in QuickJS -> seamlessly falls back!
      final playOut = await JsSourceHost.callCached(
        sessionKey: 'subtle-session',
        method: 'play',
        arguments: const [],
      );
      expect(jsonDecode(playOut!)['url'], 'https://cdn.test/subtle.m3u8');
      expect(evalCalls, hasLength(1));
      expect(evalCalls.single['method'], 'play');
    },
  );

  test(
    'non-browser failures and timeouts never trigger WebView2 fallback',
    () async {
      var evalTriggered = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(jsChannel, (call) async {
            if (call.method == 'isAvailable') return true;
            if (call.method == 'evalSpider') {
              evalTriggered = true;
            }
            return null;
          });

      const entry = 'pkg://local/bad.mjs';
      await expectLater(
        JsSourceHost.invoke(
          entry: entry,
          modules: const {entry: 'throw "fixture_failure"; export default {}'},
          method: 'home',
          arguments: const [],
        ),
        throwsA(isA<StateError>()),
      );
      expect(evalTriggered, isFalse);

      expect(
        DesktopWebViewJsBridge.shouldFallbackFromError(
          TimeoutException('脚本请求超时'),
        ),
        isFalse,
      );
      expect(
        DesktopWebViewJsBridge.shouldFallbackFromError(
          StateError('脚本操作已取消'),
        ),
        isFalse,
      );
      expect(
        DesktopWebViewJsBridge.shouldFallbackFromError(
          const FormatException('当前脚本需要 CatVod 宿主模块，该接口尚未适配'),
        ),
        isFalse,
      );
      expect(
        DesktopWebViewJsBridge.shouldFallbackFromError(
          StateError("ReferenceError: 'DOMParser' is not defined"),
        ),
        isTrue,
      );
      expect(
        DesktopWebViewJsBridge.shouldFallbackFromError(
          StateError("TypeError: cannot read property 'subtle' of undefined"),
        ),
        isTrue,
      );
    },
  );

  test(
    'evalSpider timeout rejects cleanly when native WebView2 does not reply in time',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(jsChannel, (call) async {
            if (call.method == 'isAvailable') return true;
            if (call.method == 'evalSpider') {
              await Future<void>.delayed(const Duration(seconds: 5));
              return null;
            }
            return null;
          });

      await expectLater(
        DesktopWebViewJsBridge.instance.invoke(
          entry: 'pkg://local/slow.mjs',
          modules: const {'pkg://local/slow.mjs': 'export default {home(){}}'},
          method: 'home',
          arguments: const [],
          budget: const Duration(milliseconds: 100),
        ),
        throwsA(isA<TimeoutException>()),
      );
    },
  );
}
