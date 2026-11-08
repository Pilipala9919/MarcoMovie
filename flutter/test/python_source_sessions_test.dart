import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/core/python_source_sessions.dart';

class OwnedBackend extends PythonNativeSession {
  OwnedBackend(this.proxy, this.http);
  final Uri proxy;
  final PythonHttpRequest http;
  final calls = <String>[];
  final cancelled = <String>[];
  final ids = <String>[];
  int closed = 0;
  Future<Object?> Function(String, List<Object?>)? handler;
  Future<void> Function()? closeHandler;
  @override
  Future<Object?> invoke(
    String id,
    String method,
    List<Object?> args,
    Duration budget,
  ) async {
    ids.add(id);
    calls.add(method);
    if (handler != null) return handler!(method, args);
    if (method == 'play') return {'url': '$proxy'};
    if (method == 'proxy') {
      final params = args.single as Map;
      return [
        206,
        'application/octet-stream',
        base64Encode([0, 255, 128, 13, 10, 65]),
        {'Content-Range': 'bytes 0-5/6', 'X-Method': params['method']},
        1,
      ];
    }
    if (method == 'liveContent') return '#EXTM3U\n';
    return {'count': calls.length};
  }

  @override
  Future<void> cancel(String id) async {
    cancelled.add(id);
  }

  @override
  Future<void> close() async {
    closed++;
    await closeHandler?.call();
  }
}

Future<void> tick() => Future<void>.delayed(const Duration(milliseconds: 10));

void main() {
  late PythonSourceSessions pool;
  late List<OwnedBackend> owners;
  Future<PythonNativeSession> open(Uri proxy, PythonHttpRequest http) async {
    final owner = OwnedBackend(proxy, http);
    owners.add(owner);
    return owner;
  }

  Future<String> call(
    String key,
    String method, {
    List<Object?> args = const [],
    Completer<void>? cancellation,
    Duration budget = const Duration(seconds: 2),
    OpenPythonSource? factory,
  }) => pool.invoke(
    sessionKey: key,
    expectedGeneration: pool.generation,
    open: factory ?? open,
    method: method,
    arguments: args,
    cancellation: cancellation,
    budget: budget,
  );
  setUp(() {
    pool = PythonSourceSessions();
    owners = [];
  });
  tearDown(() async {
    await pool.close();
    await tick();
  });

  test(
    'same source owns actual GET/HEAD proxy and revocation never rebinds URL',
    () async {
      await call('a', 'home');
      final play = jsonDecode(await call('a', 'play')) as Map;
      final url = Uri.parse(play['url'] as String);
      expect(owners, hasLength(1));
      expect(pool.ownsProxyUrl('a', url), isTrue);
      expect(pool.ownsProxyUrl('b', url), isFalse);
      expect(pool.ownsProxyUrl('a', Uri.parse('file:///tmp/proxy')), isFalse);
      final client = HttpClient();
      try {
        for (final method in ['GET', 'HEAD']) {
          final request = await client.openUrl(
            method,
            url.replace(
              queryParameters: {...url.queryParameters, 'method': 'spoof'},
            ),
          );
          request.headers.set('range', 'bytes=0-5');
          final response = await request.close();
          final bytes = await response.fold<List<int>>(
            [],
            (a, b) => a..addAll(b),
          );
          expect(response.statusCode, 206);
          expect(response.headers.value('x-method'), method);
          expect(response.contentLength, 6);
          expect(bytes, method == 'HEAD' ? [] : [0, 255, 128, 13, 10, 65]);
        }
        expect(await call('a', 'liveContent'), '#EXTM3U\n');
        final before = owners.single;
        pool.release('a');
        expect(pool.ownsProxyUrl('a', url), isFalse);
        await call('a', 'home');
        final response = await (await client.getUrl(url)).close();
        await response.drain<void>();
        expect(response.statusCode, 404);
        expect(owners.last.proxy, isNot(url));
        expect(before.closed, 1);
        expect(owners.last.calls, ['home']);
      } finally {
        client.close(force: true);
      }
    },
  );

  test(
    'cancelled queued call cannot let a later call overtake running work',
    () async {
      await call('a', 'home');
      final owner = owners.single;
      final blocked = Completer<Object?>();
      owner.handler = (method, args) async =>
          method == 'search' ? blocked.future : {'method': method};
      final first = call('a', 'search');
      await tick();
      final cancel = Completer<void>();
      final second = call('a', 'detail', cancellation: cancel);
      final secondError = expectLater(second, throwsStateError);
      final third = call('a', 'category');
      cancel.complete();
      await secondError;
      await tick();
      expect(owner.calls, ['home', 'search']);
      expect(owner.cancelled, isEmpty);
      blocked.complete({'done': true});
      await first;
      expect(jsonDecode(await third)['method'], 'category');
      expect(owner.calls, ['home', 'search', 'category']);
    },
  );

  test(
    'cancel running task revokes now but capacity waits for real native exit',
    () async {
      await call('a', 'home');
      final owner = owners.single;
      final blocked = Completer<Object?>();
      owner.handler = (_, __) => blocked.future;
      final cancel = Completer<void>();
      final running = call('a', 'search', cancellation: cancel);
      final error = expectLater(running, throwsStateError);
      await tick();
      cancel.complete();
      await error;
      expect(pool.activeCount, 0);
      expect(pool.allocatedCount, 1);
      expect(owner.closed, 0);
      expect(owner.cancelled, hasLength(1));
      await call('b', 'home');
      final unpin = pool.pinForPlayback('b');
      await expectLater(
        call('c', 'home', budget: const Duration(milliseconds: 35)),
        throwsA(isA<TimeoutException>()),
      );
      expect(owners, hasLength(2));
      expect(owner.closed, 0);
      blocked.complete({'late': true});
      await tick();
      expect(owner.closed, 1);
      expect(pool.allocatedCount, 1);
      await call('c', 'home');
      unpin();
      expect(owners, hasLength(3));
    },
  );

  test(
    'removal while opening closes late owner without executing source',
    () async {
      final gate = Completer<PythonNativeSession>();
      OwnedBackend? late;
      final result = call(
        'a',
        'home',
        factory: (proxy, request) {
          late = OwnedBackend(proxy, request);
          return gate.future;
        },
      );
      final error = expectLater(result, throwsStateError);
      await tick();
      pool.retainSessions({});
      await error;
      expect(pool.activeCount, 0);
      expect(pool.allocatedCount, 1);
      gate.complete(late!);
      await tick();
      expect(late!.calls, isEmpty);
      expect(late!.closed, 1);
      expect(pool.allocatedCount, 0);
    },
  );

  test('retired generation is rejected before a factory can run', () async {
    final generation = pool.generation;
    pool.retainSessions({});
    await expectLater(
      pool.invoke(
        sessionKey: 'deleted',
        open: open,
        method: 'home',
        arguments: [],
        expectedGeneration: generation,
      ),
      throwsStateError,
    );
    expect(owners, isEmpty);
    expect(pool.allocatedCount, 0);
  });

  test(
    'deadline covers queue and open, queued expiry leaves current source alive',
    () async {
      await call('a', 'home');
      final blocked = Completer<Object?>();
      owners.single.handler = (method, _) async =>
          method == 'search' ? blocked.future : {};
      final running = call('a', 'search');
      await tick();
      await expectLater(
        call('a', 'category', budget: const Duration(milliseconds: 25)),
        throwsA(isA<TimeoutException>()),
      );
      expect(owners.single.calls, ['home', 'search']);
      expect(owners.single.cancelled, isEmpty);
      blocked.complete({});
      await running;
      await call('a', 'home');
      expect(owners, hasLength(1));
    },
  );

  test(
    'bounded queue snapshots filters instead of sharing caller mutations',
    () async {
      await call('a', 'home');
      final blocked = Completer<Object?>();
      owners.single.handler = (method, args) async =>
          method == 'search' ? blocked.future : args[0];
      final running = call('a', 'search');
      await tick();
      final filters = {'year': '2026'};
      final a = call('a', 'category', args: [filters]);
      final b = call('a', 'category', args: [{}]);
      final c = call('a', 'category', args: [{}]);
      await tick();
      filters['year'] = '2000';
      await expectLater(call('a', 'category', args: [{}]), throwsStateError);
      blocked.complete({});
      await running;
      expect(jsonDecode(await a)['year'], '2026');
      await b;
      await c;
    },
  );

  test(
    'old playback unpin cannot remove a new source lease after reimport',
    () async {
      final oldUnpin = pool.pinForPlayback('a');
      pool.retainSessions({});
      await call('a', 'home');
      final newUnpin = pool.pinForPlayback('a');
      await call('b', 'home');
      final otherUnpin = pool.pinForPlayback('b');
      oldUnpin();
      await expectLater(
        call('c', 'home', budget: const Duration(milliseconds: 25)),
        throwsA(isA<TimeoutException>()),
      );
      expect(owners, hasLength(2));
      newUnpin();
      await call('c', 'home');
      expect(owners.first.closed, 1);
      otherUnpin();
    },
  );

  test(
    'failed destruction remains quarantined rather than freeing another slot',
    () async {
      await call('a', 'home');
      owners.single.closeHandler = () async =>
          throw StateError('owner still alive');
      pool.release('a');
      await tick();
      expect(pool.allocatedCount, 1);
      await call('b', 'home');
      final unpin = pool.pinForPlayback('b');
      await expectLater(
        call('c', 'home', budget: const Duration(milliseconds: 25)),
        throwsA(isA<TimeoutException>()),
      );
      expect(owners, hasLength(2));
      unpin();
    },
  );

  test(
    'late HTTP callback cannot borrow the next operation transport',
    () async {
      await call('a', 'home');
      final owner = owners.single;
      final oldId = owner.ids.single;
      final blocked = Completer<Object?>();
      owner.handler = (_, __) => blocked.future;
      final current = call('a', 'search');
      await tick();
      await expectLater(
        owner.http({'callId': oldId}),
        throwsA(isA<Exception>()),
      );
      blocked.complete({});
      await current;
      expect(owner.ids.toSet().length, 2);
    },
  );

  test(
    'running cancellation closes actual HTTP and ignores a late native result',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final received = Completer<void>();
      server.listen((request) {
        if (!received.isCompleted) received.complete();
        // Intentionally never respond. The owning transport must cancel its socket.
      });
      try {
        await call('a', 'home');
        final owner = owners.single;
        owner.handler = (_, __) async {
          await owner.http({
            'version': 1,
            'callId': owner.ids.last,
            'requestId': '1' * 32,
            'url': 'http://127.0.0.1:${server.port}/slow',
            'method': 'GET',
            'headers': <List<String>>[],
            'body': Uint8List(0),
            'connectTimeoutMs': 1000,
            'readTimeoutMs': 1000,
            'deadlineRemainingMs': 1000,
          });
          return {'unexpected': true};
        };
        final cancel = Completer<void>();
        final result = call('a', 'search', cancellation: cancel);
        final error = expectLater(result, throwsStateError);
        await received.future;
        cancel.complete();
        await error;
        await tick();
        expect(owner.closed, 1);
        expect(pool.allocatedCount, 0);
      } finally {
        await server.close(force: true);
      }
    },
  );
}
