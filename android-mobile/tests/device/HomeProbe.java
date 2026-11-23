package com.pilipala.marcomovie;

import android.app.*;
import android.content.*;
import android.os.*;
import android.view.*;
import android.widget.*;
import android.graphics.*;
import java.io.*;
import java.util.concurrent.*;
import org.json.*;

/** Synthetic source probe. Requires an explicitly provisioned, empty test installation. */
public final class HomeProbe extends Instrumentation {
    MainActivity a;
    String fixtureNamespace;
    SharedPreferences fixturePrefs;
    boolean isolatedTarget;
    volatile boolean failAnimeCategory;
    final CountDownLatch launched = new CountDownLatch(1);
    final JSONObject result = new JSONObject();
    SectionFixture activeSectionFixture;
    String sectionWait = "not-started";
    final java.util.concurrent.atomic.AtomicInteger homeRequests =
            new java.util.concurrent.atomic.AtomicInteger();
    final java.util.concurrent.atomic.AtomicInteger categoryRequests =
            new java.util.concurrent.atomic.AtomicInteger();
    volatile java.util.Map<String, String> receivedFilters = new java.util.LinkedHashMap<>();

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
                            public SharedPreferences getSharedPreferences(String name, int mode) {
                                if (name.equals("movie") || name.equals("movie-private"))
                                    return fixturePrefs;
                                return super.getSharedPreferences(
                                        fixtureNamespace + "_" + name, mode);
                            }

                            public java.io.File getFilesDir() {
                                java.io.File file =
                                        new java.io.File(
                                                super.getCacheDir(), fixtureNamespace + "/files");
                                file.mkdirs();
                                return file;
                            }

                            public java.io.File getCacheDir() {
                                java.io.File file =
                                        new java.io.File(
                                                super.getCacheDir(), fixtureNamespace + "/cache");
                                file.mkdirs();
                                return file;
                            }

                            public java.io.File getExternalFilesDir(String type) {
                                java.io.File base = super.getExternalFilesDir(type);
                                java.io.File file =
                                        new java.io.File(
                                                base == null ? getCacheDir() : base,
                                                fixtureNamespace);
                                file.mkdirs();
                                return file;
                            }

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
            created.getWindow()
                    .addFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
            created.ui.post(
                    new Runnable() {
                        public void run() {
                            if (created.isDestroyed()) return;
                            if (created.layoutReady) launched.countDown();
                            else created.ui.postDelayed(this, 16);
                        }
                    });
        }
    }

    @Override
    public void onCreate(Bundle args) {
        super.onCreate(args);
        isolatedTarget = args != null && "true".equals(args.getString("isolated_target"));
        fixtureNamespace = "home_probe_v17_" + SystemClock.elapsedRealtime();
        start();
    }

    boolean ui(Callable<Boolean> call) {
        boolean[] out = {false};
        runOnMainSync(
                () -> {
                    try {
                        out[0] = call.call();
                    } catch (Exception e) {
                        throw new RuntimeException(e);
                    }
                });
        return out[0];
    }

    void check(String name, boolean value) throws Exception {
        result.put(name, value);
        if (!value) throw new AssertionError(name);
    }

    View tag(String name) {
        return a.root.findViewWithTag(name);
    }

    void await(Callable<Boolean> condition) throws Exception {
        long end = SystemClock.elapsedRealtime() + 12000;
        while (SystemClock.elapsedRealtime() < end) {
            if (ui(condition)) return;
            SystemClock.sleep(80);
        }
        throw new AssertionError("Wait timed out");
    }

    void click(String name) {
        runOnMainSync(
                () -> {
                    View v = tag(name);
                    if (v == null) throw new AssertionError(name);
                    v.requestFocus();
                    v.performClick();
                });
        SystemClock.sleep(200);
    }

    void key(int code) {
        long end = SystemClock.elapsedRealtime() + 5000;
        while (SystemClock.elapsedRealtime() < end
                && !ui(
                        () ->
                                a.hasWindowFocus()
                                        || a.appDialog != null
                                        || a.accountDialog != null
                                        || a.sourceDialog != null
                                                && a.sourceDialog
                                                        .getWindow()
                                                        .getDecorView()
                                                        .hasWindowFocus())) SystemClock.sleep(100);
        if (!ui(
                () ->
                        a.hasWindowFocus()
                                || a.appDialog != null
                                || a.accountDialog != null
                                || a.sourceDialog != null
                                        && a.sourceDialog
                                                .getWindow()
                                                .getDecorView()
                                                .hasWindowFocus()))
            throw new AssertionError("Application lost window focus");
        sendKeyDownUpSync(code);
        SystemClock.sleep(300);
    }

    void pacedUp() {
        key(KeyEvent.KEYCODE_DPAD_UP);
        SystemClock.sleep(300);
    }

    void fastUp() {
        sendKeyDownUpSync(KeyEvent.KEYCODE_DPAD_UP);
        SystemClock.sleep(70);
    }

    boolean noNav() {
        return tag("nav-home") == null && tag("nav-settings") == null && tag("nav-search") == null;
    }

    void frame(String name) {
        runOnMainSync(
                () -> {
                    Bitmap b =
                            Bitmap.createBitmap(
                                    a.root.getWidth(), a.root.getHeight(), Bitmap.Config.ARGB_8888);
                    a.root.draw(new Canvas(b));
                    try (FileOutputStream out =
                            new FileOutputStream(
                                    new File(
                                            a.getExternalFilesDir(null),
                                            "home-" + name + ".png"))) {
                        b.compress(Bitmap.CompressFormat.PNG, 100, out);
                    } catch (Exception error) {
                        throw new RuntimeException(error);
                    } finally {
                        b.recycle();
                    }
                });
    }

    String listing(String prefix, int count, int page) throws Exception {
        JSONArray list = new JSONArray();
        for (int i = 0; i < count; i++)
            list.put(
                    new JSONObject()
                            .put("vod_id", prefix + "-" + page + "-" + i)
                            .put("vod_name", prefix + " · " + (i + 1))
                            .put("vod_pic", "https://fixture.test/poster.png")
                            .put("vod_remarks", "合成样本"));
        return new JSONObject().put("page", page).put("pagecount", 2).put("list", list).toString();
    }

    boolean fullLabel(TextView label) {
        android.text.Layout layout = label.getLayout();
        if (layout == null || layout.getLineCount() == 0) return false;
        for (int i = 0; i < layout.getLineCount(); i++)
            if (layout.getEllipsisCount(i) != 0) return false;
        return layout.getLineEnd(layout.getLineCount() - 1) == label.getText().length()
                && layout.getHeight()
                        <= label.getHeight()
                                - label.getCompoundPaddingTop()
                                - label.getCompoundPaddingBottom();
    }

    @Override
    public void onStart() {
        try {
            Context context = getTargetContext();
            // Context wrapping begins after attachBaseContext/Application creation. It cannot
            // isolate every process-global service: never run this on a user's installation.
            if (!isolatedTarget
                    || PrivacySpace.active
                    || !context.getSharedPreferences("movie", 0).getAll().isEmpty()
                    || !context.getSharedPreferences("movie-private", 0).getAll().isEmpty()
                    || new File(context.getFilesDir(), "config.json").exists())
                throw new AssertionError(
                        "HomeProbe requires -e isolated_target true and an empty dedicated test target; do not clear a user installation");
            SharedPreferences fixture = context.getSharedPreferences(fixtureNamespace, 0);
            fixturePrefs = fixture;
            check(
                    "fixture_defaults_written",
                    fixture.edit()
                            .putInt(Prefs.TV_NAVIGATION_MODE, 0)
                            .putInt(Prefs.TV_DOCK_POSITION, 0)
                            .putBoolean(Prefs.CAST_ENABLED, false)
                            .putBoolean(Prefs.STARTUP_ANIMATION, false)
                            .commit());
            result.put("fixture_namespace", fixtureNamespace);
            result.put("sdk_int", Build.VERSION.SDK_INT);
            result.put("device", Build.MANUFACTURER + "/" + Build.MODEL);
            result.put("input_scope", "instrumentation-injected keys; no physical remote claim");
            context.startActivity(
                    new Intent(context, MainActivity.class)
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
            if (!launched.await(15, TimeUnit.SECONDS)) throw new AssertionError("launch");
            runOnMainSync(
                    () -> {
                        a.prefs = fixture;
                        if (a.startupIntro != null) a.startupIntro.cancel();
                    });
            Cms.Site site = new Cms.Site();
            site.key = "home-fixture";
            site.name = "测试片库";
            site.api = "https://fixture.test/api";
            site.type = 1;
            Bitmap art = Bitmap.createBitmap(300, 450, Bitmap.Config.ARGB_8888);
            Canvas canvas = new Canvas(art);
            Paint p = new Paint(3);
            p.setShader(
                    new LinearGradient(
                            0, 0, 300, 450, 0xff42636a, 0xff272b35, Shader.TileMode.CLAMP));
            canvas.drawRect(0, 0, 300, 450, p);
            p.setShader(null);
            p.setColor(0xffd4d2c4);
            canvas.drawCircle(150, 130, 72, p);
            p.setColor(Color.WHITE);
            p.setTextSize(28);
            p.setTextAlign(Paint.Align.CENTER);
            canvas.drawText("山海之间", 150, 340, p);
            a.images.put("https://fixture.test/poster.png", art);
            JSONArray records = new JSONArray();
            for (int i = 0; i < 4; i++) {
                WatchHistory.Entry e = new WatchHistory.Entry();
                e.site = site.key;
                e.id = "history-" + i;
                e.title = "继续观看 · " + (i + 1);
                e.poster = "https://fixture.test/poster.png";
                e.episode = "第 6 集";
                e.line = "样本";
                e.position = 1200000;
                e.duration = 2400000;
                e.updated = System.currentTimeMillis();
                records.put(e.json());
            }
            final String savedRecords = records.toString();
            runOnMainSync(
                    () -> {
                        Cms.Config config = new Cms.Config();
                        config.raw = "{}";
                        config.sites.add(site);
                        a.config = config;
                        a.prefs
                                .edit()
                                .putBoolean("wallpaper_enabled", false)
                                .putBoolean("home_ambient", true)
                                .putString("selected_site", site.key)
                                .putString("watch_history", savedRecords)
                                .remove("home_columns")
                                .commit();
                        a.engines.put(
                                site.key,
                                new SourceEngine() {
                                    public String home() throws Exception {
                                        homeRequests.incrementAndGet();
                                        JSONObject o = new JSONObject(listing("推荐", 12, 1));
                                        JSONObject schemas = new JSONObject();
                                        JSONArray dimensions = new JSONArray();
                                        for (String[] item :
                                                new String[][] {
                                                    {"class", "类型", "剧情"},
                                                    {"area", "地区", "美国"},
                                                    {"year", "年份", "2026"}
                                                }) {
                                            dimensions.put(
                                                    new JSONObject()
                                                            .put("key", item[0])
                                                            .put("name", item[1])
                                                            .put(
                                                                    "value",
                                                                    new JSONArray()
                                                                            .put(
                                                                                    new JSONObject()
                                                                                            .put(
                                                                                                    "n",
                                                                                                    item[
                                                                                                            2])
                                                                                            .put(
                                                                                                    "v",
                                                                                                    item[
                                                                                                            2]))));
                                        }
                                        o.put("filters", schemas.put("c2", dimensions));
                                        JSONArray cats = new JSONArray();
                                        for (int i = 1; i <= 7; i++)
                                            cats.put(
                                                    new JSONObject()
                                                            .put("type_id", "c" + i)
                                                            .put(
                                                                    "type_name",
                                                                    new String[] {
                                                                                "豆瓣电影Top250",
                                                                                "电视剧",
                                                                                "动漫",
                                                                                "纪录片：自然地理、科学探索、人文历史与世界各地的真实故事，还有更多值得细看的精彩内容，分类名称完整展示验证，超长分类应自动增加高度并显示全部文字，不能通过省略号隐藏后半部分，也不能横向溢出或遮住右侧导航",
                                                                                "综艺",
                                                                                "其他",
                                                                                "空分类：这个分类的名称很长，用来验证更多分类弹窗与选中后的完整标题展示，不应隐藏任何文字"
                                                                            }
                                                                            [i - 1]));
                                        return o.put("class", cats).toString();
                                    }

                                    public String category(
                                            String id,
                                            int page,
                                            java.util.Map<String, String> filters)
                                            throws Exception {
                                        receivedFilters = new java.util.LinkedHashMap<>(filters);
                                        return category(id, page);
                                    }

                                    public String category(String id, int page) throws Exception {
                                        categoryRequests.incrementAndGet();
                                        if (id.equals("c1")) SystemClock.sleep(850);
                                        if (id.equals("c3") && failAnimeCategory) {
                                            failAnimeCategory = false;
                                            throw new IOException("fixture failure");
                                        }
                                        return listing(
                                                id, id.equals("c7") ? 0 : page == 1 ? 12 : 3, page);
                                    }

                                    public String search(String q, int page) throws Exception {
                                        return listing(q, 2, 1);
                                    }

                                    public boolean requiresExternalRuntime() {
                                        return false;
                                    }

                                    public String detail(String id) throws Exception {
                                        return new JSONObject()
                                                .put(
                                                        "list",
                                                        new JSONArray()
                                                                .put(
                                                                        new JSONObject()
                                                                                .put("vod_id", id)
                                                                                .put(
                                                                                        "vod_name",
                                                                                        "详情样本")
                                                                                .put(
                                                                                        "vod_pic",
                                                                                        "https://fixture.test/poster.png")
                                                                                .put(
                                                                                        "vod_content",
                                                                                        "用于检查返回后分类、焦点与位置恢复。")
                                                                                .put(
                                                                                        "vod_play_from",
                                                                                        "样本")
                                                                                .put(
                                                                                        "vod_play_url",
                                                                                        "第 1 集$https://fixture.test/sample.mp4")))
                                                .toString();
                                    }
                                });
                        a.back.clear();
                        a.open(new MainActivity.Screen(a::home), false);
                    });
            await(() -> tag("home-video:11") != null);
            SystemClock.sleep(300);
            check(
                    "initial_category_is_recommended",
                    ui(
                            () ->
                                    a.current.homeState.category.isEmpty()
                                            && tag("home-tab:0").isSelected()));
            check("initial_focus_on_recommended", ui(() -> tag("home-tab:0").hasFocus()));
            // Dispatch through the Activity: home navigation consumes these keys before
            // any tab OnKeyListener. No confirmation key should be needed to switch.
            key(KeyEvent.KEYCODE_DPAD_RIGHT);
            await(() -> a.current.homeState.category.equals("c1"));
            check("right_focus_selects_movie", ui(() -> tag("home-tab:1").hasFocus()));
            key(KeyEvent.KEYCODE_DPAD_RIGHT);
            await(() -> a.current.homeState.ready && a.current.homeState.category.equals("c2"));
            check(
                    "right_focus_selects_series_content",
                    ui(
                            () ->
                                    tag("home-tab:2").hasFocus()
                                            && a.current
                                                    .homeState
                                                    .videos
                                                    .get(0)
                                                    .title
                                                    .startsWith("c2")));
            SystemClock.sleep(900);
            check(
                    "focus_switch_rejects_late_movie_content",
                    ui(
                            () ->
                                    a.current.homeState.category.equals("c2")
                                            && a.current
                                                    .homeState
                                                    .videos
                                                    .get(0)
                                                    .title
                                                    .startsWith("c2")));
            key(KeyEvent.KEYCODE_DPAD_LEFT);
            await(() -> a.current.homeState.ready && a.current.homeState.category.equals("c1"));
            check("left_focus_selects_movie", ui(() -> tag("home-tab:1").hasFocus()));
            SystemClock.sleep(400);
            runOnMainSync(() -> tag("home-tab:2").requestFocus());
            await(() -> a.current.homeState.ready && a.current.homeState.category.equals("c2"));
            check(
                    "focus_without_recent_key_selects_category",
                    ui(() -> tag("home-tab:2").hasFocus()));
            int requestsAfterFocus = categoryRequests.get();
            key(KeyEvent.KEYCODE_DPAD_CENTER);
            check(
                    "confirm_after_focus_does_not_reload",
                    categoryRequests.get() == requestsAfterFocus);
            check(
                    "category_selection_is_immediate",
                    ui(
                            () -> {
                                tag("home-tab:1").requestFocus();
                                return a.current.homeState.category.equals("c1")
                                        && tag("home-tab:1").isSelected();
                            }));
            runOnMainSync(() -> tag("source-switcher").requestFocus());
            SystemClock.sleep(250);
            check(
                    "leaving_category_keeps_immediate_selection",
                    ui(
                            () ->
                                    a.current.homeState.category.equals("c1")
                                            && tag("source-switcher").hasFocus()));
            check(
                    "concrete_category_collapses_inline_filters_by_default",
                    ui(
                            () ->
                                    tag("home-filters") == null
                                            && tag("home-category-more") == null
                                            && tag("home-tab:7") != null
                                            && !tag("home-inline-filters").isShown()));
            click("home-tab:1");
            check(
                    "clicking_selected_category_expands_inline_filters",
                    ui(() -> tag("home-inline-filters").isShown()));
            runOnMainSync(() -> tag("home-filter:class:0").requestFocus());
            SystemClock.sleep(250);
            check(
                    "filter_focus_does_not_open_or_switch",
                    ui(() -> a.appDialog == null && a.current.homeState.category.equals("c1")));
            runOnMainSync(() -> tag("home-tab:0").requestFocus());
            await(
                    () ->
                            a.current.homeState.ready
                                    && a.current.homeState.category.isEmpty()
                                    && !tag("home-inline-filters").isShown()
                                    && tag("home-video:11") != null);
            check(
                    "history_has_four_cards_in_one_list",
                    ui(
                            () ->
                                    ((ViewGroup) tag("home-history-list")).getChildCount() == 4
                                            && tag("home-history:3") != null
                                            && tag("home-history:4") == null));
            check(
                    "newest_history_is_first_and_resumable",
                    ui(
                            () -> {
                                ViewGroup historyRow = (ViewGroup) tag("home-history-list");
                                return historyRow.getChildAt(0) == tag("home-history:0")
                                        && historyRow.getChildAt(0).hasOnClickListeners()
                                        && ((TextView) tag("home-history-title"))
                                                .getText()
                                                .toString()
                                                .equals("历史记录")
                                        && ((ViewGroup) tag("home-history-section")).getChildCount()
                                                == 3;
                            }));
            check(
                    "history_does_not_duplicate_latest",
                    ui(
                            () ->
                                    tag("home-history:0")
                                                    .getContentDescription()
                                                    .toString()
                                                    .startsWith("继续观看 · 1")
                                            && tag("home-history:1")
                                                    .getContentDescription()
                                                    .toString()
                                                    .startsWith("继续观看 · 2")));
            check("home_has_navigation", ui(() -> tag("nav-home") != null));
            check(
                    "history_compact_landscape",
                    ui(
                            () ->
                                    tag("home-history:0").getWidth()
                                            > tag("home-history:0").getHeight() * 2));
            check(
                    "five_columns",
                    ui(() -> ((ViewGroup) tag("home-video:0").getParent()).getChildCount() == 5));
            check(
                    "portrait_ratio",
                    ui(
                            () -> {
                                View image = ((ViewGroup) tag("home-video:0")).getChildAt(0);
                                return Math.abs(image.getHeight() / (float) image.getWidth() - 1.5)
                                        < .02;
                            }));
            check(
                    "larger_posters",
                    ui(
                            () ->
                                    ((ViewGroup) tag("home-video:0")).getChildAt(0).getWidth()
                                            >= a.dp(145)));
            check("dock_fixed_outside_scroll", ui(() -> tag("home-dock").getParent() == a.root));
            check(
                    "dock_right_and_compact",
                    ui(
                            () ->
                                    tag("home-dock").getWidth() <= a.dp(56)
                                            && tag("home-dock").getRight()
                                                    <= a.root.getWidth() - a.dp(19)));
            check(
                    "dock_does_not_overlap_posters",
                    ui(
                            () -> {
                                int[] card = {0, 0}, dock = {0, 0};
                                tag("home-video:4").getLocationOnScreen(card);
                                tag("home-dock").getLocationOnScreen(dock);
                                return card[0] + tag("home-video:4").getWidth() + a.dp(12)
                                        < dock[0];
                            }));
            check(
                    "icon_labels_accessible",
                    ui(
                            () ->
                                    tag("nav-search")
                                                    .getContentDescription()
                                                    .toString()
                                                    .equals("搜索")
                                            && !(tag("nav-search") instanceof TextView)));
            runOnMainSync(() -> tag("home-video:4").requestFocus());
            key(KeyEvent.KEYCODE_DPAD_RIGHT);
            check("row_right_enters_dock", ui(() -> tag("nav-home").hasFocus()));
            key(KeyEvent.KEYCODE_DPAD_DOWN);
            check("dock_down_moves_to_search", ui(() -> tag("nav-search").hasFocus()));
            check(
                    "focus_label_visible",
                    ui(
                            () ->
                                    tag("home-dock-label").getVisibility() == View.VISIBLE
                                            && ((TextView) tag("home-dock-label"))
                                                    .getText()
                                                    .toString()
                                                    .equals("搜索")));
            check(
                    "page_marker_independent_of_focus",
                    ui(() -> tag("nav-home").isSelected() && !tag("nav-search").isSelected()));
            check(
                    "label_compact_and_aligned",
                    ui(
                            () -> {
                                View label = tag("home-dock-label"), icon = tag("nav-search");
                                int[] l = {0, 0}, i = {0, 0};
                                label.getLocationOnScreen(l);
                                icon.getLocationOnScreen(i);
                                return label.getHeight() <= a.dp(28)
                                        && Math.abs(
                                                        l[1]
                                                                + label.getHeight() / 2
                                                                - i[1]
                                                                - icon.getHeight() / 2)
                                                <= 2
                                        && l[0] + label.getWidth() < i[0];
                            }));
            frame("dock-focus");
            key(KeyEvent.KEYCODE_DPAD_LEFT);
            check("dock_left_restores_exact_card", ui(() -> tag("home-video:4").hasFocus()));
            check(
                    "focus_label_hides_in_content",
                    ui(() -> tag("home-dock-label").getVisibility() != View.VISIBLE));
            runOnMainSync(() -> tag("home-video:11").requestFocus());
            key(KeyEvent.KEYCODE_DPAD_RIGHT);
            check("partial_row_enters_dock", ui(() -> tag("nav-home").hasFocus()));
            click("nav-settings");
            check("dock_hidden_on_secondary", ui(() -> tag("home-dock") == null));
            key(KeyEvent.KEYCODE_BACK);
            await(() -> tag("nav-settings") != null);
            key(KeyEvent.KEYCODE_DPAD_LEFT);
            check(
                    "secondary_back_then_left_restores_card",
                    ui(() -> tag("home-video:11").hasFocus()));
            click("nav-accounts");
            SystemClock.sleep(350);
            check(
                    "account_panel_inside_screen",
                    ui(
                            () -> {
                                View v = a.accountDialog.findViewById(android.R.id.content);
                                int[] xy = {0, 0};
                                v.getLocationOnScreen(xy);
                                return xy[0] >= 0
                                        && xy[1] >= 0
                                        && xy[0] + v.getWidth() <= a.root.getWidth()
                                        && xy[1] + v.getHeight() <= a.root.getHeight();
                            }));
            frame("accounts");
            runOnMainSync(() -> a.accountDialog.dismiss());
            check("account_dismiss_restores_icon", ui(() -> tag("nav-accounts").hasFocus()));
            key(KeyEvent.KEYCODE_DPAD_LEFT);
            check("account_left_restores_card", ui(() -> tag("home-video:11").hasFocus()));
            runOnMainSync(
                    () -> {
                        a.scroll.scrollTo(0, 0);
                        tag("home-history:0").requestFocus();
                    });
            check(
                    "source_beside_discover",
                    ui(
                            () -> {
                                View v = tag("source-switcher");
                                return v.getLeft() < a.dp(100) && v.getWidth() <= a.dp(220);
                            }));
            check(
                    "category_long_title_complete",
                    ui(
                            () ->
                                    fullLabel((TextView) tag("home-tab:1"))
                                            && ((TextView) tag("home-tab:1"))
                                                    .getText()
                                                    .toString()
                                                    .equals("豆瓣电影Top250")));
            check(
                    "all_categories_shown_in_single_scrollable_row",
                    ui(
                            () ->
                                    tag("home-category-scroll") != null
                                            && tag("home-category-more") == null
                                            && tag("home-tab:7") != null
                                            && fullLabel((TextView) tag("home-tab:4"))
                                            && fullLabel((TextView) tag("home-tab:7"))
                                            && ((TextView) tag("home-tab:4")).getLineCount() == 1
                                            && tag("home-tab:4").getTop()
                                                    == tag("home-tab:0").getTop()
                                            && tag("home-tab:7").getTop()
                                                    == tag("home-tab:0").getTop()));
            runOnMainSync(() -> tag("home-tab:4").requestFocus());
            await(
                    () ->
                            a.current.homeState.category.equals(
                                    a.current.retainedHome.tabIds.get(a.getCurrentFocus())));
            check(
                    "single_row_category_focus_selects_category",
                    ui(() -> a.getCurrentFocus().isSelected()));
            pacedUp();
            check(
                    "single_row_category_up_reaches_source",
                    ui(() -> tag("source-switcher").hasFocus()));
            runOnMainSync(() -> tag("home-tab:0").requestFocus());
            await(
                    () ->
                            a.current.homeState.ready
                                    && a.current.homeState.category.isEmpty()
                                    && tag("home-video:11") != null);
            check(
                    "source_has_visible_dropdown",
                    ui(
                            () ->
                                    ((TextView) tag("source-switcher")).getCompoundDrawables()[2]
                                            != null));
            check(
                    "ambient_home_only",
                    ui(() -> a.homeAmbient != null && tag("home-ambient") != null));
            runOnMainSync(() -> tag("home-video:0").requestFocus());
            await(() -> a.homeAmbient.applied > 0);
            check(
                    "ambient_uses_loaded_poster",
                    ui(
                            () ->
                                    a.homeAmbient.wanted
                                            == ((ViewGroup) tag("home-video:0")).getChildAt(0)));
            final int[] warm = {0}, cool = {0};
            runOnMainSync(
                    () -> {
                        Bitmap red = Bitmap.createBitmap(24, 24, Bitmap.Config.ARGB_8888);
                        red.eraseColor(0xffc05030);
                        Bitmap blue = Bitmap.createBitmap(24, 24, Bitmap.Config.ARGB_8888);
                        blue.eraseColor(0xff3060c0);
                        warm[0] = HomeAmbient.sample(red, 0);
                        cool[0] = HomeAmbient.sample(blue, 0);
                        red.recycle();
                        blue.recycle();
                    });
            check(
                    "ambient_colors_follow_art_and_stay_dim",
                    warm[0] != cool[0] && Color.red(warm[0]) <= 64 && Color.blue(cool[0]) <= 64);
            check(
                    "ambient_reduced_motion_is_static",
                    ui(
                            () -> {
                                a.reduced = true;
                                a.homeAmbient.transition(warm[0], cool[0]);
                                // Check the requested colors in the same UI task: a queued
                                // posterReady may legitimately choose new colors afterwards.
                                return !a.homeAmbient.loopRunning
                                        && a.homeAmbient.morphProgress >= 1f
                                        && a.homeAmbient.left == warm[0]
                                        && a.homeAmbient.right == cool[0];
                            }));
            SystemClock.sleep(250);
            check(
                    "ambient_pending_poster_remains_static",
                    ui(() -> !a.homeAmbient.loopRunning && a.homeAmbient.morphProgress >= 1f));
            runOnMainSync(() -> a.reduced = a.prefs.getBoolean("reduced", false));
            frame("overview");
            runOnMainSync(() -> tag("home-video:0").requestFocus());
            String source = ((TextView) tag("source-switcher")).getText().toString();
            key(KeyEvent.KEYCODE_DPAD_RIGHT);
            check(
                    "source_label_stable",
                    ui(
                            () ->
                                    source.equals(
                                            ((TextView) tag("source-switcher"))
                                                    .getText()
                                                    .toString())));
            pacedUp();
            check("poster_up_to_category", ui(() -> tag("home-tab:0").hasFocus()));
            pacedUp();
            check("category_up_to_source", ui(() -> tag("source-switcher").hasFocus()));
            pacedUp();
            check("source_up_to_history", ui(() -> tag("home-history:0").hasFocus()));
            runOnMainSync(() -> a.current.homeState.categoryCache.remove("c1"));
            click("home-tab:1");
            click("home-tab:2");
            await(() -> a.current.homeState.ready && a.current.homeState.category.equals("c2"));
            SystemClock.sleep(1000);
            check(
                    "late_category_cannot_overwrite",
                    ui(() -> a.current.homeState.videos.get(0).id.startsWith("c2")));
            View beforeAppend = tag("home-video:0");
            check(
                    "load_more_button_not_shown_before_auto_page",
                    ui(() -> !tag("home-load-more").isShown()));
            runOnMainSync(() -> tag("home-video:10").requestFocus());
            await(() -> tag("home-video:14") != null);
            check("pagination_keeps_existing_cards", ui(() -> tag("home-video:0") == beforeAppend));
            check(
                    "pagination_appends",
                    ui(
                            () ->
                                    a.current.homeState.videos.size() == 15
                                            && a.current.homeState.page == 2));
            check("page_end_hides_more", ui(() -> !tag("home-load-more").isShown()));
            runOnMainSync(() -> tag("home-video:14").requestFocus());
            SystemClock.sleep(300);
            check("scrolled_down_before_return", ui(() -> a.scroll.getScrollY() > a.dp(100)));
            for (int i = 0; i < 5; i++) pacedUp();
            SystemClock.sleep(500);
            check("up_from_deep_grid_reaches_history", ui(() -> tag("home-history:0").hasFocus()));
            check("up_restores_absolute_top", ui(() -> a.scroll.getScrollY() == 0));
            check(
                    "logo_and_history_visible_after_up",
                    ui(
                            () -> {
                                android.graphics.Rect logo = new android.graphics.Rect(),
                                        historyBox = new android.graphics.Rect();
                                return tag("home-brand").getGlobalVisibleRect(logo)
                                        && logo.height() == tag("home-brand").getHeight()
                                        && tag("home-history:0").getGlobalVisibleRect(historyBox)
                                        && historyBox.height()
                                                >= tag("home-history:0").getHeight() - 2;
                            }));
            pacedUp();
            SystemClock.sleep(300);
            check("top_up_keeps_logo_visible", ui(() -> a.scroll.getScrollY() == 0));
            frame("history-top");
            runOnMainSync(() -> tag("nav-settings").requestFocus());
            fastUp();
            fastUp();
            fastUp();
            check(
                    "tv_three_up_follows_three_navigation_rows",
                    ui(() -> tag("nav-favorites").hasFocus()));
            key(KeyEvent.KEYCODE_MENU);
            check(
                    "menu_opens_source_chooser",
                    ui(
                            () ->
                                    a.sourceDialog != null
                                            && a.sourceDialog.isShowing()
                                            && a.sourceDialog
                                                            .findViewById(android.R.id.content)
                                                            .findViewWithTag(
                                                                    "source-choice:home-fixture")
                                                    != null));
            key(KeyEvent.KEYCODE_BACK);
            check(
                    "source_menu_back_preserves_home",
                    ui(() -> a.sourceDialog == null && a.current.home));

            View retainedHome = a.root;
            int homeCount = homeRequests.get(), categoryCount = categoryRequests.get();
            click("home-video:11");
            await(() -> tag("detail-favorite") != null);
            check("details_hide_nav", ui(this::noNav));
            check("ambient_not_on_detail", ui(() -> tag("home-ambient") == null));
            key(KeyEvent.KEYCODE_BACK);
            await(() -> tag("home-video:14") != null);
            check(
                    "back_restores_category_and_pages",
                    ui(
                            () ->
                                    a.current.homeState.category.equals("c2")
                                            && a.current.homeState.page == 2));
            check("back_restores_card_focus", ui(() -> tag("home-video:11").hasFocus()));
            check("back_reattaches_same_home_tree", ui(() -> a.root == retainedHome));
            check(
                    "detail_return_sends_no_catalogue_requests",
                    homeRequests.get() == homeCount && categoryRequests.get() == categoryCount);
            click("home-video:11");
            await(() -> tag("detail-favorite") != null);
            runOnMainSync(
                    () -> {
                        WatchHistory.Entry watched = new WatchHistory.Entry();
                        watched.site = "home-fixture";
                        watched.id = "c2-1-11";
                        watched.title = "刚看完的新片";
                        watched.poster = "https://fixture.test/poster.png";
                        watched.line = "样本";
                        watched.episode = "第 1 集";
                        watched.position = 120000;
                        watched.duration = 120000;
                        watched.updated = System.currentTimeMillis();
                        a.prefs
                                .edit()
                                .putString(
                                        Prefs.WATCH_HISTORY,
                                        WatchHistory.upsert(
                                                a.prefs.getString(Prefs.WATCH_HISTORY, "[]"),
                                                watched))
                                .commit();
                    });
            key(KeyEvent.KEYCODE_BACK);
            await(() -> tag("home-history:0") != null);
            check(
                    "resume_refreshes_watch_history_immediately",
                    ui(
                            () ->
                                    a.root == retainedHome
                                            && tag("home-history:0")
                                                    .getContentDescription()
                                                    .toString()
                                                    .startsWith("刚看完的新片")));
            runOnMainSync(() -> tag("home-tab:2").requestFocus());
            check(
                    "focus_category_keeps_filters_collapsed",
                    ui(() -> !tag("home-inline-filters").isShown()));
            click("home-tab:2");
            await(
                    () ->
                            tag("home-inline-filters").isShown()
                                    && tag("home-filter:class:0") != null
                                    && tag("home-filter:class:0").getWidth() > 0);
            check(
                    "filters_expand_as_three_inline_rows",
                    ui(
                            () ->
                                    a.appDialog == null
                                            && a.current.retainedHome.inlineFilters.getChildCount()
                                                    == 3
                                            && tag("home-inline-filters").getTop()
                                                    >= tag("home-category-scroll").getBottom()));
            key(KeyEvent.KEYCODE_DPAD_DOWN);
            check(
                    "category_down_enters_first_filter_row",
                    ui(
                            () ->
                                    String.valueOf(a.getCurrentFocus().getTag())
                                            .startsWith("home-filter:class:")));
            key(KeyEvent.KEYCODE_DPAD_DOWN);
            check(
                    "inline_filter_down_enters_area_row",
                    ui(
                            () ->
                                    String.valueOf(a.getCurrentFocus().getTag())
                                            .startsWith("home-filter:area:")));
            key(KeyEvent.KEYCODE_DPAD_DOWN);
            check(
                    "inline_filter_down_enters_year_row",
                    ui(
                            () ->
                                    String.valueOf(a.getCurrentFocus().getTag())
                                            .startsWith("home-filter:year:")));
            for (int dimension = 0; dimension < 3; dimension++) {
                final int choice = dimension;
                String option = "home-filter:" + VideoFilters.DIMENSIONS[choice] + ":1";
                click(option);
                await(
                        () ->
                                a.current.homeState.ready
                                        && a.current.homeState.selectedFilters.size() == choice + 1
                                        && tag("home-video:2") != null);
                check(
                        "filter_selection_keeps_row_focus_" + choice,
                        ui(() -> tag(option).hasFocus() && tag(option).isSelected()));
            }
            frame("inline-filters-expanded");
            check(
                    "all_three_tv_filters_reach_engine",
                    receivedFilters.size() == 3 && receivedFilters.get("year").equals("2026"));
            key(KeyEvent.KEYCODE_DPAD_DOWN);
            check(
                    "last_filter_row_down_enters_posters_and_folds_summary",
                    ui(
                            () ->
                                    String.valueOf(a.getCurrentFocus().getTag())
                                                    .startsWith("home-video:")
                                            && tag("home-filter-summary") != null
                                            && tag("home-filter-expand") != null
                                            && tag("home-filter-reset") != null
                                            && ((TextView) tag("home-filter-summary-text"))
                                                    .getText()
                                                    .toString()
                                                    .startsWith("已选：")));
            key(KeyEvent.KEYCODE_DPAD_UP);
            check(
                    "poster_up_targets_filter_summary_expand",
                    ui(() -> tag("home-filter-expand").hasFocus()));
            View filteredHome = a.root;
            int filteredCount = categoryRequests.get();
            click("home-video:2");
            await(() -> tag("detail-favorite") != null);
            key(KeyEvent.KEYCODE_BACK);
            await(() -> tag("home-video:2") != null);
            check(
                    "filtered_home_stays_resident",
                    ui(
                            () ->
                                    a.root == filteredHome
                                            && a.current.homeState.selectedFilters.size() == 3
                                            && tag("home-video:2").hasFocus()));
            check("filtered_return_does_not_reload", categoryRequests.get() == filteredCount);
            check(
                    "filter_summary_stays_visible_on_detail_return",
                    ui(
                            () ->
                                    tag("home-inline-filters").isShown()
                                            && tag("home-filter-summary") != null));
            click("home-filter-expand");
            check(
                    "summary_expand_reopens_existing_selection",
                    ui(
                            () ->
                                    tag("home-inline-filters").isShown()
                                            && tag("home-filter:year:1") != null
                                            && tag("home-filter:year:1").isSelected()));
            runOnMainSync(() -> tag("home-video:0").requestFocus());
            await(() -> tag("home-filter-reset") != null);
            click("home-filter-reset");
            await(
                    () ->
                            a.current.homeState.ready
                                    && a.current.homeState.selectedFilters.isEmpty()
                                    && tag("home-video:0") != null);
            check(
                    "summary_reset_clears_filters_and_hides_bar",
                    ui(() -> !tag("home-inline-filters").isShown()));

            runOnMainSync(
                    () -> {
                        failAnimeCategory = true;
                        a.current.homeState.categoryCache.remove("c3");
                    });
            click("home-tab:3");
            await(() -> tag("home-load-more").isShown());
            check(
                    "failure_has_retry",
                    ui(
                            () ->
                                    ((TextView) tag("home-load-more"))
                                            .getText()
                                            .toString()
                                            .equals("重新加载")));
            click("home-load-more");
            await(() -> a.current.homeState.ready);
            check(
                    "retry_recovers",
                    ui(() -> a.current.homeState.videos.get(0).id.startsWith("c3")));
            click("home-tab:7");
            await(
                    () ->
                            a.current.homeState.ready
                                    && a.current.homeState.category.equals("c7")
                                    && ((HorizontalScrollView) tag("home-category-scroll"))
                                                    .getScrollX()
                                            > 0);
            check("empty_category_no_stale_posters", ui(() -> tag("home-video:0") == null));
            check(
                    "direct_tail_category_scrolled_and_complete",
                    ui(
                            () ->
                                    tag("home-category-more") == null
                                            && ((HorizontalScrollView) tag("home-category-scroll"))
                                                            .getScrollX()
                                                    > 0
                                            && fullLabel((TextView) tag("home-tab:7"))));
            click("home-tab:0");
            await(() -> tag("home-video:0") != null);
            click("nav-search");
            check("search_hides_nav", ui(this::noNav));
            check("search_has_focus", ui(() -> a.getCurrentFocus() != null));
            key(KeyEvent.KEYCODE_BACK);
            await(() -> tag("nav-home") != null);
            click("nav-favorites");
            check("favorites_hide_nav", ui(this::noNav));
            key(KeyEvent.KEYCODE_BACK);
            await(() -> tag("nav-home") != null);
            click("nav-live");
            check("live_hides_nav", ui(this::noNav));
            key(KeyEvent.KEYCODE_BACK);
            await(() -> tag("nav-home") != null);
            click("nav-settings");
            check("settings_hide_nav", ui(this::noNav));
            check("settings_has_focus", ui(() -> a.getCurrentFocus() != null));
            frame("settings");
            click("settings-appearance");
            check("nested_settings_hide_nav", ui(this::noNav));
            key(KeyEvent.KEYCODE_BACK);
            check("back_to_settings_no_nav", ui(this::noNav));
            key(KeyEvent.KEYCODE_BACK);
            await(() -> tag("nav-home") != null);
            check("home_restores_nav_focus", ui(() -> tag("nav-settings").hasFocus()));
            click("home-history-all");
            check("history_hides_nav", ui(this::noNav));
            key(KeyEvent.KEYCODE_BACK);
            await(() -> tag("home-history:0") != null);
            final String singleRecord = new JSONArray().put(records.getJSONObject(0)).toString();
            runOnMainSync(
                    () -> {
                        a.prefs.edit().putString("watch_history", singleRecord).commit();
                        a.refresh();
                    });
            await(() -> tag("home-video:11") != null);
            check(
                    "one_history_entry_has_no_empty_continuation_area",
                    ui(
                            () ->
                                    ((ViewGroup) tag("home-history-list")).getChildCount() == 1
                                            && tag("home-history:0") != null
                                            && tag("home-history:1") == null
                                            && ((ViewGroup) tag("home-history-section"))
                                                            .getChildCount()
                                                    == 3));
            runOnMainSync(
                    () -> {
                        a.prefs.edit().putString("watch_history", "[]").commit();
                        a.refresh();
                    });
            await(() -> tag("home-video:11") != null);
            check("no_history_no_blank_section", ui(() -> tag("home-history:0") == null));
            runOnMainSync(() -> tag("home-video:11").requestFocus());
            SystemClock.sleep(250);
            for (int i = 0; i < 5; i++) pacedUp();
            SystemClock.sleep(400);
            check("no_history_up_reveals_logo", ui(() -> a.scroll.getScrollY() == 0));
            runOnMainSync(() -> tag("nav-settings").requestFocus());
            fastUp();
            fastUp();
            fastUp();
            check(
                    "tv_no_history_three_up_keeps_navigation_focus",
                    ui(() -> tag("nav-favorites").hasFocus()));
            frame("no-history");
            runOnMainSync(
                    () -> {
                        a.prefs.edit().putBoolean("wallpaper_enabled", true).commit();
                        a.refresh();
                    });
            check("custom_wallpaper_takes_priority", ui(() -> tag("home-ambient") == null));
            runOnMainSync(
                    () -> {
                        a.prefs
                                .edit()
                                .putBoolean("wallpaper_enabled", false)
                                .putBoolean("home_ambient", false)
                                .commit();
                        a.refresh();
                    });
            check("ambient_can_be_disabled", ui(() -> tag("home-ambient") == null));
            SourceEngine originalFixture = a.engines.get(site.key);
            for (int round = 0; round < 10; round++) {
                CountDownLatch requested = new CountDownLatch(1), deliver = new CountDownLatch(1);
                runOnMainSync(
                        () -> {
                            a.engines.put(
                                    site.key,
                                    new SourceEngine() {
                                        public String home() throws Exception {
                                            requested.countDown();
                                            if (!deliver.await(5, TimeUnit.SECONDS))
                                                throw new IOException("fixture delivery timeout");
                                            return listing("迟到推荐", 12, 1);
                                        }

                                        public String category(String id, int page) {
                                            return "{}";
                                        }

                                        public String search(String q, int page) {
                                            return "{}";
                                        }

                                        public String detail(String id) {
                                            return "{}";
                                        }

                                        public boolean requiresExternalRuntime() {
                                            return false;
                                        }
                                    });
                            a.homeData.remove(site.key);
                            a.open(new MainActivity.Screen(a::home), false);
                        });
                try {
                    if (!requested.await(5, TimeUnit.SECONDS))
                        throw new AssertionError("home request not started");
                    runOnMainSync(() -> tag("nav-accounts").requestFocus());
                    deliver.countDown();
                    await(() -> tag("home-video:11") != null);
                    SystemClock.sleep(100);
                    check(
                            "late_home_preserves_user_dock_focus_" + round,
                            ui(() -> tag("nav-accounts").hasFocus()));
                } finally {
                    deliver.countDown();
                }
            }
            runOnMainSync(
                    () -> {
                        a.engines.put(site.key, originalFixture);
                        a.homeData.remove(site.key);
                    });
            glassNavigation();
            readingScroll();
            sectionPagingRegression();
            result.put("passed", true);
        } catch (Throwable e) {
            try {
                result.put("passed", false)
                        .put("error", e.toString())
                        .put("error_stack", android.util.Log.getStackTraceString(e));
            } catch (Exception ignored) {
            }
            if (activeSectionFixture != null) captureSectionFailure();
        } finally {
            if (a != null) {
                runOnMainSync(
                        () -> {
                            if (a.sourceDialog != null) a.sourceDialog.dismiss();
                            if (a.appDialog != null) a.appDialog.dismiss();
                            a.ui.removeCallbacks(a.learnPendingTitles);
                            a.pendingTitles.clear();
                            a.cancelArtwork();
                            a.finish(); // Keep fixture prefs through onStop/onDestroy; never
                            // reopen user home.
                        });
            }
        }
        Bundle report = new Bundle();
        report.putString("result", result.toString());
        sendStatus(0, report);
        finish(Activity.RESULT_OK, new Bundle());
    }

    // Cms.listing accepts at most 500 items per response. Keep the 2001-item case
    // cumulative: all five pages must pass through the real parser and HomeScreen.
    String sectionListing(boolean wide, int page) throws Exception {
        if (!wide) return listing("section", page == 1 ? 40 : 5, page);
        if (page < 1 || page > 5) throw new IOException("unexpected section window page: " + page);
        return new JSONObject(listing("section", page < 5 ? 500 : 1, page))
                .put("pagecount", 5)
                .toString();
    }

    void verifySectionPageContract() throws Exception {
        java.util.Set<String> ids = new java.util.HashSet<>();
        JSONArray sizes = new JSONArray();
        for (int page = 1; page <= 5; page++) {
            Cms.Listing parsed = Cms.listing(sectionListing(true, page));
            sizes.put(parsed.videos.size());
            check(
                    "section_window_page_" + page + "_valid_cms_response",
                    parsed.page == page
                            && parsed.pageCount == 5
                            && parsed.videos.size() == (page < 5 ? 500 : 1));
            for (Cms.Video video : parsed.videos)
                if (!ids.add(video.id))
                    throw new AssertionError("duplicate section fixture id: " + video.id);
        }
        result.put("section_window_response_sizes", sizes);
        check("section_window_fixture_has_2001_unique_items", ids.size() == 2001);
    }

    /** Real HomeScreen + SourceEngine boundary; native reruns remain required after fixture changes. */
    final class SectionFixture implements SourceEngine {
        final boolean wide;
        final java.util.concurrent.atomic.AtomicInteger requests =
                new java.util.concurrent.atomic.AtomicInteger();
        final java.util.List<String> trace =
                java.util.Collections.synchronizedList(new java.util.ArrayList<String>());
        volatile CountDownLatch hold;
        volatile boolean failNext;

        SectionFixture(boolean wide) {
            this.wide = wide;
        }

        public String home() throws Exception {
            return new JSONObject(listing("section-home", 12, 1))
                    .put("pagecount", 1)
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
            trace.add(SystemClock.uptimeMillis() + ":request:" + id + ":" + page);
            CountDownLatch wait = hold;
            if (wait != null && !wait.await(10, TimeUnit.SECONDS))
                throw new IOException("section fixture release timeout");
            if (failNext) {
                failNext = false;
                trace.add(SystemClock.uptimeMillis() + ":failure:" + page);
                throw new IOException("section paging intentional failure");
            }
            trace.add(SystemClock.uptimeMillis() + ":response:" + page);
            return sectionListing(wide, page);
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
    }

    HomeScreen retained() {
        return a.current.retainedHome;
    }

    // Diagnostic-only reads: never repair focus, pump paging or change a timeout here.
    JSONObject sectionViewDiagnostic(View view) throws Exception {
        JSONObject out = new JSONObject().put("present", view != null);
        if (view == null) return out;
        Rect rect = new Rect(), screen = new Rect();
        if (a.root != null) a.root.getGlobalVisibleRect(screen);
        boolean visible = view.getGlobalVisibleRect(rect);
        Rect intersection = new Rect(rect);
        return out.put("tag", String.valueOf(view.getTag()))
                .put("id", view.getId())
                .put("shown", view.isShown())
                .put("enabled", view.isEnabled())
                .put("focusable", view.isFocusable())
                .put("has_focus", view.hasFocus())
                .put("attached", view.isAttachedToWindow())
                .put("laid_out", view.isLaidOut())
                .put("width", view.getWidth())
                .put("height", view.getHeight())
                .put("alpha", view.getAlpha())
                .put("rect", rect.toShortString())
                .put("intersects_screen", visible && intersection.intersect(screen))
                .put("next_down_id", view.getNextFocusDownId());
    }

    void captureSectionFailure() {
        // Preserve the original failure even when diagnostic collection itself fails.
        JSONObject diagnostic = new JSONObject();
        try {
            diagnostic
                    .put("stage", result.optString("section_stage"))
                    .put("wait", sectionWait)
                    .put("uptime_ms", SystemClock.uptimeMillis());
            runOnMainSync(
                    () -> {
                        try {
                            diagnostic.put("activity_present", a != null);
                            if (a == null) return;
                            diagnostic
                                    .put("generation", a.generation)
                                    .put("window_focus", a.hasWindowFocus())
                                    .put("layout_ready", a.layoutReady)
                                    .put("focus", sectionViewDiagnostic(a.getCurrentFocus()));
                            HomeScreen h = a.current == null ? null : a.current.retainedHome;
                            diagnostic.put("retained_home_present", h != null);
                            if (h == null || h.state == null) return;
                            diagnostic
                                    .put("library", h.state.library)
                                    .put("category", h.state.category)
                                    .put("page", h.state.page)
                                    .put("pages", h.state.pages)
                                    .put("items", h.state.videos.size())
                                    .put("ready", h.state.ready)
                                    .put("busy", h.busy)
                                    .put("window_start", h.state.windowStart)
                                    .put("window_end", h.windowEnd())
                                    .put("grid_epoch", h.gridEpoch)
                                    .put("pending_grid", h.pendingGrid != null)
                                    .put("rows", h.rows.size())
                                    .put(
                                            "pending_focus",
                                            h.pendingFocus == null
                                                    ? JSONObject.NULL
                                                    : h.pendingFocus);
                            int cards = 0;
                            for (java.util.List<View> row : h.rows) cards += row.size();
                            diagnostic
                                    .put("rendered_cards", cards)
                                    .put(
                                            "last_card",
                                            sectionViewDiagnostic(
                                                    tag("home-video:" + (h.windowEnd() - 1))))
                                    .put(
                                            "status",
                                            h.status == null ? "" : h.status.getText().toString());
                            if (a.scroll != null)
                                diagnostic
                                        .put("scroll_y", a.scroll.getScrollY())
                                        .put("scroll_height", a.scroll.getHeight());
                            diagnostic.put(
                                    "category_requests", activeSectionFixture.requests.get());
                            synchronized (activeSectionFixture.trace) {
                                diagnostic.put(
                                        "request_trace", new JSONArray(activeSectionFixture.trace));
                            }
                        } catch (Exception error) {
                            try {
                                diagnostic.put("state_error", error.toString());
                            } catch (Exception ignored) {
                            }
                        }
                    });
            Bitmap image = getUiAutomation().takeScreenshot();
            if (image == null) throw new IOException("failure screenshot unavailable");
            try {
                File file =
                        new File(
                                a.getExternalFilesDir(null), "home-v17-section-failure-native.png");
                try (FileOutputStream stream = new FileOutputStream(file)) {
                    if (!image.compress(Bitmap.CompressFormat.PNG, 100, stream))
                        throw new IOException("failure screenshot compression failed");
                }
                diagnostic.put("native_screenshot", file.getAbsolutePath());
            } finally {
                image.recycle();
            }
        } catch (Throwable error) {
            try {
                diagnostic.put("capture_error", error.toString());
            } catch (Exception ignored) {
            }
        }
        try {
            result.put("section_failure_diagnostic", diagnostic);
            Bundle progress = new Bundle();
            progress.putString("section_failure_diagnostic", diagnostic.toString());
            sendStatus(2, progress);
        } catch (Exception ignored) {
        }
    }

    void readySection() throws Exception {
        await(
                () ->
                        a.current != null
                                && retained() != null
                                && !retained().busy
                                && a.current.homeState.ready
                                && a.current.homeState.category.equals("section"));
    }

    void sectionState(String label, SectionFixture engine, boolean screenshot) throws Exception {
        JSONObject state = new JSONObject();
        runOnMainSync(
                () -> {
                    try {
                        HomeScreen.State s = a.current.homeState;
                        View focus = a.getCurrentFocus();
                        Rect visible = new Rect(), screen = new Rect();
                        a.root.getGlobalVisibleRect(screen);
                        boolean intersects =
                                focus != null
                                        && focus.getGlobalVisibleRect(visible)
                                        && visible.intersect(screen);
                        float alpha = 1f;
                        View ancestor = focus;
                        while (ancestor != null) {
                            alpha *= ancestor.getAlpha();
                            ancestor =
                                    ancestor.getParent() instanceof View
                                            ? (View) ancestor.getParent()
                                            : null;
                        }
                        state.put("uptime_ms", SystemClock.uptimeMillis())
                                .put("generation", a.generation)
                                .put("library", s.library)
                                .put("category", s.category)
                                .put("page", s.page)
                                .put("window_start", s.windowStart)
                                .put("items", s.videos.size())
                                .put("busy", retained().busy)
                                .put("scroll_y", a.scroll.getScrollY())
                                .put("category_requests", engine.requests.get())
                                .put(
                                        "focus_tag",
                                        focus == null
                                                ? JSONObject.NULL
                                                : String.valueOf(focus.getTag()))
                                .put("focus_id", focus == null ? View.NO_ID : focus.getId())
                                .put("global_visible_rect", visible.toShortString())
                                .put("root_visible_rect", screen.toShortString())
                                .put("intersects_screen", intersects)
                                .put("ancestor_alpha_product", alpha);
                        synchronized (engine.trace) {
                            state.put("request_trace", new JSONArray(engine.trace));
                        }
                    } catch (Exception e) {
                        throw new RuntimeException(e);
                    }
                });
        result.put("section_" + label, state);
        Bundle progress = new Bundle();
        progress.putString("section_state", state.toString());
        sendStatus(2, progress); // Preserve the snapshot even if the following assertion fails.
        check(
                label + "_focus_has_visible_screen_intersection",
                state.getBoolean("intersects_screen")
                        && state.getDouble("ancestor_alpha_product") > 0);
        if (screenshot) {
            Bitmap image = getUiAutomation().takeScreenshot();
            if (image == null) throw new AssertionError("native screenshot unavailable: " + label);
            File path = new File(a.getExternalFilesDir(null), "home-v17-" + label + "-native.png");
            try (FileOutputStream stream = new FileOutputStream(path)) {
                if (!image.compress(Bitmap.CompressFormat.PNG, 100, stream))
                    throw new IOException("native screenshot compression failed");
            } finally {
                image.recycle();
            }
            state.put("native_screenshot", path.getAbsolutePath());
        }
    }

    void previewDownBurst() {
        long time = SystemClock.uptimeMillis();
        for (int repeat = 0; repeat < 4; repeat++) {
            sendKeySync(
                    new KeyEvent(
                            time,
                            SystemClock.uptimeMillis(),
                            KeyEvent.ACTION_DOWN,
                            KeyEvent.KEYCODE_DPAD_DOWN,
                            repeat));
            SystemClock.sleep(25);
        }
        sendKeySync(
                new KeyEvent(
                        time,
                        SystemClock.uptimeMillis(),
                        KeyEvent.ACTION_UP,
                        KeyEvent.KEYCODE_DPAD_DOWN,
                        0));
        SystemClock.sleep(400);
    }

    void lastCardDown() throws Exception {
        sectionWait = "await-last-card-created";
        result.put(
                "last_card_dispatch",
                new JSONObject().put("attempt_stage", result.optString("section_stage")));
        HomeRenderDiagnostics.awaitLastCard(
                this,
                a,
                this::retained,
                () -> tag("home-video:" + (retained().windowEnd() - 1)) != null,
                result,
                result.optString("section_stage"));
        sectionWait = "last-card-focus-and-dispatch";
        runOnMainSync(
                () -> {
                    HomeScreen h = retained();
                    if (h.busy) throw new AssertionError("paging precondition busy");
                    // Position focus without the existing near-end onFocus prefetch winning the
                    // race.
                    // Only this setup toggles busy; the subsequent activity dispatch uses ready
                    // state.
                    h.busy = true;
                    try {
                        View target = tag("home-video:" + (h.windowEnd() - 1));
                        JSONObject drive =
                                new JSONObject()
                                        .put("target_before", sectionViewDiagnostic(target));
                        result.put("last_card_dispatch", drive);
                        drive.put("focus_request_accepted", target.requestFocus())
                                .put(
                                        "actual_focus_after_request",
                                        sectionViewDiagnostic(a.getCurrentFocus()))
                                .put("target_after_focus", sectionViewDiagnostic(target));
                        View next = a.root.findViewById(target.getNextFocusDownId());
                        drive.put("down_target", sectionViewDiagnostic(next));
                    } catch (Exception error) {
                        throw new RuntimeException(error);
                    } finally {
                        h.busy = false;
                    }
                    long time = SystemClock.uptimeMillis();
                    boolean downHandled =
                            a.dispatchKeyEvent(
                                    new KeyEvent(
                                            time,
                                            time,
                                            KeyEvent.ACTION_DOWN,
                                            KeyEvent.KEYCODE_DPAD_DOWN,
                                            0));
                    boolean upHandled =
                            a.dispatchKeyEvent(
                                    new KeyEvent(
                                            time,
                                            time + 1,
                                            KeyEvent.ACTION_UP,
                                            KeyEvent.KEYCODE_DPAD_DOWN,
                                            0));
                    try {
                        result.getJSONObject("last_card_dispatch")
                                .put("down_handled", downHandled)
                                .put("up_handled", upHandled)
                                .put("window_start_after_dispatch", h.state.windowStart)
                                .put("busy_after_dispatch", h.busy)
                                .put(
                                        "focus_after_dispatch",
                                        sectionViewDiagnostic(a.getCurrentFocus()));
                    } catch (Exception error) {
                        throw new RuntimeException(error);
                    }
                });
        sectionWait = "last-card-dispatched";
    }

    void accumulateSectionWindow(String name, SectionFixture engine) throws Exception {
        // Build the large retained list using visible last-card DOWN events. Do not
        // seed State.videos or bypass Cms.listing with a pre-parsed category cache.
        for (int step = 0; !ui(() -> a.current.homeState.page == 5); step++) {
            if (step >= 20)
                throw new AssertionError(name + " cumulative paging did not reach page 5");
            final int[] before = new int[4];
            runOnMainSync(
                    () -> {
                        before[0] = a.current.homeState.page;
                        before[1] = a.current.homeState.windowStart;
                        before[2] = a.current.homeState.videos.size();
                        before[3] = retained().windowEnd();
                    });
            final int requests = engine.requests.get();
            final boolean bufferedWindow = before[3] < before[2];
            result.put("section_stage", name + "-accumulate-step-" + step);
            lastCardDown();
            sectionWait =
                    bufferedWindow ? "await-buffered-window-advanced" : "await-next-page-loaded";
            await(
                    () ->
                            !retained().busy
                                    && (bufferedWindow
                                            ? a.current.homeState.windowStart > before[1]
                                            : a.current.homeState.page == before[0] + 1));
            check(
                    name + "_accumulate_step_" + step,
                    ui(
                            () ->
                                    bufferedWindow
                                            ? a.current.homeState.page == before[0]
                                                    && a.current.homeState.videos.size()
                                                            == before[2]
                                                    && a.current.homeState.windowStart
                                                            == before[1] + retained().windowSize()
                                                    && engine.requests.get() == requests
                                            : a.current.homeState.page == before[0] + 1
                                                    && a.current.homeState.videos.size()
                                                            == Math.min(2001, (before[0] + 1) * 500)
                                                    && engine.requests.get() == requests + 1));
        }
        check(
                name + "_retains_2001_items_from_five_pages",
                ui(
                        () ->
                                a.current.homeState.videos.size() == 2001
                                        && a.current.homeState.pages == 5
                                        && engine.requests.get() == 5));
        sectionState(name + "-accumulated", engine, true);
        lastCardDown();
        check(name + "_accumulated_tail_does_not_request_extra", engine.requests.get() == 5);
        while (ui(() -> a.current.homeState.windowStart > 0)) {
            final int[] target = new int[1];
            runOnMainSync(
                    () ->
                            target[0] =
                                    Math.max(
                                            0,
                                            a.current.homeState.windowStart
                                                    - retained().windowSize()));
            click("home-earlier");
            await(() -> a.current.homeState.windowStart == target[0]);
        }
        check(
                name + "_returns_to_first_loaded_window",
                ui(
                        () ->
                                a.current.homeState.windowStart == 0
                                        && a.current.homeState.page == 5
                                        && a.current.homeState.videos.size() == 2001
                                        && engine.requests.get() == 5));
    }

    void sectionPagingRegression() throws Exception {
        verifySectionPageContract();
        // Keep every old right/top assertion above; add independent explicit layouts here.
        for (int layout = 0; layout < 3; layout++) {
            for (boolean wide : new boolean[] {false, true}) {
                final int selectedLayout = layout;
                String name =
                        (layout == 0 ? "left" : layout == 1 ? "right" : "top")
                                + (wide ? "-window" : "-page");
                SectionFixture engine = new SectionFixture(wide);
                activeSectionFixture = engine;
                sectionWait = "scenario-setup";
                Cms.Site source = new Cms.Site();
                source.key = "home-section-" + name;
                source.name = "独立分页夹具";
                source.type = 1;
                source.api = "https://fixture.test/section";
                runOnMainSync(
                        () -> {
                            a.prefs
                                    .edit()
                                    .putInt(Prefs.TV_NAVIGATION_MODE, selectedLayout == 0 ? 1 : 0)
                                    .putInt(Prefs.TV_DOCK_POSITION, selectedLayout == 2 ? 1 : 0)
                                    .putInt(Prefs.NAV_SCALE_PERCENT, 100)
                                    .putInt(Prefs.HOME_COLUMNS, 5)
                                    .putString("watch_history", "[]")
                                    .putString(Prefs.SELECTED_SITE, source.key)
                                    .putBoolean(Prefs.REDUCED, true)
                                    .commit();
                            a.reduced = true;
                            Cms.Config config = new Cms.Config();
                            config.raw = "{}";
                            config.sites.add(source);
                            a.config = config;
                            a.engines.put(source.key, engine);
                            a.back.clear();
                            a.open(new MainActivity.Screen(a::home), false);
                        });
                await(() -> tag("home-tab:1") != null && a.current.homeState.ready);
                if (layout == 0) click("nav-library");
                result.put("section_stage", name + "-first-page");
                sectionWait = "await-first-page-ready";
                click("home-tab:1");
                readySection();
                check(
                        name + "_fixture_first_page",
                        ui(
                                () ->
                                        a.current.homeState.page == 1
                                                && a.current.homeState.videos.size()
                                                        == (wide ? 500 : 40)));
                if (wide) accumulateSectionWindow(name, engine);
                result.put("section_stage", name + "-section-navigation");
                if (layout == 0) {
                    click("nav-home");
                    await(() -> tag("home-preview:0") != null && tag("home-preview:0").isShown());
                    runOnMainSync(() -> tag("home-preview:0").requestFocus());
                    SystemClock.sleep(300);
                    final int beforeRequests = engine.requests.get();
                    final int[] before = new int[3];
                    runOnMainSync(
                            () -> {
                                before[0] = a.current.homeState.page;
                                before[1] = a.current.homeState.windowStart;
                                before[2] = a.current.homeState.videos.size();
                            });
                    sectionState(name + "-before-down", engine, true);
                    previewDownBurst();
                    sectionState(name + "-after-down", engine, true);
                    check(
                            name + "_home_down_preserves_hidden_library",
                            ui(
                                    () ->
                                            engine.requests.get() == beforeRequests
                                                    && !retained().busy
                                                    && a.current.homeState.page == before[0]
                                                    && a.current.homeState.windowStart == before[1]
                                                    && a.current.homeState.videos.size()
                                                            == before[2]
                                                    && tag("home-preview:0").hasFocus()));
                    key(KeyEvent.KEYCODE_DPAD_LEFT);
                    check(
                            name + "_left_recalls_dock",
                            ui(() -> a.homeDock.contains(a.getCurrentFocus())));
                    key(KeyEvent.KEYCODE_DPAD_RIGHT);
                    check(
                            name + "_right_restores_preview",
                            ui(() -> tag("home-preview:0").hasFocus()));
                    key(KeyEvent.KEYCODE_DPAD_LEFT);
                    key(KeyEvent.KEYCODE_BACK);
                    check(
                            name + "_back_restores_preview",
                            ui(() -> tag("home-preview:0").hasFocus()));
                    click("nav-library");
                }
                final int beforeVisible = engine.requests.get();
                if (!wide) {
                    engine.hold = new CountDownLatch(1);
                    engine.failNext = true;
                }
                try {
                    lastCardDown();
                    if (wide) {
                        await(() -> a.current.homeState.windowStart > 0);
                        check(
                                name + "_visible_advances_window_without_request",
                                ui(
                                        () ->
                                                a.current.homeState.windowStart
                                                                == retained().windowSize()
                                                        && engine.requests.get() == beforeVisible));
                        click("home-earlier");
                        await(() -> a.current.homeState.windowStart == 0);
                    } else {
                        await(() -> engine.requests.get() == beforeVisible + 1 && retained().busy);
                        previewDownBurst();
                        check(
                                name + "_busy_deduplicates",
                                engine.requests.get() == beforeVisible + 1);
                        runOnMainSync(
                                () -> {
                                    tag("home-tab:1").requestFocus();
                                    a.scroll.scrollTo(0, 0);
                                });
                        engine.hold.countDown();
                        readySection();
                        check(
                                name + "_failure_preserves_page_and_retry",
                                ui(
                                        () ->
                                                a.current.homeState.page == 1
                                                        && a.current.homeState.videos.size() == 40
                                                        && tag("home-load-more").isShown()
                                                        && engine.requests.get()
                                                                == beforeVisible + 1));
                        sectionState(name + "-failure", engine, true);
                        engine.hold = new CountDownLatch(1);
                        click("home-load-more");
                        await(() -> engine.requests.get() == beforeVisible + 2 && retained().busy);
                        if (layout == 0) {
                            click("nav-home");
                            runOnMainSync(() -> tag("home-preview:0").requestFocus());
                        }
                        engine.hold.countDown();
                        readySection();
                        check(
                                name + "_inflight_completion_allowed",
                                ui(
                                        () ->
                                                a.current.homeState.page == 2
                                                        && a.current.homeState.videos.size()
                                                                == 45));
                        if (layout == 0) previewDownBurst();
                        else lastCardDown();
                        check(
                                name + "_tail_does_not_request_extra",
                                engine.requests.get() == beforeVisible + 2);
                    }
                    sectionState(name + "-finished", engine, true);
                } finally {
                    if (engine.hold != null) engine.hold.countDown();
                    engine.hold = null;
                }
            }
        }
    }

    void readingScroll() throws Exception {
        runOnMainSync(
                () ->
                        a.open(
                                new MainActivity.Screen(() -> new SettingsScreen(a).appearance()),
                                true));
        await(() -> tag("setting-tv_dock_position") != null);
        check("settings_use_reading_scroll", ui(() -> ((TvScrollView) a.scroll).readingMode));
        runOnMainSync(
                () ->
                        a.open(
                                new MainActivity.Screen(
                                        () -> {
                                            new UpdateScreen(a).show();
                                            StringBuilder notes = new StringBuilder();
                                            for (int n = 1; n <= 100; n++)
                                                notes.append(n)
                                                        .append(". 电视端更新内容：分类导航、清晰图标和遥控器体验。\n");
                                            ((TextView) tag("update-notes"))
                                                    .setText(notes.toString());
                                        }),
                                true));
        await(
                () ->
                        tag("update-notes") != null
                                && tag("update-notes").getHeight() > a.scroll.getHeight() * 2);
        runOnMainSync(
                () -> {
                    tag("update-notes").requestFocus();
                    a.scroll.scrollTo(0, 0);
                });
        key(KeyEvent.KEYCODE_DPAD_DOWN);
        TvScrollView scroll = (TvScrollView) a.scroll;
        int readingStep =
                TvReadingScrollPolicy.step(
                        scroll.getHeight() - a.dp(24),
                        ((TextView) tag("update-notes")).getLineHeight(),
                        a.dp(48));
        check(
                "long_update_down_scrolls_one_reading_page",
                ui(
                        () ->
                                scroll.readingMode
                                        && scroll.goal > 0
                                        && scroll.goal <= readingStep
                                        && tag("update-notes").hasFocus()));
        await(() -> scroll.motion == null);
        check(
                "reading_step_does_not_skip_to_bottom",
                ui(
                        () ->
                                scroll.getScrollY() <= readingStep
                                        && scroll.getScrollY() < scroll.limit() / 4));
        check(
                "held_remote_does_not_queue_large_reading_jump",
                ui(
                        () -> {
                            int before = scroll.getScrollY();
                            long now = SystemClock.uptimeMillis();
                            for (int n = 0; n < 12; n++)
                                a.dispatchKeyEvent(
                                        new KeyEvent(
                                                now,
                                                now + n * 5,
                                                KeyEvent.ACTION_DOWN,
                                                KeyEvent.KEYCODE_DPAD_DOWN,
                                                n));
                            return scroll.goal <= before + readingStep;
                        }));
        await(() -> scroll.motion == null);
        int beforeUp = scroll.getScrollY();
        key(KeyEvent.KEYCODE_DPAD_UP);
        check(
                "reading_up_reverses_by_one_reading_page",
                ui(() -> scroll.goal < beforeUp && beforeUp - scroll.goal <= readingStep));
        frame("long-update-reading");
        runOnMainSync(
                () -> {
                    View action = tag("update-check");
                    Rect area = new Rect(0, 0, action.getWidth(), action.getHeight());
                    scroll.offsetDescendantRectToMyCoords(action, area);
                    scroll.scrollTo(0, area.bottom - scroll.getHeight() + a.dp(40));
                });
        key(KeyEvent.KEYCODE_DPAD_DOWN);
        check(
                "reading_reaches_update_action_when_visible",
                ui(() -> tag("update-check").hasFocus()));
        runOnMainSync(
                () -> {
                    scroll.scrollTo(0, scroll.limit());
                    tag("update-check").requestFocus();
                    scroll.scrollTo(0, scroll.limit());
                });
        key(KeyEvent.KEYCODE_DPAD_DOWN);
        check("reading_bottom_stays_bounded", ui(() -> scroll.goal <= scroll.limit()));
        runOnMainSync(() -> a.open(new MainActivity.Screen(a::home), false));
        await(() -> tag("home-video:11") != null);
        check(
                "home_keeps_its_browsing_scroll_policy",
                ui(() -> !((TvScrollView) a.scroll).readingMode));
    }

    void glassNavigation() throws Exception {
        runOnMainSync(
                () -> {
                    a.prefs
                            .edit()
                            .putInt(Prefs.TV_DOCK_POSITION, 0)
                            .putInt(Prefs.NAV_SCALE_PERCENT, 100)
                            .putString(Prefs.WATCH_HISTORY, "[]")
                            .apply();
                    a.reduced = false;
                    a.open(new MainActivity.Screen(a::home), false);
                });
        await(
                () ->
                        tag("home-video:11") != null
                                && a.current.retainedHome.filters.selection.positioned);
        GlassSelection category = a.current.retainedHome.filters.selection;
        check(
                "category_glass_retargets_without_fading_buttons",
                ui(
                        () -> {
                            float previous = category.left.value;
                            tag("home-tab:1").requestFocus();
                            return category.target == tag("home-tab:1")
                                    && category.animator != null
                                    && category.left.value == previous
                                    && a.current.homeState.category.equals("c1")
                                    && tag("home-tab:0").getAlpha() == 1f
                                    && tag("home-tab:1").getAlpha() == 1f
                                    && tag("home-tab:0").getBackground() == null
                                    && tag("home-tab:1").getBackground() == null;
                        }));
        SystemClock.sleep(45);
        frame("glass-category-moving");
        check(
                "category_glass_reverses_from_current_position",
                ui(
                        () -> {
                            float position = category.left.value;
                            tag("home-tab:2").requestFocus();
                            tag("home-tab:0").requestFocus();
                            return category.left.value == position
                                    && category.target == tag("home-tab:0")
                                    && a.current.homeState.category.isEmpty();
                        }));
        await(() -> category.animator == null);
        check(
                "category_glass_settles_on_selected_bounds",
                ui(
                        () ->
                                Math.abs(
                                                category.left.value
                                                        - tag("home-tab:0").getLeft()
                                                        - a.dp(1))
                                        < 1));
        runOnMainSync(() -> tag("nav-home").requestFocus());
        await(() -> a.homeDock.selection.animator == null);
        GlassSelection dock = a.homeDock.selection;
        check(
                "dock_uses_one_sliding_glass_lens",
                ui(
                        () -> {
                            float previous = dock.top.value;
                            tag("nav-search").requestFocus();
                            return dock.target == tag("nav-search")
                                    && dock.animator != null
                                    && dock.top.value == previous
                                    && tag("nav-home").getBackground() == null
                                    && tag("nav-search").getBackground() == null;
                        }));
        await(() -> dock.animator == null);
        check(
                "tv_dock_icons_slightly_larger",
                ui(
                        () ->
                                tag("nav-home").getWidth() == a.dp(42)
                                        && tag("home-dock").getWidth() == a.dp(56)));
        frame("glass-right-dock");

        runOnMainSync(
                () ->
                        a.open(
                                new MainActivity.Screen(() -> new SettingsScreen(a).appearance()),
                                true));
        await(() -> tag("setting-tv_dock_position") != null);
        check("dock_position_setting_visible", ui(() -> tag("setting-tv_dock_position").isShown()));
        runOnMainSync(() -> tag("setting-tv_dock_position").performClick());
        await(
                () ->
                        a.appDialog != null
                                && a.appDialog
                                                .findViewById(android.R.id.content)
                                                .findViewWithTag("dialog-option:1")
                                        != null);
        runOnMainSync(
                () ->
                        a.appDialog
                                .findViewById(android.R.id.content)
                                .findViewWithTag("dialog-option:1")
                                .performClick());
        check(
                "top_position_preference_saved",
                ui(() -> a.prefs.getInt(Prefs.TV_DOCK_POSITION, 0) == 1));
        runOnMainSync(a::onBackPressed);
        await(
                () ->
                        a.homeDock != null
                                && a.homeDock.topMode
                                && tag("home-video:11") != null
                                && tag("home-dock").getWidth() > 0);
        check(
                "top_dock_is_horizontal_and_fixed",
                ui(
                        () ->
                                tag("home-dock").getParent() == a.root
                                        && tag("home-dock").getWidth()
                                                > tag("home-dock").getHeight()
                                        && tag("home-dock").getTop() == a.dp(16)));
        check(
                "top_dock_logo_fixed_and_level_with_dock",
                ui(
                        () -> {
                            View brand = tag("home-brand");
                            View dockBar = tag("home-dock");
                            return brand != null
                                    && brand.getParent() == a.root
                                    && brand.getTop() == dockBar.getTop()
                                    && Math.abs(
                                                    (brand.getTop() + brand.getBottom())
                                                            - (dockBar.getTop()
                                                                    + dockBar.getBottom()))
                                            <= 2
                                    && brand.getRight() + a.dp(12) <= dockBar.getLeft();
                        }));
        check(
                "top_dock_reserves_content_viewport",
                ui(() -> a.scroll.getTop() >= tag("home-dock").getBottom() + a.dp(12)));
        runOnMainSync(() -> tag("source-switcher").requestFocus());
        key(KeyEvent.KEYCODE_DPAD_UP);
        check("up_from_content_enters_top_dock", ui(() -> tag("nav-home").hasFocus()));
        key(KeyEvent.KEYCODE_DPAD_RIGHT);
        check("top_dock_right_moves_to_search", ui(() -> tag("nav-search").hasFocus()));
        key(KeyEvent.KEYCODE_DPAD_LEFT);
        check("top_dock_left_moves_between_icons", ui(() -> tag("nav-home").hasFocus()));
        key(KeyEvent.KEYCODE_DPAD_UP);
        check("top_dock_up_stays_inside_navigation", ui(() -> tag("nav-home").hasFocus()));
        key(KeyEvent.KEYCODE_DPAD_DOWN);
        check("top_dock_down_restores_content_focus", ui(() -> tag("source-switcher").hasFocus()));
        runOnMainSync(() -> tag("nav-settings").requestFocus());
        await(() -> a.homeDock.selection.animator == null);
        frame("glass-top-dock");
        check(
                "top_dock_label_inside_screen",
                ui(
                        () -> {
                            View hint = tag("home-dock-label");
                            return hint.getVisibility() == View.VISIBLE
                                    && hint.getLeft() >= 0
                                    && hint.getRight() <= a.root.getWidth()
                                    && hint.getTop() >= tag("home-dock").getBottom();
                        }));
        click("nav-accounts");
        await(() -> a.accountDialog != null && a.accountDialog.isShowing());
        check(
                "top_dock_account_panel_stays_within_screen",
                ui(
                        () -> {
                            View panel =
                                    a.accountDialog
                                            .findViewById(android.R.id.content)
                                            .findViewWithTag("account-panel");
                            int[] point = new int[2];
                            panel.getLocationOnScreen(point);
                            return point[0] >= 0
                                    && point[0] + panel.getWidth() <= a.windowWidth()
                                    && point[1] >= 0
                                    && point[1] + panel.getHeight() <= a.windowHeight();
                        }));
        key(KeyEvent.KEYCODE_BACK);
        check(
                "top_dock_account_panel_restores_anchor_focus",
                ui(() -> tag("nav-accounts").hasFocus()));
        runOnMainSync(
                () -> {
                    a.prefs.edit().putInt(Prefs.NAV_SCALE_PERCENT, 140).apply();
                    a.refresh();
                });
        await(
                () ->
                        a.homeDock != null
                                && a.homeDock.topMode
                                && tag("home-video:11") != null
                                && a.homeDock.navScale > 1.3f);
        check(
                "large_top_dock_stays_within_screen",
                ui(
                        () ->
                                tag("home-dock").getLeft() >= a.dp(16)
                                        && tag("home-dock").getRight()
                                                <= a.root.getWidth() - a.dp(16)
                                        && a.scroll.getTop()
                                                >= tag("home-dock").getBottom() + a.dp(12)));
        check(
                "large_top_dock_logo_aligned_and_clear",
                ui(
                        () ->
                                tag("home-brand") != null
                                        && tag("home-brand").getTop() == tag("home-dock").getTop()
                                        && tag("home-brand").getRight()
                                                <= tag("home-dock").getLeft()));
        frame("glass-top-large");
        check(
                "large_top_dock_label_clears_content",
                ui(
                        () ->
                                a.scroll.getTop() + a.body.getPaddingTop()
                                        >= tag("home-dock").getBottom() + a.dp(6)));
        check(
                "reduced_motion_snaps_glass_without_delaying_category",
                ui(
                        () -> {
                            a.reduced = true;
                            tag("home-tab:1").requestFocus();
                            GlassSelection glass = a.current.retainedHome.filters.selection;
                            return a.current.homeState.category.equals("c1")
                                    && glass.animator == null
                                    && glass.left.value == glass.left.target;
                        }));
        runOnMainSync(
                () -> {
                    a.reduced = false;
                    a.prefs
                            .edit()
                            .putInt(Prefs.TV_DOCK_POSITION, 0)
                            .putInt(Prefs.NAV_SCALE_PERCENT, 100)
                            .apply();
                    a.refresh();
                });
        await(() -> a.homeDock != null && !a.homeDock.topMode && tag("home-video:11") != null);
        check(
                "right_dock_can_be_restored",
                ui(() -> tag("home-dock").getWidth() < tag("home-dock").getHeight()));
    }
}
