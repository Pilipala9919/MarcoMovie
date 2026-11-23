import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:path_provider/path_provider.dart';

import 'cloud_media_proxy.dart';

enum _TargetKind { auto, playlist, tsSegment, raw, diskCached }

class _RegisteredTarget {
  final Uri uri;
  final _TargetKind kind;
  final String? cacheKey;
  final DiskBlockCache? diskCache;
  const _RegisteredTarget(
    this.uri,
    this.kind, {
    this.cacheKey,
    this.diskCache,
  });
}

class _StoredCookie {
  final String name;
  final String value;
  final String domain;
  final bool hostOnly;
  final String path;
  final DateTime? expiresAt;

  const _StoredCookie({
    required this.name,
    required this.value,
    required this.domain,
    required this.hostOnly,
    required this.path,
    this.expiresAt,
  });

  bool matches(Uri uri, DateTime now) {
    if (expiresAt != null && !expiresAt!.isAfter(now)) return false;
    final reqHost = uri.host.toLowerCase();
    if (hostOnly) {
      if (reqHost != domain) return false;
    } else {
      if (reqHost != domain && !reqHost.endsWith('.$domain')) return false;
    }
    final reqPath = uri.path.isEmpty ? '/' : uri.path;
    if (path == '/' || reqPath == path) return true;
    if (reqPath.startsWith(path)) {
      return path.endsWith('/') || reqPath.codeUnitAt(path.length) == 0x2F;
    }
    return false;
  }
}

class _SessionCookieJar {
  final Map<String, _StoredCookie> _cookies = {};

  static List<String> splitSetCookieHeader(String raw) {
    final result = <String>[];
    var start = 0;
    var inExpires = false;
    for (var i = 0; i < raw.length; i++) {
      final ch = raw.codeUnitAt(i);
      if (ch == 0x3B /* ; */) {
        inExpires = false;
      } else if (!inExpires &&
          i + 8 <= raw.length &&
          raw.substring(i, i + 8).toLowerCase() == 'expires=') {
        inExpires = true;
      } else if (ch == 0x2C /* , */) {
        if (inExpires) {
          inExpires = false;
          continue;
        }
        final rest = raw.substring(i + 1).trimLeft();
        final semi = rest.indexOf(';');
        final eq = rest.indexOf('=');
        if (eq > 0 && (semi < 0 || eq < semi)) {
          final piece = raw.substring(start, i).trim();
          if (piece.isNotEmpty) result.add(piece);
          start = i + 1;
        }
      }
    }
    final tail = raw.substring(start).trim();
    if (tail.isNotEmpty) result.add(tail);
    return result;
  }

  void storeFromHeaders(
      Map<String, String> responseHeaders, Uri requestUri, DateTime now) {
    String? rawSetCookie;
    for (final entry in responseHeaders.entries) {
      if (entry.key.toLowerCase() == 'set-cookie') {
        rawSetCookie = entry.value;
        break;
      }
    }
    if (rawSetCookie == null || rawSetCookie.trim().isEmpty) return;
    for (final header in splitSetCookieHeader(rawSetCookie)) {
      final parts = header.split(';');
      if (parts.isEmpty) continue;
      final nv = parts.first.trim();
      final eq = nv.indexOf('=');
      if (eq <= 0) continue;
      final name = nv.substring(0, eq).trim();
      final value = nv.substring(eq + 1).trim();
      if (name.isEmpty) continue;

      final reqHost = requestUri.host.toLowerCase();
      var domain = reqHost;
      var hostOnly = true;
      var path = _defaultCookiePath(requestUri.path);
      DateTime? expiresAt;

      for (final rawAttr in parts.skip(1)) {
        final attr = rawAttr.trim();
        if (attr.isEmpty) continue;
        final aEq = attr.indexOf('=');
        final aKey =
            (aEq < 0 ? attr : attr.substring(0, aEq)).trim().toLowerCase();
        final aVal = aEq < 0 ? '' : attr.substring(aEq + 1).trim();
        if (aKey == 'domain' && aVal.isNotEmpty) {
          final clean = aVal.replaceFirst(RegExp(r'^\.+'), '').toLowerCase();
          if (clean.contains('.') &&
              InternetAddress.tryParse(clean) == null &&
              (reqHost == clean || reqHost.endsWith('.$clean'))) {
            domain = clean;
            hostOnly = false;
          }
        } else if (aKey == 'path' && aVal.startsWith('/')) {
          path = aVal;
        } else if (aKey == 'max-age') {
          final secs = int.tryParse(aVal);
          if (secs != null) {
            expiresAt = secs <= 0
                ? now.subtract(const Duration(seconds: 1))
                : now.add(Duration(seconds: secs));
          }
        } else if (aKey == 'expires' && expiresAt == null && aVal.isNotEmpty) {
          try {
            expiresAt = HttpDate.parse(aVal);
          } catch (_) {}
        }
      }

      final storageKey = '$domain|$hostOnly|$path|$name';
      if (value.isEmpty || (expiresAt != null && !expiresAt.isAfter(now))) {
        _cookies.remove(storageKey);
      } else if (_cookies.length < 256 || _cookies.containsKey(storageKey)) {
        _cookies[storageKey] = _StoredCookie(
          name: name,
          value: value,
          domain: domain,
          hostOnly: hostOnly,
          path: path,
          expiresAt: expiresAt,
        );
      }
    }
  }

  Map<String, String> matchingCookies(Uri uri, DateTime now) {
    final out = <String, String>{};
    final matched = _cookies.values.where((c) => c.matches(uri, now)).toList()
      ..sort((a, b) => a.path.length.compareTo(b.path.length));
    for (final c in matched) {
      out[c.name] = c.value;
    }
    return out;
  }

  void clear() => _cookies.clear();

  static String _defaultCookiePath(String reqPath) {
    if (reqPath.isEmpty || !reqPath.startsWith('/')) return '/';
    final lastSlash = reqPath.lastIndexOf('/');
    return lastSlash <= 0 ? '/' : reqPath.substring(0, lastSlash);
  }
}

/// 256 KiB block-aligned disk Range cache (`/kcache/<sid>`) with concurrent
/// block deduplication, HTTP 206 Partial Content, 416 no-Range retry, and LRU
/// capacity eviction.
class DiskBlockCache {
  DiskBlockCache({
    Directory? directory,
    int? maxBytes,
    int maxFullResponseCacheBytes = defaultMaxFullResponseCacheBytes,
    DateTime Function()? clock,
  })  : _explicitDirectory = directory,
        _maxBytes = math.max(0, maxBytes ?? defaultMaxBytes),
        _maxFullResponseCacheBytes = math.max(1, maxFullResponseCacheBytes),
        _clock = clock;

  static const int blockSize = 256 * 1024; // 256 KiB
  static int get defaultMaxBytes =>
      (Platform.isWindows || Platform.isMacOS || Platform.isLinux)
          ? 512 * 1024 * 1024
          : 256 * 1024 * 1024;
  static const List<int> supportedMaxMbOptions = <int>[0, 256, 512, 1024, 2048];
  static const int defaultMaxFullResponseCacheBytes = 64 * 1024 * 1024;
  static const int _streamFlushThresholdBytes = 1024 * 1024;

  static final DiskBlockCache shared = DiskBlockCache();
  static DiskBlockCache get instance => shared;

  final Directory? _explicitDirectory;
  final int _maxFullResponseCacheBytes;
  // ignore: unused_field
  final DateTime Function()? _clock;
  int _maxBytes;
  int _currentBytes = 0;
  int _generation = 0;
  int _accessSeq = 0;
  bool _initialized = false;
  Future<void>? _initFuture;
  Directory? _resolvedDir;

  final LinkedHashMap<String, _CachedBlockEntry> _entries =
      LinkedHashMap<String, _CachedBlockEntry>();
  final Map<String, _CachedObjectMeta> _metaByKey =
      <String, _CachedObjectMeta>{};
  final Set<String> _nonCacheablePassthroughKeys = <String>{};
  final Map<String, Future<void>> _inFlightInitialProbes =
      <String, Future<void>>{};
  final Map<String, Future<Uint8List>> _inFlightBlocks =
      <String, Future<Uint8List>>{};

  int get maxBytes => _maxBytes;
  bool get isEnabled => _maxBytes > 0;
  int get currentBytes => _currentBytes;
  int get cachedBlockCount => _entries.length;
  int get inFlightCount => _inFlightBlocks.length;

  static String cacheKeyForString(String raw) =>
      sha256.convert(utf8.encode(raw)).toString().substring(0, 32);

  static String cacheKeyForUri(Uri uri) => cacheKeyForString(uri.toString());

  Future<Directory> _resolveDirectory() async {
    if (_resolvedDir != null) return _resolvedDir!;
    if (_explicitDirectory != null) {
      try {
        _explicitDirectory.createSync(recursive: true);
      } catch (_) {}
      _resolvedDir = _explicitDirectory;
      return _resolvedDir!;
    }
    if (Platform.isWindows) {
      final localAppData = (Platform.environment['LOCALAPPDATA'] ?? '').trim();
      if (localAppData.isNotEmpty) {
        final winDir = Directory(
          '$localAppData${Platform.pathSeparator}MarcoMovie${Platform.pathSeparator}cache${Platform.pathSeparator}media-cache',
        );
        try {
          winDir.createSync(recursive: true);
        } catch (_) {}
        _resolvedDir = winDir;
        return winDir;
      }
    }
    Directory base;
    try {
      base = await getApplicationCacheDirectory();
    } on MissingPluginException {
      base = Directory(
        '${Directory.systemTemp.path}/marco_movie_cache',
      );
    } catch (_) {
      base = Directory(
        '${Directory.systemTemp.path}/marco_movie_cache',
      );
    }
    final dir = Directory('${base.path}/media-cache');
    try {
      dir.createSync(recursive: true);
    } catch (_) {}
    _resolvedDir = dir;
    return dir;
  }

  Future<void> ensureInitialized() => _initFuture ??= _initialize();

  Future<void> _initialize() async {
    if (_initialized) return;
    final dir = await _resolveDirectory();
    final diskBlocks = <({String id, File file, int size, DateTime modified})>[];
    if (dir.existsSync()) {
      for (final entity in dir.listSync(followLinks: false)) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.last;
        if (name.endsWith('.tmp')) {
          try {
            entity.deleteSync();
          } catch (_) {}
          continue;
        }
        if (name.endsWith('.blk')) {
          try {
            final stat = entity.statSync();
            final id = name.substring(0, name.length - 4);
            diskBlocks.add((
              id: id,
              file: entity,
              size: stat.size,
              modified: stat.modified,
            ));
          } catch (_) {}
        }
      }
    }
    diskBlocks.sort((a, b) => a.modified.compareTo(b.modified));
    _currentBytes = 0;
    _entries.clear();
    for (final item in diskBlocks) {
      _entries[item.id] = _CachedBlockEntry(
        id: item.id,
        file: item.file,
        size: item.size,
        accessSeq: ++_accessSeq,
      );
      _currentBytes += item.size;
    }
    _initialized = true;
    await _evictToBudget();
  }

  Future<void> setCapacityBytes(int nextMaxBytes) async {
    _maxBytes = math.max(0, nextMaxBytes);
    await ensureInitialized();
    if (_maxBytes == 0) {
      await clear();
      return;
    }
    await _evictToBudget();
  }

  Future<void> setCapacityMb(int mb) =>
      setCapacityBytes(mb <= 0 ? 0 : mb * 1024 * 1024);

  Future<void> setMaxBytes(int bytes) => setCapacityBytes(bytes);

  Future<void> setMaxMegabytes(int mb) => setCapacityMb(mb);

  Future<int> currentCacheBytes() async {
    await ensureInitialized();
    return _currentBytes;
  }

  Future<void> clearDiskCache() => clear();

  Future<void> flush() async {
    await ensureInitialized();
  }

  Future<void> writeBlock(
    String rawKey,
    int blockIndex,
    Uint8List bytes, {
    int? totalLength,
    String contentType = 'application/octet-stream',
  }) async {
    await ensureInitialized();
    final cacheKey = rawKey.length == 32 && RegExp(r'^[0-9a-f]+$').hasMatch(rawKey)
        ? rawKey
        : cacheKeyForString(rawKey);
    final gen = _generation;
    if (totalLength != null) {
      await _saveMeta(
        cacheKey,
        _CachedObjectMeta(
          totalLength: totalLength,
          contentType: contentType,
          supportsRanges: true,
        ),
        gen,
      );
    }
    await _writeCachedBlock(cacheKey, blockIndex, bytes, gen);
  }

  Future<bool> hasBlock(String rawKey, int blockIndex) async {
    await ensureInitialized();
    final cacheKey = rawKey.length == 32 && RegExp(r'^[0-9a-f]+$').hasMatch(rawKey)
        ? rawKey
        : cacheKeyForString(rawKey);
    final id = _blockId(cacheKey, blockIndex);
    final entry = _entries[id];
    if (entry == null) return false;
    return entry.file.exists();
  }

  Future<void> clear() async {
    _generation++;
    _entries.clear();
    _metaByKey.clear();
    _nonCacheablePassthroughKeys.clear();
    _currentBytes = 0;
    final dir = await _resolveDirectory();
    if (dir.existsSync()) {
      for (final entity in dir.listSync(followLinks: false)) {
        if (entity is File) {
          try {
            entity.deleteSync();
          } catch (_) {}
        }
      }
    }
  }

  Future<void> _evictToBudget() async {
    while (_currentBytes > _maxBytes && _entries.isNotEmpty) {
      final oldestKey = _entries.keys.first;
      final oldest = _entries.remove(oldestKey);
      if (oldest == null) continue;
      _currentBytes = math.max(0, _currentBytes - oldest.size);
      try {
        if (oldest.file.existsSync()) {
          oldest.file.deleteSync();
        }
      } catch (_) {}
    }
  }

  String _blockId(String cacheKey, int blockIndex) => '${cacheKey}_$blockIndex';

  Future<Uint8List?> _readCachedBlock(String cacheKey, int blockIndex) async {
    await ensureInitialized();
    if (_maxBytes <= 0) return null;
    final id = _blockId(cacheKey, blockIndex);
    final entry = _entries.remove(id);
    if (entry == null) return null;
    try {
      if (!await entry.file.exists()) {
        _currentBytes = math.max(0, _currentBytes - entry.size);
        return null;
      }
      final bytes = await entry.file.readAsBytes();
      entry.accessSeq = ++_accessSeq;
      _entries[id] = entry;
      return bytes;
    } catch (_) {
      _currentBytes = math.max(0, _currentBytes - entry.size);
      return null;
    }
  }

  Future<void> _writeCachedBlock(
    String cacheKey,
    int blockIndex,
    Uint8List bytes,
    int generation,
  ) async {
    await ensureInitialized();
    if (_maxBytes <= 0 || generation != _generation || bytes.isEmpty) return;
    if (bytes.length > _maxBytes) return;
    final dir = await _resolveDirectory();
    final id = _blockId(cacheKey, blockIndex);
    final targetFile = File('${dir.path}/$id.blk');
    final tmpFile = File('${dir.path}/$id.${++_accessSeq}.tmp');
    try {
      await tmpFile.writeAsBytes(bytes, flush: true);
      if (generation != _generation) {
        try {
          if (await tmpFile.exists()) await tmpFile.delete();
        } catch (_) {}
        return;
      }
      await tmpFile.rename(targetFile.path);
      final old = _entries.remove(id);
      if (old != null) {
        _currentBytes = math.max(0, _currentBytes - old.size);
      }
      _entries[id] = _CachedBlockEntry(
        id: id,
        file: targetFile,
        size: bytes.length,
        accessSeq: ++_accessSeq,
      );
      _currentBytes += bytes.length;
      await _evictToBudget();
    } catch (_) {
      try {
        if (await tmpFile.exists()) await tmpFile.delete();
      } catch (_) {}
    }
  }

  Future<_CachedObjectMeta?> _loadMeta(String cacheKey) async {
    final mem = _metaByKey[cacheKey];
    if (mem != null) return mem;
    await ensureInitialized();
    final dir = await _resolveDirectory();
    final file = File('${dir.path}/$cacheKey.meta.json');
    if (!await file.exists()) return null;
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is Map && decoded['totalLength'] is int) {
        final meta = _CachedObjectMeta(
          totalLength: decoded['totalLength'] as int,
          contentType: (decoded['contentType'] ?? '').toString(),
          supportsRanges: decoded['supportsRanges'] != false,
        );
        _metaByKey[cacheKey] = meta;
        return meta;
      }
    } catch (_) {}
    return null;
  }

  Future<void> _saveMeta(
    String cacheKey,
    _CachedObjectMeta meta,
    int generation,
  ) async {
    if (generation != _generation) return;
    _metaByKey[cacheKey] = meta;
    if (_maxBytes <= 0) return;
    await ensureInitialized();
    if (generation != _generation) return;
    final dir = await _resolveDirectory();
    final file = File('${dir.path}/$cacheKey.meta.json');
    final tmp = File('${dir.path}/$cacheKey.meta.${++_accessSeq}.tmp');
    try {
      await tmp.writeAsString(
        jsonEncode({
          'totalLength': meta.totalLength,
          'contentType': meta.contentType,
          'supportsRanges': meta.supportsRanges,
        }),
        flush: true,
      );
      await tmp.rename(file.path);
    } catch (_) {
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
    }
  }

  static ({int? start, int? end, int? suffixLength, bool valid}) _parseRange(
    String? header,
  ) {
    if (header == null || header.trim().isEmpty) {
      return (start: null, end: null, suffixLength: null, valid: true);
    }
    final match =
        RegExp(r'^bytes=(\d*)-(\d*)$', caseSensitive: false).firstMatch(header.trim());
    if (match == null) {
      return (start: null, end: null, suffixLength: null, valid: false);
    }
    final startStr = match.group(1)!;
    final endStr = match.group(2)!;
    if (startStr.isEmpty && endStr.isEmpty) {
      return (start: null, end: null, suffixLength: null, valid: false);
    }
    if (startStr.isEmpty) {
      final suffix = int.tryParse(endStr);
      if (suffix == null || suffix <= 0) {
        return (start: null, end: null, suffixLength: null, valid: false);
      }
      return (start: null, end: null, suffixLength: suffix, valid: true);
    }
    final start = int.tryParse(startStr);
    final end = endStr.isEmpty ? null : int.tryParse(endStr);
    if (start == null || (end != null && end < start)) {
      return (start: null, end: null, suffixLength: null, valid: false);
    }
    return (start: start, end: end, suffixLength: null, valid: true);
  }

  static int? _parseTotalLengthFromContentRange(String? contentRange) {
    if (contentRange == null || contentRange.isEmpty) return null;
    final m = RegExp(r'^bytes\s+\d+-\d+/(\d+)$', caseSensitive: false)
        .firstMatch(contentRange.trim());
    if (m != null) return int.tryParse(m.group(1)!);
    final star = RegExp(r'^bytes\s+\*/(\d+)$', caseSensitive: false)
        .firstMatch(contentRange.trim());
    if (star != null) return int.tryParse(star.group(1)!);
    return null;
  }

  static int? _parseContentLength(Map<String, String> headers) {
    final raw = headers['content-length'];
    if (raw == null || raw.trim().isEmpty) return null;
    final parsed = int.tryParse(raw.trim());
    return (parsed != null && parsed >= 0) ? parsed : null;
  }

  static bool _isHlsPlaylistResponse(Uri finalTarget, String? contentType) {
    final lowerUrl = '${finalTarget.path}?${finalTarget.query}'.toLowerCase();
    if (finalTarget.path.toLowerCase().endsWith('.m3u8') ||
        lowerUrl.contains('.m3u8')) {
      return true;
    }
    final mime = (contentType ?? '').toLowerCase();
    return mime.contains('mpegurl') || mime.contains('x-mpegurl');
  }

  Future<Uint8List> _readStreamBytes(
    Stream<List<int>> stream, {
    int? maxBytes,
  }) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in stream.timeout(const Duration(seconds: 30))) {
      if (maxBytes != null && builder.length + chunk.length > maxBytes) {
        throw const FormatException('缓存响应超出单次读取上限');
      }
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  Future<Uint8List> _readPrefixFromIterator(
    StreamIterator<List<int>> iter, {
    int minBytes = LocalMediaLease._sniffPrefixBytes,
  }) async {
    final builder = BytesBuilder(copy: false);
    while (builder.length < minBytes) {
      final hasNext = await iter.moveNext().timeout(const Duration(seconds: 30));
      if (!hasNext) break;
      final chunk = iter.current;
      if (chunk.isEmpty) continue;
      builder.add(chunk);
      final current = builder.toBytes();
      if (LocalMediaLease._startsWithM3u8Magic(current) ||
          !LocalMediaLease._couldBeM3u8Prefix(current)) {
        return builder.takeBytes();
      }
    }
    return builder.takeBytes();
  }

  Future<Uint8List> _drainBoundedPlaylistFromIterator(
    StreamIterator<List<int>> iter,
    Uint8List initialPrefix,
  ) async {
    if (initialPrefix.length > LocalMediaLease._maxPlaylistBytes) {
      throw const FormatException('媒体播放列表体积超出安全上限');
    }
    final builder = BytesBuilder(copy: false)..add(initialPrefix);
    while (await iter.moveNext().timeout(const Duration(seconds: 30))) {
      final chunk = iter.current;
      if (builder.length + chunk.length > LocalMediaLease._maxPlaylistBytes) {
        throw const FormatException('媒体播放列表体积超出安全上限');
      }
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  Future<void> _streamUpstreamSlice(
    HttpRequest request,
    StreamIterator<List<int>> iter, {
    required String contentType,
    required int? totalLength,
    required int reqStart,
    required int? reqEnd,
    required bool hasRange,
    Uint8List? alreadyReadPrefix,
    List<int>? extraChunk,
  }) async {
    final int? effectiveEnd;
    if (hasRange && totalLength != null) {
      if (totalLength == 0) {
        request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        request.response.headers.set('content-range', 'bytes */0');
        return;
      }
      final candidateEnd = math.min(reqEnd ?? (totalLength - 1), totalLength - 1);
      if (reqStart >= totalLength || candidateEnd < reqStart) {
        request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        request.response.headers.set('content-range', 'bytes */$totalLength');
        return;
      }
      effectiveEnd = candidateEnd;
      request.response.bufferOutput = false;
      request.response.statusCode = HttpStatus.partialContent;
      if (contentType.isNotEmpty) {
        request.response.headers.set(HttpHeaders.contentTypeHeader, contentType);
      }
      request.response.headers.set('accept-ranges', 'bytes');
      request.response.headers.set('cache-control', 'no-store');
      request.response.headers
          .set('content-range', 'bytes $reqStart-$effectiveEnd/$totalLength');
      request.response.contentLength = effectiveEnd - reqStart + 1;
    } else {
      effectiveEnd = null;
      request.response.bufferOutput = false;
      request.response.statusCode = HttpStatus.ok;
      if (contentType.isNotEmpty) {
        request.response.headers.set(HttpHeaders.contentTypeHeader, contentType);
      }
      request.response.headers.set('cache-control', 'no-store');
      if (totalLength != null) {
        request.response.contentLength = totalLength;
      }
    }

    var streamOffset = 0;
    var pendingFlushBytes = 0;
    final effectiveStart = (hasRange && totalLength != null) ? reqStart : 0;

    Future<bool> forwardChunk(List<int> chunk) async {
      if (chunk.isEmpty) return true;
      final chunkStart = streamOffset;
      final chunkEnd = streamOffset + chunk.length - 1;
      streamOffset += chunk.length;
      if (effectiveEnd != null && chunkStart > effectiveEnd) {
        return false;
      }
      if (chunkEnd < effectiveStart) {
        return true;
      }
      final sliceStart = math.max(0, effectiveStart - chunkStart);
      final sliceEnd = effectiveEnd != null
          ? math.min(chunk.length, effectiveEnd - chunkStart + 1)
          : chunk.length;
      if (sliceEnd > sliceStart) {
        final Uint8List outSlice;
        if (sliceStart == 0 && sliceEnd == chunk.length) {
          outSlice = chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
        } else {
          outSlice = Uint8List.sublistView(
            chunk is Uint8List ? chunk : Uint8List.fromList(chunk),
            sliceStart,
            sliceEnd,
          );
        }
        request.response.add(outSlice);
        pendingFlushBytes += outSlice.length;
        if (pendingFlushBytes >= _streamFlushThresholdBytes) {
          pendingFlushBytes = 0;
          await request.response.flush().timeout(const Duration(seconds: 30));
        }
      }
      return effectiveEnd == null || streamOffset <= effectiveEnd;
    }

    if (alreadyReadPrefix != null && alreadyReadPrefix.isNotEmpty) {
      if (!await forwardChunk(alreadyReadPrefix)) return;
    }
    if (extraChunk != null && extraChunk.isNotEmpty) {
      if (!await forwardChunk(extraChunk)) return;
    }
    while (await iter.moveNext().timeout(const Duration(seconds: 30))) {
      if (!await forwardChunk(iter.current)) break;
    }
  }

  Future<void> _cacheFullBodyIntoBlocks(
    String cacheKey,
    Uint8List fullBytes,
    String contentType,
    bool supportsRanges,
    int generation,
  ) async {
    await _saveMeta(
      cacheKey,
      _CachedObjectMeta(
        totalLength: fullBytes.length,
        contentType: contentType,
        supportsRanges: supportsRanges,
      ),
      generation,
    );
    if (_maxBytes <= 0 || fullBytes.length > _maxFullResponseCacheBytes) {
      return;
    }
    for (var offset = 0, blockIndex = 0;
        offset < fullBytes.length;
        offset += blockSize, blockIndex++) {
      final end = math.min(offset + blockSize, fullBytes.length);
      final slice = Uint8List.sublistView(fullBytes, offset, end);
      await _writeCachedBlock(cacheKey, blockIndex, slice, generation);
    }
  }

  Future<Uint8List> _getOrFetchBlock({
    required String cacheKey,
    required int blockIndex,
    required Future<(http.StreamedResponse, Uri)> Function({
      String? range,
      String? ifRange,
      required bool allowRange,
    }) fetchUpstream,
    required Future<void> Function(
      Uint8List bytes,
      String contentType,
      int totalLength,
    ) onFullFallback,
  }) async {
    final flightKey = '$cacheKey#$blockIndex';
    final existing = _inFlightBlocks[flightKey];
    if (existing != null) return existing;

    final generation = _generation;
    final future = () async {
      final cached = await _readCachedBlock(cacheKey, blockIndex);
      if (cached != null) return cached;

      final blockStart = blockIndex * blockSize;
      final meta = await _loadMeta(cacheKey);
      final knownTotal = meta?.totalLength;
      final blockEnd = knownTotal != null
          ? math.min(knownTotal - 1, blockStart + blockSize - 1)
          : blockStart + blockSize - 1;
      if (knownTotal != null && blockStart >= knownTotal) {
        return Uint8List(0);
      }

      var (response, _) = await fetchUpstream(
        range: 'bytes=$blockStart-$blockEnd',
        allowRange: true,
      );

      // 416 Range Not Satisfiable -> auto-retry without Range header!
      if (response.statusCode == HttpStatus.requestedRangeNotSatisfiable) {
        final crTotal = _parseTotalLengthFromContentRange(
          response.headers['content-range'],
        );
        await response.stream.listen((_) {}).cancel();
        if (crTotal != null && blockStart >= crTotal) {
          await _saveMeta(
            cacheKey,
            _CachedObjectMeta(
              totalLength: crTotal,
              contentType: response.headers['content-type'] ??
                  meta?.contentType ??
                  'application/octet-stream',
              supportsRanges: true,
            ),
            generation,
          );
          return Uint8List(0);
        }
        final (retryRes, _) = await fetchUpstream(
          range: null,
          allowRange: false,
        );
        if (retryRes.statusCode < 200 || retryRes.statusCode >= 300) {
          final code = retryRes.statusCode;
          await retryRes.stream.listen((_) {}).cancel();
          throw HttpException('Upstream returned HTTP $code after 416 retry');
        }
        final ct = retryRes.headers['content-type'] ??
            meta?.contentType ??
            'application/octet-stream';
        final retryLen = _parseContentLength(retryRes.headers);
        if (retryLen != null && retryLen > _maxFullResponseCacheBytes) {
          await retryRes.stream.listen((_) {}).cancel();
          _nonCacheablePassthroughKeys.add(cacheKey);
          await _saveMeta(
            cacheKey,
            _CachedObjectMeta(
              totalLength: retryLen,
              contentType: ct,
              supportsRanges: false,
            ),
            generation,
          );
          throw const FormatException('非 Range 响应超出缓存上限，请切换直通流');
        }
        final retryBytes = await _readStreamBytes(
          retryRes.stream,
          maxBytes: _maxFullResponseCacheBytes,
        );
        await _cacheFullBodyIntoBlocks(
          cacheKey,
          retryBytes,
          ct,
          false,
          generation,
        );
        await onFullFallback(retryBytes, ct, retryBytes.length);
        if (blockStart >= retryBytes.length) return Uint8List(0);
        final end = math.min(blockStart + blockSize, retryBytes.length);
        return Uint8List.sublistView(retryBytes, blockStart, end);
      }

      if (response.statusCode == HttpStatus.ok) {
        final ct = response.headers['content-type'] ??
            meta?.contentType ??
            'application/octet-stream';
        final respLen = _parseContentLength(response.headers);
        if (respLen != null && respLen > _maxFullResponseCacheBytes) {
          await response.stream.listen((_) {}).cancel();
          _nonCacheablePassthroughKeys.add(cacheKey);
          await _saveMeta(
            cacheKey,
            _CachedObjectMeta(
              totalLength: respLen,
              contentType: ct,
              supportsRanges: false,
            ),
            generation,
          );
          throw const FormatException('非 Range 响应超出缓存上限，请切换直通流');
        }
        final bytes = await _readStreamBytes(
          response.stream,
          maxBytes: _maxFullResponseCacheBytes,
        );
        await _cacheFullBodyIntoBlocks(
          cacheKey,
          bytes,
          ct,
          false,
          generation,
        );
        await onFullFallback(bytes, ct, bytes.length);
        if (blockStart >= bytes.length) return Uint8List(0);
        final end = math.min(blockStart + blockSize, bytes.length);
        return Uint8List.sublistView(bytes, blockStart, end);
      }

      if (response.statusCode != HttpStatus.partialContent) {
        final code = response.statusCode;
        await response.stream.listen((_) {}).cancel();
        throw HttpException('Upstream returned HTTP $code');
      }

      final ct = response.headers['content-type'] ??
          meta?.contentType ??
          'application/octet-stream';
      final crHeader = response.headers['content-range'];
      final totalFromHeader = _parseTotalLengthFromContentRange(crHeader);
      final blockBytes = await _readStreamBytes(
        response.stream,
        maxBytes: blockSize + 1024,
      );
      final inferredTotal = totalFromHeader ??
          (blockBytes.length < blockSize ? blockStart + blockBytes.length : null);
      if (inferredTotal != null) {
        await _saveMeta(
          cacheKey,
          _CachedObjectMeta(
            totalLength: inferredTotal,
            contentType: ct,
            supportsRanges: true,
          ),
          generation,
        );
      }
      if (blockBytes.isNotEmpty) {
        await _writeCachedBlock(cacheKey, blockIndex, blockBytes, generation);
      }
      return blockBytes;
    }();

    _inFlightBlocks[flightKey] = future;
    try {
      return await future;
    } finally {
      if (identical(_inFlightBlocks[flightKey], future)) {
        _inFlightBlocks.remove(flightKey);
      }
    }
  }

  Future<void> _servePassthrough(
    HttpRequest request, {
    required String cacheKey,
    required ({int? start, int? end, int? suffixLength, bool valid}) parsedRange,
    required String? rangeHeader,
    required _CachedObjectMeta? meta,
    required Future<(http.StreamedResponse, Uri)> Function({
      String? range,
      String? ifRange,
      required bool allowRange,
    }) fetchUpstream,
    required void Function(int statusCode, String host) onUpstreamStatus,
    Future<void> Function(Uri finalTarget, String playlistText)?
        onHlsPlaylistDetected,
    void Function(Uri finalTarget)? onHlsHeadDetected,
  }) async {
    final hasRange = rangeHeader != null && rangeHeader.trim().isNotEmpty;
    final knownNoRange = meta != null && !meta.supportsRanges;
    var (res, finalTarget) = await fetchUpstream(
      range: knownNoRange ? null : rangeHeader,
      ifRange: knownNoRange
          ? null
          : request.headers.value(HttpHeaders.ifRangeHeader),
      allowRange: !knownNoRange,
    );
    onUpstreamStatus(res.statusCode, finalTarget.host);
    if (res.statusCode == HttpStatus.requestedRangeNotSatisfiable &&
        !knownNoRange) {
      await res.stream.listen((_) {}).cancel();
      final (retryRes, retryTarget) = await fetchUpstream(
        range: null,
        allowRange: false,
      );
      onUpstreamStatus(retryRes.statusCode, retryTarget.host);
      res = retryRes;
      finalTarget = retryTarget;
    }

    if (res.statusCode < 200 || res.statusCode >= 300) {
      request.response.statusCode = res.statusCode;
      await res.stream.listen((_) {}).cancel();
      return;
    }

    final isDeclaredHls =
        _isHlsPlaylistResponse(finalTarget, res.headers['content-type']);
    if (request.method == 'HEAD') {
      if (isDeclaredHls && onHlsHeadDetected != null) {
        onHlsHeadDetected(finalTarget);
        request.response.statusCode = HttpStatus.ok;
        request.response.headers
            .set(HttpHeaders.contentTypeHeader, 'application/vnd.apple.mpegurl');
        await res.stream.listen((_) {}).cancel();
        return;
      }
      request.response.statusCode = res.statusCode;
      for (final k in const [
        'content-type',
        'content-length',
        'content-range',
        'accept-ranges',
      ]) {
        final v = res.headers[k];
        if (v != null && v.isNotEmpty) request.response.headers.set(k, v);
      }
      await res.stream.listen((_) {}).cancel();
      return;
    }

    if (isDeclaredHls && onHlsPlaylistDetected != null) {
      final body = await _readStreamBytes(
        res.stream,
        maxBytes: LocalMediaLease._maxPlaylistBytes,
      );
      if (LocalMediaLease._startsWithM3u8Magic(body)) {
        await onHlsPlaylistDetected(
          finalTarget,
          utf8.decode(body, allowMalformed: true),
        );
        return;
      }
      request.response.statusCode = res.statusCode;
      final ct = res.headers['content-type'];
      if (ct != null && ct.isNotEmpty) {
        request.response.headers.set(HttpHeaders.contentTypeHeader, ct);
      }
      request.response.contentLength = body.length;
      request.response.add(body);
      return;
    }

    final iter = StreamIterator<List<int>>(res.stream);
    try {
      Uint8List? prefix;
      if (res.statusCode == HttpStatus.ok &&
          onHlsPlaylistDetected != null &&
          (parsedRange.start ?? 0) == 0 &&
          parsedRange.suffixLength == null) {
        prefix = await _readPrefixFromIterator(iter);
        if (LocalMediaLease._startsWithM3u8Magic(prefix)) {
          final full = await _drainBoundedPlaylistFromIterator(iter, prefix);
          await onHlsPlaylistDetected(
            finalTarget,
            utf8.decode(full, allowMalformed: true),
          );
          return;
        }
      }

      if (res.statusCode == HttpStatus.partialContent) {
        request.response.bufferOutput = false;
        request.response.statusCode = res.statusCode;
        for (final k in const [
          'content-type',
          'content-length',
          'content-range',
          'accept-ranges',
        ]) {
          final v = res.headers[k];
          if (v != null && v.isNotEmpty) request.response.headers.set(k, v);
        }
        if (prefix != null && prefix.isNotEmpty) {
          request.response.add(prefix);
        }
        var pending = 0;
        while (await iter.moveNext().timeout(const Duration(seconds: 30))) {
          final chunk = iter.current;
          request.response.add(chunk);
          pending += chunk.length;
          if (pending >= _streamFlushThresholdBytes) {
            pending = 0;
            await request.response.flush().timeout(const Duration(seconds: 30));
          }
        }
        return;
      }

      final ct = res.headers['content-type'] ??
          meta?.contentType ??
          'application/octet-stream';
      final totalLen = _parseContentLength(res.headers) ??
          ((meta != null && meta.totalLength >= 0) ? meta.totalLength : null);
      int reqStart = 0;
      int? reqEnd;
      if (hasRange && totalLen != null) {
        if (parsedRange.suffixLength != null) {
          reqStart = math.max(0, totalLen - parsedRange.suffixLength!);
          reqEnd = totalLen - 1;
        } else {
          reqStart = parsedRange.start ?? 0;
          reqEnd = parsedRange.end;
        }
      }
      await _streamUpstreamSlice(
        request,
        iter,
        contentType: ct,
        totalLength: totalLen,
        reqStart: reqStart,
        reqEnd: reqEnd,
        hasRange: hasRange,
        alreadyReadPrefix: prefix,
      );
    } finally {
      try {
        await iter.cancel();
      } catch (_) {}
    }
  }

  void _writeSliceResponse(
    HttpRequest request, {
    required Uint8List fullBytes,
    required String contentType,
    required ({int? start, int? end, int? suffixLength, bool valid}) parsedRange,
    required bool hasRange,
  }) {
    final totalLength = fullBytes.length;
    if (totalLength == 0) {
      if (hasRange) {
        request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        request.response.headers.set('content-range', 'bytes */0');
        return;
      }
      request.response.statusCode = HttpStatus.ok;
      request.response.contentLength = 0;
      return;
    }
    int reqStart;
    int reqEnd;
    if (!hasRange) {
      reqStart = 0;
      reqEnd = totalLength - 1;
    } else if (parsedRange.suffixLength != null) {
      reqStart = math.max(0, totalLength - parsedRange.suffixLength!);
      reqEnd = totalLength - 1;
    } else {
      reqStart = parsedRange.start!;
      reqEnd = math.min(parsedRange.end ?? (totalLength - 1), totalLength - 1);
    }
    if (reqStart >= totalLength || reqEnd < reqStart) {
      request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
      request.response.headers.set('content-range', 'bytes */$totalLength');
      return;
    }
    final responseLen = reqEnd - reqStart + 1;
    request.response.bufferOutput = false;
    request.response.statusCode =
        hasRange ? HttpStatus.partialContent : HttpStatus.ok;
    if (contentType.isNotEmpty) {
      request.response.headers.set(HttpHeaders.contentTypeHeader, contentType);
    }
    request.response.headers.set('accept-ranges', 'bytes');
    request.response.headers.set('cache-control', 'no-store');
    if (hasRange) {
      request.response.headers
          .set('content-range', 'bytes $reqStart-$reqEnd/$totalLength');
    }
    request.response.contentLength = responseLen;
    request.response.add(Uint8List.sublistView(fullBytes, reqStart, reqEnd + 1));
  }

  Future<void> serveRequest(
    HttpRequest request, {
    required String cacheKey,
    required Future<(http.StreamedResponse, Uri)> Function({
      String? range,
      String? ifRange,
      required bool allowRange,
    }) fetchUpstream,
    required void Function(int statusCode, String host) onUpstreamStatus,
    Future<void> Function(Uri finalTarget, String playlistText)?
        onHlsPlaylistDetected,
    void Function(Uri finalTarget)? onHlsHeadDetected,
  }) async {
    await ensureInitialized();
    final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
    final parsedRange = _parseRange(rangeHeader);
    if (!parsedRange.valid) {
      request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
      return;
    }
    final hasRange = rangeHeader != null && rangeHeader.trim().isNotEmpty;

    var meta = await _loadMeta(cacheKey);
    if (meta == null && !_nonCacheablePassthroughKeys.contains(cacheKey)) {
      final pendingProbe = _inFlightInitialProbes[cacheKey];
      if (pendingProbe != null) {
        await pendingProbe;
        meta = await _loadMeta(cacheKey);
      }
    }
    final isPassthrough = _maxBytes <= 0 ||
        _nonCacheablePassthroughKeys.contains(cacheKey) ||
        (meta != null &&
            !meta.supportsRanges &&
            (meta.totalLength > _maxFullResponseCacheBytes ||
                meta.totalLength < 0));
    if (isPassthrough) {
      await _servePassthrough(
        request,
        cacheKey: cacheKey,
        parsedRange: parsedRange,
        rangeHeader: rangeHeader,
        meta: meta,
        fetchUpstream: fetchUpstream,
        onUpstreamStatus: onUpstreamStatus,
        onHlsPlaylistDetected: onHlsPlaylistDetected,
        onHlsHeadDetected: onHlsHeadDetected,
      );
      return;
    }

    final prefetchedBlocks = <int, Uint8List>{};

    // Initial probe (meta == null): handle HEAD, HLS playlist bypass, bounded
    // 200 OK / 416 retry streaming without full-RAM buffering, or 206 block 0.
    if (meta == null) {
      if (request.method == 'HEAD') {
        final (res, finalTarget) = await fetchUpstream(
          range: rangeHeader,
          ifRange: request.headers.value(HttpHeaders.ifRangeHeader),
          allowRange: true,
        );
        onUpstreamStatus(res.statusCode, finalTarget.host);
        await res.stream.listen((_) {}).cancel();
        if (_isHlsPlaylistResponse(finalTarget, res.headers['content-type']) &&
            onHlsHeadDetected != null) {
          onHlsHeadDetected(finalTarget);
          request.response.statusCode = HttpStatus.ok;
          request.response.headers.set(
            HttpHeaders.contentTypeHeader,
            'application/vnd.apple.mpegurl',
          );
          return;
        }
        request.response.statusCode = res.statusCode;
        for (final k in const [
          'content-type',
          'content-length',
          'content-range',
          'accept-ranges',
        ]) {
          final v = res.headers[k];
          if (v != null && v.isNotEmpty) request.response.headers.set(k, v);
        }
        return;
      }

      final probeCompleter = Completer<void>();
      _inFlightInitialProbes[cacheKey] = probeCompleter.future;
      void releaseInitialProbe() {
        if (!probeCompleter.isCompleted) {
          probeCompleter.complete();
        }
        if (identical(_inFlightInitialProbes[cacheKey], probeCompleter.future)) {
          _inFlightInitialProbes.remove(cacheKey);
        }
      }

      try {
        final generation = _generation;
        final probeStart = parsedRange.start ?? 0;
        final probeBlockIndex = probeStart ~/ blockSize;
        final probeBlockStart = probeBlockIndex * blockSize;
        final probeBlockEnd = probeBlockStart + blockSize - 1;

        var (res, finalTarget) = await fetchUpstream(
          range: 'bytes=$probeBlockStart-$probeBlockEnd',
          allowRange: true,
        );
        onUpstreamStatus(res.statusCode, finalTarget.host);

        if (res.statusCode == HttpStatus.requestedRangeNotSatisfiable) {
          final crTotal =
              _parseTotalLengthFromContentRange(res.headers['content-range']);
          await res.stream.listen((_) {}).cancel();
          if (crTotal != null && probeBlockStart >= crTotal) {
            meta = _CachedObjectMeta(
              totalLength: crTotal,
              contentType:
                  res.headers['content-type'] ?? 'application/octet-stream',
              supportsRanges: true,
            );
            await _saveMeta(cacheKey, meta, generation);
          } else {
            final (retryRes, retryTarget) = await fetchUpstream(
              range: null,
              allowRange: false,
            );
            onUpstreamStatus(retryRes.statusCode, retryTarget.host);
            res = retryRes;
            finalTarget = retryTarget;
          }
        }

        if (meta == null) {
          if (res.statusCode < 200 || res.statusCode >= 300) {
            request.response.statusCode = res.statusCode;
            await res.stream.listen((_) {}).cancel();
            return;
          }

          final isDeclaredHls =
              _isHlsPlaylistResponse(finalTarget, res.headers['content-type']);
          if (isDeclaredHls && onHlsPlaylistDetected != null) {
            if (res.statusCode == HttpStatus.partialContent) {
              final crTotal = _parseTotalLengthFromContentRange(
                res.headers['content-range'],
              );
              final blockBytes = await _readStreamBytes(
                res.stream,
                maxBytes: blockSize + 1024,
              );
              final isComplete =
                  (crTotal != null && blockBytes.length >= crTotal) ||
                      (crTotal == null && blockBytes.length < blockSize);
              Uint8List playlistBytes;
              Uri playlistTarget = finalTarget;
              if (isComplete && probeBlockIndex == 0) {
                playlistBytes = blockBytes;
              } else {
                final (fullRes, fullTarget) = await fetchUpstream(
                  range: null,
                  allowRange: false,
                );
                onUpstreamStatus(fullRes.statusCode, fullTarget.host);
                playlistTarget = fullTarget;
                playlistBytes = await _readStreamBytes(
                  fullRes.stream,
                  maxBytes: LocalMediaLease._maxPlaylistBytes,
                );
              }
              if (LocalMediaLease._startsWithM3u8Magic(playlistBytes)) {
                releaseInitialProbe();
                await onHlsPlaylistDetected(
                  playlistTarget,
                  utf8.decode(playlistBytes, allowMalformed: true),
                );
                return;
              }
              request.response.statusCode = HttpStatus.ok;
              final ct = res.headers['content-type'];
              if (ct != null && ct.isNotEmpty) {
                request.response.headers.set(HttpHeaders.contentTypeHeader, ct);
              }
              request.response.contentLength = playlistBytes.length;
              request.response.add(playlistBytes);
              return;
            } else {
              final playlistBytes = await _readStreamBytes(
                res.stream,
                maxBytes: LocalMediaLease._maxPlaylistBytes,
              );
              if (LocalMediaLease._startsWithM3u8Magic(playlistBytes)) {
                releaseInitialProbe();
                await onHlsPlaylistDetected(
                  finalTarget,
                  utf8.decode(playlistBytes, allowMalformed: true),
                );
                return;
              }
              request.response.statusCode = res.statusCode;
              final ct = res.headers['content-type'];
              if (ct != null && ct.isNotEmpty) {
                request.response.headers.set(HttpHeaders.contentTypeHeader, ct);
              }
              request.response.contentLength = playlistBytes.length;
              request.response.add(playlistBytes);
              return;
            }
          }

          if (res.statusCode == HttpStatus.ok) {
            final ct = res.headers['content-type'] ?? 'application/octet-stream';
            final contentLen = _parseContentLength(res.headers);
            final iter = StreamIterator<List<int>>(res.stream);
            try {
              Uint8List prefix = Uint8List(0);
              if (onHlsPlaylistDetected != null && probeBlockStart == 0) {
                prefix = await _readPrefixFromIterator(iter);
                if (LocalMediaLease._startsWithM3u8Magic(prefix)) {
                  final fullPlaylist =
                      await _drainBoundedPlaylistFromIterator(iter, prefix);
                  releaseInitialProbe();
                  await onHlsPlaylistDetected(
                    finalTarget,
                    utf8.decode(fullPlaylist, allowMalformed: true),
                  );
                  return;
                }
              }

              if (contentLen != null && contentLen > _maxFullResponseCacheBytes) {
                await _saveMeta(
                  cacheKey,
                  _CachedObjectMeta(
                    totalLength: contentLen,
                    contentType: ct,
                    supportsRanges: false,
                  ),
                  generation,
                );
                releaseInitialProbe();
                int reqStart = 0;
                int? reqEnd;
                if (hasRange) {
                  if (parsedRange.suffixLength != null) {
                    reqStart =
                        math.max(0, contentLen - parsedRange.suffixLength!);
                    reqEnd = contentLen - 1;
                  } else {
                    reqStart = parsedRange.start ?? 0;
                    reqEnd = parsedRange.end;
                  }
                }
                await _streamUpstreamSlice(
                  request,
                  iter,
                  contentType: ct,
                  totalLength: contentLen,
                  reqStart: reqStart,
                  reqEnd: reqEnd,
                  hasRange: hasRange,
                  alreadyReadPrefix: prefix,
                );
                return;
              }

              final builder = BytesBuilder(copy: false);
              if (prefix.isNotEmpty) {
                if (prefix.length > _maxFullResponseCacheBytes) {
                  _nonCacheablePassthroughKeys.add(cacheKey);
                  if (contentLen != null) {
                    await _saveMeta(
                      cacheKey,
                      _CachedObjectMeta(
                        totalLength: contentLen,
                        contentType: ct,
                        supportsRanges: false,
                      ),
                      generation,
                    );
                  }
                  releaseInitialProbe();
                  int reqStart = 0;
                  int? reqEnd;
                  if (hasRange && contentLen != null) {
                    if (parsedRange.suffixLength != null) {
                      reqStart =
                          math.max(0, contentLen - parsedRange.suffixLength!);
                      reqEnd = contentLen - 1;
                    } else {
                      reqStart = parsedRange.start ?? 0;
                      reqEnd = parsedRange.end;
                    }
                  }
                  await _streamUpstreamSlice(
                    request,
                    iter,
                    contentType: ct,
                    totalLength: contentLen,
                    reqStart: reqStart,
                    reqEnd: reqEnd,
                    hasRange: hasRange,
                    alreadyReadPrefix: prefix,
                  );
                  return;
                }
                builder.add(prefix);
              }

              while (
                  await iter.moveNext().timeout(const Duration(seconds: 30))) {
                final chunk = iter.current;
                if (builder.length + chunk.length > _maxFullResponseCacheBytes) {
                  _nonCacheablePassthroughKeys.add(cacheKey);
                  if (contentLen != null) {
                    await _saveMeta(
                      cacheKey,
                      _CachedObjectMeta(
                        totalLength: contentLen,
                        contentType: ct,
                        supportsRanges: false,
                      ),
                      generation,
                    );
                  }
                  releaseInitialProbe();
                  int reqStart = 0;
                  int? reqEnd;
                  if (hasRange && contentLen != null) {
                    if (parsedRange.suffixLength != null) {
                      reqStart =
                          math.max(0, contentLen - parsedRange.suffixLength!);
                      reqEnd = contentLen - 1;
                    } else {
                      reqStart = parsedRange.start ?? 0;
                      reqEnd = parsedRange.end;
                    }
                  }
                  await _streamUpstreamSlice(
                    request,
                    iter,
                    contentType: ct,
                    totalLength: contentLen,
                    reqStart: reqStart,
                    reqEnd: reqEnd,
                    hasRange: hasRange,
                    alreadyReadPrefix: builder.takeBytes(),
                    extraChunk: chunk,
                  );
                  return;
                }
                builder.add(chunk);
              }

              final fullBytes = builder.takeBytes();
              await _cacheFullBodyIntoBlocks(
                cacheKey,
                fullBytes,
                ct,
                false,
                generation,
              );
              releaseInitialProbe();
              _writeSliceResponse(
                request,
                fullBytes: fullBytes,
                contentType: ct,
                parsedRange: parsedRange,
                hasRange: hasRange,
              );
              return;
            } finally {
              try {
                await iter.cancel();
              } catch (_) {}
            }
          }

          if (res.statusCode != HttpStatus.partialContent) {
            request.response.statusCode = res.statusCode;
            await res.stream.listen((_) {}).cancel();
            return;
          }

          final ct = res.headers['content-type'] ?? 'application/octet-stream';
          final crHeader = res.headers['content-range'];
          final totalFromHeader = _parseTotalLengthFromContentRange(crHeader);
          final blockBytes = await _readStreamBytes(
            res.stream,
            maxBytes: blockSize + 1024,
          );
          if (probeBlockIndex == 0 &&
              onHlsPlaylistDetected != null &&
              LocalMediaLease._startsWithM3u8Magic(blockBytes)) {
            final isComplete =
                (totalFromHeader != null &&
                        blockBytes.length >= totalFromHeader) ||
                    (totalFromHeader == null && blockBytes.length < blockSize);
            Uint8List playlistBytes;
            Uri playlistTarget = finalTarget;
            if (isComplete) {
              playlistBytes = blockBytes;
            } else {
              final (fullRes, fullTarget) = await fetchUpstream(
                range: null,
                allowRange: false,
              );
              onUpstreamStatus(fullRes.statusCode, fullTarget.host);
              playlistTarget = fullTarget;
              playlistBytes = await _readStreamBytes(
                fullRes.stream,
                maxBytes: LocalMediaLease._maxPlaylistBytes,
              );
            }
            releaseInitialProbe();
            await onHlsPlaylistDetected(
              playlistTarget,
              utf8.decode(playlistBytes, allowMalformed: true),
            );
            return;
          }

          final inferredTotal = totalFromHeader ??
              (blockBytes.length < blockSize
                  ? probeBlockStart + blockBytes.length
                  : null);
          if (blockBytes.isNotEmpty) {
            await _writeCachedBlock(
                cacheKey, probeBlockIndex, blockBytes, generation);
            prefetchedBlocks[probeBlockIndex] = blockBytes;
          }
          if (inferredTotal != null) {
            meta = _CachedObjectMeta(
              totalLength: inferredTotal,
              contentType: ct,
              supportsRanges: true,
            );
            await _saveMeta(cacheKey, meta, generation);
          }
        }
      } finally {
        releaseInitialProbe();
      }
    }

    if (meta == null) {
      // Unknown total length: fall back to direct upstream passthrough.
      await _servePassthrough(
        request,
        cacheKey: cacheKey,
        parsedRange: parsedRange,
        rangeHeader: rangeHeader,
        meta: null,
        fetchUpstream: fetchUpstream,
        onUpstreamStatus: onUpstreamStatus,
        onHlsPlaylistDetected: onHlsPlaylistDetected,
        onHlsHeadDetected: onHlsHeadDetected,
      );
      return;
    }

    final totalLength = meta.totalLength;
    if (totalLength == 0) {
      if (rangeHeader != null) {
        request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        request.response.headers.set('content-range', 'bytes */0');
        return;
      }
      request.response.statusCode = HttpStatus.ok;
      request.response.contentLength = 0;
      return;
    }

    int reqStart;
    int reqEnd;
    if (!hasRange) {
      reqStart = 0;
      reqEnd = totalLength - 1;
    } else if (parsedRange.suffixLength != null) {
      final suffix = parsedRange.suffixLength!;
      reqStart = math.max(0, totalLength - suffix);
      reqEnd = totalLength - 1;
    } else {
      reqStart = parsedRange.start!;
      reqEnd = math.min(parsedRange.end ?? (totalLength - 1), totalLength - 1);
    }

    if (reqStart >= totalLength || reqEnd < reqStart) {
      request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
      request.response.headers.set('content-range', 'bytes */$totalLength');
      return;
    }

    final responseLen = reqEnd - reqStart + 1;
    request.response.bufferOutput = false;
    request.response.statusCode =
        hasRange ? HttpStatus.partialContent : HttpStatus.ok;
    if (meta.contentType.isNotEmpty) {
      request.response.headers
          .set(HttpHeaders.contentTypeHeader, meta.contentType);
    }
    request.response.headers.set('accept-ranges', 'bytes');
    request.response.headers.set('cache-control', 'no-store');
    if (hasRange) {
      request.response.headers
          .set('content-range', 'bytes $reqStart-$reqEnd/$totalLength');
    }
    request.response.contentLength = responseLen;

    if (request.method == 'HEAD') {
      return;
    }

    final firstBlock = reqStart ~/ blockSize;
    final lastBlock = reqEnd ~/ blockSize;
    Uint8List? preFetchedFullBody;
    for (var b = firstBlock; b <= lastBlock; b++) {
      final Uint8List blockData;
      if (preFetchedFullBody != null) {
        final bStart = b * blockSize;
        if (bStart >= preFetchedFullBody!.length) {
          blockData = Uint8List(0);
        } else {
          final bEnd = math.min(bStart + blockSize, preFetchedFullBody!.length);
          blockData = Uint8List.sublistView(preFetchedFullBody!, bStart, bEnd);
        }
      } else if (prefetchedBlocks.containsKey(b)) {
        blockData = prefetchedBlocks[b]!;
      } else {
        blockData = await _getOrFetchBlock(
          cacheKey: cacheKey,
          blockIndex: b,
          fetchUpstream: ({range, ifRange, required allowRange}) async {
            final result = await fetchUpstream(
              range: range,
              ifRange: ifRange,
              allowRange: allowRange,
            );
            onUpstreamStatus(result.$1.statusCode, result.$2.host);
            return result;
          },
          onFullFallback: (bytes, ct, total) async {
            preFetchedFullBody = bytes;
          },
        );
      }
      final blockBase = b * blockSize;
      final sliceStart = math.max(0, reqStart - blockBase);
      final sliceEnd = math.min(blockData.length, reqEnd - blockBase + 1);
      if (sliceEnd > sliceStart) {
        request.response.add(
          Uint8List.sublistView(blockData, sliceStart, sliceEnd),
        );
      }
    }
  }
}

class _CachedBlockEntry {
  _CachedBlockEntry({
    required this.id,
    required this.file,
    required this.size,
    required this.accessSeq,
  });
  final String id;
  final File file;
  final int size;
  int accessSeq;
}

class _CachedObjectMeta {
  const _CachedObjectMeta({
    required this.totalLength,
    required this.contentType,
    required this.supportsRanges,
  });
  final int totalLength;
  final String contentType;
  final bool supportsRanges;
}

class _HlsSegmentEntry {
  const _HlsSegmentEntry({
    required this.duration,
    required this.tagLines,
    required this.uriLine,
    required this.resolvedUri,
    this.keyTag,
  });
  final double duration;
  final List<String> tagLines;
  final String uriLine;
  final Uri resolvedUri;
  final String? keyTag;
}

class _HlsBlock {
  _HlsBlock({required this.hasPrecedingDiscontinuity});
  final bool hasPrecedingDiscontinuity;
  final List<_HlsSegmentEntry> segments = <_HlsSegmentEntry>[];
}

/// Session-scoped loopback media gateway (`http://127.0.0.1:<port>/<capability>/...`).
///
/// Handles anti-leech `Referer`/`User-Agent`/`Origin`, dynamic `Set-Cookie` jars,
/// cross-domain CDN redirects with strict credential-origin boundaries, extensionless
/// HLS `.m3u8` manifest rewriting, HLS VOD discontinuity ad removal, `DiskBlockCache`
/// (`/kcache/<sid>`), and fake PNG/JPG/GIF header stripping on MPEG-TS segments so
/// `libmpv` / `AVPlayer` receives a clean local stream.
class LocalMediaLease {
  static bool defaultHlsAdStripEnabled = true;

  LocalMediaLease._(
    this._server,
    this._client,
    this._ownsClient,
    Uri initialTarget,
    this._headers,
    this._isCancelled,
    this._capability,
    this._clock,
    this._isLive,
    this._removeHlsAds,
    this._adHosts,
    this._enableDiskCache,
    this._diskCache,
    String? diskCacheKey,
  )   : _initialOrigin = _originOf(initialTarget),
        _created = _clock() {
    final initialKind = _inferInitialKind(initialTarget);
    if (_enableDiskCache &&
        !_isLive &&
        initialKind != _TargetKind.playlist) {
      _initialUrl = _registerDiskCached(
        initialTarget,
        cacheKey: diskCacheKey,
        diskCache: _diskCache,
      );
    } else {
      _initialUrl = _register(initialTarget, initialKind);
    }
    _server.listen(_serve);
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _sweep());
  }

  static const int _maxConcurrentRequests = 24;
  static const int _flushThresholdBytes = 4 * 1024 * 1024;
  static const int _liveFlushThresholdBytes = 64 * 1024;
  static const int _maxPlaylistBytes = 4 * 1024 * 1024;
  static const int _sniffPrefixBytes = 4096;
  static const String _defaultBrowserUa =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

  static const Set<String> _originBoundHeaderNames = {
    'authorization',
    'proxy-authorization',
    'cookie',
    'cookie2',
    'x-api-key',
    'x-emby-token',
    'x-plex-token',
  };

  static const Set<String> _hopByHopHeaderNames = {
    'host',
    'connection',
    'keep-alive',
    'proxy-connection',
    'transfer-encoding',
    'te',
    'trailer',
    'upgrade',
    'content-length',
  };

  final HttpServer _server;
  final http.Client _client;
  final bool _ownsClient;
  final Uri _initialOrigin;
  final Map<String, String> _headers;
  final bool Function() _isCancelled;
  final String _capability;
  final DateTime Function() _clock;
  final bool _isLive;
  final bool _removeHlsAds;
  final List<String> _adHosts;
  final bool _enableDiskCache;
  final DiskBlockCache _diskCache;
  final DateTime _created;
  final _cookieJar = _SessionCookieJar();
  final _targets = <String, _RegisteredTarget>{};
  final _paths = <String, String>{};
  final _requests = <HttpRequest>{};
  final _upstreams = <StreamSubscription<List<int>>>{};
  late final Uri _initialUrl;
  http.Client? _directOnlyClient;
  Timer? _timer;
  bool _closed = false;
  int? _lastUpstreamStatusCode;
  String? _lastUpstreamHost;
  Object? _lastUpstreamError;
  int _removedHlsAdSegments = 0;
  double _removedHlsAdDurationSec = 0.0;

  Uri get url => _initialUrl;
  bool get isClosed => _closed;
  int? get lastUpstreamStatusCode => _lastUpstreamStatusCode;
  String? get lastUpstreamHost => _lastUpstreamHost;
  Object? get lastUpstreamError => _lastUpstreamError;
  int get removedHlsAdSegments => _removedHlsAdSegments;
  double get removedHlsAdDurationSec => _removedHlsAdDurationSec;
  DiskBlockCache get diskCache => _diskCache;

  /// Registers a companion stream (e.g. separate DASH `.m4s` audio track) onto
  /// this session's loopback gateway so it receives the same anti-leech headers.
  Uri? tryRegisterCompanionMedia(String rawUrl) {
    final trimmed = rawUrl.trim();
    if (trimmed.isEmpty) return null;
    final parsed = Uri.tryParse(trimmed);
    if (parsed == null || !shouldProxy(parsed) || !_canRegisterTarget(parsed)) {
      return null;
    }
    try {
      final kind = _inferInitialKind(parsed);
      if (_enableDiskCache && !_isLive && kind != _TargetKind.playlist) {
        return _registerDiskCached(parsed);
      }
      return _register(parsed, kind);
    } catch (_) {
      return null;
    }
  }

  static bool isLoopbackHost(String host) {
    final bare = host.trim().toLowerCase();
    if (bare.isEmpty) return false;
    return bare == '127.0.0.1' ||
        bare == 'localhost' ||
        bare == '::1' ||
        bare == '[::1]' ||
        bare.startsWith('127.');
  }

  static bool shouldProxy(Uri? uri) =>
      uri != null &&
      (uri.scheme == 'http' || uri.scheme == 'https') &&
      uri.host.isNotEmpty &&
      uri.userInfo.isEmpty &&
      !isLoopbackHost(uri.host);

  static bool isPrivateOrReservedTarget(Uri uri) {
    final host = uri.host.trim().toLowerCase();
    if (host.isEmpty) return true;
    if (isLoopbackHost(host) || host.endsWith('.localhost')) return true;
    final cleanHost = host.startsWith('[') && host.endsWith(']')
        ? host.substring(1, host.length - 1)
        : host;
    final ip = InternetAddress.tryParse(cleanHost);
    if (ip == null) return false;
    if (ip.isLoopback || ip.isLinkLocal || ip.isMulticast) return true;
    final raw = ip.rawAddress;
    if (ip.type == InternetAddressType.IPv4 && raw.length == 4) {
      final a = raw[0], b = raw[1];
      if (a == 0 || a == 10 || a == 127) return true;
      if (a == 169 && b == 254) return true;
      if (a == 172 && b >= 16 && b <= 31) return true;
      if (a == 192 && b == 168) return true;
      if (a == 100 && b >= 64 && b <= 127) return true;
      return false;
    }
    if (ip.type == InternetAddressType.IPv6 && raw.length == 16) {
      final allZero = raw.every((b) => b == 0);
      if (allZero) return true;
      // Unique local fc00::/7
      if ((raw[0] & 0xFE) == 0xFC) return true;
      // IPv4-mapped ::ffff:a.b.c.d
      final v4Mapped = raw.take(10).every((b) => b == 0) &&
          raw[10] == 0xFF &&
          raw[11] == 0xFF;
      if (v4Mapped) {
        final v4 = '${raw[12]}.${raw[13]}.${raw[14]}.${raw[15]}';
        return isPrivateOrReservedTarget(Uri(scheme: 'http', host: v4));
      }
    }
    return false;
  }

  /// Detects a fake image/padding prefix (e.g. PNG/JPG/GIF/BMP header) prepended
  /// before an unencrypted 188-byte MPEG-TS packet stream and returns its byte offset.
  /// Returns `0` when the buffer is already standard media or no TS sync lock exists.
  static int findDisguisedTsOffset(Uint8List prefix) {
    if (prefix.length < 189 || prefix[0] == 0x47) return 0;
    // Standard elementary / container signatures that must never be stripped:
    // ID3 (packed audio HLS), #EXTM3U, WEBVTT, FLV, EBML (MKV/WebM), MP4/fMP4 boxes.
    if (prefix.length >= 3 &&
        prefix[0] == 0x49 &&
        prefix[1] == 0x44 &&
        prefix[2] == 0x33) {
      return 0;
    }
    if (prefix.length >= 7) {
      var s = 0;
      if (prefix[0] == 0xEF && prefix[1] == 0xBB && prefix[2] == 0xBF) s = 3;
      while (s < prefix.length &&
          (prefix[s] == 0x20 ||
              prefix[s] == 0x09 ||
              prefix[s] == 0x0D ||
              prefix[s] == 0x0A)) {
        s++;
      }
      if (s + 7 <= prefix.length &&
          latin1.decode(prefix.sublist(s, s + 7)) == '#EXTM3U') {
        return 0;
      }
      if (s + 6 <= prefix.length &&
          latin1.decode(prefix.sublist(s, s + 6)) == 'WEBVTT') {
        return 0;
      }
    }
    if (prefix.length >= 4 &&
        ((prefix[0] == 0x46 && prefix[1] == 0x4C && prefix[2] == 0x56) ||
            (prefix[0] == 0x1A &&
                prefix[1] == 0x45 &&
                prefix[2] == 0xDF &&
                prefix[3] == 0xA3))) {
      return 0;
    }
    if (prefix.length >= 8) {
      final box = latin1.decode(prefix.sublist(4, 8));
      if (const {'ftyp', 'styp', 'moof', 'moov', 'mdat', 'sidx', 'free', 'wide'}
          .contains(box)) {
        return 0;
      }
    }

    final maxOffset = math.min(prefix.length - 189, 3072);
    for (var i = 1; i <= maxOffset; i++) {
      if (prefix[i] != 0x47) continue;
      if (prefix.length >= i + 377) {
        if (prefix[i + 188] == 0x47 && prefix[i + 376] == 0x47) {
          return i;
        }
      } else if (prefix[i + 188] == 0x47) {
        return i;
      }
    }
    return 0;
  }

  static Future<LocalMediaLease> open({
    required Uri target,
    Map<String, String> headers = const {},
    required bool Function() isCancelled,
    DateTime Function()? clock,
    http.Client? client,
    bool isLive = false,
    bool? removeHlsAds,
    bool? stripHlsAds,
    List<String> adHosts = const [],
    List<String> adPatterns = const [],
    bool enableDiskCache = false,
    DiskBlockCache? diskCache,
    String? diskCacheKey,
  }) async {
    if (!shouldProxy(target)) {
      throw const FormatException('本地媒体代理仅接受远程 HTTP/HTTPS 流地址');
    }
    final sanitized = <String, String>{};
    for (final entry in headers.entries) {
      final key = entry.key.trim();
      final value = entry.value.trim();
      if (key.isEmpty ||
          key.contains('\r') ||
          key.contains('\n') ||
          value.contains('\r') ||
          value.contains('\n')) {
        continue;
      }
      if (_hopByHopHeaderNames.contains(key.toLowerCase())) continue;
      sanitized[key] = value;
    }
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0)
      ..autoCompress = false;
    final random = math.Random.secure();
    final capability = List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final ownsClient = client == null;
    final transport =
        client ?? _createDirectFallbackHttpClient(isLive: isLive);
    final effectiveRemoveHlsAds =
        stripHlsAds ?? removeHlsAds ?? defaultHlsAdStripEnabled;
    final mergedAdHosts = adPatterns.isEmpty
        ? adHosts
        : <String>[...adHosts, ...adPatterns];
    return LocalMediaLease._(
      server,
      transport,
      ownsClient,
      target,
      sanitized,
      isCancelled,
      capability,
      clock ?? DateTime.now,
      isLive,
      effectiveRemoveHlsAds,
      List<String>.unmodifiable(mergedAdHosts),
      enableDiskCache,
      diskCache ?? DiskBlockCache.shared,
      diskCacheKey,
    );
  }

  static http.Client _createDirectFallbackHttpClient({
    bool directOnly = false,
    bool isLive = false,
  }) {
    final io = HttpClient()
      ..autoUncompress = true
      ..maxConnectionsPerHost = 12
      ..connectionTimeout = Duration(seconds: isLive ? 8 : 15)
      ..idleTimeout = const Duration(seconds: 30);
    if (isLive) {
      // Many public IPTV HTTPS edges use self-signed or incomplete cert chains.
      io.badCertificateCallback = (_, __, ___) => true;
    }
    if (directOnly) {
      io.findProxy = (_) => 'DIRECT';
    }
    return IOClient(io);
  }

  static bool _isDeadLocalProxyError(Uri targetUri, Object error) {
    if (isLoopbackHost(targetUri.host)) return false;
    if (error is SocketException) {
      final host = error.address?.host ?? '';
      if (error.address?.isLoopback == true || isLoopbackHost(host)) {
        return true;
      }
    }
    if (error is http.ClientException || error is SocketException) {
      final msg = error.toString();
      final hitsLoopback = msg.contains('address = 127.0.0.1') ||
          msg.contains('address = ::1') ||
          msg.contains('address = localhost');
      final refused = msg.contains('Connection refused') ||
          msg.contains('errno = 61') ||
          msg.contains('errno = 111') ||
          msg.contains('errno = 10061');
      return hitsLoopback && refused;
    }
    return false;
  }

  static Uri _originOf(Uri uri) => Uri(
        scheme: uri.scheme.toLowerCase(),
        host: uri.host.toLowerCase(),
        port: uri.hasPort ? uri.port : (uri.scheme.toLowerCase() == 'https' ? 443 : 80),
      );

  static bool _sameOrigin(Uri a, Uri b) =>
      _originOf(a).scheme == _originOf(b).scheme &&
      _originOf(a).host == _originOf(b).host &&
      _originOf(a).port == _originOf(b).port;

  static _TargetKind _inferInitialKind(Uri uri) {
    final lower = '${uri.path}?${uri.query}'.toLowerCase();
    if (lower.contains('.m3u8')) return _TargetKind.playlist;
    return _TargetKind.auto;
  }

  bool _canRegisterTarget(Uri uri) {
    if (uri.scheme != 'http' && uri.scheme != 'https') return false;
    if (uri.host.isEmpty || uri.userInfo.isNotEmpty) return false;
    if (_sameOrigin(uri, _initialOrigin)) return true;
    if (isPrivateOrReservedTarget(uri)) return false;
    return uri.host.contains('.') || InternetAddress.tryParse(uri.host) != null;
  }

  Uri registerDiskCacheStream(
    Uri target, {
    String? cacheKey,
    DiskBlockCache? diskCache,
  }) =>
      _registerDiskCached(target, cacheKey: cacheKey, diskCache: diskCache);

  Uri _registerDiskCached(
    Uri target, {
    String? cacheKey,
    DiskBlockCache? diskCache,
  }) {
    if (_closed || !_canRegisterTarget(target)) {
      throw const FormatException('媒体分片或重定向目标不受信任');
    }
    final resolvedCacheKey = (cacheKey != null && cacheKey.trim().isNotEmpty)
        ? DiskBlockCache.cacheKeyForString(cacheKey.trim())
        : DiskBlockCache.cacheKeyForUri(target);
    final key = '${_TargetKind.diskCached.name}|$resolvedCacheKey|$target';
    final path = _paths.putIfAbsent(key, () {
      final sid = _targets.isEmpty
          ? _capability
          : '${_capability}_${_targets.length}';
      final p = '/kcache/$sid';
      _targets[p] = _RegisteredTarget(
        target,
        _TargetKind.diskCached,
        cacheKey: resolvedCacheKey,
        diskCache: diskCache,
      );
      return p;
    });
    return Uri.parse('http://127.0.0.1:${_server.port}$path');
  }

  Uri _register(Uri target, _TargetKind kind) {
    if (_closed || !_canRegisterTarget(target)) {
      throw const FormatException('媒体分片或重定向目标不受信任');
    }
    if (_isLive && _targets.length >= 512) {
      final keepPath = _targets.isNotEmpty ? _targets.keys.first : '';
      final removableKeys = _paths.keys
          .where((k) => _paths[k] != keepPath)
          .take(128)
          .toList(growable: false);
      for (final oldKey in removableKeys) {
        final oldPath = _paths.remove(oldKey);
        if (oldPath != null) _targets.remove(oldPath);
      }
    }
    if (_targets.length >= 65536) {
      throw const FormatException('媒体分片或重定向目标不受信任');
    }
    final key = '${kind.name}|$target';
    final path = _paths.putIfAbsent(key, () {
      String suffix;
      if (_targets.isEmpty) {
        final lowerPath = target.path.toLowerCase();
        if (lowerPath.endsWith('.m3u8') || kind == _TargetKind.playlist) {
          suffix = 'stream.m3u8';
        } else if (lowerPath.endsWith('.mp4')) {
          suffix = 'stream.mp4';
        } else if (lowerPath.endsWith('.mkv')) {
          suffix = 'stream.mkv';
        } else if (lowerPath.endsWith('.flv')) {
          suffix = 'stream.flv';
        } else {
          suffix = 'stream';
        }
      } else {
        String ext;
        if (kind == _TargetKind.playlist) {
          ext = '.m3u8';
        } else if (kind == _TargetKind.tsSegment) {
          ext = '.ts';
        } else {
          final lowerPath = target.path.toLowerCase();
          const safeExts = [
            '.m4s',
            '.mp4',
            '.ts',
            '.key',
            '.aac',
            '.vtt',
            '.mkv',
            '.flv',
          ];
          ext = safeExts.firstWhere(
            (candidate) => lowerPath.endsWith(candidate),
            orElse: () => '',
          );
        }
        suffix = 'part-${_targets.length}$ext';
      }
      final p = '/$_capability/$suffix';
      _targets[p] = _RegisteredTarget(target, kind);
      return p;
    });
    return Uri.parse('http://127.0.0.1:${_server.port}$path');
  }

  Future<void> _sweep() async {
    if (_closed) return;
    if (_isCancelled() ||
        _clock().difference(_created) > const Duration(hours: 12)) {
      await close();
    }
  }

  bool _isAllowedLocalRequest(HttpRequest request) {
    final hostHeader = request.headers.value(HttpHeaders.hostHeader);
    if (hostHeader != null && hostHeader.isNotEmpty) {
      final hostOnly = hostHeader.startsWith('[')
          ? hostHeader.substring(0, hostHeader.indexOf(']') + 1)
          : hostHeader.split(':').first;
      if (!isLoopbackHost(hostOnly)) return false;
    }
    final origin = request.headers.value('origin');
    if (origin != null && origin.isNotEmpty) return false;
    final secFetch = request.headers.value('sec-fetch-site')?.trim().toLowerCase();
    if (secFetch != null &&
        secFetch.isNotEmpty &&
        secFetch != 'none' &&
        secFetch != 'same-origin') {
      return false;
    }
    return true;
  }

  Map<String, String> _providerScopedRedirectCookies(Uri target) {
    final rawCookie = _headers.entries
        .firstWhere(
          (e) => e.key.toLowerCase() == 'cookie',
          orElse: () => const MapEntry('', ''),
        )
        .value;
    if (rawCookie.isEmpty) return const {};
    Set<String>? allowedKeys;
    if (CloudMediaLease.isTrustedQuarkMedia(target)) {
      allowedKeys = const {'__pus', '__puus'};
    } else if (CloudMediaLease.isTrustedUcMedia(target)) {
      allowedKeys = const {'__pus', '__puus', '__pugs'};
    }
    if (allowedKeys == null) return const {};
    final scoped = <String, String>{};
    for (final pair in rawCookie.split(';')) {
      final trimmed = pair.trim();
      final eq = trimmed.indexOf('=');
      if (eq <= 0) continue;
      final name = trimmed.substring(0, eq).trim();
      final value = trimmed.substring(eq + 1).trim();
      if (allowedKeys.contains(name) && value.isNotEmpty) {
        scoped[name] = value;
      }
    }
    return scoped;
  }

  Map<String, String> _buildUpstreamHeaders(
    Uri target, {
    String? range,
    String? ifRange,
    required bool allowRange,
  }) {
    final sameOrigin = _sameOrigin(target, _initialOrigin);
    final out = <String, String>{};
    var hasUa = false;
    String? initialCookie;

    for (final entry in _headers.entries) {
      final lower = entry.key.toLowerCase();
      if (_hopByHopHeaderNames.contains(lower)) continue;
      if (!sameOrigin && _originBoundHeaderNames.contains(lower)) continue;
      if (lower == 'user-agent') hasUa = true;
      if (lower == 'cookie') {
        initialCookie = entry.value;
        continue;
      }
      out[entry.key] = entry.value;
    }
    if (!hasUa) {
      out['User-Agent'] = _defaultBrowserUa;
    }

    final mergedCookies = <String, String>{};
    if (initialCookie != null && initialCookie.isNotEmpty) {
      for (final pair in initialCookie.split(';')) {
        final trimmed = pair.trim();
        final eq = trimmed.indexOf('=');
        if (eq > 0) {
          mergedCookies[trimmed.substring(0, eq).trim()] =
              trimmed.substring(eq + 1).trim();
        }
      }
    } else if (!sameOrigin) {
      // Cloud media CDN redirects (e.g. Quark *.quark.cn edge redirect or a
      // T4/Gateway proxy 302 to *.quark.cn) require the provider's own session
      // cookie without leaking unrelated portal cookies or Authorization.
      mergedCookies.addAll(_providerScopedRedirectCookies(target));
    }
    mergedCookies.addAll(_cookieJar.matchingCookies(target, _clock()));
    if (mergedCookies.isNotEmpty) {
      out['Cookie'] =
          mergedCookies.entries.map((e) => '${e.key}=${e.value}').join('; ');
    }

    if (allowRange && range != null && range.isNotEmpty) {
      out['Accept-Encoding'] = 'identity';
      out['Range'] = range;
      if (ifRange != null && ifRange.isNotEmpty) {
        out['If-Range'] = ifRange;
      }
    }
    return out;
  }

  Future<(http.StreamedResponse, Uri)> _sendWithRedirects(
    Uri initialTarget, {
    required String method,
    String? range,
    String? ifRange,
    required bool allowRange,
  }) async {
    var current = initialTarget;
    for (var redirects = 0;; redirects++) {
      http.Request makeReq() => http.Request(method, current)
        ..followRedirects = false
        ..headers.addAll(_buildUpstreamHeaders(
          current,
          range: range,
          ifRange: ifRange,
          allowRange: allowRange,
        ));
      final requestTimeout = Duration(seconds: _isLive ? 15 : 25);
      http.StreamedResponse response;
      try {
        final activeTransport = _directOnlyClient ?? _client;
        response = await activeTransport
            .send(makeReq())
            .timeout(requestTimeout);
      } catch (error) {
        if (_ownsClient &&
            _directOnlyClient == null &&
            !_closed &&
            !_isCancelled() &&
            _isDeadLocalProxyError(current, error)) {
          _directOnlyClient = _createDirectFallbackHttpClient(
            directOnly: true,
            isLive: _isLive,
          );
          response = await _directOnlyClient!
              .send(makeReq())
              .timeout(requestTimeout);
        } else {
          rethrow;
        }
      }
      if (_closed || _isCancelled()) {
        await response.stream.listen((_) {}).cancel();
        throw StateError('cancelled');
      }
      _cookieJar.storeFromHeaders(response.headers, current, _clock());

      if (!const [301, 302, 303, 307, 308].contains(response.statusCode)) {
        return (response, current);
      }
      await response.stream.listen((_) {}).cancel();
      final location = response.headers['location'];
      if (location == null || location.trim().isEmpty || redirects >= 10) {
        throw const FormatException('媒体重定向次数过多或地址缺失');
      }
      final next = current.resolve(location.trim()).removeFragment();
      if (!_canRegisterTarget(next)) {
        throw const FormatException('媒体重定向目标不受信任');
      }
      current = next;
    }
  }

  static bool _startsWithM3u8Magic(List<int> bytes) {
    var i = 0;
    if (bytes.length >= 3 &&
        bytes[0] == 0xEF &&
        bytes[1] == 0xBB &&
        bytes[2] == 0xBF) {
      i = 3;
    }
    while (i < bytes.length &&
        (bytes[i] == 0x20 ||
            bytes[i] == 0x09 ||
            bytes[i] == 0x0D ||
            bytes[i] == 0x0A)) {
      i++;
    }
    if (bytes.length - i < 7) return false;
    return latin1.decode(bytes.sublist(i, i + 7)) == '#EXTM3U';
  }

  static bool _couldBeM3u8Prefix(List<int> bytes) {
    var i = 0;
    if (bytes.length >= 3 &&
        bytes[0] == 0xEF &&
        bytes[1] == 0xBB &&
        bytes[2] == 0xBF) {
      i = 3;
    }
    while (i < bytes.length &&
        (bytes[i] == 0x20 ||
            bytes[i] == 0x09 ||
            bytes[i] == 0x0D ||
            bytes[i] == 0x0A)) {
      i++;
    }
    if (i >= bytes.length) return true;
    const magic = <int>[0x23, 0x45, 0x58, 0x54, 0x4D, 0x33, 0x55]; // #EXTM3U
    final remaining = bytes.length - i;
    final checkLen = remaining < magic.length ? remaining : magic.length;
    for (var j = 0; j < checkLen; j++) {
      if (bytes[i + j] != magic[j]) return false;
    }
    return true;
  }

  static bool _hasNonZeroRangeStart(String? range) {
    if (range == null || range.isEmpty) return false;
    final match = RegExp(r'^bytes=(\d+)-').firstMatch(range.trim());
    if (match == null) return true;
    return (int.tryParse(match.group(1)!) ?? 0) > 0;
  }

  Future<void> _serve(HttpRequest request) async {
    if (_closed || _isCancelled()) {
      request.response.statusCode = HttpStatus.gone;
      await request.response.close();
      return;
    }
    if (!_isAllowedLocalRequest(request)) {
      request.response.statusCode = HttpStatus.forbidden;
      await request.response.close();
      return;
    }
    final registered = _targets[request.uri.path];
    if (registered == null) {
      request.response.statusCode = HttpStatus.forbidden;
      await request.response.close();
      return;
    }
    if (request.method != 'GET' && request.method != 'HEAD') {
      request.response.statusCode = HttpStatus.methodNotAllowed;
      await request.response.close();
      return;
    }
    if (_requests.length >= _maxConcurrentRequests) {
      request.response.statusCode = HttpStatus.serviceUnavailable;
      await request.response.close();
      return;
    }

    _requests.add(request);
    try {
      if (registered.kind == _TargetKind.diskCached) {
        final effectiveCache = registered.diskCache ?? _diskCache;
        await effectiveCache.serveRequest(
          request,
          cacheKey: registered.cacheKey ?? DiskBlockCache.cacheKeyForUri(registered.uri),
          fetchUpstream: ({range, ifRange, required allowRange}) =>
              _sendWithRedirects(
            registered.uri,
            method: request.method == 'HEAD' ? 'HEAD' : 'GET',
            range: range,
            ifRange: ifRange,
            allowRange: allowRange,
          ),
          onUpstreamStatus: (status, host) {
            _lastUpstreamStatusCode = status;
            _lastUpstreamHost = host;
            if (status >= 200 && status < 300) {
              _lastUpstreamError = null;
            }
          },
          onHlsHeadDetected: (finalTarget) {
            _targets[request.uri.path] =
                _RegisteredTarget(finalTarget, _TargetKind.playlist);
          },
          onHlsPlaylistDetected: (finalTarget, playlistText) async {
            _targets[request.uri.path] =
                _RegisteredTarget(finalTarget, _TargetKind.playlist);
            await _respondPlaylist(
              request.response,
              playlistText,
              finalTarget,
            );
          },
        );
        return;
      }
      final range = request.headers.value(HttpHeaders.rangeHeader);
      final ifRange = request.headers.value(HttpHeaders.ifRangeHeader);
      final isExplicitPlaylist = registered.kind == _TargetKind.playlist ||
          registered.uri.path.toLowerCase().endsWith('.m3u8');
      final (response, finalTarget) = await _sendWithRedirects(
        registered.uri,
        method: request.method,
        range: range,
        ifRange: ifRange,
        allowRange: !isExplicitPlaylist && !_isLive,
      );

      if (_closed || _isCancelled()) {
        await response.stream.listen((_) {}).cancel();
        request.response.statusCode = HttpStatus.gone;
        return;
      }

      if (response.statusCode < 200 || response.statusCode >= 300) {
        _lastUpstreamStatusCode = response.statusCode;
        _lastUpstreamHost = finalTarget.host;
        await response.stream.listen((_) {}).cancel();
        request.response.statusCode = response.statusCode;
        return;
      }
      _lastUpstreamStatusCode = response.statusCode;
      _lastUpstreamHost = finalTarget.host;
      _lastUpstreamError = null;

      final mime = (response.headers['content-type'] ?? '').toLowerCase();
      final knownPlaylist = isExplicitPlaylist ||
          mime.contains('mpegurl') ||
          finalTarget.path.toLowerCase().endsWith('.m3u8');

      if (request.method == 'HEAD') {
        _copyResponseHeaders(response, request.response);
        if (knownPlaylist) {
          request.response.headers
              .set(HttpHeaders.contentTypeHeader, 'application/vnd.apple.mpegurl');
        }
        await response.stream.listen((_) {}).cancel();
        return;
      }

      if (knownPlaylist) {
        final body = await _readBoundedBody(response.stream, _maxPlaylistBytes);
        final text = utf8.decode(body, allowMalformed: true);
        if (_startsWithM3u8Magic(body)) {
          await _respondPlaylist(request.response, text, finalTarget);
          return;
        }
        _copyResponseHeaders(response, request.response);
        request.response.contentLength = body.length;
        request.response.add(body);
        return;
      }

      // Sniff prefix for extensionless #EXTM3U playlists (including PHP/text/html
      // dynamic IPTV gateways) or disguised TS segments.
      final shouldSniffPrefix = !_hasNonZeroRangeStart(range) &&
          (registered.kind == _TargetKind.tsSegment ||
              (registered.kind == _TargetKind.auto &&
                  (mime.isEmpty ||
                      mime.startsWith('text/') ||
                      mime.contains('application/text') ||
                      mime.contains('octet-stream'))));

      if (shouldSniffPrefix) {
        await _serveWithPrefixInspection(
          response,
          finalTarget,
          registered.kind,
          request.response,
        );
        return;
      }

      request.response.bufferOutput = false;
      _copyResponseHeaders(response, request.response);
      request.response.statusCode = response.statusCode;
      await _pipeMediaStream(response.stream, request.response);
    } on StateError {
      try {
        request.response.statusCode = HttpStatus.gone;
      } catch (_) {}
    } catch (error) {
      _lastUpstreamError = error;
      try {
        request.response.statusCode = HttpStatus.badGateway;
      } catch (_) {}
    } finally {
      _requests.remove(request);
      try {
        await request.response.close();
      } catch (_) {}
    }
  }

  void _copyResponseHeaders(
      http.StreamedResponse upstream, HttpResponse downstream) {
    downstream.statusCode = upstream.statusCode;
    final encoding = (upstream.headers['content-encoding'] ?? '').trim().toLowerCase();
    final isCompressed = encoding.isNotEmpty && encoding != 'identity';
    for (final key in const [
      'content-type',
      'content-length',
      'content-range',
      'accept-ranges',
      'etag',
      'last-modified',
    ]) {
      if (key == 'content-length' && isCompressed) continue;
      final value = upstream.headers[key];
      if (value != null && value.isNotEmpty) {
        downstream.headers.set(key, value);
      }
    }
    downstream.headers.set('cache-control', 'no-store');
  }

  Future<Uint8List> _readBoundedBody(
      Stream<List<int>> stream, int maxBytes) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in stream.timeout(const Duration(seconds: 30))) {
      if (_closed || _isCancelled()) throw StateError('cancelled');
      if (builder.length + chunk.length > maxBytes) {
        throw const FormatException('媒体播放列表体积超出安全上限');
      }
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  static final RegExp _adPathPattern = RegExp(
    r'(?:^|[/_.-])(?:ads?|advert|adjump|adver|guanggao|promo|preroll|pre-roll|midroll|mid-roll|commercial|sponsor)(?:[/_.\-\d]|$)',
    caseSensitive: false,
  );

  static bool _matchesAdHeuristic(
    Uri segmentUri,
    String primaryHost,
    List<String> adHosts,
  ) {
    final host = segmentUri.host.toLowerCase();
    if (primaryHost.isNotEmpty && host.isNotEmpty && host != primaryHost) {
      return true;
    }
    for (final raw in adHosts) {
      final ad = raw.trim().toLowerCase();
      if (ad.isEmpty) continue;
      if (host == ad ||
          host.endsWith('.$ad') ||
          segmentUri.toString().toLowerCase().contains(ad)) {
        return true;
      }
    }
    return _adPathPattern.hasMatch(segmentUri.path) ||
        _adPathPattern.hasMatch(host);
  }

  static String stripVodPlaylistAds(
    String text,
    Uri origin, {
    List<String> adPatterns = const [],
  }) =>
      stripHlsAdsIfVod(text, origin, adHosts: adPatterns).playlist;

  /// Heuristic HLS VOD discontinuity ad remover.
  /// Never triggers on live streams (requires `#EXT-X-ENDLIST` or
  /// `#EXT-X-PLAYLIST-TYPE:VOD` + `#EXT-X-DISCONTINUITY`, and `!isLive`).
  static ({String playlist, int removedSegments, double removedDuration})
      stripHlsAdsIfVod(
    String text,
    Uri origin, {
    bool enabled = true,
    bool isLive = false,
    List<String> adHosts = const [],
  }) {
    if (!enabled || isLive) {
      return (playlist: text, removedSegments: 0, removedDuration: 0.0);
    }
    final normalizedLines = text.split('\n').map((raw) {
      return raw.endsWith('\r') ? raw.substring(0, raw.length - 1) : raw;
    }).toList(growable: false);

    var isMaster = false;
    var isVod = false;
    var hasDiscontinuity = false;
    for (final raw in normalizedLines) {
      final t = raw.trim();
      final upper = t.toUpperCase();
      if (upper.startsWith('#EXT-X-STREAM-INF')) {
        isMaster = true;
        break;
      }
      if (upper == '#EXT-X-ENDLIST' ||
          upper.startsWith('#EXT-X-PLAYLIST-TYPE:VOD')) {
        isVod = true;
      } else if (upper == '#EXT-X-DISCONTINUITY') {
        hasDiscontinuity = true;
      }
    }
    if (isMaster || !isVod || !hasDiscontinuity) {
      return (playlist: text, removedSegments: 0, removedDuration: 0.0);
    }

    final headerLines = <String>[];
    final footerLines = <String>[];
    final blocks = <_HlsBlock>[];
    var currentBlock = _HlsBlock(hasPrecedingDiscontinuity: false);
    var seenFirstSegmentOrDiscontinuity = false;
    final pendingSegTags = <String>[];
    double? pendingDuration;
    String? currentKeyTag;
    var inFooter = false;

    for (final line in normalizedLines) {
      final trimmed = line.trim();
      final upper = trimmed.toUpperCase();
      if (upper == '#EXT-X-ENDLIST') {
        inFooter = true;
        footerLines.add(line);
        continue;
      }
      if (inFooter) {
        footerLines.add(line);
        continue;
      }
      if (trimmed.isEmpty) {
        if (!seenFirstSegmentOrDiscontinuity && pendingSegTags.isEmpty) {
          headerLines.add(line);
        }
        continue;
      }
      if (upper == '#EXT-X-DISCONTINUITY') {
        if (seenFirstSegmentOrDiscontinuity) {
          blocks.add(currentBlock);
          currentBlock = _HlsBlock(hasPrecedingDiscontinuity: true);
        } else {
          seenFirstSegmentOrDiscontinuity = true;
        }
        pendingSegTags.clear();
        pendingDuration = null;
        continue;
      }
      if (trimmed.startsWith('#')) {
        if (upper.startsWith('#EXTINF:')) {
          seenFirstSegmentOrDiscontinuity = true;
          final afterColon = trimmed.substring(8);
          final comma = afterColon.indexOf(',');
          final numText =
              (comma >= 0 ? afterColon.substring(0, comma) : afterColon).trim();
          pendingDuration = double.tryParse(numText) ?? 0.0;
          pendingSegTags.add(line);
        } else if (upper.startsWith('#EXT-X-KEY:')) {
          currentKeyTag = line;
          if (!seenFirstSegmentOrDiscontinuity) {
            headerLines.add(line);
          } else {
            pendingSegTags.add(line);
          }
        } else if (upper.startsWith('#EXT-X-MAP:') ||
            upper.startsWith('#EXT-X-BYTERANGE:') ||
            upper.startsWith('#EXT-X-PROGRAM-DATE-TIME:')) {
          seenFirstSegmentOrDiscontinuity = true;
          pendingSegTags.add(line);
        } else if (!seenFirstSegmentOrDiscontinuity) {
          headerLines.add(line);
        } else {
          pendingSegTags.add(line);
        }
        continue;
      }

      seenFirstSegmentOrDiscontinuity = true;
      Uri resolvedUri;
      try {
        resolvedUri = origin.resolve(trimmed);
      } catch (_) {
        resolvedUri = origin;
      }
      currentBlock.segments.add(
        _HlsSegmentEntry(
          duration: pendingDuration ?? 0.0,
          tagLines: List<String>.from(pendingSegTags),
          uriLine: line,
          resolvedUri: resolvedUri,
          keyTag: currentKeyTag,
        ),
      );
      pendingSegTags.clear();
      pendingDuration = null;
    }
    if (currentBlock.segments.isNotEmpty) {
      blocks.add(currentBlock);
    }

    if (blocks.length < 2) {
      return (playlist: text, removedSegments: 0, removedDuration: 0.0);
    }

    var totalDuration = 0.0;
    var totalSegments = 0;
    final hostDurations = <String, double>{};
    for (final block in blocks) {
      for (final seg in block.segments) {
        totalSegments++;
        final d = seg.duration > 0 ? seg.duration : 0.0;
        totalDuration += d;
        final h = seg.resolvedUri.host.toLowerCase();
        hostDurations[h] = (hostDurations[h] ?? 0.0) + d;
      }
    }
    if (totalSegments == 0 || totalDuration <= 0.0) {
      return (playlist: text, removedSegments: 0, removedDuration: 0.0);
    }

    var primaryHost = origin.host.toLowerCase();
    var maxHostDur = -1.0;
    hostDurations.forEach((host, dur) {
      if (dur > maxHostDur) {
        maxHostDur = dur;
        primaryHost = host;
      }
    });

    final removeBlock = List<bool>.filled(blocks.length, false);
    var removedSegments = 0;
    var removedDuration = 0.0;

    for (var i = 0; i < blocks.length; i++) {
      final block = blocks[i];
      if (block.segments.isEmpty || block.segments.length > 20) continue;
      final blockDuration = block.segments.fold<double>(
        0.0,
        (sum, seg) => sum + (seg.duration > 0 ? seg.duration : 0.0),
      );
      if (blockDuration / totalDuration > 0.40) continue;
      final allShortEnough =
          block.segments.every((seg) => seg.duration > 0 && seg.duration <= 60.0);
      if (!allShortEnough) continue;

      final hitsHeuristic = block.segments.any(
        (seg) => _matchesAdHeuristic(seg.resolvedUri, primaryHost, adHosts),
      );
      if (hitsHeuristic) {
        removeBlock[i] = true;
        removedSegments += block.segments.length;
        removedDuration += blockDuration;
      }
    }

    if (removedSegments == 0 ||
        removedSegments >= totalSegments ||
        (removedDuration / totalDuration) > 0.40) {
      return (playlist: text, removedSegments: 0, removedDuration: 0.0);
    }

    final out = <String>[...headerLines];
    var emittedAnyBlock = false;
    var prevWasRemoved = false;
    String? lastEmittedKeyTag;
    for (final line in headerLines) {
      if (line.trim().toUpperCase().startsWith('#EXT-X-KEY:')) {
        lastEmittedKeyTag = line;
      }
    }
    for (var i = 0; i < blocks.length; i++) {
      if (removeBlock[i]) {
        prevWasRemoved = true;
        continue;
      }
      final block = blocks[i];
      final wasPrecededByRemovedAd = prevWasRemoved;
      if (emittedAnyBlock &&
          block.hasPrecedingDiscontinuity &&
          !wasPrecededByRemovedAd) {
        out.add('#EXT-X-DISCONTINUITY');
      }
      prevWasRemoved = false;
      emittedAnyBlock = true;
      for (var sIdx = 0; sIdx < block.segments.length; sIdx++) {
        final seg = block.segments[sIdx];
        final blockHasOwnKey = seg.tagLines.any(
          (l) => l.trim().toUpperCase().startsWith('#EXT-X-KEY:'),
        );
        if (sIdx == 0 && !blockHasOwnKey) {
          if (wasPrecededByRemovedAd) {
            if (lastEmittedKeyTag != null) {
              out.add(lastEmittedKeyTag);
            }
          } else if (seg.keyTag != null && seg.keyTag != lastEmittedKeyTag) {
            out.add(seg.keyTag!);
            lastEmittedKeyTag = seg.keyTag;
          }
        }
        for (final tag in seg.tagLines) {
          if (tag.trim().toUpperCase().startsWith('#EXT-X-KEY:')) {
            lastEmittedKeyTag = tag;
          }
          out.add(tag);
        }
        out.add(seg.uriLine);
      }
    }
    out.addAll(footerLines);
    return (
      playlist: out.join('\n'),
      removedSegments: removedSegments,
      removedDuration: removedDuration,
    );
  }

  Future<void> _respondPlaylist(
      HttpResponse downstream, String playlistText, Uri playlistOrigin) async {
    final cleaned = stripHlsAdsIfVod(
      playlistText,
      playlistOrigin,
      enabled: _removeHlsAds,
      isLive: _isLive,
      adHosts: _adHosts,
    );
    _removedHlsAdSegments += cleaned.removedSegments;
    _removedHlsAdDurationSec += cleaned.removedDuration;
    final rewritten = _rewritePlaylist(cleaned.playlist, playlistOrigin);
    final encoded = utf8.encode(rewritten);
    downstream.statusCode = HttpStatus.ok;
    downstream.headers.removeAll('content-range');
    downstream.headers
        .set(HttpHeaders.contentTypeHeader, 'application/vnd.apple.mpegurl');
    downstream.headers.set('cache-control', 'no-store');
    downstream.contentLength = encoded.length;
    downstream.add(encoded);
  }

  Future<void> _serveWithPrefixInspection(
    http.StreamedResponse upstream,
    Uri finalTarget,
    _TargetKind kind,
    HttpResponse downstream,
  ) async {
    final done = Completer<void>();
    StreamSubscription<List<int>>? subscription;
    Timer? idleTimer;
    var finished = false;
    var phase = 0; // 0: sniffing prefix, 1: playlist accumulation, 2: binary streaming
    var pendingBytes = 0;
    final prefixBuilder = BytesBuilder(copy: false);
    final playlistBuilder = BytesBuilder(copy: false);

    Future<void> finish([Object? error, StackTrace? stackTrace]) async {
      if (finished) return;
      finished = true;
      idleTimer?.cancel();
      final sub = subscription;
      if (sub != null) {
        _upstreams.remove(sub);
        try {
          await sub.cancel();
        } catch (_) {}
      }
      if (!done.isCompleted) {
        if (error != null) {
          done.completeError(error, stackTrace);
        } else {
          done.complete();
        }
      }
    }

    void resetIdleTimer() {
      idleTimer?.cancel();
      idleTimer = Timer(const Duration(seconds: 30), () {
        unawaited(finish(TimeoutException('upstream media idle')));
      });
    }

    void beginBinaryStream(Uint8List prefix) {
      phase = 2;
      downstream.bufferOutput = false;
      final skip =
          kind == _TargetKind.tsSegment ? findDisguisedTsOffset(prefix) : 0;
      _copyResponseHeaders(upstream, downstream);
      if (skip > 0) {
        downstream.statusCode = HttpStatus.ok;
        downstream.headers.removeAll('content-range');
        downstream.headers.set(HttpHeaders.contentTypeHeader, 'video/mp2t');
        final rawLen = int.tryParse(upstream.headers['content-length'] ?? '');
        if (rawLen != null && rawLen >= skip) {
          downstream.contentLength = rawLen - skip;
        } else {
          downstream.headers.removeAll(HttpHeaders.contentLengthHeader);
        }
      }
      final initialSlice = skip > 0 ? prefix.sublist(skip) : prefix;
      if (initialSlice.isNotEmpty) {
        downstream.add(initialSlice);
        pendingBytes += initialSlice.length;
      }
    }

    unawaited(downstream.done.then((_) => finish(), onError: (_) => finish()));
    resetIdleTimer();
    subscription = upstream.stream.listen(
      (chunk) {
        if (finished || _closed || _isCancelled()) {
          unawaited(finish(StateError('cancelled')));
          return;
        }
        resetIdleTimer();
        try {
          if (phase == 0) {
            prefixBuilder.add(chunk);
            final currentBytes = prefixBuilder.toBytes();
            if (_startsWithM3u8Magic(currentBytes) && currentBytes.length >= 7) {
              final taken = prefixBuilder.takeBytes();
              if (taken.length > _maxPlaylistBytes) {
                unawaited(
                  finish(const FormatException('媒体播放列表体积超出安全上限')),
                );
                return;
              }
              phase = 1;
              playlistBuilder.add(taken);
              return;
            }
            if (kind == _TargetKind.auto && !_couldBeM3u8Prefix(currentBytes)) {
              beginBinaryStream(prefixBuilder.takeBytes());
              return;
            }
            if (prefixBuilder.length >= _sniffPrefixBytes) {
              final prefix = prefixBuilder.takeBytes();
              if (_startsWithM3u8Magic(prefix)) {
                if (prefix.length > _maxPlaylistBytes) {
                  unawaited(
                    finish(const FormatException('媒体播放列表体积超出安全上限')),
                  );
                  return;
                }
                phase = 1;
                playlistBuilder.add(prefix);
                return;
              }
              beginBinaryStream(prefix);
            }
            return;
          }
          if (phase == 1) {
            if (playlistBuilder.length + chunk.length > _maxPlaylistBytes) {
              unawaited(
                finish(const FormatException('媒体播放列表体积超出安全上限')),
              );
              return;
            }
            playlistBuilder.add(chunk);
            return;
          }
          downstream.add(chunk);
          pendingBytes += chunk.length;
          final flushThreshold =
              _isLive ? _liveFlushThresholdBytes : _flushThresholdBytes;
          if (pendingBytes >= flushThreshold) {
            pendingBytes = 0;
            subscription?.pause(
              downstream
                  .flush()
                  .timeout(const Duration(seconds: 30))
                  .catchError((_) => finish()),
            );
          }
        } catch (e, st) {
          unawaited(finish(e, st));
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        unawaited(finish(error, stackTrace));
      },
      onDone: () async {
        if (finished) return;
        try {
          if (phase == 0) {
            final prefix = prefixBuilder.takeBytes();
            if (_startsWithM3u8Magic(prefix)) {
              final text = utf8.decode(prefix, allowMalformed: true);
              await _respondPlaylist(downstream, text, finalTarget);
            } else {
              beginBinaryStream(prefix);
            }
          } else if (phase == 1) {
            final text = utf8.decode(
              playlistBuilder.takeBytes(),
              allowMalformed: true,
            );
            await _respondPlaylist(downstream, text, finalTarget);
          }
          await finish();
        } catch (e, st) {
          await finish(e, st);
        }
      },
      cancelOnError: true,
    );
    _upstreams.add(subscription);
    await done.future;
    if (!_closed && !_isCancelled() && phase == 2 && pendingBytes > 0) {
      try {
        await downstream.flush().timeout(const Duration(seconds: 30));
      } catch (_) {}
    }
  }

  Future<void> _pipeMediaStream(
    Stream<List<int>> source,
    HttpResponse sink,
  ) async {
    final done = Completer<void>();
    StreamSubscription<List<int>>? subscription;
    Timer? idleTimer;
    var finished = false;
    var pendingBytes = 0;

    Future<void> finish([Object? error, StackTrace? stackTrace]) async {
      if (finished) return;
      finished = true;
      idleTimer?.cancel();
      final sub = subscription;
      if (sub != null) {
        _upstreams.remove(sub);
        try {
          await sub.cancel();
        } catch (_) {}
      }
      if (!done.isCompleted) {
        if (error != null) {
          done.completeError(error, stackTrace);
        } else {
          done.complete();
        }
      }
    }

    void resetIdleTimer() {
      idleTimer?.cancel();
      idleTimer = Timer(const Duration(seconds: 30), () {
        unawaited(finish(TimeoutException('upstream media idle')));
      });
    }

    unawaited(sink.done.then((_) => finish(), onError: (_) => finish()));
    resetIdleTimer();
    subscription = source.listen(
      (chunk) {
        if (finished || _closed || _isCancelled()) {
          unawaited(finish());
          return;
        }
        resetIdleTimer();
        try {
          sink.add(chunk);
        } catch (_) {
          unawaited(finish());
          return;
        }
        pendingBytes += chunk.length;
        final flushThreshold =
            _isLive ? _liveFlushThresholdBytes : _flushThresholdBytes;
        if (pendingBytes >= flushThreshold) {
          pendingBytes = 0;
          subscription?.pause(
            sink
                .flush()
                .timeout(const Duration(seconds: 30))
                .catchError((_) => finish()),
          );
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        unawaited(finish(error, stackTrace));
      },
      onDone: () {
        unawaited(finish());
      },
      cancelOnError: true,
    );
    _upstreams.add(subscription);
    await done.future;
    if (!_closed && !_isCancelled() && pendingBytes > 0) {
      try {
        await sink.flush().timeout(const Duration(seconds: 30));
      } catch (_) {}
    }
  }

  String _rewritePlaylist(String text, Uri origin) {
    var encrypted = false;
    var hasInitMap = false;
    var expectVariant = false;

    String rewriteUri(String rawUri, _TargetKind kind) {
      final cleaned = rawUri.trim();
      if (cleaned.isEmpty || cleaned.startsWith('data:')) return rawUri;
      final resolved = origin.resolve(cleaned);
      if (!_canRegisterTarget(resolved)) {
        throw const FormatException('播放列表包含不受信任的分片地址');
      }
      return _register(resolved, kind).toString();
    }

    final out = <String>[];
    for (final rawLine in text.split('\n')) {
      final line = rawLine.endsWith('\r')
          ? rawLine.substring(0, rawLine.length - 1)
          : rawLine;
      final trimmed = line.trim();
      if (trimmed.isEmpty) {
        out.add(line);
        continue;
      }
      if (trimmed.startsWith('#')) {
        if (trimmed.startsWith('#EXT-X-STREAM-INF')) {
          expectVariant = true;
          out.add(line);
          continue;
        }
        if (trimmed.startsWith('#EXT-X-KEY:')) {
          final methodMatch =
              RegExp(r'METHOD=([^,\s]+)', caseSensitive: false).firstMatch(trimmed);
          final method = methodMatch?.group(1)?.trim().toUpperCase() ?? 'NONE';
          encrypted = method != 'NONE';
          out.add(line.replaceAllMapped(
            RegExp(r'URI="([^"]+)"'),
            (m) => 'URI="${rewriteUri(m[1]!, _TargetKind.raw)}"',
          ));
          continue;
        }
        if (trimmed.startsWith('#EXT-X-MAP:')) {
          hasInitMap = true;
          out.add(line.replaceAllMapped(
            RegExp(r'URI="([^"]+)"'),
            (m) => 'URI="${rewriteUri(m[1]!, _TargetKind.raw)}"',
          ));
          continue;
        }
        if (trimmed.startsWith('#EXT-X-MEDIA:') ||
            trimmed.startsWith('#EXT-X-I-FRAME-STREAM-INF:')) {
          out.add(line.replaceAllMapped(
            RegExp(r'URI="([^"]+)"'),
            (m) => 'URI="${rewriteUri(m[1]!, _TargetKind.playlist)}"',
          ));
          continue;
        }
        out.add(line);
        continue;
      }

      final resolved = origin.resolve(trimmed);
      final looksPlaylist = expectVariant ||
          resolved.path.toLowerCase().endsWith('.m3u8');
      expectVariant = false;
      final kind = looksPlaylist
          ? _TargetKind.playlist
          : ((!encrypted && !hasInitMap)
              ? _TargetKind.tsSegment
              : _TargetKind.raw);
      out.add(rewriteUri(trimmed, kind));
    }
    return out.join('\n');
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _timer?.cancel();
    _headers.clear();
    _cookieJar.clear();
    _targets.clear();
    _paths.clear();
    final activeUpstreams = _upstreams.toList();
    _upstreams.clear();
    for (final sub in activeUpstreams) {
      try {
        await sub.cancel();
      } catch (_) {}
    }
    if (_ownsClient) {
      _client.close();
      _directOnlyClient?.close();
      _directOnlyClient = null;
    }
    await _server.close(force: true);
  }
}

/// Owns the active episode's local `127.0.0.1` gateway lease in `PlayerScreen`.
class PlayerLocalMediaSession {
  LocalMediaLease? _current;
  LocalMediaLease? get current => _current;

  bool owns(LocalMediaLease? lease) =>
      lease != null && identical(lease, _current);

  void adopt(LocalMediaLease? lease) => _current = lease;

  LocalMediaLease? detach() {
    final previous = _current;
    _current = null;
    return previous;
  }

  Future<void> releaseUnless(LocalMediaLease? keep) async {
    if (!owns(keep)) await detach()?.close();
  }

  Future<void> discard(LocalMediaLease? lease) async {
    if (lease != null && !owns(lease)) await lease.close();
  }
}
