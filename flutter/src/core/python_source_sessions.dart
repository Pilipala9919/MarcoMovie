import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'python_http_transport.dart';
import 'script_proxy_protocol.dart';
import 'script_proxy_server.dart';

typedef PythonHttpRequest =
    Future<Map<String, Object?>> Function(Map<String, Object?> envelope);
typedef OpenPythonSource =
    Future<PythonNativeSession> Function(
      Uri proxyUrl,
      PythonHttpRequest request,
    );

/// A native owner, not a timeout wrapper. [close] must finish only after the
/// interpreter has actually stopped and been destroyed on its owning thread.
/// [cancel] is cooperative; acknowledging it never frees an occupied slot.
abstract class PythonNativeSession {
  Future<Object?> invoke(
    String callId,
    String method,
    List<Object?> arguments,
    Duration budget,
  );
  Future<void> cancel(String callId);
  Future<void> close();
}

/// Shared catalogue/detail/player lifecycle for a native Python backend.
/// This is deliberately independent of backend selection: a failed source is
/// never replayed in another interpreter. Production routing must first verify
/// that the installed native backend implements this ownership contract.
class PythonSourceSessions {
  PythonSourceSessions({this.maxSessions = 2, this.maxPendingPerSource = 4}) {
    if (maxSessions < 1 ||
        maxSessions > 2 ||
        maxPendingPerSource < 1 ||
        maxPendingPerSource > 8)
      throw ArgumentError('Python capacity');
  }

  final int maxSessions;
  final int maxPendingPerSource;
  final _sources = <String, _Source>{};
  final _allocated = <_Source>{};
  final _pins = <String, Set<Object>>{};
  final _random = Random.secure();
  final _changed = StreamController<void>.broadcast(sync: true);
  final _proxy = ScriptProxyServer();
  int _generation = 0;
  bool _closed = false;

  int get generation => _generation;
  int get allocatedCount => _allocated.length;
  int get activeCount => _sources.length;

  String _identity() => List.generate(
    16,
    (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();

  void Function() pinForPlayback(String key) {
    if (_closed) throw StateError('Python 运行环境已关闭');
    final pins = _pins.putIfAbsent(key, () => <Object>{});
    final token = Object();
    pins.add(token);
    return () {
      if (!pins.remove(token)) return;
      if (pins.isEmpty && identical(_pins[key], pins)) _pins.remove(key);
      _changed.add(null);
    };
  }

  bool ownsProxyUrl(String key, Uri uri) {
    final source = _sources[key];
    final proxy = source?.proxy;
    if (source == null ||
        source.revoked ||
        proxy == null ||
        !proxy.isActive ||
        uri.scheme != 'http' ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment ||
        uri.origin != proxy.url.origin) {
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

  /// Removal and URL revocation happen before returning. A hung native call
  /// remains allocated; waiting for its disposal must not block a settings page.
  void retainSessions(Set<String> keys) {
    _generation++;
    _pins.removeWhere((key, _) => !keys.contains(key));
    for (final source in _sources.values.toList()) {
      if (!keys.contains(source.key)) source.revoke();
    }
    _changed.add(null);
  }

  void release(String key) => _sources[key]?.revoke();

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    retainSessions({});
    await _proxy.close();
    // Do not close _changed while outstanding native owners can still report
    // their actual exit. There are at most maxSessions such owners.
  }

  Future<String?> callCached({
    required String sessionKey,
    required String method,
    required List<Object?> arguments,
    Duration budget = const Duration(seconds: 12),
    Completer<void>? cancellation,
  }) async {
    final source = _sources[sessionKey];
    if (source == null || source.revoked) return null;
    return _invoke(source, method, arguments, budget, cancellation);
  }

  Future<String> invoke({
    required String sessionKey,
    required OpenPythonSource open,
    required String method,
    required List<Object?> arguments,
    required int expectedGeneration,
    Duration budget = const Duration(seconds: 12),
    Completer<void>? cancellation,
    bool Function(Uri)? allowUrl,
  }) async {
    final operation = _Operation(budget, cancellation);
    try {
      void check() {
        operation.check();
        if (_closed || expectedGeneration != _generation) {
          throw StateError('Python 片源已变更，请重新打开');
        }
      }

      check();
      while (!_sources.containsKey(sessionKey) &&
          _allocated.length >= maxSessions) {
        final idle = _sources.values
            .where(
              (source) =>
                  source.pending == 0 &&
                  !source.revoked &&
                  !_pins.containsKey(source.key),
            )
            .firstOrNull;
        // Subscribe before revocation, so synchronous owner exit cannot be lost.
        final changed = Completer<void>();
        final listener = _changed.stream.listen((_) {
          if (!changed.isCompleted) changed.complete();
        });
        try {
          if (idle != null) idle.revoke();
          await operation.wait(changed.future);
        } finally {
          await listener.cancel();
        }
        check();
      }
      check();
      final source = _sources.putIfAbsent(sessionKey, () {
        final source = _Source(this, sessionKey, open, allowUrl);
        _allocated.add(source);
        return source;
      });
      return await source.invoke(method, arguments, operation);
    } finally {
      operation.dispose();
    }
  }

  Future<String> _invoke(
    _Source source,
    String method,
    List<Object?> arguments,
    Duration budget,
    Completer<void>? cancellation,
  ) async {
    final operation = _Operation(budget, cancellation);
    try {
      return await source.invoke(method, arguments, operation);
    } finally {
      operation.dispose();
    }
  }
}

class _Operation {
  _Operation(this.budget, Completer<void>? cancellation) {
    if (budget.inMilliseconds < 1 || budget.inMilliseconds > 45000) {
      throw ArgumentError('Python operation budget');
    }
    timer = Timer(budget, () => abort(TimeoutException('Python 片源加载超时')));
    if (cancellation?.isCompleted == true) {
      abort(StateError('Python 片源加载已取消'));
    } else {
      subscription = cancellation?.future.asStream().listen(
        (_) => abort(StateError('Python 片源加载已取消')),
      );
    }
  }
  final Duration budget;
  final watch = Stopwatch()..start();
  final stopped = Completer<void>();
  Timer? timer;
  StreamSubscription<void>? subscription;
  Object? reason;
  void Function()? onAbort;
  Duration get remaining => budget - watch.elapsed;
  void abort(Object error) {
    if (reason != null) return;
    reason = error;
    stopped.complete();
    onAbort?.call();
  }

  void check() {
    if (reason == null && remaining <= Duration.zero) {
      abort(TimeoutException('Python 片源加载超时'));
    }
    if (reason != null) throw reason!;
  }

  Future<T> wait<T>(Future<T> future) async {
    // Attach to the underlying future even when the deadline has just elapsed:
    // a late native error still needs an observer after the UI has gone away.
    if (reason == null && remaining <= Duration.zero) {
      abort(TimeoutException('Python 片源加载超时'));
    }
    final result = await Future.any<T>([
      future,
      stopped.future.then<T>((_) => throw reason ?? StateError('操作已结束')),
    ]);
    check();
    return result;
  }

  void dispose() {
    timer?.cancel();
    unawaited(subscription?.cancel());
    onAbort = null;
    // Release listeners from completed races even if nobody cancelled the call.
    if (!stopped.isCompleted) stopped.complete();
  }
}

class _Source {
  _Source(this.pool, this.key, this.open, this.allowUrl);
  final PythonSourceSessions pool;
  final String key;
  final OpenPythonSource open;
  final bool Function(Uri)? allowUrl;
  final operations = <_Operation>{};
  ScriptProxyRegistration? proxy;
  PythonNativeSession? native;
  Future<PythonNativeSession>? opening;
  Future<void> tail = Future.value();
  Future<void>? closing;
  PythonHttpTransport? transport;
  String? activeId;
  bool revoked = false;
  int pending = 0;

  Future<PythonNativeSession> start() => opening ??= () async {
    final registration = await pool._proxy.register((request) async {
      final params = <String, String>{
        for (final item in request.queryParametersAll.entries)
          item.key: item.value.last,
        ...request.headers,
        'method': request.method,
      };
      final origin = params.remove('x-marcomovie-proxy-origin');
      if (origin != null) params['origin'] = origin;
      if (request.path != '/proxy')
        params.putIfAbsent('path', () => request.path);
      final raw = await pool._invoke(
        this,
        'proxy',
        [params],
        const Duration(seconds: 18),
        request.cancellation,
      );
      return ScriptProxyProtocol.decode(raw);
    });
    proxy = registration;
    if (revoked) {
      await registration.unregister();
      throw StateError('Python 片源已移除');
    }
    final url = registration.url.replace(
      queryParameters: {
        'do': 'py',
        'siteKey': registration.url.pathSegments[1],
      },
    );
    native = await open(url, (envelope) async {
      // The native bridge must bind this callback to this source before calling
      // Dart. A callback cannot use another source's current transport.
      final owned = transport;
      if (revoked || owned == null || envelope['callId'] != activeId) {
        throw const PythonTransportException('cancelled');
      }
      return owned.request(envelope);
    });
    return native!;
  }();

  Future<String> invoke(
    String method,
    List<Object?> arguments,
    _Operation operation,
  ) async {
    operation.check();
    if (revoked) throw StateError('Python 片源已移除');
    if (!const {
      'home',
      'homeVod',
      'category',
      'search',
      'detail',
      'play',
      'proxy',
      'liveContent',
    }.contains(method)) {
      throw const FormatException('不支持的 Python 片源操作');
    }
    if (pending >= pool.maxPendingPerSource)
      throw StateError('Python 片源忙，请稍后重试');
    // Copy before queueing: navigation code may reuse its mutable filter map.
    final encoded = jsonEncode(arguments);
    if (utf8.encode(encoded).length > 64 * 1024) {
      throw const FormatException('Python 片源参数超过限制');
    }
    final copied = jsonDecode(encoded) as List<Object?>;
    pending++;
    operations.add(operation);
    final previous = tail;
    final done = Completer<void>();
    tail = done.future;
    Future<void>? nativeDone;
    try {
      await operation.wait(previous);
      if (revoked) throw StateError('Python 片源已移除');
      running = operation;
      operation.onAbort = revoke;
      final owner = await operation.wait(start());
      operation.check();
      if (revoked) throw StateError('Python 片源已移除');
      activeId = pool._identity();
      transport = PythonHttpTransport(
        callId: activeId!,
        budget: operation.remaining,
        allowUrl: allowUrl,
      );
      // Keep native completion separate from the UI wait. Cancellation revokes
      // this source but can neither destroy a busy interpreter nor free its slot.
      final executing = owner.invoke(
        activeId!,
        method,
        copied,
        operation.remaining,
      );
      nativeDone = executing.then<void>(
        (_) {},
        onError: (Object _, StackTrace __) {},
      );
      final value = await operation.wait(executing);
      if (revoked) throw StateError('Python 片源已移除');
      final result = method == 'liveContent' && value is String
          ? value
          : jsonEncode(value);
      if (utf8.encode(result).length > 8 * 1024 * 1024 + 65536) {
        throw const FormatException('Python 片源返回内容超过限制');
      }
      return result;
    } catch (_) {
      // A queued timeout did not execute or touch the active interpreter.
      if (operation.onAbort != null) revoke();
      rethrow;
    } finally {
      operation.onAbort = null;
      operations.remove(operation);
      pending--;
      // A queued cancellation must not close another operation's HTTP client.
      if (operation == running) {
        running = null;
        transport?.close();
        transport = null;
        activeId = null;
      }
      // A cancelled queued item is still a barrier behind its predecessor;
      // otherwise the next item could overtake the source's running call.
      unawaited(
        Future.wait([
          previous,
          if (nativeDone != null) nativeDone,
        ]).then((_) => done.complete()),
      );
      pool._changed.add(null);
    }
  }

  _Operation? running;

  void revoke() {
    if (revoked) return;
    revoked = true;
    if (identical(pool._sources[key], this)) pool._sources.remove(key);
    unawaited(proxy?.unregister());
    transport?.close();
    transport = null;
    final id = activeId;
    if (id != null && native != null) {
      unawaited(native!.cancel(id).catchError((Object _) {}));
    }
    for (final operation in operations.toList()) {
      operation.abort(StateError('Python 片源已移除'));
    }
    closing ??= disposeOwner();
    pool._changed.add(null);
  }

  Future<void> disposeOwner() async {
    try {
      if (opening != null) {
        try {
          await opening;
        } catch (_) {
          /* Failed open must leave no owner. */
        }
      }
      await tail;
      await native?.close();
      pool._allocated.remove(this);
      pool._changed.add(null);
    } catch (_) {
      // Unknown teardown is quarantined and still consumes capacity. Never
      // replace it with unbounded fresh interpreters or silently replay a call.
    }
  }
}
