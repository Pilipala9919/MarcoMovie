"""Isolated JVM + loopback TCP tests for HighQualityUpgradeChecks."""
from pathlib import Path
import os
import shutil
import subprocess
import sys
import textwrap

sys.path.insert(0, str(Path(__file__).resolve().parent))
from java_dependencies import ensure_json_jar

ROOT = Path(__file__).resolve().parents[2]
JDK = os.environ.get("MARCOMOVIE_JDK") or os.environ.get("JAVA_HOME")


def java_tool(name: str) -> str:
    if JDK:
        return str(Path(JDK) / "bin" / (name + (".exe" if os.name == "nt" else "")))
    found = shutil.which(name)
    if not found:
        raise RuntimeError("Set MARCOMOVIE_JDK or JAVA_HOME to JDK 17+")
    return found


ANDROID_JAR = Path(os.environ.get("MARCOMOVIE_ANDROID_JAR", str(ROOT / "tools/android-35/android.jar")))
BUILD_DIR = ROOT / "android-tv/build/hq-upgrade-check"
CLASSES_DIR = BUILD_DIR / "classes"
SHIM_SRC_DIR = BUILD_DIR / "shim-src"
SHIM_CLASSES_DIR = BUILD_DIR / "shim-classes"

if BUILD_DIR.exists():
    shutil.rmtree(BUILD_DIR)
CLASSES_DIR.mkdir(parents=True, exist_ok=True)
SHIM_CLASSES_DIR.mkdir(parents=True, exist_ok=True)

DEPS = [
    ensure_json_jar(),
    *sorted((ROOT / "android-tv/build/aar").glob("*/classes.jar")),
    *sorted((ROOT / "tools/java-dependencies").glob("*.jar")),
]
COMPILE_CP = os.pathsep.join(str(p) for p in [ANDROID_JAR, *DEPS] if p.exists())
MAIN_JAVA_ROOT = ROOT / "android-tv/src/main/java"
SOURCE_PATHS = [MAIN_JAVA_ROOT, ROOT / "shared/java", ROOT / "android-tv/build/generated"]
SOURCEPATH_ARG = os.pathsep.join(str(p) for p in SOURCE_PATHS if p.exists())

TARGET_SOURCES = [
    MAIN_JAVA_ROOT / "com/pilipala/marcomovie/Prefs.java",
    MAIN_JAVA_ROOT / "com/pilipala/marcomovie/MoviePlayer.java",
    MAIN_JAVA_ROOT / "com/pilipala/marcomovie/MpvPlayer.java",
    MAIN_JAVA_ROOT / "com/pilipala/marcomovie/HlsStreamProxy.java",
    MAIN_JAVA_ROOT / "com/pilipala/marcomovie/MediaDiskCache.java",
    MAIN_JAVA_ROOT / "com/pilipala/marcomovie/LocalProxy.java",
    MAIN_JAVA_ROOT / "com/pilipala/marcomovie/WebResolver.java",
    MAIN_JAVA_ROOT / "com/pilipala/marcomovie/WebViewJsEngine.java",
    MAIN_JAVA_ROOT / "com/pilipala/marcomovie/NativePythonEngine.java",
    MAIN_JAVA_ROOT / "com/pilipala/marcomovie/Cms.java",
    ROOT / "android-tv/tests/HighQualityUpgradeChecks.java",
]

subprocess.run(
    [
        java_tool("javac"),
        "-encoding",
        "UTF-8",
        "-source",
        "8",
        "-target",
        "8",
        "-Xlint:-options",
        "-cp",
        COMPILE_CP,
        "-sourcepath",
        SOURCEPATH_ARG,
        "-d",
        str(CLASSES_DIR),
        *map(str, TARGET_SOURCES),
    ],
    check=True,
)

# Minimal desktop JVM shims for Android stubs invoked indirectly during loopback/util tests.
(SHIM_SRC_DIR / "android/util").mkdir(parents=True, exist_ok=True)
(SHIM_SRC_DIR / "android/util/Log.java").write_text(
    textwrap.dedent(
        """\
        package android.util;
        public final class Log {
            public static int d(String t, String m) { return 0; }
            public static int w(String t, String m) { return 0; }
            public static int w(String t, String m, Throwable tr) { return 0; }
            public static int e(String t, String m, Throwable tr) { return 0; }
        }
        """
    ),
    encoding="utf-8",
)
subprocess.run(
    [
        java_tool("javac"),
        "-encoding",
        "UTF-8",
        "-source",
        "8",
        "-target",
        "8",
        "-d",
        str(SHIM_CLASSES_DIR),
        str(SHIM_SRC_DIR / "android/util/Log.java"),
    ],
    check=True,
)

RUNTIME_CP = os.pathsep.join(
    str(p) for p in [SHIM_CLASSES_DIR, CLASSES_DIR, *DEPS, ANDROID_JAR] if p.exists()
)
subprocess.run(
    [java_tool("java"), "-cp", RUNTIME_CP, "com.pilipala.marcomovie.HighQualityUpgradeChecks"],
    check=True,
)
