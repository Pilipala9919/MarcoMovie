package com.pilipala.marcomovie;

import org.json.*;
import com.pilipala.source.Json;
import com.pilipala.source.Warehouse;
import java.io.*;
import java.net.*;
import java.util.*;
import java.util.concurrent.*;
import javax.net.ssl.*;

/** A bounded, non-executing adapter for standard TVBox type-1 JSON CMS sites. */
public final class Cms {
    public static final int MAX_JSON = 16 * 1024 * 1024;
    public static final String USER_AGENT = "okhttp/3.15";
    public static final String SAFARI_USER_AGENT =
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15";
    public static final String MOBILE_USER_AGENT =
            "Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 "
                    + "(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36";
    public static final String TVBOX_USER_AGENT =
            "Mozilla/5.0 (Linux; Android 11; TVBox) AppleWebKit/537.36 "
                    + "(KHTML, like Gecko) Version/4.0 Chrome/114.0.0.0 Safari/537.36";

    private static final String[] DEFAULT_DOH_ENDPOINTS = {
        "https://223.5.5.5/dns-query", "https://1.12.12.12/dns-query"
    };
    private static volatile String[] dohEndpoints = DEFAULT_DOH_ENDPOINTS;
    private static final int MAX_DOH_CACHE_ENTRIES = 256;
    private static final long MIN_DOH_TTL_MS = 60_000L;
    private static final long MAX_DOH_TTL_MS = 600_000L;
    private static final ConcurrentHashMap<String, DohCacheEntry> DOH_CACHE =
            new ConcurrentHashMap<>();
    private static final ExecutorService DOH_EXECUTOR =
            Executors.newFixedThreadPool(
                    4,
                    r -> {
                        Thread t = new Thread(r, "cms-doh");
                        t.setDaemon(true);
                        return t;
                    });

    private static final class DohCacheEntry {
        final List<InetAddress> addresses;
        final long expireAtMs;

        DohCacheEntry(List<InetAddress> addresses, long expireAtMs) {
            this.addresses = addresses;
            this.expireAtMs = expireAtMs;
        }
    }

    static void setDohEndpointsForTest(String... endpoints) {
        dohEndpoints =
                (endpoints == null || endpoints.length == 0)
                        ? DEFAULT_DOH_ENDPOINTS
                        : endpoints.clone();
        DOH_CACHE.clear();
    }

    static void clearDohCacheForTest() {
        DOH_CACHE.clear();
    }

    /**
     * Null-safe string reader for {@link JSONObject}. Android's built-in {@code
     * JSONObject.optString} converts {@code JSONObject.NULL} into the literal string {@code
     * "null"}, which otherwise pollutes {@code jar}, {@code ua}, {@code api}, and header fields.
     */
    public static String optSafeString(JSONObject obj, String key) {
        return optSafeString(obj, key, "");
    }

    public static String optSafeString(JSONObject obj, String key, String fallback) {
        if (obj == null || key == null || obj.isNull(key)) return fallback;
        Object val = obj.opt(key);
        if (val == null || val == JSONObject.NULL || JSONObject.NULL.equals(val)) {
            return fallback;
        }
        String str = val instanceof String ? (String) val : String.valueOf(val);
        if ("null".equalsIgnoreCase(str.trim())) return fallback;
        return str;
    }

    public static final class Parse {
        public String name = "", url = "";
        public int type;
        public final Map<String, String> headers = new LinkedHashMap<>();
    }

    public static final class SniffRule {
        public String name = "";
        public final List<String> hosts = new ArrayList<>();
        public final List<String> regex = new ArrayList<>();
        public final List<String> exclude = new ArrayList<>();
        public String script = "";

        boolean matchesHost(String pageUrl) {
            if (hosts.isEmpty()) return true;
            String host = "";
            if (pageUrl != null && !pageUrl.isEmpty()) {
                try {
                    String h = new URI(pageUrl).getHost();
                    host = h == null ? "" : h.toLowerCase(Locale.ROOT);
                } catch (Exception ignored) {
                }
            }
            if (host.isEmpty()) return false;
            for (String h : hosts) {
                if (h == null || h.trim().isEmpty()) continue;
                String pattern = h.trim().toLowerCase(Locale.ROOT);
                if ("*".equals(pattern)) return true;
                if (pattern.startsWith("*.")) {
                    String suffix = pattern.substring(1);
                    if (host.endsWith(suffix) || host.equals(pattern.substring(2))) return true;
                } else if (host.equals(pattern)
                        || host.endsWith("." + pattern)
                        || host.contains(pattern)) {
                    return true;
                }
            }
            return false;
        }
    }

    public static final class Config {
        public final List<Site> sites = new ArrayList<>();
        public final List<Parse> parses = new ArrayList<>();
        public final List<SniffRule> rules = new ArrayList<>();
        public final List<String> ads = new ArrayList<>();
        public String raw;
        public String spider;
        public String origin = "", warehouse = "";
        public JSONArray depots = new JSONArray();
    }

    public static final class Site {
        public static final String STATUS_OK = "ok";
        public static final String STATUS_NEEDS_JAR = "needs-jar";
        public static final String STATUS_UNSUPPORTED_TYPE = "unsupported-type";
        public static final String STATUS_ADAPTER_MISSING = "adapter-missing";
        public static final String STATUS_EXT_TOO_LARGE = "ext-too-large";
        public static final String STATUS_CUSTOM_SITE_URL = "custom-site-url";
        public static final String STATUS_PARSER_REQUIRED = "parser-required";
        public static final int MAX_EXT_SIZE = 128 * 1024;

        public String key = "", name = "", api = "", playUrl = "", jar = "";
        public String originalKey = "", originalApi = "", group = "默认分组";
        public int type;
        public final Map<String, String> headers = new LinkedHashMap<>();
        public boolean requiresParser;
        public boolean searchable = true;
        public Object ext;
        public boolean extTooLarge;

        public String siteId() {
            return originalKey != null && !originalKey.isEmpty() ? originalKey : key;
        }

        public boolean isExtTooLarge() {
            if (extTooLarge) return true;
            if (ext instanceof String) {
                return ((String) ext).length() > MAX_EXT_SIZE;
            }
            if (ext instanceof JSONObject || ext instanceof JSONArray) {
                return ext.toString().length() > MAX_EXT_SIZE;
            }
            return false;
        }

        public boolean isNetdiskSite() {
            String lowerApi = api == null ? "" : api.toLowerCase(Locale.ROOT);
            String lowerName = name == null ? "" : name.toLowerCase(Locale.ROOT);
            String lowerKey = key == null ? "" : key.toLowerCase(Locale.ROOT);
            if (lowerName.contains("秒播")
                    || lowerApi.startsWith("csp_wex")
                    || lowerApi.contains("ikanbot")
                    || lowerApi.contains("yiys")) {
                return false;
            }
            return lowerApi.contains("wogg")
                    || lowerApi.contains("ainew")
                    || lowerApi.contains("qwmkv")
                    || lowerApi.contains("soai")
                    || lowerApi.contains("sokaka")
                    || lowerApi.contains("seedhub")
                    || lowerApi.contains("pansou")
                    || lowerApi.contains("s_zps")
                    || lowerApi.contains("ypanso")
                    || lowerApi.contains("bpanso")
                    || lowerApi.contains("yiso")
                    || lowerApi.contains("panta")
                    || lowerApi.contains("mypan")
                    || lowerKey.contains("mypan")
                    || lowerName.contains("我的云盘")
                    || lowerName.contains("我的网盘")
                    || lowerName.contains("我的┃网盘")
                    || lowerName.contains("网盘")
                    || lowerName.contains("云盘")
                    || lowerApi.contains("alipansou")
                    || lowerApi.contains("tudou");
        }

        public boolean supported() {
            return !"mydrive".equals(key)
                    && (type == 0 || type == 1)
                    && isHttp(api)
                    && !isScriptOrJarApi(api)
                    && !isExtTooLarge();
        }

        public String capabilityStatus() {
            if (isExtTooLarge()) {
                return STATUS_EXT_TOO_LARGE;
            }
            if ("mydrive".equals(key)) {
                return STATUS_UNSUPPORTED_TYPE;
            }
            if (api != null
                    && (api.startsWith("emby://")
                            || api.startsWith("alist://")
                            || api.startsWith("catpaw://")
                            || (type == 4 && isHttp(api) && !isScriptOrJarApi(api)))) {
                return STATUS_OK;
            }
            if ((type == 3 || isScriptOrJarApi(api)) && isNetdiskSite()) {
                return STATUS_ADAPTER_MISSING;
            }
            if (type == 3
                    || isScriptOrJarApi(api)
                    || (type != 0 && type != 1 && type != 4 && jar != null && !jar.isEmpty())) {
                return STATUS_NEEDS_JAR;
            }
            if (type != 0 && type != 1 && type != 4) {
                return STATUS_UNSUPPORTED_TYPE;
            }
            if (!isHttp(api)) {
                return STATUS_CUSTOM_SITE_URL;
            }
            return STATUS_OK;
        }

        public String playbackHint() {
            if (requiresParser && (playUrl == null || playUrl.trim().isEmpty())) {
                return capabilityReason(STATUS_PARSER_REQUIRED);
            }
            return "";
        }

        public static String capabilityReason(String status) {
            if (STATUS_OK.equals(status)) {
                return "正常可用";
            } else if (STATUS_NEEDS_JAR.equals(status)) {
                return "此来源需要 Spider / JS / JAR 运行环境，基础版尚未支持";
            } else if (STATUS_UNSUPPORTED_TYPE.equals(status)) {
                return "暂不支持此类型来源，已保留在列表中";
            } else if (STATUS_ADAPTER_MISSING.equals(status)) {
                return "此网盘源的原始插件尚未适配当前设备，无法读取原始网盘线路";
            } else if (STATUS_EXT_TOO_LARGE.equals(status)) {
                return "扩展参数超过大小上限，无法加载";
            } else if (STATUS_CUSTOM_SITE_URL.equals(status)) {
                return "此来源不是可直接请求的 HTTP(S) CMS";
            } else if (STATUS_PARSER_REQUIRED.equals(status)) {
                return "需要解析器，当前环境缺少可用解析配置";
            }
            return "此来源暂不可用";
        }

        public String limitation() {
            return capabilityReason(capabilityStatus());
        }
    }

    public static final class Category {
        public String id, name;

        public Category() {}

        public Category(String id, String name) {
            this.id = id;
            this.name = name;
        }
    }

    public static final class Video {
        public String id,
                title,
                poster,
                remarks,
                year,
                area,
                genre,
                actor,
                director,
                description,
                action,
                tag,
                doubanScore = "",
                doubanId = "";
        public final List<Line> lines = new ArrayList<>();
    }

    public static double parseValidDoubanScore(String raw) {
        if (raw == null) return 0.0;
        String s = raw.trim();
        if (s.isEmpty() || "0".equals(s) || "0.0".equals(s) || "0.00".equals(s)) return 0.0;
        java.util.regex.Matcher m =
                java.util.regex.Pattern.compile("([1-9]\\.[0-9]|10\\.0|[2-9])").matcher(s);
        if (!m.find()) return 0.0;
        try {
            double v = Double.parseDouble(m.group(1));
            // MacCMS often fills unrated vod_score with placeholder 10.0 or 0.0; accept [2.0, 9.9]
            if (v >= 2.0 && v <= 9.9) return v;
        } catch (NumberFormatException ignored) {
        }
        return 0.0;
    }

    public static final class Line {
        public String name;
        public final List<Episode> episodes = new ArrayList<>();
    }

    public static final class Episode {
        public String name, url;
        public final Map<String, String> headers = new LinkedHashMap<>();
        public JSONObject media = new JSONObject();
    }

    public static final class Listing {
        public int page = 1, pageCount = 1;
        public final List<Video> videos = new ArrayList<>();
    }

    public static final class ImageRequest {
        public String url;
        public final Map<String, String> headers = new LinkedHashMap<>();
    }

    public static ImageRequest imageRequest(String value) {
        ImageRequest out = new ImageRequest();
        out.url = value;
        java.util.regex.Matcher m =
                java.util.regex.Pattern.compile("@(?i:Referer|User-Agent)=").matcher(value);
        int first = -1;
        String key = null;
        int start = 0;
        while (m.find()) {
            if (first < 0) first = m.start();
            if (key != null) out.headers.put(key, value.substring(start, m.start()));
            key = value.substring(m.start() + 1, m.end() - 1);
            start = m.end();
        }
        if (key != null) {
            out.headers.put(key, value.substring(start));
            out.url = value.substring(0, first);
        }
        for (Iterator<Map.Entry<String, String>> it = out.headers.entrySet().iterator();
                it.hasNext(); ) {
            String val = it.next().getValue();
            if (val.contains("\r") || val.contains("\n")) it.remove();
        }
        return out;
    }

    public static boolean isMedia(String value) {
        if (isHttp(value)) return true;
        if (value == null) return false;
        String lower = value.trim().toLowerCase(Locale.ROOT);
        return lower.startsWith("rtsp://")
                || lower.startsWith("rtsps://")
                || lower.startsWith("rtmp://")
                || lower.startsWith("rtmps://")
                || lower.startsWith("rtmpt://")
                || lower.startsWith("rtmpe://")
                || lower.startsWith("rtmfp://")
                || lower.startsWith("mms://")
                || lower.startsWith("mmsh://")
                || lower.startsWith("mmst://")
                || lower.startsWith("udp://")
                || lower.startsWith("rtp://")
                || lower.startsWith("srt://")
                || lower.startsWith("rist://")
                || lower.startsWith("webrtc://")
                || lower.startsWith("proxy://")
                || lower.startsWith("file://")
                || lower.startsWith("content://");
    }

    public static boolean isDirectStreamUrl(String value) {
        if (value == null || value.isEmpty()) return false;
        String lower = value.trim().toLowerCase(Locale.ROOT);
        if (lower.startsWith("rtsp://")
                || lower.startsWith("rtsps://")
                || lower.startsWith("rtmp://")
                || lower.startsWith("rtmps://")
                || lower.startsWith("rtmpt://")
                || lower.startsWith("rtmpe://")
                || lower.startsWith("rtmfp://")
                || lower.startsWith("udp://")
                || lower.startsWith("rtp://")
                || lower.startsWith("mms://")
                || lower.startsWith("mmsh://")
                || lower.startsWith("mmst://")
                || lower.startsWith("srt://")
                || lower.startsWith("rist://")
                || lower.startsWith("webrtc://")
                || lower.startsWith("proxy://")
                || lower.startsWith("file://")
                || lower.startsWith("content://")
                || lower.startsWith("magnet:?")) return true;
        if (!isHttp(value)) return false;
        String path = value.split("[?#]", 2)[0].toLowerCase(Locale.ROOT);
        return path.endsWith(".m3u8")
                || path.endsWith(".mp4")
                || path.endsWith(".flv")
                || path.endsWith(".mkv")
                || path.endsWith(".ts")
                || path.endsWith(".webm")
                || path.endsWith(".mpd")
                || path.endsWith(".mov")
                || path.endsWith(".avi")
                || lower.contains(".m3u8?")
                || lower.contains(".mp4?")
                || lower.contains(".flv?")
                || lower.contains("/proxy?");
    }

    public static boolean isHttp(String value) {
        try {
            URL u = new URL(value);
            return (u.getProtocol().equals("http") || u.getProtocol().equals("https"))
                    && !u.getHost().isEmpty();
        } catch (Exception e) {
            return false;
        }
    }

    static boolean sameOrigin(String first, String second) {
        if (!isHttp(first) || !isHttp(second)) return false;
        try {
            URL a = new URL(first), b = new URL(second);
            int ap = a.getPort() < 0 ? a.getDefaultPort() : a.getPort();
            int bp = b.getPort() < 0 ? b.getDefaultPort() : b.getPort();
            return a.getProtocol().equalsIgnoreCase(b.getProtocol())
                    && a.getHost().equalsIgnoreCase(b.getHost())
                    && ap == bp;
        } catch (MalformedURLException invalid) {
            return false;
        }
    }

    /** Source credentials belong to that origin; a play result may explicitly supply its own. */
    static Map<String, String> inheritedHeaders(
            String origin, String target, Map<String, String> input) {
        Map<String, String> out = new LinkedHashMap<>();
        boolean same = sameOrigin(origin, target);
        for (Map.Entry<String, String> entry : input.entrySet()) {
            String key = entry.getKey();
            if (same
                    || !(key.equalsIgnoreCase("Authorization")
                            || key.equalsIgnoreCase("Proxy-Authorization")
                            || key.equalsIgnoreCase("Cookie")
                            || key.equalsIgnoreCase("Cookie2"))) out.put(key, entry.getValue());
        }
        return out;
    }

    static void mergeHeaders(Map<String, String> target, Map<String, String> overrides) {
        for (Map.Entry<String, String> entry : overrides.entrySet()) {
            for (Iterator<String> keys = target.keySet().iterator(); keys.hasNext(); )
                if (keys.next().equalsIgnoreCase(entry.getKey())) keys.remove();
            target.put(entry.getKey(), entry.getValue());
        }
    }

    public static String normalizeHttp(String value) throws Exception {
        URL u = new URL(value);
        String host = u.getHost();
        if (!host.startsWith("[")) host = IDN.toASCII(host);
        return u.getProtocol()
                + "://"
                + (u.getUserInfo() != null ? u.getUserInfo() + "@" : "")
                + host
                + (u.getPort() >= 0 ? ":" + u.getPort() : "")
                + u.getFile()
                + (u.getRef() != null ? "#" + u.getRef() : "");
    }

    static String fileUri(java.io.File file) {
        return "file://" + file.toURI().getRawPath();
    }

    /**
     * Converts TVBox / OK影视 {@code clan://localhost/...} or {@code clan://...} local storage URIs
     * (#41) into standard {@code file://} URIs rooted at external storage ({@code /sdcard}).
     */
    public static String normalizeClanUri(String value) {
        if (value == null) return "";
        String trimmed = value.trim();
        if (!trimmed.regionMatches(true, 0, "clan://", 0, 7)) return value;
        String rest = trimmed.substring(7);
        if (rest.regionMatches(true, 0, "localhost/", 0, 10)) {
            rest = rest.substring(10);
        } else if (rest.regionMatches(true, 0, "127.0.0.1/", 0, 10)) {
            rest = rest.substring(10);
        }
        while (rest.startsWith("/")) rest = rest.substring(1);
        if (rest.isEmpty() || rest.contains("..")) return value;
        java.io.File sdcard = null;
        try {
            Object dir =
                    Class.forName("android.os.Environment")
                            .getMethod("getExternalStorageDirectory")
                            .invoke(null);
            if (dir instanceof java.io.File) sdcard = (java.io.File) dir;
        } catch (Throwable ignored) {
        }
        if (sdcard == null) sdcard = new java.io.File("/sdcard");
        return fileUri(new java.io.File(sdcard, rest));
    }

    /**
     * Preserves {@code file://} origins only for real filesystem URIs; {@code content://} document
     * picks keep an empty origin so relative paths are not rewritten against bogus {@code
     * file:///document/...} paths and imported configs remain eligible for ConfigLibrary & sync.
     */
    public static String localImportOrigin(String scheme, String uriString) {
        if (uriString != null && uriString.trim().regionMatches(true, 0, "clan://", 0, 7)) {
            return normalizeClanUri(uriString);
        }
        if ("file".equalsIgnoreCase(scheme) && uriString != null) {
            return uriString.trim();
        }
        return "";
    }

    static String resolve(String origin, String target) {
        if (target == null) return "";
        if (target.trim().regionMatches(true, 0, "clan://", 0, 7)) {
            return normalizeClanUri(target);
        }
        String effectiveOrigin =
                origin != null && origin.trim().regionMatches(true, 0, "clan://", 0, 7)
                        ? normalizeClanUri(origin)
                        : origin;
        if (isHttp(target)
                || target.isEmpty()
                || target.startsWith("file://")
                || target.startsWith("csp_")
                || effectiveOrigin == null
                || (!isHttp(effectiveOrigin) && !effectiveOrigin.startsWith("file://")))
            return target;
        try {
            URL resolved = new URL(new URL(effectiveOrigin), target);
            return "file".equals(resolved.getProtocol()) && effectiveOrigin.startsWith("file://")
                    ? fileUri(new java.io.File(resolved.toURI()))
                    : resolved.toString();
        } catch (Exception e) {
            return target;
        }
    }

    public static boolean looksLikeJsSpider(String text, String origin) {
        String content = text == null ? "" : text.trim().replaceFirst("^\\uFEFF", "").trim();
        if (content.startsWith("//bb")) return true;
        if (content.startsWith("{") || content.startsWith("[") || content.startsWith("<"))
            return false;
        String cleanOrigin =
                origin == null ? "" : origin.split("[?#]", 2)[0].toLowerCase(Locale.ROOT);
        if (cleanOrigin.endsWith(".js") || cleanOrigin.endsWith(".mjs")) return true;
        if (text == null) return false;
        String t = text.trim();
        return t.contains("__jsEvalReturn")
                || t.contains("export default")
                || java.util.regex.Pattern.compile(
                                "\\bmodule\\s*\\.\\s*exports\\b|\\bexports\\s*(?:\\.|\\[)")
                        .matcher(t)
                        .find()
                || java.util.regex.Pattern.compile(
                                "\\bexport\\s+(?:(?:async\\s+)?function|const|let|var)\\s+(?:init|home|homeVod|category|search|detail|play)\\b")
                        .matcher(t)
                        .find()
                || java.util.regex.Pattern.compile("\\bexport\\s*(?:\\{|\\*)").matcher(t).find()
                || looksLikeDrpyRule(t);
    }

    static boolean looksLikeDrpyRule(String text) {
        if (text == null) return false;
        String content = scriptCode(text);
        if (java.util.regex.Pattern.compile("\\b__jsEvalReturn\\b").matcher(content).find()
                || java.util.regex.Pattern.compile(
                                "\\b(?:module\\s*(?:\\.\\s*exports\\b|\\[)|exports\\s*(?:\\.|\\[))|(?:^|[;}\\n])\\s*export\\b")
                        .matcher(content)
                        .find()) return false;
        return java.util.regex.Pattern.compile(
                        "(?:^|[;\\n])\\s*(?:var|let|const)\\s+rule\\s*=",
                        java.util.regex.Pattern.MULTILINE)
                .matcher(content)
                .find();
    }

    /** Classification only: omit comments and literals, never evaluate downloaded code. */
    private static String scriptCode(String source) {
        StringBuilder code = new StringBuilder(source.length());
        boolean regexAllowed = true;
        for (int i = 0; i < source.length(); ) {
            char c = source.charAt(i);
            char next = i + 1 < source.length() ? source.charAt(i + 1) : 0;
            if (c == '/' && (next == '/' || next == '*')) {
                boolean line = next == '/';
                i += 2;
                code.append(' ');
                while (i < source.length()) {
                    char current = source.charAt(i++);
                    if (current == '\n') {
                        code.append('\n');
                        if (line) break;
                    }
                    if (!line && current == '*' && i < source.length() && source.charAt(i) == '/') {
                        i++;
                        break;
                    }
                }
                continue;
            }
            if (c == '\'' || c == '"' || c == '`' || (c == '/' && regexAllowed)) {
                char quote = c;
                boolean escaped = false, characterClass = false;
                code.append(' ');
                i++;
                while (i < source.length()) {
                    char current = source.charAt(i++);
                    if (escaped) {
                        escaped = false;
                        continue;
                    }
                    if (current == '\\') {
                        escaped = true;
                        continue;
                    }
                    if (quote == '/') {
                        if (current == '[') characterClass = true;
                        if (current == ']') characterClass = false;
                    }
                    if (current == quote && !characterClass) break;
                }
                regexAllowed = false;
                continue;
            }
            if (Character.isJavaIdentifierStart(c)) {
                int start = i++;
                while (i < source.length() && Character.isJavaIdentifierPart(source.charAt(i))) i++;
                String token = source.substring(start, i);
                code.append(token);
                regexAllowed =
                        Arrays.asList(
                                        "return", "throw", "case", "delete", "typeof", "void",
                                        "new", "in", "of", "yield", "await")
                                .contains(token);
                continue;
            }
            code.append(c);
            i++;
            if (!Character.isWhitespace(c)) regexAllowed = "=(:,[!&|?;{}+*-~%<>".indexOf(c) >= 0;
        }
        return code.toString();
    }

    public static boolean looksLikePySpider(String text, String origin) {
        String content = text == null ? "" : text.trim().replaceFirst("^\\uFEFF", "");
        if (content.startsWith("{") || content.startsWith("[") || content.startsWith("<"))
            return false;
        String cleanOrigin =
                origin == null ? "" : origin.split("[?#]", 2)[0].toLowerCase(Locale.ROOT);
        if (cleanOrigin.endsWith(".py")) return true;
        if (text == null) return false;
        String t = text.trim();
        return (t.contains("class Spider") && t.contains("def "))
                || (t.contains("def homeContent") && t.contains("def playerContent"));
    }

    private static String extractScriptTitle(String text, String origin, String prefix) {
        if (text != null) {
            java.util.regex.Matcher m =
                    java.util.regex.Pattern.compile(
                                    "(?:title|name)\\s*[:=]\\s*['\"]([^'\"\\r\\n]{1,32})['\"]")
                            .matcher(text);
            if (m.find()) return prefix + " · " + m.group(1).trim();
        }
        if (origin != null && !origin.isEmpty()) {
            String path = origin.split("[?#]", 2)[0];
            int slash = Math.max(path.lastIndexOf('/'), path.lastIndexOf('\\'));
            String file = slash >= 0 ? path.substring(slash + 1) : path;
            int dot = file.lastIndexOf('.');
            if (dot > 0) file = file.substring(0, dot);
            if (!file.isEmpty()) return prefix + " · " + file;
        }
        return prefix + " 扩展片源";
    }

    private static void appendStringList(List<String> target, Object raw) {
        if (raw == null || raw == JSONObject.NULL) return;
        if (raw instanceof JSONArray) {
            JSONArray arr = (JSONArray) raw;
            for (int i = 0; i < Math.min(500, arr.length()); i++) {
                String v = arr.optString(i, "").trim();
                if (!v.isEmpty() && !"null".equalsIgnoreCase(v)) target.add(v);
            }
        } else if (raw instanceof String) {
            String s = ((String) raw).trim();
            if (!s.isEmpty() && !"null".equalsIgnoreCase(s)) target.add(s);
        }
    }

    private static void copySafeHeaders(Map<String, String> target, Object headerObj) {
        if (headerObj instanceof String) {
            String str = ((String) headerObj).trim();
            if (str.startsWith("{")) {
                try {
                    headerObj = new JSONObject(str);
                } catch (Exception ignored) {
                    headerObj = null;
                }
            }
        }
        if (headerObj instanceof JSONObject) {
            JSONObject o = (JSONObject) headerObj;
            Iterator<String> it = o.keys();
            while (it.hasNext()) {
                String k = it.next();
                String v = optSafeString(o, k, "");
                if (k == null || v == null || v.isEmpty() || v.contains("\r") || v.contains("\n"))
                    continue;
                for (String allowed :
                        new String[] {
                            "User-Agent", "Referer", "Cookie", "Origin", "Authorization"
                        }) {
                    if (k.equalsIgnoreCase(allowed)) {
                        target.put(allowed, v);
                        break;
                    }
                }
            }
        }
    }

    /** Match CMS data, not just an endpoint-looking URL or an arbitrary JSON list. */
    private static boolean isDirectCmsResponse(JSONObject root) {
        if (root.has("sites") || root.has("api") || root.has("lives") || Warehouse.isCatalog(root))
            return false;
        JSONArray videos = root.optJSONArray("list");
        if (videos == null) return false;
        if (root.has("code")) {
            int code = root.optInt("code", -1);
            if (code != 0 && code != 1 && code != 200) return false;
        }
        for (int i = 0; i < Math.min(50, videos.length()); i++) {
            JSONObject video = videos.optJSONObject(i);
            if (video != null
                    && !video.isNull("vod_id")
                    && !video.isNull("vod_name")
                    && !optSafeString(video, "vod_id").trim().isEmpty()
                    && !optSafeString(video, "vod_name").trim().isEmpty()) return true;
        }
        JSONArray categories = root.optJSONArray("class");
        if (categories != null) {
            for (int i = 0; i < Math.min(500, categories.length()); i++) {
                JSONObject category = categories.optJSONObject(i);
                if (category != null
                        && !category.isNull("type_id")
                        && !category.isNull("type_name")
                        && !optSafeString(category, "type_id").trim().isEmpty()
                        && !optSafeString(category, "type_name").trim().isEmpty()) return true;
            }
        }
        return videos.length() == 0
                && root.optInt("code", -1) == 1
                && root.optInt("page", 0) > 0
                && root.optInt("pagecount", -1) >= 0
                && root.optInt("limit", 0) > 0
                && root.optInt("total", -1) == 0;
    }

    private static JSONObject directCmsConfig(JSONObject response, String origin) throws Exception {
        if (!isHttp(origin)) throw new IOException("这是采集接口返回的数据，请直接导入该接口的 HTTP(S) 地址");
        String address = normalizeHttp(origin);
        URI uri = new URI(address);
        StringBuilder api = new StringBuilder(address.split("[?#]", 2)[0]);
        String query = uri.getRawQuery();
        if (query != null) {
            boolean first = true;
            for (String part : query.split("&")) {
                if (part.isEmpty()) continue;
                String key = URLDecoder.decode(part.split("=", 2)[0], "UTF-8");
                if (Arrays.asList("ac", "t", "pg", "wd", "ids", "h").contains(key)) continue;
                api.append(first ? '?' : '&').append(part);
                first = false;
            }
        }
        String endpoint = api.toString();
        JSONObject site =
                new JSONObject()
                        .put("key", "cms_" + UUID.nameUUIDFromBytes(endpoint.getBytes("UTF-8")))
                        .put("name", "采集源 · " + new URL(endpoint).getHost())
                        .put("type", 1)
                        .put("api", endpoint)
                        .put("searchable", 1);
        JSONObject config = new JSONObject().put("sites", new JSONArray().put(site));
        for (String field : new String[] {Warehouse.ORIGIN, Warehouse.ROOT, Warehouse.DEPOTS})
            if (response.has(field)) config.put(field, response.get(field));
        return config;
    }

    public static boolean isHtml(String s) {
        if (s == null) return false;
        String t = s.replaceFirst("^\\uFEFF", "").trim().toLowerCase(Locale.ROOT);
        return t.startsWith("<!doctype") || t.startsWith("<html");
    }

    static boolean isScriptOrJarApi(String api) {
        if (api == null) return false;
        String lower = api.trim().toLowerCase(Locale.ROOT).split("[?#]", 2)[0];
        return lower.startsWith("csp_")
                || lower.endsWith(".js")
                || lower.endsWith(".mjs")
                || lower.endsWith(".py")
                || lower.endsWith(".jar");
    }

    static boolean hasXmlInUrlPath(String httpUrl) {
        try {
            String urlPath = new URL(normalizeHttp(httpUrl)).getPath();
            if (urlPath == null) return false;
            String lowerPath = urlPath.toLowerCase(Locale.ROOT);
            return lowerPath.contains("xml") || lowerPath.endsWith(".xml");
        } catch (Exception e) {
            return false;
        }
    }

    public static Config parseConfig(String text, String origin) throws Exception {
        if (text == null || text.length() > MAX_JSON) throw new IOException("配置超过 16 MB 限制");
        String trimmed = text.trim().replaceFirst("^\\uFEFF", "");
        if (isHtml(trimmed)) {
            throw new IOException("地址返回的是网页而不是配置（可能需要登录或被拦截）");
        }
        if (!trimmed.startsWith("{") && !trimmed.startsWith("[")) {
            if (origin != null
                    && isHttp(origin)
                    && !trimmed.startsWith("/")
                    && (trimmed.startsWith("#EXTM3U")
                            || trimmed.contains("#EXTINF:")
                            || trimmed.contains(",#genre#"))) {
                JSONObject synthetic = new JSONObject();
                JSONArray lives = new JSONArray();
                lives.put(new JSONObject().put("name", "电视直播").put("url", origin));
                synthetic.put("lives", lives);
                JSONArray sites = new JSONArray();
                sites.put(
                        new JSONObject()
                                .put("key", "live-only-placeholder")
                                .put("name", "仅直播源 (请在直播页观看)")
                                .put("type", 3)
                                .put("api", "csp_LivePlaceholder"));
                synthetic.put("sites", sites);
                trimmed = synthetic.toString();
                text = trimmed;
            } else if (looksLikeDrpyRule(trimmed) && (origin == null || origin.isEmpty())) {
                JSONObject rule =
                        new JSONObject()
                                .put("key", "drpy_" + Math.abs(trimmed.hashCode()))
                                .put("name", extractScriptTitle(trimmed, "", "DRPY"))
                                .put("type", 3)
                                .put("api", "csp_LocalRule.js")
                                .put("ext", new JSONObject().put("_mm_entrySource", trimmed));
                return parseConfig(
                        new JSONObject().put("sites", new JSONArray().put(rule)).toString(),
                        origin);
            } else if (looksLikeJsSpider(trimmed, origin)
                    && origin != null
                    && (isHttp(origin) || origin.startsWith("file://"))) {
                String title = extractScriptTitle(trimmed, origin, "JS");
                JSONObject siteObj =
                        new JSONObject()
                                .put("key", "js_" + Math.abs(origin.hashCode()))
                                .put("name", title)
                                .put("type", 3)
                                .put("api", origin)
                                .put("ext", new JSONObject().put("_mm_entrySource", trimmed))
                                .put("searchable", 1);
                JSONObject synth = new JSONObject().put("sites", new JSONArray().put(siteObj));
                return parseConfig(synth.toString(), origin);
            } else if (looksLikePySpider(trimmed, origin)) {
                String title = extractScriptTitle(trimmed, origin, "PY");
                JSONObject siteObj = new JSONObject();
                siteObj.put(
                        "key",
                        "py_"
                                + Math.abs(
                                        (origin == null || origin.isEmpty() ? trimmed : origin)
                                                .hashCode()));
                siteObj.put("name", title);
                siteObj.put("type", 3);
                if (origin != null
                        && origin.split("[?#]", 2)[0].toLowerCase(Locale.ROOT).endsWith(".py")) {
                    siteObj.put("api", origin);
                } else {
                    siteObj.put("api", "csp_LocalPython");
                    siteObj.put("ext", trimmed);
                }
                siteObj.put("searchable", 1);
                JSONObject synth = new JSONObject().put("sites", new JSONArray().put(siteObj));
                return parseConfig(synth.toString(), origin);
            }
        }
        String json = withoutComments(trimmed);
        JSONObject root;
        if (json.trim().startsWith("[")) {
            JSONArray array = new JSONArray(json);
            if (!isSiteArray(array)) throw new IOException("配置数组需要包含带 api 的来源对象");
            root = new JSONObject().put("sites", array);
        } else {
            root = new JSONObject(json);
        }
        if (isDirectCmsResponse(root)) {
            String directOrigin = optSafeString(root, Warehouse.ORIGIN, "").trim();
            root = directCmsConfig(root, directOrigin.isEmpty() ? origin : directOrigin);
            text = root.toString();
        }
        JSONArray sites = root.optJSONArray("sites");
        if ((sites == null || sites.length() == 0)
                && root.has("api")
                && !optSafeString(root, "api", "").trim().isEmpty()) {
            sites = new JSONArray().put(root);
        }
        if (Warehouse.isCatalog(root)) {
            String resolved =
                    Warehouse.resolve(
                            text,
                            origin,
                            Cms::fetchImport,
                            raw -> new JSONObject(withoutComments(raw)),
                            (raw, base) -> parseConfig(raw, base));
            return parseConfig(resolved, origin);
        }
        if ((sites == null || sites.length() == 0)
                && root.optJSONArray("lives") != null
                && root.optJSONArray("lives").length() > 0) {
            sites = new JSONArray();
            sites.put(
                    new JSONObject()
                            .put("key", "live-only-placeholder")
                            .put("name", "仅直播配置 (请前往直播页)")
                            .put("type", 3)
                            .put("api", "csp_LivePlaceholder"));
        }
        String taggedOrigin = optSafeString(root, Warehouse.ORIGIN, "").trim();
        if (!taggedOrigin.isEmpty()) origin = taggedOrigin;
        if (sites == null || sites.length() == 0) throw new IOException("配置中没有 sites 来源列表");
        if (sites.length() > 500) throw new IOException("来源超过 500 个限制");
        Config out = new Config();
        out.raw = text;
        out.origin = origin == null ? "" : origin;
        out.warehouse = optSafeString(root, Warehouse.ROOT, "").trim();
        JSONArray directory = root.optJSONArray(Warehouse.DEPOTS);
        if (directory != null) out.depots = directory;
        String rawSpider = optSafeString(root, "spider", "").trim();
        if (rawSpider.isEmpty()) rawSpider = optSafeString(root, "jar", "").trim();
        if (!rawSpider.isEmpty()) {
            String[] spParts = rawSpider.split(";md5;", 2);
            out.spider =
                    resolve(origin, spParts[0]) + (spParts.length == 2 ? ";md5;" + spParts[1] : "");
        } else {
            out.spider = "";
        }
        JSONArray parses = root.optJSONArray("parses");
        if (parses != null) {
            for (int i = 0; i < Math.min(100, parses.length()); i++) {
                JSONObject pj = parses.optJSONObject(i);
                if (pj == null) continue;
                String pUrl = optSafeString(pj, "url", "").trim();
                if (!isHttp(pUrl)) continue;
                Parse p = new Parse();
                String pName = optSafeString(pj, "name", "").trim();
                p.name = pName.isEmpty() ? "解析 " + (i + 1) : pName;
                p.url = pUrl;
                p.type = Json.integer(pj, "type", 0);
                p.headers.put("User-Agent", USER_AGENT);
                copySafeHeaders(p.headers, pj.opt("header"));
                copySafeHeaders(p.headers, pj.opt("headers"));
                JSONObject pExt = pj.optJSONObject("ext");
                if (pExt != null) {
                    copySafeHeaders(p.headers, pExt.opt("header"));
                    copySafeHeaders(p.headers, pExt.opt("headers"));
                }
                out.parses.add(p);
            }
        }
        JSONArray rulesArr = root.optJSONArray("rules");
        if (rulesArr != null) {
            for (int i = 0; i < Math.min(200, rulesArr.length()); i++) {
                JSONObject rj = rulesArr.optJSONObject(i);
                if (rj == null) continue;
                SniffRule rule = new SniffRule();
                rule.name = optSafeString(rj, "name", "").trim();
                rule.script = optSafeString(rj, "script", optSafeString(rj, "click", "")).trim();
                appendStringList(rule.hosts, rj.opt("hosts"));
                appendStringList(rule.hosts, rj.opt("host"));
                appendStringList(rule.regex, rj.opt("regex"));
                appendStringList(rule.exclude, rj.opt("exclude"));
                if (!rule.hosts.isEmpty()
                        || !rule.regex.isEmpty()
                        || !rule.exclude.isEmpty()
                        || !rule.script.isEmpty()) {
                    out.rules.add(rule);
                }
            }
        }
        appendStringList(out.ads, root.opt("ads"));
        String defaultJsonParseUrl = "";
        for (Parse p : out.parses) {
            if (p.type == 1 || p.type == 2 || p.type == 3) {
                defaultJsonParseUrl = p.url;
                break;
            }
        }
        Set<String> keys = new HashSet<>();
        for (int i = 0; i < sites.length(); i++) {
            JSONObject j = sites.optJSONObject(i);
            if (j == null) continue;
            Site s = new Site();
            String rawKey = optSafeString(j, "key", "").trim();
            s.key = rawKey.isEmpty() ? "site-" + i : rawKey;
            String rawName = optSafeString(j, "name", "").trim();
            s.name = rawName.isEmpty() ? s.key : rawName;
            if (!keys.add(s.key)) s.key = s.key + "-" + i;
            s.originalKey = s.key;
            String rawGroup = optSafeString(j, "group", "").trim();
            s.group = rawGroup.isEmpty() ? "默认分组" : rawGroup;
            s.type = Json.integer(j, "type", -1);
            s.api = resolve(origin, optSafeString(j, "api", "").trim());
            s.originalApi = s.api;
            String rawJar = optSafeString(j, "jar", "").trim();
            if (!rawJar.isEmpty()) {
                String[] jarParts = rawJar.split(";md5;", 2);
                s.jar =
                        resolve(origin, jarParts[0])
                                + (jarParts.length == 2 ? ";md5;" + jarParts[1] : "");
            }
            if (s.type == -1
                    && isHttp(s.api)
                    && (s.jar == null || s.jar.isEmpty())
                    && !isScriptOrJarApi(s.api)) {
                s.type = hasXmlInUrlPath(s.api) ? 0 : 1;
            }
            s.playUrl = optSafeString(j, "playUrl", "").trim();
            if (s.playUrl.isEmpty()
                    && (Json.integer(j, "parse", 0) == 1 || Json.integer(j, "jx", 0) == 1)) {
                s.playUrl = defaultJsonParseUrl;
            }
            s.searchable = Json.integer(j, "searchable", 1) != 0;
            Object rawExt = j.isNull("ext") ? null : j.opt("ext");
            if (rawExt == JSONObject.NULL
                    || JSONObject.NULL.equals(rawExt)
                    || (rawExt instanceof String
                            && "null".equalsIgnoreCase(((String) rawExt).trim()))) {
                rawExt = null;
            }
            s.ext = rawExt;
            if (origin != null && !origin.isEmpty()) {
                if (s.ext instanceof String) {
                    String ext = (String) s.ext;
                    if (ext.startsWith("./") || ext.startsWith("../")) s.ext = resolve(origin, ext);
                } else if (s.ext instanceof JSONObject) {
                    JSONObject extObj = (JSONObject) s.ext;
                    for (String field : new String[] {"json", "url", "rule"}) {
                        String val = optSafeString(extObj, field, null);
                        if (val != null) val = val.trim();
                        if (val != null && (val.startsWith("./") || val.startsWith("../"))) {
                            try {
                                extObj.put(field, resolve(origin, val));
                            } catch (Exception ignored) {
                            }
                        }
                    }
                }
            }
            s.requiresParser =
                    !s.playUrl.isEmpty()
                            || Json.integer(j, "parse", 0) == 1
                            || Json.integer(j, "jx", 0) == 1;
            s.headers.put("User-Agent", USER_AGENT);
            Object h = j.isNull("headers") ? null : j.opt("headers");
            if (h == null || h == JSONObject.NULL) {
                h = j.isNull("header") ? null : j.opt("header");
            }
            copySafeHeaders(s.headers, j.opt("header"));
            copySafeHeaders(s.headers, j.opt("headers"));
            String ua = optSafeString(j, "ua", "").trim();
            if (!ua.isEmpty() && !ua.contains("\r") && !ua.contains("\n")) {
                s.headers.put("User-Agent", ua);
            }
            if (h instanceof JSONObject) {
                JSONObject o = (JSONObject) h;
                Iterator<String> it = o.keys();
                while (it.hasNext()) {
                    String k = it.next();
                    String val = optSafeString(o, k, "").trim();
                    if (val.isEmpty() || val.contains("\r") || val.contains("\n")) continue;
                    if (k.equalsIgnoreCase("User-Agent")
                            || k.equalsIgnoreCase("Referer")
                            || (s.type == 4
                                    && k.matches("[!#$%&'*+.^_`|~0-9A-Za-z-]+")
                                    && !Arrays.asList(
                                                    "content-length",
                                                    "transfer-encoding",
                                                    "connection")
                                            .contains(k.toLowerCase(Locale.ROOT))))
                        s.headers.put(k, val);
                }
            }
            if (s.ext instanceof JSONObject) {
                JSONObject extObj = (JSONObject) s.ext;
                copySafeHeaders(s.headers, extObj.opt("header"));
                copySafeHeaders(s.headers, extObj.opt("headers"));
                String extUa = optSafeString(extObj, "ua", "").trim();
                if (!extUa.isEmpty() && !extUa.contains("\r") && !extUa.contains("\n")) {
                    s.headers.put("User-Agent", extUa);
                }
            }
            out.sites.add(s);
        }
        if (out.sites.isEmpty()) throw new IOException("配置没有可识别的站点");
        return out;
    }

    static boolean isSiteArray(JSONArray entries) {
        if (entries.length() == 0) return false;
        for (int i = 0; i < entries.length(); i++) {
            JSONObject item = entries.optJSONObject(i);
            Object api = item == null ? null : item.opt("api");
            if (!(api instanceof String) || ((String) api).trim().isEmpty()) return false;
        }
        return true;
    }

    public static String withoutComments(String source) throws IOException {
        if (source == null) return "";
        if (source.startsWith("\uFEFF")) source = source.substring(1);
        StringBuilder clean = new StringBuilder();
        boolean quoted = false, escaped = false;
        for (int i = 0; i < source.length(); i++) {
            char ch = source.charAt(i);
            if (quoted) {
                clean.append(ch);
                if (escaped) escaped = false;
                else if (ch == '\\') escaped = true;
                else if (ch == '"') quoted = false;
                continue;
            }
            if (ch == '"') {
                quoted = true;
                clean.append(ch);
                continue;
            }
            if (ch == '/' && i + 1 < source.length() && source.charAt(i + 1) == '/') {
                while (i < source.length() && source.charAt(i) != '\n') i++;
                clean.append('\n');
                continue;
            }
            if (ch == '/' && i + 1 < source.length() && source.charAt(i + 1) == '*') {
                i += 2;
                while (i + 1 < source.length()
                        && !(source.charAt(i) == '*' && source.charAt(i + 1) == '/')) i++;
                if (i + 1 >= source.length()) throw new IOException("配置注释没有结束");
                i++;
                clean.append(' ');
                continue;
            }
            clean.append(ch);
        }
        // Strip trailing commas before '}' or ']' outside string literals
        String noComments = clean.toString();
        StringBuilder out = new StringBuilder(noComments.length());
        quoted = false;
        escaped = false;
        for (int i = 0; i < noComments.length(); i++) {
            char ch = noComments.charAt(i);
            if (quoted) {
                out.append(ch);
                if (escaped) escaped = false;
                else if (ch == '\\') escaped = true;
                else if (ch == '"') quoted = false;
                continue;
            }
            if (ch == '"') {
                quoted = true;
                out.append(ch);
                continue;
            }
            if (ch == ',') {
                int j = i + 1;
                while (j < noComments.length() && Character.isWhitespace(noComments.charAt(j))) j++;
                if (j < noComments.length()
                        && (noComments.charAt(j) == '}' || noComments.charAt(j) == ']')) {
                    continue;
                }
            }
            out.append(ch);
        }
        return out.toString();
    }

    public static String read(InputStream in, int limit) throws IOException {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        byte[] buf = new byte[8192];
        int n;
        while ((n = in.read(buf)) != -1) {
            if (Thread.currentThread().isInterrupted()) throw new java.io.InterruptedIOException();
            if (out.size() + n > limit) throw new IOException("响应超过大小限制");
            out.write(buf, 0, n);
        }
        return document(out.toByteArray());
    }

    static byte[] gunzipIfNeeded(byte[] bytes) throws IOException {
        if (bytes != null
                && bytes.length >= 2
                && (bytes[0] & 0xff) == 0x1f
                && (bytes[1] & 0xff) == 0x8b) {
            try (java.util.zip.GZIPInputStream gis =
                            new java.util.zip.GZIPInputStream(new ByteArrayInputStream(bytes));
                    ByteArrayOutputStream bos = new ByteArrayOutputStream()) {
                byte[] buf = new byte[8192];
                int n;
                while ((n = gis.read(buf)) != -1) {
                    if (bos.size() + n > MAX_JSON) {
                        throw new IOException("解压后内容超过大小限制");
                    }
                    bos.write(buf, 0, n);
                }
                return bos.toByteArray();
            }
        }
        return bytes;
    }

    private static boolean looksLikeConfigPayload(String s) {
        if (s == null) return false;
        String t = s.trim().replaceFirst("^\\uFEFF", "");
        return t.startsWith("{")
                || t.startsWith("[")
                || t.startsWith("//")
                || t.startsWith("/*")
                || t.startsWith("#EXTM3U")
                || t.contains("#EXTINF:")
                || t.contains(",#genre#")
                || t.matches("(?s).*[^,\\r\\n]{1,64},(?:https?|rtmps?|rtsp|mms|proxy)://.*");
    }

    /** Some operator-provided TVBox configs are JPEG/PNG/GIF + '**' + Base64(JSON) or AES hex. */
    public static String document(byte[] bytes) throws IOException {
        bytes = gunzipIfNeeded(bytes);
        if (bytes.length >= 2 && (bytes[0] & 255) == 255 && (bytes[1] & 255) == 216) {
            int end = -1;
            for (int i = 2; i < bytes.length - 1; i++)
                if ((bytes[i] & 255) == 255 && (bytes[i + 1] & 255) == 217) {
                    end = i + 2;
                    break;
                }
            int marker = -1;
            if (end >= 0)
                for (int i = end; i < Math.min(bytes.length - 1, end + 128); i++)
                    if (bytes[i] == '*' && bytes[i + 1] == '*') {
                        marker = i + 2;
                        break;
                    }
            if (marker < 0) {
                for (int i = bytes.length - 2; i >= 2; i--) {
                    if (bytes[i] == '*' && bytes[i + 1] == '*') {
                        marker = i + 2;
                        break;
                    }
                }
            }
            if (marker < 0) throw new IOException("配置图片中没有受支持的 JSON 载荷");
            return decodeBase64Range(bytes, marker, bytes.length);
        }
        // Check binary PNG / GIF / arbitrary carrier with '**' + Base64
        boolean isPngOrGif =
                (bytes.length >= 4
                                && (bytes[0] & 0xff) == 0x89
                                && bytes[1] == 'P'
                                && bytes[2] == 'N'
                                && bytes[3] == 'G')
                        || (bytes.length >= 4
                                && bytes[0] == 'G'
                                && bytes[1] == 'I'
                                && bytes[2] == 'F'
                                && bytes[3] == '8');
        if (isPngOrGif) {
            for (int i = bytes.length - 2; i >= 4; i--) {
                if (bytes[i] == '*' && bytes[i + 1] == '*') {
                    String decoded = decodeBase64Range(bytes, i + 2, bytes.length);
                    if (looksLikeConfigPayload(decoded)) return decoded;
                    break;
                }
            }
        }
        String text;
        if (bytes.length >= 3
                && (bytes[0] & 255) == 0xEF
                && (bytes[1] & 255) == 0xBB
                && (bytes[2] & 255) == 0xBF) text = new String(bytes, 3, bytes.length - 3, "UTF-8");
        else if (bytes.length >= 2 && (bytes[0] & 255) == 255 && (bytes[1] & 255) == 254)
            text = new String(bytes, 2, bytes.length - 2, "UTF-16LE");
        else if (bytes.length >= 2 && (bytes[0] & 255) == 254 && (bytes[1] & 255) == 255)
            text = new String(bytes, 2, bytes.length - 2, "UTF-16BE");
        else text = new String(bytes, "UTF-8");
        String trimmed = text.trim().replaceFirst("^\\uFEFF", "");
        if (looksLikeJsSpider(trimmed, "") || looksLikePySpider(trimmed, "")) return text;
        if (!trimmed.startsWith("{")
                && !trimmed.startsWith("[")
                && !trimmed.startsWith("/")
                && !trimmed.startsWith("<")) {
            int star = trimmed.lastIndexOf("**");
            if (star >= 0 && star + 2 < trimmed.length()) {
                try {
                    byte[] sub = trimmed.substring(star + 2).getBytes("US-ASCII");
                    String decoded = decodeBase64Range(sub, 0, sub.length);
                    if (looksLikeConfigPayload(decoded)) return decoded;
                } catch (Exception ignored) {
                }
            }
            String compactHex = trimmed.replaceAll("\\s+", "");
            if (compactHex.startsWith("2423")
                    && compactHex.length() > 36
                    && compactHex.length() % 2 == 0) {
                try {
                    String decrypted = decryptHexAes(compactHex);
                    if (looksLikeConfigPayload(decrypted)) return decrypted;
                } catch (Exception ignored) {
                }
            }
            if (trimmed.startsWith("eyJ") || (trimmed.length() >= 32 && !trimmed.contains(" "))) {
                try {
                    byte[] sub = trimmed.getBytes("US-ASCII");
                    String decoded = decodeBase64Range(sub, 0, sub.length);
                    if (looksLikeConfigPayload(decoded)) return decoded;
                } catch (Exception ignored) {
                }
            }
        }
        return text;
    }

    private static String decodeBase64Range(byte[] bytes, int start, int end) throws IOException {
        ByteArrayOutputStream decoded = new ByteArrayOutputStream();
        int bits = 0, count = 0;
        String alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        for (int i = start; i < end; i++) {
            char ch = (char) (bytes[i] & 255);
            if (ch == '=') break;
            if (Character.isWhitespace(ch)) continue;
            if (ch == '-') ch = '+';
            else if (ch == '_') ch = '/';
            int v = alphabet.indexOf(ch);
            if (v < 0) throw new IOException("配置图片中的 Base64 格式不受支持");
            bits = (bits << 6) | v;
            count += 6;
            if (count >= 8) {
                count -= 8;
                decoded.write((bits >> count) & 255);
            }
        }
        return new String(decoded.toByteArray(), "UTF-8");
    }

    private static String decryptHexAes(String hex) throws Exception {
        byte[] raw = new byte[hex.length() / 2];
        for (int i = 0; i < raw.length; i++) {
            int hi = Character.digit(hex.charAt(i * 2), 16);
            int lo = Character.digit(hex.charAt(i * 2 + 1), 16);
            if (hi < 0 || lo < 0) return null;
            raw[i] = (byte) ((hi << 4) | lo);
        }
        String ascii = new String(raw, "ISO-8859-1");
        int endKey = ascii.indexOf("#$");
        if (!ascii.startsWith("$#") || endKey < 2 || ascii.length() < endKey + 2 + 16) return null;
        String keyPart = ascii.substring(2, endKey);
        String ivPart = ascii.substring(ascii.length() - 13);
        byte[] keyBytes = pad16(keyPart);
        byte[] ivBytes = pad16(ivPart);
        int cipherLen = raw.length - (endKey + 2) - 13;
        if (cipherLen <= 0 || cipherLen % 16 != 0) return null;
        javax.crypto.Cipher cipher = javax.crypto.Cipher.getInstance("AES/CBC/PKCS5Padding");
        cipher.init(
                javax.crypto.Cipher.DECRYPT_MODE,
                new javax.crypto.spec.SecretKeySpec(keyBytes, "AES"),
                new javax.crypto.spec.IvParameterSpec(ivBytes));
        byte[] out = cipher.doFinal(raw, endKey + 2, cipherLen);
        return new String(out, "UTF-8");
    }

    private static byte[] pad16(String s) throws Exception {
        StringBuilder sb = new StringBuilder(s);
        while (sb.length() < 16) sb.append('0');
        return sb.substring(0, 16).getBytes("UTF-8");
    }

    private static final class NonRetryableFetchException extends IOException {
        NonRetryableFetchException(String message) {
            super(message);
        }

        NonRetryableFetchException(IOException cause) {
            super(cause.getMessage(), cause);
        }
    }

    static final class HttpStatusException extends IOException {
        final int status;

        HttpStatusException(int status) {
            super("来源返回 HTTP " + status);
            this.status = status;
        }
    }

    private static final String ISRG_ROOT_X1_PEM =
            "-----BEGIN CERTIFICATE-----\n"
                    + "MIIFazCCA1OgAwIBAgIRAIIQz7DSQONZRGPgu2OCiwAwDQYJKoZIhvcNAQELBQAw\n"
                    + "TzELMAkGA1UEBhMCVVMxKTAnBgNVBAoTIEludGVybmV0IFNlY3VyaXR5IFJlc2Vh\n"
                    + "cmNoIEdyb3VwMRUwEwYDVQQDEwxJU1JHIFJvb3QgWDEwHhcNMTUwNjA0MTEwNDM4\n"
                    + "WhcNMzUwNjA0MTEwNDM4WjBPMQswCQYDVQQGEwJVUzEpMCcGA1UEChMgSW50ZXJu\n"
                    + "ZXQgU2VjdXJpdHkgUmVzZWFyY2ggR3JvdXAxFTATBgNVBAMTDElTUkcgUm9vdCBY\n"
                    + "MTCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAK3oJHP0FDfzm54rVygc\n"
                    + "h77ct984kIxuPOZXoHj3dcKi/vVqbvYATyjb3miGbESTtrFj/RQSa78f0uoxmyF+\n"
                    + "0TM8ukj13Xnfs7j/EvEhmkvBioZxaUpmZmyPfjxwv60pIgbz5MDmgK7iS4+3mX6U\n"
                    + "A5/TR5d8mUgjU+g4rk8Kb4Mu0UlXjIB0ttov0DiNewNwIRt18jA8+o+u3dpjq+sW\n"
                    + "T8KOEUt+zwvo/7V3LvSye0rgTBIlDHCNAymg4VMk7BPZ7hm/ELNKjD+Jo2FR3qyH\n"
                    + "B5T0Y3HsLuJvW5iB4YlcNHlsdu87kGJ55tukmi8mxdAQ4Q7e2RCOFvu396j3x+UC\n"
                    + "B5iPNgiV5+I3lg02dZ77DnKxHZu8A/lJBdiB3QW0KtZB6awBdpUKD9jf1b0SHzUv\n"
                    + "KBds0pjBqAlkd25HN7rOrFleaJ1/ctaJxQZBKT5ZPt0m9STJEadao0xAH0ahmbWn\n"
                    + "OlFuhjuefXKnEgV4We0+UXgVCwOPjdAvBbI+e0ocS3MFEvzG6uBQE3xDk3SzynTn\n"
                    + "jh8BCNAw1FtxNrQHusEwMFxIt4I7mKZ9YIqioymCzLq9gwQbooMDQaHWBfEbwrbw\n"
                    + "qHyGO0aoSCqI3Haadr8faqU9GY/rOPNk3sgrDQoo//fb4hVC1CLQJ13hef4Y53CI\n"
                    + "rU7m2Ys6xt0nUW7/vGT1M0NPAgMBAAGjQjBAMA4GA1UdDwEB/wQEAwIBBjAPBgNV\n"
                    + "HRMBAf8EBTADAQH/MB0GA1UdDgQWBBR5tFnme7bl5AFzgAiIyBpY9umbbjANBgkq\n"
                    + "hkiG9w0BAQsFAAOCAgEAVR9YqbyyqFDQDLHYGmkgJykIrGF1XIpu+ILlaS/V9lZL\n"
                    + "ubhzEFnTIZd+50xx+7LSYK05qAvqFyFWhfFQDlnrzuBZ6brJFe+GnY+EgPbk6ZGQ\n"
                    + "3BebYhtF8GaV0nxvwuo77x/Py9auJ/GpsMiu/X1+mvoiBOv/2X/qkSsisRcOj/KK\n"
                    + "NFtY2PwByVS5uCbMiogziUwthDyC3+6WVwW6LLv3xLfHTjuCvjHIInNzktHCgKQ5\n"
                    + "ORAzI4JMPJ+GslWYHb4phowim57iaztXOoJwTdwJx4nLCgdNbOhdjsnvzqvHu7Ur\n"
                    + "TkXWStAmzOVyyghqpZXjFaH3pO3JLF+l+/+sKAIuvtd7u+Nxe5AW0wdeRlN8NwdC\n"
                    + "jNPElpzVmbUq4JUagEiuTDkHzsxHpFKVK7q4+63SM1N95R1NbdWhscdCb+ZAJzVc\n"
                    + "oyi3B43njTOQ5yOf+1CceWxG1bQVs5ZufpsMljq4Ui0/1lvh+wjChP4kqKOJ2qxq\n"
                    + "4RgqsahDYVvTH9w7jXbyLeiNdd8XM2w9U/t7y0Ff/9yi0GE44Za4rF2LN9d11TPA\n"
                    + "mRGunUHBcnWEvgJBQl9nJEiU0Zsnvgc/ubhPgXRR4Xq37Z0j4r7g1SgEEzwxA57d\n"
                    + "emyPxgcYxn/eR44/KJ4EBs+lVDR3veyJm+kXQ99b21/+jh5Xos1AnX5iItreGCc=\n"
                    + "-----END CERTIFICATE-----";

    private static volatile boolean api23TrustInstalled;

    /**
     * Android 6.0 (API 23) ignores {@code res/xml/network_security_config.xml} (#55), so Let's
     * Encrypt ({@code ISRG Root X1}) HTTPS sites fail certificate validation while HTTP works.
     * Installs a composite [system + ISRG Root X1] default SSLSocketFactory on API 14..23 devices.
     */
    static void ensureApi23RootTrust() {
        if (api23TrustInstalled) return;
        int sdk = 0;
        try {
            sdk = Class.forName("android.os.Build$VERSION").getField("SDK_INT").getInt(null);
        } catch (Throwable ignored) {
        }
        if (sdk < 14 || sdk >= 24) {
            api23TrustInstalled = true;
            return;
        }
        synchronized (Cms.class) {
            if (api23TrustInstalled) return;
            api23TrustInstalled = true;
            try {
                SSLSocketFactory compat = buildCompositeIsrgSocketFactory();
                if (compat != null) {
                    HttpsURLConnection.setDefaultSSLSocketFactory(compat);
                }
            } catch (Throwable ignored) {
            }
        }
    }

    static SSLSocketFactory buildCompositeIsrgSocketFactory() {
        try {
            X509TrustManager systemTm = null;
            TrustManagerFactory sysTmf =
                    TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm());
            sysTmf.init((java.security.KeyStore) null);
            for (TrustManager tm : sysTmf.getTrustManagers()) {
                if (tm instanceof X509TrustManager) {
                    systemTm = (X509TrustManager) tm;
                    break;
                }
            }
            java.security.cert.CertificateFactory cf =
                    java.security.cert.CertificateFactory.getInstance("X.509");
            java.security.cert.X509Certificate isrgCert =
                    (java.security.cert.X509Certificate)
                            cf.generateCertificate(
                                    new ByteArrayInputStream(ISRG_ROOT_X1_PEM.getBytes("UTF-8")));
            java.security.KeyStore ks =
                    java.security.KeyStore.getInstance(java.security.KeyStore.getDefaultType());
            ks.load(null, null);
            ks.setCertificateEntry("isrg_root_x1", isrgCert);
            TrustManagerFactory isrgTmf =
                    TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm());
            isrgTmf.init(ks);
            X509TrustManager isrgTm = null;
            for (TrustManager tm : isrgTmf.getTrustManagers()) {
                if (tm instanceof X509TrustManager) {
                    isrgTm = (X509TrustManager) tm;
                    break;
                }
            }
            final X509TrustManager finalSys = systemTm;
            final X509TrustManager finalIsrg = isrgTm;
            X509TrustManager composite =
                    new X509TrustManager() {
                        @Override
                        public void checkClientTrusted(
                                java.security.cert.X509Certificate[] chain, String authType)
                                throws java.security.cert.CertificateException {
                            if (finalSys != null) finalSys.checkClientTrusted(chain, authType);
                        }

                        @Override
                        public void checkServerTrusted(
                                java.security.cert.X509Certificate[] chain, String authType)
                                throws java.security.cert.CertificateException {
                            try {
                                if (finalSys != null) {
                                    finalSys.checkServerTrusted(chain, authType);
                                    return;
                                }
                            } catch (java.security.cert.CertificateException ignored) {
                            }
                            if (finalIsrg != null) {
                                finalIsrg.checkServerTrusted(chain, authType);
                            } else {
                                throw new java.security.cert.CertificateException(
                                        "No trust manager available");
                            }
                        }

                        @Override
                        public java.security.cert.X509Certificate[] getAcceptedIssuers() {
                            List<java.security.cert.X509Certificate> out = new ArrayList<>();
                            if (finalSys != null)
                                out.addAll(Arrays.asList(finalSys.getAcceptedIssuers()));
                            if (finalIsrg != null)
                                out.addAll(Arrays.asList(finalIsrg.getAcceptedIssuers()));
                            return out.toArray(new java.security.cert.X509Certificate[out.size()]);
                        }
                    };
            SSLContext ctx = SSLContext.getInstance("TLS");
            ctx.init(null, new TrustManager[] {composite}, null);
            return new SniOverrideSocketFactory(ctx.getSocketFactory(), null);
        } catch (Throwable ignored) {
            return null;
        }
    }

    static final class SniOverrideSocketFactory extends SSLSocketFactory {
        private final SSLSocketFactory delegate;
        private final String sniHost;

        SniOverrideSocketFactory(SSLSocketFactory delegate, String sniHost) {
            this.delegate = delegate;
            this.sniHost = sniHost;
        }

        @Override
        public String[] getDefaultCipherSuites() {
            return delegate.getDefaultCipherSuites();
        }

        @Override
        public String[] getSupportedCipherSuites() {
            return delegate.getSupportedCipherSuites();
        }

        @Override
        public Socket createSocket() throws IOException {
            return configureSocket(delegate.createSocket(), sniHost);
        }

        @Override
        public Socket createSocket(Socket s, String host, int port, boolean autoClose)
                throws IOException {
            String targetHost = sniHost != null && !sniHost.isEmpty() ? sniHost : host;
            return configureSocket(
                    delegate.createSocket(s, targetHost, port, autoClose), targetHost);
        }

        @Override
        public Socket createSocket(String host, int port) throws IOException {
            return configureSocket(
                    delegate.createSocket(host, port),
                    sniHost != null && !sniHost.isEmpty() ? sniHost : host);
        }

        @Override
        public Socket createSocket(String host, int port, InetAddress localHost, int localPort)
                throws IOException {
            return configureSocket(
                    delegate.createSocket(host, port, localHost, localPort),
                    sniHost != null && !sniHost.isEmpty() ? sniHost : host);
        }

        @Override
        public Socket createSocket(InetAddress host, int port) throws IOException {
            return configureSocket(delegate.createSocket(host, port), sniHost);
        }

        @Override
        public Socket createSocket(
                InetAddress address, int port, InetAddress localAddress, int localPort)
                throws IOException {
            return configureSocket(
                    delegate.createSocket(address, port, localAddress, localPort), sniHost);
        }

        private static Socket configureSocket(Socket socket, String hostname) {
            if (socket instanceof SSLSocket) {
                SSLSocket ssl = (SSLSocket) socket;
                String[] supported = ssl.getSupportedProtocols();
                if (supported != null) {
                    List<String> enabled = new ArrayList<>();
                    for (String p : supported) {
                        if ("TLSv1.3".equals(p) || "TLSv1.2".equals(p)) enabled.add(p);
                    }
                    if (!enabled.isEmpty()) {
                        ssl.setEnabledProtocols(enabled.toArray(new String[0]));
                    }
                }
                if (hostname != null
                        && !hostname.isEmpty()
                        && !hostname.startsWith("[")
                        && !hostname.matches("\\d{1,3}(?:\\.\\d{1,3}){3}")) {
                    try {
                        ssl.getClass().getMethod("setHostname", String.class).invoke(ssl, hostname);
                    } catch (Throwable ignored) {
                    }
                }
            }
            return socket;
        }
    }

    public static String fetch(String address, Map<String, String> headers) throws Exception {
        return fetch(address, headers, null, USER_AGENT);
    }

    public static String fetch(
            String address, Map<String, String> headers, Map<String, String> form)
            throws Exception {
        return fetch(address, headers, form, USER_AGENT);
    }

    public static String fetchImport(String address) throws Exception {
        if (!isHttp(address)) throw new IOException("只支持 HTTP(S) 地址");
        URL initialUrl = new URL(normalizeHttp(address));
        Map<String, String> headers = new LinkedHashMap<>();
        if (initialUrl.getUserInfo() != null) {
            String credentials =
                    URLDecoder.decode(initialUrl.getUserInfo().replace("+", "%2B"), "UTF-8");
            headers.put("Authorization", basicAuthorization(credentials));
            initialUrl =
                    new URL(
                            initialUrl.getProtocol(),
                            initialUrl.getHost(),
                            initialUrl.getPort(),
                            initialUrl.getFile());
        }
        String result = null;
        Exception firstErr = null;
        try {
            result = fetchOnce(initialUrl, headers, null, USER_AGENT, true, false);
            if (!isHtml(result)) {
                return result;
            }
        } catch (NonRetryableFetchException fatal) {
            if (fatal.getCause() instanceof IOException) throw (IOException) fatal.getCause();
            throw new IOException(fatal.getMessage());
        } catch (HttpStatusException e) {
            if (e.status != 403) {
                throw e;
            }
            firstErr = e;
        } catch (IOException transportErr) {
            List<InetAddress> dohAddrs = resolveViaDoh(initialUrl.getHost());
            if (dohAddrs.isEmpty()) {
                throw transportErr;
            }
            firstErr = transportErr;
        }
        if (firstErr == null || firstErr instanceof HttpStatusException) {
            for (String ua :
                    new String[] {SAFARI_USER_AGENT, MOBILE_USER_AGENT, TVBOX_USER_AGENT}) {
                try {
                    result = fetchOnce(initialUrl, headers, null, ua, true, false);
                    if (!isHtml(result)) {
                        return result;
                    }
                    // Got 200 HTML with Safari UA as well -> surface HTML diagnostic below
                    break;
                } catch (NonRetryableFetchException fatal) {
                    if (fatal.getCause() instanceof IOException)
                        throw (IOException) fatal.getCause();
                    throw new IOException(fatal.getMessage());
                } catch (HttpStatusException e) {
                    if (e.status != 403) throw e;
                    firstErr = e;
                }
            }
            if (result != null && isHtml(result)) {
                throw new IOException("地址返回的是网页而不是配置（可能需要登录或被拦截）");
            }
        }
        List<InetAddress> dohAddrs = resolveViaDoh(initialUrl.getHost());
        if (!dohAddrs.isEmpty()) {
            for (String ua :
                    new String[] {
                        USER_AGENT, SAFARI_USER_AGENT, MOBILE_USER_AGENT, TVBOX_USER_AGENT
                    }) {
                try {
                    result = fetchOnce(initialUrl, headers, null, ua, true, true);
                    if (!isHtml(result)) {
                        return result;
                    }
                } catch (NonRetryableFetchException fatal) {
                    if (fatal.getCause() instanceof IOException)
                        throw (IOException) fatal.getCause();
                    throw new IOException(fatal.getMessage());
                } catch (HttpStatusException e) {
                    if (e.status != 403) throw e;
                    firstErr = e;
                } catch (IOException ignored) {
                }
            }
            if (result != null && isHtml(result)) {
                throw new IOException("地址返回的是网页而不是配置（可能需要登录或被拦截）");
            }
        }
        if (firstErr != null) throw firstErr;
        throw new IOException("地址返回的是网页而不是配置（可能需要登录或被拦截）");
    }

    static final class RedirectCookie {
        final String name;
        final String value;
        final String domain;
        final boolean hostOnly;
        final String path;

        RedirectCookie(String name, String value, String domain, boolean hostOnly, String path) {
            this.name = name;
            this.value = value;
            this.domain = domain;
            this.hostOnly = hostOnly;
            this.path = path;
        }

        boolean matches(URL target) {
            String targetHost = target.getHost().toLowerCase(Locale.ROOT);
            if (hostOnly) {
                if (!targetHost.equals(domain)) return false;
            } else {
                if (!targetHost.equals(domain) && !targetHost.endsWith("." + domain)) return false;
            }
            String targetPath = target.getPath();
            if (targetPath == null || targetPath.isEmpty()) targetPath = "/";
            if (path.equals("/") || targetPath.equals(path)) return true;
            if (targetPath.startsWith(path)) {
                return path.endsWith("/") || targetPath.charAt(path.length()) == '/';
            }
            return false;
        }
    }

    static List<RedirectCookie> parseSetCookies(List<String> headerValues, URL requestUrl) {
        List<RedirectCookie> result = new ArrayList<>();
        if (headerValues == null || headerValues.isEmpty()) return result;
        String reqHost = requestUrl.getHost().toLowerCase(Locale.ROOT);
        for (String raw : headerValues) {
            if (raw == null || raw.trim().isEmpty()) continue;
            String[] parts = raw.split(";");
            if (parts.length == 0) continue;
            String first = parts[0].trim();
            int eq = first.indexOf('=');
            if (eq <= 0) continue;
            String name = first.substring(0, eq).trim();
            String value = first.substring(eq + 1).trim();
            if (name.isEmpty()) continue;

            String domain = reqHost;
            boolean hostOnly = true;
            String path = "/";
            boolean expired = value.isEmpty();

            for (int i = 1; i < parts.length; i++) {
                String attr = parts[i].trim();
                if (attr.isEmpty()) continue;
                int aEq = attr.indexOf('=');
                String aKey =
                        (aEq < 0 ? attr : attr.substring(0, aEq)).trim().toLowerCase(Locale.ROOT);
                String aVal = aEq < 0 ? "" : attr.substring(aEq + 1).trim();
                if ("domain".equals(aKey) && !aVal.isEmpty()) {
                    String clean = aVal.replaceAll("^\\.+", "").toLowerCase(Locale.ROOT);
                    if (clean.contains(".")
                            && (reqHost.equals(clean) || reqHost.endsWith("." + clean))) {
                        domain = clean;
                        hostOnly = false;
                    }
                } else if ("path".equals(aKey) && aVal.startsWith("/")) {
                    path = aVal;
                } else if ("max-age".equals(aKey)) {
                    try {
                        long secs = Long.parseLong(aVal);
                        if (secs <= 0) expired = true;
                    } catch (Exception ignored) {
                    }
                }
            }
            if (!expired) {
                result.add(new RedirectCookie(name, value, domain, hostOnly, path));
            }
        }
        return result;
    }

    static void mergeRedirectCookies(
            Map<String, String> headers, Collection<RedirectCookie> cookies, URL target) {
        Map<String, String> map = new LinkedHashMap<>();
        String existing = null;
        for (Map.Entry<String, String> entry : headers.entrySet()) {
            if ("cookie".equalsIgnoreCase(entry.getKey())) {
                existing = entry.getValue();
                break;
            }
        }
        if (existing != null && !existing.trim().isEmpty()) {
            String[] pairs = existing.split(";");
            for (String pair : pairs) {
                int eq = pair.indexOf('=');
                if (eq > 0) {
                    map.put(pair.substring(0, eq).trim(), pair.substring(eq + 1).trim());
                }
            }
        }
        for (RedirectCookie rc : cookies) {
            if (rc.matches(target)) {
                map.put(rc.name, rc.value);
            }
        }
        if (!map.isEmpty()) {
            StringBuilder sb = new StringBuilder();
            for (Map.Entry<String, String> e : map.entrySet()) {
                if (sb.length() > 0) sb.append("; ");
                sb.append(e.getKey()).append("=").append(e.getValue());
            }
            for (Iterator<String> it = headers.keySet().iterator(); it.hasNext(); ) {
                if ("cookie".equalsIgnoreCase(it.next())) it.remove();
            }
            headers.put("Cookie", sb.toString());
        }
    }

    /** A non-null form selects POST; redirects preserve the existing credential boundary. */
    public static String fetch(
            String address, Map<String, String> headers, Map<String, String> form, String defaultUa)
            throws Exception {
        if (!isHttp(address)) throw new IOException("只支持 HTTP(S) 地址");
        URL initialUrl = new URL(normalizeHttp(address));
        Map<String, String> baseForwarded = new LinkedHashMap<>();
        byte[] body = null;
        if (form != null) {
            StringBuilder encoded = new StringBuilder();
            for (Map.Entry<String, String> item : form.entrySet()) {
                if (encoded.length() > 0) encoded.append('&');
                encoded.append(URLEncoder.encode(item.getKey(), "UTF-8"))
                        .append('=')
                        .append(URLEncoder.encode(item.getValue(), "UTF-8"));
            }
            body = encoded.toString().getBytes("UTF-8");
        }
        if (headers != null) mergeHeaders(baseForwarded, headers);
        if (initialUrl.getUserInfo() != null) {
            boolean explicit = false;
            for (String key : baseForwarded.keySet())
                explicit |= key.equalsIgnoreCase("Authorization");
            if (!explicit) {
                String credentials =
                        URLDecoder.decode(initialUrl.getUserInfo().replace("+", "%2B"), "UTF-8");
                baseForwarded.put("Authorization", basicAuthorization(credentials));
            }
            initialUrl =
                    new URL(
                            initialUrl.getProtocol(),
                            initialUrl.getHost(),
                            initialUrl.getPort(),
                            initialUrl.getFile());
        }

        String callerUa = null;
        for (Map.Entry<String, String> e : baseForwarded.entrySet()) {
            if ("User-Agent".equalsIgnoreCase(e.getKey())
                    && e.getValue() != null
                    && !e.getValue().trim().isEmpty()) {
                callerUa = e.getValue();
                break;
            }
        }
        String fallbackDefaultUa = defaultUa != null ? defaultUa : USER_AGENT;
        String primaryUa = callerUa != null ? callerUa : fallbackDefaultUa;

        Exception firstFailure;
        try {
            return fetchOnce(initialUrl, baseForwarded, body, primaryUa, false, false);
        } catch (NonRetryableFetchException fatal) {
            if (fatal.getCause() instanceof IOException) throw (IOException) fatal.getCause();
            throw new IOException(fatal.getMessage());
        } catch (HttpStatusException httpErr) {
            if (httpErr.status != 403) throw httpErr;
            firstFailure = httpErr;
        } catch (InterruptedIOException interrupted) {
            if (!(interrupted instanceof SocketTimeoutException)
                    || Thread.currentThread().isInterrupted()) {
                throw interrupted;
            }
            firstFailure = interrupted;
        } catch (IOException transportErr) {
            if (Thread.currentThread().isInterrupted()) throw new InterruptedIOException();
            firstFailure = transportErr;
        }

        // Phase A: UA fallback (okhttp/3.15 -> Mobile Chrome UA -> TVBox UA -> Safari UA) when
        // blocked (403) or reset after TCP handshake (skip if host failed DNS or refused TCP).
        boolean tryUaFallback =
                !(firstFailure instanceof UnknownHostException)
                        && !(firstFailure instanceof ConnectException)
                        && !(firstFailure instanceof SocketTimeoutException);
        String[] fallbackUas = {MOBILE_USER_AGENT, TVBOX_USER_AGENT, SAFARI_USER_AGENT, USER_AGENT};
        if (tryUaFallback) {
            for (String candidateUa : fallbackUas) {
                if (candidateUa.equals(primaryUa)) continue;
                if (Thread.currentThread().isInterrupted()) throw new InterruptedIOException();
                try {
                    return fetchOnce(initialUrl, baseForwarded, body, candidateUa, true, false);
                } catch (NonRetryableFetchException fatal) {
                    if (fatal.getCause() instanceof IOException)
                        throw (IOException) fatal.getCause();
                    throw new IOException(fatal.getMessage());
                } catch (HttpStatusException httpErr) {
                    if (httpErr.status != 403) throw httpErr;
                    firstFailure = httpErr;
                } catch (IOException ignored) {
                    if (Thread.currentThread().isInterrupted()) throw new InterruptedIOException();
                }
            }
        }

        // Phase B: DoH resolution fallback against DNS pollution / blackhole / edge resets.
        List<InetAddress> dohAddrs = resolveViaDoh(initialUrl.getHost());
        if (!dohAddrs.isEmpty()) {
            String[] dohUas =
                    primaryUa.equals(MOBILE_USER_AGENT)
                            ? new String[] {primaryUa, TVBOX_USER_AGENT, SAFARI_USER_AGENT}
                            : new String[] {
                                primaryUa, MOBILE_USER_AGENT, TVBOX_USER_AGENT, SAFARI_USER_AGENT
                            };
            for (String candidateUa : dohUas) {
                if (Thread.currentThread().isInterrupted()) throw new InterruptedIOException();
                try {
                    return fetchOnce(
                            initialUrl,
                            baseForwarded,
                            body,
                            candidateUa,
                            !candidateUa.equals(primaryUa),
                            true);
                } catch (NonRetryableFetchException fatal) {
                    if (fatal.getCause() instanceof IOException)
                        throw (IOException) fatal.getCause();
                    throw new IOException(fatal.getMessage());
                } catch (HttpStatusException httpErr) {
                    if (httpErr.status != 403) throw httpErr;
                    firstFailure = httpErr;
                } catch (IOException dohErr) {
                    if (Thread.currentThread().isInterrupted()) throw new InterruptedIOException();
                }
            }
        }

        throw firstFailure;
    }

    private static String fetchOnce(
            URL startUrl,
            Map<String, String> initialHeaders,
            byte[] initialBody,
            String effectiveUa,
            boolean forceUaOverride,
            boolean useDoh)
            throws Exception {
        URL next = startUrl;
        Map<String, String> forwarded = new LinkedHashMap<>(initialHeaders);
        byte[] body = initialBody;
        Map<String, RedirectCookie> redirectCookies = new LinkedHashMap<>();
        boolean forceDirect = false;
        for (int hop = 0; hop < 5; hop++) {
            if (Thread.currentThread().isInterrupted()) throw new InterruptedIOException();
            InetAddress dohOverride = null;
            if (useDoh) {
                List<InetAddress> addrs = resolveViaDoh(next.getHost());
                if (!addrs.isEmpty()) dohOverride = addrs.get(0);
            }
            boolean canFallbackDirect =
                    !forceDirect && dohOverride == null && hasActiveHttpProxy(next);
            HttpURLConnection c = openConnectionWithOverride(next, dohOverride, forceDirect);
            c.setConnectTimeout(12000);
            c.setReadTimeout(18000);
            c.setInstanceFollowRedirects(false);
            c.setRequestProperty("User-Agent", effectiveUa != null ? effectiveUa : USER_AGENT);
            for (Map.Entry<String, String> e : forwarded.entrySet()) {
                c.setRequestProperty(e.getKey(), e.getValue());
            }
            if (forceUaOverride && effectiveUa != null) {
                c.setRequestProperty("User-Agent", effectiveUa);
            }
            try {
                RequestScope.attach(c);
                int status;
                try {
                    if (body != null) {
                        c.setRequestMethod("POST");
                        c.setDoOutput(true);
                        c.setRequestProperty(
                                "Content-Type", "application/x-www-form-urlencoded; charset=UTF-8");
                        c.setFixedLengthStreamingMode(body.length);
                        try (OutputStream output = c.getOutputStream()) {
                            output.write(body);
                        }
                    }
                    status = c.getResponseCode();
                } catch (ConnectException | SocketTimeoutException proxyIo) {
                    if (canFallbackDirect) {
                        forceDirect = true;
                        hop--;
                        continue;
                    }
                    throw proxyIo;
                }
                if (canFallbackDirect && (status == 502 || status == 503 || status == 504)) {
                    forceDirect = true;
                    hop--;
                    continue;
                }
                List<String> setCookies = c.getHeaderFields().get("Set-Cookie");
                if (setCookies == null) {
                    for (Map.Entry<String, List<String>> entry : c.getHeaderFields().entrySet()) {
                        if ("set-cookie".equalsIgnoreCase(entry.getKey())) {
                            setCookies = entry.getValue();
                            break;
                        }
                    }
                }
                List<RedirectCookie> newCookies = parseSetCookies(setCookies, next);
                for (RedirectCookie cookie : newCookies) {
                    redirectCookies.put(
                            cookie.domain
                                    + "|"
                                    + cookie.hostOnly
                                    + "|"
                                    + cookie.path
                                    + "|"
                                    + cookie.name,
                            cookie);
                }
                if (status == 301
                        || status == 302
                        || status == 303
                        || status == 307
                        || status == 308) {
                    String loc = c.getHeaderField("Location");
                    if (loc == null) throw new NonRetryableFetchException("重定向缺少地址");
                    URL target = new URL(next, loc);
                    if (!isHttp(target.toString()))
                        throw new NonRetryableFetchException("不支持此重定向协议");
                    if (target.getUserInfo() != null)
                        throw new NonRetryableFetchException("来源重定向不能注入登录凭据");
                    forwarded = inheritedHeaders(next.toString(), target.toString(), forwarded);
                    mergeRedirectCookies(forwarded, redirectCookies.values(), target);
                    if (status == 301 || status == 302 || status == 303) body = null;
                    next = target;
                    continue;
                }
                if (status < 200 || status >= 300) throw new HttpStatusException(status);
                InputStream rawIn = c.getInputStream();
                if ("gzip".equalsIgnoreCase(c.getContentEncoding())) {
                    rawIn = new java.util.zip.GZIPInputStream(rawIn);
                }
                try (InputStream input = rawIn) {
                    try {
                        return read(input, MAX_JSON);
                    } catch (IOException payloadErr) {
                        if (payloadErr.getMessage() != null
                                && (payloadErr.getMessage().contains("大小限制")
                                        || payloadErr.getMessage().contains("配置图片"))) {
                            throw new NonRetryableFetchException(payloadErr);
                        }
                        throw payloadErr;
                    }
                }
            } finally {
                RequestScope.detach(c);
                c.disconnect();
            }
        }
        throw new NonRetryableFetchException("来源重定向次数过多");
    }

    private static HttpURLConnection openConnectionWithOverride(
            URL url, InetAddress overrideIp, boolean forceDirect) throws IOException {
        if (overrideIp == null) {
            return openHttpConnection(url, forceDirect);
        }
        final String originalHost = url.getHost();
        int port = url.getPort();
        String ipLiteral =
                overrideIp instanceof Inet6Address
                        ? "[" + overrideIp.getHostAddress() + "]"
                        : overrideIp.getHostAddress();
        String hostHeader =
                port >= 0 && port != url.getDefaultPort()
                        ? originalHost + ":" + port
                        : originalHost;
        if ("https".equalsIgnoreCase(url.getProtocol())) {
            URL rewritten = new URL("https", ipLiteral, port, url.getFile());
            HttpsURLConnection https =
                    (HttpsURLConnection) openHttpConnection(rewritten, forceDirect);
            https.setSSLSocketFactory(
                    new SniOverrideSocketFactory(
                            HttpsURLConnection.getDefaultSSLSocketFactory(), originalHost));
            https.setHostnameVerifier(
                    (h, session) ->
                            HttpsURLConnection.getDefaultHostnameVerifier()
                                    .verify(originalHost, session));
            https.setRequestProperty("Host", hostHeader);
            return https;
        }
        URL rewritten = new URL("http", ipLiteral, port, url.getFile());
        HttpURLConnection http = openHttpConnection(rewritten, forceDirect);
        http.setRequestProperty("Host", hostHeader);
        return http;
    }

    static List<InetAddress> resolveViaDoh(String hostname) {
        if (hostname == null) return Collections.emptyList();
        String trimmed = hostname.trim();
        if (trimmed.isEmpty() || shouldBypassDoh(trimmed)) return Collections.emptyList();
        final String asciiHost;
        try {
            asciiHost = IDN.toASCII(trimmed).toLowerCase(Locale.ROOT);
        } catch (IllegalArgumentException e) {
            return Collections.emptyList();
        }
        long now = System.currentTimeMillis();
        DohCacheEntry cached = DOH_CACHE.get(asciiHost);
        if (cached != null && cached.expireAtMs > now) {
            return cached.addresses;
        }
        String[] endpoints = dohEndpoints;
        if (endpoints == null || endpoints.length == 0) return Collections.emptyList();
        CompletionService<DohQueryResult> race = new ExecutorCompletionService<>(DOH_EXECUTOR);
        List<Future<DohQueryResult>> futures = new ArrayList<>(endpoints.length);
        for (final String endpoint : endpoints) {
            futures.add(race.submit(() -> queryDohEndpoint(endpoint, asciiHost)));
        }
        long deadlineNs = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(4000);
        try {
            for (int i = 0; i < futures.size(); i++) {
                long remainingNs = deadlineNs - System.nanoTime();
                if (remainingNs <= 0) break;
                Future<DohQueryResult> done = race.poll(remainingNs, TimeUnit.NANOSECONDS);
                if (done == null) break;
                try {
                    DohQueryResult res = done.get();
                    if (res != null && !res.addresses.isEmpty()) {
                        long ttlMs =
                                Math.max(
                                        MIN_DOH_TTL_MS,
                                        Math.min(MAX_DOH_TTL_MS, res.ttlSeconds * 1000L));
                        if (DOH_CACHE.size() >= MAX_DOH_CACHE_ENTRIES) {
                            evictDohCache(System.currentTimeMillis());
                        }
                        List<InetAddress> immutable =
                                Collections.unmodifiableList(new ArrayList<>(res.addresses));
                        DOH_CACHE.put(
                                asciiHost,
                                new DohCacheEntry(immutable, System.currentTimeMillis() + ttlMs));
                        return immutable;
                    }
                } catch (Exception ignored) {
                }
            }
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        } finally {
            for (Future<DohQueryResult> f : futures) f.cancel(true);
        }
        return Collections.emptyList();
    }

    private static final class DohQueryResult {
        final List<InetAddress> addresses;
        final long ttlSeconds;

        DohQueryResult(List<InetAddress> addresses, long ttlSeconds) {
            this.addresses = addresses;
            this.ttlSeconds = ttlSeconds;
        }
    }

    private static void evictDohCache(long now) {
        for (Iterator<Map.Entry<String, DohCacheEntry>> it = DOH_CACHE.entrySet().iterator();
                it.hasNext(); ) {
            if (it.next().getValue().expireAtMs <= now) it.remove();
        }
        if (DOH_CACHE.size() >= MAX_DOH_CACHE_ENTRIES) {
            Iterator<String> keys = DOH_CACHE.keySet().iterator();
            if (keys.hasNext()) {
                DOH_CACHE.remove(keys.next());
            }
        }
    }

    private static boolean shouldBypassDoh(String host) {
        String lower = host.toLowerCase(Locale.ROOT);
        if ("localhost".equals(lower)
                || lower.endsWith(".localhost")
                || lower.endsWith(".local")
                || lower.contains(":")) {
            return true;
        }
        if (dohEndpoints == DEFAULT_DOH_ENDPOINTS
                && (lower.endsWith(".test")
                        || lower.endsWith(".example")
                        || lower.endsWith(".invalid"))) {
            return true;
        }
        return lower.matches("\\d{1,3}(?:\\.\\d{1,3}){3}");
    }

    private static boolean isLoopbackEndpoint(String endpoint) {
        try {
            String h = new URL(endpoint).getHost().toLowerCase(Locale.ROOT);
            return "127.0.0.1".equals(h)
                    || "localhost".equals(h)
                    || "[::1]".equals(h)
                    || "::1".equals(h);
        } catch (Exception e) {
            return false;
        }
    }

    private static boolean isPoisonedAddress(InetAddress addr, boolean allowLoopback) {
        if (addr == null || addr.isAnyLocalAddress() || addr.isMulticastAddress()) return true;
        if (addr.isLoopbackAddress() && !allowLoopback) return true;
        byte[] raw = addr.getAddress();
        return raw.length == 4
                && (raw[0] & 0xff) == 255
                && (raw[1] & 0xff) == 255
                && (raw[2] & 0xff) == 255
                && (raw[3] & 0xff) == 255;
    }

    private static DohQueryResult queryDohEndpoint(String endpoint, String asciiHost)
            throws Exception {
        byte[] wireQuery = buildDnsWireQuery(asciiHost, 1);
        String encoded = encodeBase64UrlNoPad(wireQuery);
        String urlStr = endpoint + (endpoint.contains("?") ? "&dns=" : "?dns=") + encoded;
        boolean allowLoopback = isLoopbackEndpoint(endpoint);
        HttpURLConnection conn = openHttpConnection(new URL(urlStr), allowLoopback);
        conn.setConnectTimeout(3500);
        conn.setReadTimeout(3500);
        conn.setInstanceFollowRedirects(true);
        conn.setRequestProperty("Accept", "application/dns-message, application/dns-json;q=0.8");
        conn.setRequestProperty("User-Agent", USER_AGENT);
        try {
            if (conn.getResponseCode() != 200) return null;
            byte[] payload;
            try (InputStream in = conn.getInputStream();
                    ByteArrayOutputStream bos = new ByteArrayOutputStream()) {
                byte[] buf = new byte[2048];
                int n;
                while ((n = in.read(buf)) != -1) {
                    if (bos.size() + n > 65536) return null;
                    bos.write(buf, 0, n);
                }
                payload = bos.toByteArray();
            }
            if (payload.length == 0) return null;
            String contentType = conn.getContentType();
            if ((contentType != null && contentType.toLowerCase(Locale.ROOT).contains("json"))
                    || payload[0] == '{') {
                return parseDohJsonResponse(new String(payload, "UTF-8"), asciiHost, allowLoopback);
            }
            return parseDnsWireResponse(payload, asciiHost, allowLoopback);
        } finally {
            conn.disconnect();
        }
    }

    private static byte[] buildDnsWireQuery(String asciiHost, int qtype) throws IOException {
        ByteArrayOutputStream out = new ByteArrayOutputStream(64);
        // Header: ID=0 (RFC 8484 §4.1), Flags=0x0100 (RD=1), QDCOUNT=1, AN/NS/AR=0
        out.write(0);
        out.write(0);
        out.write(0x01);
        out.write(0x00);
        out.write(0);
        out.write(1);
        for (int i = 0; i < 6; i++) out.write(0);
        for (String label : asciiHost.split("\\.")) {
            if (label.isEmpty()) continue;
            byte[] bytes = label.getBytes("US-ASCII");
            if (bytes.length > 63) throw new IOException("DNS label too long");
            out.write(bytes.length);
            out.write(bytes);
        }
        out.write(0);
        out.write((qtype >> 8) & 0xff);
        out.write(qtype & 0xff);
        out.write(0);
        out.write(1); // QCLASS IN
        return out.toByteArray();
    }

    private static String encodeBase64UrlNoPad(byte[] input) {
        String alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
        StringBuilder sb = new StringBuilder((input.length * 4 + 2) / 3);
        for (int i = 0; i < input.length; i += 3) {
            int a = input[i] & 0xff;
            int b = (i + 1 < input.length) ? (input[i + 1] & 0xff) : 0;
            int c = (i + 2 < input.length) ? (input[i + 2] & 0xff) : 0;
            sb.append(alphabet.charAt(a >> 2));
            sb.append(alphabet.charAt(((a & 0x03) << 4) | (b >> 4)));
            if (i + 1 < input.length) sb.append(alphabet.charAt(((b & 0x0f) << 2) | (c >> 6)));
            if (i + 2 < input.length) sb.append(alphabet.charAt(c & 0x3f));
        }
        return sb.toString();
    }

    private static int skipDnsName(byte[] msg, int offset) {
        int pos = offset;
        int jumps = 0;
        while (pos < msg.length) {
            int len = msg[pos] & 0xff;
            if (len == 0) return pos + 1;
            if ((len & 0xc0) == 0xc0) {
                return (pos + 2 <= msg.length) ? pos + 2 : -1;
            }
            if ((len & 0xc0) != 0) return -1;
            pos += 1 + len;
            if (++jumps > 128) return -1;
        }
        return -1;
    }

    private static DohQueryResult parseDnsWireResponse(
            byte[] msg, String asciiHost, boolean allowLoopback) {
        if (msg == null || msg.length < 12) return null;
        int flags = ((msg[2] & 0xff) << 8) | (msg[3] & 0xff);
        if ((flags & 0x8000) == 0 || (flags & 0x000f) != 0) return null;
        int qdCount = ((msg[4] & 0xff) << 8) | (msg[5] & 0xff);
        int anCount = ((msg[6] & 0xff) << 8) | (msg[7] & 0xff);
        if (anCount <= 0) return null;
        int pos = 12;
        for (int i = 0; i < qdCount; i++) {
            pos = skipDnsName(msg, pos);
            if (pos < 0 || pos + 4 > msg.length) return null;
            pos += 4;
        }
        List<InetAddress> out = new ArrayList<>();
        long minTtl = 300;
        for (int i = 0; i < anCount && pos < msg.length; i++) {
            pos = skipDnsName(msg, pos);
            if (pos < 0 || pos + 10 > msg.length) break;
            int type = ((msg[pos] & 0xff) << 8) | (msg[pos + 1] & 0xff);
            int cls = ((msg[pos] & 0xff) << 8) | (msg[pos + 3] & 0xff);
            long ttl =
                    ((long) (msg[pos + 4] & 0xff) << 24)
                            | ((long) (msg[pos + 5] & 0xff) << 16)
                            | ((long) (msg[pos + 6] & 0xff) << 8)
                            | (msg[pos + 7] & 0xff);
            int rdLength = ((msg[pos + 8] & 0xff) << 8) | (msg[pos + 9] & 0xff);
            pos += 10;
            if (pos + rdLength > msg.length) break;
            if (cls == 1 && ((type == 1 && rdLength == 4) || (type == 28 && rdLength == 16))) {
                byte[] rawIp = Arrays.copyOfRange(msg, pos, pos + rdLength);
                try {
                    InetAddress addr = InetAddress.getByAddress(asciiHost, rawIp);
                    if (!isPoisonedAddress(addr, allowLoopback)) {
                        out.add(addr);
                        if (ttl > 0 && ttl < minTtl) minTtl = ttl;
                    }
                } catch (UnknownHostException ignored) {
                }
            }
            pos += rdLength;
        }
        return out.isEmpty() ? null : new DohQueryResult(out, minTtl);
    }

    private static DohQueryResult parseDohJsonResponse(
            String jsonText, String asciiHost, boolean allowLoopback) {
        try {
            JSONObject obj = new JSONObject(jsonText);
            if (obj.optInt("Status", 0) != 0) return null;
            JSONArray answers = obj.optJSONArray("Answer");
            if (answers == null || answers.length() == 0) return null;
            List<InetAddress> out = new ArrayList<>();
            long minTtl = 300;
            for (int i = 0; i < answers.length(); i++) {
                JSONObject ans = answers.optJSONObject(i);
                if (ans == null) continue;
                int type = ans.optInt("type", 0);
                String data = optSafeString(ans, "data", "").trim();
                long ttl = ans.optLong("TTL", 300);
                if ((type == 1 && data.matches("\\d{1,3}(?:\\.\\d{1,3}){3}"))
                        || (type == 28 && data.contains(":"))) {
                    InetAddress parsed = InetAddress.getByName(data);
                    InetAddress bound = InetAddress.getByAddress(asciiHost, parsed.getAddress());
                    if (!isPoisonedAddress(bound, allowLoopback)) {
                        out.add(bound);
                        if (ttl > 0 && ttl < minTtl) minTtl = ttl;
                    }
                }
            }
            return out.isEmpty() ? null : new DohQueryResult(out, minTtl);
        } catch (Exception e) {
            return null;
        }
    }

    // Keep this parser usable in the JVM checks and on Android 23 (java.util.Base64 is API 26).
    static String basicAuthorization(String credentials) throws IOException {
        byte[] input = credentials.getBytes("UTF-8");
        String alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        StringBuilder result = new StringBuilder("Basic ");
        for (int i = 0; i < input.length; i += 3) {
            int a = input[i] & 255,
                    b = i + 1 < input.length ? input[i + 1] & 255 : 0,
                    c = i + 2 < input.length ? input[i + 2] & 255 : 0;
            result.append(alphabet.charAt(a >> 2))
                    .append(alphabet.charAt(((a & 3) << 4) | (b >> 4)))
                    .append(
                            i + 1 < input.length
                                    ? alphabet.charAt(((b & 15) << 2) | (c >> 6))
                                    : '=')
                    .append(i + 2 < input.length ? alphabet.charAt(c & 63) : '=');
        }
        return result.toString();
    }

    public static String query(String address, String... pairs) throws Exception {
        URI u = new URI(address);
        String existing = u.getRawQuery();
        List<String> p = new ArrayList<>();
        Set<String> replaced = new HashSet<>();
        for (int i = 0; i < pairs.length; i += 2) replaced.add(pairs[i]);
        if (existing != null)
            for (String part : existing.split("&")) {
                String key = URLDecoder.decode(part.split("=", 2)[0], "UTF-8");
                if (!replaced.contains(key)) p.add(part);
            }
        for (int i = 0; i < pairs.length; i += 2)
            p.add(
                    URLEncoder.encode(pairs[i], "UTF-8")
                            + "="
                            + URLEncoder.encode(pairs[i + 1], "UTF-8"));
        String base = address.split("[?#]", 2)[0];
        StringBuilder joined = new StringBuilder();
        for (String part : p) {
            if (joined.length() > 0) joined.append('&');
            joined.append(part);
        }
        return base + "?" + joined;
    }

    private static String unescapeXml(String text) {
        if (text == null || text.isEmpty()) return "";
        String s = text.trim();
        if (s.startsWith("<![CDATA[") && s.endsWith("]]>")) {
            s = s.substring(9, s.length() - 3).trim();
        } else {
            s = s.replaceAll("<!\\[CDATA\\[([\\s\\S]*?)\\]\\]>", "$1");
        }
        return s.replace("&amp;", "&")
                .replace("&lt;", "<")
                .replace("&gt;", ">")
                .replace("&quot;", "\"")
                .replace("&apos;", "'")
                .replace("&#39;", "'")
                .trim();
    }

    private static String xmlTagValue(String xmlBlock, String tag) {
        java.util.regex.Matcher m =
                java.util.regex.Pattern.compile(
                                "<" + tag + "\\b[^>]*>([\\s\\S]*?)</" + tag + ">",
                                java.util.regex.Pattern.CASE_INSENSITIVE)
                        .matcher(xmlBlock);
        return m.find() ? unescapeXml(m.group(1)) : "";
    }

    public static List<Category> categories(String json) throws Exception {
        if (json != null && json.trim().startsWith("<")) {
            List<Category> result = new ArrayList<>();
            java.util.regex.Matcher m =
                    java.util.regex.Pattern.compile(
                                    "<ty\\b[^>]*\\bid\\s*=\\s*[\"']([^\"']+)[\"'][^>]*>([\\s\\S]*?)</ty>",
                                    java.util.regex.Pattern.CASE_INSENSITIVE)
                            .matcher(json);
            while (m.find()) {
                Category c = new Category();
                c.id = m.group(1).trim();
                c.name = unescapeXml(m.group(2));
                if (c.name.isEmpty()) c.name = c.id;
                if (!c.id.isEmpty()) result.add(c);
            }
            return result;
        }
        JSONObject o = new JSONObject(json);
        JSONArray a = o.optJSONArray("class");
        List<Category> result = new ArrayList<>();
        if (a != null)
            for (int i = 0; i < a.length(); i++) {
                JSONObject j = a.optJSONObject(i);
                if (j == null) continue;
                Category c = new Category();
                c.id = optSafeString(j, "type_id", "").trim();
                String cname = optSafeString(j, "type_name", "");
                c.name = cname.isEmpty() ? c.id : cname;
                if (!c.id.isEmpty()) result.add(c);
            }
        return result;
    }

    public static String searchTitle(Video v) {
        if (v.id != null && v.id.startsWith("msearch:")) {
            String[] parts = v.id.substring(8).split("###", -1);
            for (String part : parts) {
                String text = part.trim();
                // Some catalogue spiders put a Douban/TMDB id before the title.
                // That id is metadata, not a title to prefill into global search.
                if (!text.isEmpty() && !isHttp(text) && !text.matches("[0-9]+")) return text;
            }
        }
        return v.title == null ? "" : v.title.trim();
    }

    private static void parsePlayLines(Video v, String[] from, String[] urls) {
        for (int i = 0; i < urls.length; i++) {
            if (urls[i] == null || urls[i].trim().isEmpty()) continue;
            Line l = new Line();
            l.name =
                    i < from.length && from[i] != null && !from[i].trim().isEmpty()
                            ? from[i].trim()
                            : "线路 " + (i + 1);
            for (String part : urls[i].split("#")) {
                if (part.trim().isEmpty()) continue;
                int at = part.indexOf('$');
                Episode e = new Episode();
                e.name = at >= 0 ? part.substring(0, at) : "播放";
                e.url = at >= 0 ? part.substring(at + 1) : part;
                l.episodes.add(e);
            }
            if (!l.episodes.isEmpty()) v.lines.add(l);
        }
    }

    private static void prioritizeDirectStreamLines(Video v) {
        if (v == null || v.lines.size() <= 1) return;
        List<Line> direct = new ArrayList<>();
        List<Line> indirect = new ArrayList<>();
        for (Line l : v.lines) {
            boolean hasDirect =
                    !l.episodes.isEmpty()
                            && (isDirectStreamUrl(l.episodes.get(0).url)
                                    || (l.name != null
                                            && l.name.toLowerCase(Locale.ROOT).contains("m3u8")));
            if (hasDirect) direct.add(l);
            else indirect.add(l);
        }
        if (!direct.isEmpty() && !indirect.isEmpty()) {
            v.lines.clear();
            v.lines.addAll(direct);
            v.lines.addAll(indirect);
        }
    }

    private static Video video(JSONObject j) {
        Video v = new Video();
        v.id = optSafeString(j, "vod_id", "");
        String vTitle = optSafeString(j, "vod_name", "");
        v.title = vTitle.isEmpty() ? "未命名影片" : vTitle;
        v.poster = optSafeString(j, "vod_pic", "");
        v.remarks = optSafeString(j, "vod_remarks", "");
        Object action = j.opt("action");
        v.action =
                action == null || action == JSONObject.NULL ? "" : optSafeString(j, "action", "");
        v.tag = optSafeString(j, "vod_tag", "");
        if (v.action.isEmpty()
                && "action".equalsIgnoreCase(v.tag)
                && v.id != null
                && !v.id.isEmpty()) {
            v.action = v.id;
        }
        v.year = optSafeString(j, "vod_year", "");
        v.area = optSafeString(j, "vod_area", "");
        v.genre = optSafeString(j, "vod_class", optSafeString(j, "type_name", ""));
        v.actor = optSafeString(j, "vod_actor", "");
        v.director = optSafeString(j, "vod_director", "");
        double dbVal = parseValidDoubanScore(optSafeString(j, "vod_douban_score", ""));
        if (dbVal <= 0.0) {
            dbVal = parseValidDoubanScore(optSafeString(j, "vod_score", ""));
        }
        if (dbVal <= 0.0) {
            dbVal = parseValidDoubanScore(optSafeString(j, "douban_score", ""));
        }
        if (dbVal <= 0.0) {
            dbVal = parseValidDoubanScore(optSafeString(j, "score", ""));
        }
        if (dbVal <= 0.0) {
            dbVal = parseValidDoubanScore(optSafeString(j, "rating", optSafeString(j, "rate", "")));
        }
        v.doubanScore = dbVal >= 2.0 ? String.format(java.util.Locale.US, "%.1f", dbVal) : "";
        String rawDbId =
                optSafeString(j, "vod_douban_id", optSafeString(j, "douban_id", "")).trim();
        v.doubanId = rawDbId.matches("\\d{5,12}") ? rawDbId : "";
        v.description =
                optSafeString(j, "vod_content", "")
                        .replaceAll("<[^>]*>", " ")
                        .replace("&nbsp;", " ")
                        .trim();
        String rawFrom = optSafeString(j, "vod_play_from", "");
        String rawUrl = optSafeString(j, "vod_play_url", "");
        if (rawUrl.isEmpty() && j.has("vod_play_list")) {
            JSONArray playList = j.optJSONArray("vod_play_list");
            if (playList != null) {
                List<String> froms = new ArrayList<>();
                List<String> urls = new ArrayList<>();
                for (int i = 0; i < playList.length(); i++) {
                    JSONObject p = playList.optJSONObject(i);
                    if (p == null) continue;
                    String u = Json.str(p, "url", "");
                    JSONObject urlsObj = p.optJSONObject("urls");
                    if (u.isEmpty() && urlsObj != null) {
                        List<String> segs = new ArrayList<>();
                        Iterator<String> it = urlsObj.keys();
                        while (it.hasNext()) {
                            JSONObject ep = urlsObj.optJSONObject(it.next());
                            if (ep == null) continue;
                            String epUrl = Json.str(ep, "url", "");
                            if (epUrl.isEmpty()) continue;
                            String epName = Json.str(ep, "name", "正片");
                            segs.add(epName + "$" + epUrl);
                        }
                        u = joinStrings("#", segs);
                    }
                    if (u.isEmpty()) continue;
                    JSONObject pInfo = p.optJSONObject("player_info");
                    String showName =
                            pInfo != null
                                    ? Json.str(pInfo, "show", Json.str(pInfo, "from", ""))
                                    : "";
                    if (showName.isEmpty())
                        showName = Json.str(p, "from", Json.str(p, "name", "默认线路"));
                    froms.add(showName);
                    urls.add(u);
                }
                if (!froms.isEmpty()) {
                    rawFrom = joinStrings("$$$", froms);
                    rawUrl = joinStrings("$$$", urls);
                }
            }
        }
        String[] from = rawFrom.split("\\$\\$\\$", -1), urls = rawUrl.split("\\$\\$\\$", -1);
        parsePlayLines(v, from, urls);
        prioritizeDirectStreamLines(v);
        return v;
    }

    private static String joinStrings(String delimiter, List<String> parts) {
        if (parts == null || parts.isEmpty()) return "";
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < parts.size(); i++) {
            if (i > 0) sb.append(delimiter);
            String item = parts.get(i);
            if (item != null) sb.append(item);
        }
        return sb.toString();
    }

    private static Video videoXml(String block) {
        Video v = new Video();
        v.id = xmlTagValue(block, "id");
        if (v.id.isEmpty()) v.id = xmlTagValue(block, "vod_id");
        v.title = xmlTagValue(block, "name");
        if (v.title.isEmpty()) v.title = xmlTagValue(block, "vod_name");
        if (v.title.isEmpty()) v.title = "未命名影片";
        v.poster = xmlTagValue(block, "pic");
        if (v.poster.isEmpty()) v.poster = xmlTagValue(block, "vod_pic");
        v.remarks = xmlTagValue(block, "note");
        if (v.remarks.isEmpty()) v.remarks = xmlTagValue(block, "vod_remarks");
        v.action = "";
        v.tag = xmlTagValue(block, "type");
        v.genre = xmlTagValue(block, "vod_class");
        if (v.genre.isEmpty()) v.genre = v.tag;
        v.year = xmlTagValue(block, "year");
        v.area = xmlTagValue(block, "area");
        v.actor = xmlTagValue(block, "actor");
        v.director = xmlTagValue(block, "director");
        double xmlDb = parseValidDoubanScore(xmlTagValue(block, "vod_douban_score"));
        if (xmlDb <= 0.0) xmlDb = parseValidDoubanScore(xmlTagValue(block, "douban"));
        if (xmlDb <= 0.0) xmlDb = parseValidDoubanScore(xmlTagValue(block, "score"));
        v.doubanScore = xmlDb >= 2.0 ? String.format(java.util.Locale.US, "%.1f", xmlDb) : "";
        String des = xmlTagValue(block, "des");
        if (des.isEmpty()) des = xmlTagValue(block, "vod_content");
        v.description = des.replaceAll("<[^>]*>", " ").replace("&nbsp;", " ").trim();

        java.util.regex.Matcher ddMatcher =
                java.util.regex.Pattern.compile(
                                "<dd\\b([^>]*)>([\\s\\S]*?)</dd>",
                                java.util.regex.Pattern.CASE_INSENSITIVE)
                        .matcher(block);
        int lineIdx = 0;
        while (ddMatcher.find()) {
            String attrs = ddMatcher.group(1);
            String body = unescapeXml(ddMatcher.group(2));
            if (body.isEmpty()) continue;
            String flag = "";
            java.util.regex.Matcher flagM =
                    java.util.regex.Pattern.compile(
                                    "flag\\s*=\\s*[\"']([^\"']+)[\"']",
                                    java.util.regex.Pattern.CASE_INSENSITIVE)
                            .matcher(attrs);
            if (flagM.find()) flag = flagM.group(1).trim();
            String[] subUrls = body.split("\\$\\$\\$", -1);
            String[] subFrom = new String[subUrls.length];
            for (int i = 0; i < subUrls.length; i++) {
                lineIdx++;
                subFrom[i] =
                        !flag.isEmpty()
                                ? (subUrls.length > 1 ? flag + " " + (i + 1) : flag)
                                : ("线路 " + lineIdx);
            }
            parsePlayLines(v, subFrom, subUrls);
        }
        prioritizeDirectStreamLines(v);
        return v;
    }

    public static Listing listing(String json) throws Exception {
        if (json != null && json.trim().startsWith("<")) {
            Listing l = new Listing();
            java.util.regex.Matcher listM =
                    java.util.regex.Pattern.compile(
                                    "<list\\b([^>]*)>", java.util.regex.Pattern.CASE_INSENSITIVE)
                            .matcher(json);
            if (listM.find()) {
                String attrs = listM.group(1);
                java.util.regex.Matcher pgM =
                        java.util.regex.Pattern.compile(
                                        "\\bpage\\s*=\\s*[\"']?(\\d+)",
                                        java.util.regex.Pattern.CASE_INSENSITIVE)
                                .matcher(attrs);
                if (pgM.find()) {
                    try {
                        l.page = Math.max(1, Integer.parseInt(pgM.group(1)));
                    } catch (Exception ignored) {
                    }
                }
                java.util.regex.Matcher pcM =
                        java.util.regex.Pattern.compile(
                                        "\\bpagecount\\s*=\\s*[\"']?(\\d+)",
                                        java.util.regex.Pattern.CASE_INSENSITIVE)
                                .matcher(attrs);
                if (pcM.find()) {
                    try {
                        l.pageCount = Math.max(l.page, Integer.parseInt(pcM.group(1)));
                    } catch (Exception ignored) {
                    }
                }
            }
            java.util.regex.Matcher vidM =
                    java.util.regex.Pattern.compile(
                                    "<video\\b[^>]*>([\\s\\S]*?)</video>",
                                    java.util.regex.Pattern.CASE_INSENSITIVE)
                            .matcher(json);
            while (vidM.find()) {
                if (l.videos.size() >= 500) throw new IOException("单页超过 500 项限制");
                Video v = videoXml(vidM.group(1));
                if (v.id != null && !v.id.isEmpty()) l.videos.add(v);
            }
            return l;
        }
        JSONObject o = new JSONObject(json);
        if (!o.has("list") && o.optJSONObject("data") != null) {
            o = o.getJSONObject("data");
        }
        Listing l = new Listing();
        l.page = Math.max(1, o.optInt("page", 1));
        l.pageCount = Math.max(l.page, o.optInt("pagecount", l.page));
        JSONArray a = o.optJSONArray("list");
        if (a == null) throw new IOException("来源没有返回 JSON list");
        if (a.length() > 500) throw new IOException("单页超过 500 项限制");
        for (int i = 0; i < a.length(); i++) {
            JSONObject j = a.optJSONObject(i);
            if (j != null) l.videos.add(video(j));
        }
        return l;
    }

    private static boolean isLoopbackUrlHost(String host) {
        if (host == null || host.isEmpty()) return false;
        String bare = host.trim();
        if ("::1".equals(bare)) return true;
        if (bare.startsWith("[")) {
            int close = bare.indexOf(']');
            if (close < 0) return false;
            bare = bare.substring(0, close + 1);
        } else {
            int colon = bare.indexOf(':');
            if (colon >= 0) bare = bare.substring(0, colon);
        }
        return "127.0.0.1".equals(bare)
                || "localhost".equalsIgnoreCase(bare)
                || "[::1]".equals(bare);
    }

    private static boolean hasActiveHttpProxy(URL url) {
        if (url == null || isLoopbackUrlHost(url.getHost())) return false;
        try {
            ProxySelector selector = ProxySelector.getDefault();
            if (selector == null) return false;
            List<Proxy> proxies = selector.select(url.toURI());
            if (proxies == null) return false;
            for (Proxy p : proxies) {
                if (p != null && p.type() != Proxy.Type.DIRECT) return true;
            }
        } catch (Exception ignored) {
        }
        return false;
    }

    private static HttpURLConnection openHttpConnection(URL url, boolean forceDirect)
            throws IOException {
        if ("https".equalsIgnoreCase(url.getProtocol())) {
            ensureApi23RootTrust();
        }
        if (forceDirect || isLoopbackUrlHost(url.getHost())) {
            return (HttpURLConnection) url.openConnection(Proxy.NO_PROXY);
        }
        return (HttpURLConnection) url.openConnection();
    }

    public static void assertMedia(String address, Map<String, String> headers) throws Exception {
        if (!isHttp(address)) throw new IOException("此剧集不是 HTTP(S) 直连媒体，基础版不能播放");
        HttpURLConnection c = openHttpConnection(new URL(normalizeHttp(address)), false);
        c.setRequestMethod("HEAD");
        c.setConnectTimeout(12000);
        c.setReadTimeout(12000);
        c.setInstanceFollowRedirects(true);
        c.setRequestProperty("User-Agent", USER_AGENT);
        for (Map.Entry<String, String> e : headers.entrySet())
            c.setRequestProperty(e.getKey(), e.getValue());
        try {
            int status = c.getResponseCode();
            String type = c.getContentType();
            if (type != null
                    && (type.toLowerCase(Locale.ROOT).contains("text/html")
                            || type.toLowerCase(Locale.ROOT).contains("application/json")))
                throw new IOException("剧集返回网页或 JSON，需要额外解析，基础版尚未支持");
            if (status >= 400 && status != 405) throw new IOException("媒体地址返回 HTTP " + status);
        } finally {
            c.disconnect();
        }
    }

    private Cms() {}
}
