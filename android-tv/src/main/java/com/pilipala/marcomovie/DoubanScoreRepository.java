// Copyright (C) 2026 Pilipala
// SPDX-License-Identifier: GPL-3.0-only
package com.pilipala.marcomovie;

import android.content.Context;
import android.view.View;
import android.widget.TextView;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.lang.ref.WeakReference;
import java.net.HttpURLConnection;
import java.net.URL;
import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.LinkedBlockingQueue;
import java.util.concurrent.ThreadPoolExecutor;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import org.json.JSONArray;
import org.json.JSONObject;

/**
 * Lightweight, throttled, persistent Douban rating cache & resolver dedicated to poster card grids
 * (Home, Library "片库", and Search "搜索"). Avoids Rotten Tomatoes scraping and protects detail-page
 * rating pools while ensuring every eligible show/movie card displays a crisp Douban rating badge.
 */
final class DoubanScoreRepository {
    private static final String CACHE_FILE = "douban-card-scores-v1.json";
    private static final int MAX_CACHE_ENTRIES = 1600;
    private static final long HIT_TTL_MS = 14L * 24 * 3600 * 1000L;
    private static final long MISS_TTL_MS = 48L * 3600 * 1000L;
    private static final int MAX_PENDING_TASKS = 48;
    private static final int TAG_LOOKUP_KEY = 0x5f444253; // "DBS"

    private static final Pattern YEAR_PATTERN = Pattern.compile("(19[4-9]\\d|20[0-3]\\d)");
    private static final Pattern NUMERIC_ID_PATTERN = Pattern.compile("^\\d{5,12}$");
    private static final Pattern INLINE_SCORE_PATTERN =
            Pattern.compile("(?:豆瓣(?:评分)?|评分|Douban)\\s*[:：]?\\s*([2-9]\\.\\d)");

    static final class CacheEntry {
        final double score; // 0.0 means negative miss
        final long updatedAtMs;

        CacheEntry(double score, long updatedAtMs) {
            this.score = score;
            this.updatedAtMs = updatedAtMs;
        }

        boolean isExpired(long nowMs) {
            long ttl = score >= 2.0 ? HIT_TTL_MS : MISS_TTL_MS;
            return (nowMs - updatedAtMs) > ttl;
        }
    }

    private static final Object CACHE_LOCK = new Object();
    private static final LinkedHashMap<String, CacheEntry> CACHE =
            new LinkedHashMap<String, CacheEntry>(256, 0.75f, true) {
                @Override
                protected boolean removeEldestEntry(Map.Entry<String, CacheEntry> eldest) {
                    return size() > MAX_CACHE_ENTRIES;
                }
            };
    private static final AtomicBoolean DISK_LOAD_STARTED = new AtomicBoolean(false);
    private static volatile long lastDiskSaveMs;
    private static final AtomicBoolean DISK_SAVE_SCHEDULED = new AtomicBoolean(false);
    private static final ConcurrentHashMap<String, CopyOnWriteArrayList<WeakReference<TextView>>>
            INFLIGHT = new ConcurrentHashMap<>();

    private static final class FetchTask implements Runnable {
        final String key;
        final Runnable body;

        FetchTask(String key, Runnable body) {
            this.key = key;
            this.body = body;
        }

        @Override
        public void run() {
            body.run();
        }
    }

    private static final ExecutorService DISK_IO_POOL =
            new ThreadPoolExecutor(
                    1,
                    1,
                    30L,
                    TimeUnit.SECONDS,
                    new LinkedBlockingQueue<Runnable>(8),
                    r -> {
                        Thread t = new Thread(r, "douban-card-disk");
                        t.setDaemon(true);
                        return t;
                    },
                    (r, exec) -> DISK_SAVE_SCHEDULED.set(false));

    private static final ExecutorService FETCH_POOL =
            new ThreadPoolExecutor(
                    2,
                    2,
                    30L,
                    TimeUnit.SECONDS,
                    new LinkedBlockingQueue<Runnable>(MAX_PENDING_TASKS),
                    r -> {
                        Thread t = new Thread(r, "douban-card-score");
                        t.setDaemon(true);
                        return t;
                    },
                    (r, executor) -> {
                        if (executor.isShutdown()) {
                            if (r instanceof FetchTask) INFLIGHT.remove(((FetchTask) r).key);
                            return;
                        }
                        Runnable dropped = executor.getQueue().poll();
                        if (dropped instanceof FetchTask) {
                            INFLIGHT.remove(((FetchTask) dropped).key);
                        }
                        if (!executor.getQueue().offer(r) && r instanceof FetchTask) {
                            INFLIGHT.remove(((FetchTask) r).key);
                        }
                    });

    private DoubanScoreRepository() {}

    static String normalizeLookupKey(String rawTitle, String rawYear) {
        String clean = TvSeriesScraper.cleanWorkTitle(rawTitle == null ? "" : rawTitle);
        String core = TvSeriesScraper.normalizeCoreKey(clean);
        if (core.isEmpty()) return "";
        String year = extractYear(rawYear);
        if (year.isEmpty()) year = extractYear(rawTitle);
        return year.isEmpty() ? core : (core + "#" + year);
    }

    static String extractYear(String raw) {
        if (raw == null || raw.isEmpty()) return "";
        Matcher m = YEAR_PATTERN.matcher(raw);
        return m.find() ? m.group(1) : "";
    }

    static double extractImmediateScore(Cms.Video v) {
        if (v == null) return 0.0;
        double direct = Cms.parseValidDoubanScore(v.doubanScore);
        if (direct >= 2.0) return direct;
        String blob =
                (v.remarks == null ? "" : v.remarks)
                        + " "
                        + (v.description == null ? "" : v.description);
        Matcher m = INLINE_SCORE_PATTERN.matcher(blob);
        if (m.find()) {
            double parsed = Cms.parseValidDoubanScore(m.group(1));
            if (parsed >= 2.0) return parsed;
        }
        return 0.0;
    }

    static String formatBadgeText(double score) {
        if (score < 2.0 || score > 9.9) return "";
        return String.format(Locale.US, "豆 %.1f", score);
    }

    static void seedScore(Context context, String rawTitle, String rawYear, double score) {
        if (score < 2.0 || score > 9.9) return;
        String key = normalizeLookupKey(rawTitle, rawYear);
        if (key.isEmpty()) return;
        ensureDiskLoadedAsync(context);
        long now = System.currentTimeMillis();
        synchronized (CACHE_LOCK) {
            CACHE.put(key, new CacheEntry(score, now));
            String bareKey = key.contains("#") ? key.substring(0, key.indexOf('#')) : "";
            if (!bareKey.isEmpty() && !CACHE.containsKey(bareKey)) {
                CACHE.put(bareKey, new CacheEntry(score, now));
            }
        }
        scheduleDiskSave(context);
    }

    static CacheEntry getCached(Context context, String key) {
        if (key == null || key.isEmpty()) return null;
        ensureDiskLoadedAsync(context);
        long now = System.currentTimeMillis();
        synchronized (CACHE_LOCK) {
            CacheEntry hit = CACHE.get(key);
            if (hit != null && !hit.isExpired(now)) return hit;
            int hash = key.indexOf('#');
            if (hash > 0) {
                CacheEntry bare = CACHE.get(key.substring(0, hash));
                if (bare != null && bare.score >= 2.0 && !bare.isExpired(now)) return bare;
            }
        }
        return null;
    }

    /**
     * Binds a poster card's Douban badge {@link TextView} to a {@link Cms.Video}. Displays known or
     * cached scores synchronously in 0ms; otherwise queues a throttled background Douban lookup and
     * populates the badge safely if the card is still attached and bound to the same video.
     */
    static void bindBadge(final MainActivity a, final TextView badge, final Cms.Video video) {
        if (a == null || badge == null || video == null) return;
        if (video.title == null || video.title.trim().isEmpty()) {
            badge.setVisibility(View.GONE);
            return;
        }
        final String key = normalizeLookupKey(video.title, video.year);
        if (key.isEmpty()) {
            badge.setVisibility(View.GONE);
            return;
        }
        badge.setTag(TAG_LOOKUP_KEY, key);

        // 1. Immediate score from CMS payload / remarks / ImmersivePoster memory cache
        double immediate = extractImmediateScore(video);
        if (immediate < 2.0) {
            ImmersivePoster.Ratings ir = ImmersivePoster.extractImmediateRatings(video);
            if (ir != null && ir.douban >= 2.0) immediate = ir.douban;
        }
        if (immediate >= 2.0) {
            String formatted = formatBadgeText(immediate);
            badge.setText(formatted);
            badge.setVisibility(View.VISIBLE);
            if (video.doubanScore == null || video.doubanScore.isEmpty()) {
                video.doubanScore = String.format(Locale.US, "%.1f", immediate);
            }
            seedScore(a, video.title, video.year, immediate);
            return;
        }

        // 2. Check our persistent disk/memory card cache
        CacheEntry cached = getCached(a, key);
        if (cached != null) {
            if (cached.score >= 2.0) {
                badge.setText(formatBadgeText(cached.score));
                badge.setVisibility(View.VISIBLE);
                video.doubanScore = String.format(Locale.US, "%.1f", cached.score);
            } else {
                badge.setVisibility(View.GONE);
            }
            return;
        }

        // 3. Throttled single-flight async lookup
        badge.setVisibility(View.GONE);
        final Context appCtx = a.getApplicationContext();
        final String cleanTitle = TvSeriesScraper.cleanWorkTitle(video.title);
        final String year = extractYear(video.year);
        final String doubanId = video.doubanId == null ? "" : video.doubanId.trim();

        CopyOnWriteArrayList<WeakReference<TextView>> waiters = INFLIGHT.get(key);
        if (waiters != null) {
            waiters.add(new WeakReference<>(badge));
            return;
        }
        final CopyOnWriteArrayList<WeakReference<TextView>> created = new CopyOnWriteArrayList<>();
        created.add(new WeakReference<>(badge));
        CopyOnWriteArrayList<WeakReference<TextView>> existing = INFLIGHT.putIfAbsent(key, created);
        if (existing != null) {
            existing.add(new WeakReference<>(badge));
            return;
        }

        FETCH_POOL.execute(
                new FetchTask(
                        key,
                        () -> {
                            double resolved = 0.0;
                            try {
                                resolved = fetchRemoteDoubanScore(cleanTitle, year, doubanId);
                            } catch (Throwable ignored) {
                            } finally {
                                long now = System.currentTimeMillis();
                                synchronized (CACHE_LOCK) {
                                    CACHE.put(key, new CacheEntry(resolved, now));
                                    if (resolved >= 2.0) {
                                        int hash = key.indexOf('#');
                                        if (hash > 0) {
                                            CACHE.put(
                                                    key.substring(0, hash),
                                                    new CacheEntry(resolved, now));
                                        }
                                    }
                                }
                                scheduleDiskSave(appCtx);
                                final double finalScore = resolved;
                                final CopyOnWriteArrayList<WeakReference<TextView>> targets =
                                        INFLIGHT.remove(key);
                                if (finalScore >= 2.0) {
                                    video.doubanScore =
                                            String.format(Locale.US, "%.1f", finalScore);
                                }
                                if (finalScore >= 2.0 && targets != null && !targets.isEmpty()) {
                                    final String label = formatBadgeText(finalScore);
                                    a.ui.post(
                                            () -> {
                                                if (a.isFinishing()) return;
                                                for (WeakReference<TextView> ref : targets) {
                                                    TextView tv = ref.get();
                                                    if (tv == null || !tv.isAttachedToWindow())
                                                        continue;
                                                    if (!key.equals(tv.getTag(TAG_LOOKUP_KEY)))
                                                        continue;
                                                    tv.setText(label);
                                                    if (tv.getVisibility() != View.VISIBLE) {
                                                        tv.setAlpha(0f);
                                                        tv.setVisibility(View.VISIBLE);
                                                        tv.animate()
                                                                .alpha(1f)
                                                                .setDuration(150)
                                                                .start();
                                                    }
                                                }
                                            });
                                }
                            }
                        }));
    }

    private static double fetchRemoteDoubanScore(String cleanTitle, String year, String doubanId) {
        if (doubanId != null && NUMERIC_ID_PATTERN.matcher(doubanId).matches()) {
            double byId = fetchScoreBySubjectId(doubanId);
            if (byId >= 2.0) return byId;
        }
        if (cleanTitle == null || cleanTitle.trim().isEmpty()) return 0.0;
        String targetCore = TvSeriesScraper.normalizeCoreKey(cleanTitle);
        if (targetCore.isEmpty()) return 0.0;

        // Fast path: Douban Rexxar search JSON (returns rating.value directly in 1 round-trip!)
        try {
            String query = year != null && !year.isEmpty() ? (cleanTitle + " " + year) : cleanTitle;
            String url =
                    "https://m.douban.com/rexxar/api/v2/search/weixin?q="
                            + URLEncoder.encode(query, "UTF-8")
                            + "&start=0&count=6";
            String body = httpGet(url, "https://m.douban.com/search/");
            double best = parseRexxarSearchBestScore(body, targetCore, year);
            if (best >= 2.0) return best;
        } catch (Exception ignored) {
        }

        // Secondary fallback: subject_suggest -> single subject rating fetch
        try {
            String url =
                    "https://movie.douban.com/j/subject_suggest?q="
                            + URLEncoder.encode(cleanTitle, "UTF-8");
            String body = httpGet(url, "https://movie.douban.com/");
            if (body != null && body.trim().startsWith("[")) {
                JSONArray arr = new JSONArray(body);
                String matchedId = "";
                for (int i = 0; i < Math.min(arr.length(), 6); i++) {
                    JSONObject o = arr.optJSONObject(i);
                    if (o == null) continue;
                    String title = o.optString("title", "");
                    String subId = o.optString("id", "").trim();
                    String itemYear = extractYear(o.optString("year", ""));
                    if (subId.isEmpty() || !NUMERIC_ID_PATTERN.matcher(subId).matches()) continue;
                    String candCore = TvSeriesScraper.normalizeCoreKey(title);
                    if (candCore.equals(targetCore)
                            || (candCore.length() >= 2
                                    && (candCore.contains(targetCore)
                                            || targetCore.contains(candCore)))) {
                        if (year == null
                                || year.isEmpty()
                                || itemYear.isEmpty()
                                || year.equals(itemYear)) {
                            matchedId = subId;
                            break;
                        }
                        if (matchedId.isEmpty()) matchedId = subId;
                    }
                }
                if (!matchedId.isEmpty()) {
                    return fetchScoreBySubjectId(matchedId);
                }
            }
        } catch (Exception ignored) {
        }
        return 0.0;
    }

    static double parseRexxarSearchBestScore(String jsonBody, String targetCore, String year) {
        if (jsonBody == null
                || jsonBody.trim().isEmpty()
                || targetCore == null
                || targetCore.isEmpty()) {
            return 0.0;
        }
        try {
            JSONObject root = new JSONObject(jsonBody);
            JSONObject subjects = root.optJSONObject("subjects");
            JSONArray items =
                    subjects != null ? subjects.optJSONArray("items") : root.optJSONArray("items");
            if (items == null) return 0.0;
            double bestScore = 0.0;
            int bestRank = -1;
            for (int i = 0; i < items.length(); i++) {
                JSONObject entry = items.optJSONObject(i);
                if (entry == null) continue;
                JSONObject target = entry.optJSONObject("target");
                if (target == null) target = entry;
                String title = target.optString("title", "");
                JSONObject rating = target.optJSONObject("rating");
                double val = rating != null ? rating.optDouble("value", 0.0) : 0.0;
                if (val < 2.0 || val > 9.9) continue;
                String candCore = TvSeriesScraper.normalizeCoreKey(title);
                if (candCore.isEmpty()) continue;
                int rank = 0;
                if (candCore.equals(targetCore)) {
                    rank = 100;
                } else if (candCore.contains(targetCore) || targetCore.contains(candCore)) {
                    rank = 60 - Math.min(30, Math.abs(candCore.length() - targetCore.length()) * 4);
                } else {
                    continue;
                }
                String candYear =
                        extractYear(
                                target.optString("year", target.optString("card_subtitle", "")));
                if (year != null && !year.isEmpty() && !candYear.isEmpty()) {
                    if (year.equals(candYear)) rank += 25;
                    else rank -= 20;
                }
                if (rank > bestRank) {
                    bestRank = rank;
                    bestScore = val;
                }
            }
            return bestRank >= 40 ? bestScore : 0.0;
        } catch (Exception ignored) {
            return 0.0;
        }
    }

    private static double fetchScoreBySubjectId(String subjectId) {
        for (String kind : new String[] {"movie", "tv"}) {
            try {
                String url = "https://m.douban.com/rexxar/api/v2/" + kind + "/" + subjectId;
                String body = httpGet(url, "https://m.douban.com/movie/subject/" + subjectId + "/");
                if (body == null || body.trim().isEmpty()) continue;
                JSONObject obj = new JSONObject(body);
                JSONObject rating = obj.optJSONObject("rating");
                if (rating != null) {
                    double v = rating.optDouble("value", 0.0);
                    if (v >= 2.0 && v <= 9.9) return v;
                }
            } catch (Exception ignored) {
            }
        }
        return 0.0;
    }

    private static String httpGet(String urlStr, String referer) throws Exception {
        HttpURLConnection conn = (HttpURLConnection) new URL(urlStr).openConnection();
        conn.setConnectTimeout(4500);
        conn.setReadTimeout(5000);
        conn.setInstanceFollowRedirects(true);
        conn.setRequestProperty(
                "User-Agent",
                "Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 "
                        + "(KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36");
        if (referer != null && !referer.isEmpty()) {
            conn.setRequestProperty("Referer", referer);
        }
        conn.setRequestProperty("Accept", "application/json, text/plain, */*");
        try {
            int code = conn.getResponseCode();
            if (code != 200) return "";
            return Cms.read(conn.getInputStream(), 256 * 1024);
        } finally {
            conn.disconnect();
        }
    }

    private static void ensureDiskLoadedAsync(Context context) {
        if (context == null || !DISK_LOAD_STARTED.compareAndSet(false, true)) return;
        final Context appCtx = context.getApplicationContext();
        if (appCtx == null) return;
        DISK_IO_POOL.execute(
                () -> {
                    try {
                        File f = new File(appCtx.getFilesDir(), CACHE_FILE);
                        if (!f.exists() || !f.canRead() || f.length() > 2 * 1024 * 1024) return;
                        String raw;
                        try (FileInputStream in = new FileInputStream(f)) {
                            byte[] data = new byte[(int) f.length()];
                            int read = in.read(data);
                            if (read <= 0) return;
                            raw = new String(data, 0, read, StandardCharsets.UTF_8);
                        }
                        Map<String, CacheEntry> parsed = new LinkedHashMap<>();
                        parseCacheJsonInto(raw, parsed);
                        if (parsed.isEmpty()) return;
                        synchronized (CACHE_LOCK) {
                            for (Map.Entry<String, CacheEntry> e : parsed.entrySet()) {
                                if (!CACHE.containsKey(e.getKey())) {
                                    CACHE.put(e.getKey(), e.getValue());
                                }
                            }
                        }
                    } catch (Throwable ignored) {
                    }
                });
    }

    static void parseCacheJsonInto(String raw, Map<String, CacheEntry> target) {
        if (raw == null || raw.trim().isEmpty() || target == null) return;
        try {
            JSONObject obj = new JSONObject(raw);
            long now = System.currentTimeMillis();
            Iterator<String> it = obj.keys();
            while (it.hasNext()) {
                String k = it.next();
                JSONObject e = obj.optJSONObject(k);
                if (e == null) continue;
                double sc = e.optDouble("s", 0.0);
                long ts = e.optLong("t", 0L);
                CacheEntry entry = new CacheEntry(sc, ts);
                if (!entry.isExpired(now)) {
                    target.put(k, entry);
                }
            }
        } catch (Exception ignored) {
        }
    }

    static String serializeCacheJson(Map<String, CacheEntry> source) {
        JSONObject root = new JSONObject();
        if (source != null) {
            long now = System.currentTimeMillis();
            for (Map.Entry<String, CacheEntry> e : source.entrySet()) {
                CacheEntry ce = e.getValue();
                if (ce == null || ce.isExpired(now)) continue;
                try {
                    root.put(
                            e.getKey(),
                            new JSONObject().put("s", ce.score).put("t", ce.updatedAtMs));
                } catch (Exception ignored) {
                }
            }
        }
        return root.toString();
    }

    private static void scheduleDiskSave(final Context context) {
        if (context == null) return;
        long now = System.currentTimeMillis();
        if (now - lastDiskSaveMs < 4000L && DISK_SAVE_SCHEDULED.get()) return;
        if (!DISK_SAVE_SCHEDULED.compareAndSet(false, true)) return;
        final Context appCtx = context.getApplicationContext();
        if (appCtx == null) {
            DISK_SAVE_SCHEDULED.set(false);
            return;
        }
        DISK_IO_POOL.execute(
                () -> {
                    try {
                        Map<String, CacheEntry> snapshot;
                        synchronized (CACHE_LOCK) {
                            snapshot = new LinkedHashMap<>(CACHE);
                        }
                        String payload = serializeCacheJson(snapshot);
                        File target = new File(appCtx.getFilesDir(), CACHE_FILE);
                        File tmp = new File(appCtx.getFilesDir(), CACHE_FILE + ".tmp");
                        try (FileOutputStream out = new FileOutputStream(tmp)) {
                            out.write(payload.getBytes(StandardCharsets.UTF_8));
                            out.flush();
                        }
                        if (!tmp.renameTo(target)) {
                            try (FileOutputStream out = new FileOutputStream(target)) {
                                out.write(payload.getBytes(StandardCharsets.UTF_8));
                                out.flush();
                            }
                            tmp.delete();
                        }
                        lastDiskSaveMs = System.currentTimeMillis();
                    } catch (Throwable ignored) {
                    } finally {
                        DISK_SAVE_SCHEDULED.set(false);
                    }
                });
    }
}
