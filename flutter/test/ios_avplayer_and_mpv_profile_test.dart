// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/core/ios_avplayer_controller.dart';
import 'package:marco_movie/core/ios_mpv_profile.dart';
import 'package:media_kit/media_kit.dart';

class _FakeMpvPlayer extends Fake implements Player {
  @override
  PlatformPlayer? get platform => null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('IosMpvProfile — RAM-tiered buffers, HDR tone-mapping & 4-tier vocal loudness', () {
    test('selects 128MiB/32MiB on >= 6GB RAM (256MiB/64MiB large) and 64MiB/16MiB on < 6GB RAM', () {
      const fourGb = 4 * 1024 * 1024 * 1024;
      const sixGbReported = 5850000000; // ~5.45 GiB reported by iOS on 6GB devices
      const eightGb = 8 * 1024 * 1024 * 1024;

      final under6 = IosMpvProfile.buildMpvProperties(
        physicalMemoryBytes: fourGb,
      );
      expect(under6['demuxer-max-bytes'], '67108864'); // 64 MiB
      expect(under6['demuxer-max-back-bytes'], '16777216'); // 16 MiB
      expect(under6['demuxer-readahead-secs'], '30');

      final sixGbDefault = IosMpvProfile.buildMpvProperties(
        physicalMemoryBytes: sixGbReported,
      );
      expect(sixGbDefault['demuxer-max-bytes'], '134217728'); // 128 MiB
      expect(sixGbDefault['demuxer-max-back-bytes'], '33554432'); // 32 MiB
      expect(sixGbDefault['demuxer-readahead-secs'], '60');

      final eightGbLarge = IosMpvProfile.buildMpvProperties(
        physicalMemoryBytes: eightGb,
        largeBuffer: true,
      );
      expect(eightGbLarge['demuxer-max-bytes'], '268435456'); // 256 MiB
      expect(eightGbLarge['demuxer-max-back-bytes'], '67108864'); // 64 MiB
      expect(eightGbLarge['demuxer-readahead-secs'], '90');

      final liveProps = IosMpvProfile.buildMpvProperties(
        physicalMemoryBytes: eightGb,
        isLive: true,
      );
      expect(liveProps['demuxer-max-bytes'], '16777216');
      expect(liveProps['demuxer-max-back-bytes'], '4194304');
      expect(liveProps['demuxer-readahead-secs'], '5');
    });

    test('configures HDR tone-mapping, hr-seek=yes, and sub-ass-override=scale', () {
      final autoHdr = IosMpvProfile.buildMpvProperties(
        hdrToneMapping: IosHdrToneMappingMode.auto,
      );
      expect(autoHdr['tone-mapping'], 'bt.2390');
      expect(autoHdr['hdr-compute-peak'], 'yes');
      expect(autoHdr['gamut-mapping-mode'], 'perceptual');
      expect(autoHdr['dither-depth'], 'auto');
      expect(autoHdr['hr-seek'], 'yes');
      expect(autoHdr['sub-ass-override'], 'scale');

      final bt2446a = IosMpvProfile.buildMpvProperties(
        hdrToneMapping: IosHdrToneMappingMode.bt2446a,
      );
      expect(bt2446a['tone-mapping'], 'bt.2446a');
      expect(bt2446a['hdr-compute-peak'], 'yes');
    });

    test('builds and applies 4-tier vocal loudness presets (off/light/standard/cinema_vocal)', () async {
      expect(
        VocalLoudnessPreset.fromId('cinema_vocal'),
        VocalLoudnessPreset.cinemaVocal,
      );
      expect(
        IosMpvProfile.buildVocalLoudnessProperties(VocalLoudnessPreset.off),
        equals(const {'volume-max': '100', 'af': ''}),
      );
      expect(
        IosMpvProfile.buildVocalLoudnessProperties(VocalLoudnessPreset.light),
        equals(const {
          'volume-max': '150',
          'af': 'lavfi=[dynaudnorm=f=150:g=15:p=0.90:m=3.0]',
        }),
      );
      expect(
        IosMpvProfile.buildVocalLoudnessProperties(VocalLoudnessPreset.standard),
        equals(const {
          'volume-max': '200',
          'af': 'lavfi=[dynaudnorm=f=150:g=15:p=0.95:m=6.0]',
        }),
      );
      final cinema = IosMpvProfile.buildVocalLoudnessProperties(
        VocalLoudnessPreset.cinemaVocal,
      );
      expect(cinema['volume-max'], '200');
      expect(cinema['af'], contains('dynaudnorm='));
      expect(cinema['af'], contains('lavfi=['));

      final applied = <String, String>{};
      final fakePlayer = _FakeMpvPlayer();
      await IosMpvProfile.applyToPlayer(
        fakePlayer,
        physicalMemoryBytes: 8 * 1024 * 1024 * 1024,
        hdrToneMapping: IosHdrToneMappingMode.bt2390,
        vocalLoudness: VocalLoudnessPreset.standard,
        propertySetterOverride: (k, v) async => applied[k] = v,
      );
      expect(applied['demuxer-max-bytes'], '134217728');
      expect(applied['tone-mapping'], 'bt.2390');
      expect(applied['volume-max'], '200');
      expect(applied['af'], contains('dynaudnorm='));

      applied.clear();
      await IosMpvProfile.applyVocalLoudness(
        fakePlayer,
        VocalLoudnessPreset.off,
        propertySetterOverride: (k, v) async => applied[k] = v,
      );
      expect(applied, equals(const {'volume-max': '100', 'af': ''}));
    });
  });

  group('IosAvPlayerController — Static precheck, headers, fallback, PiP, AirPlay 2 & telemetry', () {
    const channel = IosAvPlayerController.defaultChannel;

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('static pre-check recommends libmpv for MKV/FLV/AVI/ASS and allows MP4/M3U8/MOV', () {
      expect(
        IosAvPlayerController.checkUrlCompatibility('https://cdn.example/video.mp4').supported,
        isTrue,
      );
      expect(
        IosAvPlayerController.checkUrlCompatibility('http://127.0.0.1:18080/proxy/master.m3u8').supported,
        isTrue,
      );
      expect(
        IosAvPlayerController.checkUrlCompatibility('https://cdn.example/movie.mov').supported,
        isTrue,
      );

      for (final badUrl in const [
        'https://cdn.example/movie.mkv?token=1',
        'https://cdn.example/live.flv',
        'https://cdn.example/clip.avi',
        'http://127.0.0.1:9000/stream?format=mkv',
      ]) {
        final res = IosAvPlayerController.checkUrlCompatibility(badUrl);
        expect(res.supported, isFalse, reason: badUrl);
        expect(res.reason, isNotEmpty);
      }

      // External .ass / .ssa subtitle forces MPV fallback
      final assRes = IosAvPlayerController.checkUrlCompatibility(
        'https://cdn.example/video.mp4',
        externalSubtitles: const ['https://cdn.example/sub.ass'],
      );
      expect(assRes.supported, isFalse);
      expect(assRes.detectedExtension, '.ass');

      // Explicit .mp4 URL stays supported even if display episodeName mentions .mkv
      expect(
        IosAvPlayerController.checkUrlCompatibility(
          'file:///tmp/ios_e1.mp4',
          episodeName: '第01集 DV.Atmos.HEVC.mkv',
        ).supported,
        isTrue,
      );
    });

    test('open() emits FallbackToMpvRequested statically on MKV/ASS without invoking native open', () async {
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (call.method == 'getTelemetry') {
          return <String, dynamic>{
            'thermalState': 'nominal',
            'physicalMemoryBytes': 6 * 1024 * 1024 * 1024,
            'isPipSupported': true,
            'isPipActive': false,
            'isAirPlayActive': false,
          };
        }
        return true;
      });

      final ctrl = IosAvPlayerController(
        platformOverride: TargetPlatform.iOS,
        isOhosOverride: false,
        isWebOverride: false,
      );
      addTearDown(ctrl.dispose);

      final fallbacks = <FallbackToMpvRequested>[];
      ctrl.onFallbackToMpvRequested.listen(fallbacks.add);

      final opened = await ctrl.open(
        'https://cdn.example/anime.mkv',
        startPosition: const Duration(seconds: 45),
      );
      await Future<void>.delayed(Duration.zero);

      expect(opened, isFalse);
      expect(calls.where((c) => c.method == 'open'), isEmpty);
      expect(fallbacks, hasLength(1));
      expect(fallbacks.single.positionMs, 45000);
      expect(fallbacks.single.isStaticPrecheck, isTrue);
    });

    test('open() forwards custom HTTP headers and 127.0.0.1 proxy URLs; runtime failure triggers FallbackToMpvRequested', () async {
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (call.method == 'getTelemetry') {
          return <String, dynamic>{
            'thermalState': 'fair',
            'physicalMemoryBytes': 8589934592,
            'isPipSupported': true,
            'isPipActive': false,
            'isAirPlayActive': false,
          };
        }
        return true;
      });

      final ctrl = IosAvPlayerController(
        platformOverride: TargetPlatform.iOS,
        isOhosOverride: false,
        isWebOverride: false,
      );
      addTearDown(ctrl.dispose);

      final fallbacks = <FallbackToMpvRequested>[];
      ctrl.onFallbackToMpvRequested.listen(fallbacks.add);

      final ok = await ctrl.open(
        'http://127.0.0.1:18123/proxy/stream.mp4',
        headers: const {
          'User-Agent': 'MarcoTest/1.0',
          'Referer': 'https://source.example/',
          'Cookie': 'sid=abc',
        },
        startPosition: const Duration(seconds: 12),
      );
      expect(ok, isTrue);

      final openCall = calls.singleWhere((c) => c.method == 'open');
      final args = Map<String, dynamic>.from(openCall.arguments as Map);
      expect(args['url'], 'http://127.0.0.1:18123/proxy/stream.mp4');
      expect(args['startPositionMs'], 12000);
      expect(
        Map<String, dynamic>.from(args['headers'] as Map),
        equals(const {
          'User-Agent': 'MarcoTest/1.0',
          'Referer': 'https://source.example/',
          'Cookie': 'sid=abc',
        }),
      );

      // Simulate native AVPlayerItem.status == .failed callback via MethodChannel
      const codec = StandardMethodCodec();
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
        channel.name,
        codec.encodeMethodCall(
          const MethodCall('onFallbackToMpv', <String, dynamic>{
            'positionMs': 94500,
            'reason': 'AVPlayerItem status failed: unsupported audio',
          }),
        ),
        (_) {},
      );
      await Future<void>.delayed(Duration.zero);

      expect(fallbacks, hasLength(1));
      expect(fallbacks.single.positionMs, 94500);
      expect(fallbacks.single.isStaticPrecheck, isFalse);
      expect(fallbacks.single.reason, contains('unsupported audio'));
    });

    test('deduplicates fallbackToMpv + onFallbackToMpv per opened item and resets on next open()', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'getTelemetry') {
          return <String, dynamic>{
            'thermalState': 'nominal',
            'physicalMemoryBytes': 6442450944,
            'isPipSupported': true,
            'isPipActive': false,
            'isAirPlayActive': false,
          };
        }
        return true;
      });

      final ctrl = IosAvPlayerController(
        platformOverride: TargetPlatform.iOS,
        isOhosOverride: false,
        isWebOverride: false,
      );
      addTearDown(ctrl.dispose);

      final fallbacks = <FallbackToMpvRequested>[];
      ctrl.onFallbackToMpvRequested.listen(fallbacks.add);

      expect(
        await ctrl.open('https://cdn.example/video1.mp4'),
        isTrue,
      );

      // Emit via EventChannel path first, then duplicate via MethodChannel onFallbackToMpv.
      ctrl.handleNativeEvent(const <Object?, Object?>{
        'type': 'fallbackToMpv',
        'positionMs': 12345,
        'reason': 'AVPlayer failed',
      });
      const codec = StandardMethodCodec();
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
        channel.name,
        codec.encodeMethodCall(
          const MethodCall('onFallbackToMpv', <String, dynamic>{
            'positionMs': 12345,
            'reason': 'AVPlayer failed',
          }),
        ),
        (_) {},
      );
      await Future<void>.delayed(Duration.zero);

      expect(fallbacks, hasLength(1));
      expect(fallbacks.single.positionMs, 12345);

      // Opening a second item resets the per-item deduplication flag.
      expect(
        await ctrl.open('https://cdn.example/video2.mp4'),
        isTrue,
      );
      ctrl.handleNativeEvent(const <Object?, Object?>{
        'type': 'fallbackToMpv',
        'positionMs': 54321,
        'reason': 'Second item failed',
      });
      await Future<void>.delayed(Duration.zero);

      expect(fallbacks, hasLength(2));
      expect(fallbacks.last.positionMs, 54321);
      expect(fallbacks.last.reason, 'Second item failed');
    });

    test('PiP lifecycle, AirPlay 2 state & thermal telemetry streams update controller state', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'getTelemetry') {
          return <String, dynamic>{
            'thermalState': 'nominal',
            'physicalMemoryBytes': 6442450944,
            'isPipSupported': true,
            'isPipActive': false,
            'isAirPlayActive': false,
          };
        }
        return true;
      });

      final ctrl = IosAvPlayerController(
        platformOverride: TargetPlatform.iOS,
        isOhosOverride: false,
        isWebOverride: false,
      );
      addTearDown(ctrl.dispose);

      final pipStates = <bool>[];
      final airPlayStates = <bool>[];
      final thermalStates = <IosThermalState>[];
      var restoredCount = 0;

      ctrl.onPipStateChanged.listen(pipStates.add);
      ctrl.onAirPlayStateChanged.listen(airPlayStates.add);
      ctrl.onThermalStateChanged.listen(thermalStates.add);
      ctrl.onPipRestoreForeground.listen((_) => restoredCount++);

      await ctrl.initialize();
      expect(ctrl.isPipSupported, isTrue);
      expect(ctrl.physicalMemoryBytes, 6442450944);
      expect(ctrl.thermalState, IosThermalState.nominal);

      expect(await ctrl.startPip(), isTrue);
      expect(ctrl.isPipActive, isTrue);

      ctrl.handleNativeEvent(const {
        'type': 'pipStateChanged',
        'active': false,
        'supported': true,
      });
      ctrl.handleNativeEvent(const {'type': 'pipRestoreForeground'});
      ctrl.handleNativeEvent(const {
        'type': 'airPlayStateChanged',
        'isAirPlayActive': true,
        'deviceName': '客厅 Apple TV',
      });
      ctrl.handleNativeEvent(const {
        'type': 'thermalStateChanged',
        'thermalState': 'serious',
      });
      await Future<void>.delayed(Duration.zero);

      expect(ctrl.isPipActive, isFalse);
      expect(pipStates, equals(const [false]));
      expect(restoredCount, 1);
      expect(ctrl.isAirPlayActive, isTrue);
      expect(ctrl.airPlayDeviceName, '客厅 Apple TV');
      expect(airPlayStates, equals(const [true]));
      expect(ctrl.thermalState, IosThermalState.serious);
      expect(thermalStates, equals(const [IosThermalState.serious]));
    });

    testWidgets('buildView mounts marco_movie/ios_avplayer_view UiKitView on iOS', (tester) async {
      final ctrl = IosAvPlayerController(
        platformOverride: TargetPlatform.iOS,
        isOhosOverride: false,
        isWebOverride: false,
      );
      addTearDown(ctrl.dispose);

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: ctrl.buildView(key: const Key('avplayer-view')),
        ),
      );
      expect(find.byType(UiKitView), findsOneWidget);
      final uikit = tester.widget<UiKitView>(find.byType(UiKitView));
      expect(uikit.viewType, IosAvPlayerController.viewType);
    });
  });
}
