// Real dedicated native threads/interpreters; bundled source package only.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'source_fixture.dart';

Future<void> runNativeOwnerFixture(
  MethodChannel channel,
  void Function(String, bool) check,
  int Function() heartbeat,
) async {
  final fixture = await NativeSourceFixture.start(channel, actors: true);
  final http = HttpClient();
  channel.setMethodCallHandler(fixture.onMethod);
  final before = heartbeat();
  Future<Map> status() async => (await channel.invokeMapMethod<String, Object?>(
    'actorStatus',
    {'version': 1},
  ))!;
  Future<String> outcome(Future<Object?> work) async {
    try {
      await work;
      return 'success';
    } on PlatformException catch (error) {
      return error.code;
    }
  }

  try {
    final a = await fixture.open();
    final b = await fixture.open();
    final homeA = await fixture.call(a, 'home', [true]) as Map;
    final homeB = await fixture.call(b, 'home', [true]) as Map;
    check(
      'owner_shared_source_http',
      homeA['request_method'] == 'GET' && homeB['request_method'] == 'GET',
    );
    final ownerA = fixture.owners[a]!;
    final ownerB = fixture.owners[b]!;
    final states = (await status())['owners'] as Map;
    final aState = states[ownerA.handle] as Map;
    final bState = states[ownerB.handle] as Map;
    check(
      'owner_distinct_threads',
      aState['thread'] != 0 &&
          bState['thread'] != 0 &&
          aState['thread'] != bState['thread'],
    );
    check(
      'owner_distinct_interpreters',
      (aState['interpreter'] as int) > 0 &&
          (bState['interpreter'] as int) > 0 &&
          aState['interpreter'] != bState['interpreter'],
    );
    check(
      'owner_instance_isolation',
      homeA['calls'] == 1 &&
          homeB['calls'] == 1 &&
          homeA['module_instances'] == 1 &&
          homeB['module_instances'] == 1,
    );
    final play =
        await fixture.call(a, 'play', ['owned', 'episode-1', []]) as Map;
    final proxy = Uri.parse(play['url'] as String);
    final get = await http.getUrl(proxy);
    get.headers.set(HttpHeaders.rangeHeader, 'bytes=0-5');
    final response = await get.close();
    final bytes = await response.fold<List<int>>(
      [],
      (all, part) => all..addAll(part),
    );
    check(
      'owner_binary_proxy',
      response.statusCode == 206 &&
          base64Encode(bytes) == 'AP+ADQpB' &&
          response.headers.value('x-instance-calls') == '3',
    );
    final head = await http.openUrl('HEAD', proxy);
    head.headers.set(HttpHeaders.rangeHeader, 'bytes=0-5');
    final headResponse = await head.close();
    final headBytes = await headResponse.fold<List<int>>(
      [],
      (all, part) => all..addAll(part),
    );
    check(
      'owner_proxy_head',
      headResponse.statusCode == 206 &&
          headBytes.isEmpty &&
          headResponse.contentLength == 6,
    );

    final stop = Completer<void>();
    bool blockSettled = false;
    final blocked = fixture
        .call(a, 'liveContent', ['native-block'], cancellation: stop)
        .then(
          (_) {
            blockSettled = true;
            return false;
          },
          onError: (Object error) {
            blockSettled = true;
            return error is StateError;
          },
        );
    await fixture.blockEntered.future.timeout(const Duration(seconds: 5));
    final other = await fixture.call(b, 'home', [false]) as Map;
    check(
      'owner_other_runs_during_c_block',
      other['calls'] == 2 && !blockSettled,
    );
    Future<String> queued(String id) => outcome(
      channel.invokeMethod<Object?>('callActor', {
        'version': 1,
        'handle': ownerA.handle,
        'method': 'homeVod',
        'args': [],
        'callId': id,
        'budgetMs': 12000,
      }),
    );
    final first = queued('1' * 32);
    final middle = queued('2' * 32);
    final last = queued('3' * 32);
    final full = await status();
    check(
      'owner_queue_bounded',
      full['owners'][ownerA.handle]['pending'] == 4 &&
          await queued('4' * 32) == 'runtime_limit',
    );
    final removed = await channel.invokeMapMethod<String, Object?>(
      'cancelActor',
      {'version': 1, 'handle': ownerA.handle, 'callId': '2' * 32},
    );
    check(
      'owner_queued_cancel',
      removed?['cancelled'] == 'queued' && await middle == 'cancelled',
    );
    final afterQueueCancel = await status();
    check(
      'owner_queued_cancel_preserves_active',
      !blockSettled &&
          afterQueueCancel['owners'][ownerA.handle]['pending'] == 3 &&
          afterQueueCancel['owners'][ownerA.handle]['state'] == 'running',
    );

    stop.complete();
    check(
      'owner_active_cancel_returns',
      await blocked.timeout(const Duration(seconds: 2)),
    );
    final revoked = await http.getUrl(proxy);
    final revokedResponse = await revoked.close();
    await revokedResponse.drain<void>();
    check(
      'owner_proxy_revoked_before_close',
      revokedResponse.statusCode == 404 && !ownerA.closed.isCompleted,
    );
    final closing = await status();
    check(
      'owner_cancel_not_termination',
      closing['allocated'] == 2 &&
          closing['owners'][ownerA.handle]['state'] == 'closing' &&
          closing['owners'][ownerA.handle]['finished'] == false,
    );
    final proxyQuery = Map<String, String>.from(proxy.queryParameters)
      ..remove('item');
    check(
      'owner_closing_capacity_retained',
      await outcome(
            channel.invokeMethod<Object?>('openActor', {
              'version': 1,
              'source': 'native-source-v1',
              'origin': '${fixture.origin}',
              'proxy': '${proxy.replace(queryParameters: proxyQuery)}',
            }),
          ) ==
          'runtime_limit',
    );
    final duringClose = await fixture.call(b, 'home', [false]) as Map;
    check(
      'owner_other_runs_during_close',
      duringClose['calls'] == 3 && !ownerA.closed.isCompleted,
    );
    check(
      'owner_close_drains_queue',
      await first == 'cancelled' && await last == 'cancelled',
    );
    await ownerA.closed.future.timeout(const Duration(seconds: 8));
    check(
      'owner_real_destruction',
      (await status())['allocated'] == 1 &&
          ownerA.cancellations == 1 &&
          fixture.pending.isEmpty,
    );
    check('owner_stale_handle', await queued('5' * 32) == 'invalid_handle');
    final fresh = await fixture.open();
    final freshHome = await fixture.call(fresh, 'home', [false]) as Map;
    check(
      'owner_capacity_reused',
      freshHome['calls'] == 1 &&
          freshHome['initializations'] == 1 &&
          freshHome['module_instances'] == 1 &&
          fixture.owners[fresh]!.handle != ownerA.handle,
    );
    check(
      'owner_other_survives_destruction',
      (await fixture.call(b, 'home', [false]) as Map)['calls'] == 4,
    );
    check('owner_ui_responsive', heartbeat() - before >= 2);
    check(
      'owner_transport_clean',
      fixture.pending.isEmpty && fixture.failures.isEmpty,
    );
  } finally {
    await fixture.close();
    channel.setMethodCallHandler(null);
    http.close(force: true);
  }
}
