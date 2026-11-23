"""Build the standalone Marco Movie Android Mobile APK from android-mobile/."""
from pathlib import Path
import hashlib
import json
import os
import re
import subprocess
import urllib.request
import xml.etree.ElementTree as ET
import zipfile

from android_build_common import (
    ANDROID,
    DIST,
    ENV,
    JDK,
    RELEASE_SIGNER_SHA256,
    ROOT,
    SDK,
    exe,
    resolve_signing_key,
    run,
)
from android_package_names import compatibility_alias, package_name
from build_catpaw_android import assets_for_package, build as build_catpaw
from build_python_android import build_for_module as build_python_module
from build_quickjs_deadline import build as build_quickjs_deadline

MODULE = ROOT / 'android-mobile'
SRC = MODULE / 'src/main'
BUILD = MODULE / 'build'
ABIS = ('armeabi-v7a', 'arm64-v8a')


def main():
    from prepare_python_html import verify as verify_python_html
    verify_python_html()
    from prepare_python_modules import verify as verify_python_modules
    verify_python_modules()
    if 'MARCOMOVIE_ANDROID_JAR' not in os.environ:
        from prepare_android_platform import prepare
        prepare()

    dependencies = []
    native_files = {}
    resource_dirs = []
    packages = []

    items = json.loads((MODULE / 'dependencies.json').read_text(encoding='utf-8'))
    for filename in ('media-dependencies.json', 'torrent-dependencies.json', 'decoder-dependencies.json'):
        manifest = MODULE / filename
        if manifest.exists():
            items += json.loads(manifest.read_text(encoding='utf-8'))

    for item in items:
        jar = ROOT / 'tools/java-dependencies' / item['url'].rsplit('/', 1)[1]
        jar.parent.mkdir(parents=True, exist_ok=True)
        if not jar.exists():
            jar.write_bytes(urllib.request.urlopen(item['url'], timeout=30).read())
        if hashlib.sha256(jar.read_bytes()).hexdigest() != item['sha256']:
            raise RuntimeError('Dependency digest mismatch: ' + item['name'])
        if jar.suffix == '.aar':
            unpack = BUILD / 'aar' / jar.stem
            unpack.mkdir(parents=True, exist_ok=True)
            with zipfile.ZipFile(jar) as z:
                classes = unpack / 'classes.jar'
                classes.write_bytes(z.read('classes.jar'))
                dependencies.append(classes)
                manifest = ET.fromstring(z.read('AndroidManifest.xml'))
                pkg = manifest.get('package')
                if pkg:
                    packages.append(pkg)
                has_arm64 = any(n.startswith('jni/arm64-v8a/') and n.endswith('.so') for n in z.namelist())
                for name in z.namelist():
                    if name.startswith('jni/armeabi-v7a/') and name.endswith('.so') and has_arm64:
                        native_files['lib/' + name[4:]] = z.read(name)
                    if name.startswith('jni/arm64-v8a/') and name.endswith('.so'):
                        native_files['lib/' + name[4:]] = z.read(name)
                    if name.startswith('res/') and not name.endswith('/'):
                        target = (unpack / name).resolve()
                        if not target.is_relative_to(unpack.resolve()):
                            raise RuntimeError('Invalid AAR resource path')
                        target.parent.mkdir(parents=True, exist_ok=True)
                        target.write_bytes(z.read(name))
                if (unpack / 'res').exists():
                    resource_dirs.append(unpack / 'res')
        else:
            if item.get('java_classes', True):
                dependencies.append(jar)
            if item.get('native_members'):
                with zipfile.ZipFile(jar) as z:
                    for name in item['native_members']:
                        if not (name.startswith('lib/armeabi-v7a/') or name.startswith('lib/arm64-v8a/')) or not name.endswith('.so'):
                            raise RuntimeError('Unexpected native dependency member')
                        native_files[name] = z.read(name)

    deadline_files = build_quickjs_deadline(module_dir=MODULE, abis=ABIS)
    native_files.update(deadline_files)

    catpaw_files, catpaw_assets = build_catpaw(module_dir=MODULE, abis=ABIS)
    native_files.update(catpaw_files)
    catpaw_mobile_assets = assets_for_package(catpaw_assets, native_files, BUILD / 'catpaw/assets-mobile')

    python_mobile_libs, python_mobile_assets = build_python_module(MODULE, abis=ABIS)
    native_files.update(python_mobile_libs)

    ui_spec_assets = BUILD / 'ui-spec-assets'
    badge_rules_src = ROOT / 'shared/ui-spec/badge-rules.json'
    if badge_rules_src.exists():
        (ui_spec_assets / 'ui-spec').mkdir(parents=True, exist_ok=True)
        (ui_spec_assets / 'ui-spec/badge-rules.json').write_bytes(badge_rules_src.read_bytes())
    ui_spec_asset_args = ['-A', ui_spec_assets] if (ui_spec_assets / 'ui-spec/badge-rules.json').exists() else []

    for p in (exe(JDK / 'bin', 'java'), exe(SDK, 'aapt2'), ANDROID):
        if not p.exists():
            raise RuntimeError(f'Required existing tool missing: {p}')

    for folder in (BUILD, BUILD / 'classes', BUILD / 'dex', DIST):
        folder.mkdir(parents=True, exist_ok=True)
    boundary = BUILD.resolve()
    for folder, pattern in ((BUILD / 'classes', '*.class'), (BUILD / 'dex', '*.dex')):
        for old in folder.rglob(pattern):
            if not old.resolve().is_relative_to(boundary):
                raise RuntimeError('Generated output leaves build directory')
            old.unlink()

    manifest_root = ET.parse(SRC / 'AndroidManifest.xml').getroot()
    manifest_version = manifest_root.get('{http://schemas.android.com/apk/res/android}versionName')
    manifest_version_code = int(manifest_root.get('{http://schemas.android.com/apk/res/android}versionCode', '0'))
    edition_versions_file = MODULE / 'edition-versions.json'
    edition_versions = json.loads(edition_versions_file.read_text(encoding='utf-8')) if edition_versions_file.exists() else {}
    mobile_meta = edition_versions.get('android-mobile', {})
    mobile_version = mobile_meta.get('versionName', manifest_version)
    mobile_version_code = int(mobile_meta.get('versionCode', manifest_version_code))

    mobile_manifest = BUILD / 'AndroidManifest.mobile.xml'
    mobile_xml = (SRC / 'AndroidManifest.xml').read_text(encoding='utf-8')
    mobile_xml = re.sub(r'android:versionCode="[^"]+"', f'android:versionCode="{mobile_version_code}"', mobile_xml)
    mobile_xml = re.sub(r'android:versionName="[^"]+"', f'android:versionName="{mobile_version}"', mobile_xml)
    mobile_manifest.write_text(mobile_xml, encoding='utf-8')

    run(exe(SDK, 'aapt2'), 'compile', '--dir', SRC / 'res', '-o', BUILD / 'resources.zip')
    overlays = []
    for i, folder in enumerate(resource_dirs):
        resource = BUILD / f'dep-res-{i}.zip'
        run(exe(SDK, 'aapt2'), 'compile', '--dir', folder, '-o', resource)
        overlays += ['-R', resource]

    generated = BUILD / 'generated'
    generated.mkdir(exist_ok=True)
    for old in generated.rglob('*.java'):
        old.unlink()
    extra = ['--extra-packages', ':'.join(sorted(set(packages)))] if packages else []

    run(
        exe(SDK, 'aapt2'), 'link',
        '-o', BUILD / 'resources-mobile.apk',
        '--manifest', mobile_manifest,
        '-I', ANDROID,
        '-A', SRC / 'assets',
        '-A', catpaw_mobile_assets,
        '-A', python_mobile_assets,
        *ui_spec_asset_args,
        '--java', generated,
        '--auto-add-overlay',
        *extra,
        *overlays,
        '-R', BUILD / 'resources.zip',
    )

    sources = sorted((SRC / 'java').rglob('*.java')) + sorted((ROOT / 'shared/java').rglob('*.java')) + sorted(generated.rglob('*.java'))
    argfile = BUILD / 'javac-sources.txt'
    argfile.write_text('\n'.join('"' + str(p).replace('\\', '/') + '"' for p in sources) + '\n', encoding='utf-8')
    run(
        exe(JDK / 'bin', 'javac'),
        '-encoding', 'UTF-8', '-source', '8', '-target', '8', '-Xlint:-options',
        '-classpath', os.pathsep.join(str(p) for p in [ANDROID, *dependencies]),
        '-d', BUILD / 'classes',
        '@' + str(argfile),
    )

    with zipfile.ZipFile(BUILD / 'classes.jar', 'w', zipfile.ZIP_DEFLATED) as z:
        for p in (BUILD / 'classes').rglob('*.class'):
            z.write(p, p.relative_to(BUILD / 'classes').as_posix())

    run(
        exe(JDK / 'bin', 'java'),
        '-cp', SDK / 'lib/d8.jar', 'com.android.tools.r8.D8',
        '--release', '--min-api', '23',
        '--lib', ANDROID,
        '--output', BUILD / 'dex',
        BUILD / 'classes.jar', *dependencies,
    )

    with zipfile.ZipFile(BUILD / 'resources-mobile.apk') as source, zipfile.ZipFile(BUILD / 'unsigned-mobile.apk', 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as dest:
        for entry in source.infolist():
            dest.writestr(entry, source.read(entry.filename))
        for dex in (BUILD / 'dex').glob('*.dex'):
            dest.write(dex, dex.name)
        for name, data in native_files.items():
            dest.writestr(name, data)

    run(exe(SDK, 'zipalign'), '-f', '4', BUILD / 'unsigned-mobile.apk', BUILD / 'aligned-mobile.apk')

    key = resolve_signing_key(MODULE)
    mobile_apk = DIST / package_name(mobile_version, 'mobile')
    run(
        exe(JDK / 'bin', 'java'), '-jar', SDK / 'lib/apksigner.jar', 'sign',
        '--ks', key, '--ks-key-alias', 'marcomovie', '--ks-pass', 'env:MARCOMOVIE_KEY_PASSWORD',
        '--out', mobile_apk, BUILD / 'aligned-mobile.apk',
    )
    signature = run(exe(JDK / 'bin', 'java'), '-jar', SDK / 'lib/apksigner.jar', 'verify', '--verbose', '--print-certs', mobile_apk, capture=True)
    cert_match = re.search(r'certificate SHA-256 digest:\s*([0-9a-fA-F]{64})', signature)
    signer_sha256 = cert_match.group(1).lower() if cert_match else ''
    expected_signer = os.environ.get(
        'MARCOMOVIE_EXPECTED_SIGNER_SHA256',
        RELEASE_SIGNER_SHA256 if os.environ.get('MARCOMOVIE_RELEASE', '') == '1' else '',
    ).strip().lower()
    if expected_signer and signer_sha256 != expected_signer:
        raise RuntimeError(f'APK signer certificate mismatch: got {signer_sha256}, expected {expected_signer}')

    run(exe(SDK, 'zipalign'), '-c', '4', mobile_apk, capture=True)
    badging = run(exe(SDK, 'aapt'), 'dump', 'badging', mobile_apk, capture=True)
    mobile_digest = hashlib.sha256(mobile_apk.read_bytes()).hexdigest()

    git_commit = ''
    git_dirty = False
    if (ROOT / '.git').exists():
        try:
            git_commit = subprocess.run(['git', 'rev-parse', 'HEAD'], cwd=ROOT, capture_output=True, text=True, check=True).stdout.strip()
            git_dirty = bool(subprocess.run(['git', 'status', '--porcelain'], cwd=ROOT, capture_output=True, text=True, check=True).stdout.strip())
        except Exception:
            pass

    (DIST / (mobile_apk.name + '.sha256')).write_text(mobile_digest + '  ' + mobile_apk.name + '\n', encoding='ascii')
    compatibility_alias(mobile_apk, mobile_version, 'mobile')
    (BUILD / 'apk-signature.txt').write_text(signature, encoding='utf-8')
    (BUILD / 'apk-badging.txt').write_text(badging, encoding='utf-8')

    result = {
        'edition': 'mobile',
        'module': 'android-mobile',
        'mobile_apk': mobile_apk.name,
        'mobile_sha256': mobile_digest,
        'mobile_bytes': mobile_apk.stat().st_size,
        'signature_verified': True,
        'signer_sha256': signer_sha256,
        'zipalign_verified': True,
        'package': 'com.pilipala.marcomovie',
        'mobile_version': mobile_version,
        'mobile_version_code': mobile_version_code,
        'git_commit': git_commit,
        'git_dirty': git_dirty,
        'min_sdk': 23,
        'target_sdk': 28,
        'device_install_tested': False,
        'device_playback_tested': False,
        'signing': 'release-verified signing key' if expected_signer else 'independent local development key; not a store release',
    }
    (BUILD / 'build-validation.json').write_text(json.dumps(result, indent=2), encoding='utf-8')
    print(json.dumps(result, indent=2))
    return result


if __name__ == '__main__':
    main()
