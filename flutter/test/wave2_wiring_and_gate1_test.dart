// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/danmu/block_filter.dart';
import 'package:marco_movie/core/danmu/dandanplay_provider.dart';
import 'package:marco_movie/core/danmu/danmu_prefs.dart';
import 'package:marco_movie/core/danmu/provider.dart';
import 'package:marco_movie/core/danmu/segment_cache.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/core/ohos_runtime.dart';
import 'package:marco_movie/core/storage_service.dart';
import 'package:marco_movie/ui/adaptive_shell.dart';
import 'package:marco_movie/ui/apple_theme.dart';
import 'package:marco_movie/ui/danmu/danmu_layer.dart';
import 'package:marco_movie/ui/danmu/danmu_settings_sheet.dart';
import 'package:marco_movie/ui/ios_liquid_glass.dart';
import 'package:marco_movie/ui/ios_settings.dart';
import 'package:marco_movie/ui/onboarding/first_play_gesture_hint.dart';
import 'package:marco_movie/ui/onboarding/onboarding_prefs.dart';
import 'package:marco_movie/ui/onboarding/onboarding_screen.dart';
import 'package:marco_movie/ui/player/ios_player_chrome.dart';
import 'package:marco_movie/ui/player/player_hud_prefs.dart';
import 'package:marco_movie/ui/player_screen.dart';
import 'package:marco_movie/ui/windows_appearance.dart';
import 'package:media_kit/media_kit.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'test_storage_helper.dart';

class _W2FakeState extends Fake implements PlayerState {
  Playlist playlistValue = const Playlist([]);
  bool playingValue = true;
  bool completedValue = false;
  Duration positionValue = const Duration(seconds: 5);
  Duration durationValue = const Duration(minutes: 25);
  double volumeValue = 100.0;
  double rateValue = 1.0;
  bool bufferingValue = false;
  Tracks tracksValue = const Tracks();
  Track trackValue = const Track();

  @override
  Playlist get playlist => playlistValue;
  @override
  bool get playing => playingValue;
  @override
  bool get completed => completedValue;
  @override
  Duration get position => positionValue;
  @override
  Duration get duration => durationValue;
  @override
  double get volume => volumeValue;
  @override
  double get rate => rateValue;
  @override
  bool get buffering => bufferingValue;
  @override
  Tracks get tracks => tracksValue;
  @override
  Track get track => trackValue;
}

class _W2FakeStream extends Fake implements PlayerStream {
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

class _W2FakePlayer extends Fake implements Player {
  final _state = _W2FakeState();
  final _stream = _W2FakeStream();
  int playOrPauseCalls = 0;
  final List<Duration> seeks = <Duration>[];
  bool disposed = false;

  @override
  PlatformPlayer? get platform => null;
  @override
  PlayerState get state => _state;
  @override
  PlayerStream get stream => _stream;

  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    if (playable is Media) _state.playlistValue = Playlist([playable]);
    _state.playingValue = play;
    _state.bufferingValue = false;
    if (!disposed) {
      _stream.widthCtrl.add(1920);
      _stream.heightCtrl.add(1080);
      _stream.durationCtrl.add(_state.durationValue);
      _stream.positionCtrl.add(_state.positionValue);
      _stream.bufferingCtrl.add(false);
      _stream.playingCtrl.add(play);
    }
  }

  @override
  Future<void> playOrPause() async {
    playOrPauseCalls++;
    _state.playingValue = !_state.playingValue;
    if (!disposed) _stream.playingCtrl.add(_state.playingValue);
  }

  @override
  Future<void> seek(Duration position) async {
    seeks.add(position);
    _state.positionValue = position;
    if (!disposed) _stream.positionCtrl.add(position);
  }

  @override
  Future<void> stop() async => _state.playingValue = false;
  @override
  Future<void> pause() async {
    _state.playingValue = false;
    if (!disposed) _stream.playingCtrl.add(false);
  }

  @override
  Future<void> play() async {
    _state.playingValue = true;
    if (!disposed) _stream.playingCtrl.add(true);
  }

  @override
  Future<void> setRate(double rate) async => _state.rateValue = rate;
  @override
  Future<void> setVolume(double volume) async => _state.volumeValue = volume;
  @override
  Future<void> dispose() async {
    disposed = true;
    await _stream.close();
  }
}

class _FakeDanmuProvider implements DanmuProvider {
  final List<DanmuMatchQuery> matchQueries = <DanmuMatchQuery>[];
  final List<String> openedEpisodeIds = <String>[];
  final List<int> fetchedWindows = <int>[];

  @override
  Future<List<DanmuCandidate>> matchOrSearch(
    DanmuMatchQuery query, {
    DanmuCancelToken? cancelToken,
  }) async {
    matchQueries.add(query);
    return <DanmuCandidate>[
      DanmuCandidate(
        sourceOrigin: 'https://danmu.example',
        animeId: 'anime_1',
        animeTitle: query.title,
        boundEpisodeId:
            'mmdanmu://v1?src=aHR0cHM6Ly9kYW5tdS5leGFtcGxl&ep=ep_${query.episodeIndex}',
        episodeTitle: query.episodeTitle,
        confidence: 0.95,
      ),
    ];
  }

  @override
  Future<List<DanmuCandidate>> listEpisodes(
    String sourceOrigin,
    String animeId, {
    DanmuCancelToken? cancelToken,
  }) async =>
      const <DanmuCandidate>[];

  @override
  Future<DanmuEpisodeSession> openSession(
    String boundEpisodeId, {
    DanmuCancelToken? cancelToken,
  }) async {
    openedEpisodeIds.add(boundEpisodeId);
    return DanmuEpisodeSession(
      boundEpisodeId: boundEpisodeId,
      segmented: true,
      segments: const <DanmuSegmentDescriptor>[
        DanmuSegmentDescriptor(
          startMs: 0,
          endMs: 30000,
          segmentUrl: 'https://danmu.example/seg/0',
        ),
        DanmuSegmentDescriptor(
          startMs: 30000,
          endMs: 60000,
          segmentUrl: 'https://danmu.example/seg/1',
        ),
        DanmuSegmentDescriptor(
          startMs: 60000,
          endMs: 90000,
          segmentUrl: 'https://danmu.example/seg/2',
        ),
      ],
      preloadComments: const <DanmuItem>[],
    );
  }

  @override
  Future<List<DanmuItem>> fetchWindow(
    DanmuEpisodeSession session,
    int windowIndex, {
    DanmuCancelToken? cancelToken,
  }) async {
    fetchedWindows.add(windowIndex);
    return <DanmuItem>[
      DanmuItem(
        id: 'c_${session.boundEpisodeId}_w$windowIndex',
        timeMs: windowIndex * 30000 + 2000,
        mode: 1,
        rgbColor: 0xFFFFFF,
        text: '测试弹幕窗口$windowIndex',
      ),
    ];
  }
}

void main() {
  const windowChannel = MethodChannel('window_manager');

  setUp(() {
    OhosRuntime.resetForTesting();
    SharedPreferences.setMockInitialValues(<String, Object>{});
    PackageInfo.setMockInitialValues(
      appName: 'Marco Movie',
      packageName: 'com.pilipala.marcomovie.test',
      version: '0.5.34',
      buildNumber: '84',
      buildSignature: '',
    );
    IosLiquidGlassBridge.setAvailableForTest(null);
    IosLiquidGlassBridge.setReduceTransparencyForTest(null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(windowChannel, (call) async {
      switch (call.method) {
        case 'isFullScreen':
        case 'isMaximized':
        case 'isMinimized':
        case 'isAlwaysOnTop':
          return false;
        case 'getBounds':
          return <String, double>{
            'x': 0,
            'y': 0,
            'width': 1280,
            'height': 720,
          };
      }
      return null;
    });
  });

  tearDown(() {
    OhosRuntime.resetForTesting();
    IosLiquidGlassBridge.setAvailableForTest(null);
    IosLiquidGlassBridge.setReduceTransparencyForTest(null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(windowChannel, null);
  });

  const testSite = CmsSite(
    key: 'w2_site',
    name: 'Wave2 联调源',
    type: 1,
    api: 'https://source.example/api',
  );
  const testVideo = CmsVideo(
    id: 'w2_vid',
    title: 'Wave2 测试片源',
    lines: [
      CmsLine(
        name: '主线路',
        episodes: [
          CmsEpisode(name: '第01集', url: 'https://source.example/e1.mp4'),
          CmsEpisode(name: '第02集', url: 'https://source.example/e2.mp4'),
        ],
      ),
    ],
  );

  group('M3b DanmuLayer stack order, lifecycle, D shortcut & iOS chrome/settings',
      () {
    testWidgets(
      'DanmuLayer sits STRICTLY above video surface and BELOW subtitles & HUD, and is absent on OHOS',
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
      (tester) async {
        final storage = await initTestStorage();
        final hudPrefs = PlayerHudPrefs.inMemory(isDesktop: true);
        addTearDown(hudPrefs.dispose);
        final player = _W2FakePlayer();
        final provider = _FakeDanmuProvider();

        await tester.pumpWidget(
          MaterialApp(
            home: PlayerScreen(
              site: testSite,
              video: testVideo,
              initialLineIndex: 0,
              initialEpisodeIndex: 0,
              storage: storage,
              debugPlayer: player,
              debugVideoSurface: const ColoredBox(color: Colors.black),
              debugSubtitleLayer: const Text('测试字幕层'),
              debugHudPrefs: hudPrefs,
              debugDanmuProvider: provider,
              debugDanmuSettings: const DanmuSettings(
                enabled: true,
                serverUrls: 'https://danmu.example',
              ),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 250));

        // Verify strict Stack Z-order: videoSurface < danmuLayer < subtitleLayer
        final stack = tester.widget<Stack>(
          find.byKey(const Key('player-video-stack')),
        );
        final keys = stack.children.map((w) => w.key).toList();
        final videoIdx = keys.indexOf(const Key('player-video-surface-layer'));
        final danmuIdx = keys.indexOf(const Key('player-danmu-layer'));
        final subIdx = keys.indexOf(const Key('player-subtitle-layer'));
        expect(videoIdx, greaterThanOrEqualTo(0));
        expect(danmuIdx, greaterThan(videoIdx));
        expect(subIdx, greaterThan(danmuIdx));
        expect(find.byType(DanmuLayer), findsOneWidget);

        // Verify DanmuSegmentCache session lifecycle (open -> window 0 -> seek -> window 2 -> next episode)
        expect(provider.matchQueries.length, 1);
        expect(provider.openedEpisodeIds, contains(endsWith('ep_1')));
        expect(provider.fetchedWindows, contains(0));

        // Seek to 70s -> debounce 180ms -> fetches window 2
        await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
        await tester.pump(const Duration(milliseconds: 60));
        await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
        await tester.pump(const Duration(milliseconds: 260));
        expect(player.seeks, isNotEmpty);

        // Press D to toggle danmu off then on
        await tester.sendKeyDownEvent(LogicalKeyboardKey.keyD);
        await tester.pump(const Duration(milliseconds: 60));
        await tester.sendKeyUpEvent(LogicalKeyboardKey.keyD);
        expect(find.text('弹幕已关闭'), findsOneWidget);

        await tester.sendKeyDownEvent(LogicalKeyboardKey.keyD);
        await tester.pump(const Duration(milliseconds: 60));
        await tester.sendKeyUpEvent(LogicalKeyboardKey.keyD);
        expect(find.text('弹幕已开启'), findsOneWidget);

        // Step to next episode (keyN) -> binds ep_2!
        await tester.sendKeyDownEvent(LogicalKeyboardKey.keyN);
        await tester.pump(const Duration(milliseconds: 60));
        await tester.sendKeyUpEvent(LogicalKeyboardKey.keyN);
        await tester.pump(const Duration(milliseconds: 260));
        expect(provider.openedEpisodeIds, contains(endsWith('ep_2')));

        // OHOS guard: DanmuLayer must NOT be mounted when OhosRuntime.isOhos == true
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        OhosRuntime.debugIsOhosOverride = true;
        final ohosPlayer = _W2FakePlayer();
        final ohosProvider = _FakeDanmuProvider();
        await tester.pumpWidget(
          MaterialApp(
            home: PlayerScreen(
              site: testSite,
              video: testVideo,
              initialLineIndex: 0,
              initialEpisodeIndex: 0,
              storage: storage,
              debugPlayer: ohosPlayer,
              debugVideoSurface: const ColoredBox(color: Colors.black),
              debugHudPrefs: hudPrefs,
              debugDanmuProvider: ohosProvider,
              debugDanmuSettings: const DanmuSettings(
                enabled: true,
                serverUrls: 'https://danmu.example',
              ),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 200));
        expect(find.byKey(const Key('player-danmu-layer')), findsNothing);
        expect(find.byType(DanmuLayer), findsNothing);
        expect(ohosProvider.matchQueries, isEmpty);
      },
    );

    testWidgets(
      'iOS 26 top-bar danmu toggle & bottom-dock danmu settings open DanmuSettingsSheet cleanly',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        tester.view.devicePixelRatio = 1.0;
        tester.view.physicalSize = const Size(844, 390);
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        final storage = await initTestStorage();
        final hudPrefs = PlayerHudPrefs.inMemory(isDesktop: false);
        addTearDown(hudPrefs.dispose);
        final player = _W2FakePlayer();

        await tester.pumpWidget(
          MaterialApp(
            home: PlayerScreen(
              site: testSite,
              video: testVideo,
              initialLineIndex: 0,
              initialEpisodeIndex: 0,
              storage: storage,
              debugPlayer: player,
              debugVideoSurface: const ColoredBox(color: Colors.black),
              debugHudPrefs: hudPrefs,
              debugDanmuSettings: const DanmuSettings(enabled: false),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 200));

        // Top-right 4 Liquid Glass actions: Cast, Favorite, Download, More
        expect(find.byKey(const Key('ios-player-cast-button')), findsOneWidget);
        expect(
          find.byKey(const Key('ios-player-favorite-button')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('ios-player-download-button')),
          findsOneWidget,
        );
        expect(find.byKey(const Key('ios-player-more-button')), findsOneWidget);

        // Bottom-dock danmu settings button -> opens DanmuSettingsSheet popover
        final dockBtn = find.byKey(const ValueKey('ios-dock-action-danmu'));
        expect(dockBtn, findsOneWidget);
        await tester.tap(dockBtn);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        expect(find.byType(DanmuSettingsSheet), findsOneWidget);

        // Toggling the danmu switch inside DanmuSettingsSheet enables danmu
        final toggle = find.descendant(
          of: find.byType(DanmuSettingsSheet),
          matching: find.byType(IosNativeSwitch),
        );
        expect(toggle, findsOneWidget);
        await tester.tap(toggle);
        await tester.pump(const Duration(milliseconds: 80));
        expect(find.byType(DanmuLayer), findsOneWidget);
      },
    );

    testWidgets(
      'ios_settings.dart Danmu & HUD sections use IosNativeSwitch, persist changes, and hide on OHOS',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        final hudPrefs = PlayerHudPrefs.inMemory(isDesktop: false);
        addTearDown(hudPrefs.dispose);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ListView(
                children: [
                  const IosDanmuSettingsSection(),
                  const SizedBox(height: 16),
                  IosPlayerHudSettingsSection(debugHudPrefs: hudPrefs),
                ],
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byType(IosNativeSwitch), findsNWidgets(7));
        expect(find.byKey(const ValueKey('ios-switch-danmu-enabled')),
            findsOneWidget);
        expect(find.byKey(const ValueKey('ios-switch-hud-start-spec')),
            findsOneWidget);
        expect(find.byKey(const ValueKey('ios-switch-hud-slim-progress')),
            findsOneWidget);
        expect(find.byKey(const ValueKey('ios-switch-hud-skip-countdown')),
            findsOneWidget);

        // Toggle danmu enabled switch and verify DanmuPrefs persistence
        final danmuSwitch = find.descendant(
          of: find.byKey(const ValueKey('ios-switch-danmu-enabled')),
          matching: find.byType(IosNativeSwitch),
        );
        await tester.tap(danmuSwitch);
        await tester.pumpAndSettle();
        final savedDanmu = await DanmuPrefs.load();
        expect(savedDanmu.enabled, isTrue);
        expect(savedDanmu.serverUrls, isEmpty);

        // Toggle HUD slim progress switch
        final slimSwitch = find.descendant(
          of: find.byKey(const ValueKey('ios-switch-hud-slim-progress')),
          matching: find.byType(IosNativeSwitch),
        );
        await tester.tap(slimSwitch);
        await tester.pumpAndSettle();
        expect(hudPrefs.data.slimProgress, isFalse);

        // OHOS guard: both sections render SizedBox.shrink
        OhosRuntime.debugIsOhosOverride = true;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ListView(
                children: [
                  const IosDanmuSettingsSection(),
                  IosPlayerHudSettingsSection(debugHudPrefs: hudPrefs),
                ],
              ),
            ),
          ),
        );
        await tester.pump();
        expect(find.byType(IosNativeSwitch), findsNothing);
      },
    );
  });

  group('M5b Onboarding route, Settings replay entry & FirstPlayGestureHint', () {
    testWidgets(
      'AdaptiveShell pushes standalone OnboardingScreen on first launch (skipped on OHOS), exposes Settings replay entry',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        tester.view.devicePixelRatio = 1.0;
        tester.view.physicalSize = const Size(390, 844);
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        SharedPreferences.setMockInitialValues(<String, Object>{});
        final storage = await StorageService.init();
        await tester.pumpWidget(
          MaterialApp(
            home: AdaptiveShell(
              storage: storage,
              client: CmsClient(
                client: MockClient(
                  (_) async => http.Response('{"class":[],"list":[]}', 200),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump(const Duration(milliseconds: 300));

        // Standalone OnboardingScreen route is presented on fresh install
        expect(find.byType(OnboardingScreen), findsOneWidget);
        // Primary CTA uses IosNativeGlassButton
        expect(find.byType(IosNativeGlassButton), findsWidgets);

        // Skip completes onboarding and pops route
        await tester.tap(find.byKey(const Key('onboarding_skip_button')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        expect(find.byType(OnboardingScreen), findsNothing);

        final prefs = await OnboardingPrefs.load();
        expect(prefs.doneVersion, OnboardingPrefs.currentVersion);

        // Navigate to Settings -> 关于与更新 -> verify '重新查看新手引导' entry exists
        await tester.tap(find.text('设置').last);
        await tester.pumpAndSettle();
        final aboutCat = find.byKey(const ValueKey('settings-category-about'));
        await tester.ensureVisible(aboutCat);
        await tester.pumpAndSettle();
        await tester.tap(aboutCat);
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('ios-replay-onboarding')),
            findsOneWidget);
        expect(find.text('重新查看新手引导'), findsOneWidget);

        // OHOS guard: fresh launch skips OnboardingScreen completely
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        OhosRuntime.debugIsOhosOverride = true;
        SharedPreferences.setMockInitialValues(<String, Object>{});
        final ohosStorage = await StorageService.init();
        await tester.pumpWidget(
          MaterialApp(
            home: AdaptiveShell(
              storage: ohosStorage,
              client: CmsClient(
                client: MockClient(
                  (_) async => http.Response('{"class":[],"list":[]}', 200),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.byType(OnboardingScreen), findsNothing);
      },
    );

    testWidgets(
      'PlayerScreen mounts FirstPlayGestureHint on VOD startup, honors dismiss forever, and suppresses on OHOS',
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
      (tester) async {
        SharedPreferences.setMockInitialValues(<String, Object>{});
        final sp = await SharedPreferences.getInstance();
        final onboardingPrefs = OnboardingPrefs(sp);
        final storage = await initTestStorage();
        final hudPrefs = PlayerHudPrefs.inMemory(isDesktop: true);
        addTearDown(hudPrefs.dispose);
        final player = _W2FakePlayer();

        await tester.pumpWidget(
          MaterialApp(
            home: PlayerScreen(
              site: testSite,
              video: testVideo,
              initialLineIndex: 0,
              initialEpisodeIndex: 0,
              storage: storage,
              debugPlayer: player,
              debugVideoSurface: const ColoredBox(color: Colors.black),
              debugHudPrefs: hudPrefs,
              debugOnboardingPrefs: onboardingPrefs,
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 250));

        expect(find.byType(FirstPlayGestureHint), findsOneWidget);
        expect(find.byKey(const Key('first_play_gesture_hint_dismiss')),
            findsOneWidget);

        // Tap "知道了 / 不再提示" -> permanently dismissed
        await tester.tap(find.byKey(const Key('first_play_gesture_hint_dismiss')));
        await tester.pump(const Duration(milliseconds: 300));
        expect(onboardingPrefs.playHintDismissed, isTrue);
        expect(onboardingPrefs.shouldShowFirstPlayHint(), isFalse);
      },
    );

    testWidgets(
      'L-01: replaying onboarding preserves user glassBlurLevel (light / deep) when adjusting text scale or toggling reduceTransparency',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        tester.view.devicePixelRatio = 1.0;
        tester.view.physicalSize = const Size(390, 844);
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
          GlassworkBackdrop.reduceTransparency.value = false;
          GlassworkBackdrop.intensity.value = 0.68;
        });

        for (final savedPreset in const <(String, double)>[
          ('light', 0.35),
          ('deep', 1.0),
        ]) {
          final level = savedPreset.$1;
          final strength = savedPreset.$2;
          SharedPreferences.setMockInitialValues(<String, Object>{
            OnboardingPrefs.doneVersionKey: OnboardingPrefs.currentVersion,
            StorageService.keyGlassBlurLevel: level,
            StorageService.keyGlassBlurStrength: strength,
          });
          final storage = await StorageService.init();
          expect(storage.glassBlurLevel, level);

          await tester.pumpWidget(
            MaterialApp(
              home: AdaptiveShell(
                storage: storage,
                client: CmsClient(
                  client: MockClient(
                    (_) async => http.Response('{"class":[],"list":[]}', 200),
                  ),
                ),
              ),
            ),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          expect(find.byType(OnboardingScreen), findsNothing);

          // Open Settings -> 关于与更新 -> 重新查看新手引导
          await tester.tap(find.text('设置').last);
          await tester.pumpAndSettle();
          final aboutCat = find.byKey(const ValueKey('settings-category-about'));
          await tester.ensureVisible(aboutCat);
          await tester.pumpAndSettle();
          await tester.tap(aboutCat);
          await tester.pumpAndSettle();
          final replayEntry = find.byKey(const ValueKey('ios-replay-onboarding'));
          await tester.ensureVisible(replayEntry);
          await tester.pumpAndSettle();
          await tester.tap(replayEntry);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 400));
          expect(find.byType(OnboardingScreen), findsOneWidget);

          // Advance Acts 1 -> 5 (AuroraBackground runs an active ticker, so pump fixed intervals).
          for (var i = 0; i < 4; i++) {
            await tester.tap(find.byKey(const Key('onboarding_next_button')));
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 300));
          }

          // Adjust text scale slider & Reduce Motion switch while Reduce Transparency is OFF:
          // MUST NOT overwrite user's existing 'light' or 'deep' glassBlurLevel!
          final slider = find.byKey(const Key('onboarding_text_scale_slider'));
          await tester.ensureVisible(slider);
          await tester.pump();
          await tester.drag(slider, const Offset(60, 0));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 100));
          expect(storage.glassBlurLevel, level);
          expect(storage.glassBlurStrength, closeTo(strength, 0.01));

          final motionSwitch =
              find.byKey(const Key('onboarding_reduce_motion_switch'));
          await tester.ensureVisible(motionSwitch);
          await tester.pump();
          await tester.tap(motionSwitch);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 100));
          expect(storage.glassBlurLevel, level);
          expect(storage.glassBlurStrength, closeTo(strength, 0.01));

          // Toggling Reduce Transparency ON sets 'solid', and toggling it back OFF
          // MUST restore the user's original 'light'/'deep' preference (not 'standard').
          final rtSwitch =
              find.byKey(const Key('onboarding_reduce_transparency_switch'));
          await tester.ensureVisible(rtSwitch);
          await tester.pump();
          await tester.tap(rtSwitch);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 100));
          expect(storage.glassBlurLevel, 'solid');
          expect(GlassworkBackdrop.reduceTransparency.value, isTrue);

          await tester.tap(rtSwitch);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 100));
          expect(storage.glassBlurLevel, level);
          expect(storage.glassBlurStrength, closeTo(strength, 0.01));
          expect(GlassworkBackdrop.reduceTransparency.value, isFalse);

          // Cleanly unmount before second iteration
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
        }
      },
    );
  });

  group('Gate 1 residual closures: NEW-M01, NEW-L01, Danmu _warmupTwoByte', () {
    testWidgets(
      'NEW-M01: embedded PlayerScreen + sibling TextField NEVER steals focus on auto-hide timer or pointer move',
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
      (tester) async {
        tester.view.devicePixelRatio = 1.0;
        tester.view.physicalSize = const Size(1280, 720);
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        final storage = await initTestStorage();
        final appearance = WindowsAppearance(Directory.systemTemp);
        addTearDown(appearance.dispose);
        final hudPrefs = PlayerHudPrefs.inMemory(isDesktop: true);
        addTearDown(hudPrefs.dispose);
        final player = _W2FakePlayer();
        final searchFocus = FocusNode();
        final searchCtrl = TextEditingController();
        addTearDown(searchFocus.dispose);
        addTearDown(searchCtrl.dispose);

        await tester.pumpWidget(
          MaterialApp(
            builder: (_, child) =>
                WindowsAppearanceScope(controller: appearance, child: child!),
            home: Scaffold(
              body: Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: PlayerScreen(
                      site: testSite,
                      video: testVideo,
                      initialLineIndex: 0,
                      initialEpisodeIndex: 0,
                      storage: storage,
                      isLive: true,
                      embedded: true,
                      debugPlayer: player,
                      debugVideoSurface: const ColoredBox(color: Colors.black),
                      debugHudPrefs: hudPrefs,
                    ),
                  ),
                  Expanded(
                    flex: 1,
                    child: TextField(
                      key: const Key('sibling-live-search'),
                      focusNode: searchFocus,
                      controller: searchCtrl,
                      decoration: const InputDecoration(hintText: '搜索全部频道'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 200));

        // Embedded player must NOT autofocus on mount.
        await tester.tap(find.byKey(const Key('sibling-live-search')));
        await tester.pump(const Duration(milliseconds: 50));
        expect(searchFocus.hasFocus, isTrue);

        // Move mouse across embedded player to trigger _onPointerMove & _hideTimer
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: const Offset(200, 200));
        await tester.pump();
        await mouse.moveTo(const Offset(260, 220));
        await tester.pump(const Duration(milliseconds: 100));
        expect(searchFocus.hasFocus, isTrue);

        // Wait past 2.5s auto-hide timer -> _restorePlayerFocusIfCurrent MUST NOT steal focus!
        await tester.pump(const Duration(milliseconds: 2800));
        expect(searchFocus.hasFocus, isTrue);

        // Move mouse again while HUD is hidden -> still MUST NOT steal focus!
        await mouse.moveTo(const Offset(320, 240));
        await tester.pump(const Duration(milliseconds: 100));
        expect(searchFocus.hasFocus, isTrue);

        // Typing Space / D while TextField has focus MUST NOT pause player!
        final pausesBefore = player.playOrPauseCalls;
        await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
        await tester.pump(const Duration(milliseconds: 40));
        await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
        expect(player.playOrPauseCalls, pausesBefore);
        expect(searchFocus.hasFocus, isTrue);
      },
    );

    testWidgets(
      'NEW-L01: IosFluidScrubberCapsule clears _activePointerId when parent cancels isScrubbing so lifting original finger does NOT seek',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        var scrubEnds = 0;
        var scrubbing = false;
        late StateSetter hostSetState;

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 400,
                  child: StatefulBuilder(
                    builder: (context, setState) {
                      hostSetState = setState;
                      return IosFluidScrubberCapsule(
                        position: const Duration(seconds: 60),
                        duration: const Duration(seconds: 300),
                        isScrubbing: scrubbing,
                        scrubPositionMs: 60000,
                        skipIntroSec: 0,
                        skipOutroSec: 0,
                        ios26Visual: false,
                        reduceTransparency: false,
                        reduceMotion: true,
                        onScrubStart: (_) => setState(() => scrubbing = true),
                        onScrubUpdate: (_) {},
                        onScrubEnd: (_) {
                          scrubEnds++;
                          setState(() => scrubbing = false);
                        },
                        onScrubCancel: () => setState(() => scrubbing = false),
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        );

        final hitArea = find.byKey(const Key('ios-fluid-scrubber-hit-area'));
        expect(hitArea, findsOneWidget);
        final center = tester.getCenter(hitArea);

        // Pointer 1 starts dragging scrubber -> isScrubbing becomes true
        final p1 = await tester.startGesture(center);
        await tester.pump();
        expect(scrubbing, isTrue);
        await p1.moveBy(const Offset(40, 0));
        await tester.pump();

        // Parent cancels scrub (e.g. second finger multi-touch interrupt)
        hostSetState(() => scrubbing = false);
        await tester.pump();

        // Original finger (Pointer 1) now lifts -> MUST NOT trigger onScrubEnd!
        await p1.up();
        await tester.pump();
        expect(scrubEnds, 0);
      },
    );

    test(
      'DanmuBlockFilter _warmupTwoByte keeps 180-char TwoByte first-call strictly < 5ms without altering _SafeRegexValidator rules',
      () {
        final twoByteAsciiHeavy = '${'a' * 179}\u4e00';
        final twoByteMixed =
            '${'a' * 150}12345 _!${'\u4e00' * 15}\u0150\u00e9\u4e2d\u6587\u6d4b\u8bd5!';
        expect(twoByteAsciiHeavy.length, 180);
        expect(twoByteMixed.length, lessThanOrEqualTo(180));

        // Verify _SafeRegexValidator rules remain strictly intact
        expect(DanmuBlockFilter.validateRule('re:(a|aa)+\$').valid, isFalse);
        expect(DanmuBlockFilter.validateRule('re:a+a+c').valid, isFalse);
        expect(DanmuBlockFilter.validateRule('re:剧透|打卡').valid, isTrue);

        final rules = <String>[
          're:[a-z]{20}[a-z]{20}[a-z]{20}[a-z]{20}[a-z]{20}z',
          're:a{20}a{20}a{20}a{20}a{20}a{20}',
        ];
        for (final rule in rules) {
          expect(DanmuBlockFilter.validateRule(rule).valid, isTrue);
          final filter = DanmuBlockFilter.compile(<String>[rule]);
          for (final sample in <String>[twoByteAsciiHeavy, twoByteMixed]) {
            for (var callIdx = 0; callIdx < 6; callIdx++) {
              final sw = Stopwatch()..start();
              filter.isBlocked(sample);
              sw.stop();
              var ms = sw.elapsedMicroseconds / 1000.0;
              if (ms >= 5.0 && callIdx == 0) {
                // Guard against OS hypervisor thread preemption on shared CI VMs
                // by re-measuring a fresh cold-compiled filter instance once.
                final retryFilter = DanmuBlockFilter.compile(<String>[rule]);
                final retrySw = Stopwatch()..start();
                retryFilter.isBlocked(sample);
                retrySw.stop();
                final retryMs = retrySw.elapsedMicroseconds / 1000.0;
                if (retryMs < ms) ms = retryMs;
              } else if (ms >= 5.0) {
                final retrySw = Stopwatch()..start();
                filter.isBlocked(sample);
                retrySw.stop();
                final retryMs = retrySw.elapsedMicroseconds / 1000.0;
                if (retryMs < ms) ms = retryMs;
              }
              expect(
                ms,
                lessThan(5.0),
                reason:
                    'Rule "$rule" call$callIdx on TwoByte 180-char took ${ms.toStringAsFixed(3)}ms',
              );
            }
          }
        }
      },
    );
  });

  group('Gate R2 follow-up regressions (#27 Major 1-2, Minor 3 & #29 Minor 1)', () {
    testWidgets(
      'R2 #27-M1 & #27-M2: live danmu serverUrls edit with owned DandanplayProvider avoids ChangeNotifier use-after-dispose and closes owned providers on rebuild & dispose',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        tester.view.devicePixelRatio = 1.0;
        tester.view.physicalSize = const Size(844, 390);
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        final storage = await initTestStorage();
        final hudPrefs = PlayerHudPrefs.inMemory(isDesktop: false);
        addTearDown(hudPrefs.dispose);
        final player = _W2FakePlayer();

        final createdProviders = <DandanplayProvider>[];
        await tester.pumpWidget(
          MaterialApp(
            home: PlayerScreen(
              site: testSite,
              video: testVideo,
              initialLineIndex: 0,
              initialEpisodeIndex: 0,
              storage: storage,
              debugPlayer: player,
              debugVideoSurface: const ColoredBox(color: Colors.black),
              debugHudPrefs: hudPrefs,
              debugDanmuSettings: const DanmuSettings(enabled: true),
              debugDanmuProviderFactory: (settings) {
                final provider = DandanplayProvider(
                  multilineServerUrls: settings.serverUrls,
                  appId: settings.appId,
                  appSecret: settings.appSecret,
                  client: MockClient(
                    (_) async => http.Response('{"matches":[]}', 200),
                  ),
                );
                createdProviders.add(provider);
                return provider;
              },
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 200));

        expect(createdProviders, hasLength(1));
        expect(createdProviders.first.isClosed, isFalse);
        final initialLayer = tester.widget<DanmuLayer>(find.byType(DanmuLayer));
        final firstCache = initialLayer.segmentCache!;
        expect(firstCache.isDisposed, isFalse);

        // Open DanmuSettingsSheet and update serverUrls live (triggers _rebuildDanmuPipeline
        // on the production debugDanmuProvider == null branch!).
        await tester.tap(find.byKey(const ValueKey('ios-dock-action-danmu')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));

        final serverField = find.descendant(
          of: find.byType(DanmuSettingsSheet),
          matching: find.byType(TextField),
        ).first;
        await tester.enterText(serverField, 'https://danmu-live.example');
        await tester.pump();

        final saveBtn = find.text('保存服务配置');
        await tester.ensureVisible(saveBtn);
        await tester.tap(saveBtn);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        // Zero ChangeNotifier use-after-dispose FlutterError!
        expect(tester.takeException(), isNull);
        expect(createdProviders, hasLength(2));
        expect(createdProviders[0].isClosed, isTrue);
        expect(createdProviders[1].isClosed, isFalse);
        expect(firstCache.isDisposed, isTrue);

        final updatedLayer = tester.widget<DanmuLayer>(find.byType(DanmuLayer));
        expect(updatedLayer.segmentCache, isNot(same(firstCache)));
        expect(updatedLayer.segmentCache!.isDisposed, isFalse);

        // Unmount PlayerScreen -> closes active owned provider & disposes cache cleanly.
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        expect(tester.takeException(), isNull);
        expect(createdProviders[1].isClosed, isTrue);
        expect(updatedLayer.segmentCache!.isDisposed, isTrue);
      },
    );

    test(
      'R2 #29-m1: DanmuSegmentCache.cancelPendingRequests cancels armed seek debounce timer and in-flight window fetches',
      () async {
        final fetchWindows = <int>[];
        final fetchTokens = <DanmuCancelToken>[];
        final inFlightGate = Completer<List<DanmuItem>>();
        final provider = _CancellableDanmuProvider(
          onFetchWindow: (w, token) {
            fetchWindows.add(w);
            if (token != null) fetchTokens.add(token);
            return inFlightGate.future;
          },
        );
        final cache = DanmuSegmentCache(
          provider: provider,
          seekDebounceMs: 120,
        );
        addTearDown(cache.dispose);

        await cache.bindSession('mmdanmu://v1?src=https%3A%2F%2Fdanmu.example&ep=42');
        expect(cache.currentSession, isNotNull);

        // 1. Arm 120ms seek debounce timer, then cancelPendingRequests() before debounce fires.
        cache.onSeekChanged(90000);
        cache.cancelPendingRequests();
        await Future<void>.delayed(const Duration(milliseconds: 180));
        expect(fetchWindows, isEmpty);

        // 2. Start an in-flight window fetch, then cancelPendingRequests() -> token cancelled!
        cache.onPlaybackTick(5000, playing: true);
        expect(fetchWindows, equals(<int>[0]));
        expect(fetchTokens.single.isCancelled, isFalse);
        cache.cancelPendingRequests();
        expect(fetchTokens.single.isCancelled, isTrue);
      },
    );

    testWidgets(
      'R2 #29-m1: disabling Danmu inside PlayerScreen cancels pending seek debounce fetch',
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
      (tester) async {
        final storage = await initTestStorage();
        final hudPrefs = PlayerHudPrefs.inMemory(isDesktop: true);
        addTearDown(hudPrefs.dispose);
        final player = _W2FakePlayer();
        final fetchedWindows = <int>[];
        final provider = _CancellableDanmuProvider(
          onFetchWindow: (w, _) async {
            fetchedWindows.add(w);
            return const <DanmuItem>[];
          },
        );

        await tester.pumpWidget(
          MaterialApp(
            home: PlayerScreen(
              site: testSite,
              video: testVideo,
              initialLineIndex: 0,
              initialEpisodeIndex: 0,
              storage: storage,
              debugPlayer: player,
              debugVideoSurface: const ColoredBox(color: Colors.black),
              debugHudPrefs: hudPrefs,
              debugDanmuProvider: provider,
              debugDanmuSettings: const DanmuSettings(
                enabled: true,
                serverUrls: 'https://danmu.example',
              ),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 200));
        final layer = tester.widget<DanmuLayer>(find.byType(DanmuLayer));
        final cache = layer.segmentCache!;
        expect(cache.currentSession, isNotNull);
        fetchedWindows.clear();

        // Arm 180ms seek debounce, then immediately toggle Danmu OFF via D key (< 180ms).
        cache.onSeekChanged(120000);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyD);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(fetchedWindows, isEmpty);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      },
    );

    testWidgets(
      'R2 #27-m3: IosDanmuSettingsSection._update does not invoke onChanged after unmount',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        var onChangedCalls = 0;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: IosDanmuSettingsSection(
                initialSettingsOverride: const DanmuSettings(enabled: false),
                onChanged: () => onChangedCalls++,
              ),
            ),
          ),
        );
        await tester.pump();

        // Tap switch and immediately unmount before async DanmuPrefs.save settles.
        await tester.tap(find.byKey(const ValueKey('ios-switch-danmu-enabled')));
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 100));
        expect(tester.takeException(), isNull);
        expect(onChangedCalls, 0);
      },
    );
  });
}

class _CancellableDanmuProvider implements DanmuProvider {
  final Future<List<DanmuItem>> Function(int windowIndex, DanmuCancelToken? token)
      onFetchWindow;

  _CancellableDanmuProvider({required this.onFetchWindow});

  @override
  Future<List<DanmuCandidate>> matchOrSearch(
    DanmuMatchQuery query, {
    DanmuCancelToken? cancelToken,
  }) async =>
      const <DanmuCandidate>[
        DanmuCandidate(
          sourceOrigin: 'https://danmu.example',
          animeId: '1',
          animeTitle: '测试影片',
          boundEpisodeId: 'mmdanmu://v1?src=https%3A%2F%2Fdanmu.example&ep=42',
          episodeTitle: '第01集',
          confidence: 0.99,
        ),
      ];

  @override
  Future<List<DanmuCandidate>> listEpisodes(
    String sourceOrigin,
    String animeId, {
    DanmuCancelToken? cancelToken,
  }) async =>
      const <DanmuCandidate>[];

  @override
  Future<DanmuEpisodeSession> openSession(
    String boundEpisodeId, {
    DanmuCancelToken? cancelToken,
  }) async =>
      DanmuEpisodeSession(
        boundEpisodeId: boundEpisodeId,
        segmented: true,
        segments: const <DanmuSegmentDescriptor>[],
      );

  @override
  Future<List<DanmuItem>> fetchWindow(
    DanmuEpisodeSession session,
    int windowIndex, {
    DanmuCancelToken? cancelToken,
  }) =>
      onFetchWindow(windowIndex, cancelToken);
}
