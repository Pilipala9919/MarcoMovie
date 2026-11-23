// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/core/anime4k_controller.dart';
import 'package:marco_movie/core/ohos_runtime.dart';
import 'package:marco_movie/core/windows_video_quality.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

Directory _resolveRepoRoot() {
  var dir = Directory.current;
  for (var i = 0; i < 6; i++) {
    if (File('${dir.path}${Platform.pathSeparator}THIRD_PARTY_NOTICES.md')
        .existsSync()) {
      return dir;
    }
    dir = dir.parent;
  }
  throw StateError(
    'Unable to locate repository root from ${Directory.current.path}',
  );
}

Future<ByteData> _loadDiskShader(String assetKey) async {
  final root = _resolveRepoRoot();
  final rel = assetKey.replaceAll('/', Platform.pathSeparator);
  final file = File(
    '${root.path}${Platform.pathSeparator}flutter${Platform.pathSeparator}$rel',
  );
  final bytes = await file.readAsBytes();
  return ByteData.sublistView(bytes);
}

class _FakeQualityPlayer extends Fake implements Player {
  @override
  PlatformPlayer? get platform => null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    OhosRuntime.resetForTesting();
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  tearDown(() {
    OhosRuntime.resetForTesting();
  });

  group('WindowsVideoQualityController presets & property tables', () {
    test('defaults to balancedHq and off loudness; fromId handles aliases', () {
      final ctrl = WindowsVideoQualityController(
        platformOverride: TargetPlatform.windows,
        isOhosOverride: false,
        isWebOverride: false,
        persistLocally: false,
      );
      addTearDown(ctrl.dispose);

      expect(ctrl.qualityPreset, WindowsQualityPreset.balancedHq);
      expect(ctrl.loudnessPreset, AudioLoudnessPreset.off);
      expect(ctrl.activeBaseScalers, (scale: 'spline36', cscale: 'spline36'));

      expect(WindowsQualityPreset.fromId(null), WindowsQualityPreset.balancedHq);
      expect(WindowsQualityPreset.fromId('eco'), WindowsQualityPreset.ecoCompat);
      expect(
        WindowsQualityPreset.fromId('eco_compat'),
        WindowsQualityPreset.ecoCompat,
      );
      expect(
        WindowsQualityPreset.fromId('cinemaUltra'),
        WindowsQualityPreset.cinemaUltra,
      );
      expect(
        WindowsQualityPreset.fromId('ultra'),
        WindowsQualityPreset.cinemaUltra,
      );
      expect(
        WindowsQualityPreset.fromId('unknown'),
        WindowsQualityPreset.balancedHq,
      );

      expect(AudioLoudnessPreset.fromId(null), AudioLoudnessPreset.off);
      expect(AudioLoudnessPreset.fromId('light'), AudioLoudnessPreset.light);
      expect(
        AudioLoudnessPreset.fromId('standard'),
        AudioLoudnessPreset.standard,
      );
      expect(
        AudioLoudnessPreset.fromId('cinema_vocal'),
        AudioLoudnessPreset.cinemaVocal,
      );
    });

    test('applies ecoCompat, balancedHq, and cinemaUltra property tables', () async {
      final props = <(String, String)>[];
      final player = _FakeQualityPlayer();
      final ctrl = WindowsVideoQualityController(
        platformOverride: TargetPlatform.windows,
        isOhosOverride: false,
        isWebOverride: false,
        isNativePlayerOverride: true,
        propertySetterOverride: (k, v) async => props.add((k, v)),
        persistLocally: false,
      );
      addTearDown(ctrl.dispose);

      // 1. ecoCompat
      expect(
        await ctrl.applyQualityPreset(player, WindowsQualityPreset.ecoCompat),
        isTrue,
      );
      expect(
        props,
        containsAll(const [
          ('hwdec', 'd3d11va'),
          ('scale', 'bilinear'),
          ('cscale', 'bilinear'),
          ('dscale', 'bilinear'),
          ('correct-downscaling', 'no'),
          ('linear-downscaling', 'no'),
          ('sigmoid-upscaling', 'no'),
          ('dither-depth', 'no'),
          ('hdr-compute-peak', 'no'),
          ('deband', 'no'),
        ]),
      );

      // 2. balancedHq (default recommended HDR tone-mapping preset)
      props.clear();
      expect(
        await ctrl.applyQualityPreset(player, WindowsQualityPreset.balancedHq),
        isTrue,
      );
      expect(ctrl.effectiveToneMapping, 'bt.2446a');
      expect(
        props,
        containsAll(const [
          ('hwdec', 'auto-safe'),
          ('scale', 'spline36'),
          ('cscale', 'spline36'),
          ('dscale', 'mitchell'),
          ('correct-downscaling', 'yes'),
          ('linear-downscaling', 'yes'),
          ('sigmoid-upscaling', 'yes'),
          ('dither-depth', 'auto'),
          ('hdr-compute-peak', 'yes'),
          ('deband', 'no'),
          ('gamut-mapping-mode', 'perceptual'),
          ('tone-mapping', 'bt.2446a'),
        ]),
      );

      // 3. cinemaUltra
      props.clear();
      expect(
        await ctrl.applyQualityPreset(player, WindowsQualityPreset.cinemaUltra),
        isTrue,
      );
      expect(ctrl.effectiveScale, 'ewa_lanczossharp');
      expect(
        props,
        containsAll(const [
          ('hwdec', 'auto-safe'),
          ('scale', 'ewa_lanczossharp'),
          ('cscale', 'spline36'),
          ('dscale', 'mitchell'),
          ('correct-downscaling', 'yes'),
          ('linear-downscaling', 'yes'),
          ('sigmoid-upscaling', 'yes'),
          ('dither-depth', 'auto'),
          ('hdr-compute-peak', 'yes'),
          ('deband', 'yes'),
          ('gamut-mapping-mode', 'perceptual'),
          ('tone-mapping', 'bt.2446a'),
          ('target-colorspace-hint', 'yes'),
        ]),
      );
    });

    test(
      'tone-mapping gracefully falls back bt.2446a -> bt.2390 -> spline and survives unsupported optional props',
      () async {
        final accepted = <(String, String)>[];
        final attemptedToneMappings = <String>[];
        final player = _FakeQualityPlayer();

        final ctrl = WindowsVideoQualityController(
          platformOverride: TargetPlatform.windows,
          isOhosOverride: false,
          isWebOverride: false,
          isNativePlayerOverride: true,
          persistLocally: false,
          propertySetterOverride: (k, v) async {
            if (k == 'gamut-mapping-mode' || k == 'target-colorspace-hint') {
              throw StateError('unsupported property $k');
            }
            if (k == 'tone-mapping') {
              attemptedToneMappings.add(v);
              if (v == 'bt.2446a' || v == 'bt.2390') {
                throw ArgumentError('unsupported tone-mapping $v');
              }
            }
            if (k == 'scale' && v == 'ewa_lanczossharp') {
              throw ArgumentError('unsupported scaler $v');
            }
            accepted.add((k, v));
          },
        );
        addTearDown(ctrl.dispose);

        final ok = await ctrl.applyQualityPreset(
          player,
          WindowsQualityPreset.cinemaUltra,
        );
        expect(ok, isTrue);
        expect(attemptedToneMappings, equals(const ['bt.2446a', 'bt.2390', 'spline']));
        expect(ctrl.effectiveToneMapping, 'spline');
        expect(ctrl.effectiveScale, 'spline36');
        expect(ctrl.activeBaseScalers, (scale: 'spline36', cscale: 'spline36'));
        expect(accepted, contains(('scale', 'spline36')));
        expect(accepted, contains(('tone-mapping', 'spline')));
        expect(accepted, contains(('deband', 'yes')));

        // Also test stopping at bt.2390 when only bt.2446a fails.
        attemptedToneMappings.clear();
        final ctrl2 = WindowsVideoQualityController(
          platformOverride: TargetPlatform.windows,
          isOhosOverride: false,
          isWebOverride: false,
          isNativePlayerOverride: true,
          persistLocally: false,
          propertySetterOverride: (k, v) async {
            if (k == 'tone-mapping') {
              attemptedToneMappings.add(v);
              if (v == 'bt.2446a') {
                throw ArgumentError('unsupported $v');
              }
            }
          },
        );
        addTearDown(ctrl2.dispose);
        expect(
          await ctrl2.applyQualityPreset(player, WindowsQualityPreset.balancedHq),
          isTrue,
        );
        expect(attemptedToneMappings, equals(const ['bt.2446a', 'bt.2390']));
        expect(ctrl2.effectiveToneMapping, 'bt.2390');
      },
    );
  });

  group('Smart hwdec linkage & 4-tier audio loudness', () {
    test('switches hwdec to d3d11va-copy for Anime4K, soft filters, and compat kernel', () async {
      final props = <(String, String)>[];
      final player = _FakeQualityPlayer();
      final ctrl = WindowsVideoQualityController(
        platformOverride: TargetPlatform.windows,
        isOhosOverride: false,
        isWebOverride: false,
        isNativePlayerOverride: true,
        propertySetterOverride: (k, v) async => props.add((k, v)),
        persistLocally: false,
      );
      addTearDown(ctrl.dispose);

      // Default balancedHq without Anime4K / soft filters / ijk -> auto-safe
      expect(
        WindowsVideoQualityController.resolveHardwareDecoder(
          qualityPreset: WindowsQualityPreset.balancedHq,
        ),
        'auto-safe',
      );
      expect(
        WindowsVideoQualityController.resolveHardwareDecoder(
          qualityPreset: WindowsQualityPreset.balancedHq,
          preferZeroCopyD3d11: true,
        ),
        'd3d11va',
      );
      expect(
        WindowsVideoQualityController.resolveHardwareDecoder(
          qualityPreset: WindowsQualityPreset.ecoCompat,
        ),
        'd3d11va',
      );

      // Anime4K enabled -> d3d11va-copy, and applyQualityPreset does not overwrite Anime4K spline36
      await ctrl.applyQualityPreset(
        player,
        WindowsQualityPreset.ecoCompat,
        anime4kActive: true,
      );
      expect(ctrl.effectiveHwdec, 'd3d11va-copy');
      expect(props, contains(('hwdec', 'd3d11va-copy')));
      expect(props.any((e) => e.$1 == 'scale' && e.$2 == 'bilinear'), isFalse);

      // Compat kernel ('ijk') -> d3d11va-copy
      props.clear();
      expect(
        await ctrl.syncHardwareDecoder(player, playerKernel: 'ijk'),
        'd3d11va-copy',
      );
      expect(props, equals(const [('hwdec', 'd3d11va-copy')]));

      // Soft filter active -> d3d11va-copy
      props.clear();
      expect(
        await ctrl.syncHardwareDecoder(player, softFilterActive: true),
        'd3d11va-copy',
      );
      expect(props, equals(const [('hwdec', 'd3d11va-copy')]));

      // Disabling Anime4K/soft filter on balancedHq restores auto-safe
      await ctrl.applyQualityPreset(player, WindowsQualityPreset.balancedHq);
      expect(ctrl.effectiveHwdec, 'auto-safe');
    });

    test('applies 4-tier AudioLoudnessPreset with volume-max=200 and dynaudnorm fallback', () async {
      final props = <(String, String)>[];
      final player = _FakeQualityPlayer();
      final ctrl = WindowsVideoQualityController(
        platformOverride: TargetPlatform.windows,
        isOhosOverride: false,
        isWebOverride: false,
        isNativePlayerOverride: true,
        propertySetterOverride: (k, v) async => props.add((k, v)),
        persistLocally: false,
      );
      addTearDown(ctrl.dispose);

      // light
      expect(
        await ctrl.applyLoudnessPreset(player, AudioLoudnessPreset.light),
        isTrue,
      );
      expect(
        props,
        equals(const [
          ('volume-max', '200'),
          ('af', 'lavfi=[dynaudnorm=f=250:g=21:p=0.90:m=4.0]'),
        ]),
      );

      // standard
      props.clear();
      expect(
        await ctrl.applyLoudnessPreset(player, AudioLoudnessPreset.standard),
        isTrue,
      );
      expect(
        props,
        equals(const [
          ('volume-max', '200'),
          ('af', 'lavfi=[dynaudnorm=f=150:g=15:p=0.95]'),
        ]),
      );

      // cinemaVocal
      props.clear();
      expect(
        await ctrl.applyLoudnessPreset(player, AudioLoudnessPreset.cinemaVocal),
        isTrue,
      );
      expect(
        props,
        equals(const [
          ('volume-max', '200'),
          ('af', 'lavfi=[dynaudnorm=f=100:g=9:p=0.95:m=12.0]'),
        ]),
      );

      // off clears af and resets volume-max
      props.clear();
      expect(
        await ctrl.applyLoudnessPreset(player, AudioLoudnessPreset.off),
        isTrue,
      );
      expect(
        props,
        equals(const [
          ('volume-max', '100'),
          ('af', ''),
        ]),
      );

      // Fallback when extended dynaudnorm params fail
      final fallbackProps = <(String, String)>[];
      final fallbackCtrl = WindowsVideoQualityController(
        platformOverride: TargetPlatform.windows,
        isOhosOverride: false,
        isWebOverride: false,
        isNativePlayerOverride: true,
        persistLocally: false,
        propertySetterOverride: (k, v) async {
          if (k == 'af' && v.contains('m=12.0')) {
            throw StateError('unsupported param m');
          }
          fallbackProps.add((k, v));
        },
      );
      addTearDown(fallbackCtrl.dispose);

      expect(
        await fallbackCtrl.applyLoudnessPreset(
          player,
          AudioLoudnessPreset.cinemaVocal,
        ),
        isTrue,
      );
      expect(
        fallbackProps,
        equals(const [
          ('volume-max', '200'),
          ('af', 'lavfi=[dynaudnorm=f=150:g=15:p=0.95]'),
        ]),
      );
    });
  });

  group('Anime4K decoupling & SharedPreferences persistence', () {
    test(
      'enabling and disabling Anime4K restores balancedHq spline36 (or cinemaUltra ewa_lanczossharp) instead of forcing bilinear',
      () async {
        final tempDir = await Directory.systemTemp.createTemp('win_q_a4k_');
        addTearDown(() => tempDir.delete(recursive: true));
        final props = <(String, String)>[];
        final player = _FakeQualityPlayer();

        final quality = WindowsVideoQualityController(
          platformOverride: TargetPlatform.windows,
          isOhosOverride: false,
          isWebOverride: false,
          isNativePlayerOverride: true,
          propertySetterOverride: (k, v) async => props.add((k, v)),
          persistLocally: false,
        );
        addTearDown(quality.dispose);

        final a4k = Anime4kController(
          platformOverride: TargetPlatform.windows,
          isOhosOverride: false,
          isWebOverride: false,
          isNativePlayerOverride: true,
          cacheDirResolver: () async => tempDir,
          assetLoader: _loadDiskShader,
          propertySetterOverride: (k, v) async => props.add((k, v)),
          windowsBaseScalerResolver: () => quality.activeBaseScalers,
          persistLocally: false,
        );
        addTearDown(a4k.dispose);

        // Apply balancedHq first
        await quality.applyQualityPreset(player, WindowsQualityPreset.balancedHq);
        props.clear();

        // Enable Anime4K then disable Anime4K -> MUST restore spline36, NOT bilinear!
        expect(await a4k.applyPreset(player, Anime4kPreset.balanced), isTrue);
        props.clear();
        expect(await a4k.applyPreset(player, Anime4kPreset.off), isTrue);
        expect(
          props,
          equals(const [
            ('glsl-shaders', ''),
            ('scale', 'spline36'),
            ('cscale', 'spline36'),
          ]),
        );
        expect(props.any((e) => e.$2 == 'bilinear'), isFalse);

        // Switch quality to cinemaUltra, enable Anime4K, then resetSession -> restores ewa_lanczossharp + spline36!
        await quality.applyQualityPreset(player, WindowsQualityPreset.cinemaUltra);
        expect(await a4k.applyPreset(player, Anime4kPreset.performance), isTrue);
        props.clear();
        await a4k.resetSession(player);
        expect(
          props,
          equals(const [
            ('glsl-shaders', ''),
            ('scale', 'ewa_lanczossharp'),
            ('cscale', 'spline36'),
          ]),
        );

        // Switch quality to ecoCompat, enable Anime4K, then disable -> restores bilinear
        await quality.applyQualityPreset(player, WindowsQualityPreset.ecoCompat);
        expect(await a4k.applyPreset(player, Anime4kPreset.performance), isTrue);
        props.clear();
        expect(await a4k.applyPreset(player, Anime4kPreset.off), isTrue);
        expect(
          props,
          equals(const [
            ('glsl-shaders', ''),
            ('scale', 'bilinear'),
            ('cscale', 'bilinear'),
          ]),
        );
      },
    );

    test('persists quality & loudness presets via SharedPreferences and guards non-Windows platforms', () async {
      final player = _FakeQualityPlayer();
      final ctrl = WindowsVideoQualityController(
        platformOverride: TargetPlatform.windows,
        isOhosOverride: false,
        isWebOverride: false,
        isNativePlayerOverride: true,
        propertySetterOverride: (k, v) async {},
      );
      addTearDown(ctrl.dispose);

      await ctrl.applyQualityPreset(player, WindowsQualityPreset.cinemaUltra);
      await ctrl.applyLoudnessPreset(player, AudioLoudnessPreset.cinemaVocal);

      final reloaded = WindowsVideoQualityController(
        platformOverride: TargetPlatform.windows,
        isOhosOverride: false,
        isWebOverride: false,
      );
      addTearDown(reloaded.dispose);
      await reloaded.loadSaved();
      expect(reloaded.qualityPreset, WindowsQualityPreset.cinemaUltra);
      expect(reloaded.loudnessPreset, AudioLoudnessPreset.cinemaVocal);
      expect(
        await WindowsVideoQualityController.readSavedQualityPreset(),
        WindowsQualityPreset.cinemaUltra,
      );
      expect(
        await WindowsVideoQualityController.readSavedLoudnessPreset(),
        AudioLoudnessPreset.cinemaVocal,
      );

      // Platform guards: strictly Windows-only (non-OHOS, non-Web)
      expect(
        WindowsVideoQualityController.isSupportedPlatform(
          platformOverride: TargetPlatform.iOS,
          isOhosOverride: false,
          isWebOverride: false,
        ),
        isFalse,
      );
      expect(
        WindowsVideoQualityController.isSupportedPlatform(
          platformOverride: TargetPlatform.macOS,
          isOhosOverride: false,
          isWebOverride: false,
        ),
        isFalse,
      );
      expect(
        WindowsVideoQualityController.isSupportedPlatform(
          platformOverride: TargetPlatform.windows,
          isOhosOverride: true,
          isWebOverride: false,
        ),
        isFalse,
      );
      expect(
        WindowsVideoQualityController.isSupportedPlatform(
          platformOverride: TargetPlatform.windows,
          isOhosOverride: false,
          isWebOverride: true,
        ),
        isFalse,
      );

      final iosCtrl = WindowsVideoQualityController(
        platformOverride: TargetPlatform.iOS,
        isOhosOverride: false,
        isWebOverride: false,
        isNativePlayerOverride: true,
        propertySetterOverride: (k, v) async {},
      );
      addTearDown(iosCtrl.dispose);
      expect(iosCtrl.isAvailableForPlayer(player), isFalse);
      expect(
        await iosCtrl.applyQualityPreset(player, WindowsQualityPreset.ecoCompat),
        isFalse,
      );
    });

    test('concurrent quality preset race cancels stale operation cleanly', () async {
      final gate = Completer<void>();
      var delayedOnce = false;
      final props = <(String, String)>[];
      final player = _FakeQualityPlayer();

      final ctrl = WindowsVideoQualityController(
        platformOverride: TargetPlatform.windows,
        isOhosOverride: false,
        isWebOverride: false,
        isNativePlayerOverride: true,
        persistLocally: false,
        propertySetterOverride: (k, v) async {
          props.add((k, v));
          if (!delayedOnce && k == 'hwdec') {
            delayedOnce = true;
            await gate.future;
          }
        },
      );
      addTearDown(ctrl.dispose);

      final staleFuture = ctrl.applyQualityPreset(
        player,
        WindowsQualityPreset.ecoCompat,
      );
      await Future<void>.delayed(Duration.zero);

      final latestOk = await ctrl.applyQualityPreset(
        player,
        WindowsQualityPreset.cinemaUltra,
      );
      expect(latestOk, isTrue);
      expect(ctrl.qualityPreset, WindowsQualityPreset.cinemaUltra);
      expect(ctrl.effectiveHwdec, 'auto-safe');

      props.clear();
      gate.complete();
      expect(await staleFuture, isFalse);
      expect(ctrl.qualityPreset, WindowsQualityPreset.cinemaUltra);
      expect(ctrl.effectiveHwdec, 'auto-safe');
      expect(props, isEmpty);
    });
  });
}
