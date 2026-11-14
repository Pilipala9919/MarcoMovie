"""Pure JVM compilation + runtime checks for Android mobile/tablet playback screen lock."""

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
    "android/os/Build.java": """package android.os;

public class Build {
    public static class VERSION {
        public static int SDK_INT = 35;
    }
}
""",
    "android/os/SystemClock.java": """package android.os;

public final class SystemClock {
    public static long uptimeMillis() {
        return 1000L;
    }
}
""",
    "android/os/Looper.java": """package android.os;

public final class Looper {
    private static final Looper MAIN = new Looper();

    public static Looper getMainLooper() {
        return MAIN;
    }

    public Thread getThread() {
        return Thread.currentThread();
    }
}
""",
    "android/os/Handler.java": """package android.os;

import java.util.concurrent.CopyOnWriteArrayList;

public class Handler {
    private final CopyOnWriteArrayList<Runnable> callbacks = new CopyOnWriteArrayList<>();

    public Handler() {}

    public Handler(Looper looper) {}

    public final boolean post(Runnable r) {
        if (r != null) callbacks.add(r);
        return true;
    }

    public final boolean postDelayed(Runnable r, long delayMillis) {
        if (r != null) callbacks.add(r);
        return true;
    }

    public final void removeCallbacks(Runnable r) {
        if (r != null) {
            while (callbacks.remove(r)) {}
        }
    }

    public final boolean hasCallbacks(Runnable r) {
        return r != null && callbacks.contains(r);
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
    "android/view/Window.java": """package android.view;

public class Window {
    public void addFlags(int flags) {}

    public void clearFlags(int flags) {}

    public WindowManager.LayoutParams getAttributes() {
        return null;
    }

    public View getDecorView() {
        return null;
    }

    public void setColorMode(int colorMode) {}
}
""",
    "android/content/Context.java": """package android.content;

import java.io.File;

public class Context {
    public static final String ACTIVITY_SERVICE = "activity";
    public static final String UI_MODE_SERVICE = "uimode";
    public static final String WINDOW_SERVICE = "window";
    public static final int MODE_PRIVATE = 0;

    public File getFilesDir() {
        return new File(".");
    }

    public File getCacheDir() {
        return new File(".");
    }

    public int checkSelfPermission(String permission) {
        return 0;
    }

    public int checkPermission(String permission, int pid, int uid) {
        return 0;
    }

    public Object getSystemService(String name) {
        return null;
    }
}
""",
    "android/content/ContextWrapper.java": """package android.content;

public class ContextWrapper extends Context {
    public ContextWrapper() {}

    public ContextWrapper(Context base) {}

    protected void attachBaseContext(Context base) {}
}
""",
    "android/view/ContextThemeWrapper.java": """package android.view;

import android.content.Context;
import android.content.ContextWrapper;

public class ContextThemeWrapper extends ContextWrapper {
    public ContextThemeWrapper() {}

    public ContextThemeWrapper(Context base, int themeResId) {
        super(base);
    }
}
""",
    "android/app/Activity.java": """package android.app;

import android.view.ContextThemeWrapper;
import android.view.KeyEvent;
import android.view.View;
import android.view.Window;

public class Activity extends ContextThemeWrapper {
    private int requestedOrientation = -1;
    private final Window window = new Window();

    public void setRequestedOrientation(int requestedOrientation) {
        this.requestedOrientation = requestedOrientation;
    }

    public int getRequestedOrientation() {
        return requestedOrientation;
    }

    public Window getWindow() {
        return window;
    }

    public View getCurrentFocus() {
        return null;
    }

    public boolean isFinishing() {
        return false;
    }

    public boolean isDestroyed() {
        return false;
    }

    public void finish() {}

    public void finishAffinity() {}

    public void finishAndRemoveTask() {}

    public void onBackPressed() {}

    public boolean dispatchKeyEvent(KeyEvent event) {
        return false;
    }
}
""",
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
    public static final int KEYCODE_VOLUME_UP = 24;
    public static final int KEYCODE_VOLUME_DOWN = 25;
    public static final int KEYCODE_SPACE = 62;
    public static final int KEYCODE_ENTER = 66;
    public static final int KEYCODE_MENU = 82;
    public static final int KEYCODE_MEDIA_PLAY_PAUSE = 85;
    public static final int KEYCODE_MEDIA_PLAY = 126;
    public static final int KEYCODE_MEDIA_PAUSE = 127;

    private final int action;
    private final int keyCode;
    private final int repeatCount;

    public KeyEvent(int action, int code) {
        this(0L, 0L, action, code, 0);
    }

    public KeyEvent(long downTime, long eventTime, int action, int code, int repeat) {
        this.action = action;
        this.keyCode = code;
        this.repeatCount = repeat;
    }

    public final int getAction() {
        return action;
    }

    public final int getKeyCode() {
        return keyCode;
    }

    public final int getRepeatCount() {
        return repeatCount;
    }

    public final boolean isCanceled() {
        return false;
    }
}
""",
}

with tempfile.TemporaryDirectory(prefix="player-lock-checks-") as tmp:
    work_dir = Path(tmp)
    classes_dir = work_dir / "classes"
    runtime_cp = compile_real_android_sources(
        classes_dir=classes_dir,
        work_dir=work_dir,
        test_sources=[ROOT / "android/tests/PlayerLockChecks.java"],
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
            "com.pilipala.marcomovie.PlayerLockChecks",
        ],
        cwd=ROOT,
        check=True,
    )
