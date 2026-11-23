import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/cupertino.dart'
    show CupertinoTheme, CupertinoThemeData, CupertinoTextThemeData;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/storage_service.dart';
import 'package:marco_movie/ui/adaptive_shell.dart';
import 'package:marco_movie/ui/apple_theme.dart';
import 'package:marco_movie/ui/ios_liquid_glass.dart';
import 'package:marco_movie/ui/ios_settings.dart';

void main() {
  setUp(() {
    PackageInfo.setMockInitialValues(
        appName: 'Marco Movie',
        packageName: 'test',
        version: '0.5.18',
        buildNumber: '68',
        buildSignature: '');
  });

  Future<StorageService> mount(WidgetTester tester, Size size,
      {double scale = 1}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({});
    final storage = await StorageService.init();
    await storage.saveConfig(
        '{"sites":[{"key":"test","name":"玩偶哥哥 4K 弹幕","type":1,"api":"https://source.example/api"}]}');
    final capture = Platform.environment['MARCO_UI_CAPTURE_DIR'];
    if (capture != null) {
      final font = Platform.environment['MARCO_UI_CAPTURE_FONT'];
      if (font != null) {
        await tester.runAsync(() async {
          final bytes = ByteData.sublistView(await File(font).readAsBytes());
          for (final family in [
            'PreviewFont',
            'Ahem',
            'CupertinoSystemText',
            'CupertinoSystemDisplay'
          ]) {
            await (FontLoader(family)..addFont(Future.value(bytes))).load();
          }
          await (FontLoader('packages/cupertino_icons/CupertinoIcons')
                ..addFont(rootBundle.load(
                    'packages/cupertino_icons/assets/CupertinoIcons.ttf')))
              .load();
        });
      }
    }
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData.dark().copyWith(
          textTheme: ThemeData.dark()
              .textTheme
              .apply(fontFamily: capture != null ? 'PreviewFont' : null)),
      builder: (context, child) => RepaintBoundary(
          key: const ValueKey('ios-capture'),
          child: MediaQuery(
            data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(scale),
                padding: size.width > size.height
                    ? const EdgeInsets.fromLTRB(44, 0, 44, 21)
                    : const EdgeInsets.fromLTRB(0, 44, 0, 34)),
            child: capture == null
                ? child!
                : CupertinoTheme(
                    data: const CupertinoThemeData(
                        textTheme: CupertinoTextThemeData(
                            textStyle: TextStyle(fontFamily: 'PreviewFont'),
                            actionTextStyle:
                                TextStyle(fontFamily: 'PreviewFont'))),
                    child: child!),
          )),
      home: AdaptiveShell(
          storage: storage,
          client: CmsClient(
              client: MockClient(
                  (_) async => http.Response('{"class":[],"list":[]}', 200)))),
    ));
    if (capture != null) {
      await tester.runAsync(() => precacheImage(
          const AssetImage('assets/logo_mark.png'),
          tester.element(find.byType(AdaptiveShell))));
    }
    await tester.pump(const Duration(milliseconds: 600));
    return storage;
  }

  Future<void> capture(WidgetTester tester, String name) async {
    final folder = Platform.environment['MARCO_UI_CAPTURE_DIR'];
    if (folder == null) return;
    await tester.pumpAndSettle();
    final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const ValueKey('ios-capture')));
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await File('$folder/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  Future<void> tapKey(WidgetTester tester, String key) async {
    final finder = find.byKey(ValueKey(key));
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  testWidgets(
      'three settings levels push iOS system secondary pages without modal popups and persist values',
      (tester) async {
    final storage = await mount(tester, const Size(390, 844));
    await capture(tester, 'home-390');
    await tester.tap(find.text('设置').last);
    await tester.pumpAndSettle();
    await capture(tester, 'settings-root-390');
    expect(find.byKey(const ValueKey('settings-liquid-glass-slider')),
        findsNothing);
    // Version number must NOT appear on Level-1 Settings root
    expect(find.textContaining('0.5.18'), findsNothing);
    expect(find.textContaining('Marco Movie ·'), findsNothing);
    expect(find.byType(IosSettingsGroup), findsWidgets);

    await tapKey(tester, 'settings-category-playback');
    await capture(tester, 'settings-playback-390');
    expect(find.byType(IosSettingsSubPage), findsOneWidget);

    await tapKey(tester, 'settings-open-episodes');
    await tapKey(tester, 'choice-起播倍速-1.5');
    expect(storage.playSpeed, 1.5);
    await capture(tester, 'settings-episodes-390');

    await tapKey(tester, 'settings-drawer-back');
    expect(find.byKey(const ValueKey('settings-page-playback')), findsOneWidget);
    await tapKey(tester, 'settings-open-episodes');
    expect(
        tester
            .widget<IosSettingsChoiceTile>(
                find.byKey(const ValueKey('choice-起播倍速-1.5')))
            .selected,
        isTrue);
    expect((await StorageService.init()).playSpeed, 1.5);

    await tapKey(tester, 'settings-drawer-back');
    expect(find.byKey(const ValueKey('settings-open-picture')), findsOneWidget);
    await tapKey(tester, 'settings-drawer-back');
    expect(find.byKey(const ValueKey('ios-settings-root')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets(
      'version lives in About & Updates page and sub-tools push iOS pages instead of modal sheets',
      (tester) async {
    await mount(tester, const Size(390, 844));
    await tester.tap(find.text('设置').last);
    await tester.pumpAndSettle();
    expect(find.textContaining('0.5.18'), findsNothing);

    await tapKey(tester, 'settings-category-about');
    expect(find.byKey(const ValueKey('settings-page-about')), findsOneWidget);
    expect(find.byKey(const ValueKey('ios-about-version')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('ios-about-version')),
        matching: find.text('0.5.18'),
      ),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('ios-check-update-row')), findsOneWidget);
    await capture(tester, 'settings-about-390');

    await tapKey(tester, 'settings-drawer-back');
    expect(find.byKey(const ValueKey('ios-settings-root')), findsOneWidget);

    await tapKey(tester, 'settings-category-sources');
    await tapKey(tester, 'ios-open-subscriptions');
    expect(find.text('订阅管理'), findsOneWidget);
    await tapKey(tester, 'settings-drawer-back');
    expect(find.byKey(const ValueKey('settings-page-sources')), findsOneWidget);

    await tapKey(tester, 'settings-drawer-back');
    await tapKey(tester, 'settings-category-data');
    await tapKey(tester, 'settings-open-backup');
    expect(find.byKey(const ValueKey('ios-backup-copy')), findsOneWidget);
    expect(find.byKey(const ValueKey('ios-backup-restore-btn')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets(
      'iOS Live TV tab filters out Android local spider proxy sources while loading valid M3U channels',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({});
    final storage = await StorageService.init();
    await storage.saveConfig(
      '{"sites":[{"key":"vod","name":"综合点播","type":1,"api":"https://source.example/api"}],'
      '"lives":['
      '{"name":"综合","url":"https://live.example/main.m3u"},'
      '{"name":"牛播一","url":"http://127.0.0.1:9978/proxy?do=cctva"}'
      ']}',
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: AdaptiveShell(
          storage: storage,
          client: CmsClient(
            client: MockClient((req) async {
              if (req.url.toString() == 'https://live.example/main.m3u') {
                return http.Response.bytes(
                  utf8.encode(
                    '#EXTM3U\n#EXTINF:-1 group-title="央视",CCTV-1 综合\nhttps://stream.example/cctv1.m3u8\n',
                  ),
                  200,
                );
              }
              return http.Response('{"class":[],"list":[]}', 200);
            }),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 600));
    await tester.tap(find.text('直播').last);
    await tester.pumpAndSettle();
    expect(find.text('牛播一'), findsNothing);
    expect(find.text('CCTV-1 综合'), findsOneWidget);
    expect(find.textContaining('Connection refused'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  for (final size in [
    const Size(320, 740),
    const Size(844, 390),
    const Size(1024, 768)
  ]) {
    testWidgets('settings remain reachable at $size with enlarged text',
        (tester) async {
      final storage = await mount(tester, size, scale: 1.3);
      final logo = tester.widget<MarcoBrandLogo>(find.descendant(
          of: find.byKey(const ValueKey('home-brand-logo')),
          matching: find.byType(MarcoBrandLogo)));
      expect(logo.iconSize, greaterThanOrEqualTo(36));
      expect(
          tester.getSize(find.byKey(const ValueKey('home-brand-logo'))).height,
          greaterThanOrEqualTo(44));
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('设置').last);
      await tester.pumpAndSettle();
      await tapKey(tester, 'settings-category-appearance');
      // Ineffective liquid glass adjustment pane & slider must be removed.
      expect(find.byKey(const ValueKey('settings-open-glass')), findsNothing);
      expect(find.byKey(const ValueKey('ios-glass-slider')), findsNothing);
      await tapKey(tester, 'choice-主题模式-light');
      expect(storage.appThemeMode, 'light');
      await capture(tester, 'settings-appearance-${size.width.toInt()}');
      await tapKey(tester, 'settings-drawer-back');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
  }

  testWidgets('rotating a third-level drawer preserves page and setting',
      (tester) async {
    final storage = await mount(tester, const Size(390, 844));
    await tester.tap(find.text('设置').last);
    await tester.pumpAndSettle();
    await tapKey(tester, 'settings-category-playback');
    await tapKey(tester, 'settings-open-episodes');
    await tapKey(tester, 'choice-起播倍速-1.25');
    tester.view.physicalSize = const Size(844, 390);
    await tester.pumpAndSettle();
    expect(
        find.byKey(const ValueKey('settings-page-episodes')), findsOneWidget);
    expect(storage.playSpeed, 1.25);
    await tapKey(tester, 'settings-drawer-back');
    expect(
        find.byKey(const ValueKey('settings-page-playback')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets(
      'portrait settings scroll viewport extends behind transparent Dock without high clipping mask',
      (tester) async {
    await mount(tester, const Size(390, 844));
    await tester.tap(find.text('设置').last);
    await tester.pumpAndSettle();
    final listRect =
        tester.getRect(find.byKey(const ValueKey('ios-settings-root')));
    final dockRect = tester.getRect(find.byType(AppleLiquidGlassDock));
    final aboutRect =
        tester.getRect(find.byKey(const ValueKey('settings-category-about')));
    expect(listRect.bottom, 844.0);
    expect(aboutRect.bottom, lessThanOrEqualTo(dockRect.top));
    await tapKey(tester, 'settings-category-about');
    expect(find.byKey(const ValueKey('settings-page-about')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets(
      'site picker opens as full-screen secondary page on iOS instead of modal popup',
      (tester) async {
    await mount(tester, const Size(390, 844));
    await tester.tap(find.text('玩偶哥哥 4K 弹幕').first);
    await tester.pumpAndSettle();
    expect(find.byType(IosSettingsScaffold), findsOneWidget);
    expect(find.text('切换片源 (可用 1 / 共 1)'), findsOneWidget);
    expect(find.byKey(const ValueKey('site-picker-scroll')), findsOneWidget);
    // Tapping 管理线路 transitions cleanly to another full-screen secondary page.
    await tester.tap(find.text('管理线路'));
    await tester.pumpAndSettle();
    expect(find.byType(IosSettingsScaffold), findsOneWidget);
    expect(find.text('管理线路'), findsOneWidget);
    await tapKey(tester, 'settings-drawer-back');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets(
      'iOS 0.7.0 playback engine/HDR/loudness/Anime4K and disk cache/HLS ad settings persist',
      (tester) async {
    final storage = await mount(tester, const Size(390, 844));
    await tester.tap(find.text('设置').last);
    await tester.pumpAndSettle();

    await tapKey(tester, 'settings-category-playback');
    await tapKey(tester, 'settings-open-picture');
    expect(find.byType(IosPlaybackEngineSettingsSection), findsOneWidget);

    await tapKey(tester, 'choice-播放内核偏好-mpv');
    expect(storage.iosPlaybackEngineMode, 'mpv');

    await tapKey(tester, 'choice-HDR 色调映射（MPV 内核）-bt.2446a');
    expect(storage.iosHdrToneMappingMode, 'bt.2446a');

    await tapKey(tester, 'choice-人声响度增强（4 档）-cinema_vocal');
    expect(storage.vocalLoudnessPreset, 'cinema_vocal');

    Future<void> tapSwitch(String key) async {
      final rowFinder = find.byKey(ValueKey(key));
      await tester.ensureVisible(rowFinder);
      await tester.pumpAndSettle();
      final switchFinder = find.descendant(
        of: rowFinder,
        matching: find.byType(IosNativeSwitch),
      );
      await tester.tap(switchFinder);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }

    await tapSwitch('ios-switch-anime4k-lightweight');
    expect(storage.iosAnime4kLightweightEnabled, isTrue);

    await tapSwitch('ios-switch-mpv-large-buffer');
    expect(storage.iosLargeBufferEnabled, isTrue);

    await tapKey(tester, 'settings-drawer-back');
    await tapKey(tester, 'settings-drawer-back');
    await tapKey(tester, 'settings-category-data');
    await tapKey(tester, 'settings-open-cache');

    expect(find.byKey(const ValueKey('ios-switch-hls-ad-removal')),
        findsOneWidget);
    final initialAdRemoval = storage.hlsAdRemovalEnabled;
    await tapSwitch('ios-switch-hls-ad-removal');
    expect(storage.hlsAdRemovalEnabled, !initialAdRemoval);

    await tapKey(tester, 'choice-本地媒体落盘缓存上限-512');
    expect(storage.mediaDiskCacheLimitMb, 512);

    await tester.pumpWidget(const SizedBox());
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
}
