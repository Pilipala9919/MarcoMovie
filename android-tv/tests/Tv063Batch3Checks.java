package com.pilipala.marcomovie;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.List;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import org.json.JSONArray;
import org.json.JSONObject;

/**
 * Pure-JVM regression verification suite for Batch 3 fixes:
 * - Config Center QR popover capture & anti-blue-box layout normalization
 * - Multi-subscription source lines & Config Center visibility
 * - Issue #75 (TV search crash/reboot, low-RAM detection, engine LRU, SingleFlight, Douban cache)
 * - Issue #74 (TV ANR lock inversions, UI-thread network/disk I/O, 192 MB memory budget)
 * - Issues #72/#73 (MpvPlayer SIGABRT / async destroy, VideoOutput PixelCopy, CPython init & ABI)
 * - Issue #53 (TV OEM Android 9/11 APK install permission flow)
 */
public final class Tv063Batch3Checks {
    private static int passed = 0;
    private static int failed = 0;

    private static void check(String name, boolean ok) {
        if (ok) {
            passed++;
            System.out.println("PASS: " + name);
        } else {
            failed++;
            System.out.println("FAIL: " + name);
        }
    }

    private static String readSrc(String relPath) throws Exception {
        Path p = Paths.get(relPath);
        return new String(Files.readAllBytes(p), StandardCharsets.UTF_8);
    }

    public static void main(String[] args) throws Exception {
        checkQrBubbleCaptureAndLayout();
        checkMultiSubscriptionLinesAndConfigCenters();
        checkIssue75SearchCrashAndDoubanSafety();
        checkIssue74TvAnrAndMemoryBudget();
        checkIssue72And73NativeSigabrtGuards();
        checkIssue53TvApkInstallFlow();
        checkIntroOutroNextEpisodeCarryOver();
        checkPrefsInvariant();

        System.out.println("Batch 3 summary: " + passed + " passed, " + failed + " failed");
        if (failed > 0) {
            System.exit(1);
        }
    }

    private static void checkQrBubbleCaptureAndLayout() throws Exception {
        String bubbleSrc =
                readSrc("android-tv/src/main/java/com/pilipala/marcomovie/NetdiskQrBubble.java");
        int armStart = bubbleSrc.indexOf("static void arm(");
        int armEnd = bubbleSrc.indexOf("static boolean tryCapturePluginQrWindow(");
        String armBody =
                armStart >= 0 && armEnd > armStart ? bubbleSrc.substring(armStart, armEnd) : "";

        check(
                "NetdiskQrBubble.arm does not open premature PopupWindow that wipes active",
                !armBody.contains("showBubbleWindow(")
                        && bubbleSrc.contains("ARM_TTL_MS = 30000L"));
        check(
                "NetdiskQrBubble protects programmatic dismiss with suppressDismissCallback",
                bubbleSrc.contains("suppressDismissCallback = true")
                        && bubbleSrc.contains("!session.suppressDismissCallback")
                        && bubbleSrc.contains("setOutsideTouchable(!a.isTvDevice())"));
        check(
                "NetdiskQrBubble suppresses raw spider window completely offscreen",
                bubbleSrc.contains("wlp.x = -10000")
                        && bubbleSrc.contains("wlp.y = -10000")
                        && bubbleSrc.contains("wlp.alpha = 0f"));

        // Anti-blue-box layout check: decorative View accent bars must NEVER be stretched to
        // weight=1
        check(
                "PluginDialogStyler preserves plain decorative View accent bar width",
                PluginDialogStyler.shouldPreserveFixedRowChildWidth(
                        false, false, false, false, 12, 128));
        check(
                "PluginDialogStyler preserves ImageView and small fixed badge container width",
                PluginDialogStyler.shouldPreserveFixedRowChildWidth(
                                true, false, false, false, 96, 128)
                        && PluginDialogStyler.shouldPreserveFixedRowChildWidth(
                                false, false, false, true, 48, 128));
        check(
                "PluginDialogStyler still balances wide ViewGroup / Button / EditText children",
                !PluginDialogStyler.shouldPreserveFixedRowChildWidth(
                                false, false, false, true, 420, 128)
                        && !PluginDialogStyler.shouldPreserveFixedRowChildWidth(
                                false, true, true, false, 48, 128));

        String stylerSrc =
                readSrc("android-tv/src/main/java/com/pilipala/marcomovie/PluginDialogStyler.java");
        check(
                "PluginDialogStyler compacts standalone QR dialogs on TV (380dp) and supports sub-panel QR",
                stylerSrc.contains("isQrDialog")
                        && stylerSrc.contains("a.dp(380)")
                        && stylerSrc.contains("TYPE_APPLICATION_PANEL"));
    }

    private static void checkMultiSubscriptionLinesAndConfigCenters() throws Exception {
        // Test CJK U+4E28 '丨' in Config Center title ("📺配置丨中心📺")
        Cms.Site okCenter = new Cms.Site();
        okCenter.key = "ok_cfg";
        okCenter.name = "📺配置丨中心📺";
        okCenter.api = "csp_CustomCenter";
        okCenter.group = "OK猫";

        Cms.Site fanCenter = new Cms.Site();
        fanCenter.key = "fan_cfg";
        fanCenter.name = "配置┃中心";
        fanCenter.api = "csp_PanConfig";
        fanCenter.group = "饭太硬";

        Cms.Site normalSite = new Cms.Site();
        normalSite.key = "normal_1";
        normalSite.name = "普通影视";
        normalSite.api = "https://source.test/api.php/provide/vod/";
        normalSite.group = "饭太硬";

        check(
                "Dedicated Config Center detection handles CJK 丨 and generic 配置+中心 names",
                SourceController.isDedicatedConfigSite(okCenter)
                        && AccountPanel.isLikelyConfigCenterSite(okCenter)
                        && SourceController.isDedicatedConfigSite(fanCenter)
                        && !AccountPanel.isLikelyConfigCenterSite(normalSite));

        List<Cms.Site> centers =
                AccountPanel.collectConfigCenterSites(
                        Arrays.asList(okCenter, normalSite, fanCenter), "饭太硬", "");
        check(
                "collectConfigCenterSites surfaces ALL Config Centers across multiple subscriptions",
                centers.size() == 2
                        && "fan_cfg".equals(centers.get(0).key)
                        && "ok_cfg".equals(centers.get(1).key));

        // Test SubscriptionManager.mergeSources with null rawSite entry + warehouse depots +
        // multi-groups
        JSONObject subA =
                new JSONObject()
                        .put("spider", "https://a.example/a.jar")
                        .put(
                                "_marco_depots",
                                new JSONArray()
                                        .put(
                                                new JSONObject()
                                                        .put("name", "仓A1")
                                                        .put("url", "https://a.example/d1.json")))
                        .put(
                                "sites",
                                new JSONArray()
                                        .put(JSONObject.NULL)
                                        .put(
                                                new JSONObject()
                                                        .put("key", "cfg")
                                                        .put("name", "配置丨中心A")
                                                        .put("type", 3)
                                                        .put("api", "csp_Wexokconfig"))
                                        .put(
                                                new JSONObject()
                                                        .put("key", "vod1")
                                                        .put("name", "线路A1")
                                                        .put("type", 1)
                                                        .put("api", "https://a.example/vod")));
        JSONObject subB =
                new JSONObject()
                        .put("spider", "https://b.example/b.jar")
                        .put(
                                "_marco_depots",
                                new JSONArray()
                                        .put(
                                                new JSONObject()
                                                        .put("name", "仓B1")
                                                        .put("url", "https://b.example/d1.json")))
                        .put(
                                "sites",
                                new JSONArray()
                                        .put(
                                                new JSONObject()
                                                        .put("key", "cfg")
                                                        .put("name", "配置中心B")
                                                        .put("type", 3)
                                                        .put("api", "csp_PanConfig"))
                                        .put(
                                                new JSONObject()
                                                        .put("key", "vod2")
                                                        .put("name", "线路B1")
                                                        .put("type", 1)
                                                        .put("api", "https://b.example/vod")));

        SubscriptionManager.MergedResult merged =
                SubscriptionManager.mergeSources(
                        Arrays.asList(
                                new SubscriptionManager.SourceBundle(
                                        "订阅A", "https://a.example/sub.json", subA.toString(), 100L),
                                new SubscriptionManager.SourceBundle(
                                        "订阅B",
                                        "https://b.example/sub.json",
                                        subB.toString(),
                                        200L)));
        check(
                "SubscriptionManager.mergeSources preserves all sites, unique keys, groups, and depots",
                merged.config.sites.size() == 4
                        && merged.config.depots.length() == 2
                        && "订阅A".equals(merged.config.sites.get(0).group)
                        && "订阅B".equals(merged.config.sites.get(2).group)
                        && !merged.config.sites.get(0).key.equals(merged.config.sites.get(2).key));

        String synthGroupB = SourceController.extractGroupRawJson(merged.config, "订阅B");
        Cms.Config parsedSynthB = Cms.parseConfig(synthGroupB, "");
        check(
                "SourceController.extractGroupRawJson preserves existing group lines cleanly",
                parsedSynthB.sites.size() == 2 && "配置中心B".equals(parsedSynthB.sites.get(0).name));

        String accountSrc =
                readSrc("android-tv/src/main/java/com/pilipala/marcomovie/AccountPanel.java");
        String pickerSrc =
                readSrc("android-tv/src/main/java/com/pilipala/marcomovie/SourcePicker.java");
        String scSrc =
                readSrc("android-tv/src/main/java/com/pilipala/marcomovie/SourceController.java");
        check(
                "AccountPanel renders inline multi-Config-Center tabs & ConfigLibrary merge bar",
                accountSrc.contains("account-config-center-tabs")
                        && accountSrc.contains("account-merge-all-subscriptions")
                        && accountSrc.contains("account-embed-cat:home"));
        check(
                "SourcePicker exposes one-click multi-subscription merge pill & group labels",
                pickerSrc.contains("source-merge-all-subscriptions")
                        && pickerSrc.contains("showGroupSuffix"));
        check(
                "SourceController.addressImportDialog defaults appendCheck=true for multi-source display",
                scSrc.contains("appendCheck.setChecked(true)")
                        && scSrc.contains("extractGroupRawJson"));
    }

    private static void checkIssue75SearchCrashAndDoubanSafety() throws Exception {
        check(
                "Low-RAM TV detection checks memoryClass<=256 even when largeHeap inflates maxHeap to 512MB",
                GlobalSearchScreen.isLowRamMemoryClass(false, 192, 512L * 1024L * 1024L)
                        && GlobalSearchScreen.isLowRamMemoryClass(false, 256, 512L * 1024L * 1024L)
                        && !GlobalSearchScreen.isLowRamMemoryClass(false, 512, 512L * 1024L * 1024L)
                        && GlobalSearchScreen.isLowRamMemoryClass(true, 512, 512L * 1024L * 1024L));

        check(
                "SearchCoordinator caps wedged thread expansion tightly for TV and mobile",
                SearchCoordinator.computePoolCapacity(3, 50, 6) == 6
                        && SearchCoordinator.computePoolCapacity(6, 50, 8) == 8
                        && SearchCoordinator.computePoolCapacity(6, 2, 12) == 8
                        && SearchCoordinator.computePoolCapacity(6, 100, 20) == 16);

        // Functional OOM circuit breaker test in SearchCoordinator
        AtomicInteger executed = new AtomicInteger(0);
        AtomicInteger hookCalls = new AtomicInteger(0);
        List<SearchCoordinator.Outcome> outcomes = new CopyOnWriteArrayList<>();
        CountDownLatch allDone = new CountDownLatch(4);
        SearchCoordinator.onLowMemoryHook = hookCalls::incrementAndGet;
        List<Cms.Site> sites = new ArrayList<>();
        for (int i = 0; i < 4; i++) {
            Cms.Site s = new Cms.Site();
            s.key = "oom_site_" + i;
            s.name = "OOM-" + i;
            s.type = 1;
            s.api = "https://oom.example/" + i;
            sites.add(s);
        }
        try (SearchCoordinator sc =
                new SearchCoordinator(
                        (site, q) -> {
                            int n = executed.incrementAndGet();
                            if (n == 1) throw new OutOfMemoryError("simulated TV OOM");
                            return Collections.emptyList();
                        },
                        (site, vids, out) -> {
                            outcomes.add(out);
                            allDone.countDown();
                        },
                        3000,
                        8000,
                        8,
                        1)) {
            sc.start(sites, "test");
            check(
                    "SearchCoordinator OOM aborts remaining jobs cleanly",
                    allDone.await(5, TimeUnit.SECONDS));
        } finally {
            SearchCoordinator.onLowMemoryHook = null;
        }
        check(
                "SearchCoordinator triggered low-memory hook and aborted subsequent jobs as BUSY",
                executed.get() == 1
                        && hookCalls.get() == 1
                        && outcomes.size() == 4
                        && outcomes.contains(SearchCoordinator.Outcome.FAILED)
                        && outcomes.contains(SearchCoordinator.Outcome.BUSY));

        // SingleFlight deduplication and completion cleanup
        SingleFlight<String> sf = new SingleFlight<>();
        AtomicInteger runs = new AtomicInteger(0);
        String v1 = sf.get("k1", () -> "val-" + runs.incrementAndGet());
        String v2 = sf.get("k1", () -> "val-" + runs.incrementAndGet());
        check(
                "SingleFlight cleans up finished entries and supports retries",
                "val-1".equals(v1) && "val-2".equals(v2));

        String mainSrc =
                readSrc("android-tv/src/main/java/com/pilipala/marcomovie/MainActivity.java");
        String scSrc =
                readSrc("android-tv/src/main/java/com/pilipala/marcomovie/SourceController.java");
        String doubanSrc =
                readSrc(
                        "android-tv/src/main/java/com/pilipala/marcomovie/DoubanScoreRepository.java");
        check(
                "MainActivity.engines uses access-order LRU LinkedHashMap and SourceController caps TV engines",
                mainSrc.contains("new LinkedHashMap<>(16, 0.75f, true)")
                        && SourceController.maxCachedEngines(true) == 14
                        && SourceController.maxCachedEngines(false) == 24
                        && scSrc.contains("a.searchScreen != null"));
        check(
                "DoubanScoreRepository uses async DISK_IO_POOL and never leaks INFLIGHT on DiscardOldest",
                doubanSrc.contains("DISK_IO_POOL")
                        && doubanSrc.contains("ensureDiskLoadedAsync")
                        && !doubanSrc.contains("DiscardOldestPolicy")
                        && doubanSrc.contains("class FetchTask"));
    }

    private static void checkIssue74TvAnrAndMemoryBudget() throws Exception {
        String cspSrc = readSrc("android-tv/src/main/java/com/pilipala/marcomovie/CspEngine.java");
        String castSrc =
                readSrc("android-tv/src/main/java/com/pilipala/marcomovie/CastService.java");
        String mainSrc =
                readSrc("android-tv/src/main/java/com/pilipala/marcomovie/MainActivity.java");
        String scSrc =
                readSrc("android-tv/src/main/java/com/pilipala/marcomovie/SourceController.java");
        String homeSrc =
                readSrc("android-tv/src/main/java/com/pilipala/marcomovie/HomeScreen.java");
        String posterSrc =
                readSrc("android-tv/src/main/java/com/pilipala/marcomovie/ImmersivePoster.java");

        check(
                "CspEngine decouples loader() LOADER_LOCK from lock-free syncAllPluginActivities()",
                cspSrc.contains("private static final Object LOADER_LOCK")
                        && cspSrc.contains("new java.util.concurrent.ConcurrentHashMap<>()")
                        && cspSrc.contains("static void syncAllPluginActivities(")
                        && !cspSrc.contains("static synchronized void syncAllPluginActivities(")
                        && !cspSrc.contains("static synchronized DexClassLoader loader("));
        check(
                "CastService.close() offloads SSDP byebye & socket close off UI thread",
                castSrc.contains("\"cast-service-close\"")
                        && mainSrc.contains("void stopCastService()")
                        && !mainSrc.contains("synchronized void stopCastService()"));
        check(
                "SourceController.ensureProxy uses dedicated PROXY_LOCK instead of Activity monitor",
                scSrc.contains("private static final Object PROXY_LOCK")
                        && scSrc.contains("synchronized (PROXY_LOCK)"));
        check(
                "HomeScreen.loadHome avoids synchronous SharedPreferences.commit() on UI thread",
                homeSrc.contains(
                        "putString(Prefs.LOADING_SITE, site.key == null ? \"\" : site.key).apply()"));
        check(
                "ImmersivePoster.applyMemoryBudget scales down caches for 192 MB TVs too",
                posterSrc.contains("memoryClassMb > 192") && posterSrc.contains("5 * 1024 * 1024"));
    }

    private static void checkIssue72And73NativeSigabrtGuards() throws Exception {
        check(
                "MpvPlayer disables hdr-compute-peak on both 64-bit and 32-bit Android",
                "no".equals(MpvPlayer.resolveHdrComputePeak(true))
                        && "no".equals(MpvPlayer.resolveHdrComputePeak(false)));
        long eff192 = MpvPlayer.effectiveHeapBudgetBytes(192, 512L * 1024L * 1024L);
        check(
                "MpvPlayer respects 192 MB memoryClass against largeHeap inflation",
                eff192 == 192L * 1024L * 1024L
                        && MpvPlayer.mpvBufferBytes(eff192, false) <= 32 * 1024 * 1024);

        String mpvSrc = readSrc("android-tv/src/main/java/com/pilipala/marcomovie/MpvPlayer.java");
        check(
                "MpvPlayer offloads MPVLib.destroy(), serializes with MPV_NATIVE_LOCK, fixes released & volatile hdrChangedListener",
                mpvSrc.contains("MPV_NATIVE_LOCK")
                        && mpvSrc.contains("MPV_DESTROY_POOL")
                        && mpvSrc.contains("awaitPendingDestroy(")
                        && mpvSrc.contains("markBaseReleased();")
                        && mpvSrc.contains("protected void notifyBufferingChanged(")
                        && mpvSrc.contains(
                                "private volatile OnHdrChangedListener hdrChangedListener;"));

        check(
                "VideoOutput skips SurfaceView PixelCopy whenever MpvPlayer (externalNativeRenderer) is active",
                VideoOutput.shouldSkipSurfacePixelCopy(true, false, false, true)
                        && !VideoOutput.shouldSkipSurfacePixelCopy(true, false, false, false)
                        && !VideoOutput.shouldSkipSurfacePixelCopy(false, false, false, true));

        String pbCtrlSrc =
                readSrc("android-tv/src/main/java/com/pilipala/marcomovie/PlaybackController.java");
        check(
                "PlaybackController wires surface.setExternalNativeRenderer(ready instanceof MpvPlayer)",
                pbCtrlSrc.contains("surface.setExternalNativeRenderer(")
                        && pbCtrlSrc.contains("ready instanceof MpvPlayer"));

        check(
                "NativePythonEngine.selectDynloadAbi strictly matches 32-bit process bitness on 64-bit SoC",
                "armeabi-v7a"
                                .equals(
                                        NativePythonEngine.selectDynloadAbi(
                                                new String[] {"arm64-v8a", "armeabi-v7a"},
                                                false,
                                                true,
                                                true))
                        && "arm64-v8a"
                                .equals(
                                        NativePythonEngine.selectDynloadAbi(
                                                new String[] {"arm64-v8a", "armeabi-v7a"},
                                                true,
                                                true,
                                                true)));

        String pyBridgeSrc = readSrc("android-tv/src/main/cpp/python_bridge.c");
        check(
                "python_bridge.c guards Py_IsInitialized() before Py_InitializeFromConfig",
                pyBridgeSrc.contains("if (Py_IsInitialized())")
                        && pyBridgeSrc.contains("PyGILState_Ensure()"));
    }

    private static void checkIssue53TvApkInstallFlow() throws Exception {
        check(
                "UpdateScreen prefers direct install on TV even when stub permission page exists",
                UpdateScreen.shouldPreferDirectInstallOnTv(true, false)
                        && !UpdateScreen.shouldPreferDirectInstallOnTv(false, false)
                        && !UpdateScreen.shouldPreferDirectInstallOnTv(true, true));

        String updateSrc =
                readSrc("android-tv/src/main/java/com/pilipala/marcomovie/UpdateScreen.java");
        check(
                "UpdateScreen.result surfaces showInstallBlockedDialog() on TV install failure",
                updateSrc.contains("shouldPreferDirectInstallOnTv(a.isTvDevice(), false)")
                        && updateSrc.contains("a.updateScreen.showInstallBlockedDialog();"));
    }

    private static void checkIntroOutroNextEpisodeCarryOver() throws Exception {
        // 1. PlaybackControls must recreate TvMarkerHost when switching episode/line or stale
        check(
                "PlaybackControls.shouldRecreateMarkerHost recreates on episode switch or line switch",
                PlaybackControls.shouldRecreateMarkerHost(false, true, true, true)
                        && PlaybackControls.shouldRecreateMarkerHost(true, false, true, true)
                        && PlaybackControls.shouldRecreateMarkerHost(true, true, false, true)
                        && PlaybackControls.shouldRecreateMarkerHost(true, true, true, false)
                        && !PlaybackControls.shouldRecreateMarkerHost(true, true, true, true));

        // 2. TvMarkerHost.computeSeriesCarryOverSeconds converts intro/outro markers accurately
        check(
                "TvMarkerHost.computeSeriesCarryOverSeconds converts intro and outro for next episode",
                TvMarkerHost.computeSeriesCarryOverSeconds(true, 92_000L, 2_700_000L) == 92
                        && TvMarkerHost.computeSeriesCarryOverSeconds(false, 2_580_000L, 2_700_000L)
                                == 120
                        && TvMarkerHost.computeSeriesCarryOverSeconds(false, 900_000L, 2_700_000L)
                                == 0
                        && TvMarkerHost.computeSeriesCarryOverSeconds(false, 2_580_000L, 0L) == 0);

        // 3. VideoSkipStore keeps the same series key across Episode 1 -> Episode 2 -> Episode 3
        Cms.Video series = new Cms.Video();
        series.id = "vod-series-88";
        series.title = "庆余年";
        Cms.Episode ep1 = new Cms.Episode();
        ep1.name = "第01集";
        ep1.url = "https://cdn.example/ep1.m3u8";
        Cms.Episode ep2 = new Cms.Episode();
        ep2.name = "第02集";
        ep2.url = "https://cdn.example/ep2.m3u8";
        String key1 = VideoSkipStore.videoKeyFrom(series, ep1);
        String key2 = VideoSkipStore.videoKeyFrom(series, ep2);
        String raw = VideoSkipStore.writeSkip("[]", "siteA", key1, true, 92, 1000L);
        raw = VideoSkipStore.writeSkip(raw, "siteA", key1, false, 120, 1001L);
        check(
                "VideoSkipStore carries over intro & outro across episodes of the same series",
                key1.equals(key2)
                        && VideoSkipStore.readIntro(raw, "siteA", key2) == 92
                        && VideoSkipStore.readOutro(raw, "siteA", key2) == 120);

        // 4. Source wiring: resetEpisodeTransientState calls resetMarkers(), markers() self-heals,
        //    and TvMarkerHost.confirm propagates series skip seconds to VideoSkipStore
        String ctrlSrc =
                readSrc("android-tv/src/main/java/com/pilipala/marcomovie/PlaybackControls.java");
        String hostSrc =
                readSrc("android-tv/src/main/java/com/pilipala/marcomovie/TvMarkerHost.java");
        int resetStart = ctrlSrc.indexOf("void resetEpisodeTransientState()");
        int resetEnd = ctrlSrc.indexOf("private void cancelPendingSkipTap()");
        String resetBody =
                resetStart >= 0 && resetEnd > resetStart
                        ? ctrlSrc.substring(resetStart, resetEnd)
                        : "";
        check(
                "PlaybackControls.resetEpisodeTransientState resets stale TvMarkerHost & markerTail",
                resetBody.contains("resetMarkers();")
                        && ctrlSrc.contains("shouldRecreateMarkerHost(")
                        && ctrlSrc.contains("pendingResumeIsIntro"));
        check(
                "TvMarkerHost.confirm syncs series-level skip seconds to VideoSkipStore",
                hostSrc.contains("computeSeriesCarryOverSeconds(")
                        && hostSrc.contains("PlaybackControls.setVideoSkip(")
                        && hostSrc.contains("controls.updateLabels()"));
    }

    private static void checkPrefsInvariant() {
        check("Prefs.KEYS remains strictly 46 keys", Prefs.KEYS.length == 46);
    }
}
