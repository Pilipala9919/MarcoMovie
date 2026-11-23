"""Real Java compilation plus V2 repository/transaction/IME/F-R1 model regression. No ADB."""
from pathlib import Path
import os
import subprocess
import tempfile
from android_compile_support import SUFFIX, compile_real_android_sources, resolve_jdk_bin

ROOT = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix="tv-v17-safety-") as tmp:
    work = Path(tmp)
    names = ["TvV17SafetyChecks", "TvV17MarkerChecks", "PrivacySearchChecks", "PrivacyPinChecks"]
    cp = compile_real_android_sources(classes_dir=work / "classes", work_dir=work,
        test_sources=[ROOT / "android-tv/tests" / (name + ".java") for name in names])
    for name in names:
        subprocess.run([str(resolve_jdk_bin() / ("java" + SUFFIX)), "-Dfile.encoding=UTF-8",
            "-cp", os.pathsep.join(map(str, cp)), "com.pilipala.marcomovie." + name],
            cwd=ROOT, check=True)
