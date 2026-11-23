package com.pilipala.marcomovie;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.lang.ref.WeakReference;
import java.net.HttpURLConnection;
import java.net.URI;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashSet;
import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.Callable;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;
import okhttp3.OkHttpClient;
import okhttp3.Request;
import okhttp3.Response;
import okhttp3.ResponseBody;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

/**
 * Cross-device cloud (WebDAV) and LAN peer-to-peer synchronization engine ({@code marco-movie-sync}
 * v2).
 *
 * <p>Syncs public watch-history bookmarks, favorites, deletion tombstones, and optionally user
 * public subscription configurations across Android TV, Android Mobile/Tablet, Android Lite, iOS,
 * iPadOS, macOS, and Windows. Never exports or mutates Private Space data, cloud drive tokens, or
 * Emby credentials.
 */
final class CloudSync {
    static final String SCHEMA = "marco-movie-sync";
    static final int VERSION = 2;
    static final String DEFAULT_FILE = "marco-movie-sync.json";
    static final int MAX_TOMBSTONES = 300;
    static final int MAX_SYNC_BYTES = 8 * 1024 * 1024;
    private static final char[] BASE64_ALPHABET =
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".toCharArray();
    static final OkHttpClient MKCOL_CLIENT =
            new OkHttpClient.Builder()
                    .connectTimeout(10, TimeUnit.SECONDS)
                    .readTimeout(10, TimeUnit.SECONDS)
                    .followRedirects(false)
                    .build();
    private static final Set<String> NO_CONDITIONAL_WRITE_HOSTS =
            Collections.synchronizedSet(new HashSet<>());
    private static final ThreadLocal<ExecutorService> ACTIVE_SERIAL_EXECUTOR = new ThreadLocal<>();

    private CloudSync() {}

    interface MergeCallback {
        MergeResult merge(String remotePayloadJson) throws Exception;
    }

    interface LanPeerCallback {
        String exportLocalPayload() throws Exception;

        MergeResult applyMergedPayload(String remoteMergedPayloadJson) throws Exception;
    }

    interface LocalStore {
        String readHistoryJson();

        String readFavoritesJson();

        String readTombstonesJson();

        void writeMerged(
                String historyJson,
                String favoritesJson,
                String tombstonesJson,
                MergeResult result);
    }

    interface DelayScheduler {
        void postDelayed(Runnable task, long delayMs);

        void removeCallbacks(Runnable task);
    }

    interface CredentialLoader {
        String loadPassword() throws Exception;
    }

    /** Tracks auto-push attempt timestamps and exponential failure backoff (1, 2, 4, 8 -> 15m). */
    static final class AutoPushTracker {
        static final long NORMAL_MIN_INTERVAL_MS = 5 * 60 * 1000L;
        static final long IMMEDIATE_DEBOUNCE_MS = 2500L;
        static final long READY_DEBOUNCE_MS = 3000L;
        static final long BASE_BACKOFF_MS = 60 * 1000L;
        static final long MAX_BACKOFF_MS = 15 * 60 * 1000L;

        private long lastAutoPushMs;
        private int consecutiveFailures;

        static long backoffMsForFailures(int failures) {
            if (failures <= 0) return 0L;
            int shift = Math.min(failures - 1, 4);
            return Math.min(MAX_BACKOFF_MS, BASE_BACKOFF_MS << shift);
        }

        synchronized void onAttemptStart(long nowMs) {
            lastAutoPushMs = nowMs;
        }

        synchronized void onSuccess(long nowMs) {
            lastAutoPushMs = nowMs;
            consecutiveFailures = 0;
        }

        synchronized void onFailure(long nowMs) {
            if (lastAutoPushMs <= 0L || nowMs > lastAutoPushMs) {
                lastAutoPushMs = nowMs;
            }
            consecutiveFailures++;
        }

        synchronized void resetBackoff() {
            consecutiveFailures = 0;
        }

        synchronized void resetAllForTest() {
            lastAutoPushMs = 0L;
            consecutiveFailures = 0;
        }

        synchronized long lastAutoPushMs() {
            return lastAutoPushMs;
        }

        synchronized int consecutiveFailures() {
            return consecutiveFailures;
        }

        synchronized long computeDelayMs(long nowMs, boolean immediate) {
            if (consecutiveFailures > 0) {
                long backoff = backoffMsForFailures(consecutiveFailures);
                long elapsed = lastAutoPushMs > 0L ? Math.max(0L, nowMs - lastAutoPushMs) : backoff;
                if (elapsed < backoff) {
                    return backoff - elapsed;
                }
                return immediate ? IMMEDIATE_DEBOUNCE_MS : READY_DEBOUNCE_MS;
            }
            if (immediate) {
                return IMMEDIATE_DEBOUNCE_MS;
            }
            if (lastAutoPushMs > 0L) {
                long elapsed = Math.max(0L, nowMs - lastAutoPushMs);
                if (elapsed < NORMAL_MIN_INTERVAL_MS) {
                    return NORMAL_MIN_INTERVAL_MS - elapsed;
                }
            }
            return READY_DEBOUNCE_MS;
        }
    }

    /**
     * Coordinates single-threaded background sync execution, owner-scoped UI auto-push cancellation,
     * and un-cancellable exit pushes.
     */
    static final class SyncRuntime {
        final ExecutorService syncExec =
                Executors.newSingleThreadExecutor(
                        r -> {
                            Thread t = new Thread(r, "marco-cloud-sync");
                            t.setDaemon(true);
                            return t;
                        });
        final AutoPushTracker tracker = new AutoPushTracker();
        private DelayScheduler pendingScheduler;
        private Runnable pendingCallback;
        private WeakReference<Object> pendingOwnerRef;

        synchronized void scheduleOwned(
                Object owner, DelayScheduler scheduler, long delayMs, final Runnable action) {
            if (pendingCallback != null && pendingScheduler != null) {
                pendingScheduler.removeCallbacks(pendingCallback);
            }
            final WeakReference<Object> ownerRef = new WeakReference<>(owner);
            pendingOwnerRef = ownerRef;
            pendingScheduler = scheduler;
            Runnable wrapper =
                    new Runnable() {
                        @Override
                        public void run() {
                            synchronized (SyncRuntime.this) {
                                if (pendingCallback == this) {
                                    pendingCallback = null;
                                    pendingOwnerRef = null;
                                    pendingScheduler = null;
                                }
                            }
                            action.run();
                        }
                    };
            pendingCallback = wrapper;
            scheduler.postDelayed(wrapper, delayMs);
        }

        synchronized boolean cancelOwned(Object owner) {
            if (pendingCallback == null) return false;
            Object currentOwner = pendingOwnerRef == null ? null : pendingOwnerRef.get();
            if (owner != null && currentOwner != null && currentOwner != owner) {
                return false;
            }
            if (pendingScheduler != null) {
                pendingScheduler.removeCallbacks(pendingCallback);
            }
            pendingCallback = null;
            pendingOwnerRef = null;
            pendingScheduler = null;
            return true;
        }

        Future<MergeResult> submitExitPush(
                final String rawUrl,
                final String username,
                final CredentialLoader passwordLoader,
                final MergeCallback merger) {
            return syncExec.submit(
                    () -> {
                        tracker.onAttemptStart(System.currentTimeMillis());
                        try {
                            String pass =
                                    passwordLoader != null ? passwordLoader.loadPassword() : "";
                            MergeResult res = syncWebdav(rawUrl, username, pass, merger);
                            tracker.onSuccess(System.currentTimeMillis());
                            return res;
                        } catch (Exception e) {
                            tracker.onFailure(System.currentTimeMillis());
                            throw e;
                        }
                    });
        }
    }

    static MergeResult mergeSerial(
            final ExecutorService serialExecutor,
            final LocalStore store,
            final List<SubscriptionItem> localSubscriptions,
            final boolean syncSubscriptions,
            final String remotePayloadJson,
            final long now)
            throws Exception {
        return mergeSerial(
                serialExecutor,
                store,
                localSubscriptions,
                syncSubscriptions,
                true,
                remotePayloadJson,
                now);
    }

    static MergeResult mergeSerial(
            final ExecutorService serialExecutor,
            final LocalStore store,
            final List<SubscriptionItem> localSubscriptions,
            final boolean syncSubscriptions,
            final boolean syncHistory,
            final String remotePayloadJson,
            final long now)
            throws Exception {
        Callable<MergeResult> task =
                () -> {
                    ExecutorService prev = ACTIVE_SERIAL_EXECUTOR.get();
                    ACTIVE_SERIAL_EXECUTOR.set(serialExecutor);
                    try {
                        String localHist = store.readHistoryJson();
                        String localFav = store.readFavoritesJson();
                        String localTomb = store.readTombstonesJson();
                        MergeResult res =
                                merge(
                                        localHist,
                                        localFav,
                                        localTomb,
                                        localSubscriptions,
                                        syncSubscriptions,
                                        syncHistory,
                                        remotePayloadJson,
                                        now);
                        store.writeMerged(
                                res.historyJson, res.favoritesJson, res.tombstonesJson, res);
                        return res;
                    } finally {
                        ACTIVE_SERIAL_EXECUTOR.set(prev);
                    }
                };
        if (serialExecutor == null || ACTIVE_SERIAL_EXECUTOR.get() == serialExecutor) {
            return task.call();
        }
        try {
            return serialExecutor.submit(task).get(15, TimeUnit.SECONDS);
        } catch (ExecutionException e) {
            Throwable cause = e.getCause();
            if (cause instanceof Exception) throw (Exception) cause;
            throw new IOException("串行合并写入失败", cause);
        } catch (TimeoutException e) {
            throw new IOException("串行合并写入超时 (15s)", e);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new IOException("串行合并写入中断", e);
        }
    }

    /** Public subscription item synchronized across devices in {@code marco-movie-sync} v2. */
    static final class SubscriptionItem {
        String key = "";
        String name = "";
        String url = "";
        String rawContent = "";
        boolean enabled = true;
        String selectedSiteKey = "";
        String groupTag = "";
        long updatedAt = 1L;

        JSONObject toJson() throws JSONException {
            String safeKey = key == null ? "" : key;
            JSONObject o =
                    new JSONObject()
                            .put("id", safeKey)
                            .put("syncKey", safeKey)
                            .put("key", safeKey)
                            .put("name", name == null || name.isEmpty() ? "我的订阅" : name)
                            .put("url", url == null ? "" : url)
                            .put("rawContent", rawContent == null ? "" : rawContent)
                            .put("isPrivate", false)
                            .put("enabled", enabled)
                            .put("selectedSiteKey", selectedSiteKey == null ? "" : selectedSiteKey)
                            .put("updatedAt", Math.max(1L, updatedAt));
            if (groupTag != null && !groupTag.isEmpty()) {
                o.put("group", groupTag);
                o.put("groupTag", groupTag);
            }
            return o;
        }

        static SubscriptionItem create(
                String name,
                String originUrl,
                String rawConfig,
                boolean enabled,
                String selectedSiteKey,
                long updatedAt)
                throws Exception {
            String cleanUrl = originUrl == null ? "" : originUrl.trim();
            if (cleanUrl.toLowerCase(Locale.ROOT).startsWith("file:")) {
                cleanUrl = "";
            }
            if (!cleanUrl.isEmpty() && !Cms.isHttp(cleanUrl)) {
                cleanUrl = "";
            }
            String publicRaw = sanitizePublicRawConfig(rawConfig);
            if (cleanUrl.isEmpty() && publicRaw.isEmpty()) return null;
            SubscriptionItem item = new SubscriptionItem();
            item.url = cleanUrl;
            item.rawContent = publicRaw;
            item.key = ConfigLibrary.identity(cleanUrl, publicRaw);
            item.name = name == null || name.trim().isEmpty() ? "我的订阅" : name.trim();
            item.enabled = enabled;
            item.selectedSiteKey = selectedSiteKey == null ? "" : selectedSiteKey.trim();
            item.updatedAt = Math.max(1L, updatedAt);
            return item;
        }

        static SubscriptionItem fromRemoteJson(JSONObject o) {
            if (o == null) return null;
            String grp = o.optString("group", o.optString("groupTag", "")).trim();
            if (isTruthyPrivateFlag(o.opt("isPrivate"))
                    || isTruthyPrivateFlag(o.opt("hidden"))
                    || grp.contains("隐私")
                    || grp.contains("私密")) {
                return null;
            }
            String rawUrl =
                    o.optString("warehouseUrl", "").trim().isEmpty()
                            ? o.optString("url", o.optString("origin", "")).trim()
                            : o.optString("warehouseUrl", "").trim();
            if (rawUrl.toLowerCase(Locale.ROOT).startsWith("file:")) {
                return null;
            }
            String cleanUrl = Cms.isHttp(rawUrl) ? rawUrl : "";
            String rawCfg =
                    sanitizePublicRawConfig(o.optString("rawContent", o.optString("raw", "")));
            if (cleanUrl.isEmpty() && rawCfg.isEmpty()) {
                return null;
            }
            try {
                String canonicalKey;
                String providedKey =
                        o.optString("syncKey", o.optString("key", o.optString("id", "")))
                                .trim()
                                .toLowerCase(Locale.ROOT);
                if (!cleanUrl.isEmpty() || !rawCfg.isEmpty()) {
                    canonicalKey = ConfigLibrary.identity(cleanUrl, rawCfg);
                } else if (providedKey.matches("[0-9a-f]{64}")) {
                    canonicalKey = providedKey;
                } else {
                    return null;
                }
                SubscriptionItem item = new SubscriptionItem();
                item.key = canonicalKey;
                item.name = o.optString("name", "").trim();
                if (item.name.isEmpty()) item.name = "我的订阅";
                item.url = cleanUrl;
                item.rawContent = rawCfg;
                item.enabled = o.optBoolean("enabled", true);
                item.selectedSiteKey =
                        o.optString("selectedSiteKey", o.optString("selected", "")).trim();
                item.groupTag = grp;
                item.updatedAt = Math.max(1L, o.optLong("updatedAt", o.optLong("updated", 1L)));
                return item;
            } catch (Exception ignored) {
                return null;
            }
        }
    }

    static boolean isTruthyPrivateFlag(Object flag) {
        if (flag == null) return false;
        if (flag instanceof Boolean) return (Boolean) flag;
        if (flag instanceof Number) return ((Number) flag).intValue() == 1;
        String s = String.valueOf(flag).trim().toLowerCase(Locale.ROOT);
        return "true".equals(s) || "1".equals(s);
    }

    private static boolean isPrivateJsonEntry(Object entry) {
        if (!(entry instanceof JSONObject)) return false;
        JSONObject map = (JSONObject) entry;
        if (isTruthyPrivateFlag(map.opt("isPrivate"))
                || isTruthyPrivateFlag(map.opt("private"))
                || isTruthyPrivateFlag(map.opt("hidden"))
                || "private".equalsIgnoreCase(map.optString("space", "").trim())) {
            return true;
        }
        String group = map.optString("group", "");
        return group.contains("隐私") || group.contains("私密");
    }

    /**
     * Strips any private site or live source from raw subscription JSON so Private Space entries
     * never leave the device.
     */
    static String sanitizePublicRawConfig(String raw) {
        if (raw == null) return "";
        String trimmed = raw.trim();
        if (trimmed.isEmpty()) return "";
        try {
            String unpacked = Cms.withoutComments(trimmed);
            JSONObject obj = new JSONObject(unpacked);
            if (obj.has("api") && isPrivateJsonEntry(obj)) {
                return "";
            }
            boolean modified = false;
            boolean hadFilteredArray = false;
            int remainingPublicItems = 0;
            String[] keys = {"sites", "lives"};
            for (String k : keys) {
                Object field = obj.opt(k);
                if (field instanceof JSONArray) {
                    hadFilteredArray = true;
                    JSONArray arr = (JSONArray) field;
                    JSONArray clean = new JSONArray();
                    for (int i = 0; i < arr.length(); i++) {
                        Object item = arr.opt(i);
                        if (isPrivateJsonEntry(item)) {
                            modified = true;
                        } else {
                            clean.put(item);
                            remainingPublicItems++;
                        }
                    }
                    if (modified) obj.put(k, clean);
                } else if (field instanceof JSONObject && isPrivateJsonEntry(field)) {
                    hadFilteredArray = true;
                    modified = true;
                    obj.put(k, new JSONArray());
                }
            }
            if (!modified) return raw;
            JSONArray depots = obj.optJSONArray("urls");
            if (depots == null) depots = obj.optJSONArray("depots");
            if (hadFilteredArray
                    && remainingPublicItems == 0
                    && (depots == null || depots.length() == 0)) {
                return "";
            }
            return obj.toString();
        } catch (Exception ignored) {
            return raw;
        }
    }

    static final class MergeResult {
        final String historyJson;
        final String favoritesJson;
        final String tombstonesJson;
        final List<SubscriptionItem> subscriptions;
        final String payloadJson;
        final int historyCount;
        final int favoriteCount;
        final int subscriptionCount;
        final boolean changed;
        final boolean subscriptionsChanged;

        MergeResult(
                String historyJson,
                String favoritesJson,
                String tombstonesJson,
                List<SubscriptionItem> subscriptions,
                String payloadJson,
                int historyCount,
                int favoriteCount,
                int subscriptionCount,
                boolean changed,
                boolean subscriptionsChanged) {
            this.historyJson = historyJson;
            this.favoritesJson = favoritesJson;
            this.tombstonesJson = tombstonesJson;
            this.subscriptions = subscriptions;
            this.payloadJson = payloadJson;
            this.historyCount = historyCount;
            this.favoriteCount = favoriteCount;
            this.subscriptionCount = subscriptionCount;
            this.changed = changed;
            this.subscriptionsChanged = subscriptionsChanged;
        }
    }

    /**
     * Tracks deletion and favorite-addition timestamps so deleted items do not resurrect across
     * devices.
     *
     * <ul>
     *   <li>{@code hist:<site>\n<id>} -> epoch millis when watch-history bookmark was deleted
     *   <li>{@code fav:<site>\n<id>} -> epoch millis when favorite was removed
     *   <li>{@code add:<site>\n<id>} -> epoch millis when favorite was added locally
     *   <li>{@code sub:<sha256-hex>} -> epoch millis when subscription was deleted locally
     * </ul>
     */
    static final class Tombstones {
        final Map<String, Long> stamps = new LinkedHashMap<>();

        static Tombstones read(String raw) {
            Tombstones t = new Tombstones();
            if (raw == null || raw.isEmpty()) return t;
            try {
                JSONObject obj = new JSONObject(raw);
                Iterator<String> keys = obj.keys();
                List<String> names = new ArrayList<>();
                while (keys.hasNext()) names.add(keys.next());
                Collections.sort(names, (a, b) -> Long.compare(obj.optLong(b), obj.optLong(a)));
                for (int i = 0; i < Math.min(MAX_TOMBSTONES, names.size()); i++) {
                    String k = names.get(i);
                    long ts = obj.optLong(k, 0L);
                    if (!k.isEmpty() && ts > 0L) t.stamps.put(k, ts);
                }
            } catch (Exception e) {
                AppLog.w("CloudSync", "Failed to parse tombstones JSON", e);
            }
            return t;
        }

        String json() {
            return toJsonObject().toString();
        }

        JSONObject toJsonObject() {
            List<Map.Entry<String, Long>> list = new ArrayList<>(stamps.entrySet());
            Collections.sort(list, (a, b) -> Long.compare(b.getValue(), a.getValue()));
            JSONObject out = new JSONObject();
            for (int i = 0; i < Math.min(MAX_TOMBSTONES, list.size()); i++) {
                Map.Entry<String, Long> e = list.get(i);
                if (e.getValue() != null && e.getValue() > 0L) {
                    try {
                        out.put(e.getKey(), e.getValue().longValue());
                    } catch (JSONException ex) {
                        AppLog.w("CloudSync", "Failed to serialize tombstone key", ex);
                    }
                }
            }
            return out;
        }

        void putMax(String key, long ts) {
            if (key == null || key.isEmpty() || ts <= 0L) return;
            Long prev = stamps.get(key);
            if (prev == null || ts > prev) stamps.put(key, ts);
        }

        long get(String key) {
            Long v = stamps.get(key);
            return v == null ? 0L : v;
        }

        static String recordHistoryDelete(String raw, String itemKey, long now) {
            Tombstones t = read(raw);
            if (itemKey != null && !itemKey.isEmpty()) {
                t.putMax("hist:" + itemKey, now);
            }
            return t.json();
        }

        static String recordHistoryClear(
                String raw, List<WatchHistory.Entry> currentEntries, long now) {
            Tombstones t = read(raw);
            if (currentEntries != null) {
                for (WatchHistory.Entry e : currentEntries) {
                    if (e != null && e.site != null && e.id != null) {
                        t.putMax("hist:" + e.key(), now);
                    }
                }
            }
            return t.json();
        }

        static String recordFavoriteToggle(
                String raw, String itemKey, boolean nowFavorited, long now) {
            Tombstones t = read(raw);
            if (itemKey != null && !itemKey.isEmpty()) {
                if (nowFavorited) {
                    t.stamps.put("add:" + itemKey, now);
                    t.stamps.remove("fav:" + itemKey);
                } else {
                    t.stamps.put("fav:" + itemKey, now);
                    t.stamps.remove("add:" + itemKey);
                }
            }
            return t.json();
        }

        static String recordSubscriptionUpsert(String raw, String subKey) {
            Tombstones t = read(raw);
            if (subKey != null && !subKey.isEmpty()) {
                t.stamps.remove("sub:" + subKey);
            }
            return t.json();
        }

        static String recordSubscriptionDelete(String raw, String subKey, long now) {
            Tombstones t = read(raw);
            if (subKey != null && !subKey.isEmpty()) {
                t.putMax("sub:" + subKey, now);
            }
            return t.json();
        }

        void merge(Tombstones other) {
            if (other == null) return;
            for (Map.Entry<String, Long> e : other.stamps.entrySet()) {
                if (e.getValue() != null) putMax(e.getKey(), e.getValue());
            }
        }
    }

    static String exportPayload(
            String historyJson,
            String favoritesJson,
            String tombstonesJson,
            List<SubscriptionItem> localSubscriptions,
            boolean syncSubscriptions,
            long now) {
        return exportPayload(
                historyJson,
                favoritesJson,
                tombstonesJson,
                localSubscriptions,
                syncSubscriptions,
                null,
                now);
    }

    static String exportPayload(
            String historyJson,
            String favoritesJson,
            String tombstonesJson,
            List<SubscriptionItem> localSubscriptions,
            boolean syncSubscriptions,
            JSONArray preservedRemoteSubscriptions,
            long now) {
        List<WatchHistory.Entry> history = WatchHistory.read(historyJson);
        List<Favorites.Entry> favs = Favorites.read(favoritesJson);
        Tombstones tombs = Tombstones.read(tombstonesJson);
        JSONArray histArr = new JSONArray();
        for (WatchHistory.Entry e : history) {
            try {
                histArr.put(e.json());
            } catch (JSONException ex) {
                AppLog.w("CloudSync", "Failed to serialize history entry", ex);
            }
        }
        JSONArray favArr = new JSONArray();
        for (Favorites.Entry f : favs) {
            try {
                long favTs = Math.max(1L, tombs.get("add:" + f.key()));
                favArr.put(f.json().put("updated", favTs).put("addedAt", favTs));
            } catch (JSONException ex) {
                AppLog.w("CloudSync", "Failed to serialize favorite entry", ex);
            }
        }
        try {
            JSONObject out =
                    new JSONObject()
                            .put("schema", SCHEMA)
                            .put("version", VERSION)
                            .put("updated", now)
                            .put("updatedAt", now)
                            .put("watch_history", histArr)
                            .put("favorites", favArr)
                            .put("tombstones", tombs.toJsonObject());
            if (syncSubscriptions) {
                JSONArray subsArr = new JSONArray();
                if (localSubscriptions != null) {
                    for (SubscriptionItem sub : localSubscriptions) {
                        if (sub == null || sub.key == null || sub.key.isEmpty()) continue;
                        if (tombs.get("sub:" + sub.key) >= sub.updatedAt) continue;
                        subsArr.put(sub.toJson());
                    }
                }
                out.put("subscriptions", subsArr);
            } else if (preservedRemoteSubscriptions != null) {
                out.put("subscriptions", preservedRemoteSubscriptions);
            }
            return out.toString();
        } catch (JSONException e) {
            return "{}";
        }
    }

    static MergeResult merge(
            String localHistoryJson,
            String localFavoritesJson,
            String localTombstonesJson,
            String remotePayloadJson,
            long now) {
        return merge(
                localHistoryJson,
                localFavoritesJson,
                localTombstonesJson,
                null,
                false,
                remotePayloadJson,
                now);
    }

    static MergeResult merge(
            String localHistoryJson,
            String localFavoritesJson,
            String localTombstonesJson,
            List<SubscriptionItem> localSubscriptions,
            boolean syncSubscriptions,
            String remotePayloadJson,
            long now) {
        return merge(
                localHistoryJson,
                localFavoritesJson,
                localTombstonesJson,
                localSubscriptions,
                syncSubscriptions,
                true,
                remotePayloadJson,
                now);
    }

    static MergeResult merge(
            String localHistoryJson,
            String localFavoritesJson,
            String localTombstonesJson,
            List<SubscriptionItem> localSubscriptions,
            boolean syncSubscriptions,
            boolean syncHistory,
            String remotePayloadJson,
            long now) {
        List<WatchHistory.Entry> localHist = WatchHistory.read(localHistoryJson);
        List<Favorites.Entry> localFavs = Favorites.read(localFavoritesJson);
        Tombstones tombs = Tombstones.read(localTombstonesJson);

        List<WatchHistory.Entry> remoteHist = new ArrayList<>();
        List<Favorites.Entry> remoteFavs = new ArrayList<>();
        Map<String, Long> remoteFavAdded = new LinkedHashMap<>();
        List<SubscriptionItem> remoteSubs = new ArrayList<>();
        JSONArray rawRemoteSubsArray = null;
        JSONArray rawRemoteHistArray = null;
        JSONArray rawRemoteFavsArray = null;
        JSONObject rawRemoteTombsObj = null;

        if (remotePayloadJson != null && !remotePayloadJson.trim().isEmpty()) {
            try {
                JSONObject root = new JSONObject(remotePayloadJson);
                String schema = root.optString("schema", root.optString("format", ""));
                if (!schema.isEmpty()
                        && !SCHEMA.equals(schema)
                        && !"marco-movie-backup".equals(schema)
                        && !"MarcoMovie-1".equals(schema)) {
                    throw new IllegalArgumentException("不支持的同步文件格式: " + schema);
                }
                JSONObject remoteTombObj = root.optJSONObject("tombstones");
                rawRemoteTombsObj = remoteTombObj;
                if (remoteTombObj != null) {
                    if (syncHistory) {
                        tombs.merge(Tombstones.read(remoteTombObj.toString()));
                    } else {
                        Iterator<String> tKeys = remoteTombObj.keys();
                        JSONObject subOnlyTombs = new JSONObject();
                        while (tKeys.hasNext()) {
                            String tk = tKeys.next();
                            if (tk != null && tk.startsWith("sub:")) {
                                subOnlyTombs.put(tk, remoteTombObj.optLong(tk));
                            }
                        }
                        tombs.merge(Tombstones.read(subOnlyTombs.toString()));
                    }
                }
                JSONArray hArr = root.optJSONArray("watch_history");
                if (hArr == null) hArr = root.optJSONArray("history");
                if (hArr == null) hArr = root.optJSONArray("watchHistory");
                JSONObject prefsBag = root.optJSONObject("prefs");
                if (prefsBag == null) prefsBag = root.optJSONObject("settings");
                if (hArr == null && prefsBag != null) {
                    Object rawH = prefsBag.opt("watch_history");
                    if (rawH instanceof JSONArray) hArr = (JSONArray) rawH;
                    else if (rawH instanceof String && !((String) rawH).isEmpty()) {
                        hArr = new JSONArray((String) rawH);
                    }
                }
                rawRemoteHistArray = hArr;
                if (syncHistory && hArr != null) {
                    remoteHist = parseRemoteHistory(hArr);
                }
                JSONArray fArr = root.optJSONArray("favorites");
                if (fArr == null && prefsBag != null) {
                    Object rawF = prefsBag.opt("favorites");
                    if (rawF instanceof JSONArray) fArr = (JSONArray) rawF;
                    else if (rawF instanceof String && !((String) rawF).isEmpty()) {
                        fArr = new JSONArray((String) rawF);
                    }
                }
                rawRemoteFavsArray = fArr;
                if (syncHistory && fArr != null) {
                    parseRemoteFavorites(fArr, remoteFavs, remoteFavAdded);
                }
                if (root.has("subscriptions") && root.optJSONArray("subscriptions") != null) {
                    rawRemoteSubsArray = root.optJSONArray("subscriptions");
                    for (int i = 0; i < rawRemoteSubsArray.length(); i++) {
                        SubscriptionItem sub =
                                SubscriptionItem.fromRemoteJson(
                                        rawRemoteSubsArray.optJSONObject(i));
                        if (sub != null) remoteSubs.add(sub);
                    }
                } else if (prefsBag != null
                        && prefsBag.optJSONArray("saved_subscriptions") != null) {
                    JSONArray savedSubs = prefsBag.optJSONArray("saved_subscriptions");
                    for (int i = 0; i < savedSubs.length(); i++) {
                        SubscriptionItem sub =
                                SubscriptionItem.fromRemoteJson(savedSubs.optJSONObject(i));
                        if (sub != null) remoteSubs.add(sub);
                    }
                } else if ("MarcoMovie-1".equals(schema) || "marco-movie-backup".equals(schema)) {
                    String origin = root.optString("origin", "").trim();
                    String cfgRaw = root.optString("rawConfig", root.optString("config", ""));
                    SubscriptionItem legacy =
                            SubscriptionItem.create("备份订阅", origin, cfgRaw, true, "", 1L);
                    if (legacy != null) remoteSubs.add(legacy);
                }
            } catch (IllegalArgumentException e) {
                throw e;
            } catch (Exception e) {
                throw new IllegalArgumentException("远端同步数据解析失败", e);
            }
        }

        // 1. Merge WatchHistory (Last-Write-Wins on `updated`, respecting `hist:` tombstones)
        Map<String, WatchHistory.Entry> histMap = new LinkedHashMap<>();
        for (WatchHistory.Entry e : localHist) {
            long delAt = tombs.get("hist:" + e.key());
            if (delAt > 0L && delAt >= e.updated) continue;
            histMap.put(e.key(), e);
        }
        for (WatchHistory.Entry r : remoteHist) {
            String key = r.key();
            long delAt = tombs.get("hist:" + key);
            if (delAt > 0L && delAt >= r.updated) continue;
            WatchHistory.Entry cur = histMap.get(key);
            if (cur == null
                    || r.updated > cur.updated
                    || (r.updated == cur.updated && r.position > cur.position)) {
                histMap.put(key, r);
            }
        }
        List<WatchHistory.Entry> mergedHist = new ArrayList<>(histMap.values());
        Collections.sort(mergedHist, (a, b) -> Long.compare(b.updated, a.updated));
        if (mergedHist.size() > WatchHistory.LIMIT) {
            mergedHist = new ArrayList<>(mergedHist.subList(0, WatchHistory.LIMIT));
        }

        // 2. Merge Favorites (respecting `fav:` removal vs `add:` addition timestamps)
        Map<String, Favorites.Entry> favMap = new LinkedHashMap<>();
        for (Favorites.Entry f : localFavs) {
            String key = f.key();
            long addedAt = Math.max(1L, tombs.get("add:" + key));
            long delAt = tombs.get("fav:" + key);
            if (delAt > addedAt) continue;
            tombs.putMax("add:" + key, addedAt);
            favMap.put(key, f);
        }
        for (Favorites.Entry rf : remoteFavs) {
            String key = rf.key();
            Long remoteAddedObj = remoteFavAdded.get(key);
            long remoteAdded = Math.max(1L, remoteAddedObj == null ? 1L : remoteAddedObj);
            long localAdded = tombs.get("add:" + key);
            long effectiveAdded = Math.max(remoteAdded, localAdded);
            long delAt = tombs.get("fav:" + key);
            if (delAt > effectiveAdded) continue;
            tombs.putMax("add:" + key, effectiveAdded);
            if (!favMap.containsKey(key)) {
                favMap.put(key, rf);
            } else {
                Favorites.Entry existing = favMap.get(key);
                if ((existing.poster == null || existing.poster.isEmpty())
                        && rf.poster != null
                        && !rf.poster.isEmpty()) {
                    existing.poster = rf.poster;
                }
            }
        }
        List<Favorites.Entry> mergedFavs = new ArrayList<>(favMap.values());
        if (mergedFavs.size() > Favorites.LIMIT) {
            mergedFavs = new ArrayList<>(mergedFavs.subList(0, Favorites.LIMIT));
        }

        // 3. Merge Public Subscriptions (when opted in)
        List<SubscriptionItem> mergedSubs = null;
        boolean subsChanged = false;
        if (syncSubscriptions) {
            Map<String, SubscriptionItem> subMap = new LinkedHashMap<>();
            List<String> beforeDigest = new ArrayList<>();
            if (localSubscriptions != null) {
                for (SubscriptionItem s : localSubscriptions) {
                    if (s == null || s.key == null || s.key.isEmpty()) continue;
                    beforeDigest.add(subscriptionStateKey(s));
                    long delAt = tombs.get("sub:" + s.key);
                    if (delAt > 0L && delAt >= s.updatedAt) continue;
                    subMap.put(s.key, s);
                }
            }
            for (SubscriptionItem rs : remoteSubs) {
                if (rs == null || rs.key == null || rs.key.isEmpty()) continue;
                long delAt = tombs.get("sub:" + rs.key);
                if (delAt > 0L && delAt >= rs.updatedAt) continue;
                SubscriptionItem cur = subMap.get(rs.key);
                if (cur == null) {
                    subMap.put(rs.key, rs);
                } else {
                    boolean remoteNewer =
                            rs.updatedAt > cur.updatedAt
                                    || (rs.updatedAt == cur.updatedAt
                                            && cur.rawContent.isEmpty()
                                            && !rs.rawContent.isEmpty());
                    if (remoteNewer) {
                        if (rs.rawContent.isEmpty() && !cur.rawContent.isEmpty()) {
                            rs.rawContent = cur.rawContent;
                        }
                        if (rs.groupTag.isEmpty() && !cur.groupTag.isEmpty()) {
                            rs.groupTag = cur.groupTag;
                        }
                        subMap.put(rs.key, rs);
                    } else if (cur.rawContent.isEmpty() && !rs.rawContent.isEmpty()) {
                        cur.rawContent = rs.rawContent;
                    }
                }
            }
            mergedSubs = new ArrayList<>(subMap.values());
            List<String> afterDigest = new ArrayList<>();
            for (SubscriptionItem s : mergedSubs) {
                afterDigest.add(subscriptionStateKey(s));
            }
            subsChanged = !beforeDigest.equals(afterDigest);
        }

        if (!syncHistory) {
            String nextTombJson = tombs.json();
            JSONObject cloudTombs = new JSONObject();
            if (rawRemoteTombsObj != null) {
                Iterator<String> rk = rawRemoteTombsObj.keys();
                while (rk.hasNext()) {
                    String k = rk.next();
                    try {
                        cloudTombs.put(k, rawRemoteTombsObj.optLong(k));
                    } catch (JSONException ignored) {
                    }
                }
            }
            JSONObject localTombObj = tombs.toJsonObject();
            Iterator<String> lk = localTombObj.keys();
            while (lk.hasNext()) {
                String k = lk.next();
                if (k != null && k.startsWith("sub:")) {
                    long lv = localTombObj.optLong(k);
                    if (lv > cloudTombs.optLong(k)) {
                        try {
                            cloudTombs.put(k, lv);
                        } catch (JSONException ignored) {
                        }
                    }
                }
            }
            String payload;
            try {
                JSONObject out =
                        new JSONObject()
                                .put("schema", SCHEMA)
                                .put("version", VERSION)
                                .put("updated", now)
                                .put("updatedAt", now)
                                .put(
                                        "watch_history",
                                        rawRemoteHistArray != null
                                                ? rawRemoteHistArray
                                                : new JSONArray())
                                .put(
                                        "favorites",
                                        rawRemoteFavsArray != null
                                                ? rawRemoteFavsArray
                                                : new JSONArray())
                                .put("tombstones", cloudTombs);
                if (syncSubscriptions) {
                    JSONArray subsArr = new JSONArray();
                    if (mergedSubs != null) {
                        for (SubscriptionItem sub : mergedSubs) {
                            if (sub == null || sub.key == null || sub.key.isEmpty()) continue;
                            if (tombs.get("sub:" + sub.key) >= sub.updatedAt) continue;
                            subsArr.put(sub.toJson());
                        }
                    }
                    out.put("subscriptions", subsArr);
                } else if (rawRemoteSubsArray != null) {
                    out.put("subscriptions", rawRemoteSubsArray);
                }
                payload = out.toString();
            } catch (JSONException e) {
                payload = "{}";
            }
            int subCount =
                    syncSubscriptions
                            ? (mergedSubs == null ? 0 : mergedSubs.size())
                            : (localSubscriptions == null ? 0 : localSubscriptions.size());
            return new MergeResult(
                    localHistoryJson != null ? localHistoryJson : "[]",
                    localFavoritesJson != null ? localFavoritesJson : "[]",
                    nextTombJson,
                    mergedSubs,
                    payload,
                    0,
                    0,
                    subCount,
                    subsChanged,
                    subsChanged);
        }

        JSONArray outHistArr = new JSONArray();
        for (WatchHistory.Entry e : mergedHist) {
            try {
                outHistArr.put(e.json());
            } catch (JSONException ex) {
                AppLog.w("CloudSync", "Failed to serialize merged history entry", ex);
            }
        }
        JSONArray outFavArr = new JSONArray();
        for (Favorites.Entry f : mergedFavs) {
            try {
                outFavArr.put(f.json());
            } catch (JSONException ex) {
                AppLog.w("CloudSync", "Failed to serialize merged favorite entry", ex);
            }
        }

        String nextHistJson = outHistArr.toString();
        String nextFavJson = outFavArr.toString();
        String nextTombJson = tombs.json();
        boolean changed =
                !sameHistory(localHist, mergedHist)
                        || !sameFavorites(localFavs, mergedFavs)
                        || subsChanged;
        String payload =
                exportPayload(
                        nextHistJson,
                        nextFavJson,
                        nextTombJson,
                        mergedSubs,
                        syncSubscriptions,
                        rawRemoteSubsArray,
                        now);
        int subCount =
                syncSubscriptions
                        ? (mergedSubs == null ? 0 : mergedSubs.size())
                        : (localSubscriptions == null ? 0 : localSubscriptions.size());
        return new MergeResult(
                nextHistJson,
                nextFavJson,
                nextTombJson,
                mergedSubs,
                payload,
                mergedHist.size(),
                mergedFavs.size(),
                subCount,
                changed,
                subsChanged);
    }

    private static String subscriptionStateKey(SubscriptionItem s) {
        return s.key
                + "|"
                + s.name
                + "|"
                + s.url
                + "|"
                + s.enabled
                + "|"
                + s.selectedSiteKey
                + "|"
                + (s.rawContent == null ? 0 : s.rawContent.hashCode());
    }

    private static List<WatchHistory.Entry> parseRemoteHistory(JSONArray arr) {
        List<WatchHistory.Entry> out = new ArrayList<>();
        for (int i = 0; i < arr.length(); i++) {
            JSONObject o = arr.optJSONObject(i);
            if (o == null) continue;
            String site = o.optString("site", o.optString("siteKey", "")).trim();
            String id = o.optString("id", o.optString("vodId", "")).trim();
            if (site.isEmpty() || id.isEmpty() || "live".equals(site)) continue;
            WatchHistory.Entry e = new WatchHistory.Entry();
            e.site = site;
            e.id = id;
            e.title = o.optString("title", "").trim();
            e.poster = o.optString("poster", "");
            e.line = o.optString("line", o.optString("routeName", ""));
            e.episode =
                    o.optString(
                            "episode", o.optString("episodeName", o.optString("episodeTitle", "")));
            e.index = Math.max(0, o.optInt("index", o.optInt("episodeIndex", 0)));
            long pos = o.has("position") ? o.optLong("position", 0L) : o.optLong("positionMs", 0L);
            long dur = o.has("duration") ? o.optLong("duration", 0L) : o.optLong("durationMs", 0L);
            e.position = (int) Math.max(0L, Math.min(Integer.MAX_VALUE, pos));
            e.duration = (int) Math.max(0L, Math.min(Integer.MAX_VALUE, dur));
            e.updated = Math.max(1L, o.optLong("updated", o.optLong("updatedAt", 1L)));
            out.add(e);
        }
        return out;
    }

    private static void parseRemoteFavorites(
            JSONArray arr, List<Favorites.Entry> out, Map<String, Long> addedAtMap) {
        for (int i = 0; i < arr.length(); i++) {
            JSONObject o = arr.optJSONObject(i);
            if (o == null) continue;
            String site = o.optString("site", o.optString("siteKey", "")).trim();
            String id = o.optString("id", o.optString("vodId", "")).trim();
            if (site.isEmpty() || id.isEmpty()) continue;
            Favorites.Entry f = new Favorites.Entry();
            f.site = site;
            f.id = id;
            f.title = o.optString("title", "").trim();
            f.poster = o.optString("poster", "");
            out.add(f);
            addedAtMap.put(f.key(), Math.max(1L, o.optLong("updated", o.optLong("addedAt", 1L))));
        }
    }

    private static boolean sameHistory(List<WatchHistory.Entry> a, List<WatchHistory.Entry> b) {
        if (a.size() != b.size()) return false;
        for (int i = 0; i < a.size(); i++) {
            WatchHistory.Entry x = a.get(i), y = b.get(i);
            if (!x.key().equals(y.key())
                    || x.position != y.position
                    || x.duration != y.duration
                    || x.updated != y.updated
                    || !String.valueOf(x.episode).equals(String.valueOf(y.episode))
                    || !String.valueOf(x.line).equals(String.valueOf(y.line))) {
                return false;
            }
        }
        return true;
    }

    private static boolean sameFavorites(List<Favorites.Entry> a, List<Favorites.Entry> b) {
        if (a.size() != b.size()) return false;
        for (int i = 0; i < a.size(); i++) {
            if (!a.get(i).key().equals(b.get(i).key())) return false;
        }
        return true;
    }

    /** Normalizes a WebDAV folder or file URL to the exact JSON sync file endpoint. */
    static String resolveWebdavFileUrl(String rawUrl) {
        if (rawUrl == null) throw new IllegalArgumentException("请填写 WebDAV 服务器地址");
        String trimmed = rawUrl.trim();
        if (trimmed.isEmpty()) throw new IllegalArgumentException("请填写 WebDAV 服务器地址");
        if (!trimmed.regionMatches(true, 0, "http://", 0, 7)
                && !trimmed.regionMatches(true, 0, "https://", 0, 8)) {
            trimmed = "https://" + trimmed;
        }
        trimmed = trimmed.replace(" ", "%20");
        URI uri = URI.create(trimmed);
        String scheme = uri.getScheme() == null ? "" : uri.getScheme().toLowerCase(Locale.ROOT);
        if (!"http".equals(scheme) && !"https".equals(scheme)) {
            throw new IllegalArgumentException("仅支持 HTTP 或 HTTPS WebDAV 地址");
        }
        String path =
                uri.getPath() == null
                        ? (uri.getRawPath() == null ? "" : uri.getRawPath())
                        : uri.getPath();
        if (path.toLowerCase(Locale.ROOT).endsWith(".json")) {
            return trimmed;
        }
        String host = uri.getHost() == null ? "" : uri.getHost().toLowerCase(Locale.ROOT);
        boolean isJianguoyun = isJianguoyunHost(host);
        String folderPrefix = "";
        if (isJianguoyun) {
            if (path.isEmpty() || "/".equals(path)) {
                folderPrefix = "dav/MarcoMovie/";
            } else if ("/dav".equals(path) || "/dav/".equals(path)) {
                folderPrefix = "MarcoMovie/";
            }
        }
        if (trimmed.endsWith("/")) {
            return trimmed + folderPrefix + DEFAULT_FILE;
        } else {
            return trimmed + "/" + folderPrefix + DEFAULT_FILE;
        }
    }

    static boolean isJianguoyunHost(String host) {
        if (host == null) return false;
        String h = host.toLowerCase(Locale.ROOT);
        return "jianguoyun.com".equals(h) || h.endsWith(".jianguoyun.com");
    }

    static boolean isWeakEtag(String etag) {
        if (etag == null) return false;
        String t = etag.trim();
        return t.startsWith("W/") || t.startsWith("w/");
    }

    static String extractHostKey(String rawOrFileUrl) {
        if (rawOrFileUrl == null) return "";
        String t = rawOrFileUrl.trim().replace(" ", "%20");
        if (t.isEmpty()) return "";
        if (!t.regionMatches(true, 0, "http://", 0, 7)
                && !t.regionMatches(true, 0, "https://", 0, 8)) {
            t = "https://" + t;
        }
        try {
            URI u = URI.create(t);
            String host = u.getHost();
            if (host == null || host.isEmpty()) return "";
            int port = u.getPort();
            return port > 0
                    ? host.toLowerCase(Locale.ROOT) + ":" + port
                    : host.toLowerCase(Locale.ROOT);
        } catch (Exception e) {
            AppLog.w("CloudSync", "Failed to extract WebDAV host key from URL", e);
            return "";
        }
    }

    static boolean isHostMarkedNoConditionalWrite(String rawOrFileUrl) {
        String key = extractHostKey(rawOrFileUrl);
        return !key.isEmpty() && NO_CONDITIONAL_WRITE_HOSTS.contains(key);
    }

    static void clearNoConditionalWriteHostsForTest() {
        NO_CONDITIONAL_WRITE_HOSTS.clear();
    }

    private static boolean isIfNoneMatchRejectedStatus(int code) {
        return code == 400
                || code == 405
                || code == 406
                || code == 417
                || code == 428
                || code == 500
                || code == 501;
    }

    /** Normalizes a LAN QR pairing URL or sync URL to the {@code /sync} JSON endpoint. */
    static String resolveLanSyncEndpoint(String rawInput) {
        if (rawInput == null) throw new IllegalArgumentException("请输入对方设备的局域网同步地址");
        String trimmed = rawInput.trim();
        if (trimmed.isEmpty()) throw new IllegalArgumentException("请输入对方设备的局域网同步地址");
        if (!trimmed.regionMatches(true, 0, "http://", 0, 7)
                && !trimmed.regionMatches(true, 0, "https://", 0, 8)) {
            trimmed = "http://" + trimmed;
        }
        trimmed = trimmed.replace(" ", "%20");
        while (trimmed.endsWith("/")) {
            trimmed = trimmed.substring(0, trimmed.length() - 1);
        }
        URI uri = URI.create(trimmed);
        String host = uri.getHost();
        if (host == null || host.isEmpty()) {
            throw new IllegalArgumentException("局域网同步地址缺少主机 IP");
        }
        if (trimmed.endsWith("/sync")) return trimmed;
        return trimmed + "/sync";
    }

    static String base64EncodeUtf8(String value) {
        byte[] data = value.getBytes(StandardCharsets.UTF_8);
        StringBuilder sb = new StringBuilder(((data.length + 2) / 3) * 4);
        int i = 0;
        while (i < data.length) {
            int b0 = data[i++] & 0xff;
            int b1 = i < data.length ? data[i++] & 0xff : -1;
            int b2 = i < data.length ? data[i++] & 0xff : -1;
            sb.append(BASE64_ALPHABET[b0 >>> 2]);
            if (b1 < 0) {
                sb.append(BASE64_ALPHABET[(b0 & 0x03) << 4]);
                sb.append("==");
            } else if (b2 < 0) {
                sb.append(BASE64_ALPHABET[((b0 & 0x03) << 4) | (b1 >>> 4)]);
                sb.append(BASE64_ALPHABET[(b1 & 0x0f) << 2]);
                sb.append('=');
            } else {
                sb.append(BASE64_ALPHABET[((b0 & 0x03) << 4) | (b1 >>> 4)]);
                sb.append(BASE64_ALPHABET[((b1 & 0x0f) << 2) | (b2 >>> 6)]);
                sb.append(BASE64_ALPHABET[b2 & 0x3f]);
            }
        }
        return sb.toString();
    }

    private static String basicAuthHeader(String user, String pass) {
        String u = user == null ? "" : user;
        String p = pass == null ? "" : pass;
        if (u.isEmpty() && p.isEmpty()) return null;
        return "Basic " + base64EncodeUtf8(u + ":" + p);
    }

    /** Executes a bidirectional WebDAV GET -> merge -> PUT sync cycle. */
    static MergeResult syncWebdav(
            String rawUrl, String username, String password, MergeCallback merger)
            throws Exception {
        String fileUrl = resolveWebdavFileUrl(rawUrl);
        String hostKey = extractHostKey(fileUrl);
        String auth = basicAuthHeader(username, password);

        int maxRetries = 2;
        int attempt = 0;
        boolean sawAbsent412 = false;
        java.util.Random rand = new java.util.Random();

        while (true) {
            String remoteJson = null;
            String etag = null;
            boolean fileAbsent = false;

            HttpURLConnection getConn = openConnection(fileUrl, "GET", auth, 12000);
            try {
                int code = getConn.getResponseCode();
                if (code >= 200 && code < 300) {
                    remoteJson = readBody(getConn.getInputStream(), MAX_SYNC_BYTES);
                    String h = getConn.getHeaderField("ETag");
                    if (h != null && !h.trim().isEmpty()) {
                        String trimmedEtag = h.trim();
                        if (!isWeakEtag(trimmedEtag)) {
                            etag = trimmedEtag;
                        }
                    }
                } else if (code == 401 || code == 403) {
                    drainConnectionStreams(getConn);
                    throw new IOException("WebDAV 认证失败 (HTTP " + code + ")，请检查账号或应用专用密码");
                } else if (code == 404) {
                    drainConnectionStreams(getConn);
                    fileAbsent = true;
                } else {
                    drainConnectionStreams(getConn);
                    throw new IOException("WebDAV 读取失败 (HTTP " + code + ")");
                }
            } finally {
                getConn.disconnect();
            }

            MergeResult merged = merger.merge(remoteJson);
            byte[] payloadBytes = merged.payloadJson.getBytes(StandardCharsets.UTF_8);
            if (payloadBytes.length > MAX_SYNC_BYTES) {
                throw new IOException("同步数据超出 8 MB 大小限制");
            }

            boolean skipCond = !hostKey.isEmpty() && NO_CONDITIONAL_WRITE_HOSTS.contains(hostKey);
            boolean absent412Fallback = fileAbsent && sawAbsent412;
            String condIfMatch =
                    (!skipCond && !fileAbsent && etag != null && !etag.isEmpty()) ? etag : null;
            boolean condIfNoneMatch = !skipCond && fileAbsent && !absent412Fallback;
            boolean usedConditional = (condIfMatch != null) || condIfNoneMatch;

            int putCode = putBytes(fileUrl, auth, payloadBytes, condIfMatch, condIfNoneMatch);
            if (putCode == 404 || putCode == 409) {
                ensureParentCollections(rawUrl, fileUrl, auth);
                putCode = putBytes(fileUrl, auth, payloadBytes, condIfMatch, condIfNoneMatch);
            }

            if (condIfNoneMatch && isIfNoneMatchRejectedStatus(putCode)) {
                int retryCode = putBytes(fileUrl, auth, payloadBytes, null, false);
                if (retryCode == 404 || retryCode == 409) {
                    ensureParentCollections(rawUrl, fileUrl, auth);
                    retryCode = putBytes(fileUrl, auth, payloadBytes, null, false);
                }
                if (retryCode >= 200 && retryCode < 300) {
                    if (!hostKey.isEmpty()) NO_CONDITIONAL_WRITE_HOSTS.add(hostKey);
                    return merged;
                }
                putCode = retryCode;
            }

            if (putCode == 412) {
                if (attempt < maxRetries && !(fileAbsent && sawAbsent412)) {
                    if (condIfNoneMatch) {
                        sawAbsent412 = true;
                    }
                    attempt++;
                    AppLog.w(
                            "CloudSync",
                            "WebDAV 412 Precondition Failed, retrying merge ("
                                    + attempt
                                    + "/"
                                    + maxRetries
                                    + ")",
                            null);
                    int jitterMs = 50 + rand.nextInt(100);
                    try {
                        Thread.sleep(jitterMs);
                    } catch (InterruptedException ie) {
                        Thread.currentThread().interrupt();
                        throw new IOException("WebDAV 412 重试等待中断", ie);
                    }
                    continue;
                }
                if (usedConditional) {
                    AppLog.w(
                            "CloudSync",
                            "WebDAV 412 retries exhausted; falling back to unconditional PUT",
                            null);
                    int fallbackCode = putBytes(fileUrl, auth, payloadBytes, null, false);
                    if (fallbackCode == 404 || fallbackCode == 409) {
                        ensureParentCollections(rawUrl, fileUrl, auth);
                        fallbackCode = putBytes(fileUrl, auth, payloadBytes, null, false);
                    }
                    if (fallbackCode >= 200 && fallbackCode < 300) {
                        if (!hostKey.isEmpty()) NO_CONDITIONAL_WRITE_HOSTS.add(hostKey);
                        return merged;
                    }
                    putCode = fallbackCode;
                }
            }

            if (putCode == 401 || putCode == 403) {
                throw new IOException("WebDAV 写入被拒绝 (HTTP " + putCode + ")，请检查读写权限");
            }
            if (putCode < 200 || putCode >= 300) {
                throw new IOException(formatWebdavWriteError(putCode));
            }
            if (absent412Fallback && !hostKey.isEmpty()) {
                NO_CONDITIONAL_WRITE_HOSTS.add(hostKey);
            }
            return merged;
        }
    }

    static String formatWebdavWriteError(int code) {
        if (code == 412) {
            return "WebDAV 写入冲突 (HTTP 412)：文件已被其他设备修改，重试后仍冲突";
        }
        if (code == 404 || code == 409) {
            return "WebDAV 写入失败 (HTTP "
                    + code
                    + ")：目标文件夹不存在或不可写。坚果云请在地址后加一个文件夹名，例如 https://dav.jianguoyun.com/dav/MarcoMovie/";
        }
        if (code == 405) {
            return "WebDAV 写入失败 (HTTP 405)：服务器不允许写入";
        }
        if (code == 423) {
            return "WebDAV 写入失败 (HTTP 423)：文件被锁定";
        }
        if (code == 507) {
            return "WebDAV 写入失败 (HTTP 507)：空间不足";
        }
        return "WebDAV 写入失败 (HTTP " + code + ")";
    }

    /**
     * Executes a bidirectional sync against another Marco Movie device's LAN receiver ({@code POST
     * /configure/<token>/sync}).
     */
    static MergeResult syncLanPeer(String peerUrlOrHost, LanPeerCallback callback)
            throws Exception {
        String endpoint = resolveLanSyncEndpoint(peerUrlOrHost);
        String localJson = callback.exportLocalPayload();
        byte[] outBytes = localJson.getBytes(StandardCharsets.UTF_8);
        if (outBytes.length > MAX_SYNC_BYTES) {
            throw new IOException("本地同步数据超出 8 MB 大小限制");
        }

        HttpURLConnection postConn = openConnection(endpoint, "POST", null, 12000);
        String responseJson;
        try {
            postConn.setDoOutput(true);
            postConn.setFixedLengthStreamingMode(outBytes.length);
            postConn.setRequestProperty("Content-Type", "application/json; charset=utf-8");
            try (OutputStream out = postConn.getOutputStream()) {
                out.write(outBytes);
            }
            int code = postConn.getResponseCode();
            if (code == 410) {
                drainConnectionStreams(postConn);
                throw new IOException("对方设备的局域网同步会话已过期，请重新打开二维码");
            }
            if (code < 200 || code >= 300) {
                drainConnectionStreams(postConn);
                throw new IOException("局域网同步未成功 (HTTP " + code + ")");
            }
            responseJson = readBody(postConn.getInputStream(), MAX_SYNC_BYTES);
        } finally {
            postConn.disconnect();
        }
        return callback.applyMergedPayload(responseJson);
    }

    private static int putBytes(String fileUrl, String auth, byte[] payloadBytes)
            throws IOException {
        return putBytes(fileUrl, auth, payloadBytes, null, false);
    }

    private static int putBytes(
            String fileUrl,
            String auth,
            byte[] payloadBytes,
            String ifMatch,
            boolean ifNoneMatchStar)
            throws IOException {
        HttpURLConnection conn = openConnection(fileUrl, "PUT", auth, 15000);
        try {
            conn.setDoOutput(true);
            conn.setFixedLengthStreamingMode(payloadBytes.length);
            conn.setRequestProperty("Content-Type", "application/json; charset=utf-8");
            if (ifNoneMatchStar) {
                conn.setRequestProperty("If-None-Match", "*");
            } else if (ifMatch != null && !ifMatch.isEmpty()) {
                conn.setRequestProperty("If-Match", ifMatch);
            }
            try (OutputStream out = conn.getOutputStream()) {
                out.write(payloadBytes);
            }
            int code = conn.getResponseCode();
            drainConnectionStreams(conn);
            return code;
        } finally {
            conn.disconnect();
        }
    }

    static int baseCollectionDepth(String rawBaseUrl, URI fileUri) {
        if (fileUri == null) return 0;
        List<String> parentSegs = extractParentSegments(fileUri);
        if (parentSegs.isEmpty()) return 0;

        String host = fileUri.getHost() == null ? "" : fileUri.getHost().toLowerCase(Locale.ROOT);
        if (isJianguoyunHost(host) && "dav".equalsIgnoreCase(parentSegs.get(0))) {
            int skip = 1;
            List<String> baseSegs = extractDirectorySegmentsFromRawBase(rawBaseUrl);
            if (!baseSegs.isEmpty()
                    && baseSegs.size() < parentSegs.size()
                    && isSegmentPrefix(baseSegs, parentSegs)) {
                skip = Math.max(skip, baseSegs.size());
            }
            return skip;
        }
        if (parentSegs.size() >= 4
                && "remote.php".equalsIgnoreCase(parentSegs.get(0))
                && "dav".equalsIgnoreCase(parentSegs.get(1))
                && "files".equalsIgnoreCase(parentSegs.get(2))) {
            int skip = 4;
            List<String> baseSegs = extractDirectorySegmentsFromRawBase(rawBaseUrl);
            if (!baseSegs.isEmpty()
                    && baseSegs.size() < parentSegs.size()
                    && isSegmentPrefix(baseSegs, parentSegs)) {
                skip = Math.max(skip, baseSegs.size());
            }
            return skip;
        }
        if (parentSegs.size() >= 2
                && "remote.php".equalsIgnoreCase(parentSegs.get(0))
                && "webdav".equalsIgnoreCase(parentSegs.get(1))) {
            int skip = 2;
            List<String> baseSegs = extractDirectorySegmentsFromRawBase(rawBaseUrl);
            if (!baseSegs.isEmpty()
                    && baseSegs.size() < parentSegs.size()
                    && isSegmentPrefix(baseSegs, parentSegs)) {
                skip = Math.max(skip, baseSegs.size());
            }
            return skip;
        }

        List<String> baseSegs = extractDirectorySegmentsFromRawBase(rawBaseUrl);
        if (!baseSegs.isEmpty()
                && baseSegs.size() < parentSegs.size()
                && isSegmentPrefix(baseSegs, parentSegs)) {
            return baseSegs.size();
        }
        return 0;
    }

    private static List<String> extractParentSegments(URI fileUri) {
        List<String> out = new ArrayList<>();
        String rawPath = fileUri.getRawPath();
        if (rawPath == null || rawPath.isEmpty()) return out;
        int lastSlash = rawPath.lastIndexOf('/');
        if (lastSlash <= 0) return out;
        String parentPath = rawPath.substring(0, lastSlash + 1);
        for (String part : parentPath.split("/")) {
            if (part != null && !part.isEmpty()) {
                out.add(part);
            }
        }
        return out;
    }

    private static List<String> extractDirectorySegmentsFromRawBase(String rawBaseUrl) {
        List<String> out = new ArrayList<>();
        if (rawBaseUrl == null) return out;
        String t = rawBaseUrl.trim();
        if (t.isEmpty()) return out;
        if (!t.regionMatches(true, 0, "http://", 0, 7)
                && !t.regionMatches(true, 0, "https://", 0, 8)) {
            t = "https://" + t;
        }
        t = t.replace(" ", "%20");
        try {
            URI u = URI.create(URI.create(t).toASCIIString());
            String rawPath = u.getRawPath();
            if (rawPath == null || rawPath.isEmpty()) return out;
            if (rawPath.toLowerCase(Locale.ROOT).endsWith(".json")) return out;
            for (String part : rawPath.split("/")) {
                if (part != null && !part.isEmpty()) {
                    out.add(part);
                }
            }
        } catch (Exception e) {
            AppLog.w("CloudSync", "Failed to parse base URL segments", e);
        }
        return out;
    }

    private static boolean isSegmentPrefix(List<String> prefix, List<String> full) {
        if (prefix.size() > full.size()) return false;
        for (int i = 0; i < prefix.size(); i++) {
            if (!prefix.get(i).equalsIgnoreCase(full.get(i))) {
                return false;
            }
        }
        return true;
    }

    /**
     * Creates missing ancestor WebDAV collections below the base address sequentially via {@code
     * MKCOL} using a shared {@link OkHttpClient}, because standard {@link
     * HttpURLConnection#setRequestMethod(String)} rejects {@code MKCOL}.
     */
    static void ensureParentCollections(String rawBaseUrl, String fileUrl, String auth) {
        try {
            URI rawUri = URI.create(fileUrl.replace(" ", "%20"));
            URI uri = URI.create(rawUri.toASCIIString());
            List<String> parts = extractParentSegments(uri);
            if (parts.isEmpty()) return;
            int skipSegments = baseCollectionDepth(rawBaseUrl, uri);
            StringBuilder current = new StringBuilder("/");
            String authority = uri.getRawAuthority();
            String scheme = uri.getScheme() == null ? "https" : uri.getScheme();
            String base = scheme + "://" + authority;

            for (int i = 0; i < parts.size(); i++) {
                String part = parts.get(i);
                current.append(part).append('/');
                if (i < skipSegments) {
                    continue;
                }
                String collUrl = base + current.toString();
                Request.Builder reqBuilder =
                        new Request.Builder()
                                .url(collUrl)
                                .method("MKCOL", null)
                                .header("User-Agent", "MarcoMovie-Sync/2.0");
                if (auth != null && !auth.isEmpty()) {
                    reqBuilder.header("Authorization", auth);
                }
                try (Response resp = MKCOL_CLIENT.newCall(reqBuilder.build()).execute()) {
                    ResponseBody body = resp.body();
                    if (body != null) {
                        drainStreamQuietly(body.byteStream());
                    }
                    int code = resp.code();
                    if (code == 401) {
                        AppLog.w("CloudSync", "WebDAV 认证失败 (HTTP 401) for " + collUrl, null);
                        break;
                    }
                } catch (Exception e) {
                    AppLog.w("CloudSync", "MKCOL 请求失败 for " + collUrl, e);
                }
            }
        } catch (Exception e) {
            AppLog.w("CloudSync", "递归创建 WebDAV 父目录失败: " + fileUrl, e);
        }
    }

    private static void drainConnectionStreams(HttpURLConnection conn) {
        if (conn == null) return;
        try {
            InputStream in = conn.getInputStream();
            if (in != null) drainStreamQuietly(in);
        } catch (IOException ioErr) {
            InputStream err = conn.getErrorStream();
            if (err != null) drainStreamQuietly(err);
        }
    }

    private static void drainStreamQuietly(InputStream in) {
        if (in == null) return;
        try (InputStream src = in) {
            byte[] buf = new byte[1024];
            while (src.read(buf) != -1) {
                // Drain remaining response bytes so pooled connections stay reusable.
            }
        } catch (IOException e) {
            AppLog.w("CloudSync", "Draining HTTP response stream ended early", e);
        }
    }

    private static HttpURLConnection openConnection(
            String targetUrl, String method, String auth, int timeoutMs) throws IOException {
        HttpURLConnection conn = (HttpURLConnection) new URL(targetUrl).openConnection();
        conn.setInstanceFollowRedirects(false);
        conn.setConnectTimeout(timeoutMs);
        conn.setReadTimeout(timeoutMs);
        conn.setUseCaches(false);
        conn.setRequestMethod(method);
        conn.setRequestProperty("User-Agent", "MarcoMovie-Sync/2.0");
        conn.setRequestProperty("Accept", "application/json");
        if (auth != null && !auth.isEmpty()) {
            conn.setRequestProperty("Authorization", auth);
        }
        return conn;
    }

    private static String readBody(InputStream in, int maxBytes) throws IOException {
        if (in == null) return "";
        try (InputStream src = in;
                ByteArrayOutputStream bos = new ByteArrayOutputStream()) {
            byte[] buf = new byte[8192];
            int n;
            while ((n = src.read(buf)) != -1) {
                if (bos.size() + n > maxBytes) {
                    throw new IOException("远端同步文件超出大小限制");
                }
                bos.write(buf, 0, n);
            }
            return new String(bos.toByteArray(), StandardCharsets.UTF_8);
        }
    }
}
