"""Pure JVM checks for TV HDR10/HEVC/Dolby Vision color handling, Douban/RT rating resolution, and TV playback HUD."""

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
            if (a instanceof String && b instanceof String) {
                return a.equals(b);
            }
            for (int i = 0; i < a.length(); i++) {
                if (a.charAt(i) != b.charAt(i)) return false;
            }
            return true;
        }
        return false;
    }
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

    public final synchronized void evictAll() {
        map.clear();
    }
}
""",
    "android/text/SpannableString.java": """package android.text;

public class SpannableString implements Spannable, CharSequence {
    private final String text;

    public SpannableString(CharSequence source) {
        this.text = source == null ? "" : source.toString();
    }

    @Override
    public void setSpan(Object what, int start, int end, int flags) {}

    @Override
    public void removeSpan(Object what) {}

    @Override
    public <T> T[] getSpans(int queryStart, int queryEnd, Class<T> kind) {
        @SuppressWarnings("unchecked")
        T[] empty = (T[]) java.lang.reflect.Array.newInstance(kind, 0);
        return empty;
    }

    @Override
    public int getSpanStart(Object tag) { return -1; }

    @Override
    public int getSpanEnd(Object tag) { return -1; }

    @Override
    public int getSpanFlags(Object tag) { return 0; }

    @Override
    public int nextSpanTransition(int start, int limit, Class type) { return limit; }

    @Override
    public int length() { return text.length(); }

    @Override
    public char charAt(int index) { return text.charAt(index); }

    @Override
    public CharSequence subSequence(int start, int end) { return text.subSequence(start, end); }

    @Override
    public String toString() { return text; }
}
""",
    "android/text/style/CharacterStyle.java": """package android.text.style;

import android.text.TextPaint;

public abstract class CharacterStyle {
    public abstract void updateDrawState(TextPaint tp);
}
""",
    "android/text/style/MetricAffectingSpan.java": """package android.text.style;

import android.text.TextPaint;

public abstract class MetricAffectingSpan extends CharacterStyle implements UpdateLayout {
    public abstract void updateMeasureState(TextPaint textPaint);
}
""",
    "android/text/style/ForegroundColorSpan.java": """package android.text.style;

import android.text.TextPaint;

public class ForegroundColorSpan extends CharacterStyle implements UpdateAppearance {
    private final int color;

    public ForegroundColorSpan(int color) {
        this.color = color;
    }

    public int getForegroundColor() {
        return color;
    }

    @Override
    public void updateDrawState(TextPaint tp) {}
}
""",
    "android/text/style/ReplacementSpan.java": """package android.text.style;

import android.graphics.Canvas;
import android.graphics.Paint;
import android.text.TextPaint;

public abstract class ReplacementSpan extends MetricAffectingSpan {
    public abstract int getSize(Paint paint, CharSequence text, int start, int end, Paint.FontMetricsInt fm);
    public abstract void draw(Canvas canvas, CharSequence text, int start, int end, float x, int top, int y, int bottom, Paint paint);

    @Override
    public void updateMeasureState(TextPaint p) {}

    @Override
    public void updateDrawState(TextPaint ds) {}
}
""",
}

with tempfile.TemporaryDirectory(prefix="tv-playback-ratings-checks-") as tmp:
    work_dir = Path(tmp)
    classes_dir = work_dir / "classes"
    runtime_cp = compile_real_android_sources(
        classes_dir=classes_dir,
        work_dir=work_dir,
        test_sources=[ROOT / "android/tests/TvPlaybackAndRatingsChecks.java"],
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
            "com.pilipala.marcomovie.TvPlaybackAndRatingsChecks",
        ],
        cwd=ROOT,
        check=True,
    )
