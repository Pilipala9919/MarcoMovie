"""Offline JVM verification for Android TV 0.6.1 feedback fixes."""

from pathlib import Path
import os
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
from android_compile_support import SUFFIX, compile_real_android_sources, resolve_jdk_bin

ROOT = Path(__file__).resolve().parents[2]
JDK = resolve_jdk_bin()

with tempfile.TemporaryDirectory(prefix="tv-061-feedback-checks-") as tmp:
    work_dir = Path(tmp)
    classes_dir = work_dir / "classes"
    runtime_cp = compile_real_android_sources(
        classes_dir=classes_dir,
        work_dir=work_dir,
        test_sources=[ROOT / "android-tv/tests/Tv061FeedbackChecks.java"],
    )
    subprocess.run(
        [
            str(JDK / ("java" + SUFFIX)),
            "-Dfile.encoding=UTF-8",
            "-Dsun.net.http.allowRestrictedHeaders=true",
            "-cp",
            os.pathsep.join(str(p) for p in runtime_cp),
            "com.pilipala.marcomovie.Tv061FeedbackChecks",
        ],
        cwd=ROOT,
        check=True,
    )
