package com.pilipala.marcomovie;

import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.regex.Pattern;
import org.json.JSONArray;
import org.json.JSONObject;

/**
 * Per-series subtitle & audio track memory and smart first-open auto-selection keyed by {@code
 * (siteKey, videoKey)}.
 *
 * <p>When a user picks a subtitle or audio track (or explicitly turns subtitles off) on one episode
 * of a series, subsequent episodes of the same series automatically match and apply that choice by
 * exact label, episode-number-stripped template, language/script bucket, or track index fallback.
 *
 * <p>When no series memory exists yet, {@link #pickBestSubtitleTrack(List)} and {@link
 * #pickBestAudioTrack(List, int)} automatically select the best Chinese subtitle and clean playable
 * audio track so users do not have to adjust tracks manually on every new drama or MKV release.
 *
 * <p>In Privacy Space, records stay strictly in memory for the current session and are cleared on
 * exit.
 */
final class SubtitlePreferenceStore {
    static final int MAX_ENTRIES = 300;
    static final int AUDIO_PREF_SMART = 0;
    static final int AUDIO_PREF_CHINESE = 1;
    static final int AUDIO_PREF_ORIGINAL = 2;

    private static final Map<String, Selection> PRIVATE_RECORDS = new LinkedHashMap<>();
    private static final Map<String, Selection> PRIVATE_AUDIO_RECORDS = new LinkedHashMap<>();

    private static final Pattern EPISODE_TOKEN_PATTERN =
            Pattern.compile(
                    "(?i)(?:s\\d{1,3}e\\d{1,4}|ep?\\.?\\d{1,4}|第\\s*\\d{1,4}\\s*[集话話回期]|\\b\\d{2,4}\\b)");
    private static final Pattern SPACE_COLLAPSE_PATTERN = Pattern.compile("[\\s._-]+");

    static final class Selection {
        final boolean disabled;
        final int trackIndex;
        final String label;
        final String template;
        final String langBucket;

        Selection(boolean disabled, int trackIndex, String label) {
            this.disabled = disabled;
            this.trackIndex = disabled ? -2 : Math.max(0, trackIndex);
            this.label = cleanLabel(label);
            this.template = normalizeTemplate(this.label);
            this.langBucket = detectLangBucket(this.label);
        }

        private Selection(
                boolean disabled,
                int trackIndex,
                String label,
                String template,
                String langBucket) {
            this.disabled = disabled;
            this.trackIndex = disabled ? -2 : Math.max(0, trackIndex);
            this.label = label == null ? "" : label;
            this.template = template == null ? "" : template;
            this.langBucket = langBucket == null ? "" : langBucket;
        }

        JSONObject toJson(String key) throws Exception {
            JSONObject o = new JSONObject();
            o.put("k", key);
            o.put("off", disabled);
            o.put("idx", trackIndex);
            o.put("lbl", label);
            o.put("tpl", template);
            o.put("lang", langBucket);
            return o;
        }

        static Selection fromJson(JSONObject o) {
            if (o == null) return null;
            boolean off = o.optBoolean("off", false);
            int idx = o.optInt("idx", off ? -2 : 0);
            String lbl = o.optString("lbl", "");
            String tpl = o.optString("tpl", normalizeTemplate(lbl));
            String lang = o.optString("lang", detectLangBucket(lbl));
            return new Selection(off, idx, lbl, tpl, lang);
        }
    }

    private SubtitlePreferenceStore() {}

    static String recordKey(String siteKey, String videoKey) {
        return VideoSkipStore.recordKey(siteKey, videoKey);
    }

    static String cleanLabel(String raw) {
        if (raw == null) return "";
        String s = raw.trim();
        if (s.startsWith("✓")) {
            s = s.substring(1).trim();
        }
        return s;
    }

    /** Removes episode numbers so e.g. {@code Show.S01E01.chs.ass} matches {@code Show.S01E02.chs.ass}. */
    static String normalizeTemplate(String rawLabel) {
        String s = cleanLabel(rawLabel).toLowerCase(Locale.ROOT);
        if (s.isEmpty()) return "";
        s = EPISODE_TOKEN_PATTERN.matcher(s).replaceAll(" ");
        s = SPACE_COLLAPSE_PATTERN.matcher(s).replaceAll(" ").trim();
        return s;
    }

    static String detectLangBucket(String rawLabel) {
        String s = cleanLabel(rawLabel).toLowerCase(Locale.ROOT);
        if (s.isEmpty()) return "";
        if (s.contains("粤语")
                || s.contains("粵語")
                || s.contains("粤")
                || s.contains("粵")
                || s.contains("cantonese")
                || hasWord(s, "yue")) {
            return "zh-yue";
        }
        boolean hasBilingual =
                s.contains("双语")
                        || s.contains("雙語")
                        || s.contains("中英")
                        || s.contains("英中")
                        || s.contains("bilingual")
                        || s.contains("chs&eng")
                        || s.contains("cht&eng")
                        || s.contains("chs+eng")
                        || s.contains("sc+en");
        boolean hasSimp =
                s.contains("简")
                        || s.contains("簡")
                        || s.contains("simplified")
                        || s.contains("zh-cn")
                        || s.contains("zh_cn")
                        || s.contains("zh-hans")
                        || s.contains("hans")
                        || hasWord(s, "chs")
                        || hasWord(s, "sc")
                        || hasWord(s, "gb");
        boolean hasTrad =
                s.contains("繁")
                        || s.contains("traditional")
                        || s.contains("zh-tw")
                        || s.contains("zh_tw")
                        || s.contains("zh-hk")
                        || s.contains("zh-hant")
                        || s.contains("hant")
                        || hasWord(s, "cht")
                        || hasWord(s, "tc")
                        || hasWord(s, "big5");
        if (hasBilingual && hasTrad) return "zh-hant-bi";
        if (hasBilingual) return "zh-hans-bi";
        if (hasSimp) return "zh-hans";
        if (hasTrad) return "zh-hant";
        if (s.contains("中文")
                || s.contains("中字")
                || s.contains("国语")
                || s.contains("國語")
                || s.contains("普通话")
                || s.contains("華語")
                || s.contains("华语")
                || s.contains("mandarin")
                || s.contains("chinese")
                || hasWord(s, "zh")
                || hasWord(s, "chi")
                || hasWord(s, "zho")
                || hasWord(s, "cmn")) {
            return "zh";
        }
        if (s.contains("英文")
                || s.contains("英语")
                || s.contains("英語")
                || s.contains("english")
                || hasWord(s, "en")
                || hasWord(s, "eng")) {
            return "en";
        }
        if (s.contains("日文")
                || s.contains("日语")
                || s.contains("日語")
                || s.contains("japanese")
                || hasWord(s, "ja")
                || hasWord(s, "jpn")
                || hasWord(s, "jp")) {
            return "ja";
        }
        if (s.contains("韩文")
                || s.contains("韩语")
                || s.contains("韓語")
                || s.contains("korean")
                || hasWord(s, "ko")
                || hasWord(s, "kor")) {
            return "ko";
        }
        if (s.contains("法语")
                || s.contains("french")
                || hasWord(s, "fr")
                || hasWord(s, "fre")
                || hasWord(s, "fra")) {
            return "fr";
        }
        if (s.contains("德语")
                || s.contains("german")
                || hasWord(s, "de")
                || hasWord(s, "ger")
                || hasWord(s, "deu")) {
            return "de";
        }
        if (s.contains("西班牙") || s.contains("spanish") || hasWord(s, "es") || hasWord(s, "spa")) {
            return "es";
        }
        if (s.contains("俄语") || s.contains("russian") || hasWord(s, "ru") || hasWord(s, "rus")) {
            return "ru";
        }
        if (s.contains("阿拉伯") || s.contains("arabic") || hasWord(s, "ar") || hasWord(s, "ara")) {
            return "ar";
        }
        if (s.contains("泰语") || s.contains("thai") || hasWord(s, "th") || hasWord(s, "tha")) {
            return "th";
        }
        if (s.contains("越南") || s.contains("vietnamese") || hasWord(s, "vi") || hasWord(s, "vie")) {
            return "vi";
        }
        return "";
    }

    static boolean isCommentaryOrAdTrack(String rawLabel) {
        String s = cleanLabel(rawLabel).toLowerCase(Locale.ROOT);
        if (s.isEmpty()) return false;
        return s.contains("commentary")
                || s.contains("director")
                || s.contains("评论")
                || s.contains("評論")
                || s.contains("解说")
                || s.contains("解說")
                || s.contains("audio description")
                || s.contains("descriptive")
                || s.contains("视觉描述")
                || s.contains("视觉辅助")
                || s.contains("盲人")
                || hasWord(s, "ad");
    }

    static boolean isForcedSubtitle(String rawLabel) {
        String s = cleanLabel(rawLabel).toLowerCase(Locale.ROOT);
        if (s.isEmpty()) return false;
        return s.contains("forced")
                || s.contains("强制")
                || s.contains("強制")
                || s.contains("signs")
                || s.contains("songs");
    }

    static boolean isSdhSubtitle(String rawLabel) {
        String s = cleanLabel(rawLabel).toLowerCase(Locale.ROOT);
        if (s.isEmpty()) return false;
        return hasWord(s, "sdh")
                || hasWord(s, "cc")
                || s.contains("hearing")
                || s.contains("听障")
                || s.contains("聽障")
                || s.contains("closed caption");
    }

    /**
     * Automatically chooses the best Chinese subtitle track on first open when the user has not yet
     * saved a per-series preference.
     *
     * @return target track index to select, or {@code -1} if no better Chinese track should be
     *     forced.
     */
    static int pickBestSubtitleTrack(List<String> trackLabels) {
        if (trackLabels == null || trackLabels.isEmpty()) return -1;
        int bestIdx = -1;
        int bestScore = Integer.MIN_VALUE;
        int selectedIdx = -1;
        int selectedScore = Integer.MIN_VALUE;

        for (int i = 0; i < trackLabels.size(); i++) {
            String raw = trackLabels.get(i);
            boolean selected = raw != null && raw.trim().startsWith("✓");
            String clean = cleanLabel(raw);
            String bucket = detectLangBucket(clean);
            int score = 0;
            if ("zh-hans-bi".equals(bucket)) score = 120;
            else if ("zh-hans".equals(bucket)) score = 110;
            else if ("zh".equals(bucket)) score = 95;
            else if ("zh-hant-bi".equals(bucket)) score = 92;
            else if ("zh-hant".equals(bucket)) score = 85;
            else if (clean.contains("外挂")
                    || clean.toLowerCase(Locale.ROOT).endsWith(".srt")
                    || clean.toLowerCase(Locale.ROOT).endsWith(".ass")
                    || clean.toLowerCase(Locale.ROOT).endsWith(".vtt")) {
                // External subtitles bundled with a source are almost always intended for display.
                score = bucket.isEmpty() ? 70 : 15;
            }
            if (score > 0) {
                if (clean.contains("外挂") || clean.toLowerCase(Locale.ROOT).contains("external")) {
                    score += 12;
                }
                if (isCommentaryOrAdTrack(clean)) score -= 85;
                if (isForcedSubtitle(clean)) score -= 40;
                if (isSdhSubtitle(clean)) score -= 22;
            }
            if (selected) {
                selectedIdx = i;
                selectedScore = score;
            }
            if (score > bestScore) {
                bestScore = score;
                bestIdx = i;
            }
        }
        if (bestIdx < 0 || bestScore < 40) return -1;
        if (selectedIdx == bestIdx) return -1;
        // If a clean Chinese track is already selected and nearly tied, avoid unnecessary switch.
        if (selectedIdx >= 0 && selectedScore >= 85 && bestScore - selectedScore < 15) {
            return -1;
        }
        return bestIdx;
    }

    /**
     * Automatically chooses the best audio track on first open when the user has not saved a
     * per-series audio override.
     *
     * @param audioPrefMode {@link #AUDIO_PREF_SMART}, {@link #AUDIO_PREF_CHINESE}, or {@link
     *     #AUDIO_PREF_ORIGINAL}.
     * @return track index to select, or {@code -1} to keep the player's current selection.
     */
    static int pickBestAudioTrack(List<String> trackLabels, int audioPrefMode) {
        if (trackLabels == null || trackLabels.isEmpty()) return -1;
        int n = trackLabels.size();
        int selectedIdx = -1;
        for (int i = 0; i < n; i++) {
            String raw = trackLabels.get(i);
            if (raw != null && raw.trim().startsWith("✓")) {
                selectedIdx = i;
                break;
            }
        }
        if (n == 1) {
            return selectedIdx == 0 ? -1 : 0;
        }

        boolean selectedUnwanted =
                selectedIdx >= 0 && isCommentaryOrAdTrack(trackLabels.get(selectedIdx));

        if (audioPrefMode == AUDIO_PREF_CHINESE) {
            int bestZh = findBestMandarinOrChineseAudio(trackLabels);
            if (bestZh >= 0 && bestZh != selectedIdx) return bestZh;
            if (selectedIdx < 0 || selectedUnwanted) {
                int clean = findFirstCleanAudio(trackLabels);
                return clean != selectedIdx ? clean : -1;
            }
            return -1;
        }

        if (audioPrefMode == AUDIO_PREF_ORIGINAL) {
            if (selectedIdx < 0 || selectedUnwanted) {
                int clean = findFirstCleanAudio(trackLabels);
                return clean != selectedIdx ? clean : -1;
            }
            return -1;
        }

        // AUDIO_PREF_SMART:
        // 1. Always rescue unselected audio or commentary / Audio Description tracks.
        if (selectedIdx < 0 || selectedUnwanted) {
            int bestZh = findBestMandarinOrChineseAudio(trackLabels);
            if (bestZh >= 0) return bestZh;
            int clean = findFirstCleanAudio(trackLabels);
            return clean != selectedIdx ? clean : -1;
        }

        // 2. If currently selected is Cantonese or a non-CJK/non-English dub (e.g. Arabic/German
        //    Track 0 in a multi-dub MKV) and a clean Mandarin Chinese track exists, prefer
        // Mandarin.
        String selBucket = detectLangBucket(trackLabels.get(selectedIdx));
        boolean keepOriginal =
                "zh".equals(selBucket)
                        || "zh-hans".equals(selBucket)
                        || "zh-hant".equals(selBucket)
                        || "en".equals(selBucket)
                        || "ja".equals(selBucket)
                        || "ko".equals(selBucket)
                        || selBucket.isEmpty();
        if (!keepOriginal) {
            int bestMandarin = findBestMandarinOnlyAudio(trackLabels);
            if (bestMandarin >= 0 && bestMandarin != selectedIdx) {
                return bestMandarin;
            }
        }
        return -1;
    }

    private static int findBestMandarinOnlyAudio(List<String> trackLabels) {
        int best = -1;
        int bestScore = Integer.MIN_VALUE;
        for (int i = 0; i < trackLabels.size(); i++) {
            String clean = cleanLabel(trackLabels.get(i));
            if (isCommentaryOrAdTrack(clean)) continue;
            String bucket = detectLangBucket(clean);
            int score = 0;
            if ("zh".equals(bucket) || "zh-hans".equals(bucket)) score = 100;
            else if ("zh-hant".equals(bucket)) score = 88;
            if (score > 0) {
                score += audioQualityTieBreaker(clean);
                if (score > bestScore) {
                    bestScore = score;
                    best = i;
                }
            }
        }
        return best;
    }

    private static int findBestMandarinOrChineseAudio(List<String> trackLabels) {
        int best = -1;
        int bestScore = Integer.MIN_VALUE;
        for (int i = 0; i < trackLabels.size(); i++) {
            String clean = cleanLabel(trackLabels.get(i));
            if (isCommentaryOrAdTrack(clean)) continue;
            String bucket = detectLangBucket(clean);
            int score = 0;
            if ("zh".equals(bucket) || "zh-hans".equals(bucket)) score = 100;
            else if ("zh-hant".equals(bucket)) score = 88;
            else if ("zh-yue".equals(bucket)) score = 78;
            if (score > 0) {
                score += audioQualityTieBreaker(clean);
                if (score > bestScore) {
                    bestScore = score;
                    best = i;
                }
            }
        }
        return best;
    }

    private static int findFirstCleanAudio(List<String> trackLabels) {
        for (int i = 0; i < trackLabels.size(); i++) {
            if (!isCommentaryOrAdTrack(trackLabels.get(i))) return i;
        }
        return trackLabels.isEmpty() ? -1 : 0;
    }

    private static int audioQualityTieBreaker(String clean) {
        String lower = clean.toLowerCase(Locale.ROOT);
        int bonus = 0;
        if (lower.contains("国语") || lower.contains("國語") || lower.contains("普通话")) bonus += 8;
        if (lower.contains("5.1") || lower.contains("6 声道")) bonus += 4;
        else if (lower.contains("7.1") || lower.contains("8 声道")) bonus += 3;
        return bonus;
    }

    private static boolean hasWord(String lower, String word) {
        int idx = lower.indexOf(word);
        while (idx >= 0) {
            boolean leftOk = idx == 0 || !isAsciiLetterOrDigit(lower.charAt(idx - 1));
            int end = idx + word.length();
            boolean rightOk = end >= lower.length() || !isAsciiLetterOrDigit(lower.charAt(end));
            if (leftOk && rightOk) return true;
            idx = lower.indexOf(word, idx + 1);
        }
        return false;
    }

    private static boolean isAsciiLetterOrDigit(char c) {
        return (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9');
    }

    /**
     * Resolves the track index to select on the next episode.
     *
     * @return {@code -2} to disable subtitles, {@code >= 0} for a matched track index, or {@code -1}
     *     when no preference applies.
     */
    static int matchTrackIndex(Selection saved, List<String> trackLabels) {
        if (saved == null) return -1;
        if (saved.disabled) return -2;
        if (trackLabels == null || trackLabels.isEmpty()) return -1;

        int n = trackLabels.size();
        String[] cleaned = new String[n];
        for (int i = 0; i < n; i++) {
            cleaned[i] = cleanLabel(trackLabels.get(i));
        }

        // 1. Exact label match (case-insensitive), preferring closest to saved track index.
        if (!saved.label.isEmpty()) {
            int best = -1;
            int bestDist = Integer.MAX_VALUE;
            for (int i = 0; i < n; i++) {
                if (saved.label.equalsIgnoreCase(cleaned[i])) {
                    int dist = Math.abs(i - saved.trackIndex);
                    if (dist < bestDist) {
                        bestDist = dist;
                        best = i;
                    }
                }
            }
            if (best >= 0) return best;
        }

        // 2. Episode-number-invariant template match (e.g., S01E01.chs.ass -> S01E02.chs.ass).
        if (!saved.template.isEmpty()) {
            int best = -1;
            int bestDist = Integer.MAX_VALUE;
            for (int i = 0; i < n; i++) {
                String tpl = normalizeTemplate(cleaned[i]);
                if (!tpl.isEmpty() && saved.template.equals(tpl)) {
                    int dist = Math.abs(i - saved.trackIndex);
                    if (dist < bestDist) {
                        bestDist = dist;
                        best = i;
                    }
                }
            }
            if (best >= 0) return best;
        }

        // 3. Language/script bucket match (exact bucket first, then compatible zh family).
        if (!saved.langBucket.isEmpty()) {
            int best = -1;
            int bestDist = Integer.MAX_VALUE;
            for (int i = 0; i < n; i++) {
                if (saved.langBucket.equals(detectLangBucket(cleaned[i]))) {
                    int dist = Math.abs(i - saved.trackIndex);
                    if (dist < bestDist) {
                        bestDist = dist;
                        best = i;
                    }
                }
            }
            if (best >= 0) return best;

            if (saved.langBucket.startsWith("zh") && !"zh-yue".equals(saved.langBucket)) {
                for (int i = 0; i < n; i++) {
                    String b = detectLangBucket(cleaned[i]);
                    if (b.startsWith("zh") && !"zh-yue".equals(b)) {
                        int dist = Math.abs(i - saved.trackIndex);
                        if (dist < bestDist) {
                            bestDist = dist;
                            best = i;
                        }
                    }
                }
                if (best >= 0) return best;
            }
        }

        // 4. Same-position index fallback when track ordering stays consistent across episodes.
        if (saved.trackIndex >= 0 && saved.trackIndex < n) {
            return saved.trackIndex;
        }
        return -1;
    }

    private static Map<String, Selection> parseMap(String rawJson) {
        Map<String, Selection> out = new LinkedHashMap<>();
        if (rawJson == null || rawJson.trim().isEmpty()) return out;
        try {
            JSONArray arr = new JSONArray(rawJson);
            for (int i = 0; i < arr.length(); i++) {
                JSONObject o = arr.optJSONObject(i);
                if (o == null) continue;
                String k = o.optString("k", "");
                if (k.isEmpty()) continue;
                Selection sel = Selection.fromJson(o);
                if (sel != null) out.put(k, sel);
            }
        } catch (Exception ignored) {
        }
        return out;
    }

    private static String serializeMap(Map<String, Selection> map) {
        while (map.size() > MAX_ENTRIES) {
            Iterator<String> it = map.keySet().iterator();
            if (!it.hasNext()) break;
            it.next();
            it.remove();
        }
        JSONArray arr = new JSONArray();
        for (Map.Entry<String, Selection> e : map.entrySet()) {
            try {
                arr.put(e.getValue().toJson(e.getKey()));
            } catch (Exception ignored) {
            }
        }
        return arr.toString();
    }

    static Selection read(String rawJson, String siteKey, String videoKey) {
        String key = recordKey(siteKey, videoKey);
        if (key.isEmpty()) return null;
        return parseMap(rawJson).get(key);
    }

    static String write(String rawJson, String siteKey, String videoKey, Selection selection) {
        String key = recordKey(siteKey, videoKey);
        if (key.isEmpty() || selection == null) {
            return rawJson == null ? "[]" : rawJson;
        }
        Map<String, Selection> map = parseMap(rawJson);
        map.remove(key);
        map.put(key, selection);
        return serializeMap(map);
    }

    static String remove(String rawJson, String siteKey, String videoKey) {
        String key = recordKey(siteKey, videoKey);
        if (key.isEmpty()) return rawJson == null ? "[]" : rawJson;
        Map<String, Selection> map = parseMap(rawJson);
        if (map.remove(key) == null) return rawJson == null ? "[]" : rawJson;
        return serializeMap(map);
    }

    static synchronized Selection getPrivate(String siteKey, String videoKey) {
        String key = recordKey(siteKey, videoKey);
        return key.isEmpty() ? null : PRIVATE_RECORDS.get(key);
    }

    static synchronized void setPrivate(String siteKey, String videoKey, Selection selection) {
        String key = recordKey(siteKey, videoKey);
        if (key.isEmpty() || selection == null) return;
        PRIVATE_RECORDS.remove(key);
        PRIVATE_RECORDS.put(key, selection);
        while (PRIVATE_RECORDS.size() > MAX_ENTRIES) {
            Iterator<String> it = PRIVATE_RECORDS.keySet().iterator();
            if (!it.hasNext()) break;
            it.next();
            it.remove();
        }
    }

    static synchronized Selection getPrivateAudio(String siteKey, String videoKey) {
        String key = recordKey(siteKey, videoKey);
        return key.isEmpty() ? null : PRIVATE_AUDIO_RECORDS.get(key);
    }

    static synchronized void setPrivateAudio(String siteKey, String videoKey, Selection selection) {
        String key = recordKey(siteKey, videoKey);
        if (key.isEmpty() || selection == null) return;
        PRIVATE_AUDIO_RECORDS.remove(key);
        PRIVATE_AUDIO_RECORDS.put(key, selection);
        while (PRIVATE_AUDIO_RECORDS.size() > MAX_ENTRIES) {
            Iterator<String> it = PRIVATE_AUDIO_RECORDS.keySet().iterator();
            if (!it.hasNext()) break;
            it.next();
            it.remove();
        }
    }

    static synchronized void removePrivateAudio(String siteKey, String videoKey) {
        String key = recordKey(siteKey, videoKey);
        if (!key.isEmpty()) PRIVATE_AUDIO_RECORDS.remove(key);
    }

    static synchronized void clearPrivateRecords() {
        PRIVATE_RECORDS.clear();
        PRIVATE_AUDIO_RECORDS.clear();
    }
}
