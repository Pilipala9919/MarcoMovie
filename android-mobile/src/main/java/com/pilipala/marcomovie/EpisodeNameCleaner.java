package com.pilipala.marcomovie;

import java.util.Locale;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Pure-Java episode & media title purifier for messy CMS / netdisk filenames (strips promotional
 * watermarks, anti-harmony symbols, release codec tags, and normalizes {@code S01E12} / {@code 第 12
 * 集} while preserving optional size/quality badges).
 */
final class EpisodeNameCleaner {
    static final class CleanedEpisode {
        final String shortLabel;
        final String subtitle;
        final String specBadge;
        final int seasonNumber;
        final int episodeNumber;

        CleanedEpisode(
                String shortLabel,
                String subtitle,
                String specBadge,
                int seasonNumber,
                int episodeNumber) {
            this.shortLabel = shortLabel;
            this.subtitle = subtitle;
            this.specBadge = specBadge;
            this.seasonNumber = seasonNumber;
            this.episodeNumber = episodeNumber;
        }
    }

    private static final Pattern LEADING_BRACKET_BADGE =
            Pattern.compile("^\\[([^\\]]{1,24})\\]\\s*(.*)$");
    private static final Pattern SIZE_BADGE =
            Pattern.compile("(?i)(\\d+(?:\\.\\d+)?\\s*(?:GB|MB|GiB|MiB))");
    private static final Pattern QUALITY_BADGE =
            Pattern.compile(
                    "(?i)\\b(4K|2160P|1080P|720P|HDR10\\+?|HDR|DV|Dolby\\s*Vision|REMUX)\\b");
    private static final Pattern AD_BRACKETS =
            Pattern.compile(
                    "(?i)[\\[【(（][^\\]】)）]*(?:扫码|关注|公众号|防失联|群|资源|网盘|夸克|阿里|百度|UC|更新至|全\\d+集|免费|首发|福利|订阅|频道)[^\\]】)）]*[\\]】)）]");
    private static final Pattern EXTENSION =
            Pattern.compile("(?i)\\.(?:mkv|mp4|ts|flv|avi|mov|m3u8|webm|iso|rmvb)$");
    private static final Pattern SXX_EXX =
            Pattern.compile(
                    "(?i)(?:^|[^A-Za-z0-9])S(\\d{1,2})\\s*[.\\-_ ]?\\s*E(\\d{1,4})(?:[^0-9]|$)");
    private static final Pattern CN_SEASON_EP =
            Pattern.compile(
                    "(?:第\\s*([一二三四五六七八九十百零两\\d]{1,4})\\s*[季部]\\s*)?第\\s*([一二三四五六七八九十百零两\\d]{1,4})\\s*([集话期篇回])");
    private static final Pattern EP_TOKEN =
            Pattern.compile(
                    "(?i)(?:^|[.\\-_\\s\\[【(（])(?:EP?|Episode)\\s*0*(\\d{1,4})(?:[^0-9]|$)");
    private static final Pattern PURE_NUMBER = Pattern.compile("^0*(\\d{1,4})$");
    private static final Pattern CODEC_TAIL =
            Pattern.compile(
                    "(?i)[.\\-_\\s]+(?:2160p|1080p|720p|4k|web-?dl|webrip|bluray|bdrip|hdrip|remux|x264|x265|h264|h265|hevc|avc|10bit|8bit|hdr10\\+?|hdr|dv|ddp\\d*(?:\\.\\d+)?|aac\\d*(?:\\.\\d+)?|atmos|truehd|dts|flac|chs|cht|eng|mp4|mkv).*$");

    private EpisodeNameCleaner() {}

    static CleanedEpisode clean(String rawName, String seriesTitle, int fallbackEpNumber) {
        int fallback = Math.max(1, fallbackEpNumber);
        if (rawName == null || rawName.trim().isEmpty()) {
            return new CleanedEpisode("第 " + fallback + " 集", "", null, 1, fallback);
        }
        String s = rawName.trim();
        int nl = s.indexOf('\n');
        if (nl >= 0) s = s.substring(0, nl).trim();
        s = s.replace('\r', ' ').replaceAll("\\s+", " ").trim();

        String badge = null;
        Matcher leadBadge = LEADING_BRACKET_BADGE.matcher(s);
        if (leadBadge.matches()) {
            String candidate = leadBadge.group(1).trim();
            if (SIZE_BADGE.matcher(candidate).find() || QUALITY_BADGE.matcher(candidate).find()) {
                badge = candidate;
                s = leadBadge.group(2).trim();
            }
        }
        if (badge == null) {
            Matcher sizeM = SIZE_BADGE.matcher(s);
            Matcher qualM = QUALITY_BADGE.matcher(s);
            String sizePart =
                    sizeM.find() ? sizeM.group(1).toUpperCase(Locale.ROOT).replace(" ", "") : null;
            String qualPart = qualM.find() ? qualM.group(1).toUpperCase(Locale.ROOT) : null;
            if (sizePart != null && qualPart != null) badge = qualPart + " · " + sizePart;
            else if (sizePart != null) badge = sizePart;
            else if (qualPart != null) badge = qualPart;
        }

        // Strip promotional brackets and file extensions
        s = AD_BRACKETS.matcher(s).replaceAll(" ").trim();
        s = EXTENSION.matcher(s).replaceAll("").trim();
        // Strip anti-harmony separators inside CJK characters (e.g. 生%活*大*爆#炸 -> 生活大爆炸)
        s = s.replaceAll("(?<=[\\u4e00-\\u9fa5])[%*#^~_|]+(?=[\\u4e00-\\u9fa5])", "");

        // Deduplicate mirrored title ("E01 E01")
        if (s.length() > 8 && s.length() % 2 == 1) {
            int half = s.length() / 2;
            if (s.charAt(half) == ' '
                    && s.substring(0, half).equalsIgnoreCase(s.substring(half + 1))) {
                s = s.substring(0, half).trim();
            }
        }

        // Remove leading series title if repeated in episode filename
        if (seriesTitle != null && !seriesTitle.trim().isEmpty()) {
            String cleanSeries = cleanSearchTitle(seriesTitle);
            if (!cleanSeries.isEmpty()
                    && s.startsWith(cleanSeries)
                    && s.length() > cleanSeries.length()) {
                s = s.substring(cleanSeries.length()).replaceFirst("^[\\s·:：.\\-_—]+", "").trim();
            }
        }

        int season = 1;
        int ep = fallback;
        String unit = "集";
        boolean matchedEp = false;

        Matcher mSxx = SXX_EXX.matcher(s);
        if (mSxx.find()) {
            season = safeInt(mSxx.group(1), 1);
            ep = safeInt(mSxx.group(2), fallback);
            matchedEp = true;
            String after = s.substring(mSxx.end()).trim();
            after =
                    CODEC_TAIL
                            .matcher(after)
                            .replaceAll("")
                            .replaceFirst("^[\\s·:：.\\-_—]+", "")
                            .trim();
            String label =
                    season > 1
                            ? String.format(Locale.US, "S%02dE%02d", season, ep)
                            : ("第 " + ep + " 集");
            return new CleanedEpisode(label, sanitizeSubtitle(after), badge, season, ep);
        }

        Matcher mCn = CN_SEASON_EP.matcher(s);
        if (mCn.find()) {
            if (mCn.group(1) != null) season = parseChineseInt(mCn.group(1), 1);
            ep = parseChineseInt(mCn.group(2), fallback);
            unit = mCn.group(3);
            matchedEp = true;
            String after = s.substring(mCn.end()).trim();
            after =
                    CODEC_TAIL
                            .matcher(after)
                            .replaceAll("")
                            .replaceFirst("^[\\s·:：.\\-_—]+", "")
                            .trim();
            return new CleanedEpisode(
                    "第 " + ep + " " + unit, sanitizeSubtitle(after), badge, season, ep);
        }

        Matcher mEp = EP_TOKEN.matcher(s);
        if (mEp.find()) {
            ep = safeInt(mEp.group(1), fallback);
            matchedEp = true;
            String after = s.substring(mEp.end()).trim();
            after =
                    CODEC_TAIL
                            .matcher(after)
                            .replaceAll("")
                            .replaceFirst("^[\\s·:：.\\-_—]+", "")
                            .trim();
            return new CleanedEpisode("第 " + ep + " 集", sanitizeSubtitle(after), badge, season, ep);
        }

        Matcher mNum = PURE_NUMBER.matcher(s);
        if (mNum.matches()) {
            ep = safeInt(mNum.group(1), fallback);
            return new CleanedEpisode("第 " + ep + " 集", "", badge, 1, ep);
        }

        s = CODEC_TAIL.matcher(s).replaceAll("").trim();
        s = s.replaceAll("^[.\\-_\\s]+|[.\\-_\\s]+$", "").trim();
        if (s.isEmpty() || (!matchedEp && s.length() > 26)) {
            return new CleanedEpisode(
                    "第 " + fallback + " 集", s.length() <= 32 ? s : "", badge, 1, fallback);
        }
        return new CleanedEpisode(s, "", badge, 1, fallback);
    }

    /** Purifies a search or scraped media title by stripping brackets, codecs, and harmony noise. */
    static String cleanSearchTitle(String rawTitle) {
        if (rawTitle == null) return "";
        String t = rawTitle.trim();
        t = AD_BRACKETS.matcher(t).replaceAll(" ");
        t = t.replaceAll("(?<=[\\u4e00-\\u9fa5])[%*#^~_|]+(?=[\\u4e00-\\u9fa5])", "");
        t =
                t.replaceAll(
                        "(?i)\\s*[\\[【(（](?:4K|2160P|1080P|720P|HD|BD|国语|粤语|双语|中字|完结|全\\d*集|更新)[^\\]】)）]*[\\]】)）]",
                        "");
        t = CODEC_TAIL.matcher(t).replaceAll("");
        t = t.replaceAll("\\s+", " ").trim();
        return t.isEmpty() ? rawTitle.trim() : t;
    }

    private static String sanitizeSubtitle(String sub) {
        if (sub == null || sub.isEmpty()) return "";
        String s = sub.replaceAll("^[\\[【(（]\\s*|\\s*[\\]】)）]$", "").trim();
        if (s.length() > 28) s = s.substring(0, 28) + "…";
        if (s.matches("(?i)^(?:1080p|2160p|4k|hdr|mp4|mkv|h264|h265|web-?dl|chs|cht)+$")) {
            return "";
        }
        return s;
    }

    private static int safeInt(String raw, int fallback) {
        try {
            int v = Integer.parseInt(raw.trim());
            return v > 0 ? v : fallback;
        } catch (Exception ignored) {
            return fallback;
        }
    }

    static int parseChineseInt(String raw, int fallback) {
        if (raw == null || raw.trim().isEmpty()) return fallback;
        String s = raw.trim();
        try {
            int d = Integer.parseInt(s);
            if (d > 0) return d;
        } catch (NumberFormatException ignored) {
        }
        String digits = "零一二三四五六七八九";
        if ("十".equals(s) || "拾".equals(s)) return 10;
        if (s.contains("十") || s.contains("拾")) {
            String[] parts = s.split("[十拾]", -1);
            int tens = parts[0].isEmpty() ? 1 : Math.max(1, digits.indexOf(parts[0].charAt(0)));
            int ones =
                    (parts.length > 1 && !parts[1].isEmpty())
                            ? Math.max(0, digits.indexOf(parts[1].charAt(0)))
                            : 0;
            int val = tens * 10 + ones;
            return val > 0 ? val : fallback;
        }
        int acc = 0;
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            int idx = digits.indexOf(c);
            if (c == '两') idx = 2;
            if (idx >= 0) acc = acc * 10 + idx;
        }
        return acc > 0 ? acc : fallback;
    }
}
