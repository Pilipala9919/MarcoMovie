// Local loopback + synthetic upstream only; no account or external media calls.
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:marco_movie/core/cloud_media_proxy.dart';

void main() {
  test('a six minute pause preserves the player-owned media lease', () async {
    var now = DateTime.utc(2026, 11, 10);
    var calls = 0;
    final lease = await CloudMediaLease.open(
        target: Uri.parse('https://video.uc.cn/movie.mkv'),
        headers: {'Cookie': '__pus=synthetic'},
        isCancelled: () => false,
        isCurrent: () async => true,
        clock: () => now,
        client: MockClient((request) async {
          calls++;
          expect(request.headers['cookie'], '__pus=synthetic');
          expect(request.headers['range'], 'bytes=1-3');
          return http.Response.bytes([1, 2, 3], 206,
              headers: {
                'content-type': 'video/x-matroska',
                'content-range': 'bytes 1-3/8589934592'
              });
        }));
    final url = lease.url;
    try {
      expect((await http.get(url, headers: {'Range': 'bytes=1-3'})).statusCode,
          206);
      now = now.add(const Duration(minutes: 6));
      await Future<void>.delayed(const Duration(milliseconds: 1300));
      final resumed = await http.get(url, headers: {'Range': 'bytes=1-3'});
      expect(resumed.statusCode, 206);
      expect(resumed.bodyBytes, [1, 2, 3]);
      expect(resumed.headers['content-range'], 'bytes 1-3/8589934592');
      expect(calls, 2);
    } finally {
      await lease.close();
    }
  });

  test('a player-owned lease still expires after twelve hours', () async {
    var now = DateTime.utc(2026, 11, 10);
    var calls = 0;
    final lease = await CloudMediaLease.open(
        target: Uri.parse('https://video.uc.cn/movie.mkv'),
        headers: {'Cookie': '__pus=synthetic'},
        isCancelled: () => false,
        isCurrent: () async => true,
        clock: () => now,
        client: MockClient((request) async {
          calls++;
          return http.Response('movie', 200);
        }));
    final url = lease.url;
    try {
      now = now.add(const Duration(hours: 12, seconds: 1));
      await Future<void>.delayed(const Duration(milliseconds: 1300));
      await expectLater(http.get(url), throwsA(isA<http.ClientException>()));
      expect(calls, 0);
    } finally {
      await lease.close();
    }
  });

  test('proxy never follows cross-origin redirects or exposes credentials',
      () async {
    var calls = 0;
    final lease = await CloudMediaLease.open(
        target: Uri.parse('https://video.uc.cn/movie.mkv'),
        headers: {'Cookie': '__pus=synthetic'},
        isCancelled: () => false,
        isCurrent: () async => true,
        client: MockClient((request) async {
          calls++;
          expect(request.followRedirects, isFalse);
          return http.Response('', 302, headers: {
            'location': 'https://evil.test/steal',
            'set-cookie': '__pus=secret'
          });
        }));
    try {
      final result = await http.get(lease.url);
      expect(result.statusCode, 502);
      expect(result.headers.containsKey('location'), isFalse);
      expect(result.headers.containsKey('set-cookie'), isFalse);
      expect(calls, 1);
    } finally {
      await lease.close();
    }
  });

  test('cancel during upstream response prevents delivering the old movie',
      () async {
    var cancelled = false;
    final lease = await CloudMediaLease.open(
        target: Uri.parse('https://video.uc.cn/movie.mkv'),
        headers: {'Cookie': '__pus=synthetic'},
        isCancelled: () => cancelled,
        isCurrent: () async => true,
        client: MockClient((request) async {
          cancelled = true;
          return http.Response('movie', 200,
              headers: {'content-type': 'video/mp4'});
        }));
    try {
      final result = await http.get(lease.url);
      expect(result.statusCode, 410);
      expect(result.body, isNot(contains('movie')));
    } finally {
      await lease.close();
    }
  });

  test('host boundary and capability path cannot be changed by the player',
      () async {
    expect(
        CloudMediaLease.isTrustedUcMedia(
            Uri.parse('https://uc.cn.evil.test/movie')),
        isFalse);
    expect(
        CloudMediaLease.isTrustedUcMedia(
            Uri.parse('https://video.uc.cn:444/movie')),
        isFalse);
    expect(
        CloudMediaLease.isTrustedUcMedia(Uri.parse('http://video.uc.cn/movie')),
        isFalse);
    var calls = 0;
    final lease = await CloudMediaLease.open(
        target: Uri.parse('https://video.uc.cn/movie.mkv'),
        headers: {'Cookie': '__pus=synthetic'},
        isCancelled: () => false,
        isCurrent: () async => true,
        client: MockClient((request) async {
          calls++;
          return http.Response('movie', 200);
        }));
    try {
      final result = await http.get(
          lease.url.replace(queryParameters: {'url': 'https://evil.test'}));
      expect(result.statusCode, 404);
      expect(calls, 0);
    } finally {
      await lease.close();
    }
  });

  test('identity encoding is required for correct media byte ranges', () async {
    final lease = await CloudMediaLease.open(
        target: Uri.parse('https://video.uc.cn/movie.mkv'),
        headers: {'Cookie': '__pus=synthetic'},
        isCancelled: () => false,
        isCurrent: () async => true,
        client: MockClient((request) async {
          expect(request.headers['accept-encoding'], 'identity');
          return http.Response('compressed', 206, headers: {
            'content-type': 'video/mp4',
            'content-encoding': 'gzip'
          });
        }));
    try {
      final result = await http.get(lease.url, headers: {'Range': 'bytes=0-9'});
      expect(result.statusCode, 502);
      expect(result.body, isNot(contains('compressed')));
    } finally {
      await lease.close();
    }
  });

  test('account switch after resolution automatically releases the idle lease',
      () async {
    var current = true;
    var calls = 0;
    final lease = await CloudMediaLease.open(
        target: Uri.parse('https://video.uc.cn/movie.mkv'),
        headers: {'Cookie': '__pus=synthetic'},
        isCancelled: () => false,
        isCurrent: () async => current,
        client: MockClient((request) async {
          calls++;
          return http.Response('movie', 200,
              headers: {'content-type': 'video/mp4'});
        }));
    final url = lease.url;
    try {
      current = false;
      await Future<void>.delayed(const Duration(milliseconds: 1300));
      await expectLater(http.get(url), throwsA(isA<http.ClientException>()));
      expect(calls, 0);
    } finally {
      await lease.close();
    }
  });
}
