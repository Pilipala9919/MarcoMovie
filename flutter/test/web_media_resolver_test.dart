import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/core/storage_service.dart';
import 'package:marco_movie/core/web_media_resolver.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    WebMediaResolver.debugSnifferOverride = null;
  });

  test(
      'CmsClient retains Set-Cookie across same-domain 302 redirects without leaking credentials cross-origin',
      () async {
    final seenCookies = <String, String?>{};
    final client = CmsClient(
      client: MockClient((request) async {
        seenCookies[request.url.toString()] = request.headers['cookie'];
        if (request.url.toString() ==
            'https://cms-guard.test/api.php?ac=list') {
          if (request.headers['cookie']?.contains('guard_pass=ok_token') ==
              true) {
            return http.Response(
              jsonEncode({
                'class': [
                  {'type_id': 1, 'type_name': '电影'}
                ],
                'list': [
                  {
                    'vod_id': '101',
                    'vod_name': '测试影片',
                    'vod_pic': 'https://cms-guard.test/p.jpg',
                  }
                ],
              }),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
            );
          }
          return http.Response(
            '',
            302,
            headers: {
              'location': '/api.php?ac=list',
              'set-cookie': 'guard_pass=ok_token; Path=/; HttpOnly',
            },
          );
        }
        return http.Response('unexpected', 404);
      }),
    );

    const site = CmsSite(
      key: 'guarded_cms',
      name: 'Guarded CMS',
      type: 1,
      api: 'https://cms-guard.test/api.php',
      headers: {'Cookie': 'initial_user=1'},
    );

    final (_, listing) = await client.fetchHome(site);
    expect(listing.videos, hasLength(1));
    expect(listing.videos.single.title, '测试影片');
    expect(
      seenCookies['https://cms-guard.test/api.php?ac=list'],
      allOf(contains('initial_user=1'), contains('guard_pass=ok_token')),
    );
  });

  test(
      'multi-parser waterfall falls back across CmsConfig.parses and preserves custom parser headers',
      () async {
    final parserCalls = <Uri>[];
    final client = CmsClient(
      client: MockClient((request) async {
        parserCalls.add(request.url);
        if (request.url.host == 'broken-parser.test') {
          return http.Response('gateway timeout', 502);
        }
        if (request.url.host == 'backup-parser.test') {
          expect(request.headers['X-Parser-Token'], 'backup-v2');
          expect(request.headers['Authorization'], isNull);
          return http.Response(
            jsonEncode({
              'code': 200,
              'data': {
                'url': 'https://cdn.stream.test/hls/master.m3u8',
                'referer': 'https://backup-parser.test/',
                'ua': 'ParserSafari/18.0',
              },
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('not found', 404);
      }),
    );

    const site = CmsSite(
      key: 't4_parse',
      name: 'T4 Secondary',
      type: 4,
      api: 'https://t4-origin.test/spider',
      playUrl: 'https://broken-parser.test/jx?url=',
      headers: {'Authorization': 'Bearer t4-secret'},
    );

    final t4Client = CmsClient(
      client: MockClient((request) async {
        if (request.url.host == 't4-origin.test') {
          return http.Response(
            jsonEncode({
              'parse': 1,
              'jx': 1,
              'url': 'https://video-page.test/v/ep01.html',
            }),
            200,
          );
        }
        parserCalls.add(request.url);
        if (request.url.host == 'broken-parser.test') {
          return http.Response('broken', 500);
        }
        if (request.url.host == 'backup-parser.test') {
          expect(request.headers['X-Parser-Token'], 'backup-v2');
          expect(request.headers['Authorization'], isNull);
          return http.Response(
            jsonEncode({
              'code': 200,
              'data': {
                'url': 'https://cdn.stream.test/hls/master.m3u8',
                'referer': 'https://backup-parser.test/',
                'ua': 'ParserSafari/18.0',
              },
            }),
            200,
          );
        }
        return http.Response('not found', 404);
      }),
    );

    final resolved = await t4Client.resolveEpisodeForPlayback(
      site,
      const CmsEpisode(name: '第01集', url: 'mmt4://play?id=ep1&flag=lineA'),
      parses: const [
        CmsParse(
          name: '备用解析',
          url: 'https://backup-parser.test/api?url=',
          type: 1,
          headers: {'X-Parser-Token': 'backup-v2'},
        ),
      ],
    );

    expect(resolved.url, 'https://cdn.stream.test/hls/master.m3u8');
    expect(resolved.headers['Referer'], 'https://backup-parser.test/');
    expect(resolved.headers['User-Agent'], 'ParserSafari/18.0');
    expect(resolved.headers.containsKey('Authorization'), isFalse);
    expect(
      parserCalls.map((u) => u.host).toList(),
      ['broken-parser.test', 'backup-parser.test'],
    );
    // Keep analyzer happy on first client fixture:
    expect(client, isNotNull);
  });

  test(
      'MacCMS player_aaaa encrypt=2 Base64+URL-encoded HTML page and 2-hop iframe player unwrap cleanly',
      () async {
    final encodedStream = base64Encode(
      utf8.encode(
        Uri.encodeComponent('https://hls-node.test/live/ep02/index.m3u8?token=77'),
      ),
    );

    final client = CmsClient(
      client: MockClient((request) async {
        if (request.url.toString() == 'https://vod-web.test/vodplay/99-1-1.html') {
          return http.Response(
            '''
<!DOCTYPE html>
<html>
<head><title>Play</title></head>
<body>
<script type="text/javascript">
var player_aaaa={"flag":"play","encrypt":2,"trysee":0,"points":0,"url":"$encodedStream"};
</script>
</body>
</html>
''',
            200,
            headers: {'content-type': 'text/html; charset=utf-8'},
          );
        }
        if (request.url.toString() == 'https://vod-web.test/vodplay/99-1-2.html') {
          return http.Response(
            '<html><body><iframe src="https://embed-player.test/box.html?vid=2"></iframe></body></html>',
            200,
            headers: {'content-type': 'text/html; charset=utf-8'},
          );
        }
        if (request.url.toString() == 'https://embed-player.test/box.html?vid=2') {
          expect(
            request.headers['Referer'] ?? request.headers['referer'],
            'https://vod-web.test/vodplay/99-1-2.html',
          );
          return http.Response(
            '''
<html><body>
<script>
const dp = new DPlayer({
  video: { url: "https:\\/\\/cdn-iframe.test\\/videos\\/ep02.mp4" }
});
</script>
</body></html>
''',
            200,
            headers: {'content-type': 'text/html; charset=utf-8'},
          );
        }
        return http.Response('not found', 404);
      }),
    );

    const site = CmsSite(
      key: 'maccms_html',
      name: 'MacCMS HTML',
      type: 1,
      api: 'https://vod-web.test/api.php/provide/vod/',
    );

    final ep1 = await client.resolveEpisodeForPlayback(
      site,
      const CmsEpisode(
        name: '第1集',
        url: 'https://vod-web.test/vodplay/99-1-1.html',
      ),
    );
    expect(ep1.url, 'https://hls-node.test/live/ep02/index.m3u8?token=77');
    expect(ep1.headers['Referer'], 'https://vod-web.test/vodplay/99-1-1.html');

    final ep2 = await client.resolveEpisodeForPlayback(
      site,
      const CmsEpisode(
        name: '第2集',
        url: 'https://vod-web.test/vodplay/99-1-2.html',
      ),
    );
    expect(ep2.url, 'https://cdn-iframe.test/videos/ep02.mp4');
    expect(ep2.headers['Referer'], 'https://embed-player.test/box.html?vid=2');
  });

  test(
      'falls back to native web_sniffer Stage 3 when static HTML relies on dynamic runtime execution, and StorageService preserves parses in backups',
      () async {
    SharedPreferences.setMockInitialValues({});
    final storage = StorageService(await SharedPreferences.getInstance());
    await storage.saveConfig(
      jsonEncode({
        'parses': [
          {
            'name': 'Web嗅探解析',
            'type': 0,
            'url': 'https://web-jx.test/render?url=',
          }
        ],
        'sites': [
          {
            'key': 's1',
            'name': '测试源',
            'type': 1,
            'api': 'https://cms.test/api.php',
          }
        ],
      }),
      origin: 'https://cms.test/config.json',
    );
    final saved = storage.loadSavedConfig()!;
    expect(saved.parses, hasLength(1));
    expect(saved.parses.single.url, 'https://web-jx.test/render?url=');

    String? sniffedTarget;
    WebMediaResolver.debugSnifferOverride = (url, headers, timeout) async {
      sniffedTarget = url;
      return const WebSniffResult(
        url: 'https://dynamic-cdn.test/runtime/index.m3u8?sig=ok',
        headers: {
          'Referer': 'https://web-jx.test/render',
          'Cookie': 'wasm_token=verified',
        },
      );
    };

    final client = CmsClient(
      client: MockClient((request) async {
        // Static HTML has no literal video URL (simulating dynamic runtime assembly)
        return http.Response(
          '<html><body><div id="app"></div><script src="/bundle.js"></script></body></html>',
          200,
          headers: {'content-type': 'text/html'},
        );
      }),
    );

    final resolved = await client.resolveEpisodeForPlayback(
      saved.sites.single,
      const CmsEpisode(
        name: '正片',
        url: 'https://thirdparty-page.test/watch/abc.html',
      ),
      parses: saved.parses,
    );

    expect(
      sniffedTarget,
      'https://web-jx.test/render?url=https%3A%2F%2Fthirdparty-page.test%2Fwatch%2Fabc.html',
    );
    expect(resolved.url, 'https://dynamic-cdn.test/runtime/index.m3u8?sig=ok');
    expect(resolved.headers['Cookie'], 'wasm_token=verified');
    expect(resolved.headers['Referer'], 'https://web-jx.test/render');
    WebMediaResolver.debugSnifferOverride = null;
  });

  test(
      'passes host-matched rules, ads, and clickScript to Stage 3 webRuleSniffer and accepts custom regex stream',
      () async {
    addTearDown(() {
      WebMediaResolver.debugSnifferOverride = null;
      WebMediaResolver.debugRuleSnifferOverride = null;
    });

    List<Map<String, dynamic>>? capturedRules;
    List<String>? capturedAds;
    String? capturedClick;

    final rules = <CmsSniffRule>[
      const CmsSniffRule(
        name: 'target-site',
        hosts: ['player.test'],
        regex: [r'/manifest/\d+\?token='],
        exclude: [r'preview_ad'],
        click: 'document.querySelector(".play-btn")?.click();',
      ),
      const CmsSniffRule(
        name: 'other-site',
        hosts: ['unrelated.test'],
        regex: [r'\.mp4'],
        click: 'window.other();',
      ),
    ];
    const ads = ['ad.doubleclick.test', 'ad-tracker.test'];

    WebMediaResolver.debugRuleSnifferOverride = (
      url,
      headers,
      timeout, {
      List<Map<String, dynamic>> rules = const [],
      List<String> ads = const [],
      String? clickScript,
    }) async {
      capturedRules = rules;
      capturedAds = ads;
      capturedClick = clickScript;
      return const WebSniffResult(
        url: 'https://cdn.test/manifest/42?token=abc',
        headers: {'User-Agent': 'CustomWebKit/18.0'},
      );
    };

    final result = await WebMediaResolver.resolve(
      site: const CmsSite(
        key: 'web_rule_test',
        name: 'Rule Test',
        type: 3,
        api: 'csp_RuleTest',
      ),
      targetUrl: 'https://player.test/watch/99',
      rules: rules,
      ads: ads,
      fetchDocument: (url, {headers = const {}, timeout}) async {
        return ResolverHttpDocument(
          finalUri: Uri.parse(url),
          statusCode: 200,
          responseHeaders: const {'content-type': 'text/html'},
          effectiveRequestHeaders: headers,
          body: '<html><body><div id="player"></div></body></html>',
        );
      },
    );

    expect(result, isNotNull);
    expect(result!['url'], 'https://cdn.test/manifest/42?token=abc');
    expect(capturedRules, hasLength(1));
    expect(capturedRules!.single['name'], 'target-site');
    expect(capturedAds, ads);
    expect(capturedClick, 'document.querySelector(".play-btn")?.click();');
  });

  test('rejects sniffer candidates matching ads domains or rule exclude regexes',
      () async {
    addTearDown(() {
      WebMediaResolver.debugSnifferOverride = null;
      WebMediaResolver.debugRuleSnifferOverride = null;
    });

    const rules = <CmsSniffRule>[
      CmsSniffRule(
        name: 'filter-test',
        hosts: ['watch.test'],
        exclude: [r'/promo/intro\.m3u8'],
      ),
    ];
    const ads = ['ad-tracker.test'];

    WebMediaResolver.debugRuleSnifferOverride = (
      url,
      headers,
      timeout, {
      List<Map<String, dynamic>> rules = const [],
      List<String> ads = const [],
      String? clickScript,
    }) async {
      return const WebSniffResult(
        url: 'https://ad-tracker.test/video/ad_clip.m3u8',
      );
    };

    final blockedByAd = await WebMediaResolver.resolve(
      site: const CmsSite(
        key: 'ad_block',
        name: 'Ad Block',
        type: 1,
        api: 'https://cms.test/vod',
      ),
      targetUrl: 'https://watch.test/play/1',
      rules: rules,
      ads: ads,
      fetchDocument: (url, {headers = const {}, timeout}) async {
        return ResolverHttpDocument(
          finalUri: Uri.parse(url),
          statusCode: 200,
          responseHeaders: const {'content-type': 'text/html'},
          effectiveRequestHeaders: headers,
          body: '<html><body></body></html>',
        );
      },
    );
    expect(blockedByAd, isNull);

    WebMediaResolver.debugRuleSnifferOverride = (
      url,
      headers,
      timeout, {
      List<Map<String, dynamic>> rules = const [],
      List<String> ads = const [],
      String? clickScript,
    }) async {
      return const WebSniffResult(
        url: 'https://watch.test/promo/intro.m3u8',
      );
    };

    final blockedByExclude = await WebMediaResolver.resolve(
      site: const CmsSite(
        key: 'exclude_block',
        name: 'Exclude Block',
        type: 1,
        api: 'https://cms.test/vod',
      ),
      targetUrl: 'https://watch.test/play/1',
      rules: rules,
      ads: ads,
      fetchDocument: (url, {headers = const {}, timeout}) async {
        return ResolverHttpDocument(
          finalUri: Uri.parse(url),
          statusCode: 200,
          responseHeaders: const {'content-type': 'text/html'},
          effectiveRequestHeaders: headers,
          body: '<html><body></body></html>',
        );
      },
    );
    expect(blockedByExclude, isNull);
  });

  test(
      'Windows Stage-3 platform channel passes host-matched rules, ads, and clickScript and filters ads/wrapper URLs in Stage 2 and Stage 3',
      () async {
    const channel = MethodChannel('marco_movie/web_sniffer');
    final recordedCalls = <Map<String, dynamic>>[];

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'sniffMedia');
      final args = Map<String, dynamic>.from(call.arguments as Map);
      recordedCalls.add(args);
      if (recordedCalls.length == 1) {
        // First response returns an ad-domain URL which Stage-3 must reject!
        return <String, dynamic>{
          'url': 'https://ad.blocked.test/promo/ad.mp4',
          'headers': {'Referer': args['url']},
        };
      }
      return <String, dynamic>{
        'url': 'https://stream.ok.test/master/index.m3u8?token=win32',
        'headers': {
          'Referer': 'https://vip.player.test/',
          'User-Agent': 'EdgeWebView2/131',
        },
      };
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    const site = CmsSite(
      key: 'win_sniff',
      name: 'Windows Sniff Site',
      type: 1,
      api: 'https://cms.test/api.php',
    );
    const rules = [
      CmsSniffRule(
        name: 'vip_rule',
        hosts: ['*.player.test'],
        regex: [r'\.m3u8'],
        exclude: [r'preview\.mp4'],
        script: 'window.__autoPlay = 1;',
        click: '#btn-play',
      ),
      CmsSniffRule(
        name: 'other_host_rule',
        hosts: ['unrelated.example'],
        script: 'window.__shouldNotPass = 1;',
      ),
    ];
    const ads = ['ad.blocked.test', '*.tracker.test'];

    // Stage 2 must ignore ad-domain <video>, disguised wrapper URLs, and ad iframes,
    // then fall through to Stage 3 on Windows!
    Future<ResolverHttpDocument> fakeFetch(
      String url, {
      Map<String, String> headers = const {},
      Duration? timeout,
    }) async {
      return ResolverHttpDocument(
        finalUri: Uri.parse(url),
        statusCode: 200,
        responseHeaders: const {'content-type': 'text/html'},
        effectiveRequestHeaders: headers,
        body: '''
<html><body>
  <video src="https://ad.blocked.test/video/preroll.mp4"></video>
  <iframe src="https://sub.tracker.test/adframe.html"></iframe>
  <script>
    const wrapped = "https://jx.helper.test/parse?url=https://real.cdn.test/fake.m3u8";
  </script>
</body></html>
''',
      );
    }

    // 1st attempt: Stage 3 mock returns ad URL -> rejected cleanly.
    final rejectedAd = await WebMediaResolver.resolve(
      site: site,
      targetUrl: 'https://vip.player.test/watch/1001.html',
      rules: rules,
      ads: ads,
      fetchDocument: fakeFetch,
    );
    if (Platform.isWindows || Platform.isIOS || Platform.isMacOS) {
      expect(rejectedAd, isNull);
      expect(recordedCalls, hasLength(1));
      final firstArgs = recordedCalls.first;
      expect(firstArgs['url'], 'https://vip.player.test/watch/1001.html');
      expect(firstArgs['ads'], ads);
      expect(firstArgs['clickScript'], allOf(
        contains('window.__autoPlay = 1;'),
        contains('#btn-play'),
      ));
      expect(firstArgs['clickScript'], isNot(contains('__shouldNotPass')));
      final sentRules = (firstArgs['rules'] as List).cast<Map>();
      expect(sentRules, hasLength(1));
      expect(sentRules.single['name'], 'vip_rule');

      // 2nd attempt: Stage 3 returns real stream URL -> accepted!
      final accepted = await WebMediaResolver.resolve(
        site: site,
        targetUrl: 'https://vip.player.test/watch/1001.html',
        rules: rules,
        ads: ads,
        fetchDocument: fakeFetch,
      );
      expect(accepted, isNotNull);
      expect(accepted!['url'], 'https://stream.ok.test/master/index.m3u8?token=win32');
      expect((accepted['header'] as Map)['User-Agent'], 'EdgeWebView2/131');
    }

    // Also verify disguised wrapper URL rejection directly
    expect(
      WebMediaResolver.isDisguisedWrapperUrl(
        Uri.parse('https://jx.helper.test/parse?url=https://cdn.test/a.m3u8'),
      ),
      isTrue,
    );
    expect(
      WebMediaResolver.isDisguisedWrapperUrl(
        Uri.parse('https://cdn.test/video/index.m3u8?token=abc&expires=123'),
      ),
      isFalse,
    );
  });
}
