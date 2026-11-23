"""Compile real Android Java sources and check the local TV marker transaction on the JVM."""

from pathlib import Path
import os
import subprocess
import tempfile

from android_compile_support import SUFFIX, compile_real_android_sources, resolve_jdk_bin

ROOT = Path(__file__).resolve().parents[2]

with tempfile.TemporaryDirectory(prefix="tv-v17-marker-checks-") as tmp:
    work = Path(tmp)
    runtime_cp = compile_real_android_sources(
        classes_dir=work / "classes",
        work_dir=work,
        test_sources=[ROOT / "android-tv/tests/TvV17MarkerChecks.java"],
    )
    subprocess.run(
        [
            str(resolve_jdk_bin() / ("java" + SUFFIX)),
            "-Dfile.encoding=UTF-8",
            "-cp",
            os.pathsep.join(str(path) for path in runtime_cp),
            "com.pilipala.marcomovie.TvV17MarkerChecks",
        ],
        cwd=ROOT,
        check=True,
    )
