// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:marco_movie/core/danmu/block_filter.dart';
import 'package:marco_movie/core/danmu/dandanplay_provider.dart';
import 'package:marco_movie/core/danmu/danmu_prefs.dart';
import 'package:marco_movie/core/danmu/provider.dart';
import 'package:marco_movie/core/danmu/segment_cache.dart';
import 'package:marco_movie/core/ohos_runtime.dart';

void main() {
  tearDown(() {
    OhosRuntime.resetForTesting();
  });

  group('Defaults, Base64url, SHA-256 & Source Binding SSRF Guard', () {
    test('default server URLs are strictly empty', () {
      expect(DandanplayProvider.defaultServerUrls, isEmpty);
      final provider = DandanplayProvider();
      addTearDown(provider.close);
      expect(provider.configuredOrigins, isEmpty);

      const settings = DanmuSettings();
      expect(settings.serverUrls, isEmpty);
      expect(settings.appId, isEmpty);
      expect(settings.appSecret, isEmpty);
      expect(settings.enabled, isFalse);
    });

    test('RFC 4648 Base64url no-padding roundtrip & Open API v2 signature', () {
      final samples = <List<int>>[
        <int>[],
        <int>[0xFB],
        <int>[0xFB, 0xFF],
        <int>[0xFB, 0xFF, 0xBF],
        utf8.encode('https://danmu.example:8443/v2'),
        utf8.encode('a+b/c=d?e&f'),
      ];
      for (final sample in samples) {
        final enc = DandanplayProvider.base64UrlEncodeNoPad(sample);
        expect(enc.contains('='), isFalse);
        expect(enc.contains('+'), isFalse);
        expect(enc.contains('/'), isFalse);
        expect(DandanplayProvider.base64UrlDecode(enc), equals(sample));
      }

      final sig = DandanplayProvider.computeOpenApiSignature(
        appId: 'demoApp',
        timestampSec: 1700000000,
        urlPath: '/api/v2/match',
        appSecret: 'demoSecret',
      );
      expect(sig.length, 44);
      expect(sig.endsWith('='), isTrue);
    });

    test('mmdanmu://v1 roundtrip preserves literal + and enforces SSRF whitelist',
        () {
      const origin = 'https://node-a.danmu.test:8443/prefix/';
      final bound = DandanplayProvider.encodeBoundEpisodeId(origin, 'ep+42/sub');
      expect(bound.startsWith('mmdanmu://v1?src='), isTrue);

      final whitelist = <String>['https://node-a.danmu.test:8443/prefix'];
      final decoded = DandanplayProvider.decodeBoundEpisodeId(bound, whitelist);
      expect(decoded.origin, 'https://node-a.danmu.test:8443/prefix');
      expect(decoded.rawEpisodeId, 'ep+42/sub');

      // Unlisted host rejected
      final evilBound = DandanplayProvider.encodeBoundEpisodeId(
        'https://evil.invalid',
        '1001',
      );
      expect(
        () => DandanplayProvider.decodeBoundEpisodeId(evilBound, whitelist),
        throwsFormatException,
      );

      // Forbidden schemes & userinfo rejected
      expect(
        DandanplayProvider.normalizeOriginOrNull('file:///etc/passwd'),
        isNull,
      );
      expect(
        DandanplayProvider.normalizeOriginOrNull('ftp://danmu.example'),
        isNull,
      );
      expect(
        DandanplayProvider.normalizeOriginOrNull('https://user@danmu.example'),
        isNull,
      );
      expect(
        DandanplayProvider.normalizeOriginOrNull(
          Uri(scheme: 'https', userInfo: 'u:p', host: 'danmu.example')
              .toString(),
        ),
        isNull,
      );
      expect(
        DandanplayProvider.normalizeOriginOrNull('http://danmu.example/a b'),
        isNull,
      );
      expect(
        DandanplayProvider.normalizeOriginOrNull('http://bad_host.test'),
        isNull,
      );

      // Server cap = 8
      const tenUrls = 'https://s1.danmu.test\n'
          'https://s2.danmu.test\n'
          'https://s3.danmu.test\n'
          'https://s4.danmu.test\n'
          'https://s5.danmu.test\n'
          'https://s6.danmu.test\n'
          'https://s7.danmu.test\n'
          'https://s8.danmu.test\n'
          'https://s9.danmu.test\n'
          'https://s10.danmu.test';
      expect(DandanplayProvider.parseConfiguredOrigins(tenUrls).length, 8);
    });

    test('IPv6 literal origins preserve brackets and roundtrip through Uri.tryParse & mmdanmu://v1',
        () {
      const httpProto = 'http';
      const httpsProto = 'https';
      final v6PortPath = DandanplayProvider.normalizeOriginOrNull(
        '$httpProto://[::1]:8080/path/',
      );
      expect(v6PortPath, '$httpProto://[::1]:8080/path');
      final parsedPortPath = Uri.tryParse(v6PortPath!);
      expect(parsedPortPath, isNotNull);
      expect(parsedPortPath!.host, '::1');
      expect(parsedPortPath.port, 8080);
      expect(parsedPortPath.path, '/path');

      final v6HttpsDefault = DandanplayProvider.normalizeOriginOrNull(
        '$httpsProto://[2001:DB8::1]:443/api/',
      );
      expect(v6HttpsDefault, '$httpsProto://[2001:db8::1]/api');
      expect(Uri.tryParse(v6HttpsDefault!), isNotNull);

      expect(
        DandanplayProvider.normalizeOriginOrNull('$httpProto://[::1]:80'),
        '$httpProto://[::1]',
      );
      final v6Bare =
          DandanplayProvider.normalizeOriginOrNull('$httpProto://[::1]');
      expect(v6Bare, '$httpProto://[::1]');
      expect(Uri.tryParse(v6Bare!), isNotNull);

      final bound = DandanplayProvider.encodeBoundEpisodeId(v6PortPath, 'ep-v6');
      final decoded = DandanplayProvider.decodeBoundEpisodeId(
        bound,
        <String>[v6PortPath],
      );
      expect(decoded.origin, v6PortPath);
      expect(decoded.rawEpisodeId, 'ep-v6');
    });
  });

  group('O(N) Static ReDoS Blocker & BlockFilter', () {
    test('rejects catastrophic & high-polynomial backtracking constructs (Java parity vector)',
        () {
      final rejected = <String>[
        // Report bypasses (ungrouped adjacent quantifiers)
        r're:a+a+a+a+a+a+a+a+b',
        r're:[^x]*[^x]*[^x]*[^x]*[^x]*[^x]*[^x]*b',
        // Additional ungrouped / chained / hidden-group / alternation adversarial rules
        r're:a+a+b',
        r're:a+a+a+a+b',
        r're:[^x]*[^x]*[^x]*b',
        r're:\w+\w+\w+\w+!',
        r're:\d+\d+\d+\d+x',
        r're:[a-z]{1,10}[a-z]{1,10}[a-z]{1,10}[a-z]{1,10}z',
        r're:a+b?a+b?a+c',
        r're:(?:a+)(?:a+)(?:a+)b',
        r're:a+.*a+.*a+b',
        r're:.*.*b',
        r're:(?:a|aa)+$',
        r're:(a|a)(a|a)(a|a)(a|a)(a|a)(a|a)(a|a)(a|a)(a|a)(a|a)b',
        r're:(a|ab)(a|ab)(a|ab)(a|ab)(a|ab)(a|ab)(a|ab)(a|ab)(a|ab)(a|ab)b',
        r're:a?a?a?a?a?a?a?a?a?a?b',
        r're:a++',
        r're:a+*',
        r're:a??',
        r're:a*?+',
        r're:a{1,2}*',
        r're:(?=a)b',
        r're:(?!a)b',
        r're:\k<x>',
        r're:^+a',
        r're:$+',
        r're:\b+a',
        r're:a{1,65}',
        r're:a{0}',
        r're:[a-z]{1,20}[a-z]{1,20}z',
        r're:[a-z]{1,30}[a-z]{1,30}z',
        r're:(a|a)(a|a)(a|a)(a|a)(a|a)(a|a)z',
        r're:a+z|a+z|a+z|a+z',
        r're:a.*b|c.*d|e.*f|g.*h',
        // Gate 1 R1 F-1A ({N}/literal suffix amplification & Cartesian alternation)
        r're:a+a{30}a{30}b|a+a{30}a{30}b|a+a{30}a{30}b',
        r're:[a-z]{1,5}[a-z]{1,5}a{60}b|[a-z]{1,5}[a-z]{1,5}a{60}b|[a-z]{1,5}[a-z]{1,5}a{60}b|[a-z]{1,5}[a-z]{1,5}a{60}b',
        r're:([a-z]|[a-z]|[a-z])[a-z]+[a-z]{60}b',
        r're:[a-z]+[a-z]{1,3}[a-z]{60}b',
        r're:[a-z]*?[a-z]{1,3}?[a-z]{60}b',
        r're:(a|a|a)a+a{60}b',
        're:a+${'a' * 110}b',
        r're:(a|aa)(a|aa)(a|aa)(a|aa)(a|aa)Z',
        r're:[^x]*[a-z]{0,2}y',
        r're:[a-z]{1,5}[a-z]{1,5}z',
        r're:(a|a|a)[a-z]+z',
        // Gate 1 R2 F-1D (prefix chains, TwoByte 3-branch unbounded & bounded spikes)
        r're:a{20}a{20}a{20}a{20}a+b',
        r're:a{20}a+x|a{20}a+y|a{20}a+z',
        r're:[^x]{20}[^x]{20}[^x]{20}[^x]{20}[^x]+y|[^x]{20}[^x]{20}[^x]{20}[^x]{20}[^x]+z',
        r're:[a-z]{20}[a-z]{20}[a-z]{20}[a-z]{15}[a-z]+[a-z]{2}z',
        r're:[a-z]+z|[a-z]+z|[a-z]+z',
        r're:[a-z]{1,4}[a-z]{1,4}[a-z]{3}z|[a-z]{1,3}[a-z]{1,3}[a-z]{6}z',
        r're:(a|aa|aaa|aaaa)(a|aa|aaa|aaaa)[a-z]{3}z|(a|aa|aaa)(a|aa|aaa)z',
        r're:a+a{15}b',
        r're:[a-z]+[a-z]{6}z',
        r're:.*aaaaaaaaab',
        r're:.*ababababax',
        r're:a.*b|c.*d|e.*f',
        // Gate 1 R3 F-1F (non-ASCII case-folded literal delimiter & suffix bucketing)
        're:\u00E9+\u00C9.*z',
        're:\u0151+\u0150.*z',
        're:\u03B1+\u0391.*z',
        're:\u03B1+\u0391[^\\n]*z',
        're:.*\u00E9\u00C9\u00E9\u00C9\u00E9\u00C9\u00E9\u00C9\u00E9z',
        // Gate 1 R1 F-1B (UTF-16 surrogates / supplementary codepoints parity)
        're:[\uD83D\uDE00-\\uFFFF]',
        r're:[\uD83D\uDE00-\uFFFF]',
        're:[\uD83D\uDE00-\uFF5E]',
        're:\uD83D\uDE00',
        // Gate 1 R1 F-1C (Java vs Dart whitespace trimming parity)
        '\u3000',
        're:\u3000',
        '\u3000re:(a|aa)+\$',
        '\u00A0re:(a|aa)+\$',
        '\uFEFFre:(a|aa)+\$',
        '\u0000re:(a|aa)+\$',
        '\u001Fre:(a|aa)+\$',
        r're:\Qfoo\E',
        r're:[a[b]]',
        r're:[a-z&&[^bc]]',
        r're:[]a]',
        r're:a||b',
        r're:()a',
        // Existing spec rejection suite
        r're:(a|aa)+$',
        r're:(a+)+',
        r're:(a?)+',
        r're:(.*a){20}',
        r're:([a-z]|a)+$',
        r're:(foo)?',
        r're:(bar)*',
        r're:([0-9]+){2,5}',
        r're:abc\1',
        r're:(?<=pre)word',
        r're:(?<!pre)word',
        r're:(?i)spoiler',
        r're:a.*b.*c.*d.*e',
        're:${'a' * 121}',
        're:',
        '   ',
      ];
      for (final rule in rejected) {
        final vr = DanmuBlockFilter.validateRule(rule);
        expect(vr.valid, isFalse, reason: 'Expected rejection for $rule');
      }
    });

    test('accepts safe regexes and matches 180-char adversarial inputs in < 5ms',
        () {
      const accepted = <String>[
        '剧透',
        '\uD83D\uDE00',
        're:剧透|打卡',
        're:第(一|二)章',
        're:(第|共)(一|二|三)章',
        're:[0-9]{4,}',
        r're:foo\)bar+',
        r're:foo.*bar',
        r're:剧透.+结局',
        r're:.*剧透预警',
        r're:\s+keyword',
        r're:[a-z]+\.com',
        r're:第\d+集.*剧透预警',
        r're:广告.*链接',
        r're:(微信|QQ|VX)\d{5,}',
        r're:https?://[a-z0-9.-]+',
        r're:a.*b|c.*d',
        r're:^前排|沙发$',
        r're:[a-z]{1,4}[0-9]{1,4}',
        r're:(a|aa)(a|aa)z',
        r're:[a-z]+z|[a-z]+z',
        r're:(a|a)[a-z]+z',
        r're:[a-z]+[a-z]{2}z',
        r're:[^x]{20}[^x]+y|[^x]{20}[^x]+z',
        r're:剧+透.*预警',
        r're:(?:foo|bar).*?z',
      ];
      final adversarialInputs = <String>[
        '${'a' * 179}!',
        '${'a' * 179}\u4e00',
        '${'\u0150' * 179}!',
        '${'\u4e00' * 179}!',
        '${'1' * 179}!',
      ];
      for (final rule in accepted) {
        final vr = DanmuBlockFilter.validateRule(rule);
        expect(vr.valid, isTrue, reason: 'Expected valid for $rule: ${vr.error}');
        final single = DanmuBlockFilter.compile(<String>[rule]);
        // Benchmark every single call (cold call0..warm call5) across OneByte & TwoByte 180-char inputs
        var maxCallMs = 0.0;
        for (final sample in adversarialInputs) {
          for (var run = 0; run < 6; run++) {
            final sw = Stopwatch()..start();
            single.isBlocked(sample);
            sw.stop();
            var ms = sw.elapsedMicroseconds / 1000.0;
            if (ms >= 5.0) {
              // Guard against hypervisor thread preemption on shared CI VMs.
              final retryFilter = run == 0
                  ? DanmuBlockFilter.compile(<String>[rule])
                  : single;
              final retrySw = Stopwatch()..start();
              retryFilter.isBlocked(sample);
              retrySw.stop();
              final retryMs = retrySw.elapsedMicroseconds / 1000.0;
              if (retryMs < ms) ms = retryMs;
            }
            if (ms > maxCallMs) maxCallMs = ms;
          }
        }
        expect(
          maxCallMs,
          lessThan(5.0),
          reason:
              'Accepted rule peaked at ${maxCallMs.toStringAsFixed(3)}ms on 180-char input: $rule',
        );
      }

      final filter = DanmuBlockFilter.compile(<String>[
        'Spoiler',
        're:第(一|二)章',
        r're:(a|aa)+$',
      ]);
      expect(filter.ruleCount, 2);
      expect(filter.isBlocked('HUGE spoiler ahead'), isTrue);
      expect(filter.isBlocked('请看第二章'), isTrue);
      expect(filter.isBlocked('正常弹幕'), isFalse);

      // 100-rule maximum
      final many = List<String>.generate(130, (i) => 'rule$i');
      expect(DanmuBlockFilter.compile(many).ruleCount, 100);
    });
  });

  group('3-Stage Protocol, Signatures, Full-Episode Fallback & SSRF', () {
    test('signed/unsigned headers, multi-source isolation & full-episode fallback',
        () async {
      String? seenAppId;
      String? seenTs;
      String? seenSig;
      String? seenPath;

      final mockClient = MockClient((req) async {
        if (req.url.host == 'bad.danmu.test') {
          return http.Response('error', 500);
        }
        if (req.url.path == '/api/v2/match') {
          seenAppId = req.headers['X-AppId'];
          seenTs = req.headers['X-Timestamp'];
          seenSig = req.headers['X-Signature'];
          seenPath = req.url.path;
          return http.Response(
            jsonEncode(<String, dynamic>{
              'isMatched': true,
              'matches': <Map<String, dynamic>>[
                <String, dynamic>{
                  'episodeId': 10001,
                  'animeId': 500,
                  'animeTitle': 'Sample Show',
                  'episodeTitle': 'Ep 1',
                },
              ],
            }),
            200,
          );
        }
        if (req.url.path == '/api/v2/bangumi/500') {
          return http.Response(
            jsonEncode(<String, dynamic>{
              'bangumi': <String, dynamic>{
                'animeTitle': 'Sample Show',
                'episodes': <Map<String, dynamic>>[
                  <String, dynamic>{'episodeId': 10001, 'episodeTitle': 'Ep 1'},
                  <String, dynamic>{'episodeId': 10002, 'episodeTitle': 'Ep 2'},
                ],
              },
            }),
            200,
          );
        }
        if (req.url.path == '/api/v2/comment/10001') {
          return http.Response(
            jsonEncode(<String, dynamic>{
              'count': 3,
              'comments': <Map<String, dynamic>>[
                <String, dynamic>{
                  'cid': 1,
                  'p': '2.5,1,16777215,u1',
                  'm': 'first',
                },
                <String, dynamic>{
                  'cid': 2,
                  'p': '35.0,5,16711680,u2',
                  'm': 'second window',
                },
                <String, dynamic>{
                  'cid': 1,
                  'p': '2.5,1,16777215,u1',
                  'm': 'dup ignored',
                },
              ],
            }),
            200,
          );
        }
        if (req.url.path == '/api/v2/comment/evilseg') {
          return http.Response(
            jsonEncode(<String, dynamic>{
              'segments': <Map<String, dynamic>>[
                <String, dynamic>{
                  'startMs': 0,
                  'endMs': 30000,
                  'segmentUrl': 'https://unlisted.invalid/s0.json',
                },
              ],
            }),
            200,
          );
        }
        return http.Response('not found', 404);
      });

      final signed = DandanplayProvider(
        multilineServerUrls: 'https://bad.danmu.test\nhttps://good.danmu.test',
        appId: 'testAppId',
        appSecret: 'testSecret',
        minRequestIntervalMs: 0,
        client: mockClient,
      );

      final matches = await signed.matchOrSearch(
        const DanmuMatchQuery(
          title: 'Sample Show',
          episodeTitle: 'Ep 1',
          episodeIndex: 1,
          durationSec: 1440,
        ),
      );
      expect(matches.length, 1);
      expect(seenAppId, 'testAppId');
      expect(seenTs, isNotNull);
      expect(
        seenSig,
        DandanplayProvider.computeOpenApiSignature(
          appId: 'testAppId',
          timestampSec: int.parse(seenTs!),
          urlPath: seenPath!,
          appSecret: 'testSecret',
        ),
      );

      // Unsigned omits signature headers
      seenAppId = null;
      final unsigned = DandanplayProvider(
        multilineServerUrls: 'https://good.danmu.test',
        minRequestIntervalMs: 0,
        client: mockClient,
      );
      await unsigned.matchOrSearch(const DanmuMatchQuery(title: 'Sample Show'));
      expect(seenAppId, isNull);

      final eps = await unsigned.listEpisodes('https://good.danmu.test', '500');
      expect(eps.length, 2);
      expect(eps.first.boundEpisodeId.startsWith('mmdanmu://v1?'), isTrue);

      final fullSession = await unsigned.openSession(eps.first.boundEpisodeId);
      expect(fullSession.segmented, isFalse);
      expect(fullSession.preloadComments.length, 2);

      final w0 = await unsigned.fetchWindow(fullSession, 0);
      final w1 = await unsigned.fetchWindow(fullSession, 1);
      expect(w0.map((e) => e.text).toList(), <String>['first']);
      expect(w1.map((e) => e.text).toList(), <String>['second window']);

      // Unlisted segmentUrl SSRF rejection
      final evilBound = DandanplayProvider.encodeBoundEpisodeId(
        'https://good.danmu.test',
        'evilseg',
      );
      await expectLater(
        () => unsigned.openSession(evilBound),
        throwsFormatException,
      );

      // XML external entity rejection
      expect(
        () => DandanplayProvider.parseDanmuPayload(
          '<?xml version="1.0"?><!DOCTYPE x [<!ENTITY e "boom">]><i><d p="1,1,25,16777215">&e;</d></i>',
        ),
        throwsFormatException,
      );
    });
  });

  group('Segmented Cache: Boundary Continuity, Negative Offset, 410 Singleflight, Seek Storm',
      () {
    test('negative offset (-10s), 60% prefetch, 30s boundary continuity & 3-window pinning',
        () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final origin = 'http://127.0.0.1:${server.port}';

      server.listen((req) async {
        final path = req.uri.path;
        if (path == '/api/v2/comment/ep-seg') {
          final segs = List<Map<String, dynamic>>.generate(
            30,
            (w) => <String, dynamic>{
              'startMs': w * 30000,
              'endMs': (w + 1) * 30000,
              'segmentUrl': '/seg/$w',
            },
          );
          req.response
            ..statusCode = 200
            ..headers.contentType = ContentType.json
            ..write(jsonEncode(<String, dynamic>{'segments': segs}));
          await req.response.close();
          return;
        }
        if (path.startsWith('/seg/')) {
          final w = int.parse(path.substring('/seg/'.length));
          late Map<String, dynamic> body;
          if (w == 0) {
            body = <String, dynamic>{
              'comments': <Map<String, dynamic>>[
                <String, dynamic>{
                  'cid': 'c0',
                  'p': '0.0,1,16777215',
                  'm': 'intro-zero',
                },
                <String, dynamic>{
                  'cid': 'c285',
                  'p': '28.5,1,16777215',
                  'm': 'crossing-boundary',
                },
              ],
            };
          } else if (w == 1) {
            body = <String, dynamic>{
              'comments': <Map<String, dynamic>>[
                <String, dynamic>{
                  'cid': 'c305',
                  'p': '30.5,1,16777215',
                  'm': 'after-boundary',
                },
              ],
            };
          } else {
            body = <String, dynamic>{
              'comments': List<Map<String, dynamic>>.generate(
                900,
                (i) => <String, dynamic>{
                  'cid': 'w${w}_$i',
                  'p': '${w * 30.0 + i * 0.02},1,16777215',
                  'm': 'msg-$i',
                },
              ),
            };
          }
          req.response
            ..statusCode = 200
            ..headers.contentType = ContentType.json
            ..write(jsonEncode(body));
          await req.response.close();
          return;
        }
        req.response.statusCode = 404;
        await req.response.close();
      });

      final provider = DandanplayProvider(
        multilineServerUrls: origin,
        minRequestIntervalMs: 0,
      );
      addTearDown(provider.close);
      final cache = DanmuSegmentCache(provider: provider);
      addTearDown(cache.dispose);

      final boundId = DandanplayProvider.encodeBoundEpisodeId(origin, 'ep-seg');
      await cache.bindSession(boundId);
      expect(cache.currentSession?.segmented, isTrue);

      // Negative offset (-10000ms): 0.0s danmu MUST NOT freeze during first 10s
      cache.setTimeOffsetMs(-10000);
      cache.onPlaybackTick(0, playing: true);
      await cache.waitUntilIdle();
      expect(cache.isWindowCached(0), isTrue);
      expect(cache.snapshotForPosition(0), isEmpty);
      expect(cache.snapshotForPosition(5000), isEmpty);
      expect(cache.snapshotForPosition(9999), isEmpty);
      final at10s = cache.snapshotForPosition(10000);
      expect(at10s.map((e) => e.text).toList(), <String>['intro-zero']);

      // Reset offset -> 60% prefetch at 18500ms -> boundary continuity at 31500ms
      cache.setTimeOffsetMs(0);
      cache.onPlaybackTick(18500, playing: true);
      await cache.waitUntilIdle();
      expect(cache.isWindowCached(1), isTrue);

      cache.onPlaybackTick(31500, playing: true);
      final boundary = cache.snapshotForPosition(31500);
      expect(
        boundary.map((e) => e.text).toList(),
        <String>['crossing-boundary', 'after-boundary'],
      );

      // Heavy eviction: load 26 more windows (900 items each) -> dual cap & 3-window pinning
      for (var w = 2; w < 28; w++) {
        cache.onPlaybackTick(w * 30000 + 1000, playing: false);
        await cache.waitUntilIdle();
      }
      expect(
        cache.cachedWindowCount,
        lessThanOrEqualTo(DanmuSegmentCache.maxCachedWindows),
      );
      expect(
        cache.totalCachedItemCount,
        lessThanOrEqualTo(DanmuSegmentCache.maxTotalItems),
      );
      expect(cache.isWindowCached(26), isTrue);
      expect(cache.isWindowCached(27), isTrue);
    });

    test('concurrent HTTP 410 triggers singleflight refresh & caps at <= 3/episode',
        () async {
      var openCount = 0;
      var epochVer = 0;
      var always410 = false;
      final segFetches = <int, int>{};

      final client = MockClient((req) async {
        if (req.url.path == '/api/v2/comment/ep-410') {
          openCount++;
          if (openCount > 1) {
            await Future<void>.delayed(const Duration(milliseconds: 60));
          }
          epochVer++;
          final segs = List<Map<String, dynamic>>.generate(
            6,
            (w) => <String, dynamic>{
              'startMs': w * 30000,
              'endMs': (w + 1) * 30000,
              'segmentUrl': '/seg410/v$epochVer/$w',
            },
          );
          return http.Response(jsonEncode(<String, dynamic>{'segments': segs}), 200);
        }
        if (req.url.path.startsWith('/seg410/')) {
          final parts = req.url.path.split('/');
          final ver = int.parse(parts[2].substring(1));
          final w = int.parse(parts[3]);
          segFetches[w] = (segFetches[w] ?? 0) + 1;
          if (always410 || (ver == 1 && (w == 0 || w == 1))) {
            return http.Response('expired', 410);
          }
          return http.Response(
            jsonEncode(<String, dynamic>{
              'comments': <Map<String, dynamic>>[
                <String, dynamic>{
                  'cid': 'ok_$w',
                  'p': '${w * 30 + 1}.0,1,16777215',
                  'm': 'recovered-$w',
                },
              ],
            }),
            200,
          );
        }
        return http.Response('not found', 404);
      });

      final provider = DandanplayProvider(
        multilineServerUrls: 'https://node-a.danmu.test',
        minRequestIntervalMs: 0,
        client: client,
      );
      final cache = DanmuSegmentCache(provider: provider);
      addTearDown(cache.dispose);

      final boundId = DandanplayProvider.encodeBoundEpisodeId(
        'https://node-a.danmu.test',
        'ep-410',
      );
      await cache.bindSession(boundId);
      // Concurrently trigger window 0 and prefetch window 1 (both hit 410 on v1)
      cache.onPlaybackTick(19000, playing: true);
      await cache.waitUntilIdle();

      expect(cache.session410RefreshCount, 1);
      expect(openCount, 2); // 1 initial + 1 singleflight refresh
      expect(cache.sessionEpoch, 1);
      expect(cache.snapshotForPosition(1500).length, 1);
      expect(cache.snapshotForPosition(31500).length, 1);

      // Persistent 410 across windows 2..5 -> strictly <= 3 total refreshes & <= 2 attempts/window
      always410 = true;
      for (var w = 2; w <= 5; w++) {
        cache.onPlaybackTick(w * 30000 + 1000, playing: false);
        await cache.waitUntilIdle();
      }
      expect(
        cache.session410RefreshCount,
        lessThanOrEqualTo(DanmuSegmentCache.maxSession410Refreshes),
      );
      for (var w = 2; w <= 5; w++) {
        expect(segFetches[w] ?? 0, lessThanOrEqualTo(2));
      }
    });

    test('180ms seek storm debounce cancels intermediate targets', () async {
      final requested = <int>[];
      final client = MockClient((req) async {
        if (req.url.path == '/api/v2/comment/ep-seek') {
          final segs = List<Map<String, dynamic>>.generate(
            12,
            (w) => <String, dynamic>{
              'startMs': w * 30000,
              'endMs': (w + 1) * 30000,
              'segmentUrl': '/seekseg/$w',
            },
          );
          return http.Response(jsonEncode(<String, dynamic>{'segments': segs}), 200);
        }
        if (req.url.path.startsWith('/seekseg/')) {
          final w = int.parse(req.url.path.substring('/seekseg/'.length));
          requested.add(w);
          return http.Response(
            jsonEncode(<String, dynamic>{
              'comments': <Map<String, dynamic>>[
                <String, dynamic>{
                  'cid': 's$w',
                  'p': '${w * 30 + 2}.0,1,16777215',
                  'm': 'seek-win-$w',
                },
              ],
            }),
            200,
          );
        }
        return http.Response('not found', 404);
      });

      final provider = DandanplayProvider(
        multilineServerUrls: 'https://node-a.danmu.test',
        minRequestIntervalMs: 0,
        client: client,
      );
      final cache = DanmuSegmentCache(provider: provider, seekDebounceMs: 180);
      addTearDown(cache.dispose);

      final boundId = DandanplayProvider.encodeBoundEpisodeId(
        'https://node-a.danmu.test',
        'ep-seek',
      );
      await cache.bindSession(boundId);

      cache.onSeekChanged(2 * 30000 + 5000);
      await Future<void>.delayed(const Duration(milliseconds: 25));
      cache.onSeekChanged(4 * 30000 + 5000);
      await Future<void>.delayed(const Duration(milliseconds: 25));
      cache.onSeekChanged(6 * 30000 + 5000);
      await Future<void>.delayed(const Duration(milliseconds: 25));
      cache.onSeekChanged(10 * 30000 + 5000);

      expect(requested, isEmpty);
      await cache.waitUntilIdle();
      expect(requested, <int>[10]);
      expect(
        cache.snapshotForPosition(10 * 30000 + 5000).map((e) => e.text).toList(),
        <String>['seek-win-10'],
      );
    });

    test('real HttpServer delayed w0 (900ms) + seek storm aborts transport request promptly',
        () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final origin = 'http://127.0.0.1:${server.port}';
      final w0Started = Completer<void>();

      server.listen((req) async {
        try {
          if (req.uri.path == '/api/v2/comment/ep-abort') {
            final segs = List<Map<String, dynamic>>.generate(
              12,
              (w) => <String, dynamic>{
                'startMs': w * 30000,
                'endMs': (w + 1) * 30000,
                'segmentUrl': '/abortseg/$w',
              },
            );
            req.response
              ..statusCode = 200
              ..headers.contentType = ContentType.json
              ..write(jsonEncode(<String, dynamic>{'segments': segs}));
            await req.response.close();
            return;
          }
          if (req.uri.path.startsWith('/abortseg/')) {
            final w = int.parse(req.uri.path.substring('/abortseg/'.length));
            if (w == 0) {
              if (!w0Started.isCompleted) w0Started.complete();
              await Future<void>.delayed(const Duration(milliseconds: 900));
            }
            req.response
              ..statusCode = 200
              ..headers.contentType = ContentType.json
              ..write(
                jsonEncode(<String, dynamic>{
                  'comments': <Map<String, dynamic>>[
                    <String, dynamic>{
                      'cid': 'a$w',
                      'p': '${w * 30 + 2}.0,1,16777215',
                      'm': 'abort-win-$w',
                    },
                  ],
                }),
              );
            await req.response.close();
            return;
          }
          req.response.statusCode = 404;
          await req.response.close();
        } catch (_) {
          // Client legitimately aborted connection mid-flight.
        }
      });

      final provider = DandanplayProvider(
        multilineServerUrls: origin,
        minRequestIntervalMs: 0,
      );
      addTearDown(provider.close);
      final cache = DanmuSegmentCache(provider: provider, seekDebounceMs: 180);
      addTearDown(cache.dispose);

      final boundId = DandanplayProvider.encodeBoundEpisodeId(origin, 'ep-abort');
      await cache.bindSession(boundId);

      // Start slow w0 (900ms server delay)
      cache.onPlaybackTick(2000, playing: true);
      await w0Started.future.timeout(const Duration(seconds: 2));

      // Trigger seek storm -> must abort in-flight w0 immediately, NOT wait 900ms!
      final sw = Stopwatch()..start();
      cache.onSeekChanged(2 * 30000 + 5000);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      cache.onSeekChanged(6 * 30000 + 5000);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      cache.onSeekChanged(10 * 30000 + 5000);

      await cache.waitUntilIdle(timeout: const Duration(milliseconds: 800));
      sw.stop();

      expect(
        sw.elapsedMilliseconds,
        lessThan(600),
        reason:
            'Seek storm waited ${sw.elapsedMilliseconds}ms (expected < 600ms, NOT 900ms delayed w0)',
      );
      expect(cache.isWindowCached(0), isFalse);
      expect(
        cache.snapshotForPosition(10 * 30000 + 5000).map((e) => e.text).toList(),
        <String>['abort-win-10'],
      );
    });

    test('real HttpServer w0(2500ms) -> w2 -> w0 bounce aborts stale w0 and returns fresh w0',
        () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final origin = 'http://127.0.0.1:${server.port}';
      var w0Hits = 0;
      final firstW0Entered = Completer<void>();

      server.listen((req) async {
        try {
          if (req.uri.path == '/api/v2/comment/ep-bounce') {
            final segs = List<Map<String, dynamic>>.generate(
              4,
              (w) => <String, dynamic>{
                'startMs': w * 30000,
                'endMs': (w + 1) * 30000,
                'segmentUrl': '/bounceseg/$w',
              },
            );
            req.response
              ..statusCode = 200
              ..headers.contentType = ContentType.json
              ..write(jsonEncode(<String, dynamic>{'segments': segs}));
            await req.response.close();
            return;
          }
          if (req.uri.path.startsWith('/bounceseg/')) {
            final w = int.parse(req.uri.path.substring('/bounceseg/'.length));
            var label = 'win-$w';
            if (w == 0) {
              w0Hits++;
              final hit = w0Hits;
              if (hit == 1) {
                label = 'stale-0';
                if (!firstW0Entered.isCompleted) firstW0Entered.complete();
                await Future<void>.delayed(const Duration(milliseconds: 2500));
              } else {
                label = 'fresh-0';
              }
            }
            req.response
              ..statusCode = 200
              ..headers.contentType = ContentType.json
              ..write(
                jsonEncode(<String, dynamic>{
                  'comments': <Map<String, dynamic>>[
                    <String, dynamic>{
                      'cid': 'b_${w}_$label',
                      'p': '${w * 30 + 1}.0,1,16777215',
                      'm': label,
                    },
                  ],
                }),
              );
            await req.response.close();
            return;
          }
          req.response.statusCode = 404;
          await req.response.close();
        } catch (_) {
          // Expected when stale request socket is aborted.
        }
      });

      final provider = DandanplayProvider(
        multilineServerUrls: origin,
        minRequestIntervalMs: 0,
      );
      addTearDown(provider.close);
      final cache = DanmuSegmentCache(provider: provider, seekDebounceMs: 60);
      addTearDown(cache.dispose);

      final boundId = DandanplayProvider.encodeBoundEpisodeId(origin, 'ep-bounce');
      await cache.bindSession(boundId);

      // Kick off slow 2500ms w0
      cache.onPlaybackTick(1500, playing: true);
      await firstW0Entered.future.timeout(const Duration(seconds: 2));

      // Bounce w0 -> w2 -> w0 quickly; must NOT wait 2500ms or time out
      final sw = Stopwatch()..start();
      cache.onSeekChanged(2 * 30000 + 2000);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      cache.onSeekChanged(2000);
      await cache.waitUntilIdle(timeout: const Duration(milliseconds: 1200));
      sw.stop();

      expect(
        sw.elapsedMilliseconds,
        lessThan(1000),
        reason: 'w0(2500ms)->w2->w0 bounce took ${sw.elapsedMilliseconds}ms',
      );
      expect(w0Hits, 2);
      expect(
        cache.snapshotForPosition(2000).map((e) => e.text).toList(),
        <String>['fresh-0'],
      );
    });

    test('cancelToken aborts mid-body slow stream immediately without draining remaining chunks',
        () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final origin = 'http://127.0.0.1:${server.port}';
      final firstChunkFlushed = Completer<void>();

      server.listen((req) async {
        try {
          if (req.uri.path == '/api/v2/comment/ep-slowbody') {
            req.response.statusCode = 200;
            req.response.headers.contentType = ContentType.json;
            req.response.bufferOutput = false;
            req.response.write('{"comments":[');
            await req.response.flush();
            if (!firstChunkFlushed.isCompleted) firstChunkFlushed.complete();
            // Hold body open for 2500ms; cancellation must NOT drain this.
            await Future<void>.delayed(const Duration(milliseconds: 2500));
            req.response.write(']}');
            await req.response.close();
            return;
          }
          req.response.statusCode = 404;
          await req.response.close();
        } catch (_) {}
      });

      final provider = DandanplayProvider(
        multilineServerUrls: origin,
        minRequestIntervalMs: 0,
      );
      addTearDown(provider.close);

      final boundId =
          DandanplayProvider.encodeBoundEpisodeId(origin, 'ep-slowbody');
      final token = DanmuCancelToken();
      final future = provider.openSession(boundId, cancelToken: token);

      await firstChunkFlushed.future.timeout(const Duration(seconds: 2));
      final sw = Stopwatch()..start();
      token.cancel();
      await expectLater(future, throwsA(isA<DanmuCancelledException>()));
      sw.stop();

      expect(
        sw.elapsedMilliseconds,
        lessThan(300),
        reason:
            'Mid-body cancellation waited ${sw.elapsedMilliseconds}ms (must not drain 2500ms stream)',
      );
    });

    test('HTTP 429 Retry-After parsing and per-domain >= 200ms rate limit',
        () async {
      expect(DandanplayProvider.parseRetryAfterMs('3'), 3000);
      expect(DandanplayProvider.parseRetryAfterMs(null), 2000);

      final times = <int>[];
      var calls = 0;
      final client = MockClient((req) async {
        times.add(DateTime.now().millisecondsSinceEpoch);
        calls++;
        if (calls == 3) {
          return http.Response('rate limited', 429, headers: {'retry-after': '1'});
        }
        return http.Response('{"episodes":[]}', 200);
      });

      final provider = DandanplayProvider(
        multilineServerUrls: 'https://node-a.danmu.test',
        minRequestIntervalMs: 200,
        client: client,
      );
      await provider.listEpisodes('https://node-a.danmu.test', '1');
      await provider.listEpisodes('https://node-a.danmu.test', '2');
      expect(times[1] - times[0], greaterThanOrEqualTo(180));

      await expectLater(
        () => provider.listEpisodes('https://node-a.danmu.test', '3'),
        throwsA(
          isA<DanmuHttpException>()
              .having((e) => e.statusCode, 'statusCode', 429)
              .having((e) => e.retryAfterMs, 'retryAfterMs', 1000),
        ),
      );
    });
  });

  group('DanmuPrefs & OhosRuntime.isOhos Isolation', () {
    test('prefs roundtrip and OHOS guard disables danmu cleanly', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final initial = await DanmuPrefs.load();
      expect(initial.enabled, isFalse);
      expect(initial.serverUrls, isEmpty);
      expect(initial.opacity, 0.85);
      expect(initial.displayArea, 0.50);
      expect(initial.fontSize, 20.0);

      final updated = initial.copyWith(
        enabled: true,
        serverUrls: 'https://danmu.example',
        opacity: 0.70,
        timeOffsetMs: -2500,
        blockRules: <String>['剧透', r're:(a|aa)+$', 're:第(一|二)章'],
      );
      await DanmuPrefs.save(updated);
      final reloaded = await DanmuPrefs.load();
      expect(reloaded.enabled, isTrue);
      expect(reloaded.effectiveEnabled, isTrue);
      expect(reloaded.serverUrls, 'https://danmu.example');
      expect(reloaded.timeOffsetMs, -2500);
      expect(reloaded.blockRules, <String>['剧透', 're:第(一|二)章']);

      // Under OhosRuntime.isOhos == true, effectiveEnabled is forced false
      OhosRuntime.debugIsOhosOverride = true;
      expect(reloaded.effectiveEnabled, isFalse);
      final ohosLoaded = await DanmuPrefs.load();
      expect(ohosLoaded.enabled, isFalse);

      var networkCalled = false;
      final provider = DandanplayProvider(
        multilineServerUrls: 'https://danmu.example',
        client: MockClient((_) async {
          networkCalled = true;
          return http.Response('{}', 200);
        }),
      );
      expect(
        await provider.matchOrSearch(const DanmuMatchQuery(title: 'Test')),
        isEmpty,
      );
      expect(networkCalled, isFalse);
    });
  });

  group('L-04 Dart: DanmuSegmentCache cached snapshot reuse & invalidation', () {
    test(
      'reuses cached snapshot reference across steady frames and invalidates on filter/offset/window changes',
      () async {
        final client = MockClient((req) async {
          if (req.url.path == '/api/v2/comment/ep-cache') {
            return http.Response(
              jsonEncode(<String, dynamic>{
                'segments': <Map<String, dynamic>>[
                  <String, dynamic>{
                    'startMs': 0,
                    'endMs': 30000,
                    'segmentUrl': '/cseg/0',
                  },
                  <String, dynamic>{
                    'startMs': 30000,
                    'endMs': 60000,
                    'segmentUrl': '/cseg/1',
                  },
                ],
              }),
              200,
            );
          }
          if (req.url.path == '/cseg/0') {
            return http.Response(
              jsonEncode(<String, dynamic>{
                'comments': <Map<String, dynamic>>[
                  <String, dynamic>{
                    'cid': 'a1',
                    'p': '2.0,1,16777215',
                    'm': 'hello world',
                  },
                  <String, dynamic>{
                    'cid': 'a2',
                    'p': '6.0,1,16777215',
                    'm': 'spoiler alert',
                  },
                  <String, dynamic>{
                    'cid': 'a3',
                    'p': '29.0,1,16777215',
                    'm': 'near boundary',
                  },
                ],
              }),
              200,
            );
          }
          if (req.url.path == '/cseg/1') {
            return http.Response(
              jsonEncode(<String, dynamic>{
                'comments': <Map<String, dynamic>>[
                  <String, dynamic>{
                    'cid': 'b1',
                    'p': '31.0,1,16777215',
                    'm': 'next window',
                  },
                ],
              }),
              200,
            );
          }
          return http.Response('not found', 404);
        });

        final provider = DandanplayProvider(
          multilineServerUrls: 'https://node-a.danmu.test',
          minRequestIntervalMs: 0,
          client: client,
        );
        final cache = DanmuSegmentCache(provider: provider);
        addTearDown(cache.dispose);

        final boundId = DandanplayProvider.encodeBoundEpisodeId(
          'https://node-a.danmu.test',
          'ep-cache',
        );
        await cache.bindSession(boundId);
        cache.onPlaybackTick(3000, playing: true);
        await cache.waitUntilIdle();

        // Steady frames within the same visible slice [2s] reuse exact list instance.
        final s1 = cache.snapshotForPosition(3000);
        final s2 = cache.snapshotForPosition(3016);
        final s3 = cache.snapshotForPosition(3032);
        expect(s1.map((e) => e.id).toList(), <String>['a1']);
        expect(identical(s1, s2), isTrue);
        expect(identical(s2, s3), isTrue);

        // Advancing past 6.0s brings in a2.
        final s4 = cache.snapshotForPosition(6500);
        expect(s4.map((e) => e.id).toList(), <String>['a1', 'a2']);
        expect(identical(s4, cache.snapshotForPosition(6516)), isTrue);

        // Updating block filter immediately invalidates cached window pair.
        cache.setBlockFilter(DanmuBlockFilter.compile(<String>['spoiler']));
        final s5 = cache.snapshotForPosition(6516);
        expect(s5.map((e) => e.id).toList(), <String>['a1']);

        // Updating time offset invalidates slice immediately.
        cache.setTimeOffsetMs(-5000);
        expect(cache.snapshotForPosition(6516), isEmpty);
        cache.setTimeOffsetMs(0);

        // Boundary crossing into window 1 merges prev + curr sorted cleanly.
        cache.onPlaybackTick(31500, playing: true);
        await cache.waitUntilIdle();
        final cross = cache.snapshotForPosition(31500);
        expect(cross.map((e) => e.id).toList(), <String>['a3', 'b1']);
        expect(identical(cross, cache.snapshotForPosition(31516)), isTrue);

        // Rebinding empty session clears cached snapshot.
        await cache.bindSession('');
        expect(cache.snapshotForPosition(31500), isEmpty);
      },
    );
  });
}
