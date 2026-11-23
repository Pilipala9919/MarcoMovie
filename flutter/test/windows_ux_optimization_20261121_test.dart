import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:marco_movie/core/cast_avatar_service.dart';
import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/cms_parser.dart';
import 'package:marco_movie/core/live_catalog_parser.dart';
import 'package:marco_movie/core/local_media_proxy.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/core/ohos_runtime.dart';
import 'package:marco_movie/core/playback_startup.dart';
import 'package:marco_movie/core/windows_tray_service.dart';
import 'package:marco_movie/core/wogg_netdisk_adapter.dart';
import 'package:marco_movie/ui/adaptive_shell.dart';
import 'package:marco_movie/ui/cast_avatar_section.dart';
import 'package:marco_movie/ui/detail_screen.dart';
import 'package:marco_movie/ui/player/player_hud_prefs.dart';
import 'package:marco_movie/ui/player_screen.dart';
import 'package:marco_movie/ui/poster_image.dart';
import 'package:marco_movie/ui/windows_appearance.dart';
import 'package:marco_movie/ui/windows_title_bar.dart';
import 'package:media_kit/media_kit.dart';

import 'test_storage_helper.dart';

class _MultiVideoFixtureClient extends CmsClient {
  final List<CmsVideo> videos;
  final List<({String categoryId, CmsFilter? filter})> categoryRequests = [];

  static const List<CmsCategory> _categories = [
    CmsCategory(id: '1', name: '玩偶电影'),
    CmsCategory(id: '2', name: '玩偶剧集'),
    CmsCategory(id: '3', name: '玩偶动漫'),
  ];

  _MultiVideoFixtureClient(this.videos);

  @override
  Future<(List<CmsCategory>, CmsListing)> fetchHome(CmsSite site) async => (
        _categories,
        CmsListing(videos: videos),
      );

  @override
  Future<CmsListing> fetchCategory(
    CmsSite site,
    String categoryId,
    int page, {
    List<String> childIds = const [],
    CmsFilter? filter,
  }) async {
    categoryRequests.add((categoryId: categoryId, filter: filter));
    final area = filter?.area.trim() ?? '';
    final genre = filter?.genreLabel.trim() ?? '';
    final filtered = videos.where((v) {
      if (area.isNotEmpty && v.area.isNotEmpty && !v.area.contains(area)) {
        return false;
      }
      if (genre.isNotEmpty && v.tag.isNotEmpty && !v.tag.contains(genre)) {
        return false;
      }
      return true;
    }).toList();
    return CmsListing(
      page: 1,
      pageCount: 1,
      videos: filtered,
      sourceFiltered: filter != null && filter.hasSubFilter,
    );
  }

  @override
  Future<(CmsSite, CmsVideo)> playableDetail(
    CmsSite source,
    CmsVideo item,
    Iterable<CmsSite> candidates,
  ) async =>
      (source, item);
}

class _OptFakeState extends Fake implements PlayerState {
  Playlist playlistValue = const Playlist([]);
  bool playingValue = true;
  bool completedValue = false;
  Duration positionValue = const Duration(minutes: 3);
  Duration durationValue = const Duration(minutes: 45);
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

class _OptFakeStream extends Fake implements PlayerStream {
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

class _OptFakePlayer extends Fake implements Player {
  final _OptFakeState _state = _OptFakeState();
  final _OptFakeStream _stream = _OptFakeStream();
  bool disposed = false;
  int pauseCalls = 0;

  @override
  PlatformPlayer? get platform => null;
  @override
  PlayerState get state => _state;
  @override
  PlayerStream get stream => _stream;

  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    if (playable is Media) _state.playlistValue = Playlist([playable]);
    _state.durationValue = const Duration(minutes: 45);
    _state.positionValue = const Duration(minutes: 3);
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
    pauseCalls++;
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
    _state.positionValue = duration;
    if (!disposed) _stream.positionCtrl.add(duration);
  }

  @override
  Future<void> setRate(double rate) async => _state.rateValue = rate;
  @override
  Future<void> setVolume(double volume) async {
    _state.volumeValue = volume;
    if (!disposed) _stream.volumeCtrl.add(volume);
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

Future<Uint8List> _makePng(int width, int height) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  // Draw patterned gradients so compressed PNG exceeds the 18KB HD threshold.
  final paint = Paint();
  for (var y = 0; y < height; y += 8) {
    paint.color = Color.fromARGB(
      255,
      (y * 7) % 255,
      (y * 13 + 40) % 255,
      (y * 19 + 80) % 255,
    );
    canvas.drawRect(
      Rect.fromLTWH(0, y.toDouble(), width.toDouble(), 8),
      paint,
    );
  }
  for (var x = 0; x < width; x += 11) {
    paint.color = Color.fromARGB(
      140,
      (x * 17) % 255,
      (x * 23) % 255,
      (x * 29) % 255,
    );
    canvas.drawLine(
      Offset(x.toDouble(), 0),
      Offset((width - x).toDouble(), height.toDouble()),
      paint..strokeWidth = 2,
    );
  }
  final pic = recorder.endRecording();
  final img = await pic.toImage(width, height);
  final data = await img.toByteData(format: ui.ImageByteFormat.png);
  img.dispose();
  pic.dispose();
  return data!.buffer.asUint8List();
}

Future<void> _maybeCapture(WidgetTester tester, String name) async {
  if (Platform.environment['MARCO_CAPTURE_DIR'] case final String outDir) {
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('opt-capture')),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await Directory(outDir).create(recursive: true);
      await File('$outDir/$name.png')
          .writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const windowChannel = MethodChannel('window_manager');
  const trayChannel = MethodChannel('marco_movie/windows_tray');

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
        .setMockMethodCallHandler(trayChannel, null);
  });

  group('Item 1: Quiet Cinema Studio Windows theme', () {
    test('defaults to restrained dark obsidian preset and keeps light/dark options',
        () {
      final a = WindowsAppearance(Directory.systemTemp);
      addTearDown(a.dispose);
      expect(a.presetId, 'obsidian');
      expect(a.dark, isTrue);
      expect(windowsBackdropPresets.map((p) => p.id),
          containsAll(['obsidian', 'slate', 'midnight', 'ink', 'paper', 'mist']));
      a.preview(preset: 'paper');
      expect(a.dark, isFalse);
    });

    testWidgets('WindowsTitleBar adapts icon color to light paper theme',
        (tester) async {
      final a = WindowsAppearance(Directory.systemTemp)..preview(preset: 'paper');
      addTearDown(a.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: WindowsAppearanceScope(
            controller: a,
            child: Scaffold(
              body: WindowsTitleBar(
                isMaximized: false,
                isFocused: true,
                onMinimize: () {},
                onToggleMaximize: () {},
                onClose: () {},
              ),
            ),
          ),
        ),
      );
      final minIcon = tester.widget<Icon>(
        find.descendant(
          of: find.byKey(const ValueKey('win-titlebar-minimize')),
          matching: find.byType(Icon),
        ),
      );
      // Dark ink on light theme (not washed-out white).
      expect(minIcon.color!.computeLuminance(), lessThan(0.15));
    });
  });

  group('Items 2, 3, 4, 5: Refactored Windows Player HUD', () {
    Future<void> mountHudPlayer(
      WidgetTester tester, {
      required Size size,
      required _OptFakePlayer player,
    }) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = size;
      await tester.binding.setSurfaceSize(size);
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
        key: 'win_hud_site',
        name: '桌面源',
        type: 1,
        api: 'https://owned.invalid/api',
        isPrivate: true,
      );
      const video = CmsVideo(
        id: 'win_hud_vid',
        title: '兰香如故 (臻彩)',
        lines: [
          CmsLine(
            name: '百度网盘 3',
            episodes: [
              CmsEpisode(name: 'S01E01.mkv', url: 'file:///tmp/e1.mkv'),
              CmsEpisode(name: 'S01E02.mkv', url: 'file:///tmp/e2.mkv'),
            ],
          ),
          CmsLine(
            name: '夸克 4K',
            episodes: [
              CmsEpisode(name: 'S01E01.mkv', url: 'file:///tmp/e1b.mkv'),
            ],
          ),
        ],
      );

      await tester.pumpWidget(
        MaterialApp(
          builder: (_, child) => WindowsAppearanceScope(
            controller: appearance,
            child: RepaintBoundary(
              key: const ValueKey('opt-capture'),
              child: child!,
            ),
          ),
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
      await tester.pump(const Duration(milliseconds: 220));
    }

    testWidgets(
      'full-width progress bar, midline far-left lock, center play/seek, and zero-duplicate PC More popover',
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
      (tester) async {
        const size = Size(1280, 720);
        final player = _OptFakePlayer();
        await mountHudPlayer(tester, size: size, player: player);

        // Item 2: Progress bar spans full desktop width (>= 85% of viewport).
        final progressRect =
            tester.getRect(find.byKey(const Key('player-progress-bar')));
        expect(progressRect.width, greaterThan(size.width * 0.85));
        expect(progressRect.bottom, greaterThan(size.height * 0.78));

        // Item 3: Lock button sits on far left of horizontal midline.
        final lockRect =
            tester.getRect(find.byKey(const Key('player-lock-button')));
        expect(lockRect.left, lessThanOrEqualTo(36.0));
        expect((lockRect.center.dy - size.height / 2).abs(),
            lessThanOrEqualTo(16.0));

        // Item 4: Play/pause + rewind/forward sit centered in the video canvas.
        final playRect =
            tester.getRect(find.byKey(const Key('player-center-play-pause')));
        final rwRect =
            tester.getRect(find.byKey(const Key('player-center-rewind')));
        final ffRect =
            tester.getRect(find.byKey(const Key('player-center-forward')));
        expect((playRect.center.dx - size.width / 2).abs(),
            lessThanOrEqualTo(8.0));
        expect((playRect.center.dy - size.height / 2).abs(),
            lessThanOrEqualTo(16.0));
        expect(rwRect.center.dx, lessThan(playRect.center.dx));
        expect(ffRect.center.dx, greaterThan(playRect.center.dx));

        await _maybeCapture(tester, 'player-hud-1280');
        // Item 5: "More" opens a PC-native popover without horizontal touch dock
        // and without duplicating buttons already shown on the main toolbar.
        await tester.tap(find.byKey(const Key('desktop-more-button')));
        await tester.pump(const Duration(milliseconds: 100));
        await _maybeCapture(tester, 'player-hud-more-1280');
        final popover = find.byKey(const Key('desktop-more-menu-popover'));
        expect(popover, findsOneWidget);
        expect(find.byKey(const Key('player-tool-dock-portrait')), findsNothing);
        // Primary controls visible at 1280px are NOT duplicated inside popover.
        expect(
          find.descendant(of: popover, matching: find.text('播放倍速')),
          findsNothing,
        );
        expect(
          find.descendant(of: popover, matching: find.text('字幕选择')),
          findsNothing,
        );
        expect(
          find.descendant(of: popover, matching: find.text('定时关闭')),
          findsNothing,
        );
        // PC-native secondary controls are present and directly clickable.
        expect(
          find.descendant(of: popover, matching: find.text('画面比例')),
          findsOneWidget,
        );
        expect(
          find.descendant(of: popover, matching: find.text('裁切')),
          findsOneWidget,
        );
        await tester.tap(find.descendant(of: popover, matching: find.text('裁切')));
        await tester.pump(const Duration(milliseconds: 50));
        // Escape closes the popover without leaving the player.
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pump(const Duration(milliseconds: 60));
        expect(popover, findsNothing);
        expect(find.byType(PlayerScreen), findsOneWidget);

        // Locking places unlock button at the same midline far-left spot.
        await tester.tap(find.byKey(const Key('player-lock-button')));
        await tester.pump(const Duration(milliseconds: 100));
        final unlockRect =
            tester.getRect(find.byKey(const Key('player-unlock-button')));
        expect(unlockRect.left, lessThanOrEqualTo(36.0));
        expect((unlockRect.center.dy - size.height / 2).abs(),
            lessThanOrEqualTo(16.0));

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 100));
      },
    );
  });

  group('Items 7 & 8: Centered top nav, equal-height hero/history & multi-card scaling',
      () {
    final eightVideos = [
      for (var i = 1; i <= 8; i++)
        CmsVideo(
          id: 'v$i',
          title: '精选剧集 $i',
          year: '2026',
          remarks: '更新至第${i * 4}集',
        ),
    ];

    Future<void> mountHome(WidgetTester tester, Size size) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = size;
      await tester.binding.setSurfaceSize(size);
      addTearDown(() async {
        await tester.binding.setSurfaceSize(null);
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final storage = await initTestStorage();
      await tester.runAsync(() => storage.saveConfig(jsonEncode({
            'sites': [
              {
                'key': 'owned',
                'name': '玩偶哥哥 | 4K弹幕',
                'type': 1,
                'api': 'https://owned.invalid/api'
              }
            ]
          })));
      await tester.runAsync(() => storage.upsertWatchHistory(
            const WatchHistoryEntry(
              site: 'owned',
              id: 'h1',
              title: '兰香如故 (臻彩)',
              poster: '',
              line: '百度网盘 3',
              episode: 'S01E01.mkv',
              index: 0,
              position: 60000,
              duration: 1800000,
              updated: 1,
            ),
            triggerSync: false,
          ));
      final appearance = WindowsAppearance(Directory.systemTemp);
      addTearDown(appearance.dispose);
      await tester.pumpWidget(
        MaterialApp(
          builder: (_, child) => WindowsAppearanceScope(
            controller: appearance,
            child: RepaintBoundary(
              key: const ValueKey('opt-capture'),
              child: child!,
            ),
          ),
          home: AdaptiveShell(
            storage: storage,
            client: _MultiVideoFixtureClient(eightVideos),
            onSetPreventCloseForTest: (_) async {},
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    for (final width in [720.0, 1024.0, 1280.0, 1680.0, 2100.0]) {
      testWidgets(
        'top nav pill is adaptively centered at width $width',
        variant: TargetPlatformVariant.only(TargetPlatform.windows),
        (tester) async {
          await mountHome(tester, Size(width, 820));
          final pillRect =
              tester.getRect(find.byKey(const ValueKey('windows-top-nav-pill')));
          expect((pillRect.center.dx - width / 2).abs(), lessThanOrEqualTo(1.5));
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
        },
      );
    }

    testWidgets(
      'hero recommendations match history height and scale card count as window widens',
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
      (tester) async {
        // 1280px -> 2 hero cards side by side + equal-height history panel.
        await mountHome(tester, const Size(1280, 820));
        final card0At1280 =
            tester.getRect(find.byKey(const ValueKey('windows-hero-card-0')));
        final histAt1280 = tester.getRect(
          find.byKey(const ValueKey('windows-continue-watching-card')),
        );
        expect(card0At1280.height, closeTo(histAt1280.height, 0.5));
        expect(card0At1280.top, closeTo(histAt1280.top, 0.5));
        expect(card0At1280.bottom, closeTo(histAt1280.bottom, 0.5));
        expect(find.byKey(const ValueKey('windows-hero-card-1')), findsOneWidget);
        expect(find.byKey(const ValueKey('windows-hero-card-2')), findsNothing);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();

        // 1680px -> 3 hero cards side by side + equal-height history panel.
        await mountHome(tester, const Size(1680, 900));
        final card0At1680 =
            tester.getRect(find.byKey(const ValueKey('windows-hero-card-0')));
        final histAt1680 = tester.getRect(
          find.byKey(const ValueKey('windows-continue-watching-card')),
        );
        expect(card0At1680.height, closeTo(histAt1680.height, 0.5));
        expect(find.byKey(const ValueKey('windows-hero-card-2')), findsOneWidget);
        expect(find.byKey(const ValueKey('windows-hero-card-3')), findsNothing);
        await _maybeCapture(tester, 'home-wide-1680');
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();

        // 2100px -> 4 hero cards side by side instead of stretching 1 card.
        await mountHome(tester, const Size(2100, 960));
        expect(find.byKey(const ValueKey('windows-hero-card-3')), findsOneWidget);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      },
    );

    testWidgets('PosterLoader.isLandscapeHdPoster validates horizontal HD dimensions',
        (tester) async {
      await tester.runAsync(() async {
        final landscape16x9 = await _makePng(960, 540);
        final landscape4x3 = await _makePng(800, 600);
        final portrait = await _makePng(600, 900);
        final tiny = await _makePng(320, 180);

        expect(await PosterLoader.isLandscapeHdPoster(landscape16x9), isTrue);
        expect(await PosterLoader.isLandscapeHdPoster(landscape4x3), isTrue);
        expect(await PosterLoader.isLandscapeHdPoster(portrait), isFalse);
        expect(await PosterLoader.isLandscapeHdPoster(tiny), isFalse);
      });
    });
  });

  group('Item 9: Fast close & close-to-tray setting', () {
    test('StorageService persists windowsCloseAction and includes it in backups',
        () async {
      final storage = await initTestStorage();
      expect(storage.windowsCloseAction, 'exit');
      await storage.setWindowsCloseAction('tray');
      expect(storage.windowsCloseAction, 'tray');
      final backup = storage.exportBackupJson();
      await storage.setWindowsCloseAction('exit');
      expect(storage.windowsCloseAction, 'exit');
      await storage.importBackupJson(backup);
      expect(storage.windowsCloseAction, 'tray');
    });

    test('direct close hides window immediately before parallel teardown',
        () async {
      final order = <String>[];
      final sw = Stopwatch()..start();
      await AdaptiveShell.runWindowCloseSequence(
        setPreventClose: (prevent) async => order.add('prevent:$prevent'),
        hideWindow: () async => order.add('hideWindow'),
        flushHistory: () async => order.add('flushHistory'),
        flushSync: (_) => Completer<void>().future,
        closeHost: () => Completer<void>().future,
        closeScripts: () => Completer<void>().future,
        destroyWindow: () async => order.add('destroy'),
      );
      sw.stop();
      expect(order, [
        'prevent:true',
        'hideWindow',
        'flushHistory',
        'prevent:false',
        'destroy',
      ]);
      // Parallel bounded cleanup finishes well below 1.6s instead of hanging ~4s.
      expect(sw.elapsedMilliseconds, lessThan(1600));
    });

    testWidgets(
      'Windows settings toggles tray vs exit and hideToTray pauses playback',
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
      (tester) async {
        tester.view.devicePixelRatio = 1.0;
        tester.view.physicalSize = const Size(1280, 800);
        await tester.binding.setSurfaceSize(const Size(1280, 800));
        addTearDown(() async {
          await tester.binding.setSurfaceSize(null);
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        final trayCalls = <String>[];
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(trayChannel, (call) async {
          trayCalls.add(call.method);
          if (call.method == 'hideToTray') return true;
          return true;
        });

        final storage = await initTestStorage();
        await tester.runAsync(() => storage.saveConfig(jsonEncode({
              'sites': [
                {
                  'key': 'owned',
                  'name': '测试源',
                  'type': 1,
                  'api': 'https://owned.invalid/api'
                }
              ]
            })));
        final appearance = WindowsAppearance(Directory.systemTemp);
        addTearDown(appearance.dispose);
        await tester.pumpWidget(
          MaterialApp(
            builder: (_, child) =>
                WindowsAppearanceScope(controller: appearance, child: child!),
            home: AdaptiveShell(
              storage: storage,
              client: _MultiVideoFixtureClient(const []),
              onSetPreventCloseForTest: (_) async {},
            ),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.byTooltip('设置'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(WinButton, '更多设置'));
        await tester.pumpAndSettle();

        expect(find.byKey(const ValueKey('windows-close-action-tray')),
            findsOneWidget);
        expect(find.byKey(const ValueKey('windows-close-action-exit')),
            findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('windows-close-action-tray')));
        await tester.pumpAndSettle();
        expect(storage.windowsCloseAction, 'tray');

        final revBefore = WindowsTrayService.hideToTrayRevision.value;
        final ok = await WindowsTrayService.hideToTray();
        expect(ok, isTrue);
        expect(trayCalls, contains('hideToTray'));
        expect(WindowsTrayService.hideToTrayRevision.value, revBefore + 1);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      },
    );
  });

  group('Follow-up fixes 1–5: Immersive Detail + Cast Avatars + Filter + Live', () {
    testWidgets(
      'Follow-up 1 & 2: Full-bleed big-screen immersive detail poster and circular cast avatars',
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
      (tester) async {
        const size = Size(1280, 800);
        tester.view.devicePixelRatio = 1.0;
        tester.view.physicalSize = size;
        await tester.binding.setSurfaceSize(size);
        addTearDown(() async {
          CastAvatarService.debugClearCache();
          await tester.binding.setSurfaceSize(null);
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        CastAvatarService.debugSeedCache('宝珠', const [
          CastMember(name: '代露娃', role: '饰 金宝珠'),
          CastMember(name: '陈仕萌', role: '饰 谢景'),
          CastMember(name: '何洛洛', role: '主演'),
          CastMember(name: '柯颖', role: '主演'),
        ]);

        final storage = await initTestStorage();
        final appearance = WindowsAppearance(Directory.systemTemp);
        addTearDown(appearance.dispose);
        // Even under light theme, detail page must use full-bleed dark cinema backdrop.
        await appearance.selectPreset('paper');

        const site = CmsSite(
          key: 'wogg',
          name: '玩偶哥哥 | 4K弹幕',
          type: 1,
          api: 'https://owned.invalid/api',
        );
        const video = CmsVideo(
          id: 'baozhu',
          title: '宝珠',
          year: '2026',
          area: '中国大陆',
          remarks: '更新至第8集',
          actor: '/代露娃/陈仕萌/何洛洛/柯颖/',
          description: '屠户之女金宝珠是个俗人，贪财好色，锱铢必较，毕生梦想不过容全暴富。',
          lines: [
            CmsLine(
              name: '夸克网盘 1',
              episodes: [
                CmsEpisode(name: '4K 第1集', url: 'https://owned.invalid/e1.mp4'),
                CmsEpisode(name: '4K 第2集', url: 'https://owned.invalid/e2.mp4'),
              ],
            ),
          ],
        );

        await tester.pumpWidget(
          MaterialApp(
            builder: (_, child) => WindowsAppearanceScope(
              controller: appearance,
              child: RepaintBoundary(
                key: const ValueKey('opt-capture'),
                child: child!,
              ),
            ),
            home: DetailScreen(
              site: site,
              initialVideo: video,
              storage: storage,
              client: _MultiVideoFixtureClient(const [video]),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Full-bleed edge-to-edge big-screen hero poster
        final posterRect =
            tester.getRect(find.byKey(const ValueKey('windows-detail-poster')));
        expect(posterRect.left, closeTo(0.0, 0.5));
        expect(posterRect.top, closeTo(0.0, 0.5));
        expect(posterRect.width, closeTo(size.width, 0.5));
        expect(posterRect.height, greaterThanOrEqualTo(size.height * 0.5));

        // Cast avatar section is visible with individual avatar items (no raw slash string)
        expect(find.byKey(const Key('cast-avatar-section')), findsOneWidget);
        expect(find.byKey(const Key('cast-avatar-item-代露娃')), findsOneWidget);
        expect(find.byKey(const Key('cast-avatar-item-陈仕萌')), findsOneWidget);
        expect(find.textContaining('演员 · /代露娃/'), findsNothing);

        await _maybeCapture(tester, 'detail-immersive-1280');
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      },
    );

    testWidgets(
      'Follow-up 3 & 4: Windows Discover filter panel rows align identically on the left and apply filters',
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
      (tester) async {
        const size = Size(1280, 820);
        tester.view.devicePixelRatio = 1.0;
        tester.view.physicalSize = size;
        await tester.binding.setSurfaceSize(size);
        addTearDown(() async {
          await tester.binding.setSurfaceSize(null);
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        final client = _MultiVideoFixtureClient(const [
          CmsVideo(id: 'hk1', title: '无间道', area: '香港', tag: '犯罪', year: '2026'),
          CmsVideo(id: 'cn1', title: '宝珠', area: '大陆', tag: '古装', year: '2026'),
        ]);
        final storage = await initTestStorage();
        await tester.runAsync(() => storage.saveConfig(jsonEncode({
              'sites': [
                {
                  'key': 'owned',
                  'name': '玩偶 | 4K',
                  'type': 1,
                  'api': 'https://owned.invalid/api'
                }
              ]
            })));
        final appearance = WindowsAppearance(Directory.systemTemp);
        addTearDown(appearance.dispose);

        await tester.pumpWidget(
          MaterialApp(
            builder: (_, child) => WindowsAppearanceScope(
              controller: appearance,
              child: RepaintBoundary(
                key: const ValueKey('opt-capture'),
                child: child!,
              ),
            ),
            home: AdaptiveShell(
              storage: storage,
              client: client,
              onSetPreventCloseForTest: (_) async {},
            ),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text('发现'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('筛选'));
        await tester.pumpAndSettle();

        expect(find.byKey(const ValueKey('windows-filter-panel')), findsOneWidget);

        // First chip in every dimension row (分类 / 类型 / 地区 / 年份) MUST share exact left X!
        double firstChipLeft(String rowKey) {
          final row = find.byKey(ValueKey(rowKey));
          final firstChip =
              find.descendant(of: row, matching: find.byType(InkWell)).first;
          return tester.getRect(firstChip).left;
        }

        final catLeft = firstChipLeft('windows-filter-row-category');
        final genreLeft = firstChipLeft('windows-filter-row-genre');
        final areaLeft = firstChipLeft('windows-filter-row-area');
        final yearLeft = firstChipLeft('windows-filter-row-year');
        expect((catLeft - genreLeft).abs(), lessThanOrEqualTo(1.0));
        expect((genreLeft - areaLeft).abs(), lessThanOrEqualTo(1.0));
        expect((areaLeft - yearLeft).abs(), lessThanOrEqualTo(1.0));

        // Tap 地区 -> 香港 while still on 全部 tab: MUST invoke fetchCategory with area='香港'
        // and actually filter the grid to show only 无间道!
        client.categoryRequests.clear();
        await tester.tap(
          find.descendant(
            of: find.byKey(const ValueKey('windows-filter-row-area')),
            matching: find.text('香港'),
          ),
        );
        await tester.pumpAndSettle();

        await _maybeCapture(tester, 'discover-filter-1280');

        expect(client.categoryRequests, isNotEmpty);
        expect(client.categoryRequests.last.filter?.area, '香港');
        expect(find.text('无间道'), findsOneWidget);
        expect(find.text('宝珠'), findsNothing);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      },
    );

    test('Follow-up 4b: WoggNetdiskAdapter forwards server filter routes and falls back across area spelling',
        () async {
      final requestedUrls = <String>[];
      final site = CmsSite(
        key: 'wobg',
        name: '玩偶|4K',
        type: 3,
        api: 'csp_wobg',
        ext: jsonEncode({'siteUrl': 'https://wobg.example'}),
      );
      final adapter = WoggNetdiskAdapter(site, (url, {headers = const {}, requestTimeout}) async {
        requestedUrls.add(url);
        // Simulate site matching short form `大陆` on second route when `中国大陆` returns empty.
        if (url.contains(Uri.encodeComponent('中国大陆'))) {
          return '<div class="module-items"></div>';
        }
        return '''
          <div class="module-item">
            <div class="module-item-pic">
              <a href="/voddetail/99.html" title="大明王朝">
                <img data-src="https://img.example/99.jpg" />
              </a>
            </div>
            <div class="module-item-text">更新至第46集</div>
          </div>
        ''';
      });

      final listing = await adapter.category(
        '2',
        1,
        filter: const CmsFilter(area: '大陆', year: '2026'),
      );
      expect(listing.sourceFiltered, isTrue);
      expect(listing.videos, hasLength(1));
      expect(listing.videos.single.title, '大明王朝');
      expect(
        requestedUrls.any((u) => u.contains('/vodshow/2-${Uri.encodeComponent('中国大陆')}--')),
        isTrue,
      );
      expect(
        requestedUrls.any((u) => u.contains('/vodshow/2-${Uri.encodeComponent('大陆')}--')),
        isTrue,
      );
    });

    testWidgets(
      'Follow-up 5: PlaybackStartup honors shorter live timeoutOverride without breaking VOD default',
      (tester) async {
        final startup = PlaybackStartup();
        var timedOut = false;
        startup.waitForProgress(
          () => timedOut = true,
          timeoutOverride: const Duration(seconds: 12),
        );
        await tester.pump(const Duration(seconds: 11));
        expect(timedOut, isFalse);
        await tester.pump(const Duration(seconds: 1));
        expect(timedOut, isTrue);
      },
    );

    testWidgets(
      'Round 3 #1, #2, #4, #5: Search poster/list toggle, non-overlapping player loading pill, and lowered detail title',
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
      (tester) async {
        // 1. Verify Search layout toggle (grid <-> list) + adaptive columns
        const size = Size(1280, 820);
        tester.view.devicePixelRatio = 1.0;
        tester.view.physicalSize = size;
        await tester.binding.setSurfaceSize(size);
        addTearDown(() async {
          await tester.binding.setSurfaceSize(null);
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        final videos = [
          for (var i = 1; i <= 6; i++)
            CmsVideo(
              id: 's$i',
              title: '斗罗大陆2 第$i部',
              year: '2026',
              remarks: '更新至第${i * 10}集',
            ),
        ];
        final client = _SearchFixtureClient(videos);
        final storage = await initTestStorage();
        await tester.runAsync(() => storage.saveConfig(jsonEncode({
              'sites': [
                {
                  'key': 'owned',
                  'name': '虎斑 | 4K',
                  'type': 1,
                  'api': 'https://owned.invalid/api'
                }
              ]
            })));
        final appearance = WindowsAppearance(Directory.systemTemp);
        addTearDown(appearance.dispose);

        await tester.pumpWidget(
          MaterialApp(
            builder: (_, child) => WindowsAppearanceScope(
              controller: appearance,
              child: RepaintBoundary(
                key: const ValueKey('opt-capture'),
                child: child!,
              ),
            ),
            home: AdaptiveShell(
              storage: storage,
              client: client,
              onSetPreventCloseForTest: (_) async {},
            ),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.byTooltip('搜索影片 · Ctrl+K'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('windows-search-input')),
          '斗罗大陆2',
        );
        await tester.testTextInput.receiveAction(TextInputAction.search);
        await tester.pumpAndSettle();

        // Default is poster cover grid
        expect(storage.windowsSearchLayout, 'grid');
        expect(find.byKey(const ValueKey('windows-search-grid-view')),
            findsOneWidget);
        await _maybeCapture(tester, 'search-grid-1280');

        // Switch to list layout
        await tester.tap(find.byKey(const ValueKey('win-search-view-list')));
        await tester.pumpAndSettle();
        expect(storage.windowsSearchLayout, 'list');
        expect(find.byKey(const ValueKey('windows-search-list-view')),
            findsOneWidget);
        await _maybeCapture(tester, 'search-list-1280');

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();

        // 2. Verify Player loading/buffering capsule does NOT overlap center Play/Pause button
        final player = _OptFakePlayer();
        final hudPrefs = PlayerHudPrefs.inMemory(isDesktop: true);
        addTearDown(hudPrefs.dispose);
        await tester.pumpWidget(
          MaterialApp(
            builder: (_, child) => WindowsAppearanceScope(
              controller: appearance,
              child: RepaintBoundary(
                key: const ValueKey('opt-capture'),
                child: child!,
              ),
            ),
            home: PlayerScreen(
              site: const CmsSite(
                key: 'win_buf_site',
                name: '桌面源',
                type: 1,
                api: 'https://owned.invalid/api',
                isPrivate: true,
              ),
              video: const CmsVideo(
                id: 'buf_vid',
                title: '斗罗大陆2：绝世唐门2023',
                lines: [
                  CmsLine(
                    name: '百度网盘 2',
                    episodes: [
                      CmsEpisode(name: '180 4K.mp4', url: 'file:///tmp/180.mp4'),
                    ],
                  ),
                ],
              ),
              initialLineIndex: 0,
              initialEpisodeIndex: 0,
              storage: storage,
              debugPlayer: player,
              debugVideoSurface: const ColoredBox(color: Colors.black),
              debugHudPrefs: hudPrefs,
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 220));
        // Emit buffering = true while HUD controls are visible
        player._state.bufferingValue = true;
        player._stream.bufferingCtrl.add(true);
        await tester.pump(const Duration(milliseconds: 80));

        final playRect =
            tester.getRect(find.byKey(const Key('player-center-play-pause')));
        final loadingRect =
            tester.getRect(find.byKey(const Key('player-loading-indicator')));
        expect(loadingRect.top, greaterThan(playRect.bottom));
        expect(playRect.overlaps(loadingRect), isFalse);
        await _maybeCapture(tester, 'player-buffering-1280');

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 100));
      },
    );
  });

  group('Round 4: Live HTTP diagnostics, Bing exact landscape matcher, dual-mode hero & borderless detail',
      () {
    test('LiveCatalogParser parses inline #EXTINF http-user-agent / http-referer / #KODIPROP headers',
        () {
      const m3u = '''
#EXTM3U
#EXTINF:-1 tvg-id="CCTV1" http-user-agent="AptvPlayer-UA" group-title="央视IPV4",CCTV1
http://iptv.test/live.php?id=CCTV1
#EXTINF:-1 tvg-id="CCTV5" http-user-agent="iPhone" http-referer="https://aptv.test/" group-title="央视IPV4",CCTV5
http://iptv.test/live.php?id=CCTV5
#EXTINF:-1 tvg-id="Hunan" http-user-agent="BaseUA" group-title="卫视IPV4",湖南卫视
#EXTVLCOPT:http-user-agent=OverrideUA
#KODIPROP:inputstream.adaptive.stream_headers=Origin=https://origin.test
http://iptv.test/live.php?id=hunan
''';
      final groups = LiveCatalogParser.parse(
        m3u,
        origin: 'https://playlist.test/iptv.m3u',
        resolve: CmsParser.resolveUrl,
      );
      expect(groups.length, 2);
      final cctv1 = groups[0].channels.firstWhere((c) => c.name == 'CCTV1');
      final cctv5 = groups[0].channels.firstWhere((c) => c.name == 'CCTV5');
      final hunan = groups[1].channels.firstWhere((c) => c.name == '湖南卫视');

      expect(cctv1.episodes.first.headers['User-Agent'], 'AptvPlayer-UA');
      expect(cctv5.episodes.first.headers['User-Agent'], 'iPhone');
      expect(cctv5.episodes.first.headers['Referer'], 'https://aptv.test/');
      expect(hunan.episodes.first.headers['User-Agent'], 'OverrideUA');
      expect(hunan.episodes.first.headers['Origin'], 'https://origin.test');
    });

    test('LocalMediaLease records upstream HTTP 404/502 and PlayerScreen formats actionable messages',
        () async {
      final lease = await LocalMediaLease.open(
        target: Uri.parse('https://iptv-dead.test/live.php?id=CCTV1'),
        headers: const {'User-Agent': 'okhttp/4.12.0'},
        isLive: true,
        isCancelled: () => false,
        client: MockClient((request) async {
          return http.Response('Not Found', 404);
        }),
      );
      addTearDown(lease.close);

      final prevOverrides = HttpOverrides.current;
      HttpOverrides.global = null;
      late int respCode;
      try {
        final client = HttpClient();
        try {
          final req = await client.getUrl(lease.url);
          final resp = await req.close();
          await resp.drain<void>();
          respCode = resp.statusCode;
        } finally {
          client.close(force: true);
        }
      } finally {
        HttpOverrides.global = prevOverrides;
      }

      expect(respCode, 404);
      expect(lease.lastUpstreamStatusCode, 404);
      expect(lease.lastUpstreamHost, 'iptv-dead.test');

      expect(
        PlayerScreen.formatLivePlaybackError(
          'Failed to open',
          upstreamStatusCode: lease.lastUpstreamStatusCode,
        ),
        contains('HTTP 404'),
      );
      expect(
        PlayerScreen.formatLivePlaybackError(
          'Failed to open',
          upstreamStatusCode: 403,
        ),
        contains('HTTP 403'),
      );
      expect(
        PlayerScreen.formatLivePlaybackError(
          'Failed to open',
          upstreamStatusCode: 502,
        ),
        contains('HTTP 502'),
      );
      expect(
        PlayerScreen.formatLivePlaybackError(TimeoutException('timeout')),
        contains('超时'),
      );
    });

    test('PosterLoader.matchesBingLandscapeCaption enforces exact title & rejects templates/wrong shows',
        () {
      expect(
        PosterLoader.matchesBingLandscapeCaption(
          '国漫《光阴之外》12月28日优酷独播，许青率末世群英斩荆举剑',
          '光阴之外',
        ),
        isTrue,
      );
      expect(
        PosterLoader.matchesBingLandscapeCaption(
          '《宝珠》预约量突破10万，古装宅斗佳作引全民期待',
          '宝珠',
        ),
        isTrue,
      );
      expect(
        PosterLoader.matchesBingLandscapeCaption(
          '宝珠奇缘剧照663剧照-电视指南',
          '宝珠',
        ),
        isFalse,
      );
      expect(
        PosterLoader.matchesBingLandscapeCaption(
          '年货节海报_宝珠姐-站酷ZCOOL',
          '宝珠',
        ),
        isFalse,
      );
      expect(
        PosterLoader.matchesBingLandscapeCaption(
          '《甜甜的陷阱》首播，谢彬彬张淼怡主演',
          '欲望的陷阱',
        ),
        isFalse,
      );
      expect(
        PosterLoader.matchesBingLandscapeCaption(
          '马年创意海报素材-马年创意海报图片-设图网',
          '欲望的陷阱',
        ),
        isFalse,
      );
    });

    testWidgets(
      'Windows detail adapts portrait-only poster to ambient blur + right framed poster, uses full-bleed for landscape, and removes outer card borders',
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
      (tester) async {
        const size = Size(1280, 800);
        tester.view.devicePixelRatio = 1.0;
        tester.view.physicalSize = size;
        await tester.binding.setSurfaceSize(size);
        addTearDown(() async {
          await tester.binding.setSurfaceSize(null);
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        final portraitPng = await tester.runAsync(() => _makePng(480, 720));
        final landscapePng = await tester.runAsync(() => _makePng(1280, 720));
        PosterLoader.seedMemoryForTest(
          'https://poster.test/portrait-trap.jpg',
          portraitPng!,
          title: '欲望的陷阱测试',
          year: '2026',
          asHd: true,
        );
        PosterLoader.debugSeedLandscapeMemory(
          '光阴之外测试',
          landscapePng!,
          year: '2025',
        );

        final storage = await initTestStorage();
        final appearance = WindowsAppearance(Directory.systemTemp);
        addTearDown(appearance.dispose);
        const site = CmsSite(
          key: 'win_r4_site',
          name: '玩偶哥哥 | 4K弹幕',
          type: 1,
          api: 'https://owned.invalid/api',
          isPrivate: true,
        );

        // Case A: Portrait-only show -> ambient blur full-bleed + right framed vertical poster
        const portraitVideo = CmsVideo(
          id: 'r4_portrait',
          title: '欲望的陷阱测试',
          year: '2026',
          remarks: '更新至第62集',
          poster: 'https://poster.test/portrait-trap.jpg',
          actor: '张瑞希 / 全惠媛 / 崔正宇 / 周艺恩',
          description:
              '短简介预览。[展开全部] 本剧讲述被冤枉而失去生命的一名女性面对巨大的欲望，重新找回自己人生的复仇剧【玩偶哥哥】。',
          lines: [
            CmsLine(
              name: '夸克网盘 2',
              episodes: [
                CmsEpisode(name: '第01集', url: 'https://owned.invalid/e1.m3u8'),
                CmsEpisode(name: '第02集', url: 'https://owned.invalid/e2.m3u8'),
              ],
            ),
          ],
        );

        await tester.pumpWidget(
          MaterialApp(
            builder: (_, child) => WindowsAppearanceScope(
              controller: appearance,
              child: RepaintBoundary(
                key: const ValueKey('opt-capture'),
                child: child!,
              ),
            ),
            home: DetailScreen(
              site: site,
              initialVideo: portraitVideo,
              storage: storage,
              client: _MultiVideoFixtureClient([portraitVideo]),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final bgRect =
            tester.getRect(find.byKey(const ValueKey('windows-detail-poster')));
        expect(bgRect.left, closeTo(0, 1.0));
        expect(bgRect.width, closeTo(size.width, 1.0));

        // Framed vertical poster sits cleanly on the right without overlapping title
        final framedFinder =
            find.byKey(const ValueKey('windows-detail-framed-poster'));
        expect(framedFinder, findsOneWidget);
        final framedRect = tester.getRect(framedFinder);
        final titleRect = tester.getRect(find.text('欲望的陷阱测试'));
        expect(framedRect.width, lessThan(framedRect.height));
        expect(framedRect.left, greaterThan(titleRect.right));
        expect(framedRect.right, lessThanOrEqualTo(size.width - 36));

        // Synopsis cleaned of [展开全部] and 【玩偶哥哥】
        expect(find.textContaining('展开全部'), findsNothing);
        expect(find.textContaining('玩偶哥哥】'), findsNothing);

        // Controls bar & CastAvatarSection have NO enclosing card box borders
        expect(
          find.byKey(const ValueKey('windows-detail-controls-bar')),
          findsOneWidget,
        );
        final castWidget =
            tester.widget<CastAvatarSection>(find.byType(CastAvatarSection));
        expect(castWidget.containerDecoration, isNull);
        expect(castWidget.containerPadding, isNull);

        await _maybeCapture(tester, 'detail-portrait-ambient-1280');

        // Case B: True landscape HD still -> unobstructed full-bleed hero, no framed portrait card
        const publicSite = CmsSite(
          key: 'win_r4_public',
          name: '玩偶哥哥 | 4K弹幕',
          type: 1,
          api: 'https://owned.invalid/api',
        );
        const landscapeVideo = CmsVideo(
          id: 'r4_landscape',
          title: '光阴之外测试',
          year: '2025',
          remarks: '更新至第48集',
          poster: 'https://poster.test/portrait-trap.jpg',
          actor: '张瑞希 / 全惠媛 / 崔正宇',
          description: '天地是万物众生的客舍，光阴是古往今来的过客。',
          lines: [
            CmsLine(
              name: '夸克网盘 1',
              episodes: [
                CmsEpisode(name: '第01集', url: 'https://owned.invalid/l1.m3u8'),
              ],
            ),
          ],
        );

        await tester.pumpWidget(
          MaterialApp(
            builder: (_, child) => WindowsAppearanceScope(
              controller: appearance,
              child: RepaintBoundary(
                key: const ValueKey('opt-capture'),
                child: child!,
              ),
            ),
            home: DetailScreen(
              key: const ValueKey('detail-landscape-case'),
              site: publicSite,
              initialVideo: landscapeVideo,
              storage: storage,
              client: _MultiVideoFixtureClient([landscapeVideo]),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.byKey(const ValueKey('windows-detail-framed-poster')),
          findsNothing,
        );
        await _maybeCapture(tester, 'detail-landscape-borderless-1280');

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      },
    );
  });
}

class _SearchFixtureClient extends _MultiVideoFixtureClient {
  _SearchFixtureClient(super.videos);

  @override
  Stream<(CmsSite, List<CmsVideo>)> searchAcrossSites(
    List<CmsSite> sites,
    String keyword, {
    int maxConcurrency = CmsClient.defaultSearchConcurrency,
    void Function(CmsSite site, Object error)? onSourceError,
  }) async* {
    if (sites.isNotEmpty) {
      yield (sites.first, videos);
    }
  }
}
