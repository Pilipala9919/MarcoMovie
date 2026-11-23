"""Fetch pinned official Python 3.11 Windows Embeddable runtime and verified PyPI wheels."""
from __future__ import annotations

import argparse
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import sys
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
PYTHON_VERSION = '3.11.9'
PYTHON_EMBED_PTH = 'python311._pth'

EMBED_RUNTIME = {
    'name': 'python-embed-amd64',
    'version': PYTHON_VERSION,
    'filename': 'python-3.11.9-embed-amd64.zip',
    'url': 'https://www.python.org/ftp/python/3.11.9/python-3.11.9-embed-amd64.zip',
    'sha256': '009d6bf7e3b2ddca3d784fa09f90fe54336d5b60f0e0f305c37f400bf83cfd3b',
    'license': 'PSF-2.0',
}

# Pinned 11 target PyPI packages (+ typing-extensions required at runtime by beautifulsoup4==4.15.0).
WHEELS = (
    {
        'name': 'requests',
        'version': '2.34.2',
        'filename': 'requests-2.34.2-py3-none-any.whl',
        'url': 'https://files.pythonhosted.org/packages/a0/f4/c67b0b3f1b9245e8d266f0f112c500d50e5b4e83cb6f3b71b6528104182a/requests-2.34.2-py3-none-any.whl',
        'sha256': '2a0d60c172f83ac6ab31e4554906c0f3b3588d37b5cb939b1c061f4907e278e0',
    },
    {
        'name': 'urllib3',
        'version': '2.8.0',
        'filename': 'urllib3-2.8.0-py3-none-any.whl',
        'url': 'https://files.pythonhosted.org/packages/92/9d/c4e665119135114480843e7ab388fa94d8480650450e6f8e26b70d323a4c/urllib3-2.8.0-py3-none-any.whl',
        'sha256': '0cf3cae568d36aa9576b28dfb35f11328f1cb974ca7647d9475ebb86c75ac6e3',
    },
    {
        'name': 'certifi',
        'version': '2026.11.20',
        'filename': 'certifi-2026.11.20-py3-none-any.whl',
        'url': 'https://files.pythonhosted.org/packages/6d/39/5eec3296860b94ac20bb8ed807725b88f6adfab3f343df592afd975f5f86/certifi-2026.11.20-py3-none-any.whl',
        'sha256': '7422df25243767b9877031a2248cb14d09ddac9beee846f4cef3d5c9191d488f',
    },
    {
        'name': 'idna',
        'version': '3.20',
        'filename': 'idna-3.20-py3-none-any.whl',
        'url': 'https://files.pythonhosted.org/packages/58/a2/bb081bab032533a855d44de1d56f8e8426114ff1ba5d1f07a438a0a654f8/idna-3.20-py3-none-any.whl',
        'sha256': 'ab7ae7122974553370f0bdb919e1a960b2cd1bc1ef0276416d896db81c14582c',
    },
    {
        'name': 'charset-normalizer',
        'version': '3.5.2',
        'filename': 'charset_normalizer-3.5.2-py3-none-any.whl',
        'url': 'https://files.pythonhosted.org/packages/fc/ad/d07d7862a62ffa6d79d68074d14823243dd235a77c45262acbf6adeb28bf/charset_normalizer-3.5.2-py3-none-any.whl',
        'sha256': 'b6b751274acb69d77b3323d6b7dbaa3c7fdfc1eb829b7eb61d262f32e1af9685',
    },
    {
        'name': 'beautifulsoup4',
        'version': '4.15.0',
        'filename': 'beautifulsoup4-4.15.0-py3-none-any.whl',
        'url': 'https://files.pythonhosted.org/packages/88/c6/92fcd42f1ba33e1184263f25bfabf3d27c383410470f169e4b8163bf9c17/beautifulsoup4-4.15.0-py3-none-any.whl',
        'sha256': 'd6f88de62e1d4e38ecb1077eb9724cd0eff29d2a08ca16a401e9b9e93f117cf9',
    },
    {
        'name': 'soupsieve',
        'version': '4.1.3',
        'filename': 'soupsieve-4.1.3-py3-none-any.whl',
        'url': 'https://files.pythonhosted.org/packages/f6/f7/be207468cac6ad79389f36cf1fce4f2836960df91659979ec486c727bb2e/soupsieve-4.1.3-py3-none-any.whl',
        'sha256': '7a390d1a57d1ab7bb228531e9b8a750a5ebf87db774e0ef6faeeac057d22a5bf',
    },
    {
        'name': 'typing-extensions',
        'version': '4.16.0',
        'filename': 'typing_extensions-4.16.0-py3-none-any.whl',
        'url': 'https://files.pythonhosted.org/packages/49/d3/b8441a820a491ddfc024b0b0cf0393375b75ea13866d9c66727e54c2fc80/typing_extensions-4.16.0-py3-none-any.whl',
        'sha256': '481caa481374e813c1b176ada14e97f1f67a4539ce9cfeb3f350d78d6370c2e8',
    },
    {
        'name': 'pyquery',
        'version': '2.1.0',
        'filename': 'pyquery-2.1.0-py3-none-any.whl',
        'url': 'https://files.pythonhosted.org/packages/2f/d2/5eab7f15bdb63c5281f625a003e999ef3f843c35972c936b07ea868cb854/pyquery-2.1.0-py3-none-any.whl',
        'sha256': '74c9e65ea0cfbcf644a8c3fd438a3dedbcbbd497b9cb366a4f360dba72f8aebb',
    },
    {
        'name': 'cssselect',
        'version': '1.6.0',
        'filename': 'cssselect-1.6.0-py3-none-any.whl',
        'url': 'https://files.pythonhosted.org/packages/08/ae/f24b3aac56ba91a29c9d3a31c07a9ad4e9eb500e5d212742bb6d348edaef/cssselect-1.6.0-py3-none-any.whl',
        'sha256': '6df6eab9b264c0f2092a6e386b33610e1684a25e27925ecebe25e3d97cbf3525',
    },
    {
        'name': 'pycryptodome',
        'version': '4.6.0',
        'filename': 'pycryptodome-4.6.0-cp39-abi3-win_amd64.whl',
        'url': 'https://files.pythonhosted.org/packages/f3/10/f375e028f5e3b10b4858010ffa391e66c7b61a410284bdc3e0f351edefc7/pycryptodome-4.6.0-cp39-abi3-win_amd64.whl',
        'sha256': '0500c66f8cc33db5450f24aedd10a6e430e4d83c377dbd8ca0e845ae27b4312f',
    },
    {
        'name': 'lxml',
        'version': '6.1.3',
        'filename': 'lxml-6.1.3-cp311-cp311-win_amd64.whl',
        'url': 'https://files.pythonhosted.org/packages/45/5a/15531a0d307c96282fe8b639b3d74e8bd783e4ab4cb2b0781146ac4161b8/lxml-6.1.3-cp311-cp311-win_amd64.whl',
        'sha256': '7ae4949f212a53b007dbc355884fda122545c5764a54256c9217e419a62a6559',
    },
)

SITECUSTOMIZE_CODE = """\"\"\"Site initialization for bundled Marco Movie Windows Python runtime.\"\"\"
import importlib
import importlib.abc
import importlib.util
import sys


class _CryptodomeAliasFinder(importlib.abc.MetaPathFinder):
    def find_spec(self, fullname, path=None, target=None):
        if fullname != "Cryptodome" and not fullname.startswith("Cryptodome."):
            return None
        mapped = "Crypto" + fullname[len("Cryptodome"):]
        try:
            real_mod = importlib.import_module(mapped)
        except Exception:
            return None
        sys.modules[fullname] = real_mod
        return importlib.util.spec_from_loader(
            fullname,
            _AliasLoader(real_mod),
            is_package=hasattr(real_mod, "__path__"),
        )


class _AliasLoader(importlib.abc.Loader):
    def __init__(self, mod):
        self._mod = mod

    def create_module(self, spec):
        return self._mod

    def exec_module(self, module):
        return None


if "Cryptodome" not in sys.modules:
    try:
        sys.modules["Cryptodome"] = importlib.import_module("Crypto")
        sys.meta_path.append(_CryptodomeAliasFinder())
    except Exception:
        pass
"""

VERIFY_SNIPPET = """
import json
import os
import sqlite3
import ssl
import sys
import bs4
import certifi
import lxml.etree as etree
import pyquery
import requests
from Crypto.Cipher import AES as CryptoAES
from Crypto.Util.Padding import pad, unpad
from Cryptodome.Cipher import AES as CryptodomeAES

assert sys.version_info[:2] == (3, 11), f"Unexpected Python version: {sys.version}"
poison = os.environ.get("MARCO_POISON_PYTHONPATH", "")
assert not poison or poison not in sys.path, f"Isolated sys.path leaked PYTHONPATH: {sys.path}"
assert os.path.isfile(certifi.where()), "Missing certifi CA bundle"
doc = etree.HTML("<html><body><div class='item'>ok</div></body></html>")
assert doc.xpath("//div[@class='item']/text()") == ["ok"]
assert pyquery.PyQuery("<div><span>hello</span></div>")("span").text() == "hello"
assert bs4.BeautifulSoup("<p>world</p>", "html.parser").p.text == "world"
key = b"0123456789abcdef"
iv = b"abcdef0123456789"
ct = CryptoAES.new(key, CryptoAES.MODE_CBC, iv).encrypt(pad(b"marco-win-py311", 16))
pt = unpad(CryptodomeAES.new(key, CryptodomeAES.MODE_CBC, iv).decrypt(ct), 16)
assert pt == b"marco-win-py311"
assert hasattr(requests, "Session")
assert sqlite3.sqlite_version
assert ssl.OPENSSL_VERSION
print(json.dumps({
    "python": sys.version.split()[0],
    "openssl": ssl.OPENSSL_VERSION,
    "sqlite": sqlite3.sqlite_version,
    "requests": requests.__version__,
    "lxml": etree.__version__,
}))
"""


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open('rb') as handle:
        while True:
            chunk = handle.read(65536)
            if not chunk:
                break
            digest.update(chunk)
    return digest.hexdigest()


def default_cache_dir() -> Path:
    override = os.environ.get('MARCOMOVIE_PYTHON_WIN_CACHE', '').strip()
    if override:
        return Path(override)
    return ROOT / 'tools' / 'python-win-cache'


def fetch_pinned_artifact(url: str, filename: str, expected_sha256: str, cache_dir: Path, downloader=None) -> Path:
    cache_dir.mkdir(parents=True, exist_ok=True)
    cached = cache_dir / filename
    if not cached.exists():
        partial = cached.with_suffix(cached.suffix + '.partial')
        if partial.exists():
            partial.unlink()
        if downloader is not None:
            downloader(url, partial)
        else:
            with urllib.request.urlopen(url, timeout=120) as response, partial.open('wb') as out:
                shutil.copyfileobj(response, out)
        partial.replace(cached)
    actual = sha256_file(cached)
    if actual.lower() != expected_sha256.lower():
        raise ValueError(f'SHA-256 mismatch for {filename}: expected {expected_sha256}, got {actual}')
    return cached


def _safe_extract_zip(archive_path: Path, target_dir: Path, *, wheel_mode: bool = False) -> None:
    target_root = target_dir.resolve()
    target_root.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(archive_path) as archive:
        for member in archive.infolist():
            rel_name = member.filename.replace('\\', '/')
            if wheel_mode and '.data/' in rel_name:
                _, _, tail = rel_name.partition('.data/')
                if tail.startswith('purelib/'):
                    rel_name = tail[len('purelib/'):]
                elif tail.startswith('platlib/'):
                    rel_name = tail[len('platlib/'):]
                else:
                    continue
            if not rel_name or rel_name.endswith('/'):
                dest = (target_root / rel_name).resolve()
                if not dest.is_relative_to(target_root):
                    raise ValueError(f'Unsafe archive directory path: {member.filename}')
                dest.mkdir(parents=True, exist_ok=True)
                continue
            dest = (target_root / rel_name).resolve()
            if not dest.is_relative_to(target_root):
                raise ValueError(f'Unsafe archive file path: {member.filename}')
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_bytes(archive.read(member))


def configure_embed_pth(destination: Path) -> Path:
    pth_path = destination / PYTHON_EMBED_PTH
    lines = [
        'python311.zip',
        '.',
        'Lib\\site-packages',
        'marco_host',
        'import site',
    ]
    pth_path.write_text('\n'.join(lines) + '\n', encoding='utf-8')
    return pth_path


def copy_host_scripts(destination: Path, host_source_dir: Path | None = None) -> Path:
    src_dir = host_source_dir or (ROOT / 'flutter' / 'assets' / 'python-host')
    runner_src = src_dir / 'desktop_runner.py'
    if not runner_src.is_file():
        raise FileNotFoundError(f'Missing desktop runner source: {runner_src}')
    host_dir = destination / 'marco_host'
    host_dir.mkdir(parents=True, exist_ok=True)
    for item in sorted(src_dir.glob('*.py')):
        shutil.copy2(item, host_dir / item.name)
    return host_dir


def prepare(
    destination: Path,
    *,
    cache_dir: Path | None = None,
    host_source_dir: Path | None = None,
    downloader=None,
) -> Path:
    destination = Path(destination)
    cache = Path(cache_dir) if cache_dir is not None else default_cache_dir()
    embed_zip = fetch_pinned_artifact(
        EMBED_RUNTIME['url'],
        EMBED_RUNTIME['filename'],
        EMBED_RUNTIME['sha256'],
        cache,
        downloader=downloader,
    )
    _safe_extract_zip(embed_zip, destination, wheel_mode=False)

    site_packages = destination / 'Lib' / 'site-packages'
    site_packages.mkdir(parents=True, exist_ok=True)
    for wheel in WHEELS:
        whl_path = fetch_pinned_artifact(
            wheel['url'],
            wheel['filename'],
            wheel['sha256'],
            cache,
            downloader=downloader,
        )
        _safe_extract_zip(whl_path, site_packages, wheel_mode=True)

    (site_packages / 'sitecustomize.py').write_text(SITECUSTOMIZE_CODE, encoding='utf-8')
    configure_embed_pth(destination)
    copy_host_scripts(destination, host_source_dir=host_source_dir)
    print(f'Prepared Windows Python {PYTHON_VERSION} runtime at {destination}')
    return destination


def verify_runtime(destination: Path) -> str:
    destination = Path(destination).resolve()
    python_exe = destination / 'python.exe'
    runner = destination / 'marco_host' / 'desktop_runner.py'
    if not python_exe.is_file():
        raise FileNotFoundError(f'Missing python.exe at {python_exe}')
    if not runner.is_file():
        raise FileNotFoundError(f'Missing desktop_runner.py at {runner}')

    env = dict(os.environ)
    poison_dir = str(destination / '_poison_pythonpath')
    env['PYTHONPATH'] = poison_dir
    env['MARCO_POISON_PYTHONPATH'] = poison_dir
    env['PYTHONUTF8'] = '1'
    result = subprocess.run(
        [str(python_exe), '-I', '-c', VERIFY_SNIPPET],
        cwd=str(destination),
        env=env,
        capture_output=True,
        text=True,
        encoding='utf-8',
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeError(
            f'Windows Python runtime self-check failed (exit {result.returncode}):\n'
            f'STDOUT: {result.stdout}\nSTDERR: {result.stderr}'
        )
    summary = result.stdout.strip()
    print(f'Verified Windows Python runtime: {summary}')
    return summary


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--destination', type=Path, required=True)
    parser.add_argument('--cache-dir', type=Path, default=None)
    parser.add_argument('--verify', action='store_true')
    args = parser.parse_args(argv)
    prepare(args.destination, cache_dir=args.cache_dir)
    if args.verify:
        verify_runtime(args.destination)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
