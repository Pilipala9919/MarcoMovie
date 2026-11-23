// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/local_media_proxy.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/core/ohos_runtime.dart';
import 'package:marco_movie/core/windows_tray_service.dart';
import 'package:marco_movie/core/windows_video_quality.dart';
import 'package:marco_movie/ui/adaptive_shell.dart';
import 'package:marco_movie/ui/player/player_hud_prefs.dart';
import 'package:marco_movie/ui/player_screen.dart';
import 'package:marco_movie/ui/windows_appearance.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'test_storage_helper.dart';

class _WiringNativePlatform extends Fake implements NativePlayer {
  final List<(String key, String value)> properties = [];

  @override
  Future<void> setProperty(
    String property,
    String value, {
    bool waitForInitialization = true,
  }) async {
    properties.add((property, value));
  }
}

class _WiringPlayerState extends Fake implements PlayerState {
  @override
  int? get width => 1920;
  @override
  int? get height => 1080;
  @override
  Playlist get playlist => const Playlist([]);
  @override
  bool get playing => true;
  @override
  bool get completed => false;
  @override
  Duration get position => const Duration(seconds: 20);
  @override
  Duration get duration => const Duration(minutes: 10);
  @override
  double get volume => 100.0;
  @override
  double get rate => 1.0;
  @override
  bool get buffering => false;
  @override
  Tracks get tracks => const Tracks();
  @override
  Track get track => const Track();
}

class _WiringPlayerStream extends Fake implements PlayerStream {
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

class _WiringFakeNativePlayer extends Fake implements Player {
  final _WiringNativePlatform native = _WiringNativePlatform();
  final _WiringPlayerState _state = _WiringPlayerState();
  final _WiringPlayerStream _stream = _WiringPlayerStream();
  final List<Media> opened = [];
  bool _disposed = false;

  @override
  PlatformPlayer? get platform => native;
  @override
  PlayerState get state => _state;
  @override
  PlayerStream get stream => _stream;

  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    if (playable is Media) opened.add(playable);
    _stream.widthCtrl.add(1920);
    _stream.heightCtrl.add(1080);
    _stream.durationCtrl.add(const Duration(minutes: 10));
    _stream.positionCtrl.add(const Duration(seconds: 20));
    _stream.playingCtrl.add(true);
    _stream.bufferingCtrl.add(false);
  }

  @override
  Future<void> stop() async {}
  @override
  Future<void> play() async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> setRate(double rate) async {}
  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _stream.close();
  }
}

class _StaticShellClient extends CmsClient {
  @override
  Future<(List<CmsCategory>, CmsListing)> fetchHome(CmsSite site) async => (
        const [CmsCategory(id: '1', name: '电影')],
        const CmsListing(videos: []),
      );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const windowChannel = MethodChannel('window_manager');
  const webviewJsChannel = MethodChannel('marco_movie/webview_js');

  setUp(() {
    OhosRuntime.resetForTesting();
    WindowsTrayService.resetForTesting();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(windowChannel, (call) async {
      if (call.method == 'isFullScreen') return false;
      if (call.method == 'isMaximized') return false;
      return null;
    });
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    OhosRuntime.resetForTesting();
    WindowsTrayService.resetForTesting();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(windowChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(webviewJsChannel, null);
  });

  testWidgets(
    'PlayerScreen applies Windows balancedHq HDR quality instead of bilinear and exposes HUD controls',
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
    (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1280, 720);
      await tester.binding.setSurfaceSize(const Size(1280, 720));
      addTearDown(() async {
        await tester.binding.setSurfaceSize(null);
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final storage = await initTestStorage();
      final appearance = WindowsAppearance(Directory.systemTemp);
      addTearDown(appearance.dispose);
      final hudPrefs = PlayerHudPrefs.inMemory(isDesktop: true);
      addTearDown(hudPrefs.dispose);
      final player = _WiringFakeNativePlayer();

      const site = CmsSite(
        key: 'win_wiring_site',
        name: '测试源',
        type: 1,
        api: 'https://source.example/api',
        isPrivate: true,
      );
      const video = CmsVideo(
        id: 'win_wiring_vid',
        title: '4K HDR 测试影片',
        lines: [
          CmsLine(
            name: '直连',
            episodes: [
              CmsEpisode(name: '第01集', url: 'file:///tmp/wiring_test.mkv'),
            ],
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
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 250));

      // Verify old bilinear / hdr-compute-peak=no shackles are gone and
      // balancedHq properties are applied.
      expect(
        player.native.properties,
        containsAllInOrder([
          ('scale', 'spline36'),
          ('cscale', 'spline36'),
          ('dscale', 'mitchell'),
        ]),
      );
      expect(
        player.native.properties,
        contains(('hdr-compute-peak', 'yes')),
      );
      expect(
        player.native.properties.where((p) => p == ('scale', 'bilinear')),
        isEmpty,
      );

      // Verify HUD exposes Windows 0.7.0 quality & loudness quick buttons
      expect(find.byKey(const Key('desktop-video-quality-button')), findsOneWidget);
      expect(find.byKey(const Key('desktop-audio-loudness-button')), findsOneWidget);

      // Hot-switch quality preset from HUD quick popover
      await tester.tap(find.byKey(const Key('desktop-video-quality-button')));
      await tester.pump(const Duration(milliseconds: 80));
      await tester.tap(find.byKey(const Key('desktop-quality-preset-cinemaUltra')));
      await tester.pump(const Duration(milliseconds: 80));
      expect(
        player.native.properties,
        contains(('scale', 'ewa_lanczossharp')),
      );

      // Hot-switch audio loudness preset from HUD quick popover
      await tester.tap(find.byKey(const Key('desktop-audio-loudness-button')));
      await tester.pump(const Duration(milliseconds: 80));
      await tester.tap(find.byKey(const Key('desktop-loudness-preset-cinemaVocal')));
      await tester.pump(const Duration(milliseconds: 80));
      expect(
        player.native.properties,
        contains(('volume-max', '200')),
      );
      expect(
        player.native.properties,
        contains(('af', AudioLoudnessPreset.cinemaVocal.audioFilter)),
      );

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 120));
    },
  );

  testWidgets(
    'WindowsShell settings expose 0.7.0 quality, loudness, HLS ad-strip, disk cache & runtime status without BackdropFilter',
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
    (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1280, 820);
      await tester.binding.setSurfaceSize(const Size(1280, 820));
      addTearDown(() async {
        await tester.binding.setSurfaceSize(null);
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(webviewJsChannel, (call) async {
        if (call.method == 'getStatus') {
          return <String, dynamic>{
            'available': true,
            'version': '131.0.2903.86',
            'userDataDir': r'C:\ProgramData\MarcoMovie\cache\webview2',
          };
        }
        return true;
      });

      final storage = await initTestStorage();
      await tester.runAsync(
        () => storage.saveConfig(
          jsonEncode({
            'sites': [
              {
                'key': 'owned',
                'name': '测试源',
                'type': 1,
                'api': 'https://owned.invalid/api',
              },
            ],
          }),
        ),
      );
      final appearance = WindowsAppearance(Directory.systemTemp);
      addTearDown(appearance.dispose);

      await tester.pumpWidget(
        MaterialApp(
          builder: (_, child) =>
              WindowsAppearanceScope(controller: appearance, child: child!),
          home: AdaptiveShell(
            storage: storage,
            client: _StaticShellClient(),
            onSetPreventCloseForTest: (_) async {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Open Settings -> Playback tab
      await tester.tap(find.byTooltip('设置'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(WinButton, '播放'));
      await tester.pumpAndSettle();

      expect(
        find.descendant(
          of: find.byKey(const ValueKey('windows-settings-video-quality')),
          matching: find.byType(BackdropFilter),
        ),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('windows-settings-video-quality')), findsOneWidget);
      expect(find.byKey(const ValueKey('windows-settings-audio-loudness')), findsOneWidget);
      expect(find.byKey(const ValueKey('windows-settings-hls-ad-strip')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('win-setting-quality-cinemaUltra')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('win-setting-loudness-standard')));
      await tester.pumpAndSettle();
      expect(
        await WindowsVideoQualityController.readSavedQualityPreset(),
        WindowsQualityPreset.cinemaUltra,
      );
      expect(
        await WindowsVideoQualityController.readSavedLoudnessPreset(),
        AudioLoudnessPreset.standard,
      );

      // Toggle HLS ad strip switch
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('windows-settings-hls-ad-strip')),
          matching: find.byType(CupertinoSwitch),
        ),
      );
      await tester.pumpAndSettle();
      expect(storage.hlsAdStripEnabled, isFalse);
      expect(LocalMediaLease.defaultHlsAdStripEnabled, isFalse);
      // Restore default for clean global state
      await storage.setHlsAdStripEnabled(true);

      // Open More Settings tab
      await tester.tap(find.widgetWithText(WinButton, '更多设置'));
      await tester.pumpAndSettle();

      expect(
        find.descendant(
          of: find.byKey(const ValueKey('windows-settings-disk-cache')),
          matching: find.byType(BackdropFilter),
        ),
        findsNothing,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('windows-runtime-python-status')),
          matching: find.byType(BackdropFilter),
        ),
        findsNothing,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('windows-runtime-webview2-status')),
          matching: find.byType(BackdropFilter),
        ),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('windows-settings-disk-cache')), findsOneWidget);
      expect(find.byKey(const ValueKey('windows-settings-clear-disk-cache')), findsOneWidget);
      expect(find.byKey(const ValueKey('windows-runtime-python-status')), findsOneWidget);
      expect(find.byKey(const ValueKey('windows-runtime-webview2-status')), findsOneWidget);
      expect(find.textContaining('v131.0.2903.86'), findsOneWidget);

      // Change disk cache max MB to 1024 and restore back to 512
      await tester.ensureVisible(find.byKey(const ValueKey('win-setting-disk-cache-1024')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('win-setting-disk-cache-1024')));
      await tester.pumpAndSettle();
      expect(storage.diskCacheMaxMb, 1024);
      await tester.tap(find.byKey(const ValueKey('win-setting-disk-cache-512')));
      await tester.pumpAndSettle();
      expect(storage.diskCacheMaxMb, 512);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      SharedPreferences.setMockInitialValues(<String, Object>{});
    },
  );
}
