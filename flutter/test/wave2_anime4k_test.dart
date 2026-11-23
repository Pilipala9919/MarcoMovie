// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/core/anime4k_controller.dart';
import 'package:marco_movie/core/ios_avplayer_controller.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/core/ohos_runtime.dart';
import 'package:marco_movie/ui/player/player_hud_prefs.dart';
import 'package:marco_movie/ui/player_screen.dart';
import 'package:marco_movie/ui/windows_appearance.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'test_storage_helper.dart';

Directory _resolveRepoRoot() {
  var dir = Directory.current;
  for (var i = 0; i < 6; i++) {
    if (File('${dir.path}${Platform.pathSeparator}THIRD_PARTY_NOTICES.md')
        .existsSync()) {
      return dir;
    }
    dir = dir.parent;
  }
  throw StateError('Unable to locate repository root from ${Directory.current.path}');
}

class _Anime4kFakeState extends Fake implements PlayerState {
  int? widthValue = 3840;
  int? heightValue = 2160;
  bool playingValue = true;
  Duration positionValue = const Duration(seconds: 42);
  Duration durationValue = const Duration(minutes: 24);
  double volumeValue = 100.0;
  double rateValue = 1.0;

  @override
  int? get width => widthValue;
  @override
  int? get height => heightValue;
  @override
  Playlist get playlist => const Playlist([]);
  @override
  bool get playing => playingValue;
  @override
  bool get completed => false;
  @override
  Duration get position => positionValue;
  @override
  Duration get duration => durationValue;
  @override
  double get volume => volumeValue;
  @override
  double get rate => rateValue;
  @override
  bool get buffering => false;
  @override
  Tracks get tracks => const Tracks();
  @override
  Track get track => const Track();
}

class _Anime4kFakeStream extends Fake implements PlayerStream {
  final widthCtrl = StreamController<int?>.broadcast();
  final heightCtrl = StreamController<int?>.broadcast();
  final trackCtrl = StreamController<Track>.broadcast();
  final tracksCtrl = StreamController<Tracks>.broadcast();
  final positionCtrl = StreamController<Duration>.broadcast();
  final durationCtrl = StreamController<Duration>.broadcast();
  final playingCtrl = StreamController<bool>.broadcast();
  final bufferingCtrl = StreamController<bool>.broadcast();
  final completedCtrl = StreamController<bool>.broadcast();
  final errorCtrl = StreamController<String>.broadcast();
  final volumeCtrl = StreamController<double>.broadcast();

  @override
  Stream<int?> get width => widthCtrl.stream;
  @override
  Stream<int?> get height => heightCtrl.stream;
  @override
  Stream<Track> get track => trackCtrl.stream;
  @override
  Stream<Tracks> get tracks => tracksCtrl.stream;
  @override
  Stream<Duration> get position => positionCtrl.stream;
  @override
  Stream<Duration> get duration => durationCtrl.stream;
  @override
  Stream<bool> get playing => playingCtrl.stream;
  @override
  Stream<bool> get buffering => bufferingCtrl.stream;
  @override
  Stream<bool> get completed => completedCtrl.stream;
  @override
  Stream<String> get error => errorCtrl.stream;
  @override
  Stream<double> get volume => volumeCtrl.stream;

  Future<void> close() async {
    await Future.wait([
      widthCtrl.close(),
      heightCtrl.close(),
      trackCtrl.close(),
      tracksCtrl.close(),
      positionCtrl.close(),
      durationCtrl.close(),
      playingCtrl.close(),
      bufferingCtrl.close(),
      completedCtrl.close(),
      errorCtrl.close(),
      volumeCtrl.close(),
    ]);
  }
}

class _Anime4kFakePlayer extends Fake implements Player {
  final _state = _Anime4kFakeState();
  final _stream = _Anime4kFakeStream();
  final VoidCallback? onDisposeCallback;
  int openCount = 0;
  bool _disposed = false;

  _Anime4kFakePlayer({this.onDisposeCallback});

  @override
  PlatformPlayer? get platform => null;
  @override
  PlayerState get state => _state;
  @override
  PlayerStream get stream => _stream;

  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    openCount++;
    _stream.widthCtrl.add(_state.widthValue);
    _stream.heightCtrl.add(_state.heightValue);
    _stream.durationCtrl.add(_state.durationValue);
    _stream.positionCtrl.add(_state.positionValue);
    _stream.playingCtrl.add(true);
    _stream.bufferingCtrl.add(false);
  }

  @override
  Future<void> stop() async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> play() async {}
  @override
  Future<void> setRate(double rate) async {}
  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    onDisposeCallback?.call();
    await _stream.close();
  }
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

  group('M6 Anime4K v4.0.1 provenance, presets & SHA-256 integrity', () {
    test('presets map to exact spec v4.0.1 shader chains', () {
      expect(Anime4kPreset.off.shaderFiles, isEmpty);
      expect(
        Anime4kPreset.performance.shaderFiles,
        equals(const [
          'Anime4K_Clamp_Highlights.glsl',
          'Anime4K_Restore_CNN_S.glsl',
        ]),
      );
      expect(
        Anime4kPreset.balanced.shaderFiles,
        equals(const [
          'Anime4K_Clamp_Highlights.glsl',
          'Anime4K_Restore_CNN_M.glsl',
          'Anime4K_Upscale_CNN_x2_S.glsl',
        ]),
      );
      expect(
        Anime4kPreset.quality.shaderFiles,
        equals(const [
          'Anime4K_Clamp_Highlights.glsl',
          'Anime4K_Restore_CNN_VL.glsl',
          'Anime4K_Upscale_CNN_x2_M.glsl',
        ]),
      );
    });

    test(
      'bundled v4.0.1 GLSL files on disk match manifest.json, controller SHA-256 table, and THIRD_PARTY_NOTICES.md',
      () {
        final root = _resolveRepoRoot();
        final shaderDir = Directory(
          '${root.path}${Platform.pathSeparator}flutter${Platform.pathSeparator}assets${Platform.pathSeparator}shaders${Platform.pathSeparator}anime4k',
        );
        expect(shaderDir.existsSync(), isTrue);

        final manifestFile = File(
          '${shaderDir.path}${Platform.pathSeparator}manifest.json',
        );
        expect(manifestFile.existsSync(), isTrue);
        final manifest =
            jsonDecode(manifestFile.readAsStringSync()) as Map<String, dynamic>;
        expect(manifest['tag'], 'v4.0.1');
        expect(manifest['license'], 'MIT');
        expect(manifest['upstream'], 'https://github.com/bloc97/Anime4K');

        final licFile = File(
          '${shaderDir.path}${Platform.pathSeparator}ANIME4K-LICENSE.txt',
        );
        expect(licFile.existsSync(), isTrue);
        expect(
          sha256.convert(licFile.readAsBytesSync()).toString(),
          manifest['licenseSha256'],
        );

        final filesMap = Map<String, dynamic>.from(manifest['files'] as Map);
        expect(filesMap.keys.toSet(), Anime4kController.expectedShaderSha256.keys.toSet());

        for (final entry in Anime4kController.expectedShaderSha256.entries) {
          final glsl = File(
            '${shaderDir.path}${Platform.pathSeparator}${entry.key}',
          );
          expect(glsl.existsSync(), isTrue, reason: 'Missing ${entry.key}');
          final bytes = glsl.readAsBytesSync();
          expect(bytes.length, greaterThan(500));
          final actualHash = sha256.convert(bytes).toString();
          expect(actualHash, entry.value, reason: 'Hash mismatch for ${entry.key}');
          final meta = Map<String, dynamic>.from(filesMap[entry.key] as Map);
          expect(meta['sha256'], actualHash);
          expect(meta['sizeBytes'], bytes.length);
        }

        final notices = File(
          '${root.path}${Platform.pathSeparator}THIRD_PARTY_NOTICES.md',
        ).readAsStringSync();
        expect(notices, contains('bloc97/Anime4K'));
        expect(notices, contains('v4.0.1'));
        expect(notices, contains('Copyright (c) 2019 bloc97'));
        expect(notices, contains('MIT License'));
      },
    );
  });

  group('M6 Anime4K Windows bilinear<->spline36 contract, macOS & guards', () {
    Future<ByteData> loadDiskShader(String assetKey) async {
      final root = _resolveRepoRoot();
      final rel = assetKey.replaceAll('/', Platform.pathSeparator);
      final file = File(
        '${root.path}${Platform.pathSeparator}flutter${Platform.pathSeparator}$rel',
      );
      final bytes = await file.readAsBytes();
      return ByteData.sublistView(bytes);
    }

    test(
      'Windows switches scale/cscale bilinear -> spline36 on enable, joins paths with ";", and IMMEDIATELY restores bilinear on Off / reset / error',
      () async {
        final tempDir = await Directory.systemTemp.createTemp('a4k_win_test_');
        addTearDown(() => tempDir.delete(recursive: true));
        final props = <(String, String)>[];
        final player = _Anime4kFakePlayer();
        addTearDown(player.dispose);

        final ctrl = Anime4kController(
          platformOverride: TargetPlatform.windows,
          isOhosOverride: false,
          isWebOverride: false,
          isNativePlayerOverride: true,
          cacheDirResolver: () async => tempDir,
          assetLoader: loadDiskShader,
          propertySetterOverride: (k, v) async => props.add((k, v)),
          persistLocally: false,
        );
        addTearDown(ctrl.dispose);

        // Enable balanced preset on Windows
        final okBalanced = await ctrl.applyPreset(player, Anime4kPreset.balanced);
        expect(okBalanced, isTrue);
        expect(ctrl.preset, Anime4kPreset.balanced);
        expect(player.openCount, 0); // Hot-switch without restarting playback!

        expect(props, contains(('scale', 'spline36')));
        expect(props, contains(('cscale', 'spline36')));
        final shaderCall = props.lastWhere((e) => e.$1 == 'glsl-shaders');
        final parts = shaderCall.$2.split(';');
        expect(parts.length, 3);
        expect(parts[0], endsWith('Anime4K_Clamp_Highlights.glsl'));
        expect(parts[1], endsWith('Anime4K_Restore_CNN_M.glsl'));
        expect(parts[2], endsWith('Anime4K_Upscale_CNN_x2_S.glsl'));
        for (final p in parts) {
          expect(File(p).existsSync(), isTrue);
        }

        // Switch back to Off -> MUST immediately clear glsl-shaders AND restore bilinear!
        props.clear();
        final okOff = await ctrl.applyPreset(player, Anime4kPreset.off);
        expect(okOff, isTrue);
        expect(ctrl.preset, Anime4kPreset.off);
        expect(
          props,
          equals(const [
            ('glsl-shaders', ''),
            ('scale', 'bilinear'),
            ('cscale', 'bilinear'),
          ]),
        );

        // Enable quality -> resetSession MUST also restore bilinear!
        props.clear();
        expect(await ctrl.applyPreset(player, Anime4kPreset.quality), isTrue);
        props.clear();
        await ctrl.resetSession(player);
        expect(ctrl.preset, Anime4kPreset.off);
        expect(
          props,
          equals(const [
            ('glsl-shaders', ''),
            ('scale', 'bilinear'),
            ('cscale', 'bilinear'),
          ]),
        );

        // Corrupted asset load failure -> falls back to Off and restores bilinear!
        final badTempDir = await Directory.systemTemp.createTemp('a4k_bad_');
        addTearDown(() => badTempDir.delete(recursive: true));
        final brokenCtrl = Anime4kController(
          platformOverride: TargetPlatform.windows,
          isOhosOverride: false,
          isWebOverride: false,
          isNativePlayerOverride: true,
          cacheDirResolver: () async => badTempDir,
          assetLoader: (_) async => ByteData.sublistView(Uint8List.fromList([1, 2, 3])),
          propertySetterOverride: (k, v) async => props.add((k, v)),
          persistLocally: false,
        );
        addTearDown(brokenCtrl.dispose);
        props.clear();
        expect(
          await brokenCtrl.applyPreset(player, Anime4kPreset.performance),
          isFalse,
        );
        expect(brokenCtrl.preset, Anime4kPreset.off);
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

    test(
      'macOS joins shader paths with ":" and does not touch Windows bilinear properties',
      () async {
        final tempDir = await Directory.systemTemp.createTemp('a4k_mac_test_');
        addTearDown(() => tempDir.delete(recursive: true));
        final props = <(String, String)>[];
        final player = _Anime4kFakePlayer();
        addTearDown(player.dispose);

        final ctrl = Anime4kController(
          platformOverride: TargetPlatform.macOS,
          isOhosOverride: false,
          isWebOverride: false,
          isNativePlayerOverride: true,
          cacheDirResolver: () async => tempDir,
          assetLoader: loadDiskShader,
          propertySetterOverride: (k, v) async => props.add((k, v)),
          persistLocally: false,
        );
        addTearDown(ctrl.dispose);

        expect(await ctrl.applyPreset(player, Anime4kPreset.performance), isTrue);
        expect(props.any((e) => e.$1 == 'scale' || e.$1 == 'cscale'), isFalse);
        final shaderCall = props.singleWhere((e) => e.$1 == 'glsl-shaders');
        expect(shaderCall.$2.contains(':'), isTrue);
        expect(shaderCall.$2, contains('Anime4K_Clamp_Highlights.glsl'));
        expect(shaderCall.$2, contains('Anime4K_Restore_CNN_S.glsl'));
      },
    );

    test('strictly hidden/disabled on iOS, Android, Linux, OHOS, and non-NativePlayer', () {
      final player = _Anime4kFakePlayer();
      addTearDown(player.dispose);

      expect(
        Anime4kController.isSupportedPlatform(
          platformOverride: TargetPlatform.windows,
          isOhosOverride: false,
          isWebOverride: false,
        ),
        isTrue,
      );
      expect(
        Anime4kController.isSupportedPlatform(
          platformOverride: TargetPlatform.macOS,
          isOhosOverride: false,
          isWebOverride: false,
        ),
        isTrue,
      );
      expect(
        Anime4kController.isSupportedPlatform(
          platformOverride: TargetPlatform.iOS,
          isOhosOverride: false,
          isWebOverride: false,
        ),
        isFalse,
      );
      expect(
        Anime4kController.isSupportedPlatform(
          platformOverride: TargetPlatform.android,
          isOhosOverride: false,
          isWebOverride: false,
        ),
        isFalse,
      );
      expect(
        Anime4kController.isSupportedPlatform(
          platformOverride: TargetPlatform.windows,
          isOhosOverride: true,
          isWebOverride: false,
        ),
        isFalse,
      );

      // Non-NativePlayer (platform == null) gracefully reports unavailable
      final nonNativeCtrl = Anime4kController(
        platformOverride: TargetPlatform.windows,
        isOhosOverride: false,
        isWebOverride: false,
      );
      addTearDown(nonNativeCtrl.dispose);
      expect(nonNativeCtrl.isAvailableForPlayer(player), isFalse);

      // >1080p warning threshold
      expect(Anime4kController.shouldShowUltraHdWarning(1080), isFalse);
      expect(Anime4kController.shouldShowUltraHdWarning(1081), isTrue);
      expect(Anime4kController.shouldShowUltraHdWarning(2160), isTrue);
    });

    testWidgets(
      'PlayerScreen shows Anime4K selector + >1080p warning on Windows desktop and hides on iOS/OHOS',
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
      (tester) async {
        tester.view.devicePixelRatio = 1.0;
        tester.view.physicalSize = const Size(1280, 720);
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        final tempDir = Directory.systemTemp.createTempSync('a4k_ui_test_');
        addTearDown(() {
          if (tempDir.existsSync()) {
            tempDir.deleteSync(recursive: true);
          }
        });
        final props = <(String, String)>[];
        final player = _Anime4kFakePlayer();
        final storage = await initTestStorage();
        final appearance = WindowsAppearance(Directory.systemTemp);
        addTearDown(appearance.dispose);
        final hudPrefs = PlayerHudPrefs.inMemory(isDesktop: true);
        addTearDown(hudPrefs.dispose);
        final a4k = Anime4kController(
          platformOverride: TargetPlatform.windows,
          isOhosOverride: false,
          isWebOverride: false,
          isNativePlayerOverride: true,
          cacheDirResolver: () async => tempDir,
          assetLoader: loadDiskShader,
          propertySetterOverride: (k, v) async => props.add((k, v)),
          persistLocally: false,
        );
        addTearDown(a4k.dispose);

        const site = CmsSite(
          key: 'a4k_site',
          name: '桌面超分源',
          type: 1,
          api: 'https://a4k.example/api',
        );
        const video = CmsVideo(
          id: 'a4k_vid',
          title: '4K 测试影片',
          lines: [
            CmsLine(
              name: '主线路',
              episodes: [CmsEpisode(name: '第01集', url: 'https://a4k.example/e1.mp4')],
            ),
          ],
        );

        await tester.pumpWidget(
          MaterialApp(
            builder: (_, child) =>
                WindowsAppearanceScope(controller: appearance, child: child!),
            home: PlayerScreen(
              site: site,
              video: video,
              initialLineIndex: 0,
              initialEpisodeIndex: 0,
              storage: storage,
              debugPlayer: player,
              debugVideoSurface: const ColoredBox(color: Colors.black),
              debugHudPrefs: hudPrefs,
              debugAnime4kController: a4k,
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 200));

        final btn = find.byKey(const Key('desktop-anime4k-button'));
        expect(btn, findsOneWidget);
        await tester.tap(btn);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));

        expect(find.byKey(const Key('anime4k-ultrahd-warning')), findsOneWidget);
        expect(
          find.text('当前已是超清分辨率，开启 Anime4K 会显著增加显卡负载'),
          findsOneWidget,
        );

        // Tap '性能' preset -> hot-switches without restarting playback
        final opensBefore = player.openCount;
        await tester.tap(find.byKey(const ValueKey('anime4k-preset-performance')));
        for (var i = 0; i < 30 && a4k.preset != Anime4kPreset.performance; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump();
        }
        await tester.pump(const Duration(milliseconds: 350));
        expect(
          a4k.preset,
          Anime4kPreset.performance,
          reason: 'lastError=${a4k.lastError}',
        );
        expect(player.openCount, opensBefore);
        expect(props, contains(('scale', 'spline36')));
        expect(props, contains(('cscale', 'spline36')));

        // Unmount player cleanly before verifying OHOS hides Anime4K button.
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();

        OhosRuntime.debugIsOhosOverride = true;
        addTearDown(OhosRuntime.resetForTesting);
        final ohosPlayer = _Anime4kFakePlayer();
        await tester.pumpWidget(
          MaterialApp(
            builder: (_, child) =>
                WindowsAppearanceScope(controller: appearance, child: child!),
            home: PlayerScreen(
              site: site,
              video: video,
              initialLineIndex: 0,
              initialEpisodeIndex: 0,
              storage: storage,
              debugPlayer: ohosPlayer,
              debugVideoSurface: const ColoredBox(color: Colors.black),
              debugHudPrefs: hudPrefs,
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 200));
        expect(find.byKey(const Key('desktop-anime4k-button')), findsNothing);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      },
    );

    test(
      'R2 #29-M2/#27-m1: concurrent Quality -> Off race never lets stale Quality overwrite Off + Windows bilinear',
      () async {
        final tempDir = await Directory.systemTemp.createTemp('a4k_race_test_');
        addTearDown(() => tempDir.delete(recursive: true));
        final props = <(String, String)>[];
        final player = _Anime4kFakePlayer();
        addTearDown(player.dispose);

        final gate = Completer<void>();
        var interceptedOnce = false;
        final ctrl = Anime4kController(
          platformOverride: TargetPlatform.windows,
          isOhosOverride: false,
          isWebOverride: false,
          isNativePlayerOverride: true,
          cacheDirResolver: () async => tempDir,
          assetLoader: (assetKey) async {
            if (!interceptedOnce) {
              interceptedOnce = true;
              await gate.future;
            }
            return loadDiskShader(assetKey);
          },
          propertySetterOverride: (k, v) async => props.add((k, v)),
          persistLocally: false,
        );
        addTearDown(ctrl.dispose);

        // Start slow Quality apply (suspends on shader extraction).
        final staleQualityFuture = ctrl.applyPreset(player, Anime4kPreset.quality);
        await Future<void>.delayed(Duration.zero);

        // Immediately switch to Off while Quality is still extracting.
        final offOk = await ctrl.applyPreset(player, Anime4kPreset.off);
        expect(offOk, isTrue);
        expect(ctrl.preset, Anime4kPreset.off);
        expect(
          props,
          equals(const [
            ('glsl-shaders', ''),
            ('scale', 'bilinear'),
            ('cscale', 'bilinear'),
          ]),
        );

        // Release stale Quality extraction -> MUST abort via _opGen and NOT overwrite Off/bilinear!
        props.clear();
        gate.complete();
        final staleQualityOk = await staleQualityFuture;
        expect(staleQualityOk, isFalse);
        expect(ctrl.preset, Anime4kPreset.off);
        expect(props, isEmpty);

        // Also verify stale error fallback does NOT clobber a newer Performance preset.
        final failGate = Completer<void>();
        final errProps = <(String, String)>[];
        final ctrl2 = Anime4kController(
          platformOverride: TargetPlatform.windows,
          isOhosOverride: false,
          isWebOverride: false,
          isNativePlayerOverride: true,
          cacheDirResolver: () async => tempDir,
          assetLoader: (assetKey) async {
            if (assetKey.contains('Restore_CNN_VL')) {
              await failGate.future;
              throw StateError('stale quality failure');
            }
            return loadDiskShader(assetKey);
          },
          propertySetterOverride: (k, v) async => errProps.add((k, v)),
          persistLocally: false,
        );
        addTearDown(ctrl2.dispose);

        final staleFailFuture = ctrl2.applyPreset(player, Anime4kPreset.quality);
        await Future<void>.delayed(Duration.zero);
        final perfOk = await ctrl2.applyPreset(player, Anime4kPreset.performance);
        expect(perfOk, isTrue);
        expect(ctrl2.preset, Anime4kPreset.performance);

        errProps.clear();
        failGate.complete();
        expect(await staleFailFuture, isFalse);
        expect(ctrl2.preset, Anime4kPreset.performance);
        expect(errProps, isEmpty);
      },
    );

    testWidgets(
      'R2 #29-M2: PlayerScreen.dispose() resets Anime4K and restores Windows bilinear strictly BEFORE _player.dispose()',
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
      (tester) async {
        tester.view.devicePixelRatio = 1.0;
        tester.view.physicalSize = const Size(1280, 720);
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        final tempDir = Directory.systemTemp.createTempSync('a4k_disp_test_');
        addTearDown(() {
          if (tempDir.existsSync()) {
            tempDir.deleteSync(recursive: true);
          }
        });
        final events = <String>[];
        final player = _Anime4kFakePlayer(
          onDisposeCallback: () => events.add('player:dispose'),
        );
        final storage = await initTestStorage();
        final appearance = WindowsAppearance(Directory.systemTemp);
        addTearDown(appearance.dispose);
        final hudPrefs = PlayerHudPrefs.inMemory(isDesktop: true);
        addTearDown(hudPrefs.dispose);
        final a4k = Anime4kController(
          platformOverride: TargetPlatform.windows,
          isOhosOverride: false,
          isWebOverride: false,
          isNativePlayerOverride: true,
          cacheDirResolver: () async => tempDir,
          assetLoader: loadDiskShader,
          propertySetterOverride: (k, v) async => events.add('prop:$k=$v'),
          persistLocally: false,
        );
        addTearDown(a4k.dispose);

        const site = CmsSite(
          key: 'a4k_disp_site',
          name: '释放测试源',
          type: 1,
          api: 'https://a4k.example/api',
        );
        const video = CmsVideo(
          id: 'a4k_disp_vid',
          title: '释放恢复测试影片',
          lines: [
            CmsLine(
              name: '主线路',
              episodes: [CmsEpisode(name: '第01集', url: 'https://a4k.example/e1.mp4')],
            ),
          ],
        );

        await tester.pumpWidget(
          MaterialApp(
            builder: (_, child) =>
                WindowsAppearanceScope(controller: appearance, child: child!),
            home: PlayerScreen(
              site: site,
              video: video,
              initialLineIndex: 0,
              initialEpisodeIndex: 0,
              storage: storage,
              debugPlayer: player,
              debugVideoSurface: const ColoredBox(color: Colors.black),
              debugHudPrefs: hudPrefs,
              debugAnime4kController: a4k,
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 200));

        // Activate performance preset -> switches to spline36.
        await tester.runAsync(
          () => a4k.applyPreset(player, Anime4kPreset.performance),
        );
        await tester.pump();
        expect(a4k.preset, Anime4kPreset.performance);

        events.clear();
        // Unmount PlayerScreen -> MUST call resetSession (clear glsl-shaders + restore bilinear)
        // strictly BEFORE _player.dispose()!
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();

        expect(a4k.preset, Anime4kPreset.off);
        final clearIdx = events.indexOf('prop:glsl-shaders=');
        final scaleIdx = events.indexOf('prop:scale=bilinear');
        final cscaleIdx = events.indexOf('prop:cscale=bilinear');
        final disposeIdx = events.indexOf('player:dispose');
        expect(clearIdx, greaterThanOrEqualTo(0), reason: 'events=$events');
        expect(scaleIdx, greaterThan(clearIdx), reason: 'events=$events');
        expect(cscaleIdx, greaterThan(scaleIdx), reason: 'events=$events');
        expect(disposeIdx, greaterThan(cscaleIdx), reason: 'events=$events');
      },
    );

    test(
      'Windows decoupled windowsBaseScalerResolver restores spline36 / ewa_lanczossharp instead of forcing bilinear on Off / reset / error',
      () async {
        final tempDir = await Directory.systemTemp.createTemp('a4k_decoupled_');
        addTearDown(() => tempDir.delete(recursive: true));
        final props = <(String, String)>[];
        final player = _Anime4kFakePlayer();
        addTearDown(player.dispose);

        var currentScalers = (scale: 'spline36', cscale: 'spline36');
        final ctrl = Anime4kController(
          platformOverride: TargetPlatform.windows,
          isOhosOverride: false,
          isWebOverride: false,
          isNativePlayerOverride: true,
          cacheDirResolver: () async => tempDir,
          assetLoader: loadDiskShader,
          propertySetterOverride: (k, v) async => props.add((k, v)),
          windowsBaseScalerResolver: () => currentScalers,
          persistLocally: false,
        );
        addTearDown(ctrl.dispose);

        expect(await ctrl.applyPreset(player, Anime4kPreset.balanced), isTrue);
        props.clear();
        expect(await ctrl.applyPreset(player, Anime4kPreset.off), isTrue);
        expect(
          props,
          equals(const [
            ('glsl-shaders', ''),
            ('scale', 'spline36'),
            ('cscale', 'spline36'),
          ]),
        );

        // Update resolver dynamically via setWindowsBaseScalerResolver -> ewa_lanczossharp
        ctrl.setWindowsBaseScalerResolver(
          () => (scale: 'ewa_lanczossharp', cscale: 'spline36'),
        );
        expect(await ctrl.applyPreset(player, Anime4kPreset.performance), isTrue);
        props.clear();
        await ctrl.resetSession(player);
        expect(
          props,
          equals(const [
            ('glsl-shaders', ''),
            ('scale', 'ewa_lanczossharp'),
            ('cscale', 'spline36'),
          ]),
        );
      },
    );
  });

  group('iOS 27 Single-Pass Anime4K & Apple Silicon Thermal Guard', () {
    Future<ByteData> loadDiskShader(String assetKey) async {
      final root = _resolveRepoRoot();
      final rel = assetKey.replaceAll('/', Platform.pathSeparator);
      final file = File(
        '${root.path}${Platform.pathSeparator}flutter${Platform.pathSeparator}$rel',
      );
      final bytes = await file.readAsBytes();
      return ByteData.sublistView(bytes);
    }

    test('isIosLightweightSupported enables only on iOS when not OHOS/Web', () {
      expect(
        Anime4kController.isIosLightweightSupported(
          platformOverride: TargetPlatform.iOS,
          isOhosOverride: false,
          isWebOverride: false,
        ),
        isTrue,
      );
      expect(
        Anime4kController.isIosLightweightSupported(
          platformOverride: TargetPlatform.windows,
          isOhosOverride: false,
          isWebOverride: false,
        ),
        isFalse,
      );
      expect(
        Anime4kController.isIosLightweightSupported(
          platformOverride: TargetPlatform.android,
          isOhosOverride: false,
          isWebOverride: false,
        ),
        isFalse,
      );
      expect(
        Anime4kController.isIosLightweightSupported(
          platformOverride: TargetPlatform.iOS,
          isOhosOverride: true,
          isWebOverride: false,
        ),
        isFalse,
      );
    });

    test(
      'iOS lightweight loads ONLY single-pass Upscale_CNN_x2_S and thermal serious/critical auto-disables with callback',
      () async {
        final tempDir = await Directory.systemTemp.createTemp('a4k_ios_test_');
        addTearDown(() => tempDir.delete(recursive: true));
        final props = <(String, String)>[];
        final thermalAlerts = <IosThermalState>[];
        final player = _Anime4kFakePlayer();
        addTearDown(player.dispose);

        final ctrl = Anime4kController(
          platformOverride: TargetPlatform.iOS,
          isOhosOverride: false,
          isWebOverride: false,
          isNativePlayerOverride: true,
          cacheDirResolver: () async => tempDir,
          assetLoader: loadDiskShader,
          propertySetterOverride: (k, v) async => props.add((k, v)),
          onThermalAutoDisabled: thermalAlerts.add,
          persistLocally: false,
        );
        addTearDown(ctrl.dispose);

        expect(ctrl.isAvailableForPlayer(player), isFalse);
        expect(ctrl.isIosLightweightAvailableForPlayer(player), isTrue);

        // Enable single-pass shader
        final ok = await ctrl.setIosLightweightEnabled(player, true);
        expect(ok, isTrue);
        expect(ctrl.iosLightweightEnabled, isTrue);
        expect(props.any((p) => p.$1 == 'scale' || p.$1 == 'cscale'), isFalse);
        final shaderProp = props.singleWhere((p) => p.$1 == 'glsl-shaders');
        expect(shaderProp.$2, endsWith('Anime4K_Upscale_CNN_x2_S.glsl'));
        expect(shaderProp.$2.contains(';'), isFalse);
        expect(shaderProp.$2, isNot(contains('Anime4K_Clamp_Highlights.glsl')));
        expect(shaderProp.$2, isNot(contains('Anime4K_Restore_CNN')));
        expect(File(shaderProp.$2).existsSync(), isTrue);

        // Fair thermal state keeps shader enabled
        props.clear();
        await ctrl.handleThermalState(player, IosThermalState.fair);
        expect(ctrl.iosLightweightEnabled, isTrue);
        expect(thermalAlerts, isEmpty);

        // Serious thermal warning -> auto-disables glsl-shaders and triggers callback!
        await ctrl.handleThermalState(player, IosThermalState.serious);
        expect(ctrl.iosLightweightEnabled, isFalse);
        expect(ctrl.isThermalThrottled, isTrue);
        expect(props, contains(('glsl-shaders', '')));
        expect(thermalAlerts, equals(const [IosThermalState.serious]));

        // Refuses re-enabling while still in critical/serious thermal state
        props.clear();
        await ctrl.handleThermalState(player, IosThermalState.critical);
        final blocked = await ctrl.setIosLightweightEnabled(player, true);
        expect(blocked, isFalse);
        expect(ctrl.iosLightweightEnabled, isFalse);
        expect(thermalAlerts.last, IosThermalState.critical);

        // Recovers once thermal state drops back to nominal
        await ctrl.handleThermalState(player, IosThermalState.nominal);
        expect(ctrl.isThermalThrottled, isFalse);
        expect(await ctrl.setIosLightweightEnabled(player, true), isTrue);
        expect(ctrl.iosLightweightEnabled, isTrue);
      },
    );

    test('bindThermalStream automatically disables iOS shader on stream event', () async {
      final tempDir = await Directory.systemTemp.createTemp('a4k_ios_stream_');
      addTearDown(() => tempDir.delete(recursive: true));
      final props = <(String, String)>[];
      final thermalAlerts = <IosThermalState>[];
      final player = _Anime4kFakePlayer();
      addTearDown(player.dispose);
      final streamCtrl = StreamController<IosThermalState>.broadcast();
      addTearDown(streamCtrl.close);

      final ctrl = Anime4kController(
        platformOverride: TargetPlatform.iOS,
        isOhosOverride: false,
        isWebOverride: false,
        isNativePlayerOverride: true,
        cacheDirResolver: () async => tempDir,
        assetLoader: loadDiskShader,
        propertySetterOverride: (k, v) async => props.add((k, v)),
        onThermalAutoDisabled: thermalAlerts.add,
        persistLocally: false,
      );
      addTearDown(ctrl.dispose);

      ctrl.bindThermalStream(player, streamCtrl.stream);
      expect(await ctrl.setIosLightweightEnabled(player, true), isTrue);
      props.clear();

      streamCtrl.add(IosThermalState.critical);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(ctrl.iosLightweightEnabled, isFalse);
      expect(props, contains(('glsl-shaders', '')));
      expect(thermalAlerts, equals(const [IosThermalState.critical]));
    });
  });
}
