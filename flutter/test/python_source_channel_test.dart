import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/core/python_source_channel.dart';
import 'package:marco_movie/core/python_http_transport.dart';

class NativeChannelFixture {
  final channel = const MethodChannel('owned.native.python.test');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <String, Completer<Object?>>{};
  final opened = <Map>[];
  Completer<Object?>? closeGate;
  Completer<Object?>? cancelGate;
  int closes = 0;
  String handle(int number) =>
      '${number.toRadixString(16).padLeft(8, '0')}-0000-0000-0000-000000000000';
  NativeChannelFixture() {
    messenger.setMockMethodCallHandler(channel, (call) async {
      final args = call.arguments as Map;
      if (call.method == 'python.open') {
        opened.add(args);
        return {'handle': handle(opened.length)};
      }
      if (call.method == 'python.call') {
        final pending = Completer<Object?>();
        calls[args['callId'] as String] = pending;
        return pending.future;
      }
      if (call.method == 'python.cancel')
        return cancelGate?.future ?? {'cancelled': 'active'};
      if (call.method == 'python.close') {
        closes++;
        return closeGate?.future ?? {'closed': true};
      }
      throw MissingPluginException();
    });
  }
  Future<Object?> callback(String handle, String callId) async {
    final bytes = await messenger.handlePlatformMessage(
      channel.name,
      channel.codec.encodeMethodCall(
        MethodCall('python.http.request', {
          'version': 1,
          'handle': handle,
          'callId': callId,
          'requestId': '9' * 32,
        }),
      ),
      null,
    );
    return channel.codec.decodeEnvelope(bytes!);
  }

  void dispose() {
    channel.setMethodCallHandler(null);
    messenger.setMockMethodCallHandler(channel, null);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'remote package keeps origin headers and rejects embedded credentials',
    () {
      final headers = {'Authorization': 'owned'};
      final remote = PythonRemoteSource(
        Uri.parse('https://source.invalid/api.php?entry=1'),
        headers: headers,
      );
      headers.clear();
      expect(remote.arguments['headers'], {'Authorization': 'owned'});
      expect(
        () => PythonRemoteSource(
          Uri.parse('https://user:password@source.invalid/main.py'),
        ),
        throwsFormatException,
      );
      expect(
        () => PythonRemoteSource(Uri.parse('file:///main.py')),
        throwsFormatException,
      );
      expect(
        () => PythonRemoteSource(
          Uri.parse('https://source.invalid/main.py'),
          headers: {'X-Test': 'bad\nvalue'},
        ),
        throwsFormatException,
      );
    },
  );
  final proxy = Uri.parse(
    'http://127.0.0.1:1234/_spider/${'a' * 43}/proxy?do=py&siteKey=${'a' * 43}',
  );
  NativePythonPackage package() => NativePythonPackage(
    entry: 'main.py',
    files: {'main.py': Uint8List.fromList(utf8.encode('owned'))},
  );
  Matcher errorCode(String code) =>
      isA<PlatformException>().having((e) => e.code, 'code', code);

  test('package preserves bytes and raw extension across mutable callers', () {
    final source = Uint8List.fromList([0, 255, 128]);
    final input = NativePythonPackage(
      entry: 'main.py',
      files: {'main.py': source},
      extension: '  原始配置\n',
    );
    source[0] = 9;
    final first = input.arguments(proxy);
    expect(first['extension'], '  原始配置\n');
    expect((first['files'] as Map)['main.py'], [0, 255, 128]);
    ((first['files'] as Map)['main.py'] as Uint8List)[0] = 7;
    expect((input.arguments(proxy)['files'] as Map)['main.py'], [0, 255, 128]);
  });
  test(
    'package rejects escaped paths and oversized content before native open',
    () {
      for (final name in [
        '../main.py',
        '/main.py',
        'a/../main.py',
        r'a\main.py',
        'a//main.py',
      ]) {
        expect(
          () => NativePythonPackage(entry: name, files: {name: Uint8List(0)}),
          throwsFormatException,
        );
      }
      expect(
        () => NativePythonPackage(
          entry: 'main.py',
          files: {'main.py': Uint8List(2 * 1024 * 1024 + 1)},
        ),
        throwsFormatException,
      );
      expect(
        () => NativePythonPackage(
          entry: 'missing.py',
          files: {'main.py': Uint8List(0)},
        ),
        throwsFormatException,
      );
    },
  );
  test(
    'HTTP callback requires its own handle and active call identity',
    () async {
      final native = NativeChannelFixture();
      addTearDown(native.dispose);
      final bridge = PythonSourceChannel(channel: native.channel);
      int aRequests = 0, bRequests = 0;
      final a = await bridge.open(package(), proxy, (args) async {
        aRequests++;
        expect(args.containsKey('handle'), false);
        return {'owned': 'a'};
      });
      final b = await bridge.open(package(), proxy, (_) async {
        bRequests++;
        return {};
      });
      final id = '1' * 32;
      final work = a.invoke(id, 'home', [false], const Duration(seconds: 2));
      await Future<void>.delayed(Duration.zero);
      expect(await native.callback(native.handle(1), id), {'owned': 'a'});
      await expectLater(
        native.callback(native.handle(2), id),
        throwsA(errorCode('cancelled')),
      );
      await expectLater(
        native.callback(native.handle(1), '2' * 32),
        throwsA(errorCode('cancelled')),
      );
      expect(aRequests, 1);
      expect(bRequests, 0);
      native.calls[id]!.complete({});
      await work;
      await expectLater(
        native.callback(native.handle(1), id),
        throwsA(errorCode('cancelled')),
      );
      await a.close();
      await b.close();
    },
  );
  test(
    'cancel rejects an outstanding HTTP result before native acknowledgement',
    () async {
      final native = NativeChannelFixture()..cancelGate = Completer<Object?>();
      addTearDown(native.dispose);
      final bridge = PythonSourceChannel(channel: native.channel);
      final response = Completer<Map<String, Object?>>();
      final owner = await bridge.open(package(), proxy, (_) => response.future);
      final id = '1' * 32;
      final work = owner.invoke(id, 'home', [], const Duration(seconds: 2));
      await Future<void>.delayed(Duration.zero);
      final callback = native.callback(native.handle(1), id);
      final checked = expectLater(callback, throwsA(errorCode('cancelled')));
      await Future<void>.delayed(Duration.zero);
      final cancel = owner.cancel(id);
      response.complete({'late': true});
      await checked;
      native.cancelGate!.complete({'cancelled': 'active'});
      await cancel;
      native.calls[id]!.complete({});
      await work;
      await owner.close();
    },
  );
  test(
    'close completes only after native destruction and is sent once',
    () async {
      final native = NativeChannelFixture()..closeGate = Completer<Object?>();
      addTearDown(native.dispose);
      final bridge = PythonSourceChannel(channel: native.channel);
      final owner = await bridge.open(package(), proxy, (_) async => {});
      final id = '1' * 32;
      final work = owner.invoke(id, 'home', [], const Duration(seconds: 2));
      await Future<void>.delayed(Duration.zero);
      var closed = false;
      final close = owner.close().then((_) => closed = true);
      final again = owner.close();
      await Future<void>.delayed(Duration.zero);
      expect(closed, false);
      expect(native.closes, 1);
      await expectLater(
        native.callback(native.handle(1), id),
        throwsA(errorCode('cancelled')),
      );
      native.calls[id]!.complete({});
      await work;
      native.closeGate!.complete({'closed': true});
      await close;
      await again;
      expect(closed, true);
      await expectLater(
        owner.invoke('2' * 32, 'home', [], const Duration(seconds: 2)),
        throwsStateError,
      );
    },
  );
  test('source failure is returned without replay in another owner', () async {
    final native = NativeChannelFixture();
    addTearDown(native.dispose);
    final bridge = PythonSourceChannel(channel: native.channel);
    final owner = await bridge.open(package(), proxy, (_) async => {});
    final id = '1' * 32;
    final work = owner.invoke(id, 'home', [], const Duration(seconds: 2));
    final checked = expectLater(work, throwsA(errorCode('python_error')));
    await Future<void>.delayed(Duration.zero);
    native.calls[id]!.completeError(PlatformException(code: 'python_error'));
    await checked;
    expect(native.opened.length, 1);
    expect(native.calls.length, 1);
    await owner.close();
  });
  test('transport failure keeps its typed native error', () async {
    final native = NativeChannelFixture();
    addTearDown(native.dispose);
    final bridge = PythonSourceChannel(channel: native.channel);
    final owner = await bridge.open(
      package(),
      proxy,
      (_) async => throw const PythonTransportException('tls'),
    );
    final id = '1' * 32;
    final work = owner.invoke(id, 'home', [], const Duration(seconds: 2));
    await Future<void>.delayed(Duration.zero);
    await expectLater(
      native.callback(native.handle(1), id),
      throwsA(errorCode('tls')),
    );
    native.calls[id]!.complete({});
    await work;
    await owner.close();
  });
}
