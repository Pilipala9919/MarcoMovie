import 'dart:convert';
import 'package:flutter/services.dart';
import 'python_http_transport.dart';
import 'python_source_sessions.dart';

/// A generic in-memory package; subscription download/archive resolution happens
/// before this boundary. The native loader also validates names and imports.
class NativePythonPackage {
  NativePythonPackage({
    required this.entry,
    required Map<String, Uint8List> files,
    this.extension = '',
  }) : _files = {
         for (final item in files.entries)
           item.key: Uint8List.fromList(item.value),
       } {
    if (_files.isEmpty ||
        _files.length > 256 ||
        !_files.containsKey(entry) ||
        !entry.endsWith('.py') ||
        utf8.encode(extension).length > 64 * 1024) {
      throw const FormatException('Invalid Python package');
    }
    var total = 0;
    for (final item in _files.entries) {
      final name = item.key;
      if (name.isEmpty ||
          name.length > 1024 ||
          name.startsWith('/') ||
          RegExp(r'[:\\\x00-\x1f\x7f]').hasMatch(name) ||
          name
              .split('/')
              .any((part) => part.isEmpty || part == '.' || part == '..') ||
          item.value.length > 2 * 1024 * 1024) {
        throw const FormatException('Invalid Python package file');
      }
      total += item.value.length;
    }
    if (total > 6 * 1024 * 1024)
      throw const FormatException('Python package too large');
  }
  final String entry;
  final String extension;
  final Map<String, Uint8List> _files;
  Map<String, Object?> arguments(Uri proxy) => {
    'version': 1,
    'entry': entry,
    'extension': extension,
    'proxy': '$proxy',
    'files': {
      for (final item in _files.entries)
        item.key: Uint8List.fromList(item.value),
    },
  };
}

/// Owns the channel callback routing for one installed native backend. Each HTTP
/// callback must match both the native owner and its currently pending operation.
/// This adapter does not select/fallback between source engines.
class PythonSourceChannel {
  PythonSourceChannel({MethodChannel? channel})
    : channel = channel ?? const MethodChannel('marco_movie/python_source') {
    this.channel.setMethodCallHandler(_onMethod);
  }
  final MethodChannel channel;
  final _owners = <String, _ChannelPythonSession>{};
  static final _handle = RegExp(
    r'^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$',
  );
  static final _identity = RegExp(r'^[0-9a-f]{32}$');

  Future<PythonNativeSession> open(
    NativePythonPackage package,
    Uri proxy,
    PythonHttpRequest request,
  ) async {
    final reply = await channel.invokeMapMethod<String, Object?>(
      'python.open',
      package.arguments(proxy),
    );
    final handle = reply?['handle'];
    if (reply?.length != 1 ||
        handle is! String ||
        !_handle.hasMatch(handle) ||
        _owners.containsKey(handle)) {
      throw const FormatException('Invalid native Python owner response');
    }
    final owner = _ChannelPythonSession(this, handle, request);
    _owners[handle] = owner;
    return owner;
  }

  Future<Object?> _onMethod(MethodCall call) async {
    if (call.method != 'python.http.request' &&
        call.method != 'python.http.cancel') {
      throw MissingPluginException('Unknown Python callback');
    }
    final raw = call.arguments;
    if (raw is! Map || raw.keys.any((key) => key is! String)) {
      throw PlatformException(code: 'protocol');
    }
    final args = Map<String, Object?>.from(raw);
    final handle = args.remove('handle');
    final identity = args['callId'];
    final owner = handle is String ? _owners[handle] : null;
    if (args['version'] != 1 ||
        args['version'] is! int ||
        identity is! String ||
        !_identity.hasMatch(identity)) {
      throw PlatformException(code: 'protocol');
    }
    if (call.method == 'python.http.cancel') {
      if (args.length != 2) throw PlatformException(code: 'protocol');
      // A native HTTP timeout already settled its waiting operation. Source
      // cancellation is owned by PythonSourceSessions, never by another source.
      return null;
    }
    if (owner == null ||
        owner.closing ||
        !owner.pending.contains(identity) ||
        owner.cancelled.contains(identity)) {
      throw PlatformException(code: 'cancelled');
    }
    try {
      final response = await owner.request(args);
      if (owner.closing ||
          !owner.pending.contains(identity) ||
          owner.cancelled.contains(identity)) {
        throw PlatformException(code: 'cancelled');
      }
      return response;
    } on PythonTransportException catch (error) {
      throw PlatformException(code: error.kind);
    } on FormatException {
      throw PlatformException(code: 'protocol');
    }
  }
}

class _ChannelPythonSession implements PythonNativeSession {
  _ChannelPythonSession(this.bridge, this.handle, this.request);
  final PythonSourceChannel bridge;
  final String handle;
  final PythonHttpRequest request;
  final pending = <String>{};
  final cancelled = <String>{};
  bool closing = false;
  Future<void>? _closing;

  @override
  Future<Object?> invoke(
    String callId,
    String method,
    List<Object?> arguments,
    Duration budget,
  ) async {
    if (closing ||
        pending.length >= 4 ||
        !PythonSourceChannel._identity.hasMatch(callId) ||
        pending.contains(callId) ||
        budget.inMilliseconds < 1 ||
        budget.inMilliseconds > 45000) {
      throw StateError('Invalid Python source operation');
    }
    pending.add(callId);
    try {
      return await bridge.channel.invokeMethod<Object?>('python.call', {
        'version': 1,
        'handle': handle,
        'callId': callId,
        'method': method,
        'args': arguments,
        'budgetMs': budget.inMilliseconds,
      });
    } finally {
      pending.remove(callId);
      cancelled.remove(callId);
    }
  }

  @override
  Future<void> cancel(String callId) async {
    if (!pending.contains(callId)) return;
    cancelled.add(callId);
    await bridge.channel.invokeMethod<Object?>('python.cancel', {
      'version': 1,
      'handle': handle,
      'callId': callId,
    });
  }

  @override
  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    closing = true;
    final reply = await bridge.channel.invokeMapMethod<String, Object?>(
      'python.close',
      {'version': 1, 'handle': handle},
    );
    if (reply?.length != 1 || reply?['closed'] != true) {
      throw const FormatException(
        'Native Python owner destruction was not acknowledged',
      );
    }
    if (identical(bridge._owners[handle], this)) bridge._owners.remove(handle);
  }
}
