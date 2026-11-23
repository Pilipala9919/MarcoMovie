import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/ui/desktop_player_window.dart';
import 'package:marco_movie/ui/player_screen.dart';
import 'package:marco_movie/ui/windows_appearance.dart';
import 'package:marco_movie/ui/windows_title_bar.dart';
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart';

import 'test_storage_helper.dart';

class _MinimalFakeState extends Fake implements PlayerState {
  @override
  Playlist get playlist => const Playlist([]);
  @override
  bool get playing => false;
  @override
  bool get completed => false;
  @override
  Duration get position => Duration.zero;
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

class _MinimalFakeStream extends Fake implements PlayerStream {
  final _width = StreamController<int?>.broadcast();
  final _height = StreamController<int?>.broadcast();
  final _track = StreamController<Track>.broadcast();
  final _tracks = StreamController<Tracks>.broadcast();
  final _position = StreamController<Duration>.broadcast();
  final _duration = StreamController<Duration>.broadcast();
  final _playing = StreamController<bool>.broadcast();
  final _buffering = StreamController<bool>.broadcast();
  final _completed = StreamController<bool>.broadcast();
  final _error = StreamController<String>.broadcast();
  final _volume = StreamController<double>.broadcast();

  @override
  Stream<int?> get width => _width.stream;
  @override
  Stream<int?> get height => _height.stream;
  @override
  Stream<Track> get track => _track.stream;
  @override
  Stream<Tracks> get tracks => _tracks.stream;
  @override
  Stream<Duration> get position => _position.stream;
  @override
  Stream<Duration> get duration => _duration.stream;
  @override
  Stream<bool> get playing => _playing.stream;
  @override
  Stream<bool> get buffering => _buffering.stream;
  @override
  Stream<bool> get completed => _completed.stream;
  @override
  Stream<String> get error => _error.stream;
  @override
  Stream<double> get volume => _volume.stream;

  Future<void> close() async {
    await Future.wait([
      _width.close(),
      _height.close(),
      _track.close(),
      _tracks.close(),
      _position.close(),
      _duration.close(),
      _playing.close(),
      _buffering.close(),
      _completed.close(),
      _error.close(),
      _volume.close(),
    ]);
  }
}

class _MinimalFakePlayer extends Fake implements Player {
  final _state = _MinimalFakeState();
  final _stream = _MinimalFakeStream();
  bool _disposed = false;

  @override
  PlatformPlayer? get platform => null;
  @override
  PlayerState get state => _state;
  @override
  PlayerStream get stream => _stream;
  @override
  Future<void> open(Playable playable, {bool play = true}) async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> play() async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> playOrPause() async {}
  @override
  Future<void> seek(Duration duration) async {}
  @override
  Future<void> setRate(double rate) async {}
  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<void> setAudioTrack(AudioTrack track) async {}
  @override
  Future<void> setSubtitleTrack(SubtitleTrack track) async {}
  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _stream.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('window_manager');
  final windowsOnly = TargetPlatformVariant.only(TargetPlatform.windows);

  void resetFrameNotifiers() {
    WindowsImmersiveFrame.fullScreen.value = false;
    WindowsImmersiveFrame.interactionLocked.value = false;
    WindowsImmersiveFrame.darkSurfaceDepth.value = 0;
  }

  testWidgets(
    'Windows maximized fullscreen exit restores title bar buttons even when window_manager omits leave-full-screen',
    variant: windowsOnly,
    (tester) async {
      resetFrameNotifiers();
      addTearDown(resetFrameNotifiers);

      var isFull = false;
      var isMax = true;
      final methods = <String>[];
      WindowListener? frameListener;

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        methods.add(call.method);
        switch (call.method) {
          case 'isFullScreen':
            return isFull;
          case 'isMaximized':
            return isMax;
          case 'setFullScreen':
            final target = call.arguments['isFullScreen'] as bool;
            isFull = target;
            // Reproduce window_manager 0.5.1 on a maximized Windows window:
            // enter-full-screen fires (SIZE_MAXIMIZED), but leave-full-screen
            // is NEVER emitted while the window stays zoomed.
            if (target) {
              frameListener?.onWindowEnterFullScreen();
            }
            return null;
          case 'unmaximize':
            isMax = false;
            return null;
          case 'maximize':
            isMax = true;
            return null;
          default:
            return null;
        }
      });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });

      double capturedTopPad = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: WindowsImmersiveFrame(
            child: Builder(
              builder: (context) {
                capturedTopPad = MediaQuery.paddingOf(context).top;
                return const Scaffold(body: SizedBox.expand());
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      frameListener =
          tester.state(find.byType(WindowsImmersiveFrame)) as WindowListener;

      expect(
        find.byKey(const ValueKey('windows-immersive-title-bar')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('win-titlebar-minimize')), findsOneWidget);
      expect(find.byKey(const ValueKey('win-titlebar-maximize')), findsOneWidget);
      expect(find.byKey(const ValueKey('win-titlebar-close')), findsOneWidget);
      expect(capturedTopPad, WindowsImmersiveFrame.titleBarHeight);

      final playerWindow = DesktopPlayerWindow(macOS: false, immersiveFrame: true);
      await playerWindow.initialize();

      // Enter fullscreen -> custom title bar hides and top inset becomes 0.
      await playerWindow.toggle();
      await tester.pumpAndSettle();
      expect(playerWindow.fullscreen, isTrue);
      expect(
        find.byKey(const ValueKey('windows-immersive-title-bar')),
        findsNothing,
      );
      expect(capturedTopPad, 0);

      // Exit fullscreen -> even without native leave-full-screen event,
      // maximized bounce runs and minimize/maximize/close buttons reappear.
      methods.clear();
      expect(await playerWindow.exitFullscreen(), isTrue);
      await tester.pumpAndSettle();

      expect(playerWindow.fullscreen, isFalse);
      expect(isMax, isTrue);
      final unmaxIdx = methods.indexOf('unmaximize');
      final maxIdx = methods.indexOf('maximize');
      final titleBarIdx = methods.lastIndexOf('setTitleBarStyle');
      expect(unmaxIdx, greaterThanOrEqualTo(0));
      expect(maxIdx, greaterThan(unmaxIdx));
      expect(titleBarIdx, greaterThan(maxIdx));

      expect(
        find.byKey(const ValueKey('windows-immersive-title-bar')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('win-titlebar-minimize')), findsOneWidget);
      expect(find.byKey(const ValueKey('win-titlebar-maximize')), findsOneWidget);
      expect(find.byKey(const ValueKey('win-titlebar-close')), findsOneWidget);
      expect(find.byTooltip('向下还原'), findsOneWidget);
      expect(capturedTopPad, WindowsImmersiveFrame.titleBarHeight);

      await playerWindow.close();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'Windows normal (non-maximized) fullscreen toggle hides and restores title bar without native events',
    variant: windowsOnly,
    (tester) async {
      resetFrameNotifiers();
      addTearDown(resetFrameNotifiers);

      var isFull = false;
      const isMax = false;
      final methods = <String>[];

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        methods.add(call.method);
        if (call.method == 'isFullScreen') return isFull;
        if (call.method == 'isMaximized') return isMax;
        if (call.method == 'setFullScreen') {
          isFull = call.arguments['isFullScreen'] as bool;
        }
        return null;
      });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });

      double capturedTopPad = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: WindowsImmersiveFrame(
            child: Builder(
              builder: (context) {
                capturedTopPad = MediaQuery.paddingOf(context).top;
                return const Scaffold(body: SizedBox.expand());
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final playerWindow = DesktopPlayerWindow(macOS: false, immersiveFrame: true);
      await playerWindow.initialize();

      // Enter fullscreen without native enter-full-screen callback.
      await playerWindow.toggle();
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('windows-immersive-title-bar')),
        findsNothing,
      );
      expect(capturedTopPad, 0);

      // Closing player directly from fullscreen restores the title bar cleanly.
      methods.clear();
      await playerWindow.close();
      await tester.pumpAndSettle();

      expect(methods, isNot(contains('unmaximize')));
      expect(methods, isNot(contains('maximize')));
      expect(
        find.byKey(const ValueKey('windows-immersive-title-bar')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('win-titlebar-minimize')), findsOneWidget);
      expect(find.byKey(const ValueKey('win-titlebar-maximize')), findsOneWidget);
      expect(find.byKey(const ValueKey('win-titlebar-close')), findsOneWidget);
      expect(capturedTopPad, WindowsImmersiveFrame.titleBarHeight);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'WindowsImmersiveFrame self-heals on resize if OS exits fullscreen without leave-full-screen',
    variant: windowsOnly,
    (tester) async {
      resetFrameNotifiers();
      addTearDown(resetFrameNotifiers);

      var isFull = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'isFullScreen') return isFull;
        if (call.method == 'isMaximized') return false;
        return null;
      });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });

      await tester.pumpWidget(
        const MaterialApp(
          home: WindowsImmersiveFrame(
            child: Scaffold(body: SizedBox.expand()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final listener =
          tester.state(find.byType(WindowsImmersiveFrame)) as WindowListener;
      isFull = true;
      listener.onWindowEnterFullScreen();
      await tester.pump();
      expect(
        find.byKey(const ValueKey('windows-immersive-title-bar')),
        findsNothing,
      );

      // OS exits fullscreen without firing onWindowLeaveFullScreen; next resize heals.
      isFull = false;
      listener.onWindowResize();
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('windows-immersive-title-bar')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('win-titlebar-close')), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'Windows PlayerScreen keeps caption icons bright over dark video even in light theme and restores on exit',
    variant: windowsOnly,
    (tester) async {
      resetFrameNotifiers();
      addTearDown(resetFrameNotifiers);

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'isFullScreen') return false;
        if (call.method == 'isMaximized') return false;
        return null;
      });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });

      final storage = await initTestStorage();
      final appearance = WindowsAppearance(Directory.systemTemp)
        ..preview(theme: 'light');
      addTearDown(appearance.dispose);
      final fakePlayer = _MinimalFakePlayer();
      addTearDown(fakePlayer.dispose);

      const site = CmsSite(
        key: 'owned',
        name: '测试源',
        type: 1,
        api: 'https://owned.invalid/api',
      );
      const video = CmsVideo(
        id: 'v1',
        title: '测试影片',
        lines: [
          CmsLine(
            name: '主线',
            episodes: [
              CmsEpisode(name: '第 1 集', url: 'https://owned.invalid/1.mp4'),
            ],
          ),
        ],
      );

      Color closeIconColor() {
        final closeBtn = find.byKey(const ValueKey('win-titlebar-close'));
        final icon = tester.widget<Icon>(
          find.descendant(of: closeBtn, matching: find.byType(Icon)),
        );
        return icon.color!;
      }

      await tester.pumpWidget(
        MaterialApp(
          builder: (_, child) => WindowsAppearanceScope(
            controller: appearance,
            child: WindowsImmersiveFrame(child: child!),
          ),
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () {
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => PlayerScreen(
                          site: site,
                          video: video,
                          initialLineIndex: 0,
                          initialEpisodeIndex: 0,
                          storage: storage,
                          debugPlayer: fakePlayer,
                          debugVideoSurface:
                              const ColoredBox(color: Colors.black),
                        ),
                      ),
                    );
                  },
                  child: const Text('打开播放'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Light shell -> dark caption icon.
      expect(WindowsImmersiveFrame.darkSurfaceDepth.value, 0);
      expect(closeIconColor(), const Color(0xD818212F));

      // Open full-bleed dark PlayerScreen -> caption icon switches to light white.
      await tester.tap(find.text('打开播放'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(WindowsImmersiveFrame.darkSurfaceDepth.value, 1);
      expect(closeIconColor(), const Color(0xD8FFFFFF));

      // Pop PlayerScreen -> caption icon returns to dark ink for light theme.
      Navigator.of(tester.element(find.byType(PlayerScreen))).pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      expect(WindowsImmersiveFrame.darkSurfaceDepth.value, 0);
      expect(closeIconColor(), const Color(0xD818212F));

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
}
