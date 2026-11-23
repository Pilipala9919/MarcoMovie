"""Pure JVM regression checks for the 10-item Android TV UX specialization & optimization pass."""

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
    "android/text/TextUtils.java": """package android.text;

public class TextUtils {
    public enum TruncateAt { START, MIDDLE, END, MARQUEE }

    public static boolean isEmpty(CharSequence str) {
        return str == null || str.length() == 0;
    }

    public static boolean equals(CharSequence a, CharSequence b) {
        if (a == b) return true;
        if (a != null && b != null && a.length() == b.length()) {
            if (a instanceof String && b instanceof String) return a.equals(b);
            for (int i = 0; i < a.length(); i++) {
                if (a.charAt(i) != b.charAt(i)) return false;
            }
            return true;
        }
        return false;
    }
}
""",
    "android/os/Looper.java": """package android.os;

public final class Looper {
    private static final Looper MAIN = new Looper();
    public static Looper getMainLooper() { return MAIN; }
}
""",
    "android/os/Handler.java": """package android.os;

public class Handler {
    public Handler() {}
    public Handler(Looper looper) {}
    public boolean post(Runnable r) { return true; }
    public boolean postDelayed(Runnable r, long delayMillis) { return true; }
    public void removeCallbacks(Runnable r) {}
}
""",
    "android/util/Log.java": """package android.util;

public final class Log {
    public static int d(String t, String m) { return 0; }
    public static int i(String t, String m) { return 0; }
    public static int w(String t, String m) { return 0; }
    public static int w(String t, String m, Throwable tr) { return 0; }
    public static int e(String t, String m) { return 0; }
    public static int e(String t, String m, Throwable tr) { return 0; }
    public static String getStackTraceString(Throwable tr) { return tr == null ? "" : tr.toString(); }
}
""",
    "android/util/LruCache.java": """package android.util;

import java.util.LinkedHashMap;
import java.util.Map;

public class LruCache<K, V> {
    private final int maxSize;
    private final LinkedHashMap<K, V> map = new LinkedHashMap<>(16, 0.75f, true);

    public LruCache(int maxSize) {
        this.maxSize = Math.max(1, maxSize);
    }

    public final synchronized V get(K key) {
        return map.get(key);
    }

    public final synchronized V put(K key, V value) {
        V prev = map.put(key, value);
        while (map.size() > maxSize) {
            Map.Entry<K, V> eldest = map.entrySet().iterator().next();
            map.remove(eldest.getKey());
        }
        return prev;
    }

    protected int sizeOf(K key, V value) {
        return 1;
    }

    public synchronized void trimToSize(int targetSize) {
        while (map.size() > targetSize && !map.isEmpty()) {
            Map.Entry<K, V> eldest = map.entrySet().iterator().next();
            map.remove(eldest.getKey());
        }
    }

    public final synchronized void evictAll() {
        map.clear();
    }
}
""",
}

with tempfile.TemporaryDirectory(prefix="tv-ux-opt-checks-") as tmp:
    work_dir = Path(tmp)
    classes_dir = work_dir / "classes"
    stub_src_dir = work_dir / "stub-src"
    stub_classes_dir = work_dir / "stub-classes"
    stub_classes_dir.mkdir(parents=True, exist_ok=True)
    stub_files = []
    for rel, content in EXTRA_STUBS.items():
        p = stub_src_dir / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(content, encoding="utf-8")
        stub_files.append(str(p))

    android_jar = ensure_android_jar()
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
            "-classpath",
            str(android_jar),
            "-d",
            str(stub_classes_dir),
            *stub_files,
        ],
        cwd=ROOT,
        check=True,
    )

    runtime_cp = compile_real_android_sources(
        classes_dir=classes_dir,
        work_dir=work_dir,
        test_sources=[ROOT / "android-tv/tests/TvUxOptimizationChecks.java"],
    )
    run_cp = os.pathsep.join([str(stub_classes_dir)] + [str(p) for p in runtime_cp])
    subprocess.run(
        [
            str(JDK / ("java" + SUFFIX)),
            "-Dfile.encoding=UTF-8",
            "-cp",
            run_cp,
            "com.pilipala.marcomovie.TvUxOptimizationChecks",
        ],
        cwd=ROOT,
        check=True,
    )
