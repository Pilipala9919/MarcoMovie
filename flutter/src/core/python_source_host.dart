import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'python_source_channel.dart';
import 'python_source_sessions.dart';

/// Product selection for the bundled iOS interpreter. Execution errors are
/// never replayed in another engine; Android/desktop keep their existing host.
class PythonSourceHost {
  PythonSourceHost({bool? enabled, PythonSourceChannel? channel})
    : enabled = enabled ?? Platform.isIOS,
      _channel = channel;

  static final instance = PythonSourceHost();
  final bool enabled;
  PythonSourceChannel? _channel;
  final _sessions = PythonSourceSessions();
  Future<void>? _ready;
  int get generation => _sessions.generation;

  PythonSourceChannel get _bridge => _channel ??= PythonSourceChannel();

  Future<void> _ensureReady() => _ready ??= () async {
    final reply = await _bridge.channel.invokeMapMethod<String, Object?>(
      'python.capabilities',
    );
    if (reply?['version'] != 1 ||
        reply?['runtime'] is! String ||
        !(reply!['runtime'] as String).startsWith('3.14.') ||
        reply['maxSessions'] != 2 ||
        reply['hardCancel'] != false ||
        reply['sourceThreads'] != false) {
      throw const FormatException('Python 运行库版本不匹配，请更新安装包');
    }
  }();

  Future<String?> callCached({
    required String sessionKey,
    required String method,
    required List<Object?> arguments,
    Completer<void>? cancellation,
  }) => enabled
      ? _sessions.callCached(
          sessionKey: sessionKey,
          method: method,
          arguments: arguments,
          cancellation: cancellation,
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
    return _sessions.invoke(
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
  }

  void retainSessions(Set<String> keys) => _sessions.retainSessions(keys);
  void Function() pinForPlayback(String key) =>
      enabled ? _sessions.pinForPlayback(key) : () {};
  bool ownsProxyUrl(String key, Uri uri) =>
      enabled && _sessions.ownsProxyUrl(key, uri);
  Future<void> close() => _sessions.close();

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
