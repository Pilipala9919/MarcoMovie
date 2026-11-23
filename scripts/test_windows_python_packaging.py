"""Unit tests for pinned Windows Python 3.11 runtime packaging and SHA-256 integrity."""
from __future__ import annotations

import hashlib
from pathlib import Path
import re
import sys
import tempfile
import unittest
from unittest import mock
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import prepare_windows_python_runtime as pwpr


def _make_zip(path: Path, entries: dict[str, bytes]) -> str:
    with zipfile.ZipFile(path, 'w') as zf:
        for name, data in entries.items():
            zf.writestr(name, data)
    return hashlib.sha256(path.read_bytes()).hexdigest()


class WindowsPythonPackagingTests(unittest.TestCase):
    def test_manifest_pins_expected_runtime_and_11_target_packages(self):
        self.assertTrue(pwpr.EMBED_RUNTIME['version'].startswith('3.11.'))
        self.assertEqual(pwpr.EMBED_RUNTIME['license'], 'PSF-2.0')
        self.assertTrue(pwpr.EMBED_RUNTIME['url'].startswith('https://www.python.org/ftp/python/3.11.'))
        self.assertRegex(pwpr.EMBED_RUNTIME['sha256'], r'^[0-9a-f]{64}$')

        expected_packages = {
            'requests',
            'urllib3',
            'certifi',
            'idna',
            'charset-normalizer',
            'beautifulsoup4',
            'soupsieve',
            'pyquery',
            'cssselect',
            'pycryptodome',
            'lxml',
        }
        names = {item['name'] for item in pwpr.WHEELS}
        self.assertTrue(expected_packages.issubset(names))
        for wheel in pwpr.WHEELS:
            self.assertTrue(wheel['url'].startswith('https://files.pythonhosted.org/'), wheel['name'])
            self.assertRegex(wheel['sha256'], r'^[0-9a-f]{64}$', wheel['name'])
            self.assertTrue(
                wheel['filename'].endswith('.whl') and (
                    'py3-none-any' in wheel['filename'] or 'win_amd64' in wheel['filename']
                ),
                wheel['filename'],
            )
            if wheel['name'] == 'lxml':
                self.assertIn('cp311-cp311-win_amd64', wheel['filename'])

    def test_sha256_mismatch_rejects_tampered_download_and_cached_artifact(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            cache = root / 'cache'
            expected_sha = 'a' * 64

            def tampered_downloader(_url: str, partial_path: Path):
                partial_path.write_bytes(b'corrupted-payload')

            with self.assertRaisesRegex(ValueError, 'SHA-256 mismatch'):
                pwpr.fetch_pinned_artifact(
                    'https://files.pythonhosted.org/fake.whl',
                    'fake.whl',
                    expected_sha,
                    cache,
                    downloader=tampered_downloader,
                )
            self.assertFalse((cache / 'fake.whl.partial').exists())
            self.assertTrue((cache / 'fake.whl').exists())

            # Second access with tampered cached file must still reject!
            with self.assertRaisesRegex(ValueError, 'SHA-256 mismatch'):
                pwpr.fetch_pinned_artifact(
                    'https://files.pythonhosted.org/fake.whl',
                    'fake.whl',
                    expected_sha,
                    cache,
                    downloader=lambda *_args: self.fail('Should not redownload over tampered cache'),
                )

    def test_prepare_rewrites_pth_extracts_wheels_caches_and_copies_marco_host(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            fixtures = root / 'fixtures'
            fixtures.mkdir()
            cache = root / 'cache'
            dest1 = root / 'out1'
            dest2 = root / 'out2'
            host_src = root / 'host_src'
            host_src.mkdir()
            (host_src / 'desktop_runner.py').write_text('# runner stub\n', encoding='utf-8')
            (host_src / 'helper_shim.py').write_text('# helper stub\n', encoding='utf-8')

            embed_zip = fixtures / 'python-3.11.9-embed-amd64.zip'
            embed_sha = _make_zip(embed_zip, {
                'python.exe': b'MZ-stub',
                'python311.zip': b'PK-stub',
                'python311._pth': b'python311.zip\n.\n#import site\n',
            })

            wheel_zip = fixtures / 'sample-1.0.0-py3-none-any.whl'
            wheel_sha = _make_zip(wheel_zip, {
                'sample/__init__.py': b'VALUE = 1\n',
                'sample-1.0.0.data/purelib/sample_extra.py': b'EXTRA = 2\n',
            })

            embed_meta = {
                'name': 'python-embed-amd64',
                'version': '3.11.9',
                'filename': embed_zip.name,
                'url': 'https://www.python.org/ftp/python/3.11.9/python-3.11.9-embed-amd64.zip',
                'sha256': embed_sha,
                'license': 'PSF-2.0',
            }
            wheels_meta = (
                {
                    'name': 'sample',
                    'version': '1.0.0',
                    'filename': wheel_zip.name,
                    'url': 'https://files.pythonhosted.org/sample-1.0.0-py3-none-any.whl',
                    'sha256': wheel_sha,
                },
            )

            downloads = []

            def fake_downloader(url: str, partial_path: Path):
                downloads.append(url)
                src = embed_zip if url.endswith('.zip') else wheel_zip
                partial_path.write_bytes(src.read_bytes())

            with mock.patch.object(pwpr, 'EMBED_RUNTIME', embed_meta), mock.patch.object(pwpr, 'WHEELS', wheels_meta):
                pwpr.prepare(dest1, cache_dir=cache, host_source_dir=host_src, downloader=fake_downloader)
                self.assertEqual(len(downloads), 2)

                # Repeat build into dest2 must hit local cache without downloading.
                pwpr.prepare(
                    dest2,
                    cache_dir=cache,
                    host_source_dir=host_src,
                    downloader=lambda u, _p: self.fail(f'Unexpected network download on cache hit: {u}'),
                )

            for out in (dest1, dest2):
                pth = (out / 'python311._pth').read_text(encoding='utf-8').splitlines()
                self.assertEqual(
                    pth,
                    ['python311.zip', '.', 'Lib\\site-packages', 'marco_host', 'import site'],
                )
                self.assertTrue((out / 'Lib/site-packages/sample/__init__.py').is_file())
                self.assertTrue((out / 'Lib/site-packages/sample_extra.py').is_file())
                self.assertTrue((out / 'Lib/site-packages/sitecustomize.py').is_file())
                self.assertEqual(
                    (out / 'marco_host/desktop_runner.py').read_text(encoding='utf-8'),
                    '# runner stub\n',
                )
                self.assertEqual(
                    (out / 'marco_host/helper_shim.py').read_text(encoding='utf-8'),
                    '# helper stub\n',
                )

    def test_unsafe_archive_path_traversal_is_blocked(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            evil_zip = root / 'evil.zip'
            target = root / 'target'
            with zipfile.ZipFile(evil_zip, 'w') as zf:
                zf.writestr('../../escaped.txt', b'pwned')
            with self.assertRaisesRegex(ValueError, 'Unsafe archive file path'):
                pwpr._safe_extract_zip(evil_zip, target)
            self.assertFalse((root / 'escaped.txt').exists())

    def test_verify_runtime_requires_python_and_runner(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(FileNotFoundError):
                pwpr.verify_runtime(Path(tmp))


if __name__ == '__main__':
    unittest.main()
