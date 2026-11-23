// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/core/ohos_runtime.dart';
import 'package:marco_movie/core/windows_video_quality.dart';
import 'package:marco_movie/ui/player/desktop_player_hud.dart';
import 'package:marco_movie/ui/player/player_hud_prefs.dart';
import 'package:marco_movie/ui/player_screen.dart';
import 'package:marco_movie/ui/windows_appearance.dart';
import 'package:media_kit/media_kit.dart';

import 'test_storage_helper.dart';

class _DeskFakeState extends Fake implements PlayerState {
  Playlist playlistValue = const Playlist([]);
  bool playingValue = true;
  bool completedValue = false;
  Duration positionValue = const Duration(minutes: 4);
  Duration durationValue = const Duration(minutes: 25);
  double volumeValue = 80.0;
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

class _DeskFakeStream extends Fake implements PlayerStream {
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
    ]);
  }
}

class _DeskFakePlayer extends Fake implements Player {
  final _DeskFakeState _state = _DeskFakeState();
  final _DeskFakeStream _stream = _DeskFakeStream();
  final List<Duration> seeks = <Duration>[];
  final List<double> rates = <double>[];
  final List<double> volumes = <double>[];
  int playOrPauseCalls = 0;
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
    _state.durationValue = const Duration(minutes: 25);
    _state.positionValue = const Duration(minutes: 4);
    _state.playingValue = play;
    _state.bufferingValue = false;
    if (!disposed) {
      _stream.durationCtrl.add(_state.durationValue);
      _stream.positionCtrl.add(_state.positionValue);
      _stream.bufferingCtrl.add(false);
      _stream.playingCtrl.add(play);
    }
  }

  @override
  Future<void> stop() async => _state.playingValue = false;
  @override
  Future<void> play() async {
    _state.playingValue = true;
    if (!disposed) _stream.playingCtrl.add(true);
  }

  @override
  Future<void> pause() async {
    _state.playingValue = false;
    if (!disposed) _stream.playingCtrl.add(false);
  }

  @override
  Future<void> playOrPause() async {
    playOrPauseCalls++;
    _state.playingValue = !_state.playingValue;
    if (!disposed) _stream.playingCtrl.add(_state.playingValue);
  }

  @override
  Future<void> seek(Duration duration) async {
    seeks.add(duration);
    _state.positionValue = duration;
    if (!disposed) _stream.positionCtrl.add(duration);
  }

  @override
  Future<void> setRate(double rate) async {
    rates.add(rate);
    _state.rateValue = rate;
  }

  @override
  Future<void> setVolume(double volume) async {
    volumes.add(volume);
    _state.volumeValue = volume;
  }

  @override
  Future<void> setAudioTrack(AudioTrack track) async {}
  @override
  Future<void> setSubtitleTrack(SubtitleTrack track) async {}
  @override
  Future<void> dispose() async {
    if (disposed) return;
    disposed = true;
    await _stream.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const windowChannel = MethodChannel('window_manager');
  var fullscreenToggleCount = 0;

  setUp(() {
    fullscreenToggleCount = 0;
    OhosRuntime.resetForTesting();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(windowChannel, (call) async {
      if (call.method == 'isFullScreen') return false;
      if (call.method == 'isMaximized') return false;
      if (call.method == 'setFullScreen') {
        fullscreenToggleCount++;
        return null;
      }
      return null;
    });
  });

  tearDown(() {
    OhosRuntime.resetForTesting();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(windowChannel, null);
  });

  Future<void> mountWindowsPlayer(
    WidgetTester tester, {
    required _DeskFakePlayer player,
    VoidCallback? onToggleDanmu,
  }) async {
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

    const site = CmsSite(
      key: 'desk_reg_site',
      name: '桌面回归源',
      type: 1,
      api: 'https://source.example/api',
      isPrivate: true,
    );
    const video = CmsVideo(
      id: 'desk_reg_vid',
      title: '桌面交互守卫影片',
      lines: [
        CmsLine(
          name: '主线路',
          episodes: [
            CmsEpisode(name: '第01集', url: 'file:///tmp/desk_reg_e1.mp4'),
            CmsEpisode(name: '第02集', url: 'file:///tmp/desk_reg_e2.mp4'),
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
          onToggleDanmu: onToggleDanmu,
          debugPlayer: player,
          debugVideoSurface: const ColoredBox(color: Colors.black),
          debugHudPrefs: hudPrefs,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));
  }

  group('Desktop Gate 1 regressions — S-06, S-07, M-09', () {
    testWidgets(
      'S-06: clicking desktop HUD buttons and dragging bottom Material Slider never steals focus and all shortcuts work after 2.5s auto-hide',
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
      (tester) async {
        var danmuToggles = 0;
        final player = _DeskFakePlayer();
        await mountWindowsPlayer(
          tester,
          player: player,
          onToggleDanmu: () => danmuToggles++,
        );

        // 1. Drag bottom Material Slider.
        final sliderFinder = find.byType(Slider);
        expect(sliderFinder, findsOneWidget);
        await tester.drag(sliderFinder, const Offset(80, 0));
        await tester.pump(const Duration(milliseconds: 100));

        // 2. Click a HUD button ('更多' open then close) — must NOT steal focus!
        await tester.tap(find.text('更多'));
        await tester.pump(const Duration(milliseconds: 80));
        await tester.tap(find.text('更多'));
        await tester.pump(const Duration(milliseconds: 80));

        // 3. Wait 2.5s for HUD auto-hide (child buttons & Slider unmount).
        await tester.pump(const Duration(milliseconds: 2700));
        expect(find.byKey(const Key('desktop-player-hud')), findsNothing);

        // 4. Verify ALL global shortcuts still work without clicking the video!
        player.seeks.clear();
        player.volumes.clear();
        player.rates.clear();

        // ArrowRight short tap -> +15s seek (not swallowed by Slider!)
        await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
        await tester.pump(const Duration(milliseconds: 80));
        await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
        await tester.pump(const Duration(milliseconds: 50));
        expect(player.seeks, hasLength(1));

        // ArrowUp / ArrowDown -> volume +5 / -5
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await tester.pump(const Duration(milliseconds: 30));
        expect(player.volumes.last, 85.0);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump(const Duration(milliseconds: 30));
        expect(player.volumes.last, 80.0);

        // S -> cycles speed 1.0 -> 1.25
        await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
        await tester.pump(const Duration(milliseconds: 30));
        expect(player.rates.last, 1.25);

        // [ / ] -> steps speed
        await tester.sendKeyEvent(LogicalKeyboardKey.bracketRight);
        await tester.pump(const Duration(milliseconds: 30));
        expect(player.rates.last, 1.5);
        await tester.sendKeyEvent(LogicalKeyboardKey.bracketLeft);
        await tester.pump(const Duration(milliseconds: 30));
        expect(player.rates.last, 1.25);

        // D -> toggles danmu
        await tester.sendKeyEvent(LogicalKeyboardKey.keyD);
        await tester.pump(const Duration(milliseconds: 30));
        expect(danmuToggles, 1);

        // F -> toggles fullscreen
        await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
        await tester.pump(const Duration(milliseconds: 30));
        expect(fullscreenToggleCount, 1);

        // Space -> toggles play/pause (not swallowed by any HUD button!)
        final prevPlayPause = player.playOrPauseCalls;
        await tester.sendKeyEvent(LogicalKeyboardKey.space);
        await tester.pump(const Duration(milliseconds: 30));
        expect(player.playOrPauseCalls, prevPlayPause + 1);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 100));
      },
    );

    testWidgets(
      'S-07: physical KeyRepeatEvent after Esc cancel never restarts hold-seek or commits on KeyUp, and opposite arrow KeyUp does not prematurely commit',
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
      (tester) async {
        final player = _DeskFakePlayer();
        await mountWindowsPlayer(tester, player: player);
        player.seeks.clear();

        // Hold ArrowRight >= 280ms -> enters DesktopScrubPreviewCapsule.
        await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
        await tester.pump(const Duration(milliseconds: 420));
        expect(find.byType(DesktopScrubPreviewCapsule), findsOneWidget);
        expect(player.seeks, isEmpty);

        // Press Escape -> cancels preview!
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pump(const Duration(milliseconds: 30));
        expect(find.byType(DesktopScrubPreviewCapsule), findsNothing);
        expect(find.byType(PlayerScreen), findsOneWidget);

        // OS continues emitting KeyRepeatEvent(arrowRight) while key is still held.
        for (var i = 0; i < 5; i++) {
          await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowRight);
          await tester.pump(const Duration(milliseconds: 30));
        }
        expect(find.byType(DesktopScrubPreviewCapsule), findsNothing);

        // Releasing ArrowRight after Esc cancel MUST NOT commit any seek!
        await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
        await tester.pump(const Duration(milliseconds: 60));
        expect(player.seeks, isEmpty);

        // Opposite arrow direction guard: hold Right, then press Left, then release Right.
        await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
        await tester.pump(const Duration(milliseconds: 100));
        await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowLeft);
        await tester.pump(const Duration(milliseconds: 380));
        expect(find.byType(DesktopScrubPreviewCapsule), findsOneWidget);

        // Releasing ArrowRight while ArrowLeft is active MUST NOT commit or cancel ArrowLeft!
        await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
        await tester.pump(const Duration(milliseconds: 40));
        expect(player.seeks, isEmpty);
        expect(find.byType(DesktopScrubPreviewCapsule), findsOneWidget);

        // Releasing matching ArrowLeft commits the single rewind seek!
        await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowLeft);
        await tester.pump(const Duration(milliseconds: 60));
        expect(player.seeks, hasLength(1));
        expect(player.seeks.single, lessThan(const Duration(minutes: 4)));

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 100));
      },
    );

    testWidgets(
      'M-09: mouse wheel scrolling over desktop scrollable toolbar does NOT alter volume while scrolling over video adjusts volume',
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
      (tester) async {
        final player = _DeskFakePlayer();
        await mountWindowsPlayer(tester, player: player);
        player.volumes.clear();

        // Open '更多' desktop popover menu.
        await tester.tap(find.text('更多'));
        await tester.pump(const Duration(milliseconds: 100));
        final dockFinder = find.byKey(const Key('desktop-more-menu-popover'));
        expect(dockFinder, findsOneWidget);
        final dockCenter = tester.getCenter(dockFinder);

        // Scroll forward over toolbar -> must NOT change player volume!
        await tester.sendEventToBinding(
          PointerScrollEvent(
            position: dockCenter,
            scrollDelta: const Offset(0, 120),
          ),
        );
        await tester.pump(const Duration(milliseconds: 50));
        expect(player.volumes, isEmpty);

        // Scroll backward at scroll boundary over toolbar -> STILL must NOT change player volume!
        await tester.sendEventToBinding(
          PointerScrollEvent(
            position: dockCenter,
            scrollDelta: const Offset(0, -120),
          ),
        );
        await tester.pump(const Duration(milliseconds: 50));
        expect(player.volumes, isEmpty);

        // Scroll over open video area -> adjusts player volume +5% (80 -> 85).
        await tester.sendEventToBinding(
          const PointerScrollEvent(
            position: Offset(640, 260),
            scrollDelta: Offset(0, -120),
          ),
        );
        await tester.pump(const Duration(milliseconds: 50));
        expect(player.volumes, isNotEmpty);
        expect(player.volumes.last, 85.0);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 100));
      },
    );

    testWidgets(
      'M-09: high-polling-rate (500Hz-1000Hz) mouse sub-pixel moves (<1.0lp each) accumulate past 12lp and wake hidden desktop HUD',
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
      (tester) async {
        final player = _DeskFakePlayer();
        await mountWindowsPlayer(tester, player: player);

        // Wait 2.5s auto-hide so HUD is hidden.
        await tester.pump(const Duration(milliseconds: 2700));
        expect(find.byKey(const Key('desktop-player-hud')), findsNothing);

        // Create a mouse pointer and send 20 smooth sub-pixel hover moves of 0.7lp each (total 14.0lp >= 12.0lp).
        final mouse = await tester.createGesture(
          kind: PointerDeviceKind.mouse,
        );
        await mouse.addPointer(location: const Offset(500, 360));
        await tester.pump();
        for (var i = 1; i <= 20; i++) {
          await mouse.moveTo(Offset(500.0 + i * 0.7, 360.0));
          await tester.pump(const Duration(milliseconds: 2));
        }

        // Hidden desktop HUD MUST wake cleanly!
        expect(find.byKey(const Key('desktop-player-hud')), findsOneWidget);

        await mouse.removePointer();
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 100));
      },
    );
  });

  group('Windows 0.7.0 quality & vocal loudness HUD controls', () {
    test('DesktopHudBarVisibility handles quality and loudness breakpoints cleanly', () {
      final wide = DesktopHudBarVisibility.forWidth(
        1280,
        isLive: false,
        danmuAvailable: true,
        anime4kAvailable: true,
        videoQualityAvailable: true,
        audioLoudnessAvailable: true,
      );
      expect(wide.showVideoQuality, isTrue);
      expect(wide.showAudioLoudness, isTrue);
      expect(wide.showAnime4k, isTrue);
      expect(wide.showSleepTimer, isTrue);

      final compact = DesktopHudBarVisibility.forWidth(
        980,
        isLive: false,
        danmuAvailable: true,
        anime4kAvailable: true,
        videoQualityAvailable: true,
        audioLoudnessAvailable: true,
      );
      expect(compact.showVideoQuality, isFalse);
      expect(compact.showAudioLoudness, isFalse);
      expect(compact.showAnime4k, isFalse);

      // Backward-compatible default remains false when omitted
      final legacy = DesktopHudBarVisibility.forWidth(
        1280,
        isLive: false,
        danmuAvailable: true,
        anime4kAvailable: true,
      );
      expect(legacy.showVideoQuality, isFalse);
      expect(legacy.showAudioLoudness, isFalse);
    });

    testWidgets(
      'DesktopPlayerHud renders quality & loudness quick-switch popovers without stealing focus or leaking wheel scroll',
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

        var currentQuality = WindowsQualityPreset.balancedHq;
        var currentLoudness = AudioLoudnessPreset.off;
        var moreOpen = false;
        var wheelLeakCount = 0;
        final focusNode = FocusNode();
        addTearDown(focusNode.dispose);
        var spacePressedCount = 0;

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: StatefulBuilder(
                builder: (context, setState) {
                  return KeyboardListener(
                    focusNode: focusNode,
                    autofocus: true,
                    onKeyEvent: (event) {
                      if (event is KeyDownEvent &&
                          event.logicalKey == LogicalKeyboardKey.space) {
                        spacePressedCount++;
                      }
                    },
                    child: Listener(
                      onPointerSignal: (event) {
                        if (event is PointerScrollEvent) {
                          GestureBinding.instance.pointerSignalResolver
                              .register(
                            event,
                            (_) => wheelLeakCount++,
                          );
                        }
                      },
                      child: DesktopPlayerHud(
                        embedded: false,
                        title: '4K HDR 测试影片',
                        playing: true,
                        isLive: false,
                        normalSpeed: 1.0,
                        moreControlsOpen: moreOpen,
                        sleepTimerActive: false,
                        sleepTimerLabel: '',
                        anime4kVisible: true,
                        anime4kActive: false,
                        onAnime4kTap: () {},
                        videoQualityVisible: true,
                        videoQualityPreset: currentQuality,
                        onVideoQualityChanged: (next) {
                          setState(() => currentQuality = next);
                        },
                        audioLoudnessVisible: true,
                        audioLoudnessPreset: currentLoudness,
                        onAudioLoudnessChanged: (next) {
                          setState(() => currentLoudness = next);
                        },
                        topHeader: const SizedBox(height: 32),
                        progressBar: const SizedBox(height: 20),
                        transportButtons: const SizedBox(width: 48, height: 48),
                        moreToolsDock: DesktopPlayerMorePopover(
                          sections: [
                            DesktopVideoQualitySection(
                              currentPreset: currentQuality,
                              onSelected: (next) =>
                                  setState(() => currentQuality = next),
                            ),
                            DesktopAudioLoudnessSection(
                              currentPreset: currentLoudness,
                              onSelected: (next) =>
                                  setState(() => currentLoudness = next),
                            ),
                          ],
                        ),
                        onExit: () {},
                        onPlayPause: () {},
                        onVolumeTap: () {},
                        onEpisodesTap: () {},
                        onSpeedTap: () {},
                        onSubtitlesTap: () {},
                        onSleepTimerTap: () {},
                        onToggleMore: () => setState(() => moreOpen = !moreOpen),
                        onCloseMore: () => setState(() => moreOpen = false),
                        onToggleExpand: () {},
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        );
        await tester.pump();

        // Both bar buttons visible at 1280px with current preset labels
        final qualityBtn = find.byKey(const Key('desktop-video-quality-button'));
        final loudnessBtn = find.byKey(const Key('desktop-audio-loudness-button'));
        expect(qualityBtn, findsOneWidget);
        expect(loudnessBtn, findsOneWidget);
        expect(find.text('画质·高画质'), findsOneWidget);
        expect(find.text('人声'), findsOneWidget);

        // Tap quality button -> opens 3-tier quick popover
        await tester.tap(qualityBtn);
        await tester.pump();
        expect(find.byKey(const Key('desktop-video-quality-section')), findsOneWidget);
        expect(find.byKey(const Key('desktop-quality-preset-ecoCompat')), findsOneWidget);
        expect(find.byKey(const Key('desktop-quality-preset-balancedHq')), findsOneWidget);
        expect(find.byKey(const Key('desktop-quality-preset-cinemaUltra')), findsOneWidget);

        // Select cinemaUltra -> updates label and closes quick popover
        await tester.tap(find.byKey(const Key('desktop-quality-preset-cinemaUltra')));
        await tester.pump();
        expect(currentQuality, WindowsQualityPreset.cinemaUltra);
        expect(find.text('画质·旗舰'), findsOneWidget);
        expect(find.byKey(const Key('desktop-video-quality-section')), findsNothing);

        // Tap loudness button -> opens 4-tier quick popover
        await tester.tap(loudnessBtn);
        await tester.pump();
        expect(find.byKey(const Key('desktop-audio-loudness-section')), findsOneWidget);
        expect(find.byKey(const Key('desktop-loudness-preset-off')), findsOneWidget);
        expect(find.byKey(const Key('desktop-loudness-preset-light')), findsOneWidget);
        expect(find.byKey(const Key('desktop-loudness-preset-standard')), findsOneWidget);
        expect(find.byKey(const Key('desktop-loudness-preset-cinemaVocal')), findsOneWidget);

        // Scroll wheel over quick popover is absorbed (parent resolver callback does not fire)
        final popoverCenter = tester.getCenter(
          find.byKey(const Key('desktop-more-menu-popover')),
        );
        await tester.sendEventToBinding(
          PointerScrollEvent(
            position: popoverCenter,
            scrollDelta: const Offset(0, 120),
          ),
        );
        await tester.pump();
        expect(wheelLeakCount, 0);

        // Select cinemaVocal -> updates label and closes quick popover
        await tester.tap(find.byKey(const Key('desktop-loudness-preset-cinemaVocal')));
        await tester.pump();
        expect(currentLoudness, AudioLoudnessPreset.cinemaVocal);
        expect(find.text('人声·影院人声'), findsOneWidget);
        expect(find.byKey(const Key('desktop-audio-loudness-section')), findsNothing);

        // Keyboard focus must NEVER be stolen from KeyboardListener
        await tester.sendKeyEvent(LogicalKeyboardKey.space);
        await tester.pump();
        expect(spacePressedCount, 1);
      },
    );
  });
}
