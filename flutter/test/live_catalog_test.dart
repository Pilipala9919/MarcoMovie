import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/cms_parser.dart';
import 'package:marco_movie/core/live_catalog_parser.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/core/storage_service.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  tearDown(CmsClient.closeScriptSessions);

  test(
    'live-only JS keeps raw init and source proxy state through player and removal',
    () async {
      const rawExtension = '  { "ticket": "owned" }\n';
      const script = '''export default class {
      init(ext){if(typeof ext!=='string')throw Error('init must be raw'); this.ticket=JSON.parse(ext).ticket;this.calls=0;}
      liveContent(arg){this.calls++; return [{name:'Owned',channels:[{name:arg,url:proxyUrl({ticket:this.ticket}),header:{Origin:'https://media.test'}}]}];}
      proxy(params){if(params.ticket!==this.ticket || params.origin!=='https://media.test')throw Error('lost state or headers'); return [200,'text/plain',this.ticket+':'+this.calls];}
    }''';
      final live = CmsParser.parseConfig(
        jsonEncode({
          'lives': [
            {
              'api': 'csp_LocalScript.js',
              'ext': {
                'script': script,
                'origin': 'pkg://live/main.js',
                'ext': rawExtension,
              },
              'url': 'Channel',
            },
          ],
        }),
        subscriptionId: 'proxy-owner',
      ).lives.single;
      final client = CmsClient();
      final channel = (await client.fetchLiveGroups(
        live,
      )).single.channels.single;
      final release = client.pinPlaybackSource(live.playbackSite);
      addTearDown(release);
      await CmsClient.retainScriptSessions([live.playbackSite]);
      final playable = client.resolveLiveEpisodeForPlayback(
        live.playbackSite,
        channel.episodes.single,
      );
      final socket = HttpClient();
      addTearDown(() => socket.close(force: true));
      final request = await socket.getUrl(Uri.parse(playable.url));
      playable.headers.forEach(request.headers.set);
      final response = await request.close();
      expect(response.statusCode, 200);
      expect(await response.transform(utf8.decoder).join(), 'owned:1');
      await CmsClient.retainScriptSessions([]);
      final removed = await (await socket.getUrl(
        Uri.parse(playable.url),
      )).close();
      await removed.drain<void>();
      expect(removed.statusCode, 404);
    },
  );

  test(
    'redirected catalogue resolves media against final URL and drops original credentials',
    () async {
      final requests = <http.Request>[];
      final client = CmsClient(
        client: MockClient((request) async {
          requests.add(request);
          if (requests.length == 1)
            return http.Response(
              '',
              302,
              headers: {'location': 'https://cdn.test/dir/live.m3u'},
            );
          return http.Response('#EXTM3U\n#EXTINF:-1,Owned\n./stream.m3u8', 200);
        }),
      );
      final live = const LiveSource(
        name: 'Redirect',
        url: 'https://list.test/start',
        headers: {
          'Authorization': 'private',
          'Cookie': 'private',
          'User-Agent': 'Owned',
        },
      );
      final episode = (await client.fetchLiveGroups(
        live,
      )).single.channels.single.episodes.single;
      expect(requests.last.headers.containsKey('Authorization'), false);
      expect(episode.url, 'https://cdn.test/dir/stream.m3u8');
      expect(
        client
            .resolveLiveEpisodeForPlayback(live.playbackSite, episode)
            .headers,
        {'User-Agent': 'Owned'},
      );
    },
  );

  test(
    'API-only lives retain isolated owners, opaque input, extension and JAR declarations',
    () {
      final raw = jsonEncode({
        'spider': './global.jar;md5;abc',
        'lives': [
          {
            'name': 'Same',
            'api': './live.py',
            'ext': '../data.json',
            'groups': [],
            'ua': 'Live-UA',
          },
          {
            'name': 'Same',
            'api': 'csp_Live',
            'jar': './own.jar',
            'url': 'opaque-input',
            'ext': {'mode': 1},
          },
        ],
      });
      CmsConfig parse() => CmsParser.parseConfig(
        raw,
        origin: 'https://list.test/folder/config.json',
        subscriptionId: 'owner',
      );
      final config = parse();
      final python = config.lives.first, jar = config.lives.last;
      expect(python.url, '');
      expect(python.plugin!.api, 'https://list.test/folder/live.py');
      expect(python.plugin!.ext, 'https://list.test/data.json');
      expect(
        python.plugin!.pluginReference,
        'https://list.test/folder/global.jar;md5;abc',
      );
      expect(python.plugin!.headers['User-Agent'], 'Live-UA');
      expect(jar.url, 'opaque-input');
      expect(jsonDecode(jar.plugin!.ext), {'mode': 1});
      expect(jar.plugin!.pluginReference, 'https://list.test/folder/own.jar');
      expect(python.plugin!.key, isNot(jar.plugin!.key));
      expect(python.plugin!.key, parse().lives.first.plugin!.key);
      expect(config.scriptOwners.length, 2);
      final private = python.copyWith(
        isPrivate: true,
        subscriptionId: 'another',
      );
      expect(private.playbackSite.isEffectivelyPrivate, true);
      expect(private.playbackSite.subscriptionId, 'another');
    },
  );

  test(
    'inline JSON channels load without fetching media as a catalogue',
    () async {
      var requests = 0;
      final client = CmsClient(
        client: MockClient((_) async {
          requests++;
          return http.Response('wrong', 500);
        }),
      );
      final live = CmsParser.parseConfig(
        jsonEncode({
          'lives': [
            {
              'name': '内嵌',
              'header': {'User-Agent': 'Live'},
              'channels': [
                {
                  'name': '频道',
                  'urls': [
                    'https://media.test/a.m3u8',
                    'https://media.test/b.m3u8',
                  ],
                },
              ],
            },
          ],
        }),
      ).lives.single;
      final channels = (await client.fetchLiveGroups(live)).single.channels;
      expect(requests, 0);
      expect(channels.single.urls.length, 2);
      expect(channels.single.episodes.first.headers['User-Agent'], 'Live');
    },
  );

  test(
    'legacy proxy directories remain separate from ordinary inline channels',
    () {
      final wrapped =
          'proxy://do=live&type=txt&ext=${base64Encode(utf8.encode('https://list.test/live.txt'))}';
      final config = CmsParser.parseConfig(
        jsonEncode({
          'lives': [
            {
              'name': 'Root',
              'ua': 'Parent',
              'channels': [
                {
                  'name': 'Directory',
                  'urls': [wrapped],
                  'header': {'Referer': 'https://list.test/'},
                },
                {
                  'name': 'Channel',
                  'urls': ['https://media.test/live.m3u8'],
                },
              ],
            },
          ],
        }),
      );
      expect(config.lives.length, 2);
      expect(config.lives.first.url, 'https://list.test/live.txt');
      expect(config.lives.first.headers, {
        'User-Agent': 'Parent',
        'Referer': 'https://list.test/',
      });
      expect(
        CmsParser.parseLivePlaylist(
          config.lives.last.inlineContent,
        ).single.channels.single.name,
        'Channel',
      );
      expect(
        LiveCatalogParser.directoryUrl(
          'proxy://do=live&type=txt&ext=${base64Encode(utf8.encode('file:///private/a.txt'))}',
        ),
        null,
      );
      expect(LiveCatalogParser.directoryUrl('$wrapped&ext=duplicate'), null);
      expect(
        LiveCatalogParser.directoryUrl('proxy://do=custom&type=txt&ext=bad'),
        null,
      );
    },
  );

  test(
    'M3U titles, relative links and headers stay associated with their entry',
    () {
      final result = CmsParser.parseLivePlaylist(
        '''#EXTM3U
#EXTINF:-1 group-title="News,HD" tvg-logo="../logo.png",News, HD
#EXTVLCOPT:http-user-agent=Channel-UA
#EXTVLCOPT:http-referrer=https://refer.test/
./live.m3u8|Origin=https%3A%2F%2Forigin.test
#EXTINF:-1 group-title="News,HD",Next
https://cdn.test/next.m3u8
''',
        origin: 'https://list.test/dir/live.m3u',
        headers: {'User-Agent': 'Parent', 'Authorization': 'private'},
      );
      final first = result.single.channels.first,
          next = result.single.channels.last;
      expect(first.name, 'News, HD');
      expect(first.logo, 'https://list.test/logo.png');
      expect(first.urls.single, 'https://list.test/dir/live.m3u8');
      expect(first.episodes.single.headers, {
        'User-Agent': 'Channel-UA',
        'Referer': 'https://refer.test/',
        'Origin': 'https://origin.test',
        'Authorization': 'private',
      });
      expect(next.episodes.single.headers, {'User-Agent': 'Parent'});
    },
  );

  test(
    'TXT separates fallback URLs without destroying fragments or pipe headers',
    () {
      final channels = CmsParser.parseLivePlaylist(
        'News,#genre#\nOne,https://media.test/a.m3u8#track#https://media.test/b.m3u8|User-Agent=Custom%20UA',
      ).single.channels;
      expect(channels.single.urls, [
        'https://media.test/a.m3u8#track',
        'https://media.test/b.m3u8',
      ]);
      expect(channels.single.episodes.last.headers['User-Agent'], 'Custom UA');
      expect(
        CmsParser.parseLivePlaylist(
          'error,please retry',
          origin: 'https://list.test/a',
        ),
        isEmpty,
      );
    },
  );

  test(
    'JSON group and stream headers override case-insensitively without leaking between streams',
    () {
      final result = CmsParser.parseLivePlaylist(
        jsonEncode({
          'groups': [
            {
              'name': 'News',
              'header': {'user-agent': 'Group'},
              'channels': [
                {
                  'name': 'One',
                  'urls': [
                    {
                      'name': 'HD',
                      'url': '/hd.m3u8',
                      'header': {'User-Agent': 'Stream'},
                    },
                    {'name': 'SD', 'url': '/sd.m3u8'},
                  ],
                },
              ],
            },
          ],
        }),
        origin: 'https://media.test/config',
        headers: {'USER-AGENT': 'Source'},
      );
      final streams = result.single.channels.single.episodes;
      expect(streams.first.name, 'HD');
      expect(streams.first.headers, {'User-Agent': 'Stream'});
      expect(streams.last.headers, {'user-agent': 'Group'});
    },
  );

  test(
    'failed and unsupported plugin catalogues never fetch the opaque argument',
    () async {
      var requests = 0;
      final client = CmsClient(
        client: MockClient((_) async {
          requests++;
          return http.Response('<html>error</html>', 200);
        }),
      );
      await expectLater(
        client.fetchLiveGroups(
          const LiveSource(name: 'Remote', url: 'https://list.test/error'),
        ),
        throwsFormatException,
      );
      expect(requests, 1);
      final plugin = CmsParser.parseConfig(
        '{"lives":[{"api":"csp_NotPorted","url":"https://list.test/not-a-directory"}]}',
      ).lives.single;
      await expectLater(client.fetchLiveGroups(plugin), throwsFormatException);
      expect(requests, 1);
    },
  );

  test(
    'archive live JS entry runs liveContent with its opaque argument and retains state',
    () async {
      const script = '''export default class {
      init(ext){this.state = ext;this.calls = 0;}
      liveContent(arg){return [{name:'Owned',channels:[{name:arg + (++this.calls),url:'https://media.test/live.m3u8',header:{'X-State':this.state}}]}];}
    }''';
      final archive = Archive();
      void add(String name, String text) {
        final bytes = utf8.encode(text);
        archive.addFile(ArchiveFile(name, bytes.length, bytes));
      }

      add(
        'config.json',
        jsonEncode({
          'lives': [
            {'name': 'JS', 'api': './main.js', 'url': 'opaque', 'ext': 'state'},
          ],
        }),
      );
      add('main.js', script);
      final raw = CmsClient.readSubscriptionFile(
        ZipEncoder().encode(archive),
        'source.zip',
      );
      final config = CmsParser.parseConfig(raw, subscriptionId: 'js-live');
      expect(config.lives.single.url, 'opaque');
      final client = CmsClient(
        client: MockClient(
          (_) async => throw StateError('archive must remain offline'),
        ),
      );
      final first = (await client.fetchLiveGroups(
        config.lives.single,
      )).single.channels.single;
      expect(first.name, 'opaque1');
      expect(first.episodes.single.headers['X-State'], 'state');
      await CmsClient.retainScriptSessions(config.scriptOwners);
      expect(
        (await client.fetchLiveGroups(
          config.lives.single,
        )).single.channels.single.name,
        'opaque2',
      );
      await CmsClient.retainScriptSessions([]);
      expect(
        (await client.fetchLiveGroups(
          config.lives.single,
        )).single.channels.single.name,
        'opaque1',
      );
    },
  );

  test(
    'saved live owners survive restart and disappear after subscription deletion',
    () async {
      SharedPreferences.setMockInitialValues({});
      var store = await StorageService.init();
      await store.saveConfig(
        '{"lives":[{"name":"PY","api":"./live.py","url":"opaque","ext":{"mode":1}}]}',
        origin: 'https://source.test/config.json',
      );
      final before = store.loadSavedConfig()!.lives.single;
      final prefs = await SharedPreferences.getInstance();
      SharedPreferences.setMockInitialValues({
        for (final key in prefs.getKeys()) key: prefs.get(key)!,
      });
      store = await StorageService.init();
      final after = store.loadSavedConfig()!.lives.single;
      expect(after.plugin!.key, before.plugin!.key);
      expect(
        after.playbackSite.subscriptionId,
        before.playbackSite.subscriptionId,
      );
      expect(after.plugin!.api, 'https://source.test/live.py');
      expect(after.url, 'opaque');
      await store.removeSubscription(store.getSubscriptions().single.id);
      expect(store.loadSavedConfig(), null);
      expect(store.exportBackupJson(), isNot(contains('live.py')));
    },
  );
}
