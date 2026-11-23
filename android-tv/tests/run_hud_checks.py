"""Compile real Android Java sources and run pure-JVM M2 HUD & touch gesture state machine checks."""

from pathlib import Path
import os
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
from android_compile_support import SUFFIX, compile_real_android_sources, ensure_android_jar, resolve_jdk_bin

ROOT = Path(__file__).resolve().parents[2]
JDK = resolve_jdk_bin()

EXTRA_STUBS = {
    "android/view/KeyEvent.java": """package android.view;

public class KeyEvent {
    public static final int ACTION_DOWN = 0;
    public static final int ACTION_UP = 1;
    public static final int KEYCODE_BACK = 4;
    public static final int KEYCODE_DPAD_UP = 19;
    public static final int KEYCODE_DPAD_DOWN = 20;
    public static final int KEYCODE_DPAD_LEFT = 21;
    public static final int KEYCODE_DPAD_RIGHT = 22;
    public static final int KEYCODE_DPAD_CENTER = 23;
    public static final int KEYCODE_ENTER = 66;
    public static final int KEYCODE_MENU = 82;
    public static final int KEYCODE_MEDIA_PLAY_PAUSE = 85;
    public static final int KEYCODE_ESCAPE = 111;
    public static final int KEYCODE_MEDIA_PLAY = 126;
    public static final int KEYCODE_MEDIA_PAUSE = 127;
    public static final int KEYCODE_NUMPAD_ENTER = 160;
}
""",
}

with tempfile.TemporaryDirectory(prefix="hud-checks-") as tmp:
    work_dir = Path(tmp)
    classes_dir = work_dir / "classes"
    runtime_cp = compile_real_android_sources(
        classes_dir=classes_dir,
        work_dir=work_dir,
        test_sources=[ROOT / "android-tv/tests/PlayerGestureChecks.java"],
    )
    extra_src_dir = work_dir / "extra-stubs-src"
    extra_cls_dir = work_dir / "extra-stubs-classes"
    extra_cls_dir.mkdir(parents=True, exist_ok=True)
    extra_files = []
    for rel, src in EXTRA_STUBS.items():
        dst = extra_src_dir / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        dst.write_text(src, encoding="utf-8")
        extra_files.append(str(dst))
    subprocess.run(
        [
            str(JDK / ("javac" + SUFFIX)),
            "-encoding",
            "UTF-8",
            "-source",
            "8",
            "-target",
            "8",
            "-Xlint:-options",
            "-cp",
            str(ensure_android_jar()),
            "-d",
            str(extra_cls_dir),
            *extra_files,
        ],
        check=True,
    )
    subprocess.run(
        [
            str(JDK / ("java" + SUFFIX)),
            "-Dfile.encoding=UTF-8",
            "-cp",
            os.pathsep.join(str(p) for p in [extra_cls_dir, *runtime_cp]),
            "com.pilipala.marcomovie.PlayerGestureChecks",
        ],
        cwd=ROOT,
        check=True,
    )
