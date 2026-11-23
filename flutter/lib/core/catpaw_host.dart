import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'catpaw_embedded_engine.dart';
import 'ohos_runtime.dart';
import 'quark_account.dart';
import 'storage_service.dart';

class GuardBootstrapException extends FormatException {
  final String code;
  const GuardBootstrapException(this.code, String message) : super(message);
}

class DrpySourceException extends FormatException {
  final String code;
  const DrpySourceException(this.code, String message) : super(message);
}

class _RecoverableLoopbackException implements Exception {
  final Object cause;
  final StackTrace stackTrace;
  const _RecoverableLoopbackException(this.cause, this.stackTrace);
}

/// Stable subscriptions reference verified local bytes, never an ephemeral port.
class CatPawHost {
  static CatPawHost instance = CatPawHost();
  static final Map<String, String> _permissionFlagCache = <String, String>{};
  final Future<Directory> Function()? directory;
  final String? executable;

  static Future<String> _resolvePermissionFlag(String nodePath) async {
    final cached = _permissionFlagCache[nodePath];
    if (cached != null) return cached;
    var flag = '--experimental-permission';
    try {
      final result = await Process.run(
        nodePath,
        const ['-v'],
      ).timeout(const Duration(seconds: 3));
      if (result.exitCode == 0) {
        final match = RegExp(r'v?(\d+)\.').firstMatch('${result.stdout}');
        final major = match != null ? int.tryParse(match.group(1)!) : null;
        if (major != null && major >= 24) {
          flag = '--permission';
        }
      }
    } catch (_) {}
    _permissionFlagCache[nodePath] = flag;
    return flag;
  }
  final String? bootstrap;
  final bool? useEmbeddedRuntime;
  CatPawHost({
    this.directory,
    this.executable,
    this.bootstrap,
    this.useEmbeddedRuntime,
  });
  Process? _process;
  EmbeddedCatPawEngine? _embeddedEngine;
  bool get _useEmbeddedEngine =>
      useEmbeddedRuntime ??
      (OhosRuntime.isOhos && executable == null && bootstrap == null);
  Future<Uri>? _starting;
  Future<Uri>? _recovering;
  Uri? _base;
  Future<void>? _closing;
  bool _needsReset = false;
  Directory? _root;
  String? _lastSyncedPanJson;
  final _verifiedDrpySizes = <String, int>{};
  final _activeDrpy = <String, int>{};
  final _releasingDrpy = <String, Future<void>>{};
  Future<void> _bootstrapQueue = Future<void>.value();
  static int _writeSeq = 0;
  int _rebindSeq = 0;
  int _generation = 0;
  static const drpyRuntime = 'drpy2-ca23ffdb-1';
  static const _maxBundleBytes = 16 * 1024 * 1024;
  static bool matches(String value) => value.startsWith('catpaw://');
  static bool isBundle(String code) =>
      code.contains('catServerFactory') && code.contains('catDartServerPort');

  static ({Uri base, int seq})? _parseReadyJson(String content) {
    final state = jsonDecode(content);
    if (state is! Map) return null;
    final port = state['port'];
    final secret = state['secret'];
    final rawSeq = state['seq'];
    final seq = rawSeq is int ? rawSeq : 0;
    if (port is int &&
        port > 0 &&
        port < 65536 &&
        secret is String &&
        RegExp(r'^[a-f0-9]{64}$').hasMatch(secret)) {
      return (base: Uri.parse('http://127.0.0.1:$port/$secret'), seq: seq);
    }
    return null;
  }

  Future<Directory> _storage() async {
    if (_root != null) return _root!;
    Directory folder;
    if (directory != null) {
      folder = await directory!();
    } else if (OhosRuntime.isOhos) {
      await OhosRuntime.ensureInitialized();
      final filesDir = OhosRuntime.filesDir;
      if (filesDir != null && filesDir.isNotEmpty) {
        folder = Directory('$filesDir/catpaw');
      } else {
        folder = Directory(
          '${(await getApplicationSupportDirectory()).path}/catpaw',
        );
      }
    } else {
      folder = Directory(
        '${(await getApplicationSupportDirectory()).path}/catpaw',
      );
    }
    await folder.create(recursive: true);
    // Node's permission checks use real paths (macOS /var is a symlink).
    return _root = Directory(await folder.resolveSymbolicLinks());
  }

  Future<Uri> _ensure() async {
    final closing = _closing;
    if (closing != null) await closing;
    final recovering = _recovering;
    if (recovering != null) return recovering;
    if (_needsReset) {
      final base =
          _base ??
          await (_starting ??= _start().whenComplete(() => _starting = null));
      try {
        await _resetEmbedded(base);
      } on Object {
        final recovered = await _recoverLoopback(base);
        if (_needsReset) await _resetEmbedded(recovered);
      }
    }
    if (_base != null) return _base!;
    return _starting ??= _start().whenComplete(() => _starting = null);
  }

  Future<bool> _probeHealth(Uri base) async {
    final client = HttpClient()
      ..findProxy = ((_) => 'DIRECT')
      ..connectionTimeout = const Duration(milliseconds: 900);
    final timer = Timer(
      const Duration(milliseconds: 1400),
      () => client.close(force: true),
    );
    try {
      final req = await client.getUrl(
        base.replace(path: '${base.path}/health'),
      );
      req.followRedirects = false;
      final resp = await req.close();
      await resp.drain<void>();
      return resp.statusCode == 200;
    } catch (_) {
      return false;
    } finally {
      timer.cancel();
      client.close(force: true);
    }
  }

  Future<Uri> _recoverLoopback(Uri? failedBase) {
    final existing = _recovering;
    if (existing != null) return existing;
    late final Future<Uri> task;
    task = _doRecoverLoopback(failedBase).whenComplete(() {
      if (identical(_recovering, task)) _recovering = null;
    });
    return _recovering = task;
  }

  Future<Uri> _doRecoverLoopback(Uri? failedBase) async {
    final closing = _closing;
    if (closing != null) await closing;
    final epoch = _generation;
    if (_base != null && _base != failedBase && await _probeHealth(_base!)) {
      return _base!;
    }
    if (failedBase != null && await _probeHealth(failedBase)) {
      if (epoch == _generation) _base = failedBase;
      return failedBase;
    }
    if (_useEmbeddedEngine) {
      final currentEngine = _embeddedEngine;
      if (currentEngine != null &&
          !currentEngine.isClosed &&
          await _probeHealth(currentEngine.base)) {
        if (epoch == _generation) {
          _base = currentEngine.base;
          _needsReset = false;
        }
        return currentEngine.base;
      }
      _embeddedEngine = null;
      _base = null;
      if (currentEngine != null) {
        await currentEngine.close();
      }
      if (epoch != _generation) throw StateError('CatPaw 本机服务已关闭');
      return _starting ??= _start().whenComplete(() => _starting = null);
    }
    final root = await _storage();
    final ready = File('${root.path}/ready.json');
    if (await ready.exists()) {
      try {
        final parsed = _parseReadyJson(await ready.readAsString());
        if (parsed != null) {
          if (parsed.seq > _rebindSeq) _rebindSeq = parsed.seq;
          if (parsed.base != failedBase && await _probeHealth(parsed.base)) {
            if (epoch == _generation) {
              _base = parsed.base;
              _needsReset = false;
            }
            return parsed.base;
          }
        }
      } catch (_) {}
    }
    if (!Platform.isIOS && _process == null) {
      _base = null;
      return _starting ??= _start().whenComplete(() => _starting = null);
    }
    if (Platform.isIOS) {
      try {
        final status = await const MethodChannel(
          'marco_movie/catpaw',
        ).invokeMethod<Object?>('status');
        if (status is Map) {
          if (status['exited'] == true) {
            _base = null;
            throw StateError('CatPaw 本机服务已退出，请彻底关闭并重新打开应用');
          }
          if (status['started'] == false) {
            _base = null;
            return await (_starting ??=
                _start().whenComplete(() => _starting = null));
          }
        }
      } on MissingPluginException {
        // Ignore in non-plugin test harnesses.
      } on PlatformException {
        // Proceed with file-based rebind signal.
      }
    }
    final targetSeq = ++_rebindSeq;
    final rebindFile = File('${root.path}/rebind.json');
    await _writeAtomic(
      rebindFile,
      utf8.encode(
        jsonEncode({
          'version': 1,
          'seq': targetSeq,
          if (failedBase != null) 'failedPort': failedBase.port,
        }),
      ),
    );
    final deadline = DateTime.now().add(const Duration(seconds: 6));
    while (DateTime.now().isBefore(deadline) && epoch == _generation) {
      if (!Platform.isIOS && _process == null) break;
      if (await ready.exists()) {
        try {
          final parsed = _parseReadyJson(await ready.readAsString());
          if (parsed != null &&
              (parsed.seq >= targetSeq ||
                  (failedBase != null && parsed.base != failedBase)) &&
              await _probeHealth(parsed.base)) {
            if (parsed.seq > _rebindSeq) _rebindSeq = parsed.seq;
            if (epoch != _generation) break;
            _base = parsed.base;
            _needsReset = false;
            return parsed.base;
          }
        } catch (_) {}
      }
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    if (!Platform.isIOS && epoch == _generation) {
      final stale = _process;
      _process = null;
      _base = null;
      stale?.kill();
      return _starting ??= _start().whenComplete(() => _starting = null);
    }
    _base = null;
    throw StateError('CatPaw 本机服务连接已中断，请重试或重新打开应用');
  }

  /// Proactively checks and recovers the local loopback listener after the app
  /// resumes from background suspension (e.g. iOS XNU socket defuncting).
  Future<void> onAppResumed() async {
    if (_closing != null) return;
    final current = _base;
    if (current == null) return;
    if (await _probeHealth(current)) return;
    try {
      await _recoverLoopback(current);
    } catch (_) {}
  }

  Future<Uri> _start() async {
    final epoch = _generation;
    final root = await _storage();
    await root.create(recursive: true);
    if (_useEmbeddedEngine) {
      await _stageDrpyAssets(root);
      await _syncNetdiskConfig(root);
      final engine = await EmbeddedCatPawEngine.start(root: root);
      if (epoch != _generation) {
        await engine.close();
        throw StateError('CatPaw 本机服务已关闭');
      }
      _embeddedEngine = engine;
      _base = engine.base;
      _needsReset = false;
      return engine.base;
    }
    final script = File('${root.path}/host.cjs');
    if (bootstrap != null) {
      await File(bootstrap!).copy(script.path);
      final fetch = File('${File(bootstrap!).parent.path}/fetch.cjs');
      if (await fetch.exists()) await fetch.copy('${root.path}/fetch.cjs');
    } else {
      await script.writeAsString(
        await rootBundle.loadString('assets/catpaw/host.cjs'),
        flush: true,
      );
      await File('${root.path}/fetch.cjs').writeAsString(
        await rootBundle.loadString('assets/catpaw/fetch.cjs'),
        flush: true,
      );
    }
    await _stageDrpyAssets(root);
    await _syncNetdiskConfig(root);
    final ready = File('${root.path}/ready.json');
    if (Platform.isIOS) {
      await const MethodChannel('marco_movie/catpaw').invokeMethod('start', {
        'root': root.path,
        'script': script.path,
        'ready': ready.path,
      });
    } else {
      if (await ready.exists()) await ready.delete();
      final rebind = File('${root.path}/rebind.json');
      if (await rebind.exists()) await rebind.delete();
      final app = File(Platform.resolvedExecutable).parent;
      final node =
          executable ??
          (Platform.isWindows
              ? '${app.path}/data/node/node.exe'
              : '${app.parent.path}/Frameworks/node/bin/node');
      if (!await File(node).exists())
        throw StateError('安装包缺少 CatPaw 本机运行组件，请安装完整版本');
      // Do not inherit developer credentials or NODE_OPTIONS into imported user code.
      final environment = <String, String>{
        if (Platform.environment['SystemRoot'] case final String value)
          'SystemRoot': value,
        'HOME': root.path,
        'USERPROFILE': root.path,
        'TMPDIR': root.path,
        'TEMP': root.path,
        'TMP': root.path,
      };
      final permissionFlag = await _resolvePermissionFlag(node);
      final process = await Process.start(
        node,
        [
          if (Platform.isMacOS) '--jitless',
          permissionFlag,
          '--allow-worker',
          '--allow-fs-read=${root.path}',
          '--allow-fs-write=${root.path}',
          script.path,
          root.path,
          ready.path,
        ],
        workingDirectory: root.path,
        environment: environment,
        includeParentEnvironment: false,
      );
      _process = process;
      process.stdout.drain<void>();
      process.stderr.drain<void>();
      process.exitCode.then((_) {
        if (_process == process) {
          _process = null;
          _base = null;
        }
      });
    }
    final deadline = DateTime.now().add(const Duration(seconds: 12));
    while (DateTime.now().isBefore(deadline) && epoch == _generation) {
      if (await ready.exists()) {
        try {
          final parsed = _parseReadyJson(await ready.readAsString());
          if (parsed != null) {
            if (epoch != _generation) break;
            if (parsed.seq > _rebindSeq) _rebindSeq = parsed.seq;
            _base = parsed.base;
            return parsed.base;
          }
        } catch (_) {}
      }
      await Future<void>.delayed(const Duration(milliseconds: 40));
    }
    await close();
    throw StateError('CatPaw 本机服务启动失败');
  }

  /// Stage only pinned flat runtime files, using the same path in packaged and
  /// explicitly supplied bootstrap modes. Never accept source-provided assets.
  Future<void> _stageDrpyAssets(Directory root) async {
    Future<List<int>> asset(String name) async {
      if (bootstrap != null) {
        return File('${File(bootstrap!).parent.path}/$name').readAsBytes();
      }
      final data = await rootBundle.load('assets/catpaw/$name');
      return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    }

    final manifestBytes = await asset('drpy-assets.json');
    final manifest = jsonDecode(utf8.decode(manifestBytes));
    if (manifest is! Map ||
        manifest['version'] != 1 ||
        manifest['runtime'] != drpyRuntime ||
        manifest['files'] is! List) {
      throw const FormatException('DRPY 本机运行组件清单无效');
    }
    final entries = manifest['files'] as List;
    if (entries.isEmpty || entries.length > 32) {
      throw const FormatException('DRPY 本机运行组件数量无效');
    }
    if (bootstrap == null) {
      final stagedManifest = File('${root.path}/drpy-assets.json');
      if (await stagedManifest.exists() &&
          await stagedManifest.length() == manifestBytes.length &&
          listEquals(await stagedManifest.readAsBytes(), manifestBytes)) {
        var allPresent = true;
        for (final entry in entries) {
          if (entry is! Map ||
              entry['name'] is! String ||
              entry['bytes'] is! int) {
            allPresent = false;
            break;
          }
          final staged = File('${root.path}/${entry['name']}');
          if (!await staged.exists() ||
              await staged.length() != entry['bytes']) {
            allPresent = false;
            break;
          }
        }
        if (allPresent) return;
      }
    }
    final seen = <String>{};
    final verified = <String, List<int>>{};
    var total = 0;
    for (final entry in entries) {
      if (entry is! Map ||
          entry['name'] is! String ||
          entry['sha256'] is! String ||
          entry['bytes'] is! int) {
        throw const FormatException('DRPY 本机运行组件条目无效');
      }
      final name = entry['name'] as String;
      final size = entry['bytes'] as int;
      if (!RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9_.-]*$').hasMatch(name) ||
          name == 'host.cjs' ||
          name == 'fetch.cjs' ||
          name == 'ready.json' ||
          name == 'rebind.json' ||
          name == 'drpy-assets.json' ||
          !seen.add(name) ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(entry['sha256']) ||
          size < 0 ||
          size > _maxBundleBytes ||
          (total += size) > _maxBundleBytes) {
        throw const FormatException('DRPY 本机运行组件路径或大小无效');
      }
      final bytes = await asset(name);
      if (bytes.length != size ||
          sha256.convert(bytes).toString() != entry['sha256']) {
        throw const FormatException('DRPY 本机运行组件校验失败');
      }
      verified[name] = bytes;
    }
    if (!seen.containsAll(const [
      'drpy-worker.cjs',
      'drpy-http.cjs',
      'drpy-schema.cjs',
      'drpy-core.js',
      'drpy-dependencies.js',
    ])) {
      throw const FormatException('DRPY 本机运行组件不完整');
    }
    for (final entry in verified.entries) {
      await _writeAtomic(File('${root.path}/${entry.key}'), entry.value);
    }
    await _writeAtomic(File('${root.path}/drpy-assets.json'), manifestBytes);
  }

  Future<void> _syncNetdiskConfig(Directory root) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final storage = StorageService(prefs);
      final quarkCookie = QuarkAccountSession.tryParseCredential(
          storage.getNetdiskCred('quark'))?.cookie ?? '';
      final ucCookie = storage.isNetdiskLoggedIn('uc')
          ? storage.getNetdiskCred('uc') : '';
      final baiduCookie = storage.isNetdiskLoggedIn('baidu')
          ? storage.getNetdiskCred('baidu') : '';
      final cfgFile = File('${root.path}/wexfnwconfig.json');
      if (quarkCookie.isEmpty && ucCookie.isEmpty && baiduCookie.isEmpty && !await cfgFile.exists()) {
        return;
      }
      final payload = jsonEncode({
        'pan': {
          'quark': {'cookie': quarkCookie},
          'uc': {'cookie': ucCookie},
          'baidu': {'cookie': baiduCookie},
        },
      });
      if (_lastSyncedPanJson == payload && await cfgFile.exists()) return;
      await _writeAtomic(cfgFile, utf8.encode('$payload\n'));
      _lastSyncedPanJson = payload;
      await for (final entity in root.list(followLinks: false)) {
        if (entity is Directory) {
          final stateDir = Directory('${entity.path}/state');
          if (await stateDir.exists()) {
            await _writeAtomic(
                File('${stateDir.path}/wexfnwconfig.json'), utf8.encode('$payload\n'));
          }
        }
      }
    } catch (_) {}
  }

  /// Immediately updates or clears `wexfnwconfig.json` when the user logs into
  /// or logs out of a cloud drive while the local CatPaw runtime directory exists.
  Future<void> syncNetdiskConfig() async {
    final root = _root;
    if (root == null) return;
    await _syncNetdiskConfig(root);
  }

  static Future<void> _writeAtomic(File file, List<int> bytes) async {
    final staging = File(
      '${file.path}.tmp-$pid-${DateTime.now().microsecondsSinceEpoch}-${++_writeSeq}',
    );
    try {
      await staging.writeAsBytes(bytes, flush: true);
      await staging.rename(file.path);
    } finally {
      if (await staging.exists()) await staging.delete();
    }
  }

  static Map<String, dynamic> _drpyManifest(List<int> bytes) {
    if (bytes.isEmpty || bytes.length > _maxBundleBytes) {
      throw const FormatException('DRPY 规则包超过大小限制');
    }
    final value = jsonDecode(utf8.decode(bytes));
    const fields = [
      'version',
      'kind',
      'runtime',
      'sourceId',
      'origin',
      'rule',
      'headers',
      'requestTimeoutMs',
      'modules',
    ];
    if (value is! Map<String, dynamic> ||
        value['version'] != 1 ||
        value.keys.any((key) => !fields.contains(key)) ||
        value['kind'] != 'drpy' ||
        value['runtime'] != drpyRuntime ||
        value['sourceId'] is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(value['sourceId']) ||
        value['origin'] is! String ||
        value['rule'] is! String ||
        (value['rule'] as String).trim().isEmpty ||
        value['headers'] is! Map ||
        (value['requestTimeoutMs'] ?? 10000) is! int ||
        (value['requestTimeoutMs'] ?? 10000) < 100 ||
        (value['requestTimeoutMs'] ?? 10000) > 15000) {
      throw const FormatException('DRPY 规则包格式无效');
    }
    final origin = Uri.tryParse(value['origin']);
    if (origin == null ||
        !const ['http', 'https', 'pkg'].contains(origin.scheme) ||
        origin.host.isEmpty ||
        origin.userInfo.isNotEmpty ||
        origin.hasFragment ||
        (value['origin'] as String).length > 8192 ||
        utf8.encode(value['rule']).length > 6 * 1024 * 1024) {
      throw const FormatException('DRPY 规则来源无效');
    }
    final headers = value['headers'] as Map;
    final modules = value['modules'] ?? <String, String>{};
    if (modules is! Map || modules.length > 32) {
      throw const FormatException('DRPY 本地模块格式或数量无效');
    }
    var moduleBytes = 0;
    for (final module in modules.entries) {
      final uri = module.key is String ? Uri.tryParse(module.key) : null;
      if (origin.scheme != 'pkg' ||
          uri == null ||
          uri.scheme != 'pkg' ||
          uri.authority != origin.authority ||
          uri.userInfo.isNotEmpty ||
          uri.hasQuery ||
          uri.hasFragment ||
          uri.normalizePath().toString() != module.key ||
          (module.key as String).length > 8192 ||
          module.value is! String ||
          (moduleBytes += utf8.encode(module.value).length) > 6 * 1024 * 1024) {
        throw const FormatException('DRPY 本地模块路径或大小无效');
      }
    }
    if (headers.length > 64) throw const FormatException('DRPY 请求头数量过多');
    for (final header in headers.entries) {
      if (header.key is! String ||
          header.value is! String ||
          !RegExp(r"^[!#$%&'*+.^_`|~0-9A-Za-z-]+$").hasMatch(header.key) ||
          (header.value as String).length > 8192 ||
          const [
            'host',
            'content-length',
            'connection',
            'transfer-encoding',
          ].contains((header.key as String).toLowerCase()) ||
          RegExp(r'[\r\n\x00]').hasMatch(header.value)) {
        throw const FormatException('DRPY 请求头格式无效');
      }
    }
    return value;
  }

  /// The address commits to the exact UTF-8 manifest bytes, including whitespace.
  Future<String> installDrpy(Object manifest) async {
    final List<int> bytes;
    if (manifest is List<int>) {
      bytes = List<int>.of(manifest);
    } else if (manifest is Map<String, dynamic>) {
      bytes = utf8.encode(jsonEncode(manifest));
    } else {
      throw const FormatException('DRPY 规则包需要 JSON 对象或 UTF-8 字节');
    }
    _drpyManifest(bytes);
    final hash = sha256.convert(bytes).toString();
    final root = await _storage();
    final folder = Directory('${root.path}/$hash');
    await folder.create(recursive: true);
    final file = File('${folder.path}/drpy.json');
    if (await file.exists()) {
      if (await file.length() > _maxBundleBytes ||
          sha256.convert(await file.readAsBytes()).toString() != hash) {
        throw const FormatException('DRPY 本机规则包已改变，请重新导入');
      }
    } else {
      await _writeAtomic(file, bytes);
    }
    return 'catpaw://$hash/api/drpy';
  }

  /// Extract data from one explicitly supported plugin artifact. Download and
  /// declared MD5 validation belong to the caller; this boundary never receives
  /// the remote address, request headers, or credentials used to acquire it.
  Future<Map<String, dynamic>> bootstrapGuard(
    List<int> bytes, {
    String adapter = 'dm84-v1',
    String? extension,
    Completer<void>? cancellation,
  }) async {
    _checkCancellation(cancellation);
    const baseAdapters = [
      'dm84-v1',
      'auete-v1',
      'bttwoo-v1',
      'appgz-v1',
      't4-v1',
      'apptt-v1',
      'fy-v1',
    ];
    const ftyAdapters = [
      'jpys-v1',
      'jpj-v1',
      'nmyswv-v1',
      'hmys-v1',
      'app99-v1',
      'appsx-v1',
      'newcz-v1',
      'libvio-v1',
      'ygp-v1',
      'kanqiu-v1',
      'doubao-v1',
      'livegz-v1',
      'alllive-v1',
      'tingshu275-v1',
      'yueting-v1',
      'seedhub-v1',
      'szps-v1',
      'ypanso-v1',
      'bpanso-v1',
      'kkss-v1',
      'uuss-v1',
      'jumitv-v1',
    ];
    const wexAdapters = [
      'wexappv7-v1',
      'wexguazi-v1',
      'wexduboku-v1',
      'wexwencai-v1',
      'wexfengye-v1',
      'wexjianpian-v1',
      'wexjuxiafan-v1',
      'wexrebo-v1',
      'wexbobo-v1',
      'wexikanbot-v1',
      'wexyiys-v1',
      'wexhanxiaoquan-v1',
      'wexduoduo-v1',
      'wexhuban-v1',
      'wexkuaiying-v1',
      'wexlabi-v1',
      'wexmuou-v1',
      'wexshandian-v1',
      'wexxiaopan-v1',
      'wexzhizhen-v1',
      'wexwogg-v1',
      'wexhuajuan-v1',
      'wexjutou-v1',
      'wexzhinan-v1',
      'wexwoniu-v1',
      'wexpianku-v1',
      'wexqiwei-v1',
      'wexyidong-v1',
      'wexaipanso-v1',
      'wexhaiyin-v1',
      'wexquanpan-v1',
      'wexkaka-v1',
      'wexmodu-v1',
      'wexhaokan-v1',
      'wexqimiao-v1',
      'wexkuwoa-v1',
      'wexqingting-v1',
      'wexsportguazi-v1',
      'wexkafei-v1',
      'wexkanqiutong-v1',
      'wexkanqiu-v1',
      'wexwwe-v1',
    ];
    final isOptionalExt =
        ftyAdapters.contains(adapter) || wexAdapters.contains(adapter);
    if ((!isOptionalExt && !baseAdapters.contains(adapter)) ||
        bytes.isEmpty ||
        bytes.length > _maxBundleBytes ||
        bytes.any((b) => b < 0 || b > 255)) {
      throw const FormatException('插件适配器或文件大小无效');
    }
    final needsExtension = const [
      't4-v1',
      'apptt-v1',
      'app99-v1',
      'appsx-v1',
    ].contains(adapter);
    if (needsExtension) {
      if (extension == null ||
          extension.trim().isEmpty ||
          utf8.encode(extension).length > 16 * 1024) {
        throw const FormatException('插件扩展配置无效');
      }
    } else if (isOptionalExt) {
      if (extension != null && utf8.encode(extension).length > 16 * 1024) {
        throw const FormatException('插件扩展配置无效');
      }
    } else if (extension != null) {
      throw const FormatException('插件扩展配置无效');
    }
    final artifact = Uint8List.fromList(bytes);
    final hash = sha256.convert(artifact).toString();
    final root = await _withCancellation(_storage(), cancellation);
    _checkCancellation(cancellation);
    final folder = Directory('${root.path}/imports');
    await _withCancellation(folder.create(recursive: true), cancellation);
    _checkCancellation(cancellation);
    final previousTurn = _bootstrapQueue;
    final turnDone = Completer<void>();
    _bootstrapQueue = previousTurn.whenComplete(() => turnDone.future);
    try {
      await _withCancellation(previousTurn, cancellation);
      _checkCancellation(cancellation);
      final file = File('${folder.path}/$hash.jar');
      if (await file.exists()) {
        if (await file.length() > _maxBundleBytes ||
            sha256.convert(await file.readAsBytes()).toString() != hash) {
          throw const FormatException('本机插件文件校验失败');
        }
      } else {
        await _withCancellation(_writeAtomic(file, artifact), cancellation);
      }
      _checkCancellation(cancellation);
      var base = await _withCancellation(_ensure(), cancellation);
      _checkCancellation(cancellation);
      final deadline = DateTime.now().add(const Duration(seconds: 2));
      var backoffMs = 80;
      var recoveredOnce = false;
      while (true) {
        try {
          return await _requestGuardBootstrap(
            base,
            hash,
            adapter,
            extension,
            cancellation,
          );
        } on _RecoverableLoopbackException catch (error) {
          if (recoveredOnce) {
            Error.throwWithStackTrace(error.cause, error.stackTrace);
          }
          recoveredOnce = true;
          base = await _withCancellation(_recoverLoopback(base), cancellation);
        } on GuardBootstrapException catch (error) {
          if (error.code != 'bootstrap_busy' ||
              !DateTime.now().isBefore(deadline)) {
            rethrow;
          }
          final remaining = deadline.difference(DateTime.now()).inMilliseconds;
          if (remaining <= 0) rethrow;
          await _withCancellation(
            Future<void>.delayed(
              Duration(
                milliseconds: remaining < backoffMs ? remaining : backoffMs,
              ),
            ),
            cancellation,
          );
          backoffMs = (backoffMs * 2).clamp(80, 250);
        }
      }
    } finally {
      if (!turnDone.isCompleted) turnDone.complete();
    }
  }

  Future<Map<String, dynamic>> _requestGuardBootstrap(
    Uri base,
    String hash,
    String adapter,
    String? extension,
    Completer<void>? cancellation,
  ) async {
    _checkCancellation(cancellation);
    final client = HttpClient()
      ..findProxy = ((_) => 'DIRECT')
      ..connectionTimeout = const Duration(seconds: 8);
    var finished = false;
    var timedOut = false;
    var gotResponse = false;
    cancellation?.future.then((_) {
      if (!finished) client.close(force: true);
    });
    final timer = Timer(const Duration(seconds: 10), () {
      timedOut = true;
      client.close(force: true);
    });
    try {
      final request = await _withCancellation(
        client.postUrl(base.replace(path: '${base.path}/_port-bootstrap')),
        cancellation,
      );
      _checkCancellation(cancellation);
      request.followRedirects = false;
      request.headers.contentType = ContentType.json;
      final body = utf8.encode(
        jsonEncode({
          'version': 1,
          'adapter': adapter,
          'artifactHash': hash,
          if (extension != null) 'extension': extension,
        }),
      );
      request.contentLength = body.length;
      request.add(body);
      final response = await _withCancellation(request.close(), cancellation);
      gotResponse = true;
      final output = BytesBuilder(copy: false);
      await for (final chunk in response) {
        _checkCancellation(cancellation);
        if (output.length + chunk.length > _maxBundleBytes) {
          throw const FormatException('插件解析响应过大');
        }
        output.add(chunk);
      }
      _checkCancellation(cancellation);
      final decoded = jsonDecode(utf8.decode(output.takeBytes()));
      if (response.statusCode != 200) {
        const errors = {
          'guard_artifact_unsupported': '当前插件版本尚未完成本机移植',
          'guard_artifact_integrity': '插件文件校验失败',
          'guard_artifact_invalid': '插件包格式无效',
          'bootstrap_busy': '插件解析正在进行，请稍后重试',
          'bootstrap_timeout': '插件解析超时',
          'bootstrap_request': '插件解析请求无效',
        };
        final code = decoded is Map ? decoded['error'] : null;
        throw GuardBootstrapException(
          errors.containsKey(code) ? code as String : 'bootstrap_http',
          errors.containsKey(code)
              ? '${errors[code]}（$code）'
              : '插件解析失败（HTTP ${response.statusCode}）',
        );
      }
      if (decoded is! Map<String, dynamic> ||
          decoded['version'] != 1 ||
          decoded.keys.any(
            (key) => !const ['version', 'rule', 'origin'].contains(key),
          ) ||
          decoded['rule'] is! String ||
          decoded['origin'] is! String) {
        throw const FormatException('插件解析结果格式无效');
      }
      final rule = decoded['rule'] as String;
      final origin = decoded['origin'] as String;
      final uri = Uri.tryParse(origin);
      if (rule.trim().isEmpty ||
          utf8.encode(rule).length > 6 * 1024 * 1024 ||
          origin.length > 8192 ||
          uri == null ||
          !const ['http', 'https'].contains(uri.scheme) ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty ||
          uri.hasFragment) {
        throw const FormatException('插件解析规则或来源无效');
      }
      return decoded;
    } catch (error, stackTrace) {
      _checkCancellation(cancellation);
      if (!gotResponse &&
          !timedOut &&
          (error is SocketException || error is HttpException)) {
        throw _RecoverableLoopbackException(error, stackTrace);
      }
      rethrow;
    } finally {
      finished = true;
      timer.cancel();
      client.close(force: true);
    }
  }

  static Uri _drpyAddress(String address) {
    final uri = Uri.parse(address);
    if (uri.scheme != 'catpaw' ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(uri.host) ||
        uri.path != '/api/drpy' ||
        uri.userInfo.isNotEmpty ||
        uri.hasPort ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw const FormatException('DRPY 本机地址无效');
    }
    return uri;
  }

  Future<String> callDrpy(
    String address,
    String method,
    List<Object?> args, {
    Completer<void>? cancellation,
  }) async {
    _checkCancellation(cancellation);
    _drpyAddress(address);
    if (!const [
      'home',
      'homeVod',
      'category',
      'search',
      'detail',
      'play',
    ].contains(method)) {
      throw const FormatException('DRPY 调用方法无效');
    }
    final body = utf8.encode(
      jsonEncode({'version': 1, 'method': method, 'args': args}),
    );
    if (body.length > 6 * 1024 * 1024)
      throw const FormatException('DRPY 调用参数过大');
    final releasing = _releasingDrpy[address];
    if (releasing != null) await _withCancellation(releasing, cancellation);
    _checkCancellation(cancellation);
    _activeDrpy[address] = (_activeDrpy[address] ?? 0) + 1;
    var opened = false;
    try {
      final raw = await _request(
        address,
        method: 'POST',
        body: body,
        rewriteUrls: true,
        requestTimeout: const Duration(seconds: 45),
        cancellation: cancellation,
        onRequestOpened: () => opened = true,
      );
      if (jsonDecode(raw) is! Map)
        throw const FormatException('DRPY 返回内容不是 JSON 对象');
      return raw;
    } finally {
      final remaining = (_activeDrpy[address] ?? 1) - 1;
      if (remaining > 0) {
        _activeDrpy[address] = remaining;
      } else {
        _activeDrpy.remove(address);
        if (opened && cancellation?.isCompleted == true) {
          // A new call must wait until the older cancelled call's cleanup ends.
          late final Future<void> release;
          release = releaseDrpy(address).catchError((Object _) {}).whenComplete(
            () {
              if (identical(_releasingDrpy[address], release))
                _releasingDrpy.remove(address);
            },
          );
          _releasingDrpy[address] = release;
        }
      }
    }
  }

  static void _checkCancellation(Completer<void>? cancellation) {
    if (cancellation?.isCompleted == true) throw const FormatException('搜索已取消');
  }

  static Future<T> _withCancellation<T>(
    Future<T> task,
    Completer<void>? cancellation,
  ) {
    if (cancellation?.isCompleted == true) {
      unawaited(task.then<void>((_) {}, onError: (Object _) {}));
    }
    _checkCancellation(cancellation);
    if (cancellation == null) return task;
    return Future.any([
      task,
      cancellation.future.then<T>((_) => throw const FormatException('搜索已取消')),
    ]);
  }

  Future<void> releaseDrpy(String address) async {
    final uri = _drpyAddress(address);
    await _request(
      uri.replace(path: '/_release').toString(),
      method: 'POST',
      rewriteUrls: false,
    );
  }

  Future<String> install(String code) async {
    if (!isBundle(code)) throw const FormatException('没有 CatPaw 服务入口');
    if (_useEmbeddedEngine) {
      throw StateError(
        '当前鸿蒙端暂不支持运行 Node.js CatPaw 服务包，请改用标准 TVBox/DRPY 订阅，或在桌面端/iOS 端使用该订阅',
      );
    }
    final bytes = utf8.encode(code);
    if (bytes.length > 16 * 1024 * 1024)
      throw const FormatException('CatPaw 服务包超过大小限制');
    final hash = sha256.convert(bytes).toString();
    final root = await _storage();
    final folder = Directory('${root.path}/$hash');
    await folder.create(recursive: true);
    final file = File('${folder.path}/index.cjs');
    if (!await file.exists()) {
      final staging = File('${folder.path}/index.tmp');
      await staging.writeAsBytes(bytes, flush: true);
      await staging.rename(file.path);
    }
    final raw = await read('catpaw://$hash/t4');
    final config = jsonDecode(raw);
    if (config is! Map || config['sites'] is! List)
      throw const FormatException('CatPaw 没有返回线路列表');
    final sites = <Map<String, dynamic>>[];
    for (final row in config['sites']) {
      if (row is! Map) continue;
      final api = Uri.tryParse('${row['api'] ?? ''}');
      if (api?.scheme != 'catpaw' ||
          api?.host != hash ||
          !api!.path.startsWith('/api/'))
        continue;
      sites.add({
        ...row.map((k, v) => MapEntry(k.toString(), v)),
        'key': 'paw_${row['key'] ?? api.path}',
        'type': 4,
      });
    }
    if (sites.isEmpty) throw const FormatException('CatPaw 没有可用的本机线路');
    return jsonEncode({'sites': sites});
  }

  static bool _hasTraversalSegment(String rawAddress, Uri uri) {
    final schemeEnd = rawAddress.indexOf('://');
    if (schemeEnd < 0) return true;
    final afterAuth = rawAddress.indexOf('/', schemeEnd + 3);
    final rawTail = afterAuth < 0 ? '' : rawAddress.substring(afterAuth);
    final queryOrFrag = rawTail.indexOf(RegExp(r'[?#]'));
    final rawPath = queryOrFrag < 0 ? rawTail : rawTail.substring(0, queryOrFrag);
    for (final candidatePath in [rawPath, uri.path]) {
      if (RegExp(r'[\x00-\x1f\x7f\\]').hasMatch(candidatePath) ||
          RegExp(r'%00|%5c', caseSensitive: false).hasMatch(candidatePath)) {
        return true;
      }
      for (final rawSeg in candidatePath.split('/')) {
        if (rawSeg == '.' || rawSeg == '..') return true;
        String decoded;
        try {
          decoded = Uri.decodeComponent(rawSeg);
        } catch (_) {
          return true;
        }
        if (RegExp(r'[\x00-\x1f\x7f\\]').hasMatch(decoded)) return true;
        for (final sub in decoded.split('/')) {
          if (sub == '.' || sub == '..') return true;
        }
      }
    }
    return false;
  }

  static bool _isMediaProxyPath(String path) =>
      path == '/proxy' ||
      path.endsWith('/proxy') ||
      path.contains('/proxy/') ||
      path.startsWith('/stream/');

  Future<Uri> resolve(String address, {Completer<void>? cancellation}) async {
    _checkCancellation(cancellation);
    final generation = _generation;
    final logical = Uri.parse(address);
    if (logical.scheme != 'catpaw' ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(logical.host) ||
        logical.userInfo.isNotEmpty ||
        logical.hasPort ||
        _hasTraversalSegment(address, logical)) {
      throw const FormatException('CatPaw 本机地址无效');
    }
    final root = await _storage();
    _checkCancellation(cancellation);
    final drpy = File('${root.path}/${logical.host}/drpy.json');
    if (await drpy.exists()) {
      final drpyLen = await drpy.length();
      if (!const ['/api/drpy', '/_release', '/proxy'].contains(logical.path) ||
          (logical.hasQuery && logical.path != '/proxy') ||
          logical.hasFragment ||
          drpyLen > _maxBundleBytes) {
        throw const FormatException('DRPY 本机地址无效');
      }
      if (_verifiedDrpySizes[logical.host] != drpyLen) {
        final bytes = await drpy.readAsBytes();
        _checkCancellation(cancellation);
        if (sha256.convert(bytes).toString() != logical.host) {
          throw const FormatException('DRPY 本机规则包校验失败');
        }
        _drpyManifest(bytes);
        if (_verifiedDrpySizes.length >= 128) {
          _verifiedDrpySizes.remove(_verifiedDrpySizes.keys.first);
        }
        _verifiedDrpySizes[logical.host] = drpyLen;
      }
    } else if (_useEmbeddedEngine) {
      throw StateError(
        '该线路属于 Node.js CatPaw 服务包，鸿蒙端暂不支持直接运行，请切换其他片源',
      );
    } else if (!await File('${root.path}/${logical.host}/index.cjs').exists()) {
      throw StateError('此设备没有对应的 CatPaw 服务包，请重新导入原订阅');
    } else if (logical.path.startsWith('/api/spider/')) {
      await _syncNetdiskConfig(root);
    }
    _checkCancellation(cancellation);
    if (generation != _generation) throw StateError('CatPaw 本机服务已关闭');
    var base = await _withCancellation(_ensure(), cancellation);
    if ((Platform.isIOS || _useEmbeddedEngine) &&
        _isMediaProxyPath(logical.path)) {
      if (!await _withCancellation(_probeHealth(base), cancellation)) {
        base = await _withCancellation(_recoverLoopback(base), cancellation);
      }
    }
    _checkCancellation(cancellation);
    if (generation != _generation) throw StateError('CatPaw 本机服务已关闭');
    return base.replace(
      path: '${base.path}/${logical.host}${logical.path}',
      query: logical.hasQuery ? logical.query : null,
    );
  }

  Future<Uri> settings(String address) async {
    final logical = Uri(
      scheme: 'catpaw',
      host: Uri.parse(address).host,
      path: '/_manage',
    );
    final result = jsonDecode(await read(logical.toString(), method: 'POST'));
    final url = Uri.tryParse('${result['url'] ?? ''}');
    if (url == null ||
        url.scheme != 'http' ||
        url.host != '127.0.0.1' ||
        !url.path.startsWith('/authorize/')) {
      throw StateError('CatPaw 配置页面启动失败');
    }
    return url;
  }

  Future<String> read(String address, {String method = 'GET'}) async {
    return _request(address, method: method);
  }

  Future<String> _request(
    String address, {
    String method = 'GET',
    List<int>? body,
    bool rewriteUrls = true,
    Duration requestTimeout = const Duration(seconds: 35),
    Completer<void>? cancellation,
    void Function()? onRequestOpened,
  }) async {
    _checkCancellation(cancellation);
    final logical = Uri.parse(address);
    for (var attempt = 0; attempt < 2; attempt++) {
      _checkCancellation(cancellation);
      final url = await _withCancellation(
        resolve(address, cancellation: cancellation),
        cancellation,
      );
      _checkCancellation(cancellation);
      final requestBase = Uri(
        scheme: url.scheme,
        host: url.host,
        port: url.port,
        pathSegments: [url.pathSegments.first],
      );
      final client = HttpClient()
        ..findProxy = ((_) => 'DIRECT')
        ..connectionTimeout = const Duration(seconds: 8);
      var finished = false;
      var timedOut = false;
      var gotResponse = false;
      cancellation?.future.then((_) {
        if (!finished) client.close(force: true);
      });
      final timer = Timer(requestTimeout, () {
        timedOut = true;
        client.close(force: true);
      });
      try {
        final request = await _withCancellation(
          client.openUrl(method, url),
          cancellation,
        );
        _checkCancellation(cancellation);
        onRequestOpened?.call();
        request.followRedirects = false;
        if (body != null) {
          request.headers.contentType = ContentType.json;
          request.contentLength = body.length;
          request.add(body);
        }
        final response = await request.close();
        gotResponse = true;
        _checkCancellation(cancellation);
        if (logical.path == '/api/drpy' && response.statusCode == 422) {
          final errorBytes = BytesBuilder(copy: false);
          await for (final chunk in response) {
            _checkCancellation(cancellation);
            if (errorBytes.length + chunk.length > 16 * 1024) {
              throw const FormatException('片源错误响应过大');
            }
            errorBytes.add(chunk);
          }
          _checkCancellation(cancellation);
          Object? error;
          try {
            error = jsonDecode(utf8.decode(errorBytes.takeBytes()));
          } catch (_) {}
          const messages = {
            'drpy_verification_required': '此片源需要完成网站验证码，暂时无法加载',
            'drpy_action_invalid': '验证码已失效或格式不正确，请刷新后重试',
            'drpy_verification_unavailable': '暂时无法获取验证码图片，请稍后重试',
            'drpy_unsupported_filter': '此片源不支持当前筛选条件',
            'drpy_invalid_id': '此片源的影片标识无效，请重新打开影片',
            'drpy_local_proxy_not_supported': '此片源需要的本地代理暂不支持',
            'drpy_media_protocol': '此片源返回的播放地址协议暂不支持',
            'drpy_media_unresolved': '此片源暂未解析出可播放地址',
            'drpy_source_origin': '此片源返回了不支持的跨站目录',
            'drpy_source_unavailable': '此片源暂时无法访问',
            'drpy_source_response': '此片源返回了无法识别的数据',
            'drpy_crypto_invalid': '此片源的加密响应暂不兼容',
            'drpy_authentication_required': '此站点需要登录账号后才能查看网盘或播放链接，请切换其他片源',
            'drpy_filter_not_supported': '此片源不支持当前筛选条件',
            'drpy_local_module_missing': '本地规则包缺少依赖文件，请导入完整的规则包',
            'drpy_http_timeout': '连接片源服务器超时，请稍后重试或切换其他片源',
            'drpy_http_connection_failed': '无法连接片源服务器，该站点可能暂时离线或受当前网络限制',
            'drpy_http_response_failed': '读取片源服务器响应失败，请稍后重试',
            'drpy_http_response_too_large': '片源返回的数据超过大小上限',
            'drpy_http_encoding': '片源响应编码异常，暂时无法解析',
            'drpy_http_headers': '片源请求头格式不受支持',
            'drpy_http_method': '片源请求方式不受支持',
            'drpy_http_body_too_large': '片源请求体超过大小上限',
            'drpy_http_protocol': '片源请求地址协议不受支持',
            'drpy_redirect_credentials': '片源重定向包含不安全的认证信息',
            'drpy_http_redirect_limit': '片源服务器重定向次数过多',
            'drpy_http_redirect': '片源服务器返回了无效的重定向地址',
            'drpy_http_request': '片源网络请求参数无效',
            'drpy_http_response': '片源服务器返回了异常响应',
            'drpy_execution_timeout': '片源脚本加载超时，请重试或切换其他片源',
            'drpy_source_failed': '片源线路暂时无法返回有效数据，请稍后重试或切换其他片源',
            'drpy_host_error': '片源本地运行环境处理失败，请重试',
            'drpy_storage_key': '片源本地缓存键无效',
            'drpy_storage_action': '片源本地缓存操作不受支持',
            'drpy_storage_limit': '片源本地缓存超出容量限制',
            'drpy_random_size': '片源随机参数长度无效',
            'drpy_rule_missing': '片源规则尚未初始化完成，请重试',
            'drpy_async_result': '片源异步响应格式异常',
            'drpy_result': '片源返回结果超过大小上限或格式无效',
            'drpy_proxy_result': '片源代理响应格式不受支持',
          };
          final code = error is Map ? error['error'] : null;
          if (code is String && messages.containsKey(code)) {
            throw DrpySourceException(code, messages[code]!);
          }
          if (code is String && RegExp(r'^drpy_[a-z0-9_]+$').hasMatch(code)) {
            throw DrpySourceException(
              code,
              '此片源暂时无法连接或返回异常，请稍后重试或切换其他片源',
            );
          }
        }
        if (response.statusCode != 200)
          throw StateError('CatPaw 线路请求失败（HTTP ${response.statusCode}）');
        final bytes = BytesBuilder(copy: false);
        await for (final chunk in response) {
          _checkCancellation(cancellation);
          if (bytes.length + chunk.length > 16 * 1024 * 1024)
            throw const FormatException('CatPaw 响应过大');
          bytes.add(chunk);
        }
        final raw = utf8.decode(bytes.takeBytes());
        _checkCancellation(cancellation);
        if (!rewriteUrls) return raw;
        final httpPrefix = '${requestBase.toString()}/${logical.host}';
        final logicalPrefix = 'catpaw://${logical.host}';
        var rewritten = raw.replaceAll(httpPrefix, logicalPrefix);
        final escapedHttpPrefix = httpPrefix.replaceAll('/', r'\/');
        if (rewritten.contains(escapedHttpPrefix)) {
          rewritten = rewritten.replaceAll(
            escapedHttpPrefix,
            logicalPrefix.replaceAll('/', r'\/'),
          );
        }
        return rewritten;
      } catch (error) {
        _checkCancellation(cancellation);
        if (attempt == 0 &&
            !gotResponse &&
            !timedOut &&
            (error is SocketException || error is HttpException)) {
          await _withCancellation(_recoverLoopback(requestBase), cancellation);
          continue;
        }
        rethrow;
      } finally {
        finished = true;
        timer.cancel();
        client.close(force: true);
      }
    }
    throw StateError('CatPaw 线路请求失败');
  }

  Future<void> _resetEmbedded(Uri base) async {
    final client = HttpClient()
      ..findProxy = ((_) => 'DIRECT')
      ..connectionTimeout = const Duration(seconds: 3);
    final timer = Timer(
      const Duration(seconds: 5),
      () => client.close(force: true),
    );
    try {
      final request = await client.postUrl(
        base.replace(path: '${base.path}/_reset'),
      );
      final response = await request.close();
      await response.drain<void>();
      if (response.statusCode != 200) throw StateError('本机线路正在清理，请稍后重试');
      _needsReset = false;
    } finally {
      timer.cancel();
      client.close(force: true);
    }
  }

  Future<void> close() {
    if (_closing != null) return _closing!;
    late final Future<void> task;
    task = _close().whenComplete(() {
      if (identical(_closing, task)) _closing = null;
    });
    return _closing = task;
  }

  Future<void> _close() async {
    _generation++;
    final base = _base;
    _base = null;
    if (Platform.isIOS && base != null) {
      _needsReset = true;
      try {
        await _resetEmbedded(base);
      } catch (_) {
        // The next request must finish cleanup before loading any new sources.
      }
    }
    final embedded = _embeddedEngine;
    _embeddedEngine = null;
    if (embedded != null) {
      await embedded.close();
    }
    final process = _process;
    _process = null;
    if (process != null) {
      await process.stdin.close();
      try {
        await process.exitCode.timeout(const Duration(seconds: 3));
      } catch (_) {
        process.kill();
      }
    }
  }
}
