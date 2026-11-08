"""Exercise staging integrity and embedding boundaries without Apple tooling."""
import importlib.util
import json
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch

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
        self.lxml_files = {
            "Frameworks/MarcoLxmlNative.framework/MarcoLxmlNative": b"owned private XML artifact",
            "app_packages/lxml/__init__.py": b"# owned package fixture\n",
            "app_packages/lxml/LICENSE.txt": b"owned lxml license",
            "app_packages/lxml/licenses/libxml2-Copyright.txt": b"owned XML license",
            "app_packages/lxml/licenses/libxslt-Copyright.txt": b"owned XSLT license",
        }
        for module in ("etree", "objectify"):
            binary = "Frameworks/lxml." + module + ".framework/lxml." + module
            marker = "app_packages/lxml/" + module + ".fwork"
            self.lxml_files[binary] = ("owned " + module + " artifact").encode()
            self.lxml_files[marker] = (binary + "\n").encode()
            self.lxml_files[binary + ".origin"] = (marker + "\n").encode()
        for name, data in self.lxml_files.items():
            path = self.stage / "bundle" / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        self.lxml_report = {"private_native_framework": "MarcoLxmlNative", "target": "simulator", "architecture": "arm64",
                            "product_enabled": False, "runtime_tested": False, "physical_device_tested": False}
        self.report = {"inputs": package.source_inputs(), "files": package.files_digest(self.stage / "bundle"),
                       "runtime": {"lxml": self.lxml_report}}
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
        for name, data in self.lxml_files.items():
            self.assertEqual((self.app / name).read_bytes(), data)
        embedded = json.loads((self.app / "python-runtime-manifest.json").read_text())
        self.assertEqual(embedded["runtime"]["lxml"], self.lxml_report)

    def test_prepare_stages_lxml_and_reuses_integrity_checked_cache(self):
        stage = self.root / "new-stage"
        frameworks = self.root / "link"
        cache = self.root / "cache"

        def stage_python(bundle, target, arch, _cache, **_kwargs):
            for name in ("python", "app", "app_packages", "Frameworks/Python.framework/Headers"):
                (bundle / name).mkdir(parents=True)
            (bundle / "Frameworks/Python.framework/Headers/Python.h").write_text("header")
            return {"target": target, "architecture": arch}

        def stage_lxml(bundle, _cache, **_kwargs):
            self.assertTrue((bundle / "Frameworks/Python.framework/Headers/Python.h").is_file())
            for name, data in self.lxml_files.items():
                path = bundle / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(data)
            return self.lxml_report

        with patch.object(package.native, "stage", side_effect=stage_python), \
             patch.object(package.crypto, "stage", return_value={}), \
             patch.object(package.lxml, "stage", side_effect=stage_lxml) as build:
            first = package.prepare(stage, frameworks, cache, "simulator", "arm64")
            self.assertEqual(first["runtime"]["lxml"], self.lxml_report)
            self.assertIs(first["runtime"]["lxml"]["product_enabled"], True)
            self.assertIs(first["runtime"]["lxml"]["runtime_tested"], False)
            self.assertIs(first["runtime"]["lxml"]["physical_device_tested"], False)
            self.assertEqual(package.prepare(stage, frameworks, cache, "simulator", "arm64"), first)
            build.assert_called_once_with(stage / "bundle", cache, target="simulator", arch="arm64",
                                          identifier="com.pilipala.marcomovie.lxml", log_dir=stage / "lxml-logs")

    def test_missing_or_changed_lxml_files_cannot_produce_a_partial_package(self):
        for name, data in self.lxml_files.items():
            path = self.stage / "bundle" / name
            for changed in (False, True):
                with self.subTest(file=name, changed=changed):
                    if changed:
                        path.write_bytes(data + b"changed")
                    else:
                        path.unlink()
                    with self.assertRaisesRegex(ValueError, "stage changed"):
                        package.embed(self.stage, self.app)
                    self.assertFalse((self.app / "app_packages").exists())
                    self.assertFalse((self.app / "Frameworks").exists())
                    path.write_bytes(data)

    def test_changed_lxml_build_input_invalidates_cached_stage(self):
        inputs = package.lxml.source_inputs()
        inputs["scripts/ios_lxml/owner_state.h"] = "changed-owner-input"
        with patch.object(package.lxml, "source_inputs", return_value=inputs):
            with self.assertRaisesRegex(ValueError, "stage changed"):
                package.embed(self.stage, self.app)
        self.assertFalse((self.app / "app_packages").exists())

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
