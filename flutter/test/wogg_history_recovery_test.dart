import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/core/wogg_source.dart';

const site = CmsSite(
    key: 'wogg',
    name: '玩偶',
    type: 3,
    api: 'csp_WoGGGuard',
    headers: {'Cookie': 'subscription-secret'},
    ext: '{"siteUrl":"http://original.invalid/"}');

String detail(String title, String share) => '''<title>玩偶共享站</title>
  <h1>$title</h1><div class="video-info"></div>
  <div class="module-tab-item downtab-item">优汐<span>1</span></div>
  <div class="module-downlist"><div class="module-row-info">
  <a data-clipboard-text="https://drive.uc.cn/s/$share"></a></div></div>''';

String search(List<(String, String, String)> rows) => '''<title>玩偶共享站</title>
  <div id="search"></div>${rows.map((row) => '''<div class="module-search-item">
  <div class="video-info-header"><h3><a href="/voddetail/${row.$1}.html">${row.$2}</a></h3></div>
  <div class="module-item-caption"><span>${row.$3}</span></div></div>''').join()}''';

void main() {
  Future<Map> run(
      {String oldId = '123',
      String title = '测试大陆2：绝世篇',
      String year = '',
      String? oldPage,
      List<(String, String, String)>? matches,
      String newTitle = '测试大陆2：绝世篇2023',
      List<Uri>? requests,
      List<String>? shares}) async {
    final source = WoggSource(
        readBytes: (_, __) async => throw StateError('No plugin'),
        read: (url, headers) async {
          final uri = Uri.parse(url);
          requests?.add(uri);
          expect(uri.host, 'original.invalid');
          expect(headers.keys.map((key) => key.toLowerCase()),
              isNot(contains('cookie')));
          if (uri.path.startsWith('/vodsearch/')) {
            expect(uri.queryParameters['wd'], title);
            return search(matches ?? [('456', newTitle, '2023')]);
          }
          if (uri.path == '/voddetail/456.html') {
            return detail(newTitle, 'correct');
          }
          return oldPage ?? '<html>404</html>';
        },
        listShare: (url) async {
          shares?.add(url);
          return [
            const CmsEpisode(name: 'original.mkv', url: 'mmcloud://uc?fid=one')
          ];
        });
    return jsonDecode(
        await source.invoke(site, 'detail', [oldId, title, year]));
  }

  test('history without year recovers a unique same-source title and new ID',
      () async {
    final requests = <Uri>[];
    final shares = <String>[];
    final result = await run(requests: requests, shares: shares);
    final video = result['list'][0];
    expect(video['vod_id'], '456');
    expect(video['vod_name'], '测试大陆2：绝世篇2023');
    expect(shares, ['https://drive.uc.cn/s/correct']);
    expect(video['wogg_share_errors'].last['message'], contains('重新选择原文件'));
    expect(requests.first.scheme, 'https');
    expect(requests.any((uri) => uri.scheme == 'http'), isTrue);
    expect(
        requests.where((uri) => uri.path.startsWith('/vodsearch/')).length, 1);
  });

  test('valid legacy ID with the wrong movie never opens its shares', () async {
    final shares = <String>[];
    final result =
        await run(oldPage: detail('完全不同的影片', 'wrong'), shares: shares);
    expect(result['list'][0]['vod_id'], '456');
    expect(shares, ['https://drive.uc.cn/s/correct']);
  });

  test('current matching ID does not need a recovery search', () async {
    final requests = <Uri>[];
    final result = await run(oldId: '456', requests: requests);
    expect(result['list'][0]['vod_id'], '456');
    expect(requests.length, 1);
    expect(result['list'][0]['wogg_share_errors'] ?? [], isEmpty);
  });

  test('malformed old IDs are never interpolated into catalogue paths',
      () async {
    final requests = <Uri>[];
    await run(oldId: '../?other=true', requests: requests);
    expect(requests.first.path, startsWith('/vodsearch/'));
    expect(requests.any((uri) => uri.queryParameters.containsKey('other')),
        isFalse);
  });

  for (final entry in <String, List<(String, String, String)>>{
    'ambiguous editions': [
      ('456', '测试大陆2：绝世篇2023', '2023'),
      ('457', '测试大陆2：绝世篇', '')
    ],
    'different sequel': [('456', '测试大陆3：绝世篇2023', '2023')],
    'different edition': [('456', '测试大陆2：绝世篇 剧场版', '2023')],
    'no match': [],
  }.entries) {
    test('recovery refuses ${entry.key}', () async {
      final shares = <String>[];
      await expectLater(
          run(matches: entry.value, shares: shares), throwsFormatException);
      expect(shares, isEmpty);
    });
  }

  test('known year conflicts cannot silently select a remake', () async {
    final shares = <String>[];
    await expectLater(run(year: '2025', shares: shares), throwsFormatException);
    expect(shares, isEmpty);
  });

  test('same-title direct detail with conflicting year cannot open shares',
      () async {
    final shares = <String>[];
    await expectLater(
        run(
            year: '2025',
            oldPage: '${detail('测试大陆2：绝世篇', 'wrong')}'
                '<div class="video-info-aux"><a>2023</a></div>',
            shares: shares),
        throwsFormatException);
    expect(shares, isEmpty);
  });

  test(
      'a changed result between search and detail is rejected without recursion',
      () async {
    final requests = <Uri>[];
    final shares = <String>[];
    await expectLater(
        run(
            matches: [('456', '测试大陆2：绝世篇', '2023')],
            newTitle: '别的影片',
            requests: requests,
            shares: shares),
        throwsFormatException);
    expect(shares, isEmpty);
    expect(
        requests.where((uri) => uri.path.startsWith('/vodsearch/')).length, 1);
  });
}
