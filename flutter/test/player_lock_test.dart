import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/core/storage_service.dart';
import 'package:marco_movie/ui/player_screen.dart';
import 'package:marco_movie/ui/windows_title_bar.dart';
import 'package:media_kit/media_kit.dart';
import 'test_storage_helper.dart';

class _FakePlayerState extends Fake implements PlayerState {
  Playlist playlistValue = const Playlist([]);
  bool playingValue = false;
  bool completedValue = false;
  Duration positionValue = Duration.zero;
  Duration durationValue = Duration.zero;
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

class _FakePlayerStream extends Fake implements PlayerStream {
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

class _FakePlayer extends Fake implements Player {
  final _FakePlayerState _state = _FakePlayerState();
  final _FakePlayerStream _stream = _FakePlayerStream();

  int playOrPauseCalls = 0;
  int playCalls = 0;
  int pauseCalls = 0;
  final List<Duration> seeks = <Duration>[];
  final List<double> rates = <double>[];
  final List<double> volumes = <double>[];
  bool disposed = false;

  @override
  PlatformPlayer? get platform => null;

  @override
  PlayerState get state => _state;

  @override
  PlayerStream get stream => _stream;

  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    if (playable is Media) {
      _state.playlistValue = Playlist([playable]);
    } else if (playable is Playlist) {
      _state.playlistValue = playable;
    }
    _state.durationValue = const Duration(minutes: 20);
    _state.positionValue = const Duration(minutes: 2);
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
  Future<void> stop() async {
    _state.playingValue = false;
  }

  @override
  Future<void> play() async {
    playCalls++;
    _state.playingValue = true;
    if (!disposed) _stream.playingCtrl.add(true);
  }

  @override
  Future<void> pause() async {
    pauseCalls++;
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

  void resetCounters() {
    playOrPauseCalls = 0;
    playCalls = 0;
    pauseCalls = 0;
    seeks.clear();
    rates.clear();
    volumes.clear();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const windowChannel = MethodChannel('window_manager');

  const site = CmsSite(
    key: 'test_site',
    name: '测试源',
    type: 1,
    api: 'https://source.example/api',
    isPrivate: true,
  );
  const video = CmsVideo(
    id: 'vid_lock_1',
    title: '防误触测试影片',
    lines: [
      CmsLine(
        name: '默认线路',
        episodes: [
          CmsEpisode(name: '第01集', url: 'file:///tmp/lock_e1.mp4'),
          CmsEpisode(name: '第02集', url: 'file:///tmp/lock_e2.mp4'),
        ],
      ),
    ],
  );

  late StorageService storage;
  int setFullScreenCalls = 0;
  int closeWindowCalls = 0;
  bool mockFullScreen = false;

  setUp(() async {
    setFullScreenCalls = 0;
    closeWindowCalls = 0;
    mockFullScreen = false;
    WindowsImmersiveFrame.interactionLocked.value = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(windowChannel, (call) async {
      switch (call.method) {
        case 'isFullScreen':
          return mockFullScreen;
        case 'isMaximized':
          return false;
        case 'close':
          closeWindowCalls++;
          return null;
        case 'setFullScreen':
          setFullScreenCalls++;
          final args = call.arguments;
          if (args is Map && args['isFullScreen'] is bool) {
            mockFullScreen = args['isFullScreen'] as bool;
          }
          return null;
        default:
          return null;
      }
    });
    storage = await initTestStorage();
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    WindowsImmersiveFrame.interactionLocked.value = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(windowChannel, null);
  });

  Future<T> withPlatform<T>(
    TargetPlatform platform,
    Future<T> Function() body,
  ) async {
    debugDefaultTargetPlatformOverride = platform;
    try {
      return await body();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  }

  Future<GlobalKey<NavigatorState>> mountPlayer(
    WidgetTester tester, {
    required Size surfaceSize,
    required _FakePlayer player,
    bool wrapWindowsFrame = false,
  }) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = surfaceSize;
    await tester.binding.setSurfaceSize(surfaceSize);
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final navKey = GlobalKey<NavigatorState>();
    final app = MaterialApp(
      navigatorKey: navKey,
      builder: wrapWindowsFrame
          ? (context, child) => WindowsImmersiveFrame(
                attachWindowListener: false,
                child: child ?? const SizedBox.shrink(),
              )
          : null,
      home: Scaffold(
        body: Center(
          child: Builder(
            builder: (ctx) => ElevatedButton(
              onPressed: () {
                Navigator.of(ctx).push(
                  MaterialPageRoute<void>(
                    builder: (_) => PlayerScreen(
                      site: site,
                      video: video,
                      initialLineIndex: 0,
                      initialEpisodeIndex: 0,
                      storage: storage,
                      debugPlayer: player,
                      debugVideoSurface: const ColoredBox(color: Colors.black),
                    ),
                  ),
                );
              },
              child: const Text('Open Player'),
            ),
          ),
        ),
      ),
    );

    await tester.pumpWidget(app);
    await tester.tap(find.text('Open Player'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    player.resetCounters();
    return navKey;
  }

  testWidgets('iOS landscape screen lock blocks all touch gestures and pop', (
    tester,
  ) async {
    await withPlatform(TargetPlatform.iOS, () async {
      final player = _FakePlayer();
      final navKey = await mountPlayer(
        tester,
        surfaceSize: const Size(844, 390),
        player: player,
      );

      expect(find.byKey(const Key('player-lock-button')), findsOneWidget);
      expect(find.byKey(const Key('player-center-play-pause')), findsOneWidget);
      expect(find.byKey(const Key('player-progress-bar')), findsOneWidget);

      await tester.tap(
        find.byKey(const Key('player-lock-button')),
        kind: PointerDeviceKind.touch,
      );
      await tester.pump(const Duration(milliseconds: 250));

      // All player controls hidden; only unlock button visible
      expect(find.byKey(const Key('player-lock-button')), findsNothing);
      expect(find.byKey(const Key('player-center-play-pause')), findsNothing);
      expect(find.byKey(const Key('player-progress-bar')), findsNothing);
      expect(find.byKey(const Key('player-tool-dock-landscape')), findsNothing);
      expect(find.text('返回'), findsNothing);
      expect(find.byKey(const Key('player-unlock-button')), findsOneWidget);

      // Unlock button auto-hides after 3.5s
      await tester.pump(const Duration(milliseconds: 3600));
      expect(find.byKey(const Key('player-unlock-button')), findsNothing);

      // Double tap while locked does NOT pause/play
      await tester.tapAt(const Offset(420, 195), kind: PointerDeviceKind.touch);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tapAt(const Offset(420, 195), kind: PointerDeviceKind.touch);
      await tester.pump(const Duration(milliseconds: 350));
      expect(player.playOrPauseCalls, 0);
      expect(player.pauseCalls, 0);
      expect(find.byKey(const Key('player-center-play-pause')), findsNothing);

      // Long press while locked does NOT boost speed to 2.0x
      final gesture = await tester.startGesture(
        const Offset(420, 195),
        kind: PointerDeviceKind.touch,
      );
      await tester.pump(const Duration(milliseconds: 700));
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 100));
      expect(player.rates, isEmpty);

      // Horizontal drag while locked does NOT seek
      await tester.dragFrom(
        const Offset(220, 195),
        const Offset(260, 0),
        kind: PointerDeviceKind.touch,
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(player.seeks, isEmpty);

      // Vertical drags on left (brightness) & right (volume) do NOT adjust values
      await tester.dragFrom(
        const Offset(140, 260),
        const Offset(0, -120),
        kind: PointerDeviceKind.touch,
      );
      await tester.dragFrom(
        const Offset(700, 260),
        const Offset(0, -120),
        kind: PointerDeviceKind.touch,
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(player.volumes, isEmpty);

      // Route pop / system back is blocked while locked and reveals unlock pill
      await tester.pump(const Duration(milliseconds: 3600));
      expect(find.byKey(const Key('player-unlock-button')), findsNothing);
      await navKey.currentState!.maybePop();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(PlayerScreen), findsOneWidget);
      expect(find.byKey(const Key('player-unlock-button')), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 3600));
      expect(find.byKey(const Key('player-unlock-button')), findsNothing);
      await tester.binding.handlePopRoute();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(PlayerScreen), findsOneWidget);
      expect(find.byKey(const Key('player-unlock-button')), findsOneWidget);

      // Tap unlock button -> restores controls and interactions
      await tester.tap(
        find.byKey(const Key('player-unlock-button')),
        kind: PointerDeviceKind.touch,
      );
      await tester.pump(const Duration(milliseconds: 250));

      expect(find.byKey(const Key('player-unlock-button')), findsNothing);
      expect(find.byKey(const Key('player-center-play-pause')), findsOneWidget);
      expect(find.byKey(const Key('player-progress-bar')), findsOneWidget);

      // Double tap now toggles play/pause again
      await tester.tapAt(const Offset(420, 60), kind: PointerDeviceKind.touch);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tapAt(const Offset(420, 60), kind: PointerDeviceKind.touch);
      await tester.pump(const Duration(milliseconds: 350));
      expect(player.playOrPauseCalls, 1);

      final poppedAfterUnlock = await navKey.currentState!.maybePop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(poppedAfterUnlock, isTrue);
      expect(find.byType(PlayerScreen), findsNothing);
    });
  });

  testWidgets('iOS portrait header lock button and tool dock lock work', (
    tester,
  ) async {
    await withPlatform(TargetPlatform.iOS, () async {
      final player = _FakePlayer();
      await mountPlayer(
        tester,
        surfaceSize: const Size(390, 844),
        player: player,
      );

      expect(find.byKey(const Key('player-lock-button')), findsOneWidget);
      expect(find.byKey(const Key('player-tool-dock-portrait')), findsOneWidget);

      await tester.tap(
        find.byKey(const Key('player-lock-button')),
        kind: PointerDeviceKind.touch,
      );
      await tester.pump(const Duration(milliseconds: 250));

      expect(find.byKey(const Key('player-tool-dock-portrait')), findsNothing);
      expect(find.byKey(const Key('player-unlock-button')), findsOneWidget);

      await tester.tap(
        find.byKey(const Key('player-unlock-button')),
        kind: PointerDeviceKind.touch,
      );
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.byKey(const Key('player-tool-dock-portrait')), findsOneWidget);
    });
  });

  Future<void> sendMacKey(LogicalKeyboardKey key) async {
    await simulateKeyDownEvent(key);
    await simulateKeyUpEvent(key);
  }

  Future<bool> sendMacCmdW(WidgetTester tester) async {
    await simulateKeyDownEvent(LogicalKeyboardKey.metaLeft, platform: 'windows');
    expect(HardwareKeyboard.instance.isMetaPressed, isTrue);
    final handled = await simulateKeyDownEvent(
      LogicalKeyboardKey.keyW,
      platform: 'windows',
    );
    await simulateKeyUpEvent(LogicalKeyboardKey.keyW, platform: 'windows');
    await simulateKeyUpEvent(LogicalKeyboardKey.metaLeft, platform: 'windows');
    await tester.pump();
    return handled;
  }

  testWidgets('macOS screen lock blocks keyboard shortcuts, mouse & Meta+W', (
    tester,
  ) async {
    await withPlatform(TargetPlatform.macOS, () async {
      final player = _FakePlayer();
      await mountPlayer(
        tester,
        surfaceSize: const Size(1280, 800),
        player: player,
      );

      await tester.tap(
        find.byKey(const Key('player-lock-button')),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.byKey(const Key('player-unlock-button')), findsOneWidget);
      expect(find.byKey(const Key('player-progress-bar')), findsNothing);

      // Wait for unlock pill to auto-hide, then move mouse: only unlock pill shows
      await tester.pump(const Duration(milliseconds: 3600));
      expect(find.byKey(const Key('player-unlock-button')), findsNothing);

      await tester.sendEventToBinding(
        const PointerHoverEvent(
          position: Offset(460, 320),
          delta: Offset(12, 8),
          kind: PointerDeviceKind.mouse,
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(const Key('player-unlock-button')), findsOneWidget);
      expect(find.byKey(const Key('player-progress-bar')), findsNothing);

      // Double-click on video surface while locked must NOT toggle fullscreen
      await tester.tapAt(const Offset(640, 400), kind: PointerDeviceKind.mouse);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tapAt(const Offset(640, 400), kind: PointerDeviceKind.mouse);
      await tester.pump(const Duration(milliseconds: 350));
      expect(setFullScreenCalls, 0);

      // Keyboard shortcuts must all be blocked while locked
      for (final key in <LogicalKeyboardKey>[
        LogicalKeyboardKey.space,
        LogicalKeyboardKey.enter,
        LogicalKeyboardKey.arrowRight,
        LogicalKeyboardKey.arrowLeft,
        LogicalKeyboardKey.arrowUp,
        LogicalKeyboardKey.arrowDown,
        LogicalKeyboardKey.bracketLeft,
        LogicalKeyboardKey.bracketRight,
        LogicalKeyboardKey.keyM,
        LogicalKeyboardKey.keyF,
        LogicalKeyboardKey.f11,
        LogicalKeyboardKey.escape,
      ]) {
        await sendMacKey(key);
        await tester.pump(const Duration(milliseconds: 30));
      }

      // Meta+W must NOT close PlayerScreen while locked
      await sendMacCmdW(tester);
      await tester.pump(const Duration(milliseconds: 200));

      expect(player.playOrPauseCalls, 0);
      expect(player.seeks, isEmpty);
      expect(player.rates, isEmpty);
      expect(player.volumes, isEmpty);
      expect(setFullScreenCalls, 0);
      expect(find.byType(PlayerScreen), findsOneWidget);

      // Click unlock button -> keyboard shortcuts work again
      await tester.sendEventToBinding(
        const PointerHoverEvent(
          position: Offset(500, 340),
          delta: Offset(12, 8),
          kind: PointerDeviceKind.mouse,
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(
        find.byKey(const Key('player-unlock-button')),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump(const Duration(milliseconds: 250));

      await sendMacKey(LogicalKeyboardKey.space);
      await tester.pump(const Duration(milliseconds: 50));
      expect(player.playOrPauseCalls, 1);

      await sendMacKey(LogicalKeyboardKey.arrowRight);
      await tester.pump(const Duration(milliseconds: 50));
      expect(player.seeks, hasLength(1));

      final cmdWHandled = await sendMacCmdW(tester);
      expect(cmdWHandled, isTrue, reason: 'Cmd+W should be handled');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 800));
      expect(find.byType(PlayerScreen), findsNothing);
    });
  });

  testWidgets(
    'Windows screen lock disables WindowsTitleBar and blocks Ctrl+W & shortcuts',
    (tester) async {
      await withPlatform(TargetPlatform.windows, () async {
        final player = _FakePlayer();
        await mountPlayer(
          tester,
          surfaceSize: const Size(1280, 800),
          player: player,
          wrapWindowsFrame: true,
        );

        IgnorePointer titleBarIgnorePointer() {
          final ignoreFinder = find.ancestor(
            of: find.byType(WindowsTitleBar),
            matching: find.byType(IgnorePointer),
          );
          return tester.widget<IgnorePointer>(ignoreFinder.first);
        }

        expect(WindowsImmersiveFrame.interactionLocked.value, isFalse);
        expect(titleBarIgnorePointer().ignoring, isFalse);

        await tester.tap(
          find.byKey(const Key('player-lock-button')),
          kind: PointerDeviceKind.mouse,
        );
        await tester.pump(const Duration(milliseconds: 250));

        expect(WindowsImmersiveFrame.interactionLocked.value, isTrue);
        expect(titleBarIgnorePointer().ignoring, isTrue);

        // Clicking the Windows close button region while locked must NOT close window
        await tester.tapAt(
          const Offset(1257, 16),
          kind: PointerDeviceKind.mouse,
        );
        await tester.pump(const Duration(milliseconds: 50));
        expect(closeWindowCalls, 0);

        // Ctrl+W and Space must be blocked while locked on Windows
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyW);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.space);
        await tester.pump(const Duration(milliseconds: 250));

        expect(player.playOrPauseCalls, 0);
        expect(find.byType(PlayerScreen), findsOneWidget);

        // Unlock restores WindowsTitleBar interactivity
        await tester.tap(
          find.byKey(const Key('player-unlock-button')),
          kind: PointerDeviceKind.mouse,
        );
        await tester.pump(const Duration(milliseconds: 250));

        expect(WindowsImmersiveFrame.interactionLocked.value, isFalse);
        expect(titleBarIgnorePointer().ignoring, isFalse);

        // Re-lock and unmount widget tree -> dispose() must clear interactionLocked
        await tester.tap(
          find.byKey(const Key('player-lock-button')),
          kind: PointerDeviceKind.mouse,
        );
        await tester.pump(const Duration(milliseconds: 100));
        expect(WindowsImmersiveFrame.interactionLocked.value, isTrue);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 100));
        expect(WindowsImmersiveFrame.interactionLocked.value, isFalse);
      });
    },
  );
}
