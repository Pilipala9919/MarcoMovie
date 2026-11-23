import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/ui/adaptive_shell.dart';
import 'package:marco_movie/ui/apple_theme.dart';
import 'package:marco_movie/ui/ios_liquid_glass.dart';
import 'package:marco_movie/ui/ios_settings.dart';
import 'package:marco_movie/ui/netdisk_sheet.dart';
import 'test_storage_helper.dart';

void main() {
  tearDown(() {
    IosLiquidGlassBridge.setAvailableForTest(null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(IosLiquidGlassBridge.channel, null);
  });

  testWidgets(
    'portrait Dock renders left 4-tab capsule + right detached circular search button and removes top search icon',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final storage = await initTestStorage();
      await storage.saveConfig(
        '{"sites":[{"key":"test","name":"测试源","type":1,"api":"https://source.example/api"}]}',
      );
      final client = CmsClient(
        client: MockClient(
          (_) async => http.Response('{"class":[],"list":[]}', 200),
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: AdaptiveShell(storage: storage, client: client),
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));

      final dockFinder = find.byType(AppleLiquidGlassDock);
      final searchFinder = find.byKey(const ValueKey('home-search-button'));
      expect(dockFinder, findsOneWidget);
      expect(searchFinder, findsOneWidget);

      // Search button lives inside the bottom Dock, to the right of the 4 tabs (not in the top bar).
      final dockRect = tester.getRect(dockFinder);
      final searchRect = tester.getRect(searchFinder);
      final settingsTabRect = tester.getRect(find.text('设置').last);
      expect(searchRect.top, greaterThanOrEqualTo(dockRect.top));
      expect(searchRect.bottom, lessThanOrEqualTo(dockRect.bottom));
      expect(searchRect.left, greaterThan(settingsTabRect.right));
      expect(searchRect.width, closeTo(searchRect.height, 0.5));

      // Verify all 4 tab labels exist inside the Dock.
      for (final label in ['主页', '直播', '片库', '设置']) {
        expect(
          find.descendant(of: dockFinder, matching: find.text(label)),
          findsOneWidget,
        );
      }

      // Tapping the detached circular search button opens Global Search.
      await tester.tap(searchFinder);
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(AppleSearchField), findsAtLeastNWidgets(1));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'iOS 26 native mode mounts UiKitView for Dock, SegmentedControl, and Settings back button',
    (tester) async {
      IosLiquidGlassBridge.setAvailableForTest(true);
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      const dockItems = <(IconData, IconData, String)>[
        (CupertinoIcons.play_rectangle, CupertinoIcons.play_rectangle_fill, '主页'),
        (CupertinoIcons.dot_radiowaves_left_right, CupertinoIcons.dot_radiowaves_left_right, '直播'),
        (CupertinoIcons.square_stack_3d_up, CupertinoIcons.square_stack_3d_up_fill, '片库'),
        (CupertinoIcons.gear_alt, CupertinoIcons.gear_alt_fill, '设置'),
      ];
      const nativeItems = <IosNativeDockItem>[
        IosNativeDockItem(label: '主页', symbol: 'play.rectangle', selectedSymbol: 'play.rectangle.fill'),
        IosNativeDockItem(label: '直播', symbol: 'dot.radiowaves.left.and.right'),
        IosNativeDockItem(label: '片库', symbol: 'square.stack.3d.up', selectedSymbol: 'square.stack.3d.up.fill'),
        IosNativeDockItem(label: '设置', symbol: 'gearshape', selectedSymbol: 'gearshape.fill'),
      ];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                IosNativeSegmentedControl(
                  segments: const ['收藏片单', '观看历史', '离线下载'],
                  selectedIndex: 1,
                  onChanged: (_) {},
                  fallback: const SizedBox.shrink(),
                ),
                IosNativeGlassButton(
                  style: 'circle',
                  symbol: 'chevron.backward',
                  onTap: () {},
                  fallback: const SizedBox.shrink(),
                ),
                IosNativeGlassPill(
                  actions: [
                    IosNativeGlassPillAction(
                      symbol: 'qrcode.viewfinder',
                      accessibilityLabel: '网盘扫码',
                      onTap: () {},
                    ),
                    IosNativeGlassPillAction(
                      symbol: 'heart.fill',
                      color: AppleColors.systemRed,
                      accessibilityLabel: '取消收藏',
                      onTap: () {},
                    ),
                  ],
                  fallback: const SizedBox.shrink(),
                ),
                Expanded(
                  child: IosSettingsScaffold(
                    title: '播放设置',
                    body: const SizedBox.shrink(),
                  ),
                ),
              ],
            ),
            bottomNavigationBar: AppleLiquidGlassDock(
              selectedIndex: 0,
              onSelect: (_) {},
              isLandscape: false,
              items: dockItems,
              nativeItems: nativeItems,
              onSearch: () {},
            ),
          ),
        ),
      );
      await tester.pump();

      final views = tester.widgetList<UiKitView>(find.byType(UiKitView)).toList();
      final types = views.map((v) => v.viewType).toList();
      expect(types, contains('marco_movie/ios26_dock'));
      expect(types, contains('marco_movie/ios26_segmented_control'));
      expect(types, contains('marco_movie/ios26_glass_button'));
      expect(types, contains('marco_movie/ios26_glass_pill'));

      final dockView = views.firstWhere((v) => v.viewType == 'marco_movie/ios26_dock');
      final dockParams = dockView.creationParams as Map<dynamic, dynamic>;
      expect(dockParams['showSearch'], isTrue);
      expect((dockParams['items'] as List).length, 4);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'showAppleNativeAlert and showAppleNativeActionSheet dispatch to UIAlertController channel on iOS 26+',
    (tester) async {
      IosLiquidGlassBridge.setAvailableForTest(true);
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(IosLiquidGlassBridge.channel, (call) async {
        calls.add(call);
        if (call.method == 'showAlert') return 'delete';
        if (call.method == 'showActionSheet') return '1';
        return null;
      });

      late BuildContext captured;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (ctx) {
              captured = ctx;
              return const SizedBox.shrink();
            },
          ),
        ),
      );

      final alertRes = await showAppleNativeAlert(
        captured,
        title: '删除确认',
        message: '确定要删除吗？',
        actions: const [
          AppleNativeAlertAction(id: 'cancel', title: '取消', isCancel: true),
          AppleNativeAlertAction(id: 'delete', title: '删除', isDestructive: true),
        ],
      );
      expect(alertRes, 'delete');

      final sheetRes = await showAppleNativeActionSheet<String>(
        captured,
        title: '切换画质',
        options: const [
          AppleNativeSheetOption(value: '1080p', title: '1080P'),
          AppleNativeSheetOption(value: '4k', title: '4K 原画', isDefault: true),
        ],
      );
      expect(sheetRes, '4k');
      expect(calls.map((c) => c.method).toList(), ['showAlert', 'showActionSheet']);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'scrolling Home collapses 4+1 Dock to bottom-right brand logo bubble and restores on scroll back to top',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final storage = await initTestStorage();
      await storage.saveConfig(
        '{"sites":[{"key":"test","name":"测试源","type":1,"api":"https://source.example/api"}]}',
      );
      final videos = List.generate(
        24,
        (i) => '{"vod_id":"v$i","vod_name":"测试影片 $i","vod_pic":"","vod_remarks":"HD"}',
      ).join(',');
      final client = CmsClient(
        client: MockClient(
          (_) async => http.Response('{"class":[{"type_id":"1","type_name":"电影"}],"list":[$videos]}', 200),
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: AdaptiveShell(storage: storage, client: client),
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));

      // At top: 4+1 Dock is visible, collapsed logo button is absent.
      final searchFinder = find.byKey(const ValueKey('home-search-button'));
      expect(searchFinder, findsOneWidget);
      expect(find.byKey(const ValueKey('dock-collapsed-logo-button')), findsNothing);
      final expandedSearchRect = tester.getRect(searchFinder);
      final expandedDockRect = tester.getRect(find.byType(AppleLiquidGlassDock));

      // Scroll Home downward past logo threshold -> collapses into bottom-right brand logo button.
      await tester.drag(find.byType(CustomScrollView).first, const Offset(0, -320));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      final collapsedFinder =
          find.byKey(const ValueKey('dock-collapsed-logo-button'));
      expect(collapsedFinder, findsOneWidget);
      expect(searchFinder, findsNothing);

      // Regression guard for iOS 16.4 (iOS < 26 fallback Dock): collapsed button
      // MUST stay pinned at the exact same bottom-right anchor as the expanded
      // search button — NEVER expand Align to full screen height and float to mid-screen!
      final collapsedRect = tester.getRect(collapsedFinder);
      final collapsedDockRect = tester.getRect(find.byType(AppleLiquidGlassDock));
      expect(collapsedDockRect.height, closeTo(expandedDockRect.height, 1.0));
      expect(collapsedRect.top, closeTo(expandedSearchRect.top, 1.0));
      expect(collapsedRect.bottom, closeTo(expandedSearchRect.bottom, 1.0));
      expect(collapsedRect.right, closeTo(expandedSearchRect.right, 1.0));

      // Tapping the collapsed logo button opens the vertical glass bubble menu.
      await tester.tap(find.byKey(const ValueKey('dock-collapsed-logo-button')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.byKey(const ValueKey('dock-collapsed-bubble-menu')), findsOneWidget);
      expect(find.text('搜索影片'), findsOneWidget);
      expect(find.text('回到顶部'), findsOneWidget);

      // Tapping 回到顶部 scrolls back to top and restores the full 4+1 Dock.
      await tester.tap(find.text('回到顶部'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const ValueKey('home-search-button')), findsOneWidget);
      expect(find.byKey(const ValueKey('dock-collapsed-logo-button')), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'showAppleNativeFilterSheet dispatches payload and decodes selected filters on iOS 26+',
    (tester) async {
      IosLiquidGlassBridge.setAvailableForTest(true);
      MethodCall? capturedCall;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(IosLiquidGlassBridge.channel, (call) async {
        capturedCall = call;
        return <String, dynamic>{
          'categoryId': '2',
          'genreLabel': '',
          'area': '中国大陆',
          'year': '2026',
        };
      });

      final res = await showAppleNativeFilterSheet(
        categories: const [
          IosNativeFilterCategory(id: '', label: '全部', kind: 'all'),
          IosNativeFilterCategory(id: '2', label: '动作片', kind: 'cat'),
        ],
        selectedCategoryId: '',
        selectedGenreLabel: '',
        areas: const ['全部', '中国大陆', '美国'],
        selectedArea: '',
        years: const ['全部', '2026', '2025'],
        selectedYear: '',
      );

      expect(capturedCall?.method, 'showFilterSheet');
      expect(res, isNotNull);
      expect(res!.categoryId, '2');
      expect(res.area, '中国大陆');
      expect(res.year, '2026');
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'Home mounts native UIMenu source button, netdisk glass button, category segmented control, and filter glass button on iOS 26+',
    (tester) async {
      IosLiquidGlassBridge.setAvailableForTest(true);
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final storage = await initTestStorage();
      await storage.saveConfig(
        '{"sites":[{"key":"s1","name":"玩偶哥哥 | 4K弹幕","type":1,"api":"https://source.example/api"},{"key":"s2","name":"备用影视","type":1,"api":"https://backup.example/api"}]}',
      );
      final client = CmsClient(
        client: MockClient(
          (_) async => http.Response('{"class":[],"list":[]}', 200),
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: AdaptiveShell(storage: storage, client: client),
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));

      // Top viewport mounts the Dock + Source UIMenu + Netdisk glass button.
      final topViews =
          tester.widgetList<UiKitView>(find.byType(UiKitView)).toList();
      final topTypes = topViews.map((v) => v.viewType).toList();
      expect(topTypes, contains('marco_movie/ios26_dock'));
      expect(
        topTypes.where((t) => t == 'marco_movie/ios26_glass_button').length,
        greaterThanOrEqualTo(2), // Source UIMenu + Netdisk circle
      );

      // Verify the source switcher button passes native UIMenu items.
      final sourceButton = topViews.firstWhere((v) {
        if (v.viewType != 'marco_movie/ios26_glass_button') return false;
        final params = v.creationParams as Map<dynamic, dynamic>;
        return params['menuItems'] != null;
      });
      final menuItems =
          (sourceButton.creationParams as Map<dynamic, dynamic>)['menuItems']
              as List<dynamic>;
      expect(menuItems.length, greaterThanOrEqualTo(2));
      expect((menuItems.first as Map)['id'], '__all__');

      // Scroll down below 片单发现 / 片源最新更新 where Category SegmentedControl + Filter button live.
      final categoryBarFinder =
          find.byKey(const ValueKey('home-category-filter-bar'));
      final homeScrollCtrl =
          tester.widget<CustomScrollView>(find.byType(CustomScrollView).first).controller!;
      for (double offset = 350.0;
          offset <= homeScrollCtrl.position.maxScrollExtent + 350.0 &&
              categoryBarFinder.evaluate().isEmpty;
          offset += 350.0) {
        homeScrollCtrl.jumpTo(
          offset.clamp(0.0, homeScrollCtrl.position.maxScrollExtent),
        );
        await tester.pump();
      }
      expect(categoryBarFinder, findsOneWidget);
      final categoryViews = tester
          .widgetList<UiKitView>(
            find.descendant(
              of: categoryBarFinder,
              matching: find.byType(UiKitView),
            ),
          )
          .map((v) => v.viewType)
          .toList();
      expect(categoryViews, contains('marco_movie/ios26_segmented_control'));
      expect(categoryViews, contains('marco_movie/ios26_glass_button'));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'Home source and depot native UIMenus include ALL routes without a 20-item cap and group multi-group sources',
    (tester) async {
      IosLiquidGlassBridge.setAvailableForTest(true);
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final storage = await initTestStorage();
      final sitesJson = List.generate(
        28,
        (i) =>
            '{"key":"s$i","name":"线路 $i","type":1,"api":"https://s$i.example/api","group":"${i < 14 ? '主线路' : '备用线路'}"}',
      ).join(',');
      final depotsJson = List.generate(
        25,
        (i) => '{"name":"子仓库 $i","url":"https://d$i.example/tv.json"}',
      ).join(',');
      await storage.saveConfig(
        '{"sites":[$sitesJson],"urls":[$depotsJson]}',
      );
      final client = CmsClient(
        client: MockClient(
          (_) async => http.Response('{"class":[],"list":[]}', 200),
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: AdaptiveShell(storage: storage, client: client),
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));

      final menuButtons = tester
          .widgetList<UiKitView>(find.byType(UiKitView))
          .where((v) =>
              v.viewType == 'marco_movie/ios26_glass_button' &&
              (v.creationParams as Map<dynamic, dynamic>)['menuItems'] != null)
          .toList();
      expect(menuButtons.length, greaterThanOrEqualTo(1));

      final sourceButton = menuButtons.firstWhere(
        (v) =>
            ((v.creationParams as Map)['menuItems'] as List)
                .first['id'] ==
            '__all__',
      );
      final sourceItems =
          ((sourceButton.creationParams as Map)['menuItems'] as List)
              .cast<Map<dynamic, dynamic>>();
      // 1 search/manage entry + all 28 routes (no 20-item truncation)
      expect(sourceItems.length, 29);
      // Verify multi-group section titles are propagated.
      final sectionTitles = sourceItems
          .map((m) => m['sectionTitle'])
          .where((t) => t != null)
          .toSet();
      expect(sectionTitles.length, greaterThanOrEqualTo(2));

      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'showAppleNativePrivacyPin dispatches showPrivacyPin and handles bidirectional privacyPinCallback',
    (tester) async {
      IosLiquidGlassBridge.setAvailableForTest(true);
      final seenCallbacks = <Map<String, dynamic>>[];
      MethodCall? showCall;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(IosLiquidGlassBridge.channel, (call) async {
        if (call.method == 'showPrivacyPin') {
          showCall = call;
          final sessionId = (call.arguments as Map)['sessionId'] as String;
          const codec = StandardMethodCodec();
          // Simulate native sending wrong PIN first, then correct PIN.
          for (final pin in ['0000', '1234']) {
            final envelope = codec.encodeMethodCall(
              MethodCall('privacyPinCallback', <String, dynamic>{
                'sessionId': sessionId,
                'mode': 'verify',
                'pin': pin,
              }),
            );
            ByteData? reply;
            await TestDefaultBinaryMessengerBinding
                .instance.defaultBinaryMessenger
                .handlePlatformMessage(
              IosLiquidGlassBridge.channel.name,
              envelope,
              (data) => reply = data,
            );
            final decoded = Map<String, dynamic>.from(
              codec.decodeEnvelope(reply!) as Map,
            );
            seenCallbacks.add(decoded);
          }
          return true;
        }
        return null;
      });

      final res = await showAppleNativePrivacyPin(
        mode: 'verify',
        title: '解锁隐私空间',
        subtitle: '输入设置的密码',
        pinLength: 4,
        onSubmit: (pin) async {
          if (pin == '1234') return (ok: true, error: null);
          return (ok: false, error: '密码错误，请重新输入');
        },
      );

      expect(showCall?.method, 'showPrivacyPin');
      expect(res, isTrue);
      expect(seenCallbacks.length, 2);
      expect(seenCallbacks[0]['ok'], isFalse);
      expect(seenCallbacks[0]['error'], '密码错误，请重新输入');
      expect(seenCallbacks[1]['ok'], isTrue);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'Netdisk iOS 26 page keeps native UISegmentedControl pinned outside SingleChildScrollView with zero BackdropFilter collisions',
    (tester) async {
      IosLiquidGlassBridge.setAvailableForTest(true);
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final storage = await initTestStorage();
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (ctx) => CupertinoButton(
              onPressed: () => showNetdiskAccountSheet(ctx, storage),
              child: const Text('打开云盘'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开云盘'));
      await tester.pumpAndSettle();

      // Native segmented control & header glass buttons are mounted.
      final segmentedFinder = find.byType(IosNativeSegmentedControl);
      expect(segmentedFinder, findsOneWidget);
      // Segmented control must NOT be inside SingleChildScrollView.
      expect(
        find.ancestor(
          of: segmentedFinder,
          matching: find.byType(SingleChildScrollView),
        ),
        findsNothing,
      );
      // No AppleGlassSurface (BackdropFilter) or GlassworkBackdrop on the page.
      expect(find.byType(AppleGlassSurface), findsNothing);
      expect(find.byType(GlassworkBackdrop), findsNothing);
      // No UiKitView nested inside SingleChildScrollView.
      expect(
        find.descendant(
          of: find.byType(SingleChildScrollView),
          matching: find.byType(UiKitView),
        ),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'IosNativeRouteGate unmounts background route UiKitViews during CupertinoPageRoute push and remounts on pop',
    (tester) async {
      IosLiquidGlassBridge.setAvailableForTest(true);
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final storage = await initTestStorage();
      await storage.saveConfig(
        '{"sites":['
        '{"key":"ok1","name":"正常片源","type":1,"api":"https://ok1.example/api"},'
        '{"key":"so1","name":"易听 | 音乐","type":3,"api":"csp_MusicAiYiTingGuard"}'
        ']}',
      );
      final client = CmsClient(
        client: MockClient(
          (_) async => http.Response('{"class":[],"list":[]}', 200),
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: AdaptiveShell(storage: storage, client: client),
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));

      // Home source UIMenu must automatically filter out unsupported Android .so routes.
      final homeMenuButtons = tester
          .widgetList<UiKitView>(find.byType(UiKitView))
          .where((v) =>
              v.viewType == 'marco_movie/ios26_glass_button' &&
              (v.creationParams as Map<dynamic, dynamic>)['menuItems'] != null)
          .toList();
      final sourceMenuItems =
          ((homeMenuButtons.first.creationParams as Map)['menuItems'] as List)
              .cast<Map<dynamic, dynamic>>();
      expect(sourceMenuItems.any((m) => m['id'] == 'site:ok1'), isTrue);
      expect(sourceMenuItems.any((m) => m['id'] == 'site:so1'), isFalse);

      // Push secondary page on top of Home; ownership hands off IMMEDIATELY on
      // route.isCurrent so Home unmounts its 5 background UiKitViews on frame 0
      // (preventing Impeller cross-route black occlusion) while the incoming
      // page mounts its 2 native UiKitViews immediately (zero dark-to-bright swap
      // or icon bounce at transition end).
      final navState = tester.state<NavigatorState>(find.byType(Navigator));
      navState.push<void>(
        buildApplePageRoute<void>(
          builder: (ctx) => IosSettingsScaffold(
            title: '测试页',
            body: IosNativeSegmentedControl(
              segments: const ['全部', '夸克'],
              selectedIndex: 0,
              onChanged: (_) {},
              fallback: const SizedBox(height: 36),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      // Mid-transition: strictly ONLY the foreground route's 2 UiKitViews exist
      // (zero background Home/Dock UiKitViews).
      final midPushViews =
          tester.widgetList<UiKitView>(find.byType(UiKitView)).toList();
      expect(midPushViews.length, 2);
      expect(
        midPushViews.any((v) => v.viewType == 'marco_movie/ios26_dock'),
        isFalse,
      );
      final backBtnParams = midPushViews
          .firstWhere((v) => v.viewType == 'marco_movie/ios26_glass_button')
          .creationParams as Map<dynamic, dynamic>;
      expect(backBtnParams['initialWidth'], 40.0);
      expect(backBtnParams['initialHeight'], 40.0);

      // After push settles: same 2 foreground UiKitViews remain mounted seamlessly.
      await tester.pumpAndSettle();
      expect(find.byType(UiKitView), findsNWidgets(2));
      expect(
        tester
            .widgetList<UiKitView>(find.byType(UiKitView))
            .any((v) => v.viewType == 'marco_movie/ios26_dock'),
        isFalse,
      );

      // Pop back to Home: Home's native Dock and controls remount immediately on
      // frame 0 while the exiting route's UiKitViews unmount.
      navState.pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        tester
            .widgetList<UiKitView>(find.byType(UiKitView))
            .any((v) => v.viewType == 'marco_movie/ios26_dock'),
        isTrue,
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widgetList<UiKitView>(find.byType(UiKitView))
            .any((v) => v.viewType == 'marco_movie/ios26_dock'),
        isTrue,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'iOS 26 route transitions render exact-size zero-BackdropFilter placeholders with zero jump',
    (tester) async {
      IosLiquidGlassBridge.setAvailableForTest(true);
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      const dockItems = <(IconData, IconData, String)>[
        (CupertinoIcons.play_rectangle, CupertinoIcons.play_rectangle_fill, '主页'),
        (CupertinoIcons.dot_radiowaves_left_right, CupertinoIcons.dot_radiowaves_left_right, '直播'),
        (CupertinoIcons.square_stack_3d_up, CupertinoIcons.square_stack_3d_up_fill, '片库'),
        (CupertinoIcons.gear_alt, CupertinoIcons.gear_alt_fill, '设置'),
      ];
      const nativeItems = <IosNativeDockItem>[
        IosNativeDockItem(label: '主页', symbol: 'play.rectangle', selectedSymbol: 'play.rectangle.fill'),
        IosNativeDockItem(label: '直播', symbol: 'dot.radiowaves.left.and.right'),
        IosNativeDockItem(label: '片库', symbol: 'square.stack.3d.up', selectedSymbol: 'square.stack.3d.up.fill'),
        IosNativeDockItem(label: '设置', symbol: 'gearshape', selectedSymbol: 'gearshape.fill'),
      ];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                IosNativeGlassButton(
                  key: const ValueKey('test-source-btn'),
                  style: 'capsule',
                  symbol: 'square.3.layers.3d',
                  trailingSymbol: 'chevron.down',
                  label: '玩偶哥哥',
                  height: 36,
                  maxWidth: 180,
                  onTap: () {},
                  fallback: const SizedBox(width: 99, height: 22),
                ),
                IosNativeSegmentedControl(
                  key: const ValueKey('test-seg'),
                  segments: const ['推荐', '电影', '剧集'],
                  selectedIndex: 0,
                  height: 36,
                  onChanged: (_) {},
                  fallback: const SizedBox(height: 18),
                ),
              ],
            ),
            bottomNavigationBar: AppleLiquidGlassDock(
              selectedIndex: 0,
              onSelect: (_) {},
              isLandscape: false,
              items: dockItems,
              nativeItems: nativeItems,
              onSearch: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final restingBtnSize = tester.getSize(
        find.byKey(const ValueKey('test-source-btn')),
      );
      final restingSegSize = tester.getSize(
        find.byKey(const ValueKey('test-seg')),
      );
      final restingDockSize = tester.getSize(
        find.byType(AppleLiquidGlassDock),
      );

      // Push a route so IosNativeRouteGate swaps to iOS 26 transition placeholders.
      final nav = tester.state<NavigatorState>(find.byType(Navigator));
      nav.push<void>(
        buildApplePageRoute<void>(
          builder: (_) => const Scaffold(body: Center(child: Text('Next'))),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));

      expect(find.byType(UiKitView), findsNothing);
      expect(
        find.byKey(const ValueKey('ios26-glass-button-transition-placeholder')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('ios26-segmented-transition-placeholder')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('ios26-dock-transition-placeholder')),
        findsOneWidget,
      );
      expect(find.byType(BackdropFilter), findsNothing);

      // Geometry during transition must match resting UiKitView size to 0.0pt!
      expect(
        tester.getSize(find.byKey(const ValueKey('test-source-btn'))),
        restingBtnSize,
      );
      expect(
        tester.getSize(find.byKey(const ValueKey('test-seg'))),
        restingSegSize,
      );
      expect(
        tester.getSize(find.byType(AppleLiquidGlassDock)),
        restingDockSize,
      );
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'iOS 26 native mode mounts UISwitch and UISlider UiKitViews and Settings search finds deep panes',
    (tester) async {
      IosLiquidGlassBridge.setAvailableForTest(true);
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                IosSettingsSwitchRow(
                  title: '自动播放下一集',
                  value: true,
                  onChanged: (_) {},
                ),
                IosNativeSlider(
                  value: 0.68,
                  onChanged: (_) {},
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
      final types = tester
          .widgetList<UiKitView>(find.byType(UiKitView))
          .map((v) => v.viewType)
          .toList();
      expect(types, contains('marco_movie/ios26_switch'));
      expect(types, contains('marco_movie/ios26_slider'));

      // Switch back to fallback mode to verify Settings search & extensions category.
      IosLiquidGlassBridge.setAvailableForTest(false);
      final storage = await initTestStorage();
      await storage.saveConfig(
        '{"sites":[{"key":"test","name":"测试源","type":1,"api":"https://source.example/api"}]}',
      );
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
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.text('设置').last);
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('settings-category-extensions')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('ios-settings-search')), findsOneWidget);

      await tester.enterText(
        find.descendant(
          of: find.byKey(const ValueKey('ios-settings-search')),
          matching: find.byType(CupertinoTextField),
        ),
        '网关',
      );
      await tester.pumpAndSettle();
      expect(find.text('蜘蛛扩展与网关'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'bottom Dock renders bespoke animated vector icons for all 4 tabs and settles selection animations cleanly in Light & Dark',
    (tester) async {
      IosLiquidGlassBridge.setAvailableForTest(false);
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      const dockItems = <(IconData, IconData, String)>[
        (
          CupertinoIcons.play_rectangle,
          CupertinoIcons.play_rectangle_fill,
          '主页',
        ),
        (
          CupertinoIcons.dot_radiowaves_left_right,
          CupertinoIcons.dot_radiowaves_left_right,
          '直播',
        ),
        (
          CupertinoIcons.square_stack_3d_up,
          CupertinoIcons.square_stack_3d_up_fill,
          '片库',
        ),
        (CupertinoIcons.gear_alt, CupertinoIcons.gear_alt_fill, '设置'),
      ];
      final selectedIdx = ValueNotifier<int>(0);
      final themeMode = ValueNotifier<ThemeMode>(ThemeMode.dark);
      addTearDown(() {
        selectedIdx.dispose();
        themeMode.dispose();
      });

      await tester.pumpWidget(
        ValueListenableBuilder<ThemeMode>(
          valueListenable: themeMode,
          builder: (_, mode, __) => MaterialApp(
            themeMode: mode,
            theme: ThemeData.light(useMaterial3: true),
            darkTheme: ThemeData.dark(useMaterial3: true),
            home: Scaffold(
              bottomNavigationBar: Center(
                heightFactor: 1,
                child: ValueListenableBuilder<int>(
                  valueListenable: selectedIdx,
                  builder: (_, idx, __) => AppleLiquidGlassDock(
                    selectedIndex: idx,
                    onSelect: (next) => selectedIdx.value = next,
                    isLandscape: false,
                    items: dockItems,
                    onSearch: () {},
                  ),
                ),
              ),
              body: const SizedBox.expand(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      for (final mode in const [ThemeMode.dark, ThemeMode.light]) {
        themeMode.value = mode;
        await tester.pumpAndSettle();
        expect(find.byType(MarcoAnimatedDockIcon), findsNWidgets(4));
        for (final key in const [
          'marco-dock-icon-home',
          'marco-dock-icon-live',
          'marco-dock-icon-library',
          'marco-dock-icon-settings',
        ]) {
          expect(find.byKey(ValueKey(key)), findsOneWidget);
        }

        // Tap each tab in turn and verify mid-animation frame + clean settle.
        for (final label in const ['直播', '片库', '设置', '主页']) {
          await tester.tap(find.text(label));
          await tester.pump(const Duration(milliseconds: 120));
          expect(tester.takeException(), isNull);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        }
      }
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'IosLiquidGlassBridge root tab chrome sync, scroll minimize, visibility, and reverse callbacks work on iOS 26+ and no-op safely on iOS < 26',
    (tester) async {
      const items = <IosNativeDockItem>[
        IosNativeDockItem(
          label: '主页',
          symbol: 'play.rectangle',
          selectedSymbol: 'play.rectangle.fill',
          kind: 'home',
        ),
        IosNativeDockItem(
          label: '直播',
          symbol: 'dot.radiowaves.left.and.right',
          kind: 'live',
        ),
        IosNativeDockItem(
          label: '片库',
          symbol: 'square.stack.3d.up',
          selectedSymbol: 'square.stack.3d.up.fill',
          kind: 'library',
        ),
        IosNativeDockItem(
          label: '设置',
          symbol: 'gearshape',
          selectedSymbol: 'gearshape.fill',
          kind: 'settings',
        ),
      ];

      // 1. On iOS < 26 (unavailable), root tab chrome methods safely return false / no-op.
      IosLiquidGlassBridge.setAvailableForTest(false);
      final callsUnavailable = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(IosLiquidGlassBridge.channel, (call) async {
        callsUnavailable.add(call);
        return true;
      });
      final configuredOffline = await IosLiquidGlassBridge.configureRootTabChrome(
        items: items,
        onSearch: () {},
      );
      expect(configuredOffline, isFalse);
      await IosLiquidGlassBridge.setRootTabSelectedIndex(2);
      await IosLiquidGlassBridge.setRootTabMinimized(true, progress: 0.75);
      await IosLiquidGlassBridge.setRootTabVisible(false);
      expect(callsUnavailable, isEmpty);

      // 2. On iOS 26+ (available), verify full MethodChannel contract & incoming callbacks.
      IosLiquidGlassBridge.setAvailableForTest(true);
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(IosLiquidGlassBridge.channel, (call) async {
        calls.add(call);
        if (call.method == 'configureRootTabChrome') return true;
        return null;
      });

      int? selectedTab;
      var searchTapped = 0;
      var scrollTopTapped = 0;

      final configured = await IosLiquidGlassBridge.configureRootTabChrome(
        items: items,
        selectedIndex: 1,
        showSearch: true,
        visible: true,
        minimized: false,
        adaptiveTopOnWide: true,
        onSelect: (idx) => selectedTab = idx,
        onSearch: () => searchTapped++,
        onScrollToTop: () => scrollTopTapped++,
      );
      expect(configured, isTrue);

      await IosLiquidGlassBridge.setRootTabSelectedIndex(3, animated: true);
      await IosLiquidGlassBridge.setRootTabMinimized(true, progress: 0.62);
      await IosLiquidGlassBridge.setRootTabVisible(false, animated: true);

      expect(
        calls.map((c) => c.method).toList(),
        [
          'configureRootTabChrome',
          'setRootTabSelectedIndex',
          'setRootTabMinimized',
          'setRootTabVisible',
        ],
      );
      final cfgArgs = Map<String, dynamic>.from(calls[0].arguments as Map);
      expect((cfgArgs['items'] as List).length, 4);
      expect(cfgArgs['selectedIndex'], 1);
      expect(cfgArgs['showSearch'], isTrue);
      expect(cfgArgs['adaptiveTopOnWide'], isTrue);

      final minArgs = Map<String, dynamic>.from(calls[2].arguments as Map);
      expect(minArgs['minimized'], isTrue);
      expect(minArgs['progress'], closeTo(0.62, 0.001));

      final visArgs = Map<String, dynamic>.from(calls[3].arguments as Map);
      expect(visArgs['visible'], isFalse);
      expect(visArgs['animated'], isTrue);

      // Dispatch reverse calls from native Swift -> Dart.
      const codec = StandardMethodCodec();
      Future<void> sendIncoming(String method, dynamic arg) async {
        final envelope = codec.encodeMethodCall(MethodCall(method, arg));
        await TestDefaultBinaryMessengerBinding
            .instance.defaultBinaryMessenger
            .handlePlatformMessage(
          IosLiquidGlassBridge.channel.name,
          envelope,
          (_) {},
        );
      }

      await sendIncoming('rootTabSelected', 2);
      await sendIncoming('rootTabSearchTapped', null);
      await sendIncoming('rootTabScrollToTop', null);
      await sendIncoming('sceneActivationChanged', false);

      expect(selectedTab, 2);
      expect(searchTapped, 1);
      expect(scrollTopTapped, 1);
      expect(IosLiquidGlassBridge.isSceneActive, isFalse);

      await sendIncoming('sceneActivationChanged', true);
      expect(IosLiquidGlassBridge.isSceneActive, isTrue);

      // Reset clears test overrides & scene state cleanly.
      IosLiquidGlassBridge.setAvailableForTest(null);
      expect(IosLiquidGlassBridge.isSceneActive, isTrue);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'presentNativeContextMenu dispatches showMenuAtRect with anchorRect and handles selection or fallback',
    (tester) async {
      const menuItems = <IosNativeMenuItem>[
        IosNativeMenuItem(
          id: 'play',
          title: '立即播放',
          symbol: 'play.fill',
          section: 0,
        ),
        IosNativeMenuItem(
          id: 'delete',
          title: '删除记录',
          symbol: 'trash',
          destructive: true,
          section: 1,
        ),
      ];

      // Unavailable -> returns null immediately without calling channel.
      IosLiquidGlassBridge.setAvailableForTest(false);
      final skipped = await IosLiquidGlassBridge.presentNativeContextMenu(
        anchorRect: const Rect.fromLTWH(24, 120, 44, 44),
        items: menuItems,
      );
      expect(skipped, isNull);

      // Available -> dispatches showMenuAtRect and returns selected ID.
      IosLiquidGlassBridge.setAvailableForTest(true);
      MethodCall? captured;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(IosLiquidGlassBridge.channel, (call) async {
        captured = call;
        return 'play';
      });

      final picked = await IosLiquidGlassBridge.presentNativeContextMenu(
        anchorRect: const Rect.fromLTWH(24, 120, 44, 44),
        items: menuItems,
        title: '操作菜单',
      );
      expect(picked, 'play');
      expect(captured?.method, 'showMenuAtRect');
      final args = Map<String, dynamic>.from(captured!.arguments as Map);
      expect(args['title'], '操作菜单');
      expect((args['anchorRect'] as Map)['x'], 24.0);
      expect((args['anchorRect'] as Map)['y'], 120.0);
      expect((args['anchorRect'] as Map)['width'], 44.0);
      expect((args['anchorRect'] as Map)['height'], 44.0);
      expect((args['items'] as List).length, 2);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'IosNativeGlassButton supports prominent glass configuration on iOS 26+ and renders fallback on iOS < 26',
    (tester) async {
      IosLiquidGlassBridge.setAvailableForTest(true);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: IosNativeGlassButton(
              style: 'capsule',
              symbol: 'play.fill',
              label: '立即播放',
              prominent: true,
              onTap: () {},
              fallback: const Text('fallback-play'),
            ),
          ),
        ),
      );
      await tester.pump();
      final btnView = tester.widget<UiKitView>(find.byType(UiKitView));
      expect(btnView.viewType, 'marco_movie/ios26_glass_button');
      final params = btnView.creationParams as Map<dynamic, dynamic>;
      expect(params['prominent'], isTrue);
      expect(params['style'], 'capsule');
      expect(params['label'], '立即播放');

      // Switch to iOS < 26 -> renders fallback seamlessly.
      IosLiquidGlassBridge.setAvailableForTest(false);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: IosNativeGlassButton(
              style: 'capsule',
              symbol: 'play.fill',
              label: '立即播放',
              prominent: true,
              onTap: () {},
              fallback: const Text('fallback-play'),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(UiKitView), findsNothing);
      expect(find.text('fallback-play'), findsOneWidget);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'AdaptiveShell activates root-controller native UITabBar chrome when supported and hides on secondary push',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final storage = await initTestStorage();
      await storage.saveConfig(
        '{"sites":[{"key":"test","name":"测试片源","type":1,"api":"http://127.0.0.1:9999/api"}]}',
      );
      IosLiquidGlassBridge.setAvailableForTest(true);
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(IosLiquidGlassBridge.channel, (call) async {
        calls.add(call);
        if (call.method == 'configureRootTabChrome') {
          return true;
        }
        return null;
      });

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
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
      await tester.pumpAndSettle();

      final configCall =
          calls.where((c) => c.method == 'configureRootTabChrome').last;
      final configArgs = Map<String, dynamic>.from(configCall.arguments as Map);
      expect((configArgs['items'] as List).length, 4);
      // Fallback inline dock must stay absent when native root tab host owns chrome.
      expect(find.byType(AppleLiquidGlassDock), findsNothing);

      // Switching tabs via native bridge updates selected index.
      await tester.runAsync(() async {});
      calls.clear();
      await IosLiquidGlassBridge.channel.invokeMethod<void>(
        'setRootTabSelectedIndex',
        3,
      );
      // Simulate native root tab selection callback via platform message.
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      await messenger.handlePlatformMessage(
        IosLiquidGlassBridge.channel.name,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('rootTabSelected', 3),
        ),
        (_) {},
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('ios-settings-root')), findsOneWidget);

      // Pushing a secondary drawer hides root native tab chrome, popping restores it.
      await tester.tap(find.byKey(const ValueKey('settings-category-about')));
      await tester.pumpAndSettle();
      final visCallsDuringPush = calls
          .where((c) => c.method == 'setRootTabVisible')
          .map((c) => (c.arguments as Map)['visible'])
          .toList();
      expect(visCallsDuringPush, contains(false));

      Navigator.of(
        tester.element(find.byKey(const ValueKey('settings-page-about'))),
      ).pop();
      await tester.pumpAndSettle();
      expect(
        (calls
                .where((c) => c.method == 'setRootTabVisible')
                .last
                .arguments as Map)['visible'],
        isTrue,
      );
      await tester.pumpWidget(const SizedBox());
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );
}
