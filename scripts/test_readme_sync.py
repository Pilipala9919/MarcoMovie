#!/usr/bin/env python3
"""Unit tests for scripts/sync_readme_versions.py."""
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
from sync_readme_versions import build_expected_version_line, sync_readme


class TestReadmeSync(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.root = Path(self.temp_dir.name)

        (self.root / "android-tv").mkdir(parents=True, exist_ok=True)
        (self.root / "android-mobile").mkdir(parents=True, exist_ok=True)
        (self.root / "lite").mkdir(parents=True, exist_ok=True)
        (self.root / "flutter").mkdir(parents=True, exist_ok=True)

        (self.root / "android-tv/edition-versions.json").write_text(
            json.dumps({"android-tv": {"versionName": "0.5.22", "versionCode": 81}}, indent=2), encoding="utf-8"
        )
        (self.root / "android-mobile/edition-versions.json").write_text(
            json.dumps({"android-mobile": {"versionName": "0.5.22", "versionCode": 82}}, indent=2), encoding="utf-8"
        )
        (self.root / "lite/edition-versions.json").write_text(
            json.dumps({"android-lite": {"versionName": "0.5.4", "versionCode": 54}}, indent=2), encoding="utf-8"
        )

        self.flutter_versions = {
            "windows": {"versionName": "0.5.18", "buildNumber": 68},
            "macos": {"versionName": "0.5.15", "buildNumber": 65},
            "ios": {"versionName": "0.5.25", "buildNumber": 75},
            "appletv": {"versionName": "0.1.0", "buildNumber": 1},
            "harmonyos": {"versionName": "0.1.0", "buildNumber": 1000001},
        }
        (self.root / "flutter/edition-versions.json").write_text(
            json.dumps(self.flutter_versions, indent=2), encoding="utf-8"
        )

        self.stale_readme = (
            "<div align=\"center\">\n"
            "  <p>支持 Android 电视、手机、平板，HarmonyOS NEXT（手机 / 平板 / 智慧屏），Apple TV（tvOS）及 Windows / macOS / iOS 多端自适应的播放器。</p>\n"
            "  <p>作者：<a href=\"https://github.com/Pilipala9919\">Pilipala</a> · Android 手机：0.5.21 · Android 电视：0.5.21 · Android Lite：0.5.4 · Windows：0.5.17 · macOS：0.5.14 · iOS：0.5.24 · 各端独立更新</p>\n"
            "</div>\n"
        )
        (self.root / "README.md").write_text(self.stale_readme, encoding="utf-8")

    def tearDown(self):
        self.temp_dir.cleanup()

    def test_build_expected_version_line(self):
        line = build_expected_version_line(self.root)
        self.assertIn("Android 手机：0.5.22", line)
        self.assertIn("Android 电视：0.5.22", line)
        self.assertIn("Android Lite：0.5.4", line)
        self.assertIn("Windows：0.5.18", line)
        self.assertIn("macOS：0.5.15", line)
        self.assertIn("iOS：0.5.25", line)
        self.assertIn("Apple TV：0.1.0", line)
        self.assertIn("HarmonyOS NEXT：0.1.0", line)

    def test_check_fails_on_stale_readme(self):
        code = sync_readme(self.root, check_only=True)
        self.assertEqual(code, 1)

    def test_sync_updates_readme_and_check_passes(self):
        code = sync_readme(self.root, check_only=False)
        self.assertEqual(code, 0)

        # Content must now have 0.5.22, 0.5.18, etc.
        content = (self.root / "README.md").read_text(encoding="utf-8")
        self.assertIn("Android 手机：0.5.22", content)
        self.assertIn("Windows：0.5.18", content)

        # --check should now pass
        check_code = sync_readme(self.root, check_only=True)
        self.assertEqual(check_code, 0)


if __name__ == "__main__":
    unittest.main()
