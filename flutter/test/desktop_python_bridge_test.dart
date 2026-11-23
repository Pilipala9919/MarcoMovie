import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/core/python_source_channel.dart';
import 'package:marco_movie/core/python_source_host.dart';

String? _findTestPythonExecutable() {
  final envExe = Platform.environment['MARCOMOVIE_PYTHON_EXE']?.trim();
  if (envExe != null && envExe.isNotEmpty && File(envExe).existsSync()) {
    return envExe;
  }
  final appDir = File(Platform.resolvedExecutable).parent.path;
  final bundled = '$appDir${Platform.pathSeparator}data'
      '${Platform.pathSeparator}python${Platform.pathSeparator}python.exe';
  if (File(bundled).existsSync()) {
    return bundled;
  }
  for (final candidate in const [
    '../build/test-win-python/python.exe',
    'build/test-win-python/python.exe',
  ]) {
    if (File(candidate).existsSync()) {
      return File(candidate).absolute.path;
    }
  }
  return null;
}

String? _findRunnerScript() {
  for (final candidate in const [
    'assets/python-host/desktop_runner.py',
    'flutter/assets/python-host/desktop_runner.py',
  ]) {
    if (File(candidate).existsSync()) {
      return File(candidate).absolute.path;
    }
  }
  return null;
}

Future<bool> _isPidAlive(int pid) async {
  if (Platform.isWindows) {
    final result = await Process.run('tasklist', ['/FI', 'PID eq $pid', '/NH']);
    return (result.stdout as String).contains('$pid');
  }
  final result = await Process.run('kill', ['-0', '$pid']);
  return result.exitCode == 0;
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  final testPythonExe = _findTestPythonExecutable();
  final testRunner = _findRunnerScript();

  tearDown(() {
    DesktopPythonBridge.executableOverride = null;
    DesktopPythonBridge.runnerOverride = null;
  });

  test('desktopRuntimeStatus reports unavailable when executable is missing', () {
    DesktopPythonBridge.executableOverride =
        '${Directory.systemTemp.path}/nonexistent_marco_python_311.exe';
    final status = PythonSourceHost.desktopRuntimeStatus();
    expect(status.ready, isFalse);
    expect(status.backend, 'unavailable');
    expect(status.reason, isNotEmpty);

    final host = PythonSourceHost();
    if (!Platform.isIOS) {
      expect(host.enabled, isFalse);
      expect(host.isDesktopNativeReady, isFalse);
    }
  });

  test(
    'desktopRuntimeStatus and PythonSourceHost auto-enable when bundled Python 3.11 is present',
    () async {
      DesktopPythonBridge.executableOverride = testPythonExe;
      DesktopPythonBridge.runnerOverride = testRunner;

      final status = PythonSourceHost.desktopRuntimeStatus();
      expect(status.ready, isTrue);
      expect(status.backend, 'cpython-3.11-desktop');
      expect(status.version, '3.11');
      expect(status.executablePath, testPythonExe);
      expect(status.runnerPath, isNotNull);

      final host = PythonSourceHost();
      expect(host.enabled, isTrue);
      expect(host.isDesktopNativeReady, isTrue);
      final runtime = await host.runtimeStatus();
      expect(runtime.ready, isTrue);
      await host.close();
    },
    skip: testPythonExe == null
        ? 'Windows Python 3.11 test runtime not staged'
        : false,
  );

  test(
    'real Spider runs AES (Crypto & Cryptodome), lxml, pyquery, bs4, getDependence, HTTP bridge & localProxy',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final base = 'http://127.0.0.1:${server.port}';
      server.listen((request) async {
        final response = request.response;
        if (request.uri.path == '/page') {
          response.headers.contentType = ContentType.html;
          response.write('''
            <html><body>
              <div id="catalog">
                <a class="vod" data-id="v100"><span>玄幻剧场</span></a>
              </div>
              <p class="summary">4K HDR 原盘</p>
            </body></html>
          ''');
        } else if (request.uri.path == '/post-api') {
          final body = await utf8.decoder.bind(request).join();
          response.headers.contentType = ContentType.json;
          response.write(jsonEncode({'echo': body}));
        } else {
          response.statusCode = 404;
        }
        await response.close();
      });

      final bridge = DesktopPythonBridge(
        pythonExecutable: testPythonExe,
        runnerScript: testRunner,
      );
      final host = PythonSourceHost(enabled: true, channel: bridge);
      addTearDown(host.close);

      final helperBytes = Uint8List.fromList(
        utf8.encode('DEPENDENCY_TAG = "dep-loaded-ok"\n'),
      );
      final mainCode = '''
import base64
import io
from bs4 import BeautifulSoup
from lxml import etree
from pyquery import PyQuery as pq
from Crypto.Cipher import AES as CryptoAES
from Crypto.Util.Padding import pad, unpad
from Cryptodome.Cipher import AES as CryptodomeAES
from com.github.catvod.crawler import Spider as TvBoxSpider

class Spider(TvBoxSpider):
    def getDependence(self):
        return ['dep_helper']

    def init(self, extend=""):
        self.cfg = extend

    def homeContent(self, filter):
        import dep_helper
        html = self.fetch('$base/page').text
        doc = etree.HTML(html)
        xpath_title = doc.xpath("//a[@class='vod']/span/text()")[0]
        pq_id = pq(html)("a.vod").attr("data-id")
        bs_summary = BeautifulSoup(html, "html.parser").select_one("p.summary").get_text()

        key = b"0123456789abcdef"
        iv = b"fedcba9876543210"
        cipher = CryptoAES.new(key, CryptoAES.MODE_CBC, iv)
        encrypted = cipher.encrypt(pad(xpath_title.encode("utf-8"), 16))
        decrypted = unpad(
            CryptodomeAES.new(key, CryptodomeAES.MODE_CBC, iv).decrypt(encrypted),
            16,
        ).decode("utf-8")

        post_res = self.post('$base/post-api', data={'k': 'v'}).json()['echo']
        return {
            'list': [{
                'vod_id': pq_id,
                'vod_name': f"{decrypted}|{bs_summary}|{dep_helper.DEPENDENCY_TAG}|{post_res}",
            }]
        }

    def detailContent(self, ids):
        return {
            'list': [{
                'vod_id': ids[0],
                'vod_name': 'Detail',
                'vod_play_from': 'Line1',
                'vod_play_url': '第1集\$ep-1',
            }]
        }

    def playerContent(self, flag, id, vipFlags):
        return {'parse': 0, 'url': self.getProxyUrl({'id': id})}

    def localProxy(self, params):
        payload = io.BytesIO(bytes([0, 1, 2, 255]) + params.get('id', '').encode('utf-8'))
        return [200, 'application/octet-stream', payload, {'X-Proxy-Test': 'desktop-py311'}]
''';

      final package = NativePythonPackage(
        entry: 'main.py',
        files: {
          'main.py': Uint8List.fromList(utf8.encode(mainCode)),
          'dep_helper.py': helperBytes,
        },
        extension: '{"mode":"desktop"}',
      );
      final client = CmsClient(pythonHost: host);
      const site = CmsSite(
        key: 'win_py311_site',
        name: 'WinPy311',
        type: 3,
        api: 'https://source.example/main.py',
      );
      // Invoke via PythonSourceHost + CmsClient package flow.
      final homeJson = await host.invoke(
        sessionKey: 'win-py311-test',
        expectedGeneration: host.generation,
        package: package,
        method: 'home',
        arguments: [false],
      );
      final home = jsonDecode(homeJson) as Map<String, dynamic>;
      final item = (home['list'] as List).single as Map<String, dynamic>;
      expect(item['vod_id'], 'v100');
      expect(item['vod_name'], '玄幻剧场|4K HDR 原盘|dep-loaded-ok|k=v');

      final playJson = await host.callCached(
        sessionKey: 'win-py311-test',
        method: 'play',
        arguments: ['Line1', 'ep-1', <String>[]],
      );
      final play = jsonDecode(playJson!) as Map<String, dynamic>;
      final proxyUrl = Uri.parse(play['url'] as String);
      expect(host.ownsProxyUrl('win-py311-test', proxyUrl), isTrue);

      final httpClient = HttpClient();
      addTearDown(() => httpClient.close(force: true));
      final resp = await (await httpClient.getUrl(proxyUrl)).close();
      final body = await resp.fold<List<int>>([], (a, b) => a..addAll(b));
      expect(resp.statusCode, 200);
      expect(resp.headers.value('x-proxy-test'), 'desktop-py311');
      expect(body, [0, 1, 2, 255, ...utf8.encode('ep-1')]);

      // Verify CmsClient end-to-end site execution also works cleanly.
      final imported = await client.resolveConfigInput(
        rawTextInput: mainCode.replaceAll(
          'import dep_helper',
          '',
        ).replaceAll(
          "{dep_helper.DEPENDENCY_TAG}",
          'ok',
        ).replaceAll(
          "return ['dep_helper']",
          'return []',
        ),
      );
      final fetchedHome = await client.fetchHome(imported.config.sites.single);
      expect(fetchedHome.$2.videos.single.id, 'v100');
      expect(site.key, 'win_py311_site');
    },
    skip: testPythonExe == null
        ? 'Windows Python 3.11 test runtime not staged'
        : false,
  );

  test(
    'infinite loop timeout kills hung subprocess and respawns a clean worker',
    () async {
      final bridge = DesktopPythonBridge(
        pythonExecutable: testPythonExe,
        runnerScript: testRunner,
      );
      addTearDown(bridge.close);

      const spider = '''
class Spider:
    def homeContent(self, filter):
        return {'list': [{'vod_id': 'ok', 'vod_name': 'alive'}]}
    def searchContent(self, key, quick, pg='1'):
        while True:
            pass
''';
      final pkg = NativePythonPackage(
        entry: 'main.py',
        files: {'main.py': Uint8List.fromList(utf8.encode(spider))},
      );
      final proxy = Uri.parse(
        'http://127.0.0.1:1234/_spider/${'a' * 43}/proxy?do=py&siteKey=${'a' * 43}',
      );
      final session = await bridge.open(pkg, proxy, (_) async => {});
      final initialPid = bridge.activePids.single;

      final ok1 = await session.invoke(
        '1' * 32,
        'home',
        [false],
        const Duration(seconds: 5),
      );
      expect((ok1 as Map)['list'][0]['vod_name'], 'alive');

      await expectLater(
        session.invoke(
          '2' * 32,
          'search',
          ['hang', false, '1'],
          const Duration(milliseconds: 350),
        ),
        throwsA(
          isA<PlatformException>().having((e) => e.code, 'code', 'timeout'),
        ),
      );

      // Give OS a brief moment to reap the terminated process.
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(await _isPidAlive(initialPid), isFalse);

      final respawnedPid = bridge.activePids.single;
      expect(respawnedPid, isNot(initialPid));

      final ok2 = await session.invoke(
        '3' * 32,
        'home',
        [false],
        const Duration(seconds: 5),
      );
      expect((ok2 as Map)['list'][0]['vod_name'], 'alive');
    },
    skip: testPythonExe == null
        ? 'Windows Python 3.11 test runtime not staged'
        : false,
  );

  test(
    'DesktopPythonBridge enforces maxSessions=4 LRU eviction and clean process shutdown',
    () async {
      final bridge = DesktopPythonBridge(
        pythonExecutable: testPythonExe,
        runnerScript: testRunner,
        maxSessions: 4,
      );
      addTearDown(bridge.close);

      NativePythonPackage pkgFor(String tag) => NativePythonPackage(
        entry: 'main.py',
        files: {
          'main.py': Uint8List.fromList(
            utf8.encode('''
class Spider:
    def homeContent(self, filter):
        return {'tag': '$tag'}
'''),
          ),
        },
      );

      final proxy = Uri.parse(
        'http://127.0.0.1:1234/_spider/${'b' * 43}/proxy?do=py&siteKey=${'b' * 43}',
      );

      final s1 = await bridge.open(pkgFor('s1'), proxy, (_) async => {});
      final s2 = await bridge.open(pkgFor('s2'), proxy, (_) async => {});
      final s3 = await bridge.open(pkgFor('s3'), proxy, (_) async => {});
      final s4 = await bridge.open(pkgFor('s4'), proxy, (_) async => {});
      expect(bridge.activeSessionCount, 4);
      final pidsBefore = List<int>.from(bridge.activePids);
      expect(pidsBefore.toSet().length, 4);

      // Touch s1 so s2 becomes the least-recently-used session.
      final r1 = await s1.invoke(
        '1' * 32,
        'home',
        [false],
        const Duration(seconds: 5),
      );
      expect((r1 as Map)['tag'], 's1');

      // Opening s5 must evict s2 (LRU) while retaining s1, s3, s4, s5.
      final s5 = await bridge.open(pkgFor('s5'), proxy, (_) async => {});
      expect(bridge.activeSessionCount, 4);

      // Evicted s2 must reject further invocations.
      expect(
        () => s2.invoke('2' * 32, 'home', [false], const Duration(seconds: 2)),
        throwsStateError,
      );

      for (final pair in [(s1, 's1'), (s3, 's3'), (s4, 's4'), (s5, 's5')]) {
        final res = await pair.$1.invoke(
          '4' * 32,
          'home',
          [false],
          const Duration(seconds: 5),
        );
        expect((res as Map)['tag'], pair.$2);
      }

      final pidsToVerifyDead = List<int>.from(bridge.activePids);
      await bridge.close();
      expect(bridge.activeSessionCount, 0);
      await Future<void>.delayed(const Duration(milliseconds: 120));
      for (final pid in pidsToVerifyDead) {
        expect(await _isPidAlive(pid), isFalse);
      }
    },
    skip: testPythonExe == null
        ? 'Windows Python 3.11 test runtime not staged'
        : false,
  );

  test(
    'PythonSourceHost upgrades pool capacity to 4 for desktop runtime and retains 4 concurrent sources',
    () async {
      DesktopPythonBridge.executableOverride =
          '${Directory.systemTemp.path}/nonexistent_marco_python_311.exe';
      final host = PythonSourceHost();
      addTearDown(host.close);
      if (!Platform.isIOS) {
        expect(host.enabled, isFalse);
        expect(host.sessionPoolCapacity, 2);
      }

      DesktopPythonBridge.executableOverride = testPythonExe;
      DesktopPythonBridge.runnerOverride = testRunner;
      expect(host.enabled, isTrue);
      expect(host.isDesktopNativeReady, isTrue);
      expect(host.sessionPoolCapacity, 4);

      NativePythonPackage pkgFor(String tag) => NativePythonPackage(
        entry: 'main.py',
        files: {
          'main.py': Uint8List.fromList(
            utf8.encode('''
class Spider:
    def init(self, extend=""):
        self.calls = 0
    def homeContent(self, filter):
        self.calls += 1
        return {'tag': '$tag', 'calls': self.calls}
    def detailContent(self, ids):
        self.calls += 1
        return {'tag': '$tag', 'calls': self.calls}
'''),
          ),
        },
      );

      for (final tag in ['k1', 'k2', 'k3', 'k4']) {
        final raw = await host.invoke(
          sessionKey: tag,
          expectedGeneration: host.generation,
          package: pkgFor(tag),
          method: 'home',
          arguments: [false],
        );
        expect((jsonDecode(raw) as Map)['tag'], tag);
      }

      // All 4 sessions must remain warm without evicting k1 when k3/k4 opened.
      final cachedK1 = await host.callCached(
        sessionKey: 'k1',
        method: 'detail',
        arguments: [
          ['id1'],
        ],
      );
      expect(cachedK1, isNotNull);
      final k1Map = jsonDecode(cachedK1!) as Map;
      expect(k1Map['tag'], 'k1');
      expect(k1Map['calls'], 2);
    },
    skip: testPythonExe == null
        ? 'Windows Python 3.11 test runtime not staged'
        : false,
  );

  test(
    'DesktopPythonBridge preserves /__package__/ __file__ contract across imports, Path, and pkgutil.get_data',
    () async {
      final bridge = DesktopPythonBridge(
        pythonExecutable: testPythonExe,
        runnerScript: testRunner,
      );
      final host = PythonSourceHost(enabled: true, channel: bridge);
      addTearDown(host.close);

      final package = NativePythonPackage(
        entry: 'bundle/main.py',
        files: {
          'bundle/__init__.py': Uint8List.fromList(utf8.encode('')),
          'bundle/main.py': Uint8List.fromList(
            utf8.encode('''
import json
import pkgutil
from pathlib import Path
from helper import helper_file, helper_title

class Spider:
    def homeContent(self, filter):
        assert __file__ == '/__package__/bundle/main.py', __file__
        assert helper_file == '/__package__/bundle/helper.py', helper_file
        with open(__file__, encoding='utf-8') as self_file:
            assert 'class Spider:' in self_file.read()
        with open(Path(__file__).parent / 'data/metadata.json', encoding='utf-8') as meta_file:
            via_path = json.load(meta_file)['title']
        via_pkgutil = json.loads(pkgutil.get_data('bundle', 'data/metadata.json').decode('utf-8'))['title']
        return {'main_file': __file__, 'helper_file': helper_file, 'titles': [helper_title, via_path, via_pkgutil]}
'''),
          ),
          'bundle/helper.py': Uint8List.fromList(
            utf8.encode('''
import json
helper_file = __file__
with open(__file__.rsplit('/', 1)[0] + '/data/metadata.json', encoding='utf-8') as f:
    helper_title = json.load(f)['title']
'''),
          ),
          'bundle/data/metadata.json': Uint8List.fromList(
            utf8.encode(jsonEncode({'title': '虚拟包契约'})),
          ),
        },
      );

      final raw = await host.invoke(
        sessionKey: 'pkg-file-contract',
        expectedGeneration: host.generation,
        package: package,
        method: 'home',
        arguments: [false],
      );
      final doc = jsonDecode(raw) as Map<String, dynamic>;
      expect(doc['main_file'], '/__package__/bundle/main.py');
      expect(doc['helper_file'], '/__package__/bundle/helper.py');
      expect(doc['titles'], ['虚拟包契约', '虚拟包契约', '虚拟包契约']);
    },
    skip: testPythonExe == null
        ? 'Windows Python 3.11 test runtime not staged'
        : false,
  );
}
