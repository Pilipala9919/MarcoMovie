package com.pilipala.marcomovie;

import java.io.IOException;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.*;

/** Deterministic regressions for initialization ownership and episode identity. */
public final class ReviewFixChecks {
    static int checks;

    static void check(boolean value, String name) {
        if (!value) throw new AssertionError(name);
        checks++;
        System.out.println("PASS " + name);
    }

    static void waiting(Thread t) throws Exception {
        long end = System.nanoTime() + TimeUnit.SECONDS.toNanos(2);
        while (t.getState() != Thread.State.WAITING && System.nanoTime() < end) Thread.sleep(1);
        check(t.getState() == Thread.State.WAITING, "waiter joined shared initialization");
    }

    public static void main(String[] args) throws Exception {
        SingleFlight<Object> flight = new SingleFlight<>();
        Object result = new Object();
        AtomicInteger initialized = new AtomicInteger();
        CountDownLatch entered = new CountDownLatch(1), release = new CountDownLatch(1);
        ExecutorService executor = Executors.newFixedThreadPool(3);
        try {
            Future<Object> owner =
                    executor.submit(
                            () ->
                                    flight.get(
                                            "epoch0:site",
                                            () -> {
                                                initialized.incrementAndGet();
                                                entered.countDown();
                                                release.await();
                                                return result;
                                            }));
            check(entered.await(2, TimeUnit.SECONDS), "owner initialization started");
            AtomicBoolean interrupted = new AtomicBoolean();
            AtomicReference<Throwable> unexpected = new AtomicReference<>();
            Thread cancelled =
                    new Thread(
                            () -> {
                                try {
                                    flight.get(
                                            "epoch0:site",
                                            () -> {
                                                initialized.incrementAndGet();
                                                return new Object();
                                            });
                                    unexpected.set(new AssertionError("cancelled waiter returned"));
                                } catch (InterruptedException expected) {
                                    interrupted.set(true);
                                } catch (Throwable error) {
                                    unexpected.set(error);
                                }
                            });
            cancelled.start();
            waiting(cancelled);
            cancelled.interrupt();
            cancelled.join(2000);
            check(
                    !cancelled.isAlive() && interrupted.get() && unexpected.get() == null,
                    "cancelling waiter does not cancel owner");
            AtomicReference<Object> shared = new AtomicReference<>();
            Thread remaining =
                    new Thread(
                            () -> {
                                try {
                                    shared.set(
                                            flight.get(
                                                    "epoch0:site",
                                                    () -> {
                                                        initialized.incrementAndGet();
                                                        return new Object();
                                                    }));
                                } catch (Throwable error) {
                                    unexpected.set(error);
                                }
                            });
            remaining.start();
            waiting(remaining);
            Future<Object> other = executor.submit(() -> flight.get("epoch1:site", Object::new));
            check(
                    other.get(2, TimeUnit.SECONDS) != result,
                    "new configuration initializes independently");
            release.countDown();
            check(owner.get(2, TimeUnit.SECONDS) == result, "owner receives initialized instance");
            remaining.join(2000);
            check(
                    !remaining.isAlive()
                            && shared.get() == result
                            && initialized.get() == 1
                            && unexpected.get() == null,
                    "all callers share one instance after cancelled waiter");
            try {
                flight.get(
                        "failure",
                        () -> {
                            throw new IOException("fixture");
                        });
                throw new AssertionError("missing failure");
            } catch (IOException expected) {
                check(
                        "fixture".equals(expected.getMessage()),
                        "original initialization exception preserved");
            }
            check(flight.get("failure", () -> result) == result, "failed initialization can retry");
            check(
                    flight.get("epoch0:site", () -> result) == result,
                    "completed flight releases pending entry");
        } finally {
            release.countDown();
            executor.shutdownNow();
        }
        for (int index : new int[] {0, 49, 50, 123, 199}) {
            check(
                    EpisodeSelection.pageFor(index, 200, false) == index / 50,
                    "ascending page for " + index);
            check(
                    EpisodeSelection.pageFor(index, 200, true) == (199 - index) / 50,
                    "descending page for " + index);
        }
        check(EpisodeSelection.pageFor(0, 0, true) == 0, "empty episode list stays on first page");
        check(EpisodeSelection.pageFor(999, 200, false) == 3, "stale episode index bounded");
        EpisodeSelection selection = new EpisodeSelection();
        selection.select("alternate", 2, 200);
        check(
                selection.selected && selection.page == 2 && selection.line.equals("alternate"),
                "browse state retains alternate line and page without playback");
        selection.select("alternate", 9, 51);
        check(selection.page == 1, "shortened episode list bounds restored page");
        check(
                ImageDecodePolicy.sample(1000, 1500, 448, 672, false, true) == 2,
                "detail keeps enough pixels instead of decoding a quarter-size poster");
        check(
                ImageDecodePolicy.sample(2000, 3000, 896, 1344, false, true) == 2,
                "4K detail requests adequate artwork pixels");
        check(
                ImageDecodePolicy.sample(1920, 1080, 448, 672, false, true) == 4,
                "landscape artwork uses fitted dimensions");
        check(
                ImageDecodePolicy.sample(200, 300, 448, 672, false, true) == 1,
                "low resolution source is not pretended to contain extra detail");
        int bounded = ImageDecodePolicy.sample(12000, 18000, 1080, 1620, false, true);
        check(
                (long) (12000 / bounded) * (18000 / bounded) <= 2L * 1024 * 1024,
                "very large poster decode remains bounded");
        check(
                ImageDecodePolicy.targetWidth(0, false) == 320
                        && ImageDecodePolicy.targetHeight(0, false) == 480
                        && ImageDecodePolicy.targetWidth(0, true) == 720
                        && ImageDecodePolicy.targetHeight(0, true) == 1080
                        && ImageDecodePolicy.targetWidth(280, false) == 280
                        && ImageDecodePolicy.targetWidth(9999, false) == 480
                        && ImageDecodePolicy.targetHeight(9999, true) == 1620,
                "image decode target dimensions fallback and bound measured size");
        check(
                !ImageDecodePolicy.cacheKey("https://example.test/a.jpg", 320, 480, false, false)
                                .equals(
                                        ImageDecodePolicy.cacheKey(
                                                "https://example.test/a.jpg",
                                                720,
                                                1080,
                                                false,
                                                true))
                        && !ImageDecodePolicy.cacheKey(
                                        "https://example.test/a.jpg", 320, 480, false, false)
                                .equals(
                                        ImageDecodePolicy.cacheKey(
                                                "https://example.test/a.jpg",
                                                320,
                                                480,
                                                true,
                                                false)),
                "image cache key distinguishes size, crop, and detail mode");
        check(
                ImageDecodePolicy.cacheBytes(32) == 10 * 1024 * 1024
                        && ImageDecodePolicy.cacheBytes(128) == 16 * 1024 * 1024
                        && ImageDecodePolicy.cacheBytes(512) == 32 * 1024 * 1024,
                "image memory cache budget scales within 10MB..32MB bounds");

        // Keep this count synchronized whenever backup-eligible appearance/playback keys are added
        // to or removed from Prefs.KEYS. Security policy switches (such as EXPERIMENTAL_CSP and
        // ONLY_ALLOW_HTTPS_PLUGINS) are intentionally excluded so backups cannot weaken policy.
        check(
                Prefs.KEYS.length == 46,
                "backup settings key table includes TV dock/background/glow, Live HD/merge, TV player style, tunneled playback, and existing appearance settings");
        check(
                Integer.valueOf(3).equals(Prefs.sanitizeSetting(Prefs.PLAYER_ENGINE, 3))
                        && Prefs.sanitizeSetting(Prefs.PLAYER_ENGINE, 4) == null
                        && Integer.valueOf(256)
                                .equals(Prefs.sanitizeSetting(Prefs.MEDIA_CACHE_MB, 256))
                        && Prefs.sanitizeSetting(Prefs.MEDIA_CACHE_MB, 2048) == null
                        && Integer.valueOf(8).equals(Prefs.sanitizeSetting(Prefs.LOUDNESS_BOOST, 8))
                        && Prefs.sanitizeSetting(Prefs.LOUDNESS_BOOST, 20) == null
                        && Boolean.TRUE.equals(Prefs.sanitizeSetting(Prefs.ANIME4K_ENABLED, true))
                        && Boolean.TRUE.equals(
                                Prefs.sanitizeSetting(Prefs.NATIVE_PYTHON_ENABLED, true)),
                "MPV, disk cache, loudness boost, Anime4K, and native Python preferences sanitize within bounds");
        check(
                Integer.valueOf(0).equals(Prefs.sanitizeSetting(Prefs.TV_BG_MODE, 0))
                        && Integer.valueOf(3).equals(Prefs.sanitizeSetting(Prefs.TV_BG_MODE, 3))
                        && Prefs.sanitizeSetting(Prefs.TV_BG_MODE, 4) == null
                        && Prefs.resolveTvBgMode(false, 0, true, true) == Prefs.BG_MODE_WALLPAPER
                        && Prefs.resolveTvBgMode(false, 0, false, true) == Prefs.BG_MODE_ADAPTIVE
                        && Prefs.resolveTvBgMode(false, 0, false, false) == Prefs.BG_MODE_DARK
                        && Prefs.resolveTvBgMode(true, Prefs.BG_MODE_GRADIENT, true, false)
                                == Prefs.BG_MODE_GRADIENT,
                "TV background mode sanitizes bounds and resolves legacy wallpaper/ambient defaults cleanly");
        check(
                Integer.valueOf(0).equals(Prefs.sanitizeSetting(Prefs.TV_GLOW_PRESET, 0))
                        && Integer.valueOf(6).equals(Prefs.sanitizeSetting(Prefs.TV_GLOW_PRESET, 6))
                        && Prefs.sanitizeSetting(Prefs.TV_GLOW_PRESET, 7) == null
                        && Integer.valueOf(0x1f6feb)
                                .equals(Prefs.sanitizeSetting(Prefs.TV_GLOW_COLOR_LEFT, 0x1f6feb))
                        && Integer.valueOf(0x00123456)
                                .equals(
                                        Prefs.sanitizeSetting(
                                                Prefs.TV_GLOW_COLOR_RIGHT, 0x00123456))
                        && Integer.valueOf(0x00ffffff)
                                .equals(
                                        Prefs.sanitizeSetting(
                                                Prefs.TV_GLOW_COLOR_RIGHT, 0x00ffffff))
                        && Boolean.TRUE.equals(Prefs.sanitizeSetting(Prefs.LIVE_HIGH_QUALITY, true))
                        && Boolean.FALSE.equals(
                                Prefs.sanitizeSetting(Prefs.LIVE_MERGE_SOURCES, false)),
                "TV glow preset/RGB colors and Live TV quality preferences sanitize cleanly");
        check(
                Integer.valueOf(0).equals(Prefs.sanitizeSetting(Prefs.TV_DOCK_POSITION, 0))
                        && Integer.valueOf(1)
                                .equals(Prefs.sanitizeSetting(Prefs.TV_DOCK_POSITION, 1))
                        && Prefs.sanitizeSetting(Prefs.TV_DOCK_POSITION, 2) == null,
                "TV dock position round-trips only right and top");
        check(
                Prefs.useTvLeftDock(true, false, -1)
                        && !Prefs.useTvLeftDock(true, true, -1)
                        && Prefs.useTvLeftDock(true, true, 1)
                        && !Prefs.useTvLeftDock(true, false, 0)
                        && !Prefs.useTvLeftDock(false, false, -1)
                        && !Prefs.useTvLeftDock(false, true, 1),
                "TV navigation keeps legacy placement, allows explicit switching, and excludes mobile");
        check(
                Integer.valueOf(1).equals(Prefs.sanitizeSetting(Prefs.TV_NAVIGATION_MODE, 1))
                        && Integer.valueOf(0)
                                .equals(Prefs.sanitizeSetting(Prefs.TV_NAVIGATION_MODE, 0))
                        && Prefs.sanitizeSetting(Prefs.TV_NAVIGATION_MODE, -1) == null
                        && Prefs.sanitizeSetting(Prefs.TV_NAVIGATION_MODE, 2) == null
                        && Prefs.sanitizeSetting(Prefs.TV_NAVIGATION_MODE, "1") == null,
                "backup validates the independent TV navigation mode without changing old position meaning");
        check(
                Prefs.tvAmbientStrength(-1) == 0f
                        && Prefs.tvAmbientStrength(150) == 1f
                        && Prefs.tvAmbientStrength(25) == .25f
                        && Integer.valueOf(0)
                                .equals(Prefs.sanitizeSetting(Prefs.TV_AMBIENT_PERCENT, 0))
                        && Integer.valueOf(100)
                                .equals(Prefs.sanitizeSetting(Prefs.TV_AMBIENT_PERCENT, 100))
                        && Prefs.sanitizeSetting(Prefs.TV_AMBIENT_PERCENT, -1) == null
                        && Prefs.sanitizeSetting(Prefs.TV_AMBIENT_PERCENT, 101) == null,
                "TV ambient percentage accepts backup endpoints, rejects outliers, and clamps runtime strength");
        check(
                Integer.valueOf(0).equals(Prefs.sanitizeSetting(Prefs.TV_PLAYER_STYLE, 0))
                        && Integer.valueOf(1)
                                .equals(Prefs.sanitizeSetting(Prefs.TV_PLAYER_STYLE, 1))
                        && Prefs.sanitizeSetting(Prefs.TV_PLAYER_STYLE, 2) == null,
                "TV player style round-trips only modern card and classic dual-bar");
        check(
                Prefs.clampSubtitleWeight(-10) == 0
                        && Prefs.clampSubtitleWeight(120) == 100
                        && Prefs.clampSubtitleOffsetX(-200) == -100
                        && Prefs.clampSubtitleOffsetX(200) == 100
                        && Integer.valueOf(65)
                                .equals(Prefs.sanitizeSetting(Prefs.SUBTITLE_WEIGHT, 65))
                        && Integer.valueOf(-25)
                                .equals(Prefs.sanitizeSetting(Prefs.SUBTITLE_OFFSET_X, -25)),
                "subtitle weight and horizontal offset clamp and validate within bounds");
        check(
                Prefs.clampNavScale(50) == 85
                        && Prefs.clampNavScale(100) == 100
                        && Prefs.clampNavScale(180) == 140
                        && Integer.valueOf(115)
                                .equals(Prefs.sanitizeSetting(Prefs.NAV_SCALE_PERCENT, 115))
                        && Prefs.sanitizeSetting(Prefs.NAV_SCALE_PERCENT, 50) == null,
                "nav_scale_percent clamps and validates within 85..140 range");
        check(
                Boolean.TRUE.equals(Prefs.sanitizeSetting(Prefs.AUTO_NEXT, true))
                        && Boolean.FALSE.equals(
                                Prefs.sanitizeSetting(Prefs.SHOW_HERO_BANNER, false))
                        && Boolean.TRUE.equals(
                                Prefs.sanitizeSetting(Prefs.REDUCED_TRANSPARENCY, true))
                        && Prefs.sanitizeSetting(Prefs.SHOW_HERO_BANNER, "false") == null
                        && Prefs.sanitizeSetting(Prefs.REDUCED_TRANSPARENCY, "true") == null
                        && Prefs.sanitizeSetting(Prefs.AUTO_NEXT, "true") == null
                        && Prefs.sanitizeSetting(Prefs.EXPERIMENTAL_CSP, true) == null
                        && Prefs.sanitizeSetting(Prefs.ONLY_ALLOW_HTTPS_PLUGINS, true) == null
                        && Prefs.sanitizeSetting(Prefs.ONLY_ALLOW_HTTPS_PLUGINS, false) == null
                        && Prefs.sanitizeSetting(null, true) == null,
                "boolean settings validate type and never restore experimental_csp or only_allow_https_plugins");
        check(
                Integer.valueOf(120).equals(Prefs.sanitizeSetting(Prefs.UI_SCALE_PERCENT, 120))
                        && Integer.valueOf(100)
                                .equals(Prefs.sanitizeSetting(Prefs.UI_SCALE_PERCENT, 999))
                        && Prefs.sanitizeSetting(Prefs.UI_SCALE_PERCENT, "100") == null,
                "ui_scale_percent normalizes to supported TV percentages");
        check(
                Integer.valueOf(5).equals(Prefs.sanitizeSetting(Prefs.HOME_COLUMNS, 5))
                        && Prefs.sanitizeSetting(Prefs.HOME_COLUMNS, 4) == null
                        && Prefs.sanitizeSetting(Prefs.HOME_COLUMNS, 9) == null
                        && Integer.valueOf(30).equals(Prefs.sanitizeSetting(Prefs.SKIP_INTRO, 30))
                        && Prefs.sanitizeSetting(Prefs.SKIP_INTRO, -1) == null
                        && Prefs.sanitizeSetting(Prefs.SKIP_INTRO, 181) == null
                        && Integer.valueOf(20)
                                .equals(Prefs.sanitizeSetting(Prefs.SEARCH_TIMEOUT, 20))
                        && Prefs.sanitizeSetting(Prefs.SEARCH_TIMEOUT, 9) == null,
                "integer settings enforce configured bounds");
        check(
                Float.valueOf(1.5f).equals(Prefs.sanitizeSetting(Prefs.PLAY_SPEED, 1.5))
                        && Prefs.sanitizeSetting(Prefs.PLAY_SPEED, 3.0) == null
                        && Prefs.sanitizeSetting(Prefs.PLAY_SPEED, Double.NaN) == null,
                "play_speed validates speed range");
        check(
                Prefs.clampWallpaperDim(-5) == 0
                        && Prefs.clampWallpaperDim(120) == 100
                        && Prefs.clampSubtitleSize(10) == 25
                        && Prefs.clampSubtitleSize(90) == 65
                        && Prefs.clampSubtitleBottom(-10) == 0
                        && Prefs.clampSubtitleBottom(240) == 180
                        && Prefs.clampSearchTimeoutSeconds(1) == 10
                        && Prefs.clampSearchTimeoutSeconds(99) == 30,
                "preference range clamp helpers bound out-of-range values");
        check(
                Prefs.isBackupObject("MarcoMovie-1", null, 0)
                        && Prefs.isBackupObject(null, "marco-movie-backup", 1)
                        && !Prefs.isBackupObject("other", "other", 2),
                "backup format validator accepts Android and Flutter backup envelopes");
        check(
                "{\"sites\":[]}".equals(Prefs.extractBackupConfigJson("  {\"sites\":[]}  "))
                        && "// header\n{\"sites\":[]}"
                                .equals(Prefs.extractBackupConfigJson("// header\n{\"sites\":[]}"))
                        && "[{\"api\":\"x\"}]"
                                .equals(Prefs.extractBackupConfigJson("[{\"api\":\"x\"}]"))
                        && Boolean.TRUE.equals(Prefs.sanitizeSetting(Prefs.TUNNELED_PLAYBACK, true))
                        && Prefs.extractBackupConfigJson("not-json") == null
                        && Prefs.extractBackupConfigJson("") == null,
                "backup config extractor accepts raw JSON string or object and rejects invalid text");
        check(
                "[\"a\"]".equals(Prefs.sanitizeUserData(Prefs.WATCH_HISTORY, " [\"a\"] "))
                        && "vod1".equals(Prefs.sanitizeUserData(Prefs.SELECTED_SITE, " vod1 "))
                        && Prefs.sanitizeUserData(Prefs.WATCH_HISTORY, "{bad}") == null,
                "backup user data sanitizer preserves cross-platform history, favorites, and selected site");

        AppLog.clear();
        AppLog.w("ReviewCheck", "sample warning", new IOException("disk full"));
        List<String> logs = AppLog.entries();
        check(
                logs.size() == 1
                        && logs.get(0).contains("W/ReviewCheck: sample warning")
                        && logs.get(0).contains("IOException: disk full"),
                "AppLog records structured warning with exception summary");
        for (int i = 0; i < 240; i++) AppLog.i("RingCheck", "item-" + i);
        List<String> boundedLogs = AppLog.entries();
        check(
                boundedLogs.size() == AppLog.CAPACITY
                        && boundedLogs.get(0).contains("item-40")
                        && boundedLogs.get(AppLog.CAPACITY - 1).contains("item-239")
                        && AppLog.dump().contains("item-239"),
                "AppLog ring buffer evicts oldest entries beyond capacity");
        AppLog.clear();

        check(
                TvLayoutPolicy.formFactor(true, true, 360) == TvLayoutPolicy.FORM_TV
                        && TvLayoutPolicy.formFactor(false, false, 800) == TvLayoutPolicy.FORM_TV
                        && TvLayoutPolicy.formFactor(false, true, 720) == TvLayoutPolicy.FORM_TABLET
                        && TvLayoutPolicy.formFactor(false, true, 390) == TvLayoutPolicy.FORM_PHONE,
                "form factor distinguishes TV, tablet, and phone");
        check(
                TvLayoutPolicy.useBottomDock(1080, 2400, TvLayoutPolicy.FORM_PHONE)
                        && !TvLayoutPolicy.useBottomDock(2400, 1080, TvLayoutPolicy.FORM_PHONE)
                        && !TvLayoutPolicy.useBottomDock(1920, 1080, TvLayoutPolicy.FORM_TV),
                "bottom navigation dock activates in portrait mode on touch devices");
        check(
                TvLayoutPolicy.responsiveHomeColumns(390, 5, TvLayoutPolicy.FORM_PHONE, true) == 3
                        && TvLayoutPolicy.responsiveHomeColumns(
                                        960, 5, TvLayoutPolicy.FORM_TV, false)
                                == 5
                        && TvLayoutPolicy.catalogColumns(390, TvLayoutPolicy.FORM_PHONE, true) == 3
                        && TvLayoutPolicy.catalogColumns(960, TvLayoutPolicy.FORM_TV, false) == 4,
                "responsive home and catalog grids adapt column count across phone, tablet, and TV");

        check(
                ListingRoute.isRedirect("folder", null, "a")
                        && ListingRoute.isRedirect("FOLDER", "", "a")
                        && ListingRoute.isRedirect("action", "", "login")
                        && ListingRoute.isRedirect("ACTION", null, "clear_cookie")
                        && ListingRoute.isRedirect(null, "{\"action\":\"x\"}", "a")
                        && ListingRoute.isRedirect(null, null, "msearch:title")
                        && !ListingRoute.isRedirect(null, null, "vod-1")
                        && !ListingRoute.isRedirect("", "", null),
                "folder, action and cross-search cards route away from detail pages");
        Thread main = Thread.currentThread();
        Thread worker = new Thread(() -> {}, "pool-1-thread-1");
        RuntimeException pluginError = new NullPointerException("context");
        pluginError.setStackTrace(
                new StackTraceElement[] {
                    new StackTraceElement("com.github.catvod.spider.merge.yP", "yq", null, 1),
                    new StackTraceElement("java.lang.Thread", "run", null, 764)
                });
        RuntimeException appError = new IllegalStateException("app");
        appError.setStackTrace(
                new StackTraceElement[] {
                    new StackTraceElement("com.pilipala.marcomovie.HomeScreen", "show", null, 1)
                });
        check(
                ListingRoute.isPluginBackgroundCrash(worker, pluginError, main)
                        && ListingRoute.isPluginBackgroundCrash(
                                worker, new RuntimeException("wrap", pluginError), main)
                        && !ListingRoute.isPluginBackgroundCrash(main, pluginError, main)
                        && !ListingRoute.isPluginBackgroundCrash(worker, appError, main)
                        && !ListingRoute.isPluginBackgroundCrash(null, pluginError, main)
                        && ListingRoute.hasPluginFrame(pluginError)
                        && !ListingRoute.hasPluginFrame(appError),
                "only extension crashes on background threads are contained");
        boolean linkageWrapped = false;
        try {
            flight.get(
                    "linkage-error",
                    () -> {
                        throw new NoSuchMethodError("plugin method");
                    });
        } catch (IOException expected) {
            linkageWrapped = expected.getCause() instanceof NoSuchMethodError;
        }
        check(linkageWrapped, "SingleFlight wraps Error into IOException for caller containment");

        System.out.println(
                "OK " + checks + " review regression checks; no device performance claim.");
    }
}
