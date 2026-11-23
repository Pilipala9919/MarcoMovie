package com.pilipala.marcomovie;

import com.sun.net.httpserver.HttpServer;
import java.io.File;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.InetSocketAddress;
import java.net.URL;
import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.Arrays;
import java.util.Collections;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;

/**
 * End-to-end JVM verification for Android TV 0.6.1 feedback fixes:
 * (1) MPV mediaBadges NPE & native SIGABRT lifecycle/buffer guards,
 * (2) daily automatic subscription updates (single + merged multi-source),
 * (3) netdisk popup compatibility across multiple subscription Config Centers, and
 * (4) multi-source batch import with automatic grouping & deterministic key/jar isolation.
 */
public final class Tv061FeedbackChecks {
    private static int passed = 0;

    private static void check(boolean condition, String label) {
        if (!condition) {
            throw new AssertionError("FAILED: " + label);
        }
        passed++;
    }

    private static String readSource(String fileName) throws Exception {
        File f = new File("android-tv/src/main/java/com/pilipala/marcomovie", fileName);
        return new String(Files.readAllBytes(f.toPath()), StandardCharsets.UTF_8);
    }

    public static void main(String[] args) throws Exception {
        testMpvCrashFixesAndNativeGuards();
        testMultiSourceParsingAndAutoGrouping();
        testDailySubscriptionAutoUpdate();
        testNetdiskPopupMultiConfigCenterCompatibility();
        testConfigTransferServerMultiLineAndSecurity();
        System.out.println("PASS Tv061FeedbackChecks (" + passed + " checks)");
    }

    private static void testMpvCrashFixesAndNativeGuards() throws Exception {
        // Sony BRAVIA 4K VH21 crash state: 4K 3840x1608 HEVC EAC3 MPV Anime4K
        List<String> sonyBadges =
                MpvPlayer.buildMediaBadges(
                        3840, 1608, "H.265 / HEVC", "eac3", "", "mediacodec-copy", true);
        check(
                sonyBadges.equals(Arrays.asList("4K", "HEVC", "DD+", "MPV Anime4K")),
                "MpvPlayer.buildMediaBadges formats Sony 4K HEVC EAC3 Anime4K badges: "
                        + sonyBadges);

        // TCL tcl_m7642 crash state: 1080P 1920x804 H.264 AAC MPV
        List<String> tclBadges =
                MpvPlayer.buildMediaBadges(
                        1920, 804, "H.264 / AVC / MPEG-4 AVC", "aac", "", "mediacodec", false);
        check(
                tclBadges.equals(Arrays.asList("1080P", "H.264", "AAC", "MPV 播放")),
                "MpvPlayer.buildMediaBadges formats TCL 1080P H.264 AAC MPV badges: " + tclBadges);

        // HDR10 + TrueHD detection
        List<String> hdrBadges =
                MpvPlayer.buildMediaBadges(3840, 2160, "hevc", "truehd", "pq", "mediacodec", false);
        check(
                hdrBadges.equals(Arrays.asList("4K", "HDR10", "TRUEHD", "MPV 播放")),
                "MpvPlayer.buildMediaBadges detects HDR10 from PQ gamma");
        check(
                MpvPlayer.isHdrGammaOrCodec("pq", "hevc")
                        && MpvPlayer.isHdrGammaOrCodec("hlg", "hevc")
                        && MpvPlayer.isHdrGammaOrCodec("", "Dolby Vision")
                        && !MpvPlayer.isHdrGammaOrCodec("bt.1886", "h264"),
                "MpvPlayer.isHdrGammaOrCodec classifies HDR vs SDR accurately");
        check(
                "video/hevc".equals(MpvPlayer.normalizeVideoMime("H.265 / HEVC"))
                        && "video/avc".equals(MpvPlayer.normalizeVideoMime("H.264 / AVC"))
                        && "video/dolby-vision"
                                .equals(MpvPlayer.normalizeVideoMime("Dolby Vision")),
                "MpvPlayer.normalizeVideoMime maps libmpv codec names to standard MIMEs");

        // 32-bit TV native buffer cap prevents SIGABRT/OOM on 192MB heap armeabi-v7a TVs
        check(
                MpvPlayer.mpvBufferBytes(192L * 1024L * 1024L, false) == 32 * 1024 * 1024,
                "32-bit 192MB TV caps MPV demuxer buffer at 32 MiB");
        check(
                MpvPlayer.mpvBufferBytes(512L * 1024L * 1024L, true)
                        == MoviePlayer.safeBufferBytes(512L * 1024L * 1024L),
                "64-bit devices retain full MoviePlayer.safeBufferBytes budget");

        // Source-level invariants for crash root causes
        String mpvSrc = readSource("MpvPlayer.java");
        String movieSrc = readSource("MoviePlayer.java");
        check(
                mpvSrc.contains("public List<String> mediaBadges()")
                        && mpvSrc.contains("MPVLib.setOptionString(\"vo\", \"null\")")
                        && mpvSrc.contains("MPVLib.setOptionString(\"force-window\", \"no\")")
                        && mpvSrc.contains("nativeCreated = true")
                        && mpvSrc.contains("MPVLib.setPropertyString(\"vo\", \"null\")"),
                "MpvPlayer overrides mediaBadges and enforces safe vo=null init/detach lifecycle");
        check(
                movieSrc.contains("if (released || exo == null) return out;"),
                "MoviePlayer.mediaBadges guards against null exo");
    }

    private static void testMultiSourceParsingAndAutoGrouping() throws Exception {
        // 1. Multi-line + named spec parsing
        List<SubscriptionManager.ImportSpec> specs =
                SubscriptionManager.parseImportSpecsStrict(
                        "主力源,https://alpha.example/tv.json\n"
                                + "备用源 | https://beta.example/api.json\n"
                                + "https://gamma.example/sub/ok.json\n"
                                + "主力源,https://alpha.example/tv.json\n");
        check(
                specs.size() == 3,
                "parseImportSpecsStrict parses and deduplicates 3 multi-line specs");
        check(
                "主力源".equals(specs.get(0).name)
                        && "https://alpha.example/tv.json".equals(specs.get(0).url)
                        && "备用源".equals(specs.get(1).name)
                        && "https://beta.example/api.json".equals(specs.get(1).url)
                        && "".equals(specs.get(2).name)
                        && "https://gamma.example/sub/ok.json".equals(specs.get(2).url),
                "parseImportSpecsStrict extracts group labels and URLs accurately");

        // Rejects non-HTTP lines
        boolean rejectedFile = false;
        try {
            SubscriptionManager.parseImportSpecsStrict(
                    "https://alpha.example/tv.json\nfile:///etc/passwd");
        } catch (Exception expected) {
            rejectedFile = true;
        }
        check(rejectedFile, "parseImportSpecsStrict rejects mixed file:// line");

        // 2. Auto-grouping merge preserves per-source spider JAR, resolves relative paths,
        //    and deterministically disambiguates colliding keys
        String rawA =
                "{"
                        + "\"spider\":\"./spiderA.jar;md5;aaaa\","
                        + "\"sites\":["
                        + "{\"key\":\"csp_Douban\",\"name\":\"豆瓣热播\",\"type\":3,\"api\":\"csp_Douban\",\"quickSearch\":1},"
                        + "{\"key\":\"csp_Config\",\"name\":\"配置中心\",\"type\":3,\"api\":\"csp_MyDrive\",\"ext\":\"./extA.json\"}"
                        + "],"
                        + "\"parses\":[{\"name\":\"P1\",\"type\":1,\"url\":\"https://parse-a.example/jx?url=\"}],"
                        + "\"ads\":[\"ads-a.example\"]"
                        + "}";
        String rawB =
                "{"
                        + "\"spider\":\"./spiderB.jar;md5;bbbb\","
                        + "\"sites\":["
                        + "{\"key\":\"csp_Douban\",\"name\":\"豆瓣B\",\"type\":3,\"api\":\"csp_Douban\"},"
                        + "{\"key\":\"csp_Pan\",\"name\":\"网盘配置\",\"type\":3,\"api\":\"csp_PanConfig\",\"ext\":\"./extB.json\"}"
                        + "],"
                        + "\"parses\":[{\"name\":\"P2\",\"type\":1,\"url\":\"https://parse-b.example/jx?url=\"}],"
                        + "\"ads\":[\"ads-b.example\"]"
                        + "}";

        List<SubscriptionManager.SourceBundle> bundles =
                Arrays.asList(
                        new SubscriptionManager.SourceBundle(
                                "源甲", "https://alpha.example/dir/config.json", rawA, 1000L),
                        new SubscriptionManager.SourceBundle(
                                "源乙", "https://beta.example/dir/config.json", rawB, 2000L));
        SubscriptionManager.MergedResult merged1 = SubscriptionManager.mergeSources(bundles);
        SubscriptionManager.MergedResult merged2 = SubscriptionManager.mergeSources(bundles);

        check(merged1.sourceCount == 2, "mergeSources records 2 sources");
        check(
                merged1.groupNames.equals(Arrays.asList("源甲", "源乙")),
                "mergeSources preserves distinct group names");
        check(merged1.config.sites.size() == 4, "mergeSources keeps all 4 sites without key loss");

        Cms.Site a0 = merged1.config.sites.get(0);
        Cms.Site a1 = merged1.config.sites.get(1);
        Cms.Site b0 = merged1.config.sites.get(2);
        Cms.Site b1 = merged1.config.sites.get(3);
        check("源甲".equals(a0.group) && "源甲".equals(a1.group), "Source A sites grouped as 源甲");
        check("源乙".equals(b0.group) && "源乙".equals(b1.group), "Source B sites grouped as 源乙");
        check(
                "https://alpha.example/dir/spiderA.jar;md5;aaaa".equals(a0.jar)
                        && "https://beta.example/dir/spiderB.jar;md5;bbbb".equals(b0.jar),
                "Each merged site retains its own source's resolved spider JAR");
        check(
                "https://alpha.example/dir/extA.json".equals(String.valueOf(a1.ext))
                        && "https://beta.example/dir/extB.json".equals(String.valueOf(b1.ext)),
                "Each merged site resolves relative ext paths against its own origin");
        check(
                !a0.key.equals(b0.key) && b0.key.equals(merged2.config.sites.get(2).key),
                "Colliding site keys are disambiguated deterministically across merges");
        check(
                merged1.config.parses.size() == 2 && merged1.config.ads.size() == 2,
                "Parses and ads merged cleanly across sources");
        check(
                SubscriptionManager.readMultiSourceMeta(merged1.rawJson).size() == 2,
                "Merged config embeds _marco_multi_sources metadata for daily updates");

        // 3. Fair cap when total sites > 500
        StringBuilder bigA = new StringBuilder("{\"sites\":[");
        StringBuilder bigB = new StringBuilder("{\"sites\":[");
        for (int i = 0; i < 320; i++) {
            if (i > 0) {
                bigA.append(',');
                bigB.append(',');
            }
            bigA.append("{\"key\":\"a")
                    .append(i)
                    .append("\",\"name\":\"A")
                    .append(i)
                    .append("\",\"type\":1,\"api\":\"https://a.example/vod")
                    .append(i)
                    .append("\"}");
            bigB.append("{\"key\":\"b")
                    .append(i)
                    .append("\",\"name\":\"B")
                    .append(i)
                    .append("\",\"type\":1,\"api\":\"https://b.example/vod")
                    .append(i)
                    .append("\"}");
        }
        bigA.append("]}");
        bigB.append("]}");
        SubscriptionManager.MergedResult capped =
                SubscriptionManager.mergeSources(
                        Arrays.asList(
                                new SubscriptionManager.SourceBundle(
                                        "大源A", "https://a.example/c.json", bigA.toString(), 1L),
                                new SubscriptionManager.SourceBundle(
                                        "大源B", "https://b.example/c.json", bigB.toString(), 1L)));
        int countA = 0, countB = 0;
        for (Cms.Site s : capped.config.sites) {
            if ("大源A".equals(s.group)) countA++;
            else if ("大源B".equals(s.group)) countB++;
        }
        check(
                capped.config.sites.size() == 500 && countA == 250 && countB == 250,
                "Fair site cap splits 500 budget evenly (250/250) instead of failing");
    }

    private static void testDailySubscriptionAutoUpdate() throws Exception {
        long day = SubscriptionManager.AUTO_UPDATE_INTERVAL_MS;
        check(!SubscriptionManager.isDueForDailyUpdate(10_000L, 10_000L + day - 1), "<24h not due");
        check(SubscriptionManager.isDueForDailyUpdate(10_000L, 10_000L + day), ">=24h is due");
        check(SubscriptionManager.isDueForDailyUpdate(0L, 10_000L), "never-updated is due");
        check(!SubscriptionManager.isDueForDailyUpdate(20_000L, 10_000L), "clock skew not due");
        check(
                Boolean.TRUE.equals(Prefs.sanitizeSetting(Prefs.SUBSCRIPTION_AUTO_UPDATE, true)),
                "Prefs.SUBSCRIPTION_AUTO_UPDATE sanitizes boolean");
        check(Prefs.KEYS.length == 46, "Prefs.KEYS length remains strictly 46");

        // Spin up local HTTP server serving two subscriptions
        final AtomicReference<String> bodyA =
                new AtomicReference<String>(
                        "{\"spider\":\"./a1.jar\",\"sites\":[{\"key\":\"sA\",\"name\":\"源A-v1\",\"type\":1,\"api\":\"https://a.example/api\"}]}");
        final AtomicReference<String> bodyB =
                new AtomicReference<String>(
                        "{\"spider\":\"./b1.jar\",\"sites\":[{\"key\":\"sB\",\"name\":\"源B-v1\",\"type\":1,\"api\":\"https://b.example/api\"}]}");
        final AtomicBoolean failB = new AtomicBoolean(false);
        final AtomicInteger hitsA = new AtomicInteger();
        final AtomicInteger hitsB = new AtomicInteger();

        HttpServer server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        server.createContext(
                "/subA.json",
                ex -> {
                    hitsA.incrementAndGet();
                    byte[] data = bodyA.get().getBytes(StandardCharsets.UTF_8);
                    ex.sendResponseHeaders(200, data.length);
                    try (OutputStream out = ex.getResponseBody()) {
                        out.write(data);
                    }
                });
        server.createContext(
                "/subB.json",
                ex -> {
                    hitsB.incrementAndGet();
                    if (failB.get()) {
                        ex.sendResponseHeaders(500, -1);
                        ex.close();
                        return;
                    }
                    byte[] data = bodyB.get().getBytes(StandardCharsets.UTF_8);
                    ex.sendResponseHeaders(200, data.length);
                    try (OutputStream out = ex.getResponseBody()) {
                        out.write(data);
                    }
                });
        server.start();
        File tmpDir = Files.createTempDirectory("sub-auto-update-").toFile();
        try {
            String urlA = "http://127.0.0.1:" + server.getAddress().getPort() + "/subA.json";
            String urlB = "http://127.0.0.1:" + server.getAddress().getPort() + "/subB.json";
            ConfigLibrary library = new ConfigLibrary(tmpDir);
            long t0 = 1_700_000_000_000L;
            library.remember(bodyA.get(), urlA, "分组A", "", t0);
            library.remember(bodyB.get(), urlB, "分组B", "", t0);

            SubscriptionManager.MergedResult initialMerged =
                    SubscriptionManager.mergeSources(
                            Arrays.asList(
                                    new SubscriptionManager.SourceBundle(
                                            "分组A", urlA, bodyA.get(), t0),
                                    new SubscriptionManager.SourceBundle(
                                            "分组B", urlB, bodyB.get(), t0)));

            // 1. After 12 hours -> nothing due
            SubscriptionManager.RefreshSummary early =
                    SubscriptionManager.refreshDueSubscriptions(
                            library,
                            initialMerged.origin,
                            initialMerged.rawJson,
                            t0 + day / 2,
                            false,
                            Cms::fetchImport);
            check(
                    early.checkedCount == 0 && hitsA.get() == 0 && hitsB.get() == 0,
                    "Skips refresh before 24h");

            // 2. After 25 hours, subB updated on server -> daily refresh updates subB and rebuilds
            // merged config
            bodyB.set(
                    "{\"spider\":\"./b2.jar\",\"sites\":[{\"key\":\"sB\",\"name\":\"源B-v2\",\"type\":1,\"api\":\"https://b.example/api2\"}]}");
            long t1 = t0 + day + 3600_000L;
            SubscriptionManager.RefreshSummary daily =
                    SubscriptionManager.refreshDueSubscriptions(
                            library,
                            initialMerged.origin,
                            initialMerged.rawJson,
                            t1,
                            false,
                            Cms::fetchImport);
            check(
                    daily.checkedCount == 2
                            && daily.updatedCount == 1
                            && daily.failedCount == 0
                            && daily.activeChanged,
                    "Daily update checks both due subscriptions, updates changed subB, rebuilds merged active config");
            Cms.Config rebuilt = Cms.parseConfig(daily.updatedActiveRaw, daily.updatedActiveOrigin);
            check(
                    rebuilt.sites.size() == 2
                            && "分组A".equals(rebuilt.sites.get(0).group)
                            && "源A-v1".equals(rebuilt.sites.get(0).name)
                            && "分组B".equals(rebuilt.sites.get(1).group)
                            && "源B-v2".equals(rebuilt.sites.get(1).name),
                    "Rebuilt merged config preserves groups and reflects updated subB content");

            // 3. Running again 5 minutes later does not re-hit server
            int hitsBefore = hitsA.get() + hitsB.get();
            SubscriptionManager.RefreshSummary soonAfter =
                    SubscriptionManager.refreshDueSubscriptions(
                            library,
                            daily.updatedActiveOrigin,
                            daily.updatedActiveRaw,
                            t1 + 300_000L,
                            false,
                            Cms::fetchImport);
            check(
                    soonAfter.checkedCount == 0 && (hitsA.get() + hitsB.get()) == hitsBefore,
                    "Bumped updated timestamp prevents redundant checks for next 24h");

            // 4. Server failure preserves existing local snapshot safely
            failB.set(true);
            SubscriptionManager.RefreshSummary forcedFail =
                    SubscriptionManager.refreshDueSubscriptions(
                            library,
                            daily.updatedActiveOrigin,
                            daily.updatedActiveRaw,
                            t1 + 600_000L,
                            true,
                            Cms::fetchImport);
            check(
                    forcedFail.checkedCount == 2
                            && forcedFail.failedCount == 1
                            && !forcedFail.activeChanged,
                    "Failed fetch increments failedCount without corrupting saved config");
        } finally {
            server.stop(0);
            deleteRec(tmpDir);
        }
    }

    private static void testNetdiskPopupMultiConfigCenterCompatibility() throws Exception {
        Cms.Site siteA1 = new Cms.Site();
        siteA1.key = "a_vod";
        siteA1.name = "源A影视";
        siteA1.group = "源A";
        siteA1.api = "csp_AppYs";

        Cms.Site centerA = new Cms.Site();
        centerA.key = "a_mydrive";
        centerA.name = "我的云盘┃配置";
        centerA.group = "源A";
        centerA.api = "csp_MyDrive";

        Cms.Site centerB = new Cms.Site();
        centerB.key = "b_panconfig";
        centerB.name = "网盘配置中心";
        centerB.group = "源B";
        centerB.api = "csp_PanConfig";

        Cms.Site centerC = new Cms.Site();
        centerC.key = "c_wex";
        centerC.name = "Wex配置";
        centerC.group = "源C";
        centerC.api = "csp_WexConfig";

        List<Cms.Site> all = Arrays.asList(siteA1, centerA, centerB, centerC);

        // Active site in 源B -> prefers centerB first, still exposes all 3 centers
        List<Cms.Site> forGroupB = AccountPanel.collectConfigCenterSites(all, "源B", "");
        check(
                forGroupB.size() == 3 && "b_panconfig".equals(forGroupB.get(0).key),
                "AccountPanel prefers Config Center matching active source group");

        // Explicit preferred Config Center overrides group default
        List<Cms.Site> forExplicitC = AccountPanel.collectConfigCenterSites(all, "源A", "c_wex");
        check(
                forExplicitC.size() == 3 && "c_wex".equals(forExplicitC.get(0).key),
                "AccountPanel honors explicitly switched Config Center key");

        // Extended drive routing works for PanConfig, WexConfig, MyDrive, and generic ConfigCenter
        check(
                "direct:pan115".equals(AccountPanel.resolveDirectDriveRoute(centerB, "115"))
                        && "direct:pan189"
                                .equals(AccountPanel.resolveDirectDriveRoute(centerB, "189"))
                        && "direct:pan139"
                                .equals(AccountPanel.resolveDirectDriveRoute(centerB, "139"))
                        && "direct:pan123manual"
                                .equals(AccountPanel.resolveDirectDriveRoute(centerB, "123"))
                        && "direct:thunder"
                                .equals(AccountPanel.resolveDirectDriveRoute(centerB, "thunder")),
                "PanConfig extended drives (115/189/139/123/thunder) route directly");
        check(
                "direct:115pancookie".equals(AccountPanel.resolveDirectDriveRoute(centerC, "115"))
                        && "direct:tianyilogin"
                                .equals(AccountPanel.resolveDirectDriveRoute(centerC, "189"))
                        && "direct:ydyuncookie"
                                .equals(AccountPanel.resolveDirectDriveRoute(centerC, "139"))
                        && "direct:pan123login"
                                .equals(AccountPanel.resolveDirectDriveRoute(centerC, "123"))
                        && "direct:panxunleiuser"
                                .equals(AccountPanel.resolveDirectDriveRoute(centerC, "thunder")),
                "WexConfig extended drives (115/189/139/123/thunder) route directly");

        // SettingsScreen non-MyDrive fallback never blindly fires MyDrive-only LoginShow
        String settingsSrc = readSource("SettingsScreen.java");
        check(
                settingsSrc.contains("isMyDriveSpider")
                        && settingsSrc.contains(
                                "openDynamicConfigSiteAction(targetSite, \"LoginShow\")"),
                "SettingsScreen non-MyDrive direct drive fallback opens dynamic Config Center instead of dead-ending on LoginShow");
    }

    private static void testConfigTransferServerMultiLineAndSecurity() throws Exception {
        final AtomicReference<String> receivedAddr = new AtomicReference<String>();
        final AtomicBoolean receivedMerge = new AtomicBoolean(false);
        try (ConfigTransferServer server =
                ConfigTransferServer.withBatchImporter(
                        (addr, merge) -> {
                            receivedAddr.set(addr);
                            receivedMerge.set(merge);
                        },
                        null)) {
            String endpoint = server.address("127.0.0.1");

            // 1. Mixed valid + file:// multi-line submission must be rejected with 400
            int badCode =
                    postForm(
                            endpoint,
                            "address="
                                    + URLEncoder.encode(
                                            "https://a.example/1.json\nfile:///private/x.json",
                                            "UTF-8")
                                    + "&merge=1");
            check(
                    badCode == 400 && receivedAddr.get() == null,
                    "Multi-line submission with file:// rejected (400)");

            // 2. Valid multi-line submission with merge=1 succeeds (200) and forwards
            // appendMerge=true
            int okCode =
                    postForm(
                            endpoint,
                            "address="
                                    + URLEncoder.encode(
                                            "源1,https://a.example/1.json\n源2,https://b.example/2.json",
                                            "UTF-8")
                                    + "&merge=1");
            check(
                    okCode == 200
                            && receivedMerge.get()
                            && "源1,https://a.example/1.json\n源2,https://b.example/2.json"
                                    .equals(receivedAddr.get()),
                    "Valid multi-line batch submission with merge=1 accepted and normalized");
        }
    }

    private static int postForm(String endpoint, String formBody) throws Exception {
        HttpURLConnection conn = (HttpURLConnection) new URL(endpoint).openConnection();
        conn.setConnectTimeout(3000);
        conn.setReadTimeout(5000);
        conn.setRequestMethod("POST");
        conn.setDoOutput(true);
        conn.setRequestProperty("Content-Type", "application/x-www-form-urlencoded");
        byte[] bytes = formBody.getBytes(StandardCharsets.UTF_8);
        conn.setFixedLengthStreamingMode(bytes.length);
        try (OutputStream out = conn.getOutputStream()) {
            out.write(bytes);
        }
        try {
            return conn.getResponseCode();
        } finally {
            conn.disconnect();
        }
    }

    private static void deleteRec(File f) {
        if (f == null || !f.exists()) return;
        File[] kids = f.listFiles();
        if (kids != null) {
            for (File k : kids) deleteRec(k);
        }
        f.delete();
    }
}
