import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'python_source_channel.dart';
import 'python_source_sessions.dart';

Future<void> runCryptoFixture(
  void Function(String, bool) check,
  int Function() beats,
) async {
  const channel = MethodChannel('marco_movie/python_source');
  final bridge = PythonSourceChannel(channel: channel);
  final pool = PythonSourceSessions();
  final owners = <String, PythonNativeSession>{};
  final source = Uint8List.fromList(
    utf8.encode(await rootBundle.loadString('assets/crypto_spider.py')),
  );
  Future<Map> call(String key, String method, List<Object?> args) async {
    final output = await pool.invoke(
      sessionKey: key,
      expectedGeneration: pool.generation,
      method: method,
      arguments: args,
      allowUrl: (_) => false,
      open: (proxy, request) async {
        final owner = await bridge.open(
          NativePythonPackage(
            entry: 'crypto_spider.py',
            files: {'crypto_spider.py': source},
            extension: key,
          ),
          proxy,
          request,
        );
        owners[key] = owner;
        return owner;
      },
    );
    return jsonDecode(output) as Map;
  }

  try {
    final a = await call('crypto-a', 'home', [true]);
    final b = await call('crypto-b', 'home', [true]);
    check(
      'crypto_native_inventory',
      a['version'] == '4.4.0' &&
          (a['modules'] as List).length == 41 &&
          jsonEncode(a['modules']) == jsonEncode(b['modules']),
    );
    check(
      'crypto_known_answers',
      [a, b].every(
        (item) =>
            (item['known'] as Map).length == 8 &&
            (item['known'] as Map).values.every((value) => value == true),
      ),
    );
    check(
      'crypto_owner_modules',
      a['owner'] == 'crypto-a' &&
          b['owner'] == 'crypto-b' &&
          a['previous'] == null &&
          b['previous'] == null,
    );
    final asymmetric = await call('crypto-a', 'detail', [
      ['owned'],
    ]);
    check(
      'crypto_rsa_ecc',
      asymmetric.length == 3 &&
          asymmetric.values.every((value) => value == true),
    );
    final first = await call('crypto-a', 'liveContent', ['stream']);
    final second = await call('crypto-a', 'liveContent', ['stream']);
    final peerFirst = await call('crypto-b', 'liveContent', ['stream']);
    check(
      'crypto_stream_state',
      first['offset'] == 32 &&
          second['offset'] == 64 &&
          peerFirst['offset'] == 32 &&
          first['bytes'] == peerFirst['bytes'] &&
          first['bytes'] != second['bytes'],
    );
    final before = beats();
    final results = await Future.wait([
      call('crypto-a', 'liveContent', ['parallel']),
      call('crypto-b', 'liveContent', ['parallel']),
    ]);
    check(
      'crypto_parallel_owners',
      results[0]['owner'] == 'crypto-a' &&
          results[1]['owner'] == 'crypto-b' &&
          results.every((item) => item['bytes'] == 12582912),
    );
    check('crypto_ui_responsive', beats() > before);
    pool.retainSessions({'crypto-b'});
    await owners['crypto-a']!.close();
    final peerNext = await call('crypto-b', 'liveContent', ['stream']);
    check(
      'crypto_survives_peer_close',
      peerNext['offset'] == 64 && peerNext['bytes'] == second['bytes'],
    );
    final reopened = await call('crypto-c', 'home', [true]);
    check(
      'crypto_reopened_owner',
      reopened['previous'] == null &&
          reopened['owner'] == 'crypto-c' &&
          (reopened['known'] as Map).values.every((value) => value == true),
    );
  } finally {
    await pool.close();
    for (final owner in owners.values) {
      await owner.close();
    }
    channel.setMethodCallHandler(null);
  }
}
