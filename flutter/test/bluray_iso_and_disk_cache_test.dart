// Local loopback + in-memory synthetic UDF 2.50 / ISO-9660 / HTTP Range fixtures; no external network.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:marco_movie/core/bluray_iso_proxy.dart';
import 'package:marco_movie/core/local_media_proxy.dart';

void _putU16LE(Uint8List b, int off, int v) {
  b[off] = v & 0xFF;
  b[off + 1] = (v >> 8) & 0xFF;
}

void _putU32LE(Uint8List b, int off, int v) {
  b[off] = v & 0xFF;
  b[off + 1] = (v >> 8) & 0xFF;
  b[off + 2] = (v >> 16) & 0xFF;
  b[off + 3] = (v >> 24) & 0xFF;
}

void _putU64LE(Uint8List b, int off, int v) {
  _putU32LE(b, off, v & 0xFFFFFFFF);
  _putU32LE(b, off + 4, (v ~/ 0x100000000) & 0xFFFFFFFF);
}

void _putU16BE(Uint8List b, int off, int v) {
  b[off] = (v >> 8) & 0xFF;
  b[off + 1] = v & 0xFF;
}

void _putU32BE(Uint8List b, int off, int v) {
  b[off] = (v >> 24) & 0xFF;
  b[off + 1] = (v >> 16) & 0xFF;
  b[off + 2] = (v >> 8) & 0xFF;
  b[off + 3] = v & 0xFF;
}

Uint8List _buildMplsBytes({
  required List<({String clip, int inTicks, int outTicks})> playItems,
  List<({int playItemId, int markTicks})> chapters = const [],
}) {
  const headerSize = 40;
  final playItemBytes = <int>[];
  for (final item in playItems) {
    // Minimal 22-byte PlayItem payload:
    // 5B clip + 4B "M2TS" + 5B flags/stc + 4B inTime + 4B outTime
    final entry = Uint8List(24);
    _putU16BE(entry, 0, 22);
    final clipAscii = ascii.encode(item.clip.padRight(5).substring(0, 5));
    entry.setRange(2, 7, clipAscii);
    entry.setRange(7, 11, ascii.encode('M2TS'));
    _putU32BE(entry, 16, item.inTicks);
    _putU32BE(entry, 20, item.outTicks);
    playItemBytes.addAll(entry);
  }

  final playlistSectionLen = 6 + playItemBytes.length;
  const playlistStart = headerSize;
  final markStart = playlistStart + 4 + playlistSectionLen;
  final markSectionLen = 2 + chapters.length * 14;
  final totalLen = markStart + 4 + markSectionLen;

  final out = Uint8List(totalLen);
  out.setRange(0, 8, ascii.encode('MPLS0200'));
  _putU32BE(out, 8, playlistStart);
  _putU32BE(out, 12, markStart);

  _putU32BE(out, playlistStart, playlistSectionLen);
  _putU16BE(out, playlistStart + 6, playItems.length);
  _putU16BE(out, playlistStart + 8, 0);
  out.setRange(playlistStart + 10, markStart, playItemBytes);

  _putU32BE(out, markStart, markSectionLen);
  _putU16BE(out, markStart + 4, chapters.length);
  var mPos = markStart + 6;
  for (final ch in chapters) {
    out[mPos] = 0x00;
    out[mPos + 1] = 0x01; // Entry-mark
    _putU16BE(out, mPos + 2, ch.playItemId);
    _putU32BE(out, mPos + 4, ch.markTicks);
    mPos += 14;
  }
  return out;
}

Uint8List _buildUdfDirFidData(
  List<({String name, bool isDir, int icbBlock, int icbPartRef})> entries,
) {
  final out = BytesBuilder(copy: false);
  for (final e in entries) {
    final nameBytes = ascii.encode(e.name);
    final lFi = 1 + nameBytes.length;
    final rawLen = 38 + lFi;
    final recLen = ((rawLen + 3) ~/ 4) * 4;
    final rec = Uint8List(recLen);
    _putU16LE(rec, 0, 257); // FID Tag ID
    rec[18] = e.isDir ? 0x02 : 0x00;
    rec[19] = lFi;
    _putU32LE(rec, 20, 2048); // ICB extent len
    _putU32LE(rec, 24, e.icbBlock);
    _putU16LE(rec, 28, e.icbPartRef);
    _putU16LE(rec, 36, 0); // L_IU
    rec[38] = 8; // 8-bit OSTA compressed unicode
    rec.setRange(39, 39 + nameBytes.length, nameBytes);
    out.add(rec);
  }
  return out.takeBytes();
}

Uint8List _buildUdfEfeShortAd({
  required bool isDir,
  required int infoLength,
  required int startBlock,
  required int extentBytes,
}) {
  final sec = Uint8List(2048);
  _putU16LE(sec, 0, 266); // Extended File Entry
  sec[27] = isDir ? 4 : 5;
  _putU16LE(sec, 34, 0); // allocType = 0 (short_ad)
  _putU64LE(sec, 56, infoLength);
  _putU32LE(sec, 208, 0); // L_EA
  _putU32LE(sec, 212, 8); // L_AD
  _putU32LE(sec, 216, extentBytes);
  _putU32LE(sec, 220, startBlock);
  return sec;
}

Uint8List _buildUdfFeLongAd({
  required bool isDir,
  required int infoLength,
  required List<({int block, int partRef, int length})> extents,
}) {
  final sec = Uint8List(2048);
  _putU16LE(sec, 0, 261); // File Entry
  sec[27] = isDir ? 4 : 5;
  _putU16LE(sec, 34, 1); // allocType = 1 (long_ad)
  _putU64LE(sec, 56, infoLength);
  _putU32LE(sec, 168, 0); // L_EA
  _putU32LE(sec, 172, extents.length * 16); // L_AD
  var pos = 176;
  for (final ext in extents) {
    _putU32LE(sec, pos, ext.length);
    _putU32LE(sec, pos + 4, ext.block);
    _putU16LE(sec, pos + 8, ext.partRef);
    pos += 16;
  }
  return sec;
}

/// Builds a genuine UDF 2.50 Blu-ray ISO image (~6 MB) with Type 2 Metadata
/// Partition, fake loop `.mpls` (`00001.mpls`), main feature `.mpls`
/// (`00000.mpls` -> `00001.m2ts` + `00002.m2ts`), and chapters.
({
  Uint8List isoBytes,
  Uint8List m2ts1Bytes,
  Uint8List m2ts2Bytes,
}) _buildSyntheticBlurayUdfIso() {
  const sectorSize = 2048;
  const totalSectors = 3000; // ~6 MB
  final iso = Uint8List(totalSectors * sectorSize);

  void writeSector(int sector, Uint8List data) {
    iso.setRange(sector * sectorSize, sector * sectorSize + data.length, data);
  }

  // Sector 256: Anchor Volume Descriptor Pointer (AVDP)
  final avdp = Uint8List(sectorSize);
  _putU16LE(avdp, 0, 2);
  _putU32LE(avdp, 16, 3 * sectorSize); // MVDS length
  _putU32LE(avdp, 20, 260); // MVDS start sector
  writeSector(256, avdp);

  // MVDS Sectors 260..262
  // 260: Partition Descriptor (partitionNumber = 0, starts at physical sector 300)
  const physStart = 300;
  final pd = Uint8List(sectorSize);
  _putU16LE(pd, 0, 5);
  _putU16LE(pd, 22, 0);
  _putU32LE(pd, 188, physStart);
  _putU32LE(pd, 192, totalSectors - physStart);
  writeSector(260, pd);

  // 261: Logical Volume Descriptor with Type 1 (ref 0) + Type 2 Metadata Partition (ref 1)
  final lvd = Uint8List(sectorSize);
  _putU16LE(lvd, 0, 6);
  _putU32LE(lvd, 212, sectorSize);
  _putU32LE(lvd, 248, sectorSize); // FSD len
  _putU32LE(lvd, 252, 0); // FSD block 0 inside Metadata Partition (ref 1)
  _putU16LE(lvd, 256, 1); // FSD partitionRef = 1
  _putU32LE(lvd, 264, 70); // mapTableLength = 6 + 64
  _putU32LE(lvd, 268, 2); // numPartitionMaps
  // Map 0: Physical (type 1, len 6)
  lvd[440] = 1;
  lvd[441] = 6;
  _putU16LE(lvd, 444, 0);
  // Map 1: Metadata Partition (type 2, len 64)
  lvd[446] = 2;
  lvd[447] = 64;
  _putU16LE(lvd, 446 + 38, 0); // partitionNumber = 0
  _putU32LE(lvd, 446 + 40, 0); // metadataFileLocation = physical block 0 (sector 300)
  _putU32LE(lvd, 446 + 44, 0);
  writeSector(261, lvd);

  // 262: Terminating Descriptor
  final td = Uint8List(sectorSize);
  _putU16LE(td, 0, 8);
  writeSector(262, td);

  // Physical block 0 (sector 300): Metadata File Entry pointing to physical blocks 10..29 (sectors 310..329)
  writeSector(
    physStart + 0,
    _buildUdfEfeShortAd(
      isDir: false,
      infoLength: 20 * sectorSize,
      startBlock: 10,
      extentBytes: 20 * sectorSize,
    ),
  );

  // Metadata Partition blocks (metaBlock i => physical sector 310 + i):
  const metaPhysBase = physStart + 10;

  // Meta block 0: File Set Descriptor (root ICB at meta block 1)
  final fsd = Uint8List(sectorSize);
  _putU16LE(fsd, 0, 256);
  _putU32LE(fsd, 400, sectorSize);
  _putU32LE(fsd, 404, 1); // Root ICB block 1
  _putU16LE(fsd, 408, 1); // Root ICB partRef 1 (Metadata)
  writeSector(metaPhysBase + 0, fsd);

  // Meta block 1: Root Dir EFE -> meta block 2
  final rootDirData = _buildUdfDirFidData([
    (name: 'BDMV', isDir: true, icbBlock: 3, icbPartRef: 1),
  ]);
  writeSector(
    metaPhysBase + 1,
    _buildUdfEfeShortAd(
      isDir: true,
      infoLength: rootDirData.length,
      startBlock: 2,
      extentBytes: sectorSize,
    ),
  );
  writeSector(metaPhysBase + 2, rootDirData);

  // Meta block 3: BDMV Dir EFE -> meta block 4
  final bdmvDirData = _buildUdfDirFidData([
    (name: 'PLAYLIST', isDir: true, icbBlock: 5, icbPartRef: 1),
    (name: 'STREAM', isDir: true, icbBlock: 7, icbPartRef: 1),
  ]);
  writeSector(
    metaPhysBase + 3,
    _buildUdfEfeShortAd(
      isDir: true,
      infoLength: bdmvDirData.length,
      startBlock: 4,
      extentBytes: sectorSize,
    ),
  );
  writeSector(metaPhysBase + 4, bdmvDirData);

  // Meta block 5: PLAYLIST Dir EFE -> meta block 6
  final playlistDirData = _buildUdfDirFidData([
    (name: '00001.mpls', isDir: false, icbBlock: 9, icbPartRef: 1), // fake loop
    (name: '00000.mpls', isDir: false, icbBlock: 10, icbPartRef: 1), // main feature
  ]);
  writeSector(
    metaPhysBase + 5,
    _buildUdfEfeShortAd(
      isDir: true,
      infoLength: playlistDirData.length,
      startBlock: 6,
      extentBytes: sectorSize,
    ),
  );
  writeSector(metaPhysBase + 6, playlistDirData);

  // Meta block 7: STREAM Dir EFE -> meta block 8
  final streamDirData = _buildUdfDirFidData([
    (name: '00001.m2ts', isDir: false, icbBlock: 11, icbPartRef: 1),
    (name: '00002.m2ts', isDir: false, icbBlock: 12, icbPartRef: 1),
  ]);
  writeSector(
    metaPhysBase + 7,
    _buildUdfEfeShortAd(
      isDir: true,
      infoLength: streamDirData.length,
      startBlock: 8,
      extentBytes: sectorSize,
    ),
  );
  writeSector(metaPhysBase + 8, streamDirData);

  // Build playlist binaries in physical blocks (partRef = 0):
  // Fake loop playlist (00001.mpls): repeats clip 00001 four times -> longer raw duration but suspected fake loop!
  final fakeLoopMpls = _buildMplsBytes(
    playItems: const [
      (clip: '00001', inTicks: 0, outTicks: 45000 * 600),
      (clip: '00001', inTicks: 0, outTicks: 45000 * 600),
      (clip: '00001', inTicks: 0, outTicks: 45000 * 600),
      (clip: '00001', inTicks: 0, outTicks: 45000 * 600),
    ],
  );
  // Real main feature playlist (00000.mpls): 00001 (600s) + 00002 (600s) with 2 chapters
  final mainMpls = _buildMplsBytes(
    playItems: const [
      (clip: '00001', inTicks: 45000 * 10, outTicks: 45000 * 610),
      (clip: '00002', inTicks: 0, outTicks: 45000 * 600),
    ],
    chapters: const [
      (playItemId: 0, markTicks: 45000 * 10), // 0s
      (playItemId: 1, markTicks: 45000 * 120), // 600s + 120s = 720s
    ],
  );

  // Place .mpls files at physical blocks 100 and 102 (partRef 0)
  writeSector(physStart + 100, fakeLoopMpls);
  writeSector(physStart + 102, mainMpls);

  writeSector(
    metaPhysBase + 9,
    _buildUdfFeLongAd(
      isDir: false,
      infoLength: fakeLoopMpls.length,
      extents: [(block: 100, partRef: 0, length: fakeLoopMpls.length)],
    ),
  );
  writeSector(
    metaPhysBase + 10,
    _buildUdfFeLongAd(
      isDir: false,
      infoLength: mainMpls.length,
      extents: [(block: 102, partRef: 0, length: mainMpls.length)],
    ),
  );

  // Place .m2ts payloads far into the 6 MB ISO (e.g., physical blocks 500.. and 1500..)
  // 00001.m2ts: 10,000 bytes (split across two physical extents: 6144 + 3856!)
  // 00002.m2ts: 8,000 bytes
  final m2ts1 = Uint8List(10000);
  for (var i = 0; i < m2ts1.length; i++) {
    m2ts1[i] = (i % 192 == 4) ? 0x47 : (0xA0 + (i % 31));
  }
  final m2ts2 = Uint8List(8000);
  for (var i = 0; i < m2ts2.length; i++) {
    m2ts2[i] = (i % 192 == 4) ? 0x47 : (0x10 + (i % 47));
  }

  // Copy m2ts1 into two disjoint physical extents: block 500 (3 sectors = 6144B) + block 900 (3856B)
  iso.setRange(
    (physStart + 500) * sectorSize,
    (physStart + 500) * sectorSize + 6144,
    m2ts1.sublist(0, 6144),
  );
  iso.setRange(
    (physStart + 900) * sectorSize,
    (physStart + 900) * sectorSize + 3856,
    m2ts1.sublist(6144, 10000),
  );
  // Copy m2ts2 into physical block 1500
  iso.setRange(
    (physStart + 1500) * sectorSize,
    (physStart + 1500) * sectorSize + m2ts2.length,
    m2ts2,
  );

  writeSector(
    metaPhysBase + 11,
    _buildUdfFeLongAd(
      isDir: false,
      infoLength: m2ts1.length,
      extents: const [
        (block: 500, partRef: 0, length: 6144),
        (block: 900, partRef: 0, length: 3856),
      ],
    ),
  );
  writeSector(
    metaPhysBase + 12,
    _buildUdfFeLongAd(
      isDir: false,
      infoLength: m2ts2.length,
      extents: [(block: 1500, partRef: 0, length: m2ts2.length)],
    ),
  );

  return (isoBytes: iso, m2ts1Bytes: m2ts1, m2ts2Bytes: m2ts2);
}

Uint8List _buildIso9660DirSector(
  List<({String name, bool isDir, int sector, int size})> entries,
) {
  final out = Uint8List(2048);
  var pos = 0;
  for (final e in entries) {
    final nameBytes = ascii.encode(e.isDir ? e.name : '${e.name};1');
    var recLen = 33 + nameBytes.length;
    if (recLen.isOdd) recLen++;
    out[pos] = recLen;
    _putU32LE(out, pos + 2, e.sector);
    _putU32LE(out, pos + 10, e.size);
    out[pos + 25] = e.isDir ? 0x02 : 0x00;
    out[pos + 32] = nameBytes.length;
    out.setRange(pos + 33, pos + 33 + nameBytes.length, nameBytes);
    pos += recLen;
  }
  return out;
}

/// Builds a synthetic ISO-9660 DVD image with `VIDEO_TS/VTS_01_1.VOB` and `VTS_01_2.VOB`.
({Uint8List isoBytes, Uint8List vob1, Uint8List vob2}) _buildSyntheticDvdIso9660() {
  const sectorSize = 2048;
  final iso = Uint8List(64 * sectorSize);
  void writeSector(int sector, Uint8List data) {
    iso.setRange(sector * sectorSize, sector * sectorSize + data.length, data);
  }

  // Sector 16: Primary Volume Descriptor
  final pvd = Uint8List(sectorSize);
  pvd[0] = 1;
  pvd.setRange(1, 6, ascii.encode('CD001'));
  _putU16LE(pvd, 128, sectorSize);
  // Root dir at sector 20, size 2048
  _putU32LE(pvd, 156 + 2, 20);
  _putU32LE(pvd, 156 + 10, sectorSize);
  writeSector(16, pvd);

  // Sector 17: Volume Descriptor Set Terminator
  final term = Uint8List(sectorSize);
  term[0] = 255;
  term.setRange(1, 6, ascii.encode('CD001'));
  writeSector(17, term);

  // Sector 20: Root dir -> VIDEO_TS at sector 21
  writeSector(
    20,
    _buildIso9660DirSector([
      (name: 'VIDEO_TS', isDir: true, sector: 21, size: sectorSize),
    ]),
  );

  final vob1 = Uint8List.fromList(List<int>.generate(3000, (i) => (i + 1) & 0xFF));
  final vob2 = Uint8List.fromList(List<int>.generate(2500, (i) => (0xFF - i) & 0xFF));

  // Sector 21: VIDEO_TS dir -> VTS_01_1.VOB at sector 30, VTS_01_2.VOB at sector 34
  writeSector(
    21,
    _buildIso9660DirSector([
      (name: 'VTS_01_0.VOB', isDir: false, sector: 25, size: 512), // menu, skipped
      (name: 'VTS_01_1.VOB', isDir: false, sector: 30, size: vob1.length),
      (name: 'VTS_01_2.VOB', isDir: false, sector: 34, size: vob2.length),
    ]),
  );

  writeSector(30, vob1);
  writeSector(34, vob2);
  return (isoBytes: iso, vob1: vob1, vob2: vob2);
}

void main() {
  group('BlurayIsoProxy on-demand HTTP Range & local file streaming', () {
    test(
        'parses UDF 2.50 metadata partition via small HTTP Range requests, filters fake loop MPLS, extracts chapters, and supports cross-segment 206 Seek',
        () async {
      final fixture = _buildSyntheticBlurayUdfIso();
      final iso = fixture.isoBytes;
      final expectedStream = Uint8List.fromList([
        ...fixture.m2ts1Bytes,
        ...fixture.m2ts2Bytes,
      ]);

      final rangeRequests = <String>[];
      var bytesTransferred = 0;

      final mockHttp = MockClient((request) async {
        final range = request.headers['range'] ?? request.headers['Range'] ?? '';
        rangeRequests.add(range);
        final m = RegExp(r'^bytes=(\d+)-(\d+)$').firstMatch(range);
        if (m == null) {
          return http.Response('range required', 400);
        }
        final start = int.parse(m.group(1)!);
        final end = math.min(int.parse(m.group(2)!), iso.length - 1);
        final slice = Uint8List.sublistView(iso, start, end + 1);
        bytesTransferred += slice.length;
        return http.Response.bytes(
          slice,
          206,
          headers: {
            'content-type': 'application/octet-stream',
            'content-range': 'bytes $start-$end/${iso.length}',
          },
        );
      });

      final lease = await BlurayIsoProxy.open(
        target: 'https://alist.example/dav/movie_4k_uhd.iso',
        headers: const {'Authorization': 'Bearer alist-secret'},
        client: mockHttp,
      );

      try {
        // Mounting and parsing the 6 MB UDF 2.50 ISO read only targeted metadata sectors (< 100 KB)
        expect(bytesTransferred, lessThan(100 * 1024));
        expect(rangeRequests, isNotEmpty);

        // Selected 00000.mpls (filtered out fake repeating loop 00001.mpls!)
        expect(lease.playlistInfo.playlistName, '00000.mpls');
        expect(lease.playlistInfo.clipNames, ['00001.m2ts', '00002.m2ts']);
        expect(lease.playlistInfo.totalDuration, const Duration(seconds: 1200));
        expect(lease.totalBytes, expectedStream.length);

        // Verified chapters extracted with PlayItem cumulative offset
        expect(lease.chapters, hasLength(2));
        expect(lease.chapters[0].position, Duration.zero);
        expect(lease.chapters[1].position, const Duration(seconds: 720));

        // HEAD check
        final headResp = await http.head(lease.url);
        expect(headResp.statusCode, 200);
        expect(headResp.headers['accept-ranges'], 'bytes');
        expect(headResp.headers['content-length'], '${expectedStream.length}');
        expect(headResp.headers['content-type'], 'video/mp2t');

        // Cross-extent & cross-segment HTTP 206 Seek:
        // Read bytes [6000..10500] which crosses:
        // - m2ts1 extent 1 -> extent 2 at byte 6144
        // - m2ts1 -> m2ts2 segment boundary at byte 10000!
        final seekResp = await http.get(
          lease.url,
          headers: const {'Range': 'bytes=6000-10500'},
        );
        expect(seekResp.statusCode, 206);
        expect(
          seekResp.headers['content-range'],
          'bytes 6000-10500/${expectedStream.length}',
        );
        expect(
          seekResp.bodyBytes,
          expectedStream.sublist(6000, 10501),
        );

        // Out-of-bounds range -> 416
        final oobResp = await http.get(
          lease.url,
          headers: {'Range': 'bytes=${expectedStream.length + 100}-'},
        );
        expect(oobResp.statusCode, 416);
      } finally {
        await lease.close();
      }
      expect(lease.isClosed, isTrue);
    });

    test(
        'parses ISO-9660 DVD VIDEO_TS/*.VOB from local file and streams concatenated 206 seek',
        () async {
      final dvd = _buildSyntheticDvdIso9660();
      final tempDir = await Directory.systemTemp.createTemp('marco_dvd_iso_');
      addTearDown(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });
      final isoFile = File('${tempDir.path}${Platform.pathSeparator}concert.iso');
      await isoFile.writeAsBytes(dvd.isoBytes, flush: true);

      expect(BlurayIsoProxy.isIsoTarget(isoFile.path), isTrue);
      expect(BlurayIsoProxy.isIsoTarget('https://emby.test/dl/film.iso?api_key=1'), isTrue);
      expect(BlurayIsoProxy.isIsoTarget('https://emby.test/dl/film.mkv'), isFalse);

      final lease = await BlurayIsoProxy.open(target: isoFile.path);
      try {
        expect(lease.playlistInfo.isDvdVob, isTrue);
        expect(lease.playlistInfo.clipNames, ['VTS_01_1.VOB', 'VTS_01_2.VOB']);
        final expected = Uint8List.fromList([...dvd.vob1, ...dvd.vob2]);
        expect(lease.totalBytes, expected.length);

        // Seek across VOB1 -> VOB2 boundary (2900..3150)
        final res = await http.get(
          lease.url,
          headers: const {'Range': 'bytes=2900-3150'},
        );
        expect(res.statusCode, 206);
        expect(res.bodyBytes, expected.sublist(2900, 3151));
      } finally {
        await lease.close();
      }
    });
  });

  group('DiskBlockCache (/kcache/<sid>) 256 KiB block cache, 206 splicing, 416 fallback & LRU', () {
    test(
        'splices HTTP 206 across cached block 0 and uncached block 1, handles 416 no-Range retry, and enforces LRU eviction & clearDiskCache',
        () async {
      final cacheDir = await Directory.systemTemp.createTemp('marco_kcache_test_');
      DiskBlockCache? cacheRef;
      addTearDown(() async {
        await cacheRef?.flush();
        for (var attempt = 0; attempt < 4; attempt++) {
          try {
            if (await cacheDir.exists()) {
              await cacheDir.delete(recursive: true);
            }
            break;
          } on FileSystemException {
            if (attempt == 3) rethrow;
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
        }
      });

      var now = DateTime.utc(2026, 11, 22, 12, 0, 0);
      final cache = DiskBlockCache(
        directory: cacheDir,
        maxBytes: 2 * DiskBlockCache.blockSize, // 512 KiB limit for LRU test
        clock: () => now,
      );
      cacheRef = cache;

      // Build 600 KiB synthetic MP4 payload (> 2 blocks: 256K + 256K + 88K)
      const totalSize = 600 * 1024;
      final payload = Uint8List.fromList(
        List<int>.generate(totalSize, (i) => (i * 7 + (i >> 8)) & 0xFF),
      );
      final upstreamRanges = <String?>[];

      final lease = await LocalMediaLease.open(
        target: Uri.parse('https://pan-cdn.test/4k/film_a.mp4'),
        enableDiskCache: true,
        diskCache: cache,
        isCancelled: () => false,
        client: MockClient((request) async {
          final r = request.headers['range'] ?? request.headers['Range'];
          upstreamRanges.add(r);
          if (r == null) {
            return http.Response.bytes(
              payload,
              200,
              headers: {
                'content-type': 'video/mp4',
                'content-length': '$totalSize',
              },
            );
          }
          final m = RegExp(r'^bytes=(\d+)-(\d+)$').firstMatch(r)!;
          final s = int.parse(m.group(1)!);
          final e = math.min(int.parse(m.group(2)!), totalSize - 1);
          return http.Response.bytes(
            Uint8List.sublistView(payload, s, e + 1),
            206,
            headers: {
              'content-type': 'video/mp4',
              'content-range': 'bytes $s-$e/$totalSize',
            },
          );
        }),
      );

      try {
        expect(lease.url.path, startsWith('/kcache/'));

        // 1. Fetch within block 0 -> fetches aligned block 0 [0 .. 262143] from upstream
        final r1 = await http.get(
          lease.url,
          headers: const {'Range': 'bytes=100-500'},
        );
        expect(r1.statusCode, 206);
        expect(r1.bodyBytes, payload.sublist(100, 501));
        expect(await cache.currentCacheBytes(), DiskBlockCache.blockSize);
        expect(upstreamRanges, ['bytes=0-${DiskBlockCache.blockSize - 1}']);

        // 2. Fetch spanning cached block 0 + uncached block 1 [200000 .. 300000]:
        // Block 0 must be served from disk; upstream must ONLY be asked for block 1!
        upstreamRanges.clear();
        now = now.add(const Duration(seconds: 10));
        final r2 = await http.get(
          lease.url,
          headers: const {'Range': 'bytes=200000-300000'},
        );
        expect(r2.statusCode, 206);
        expect(
          r2.headers['content-range'],
          'bytes 200000-300000/$totalSize',
        );
        expect(r2.bodyBytes, payload.sublist(200000, 300001));
        expect(
          upstreamRanges,
          ['bytes=${DiskBlockCache.blockSize}-${2 * DiskBlockCache.blockSize - 1}'],
        );
        expect(await cache.currentCacheBytes(), 2 * DiskBlockCache.blockSize);

        // 3. Touch block 0 via cache hit (0 upstream requests!) to make block 0 newer than block 1
        upstreamRanges.clear();
        now = now.add(const Duration(seconds: 10));
        final r3 = await http.get(
          lease.url,
          headers: const {'Range': 'bytes=0-1023'},
        );
        expect(r3.statusCode, 206);
        expect(r3.bodyBytes, payload.sublist(0, 1024));
        expect(upstreamRanges, isEmpty);

        // 4. Write a block for film_b -> exceeds 512 KiB cap, LRU must evict block 1 (oldest)
        now = now.add(const Duration(seconds: 10));
        await cache.writeBlock(
          'https://pan-cdn.test/4k/film_b.mp4',
          0,
          Uint8List(DiskBlockCache.blockSize),
          totalLength: DiskBlockCache.blockSize,
        );
        expect(await cache.currentCacheBytes(), 2 * DiskBlockCache.blockSize);
        expect(
          await cache.hasBlock('https://pan-cdn.test/4k/film_b.mp4', 0),
          isTrue,
        );

        // Clear cache -> 0 bytes
        await cache.clearDiskCache();
        expect(await cache.currentCacheBytes(), 0);
      } finally {
        await lease.close();
      }

      // 5. Upstream 416 fallback test: upstream rejects Range with 416, retries without Range -> 200 -> 206 slice!
      final retryTrace = <String?>[];
      final lease416 = await LocalMediaLease.open(
        target: Uri.parse('https://no-range-cdn.test/video.mp4'),
        enableDiskCache: true,
        diskCache: cache,
        isCancelled: () => false,
        client: MockClient((request) async {
          final r = request.headers['range'] ?? request.headers['Range'];
          retryTrace.add(r);
          if (r != null) {
            return http.Response('range rejected', 416);
          }
          return http.Response.bytes(
            payload.sublist(0, 4096),
            200,
            headers: {
              'content-type': 'video/mp4',
              'content-length': '4096',
            },
          );
        }),
      );
      try {
        final resp416Fallback = await http.get(
          lease416.url,
          headers: const {'Range': 'bytes=500-999'},
        );
        expect(resp416Fallback.statusCode, 206);
        expect(resp416Fallback.headers['content-range'], 'bytes 500-999/4096');
        expect(resp416Fallback.bodyBytes, payload.sublist(500, 1000));
        expect(retryTrace, hasLength(2));
        expect(retryTrace[0], isNotNull);
        expect(retryTrace[1], isNull);
      } finally {
        await lease416.close();
      }
    });
  });

  group('HLS VOD discontinuity ad-stripping boundaries', () {
    test('respects 60s segment limit, 20-segment count limit, and 40% total cap', () {
      final origin = Uri.parse('https://vod.example/p/index.m3u8');

      // Case A: Ad block > 60s (65s) must NOT be stripped
      const over60s = '#EXTM3U\n'
          '#EXT-X-TARGETDURATION:70\n'
          '#EXTINF:200.0,\n'
          'https://vod.example/p/main1.ts\n'
          '#EXT-X-DISCONTINUITY\n'
          '#EXTINF:65.0,\n'
          'https://ad.invalid/long_ad.ts\n'
          '#EXT-X-DISCONTINUITY\n'
          '#EXTINF:200.0,\n'
          'https://vod.example/p/main2.ts\n'
          '#EXT-X-ENDLIST\n';
      expect(LocalMediaLease.stripVodPlaylistAds(over60s, origin), over60s);

      // Case B: Ad block > 20 segments (21 segments) must NOT be stripped
      final over20Segs = StringBuffer()
        ..writeln('#EXTM3U')
        ..writeln('#EXT-X-TARGETDURATION:10')
        ..writeln('#EXTINF:100.0,')
        ..writeln('https://vod.example/p/main1.ts')
        ..writeln('#EXT-X-DISCONTINUITY');
      for (var i = 0; i < 21; i++) {
        over20Segs
          ..writeln('#EXTINF:1.0,')
          ..writeln('https://ad.invalid/s$i.ts');
      }
      over20Segs
        ..writeln('#EXT-X-DISCONTINUITY')
        ..writeln('#EXTINF:100.0,')
        ..writeln('https://vod.example/p/main2.ts')
        ..writeln('#EXT-X-ENDLIST');
      final over20Str = over20Segs.toString();
      expect(LocalMediaLease.stripVodPlaylistAds(over20Str, origin), over20Str);

      // Case C: Removing > 40% total duration must NOT strip (e.g. 50s main + 40s ad = 44.4% > 40%)
      const over40Pct = '#EXTM3U\n'
          '#EXT-X-PLAYLIST-TYPE:VOD\n'
          '#EXT-X-TARGETDURATION:50\n'
          '#EXTINF:50.0,\n'
          'https://vod.example/p/main.ts\n'
          '#EXT-X-DISCONTINUITY\n'
          '#EXTINF:40.0,\n'
          'https://ad.invalid/ad.ts\n';
      expect(LocalMediaLease.stripVodPlaylistAds(over40Pct, origin), over40Pct);

      // Case D: Valid VOD ad insertion (30s out of 130s = 23% <= 40%, 2 segs <= 20, <= 60s) -> stripped!
      const validStrip = '#EXTM3U\n'
          '#EXT-X-PLAYLIST-TYPE:VOD\n'
          '#EXT-X-TARGETDURATION:50\n'
          '#EXTINF:50.0,\n'
          'https://vod.example/p/main1.ts\n'
          '#EXT-X-DISCONTINUITY\n'
          '#EXTINF:15.0,\n'
          'https://ad.invalid/ad1.ts\n'
          '#EXTINF:15.0,\n'
          'https://ad.invalid/ad2.ts\n'
          '#EXT-X-DISCONTINUITY\n'
          '#EXTINF:50.0,\n'
          'https://vod.example/p/main2.ts\n';
      final cleaned = LocalMediaLease.stripVodPlaylistAds(validStrip, origin);
      expect(cleaned, isNot(contains('ad.invalid')));
      expect(cleaned, contains('main1.ts'));
      expect(cleaned, contains('main2.ts'));
    });
  });
}
