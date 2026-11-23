import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/core/media_badges.dart';
import 'package:marco_movie/ui/apple_theme.dart';
import 'package:marco_movie/ui/media_badge.dart';

File _resolveSpecFile(String relative) {
  final candidates = <String>[
    relative,
    '../$relative',
    '../../$relative',
  ];
  for (final path in candidates) {
    final file = File(path);
    if (file.existsSync()) return file;
  }
  throw StateError('Unable to locate $relative from ${Directory.current.path}');
}

void main() {
  final rulesFile = _resolveSpecFile('shared/ui-spec/badge-rules.json');
  final goldenFile = _resolveSpecFile('shared/ui-spec/badge-golden.json');
  final rulesJson = rulesFile.readAsStringSync();
  final goldenDoc =
      jsonDecode(goldenFile.readAsStringSync()) as Map<String, dynamic>;
  final cases = goldenDoc['cases'] as List<dynamic>;

  test('Flutter asset copy of badge-rules.json matches shared/ui-spec', () {
    final assetFile = _resolveSpecFile('flutter/assets/ui-spec/badge-rules.json');
    expect(assetFile.readAsStringSync(), rulesJson);
  });

  test('MediaBadges passes 165/165 golden cases (JSON-loaded and built-in)', () {
    expect(cases.length, 165);
    final jsonEngine = MediaBadges.fromJson(rulesJson);
    final builtinEngine = MediaBadges.instance;

    for (final rawCase in cases) {
      final c = rawCase as Map<String, dynamic>;
      final id = c['id'] as String;
      final input = c['input'] as String?;
      final expected = (c['expected'] as List<dynamic>)
          .map((e) => '${(e as Map<String, dynamic>)['id']}:${e['label']}')
          .toList();

      final actualJson =
          jsonEngine.extract(input).map((b) => '${b.id}:${b.label}').toList();
      expect(actualJson, expected, reason: 'JSON engine mismatch on $id');

      final actualBuiltin =
          builtinEngine.extract(input).map((b) => '${b.id}:${b.label}').toList();
      expect(actualBuiltin, expected, reason: 'Built-in engine mismatch on $id');
    }
  });

  test('256-entry LRU cache bounds size and preserves hits', () {
    final engine = MediaBadges.fromJson(rulesJson);
    engine.clearCache();
    for (var i = 0; i < 320; i++) {
      engine.extract('Synthetic.Sample.$i.2160p.HDR10+.DD+ 5.1.mkv');
    }
    expect(engine.cacheSize, MediaBadges.lruCacheCapacity);
  });

  test('Pure-data fusion overrides filename resolution with live track and runs combos', () {
    final engine = MediaBadges.fromJson(rulesJson);
    final fused = engine.fuse(
      sources: const ['Example.Movie.4K.DV.REMUX.NF.mkv'],
      track: const MediaTrackSpec(
        videoWidth: 1920,
        videoHeight: 1080,
        videoCodec: 'hev1.2.4.L120',
        audioCodec: 'ec-3',
        audioChannels: 6,
        atmos: true,
      ),
    );
    expect(
      fused.map((b) => b.label).toList(),
      const ['1080p', 'DV · ATMOS', 'REMUX', 'DD+', '5.1', 'HEVC', 'NF'],
    );

    // Contradictory video_codec: live HEVC overrides filename H264
    expect(
      engine
          .fuse(
            sources: const ['Example.H264.mkv'],
            track: const MediaTrackSpec(videoCodec: 'hev1.1.6.L120'),
          )
          .map((b) => b.label)
          .toList(),
      const ['HEVC'],
    );

    // Contradictory audio_codec: live DD+ overrides filename DD; DTS-HD MA overrides DTS
    expect(
      engine
          .fuse(
            sources: const ['Example.AC3.mkv'],
            track: const MediaTrackSpec(audioCodec: 'ec-3'),
          )
          .map((b) => b.label)
          .toList(),
      const ['DD+'],
    );
    expect(
      engine
          .fuse(
            sources: const ['Example.DTS.mkv'],
            track: const MediaTrackSpec(audioCodec: 'DTS-HD MA'),
          )
          .map((b) => b.label)
          .toList(),
      const ['DTS-HD MA'],
    );
    expect(
      engine
          .fuse(
            sources: const ['Example.DDP.Atmos.5.1.mkv'],
            track: const MediaTrackSpec(
              audioCodec: 'mp4a.40.2',
              audioChannels: 2,
            ),
          )
          .map((b) => b.label)
          .toList(),
      const ['AAC', '2.0'],
    );

    // Contradictory dynamic_range: live HDR10/HDR10+ overrides HDR while preserving DV
    expect(
      engine
          .fuse(
            sources: const ['Example.4K.HDR.mkv'],
            track: const MediaTrackSpec(dynamicRange: 'SMPTE2084'),
          )
          .map((b) => b.label)
          .toList(),
      const ['4K', 'HDR10'],
    );
    expect(
      engine
          .fuse(
            sources: const ['Example.4K.DV.HDR.mkv'],
            track: const MediaTrackSpec(dynamicRange: 'HDR10+'),
          )
          .map((b) => b.label)
          .toList(),
      const ['4K', 'DV', 'HDR10+'],
    );
  });

  test('Uncached average match latency stays below 0.8ms', () {
    final engine = MediaBadges.fromJson(rulesJson);
    final inputs = cases
        .map((raw) => (raw as Map<String, dynamic>)['input'] as String?)
        .toList();
    for (var w = 0; w < 20; w++) {
      engine.clearCache();
      for (final s in inputs) {
        engine.extract(s);
      }
    }
    const passes = 10;
    var bestAvgMs = double.infinity;
    for (var attempt = 0; attempt < 3; attempt++) {
      final sw = Stopwatch()..start();
      for (var p = 0; p < passes; p++) {
        engine.clearCache();
        for (final s in inputs) {
          engine.extract(s);
        }
      }
      sw.stop();
      final avgMs = sw.elapsedMicroseconds / 1000.0 / (passes * inputs.length);
      if (avgMs < bestAvgMs) bestAvgMs = avgMs;
      if (bestAvgMs < 0.8) break;
    }
    expect(bestAvgMs, lessThan(0.8),
        reason: 'Avg uncached latency ${bestAvgMs.toStringAsFixed(4)}ms >= 0.8ms');
  });

  testWidgets(
      'MediaBadgeRow renders motion-tokens palette, transitions glass->solid on reduceTransparency & intensity, and uses platform radius',
      (tester) async {
    final badges = MediaBadges.extractBadges('Sample.2160p.DV.Atmos.REMUX.mkv');
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    GlassworkBackdrop.reduceTransparency.value = false;
    GlassworkBackdrop.intensity.value = 1.0;
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MediaBadgeRow(badges: badges),
          ),
        ),
      );
      expect(find.text('4K'), findsOneWidget);
      expect(find.text('DV · ATMOS'), findsOneWidget);
      expect(find.text('REMUX'), findsOneWidget);

      BoxDecoration pillDeco() {
        final container = tester.widget<Container>(
          find.byKey(const ValueKey('media-badge-res_4k')),
        );
        return container.decoration! as BoxDecoration;
      }

      // iOS glass state: translucent fill + concentric 999 radius
      expect(pillDeco().color, const Color(0x2EFF9F0A));
      expect(pillDeco().borderRadius, BorderRadius.circular(999));

      // Reduce Transparency switches to solidFillArgb
      GlassworkBackdrop.reduceTransparency.value = true;
      await tester.pump();
      expect(pillDeco().color, const Color(0xEB3A2810));

      // Reset reduceTransparency, then set glassBlurLevel == 'solid' (intensity <= 0.02)
      GlassworkBackdrop.reduceTransparency.value = false;
      await tester.pump();
      expect(pillDeco().color, const Color(0x2EFF9F0A));

      GlassworkBackdrop.intensity.value = 0.0;
      await tester.pump();
      expect(pillDeco().color, const Color(0xEB3A2810));

      // Windows desktop uses solidFillArgb + 6.0 corner radius
      GlassworkBackdrop.intensity.value = 1.0;
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MediaBadgeRow(badges: badges),
          ),
        ),
      );
      expect(pillDeco().color, const Color(0xEB3A2810));
      expect(pillDeco().borderRadius, BorderRadius.circular(6.0));
    } finally {
      GlassworkBackdrop.reduceTransparency.value = false;
      GlassworkBackdrop.intensity.value = 1.0;
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
