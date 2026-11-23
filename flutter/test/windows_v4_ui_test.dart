import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:marco_movie/ui/apple_theme.dart';
import 'package:marco_movie/core/windows_appearance_preferences.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/ui/adaptive_shell.dart';
import 'package:marco_movie/ui/detail_screen.dart';
import 'package:marco_movie/ui/windows_appearance.dart';
import 'package:marco_movie/ui/cloud_sync_panel.dart';
import 'package:marco_movie/ui/netdisk_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'test_storage_helper.dart';

const fixtureSite = CmsSite(
    key: 'owned', name: '测试片源', type: 1, api: 'https://owned.invalid/api');
const fixtureVideo = CmsVideo(
    id: 'one',
    title: '海边的光',
    year: '2026',
    remarks: '更新至 2 集',
    description: '海风与晨光，记录城市里平静的一天。',
    lines: [
      CmsLine(name: '主线路', episodes: [
        CmsEpisode(name: '第 1 集', url: 'https://owned.invalid/1.mp4'),
        CmsEpisode(name: '第 2 集', url: 'https://owned.invalid/2.mp4'),
      ]),
      CmsLine(name: '备用线路', episodes: [
        CmsEpisode(name: '第 1 集', url: 'https://owned.invalid/3.mp4'),
      ]),
    ]);

class WindowsFixtureClient extends CmsClient {
  final categoryRequests = <String>[];
  @override
  Future<List<LiveGroup>> fetchLiveGroups(LiveSource source) async => const [
        LiveGroup(name: '电影频道', channels: [
          LiveChannel(
              name: '经典电影',
              group: '电影频道',
              urls: ['https://owned.invalid/1.mp4'])
        ]),
        LiveGroup(name: '纪录频道', channels: [
          LiveChannel(
              name: '自然世界',
              group: '纪录频道',
              urls: ['https://owned.invalid/2.mp4'])
        ]),
      ];
  @override
  Future<(List<CmsCategory>, CmsListing)> fetchHome(CmsSite site) async => (
        const [
          CmsCategory(id: '1', name: '电影'),
          CmsCategory(id: '2', name: '电视剧')
        ],
        const CmsListing(
            videos: [fixtureVideo, CmsVideo(id: 'two', title: '山间来信')]),
      );
  @override
  Future<CmsListing> fetchCategory(CmsSite site, String id, int page,
      {List<String> childIds = const [], CmsFilter? filter}) async {
    categoryRequests.add(id);
    return const CmsListing(videos: [fixtureVideo], sourceFiltered: true);
  }

  @override
  Future<(CmsSite, CmsVideo)> playableDetail(
          CmsSite source, CmsVideo item, Iterable<CmsSite> candidates) async =>
      (source, fixtureVideo);
  @override
  Future<CmsListing> fetchSearch(CmsSite site, String keyword,
          {int page = 1}) async =>
      const CmsListing(videos: [fixtureVideo]);
}

Future<void> captureWindowsPage(WidgetTester tester, String name) async {
  if (Platform.environment['MARCO_CAPTURE_DIR'] case final String output) {
    final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const ValueKey('capture')));
    await tester.runAsync(() async {
      final image = await boundary.toImage();
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      await Directory(output).create(recursive: true);
      await File('$output/$name.png').writeAsBytes(data!.buffer.asUint8List());
      image.dispose();
    });
  }
}

class PrivacyFixtureClient extends WindowsFixtureClient {
  final pendingPublic = Completer<(List<CmsCategory>, CmsListing)>();
  var publicCalls = 0;
  @override
  Future<(List<CmsCategory>, CmsListing)> fetchHome(CmsSite site) async {
    if (site.isEffectivelyPrivate)
      return (
        const <CmsCategory>[],
        const CmsListing(videos: [CmsVideo(id: 'private', title: '仅隐私可见的影片')])
      );
    if (++publicCalls > 1) return pendingPublic.future;
    return super.fetchHome(site);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('appearance survives restart without touching existing app preferences',
      () async {
    SharedPreferences.setMockInitialValues({
      'selected_site_key': 'keep',
      'windows_v4_brightness': .83,
      'windows_v4_preset': 'sea'
    });
    final a = WindowsAppearance(Directory.systemTemp);
    await a.load();
    expect(a.presetId, 'sea');
    expect(a.brightness, .83);
    a.preview(theme: 'dark', softness: 18, alignment: 'top');
    await a.save();
    final restored = WindowsAppearance(Directory.systemTemp);
    await restored.load();
    expect(restored.dark, isTrue);
    expect(restored.blur, 18);
    expect(restored.position, 'top');
    expect(
        (await SharedPreferences.getInstance()).getString('selected_site_key'),
        'keep');
    a.dispose();
    restored.dispose();
  });

  test('invalid saved appearance and missing wallpaper fall back safely',
      () async {
    SharedPreferences.setMockInitialValues({
      'windows_v4_preset': 'missing',
      'windows_v4_mode': 7,
      'windows_v4_position': 'bad',
      'windows_v4_blur': 900,
      'windows_v4_brightness': 'bad',
      'windows_v4_image': 'Z:/not-present.png'
    });
    final a = WindowsAppearance(Directory.systemTemp);
    await a.load();
    expect(a.presetId, defaultWindowsPresetId);
    expect(a.mode, 'auto');
    expect(a.position, 'center');
    expect(a.blur, 40);
    expect(a.brightness, 1);
    expect(a.hasImage, isFalse);
    a.dispose();
  });

  test('loading preferences after disposal does not notify a dead widget',
      () async {
    SharedPreferences.setMockInitialValues({});
    final a = WindowsAppearance(Directory.systemTemp);
    final pending = a.load();
    a.dispose();
    await pending;
  });

  testWidgets(
      'wallpaper import copies the original, rejects invalid images and removes only its copy',
      (tester) async {
    await tester.runAsync(() async {
      SharedPreferences.setMockInitialValues({});
      final temp =
          await Directory.systemTemp.createTemp('marco-wallpaper-test-');
      final a = WindowsAppearance(temp);
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawRect(
          const Rect.fromLTWH(0, 0, 24, 24), Paint()..color = Colors.blue);
      final pic = recorder.endRecording();
      final img = await pic.toImage(24, 24);
      final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
      final original = File('${temp.path}/original.png');
      await original.writeAsBytes(bytes!.buffer.asUint8List());
      img.dispose();
      pic.dispose();
      await a.load();
      await a.importImage(original.path);
      final managed = a.imagePath;
      expect(managed, isNot(original.path));
      expect(await File(managed).exists(), isTrue);
      final invalid = File('${temp.path}/invalid.png');
      await invalid.writeAsString('bad image');
      await expectLater(a.importImage(invalid.path), throwsA(anything));
      expect(a.imagePath, managed);
      expect(a.importing, isFalse);
      final restored = WindowsAppearance(temp);
      await restored.load();
      expect(restored.imagePath, managed);
      restored.dispose();
      await a.selectPreset('midnight');
      expect(a.dark, isTrue);
      expect(await original.exists(), isTrue);
      expect(await File(managed).exists(), isTrue);
      await a.reset();
      expect(a.hasImage, isFalse);
      await a.useImportedImage();
      expect(a.imagePath, managed);
      await a.removeImage();
      expect(await original.exists(), isTrue);
      expect(await File(managed).exists(), isFalse);
      a.dispose();
      await temp.delete(recursive: true);
    });
  });

  test('Windows appearance backup validates and restores portable preferences',
      () async {
    final storage = await initTestStorage(initialPrefs: {
      'windows_v4_preset': 'sea',
      'windows_v4_mode': 'dark',
      'windows_v4_blur': 15.0,
      'windows_v4_brightness': .8,
      'windows_v4_image': 'C:/private/photo.png',
      'windows_v4_imported_image': 'C:/private/photo.png',
    });
    final backup = storage.exportBackupJson();
    expect(backup, isNot(contains('private/photo')));
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('windows_v4_preset', 'rose');
    await storage.importBackupJson(backup);
    expect(prefs.getString('windows_v4_preset'), 'sea');
    expect(prefs.getString('windows_v4_image'), '');
    expect(
        prefs.getString('windows_v4_imported_image'), 'C:/private/photo.png');
    expect(
        () =>
            WindowsAppearancePreferences.validate({'version': 1, 'blur': 900}),
        throwsFormatException);
    expect(() => WindowsAppearancePreferences.validate({'version': 8}),
        throwsFormatException);
  });

  testWidgets('reduced transparency changes panels immediately',
      (tester) async {
    final a = WindowsAppearance(Directory.systemTemp);
    final old = GlassworkBackdrop.reduceTransparency.value;
    try {
      GlassworkBackdrop.reduceTransparency.value = false;
      await tester.pumpWidget(MaterialApp(
          home: WindowsAppearanceScope(
              controller: a,
              child: const Scaffold(body: WinPanel(child: Text('Panel'))))));
      Color panelColor() => (tester
              .widgetList<Container>(find.byType(Container))
              .firstWhere((w) => w.decoration is BoxDecoration)
              .decoration as BoxDecoration)
          .color!;
      expect(panelColor().a, lessThan(1));
      GlassworkBackdrop.reduceTransparency.value = true;
      await tester.pump();
      expect(panelColor().a, 1);
      expect(tester.widget<BackdropFilter>(find.byType(BackdropFilter)).enabled,
          isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
    } finally {
      GlassworkBackdrop.reduceTransparency.value = old;
      a.dispose();
    }
  });

  testWidgets('dark panels retain readable text over bright photographs',
      (tester) async {
    final a = WindowsAppearance(Directory.systemTemp)..preview(theme: 'dark');
    final old = GlassworkBackdrop.reduceTransparency.value;
    try {
      GlassworkBackdrop.reduceTransparency.value = false;
      late Color primary;
      late Color secondary;
      await tester.pumpWidget(MaterialApp(
          home: WindowsAppearanceScope(
              controller: a,
              child: Builder(builder: (context) {
                primary = winInk(context);
                secondary = winMuted(context);
                return const Scaffold(body: WinPanel(child: Text('Panel')));
              }))));
      final color = (tester
              .widgetList<Container>(find.byType(Container))
              .firstWhere((w) => w.decoration is BoxDecoration)
              .decoration as BoxDecoration)
          .color!;
      for (final background in [Colors.white, Colors.black]) {
        final surface = Color.alphaBlend(color, background);
        for (final text in [primary, secondary]) {
          final rendered = Color.alphaBlend(text, surface);
          final ratio = (rendered.computeLuminance() + .05) /
              (surface.computeLuminance() + .05);
          expect(ratio, greaterThanOrEqualTo(4.5));
        }
      }
      await tester.pumpWidget(const SizedBox.shrink());
    } finally {
      GlassworkBackdrop.reduceTransparency.value = old;
      a.dispose();
    }
  });

  for (final size in [const Size(720, 520), const Size(1280, 800)]) {
    testWidgets('Windows navigation and all settings fit $size',
        (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      await tester.binding.setSurfaceSize(size);
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final storage = await initTestStorage();
      await tester.runAsync(() => storage.saveConfig(jsonEncode({
            'lives': [
              {'name': '测试直播', 'url': 'https://owned.invalid/live.m3u'}
            ],
            'sites': [
              {
                'key': 'owned',
                'name': List.filled(14, '超长片源名称').join(),
                'type': 1,
                'api': 'https://owned.invalid/api'
              }
            ]
          })));
      final client = WindowsFixtureClient();
      await tester.runAsync(() => storage.upsertWatchHistory(
          const WatchHistoryEntry(
              site: 'owned',
              id: 'history',
              title: '昨日的旅途',
              poster: '',
              line: '主线路',
              episode: '第 3 集',
              index: 2,
              position: 60000,
              duration: 1200000,
              updated: 1),
          triggerSync: false));
      final appearance = WindowsAppearance(Directory.systemTemp);
      addTearDown(appearance.dispose);
      await tester.pumpWidget(MaterialApp(
          builder: (_, child) =>
              WindowsAppearanceScope(controller: appearance, child: child!),
          home: RepaintBoundary(
              key: const ValueKey('capture'),
              child: AdaptiveShell(
                  storage: storage,
                  client: client,
                  onSetPreventCloseForTest: (_) async {}))));
      await tester.pumpAndSettle();
      expect(find.text('影片详情'), findsOneWidget);
      expect(find.text('最近在看'), findsOneWidget);
      expect(find.text('为你呈现'), findsOneWidget,
          reason: 'History and recommendations must coexist on home');
      await captureWindowsPage(tester, 'home-${size.width.toInt()}');
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('发现').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('电影').first);
      await tester.pumpAndSettle();
      expect(client.categoryRequests, contains('1'));
      await tester.tap(find.text('筛选'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('首页').first);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('山间来信'), 200,
          scrollable: find.byType(Scrollable).last);
      expect(find.text('山间来信'), findsOneWidget,
          reason: 'Discover must not replace home recommendations');
      await tester.tap(find.byTooltip('搜索影片 · Ctrl+K'));
      await tester.pumpAndSettle();
      expect(
          find.byKey(const ValueKey('windows-search-input')), findsOneWidget);
      await tester.enterText(
          find.byKey(const ValueKey('windows-search-input')), '海边');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(find.byKey(const PageStorageKey('windows-search-results')),
          findsOneWidget);
      final result = find.byWidgetPredicate(
          (w) => w is InkWell && w.key.toString().contains('windows-search-'));
      expect(result, findsOneWidget);
      Focus.of(tester.element(
              find.descendant(of: result, matching: find.text('海边的光'))))
          .requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.byType(DetailScreen), findsOneWidget);
      expect(
          find.byKey(const ValueKey('windows-detail-poster')), findsOneWidget);
      expect(find.text('切换片源'), findsOneWidget);
      await tester.tap(find.text('返回'));
      await tester.pumpAndSettle();
      expect(find.text('海边'), findsOneWidget);
      await tester.tap(find.text('我的').first);
      await tester.pumpAndSettle();
      for (final segment in ['继续观看', '收藏', '下载']) {
        await tester.tap(find.text(segment).first);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
      await tester.tap(find.text('直播').first);
      await tester.pumpAndSettle();
      final liveSearch = find.widgetWithText(TextField, '搜索全部频道');
      await tester.ensureVisible(liveSearch);
      await tester.enterText(liveSearch, '纪录');
      await tester.pumpAndSettle();
      expect(find.text('自然世界'), findsOneWidget,
          reason: 'Search includes other groups and group names');
      await tester.enterText(liveSearch, '不存在的频道');
      await tester.pumpAndSettle();
      expect(find.text('没有匹配频道'), findsOneWidget);
      await tester.tap(find.text('清除搜索'));
      await tester.pumpAndSettle();
      expect(find.text('经典电影'), findsOneWidget);
      expect(find.text('自然世界'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('设置'));
      await tester.pumpAndSettle();
      expect(find.text('沉静主题'), findsOneWidget);
      expect(tester.takeException(), isNull);
      if (Platform.environment['MARCO_CAPTURE_DIR'] case final String output) {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(const ValueKey('capture')));
        await tester.runAsync(() async {
          final image = await boundary.toImage();
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          await Directory(output).create(recursive: true);
          await File('$output/settings-${size.width.toInt()}.png')
              .writeAsBytes(data!.buffer.asUint8List());
          image.dispose();
        });
      }
      for (final tab in ['首页与排版', '播放', '内容来源', '账号', '同步与备份', '更多设置']) {
        await tester.tap(find.widgetWithText(WinButton, tab).first);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'Settings: $tab');
        if (tab == '播放') {
          await captureWindowsPage(
              tester, 'playback-settings-${size.width.toInt()}');
        }
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      debugDefaultTargetPlatformOverride = null;
    });
  }

  testWidgets(
      'exiting privacy clears private catalogue before a delayed public request finishes',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final storage = await initTestStorage();
    await storage.setPrivacyPassword('1234');
    await tester.runAsync(() => storage.saveConfig(jsonEncode({
          'sites': [
            {
              'key': 'public',
              'name': '公开源',
              'type': 1,
              'api': 'https://owned.invalid/public'
            },
            {
              'key': 'private',
              'name': '隐私源',
              'type': 1,
              'api': 'https://owned.invalid/private',
              'isPrivate': true
            },
          ]
        })));
    final appearance = WindowsAppearance(Directory.systemTemp);
    addTearDown(appearance.dispose);
    final client = PrivacyFixtureClient();
    await tester.pumpWidget(MaterialApp(
        builder: (_, child) =>
            WindowsAppearanceScope(controller: appearance, child: child!),
        home: AdaptiveShell(
            storage: storage,
            client: client,
            onSetPreventCloseForTest: (_) async {})));
    await tester.pumpAndSettle();
    for (var i = 0; i < 5; i++) {
      await tester.tap(find.byKey(const ValueKey('home-brand-logo')));
      await tester.pump(const Duration(milliseconds: 80));
    }
    await tester.pumpAndSettle();
    for (final digit in ['1', '2', '3', '4']) {
      await tester.tap(find.text(digit));
    }
    await tester.pumpAndSettle();
    expect(find.text('仅隐私可见的影片'), findsWidgets);
    await tester.tap(find.text('退出隐私空间'));
    await tester.pump();
    expect(find.text('仅隐私可见的影片'), findsNothing);
    client.pendingPublic.completeError(const FormatException('公共片源失败'));
    await tester.pumpAndSettle();
    expect(find.text('仅隐私可见的影片'), findsNothing);
    expect(find.text('重试'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets(
      'Windows details preserve favorites, line switching, episode ordering and all-episode picker',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    await tester.binding.setSurfaceSize(const Size(1280, 1000));
    tester.view.physicalSize = const Size(1280, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final storage = await initTestStorage();
    final appearance = WindowsAppearance(Directory.systemTemp);
    addTearDown(appearance.dispose);
    await storage.upsertWatchHistory(
        const WatchHistoryEntry(
            site: 'owned',
            id: 'one',
            title: '海边的光',
            poster: '',
            line: '主线路',
            episode: '第 2 集',
            index: 1,
            position: 180000,
            duration: 1200000,
            updated: 1),
        triggerSync: false);
    await tester.pumpWidget(MaterialApp(
        builder: (_, child) =>
            WindowsAppearanceScope(controller: appearance, child: child!),
        home: DetailScreen(
            site: fixtureSite,
            initialVideo: fixtureVideo,
            storage: storage,
            client: WindowsFixtureClient())));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('继续观看'), findsOneWidget);
    await tester.tap(find.text('收藏'));
    await tester.pumpAndSettle();
    expect(storage.getFavorites().length, 1);
    // Lines and episodes are collapsible button drawers by default.
    expect(find.byKey(const ValueKey('windows-detail-lines-panel')), findsNothing);
    expect(find.byKey(const ValueKey('windows-detail-episodes-panel')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('windows-detail-line-toggle')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('windows-detail-lines-panel')), findsOneWidget);
    await tester.tap(find.text('备用线路'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('windows-detail-episode-toggle')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('ep_card_1_0')), findsOneWidget);
    expect(find.text('立即播放'), findsOneWidget,
        reason: 'Switching line must not resume the old line');
    await tester.tap(find.text('主线路'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('正序'));
    await tester.pumpAndSettle();
    expect(storage.episodesDescending, isTrue);
    await tester.tap(find.text('全部剧集'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    debugDefaultTargetPlatformOverride = null;
  });

  for (final size in [
    const Size(720, 520),
    const Size(1280, 800),
    const Size(1920, 1080)
  ]) {
    testWidgets(
        'Responsive detail keeps poster, source and episode access at $size',
        (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final storage = await initTestStorage();
      final appearance = WindowsAppearance(Directory.systemTemp);
      addTearDown(appearance.dispose);
      await tester.pumpWidget(MaterialApp(
          builder: (_, child) => WindowsAppearanceScope(
              controller: appearance,
              child: RepaintBoundary(
                  key: const ValueKey('capture'), child: child!)),
          home: DetailScreen(
              site: fixtureSite,
              initialVideo: fixtureVideo,
              storage: storage,
              client: WindowsFixtureClient())));
      await tester.pumpAndSettle();
      final poster =
          tester.getRect(find.byKey(const ValueKey('windows-detail-poster')));
      expect(poster.top, greaterThanOrEqualTo(0));
      expect(poster.left, closeTo(0, 1.0));
      expect(poster.width, closeTo(size.width, 1.0));
      expect(poster.bottom, lessThan(size.height));
      // Full-bleed landscape immersive big-screen hero poster
      expect(poster.width, greaterThan(poster.height));
      await captureWindowsPage(tester, 'detail-${size.width.toInt()}');
      await tester.ensureVisible(
          find.byKey(const ValueKey('windows-detail-line-toggle')));
      await tester.pumpAndSettle();
      await tester.tap(
          find.byKey(const ValueKey('windows-detail-line-toggle')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('备用线路'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('备用线路'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
          find.byKey(const ValueKey('windows-detail-episode-toggle')));
      await tester.pumpAndSettle();
      await tester.tap(
          find.byKey(const ValueKey('windows-detail-episode-toggle')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('ep_card_1_0')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('ep_card_1_0')).hitTestable(),
          findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      debugDefaultTargetPlatformOverride = null;
    });
  }

  testWidgets(
      'Windows account and sync routes use the same appearance and return safely',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    tester.view.physicalSize = const Size(720, 520);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final storage = await initTestStorage();
    final appearance = WindowsAppearance(Directory.systemTemp);
    addTearDown(appearance.dispose);
    await tester.pumpWidget(MaterialApp(
        builder: (_, child) => WindowsAppearanceScope(
            controller: appearance,
            child:
                RepaintBoundary(key: const ValueKey('capture'), child: child!)),
        home: Builder(
            builder: (context) => Scaffold(
                    body: Column(children: [
                  TextButton(
                      onPressed: () =>
                          showNetdiskAccountSheet(context, storage),
                      child: const Text('accounts')),
                  TextButton(
                      onPressed: () => showCloudSyncSheet(context, storage),
                      child: const Text('sync')),
                ])))));
    for (final route in ['accounts', 'sync']) {
      await tester.tap(find.text(route));
      await tester.pumpAndSettle();
      expect(find.byType(WinSettingsScaffold), findsOneWidget);
      expect(find.byType(WinSettingsRow), findsWidgets);
      await captureWindowsPage(tester, '$route-720');
      if (route == 'sync') {
        final label = tester.widget<Text>(find.text('服务器目录或文件地址'));
        final color = label.style!.color!;
        // Verify contrast matches the active dark or light Windows panel surface.
        final panelBg = appearance.dark
            ? const Color(0xFF171B22)
            : const Color(0xFFF5F6F8);
        final painted = Color.alphaBlend(color, panelBg);
        final l1 = math.max(panelBg.computeLuminance(), painted.computeLuminance());
        final l2 = math.min(panelBg.computeLuminance(), painted.computeLuminance());
        final contrast = (l1 + .05) / (l2 + .05);
        expect(contrast, greaterThanOrEqualTo(4.5));
        final field = find.byKey(const ValueKey('sync-webdav-url'));
        if (field.evaluate().isNotEmpty) {
          await tester.ensureVisible(field);
          await tester.enterText(field, 'https://owned.invalid/dav');
        }
      }
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('返回'));
      await tester.pumpAndSettle();
      expect(find.byType(WinSettingsScaffold), findsNothing);
    }
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    debugDefaultTargetPlatformOverride = null;
  });
}
