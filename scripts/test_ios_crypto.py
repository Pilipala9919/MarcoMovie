"""Check archive plans and framework lookup; Apple execution is a separate gate."""
import importlib.util
import json
from pathlib import Path
import shutil
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('ios_crypto_build', ROOT / 'scripts/ios_cpython_crypto/build.py')
builder = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(builder)


class CryptoStagingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def load_mapper(self, mapping):
        utility = self.root / 'Runner.app/app_packages/Crypto/Util'
        utility.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT / 'scripts/ios_cpython_crypto/ios_loader.py', utility / '_ios_loader.py')
        (utility / '_ios_modules.json').write_text(json.dumps(mapping))
        spec = importlib.util.spec_from_file_location('owned_crypto_loader', utility / '_ios_loader.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def test_exact_framework_and_declaration_are_forwarded(self):
        name = 'Crypto.Cipher._raw_aes'
        relative = 'Frameworks/' + name + '.framework/' + name
        path = self.root / 'Runner.app' / relative
        path.parent.mkdir(parents=True)
        path.write_bytes(b'owned placeholder, not a Mach-O')
        loader = self.load_mapper({name: relative})
        self.assertEqual(loader.load_native(name, 'int owned();', lambda *args: args), (str(path.resolve()), 'int owned();'))
        with self.assertRaisesRegex(OSError, 'not bundled'):
            loader.load_native('Crypto.Cipher._raw_aesni', '', lambda *_: self.fail())

    def test_mapping_cannot_escape_or_substitute_other_library(self):
        name = 'Crypto.Cipher._raw_aes'
        for path in ('../outside', 'Frameworks/Other.framework/Other', 'app_packages/arbitrary.so'):
            loader = self.load_mapper({name: path})
            with self.assertRaisesRegex(OSError, 'Invalid bundled'):
                loader.load_native(name, '', lambda *_: self.fail())

    def test_source_checksum_precedes_extraction(self):
        archive = self.root / 'bad.tar.gz'
        archive.write_bytes(b'not the pinned archive')
        with self.assertRaisesRegex(ValueError, 'checksum'):
            builder.extract(archive, self.root / 'out')
        self.assertFalse((self.root / 'out').exists())

    def test_plan_rejects_dynamic_or_incomplete_extension_metadata(self):
        for code in ('ext_modules = get_extensions()', 'ext_modules = []'):
            (self.root / 'setup.py').write_text(code)
            with self.assertRaises(ValueError):
                builder.build_plan(self.root)


if __name__ == '__main__':
    unittest.main()
