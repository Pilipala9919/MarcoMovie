import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/core/storage_service.dart';
import 'package:marco_movie/ui/adaptive_shell.dart';
import 'package:marco_movie/ui/windows_title_bar.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

class _PagingFixtureClient extends CmsClient {
  int categoryCalls = 0;

  @override
  Future<(List<CmsCategory>, CmsListing)> fetchHome(CmsSite site) async {
    return (
      const [
        CmsCategory(id: '1', name: '电影'),
        CmsCategory(id: '2', name: '剧集'),
      ],
      CmsListing(
        page: 1,
        pageCount: 3,
        videos: [
          for (int i = 1; i <= 12; i++)
            CmsVideo(id: 'p1_$i', title: '首页影片 $i', year: '2026'),
        ],
      ),
    );
  }

  @override
  Future<CmsListing> fetchCategory(
    CmsSite site,
    String categoryId,
    int page, {
    List<String> childIds = const [],
    CmsFilter? filter,
  }) async {
    categoryCalls++;
    if (page == 2) {
      return CmsListing(
        page: 2,
        pageCount: 3,
        videos: [
          for (int i = 1; i <= 6; i++)
            CmsVideo(id: 'p2_$i', title: '自动翻页影片 $i', year: '2026'),
        ],
      );
    }
    // Page 3 returns duplicate items to verify infinite-loop guard
    return CmsListing(
      page: page,
      pageCount: 99,
      videos: [
        for (int i = 1; i <= 6; i++)
          CmsVideo(id: 'p2_$i', title: '自动翻页影片 $i', year: '2026'),
      ],
    );
  }
}

void main() {
  test(
    'per-video intro/outro skip records are independent, local-only, private-isolated, and default to current playback time',
    () async {
      SharedPreferences.setMockInitialValues({});
      final storage = await StorageService.init();

      await storage.setVideoSkipIntroSec('site_a', 'vod_1', 85);
      await storage.setVideoSkipOutroSec('site_a', 'vod_1', 110);
      await storage.setVideoSkipIntroSec('site_a', 'vod_2', 42);

      expect(storage.getVideoSkipIntroSec('site_a', 'vod_1'), 85);
      expect(storage.getVideoSkipOutroSec('site_a', 'vod_1'), 110);
      expect(storage.getVideoSkipIntroSec('site_a', 'vod_2'), 42);
      expect(storage.getVideoSkipOutroSec('site_a', 'vod_2'), 0);
      expect(storage.getVideoSkipIntroSec('site_b', 'vod_1'), 0);
      expect(storage.countVideoSkipRecords(), 2);

      // Must NOT leak into cross-device backup or cloud sync payloads
      final backup = storage.exportBackupJson();
      expect(backup.contains(StorageService.keyVideoSkipRecords), isFalse);
      expect(backup.contains('vod_1'), isFalse);
      final syncPayload = storage.exportSyncPayload();
      expect(syncPayload.contains(StorageService.keyVideoSkipRecords), isFalse);

      // Private space isolation: kept in memory only and cleared on exit
      await storage.setVideoSkipIntroSec(
        'priv_site',
        'secret_vod',
        65,
        isPrivate: true,
      );
      expect(
        storage.getVideoSkipIntroSec('priv_site', 'secret_vod', isPrivate: true),
        65,
      );
      expect(storage.countVideoSkipRecords(forPrivate: true), 1);
      expect(storage.countVideoSkipRecords(forPrivate: false), 2);
      storage.clearPrivateVideoSkipRecords();
      expect(
        storage.getVideoSkipIntroSec('priv_site', 'secret_vod', isPrivate: true),
        0,
      );

      // Default to current playback time first when opening skip sheet
      expect(
        StorageService.defaultSkipSecondsFromPlayback(
          isIntro: true,
          savedSec: 30,
          position: const Duration(minutes: 1, seconds: 28),
          duration: const Duration(minutes: 45),
        ),
        88,
      );
      expect(
        StorageService.defaultSkipSecondsFromPlayback(
          isIntro: false,
          savedSec: 40,
          position: const Duration(minutes: 42, seconds: 50),
          duration: const Duration(minutes: 45),
        ),
        130,
      );
      // Falls back to savedSec when position is 0 or remaining exceeds 10 min
      expect(
        StorageService.defaultSkipSecondsFromPlayback(
          isIntro: true,
          savedSec: 30,
          position: Duration.zero,
          duration: const Duration(minutes: 45),
        ),
        30,
      );
      expect(
        StorageService.defaultSkipSecondsFromPlayback(
          isIntro: false,
          savedSec: 40,
          position: const Duration(minutes: 10),
          duration: const Duration(minutes: 45),
        ),
        40,
      );
    },
  );

  test('independent playerAlwaysShowClock setting and cleanErrorMessage', () async {
    SharedPreferences.setMockInitialValues({});
    final storage = await StorageService.init();
    expect(storage.playerAlwaysShowClock, isFalse);
    await storage.setPlayerAlwaysShowClock(true);
    expect(storage.playerAlwaysShowClock, isTrue);

    expect(
      CmsClient.cleanErrorMessage(
        const FormatException('玩偶原网盘分享暂不可用，请检查网盘登录或分享状态'),
      ),
      '玩偶原网盘分享暂不可用，请检查网盘登录或分享状态',
    );
  });

  testWidgets(
    'home auto-loads next page without load-more button, collapses filters by default, and refreshes watch history reactively',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 600));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      SharedPreferences.setMockInitialValues({});
      final storage = await StorageService.init();
      await storage.saveConfig(
        jsonEncode({
          'sites': [
            {
              'key': 'demo',
              'name': '演示源',
              'type': 1,
              'api': 'https://cms.example/api.php/provide/vod/',
            },
          ],
        }),
        origin: 'https://cms.example/sub.json',
      );
      final client = _PagingFixtureClient();

      await tester.pumpWidget(
        MaterialApp(
          home: AdaptiveShell(storage: storage, client: client),
        ),
      );
      await tester.pumpAndSettle();

      // 1. No manual "加载更多影片" button; filter drawer is collapsed by default
      expect(find.text('加载更多影片'), findsNothing);
      expect(find.text('动作'), findsNothing);

      // 2. Selecting "电影" switches category with filter drawer still collapsed;
      // tapping the selected "电影" pill again expands the filter drawer!
      await tester.tap(find.text('电影').first);
      await tester.pumpAndSettle();
      expect(find.text('动作'), findsNothing);

      await tester.tap(find.text('电影').first);
      await tester.pumpAndSettle();
      expect(find.text('动作'), findsOneWidget);

      await tester.tap(find.text('电影').first);
      await tester.pumpAndSettle();
      expect(find.text('动作'), findsNothing);

      // 3. Switch back to recommend and scroll down -> auto-loads page 2
      await tester.tap(find.text('推荐').first);
      await tester.pumpAndSettle();
      for (var i = 0; i < 6; i++) {
        if (find.text('自动翻页影片 1').evaluate().isNotEmpty) break;
        await tester.drag(find.byType(CustomScrollView).first, const Offset(0, -600));
        await tester.pumpAndSettle();
      }
      expect(find.text('自动翻页影片 1'), findsOneWidget);

      // Scroll back to top and verify watch history updated in background
      // immediately refreshes Home "历史记录"
      for (var i = 0; i < 8; i++) {
        await tester.drag(find.byType(CustomScrollView).first, const Offset(0, 700));
        await tester.pumpAndSettle();
      }
      expect(find.text('历史记录'), findsNothing);
      await storage.upsertWatchHistory(
        const WatchHistoryEntry(
          site: 'demo',
          id: 'p1_1',
          title: '刚看完的新片',
          line: 'HD',
          episode: '正片',
          index: 0,
          position: 5400000,
          duration: 5400000,
          updated: 1700000000000,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('历史记录'), findsOneWidget);
      expect(find.text('刚看完的新片'), findsOneWidget);
    },
  );

  testWidgets(
    'WindowsImmersiveFrame renders caption buttons, applies top safe inset, and hides in fullscreen',
    (tester) async {
      const channel = MethodChannel('window_manager');
      final methods = <String>[];
      var isFull = false;
      var isMax = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            methods.add(call.method);
            if (call.method == 'isFullScreen') return isFull;
            if (call.method == 'isMaximized') return isMax;
            if (call.method == 'maximize') isMax = true;
            if (call.method == 'unmaximize') isMax = false;
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
      await tester.pump();

      expect(
        find.byKey(const ValueKey('windows-immersive-title-bar')),
        findsOneWidget,
      );
      expect(capturedTopPad, WindowsImmersiveFrame.titleBarHeight);

      await tester.tap(find.byKey(const ValueKey('win-titlebar-minimize')));
      await tester.pump();
      expect(methods, contains('minimize'));

      await tester.tap(find.byKey(const ValueKey('win-titlebar-maximize')));
      await tester.pump();
      expect(methods, contains('maximize'));

      // Simulate entering fullscreen via WindowListener
      (tester.state(find.byType(WindowsImmersiveFrame)) as WindowListener)
          .onWindowEnterFullScreen();
      await tester.pump();
      expect(
        find.byKey(const ValueKey('windows-immersive-title-bar')),
        findsNothing,
      );
      expect(capturedTopPad, 0);
    },
  );
}
