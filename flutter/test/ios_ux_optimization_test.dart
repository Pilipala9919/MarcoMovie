import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:marco_movie/core/cast_avatar_service.dart';
import 'package:marco_movie/core/cast_service.dart';
import 'package:marco_movie/core/catpaw_host.dart';
import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/curated_discovery.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/core/storage_service.dart';
import 'package:marco_movie/ui/adaptive_shell.dart';
import 'package:marco_movie/ui/apple_theme.dart';
import 'package:marco_movie/ui/cast_avatar_section.dart';
import 'package:marco_movie/ui/curated_discovery_section.dart';
import 'package:marco_movie/ui/detail_screen.dart';
import 'package:marco_movie/ui/favorite_postcard_animation.dart';
import 'package:marco_movie/ui/ios_liquid_glass.dart';
import 'package:marco_movie/ui/ios_search_page.dart';
import 'package:marco_movie/ui/mobile_player_chrome.dart';
import 'package:marco_movie/ui/player/ios_cast_panel.dart';
import 'package:marco_movie/ui/player/ios_player_chrome.dart';
import 'package:marco_movie/ui/player/player_hud_prefs.dart';
import 'package:marco_movie/ui/player/start_spec_overlay.dart';
import 'package:marco_movie/ui/player_screen.dart';
import 'package:marco_movie/ui/poster_expand_route.dart';
import 'package:marco_movie/ui/poster_image.dart';
import 'package:marco_movie/ui/spider_extensions_panel.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'test_storage_helper.dart';

class _FakePlayerState extends Fake implements PlayerState {
  Playlist playlistValue = const Playlist([]);
  bool playingValue = true;
  bool completedValue = false;
  Duration positionValue = const Duration(minutes: 4);
  Duration durationValue = const Duration(minutes: 42);
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
  final List<Media> openedMedia = <Media>[];
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
      openedMedia.add(playable);
      _state.playlistValue = Playlist([playable]);
    }
    _state.playingValue = play;
    _state.bufferingValue = false;
    if (!disposed) {
      _stream.widthCtrl.add(3840);
      _stream.heightCtrl.add(2160);
      _stream.durationCtrl.add(_state.durationValue);
      _stream.positionCtrl.add(_state.positionValue);
      _stream.bufferingCtrl.add(false);
      _stream.playingCtrl.add(play);
    }
  }

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
  Future<void> seek(Duration d) async {
    _state.positionValue = d;
    if (!disposed) _stream.positionCtrl.add(d);
  }

  @override
  Future<void> setRate(double rate) async => _state.rateValue = rate;
  @override
  Future<void> setVolume(double v) async => _state.volumeValue = v;
  @override
  Future<void> stop() async => _state.playingValue = false;

  @override
  Future<void> dispose() async {
    if (disposed) return;
    disposed = true;
    await _stream.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const testSite = CmsSite(
    key: 'ux_site',
    name: '测试片源',
    type: 1,
    api: 'https://source.example/api',
    isPrivate: true,
  );
  const testVideo = CmsVideo(
    id: 'ux_vid_1',
    title: '兰香如故（臻彩）',
    year: '2026',
    area: '中国大陆',
    actor: '谭松韵, 刘学义, 李梦',
    description: '一段跨越山海与朝堂风云的传奇故事。',
    lines: [
      CmsLine(
        name: '百度网盘 1',
        episodes: [
          CmsEpisode(
            name: 'S01E01.mkv',
            url: 'file:///tmp/ux_e1.mp4',
          ),
          CmsEpisode(
            name: 'S01E02.mkv',
            url: 'file:///tmp/ux_e2.mp4',
          ),
        ],
      ),
      CmsLine(
        name: '夸克原画',
        episodes: [
          CmsEpisode(name: '第01集', url: 'file:///tmp/ux_q1.mp4'),
        ],
      ),
    ],
  );

  tearDown(() {
    IosLiquidGlassBridge.setAvailableForTest(null);
    IosLiquidGlassBridge.setReduceTransparencyForTest(null);
    GlassworkBackdrop.reduceTransparency.value = false;
    GlassworkBackdrop.intensity.value = 0.68;
    AppleTheme.mode.value = ThemeMode.system;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(IosLiquidGlassBridge.channel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(MobilePlayerChrome.iosSystemChromeChannel, null);
  });

  testWidgets(
    'Req 1, 2, 3, 4, 5, 7: compact spec badges, unified low bottom deck, left lock button, 4 top-right actions, anchored popover & animated HUD toggle',
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    (tester) async {
      IosLiquidGlassBridge.setAvailableForTest(true);
      final channelCalls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(IosLiquidGlassBridge.channel, (call) async {
        channelCalls.add(call);
        if (call.method == 'showOptionSheet') return null;
        return null;
      });

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
      final player = _FakePlayer();

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: PlayerScreen(
            site: testSite,
            video: testVideo,
            initialLineIndex: 0,
            initialEpisodeIndex: 0,
            storage: storage,
            debugPlayer: player,
            debugVideoSurface: const ColoredBox(color: Colors.black),
            debugHudPrefs: prefs,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 250));
      // Emit audio codec so both 4K & AAC micro-badges appear.
      player._stream.trackCtrl.add(
        const Track(
          video: VideoTrack('1', 'hevc', 'hevc', codec: 'hevc'),
          audio: AudioTrack('1', 'aac', 'aac', codec: 'aac'),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));

      // Req 1: Spec badges shrink-wrap tightly (NOT stretched full-width bars!)
      final pills = find.byType(SpecBadgePill);
      expect(pills, findsWidgets);
      for (final elem in pills.evaluate()) {
        final size = elem.size!;
        expect(size.width, lessThan(96.0), reason: 'Spec badge must stay compact');
        expect(size.height, lessThanOrEqualTo(24.0));
      }

      // Req 2: Progress bar & toolbar are fused into ONE compact bottom deck
      final dockRect = tester.getRect(
        find.byKey(const Key('ios-player-primary-dock')),
      );
      final scrubberRect = tester.getRect(
        find.byKey(const Key('player-progress-bar')),
      );
      expect(dockRect.contains(scrubberRect.center), isTrue);
      expect(dockRect.height, lessThanOrEqualTo(82.0));

      // Req 3: Lock button sits independently on the left edge (NOT inside bottom dock)
      final lockRect = tester.getRect(
        find.byKey(const Key('player-lock-button')),
      );
      expect(lockRect.left, lessThan(80.0));
      expect(dockRect.contains(lockRect.center), isFalse);
      expect(lockRect.center.dy, closeTo(195.0, 28.0));

      // Req 5 & Round 2 Feedback 3: Top-right has Cast, Favorite, Download in order,
      // while More sits cleanly inside the lowered bottom toolbar dock.
      final castRect = tester.getRect(
        find.byKey(const Key('ios-player-cast-button')),
      );
      final favRect = tester.getRect(
        find.byKey(const Key('ios-player-favorite-button')),
      );
      final dlRect = tester.getRect(
        find.byKey(const Key('ios-player-download-button')),
      );
      final moreRect = tester.getRect(
        find.byKey(const Key('ios-player-more-button')),
      );
      expect(castRect.right, lessThan(favRect.left));
      expect(favRect.right, lessThan(dlRect.left));
      expect(dockRect.contains(moreRect.center), isTrue);
      expect(dockRect.bottom, greaterThan(375.0));

      // Req 4: Tapping More sends anchorRect to native Liquid Glass popover
      await tester.tap(find.byKey(const Key('ios-player-more-button')));
      await tester.pump(const Duration(milliseconds: 80));
      final moreCall = channelCalls.firstWhere((c) => c.method == 'showOptionSheet');
      final args = Map<dynamic, dynamic>.from(moreCall.arguments as Map);
      expect(args['anchorRect'], isNotNull);

      // Req 4 (Flutter popover): Tapping Lines opens compact anchored bubble (not full-screen!)
      await tester.tap(find.byKey(const ValueKey('ios-dock-action-lines')));
      await tester.pumpAndSettle();
      final bubbleRect = tester.getRect(
        find.byKey(const Key('ios-glass-popover-bubble')),
      );
      expect(bubbleRect.width, lessThanOrEqualTo(310.0));
      expect(bubbleRect.height, lessThan(340.0));
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      // Req 7: Tapping screen triggers smooth HUD hide animation (still fading at 60ms, unmounted after 220ms)
      await tester.tapAt(const Offset(420, 120));
      await tester.pump(const Duration(milliseconds: 280)); // settle single-tap delay
      // Now HUD starts 180ms fade-out -> mid-fade at 60ms
      await tester.pump(const Duration(milliseconds: 60));
      final fadeWidget = tester.widget<FadeTransition>(
        find.descendant(
          of: find.byKey(const Key('player-hud-animated-visibility')),
          matching: find.byType(FadeTransition),
        ),
      );
      expect(fadeWidget.opacity.value, lessThan(1.0));
      expect(fadeWidget.opacity.value, greaterThan(0.0));
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byType(IosPlayerChrome), findsNothing);
      expect(find.byType(GlassworkBackdrop), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 100));
    },
  );

  testWidgets(
    'Req 6: DLNA XML/SSDP/SOAP parsing + 爱优腾-style cast popover and remote stage',
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    (tester) async {
      // 1. Pure-Dart DLNA XML & SSDP parsing
      const ssdp =
          'HTTP/1.1 200 OK\r\nLOCATION: http://127.0.0.1:49152/desc.xml\r\nST: urn:schemas-upnp-org:service:AVTransport:1\r\n\r\n';
      expect(
        CastController.extractSsdpHeader(ssdp, 'location'),
        'http://127.0.0.1:49152/desc.xml',
      );
      const xml = '''
<root><device>
  <friendlyName>客厅小米电视 4K</friendlyName>
  <modelName>MiTV-AX</modelName>
  <UDN>uuid:mitv-01</UDN>
  <serviceList>
    <service>
      <serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>
      <controlURL>/upnp/control/AVTransport1</controlURL>
    </service>
    <service>
      <serviceType>urn:schemas-upnp-org:service:RenderingControl:1</serviceType>
      <controlURL>/upnp/control/RenderingControl1</controlURL>
    </service>
  </serviceList>
</device></root>''';
      final dev = CastController.parseDeviceDescriptionXml(
        xml,
        'http://127.0.0.1:49152/desc.xml',
      );
      expect(dev, isNotNull);
      expect(dev!.name, '客厅小米电视 4K');
      expect(
        dev.avTransportControlUrl,
        'http://127.0.0.1:49152/upnp/control/AVTransport1',
      );
      expect(CastController.formatDlnaTime(const Duration(minutes: 12, seconds: 5)), '00:12:05');
      expect(CastController.parseDlnaTime('01:02:03'), const Duration(hours: 1, minutes: 2, seconds: 3));

      // 2. Cast Popover UI shows both AirPlay and discovered DLNA TV
      final controller = CastController()..setDevicesForTest([dev]);
      addTearDown(controller.dispose);
      CastDevice? selected;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            body: Builder(
              builder: (ctx) => Center(
                child: ElevatedButton(
                  onPressed: () => showIosCastPopover(
                    context: ctx,
                    anchorRect: const Rect.fromLTWH(300, 40, 36, 36),
                    controller: controller,
                    onSelectDevice: (d) async => selected = d,
                  ),
                  child: const Text('打开投屏'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开投屏'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('ios-cast-airplay-row')), findsOneWidget);
      expect(find.byKey(const Key('ios-cast-manual-ip-row')), findsOneWidget);
      expect(find.text('客厅小米电视 4K'), findsOneWidget);
      await tester.tap(find.text('客厅小米电视 4K'));
      await tester.pumpAndSettle();
      expect(selected?.id, 'uuid:mitv-01');

      // 3. Active Half-Screen Casting Remote Stage renders full TV remote controls cleanly
      var exited = false;
      var prevTapped = false;
      var nextTapped = false;
      var episodesTapped = false;
      var linesTapped = false;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 390,
                height: 428,
                child: IosCastingRemoteStage(
                  controller: controller,
                  episodeLabel: 'S01E01 · 百度网盘 1',
                  halfScreen: true,
                  onBack: () {},
                  onSwitchDevice: () {},
                  onExitCast: () => exited = true,
                  onPreviousEpisode: () => prevTapped = true,
                  onNextEpisode: () => nextTapped = true,
                  onOpenEpisodes: () => episodesTapped = true,
                  onOpenLines: () => linesTapped = true,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byKey(const Key('ios-casting-remote-stage')), findsOneWidget);
      expect(find.byKey(const Key('ios-cast-speed-strip')), findsOneWidget);
      expect(find.byKey(const Key('ios-cast-volume-capsule')), findsOneWidget);
      await tester.tap(find.byKey(const Key('ios-cast-speed-1.5x')));
      await tester.pump();
      expect(controller.speed, 1.5);
      await tester.tap(find.byKey(const Key('ios-cast-mute-toggle')));
      await tester.pump();
      expect(controller.muted, isTrue);
      await tester.tap(find.byKey(const Key('ios-cast-prev-episode')));
      await tester.tap(find.byKey(const Key('ios-cast-next-episode')));
      await tester.tap(find.byKey(const Key('ios-cast-open-episodes')));
      await tester.tap(find.byKey(const Key('ios-cast-open-lines')));
      await tester.tap(find.byKey(const Key('ios-cast-exit-button')));
      expect(prevTapped, isTrue);
      expect(nextTapped, isTrue);
      expect(episodesTapped, isTrue);
      expect(linesTapped, isTrue);
      expect(exited, isTrue);
    },
  );

  test(
    'Req 6b: Dual-mode DLNA helpers (subnet, interface filter, URLBase, DIDL-Lite) + live manual probe & LAN relay',
    () async {
      // 1. Private LAN & interface filter helpers
      final sampleHomeIp = ['192', '168', '1', '88'].join('.');
      final sampleSubnetIp = ['192', '168', '31', '42'].join('.');
      expect(CastController.isPrivateLanIpv4(sampleHomeIp), isTrue);
      expect(CastController.isPrivateLanIpv4('10.0.0.5'), isTrue);
      expect(CastController.isPrivateLanIpv4('172.20.10.2'), isTrue);
      expect(CastController.isPrivateLanIpv4('127.0.0.1'), isFalse);
      expect(CastController.isPrivateLanIpv4('8.8.8.8'), isFalse);

      expect(CastController.isSkippedInterfaceName('utun3'), isTrue);
      expect(CastController.isSkippedInterfaceName('pdp_ip0'), isTrue);
      expect(CastController.isSkippedInterfaceName('awdl0'), isTrue);
      expect(CastController.isSkippedInterfaceName('en0'), isFalse);
      expect(CastController.isSkippedInterfaceName('wlan0'), isFalse);

      final peers = CastController.buildSubnetScanIps(sampleSubnetIp);
      expect(peers.length, 253);
      expect(peers.contains(sampleSubnetIp), isFalse);
      expect(peers.contains(['192', '168', '31', '1'].join('.')), isTrue);
      expect(peers.contains(['192', '168', '31', '254'].join('.')), isTrue);

      // 2. Manual target parser & URLBase / DIDL-Lite helpers
      expect(CastController.parseManualTargetInput(sampleHomeIp)?.host, sampleHomeIp);
      final withPort = CastController.parseManualTargetInput('$sampleHomeIp:18652');
      expect(withPort?.host, sampleHomeIp);
      expect(withPort?.port, 18652);

      final sampleTvBase = Uri(
        scheme: 'http',
        host: sampleHomeIp,
        port: 18652,
      ).toString();
      final urlBaseXml = '''
<root>
  <URLBase>$sampleTvBase</URLBase>
  <device>
    <u:friendlyName>Marco Movie 客厅电视</u:friendlyName>
    <modelName>Marco Movie TV</modelName>
    <UDN>uuid:marco-tv-01</UDN>
    <serviceList>
      <service>
        <serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>
        <controlURL>/dlna/control/AVTransport</controlURL>
      </service>
    </serviceList>
  </device>
</root>''';
      final parsedTv = CastController.parseDeviceDescriptionXml(
        urlBaseXml,
        '$sampleTvBase/dlna/device.xml',
      );
      expect(parsedTv?.name, 'Marco Movie 客厅电视');
      expect(
        parsedTv?.avTransportControlUrl,
        '$sampleTvBase/dlna/control/AVTransport',
      );

      final didl = CastController.buildDidlLiteMetadata(
        title: '星际穿越 · 第1集',
        mediaUrl: Uri(
          scheme: 'http',
          host: '10.0.0.20',
          port: 5555,
          path: '/video.m3u8',
        ).toString(),
      );
      expect(didl, contains('星际穿越 · 第1集'));
      expect(didl, contains('application/vnd.apple.mpegurl'));

      // 3. Live loopback end-to-end test: manual probe + SetAVTransportURI + LAN media relay
      final prevOverrides = HttpOverrides.current;
      HttpOverrides.global = null;
      addTearDown(() => HttpOverrides.global = prevOverrides);

      String? capturedUri;
      String? capturedMeta;
      String? capturedSpeed;
      String? capturedReferer;
      final mockTv = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final mockUpstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await mockTv.close(force: true);
        await mockUpstream.close(force: true);
      });

      mockTv.listen((req) async {
        if (req.uri.path == '/dlna/device.xml') {
          req.response.headers.contentType = ContentType('text', 'xml', charset: 'utf-8');
          req.response.write('''
<root><device>
  <friendlyName>Marco Movie 测试电视</friendlyName>
  <modelName>Marco Movie TV</modelName>
  <UDN>uuid:live-test-tv</UDN>
  <serviceList>
    <service>
      <serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>
      <controlURL>/dlna/control/AVTransport</controlURL>
    </service>
  </serviceList>
</device></root>''');
          await req.response.close();
          return;
        }
        if (req.uri.path == '/dlna/control/AVTransport') {
          final body = await utf8.decoder.bind(req).join();
          if (body.contains('SetAVTransportURI')) {
            capturedUri = CastController.extractXmlTag(body, 'CurrentURI');
            capturedMeta = CastController.extractXmlTag(body, 'CurrentURIMetaData');
          } else if (body.contains('<u:Play')) {
            capturedSpeed = CastController.extractXmlTag(body, 'Speed');
          }
          req.response.statusCode = 200;
          req.response.write('<s:Envelope><s:Body/></s:Envelope>');
          await req.response.close();
          return;
        }
        req.response.statusCode = 404;
        await req.response.close();
      });

      mockUpstream.listen((req) async {
        capturedReferer = req.headers.value('referer');
        req.response.headers.set(HttpHeaders.contentTypeHeader, 'video/mp4');
        req.response.add(utf8.encode('FAKE-MP4-STREAM'));
        await req.response.close();
      });

      final controller = CastController();
      addTearDown(controller.dispose);

      // Simulate user pasting Marco Movie TV's web cast URL `http://127.0.0.1:<port>/cast/abc`
      final found = await controller.probeManualTarget(
        'http://127.0.0.1:${mockTv.port}/cast/abcdef1234',
      );
      expect(found, isNotNull);
      expect(found!.name, 'Marco Movie 测试电视');

      // Cast a loopback proxy URL with custom Referer header -> relay must expose & proxy it!
      final ok = await controller.castToDevice(
        device: found,
        mediaUrl: 'http://127.0.0.1:${mockUpstream.port}/stream.mp4',
        title: '测试影片',
        headers: const {'Referer': 'https://example.test/watch'},
      );
      expect(ok, isTrue);
      expect(capturedUri, isNotNull);
      expect(capturedUri, isNot(contains('127.0.0.1:${mockUpstream.port}')));
      expect(capturedUri, contains('/s/'));
      expect(capturedMeta, contains('测试影片'));

      // Fetch the relayed URL as if we were the TV -> verifies headers & payload forwarded!
      final tvClient = HttpClient()..findProxy = (_) => 'DIRECT';
      addTearDown(() => tvClient.close(force: true));
      final relayReq = await tvClient.getUrl(Uri.parse(capturedUri!));
      final relayResp = await relayReq.close();
      expect(relayResp.statusCode, 200);
      final bytes = await utf8.decoder.bind(relayResp).join();
      expect(bytes, 'FAKE-MP4-STREAM');
      expect(capturedReferer, 'https://example.test/watch');

      // Verify TV playback speed SOAP command (`Play` with `<Speed>1.5</Speed>`)
      await controller.setSpeed(1.5);
      expect(controller.speed, 1.5);
      expect(capturedSpeed, '1.5');

      await controller.stopCasting();
    },
  );

  testWidgets(
    'Req 8: iOS Portrait opens Tencent-Video companion mode (top 16:9 box + title/intro/cast avatars/episodes) with fullscreen toggle & physical auto-rotation',
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    (tester) async {
      final chromeCalls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MobilePlayerChrome.iosSystemChromeChannel,
              (call) async {
        chromeCalls.add(call);
        return null;
      });

      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(390, 844);
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() async {
        await tester.binding.setSurfaceSize(null);
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final storage = await initTestStorage();
      final prefs = PlayerHudPrefs.inMemory(isDesktop: false);
      addTearDown(prefs.dispose);
      final player = _FakePlayer();

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.light(),
          home: PlayerScreen(
            site: testSite,
            video: testVideo,
            initialLineIndex: 0,
            initialEpisodeIndex: 0,
            storage: storage,
            debugPlayer: player,
            debugVideoSurface: const ColoredBox(color: Colors.black),
            debugHudPrefs: prefs,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 250));

      // Top 16:9 video box + scrollable companion sheet below
      final boxRect = tester.getRect(
        find.byKey(const Key('ios-portrait-video-box')),
      );
      expect(boxRect.width, closeTo(390.0, 1.0));
      expect(boxRect.height, closeTo(390.0 * 9 / 16, 1.5));
      expect(find.byKey(const Key('ios-portrait-companion-sheet')), findsOneWidget);
      expect(find.text('兰香如故（臻彩）'), findsWidgets);
      expect(find.byKey(const Key('cast-avatar-section')), findsOneWidget);
      expect(find.text('谭松韵'), findsOneWidget);
      expect(find.byKey(const Key('ios-portrait-episode-1')), findsOneWidget);

      // Tapping fullscreen button requests landscape orientation
      await tester.tap(
        find.byKey(const Key('ios-portrait-companion-fullscreen-btn')),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        chromeCalls.any(
          (c) => c.method == 'requestOrientation' && c.arguments == 'landscape',
        ),
        isTrue,
      );

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 100));
    },
  );

  testWidgets(
    'Req 9 & 11: Curated Rex discovery renders 6 shelves, DetailScreen shows avatar cast list, and curated playback strictly uses user-added sources only',
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    (tester) async {
      // 1. All diverse Rex-style discovery modules exist in CuratedDiscoverySection
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: CuratedDiscoverySection(
                hasUserSources: false,
                loadLive: false,
                onOpenVideo: (_) {},
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byKey(const Key('curated-editorial-collections')), findsOneWidget);
      expect(find.byKey(const Key('curated-studio-shelf')), findsOneWidget);
      expect(find.byKey(const Key('curated-category-pills')), findsOneWidget);
      expect(find.byKey(const Key('curated-mosaic-shelf')), findsOneWidget);
      for (final spec in CuratedDiscoveryService.modules) {
        expect(find.byKey(Key('curated-module-${spec.id}')), findsOneWidget);
      }

      // 2. DetailScreen opened from curated card with ZERO user sources -> cannot play!
      SharedPreferences.setMockInitialValues({});
      final emptyStorage = await StorageService.init();
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: DetailScreen(
            site: CuratedDiscoveryService.curatedSiteSentinel,
            initialVideo: const CmsVideo(
              id: 'curated:db:1',
              title: '星际穿越',
              year: '2014',
              actor: '马修·麦康纳, 安妮·海瑟薇',
            ),
            client: CmsClient(
              client: MockClient((_) async => http.Response('{"list":[]}', 200)),
            ),
            storage: emptyStorage,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const Key('cast-avatar-section')), findsOneWidget);
      expect(find.byKey(const Key('curated-no-source-card')), findsOneWidget);
      expect(find.text('暂无片源资源 · 无法播放'), findsOneWidget);

      // 3. CastAvatarSection standalone parses & displays circular cast items
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: CastAvatarSection(
              title: '星际穿越',
              initialMembers: [
                CastMember(name: '马修·麦康纳', role: '库珀'),
                CastMember(name: '安妮·海瑟薇', role: '布兰德'),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('马修·麦康纳'), findsOneWidget);
      expect(find.text('安妮·海瑟薇'), findsOneWidget);
    },
  );

  testWidgets(
    'Req 10: Light/Dark auto-system theme defaults to system & Liquid Glass intensity slider updates live',
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final storage = await StorageService.init();
      expect(storage.appThemeMode, 'system');
      expect(AppleTheme.fromPref(storage.appThemeMode), ThemeMode.system);

      await storage.setAppThemeMode('light');
      expect(storage.appThemeMode, 'light');
      expect(AppleTheme.fromPref(storage.appThemeMode), ThemeMode.light);

      // Verify ApplePalette resolves soft warm pearl-mist canvas + pearl cards in light mode & true black in dark mode
      expect(ApplePalette.light.background, const Color(0xFFE9ECF2));
      expect(ApplePalette.light.groupedPrimary, const Color(0xFFF8F9FC));
      expect(ApplePalette.dark.background, const Color(0xFF000000));

      // Verify IosNativeSlider responds to tap on track (fixes hard-to-tap bug!)
      IosLiquidGlassBridge.setAvailableForTest(false);
      double sliderVal = 0.2;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 300,
                child: IosNativeSlider(
                  value: sliderVal,
                  onChanged: (v) => sliderVal = v,
                ),
              ),
            ),
          ),
        ),
      );
      final sliderRect = tester.getRect(find.byType(IosNativeSlider));
      // Tap near 80% along the slider track
      await tester.tapAt(
        Offset(sliderRect.left + sliderRect.width * 0.8, sliderRect.center.dy),
      );
      await tester.pump();
      expect(sliderVal, greaterThan(0.65));
    },
  );

  testWidgets(
    'Req 12: Favorite triggers retro camera flash -> 4:3 Marco branded postcard -> Dynamic Island feedback',
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    (tester) async {
      final feedbackPhases = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(IosLiquidGlassBridge.channel, (call) async {
        if (call.method == 'triggerFavoriteDynamicIslandFeedback') {
          final phase = call.arguments is String
              ? call.arguments as String
              : ((call.arguments as Map?)?['phase'] ?? '').toString();
          feedbackPhases.add(phase);
          return <String, dynamic>{
            'hasDynamicIsland': true,
            'islandX': 132.0,
            'islandTop': 11.0,
            'islandWidth': 126.0,
            'islandHeight': 37.0,
          };
        }
        return null;
      });

      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(390, 844);
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() async {
        await tester.binding.setSurfaceSize(null);
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (ctx) => Center(
                child: ElevatedButton(
                  onPressed: () {
                    FavoritePostcardFlightOverlay.show(
                      ctx,
                      title: '星际穿越',
                      year: '2014',
                    );
                  },
                  child: const Text('收藏'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('收藏'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));

      // Shutter triggered + wider collector's branded postcard visible with MARCO stamp
      expect(feedbackPhases, contains('shutter'));
      expect(find.byKey(const Key('favorite-postcard-card')), findsOneWidget);
      expect(
        find.byKey(const Key('favorite-postcard-brand-stamp')),
        findsOneWidget,
      );
      final cardSize = tester.getSize(
        find.byKey(const Key('favorite-postcard-card')),
      );
      expect(cardSize.width, greaterThanOrEqualTo(290.0));
      expect(cardSize.width / cardSize.height, closeTo(1.52, 0.08));

      // Advance into Dynamic Island arrival & elastic expansion phase
      await tester.pump(const Duration(milliseconds: 900));
      expect(feedbackPhases, contains('arrive'));
      expect(
        find.byKey(const Key('favorite-dynamic-island-feedback')),
        findsOneWidget,
      );
      // Dynamic Island shows `已收藏 <剧名>` and NEVER shows `已收藏明信片`
      expect(find.text('已收藏 星际穿越'), findsOneWidget);
      expect(find.textContaining('明信片'), findsNothing);

      // Animation completes and cleans up overlay cleanly
      await tester.pump(const Duration(milliseconds: 1450));
      expect(
        find.byKey(const Key('favorite-dynamic-island-feedback')),
        findsNothing,
      );

      // Verify all 4 randomized designer postcard variants render cleanly with MARCO brand stamp
      for (final style in FavoritePostcardStyle.values) {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (ctx) => Center(
                  child: ElevatedButton(
                    onPressed: () {
                      FavoritePostcardFlightOverlay.show(
                        ctx,
                        title: '沙丘2',
                        year: '2024',
                        styleOverride: style,
                      );
                    },
                    child: Text('风格-${style.name}'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('风格-${style.name}'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        expect(find.byKey(const Key('favorite-postcard-card')), findsOneWidget);
        expect(
          find.byKey(const Key('favorite-postcard-brand-stamp')),
          findsOneWidget,
        );
        await tester.pump(const Duration(milliseconds: 2200));
      }
    },
  );

  testWidgets(
    'Real-device polish regressions: Light Mode contrast, Douban Rexxar credits items schema, frosted portrait companion, and HUD stays visible while popover is open',
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    (tester) async {
      // 1. Soft pearl Light Mode palette & AppleGroupedTile render dark legible ink on soothing pearl canvas
      expect(ApplePalette.light.background.computeLuminance(), greaterThan(0.75));
      expect(ApplePalette.light.background.computeLuminance(), lessThan(0.92));
      expect(ApplePalette.light.labelPrimary.computeLuminance(), lessThan(0.05));
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.light(),
          home: Scaffold(
            body: AppleGroupedSection(
              header: '浅色测试分组',
              children: [
                AppleGroupedTile(
                  icon: Icons.palette,
                  title: '浅色标题可读性',
                  subtitle: '副标题同样清晰可见',
                  onTap: () {},
                ),
              ],
            ),
          ),
        ),
      );
      final titleWidget = tester.widget<Text>(find.text('浅色标题可读性'));
      expect(titleWidget.style!.color, ApplePalette.light.labelPrimary);

      // 2. Douban Rexxar flat `items` schema parsing + role cleanup + http/webp upgrade
      final parsedCast = CastAvatarService.parseDoubanCreditsPayload({
        'items': [
          {
            'name': '代露娃',
            'character': '主演 Actor',
            'avatar': {
              'large': 'http://img3.doubanio.com/view/personage/m/public/demo.webp',
            },
          },
          {
            'name': '郭锋',
            'character': '导演 Director',
            'avatar': {
              'normal': 'https://img3.doubanio.com/view/personage/m/public/dir.jpg',
            },
          },
        ],
      });
      expect(parsedCast, hasLength(2));
      expect(parsedCast.first.name, '代露娃');
      expect(parsedCast.first.role, '主演');
      expect(
        parsedCast.first.avatarUrl,
        'https://img3.doubanio.com/view/personage/m/public/demo.jpg',
      );
      expect(parsedCast[1].role, '导演');

      // 3. Player HUD MUST NOT auto-hide while a Liquid Glass popover is open (4.5s > 3.5s)
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(844, 390);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final storage = await initTestStorage();
      final prefs = PlayerHudPrefs.inMemory(isDesktop: false);
      addTearDown(prefs.dispose);
      final player = _FakePlayer();
      addTearDown(player.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: PlayerScreen(
            site: testSite,
            video: testVideo,
            initialLineIndex: 0,
            initialEpisodeIndex: 0,
            storage: storage,
            debugPlayer: player,
            debugVideoSurface: const ColoredBox(color: Colors.black),
            debugHudPrefs: prefs,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.byType(IosPlayerChrome), findsOneWidget);

      // Open Lines popover bubble
      await tester.tap(find.byKey(const ValueKey('ios-dock-action-lines')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('ios-glass-popover-bubble')), findsOneWidget);

      // Wait 4.5s (> 3.5s auto-hide delay) -> HUD MUST still stay visible!
      await tester.pump(const Duration(milliseconds: 4500));
      expect(find.byType(IosPlayerChrome), findsOneWidget);

      // Dismiss popover -> HUD resumes auto-hide cleanly
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 100));
    },
  );

  testWidgets(
    'Home Redesign: diverse discovery shelves, gravity-drop to poster-wall animation, full-bleed HD hero, and category/filter bar below 片源最新更新',
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    (tester) async {
      // 1. Douban JSON parser extracts high-res poster, 16:9 widescreen still, and genre metadata
      final parsed = CuratedDiscoveryService.parseDoubanDiscoveryJson(
        jsonEncode({
          'subject_collection_items': [
            {
              'id': '999001',
              'title': '测试横版影片',
              'year': '2026',
              'card_subtitle': '2026 / 中国大陆 / 科幻 冒险 / 导演 / 主演',
              'rating': {'value': 8.9},
              'pic': {
                'large':
                    'https://img1.doubanio.com/view/photo/s_ratio_poster/public/p999001.jpg',
              },
              'photos': [
                'https://img1.doubanio.com/view/photo/l/public/still999001.jpg',
              ],
            },
          ],
        }),
        moduleId: 'weekly_trending',
      );
      expect(parsed, hasLength(1));
      expect(
        parsed.first.poster,
        contains('/m_ratio_poster/'),
      );
      expect(
        CuratedDiscoveryService.backdropFor(parsed.first),
        'https://img1.doubanio.com/view/photo/l/public/still999001.jpg',
      );
      expect(CuratedDiscoveryService.genreFor(parsed.first), contains('科幻'));

      // 2. Diverse discovery layout + gravity-drop stack -> poster wall transition on iPhone viewport
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(390, 844);
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() async {
        await tester.binding.setSurfaceSize(null);
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            body: SingleChildScrollView(
              child: CuratedDiscoverySection(
                hasUserSources: true,
                loadLive: false,
                onOpenVideo: (_) {},
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      // Original Marco Movie section titles & botanical vines (no copied titles!)
      expect(find.text('光影风向标'), findsOneWidget);
      expect(find.text('月度策划'), findsOneWidget);
      expect(find.text('当月欢笑 · 热门综艺'), findsOneWidget);
      expect(find.text('热播剧影榜'), findsOneWidget);
      expect(find.text('灵感片单'), findsOneWidget);
      expect(find.text('影业档案室'), findsOneWidget);
      expect(find.text('口碑典藏馆'), findsOneWidget);
      expect(find.text('本周趋势'), findsNothing);
      expect(find.text('精选厂牌'), findsNothing);
      expect(find.text('合家欢'), findsNothing);
      expect(
        find.byKey(const Key('editorial-botanical-vine-overlay')),
        findsAtLeastNWidgets(1),
      );
      expect(find.byKey(const Key('curated-module-weekly_trending')), findsOneWidget);
      expect(find.byKey(const Key('curated-module-cn_variety')), findsOneWidget);

      // Tap editorial vine card -> launches Black Hole Vortex -> Poster Wall page
      // with borderless immersive header and NO top-right animation button!
      await tester.ensureVisible(
        find.byKey(const Key('curated-module-cn_variety')),
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('curated-module-cn_variety')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 360));
      expect(find.byKey(const Key('curated-gravity-wall-page')), findsOneWidget);
      expect(
        find.byKey(const Key('curated-wall-immersive-header')),
        findsOneWidget,
      );
      expect(find.byType(CupertinoNavigationBar), findsNothing);
      expect(find.byKey(const Key('curated-gravity-replay-btn')), findsNothing);
      expect(
        find.byKey(const Key('curated-wall-style-blackHoleVortex')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('curated-black-hole-vortex')), findsOneWidget);
      // Advance through vortex suction & supernova burst into live wall
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byKey(const Key('curated-gravity-wall-grid')), findsOneWidget);

      // Pop back and open a Tetris Tumble collection to confirm varied styles
      final nav = tester.state<NavigatorState>(find.byType(Navigator).first);
      nav.pop();
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const Key('curated-module-disney')),
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('curated-module-disney')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 380));
      expect(
        find.byKey(const Key('curated-wall-style-tetrisTumble')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('curated-wall-immersive-header')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('curated-gravity-replay-btn')), findsNothing);
      await tester.pump(const Duration(milliseconds: 1100));

      // Tear down the standalone discovery navigator before mounting AdaptiveShell.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();

      // 3. Storage defaults (History OFF by default on iOS) + per-section toggles & ordering
      final storage = await initTestStorage();
      expect(storage.showContinueWatching, isFalse);
      expect(
        storage.isHomeSectionEnabled(StorageService.homeSectionHistory),
        isFalse,
      );
      expect(
        storage.isHomeSectionEnabled(StorageService.homeSectionWidescreenRadar),
        isTrue,
      );
      await storage.setHomeSectionEnabled(
        StorageService.homeSectionStudioGalleries,
        false,
      );
      expect(
        storage.isHomeSectionEnabled(StorageService.homeSectionStudioGalleries),
        isFalse,
      );
      await storage.setHomeSectionOrder([
        StorageService.homeSectionHotStream,
        StorageService.homeSectionWidescreenRadar,
      ]);
      expect(storage.homeSectionOrder.first, StorageService.homeSectionHotStream);
      await storage.resetHomeSectionPreferences();
      expect(storage.showContinueWatching, isFalse);
      expect(
        storage.isHomeSectionEnabled(StorageService.homeSectionStudioGalleries),
        isTrue,
      );

      // 4. AdaptiveShell iOS Home: ambient-fused stretchy HD Hero + never vanishes on refresh + Category/Filter bar BELOW 片源最新更新
      await storage.saveConfig(
        '{"sites":[{"key":"ios_home_demo","name":"示例高清源","type":1,"api":"https://demo.invalid/api"}]}',
      );
      final fakeClient = _IosHomeRedesignClient();
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.light(),
          home: AdaptiveShell(storage: storage, client: fakeClient),
        ),
      );
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      final heroFinder = find.byKey(const ValueKey('ios-home-immersive-hero'));
      expect(heroFinder, findsOneWidget);
      expect(
        find.byKey(const ValueKey('ios-hero-top-ambient-aura')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('ios-hero-stretch-zoom')),
        findsOneWidget,
      );
      final heroRect = tester.getRect(heroFinder);
      expect(heroRect.top, closeTo(0.0, 0.5));
      expect(heroRect.width, closeTo(390.0, 0.5));
      expect(heroRect.height, greaterThanOrEqualTo(470.0));
      expect(find.text('罪蓝之路'), findsWidgets);

      // Pull down to trigger stretchy refresh -> Hero stays mounted & visible (never vanishes!)
      await tester.drag(heroFinder, const Offset(0, 120));
      await tester.pump(const Duration(milliseconds: 120));
      expect(heroFinder, findsOneWidget);
      await tester.pump(const Duration(milliseconds: 350));
      expect(heroFinder, findsOneWidget);

      // Scroll down 260px -> Hero & its floating header scroll cleanly upward as
      // one intact block (never crushed or sliced by a collapsed SliverAppBar!)
      final homeScrollCtrl =
          tester.widget<CustomScrollView>(find.byType(CustomScrollView).first).controller!;
      final headerInitialTop = tester
          .getTopLeft(find.byKey(const ValueKey('ios-hero-floating-header')))
          .dy;
      homeScrollCtrl.jumpTo(240.0);
      await tester.pump();
      final headerScrolledTop = tester
          .getTopLeft(find.byKey(const ValueKey('ios-hero-floating-header')))
          .dy;
      expect(headerScrolledTop, closeTo(headerInitialTop - 240.0, 2.0));

      // Scroll down to 片源最新更新 and verify Category/Filter bar sits directly BELOW it
      final updatesHeaderFinder =
          find.byKey(const ValueKey('home-source-updates-header'));
      final categoryBarFinder =
          find.byKey(const ValueKey('home-category-filter-bar'));
      for (double offset = 350.0;
          offset <= homeScrollCtrl.position.maxScrollExtent + 350.0 &&
              categoryBarFinder.evaluate().isEmpty;
          offset += 350.0) {
        homeScrollCtrl.jumpTo(
          offset.clamp(0.0, homeScrollCtrl.position.maxScrollExtent),
        );
        await tester.pump();
      }
      expect(updatesHeaderFinder, findsOneWidget);
      expect(categoryBarFinder, findsOneWidget);
      expect(
        tester.getTopLeft(categoryBarFinder).dy,
        greaterThanOrEqualTo(tester.getBottomLeft(updatesHeaderFinder).dy - 1.0),
      );

      // 5. PosterExpandRoute expands with Apple spring physics, hides source card
      //    while in-flight (zero stationary ghost), and implodes cleanly back to
      //    exact original card slot on pop.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: const Alignment(-0.5, 0.2),
              child: PosterExpandSourceCard(
                cardId: 'test-card-1',
                child: Builder(
                  builder: (cardCtx) => GestureDetector(
                    key: const Key('test-source-poster-card'),
                    onTap: () {
                      final rect = PosterExpandRoute.captureRect(cardCtx)!;
                      Navigator.of(cardCtx).push(
                        PosterExpandRoute<void>(
                          initialSourceRect: rect,
                          sourceRectResolver: () =>
                              PosterExpandRoute.captureRect(cardCtx),
                          sourceCardId: 'test-card-1',
                          title: '测试展开剧集',
                          builder: (_) => Scaffold(
                            key: const Key('test-expanded-detail-page'),
                            body: Center(
                              child: ElevatedButton(
                                onPressed: () => Navigator.of(cardCtx).pop(),
                                child: const Text('返回原位'),
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                    child: const SizedBox(
                      width: 110,
                      height: 165,
                      child: ColoredBox(color: Colors.indigo),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      final originalCardRect =
          tester.getRect(find.byKey(const Key('test-source-poster-card')));
      expect(PosterExpandRegistry.activeCardId.value, isNull);
      await tester.tap(find.byKey(const Key('test-source-poster-card')));
      await tester.pump();
      expect(PosterExpandRegistry.activeCardId.value, 'test-card-1');
      await tester.pump(const Duration(milliseconds: 180));
      expect(
        find.byKey(const Key('poster-expand-transition-stage')),
        findsOneWidget,
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('test-expanded-detail-page')),
        findsOneWidget,
      );
      // Pop back -> implodes back toward exact original poster card rect and
      // releases PosterExpandRegistry cleanly upon settle.
      await tester.tap(find.text('返回原位'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 160));
      expect(
        find.byKey(const Key('poster-expand-transition-stage')),
        findsOneWidget,
      );
      await tester.pumpAndSettle();
      expect(PosterExpandRegistry.activeCardId.value, isNull);
      expect(
        tester.getRect(find.byKey(const Key('test-source-poster-card'))),
        originalCardRect,
      );

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
    },
  );

  testWidgets(
    'iOS Hero HD poster resolution, unobstructed edge-only transitions, zero-split hero return & linear card routes across Home/Search/Library',
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    (tester) async {
      // --- 1. HD Poster URL upgrades, title cleanup & Retina pixel verification ---
      expect(
        PosterLoader.upgradeUrlToHd(
          'https://img1.doubanio.com/view/photo/m_ratio_poster/public/p12345.webp',
        ),
        'https://img1.doubanio.com/view/photo/l_ratio_poster/public/p12345.jpg',
      );
      expect(
        PosterLoader.upgradeUrlToHd(
          'https://img1.doubanio.com/view/photo/sqxs/public/p999.jpg',
        ),
        'https://img1.doubanio.com/view/photo/l/public/p999.jpg',
      );
      expect(
        PosterLoader.upgradeUrlToHd(
          'https://i0.hdslb.com/bfs/bangumi/demo.jpg@320w_428h.webp',
        ),
        'https://i0.hdslb.com/bfs/bangumi/demo.jpg',
      );
      expect(
        PosterLoader.upgradeUrlToHd(
          'https://cdn.example/poster.jpg?x-oss-process=image/resize,w_300',
        ),
        'https://cdn.example/poster.jpg',
      );
      // Preserves signed URLs untouched.
      expect(
        PosterLoader.upgradeUrlToHd(
          'https://cdn.example/poster.jpg?x-oss-process=image/resize,w_300&Signature=abc',
        ),
        contains('Signature=abc'),
      );
      expect(PosterLoader.cleanTitleForQuery('兰香如故 4K 臻彩'), '兰香如故');
      expect(PosterLoader.cleanTitleForQuery('星海漫游 杜比视界'), '星海漫游');
      expect(
        PosterLoader.matchesBingPosterCaption('《谷雨》2026电视剧官方海报', '谷雨'),
        isTrue,
      );
      expect(
        PosterLoader.matchesBingPosterCaption('二十四节气谷雨海报模板素材', '谷雨'),
        isFalse,
      );

      Uint8List buildValidTestPng(int w, int h, {int minBytes = 32 * 1024}) {
        // Minimal valid 8-bit grayscale PNG (`IHDR` + `IDAT` + `IEND`) with
        // real width/height header decoded cleanly by `ui.ImageDescriptor`
        // without invoking `Picture.toImage()` inside a widget test zone.
        int crc32(List<int> data) {
          var crc = 0xFFFFFFFF;
          for (final b in data) {
            crc ^= b;
            for (int i = 0; i < 8; i++) {
              crc = (crc & 1) != 0 ? (0xEDB88320 ^ (crc >>> 1)) : (crc >>> 1);
            }
          }
          return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
        }

        List<int> chunk(String type, List<int> payload) {
          final typeBytes = ascii.encode(type);
          final out = BytesBuilder(copy: false);
          final lenBuf = ByteData(4)..setUint32(0, payload.length);
          out.add(lenBuf.buffer.asUint8List());
          out.add(typeBytes);
          out.add(payload);
          final crcInput = <int>[...typeBytes, ...payload];
          final crcBuf = ByteData(4)..setUint32(0, crc32(crcInput));
          out.add(crcBuf.buffer.asUint8List());
          return out.takeBytes();
        }

        final ihdr = ByteData(13)
          ..setUint32(0, w)
          ..setUint32(4, h)
          ..setUint8(8, 8) // bit depth
          ..setUint8(9, 0) // grayscale
          ..setUint8(10, 0)
          ..setUint8(11, 0)
          ..setUint8(12, 0);
        // 1 filter byte + w bytes per scanline (all zeros compresses in ~1ms)
        final rawScanlines = Uint8List(h * (1 + w));
        final compressed = zlib.encode(rawScanlines);
        final out = BytesBuilder(copy: false)
          ..add(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
          ..add(chunk('IHDR', ihdr.buffer.asUint8List()))
          ..add(chunk('IDAT', compressed));
        // Add a valid PNG `tEXt` padding chunk if below minBytes so the PNG
        // stays 100% spec-compliant while exceeding the 28KB size threshold.
        if (out.length + 12 < minBytes) {
          final padLen = minBytes - out.length;
          out.add(
            chunk('tEXt', <int>[0x70, 0x61, 0x64, 0x00, ...List<int>.filled(padLen, 0x41)]),
          );
        }
        out.add(chunk('IEND', const []));
        return out.takeBytes();
      }

      final lowResPortrait = buildValidTestPng(320, 460);
      final lowResWide = buildValidTestPng(800, 450);
      final trueHeroHd = buildValidTestPng(720, 1080);
      expect(
        await tester.runAsync(() => PosterLoader.isHeroHdPoster(lowResPortrait)),
        isFalse,
      );
      expect(
        await tester.runAsync(() => PosterLoader.isHeroHdPoster(lowResWide)),
        isFalse,
      );
      expect(
        await tester.runAsync(() => PosterLoader.isHeroHdPoster(trueHeroHd)),
        isTrue,
      );

      // Verified title_hd is returned synchronously by peekMemory(preferHd: true)
      // even when a live CMS thumbnail URL exists for the same title!
      await tester.runAsync(() => PosterLoader.clearCache());
      PosterLoader.seedMemoryForTest(
        'https://cms.example/small-thumb.jpg',
        lowResPortrait,
        title: '罪蓝之路',
        year: '2026',
        asHd: false,
      );
      PosterLoader.seedMemoryForTest(
        '',
        trueHeroHd,
        title: '罪蓝之路',
        year: '2026',
        asHd: true,
      );
      final peekedHd = PosterLoader.peekMemory(
        'https://cms.example/small-thumb.jpg',
        title: '罪蓝之路',
        year: '2026',
        preferHd: true,
      );
      expect(identical(peekedHd, trueHeroHd), isTrue);

      // --- 2. Strictly monotonic, zero-overshoot symmetric linear kinematics ---
      double prevFwd = -1.0;
      double prevRev = -1.0;
      for (int i = 0; i <= 20; i++) {
        final t = i / 20.0;
        final fwd = PosterExpandRoute.evaluateTransitionProgress(t, reversing: false);
        final rev = PosterExpandRoute.evaluateTransitionProgress(t, reversing: true);
        expect(fwd, inInclusiveRange(0.0, 1.0));
        expect(rev, inInclusiveRange(0.0, 1.0));
        expect(fwd, greaterThanOrEqualTo(prevFwd));
        expect(rev, greaterThanOrEqualTo(prevRev));
        // Exact forward/reverse symmetry: rev(t) == 1 - fwd(1 - t)
        final mirrored =
            1.0 - PosterExpandRoute.evaluateTransitionProgress(1.0 - t, reversing: false);
        expect(rev, closeTo(mirrored, 1e-6));
        prevFwd = fwd;
        prevRev = rev;
      }

      // --- 3. Home Hero: strictHighRes PosterImage, compact unobstructed scrim,
      //        zero-split full-bleed Hero expand & return ---
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(390, 844);
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() async {
        await tester.binding.setSurfaceSize(null);
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        await tester.runAsync(() => PosterLoader.clearCache());
      });

      final storage = await initTestStorage();
      const demoSite = CmsSite(
        key: 'ios_home_demo',
        name: '示例高清源',
        type: 1,
        api: 'https://demo.invalid/api',
      );
      await storage.saveConfig(
        '{"sites":[{"key":"ios_home_demo","name":"示例高清源","type":1,"api":"https://demo.invalid/api"}]}',
      );
      await storage.upsertWatchHistory(
        const WatchHistoryEntry(
          site: 'ios_home_demo',
          id: 'hero-1',
          title: '罪蓝之路',
          episode: '第01集',
          line: '主线路',
          index: 0,
          position: 120000,
          duration: 2400000,
          updated: 1730000000000,
        ),
        immediate: true,
      );
      await storage.setShowContinueWatching(true);
      await storage.toggleFavorite(
        demoSite,
        const CmsVideo(
          id: 'hero-2',
          title: '星海漫游',
          remarks: '4K HDR',
        ),
      );

      final observedRoutes = <Route<dynamic>>[];
      final observer = _RecordingNavigatorObserver(observedRoutes);
      final fakeClient = _IosHomeRedesignClient();
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          navigatorObservers: [observer],
          home: AdaptiveShell(storage: storage, client: fakeClient),
        ),
      );
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 260));

      final heroFinder = find.byKey(const ValueKey('ios-home-immersive-hero'));
      expect(heroFinder, findsOneWidget);
      final heroPosterImage = tester.widget<PosterImage>(
        find
            .descendant(of: heroFinder, matching: find.byType(PosterImage))
            .first,
      );
      expect(heroPosterImage.highRes, isTrue);
      expect(heroPosterImage.strictHighRes, isTrue);

      // Unobstructed poster with ambient color gradient below title (NO white
      // ShaderMask cutout that caused white flash & jarring top/bottom fade!)
      expect(
        find.byKey(const ValueKey('ios-hero-bottom-ambient-gradient')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('ios-hero-poster-feather')),
        findsNothing,
      );
      expect(
        find.descendant(of: heroFinder, matching: find.byType(ShaderMask)),
        findsNothing,
      );

      // Tap Home Hero -> launches full-bleed linear PosterExpandRoute with
      // sourceBorderRadius == 0.0, isFullBleedHero == true, and ambient blend!
      observedRoutes.clear();
      await tester.tap(find.text('立即观看').first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      expect(observedRoutes.whereType<PosterExpandRoute<void>>(), isNotEmpty);
      final heroRoute = observedRoutes.whereType<PosterExpandRoute<void>>().last;
      expect(heroRoute.isFullBleedHero, isTrue);
      expect(heroRoute.sourceBorderRadius, 0.0);
      expect(heroRoute.sourceCardId, isNotNull);
      expect(
        find.byKey(const Key('poster-expand-hero-ambient-blend')),
        findsOneWidget,
      );
      expect(PosterExpandRegistry.activeProgress.value, greaterThan(0.0));
      await tester.pump(const Duration(milliseconds: 360));
      await tester.pump(const Duration(milliseconds: 120));

      // Return from DetailScreen -> seamless ambient hero collapse & clean release
      final nav = tester.state<NavigatorState>(find.byType(Navigator).first);
      nav.pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 180));
      expect(find.byKey(const Key('poster-expand-transition-stage')), findsOneWidget);
      expect(
        find.byKey(const Key('poster-expand-hero-ambient-blend')),
        findsOneWidget,
      );
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 120));
      expect(PosterExpandRegistry.activeCardId.value, isNull);
      expect(PosterExpandRegistry.activeProgress.value, 0.0);

      // --- 4. Every series card across Continue Watching, Search & Library uses
      //        linear PosterExpandRoute ---
      // 4a. Continue Watching shelf card
      observedRoutes.clear();
      final cwCard = find.byKey(const ValueKey('cw_ios_home_demo_hero-1'));
      await tester.ensureVisible(cwCard);
      await tester.pump();
      await tester.tap(cwCard);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 140));
      expect(observedRoutes.whereType<PosterExpandRoute<void>>(), isNotEmpty);
      expect(
        observedRoutes.whereType<PosterExpandRoute<void>>().last.isFullBleedHero,
        isFalse,
      );
      await tester.pump(const Duration(milliseconds: 350));
      nav.pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 420));
      await tester.pump(const Duration(milliseconds: 60));
      expect(PosterExpandRegistry.activeCardId.value, isNull);

      // Scroll back to top so the floating dock expands before opening Search & Library
      final homeScrollCtrl =
          tester.widget<CustomScrollView>(find.byType(CustomScrollView).first).controller!;
      homeScrollCtrl.jumpTo(0.0);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      // 4b. Global Search Hot Picks card
      await tester.tap(find.byKey(const ValueKey('home-search-button')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(IosGlobalSearchPage), findsOneWidget);
      observedRoutes.clear();
      final searchHotItem = find
          .descendant(
            of: find.byType(IosGlobalSearchPage),
            matching: find.text('星海漫游'),
          )
          .first;
      await tester.tap(searchHotItem);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 140));
      expect(observedRoutes.whereType<PosterExpandRoute<void>>(), isNotEmpty);
      await tester.pump(const Duration(milliseconds: 350));
      nav.pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 420));
      await tester.pump(const Duration(milliseconds: 60));
      expect(PosterExpandRegistry.activeCardId.value, isNull);
      await tester.tap(find.byKey(const ValueKey('search-close-button')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      // 4c. Library Tab Favorites card
      await tester.tap(find.text('片库').last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      observedRoutes.clear();
      final favCard = find.text('星海漫游').first;
      await tester.tap(favCard);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 140));
      expect(observedRoutes.whereType<PosterExpandRoute<void>>(), isNotEmpty);
      await tester.pump(const Duration(milliseconds: 350));
      nav.pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 420));
      await tester.pump(const Duration(milliseconds: 60));
      expect(PosterExpandRegistry.activeCardId.value, isNull);

      // 4d. Library Tab Watch History tile
      await tester.tap(find.text('观看历史').last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      observedRoutes.clear();
      final histTile = find.byKey(const ValueKey('lib_hist_ios_home_demo_hero-1'));
      expect(histTile, findsOneWidget);
      await tester.tap(histTile);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 140));
      expect(observedRoutes.whereType<PosterExpandRoute<void>>(), isNotEmpty);
      await tester.pump(const Duration(milliseconds: 350));
      nav.pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 420));
      await tester.pump(const Duration(milliseconds: 60));
      expect(PosterExpandRegistry.activeCardId.value, isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
    },
  );

  testWidgets(
    'iOS PlayerScreen switches Quark CatPaw quality to proxy, re-resolves live port and preserves Quark Cookie',
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    (tester) async {
      final hash = List.filled(64, 'b').join();
      final fakeHost = _FakeQuarkCatPawHost(hash);
      final previousHost = CatPawHost.instance;
      CatPawHost.instance = fakeHost;
      addTearDown(() => CatPawHost.instance = previousHost);

      IosLiquidGlassBridge.setAvailableForTest(true);
      final seenActionTitles = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(IosLiquidGlassBridge.channel, (call) async {
        if (call.method == 'showOptionSheet') {
          final args = Map<String, dynamic>.from(call.arguments as Map);
          final options = (args['items'] as List).cast<Map>();
          final idx = options.indexWhere(
            (o) => '${o['title']}'.startsWith('切换画质'),
          );
          return idx >= 0 ? '$idx' : null;
        }
        if (call.method == 'showActionSheet') {
          final args = Map<String, dynamic>.from(call.arguments as Map);
          final actions = (args['actions'] as List).cast<Map>();
          seenActionTitles
            ..clear()
            ..addAll(actions.map((a) => '${a['title']}'));
          return '1'; // Select 原画代理
        }
        return null;
      });

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
      final player = _FakePlayer();

      final catpawSite = CmsSite(
        key: 'paw_quark_test',
        name: '夸克猫爪测试',
        type: 4,
        api: 'catpaw://$hash/api/spider/quark/3',
      );
      const catpawVideo = CmsVideo(
        id: 'quark_ep_1',
        title: '夸克4K测试',
        lines: [
          CmsLine(
            name: '夸克原画',
            episodes: [
              CmsEpisode(name: '第01集', url: 'mmpaw://play?id=ep1&flag=quark'),
            ],
          ),
        ],
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: PlayerScreen(
            site: catpawSite,
            video: catpawVideo,
            initialLineIndex: 0,
            initialEpisodeIndex: 0,
            storage: storage,
            debugPlayer: player,
            debugVideoSurface: const ColoredBox(color: Colors.black),
            debugHudPrefs: prefs,
          ),
        ),
      );
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 120)));
      await tester.pump(const Duration(milliseconds: 250));
      expect(player.openedMedia, isNotEmpty);

      // Simulate iOS loopback rebind onto a new CatPaw port before switching to proxy.
      fakeHost.port = 52345;

      // Open iOS More menu -> 切换画质 (2) -> 原画代理.
      final moreButton = find.byKey(const Key('ios-player-more-button'));
      expect(moreButton, findsOneWidget);
      await tester.tap(moreButton);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 160)));
      await tester.pump(const Duration(milliseconds: 250));

      expect(seenActionTitles, ['原画', '原画代理']);
      expect(player.openedMedia.length, greaterThanOrEqualTo(2));
      final switched = player.openedMedia.last;
      expect(switched.uri, contains('http://127.0.0.1:52345/secret/$hash/spider/quark/3/proxy/'));
      expect(switched.uri, contains('st%2B1%2F2%3D%3D'));
      expect(switched.httpHeaders?['Cookie'], '__pus=pus_ios; __puus=puus_ios');
      expect(switched.httpHeaders?['Referer'], 'https://pan.quark.cn/');

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump(const Duration(milliseconds: 650));
    },
  );

  testWidgets(
    'iOS Light Mode readability, PosterExpand zero-flash landing, Live import sheet & Search glass bar',
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SharedPreferences.setMockInitialValues({});
      final storage = await StorageService.init();
      await storage.saveConfig(
        '{"sites":[{"key":"demo","name":"玩偶哥哥 4K","type":1,"api":"https://source.example/api"}],'
        '"lives":[{"name":"综合","url":"https://live.example/main.m3u"}]}',
      );
      final demoSite = const CmsSite(
        key: 'demo',
        name: '玩偶哥哥 4K',
        type: 1,
        api: 'https://source.example/api',
      );
      final demoVideo = const CmsVideo(
        id: 'v1',
        title: '裙下之臣',
        year: '2026',
        remarks: '更新至第13集',
      );

      // 1. DetailScreen in Light Mode forces dark frosted glass + white icons
      //    so top-bar buttons never render white-on-white over dark posters.
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.light(),
          home: DetailScreen(
            site: demoSite,
            initialVideo: demoVideo,
            client: _IosHomeRedesignClient(),
            storage: storage,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 250));
      final glassButtons = tester
          .widgetList<IosNativeGlassButton>(find.byType(IosNativeGlassButton))
          .toList();
      expect(glassButtons, isNotEmpty);
      expect(glassButtons.every((b) => b.forceDark), isTrue);
      final glassPills = tester
          .widgetList<IosNativeGlassPill>(find.byType(IosNativeGlassPill))
          .toList();
      expect(glassPills, isNotEmpty);
      expect(glassPills.every((p) => p.forceDark), isTrue);

      // 2. PosterExpandSourceCard stays visible at progress <= 0.035 (prevents
      //    1-frame white hole on push frame 0 and return landing) and hides in flight.
      PosterExpandRegistry.activeCardId.value = 'card-1';
      PosterExpandRegistry.activeProgress.value = 0.0;
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: PosterExpandSourceCard(
              cardId: 'card-1',
              child: SizedBox(width: 120, height: 180),
            ),
          ),
        ),
      );
      expect(
        tester.widget<Visibility>(find.byType(Visibility)).visible,
        isTrue,
      );
      PosterExpandRegistry.activeProgress.value = 0.5;
      await tester.pump();
      expect(
        tester.widget<Visibility>(find.byType(Visibility)).visible,
        isFalse,
      );
      PosterExpandRegistry.activeProgress.value = 0.02;
      await tester.pump();
      expect(
        tester.widget<Visibility>(find.byType(Visibility)).visible,
        isTrue,
      );
      PosterExpandRegistry.activeCardId.value = null;
      PosterExpandRegistry.activeProgress.value = 0.0;

      // 3. SpiderExtensionsPanel & GuidePage use dark readable text in Light Mode.
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.light(),
          home: Scaffold(
            body: SingleChildScrollView(
              child: SpiderExtensionsPanel(
                storage: storage,
                client: _IosHomeRedesignClient(),
                sites: [demoSite],
                onChanged: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      for (final t in tester.widgetList<Text>(find.byType(Text))) {
        final color = t.style?.color;
        if (color != null) {
          expect(color.toARGB32(), isNot(0x99EBEBF5));
          expect(color.toARGB32(), isNot(0xD8EBEBF5));
        }
      }
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.light(),
          home: SpiderExtensionsGuidePage(onNotice: (_, __) {}),
        ),
      );
      await tester.pumpAndSettle();
      for (final t in tester.widgetList<Text>(find.byType(Text))) {
        final color = t.style?.color;
        if (color != null) {
          expect(color.toARGB32(), isNot(0xD8EBEBF5));
        }
      }

      // 4 & 5. Full AdaptiveShell testing live Light <-> Dark mode switching:
      //   - Global Search floating bar adapts dynamically in Light AND Dark Mode
      //   - Live TV tab + redesigned breathable Import modal with compact
      //     centered Save CTA button (width 200..256) work cleanly in BOTH modes
      //   - Settings subpage back button keeps foregroundColor == null for live native adaptation
      final themeMode = ValueNotifier<ThemeMode>(ThemeMode.light);
      addTearDown(themeMode.dispose);
      await tester.pumpWidget(
        ValueListenableBuilder<ThemeMode>(
          valueListenable: themeMode,
          builder: (_, mode, __) => MaterialApp(
            theme: ThemeData.light(),
            darkTheme: ThemeData.dark(),
            themeMode: mode,
            home: AdaptiveShell(
              storage: storage,
              client: CmsClient(
                client: MockClient((req) async {
                  if (req.url.toString() == 'https://live.example/main.m3u') {
                    return http.Response.bytes(
                      utf8.encode(
                        '#EXTM3U\n#EXTINF:-1 group-title="央视",CCTV1\nhttps://stream.example/cctv1.m3u8\n',
                      ),
                      200,
                    );
                  }
                  return http.Response('{"class":[],"list":[]}', 200);
                }),
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));

      // Open Search in Light Mode -> switch live to Dark Mode -> verify both palettes!
      await tester.tap(find.byKey(const ValueKey('home-search-button')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.byType(IosGlobalSearchPage), findsOneWidget);
      expect(
        tester.widget<CupertinoTextField>(find.byType(CupertinoTextField).first).style?.color,
        equals(ApplePalette.light.labelPrimary),
      );
      themeMode.value = ThemeMode.dark;
      await tester.pumpAndSettle();
      expect(
        tester.widget<CupertinoTextField>(find.byType(CupertinoTextField).first).style?.color,
        equals(ApplePalette.dark.labelPrimary),
      );
      themeMode.value = ThemeMode.light;
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('search-close-button')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));

      // Switch to Live TV tab and open redesigned Import Live Source sheet in Light + Dark.
      await tester.tap(find.text('直播').last);
      await tester.pumpAndSettle();
      expect(find.text('导入'), findsOneWidget);
      await tester.tap(find.text('导入'));
      await tester.pumpAndSettle();
      expect(find.text('独立导入直播源'), findsOneWidget);
      expect(find.text('高级选项（User-Agent / 台标模板）'), findsOneWidget);
      final saveBtnFinder = find.byKey(const ValueKey('live-import-save-btn'));
      expect(saveBtnFinder, findsOneWidget);
      final saveWidth = tester.getSize(saveBtnFinder).width;
      expect(saveWidth, greaterThanOrEqualTo(200.0));
      expect(saveWidth, lessThanOrEqualTo(256.0));
      themeMode.value = ThemeMode.dark;
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      Navigator.of(tester.element(saveBtnFinder)).pop();
      await tester.pumpAndSettle();

      // Settings -> 外观 back button uses native auto-adaptive foregroundColor (null).
      await tester.tap(find.text('设置').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('settings-category-appearance')));
      await tester.pumpAndSettle();
      final backBtn = tester.widget<IosNativeGlassButton>(
        find.byKey(const ValueKey('settings-drawer-back')),
      );
      expect(backBtn.foregroundColor, isNull);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );
}

class _FakeQuarkCatPawHost extends CatPawHost {
  _FakeQuarkCatPawHost(this.hash);

  final String hash;
  int port = 51111;

  @override
  Future<String> read(String address, {String method = 'GET'}) async {
    return jsonEncode({
      'parse': 0,
      'url': [
        '原画',
        'https://drive.quark.cn/file/ep1.mkv',
        '原画代理',
        'catpaw://$hash/spider/quark/3/proxy/st%2B1%2F2%3D%3D/ep1%20%5B4K%5D.mkv?fid=1',
      ],
      'header': {
        'Cookie': '__pus=pus_ios; __puus=puus_ios',
        'Referer': 'https://pan.quark.cn/',
      },
    });
  }

  @override
  Future<Uri> resolve(String address, {Completer<void>? cancellation}) async {
    final uri = Uri.parse(address);
    return Uri(
      scheme: 'http',
      host: '127.0.0.1',
      port: port,
      path: '/secret/$hash${uri.path}',
      query: uri.hasQuery ? uri.query : null,
    );
  }
}

class _RecordingNavigatorObserver extends NavigatorObserver {
  final List<Route<dynamic>> pushed;
  _RecordingNavigatorObserver(this.pushed);

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushed.add(route);
    super.didPush(route, previousRoute);
  }
}

class _IosHomeRedesignClient extends CmsClient {
  @override
  Future<CmsVideo> fetchDetail(CmsSite site, CmsVideo video) async => video;

  @override
  Future<(List<CmsCategory>, CmsListing)> fetchHome(CmsSite site) async {
    return (
      const [
        CmsCategory(id: '1', name: '电影'),
        CmsCategory(id: '2', name: '剧集'),
      ],
      const CmsListing(
        videos: [
          CmsVideo(
            id: 'hero-1',
            title: '罪蓝之路',
            year: '2026',
            area: '中国大陆',
            remarks: '更新至第12集',
            description: '两名刑警联手追查跨境悬疑大案的高燃缉凶故事。',
          ),
          CmsVideo(
            id: 'hero-2',
            title: '星海漫游',
            year: '2026',
            area: '美国',
            remarks: '4K HDR',
          ),
        ],
      ),
    );
  }
}
