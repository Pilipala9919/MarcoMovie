// Copyright (C) 2026 Pilipala
// SPDX-License-Identifier: GPL-3.0-only
package com.pilipala.marcomovie;

import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Unified episode & series scraping engine for ALL Android TV media sources (subscription CMS,
 * CSP/JS/Python plugins, cloud drives, AList, Emby, and local USB hard drives).
 *
 * <p>Solves:
 *
 * <ul>
 *   <li>Misrecognized episode numbers caused by tech tags ({@code H.265}, {@code 1920x1080}, {@code
 *       60fps}, {@code DDP5.1}, {@code [1.8GB]}), franchise numerals ({@code 斗罗大陆2}), or leading
 *       specials ({@code 第0集}, {@code 先导片}, {@code 预告}, {@code SP/OVA/PV}).
 *   <li>Scrambled or lexicographically ordered episode lists ({@code 1, 10, 11, 2}) and
 *       multi-season flattened lines ({@code S01E01..S02E12}).
 *   <li>Mismatched Danmaku queries by supplying true scraped {@code (season, episodeNumber)},
 *       cleaned work titles, movie detection, work-form filtering, and user overrides.
 * </ul>
 */
final class TvSeriesScraper {

    enum WorkForm {
        REGULAR,
        MOTION_COMIC,
        AUDIO_BOOK,
        RECAP,
        GAME
    }

    static final class ScrapedEpisode {
        final int sourceIndex;
        final String rawName;
        final int season;
        final int episodeNumber;
        final int endEpisodeNumber;
        final boolean isSpecial;
        final String specialLabel;
        final String cleanDisplayLabel;
        final String episodeTitle;
        final boolean manualOverride;

        ScrapedEpisode(
                int sourceIndex,
                String rawName,
                int season,
                int episodeNumber,
                int endEpisodeNumber,
                boolean isSpecial,
                String specialLabel,
                String cleanDisplayLabel,
                String episodeTitle,
                boolean manualOverride) {
            this.sourceIndex = sourceIndex;
            this.rawName = rawName == null ? "" : rawName;
            this.season = season;
            this.episodeNumber = episodeNumber;
            this.endEpisodeNumber = endEpisodeNumber;
            this.isSpecial = isSpecial;
            this.specialLabel = specialLabel == null ? "" : specialLabel;
            this.cleanDisplayLabel = cleanDisplayLabel == null ? "" : cleanDisplayLabel;
            this.episodeTitle = episodeTitle == null ? "" : episodeTitle;
            this.manualOverride = manualOverride;
        }

        String displayText() {
            if (!episodeTitle.isEmpty() && episodeNumber > 0 && !isSpecial) {
                return cleanDisplayLabel + " · " + episodeTitle;
            }
            return cleanDisplayLabel.isEmpty() ? rawName : cleanDisplayLabel;
        }
    }

    static final class ScrapedLine {
        final List<ScrapedEpisode> episodes;
        final boolean sourceOrderScrambled;
        final boolean multiSeason;
        final int regularCount;
        final int specialCount;

        ScrapedLine(
                List<ScrapedEpisode> episodes,
                boolean sourceOrderScrambled,
                boolean multiSeason,
                int regularCount,
                int specialCount) {
            this.episodes = episodes;
            this.sourceOrderScrambled = sourceOrderScrambled;
            this.multiSeason = multiSeason;
            this.regularCount = regularCount;
            this.specialCount = specialCount;
        }

        ScrapedEpisode atSourceIndex(int sourceIndex) {
            if (sourceIndex < 0 || sourceIndex >= episodes.size()) return null;
            return episodes.get(sourceIndex);
        }

        /**
         * Returns non-mutating ordered source indices for UI rendering. Keeps raw array order when
         * {@code sortByScraped} is false, or sorts by {@code (isSpecial, season, episodeNumber,
         * sourceIndex)} when true.
         */
        List<Integer> orderedIndices(
                boolean sortByScraped, boolean hideSpecials, boolean descending) {
            List<ScrapedEpisode> filtered = new ArrayList<>(episodes.size());
            for (ScrapedEpisode ep : episodes) {
                if (hideSpecials && ep.isSpecial && regularCount > 0) continue;
                filtered.add(ep);
            }
            if (sortByScraped) {
                Collections.sort(
                        filtered,
                        new Comparator<ScrapedEpisode>() {
                            @Override
                            public int compare(ScrapedEpisode a, ScrapedEpisode b) {
                                if (a.isSpecial != b.isSpecial) {
                                    return a.isSpecial ? 1 : -1;
                                }
                                int sa = a.season > 0 ? a.season : 1;
                                int sb = b.season > 0 ? b.season : 1;
                                if (sa != sb) return Integer.compare(sa, sb);
                                boolean aHas = a.episodeNumber > 0;
                                boolean bHas = b.episodeNumber > 0;
                                if (aHas && bHas && a.episodeNumber != b.episodeNumber) {
                                    return Integer.compare(a.episodeNumber, b.episodeNumber);
                                }
                                if (aHas != bHas) return aHas ? -1 : 1;
                                return Integer.compare(a.sourceIndex, b.sourceIndex);
                            }
                        });
            }
            if (descending) {
                Collections.reverse(filtered);
            }
            List<Integer> indices = new ArrayList<>(filtered.size());
            for (ScrapedEpisode ep : filtered) {
                indices.add(ep.sourceIndex);
            }
            return indices;
        }
    }

    private static final Pattern SEASON_EP_RANGE_PATTERN =
            Pattern.compile(
                    "(?i)(?:s|season\\s*)0*(\\d{1,2})\\s*[._\\-\\s]*e(?:p)?\\.?\\s*0*(\\d{1,4})(?:\\s*[-~～]\\s*e?(?:p)?\\.?\\s*0*(\\d{1,4}))?");
    private static final Pattern CN_ARABIC_EP_PATTERN =
            Pattern.compile("第\\s*0*(\\d{1,4})(?:\\s*[-~～]\\s*0*(\\d{1,4}))?\\s*[集话話回期篇章]");
    private static final Pattern CN_NUMERAL_EP_PATTERN =
            Pattern.compile("第\\s*([一二三四五六七八九十百千零〇两兩]{1,6})\\s*[集话話回期篇章]");
    private static final Pattern EP_ZERO_PATTERN =
            Pattern.compile("(?i)(?:第\\s*0+\\s*[集话話回期]|(?:^|[^a-z0-9])ep?\\.?\\s*0+(?:$|[^0-9]))");
    private static final Pattern SPECIAL_KEYWORD_PATTERN =
            Pattern.compile(
                    "(?i)(?:(?:^|[^a-z0-9])(?:sp|ova|oad|pv|cm|op|ed|ncop|nced|extra|bonus|trailer|teaser|preview|behind|making)(?:\\s*\\d{0,3})(?:$|[^a-z0-9])|预告|先导|花絮|番外|特别篇|特典|总集篇|总集|幕后|彩蛋|片花|精编|定档|终极预告|主题曲|片头曲|片尾曲|小剧场|抢先看)");
    private static final Pattern SPECIAL_CODE_PATTERN =
            Pattern.compile(
                    "(?i)(?:^|[^a-z0-9])(sp|ova|oad|pv|op|ed)\\s*0*(\\d{1,2})?(?:$|[^a-z0-9])");
    private static final Pattern SEASON_ONLY_PATTERN =
            Pattern.compile(
                    "(?i)(?:第\\s*0*(\\d{1,2})\\s*季|第\\s*([一二三四五六七八九十两兩]{1,3})\\s*季|season\\s*0*(\\d{1,2})|(?:^|[^a-z0-9])s0*(\\d{1,2})(?:$|[^a-z0-9]))");
    private static final Pattern EXPLICIT_EP_PATTERN =
            Pattern.compile(
                    "(?i)(?:^|[^a-z0-9])ep?\\.?\\s*0*(\\d{1,4})(?:\\s*[-~～]\\s*e?p?\\.?\\s*0*(\\d{1,4}))?(?:$|[^a-z0-9])");
    private static final Pattern ATTACHED_EP_PATTERN =
            Pattern.compile(
                    "(?i)(?:[\\u4e00-\\u9fff_\\-.\\s])ep?\\.?\\s*0*(\\d{1,4})(?:$|[^a-z0-9])");
    private static final Pattern BRACKET_EP_PATTERN =
            Pattern.compile("[\\[【(（]\\s*(?:第)?0*(\\d{1,4})(?:\\s*[集话話完全])?\\s*[\\]】)）]");
    private static final Pattern VARIETY_DATE_PATTERN =
            Pattern.compile("(?:19|20)\\d{2}[.\\-/]?\\d{2}[.\\-/]?\\d{2}\\s*期?");
    private static final Pattern TECH_NOISE_PATTERN =
            Pattern.compile(
                    "(?i)(?:\\d{3,4}\\s*[xX×]\\s*\\d{3,4}|(?:2160|1440|1080|720|576|480|360)[pi]|(?:2k|4k|8k)|(?:8|10|12)\\s*bit|(?:24|25|30|48|50|60|120)\\s*(?:fps|帧|hz)|hdr10\\+?|hdr|sdr|dovi|dolby\\s*vision|atmos|dts(?:-?hd)?|truehd|ddp\\s*5\\.?1|ddp\\s*2\\.?0|dd\\+?\\s*5\\.?1|aac\\s*2\\.?0|ac3|eac3|flac|opus|5\\.1|7\\.1|2\\.0|h\\.?265|h\\.?264|x\\.?265|x\\.?264|hevc|avc|av1|vp9|web-?dl|webrip|bluray|blu-?ray|bdrip|remux|hq|uhd|fhd|hdrip|\\d+(?:\\.\\d+)?\\s*(?:gb|mb|kb|gib|mib)|(?:^|[^0-9])v[234](?:$|[^a-z0-9])|\\.(?:mkv|mp4|m4v|avi|mov|ts|m2ts|flv|rmvb|wmv|webm|mpg|mpeg|vob|iso|strm|m3u8|srt|ass|vtt))");
    private static final Pattern YEAR_PATTERN =
            Pattern.compile("(?<![0-9])(?:19[4-9]\\d|20[0-3]\\d)(?![0-9])");
    private static final Pattern LOOSE_NUMBER_PATTERN =
            Pattern.compile("(?<![0-9])0*(\\d{1,4})(?![0-9])");
    private static final Pattern TITLE_NOISE_TAGS =
            Pattern.compile(
                    "(?i)(?:[\\[【(（][^\\]】)）]*(?:4k|8k|2k|1080p|2160p|720p|hdr|杜比|高码|蓝光|原盘|国语|粤语|中字|双语|字幕|更新|全\\d+集|完结|连载|未删减|修正|高帧|60帧|120帧|hd|bd|tc|ts)[^\\]】)）]*[\\]】)）]|更新至?\\s*\\d+\\s*[集话期]?|全\\s*\\d+\\s*[集话期]|第\\s*\\d+\\s*集(?:完)?|国语中字|粤语中字|中英双字|蓝光原盘|4k高码|高清修复版|未删减版|完整版|抢先版|hd中字)");
    private static final Pattern COMPACT_CLEAN_PATTERN =
            Pattern.compile("[\\s\\p{Punct}·•—–：:，,。！？!？【】\\[\\]()（）《》<>「」『』]+");

    private TvSeriesScraper() {}

    static WorkForm detectWorkForm(String title) {
        if (title == null || title.trim().isEmpty()) return WorkForm.REGULAR;
        String lower = title.toLowerCase(Locale.ROOT);
        if (lower.contains("动态漫画") || lower.contains("动态漫") || lower.contains("有声漫画")) {
            return WorkForm.MOTION_COMIC;
        }
        if (lower.contains("有声书")
                || lower.contains("有声小说")
                || lower.contains("广播剧")
                || lower.contains("评书")) {
            return WorkForm.AUDIO_BOOK;
        }
        if (lower.contains("解说") || lower.contains("速看") || lower.contains("一口气看完")) {
            return WorkForm.RECAP;
        }
        if (lower.contains("游戏实况") || lower.contains("通关攻略") || lower.contains("全剧情流程")) {
            return WorkForm.GAME;
        }
        return WorkForm.REGULAR;
    }

    static String normalizeSequelNumerals(String raw) {
        if (raw == null) return "";
        return raw.replace("Ⅳ", "4").replace("Ⅲ", "3").replace("Ⅱ", "2").replace("Ⅰ", "1");
    }

    static String cleanWorkTitle(String raw) {
        if (raw == null) return "";
        String s = normalizeSequelNumerals(raw).replaceAll("[\\p{Cntrl}]+", " ").trim();
        s = TITLE_NOISE_TAGS.matcher(s).replaceAll(" ");
        s = YEAR_PATTERN.matcher(s).replaceAll(" ");
        s = s.replaceAll("\\s*[\\[【(（]\\s*[\\]】)）]\\s*", " ");
        s = s.replaceAll("[._]+", " ");
        s = s.replaceAll("\\s+", " ").trim();
        if (s.isEmpty()) {
            return raw.replaceAll("[\\p{Cntrl}]+", " ").replaceAll("\\s+", " ").trim();
        }
        return s;
    }

    static String normalizeCoreKey(String raw) {
        String cleaned = cleanWorkTitle(raw);
        return COMPACT_CLEAN_PATTERN
                .matcher(cleaned)
                .replaceAll("")
                .toLowerCase(Locale.ROOT)
                .trim();
    }

    static int extractSeasonNumber(String text) {
        if (text == null || text.trim().isEmpty()) return -1;
        String norm = normalizeSequelNumerals(text);
        Matcher se = SEASON_EP_RANGE_PATTERN.matcher(norm);
        if (se.find()) {
            return parsePositiveInt(se.group(1));
        }
        Matcher m = SEASON_ONLY_PATTERN.matcher(norm);
        if (m.find()) {
            if (m.group(1) != null) return parsePositiveInt(m.group(1));
            if (m.group(2) != null) return parseChineseNumeral(m.group(2));
            if (m.group(3) != null) return parsePositiveInt(m.group(3));
            if (m.group(4) != null) return parsePositiveInt(m.group(4));
        }
        return -1;
    }

    static boolean isSpecialEpisode(String raw) {
        if (raw == null || raw.trim().isEmpty()) return false;
        String s = raw.trim();
        if (EP_ZERO_PATTERN.matcher(s).find()) return true;
        // If string contains explicit SxxExx with positive episode, treat as regular unless clearly
        // trailer/PV
        if (SEASON_EP_RANGE_PATTERN.matcher(s).find()) {
            Matcher se = SEASON_EP_RANGE_PATTERN.matcher(s);
            if (se.find()) {
                int sNum = parsePositiveInt(se.group(1));
                int eNum = parsePositiveInt(se.group(2));
                if (sNum == 0 || eNum == 0) return true;
            }
        }
        return SPECIAL_KEYWORD_PATTERN.matcher(s).find();
    }

    static String extractSpecialLabel(String raw) {
        if (raw == null) return "特辑";
        String s = raw.trim();
        if (EP_ZERO_PATTERN.matcher(s).find()) return "第0集";
        Matcher code = SPECIAL_CODE_PATTERN.matcher(s);
        if (code.find()) {
            String tag = code.group(1).toUpperCase(Locale.ROOT);
            String num = code.group(2);
            if (num != null && !num.isEmpty()) {
                int v = parsePositiveInt(num);
                return v > 0 ? (tag + (v < 10 ? "0" + v : String.valueOf(v))) : tag;
            }
            return tag;
        }
        if (s.contains("先导")) return "先导片";
        if (s.contains("预告")) return "预告";
        if (s.contains("花絮")) return "花絮";
        if (s.contains("番外")) return "番外";
        if (s.contains("特别篇")) return "特别篇";
        if (s.contains("总集")) return "总集篇";
        if (s.contains("彩蛋")) return "彩蛋";
        return "特辑";
    }

    /**
     * Strips technical metadata, file extensions, resolution dimensions, years, and season tags so
     * loose number matching never mistakes {@code H.265}, {@code 60fps}, {@code 1920x1080}, {@code
     * 5.1}, {@code 2026}, or {@code S02} for an episode number.
     */
    static String stripTechNoise(String raw) {
        if (raw == null) return "";
        String s = TECH_NOISE_PATTERN.matcher(raw).replaceAll(" ");
        s = YEAR_PATTERN.matcher(s).replaceAll(" ");
        s = SEASON_ONLY_PATTERN.matcher(s).replaceAll(" ");
        return s;
    }

    /** Single-name episode number extraction (used by HistoryResumeMatcher & single-item callers). */
    static int extractEpisodeNumber(String rawName) {
        return extractEpisodeNumber(rawName, null);
    }

    static int extractEpisodeNumber(String rawName, Set<Integer> constantNumbers) {
        if (rawName == null) return -1;
        String trimmed = rawName.trim();
        if (trimmed.isEmpty()) return -1;
        if (isSpecialEpisode(trimmed)) return -1;

        Matcher se = SEASON_EP_RANGE_PATTERN.matcher(trimmed);
        if (se.find()) {
            int ep = parsePositiveInt(se.group(2));
            if (ep > 0) return ep;
        }

        Matcher cnAr = CN_ARABIC_EP_PATTERN.matcher(trimmed);
        if (cnAr.find()) {
            int ep = parsePositiveInt(cnAr.group(1));
            if (ep > 0) return ep;
        }

        Matcher cnNum = CN_NUMERAL_EP_PATTERN.matcher(trimmed);
        if (cnNum.find()) {
            int ep = parseChineseNumeral(cnNum.group(1));
            if (ep > 0) return ep;
        }

        String stripped = stripTechNoise(trimmed);

        Matcher exp = EXPLICIT_EP_PATTERN.matcher(stripped);
        if (exp.find()) {
            int ep = parsePositiveInt(exp.group(1));
            if (ep > 0) return ep;
        }

        Matcher att = ATTACHED_EP_PATTERN.matcher(stripped);
        if (att.find()) {
            int ep = parsePositiveInt(att.group(1));
            if (ep > 0) return ep;
        }

        Matcher br = BRACKET_EP_PATTERN.matcher(stripped);
        if (br.find()) {
            int ep = parsePositiveInt(br.group(1));
            if (ep > 0 && ep <= 2000) {
                return ep;
            }
        }

        // Strip variety date tokens like 20260315 so date digits aren't matched as episodes.
        String noDate = VARIETY_DATE_PATTERN.matcher(stripped).replaceAll(" ");
        Matcher loose = LOOSE_NUMBER_PATTERN.matcher(noDate);
        List<Integer> nums = new ArrayList<>();
        while (loose.find()) {
            int val = parsePositiveInt(loose.group(1));
            if (val > 0 && val <= 2000) {
                nums.add(val);
            }
        }
        if (nums.isEmpty()) return -1;
        if (nums.size() == 1) {
            int only = nums.get(0);
            if (constantNumbers != null && constantNumbers.contains(only)) {
                // Keep bare numeric labels like "02" or "2", suppress title-only strings like
                // "斗罗大陆2".
                boolean hasWordChars =
                        noDate.replaceAll("[0-9\\s\\p{Punct}_\\-]+", "").length() > 0;
                if (hasWordChars) return -1;
            }
            return only;
        }
        // Multiple numbers in the same episode name (e.g. "斗罗大陆2_02" -> [2, 2], "斗罗大陆2_01" -> [2,
        // 1]).
        // Suppress at most ONE (leftmost) occurrence of each franchise/constant number so Episode 2
        // of
        // a sequel show ("斗罗大陆2_02") preserves its second "2" as the real episode number.
        Set<Integer> consumedConstants = new HashSet<>();
        int found = -1;
        for (int val : nums) {
            if (constantNumbers != null
                    && constantNumbers.contains(val)
                    && !consumedConstants.contains(val)) {
                consumedConstants.add(val);
                continue;
            }
            found = val;
        }
        return found;
    }

    /**
     * Scrapes an entire line with cross-episode constant-number suppression (e.g. franchise numeral
     * {@code 2} in {@code 斗罗大陆2_01.mkv} .. {@code 斗罗大陆2_26.mkv}), special isolation, season
     * extraction, scrambled-order detection, and user override application.
     */
    static ScrapedLine scrapeLine(
            String seriesTitle,
            List<Cms.Episode> episodes,
            SeriesScrapeStore.OverrideRecord override) {
        if (episodes == null || episodes.isEmpty()) {
            return new ScrapedLine(Collections.<ScrapedEpisode>emptyList(), false, false, 0, 0);
        }

        Set<Integer> constantNumbers = computeConstantNumbers(seriesTitle, episodes);
        int seriesSeason = extractSeasonNumber(seriesTitle);
        int offset = override != null ? override.episodeOffset : 0;

        List<ScrapedEpisode> out = new ArrayList<>(episodes.size());
        Set<Integer> distinctSeasons = new HashSet<>();
        int regularCount = 0;
        int specialCount = 0;

        for (int i = 0; i < episodes.size(); i++) {
            Cms.Episode ep = episodes.get(i);
            String raw = ep != null && ep.name != null ? ep.name.trim() : "";

            Integer manualEp =
                    override != null && override.episodeNumberOverrides != null
                            ? override.episodeNumberOverrides.get(i)
                            : null;
            if (manualEp != null && manualEp > 0) {
                int season = extractSeasonNumber(raw);
                if (season <= 0) season = seriesSeason;
                if (season > 0) distinctSeasons.add(season);
                String officialTitle = lookupOfficialEpTitle(override, manualEp);
                regularCount++;
                out.add(
                        new ScrapedEpisode(
                                i,
                                raw,
                                season,
                                manualEp,
                                -1,
                                false,
                                "",
                                formatEpisodeBadge(season, manualEp, -1, false),
                                officialTitle,
                                true));
                continue;
            }

            boolean special = isSpecialEpisode(raw);
            if (special) {
                specialCount++;
                String spLabel = extractSpecialLabel(raw);
                out.add(
                        new ScrapedEpisode(
                                i, raw, seriesSeason, -1, -1, true, spLabel, spLabel, "", false));
                continue;
            }

            int season = extractSeasonNumber(raw);
            if (season <= 0) season = seriesSeason;
            int epNum = -1;
            int endEp = -1;

            Matcher se = SEASON_EP_RANGE_PATTERN.matcher(raw);
            if (se.find()) {
                int sFound = parsePositiveInt(se.group(1));
                int eFound = parsePositiveInt(se.group(2));
                int eEnd = se.group(3) != null ? parsePositiveInt(se.group(3)) : -1;
                if (sFound > 0) season = sFound;
                if (eFound > 0) epNum = eFound;
                if (eEnd > epNum && eEnd - epNum <= 6) endEp = eEnd;
            }
            if (epNum <= 0) {
                Matcher cnAr = CN_ARABIC_EP_PATTERN.matcher(raw);
                if (cnAr.find()) {
                    epNum = parsePositiveInt(cnAr.group(1));
                    int eEnd = cnAr.group(2) != null ? parsePositiveInt(cnAr.group(2)) : -1;
                    if (eEnd > epNum && eEnd - epNum <= 6) endEp = eEnd;
                }
            }
            if (epNum <= 0) {
                epNum = extractEpisodeNumber(raw, constantNumbers);
            }

            if (epNum > 0 && offset != 0) {
                epNum = Math.max(1, epNum + offset);
                if (endEp > 0) endEp = Math.max(epNum, endEp + offset);
            }
            if (season > 0 && epNum > 0) {
                distinctSeasons.add(season);
            }
            if (epNum > 0) {
                regularCount++;
            }

            String officialTitle = epNum > 0 ? lookupOfficialEpTitle(override, epNum) : "";
            out.add(
                    new ScrapedEpisode(
                            i, raw, season, epNum, endEp, false, "", raw, officialTitle, false));
        }

        boolean multiSeason = distinctSeasons.size() >= 2;
        List<ScrapedEpisode> finalized = new ArrayList<>(out.size());
        for (ScrapedEpisode item : out) {
            String cleanLabel;
            if (item.isSpecial) {
                cleanLabel = item.specialLabel;
            } else if (item.episodeNumber > 0) {
                cleanLabel =
                        formatEpisodeBadge(
                                item.season,
                                item.episodeNumber,
                                item.endEpisodeNumber,
                                multiSeason);
            } else {
                cleanLabel = item.rawName;
            }
            finalized.add(
                    new ScrapedEpisode(
                            item.sourceIndex,
                            item.rawName,
                            item.season,
                            item.episodeNumber,
                            item.endEpisodeNumber,
                            item.isSpecial,
                            item.specialLabel,
                            cleanLabel,
                            item.episodeTitle,
                            item.manualOverride));
        }

        boolean scrambled = detectScrambledOrder(finalized);
        return new ScrapedLine(finalized, scrambled, multiSeason, regularCount, specialCount);
    }

    /**
     * True when the raw episode array is out of order (e.g., lexicographic {@code 1, 10, 11, 2},
     * reversed {@code 40..1}, or specials intermixed before regular episodes).
     */
    private static boolean detectScrambledOrder(List<ScrapedEpisode> list) {
        if (list.size() < 2) return false;
        int prevSeason = -1;
        int prevEp = -1;
        int numbered = 0;
        boolean seenRegular = false;
        boolean leadingSpecial = false;
        for (ScrapedEpisode ep : list) {
            if (ep.isSpecial) {
                if (!seenRegular) leadingSpecial = true;
                continue;
            }
            if (ep.episodeNumber <= 0) continue;
            seenRegular = true;
            numbered++;
            int curSeason = ep.season > 0 ? ep.season : 1;
            if (prevEp > 0) {
                if (curSeason < prevSeason
                        || (curSeason == prevSeason && ep.episodeNumber < prevEp)) {
                    return true;
                }
            }
            prevSeason = curSeason;
            prevEp = ep.episodeNumber;
        }
        return leadingSpecial && numbered >= 2;
    }

    private static Set<Integer> computeConstantNumbers(
            String seriesTitle, List<Cms.Episode> episodes) {
        Set<Integer> constants = new HashSet<>();
        if (seriesTitle != null && !seriesTitle.trim().isEmpty()) {
            String titleNoNoise = stripTechNoise(normalizeSequelNumerals(seriesTitle));
            Matcher tm = LOOSE_NUMBER_PATTERN.matcher(titleNoNoise);
            while (tm.find()) {
                int v = parsePositiveInt(tm.group(1));
                if (v > 0 && v <= 99) constants.add(v);
            }
        }
        if (episodes.size() < 3) return constants;
        Map<Integer, Integer> docFreq = new HashMap<>();
        int nonEmpty = 0;
        for (Cms.Episode ep : episodes) {
            if (ep == null || ep.name == null || ep.name.trim().isEmpty()) continue;
            nonEmpty++;
            String cleaned = stripTechNoise(ep.name);
            Matcher m = LOOSE_NUMBER_PATTERN.matcher(cleaned);
            Set<Integer> seenInEp = new HashSet<>();
            int tokenCount = 0;
            while (m.find()) {
                int v = parsePositiveInt(m.group(1));
                if (v > 0 && v <= 2000) {
                    seenInEp.add(v);
                    tokenCount++;
                }
            }
            // Only mark numbers as constant if an episode actually has >= 2 number tokens
            // (including duplicates like "斗罗大陆2_02" -> [2, 2]).
            if (tokenCount >= 2) {
                for (Integer v : seenInEp) {
                    Integer prev = docFreq.get(v);
                    docFreq.put(v, prev == null ? 1 : prev + 1);
                }
            }
        }
        if (nonEmpty >= 3) {
            int threshold = (int) Math.ceil(nonEmpty * 0.80);
            for (Map.Entry<Integer, Integer> entry : docFreq.entrySet()) {
                if (entry.getValue() >= threshold) {
                    constants.add(entry.getKey());
                }
            }
        }
        return constants;
    }

    private static String lookupOfficialEpTitle(
            SeriesScrapeStore.OverrideRecord override, int epNum) {
        if (override == null || override.officialEpisodeTitles == null || epNum <= 0) return "";
        String t = override.officialEpisodeTitles.get(epNum);
        return t == null ? "" : t.trim();
    }

    static String formatEpisodeBadge(int season, int epNum, int endEp, boolean showSeason) {
        if (epNum <= 0) return "";
        String pEp = epNum < 10 ? "0" + epNum : String.valueOf(epNum);
        if (showSeason && season > 0) {
            String pS = season < 10 ? "0" + season : String.valueOf(season);
            if (endEp > epNum) {
                String pEnd = endEp < 10 ? "0" + endEp : String.valueOf(endEp);
                return "S" + pS + "E" + pEp + "-E" + pEnd;
            }
            return "S" + pS + "E" + pEp;
        }
        if (endEp > epNum) {
            String pEnd = endEp < 10 ? "0" + endEp : String.valueOf(endEp);
            return "第" + pEp + "-" + pEnd + "集";
        }
        return "第" + pEp + "集";
    }

    /**
     * Decides whether a raw episode name should be replaced on the TV episode grid with the crisp
     * scraped badge (true for release filenames, scrambled lists, manual overrides, or bound
     * official titles; false when the source already provides clean concise labels like {@code
     * 第01集} or custom chapter titles without release clutter).
     */
    static String formatGridEpisodeLabel(
            ScrapedEpisode scraped, boolean isBookmarked, boolean hasOverrideOrScrambled) {
        if (scraped == null) return "";
        String base = scraped.rawName;
        if (scraped.manualOverride || !scraped.episodeTitle.isEmpty()) {
            base = scraped.displayText();
        } else if (scraped.isSpecial) {
            base = scraped.rawName.length() > 14 ? scraped.specialLabel : scraped.rawName;
        } else if (scraped.episodeNumber > 0) {
            boolean noisyFilename =
                    scraped.rawName.length() > 14
                            || scraped.rawName.contains(".")
                            || TECH_NOISE_PATTERN.matcher(scraped.rawName).find();
            if (noisyFilename || hasOverrideOrScrambled) {
                base = scraped.cleanDisplayLabel;
            }
        }
        return isBookmarked ? ("● " + base) : base;
    }

    /**
     * Computes the exact episode number for Danmaku matching:
     *
     * <ul>
     *   <li>Returns {@code 0} for single-stream movies (preventing bogus {@code "Movie E01"}
     *       queries).
     *   <li>Returns the real scraped episode number (with {@code episodeOffset} and per-episode
     *       overrides applied) rather than the raw 1-based array index.
     *   <li>Falls back to 1-based regular-episode rank (excluding leading trailers/specials) only
     *       when no episode number could be extracted.
     * </ul>
     */
    static int resolveDanmuEpisodeNumber(
            String seriesTitle,
            List<Cms.Episode> episodes,
            int activeIndex,
            SeriesScrapeStore.OverrideRecord override) {
        if (episodes == null || episodes.isEmpty()) return 0;
        int safeIdx = Math.max(0, Math.min(activeIndex, episodes.size() - 1));
        Cms.Episode active = episodes.get(safeIdx);
        String rawName = active != null && active.name != null ? active.name.trim() : "";

        // Single-item movie detection
        if (episodes.size() == 1
                && (override == null
                        || (override.episodeOffset == 0
                                && (override.episodeNumberOverrides == null
                                        || override.episodeNumberOverrides.isEmpty())))
                && HistoryResumeMatcher.looksLikeMovieEpisode(rawName)
                && extractEpisodeNumber(rawName) <= 0) {
            return 0;
        }

        ScrapedLine scraped = scrapeLine(seriesTitle, episodes, override);
        ScrapedEpisode item = scraped.atSourceIndex(safeIdx);
        if (item != null && !item.isSpecial && item.episodeNumber > 0) {
            return item.episodeNumber;
        }
        if (item != null && item.isSpecial) {
            return 0;
        }
        // Fallback: count non-special episodes up to safeIdx
        int regularRank = 0;
        for (int i = 0; i <= safeIdx; i++) {
            ScrapedEpisode cand = scraped.atSourceIndex(i);
            if (cand != null && !cand.isSpecial) regularRank++;
        }
        int offset = override != null ? override.episodeOffset : 0;
        return Math.max(1, Math.max(1, regularRank) + offset);
    }

    static int resolveDanmuSeasonNumber(
            String seriesTitle,
            List<Cms.Episode> episodes,
            int activeIndex,
            SeriesScrapeStore.OverrideRecord override) {
        if (episodes != null && !episodes.isEmpty()) {
            int safeIdx = Math.max(0, Math.min(activeIndex, episodes.size() - 1));
            ScrapedLine scraped = scrapeLine(seriesTitle, episodes, override);
            ScrapedEpisode item = scraped.atSourceIndex(safeIdx);
            if (item != null && item.season > 0) return item.season;
        }
        String effectiveTitle =
                override != null && !override.matchedTitle.isEmpty()
                        ? override.matchedTitle
                        : seriesTitle;
        return extractSeasonNumber(effectiveTitle);
    }

    static boolean isSingleMovieLine(
            String seriesTitle, List<Cms.Episode> episodes, int activeIndex) {
        if (episodes == null || episodes.size() != 1) return false;
        Cms.Episode ep = episodes.get(Math.max(0, Math.min(activeIndex, episodes.size() - 1)));
        String name = ep != null && ep.name != null ? ep.name.trim() : "";
        return HistoryResumeMatcher.looksLikeMovieEpisode(name) && extractEpisodeNumber(name) <= 0;
    }

    /**
     * Scores a Dandanplay search candidate using cleaned title similarity, work-form consistency
     * (rejecting 动态漫画 / 有声书 mismatches), season agreement, and episode number agreement.
     */
    static double scoreDanmuCandidate(
            String rawQueryTitle,
            int querySeason,
            int queryEp,
            String candAnimeTitle,
            String candEpTitle) {
        WorkForm queryForm = detectWorkForm(rawQueryTitle);
        WorkForm candForm = detectWorkForm(candAnimeTitle);
        double score = 0.50;
        if (queryForm != candForm) {
            score -= 0.35;
        }

        String qCore = normalizeCoreKey(rawQueryTitle);
        String cCore = normalizeCoreKey(candAnimeTitle);
        if (!qCore.isEmpty() && !cCore.isEmpty()) {
            if (qCore.equals(cCore)) {
                score += 0.32;
            } else if (cCore.contains(qCore) || qCore.contains(cCore)) {
                int lenDiff = Math.abs(cCore.length() - qCore.length());
                score += Math.max(0.08, 0.24 - lenDiff * 0.02);
            } else {
                score -= 0.12;
            }
        }

        int candSeason = extractSeasonNumber(candAnimeTitle);
        if (querySeason > 0 && candSeason > 0) {
            score += (querySeason == candSeason) ? 0.14 : -0.25;
        } else if (querySeason > 1 && candSeason <= 0) {
            score -= 0.10;
        }

        if (queryEp > 0 && candEpTitle != null && !candEpTitle.trim().isEmpty()) {
            int candEp = extractEpisodeNumber(candEpTitle);
            if (candEp == queryEp) {
                score += 0.14;
            } else if (candEp > 0) {
                score -= 0.20;
            }
        }
        return Math.max(0.05, Math.min(0.99, score));
    }

    /**
     * Matches an episode from {@code fromLine} to {@code targetLine} using scraped {@code (season,
     * episodeNumber)} before falling back to positional index.
     */
    static Cms.Episode findMatchingEpisodeAcrossLines(
            String seriesTitle,
            Cms.Line targetLine,
            Cms.Line fromLine,
            Cms.Episode fromEpisode,
            SeriesScrapeStore.OverrideRecord override) {
        if (targetLine == null || targetLine.episodes == null || targetLine.episodes.isEmpty()) {
            return null;
        }
        if (fromEpisode != null && fromEpisode.name != null) {
            for (Cms.Episode cand : targetLine.episodes) {
                if (cand != null && fromEpisode.name.equalsIgnoreCase(cand.name)) {
                    return cand;
                }
            }
        }
        int fromIdx =
                fromLine != null && fromLine.episodes != null && fromEpisode != null
                        ? fromLine.episodes.indexOf(fromEpisode)
                        : -1;
        if (fromLine != null && fromIdx >= 0) {
            ScrapedLine fromScraped = scrapeLine(seriesTitle, fromLine.episodes, override);
            ScrapedEpisode src = fromScraped.atSourceIndex(fromIdx);
            if (src != null && !src.isSpecial && src.episodeNumber > 0) {
                ScrapedLine targetScraped = scrapeLine(seriesTitle, targetLine.episodes, override);
                Cms.Episode fallbackEpMatch = null;
                for (ScrapedEpisode cand : targetScraped.episodes) {
                    if (cand.isSpecial || cand.episodeNumber != src.episodeNumber) continue;
                    if (src.season <= 0 || cand.season <= 0 || src.season == cand.season) {
                        return targetLine.episodes.get(cand.sourceIndex);
                    }
                    if (fallbackEpMatch == null) {
                        fallbackEpMatch = targetLine.episodes.get(cand.sourceIndex);
                    }
                }
                if (fallbackEpMatch != null) return fallbackEpMatch;
            }
        }
        if (fromIdx >= 0 && fromIdx < targetLine.episodes.size()) {
            return targetLine.episodes.get(fromIdx);
        }
        return targetLine.episodes.get(0);
    }

    static String formatRangeLabel(
            ScrapedLine scraped, List<Integer> orderedIndices, int start, int end) {
        if (orderedIndices == null || orderedIndices.isEmpty() || start >= end) return "";
        int safeEnd = Math.min(end, orderedIndices.size());
        ScrapedEpisode first =
                scraped != null ? scraped.atSourceIndex(orderedIndices.get(start)) : null;
        ScrapedEpisode last =
                scraped != null ? scraped.atSourceIndex(orderedIndices.get(safeEnd - 1)) : null;
        if (first != null
                && last != null
                && !first.isSpecial
                && !last.isSpecial
                && first.episodeNumber > 0
                && last.episodeNumber > 0) {
            if (scraped.multiSeason && first.season > 0 && last.season > 0) {
                return "S"
                        + first.season
                        + "E"
                        + first.episodeNumber
                        + "–S"
                        + last.season
                        + "E"
                        + last.episodeNumber;
            }
            return first.episodeNumber + "–" + last.episodeNumber;
        }
        return (start + 1) + "–" + safeEnd;
    }

    static int parsePositiveInt(String digits) {
        if (digits == null || digits.isEmpty()) return -1;
        try {
            int val = Integer.parseInt(digits.trim());
            return val > 0 ? val : -1;
        } catch (NumberFormatException ignored) {
            return -1;
        }
    }

    static int parseChineseNumeral(String cn) {
        if (cn == null || cn.trim().isEmpty()) return -1;
        String s = cn.trim();
        int total = 0;
        int current = 0;
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            int digit = chineseDigit(c);
            if (digit >= 0) {
                current = digit;
            } else if (c == '十') {
                total += (current == 0 ? 1 : current) * 10;
                current = 0;
            } else if (c == '百') {
                total += (current == 0 ? 1 : current) * 100;
                current = 0;
            } else if (c == '千') {
                total += (current == 0 ? 1 : current) * 1000;
                current = 0;
            } else {
                return -1;
            }
        }
        total += current;
        return total > 0 ? total : -1;
    }

    private static int chineseDigit(char c) {
        switch (c) {
            case '零':
            case '〇':
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

    /** Utility used by interactive search to deduplicate candidate queries. */
    static List<String> buildSearchQueries(String rawTitle) {
        Set<String> out = new LinkedHashSet<>();
        String clean = cleanWorkTitle(rawTitle);
        if (!clean.isEmpty()) out.add(clean);
        String noSeason =
                SEASON_ONLY_PATTERN.matcher(clean).replaceAll(" ").replaceAll("\\s+", " ").trim();
        if (!noSeason.isEmpty()) out.add(noSeason);
        if (rawTitle != null && !rawTitle.trim().isEmpty()) out.add(rawTitle.trim());
        return new ArrayList<>(out);
    }
}
