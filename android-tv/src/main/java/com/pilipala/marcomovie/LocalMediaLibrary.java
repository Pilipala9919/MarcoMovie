// Copyright (C) 2026 Pilipala
// SPDX-License-Identifier: GPL-3.0-only
package com.pilipala.marcomovie;

import android.content.Context;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

/**
 * Local USB hard drive media library: smart movie/series grouping, Kodi/Emby {@code .nfo} parsing,
 * integration with {@link TvSeriesScraper}, conversion into standard {@link Cms.Video} objects for
 * native playback/detail screens, and atomic JSON disk cache.
 */
final class LocalMediaLibrary {
    static final String LOCAL_SITE_KEY = "local_drive";
    private static final String CACHE_FILE = "local-drive-library-v1.json";

    private static final Pattern SEASON_DIR_PATTERN =
            Pattern.compile(
                    "(?i)^(?:season\\s*\\d{1,2}|s0*\\d{1,2}|第\\s*[0-9一二三四五六七八九十]+\\s*季|specials?)$");
    private static final Pattern YEAR_PATTERN =
            Pattern.compile("(?<![0-9])(19[4-9]\\d|20[0-3]\\d)(?![0-9])");
    private static final Pattern RELEASE_SPLIT_PATTERN =
            Pattern.compile(
                    "(?i)(?:[.\\s_\\-\\[\\(](?:2160p|1080p|720p|480p|4k|8k|hdr|hdr10|dv|dovi|web-?dl|webrip|bluray|blu-?ray|bdrip|remux|h\\.?265|h\\.?264|x\\.?265|x\\.?264|hevc|avc|aac|ddp|dts|atmos|60fps|10bit|国语|粤语|中字|双语|complete|s0*\\d{1,2}e0*\\d{1,3}).*$)");
    private static final Pattern NFO_TITLE =
            Pattern.compile("(?is)<title>\\s*([^<]+?)\\s*</title>");
    private static final Pattern NFO_YEAR = Pattern.compile("(?is)<year>\\s*(\\d{4})\\s*</year>");
    private static final Pattern NFO_PLOT = Pattern.compile("(?is)<plot>\\s*([^<]+?)\\s*</plot>");
    private static final Pattern NFO_RATING =
            Pattern.compile("(?is)<rating>\\s*([0-9.]+)\\s*</rating>");

    static final class LocalEpisode {
        final String name;
        final String uri;
        final long sizeBytes;
        final int season;
        final int episodeNumber;
        final List<String> subtitleUris;

        LocalEpisode(
                String name,
                String uri,
                long sizeBytes,
                int season,
                int episodeNumber,
                List<String> subtitleUris) {
            this.name = name == null ? "" : name;
            this.uri = uri == null ? "" : uri;
            this.sizeBytes = Math.max(0L, sizeBytes);
            this.season = season;
            this.episodeNumber = episodeNumber;
            this.subtitleUris =
                    subtitleUris == null ? Collections.<String>emptyList() : subtitleUris;
        }
    }

    static final class LocalVideoItem {
        String id = "";
        String driveId = "";
        String driveLabel = "";
        String folderPath = "";
        String title = "";
        String rawTitle = "";
        boolean isSeries;
        String posterUrl = "";
        String backdropUrl = "";
        String year = "";
        String synopsis = "";
        double doubanScore;
        String remarks = "";
        boolean scrapedOnline;
        long lastModified;
        final List<LocalEpisode> episodes = new ArrayList<>();

        Cms.Video toCmsVideo() {
            Cms.Video v = new Cms.Video();
            v.id = id;
            v.title = title.isEmpty() ? rawTitle : title;
            v.poster = posterUrl;
            v.year = year;
            v.description = synopsis;
            v.tag = isSeries ? "本地剧集" : "本地电影";
            v.remarks = remarks;
            if (doubanScore > 0.1) {
                v.doubanScore = String.format(Locale.US, "%.1f", doubanScore);
            }
            Cms.Line line = new Cms.Line();
            line.name = driveLabel.isEmpty() ? "移动硬盘" : driveLabel;
            for (LocalEpisode ep : episodes) {
                Cms.Episode ce = new Cms.Episode();
                ce.name = ep.name;
                ce.url = ep.uri;
                if (!ep.subtitleUris.isEmpty()) {
                    try {
                        JSONArray subArr = new JSONArray();
                        int limit = Math.min(6, ep.subtitleUris.size());
                        for (int i = 0; i < limit; i++) {
                            String subUri = ep.subtitleUris.get(i);
                            if (subUri == null || subUri.trim().isEmpty()) continue;
                            String displayName = subDisplayName(subUri);
                            String langBucket =
                                    SubtitlePreferenceStore.detectLangBucket(displayName);
                            String lang = langBucket.startsWith("zh") ? "zh" : "und";
                            subArr.put(
                                    new JSONObject()
                                            .put("name", "本地字幕 · " + displayName)
                                            .put("url", subUri)
                                            .put("language", lang));
                        }
                        if (subArr.length() > 0) {
                            ce.media.put("subtitles", subArr);
                        }
                    } catch (JSONException ignored) {
                    }
                }
                line.episodes.add(ce);
            }
            v.lines.add(line);
            return v;
        }
    }

    private LocalMediaLibrary() {}

    static Cms.Site localSite(String driveLabel) {
        Cms.Site site = new Cms.Site();
        site.key = LOCAL_SITE_KEY;
        site.name =
                (driveLabel == null || driveLabel.trim().isEmpty()) ? "移动硬盘" : driveLabel.trim();
        site.api = "local://drive";
        site.type = 0;
        site.searchable = false;
        return site;
    }

    static boolean isSeasonFolderName(String name) {
        return name != null && SEASON_DIR_PATTERN.matcher(name.trim()).matches();
    }

    static String extractCleanMediaTitle(String raw) {
        if (raw == null) return "";
        String s = LocalDriveScanner.stripExtension(raw).trim();
        s = RELEASE_SPLIT_PATTERN.matcher(s).replaceFirst("");
        s = YEAR_PATTERN.matcher(s).replaceAll(" ");
        s = TvSeriesScraper.cleanWorkTitle(s);
        return s.isEmpty() ? LocalDriveScanner.stripExtension(raw).trim() : s;
    }

    static String extractYear(String raw) {
        if (raw == null) return "";
        Matcher m = YEAR_PATTERN.matcher(raw);
        String found = "";
        while (m.find()) found = m.group(1);
        return found;
    }

    static String detectQualityTag(String raw) {
        if (raw == null) return "";
        String lower = raw.toLowerCase(Locale.ROOT);
        if (lower.contains("2160p") || lower.contains("4k") || lower.contains("uhd")) return "4K";
        if (lower.contains("1080p") || lower.contains("fhd") || lower.contains("bluray"))
            return "1080P";
        if (lower.contains("720p")) return "720P";
        return "";
    }

    /**
     * Pure-JVM smart grouping of scanned USB files into Movies and TV Series:
     *
     * <ul>
     *   <li>Merges {@code Season 1 / S01 / 第一季} subfolders under their parent show directory.
     *   <li>Groups multi-episode series folders into a single {@link LocalVideoItem} with episodes
     *       sorted cleanly via {@link TvSeriesScraper}.
     *   <li>Keeps flat movie folders (multiple unrelated movie files without episode markers) as
     *       individual Movie poster cards.
     * </ul>
     */
    static List<LocalVideoItem> groupScannedFiles(
            List<LocalDriveScanner.ScannedFile> files, Map<String, LocalVideoItem> existingById) {
        if (files == null || files.isEmpty()) return Collections.emptyList();

        // Group by logical show/container bucket
        Map<String, List<LocalDriveScanner.ScannedFile>> buckets = new LinkedHashMap<>();
        for (LocalDriveScanner.ScannedFile f : files) {
            String bucketKey = resolveBucketKey(f);
            List<LocalDriveScanner.ScannedFile> list = buckets.get(bucketKey);
            if (list == null) {
                list = new ArrayList<>();
                buckets.put(bucketKey, list);
            }
            list.add(f);
        }

        List<LocalVideoItem> items = new ArrayList<>();
        for (Map.Entry<String, List<LocalDriveScanner.ScannedFile>> entry : buckets.entrySet()) {
            List<LocalDriveScanner.ScannedFile> group = entry.getValue();
            if (group.size() == 1) {
                items.add(buildSingleMovieItem(group.get(0), existingById));
            } else if (looksLikeSeriesBucket(group)) {
                items.add(buildSeriesItem(entry.getKey(), group, existingById));
            } else {
                // Flat movie folder: treat each file as an independent movie card!
                for (LocalDriveScanner.ScannedFile f : group) {
                    items.add(buildSingleMovieItem(f, existingById));
                }
            }
        }

        Collections.sort(
                items,
                new Comparator<LocalVideoItem>() {
                    @Override
                    public int compare(LocalVideoItem a, LocalVideoItem b) {
                        if (a.isSeries != b.isSeries) return a.isSeries ? -1 : 1;
                        return a.title.compareToIgnoreCase(b.title);
                    }
                });
        return items;
    }

    private static String resolveBucketKey(LocalDriveScanner.ScannedFile f) {
        if (isSeasonFolderName(f.folderName) && !f.parentFolderName.isEmpty()) {
            int lastSlash = Math.max(f.folderPath.lastIndexOf('/'), f.folderPath.lastIndexOf('\\'));
            if (lastSlash > 0) {
                return f.driveId + "::" + f.folderPath.substring(0, lastSlash);
            }
        }
        return f.driveId + "::" + f.folderPath;
    }

    private static boolean looksLikeSeriesBucket(List<LocalDriveScanner.ScannedFile> group) {
        int episodeMarked = 0;
        boolean insideSeasonDir = false;
        for (LocalDriveScanner.ScannedFile f : group) {
            if (isSeasonFolderName(f.folderName)) insideSeasonDir = true;
            if (TvSeriesScraper.extractEpisodeNumber(f.fileName) > 0
                    || TvSeriesScraper.isSpecialEpisode(f.fileName)) {
                episodeMarked++;
            }
        }
        if (insideSeasonDir) return true;
        return episodeMarked >= 2 && (episodeMarked * 2 >= group.size());
    }

    private static LocalVideoItem buildSingleMovieItem(
            LocalDriveScanner.ScannedFile f, Map<String, LocalVideoItem> existingById) {
        LocalVideoItem item = new LocalVideoItem();
        item.id = "local_" + shortHash(f.mediaUri);
        item.driveId = f.driveId;
        item.driveLabel = f.driveLabel;
        item.folderPath = f.folderPath;
        item.rawTitle = LocalDriveScanner.stripExtension(f.fileName);
        item.title = extractCleanMediaTitle(f.fileName);
        item.isSeries = false;
        item.year = extractYear(f.fileName);
        if (item.year.isEmpty()) item.year = extractYear(f.folderName);
        item.posterUrl = f.localPosterUri;
        item.backdropUrl = f.localFanartUri;
        item.lastModified = f.lastModified;

        String qual = detectQualityTag(f.fileName);
        String sizeStr = f.sizeBytes > 0 ? LocalDriveScanner.formatBytes(f.sizeBytes) : "";
        item.remarks =
                !qual.isEmpty() && !sizeStr.isEmpty()
                        ? (qual + " · " + sizeStr)
                        : (!qual.isEmpty() ? qual : sizeStr);

        item.episodes.add(
                new LocalEpisode(item.rawTitle, f.mediaUri, f.sizeBytes, -1, -1, f.subtitleUris));

        applyNfoMetadata(item, f.nfoPath);
        mergeCachedScrape(item, existingById);
        return item;
    }

    private static LocalVideoItem buildSeriesItem(
            String bucketKey,
            List<LocalDriveScanner.ScannedFile> group,
            Map<String, LocalVideoItem> existingById) {
        LocalDriveScanner.ScannedFile first = group.get(0);
        String showDirName =
                isSeasonFolderName(first.folderName) && !first.parentFolderName.isEmpty()
                        ? first.parentFolderName
                        : first.folderName;
        if (showDirName == null || showDirName.trim().isEmpty()) {
            showDirName = extractCleanMediaTitle(first.fileName);
        }

        LocalVideoItem item = new LocalVideoItem();
        item.id = "local_" + shortHash(bucketKey);
        item.driveId = first.driveId;
        item.driveLabel = first.driveLabel;
        item.folderPath = first.folderPath;
        item.rawTitle = showDirName.trim();
        item.title = extractCleanMediaTitle(showDirName);
        if (item.title.isEmpty()) item.title = item.rawTitle;
        item.isSeries = true;
        item.year = extractYear(showDirName);
        item.lastModified = first.lastModified;

        // Build Cms.Episode list so TvSeriesScraper can sort & normalize across all files
        List<Cms.Episode> rawEps = new ArrayList<>(group.size());
        String localPoster = "";
        String localFanart = "";
        String nfoPath = "";
        String bestQual = "";
        for (LocalDriveScanner.ScannedFile f : group) {
            if (f.lastModified > item.lastModified) item.lastModified = f.lastModified;
            if (localPoster.isEmpty() && !f.localPosterUri.isEmpty())
                localPoster = f.localPosterUri;
            if (localFanart.isEmpty() && !f.localFanartUri.isEmpty())
                localFanart = f.localFanartUri;
            if (nfoPath.isEmpty() && !f.nfoPath.isEmpty()) nfoPath = f.nfoPath;
            if (bestQual.isEmpty()) bestQual = detectQualityTag(f.fileName);
            Cms.Episode ce = new Cms.Episode();
            ce.name = LocalDriveScanner.stripExtension(f.fileName);
            ce.url = f.mediaUri;
            rawEps.add(ce);
        }
        item.posterUrl = localPoster;
        item.backdropUrl = localFanart;

        TvSeriesScraper.ScrapedLine scraped = TvSeriesScraper.scrapeLine(item.title, rawEps, null);
        List<Integer> order = scraped.orderedIndices(true, false, false);
        for (int idx : order) {
            LocalDriveScanner.ScannedFile f = group.get(idx);
            TvSeriesScraper.ScrapedEpisode se = scraped.atSourceIndex(idx);
            int s = se != null ? se.season : -1;
            int epNum = se != null ? se.episodeNumber : -1;
            item.episodes.add(
                    new LocalEpisode(
                            LocalDriveScanner.stripExtension(f.fileName),
                            f.mediaUri,
                            f.sizeBytes,
                            s,
                            epNum,
                            f.subtitleUris));
        }

        int epCount = scraped.regularCount > 0 ? scraped.regularCount : item.episodes.size();
        item.remarks =
                !bestQual.isEmpty()
                        ? (bestQual + " · 共 " + epCount + " 集")
                        : ("共 " + epCount + " 集");

        applyNfoMetadata(item, nfoPath);
        mergeCachedScrape(item, existingById);
        return item;
    }

    static void parseNfoInto(LocalVideoItem item, String nfoXml) {
        if (item == null || nfoXml == null || nfoXml.trim().isEmpty()) return;
        Matcher mt = NFO_TITLE.matcher(nfoXml);
        if (mt.find()) {
            String t = mt.group(1).trim();
            if (!t.isEmpty()) item.title = t;
        }
        Matcher my = NFO_YEAR.matcher(nfoXml);
        if (my.find()) item.year = my.group(1).trim();
        Matcher mp = NFO_PLOT.matcher(nfoXml);
        if (mp.find()) {
            String p = mp.group(1).trim();
            if (!p.isEmpty()) item.synopsis = p;
        }
        Matcher mr = NFO_RATING.matcher(nfoXml);
        if (mr.find()) {
            try {
                double r = Double.parseDouble(mr.group(1).trim());
                if (r > 0 && r <= 10.0) item.doubanScore = r;
            } catch (NumberFormatException ignored) {
            }
        }
    }

    private static void applyNfoMetadata(LocalVideoItem item, String nfoPath) {
        if (nfoPath == null || nfoPath.isEmpty()) return;
        File f = new File(nfoPath);
        if (!f.exists() || !f.canRead() || f.length() > 512 * 1024) return;
        try (FileInputStream in = new FileInputStream(f)) {
            byte[] data = new byte[(int) f.length()];
            int read = in.read(data);
            if (read > 0) {
                parseNfoInto(item, new String(data, 0, read, StandardCharsets.UTF_8));
            }
        } catch (Exception ignored) {
        }
    }

    private static void mergeCachedScrape(
            LocalVideoItem item, Map<String, LocalVideoItem> existingById) {
        if (existingById == null) return;
        LocalVideoItem prev = existingById.get(item.id);
        if (prev == null) return;
        if (item.posterUrl.isEmpty() && !prev.posterUrl.isEmpty()) item.posterUrl = prev.posterUrl;
        if (item.backdropUrl.isEmpty() && !prev.backdropUrl.isEmpty())
            item.backdropUrl = prev.backdropUrl;
        if (item.synopsis.isEmpty() && !prev.synopsis.isEmpty()) item.synopsis = prev.synopsis;
        if (item.year.isEmpty() && !prev.year.isEmpty()) item.year = prev.year;
        if (item.doubanScore <= 0.1 && prev.doubanScore > 0.1) item.doubanScore = prev.doubanScore;
        if (!prev.title.isEmpty() && prev.scrapedOnline) item.title = prev.title;
        item.scrapedOnline = prev.scrapedOnline;
    }

    static List<LocalVideoItem> loadCache(Context context) {
        if (context == null) return Collections.emptyList();
        File f = new File(context.getFilesDir(), CACHE_FILE);
        if (!f.exists() || !f.canRead() || f.length() > 8 * 1024 * 1024) {
            return Collections.emptyList();
        }
        try (FileInputStream in = new FileInputStream(f)) {
            byte[] buf = new byte[(int) f.length()];
            int read = in.read(buf);
            if (read <= 0) return Collections.emptyList();
            return parseLibraryJson(new String(buf, 0, read, StandardCharsets.UTF_8));
        } catch (Exception ignored) {
            return Collections.emptyList();
        }
    }

    static void saveCache(Context context, List<LocalVideoItem> items) {
        if (context == null || items == null) return;
        String json = serializeLibraryJson(items);
        File target = new File(context.getFilesDir(), CACHE_FILE);
        File tmp = new File(context.getFilesDir(), CACHE_FILE + ".tmp");
        try (FileOutputStream out = new FileOutputStream(tmp)) {
            out.write(json.getBytes(StandardCharsets.UTF_8));
            out.flush();
        } catch (Exception ignored) {
            return;
        }
        if (!tmp.renameTo(target)) {
            // Fallback overwrite on devices where rename over existing fails
            try (FileOutputStream out = new FileOutputStream(target)) {
                out.write(json.getBytes(StandardCharsets.UTF_8));
                out.flush();
            } catch (Exception ignored) {
            }
            tmp.delete();
        }
    }

    static String serializeLibraryJson(List<LocalVideoItem> items) {
        JSONArray arr = new JSONArray();
        if (items != null) {
            for (LocalVideoItem item : items) {
                try {
                    JSONObject o = new JSONObject();
                    o.put("id", item.id);
                    o.put("driveId", item.driveId);
                    o.put("driveLabel", item.driveLabel);
                    o.put("folderPath", item.folderPath);
                    o.put("title", item.title);
                    o.put("rawTitle", item.rawTitle);
                    o.put("isSeries", item.isSeries);
                    o.put("posterUrl", item.posterUrl);
                    o.put("backdropUrl", item.backdropUrl);
                    o.put("year", item.year);
                    o.put("synopsis", item.synopsis);
                    o.put("doubanScore", item.doubanScore);
                    o.put("remarks", item.remarks);
                    o.put("scrapedOnline", item.scrapedOnline);
                    o.put("lastModified", item.lastModified);
                    JSONArray eps = new JSONArray();
                    for (LocalEpisode ep : item.episodes) {
                        JSONObject eo = new JSONObject();
                        eo.put("name", ep.name);
                        eo.put("uri", ep.uri);
                        eo.put("sizeBytes", ep.sizeBytes);
                        eo.put("season", ep.season);
                        eo.put("episodeNumber", ep.episodeNumber);
                        if (!ep.subtitleUris.isEmpty()) {
                            JSONArray subs = new JSONArray();
                            for (String s : ep.subtitleUris) subs.put(s);
                            eo.put("subtitleUris", subs);
                        }
                        eps.put(eo);
                    }
                    o.put("episodes", eps);
                    arr.put(o);
                } catch (JSONException ignored) {
                }
            }
        }
        return arr.toString();
    }

    static List<LocalVideoItem> parseLibraryJson(String raw) {
        List<LocalVideoItem> out = new ArrayList<>();
        if (raw == null || raw.trim().isEmpty()) return out;
        try {
            JSONArray arr = new JSONArray(raw);
            for (int i = 0; i < arr.length(); i++) {
                JSONObject o = arr.optJSONObject(i);
                if (o == null) continue;
                LocalVideoItem item = new LocalVideoItem();
                item.id = o.optString("id", "");
                item.driveId = o.optString("driveId", "");
                item.driveLabel = o.optString("driveLabel", "");
                item.folderPath = o.optString("folderPath", "");
                item.title = o.optString("title", "");
                item.rawTitle = o.optString("rawTitle", "");
                item.isSeries = o.optBoolean("isSeries", false);
                item.posterUrl = o.optString("posterUrl", "");
                item.backdropUrl = o.optString("backdropUrl", "");
                item.year = o.optString("year", "");
                item.synopsis = o.optString("synopsis", "");
                item.doubanScore = o.optDouble("doubanScore", 0.0);
                item.remarks = o.optString("remarks", "");
                item.scrapedOnline = o.optBoolean("scrapedOnline", false);
                item.lastModified = o.optLong("lastModified", 0L);
                JSONArray eps = o.optJSONArray("episodes");
                if (eps != null) {
                    for (int j = 0; j < eps.length(); j++) {
                        JSONObject eo = eps.optJSONObject(j);
                        if (eo == null) continue;
                        List<String> subs = new ArrayList<>();
                        JSONArray sa = eo.optJSONArray("subtitleUris");
                        if (sa != null) {
                            for (int k = 0; k < sa.length(); k++) {
                                String su = sa.optString(k, "").trim();
                                if (!su.isEmpty()) subs.add(su);
                            }
                        }
                        item.episodes.add(
                                new LocalEpisode(
                                        eo.optString("name", ""),
                                        eo.optString("uri", ""),
                                        eo.optLong("sizeBytes", 0L),
                                        eo.optInt("season", -1),
                                        eo.optInt("episodeNumber", -1),
                                        subs));
                    }
                }
                if (!item.id.isEmpty() && !item.episodes.isEmpty()) {
                    out.add(item);
                }
            }
        } catch (JSONException ignored) {
        }
        return out;
    }

    private static String subDisplayName(String uri) {
        if (uri == null || uri.isEmpty()) return "外挂字幕";
        String decoded = uri;
        try {
            decoded = java.net.URLDecoder.decode(uri, "UTF-8");
        } catch (Exception ignored) {
        }
        int slash = Math.max(decoded.lastIndexOf('/'), decoded.lastIndexOf(':'));
        String tail =
                slash >= 0 && slash + 1 < decoded.length() ? decoded.substring(slash + 1) : decoded;
        return tail.trim().isEmpty() ? "外挂字幕" : tail.trim();
    }

    static String shortHash(String input) {
        try {
            MessageDigest md = MessageDigest.getInstance("SHA-256");
            byte[] digest =
                    md.digest((input == null ? "" : input).getBytes(StandardCharsets.UTF_8));
            StringBuilder sb = new StringBuilder(16);
            for (int i = 0; i < 8; i++) {
                sb.append(String.format(Locale.US, "%02x", digest[i] & 0xff));
            }
            return sb.toString();
        } catch (Exception ignored) {
            return Integer.toHexString((input == null ? "" : input).hashCode());
        }
    }
}
