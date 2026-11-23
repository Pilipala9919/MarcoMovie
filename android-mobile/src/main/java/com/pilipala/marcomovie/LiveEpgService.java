package com.pilipala.marcomovie;

import java.io.BufferedInputStream;
import java.io.BufferedReader;
import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.net.HttpURLConnection;
import java.net.URI;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Calendar;
import java.util.Collections;
import java.util.Date;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.TimeZone;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import java.util.zip.GZIPInputStream;

/**
 * Pure-Java XMLTV EPG loader (supports plain XML and {@code .xml.gz}) and IPTV catchup / timeshift
 * URL builder. Keeps bounded memory by filtering programs to the active replay + upcoming window.
 */
public final class LiveEpgService {
    private LiveEpgService() {}

    private static final int MAX_COMPRESSED_BYTES = 8 * 1024 * 1024;
    private static final int MAX_XML_BYTES = 20 * 1024 * 1024;
    private static final int MAX_PROGRAMS = 60000;
    private static final long CACHE_TTL_MS = 30L * 60L * 1000L;
    private static final long PAST_WINDOW_MS = 7L * 24L * 3600L * 1000L;
    private static final long FUTURE_WINDOW_MS = 36L * 3600L * 1000L;

    private static final Map<String, CachedGuide> CACHE = new LinkedHashMap<>();

    private static final Pattern XMLTV_TIME =
            Pattern.compile(
                    "^(\\d{4})(\\d{2})(\\d{2})(\\d{2})(\\d{2})(\\d{2})?(?:\\s*([+-])(\\d{2})(\\d{2}))?");
    private static final Pattern ATTR_PATTERN =
            Pattern.compile("([A-Za-z0-9_:-]+)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)')");
    private static final Pattern CATCHUP_TOKEN = Pattern.compile("\\$\\{\\(([be])\\)([^}]+)\\}");

    public static final class Program {
        public final String title;
        public final String desc;
        public final long startMs;
        public final long stopMs;

        public Program(String title, String desc, long startMs, long stopMs) {
            this.title = title == null ? "" : title.trim();
            this.desc = desc == null ? "" : desc.trim();
            this.startMs = startMs;
            this.stopMs = stopMs;
        }

        public boolean isLiveAt(long nowMs) {
            return startMs <= nowMs && (stopMs <= 0 || nowMs < stopMs);
        }

        public String timeRangeLabel() {
            SimpleDateFormat fmt = new SimpleDateFormat("HH:mm", Locale.ROOT);
            String startStr = fmt.format(new Date(startMs));
            String stopStr = stopMs > 0 ? fmt.format(new Date(stopMs)) : "";
            return stopStr.isEmpty() ? startStr : startStr + "-" + stopStr;
        }

        public String dayAndTimeLabel() {
            SimpleDateFormat fmt = new SimpleDateFormat("MM-dd HH:mm", Locale.ROOT);
            return fmt.format(new Date(startMs));
        }
    }

    public static final class Guide {
        private final Map<String, List<Program>> byChannelId = new HashMap<>();
        private final Map<String, Set<String>> idByCanonicalName = new HashMap<>();

        public boolean isEmpty() {
            return byChannelId.isEmpty();
        }

        public int channelCount() {
            return byChannelId.size();
        }

        public List<Program> programsFor(String tvgId, String tvgName, String channelName) {
            if (tvgId != null && !tvgId.trim().isEmpty()) {
                List<Program> direct = byChannelId.get(tvgId.trim().toLowerCase(Locale.ROOT));
                if (direct != null && !direct.isEmpty()) return direct;
            }
            for (String candidate : new String[] {tvgName, channelName, tvgId}) {
                if (candidate == null || candidate.trim().isEmpty()) continue;
                String canon =
                        LiveQualityPolicy.canonicalChannelName(candidate).toLowerCase(Locale.ROOT);
                Set<String> ids = idByCanonicalName.get(canon);
                if (ids != null) {
                    for (String id : ids) {
                        List<Program> list = byChannelId.get(id);
                        if (list != null && !list.isEmpty()) return list;
                    }
                }
                List<Program> exact = byChannelId.get(canon);
                if (exact != null && !exact.isEmpty()) return exact;
            }
            return Collections.emptyList();
        }

        public Program currentProgram(
                String tvgId, String tvgName, String channelName, long nowMs) {
            List<Program> list = programsFor(tvgId, tvgName, channelName);
            for (Program p : list) {
                if (p.isLiveAt(nowMs)) return p;
            }
            return null;
        }

        public List<Program> pastPrograms(
                String tvgId, String tvgName, String channelName, long nowMs, int maxDays) {
            long cutoff = nowMs - Math.max(1, Math.min(14, maxDays)) * 24L * 3600L * 1000L;
            List<Program> list = programsFor(tvgId, tvgName, channelName);
            List<Program> out = new ArrayList<>();
            for (Program p : list) {
                if (p.stopMs > 0 && p.stopMs <= nowMs && p.startMs >= cutoff) {
                    out.add(p);
                }
            }
            Collections.sort(out, (a, b) -> Long.compare(b.startMs, a.startMs));
            return out;
        }

        public List<Program> upcomingPrograms(
                String tvgId, String tvgName, String channelName, long nowMs, int limit) {
            List<Program> list = programsFor(tvgId, tvgName, channelName);
            List<Program> out = new ArrayList<>();
            for (Program p : list) {
                if (p.startMs > nowMs) {
                    out.add(p);
                    if (out.size() >= limit) break;
                }
            }
            return out;
        }

        void addAlias(String channelId, String displayName) {
            if (channelId == null || channelId.trim().isEmpty()) return;
            String idKey = channelId.trim().toLowerCase(Locale.ROOT);
            if (displayName != null && !displayName.trim().isEmpty()) {
                String canon =
                        LiveQualityPolicy.canonicalChannelName(displayName)
                                .toLowerCase(Locale.ROOT);
                Set<String> nameIds = idByCanonicalName.get(canon);
                if (nameIds == null) {
                    nameIds = new HashSet<>();
                    idByCanonicalName.put(canon, nameIds);
                }
                nameIds.add(idKey);
            }
            String canonId =
                    LiveQualityPolicy.canonicalChannelName(channelId).toLowerCase(Locale.ROOT);
            Set<String> canonIds = idByCanonicalName.get(canonId);
            if (canonIds == null) {
                canonIds = new HashSet<>();
                idByCanonicalName.put(canonId, canonIds);
            }
            canonIds.add(idKey);
        }

        void addProgram(String channelId, Program program) {
            if (channelId == null || channelId.trim().isEmpty() || program.title.isEmpty()) return;
            String idKey = channelId.trim().toLowerCase(Locale.ROOT);
            List<Program> programs = byChannelId.get(idKey);
            if (programs == null) {
                programs = new ArrayList<>();
                byChannelId.put(idKey, programs);
            }
            programs.add(program);
            String canonId =
                    LiveQualityPolicy.canonicalChannelName(channelId).toLowerCase(Locale.ROOT);
            Set<String> canonIds = idByCanonicalName.get(canonId);
            if (canonIds == null) {
                canonIds = new HashSet<>();
                idByCanonicalName.put(canonId, canonIds);
            }
            canonIds.add(idKey);
        }

        void finalizeSort() {
            for (List<Program> list : byChannelId.values()) {
                Collections.sort(list, (a, b) -> Long.compare(a.startMs, b.startMs));
            }
        }
    }

    private static final class CachedGuide {
        final Guide guide;
        final long fetchedAt;

        CachedGuide(Guide guide, long fetchedAt) {
            this.guide = guide;
            this.fetchedAt = fetchedAt;
        }
    }

    public static String firstEpgUrl(LiveCatalog.Catalog catalog, String userEpgUrl) {
        if (userEpgUrl != null && !userEpgUrl.trim().isEmpty()) {
            return userEpgUrl.trim();
        }
        if (catalog == null) return "";
        for (String key : new String[] {"x-tvg-url", "url-tvg", "tvg-url"}) {
            String raw = catalog.options.get(key);
            if (raw != null && !raw.trim().isEmpty()) {
                for (String part : raw.split("[,\\s]+")) {
                    String candidate = part.trim();
                    if (Cms.isHttp(candidate)) return candidate;
                }
            }
        }
        return "";
    }

    public static Guide load(String epgUrl) throws Exception {
        return load(epgUrl, System.currentTimeMillis());
    }

    public static Guide load(String epgUrl, long nowMs) throws Exception {
        if (epgUrl == null || !Cms.isHttp(epgUrl.trim())) {
            throw new IOException("EPG 节目单地址无效");
        }
        String normUrl = Cms.normalizeHttp(epgUrl.trim());
        synchronized (CACHE) {
            CachedGuide hit = CACHE.get(normUrl);
            if (hit != null && nowMs - hit.fetchedAt < CACHE_TTL_MS) {
                return hit.guide;
            }
        }
        byte[] rawBytes = downloadBytes(normUrl);
        Guide guide = parseXmltv(rawBytes, nowMs);
        synchronized (CACHE) {
            if (CACHE.size() >= 6) CACHE.clear();
            CACHE.put(normUrl, new CachedGuide(guide, nowMs));
        }
        return guide;
    }

    private static byte[] downloadBytes(String urlStr) throws IOException {
        URL next = new URL(urlStr);
        for (int hop = 0; hop < 5; hop++) {
            HttpURLConnection conn = (HttpURLConnection) next.openConnection();
            conn.setConnectTimeout(10000);
            conn.setReadTimeout(15000);
            conn.setInstanceFollowRedirects(false);
            conn.setRequestProperty("User-Agent", Cms.USER_AGENT);
            conn.setRequestProperty("Accept-Encoding", "gzip");
            try {
                RequestScope.attach(conn);
                int status = conn.getResponseCode();
                if (status == 301
                        || status == 302
                        || status == 303
                        || status == 307
                        || status == 308) {
                    String loc = conn.getHeaderField("Location");
                    if (loc == null) throw new IOException("EPG 重定向缺少目标地址");
                    next = new URL(next, loc);
                    continue;
                }
                if (status < 200 || status >= 300) {
                    throw new IOException("EPG 请求失败（HTTP " + status + "）");
                }
                InputStream in = conn.getInputStream();
                if ("gzip".equalsIgnoreCase(conn.getContentEncoding())) {
                    in = new GZIPInputStream(in);
                }
                try (InputStream stream = in;
                        ByteArrayOutputStream out = new ByteArrayOutputStream()) {
                    byte[] buf = new byte[8192];
                    int n;
                    while ((n = stream.read(buf)) != -1) {
                        if (out.size() + n > MAX_COMPRESSED_BYTES) {
                            throw new IOException("EPG 文件超过大小限制");
                        }
                        out.write(buf, 0, n);
                    }
                    return out.toByteArray();
                }
            } finally {
                RequestScope.detach(conn);
                conn.disconnect();
            }
        }
        throw new IOException("EPG 重定向次数过多");
    }

    /** Parses plain XMLTV or GZIP-compressed {@code .xml.gz} bytes into a {@link Guide}. */
    public static Guide parseXmltv(byte[] rawBytes, long nowMs) throws IOException {
        if (rawBytes == null || rawBytes.length == 0) return new Guide();
        InputStream in = new BufferedInputStream(new ByteArrayInputStream(rawBytes));
        if (rawBytes.length >= 2 && (rawBytes[0] & 0xFF) == 0x1F && (rawBytes[1] & 0xFF) == 0x8B) {
            in = new GZIPInputStream(in);
        }
        ByteArrayOutputStream xmlOut = new ByteArrayOutputStream();
        byte[] buf = new byte[8192];
        int n;
        while ((n = in.read(buf)) != -1) {
            if (xmlOut.size() + n > MAX_XML_BYTES) break;
            xmlOut.write(buf, 0, n);
        }
        in.close();
        String xml = new String(xmlOut.toByteArray(), StandardCharsets.UTF_8);
        return parseXmltvString(xml, nowMs);
    }

    public static Guide parseXmltvString(String xml, long nowMs) {
        Guide guide = new Guide();
        if (xml == null || xml.isEmpty()) return guide;
        long minStart = nowMs - PAST_WINDOW_MS;
        long maxStart = nowMs + FUTURE_WINDOW_MS;

        // 1. Parse <channel id="..."> ... <display-name>...</display-name> </channel>
        int pos = 0;
        int len = xml.length();
        while (pos < len) {
            int chStart = indexOfTag(xml, "<channel", pos);
            if (chStart < 0) break;
            int chTagEnd = xml.indexOf('>', chStart);
            if (chTagEnd < 0) break;
            int chClose = xml.indexOf("</channel>", chTagEnd);
            if (chClose < 0) break;
            String header = xml.substring(chStart, chTagEnd);
            String id = extractAttr(header, "id");
            if (!id.isEmpty()) {
                guide.addAlias(id, id);
                String inner = xml.substring(chTagEnd + 1, chClose);
                int dnPos = 0;
                while (dnPos < inner.length()) {
                    int dnStart = indexOfTag(inner, "<display-name", dnPos);
                    if (dnStart < 0) break;
                    int dnOpenEnd = inner.indexOf('>', dnStart);
                    int dnClose = inner.indexOf("</display-name>", dnOpenEnd);
                    if (dnOpenEnd < 0 || dnClose < 0) break;
                    String display = unescapeXml(inner.substring(dnOpenEnd + 1, dnClose)).trim();
                    if (!display.isEmpty()) guide.addAlias(id, display);
                    dnPos = dnClose + 15;
                }
            }
            pos = chClose + 10;
        }

        // 2. Parse <programme start="..." stop="..." channel="..."> <title>...</title> ...
        pos = 0;
        int kept = 0;
        while (pos < len && kept < MAX_PROGRAMS) {
            int pStart = indexOfTag(xml, "<programme", pos);
            if (pStart < 0) break;
            int pTagEnd = xml.indexOf('>', pStart);
            if (pTagEnd < 0) break;
            int pClose = xml.indexOf("</programme>", pTagEnd);
            if (pClose < 0) break;
            String header = xml.substring(pStart, pTagEnd);
            String channelId = extractAttr(header, "channel");
            long startMs = parseXmltvTime(extractAttr(header, "start"));
            long stopMs = parseXmltvTime(extractAttr(header, "stop"));
            if (!channelId.isEmpty() && startMs > 0 && startMs >= minStart && startMs <= maxStart) {
                String inner = xml.substring(pTagEnd + 1, pClose);
                String title = extractFirstElementText(inner, "title");
                if (!title.isEmpty()) {
                    String desc = extractFirstElementText(inner, "desc");
                    guide.addProgram(channelId, new Program(title, desc, startMs, stopMs));
                    kept++;
                }
            }
            pos = pClose + 12;
        }
        guide.finalizeSort();
        return guide;
    }

    /** Enriches a parsed catalog's channels with current EPG program names in place. */
    public static int applyGuideToCatalog(LiveCatalog.Catalog catalog, Guide guide, long nowMs) {
        if (catalog == null || guide == null || guide.isEmpty()) return 0;
        int matched = 0;
        for (LiveCatalog.Group g : catalog.groups) {
            for (LiveCatalog.Channel ch : g.channels) {
                String existingEpg = ch.options.get("epg");
                if (existingEpg != null && !existingEpg.trim().isEmpty()) continue;
                String tvgName = ch.options.get("tvg-name");
                Program cur = guide.currentProgram(ch.id, tvgName, ch.name, nowMs);
                if (cur != null && !cur.title.isEmpty()) {
                    ch.options.put("epg", cur.title + " (" + cur.timeRangeLabel() + ")");
                    matched++;
                }
            }
        }
        return matched;
    }

    public static long parseXmltvTime(String raw) {
        if (raw == null) return 0L;
        Matcher m = XMLTV_TIME.matcher(raw.trim());
        if (!m.find()) return 0L;
        int year = Integer.parseInt(m.group(1));
        int month = Integer.parseInt(m.group(2)) - 1;
        int day = Integer.parseInt(m.group(3));
        int hour = Integer.parseInt(m.group(4));
        int min = Integer.parseInt(m.group(5));
        int sec = m.group(6) != null ? Integer.parseInt(m.group(6)) : 0;
        TimeZone tz;
        if (m.group(7) != null) {
            tz = TimeZone.getTimeZone("GMT" + m.group(7) + m.group(8) + ":" + m.group(9));
        } else {
            tz = TimeZone.getDefault();
        }
        Calendar cal = Calendar.getInstance(tz, Locale.ROOT);
        cal.clear();
        cal.set(year, month, day, hour, min, sec);
        return cal.getTimeInMillis();
    }

    /**
     * Checks whether a live channel declares IPTV catchup/replay support.
     */
    public static boolean supportsCatchup(LiveCatalog.Channel channel) {
        if (channel == null) return false;
        String mode = optionIgnoreCase(channel.options, "catchup");
        String source = optionIgnoreCase(channel.options, "catchup-source");
        return !mode.isEmpty() || !source.isEmpty();
    }

    public static int catchupDays(LiveCatalog.Channel channel) {
        if (channel == null) return 7;
        String raw = optionIgnoreCase(channel.options, "catchup-days");
        try {
            int n = Integer.parseInt(raw.trim());
            return Math.max(1, Math.min(14, n));
        } catch (Exception ignored) {
            return 7;
        }
    }

    /**
     * Builds a catchup / timeshift playback URL for a historical program according to Kodi/TiviMate
     * M3U {@code catchup} / {@code catchup-source} attributes.
     */
    public static String buildCatchupUrl(
            String liveStreamUrl,
            String catchupMode,
            String catchupSource,
            long startMs,
            long stopMs,
            TimeZone tz) {
        if (liveStreamUrl == null || liveStreamUrl.trim().isEmpty() || startMs <= 0) return "";
        String baseUrl = liveStreamUrl.trim();
        String mode = catchupMode == null ? "" : catchupMode.trim().toLowerCase(Locale.ROOT);
        String src = catchupSource == null ? "" : catchupSource.trim();
        long endMs = stopMs > startMs ? stopMs : startMs + 3600L * 1000L;
        TimeZone zone = tz != null ? tz : TimeZone.getDefault();

        if (src.isEmpty()) {
            if ("shift".equals(mode)) {
                src = "?utc=${start}&lutc=${end}";
                mode = "append";
            } else if ("flussonic".equals(mode)) {
                String replaced =
                        baseUrl.replaceFirst(
                                "/(?:index|video|playlist)\\.m3u8",
                                "/timeshift_abs-" + (startMs / 1000L) + ".m3u8");
                if (!replaced.equals(baseUrl)) return replaced;
                src = "?utc=${start}&lutc=${end}";
                mode = "append";
            } else {
                return "";
            }
        }

        String rendered = expandCatchupTemplate(src, startMs, endMs, zone);
        if ("append".equals(mode)
                || (mode.isEmpty() && (rendered.startsWith("?") || rendered.startsWith("&")))) {
            if (rendered.startsWith("?") && baseUrl.contains("?")) {
                return baseUrl + "&" + rendered.substring(1);
            }
            if (!rendered.startsWith("?") && !rendered.startsWith("&") && !baseUrl.endsWith("/")) {
                return baseUrl + (baseUrl.contains("?") ? "&" : "?") + rendered;
            }
            return baseUrl + rendered;
        }
        if (rendered.regionMatches(true, 0, "http://", 0, 7)
                || rendered.regionMatches(true, 0, "https://", 0, 8)) {
            return rendered;
        }
        try {
            return URI.create(baseUrl).resolve(rendered).toString();
        } catch (Exception ignored) {
            return baseUrl + rendered;
        }
    }

    private static String expandCatchupTemplate(
            String template, long startMs, long endMs, TimeZone zone) {
        long startSec = startMs / 1000L;
        long endSec = endMs / 1000L;
        long durSec = Math.max(60L, endSec - startSec);
        StringBuffer sb = new StringBuffer();
        Matcher m = CATCHUP_TOKEN.matcher(template);
        while (m.find()) {
            boolean isEnd = "e".equals(m.group(1));
            String spec = m.group(2);
            long ts = isEnd ? endMs : startMs;
            String val;
            if ("timestamp".equalsIgnoreCase(spec)) {
                val = Long.toString(ts / 1000L);
            } else {
                SimpleDateFormat fmt = new SimpleDateFormat(spec, Locale.ROOT);
                fmt.setTimeZone(zone);
                val = fmt.format(new Date(ts));
            }
            m.appendReplacement(sb, Matcher.quoteReplacement(val));
        }
        m.appendTail(sb);
        String out = sb.toString();
        out = out.replace("${start}", Long.toString(startSec));
        out = out.replace("{start}", Long.toString(startSec));
        out = out.replace("{utc}", Long.toString(startSec));
        out = out.replace("${end}", Long.toString(endSec));
        out = out.replace("{end}", Long.toString(endSec));
        out = out.replace("{utcend}", Long.toString(endSec));
        out = out.replace("${duration}", Long.toString(durSec));
        out = out.replace("{duration}", Long.toString(durSec));
        Calendar cal = Calendar.getInstance(zone, Locale.ROOT);
        cal.setTimeInMillis(startMs);
        out = out.replace("{Y}", String.format(Locale.ROOT, "%04d", cal.get(Calendar.YEAR)));
        out = out.replace("{m}", String.format(Locale.ROOT, "%02d", cal.get(Calendar.MONTH) + 1));
        out =
                out.replace(
                        "{d}", String.format(Locale.ROOT, "%02d", cal.get(Calendar.DAY_OF_MONTH)));
        out = out.replace("{H}", String.format(Locale.ROOT, "%02d", cal.get(Calendar.HOUR_OF_DAY)));
        out = out.replace("{M}", String.format(Locale.ROOT, "%02d", cal.get(Calendar.MINUTE)));
        out = out.replace("{S}", String.format(Locale.ROOT, "%02d", cal.get(Calendar.SECOND)));
        return out;
    }

    static String optionIgnoreCase(Map<String, String> map, String key) {
        if (map == null || key == null) return "";
        for (Map.Entry<String, String> e : map.entrySet()) {
            if (e.getKey() != null && e.getKey().equalsIgnoreCase(key) && e.getValue() != null) {
                return e.getValue().trim();
            }
        }
        return "";
    }

    private static int indexOfTag(String xml, String tagPrefix, int from) {
        int idx = xml.indexOf(tagPrefix, from);
        while (idx >= 0) {
            int after = idx + tagPrefix.length();
            if (after < xml.length()) {
                char c = xml.charAt(after);
                if (c == ' ' || c == '>' || c == '\t' || c == '\r' || c == '\n') {
                    return idx;
                }
            }
            idx = xml.indexOf(tagPrefix, after);
        }
        return -1;
    }

    private static String extractAttr(String tagHeader, String name) {
        Matcher m = ATTR_PATTERN.matcher(tagHeader);
        while (m.find()) {
            if (name.equalsIgnoreCase(m.group(1))) {
                String v = m.group(2) != null ? m.group(2) : m.group(3);
                return v == null ? "" : unescapeXml(v).trim();
            }
        }
        return "";
    }

    private static String extractFirstElementText(String xmlFragment, String tagName) {
        int start = indexOfTag(xmlFragment, "<" + tagName, 0);
        if (start < 0) return "";
        int openEnd = xmlFragment.indexOf('>', start);
        if (openEnd < 0) return "";
        int close = xmlFragment.indexOf("</" + tagName + ">", openEnd);
        if (close < 0) return "";
        return unescapeXml(xmlFragment.substring(openEnd + 1, close)).trim();
    }

    private static String unescapeXml(String raw) {
        if (raw == null || raw.isEmpty()) return "";
        String s = raw;
        if (s.startsWith("<![CDATA[") && s.endsWith("]]>")) {
            s = s.substring(9, s.length() - 3);
        }
        return s.replace("&amp;", "&")
                .replace("&lt;", "<")
                .replace("&gt;", ">")
                .replace("&quot;", "\"")
                .replace("&apos;", "'")
                .replace("&#39;", "'");
    }
}
