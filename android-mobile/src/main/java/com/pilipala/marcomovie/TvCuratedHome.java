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
import java.util.Locale;
import java.util.Set;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import org.json.JSONArray;
import org.json.JSONObject;

/**
 * Source-independent curated TV Home recommendations (recent hot dramas & movies).
 *
 * <p>Metadata-only catalog from approved public Douban trending collections plus offline seeds.
 * Never bundles or provides playable stream URLs: selecting any title resolves playable lines
 * strictly from the user's own added sources.
 */
final class TvCuratedHome {
    static final String CURATED_SITE_KEY = "__tv_curated_home__";
    private static final String CACHE_FILE = "tv_curated_home_v1.json";
    private static final long CACHE_TTL_MS = 6L * 60L * 60L * 1000L;
    private static final Pattern YEAR_PATTERN = Pattern.compile("\\b((?:19|20)\\d{2})\\b");
    private static final Pattern SEASON_CN_PATTERN =
            Pattern.compile("第\\s*([一二三四五六七八九十\\d]+)\\s*季");
    private static final Pattern SEASON_EN_PATTERN =
            Pattern.compile("(?i)(?:season\\s*|s0?)(\\d{1,2})\\b");

    static final class Catalog {
        final List<Cms.Video> hero;
        final List<Cms.Video> hotDramas;
        final List<Cms.Video> hotMovies;
        final boolean live;

        Catalog(
                List<Cms.Video> hero,
                List<Cms.Video> hotDramas,
                List<Cms.Video> hotMovies,
                boolean live) {
            this.hero = Collections.unmodifiableList(hero);
            this.hotDramas = Collections.unmodifiableList(hotDramas);
            this.hotMovies = Collections.unmodifiableList(hotMovies);
            this.live = live;
        }
    }

    interface Listener {
        void onReady(Catalog catalog);
    }

    private static volatile Catalog memoryCatalog;
    private static volatile long memoryLoadedAtMs;
    private static volatile boolean fetchInFlight;

    private TvCuratedHome() {}

    static Cms.Site curatedSite() {
        Cms.Site s = new Cms.Site();
        s.key = CURATED_SITE_KEY;
        s.name = "近期热门";
        s.type = 1;
        s.api = "";
        s.searchable = false;
        return s;
    }

    static boolean isCuratedSite(Cms.Site site) {
        return site != null && CURATED_SITE_KEY.equals(site.key);
    }

    static Catalog peekOrSeed() {
        Catalog cached = memoryCatalog;
        if (cached != null && (!cached.hotDramas.isEmpty() || !cached.hotMovies.isEmpty())) {
            return cached;
        }
        return buildCatalog(seedDramas(), seedMovies(), false);
    }

    static void loadAsync(final MainActivity a, final Listener listener) {
        if (a == null || a.privateMode || a.isFinishing()) return;
        final long now = System.currentTimeMillis();
        Catalog mem = memoryCatalog;
        if (mem != null && mem.live && (now - memoryLoadedAtMs) < CACHE_TTL_MS) {
            if (listener != null) a.ui.post(() -> listener.onReady(mem));
            return;
        }
        if (listener != null) {
            final Catalog immediate = peekOrSeed();
            a.ui.post(() -> listener.onReady(immediate));
        }
        if (fetchInFlight) return;
        fetchInFlight = true;
        final File cacheFile = new File(a.getCacheDir(), CACHE_FILE);
        a.worker.execute(
                () -> {
                    try {
                        Catalog disk = readDiskCache(cacheFile, now);
                        if (disk != null) {
                            memoryCatalog = disk;
                            memoryLoadedAtMs = now;
                            if (listener != null && !a.isFinishing() && !a.privateMode) {
                                a.ui.post(() -> listener.onReady(disk));
                            }
                            return;
                        }
                        List<Cms.Video> dramas =
                                mergeCollections(
                                        new String[] {"tv_hot", "tv_domestic"},
                                        "https://m.douban.com/tv/",
                                        false,
                                        18);
                        List<Cms.Video> movies =
                                mergeCollections(
                                        new String[] {"movie_hot_gaia", "movie_showing"},
                                        "https://m.douban.com/movie/",
                                        true,
                                        18);
                        if (!dramas.isEmpty() || !movies.isEmpty()) {
                            List<Cms.Video> finalDramas = dramas.isEmpty() ? seedDramas() : dramas;
                            List<Cms.Video> finalMovies = movies.isEmpty() ? seedMovies() : movies;
                            Catalog fresh = buildCatalog(finalDramas, finalMovies, true);
                            memoryCatalog = fresh;
                            memoryLoadedAtMs = System.currentTimeMillis();
                            writeDiskCache(cacheFile, finalDramas, finalMovies, memoryLoadedAtMs);
                            learnCuratedTitles(a, finalDramas, finalMovies);
                            if (listener != null && !a.isFinishing() && !a.privateMode) {
                                a.ui.post(() -> listener.onReady(fresh));
                            }
                        }
                    } catch (Throwable ignored) {
                    } finally {
                        fetchInFlight = false;
                    }
                });
    }

    private static void learnCuratedTitles(
            MainActivity a, List<Cms.Video> dramas, List<Cms.Video> movies) {
        if (a == null || a.privateMode) return;
        List<String> titles = new ArrayList<>();
        for (Cms.Video v : dramas) if (v.title != null) titles.add(v.title);
        for (Cms.Video v : movies) if (v.title != null) titles.add(v.title);
        if (titles.isEmpty()) return;
        a.phoneticWork.execute(
                () -> {
                    try {
                        PhoneticSearchIndex idx = a.phonetic;
                        if (idx != null && !a.privateMode) idx.learnHotTitles(titles);
                    } catch (Throwable ignored) {
                    }
                });
    }

    private static List<Cms.Video> mergeCollections(
            String[] collections, String referer, boolean isMovie, int limit) {
        List<Cms.Video> out = new ArrayList<>();
        Set<String> seen = new LinkedHashSet<>();
        for (String col : collections) {
            String url =
                    "https://m.douban.com/rexxar/api/v2/subject_collection/"
                            + col
                            + "/items?start=0&count=24";
            String body = httpGet(url, referer);
            for (Cms.Video v : parseCollectionVideos(body, isMovie)) {
                String key = normalizeTitleForMatch(v.title);
                if (!key.isEmpty() && seen.add(key)) {
                    out.add(v);
                    if (out.size() >= limit) return out;
                }
            }
        }
        return out;
    }

    static List<Cms.Video> parseCollectionVideos(String json, boolean isMovie) {
        List<Cms.Video> out = new ArrayList<>();
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
                String title = HotTitleCatalog.cleanHotTitle(item.optString("title", ""));
                if (title.isEmpty() || !seen.add(title)) continue;

                Cms.Video v = new Cms.Video();
                String id = item.optString("id", "").trim();
                v.id =
                        id.isEmpty()
                                ? ("curated:" + (isMovie ? "m:" : "t:") + i)
                                : ("curated:" + id);
                v.title = title;

                JSONObject pic = item.optJSONObject("pic");
                if (pic != null) {
                    String large = pic.optString("large", "").trim();
                    String normal = pic.optString("normal", "").trim();
                    v.poster = !large.isEmpty() ? large : normal;
                }
                if (v.poster == null || v.poster.isEmpty()) {
                    JSONObject cover = item.optJSONObject("cover");
                    if (cover != null) v.poster = cover.optString("url", "").trim();
                }

                JSONObject rating = item.optJSONObject("rating");
                if (rating != null) {
                    double val = rating.optDouble("value", 0.0);
                    if (val > 0.5 && val < 9.95) {
                        v.doubanScore = String.format(Locale.US, "%.1f", val);
                    }
                }

                String cardSub = item.optString("card_subtitle", "").trim();
                String year = item.optString("year", "").trim();
                if (year.isEmpty() && !cardSub.isEmpty()) {
                    Matcher ym = YEAR_PATTERN.matcher(cardSub);
                    if (ym.find()) year = ym.group(1);
                }
                v.year = year;

                if (!cardSub.isEmpty()) {
                    String[] parts = cardSub.split("\\s*/\\s*");
                    int offset = 0;
                    if (parts.length > 0 && YEAR_PATTERN.matcher(parts[0].trim()).matches()) {
                        offset = 1;
                    }
                    if (parts.length > offset) {
                        v.area = deduplicateMetadataSegment(parts[offset], " / ", 2);
                    }
                    if (parts.length > offset + 1) {
                        v.genre = deduplicateMetadataSegment(parts[offset + 1], " ", 3);
                    }
                    if (parts.length > offset + 2) {
                        v.actor = parts[offset + 2].trim();
                    }
                }
                String desc = item.optString("description", "").trim();
                if (desc.isEmpty()) {
                    String info = item.optString("info", "").trim();
                    if (!info.isEmpty() && !looksLikeMetadataSubtitle(info)) {
                        desc = info;
                    }
                }
                if (looksLikeMetadataSubtitle(desc)) {
                    desc = "";
                }
                v.description = desc;

                String episodesInfo = item.optString("episodes_info", "").trim();
                if (!episodesInfo.isEmpty()) {
                    v.remarks = episodesInfo;
                } else if (v.doubanScore != null && !v.doubanScore.isEmpty()) {
                    v.remarks = "豆瓣 " + v.doubanScore;
                } else {
                    v.remarks = isMovie ? "热门电影" : "近期热剧";
                }
                v.tag = isMovie ? "电影" : "剧集";
                out.add(v);
            }
        } catch (Throwable ignored) {
        }
        return out;
    }

    static String deduplicateMetadataSegment(String raw, String sep, int maxItems) {
        if (raw == null || raw.trim().isEmpty()) return "";
        String[] tokens = raw.trim().split("[,，、/|;；\\s]+");
        java.util.LinkedHashSet<String> seen = new java.util.LinkedHashSet<>();
        StringBuilder out = new StringBuilder();
        int count = 0;
        for (String token : tokens) {
            String clean = token.trim();
            if (clean.isEmpty()) continue;
            if (!seen.add(ImmersivePoster.normalizeFactTokenKey(clean))) continue;
            if (out.length() > 0) out.append(sep);
            out.append(clean);
            if (++count >= maxItems) break;
        }
        return out.toString();
    }

    /**
     * Detects Douban's {@code card_subtitle} metadata strings (e.g. "2025 / 中国大陆 / 古装 权谋 / 演员")
     * so they are never shown a second time as synopsis below the metadata badges.
     */
    static boolean looksLikeMetadataSubtitle(String text) {
        if (text == null) return false;
        String trimmed = text.trim();
        if (trimmed.isEmpty()) return false;
        String[] slashes = trimmed.split("\\s*/\\s*");
        if (slashes.length >= 3 && trimmed.length() <= 140) {
            if (YEAR_PATTERN.matcher(slashes[0].trim()).matches()) {
                return true;
            }
            if (!trimmed.contains("。") && !trimmed.contains("！") && !trimmed.contains("？")) {
                return true;
            }
        }
        return false;
    }

    static Catalog buildCatalog(List<Cms.Video> dramas, List<Cms.Video> movies, boolean live) {
        List<Cms.Video> safeDramas = dramas == null ? Collections.emptyList() : dramas;
        List<Cms.Video> safeMovies = movies == null ? Collections.emptyList() : movies;
        List<Cms.Video> hero = new ArrayList<>();
        int maxHero = 6;
        int di = 0, mi = 0;
        while (hero.size() < maxHero && (di < safeDramas.size() || mi < safeMovies.size())) {
            if (di < safeDramas.size()) hero.add(safeDramas.get(di++));
            if (hero.size() < maxHero && mi < safeMovies.size()) hero.add(safeMovies.get(mi++));
        }
        return new Catalog(hero, safeDramas, safeMovies, live);
    }

    /** Normalized title key for matching curated titles against user-added CMS sources. */
    static String normalizeTitleForMatch(String raw) {
        if (raw == null) return "";
        String s = raw.trim().toLowerCase(Locale.ROOT);
        s = s.replaceAll("[\\[(（【][^\\])）】]{0,18}[\\])）】]", " ");
        s =
                s.replaceAll(
                        "(?i)\\b(4k|2160p|1080p|720p|hdr|dv|web-dl|bluray|remux|hd|tc|ts)\\b", " ");
        s = s.replaceAll("[\\s·・:：\\-_—~!！?？,，.。'\"《》<>]+", "");
        return s;
    }

    static int extractSeasonNumber(String title) {
        if (title == null || title.isEmpty()) return 0;
        Matcher cn = SEASON_CN_PATTERN.matcher(title);
        if (cn.find()) {
            String token = cn.group(1);
            switch (token) {
                case "一":
                    return 1;
                case "二":
                    return 2;
                case "三":
                    return 3;
                case "四":
                    return 4;
                case "五":
                    return 5;
                case "六":
                    return 6;
                case "七":
                    return 7;
                case "八":
                    return 8;
                case "九":
                    return 9;
                case "十":
                    return 10;
                default:
                    try {
                        return Integer.parseInt(token);
                    } catch (NumberFormatException ignored) {
                    }
            }
        }
        Matcher en = SEASON_EN_PATTERN.matcher(title);
        if (en.find()) {
            try {
                return Integer.parseInt(en.group(1));
            } catch (NumberFormatException ignored) {
            }
        }
        return 0;
    }

    static int extractYearInt(String raw) {
        if (raw == null || raw.isEmpty()) return 0;
        Matcher m = YEAR_PATTERN.matcher(raw);
        if (m.find()) {
            try {
                return Integer.parseInt(m.group(1));
            } catch (NumberFormatException ignored) {
            }
        }
        return 0;
    }

    /**
     * Scores how well a search result from a user-added source matches a curated title. Returns a
     * score <= 0 if the candidate does not plausibly match.
     */
    static int scoreSourceMatch(Cms.Video target, Cms.Video candidate) {
        if (target == null || candidate == null) return -100;
        if (ListingRoute.isRedirect(candidate.action, candidate.tag, candidate.id)) return -100;
        String tNorm = normalizeTitleForMatch(target.title);
        String cNorm = normalizeTitleForMatch(candidate.title);
        if (tNorm.isEmpty() || cNorm.isEmpty()) return -100;

        int score = 0;
        if (tNorm.equals(cNorm)) {
            score += 100;
        } else if (cNorm.startsWith(tNorm) || tNorm.startsWith(cNorm)) {
            int diff = Math.abs(cNorm.length() - tNorm.length());
            score += Math.max(40, 78 - diff * 5);
        } else if (cNorm.contains(tNorm)) {
            int diff = cNorm.length() - tNorm.length();
            score += Math.max(20, 60 - diff * 4);
        } else {
            return -50;
        }

        int tSeason = extractSeasonNumber(target.title);
        int cSeason = extractSeasonNumber(candidate.title);
        if (tSeason > 0 && cSeason > 0) {
            score += (tSeason == cSeason) ? 25 : -70;
        } else if (tSeason > 1 && cSeason == 0) {
            score -= 35;
        } else if (tSeason == 0 && cSeason > 1) {
            score -= 35;
        }

        int tYear = extractYearInt(target.year);
        int cYear = extractYearInt(candidate.year);
        if (tYear > 0 && cYear > 0) {
            int gap = Math.abs(tYear - cYear);
            if (gap == 0) score += 20;
            else if (gap == 1) score += 8;
            else if (gap >= 3) score -= 24;
        }

        String rem = (candidate.remarks == null ? "" : candidate.remarks).toUpperCase(Locale.ROOT);
        if (rem.contains("4K")
                || rem.contains("2160")
                || rem.contains("原画")
                || rem.contains("HDR")) {
            score += 10;
        } else if (rem.contains("1080") || rem.contains("蓝光") || rem.contains("高清")) {
            score += 4;
        }
        return score;
    }

    private static Cms.Video makeSeed(
            String id,
            String title,
            String year,
            String area,
            String genre,
            String score,
            String desc,
            boolean movie) {
        Cms.Video v = new Cms.Video();
        v.id = id;
        v.title = title;
        v.year = year;
        v.area = area;
        v.genre = genre;
        v.doubanScore = score;
        v.remarks = score != null && !score.isEmpty() ? ("豆瓣 " + score) : (movie ? "热门电影" : "近期热剧");
        v.description = desc;
        v.tag = movie ? "电影" : "剧集";
        return v;
    }

    static List<Cms.Video> seedDramas() {
        List<Cms.Video> list = new ArrayList<>();
        list.add(
                makeSeed(
                        "curated:seed:t1",
                        "漫长的季节",
                        "2023",
                        "中国大陆",
                        "剧情 / 悬疑",
                        "9.4",
                        "小城桦林跨越二十年的命运纠葛，几位老友在秋天重新追寻尘封真相。",
                        false));
        list.add(
                makeSeed(
                        "curated:seed:t2",
                        "山花烂漫时",
                        "2024",
                        "中国大陆",
                        "剧情 / 传记",
                        "9.6",
                        "根据张桂梅校长真实事迹改编，讲述大山深处创办免费女子高中的动人故事。",
                        false));
        list.add(
                makeSeed(
                        "curated:seed:t3",
                        "我的阿勒泰",
                        "2024",
                        "中国大陆",
                        "剧情 / 治愈",
                        "8.9",
                        "生长在阿勒泰的汉族少女与牧民少年在辽阔草原间寻找自我与远方。",
                        false));
        list.add(
                makeSeed(
                        "curated:seed:t4",
                        "繁花",
                        "2023",
                        "中国大陆",
                        "剧情 / 爱情",
                        "8.7",
                        "九十年代初上海黄河路商海沉浮，阿宝在时代浪潮中历经风华与起伏。",
                        false));
        list.add(
                makeSeed(
                        "curated:seed:t5",
                        "唐朝诡事录之西行",
                        "2024",
                        "中国大陆",
                        "古装 / 悬疑",
                        "8.6",
                        "卢凌风与苏无名一行西行探案，揭开大唐盛世之下层层诡谲迷案。",
                        false));
        list.add(
                makeSeed(
                        "curated:seed:t6",
                        "三体",
                        "2023",
                        "中国大陆",
                        "科幻 / 悬疑",
                        "8.7",
                        "纳米科学家汪淼与刑警史强联手调查科学界异象，揭开外星文明降临危机。",
                        false));
        return list;
    }

    static List<Cms.Video> seedMovies() {
        List<Cms.Video> list = new ArrayList<>();
        list.add(
                makeSeed(
                        "curated:seed:m1",
                        "奥本海默",
                        "2023",
                        "美国",
                        "剧情 / 传记 / 历史",
                        "8.8",
                        "克里斯托弗·诺兰执导，聚焦理论物理学家奥本海默主导曼哈顿计划的人生抉择。",
                        true));
        list.add(
                makeSeed(
                        "curated:seed:m2",
                        "沙丘2",
                        "2024",
                        "美国",
                        "科幻 / 冒险 / 动作",
                        "8.2",
                        "保罗·厄崔迪与弗雷曼人联手反击哈克南家族，在命运与复仇之间做出抉择。",
                        true));
        list.add(
                makeSeed(
                        "curated:seed:m3",
                        "星际穿越",
                        "2014",
                        "美国",
                        "科幻 / 冒险 / 剧情",
                        "9.4",
                        "穿越虫洞的深空远征，父爱与时间相对论交织的太空史诗。",
                        true));
        list.add(
                makeSeed(
                        "curated:seed:m4",
                        "周处除三害",
                        "2023",
                        "中国台湾",
                        "动作 / 犯罪",
                        "8.1",
                        "通缉犯陈桂林决心在生命最后阶段清除榜上头号与二号恶徒。",
                        true));
        list.add(
                makeSeed(
                        "curated:seed:m5",
                        "流浪地球2",
                        "2023",
                        "中国大陆",
                        "科幻 / 冒险 / 灾难",
                        "8.3",
                        "太阳危机初现，人类启动移山计划与数字生命之争的前传史诗。",
                        true));
        list.add(
                makeSeed(
                        "curated:seed:m6",
                        "荒野机器人",
                        "2024",
                        "美国",
                        "动画 / 科幻 / 冒险",
                        "8.0",
                        "流落荒岛的机器人萝斯学会适应自然并抚养一只孤儿雏雁。",
                        true));
        return list;
    }

    private static Catalog readDiskCache(File file, long now) {
        if (file == null || !file.isFile() || file.length() > 1024 * 1024) return null;
        try (InputStream in = new FileInputStream(file);
                ByteArrayOutputStream bos = new ByteArrayOutputStream()) {
            byte[] buf = new byte[4096];
            int n;
            while ((n = in.read(buf)) != -1) bos.write(buf, 0, n);
            JSONObject obj = new JSONObject(new String(bos.toByteArray(), StandardCharsets.UTF_8));
            long savedAt = obj.optLong("savedAt", 0L);
            if (savedAt <= 0L || (now - savedAt) >= CACHE_TTL_MS) return null;
            List<Cms.Video> dramas = readVideosArray(obj.optJSONArray("dramas"));
            List<Cms.Video> movies = readVideosArray(obj.optJSONArray("movies"));
            if (dramas.isEmpty() && movies.isEmpty()) return null;
            return buildCatalog(
                    dramas.isEmpty() ? seedDramas() : dramas,
                    movies.isEmpty() ? seedMovies() : movies,
                    true);
        } catch (Throwable ignored) {
            return null;
        }
    }

    private static List<Cms.Video> readVideosArray(JSONArray arr) {
        List<Cms.Video> out = new ArrayList<>();
        if (arr == null) return out;
        for (int i = 0; i < arr.length(); i++) {
            JSONObject o = arr.optJSONObject(i);
            if (o == null) continue;
            Cms.Video v = new Cms.Video();
            v.id = o.optString("id", "");
            v.title = o.optString("title", "");
            v.poster = o.optString("poster", "");
            v.year = o.optString("year", "");
            v.area = o.optString("area", "");
            v.genre = o.optString("genre", "");
            v.actor = o.optString("actor", "");
            v.doubanScore = o.optString("doubanScore", "");
            v.remarks = o.optString("remarks", "");
            v.description = o.optString("description", "");
            v.tag = o.optString("tag", "");
            if (!v.title.isEmpty()) out.add(v);
        }
        return out;
    }

    private static void writeDiskCache(
            File file, List<Cms.Video> dramas, List<Cms.Video> movies, long savedAt) {
        if (file == null) return;
        try {
            JSONObject obj = new JSONObject();
            obj.put("savedAt", savedAt);
            obj.put("dramas", toJsonArray(dramas));
            obj.put("movies", toJsonArray(movies));
            try (FileOutputStream fos = new FileOutputStream(file)) {
                fos.write(obj.toString().getBytes(StandardCharsets.UTF_8));
            }
        } catch (Throwable ignored) {
        }
    }

    private static JSONArray toJsonArray(List<Cms.Video> list) {
        JSONArray arr = new JSONArray();
        if (list == null) return arr;
        for (Cms.Video v : list) {
            try {
                JSONObject o = new JSONObject();
                o.put("id", v.id == null ? "" : v.id);
                o.put("title", v.title == null ? "" : v.title);
                o.put("poster", v.poster == null ? "" : v.poster);
                o.put("year", v.year == null ? "" : v.year);
                o.put("area", v.area == null ? "" : v.area);
                o.put("genre", v.genre == null ? "" : v.genre);
                o.put("actor", v.actor == null ? "" : v.actor);
                o.put("doubanScore", v.doubanScore == null ? "" : v.doubanScore);
                o.put("remarks", v.remarks == null ? "" : v.remarks);
                o.put("description", v.description == null ? "" : v.description);
                o.put("tag", v.tag == null ? "" : v.tag);
                arr.put(o);
            } catch (Throwable ignored) {
            }
        }
        return arr;
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
                    "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1");
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
        } catch (Throwable ignored) {
            return null;
        } finally {
            if (conn != null) conn.disconnect();
        }
    }
}
