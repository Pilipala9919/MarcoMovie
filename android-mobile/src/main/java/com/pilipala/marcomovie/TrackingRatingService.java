package com.pilipala.marcomovie;

import java.net.URLEncoder;
import java.util.ArrayList;
import java.util.Calendar;
import java.util.Collections;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import org.json.JSONArray;
import org.json.JSONObject;

/**
 * Multi-platform ratings aggregator (TMDB, Douban, Bangumi, Trakt, IMDb / RottenTomatoes via
 * MDBList) and Airing / Follow Calendar client (Bangumi broadcast schedule + user Bangumi/Trakt
 * watching collection). Zero built-in credentials.
 */
final class TrackingRatingService {
    interface Callback<T> {
        void onResult(T value);
    }

    static final class MultiRating {
        double tmdb;
        double douban;
        double bangumi;
        double imdb;
        int rottenTomatoes;
        double trakt;
    }

    static final class CalendarEntry {
        final int weekday; // 1=Mon .. 7=Sun
        final String title;
        final String subtitle;
        final String posterUrl;
        final double rating;
        final String sourceBadge;

        CalendarEntry(
                int weekday,
                String title,
                String subtitle,
                String posterUrl,
                double rating,
                String sourceBadge) {
            this.weekday = weekday;
            this.title = title;
            this.subtitle = subtitle;
            this.posterUrl = posterUrl;
            this.rating = rating;
            this.sourceBadge = sourceBadge;
        }
    }

    private TrackingRatingService() {}

    static void lookupRatingsAsync(
            final MainActivity a,
            final String rawTitle,
            final int tmdbId,
            final boolean isTv,
            final double knownTmdb,
            final double knownDouban,
            final Callback<MultiRating> callback) {
        if (a == null || rawTitle == null || callback == null) return;
        final int ticket = a.generation;
        final String cleanTitle =
                EpisodeNameCleaner.cleanSearchTitle(
                        SeasonParser.parseSeasonMeta(rawTitle).baseTitle);
        a.worker.execute(
                () -> {
                    final MultiRating r = new MultiRating();
                    r.tmdb = knownTmdb;
                    r.douban = knownDouban;

                    // 1. Bangumi subject rating lookup (official public API)
                    try {
                        String bgmUrl =
                                "https://api.bgm.tv/search/subject/"
                                        + URLEncoder.encode(cleanTitle, "UTF-8")
                                        + "?type=2&responseGroup=small&max_results=3";
                        Map<String, String> headers = new HashMap<>();
                        String bgmToken =
                                a.secretsPrefs().getString(Prefs.SECRET_BANGUMI_TOKEN, "").trim();
                        if (!bgmToken.isEmpty()) {
                            headers.put("Authorization", "Bearer " + bgmToken);
                        }
                        String raw = TmdbService.httpGet(bgmUrl, headers);
                        if (raw != null && raw.startsWith("{")) {
                            JSONArray list = new JSONObject(raw).optJSONArray("list");
                            if (list != null && list.length() > 0) {
                                JSONObject first = list.getJSONObject(0);
                                JSONObject ratingObj = first.optJSONObject("rating");
                                if (ratingObj != null) {
                                    r.bangumi = ratingObj.optDouble("score", 0.0);
                                }
                            }
                        }
                    } catch (Exception ignored) {
                    }

                    // 2. MDBList multi-score lookup when user configured SECRET_MDBLIST_API_KEY
                    String mdbKey =
                            a.secretsPrefs().getString(Prefs.SECRET_MDBLIST_API_KEY, "").trim();
                    if (!mdbKey.isEmpty() && tmdbId > 0) {
                        try {
                            String url =
                                    "https://api.mdblist.com/?apikey="
                                            + URLEncoder.encode(mdbKey, "UTF-8")
                                            + "&tm="
                                            + tmdbId
                                            + "&m="
                                            + (isTv ? "show" : "movie");
                            String raw = TmdbService.httpGet(url, Collections.emptyMap());
                            if (raw != null && raw.startsWith("{")) {
                                JSONObject obj = new JSONObject(raw);
                                JSONArray ratings = obj.optJSONArray("ratings");
                                if (ratings != null) {
                                    for (int i = 0; i < ratings.length(); i++) {
                                        JSONObject item = ratings.optJSONObject(i);
                                        if (item == null) continue;
                                        String src =
                                                item.optString("source", "")
                                                        .toLowerCase(Locale.ROOT);
                                        double val = item.optDouble("value", 0.0);
                                        if ("imdb".equals(src) && val > 0) r.imdb = val;
                                        else if ("tomatoes".equals(src) && val > 0)
                                            r.rottenTomatoes = (int) Math.round(val);
                                        else if ("trakt".equals(src) && val > 0)
                                            r.trakt = val > 10 ? val / 10.0 : val;
                                        else if ("tmdb".equals(src) && val > 0 && r.tmdb <= 0)
                                            r.tmdb = val > 10 ? val / 10.0 : val;
                                    }
                                }
                            }
                        } catch (Exception ignored) {
                        }
                    }

                    a.ui.post(
                            () -> {
                                if (!a.isFinishing() && ticket == a.generation) {
                                    callback.onResult(r);
                                }
                            });
                });
    }

    /**
     * Loads the weekly broadcast & personal watching calendar (Bangumi weekly schedule + optional
     * user Bangumi watching collection + optional Trakt show calendar).
     */
    static void fetchFollowCalendarAsync(
            final MainActivity a, final Callback<List<CalendarEntry>> callback) {
        if (a == null || callback == null) return;
        final int ticket = a.generation;
        a.worker.execute(
                () -> {
                    final List<CalendarEntry> out = new ArrayList<>();
                    // 1. User's personal Trakt watching calendar if configured
                    String traktToken =
                            a.secretsPrefs().getString(Prefs.SECRET_TRAKT_TOKEN, "").trim();
                    String traktClient =
                            a.secretsPrefs().getString(Prefs.SECRET_TRAKT_CLIENT_ID, "").trim();
                    if (!traktToken.isEmpty() && !traktClient.isEmpty()) {
                        try {
                            Map<String, String> headers = new HashMap<>();
                            headers.put("Authorization", "Bearer " + traktToken);
                            headers.put("trakt-api-version", "2");
                            headers.put("trakt-api-key", traktClient);
                            String raw =
                                    TmdbService.httpGet(
                                            "https://api.trakt.tv/calendars/my/shows?extended=full",
                                            headers);
                            if (raw != null && raw.startsWith("[")) {
                                JSONArray arr = new JSONArray(raw);
                                for (int i = 0; i < Math.min(30, arr.length()); i++) {
                                    JSONObject row = arr.getJSONObject(i);
                                    JSONObject show = row.optJSONObject("show");
                                    JSONObject ep = row.optJSONObject("episode");
                                    if (show == null) continue;
                                    String title = show.optString("title", "");
                                    String sub =
                                            ep == null
                                                    ? ""
                                                    : String.format(
                                                            Locale.US,
                                                            "S%02dE%02d %s",
                                                            ep.optInt("season", 1),
                                                            ep.optInt("number", 1),
                                                            ep.optString("title", ""));
                                    out.add(
                                            new CalendarEntry(
                                                    todayWeekday(),
                                                    title,
                                                    sub.trim(),
                                                    "",
                                                    show.optDouble("rating", 0.0),
                                                    "Trakt 追剧"));
                                }
                            }
                        } catch (Exception ignored) {
                        }
                    }

                    // 2. User's Bangumi watching collection if username configured
                    String bgmUser =
                            a.secretsPrefs().getString(Prefs.SECRET_BANGUMI_USERNAME, "").trim();
                    if (!bgmUser.isEmpty()) {
                        try {
                            Map<String, String> headers = new HashMap<>();
                            String bgmToken =
                                    a.secretsPrefs()
                                            .getString(Prefs.SECRET_BANGUMI_TOKEN, "")
                                            .trim();
                            if (!bgmToken.isEmpty()) {
                                headers.put("Authorization", "Bearer " + bgmToken);
                            }
                            String raw =
                                    TmdbService.httpGet(
                                            "https://api.bgm.tv/v0/users/"
                                                    + URLEncoder.encode(bgmUser, "UTF-8")
                                                    + "/collections?subject_type=2&type=3&limit=24",
                                            headers);
                            if (raw != null && raw.startsWith("{")) {
                                JSONArray data = new JSONObject(raw).optJSONArray("data");
                                if (data != null) {
                                    for (int i = 0; i < data.length(); i++) {
                                        JSONObject item = data.getJSONObject(i);
                                        JSONObject subj = item.optJSONObject("subject");
                                        if (subj == null) continue;
                                        String cn = subj.optString("name_cn", "");
                                        String name =
                                                cn.isEmpty() ? subj.optString("name", "") : cn;
                                        JSONObject images = subj.optJSONObject("images");
                                        String pic =
                                                images == null
                                                        ? ""
                                                        : images.optString(
                                                                "common",
                                                                images.optString("medium", ""));
                                        int epStatus = item.optInt("ep_status", 0);
                                        int epsTotal = subj.optInt("eps", 0);
                                        String sub =
                                                "已看 "
                                                        + epStatus
                                                        + (epsTotal > 0 ? (" / " + epsTotal) : "")
                                                        + " 话";
                                        out.add(
                                                new CalendarEntry(
                                                        todayWeekday(),
                                                        name,
                                                        sub,
                                                        pic,
                                                        subj.optDouble("score", 0.0),
                                                        "Bangumi 在看"));
                                    }
                                }
                            }
                        } catch (Exception ignored) {
                        }
                    }

                    // 3. Weekly broadcast schedule from Bangumi /calendar
                    try {
                        String raw =
                                TmdbService.httpGet(
                                        "https://api.bgm.tv/calendar", Collections.emptyMap());
                        if (raw != null && raw.startsWith("[")) {
                            JSONArray days = new JSONArray(raw);
                            for (int d = 0; d < days.length(); d++) {
                                JSONObject dayObj = days.getJSONObject(d);
                                JSONObject wk = dayObj.optJSONObject("weekday");
                                int dayId = wk == null ? (d + 1) : wk.optInt("id", d + 1);
                                JSONArray items = dayObj.optJSONArray("items");
                                if (items == null) continue;
                                for (int i = 0; i < Math.min(12, items.length()); i++) {
                                    JSONObject it = items.getJSONObject(i);
                                    String cn = it.optString("name_cn", "").trim();
                                    String name =
                                            cn.isEmpty() ? it.optString("name", "").trim() : cn;
                                    if (name.isEmpty()) continue;
                                    JSONObject images = it.optJSONObject("images");
                                    String pic =
                                            images == null
                                                    ? ""
                                                    : images.optString(
                                                            "common",
                                                            images.optString("medium", ""));
                                    JSONObject rating = it.optJSONObject("rating");
                                    double score =
                                            rating == null ? 0.0 : rating.optDouble("score", 0.0);
                                    out.add(
                                            new CalendarEntry(
                                                    dayId,
                                                    name,
                                                    it.optString("air_date", "连载更新中"),
                                                    pic,
                                                    score,
                                                    "每日放送"));
                                }
                            }
                        }
                    } catch (Exception e) {
                        AppLog.w("TrackingRating", "calendar fetch failed", e);
                    }

                    a.ui.post(
                            () -> {
                                if (!a.isFinishing() && ticket == a.generation) {
                                    callback.onResult(out);
                                }
                            });
                });
    }

    static int todayWeekday() {
        int dow = Calendar.getInstance().get(Calendar.DAY_OF_WEEK);
        return dow == Calendar.SUNDAY ? 7 : (dow - 1);
    }
}
