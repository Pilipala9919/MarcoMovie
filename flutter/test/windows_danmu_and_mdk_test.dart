// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fvp/mdk.dart' as mdk;
import 'package:marco_movie/core/anime4k_controller.dart';
import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/danmu/danmu_prefs.dart';
import 'package:marco_movie/core/danmu/provider.dart';
import 'package:marco_movie/core/mdk_platform_player.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/core/ohos_runtime.dart';
import 'package:marco_movie/core/video_kernel.dart';
import 'package:marco_movie/core/windows_video_quality.dart';
import 'package:marco_movie/ui/adaptive_shell.dart';
import 'package:marco_movie/ui/danmu/danmu_layer.dart';
import 'package:marco_movie/ui/player/player_hud_prefs.dart';
import 'package:marco_movie/ui/player_screen.dart';
import 'package:marco_movie/ui/windows_appearance.dart';
import 'package:media_kit/media_kit.dart';

import 'test_storage_helper.dart';

class _FakeMdkBackend implements MdkNativeBackend {
  final ValueNotifier<int?> _textureId = ValueNotifier<int?>(null);
  final _statusCtrl =
      StreamController<({int oldStatus, int newStatus})>.broadcast();
  final _stateCtrl = StreamController<mdk.PlaybackState>.broadcast();
  final _eventCtrl =
      StreamController<({int error, String category, String detail})>.broadcast();

  final Map<String, String> properties = <String, String>{};
  final List<({int min, int max, bool drop})> bufferCalls = [];
  final List<({String uri, mdk.MediaType type})> externalMedias = [];
  final List<({int position, mdk.SeekFlag flags})> seekCalls = [];

  List<String> _videoDecoders = const <String>[];
  String _media = '';
  mdk.PlaybackState _state = mdk.PlaybackState.stopped;
  double _volume = 1.0;
  bool _mute = false;
  double _playbackRate = 1.0;
  int _loop = 0;
  int _positionMs = 0;
  int _bufferedMs = 0;
  bool _isLive = false;
  int prepareReturnCode = 0;
  int nextTextureId = 77;
  bool disposed = false;

  List<int> _activeAudioTracks = const <int>[0];
  List<int> _activeSubtitleTracks = const <int>[0];
  List<int> _activeVideoTracks = const <int>[0];

  MdkMediaSnapshot snapshot = MdkMediaSnapshot(
    durationMs: 120000,
    videoWidth: 1920,
    videoHeight: 1080,
    videoTracks: <VideoTrack>[
      VideoTrack.auto(),
      VideoTrack('0', 'HEVC 1080p', 'und', codec: 'hevc'),
    ],
    audioTracks: <AudioTrack>[
      AudioTrack.auto(),
      AudioTrack('0', '国语 AAC', 'zh', codec: 'aac'),
      AudioTrack('1', '日语 FLAC', 'ja', codec: 'flac'),
    ],
    subtitleTracks: <SubtitleTrack>[
      SubtitleTrack.auto(),
      SubtitleTrack.no(),
      SubtitleTrack('0', '简中 ASS', 'zh', codec: 'ass'),
      SubtitleTrack('1', '繁中 SRT', 'zh-Hant', codec: 'subrip'),
    ],
  );

  @override
  ValueListenable<int?> get textureIdListenable => _textureId;

  @override
  Stream<({int oldStatus, int newStatus})> get onStatusChanged =>
      _statusCtrl.stream;

  @override
  Stream<mdk.PlaybackState> get onStateChanged => _stateCtrl.stream;

  @override
  Stream<({int error, String category, String detail})> get onEvent =>
      _eventCtrl.stream;

  List<String> get videoDecoders => _videoDecoders;

  @override
  set videoDecoders(List<String> value) =>
      _videoDecoders = List<String>.of(value);

  String get media => _media;

  @override
  set media(String value) => _media = value;

  mdk.PlaybackState get state => _state;

  @override
  set state(mdk.PlaybackState value) {
    _state = value;
    if (!_stateCtrl.isClosed) _stateCtrl.add(value);
  }

  double get volume => _volume;

  @override
  set volume(double value) => _volume = value;

  bool get mute => _mute;

  @override
  set mute(bool value) => _mute = value;

  double get playbackRate => _playbackRate;

  @override
  set playbackRate(double value) => _playbackRate = value;

  int get loop => _loop;

  @override
  set loop(int value) => _loop = value;

  @override
  int get positionMs => _positionMs;

  set positionMs(int value) => _positionMs = value;

  @override
  int get bufferedMs => _bufferedMs;

  set bufferedMs(int value) => _bufferedMs = value;

  @override
  bool get isLive => _isLive;

  set isLive(bool value) => _isLive = value;

  @override
  void setProperty(String key, String value) {
    properties[key] = value;
  }

  @override
  void setBufferRange({int min = -1, int max = -1, bool drop = false}) {
    bufferCalls.add((min: min, max: max, drop: drop));
  }

  @override
  void setMediaForType(String uri, mdk.MediaType type) {
    externalMedias.add((uri: uri, type: type));
  }

  @override
  set activeAudioTracks(List<int> value) =>
      _activeAudioTracks = List<int>.of(value);

  List<int> get activeAudioTracks => _activeAudioTracks;

  @override
  set activeSubtitleTracks(List<int> value) =>
      _activeSubtitleTracks = List<int>.of(value);

  List<int> get activeSubtitleTracks => _activeSubtitleTracks;

  @override
  set activeVideoTracks(List<int> value) =>
      _activeVideoTracks = List<int>.of(value);

  List<int> get activeVideoTracks => _activeVideoTracks;

  @override
  Future<int> prepare({int position = 0}) async {
    _positionMs = position;
    return prepareReturnCode;
  }

  @override
  Future<int> updateTexture({int? width, int? height}) async {
    _textureId.value = nextTextureId;
    return nextTextureId;
  }

  @override
  Future<int> seek({required int position, required mdk.SeekFlag flags}) async {
    seekCalls.add((position: position, flags: flags));
    _positionMs = position;
    return position;
  }

  @override
  MdkMediaSnapshot readMediaSnapshot() => snapshot;

  void emitStatus(int oldStatus, int newStatus) {
    _statusCtrl.add((oldStatus: oldStatus, newStatus: newStatus));
  }

  void emitEvent({int error = 0, required String category, String detail = ''}) {
    _eventCtrl.add((error: error, category: category, detail: detail));
  }

  @override
  Future<void> disposeAsync() async {
    disposed = true;
    await _statusCtrl.close();
    await _stateCtrl.close();
    await _eventCtrl.close();
    _textureId.dispose();
  }
}

class _FakePlayerState extends Fake implements PlayerState {
  Playlist playlistValue = const Playlist([]);
  bool playingValue = true;
  bool completedValue = false;
  Duration positionValue = Duration.zero;
  Duration durationValue = const Duration(minutes: 45);
  double volumeValue = 80.0;
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
      volumeCtrl.close(),
    ]);
  }
}

class _FakePlayer extends Fake implements Player {
  final _FakePlayerState _state = _FakePlayerState();
  final _FakePlayerStream _stream = _FakePlayerStream();
  bool disposed = false;

  void emitPosition(Duration pos) {
    _state.positionValue = pos;
    if (!disposed) _stream.positionCtrl.add(pos);
  }

  @override
  PlatformPlayer? get platform => null;
  @override
  PlayerState get state => _state;
  @override
  PlayerStream get stream => _stream;

  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    if (playable is Media) _state.playlistValue = Playlist([playable]);
    _state.durationValue = const Duration(minutes: 45);
    _state.positionValue = const Duration(milliseconds: 500);
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
  Future<void> seek(Duration duration) async => emitPosition(duration);

  @override
  Future<void> setRate(double rate) async => _state.rateValue = rate;

  @override
  Future<void> setVolume(double volume) async {
    _state.volumeValue = volume;
    if (!disposed) _stream.volumeCtrl.add(volume);
  }

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

class _StubShellClient extends CmsClient {
  @override
  Future<(List<CmsCategory>, CmsListing)> fetchHome(CmsSite site) async =>
      (const <CmsCategory>[], const CmsListing(videos: <CmsVideo>[]));
}

void main() {
  tearDown(() {
    OhosRuntime.resetForTesting();
    debugDefaultTargetPlatformOverride = null;
  });

  group('Windows Danmu Hidden Fullscreen Progress Bar Regression', () {
    testWidgets(
      'DanmuLayer keeps scrolling past 500ms via positionListenable even when parent widget positionMs stays frozen',
      (tester) async {
        final posNotifier = ValueNotifier<int>(0);
        addTearDown(posNotifier.dispose);

        const items = <DanmuItem>[
          DanmuItem(
            id: 'd1',
            timeMs: 200,
            mode: 1,
            rgbColor: 0xFFFFFF,
            text: '隐藏进度条后弹幕依然丝滑滚动',
          ),
          DanmuItem(
            id: 'd2',
            timeMs: 1800,
            mode: 1,
            rgbColor: 0x00FFAA,
            text: '超过两秒进度条隐藏后也不会静止',
          ),
        ];

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 1280,
                height: 720,
                child: DanmuLayer(
                  settings: const DanmuSettings(enabled: true),
                  // Frozen at 0 to simulate PlayerScreen skipping setState()
                  // while HUD is hidden and slimProgress is disabled.
                  positionMs: 0,
                  positionListenable: posNotifier,
                  playing: true,
                  items: items,
                ),
              ),
            ),
          ),
        );

        final customPaintFinder = find.descendant(
          of: find.byType(DanmuLayer),
          matching: find.byType(CustomPaint),
        );
        expect(customPaintFinder, findsOneWidget);
        final painter =
            tester.widget<CustomPaint>(customPaintFinder).painter
                as DanmuLayerPainter;

        // Simulate 4 seconds of continuous playback ticks via ValueNotifier only
        // (zero parent widget rebuilds).
        double? xAt1000;
        double? xAt2500;
        double? xAt4000;
        for (var t = 100; t <= 4000; t += 100) {
          posNotifier.value = t;
          await tester.pump(const Duration(milliseconds: 100));
          if (t == 1000) {
            xAt1000 = painter.layoutEngine.activeEntries
                .firstWhere((e) => e.item.id == 'd1')
                .x;
          } else if (t == 2500) {
            xAt2500 = painter.layoutEngine.activeEntries
                .firstWhere((e) => e.item.id == 'd1')
                .x;
          } else if (t == 4000) {
            xAt4000 = painter.layoutEngine.activeEntries
                .firstWhere((e) => e.item.id == 'd1')
                .x;
          }
        }

        expect(painter.resolveRawPositionMs(), greaterThanOrEqualTo(3900));
        expect(xAt1000, isNotNull);
        expect(xAt2500, isNotNull);
        expect(xAt4000, isNotNull);
        // Danmu must keep moving right-to-left across the entire 4s window
        // instead of freezing at 500ms.
        expect(xAt2500!, lessThan(xAt1000! - 120));
        expect(xAt4000!, lessThan(xAt2500! - 120));
        // Second danmu emitted at 1800ms must also have entered and moved.
        expect(
          painter.layoutEngine.activeEntries.any((e) => e.item.id == 'd2'),
          isTrue,
        );
      },
    );

    testWidgets(
      'Windows PlayerScreen keeps feeding DanmuLayer position when controls auto-hide and slim progress bar is disabled',
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
      (tester) async {
        final storage = await initTestStorage();
        final hudPrefs = PlayerHudPrefs.inMemory(
          isDesktop: true,
          initial: PlayerHudPrefsData.defaultsFor(
            isDesktop: true,
          ).copyWith(slimProgress: false),
        );
        addTearDown(hudPrefs.dispose);
        final appearance = WindowsAppearance(Directory.systemTemp);
        addTearDown(appearance.dispose);
        final player = _FakePlayer();
        addTearDown(player.dispose);

        await tester.binding.setSurfaceSize(const Size(1280, 720));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        const site = CmsSite(
          key: 'win_danmu_test',
          name: 'Test',
          type: 1,
          api: 'https://owned.invalid/api',
        );
        const video = CmsVideo(
          id: 'vid_danmu_1',
          title: '测试动漫',
          lines: [
            CmsLine(
              name: '线路1',
              episodes: [
                CmsEpisode(name: '第01集', url: 'https://owned.invalid/1.m3u8'),
              ],
            ),
          ],
        );

        await tester.pumpWidget(
          MaterialApp(
            builder: (_, child) =>
                WindowsAppearanceScope(controller: appearance, child: child!),
            home: PlayerScreen(
              site: site,
              video: video,
              initialLineIndex: 0,
              initialEpisodeIndex: 0,
              storage: storage,
              debugPlayer: player,
              debugHudPrefs: hudPrefs,
              debugDanmuSettings: const DanmuSettings(enabled: true),
              debugVideoSurface: const ColoredBox(color: Colors.black),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 200));

        // Let HUD auto-hide (5 seconds) while slim progress bar is disabled.
        await tester.pump(const Duration(seconds: 5));

        final danmuLayer = tester.widget<DanmuLayer>(find.byType(DanmuLayer));
        expect(danmuLayer.positionListenable, isNotNull);

        // Emit position updates over 3.5 seconds while HUD stays hidden.
        for (var ms = 1000; ms <= 4500; ms += 250) {
          player.emitPosition(Duration(milliseconds: ms));
          await tester.pump(const Duration(milliseconds: 250));
        }

        expect(danmuLayer.positionListenable!.value, 4500);
        final customPaintFinder = find.descendant(
          of: find.byType(DanmuLayer),
          matching: find.byType(CustomPaint),
        );
        final painter =
            tester.widget<CustomPaint>(customPaintFinder).painter
                as DanmuLayerPainter;
        expect(painter.resolveRawPositionMs(), greaterThanOrEqualTo(4400));

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      },
    );
  });

  group('MDK Windows iGPU Playback Engine', () {
    test('WindowsPlaybackEngine parsing and StorageService persistence', () async {
      expect(WindowsPlaybackEngine.fromId(null), WindowsPlaybackEngine.mpv);
      expect(WindowsPlaybackEngine.fromId('mpv'), WindowsPlaybackEngine.mpv);
      expect(WindowsPlaybackEngine.fromId('mdk'), WindowsPlaybackEngine.mdk);
      expect(WindowsPlaybackEngine.fromId('FVP'), WindowsPlaybackEngine.mdk);

      final storage = await initTestStorage();
      expect(storage.windowsPlaybackEngine, WindowsPlaybackEngine.mpv.id);
      await storage.setWindowsPlaybackEngine('mdk');
      expect(storage.windowsPlaybackEngine, WindowsPlaybackEngine.mdk.id);
      await storage.setWindowsPlaybackEngine('unknown');
      expect(storage.windowsPlaybackEngine, WindowsPlaybackEngine.mpv.id);
    });

    test(
      'MdkPlatformPlayer configures iGPU D3D11/MFT/DXVA decoders, headers, buffer, tracks and status events',
      () async {
        final backend = _FakeMdkBackend();
        final mdkPlayer = MdkPlatformPlayer(
          kernelStrategy: 'exo',
          debugBackend: backend,
        );
        addTearDown(mdkPlayer.dispose);

        // Default iGPU-tuned decoder priority & driver stability properties
        expect(
          backend.videoDecoders,
          MdkPlatformPlayer.defaultIgpuDecoders,
        );
        expect(backend.properties['video.decoder'], 'shader_resource=0');
        expect(backend.properties['keep_open'], '1');
        expect(backend.properties['avio.reconnect'], '1');

        // Switching to 'ijk' puts legacy DXVA first for older Intel HD / AMD APUs
        mdkPlayer.applyKernelStrategy('ijk', isLive: false);
        expect(
          backend.videoDecoders,
          MdkPlatformPlayer.legacyIgpuCompatDecoders,
        );
        expect(backend.videoDecoders.first, 'DXVA');

        // Live strategy sets lean low-latency buffer
        mdkPlayer.applyKernelStrategy('exo', isLive: true);
        expect(backend.bufferCalls.last.min, 500);
        expect(backend.bufferCalls.last.max, 3000);
        expect(backend.bufferCalls.last.drop, isTrue);

        // Open media with headers & resume start position
        await mdkPlayer.open(
          Media(
            'https://owned.invalid/4k-hdr.mkv',
            httpHeaders: const <String, String>{
              'User-Agent': 'MarcoTest/1.0',
              'Referer': 'https://owned.invalid/watch',
              'X-Token': 'abc123',
            },
            start: const Duration(seconds: 30),
          ),
          play: true,
        );

        expect(backend.media, 'https://owned.invalid/4k-hdr.mkv');
        expect(backend.properties['avio.user_agent'], 'MarcoTest/1.0');
        expect(backend.properties['avio.referer'], 'https://owned.invalid/watch');
        expect(
          backend.properties['avio.headers'],
          contains('User-Agent: MarcoTest/1.0\r\n'),
        );
        expect(backend.properties['avio.headers'], contains('X-Token: abc123\r\n'));
        expect(mdkPlayer.textureId, 77);
        expect(mdkPlayer.state.playing, isTrue);
        expect(mdkPlayer.state.width, 1920);
        expect(mdkPlayer.state.height, 1080);
        expect(mdkPlayer.state.duration, const Duration(seconds: 120));
        expect(mdkPlayer.state.tracks.audio.length, 3);
        expect(mdkPlayer.state.tracks.subtitle.length, 4);

        // Subsequent open without Referer clears stale avio.referer
        await mdkPlayer.setProperty('referrer', '');
        await mdkPlayer.open(
          Media('https://owned.invalid/ep2.mkv'),
          play: true,
        );
        expect(backend.properties['avio.referer'], '');
        expect(backend.properties['avio.headers'], '');

        // Volume (0..200 -> 0.0..2.0), rate, seek, loop
        await mdkPlayer.setVolume(150);
        expect(backend.volume, closeTo(1.5, 0.001));
        await mdkPlayer.setRate(1.75);
        expect(backend.playbackRate, closeTo(1.75, 0.001));
        await mdkPlayer.seek(const Duration(seconds: 65));
        expect(backend.seekCalls.last.position, 65000);
        await mdkPlayer.setPlaylistMode(PlaylistMode.single);
        expect(backend.loop, -1);
        await mdkPlayer.setPlaylistMode(PlaylistMode.none);
        expect(backend.loop, 0);

        // Embedded & external track selection
        await mdkPlayer.setAudioTrack(mdkPlayer.state.tracks.audio[2]);
        expect(backend.activeAudioTracks, <int>[1]);
        await mdkPlayer.setAudioTrack(
          AudioTrack.uri('https://owned.invalid/ext.m4a'),
        );
        expect(backend.externalMedias.last.type, mdk.MediaType.audio);

        await mdkPlayer.setSubtitleTrack(SubtitleTrack.no());
        expect(backend.activeSubtitleTracks, isEmpty);
        await mdkPlayer.setSubtitleTrack(mdkPlayer.state.tracks.subtitle[2]);
        expect(backend.activeSubtitleTracks, <int>[0]);
        await mdkPlayer.setSubtitleTrack(
          SubtitleTrack.uri('https://owned.invalid/sub.ass'),
        );
        expect(backend.externalMedias.last.type, mdk.MediaType.subtitle);

        // MediaStatus end -> completed stream
        final completedFuture = mdkPlayer.stream.completed.firstWhere((c) => c);
        backend.emitStatus(
          mdk.MediaStatus.loaded,
          mdk.MediaStatus.loaded | mdk.MediaStatus.end,
        );
        expect(await completedFuture, isTrue);

        // Reader open error event propagates to error stream
        final errFuture = mdkPlayer.stream.error.first;
        backend.emitEvent(
          error: -2,
          category: 'reader.open',
          detail: '404 Not Found',
        );
        expect(await errFuture, contains('MDK reader.open'));
      },
    );

    testWidgets(
      'VideoKernel selects windowsMdk mode, builds Texture surface, returns null subtitle overlay, and keeps MPV controllers disabled',
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
      timeout: const Timeout(Duration(seconds: 15)),
      (tester) async {
        final backend = _FakeMdkBackend();
        final kernel = VideoKernel.create(
          hwdec: 'auto-safe',
          windowsEngine: WindowsPlaybackEngine.mdk,
          kernelStrategy: 'exo',
          debugMdkBackend: backend,
        );
        addTearDown(kernel.player.dispose);

        expect(kernel.mode, VideoKernelMode.windowsMdk);
        expect(kernel.isMdk, isTrue);
        expect(kernel.mdkPlatform, isNotNull);
        expect(kernel.buildSubtitleOverlay(), isNull);

        // MPV-only controllers must cleanly report unavailable on MDK
        final anime4k = Anime4kController();
        final winQuality = WindowsVideoQualityController();
        addTearDown(anime4k.dispose);
        addTearDown(winQuality.dispose);
        expect(anime4k.isAvailableForPlayer(kernel.player), isFalse);
        expect(winQuality.isAvailableForPlayer(kernel.player), isFalse);

        await kernel.player.open(
          Media('https://owned.invalid/test.mp4'),
          play: true,
        );

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 640,
                height: 360,
                child: kernel.buildVideoSurface(
                  fit: BoxFit.contain,
                  videoWidth: 1920,
                  videoHeight: 1080,
                ),
              ),
            ),
          ),
        );

        final tex = tester.widget<Texture>(find.byType(Texture));
        expect(tex.textureId, 77);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() => kernel.player.dispose());
      },
    );

    test(
      'VideoKernel preserves OhosPlatformPlayer when OhosRuntime.isOhos is true',
      () async {
        OhosRuntime.debugIsOhosOverride = true;
        final kernel = VideoKernel.create(
          hwdec: 'auto-safe',
          windowsEngine: WindowsPlaybackEngine.mdk,
        );
        addTearDown(kernel.player.dispose);
        expect(kernel.mode, VideoKernelMode.ohosHardwareHdr);
        expect(kernel.isMdk, isFalse);
      },
    );

    testWidgets(
      'Windows Settings allows switching playback engine to MDK and persists preference',
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
      (tester) async {
        final storage = await initTestStorage();
        await tester.runAsync(
          () => storage.saveConfig(
            jsonEncode({
              'sites': [
                {
                  'key': 'owned',
                  'name': '测试源',
                  'type': 1,
                  'api': 'https://owned.invalid/api',
                },
              ],
            }),
          ),
        );
        final appearance = WindowsAppearance(Directory.systemTemp);
        addTearDown(appearance.dispose);

        await tester.binding.setSurfaceSize(const Size(1280, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        await tester.pumpWidget(
          MaterialApp(
            builder: (_, child) =>
                WindowsAppearanceScope(controller: appearance, child: child!),
            home: AdaptiveShell(
              storage: storage,
              client: _StubShellClient(),
              onSetPreventCloseForTest: (_) async {},
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Open Settings -> Playback tab
        await tester.tap(find.byTooltip('设置'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(WinButton, '播放'));
        await tester.pumpAndSettle();

        final engineSection =
            find.byKey(const ValueKey('windows-settings-playback-engine'));
        expect(engineSection, findsOneWidget);

        final mdkBtn = find.byKey(const ValueKey('win-setting-engine-mdk'));
        await tester.ensureVisible(mdkBtn);
        await tester.tap(mdkBtn);
        await tester.pumpAndSettle();

        expect(storage.windowsPlaybackEngine, WindowsPlaybackEngine.mdk.id);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      },
    );

    testWidgets(
      'Windows Player More menu exposes playback engine switcher and persists MDK selection',
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
      (tester) async {
        final storage = await initTestStorage();
        final appearance = WindowsAppearance(Directory.systemTemp);
        addTearDown(appearance.dispose);
        final player = _FakePlayer();
        addTearDown(player.dispose);

        await tester.binding.setSurfaceSize(const Size(1280, 720));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        const site = CmsSite(
          key: 'win_engine_menu_test',
          name: 'Test',
          type: 1,
          api: 'https://owned.invalid/api',
        );
        const video = CmsVideo(
          id: 'vid_engine_1',
          title: '核显测试片',
          lines: [
            CmsLine(
              name: '线路1',
              episodes: [
                CmsEpisode(name: '第01集', url: 'https://owned.invalid/1.mp4'),
              ],
            ),
          ],
        );

        await tester.pumpWidget(
          MaterialApp(
            builder: (_, child) =>
                WindowsAppearanceScope(controller: appearance, child: child!),
            home: PlayerScreen(
              site: site,
              video: video,
              initialLineIndex: 0,
              initialEpisodeIndex: 0,
              storage: storage,
              debugPlayer: player,
              debugVideoSurface: const ColoredBox(color: Colors.black),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 250));

        // Open Windows desktop "More" popover
        final moreBtn = find.byKey(const Key('desktop-more-button'));
        expect(moreBtn, findsOneWidget);
        await tester.tap(moreBtn);
        await tester.pumpAndSettle();

        final engineRow =
            find.byKey(const ValueKey('windows-more-engine-switch'));
        expect(engineRow, findsOneWidget);
        expect(find.text('MPV 旗舰'), findsOneWidget);

        await tester.tap(engineRow);
        await tester.pumpAndSettle();

        final mdkOption =
            find.byKey(const ValueKey('player-engine-option-mdk'));
        expect(mdkOption, findsOneWidget);
        await tester.tap(mdkOption);
        await tester.pumpAndSettle();

        expect(storage.windowsPlaybackEngine, WindowsPlaybackEngine.mdk.id);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      },
    );
  });
}
