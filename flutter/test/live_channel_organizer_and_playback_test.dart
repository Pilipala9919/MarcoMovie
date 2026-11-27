import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/core/cms_parser.dart';
import 'package:marco_movie/core/live_channel_organizer.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/ui/ios_liquid_glass.dart';
import 'package:marco_movie/ui/live_station_badge.dart';
import 'package:marco_movie/ui/player/player_hud_prefs.dart';
import 'package:marco_movie/ui/player_screen.dart';
import 'package:marco_movie/ui/windows_appearance.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'test_storage_helper.dart';

class _RecordingPlatformPlayer extends Fake implements PlatformPlayer {
  final Map<String, String> properties = <String, String>{};

  Future<void> setProperty(String key, String value) async {
    properties[key] = value;
  }
}

class _LiveFakePlayerState extends Fake implements PlayerState {
  Playlist playlistValue = const Playlist([]);
  bool playingValue = true;
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

class _LiveFakePlayerStream extends Fake implements PlayerStream {
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

class _LiveFakePlayer extends Fake implements Player {
  final _LiveFakePlayerState _state = _LiveFakePlayerState();
  final _LiveFakePlayerStream _stream = _LiveFakePlayerStream();
  final _RecordingPlatformPlayer _platform = _RecordingPlatformPlayer();
  final List<Media> openedMedia = <Media>[];
  final List<double> openedVolumes = <double>[];
  bool disposed = false;

  @override
  PlatformPlayer? get platform => _platform;
  @override
  PlayerState get state => _state;
  @override
  PlayerStream get stream => _stream;

  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    if (playable is Media) {
      openedMedia.add(playable);
      openedVolumes.add(_state.volumeValue);
      _state.playlistValue = Playlist([playable]);
    }
    _state.playingValue = play;
    _state.bufferingValue = false;
    if (!disposed) {
      _stream.widthCtrl.add(1920);
      _stream.heightCtrl.add(1080);
      _stream.positionCtrl.add(const Duration(seconds: 1));
      _stream.bufferingCtrl.add(false);
      _stream.playingCtrl.add(play);
    }
  }

  @override
  Future<void> play() async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> playOrPause() async {}
  @override
  Future<void> seek(Duration d) async {}
  @override
  Future<void> setRate(double rate) async {}
  @override
  Future<void> setVolume(double v) async => _state.volumeValue = v;
  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {
    if (disposed) return;
    disposed = true;
    await _stream.close();
  }
}

class _DirectLoopbackHttpOverrides extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'Windows live volume survives replacing the player on channel switch',
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 720));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final storage = await initTestStorage();
      final appearance = WindowsAppearance(Directory.systemTemp);
      addTearDown(appearance.dispose);
      const site = CmsSite(
        key: 'live:test',
        name: 'Test live',
        type: 1,
        api: 'http://live.example/list.m3u',
      );

      Future<void> playChannel(String name, _LiveFakePlayer player) async {
        final channel = LiveChannel(
          name: name,
          group: 'Test',
          urls: ['http://live.example/$name.m3u8'],
        );
        await tester.pumpWidget(MaterialApp(
          builder: (_, child) => WindowsAppearanceScope(
            controller: appearance,
            child: child!,
          ),
          home: PlayerScreen(
            key: ValueKey(name),
            site: site,
            video: CmsVideo(
              id: name,
              title: name,
              lines: [CmsLine(name: channel.group, episodes: channel.episodes)],
            ),
            initialLineIndex: 0,
            initialEpisodeIndex: 0,
            storage: storage,
            isLive: true,
            embedded: true,
            initialLiveChannel: channel,
            debugPlayer: player,
            debugVideoSurface: const ColoredBox(color: Colors.black),
          ),
        ));
        await tester.pumpAndSettle();
      }

      final first = _LiveFakePlayer();
      await playChannel('first', first);
      expect(first.openedVolumes, [100.0]);
      await tester.tap(find.byTooltip('音量'));
      await tester.pumpAndSettle();
      final slider = find.byType(Slider);
      tester.widget<Slider>(slider).onChanged!(71.0);
      await tester.pump();
      expect(first.state.volume, 71.0);
      await (await SharedPreferences.getInstance()).reload();
      expect(storage.windowsLiveVolume, 71.0);
      Navigator.of(tester.element(slider)).pop();
      await tester.pumpAndSettle();

      final second = _LiveFakePlayer();
      await playChannel('second', second);
      expect(second.openedVolumes, [71.0]);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    },
  );

  test(
      'auto-categorizes ungrouped playlist, sorts CCTV naturally, merges aliases and propagates logos',
      () {
    const rawM3u = '''
#EXTM3U
#EXTINF:-1 tvg-logo="https://logos.example/cctv1.png",CCTV-13 新闻
http://live.example/cctv13.m3u8
#EXTINF:-1 tvg-logo="https://logos.example/cctv1.png",CCTV-1 综合
http://live.example/cctv1_a.m3u8
#EXTINF:-1,CCTV1 综合 HD
http://live.example/cctv1_b.m3u8
#EXTINF:-1,CCTV-5+ 体育赛事
http://live.example/cctv5p.m3u8
#EXTINF:-1,湖南卫视 HD
http://live.example/hunan.m3u8
#EXTINF:-1,浙江卫视
http://live.example/zhejiang.m3u8
#EXTINF:-1,TVB翡翠台
http://live.example/jade.m3u8
#EXTINF:-1,4K超高清频道
http://live.example/4k.m3u8
#EXTINF:-1,CHC动作电影
http://live.example/chc.m3u8
#EXTINF:-1,金鹰卡通
http://live.example/kids.m3u8
#EXTINF:-1,Discovery探索
http://live.example/doc.m3u8
#EXTINF:-1,北京都市
http://live.example/bj_city.m3u8
''';

    final parsed = CmsParser.parseLivePlaylist(rawM3u);
    final organized = LiveChannelOrganizer.organize(
      parsed,
      autoCategorize: true,
      logoTemplate: 'https://logos.example/auto/{name}.png',
    );

    final groupNames = organized.map((g) => g.name).toList();
    expect(groupNames, [
      '央视',
      '卫视',
      '4K 超清',
      '港澳台',
      '影视轮播',
      '少儿动漫',
      '纪录科教',
      '地方频道',
    ]);

    // CCTV sorted naturally and aliases merged with logo preserved.
    final cctv = organized.firstWhere((g) => g.name == '央视').channels;
    expect(cctv.map((c) => LiveChannelOrganizer.canonicalChannelKey(c.name)).toList(), [
      'CCTV1',
      'CCTV5+',
      'CCTV13',
    ]);
    expect(cctv.first.urls, [
      'http://live.example/cctv1_a.m3u8',
      'http://live.example/cctv1_b.m3u8',
    ]);
    expect(cctv.first.logo, 'https://logos.example/cctv1.png');

    // Logo template fills channels lacking explicit tvg-logo.
    final satellite = organized.firstWhere((g) => g.name == '卫视').channels;
    expect(satellite.first.logo, contains('https://logos.example/auto/'));

    // Branded station emblems resolve distinct brand colors.
    final hunanEmblem = LiveChannelOrganizer.resolveStationEmblem(satellite.first);
    final zhejiangEmblem = LiveChannelOrganizer.resolveStationEmblem(satellite[1]);
    expect(hunanEmblem.topLine, '卫视');
    expect(hunanEmblem.mainText, '湖南');
    expect(hunanEmblem.colorStart, isNot(zhejiangEmblem.colorStart));
  });

  test(
      'probes live streams over loopback, sorts fastest line first, rejects HTML error pages and groups dead channels into 失效频道',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));

    server.listen((req) async {
      switch (req.uri.path) {
        case '/fast.m3u8':
          req.response.statusCode = 200;
          req.response.headers.set('content-type', 'application/vnd.apple.mpegurl');
          req.response.write('#EXTM3U\n#EXT-X-VERSION:3\n#EXTINF:4.0,\nseg1.ts\n');
          await req.response.close();
          break;
        case '/slow.ts':
          await Future<void>.delayed(const Duration(milliseconds: 120));
          req.response.statusCode = 200;
          req.response.headers.set('content-type', 'video/mp2t');
          req.response.add(List<int>.filled(376, 0x47));
          await req.response.close();
          break;
        case '/html-error':
          req.response.statusCode = 200;
          req.response.headers.set('content-type', 'text/html; charset=utf-8');
          req.response.write('<!DOCTYPE html><html><body>Access Denied</body></html>');
          await req.response.close();
          break;
        default:
          req.response.statusCode = 404;
          await req.response.close();
      }
    });

    final base = 'http://127.0.0.1:${server.port}';
    final groups = [
      LiveGroup(
        name: '未分组',
        channels: [
          LiveChannel(
            name: 'CCTV-1 综合',
            group: '未分组',
            urls: ['$base/html-error', '$base/slow.ts', '$base/fast.m3u8'],
          ),
          LiveChannel(
            name: '湖南卫视',
            group: '未分组',
            urls: ['$base/missing', '$base/html-error'],
          ),
        ],
      ),
    ];

    final progressEvents = <LiveProbeProgress>[];
    final probed = await HttpOverrides.runWithHttpOverrides(
      () => LiveStreamProber.probeAndOrganize(
        groups,
        concurrency: 4,
        timeout: const Duration(seconds: 2),
        autoCategorize: true,
        onProgress: progressEvents.add,
      ),
      _DirectLoopbackHttpOverrides(),
    );

    expect(progressEvents, isNotEmpty);
    expect(progressEvents.last.completedChannels, 2);
    expect(progressEvents.last.reachableChannels, 1);
    expect(progressEvents.last.unreachableChannels, 1);

    expect(probed.map((g) => g.name).toList(), ['央视', LiveChannelOrganizer.failedGroupName]);

    final cctv1 = probed.first.channels.single;
    expect(cctv1.health, isNot(LiveStreamHealth.unreachable));
    expect(cctv1.latencyMs, isNotNull);
    expect(cctv1.reachableCount, 2);
    // Fastest healthy stream moved to index 0; HTML error moved to last!
    expect(cctv1.urls.first, '$base/fast.m3u8');
    expect(cctv1.urls.last, '$base/html-error');
    expect(cctv1.episodes.first.name, contains('ms'));
    expect(cctv1.episodes.last.name, contains('不可用'));

    final failed = probed.last.channels.single;
    expect(failed.name, '湖南卫视');
    expect(failed.health, LiveStreamHealth.unreachable);
  });

  test('StorageService persists standalone live sources and probed snapshots independently of VOD subscriptions',
      () async {
    final storage = await initTestStorage();
    expect(storage.loadSavedConfig(), isNull);

    final saved = await storage.upsertStandaloneLiveSource(
      const StandaloneLiveSource(
        id: 'my_iptv',
        name: '我的 IPTV',
        inlineContent: 'CCTV-1,http://live.example/cctv1.m3u8\n湖南卫视,http://live.example/hunan.m3u8',
        userAgent: 'CustomLiveUA/2.0',
        autoCategorize: true,
      ),
    );

    final cfg = storage.loadSavedConfig();
    expect(cfg, isNotNull);
    expect(cfg!.sites, isEmpty);
    expect(cfg.lives, hasLength(1));
    expect(cfg.lives.single.name, '我的 IPTV');
    expect(cfg.lives.single.headers['User-Agent'], 'CustomLiveUA/2.0');

    final snapshotGroups = [
      const LiveGroup(
        name: '央视',
        channels: [
          LiveChannel(
            name: 'CCTV-1',
            group: '央视',
            urls: ['http://live.example/cctv1.m3u8'],
            health: LiveStreamHealth.fast,
            latencyMs: 95,
            reachableCount: 1,
          ),
        ],
      ),
    ];
    final liveSource = saved.toLiveSource();
    await storage.saveLiveSnapshot(liveSource, snapshotGroups);
    final loadedSnapshot = storage.loadLiveSnapshot(liveSource);
    expect(loadedSnapshot, isNotNull);
    expect(loadedSnapshot!.single.name, '央视');
    expect(loadedSnapshot.single.channels.single.health, LiveStreamHealth.fast);
    expect(loadedSnapshot.single.channels.single.latencyMs, 95);

    await storage.deleteStandaloneLiveSource(saved.id);
    expect(storage.loadLiveSnapshot(liveSource), isNull);
    expect(storage.loadSavedConfig(), isNull);
  });

  testWidgets(
    'iOS live PlayerScreen opens live streams directly with tuned libmpv options and switches channels warmly via LiveChannelDrawer',
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    (tester) async {
      IosLiquidGlassBridge.setAvailableForTest(false);
      addTearDown(() => IosLiquidGlassBridge.setAvailableForTest(null));

      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(844, 390);
      await tester.binding.setSurfaceSize(const Size(844, 390));
      addTearDown(() async {
        await tester.binding.setSurfaceSize(null);
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final storage = await initTestStorage();
      final prefs = PlayerHudPrefs.inMemory(isDesktop: false);
      addTearDown(prefs.dispose);
      final player = _LiveFakePlayer();

      const ch1 = LiveChannel(
        name: 'CCTV-1 综合',
        group: '央视',
        urls: ['http://live.example/cctv1.m3u8'],
        health: LiveStreamHealth.fast,
        latencyMs: 120,
      );
      const ch2 = LiveChannel(
        name: '湖南卫视',
        group: '卫视',
        urls: ['http://live.example/hunan.m3u8'],
        health: LiveStreamHealth.smooth,
        latencyMs: 280,
      );
      const liveGroups = [
        LiveGroup(name: '央视', channels: [ch1]),
        LiveGroup(name: '卫视', channels: [ch2]),
      ];
      const liveSite = CmsSite(
        key: 'live:test',
        name: '测试直播',
        type: 1,
        api: 'http://live.example/list.m3u',
      );
      final liveVideo = CmsVideo(
        id: ch1.name,
        title: ch1.name,
        lines: [CmsLine(name: ch1.group, episodes: ch1.episodes)],
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: PlayerScreen(
            site: liveSite,
            video: liveVideo,
            initialLineIndex: 0,
            initialEpisodeIndex: 0,
            storage: storage,
            isLive: true,
            liveGroups: liveGroups,
            initialLiveChannel: ch1,
            debugPlayer: player,
            debugVideoSurface: const ColoredBox(color: Colors.black),
            debugHudPrefs: prefs,
          ),
        ),
      );
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
      await tester.pump(const Duration(milliseconds: 250));

      // Direct-first live playback on iOS (no LocalMediaLease 127.0.0.1 wrapper) + tuned mpv options.
      expect(player.openedMedia, hasLength(1));
      expect(player.openedMedia.first.uri, 'http://live.example/cctv1.m3u8');
      expect(player.openedMedia.first.httpHeaders?['User-Agent'], 'okhttp/4.12.0');
      expect(player._platform.properties['tls-verify'], 'no');
      expect(player._platform.properties['demuxer-max-bytes'], '16777216');
      expect(player._platform.properties['demuxer-max-back-bytes'], '4194304');
      expect(player._platform.properties['stream-lavf-o'], contains('tls_verify=0'));
      expect(player._platform.properties['hwdec-extra-frames'], '8');

      // Tap iOS live dock 「频道」 button -> opens in-player LiveChannelDrawer with logos & latency.
      final channelBtn = find.text('频道');
      expect(channelBtn, findsOneWidget);
      await tester.tap(channelBtn);
      await tester.pumpAndSettle();

      expect(find.text('切换频道'), findsOneWidget);
      expect(find.byType(LiveStationBadge), findsWidgets);
      expect(find.text('120ms'), findsOneWidget);

      // Switch to 「卫视」 group -> tap 「湖南卫视」 inside the same warm PlayerScreen!
      await tester.tap(find.text('卫视 (1)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('湖南卫视'));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
      await tester.pump(const Duration(milliseconds: 250));

      expect(player.openedMedia, hasLength(2));
      expect(player.openedMedia.last.uri, 'http://live.example/hunan.m3u8');

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump(const Duration(milliseconds: 650));
    },
  );
}
