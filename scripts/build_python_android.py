"""Build libmarco_python.so JNI bridge and stage pinned CPython 3.11 runtime for Android."""
from pathlib import Path
import hashlib
import os
import shutil
import subprocess
import urllib.request
import zipfile
from build_catpaw_android import toolchain
from native_elf import inspect_elf

ROOT = Path(__file__).resolve().parents[1]
CACHE = ROOT / 'tools/python-android'
DEPS_CACHE = CACHE / 'deps'

PYTHON_VERSION = '3.11.17-0'
TARGETS = {
    'armeabi-v7a': (
        f'https://repo.maven.apache.org/maven2/com/chaquo/python/target/{PYTHON_VERSION}/target-{PYTHON_VERSION}-armeabi-v7a.zip',
        '7516b90fcb8a5a2df70e5f9899aab7e63fa43efa0455c3ba7b846ae54d70ee2c',
        'armv7a-linux-androideabi23',
    ),
    'arm64-v8a': (
        f'https://repo.maven.apache.org/maven2/com/chaquo/python/target/{PYTHON_VERSION}/target-{PYTHON_VERSION}-arm64-v8a.zip',
        '399b58d04898f2c7d5f0044e141bdf3818552e538e5f36d06d7fe0bebc298582',
        'aarch64-linux-android23',
    ),
}
STDLIB = (
    f'https://repo.maven.apache.org/maven2/com/chaquo/python/target/{PYTHON_VERSION}/target-{PYTHON_VERSION}-stdlib-pyc.zip',
    '5b853d5631b8f482f4f181af3d7b8162c17f440da5eafc5e1f64b23faf53f773',
)

# Official upstream GitHub release tag archives for pure-Python spider dependencies.
PURE_DEPS = [
    (
        'requests-2.32.3.zip',
        'https://github.com/psf/requests/archive/refs/tags/v2.32.3.zip',
        'ce709c9c71109afc6d0308b3975dab231c03fb414ac572bcbd55e40909f0a2b3',
        'requests-2.32.3/src/requests/',
        'requests/',
    ),
    (
        'urllib3-2.2.3.zip',
        'https://github.com/urllib3/urllib3/archive/refs/tags/v2.2.3.zip',
        'c487db502a4a09b98621714e47bddd96e6ccffbeb38e544375f43eacfea34022',
        'urllib3-2.2.3/src/urllib3/',
        'urllib3/',
    ),
    (
        'certifi-2024.08.30.zip',
        'https://github.com/certifi/python-certifi/archive/refs/tags/2024.08.30.zip',
        '6201ea59652cd15b564f4b3972e9404a4ca422c3b7dc48e18fc34bf0eca0ad7e',
        'python-certifi-2024.08.30/certifi/',
        'certifi/',
    ),
    (
        'idna-3.10.zip',
        'https://github.com/kjd/idna/archive/refs/tags/v3.10.zip',
        '5fba374e05680d9be2fc4fa13124481d0318573b8612a0b8c9658bfc027566a5',
        'idna-3.10/idna/',
        'idna/',
    ),
    (
        'charset_normalizer-3.4.0.zip',
        'https://github.com/Ousret/charset_normalizer/archive/refs/tags/3.4.0.zip',
        '07847b2335e03f3996ed99ce62434186180dc2652c6ad795289616300b3b9110',
        'charset_normalizer-3.4.0/charset_normalizer/',
        'charset_normalizer/',
    ),
    (
        'soupsieve-2.6.zip',
        'https://github.com/facelessuser/soupsieve/archive/refs/tags/2.6.zip',
        '9b2efa86e539a7abc4aed4f242909dd9f8153fb158cc4295421fd0f8390e9b4a',
        'soupsieve-2.6/soupsieve/',
        'soupsieve/',
    ),
    (
        'pyaes-1.6.1.zip',
        'https://github.com/ricmoo/pyaes/archive/refs/tags/v1.6.1.zip',
        'e1e1170228c38bb71946462bbb6df692457020279c34b4b37de0ea8ec743e828',
        'pyaes-1.6.1/pyaes/',
        'pyaes/',
    ),
]


def _fetch_verified(dest: Path, url: str, expected_sha256: str) -> Path:
    dest.parent.mkdir(parents=True, exist_ok=True)
    if not dest.exists():
        req = urllib.request.Request(url, headers={'User-Agent': 'MarcoMovie-Build/1.0'})
        dest.write_bytes(urllib.request.urlopen(req, timeout=60).read())
    actual = hashlib.sha256(dest.read_bytes()).hexdigest()
    if actual != expected_sha256:
        raise RuntimeError(f'Python artifact digest mismatch for {dest.name}: {actual} != {expected_sha256}')
    return dest


def _build_site_packages_zip(out_zip: Path) -> bytes:
    out_zip.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(out_zip, 'w', zipfile.ZIP_DEFLATED) as dst:
        for filename, url, digest, src_prefix, dst_prefix in PURE_DEPS:
            archive = _fetch_verified(DEPS_CACHE / filename, url, digest)
            with zipfile.ZipFile(archive) as src:
                for info in sorted(src.infolist(), key=lambda i: i.filename):
                    if info.is_dir() or not info.filename.startswith(src_prefix):
                        continue
                    rel = info.filename[len(src_prefix):]
                    if not rel or '/__pycache__/' in rel or rel.endswith('.pyc'):
                        continue
                    if not (rel.endswith('.py') or rel.endswith('.pem') or rel.endswith('py.typed')):
                        continue
                    dst.writestr(dst_prefix + rel, src.read(info.filename))
    return out_zip.read_bytes()


def build_for_module(module_dir: Path, abis=('armeabi-v7a',)):
    """Build CPython JNI bridge and runtime assets isolated to a single Android edition module."""
    module_dir = Path(module_dir)
    build_dir = module_dir / 'build/python'
    ndk = toolchain()
    clang = ndk / 'bin' / ('clang.exe' if os.name == 'nt' else 'clang')
    if not clang.exists():
        raise RuntimeError(f'NDK clang missing: {clang}')

    stdlib_zip = _fetch_verified(
        CACHE / f'target-{PYTHON_VERSION}-stdlib-pyc.zip', STDLIB[0], STDLIB[1]
    )
    site_zip = build_dir / 'site-packages.zip'
    site_bytes = _build_site_packages_zip(site_zip)

    native_libs = {}
    dynload_zips = {}
    bridge_src = module_dir / 'src/main/cpp/python_bridge.c'
    runner_src = module_dir / 'src/main/assets/python-native/android_runner.py'

    for abi in abis:
        if abi not in TARGETS:
            raise ValueError(f'Unsupported Python Android ABI: {abi}')
        url, digest, triple = TARGETS[abi]
        archive = _fetch_verified(CACHE / f'target-{PYTHON_VERSION}-{abi}.zip', url, digest)
        unpack = build_dir / 'unpack' / abi
        if unpack.exists():
            shutil.rmtree(unpack)
        unpack.mkdir(parents=True, exist_ok=True)
        with zipfile.ZipFile(archive) as z:
            z.extractall(unpack)

        inc_dir = unpack / 'include/python3.11'
        lib_dir = unpack / 'jniLibs' / abi
        libpython = lib_dir / 'libpython3.11.so'
        if not inc_dir.is_dir() or not libpython.is_file():
            raise RuntimeError(f'Incomplete CPython target archive for {abi}')

        out_so = build_dir / 'so' / abi / 'libmarco_python.so'
        out_so.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(
            list(
                map(
                    str,
                    [
                        clang,
                        '--target=' + triple,
                        '--sysroot=' + str(ndk / 'sysroot'),
                        '-shared',
                        '-fPIC',
                        '-O2',
                        '-I' + str(inc_dir),
                        '-Wl,--no-undefined',
                        '-Wl,-z,max-page-size=16384',
                        '-Wl,-soname,libmarco_python.so',
                        bridge_src,
                        libpython,
                        '-llog',
                        '-o',
                        out_so,
                    ],
                )
            ),
            check=True,
        )

        # Collect all JNI libraries for this ABI (never overwriting libc++_shared.so).
        abi_libs = {}
        for so in sorted(lib_dir.glob('*.so')):
            if so.name == 'libc++_shared.so':
                continue
            abi_libs[so.name] = so.read_bytes()
        abi_libs['libmarco_python.so'] = out_so.read_bytes()

        if abi == 'arm64-v8a':
            for name, data in abi_libs.items():
                elf = inspect_elf(data)
                if elf['bits'] != 64 or not elf['compatible_16kb']:
                    raise RuntimeError(f'Python ARM64 library is not 16 KB page-aligned: {name}')

        for name, data in abi_libs.items():
            native_libs[f'lib/{abi}/{name}'] = data

        # Package ABI-specific lib-dynload extensions into a compact zip asset.
        dyn_dir = unpack / 'lib-dynload' / abi
        dyn_zip = build_dir / f'lib-dynload-{abi}.zip'
        with zipfile.ZipFile(dyn_zip, 'w', zipfile.ZIP_DEFLATED) as dz:
            for ext_so in sorted(dyn_dir.glob('*.so')):
                dz.write(ext_so, ext_so.name)
        dynload_zips[abi] = dyn_zip

    version_hash = hashlib.sha256(
        (
            PYTHON_VERSION
            + ':'
            + hashlib.sha256(site_bytes).hexdigest()
            + ':'
            + hashlib.sha256(runner_src.read_bytes()).hexdigest()
        ).encode('utf-8')
    ).hexdigest()[:16]

    assets_root = build_dir / 'assets'
    target_dir = assets_root / 'python-native'
    if target_dir.exists():
        shutil.rmtree(target_dir)
    target_dir.mkdir(parents=True, exist_ok=True)
    shutil.copy2(stdlib_zip, target_dir / 'stdlib-pyc.zip')
    shutil.copy2(site_zip, target_dir / 'site-packages.zip')
    for abi in abis:
        shutil.copy2(dynload_zips[abi], target_dir / f'lib-dynload-{abi}.zip')
    (target_dir / 'runtime-version.txt').write_text(version_hash + '\n', encoding='ascii')

    print(
        f'PASS built Android CPython {PYTHON_VERSION} bridge for {module_dir.name} '
        f'(abis={",".join(abis)}, libs={len(native_libs)}, stamp={version_hash})'
    )
    return native_libs, assets_root


def build():
    native_tv, assets_tv = build_for_module(ROOT / 'android-tv', abis=('armeabi-v7a',))
    native_mobile, assets_mobile = build_for_module(ROOT / 'android-mobile', abis=('armeabi-v7a', 'arm64-v8a'))
    return native_tv, native_mobile, assets_tv, assets_mobile


if __name__ == '__main__':
    build()
