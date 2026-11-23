import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'desktop_python_bridge.dart';
import 'python_source_channel.dart';
import 'python_source_sessions.dart';

export 'desktop_python_bridge.dart'
    show DesktopPythonBridge, PythonRuntimeStatus;

/// Product-facing failure text. Never interpolate a script's exception message,
/// native details or stack trace into the catalogue/detail error cards.
class PythonSourceException implements Exception {
  PythonSourceException(String code)
    : code =
          const {
            'timeout',
            'runtime_limit',
            'runtime_unavailable',
            'invalid_handle',
            'closed',
            'cancelled',
            'invalid_request',
          }.contains(code)
          ? code
          : 'python_error';
  final String code;

  @override
  String toString() => switch (code) {
    'timeout' => '片源响应超时，请重试或切换其他片源',
    'runtime_limit' => 'Python 片源正在处理其他请求，请稍后重试',
    'runtime_unavailable' => 'Python 运行库不可用，请重新打开应用或更新安装包',
    'invalid_handle' || 'closed' || 'cancelled' => '当前片源会话已结束，请重新加载',
    'invalid_request' => 'Python 片源接口不兼容，请切换其他片源',
    _ => 'Python 片源执行失败，请重试或切换其他片源',
  };
}

/// Product selection for native Python runtimes (bundled iOS interpreter and
/// Windows/desktop Python 3.11 embeddable bridge). Execution errors are never
/// replayed in another engine.
class PythonSourceHost {
  PythonSourceHost({bool? enabled, PythonSourceChannel? channel})
    : _explicitEnabled = enabled,
      _channel = channel {
    _sessions = _buildSessions(_targetMaxSessions());
  }

  static final instance = PythonSourceHost();
  final bool? _explicitEnabled;
  PythonSourceChannel? _channel;
  late PythonSourceSessions _sessions;
  Future<void>? _ready;
  int? _capabilitiesMaxSessions;
  int get maxSessions => _ensureSessions().maxSessions;

  bool get enabled =>
      _explicitEnabled ??
      (Platform.isIOS ||
          _channel is DesktopPythonBridge ||
          (_channel == null && DesktopPythonBridge.isRuntimeAvailable()));

  int _targetMaxSessions() {
    if (_capabilitiesMaxSessions != null) return _capabilitiesMaxSessions!;
    if (Platform.isIOS) return 2;
    final channel = _channel;
    if (channel is DesktopPythonBridge) return channel.maxSessions;
    if (_explicitEnabled != false &&
        channel == null &&
        DesktopPythonBridge.isRuntimeAvailable()) {
      return 4;
    }
    return 2;
  }

  static PythonSourceSessions _buildSessions(
    int capacity, {
    int initialGeneration = 0,
  }) => PythonSourceSessions(
    maxSessions: capacity,
    maxAllowedSessions: capacity < 2 ? 2 : capacity,
    initialGeneration: initialGeneration,
  );

  PythonSourceSessions _ensureSessions() {
    final target = _targetMaxSessions();
    if (_sessions.maxSessions != target &&
        _sessions.allocatedCount == 0 &&
        _sessions.activeCount == 0) {
      final previous = _sessions;
      _sessions = _buildSessions(
        target,
        initialGeneration: previous.generation,
      );
      unawaited(previous.close());
    }
    return _sessions;
  }

  @visibleForTesting
  int get sessionPoolCapacity => _ensureSessions().maxSessions;

  int get generation => _ensureSessions().generation;

  PythonSourceChannel get _bridge => _channel ??=
      (!Platform.isIOS && DesktopPythonBridge.isRuntimeAvailable())
          ? DesktopPythonBridge()
          : PythonSourceChannel();

  /// Synchronous readiness snapshot for desktop UI status panels.
  static PythonRuntimeStatus desktopRuntimeStatus() =>
      DesktopPythonBridge.probeStatus();

  bool get isDesktopNativeReady =>
      !Platform.isIOS &&
      enabled &&
      (_channel is DesktopPythonBridge ||
          (_channel == null && DesktopPythonBridge.isRuntimeAvailable()));

  Future<PythonRuntimeStatus> runtimeStatus() async {
    if (Platform.isIOS) {
      return const PythonRuntimeStatus(
        ready: true,
        backend: 'cpython-3.14-ios',
        version: '3.14',
      );
    }
    return DesktopPythonBridge.probeStatus();
  }

  Future<T> _explainFailure<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on PlatformException catch (error) {
      throw PythonSourceException(error.code);
    } on MissingPluginException {
      throw PythonSourceException('runtime_unavailable');
    } on TimeoutException {
      throw PythonSourceException('timeout');
    }
  }

  Future<void> _ensureReady() => _ready ??= () async {
    try {
      final bridge = _bridge;
      final reply = await bridge.capabilities();
      if (bridge is DesktopPythonBridge || reply?['backend'] == 'desktop') {
        final runtime = reply?['runtime'];
        final capMax = reply?['maxSessions'];
        if (reply?['version'] != 1 ||
            runtime is! String ||
            !runtime.startsWith('3.') ||
            capMax is! int ||
            capMax < 1 ||
            capMax > 8) {
          throw const FormatException('Python 运行库版本不匹配，请更新安装包');
        }
        _capabilitiesMaxSessions = capMax;
        _sessions.configureMaxSessions(capMax);
        return;
      }
      final capMax = reply?['maxSessions'];
      if (reply?['version'] != 1 ||
          reply?['runtime'] is! String ||
          !(reply!['runtime'] as String).startsWith('3.14.') ||
          capMax is! int ||
          capMax < 1 ||
          capMax > 8 ||
          reply['hardCancel'] != false ||
          reply['sourceThreads'] != false) {
        throw const FormatException('Python 运行库版本不匹配，请更新安装包');
      }
      _capabilitiesMaxSessions = capMax;
      _sessions.configureMaxSessions(capMax);
    } catch (_) {
      _ready = null;
      rethrow;
    }
  }();

  Future<String?> callCached({
    required String sessionKey,
    required String method,
    required List<Object?> arguments,
    Completer<void>? cancellation,
  }) => enabled
      ? _explainFailure(
          () => _ensureSessions().callCached(
            sessionKey: sessionKey,
            method: method,
            arguments: arguments,
            cancellation: cancellation,
          ),
        )
      : Future.value(null);

  Future<String> invoke({
    required String sessionKey,
    required int expectedGeneration,
    required NativePythonPackage package,
    required String method,
    required List<Object?> arguments,
    Completer<void>? cancellation,
  }) {
    if (!enabled) throw StateError('此设备未启用原生 Python 运行库');
    return _explainFailure(() async {
      final sessions = _ensureSessions();
      if (expectedGeneration == sessions.generation &&
          cancellation?.isCompleted != true) {
        await _ensureReady();
      }
      return sessions.invoke(
        sessionKey: sessionKey,
        expectedGeneration: expectedGeneration,
        method: method,
        arguments: arguments,
        cancellation: cancellation,
        open: (proxy, request) async {
          await _ensureReady();
          return _bridge.open(package, proxy, request);
        },
      );
    });
  }

  void retainSessions(Set<String> keys) => _ensureSessions().retainSessions(keys);
  Future<void> onAppResumed() =>
      enabled ? _ensureSessions().onAppResumed() : Future.value();
  void Function() pinForPlayback(String key) =>
      enabled ? _ensureSessions().pinForPlayback(key) : () {};
  bool ownsProxyUrl(String key, Uri uri) =>
      enabled && _ensureSessions().ownsProxyUrl(key, uri);
  Future<void> close() async {
    await _sessions.close();
    final channel = _channel;
    if (channel is DesktopPythonBridge) {
      await channel.close();
    }
  }

  /// Retain archive paths, binary bytes and the unmodified extension string.
  /// Remote PHP/extensionless entries are detected by content before this call.
  static NativePythonPackage packageFromSource({
    required String entry,
    required String source,
    required String extension,
    Map<String, Object?> packageData = const {},
    Map<String, String> headers = const {},
  }) {
    if (packageData.isNotEmpty) {
      final path = packageData['entry'];
      final files = packageData['files'];
      if (path is! String || files is! Map || files.length > 256) {
        throw const FormatException('Python 本地包目录无效');
      }
      final decoded = <String, Uint8List>{};
      var total = 0;
      for (final item in files.entries) {
        if (item.key is! String ||
            item.value is! String ||
            (item.value as String).length > 2796204) {
          throw const FormatException('Python 本地包文件无效');
        }
        final data = base64Decode(item.value as String);
        total += data.length;
        if (total > 6 * 1024 * 1024) {
          throw const FormatException('Python 本地包内容超过 6 MB');
        }
        decoded[item.key as String] = data;
      }
      return NativePythonPackage(
        entry: path,
        files: decoded,
        extension: extension,
      );
    }
    final uri = Uri.parse(entry);
    final remote = {'http', 'https'}.contains(uri.scheme);
    var name = uri.pathSegments.isEmpty ? 'main.py' : uri.pathSegments.last;
    if (!RegExp(r'^[A-Za-z_][A-Za-z0-9_]*\.py$').hasMatch(name))
      name = 'main.py';
    final inherited = Map<String, String>.of(headers);
    if (remote &&
        uri.userInfo.isNotEmpty &&
        !inherited.keys.any((name) => name.toLowerCase() == 'authorization')) {
      inherited['Authorization'] =
          'Basic ${base64Encode(utf8.encode(Uri.decodeComponent(uri.userInfo)))}';
    }
    return NativePythonPackage(
      entry: name,
      files: {name: Uint8List.fromList(utf8.encode(source))},
      extension: extension,
      remote: remote
          ? PythonRemoteSource(
              uri.replace(userInfo: '').removeFragment(),
              headers: inherited,
            )
          : null,
    );
  }
}
