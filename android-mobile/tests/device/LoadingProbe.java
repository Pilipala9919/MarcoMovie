package com.pilipala.marcomovie;

import android.app.*;
import android.content.*;
import android.os.*;
import android.view.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.*;
import org.json.*;

/** Slow local sources exercise TV request ordering; no external network or user accounts. */
public final class LoadingProbe extends Instrumentation {
    MainActivity a;
    Cms.Site site;
    final CountDownLatch launched = new CountDownLatch(1);
    final JSONObject result = new JSONObject();

    @Override
    public void onCreate(Bundle args) {
        super.onCreate(args);
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
                            public SharedPreferences getSharedPreferences(String name, int mode) {
                                return super.getSharedPreferences(
                                        name.equals("movie") ? "loading-fixture" : name, mode);
                            }

                            public java.io.File getFilesDir() {
                                java.io.File dir =
                                        new java.io.File(super.getCacheDir(), "loading-empty");
                                dir.mkdirs();
                                return dir;
                            }
                        });
            } catch (Exception error) {
                throw new RuntimeException(error);
            }
        }
        super.callActivityOnCreate(activity, state);
        if (activity instanceof MainActivity) {
            a = (MainActivity) activity;
            a.getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
            a.ui.post(
                    new Runnable() {
                        public void run() {
                            if (a.layoutReady) launched.countDown();
                            else a.ui.postDelayed(this, 16);
                        }
                    });
        }
    }

    boolean ui(Callable<Boolean> call) {
        boolean[] value = {false};
        runOnMainSync(
                () -> {
                    try {
                        value[0] = call.call();
                    } catch (Exception error) {
                        throw new RuntimeException(error);
                    }
                });
        return value[0];
    }

    void check(String name, boolean value) throws Exception {
        result.put(name, value);
        if (!value) throw new AssertionError(name);
    }

    boolean await(Callable<Boolean> call, int timeout) {
        long end = SystemClock.elapsedRealtime() + timeout;
        while (SystemClock.elapsedRealtime() < end) {
            if (ui(call)) return true;
            SystemClock.sleep(20);
        }
        return false;
    }

    View tag(String name) {
        return a.root.findViewWithTag(name);
    }

    View choice(View view, String label) {
        if (view instanceof android.widget.Button
                && ((android.widget.Button) view).getText().toString().contains(label)) return view;
        if (view instanceof ViewGroup) {
            ViewGroup group = (ViewGroup) view;
            for (int i = 0; i < group.getChildCount(); i++) {
                View found = choice(group.getChildAt(i), label);
                if (found != null) return found;
            }
        }
        return null;
    }

    static String listing(String id) {
        return "{\"list\":[{\"vod_id\":\"" + id + "\",\"vod_name\":\"加载样本\"}],\"pagecount\":1}";
    }

    static String detail(String id) {
        return "{\"list\":[{\"vod_id\":\""
                + id
                + "\",\"vod_name\":\"加载样本\",\"vod_content\":\"样本简介\",\"vod_play_from\":\"样本\",\"vod_play_url\":\"第一集$https://fixture.test/video\"}]}";
    }

    Cms.Video video(String id) {
        Cms.Video v = new Cms.Video();
        v.id = id;
        v.title = "加载样本";
        return v;
    }

    static class Source implements SourceEngine {
        public String home() throws Exception {
            return "{\"class\":[{\"type_id\":\"movie\",\"type_name\":\"电影\"},{\"type_id\":\"series\",\"type_name\":\"剧集\"}],\"list\":[]}";
        }

        public String category(String id, int page) throws Exception {
            return listing(id);
        }

        public String search(String q, int page) {
            return "{}";
        }

        public String detail(String id) throws Exception {
            return LoadingProbe.detail(id);
        }

        public boolean requiresExternalRuntime() {
            return false;
        }
    }

    void setSource(SourceEngine source) {
        runOnMainSync(
                () -> {
                    a.cancelPageRequests();
                    a.detailCache.clear();
                    a.homeData.clear();
                    a.engines.put(site.key, source);
                });
    }

    void home() {
        runOnMainSync(() -> a.open(new MainActivity.Screen(a::home), false));
    }

    void requestDetail(String id, AtomicReference<String> received) {
        runOnMainSync(() -> a.loadDetail(site, id, v -> received.set(v.id)));
    }

    void saveConfig(Cms.Config config, String origin) throws Exception {
        AtomicReference<Exception> error = new AtomicReference<>();
        runOnMainSync(
                () -> {
                    try {
                        a.saveConfig(config, origin);
                    } catch (Exception failure) {
                        error.set(failure);
                    }
                });
        if (error.get() != null) throw error.get();
    }

    @Override
    public void onStart() {
        CountDownLatch release = new CountDownLatch(1);
        try {
            Context context = getTargetContext();
            context.startActivity(
                    new Intent(context, MainActivity.class)
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
            if (!launched.await(20, TimeUnit.SECONDS)) throw new AssertionError("launch");
            site = new Cms.Site();
            site.key = "loading-fixture";
            site.name = "加载测试";
            site.type = 1;
            site.api = "https://fixture.test/api";
            runOnMainSync(
                    () -> {
                        if (a.startupIntro != null) a.startupIntro.cancel();
                        a.prefs
                                .edit()
                                .clear()
                                .putString(Prefs.SELECTED_SITE, site.key)
                                .putBoolean("startup_animation", false)
                                .commit();
                        a.config = new Cms.Config();
                        a.config.sites.add(site);
                        a.reduced = false;
                        a.back.clear();
                    });

            AtomicInteger recommendations = new AtomicInteger(), categories = new AtomicInteger();
            CountDownLatch recommendationEntered = new CountDownLatch(1),
                    recommendationCancelled = new CountDownLatch(1);
            setSource(
                    new Source() {
                        public String homeVideos() throws Exception {
                            if (recommendations.incrementAndGet() == 1) {
                                RequestScope.onCancel(recommendationCancelled::countDown);
                                recommendationEntered.countDown();
                                release.await(8, TimeUnit.SECONDS);
                                RequestScope.checkCurrent();
                            }
                            return listing("recommendation");
                        }

                        public String category(String id, int page) {
                            categories.incrementAndGet();
                            return listing(id);
                        }
                    });
            long began = SystemClock.elapsedRealtime();
            home();
            check("slow_recommendation_started", recommendationEntered.await(3, TimeUnit.SECONDS));
            check(
                    "categories_visible_before_recommendations",
                    await(() -> tag("home-tab:1") != null, 1800));
            result.put("navigation_ready_ms", SystemClock.elapsedRealtime() - began);
            began = SystemClock.elapsedRealtime();
            runOnMainSync(() -> tag("home-tab:1").requestFocus());
            check(
                    "focus_loads_movie_while_recommendation_pending",
                    await(
                            () ->
                                    a.current.homeState.ready
                                            && "movie".equals(a.current.homeState.category),
                            1800));
            result.put("focus_to_category_ms", SystemClock.elapsedRealtime() - began);
            check(
                    "category_cancels_old_recommendation",
                    recommendationCancelled.await(1, TimeUnit.SECONDS));
            SystemClock.sleep(100);
            result.put("category_calls_after_cancel", categories.get());
            check("cancelled_home_skips_fallback_request", categories.get() == 1);
            runOnMainSync(() -> a.current.retainedHome.choose("series", true));
            check("series_ready", await(() -> a.current.homeState.ready, 1800));
            int loaded = categories.get();
            runOnMainSync(() -> a.current.retainedHome.choose("movie", true));
            check(
                    "returning_category_reuses_cache",
                    ui(() -> a.current.homeState.ready) && categories.get() == loaded);
            runOnMainSync(() -> a.current.retainedHome.choose("", true));
            check(
                    "return_to_pending_recommendations_reloads",
                    await(
                            () ->
                                    a.current.homeState.ready
                                            && !a.current.homeState.videos.isEmpty()
                                            && "recommendation"
                                                    .equals(a.current.homeState.videos.get(0).id),
                            2000));

            AtomicInteger serializedDetails = new AtomicInteger();
            setSource(
                    new QueuedSourceEngine(
                            new Source() {
                                public String home() {
                                    return listing("plugin");
                                }

                                public boolean requiresExternalRuntime() {
                                    return true;
                                }

                                public String detail(String id) {
                                    serializedDetails.incrementAndGet();
                                    return LoadingProbe.detail(id);
                                }
                            }));
            home();
            check("plugin_home_ready", await(() -> tag("home-video:0") != null, 2000));
            SystemClock.sleep(700);
            check("first_card_is_not_automatically_prefetched", serializedDetails.get() == 0);
            runOnMainSync(() -> tag("home-video:0").requestFocus());
            SystemClock.sleep(700);
            check("focus_does_not_speculate_on_serialized_plugin", serializedDetails.get() == 0);
            AtomicReference<String> received = new AtomicReference<>();
            requestDetail("selected", received);
            check(
                    "selected_plugin_detail_runs_once",
                    await(() -> "selected".equals(received.get()), 1800)
                            && serializedDetails.get() == 1);

            AtomicInteger speculative = new AtomicInteger(), selected = new AtomicInteger();
            CountDownLatch speculativeEntered = new CountDownLatch(1);
            setSource(
                    new Source() {
                        public String detail(String id) throws Exception {
                            if (id.startsWith("hover")) {
                                speculative.incrementAndGet();
                                speculativeEntered.countDown();
                                release.await(8, TimeUnit.SECONDS);
                            } else selected.incrementAndGet();
                            return LoadingProbe.detail(id);
                        }
                    });
            runOnMainSync(
                    () -> {
                        for (int i = 0; i < 8; i++)
                            SourceController.prefetchDetail(a, site, video("hover" + i));
                    });
            check("one_optional_request_started", speculativeEntered.await(2, TimeUnit.SECONDS));
            received.set(null);
            began = SystemClock.elapsedRealtime();
            requestDetail("clicked", received);
            check(
                    "click_does_not_wait_for_unrelated_prefetch",
                    await(() -> "clicked".equals(received.get()), 1800));
            result.put("detail_while_prefetch_blocked_ms", SystemClock.elapsedRealtime() - began);
            check("rapid_focus_keeps_only_one_optional_request", speculative.get() == 1);
            AtomicReference<String> shared = new AtomicReference<>();
            requestDetail("hover0", shared);
            release.countDown();
            check(
                    "matching_click_shares_existing_request",
                    await(() -> "hover0".equals(shared.get()), 2000) && speculative.get() == 1);
            received.set(null);
            requestDetail("clicked", received);
            check(
                    "repeat_detail_reuses_valid_cache",
                    await(() -> "clicked".equals(received.get()), 1000) && selected.get() == 1);
            check("prefetch_finished", await(() -> a.detailPrefetch.isDone(), 2000));

            AtomicInteger retry = new AtomicInteger();
            setSource(
                    new Source() {
                        public String detail(String id) {
                            return retry.incrementAndGet() == 1 ? "{}" : LoadingProbe.detail(id);
                        }
                    });
            runOnMainSync(() -> SourceController.prefetchDetail(a, site, video("retry")));
            check("empty_prefetch_finishes", await(() -> a.detailPrefetch.isDone(), 2000));
            received.set(null);
            requestDetail("retry", received);
            check(
                    "empty_prefetch_does_not_poison_detail_cache",
                    await(() -> "retry".equals(received.get()), 2000) && retry.get() == 2);

            Cms.Video complete = Cms.listing(detail("complete")).videos.get(0);
            complete.description = "";
            int before = retry.get();
            runOnMainSync(
                    () -> {
                        a.reduced = true;
                        a.openListing(site, complete);
                    });
            check(
                    "reduced_mode_uses_existing_episodes",
                    await(() -> tag("episode:样本:0") != null, 1500) && retry.get() == before);
            runOnMainSync(() -> a.reduced = false);

            CountDownLatch refreshEntered = new CountDownLatch(1),
                    refreshCancelled = new CountDownLatch(1);
            AtomicInteger homeCalls = new AtomicInteger();
            setSource(
                    new Source() {
                        public String home() throws Exception {
                            if (homeCalls.incrementAndGet() > 1) {
                                RequestScope.onCancel(refreshCancelled::countDown);
                                refreshEntered.countDown();
                                new CountDownLatch(1).await(8, TimeUnit.SECONDS);
                            }
                            return super.home()
                                    .replace(
                                            "\"list\":[]",
                                            "\"list\":[{\"vod_id\":\"home\",\"vod_name\":\"样本\"}]");
                        }
                    });
            home();
            check("refresh_fixture_ready", await(() -> tag("home-video:0") != null, 2000));
            runOnMainSync(() -> a.current.retainedHome.refreshHomeSilently());
            check("silent_refresh_started", refreshEntered.await(2, TimeUnit.SECONDS));
            runOnMainSync(() -> a.current.retainedHome.choose("movie", true));
            check("category_cancels_silent_refresh", refreshCancelled.await(1, TimeUnit.SECONDS));
            check(
                    "category_after_refresh_ready",
                    await(
                            () ->
                                    a.current.homeState.ready
                                            && "movie".equals(a.current.homeState.category),
                            1800));
            runOnMainSync(
                    () -> {
                        a.cancelPageRequests();
                        a.configStore =
                                new ConfigStore(
                                        new java.io.File(
                                                a.getCacheDir(),
                                                "subscription-probe-" + System.nanoTime()));
                        a.config = null;
                        a.configOrigin = "";
                    });
            String firstOrigin = "https://first.fixture.test/config.json";
            String secondOrigin = "https://second.fixture.test/config.json";
            String firstRaw =
                    "{\"sites\":[{\"key\":\"duplicate\",\"name\":\"第一个订阅\",\"type\":99,\"api\":\"./api\"}]}";
            String secondRaw =
                    "{\"sites\":[{\"key\":\"duplicate\",\"name\":\"第二个订阅\",\"type\":99,\"api\":\"./api\"}]}";
            saveConfig(Cms.parseConfig(firstRaw, firstOrigin), firstOrigin);
            saveConfig(Cms.parseConfig(secondRaw, secondOrigin), secondOrigin);
            ConfigLibrary library = new ConfigLibrary(a.configStore.directory);
            check(
                    "tv_import_keeps_both_subscriptions",
                    library.entries().size() == 2
                            && library.raw(library.entries().get(0)).equals(firstRaw));
            check("new_subscription_is_active", ui(() -> a.configOrigin.equals(secondOrigin)));
            saveConfig(Cms.parseConfig(secondRaw, secondOrigin), secondOrigin);
            check("reimport_updates_existing_subscription", library.entries().size() == 2);
            runOnMainSync(() -> SourcePicker.show(a));
            check(
                    "saved_sources_entry_is_available",
                    ui(
                            () ->
                                    a.sourceDialog
                                                    .findViewById(android.R.id.content)
                                                    .findViewWithTag("source-library")
                                            != null));
            runOnMainSync(
                    () ->
                            a.sourceDialog
                                    .findViewById(android.R.id.content)
                                    .findViewWithTag("source-library")
                                    .performClick());
            check(
                    "saved_sources_dialog_opens",
                    await(
                            () ->
                                    a.appDialog != null
                                            && a.appDialog.isShowing()
                                            && choice(
                                                            a.appDialog.getWindow().getDecorView(),
                                                            "第一个订阅")
                                                    != null,
                            2000));
            runOnMainSync(
                    () -> choice(a.appDialog.getWindow().getDecorView(), "第一个订阅").performClick());
            check(
                    "older_subscription_restored_from_saved_copy",
                    await(() -> firstOrigin.equals(a.configOrigin), 2000));
            check(
                    "switch_preserves_other_saved_source",
                    new ConfigLibrary(a.configStore.directory).entries().size() == 2);
            runOnMainSync(
                    () -> {
                        if (a.sourceDialog != null) a.sourceDialog.dismiss();
                    });
            result.put("passed", true);
        } catch (Throwable error) {
            try {
                result.put("passed", false).put("error", error.toString());
            } catch (Exception ignored) {
            }
        } finally {
            release.countDown();
            if (a != null) runOnMainSync(() -> a.cancelPageRequests());
        }
        Bundle report = new Bundle();
        report.putString("result", result.toString());
        sendStatus(0, report);
        finish(Activity.RESULT_OK, new Bundle());
    }
}
