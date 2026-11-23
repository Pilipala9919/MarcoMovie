"""Isolated JVM unit + loopback TCP integration checks for LocalProxy & ChunkedProxyDataSource.

Compiles exclusively into android-mobile/build/local-proxy-check to avoid colliding with parallel tasks.
"""
from pathlib import Path
import os
import shutil
import subprocess
import textwrap

ROOT = Path(__file__).resolve().parents[2]
JDK = Path(os.environ.get('MARCOMOVIE_JDK', os.environ.get('JAVA_HOME', 'missing-jdk')))


def java_tool(name: str) -> str:
    candidate = JDK / 'bin' / (name + ('.exe' if os.name == 'nt' else ''))
    if candidate.exists():
        return str(candidate)
    found = shutil.which(name)
    if not found:
        raise RuntimeError('Set MARCOMOVIE_JDK or JAVA_HOME to JDK 17+')
    return found


ANDROID_JAR = Path(os.environ.get('MARCOMOVIE_ANDROID_JAR', str(ROOT / 'tools/android-35/android.jar')))
BUILD_DIR = ROOT / 'android-mobile/build/local-proxy-check'
CLASSES_DIR = BUILD_DIR / 'classes'
SHIM_SRC_DIR = BUILD_DIR / 'shim-src'
SHIM_CLASSES_DIR = BUILD_DIR / 'shim-classes'

if BUILD_DIR.exists():
    shutil.rmtree(BUILD_DIR)
CLASSES_DIR.mkdir(parents=True, exist_ok=True)
SHIM_CLASSES_DIR.mkdir(parents=True, exist_ok=True)

DEPS = [
    ROOT / 'android-mobile/tests/lib/json-20240303.jar',
    *sorted((ROOT / 'android-mobile/build/aar').glob('*/classes.jar')),
    *sorted((ROOT / 'tools/java-dependencies').glob('*.jar')),
]

COMPILE_CP = os.pathsep.join(str(p) for p in [ANDROID_JAR, *DEPS] if p.exists())

# 1. Compile our modified Android sources + test against the real Android 35 SDK & Media3 JARs
MAIN_JAVA_ROOT = ROOT / 'android-mobile/src/main/java'
GENERATED_ROOT = ROOT / 'android-mobile/build/generated'
if not GENERATED_ROOT.exists():
    GENERATED_ROOT = BUILD_DIR / 'generated-stub'
    r_java = GENERATED_ROOT / 'com/pilipala/marcomovie/R.java'
    r_java.parent.mkdir(parents=True, exist_ok=True)
    r_java.write_text(
        textwrap.dedent(
            """\
            package com.pilipala.marcomovie;
            public final class R {
                public static final class drawable { public static final int logo_mark = 1; }
                public static final class id { public static final int focus_motion = 2; }
                public static final class mipmap { public static final int ic_launcher = 3; }
            }
            """
        ),
        encoding='utf-8',
    )
SOURCE_PATHS = [
    MAIN_JAVA_ROOT,
    ROOT / 'shared/java',
    GENERATED_ROOT,
]
SOURCEPATH_ARG = os.pathsep.join(str(p) for p in SOURCE_PATHS if p.exists())
TARGET_SOURCES = [
    MAIN_JAVA_ROOT / 'com/pilipala/marcomovie/LocalProxy.java',
    MAIN_JAVA_ROOT / 'com/pilipala/marcomovie/MediaOptions.java',
    MAIN_JAVA_ROOT / 'com/pilipala/marcomovie/MoviePlayer.java',
    MAIN_JAVA_ROOT / 'com/pilipala/marcomovie/DecoderRenderersFactory.java',
    ROOT / 'android-mobile/tests/LocalProxyRangeChecks.java',
]

subprocess.run(
    [
        java_tool('javac'),
        '-encoding',
        'UTF-8',
        '-source',
        '8',
        '-target',
        '8',
        '-Xlint:-options',
        '-cp',
        COMPILE_CP,
        '-sourcepath',
        SOURCEPATH_ARG,
        '-d',
        str(CLASSES_DIR),
        *map(str, TARGET_SOURCES),
    ],
    check=True,
)

# 2. Build minimal desktop-JVM runtime shims for android.net.Uri, android.text.TextUtils, android.util.Log
#    (android.jar contains "Stub!" method bodies that throw at desktop JVM runtime).
(SHIM_SRC_DIR / 'android/net').mkdir(parents=True, exist_ok=True)
(SHIM_SRC_DIR / 'android/text').mkdir(parents=True, exist_ok=True)
(SHIM_SRC_DIR / 'android/util').mkdir(parents=True, exist_ok=True)

(SHIM_SRC_DIR / 'android/net/Uri.java').write_text(
    textwrap.dedent(
        """\
        package android.net;
        import java.net.URI;
        public final class Uri {
            public static final Uri EMPTY = new Uri("");
            private final String raw;
            private final URI parsed;
            private Uri(String s) {
                this.raw = s == null ? "" : s;
                URI u = null;
                try { u = new URI(this.raw); } catch (Exception ignored) {}
                this.parsed = u;
            }
            public static Uri parse(String s) { return new Uri(s); }
            public String getScheme() { return parsed != null ? parsed.getScheme() : null; }
            public String getHost() { return parsed != null ? parsed.getHost() : null; }
            public int getPort() { return parsed != null ? parsed.getPort() : -1; }
            public String getPath() { return parsed != null ? parsed.getPath() : null; }
            public String getQuery() { return parsed != null ? parsed.getQuery() : null; }
            public String getLastPathSegment() {
                String p = getPath();
                if (p == null || p.isEmpty()) return null;
                int idx = p.lastIndexOf('/');
                return idx >= 0 ? p.substring(idx + 1) : p;
            }
            @Override public String toString() { return raw; }
            @Override public boolean equals(Object o) {
                return o instanceof Uri && raw.equals(((Uri) o).raw);
            }
            @Override public int hashCode() { return raw.hashCode(); }
        }
        """
    ),
    encoding='utf-8',
)

(SHIM_SRC_DIR / 'android/text/TextUtils.java').write_text(
    textwrap.dedent(
        """\
        package android.text;
        public final class TextUtils {
            public static boolean isEmpty(CharSequence s) { return s == null || s.length() == 0; }
            public static boolean equals(CharSequence a, CharSequence b) {
                if (a == b) return true;
                if (a == null || b == null || a.length() != b.length()) return false;
                return a.toString().equals(b.toString());
            }
        }
        """
    ),
    encoding='utf-8',
)

(SHIM_SRC_DIR / 'android/util/Log.java').write_text(
    textwrap.dedent(
        """\
        package android.util;
        public final class Log {
            public static int d(String t, String m) { return 0; }
            public static int i(String t, String m) { return 0; }
            public static int w(String t, String m) { return 0; }
            public static int w(String t, String m, Throwable e) { return 0; }
            public static int e(String t, String m) { return 0; }
            public static int e(String t, String m, Throwable e) { return 0; }
            public static String getStackTraceString(Throwable tr) { return tr == null ? "" : tr.toString(); }
        }
        """
    ),
    encoding='utf-8',
)

subprocess.run(
    [
        java_tool('javac'),
        '-encoding',
        'UTF-8',
        '-source',
        '8',
        '-target',
        '8',
        '-Xlint:-options',
        '-d',
        str(SHIM_CLASSES_DIR),
        *map(str, SHIM_SRC_DIR.rglob('*.java')),
    ],
    check=True,
)

RUN_CP = os.pathsep.join(
    str(p) for p in [SHIM_CLASSES_DIR, CLASSES_DIR, *DEPS, ANDROID_JAR] if p.exists()
)

result = subprocess.run(
    [
        java_tool('java'),
        '-Dfile.encoding=UTF-8',
        '-cp',
        RUN_CP,
        'com.pilipala.marcomovie.LocalProxyRangeChecks',
    ],
    check=True,
    text=True,
    encoding='utf-8',
    errors='replace',
    capture_output=True,
)
print(result.stdout, end='')
