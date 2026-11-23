package com.pilipala.marcomovie;

import android.content.SharedPreferences;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.net.URLEncoder;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import org.json.JSONArray;
import org.json.JSONObject;

/**
 * User-configured TMDB v3 metadata/artwork client + TheIntroDB automatic intro/outro timestamp
 * lookup. Supports custom API/image reverse proxies and disk caching; zero built-in keys.
 */
final class TmdbService {
    interface Callback<T> {
        void onResult(T value);
    }

    static final class MediaCard {
        final int tmdbId;
        final boolean isTv;
        final String title;
        final String posterUrl;
        final String backdropUrl;
        final String year;
        final double rating;
        final String overview;

        MediaCard(
                int tmdbId,
                boolean isTv,
                String title,
                String posterUrl,
                String backdropUrl,
                String year,
                double rating,
                String overview) {
            this.tmdbId = tmdbId;
            this.isTv = isTv;
            this.title = title;
            this.posterUrl = posterUrl;
            this.backdropUrl = backdropUrl;
            this.year = year;
            this.rating = rating;
            this.overview = overview;
        }
    }

    static final class DiscoveryFeed {
        final List<MediaCard> trending = new ArrayList<>();
        final List<MediaCard> popularMovies = new ArrayList<>();
        final List<MediaCard> popularTv = new ArrayList<>();
        final List<MediaCard> topRated = new ArrayList<>();
    }

    static final class EpisodeStill {
        final int episodeNumber;
        final String name;
        final String overview;
        final String stillUrl;
        final String airDate;
        final int runtimeMinutes;

        EpisodeStill(
                int episodeNumber,
                String name,
                String overview,
                String stillUrl,
                String airDate,
                int runtimeMinutes) {
            this.episodeNumber = episodeNumber;
            this.name = name;
            this.overview = overview;
            this.stillUrl = stillUrl;
            this.airDate = airDate;
            this.runtimeMinutes = runtimeMinutes;
        }
    }

    static final class EnrichedMeta {
        final int tmdbId;
        final boolean isTv;
        final String title;
        final String overview;
        final String posterUrl;
        final String backdropUrl;
        final double voteAverage;
        final String releaseYear;
        final String genres;
        final String castLine;
        final Map<Integer, EpisodeStill> episodes = new HashMap<>();

        EnrichedMeta(
                int tmdbId,
                boolean isTv,
                String title,
                String overview,
                String posterUrl,
                String backdropUrl,
                double voteAverage,
                String releaseYear,
                String genres,
                String castLine) {
            this.tmdbId = tmdbId;
            this.isTv = isTv;
            this.title = title;
            this.overview = overview;
            this.posterUrl = posterUrl;
            this.backdropUrl = backdropUrl;
            this.voteAverage = voteAverage;
            this.releaseYear = releaseYear;
            this.genres = genres;
            this.castLine = castLine;
        }
    }

    static final class IntroTimestamps {
        final int introStartSec;
        final int introEndSec;
        final int outroStartSec;

        IntroTimestamps(int introStartSec, int introEndSec, int outroStartSec) {
            this.introStartSec = introStartSec;
            this.introEndSec = introEndSec;
            this.outroStartSec = outroStartSec;
        }
    }

    private TmdbService() {}

    static boolean isConfigured(MainActivity a) {
        if (a == null || a.isTvDevice()) return false;
        if (!a.mobilePrefs().getBoolean(Prefs.TMDB_ENABLED, true)) return false;
        String key = a.secretsPrefs().getString(Prefs.SECRET_TMDB_API_KEY, "").trim();
        return !key.isEmpty();
    }

    static String apiBase(MainActivity a) {
        String proxy = a.mobilePrefs().getString(Prefs.TMDB_API_PROXY, "").trim();
        String base = proxy.isEmpty() ? "https://api.themoviedb.org/3" : proxy;
        while (base.endsWith("/")) base = base.substring(0, base.length() - 1);
        if (!base.endsWith("/3") && base.contains("themoviedb")) base = base + "/3";
        return base;
    }

    static String imageUrl(MainActivity a, String path, String size) {
        if (path == null || path.isEmpty() || "null".equals(path)) return "";
        String proxy = a.mobilePrefs().getString(Prefs.TMDB_IMAGE_PROXY, "").trim();
        String base = proxy.isEmpty() ? "https://image.tmdb.org/t/p" : proxy;
        while (base.endsWith("/")) base = base.substring(0, base.length() - 1);
        if (!base.contains("/t/p") && base.contains("tmdb.org")) base = base + "/t/p";
        return base + "/" + size + (path.startsWith("/") ? path : ("/" + path));
    }

    static void fetchDiscoveryAsync(final MainActivity a, final Callback<DiscoveryFeed> callback) {
        if (!isConfigured(a) || callback == null) return;
        final int ticket = a.generation;
        final String lang = a.mobilePrefs().getString(Prefs.TMDB_LANGUAGE, "zh-CN");
        a.worker.execute(
                () -> {
                    try {
                        DiscoveryFeed feed = new DiscoveryFeed();
                        parseCardList(
                                a,
                                getJson(a, "/trending/all/day?language=" + lang, 3600_000L),
                                false,
                                feed.trending);
                        parseCardList(
                                a,
                                getJson(a, "/tv/popular?language=" + lang, 7200_000L),
                                true,
                                feed.popularTv);
                        parseCardList(
                                a,
                                getJson(a, "/movie/popular?language=" + lang, 7200_000L),
                                false,
                                feed.popularMovies);
                        parseCardList(
                                a,
                                getJson(a, "/tv/top_rated?language=" + lang, 14400_000L),
                                true,
                                feed.topRated);
                        a.ui.post(
                                () -> {
                                    if (!a.isFinishing() && ticket == a.generation) {
                                        callback.onResult(feed);
                                    }
                                });
                    } catch (Exception e) {
                        AppLog.w("TmdbService", "fetchDiscoveryAsync failed", e);
                        a.ui.post(
                                () -> {
                                    if (!a.isFinishing() && ticket == a.generation) {
                                        callback.onResult(null);
                                    }
                                });
                    }
                });
    }

    static void enrichDetailAsync(
            final MainActivity a,
            final String rawTitle,
            final int seasonNumber,
            final Callback<EnrichedMeta> callback) {
        if (!isConfigured(a) || rawTitle == null || callback == null) return;
        final int ticket = a.generation;
        final SeasonParser.SeasonMeta sMeta = SeasonParser.parseSeasonMeta(rawTitle);
        final String query = EpisodeNameCleaner.cleanSearchTitle(sMeta.baseTitle);
        if (query.isEmpty()) return;
        final int targetSeason = Math.max(1, seasonNumber > 0 ? seasonNumber : sMeta.seasonNumber);
        final String lang = a.mobilePrefs().getString(Prefs.TMDB_LANGUAGE, "zh-CN");

        a.worker.execute(
                () -> {
                    try {
                        String searchPath =
                                "/search/multi?language="
                                        + lang
                                        + "&query="
                                        + URLEncoder.encode(query, "UTF-8");
                        JSONObject searchJson = getJson(a, searchPath, 86400_000L);
                        JSONArray results =
                                searchJson == null ? null : searchJson.optJSONArray("results");
                        if (results == null || results.length() == 0) return;

                        JSONObject hit = null;
                        for (int i = 0; i < results.length(); i++) {
                            JSONObject item = results.optJSONObject(i);
                            if (item == null) continue;
                            String mediaType = item.optString("media_type", "tv");
                            if ("movie".equals(mediaType) || "tv".equals(mediaType)) {
                                hit = item;
                                break;
                            }
                        }
                        if (hit == null) return;

                        boolean isTv = "tv".equals(hit.optString("media_type", "tv"));
                        int id = hit.optInt("id", 0);
                        if (id <= 0) return;

                        JSONObject detail =
                                getJson(
                                        a,
                                        (isTv ? "/tv/" : "/movie/")
                                                + id
                                                + "?language="
                                                + lang
                                                + "&append_to_response=credits",
                                        86400_000L);
                        if (detail == null) detail = hit;

                        String title =
                                detail.optString(
                                        isTv ? "name" : "title",
                                        hit.optString(isTv ? "name" : "title", query));
                        String overview = detail.optString("overview", "");
                        String poster = imageUrl(a, detail.optString("poster_path", ""), "w500");
                        String backdrop =
                                imageUrl(a, detail.optString("backdrop_path", ""), "w780");
                        double vote = detail.optDouble("vote_average", 0.0);
                        String date =
                                detail.optString(isTv ? "first_air_date" : "release_date", "");
                        String year = date.length() >= 4 ? date.substring(0, 4) : "";

                        StringBuilder genreSb = new StringBuilder();
                        JSONArray genresArr = detail.optJSONArray("genres");
                        if (genresArr != null) {
                            for (int i = 0; i < Math.min(3, genresArr.length()); i++) {
                                String g = genresArr.getJSONObject(i).optString("name", "");
                                if (!g.isEmpty()) {
                                    if (genreSb.length() > 0) genreSb.append(" · ");
                                    genreSb.append(g);
                                }
                            }
                        }

                        StringBuilder castSb = new StringBuilder();
                        JSONObject credits = detail.optJSONObject("credits");
                        JSONArray castArr = credits == null ? null : credits.optJSONArray("cast");
                        if (castArr != null) {
                            for (int i = 0; i < Math.min(5, castArr.length()); i++) {
                                String c = castArr.getJSONObject(i).optString("name", "");
                                if (!c.isEmpty()) {
                                    if (castSb.length() > 0) castSb.append(" / ");
                                    castSb.append(c);
                                }
                            }
                        }

                        final EnrichedMeta meta =
                                new EnrichedMeta(
                                        id,
                                        isTv,
                                        title,
                                        overview,
                                        poster,
                                        backdrop,
                                        vote,
                                        year,
                                        genreSb.toString(),
                                        castSb.toString());

                        if (isTv) {
                            try {
                                JSONObject seasonJson =
                                        getJson(
                                                a,
                                                "/tv/"
                                                        + id
                                                        + "/season/"
                                                        + targetSeason
                                                        + "?language="
                                                        + lang,
                                                86400_000L);
                                JSONArray eps =
                                        seasonJson == null
                                                ? null
                                                : seasonJson.optJSONArray("episodes");
                                if (eps != null) {
                                    for (int i = 0; i < eps.length(); i++) {
                                        JSONObject epObj = eps.optJSONObject(i);
                                        if (epObj == null) continue;
                                        int epNum = epObj.optInt("episode_number", i + 1);
                                        meta.episodes.put(
                                                epNum,
                                                new EpisodeStill(
                                                        epNum,
                                                        epObj.optString("name", ""),
                                                        epObj.optString("overview", ""),
                                                        imageUrl(
                                                                a,
                                                                epObj.optString("still_path", ""),
                                                                "w300"),
                                                        epObj.optString("air_date", ""),
                                                        epObj.optInt("runtime", 0)));
                                    }
                                }
                            } catch (Exception ignored) {
                            }
                        }

                        a.ui.post(
                                () -> {
                                    if (!a.isFinishing() && ticket == a.generation) {
                                        callback.onResult(meta);
                                    }
                                });
                    } catch (Exception e) {
                        AppLog.w("TmdbService", "enrichDetailAsync failed", e);
                    }
                });
    }

    /** Queries TheIntroDB for community intro/outro timestamps using a matched TMDB ID. */
    static void lookupIntroDbAsync(
            final MainActivity a,
            final int tmdbId,
            final boolean isTv,
            final int season,
            final int episode,
            final Callback<IntroTimestamps> callback) {
        if (a == null
                || a.isTvDevice()
                || tmdbId <= 0
                || callback == null
                || !a.mobilePrefs().getBoolean(Prefs.THEINTRODB_AUTO_SKIP, true)) {
            return;
        }
        a.worker.execute(
                () -> {
                    try {
                        String url =
                                "https://api.theintrodb.org/v1/media?tmdb_id="
                                        + tmdbId
                                        + (isTv
                                                ? ("&season="
                                                        + Math.max(1, season)
                                                        + "&episode="
                                                        + Math.max(1, episode))
                                                : "");
                        String cacheKey = "introdb_" + sha256(url);
                        String raw = readCache(a, cacheKey, 7L * 86400_000L);
                        if (raw == null) {
                            raw = httpGet(url, Collections.emptyMap());
                            if (raw != null) writeCache(a, cacheKey, raw);
                        }
                        if (raw == null || raw.isEmpty()) return;
                        JSONObject obj = new JSONObject(raw);
                        JSONObject intro = obj.optJSONObject("intro");
                        JSONObject outro = obj.optJSONObject("outro");
                        int iStart = intro == null ? -1 : msOrSecToSec(intro, "start_ms", "start");
                        int iEnd = intro == null ? -1 : msOrSecToSec(intro, "end_ms", "end");
                        int oStart = outro == null ? -1 : msOrSecToSec(outro, "start_ms", "start");
                        if (iEnd > 0 || oStart > 0) {
                            final IntroTimestamps ts =
                                    new IntroTimestamps(Math.max(0, iStart), iEnd, oStart);
                            a.ui.post(
                                    () -> {
                                        if (!a.isFinishing()) callback.onResult(ts);
                                    });
                        }
                    } catch (Exception ignored) {
                    }
                });
    }

    private static int msOrSecToSec(JSONObject obj, String msKey, String secKey) {
        if (obj.has(msKey) && !obj.isNull(msKey)) {
            return Math.max(0, (int) (obj.optLong(msKey, 0L) / 1000L));
        }
        if (obj.has(secKey) && !obj.isNull(secKey)) {
            return Math.max(0, obj.optInt(secKey, 0));
        }
        return -1;
    }

    private static void parseCardList(
            MainActivity a, JSONObject json, boolean defaultTv, List<MediaCard> dest) {
        if (json == null) return;
        JSONArray arr = json.optJSONArray("results");
        if (arr == null) return;
        for (int i = 0; i < Math.min(18, arr.length()); i++) {
            JSONObject o = arr.optJSONObject(i);
            if (o == null) continue;
            String mt = o.optString("media_type", defaultTv ? "tv" : "movie");
            if (!"tv".equals(mt) && !"movie".equals(mt)) continue;
            boolean tv = "tv".equals(mt);
            String title = o.optString(tv ? "name" : "title", "").trim();
            if (title.isEmpty()) continue;
            String date = o.optString(tv ? "first_air_date" : "release_date", "");
            dest.add(
                    new MediaCard(
                            o.optInt("id", 0),
                            tv,
                            title,
                            imageUrl(a, o.optString("poster_path", ""), "w342"),
                            imageUrl(a, o.optString("backdrop_path", ""), "w780"),
                            date.length() >= 4 ? date.substring(0, 4) : "",
                            o.optDouble("vote_average", 0.0),
                            o.optString("overview", "")));
        }
    }

    private static JSONObject getJson(MainActivity a, String pathAndQuery, long maxAgeMs)
            throws Exception {
        SharedPreferences secrets = a.secretsPrefs();
        String apiKey = secrets.getString(Prefs.SECRET_TMDB_API_KEY, "").trim();
        if (apiKey.isEmpty()) return null;

        String cacheKey = "tmdb_" + sha256(pathAndQuery);
        String cached = readCache(a, cacheKey, maxAgeMs);
        if (cached != null) return new JSONObject(cached);

        String base = apiBase(a);
        Map<String, String> headers = new HashMap<>();
        String fullUrl;
        if (apiKey.length() > 64 || apiKey.startsWith("eyJ")) {
            // TMDB v4 Read Access Bearer Token
            fullUrl = base + pathAndQuery;
            headers.put("Authorization", "Bearer " + apiKey);
        } else {
            String sep = pathAndQuery.contains("?") ? "&" : "?";
            fullUrl = base + pathAndQuery + sep + "api_key=" + URLEncoder.encode(apiKey, "UTF-8");
        }
        String body = httpGet(fullUrl, headers);
        if (body == null || body.isEmpty()) return null;
        writeCache(a, cacheKey, body);
        return new JSONObject(body);
    }

    static String httpGet(String urlStr, Map<String, String> headers) throws Exception {
        HttpURLConnection conn = (HttpURLConnection) new URL(urlStr).openConnection();
        conn.setConnectTimeout(10000);
        conn.setReadTimeout(15000);
        conn.setRequestProperty("Accept", "application/json");
        conn.setRequestProperty("User-Agent", Cms.USER_AGENT);
        if (headers != null) {
            for (Map.Entry<String, String> e : headers.entrySet()) {
                conn.setRequestProperty(e.getKey(), e.getValue());
            }
        }
        int code = conn.getResponseCode();
        if (code < 200 || code >= 300) {
            conn.disconnect();
            throw new java.io.IOException("HTTP " + code);
        }
        try (InputStream in = conn.getInputStream()) {
            return Cms.read(in, 512 * 1024);
        } finally {
            conn.disconnect();
        }
    }

    private static File cacheDir(MainActivity a) {
        File d = new File(a.getCacheDir(), "tmdb_cache_v1");
        if (!d.exists()) d.mkdirs();
        return d;
    }

    private static String readCache(MainActivity a, String key, long maxAgeMs) {
        File f = new File(cacheDir(a), key + ".json");
        if (!f.exists() || System.currentTimeMillis() - f.lastModified() > maxAgeMs) return null;
        try (InputStream in = new FileInputStream(f)) {
            return Cms.read(in, 512 * 1024);
        } catch (Exception ignored) {
            return null;
        }
    }

    private static void writeCache(MainActivity a, String key, String data) {
        File f = new File(cacheDir(a), key + ".json");
        try (OutputStream out = new FileOutputStream(f)) {
            out.write(data.getBytes("UTF-8"));
        } catch (Exception ignored) {
        }
    }

    static long cacheBytes(MainActivity a) {
        File d = new File(a.getCacheDir(), "tmdb_cache_v1");
        File[] files = d.listFiles();
        long sum = 0;
        if (files != null) for (File f : files) sum += f.length();
        return sum;
    }

    static void clearCache(MainActivity a) {
        File d = new File(a.getCacheDir(), "tmdb_cache_v1");
        File[] files = d.listFiles();
        if (files != null) for (File f : files) f.delete();
    }

    private static String sha256(String s) {
        try {
            byte[] d = MessageDigest.getInstance("SHA-256").digest(s.getBytes("UTF-8"));
            StringBuilder sb = new StringBuilder(32);
            for (int i = 0; i < 16; i++) {
                sb.append(String.format(Locale.US, "%02x", d[i] & 0xff));
            }
            return sb.toString();
        } catch (Exception e) {
            return Integer.toHexString(s.hashCode());
        }
    }
}
