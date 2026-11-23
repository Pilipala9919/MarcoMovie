import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'local_media_proxy.dart';

/// Byte extent `[isoOffset, isoOffset + length - 1]` inside the ISO image.
class IsoExtent {
  final int isoOffset;
  final int length;
  const IsoExtent({required this.isoOffset, required this.length});
}

/// Resolved file inside an ISO-9660 or UDF 2.50 volume.
class IsoFileEntry {
  final String name;
  final int size;
  final List<IsoExtent> extents;
  final Uint8List? inlineData;

  const IsoFileEntry({
    required this.name,
    required this.size,
    this.extents = const [],
    this.inlineData,
  });
}

/// Chapter marker extracted from a Blu-ray `.mpls` PlayListMark table.
class BlurayChapter {
  final int index;
  final String title;
  final Duration position;
  final Duration? duration;

  const BlurayChapter({
    required this.index,
    required this.title,
    required this.position,
    this.duration,
  });

  Map<String, dynamic> toJson() => {
        'index': index,
        'title': title,
        'positionMs': position.inMilliseconds,
        if (duration != null) 'durationMs': duration!.inMilliseconds,
      };
}

/// Parsed Blu-ray `.mpls` or DVD `VIDEO_TS` main feature metadata.
class BlurayPlaylistInfo {
  final String playlistName;
  final Duration totalDuration;
  final List<String> clipNames;
  final List<BlurayChapter> chapters;
  final int totalBytes;
  final bool isDvdVob;

  const BlurayPlaylistInfo({
    required this.playlistName,
    required this.totalDuration,
    required this.clipNames,
    this.chapters = const [],
    required this.totalBytes,
    this.isDvdVob = false,
  });
}

/// Random-access byte source for `.iso` images (local/SMB, HTTP Range, or synthetic).
abstract class IsoRangeReader {
  Future<int?> totalLength();
  Future<Uint8List> readAt(int offset, int length);
  Future<void> close();
}

/// Local filesystem & SMB UNC path (`C:\...`, `\\server\share\...`, `/Volumes/...`)
/// random-access ISO reader using a serialized [RandomAccessFile].
class LocalFileIsoReader implements IsoRangeReader {
  final File _file;
  RandomAccessFile? _raf;
  int? _length;
  Future<void> _lock = Future<void>.value();

  LocalFileIsoReader(this._file);

  Future<T> _synchronized<T>(Future<T> Function() fn) {
    final next = _lock.then((_) => fn());
    _lock = next.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return next;
  }

  Future<RandomAccessFile> _ensureOpen() async {
    if (_raf != null) return _raf!;
    if (!await _file.exists()) {
      throw FileSystemException('ISO 文件不存在', _file.path);
    }
    _raf = await _file.open(mode: FileMode.read);
    _length ??= await _raf!.length();
    return _raf!;
  }

  @override
  Future<int?> totalLength() => _synchronized(() async {
        await _ensureOpen();
        return _length;
      });

  @override
  Future<Uint8List> readAt(int offset, int length) => _synchronized(() async {
        if (offset < 0 || length <= 0) return Uint8List(0);
        final raf = await _ensureOpen();
        final total = _length ?? await raf.length();
        if (offset >= total) return Uint8List(0);
        final toRead = math.min(length, total - offset);
        await raf.setPosition(offset);
        return await raf.read(toRead);
      });

  @override
  Future<void> close() => _synchronized(() async {
        final raf = _raf;
        _raf = null;
        if (raf != null) {
          try {
            await raf.close();
          } catch (_) {}
        }
      });
}

/// HTTP(S) `Range` reader for WebDAV, AList, Emby, and cloud-drive `.iso` URLs.
class HttpRangeIsoReader implements IsoRangeReader {
  final Uri _initialUri;
  final Map<String, String> _headers;
  final http.Client _client;
  final bool _ownsClient;
  final bool _allowPrivateOrigin;

  Uri? _resolvedUri;
  int? _totalLength;
  bool _closed = false;

  HttpRangeIsoReader(
    Uri uri, {
    Map<String, String> headers = const {},
    http.Client? client,
  })  : _initialUri = uri,
        _headers = Map<String, String>.from(headers),
        _client = client ?? _createDefaultClient(),
        _ownsClient = client == null,
        _allowPrivateOrigin = LocalMediaLease.isPrivateOrReservedTarget(uri);

  static http.Client _createDefaultClient() {
    final io = HttpClient()
      ..autoUncompress = false
      ..maxConnectionsPerHost = 8
      ..connectionTimeout = const Duration(seconds: 15)
      ..idleTimeout = const Duration(seconds: 30);
    return IOClient(io);
  }

  static const Set<String> _originBoundHeaders = {
    'authorization',
    'proxy-authorization',
    'cookie',
    'cookie2',
    'x-api-key',
    'x-emby-token',
    'x-plex-token',
  };

  static bool _sameOrigin(Uri a, Uri b) {
    final portA =
        a.hasPort ? a.port : (a.scheme.toLowerCase() == 'https' ? 443 : 80);
    final portB =
        b.hasPort ? b.port : (b.scheme.toLowerCase() == 'https' ? 443 : 80);
    return a.scheme.toLowerCase() == b.scheme.toLowerCase() &&
        a.host.toLowerCase() == b.host.toLowerCase() &&
        portA == portB;
  }

  Map<String, String> _headersFor(Uri target, {String? range}) {
    final sameOrigin = _sameOrigin(target, _initialUri);
    final out = <String, String>{};
    for (final entry in _headers.entries) {
      final lower = entry.key.toLowerCase();
      if (lower == 'host' || lower == 'range' || lower == 'content-length') {
        continue;
      }
      if (!sameOrigin && _originBoundHeaders.contains(lower)) continue;
      out[entry.key] = entry.value;
    }
    out['Accept-Encoding'] = 'identity';
    if (range != null) out['Range'] = range;
    return out;
  }

  bool _isAllowedTarget(Uri next) {
    if (next.scheme != 'http' && next.scheme != 'https') return false;
    if (next.host.isEmpty || next.userInfo.isNotEmpty) return false;
    if (_sameOrigin(next, _initialUri) || _allowPrivateOrigin) return true;
    return !LocalMediaLease.isPrivateOrReservedTarget(next);
  }

  Future<http.StreamedResponse> _sendRangeWithRedirects(
    String method, {
    String? range,
  }) async {
    var current = _resolvedUri ?? _initialUri;
    for (var hop = 0; hop <= 10; hop++) {
      final req = http.Request(method, current)
        ..followRedirects = false
        ..headers.addAll(_headersFor(current, range: range));
      final resp =
          await _client.send(req).timeout(const Duration(seconds: 25));
      if (const [301, 302, 303, 307, 308].contains(resp.statusCode)) {
        await resp.stream.listen((_) {}).cancel();
        final loc = resp.headers['location'];
        if (loc == null || loc.trim().isEmpty || hop >= 10) {
          throw const FormatException('ISO 远端重定向失败');
        }
        final next = current.resolve(loc.trim()).removeFragment();
        if (!_isAllowedTarget(next)) {
          throw const FormatException('ISO 重定向目标不受信任');
        }
        current = next;
        _resolvedUri = next;
        continue;
      }
      return resp;
    }
    throw const FormatException('ISO 重定向次数过多');
  }

  static int? _parseTotalFromContentRange(String? cr) {
    if (cr == null || cr.isEmpty) return null;
    final m = RegExp(
      r'^bytes\s+\d+-\d+/(\d+)$',
      caseSensitive: false,
    ).firstMatch(cr.trim());
    return m == null ? null : int.tryParse(m.group(1)!);
  }

  @override
  Future<int?> totalLength() async {
    if (_totalLength != null) return _totalLength;
    // Probe with a single 2 KiB sector Range request (also validates Range support).
    final resp = await _sendRangeWithRedirects('GET', range: 'bytes=0-2047');
    try {
      if (resp.statusCode == 206) {
        _totalLength = _parseTotalFromContentRange(resp.headers['content-range']);
      } else if (resp.statusCode == 200) {
        _totalLength = int.tryParse(resp.headers['content-length'] ?? '');
      }
    } finally {
      await resp.stream.listen((_) {}).cancel();
    }
    return _totalLength;
  }

  @override
  Future<Uint8List> readAt(int offset, int length) async {
    if (_closed || offset < 0 || length <= 0) return Uint8List(0);
    if (_totalLength != null && offset >= _totalLength!) return Uint8List(0);
    final end = _totalLength != null
        ? math.min(offset + length - 1, _totalLength! - 1)
        : offset + length - 1;
    final resp = await _sendRangeWithRedirects(
      'GET',
      range: 'bytes=$offset-$end',
    );
    if (resp.statusCode == 416) {
      await resp.stream.listen((_) {}).cancel();
      return Uint8List(0);
    }
    if (resp.statusCode != 206 && resp.statusCode != 200) {
      await resp.stream.listen((_) {}).cancel();
      throw HttpException('ISO Range 请求失败 (HTTP ${resp.statusCode})');
    }
    if (_totalLength == null) {
      if (resp.statusCode == 206) {
        _totalLength = _parseTotalFromContentRange(resp.headers['content-range']);
      } else {
        _totalLength = int.tryParse(resp.headers['content-length'] ?? '');
      }
    }

    final expected = end - offset + 1;
    if (resp.statusCode == 200) {
      // Server ignored Range and started at 0: consume only up to offset + expected.
      final out = BytesBuilder(copy: false);
      var pos = 0;
      await for (final chunk
          in resp.stream.timeout(const Duration(seconds: 30))) {
        final chunkEnd = pos + chunk.length;
        if (chunkEnd > offset && pos <= end) {
          final s = math.max(0, offset - pos);
          final e = math.min(chunk.length, end - pos + 1);
          if (e > s) {
            out.add(s == 0 && e == chunk.length ? chunk : chunk.sublist(s, e));
          }
        }
        pos = chunkEnd;
        if (pos > end) {
          break;
        }
      }
      return out.takeBytes();
    }

    final builder = BytesBuilder(copy: false);
    await for (final chunk in resp.stream.timeout(const Duration(seconds: 30))) {
      builder.add(chunk);
      if (builder.length >= expected) break;
    }
    final bytes = builder.takeBytes();
    if (bytes.length > expected) {
      return Uint8List.sublistView(bytes, 0, expected);
    }
    return bytes;
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    if (_ownsClient) {
      _client.close();
    }
  }
}

/// Bounded 2 KiB sector LRU cache wrapper used during filesystem & `.mpls` parsing.
class _SectorCachedReader {
  static const int sectorSize = 2048;
  static const int _maxCachedSectors = 256;

  final IsoRangeReader inner;
  final Map<int, Uint8List> _sectors = <int, Uint8List>{};

  _SectorCachedReader(this.inner);

  Future<int?> totalLength() => inner.totalLength();

  Future<Uint8List> readSector(int sectorIndex) async {
    final existing = _sectors.remove(sectorIndex);
    if (existing != null) {
      _sectors[sectorIndex] = existing;
      return existing;
    }
    final data = await inner.readAt(sectorIndex * sectorSize, sectorSize);
    if (data.isNotEmpty) {
      if (_sectors.length >= _maxCachedSectors) {
        _sectors.remove(_sectors.keys.first);
      }
      _sectors[sectorIndex] = data;
    }
    return data;
  }

  Future<Uint8List> readBytes(int offset, int length) async {
    if (length <= 0 || offset < 0) return Uint8List(0);
    if (length <= sectorSize * 4) {
      final startSector = offset ~/ sectorSize;
      final endSector = (offset + length - 1) ~/ sectorSize;
      final builder = BytesBuilder(copy: false);
      for (var s = startSector; s <= endSector; s++) {
        final sec = await readSector(s);
        if (sec.isEmpty) break;
        final secBase = s * sectorSize;
        final sliceStart = math.max(0, offset - secBase);
        final sliceEnd = math.min(sec.length, offset + length - secBase);
        if (sliceEnd > sliceStart) {
          builder.add(Uint8List.sublistView(sec, sliceStart, sliceEnd));
        }
      }
      return builder.takeBytes();
    }
    return inner.readAt(offset, length);
  }
}

/// Virtual filesystem browser over UDF 2.50 (ECMA-167) and ISO-9660 (ECMA-119)
/// using only on-demand 2 KiB sector Range reads.
class IsoFilesystem {
  static const int sectorSize = 2048;

  final _SectorCachedReader _reader;
  final bool isUdf;
  final int _blockSize;

  // UDF state
  final Map<int, ({int startSector, int lengthSectors})> _udfPhysPartitions = {};
  final Map<int, _UdfPartitionMap> _udfMaps = {};
  final Map<int, List<IsoExtent>> _udfMetadataExtents = {};
  ({int block, int partitionRef})? _udfRootIcb;

  // ISO-9660 state
  ({int extentSector, int size, bool isJoliet})? _iso9660Root;

  IsoFilesystem._udf(
    this._reader,
    this._blockSize,
  ) : isUdf = true;

  IsoFilesystem._iso9660(
    this._reader,
    this._blockSize,
    this._iso9660Root,
  ) : isUdf = false;

  static int _u16LE(Uint8List b, int off) => b[off] | (b[off + 1] << 8);
  static int _u32LE(Uint8List b, int off) =>
      b[off] | (b[off + 1] << 8) | (b[off + 2] << 16) | (b[off + 3] << 24);
  static int _u64LE(Uint8List b, int off) {
    final lo = _u32LE(b, off);
    final hi = _u32LE(b, off + 4);
    return lo + (hi * 0x100000000);
  }

  static Future<IsoFilesystem> mount(IsoRangeReader reader) async {
    final cached = _SectorCachedReader(reader);
    final udf = await _tryMountUdf(cached);
    if (udf != null) return udf;
    final iso = await _tryMountIso9660(cached);
    if (iso != null) return iso;
    throw const FormatException('无法识别该镜像的 UDF 2.50 或 ISO-9660 文件系统');
  }

  static Future<IsoFilesystem?> _tryMountUdf(_SectorCachedReader reader) async {
    Uint8List avdp = await reader.readSector(256);
    if (avdp.length < 32 || _u16LE(avdp, 0) != 2) {
      final total = await reader.totalLength();
      if (total != null && total >= 258 * sectorSize) {
        final totalSectors = total ~/ sectorSize;
        for (final candidate in [totalSectors - 257, totalSectors - 1]) {
          if (candidate > 256) {
            final alt = await reader.readSector(candidate);
            if (alt.length >= 32 && _u16LE(alt, 0) == 2) {
              avdp = alt;
              break;
            }
          }
        }
      }
    }
    if (avdp.length < 32 || _u16LE(avdp, 0) != 2) return null;

    final mvdsLength = _u32LE(avdp, 16);
    final mvdsLocation = _u32LE(avdp, 20);
    if (mvdsLength < sectorSize || mvdsLocation <= 0) return null;

    final mvdsSectors = math.min((mvdsLength + sectorSize - 1) ~/ sectorSize, 64);
    final fs = IsoFilesystem._udf(reader, sectorSize);

    int? lvdBlockSize;
    int fsdLength = 0;
    int fsdBlock = 0;
    int fsdPartRef = 0;
    final rawMaps = <_UdfPartitionMap>[];

    for (var i = 0; i < mvdsSectors; i++) {
      final sec = await reader.readSector(mvdsLocation + i);
      if (sec.length < 16) break;
      final tagId = _u16LE(sec, 0);
      if (tagId == 8) break; // Terminating Descriptor
      if (tagId == 5 && sec.length >= 196) {
        // Partition Descriptor
        final partNum = _u16LE(sec, 22);
        final startSec = _u32LE(sec, 188);
        final lenSec = _u32LE(sec, 192);
        fs._udfPhysPartitions[partNum] =
            (startSector: startSec, lengthSectors: lenSec);
      } else if (tagId == 6 && sec.length >= 440) {
        // Logical Volume Descriptor
        final bs = _u32LE(sec, 212);
        lvdBlockSize = bs > 0 ? bs : sectorSize;
        fsdLength = _u32LE(sec, 248);
        fsdBlock = _u32LE(sec, 252);
        fsdPartRef = _u16LE(sec, 256);
        final mapTableLen = _u32LE(sec, 264);
        final numMaps = _u32LE(sec, 268);
        var mapOff = 440;
        final mapLimit = math.min(sec.length, 440 + mapTableLen);
        for (var m = 0; m < numMaps && mapOff + 2 <= mapLimit; m++) {
          final mType = sec[mapOff];
          final mLen = sec[mapOff + 1];
          if (mLen < 2 || mapOff + mLen > mapLimit) break;
          if (mType == 1 && mLen >= 6) {
            final pNum = _u16LE(sec, mapOff + 4);
            rawMaps.add(_UdfPartitionMap.physical(partitionNumber: pNum));
          } else if (mType == 2 && mLen >= 64) {
            final pNum = _u16LE(sec, mapOff + 38);
            final metaLoc = _u32LE(sec, mapOff + 40);
            final metaMirrorLoc = _u32LE(sec, mapOff + 44);
            rawMaps.add(_UdfPartitionMap.metadata(
              partitionNumber: pNum,
              metadataFileLoc: metaLoc,
              metadataMirrorLoc: metaMirrorLoc,
            ));
          } else {
            rawMaps.add(_UdfPartitionMap.physical(partitionNumber: 0));
          }
          mapOff += mLen;
        }
      }
    }

    if (fs._udfPhysPartitions.isEmpty || lvdBlockSize == null || fsdLength == 0) {
      return null;
    }

    final mounted = IsoFilesystem._udf(reader, lvdBlockSize)
      .._udfPhysPartitions.addAll(fs._udfPhysPartitions);
    for (var i = 0; i < rawMaps.length; i++) {
      mounted._udfMaps[i] = rawMaps[i];
    }
    if (mounted._udfMaps.isEmpty) {
      mounted._udfMaps[0] =
          _UdfPartitionMap.physical(partitionNumber: fs._udfPhysPartitions.keys.first);
    }

    // Resolve any Type 2 UDF 2.50 Metadata Partition maps
    for (var i = 0; i < rawMaps.length; i++) {
      final map = rawMaps[i];
      if (!map.isMetadata) continue;
      final phys = mounted._udfPhysPartitions[map.partitionNumber];
      if (phys == null) continue;
      for (final candidateLoc in [map.metadataFileLoc, map.metadataMirrorLoc]) {
        if (candidateLoc == 0 && map.metadataMirrorLoc != 0) continue;
        final feOffset = (phys.startSector + candidateLoc) * lvdBlockSize;
        final feBytes = await reader.readBytes(feOffset, lvdBlockSize);
        final parsed = await mounted._parseUdfFileEntryRaw(
          feBytes,
          defaultPartRef: i,
          forcePhysicalPartNum: map.partitionNumber,
        );
        if (parsed != null && parsed.extents.isNotEmpty) {
          mounted._udfMetadataExtents[i] = parsed.extents;
          break;
        }
      }
    }

    // Read File Set Descriptor (FSD)
    final fsdOff = mounted._resolveUdfBlockOffset(fsdPartRef, fsdBlock);
    if (fsdOff == null) return null;
    final fsdBytes = await reader.readBytes(fsdOff, lvdBlockSize);
    if (fsdBytes.length < 416 || _u16LE(fsdBytes, 0) != 256) return null;

    final rootBlock = _u32LE(fsdBytes, 404);
    final rootPartRef = _u16LE(fsdBytes, 408);
    mounted._udfRootIcb = (block: rootBlock, partitionRef: rootPartRef);
    return mounted;
  }

  int? _resolveUdfBlockOffset(int partitionRef, int logicalBlock) {
    final map = _udfMaps[partitionRef];
    if (map == null) {
      final firstPhys = _udfPhysPartitions.values.firstOrNull;
      if (firstPhys == null) return null;
      return (firstPhys.startSector + logicalBlock) * _blockSize;
    }
    if (!map.isMetadata) {
      final phys = _udfPhysPartitions[map.partitionNumber];
      if (phys == null) return null;
      return (phys.startSector + logicalBlock) * _blockSize;
    }
    final metaExtents = _udfMetadataExtents[partitionRef];
    if (metaExtents == null || metaExtents.isEmpty) {
      final phys = _udfPhysPartitions[map.partitionNumber];
      if (phys == null) return null;
      return (phys.startSector + logicalBlock) * _blockSize;
    }
    var byteInMeta = logicalBlock * _blockSize;
    for (final ext in metaExtents) {
      if (byteInMeta < ext.length) {
        return ext.isoOffset + byteInMeta;
      }
      byteInMeta -= ext.length;
    }
    return null;
  }

  Future<({bool isDir, int size, List<IsoExtent> extents, Uint8List? inlineData})?>
      _parseUdfFileEntryRaw(
    Uint8List fe, {
    required int defaultPartRef,
    int? forcePhysicalPartNum,
  }) async {
    if (fe.length < 176) return null;
    final tagId = _u16LE(fe, 0);
    if (tagId != 261 && tagId != 266) return null;
    final fileType = fe[27];
    final isDir = fileType == 4;
    final icbFlags = _u16LE(fe, 34);
    final allocType = icbFlags & 0x07;
    final infoLen = _u64LE(fe, 56);

    final int lEa;
    final int lAd;
    final int adBase;
    if (tagId == 266) {
      if (fe.length < 216) return null;
      lEa = _u32LE(fe, 208);
      lAd = _u32LE(fe, 212);
      adBase = 216 + lEa;
    } else {
      lEa = _u32LE(fe, 168);
      lAd = _u32LE(fe, 172);
      adBase = 176 + lEa;
    }

    if (adBase > fe.length || lAd < 0) return null;
    final adEnd = math.min(fe.length, adBase + lAd);

    if (allocType == 3) {
      final inline = Uint8List.sublistView(
        fe,
        adBase,
        math.min(adEnd, adBase + infoLen),
      );
      return (isDir: isDir, size: infoLen, extents: const <IsoExtent>[], inlineData: inline);
    }

    final extents = <IsoExtent>[];
    Future<void> parseAdList(Uint8List buf, int start, int end) async {
      var pos = start;
      if (allocType == 0) {
        // short_ad (8 bytes)
        while (pos + 8 <= end) {
          final rawLen = _u32LE(buf, pos);
          final extType = (rawLen >> 30) & 0x03;
          final len = rawLen & 0x3FFFFFFF;
          final blk = _u32LE(buf, pos + 4);
          pos += 8;
          if (len == 0) continue;
          final int? isoOff;
          if (forcePhysicalPartNum != null) {
            final phys = _udfPhysPartitions[forcePhysicalPartNum];
            isoOff = phys == null ? null : (phys.startSector + blk) * _blockSize;
          } else {
            isoOff = _resolveUdfBlockOffset(defaultPartRef, blk);
          }
          if (extType == 3 && isoOff != null) {
            final aed = await _reader.readBytes(isoOff, _blockSize);
            if (aed.length >= 24 && _u16LE(aed, 0) == 258) {
              final nextLAd = _u32LE(aed, 20);
              await parseAdList(aed, 24, math.min(aed.length, 24 + nextLAd));
            }
          } else if (extType == 0 && isoOff != null) {
            extents.add(IsoExtent(isoOffset: isoOff, length: len));
          }
        }
      } else if (allocType == 1) {
        // long_ad (16 bytes)
        while (pos + 16 <= end) {
          final rawLen = _u32LE(buf, pos);
          final extType = (rawLen >> 30) & 0x03;
          final len = rawLen & 0x3FFFFFFF;
          final blk = _u32LE(buf, pos + 4);
          final pRef = _u16LE(buf, pos + 8);
          pos += 16;
          if (len == 0) continue;
          final isoOff = _resolveUdfBlockOffset(pRef, blk);
          if (extType == 3 && isoOff != null) {
            final aed = await _reader.readBytes(isoOff, _blockSize);
            if (aed.length >= 24 && _u16LE(aed, 0) == 258) {
              final nextLAd = _u32LE(aed, 20);
              await parseAdList(aed, 24, math.min(aed.length, 24 + nextLAd));
            }
          } else if (extType == 0 && isoOff != null) {
            extents.add(IsoExtent(isoOffset: isoOff, length: len));
          }
        }
      }
    }

    await parseAdList(fe, adBase, adEnd);
    return (isDir: isDir, size: infoLen, extents: extents, inlineData: null);
  }

  static String _decodeUdfDstring(Uint8List bytes) {
    if (bytes.isEmpty) return '';
    final compId = bytes[0];
    if (compId == 8) {
      return latin1.decode(bytes.sublist(1), allowInvalid: true);
    }
    if (compId == 16) {
      final units = <int>[];
      for (var i = 1; i + 1 < bytes.length; i += 2) {
        units.add((bytes[i] << 8) | bytes[i + 1]);
      }
      return String.fromCharCodes(units);
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  Future<Uint8List> _readUdfEntryBytes(
    ({bool isDir, int size, List<IsoExtent> extents, Uint8List? inlineData}) entry, {
    int maxBytes = 4 * 1024 * 1024,
  }) async {
    if (entry.inlineData != null) return entry.inlineData!;
    final targetLen = math.min(entry.size, maxBytes);
    final out = BytesBuilder(copy: false);
    for (final ext in entry.extents) {
      if (out.length >= targetLen) break;
      final need = math.min(ext.length, targetLen - out.length);
      final chunk = await _reader.readBytes(ext.isoOffset, need);
      if (chunk.isNotEmpty) out.add(chunk);
    }
    return out.takeBytes();
  }

  static Future<IsoFilesystem?> _tryMountIso9660(_SectorCachedReader reader) async {
    int? pvdBlockSize;
    int? pvdRootSector;
    int? pvdRootSize;
    int? jolietBlockSize;
    int? jolietRootSector;
    int? jolietRootSize;

    for (var secIdx = 16; secIdx < 32; secIdx++) {
      final sec = await reader.readSector(secIdx);
      if (sec.length < 190) break;
      if (sec[1] != 0x43 ||
          sec[2] != 0x44 ||
          sec[3] != 0x30 ||
          sec[4] != 0x30 ||
          sec[5] != 0x31) {
        break;
      }
      final volType = sec[0];
      if (volType == 255) break;
      if (volType == 1 && pvdRootSector == null) {
        final bs = _u16LE(sec, 128);
        pvdBlockSize = bs > 0 ? bs : sectorSize;
        pvdRootSector = _u32LE(sec, 156 + 2);
        pvdRootSize = _u32LE(sec, 156 + 10);
      } else if (volType == 2) {
        // Joliet SVD check (escape sequences at offset 88..90: %/@, %/C, %/E)
        final esc0 = sec[88];
        final esc1 = sec[89];
        final esc2 = sec[90];
        if (esc0 == 0x25 &&
            esc1 == 0x2F &&
            (esc2 == 0x40 || esc2 == 0x43 || esc2 == 0x45)) {
          final bs = _u16LE(sec, 128);
          jolietBlockSize = bs > 0 ? bs : sectorSize;
          jolietRootSector = _u32LE(sec, 156 + 2);
          jolietRootSize = _u32LE(sec, 156 + 10);
        }
      }
    }

    if (jolietRootSector != null && jolietRootSize != null && jolietRootSize > 0) {
      return IsoFilesystem._iso9660(
        reader,
        jolietBlockSize ?? sectorSize,
        (extentSector: jolietRootSector, size: jolietRootSize, isJoliet: true),
      );
    }
    if (pvdRootSector != null && pvdRootSize != null && pvdRootSize > 0) {
      return IsoFilesystem._iso9660(
        reader,
        pvdBlockSize ?? sectorSize,
        (extentSector: pvdRootSector, size: pvdRootSize, isJoliet: false),
      );
    }
    return null;
  }

  /// Lists immediate entries of a directory path like `['BDMV', 'PLAYLIST']`
  /// (case-insensitive) without scanning unrelated directories.
  Future<List<({String name, bool isDir, IsoFileEntry? file})>> listDirectory(
    List<String> pathSegments,
  ) async {
    if (isUdf) {
      return _listUdfDirectory(pathSegments);
    }
    return _listIso9660Directory(pathSegments);
  }

  Future<List<({String name, bool isDir, IsoFileEntry? file})>>
      _listUdfDirectory(List<String> pathSegments) async {
    var cur = _udfRootIcb;
    if (cur == null) return const [];

    Future<List<({String name, bool isDir, int block, int partRef})>>
        readDirChildren(int block, int partRef) async {
      final feOff = _resolveUdfBlockOffset(partRef, block);
      if (feOff == null) return const [];
      final feBytes = await _reader.readBytes(feOff, _blockSize);
      final parsed = await _parseUdfFileEntryRaw(
        feBytes,
        defaultPartRef: partRef,
      );
      if (parsed == null || !parsed.isDir) return const [];
      final dirData = await _readUdfEntryBytes(parsed);
      final out = <({String name, bool isDir, int block, int partRef})>[];
      var pos = 0;
      while (pos + 38 <= dirData.length) {
        final tagId = _u16LE(dirData, pos);
        if (tagId != 257) break;
        final chars = dirData[pos + 18];
        final lFi = dirData[pos + 19];
        final childBlock = _u32LE(dirData, pos + 24);
        final childPartRef = _u16LE(dirData, pos + 28);
        final lIu = _u16LE(dirData, pos + 36);
        final recordLen = ((38 + lIu + lFi + 3) ~/ 4) * 4;
        if (pos + 38 + lIu + lFi > dirData.length) break;
        final isDeleted = (chars & 0x04) != 0;
        final isParent = (chars & 0x08) != 0;
        if (!isDeleted && !isParent && lFi > 0) {
          final name = _decodeUdfDstring(
            Uint8List.sublistView(
              dirData,
              pos + 38 + lIu,
              pos + 38 + lIu + lFi,
            ),
          ).trim();
          if (name.isNotEmpty) {
            out.add((
              name: name,
              isDir: (chars & 0x02) != 0,
              block: childBlock,
              partRef: childPartRef,
            ));
          }
        }
        pos += recordLen;
      }
      return out;
    }

    for (final seg in pathSegments) {
      final target = seg.toLowerCase();
      final children = await readDirChildren(cur!.block, cur.partitionRef);
      final match = children.where(
        (c) => c.isDir && c.name.toLowerCase() == target,
      );
      if (match.isEmpty) return const [];
      cur = (block: match.first.block, partitionRef: match.first.partRef);
    }

    final children = await readDirChildren(cur!.block, cur.partitionRef);
    final result = <({String name, bool isDir, IsoFileEntry? file})>[];
    for (final c in children) {
      if (c.isDir) {
        result.add((name: c.name, isDir: true, file: null));
      } else {
        final feOff = _resolveUdfBlockOffset(c.partRef, c.block);
        if (feOff == null) continue;
        final feBytes = await _reader.readBytes(feOff, _blockSize);
        final parsed = await _parseUdfFileEntryRaw(
          feBytes,
          defaultPartRef: c.partRef,
        );
        if (parsed != null && !parsed.isDir) {
          result.add((
            name: c.name,
            isDir: false,
            file: IsoFileEntry(
              name: c.name,
              size: parsed.size,
              extents: parsed.extents,
              inlineData: parsed.inlineData,
            ),
          ));
        }
      }
    }
    return result;
  }

  Future<List<({String name, bool isDir, IsoFileEntry? file})>>
      _listIso9660Directory(List<String> pathSegments) async {
    final root = _iso9660Root;
    if (root == null) return const [];
    var curSector = root.extentSector;
    var curSize = root.size;
    final isJoliet = root.isJoliet;

    Future<List<({String name, bool isDir, int sector, int size})>>
        readDir(int sector, int size) async {
      final bytes = await _reader.readBytes(sector * _blockSize, size);
      final out = <({String name, bool isDir, int sector, int size})>[];
      var pos = 0;
      while (pos < bytes.length) {
        final recLen = bytes[pos];
        if (recLen == 0) {
          final nextSectorBoundary = ((pos ~/ _blockSize) + 1) * _blockSize;
          if (nextSectorBoundary >= bytes.length) break;
          pos = nextSectorBoundary;
          continue;
        }
        if (pos + 34 > bytes.length || pos + recLen > bytes.length) break;
        final extLoc = _u32LE(bytes, pos + 2);
        final dataLen = _u32LE(bytes, pos + 10);
        final flags = bytes[pos + 25];
        final nameLen = bytes[pos + 32];
        if (pos + 33 + nameLen <= bytes.length && nameLen > 0) {
          final rawName =
              Uint8List.sublistView(bytes, pos + 33, pos + 33 + nameLen);
          final isSpecial = nameLen == 1 && (rawName[0] == 0 || rawName[0] == 1);
          if (!isSpecial) {
            String name;
            if (isJoliet) {
              final units = <int>[];
              for (var i = 0; i + 1 < rawName.length; i += 2) {
                units.add((rawName[i] << 8) | rawName[i + 1]);
              }
              name = String.fromCharCodes(units);
            } else {
              name = latin1.decode(rawName, allowInvalid: true);
            }
            final semi = name.indexOf(';');
            if (semi >= 0) name = name.substring(0, semi);
            name = name.trim();
            if (name.isNotEmpty) {
              out.add((
                name: name,
                isDir: (flags & 0x02) != 0,
                sector: extLoc,
                size: dataLen,
              ));
            }
          }
        }
        pos += recLen;
      }
      return out;
    }

    for (final seg in pathSegments) {
      final target = seg.toLowerCase();
      final children = await readDir(curSector, curSize);
      final match = children.where(
        (c) => c.isDir && c.name.toLowerCase() == target,
      );
      if (match.isEmpty) return const [];
      curSector = match.first.sector;
      curSize = match.first.size;
    }

    final children = await readDir(curSector, curSize);
    return [
      for (final c in children)
        if (c.isDir)
          (name: c.name, isDir: true, file: null)
        else
          (
            name: c.name,
            isDir: false,
            file: IsoFileEntry(
              name: c.name,
              size: c.size,
              extents: [
                IsoExtent(isoOffset: c.sector * _blockSize, length: c.size),
              ],
            ),
          ),
    ];
  }

  Future<Uint8List> readFileBytes(IsoFileEntry file, {int maxBytes = 4 * 1024 * 1024}) async {
    if (file.inlineData != null) return file.inlineData!;
    final targetLen = math.min(file.size, maxBytes);
    final out = BytesBuilder(copy: false);
    for (final ext in file.extents) {
      if (out.length >= targetLen) break;
      final need = math.min(ext.length, targetLen - out.length);
      final chunk = await _reader.readBytes(ext.isoOffset, need);
      if (chunk.isNotEmpty) out.add(chunk);
    }
    return out.takeBytes();
  }
}

class _UdfPartitionMap {
  final int partitionNumber;
  final bool isMetadata;
  final int metadataFileLoc;
  final int metadataMirrorLoc;

  const _UdfPartitionMap.physical({required this.partitionNumber})
      : isMetadata = false,
        metadataFileLoc = 0,
        metadataMirrorLoc = 0;

  const _UdfPartitionMap.metadata({
    required this.partitionNumber,
    required this.metadataFileLoc,
    required this.metadataMirrorLoc,
  }) : isMetadata = true;
}

class _ParsedMplsPlayItem {
  final String clipName;
  final int inTimeTicks;
  final int outTimeTicks;
  double get durationSeconds =>
      outTimeTicks > inTimeTicks ? (outTimeTicks - inTimeTicks) / 45000.0 : 0.0;

  const _ParsedMplsPlayItem({
    required this.clipName,
    required this.inTimeTicks,
    required this.outTimeTicks,
  });
}

class _ParsedMplsPlaylist {
  final String fileName;
  final List<_ParsedMplsPlayItem> playItems;
  final List<BlurayChapter> chapters;
  final double totalDurationSeconds;

  const _ParsedMplsPlaylist({
    required this.fileName,
    required this.playItems,
    required this.chapters,
    required this.totalDurationSeconds,
  });

  static int _u16BE(Uint8List b, int off) => (b[off] << 8) | b[off + 1];
  static int _u32BE(Uint8List b, int off) =>
      ((b[off] << 24) | (b[off + 1] << 16) | (b[off + 2] << 8) | b[off + 3]) &
      0xFFFFFFFF;

  static _ParsedMplsPlaylist? parse(String fileName, Uint8List bytes) {
    if (bytes.length < 40) return null;
    final magic = ascii.decode(bytes.sublist(0, 4), allowInvalid: true);
    if (magic != 'MPLS') return null;

    final playlistStart = _u32BE(bytes, 8);
    final markStart = _u32BE(bytes, 12);
    if (playlistStart < 40 || playlistStart + 10 > bytes.length) return null;

    final numPlayItems = _u16BE(bytes, playlistStart + 6);
    var pos = playlistStart + 10;
    final items = <_ParsedMplsPlayItem>[];
    final itemStartOffsetsSec = <double>[];
    var runningDurationSec = 0.0;

    for (var i = 0; i < numPlayItems && pos + 2 <= bytes.length; i++) {
      final itemLen = _u16BE(bytes, pos);
      if (itemLen < 20 || pos + 2 + itemLen > bytes.length) break;
      final itemBase = pos + 2;
      final clipName = ascii
          .decode(bytes.sublist(itemBase, itemBase + 5), allowInvalid: true)
          .trim();
      final inTime = _u32BE(bytes, itemBase + 14);
      final outTime = _u32BE(bytes, itemBase + 18);
      final item = _ParsedMplsPlayItem(
        clipName: clipName,
        inTimeTicks: inTime,
        outTimeTicks: outTime,
      );
      itemStartOffsetsSec.add(runningDurationSec);
      runningDurationSec += item.durationSeconds;
      items.add(item);
      pos += 2 + itemLen;
    }

    if (items.isEmpty) return null;

    // Parse PlayListMark (chapters)
    final rawMarks = <({Duration pos, String? title})>[];
    if (markStart > 0 && markStart + 6 <= bytes.length) {
      final numMarks = _u16BE(bytes, markStart + 4);
      var mPos = markStart + 6;
      for (var i = 0; i < numMarks && mPos + 14 <= bytes.length; i++) {
        final markType = bytes[mPos + 1];
        final refPlayItemId = _u16BE(bytes, mPos + 2);
        final markTs = _u32BE(bytes, mPos + 4);
        mPos += 14;
        if (markType == 0x01 && refPlayItemId < items.length) {
          final item = items[refPlayItemId];
          final relTicks = math.max(0, markTs - item.inTimeTicks);
          final absSec = itemStartOffsetsSec[refPlayItemId] + relTicks / 45000.0;
          rawMarks.add((
            pos: Duration(milliseconds: (absSec * 1000).round()),
            title: null,
          ));
        }
      }
    }

    rawMarks.sort((a, b) => a.pos.compareTo(b.pos));
    final chapters = <BlurayChapter>[];
    for (var i = 0; i < rawMarks.length; i++) {
      final cur = rawMarks[i];
      if (chapters.isNotEmpty &&
          (cur.pos - chapters.last.position).abs() <
              const Duration(milliseconds: 500)) {
        continue;
      }
      chapters.add(BlurayChapter(
        index: chapters.length,
        title: '第 ${chapters.length + 1} 章',
        position: cur.pos,
      ));
    }

    final totalMs = (runningDurationSec * 1000).round();
    final withDurations = <BlurayChapter>[];
    for (var i = 0; i < chapters.length; i++) {
      final ch = chapters[i];
      final nextPos = i + 1 < chapters.length
          ? chapters[i + 1].position
          : Duration(milliseconds: totalMs);
      final dur = nextPos > ch.position ? nextPos - ch.position : Duration.zero;
      withDurations.add(BlurayChapter(
        index: ch.index,
        title: ch.title,
        position: ch.position,
        duration: dur,
      ));
    }

    return _ParsedMplsPlaylist(
      fileName: fileName,
      playItems: items,
      chapters: List<BlurayChapter>.unmodifiable(withDurations),
      totalDurationSeconds: runningDurationSec,
    );
  }
}

class _VirtualSegmentMapping {
  final int virtualStart;
  final int virtualEnd;
  final IsoFileEntry file;
  const _VirtualSegmentMapping({
    required this.virtualStart,
    required this.virtualEnd,
    required this.file,
  });
}

/// Active local HTTP 206 streaming gateway exposing a multi-segment Blu-ray
/// `.m2ts` (or DVD `.vob`) virtual stream directly to `libmpv`.
class BlurayIsoLease {
  static const int _streamChunkSize = 256 * 1024;
  static const int _maxConcurrentRequests = 16;

  final HttpServer _server;
  final IsoRangeReader _reader;
  final String _capability;
  final bool Function() _isCancelled;
  final List<_VirtualSegmentMapping> _segments;
  final BlurayPlaylistInfo playlistInfo;
  final String _contentType;
  final Set<HttpRequest> _activeRequests = <HttpRequest>{};
  late final Uri _url;
  Timer? _sweepTimer;
  bool _closed = false;

  BlurayIsoLease._(
    this._server,
    this._reader,
    this._capability,
    this._isCancelled,
    this._segments,
    this.playlistInfo,
    String fileExt,
    this._contentType,
  ) {
    _url = Uri.parse('http://127.0.0.1:${_server.port}/$_capability/stream$fileExt');
    _server.listen(_serve);
    _sweepTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (!_closed && _isCancelled()) {
        unawaited(close());
      }
    });
  }

  Uri get url => _url;
  List<BlurayChapter> get chapters => playlistInfo.chapters;
  int get totalBytes => playlistInfo.totalBytes;
  bool get isClosed => _closed;

  bool _isAllowedRequest(HttpRequest request) {
    final hostHeader = request.headers.value(HttpHeaders.hostHeader);
    if (hostHeader != null && hostHeader.isNotEmpty) {
      final hostOnly = hostHeader.startsWith('[')
          ? hostHeader.substring(0, hostHeader.indexOf(']') + 1)
          : hostHeader.split(':').first;
      if (!LocalMediaLease.isLoopbackHost(hostOnly)) return false;
    }
    final origin = request.headers.value('origin');
    if (origin != null && origin.isNotEmpty) return false;
    if (request.uri.path != _url.path) return false;
    return true;
  }

  Future<void> _serve(HttpRequest request) async {
    if (_closed || _isCancelled()) {
      request.response.statusCode = HttpStatus.gone;
      await request.response.close();
      return;
    }
    if (!_isAllowedRequest(request)) {
      request.response.statusCode = HttpStatus.forbidden;
      await request.response.close();
      return;
    }
    if (request.method != 'GET' && request.method != 'HEAD') {
      request.response.statusCode = HttpStatus.methodNotAllowed;
      await request.response.close();
      return;
    }
    if (_activeRequests.length >= _maxConcurrentRequests) {
      request.response.statusCode = HttpStatus.serviceUnavailable;
      await request.response.close();
      return;
    }

    _activeRequests.add(request);
    try {
      final total = playlistInfo.totalBytes;
      final rawRange = request.headers.value(HttpHeaders.rangeHeader);
      final parsedRange = _parseRange(rawRange, total);
      if (rawRange != null && parsedRange == null) {
        request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        request.response.headers.set('content-range', 'bytes */$total');
        return;
      }

      final isRange = parsedRange != null;
      final reqStart = parsedRange?.start ?? 0;
      final reqEnd = parsedRange?.end ?? (total > 0 ? total - 1 : 0);
      final contentLen = total == 0 ? 0 : (reqEnd - reqStart + 1);

      request.response.bufferOutput = false;
      request.response.statusCode =
          isRange ? HttpStatus.partialContent : HttpStatus.ok;
      request.response.headers.set('accept-ranges', 'bytes');
      request.response.headers.set('content-type', _contentType);
      request.response.headers.set('cache-control', 'no-store');
      if (isRange) {
        request.response.headers.set(
          'content-range',
          'bytes $reqStart-$reqEnd/$total',
        );
      }
      request.response.contentLength = contentLen;

      if (request.method == 'HEAD' || contentLen == 0) {
        return;
      }

      await _streamVirtualRange(reqStart, reqEnd, request.response);
    } catch (_) {
      try {
        request.response.statusCode = HttpStatus.badGateway;
      } catch (_) {}
    } finally {
      _activeRequests.remove(request);
      try {
        await request.response.close();
      } catch (_) {}
    }
  }

  static ({int start, int end})? _parseRange(String? raw, int total) {
    if (raw == null || raw.trim().isEmpty) return null;
    final trimmed = raw.trim();
    if (!trimmed.toLowerCase().startsWith('bytes=')) return null;
    final spec = trimmed.substring(6).split(',').first.trim();
    final dash = spec.indexOf('-');
    if (dash < 0 || total <= 0) return null;
    final left = spec.substring(0, dash).trim();
    final right = spec.substring(dash + 1).trim();
    if (left.isEmpty) {
      final suffix = int.tryParse(right);
      if (suffix == null || suffix <= 0) return null;
      final start = math.max(0, total - suffix);
      return (start: start, end: total - 1);
    }
    final start = int.tryParse(left);
    if (start == null || start < 0 || start >= total) return null;
    final end = right.isEmpty ? total - 1 : int.tryParse(right);
    if (end == null || end < start) return null;
    return (start: start, end: math.min(end, total - 1));
  }

  Future<void> _streamVirtualRange(
    int reqStart,
    int reqEnd,
    HttpResponse sink,
  ) async {
    // Binary search first segment containing reqStart
    var lo = 0;
    var hi = _segments.length - 1;
    var segIdx = 0;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      final seg = _segments[mid];
      if (reqStart < seg.virtualStart) {
        hi = mid - 1;
      } else if (reqStart > seg.virtualEnd) {
        lo = mid + 1;
      } else {
        segIdx = mid;
        break;
      }
    }

    var cursor = reqStart;
    while (cursor <= reqEnd && segIdx < _segments.length) {
      if (_closed || _isCancelled()) break;
      final seg = _segments[segIdx];
      if (cursor > seg.virtualEnd) {
        segIdx++;
        continue;
      }
      final segEndWant = math.min(reqEnd, seg.virtualEnd);
      var inFileOffset = cursor - seg.virtualStart;
      final inFileEnd = segEndWant - seg.virtualStart;

      if (seg.file.inlineData != null) {
        final slice = Uint8List.sublistView(
          seg.file.inlineData!,
          inFileOffset,
          inFileEnd + 1,
        );
        sink.add(slice);
        cursor += slice.length;
        segIdx++;
        continue;
      }

      // Walk physical ISO extents for this segment
      var extBaseInFile = 0;
      for (final ext in seg.file.extents) {
        if (cursor > segEndWant || _closed || _isCancelled()) break;
        final extEndInFile = extBaseInFile + ext.length - 1;
        if (inFileOffset <= extEndInFile) {
          var extReadOffset = ext.isoOffset + (inFileOffset - extBaseInFile);
          var remainingInExt =
              math.min(extEndInFile, inFileEnd) - inFileOffset + 1;
          while (remainingInExt > 0 && !_closed && !_isCancelled()) {
            final take = math.min(remainingInExt, _streamChunkSize);
            final data = await _reader.readAt(extReadOffset, take);
            if (data.isEmpty) {
              throw const FormatException('ISO 读取意外提前结束');
            }
            sink.add(data);
            extReadOffset += data.length;
            inFileOffset += data.length;
            cursor += data.length;
            remainingInExt -= data.length;
          }
        }
        extBaseInFile += ext.length;
      }
      segIdx++;
    }
    if (!_closed && !_isCancelled()) {
      await sink.flush().timeout(const Duration(seconds: 30));
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _sweepTimer?.cancel();
    await _reader.close();
    await _server.close(force: true);
  }
}

/// On-demand Blu-ray `.iso` (and DVD `.iso`) streaming proxy.
///
/// Parses ISO-9660 / UDF 2.50 directory trees and `.mpls` playlists using only
/// targeted `2 KiB` Range reads (without downloading multi-gigabyte images),
/// filters suspected loop/fake playlists, and exposes a contiguous virtual
/// `.m2ts` HTTP 206 stream with chapter markers for `libmpv`.
class BlurayIsoProxy {
  static bool isIsoTarget(String rawUrlOrPath) {
    final trimmed = rawUrlOrPath.trim();
    if (trimmed.isEmpty) return false;
    final lower = trimmed.toLowerCase();
    if (lower.startsWith('http://') ||
        lower.startsWith('https://') ||
        lower.startsWith('file://')) {
      final uri = Uri.tryParse(trimmed);
      final path = (uri?.path ?? trimmed).toLowerCase();
      return path.endsWith('.iso');
    }
    final cleanPath = trimmed.split('?').first.split('#').first.toLowerCase();
    return cleanPath.endsWith('.iso');
  }

  static IsoRangeReader _openReader(
    String target, {
    Map<String, String> headers = const {},
    http.Client? client,
  }) {
    final trimmed = target.trim();
    final lower = trimmed.toLowerCase();
    if (lower.startsWith('http://') || lower.startsWith('https://')) {
      return HttpRangeIsoReader(
        Uri.parse(trimmed),
        headers: headers,
        client: client,
      );
    }
    if (lower.startsWith('file://')) {
      return LocalFileIsoReader(File.fromUri(Uri.parse(trimmed)));
    }
    return LocalFileIsoReader(File(trimmed));
  }

  static bool _isSuspectedFakeLoopPlaylist(_ParsedMplsPlaylist pl) {
    final items = pl.playItems;
    if (items.length <= 1) return false;
    final counts = <String, int>{};
    var consecutiveDupes = 0;
    for (var i = 0; i < items.length; i++) {
      final key = items[i].clipName.toUpperCase();
      counts[key] = (counts[key] ?? 0) + 1;
      if (i > 0 && items[i - 1].clipName.toUpperCase() == key) {
        consecutiveDupes++;
      }
    }
    if (consecutiveDupes >= 2) return true;
    final maxSingleCount =
        counts.values.fold<int>(0, (a, b) => a > b ? a : b);
    if (maxSingleCount >= 3) return true;
    if (items.length >= 6 && counts.length * 1.5 < items.length) return true;
    if (items.length > 40 && counts.length < items.length * 0.7) return true;
    return false;
  }

  static Future<BlurayIsoLease> open({
    required String target,
    Map<String, String> headers = const {},
    bool Function()? isCancelled,
    http.Client? client,
    IsoRangeReader? readerOverride,
  }) async {
    final reader = readerOverride ??
        _openReader(target, headers: headers, client: client);
    HttpServer? server;
    try {
      final fs = await IsoFilesystem.mount(reader);

      // 1. Try Blu-ray BDMV structure
      final streamDir = await fs.listDirectory(const ['BDMV', 'STREAM']);
      final m2tsByClip = <String, IsoFileEntry>{};
      for (final entry in streamDir) {
        if (entry.isDir || entry.file == null) continue;
        final upperName = entry.name.toUpperCase();
        if (upperName.endsWith('.M2TS')) {
          final clip = upperName.substring(0, upperName.length - 5);
          m2tsByClip[clip] = entry.file!;
        }
      }

      final playlistDir = await fs.listDirectory(const ['BDMV', 'PLAYLIST']);
      final candidates = <({
        _ParsedMplsPlaylist playlist,
        List<IsoFileEntry> files,
        int totalBytes,
        bool isFakeLoop,
      })>[];

      for (final entry in playlistDir) {
        if (entry.isDir || entry.file == null) continue;
        if (!entry.name.toUpperCase().endsWith('.MPLS')) continue;
        final mplsBytes =
            await fs.readFileBytes(entry.file!, maxBytes: 4 * 1024 * 1024);
        final parsed = _ParsedMplsPlaylist.parse(entry.name, mplsBytes);
        if (parsed == null) continue;

        final files = <IsoFileEntry>[];
        var valid = true;
        var totalBytes = 0;
        for (final item in parsed.playItems) {
          final f = m2tsByClip[item.clipName.toUpperCase()];
          if (f == null || f.size <= 0) {
            valid = false;
            break;
          }
          files.add(f);
          totalBytes += f.size;
        }
        if (!valid || files.isEmpty || totalBytes <= 0) continue;

        candidates.add((
          playlist: parsed,
          files: files,
          totalBytes: totalBytes,
          isFakeLoop: _isSuspectedFakeLoopPlaylist(parsed),
        ));
      }

      List<IsoFileEntry> selectedFiles = const [];
      BlurayPlaylistInfo? playlistInfo;
      var fileExt = '.m2ts';
      var contentType = 'video/mp2t';

      if (candidates.isNotEmpty) {
        final clean = candidates.where((c) => !c.isFakeLoop).toList();
        final pool = clean.isNotEmpty ? clean : candidates;
        pool.sort((a, b) {
          final durCmp = b.playlist.totalDurationSeconds
              .compareTo(a.playlist.totalDurationSeconds);
          if (durCmp != 0) return durCmp;
          final sizeCmp = b.totalBytes.compareTo(a.totalBytes);
          if (sizeCmp != 0) return sizeCmp;
          return a.playlist.fileName.compareTo(b.playlist.fileName);
        });
        final best = pool.first;
        selectedFiles = best.files;
        playlistInfo = BlurayPlaylistInfo(
          playlistName: best.playlist.fileName,
          totalDuration: Duration(
            milliseconds: (best.playlist.totalDurationSeconds * 1000).round(),
          ),
          clipNames: [for (final f in best.files) f.name],
          chapters: best.playlist.chapters,
          totalBytes: best.totalBytes,
        );
      } else if (m2tsByClip.isNotEmpty) {
        // Fallback: longest standalone .m2ts in BDMV/STREAM
        final sorted = m2tsByClip.values.toList()
          ..sort((a, b) => b.size.compareTo(a.size));
        final best = sorted.first;
        selectedFiles = [best];
        playlistInfo = BlurayPlaylistInfo(
          playlistName: best.name,
          totalDuration: Duration.zero,
          clipNames: [best.name],
          totalBytes: best.size,
        );
      } else {
        // 2. Try DVD VIDEO_TS/*.VOB fallback
        final vobDir = await fs.listDirectory(const ['VIDEO_TS']);
        final titleSets = <String, List<({int part, IsoFileEntry file})>>{};
        final vobPattern = RegExp(r'^VTS_(\d{2})_([1-9])\.VOB$');
        for (final entry in vobDir) {
          if (entry.isDir || entry.file == null) continue;
          final m = vobPattern.firstMatch(entry.name.toUpperCase());
          if (m == null) continue;
          final setId = m.group(1)!;
          final part = int.parse(m.group(2)!);
          titleSets.putIfAbsent(setId, () => []).add((part: part, file: entry.file!));
        }
        if (titleSets.isNotEmpty) {
          final ranked = titleSets.entries.map((e) {
            final sortedParts = e.value.toList()
              ..sort((a, b) => a.part.compareTo(b.part));
            final totalSize = sortedParts.fold<int>(0, (s, p) => s + p.file.size);
            return (setId: e.key, parts: sortedParts, totalSize: totalSize);
          }).toList()
            ..sort((a, b) => b.totalSize.compareTo(a.totalSize));
          final bestSet = ranked.first;
          selectedFiles = [for (final p in bestSet.parts) p.file];
          fileExt = '.vob';
          contentType = 'video/mpeg';
          playlistInfo = BlurayPlaylistInfo(
            playlistName: 'VTS_${bestSet.setId}',
            totalDuration: Duration.zero,
            clipNames: [for (final f in selectedFiles) f.name],
            totalBytes: bestSet.totalSize,
            isDvdVob: true,
          );
        }
      }

      if (selectedFiles.isEmpty || playlistInfo == null) {
        throw const FormatException('ISO 镜像中未找到可播放的 BDMV 或 VIDEO_TS 视频流');
      }

      final mappings = <_VirtualSegmentMapping>[];
      var cursor = 0;
      for (final f in selectedFiles) {
        if (f.size <= 0) continue;
        mappings.add(_VirtualSegmentMapping(
          virtualStart: cursor,
          virtualEnd: cursor + f.size - 1,
          file: f,
        ));
        cursor += f.size;
      }

      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0)
        ..autoCompress = false;
      final random = math.Random.secure();
      final capability = List.generate(
        16,
        (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join();

      return BlurayIsoLease._(
        server,
        reader,
        capability,
        isCancelled ?? () => false,
        mappings,
        playlistInfo,
        fileExt,
        contentType,
      );
    } catch (_) {
      await server?.close(force: true);
      await reader.close();
      rethrow;
    }
  }
}
