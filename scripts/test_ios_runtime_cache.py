"""Behavior checks for native-stage reuse without compiling or downloading."""
import json
from pathlib import Path
import shutil
import tempfile
import unittest

from scripts import ios_runtime_cache as cache


class IosRuntimeCacheChecks(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        original = cache.load_runtime()
        # Use the real staging input inventory in an isolated checkout. This
        # checks actual source_inputs behavior rather than a copied path list.
        for name in original.source_inputs():
            destination = self.root / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(cache.ROOT / name, destination)
        self.runtime = cache.load_runtime(self.root)
        self.toolchain = {"runner_arch": "x86_64", "sdk": "iphoneos",
                          "xcode": "Xcode 16.4\nBuild version 16F6",
                          "sdk_version": "18.5", "sdk_build": "22F76"}

    def key(self, **changes):
        return cache.cache_key(self.runtime.source_inputs(), target=changes.get("target", "device"),
                               arch=changes.get("arch", "arm64"), toolchain=changes.get("toolchain", self.toolchain))

    def make_stage(self):
        stage = self.root / cache.STAGE_RELATIVE
        binary = stage / "bundle/Frameworks/example.framework/example"
        binary.parent.mkdir(parents=True)
        binary.write_bytes(b"synthetic native binary")
        report = {"runtime": {"target": "device", "architecture": "arm64"},
                  "inputs": self.runtime.source_inputs(), "files": self.runtime.files_digest(stage / "bundle")}
        (stage / "prepared.json").write_text(json.dumps(report), encoding="utf-8")
        return stage, binary

    def test_real_native_and_python_source_changes_invalidate_key(self):
        for relative in ("scripts/ios_lxml/native_callbacks.h",
                         "scripts/ios_cpython_crypto/ios_loader.py",
                         "android/src/main/assets/python-native/host.py"):
            with self.subTest(input=relative):
                before = self.key()
                path = self.root / relative
                path.write_bytes(path.read_bytes() + b"\n# changed cache input\n")
                self.assertNotEqual(before, self.key())

    def test_unrelated_dart_drpy_and_html_changes_preserve_key(self):
        before = self.key()
        for relative in ("flutter/src/ui/netdisk_sheet.dart", "shared/catpaw/drpy-http.cjs",
                         "android/src/main/assets/python-host/parser-provenance.json"):
            path = self.root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("unrelated edit", encoding="utf-8")
        self.assertEqual(before, self.key())

    def test_toolchain_and_target_slices_are_isolated(self):
        before = self.key()
        for field, value in (("xcode", "Xcode other build"), ("sdk_version", "18.6"),
                             ("sdk_build", "22F77"), ("runner_arch", "arm64")):
            with self.subTest(toolchain=field):
                self.assertNotEqual(before, self.key(toolchain={**self.toolchain, field: value}))
        simulator = self.key(target="simulator")
        self.assertNotEqual(before, simulator)
        self.assertNotEqual(simulator, self.key(target="simulator", arch="x86_64"))

    def test_valid_stage_reuses_real_verifier_and_tampered_file_rebuilds(self):
        stage, binary = self.make_stage()
        self.assertTrue(cache.validate_stage(stage, target="device", arch="arm64", runtime=self.runtime))
        binary.write_bytes(b"altered cached binary")
        neighbor = stage.parent / "unrelated-build.txt"
        neighbor.write_text("preserve", encoding="utf-8")
        self.assertFalse(cache.validate_stage(stage, target="device", arch="arm64", runtime=self.runtime))
        self.assertFalse(stage.exists())
        self.assertEqual(neighbor.read_text(), "preserve")

    def test_source_mismatch_and_wrong_arch_rebuild(self):
        stage, _ = self.make_stage()
        source = self.root / "scripts/ios_lxml/owner_state.h"
        source.write_bytes(source.read_bytes() + b"\n")
        self.assertFalse(cache.validate_stage(stage, target="device", arch="arm64", runtime=self.runtime))
        stage, _ = self.make_stage()
        self.assertFalse(cache.validate_stage(stage, target="simulator", arch="x86_64", runtime=self.runtime))

    def test_cleanup_refuses_any_other_directory(self):
        other = self.root / "flutter/build/other"
        other.mkdir(parents=True)
        with self.assertRaisesRegex(ValueError, "stage location"):
            cache.validate_stage(other, target="device", arch="arm64", runtime=self.runtime)
        self.assertTrue(other.exists())


if __name__ == "__main__":
    unittest.main()
