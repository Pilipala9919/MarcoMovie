"""Offline JVM checks for CloudSync v2 (WebDAV, LAN sync, tombstones, and MainActivity restart history checks)."""

from pathlib import Path
import os
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
from android_compile_support import SUFFIX, compile_real_android_sources, resolve_jdk_bin

ROOT = Path(__file__).resolve().parents[2]
JDK = resolve_jdk_bin()

with tempfile.TemporaryDirectory(prefix="cloud-sync-checks-") as tmp:
    work_dir = Path(tmp)
    classes_dir = work_dir / "classes"
    runtime_cp = compile_real_android_sources(
        classes_dir=classes_dir,
        work_dir=work_dir,
        test_sources=[ROOT / "android-mobile/tests/CloudSyncChecks.java"],
    )
    subprocess.run(
        [
            str(JDK / ("java" + SUFFIX)),
            "-Dfile.encoding=UTF-8",
            "-cp",
            os.pathsep.join(str(p) for p in runtime_cp),
            "com.pilipala.marcomovie.CloudSyncChecks",
        ],
        cwd=ROOT,
        check=True,
    )
