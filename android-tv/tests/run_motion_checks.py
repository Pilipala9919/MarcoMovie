"""Real Android Java compilation plus M4a MotionTokens / transition / aurora / F8 loader checks."""

from pathlib import Path
import os
import subprocess
import tempfile

from android_compile_support import SUFFIX, compile_real_android_sources, resolve_jdk_bin

ROOT = Path(__file__).resolve().parents[2]


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="m4a-motion-checks-") as tmp:
        work = Path(tmp)
        cp = compile_real_android_sources(
            classes_dir=work / "classes",
            work_dir=work,
            test_sources=[ROOT / "android-tv/tests/MotionTokenChecks.java"],
        )
        subprocess.run(
            [
                str(resolve_jdk_bin() / ("java" + SUFFIX)),
                "-Dfile.encoding=UTF-8",
                "-cp",
                os.pathsep.join(map(str, cp)),
                "com.pilipala.marcomovie.MotionTokenChecks",
                str(ROOT),
            ],
            cwd=ROOT,
            check=True,
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
