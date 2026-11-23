"""Pure-JVM offline verification suite for all 9 Android TV 0.6.3 optimizations."""

from pathlib import Path
import os
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(Path(__file__).resolve().parent))
from android_compile_support import SUFFIX, compile_real_android_sources, resolve_jdk_bin


def main() -> int:
    jdk_bin = resolve_jdk_bin()
    with tempfile.TemporaryDirectory(prefix="tv-063-opt-checks-") as tmp:
        work_dir = Path(tmp)
        classes_dir = work_dir / "classes"
        runtime_cp = compile_real_android_sources(
            classes_dir=classes_dir,
            work_dir=work_dir,
            test_sources=[ROOT / "android-tv/tests/Tv063OptimizationChecks.java"],
        )
        proc = subprocess.run(
            [
                str(jdk_bin / ("java" + SUFFIX)),
                "-Dfile.encoding=UTF-8",
                "-cp",
                os.pathsep.join([str(classes_dir), *(str(p) for p in runtime_cp)]),
                "com.pilipala.marcomovie.Tv063OptimizationChecks",
            ],
            cwd=str(ROOT),
            text=True,
            encoding="utf-8",
            errors="replace",
        )
        return proc.returncode


if __name__ == "__main__":
    sys.exit(main())
