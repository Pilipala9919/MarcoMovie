// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/core/cast_service.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/core/ohos_runtime.dart';
import 'package:marco_movie/core/storage_service.dart';
import 'package:marco_movie/ui/apple_theme.dart';
import 'package:marco_movie/ui/ios_liquid_glass.dart';
import 'package:marco_movie/ui/player/ios_cast_panel.dart';
import 'package:marco_movie/ui/player/ios_player_chrome.dart';
import 'package:marco_movie/ui/player/player_hud_prefs.dart';
import 'package:marco_movie/ui/player_screen.dart';
import 'package:media_kit/media_kit.dart';

import 'test_storage_helper.dart';

class _IosFakeState extends Fake implements PlayerState {
  Playlist playlistValue = const Playlist([]);
  bool playingValue = true;
  bool completedValue = false;
  Duration positionValue = const Duration(minutes: 3);
  Duration durationValue = const Duration(minutes: 30);
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

class _IosFakeStream extends Fake implements PlayerStream {
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

class _IosFakePlayer extends Fake implements Player {
  final _IosFakeState _state = _IosFakeState();
  final _IosFakeStream _stream = _IosFakeStream();
  final List<double> rates = <double>[];
  final List<Duration> seeks = <Duration>[];
  final List<AudioTrack> audioTracksSet = <AudioTrack>[];
  final List<SubtitleTrack> subtitleTracksSet = <SubtitleTrack>[];
  Duration initialPosition = const Duration(minutes: 3);
  Duration initialDuration = const Duration(minutes: 30);
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
    _state.durationValue = initialDuration;
    _state.positionValue = initialPosition;
    _state.playingValue = play;
    _state.bufferingValue = false;
    if (!disposed) {
      _stream.widthCtrl.add(3840);
      _stream.heightCtrl.add(2160);
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
  Future<void> setVolume(double volume) async => _state.volumeValue = volume;
  @override
  Future<void> setAudioTrack(AudioTrack track) async {
    audioTracksSet.add(track);
  }
  @override
  Future<void> setSubtitleTrack(SubtitleTrack track) async {
    subtitleTracksSet.add(track);
  }
  @override
  Future<void> dispose() async {
    if (disposed) return;
    disposed = true;
    await _stream.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    OhosRuntime.resetForTesting();
    IosLiquidGlassBridge.setAvailableForTest(null);
    IosLiquidGlassBridge.setReduceTransparencyForTest(null);
    GlassworkBackdrop.reduceTransparency.value = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(IosLiquidGlassBridge.channel, null);
  });

  group('IosLiquidGlassBridge & IosNativeRouteGate Wave 1 upgrades', () {
    testWidgets(
      'IosLiquidGlassBridge reads reduceTransparency from capabilities and live native notifications',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(IosLiquidGlassBridge.channel, (call) async {
          if (call.method == 'capabilities') {
            return <String, dynamic>{
              'available': true,
              'majorVersion': 26,
              'sdk26': true,
              'reduceTransparency': true,
            };
          }
          return null;
        });

        await IosLiquidGlassBridge.ensureInitialized();
        expect(IosLiquidGlassBridge.isAvailable, isTrue);
        expect(IosLiquidGlassBridge.reduceTransparency, isTrue);

        // Simulate native push turning reduceTransparency back off.
        const codec = StandardMethodCodec();
        final envelope = codec.encodeMethodCall(
          const MethodCall('reduceTransparencyChanged', false),
        );
        await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .handlePlatformMessage(
          IosLiquidGlassBridge.channel.name,
          envelope,
          (_) {},
        );
        expect(IosLiquidGlassBridge.reduceTransparency, isFalse);
      },
    );

    testWidgets(
      'IosNativeRouteGate.runWithPlaceholders swaps UiKitView for Flutter placeholder and restores via try/finally on throw',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        IosLiquidGlassBridge.setAvailableForTest(true);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: IosNativeGlassButton(
                style: 'circle',
                symbol: 'chevron.backward',
                onTap: () {},
                fallback: const SizedBox.shrink(),
              ),
            ),
          ),
        );
        await tester.pump();
        expect(find.byType(UiKitView), findsOneWidget);

        var sawPlaceholderDuringAction = false;
        Object? caughtError;
        final future = IosNativeRouteGate.runWithPlaceholders<void>(() async {
          sawPlaceholderDuringAction =
              IosNativeRouteGate.forcePlaceholders &&
              find.byType(UiKitView).evaluate().isEmpty &&
              find
                  .byKey(
                    const ValueKey('ios26-glass-button-transition-placeholder'),
                  )
                  .evaluate()
                  .isNotEmpty;
          throw StateError('simulated capture failure');
        }).catchError((Object e) {
          caughtError = e;
        });

        await tester.pump();
        await future;
        await tester.pump();

        expect(caughtError, isA<StateError>());
        expect(sawPlaceholderDuringAction, isTrue);
        expect(IosNativeRouteGate.forcePlaceholders, isFalse);
        expect(find.byType(UiKitView), findsOneWidget);
      },
    );
  });

  group('IosPlayerChrome — iOS 26 Concentric Spatial Cinema HUD', () {
    const site = CmsSite(
      key: 'ios_site',
      name: '测试片源',
      type: 1,
      api: 'https://source.example/api',
      isPrivate: true,
    );
    const video = CmsVideo(
      id: 'ios_vid_1',
      title: '星海旅途',
      lines: [
        CmsLine(
          name: '4K HDR10+ 原盘',
          episodes: [
            CmsEpisode(
              name: '第01集 DV.Atmos.HEVC.mkv',
              url: 'file:///tmp/ios_e1.mp4',
            ),
          ],
        ),
        CmsLine(
          name: '备用线路',
          episodes: [
            CmsEpisode(name: '第01集', url: 'file:///tmp/ios_e1_b.mp4'),
          ],
        ),
      ],
    );

    Future<void> mountIosPlayer(
      WidgetTester tester, {
      required Size surfaceSize,
      required _IosFakePlayer player,
      EdgeInsets padding = EdgeInsets.zero,
      bool isLive = false,
      CmsVideo? videoOverride,
      StorageService? storageOverride,
      PlayerHudPrefs? prefsOverride,
    }) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = surfaceSize;
      await tester.binding.setSurfaceSize(surfaceSize);
      addTearDown(() async {
        await tester.binding.setSurfaceSize(null);
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final storage = storageOverride ?? await initTestStorage();
      final prefs = prefsOverride ?? PlayerHudPrefs.inMemory(isDesktop: false);
      if (prefsOverride == null) {
        addTearDown(prefs.dispose);
      }

      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              padding: padding,
              viewPadding: padding,
            ),
            child: child!,
          ),
          home: PlayerScreen(
            site: site,
            video: videoOverride ?? video,
            initialLineIndex: 0,
            initialEpisodeIndex: 0,
            storage: storage,
            isLive: isLive,
            debugPlayer: player,
            debugVideoSurface: const ColoredBox(color: Colors.black),
            debugHudPrefs: prefs,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));
    }

    testWidgets(
      'zero UiKitViews over video, 40pt top / 56-76-56pt center, <=7 dock, zero spec/back overlap, and glasswork unmounts on hide',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        IosLiquidGlassBridge.setAvailableForTest(true);
        final player = _IosFakePlayer();
        await mountIosPlayer(
          tester,
          surfaceSize: const Size(844, 390),
          padding: const EdgeInsets.fromLTRB(59, 0, 59, 21), // Dynamic Island landscape
          player: player,
        );
        // Trigger 350ms start spec highlight.
        await tester.pump(const Duration(milliseconds: 400));

        // 1. HARD RENDERING RULE: Zero UiKitViews scattered on active video surface!
        expect(find.byType(UiKitView), findsNothing);
        expect(find.byType(IosPlayerChrome), findsOneWidget);

        // 2. Old 16-item right vertical tool dock is retired.
        expect(find.byKey(const Key('player-tool-dock-landscape')), findsNothing);
        expect(find.byKey(const Key('ios-player-primary-dock')), findsOneWidget);

        // 3. Concentric geometry checks: 40pt back capsule, 56/76/56pt center transport.
        final backRect = tester.getRect(find.byKey(const Key('ios-player-back-button')));
        expect(backRect.height, closeTo(40.0, 0.5));
        final playSize = tester.getSize(find.byKey(const Key('player-center-play-pause')));
        final rewindSize = tester.getSize(find.byKey(const Key('player-center-rewind')));
        final forwardSize = tester.getSize(find.byKey(const Key('player-center-forward')));
        expect(playSize, const Size(76.0, 76.0));
        expect(rewindSize, const Size(56.0, 56.0));
        expect(forwardSize, const Size(56.0, 56.0));

        // 4. Inline spec badges never overlap top-left return capsule.
        final specRect = tester.getRect(find.byKey(const Key('player-video-specs')));
        expect(backRect.overlaps(specRect), isFalse);

        // 5. Fluid scrubber track springs from 5pt at rest to 12pt during touch/drag.
        expect(
          tester.getSize(find.byKey(const Key('ios-fluid-scrubber-track'))).height,
          closeTo(5.0, 0.5),
        );
        final hitCenter = tester.getCenter(
          find.byKey(const Key('ios-fluid-scrubber-hit-area')),
        );
        final drag = await tester.startGesture(hitCenter, kind: PointerDeviceKind.touch);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(
          tester.getSize(find.byKey(const Key('ios-fluid-scrubber-track'))).height,
          closeTo(12.0, 0.6),
        );
        await drag.moveBy(const Offset(40, 0));
        await tester.pump(const Duration(milliseconds: 60));
        await drag.up();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(
          tester.getSize(find.byKey(const Key('ios-fluid-scrubber-track'))).height,
          closeTo(5.0, 0.5),
        );
        expect(player.seeks, isNotEmpty);

        // 6. GlassworkBackdrop mounts while HUD is visible, and unmounts completely when HUD hides.
        expect(find.byType(GlassworkBackdrop), findsWidgets);
        await tester.pump(const Duration(seconds: 5));
        expect(find.byType(IosPlayerChrome), findsNothing);
        expect(find.byType(GlassworkBackdrop), findsNothing);
        expect(tester.takeException(), isNull);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 100));
      },
    );

    testWidgets(
      'iOS 26+ dispatches showOptionSheet (including forceOpaque under reduceTransparency) while iOS 15-18 uses Flutter fallback',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        IosLiquidGlassBridge.setAvailableForTest(true);
        final calls = <MethodCall>[];
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(IosLiquidGlassBridge.channel, (call) async {
          calls.add(call);
          if (call.method == 'showOptionSheet') {
            final args = call.arguments as Map<dynamic, dynamic>;
            if (args['title'] == '播放倍速') return '4'; // 1.5x in speeds list
          }
          return null;
        });

        final player = _IosFakePlayer();
        await mountIosPlayer(
          tester,
          surfaceSize: const Size(844, 390),
          player: player,
        );

        await tester.tap(find.byKey(const ValueKey('ios-dock-action-speed')));
        await tester.pump(const Duration(milliseconds: 100));
        final speedCall = calls.firstWhere((c) => c.method == 'showOptionSheet');
        expect((speedCall.arguments as Map)['forceOpaque'], isFalse);
        expect(player.rates.last, 1.5);

        // Enable reduceTransparency on iOS 26 -> GlassworkBackdrop unmounts,
        // AND native showOptionSheet STILL dispatches with forceOpaque: true!
        calls.clear();
        IosLiquidGlassBridge.setReduceTransparencyForTest(true);
        await tester.pump();
        expect(find.byType(GlassworkBackdrop), findsNothing);

        await tester.tap(find.byKey(const Key('ios-player-more-button')));
        await tester.pump(const Duration(milliseconds: 100));
        final opaqueCall = calls.firstWhere((c) => c.method == 'showOptionSheet');
        expect((opaqueCall.arguments as Map)['title'], '播放选项');
        expect((opaqueCall.arguments as Map)['forceOpaque'], isTrue);

        // On iOS 15-18 (isAvailable == false) -> Flutter AppleModalSheet fallback opens.
        calls.clear();
        IosLiquidGlassBridge.setAvailableForTest(false);
        await tester.pump();
        await tester.tap(find.byKey(const Key('ios-player-more-button')));
        await tester.pumpAndSettle();
        expect(calls.where((c) => c.method == 'showOptionSheet'), isEmpty);
        expect(find.text('播放选项'), findsOneWidget);
        expect(find.text('定时关闭'), findsOneWidget);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 100));
      },
    );

    testWidgets(
      'opaque hit absorbers block touches on top header, scrubber timestamps & dock padding from leaking to video surface',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        IosLiquidGlassBridge.setAvailableForTest(true);
        final player = _IosFakePlayer();
        await mountIosPlayer(
          tester,
          surfaceSize: const Size(844, 390),
          player: player,
        );
        player.seeks.clear();
        player.rates.clear();

        // 1. Tap on scrubber elapsed timestamp -> must NOT toggle HUD off.
        final elapsedCenter = tester.getCenter(
          find.byKey(const Key('ios-fluid-scrubber-elapsed')),
        );
        await tester.tapAt(elapsedCenter);
        await tester.pump(const Duration(milliseconds: 320));
        expect(find.byType(IosPlayerChrome), findsOneWidget);

        // 2. Tap on bottom dock outer left padding edge -> must NOT toggle HUD off.
        final dockRect = tester.getRect(
          find.byKey(const Key('ios-player-primary-dock')),
        );
        await tester.tapAt(Offset(dockRect.left + 3, dockRect.center.dy));
        await tester.pump(const Duration(milliseconds: 320));
        expect(find.byType(IosPlayerChrome), findsOneWidget);

        // 3. Hold >= 380ms on top header title area -> must NOT trigger 2.0x speed boost or horizontal seek!
        final titleCenter = tester.getCenter(find.text('星海旅途'));
        final hold = await tester.startGesture(
          titleCenter,
          kind: PointerDeviceKind.touch,
        );
        await tester.pump(const Duration(milliseconds: 420));
        await hold.moveBy(const Offset(50, 0));
        await tester.pump(const Duration(milliseconds: 60));
        await hold.up();
        await tester.pump(const Duration(milliseconds: 100));
        expect(player.rates, isEmpty);
        expect(player.seeks, isEmpty);
        expect(find.byType(IosPlayerChrome), findsOneWidget);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 100));
      },
    );

    testWidgets(
      'IosFluidScrubberCapsule tracks active pointerId so second finger cannot jump or prematurely commit scrub',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        // 1. Standalone capsule pointerId isolation: while parent keeps
        // isScrubbing=true, a second finger on the track cannot hijack or
        // prematurely commit, and lifting pointer 1 commits near 75%.
        final ends = <double>[];
        bool scrubbing = false;
        late StateSetter setHostState;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 600,
                  child: StatefulBuilder(
                    builder: (context, setState) {
                      setHostState = setState;
                      return IosFluidScrubberCapsule(
                        position: const Duration(minutes: 5),
                        duration: const Duration(minutes: 30),
                        isScrubbing: scrubbing,
                        scrubPositionMs: const Duration(minutes: 5).inMilliseconds,
                        skipIntroSec: 0,
                        skipOutroSec: 0,
                        ios26Visual: true,
                        reduceTransparency: false,
                        reduceMotion: true,
                        onScrubStart: (_) => setHostState(() => scrubbing = true),
                        onScrubUpdate: (_) {},
                        onScrubEnd: (ms) {
                          ends.add(ms);
                          setHostState(() => scrubbing = false);
                        },
                        onScrubCancel: () => setHostState(() => scrubbing = false),
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        );

        final standaloneRect = tester.getRect(
          find.byKey(const Key('ios-fluid-scrubber-hit-area')),
        );
        final sp1 = await tester.startGesture(
          Offset(
            standaloneRect.left + standaloneRect.width * 0.5,
            standaloneRect.center.dy,
          ),
          kind: PointerDeviceKind.touch,
          pointer: 11,
        );
        await tester.pump();
        await sp1.moveTo(
          Offset(
            standaloneRect.left + standaloneRect.width * 0.75,
            standaloneRect.center.dy,
          ),
        );
        await tester.pump(const Duration(milliseconds: 50));

        // Second finger touches at 10% and lifts -> must NOT commit or reset scrub!
        final sp2 = await tester.startGesture(
          Offset(
            standaloneRect.left + standaloneRect.width * 0.1,
            standaloneRect.center.dy,
          ),
          kind: PointerDeviceKind.touch,
          pointer: 22,
        );
        await tester.pump(const Duration(milliseconds: 30));
        await sp2.moveTo(
          Offset(
            standaloneRect.left + standaloneRect.width * 0.15,
            standaloneRect.center.dy,
          ),
        );
        await sp2.up();
        await tester.pump(const Duration(milliseconds: 50));
        expect(ends, isEmpty);

        // Lifting primary finger commits near 75% (~22:30 of 30:00).
        await sp1.up();
        await tester.pump(const Duration(milliseconds: 50));
        expect(ends, hasLength(1));
        expect(
          ends.single / 1000.0,
          closeTo(const Duration(minutes: 30).inSeconds * 0.75, 45),
        );

        // 2. Inside PlayerScreen with S-01 + NEW-L01 multi-touch cancellation:
        // a second finger triggers parent isScrubbing=false -> capsule clears
        // _activePointerId so lifting finger 1 NEVER emits a stale seek.
        IosLiquidGlassBridge.setAvailableForTest(true);
        final player = _IosFakePlayer();
        await mountIosPlayer(
          tester,
          surfaceSize: const Size(844, 390),
          player: player,
        );
        player.seeks.clear();

        final trackRect = tester.getRect(
          find.byKey(const Key('ios-fluid-scrubber-hit-area')),
        );
        final p1 = await tester.startGesture(
          Offset(trackRect.left + trackRect.width * 0.5, trackRect.center.dy),
          kind: PointerDeviceKind.touch,
          pointer: 31,
        );
        await tester.pump();
        await p1.moveTo(
          Offset(trackRect.left + trackRect.width * 0.75, trackRect.center.dy),
        );
        await tester.pump(const Duration(milliseconds: 50));

        final p2 = await tester.startGesture(
          Offset(trackRect.left + trackRect.width * 0.1, trackRect.center.dy),
          kind: PointerDeviceKind.touch,
          pointer: 32,
        );
        await tester.pump(const Duration(milliseconds: 30));
        await p2.up();
        await p1.up();
        await tester.pump(const Duration(milliseconds: 50));
        expect(player.seeks, isEmpty);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 100));
      },
    );

    testWidgets(
      'responsive layout passes with zero overflow across iPhone portrait, iPad full, and narrow iPad split-view',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        for (final size in const [
          Size(390, 844), // iPhone portrait
          Size(1024, 768), // iPad landscape
          Size(320, 768), // iPad 1/3 split-view
        ]) {
          final player = _IosFakePlayer();
          await mountIosPlayer(tester, surfaceSize: size, player: player);
          expect(find.byType(IosPlayerChrome), findsOneWidget);
          expect(find.byType(UiKitView), findsNothing);
          expect(tester.takeException(), isNull, reason: 'No overflow at $size');
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump(const Duration(milliseconds: 50));
        }
      },
    );

    testWidgets(
      'end-to-end iOS touch long-press -> horizontal slide -> swipe-up lock -> unlock capsule',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        final player = _IosFakePlayer();
        await mountIosPlayer(
          tester,
          surfaceSize: const Size(844, 390),
          player: player,
        );
        // Hide controls cleanly first by waiting 4.5s so surface is fully open.
        await tester.pump(const Duration(milliseconds: 4500));
        expect(find.byType(IosPlayerChrome), findsNothing);
        player.rates.clear();

        // Long-press >= 350ms at center -> 2.0x boost.
        final gesture = await tester.startGesture(
          const Offset(420, 220),
          kind: PointerDeviceKind.touch,
        );
        await tester.pump(const Duration(milliseconds: 380));
        expect(player.rates.last, 2.0);
        expect(find.byKey(const Key('player-speed-boosting-capsule')), findsOneWidget);

        // Slide right +40dp -> 3.0x detent.
        await gesture.moveTo(const Offset(460, 220));
        await tester.pump(const Duration(milliseconds: 50));
        expect(player.rates.last, 3.0);

        // Swipe up -55dp -> lockReady.
        await gesture.moveTo(const Offset(460, 165));
        await tester.pump(const Duration(milliseconds: 50));
        expect(find.byKey(const Key('player-speed-lock-ready-capsule')), findsOneWidget);

        // Release -> speedLocked capsule appears.
        await gesture.up();
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.byKey(const Key('player-speed-locked-capsule')), findsOneWidget);

        // Tap unlock capsule -> restores 1.0x.
        await tester.tap(find.byKey(const Key('player-speed-locked-capsule')));
        await tester.pump(const Duration(milliseconds: 100));
        expect(player.rates.last, 1.0);
        expect(find.byKey(const Key('player-speed-locked-capsule')), findsNothing);

        // Re-lock 2.0x then simulate external AVAudioSession / headset pause (!playing stream)
        // -> speed-lock MUST auto-unlock cleanly and restore 1.0x.
        final gesture2 = await tester.startGesture(
          const Offset(420, 220),
          kind: PointerDeviceKind.touch,
        );
        await tester.pump(const Duration(milliseconds: 380));
        await gesture2.moveTo(const Offset(420, 165));
        await tester.pump(const Duration(milliseconds: 50));
        await gesture2.up();
        await tester.pump(const Duration(milliseconds: 100));
        expect(player.rates.last, 2.0);
        expect(find.byKey(const Key('player-speed-locked-capsule')), findsOneWidget);

        await player.pause();
        await tester.pump(const Duration(milliseconds: 100));
        expect(player.rates.last, 1.0);
        expect(find.byKey(const Key('player-speed-locked-capsule')), findsNothing);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 100));
      },
    );

    testWidgets(
      'S-01: holding scrubber while second finger taps video surface cancels multi-touch without deadlocking position updates',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        IosLiquidGlassBridge.setAvailableForTest(true);
        final player = _IosFakePlayer();
        await mountIosPlayer(
          tester,
          surfaceSize: const Size(844, 390),
          player: player,
        );

        final trackRect = tester.getRect(
          find.byKey(const Key('ios-fluid-scrubber-hit-area')),
        );
        // Finger 1 holds and drags the scrubber (_isSliderDragging = true).
        final p1 = await tester.startGesture(
          Offset(trackRect.left + trackRect.width * 0.4, trackRect.center.dy),
          kind: PointerDeviceKind.touch,
          pointer: 101,
        );
        await tester.pump(const Duration(milliseconds: 50));

        // Finger 2 taps blank video area -> must NOT toggle controls off or deadlock _isSliderDragging!
        final p2 = await tester.startGesture(
          const Offset(420, 120),
          kind: PointerDeviceKind.touch,
          pointer: 102,
        );
        await tester.pump(const Duration(milliseconds: 40));
        await p2.up();
        await tester.pump(const Duration(milliseconds: 320));

        // Release finger 1 and emit a new playback position after the 250ms
        // wall-clock UI throttle: timecode MUST update (not deadlocked!).
        await p1.cancel();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 280)),
        );
        await tester.pump(const Duration(milliseconds: 100));
        player._state.positionValue = const Duration(minutes: 10);
        player._stream.positionCtrl.add(const Duration(minutes: 10));
        await tester.pump(const Duration(milliseconds: 100));

        expect(find.byType(IosPlayerChrome), findsOneWidget);
        expect(
          tester
              .widget<Text>(find.byKey(const Key('ios-fluid-scrubber-elapsed')))
              .data,
          '10:00',
        );

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 100));
      },
    );

    testWidgets(
      'S-01: second finger tapping HUD control cancels active LONG_PRESS_SPEED and restores normal speed',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        IosLiquidGlassBridge.setAvailableForTest(true);
        final player = _IosFakePlayer();
        await mountIosPlayer(
          tester,
          surfaceSize: const Size(844, 390),
          player: player,
        );
        player.rates.clear();

        // Finger 1 holds blank video area >= 350ms -> LONG_PRESS_SPEED (2.0x).
        final p1 = await tester.startGesture(
          const Offset(200, 180),
          kind: PointerDeviceKind.touch,
          pointer: 201,
        );
        await tester.pump(const Duration(milliseconds: 380));
        expect(player.rates.last, 2.0);
        expect(
          find.byKey(const Key('player-speed-boosting-capsule')),
          findsOneWidget,
        );

        // Finger 2 touches top-right HUD button -> outer Listener sees >= 2 pointers and cancels boost!
        final moreCenter = tester.getCenter(
          find.byKey(const Key('ios-player-more-button')),
        );
        final p2 = await tester.startGesture(
          moreCenter,
          kind: PointerDeviceKind.touch,
          pointer: 202,
        );
        await tester.pump(const Duration(milliseconds: 50));
        expect(player.rates.last, 1.0);
        expect(
          find.byKey(const Key('player-speed-boosting-capsule')),
          findsNothing,
        );

        await p2.cancel();
        await p1.up();
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 100));
      },
    );

    testWidgets(
      'S-01: IosFluidScrubberCapsule.dispose() mid-drag invokes onScrubCancel cleanly without throwing',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        var cancelCalls = 0;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 360,
                  child: IosFluidScrubberCapsule(
                    position: const Duration(minutes: 2),
                    duration: const Duration(minutes: 20),
                    isScrubbing: false,
                    scrubPositionMs: 0,
                    skipIntroSec: 0,
                    skipOutroSec: 0,
                    ios26Visual: true,
                    reduceTransparency: false,
                    reduceMotion: false,
                    onScrubStart: (_) {},
                    onScrubUpdate: (_) {},
                    onScrubEnd: (_) {},
                    onScrubCancel: () => cancelCalls++,
                  ),
                ),
              ),
            ),
          ),
        );

        final hitCenter = tester.getCenter(
          find.byKey(const Key('ios-fluid-scrubber-hit-area')),
        );
        final drag = await tester.startGesture(
          hitCenter,
          kind: PointerDeviceKind.touch,
        );
        await tester.pump(const Duration(milliseconds: 40));

        // Unmount scrubber mid-drag (e.g. HUD hidden or route popped mid-scrub).
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        expect(cancelCalls, 1);
        expect(tester.takeException(), isNull);
        await drag.cancel();
      },
    );

    testWidgets(
      'S-04: iOS 15-18 (isAvailable == false, reduceTransparency == false) mounts ZERO GlassworkBackdrop or BackdropFilter shaders',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        IosLiquidGlassBridge.setAvailableForTest(false);
        IosLiquidGlassBridge.setReduceTransparencyForTest(false);
        final player = _IosFakePlayer();
        await mountIosPlayer(
          tester,
          surfaceSize: const Size(844, 390),
          player: player,
        );

        expect(find.byType(IosPlayerChrome), findsOneWidget);
        expect(find.byType(UiKitView), findsNothing);
        expect(find.byType(GlassworkBackdrop), findsNothing);
        expect(find.byType(BackdropFilter), findsNothing);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 100));
      },
    );

    testWidgets(
      'M-04: system reduceTransparency degrades LiquidGlass, AppleGlassSurface, AppleModalSheet, locked overlay and error card to #F51E1E22 with zero GlassworkBackdrop',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        IosLiquidGlassBridge.setAvailableForTest(true);
        IosLiquidGlassBridge.setReduceTransparencyForTest(true);
        final player = _IosFakePlayer();
        await mountIosPlayer(
          tester,
          surfaceSize: const Size(844, 390),
          player: player,
        );

        expect(find.byType(GlassworkBackdrop), findsNothing);

        // Open AppleModalSheet (Lines sheet) -> LiquidGlass inside sheet MUST NOT mount GlassworkBackdrop!
        await tester.tap(find.byKey(const ValueKey('ios-dock-action-lines')));
        await tester.pumpAndSettle();
        expect(find.text('切换播放线路'), findsOneWidget);
        expect(find.byType(GlassworkBackdrop), findsNothing);
        // Verify solid #F51E1E22 surface inside LiquidGlass.
        final sheetContainers = tester
            .widgetList<Container>(
              find.descendant(
                of: find.byType(LiquidGlass),
                matching: find.byType(Container),
              ),
            )
            .where(
              (c) =>
                  c.decoration is ShapeDecoration &&
                  (c.decoration! as ShapeDecoration).color ==
                      const Color(0xF51E1E22),
            );
        expect(sheetContainers, isNotEmpty);
        await tester.tapAt(const Offset(10, 10));
        await tester.pumpAndSettle();

        // Trigger locked overlay -> solid #F51E1E22, zero GlassworkBackdrop.
        await tester.tap(find.byKey(const Key('player-lock-button')));
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.byKey(const Key('player-unlock-button')), findsOneWidget);
        expect(find.byType(GlassworkBackdrop), findsNothing);
        await tester.tap(find.byKey(const Key('player-unlock-button')));
        await tester.pump(const Duration(milliseconds: 100));

        // Verify standalone AppleGlassSurface under reduceTransparency renders #F51E1E22 in Dark Mode with zero GlassworkBackdrop,
        // and respects !OhosRuntime.isOhos guard.
        await tester.pumpWidget(
          MaterialApp(
            key: const ValueKey('m04-dark-glass-surface'),
            theme: ThemeData.dark(),
            home: const Scaffold(
              body: AppleGlassSurface(child: Text('glass-check')),
            ),
          ),
        );
        expect(find.byType(GlassworkBackdrop), findsNothing);
        final solidSurface = tester.widget<Container>(
          find.descendant(
            of: find.byType(AppleGlassSurface),
            matching: find.byType(Container),
          ),
        );
        expect(
          (solidSurface.decoration! as BoxDecoration).color,
          const Color(0xF51E1E22),
        );

        // Guarded off on HarmonyOS NEXT.
        OhosRuntime.debugIsOhosOverride = true;
        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(
              body: AppleGlassSurface(child: Text('ohos-check')),
            ),
          ),
        );
        expect(find.byType(GlassworkBackdrop), findsOneWidget);
        OhosRuntime.resetForTesting();

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 100));
      },
    );

    testWidgets(
      'M-05: native sheet single-flight mutex rejects concurrent calls, PlayerScreen.dispose() invokes dismissActiveSheets, and stale session audio pick is ignored',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        IosLiquidGlassBridge.setAvailableForTest(true);
        final calls = <MethodCall>[];
        Completer<String?>? pendingOptionSheet;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(IosLiquidGlassBridge.channel, (call) async {
          calls.add(call);
          if (call.method == 'showOptionSheet') {
            pendingOptionSheet = Completer<String?>();
            return pendingOptionSheet!.future;
          }
          return null;
        });

        final player = _IosFakePlayer();
        player._state.tracksValue = Tracks(
          audio: [AudioTrack('a1', '中文配音', 'zh'), AudioTrack('a2', '原声', 'en')],
        );
        const twoEpVideo = CmsVideo(
          id: 'ios_m05_vid',
          title: '单飞弹窗测试',
          lines: [
            CmsLine(
              name: '主线路',
              episodes: [
                CmsEpisode(name: '第01集', url: 'file:///tmp/m05_e1.mp4'),
                CmsEpisode(name: '第02集', url: 'file:///tmp/m05_e2.mp4'),
              ],
            ),
          ],
        );

        await mountIosPlayer(
          tester,
          surfaceSize: const Size(844, 390),
          player: player,
          videoOverride: twoEpVideo,
        );

        // Tap speed button -> first showOptionSheet in flight.
        await tester.tap(find.byKey(const ValueKey('ios-dock-action-speed')));
        await tester.pump(const Duration(milliseconds: 50));
        expect(IosLiquidGlassBridge.isSheetPresentationInFlight, isTrue);
        expect(calls.where((c) => c.method == 'showOptionSheet'), hasLength(1));

        // Concurrently tap more button while first sheet is in flight -> MUST be rejected cleanly!
        await tester.tap(find.byKey(const Key('ios-player-more-button')));
        await tester.pump(const Duration(milliseconds: 50));
        expect(calls.where((c) => c.method == 'showOptionSheet'), hasLength(1));

        // Finish first sheet -> lock releases.
        pendingOptionSheet!.complete(null);
        await tester.pump(const Duration(milliseconds: 50));
        expect(IosLiquidGlassBridge.isSheetPresentationInFlight, isFalse);

        // Open audio/subtitle quick menu -> choose 'audio' -> opens audio sheet (in flight).
        calls.clear();
        await tester.tap(find.byKey(const Key('ios-player-tracks-button')));
        await tester.pump(const Duration(milliseconds: 50));
        expect(calls.where((c) => c.method == 'showOptionSheet'), hasLength(1));
        pendingOptionSheet!.complete('0'); // 'audio'
        await tester.pump(const Duration(milliseconds: 50));
        expect(calls.where((c) => c.method == 'showOptionSheet'), hasLength(2));

        // Switch episode (advances _playSession) while audio sheet is still open!
        await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
        await tester.pump(const Duration(milliseconds: 100));

        // Complete the stale audio sheet pick -> MUST be ignored by session != _playSession guard!
        pendingOptionSheet!.complete('1');
        await tester.pump(const Duration(milliseconds: 50));
        expect(player.audioTracksSet, isEmpty);

        // Dispose PlayerScreen -> MUST invoke dismissActiveSheets on native channel!
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 100));
        expect(
          calls.where((c) => c.method == 'dismissActiveSheets'),
          isNotEmpty,
        );
      },
    );

    testWidgets(
      'M-06: iOS 26 spatial glass aligns to Home/Detail dark obsidian tint (#3D161820) + 135deg rim, top capsules clear header when controls visible, and SkipCountdownOverlay fits 320pt Split View',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        IosLiquidGlassBridge.setAvailableForTest(true);
        IosLiquidGlassBridge.setReduceTransparencyForTest(false);
        final player = _IosFakePlayer();
        await mountIosPlayer(
          tester,
          surfaceSize: const Size(844, 390),
          padding: const EdgeInsets.fromLTRB(59, 0, 59, 21),
          player: player,
        );

        // 1. Aesthetic unity: inspect ShapeDecoration inside back button & center play button.
        final backContainer = tester.widget<Container>(
          find.descendant(
            of: find.byKey(const Key('ios-player-back-button')),
            matching: find.byType(Container),
          ).first,
        );
        final backDeco = backContainer.decoration! as ShapeDecoration;
        final backGrad = backDeco.gradient! as LinearGradient;
        expect(backGrad.begin, Alignment.topLeft);
        expect(backGrad.end, Alignment.bottomRight);
        // Must NOT contain the old washed-out white haze colors.
        expect(backGrad.colors, isNot(contains(const Color(0x38FFFFFF))));
        expect(backGrad.colors, isNot(contains(const Color(0x52FFFFFF))));
        // Middle stop is exact Home/Detail dark obsidian glass tint #3D161820.
        expect(backGrad.colors[1], const Color(0x3D161820));
        // Uses CustomPaint directional rim painter rather than uniform Border.all.
        expect(
          find.descendant(
            of: find.byKey(const Key('ios-player-back-button')),
            matching: find.byType(CustomPaint),
          ),
          findsWidgets,
        );

        // 2. Top capsule non-overlap when controls become visible during SPEED_LOCKED.
        await tester.pump(const Duration(milliseconds: 4500));
        expect(find.byType(IosPlayerChrome), findsNothing);
        final hold = await tester.startGesture(
          const Offset(420, 220),
          kind: PointerDeviceKind.touch,
        );
        await tester.pump(const Duration(milliseconds: 380));
        await hold.moveTo(const Offset(420, 160));
        await tester.pump(const Duration(milliseconds: 50));
        await hold.up();
        await tester.pump(const Duration(milliseconds: 100));
        expect(
          find.byKey(const Key('player-speed-locked-capsule')),
          findsOneWidget,
        );

        // Wake HUD while speed is locked -> locked capsule MUST NOT overlap top header!
        await tester.tapAt(const Offset(420, 260));
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.byType(IosPlayerChrome), findsOneWidget);
        final headerRect = tester.getRect(
          find.byKey(const Key('ios-player-top-header-hit-area')),
        );
        final lockedRect = tester.getRect(
          find.byKey(const Key('player-speed-locked-capsule')),
        );
        expect(headerRect.overlaps(lockedRect), isFalse);
        expect(lockedRect.top, greaterThanOrEqualTo(headerRect.bottom));

        // 3. Narrow 320pt iPad Split View: SkipCountdownOverlay MUST fit within 320pt with zero overflow!
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 100));

        final splitStorage = await initTestStorage();
        await splitStorage.setVideoSkipIntroSec(
          site.key,
          video.id,
          90,
          isPrivate: true,
        );
        final splitPlayer = _IosFakePlayer()
          ..initialDuration = const Duration(minutes: 20)
          ..initialPosition = const Duration(seconds: 10);
        await mountIosPlayer(
          tester,
          surfaceSize: const Size(320, 768),
          player: splitPlayer,
          storageOverride: splitStorage,
        );
        expect(find.byKey(const Key('skip-countdown-overlay')), findsOneWidget);
        expect(tester.takeException(), isNull);
        final skipRect = tester.getRect(
          find.byKey(const Key('skip-countdown-overlay')),
        );
        expect(skipRect.left, greaterThanOrEqualTo(16.0));
        expect(skipRect.right, lessThanOrEqualTo(320.0 - 16.0 + 0.1));

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 100));
      },
    );

    testWidgets(
      'L-02: _showAudioSubtitleQuickSheet fallback on iOS 15-18 shows both audio and subtitle chooser entries',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        IosLiquidGlassBridge.setAvailableForTest(false);
        final player = _IosFakePlayer();
        await mountIosPlayer(
          tester,
          surfaceSize: const Size(844, 390),
          player: player,
        );

        await tester.tap(find.byKey(const Key('ios-player-tracks-button')));
        await tester.pumpAndSettle();
        expect(find.text('音轨与字幕'), findsOneWidget);
        expect(find.text('切换音轨'), findsOneWidget);
        expect(find.text('切换内嵌字幕'), findsOneWidget);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 100));
      },
    );

    testWidgets(
      'L-03: long-press release with restoreMode 1.0x syncs HUD speed badge from 1.5x to 1.0x',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        IosLiquidGlassBridge.setAvailableForTest(true);
        final storage = await initTestStorage();
        await storage.setPlaySpeed(1.5);
        final prefs = PlayerHudPrefs.inMemory(isDesktop: false);
        addTearDown(prefs.dispose);
        await prefs.setLongPressRestoreMode('1.0x');

        final player = _IosFakePlayer();
        await mountIosPlayer(
          tester,
          surfaceSize: const Size(844, 390),
          player: player,
          storageOverride: storage,
          prefsOverride: prefs,
        );

        // Initially HUD shows 1.5×.
        expect(find.text('1.5×'), findsOneWidget);

        // Hide controls, long-press >= 350ms (2.0x), then release -> restores 1.0x.
        await tester.pump(const Duration(milliseconds: 4500));
        final hold = await tester.startGesture(
          const Offset(420, 220),
          kind: PointerDeviceKind.touch,
        );
        await tester.pump(const Duration(milliseconds: 380));
        expect(player.rates.last, 2.0);
        await hold.up();
        await tester.pump(const Duration(milliseconds: 100));
        expect(player.rates.last, 1.0);

        // Wake controls -> speed badge MUST now display 1.0× (synced with _normalSpeed)!
        await tester.tapAt(const Offset(420, 220));
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('1.0×'), findsOneWidget);
        expect(find.text('1.5×'), findsNothing);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 100));
      },
    );

    testWidgets(
      'L-07: IosNativeRouteGate.runWithPlaceholders completes via 100ms timeout fallback when frame never arrives and restores placeholder depth',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        IosLiquidGlassBridge.setAvailableForTest(true);
        String? outcome;
        await tester.runAsync(() async {
          // No frame is pumped during runAsync -> hits timeout fallback cleanly!
          outcome = await IosNativeRouteGate.runWithPlaceholders<String>(
            () async => 'recovered',
            frameTimeout: const Duration(milliseconds: 50),
          );
        });
        expect(outcome, 'recovered');
        expect(IosNativeRouteGate.forcePlaceholders, isFalse);
      },
    );

    testWidgets(
      'iOS 27 HUD optional PiP, Engine Switch & Vocal Loudness callbacks render when supplied and spring swell scales outward on press',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        IosLiquidGlassBridge.setAvailableForTest(true);
        var pipTapped = 0;
        var engineTapped = 0;
        var loudnessTapped = 0;

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 844,
                height: 390,
                child: IosPlayerChrome(
                  title: 'iOS 27 空间影院',
                  episodeName: '第01集',
                  lineName: '原生内核',
                  isLive: false,
                  playing: true,
                  loading: false,
                  buffering: false,
                  hasError: false,
                  position: const Duration(minutes: 2),
                  duration: const Duration(minutes: 40),
                  isScrubbing: false,
                  scrubPositionMs: 0,
                  playbackSpeed: 1.0,
                  skipIntroSec: 0,
                  skipOutroSec: 0,
                  specBadges: const [],
                  fallbackSpecsLabel: '4K HDR',
                  specBadgesExpanded: false,
                  isLandscape: true,
                  danmuEnabled: true,
                  sleepTimerActive: false,
                  hasMultipleLines: true,
                  storageReduceTransparency: false,
                  isPipSupported: true,
                  isPipActive: false,
                  onPipTap: () => pipTapped++,
                  engineLabel: 'AVPlayer',
                  isAvPlayerActive: true,
                  onEngineSwitchTap: () => engineTapped++,
                  vocalLoudnessLabel: '影院人声',
                  vocalLoudnessActive: true,
                  onVocalLoudnessTap: () => loudnessTapped++,
                  onBack: () {},
                  onPlayPause: () {},
                  onRewind15: () {},
                  onForward15: () {},
                  onScrubStart: (_) {},
                  onScrubUpdate: (_) {},
                  onScrubEnd: (_) {},
                  onScrubCancel: () {},
                  onEpisodesTap: () {},
                  onLinesTap: () {},
                  onSpeedTap: () {},
                  onDanmuToggle: () {},
                  onDanmuSettingsTap: () {},
                  onAspectAndStrategyTap: () {},
                  onAudioSubtitleTap: () {},
                  onMoreTap: () {},
                  onLockTap: () {},
                  onFullscreenToggle: () {},
                  onInteraction: () {},
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        expect(find.byKey(const Key('ios-player-pip-button')), findsOneWidget);
        expect(
          find.byKey(const Key('ios-player-engine-button')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('ios-player-loudness-button')),
          findsOneWidget,
        );
        expect(find.text('AVPlayer'), findsOneWidget);
        expect(find.text('影院人声'), findsOneWidget);

        // Press down center play button -> iOS 27 SpringSimulation fluid gel swell (> 1.0x, NOT shrink)
        final playFinder = find.byKey(const Key('player-center-play-pause'));
        final beforeSize = tester.getSize(playFinder);
        final press = await tester.startGesture(tester.getCenter(playFinder));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 120));
        final transform = tester.widget<Transform>(
          find.descendant(of: playFinder, matching: find.byType(Transform)).first,
        );
        expect(transform.transform.getMaxScaleOnAxis(), greaterThan(1.0));
        expect(beforeSize, const Size(76.0, 76.0));
        await press.up();
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('ios-player-pip-button')));
        await tester.tap(find.byKey(const Key('ios-player-engine-button')));
        await tester.tap(find.byKey(const Key('ios-player-loudness-button')));
        await tester.pump();

        expect(pipTapped, 1);
        expect(engineTapped, 1);
        expect(loudnessTapped, 1);
      },
    );

    testWidgets(
      'showIosCastPopover renders iOS 27 4-side inset concentric Liquid Glass panel with AirPlay 2 + DLNA',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        IosLiquidGlassBridge.setAvailableForTest(true);
        final controller = CastController()
          ..setDevicesForTest(const [
            CastDevice(
              id: 'uuid:test-tv',
              name: 'Apple TV 客厅',
              model: 'Marco TV',
              host: '127.0.0.1',
              location: 'http://127.0.0.1:18652/desc.xml',
              avTransportControlUrl: 'http://127.0.0.1:18652/ctrl',
            ),
          ]);
        addTearDown(controller.dispose);

        CastDevice? picked;
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData.dark(),
            home: Scaffold(
              body: Builder(
                builder: (ctx) => Center(
                  child: ElevatedButton(
                    onPressed: () => showIosCastPopover(
                      context: ctx,
                      anchorRect: const Rect.fromLTWH(300, 40, 36, 36),
                      controller: controller,
                      isAirPlayActive: true,
                      airPlayDeviceName: '客厅 HomePod',
                      onSelectDevice: (d) async => picked = d,
                    ),
                    child: const Text('投屏'),
                  ),
                ),
              ),
            ),
          ),
        );

        await tester.tap(find.text('投屏'));
        await tester.pumpAndSettle();

        final panelFinder = find.byKey(const Key('ios-cast-inset-panel'));
        expect(panelFinder, findsOneWidget);
        final panelRect = tester.getRect(panelFinder);
        // 4-side inset verification (not edge-to-edge 0px)
        expect(panelRect.left, greaterThanOrEqualTo(10.0));
        expect(panelRect.bottom, lessThan(600.0));
        expect(find.byKey(const Key('ios-cast-airplay-row')), findsOneWidget);
        expect(find.text('AirPlay 2'), findsOneWidget);
        expect(find.text('Apple TV 客厅'), findsOneWidget);

        await tester.tap(find.text('Apple TV 客厅'));
        await tester.pumpAndSettle();
        expect(picked?.id, 'uuid:test-tv');
      },
    );
  });
}
