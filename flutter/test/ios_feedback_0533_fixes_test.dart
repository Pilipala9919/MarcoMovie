import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:media_kit/media_kit.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:marco_movie/core/catpaw_host.dart';
import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/cms_parser.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/core/storage_service.dart';
import 'package:marco_movie/ui/adaptive_shell.dart';
import 'package:marco_movie/ui/ios_settings.dart';
import 'package:marco_movie/ui/mobile_player_chrome.dart';
import 'package:marco_movie/ui/player_screen.dart';
import 'package:marco_movie/ui/poster_image.dart';
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
    _state.durationValue = const Duration(minutes: 45);
    _state.positionValue = const Duration(seconds: 5);
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
  Future<void> setVolume(double volume) async => _state.volumeValue = volume;
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

class _SnapshotHomeClient extends CmsClient {
  final Completer<(List<CmsCategory>, CmsListing)> home =
      Completer<(List<CmsCategory>, CmsListing)>();

  @override
  Future<(List<CmsCategory>, CmsListing)> fetchHome(CmsSite site) =>
      home.future;

  @override
  Future<List<LiveGroup>> fetchLiveGroups(LiveSource source) async => const [];
}

class _ManyNoticesSearchClient extends CmsClient {
  @override
  Future<(List<CmsCategory>, CmsListing)> fetchHome(CmsSite site) async =>
      (<CmsCategory>[], const CmsListing());

  @override
  Future<CmsListing> fetchSearch(
    CmsSite site,
    String keyword, {
    int page = 1,
  }) async {
    if (site.key == 'pianku') {
      return const CmsListing(
        videos: [
          CmsVideo(
            id: 'lxrg-1',
            title: '兰香如故',
            poster: 'https://vod.invalid/lanxiangrugu.jpg',
          ),
        ],
      );
    }
    throw const DrpySourceException('drpy_source_unavailable', 'offline');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    PackageInfo.setMockInitialValues(
      appName: 'Marco Movie',
      packageName: 'com.pilipala.marcoMovie',
      version: '0.5.33',
      buildNumber: '83',
      buildSignature: '',
    );
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    messenger.setMockMethodCallHandler(
      MobilePlayerChrome.iosSystemChromeChannel,
      null,
    );
  });

  testWidgets(
    'Issue 1: iPad fullscreen player enters immersive mode and notifies native Home Indicator channel',
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    (tester) async {
      final platformModes = <String>[];
      final iosImmersiveCalls = <bool>[];
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'SystemChrome.setEnabledSystemUIMode') {
          platformModes.add(call.arguments as String);
        }
        return null;
      });
      messenger.setMockMethodCallHandler(
        MobilePlayerChrome.iosSystemChromeChannel,
        (call) async {
          if (call.method == 'setImmersive' && call.arguments is bool) {
            iosImmersiveCalls.add(call.arguments as bool);
          }
          return null;
        },
      );

      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1024, 768);
      await tester.binding.setSurfaceSize(const Size(1024, 768));
      addTearDown(() async {
        await tester.binding.setSurfaceSize(null);
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final storage = await initTestStorage();
      final player = _FakePlayer();
      const site = CmsSite(
        key: 'ipad_site',
        name: '测试源',
        type: 1,
        api: 'https://source.invalid/api',
        isPrivate: true,
      );
      const video = CmsVideo(
        id: 'lxrg',
        title: '兰香如故',
        lines: [
          CmsLine(
            name: '自营',
            episodes: [
              CmsEpisode(name: '第1集', url: 'file:///tmp/lxrg_01.mp4'),
            ],
          ),
        ],
      );

      await tester.pumpWidget(
        MaterialApp(
          home: PlayerScreen(
            site: site,
            video: video,
            storage: storage,
            initialLineIndex: 0,
            initialEpisodeIndex: 0,
            debugPlayer: player,
            debugVideoSurface: const ColoredBox(color: Colors.black),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(platformModes, contains('SystemUiMode.immersiveSticky'));
      expect(iosImmersiveCalls, isNotEmpty);
      expect(iosImmersiveCalls.last, isTrue);

      // Controls auto-hide after 4s once initial loading clears, keeping immersive bars hidden.
      await tester.pump(const Duration(seconds: 5));
      expect(iosImmersiveCalls.last, isTrue);

      // Disposing the player screen restores system status bar and Home Indicator.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(platformModes.last, 'SystemUiMode.edgeToEdge');
      expect(iosImmersiveCalls.last, isFalse);
    },
  );

  testWidgets(
    'Issue 2: iOS 26 settings cards render authentic inset-grouped rows, search pill, and fit cleanly above dock',
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      SharedPreferences.setMockInitialValues({});
      final storage = await StorageService.init();
      await storage.saveConfig(
        '{"sites":[{"key":"s1","name":"测试源","type":1,"api":"https://source.invalid/api"}]}',
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              padding: const EdgeInsets.fromLTRB(0, 44, 0, 34),
            ),
            child: child!,
          ),
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

      expect(find.byKey(const ValueKey('ios-settings-root')), findsOneWidget);
      expect(find.byKey(const ValueKey('ios-settings-search')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('settings-category-extensions')),
        findsOneWidget,
      );

      final appearanceRowRect = tester.getRect(
        find.byKey(const ValueKey('settings-category-appearance')),
      );
      expect(appearanceRowRect.height, greaterThanOrEqualTo(44.0));

      final groupClip = tester.widget<ClipPath>(
        find
            .descendant(
              of: find.byType(IosSettingsGroup).first,
              matching: find.byType(ClipPath),
            )
            .first,
      );
      final clipper = groupClip.clipper as ShapeBorderClipper;
      final shape = clipper.shape as RoundedSuperellipseBorder;
      expect(shape.borderRadius, BorderRadius.circular(22));

      final aboutRect = tester.getRect(
        find.byKey(const ValueKey('settings-category-about')),
      );
      final dockRect = tester.getRect(find.text('主页').last);
      expect(aboutRect.bottom, lessThanOrEqualTo(dockRect.top));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Issue 3: cached site home renders immediately while slow network refresh completes in background',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final storage = await initTestStorage();
      await storage.saveConfig(
        '{"sites":[{"key":"owned","name":"Owned","type":1,"api":"https://owned.invalid/api"}]}',
      );
      final targetSite = storage.loadSavedConfig()!.sites.single;
      await storage.saveCachedSiteHome(
        targetSite,
        const [CmsCategory(id: '1', name: '剧集')],
        const CmsListing(
          videos: [CmsVideo(id: 'cached-1', title: '秒开缓存剧集')],
        ),
      );

      final client = _SnapshotHomeClient();
      await tester.pumpWidget(
        MaterialApp(home: AdaptiveShell(storage: storage, client: client)),
      );
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();

      // Cached home renders immediately before network Completer finishes.
      expect(find.text('秒开缓存剧集'), findsWidgets);

      client.home.complete((
        const [CmsCategory(id: '1', name: '剧集')],
        const CmsListing(
          videos: [CmsVideo(id: 'fresh-1', title: '后台刷新剧集')],
        ),
      ));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();

      expect(find.text('后台刷新剧集'), findsWidgets);
      await storage.clearSearchHistory();
      expect(storage.getCachedSiteHome(targetSite), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

  testWidgets(
    'Issue 4: search source notice log is capped to ~3 scrollable lines without pushing cards off-screen',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      SharedPreferences.setMockInitialValues({});
      final storage = await StorageService.init();
      await storage.saveConfig(
        jsonEncode({
          'sites': [
            for (var i = 0; i < 10; i++)
              {
                'key': 'broken_$i',
                'name': '故障线路$i | 4K',
                'type': 1,
                'api': 'https://broken.invalid/api/$i',
              },
            {
              'key': 'pianku',
              'name': '盘库 | 4K',
              'type': 1,
              'api': 'https://pianku.invalid/api',
            },
          ],
        }),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: AdaptiveShell(
            storage: storage,
            client: _ManyNoticesSearchClient(),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byKey(const ValueKey('home-search-button')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(CupertinoTextField).last, '兰香如故');
      await tester.tap(find.text('搜索').last);
      await tester.pumpAndSettle();

      final boxFinder = find.byKey(const ValueKey('search-source-notices-box'));
      expect(boxFinder, findsOneWidget);
      final boxRect = tester.getRect(boxFinder);
      // 3 text lines (~52px) + 6px vertical padding + 1px border <= 68px (vs 180+px uncapped).
      expect(boxRect.height, lessThanOrEqualTo(68.0));

      final noticeScroll = find
          .ancestor(
            of: find.byKey(const ValueKey('search-source-notices')),
            matching: find.byType(SingleChildScrollView),
          )
          .first;
      await tester.drag(noticeScroll, const Offset(0, -120));
      await tester.pumpAndSettle();

      // Result card remains prominently near the top right below the 3-line notice area.
      expect(find.text('兰香如故'), findsWidgets);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  test(
    'Issue 6: PosterLoader, CmsParser, and CmsClient strip polluted update suffixes and reject placeholder covers',
    () async {
      expect(PosterLoader.cleanTitleForQuery('兰香如故更新至第38集'), '兰香如故');
      expect(PosterLoader.cleanTitleForQuery('兰香如故更至38集'), '兰香如故');
      expect(PosterLoader.cleanTitleForQuery('兰香如故全38集'), '兰香如故');
      expect(PosterLoader.cleanTitleForQuery('兰香如故已完结'), '兰香如故');

      expect(
        CmsParser.isBrokenPosterUrl('https://vod.invalid/static/loading.gif'),
        isTrue,
      );
      expect(
        CmsParser.isBrokenPosterUrl('https://vod.invalid/images/lazyload.png'),
        isTrue,
      );
      expect(
        CmsParser.isBrokenPosterUrl('https://vod.invalid/upload/lxrg.jpg'),
        isFalse,
      );

      final client = CmsClient(
        client: MockClient((_) async {
          return http.Response.bytes(
            utf8.encode(
              jsonEncode({
                'code': 1,
                'list': [
                  {
                    'vod_id': '101',
                    'vod_name': '兰香如故更新至第38集',
                    'vod_pic': 'https://vod.invalid/static/loading.gif',
                    'vod_remarks': '',
                    'vod_play_from': '自营',
                    'vod_play_url': '第1集\$https://vod.invalid/ep1.m3u8',
                  },
                ],
              }),
            ),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );
      const site = CmsSite(
        key: 'pianku',
        name: '盘库 | 4K',
        type: 1,
        api: 'https://vod.invalid/api.php/provide/vod',
      );
      const fallback = CmsVideo(
        id: '101',
        title: '兰香如故',
        poster: 'https://vod.invalid/upload/lanxiangrugu_search.jpg',
      );
      final merged = await client.fetchDetail(site, fallback);
      expect(merged.title, '兰香如故');
      expect(merged.remarks, '更新至第38集');
      expect(merged.poster, 'https://vod.invalid/upload/lanxiangrugu_search.jpg');
    },
  );

  test(
    'Issues 5 & 6: wexpianku-v1 detail ignores top banner img and wexwogg-v1 search avoids captcha path',
    () async {
      final repoRoot = Directory.current.path.endsWith('flutter')
          ? Directory.current.parent
          : Directory.current;
      final catpawDir = Directory('${repoRoot.path}/shared/catpaw');
      final nodeCandidates = [
        '${repoRoot.parent.parent.path}/tools/windows-test-node22/node.exe',
        '${repoRoot.path}/tools/windows-test-node22/node.exe',
        'node',
      ];
      String? nodeBin;
      for (final c in nodeCandidates) {
        if (c == 'node' || File(c).existsSync()) {
          nodeBin = c;
          break;
        }
      }
      expect(nodeBin, isNotNull);

      const script = r'''
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const catpawDir = process.env.CATPAW_DIR;
const depsCode = fs.readFileSync(path.join(catpawDir, 'drpy-dependencies.js'), 'utf8');
const wexPanRule = require(path.join(catpawDir, 'drpy-wex-pan-adapter.cjs'));

function createAdapter(cfg, mockReq) {
  const ctx = vm.createContext(Object.create(null));
  ctx.joinUrl = (base, part) => new URL(String(part || ''), String(base || '')).href;
  vm.runInContext(`
    globalThis.window = globalThis;
    globalThis.self = globalThis;
    globalThis.console = { log(){}, warn(){}, error(){} };
    function unsupportedFeature(code) { const e = new Error(code); throw e; }
    globalThis.unsupportedFeature = unsupportedFeature;
    const store = Object.create(null);
    globalThis.local = {
      get: (ns, k) => store[ns + ':' + k] ?? null,
      set: (ns, k, v) => { store[ns + ':' + k] = v; },
      delete: (ns, k) => { delete store[ns + ':' + k]; },
    };
    globalThis.__drpy = {};
  `, ctx);
  ctx.cfg = cfg;
  ctx.req = mockReq;
  vm.runInContext(depsCode, ctx);
  vm.runInContext(`
    globalThis.CryptoJS = DRPYDeps.CryptoJS;
    function selectHtml(html, parts) {
      const $ = DRPYDeps.cheerio.load(String(html));
      let selected = $.root();
      for (const step of parts) {
        if (!step) continue;
        const cuts = step.split('--'), selector = cuts.shift().trim();
        if (selector && selector !== '*') selected = selected.find(selector);
        if (cuts.length) {
          selected = selected.clone();
          for (const cut of cuts) selected.find(cut).remove();
        }
      }
      return { $, selected };
    }
    globalThis.pdfa = (html, expr) => {
      const { $, selected } = selectHtml(html, String(expr).split('&&'));
      return selected.toArray().map(n => $.html(n));
    };
    globalThis.pdfh = (html, expr) => {
      const parts = String(expr).split('&&');
      const field = parts.pop();
      const { selected } = selectHtml(html, parts);
      const first = selected.first();
      if (field === 'Text') return first.text().trim();
      if (field === 'Html') return first.html() || '';
      return first.attr(field) || '';
    };
  `, ctx);
  vm.runInContext(wexPanRule(cfg) + '\nrule._install();', ctx);
  return ctx.__drpy;
}

// 1. wexpianku-v1 detail with top 《主角》 banner + lazy-loaded 《兰香如故》 poster
const pkDrpy = createAdapter(
  {
    adapter: 'wexpianku-v1',
    origin: 'https://pianku.invalid',
    defaultHost: 'https://pianku.invalid',
    userAgent: 'Mozilla/5.0',
  },
  (url) => ({
    code: 200,
    headers: {},
    content: `
      <html><body>
        <div class="top-ad"><img src="/banner/zhujue_hero.jpg" alt="主角"/></div>
        <div class="vod-detail">
          <div class="vod-pic"><img src="/static/images/loading.gif" data-original="/upload/vod/lanxiangrugu_real.jpg"/></div>
          <h1>兰香如故<span>更新至第38集</span></h1>
          <div class="vod-desc">古装剧《兰香如故》详情简介</div>
          <span class="source-tab-item" data-target="pane-self">自营</span>
          <div class="source-pane" id="pane-self">
            <a href="/vodplay/101-1-1.html">第1集</a>
          </div>
        </div>
      </body></html>
    `,
  })
);
const pkDetail = pkDrpy.detail('/voddetail/101.html');

// 2. wexwogg-v1 search prefers /vodsearch/-------------.html?wd= even when /index.php/vodsearch/ has captcha
const woggDrpy = createAdapter(
  {
    adapter: 'wexwogg-v1',
    origin: 'https://wogg.invalid',
    defaultHost: 'https://wogg.invalid',
    userAgent: 'Mozilla/5.0',
  },
  (url) => {
    if (url.includes('/index.php/vodsearch/')) {
      return { code: 200, headers: {}, content: '<html><body>系统安全验证<input name="verify"/></body></html>' };
    }
    if (url.includes('/vodsearch/-------------.html?wd=')) {
      return {
        code: 200,
        headers: {},
        content: `
          <div class="module-search-item">
            <a class="video-serial" href="/voddetail/888.html">更新至38集</a>
            <div class="video-info-header"><h3><a href="/voddetail/888.html">兰香如故</a></h3></div>
            <img data-src="/upload/wogg_lxrg.jpg" src="/static/loading.gif"/>
          </div>
        `,
      };
    }
    return { code: 404, headers: {}, content: '' };
  }
);
const woggSearch = woggDrpy.search('兰香如故');

process.stdout.write(JSON.stringify({
  pkName: pkDetail.list[0].vod_name,
  pkPic: pkDetail.list[0].vod_pic,
  woggCount: woggSearch.list.length,
  woggName: woggSearch.list[0]?.vod_name,
  woggPic: woggSearch.list[0]?.vod_pic,
}));
''';

      final proc = await Process.run(
        nodeBin!,
        ['-e', script],
        environment: {'CATPAW_DIR': catpawDir.path},
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
      expect(proc.exitCode, 0, reason: 'stderr: ${proc.stderr}');
      final out = jsonDecode(proc.stdout as String) as Map<String, dynamic>;
      expect(out['pkName'], '兰香如故');
      expect(
        out['pkPic'],
        'https://pianku.invalid/upload/vod/lanxiangrugu_real.jpg',
      );
      expect(out['woggCount'], 1);
      expect(out['woggName'], '兰香如故');
      expect(out['woggPic'], 'https://wogg.invalid/upload/wogg_lxrg.jpg');
    },
  );
}
