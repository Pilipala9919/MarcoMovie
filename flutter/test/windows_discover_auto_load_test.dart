import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/core/quark_account.dart';
import 'package:marco_movie/core/quark_drive.dart';
import 'package:marco_movie/ui/adaptive_shell.dart';
import 'package:marco_movie/ui/quark_library_sheet.dart';
import 'package:marco_movie/ui/windows_appearance.dart';

import 'test_storage_helper.dart';

class _WindowsPagingFixtureClient extends CmsClient {
  _WindowsPagingFixtureClient({
    required this.pages,
    this.failPagesOnce = const <int>{},
  });

  final Map<int, List<CmsVideo>> pages;
  final Set<int> failPagesOnce;
  final Set<int> _failedOnce = <int>{};
  final List<int> requestedCategoryPages = <int>[];

  int get _pageCount => pages.length;

  @override
  Future<(List<CmsCategory>, CmsListing)> fetchHome(CmsSite site) async => (
        const [
          CmsCategory(id: '1', name: '电影'),
          CmsCategory(id: '2', name: '电视剧'),
        ],
        CmsListing(
          page: 1,
          pageCount: _pageCount,
          videos: pages[1] ?? const [],
        ),
      );

  @override
  Future<CmsListing> fetchCategory(
    CmsSite site,
    String categoryId,
    int page, {
    List<String> childIds = const [],
    CmsFilter? filter,
  }) async {
    requestedCategoryPages.add(page);
    if (failPagesOnce.contains(page) && _failedOnce.add(page)) {
      throw const SocketException('模拟翻页网络超时');
    }
    return CmsListing(
      page: page,
      pageCount: _pageCount,
      videos: pages[page] ?? const [],
      sourceFiltered: true,
    );
  }
}

class _QuarkPagingDrive extends QuarkDriveClient {
  _QuarkPagingDrive()
      : super(
          accounts: QuarkAccountProvider(
            readCredential: () => '',
            writeCredential: (_) {},
            httpClient: MockClient(
              (_) async => throw StateError('Unexpected HTTP'),
            ),
          ),
          httpClient: MockClient(
            (_) async => throw StateError('Unexpected HTTP'),
          ),
        );

  final List<int> requestedPages = <int>[];

  @override
  Future<CmsListing> listOwned({String folder = '0', int page = 1}) async {
    requestedPages.add(page);
    if (page == 1) {
      return CmsListing(
        page: 1,
        pageCount: 2,
        videos: [
          for (var i = 1; i <= 12; i++)
            CmsVideo(
              id: 'mmquark://owned?account=a&fid=p1_$i',
              title: '夸克第一页视频 $i',
              remarks: '1.0 GB',
            ),
        ],
      );
    }
    return CmsListing(
      page: 2,
      pageCount: 2,
      videos: const [
        CmsVideo(
          id: 'mmquark://owned?account=a&fid=p2_1',
          title: '夸克自动加载第二页视频',
          remarks: '2.0 GB',
        ),
      ],
    );
  }
}

List<CmsVideo> _makePageVideos(int page, int count) => [
      for (var i = 1; i <= count; i++)
        CmsVideo(
          id: 'p${page}_$i',
          title: '第$page页影片 $i',
          year: '2026',
          remarks: 'HD',
        ),
    ];

Future<void> _pumpWindowsDiscover(
  WidgetTester tester,
  _WindowsPagingFixtureClient client, {
  Size size = const Size(1280, 800),
}) async {
  await tester.binding.setSurfaceSize(size);
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final storage = await initTestStorage();
  await tester.runAsync(
    () => storage.saveConfig(
      jsonEncode({
        'sites': [
          {
            'key': 'owned',
            'name': '测试片源',
            'type': 1,
            'api': 'https://owned.invalid/api',
          },
        ],
      }),
    ),
  );
  final appearance = WindowsAppearance(Directory.systemTemp);
  addTearDown(appearance.dispose);

  await tester.pumpWidget(
    MaterialApp(
      builder: (_, child) =>
          WindowsAppearanceScope(controller: appearance, child: child!),
      home: AdaptiveShell(
        storage: storage,
        client: client,
        onSetPreventCloseForTest: (_) async {},
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('发现').first);
  await tester.pumpAndSettle();
}

Future<void> _sendWheel(
  WidgetTester tester,
  Offset position,
  double deltaY,
) async {
  await tester.sendEventToBinding(
    PointerScrollEvent(
      position: position,
      scrollDelta: Offset(0, deltaY),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final windowsOnly = TargetPlatformVariant.only(TargetPlatform.windows);

  testWidgets(
    'Windows Discover hides Load More button and auto-loads pages when scrolling down',
    variant: windowsOnly,
    (tester) async {
      final client = _WindowsPagingFixtureClient(
        pages: {
          1: _makePageVideos(1, 24),
          2: _makePageVideos(2, 24),
          3: _makePageVideos(3, 12),
        },
      );
      await _pumpWindowsDiscover(tester, client);

      expect(find.text('加载更多'), findsNothing);
      expect(find.text('加载更多影片'), findsNothing);
      expect(client.requestedCategoryPages, isEmpty);

      final scrollFinder =
          find.byKey(const PageStorageKey('windows-discover-list'));
      expect(scrollFinder, findsOneWidget);

      // Scroll down to near the bottom -> page 2 loads automatically.
      for (var i = 0; i < 8 && !client.requestedCategoryPages.contains(2); i++) {
        await tester.drag(scrollFinder, const Offset(0, -500));
        await tester.pumpAndSettle();
      }
      expect(client.requestedCategoryPages, [2]);
      expect(find.text('加载更多'), findsNothing);

      // Keep scrolling down -> page 3 loads automatically and appears.
      for (var i = 0; i < 12 && !client.requestedCategoryPages.contains(3); i++) {
        await tester.drag(scrollFinder, const Offset(0, -600));
        await tester.pumpAndSettle();
      }
      expect(client.requestedCategoryPages, [2, 3]);

      await tester.scrollUntilVisible(
        find.text('第3页影片 12'),
        400,
        scrollable: find.descendant(
          of: scrollFinder,
          matching: find.byType(Scrollable),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('第3页影片 12'), findsOneWidget);

      // Additional downward scroll at the last page must not request page 4.
      await _sendWheel(tester, const Offset(640, 420), 240);
      expect(client.requestedCategoryPages, [2, 3]);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'Windows Discover auto-loads on downward mouse wheel even when page 1 fits viewport',
    variant: windowsOnly,
    (tester) async {
      final client = _WindowsPagingFixtureClient(
        pages: {
          1: _makePageVideos(1, 3),
          2: _makePageVideos(2, 4),
        },
      );
      await _pumpWindowsDiscover(tester, client);

      expect(find.text('加载更多'), findsNothing);
      expect(client.requestedCategoryPages, isEmpty);

      // Upward wheel scroll must not trigger next-page fetch.
      await _sendWheel(tester, const Offset(640, 420), -120);
      expect(client.requestedCategoryPages, isEmpty);

      // Downward wheel scroll triggers page 2 even though maxScrollExtent == 0.
      await _sendWheel(tester, const Offset(640, 420), 120);
      expect(client.requestedCategoryPages, [2]);
      expect(find.text('第2页影片 1'), findsOneWidget);
      expect(find.text('加载更多'), findsNothing);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'Windows Discover pauses auto-load on error and resumes after retry',
    variant: windowsOnly,
    (tester) async {
      final client = _WindowsPagingFixtureClient(
        pages: {
          1: _makePageVideos(1, 18),
          2: _makePageVideos(2, 18),
          3: _makePageVideos(3, 6),
        },
        failPagesOnce: const {2},
      );
      await _pumpWindowsDiscover(tester, client);

      final scrollFinder =
          find.byKey(const PageStorageKey('windows-discover-list'));

      for (var i = 0; i < 8 && client.requestedCategoryPages.isEmpty; i++) {
        await tester.drag(scrollFinder, const Offset(0, -500));
        await tester.pumpAndSettle();
      }
      expect(client.requestedCategoryPages, [2]);

      // Further downward scrolling while an error is shown must not spam retries.
      await _sendWheel(tester, const Offset(640, 420), 200);
      expect(client.requestedCategoryPages, [2]);

      await tester.scrollUntilVisible(
        find.text('重试加载更多'),
        300,
        scrollable: find.descendant(
          of: scrollFinder,
          matching: find.byType(Scrollable),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('重试加载更多'), findsOneWidget);
      expect(find.text('加载更多'), findsNothing);

      // Clicking retry recovers page 2, and further scrolling auto-loads page 3.
      await tester.tap(find.text('重试加载更多'));
      await tester.pumpAndSettle();
      expect(client.requestedCategoryPages, [2, 2]);
      expect(find.text('重试加载更多'), findsNothing);

      for (var i = 0; i < 10 && !client.requestedCategoryPages.contains(3); i++) {
        await tester.drag(scrollFinder, const Offset(0, -600));
        await tester.pumpAndSettle();
      }
      expect(client.requestedCategoryPages, [2, 2, 3]);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'Windows Quark library sheet hides Load More button and auto-loads on downward scroll',
    variant: windowsOnly,
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 800));
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final storage = await initTestStorage();
      final drive = _QuarkPagingDrive();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () =>
                    showQuarkLibrarySheet(context, storage, drive: drive),
                child: const Text('打开我的夸克'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开我的夸克'));
      await tester.pumpAndSettle();

      expect(drive.requestedPages, [1]);
      expect(find.text('加载更多'), findsNothing);

      final listFinder = find.byType(ListView).first;
      for (var i = 0; i < 6 && !drive.requestedPages.contains(2); i++) {
        await tester.drag(listFinder, const Offset(0, -400));
        await tester.pumpAndSettle();
      }
      expect(drive.requestedPages, [1, 2]);

      await tester.scrollUntilVisible(
        find.text('夸克自动加载第二页视频'),
        250,
        scrollable: find.descendant(
          of: listFinder,
          matching: find.byType(Scrollable),
        ),
      );
      expect(find.text('夸克自动加载第二页视频'), findsOneWidget);
      expect(find.text('加载更多'), findsNothing);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
}
