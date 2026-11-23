package com.pilipala.marcomovie;

import android.app.*;
import android.content.*;
import android.graphics.*;
import android.os.*;
import android.view.*;
import java.io.*;
import java.util.concurrent.*;
import org.json.*;

/** Separate common-right-layout comparison. Never substitutes for the full HomeProbe matrix. */
public final class GridRenderCompareProbe extends Instrumentation {
    MainActivity a;
    SharedPreferences fixturePrefs;
    String namespace;
    boolean isolatedTarget;
    final CountDownLatch launched = new CountDownLatch(1);
    final JSONObject result = new JSONObject();
    final java.util.concurrent.atomic.AtomicInteger requests =
            new java.util.concurrent.atomic.AtomicInteger();

    @Override
    public void onCreate(Bundle args) {
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
            File file = new File(a.getExternalFilesDir(null), "grid-compare-result-native.png");
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

    @Override
    public void onStart() {
        try {
            Context context = getTargetContext();
            if (!isolatedTarget
                    || PrivacySpace.active
                    || !context.getSharedPreferences("movie", 0).getAll().isEmpty()
                    || !context.getSharedPreferences("movie-private", 0).getAll().isEmpty()
                    || new File(context.getFilesDir(), "config.json").exists())
                throw new AssertionError(
                        "Requires isolated_target=true and an empty dedicated target; never clear user data");
            fixturePrefs = context.getSharedPreferences(namespace, 0);
            check(
                    "fixture_defaults_written",
                    fixturePrefs
                            .edit()
                            .putBoolean(Prefs.CAST_ENABLED, false)
                            .putBoolean(Prefs.STARTUP_ANIMATION, false)
                            .putInt("tv_navigation_mode", 0)
                            .putInt(Prefs.TV_DOCK_POSITION, 0)
                            .putInt(Prefs.HOME_COLUMNS, 5)
                            .putInt(Prefs.NAV_SCALE_PERCENT, 100)
                            .putBoolean(Prefs.REDUCED, true)
                            .putBoolean("wallpaper_enabled", false)
                            .putBoolean("home_ambient", true)
                            .putString("watch_history", "[]")
                            .commit());
            result.put("fixture_namespace", namespace)
                    .put("comparison_only", true)
                    .put(
                            "scope",
                            "shared-right-layout, first 500 items/window360, warm synthetic artwork; no DOWN, no 2001/left-navigation pass claim")
                    .put("sdk_int", Build.VERSION.SDK_INT)
                    .put("device", Build.MANUFACTURER + "/" + Build.MODEL);
            context.startActivity(
                    new Intent(context, MainActivity.class)
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
            if (!launched.await(15, TimeUnit.SECONDS)) throw new AssertionError("launch");
            Cms.Site site = new Cms.Site();
            site.key = "home-grid-compare";
            site.name = "网格对照夹具";
            site.type = 1;
            site.api = "https://fixture.test/section";
            SourceEngine engine =
                    new SourceEngine() {
                        public String home() throws Exception {
                            return new JSONObject(listing("section-home", 12, 1, 1))
                                    .put(
                                            "class",
                                            new JSONArray()
                                                    .put(
                                                            new JSONObject()
                                                                    .put("type_id", "section")
                                                                    .put("type_name", "分页夹具")))
                                    .toString();
                        }

                        public String category(String id, int page) throws Exception {
                            requests.incrementAndGet();
                            if (page < 1 || page > 5) throw new IOException("unexpected page");
                            return listing("section", page < 5 ? 500 : 1, page, 5);
                        }

                        public String detail(String id) {
                            return "{\"list\":[]}";
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
                        if (a.startupIntro != null) a.startupIntro.cancel();
                        a.reduced = true;
                        Bitmap art = Bitmap.createBitmap(300, 450, Bitmap.Config.ARGB_8888);
                        Canvas canvas = new Canvas(art);
                        Paint paint = new Paint(3);
                        paint.setShader(
                                new LinearGradient(
                                        0,
                                        0,
                                        300,
                                        450,
                                        0xff42636a,
                                        0xff272b35,
                                        Shader.TileMode.CLAMP));
                        canvas.drawRect(0, 0, 300, 450, paint);
                        paint.setShader(null);
                        paint.setColor(0xffd4d2c4);
                        canvas.drawCircle(150, 130, 72, paint);
                        paint.setColor(Color.WHITE);
                        paint.setTextSize(28);
                        paint.setTextAlign(Paint.Align.CENTER);
                        canvas.drawText("山海之间", 150, 340, paint);
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
            runOnMainSync(
                    () -> {
                        View tab = a.root.findViewWithTag("home-tab:1");
                        tab.requestFocus();
                        tab.performClick();
                    });
            SystemClock.sleep(200);
            await(
                    () ->
                            !a.current.retainedHome.busy
                                    && a.current.homeState.ready
                                    && "section".equals(a.current.homeState.category));
            check(
                    "first_page_500_window360",
                    ui(
                            () ->
                                    a.current.homeState.page == 1
                                            && a.current.homeState.videos.size() == 500
                                            && a.current.retainedHome.COLUMNS == 5
                                            && a.current.homeState.windowStart == 0
                                            && a.current.retainedHome.windowEnd() == 360));
            HomeRenderDiagnostics.awaitLastCard(
                    this,
                    a,
                    () -> a.current.retainedHome,
                    () ->
                            a.root.findViewWithTag(
                                            "home-video:"
                                                    + (a.current.retainedHome.windowEnd() - 1))
                                    != null,
                    result,
                    "common-right-first-window");
            check("no_extra_source_requests", requests.get() == 1);
            check(
                    "diagnostic_overlay_available",
                    result.getJSONArray("render_waits")
                            .getJSONObject(0)
                            .getBoolean("trace_available"));
            result.put("passed", true);
        } catch (Throwable failure) {
            try {
                result.put("passed", false)
                        .put("error", failure.toString())
                        .put("error_stack", android.util.Log.getStackTraceString(failure));
            } catch (Exception ignored) {
            }
        } finally {
            screenshot();
            if (a != null)
                runOnMainSync(
                        () -> {
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
