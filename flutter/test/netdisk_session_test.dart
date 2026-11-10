import 'dart:convert';
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:marco_movie/core/netdisk_service.dart';
import 'package:marco_movie/core/netdisk_session.dart';
import 'package:marco_movie/core/storage_service.dart';

NetdiskQrSession qr(String provider) => NetdiskQrSession(
    driveKey: provider, token: 'qr-ticket', qrContentUrl: '', qrImageUrl: '');
http.Response response(Object value) => http.Response(jsonEncode(value), 200);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('UC exchanges CAS ticket for account cookie; never stores QR codes',
      () async {
    final paths = <String>[];
    final client = MockClient((request) async {
      paths.add(request.url.path);
      if (request.url.host == 'api.open.uc.cn') {
        return response({
          'status': 2000000,
          'data': {
            'members': {'service_ticket': 'cas-value'}
          }
        });
      }
      expect(request.url.host, 'drive.uc.cn');
      expect(request.url.path, '/account/mobileinfo');
      expect(request.url.queryParameters['st'], 'cas-value');
      expect(request.followRedirects, isFalse);
      return response({
        'data': {'__pus': 'account-cookie', 'serviceTicket': 'drive-st'}
      });
    });
    final result =
        await NetdiskService(httpClient: client).pollQrSession(qr('uc'));
    expect(result.state, NetdiskPollState.confirmed);
    expect(result.credential, '__pus=account-cookie');
    expect(paths.length, 2);
  });
  test('failed UC exchange remains error and retries the cached ticket',
      () async {
    var polls = 0;
    var exchanges = 0;
    final client = MockClient((request) async {
      if (request.url.host == 'api.open.uc.cn') {
        polls++;
        return response({
          'status': 2000000,
          'data': {
            'members': {'service_ticket': 'cas-value'}
          }
        });
      }
      exchanges++;
      return response(exchanges == 1
          ? {'data': {}}
          : {
              'data': {'__pus': 'valid-cookie'}
            });
    });
    final service = NetdiskService(httpClient: client);
    final first = await service.pollQrSession(qr('uc'));
    expect(first.state, NetdiskPollState.error);
    expect(first.credential, isEmpty);
    expect((await service.pollQrSession(qr('uc'))).credential,
        '__pus=valid-cookie');
    expect(polls, 1);
    expect(exchanges, 2);
  });
  test('Baidu QR v is exchanged for real BDUSS and STOKEN', () async {
    final client = MockClient((request) async {
      if (request.url.path == '/channel/unicast') {
        return response({
          'errno': 0,
          'channel_v': jsonEncode({'status': 0, 'v': 'one-use-ticket'})
        });
      }
      expect(request.url.host, 'passport.baidu.com');
      expect(request.url.path, '/v3/login/main/qrbdusslogin');
      expect(request.url.queryParameters['bduss'], 'one-use-ticket');
      expect(request.followRedirects, isFalse);
      return http.Response(
          'bd__cbs__4wi6y6(${jsonEncode({
                'data': {
                  'session': jsonEncode(
                      {'bduss': 'account-bduss', 'stoken': 'account-stoken'})
                }
              })});',
          200);
    });
    final result =
        await NetdiskService(httpClient: client).pollQrSession(qr('baidu'));
    expect(result.state, NetdiskPollState.confirmed);
    expect(result.credential, 'BDUSS=account-bduss; STOKEN=account-stoken');
    expect(result.credential, isNot(contains('one-use-ticket')));
  });
  test('missing Baidu session and redirect never create a login', () async {
    for (final status in [200, 302]) {
      final client = MockClient((request) async =>
          request.url.path == '/channel/unicast'
              ? response({
                  'errno': 0,
                  'channel_v': {'status': 0, 'v': 'one-use-ticket'}
                })
              : http.Response('{}', status,
                  headers: {'location': 'https://other.example/'}));
      final result =
          await NetdiskService(httpClient: client).pollQrSession(qr('baidu'));
      expect(result.state, NetdiskPollState.error);
      expect(result.credential, isEmpty);
    }
  });
  test('Baidu keeps one QR browser session and persists real header cookies',
      () async {
    // Synthetic passport responses, never a real account or scan.
    String? gid;
    var polls = 0;
    var exchanges = 0;
    final client = MockClient((request) async {
      expect(request.url.host, 'passport.baidu.com');
      expect(request.followRedirects, isFalse);
      expect(request.headers['User-Agent'], NetdiskSession.baiduUserAgent);
      expect(request.headers['Referer'], 'https://pan.baidu.com/');
      if (request.url.path == '/v2/api/getqrcode') {
        gid = request.url.queryParameters['gid'];
        expect(gid, matches(r'^[0-9A-F-]{36}$'));
        expect(request.headers['Cookie'], isNull);
        return http.Response(
            'tangram_guid_123({"sign":"synthetic-sign"});', 200,
            headers: {
              'date': 'Tue, 10 Nov 2026 01:00:00 GMT',
              'set-cookie':
                  'BAIDUID=synthetic-browser; Domain=.baidu.com; Path=/'
            });
      }
      expect(request.headers['Cookie'], contains('BAIDUID=synthetic-browser'));
      if (request.url.path == '/channel/unicast') {
        expect(request.url.queryParameters['gid'], gid);
        expect(request.url.queryParameters['_sdkFrom'], '1');
        polls++;
        if (polls == 1) {
          return response({
            'errno': '0',
            'channel_v': {'status': '1'}
          });
        }
        if (polls == 2) return response({'errno': 1});
        return response({
          'errno': 0,
          'channel_v': jsonEncode({'status': 0, 'v': 'temporary-scan-ticket'})
        });
      }
      exchanges++;
      expect(request.url.path, '/v3/login/main/qrbdusslogin');
      expect(request.url.queryParameters['bduss'], 'temporary-scan-ticket');
      return http.Response(
          jsonEncode({
            'data': {
              'session': {'bduss': 'body-alternative', 'stoken': 'body-token'}
            }
          }),
          200,
          headers: {
            'set-cookie':
                'BDUSS=header-account; Domain=.baidu.com; Path=/; HttpOnly, '
                    'STOKEN=header-token; Domain=.baidu.com; Path=/; Secure, '
                    'PTOKEN=header-ptoken; Domain=.baidu.com; Path=/'
          });
    });
    final service = NetdiskService(httpClient: client);
    final session = await service.startQrSession('baidu');
    expect(Uri.parse(session.qrContentUrl).queryParameters['t'], '1794272400');
    expect(session.extra, {'gid': gid});
    expect(
        (await service.pollQrSession(session)).state, NetdiskPollState.scanned);
    expect(
        (await service.pollQrSession(session)).state, NetdiskPollState.scanned,
        reason:
            'An unchanged long poll must preserve the already-scanned state');
    final result = await service.pollQrSession(session);
    expect(result.state, NetdiskPollState.confirmed);
    expect(result.credential,
        'BDUSS=header-account; STOKEN=header-token; PTOKEN=header-ptoken');
    expect(result.credential, isNot(contains('temporary-scan-ticket')));
    expect(result.credential, isNot(contains('BAIDUID')));
    expect(
        (await service.pollQrSession(session)).credential, result.credential);
    expect(polls, 3);
    expect(exchanges, 1);
    SharedPreferences.setMockInitialValues({});
    final storage = await StorageService.init();
    await storage.setNetdiskCredential('baidu', result.credential);
    final reopened = await StorageService.init();
    expect(reopened.netdiskCredential('baidu'), result.credential);
    expect(reopened.isNetdiskLoggedIn('baidu'), isTrue);
    expect(NetdiskService.statusLabel(reopened, 'baidu'), '已登录+启用中');
    service.close();
  });
  test('Baidu cookies respect Expires commas, domains, paths and deletion', () {
    final jar = BaiduLoginCookies();
    final exchange =
        Uri.https('passport.baidu.com', '/v3/login/main/qrbdusslogin');
    final poll = Uri.https('passport.baidu.com', '/channel/unicast');
    jar.receive(
        http.Response('', 200, headers: {
          'set-cookie': 'BAIDUID=browser; Domain=.baidu.com; Path=/; '
              'Expires=Thu, 01 Jan 2099 00:00:00 GMT, '
              'STOKEN=drive-stoken; Domain=.baidu.com; Path=/, '
              'BDUSS=passport-only; Path=/, '
              'PTOKEN=foreign; Domain=notbaidu.com; Path=/, '
              'FLOW=endpoint-only; Domain=.baidu.com; Path=/v3/login/main, '
              'OLD=expired; Domain=.baidu.com; Path=/; Expires=Sat, 01 Jan 2000 00:00:00 GMT'
        }),
        exchange);
    expect(jar.accountCookies, {'STOKEN': 'drive-stoken'});
    expect(jar.headerFor(exchange), contains('FLOW=endpoint-only'));
    expect(jar.headerFor(poll), contains('BAIDUID=browser'));
    expect(jar.headerFor(poll), isNot(contains('FLOW=')));
    expect(jar.headerFor(poll), isNot(contains('PTOKEN=')));
    expect(jar.headerFor(poll), isNot(contains('OLD=')));
    expect(jar.headerFor(Uri.https('pan.baidu.com', '/')), isEmpty);
    expect(
        jar.headerFor(Uri.https('passport.baidu.com.evil.test', '/')), isEmpty);
    jar.receive(
        http.Response('', 200, headers: {
          'set-cookie':
              'BAIDUID=deleted; Domain=.baidu.com; Path=/; Max-Age=0; '
                  'Expires=Thu, 01 Jan 2099 00:00:00 GMT'
        }),
        exchange);
    expect(jar.headerFor(poll), isNot(contains('BAIDUID=')));
    expect(
        () => jar.receive(
            http.Response('', 200), Uri.https('other.example', '/')),
        throwsFormatException);
  });
  test('Baidu JSON session may fill missing cookie but never replace header',
      () async {
    final client = MockClient((_) async => http.Response(
            jsonEncode({
              'data': {
                'session': jsonEncode(
                    {'bduss': 'body-account', 'stoken': 'body-stoken'})
              }
            }),
            200,
            headers: {
              'set-cookie': 'BDUSS=header-account; Domain=.baidu.com; Path=/'
            }));
    expect(await NetdiskSession.exchangeBaidu(client, 'qr-temporary'),
        'BDUSS=header-account; STOKEN=body-stoken');
  });
  test('Baidu partial login retries the same approval and retains its cookies',
      () async {
    var polls = 0;
    var exchanges = 0;
    final client = MockClient((request) async {
      if (request.url.path == '/channel/unicast') {
        polls++;
        return response({
          'errno': 0,
          'channel_v': {'status': 0, 'v': 'approval'}
        });
      }
      exchanges++;
      if (exchanges == 1) {
        return http.Response('{}', 200, headers: {
          'set-cookie': 'BDUSS=real-account; Domain=.baidu.com; Path=/'
        });
      }
      expect(request.headers['Cookie'], contains('BDUSS=real-account'));
      return http.Response('{}', 200, headers: {
        'set-cookie': 'STOKEN=real-token; Domain=.baidu.com; Path=/'
      });
    });
    final service = NetdiskService(httpClient: client);
    final first = await service.pollQrSession(qr('baidu'));
    expect(first.state, NetdiskPollState.error);
    expect(first.message, contains('已确认百度授权'));
    expect(first.credential, isEmpty);
    expect((await service.pollQrSession(qr('baidu'))).credential,
        'BDUSS=real-account; STOKEN=real-token');
    expect(polls, 1);
    expect(exchanges, 2);
  });
  test('Baidu exchange must not promote a QR ticket to an account cookie',
      () async {
    for (final fromHeader in [false, true]) {
      final client = MockClient((_) async => http.Response(
          jsonEncode({
            'data': {
              'session': {'bduss': 'temporary', 'stoken': 'session-token'}
            }
          }),
          200,
          headers: fromHeader
              ? {
                  'set-cookie': 'BDUSS=temporary; Domain=.baidu.com; Path=/, '
                      'STOKEN=session-token; Domain=.baidu.com; Path=/'
                }
              : {}));
      await expectLater(NetdiskSession.exchangeBaidu(client, 'temporary'),
          throwsFormatException);
    }
  });
  test('Baidu explicit cookie deletion cannot fall back to a stale JSON value',
      () async {
    final client = MockClient((_) async => http.Response(
            jsonEncode({
              'data': {
                'session': {'bduss': 'body-account', 'stoken': 'stale-token'}
              }
            }),
            200,
            headers: {
              'set-cookie': 'BDUSS=header-account; Domain=.baidu.com; Path=/, '
                  'STOKEN=deleted; Domain=.baidu.com; Path=/; Max-Age=0'
            }));
    await expectLater(NetdiskSession.exchangeBaidu(client, 'temporary'),
        throwsFormatException);
  });
  test(
      'Baidu long poll network timeouts preserve progress and remain retryable',
      () async {
    var calls = 0;
    final service = NetdiskService(httpClient: MockClient((request) async {
      calls++;
      if (calls == 1 || calls == 3 || calls == 5) {
        throw TimeoutException('synthetic timeout');
      }
      if (calls == 2) {
        return response({
          'errno': 0,
          'channel_v': {'status': 1}
        });
      }
      if (calls == 4) {
        return response({
          'errno': 0,
          'channel_v': {'status': 0, 'v': 'approval'}
        });
      }
      expect(request.url.path, '/v3/login/main/qrbdusslogin');
      return response({
        'data': {
          'session': {'bduss': 'account', 'stoken': 'token'}
        }
      });
    }));
    final session = qr('baidu');
    expect(
        (await service.pollQrSession(session)).state, NetdiskPollState.waiting);
    expect(
        (await service.pollQrSession(session)).state, NetdiskPollState.scanned);
    expect(
        (await service.pollQrSession(session)).state, NetdiskPollState.scanned);
    final approved = await service.pollQrSession(session);
    expect(approved.state, NetdiskPollState.scanned);
    expect(approved.message, contains('已确认百度授权'));
    expect((await service.pollQrSession(session)).state,
        NetdiskPollState.confirmed);
  });
  test('Baidu explicit expiry and malformed status never mean pending success',
      () async {
    for (final entry in <Object, NetdiskPollState>{
      {
        'errno': 0,
        'channel_v': {'status': 2}
      }: NetdiskPollState.expired,
      {
        'errno': 0,
        'channel_v': {
          'status': 0,
          'v': {'ticket': 'wrong-type'}
        }
      }: NetdiskPollState.error,
      {'errno': 42}: NetdiskPollState.error,
      {
        'errno': 0,
        'channel_v': {'status': true}
      }: NetdiskPollState.error,
    }.entries) {
      final service = NetdiskService(
          httpClient: MockClient((_) async => response(entry.key)));
      final result = await service.pollQrSession(qr('baidu'));
      expect(result.state, entry.value);
      expect(result.credential, isEmpty);
    }
  });
  test('Baidu long poll can wait beyond the old six-second timeout', () async {
    final service = NetdiskService(httpClient: MockClient((request) async {
      if (request.url.path == '/channel/unicast') {
        await Future<void>.delayed(const Duration(seconds: 7));
        return response({
          'errno': 0,
          'channel_v': {'status': 0, 'v': 'approval'}
        });
      }
      return response({
        'data': {
          'session': {'bduss': 'account', 'stoken': 'token'}
        }
      });
    }));
    expect((await service.pollQrSession(qr('baidu'))).state,
        NetdiskPollState.confirmed);
  });
  test('Baidu replacement QR starts with no cookies from the earlier account',
      () async {
    var generation = 0;
    final service = NetdiskService(httpClient: MockClient((request) async {
      if (request.url.path == '/v2/api/getqrcode') {
        generation++;
        expect(request.headers['Cookie'], isNull);
        return http.Response(
            jsonEncode({'sign': 'qr-$generation'}), 200, headers: {
          'set-cookie': 'BAIDUID=browser-$generation; Domain=.baidu.com; Path=/'
        });
      }
      expect(request.headers['Cookie'], 'BAIDUID=browser-2');
      return response({'errno': 1});
    }));
    await service.startQrSession('baidu');
    final newer = await service.startQrSession('baidu');
    expect(
        (await service.pollQrSession(newer)).state, NetdiskPollState.waiting);
  });
  test(
      'Baidu create failure is an error, never a homepage disguised as QR login',
      () async {
    final service =
        NetdiskService(httpClient: MockClient((_) async => response({})));
    await expectLater(service.startQrSession('baidu'), throwsFormatException);
  });
  test('Baidu out-of-order QR creation cannot replace the newer cookie jar',
      () async {
    final started = [Completer<void>(), Completer<void>()];
    final replies = [Completer<http.Response>(), Completer<http.Response>()];
    var generations = 0;
    final service = NetdiskService(httpClient: MockClient((request) async {
      if (request.url.path == '/v2/api/getqrcode') {
        final index = generations++;
        started[index].complete();
        return replies[index].future;
      }
      expect(request.url.queryParameters['channel_id'], 'newer-qr');
      expect(request.headers['Cookie'], 'BAIDUID=newer-browser');
      return response({'errno': 1});
    }));
    final earlier = service.startQrSession('baidu');
    final earlierRejected = expectLater(earlier, throwsFormatException);
    await started[0].future;
    final newer = service.startQrSession('baidu');
    await started[1].future;
    replies[1].complete(http.Response('{"sign":"newer-qr"}', 200, headers: {
      'set-cookie': 'BAIDUID=newer-browser; Domain=.baidu.com; Path=/'
    }));
    final activeQr = await newer;
    replies[0].complete(http.Response('{"sign":"older-qr"}', 200, headers: {
      'set-cookie': 'BAIDUID=older-browser; Domain=.baidu.com; Path=/'
    }));
    await earlierRejected;
    expect((await service.pollQrSession(activeQr)).state,
        NetdiskPollState.waiting);
  });
  test('Baidu closing invalidates pending QR creation and prevents later polls',
      () async {
    final started = Completer<void>();
    final reply = Completer<http.Response>();
    var requests = 0;
    final service = NetdiskService(httpClient: MockClient((_) async {
      requests++;
      started.complete();
      return reply.future;
    }));
    final pending = service.startQrSession('baidu');
    final rejected = expectLater(pending, throwsFormatException);
    await started.future;
    service.close();
    reply.complete(http.Response('{"sign":"late-qr"}', 200, headers: {
      'set-cookie': 'BAIDUID=late-browser; Domain=.baidu.com; Path=/'
    }));
    await rejected;
    expect((await service.pollQrSession(qr('baidu'))).state,
        NetdiskPollState.error);
    await expectLater(service.startQrSession('baidu'), throwsFormatException);
    expect(requests, 1);
  });
  for (final delayBody in [false, true]) {
    test(
        'Baidu timed-out ${delayBody ? 'body' : 'send'} cannot overwrite retry cookies',
        () async {
      final lateResponse = Completer<http.StreamedResponse>();
      final lateBody = StreamController<List<int>>();
      var calls = 0;
      final jar = BaiduLoginCookies();
      final uri =
          Uri.https('passport.baidu.com', '/v3/login/main/qrbdusslogin');
      final oldHeaders = {
        'set-cookie': 'BDUSS=old-account; Domain=.baidu.com; Path=/, '
            'STOKEN=deleted; Domain=.baidu.com; Path=/; Max-Age=0'
      };
      final client = MockClient.streaming((request, _) async {
        calls++;
        if (calls == 1) {
          return delayBody
              ? http.StreamedResponse(lateBody.stream, 200, headers: oldHeaders)
              : await lateResponse.future;
        }
        return http.StreamedResponse(Stream.value(utf8.encode('{}')), 200,
            headers: {
              'set-cookie': 'BDUSS=new-account; Domain=.baidu.com; Path=/, '
                  'STOKEN=new-token; Domain=.baidu.com; Path=/'
            });
      });
      await expectLater(
          NetdiskSession.baiduRequest(client, uri, jar,
              timeout: const Duration(milliseconds: 20)),
          throwsA(isA<TimeoutException>()));
      await NetdiskSession.baiduRequest(client, uri, jar);
      expect(
          jar.accountCookies, {'BDUSS': 'new-account', 'STOKEN': 'new-token'});
      if (delayBody) {
        lateBody.add(utf8.encode('{}'));
        await lateBody.close();
      } else {
        lateResponse.complete(http.StreamedResponse(
            Stream.value(utf8.encode('{}')), 200,
            headers: oldHeaders));
      }
      // Flush the old request's completion after the newer response was applied.
      await Future<void>.delayed(Duration.zero);
      expect(
          jar.accountCookies, {'BDUSS': 'new-account', 'STOKEN': 'new-token'});
      expect(jar.headerFor(uri), 'BDUSS=new-account; STOKEN=new-token');
    });
  }
  test('Ali only confirms a decoded refresh token', () async {
    for (final bizExt in [
      null,
      'not-base64',
      base64Encode(utf8.encode('{}'))
    ]) {
      final client = MockClient((_) async => response({
            'content': {
              'data': {'qrCodeStatus': 'CONFIRMED', 'bizExt': bizExt}
            }
          }));
      final result =
          await NetdiskService(httpClient: client).pollQrSession(qr('ali'));
      expect(result.state, NetdiskPollState.error);
      expect(result.credential, isEmpty);
    }
    final ext = base64Encode(utf8.encode(jsonEncode({
      'pds_login_result': {'refreshToken': 'valid-refresh-token-123456'}
    })));
    expect(NetdiskSession.aliCredential(ext),
        'ali_token=valid-refresh-token-123456');
  });
  test('old Ali QR envelopes without refresh tokens never appear logged in',
      () async {
    SharedPreferences.setMockInitialValues({});
    final storage = await StorageService.init();
    final oldEnvelope =
        base64Encode(utf8.encode('{"pds_login_result":{"refreshToken":null}}'));
    expect(oldEnvelope.contains('='), isFalse,
        reason: 'Regression includes unpadded QR envelopes');
    final value = 'ali_token=$oldEnvelope';
    await storage.setNetdiskCredential('ali', value);
    expect(storage.isNetdiskLoggedIn('ali'), isFalse);
    expect(storage.netdiskCredential('ali'), value);
  });

  test('old placeholder logins are not displayed as authenticated', () async {
    SharedPreferences.setMockInitialValues({});
    final storage = await StorageService.init();
    for (final entry in {
      'uc': 'uc_st=old; token=qr',
      'baidu': 'bduss=old-qr-ticket',
      'ali': 'ali_token=bad'
    }.entries) {
      await storage.setNetdiskCredential(entry.key, entry.value);
      expect(storage.isNetdiskLoggedIn(entry.key), isFalse);
      expect(storage.netdiskCredential(entry.key), entry.value,
          reason: 'Do not silently delete saved data');
    }
    for (final entry in {
      'uc': '__pus=cookie',
      'baidu': 'BDUSS=cookie; STOKEN=st',
      'ali': 'ali_token=valid-refresh-token-123456'
    }.entries) {
      await storage.setNetdiskCredential(entry.key, entry.value);
      expect(storage.isNetdiskLoggedIn(entry.key), isTrue);
    }
  });
}
