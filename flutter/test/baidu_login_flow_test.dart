import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:marco_movie/core/netdisk_service.dart';
import 'package:marco_movie/core/netdisk_session.dart';

http.Response jsonResponse(Object value, {String? cookie}) =>
    http.Response(jsonEncode(value), 200,
        headers: {if (cookie != null) 'set-cookie': cookie});

void main() {
  test('Baidu completes redirects and verifies pan-scoped account cookies',
      () async {
    final paths = <String>[];
    final client = MockClient((request) async {
      paths.add(request.url.path);
      expect(request.followRedirects, isFalse);
      if (request.url.host == 'passport.baidu.com') {
        expect(request.url.queryParameters['loginVersion'], 'v4');
        expect(request.url.queryParameters['u'],
            'https://pan.baidu.com/disk/home');
        expect(request.url.queryParameters['bduss'], 'qr-one-use');
        return http.Response('', 302, headers: {
          'location': 'https://pan.baidu.com/disk/main',
          'set-cookie': 'BDUSS=real-account; Domain=.baidu.com; Path=/, '
              'STOKEN=passport-token; Domain=.baidu.com; Path=/, '
              'FLOW=passport-only; Path=/'
        });
      }
      expect(request.headers['Cookie'], contains('BDUSS=real-account'));
      expect(request.headers['Cookie'], isNot(contains('FLOW=')));
      if (request.url.path == '/disk/main') {
        return jsonResponse({},
            cookie: 'STOKEN=pan-token; Path=/, PANPSC=pan-session; Path=/');
      }
      if (request.url.path == '/disk/home') {
        return http.Response('', 302, headers: {'location': '/disk/main'});
      }
      expect(request.headers['Cookie'], contains('STOKEN=pan-token'));
      expect(request.headers['Cookie'], isNot(contains('passport-token')));
      if (request.url.path == '/api/loginStatus') return jsonResponse({});
      expect(request.url.path, '/rest/2.0/membership/user/info');
      expect(request.url.queryParameters['method'], 'query');
      return jsonResponse({
        'errno': 0,
        'user_info': {'uk': 1357}
      });
    });
    expect(await NetdiskSession.exchangeBaidu(client, 'qr-one-use'),
        'BDUSS=real-account; STOKEN=pan-token; PANPSC=pan-session');
    expect(paths, [
      '/v3/login/main/qrbdusslogin',
      '/disk/main',
      '/disk/home',
      '/disk/main',
      '/api/loginStatus',
      '/rest/2.0/membership/user/info'
    ]);
  });

  for (final entry in <String, Object>{
    'BDUSS alone with verified account': {
      'errno': 0,
      'user_info': {'user_id': '123'}
    },
    'expired account despite cookies': {
      'errno': -6,
      'user_info': {'uk': 123}
    },
    'zero account identity': {
      'errno': 0,
      'user_info': {'uk': 0}
    },
    'missing account identity': {'errno': 0},
    'HTML login page': '<html>login</html>',
  }.entries) {
    test('Baidu ${entry.key}', () async {
      final service = NetdiskService(httpClient: MockClient((request) async {
        switch (request.url.path) {
          case '/channel/unicast':
            return jsonResponse({
              'errno': 0,
              'channel_v': {'status': 0, 'v': 'ticket'}
            });
          case '/v3/login/main/qrbdusslogin':
            return jsonResponse({},
                cookie: 'BDUSS=real-account; Domain=.baidu.com; Path=/');
          case '/disk/home':
          case '/api/loginStatus':
            return jsonResponse({});
          case '/rest/2.0/membership/user/info':
            return entry.value is String
                ? http.Response(entry.value as String, 200)
                : jsonResponse(entry.value);
          default:
            throw StateError('Unexpected endpoint');
        }
      }));
      addTearDown(service.close);
      final result = await service.pollQrSession(const NetdiskQrSession(
          driveKey: 'baidu', token: 'qr', qrContentUrl: '', qrImageUrl: ''));
      final valid = entry.key.startsWith('BDUSS alone');
      expect(result.state,
          valid ? NetdiskPollState.confirmed : NetdiskPollState.error);
      expect(result.accountVerified, valid);
      expect(result.credential, valid ? 'BDUSS=real-account' : '');
    });
  }

  test(
      'Baidu cookies preserve host scope, expiry and reject cross-domain injection',
      () {
    final jar = BaiduLoginCookies();
    final passport =
        Uri.https('passport.baidu.com', '/v3/login/main/qrbdusslogin');
    final pan = Uri.https('pan.baidu.com', '/disk/home');
    jar.receive(
        jsonResponse({},
            cookie: 'BDUSS=root-account; Domain=.baidu.com; Path=/, '
                'STOKEN=root-token; Domain=.baidu.com; Path=/, '
                'STOKEN=forged; Domain=pan.baidu.com; Path=/, '
                'PTOKEN=passport-only; Path=/'),
        passport);
    expect(jar.accountCookies['STOKEN'], 'root-token');
    expect(jar.accountCookies.containsKey('PTOKEN'), isFalse);
    jar.receive(
        jsonResponse({},
            cookie: 'STOKEN=pan-token; Path=/, '
                'PANPSC=pan-only; Domain=pan.baidu.com; Path=/, '
                'BDUSS=forged; Domain=passport.baidu.com; Path=/'),
        pan);
    expect(jar.accountCookies['BDUSS'], 'root-account');
    expect(jar.accountCookies['STOKEN'], 'pan-token');
    expect(jar.headerFor(passport), contains('STOKEN=root-token'));
    expect(jar.headerFor(passport), isNot(contains('pan-only')));
    jar.receive(
        jsonResponse({}, cookie: 'STOKEN=deleted; Path=/; Max-Age=0'), pan);
    expect(jar.accountCookies['STOKEN'], 'root-token');
    for (final url in [
      'http://pan.baidu.com/',
      'https://pan.baidu.com.evil.test/',
      'https://pan.baidu.com:8443/',
    ]) {
      expect(jar.headerFor(Uri.parse(url)), isEmpty);
    }
    expect(
        jar.headerFor(
            Uri.https('pan.baidu.com', '/').replace(userInfo: 'fixture-user')),
        isEmpty);
  });

  test('Baidu rejects external redirects before sending any cookies there',
      () async {
    final hosts = <String>[];
    final client = MockClient((request) async {
      hosts.add(request.url.host);
      return http.Response('', 302, headers: {
        'set-cookie': 'BDUSS=real-account; Domain=.baidu.com; Path=/',
        'location': 'https://other.invalid/disk/main'
      });
    });
    await expectLater(
        NetdiskSession.exchangeBaidu(client, 'ticket'), throwsFormatException);
    expect(hosts, ['passport.baidu.com']);
  });

  test('Baidu caps same-site redirect loops', () async {
    var count = 0;
    final client = MockClient((request) async {
      count++;
      return http.Response('', 302, headers: {'location': '/disk/main'});
    });
    await expectLater(
        NetdiskSession.baiduRequest(client,
            Uri.https('pan.baidu.com', '/disk/home'), BaiduLoginCookies()),
        throwsFormatException);
    expect(count, 6);
  });
}
