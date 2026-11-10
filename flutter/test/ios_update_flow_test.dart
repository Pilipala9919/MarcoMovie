import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:share_plus/share_plus.dart';
import 'package:marco_movie/core/app_update.dart';
import 'package:marco_movie/ui/ios_update_sheet.dart';
import 'package:marco_movie/ui/apple_theme.dart';

final bytes = utf8.encode('verified IPA fixture');
AppUpdate release([String version = '0.5.18']) => AppUpdate(
    version,
    'Update notes',
    null,
    sha256.convert(bytes).toString(),
    bytes.length,
    Uri.parse(
        'https://github.com/Pilipala9919/MarcoMovie/releases/download/ios-v$version/MarcoMovie-$version-ios-unsigned.ipa'));

class StreamClient extends http.BaseClient {
  final Future<http.StreamedResponse> Function(http.BaseRequest) response;
  StreamClient(this.response);
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      response(request);
}

void main() {
  test(
      'TrollStore local URL preserves spaces and Unicode without a remote download',
      () {
    final file =
        File('${Directory.systemTemp.path}/Marco Movie/更新包 0.5.18.ipa');
    final uri = AppUpdate.trollStoreFileUrl(file);
    expect(uri.scheme, 'apple-magnifier');
    expect(uri.host, 'install');
    expect(uri.queryParameters['url'], file.absolute.uri.toString());
    expect(Uri.parse(uri.queryParameters['url']!).scheme, 'file');
  });
  test('both stalled metadata endpoints end and each request is aborted',
      () async {
    final aborted = <Future<void>>[];
    final client = StreamClient((request) {
      aborted.add((request as http.AbortableRequest).abortTrigger!);
      return Completer<http.StreamedResponse>().future;
    });
    final stages = <String>[];
    await expectLater(
        AppUpdate.check(
            client: client,
            platform: 'ios',
            endpointTimeout: const Duration(milliseconds: 15),
            onStage: stages.add),
        throwsA(isA<HttpException>()));
    expect(stages, hasLength(2));
    await Future.wait(aborted).timeout(const Duration(seconds: 1));
  });

  test(
      'metadata body stall falls back and cancellation never starts another endpoint',
      () async {
    final body = StreamController<List<int>>();
    var calls = 0;
    final client = StreamClient((request) async {
      calls++;
      if (calls == 1) return http.StreamedResponse(body.stream, 200);
      return http.StreamedResponse(
          Stream.value(utf8.encode(jsonEncode([
            {
              'tag_name': 'ios-v0.5.18',
              'assets': [
                {
                  'name': 'MarcoMovie-0.5.18-ios-unsigned.ipa',
                  'size': bytes.length,
                  'digest': 'sha256:${sha256.convert(bytes)}',
                  'browser_download_url': release().iosUrl.toString(),
                }
              ],
            }
          ]))),
          200);
    });
    final update = await AppUpdate.check(
        client: client,
        platform: 'ios',
        endpointTimeout: const Duration(milliseconds: 20));
    expect(update.version, '0.5.18');
    await body.close();
    final cancel = UpdateCancellation();
    var requests = 0;
    final work = AppUpdate.check(
        client: StreamClient((_) {
          requests++;
          return Completer<http.StreamedResponse>().future;
        }),
        platform: 'ios',
        cancellation: cancel);
    final assertion = expectLater(work, throwsA(isA<UpdateCancelled>()));
    cancel.cancel();
    await assertion;
    expect(requests, 1);
  });

  test('only the published URL is fetched; verified file can be reused offline',
      () async {
    final dir = await Directory.systemTemp.createTemp('marco-ios-update-test-');
    addTearDown(() => dir.delete(recursive: true));
    var calls = 0;
    final client = MockClient((request) async {
      calls++;
      expect(request.url, release().iosUrl);
      return http.Response.bytes(bytes, 200);
    });
    final file = await release().downloadIos(
        directory: dir, cancellation: UpdateCancellation(), client: client);
    expect(await file.readAsBytes(), bytes);
    expect((await dir.list().toList()).length, 1);
    await release().downloadIos(
        directory: dir, cancellation: UpdateCancellation(), client: client);
    expect(calls, 1);
  });

  for (final kind in ['truncated', 'corrupt', 'oversized', 'length', 'http']) {
    test('$kind package is never exposed and staging files are removed',
        () async {
      final dir =
          await Directory.systemTemp.createTemp('marco-ios-update-test-');
      addTearDown(() => dir.delete(recursive: true));
      final content = switch (kind) {
        'truncated' => bytes.sublist(0, 3),
        'oversized' => [...bytes, 1],
        _ => List<int>.filled(bytes.length, 0),
      };
      final client = StreamClient((_) async => http.StreamedResponse(
          Stream.value(content), kind == 'http' ? 503 : 200,
          contentLength: kind == 'length' ? 1 : null));
      await expectLater(
          release().downloadIos(
              directory: dir,
              cancellation: UpdateCancellation(),
              client: client),
          throwsException);
      expect(await dir.list().toList(), isEmpty);
    });
  }

  for (final kind in ['headers', 'stalled', 'deadline', 'cancel']) {
    test('$kind download ends, aborts request and cleans partial files',
        () async {
      final dir =
          await Directory.systemTemp.createTemp('marco-ios-update-test-');
      addTearDown(() => dir.delete(recursive: true));
      final body = StreamController<List<int>>();
      final started = Completer<void>();
      Future<void>? aborted;
      final client = StreamClient((request) async {
        aborted = (request as http.AbortableRequest).abortTrigger;
        started.complete();
        if (kind == 'headers') return Completer<http.StreamedResponse>().future;
        return http.StreamedResponse(body.stream, 200);
      });
      final cancel = UpdateCancellation();
      final result = release().downloadIos(
          directory: dir,
          cancellation: cancel,
          client: client,
          connectionTimeout: const Duration(milliseconds: 20),
          stallTimeout: Duration(milliseconds: kind == 'stalled' ? 20 : 500),
          totalTimeout: Duration(milliseconds: kind == 'deadline' ? 25 : 1000));
      final assertion = expectLater(result, throwsException);
      await started.future;
      if (kind == 'cancel') cancel.cancel();
      await assertion;
      await aborted;
      // Mock transports need explicit closure; production IOClient aborts it.
      unawaited(body.close());
      expect(await dir.list().toList(), isEmpty);
    });
  }

  Future<void> mount(WidgetTester tester, IosUpdateSheet sheet) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: sheet)));
    await tester.pump();
  }

  testWidgets(
      'blocked package-info never blocks remote check or leaves spinner',
      (tester) async {
    await mount(
        tester,
        IosUpdateSheet(
            readVersion: () => Completer<String>().future,
            check: (_, __) async => release()));
    expect(find.text('可用版本 0.5.18'), findsOneWidget);
    expect(find.byKey(const ValueKey('ios-update-progress')), findsNothing);
    await tester.pump(const Duration(seconds: 4));
    expect(find.text('当前版本暂无法读取'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('hung check times out; retry ignores old completion',
      (tester) async {
    final first = Completer<AppUpdate>();
    var calls = 0;
    await mount(
        tester,
        IosUpdateSheet(
            readVersion: () async => '0.5.17',
            check: (_, __) {
              return ++calls == 1 ? first.future : Future.value(release());
            }));
    expect(find.text('打开下载站').hitTestable(), findsOneWidget);
    await tester.pump(const Duration(seconds: 19));
    await tester.pump();
    expect(find.textContaining('检查更新超时'), findsOneWidget);
    expect(find.byKey(const ValueKey('ios-update-progress')), findsNothing);
    await tester.tap(find.text('重新检查'));
    await tester.pump();
    first.complete(release('9.9.9'));
    await tester.pump();
    expect(find.text('发现新版本 0.5.18'), findsOneWidget);
    expect(find.textContaining('9.9.9'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'dismissal cancels request and late response cannot update next sheet',
      (tester) async {
    final first = Completer<AppUpdate>();
    late UpdateCancellation operation;
    await mount(
        tester,
        IosUpdateSheet(
            readVersion: () async => '0.5.17',
            check: (op, _) {
              operation = op;
              return first.future;
            }));
    await tester.pumpWidget(const SizedBox());
    expect(operation.isCancelled, isTrue);
    first.complete(release());
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'glass mode changes keep a pending check and its completion attached',
      (tester) async {
    final pending = Completer<AppUpdate>();
    var calls = 0;
    late UpdateCancellation operation;
    GlassworkBackdrop.reduceTransparency.value = false;
    GlassworkBackdrop.intensity.value = .68;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: GlassworkBackdrop(
      radius: 28,
      child: IosUpdateSheet(
          readVersion: () async => '0.5.17',
          check: (op, _) {
            calls++;
            operation = op;
            return pending.future;
          }),
    ))));
    await tester.pump();
    for (final solid in [true, false, true, false]) {
      GlassworkBackdrop.reduceTransparency.value = solid;
      await tester.pump();
      expect(operation.isCancelled, isFalse);
    }
    expect(calls, 1);
    pending.complete(release());
    await tester.pump();
    expect(find.text('发现新版本 0.5.18'), findsOneWidget);
    expect(find.byKey(const ValueKey('ios-update-progress')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  for (final troll in [true, false]) {
    testWidgets(
        '${troll ? 'TrollStore' : 'self-sign'} downloads then shares local IPA; cancelled share can reopen',
        (tester) async {
      tester.view.physicalSize = const Size(1024, 768);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final completed = Completer<File>();
      var downloads = 0, shares = 0;
      final saved = File('${Directory.systemTemp.path}/verified-0.5.18.ipa');
      await mount(
          tester,
          IosUpdateSheet(
            readVersion: () async => '0.5.17',
            check: (_, __) async => release(),
            openTrollStore: (_) async => false,
            download: (_, __, progress) {
              downloads++;
              progress(1, 2);
              return completed.future;
            },
            shareFile: (file, origin) async {
              shares++;
              expect(file.path, saved.path);
              expect(origin.width, greaterThan(0));
              expect(
                  (Offset.zero & const Size(1024, 768)).contains(origin.center),
                  isTrue);
              return const ShareResult('', ShareResultStatus.dismissed);
            },
          ));
      await tester.tap(find.text(troll ? '下载并用巨魔更新' : '下载并自签更新'));
      await tester.pump();
      expect(downloads, 1);
      expect(shares, 0);
      completed.complete(saved);
      await tester.pump();
      await tester.pump();
      expect(shares, 1);
      expect(find.textContaining('已取消分享'), findsOneWidget);
      await tester.tap(find.text(troll ? '用巨魔更新' : '用其他应用打开'));
      await tester.pump();
      expect(shares, 2);
      expect(downloads, 1);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets(
      'TrollStore directly opens the verified local IPA after downloading',
      (tester) async {
    final completed = Completer<File>();
    final file = File('${Directory.systemTemp.path}/verified.ipa');
    var launches = 0, shares = 0;
    await mount(
        tester,
        IosUpdateSheet(
          readVersion: () async => '0.5.17',
          check: (_, __) async => release(),
          download: (_, __, ___) => completed.future,
          openTrollStore: (uri) async {
            launches++;
            expect(uri.queryParameters['url'], file.absolute.uri.toString());
            return true;
          },
          shareFile: (_, __) async {
            shares++;
            return const ShareResult('', ShareResultStatus.success);
          },
        ));
    await tester.tap(find.text('下载并用巨魔更新'));
    await tester.pump();
    expect(launches, 0);
    completed.complete(file);
    await tester.pump();
    await tester.pump();
    expect(launches, 1);
    expect(shares, 0);
    expect(find.textContaining('已请求巨魔打开本地 IPA'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  for (final troll in [true, false]) {
    testWidgets(
        'failed integrity check cannot ${troll ? 'open TrollStore' : 'open the share sheet'}',
        (tester) async {
      var shares = 0;
      await mount(
          tester,
          IosUpdateSheet(
            readVersion: () async => '0.5.17',
            check: (_, __) async => release(),
            openTrollStore: (_) async {
              shares++;
              return true;
            },
            download: (_, __, ___) async =>
                throw const FormatException('bad digest'),
            shareFile: (_, __) async {
              shares++;
              return const ShareResult('', ShareResultStatus.success);
            },
          ));
      await tester.tap(find.text(troll ? '下载并用巨魔更新' : '下载并自签更新'));
      await tester.pump();
      expect(shares, 0);
      expect(find.textContaining('安装包校验失败'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
