// Isolated review probes. All HTTP traffic below is mocked; no account is used.
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:marco_movie/core/app_update.dart';
import 'package:marco_movie/core/csp_bridge.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/core/netdisk_service.dart';
import 'package:marco_movie/core/quark_account.dart';
import 'package:marco_movie/core/quark_drive.dart';
import 'netdisk_login_ui_test.dart' as login;

class ReviewAccounts extends QuarkAccountProvider {
  ReviewAccounts() : super(
    readCredential: () async => '',
    writeCredential: (_) async {},
    httpClient: MockClient((_) async => throw StateError('No account HTTP')),
  );
  final session = QuarkAccountSession(
    cookie: '__pus=review-fixture; __puus=review-fixture',
    driveSt: 'review-ticket',
    accountId: 'review-account',
    validatedAt: DateTime.utc(2026, 11, 10),
  );
  @override
  Future<QuarkAccountSession> requireSession() async => session;
  @override
  Future<void> assertCurrentSession(QuarkAccountSession value, {int? generation}) async {}
}

http.Response ok(Object data) => http.Response(
  jsonEncode({'status': 200, 'code': 0, 'data': data}), 200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('R1: playing a share must not delete unrelated existing cloud files', () async {
    final deleted = <String>[];
    final requests = <String>[];
    final accounts = ReviewAccounts();
    addTearDown(accounts.close);
    final client = MockClient((request) async {
      requests.add(request.url.path);
      switch (request.url.path) {
        case '/1/clouddrive/file/sort':
          if (request.url.queryParameters['pdir_fid'] == '0') {
            return ok({'list': [
              {'fid': 'preexisting-user-folder', 'file_name': '0000temp', 'dir': true}
            ]});
          }
          return ok({'list': [
            {'fid': 'unrelated-family-video', 'file_name': 'family.mp4', 'file_type': 1},
            {'fid': 'unrelated-user-documents', 'file_name': 'documents', 'dir': true}
          ]});
        case '/1/clouddrive/file/delete':
          deleted.addAll((jsonDecode(request.body)['filelist'] as List).cast<String>());
          return ok({});
        case '/1/clouddrive/share/sharepage/save':
          return ok({'save_as': {'save_as_top_fids': ['saved-review-file']}});
        case '/1/clouddrive/file/download':
          return ok([{'download_url': 'https://media.example.test/review.mp4'}]);
        case '/1/clouddrive/file/v2/play':
          return ok({'video_list': []});
        default:
          throw StateError('Unexpected mocked path ${request.url.path}');
      }
    });
    addTearDown(client.close);
    final drive = QuarkDriveClient(accounts: accounts, httpClient: client);
    await drive.resolveWoggShare(const CmsEpisode(
      name: 'Review fixture',
      url: 'mmwogg://quark?pwd_id=fixture&stoken=fixture&fid=fixture&fid_token=fixture',
    ));
    expect(requests, contains('/1/clouddrive/share/sharepage/save'));
    expect(deleted, isEmpty, reason: 'Unrelated files have no application ownership marker');
  });

  test('R2: a 720p direct stream must not acquire unverified 4K/HDR labels', () {
    final lines = CspBridge.buildNetdisk4KLines(const [
      CmsLine(name: '720P fixture', episodes: [
        CmsEpisode(name: 'Episode 1', url: 'https://media.example.test/720p.mp4')
      ])
    ]);
    expect(lines, isNotEmpty);
    expect(lines.map((l) => l.episodes.single.url).toSet(),
      {'https://media.example.test/720p.mp4'});
    expect(lines.any((l) => l.episodes.any((e) => e.name.contains('4K'))), isFalse);
  });

  test('R3: missing iOS checksum must fall back to a verified release', () async {
    var calls = 0;
    final client = MockClient((request) async {
      calls++;
      if (request.url.host != 'api.github.com') {
        return http.Response(jsonEncode({
          'platform': 'ios', 'versionName': '0.5.13',
          'package': {'url': 'https://marcotv.wlj9919.top/movie/MarcoMovie-0.5.13-ios-unsigned.ipa', 'size': 100}
        }), 200);
      }
      return http.Response(jsonEncode([{
        'tag_name': 'ios-v0.5.13',
        'assets': [{
          'name': 'MarcoMovie-0.5.13-ios-unsigned.ipa', 'size': 100,
          'digest': 'sha256:${'a' * 64}',
          'browser_download_url': 'https://github.com/Pilipala9919/MarcoMovie/releases/download/ios-v0.5.13/MarcoMovie-0.5.13-ios-unsigned.ipa'
        }]
      }]), 200);
    });
    addTearDown(client.close);
    final release = await AppUpdate.check(client: client, platform: 'ios');
    expect(release.iosUrl, isNotNull, reason: 'Invalid metadata must not enable the IPA installer');
    expect(calls, 2);
  });

  testWidgets('R4: an in-flight QR poll must not restart polling while paused', (tester) async {
    final service = login.PendingLogin();
    await login.open(tester, service);
    service.creations.single.complete(login.challenge('background-review'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    expect(service.polls.length, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    service.polls.single.complete(const NetdiskPollResult(
      state: NetdiskPollState.waiting, message: 'Waiting',
    ));
    await tester.pump();
    await tester.pump(const Duration(seconds: 4));
    final countWhilePaused = service.polls.length;
    // Dispose before assertion, so a failed assertion leaves no live timer.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(const SizedBox());
    expect(countWhilePaused, 1, reason: 'Background state must suppress newly scheduled polls');
  });
}
