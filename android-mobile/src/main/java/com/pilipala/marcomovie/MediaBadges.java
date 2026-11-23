// SPDX-License-Identifier: GPL-3.0-only
package com.pilipala.marcomovie;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.ByteBuffer;
import java.nio.charset.Charset;
import java.nio.charset.CharsetDecoder;
import java.nio.charset.CodingErrorAction;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.regex.Pattern;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

/**
 * Cross-platform media specification badge parser and pure-data track fusion engine.
 *
 * <p>Implements {@code shared/ui-spec/badge-rules.json} (schemaVersion 1) using only Java/JSON APIs
 * compatible with Android API 14+ and standard JVM unit checks. All emitted badges are plain-text
 * typography labels with zero trademarked graphic assets.
 */
public final class MediaBadges {
    public static final int MAX_INPUT_CODE_UNITS = 1024;
    public static final int LRU_CACHE_CAPACITY = 256;

    private static final Charset UTF8 = Charset.forName("UTF-8");

    public static final class Badge {
        public final String id;
        public final String group;
        public final String label;
        public final int priority;
        public final String style;

        public Badge(String id, String group, String label, int priority, String style) {
            this.id = id;
            this.group = group;
            this.label = label;
            this.priority = priority;
            this.style = style;
        }

        @Override
        public boolean equals(Object o) {
            if (this == o) return true;
            if (!(o instanceof Badge)) return false;
            Badge other = (Badge) o;
            return priority == other.priority
                    && id.equals(other.id)
                    && group.equals(other.group)
                    && label.equals(other.label)
                    && style.equals(other.style);
        }

        @Override
        public int hashCode() {
            int h = id.hashCode();
            h = 31 * h + label.hashCode();
            h = 31 * h + priority;
            return h;
        }

        @Override
        public String toString() {
            return label + "(" + id + ")";
        }
    }

    /**
     * Pure-data live track descriptor for player HUD fusion (M2 / Wave 2).
     *
     * <p>All fields are optional; zero/null/empty values are ignored.
     */
    public static final class TrackSpec {
        public final int videoWidth;
        public final int videoHeight;
        public final String videoCodec;
        public final String dynamicRange;
        public final String audioCodec;
        public final int audioChannels;
        public final String audioChannelLayout;
        public final boolean atmos;

        public TrackSpec(
                int videoWidth,
                int videoHeight,
                String videoCodec,
                String dynamicRange,
                String audioCodec,
                int audioChannels,
                String audioChannelLayout,
                boolean atmos) {
            this.videoWidth = videoWidth;
            this.videoHeight = videoHeight;
            this.videoCodec = videoCodec;
            this.dynamicRange = dynamicRange;
            this.audioCodec = audioCodec;
            this.audioChannels = audioChannels;
            this.audioChannelLayout = audioChannelLayout;
            this.atmos = atmos;
        }

        public String toSyntheticTokens() {
            StringBuilder sb = new StringBuilder();
            if (videoWidth >= 7000 || videoHeight >= 4000) {
                appendToken(sb, "4320p");
            } else if (videoWidth >= 3600 || videoHeight >= 2000) {
                appendToken(sb, "2160p");
            } else if (videoWidth >= 2400 || videoHeight >= 1350) {
                appendToken(sb, "1440p");
            } else if (videoWidth >= 1800 || videoHeight >= 1000) {
                appendToken(sb, "1080p");
            } else if (videoWidth >= 1200 || videoHeight >= 700) {
                appendToken(sb, "720p");
            } else if (videoWidth > 0 || videoHeight > 0) {
                appendToken(sb, "480p");
            }
            appendToken(sb, dynamicRange);
            appendToken(sb, videoCodec);
            appendToken(sb, audioCodec);
            if (atmos) {
                appendToken(sb, "Atmos");
            }
            if (audioChannelLayout != null && !audioChannelLayout.isEmpty()) {
                appendToken(sb, audioChannelLayout);
            } else if (audioChannels >= 8) {
                appendToken(sb, "7.1");
            } else if (audioChannels >= 6) {
                appendToken(sb, "5.1");
            } else if (audioChannels == 2) {
                appendToken(sb, "2.0");
            }
            return sb.toString();
        }

        private static void appendToken(StringBuilder sb, String token) {
            if (token == null || token.isEmpty()) return;
            if (sb.length() > 0) sb.append(' ');
            sb.append(token);
        }
    }

    private static final class Rule {
        final String id;
        final String group;
        final String label;
        final Pattern pattern;
        final String[] anyRequiredTokens;
        final int priority;
        final String style;
        final Badge badge;

        Rule(
                String id,
                String group,
                String label,
                String regex,
                int priority,
                String style,
                boolean registerStandard) {
            this.id = id;
            this.group = group;
            this.label = label;
            this.pattern = Pattern.compile(regex, Pattern.CASE_INSENSITIVE);
            this.anyRequiredTokens =
                    registerStandard
                            ? registerStandardPattern(id, regex)
                            : requiredTokensForStandardRule(id, regex);
            this.priority = priority;
            this.style = style;
            this.badge = new Badge(id, group, label, priority, style);
        }

        boolean couldMatch(String lower) {
            if (anyRequiredTokens == null) return true;
            for (int i = 0; i < anyRequiredTokens.length; i++) {
                if (lower.indexOf(anyRequiredTokens[i]) >= 0) return true;
            }
            return false;
        }
    }

    private static final Map<String, String> STANDARD_PATTERNS = new HashMap<String, String>();
    private static final Map<String, String[]> STANDARD_HINTS = buildStandardHints();

    private static String[] registerStandardPattern(String id, String regex) {
        synchronized (STANDARD_PATTERNS) {
            STANDARD_PATTERNS.put(id, regex);
        }
        return STANDARD_HINTS.get(id);
    }

    private static String[] requiredTokensForStandardRule(String id, String regex) {
        String expected;
        synchronized (STANDARD_PATTERNS) {
            expected = STANDARD_PATTERNS.get(id);
        }
        if (expected == null || !expected.equals(regex)) return null;
        return STANDARD_HINTS.get(id);
    }

    private static Map<String, String[]> buildStandardHints() {
        Map<String, String[]> m = new HashMap<String, String[]>(64);
        m.put("res_8k", new String[] {"8k", "4320", "fuhd"});
        m.put("res_4k", new String[] {"4k", "2160", "uhd", "3840", "4096", "ultra"});
        m.put("res_2k", new String[] {"2k", "1440", "qhd", "2560"});
        m.put("res_1080p", new String[] {"1080", "fhd", "1920", "full"});
        m.put("res_720p", new String[] {"720", "1280"});
        m.put("res_sd", new String[] {"480", "576", "sd", "标清"});
        m.put("dr_dv", new String[] {"dv", "dovi", "dolby", "dav1", "杜比"});
        m.put("dr_hdr10plus", new String[] {"hdr10"});
        m.put("dr_hdr10", new String[] {"hdr", "2084"});
        m.put("dr_hlg", new String[] {"hlg", "b67"});
        m.put("dr_hdr", new String[] {"hdr", "2020", "臻彩"});
        m.put("src_remux", new String[] {"remux"});
        m.put("src_bluray", new String[] {"blu", "bd", "brrip", "原盘"});
        m.put("src_webdl", new String[] {"web"});
        m.put("src_webrip", new String[] {"web"});
        m.put("src_hdtv", new String[] {"hdtv", "pdtv", "dsr"});
        m.put("aud_atmos", new String[] {"atmos", "joc", "ec+3", "全景声"});
        m.put("aud_dtsx", new String[] {"dts"});
        m.put("aud_truehd", new String[] {"true", "mlp"});
        m.put("aud_dtshd_ma", new String[] {"dts"});
        m.put("aud_dtshd", new String[] {"dts"});
        m.put("aud_dts", new String[] {"dts"});
        m.put("aud_ddp", new String[] {"dd+", "ddp", "ac", "ec", "dolby"});
        m.put("aud_dd", new String[] {"dd", "ac", "dolby"});
        m.put("aud_lpcm", new String[] {"pcm"});
        m.put("aud_flac", new String[] {"flac"});
        m.put("aud_opus", new String[] {"opus"});
        m.put("aud_aac", new String[] {"aac", "mp4a"});
        m.put("ch_7_1", new String[] {"7.1", "8"});
        m.put("ch_5_1", new String[] {"5.1", "6"});
        m.put("ch_2_0", new String[] {"2.0", "2", "stereo", "立体声", "双声道"});
        m.put("vid_av1", new String[] {"av1", "av01", "dav1"});
        m.put("vid_hevc", new String[] {"hevc", "265", "hev1", "hvc1"});
        m.put("vid_vp9", new String[] {"vp9", "vp09"});
        m.put("vid_avc", new String[] {"avc", "264"});
        m.put("plt_nf", new String[] {"nf", "netflix", "nflx"});
        m.put("plt_amzn", new String[] {"amzn", "amazon", "prime"});
        m.put("plt_atvp", new String[] {"atvp", "aptv", "apple"});
        m.put("plt_dsnp", new String[] {"dsnp", "dsny", "disney"});
        m.put("plt_max", new String[] {"max"});
        m.put("plt_hulu", new String[] {"hulu"});
        m.put("plt_pcok", new String[] {"pcok", "peacock"});
        m.put("plt_pmtp", new String[] {"pmtp", "pamp", "paramount"});
        m.put("plt_bili", new String[] {"bili", "global", "b站"});
        m.put("plt_cr", new String[] {"cr"});
        return m;
    }

    private static final class ComboRule {
        final String id;
        final String group;
        final String label;
        final String[] requires;
        final String[] consumes;
        final int priority;
        final String style;
        final Badge badge;

        ComboRule(
                String id,
                String group,
                String label,
                String[] requires,
                String[] consumes,
                int priority,
                String style) {
            this.id = id;
            this.group = group;
            this.label = label;
            this.requires = requires;
            this.consumes = consumes;
            this.priority = priority;
            this.style = style;
            this.badge = new Badge(id, group, label, priority, style);
        }
    }

    private static final Comparator<Badge> BADGE_ORDER =
            new Comparator<Badge>() {
                @Override
                public int compare(Badge a, Badge b) {
                    if (a.priority != b.priority) {
                        return a.priority < b.priority ? -1 : 1;
                    }
                    return a.id.compareTo(b.id);
                }
            };

    private static final Comparator<ComboRule> COMBO_ORDER =
            new Comparator<ComboRule>() {
                @Override
                public int compare(ComboRule a, ComboRule b) {
                    if (a.priority != b.priority) {
                        return a.priority < b.priority ? -1 : 1;
                    }
                    return a.id.compareTo(b.id);
                }
            };

    private static volatile MediaBadges defaultEngine;

    private final List<Rule> rules;
    private final Map<String, Rule> ruleById;
    private final List<ComboRule> comboRules;
    private final LinkedHashMap<String, List<Badge>> cache;

    private MediaBadges(List<Rule> rules, List<ComboRule> comboRules) {
        this.rules = Collections.unmodifiableList(new ArrayList<Rule>(rules));
        Map<String, Rule> byId = new HashMap<String, Rule>(rules.size() * 2);
        for (int i = 0; i < rules.size(); i++) {
            Rule r = rules.get(i);
            byId.put(r.id, r);
        }
        this.ruleById = Collections.unmodifiableMap(byId);
        List<ComboRule> sortedCombos = new ArrayList<ComboRule>(comboRules);
        Collections.sort(sortedCombos, COMBO_ORDER);
        this.comboRules = Collections.unmodifiableList(sortedCombos);
        this.cache =
                new LinkedHashMap<String, List<Badge>>(LRU_CACHE_CAPACITY, 0.75f, true) {
                    @Override
                    protected boolean removeEldestEntry(Map.Entry<String, List<Badge>> eldest) {
                        return size() > LRU_CACHE_CAPACITY;
                    }
                };
    }

    public static MediaBadges getDefault() {
        MediaBadges engine = defaultEngine;
        if (engine == null) {
            synchronized (MediaBadges.class) {
                engine = defaultEngine;
                if (engine == null) {
                    engine = buildBuiltinDefault();
                    defaultEngine = engine;
                }
            }
        }
        return engine;
    }

    public static void installDefault(MediaBadges engine) {
        if (engine != null) {
            defaultEngine = engine;
        }
    }

    public static boolean loadDefaultFromStream(InputStream in) {
        if (in == null) return false;
        try {
            ByteArrayOutputStream out = new ByteArrayOutputStream();
            byte[] buf = new byte[4096];
            int n;
            while ((n = in.read(buf)) >= 0) {
                out.write(buf, 0, n);
            }
            String json = new String(out.toByteArray(), UTF8);
            installDefault(fromJson(json));
            return true;
        } catch (IOException ignored) {
            return false;
        } catch (JSONException ignored) {
            return false;
        }
    }

    public static MediaBadges fromJson(String json) throws JSONException {
        if (defaultEngine == null) {
            getDefault();
        }
        JSONObject root = new JSONObject(json);
        JSONArray rulesArr = root.getJSONArray("rules");
        List<Rule> parsedRules = new ArrayList<Rule>(rulesArr.length());
        for (int i = 0; i < rulesArr.length(); i++) {
            JSONObject obj = rulesArr.getJSONObject(i);
            parsedRules.add(
                    new Rule(
                            obj.getString("id"),
                            obj.getString("group"),
                            obj.getString("label"),
                            obj.getString("pattern"),
                            obj.getInt("priority"),
                            obj.getString("style"),
                            false));
        }
        JSONArray comboArr = root.optJSONArray("comboRules");
        List<ComboRule> parsedCombos =
                new ArrayList<ComboRule>(comboArr == null ? 0 : comboArr.length());
        if (comboArr != null) {
            for (int i = 0; i < comboArr.length(); i++) {
                JSONObject obj = comboArr.getJSONObject(i);
                parsedCombos.add(
                        new ComboRule(
                                obj.getString("id"),
                                obj.getString("group"),
                                obj.getString("label"),
                                toStringArray(obj.getJSONArray("requires")),
                                toStringArray(obj.getJSONArray("consumes")),
                                obj.getInt("priority"),
                                obj.getString("style")));
            }
        }
        return new MediaBadges(parsedRules, parsedCombos);
    }

    private static String[] toStringArray(JSONArray arr) throws JSONException {
        String[] res = new String[arr.length()];
        for (int i = 0; i < arr.length(); i++) {
            res[i] = arr.getString(i);
        }
        return res;
    }

    /**
     * Normalizes raw input according to {@code badge-rules.json} evaluationContract.normalization.
     */
    public static String normalize(String input) {
        if (input == null || input.isEmpty()) {
            return "";
        }
        String decoded = percentDecodeUtf8PreservePlus(input);
        int len = decoded.length();
        StringBuilder collapsed = new StringBuilder(Math.min(len, MAX_INPUT_CODE_UNITS + 16));
        boolean pendingSpace = false;
        for (int i = 0; i < len; i++) {
            char ch = decoded.charAt(i);
            if (isCollapsibleWhitespace(ch)) {
                if (collapsed.length() > 0) {
                    pendingSpace = true;
                }
            } else {
                if (pendingSpace) {
                    collapsed.append(' ');
                    pendingSpace = false;
                }
                collapsed.append(ch);
            }
        }
        // Step 4: strip leading/trailing ASCII 0x0020 explicitly (already no leading/trailing space
        // due to pendingSpace tracking, but guard defensively).
        int start = 0;
        int end = collapsed.length();
        while (start < end && collapsed.charAt(start) == ' ') start++;
        while (end > start && collapsed.charAt(end - 1) == ' ') end--;
        if (start >= end) {
            return "";
        }
        // Step 5: truncate to 1024 UTF-16 code units without splitting surrogate pairs.
        int maxEnd = start + MAX_INPUT_CODE_UNITS;
        if (end > maxEnd) {
            end = maxEnd;
            char last = collapsed.charAt(end - 1);
            if (last >= 0xD800 && last <= 0xDBFF) {
                end--;
            }
            while (end > start && collapsed.charAt(end - 1) == ' ') {
                end--;
            }
        }
        return collapsed.substring(start, end);
    }

    private static boolean isCollapsibleWhitespace(char ch) {
        return ch <= 0x0020
                || (ch >= 0x007F && ch <= 0x00A0)
                || ch == 0x2028
                || ch == 0x2029
                || ch == 0x3000
                || ch == 0xFEFF;
    }

    public static String percentDecodeUtf8PreservePlus(String input) {
        if (input == null) {
            return "";
        }
        int pct = input.indexOf('%');
        if (pct < 0) {
            return input;
        }
        int len = input.length();
        StringBuilder out = new StringBuilder(len);
        out.append(input, 0, pct);
        ByteArrayOutputStream byteBuf = new ByteArrayOutputStream(32);
        CharsetDecoder decoder = null;
        int i = pct;
        while (i < len) {
            char ch = input.charAt(i);
            if (ch == '%' && i + 2 < len) {
                int hi = hexDigit(input.charAt(i + 1));
                int lo = hexDigit(input.charAt(i + 2));
                if (hi >= 0 && lo >= 0) {
                    byteBuf.reset();
                    while (i + 2 < len && input.charAt(i) == '%') {
                        int h = hexDigit(input.charAt(i + 1));
                        int l = hexDigit(input.charAt(i + 2));
                        if (h < 0 || l < 0) break;
                        byteBuf.write((h << 4) | l);
                        i += 3;
                    }
                    if (decoder == null) {
                        decoder =
                                UTF8.newDecoder()
                                        .onMalformedInput(CodingErrorAction.REPLACE)
                                        .onUnmappableCharacter(CodingErrorAction.REPLACE);
                    } else {
                        decoder.reset();
                    }
                    try {
                        out.append(decoder.decode(ByteBuffer.wrap(byteBuf.toByteArray())));
                    } catch (Exception e) {
                        out.append('\uFFFD');
                    }
                    continue;
                }
            }
            out.append(ch);
            i++;
        }
        return out.toString();
    }

    private static int hexDigit(char c) {
        if (c >= '0' && c <= '9') return c - '0';
        if (c >= 'a' && c <= 'f') return c - 'a' + 10;
        if (c >= 'A' && c <= 'F') return c - 'A' + 10;
        return -1;
    }

    public List<Badge> extract(String input) {
        if (input == null || input.isEmpty()) {
            return Collections.emptyList();
        }
        String norm = normalize(input);
        if (norm.isEmpty()) {
            return Collections.emptyList();
        }
        synchronized (cache) {
            List<Badge> cached = cache.get(norm);
            if (cached != null) {
                return cached;
            }
        }
        Set<String> matched = matchBaseRules(norm);
        List<Badge> result = finalizeBadges(matched);
        synchronized (cache) {
            cache.put(norm, result);
        }
        return result;
    }

    public List<Badge> extractFromSources(String... inputs) {
        if (inputs == null || inputs.length == 0) {
            return Collections.emptyList();
        }
        StringBuilder joined = new StringBuilder();
        for (int i = 0; i < inputs.length; i++) {
            String s = inputs[i];
            if (s != null && !s.isEmpty()) {
                if (joined.length() > 0) joined.append(' ');
                joined.append(s);
            }
        }
        return extract(joined.toString());
    }

    /**
     * Pure-data fusion API combining filename/line/URL sources with live player track metadata.
     *
     * <p>When {@code track} provides authoritative resolution or audio channel layout, those groups
     * override filename guesses while preserving compatible tags (e.g. REMUX, platform, DV) and
     * applying comboRules across the merged set.
     */
    public List<Badge> fuse(String[] sources, TrackSpec track) {
        StringBuilder srcJoined = new StringBuilder();
        if (sources != null) {
            for (int i = 0; i < sources.length; i++) {
                String s = sources[i];
                if (s != null && !s.isEmpty()) {
                    if (srcJoined.length() > 0) srcJoined.append(' ');
                    srcJoined.append(s);
                }
            }
        }
        String normSrc = normalize(srcJoined.toString());
        Set<String> matched = normSrc.isEmpty() ? new HashSet<String>() : matchBaseRules(normSrc);
        if (track != null) {
            String normTrack = normalize(track.toSyntheticTokens());
            if (!normTrack.isEmpty()) {
                Set<String> trackMatched = matchBaseRules(normTrack);
                if (!trackMatched.isEmpty()) {
                    boolean hasTrackRes = hasGroup(trackMatched, "resolution");
                    boolean hasTrackCh = hasGroup(trackMatched, "audio_channels");
                    boolean hasTrackVid = hasGroup(trackMatched, "video_codec");
                    boolean hasTrackConcreteAud = hasConcreteAudioCodec(trackMatched);
                    boolean trackAllowsAtmos =
                            trackMatched.contains("aud_atmos")
                                    || trackMatched.contains("aud_truehd")
                                    || trackMatched.contains("aud_ddp");
                    boolean hasTrackNonDvDr = hasNonDvDynamicRange(trackMatched);
                    if (hasTrackRes
                            || hasTrackCh
                            || hasTrackVid
                            || hasTrackConcreteAud
                            || hasTrackNonDvDr) {
                        Set<String> filtered = new HashSet<String>();
                        for (String id : matched) {
                            Rule r = ruleById.get(id);
                            if (r == null) continue;
                            if (hasTrackRes && "resolution".equals(r.group)) continue;
                            if (hasTrackCh && "audio_channels".equals(r.group)) continue;
                            if (hasTrackVid && "video_codec".equals(r.group)) continue;
                            if (hasTrackConcreteAud && "audio_codec".equals(r.group)) {
                                if (!("aud_atmos".equals(id) && trackAllowsAtmos)) {
                                    continue;
                                }
                            }
                            if (hasTrackNonDvDr
                                    && "dynamic_range".equals(r.group)
                                    && !"dr_dv".equals(id)) {
                                continue;
                            }
                            filtered.add(id);
                        }
                        matched = filtered;
                    }
                    matched.addAll(trackMatched);
                    reconcileDynamicRangeHierarchy(matched);
                }
            }
        }
        return finalizeBadges(matched);
    }

    private boolean hasConcreteAudioCodec(Set<String> ids) {
        for (String id : ids) {
            if ("aud_atmos".equals(id)) continue;
            Rule r = ruleById.get(id);
            if (r != null && "audio_codec".equals(r.group)) {
                return true;
            }
        }
        return false;
    }

    private boolean hasNonDvDynamicRange(Set<String> ids) {
        for (String id : ids) {
            if ("dr_dv".equals(id)) continue;
            Rule r = ruleById.get(id);
            if (r != null && "dynamic_range".equals(r.group)) {
                return true;
            }
        }
        return false;
    }

    private static void reconcileDynamicRangeHierarchy(Set<String> matched) {
        if (matched.contains("dr_hdr10plus")) {
            matched.remove("dr_hdr10");
            matched.remove("dr_hdr");
        } else if (matched.contains("dr_hdr10") || matched.contains("dr_hlg")) {
            matched.remove("dr_hdr");
        }
    }

    private boolean hasGroup(Set<String> ids, String group) {
        for (String id : ids) {
            Rule r = ruleById.get(id);
            if (r != null && group.equals(r.group)) {
                return true;
            }
        }
        return false;
    }

    private Set<String> matchBaseRules(String norm) {
        String lower = norm.toLowerCase(java.util.Locale.ROOT);
        Set<String> matched = new HashSet<String>();
        for (int i = 0; i < rules.size(); i++) {
            Rule r = rules.get(i);
            if (r.couldMatch(lower) && r.pattern.matcher(norm).find()) {
                matched.add(r.id);
            }
        }
        return matched;
    }

    private List<Badge> finalizeBadges(Set<String> matched) {
        if (matched.isEmpty()) {
            return Collections.emptyList();
        }
        List<Badge> out = new ArrayList<Badge>(matched.size());
        for (int i = 0; i < comboRules.size(); i++) {
            ComboRule combo = comboRules.get(i);
            boolean allPresent = true;
            for (int j = 0; j < combo.requires.length; j++) {
                if (!matched.contains(combo.requires[j])) {
                    allPresent = false;
                    break;
                }
            }
            if (allPresent) {
                for (int j = 0; j < combo.consumes.length; j++) {
                    matched.remove(combo.consumes[j]);
                }
                out.add(combo.badge);
            }
        }
        for (String id : matched) {
            Rule r = ruleById.get(id);
            if (r != null) {
                out.add(r.badge);
            }
        }
        Collections.sort(out, BADGE_ORDER);
        return Collections.unmodifiableList(out);
    }

    public int cacheSize() {
        synchronized (cache) {
            return cache.size();
        }
    }

    public void clearCache() {
        synchronized (cache) {
            cache.clear();
        }
    }

    public static List<Badge> extractBadges(String input) {
        return getDefault().extract(input);
    }

    public static List<Badge> extractBadgesFromSources(String... inputs) {
        return getDefault().extractFromSources(inputs);
    }

    public static List<Badge> fuseBadges(String[] sources, TrackSpec track) {
        return getDefault().fuse(sources, track);
    }

    public static String formatDotJoined(List<Badge> badges, int maxBadges) {
        if (badges == null || badges.isEmpty() || maxBadges == 0) {
            return "";
        }
        int limit = maxBadges > 0 ? Math.min(maxBadges, badges.size()) : badges.size();
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < limit; i++) {
            if (i > 0) sb.append(" · ");
            sb.append(badges.get(i).label);
        }
        return sb.toString();
    }

    private static Rule stdRule(
            String id, String group, String label, String regex, int priority, String style) {
        return new Rule(id, group, label, regex, priority, style, true);
    }

    private static MediaBadges buildBuiltinDefault() {
        List<Rule> r = new ArrayList<Rule>(45);
        r.add(
                stdRule(
                        "res_8k",
                        "resolution",
                        "8K",
                        "^(?!(?:^|.*[^a-z0-9])(?:2160[pi]|4k|uhd|ultra[ ._-]?hd|1440[pi]|2k|qhd|wqhd|1080[pi]|fhd|full[ ._-]?hd|720[pi]|hd720|(?:480|576)[pi]|(?:3840|4096|2560|1920|1280)[ ]*[x×][ ]*[0-9]{3,4}[pi]?|(?:720|640)[ ]*[x×][ ]*(?:480|576)[pi]?)(?![a-z0-9]))(?!.*(?:(?:蓝光|超清|高清|极速|高码)[ ]*1080(?![a-z0-9])|(?:^|[^a-z0-9])1080[ ]*(?:高码|蓝光|超清)|标清))(?!(?:^|.*[^a-z0-9/])sd(?![a-z0-9/])(?![ ._-]?cards?(?![a-z0-9])))(?:^|.*[^a-z0-9])(?:4320[pi]|8k|fuhd|7680[ ]*[x×][ ]*4320[pi]?)(?![a-z0-9])",
                        100,
                        "uhdGold"));
        r.add(
                stdRule(
                        "res_4k",
                        "resolution",
                        "4K",
                        "^(?!(?:^|.*[^a-z0-9])(?:1080[pi]|fhd|full[ ._-]?hd|720[pi]|hd720|(?:480|576)[pi]|(?:1920|1280)[ ]*[x×][ ]*[0-9]{3,4}[pi]?|(?:720|640)[ ]*[x×][ ]*(?:480|576)[pi]?)(?![a-z0-9]))(?!.*(?:(?:蓝光|超清|高清|极速|高码)[ ]*1080(?![a-z0-9])|(?:^|[^a-z0-9])1080[ ]*(?:高码|蓝光|超清)|标清))(?!(?:^|.*[^a-z0-9/])sd(?![a-z0-9/])(?![ ._-]?cards?(?![a-z0-9])))(?:^|.*[^a-z0-9])(?:2160[pi]|4k|uhd|ultra[ ._-]?hd|(?:3840|4096)[ ]*[x×][ ]*[0-9]{3,4}[pi]?)(?![a-z0-9])",
                        110,
                        "uhdGold"));
        r.add(
                stdRule(
                        "res_2k",
                        "resolution",
                        "2K",
                        "^(?!(?:^|.*[^a-z0-9])(?:2160[pi]|4k|uhd|ultra[ ._-]?hd|1080[pi]|fhd|full[ ._-]?hd|720[pi]|hd720|(?:480|576)[pi]|(?:3840|4096|1920|1280)[ ]*[x×][ ]*[0-9]{3,4}[pi]?|(?:720|640)[ ]*[x×][ ]*(?:480|576)[pi]?)(?![a-z0-9]))(?!.*(?:(?:蓝光|超清|高清|极速|高码)[ ]*1080(?![a-z0-9])|(?:^|[^a-z0-9])1080[ ]*(?:高码|蓝光|超清)|标清))(?!(?:^|.*[^a-z0-9/])sd(?![a-z0-9/])(?![ ._-]?cards?(?![a-z0-9])))(?:^|.*[^a-z0-9])(?:1440[pi]|2k|qhd|wqhd|2560[ ]*[x×][ ]*[0-9]{3,4}[pi]?)(?![a-z0-9])",
                        120,
                        "hdCyan"));
        r.add(
                stdRule(
                        "res_1080p",
                        "resolution",
                        "1080p",
                        "^(?:(?:^|.*[^a-z0-9])(?:1080[pi]|fhd|full[ ._-]?hd|1920[ ]*[x×][ ]*[0-9]{3,4}[pi]?)(?![a-z0-9])|.*(?:蓝光|超清|高清|极速|高码)[ ]*1080(?![a-z0-9])|(?:^|.*[^a-z0-9])1080[ ]*(?:高码|蓝光|超清))",
                        130,
                        "hdCyan"));
        r.add(
                stdRule(
                        "res_720p",
                        "resolution",
                        "720p",
                        "^(?!(?:^|.*[^a-z0-9])(?:1080[pi]|fhd|full[ ._-]?hd|1920[ ]*[x×][ ]*[0-9]{3,4}[pi]?)(?![a-z0-9]))(?!.*(?:(?:蓝光|超清|高清|极速|高码)[ ]*1080(?![a-z0-9])|(?:^|[^a-z0-9])1080[ ]*(?:高码|蓝光|超清)))(?:^|.*[^a-z0-9])(?:720[pi]|hd720|1280[ ]*[x×][ ]*[0-9]{3,4}[pi]?)(?![a-z0-9])",
                        140,
                        "sdNeutral"));
        r.add(
                stdRule(
                        "res_sd",
                        "resolution",
                        "SD",
                        "^(?!(?:^|.*[^a-z0-9])(?:1080[pi]|fhd|full[ ._-]?hd|1920[ ]*[x×][ ]*[0-9]{3,4}[pi]?|720[pi]|hd720|1280[ ]*[x×][ ]*[0-9]{3,4}[pi]?)(?![a-z0-9]))(?!.*(?:(?:蓝光|超清|高清|极速|高码)[ ]*1080(?![a-z0-9])|(?:^|[^a-z0-9])1080[ ]*(?:高码|蓝光|超清)))(?:(?:^|.*[^a-z0-9])(?:(?:480|576)[pi]|(?:720|640)[ ]*[x×][ ]*(?:480|576)[pi]?)(?![a-z0-9])|.*标清|(?:^|.*[^a-z0-9/])sd(?![a-z0-9/])(?![ ._-]?cards?(?![a-z0-9])))",
                        150,
                        "sdNeutral"));
        r.add(
                stdRule(
                        "dr_dv",
                        "dynamic_range",
                        "DV",
                        "^(?:(?:^|.*[^a-z0-9])(?:dv|dovi|dolby[ ._-]?vision|(?:dvh[e1]|dav1)(?:\\.[0-9]{2}(?:\\.[0-9]{2})?)?)(?![a-z0-9])|.*杜比视界)",
                        210,
                        "visionPurple"));
        r.add(
                stdRule(
                        "dr_hdr10plus",
                        "dynamic_range",
                        "HDR10+",
                        "^(?:^|.*[^a-z0-9])(?:hdr10\\+(?![0-9])|hdr10[ ._-]?plus(?![a-z0-9]))",
                        220,
                        "visionPurple"));
        r.add(
                stdRule(
                        "dr_hdr10",
                        "dynamic_range",
                        "HDR10",
                        "^(?!(?:^|.*[^a-z0-9])(?:hdr10\\+(?![0-9])|hdr10[ ._-]?plus(?![a-z0-9])))(?:^|.*[^a-z0-9])(?:hdr10(?![a-z0-9+])(?![ ._-]?bits?(?![a-z0-9]))|hdr[ ._-]10(?![a-z0-9+])(?![ ._-]?bits?(?![a-z0-9]))|smpte[ ._-]?2084(?![a-z0-9]))",
                        230,
                        "hdrBlue"));
        r.add(
                stdRule(
                        "dr_hlg",
                        "dynamic_range",
                        "HLG",
                        "^(?:^|.*[^a-z0-9])(?:hlg|arib[ ._-]?std[ ._-]?b67)(?![a-z0-9])",
                        240,
                        "hdrBlue"));
        r.add(
                stdRule(
                        "dr_hdr",
                        "dynamic_range",
                        "HDR",
                        "^(?!(?:^|.*[^a-z0-9])(?:hdr10\\+(?![0-9])|hdr10[ ._-]?plus(?![a-z0-9])|hdr10(?![a-z0-9+])(?![ ._-]?bits?(?![a-z0-9]))|hdr[ ._-]10(?![a-z0-9+])(?![ ._-]?bits?(?![a-z0-9]))|smpte[ ._-]?2084(?![a-z0-9])|hlg(?![a-z0-9])|arib[ ._-]?std[ ._-]?b67(?![a-z0-9])|(?:non|no)[ ._-]?hdr(?![a-z0-9])))(?:(?:^|.*[^a-z0-9])(?:hdr(?:[ ._-]?vivid)?(?![a-z0-9])|hdr10[ ._-]?bits?(?![a-z0-9]))|(?=(?:^|.*[^a-z0-9])bt\\.?2020(?![a-z0-9]))(?=(?:^|.*[^a-z0-9])pq(?![a-z0-9])).*|.*臻彩)",
                        250,
                        "hdrBlue"));
        r.add(
                stdRule(
                        "src_remux",
                        "source_quality",
                        "REMUX",
                        "^(?:^|.*[^a-z0-9])(?:(?:bd|uhd)[ ._-]?)?remux(?![a-z0-9])",
                        310,
                        "discEmerald"));
        r.add(
                stdRule(
                        "src_bluray",
                        "source_quality",
                        "BluRay",
                        "^(?!(?:^|.*[^a-z0-9])(?:(?:bd|uhd)[ ._-]?)?remux(?![a-z0-9]))(?:(?:^|.*[^a-z0-9])(?:(?:blu[ ._-]?ray|bdrip|brrip|bdmv|bdiso|uhdbd|bd(?:25|50|66|100))(?![a-z0-9])|bd(?![a-z0-9])(?!://))|.*(?:蓝光原盘|原盘))",
                        320,
                        "discEmerald"));
        r.add(
                stdRule(
                        "src_webdl",
                        "source_quality",
                        "WEB-DL",
                        "^(?:^|.*[^a-z0-9])web[ ._-]?dl(?![a-z0-9])",
                        330,
                        "streamTeal"));
        r.add(
                stdRule(
                        "src_webrip",
                        "source_quality",
                        "WEBRip",
                        "^(?!(?:^|.*[^a-z0-9])web[ ._-]?dl(?![a-z0-9]))(?:^|.*[^a-z0-9])web[ ._-]?rip(?![a-z0-9])",
                        340,
                        "streamTeal"));
        r.add(
                stdRule(
                        "src_hdtv",
                        "source_quality",
                        "HDTV",
                        "^(?:^|.*[^a-z0-9])(?:hdtv(?:rip)?|pdtv|dsr)(?![a-z0-9])",
                        350,
                        "streamTeal"));
        r.add(
                stdRule(
                        "aud_atmos",
                        "audio_codec",
                        "ATMOS",
                        "^(?:(?:^|.*[^a-z0-9])(?:atmos(?![a-z0-9])|e[ ._-]?ac[ ._-]?3[ ._-]?joc(?![a-z0-9])|ec\\+3(?:(?![a-z0-9])|(?=[125678]\\.[01](?![0-9]))))|.*(?:杜比)?全景声)",
                        410,
                        "spatialAudio"));
        r.add(
                stdRule(
                        "aud_dtsx",
                        "audio_codec",
                        "DTS:X",
                        "^(?:^|.*[^a-z0-9])dts[ ._:+-]?x(?:(?![a-z0-9])|(?=[125678]\\.[01](?![0-9])))",
                        420,
                        "spatialAudio"));
        r.add(
                stdRule(
                        "aud_truehd",
                        "audio_codec",
                        "TrueHD",
                        "^(?:^|.*[^a-z0-9])(?:true[ ._-]?hd|mlp)(?:(?![a-z0-9])|(?=[125678]\\.[01](?![0-9])))",
                        430,
                        "spatialAudio"));
        r.add(
                stdRule(
                        "aud_dtshd_ma",
                        "audio_codec",
                        "DTS-HD MA",
                        "^(?!(?:^|.*[^a-z0-9])dts[ ._:+-]?x(?:(?![a-z0-9])|(?=[125678]\\.[01](?![0-9]))))(?:^|.*[^a-z0-9])(?:dts[ ._-]?hd[ ._-]?ma|dts[ ._-]?ma|dts[ ._-]?xll)(?:(?![a-z0-9])|(?=[125678]\\.[01](?![0-9])))",
                        440,
                        "spatialAudio"));
        r.add(
                stdRule(
                        "aud_dtshd",
                        "audio_codec",
                        "DTS-HD",
                        "^(?!(?:^|.*[^a-z0-9])(?:dts[ ._:+-]?x|dts[ ._-]?hd[ ._-]?ma|dts[ ._-]?ma|dts[ ._-]?xll)(?:(?![a-z0-9])|(?=[125678]\\.[01](?![0-9]))))(?:^|.*[^a-z0-9])(?:dts[ ._-]?hd(?:[ ._-]?(?:hr|hra))?|dts[ ._-]?(?:hr|hra))(?:(?![a-z0-9])|(?=[125678]\\.[01](?![0-9])))",
                        450,
                        "standardAudio"));
        r.add(
                stdRule(
                        "aud_dts",
                        "audio_codec",
                        "DTS",
                        "^(?!(?:^|.*[^a-z0-9])(?:dts[ ._:+-]?x|dts[ ._-]?hd(?:[ ._-]?(?:ma|hr|hra))?|dts[ ._-]?(?:ma|xll|hr|hra))(?:(?![a-z0-9])|(?=[125678]\\.[01](?![0-9]))))(?:^|.*[^a-z0-9])dts(?:[ ._-]?es)?(?:(?![a-z0-9])|(?=[125678]\\.[01](?![0-9])))",
                        460,
                        "standardAudio"));
        r.add(
                stdRule(
                        "aud_ddp",
                        "audio_codec",
                        "DD+",
                        "^(?:^|.*[^a-z0-9])(?:dd\\+|(?:ddp|e[ ._-]?ac[ ._-]?3|ec[ ._-]?3|ec\\+3|dolby[ ._-]?digital[ ._-]?plus)(?:(?![a-z0-9])|(?=[125678]\\.[01](?![0-9]))))",
                        470,
                        "standardAudio"));
        r.add(
                stdRule(
                        "aud_dd",
                        "audio_codec",
                        "DD",
                        "^(?!(?:^|.*[^a-z0-9])(?:dd\\+|(?:ddp|e[ ._-]?ac[ ._-]?3|ec[ ._-]?3|ec\\+3|dolby[ ._-]?digital[ ._-]?plus)(?:(?![a-z0-9])|(?=[125678]\\.[01](?![0-9])))))(?:(?:^|.*[^a-z0-9])(?:ac[ ._-]?3|dolby[ ._-]?(?:digital|audio))(?:(?![a-z0-9])|(?=[125678]\\.[01](?![0-9])))|(?:^|.*[^a-z0-9])dd[ ._-]?[125678]\\.[01](?![0-9])|(?:^|.*[^a-z0-9/])dd(?![a-z0-9+/]))",
                        480,
                        "standardAudio"));
        r.add(
                stdRule(
                        "aud_lpcm",
                        "audio_codec",
                        "LPCM",
                        "^(?:^|.*[^a-z0-9])(?:lpcm|pcm)(?:(?![a-z0-9])|(?=[125678]\\.[01](?![0-9])))",
                        485,
                        "standardAudio"));
        r.add(
                stdRule(
                        "aud_flac",
                        "audio_codec",
                        "FLAC",
                        "^(?:^|.*[^a-z0-9])flac(?:(?![a-z0-9])|(?=[125678]\\.[01](?![0-9])))",
                        490,
                        "standardAudio"));
        r.add(
                stdRule(
                        "aud_opus",
                        "audio_codec",
                        "OPUS",
                        "^(?:^|.*[^a-z0-9])opus(?:(?![a-z0-9])|(?=[125678]\\.[01](?![0-9])))",
                        492,
                        "standardAudio"));
        r.add(
                stdRule(
                        "aud_aac",
                        "audio_codec",
                        "AAC",
                        "^(?:^|.*[^a-z0-9])(?:(?:he[ ._-]?)?aac(?:[ ._-]?lc)?(?:(?![a-z0-9])|(?=[125678]\\.[01](?![0-9])))|mp4a(?:\\.40\\.[0-9]+)?(?![a-z0-9]))",
                        495,
                        "standardAudio"));
        r.add(
                stdRule(
                        "ch_7_1",
                        "audio_channels",
                        "7.1",
                        "^(?:(?:^|.*[^a-z0-9.]|.*(?:[a-z]|(?:19|20)[0-9]{2}|e?ac[ ._-]?3|ec[ ._+-]?3|[hx][ ._-]?26[45]|av0?1|vp0?9)\\.|.*(?:ddp|dd|aac|dts|truehd|flac|lpcm|pcm|opus))7\\.1(?:\\.[24])?(?:[ ]?ch(?:annels?)?)?(?![a-z0-9])(?![ ]*(?:gb|mb|kb|tb|gib|mib|fps|hz|khz|mhz)(?![a-z0-9]))|(?:^|.*[^a-z0-9])8[ ]*ch(?:annels?)?(?![a-z0-9]))",
                        510,
                        "standardAudio"));
        r.add(
                stdRule(
                        "ch_5_1",
                        "audio_channels",
                        "5.1",
                        "^(?!(?:^|.*[^a-z0-9.]|.*(?:[a-z]|(?:19|20)[0-9]{2}|e?ac[ ._-]?3|ec[ ._+-]?3|[hx][ ._-]?26[45]|av0?1|vp0?9)\\.|.*(?:ddp|dd|aac|dts|truehd|flac|lpcm|pcm|opus))7\\.1(?:\\.[24])?(?:[ ]?ch(?:annels?)?)?(?![a-z0-9])(?![ ]*(?:gb|mb|kb|tb|gib|mib|fps|hz|khz|mhz)(?![a-z0-9])))(?!(?:^|.*[^a-z0-9])8[ ]*ch(?:annels?)?(?![a-z0-9]))(?:(?:^|.*[^a-z0-9.]|.*(?:[a-z]|(?:19|20)[0-9]{2}|e?ac[ ._-]?3|ec[ ._+-]?3|[hx][ ._-]?26[45]|av0?1|vp0?9)\\.|.*(?:ddp|dd|aac|dts|truehd|flac|lpcm|pcm|opus))5\\.1(?:\\.[24])?(?:[ ]?ch(?:annels?)?)?(?![a-z0-9])(?![ ]*(?:gb|mb|kb|tb|gib|mib|fps|hz|khz|mhz)(?![a-z0-9]))|(?:^|.*[^a-z0-9])6[ ]*ch(?:annels?)?(?![a-z0-9]))",
                        520,
                        "standardAudio"));
        r.add(
                stdRule(
                        "ch_2_0",
                        "audio_channels",
                        "2.0",
                        "^(?!(?:^|.*[^a-z0-9.]|.*(?:[a-z]|(?:19|20)[0-9]{2}|e?ac[ ._-]?3|ec[ ._+-]?3|[hx][ ._-]?26[45]|av0?1|vp0?9)\\.|.*(?:ddp|dd|aac|dts|truehd|flac|lpcm|pcm|opus))[57]\\.1(?:\\.[24])?(?:[ ]?ch(?:annels?)?)?(?![a-z0-9])(?![ ]*(?:gb|mb|kb|tb|gib|mib|fps|hz|khz|mhz)(?![a-z0-9])))(?!(?:^|.*[^a-z0-9])[68][ ]*ch(?:annels?)?(?![a-z0-9]))(?:(?:^|.*[^a-z0-9.]|.*(?:[a-z]|(?:19|20)[0-9]{2}|e?ac[ ._-]?3|ec[ ._+-]?3|[hx][ ._-]?26[45]|av0?1|vp0?9)\\.|.*(?:ddp|dd|aac|dts|truehd|flac|lpcm|pcm|opus))2\\.0(?:[ ]?ch(?:annels?)?)?(?![a-z0-9])(?![ ]*(?:gb|mb|kb|tb|gib|mib|fps|hz|khz|mhz)(?![a-z0-9]))|(?:^|.*[^a-z0-9])(?:2[ ]*ch(?:annels?)?|stereo)(?![a-z0-9])|.*(?:立体声|双声道))",
                        530,
                        "standardAudio"));
        r.add(
                stdRule(
                        "vid_av1",
                        "video_codec",
                        "AV1",
                        "^(?:^|.*[^a-z0-9])(?:(?:svt[ ._-]?)?av1|(?:av01|dav1)(?:\\.[0-9a-z.]+)?)(?![a-z0-9])",
                        610,
                        "codecSlate"));
        r.add(
                stdRule(
                        "vid_hevc",
                        "video_codec",
                        "HEVC",
                        "^(?:^|.*[^a-z0-9])(?:hevc|[hx][ ._-]?265|h(?:ev|vc)1(?:\\.[0-9a-z.]+)?)(?![a-z0-9])",
                        620,
                        "codecSlate"));
        r.add(
                stdRule(
                        "vid_vp9",
                        "video_codec",
                        "VP9",
                        "^(?:^|.*[^a-z0-9])(?:vp9|vp09(?:\\.[0-9a-z.]+)?)(?![a-z0-9])",
                        630,
                        "codecSlate"));
        r.add(
                stdRule(
                        "vid_avc",
                        "video_codec",
                        "AVC",
                        "^(?:^|.*[^a-z0-9])(?:avc|[hx][ ._-]?264|avc1(?:\\.[0-9a-z]+)?)(?![a-z0-9])",
                        640,
                        "codecSlate"));
        r.add(
                stdRule(
                        "plt_nf",
                        "release_platform",
                        "NF",
                        "^(?:^|.*[^a-z0-9])(?:netflix|nflx|nf)(?![a-z0-9])",
                        710,
                        "platformTag"));
        r.add(
                stdRule(
                        "plt_amzn",
                        "release_platform",
                        "AMZN",
                        "^(?:^|.*[^a-z0-9])(?:amzn|amazon|prime[ ._-]?video)(?![a-z0-9])",
                        715,
                        "platformTag"));
        r.add(
                stdRule(
                        "plt_atvp",
                        "release_platform",
                        "ATVP",
                        "^(?:^|.*[^a-z0-9])(?:(?:atvp|aptv)(?![a-z0-9])|apple[ ._-]?tv\\+(?![a-z0-9])|apple[ ._-]?tv(?![a-z0-9+]))",
                        720,
                        "platformTag"));
        r.add(
                stdRule(
                        "plt_dsnp",
                        "release_platform",
                        "DSNP",
                        "^(?:^|.*[^a-z0-9])(?:(?:dsnp|dsny)(?![a-z0-9])|disney\\+(?![a-z0-9])|disney[ ._-]?plus(?![a-z0-9]))",
                        725,
                        "platformTag"));
        r.add(
                stdRule(
                        "plt_max",
                        "release_platform",
                        "MAX",
                        "^(?:^|.*[^a-z0-9])(?:hmax(?![a-z0-9])|hbo[ ._-]?max(?![a-z0-9])|max(?=[ ._-]+(?:2160[pi]|1080[pi]|720[pi]|4k|web[ ._-]?(?:dl|rip))(?![a-z0-9])))",
                        730,
                        "platformTag"));
        r.add(
                stdRule(
                        "plt_hulu",
                        "release_platform",
                        "HULU",
                        "^(?:^|.*[^a-z0-9])hulu(?![a-z0-9])",
                        735,
                        "platformTag"));
        r.add(
                stdRule(
                        "plt_pcok",
                        "release_platform",
                        "PCOK",
                        "^(?:^|.*[^a-z0-9])(?:pcok|peacock)(?![a-z0-9])",
                        740,
                        "platformTag"));
        r.add(
                stdRule(
                        "plt_pmtp",
                        "release_platform",
                        "PMTP",
                        "^(?:^|.*[^a-z0-9])(?:(?:pmtp|pamp)(?![a-z0-9])|paramount\\+(?![a-z0-9])|paramount[ ._-]?plus(?![a-z0-9]))",
                        745,
                        "platformTag"));
        r.add(
                stdRule(
                        "plt_bili",
                        "release_platform",
                        "BILI",
                        "^(?:(?:^|.*[^a-z0-9])(?:bili(?:bili)?|b[ ._-]?global)(?![a-z0-9])|(?:^|.*[^a-z0-9])b站(?!点))",
                        750,
                        "platformTag"));
        r.add(
                stdRule(
                        "plt_cr",
                        "release_platform",
                        "CR",
                        "^(?:(?:^|.*[^a-z0-9])crunchyroll(?![a-z0-9])|.*\\[cr\\]|(?:^|.*[^a-z0-9])cr(?=[ ._-]+(?:1080[pi]|720[pi]|web[ ._-]?(?:dl|rip))(?![a-z0-9])))",
                        755,
                        "platformTag"));

        List<ComboRule> c = new ArrayList<ComboRule>(3);
        c.add(
                new ComboRule(
                        "combo_dv_atmos",
                        "dynamic_range",
                        "DV · ATMOS",
                        new String[] {"dr_dv", "aud_atmos"},
                        new String[] {"dr_dv", "aud_atmos"},
                        205,
                        "premiumCombo"));
        c.add(
                new ComboRule(
                        "combo_dv_truehd",
                        "dynamic_range",
                        "DV · TrueHD",
                        new String[] {"dr_dv", "aud_truehd"},
                        new String[] {"dr_dv", "aud_truehd"},
                        206,
                        "premiumCombo"));
        c.add(
                new ComboRule(
                        "combo_dv_ddp",
                        "dynamic_range",
                        "DV · DD+",
                        new String[] {"dr_dv", "aud_ddp"},
                        new String[] {"dr_dv", "aud_ddp"},
                        207,
                        "premiumCombo"));
        return new MediaBadges(r, c);
    }
}
