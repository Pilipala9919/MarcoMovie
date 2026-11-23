import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/ui/adaptive_shell.dart';
import 'package:marco_movie/ui/apple_theme.dart';
import 'package:marco_movie/ui/detail_screen.dart';
import 'package:marco_movie/ui/ios_liquid_glass.dart';
import 'package:marco_movie/ui/ios_search_page.dart';
import 'package:marco_movie/ui/ios_settings.dart';

import 'test_storage_helper.dart';

class _DuoTestCmsClient extends CmsClient {
  @override
  Future<CmsVideo> fetchDetail(CmsSite site, CmsVideo video) async {
    return CmsVideo(
      id: video.id,
      title: video.title,
      year: video.year,
      area: video.area,
      remarks: video.remarks,
      description: video.description.isEmpty
          ? '用于验证 iPhone Duo 外屏、内屏展开与分屏布局的剧情简介文本。'
          : video.description,
      lines: const [
        CmsLine(
          name: '4K极速线路',
          episodes: [
            CmsEpisode(name: '第01集', url: 'https://media.example/1.m3u8'),
            CmsEpisode(name: '第02集', url: 'https://media.example/2.m3u8'),
            CmsEpisode(name: '第03集', url: 'https://media.example/3.m3u8'),
            CmsEpisode(name: '第04集', url: 'https://media.example/4.m3u8'),
          ],
        ),
      ],
    );
  }

  @override
  Future<(List<CmsCategory>, CmsListing)> fetchHome(CmsSite site) async {
    return (
      const [
        CmsCategory(id: '1', name: '电影'),
        CmsCategory(id: '2', name: '剧集'),
        CmsCategory(id: '3', name: '动漫'),
      ],
      const CmsListing(
        videos: [
          CmsVideo(
            id: 'duo-1',
            title: '双屏漫游指南',
            year: '2026',
            area: '中国大陆',
            remarks: '4K HDR',
            description: '在折叠与展开之间丝滑切换的沉浸式影院体验。',
          ),
          CmsVideo(
            id: 'duo-2',
            title: '光影折痕',
            year: '2026',
            area: '美国',
            remarks: '更新至第10集',
          ),
          CmsVideo(
            id: 'duo-3',
            title: '海风与星空',
            year: '2026',
            area: '日本',
            remarks: 'HD',
          ),
          CmsVideo(
            id: 'duo-4',
            title: '极夜航线',
            year: '2026',
            area: '英国',
            remarks: '杜比视界',
          ),
        ],
      ),
    );
  }

  @override
  Future<List<LiveGroup>> fetchLiveGroups(LiveSource source) async {
    return const [
      LiveGroup(
        name: '央视',
        channels: [
          LiveChannel(
            name: 'CCTV1',
            group: '央视',
            urls: ['https://live.example/cctv1.m3u8'],
          ),
          LiveChannel(
            name: 'CCTV5',
            group: '央视',
            urls: ['https://live.example/cctv5.m3u8'],
          ),
          LiveChannel(
            name: 'CCTV6',
            group: '央视',
            urls: ['https://live.example/cctv6.m3u8'],
          ),
        ],
      ),
    ];
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const duoOuterPortrait = Size(466, 678);
  const duoOuterLandscape = Size(678, 466);
  const duoInnerPortrait = Size(669, 951);
  const duoInnerLandscape = Size(951, 669);
  const duoSplitNarrow = Size(320, 951);
  const standardPhone = Size(390, 844);

  const allDuoViewports = <(String, Size)>[
    ('iPhone Duo 5.4" Outer Portrait (466x678)', duoOuterPortrait),
    ('iPhone Duo 5.4" Outer Landscape (678x466)', duoOuterLandscape),
    ('iPhone Duo 7.6" Inner Portrait (669x951)', duoInnerPortrait),
    ('iPhone Duo 7.6" Inner Landscape (951x669)', duoInnerLandscape),
    ('iPhone Duo Split View Narrow (320x951)', duoSplitNarrow),
  ];

  group('AppleViewportLayout geometry classification', () {
    test('classifies standard iPhone, iPhone Duo outer/inner, and Split View',
        () {
      const std = AppleViewportLayout(standardPhone);
      expect(std.isShortPortrait, isFalse);
      expect(std.isExpandedPortrait, isFalse);
      expect(std.isCompactSplit, isFalse);
      expect(std.prefersWideDetail, isFalse);
      expect(std.iosHomeHeroHeight(844), inInclusiveRange(500.0, 620.0));
      expect(std.posterGridExtent(useSidebar: false), 132.0);

      const outerP = AppleViewportLayout(duoOuterPortrait);
      expect(outerP.isShortPortrait, isTrue);
      expect(outerP.isExpandedPortrait, isFalse);
      expect(outerP.prefersWideDetail, isFalse);
      expect(outerP.iosHomeHeroHeight(678), inInclusiveRange(360.0, 470.0));
      expect(outerP.posterGridExtent(useSidebar: false), 144.0);

      const outerL = AppleViewportLayout(duoOuterLandscape);
      expect(outerL.isShortLandscape, isTrue);
      expect(outerL.isWideLandscape, isTrue);
      expect(outerL.prefersWideDetail, isTrue);

      const innerP = AppleViewportLayout(duoInnerPortrait);
      expect(innerP.isExpandedPortrait, isTrue);
      expect(innerP.isShortPortrait, isFalse);
      expect(innerP.prefersWideDetail, isFalse);
      expect(innerP.horizontalPadding(useSidebar: false), 24.0);
      expect(innerP.posterGridExtent(useSidebar: false), 162.0);
      expect(innerP.iosHomeHeroHeight(951), inInclusiveRange(500.0, 600.0));

      const innerL = AppleViewportLayout(duoInnerLandscape);
      expect(innerL.isWideLandscape, isTrue);
      expect(innerL.prefersWideDetail, isTrue);

      const split = AppleViewportLayout(duoSplitNarrow);
      expect(split.isCompactSplit, isTrue);
      expect(split.horizontalPadding(useSidebar: false), 12.0);
      expect(split.posterGridExtent(useSidebar: false), 148.0);
    });
  });

  group('iPhone Duo full widget matrix (Light + Dark)', () {
    setUp(() {
      IosLiquidGlassBridge.setAvailableForTest(false);
    });

    tearDown(() {
      IosLiquidGlassBridge.setAvailableForTest(false);
    });

    testWidgets(
      'AppleLiquidGlassDock renders with zero overflow across all iPhone Duo sizes and live fold/unfold in Light & Dark',
      (tester) async {
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
        final sizeNotifier = ValueNotifier<Size>(duoOuterPortrait);
        final themeNotifier = ValueNotifier<ThemeMode>(ThemeMode.light);
        final collapsedNotifier = ValueNotifier<bool>(false);
        addTearDown(() {
          sizeNotifier.dispose();
          themeNotifier.dispose();
          collapsedNotifier.dispose();
          tester.view.reset();
        });

        await tester.pumpWidget(
          ValueListenableBuilder<ThemeMode>(
            valueListenable: themeNotifier,
            builder: (_, mode, __) => MaterialApp(
              themeMode: mode,
              theme: ThemeData.light(useMaterial3: true),
              darkTheme: ThemeData.dark(useMaterial3: true),
              home: ValueListenableBuilder<Size>(
                valueListenable: sizeNotifier,
                builder: (_, size, __) {
                  final isLandscape = size.width > size.height;
                  return MediaQuery(
                    data: MediaQueryData(
                      size: size,
                      padding: const EdgeInsets.only(top: 34, bottom: 21),
                    ),
                    child: ValueListenableBuilder<bool>(
                      valueListenable: collapsedNotifier,
                      builder: (_, collapsed, __) => Scaffold(
                        extendBody: true,
                        bottomNavigationBar: isLandscape
                            ? null
                            : Center(
                                heightFactor: 1,
                                child: AppleLiquidGlassDock(
                                  selectedIndex: 0,
                                  onSelect: (_) {},
                                  isLandscape: false,
                                  items: dockItems,
                                  onSearch: () {},
                                  onScrollToTop: () {},
                                  collapsed: collapsed,
                                ),
                              ),
                        body: Stack(
                          fit: StackFit.expand,
                          children: [
                            const SizedBox.expand(),
                            if (isLandscape)
                              Positioned(
                                top: 0,
                                bottom: 0,
                                right: 0,
                                child: Center(
                                  child: AppleLiquidGlassDock(
                                    selectedIndex: 0,
                                    onSelect: (_) {},
                                    isLandscape: true,
                                    items: dockItems,
                                    onSearch: () {},
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        );

        for (final mode in const [ThemeMode.light, ThemeMode.dark]) {
          themeNotifier.value = mode;
          for (final (_, size) in allDuoViewports) {
            tester.view.physicalSize = size;
            tester.view.devicePixelRatio = 1.0;
            sizeNotifier.value = size;
            collapsedNotifier.value = false;
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);

            if (size.width <= size.height) {
              final expandedRect = tester.getRect(
                find.byType(AppleLiquidGlassDock),
              );
              collapsedNotifier.value = true;
              await tester.pumpAndSettle();
              expect(tester.takeException(), isNull);
              final collapsedRect = tester.getRect(
                find.byType(AppleLiquidGlassDock),
              );
              expect(
                collapsedRect.height,
                closeTo(expandedRect.height, 1.0),
              );
              expect(
                collapsedRect.bottom,
                closeTo(expandedRect.bottom, 1.0),
              );
            }
          }
        }
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    testWidgets(
      'DetailScreen adapts cleanly across outer cover, unfolded inner, landscape, and Split View in Light & Dark',
      (tester) async {
        final storage = await initTestStorage();
        final client = _DuoTestCmsClient();
        const site = CmsSite(
          key: 'duo_site',
          name: '双屏测试超长片源名称',
          type: 1,
          api: 'https://source.example/api',
        );
        const video = CmsVideo(
          id: 'duo-1',
          title: '双屏漫游指南：折叠屏全适配',
          year: '2026',
          area: '中国大陆',
          remarks: '4K HDR',
        );

        final themeMode = ValueNotifier<ThemeMode>(ThemeMode.light);
        addTearDown(() {
          themeMode.dispose();
          tester.view.reset();
        });

        tester.view.physicalSize = duoOuterPortrait;
        tester.view.devicePixelRatio = 1.0;

        await tester.pumpWidget(
          ValueListenableBuilder<ThemeMode>(
            valueListenable: themeMode,
            builder: (_, mode, __) => MaterialApp(
              themeMode: mode,
              theme: ThemeData.light(useMaterial3: true),
              darkTheme: ThemeData.dark(useMaterial3: true),
              home: DetailScreen(
                client: client,
                storage: storage,
                site: site,
                initialVideo: video,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('双屏漫游指南：折叠屏全适配'), findsOneWidget);
        expect(tester.takeException(), isNull);

        for (final mode in const [ThemeMode.light, ThemeMode.dark]) {
          themeMode.value = mode;
          for (final (_, size) in allDuoViewports) {
            tester.view.physicalSize = size;
            tester.view.devicePixelRatio = 1.0;
            await tester.pumpAndSettle();
            expect(find.text('双屏漫游指南：折叠屏全适配'), findsOneWidget);
            expect(tester.takeException(), isNull);
          }
        }
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    testWidgets(
      'IosGlobalSearchPage and IosSettingsPage adapt cleanly across all iPhone Duo sizes in Light & Dark',
      (tester) async {
        final storage = await initTestStorage();
        final client = _DuoTestCmsClient();
        const site = CmsSite(
          key: 'duo_site',
          name: '双屏测试源',
          type: 1,
          api: 'https://source.example/api',
        );
        const videos = [
          CmsVideo(id: '1', title: '影片一', year: '2026'),
          CmsVideo(id: '2', title: '影片二', year: '2026'),
          CmsVideo(id: '3', title: '影片三', year: '2026'),
          CmsVideo(id: '4', title: '影片四', year: '2026'),
        ];
        final queryCtrl = TextEditingController();
        final revision = ValueNotifier<int>(0);
        final themeMode = ValueNotifier<ThemeMode>(ThemeMode.light);
        addTearDown(() {
          queryCtrl.dispose();
          revision.dispose();
          themeMode.dispose();
          tester.view.reset();
        });

        await tester.pumpWidget(
          ValueListenableBuilder<ThemeMode>(
            valueListenable: themeMode,
            builder: (_, mode, __) => MaterialApp(
              themeMode: mode,
              theme: ThemeData.light(useMaterial3: true),
              darkTheme: ThemeData.dark(useMaterial3: true),
              home: IosGlobalSearchPage(
                controller: queryCtrl,
                storage: storage,
                client: client,
                stateRevision: revision,
                readSnapshot: () => GlobalSearchSnapshot(
                  isPrivate: false,
                  searching: false,
                  searchPerformed: false,
                  searchKeyword: '',
                  siteFilterKey: '',
                  searchEpoch: 0,
                  results: const [],
                  notices: const {},
                  verificationSites: const {},
                  visibleSupportedSites: const [site],
                  activeSite: site,
                  homeHotVideos: videos,
                ),
                sourceLabelOf: (s) => s.name,
                onSearch: (_) {},
                onResetSearch: () {},
                onSiteFilterChanged: (_) {},
                onRetryVerifiedSearch: (_) async {},
                onOpenVideoDetail: (_, __) {},
                buildVideoCard: (s, v, {badge, onTap}) => ColoredBox(
                  color: Colors.blueGrey,
                  child: Center(child: Text(v.title)),
                ),
              ),
            ),
          ),
        );

        for (final mode in const [ThemeMode.light, ThemeMode.dark]) {
          themeMode.value = mode;
          for (final (_, size) in allDuoViewports) {
            tester.view.physicalSize = size;
            tester.view.devicePixelRatio = 1.0;
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
          }
        }

        // Now verify IosSettingsPage across all iPhone Duo sizes in Light & Dark.
        await tester.pumpWidget(
          ValueListenableBuilder<ThemeMode>(
            valueListenable: themeMode,
            builder: (_, mode, __) => MaterialApp(
              themeMode: mode,
              theme: ThemeData.light(useMaterial3: true),
              darkTheme: ThemeData.dark(useMaterial3: true),
              home: Scaffold(
                body: IosSettingsPage(
                  onChanged: () {},
                  pages: (_) => const [
                    SettingsPane(
                      'appearance',
                      '外观与显示',
                      '主题、外屏与内屏布局',
                      CupertinoIcons.paintbrush_fill,
                      AppleColors.systemBlue,
                      trailingText: '跟随系统',
                      sectionGroup: 'appearance',
                      content: SizedBox.shrink(),
                    ),
                    SettingsPane(
                      'playback',
                      '播放与渲染',
                      '硬解、代理与折叠连续播放',
                      CupertinoIcons.play_circle_fill,
                      AppleColors.systemGreen,
                      trailingText: '自动',
                      sectionGroup: 'playback',
                      content: SizedBox.shrink(),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );

        for (final mode in const [ThemeMode.light, ThemeMode.dark]) {
          themeMode.value = mode;
          for (final (_, size) in allDuoViewports) {
            tester.view.physicalSize = size;
            tester.view.devicePixelRatio = 1.0;
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
          }
        }
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    testWidgets(
      'AdaptiveShell preserves tab state with zero overflow across live iPhone Duo fold/unfold/split transitions in Light & Dark',
      (tester) async {
        final storage = await initTestStorage();
        final client = _DuoTestCmsClient();
        await storage.saveConfig(
          '{"sites":[{"key":"duo_site","name":"双屏影院源","type":1,"api":"https://source.example/api"}],'
          '"lives":[{"name":"央视测试","url":"https://live.example/live.m3u"}]}',
        );

        final themeMode = ValueNotifier<ThemeMode>(ThemeMode.light);
        addTearDown(() {
          themeMode.dispose();
          tester.view.reset();
        });

        tester.view.physicalSize = duoOuterPortrait;
        tester.view.devicePixelRatio = 1.0;

        await tester.pumpWidget(
          ValueListenableBuilder<ThemeMode>(
            valueListenable: themeMode,
            builder: (_, mode, __) => MaterialApp(
              themeMode: mode,
              theme: ThemeData.light(useMaterial3: true),
              darkTheme: ThemeData.dark(useMaterial3: true),
              home: AdaptiveShell(client: client, storage: storage),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);

        // Verify Home tab hero height respects compact 5.4" outer cover (`<= 470pt`).
        final heroFinder = find.byKey(const ValueKey('ios-home-immersive-hero'));
        expect(heroFinder, findsOneWidget);
        expect(
          tester.getSize(heroFinder).height,
          lessThanOrEqualTo(470.0),
        );

        // Verify Rex-style Hero bottom transition in BOTH Light & Dark Mode:
        // - ZERO rounded sheet cap (`ios-hero-light-sheet-cap` removed).
        // - `ios-hero-top-ambient-aura` lives strictly in Layer 0 BEHIND
        //   CustomScrollView (NOT inside `ios-home-immersive-hero` / Sliver 0,
        //   eliminating Sliver paint-order fog over the first shelf header!).
        // - `ios-hero-bottom-ambient-gradient` uses an 8-stop single-color
        //   smoothstep dissolve whose solid end color matches Layer 0's solid
        //   color pixel-for-pixel, and Layer 0 dissolves cleanly to alpha 0.0.
        void expectSeamlessHeroBottomMelt({required bool dark}) {
          expect(
            find.byKey(const ValueKey('ios-hero-light-sheet-cap')),
            findsNothing,
          );
          final auraFinder =
              find.byKey(const ValueKey('ios-hero-top-ambient-aura'));
          expect(auraFinder, findsOneWidget);
          expect(
            find.descendant(of: heroFinder, matching: auraFinder),
            findsNothing,
          );

          final auraBox = tester.widget<DecoratedBox>(auraFinder);
          final auraGrad =
              (auraBox.decoration as BoxDecoration).gradient! as LinearGradient;
          final auraSolidColor = auraGrad.colors.first;
          expect(auraGrad.colors[1], equals(auraSolidColor));
          expect(auraGrad.colors.last.a, closeTo(0.0, 0.001));

          final bottomBox = tester.widget<DecoratedBox>(
            find.byKey(const ValueKey('ios-hero-bottom-ambient-gradient')),
          );
          final bottomGrad =
              (bottomBox.decoration as BoxDecoration).gradient!
                  as LinearGradient;
          expect(bottomGrad.colors.length, greaterThanOrEqualTo(8));
          expect(bottomGrad.colors.first.a, closeTo(0.0, 0.001));
          expect(bottomGrad.colors.last, equals(auraSolidColor));
          expect(bottomGrad.colors.last.a, closeTo(1.0, 0.001));
          if (dark) {
            expect(auraSolidColor.computeLuminance(), lessThanOrEqualTo(0.15));
          } else {
            expect(
              auraSolidColor.computeLuminance(),
              inInclusiveRange(0.04, 0.72),
            );
          }
        }

        expectSeamlessHeroBottomMelt(dark: false);
        themeMode.value = ThemeMode.dark;
        await tester.pumpAndSettle();
        expectSeamlessHeroBottomMelt(dark: true);
        themeMode.value = ThemeMode.light;
        await tester.pumpAndSettle();

        // Live unfold to 7.6" inner portrait -> landscape -> Split View -> fold back!
        for (final mode in const [ThemeMode.light, ThemeMode.dark]) {
          themeMode.value = mode;
          for (final (_, size) in allDuoViewports) {
            tester.view.physicalSize = size;
            tester.view.devicePixelRatio = 1.0;
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
          }
        }

        // Switch to Live tab and verify fold/unfold/Split View with zero overflow.
        tester.view.physicalSize = duoOuterPortrait;
        await tester.pumpAndSettle();
        await tester.tap(find.text('直播').last);
        await tester.pumpAndSettle();
        for (final (_, size) in allDuoViewports) {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1.0;
          await tester.pumpAndSettle();
          expect(find.text('电视直播'), findsOneWidget);
          expect(tester.takeException(), isNull);
        }

        // Switch to Library tab and verify Split View + Unfolded portrait.
        tester.view.physicalSize = duoInnerPortrait;
        await tester.pumpAndSettle();
        await tester.tap(find.text('片库').last);
        await tester.pumpAndSettle();
        for (final size in const [
          duoSplitNarrow,
          duoOuterPortrait,
          duoInnerPortrait,
          duoInnerLandscape,
        ]) {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1.0;
          await tester.pumpAndSettle();
          expect(find.text('我的片库'), findsOneWidget);
          expect(tester.takeException(), isNull);
        }

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );
  });
}
