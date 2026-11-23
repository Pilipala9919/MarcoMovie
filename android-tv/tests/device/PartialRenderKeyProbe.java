package com.pilipala.marcomovie;

import android.app.*;
import android.content.*;
import android.graphics.*;
import android.os.*;
import android.view.*;
import java.io.*;
import java.lang.reflect.*;
import java.util.*;
import java.util.concurrent.*;
import org.json.*;

/** Native injected-key experiment. Separate from, and never a replacement for, HomeProbe. */
public final class PartialRenderKeyProbe extends Instrumentation {
    MainActivity a;
    SharedPreferences fixturePrefs;
    String namespace;
    boolean isolatedTarget;
    final CountDownLatch launched = new CountDownLatch(1);
    final JSONObject result = new JSONObject();
    final java.util.concurrent.atomic.AtomicInteger requests =
            new java.util.concurrent.atomic.AtomicInteger();

    static final String CURRENT = "f194405e5890aef922b9a11af8be9558fedc9d75";
    static final String BASE = "55799fd3c829075547c26b1e76e0de95cc833e5c";
    static final int MAX_KEYS = 2400, EDGE_ROWS = 32;
    static final long STEP_MS = 12000, TOTAL_MS = 420000;
    String mode, layout, revision, runId, phase = "setup", failureCode;
    long expires;
    Window.Callback originalCallback;
    final ArrayList<KeyRecord> keys = new ArrayList<>();
    final ArrayList<PartialKeyContract.State> checkpoints = new ArrayList<>();
    final ArrayList<String> requestLog = new ArrayList<>();
    final ArrayList<Integer> requestedPages = new ArrayList<>();
    final java.util.concurrent.atomic.AtomicInteger details =
            new java.util.concurrent.atomic.AtomicInteger();
    volatile KeyRecord inflight;
    volatile String observerError;
    boolean partialObserved, boundaryObserved, cloudRun;

    static final class KeyRecord {
        int number, code, downCalls, upCalls;
        long downTime, issuedUptime, completedUptime, dispatchNs;
        String phase, witness, violation, injectionError;
        boolean injectedDown, injectedUp;
        PartialKeyContract.State beforeDown, afterDown, beforeUp, afterUp, settled, followup;
    }

    @Override
    public void onCreate(Bundle args) {
        mode = args == null ? "" : args.getString("scenario", "");
        layout = args == null ? "" : args.getString("layout", "");
        revision = args == null ? "" : args.getString("product_revision", "");
        runId = args == null ? "" : args.getString("run_id", "");
        cloudRun = args != null && "true".equals(args.getString("cloud_run"));
        super.onCreate(args);
        isolatedTarget = args != null && "true".equals(args.getString("isolated_target"));
        namespace = "home_probe_v17_" + SystemClock.elapsedRealtime();
        start();
    }

    @Override
    public void callActivityOnCreate(Activity activity, Bundle state) {
        if (activity instanceof MainActivity) {
            try {
                Context base = activity.getBaseContext();
                java.lang.reflect.Field field = ContextWrapper.class.getDeclaredField("mBase");
                field.setAccessible(true);
                field.set(
                        activity,
                        new ContextWrapper(base) {
                            @Override
                            public SharedPreferences getSharedPreferences(String name, int mode) {
                                if (name.equals("movie") || name.equals("movie-private"))
                                    return fixturePrefs;
                                return super.getSharedPreferences(namespace + "_" + name, mode);
                            }

                            @Override
                            public File getFilesDir() {
                                File dir = new File(super.getCacheDir(), namespace + "/files");
                                dir.mkdirs();
                                return dir;
                            }

                            @Override
                            public File getCacheDir() {
                                File dir = new File(super.getCacheDir(), namespace + "/cache");
                                dir.mkdirs();
                                return dir;
                            }

                            @Override
                            public File getExternalFilesDir(String type) {
                                File base = super.getExternalFilesDir(type);
                                File dir = new File(base == null ? getCacheDir() : base, namespace);
                                dir.mkdirs();
                                return dir;
                            }

                            @Override
                            public Context getApplicationContext() {
                                return this;
                            }
                        });
            } catch (Exception e) {
                throw new RuntimeException(e);
            }
        }
        super.callActivityOnCreate(activity, state);
        if (activity instanceof MainActivity) {
            a = (MainActivity) activity;
            final MainActivity created = a;
            a.getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
            a.ui.post(
                    new Runnable() {
                        @Override
                        public void run() {
                            if (created.isDestroyed()) return;
                            if (created.layoutReady) launched.countDown();
                            else created.ui.postDelayed(this, 16);
                        }
                    });
        }
    }

    boolean ui(Callable<Boolean> action) {
        boolean[] value = {false};
        runOnMainSync(
                () -> {
                    try {
                        value[0] = action.call();
                    } catch (Exception e) {
                        throw new RuntimeException(e);
                    }
                });
        return value[0];
    }

    void await(Callable<Boolean> condition) throws Exception {
        long end = SystemClock.elapsedRealtime() + 12000;
        while (SystemClock.elapsedRealtime() < end) {
            guard();
            if (ui(condition)) return;
            SystemClock.sleep(80);
        }
        throw new AssertionError("Wait timed out");
    }

    void check(String label, boolean passed) throws Exception {
        result.put(label, passed);
        if (!passed) throw new AssertionError(label);
    }

    String listing(String prefix, int count, int page, int pages) throws Exception {
        JSONArray videos = new JSONArray();
        for (int index = 0; index < count; index++)
            videos.put(
                    new JSONObject()
                            .put("vod_id", prefix + "-" + page + "-" + index)
                            .put("vod_name", prefix + " · " + (index + 1))
                            .put("vod_pic", "https://fixture.test/poster.png")
                            .put("vod_remarks", "合成样本"));
        return new JSONObject()
                .put("page", page)
                .put("pagecount", pages)
                .put("list", videos)
                .toString();
    }

    void screenshot() {
        if (a == null) return;
        Bitmap pixels = null;
        try {
            pixels = getUiAutomation().takeScreenshot();
            if (pixels == null) throw new IOException("native screenshot unavailable");
            File file = new File(a.getExternalFilesDir(null), "partial-key-result-native.png");
            try (FileOutputStream out = new FileOutputStream(file)) {
                if (!pixels.compress(Bitmap.CompressFormat.PNG, 100, out))
                    throw new IOException("PNG failed");
            }
            result.put("native_screenshot", file.getAbsolutePath());
        } catch (Throwable failure) {
            try {
                result.put("screenshot_error", failure.toString());
            } catch (Exception ignored) {
            }
        } finally {
            if (pixels != null) pixels.recycle();
        }
    }

    void guard() {
        if (SystemClock.elapsedRealtime() >= expires)
            fail("TOTAL_BUDGET", "420s experiment budget");
    }

    void fail(String code, String message) {
        failureCode = code;
        throw new AssertionError(code + ": " + message);
    }

    int cardIndex(View view) {
        if (view == null || !(view.getTag() instanceof String)) return -1;
        String tag = (String) view.getTag();
        if (!tag.startsWith("home-video:")) return -1;
        try {
            return Integer.parseInt(tag.substring(11));
        } catch (NumberFormatException ignored) {
            return -1;
        }
    }

    PartialKeyContract.State stateOnUi() {
        long began = System.nanoTime();
        PartialKeyContract.State s = new PartialKeyContract.State();
        s.uptime = SystemClock.uptimeMillis();
        s.generation = a.generation;
        s.requests = requests.get();
        HomeScreen h = a.current == null ? null : a.current.retainedHome;
        if (h != null) {
            s.start = h.state.windowStart;
            s.end = h.windowEnd();
            s.items = h.state.videos.size();
            s.page = h.state.page;
            s.columns = h.COLUMNS;
            s.rows = h.rows.size();
            for (java.util.List<View> row : h.rows) s.cards += row.size();
            s.pending = h.pendingGrid != null;
            s.epoch = h.gridEpoch;
            s.active = h.active();
            s.ready = h.state.ready;
            s.busy = h.busy;
        }
        View v = a.getCurrentFocus();
        if (v != null) {
            s.tag = String.valueOf(v.getTag());
            s.index = cardIndex(v);
            s.focusId = v.getId();
            s.nextId = v.getNextFocusDownId();
            s.nextIndex = cardIndex(a.root.findViewById(s.nextId));
            s.attached = v.isAttachedToWindow();
            s.shown = v.isShown();
            s.enabled = v.isEnabled() && v.isFocusable();
            Rect rect = new Rect(), root = new Rect();
            boolean hasRect = v.getGlobalVisibleRect(rect),
                    hasRoot = a.root.getGlobalVisibleRect(root);
            float alpha = v.getAlpha();
            android.view.ViewParent p = v.getParent();
            while (p instanceof View) {
                alpha *= ((View) p).getAlpha();
                p = p.getParent();
            }
            s.visible = hasRect && hasRoot && Rect.intersects(rect, root) && alpha > 0;
            s.left = rect.left;
            s.top = rect.top;
            s.right = rect.right;
            s.bottom = rect.bottom;
            if (h != null && s.index >= 0 && s.index < h.state.videos.size())
                s.contentId = h.state.videos.get(s.index).id;
        }
        s.captureNs = System.nanoTime() - began;
        return s;
    }

    PartialKeyContract.State snapshot() {
        PartialKeyContract.State[] value = new PartialKeyContract.State[1];
        runOnMainSync(() -> value[0] = stateOnUi());
        return value[0];
    }

    void observe(KeyRecord record, KeyEvent event, boolean before) {
        try {
            PartialKeyContract.State s = stateOnUi();
            if (event.getAction() == KeyEvent.ACTION_DOWN) {
                if (before) {
                    record.beforeDown = s;
                    record.downCalls++;
                } else record.afterDown = s;
            } else if (event.getAction() == KeyEvent.ACTION_UP) {
                if (before) {
                    record.beforeUp = s;
                    record.upCalls++;
                } else record.afterUp = s;
            }
        } catch (Throwable error) {
            observerError = error.toString();
        }
    }

    void hookWindow() {
        runOnMainSync(
                () -> {
                    originalCallback = a.getWindow().getCallback();
                    Window.Callback proxy =
                            (Window.Callback)
                                    Proxy.newProxyInstance(
                                            Window.Callback.class.getClassLoader(),
                                            new Class<?>[] {Window.Callback.class},
                                            (object, method, args) -> {
                                                KeyRecord record = inflight;
                                                KeyEvent event =
                                                        args != null
                                                                        && args.length == 1
                                                                        && args[0]
                                                                                instanceof KeyEvent
                                                                ? (KeyEvent) args[0]
                                                                : null;
                                                boolean matched =
                                                        record != null
                                                                && "dispatchKeyEvent"
                                                                        .equals(method.getName())
                                                                && event != null
                                                                && event.getKeyCode() == record.code
                                                                && event.getDownTime()
                                                                        == record.downTime;
                                                if (matched) observe(record, event, true);
                                                long started = System.nanoTime();
                                                try {
                                                    return method.invoke(originalCallback, args);
                                                } catch (InvocationTargetException error) {
                                                    throw error.getCause();
                                                } finally {
                                                    if (matched) {
                                                        record.dispatchNs +=
                                                                System.nanoTime() - started;
                                                        observe(record, event, false);
                                                    }
                                                }
                                            });
                    a.getWindow().setCallback(proxy);
                });
    }

    KeyRecord key(int code) throws Exception {
        guard();
        if (keys.size() >= MAX_KEYS) fail("KEY_BUDGET", "2400 total injected pairs");
        KeyRecord r = new KeyRecord();
        r.number = keys.size();
        r.code = code;
        r.phase = phase;
        r.downTime = SystemClock.uptimeMillis();
        r.issuedUptime = r.downTime;
        keys.add(r);
        inflight = r;
        try {
            r.injectedDown =
                    getUiAutomation()
                            .injectInputEvent(
                                    new KeyEvent(
                                            r.downTime,
                                            r.downTime,
                                            KeyEvent.ACTION_DOWN,
                                            code,
                                            0,
                                            0,
                                            KeyCharacterMap.VIRTUAL_KEYBOARD,
                                            0,
                                            KeyEvent.FLAG_FROM_SYSTEM,
                                            android.view.InputDevice.SOURCE_DPAD),
                                    true);
        } catch (Throwable error) {
            r.injectionError = error.toString();
        } finally {
            try {
                r.injectedUp =
                        getUiAutomation()
                                .injectInputEvent(
                                        new KeyEvent(
                                                r.downTime,
                                                SystemClock.uptimeMillis(),
                                                KeyEvent.ACTION_UP,
                                                code,
                                                0,
                                                0,
                                                KeyCharacterMap.VIRTUAL_KEYBOARD,
                                                0,
                                                KeyEvent.FLAG_FROM_SYSTEM,
                                                android.view.InputDevice.SOURCE_DPAD),
                                        true);
            } catch (Throwable error) {
                r.injectionError = error.toString();
            }
            r.completedUptime = SystemClock.uptimeMillis();
            inflight = null;
        }
        r.settled = snapshot();
        if (observerError != null
                || !r.injectedDown
                || !r.injectedUp
                || r.downCalls != 1
                || r.upCalls != 1
                || r.beforeDown == null
                || r.afterDown == null
                || r.beforeUp == null
                || r.afterUp == null)
            fail("INPUT_CAPTURE_INVALID", "injection/callback pairing failed");
        if (code == KeyEvent.KEYCODE_DPAD_DOWN && r.beforeDown.index >= 0) {
            r.witness = PartialKeyContract.witnessKind(r.beforeDown);
            partialObserved |= PartialKeyContract.partialKeyWitness(r.beforeDown);
            boundaryObserved |=
                    r.witness.equals("partial_tail_self")
                            || r.witness.equals("partial_focus_prefetch_boundary");
            for (PartialKeyContract.State s :
                    new PartialKeyContract.State[] {r.afterDown, r.afterUp, r.settled}) {
                String violation = PartialKeyContract.downViolation(r.beforeDown, s);
                if (violation != null) {
                    r.violation = violation;
                    fail(violation, "native key pair " + r.number);
                }
            }
        }
        return r;
    }

    PartialKeyContract.State waitFocus(int index, String tag) throws Exception {
        long end = SystemClock.elapsedRealtime() + STEP_MS;
        while (SystemClock.elapsedRealtime() < end) {
            guard();
            PartialKeyContract.State s = snapshot();
            if (s.usable() && (tag == null ? s.index == index : tag.equals(s.tag))) return s;
            if (tag == null && s.index > index)
                fail("SKIPPED_EXPECTED_FOCUS", "expected " + index + " got " + s.index);
            SystemClock.sleep(80);
        }
        fail("FOCUS_SETTLE_TIMEOUT", "12s expected " + (tag == null ? index : tag));
        return null;
    }

    PartialKeyContract.State advanceDown(PartialKeyContract.State start) throws Exception {
        int expected = Math.min(2000, start.index + start.columns);
        long end = SystemClock.elapsedRealtime() + STEP_MS;
        do {
            KeyRecord record = key(KeyEvent.KEYCODE_DPAD_DOWN);
            PartialKeyContract.State now = record.settled;
            // A not-yet-created next row may legitimately leave focus unchanged. Retry actual keys,
            // but retain one 12s deadline for this logical row, rather than restarting per retry.
            if (now.usable() && now.index == expected) return now;
            if (now.index > expected)
                fail("SKIPPED_EXPECTED_FOCUS", "expected " + expected + " got " + now.index);
            if (mode.equals("edge") && boundaryObserved && now.usable() && now.index == start.index)
                return now;
            SystemClock.sleep(80);
            now = snapshot();
            record.followup = now;
            String late = PartialKeyContract.downViolation(record.beforeDown, now);
            if (late != null) {
                record.violation = late;
                fail(late, "after input delivery");
            }
            if (now.usable() && now.index == expected) return now;
        } while (SystemClock.elapsedRealtime() < end);
        PartialKeyContract.State ended = snapshot();
        checkpoints.add(ended);
        fail(
                ended.usable() ? "ROW_PROGRESS_TIMEOUT" : "FOCUS_LOST_TIMEOUT",
                "12s row " + start.index + " -> " + expected);
        return null;
    }

    void prepareFixture() throws Exception {
        Context context = getTargetContext();
        if (!isolatedTarget
                || PrivacySpace.active
                || !context.getSharedPreferences("movie", 0).getAll().isEmpty()
                || !context.getSharedPreferences("movie-private", 0).getAll().isEmpty()
                || new File(context.getFilesDir(), "config.json").exists())
            fail("ISOLATION_REQUIRED", "empty dedicated cloud target only; never clear user data");
        fixturePrefs = context.getSharedPreferences(namespace, 0);
        check(
                "fixture_defaults_written",
                fixturePrefs
                        .edit()
                        .putBoolean(Prefs.CAST_ENABLED, false)
                        .putBoolean(Prefs.STARTUP_ANIMATION, false)
                        .putInt("tv_navigation_mode", layout.equals("left") ? 1 : 0)
                        .putInt(Prefs.TV_DOCK_POSITION, 0)
                        .putInt(Prefs.HOME_COLUMNS, 5)
                        .putInt(Prefs.NAV_SCALE_PERCENT, 100)
                        .putBoolean(Prefs.REDUCED, true)
                        .putBoolean("wallpaper_enabled", false)
                        .putBoolean("home_ambient", true)
                        .putString("watch_history", "[]")
                        .commit());
        context.startActivity(
                new Intent(context, MainActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
        if (!launched.await(15, TimeUnit.SECONDS)) fail("LAUNCH_TIMEOUT", "15s launch");
        android.util.DisplayMetrics display = new android.util.DisplayMetrics();
        a.getWindowManager().getDefaultDisplay().getRealMetrics(display);
        if (display.widthPixels != 1920
                || display.heightPixels != 1080
                || display.densityDpi != 320)
            fail("DISPLAY_MISMATCH", "requires original 1920x1080 density320");
        hookWindow();
        Cms.Site site = new Cms.Site();
        site.key = "partial-key-fixture";
        site.name = "Partial key fixture";
        site.type = 1;
        site.api = "https://fixture.test/partial";
        SourceEngine engine =
                new SourceEngine() {
                    public String home() throws Exception {
                        return new JSONObject(listing("home", 12, 1, 1))
                                .put(
                                        "class",
                                        new JSONArray()
                                                .put(
                                                        new JSONObject()
                                                                .put("type_id", "section")
                                                                .put("type_name", "Section")))
                                .toString();
                    }

                    public String category(String id, int page) throws Exception {
                        synchronized (requestedPages) {
                            requestedPages.add(page);
                            requestLog.add(SystemClock.uptimeMillis() + ":request:" + page);
                        }
                        requests.incrementAndGet();
                        if (page < 1 || page > 5) throw new IOException("unexpected page " + page);
                        return listing("section", page < 5 ? 500 : 1, page, 5);
                    }

                    public String detail(String id) throws Exception {
                        details.incrementAndGet();
                        return new JSONObject()
                                .put(
                                        "list",
                                        new JSONArray()
                                                .put(
                                                        new JSONObject()
                                                                .put("vod_id", id)
                                                                .put("vod_name", "Detail " + id)
                                                                .put(
                                                                        "vod_pic",
                                                                        "https://fixture.test/poster.png")
                                                                .put("vod_play_from", "fixture")
                                                                .put(
                                                                        "vod_play_url",
                                                                        "Episode 1$https://fixture.invalid/never-played.mp4")))
                                .toString();
                    }

                    public String search(String query, int page) {
                        return "{\"list\":[]}";
                    }

                    public boolean requiresExternalRuntime() {
                        return false;
                    }
                };
        runOnMainSync(
                () -> {
                    a.prefs = fixturePrefs;
                    a.reduced = true;
                    if (a.startupIntro != null) a.startupIntro.cancel();
                    Bitmap art = Bitmap.createBitmap(300, 450, Bitmap.Config.ARGB_8888);
                    Canvas canvas = new Canvas(art);
                    Paint paint = new Paint(3);
                    paint.setShader(
                            new LinearGradient(
                                    0, 0, 300, 450, 0xff42636a, 0xff272b35, Shader.TileMode.CLAMP));
                    canvas.drawRect(0, 0, 300, 450, paint);
                    paint.setShader(null);
                    paint.setColor(0xffd4d2c4);
                    canvas.drawCircle(150, 130, 72, paint);
                    paint.setColor(Color.WHITE);
                    paint.setTextSize(28);
                    paint.setTextAlign(Paint.Align.CENTER);
                    canvas.drawText("Partial key fixture", 150, 340, paint);
                    a.images.put("https://fixture.test/poster.png", art);
                    Cms.Config config = new Cms.Config();
                    config.raw = "{}";
                    config.sites.add(site);
                    a.config = config;
                    a.engines.put(site.key, engine);
                    a.prefs.edit().putString(Prefs.SELECTED_SITE, site.key).commit();
                    a.back.clear();
                    a.open(new MainActivity.Screen(a::home), false);
                });
        await(() -> a.root.findViewWithTag("home-tab:1") != null && a.current.homeState.ready);
        // Fixture bootstrap only: choose the explicit layout/library and category. From category
        // to grid and every tested movement below uses the platform's injected key path.
        runOnMainSync(
                () -> {
                    if (layout.equals("left")) {
                        View library = a.root.findViewWithTag("nav-library");
                        if (library == null)
                            throw new AssertionError("left library entry unavailable");
                        library.performClick();
                    }
                    View tab = a.root.findViewWithTag("home-tab:1");
                    tab.requestFocus();
                    tab.performClick();
                });
        await(
                () ->
                        !a.current.retainedHome.busy
                                && a.current.homeState.ready
                                && "section".equals(a.current.homeState.category)
                                && a.root.findViewWithTag("home-video:0") != null);
        check(
                "first_page_500_window360",
                ui(
                        () ->
                                a.current.homeState.page == 1
                                        && a.current.homeState.videos.size() == 500
                                        && a.current.retainedHome.windowEnd() == 360
                                        && a.current.retainedHome.COLUMNS == 5
                                        && a.current.homeState.windowStart == 0));
        phase = "enter-grid";
        key(KeyEvent.KEYCODE_DPAD_DOWN);
        checkpoints.add(waitFocus(0, null));
    }

    void validateCatalogue() throws Exception {
        check(
                "five_pages_2001_unique_ordered",
                ui(
                        () -> {
                            HomeScreen.State s = a.current.homeState;
                            if (s.page != 5 || s.pages != 5 || s.videos.size() != 2001)
                                return false;
                            HashSet<String> ids = new HashSet<>();
                            for (int n = 0; n < 2001; n++) {
                                String expected = "section-" + (n / 500 + 1) + "-" + (n % 500);
                                if (!expected.equals(s.videos.get(n).id)
                                        || !ids.add(s.videos.get(n).id)) return false;
                            }
                            return true;
                        }));
        synchronized (requestedPages) {
            check(
                    "exactly_one_request_per_page",
                    requestedPages.equals(Arrays.asList(1, 2, 3, 4, 5)));
        }
    }

    void walk() throws Exception {
        PartialKeyContract.State focus = snapshot();
        phase = "walk-down";
        for (int row = 0; focus.index < 2000; row++) {
            if (row >= 401) fail("ROW_BUDGET", "401 rows");
            focus = advanceDown(focus);
        }
        checkpoints.add(focus);
        validateCatalogue();
        phase = "tail";
        key(KeyEvent.KEYCODE_DPAD_DOWN);
        waitFocus(2000, null);
        check("tail_no_extra_request", requests.get() == 5);
        phase = "return-windows";
        // Walk UP to the first row, then activate the visible earlier-window button via OK.
        for (int window = 0; snapshot().start > 0; window++) {
            if (window >= 6) fail("RETURN_WINDOW_BUDGET", "six earlier-window activations");
            PartialKeyContract.State s = snapshot();
            int oldStart = s.start;
            for (int row = 0; s.index > oldStart; row++) {
                if (row >= 73) fail("UP_ROW_BUDGET", "73 rows");
                int target = Math.max(oldStart, s.index - 5);
                key(KeyEvent.KEYCODE_DPAD_UP);
                s = waitFocus(target, null);
            }
            key(KeyEvent.KEYCODE_DPAD_UP);
            waitFocus(-1, "home-earlier");
            key(KeyEvent.KEYCODE_DPAD_CENTER);
            s = waitFocus(Math.max(0, oldStart - 360), null);
            checkpoints.add(s);
            if (s.start != Math.max(0, oldStart - 360))
                fail("WRONG_EARLIER_WINDOW", "return window");
            check("return_window_" + window + "_no_request", requests.get() == 5);
        }
        validateCatalogue();
        phase = "detail-return";
        final HomeScreen home = a.current.retainedHome;
        final MainActivity.Screen screen = a.current;
        int oldDetails = details.get();
        key(KeyEvent.KEYCODE_DPAD_CENTER);
        await(() -> a.current != screen && details.get() > oldDetails);
        key(KeyEvent.KEYCODE_BACK);
        PartialKeyContract.State returned = waitFocus(0, null);
        checkpoints.add(returned);
        check("detail_return_same_home", ui(() -> a.current.retainedHome == home));
        check("detail_return_no_category_request", requests.get() == 5);
        validateCatalogue();
    }

    JSONObject json(PartialKeyContract.State s) throws Exception {
        if (s == null) return null;
        return new JSONObject()
                .put("uptime_ms", s.uptime)
                .put("focus_tag", s.tag)
                .put("focus_index", s.index)
                .put("content_id", s.contentId)
                .put("window_start", s.start)
                .put("window_end", s.end)
                .put("items", s.items)
                .put("page", s.page)
                .put("columns", s.columns)
                .put("cards", s.cards)
                .put("rows", s.rows)
                .put("epoch", s.epoch)
                .put("generation", s.generation)
                .put("requests", s.requests)
                .put("focus_id", s.focusId)
                .put("next_down_id", s.nextId)
                .put("next_down_index", s.nextIndex)
                .put("attached", s.attached)
                .put("shown", s.shown)
                .put("visible_screen_intersection", s.visible)
                .put("enabled_focusable", s.enabled)
                .put("rect", new JSONArray(new int[] {s.left, s.top, s.right, s.bottom}))
                .put("active", s.active)
                .put("ready", s.ready)
                .put("busy", s.busy)
                .put("pending_grid", s.pending)
                .put("capture_ns", s.captureNs);
    }

    void persist() throws Exception {
        if (a == null) return;
        JSONArray records = new JSONArray();
        for (KeyRecord r : keys)
            records.put(
                    new JSONObject()
                            .put("number", r.number)
                            .put("phase", r.phase)
                            .put("key_code", r.code)
                            .put("down_time", r.downTime)
                            .put("issued_uptime", r.issuedUptime)
                            .put("completed_uptime", r.completedUptime)
                            .put("dispatch_ns", r.dispatchNs)
                            .put("down_injected", r.injectedDown)
                            .put("up_injected", r.injectedUp)
                            .put("down_callbacks", r.downCalls)
                            .put("up_callbacks", r.upCalls)
                            .put("witness", r.witness)
                            .put("violation", r.violation)
                            .put("injection_error", r.injectionError)
                            .put("before_down", json(r.beforeDown))
                            .put("after_down", json(r.afterDown))
                            .put("before_up", json(r.beforeUp))
                            .put("after_up", json(r.afterUp))
                            .put("post_delivery", json(r.settled))
                            .put("followup", json(r.followup)));
        JSONArray saved = new JSONArray();
        for (PartialKeyContract.State s : checkpoints) saved.put(json(s));
        JSONObject data =
                new JSONObject()
                        .put("schema", 1)
                        .put("scenario", mode)
                        .put("layout", layout)
                        .put("product_revision", revision)
                        .put("run_id", runId)
                        .put("key_events", records)
                        .put("checkpoints", saved)
                        .put("partial_observed", partialObserved)
                        .put("boundary_observed", boundaryObserved)
                        .put("observer_error", observerError);
        synchronized (requestedPages) {
            data.put("requested_pages", new JSONArray(requestedPages))
                    .put("request_trace", new JSONArray(requestLog));
        }
        File file = new File(a.getExternalFilesDir(null), "partial-key-events.json");
        try (FileOutputStream out = new FileOutputStream(file)) {
            out.write((data.toString(2) + "\n").getBytes("UTF-8"));
        }
        result.put("events_path", file.getAbsolutePath())
                .put("key_pairs", keys.size())
                .put("partial_observed", partialObserved)
                .put("boundary_observed", boundaryObserved);
    }

    @Override
    public void onStart() {
        expires = SystemClock.elapsedRealtime() + TOTAL_MS;
        try {
            if (!(mode.equals("edge") || mode.equals("walk"))
                    || !(layout.equals("right") || layout.equals("left"))
                    || !(revision.equals(CURRENT) || revision.equals(BASE))
                    || runId.isEmpty()
                    || (revision.equals(BASE) && !layout.equals("right")))
                fail(
                        "PARAMETERS",
                        "explicit scenario/layout/exact product_revision/run_id required");
            if (!cloudRun
                    || Build.VERSION.SDK_INT != 23
                    || !"ranchu".equals(Build.HARDWARE)
                    || !"x86".equals(Build.CPU_ABI))
                fail(
                        "CLOUD_EMULATOR_REQUIRED",
                        "cloud runner must separately verify host identity; API23/x86/ranchu only");
            result.put("scenario", mode)
                    .put("layout", layout)
                    .put("product_revision_argument", revision)
                    .put("run_id", runId)
                    .put("fixture_namespace", namespace)
                    .put("sdk_int", Build.VERSION.SDK_INT)
                    .put(
                            "input_scope",
                            "platform injected DPAD; Window.Callback delegates original exactly once; no physical remote")
                    .put("acceptance_passed", false)
                    .put("original_homeprobe_replaced", false)
                    .put(
                            "scope",
                            "separate warm synthetic partial-render input experiment; original 12s/2001 failures remain");
            prepareFixture();
            if (mode.equals("walk")) walk();
            else {
                phase = "partial-edge";
                for (int n = 0; !boundaryObserved && n < EDGE_ROWS; n++) advanceDown(snapshot());
                if (!boundaryObserved)
                    fail(
                            "PARTIAL_BOUNDARY_NOT_OBSERVED",
                            "do not claim an unexercised fast-render path passed");
                KeyRecord last = keys.get(keys.size() - 1);
                long settleEnd = SystemClock.elapsedRealtime() + STEP_MS;
                PartialKeyContract.State s;
                do {
                    SystemClock.sleep(80);
                    guard();
                    s = snapshot();
                    last.followup = s;
                    String late = PartialKeyContract.downViolation(last.beforeDown, s);
                    if (late != null) {
                        last.violation = late;
                        fail(late, "edge post-delivery");
                    }
                    if (s.usable()
                            && (s.index == last.beforeDown.index
                                    || s.index == last.beforeDown.index + last.beforeDown.columns))
                        break;
                } while (SystemClock.elapsedRealtime() < settleEnd);
                if (!s.usable() || s.index < last.beforeDown.index)
                    fail("EDGE_FOCUS_LOST", "focus did not return within 12s");
                checkpoints.add(snapshot());
            }
            if (!partialObserved)
                fail(
                        "PARTIAL_INPUT_NOT_OBSERVED",
                        "no native DOWN arrived during partial rendering");
            result.put("passed", true);
        } catch (Throwable error) {
            try {
                result.put("passed", false)
                        .put("failure_code", failureCode == null ? "UNCLASSIFIED" : failureCode)
                        .put("error", error.toString())
                        .put("error_stack", android.util.Log.getStackTraceString(error));
            } catch (Exception ignored) {
            }
        } finally {
            try {
                if (a != null) checkpoints.add(snapshot());
                boolean paired = !keys.isEmpty() && observerError == null;
                for (KeyRecord r : keys)
                    paired &= r.injectedDown && r.injectedUp && r.downCalls == 1 && r.upCalls == 1;
                result.put(
                        "diagnostic_quality",
                        new JSONObject()
                                .put(
                                        "valid",
                                        paired
                                                && partialObserved
                                                && (!mode.equals("edge") || boundaryObserved))
                                .put("paired_keys", paired)
                                .put("partial_witness", partialObserved)
                                .put("observer_error", observerError));
                persist();
            } catch (Throwable error) {
                try {
                    result.put("capture_error", error.toString())
                            .put(
                                    "diagnostic_quality",
                                    new JSONObject()
                                            .put("valid", false)
                                            .put("reason", "capture_failure"));
                } catch (Exception ignored) {
                }
            }
            screenshot(); // Only after experiment; never delays the pre-key witness.
            if (a != null)
                runOnMainSync(
                        () -> {
                            if (originalCallback != null)
                                a.getWindow().setCallback(originalCallback);
                            a.ui.removeCallbacks(a.learnPendingTitles);
                            a.pendingTitles.clear();
                            a.cancelArtwork();
                            a.finish();
                        });
        }
        Bundle output = new Bundle();
        output.putString("result", result.toString());
        sendStatus(0, output);
        finish(Activity.RESULT_OK, new Bundle());
    }
}
