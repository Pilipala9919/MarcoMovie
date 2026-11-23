"""Compile real sources and run localhost search pagination/revocation tests. No ADB."""
from pathlib import Path
import os
import subprocess
import tempfile
from android_compile_support import SUFFIX, compile_real_android_sources, resolve_jdk_bin

ROOT = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix="tv-search-host-") as tmp:
    work = Path(tmp)
    cp = compile_real_android_sources(classes_dir=work / "classes", work_dir=work,
        test_sources=[ROOT / "android-tv/tests/TvSearchHostChecks.java", ROOT / "android-tv/tests/TvRouteHostChecks.java"])
    for name in ["TvSearchHostChecks", "TvRouteHostChecks"]:
        subprocess.run([str(resolve_jdk_bin() / ("java" + SUFFIX)), "-Dfile.encoding=UTF-8",
            "-cp", os.pathsep.join(map(str, cp)), "com.pilipala.marcomovie." + name],
            cwd=ROOT, check=True)
