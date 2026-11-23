package com.pilipala.marcomovie;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;
import org.json.JSONArray;
import org.json.JSONObject;

/**
 * Fetches and caches recent trending Chinese & global movie/TV titles from Douban public
 * collections so initials/pinyin search immediately suggests up-to-date selectable Chinese titles.
 */
final class HotTitleCatalog {
    private static final long CACHE_TTL_MS = 12L * 60L * 60L * 1000L;
    private static final String CACHE_FILE = "hot_titles_v1.json";
    private static final String[] COLLECTIONS = {
        "tv_hot",
        "movie_hot_gaia",
        "movie_showing",
        "tv_domestic",
        "tv_american",
        "tv_animation",
        "show_hot"
    };

    private static volatile List<String> memoryCache = Collections.emptyList();
    private static volatile long lastLoadedMs = 0L;
    private static volatile boolean fetchInFlight = false;

    private HotTitleCatalog() {}

    static List<String> cachedTitles() {
        return memoryCache;
    }

    static List<String> parseDoubanCollectionJson(String json) {
        List<String> out = new ArrayList<>();
        if (json == null || !json.trim().startsWith("{")) return out;
        try {
            JSONObject root = new JSONObject(json);
            JSONArray items = root.optJSONArray("subject_collection_items");
            if (items == null) items = root.optJSONArray("items");
            if (items == null) return out;
            Set<String> seen = new LinkedHashSet<>();
            for (int i = 0; i < items.length(); i++) {
                JSONObject item = items.optJSONObject(i);
                if (item == null) continue;
                String title = cleanHotTitle(item.optString("title", ""));
                if (!title.isEmpty() && seen.add(title)) {
                    out.add(title);
                }
            }
        } catch (Exception ignored) {
        }
        return out;
    }

    static String cleanHotTitle(String raw) {
        if (raw == null) return "";
        String t = raw.trim().replaceAll("\\s+", " ");
        if (t.length() < 2 || t.length() > 40) return "";
        return t;
    }

    /**
     * Populates the public-space phonetic index with cached and/or freshly fetched recent trending
     * movie and TV titles. Strictly no-op in private mode.
     */
    static void ensureLoadedAsync(final MainActivity a, final Runnable onUpdatedUi) {
        if (a == null || a.privateMode || a.isFinishing()) return;
        final long now = System.currentTimeMillis();
        if (!memoryCache.isEmpty() && (now - lastLoadedMs) < CACHE_TTL_MS) {
            applyToIndex(a, memoryCache, onUpdatedUi);
            return;
        }
        if (fetchInFlight) return;
        fetchInFlight = true;
        final File cacheFile = new File(a.getCacheDir(), CACHE_FILE);
        try {
            a.worker.execute(
                    () -> {
                        try {
                            // 1. Fast disk cache warm-up if fresh
                            List<String> disk = readDiskCache(cacheFile, now);
                            if (!disk.isEmpty()) {
                                memoryCache = Collections.unmodifiableList(disk);
                                lastLoadedMs = now;
                                applyToIndex(a, memoryCache, onUpdatedUi);
                                return;
                            }
                            // 2. Fetch live recent trending collections from Douban Rexxar
                            Set<String> merged = new LinkedHashSet<>();
                            for (String col : COLLECTIONS) {
                                String url =
                                        "https://m.douban.com/rexxar/api/v2/subject_collection/"
                                                + col
                                                + "/items?start=0&count=50";
                                String body = httpGet(url, "https://m.douban.com/movie/");
                                for (String t : parseDoubanCollectionJson(body)) {
                                    merged.add(t);
                                }
                                if (merged.size() >= 320) break;
                            }
                            if (!merged.isEmpty()) {
                                List<String> fresh = new ArrayList<>(merged);
                                memoryCache = Collections.unmodifiableList(fresh);
                                lastLoadedMs = System.currentTimeMillis();
                                writeDiskCache(cacheFile, fresh, lastLoadedMs);
                                applyToIndex(a, memoryCache, onUpdatedUi);
                            }
                        } catch (Exception ignored) {
                        } finally {
                            fetchInFlight = false;
                        }
                    });
        } catch (java.util.concurrent.RejectedExecutionException ignored) {
            fetchInFlight = false;
        }
    }

    private static void applyToIndex(MainActivity a, List<String> titles, Runnable onUpdatedUi) {
        if (a == null || a.privateMode || titles == null || titles.isEmpty()) return;
        try {
            a.phoneticWork.execute(
                    () -> {
                        try {
                            if (a.phonetic == null) {
                                a.phoneticReady.await(6, java.util.concurrent.TimeUnit.SECONDS);
                            }
                            PhoneticSearchIndex idx = a.phonetic;
                            if (idx != null && !a.privateMode) {
                                idx.learnHotTitles(titles);
                                if (onUpdatedUi != null) {
                                    a.ui.post(
                                            () -> {
                                                if (!a.isFinishing() && !a.privateMode) {
                                                    onUpdatedUi.run();
                                                }
                                            });
                                }
                            }
                        } catch (Exception ignored) {
                        }
                    });
        } catch (java.util.concurrent.RejectedExecutionException ignored) {
        }
    }

    private static List<String> readDiskCache(File file, long now) {
        List<String> out = new ArrayList<>();
        if (file == null || !file.exists() || file.length() > 512 * 1024) return out;
        try (InputStream in = new FileInputStream(file);
                ByteArrayOutputStream bos = new ByteArrayOutputStream()) {
            byte[] buf = new byte[4096];
            int n;
            while ((n = in.read(buf)) != -1) bos.write(buf, 0, n);
            JSONObject obj = new JSONObject(new String(bos.toByteArray(), StandardCharsets.UTF_8));
            long savedAt = obj.optLong("savedAt", 0L);
            if (savedAt <= 0L || (now - savedAt) >= CACHE_TTL_MS) return out;
            JSONArray arr = obj.optJSONArray("titles");
            if (arr == null) return out;
            for (int i = 0; i < arr.length(); i++) {
                String t = cleanHotTitle(arr.optString(i, ""));
                if (!t.isEmpty()) out.add(t);
            }
        } catch (Exception ignored) {
        }
        return out;
    }

    private static void writeDiskCache(File file, List<String> titles, long savedAt) {
        if (file == null || titles == null || titles.isEmpty()) return;
        try {
            JSONObject obj = new JSONObject();
            obj.put("savedAt", savedAt);
            JSONArray arr = new JSONArray();
            for (String t : titles) arr.put(t);
            obj.put("titles", arr);
            try (FileOutputStream fos = new FileOutputStream(file)) {
                fos.write(obj.toString().getBytes(StandardCharsets.UTF_8));
            }
        } catch (Exception ignored) {
        }
    }

    private static String httpGet(String urlStr, String referer) {
        HttpURLConnection conn = null;
        try {
            conn = (HttpURLConnection) new URL(urlStr).openConnection();
            conn.setConnectTimeout(3500);
            conn.setReadTimeout(3500);
            conn.setInstanceFollowRedirects(true);
            conn.setRequestProperty(
                    "User-Agent",
                    "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 MicroMessenger/8.0.40");
            conn.setRequestProperty("Accept", "application/json, */*");
            conn.setRequestProperty("Accept-Language", "zh-CN,zh;q=0.9");
            if (referer != null && !referer.isEmpty()) {
                conn.setRequestProperty("Referer", referer);
            }
            if (conn.getResponseCode() < 200 || conn.getResponseCode() >= 300) return null;
            try (InputStream in = conn.getInputStream();
                    ByteArrayOutputStream out = new ByteArrayOutputStream()) {
                byte[] buf = new byte[8192];
                int n;
                while ((n = in.read(buf)) != -1) {
                    if (out.size() + n > 1024 * 1024) break;
                    out.write(buf, 0, n);
                }
                return new String(out.toByteArray(), StandardCharsets.UTF_8);
            }
        } catch (Exception ignored) {
            return null;
        } finally {
            if (conn != null) conn.disconnect();
        }
    }
}
