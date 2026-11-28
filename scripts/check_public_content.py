"""Check tracked/public source scope. This is a guardrail, not a secret scanner guarantee."""
from pathlib import Path
import re, subprocess, sys, hashlib, json

ROOT=Path(__file__).resolve().parents[1]
EXCLUDED={'.git','private','tools','dist','build','__pycache__','lib','classes'}
ALLOWED_HOSTS={'nodejs.org','api.github.com','release-assets.githubusercontent.com','marcotv.wlj9919.top','github.com','raw.githubusercontent.com','chromium.googlesource.com','android.googlesource.com','ffmpeg.org','trac.ffmpeg.org','dl.google.com','repo.maven.apache.org',
 'dl.frostwire.com','schemas.android.com','schemas.xmlsoap.org','purl.org','apache.org','xml.org','maven.apache.org','www.apache.org','www.boost.org',
 'www.unicode.org','unicode.org','opensource.org','jsoup.org','developer.mozilla.org',
 'perfectionkills.com','www.engr.mun.ca','android.git.kernel.org','fsf.org','www.gnu.org',
 'gnu.org','www.fsf.org','barcode4j.sourceforge.net','maven.aliyun.com','10.0.2.2','127.0.0.1','localhost','…','x',
 'm.douban.com','movie.douban.com','www.douban.com','img1.doubanio.com','img2.doubanio.com','img3.doubanio.com','cn.bing.com','tse1-mm.cn.bing.net','tse2-mm.cn.bing.net','tse3-mm.cn.bing.net','tse4-mm.cn.bing.net','www.tuxiaobei.com','m.youlai.cn','www.huya.com','mp.huya.com','m.douyu.com','api.bilibili.com','www.bilibili.com','search.bilibili.com','i0.hdslb.com','i1.hdslb.com','i2.hdslb.com',
 'pub.dev','www.6huo.com','api.bgm.tv','bgm.tv','lain.bgm.tv','baike.baidu.com','baike.so.com','v.qq.com','pd.qq.com','weibo.com',
 'cj.ffzyapi.com','tyyszy.com','bfzyapi.com','caiji.dyttzyapi.com','cj.lziapi.com','suoniapi.com','cj.rycjapi.com','hhzyapi.com','jszyapi.com','ikunzyapi.com','subocaiji.com','api.xinlangapi.com','www.hongniuzy2.com','caiji.moduapi.cc','360zy.com','zuidazy.me',
 'uop.quark.cn','pan.quark.cn','drive.quark.cn','drive-pc.quark.cn','drive-social-api.quark.cn','su.quark.cn','www.wogg.net','api.open.uc.cn','drive.uc.cn','su.uc.cn','passport.baidu.com','pan.baidu.com','wappass.baidu.com','passport.aliyundrive.com','www.aliyundrive.com','www.alipan.com','api.qrserver.com','www.mdzypic.com','dav.jianguoyun.com',
 'api.themoviedb.org','image.tmdb.org','api.theintrodb.org','api.trakt.tv','api.mdblist.com','api.assrt.net','api.opensubtitles.com','api.dandanplay.net','api.deepseek.com','dashscope.aliyuncs.com','api.siliconflow.cn','api.moonshot.cn','open.bigmodel.cn','api.openai.com','auth.openai.com','api.anthropic.com','generativelanguage.googleapis.com','openrouter.ai','auth.kimi.com','api.kimi.com','api.githubcopilot.com'}

# Permit documentation/example URLs only in the pinned upstream text files. A changed
# file goes through normal host review again. Private-value scanning remains active.
UPSTREAM_TEXT = json.loads((ROOT/'scripts/upstream-text-sha256.json').read_text(encoding='utf-8'))

# Exact synthetic authorities used to test URL authentication/IPv6 and a second
# loopback origin. Never allow their apparent username-as-host globally, and do
# not suppress any of the private-value checks above the URL review below.
TEST_AUTHORITIES = {
    'android-tv/tests/DrpyChecks.java': {'new:login@127.0.0.1:', 'user:p%2Bss@', 'user:pass@', 'user:p%2Bss@source.test', 'user:pass@source.test'},
    'android-tv/tests/GuardChecks.java': {'user:pass@media.test'},
    'android-mobile/tests/DrpyChecks.java': {'new:login@127.0.0.1:', 'user:p%2Bss@', 'user:pass@', 'user:p%2Bss@source.test', 'user:pass@source.test'},
    'android-mobile/tests/GuardChecks.java': {'user:pass@media.test'},
    'flutter/test/drpy_cancellation_test.dart': {'user:pass@fixture.invalid'},
    'flutter/test/drpy_host_test.dart': {'user:secret@fixture.invalid'},
    'flutter/test/guard_bootstrap_host_test.dart': {'user:secret@fixture.invalid'},
    'flutter/test/subscription_redirect_test.dart': {'injected:secret@127.0.0.1:${origin.port}'},
    'flutter/test/ali_share_test.dart': {'user@www.alipan.com'},
    'flutter/test/cloud_share_test.dart': {'x@drive.uc.cn', 'fast.uc.cn', 'video.uc.cn', 'd.pcs.baidu.com', 'qdall01.baidupcs.com'},
    'flutter/test/desktop_cloud_media_test.dart': {'media.uc.cn'},
    'flutter/test/cloud_media_proxy_test.dart': {'video.uc.cn', 'video.uc.cn:444', 'd.pcs.baidu.com', 'qdall01.baidupcs.com'},
    'flutter/test/quark_drive_test.dart': {'media.quark.cn'},
    'flutter/test/quark_media_proxy_test.dart': {'media.quark.cn', 'next.quark.cn', 'media.quark.cn:444', 'user@media.quark.cn', 'media.uc.cn'},
    'flutter/test/native_cloud_playback_test.dart': {'media.quark.cn'},
    'flutter/test/netdisk_4k_ios_optimization_test.dart': {'cdn.aliyundrive.net', 'dl.quark.cn'},
    'flutter/test/ios_077_connectors_and_netdisk_test.dart': {'d.pcs.baidu.com', 'dl.quark.cn', 'dl.uc.cn'},
    'flutter/test/ios_077_gpt_review_regressions_test.dart': {'d.pcs.baidu.com', 'dl.uc.cn', 'example.com'},
    'flutter/test/ios_077_ux_motion_audit_test.dart': {'user:pass@cdn.example'},
    'flutter/test/wogg_client_test.dart': {'media.uc.cn'},
    'flutter/test/wogg_source_test.dart': {'user:password@catalogue.invalid', 'alipan.com', 'aliyundrive.com', 'fast.uc.cn'},
    'macos/test/drpy_cancellation_test.dart': {'user:pass@fixture.invalid'},
    'macos/test/drpy_host_test.dart': {'user:secret@fixture.invalid'},
    'macos/test/guard_bootstrap_host_test.dart': {'user:secret@fixture.invalid'},
    'macos/test/subscription_redirect_test.dart': {'injected:secret@127.0.0.1:${origin.port}'},
    'macos/test/ali_share_test.dart': {'user@www.alipan.com'},
    'macos/test/cloud_share_test.dart': {'x@drive.uc.cn', 'fast.uc.cn', 'video.uc.cn', 'd.pcs.baidu.com', 'qdall01.baidupcs.com'},
    'macos/test/desktop_cloud_media_test.dart': {'media.uc.cn'},
    'macos/test/cloud_media_proxy_test.dart': {'video.uc.cn', 'video.uc.cn:444', 'd.pcs.baidu.com', 'qdall01.baidupcs.com'},
    'macos/test/quark_drive_test.dart': {'media.quark.cn'},
    'macos/test/quark_media_proxy_test.dart': {'media.quark.cn', 'next.quark.cn', 'media.quark.cn:444', 'user@media.quark.cn', 'media.uc.cn'},
    'macos/test/native_cloud_playback_test.dart': {'media.quark.cn'},
    'macos/test/netdisk_4k_ios_optimization_test.dart': {'cdn.aliyundrive.net', 'dl.quark.cn'},
    'macos/test/wogg_client_test.dart': {'media.uc.cn'},
    'macos/test/wogg_source_test.dart': {'user:password@catalogue.invalid', 'alipan.com', 'aliyundrive.com', 'fast.uc.cn'},
    'android-tv/tests/JsHttpChecks.java': {'new:secret@', 'us%40er:pa%2Bss@'},
    'android-mobile/tests/JsHttpChecks.java': {'new:secret@', 'us%40er:pa%2Bss@'},
    'flutter/test/python_host_compat_test.dart': {'user:pass@[::1]:8443'},
    'flutter/test/python_source_channel_test.dart': {'user:password@source.invalid'},
    'macos/test/python_host_compat_test.dart': {'user:pass@[::1]:8443'},
    'macos/test/python_source_channel_test.dart': {'user:password@source.invalid'},
    'scripts/test_python_host.js': {'user:pass@[::1]:8443', '127.0.0.2', '127.0.0.2:'},
    'scripts/test_python_proxy.js': {'0.0.0.0:18345'},
    'scripts/test_t4_adapter.cjs': {'name:secret@127.0.0.1'},
    'scripts/test_t4_adapter.py': {'name:secret@example.invalid'},
    # The URL scan stops at the escaped dot in this reviewed loopback-only regex.
    'scripts/ios_cpython_transport/dart/fixture_http_transport.dart': {'127'},
    'scripts/ios_cpython_transport/dart/fixture_http_transport_test.dart': {'user@127.0.0.1:${server.port}'},
    'flutter/lib/core/app_log.dart': {'user:password@host'},
    'flutter/test/app_log_test.dart': {'user:super_secret_pw@dav.jianguoyun.com', 'user:[REDACTED]@dav.jianguoyun.com'},
    'macos/lib/core/app_log.dart': {'user:password@host'},
    'macos/test/app_log_test.dart': {'user:super_secret_pw@dav.jianguoyun.com', 'user:[REDACTED]@dav.jianguoyun.com'},
    'android-tv/tests/LaneEChecks.java': {'user:secret@127.0.0.1:'},
    'android-tv/tests/LiveNetworkChecks.java': {'127.0.0.2', '127.0.0.2:'},
    'android-tv/tests/TvPlaybackMultiSourceChecks.java': {'api.example.com', 'cdn.example.com', 'valid-', 'big-', '...'},
    'android-mobile/tests/LaneEChecks.java': {'user:secret@127.0.0.1:'},
    'android-mobile/tests/LiveNetworkChecks.java': {'127.0.0.2', '127.0.0.2:'},
    'flutter/test/security_hardening_test.dart': {'192.168.1.10:5005'},
    'macos/test/security_hardening_test.dart': {'192.168.1.10:5005'},
    'shared/conformance/case_01_bom/meta.json': {'example.com'},
    'shared/conformance/case_01_bom/expected.json': {'api.example.com'},
    'shared/conformance/case_02_utf16/meta.json': {'example.com'},
    'shared/conformance/case_02_utf16/expected.json': {'utf16.example.com'},
    'shared/conformance/case_03_gzip/meta.json': {'example.com'},
    'shared/conformance/case_03_gzip/expected.json': {'gzip.example.com'},
    'shared/conformance/case_04_steganography_jpeg/meta.json': {'example.com'},
    'shared/conformance/case_04_steganography_jpeg/expected.json': {'stego.example.com'},
    'shared/conformance/case_05_hex2423/meta.json': {'example.com'},
    'shared/conformance/case_05_hex2423/expected.json': {'2423.example.com'},
    'shared/conformance/case_06_base64/meta.json': {'example.com'},
    'shared/conformance/case_06_base64/expected.json': {'base64.example.com'},
    'ios/Tests/MarcoIOSCoreTests/EcosystemAndPrivacyTests.swift': {'10.0.2.15:18652'},
}

# Exact SHA-256 hashes of reviewed binary/text conformance inputs under shared/conformance/.
CONFORMANCE_INPUT_SHA256 = {
    'shared/conformance/case_01_bom/input.bin': 'bae38680a1198e008fadcf221690ed9529b51e3aebff260e663335673179a497',
    'shared/conformance/case_02_utf16/input.bin': 'b0718edc2c078ebbb6e2073d12621f42b2e52c136828af9285d52f9dc3622ada',
    'shared/conformance/case_03_gzip/input.bin': '67f68a9eed6415f61dd83009eb158b2668e3d2d839b7b339b5c9a37f287bad96',
    'shared/conformance/case_04_steganography_jpeg/input.bin': '42bbe4ddb16a609bd9fc6821f35cbaa3605b1be773f192191bec59940951608c',
    'shared/conformance/case_05_hex2423/input.bin': 'cf6476076533db3fcaae5db4fc805531ae4949f37e096de785efdf930957c32f',
    'shared/conformance/case_06_base64/input.bin': '1bd9c77b01d42374fe137d1490582273329d99f12a0793b567d2a3c179a9137a',
    'shared/conformance/case_07_comments_trailing_comma/input.bin': '6cc9e9887add02aa60e25967f975abd909fd567e2a0d269a1baa5b7bc8cf0ae0',
    'shared/conformance/case_08_json_null/input.bin': '2e9f10d3b8caf53b3071f0be69b6f9fac7f5ce67f62f1992f8208f3c47f8939b',
    'shared/conformance/case_09_missing_type/input.bin': 'ba57fb0a857ada9c1fdc3cc1b5c68d6bd5fd4168052eed3498f98a2408c9b20c',
    'shared/conformance/case_10_type3_extensionless/input.bin': '482c09f9552080cdf9ee2a1e87a9b4fc380366909760022f33380e07eff0c14b',
    'shared/conformance/case_11_relative_jar_ext/input.bin': '0134fb1b8ddc64a0327cec403fa5f79b80988613870b04f2def11d1957e6a8fa',
    'shared/conformance/case_12_multi_warehouse_urls/input.bin': '2c227f5628515fbe60526d3e0174e6d4ebc6c4475d519373913a6ea007206757',
    'shared/conformance/case_13_storehouse/input.bin': '92937bdc65d89abcae09813bbf0303f7be58558a01556d8d59a02c5e54095bb3',
    'shared/conformance/case_14_data_list/input.bin': 'bad356ed7299c913fd13632ddf42aa0567a4f33dee966938d4b16fe923178a12',
    'shared/conformance/case_15_vod_play_list/input.bin': 'e7be6fc5fa3b35b0070cfa45f138bdfee0fab64ee2229917fe89be81c2b3a317',
    'shared/conformance/case_16_header_priority/input.bin': '7cde3aa30d2881abdba8e3580bbc57dae4ad278dcdc366bc2394042007d1f5e1',
    'shared/conformance/case_17_type0_xml/input.bin': '943ef7b9cf22bd770698251ac2af269432e89123f343ce8c4405f4f2cc5c1fd5',
    'shared/conformance/case_18_parses_fallback/input.bin': '8943c16167683d2d45472cb19dcea9bd3d887cbc744800feb18123f14ff280bd',
    'shared/conformance/case_19_mixed_direct_and_parse_lines/input.bin': 'b1b148e6842a7c90548417138609a22bebbeabcd6c25bc5e4ed45d0d662ffa7d',
    'shared/conformance/case_20_large_ext/input.bin': '099599a0119c8affd5e33e18156da9fe02d22cb5f8d283adaf3ec99f662c847f',
}

# Only these reviewed SSRF/LAN boundary unit tests may assert 192.168.x.x matching.
LAN_IP_TEST_FILES = {
    'flutter/test/adversarial_f8_test.dart',
    'flutter/test/security_hardening_test.dart',
    'macos/test/adversarial_f8_test.dart',
    'macos/test/security_hardening_test.dart',
    'lite/tests/AdversarialConfigServerTest.java',
    'lite/tests/LiteJvmChecks.java',
}

# Pinned interpreter dependencies and their primary documentation are reviewed
# only for the isolated native experiment, never for imported source defaults.
EXPERIMENT_HOSTS = {
    'scripts/ios_cpython/run_cpython_probe.py': {'files.pythonhosted.org'},
    'scripts/ios_cpython/pure-dependencies.lock.json': {'files.pythonhosted.org', 'pypi.org'},
    'scripts/prepare_ios_python_runtime.py': {'files.pythonhosted.org'},
    'scripts/ios_cpython_crypto/source.lock.json': {'files.pythonhosted.org'},
    'scripts/ios_lxml/source.lock.json': {'files.pythonhosted.org'},
    'scripts/ios_lxml/native-libraries.lock.json': {'download.gnome.org'},
    'scripts/ios_lxml/owner_fixture.py': {'www.w3.org'},
    'scripts/ios_cpython/README.md': {'docs.python.org', 'briefcase.beeware.org'},
    'scripts/ios_cpython_transport/README.md': {'requests.readthedocs.io', 'www.rfc-editor.org'},
    'scripts/prepare_windows_python_runtime.py': {'files.pythonhosted.org', 'www.python.org'},
    'scripts/test_windows_python_packaging.py': {'files.pythonhosted.org', 'www.python.org'},
    'flutter/windows_native/marco_webview2_plugin.cpp': {'marco.localhost'},
    '.github/workflows/build-multiplatform.yml': {'gitcode.com'},
}

# Original cloud-provider endpoints used only for an explicitly selected share
# and account. Keep review scoped to the adapter rather than permitting these
# hosts in arbitrary public files. Synthetic media URLs stay test-scoped above.
CLOUD_SHARE_HOSTS = {
    'android-tv/src/main/java/com/github/catvod/crawler/Spider.java': {'223.5.5.5', '1.12.12.12'},
    'android-tv/src/main/java/com/pilipala/marcomovie/Cms.java': {'223.5.5.5', '1.12.12.12'},
    'android-mobile/src/main/java/com/github/catvod/crawler/Spider.java': {'223.5.5.5', '1.12.12.12'},
    'android-mobile/src/main/java/com/pilipala/marcomovie/Cms.java': {'223.5.5.5', '1.12.12.12'},
    'android-mobile/src/main/java/com/pilipala/marcomovie/NetdiskAuthService.java': {'auth.aliyundrive.com'},
    'android-mobile/src/main/java/com/pilipala/marcomovie/PersonalNetdiskLibrary.java': {'pc-api.uc.cn', 'd.pcs.baidu.com', 'api.aliyundrive.com', 'auth.aliyundrive.com', 'bj29.api.aliyunpds.com'},
    'flutter/lib/core/ali_share.dart': {'api.aliyundrive.com', 'auth.aliyundrive.com', 'bj29.api.aliyunpds.com'},
    'flutter/lib/core/ai_service.dart': {
        'auth.openai.com',
        'chatgpt.com',
        'api.openai.com',
        'api.anthropic.com',
        'generativelanguage.googleapis.com',
    },
    'flutter/lib/ui/ios_ai_settings_page.dart': {
        'api.openai.com',
        'api.anthropic.com',
        'generativelanguage.googleapis.com',
    },
    'flutter/lib/core/personal_netdisk_library.dart': {'api.aliyundrive.com', 'auth.aliyundrive.com', 'bj29.api.aliyunpds.com'},
    'flutter/lib/core/netdisk_service.dart': {'auth.aliyundrive.com'},
    'flutter/lib/core/cloud_share.dart': {'fast.uc.cn'},
    'flutter/lib/core/doh_resolver.dart': {'dns.alidns.com', 'cloudflare-dns.com', 'dns.google'},
    'macos/lib/core/ali_share.dart': {'api.aliyundrive.com', 'auth.aliyundrive.com', 'bj29.api.aliyunpds.com'},
    'macos/lib/core/personal_netdisk_library.dart': {'api.aliyundrive.com', 'auth.aliyundrive.com', 'bj29.api.aliyunpds.com'},
    'macos/lib/core/netdisk_service.dart': {'auth.aliyundrive.com'},
    'macos/lib/core/cloud_share.dart': {'fast.uc.cn'},
    'macos/lib/core/doh_resolver.dart': {'dns.alidns.com', 'cloudflare-dns.com', 'dns.google'},
    'ios/Sources/MarcoIOSCore/Network/NetdiskService.swift': {'115.com', 'passportapi.115.com', 'qrcodeapi.115.com'},
    'ios/Sources/MarcoIOSCore/Network/NetdiskShareResolver.swift': {'115.com', 'webapi.115.com'},
    'ios/Sources/MarcoIOSCore/Network/PersonalNetdiskLibrary.swift': {'115.com', 'api.aliyundrive.com', 'auth.aliyundrive.com', 'pc-api.uc.cn', 'webapi.115.com'},
    'shared/catpaw/drpy-http.cjs': {'223.5.5.5', '1.12.12.12', 'dns.alidns.com', 'cloudflare-dns.com'},
}

def paths():
    if (ROOT/'.git').exists():
        result=subprocess.run(['git','ls-files','-z'],cwd=ROOT,check=True,capture_output=True)
        tracked = [ROOT/p for p in result.stdout.decode('utf-8').split('\0') if p and (ROOT/p).exists()]
        extra_untracked = [
            p
            for base in ('android-tv/src', 'android-mobile/src', 'shared/script-host')
            if (ROOT / base).exists()
            for p in (ROOT / base).rglob('*')
            if p.is_file() and not any(part in EXCLUDED for part in p.relative_to(ROOT).parts)
        ]
        report = ROOT/'analysis/BieCuiLe-1.1.4-UI与设置逆向及双端隔离方案.md'
        if report.exists(): extra_untracked.append(report)
        return sorted(set(tracked + extra_untracked))
    return [p for p in ROOT.rglob('*') if p.is_file() and not any(
        part in EXCLUDED or part.endswith(('-classes','-compile')) for part in p.relative_to(ROOT).parts)
        and not p.name.endswith('results.txt')]

issues=[];files=paths()
for p in files:
    relative=p.relative_to(ROOT)
    # Generated blue frames and a sine tone for native HEVC/HTTP regression.
    # Permit only the reviewed bytes, not arbitrary recorded media in tests.
    if relative.as_posix() in {'flutter/test/fixtures/cloud-playback.mkv', 'macos/test/fixtures/cloud-playback.mkv'}:
        if hashlib.sha256(p.read_bytes()).hexdigest()!='158d193f2fc0b9096c77cf2fb8402e347a5761b3503e4612e25d42c6d4a93347':issues.append(f'{relative}: unreviewed playback fixture')
        continue
    if relative.as_posix() in CONFORMANCE_INPUT_SHA256:
        if hashlib.sha256(p.read_bytes()).hexdigest()!=CONFORMANCE_INPUT_SHA256[relative.as_posix()]:issues.append(f'{relative}: unreviewed conformance fixture')
        continue
    if relative.as_posix() in {
        'docs/images/donate-alipay.jpg': '2c231a2f751c9640f9271da3941114967e1a78cc75d02919f6e5c3e4345a12a9',
        'docs/images/donate-wechat.jpg': 'bdd17706be7c0925cec3a93c3a5484a82a4a2cf2c1231ab23204b89254d0c045',
    }:
        expected_qr = {
            'docs/images/donate-alipay.jpg': '2c231a2f751c9640f9271da3941114967e1a78cc75d02919f6e5c3e4345a12a9',
            'docs/images/donate-wechat.jpg': 'bdd17706be7c0925cec3a93c3a5484a82a4a2cf2c1231ab23204b89254d0c045',
        }[relative.as_posix()]
        if hashlib.sha256(p.read_bytes()).hexdigest() != expected_qr:
            issues.append(f'{relative}: unreviewed image asset')
        continue
    vendor_dart = relative.as_posix().startswith((
        'flutter/lib/',
        'flutter/packages/quickjs_engine/lib/',
        'flutter/packages/ohos_platform_shims/lib/',
        'macos/lib/',
        'macos/packages/quickjs_engine/lib/',
    )) and p.suffix == '.dart'
    allow_lib = vendor_dart or relative.as_posix().startswith(('android-tv/tests/lib/aosp-json/', 'android-mobile/tests/lib/aosp-json/'))
    if any(part in (EXCLUDED - {'lib'} if allow_lib else EXCLUDED) for part in relative.parts) or p.suffix in {'.apk','.aab','.p12','.jks','.keystore','.rar','.zip','.bin','.mp4'}:
        issues.append(f'{relative}: excluded file type/path');continue
    if p.suffix=='.png':continue
    data=p.read_bytes()
    try: text=data.decode('utf-8')
    except UnicodeDecodeError:issues.append(f'{relative}: unexpected binary');continue
    if p.name==Path(__file__).name:continue
    for pattern in [r'gh[pousr]_[A-Za-z0-9]{25,}',r'github_pat_[A-Za-z0-9_]{30,}',
                    r'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----',
                    r'[A-Za-z]:[/\\](?:Users|TV)[/\\]',r'192\.168\.\d+\.\d+']:
        if pattern == r'192\.168\.\d+\.\d+' and relative.as_posix() in LAN_IP_TEST_FILES:
            continue
        if re.search(pattern,text):issues.append(f'{relative}: private value pattern')
    if UPSTREAM_TEXT.get(relative.as_posix()) == hashlib.sha256(text.replace('\r\n','\n').encode('utf-8')).hexdigest():
        continue
    for match in re.finditer(r'https?://([^/\s"\'<>\\)`' + '\u3000-\u303f\uff00-\uffef' + r']+)',text):
        authority=match.group(1)
        if authority in TEST_AUTHORITIES.get(relative.as_posix(), set()):continue
        if re.fullmatch(r'\$(?:[A-Za-z_][A-Za-z0-9_]*|\{[A-Za-z_][A-Za-z0-9_.]*\})',authority):continue
        tail=text[match.end():]
        if tail.startswith('\\.'):
            escaped=re.match(r'^((?:[A-Za-z0-9-]+\\\.)+[A-Za-z]{2,})',authority+tail)
            host=escaped.group(1).replace('\\.','.').lower() if escaped else authority.split(':')[0].lower().rstrip('.,;')
        else:
            host=authority.split(':')[0].lower().rstrip('.,;')
        if host in EXPERIMENT_HOSTS.get(relative.as_posix(), set()):continue
        if host in CLOUD_SHARE_HOSTS.get(relative.as_posix(), set()):continue
        if relative.as_posix() in {'flutter/pubspec.lock', 'macos/pubspec.lock'} and host in {'pub.dev','dart.dev'}:continue
        if relative.as_posix() == 'docs/python-json-compatibility.md' and host == 'docs.python.org':continue
        if host not in ALLOWED_HOSTS and not host.endswith(('.test','.example','.invalid')):
            issues.append(f'{relative}: review network domain {host}')

for edition_dir in ('android-tv', 'android-mobile'):
    main_path = ROOT / edition_dir / 'src/main/java/com/pilipala/marcomovie/MainActivity.java'
    if not main_path.exists():
        issues.append(f'{edition_dir}: missing MainActivity.java')
        continue
    main = main_path.read_text(encoding='utf-8')
    if not re.search(r'prefs\.getString\(\s*"origin"\s*,\s*""\s*\)', main):
        issues.append(f'{edition_dir}: First-run configuration address must be empty')
    if '不内置、不提供、不托管' not in main:
        issues.append(f'{edition_dir}: Missing first-run tool declaration')
if issues:
    print('\n'.join(sorted(set(issues))));sys.exit(1)
print(f'PASS public file scope, address default, declaration and network/secret patterns ({len(files)} files)')
