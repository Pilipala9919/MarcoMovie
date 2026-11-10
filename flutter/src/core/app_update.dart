import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

class UpdateCancelled implements Exception {
  const UpdateCancelled();
}

/// Cancellation also releases the underlying HTTP request, not just its UI.
class UpdateCancellation {
  final _done = Completer<void>();
  bool get isCancelled => _done.isCompleted;
  Future<void> get whenCancelled => _done.future;
  void cancel() {
    if (!isCancelled) _done.complete();
  }

  void check() {
    if (isCancelled) throw const UpdateCancelled();
  }

  Future<T> bind<T>(Future<T> work) => Future.any([
        work,
        whenCancelled.then<T>((_) => throw const UpdateCancelled()),
      ]);
}

class AppUpdate {
  final String version;
  final String notes;
  final Uri? windowsUrl;
  final String? checksum;
  final int? size;
  final Uri? iosUrl;
  const AppUpdate(
    this.version,
    this.notes,
    this.windowsUrl,
    this.checksum,
    this.size, [
    this.iosUrl,
  ]);

  // Only use the advertised asset. The download site does not host large IPAs.
  Uri get iosMirrorIpaUrl =>
      iosUrl ?? (throw const FormatException('缺少 iOS 更新包地址'));

  Uri get trollStoreInstallUrl {
    final target = iosUrl;
    if (target == null || checksum == null || size == null) {
      throw const FormatException('缺少可信的 iOS 更新信息');
    }
    return Uri.parse(
      'apple-magnifier://install?url=${Uri.encodeComponent(target.toString())}',
    );
  }

  static Uri? trustedAsset(dynamic value) {
    final uri = Uri.tryParse(value?.toString() ?? '');
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment ||
        (uri.hasPort && uri.port != 443)) {
      return null;
    }
    if (uri.host == 'github.com' &&
            uri.path
                .startsWith('/Pilipala9919/MarcoMovie/releases/download/') ||
        uri.host == 'marcotv.wlj9919.top' && uri.path.startsWith('/movie/')) {
      return uri;
    }
    return null;
  }

  static AppUpdate parse(Map<String, dynamic> json,
      {bool github = false, String platform = 'windows'}) {
    if (!github && json['platform'] != null && json['platform'] != platform) {
      throw const FormatException('更新包平台不匹配');
    }
    final raw =
        (github ? json['tag_name'] : json['versionName'])?.toString() ?? '';
    final normalized =
        raw.startsWith('$platform-') ? raw.substring(platform.length + 1) : raw;
    final match = RegExp(r'^[vV]?(\d+\.\d+\.\d+)(?:-preview)?$')
        .firstMatch(normalized.trim());
    if (match == null) throw const FormatException('更新版本信息无效');
    final version = match.group(1)!;
    Map? asset;
    if (github) {
      final assets = json['assets'];
      if (assets is List) {
        for (final item in assets.whereType<Map>()) {
          if (platform == 'windows' &&
              item['name'] == 'MarcoMovie-$version-windows-setup.exe') {
            asset = item;
          } else if (platform == 'ios' &&
              (item['name'] == 'MarcoMovie-$version-ios-unsigned.ipa' ||
                  item['name'] ==
                      'MarcoMovie-$version-ios-iphone-ipad-unsigned.ipa')) {
            asset ??= item;
          }
        }
      }
    } else if (platform == 'windows' && json['windows'] is Map) {
      asset = json['windows'] as Map;
    } else if (platform == 'ios') {
      if (json['package'] is Map) {
        asset = json['package'] as Map;
      } else if (json['packages'] is Map) {
        final pkgs = json['packages'] as Map;
        final cand = pkgs['MarcoMovie-$version-ios-unsigned.ipa'] ??
            pkgs['MarcoMovie-$version-ios-iphone-ipad-unsigned.ipa'];
        if (cand is Map) asset = cand;
      } else if (json['ios'] is Map) {
        asset = json['ios'] as Map;
      }
    }
    final data = asset ?? const <String, dynamic>{};
    final digest = (github ? data['digest'] : data['sha256'])
        ?.toString()
        .replaceFirst('sha256:', '');
    final size = data['size'];
    final uri =
        trustedAsset(github ? data['browser_download_url'] : data['url']);
    final validDigest = digest != null &&
        RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(digest) &&
        size is int &&
        size > 0;
    final verifiedWin = platform == 'windows' &&
        uri != null &&
        uri.path.endsWith('/MarcoMovie-$version-windows-setup.exe') &&
        validDigest;
    final verifiedIos = platform == 'ios' &&
        uri != null &&
        (uri.path.endsWith('/MarcoMovie-$version-ios-unsigned.ipa') ||
            uri.path.endsWith(
              '/MarcoMovie-$version-ios-iphone-ipad-unsigned.ipa',
            )) &&
        validDigest;
    final verified = verifiedWin || verifiedIos;
    return AppUpdate(
      version,
      (json[github ? 'body' : 'notes'] ?? '').toString(),
      verifiedWin ? uri : null,
      verified ? digest.toLowerCase() : null,
      verified ? size : null,
      verifiedIos ? uri : null,
    );
  }

  static String get currentPlatform => Platform.isWindows
      ? 'windows'
      : Platform.isIOS
          ? 'ios'
          : Platform.isMacOS
              ? 'macos'
              : 'android';

  static String _suffix(String platform) => switch (platform) {
        'windows' => 'windows-setup.exe',
        'ios' => 'ios-unsigned.ipa',
        'macos' => 'macos.zip',
        'android' => 'mobile.apk',
        _ => throw const FormatException('不支持的更新平台'),
      };

  static AppUpdate _githubRelease(dynamic body, String platform) {
    final candidates = <AppUpdate>[];
    for (final item in (body is List ? body : [body]).whereType<Map>()) {
      if (item['draft'] == true || item['prerelease'] == true) continue;
      try {
        final release = parse(Map<String, dynamic>.from(item),
            github: true, platform: platform);
        final name = 'MarcoMovie-${release.version}-${_suffix(platform)}';
        final altIosName =
            'MarcoMovie-${release.version}-ios-iphone-ipad-unsigned.ipa';
        final assets = item['assets'];
        if (assets is! List ||
            !assets.whereType<Map>().any(
                  (asset) =>
                      (asset['name'] == name ||
                          (platform == 'ios' && asset['name'] == altIosName)) &&
                      trustedAsset(asset['browser_download_url']) != null,
                )) {
          continue;
        }
        if (platform == 'windows' && release.windowsUrl == null ||
            platform == 'ios' && release.iosUrl == null) {
          continue;
        }
        candidates.add(release);
      } on FormatException {
        /* Another platform's release or malformed entry. */
      }
    }
    if (candidates.isEmpty) throw const FormatException('没有当前平台的正式更新');
    candidates.sort((a, b) {
      final av = a.version.split('.').map(int.parse).toList();
      final bv = b.version.split('.').map(int.parse).toList();
      for (var i = 0; i < av.length; i++) {
        if (av[i] != bv[i]) return bv[i].compareTo(av[i]);
      }
      return 0;
    });
    return candidates.first;
  }

  static Future<AppUpdate> check({
    http.Client? client,
    String? platform,
    Duration endpointTimeout = const Duration(seconds: 8),
    UpdateCancellation? cancellation,
    void Function(String)? onStage,
  }) async {
    platform ??= currentPlatform;
    _suffix(platform);
    final transport = client ?? http.Client();
    try {
      for (final url in [
        'https://marcotv.wlj9919.top/movie/updates/$platform.json',
        'https://api.github.com/repos/Pilipala9919/MarcoMovie/releases?per_page=100',
      ]) {
        final abort = Completer<void>();
        void stop() {
          if (!abort.isCompleted) abort.complete();
        }

        cancellation?.whenCancelled.then((_) => stop());
        try {
          cancellation?.check();
          onStage?.call(url.contains('api.github.com')
              ? '正在连接 GitHub 备用更新源…'
              : '正在连接镜像更新源…');
          final request = http.AbortableRequest('GET', Uri.parse(url),
              abortTrigger: abort.future)
            ..headers.addAll({
              'User-Agent': 'MarcoMovie-Updater',
              'Cache-Control': 'no-cache'
            });
          Future<dynamic> read() async {
            final response = await transport.send(request);
            if (response.statusCode != 200) {
              throw HttpException('HTTP ${response.statusCode}');
            }
            final bytes = <int>[];
            await for (final chunk in response.stream) {
              if (bytes.length + chunk.length > 4 * 1024 * 1024) {
                throw const FormatException('更新信息过大');
              }
              bytes.addAll(chunk);
            }
            return jsonDecode(utf8.decode(bytes));
          }

          final work = read().timeout(endpointTimeout);
          final body = await (cancellation?.bind(work) ?? work);
          if (url.contains('api.github.com')) {
            return _githubRelease(body, platform);
          }
          if (body is! Map<String, dynamic> || body['prerelease'] == true) {
            continue;
          }
          final release = parse(body, platform: platform);
          if (platform == 'windows' && release.windowsUrl == null ||
              platform == 'ios' && release.iosUrl == null) {
            continue;
          }
          return release;
        } on UpdateCancelled {
          rethrow;
        } catch (_) {/* Try the second release endpoint. */} finally {
          stop();
        }
      }
      throw const HttpException('暂时无法检查更新，请稍后重试');
    } finally {
      if (client == null) transport.close();
    }
  }

  /// Downloads the published iOS asset to an isolated partial file. Only a
  /// complete, hash-verified package is exposed to Files / signing tools.
  Future<File> downloadIos({
    required Directory directory,
    required UpdateCancellation cancellation,
    http.Client? client,
    Duration connectionTimeout = const Duration(seconds: 15),
    Duration stallTimeout = const Duration(seconds: 30),
    Duration totalTimeout = const Duration(minutes: 8),
    void Function(int received, int total)? onProgress,
  }) async {
    final target = iosUrl;
    if (target == null ||
        trustedAsset(target.toString()) == null ||
        size == null ||
        checksum == null) {
      throw const FormatException('缺少可信的 iOS 更新信息');
    }
    final installedFile =
        File('${directory.path}/MarcoMovie-$version-ios-unsigned.ipa');
    cancellation.check();
    if (await installedFile.exists()) {
      try {
        await verifyFile(installedFile);
        cancellation.check();
        return installedFile;
      } on FormatException {
        await installedFile.delete();
      }
    }
    final transport = client ?? http.Client();
    final abort = Completer<void>();
    final deadline = Timer(totalTimeout, () {
      if (!abort.isCompleted) abort.complete();
    });
    cancellation.whenCancelled.then((_) {
      if (!abort.isCompleted) abort.complete();
    });
    Directory? staging;
    IOSink? sink;
    try {
      cancellation.check();
      await directory.create(recursive: true);
      staging = await directory.createTemp('.marco-update-');
      final partial = File('${staging.path}/package.part');
      final request =
          http.AbortableRequest('GET', target, abortTrigger: abort.future);
      final response = await cancellation
          .bind(transport.send(request).timeout(connectionTimeout));
      if (response.statusCode != 200) {
        throw HttpException('HTTP ${response.statusCode}');
      }
      if (response.contentLength != null && response.contentLength != size) {
        throw const FormatException('更新包大小与发布清单不一致');
      }
      var received = 0;
      sink = partial.openWrite();
      // Both a stalled stream and a stream trickling forever have a deadline.
      Future<void> receive() async {
        await for (final chunk in response.stream.timeout(stallTimeout)) {
          cancellation.check();
          if (abort.isCompleted) throw TimeoutException('更新包下载超时');
          received += chunk.length;
          if (received > size!) throw const FormatException('更新包超过发布大小');
          sink!.add(chunk);
          onProgress?.call(received, size!);
        }
      }

      await cancellation.bind(Future.any([
        receive(),
        abort.future.then<void>((_) => throw TimeoutException('更新包下载超时')),
      ]));
      await sink.flush();
      await sink.close();
      sink = null;
      cancellation.check();
      await verifyFile(partial);
      cancellation.check();
      return await partial
          .rename('${directory.path}/MarcoMovie-$version-ios-unsigned.ipa');
    } finally {
      deadline.cancel();
      if (!abort.isCompleted) abort.complete();
      if (client == null) transport.close();
      await sink?.close();
      if (staging != null && await staging.exists()) {
        await staging.delete(recursive: true);
      }
    }
  }

  Future<void> verifyFile(File file) async {
    if ((windowsUrl == null && iosUrl == null) ||
        size == null ||
        checksum == null ||
        await file.length() != size) {
      throw const FormatException('更新包大小不符或缺少校验信息');
    }
    final digest = await sha256.bind(file.openRead()).first;
    if (digest.toString() != checksum) {
      throw const FormatException('更新包校验失败，请重新下载');
    }
  }
}
