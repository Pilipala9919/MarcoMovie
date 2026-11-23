package com.pilipala.marcomovie;

import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.Objects;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Pure-JVM title, episode, and alternative-source matching logic for Watch History resume and
 * automatic cross-source failover.
 */
final class HistoryResumeMatcher {
    private static final Pattern SEASON_EP_PATTERN =
            Pattern.compile(
                    "(?i)(?:s|season\\s*)0*(\\d{1,2})\\s*[._\\-\\s]*e(?:p)?\\.?\\s*0*(\\d{1,4})");
    private static final Pattern EXPLICIT_EP_PATTERN =
            Pattern.compile(
                    "(?i)(?:第\\s*0*(\\d{1,4})\\s*[集话話回期]|(?:^|[^a-z0-9])ep?\\.?\\s*0*(\\d{1,4})(?:$|[^a-z0-9]))");
    private static final Pattern CN_EP_PATTERN =
            Pattern.compile("第\\s*([一二三四五六七八九十百零两兩]{1,5})\\s*[集话話回期]");
    private static final Pattern SEASON_ONLY_PATTERN =
            Pattern.compile(
                    "(?i)(?:第\\s*0*(\\d{1,2})\\s*季|第\\s*([一二三四五六七八九十]{1,3})\\s*季|season\\s*0*(\\d{1,2})|(?:^|[^a-z0-9])s0*(\\d{1,2})(?:$|[^a-z0-9]))");
    private static final Pattern NOISE_NUMBERS_PATTERN =
            Pattern.compile(
                    "(?i)(?:\\b(?:2160|1080|720|480|360)p\\b|\\b(?:4k|8k|2k|10bit|8bit|hdr10|dv|h264|h265|x264|x265|hevc|avc|aac|ac3|eac3|dts|ddp5\\.?1|5\\.1|7\\.1)\\b|\\b(?:19|20)\\d{2}\\b)");
    private static final Pattern LOOSE_NUMBER_PATTERN =
            Pattern.compile("(?:^|[^0-9])0*(\\d{1,4})(?:$|[^0-9])");
    private static final Pattern TITLE_CLEAN_PATTERN =
            Pattern.compile("[\\s\\p{Punct}·•—–：:，,。！？!？【】\\[\\]()（）《》<>「」『』]+");

    static final class EpisodeMatch {
        final Cms.Line line;
        final Cms.Episode episode;
        final int score;

        EpisodeMatch(Cms.Line line, Cms.Episode episode, int score) {
            this.line = line;
            this.episode = episode;
            this.score = score;
        }
    }

    private HistoryResumeMatcher() {}

    static int extractSeasonNumber(String text) {
        return TvSeriesScraper.extractSeasonNumber(text);
    }

    static int extractEpisodeNumber(String name) {
        return TvSeriesScraper.extractEpisodeNumber(name);
    }

    static boolean looksLikeMovieEpisode(String name) {
        if (name == null) return true;
        String lower = name.trim().toLowerCase(Locale.ROOT);
        if (lower.isEmpty()) return true;
        if (extractEpisodeNumber(lower) > 1) return false;
        return lower.contains("正片")
                || lower.contains("高清")
                || lower.contains("超清")
                || lower.contains("蓝光")
                || lower.contains("原画")
                || lower.contains("完整")
                || lower.contains("抢先")
                || lower.contains("中字")
                || lower.contains("国语")
                || lower.contains("粤语")
                || lower.contains("1080")
                || lower.contains("2160")
                || lower.contains("4k")
                || lower.contains("hd")
                || lower.contains("bd")
                || lower.contains("tc")
                || lower.contains("ts")
                || lower.contains("全集");
    }

    static EpisodeMatch matchEpisode(Cms.Video video, WatchHistory.Entry bookmark) {
        if (video == null || video.lines == null || video.lines.isEmpty()) return null;
        String bmLine = bookmark == null || bookmark.line == null ? "" : bookmark.line.trim();
        String bmEp = bookmark == null || bookmark.episode == null ? "" : bookmark.episode.trim();
        int bmIndex = bookmark == null ? 0 : Math.max(0, bookmark.index);
        int bmEpNum = extractEpisodeNumber(bmEp);
        int bmSeason = extractSeasonNumber(bmEp);
        boolean bmMovieLike = looksLikeMovieEpisode(bmEp) && bmIndex == 0;

        EpisodeMatch best = null;
        for (Cms.Line line : video.lines) {
            if (line == null || line.episodes == null || line.episodes.isEmpty()) continue;
            boolean sameLine = !bmLine.isEmpty() && bmLine.equalsIgnoreCase(line.name);
            int lineCount = line.episodes.size();
            int lineBonus = sameLine ? 25 : 0;
            if (!sameLine && lineCount > 1) {
                lineBonus += 4;
            }
            if (!sameLine && looksLikeNetdiskLineName(line.name)) {
                lineBonus -= 8;
            }

            for (int i = 0; i < lineCount; i++) {
                Cms.Episode ep = line.episodes.get(i);
                if (ep == null) continue;
                String candName = ep.name == null ? "" : ep.name.trim();
                int score = -1;

                // 1. Exact episode name match
                if (!bmEp.isEmpty() && bmEp.equalsIgnoreCase(candName)) {
                    score = 120 + lineBonus;
                } else {
                    // 2. Normalized episode number match (e.g. 第05集 <-> EP05 <-> S01E05 <-> 05)
                    int candNum = extractEpisodeNumber(candName);
                    if (bmEpNum > 0 && candNum == bmEpNum) {
                        score = 96 + lineBonus;
                        int candSeason = extractSeasonNumber(candName);
                        if (bmSeason > 0 && candSeason > 0) {
                            score += (bmSeason == candSeason) ? 10 : -45;
                        }
                    } else if (lineCount == 1 && (bmMovieLike || bmEp.isEmpty())) {
                        // 3. Single-stream movie match across sources
                        score = 82 + lineBonus;
                    } else if (bmIndex >= 0 && bmIndex == i && (lineCount > 1 || bmIndex == 0)) {
                        // 4. Positional index fallback
                        score = (sameLine ? 72 : 50) + lineBonus;
                    }
                }

                if (score >= 40 && (best == null || score > best.score)) {
                    best = new EpisodeMatch(line, ep, score);
                }
            }
        }

        if (best != null) return best;

        // Final safe fallback for single-item movie entries when source renamed everything.
        if (bmIndex == 0) {
            for (Cms.Line line : video.lines) {
                if (line != null && line.episodes != null && line.episodes.size() == 1) {
                    return new EpisodeMatch(line, line.episodes.get(0), 42);
                }
            }
        }
        return null;
    }

    static int scoreTitleMatch(WatchHistory.Entry entry, Cms.Video candidate) {
        if (entry == null || candidate == null) return 0;
        String rawTarget = entry.title == null ? "" : entry.title.trim();
        String rawCand = candidate.title == null ? "" : candidate.title.trim();
        if (rawTarget.isEmpty() || rawCand.isEmpty()) return 0;

        Cms.Video ref = new Cms.Video();
        ref.title = rawTarget;
        int base = TvCuratedHome.scoreSourceMatch(ref, candidate);

        String normTarget = normalizeTitle(rawTarget);
        String normCand = normalizeTitle(rawCand);
        if (!normTarget.isEmpty() && normTarget.equals(normCand)) {
            base = Math.max(base, 95);
        } else if (!normTarget.isEmpty()
                && !normCand.isEmpty()
                && (normCand.contains(normTarget) || normTarget.contains(normCand))) {
            int diff = Math.abs(normCand.length() - normTarget.length());
            if (diff <= 4) {
                base = Math.max(base, 78);
            }
        }

        int targetSeason = extractSeasonNumber(rawTarget);
        int candSeason = extractSeasonNumber(rawCand);
        if (targetSeason > 0 && candSeason > 0 && targetSeason != candSeason) {
            base -= 55;
        } else if ((targetSeason > 1 && candSeason <= 0) || (candSeason > 1 && targetSeason <= 0)) {
            base -= 35;
        }
        return Math.max(0, base);
    }

    static String normalizeTitle(String raw) {
        if (raw == null) return "";
        return TITLE_CLEAN_PATTERN.matcher(raw.trim().toLowerCase(Locale.ROOT)).replaceAll("");
    }

    static List<Cms.Site> rankAlternativeSites(
            List<Cms.Site> availableSearchableSites,
            String failedSiteKey,
            String preferredSiteKey,
            int maxCount) {
        List<Cms.Site> out = new ArrayList<>();
        if (availableSearchableSites == null
                || availableSearchableSites.isEmpty()
                || maxCount <= 0) {
            return out;
        }
        List<Cms.Site> preferred = new ArrayList<>();
        List<Cms.Site> light = new ArrayList<>();
        List<Cms.Site> standard = new ArrayList<>();
        List<Cms.Site> heavy = new ArrayList<>();

        for (Cms.Site site : availableSearchableSites) {
            if (site == null || site.key == null) continue;
            if (failedSiteKey != null && failedSiteKey.equals(site.key)) continue;
            if (SearchCoordinator.isSiteWedged(site.key)) continue;
            if (SourceController.isConfigOrNetdiskSite(site)) continue;
            if (preferredSiteKey != null && preferredSiteKey.equals(site.key)) {
                preferred.add(site);
            } else if (isFastSite(site)) {
                light.add(site);
            } else if (isHeavySite(site)) {
                heavy.add(site);
            } else {
                standard.add(site);
            }
        }
        appendUpTo(out, preferred, maxCount);
        appendUpTo(out, light, maxCount);
        appendUpTo(out, standard, maxCount);
        appendUpTo(out, heavy, maxCount);
        return out;
    }

    private static void appendUpTo(List<Cms.Site> dst, List<Cms.Site> src, int maxCount) {
        for (Cms.Site s : src) {
            if (dst.size() >= maxCount) return;
            boolean dup = false;
            for (Cms.Site existing : dst) {
                if (Objects.equals(existing.key, s.key)) {
                    dup = true;
                    break;
                }
            }
            if (!dup) dst.add(s);
        }
    }

    private static boolean isFastSite(Cms.Site site) {
        String api = site.api == null ? "" : site.api;
        return site.supported()
                || HttpT4Engine.eligible(site)
                || api.startsWith(com.pilipala.emby.EmbyLibrary.PREFIX)
                || api.startsWith(AlistEngine.PREFIX);
    }

    private static boolean isHeavySite(Cms.Site site) {
        String api = site.api == null ? "" : site.api;
        return api.startsWith("catpaw://")
                || DrpyEngine.eligible(site)
                || GuardEngine.eligible(site)
                || JsEngine.eligible(site);
    }

    private static boolean looksLikeNetdiskLineName(String lineName) {
        if (lineName == null) return false;
        String lower = lineName.toLowerCase(Locale.ROOT);
        return lower.contains("夸克")
                || lower.contains("夸父")
                || lower.contains("阿里")
                || lower.contains("百度")
                || lower.contains("摆渡")
                || lower.contains("天翼")
                || lower.contains("115")
                || lower.contains("uc")
                || lower.contains("网盘");
    }

    private static int parsePositiveInt(String text) {
        if (text == null || text.isEmpty()) return -1;
        try {
            int val = Integer.parseInt(text.trim());
            return val > 0 ? val : -1;
        } catch (Exception ignored) {
            return -1;
        }
    }

    private static int parseChineseNumeral(String cn) {
        if (cn == null || cn.isEmpty()) return -1;
        int total = 0;
        int current = 0;
        for (int i = 0; i < cn.length(); i++) {
            char c = cn.charAt(i);
            int d = chineseDigit(c);
            if (d >= 0) {
                current = d;
            } else if (c == '十') {
                total += (current == 0 ? 1 : current) * 10;
                current = 0;
            } else if (c == '百') {
                total += (current == 0 ? 1 : current) * 100;
                current = 0;
            } else {
                return -1;
            }
        }
        int result = total + current;
        return result > 0 ? result : -1;
    }

    private static int chineseDigit(char c) {
        switch (c) {
            case '零':
                return 0;
            case '一':
                return 1;
            case '二':
            case '两':
            case '兩':
                return 2;
            case '三':
                return 3;
            case '四':
                return 4;
            case '五':
                return 5;
            case '六':
                return 6;
            case '七':
                return 7;
            case '八':
                return 8;
            case '九':
                return 9;
            default:
                return -1;
        }
    }
}
