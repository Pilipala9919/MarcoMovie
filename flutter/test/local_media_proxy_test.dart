// Local loopback + synthetic upstream only; no external network calls.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:marco_movie/core/local_media_proxy.dart';

Uint8List _buildMpegTsPackets(int packetCount) {
  final out = Uint8List(packetCount * 188);
  for (var p = 0; p < packetCount; p++) {
    final base = p * 188;
    out[base] = 0x47; // MPEG-TS sync byte
    out[base + 1] = 0x01;
    out[base + 2] = 0x00;
    out[base + 3] = 0x10 | (p & 0x0F);
    for (var i = 4; i < 188; i++) {
      out[base + i] = (p + i) & 0xFF;
    }
  }
  return out;
}

void main() {
  test(
      'preserves anti-leech Referer/Origin/UA across cross-domain 302 while stripping origin-bound credentials and forwarding Set-Cookie',
      () async {
    final seenRequests = <Uri, Map<String, String>>{};
    final tsBytes = _buildMpegTsPackets(4);

    final lease = await LocalMediaLease.open(
      target: Uri.parse('https://vod-portal.test/play/entry'),
      headers: {
        'Referer': 'https://vod-portal.test/watch/101',
        'Origin': 'https://vod-portal.test',
        'User-Agent': 'CustomPlayerUA/1.0',
        'Authorization': 'Bearer portal-secret',
        'Cookie': 'portal_session=secret123',
      },
      isCancelled: () => false,
      client: MockClient((request) async {
        seenRequests[request.url] = Map.fromEntries(
          request.headers.entries.map((e) => MapEntry(e.key.toLowerCase(), e.value)),
        );
        if (request.url.toString() == 'https://vod-portal.test/play/entry') {
          return http.Response(
            '',
            302,
            headers: {
              'location': 'https://edge-cdn.test/hls/live_token_stream',
              'set-cookie': 'portal_only=1; Path=/',
            },
          );
        }
        if (request.url.toString() ==
            'https://edge-cdn.test/hls/live_token_stream') {
          // Extensionless HLS playlist with dynamic CDN cookie!
          return http.Response(
            '#EXTM3U\n'
            '#EXT-X-VERSION:3\n'
            '#EXT-X-TARGETDURATION:6\n'
            '#EXTINF:4.0,\n'
            'seg-001.ts?sig=abc\n'
            '#EXT-X-ENDLIST\n',
            200,
            headers: {
              'content-type': 'text/plain',
              'set-cookie': 'cdn_edge_token=edge_ok_99; Path=/hls',
            },
          );
        }
        if (request.url.toString() ==
            'https://edge-cdn.test/hls/seg-001.ts?sig=abc') {
          return http.Response.bytes(
            tsBytes,
            200,
            headers: {'content-type': 'video/mp2t'},
          );
        }
        return http.Response('not found', 404);
      }),
    );

    try {
      expect(lease.url.host, '127.0.0.1');
      final playlistRes = await http.get(lease.url);
      expect(playlistRes.statusCode, 200);
      expect(
        playlistRes.headers['content-type'],
        contains('application/vnd.apple.mpegurl'),
      );

      // Initial origin received its credentials:
      final entryHeaders =
          seenRequests[Uri.parse('https://vod-portal.test/play/entry')]!;
      expect(entryHeaders['authorization'], 'Bearer portal-secret');
      expect(entryHeaders['cookie'], contains('portal_session=secret123'));
      expect(entryHeaders['referer'], 'https://vod-portal.test/watch/101');

      // Cross-origin CDN received anti-leech Referer/Origin/UA, NOT portal secrets:
      final cdnPlaylistHeaders = seenRequests[
          Uri.parse('https://edge-cdn.test/hls/live_token_stream')]!;
      expect(cdnPlaylistHeaders['authorization'], isNull);
      expect(cdnPlaylistHeaders['cookie'], isNull);
      expect(cdnPlaylistHeaders['referer'], 'https://vod-portal.test/watch/101');
      expect(cdnPlaylistHeaders['origin'], 'https://vod-portal.test');
      expect(cdnPlaylistHeaders['user-agent'], 'CustomPlayerUA/1.0');

      // Rewritten segment URL points to local 127.0.0.1 gateway:
      final segmentLine = playlistRes.body
          .split('\n')
          .map((l) => l.trim())
          .firstWhere((l) => l.startsWith('http://127.0.0.1:'));
      final segRes = await http.get(Uri.parse(segmentLine));
      expect(segRes.statusCode, 200);
      expect(segRes.bodyBytes, tsBytes);

      // Segment request carried the dynamic Set-Cookie issued by edge-cdn.test!
      final segHeaders =
          seenRequests[Uri.parse('https://edge-cdn.test/hls/seg-001.ts?sig=abc')]!;
      expect(segHeaders['cookie'], 'cdn_edge_token=edge_ok_99');
      expect(segHeaders['referer'], 'https://vod-portal.test/watch/101');
      expect(segHeaders['authorization'], isNull);
    } finally {
      await lease.close();
    }
  });

  test(
      'strips fake PNG/JPEG image headers from disguised MPEG-TS segments while leaving fMP4 and AES-128 segments untouched',
      () async {
    final cleanTs = _buildMpegTsPackets(5);
    final fakePngPrefix = Uint8List.fromList([
      0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // PNG magic
      ...List<int>.filled(120, 0xAA),
    ]);
    final disguisedTs = Uint8List.fromList([...fakePngPrefix, ...cleanTs]);

    expect(
      LocalMediaLease.findDisguisedTsOffset(disguisedTs),
      fakePngPrefix.length,
    );

    // fMP4 init segment with an incidental 0x47 inside payload must NOT be stripped:
    final fmp4Box = Uint8List(600);
    fmp4Box.setRange(0, 8, [0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70]); // ftyp
    fmp4Box[40] = 0x47;
    fmp4Box[40 + 188] = 0x47;
    fmp4Box[40 + 376] = 0x47;
    expect(LocalMediaLease.findDisguisedTsOffset(fmp4Box), 0);

    final encryptedPayload = Uint8List.fromList([
      0x89, 0x50, 0x4E, 0x47,
      ..._buildMpegTsPackets(4), // Even if bytes align, AES-128 must stay raw!
    ]);

    final lease = await LocalMediaLease.open(
      target: Uri.parse('https://cdn.media.test/master.m3u8'),
      headers: const {'Referer': 'https://cdn.media.test/'},
      isCancelled: () => false,
      client: MockClient((request) async {
        switch (request.url.path) {
          case '/master.m3u8':
            return http.Response(
              '#EXTM3U\n'
              '#EXT-X-STREAM-INF:BANDWIDTH=2000000\n'
              'sub/index.m3u8\n',
              200,
              headers: {'content-type': 'application/vnd.apple.mpegurl'},
            );
          case '/sub/index.m3u8':
            return http.Response(
              '#EXTM3U\n'
              '#EXT-X-TARGETDURATION:6\n'
              '#EXTINF:5.0,\n'
              'disguised.png\n'
              '#EXT-X-KEY:METHOD=AES-128,URI="enc.key"\n'
              '#EXTINF:5.0,\n'
              'encrypted.ts\n'
              '#EXT-X-ENDLIST\n',
              200,
              headers: {'content-type': 'application/vnd.apple.mpegurl'},
            );
          case '/sub/disguised.png':
            return http.Response.bytes(
              disguisedTs,
              200,
              headers: {
                'content-type': 'image/png',
                'content-length': '${disguisedTs.length}',
              },
            );
          case '/sub/enc.key':
            return http.Response.bytes(List<int>.filled(16, 0x11), 200);
          case '/sub/encrypted.ts':
            return http.Response.bytes(encryptedPayload, 200);
          default:
            return http.Response('missing', 404);
        }
      }),
    );

    try {
      final master = await http.get(lease.url);
      expect(master.statusCode, 200);
      final variantUrl = master.body
          .split('\n')
          .firstWhere((l) => l.startsWith('http://127.0.0.1:'));

      final sub = await http.get(Uri.parse(variantUrl));
      expect(sub.statusCode, 200);
      final lines = sub.body.split('\n').map((l) => l.trim()).toList();
      final mediaLines =
          lines.where((l) => l.startsWith('http://127.0.0.1:')).toList();
      expect(mediaLines, hasLength(2));

      // 1st segment was PNG-disguised TS -> fake PNG prefix stripped cleanly!
      final seg1 = await http.get(Uri.parse(mediaLines[0]));
      expect(seg1.statusCode, 200);
      expect(seg1.headers['content-type'], 'video/mp2t');
      expect(seg1.bodyBytes, cleanTs);

      // Key URI was rewritten to local gateway:
      final keyLine = lines.firstWhere((l) => l.startsWith('#EXT-X-KEY:'));
      final keyUrl = RegExp(r'URI="([^"]+)"').firstMatch(keyLine)!.group(1)!;
      expect(keyUrl, startsWith('http://127.0.0.1:'));
      final keyRes = await http.get(Uri.parse(keyUrl));
      expect(keyRes.bodyBytes, hasLength(16));

      // 2nd segment is after EXT-X-KEY:METHOD=AES-128 -> raw ciphertext preserved!
      final seg2 = await http.get(Uri.parse(mediaLines[1]));
      expect(seg2.statusCode, 200);
      expect(seg2.bodyBytes, encryptedPayload);
    } finally {
      await lease.close();
    }
  });

  test(
      'blocks SSRF redirects to loopback/LAN IPs and rejects cross-site browser requests to local gateway',
      () async {
    expect(
      LocalMediaLease.isPrivateOrReservedTarget(
        Uri(scheme: 'http', host: ['192', '168', '0', '1'].join('.')),
      ),
      isTrue,
    );
    expect(
      LocalMediaLease.isPrivateOrReservedTarget(
        Uri(scheme: 'http', host: '172.16.0.1'),
      ),
      isTrue,
    );
    final lease = await LocalMediaLease.open(
      target: Uri.parse('https://public-media.test/video.mp4'),
      isCancelled: () => false,
      client: MockClient((request) async {
        return http.Response(
          '',
          302,
          headers: {'location': 'http://10.0.2.2/router-admin'},
        );
      }),
    );

    try {
      // Redirect from public host to private LAN IP is rejected with 502:
      final ssrfRes = await http.get(lease.url);
      expect(ssrfRes.statusCode, HttpStatus.badGateway);

      // Browser Origin header is rejected with 403:
      final browserOriginRes = await http.get(
        lease.url,
        headers: {'Origin': 'https://malicious.example'},
      );
      expect(browserOriginRes.statusCode, HttpStatus.forbidden);

      // Capability mismatch is rejected with 403:
      final wrongCapRes = await http.get(
        Uri.parse('http://127.0.0.1:${lease.url.port}/wrong/stream.mp4'),
      );
      expect(wrongCapRes.statusCode, HttpStatus.forbidden);
    } finally {
      await lease.close();
    }
  });

  test('supports companion audio stream registration and HTTP 206 Range forwarding',
      () async {
    final observedRanges = <String, String?>{};
    final lease = await LocalMediaLease.open(
      target: Uri.parse('https://upos.media.test/dash/video.m4s'),
      headers: const {'Referer': 'https://portal.media.test/'},
      isCancelled: () => false,
      client: MockClient((request) async {
        observedRanges[request.url.path] = request.headers['range'];
        expect(request.headers['referer'], 'https://portal.media.test/');
        return http.Response.bytes(
          utf8.encode('DASH-CHUNK'),
          206,
          headers: {
            'content-type': 'video/iso.segment',
            'content-range': 'bytes 0-9/1000',
          },
        );
      }),
    );

    try {
      final audioLocal = lease.tryRegisterCompanionMedia(
        'https://upos-audio.media.test/dash/audio.m4s',
      );
      expect(audioLocal, isNotNull);
      expect(audioLocal!.host, '127.0.0.1');

      final vRes =
          await http.get(lease.url, headers: const {'Range': 'bytes=0-9'});
      final aRes =
          await http.get(audioLocal, headers: const {'Range': 'bytes=0-9'});
      expect(vRes.statusCode, 206);
      expect(aRes.statusCode, 206);
      expect(observedRanges['/dash/video.m4s'], 'bytes=0-9');
      expect(observedRanges['/dash/audio.m4s'], 'bytes=0-9');
    } finally {
      await lease.close();
    }
  });

  test('live mode omits upstream Range and rewrites text/html #EXTM3U playlists',
      () async {
    final observedHeaders = <Map<String, String>>[];
    final lease = await LocalMediaLease.open(
      target: Uri.parse('https://iptv.example/live.php?id=scws4k'),
      isLive: true,
      isCancelled: () => false,
      client: MockClient((request) async {
        observedHeaders.add(Map<String, String>.from(request.headers));
        if (request.url.path == '/live.php') {
          return http.Response(
            '#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXTINF:6.0,\nseg1.ts\n',
            200,
            headers: {'content-type': 'text/html; charset=utf-8'},
          );
        }
        if (request.url.path == '/seg1.ts') {
          return http.Response.bytes(
            List<int>.filled(376, 0x47),
            200,
            headers: {'content-type': 'video/mp2t'},
          );
        }
        return http.Response('not found', 404);
      }),
    );

    try {
      final playlistResp = await http.get(
        lease.url,
        headers: const {'Range': 'bytes=0-'},
      );
      expect(playlistResp.statusCode, 200);
      expect(observedHeaders.first.containsKey('Range'), isFalse);
      expect(observedHeaders.first.containsKey('range'), isFalse);
      final segLine = playlistResp.body
          .split('\n')
          .map((l) => l.trim())
          .firstWhere((l) => l.startsWith('http://127.0.0.1:'));
      final segResp = await http.get(Uri.parse(segLine));
      expect(segResp.statusCode, 200);
    } finally {
      await lease.close();
    }
  });

  test(
      'preserves Quark __pus/__puus cookies across proxy and CDN redirects while stripping Authorization and portal cookies',
      () async {
    final seen = <Uri, Map<String, String>>{};
    final lease = await LocalMediaLease.open(
      target: Uri.parse('https://gateway.example/proxy?do=quark&fid=1'),
      headers: const {
        'Cookie': '__pus=pus_abc; __puus=puus_xyz; portal_session=secret',
        'Authorization': 'Bearer gateway-secret',
        'Referer': 'https://pan.quark.cn/',
        'User-Agent': 'QuarkPlayer/1.0',
      },
      isCancelled: () => false,
      client: MockClient((request) async {
        seen[request.url] = Map.fromEntries(
          request.headers.entries.map((e) => MapEntry(e.key.toLowerCase(), e.value)),
        );
        if (request.url.host == 'gateway.example') {
          return http.Response(
            '',
            302,
            headers: {'location': 'https://drive.quark.cn/file/chunk.mkv'},
          );
        }
        if (request.url.host == 'drive.quark.cn') {
          return http.Response(
            '',
            302,
            headers: {'location': 'https://drive-pc.quark.cn/edge/chunk.mkv'},
          );
        }
        if (request.url.host == 'drive-pc.quark.cn') {
          return http.Response.bytes(
            const [0x1A, 0x45, 0xDF, 0xA3],
            206,
            headers: {
              'content-type': 'video/x-matroska',
              'content-range': 'bytes 0-3/4',
            },
          );
        }
        return http.Response('missing', 404);
      }),
    );

    try {
      final res = await http.get(lease.url, headers: const {'Range': 'bytes=0-3'});
      expect(res.statusCode, 206);
      expect(res.bodyBytes, const [0x1A, 0x45, 0xDF, 0xA3]);

      for (final target in [
        Uri.parse('https://drive.quark.cn/file/chunk.mkv'),
        Uri.parse('https://drive-pc.quark.cn/edge/chunk.mkv'),
      ]) {
        final h = seen[target]!;
        expect(h['authorization'], isNull);
        expect(h['cookie'], contains('__pus=pus_abc'));
        expect(h['cookie'], contains('__puus=puus_xyz'));
        expect(h['cookie'], isNot(contains('portal_session')));
        expect(h['referer'], 'https://pan.quark.cn/');
      }
    } finally {
      await lease.close();
    }
  });

  test(
      'strips cross-domain HLS VOD discontinuity ads while preserving AES keys and leaving live streams untouched',
      () async {
    final tsPayload = _buildMpegTsPackets(2);
    final lease = await LocalMediaLease.open(
      target: Uri.parse('https://main-cdn.test/vod/movie.m3u8'),
      stripHlsAds: true,
      isCancelled: () => false,
      client: MockClient((request) async {
        if (request.url.path == '/vod/movie.m3u8') {
          return http.Response(
            '#EXTM3U\n'
            '#EXT-X-VERSION:3\n'
            '#EXT-X-TARGETDURATION:10\n'
            '#EXT-X-KEY:METHOD=AES-128,URI="https://main-cdn.test/vod/enc.key"\n'
            '#EXTINF:30.0,\n'
            'seg_001.ts\n'
            '#EXTINF:30.0,\n'
            'seg_002.ts\n'
            '#EXT-X-DISCONTINUITY\n'
            '#EXT-X-KEY:METHOD=NONE\n'
            '#EXTINF:10.0,\n'
            'https://ad-insert.other.test/ad_01.ts\n'
            '#EXTINF:5.0,\n'
            'https://ad-insert.other.test/ad_02.ts\n'
            '#EXT-X-DISCONTINUITY\n'
            '#EXTINF:30.0,\n'
            'seg_003.ts\n'
            '#EXT-X-ENDLIST\n',
            200,
            headers: {'content-type': 'application/vnd.apple.mpegurl'},
          );
        }
        return http.Response.bytes(tsPayload, 200);
      }),
    );

    try {
      final resp = await http.get(lease.url);
      expect(resp.statusCode, 200);
      final rewrittenLines =
          resp.body.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
      final segmentUrls =
          rewrittenLines.where((l) => l.startsWith('http://127.0.0.1:')).toList();
      // 3 main segments kept, 2 ad segments stripped!
      expect(segmentUrls, hasLength(3));
      // AES-128 key restored for seg_003 after ad block's METHOD=NONE was removed:
      final keyLines =
          rewrittenLines.where((l) => l.startsWith('#EXT-X-KEY:')).toList();
      expect(keyLines.any((l) => l.contains('METHOD=NONE')), isFalse);
      expect(keyLines.length, greaterThanOrEqualTo(2));
    } finally {
      await lease.close();
    }

    // Live stream (no #EXT-X-ENDLIST and no VOD) must NEVER be stripped:
    const livePlaylist = '#EXTM3U\n'
        '#EXT-X-VERSION:3\n'
        '#EXT-X-TARGETDURATION:10\n'
        '#EXTINF:30.0,\n'
        'https://main-cdn.test/live/1.ts\n'
        '#EXT-X-DISCONTINUITY\n'
        '#EXTINF:10.0,\n'
        'https://ad-insert.other.test/ad.ts\n';
    final liveAfter = LocalMediaLease.stripVodPlaylistAds(
      livePlaylist,
      Uri.parse('https://main-cdn.test/live.m3u8'),
    );
    expect(liveAfter, livePlaylist);
  });
}
