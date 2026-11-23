# Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
"""Compile and run standalone Android onboarding & first-play hint JVM checks."""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
JDK = os.environ.get("MARCOMOVIE_JDK") or os.environ.get("JAVA_HOME")


def tool(name: str) -> str:
    if JDK:
        return str(Path(JDK) / "bin" / (name + ".exe" if os.name == "nt" else name))
    return shutil.which(name) or name


def find_android_jar() -> Path:
    env_jar = os.environ.get("MARCOMOVIE_ANDROID_JAR")
    if env_jar and Path(env_jar).is_file():
        return Path(env_jar)
    for base_env in ("ANDROID_HOME", "ANDROID_SDK_ROOT"):
        base = os.environ.get(base_env)
        if base:
            candidates = sorted((Path(base) / "platforms").glob("android-*/android.jar"))
            if candidates:
                return candidates[-1]
    raise SystemExit("Set MARCOMOVIE_ANDROID_JAR to a valid android.jar")


def main() -> int:
    android_jar = find_android_jar()
    out = ROOT / "android-mobile" / "build" / "onboarding-check"
    out.mkdir(parents=True, exist_ok=True)

    aosp_json_dir = ROOT / "android-mobile" / "tests" / "lib" / "aosp-json"
    aosp_sources = sorted((aosp_json_dir / "src").rglob("*.java")) + sorted(
        (aosp_json_dir / "annotations").rglob("*.java")
    )
    app_sources = [
        ROOT / "android-mobile/src/main/java/com/pilipala/marcomovie/UiCompat.java",
        ROOT / "android-mobile/src/main/java/com/pilipala/marcomovie/OnboardingScreen.java",
        ROOT / "android-mobile/src/main/java/com/pilipala/marcomovie/FirstPlayGestureHint.java",
        ROOT / "android-mobile/tests/OnboardingStateChecks.java",
    ]

    # Compile aosp-json first so JVM runtime uses real org.json instead of android.jar stubs.
    subprocess.run(
        [
            tool("javac"),
            "-encoding",
            "UTF-8",
            "-source",
            "8",
            "-target",
            "8",
            "-Xlint:-options",
            "-d",
            str(out),
            *[str(p) for p in aosp_sources],
        ],
        check=True,
    )

    # Compile onboarding classes against android.jar + compiled aosp-json.
    subprocess.run(
        [
            tool("javac"),
            "-encoding",
            "UTF-8",
            "-source",
            "8",
            "-target",
            "8",
            "-Xlint:-options",
            "-cp",
            f"{out}{os.pathsep}{android_jar}",
            "-d",
            str(out),
            *[str(p) for p in app_sources],
        ],
        check=True,
    )

    manifest = ROOT / "android-mobile/src/main/assets/demo/manifest.json"
    subprocess.run(
        [
            tool("java"),
            "-cp",
            f"{out}{os.pathsep}{android_jar}",
            "com.pilipala.marcomovie.OnboardingStateChecks",
            str(manifest),
        ],
        check=True,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
