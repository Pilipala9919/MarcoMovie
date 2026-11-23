import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'python_http_transport.dart';
import 'python_source_channel.dart';
import 'python_source_sessions.dart';

/// Synchronous/diagnostic snapshot of the bundled desktop Python 3.11 runtime.
class PythonRuntimeStatus {
  const PythonRuntimeStatus({
    required this.ready,
    required this.backend,
    required this.version,
    this.executablePath,
    this.runnerPath,
    this.reason,
  });

  final bool ready;
  final String backend;
  final String version;
  final String? executablePath;
  final String? runnerPath;
  final String? reason;
}

/// Persistent desktop CPython 3.11 subprocess pool adapting [PythonSourceChannel].
///
/// Each active source session owns an isolated `python.exe -I desktop_runner.py`
/// worker communicating via UTF-8 line-delimited JSON-RPC over stdio. Up to
/// [maxSessions] workers are kept warm with LRU eviction; any timed-out call
/// immediately kills and respawns the hung subprocess.
class DesktopPythonBridge implements PythonSourceChannel {
  DesktopPythonBridge({
    String? pythonExecutable,
    String? runnerScript,
    this.maxSessions = 4,
    this.defaultTimeout = const Duration(seconds: 12),
  }) : _explicitExecutable = pythonExecutable,
       _explicitRunner = runnerScript {
    if (maxSessions < 1 || maxSessions > 16) {
      throw ArgumentError.value(maxSessions, 'maxSessions');
    }
    if (defaultTimeout <= Duration.zero) {
      throw ArgumentError.value(defaultTimeout, 'defaultTimeout');
    }
  }

  /// Optional test hook to override executable resolution without spawning a child env.
  @visibleForTesting
  static String? executableOverride;

  /// Optional test hook to override runner script resolution.
  @visibleForTesting
  static String? runnerOverride;

  final String? _explicitExecutable;
  final String? _explicitRunner;
  final int maxSessions;
  final Duration defaultTimeout;

  @override
  final MethodChannel channel = const MethodChannel(
    'marco_movie/python_source_desktop',
  );

  final LinkedHashMap<String, _DesktopPythonSession> _sessions =
      LinkedHashMap<String, _DesktopPythonSession>();
  final Random _random = Random.secure();
  bool _closed = false;
  Future<Map<String, Object?>?>? _cachedCapabilities;

  int get activeSessionCount => _sessions.length;

  List<int> get activePids => [
    for (final session in _sessions.values)
      if (session.pid != null) session.pid!,
  ];

  static String? resolvePythonExecutable({String? explicit}) {
    if (explicit != null && explicit.trim().isNotEmpty) {
      final file = File(explicit.trim());
      if (file.existsSync()) return file.path;
    }
    final hook = executableOverride?.trim();
    if (hook != null && hook.isNotEmpty) {
      final file = File(hook);
      return file.existsSync() ? file.path : null;
    }
    final envExe = Platform.environment['MARCOMOVIE_PYTHON_EXE']?.trim();
    if (envExe != null && envExe.isNotEmpty) {
      final file = File(envExe);
      if (file.existsSync()) return file.path;
    }
    final appDir = File(Platform.resolvedExecutable).parent.path;
    if (Platform.isWindows) {
      final bundled = File('$appDir${Platform.pathSeparator}data'
          '${Platform.pathSeparator}python${Platform.pathSeparator}python.exe');
      if (bundled.existsSync()) return bundled.path;
    } else {
      final bundled = File('$appDir${Platform.pathSeparator}data'
          '${Platform.pathSeparator}python${Platform.pathSeparator}bin'
          '${Platform.pathSeparator}python3');
      if (bundled.existsSync()) return bundled.path;
    }
    return null;
  }

  static String? resolveRunnerScript({
    String? explicit,
    String? pythonExecutable,
  }) {
    if (explicit != null && explicit.trim().isNotEmpty) {
      final file = File(explicit.trim());
      if (file.existsSync()) return file.path;
    }
    final hook = runnerOverride?.trim();
    if (hook != null && hook.isNotEmpty) {
      final file = File(hook);
      return file.existsSync() ? file.path : null;
    }
    final envRunner = Platform.environment['MARCOMOVIE_PYTHON_RUNNER']?.trim();
    if (envRunner != null && envRunner.isNotEmpty) {
      final file = File(envRunner);
      if (file.existsSync()) return file.path;
    }
    if (pythonExecutable != null && pythonExecutable.isNotEmpty) {
      final pyDir = File(pythonExecutable).parent.path;
      final packaged = File('$pyDir${Platform.pathSeparator}marco_host'
          '${Platform.pathSeparator}desktop_runner.py');
      if (packaged.existsSync()) return packaged.path;
    }
    final appDir = File(Platform.resolvedExecutable).parent.path;
    final candidates = [
      '$appDir${Platform.pathSeparator}data${Platform.pathSeparator}python'
          '${Platform.pathSeparator}marco_host${Platform.pathSeparator}desktop_runner.py',
      '$appDir${Platform.pathSeparator}data${Platform.pathSeparator}flutter_assets'
          '${Platform.pathSeparator}assets${Platform.pathSeparator}python-host'
          '${Platform.pathSeparator}desktop_runner.py',
      '${Directory.current.path}${Platform.pathSeparator}assets'
          '${Platform.pathSeparator}python-host${Platform.pathSeparator}desktop_runner.py',
      '${Directory.current.path}${Platform.pathSeparator}flutter'
          '${Platform.pathSeparator}assets${Platform.pathSeparator}python-host'
          '${Platform.pathSeparator}desktop_runner.py',
    ];
    for (final path in candidates) {
      final file = File(path);
      if (file.existsSync()) return file.path;
    }
    return null;
  }

  static bool isRuntimeAvailable({
    String? pythonExecutable,
    String? runnerScript,
  }) {
    final exe = resolvePythonExecutable(explicit: pythonExecutable);
    if (exe == null) return false;
    final runner = resolveRunnerScript(
      explicit: runnerScript,
      pythonExecutable: exe,
    );
    return runner != null;
  }

  static PythonRuntimeStatus probeStatus({
    String? pythonExecutable,
    String? runnerScript,
  }) {
    final exe = resolvePythonExecutable(explicit: pythonExecutable);
    if (exe == null) {
      return const PythonRuntimeStatus(
        ready: false,
        backend: 'unavailable',
        version: '',
        reason: '未检测到内置 Python 3.11 运行时 (data/python/python.exe)',
      );
    }
    final runner = resolveRunnerScript(
      explicit: runnerScript,
      pythonExecutable: exe,
    );
    if (runner == null) {
      return PythonRuntimeStatus(
        ready: false,
        backend: 'unavailable',
        version: '',
        executablePath: exe,
        reason: '未检测到桌面 Python 宿主脚本 (desktop_runner.py)',
      );
    }
    final pyDir = File(exe).parent.path;
    final has311Dll = File(
      '$pyDir${Platform.pathSeparator}python311.dll',
    ).existsSync();
    return PythonRuntimeStatus(
      ready: true,
      backend: 'cpython-3.11-desktop',
      version: has311Dll ? '3.11' : '3.x',
      executablePath: exe,
      runnerPath: runner,
    );
  }

  String _nextHandle() {
    String hex(int bytes) => List.generate(
      bytes,
      (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    return '${hex(4)}-${hex(2)}-${hex(2)}-${hex(2)}-${hex(6)}';
  }

  void _touch(String handle) {
    final session = _sessions.remove(handle);
    if (session != null) {
      _sessions[handle] = session;
    }
  }

  void _removeSession(String handle, _DesktopPythonSession session) {
    if (identical(_sessions[handle], session)) {
      _sessions.remove(handle);
    }
  }

  @override
  Future<Map<String, Object?>?> capabilities() => _cachedCapabilities ??= () async {
    final exe = resolvePythonExecutable(explicit: _explicitExecutable);
    final runner = resolveRunnerScript(
      explicit: _explicitRunner,
      pythonExecutable: exe,
    );
    if (exe == null || runner == null) {
      throw PlatformException(
        code: 'runtime_unavailable',
        message: 'Bundled desktop Python runtime is unavailable',
      );
    }
    final probe = await Process.run(
      exe,
      ['-I', '-c', 'import sys; print(sys.version.split()[0])'],
      workingDirectory: File(exe).parent.path,
      environment: _sanitizedEnvironment(exe),
      includeParentEnvironment: false,
    );
    if (probe.exitCode != 0) {
      _cachedCapabilities = null;
      throw PlatformException(
        code: 'runtime_unavailable',
        message: 'Desktop Python probe failed',
      );
    }
    final version = (probe.stdout as String).trim();
    return {
      'version': 1,
      'backend': 'desktop',
      'runtime': '$version desktop',
      'maxSessions': maxSessions,
      'hardCancel': true,
      'sourceThreads': true,
    };
  }();

  static Map<String, String> _sanitizedEnvironment(String pythonExe) {
    final pyDir = File(pythonExe).parent.path;
    final sysRoot = Platform.environment['SystemRoot'];
    final winDir = Platform.environment['WINDIR'];
    final temp = Platform.environment['TEMP'] ?? Platform.environment['TMP'];
    return <String, String>{
      if (sysRoot != null && sysRoot.isNotEmpty) 'SystemRoot': sysRoot,
      if (winDir != null && winDir.isNotEmpty) 'WINDIR': winDir,
      if (temp != null && temp.isNotEmpty) ...{'TEMP': temp, 'TMP': temp},
      'PATH': pyDir,
      'PYTHONUTF8': '1',
      'PYTHONIOENCODING': 'utf-8',
    };
  }

  @override
  Future<PythonNativeSession> open(
    NativePythonPackage package,
    Uri proxy,
    PythonHttpRequest request,
  ) async {
    if (_closed) {
      throw PlatformException(
        code: 'closed',
        message: 'Desktop Python bridge is closed',
      );
    }
    final exe = resolvePythonExecutable(explicit: _explicitExecutable);
    final runner = resolveRunnerScript(
      explicit: _explicitRunner,
      pythonExecutable: exe,
    );
    if (exe == null || runner == null) {
      throw PlatformException(
        code: 'runtime_unavailable',
        message: 'Bundled desktop Python runtime is unavailable',
      );
    }

    while (_sessions.length >= maxSessions) {
      _DesktopPythonSession? lruIdle;
      for (final candidate in _sessions.values) {
        if (!candidate.isBusy && !candidate.isClosing) {
          lruIdle = candidate;
          break;
        }
      }
      if (lruIdle == null) {
        throw PlatformException(
          code: 'runtime_limit',
          message: 'All desktop Python sessions are currently busy',
        );
      }
      _sessions.remove(lruIdle.handle);
      await lruIdle.close();
    }

    final handle = _nextHandle();
    final session = _DesktopPythonSession(
      bridge: this,
      handle: handle,
      pythonExecutable: exe,
      runnerScript: runner,
      package: package,
      proxy: proxy,
      request: request,
    );
    _sessions[handle] = session;
    try {
      await session.start();
      return session;
    } catch (_) {
      _removeSession(handle, session);
      await session.close();
      rethrow;
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final list = _sessions.values.toList();
    _sessions.clear();
    await Future.wait(list.map((s) => s.close()));
  }
}

class _PendingRpc {
  _PendingRpc(this.completer, {this.callId});
  final Completer<Object?> completer;
  final String? callId;
}

class _DesktopPythonSession implements PythonNativeSession {
  _DesktopPythonSession({
    required this.bridge,
    required this.handle,
    required this.pythonExecutable,
    required this.runnerScript,
    required this.package,
    required this.proxy,
    required this.request,
  });

  final DesktopPythonBridge bridge;
  final String handle;
  final String pythonExecutable;
  final String runnerScript;
  final NativePythonPackage package;
  final Uri proxy;
  final PythonHttpRequest request;

  static final _identity = RegExp(r'^[0-9a-f]{32}$');

  Process? _process;
  StreamSubscription<String>? _stdoutSub;
  StreamSubscription<List<int>>? _stderrSub;
  final Map<String, _PendingRpc> _pendingRpc = {};
  final Set<String> _cancelledCalls = {};
  Future<void> _serialTail = Future.value();
  Future<void>? _closingFuture;
  Future<void>? _respawning;
  int _rpcSeq = 0;
  int _activeOps = 0;
  bool _closing = false;
  bool _closed = false;

  bool get isBusy => _activeOps > 0 || _respawning != null;
  bool get isClosing => _closing || _closed;
  int? get pid => _process?.pid;

  String _nextRpcId() => (++_rpcSeq).toString();

  Map<String, Object?> _encodeOpenParams() {
    final raw = package.arguments(proxy);
    final rawFiles = raw['files'] as Map<String, Uint8List>;
    final encodedFiles = <String, String>{
      for (final entry in rawFiles.entries)
        entry.key: base64Encode(entry.value),
    };
    return <String, Object?>{
      'version': raw['version'],
      'entry': raw['entry'],
      'extension': raw['extension'],
      'proxy': raw['proxy'],
      if (raw.containsKey('remote')) 'remote': raw['remote'],
      'files': encodedFiles,
    };
  }

  Future<void> start() async {
    await _spawnAndOpen();
  }

  Future<void> _spawnAndOpen() async {
    if (_closing || _closed) return;
    final process = await Process.start(
      pythonExecutable,
      ['-I', runnerScript],
      workingDirectory: File(pythonExecutable).parent.path,
      environment: DesktopPythonBridge._sanitizedEnvironment(pythonExecutable),
      includeParentEnvironment: false,
    );
    _process = process;
    _stderrSub = process.stderr.listen((_) {});
    _stdoutSub = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) => _onStdoutLine(process, line),
          onError: (_) {},
          onDone: () => _onProcessExited(process),
        );
    unawaited(
      process.exitCode.then((_) => _onProcessExited(process)),
    );

    final openReply = await _sendRpc(
      process: process,
      op: 'open',
      params: _encodeOpenParams(),
      timeout: const Duration(seconds: 10),
    );
    if (openReply is! Map || openReply['opened'] != true) {
      throw const FormatException('Desktop Python session failed to open');
    }
  }

  void _onProcessExited(Process process) {
    if (!identical(_process, process)) return;
    _process = null;
    final pending = _pendingRpc.values.toList();
    _pendingRpc.clear();
    for (final entry in pending) {
      if (!entry.completer.isCompleted) {
        entry.completer.completeError(
          PlatformException(
            code: _closing ? 'cancelled' : 'python_error',
            message: 'Desktop Python worker exited unexpectedly',
          ),
        );
      }
    }
  }

  void _onStdoutLine(Process process, String line) {
    if (!identical(_process, process) || line.trim().isEmpty) return;
    final Object? decoded;
    try {
      decoded = jsonDecode(line);
    } catch (_) {
      return;
    }
    if (decoded is! Map) return;
    final type = decoded['type'];
    if (type == 'resp') {
      final id = decoded['id']?.toString();
      if (id == null) return;
      final pending = _pendingRpc.remove(id);
      if (pending == null || pending.completer.isCompleted) return;
      if (decoded['ok'] == true) {
        pending.completer.complete(decoded['result']);
      } else {
        final code = decoded['code'] is String
            ? decoded['code'] as String
            : 'python_error';
        final message = decoded['error'] is String
            ? decoded['error'] as String
            : 'Python source error';
        pending.completer.completeError(
          PlatformException(code: code, message: message),
        );
      }
    } else if (type == 'http') {
      final httpId = decoded['id']?.toString();
      final params = decoded['params'];
      if (httpId == null || params is! Map) return;
      unawaited(_handleHttpCallback(process, httpId, Map<String, Object?>.from(params)));
    }
  }

  Future<void> _handleHttpCallback(
    Process process,
    String httpId,
    Map<String, Object?> params,
  ) async {
    try {
      final callId = params['callId'];
      if (_closing ||
          _closed ||
          callId is! String ||
          _cancelledCalls.contains(callId)) {
        _writeLine(process, {
          'type': 'http_resp',
          'id': httpId,
          'ok': false,
          'kind': 'cancelled',
        });
        return;
      }
      final envelope = Map<String, Object?>.from(params);
      final bodyB64 = envelope.remove('body_b64');
      envelope['body'] = bodyB64 is String && bodyB64.isNotEmpty
          ? base64Decode(bodyB64)
          : Uint8List(0);
      final result = await request(envelope);
      if (!identical(_process, process) ||
          _closing ||
          _closed ||
          _cancelledCalls.contains(callId)) {
        _writeLine(process, {
          'type': 'http_resp',
          'id': httpId,
          'ok': false,
          'kind': 'cancelled',
        });
        return;
      }
      final wireResult = Map<String, Object?>.from(result);
      final body = wireResult.remove('body');
      wireResult['body_b64'] = body is Uint8List
          ? base64Encode(body)
          : body is List<int>
          ? base64Encode(body)
          : '';
      _writeLine(process, {
        'type': 'http_resp',
        'id': httpId,
        'ok': true,
        'result': wireResult,
      });
    } on PythonTransportException catch (error) {
      _writeLine(process, {
        'type': 'http_resp',
        'id': httpId,
        'ok': false,
        'kind': error.kind,
      });
    } on FormatException {
      _writeLine(process, {
        'type': 'http_resp',
        'id': httpId,
        'ok': false,
        'kind': 'protocol',
      });
    } catch (_) {
      _writeLine(process, {
        'type': 'http_resp',
        'id': httpId,
        'ok': false,
        'kind': 'connection',
      });
    }
  }

  void _writeLine(Process process, Map<String, Object?> payload) {
    if (!identical(_process, process)) return;
    try {
      process.stdin.writeln(jsonEncode(payload));
    } catch (_) {}
  }

  Future<Object?> _sendRpc({
    required Process process,
    required String op,
    required Map<String, Object?> params,
    required Duration timeout,
    String? callId,
    bool killOnTimeout = false,
  }) async {
    final rpcId = _nextRpcId();
    final completer = Completer<Object?>();
    _pendingRpc[rpcId] = _PendingRpc(completer, callId: callId);
    final timer = Timer(timeout, () {
      final entry = _pendingRpc.remove(rpcId);
      if (entry == null || entry.completer.isCompleted) return;
      if (killOnTimeout) {
        _killAndScheduleRespawn(process);
      }
      entry.completer.completeError(
        PlatformException(
          code: 'timeout',
          message: 'Desktop Python call timed out after ${timeout.inMilliseconds}ms',
        ),
      );
    });
    try {
      _writeLine(process, {
        'type': 'req',
        'id': rpcId,
        'op': op,
        'params': params,
      });
      return await completer.future;
    } finally {
      timer.cancel();
      _pendingRpc.remove(rpcId);
    }
  }

  void _killAndScheduleRespawn(Process hungProcess) {
    if (identical(_process, hungProcess)) {
      _process = null;
    }
    unawaited(_stdoutSub?.cancel());
    unawaited(_stderrSub?.cancel());
    _stdoutSub = null;
    _stderrSub = null;
    try {
      hungProcess.kill(ProcessSignal.sigkill);
    } catch (_) {}
    final pending = _pendingRpc.values.toList();
    _pendingRpc.clear();
    for (final entry in pending) {
      if (!entry.completer.isCompleted) {
        entry.completer.completeError(
          PlatformException(
            code: 'timeout',
            message: 'Desktop Python worker restarted after timeout',
          ),
        );
      }
    }
    if (!_closing && !_closed && _respawning == null) {
      _respawning = () async {
        try {
          if (!_closing && !_closed) {
            await _spawnAndOpen();
          }
        } catch (_) {
          // Next invoke will retry spawn if still open.
        } finally {
          _respawning = null;
        }
      }();
    }
  }

  @override
  Future<Object?> invoke(
    String callId,
    String method,
    List<Object?> arguments,
    Duration budget,
  ) {
    if (_closing ||
        _closed ||
        !_identity.hasMatch(callId) ||
        budget.inMilliseconds < 1 ||
        budget.inMilliseconds > 45000) {
      throw StateError('Invalid Python source operation');
    }
    if (_activeOps >= 4) {
      throw PlatformException(
        code: 'runtime_limit',
        message: 'Too many queued calls for Python session',
      );
    }
    bridge._touch(handle);
    _activeOps++;
    final previous = _serialTail;
    final done = Completer<void>();
    _serialTail = done.future;

    return () async {
      try {
        await previous;
        if (_closing || _closed) {
          throw PlatformException(
            code: 'closed',
            message: 'Python session closed',
          );
        }
        if (_cancelledCalls.remove(callId)) {
          throw PlatformException(
            code: 'cancelled',
            message: 'Python call cancelled',
          );
        }
        if (_respawning != null) {
          await _respawning;
        }
        if (_process == null && !_closing && !_closed) {
          await _spawnAndOpen();
        }
        final process = _process;
        if (process == null) {
          throw PlatformException(
            code: 'runtime_unavailable',
            message: 'Desktop Python worker is unavailable',
          );
        }
        final result = await _sendRpc(
          process: process,
          op: 'call',
          callId: callId,
          params: {
            'callId': callId,
            'method': method,
            'args': arguments,
            'budgetMs': budget.inMilliseconds,
          },
          timeout: budget,
          killOnTimeout: true,
        );
        if (_respawning != null) {
          await _respawning;
        }
        return result;
      } on PlatformException catch (error) {
        if (error.code == 'timeout' && _respawning != null && !_closing && !_closed) {
          // Wait briefly for the respawned replacement worker so caller observes a healthy restarted session.
          await _respawning!.timeout(
            const Duration(seconds: 3),
            onTimeout: () {},
          );
        }
        rethrow;
      } finally {
        _activeOps--;
        _cancelledCalls.remove(callId);
        if (!done.isCompleted) done.complete();
      }
    }();
  }

  @override
  Future<void> cancel(String callId) async {
    _cancelledCalls.add(callId);
    final process = _process;
    if (process != null && !_closing && !_closed) {
      _writeLine(process, {
        'type': 'req',
        'id': _nextRpcId(),
        'op': 'cancel',
        'params': {'callId': callId},
      });
    }
  }

  @override
  Future<void> close() => _closingFuture ??= _close();

  Future<void> _close() async {
    if (_closed) return;
    _closing = true;
    bridge._removeSession(handle, this);
    final respawning = _respawning;
    if (respawning != null) {
      await respawning.timeout(
        const Duration(milliseconds: 250),
        onTimeout: () {},
      );
    }
    final process = _process;
    _process = null;
    if (process != null) {
      try {
        await _sendRpc(
          process: process,
          op: 'close',
          params: const {},
          timeout: const Duration(milliseconds: 200),
        ).timeout(
          const Duration(milliseconds: 220),
          onTimeout: () => null,
        );
      } catch (_) {}
      try {
        await process.stdin.close().timeout(
          const Duration(milliseconds: 100),
          onTimeout: () {},
        );
      } catch (_) {}
      try {
        final exited = await process.exitCode.timeout(
          const Duration(milliseconds: 180),
          onTimeout: () => -1,
        );
        if (exited == -1) {
          process.kill(ProcessSignal.sigkill);
        }
      } catch (_) {
        try {
          process.kill(ProcessSignal.sigkill);
        } catch (_) {}
      }
    }
    await _stdoutSub?.cancel();
    await _stderrSub?.cancel();
    _stdoutSub = null;
    _stderrSub = null;
    final pending = _pendingRpc.values.toList();
    _pendingRpc.clear();
    for (final entry in pending) {
      if (!entry.completer.isCompleted) {
        entry.completer.completeError(
          PlatformException(
            code: 'closed',
            message: 'Desktop Python session closed',
          ),
        );
      }
    }
    _closed = true;
  }
}
