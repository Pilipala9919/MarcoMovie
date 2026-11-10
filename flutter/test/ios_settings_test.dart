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
      'three settings levels keep selection, back navigation and persisted values',
      (tester) async {
    final storage = await mount(tester, const Size(390, 844));
    await capture(tester, 'home-390');
    await tester.tap(find.text('设置').last);
    await tester.pumpAndSettle();
    await capture(tester, 'settings-root-390');
    expect(find.byKey(const ValueKey('settings-liquid-glass-slider')),
        findsNothing);
    await tapKey(tester, 'settings-category-playback');
    await capture(tester, 'settings-playback-390');
    await tapKey(tester, 'settings-open-episodes');
    await tapKey(tester, 'choice-起播倍速-1.5');
    expect(storage.playSpeed, 1.5);
    await capture(tester, 'settings-episodes-390');
    await tapKey(tester, 'settings-drawer-back');
    await tapKey(tester, 'settings-open-episodes');
    expect(
        tester
            .widget<AppleCapsuleButton>(
                find.byKey(const ValueKey('choice-起播倍速-1.5')))
            .primary,
        isTrue);
    expect((await StorageService.init()).playSpeed, 1.5);
    await tapKey(tester, 'settings-breadcrumb-0');
    expect(find.byKey(const ValueKey('settings-open-picture')), findsOneWidget);
    Navigator.of(tester
            .element(find.byKey(const ValueKey('settings-page-playback'))))
        .pop();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('ios-settings-root')), findsOneWidget);
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
      await tapKey(tester, 'settings-open-glass');
      await tapKey(tester, 'choice-玻璃预设-solid');
      expect(storage.glassBlurStrength, 0);
      await capture(tester, 'settings-glass-${size.width.toInt()}');
      await tapKey(tester, 'settings-drawer-back');
      await tapKey(tester, 'settings-open-wallpaper');
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
}
