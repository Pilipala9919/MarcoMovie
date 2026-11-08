"""Exercise staging integrity and embedding boundaries without Apple tooling."""
import importlib.util
import json
from pathlib import Path
import plistlib
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("ios_python_packaging", Path(__file__).with_name("prepare_ios_python_runtime.py"))
package = importlib.util.module_from_spec(spec)
spec.loader.exec_module(package)


class PackagingTests(unittest.TestCase):
    def test_input_manifest_paths_are_canonical_repository_paths(self):
        for name in package.source_inputs():
            self.assertNotIn('..', Path(name).parts)
            self.assertFalse(Path(name).is_absolute())

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.stage = self.root / "stage"
        for name in ("python", "app", "app_packages", "Frameworks/Python.framework/Headers"):
            (self.stage / "bundle" / name).mkdir(parents=True, exist_ok=True)
        (self.stage / "bundle/app/native_source_entry.py").write_text("owned = True\n")
        (self.stage / "bundle/Frameworks/Python.framework/Headers/Python.h").write_text("header")
        self.crypto_binary = self.stage / "bundle/Frameworks/Crypto.Cipher._raw_aes.framework/Crypto.Cipher._raw_aes"
        self.crypto_binary.parent.mkdir(parents=True)
        self.crypto_binary.write_bytes(b"owned crypto test artifact")
        crypto_package = self.stage / "bundle/app_packages/Crypto"
        crypto_package.mkdir(parents=True)
        (crypto_package / "LICENSE.rst").write_text("owned license fixture")
        self.report = {"inputs": package.source_inputs(), "files": package.files_digest(self.stage / "bundle")}
        (self.stage / "prepared.json").write_text(json.dumps(self.report))
        self.app = self.root / "Runner.app"
        self.app.mkdir()
        (self.app / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "test.product"}))
        (self.app / "Runner").write_bytes(b"owned-application")

    def test_embedding_preserves_application_and_removes_headers(self):
        before = (self.app / "Info.plist").read_bytes()
        package.embed(self.stage, self.app)
        self.assertEqual((self.app / "Info.plist").read_bytes(), before)
        self.assertEqual((self.app / "Runner").read_bytes(), b"owned-application")
        self.assertTrue((self.app / "app/native_source_entry.py").exists())
        self.assertFalse((self.app / "Frameworks/Python.framework/Headers").exists())
        self.assertEqual((self.app / self.crypto_binary.relative_to(self.stage / "bundle")).read_bytes(), self.crypto_binary.read_bytes())
        self.assertEqual((self.app / "app_packages/Crypto/LICENSE.rst").read_text(), "owned license fixture")

    def test_missing_crypto_framework_cannot_produce_a_partial_package(self):
        self.crypto_binary.unlink()
        with self.assertRaisesRegex(ValueError, "stage changed"):
            package.embed(self.stage, self.app)
        self.assertFalse((self.app / "app_packages").exists())

    def test_changed_or_extra_staged_file_is_not_embedded(self):
        for filename in ("app/native_source_entry.py", "app/injected.py"):
            (self.stage / "bundle" / filename).write_text("changed")
            with self.assertRaisesRegex(ValueError, "stage changed"):
                package.embed(self.stage, self.app)
        self.assertFalse((self.app / "app").exists())

    def test_existing_link_framework_cannot_be_silently_replaced(self):
        destination = self.root / "link"
        package.copy_framework(self.stage, destination)
        package.copy_framework(self.stage, destination)
        (destination / "Python.framework/Headers/Python.h").write_text("changed")
        with self.assertRaisesRegex(ValueError, "differs"):
            package.copy_framework(self.stage, destination)

    def test_embedding_requires_actual_app_metadata(self):
        with self.assertRaisesRegex(ValueError, "built iOS application"):
            package.embed(self.stage, self.root / "not-an-app")


if __name__ == "__main__":
    unittest.main()
