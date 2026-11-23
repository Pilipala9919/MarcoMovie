// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/ios_avplayer_controller.dart';
import 'package:marco_movie/core/ios_mpv_profile.dart';
import 'package:marco_movie/core/local_media_proxy.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/core/web_media_resolver.dart';
import 'package:marco_movie/ui/ios_liquid_glass.dart';
import 'package:marco_movie/ui/player/ios_player_chrome.dart';
import 'package:marco_movie/ui/player/player_hud_prefs.dart';
import 'package:marco_movie/ui/player_screen.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'test_storage_helper.dart';

class _DualEngineFakeState extends Fake implements PlayerState {
  @override
  Playlist get playlist => const Playlist([]);
  @override
  bool get playing => true;
  @override
  bool get completed => false;
  @override
  Duration get position => const Duration(minutes: 2);
  @override
  Duration get duration => const Duration(minutes: 25);
  @override
  double get volume => 100.0;
  @override
  double get rate => 1.0;
  @override
  bool get buffering => false;
  @override
  Tracks get tracks => const Tracks();
  @override
  Track get track => const Track();
}

class _DualEngineFakeStream extends Fake implements PlayerStream {
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
  final volumeCtrl = StreamController<double>.broadcast();

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
  @override
  Stream<double> get volume => volumeCtrl.stream;

  void close() {
    widthCtrl.close();
    heightCtrl.close();
    trackCtrl.close();
    tracksCtrl.close();
    positionCtrl.close();
    durationCtrl.close();
    playingCtrl.close();
    bufferingCtrl.close();
    completedCtrl.close();
    errorCtrl.close();
    volumeCtrl.close();
  }
}

class _DualEngineFakePlayer extends Fake implements Player {
  @override
  final PlayerState state = _DualEngineFakeState();
  @override
  final _DualEngineFakeStream stream = _DualEngineFakeStream();
  @override
  final NativePlayer? platform = null;

  @override
  Future<void> open(Playable playable, {bool play = true}) async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> play() async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> playOrPause() async {}
  @override
  Future<void> seek(Duration duration) async {}
  @override
  Future<void> setRate(double rate) async {}
  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<void> setAudioTrack(AudioTrack track) async {}
  @override
  Future<void> setSubtitleTrack(SubtitleTrack track) async {}
  @override
  Future<void> dispose() async {
    stream.close();
  }
}

void main() {
  tearDown(() {
    IosLiquidGlassBridge.setAvailableForTest(null);
    WebMediaResolver.debugRuleSnifferOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(IosAvPlayerController.defaultChannel, null);
  });

  test(
    'CmsClient.resolveEpisodeForPlayback forwards rules and ads into WebMediaResolver',
    () async {
      List<Map<String, dynamic>> capturedRules = const [];
      List<String> capturedAds = const [];
      WebMediaResolver.debugRuleSnifferOverride = (
        url,
        headers,
        timeout, {
        rules = const [],
        ads = const [],
        clickScript,
      }) async {
        capturedRules = rules;
        capturedAds = ads;
        return const WebSniffResult(
          url: 'https://cdn.marco.test/stream.m3u8',
          headers: {'Referer': 'https://player.marco.test/'},
        );
      };

      const rule = CmsSniffRule(
        name: 'demo',
        hosts: ['player.marco.test'],
        regex: [r'\.m3u8'],
      );
      final client = CmsClient();
      final resolved = await client.resolveEpisodeForPlayback(
        const CmsSite(
          key: 'vod',
          name: '点播测试源',
          type: 1,
          api: 'http://127.0.0.1:9999/api',
        ),
        const CmsEpisode(name: '第1集', url: 'https://player.marco.test/watch/1'),
        parses: const [
          CmsParse(name: '解析1', type: 0, url: 'https://parse.marco.test/?url='),
        ],
        rules: const [rule],
        ads: const ['ad.marco.test'],
      );

      expect(resolved.url, 'https://cdn.marco.test/stream.m3u8');
      expect(capturedRules.map((r) => r['name']), ['demo']);
      expect(capturedAds, ['ad.marco.test']);
    },
  );

  testWidgets(
    'PlayerScreen applies stored iOS dual-engine/loudness/disk-cache prefs and renders Engine Switch + Vocal Loudness chrome',
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    (tester) async {
      tester.view.physicalSize = const Size(844, 390);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      SharedPreferences.setMockInitialValues({});
      final storage = await initTestStorage();
      await storage.setIosPlaybackEngineMode('mpv');
      await storage.setVocalLoudnessPreset('cinema_vocal');
      await storage.setMediaDiskCacheLimitMb(128);

      final fakePlayer = _DualEngineFakePlayer();
      final hudPrefs = PlayerHudPrefs(
        isDesktop: false,
        initial: PlayerHudPrefsData.defaultsFor(isDesktop: false),
      );
      addTearDown(hudPrefs.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: PlayerScreen(
            storage: storage,
            initialLineIndex: 0,
            initialEpisodeIndex: 0,
            site: const CmsSite(
              key: 'demo',
              name: 'Demo',
              type: 1,
              api: 'http://127.0.0.1:9999/api',
            ),
            video: const CmsVideo(
              id: 'vid1',
              title: '双内核测试影片',
              lines: [
                CmsLine(
                  name: '测试线路',
                  episodes: [
                    CmsEpisode(
                      name: '第1集',
                      url: 'http://127.0.0.1:9999/media/ep1.mp4',
                    ),
                  ],
                ),
              ],
            ),
            debugPlayer: fakePlayer,
            debugVideoSurface: const ColoredBox(color: Colors.black),
            debugHudPrefs: hudPrefs,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(DiskBlockCache.shared.maxBytes, 128 * 1024 * 1024);
      expect(find.byType(IosPlayerChrome), findsOneWidget);
      expect(find.byKey(const Key('ios-player-engine-button')), findsOneWidget);
      expect(
        find.byKey(const Key('ios-player-loudness-button')),
        findsOneWidget,
      );
      expect(find.text('MPV'), findsOneWidget);
      expect(find.text(VocalLoudnessPreset.cinemaVocal.shortLabelZh),
          findsOneWidget);

      // Tapping engine switch toggles persisted preference between MPV and AVPlayer.
      await tester.tap(find.byKey(const Key('ios-player-engine-button')));
      await tester.pump();
      expect(storage.iosPlaybackEngineMode, 'avplayer');

      await tester.pumpWidget(const SizedBox());
    },
  );
}
