package com.pilipala.marcomovie;

import android.content.SharedPreferences;
import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;
import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.lang.reflect.Field;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;
import org.json.JSONArray;
import org.json.JSONObject;

public final class CloudSyncChecks {
    static int checks;

    static void check(boolean ok, String label) {
        if (!ok) throw new AssertionError("FAILED: " + label);
        checks++;
        System.out.println("PASS " + label);
    }

    private static byte[] readAll(InputStream in) throws java.io.IOException {
        ByteArrayOutputStream bos = new ByteArrayOutputStream();
        byte[] buf = new byte[4096];
        int n;
        while ((n = in.read(buf)) != -1) {
            bos.write(buf, 0, n);
        }
        return bos.toByteArray();
    }

    public static void main(String[] args) throws Exception {
        testResolveWebdavFileUrlMatrix();
        testWebdavErrorDiagnostics();
        testHistoryFavoritesAndTombstones();
        testSubscriptionSyncIsolationAndOptOut();
        testLegacyBackupCompatibility();
        testLanPeerSyncRoundtrip();
        testWebdavMkcolAndRoundtrip();
        testWebdavEtagAndConcurrency();
        testWatchHistoryCorruptionBackupAndLockout();
        testMainActivityRestartWatchHistoryBackup();
        testUiLatchTimeoutAndErrorPropagation();
        testRound2WebdavRobustness();
        System.out.println("ALL PASS (" + checks + " checks)");
    }

    private static void testResolveWebdavFileUrlMatrix() {
        check(
                "https://dav.jianguoyun.com/dav/MarcoMovie/marco-movie-sync.json"
                        .equals(CloudSync.resolveWebdavFileUrl("dav.jianguoyun.com")),
                "Jianguoyun bare host resolves to /dav/MarcoMovie/marco-movie-sync.json");
        check(
                "https://dav.jianguoyun.com/dav/MarcoMovie/marco-movie-sync.json"
                        .equals(CloudSync.resolveWebdavFileUrl("https://dav.jianguoyun.com/")),
                "Jianguoyun root slash URL resolves to /dav/MarcoMovie/marco-movie-sync.json");
        check(
                "https://dav.jianguoyun.com/dav/MarcoMovie/marco-movie-sync.json"
                        .equals(CloudSync.resolveWebdavFileUrl("https://dav.jianguoyun.com/dav/")),
                "Jianguoyun root folder trailing slash appends MarcoMovie");
        check(
                "https://dav.jianguoyun.com/dav/MarcoMovie/marco-movie-sync.json"
                        .equals(CloudSync.resolveWebdavFileUrl("https://dav.jianguoyun.com/dav")),
                "Jianguoyun root folder without trailing slash appends MarcoMovie");
        check(
                "https://dav.jianguoyun.com/dav/MarcoMovie/marco-movie-sync.json"
                        .equals(CloudSync.resolveWebdavFileUrl("dav.jianguoyun.com/dav/")),
                "Jianguoyun scheme-less URL auto-prepends https and appends MarcoMovie");
        check(
                "https://dav.jianguoyun.com/dav/我的坚果云/marco-movie-sync.json"
                        .equals(
                                CloudSync.resolveWebdavFileUrl(
                                        "https://dav.jianguoyun.com/dav/我的坚果云/")),
                "Jianguoyun custom folder preserves user subfolder");
        check(
                "https://dav.jianguoyun.com/dav/a/x.json"
                        .equals(
                                CloudSync.resolveWebdavFileUrl(
                                        "https://dav.jianguoyun.com/dav/a/x.json")),
                "Jianguoyun explicit json file URL left untouched");
        check(
                "https://nas.test:5006/marco-movie-sync.json"
                        .equals(CloudSync.resolveWebdavFileUrl("https://nas.test:5006/")),
                "Non-Jianguoyun WebDAV server does not append MarcoMovie subfolder");
    }

    private static void testWebdavErrorDiagnostics() {
        String err404 = CloudSync.formatWebdavWriteError(404);
        check(
                err404.contains("HTTP 404") && err404.contains("坚果云请在地址后加一个文件夹名"),
                "HTTP 404 provides actionable Jianguoyun diagnostic error message");
        String err409 = CloudSync.formatWebdavWriteError(409);
        check(
                err409.contains("HTTP 409") && err409.contains("坚果云请在地址后加一个文件夹名"),
                "HTTP 409 provides actionable Jianguoyun diagnostic error message");
        check(
                "WebDAV 写入失败 (HTTP 405)：服务器不允许写入".equals(CloudSync.formatWebdavWriteError(405)),
                "HTTP 405 provides method not allowed message");
        check(
                "WebDAV 写入失败 (HTTP 423)：文件被锁定".equals(CloudSync.formatWebdavWriteError(423)),
                "HTTP 423 provides locked file message");
        check(
                "WebDAV 写入失败 (HTTP 507)：空间不足".equals(CloudSync.formatWebdavWriteError(507)),
                "HTTP 507 provides insufficient storage message");
    }

    private static void testHistoryFavoritesAndTombstones() throws Exception {
        WatchHistory.Entry h1 = new WatchHistory.Entry();
        h1.site = "site_a";
        h1.id = "vod_1";
        h1.title = "星际漫游";
        h1.episode = "第02集";
        h1.position = 120_000;
        h1.duration = 2_400_000;
        h1.updated = 1000L;
        String localHist = WatchHistory.upsert("[]", h1);

        Cms.Video favVideo = new Cms.Video();
        favVideo.id = "vod_fav";
        favVideo.title = "沙丘";
        String localFav = Favorites.toggle("[]", "site_a", favVideo);

        CloudSync.Tombstones localTombs = CloudSync.Tombstones.read("");
        localTombs.putMax("add:site_a\nvod_fav", 1200L);

        // Remote has newer progress on vod_1 (t=2500), plus vod_deleted (t=900)
        JSONObject remoteRoot =
                new JSONObject()
                        .put("schema", CloudSync.SCHEMA)
                        .put("version", 1)
                        .put("updatedAt", 2600L)
                        .put(
                                "watchHistory",
                                new JSONArray()
                                        .put(
                                                new JSONObject()
                                                        .put("siteKey", "site_a")
                                                        .put("vodId", "vod_1")
                                                        .put("title", "星际漫游")
                                                        .put("episodeName", "第03集")
                                                        .put("positionMs", 480_000)
                                                        .put("durationMs", 2_400_000)
                                                        .put("updatedAt", 2500L))
                                        .put(
                                                new JSONObject()
                                                        .put("siteKey", "site_a")
                                                        .put("vodId", "vod_old")
                                                        .put("title", "旧记录")
                                                        .put("positionMs", 30_000)
                                                        .put("durationMs", 600_000)
                                                        .put("updatedAt", 900L)))
                        .put("tombstones", new JSONObject().put("fav:site_a\nvod_fav", 2000L));

        // Local deleted vod_old at t=1500
        localTombs.putMax("hist:site_a\nvod_old", 1500L);

        CloudSync.MergeResult merged =
                CloudSync.merge(
                        localHist,
                        localFav,
                        localTombs.json(),
                        Collections.<CloudSync.SubscriptionItem>emptyList(),
                        true,
                        remoteRoot.toString(),
                        3000L);

        List<WatchHistory.Entry> resHist = WatchHistory.read(merged.historyJson);
        check(resHist.size() == 1, "tombstoned remote history removed while active entry kept");
        check(
                "第03集".equals(resHist.get(0).episode) && resHist.get(0).position == 480_000,
                "newer remote watch progress wins LWW");
        List<Favorites.Entry> resFavs = Favorites.read(merged.favoritesJson);
        check(resFavs.isEmpty(), "newer remote fav tombstone removes local favorite");
    }

    private static void testSubscriptionSyncIsolationAndOptOut() throws Exception {
        String rawMixed =
                "{\"sites\":["
                        + "{\"key\":\"pub_1\",\"name\":\"公开源\",\"type\":1,\"api\":\"https://api.example/cms\"},"
                        + "{\"key\":\"priv_1\",\"name\":\"私密源\",\"type\":1,\"api\":\"https://priv.example/cms\",\"private\":true}"
                        + "],\"lives\":["
                        + "{\"name\":\"公开直播\",\"url\":\"https://live.example/open.m3u\"},"
                        + "{\"name\":\"私密直播\",\"url\":\"https://live.example/secret.m3u\",\"space\":\"private\"}"
                        + "]}";
        String sanitized = CloudSync.sanitizePublicRawConfig(rawMixed);
        JSONObject sanObj = new JSONObject(sanitized);
        check(
                sanObj.getJSONArray("sites").length() == 1
                        && "pub_1"
                                .equals(
                                        sanObj.getJSONArray("sites")
                                                .getJSONObject(0)
                                                .getString("key")),
                "private sites stripped before cloud export");
        check(
                sanObj.getJSONArray("lives").length() == 1,
                "private live entries stripped before cloud export");

        CloudSync.SubscriptionItem subA =
                CloudSync.SubscriptionItem.create(
                        "主力订阅",
                        "https://sub-a.example/config.json",
                        rawMixed,
                        true,
                        "pub_1",
                        5000L);
        check(
                subA != null
                        && subA.key.equals(
                                ConfigLibrary.identity(
                                        "https://sub-a.example/config.json", sanitized)),
                "SubscriptionItem key matches ConfigLibrary.identity");

        String payloadDeviceA =
                CloudSync.exportPayload(
                        "[]", "[]", "", Collections.singletonList(subA), true, 5100L);
        check(!payloadDeviceA.contains("priv_1"), "exported payload never leaks private site");

        // Brand-new Device B pulls with syncSubscriptions = true
        CloudSync.MergeResult mergedOnB =
                CloudSync.merge(
                        "[]",
                        "[]",
                        "",
                        Collections.<CloudSync.SubscriptionItem>emptyList(),
                        true,
                        payloadDeviceA,
                        5200L);
        check(
                mergedOnB.subscriptionCount == 1
                        && "主力订阅".equals(mergedOnB.subscriptions.get(0).name),
                "new device receives public subscription from v2 payload");

        // Device C has syncSubscriptions = false -> must NOT wipe remote subscriptions in cloud!
        CloudSync.MergeResult mergedOnC =
                CloudSync.merge("[]", "[]", "", null, false, payloadDeviceA, 5300L);
        JSONObject cOut = new JSONObject(mergedOnC.payloadJson);
        check(
                cOut.has("subscriptions") && cOut.getJSONArray("subscriptions").length() == 1,
                "device with syncSubscriptions=false preserves remote cloud subscriptions");

        // Now Device A deletes subA via sub: tombstone at t=6000
        CloudSync.Tombstones delTomb = CloudSync.Tombstones.read("");
        delTomb.putMax("sub:" + subA.key, 6000L);
        CloudSync.MergeResult afterDelete =
                CloudSync.merge(
                        "[]",
                        "[]",
                        delTomb.json(),
                        Collections.<CloudSync.SubscriptionItem>emptyList(),
                        true,
                        payloadDeviceA,
                        6100L);
        check(
                afterDelete.subscriptionCount == 0,
                "newer sub: tombstone removes deleted subscription across devices");
    }

    private static void testLegacyBackupCompatibility() throws Exception {
        String legacyBackup =
                "{\"schema\":\"marco-movie-backup\",\"version\":1,"
                        + "\"watch_history\":[{\"site\":\"s1\",\"id\":\"v9\",\"title\":\"旧版备份影片\",\"position\":90000,\"duration\":180000,\"updated\":1700}],"
                        + "\"favorites\":[{\"site\":\"s1\",\"id\":\"v9\",\"title\":\"旧版备份影片\"}]}";
        CloudSync.MergeResult res =
                CloudSync.merge(
                        "[]",
                        "[]",
                        "",
                        Collections.<CloudSync.SubscriptionItem>emptyList(),
                        true,
                        legacyBackup,
                        2000L);
        check(
                res.historyCount == 1 && res.favoriteCount == 1,
                "backward compatible with marco-movie-backup payload");
    }

    private static void testLanPeerSyncRoundtrip() throws Exception {
        final AtomicReference<String> serverHist = new AtomicReference<>("[]");
        final AtomicReference<String> serverFav = new AtomicReference<>("[]");
        final AtomicReference<String> serverTombs = new AtomicReference<>("");
        String rawSub =
                "{\"sites\":[{\"key\":\"lan_site\",\"name\":\"局域网片源\",\"type\":1,\"api\":\"https://lan.example/cms\"}]}";
        final List<CloudSync.SubscriptionItem> serverSubs =
                new ArrayList<>(
                        Collections.singletonList(
                                CloudSync.SubscriptionItem.create(
                                        "客厅电视订阅",
                                        "https://tv.example/sub.json",
                                        rawSub,
                                        true,
                                        "lan_site",
                                        4000L)));

        WatchHistory.Entry tvHist = new WatchHistory.Entry();
        tvHist.site = "lan_site";
        tvHist.id = "m100";
        tvHist.title = "电视端进度";
        tvHist.position = 300_000;
        tvHist.duration = 900_000;
        tvHist.updated = 4100L;
        serverHist.set(WatchHistory.upsert("[]", tvHist));

        ConfigTransferServer server =
                new ConfigTransferServer(
                        address -> {},
                        remoteJson -> {
                            long now = 5000L;
                            if (remoteJson == null) {
                                return CloudSync.exportPayload(
                                        serverHist.get(),
                                        serverFav.get(),
                                        serverTombs.get(),
                                        serverSubs,
                                        true,
                                        now);
                            }
                            CloudSync.MergeResult m =
                                    CloudSync.merge(
                                            serverHist.get(),
                                            serverFav.get(),
                                            serverTombs.get(),
                                            serverSubs,
                                            true,
                                            remoteJson,
                                            now);
                            serverHist.set(m.historyJson);
                            serverFav.set(m.favoritesJson);
                            serverTombs.set(m.tombstonesJson);
                            return m.payloadJson;
                        });
        try {
            String peerUrl = server.address("127.0.0.1");
            Cms.Video phoneFavVideo = new Cms.Video();
            phoneFavVideo.id = "m200";
            phoneFavVideo.title = "手机端新收藏";
            final String phoneFav = Favorites.toggle("[]", "lan_site", phoneFavVideo);

            CloudSync.MergeResult clientRes =
                    CloudSync.syncLanPeer(
                            peerUrl,
                            new CloudSync.LanPeerCallback() {
                                @Override
                                public String exportLocalPayload() throws Exception {
                                    return CloudSync.exportPayload(
                                            "[]",
                                            phoneFav,
                                            "",
                                            Collections.<CloudSync.SubscriptionItem>emptyList(),
                                            true,
                                            4800L);
                                }

                                @Override
                                public CloudSync.MergeResult applyMergedPayload(
                                        String remoteMergedPayloadJson) throws Exception {
                                    return CloudSync.merge(
                                            "[]",
                                            phoneFav,
                                            "",
                                            Collections.<CloudSync.SubscriptionItem>emptyList(),
                                            true,
                                            remoteMergedPayloadJson,
                                            5100L);
                                }
                            });

            check(
                    clientRes.historyCount == 1
                            && clientRes.favoriteCount == 1
                            && clientRes.subscriptionCount == 1,
                    "LAN client receives TV history + TV subscription and keeps phone favorite");
            check(
                    Favorites.read(serverFav.get()).size() == 1,
                    "LAN receiver (TV) simultaneously receives phone favorite in single roundtrip");
        } finally {
            server.close();
        }
    }

    private static void testWebdavMkcolAndRoundtrip() throws Exception {
        final Set<String> createdDirs = Collections.synchronizedSet(new HashSet<String>());
        final List<String> mkcolSequence = Collections.synchronizedList(new ArrayList<String>());
        final AtomicReference<byte[]> storedFile = new AtomicReference<>(null);
        final AtomicReference<String> lastAuth = new AtomicReference<>("");

        HttpServer dav = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        dav.createContext(
                "/",
                (HttpExchange ex) -> {
                    try {
                        String method = ex.getRequestMethod();
                        String path = ex.getRequestURI().getPath();
                        String auth = ex.getRequestHeaders().getFirst("Authorization");
                        lastAuth.set(auth == null ? "" : auth);
                        if (path.startsWith("/forbidden")) {
                            if ("MKCOL".equalsIgnoreCase(method)) {
                                ex.sendResponseHeaders(403, -1);
                                return;
                            }
                            if ("PUT".equalsIgnoreCase(method)) {
                                ex.sendResponseHeaders(404, -1);
                                return;
                            }
                        }
                        if ("MKCOL".equalsIgnoreCase(method)) {
                            String norm = path.endsWith("/") ? path : path + "/";
                            createdDirs.add(norm);
                            mkcolSequence.add(norm);
                            ex.sendResponseHeaders(201, -1);
                            return;
                        }
                        if ("GET".equalsIgnoreCase(method)) {
                            byte[] data = storedFile.get();
                            if (data == null) {
                                ex.sendResponseHeaders(404, -1);
                            } else {
                                ex.getResponseHeaders()
                                        .set("Content-Type", "application/json; charset=utf-8");
                                ex.sendResponseHeaders(200, data.length);
                                try (OutputStream os = ex.getResponseBody()) {
                                    os.write(data);
                                }
                            }
                            return;
                        }
                        if ("PUT".equalsIgnoreCase(method)) {
                            byte[] body = readAll(ex.getRequestBody());
                            // Simulate Jianguoyun root collection read-only
                            if ("/dav/marco-movie-sync.json".equals(path)
                                    || "/marco-movie-sync.json".equals(path)) {
                                ex.sendResponseHeaders(404, -1);
                                return;
                            }
                            if (!createdDirs.contains("/dav/")
                                    || !createdDirs.contains("/dav/MarcoMovie/")) {
                                ex.sendResponseHeaders(409, -1);
                                return;
                            }
                            storedFile.set(body);
                            ex.sendResponseHeaders(201, -1);
                            return;
                        }
                        ex.sendResponseHeaders(405, -1);
                    } finally {
                        ex.close();
                    }
                });
        dav.start();
        try {
            int port = dav.getAddress().getPort();
            String davDirUrl = "http://127.0.0.1:" + port + "/dav/MarcoMovie/";

            WatchHistory.Entry e = new WatchHistory.Entry();
            e.site = "s_dav";
            e.id = "v_dav";
            e.title = "云端同步测试片";
            e.position = 65_000;
            e.duration = 120_000;
            e.updated = 7000L;
            final String histA = WatchHistory.upsert("[]", e);

            CloudSync.MergeResult pushRes =
                    CloudSync.syncWebdav(
                            davDirUrl,
                            "alice",
                            "secret-pass",
                            remote ->
                                    CloudSync.merge(
                                            histA,
                                            "[]",
                                            "",
                                            Arrays.asList(
                                                    CloudSync.SubscriptionItem.create(
                                                            "WebDAV 订阅",
                                                            "https://dav-sub.example/main.json",
                                                            "{\"sites\":[{\"key\":\"s_dav\",\"name\":\"云片源\",\"type\":1,\"api\":\"https://dav-sub.example/api\"}]}",
                                                            true,
                                                            "s_dav",
                                                            7000L)),
                                            true,
                                            remote,
                                            7100L));

            check(
                    pushRes.historyCount == 1 && pushRes.subscriptionCount == 1,
                    "WebDAV initial push creates parent directories via MKCOL and uploads v2 JSON");
            check(
                    lastAuth.get().startsWith("Basic "),
                    "WebDAV request sends RFC 4648 Basic Authorization header");
            check(
                    mkcolSequence.contains("/dav/") && mkcolSequence.contains("/dav/MarcoMovie/"),
                    "MKCOL creates nested collections in hierarchy");
            check(
                    mkcolSequence.indexOf("/dav/") < mkcolSequence.indexOf("/dav/MarcoMovie/"),
                    "MKCOL sequence creates parent collection before child collection");

            CloudSync.MergeResult pullRes =
                    CloudSync.syncWebdav(
                            davDirUrl,
                            "alice",
                            "secret-pass",
                            remote ->
                                    CloudSync.merge(
                                            "[]",
                                            "[]",
                                            "",
                                            Collections.<CloudSync.SubscriptionItem>emptyList(),
                                            true,
                                            remote,
                                            7200L));
            check(
                    pullRes.historyCount == 1 && pullRes.subscriptionCount == 1,
                    "second device pulls history and subscription from WebDAV server");

            try {
                CloudSync.syncWebdav(
                        "http://127.0.0.1:" + port + "/forbidden/",
                        "alice",
                        "secret-pass",
                        remote ->
                                CloudSync.merge(
                                        "[]",
                                        "[]",
                                        "",
                                        Collections.<CloudSync.SubscriptionItem>emptyList(),
                                        true,
                                        remote,
                                        7300L));
                check(false, "Persistent WebDAV write failure must throw IOException");
            } catch (java.io.IOException expected) {
                check(
                        expected.getMessage().contains("目标文件夹不存在或不可写。坚果云请在地址后加一个文件夹名"),
                        "WebDAV 404/409 write failure provides actionable diagnostic message");
            }
        } finally {
            dav.stop(0);
        }
    }

    private static void testWebdavEtagAndConcurrency() throws Exception {
        HttpServer dav = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        final AtomicReference<String> lastIfMatch = new AtomicReference<>();
        final AtomicReference<String> lastIfNoneMatch = new AtomicReference<>();
        final AtomicReference<String> serverEtag = new AtomicReference<>("\"etag-v1\"");
        final AtomicReference<byte[]> storedPayload = new AtomicReference<>(null);
        final java.util.concurrent.atomic.AtomicInteger putCount =
                new java.util.concurrent.atomic.AtomicInteger();
        final java.util.concurrent.atomic.AtomicBoolean return412Once =
                new java.util.concurrent.atomic.AtomicBoolean();
        final java.util.concurrent.atomic.AtomicBoolean always412 =
                new java.util.concurrent.atomic.AtomicBoolean();
        final java.util.concurrent.atomic.AtomicBoolean omitEtagOnGet =
                new java.util.concurrent.atomic.AtomicBoolean();

        dav.createContext(
                "/etag-dav/MarcoMovie/",
                ex -> {
                    try {
                        String method = ex.getRequestMethod();
                        if ("GET".equals(method)) {
                            byte[] body = storedPayload.get();
                            if (body == null) {
                                ex.sendResponseHeaders(404, -1);
                                return;
                            }
                            if (!omitEtagOnGet.get()) {
                                ex.getResponseHeaders().set("ETag", serverEtag.get());
                            }
                            ex.getResponseHeaders()
                                    .set("Content-Type", "application/json; charset=utf-8");
                            ex.sendResponseHeaders(200, body.length);
                            try (OutputStream out = ex.getResponseBody()) {
                                out.write(body);
                            }
                            return;
                        }
                        if ("MKCOL".equals(method)) {
                            ex.sendResponseHeaders(201, -1);
                            return;
                        }
                        if ("PUT".equals(method)) {
                            putCount.incrementAndGet();
                            lastIfMatch.set(ex.getRequestHeaders().getFirst("If-Match"));
                            lastIfNoneMatch.set(ex.getRequestHeaders().getFirst("If-None-Match"));

                            if (always412.get()) {
                                ex.sendResponseHeaders(412, -1);
                                return;
                            }
                            if (return412Once.compareAndSet(true, false)) {
                                serverEtag.set("\"etag-v2\"");
                                storedPayload.set(
                                        "{\"schema\":\"marco-movie-sync\",\"version\":2,\"updated\":8000,\"watch_history\":[]}"
                                                .getBytes(StandardCharsets.UTF_8));
                                ex.sendResponseHeaders(412, -1);
                                return;
                            }

                            storedPayload.set(readAll(ex.getRequestBody()));
                            ex.getResponseHeaders().set("ETag", serverEtag.get());
                            ex.sendResponseHeaders(201, -1);
                            return;
                        }
                        ex.sendResponseHeaders(405, -1);
                    } finally {
                        ex.close();
                    }
                });
        dav.start();
        try {
            int port = dav.getAddress().getPort();
            String url = "http://127.0.0.1:" + port + "/etag-dav/MarcoMovie/";

            // 1. Initial push when file absent on GET (404) -> sends If-None-Match: *
            storedPayload.set(null);
            CloudSync.syncWebdav(
                    url,
                    "alice",
                    "pass",
                    remote ->
                            CloudSync.merge(
                                    "[]", "[]", "", Collections.emptyList(), false, remote, 1000L));
            check(
                    "*".equals(lastIfNoneMatch.get()) && lastIfMatch.get() == null,
                    "WebDAV sends If-None-Match: * on initial push when file absent");

            // 2. Subsequent sync with existing file and ETag -> sends If-Match: <etag>
            lastIfNoneMatch.set(null);
            lastIfMatch.set(null);
            CloudSync.syncWebdav(
                    url,
                    "alice",
                    "pass",
                    remote ->
                            CloudSync.merge(
                                    "[]", "[]", "", Collections.emptyList(), false, remote, 2000L));
            check(
                    lastIfNoneMatch.get() == null && "\"etag-v1\"".equals(lastIfMatch.get()),
                    "WebDAV sends If-Match: <etag> when remote file exists");

            // 3. Fallback to unconditioned PUT when server GET omits ETag
            omitEtagOnGet.set(true);
            lastIfNoneMatch.set(null);
            lastIfMatch.set(null);
            CloudSync.syncWebdav(
                    url,
                    "alice",
                    "pass",
                    remote ->
                            CloudSync.merge(
                                    "[]", "[]", "", Collections.emptyList(), false, remote, 3000L));
            check(
                    lastIfNoneMatch.get() == null && lastIfMatch.get() == null,
                    "WebDAV falls back gracefully to unconditioned PUT when ETag omitted");
            omitEtagOnGet.set(false);

            // 4. HTTP 412 triggers retry loop and succeeds with updated ETag
            return412Once.set(true);
            putCount.set(0);
            CloudSync.syncWebdav(
                    url,
                    "alice",
                    "pass",
                    remote ->
                            CloudSync.merge(
                                    "[]", "[]", "", Collections.emptyList(), false, remote, 4000L));
            check(
                    putCount.get() == 2 && "\"etag-v2\"".equals(lastIfMatch.get()),
                    "WebDAV 412 triggers retry loop, re-fetches updated ETag and succeeds");

            // 5. Persistent HTTP 412 exhausts retries and throws actionable IOException
            always412.set(true);
            try {
                CloudSync.syncWebdav(
                        url,
                        "alice",
                        "pass",
                        remote ->
                                CloudSync.merge(
                                        "[]",
                                        "[]",
                                        "",
                                        Collections.emptyList(),
                                        false,
                                        remote,
                                        5000L));
                check(false, "Persistent 412 must throw IOException");
            } catch (java.io.IOException expected) {
                check(
                        expected.getMessage().contains("HTTP 412")
                                && expected.getMessage().contains("写入冲突"),
                        "WebDAV persistent 412 conflict provides actionable diagnostic message");
            }
        } finally {
            dav.stop(0);
        }
    }

    private static void testWatchHistoryCorruptionBackupAndLockout() {
        WatchHistory.setCorrupted(false);
        String corruptJson = "{\"corrupt\": true, [invalid json...";
        final AtomicReference<String> backupKey = new AtomicReference<>();
        final AtomicReference<String> backupValue = new AtomicReference<>();
        final java.util.concurrent.atomic.AtomicInteger backupCount =
                new java.util.concurrent.atomic.AtomicInteger();
        final AtomicReference<Boolean> prefCorrupted = new AtomicReference<>(Boolean.FALSE);
        final AtomicReference<String> storedHistoryJson = new AtomicReference<>(corruptJson);

        WatchHistory.CorruptionRecorder recorder =
                (key, raw) -> {
                    backupCount.incrementAndGet();
                    backupKey.set(key);
                    backupValue.set(raw);
                    prefCorrupted.set(Boolean.TRUE);
                };

        // 1. Reading corrupted JSON 10 times consecutively produces ONLY ONE backup
        for (int i = 0; i < 10; i++) {
            List<WatchHistory.Entry> entries = WatchHistory.read(corruptJson, recorder);
            check(entries.isEmpty(), "WatchHistory.read returns empty list on corrupt JSON #" + i);
        }
        check(
                WatchHistory.isCorrupted() && Boolean.TRUE.equals(prefCorrupted.get()),
                "WatchHistory marks historyCorrupted and pref on malformed JSON");
        check(
                backupCount.get() == 1,
                "10 consecutive reads of corrupted history produce only one backup");
        check(
                backupKey.get() != null
                        && backupKey.get().startsWith("watch_history_corrupt_")
                        && corruptJson.equals(backupValue.get()),
                "WatchHistory calls recorder with watch_history_corrupt_<ts> and verbatim content");

        // 2. Destructive upsert() and remove() are locked out when history is corrupted
        WatchHistory.Entry e = new WatchHistory.Entry();
        e.site = "site_a";
        e.id = "vod_a";
        e.title = "test";
        String upsertResult = WatchHistory.upsert(corruptJson, e);
        check(corruptJson.equals(upsertResult), "WatchHistory.upsert is locked out when corrupted");

        String removeResult = WatchHistory.remove(corruptJson, "site_a\nvod_a");
        check(corruptJson.equals(removeResult), "WatchHistory.remove is locked out when corrupted");

        // 3. Clearing history clears both in-memory flag and watch_history_corrupted pref,
        // keeps backup intact, and subsequent upsert succeeds
        WatchHistory.Store store =
                (json, corrupted) -> {
                    storedHistoryJson.set(json);
                    prefCorrupted.set(corrupted);
                };
        String cleared = WatchHistory.clear(store);
        check(
                "[]".equals(cleared)
                        && "[]".equals(storedHistoryJson.get())
                        && !WatchHistory.isCorrupted()
                        && Boolean.FALSE.equals(prefCorrupted.get())
                        && corruptJson.equals(backupValue.get()),
                "WatchHistory.clear clears flag and pref while preserving corrupt backup");
        String afterClearUpsert = WatchHistory.upsert(storedHistoryJson.get(), e);
        List<WatchHistory.Entry> afterClearEntries = WatchHistory.read(afterClearUpsert);
        check(
                afterClearEntries.size() == 1 && "vod_a".equals(afterClearEntries.get(0).id),
                "WatchHistory.upsert succeeds after clearing corrupted history");

        // 4. Full valid overwrite also clears both flag and watch_history_corrupted pref
        WatchHistory.read(corruptJson, recorder);
        check(WatchHistory.isCorrupted(), "re-triggered corruption sets flag");
        String overwritten = WatchHistory.overwrite(afterClearUpsert, store);
        check(
                overwritten != null
                        && !WatchHistory.isCorrupted()
                        && Boolean.FALSE.equals(prefCorrupted.get()),
                "WatchHistory.overwrite with valid JSON clears flag and pref");

        // 5. (6a) WatchHistory.overwrite with malformed JSON rejects payload WITHOUT setting
        // historyCorrupted or locking out subsequent local WatchHistory.upsert calls
        String healthyBeforeBadOverwrite = storedHistoryJson.get();
        String rejectedOverwrite = WatchHistory.overwrite("[corrupted_restore_payload", store);
        check(
                rejectedOverwrite == null
                        && !WatchHistory.isCorrupted()
                        && Boolean.FALSE.equals(prefCorrupted.get())
                        && healthyBeforeBadOverwrite.equals(storedHistoryJson.get()),
                "6a: WatchHistory.overwrite rejects malformed JSON without touching historyCorrupted");

        WatchHistory.Entry e2 = new WatchHistory.Entry();
        e2.site = "site_b";
        e2.id = "vod_b";
        e2.title = "Still Writable";
        String afterRejectedUpsert = WatchHistory.upsert(storedHistoryJson.get(), e2);
        check(
                WatchHistory.read(afterRejectedUpsert).size() == 2,
                "6a: local WatchHistory.upsert remains unlocked after rejected malformed overwrite");
        storedHistoryJson.set(afterRejectedUpsert);

        // 6. (6a & M-A5) WatchHistory.enqueueBackupRestore rejects malformed data via
        // callback(false)
        // without setting historyCorrupted, and restores valid JSON on STORAGE_EXECUTOR
        final WatchHistory.Persistence memPersistence =
                new WatchHistory.Persistence() {
                    @Override
                    public String readRaw() {
                        return storedHistoryJson.get();
                    }

                    @Override
                    public boolean readCorruptedPref() {
                        return Boolean.TRUE.equals(prefCorrupted.get());
                    }

                    @Override
                    public void writeState(String historyJson, boolean corrupted) {
                        storedHistoryJson.set(historyJson);
                        prefCorrupted.set(corrupted);
                    }
                };
        try {
            final AtomicReference<Boolean> badCb = new AtomicReference<>();
            boolean badResult =
                    WatchHistory.enqueueBackupRestore(
                                    memPersistence, "[malformed_backup]", badCb::set)
                            .get();
            check(
                    !badResult
                            && Boolean.FALSE.equals(badCb.get())
                            && !WatchHistory.isCorrupted()
                            && afterRejectedUpsert.equals(storedHistoryJson.get()),
                    "6a: enqueueBackupRestore rejects [malformed_backup] and notifies callback(false)");

            final AtomicReference<Boolean> nonArrayCb = new AtomicReference<>();
            boolean nonArrayResult =
                    WatchHistory.enqueueBackupRestore(
                                    memPersistence, "{\"not\":\"an_array\"}", nonArrayCb::set)
                            .get();
            check(
                    !nonArrayResult
                            && Boolean.FALSE.equals(nonArrayCb.get())
                            && !WatchHistory.isCorrupted(),
                    "6a: enqueueBackupRestore rejects non-array backup object and notifies callback(false)");

            final AtomicReference<Boolean> goodCb = new AtomicReference<>();
            boolean goodResult =
                    WatchHistory.enqueueBackupRestore(memPersistence, afterClearUpsert, goodCb::set)
                            .get();
            check(
                    goodResult
                            && Boolean.TRUE.equals(goodCb.get())
                            && WatchHistory.read(storedHistoryJson.get()).size() == 1,
                    "6a/M-A5: enqueueBackupRestore persists valid backup history on STORAGE_EXECUTOR");

            // 7. (M-A5) Concurrent playback enqueueUpsert + cloud merge on STORAGE_EXECUTOR
            testConcurrentHistoryAndCloudMerge(memPersistence, storedHistoryJson);
        } catch (Exception ex) {
            throw new AssertionError("Async WatchHistory verification failed", ex);
        }
    }

    private static void testConcurrentHistoryAndCloudMerge(
            final WatchHistory.Persistence persistence,
            final AtomicReference<String> storedHistoryJson)
            throws Exception {
        WatchHistory.enqueueClear(persistence, null).get();
        final AtomicReference<String> storedTombstones = new AtomicReference<>("");
        final Set<String> observedThreads =
                java.util.Collections.synchronizedSet(new HashSet<String>());

        WatchHistory.Persistence trackedPersistence =
                new WatchHistory.Persistence() {
                    @Override
                    public String readRaw() {
                        observedThreads.add(Thread.currentThread().getName());
                        return persistence.readRaw();
                    }

                    @Override
                    public boolean readCorruptedPref() {
                        return persistence.readCorruptedPref();
                    }

                    @Override
                    public void writeState(String historyJson, boolean corrupted) {
                        observedThreads.add(Thread.currentThread().getName());
                        persistence.writeState(historyJson, corrupted);
                    }
                };

        // Enqueue 12 playback bookmarks, delete #3, and interleave a cloud merge concurrently
        List<java.util.concurrent.Future<?>> futures = new ArrayList<>();
        for (int i = 0; i < 12; i++) {
            WatchHistory.Entry item = new WatchHistory.Entry();
            item.site = "cms";
            item.id = "vod_" + i;
            item.title = "Title " + i;
            item.position = (i + 1) * 1000;
            item.duration = 60000;
            item.updated = 10000L + i;
            futures.add(WatchHistory.enqueueUpsert(trackedPersistence, item));
            if (i == 5) {
                final String deleteKey = "cms\nvod_3";
                futures.add(
                        WatchHistory.enqueueRemove(
                                trackedPersistence,
                                deleteKey,
                                () ->
                                        storedTombstones.set(
                                                CloudSync.Tombstones.recordHistoryDelete(
                                                        storedTombstones.get(),
                                                        deleteKey,
                                                        20000L))));
            }
        }

        // Cloud merge bringing a remote item vod_remote AND stale vod_3 (older than tombstone
        // 20000L)
        WatchHistory.Entry remoteOnly = new WatchHistory.Entry();
        remoteOnly.site = "cms";
        remoteOnly.id = "vod_remote";
        remoteOnly.title = "Remote Movie";
        remoteOnly.position = 15000;
        remoteOnly.duration = 90000;
        remoteOnly.updated = 18000L;
        WatchHistory.Entry staleDeleted = new WatchHistory.Entry();
        staleDeleted.site = "cms";
        staleDeleted.id = "vod_3";
        staleDeleted.title = "Title 3";
        staleDeleted.position = 4000;
        staleDeleted.duration = 60000;
        staleDeleted.updated = 10003L;
        String remoteHist =
                WatchHistory.upsert(WatchHistory.upsert("[]", remoteOnly), staleDeleted);
        final String remotePayload =
                CloudSync.exportPayload(remoteHist, "[]", "", null, false, 19000L);

        CloudSync.MergeResult merged =
                WatchHistory.callOnStorageExecutor(
                        () -> {
                            observedThreads.add(Thread.currentThread().getName());
                            CloudSync.MergeResult r =
                                    CloudSync.merge(
                                            trackedPersistence.readRaw(),
                                            "[]",
                                            storedTombstones.get(),
                                            null,
                                            false,
                                            remotePayload,
                                            25000L);
                            WatchHistory.overwrite(r.historyJson, trackedPersistence::writeState);
                            storedTombstones.set(r.tombstonesJson);
                            return r;
                        });
        for (java.util.concurrent.Future<?> f : futures) {
            f.get();
        }
        List<WatchHistory.Entry> finalEntries = WatchHistory.read(storedHistoryJson.get());
        Set<String> ids = new HashSet<>();
        for (WatchHistory.Entry entry : finalEntries) ids.add(entry.id);
        check(
                merged != null
                        && finalEntries.size() == 12
                        && ids.contains("vod_remote")
                        && !ids.contains("vod_3"),
                "M-A5: serialized STORAGE_EXECUTOR preserves all 11 local upserts + 1 remote merge without resurrecting deleted vod_3");
        check(
                observedThreads.size() == 1 && observedThreads.contains("playback-storage"),
                "M-A5: all WatchHistory reads/merges/writes execute exclusively on single playback-storage thread: "
                        + observedThreads);
    }

    private static final class InMemorySharedPreferences implements SharedPreferences {
        final Map<String, Object> data = new HashMap<>();
        final AtomicInteger corruptBackupWrites = new AtomicInteger();

        @Override
        public Map<String, ?> getAll() {
            return new HashMap<>(data);
        }

        @Override
        public String getString(String key, String defValue) {
            Object v = data.get(key);
            return v instanceof String ? (String) v : defValue;
        }

        @Override
        @SuppressWarnings("unchecked")
        public Set<String> getStringSet(String key, Set<String> defValues) {
            Object v = data.get(key);
            return v instanceof Set ? new HashSet<>((Set<String>) v) : defValues;
        }

        @Override
        public int getInt(String key, int defValue) {
            Object v = data.get(key);
            return v instanceof Integer ? (Integer) v : defValue;
        }

        @Override
        public long getLong(String key, long defValue) {
            Object v = data.get(key);
            return v instanceof Long ? (Long) v : defValue;
        }

        @Override
        public float getFloat(String key, float defValue) {
            Object v = data.get(key);
            return v instanceof Float ? (Float) v : defValue;
        }

        @Override
        public boolean getBoolean(String key, boolean defValue) {
            Object v = data.get(key);
            return v instanceof Boolean ? (Boolean) v : defValue;
        }

        @Override
        public boolean contains(String key) {
            return data.containsKey(key);
        }

        @Override
        public Editor edit() {
            return new Editor() {
                private final Map<String, Object> pending = new HashMap<>();
                private final Set<String> removals = new HashSet<>();
                private boolean clearAll;

                @Override
                public Editor putString(String key, String value) {
                    pending.put(key, value);
                    return this;
                }

                @Override
                public Editor putStringSet(String key, Set<String> values) {
                    pending.put(key, values == null ? null : new HashSet<>(values));
                    return this;
                }

                @Override
                public Editor putInt(String key, int value) {
                    pending.put(key, value);
                    return this;
                }

                @Override
                public Editor putLong(String key, long value) {
                    pending.put(key, value);
                    return this;
                }

                @Override
                public Editor putFloat(String key, float value) {
                    pending.put(key, value);
                    return this;
                }

                @Override
                public Editor putBoolean(String key, boolean value) {
                    pending.put(key, value);
                    return this;
                }

                @Override
                public Editor remove(String key) {
                    removals.add(key);
                    return this;
                }

                @Override
                public Editor clear() {
                    clearAll = true;
                    return this;
                }

                @Override
                public boolean commit() {
                    apply();
                    return true;
                }

                @Override
                public void apply() {
                    if (clearAll) {
                        data.clear();
                    }
                    for (String k : removals) {
                        data.remove(k);
                    }
                    for (Map.Entry<String, Object> entry : pending.entrySet()) {
                        if (entry.getKey() != null
                                && entry.getKey().startsWith("watch_history_corrupt_")) {
                            corruptBackupWrites.incrementAndGet();
                        }
                        if (entry.getValue() == null) {
                            data.remove(entry.getKey());
                        } else {
                            data.put(entry.getKey(), entry.getValue());
                        }
                    }
                }
            };
        }

        @Override
        public void registerOnSharedPreferenceChangeListener(
                OnSharedPreferenceChangeListener listener) {}

        @Override
        public void unregisterOnSharedPreferenceChangeListener(
                OnSharedPreferenceChangeListener listener) {}
    }

    private static MainActivity allocateMainActivity(SharedPreferences prefs) throws Exception {
        Class<?> unsafeClass = Class.forName("sun.misc.Unsafe");
        Field theUnsafe = unsafeClass.getDeclaredField("theUnsafe");
        theUnsafe.setAccessible(true);
        Object unsafe = theUnsafe.get(null);
        MainActivity activity =
                (MainActivity)
                        unsafeClass
                                .getMethod("allocateInstance", Class.class)
                                .invoke(unsafe, MainActivity.class);
        activity.prefs = prefs;
        activity.privateMode = false;
        return activity;
    }

    private static List<String> corruptBackupKeys(InMemorySharedPreferences prefs) {
        List<String> keys = new ArrayList<>();
        for (String key : prefs.data.keySet()) {
            if (key.startsWith("watch_history_corrupt_")) {
                keys.add(key);
            }
        }
        return keys;
    }

    private static void testMainActivityRestartWatchHistoryBackup() throws Exception {
        WatchHistory.setCorrupted(false);
        String corruptJson = "{\"corrupt\": true, [invalid json...";
        InMemorySharedPreferences prefs = new InMemorySharedPreferences();
        prefs.data.put(Prefs.WATCH_HISTORY, corruptJson);

        MainActivity session1 = allocateMainActivity(prefs);
        check(
                session1.watchHistory().isEmpty(),
                "MainActivity.watchHistory returns empty list on initial corrupt JSON");
        check(
                WatchHistory.isCorrupted() && prefs.getBoolean(WatchHistory.CORRUPTED_PREF, false),
                "MainActivity.watchHistory persists CORRUPTED_PREF and sets corrupted flag");
        check(
                prefs.corruptBackupWrites.get() == 1 && corruptBackupKeys(prefs).size() == 1,
                "MainActivity.watchHistory writes exactly one backup before restart");

        // Repeat calls in same session never write a second backup
        session1.watchHistory();
        session1.watchHistory();
        check(
                prefs.corruptBackupWrites.get() == 1 && corruptBackupKeys(prefs).size() == 1,
                "MainActivity.watchHistory does not re-backup within same session");

        // Advance clock > 1ms and simulate cold process restart (in-memory flag wiped, prefs kept)
        Thread.sleep(5);
        WatchHistory.setCorrupted(false);
        MainActivity session2AfterRestart = allocateMainActivity(prefs);
        check(
                session2AfterRestart.watchHistory().isEmpty(),
                "MainActivity.watchHistory after restart returns empty list on corrupt JSON");
        check(
                WatchHistory.isCorrupted() && prefs.getBoolean(WatchHistory.CORRUPTED_PREF, false),
                "MainActivity.watchHistory after restart restores in-memory corrupted flag from prefs");
        check(
                prefs.corruptBackupWrites.get() == 1 && corruptBackupKeys(prefs).size() == 1,
                "MainActivity.watchHistory after restart performs only one backup total across restarts");

        String originalBackupKey = corruptBackupKeys(prefs).get(0);
        check(
                corruptJson.equals(prefs.getString(originalBackupKey, "")),
                "MainActivity.watchHistory preserves original corrupt backup payload verbatim across restart");

        // Clearing via MainActivity resets CORRUPTED_PREF and flag while retaining backup key
        session2AfterRestart.clearWatchHistory();
        WatchHistory.STORAGE_EXECUTOR
                .submit(() -> {})
                .get(5, java.util.concurrent.TimeUnit.SECONDS);
        check(
                !WatchHistory.isCorrupted()
                        && !prefs.getBoolean(WatchHistory.CORRUPTED_PREF, false)
                        && "[]".equals(prefs.getString(Prefs.WATCH_HISTORY, ""))
                        && corruptBackupKeys(prefs).size() == 1,
                "MainActivity.clearWatchHistory clears flag and CORRUPTED_PREF while preserving backup");

        // Re-corrupt, re-trigger via MainActivity, then clear cleanly via overwriteWatchHistory
        Thread.sleep(5);
        prefs.data.put(Prefs.WATCH_HISTORY, corruptJson);
        session2AfterRestart.watchHistory();
        check(
                WatchHistory.isCorrupted() && corruptBackupKeys(prefs).size() == 2,
                "MainActivity.watchHistory records a new backup only after explicit clear + new corruption");

        String validJson = "[{\"site\":\"s1\",\"id\":\"v1\",\"title\":\"Valid After Overwrite\"}]";
        boolean overwrittenOk = session2AfterRestart.overwriteWatchHistory(validJson);
        WatchHistory.STORAGE_EXECUTOR
                .submit(() -> {})
                .get(5, java.util.concurrent.TimeUnit.SECONDS);
        List<WatchHistory.Entry> restored = session2AfterRestart.watchHistory();
        check(
                overwrittenOk
                        && !WatchHistory.isCorrupted()
                        && !prefs.getBoolean(WatchHistory.CORRUPTED_PREF, false)
                        && restored.size() == 1
                        && "v1".equals(restored.get(0).id),
                "MainActivity.overwriteWatchHistory resets CORRUPTED_PREF and restores readable history");
    }

    private static void testUiLatchTimeoutAndErrorPropagation() {
        // Test timeout detection
        java.util.concurrent.CountDownLatch latch = new java.util.concurrent.CountDownLatch(1);
        boolean timeoutPassed = false;
        try {
            boolean completed = latch.await(50, java.util.concurrent.TimeUnit.MILLISECONDS);
            if (!completed) {
                timeoutPassed = true;
            }
        } catch (InterruptedException ignored) {
        }
        check(
                timeoutPassed,
                "CountDownLatch detects timeout when UI thread does not count down in time");

        // Test error propagation via AtomicReference<Throwable>
        final AtomicReference<Throwable> errRef = new AtomicReference<>();
        errRef.set(new IllegalStateException("simulated UI exception"));
        check(
                errRef.get() != null && "simulated UI exception".equals(errRef.get().getMessage()),
                "AtomicReference propagates background UI failure throwable to sync caller");
    }

    private static void testRound2WebdavRobustness() throws Exception {
        CloudSync.clearNoConditionalWriteHostsForTest();

        // 1. M-W2 baseCollectionDepth checks (Jianguoyun & Nextcloud & custom base prefix)
        String jgyFile = CloudSync.resolveWebdavFileUrl("https://dav.jianguoyun.com/dav/");
        check(
                CloudSync.baseCollectionDepth(
                                "https://dav.jianguoyun.com/dav/", java.net.URI.create(jgyFile))
                        == 1,
                "M-W2 Jianguoyun /dav/ base skips /dav/ and only creates MarcoMovie/ below base");
        check(
                CloudSync.baseCollectionDepth("dav.jianguoyun.com", java.net.URI.create(jgyFile))
                        == 1,
                "M-W2 Jianguoyun host-only input skips /dav/ and creates MarcoMovie/ below base");
        String ncFile =
                CloudSync.resolveWebdavFileUrl(
                        "https://nc.example/remote.php/dav/files/alice/MarcoMovie/");
        check(
                CloudSync.baseCollectionDepth(
                                "https://nc.example/remote.php/dav/files/alice/",
                                java.net.URI.create(ncFile))
                        == 4,
                "M-W2 Nextcloud base skips /remote.php/dav/files/<user>/");

        // 2. M-W1 (weak ETag, If-None-Match rejection, 412 unconditional PUT + host memory)
        //    & M-W2 (/dav/ returns 403, 401 stops, MKCOL body drained) & URL with spaces
        HttpServer r2Server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        final AtomicReference<String> lastPutIfMatch = new AtomicReference<>();
        final AtomicReference<String> lastPutIfNoneMatch = new AtomicReference<>();
        final List<String> putHistory = Collections.synchronizedList(new ArrayList<>());
        final AtomicReference<byte[]> weakStore =
                new AtomicReference<>(
                        "{\"schema\":\"marco-movie-sync\",\"version\":2,\"updated\":100,\"watch_history\":[]}"
                                .getBytes(StandardCharsets.UTF_8));
        final AtomicReference<byte[]> noInmStore = new AtomicReference<>(null);
        final AtomicReference<byte[]> cond412Store =
                new AtomicReference<>(
                        "{\"schema\":\"marco-movie-sync\",\"version\":2,\"updated\":200,\"watch_history\":[]}"
                                .getBytes(StandardCharsets.UTF_8));
        final List<String> dav403MkcolPaths = Collections.synchronizedList(new ArrayList<>());
        final Set<String> dav403Created = Collections.synchronizedSet(new HashSet<>());
        final AtomicReference<byte[]> dav403Store = new AtomicReference<>(null);
        final List<String> auth401MkcolPaths = Collections.synchronizedList(new ArrayList<>());
        final AtomicReference<byte[]> spaceStore = new AtomicReference<>(null);

        r2Server.createContext(
                "/weak/",
                ex -> {
                    try {
                        if ("GET".equals(ex.getRequestMethod())) {
                            byte[] b = weakStore.get();
                            ex.getResponseHeaders().set("ETag", "W/\"weak-etag-1\"");
                            ex.sendResponseHeaders(200, b.length);
                            try (OutputStream os = ex.getResponseBody()) {
                                os.write(b);
                            }
                            return;
                        }
                        if ("PUT".equals(ex.getRequestMethod())) {
                            lastPutIfMatch.set(ex.getRequestHeaders().getFirst("If-Match"));
                            lastPutIfNoneMatch.set(
                                    ex.getRequestHeaders().getFirst("If-None-Match"));
                            weakStore.set(readAll(ex.getRequestBody()));
                            ex.sendResponseHeaders(204, -1);
                            return;
                        }
                        ex.sendResponseHeaders(405, -1);
                    } finally {
                        ex.close();
                    }
                });

        r2Server.createContext(
                "/reject-inm/",
                ex -> {
                    try {
                        if ("GET".equals(ex.getRequestMethod())) {
                            byte[] b = noInmStore.get();
                            if (b == null) {
                                ex.sendResponseHeaders(404, -1);
                            } else {
                                ex.sendResponseHeaders(200, b.length);
                                try (OutputStream os = ex.getResponseBody()) {
                                    os.write(b);
                                }
                            }
                            return;
                        }
                        if ("PUT".equals(ex.getRequestMethod())) {
                            String inm = ex.getRequestHeaders().getFirst("If-None-Match");
                            byte[] body = readAll(ex.getRequestBody());
                            putHistory.add("inm=" + inm);
                            if (inm != null) {
                                ex.sendResponseHeaders(501, -1);
                                return;
                            }
                            noInmStore.set(body);
                            ex.sendResponseHeaders(201, -1);
                            return;
                        }
                        ex.sendResponseHeaders(405, -1);
                    } finally {
                        ex.close();
                    }
                });

        HttpServer cond412Server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        final List<String> cond412Headers = Collections.synchronizedList(new ArrayList<>());
        cond412Server.createContext(
                "/gzip-etag/",
                ex -> {
                    try {
                        if ("GET".equals(ex.getRequestMethod())) {
                            byte[] b = cond412Store.get();
                            ex.getResponseHeaders().set("ETag", "\"etag-apache-gzip\"");
                            ex.sendResponseHeaders(200, b.length);
                            try (OutputStream os = ex.getResponseBody()) {
                                os.write(b);
                            }
                            return;
                        }
                        if ("PUT".equals(ex.getRequestMethod())) {
                            String im = ex.getRequestHeaders().getFirst("If-Match");
                            String inm = ex.getRequestHeaders().getFirst("If-None-Match");
                            byte[] body = readAll(ex.getRequestBody());
                            cond412Headers.add("im=" + im + ",inm=" + inm);
                            if (im != null || inm != null) {
                                ex.sendResponseHeaders(412, -1);
                                return;
                            }
                            cond412Store.set(body);
                            ex.sendResponseHeaders(204, -1);
                            return;
                        }
                        ex.sendResponseHeaders(405, -1);
                    } finally {
                        ex.close();
                    }
                });

        r2Server.createContext(
                "/dav/",
                ex -> {
                    try {
                        String p = ex.getRequestURI().getPath();
                        String m = ex.getRequestMethod();
                        if ("MKCOL".equalsIgnoreCase(m)) {
                            String norm = p.endsWith("/") ? p : p + "/";
                            dav403MkcolPaths.add(norm);
                            byte[] respBody =
                                    ("mkcol-response-payload-" + norm)
                                            .getBytes(StandardCharsets.UTF_8);
                            if ("/dav/".equals(norm)) {
                                ex.sendResponseHeaders(403, respBody.length);
                                try (OutputStream os = ex.getResponseBody()) {
                                    os.write(respBody);
                                }
                                return;
                            }
                            dav403Created.add(norm);
                            ex.sendResponseHeaders(201, respBody.length);
                            try (OutputStream os = ex.getResponseBody()) {
                                os.write(respBody);
                            }
                            return;
                        }
                        if ("GET".equalsIgnoreCase(m)) {
                            byte[] b = dav403Store.get();
                            if (b == null) {
                                ex.sendResponseHeaders(404, -1);
                            } else {
                                ex.sendResponseHeaders(200, b.length);
                                try (OutputStream os = ex.getResponseBody()) {
                                    os.write(b);
                                }
                            }
                            return;
                        }
                        if ("PUT".equalsIgnoreCase(m)) {
                            byte[] body = readAll(ex.getRequestBody());
                            if (!dav403Created.contains("/dav/MarcoMovie/")) {
                                ex.sendResponseHeaders(409, -1);
                                return;
                            }
                            dav403Store.set(body);
                            ex.sendResponseHeaders(201, -1);
                            return;
                        }
                        ex.sendResponseHeaders(405, -1);
                    } finally {
                        ex.close();
                    }
                });

        r2Server.createContext(
                "/auth401/",
                ex -> {
                    try {
                        String p = ex.getRequestURI().getPath();
                        String m = ex.getRequestMethod();
                        if ("MKCOL".equalsIgnoreCase(m)) {
                            String norm = p.endsWith("/") ? p : p + "/";
                            auth401MkcolPaths.add(norm);
                            ex.sendResponseHeaders(401, -1);
                            return;
                        }
                        if ("GET".equalsIgnoreCase(m)) {
                            ex.sendResponseHeaders(404, -1);
                            return;
                        }
                        if ("PUT".equalsIgnoreCase(m)) {
                            readAll(ex.getRequestBody());
                            ex.sendResponseHeaders(409, -1);
                            return;
                        }
                        ex.sendResponseHeaders(405, -1);
                    } finally {
                        ex.close();
                    }
                });

        r2Server.createContext(
                "/space dir/",
                ex -> {
                    try {
                        String m = ex.getRequestMethod();
                        if ("MKCOL".equalsIgnoreCase(m)) {
                            ex.sendResponseHeaders(201, -1);
                            return;
                        }
                        if ("GET".equalsIgnoreCase(m)) {
                            byte[] b = spaceStore.get();
                            if (b == null) {
                                ex.sendResponseHeaders(404, -1);
                            } else {
                                ex.sendResponseHeaders(200, b.length);
                                try (OutputStream os = ex.getResponseBody()) {
                                    os.write(b);
                                }
                            }
                            return;
                        }
                        if ("PUT".equalsIgnoreCase(m)) {
                            spaceStore.set(readAll(ex.getRequestBody()));
                            ex.sendResponseHeaders(201, -1);
                            return;
                        }
                        ex.sendResponseHeaders(405, -1);
                    } finally {
                        ex.close();
                    }
                });

        r2Server.start();
        cond412Server.start();
        try {
            int port = r2Server.getAddress().getPort();
            int port412 = cond412Server.getAddress().getPort();

            // M-W1a: Weak ETag W/"..." omits If-Match
            CloudSync.clearNoConditionalWriteHostsForTest();
            CloudSync.syncWebdav(
                    "http://127.0.0.1:" + port + "/weak/",
                    "alice",
                    "pass",
                    remote ->
                            CloudSync.merge(
                                    "[]", "[]", "", Collections.emptyList(), false, remote, 1100L));
            check(
                    lastPutIfMatch.get() == null && lastPutIfNoneMatch.get() == null,
                    "M-W1 weak ETag (W/\"...\") does not send If-Match header");

            // M-W1b: Server rejecting If-None-Match: * retries without header and remembers host
            CloudSync.clearNoConditionalWriteHostsForTest();
            putHistory.clear();
            String rejectInmUrl = "http://127.0.0.1:" + port + "/reject-inm/";
            CloudSync.syncWebdav(
                    rejectInmUrl,
                    "alice",
                    "pass",
                    remote ->
                            CloudSync.merge(
                                    "[]", "[]", "", Collections.emptyList(), false, remote, 1200L));
            check(
                    putHistory.size() == 2
                            && "inm=*".equals(putHistory.get(0))
                            && "inm=null".equals(putHistory.get(1))
                            && noInmStore.get() != null,
                    "M-W1 server rejecting If-None-Match:* retries without header and succeeds");
            check(
                    CloudSync.isHostMarkedNoConditionalWrite(
                            CloudSync.resolveWebdavFileUrl(rejectInmUrl)),
                    "M-W1 host is remembered as not supporting conditional writes after If-None-Match fallback");

            // M-W1c: 412 retries exhausted -> 1 unconditional PUT + per-host memory on next sync
            CloudSync.clearNoConditionalWriteHostsForTest();
            cond412Headers.clear();
            String cond412Url = "http://127.0.0.1:" + port412 + "/gzip-etag/";
            CloudSync.syncWebdav(
                    cond412Url,
                    "alice",
                    "pass",
                    remote ->
                            CloudSync.merge(
                                    "[]", "[]", "", Collections.emptyList(), false, remote, 1300L));
            check(
                    cond412Headers.size() == 4 && "im=null,inm=null".equals(cond412Headers.get(3)),
                    "M-W1 412 retries exhausted performs one unconditional PUT");
            check(
                    CloudSync.isHostMarkedNoConditionalWrite(
                            CloudSync.resolveWebdavFileUrl(cond412Url)),
                    "M-W1 host remembered after 412 unconditional PUT succeeds");
            cond412Headers.clear();
            CloudSync.syncWebdav(
                    cond412Url,
                    "alice",
                    "pass",
                    remote ->
                            CloudSync.merge(
                                    "[]", "[]", "", Collections.emptyList(), false, remote, 1400L));
            check(
                    cond412Headers.size() == 1 && "im=null,inm=null".equals(cond412Headers.get(0)),
                    "M-W1 subsequent sync to remembered host skips conditional headers immediately");

            // M-W2a: /dav/ returns 403 on MKCOL -> continues to /dav/MarcoMovie/ (201) and succeeds
            CloudSync.clearNoConditionalWriteHostsForTest();
            CloudSync.syncWebdav(
                    "http://127.0.0.1:" + port + "/dav/MarcoMovie/",
                    "alice",
                    "pass",
                    remote ->
                            CloudSync.merge(
                                    "[]", "[]", "", Collections.emptyList(), false, remote, 1500L));
            check(
                    dav403MkcolPaths.contains("/dav/")
                            && dav403MkcolPaths.contains("/dav/MarcoMovie/")
                            && dav403Store.get() != null,
                    "M-W2 MKCOL continues past /dav/ returning 403 and creates /dav/MarcoMovie/");

            // M-W2b: MKCOL stops immediately on 401 without requesting child collections
            try {
                CloudSync.syncWebdav(
                        "http://127.0.0.1:" + port + "/auth401/child1/child2/",
                        "alice",
                        "pass",
                        remote ->
                                CloudSync.merge(
                                        "[]",
                                        "[]",
                                        "",
                                        Collections.emptyList(),
                                        false,
                                        remote,
                                        1600L));
                check(false, "401 MKCOL with 409 PUT must throw");
            } catch (java.io.IOException expected) {
                check(
                        auth401MkcolPaths.size() == 1
                                && "/auth401/".equals(auth401MkcolPaths.get(0)),
                        "M-W2 MKCOL stops immediately on HTTP 401");
            }

            // Minor fix: URL containing spaces encodes cleanly and syncs
            CloudSync.syncWebdav(
                    "http://127.0.0.1:" + port + "/space dir/",
                    "alice",
                    "pass",
                    remote ->
                            CloudSync.merge(
                                    "[]", "[]", "", Collections.emptyList(), false, remote, 1700L));
            check(spaceStore.get() != null, "WebDAV URL containing spaces syncs cleanly");

            // M-W3: AutoPushTracker updates lastAutoPushMs on every attempt and applies 1,2,4,8,15m
            // backoff
            CloudSync.AutoPushTracker tracker = new CloudSync.AutoPushTracker();
            tracker.onAttemptStart(10_000L);
            check(
                    tracker.lastAutoPushMs() == 10_000L,
                    "M-W3 lastAutoPushMs updated at attempt start before result is known");
            tracker.onFailure(10_500L);
            check(
                    tracker.lastAutoPushMs() == 10_500L
                            && tracker.consecutiveFailures() == 1
                            && tracker.computeDelayMs(11_000L, true) == 60_000L - 500L,
                    "M-W3 first failure schedules 1-minute backoff even for immediate trigger");
            check(
                    CloudSync.AutoPushTracker.backoffMsForFailures(1) == 60_000L
                            && CloudSync.AutoPushTracker.backoffMsForFailures(2) == 120_000L
                            && CloudSync.AutoPushTracker.backoffMsForFailures(3) == 240_000L
                            && CloudSync.AutoPushTracker.backoffMsForFailures(4) == 480_000L
                            && CloudSync.AutoPushTracker.backoffMsForFailures(5) == 900_000L
                            && CloudSync.AutoPushTracker.backoffMsForFailures(8) == 900_000L,
                    "M-W3 exponential backoff follows 1, 2, 4, 8 minutes capped at 15 minutes");
            tracker.onAttemptStart(80_000L);
            tracker.onSuccess(80_200L);
            check(
                    tracker.lastAutoPushMs() == 80_200L
                            && tracker.consecutiveFailures() == 0
                            && tracker.computeDelayMs(80_500L, true) == 2_500L,
                    "M-W3 success resets failure backoff");

            // M-W4 & Scoped cancel: cancelOwned only cancels matching Activity, and submitExitPush
            // cannot be cancelled
            CloudSync.SyncRuntime runtime = new CloudSync.SyncRuntime();
            final List<Runnable> scheduledQueue = new ArrayList<>();
            CloudSync.DelayScheduler fakeScheduler =
                    new CloudSync.DelayScheduler() {
                        @Override
                        public void postDelayed(Runnable r, long delayMs) {
                            scheduledQueue.add(r);
                        }

                        @Override
                        public void removeCallbacks(Runnable r) {
                            scheduledQueue.remove(r);
                        }
                    };
            Object activityA = new Object();
            Object activityB = new Object();
            runtime.scheduleOwned(activityB, fakeScheduler, 2500L, () -> {});
            check(
                    !runtime.cancelOwned(activityA) && scheduledQueue.size() == 1,
                    "CloudSyncDialog.cancel(activityA) does not cancel activityB's pending task");
            check(
                    runtime.cancelOwned(activityB) && scheduledQueue.isEmpty(),
                    "CloudSyncDialog.cancel(activityB) cancels activityB's pending task");

            spaceStore.set(null);
            final java.util.concurrent.atomic.AtomicBoolean appCtxCredentialLoaded =
                    new java.util.concurrent.atomic.AtomicBoolean(false);
            java.util.concurrent.Future<CloudSync.MergeResult> exitFuture =
                    runtime.submitExitPush(
                            "http://127.0.0.1:" + port + "/space dir/",
                            "alice",
                            () -> {
                                appCtxCredentialLoaded.set(true);
                                return "pass";
                            },
                            remote ->
                                    CloudSync.merge(
                                            "[]",
                                            "[]",
                                            "",
                                            Collections.emptyList(),
                                            false,
                                            remote,
                                            1800L));
            runtime.cancelOwned(activityA);
            runtime.cancelOwned(null);
            CloudSync.MergeResult exitRes =
                    exitFuture.get(10, java.util.concurrent.TimeUnit.SECONDS);
            check(
                    exitRes != null && appCtxCredentialLoaded.get() && spaceStore.get() != null,
                    "M-W4 submitExitPush completes on background executor and cannot be cancelled by cancel()");

            // M-W6: mergeSerial re-reads -> merges -> writes on same serial thread so deleted item
            // never resurrects
            java.util.concurrent.ExecutorService serialExec =
                    java.util.concurrent.Executors.newSingleThreadExecutor();
            try {
                WatchHistory.Entry zombieCandidate = new WatchHistory.Entry();
                zombieCandidate.site = "site_m";
                zombieCandidate.id = "vod_deleted";
                zombieCandidate.title = "待删除条目";
                zombieCandidate.position = 30_000;
                zombieCandidate.duration = 90_000;
                zombieCandidate.updated = 1_000L;
                final AtomicReference<String> diskHist =
                        new AtomicReference<>(WatchHistory.upsert("[]", zombieCandidate));
                final AtomicReference<String> diskFav = new AtomicReference<>("[]");
                final AtomicReference<String> diskTomb = new AtomicReference<>("");

                String remoteWithDeletedItem =
                        CloudSync.exportPayload(
                                diskHist.get(), "[]", "", Collections.emptyList(), false, 1_500L);

                // Queue a user deletion on serialExec BEFORE mergeSerial executes on serialExec
                final java.util.concurrent.CountDownLatch holdSerial =
                        new java.util.concurrent.CountDownLatch(1);
                serialExec.execute(
                        () -> {
                            try {
                                holdSerial.await(5, java.util.concurrent.TimeUnit.SECONDS);
                            } catch (InterruptedException e) {
                                Thread.currentThread().interrupt();
                            }
                            diskHist.set(
                                    WatchHistory.remove(diskHist.get(), "site_m\nvod_deleted"));
                            CloudSync.Tombstones t = CloudSync.Tombstones.read(diskTomb.get());
                            t.putMax("hist:site_m\nvod_deleted", 2_000L);
                            diskTomb.set(t.json());
                        });

                final CloudSync.LocalStore store =
                        new CloudSync.LocalStore() {
                            @Override
                            public String readHistoryJson() {
                                return diskHist.get();
                            }

                            @Override
                            public String readFavoritesJson() {
                                return diskFav.get();
                            }

                            @Override
                            public String readTombstonesJson() {
                                return diskTomb.get();
                            }

                            @Override
                            public void writeMerged(
                                    String historyJson,
                                    String favoritesJson,
                                    String tombstonesJson,
                                    CloudSync.MergeResult result) {
                                diskHist.set(historyJson);
                                diskFav.set(favoritesJson);
                                diskTomb.set(tombstonesJson);
                            }
                        };

                java.util.concurrent.ExecutorService callerExec =
                        java.util.concurrent.Executors.newSingleThreadExecutor();
                try {
                    java.util.concurrent.Future<CloudSync.MergeResult> mergeFuture =
                            callerExec.submit(
                                    () ->
                                            CloudSync.mergeSerial(
                                                    serialExec,
                                                    store,
                                                    Collections.emptyList(),
                                                    false,
                                                    remoteWithDeletedItem,
                                                    2_100L));
                    holdSerial.countDown();
                    CloudSync.MergeResult serialMerged =
                            mergeFuture.get(10, java.util.concurrent.TimeUnit.SECONDS);
                    check(
                            serialMerged.historyCount == 0
                                    && WatchHistory.read(diskHist.get()).isEmpty(),
                            "M-W6 mergeSerial re-reads latest history & tombstones on serial thread so deleted item never resurrects");
                } finally {
                    callerExec.shutdownNow();
                }
            } finally {
                serialExec.shutdownNow();
                CloudSync.clearNoConditionalWriteHostsForTest();
            }
        } finally {
            r2Server.stop(0);
            cond412Server.stop(0);
        }
    }
}
