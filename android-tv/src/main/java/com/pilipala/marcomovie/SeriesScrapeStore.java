// Copyright (C) 2026 Pilipala
// SPDX-License-Identifier: GPL-3.0-only
package com.pilipala.marcomovie;

import android.content.Context;
import android.content.SharedPreferences;
import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.Map;
import org.json.JSONException;
import org.json.JSONObject;

/**
 * Persistent per-series scraping overrides (stored in its own {@code series_scrape_overrides}
 * SharedPreferences file so {@link Prefs#KEYS} stays untouched). Applies across ALL sources:
 * subscription CMS/plugins, cloud drives, AList, Emby, and local USB hard drives.
 */
final class SeriesScrapeStore {
    private static final String PREF_FILE = "series_scrape_overrides";
    private static final String PREF_KEY = "records_v1";
    private static final int MAX_ENTRIES = 300;

    static final class OverrideRecord {
        String key = "";
        String matchedTitle = "";
        String metadataSource = "";
        String subjectId = "";
        String posterUrl = "";
        String backdropUrl = "";
        String synopsis = "";
        String year = "";
        double doubanScore;
        int totalEpisodes;
        int episodeOffset;
        boolean sortByScrapedEpisode;
        boolean sortPreferenceExplicit;
        boolean hideSpecials;
        String danmuTitleOverride = "";
        String danmuAnimeId = "";
        String danmuOrigin = "";
        long updatedAt;
        final Map<Integer, Integer> episodeNumberOverrides = new LinkedHashMap<>();
        final Map<Integer, String> officialEpisodeTitles = new LinkedHashMap<>();

        boolean isEmpty() {
            return matchedTitle.isEmpty()
                    && posterUrl.isEmpty()
                    && backdropUrl.isEmpty()
                    && synopsis.isEmpty()
                    && episodeOffset == 0
                    && !sortPreferenceExplicit
                    && !hideSpecials
                    && danmuTitleOverride.isEmpty()
                    && danmuAnimeId.isEmpty()
                    && episodeNumberOverrides.isEmpty()
                    && officialEpisodeTitles.isEmpty();
        }

        OverrideRecord copy() {
            OverrideRecord c = new OverrideRecord();
            c.key = key;
            c.matchedTitle = matchedTitle;
            c.metadataSource = metadataSource;
            c.subjectId = subjectId;
            c.posterUrl = posterUrl;
            c.backdropUrl = backdropUrl;
            c.synopsis = synopsis;
            c.year = year;
            c.doubanScore = doubanScore;
            c.totalEpisodes = totalEpisodes;
            c.episodeOffset = episodeOffset;
            c.sortByScrapedEpisode = sortByScrapedEpisode;
            c.sortPreferenceExplicit = sortPreferenceExplicit;
            c.hideSpecials = hideSpecials;
            c.danmuTitleOverride = danmuTitleOverride;
            c.danmuAnimeId = danmuAnimeId;
            c.danmuOrigin = danmuOrigin;
            c.updatedAt = updatedAt;
            c.episodeNumberOverrides.putAll(episodeNumberOverrides);
            c.officialEpisodeTitles.putAll(officialEpisodeTitles);
            return c;
        }

        JSONObject toJson() throws JSONException {
            JSONObject obj = new JSONObject();
            obj.put("key", key);
            if (!matchedTitle.isEmpty()) obj.put("matchedTitle", matchedTitle);
            if (!metadataSource.isEmpty()) obj.put("metadataSource", metadataSource);
            if (!subjectId.isEmpty()) obj.put("subjectId", subjectId);
            if (!posterUrl.isEmpty()) obj.put("posterUrl", posterUrl);
            if (!backdropUrl.isEmpty()) obj.put("backdropUrl", backdropUrl);
            if (!synopsis.isEmpty()) obj.put("synopsis", synopsis);
            if (!year.isEmpty()) obj.put("year", year);
            if (doubanScore > 0) obj.put("doubanScore", doubanScore);
            if (totalEpisodes > 0) obj.put("totalEpisodes", totalEpisodes);
            if (episodeOffset != 0) obj.put("episodeOffset", episodeOffset);
            if (sortPreferenceExplicit) {
                obj.put("sortByScrapedEpisode", sortByScrapedEpisode);
                obj.put("sortPreferenceExplicit", true);
            }
            if (hideSpecials) obj.put("hideSpecials", true);
            if (!danmuTitleOverride.isEmpty()) obj.put("danmuTitleOverride", danmuTitleOverride);
            if (!danmuAnimeId.isEmpty()) obj.put("danmuAnimeId", danmuAnimeId);
            if (!danmuOrigin.isEmpty()) obj.put("danmuOrigin", danmuOrigin);
            obj.put("updatedAt", updatedAt);
            if (!episodeNumberOverrides.isEmpty()) {
                JSONObject map = new JSONObject();
                for (Map.Entry<Integer, Integer> e : episodeNumberOverrides.entrySet()) {
                    map.put(String.valueOf(e.getKey()), e.getValue().intValue());
                }
                obj.put("episodeNumberOverrides", map);
            }
            if (!officialEpisodeTitles.isEmpty()) {
                JSONObject map = new JSONObject();
                for (Map.Entry<Integer, String> e : officialEpisodeTitles.entrySet()) {
                    map.put(String.valueOf(e.getKey()), e.getValue());
                }
                obj.put("officialEpisodeTitles", map);
            }
            return obj;
        }

        static OverrideRecord fromJson(String key, JSONObject obj) {
            if (obj == null) return null;
            OverrideRecord r = new OverrideRecord();
            r.key = safeStr(obj, "key", key);
            r.matchedTitle = safeStr(obj, "matchedTitle", "");
            r.metadataSource = safeStr(obj, "metadataSource", "");
            r.subjectId = safeStr(obj, "subjectId", "");
            r.posterUrl = safeStr(obj, "posterUrl", "");
            r.backdropUrl = safeStr(obj, "backdropUrl", "");
            r.synopsis = safeStr(obj, "synopsis", "");
            r.year = safeStr(obj, "year", "");
            r.doubanScore = obj.optDouble("doubanScore", 0.0);
            if (Double.isNaN(r.doubanScore)) r.doubanScore = 0.0;
            r.totalEpisodes = Math.max(0, obj.optInt("totalEpisodes", 0));
            r.episodeOffset = Math.max(-500, Math.min(500, obj.optInt("episodeOffset", 0)));
            r.sortPreferenceExplicit = obj.optBoolean("sortPreferenceExplicit", false);
            r.sortByScrapedEpisode = obj.optBoolean("sortByScrapedEpisode", false);
            r.hideSpecials = obj.optBoolean("hideSpecials", false);
            r.danmuTitleOverride = safeStr(obj, "danmuTitleOverride", "");
            r.danmuAnimeId = safeStr(obj, "danmuAnimeId", "");
            r.danmuOrigin = safeStr(obj, "danmuOrigin", "");
            r.updatedAt = obj.optLong("updatedAt", 0L);

            JSONObject epOv = obj.optJSONObject("episodeNumberOverrides");
            if (epOv != null) {
                Iterator<String> it = epOv.keys();
                while (it.hasNext()) {
                    String k = it.next();
                    try {
                        int idx = Integer.parseInt(k);
                        int val = epOv.optInt(k, -1);
                        if (idx >= 0 && val > 0) r.episodeNumberOverrides.put(idx, val);
                    } catch (NumberFormatException ignored) {
                    }
                }
            }
            JSONObject titles = obj.optJSONObject("officialEpisodeTitles");
            if (titles != null) {
                Iterator<String> it = titles.keys();
                while (it.hasNext()) {
                    String k = it.next();
                    try {
                        int epNum = Integer.parseInt(k);
                        String title = safeStr(titles, k, "");
                        if (epNum > 0 && !title.isEmpty())
                            r.officialEpisodeTitles.put(epNum, title);
                    } catch (NumberFormatException ignored) {
                    }
                }
            }
            return r;
        }
    }

    private static final Object LOCK = new Object();
    private static LinkedHashMap<String, OverrideRecord> cache;

    private SeriesScrapeStore() {}

    static String primaryKey(String siteKey, String videoId) {
        String s = siteKey == null ? "" : siteKey.trim();
        String v = videoId == null ? "" : videoId.trim();
        if (s.isEmpty() || v.isEmpty()) return "";
        return "item:" + s + "::" + v;
    }

    static String titleKey(String title) {
        String core = TvSeriesScraper.normalizeCoreKey(title);
        return core.isEmpty() ? "" : ("title:" + core);
    }

    static OverrideRecord load(Context context, String siteKey, String videoId, String title) {
        if (context == null) return null;
        synchronized (LOCK) {
            ensureLoadedLocked(context);
            String pk = primaryKey(siteKey, videoId);
            OverrideRecord found = pk.isEmpty() ? null : cache.get(pk);
            if (found != null) return found.copy();
            String tk = titleKey(title);
            found = tk.isEmpty() ? null : cache.get(tk);
            return found != null ? found.copy() : null;
        }
    }

    static void save(
            Context context, String siteKey, String videoId, String title, OverrideRecord record) {
        if (context == null || record == null) return;
        String pk = primaryKey(siteKey, videoId);
        if (pk.isEmpty()) pk = titleKey(title);
        if (pk.isEmpty()) return;
        synchronized (LOCK) {
            ensureLoadedLocked(context);
            if (record.isEmpty()) {
                cache.remove(pk);
            } else {
                OverrideRecord copy = record.copy();
                copy.key = pk;
                copy.updatedAt = System.currentTimeMillis();
                cache.remove(pk);
                cache.put(pk, copy);
                while (cache.size() > MAX_ENTRIES) {
                    Iterator<String> it = cache.keySet().iterator();
                    if (!it.hasNext()) break;
                    it.next();
                    it.remove();
                }
            }
            persistLocked(context);
        }
    }

    static void remove(Context context, String siteKey, String videoId, String title) {
        if (context == null) return;
        synchronized (LOCK) {
            ensureLoadedLocked(context);
            String pk = primaryKey(siteKey, videoId);
            String tk = titleKey(title);
            boolean changed = false;
            if (!pk.isEmpty() && cache.remove(pk) != null) changed = true;
            if (!tk.isEmpty() && cache.remove(tk) != null) changed = true;
            if (changed) persistLocked(context);
        }
    }

    static Map<String, OverrideRecord> parseMapJson(String raw) {
        LinkedHashMap<String, OverrideRecord> map = new LinkedHashMap<>();
        if (raw == null || raw.trim().isEmpty()) return map;
        try {
            JSONObject root = new JSONObject(raw);
            Iterator<String> it = root.keys();
            while (it.hasNext()) {
                String k = it.next();
                OverrideRecord r = OverrideRecord.fromJson(k, root.optJSONObject(k));
                if (r != null && !r.isEmpty()) {
                    map.put(k, r);
                }
            }
        } catch (JSONException ignored) {
        }
        return map;
    }

    static String serializeMapJson(Map<String, OverrideRecord> map) {
        JSONObject root = new JSONObject();
        if (map != null) {
            for (Map.Entry<String, OverrideRecord> e : map.entrySet()) {
                if (e.getKey() == null || e.getValue() == null || e.getValue().isEmpty()) continue;
                try {
                    root.put(e.getKey(), e.getValue().toJson());
                } catch (JSONException ignored) {
                }
            }
        }
        return root.toString();
    }

    private static void ensureLoadedLocked(Context context) {
        if (cache != null) return;
        SharedPreferences sp = context.getSharedPreferences(PREF_FILE, Context.MODE_PRIVATE);
        cache = new LinkedHashMap<>(parseMapJson(sp.getString(PREF_KEY, "")));
    }

    private static void persistLocked(Context context) {
        SharedPreferences sp = context.getSharedPreferences(PREF_FILE, Context.MODE_PRIVATE);
        sp.edit().putString(PREF_KEY, serializeMapJson(cache)).apply();
    }

    private static String safeStr(JSONObject obj, String key, String fallback) {
        if (obj == null || !obj.has(key) || obj.isNull(key)) return fallback;
        String v = obj.optString(key, fallback);
        return (v == null || "null".equalsIgnoreCase(v.trim())) ? fallback : v.trim();
    }
}
