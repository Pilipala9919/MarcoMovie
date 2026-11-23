"""Pure JVM checks for SourcePicker manual grouping/editing/deletion, SearchInputServer QR input, and CastService DLNA/Web cast."""
from pathlib import Path
import os
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
from android_compile_support import SUFFIX, compile_real_android_sources, resolve_jdk_bin

ROOT = Path(__file__).resolve().parents[2]
JDK = resolve_jdk_bin()

with tempfile.TemporaryDirectory(prefix='cast-search-picker-checks-') as tmp:
    work_dir = Path(tmp)
    classes_dir = work_dir / 'classes'
    runtime_cp = compile_real_android_sources(
        classes_dir=classes_dir,
        work_dir=work_dir,
        test_sources=[ROOT / 'android-tv/tests/CastSearchAndPickerChecks.java'],
    )
    run_cp = os.pathsep.join(str(p) for p in runtime_cp)
    subprocess.run([
        str(JDK / ('java' + SUFFIX)),
        '-Dfile.encoding=UTF-8',
        '-cp', run_cp,
        'com.pilipala.marcomovie.CastSearchAndPickerChecks',
    ], cwd=ROOT, check=True)
