#!/usr/bin/env python3
"""Synchronize or verify README version numbers against per-platform edition-versions.json."""
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]


def _read_edition(path: Path, key: str) -> str | None:
    if not path.exists():
        return None
    data = json.loads(path.read_text(encoding="utf-8"))
    return data.get(key, {}).get("versionName")


def build_expected_version_line(root: Path = ROOT) -> str:
    flutter_file = root / "flutter/edition-versions.json"
    if not flutter_file.exists():
        raise FileNotFoundError(f"Missing {flutter_file}")

    mobile = _read_edition(root / "android-mobile/edition-versions.json", "android-mobile")
    tv = _read_edition(root / "android-tv/edition-versions.json", "android-tv")
    lite = _read_edition(root / "lite/edition-versions.json", "android-lite")

    flutter_data = json.loads(flutter_file.read_text(encoding="utf-8"))

    windows = flutter_data.get("windows", {}).get("versionName")
    macos = flutter_data.get("macos", {}).get("versionName")
    ios = flutter_data.get("ios", {}).get("versionName")
    appletv = flutter_data.get("appletv", {}).get("versionName")
    harmonyos = flutter_data.get("harmonyos", {}).get("versionName")

    for name, val in [("android-mobile", mobile), ("android-tv", tv), ("android-lite", lite),
                      ("windows", windows), ("macos", macos), ("ios", ios),
                      ("appletv", appletv), ("harmonyos", harmonyos)]:
        if not val:
            raise ValueError(f"Missing versionName for {name}")

    return (
        f"  <p>作者：<a href=\"https://github.com/Pilipala9919\">Pilipala</a> · "
        f"Android 手机：{mobile} · Android 电视：{tv} · Android Lite：{lite} · "
        f"Windows：{windows} · macOS：{macos} · iOS：{ios} · "
        f"Apple TV：{appletv} · HarmonyOS NEXT：{harmonyos} · 各端独立更新</p>"
    )


def sync_readme(root: Path = ROOT, check_only: bool = False) -> int:
    readme_path = root / "README.md"
    if not readme_path.exists():
        raise FileNotFoundError(f"Missing {readme_path}")

    content = readme_path.read_text(encoding="utf-8")
    expected_line = build_expected_version_line(root)

    pattern = re.compile(r"^\s*<p>作者：<a href=\"https://github\.com/Pilipala9919\">Pilipala</a> · .*?各端独立更新</p>$", re.MULTILINE)
    match = pattern.search(content)

    if not match:
        print("ERROR: Version paragraph not found in README.md", file=sys.stderr)
        return 1

    current_line = match.group(0)

    if check_only:
        if current_line == expected_line:
            print("PASS README.md version numbers match edition-versions.json")
            return 0
        else:
            print("FAIL README.md version mismatch:", file=sys.stderr)
            print(f"  Current:  {current_line}", file=sys.stderr)
            print(f"  Expected: {expected_line}", file=sys.stderr)
            return 1

    if current_line != expected_line:
        new_content = pattern.sub(expected_line, content, count=1)
        readme_path.write_text(new_content, encoding="utf-8")
        print(f"Updated README.md line:\n  {expected_line}")
    else:
        print("README.md is already up-to-date.")
    return 0


def main() -> None:
    check_only = "--check" in sys.argv
    code = sync_readme(ROOT, check_only=check_only)
    sys.exit(code)


if __name__ == "__main__":
    main()
