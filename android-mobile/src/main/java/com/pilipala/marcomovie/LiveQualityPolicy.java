package com.pilipala.marcomovie;

import java.net.Inet6Address;
import java.net.InetAddress;
import java.net.NetworkInterface;
import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Enumeration;
import java.util.HashSet;
import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import org.json.JSONArray;
import org.json.JSONObject;

/**
 * Pure-Java live TV quality optimization policy: channel name normalization, cross-source channel
 * aggregation, {@code udpxy} multicast-to-unicast rewriting, IPv6 reachability awareness, and
 * measured-resolution stream ranking.
 */
public final class LiveQualityPolicy {
    private LiveQualityPolicy() {}

    public static final String MERGED_SOURCE_URL = "marcomovie://live-merged";
    public static final String MERGED_SOURCE_NAME = "✨ 智能聚合 · 高清优选";
    private static final int MAX_METRICS_ENTRIES = 400;
    private static final long FAILURE_COOLDOWN_MS = 30L * 60L * 1000L;

    private static volatile long ipv6CheckedAtMs = 0L;
    private static volatile boolean cachedHasIpv6 = false;

    private static final Pattern CCTV_NUMERIC =
            Pattern.compile("(?i)^CCTV[-\\s_]*0*([1-9]|1[0-7])(?![0-9+]).*$");
    private static final Pattern NOISE_BRACKETS =
            Pattern.compile(
                    "(?i)[\\[\\(（【]\\s*(?:8K|4K|2K|UHD|FHD|HD|SD|1080[PI]?|720P?|576P?|480P?|"
                            + "50FPS|60FPS|25FPS|HEVC|H\\.?265|H\\.?264|AVC|HDR|HLG|"
                            + "超高清|超清|高清|标清|流畅|蓝光|原画|高码|低码|"
                            + "IPV6|IPV4|V6|V4|组播|单播|备用|主线|专线|电信|联通|移动|广电|[0-9]+M)"
                            + "[\\s/·\\-A-Z0-9]*[\\]\\)）】]");
    private static final Pattern TRAILING_QUALITY_TOKENS =
            Pattern.compile(
                    "(?i)(?:[\\s\\-_·]+(?:FHD|UHD|HD|SD|1080[PI]?|720P?|576P?|HEVC|H\\.?265|"
                            + "50FPS|60FPS|IPV6|IPV4|高清|超清|标清|蓝光|原画|高码|备用))+$");
    private static final Pattern VOLATILE_QUERY_KEY =
            Pattern.compile(
                    "(?i)^(token|sign|signature|auth|auth_key|wssecret|wstime|txsecret|txtime|"
                            + "timestamp|ts|t|expires|expire|nonce|salt)$");

    public static final class Metrics {
        public int width;
        public int height;
        public int firstFrameMs;
        public long okAt;
        public int failCount;
        public long failAt;

        public int maxEdge() {
            return Math.max(width, height);
        }

        public int minEdge() {
            return width > 0 && height > 0 ? Math.min(width, height) : 0;
        }

        public String resolutionBadge() {
            int longEdge = maxEdge();
            int shortEdge = minEdge();
            if (longEdge >= 3800 || shortEdge >= 2000) return "实测4K";
            if (longEdge >= 2500 || shortEdge >= 1400) return "实测2K";
            if (longEdge >= 1900 || shortEdge >= 1000) return "实测1080P";
            if (longEdge >= 1200 || shortEdge >= 700) return "实测720P";
            if (longEdge > 0) return "实测" + height + "P";
            return "";
        }
    }

    public static final class CustomLiveSource {
        public final String name;
        public final String url;

        public CustomLiveSource(String name, String url) {
            this.name = name == null ? "" : name.trim();
            this.url = url == null ? "" : url.trim();
        }
    }

    public static final class NamedCatalog {
        public final String sourceName;
        public final LiveCatalog.Catalog catalog;

        public NamedCatalog(String sourceName, LiveCatalog.Catalog catalog) {
            this.sourceName = sourceName == null ? "" : sourceName.trim();
            this.catalog = catalog;
        }
    }

    /** Normalizes a channel title so variants across subscriptions merge into one logical channel. */
    public static String canonicalChannelName(String rawName) {
        if (rawName == null) return "未命名频道";
        String s = rawName.trim();
        if (s.isEmpty()) return "未命名频道";
        s = NOISE_BRACKETS.matcher(s).replaceAll(" ").trim();
        String upper = s.toUpperCase(Locale.ROOT);

        if (upper.startsWith("CCTV")) {
            if (upper.matches("^CCTV[-\\s_]*8K.*")) return "CCTV-8K";
            if (upper.matches("^CCTV[-\\s_]*4K.*")) return "CCTV-4K";
            if (upper.matches("^CCTV[-\\s_]*5\\+.*") || upper.contains("CCTV5+")) {
                return "CCTV-5+";
            }
            if (upper.matches("^CCTV[-\\s_]*0*4(?![0-9]).*")) {
                if (s.contains("欧洲") || upper.contains("EURO")) return "CCTV-4欧洲";
                if (s.contains("美洲") || upper.contains("AMER")) return "CCTV-4美洲";
                return "CCTV-4";
            }
            Matcher m = CCTV_NUMERIC.matcher(s);
            if (m.matches()) {
                return "CCTV-" + Integer.parseInt(m.group(1));
            }
        }

        if (upper.startsWith("CGTN")) {
            if (s.contains("纪录") || upper.contains("DOC")) return "CGTN纪录";
            if (s.contains("法语") || upper.contains("FRAN")) return "CGTN法语";
            if (s.contains("西语") || s.contains("西班牙") || upper.contains("ESP")) return "CGTN西语";
            if (s.contains("阿语") || s.contains("阿拉伯") || upper.contains("ARAB")) return "CGTN阿语";
            if (s.contains("俄语") || upper.contains("RUS")) return "CGTN俄语";
            return "CGTN";
        }

        String stripped = TRAILING_QUALITY_TOKENS.matcher(s).replaceAll("").trim();
        if (!stripped.isEmpty()) s = stripped;

        if (s.contains("卫视")) {
            boolean dedicated4k =
                    s.matches("(?i).*卫视[-\\s]*4K.*")
                            && !rawName.matches("(?i).*\\[\\s*4K\\s*\\].*");
            int idx = s.indexOf("卫视");
            String prefix = s.substring(0, idx).replaceAll("[\\s\\-_·]+", "").trim();
            if (!prefix.isEmpty() && prefix.length() <= 8) {
                return dedicated4k ? prefix + "卫视4K" : prefix + "卫视";
            }
        }

        return s.replaceAll("\\s{2,}", " ").trim();
    }

    public static String standardGroupForChannel(String canonicalName, String originalGroup) {
        if (canonicalName != null) {
            if (canonicalName.startsWith("CCTV-") || canonicalName.startsWith("CGTN")) {
                return "央视频道";
            }
            if (canonicalName.endsWith("卫视") || canonicalName.endsWith("卫视4K")) {
                return "卫视频道";
            }
        }
        String g = originalGroup == null ? "" : originalGroup.trim();
        return g.isEmpty() ? "精选频道" : g;
    }

    public static boolean isMulticastUrl(String url) {
        if (url == null) return false;
        String t = url.trim().toLowerCase(Locale.ROOT);
        return t.startsWith("rtp://") || t.startsWith("udp://");
    }

    public static boolean isEmbyLiveUrl(String url) {
        if (url == null) return false;
        return url.trim().toLowerCase(Locale.ROOT).startsWith("mmemby://live?");
    }

    public static boolean isClearKeyScheme(String scheme) {
        if (scheme == null) return false;
        String s = scheme.trim().toLowerCase(Locale.ROOT);
        return s.equals("clearkey")
                || s.equals("org.w3.clearkey")
                || s.equals("e2719d58-a985-b3c9-781a-b030af78d30e");
    }

    /**
     * Converts Kodi ClearKey {@code kidHex:keyHex} (or comma-separated pairs) or raw JWK JSON into
     * canonical ClearKey JSON bytes accepted by Media3 {@code LocalMediaDrmCallback}. Uses a pure
     * Java Base64URL encoder to preserve Android API 23 compatibility.
     */
    public static String normalizeClearKeyJwkJson(String rawLicenseKey) {
        if (rawLicenseKey == null) return null;
        String trimmed = rawLicenseKey.trim();
        if (trimmed.isEmpty()
                || trimmed.regionMatches(true, 0, "http://", 0, 7)
                || trimmed.regionMatches(true, 0, "https://", 0, 8)) {
            return null;
        }
        if (trimmed.startsWith("{")) {
            try {
                JSONObject jwk = new JSONObject(trimmed);
                JSONArray keys = jwk.optJSONArray("keys");
                if (keys != null && keys.length() > 0) {
                    if (!jwk.has("type")) jwk.put("type", "temporary");
                    return jwk.toString();
                }
            } catch (Exception ignored) {
            }
            return null;
        }
        JSONArray keys = new JSONArray();
        for (String entry : trimmed.split("[,;\\s]+")) {
            int colon = entry.indexOf(':');
            if (colon <= 0 || colon >= entry.length() - 1) continue;
            byte[] kidBytes = decodeHex16(entry.substring(0, colon));
            byte[] keyBytes = decodeHex16(entry.substring(colon + 1));
            if (kidBytes == null || keyBytes == null) continue;
            try {
                keys.put(
                        new JSONObject()
                                .put("kty", "oct")
                                .put("kid", base64UrlNoPad(kidBytes))
                                .put("k", base64UrlNoPad(keyBytes)));
            } catch (Exception ignored) {
            }
        }
        if (keys.length() == 0) return null;
        try {
            return new JSONObject().put("keys", keys).put("type", "temporary").toString();
        } catch (Exception ignored) {
            return null;
        }
    }

    private static byte[] decodeHex16(String raw) {
        if (raw == null) return null;
        String hex = raw.replace("-", "").trim();
        if (hex.length() != 32) return null;
        byte[] out = new byte[16];
        for (int i = 0; i < 16; i++) {
            int hi = Character.digit(hex.charAt(i * 2), 16);
            int lo = Character.digit(hex.charAt(i * 2 + 1), 16);
            if (hi < 0 || lo < 0) return null;
            out[i] = (byte) ((hi << 4) | lo);
        }
        return out;
    }

    private static String base64UrlNoPad(byte[] data) {
        final String alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
        StringBuilder sb = new StringBuilder((data.length * 4 + 2) / 3);
        int i = 0;
        while (i < data.length) {
            int b0 = data[i++] & 0xFF;
            int b1 = i < data.length ? (data[i++] & 0xFF) : -1;
            int b2 = i < data.length ? (data[i++] & 0xFF) : -1;
            sb.append(alphabet.charAt(b0 >>> 2));
            if (b1 < 0) {
                sb.append(alphabet.charAt((b0 & 0x03) << 4));
            } else {
                sb.append(alphabet.charAt(((b0 & 0x03) << 4) | (b1 >>> 4)));
                if (b2 < 0) {
                    sb.append(alphabet.charAt((b1 & 0x0F) << 2));
                } else {
                    sb.append(alphabet.charAt(((b1 & 0x0F) << 2) | (b2 >>> 6)));
                    sb.append(alphabet.charAt(b2 & 0x3F));
                }
            }
        }
        return sb.toString();
    }

    public static String mimeFromKodiProps(Map<String, String> options) {
        if (options == null || options.isEmpty()) return "";
        String manifest = "";
        for (Map.Entry<String, String> e : options.entrySet()) {
            if (e.getKey() == null || e.getValue() == null) continue;
            if (e.getKey().equalsIgnoreCase("inputstream.adaptive.manifest_type")) {
                manifest = e.getValue().trim().toLowerCase(Locale.ROOT);
                break;
            }
        }
        if (manifest.equals("mpd") || manifest.equals("dash")) return "application/dash+xml";
        if (manifest.equals("hls")) return "application/x-mpegURL";
        if (manifest.equals("ism") || manifest.equals("smooth")) {
            return "application/vnd.ms-sstr+xml";
        }
        return "";
    }

    public static JSONObject buildDrmFromKodiProps(Map<String, String> options) {
        if (options == null || options.isEmpty()) return null;
        String licenseType = "";
        String licenseKey = "";
        for (Map.Entry<String, String> e : options.entrySet()) {
            if (e.getKey() == null || e.getValue() == null) continue;
            String k = e.getKey().trim().toLowerCase(Locale.ROOT);
            if (k.equals("inputstream.adaptive.license_type")) {
                licenseType = e.getValue().trim();
            } else if (k.equals("inputstream.adaptive.license_key")) {
                licenseKey = e.getValue().trim();
            }
        }
        if (licenseType.isEmpty() || licenseKey.isEmpty()) return null;
        try {
            JSONObject drm = new JSONObject();
            String scheme = isClearKeyScheme(licenseType) ? "clearkey" : licenseType;
            drm.put("scheme", scheme);
            if (isClearKeyScheme(licenseType)) {
                String jwk = normalizeClearKeyJwkJson(licenseKey);
                if (jwk != null) {
                    drm.put("clearKeyJson", jwk);
                    return drm;
                }
            }
            // Kodi license_key format: url|Header1=Val1&Header2=Val2|post|resp
            String[] sections = licenseKey.split("\\|");
            String urlPart = sections[0].trim();
            if (urlPart.regionMatches(true, 0, "http://", 0, 7)
                    || urlPart.regionMatches(true, 0, "https://", 0, 8)) {
                drm.put("licenseUrl", urlPart);
                if (sections.length >= 2 && !sections[1].trim().isEmpty()) {
                    JSONObject headers = new JSONObject();
                    for (String kv : sections[1].split("&")) {
                        int eq = kv.indexOf('=');
                        if (eq > 0) {
                            String hk = kv.substring(0, eq).trim();
                            String hv = kv.substring(eq + 1).trim();
                            if (!hk.isEmpty() && !hv.isEmpty()) headers.put(hk, hv);
                        }
                    }
                    if (headers.length() > 0) drm.put("headers", headers);
                }
                return drm;
            }
        } catch (Exception ignored) {
        }
        return null;
    }

    /**
     * Normalizes user-entered {@code udpxy} / {@code rtp2httpd} base address, e.g. {@code
     * udpxy.test:4022} -> {@code http://udpxy.test:4022}. Returns empty string when blank, or
     * throws {@link IllegalArgumentException} when malformed.
     */
    public static String normalizeUdpxyBase(String raw) {
        if (raw == null) return "";
        String t = raw.trim();
        if (t.isEmpty()) return "";
        if (!t.regionMatches(true, 0, "http://", 0, 7)
                && !t.regionMatches(true, 0, "https://", 0, 8)) {
            t = "http://" + t;
        }
        while (t.endsWith("/")) t = t.substring(0, t.length() - 1);
        if (t.toLowerCase(Locale.ROOT).endsWith("/rtp")
                || t.toLowerCase(Locale.ROOT).endsWith("/udp")) {
            t = t.substring(0, t.length() - 4);
        }
        URI uri;
        try {
            uri = URI.create(t);
        } catch (Exception e) {
            throw new IllegalArgumentException("组播代理地址格式无效");
        }
        String scheme = uri.getScheme();
        String host = uri.getHost();
        if (scheme == null
                || (!scheme.equalsIgnoreCase("http") && !scheme.equalsIgnoreCase("https"))
                || host == null
                || host.isEmpty()) {
            throw new IllegalArgumentException("请输入有效的 udpxy 地址（例如 http://…:4022）");
        }
        return t;
    }

    /**
     * Rewrites {@code rtp://[@]239.x.x.x:port} or {@code udp://[@]239.x.x.x:port} to {@code
     * http://<udpxy>/rtp/239.x.x.x:port}. Leaves non-multicast URLs unchanged.
     */
    public static String rewriteMulticastUrl(String rawUrl, String udpxyBase) {
        if (rawUrl == null) return "";
        String trimmed = rawUrl.trim();
        if (!isMulticastUrl(trimmed)) return trimmed;
        String base;
        try {
            base = normalizeUdpxyBase(udpxyBase);
        } catch (Exception e) {
            return trimmed;
        }
        if (base.isEmpty()) return trimmed;
        String proto = trimmed.substring(0, 3).toLowerCase(Locale.ROOT);
        String rest = trimmed.substring(6).trim();
        if (rest.startsWith("@")) rest = rest.substring(1);
        while (rest.startsWith("/")) rest = rest.substring(1);
        if (rest.isEmpty()) return trimmed;
        return base + "/" + proto + "/" + rest;
    }

    public static boolean isIpv6LiteralUrl(String url) {
        if (url == null) return false;
        String t = url.trim();
        int schemeIdx = t.indexOf("://");
        if (schemeIdx < 0) return false;
        String after = t.substring(schemeIdx + 3);
        int at = after.indexOf('@');
        int slash = after.indexOf('/');
        if (at >= 0 && (slash < 0 || at < slash)) {
            after = after.substring(at + 1);
        }
        return after.startsWith("[");
    }

    public static boolean isIpv6Stream(String url, String label) {
        if (isIpv6LiteralUrl(url)) return true;
        String combined =
                ((url == null ? "" : url) + " " + (label == null ? "" : label))
                        .toUpperCase(Locale.ROOT);
        return combined.contains("IPV6") || combined.matches(".*(?<![A-Z0-9])V6(?![A-Z0-9]).*");
    }

    public static boolean hasGlobalIpv6Connectivity() {
        long now = System.currentTimeMillis();
        if (now - ipv6CheckedAtMs < 60000L) return cachedHasIpv6;
        boolean found = false;
        try {
            Enumeration<NetworkInterface> interfaces = NetworkInterface.getNetworkInterfaces();
            while (interfaces != null && interfaces.hasMoreElements() && !found) {
                NetworkInterface nif = interfaces.nextElement();
                if (!nif.isUp() || nif.isLoopback()) continue;
                Enumeration<InetAddress> addrs = nif.getInetAddresses();
                while (addrs.hasMoreElements()) {
                    InetAddress addr = addrs.nextElement();
                    if (addr instanceof Inet6Address
                            && !addr.isLoopbackAddress()
                            && !addr.isLinkLocalAddress()
                            && !addr.isSiteLocalAddress()
                            && !addr.isMulticastAddress()) {
                        byte[] raw = addr.getAddress();
                        // Exclude ULA fc00::/7; require Global Unicast 2000::/3
                        if (raw != null && raw.length == 16 && (raw[0] & 0xE0) == 0x20) {
                            found = true;
                            break;
                        }
                    }
                }
            }
        } catch (Throwable ignored) {
        }
        cachedHasIpv6 = found;
        ipv6CheckedAtMs = now;
        return found;
    }

    public static int scoreStream(
            LiveCatalog.Stream stream,
            String channelHint,
            String udpxyBase,
            boolean hasIpv6,
            Map<String, Metrics> metricsMap,
            boolean preferHighQuality,
            long nowMs) {
        if (stream == null || stream.url == null || stream.url.isEmpty()) return -10000;
        String rawUrl = stream.url.trim();
        boolean rawMulticast = isMulticastUrl(rawUrl);
        String effectiveUrl = rewriteMulticastUrl(rawUrl, udpxyBase);
        if (rawMulticast && isMulticastUrl(effectiveUrl)) {
            // Un-rewritten multicast cannot play directly in HTTP/ExoPlayer without udpxy
            return -5000;
        }
        if (!hasIpv6 && isIpv6LiteralUrl(effectiveUrl)) {
            return -4000;
        }
        int score = 0;
        if (rawMulticast && !isMulticastUrl(effectiveUrl)) {
            // Local LAN udpxy unicast relay: carrier broadcast 1080i50/4K
            score += 2800;
        } else if (isEmbyLiveUrl(rawUrl)) {
            // Self-hosted Emby / Jellyfin Live TV tuner gateway
            score += 2600;
        }
        Metrics m = metricsMap == null ? null : metricsMap.get(metricKey(effectiveUrl));
        if (m != null) {
            if (m.failCount > 0 && nowMs - m.failAt <= FAILURE_COOLDOWN_MS) {
                score -= 1500 * Math.min(3, m.failCount);
            }
            int longEdge = m.maxEdge();
            int shortEdge = m.minEdge();
            if (longEdge >= 3800 || shortEdge >= 2000) score += preferHighQuality ? 3200 : 1200;
            else if (longEdge >= 2500 || shortEdge >= 1400)
                score += preferHighQuality ? 2700 : 1100;
            else if (longEdge >= 1900 || shortEdge >= 1000)
                score += preferHighQuality ? 2400 : 1000;
            else if (longEdge >= 1200 || shortEdge >= 700) score += 900;
            else if (longEdge > 0) score += 200;
            if (m.firstFrameMs > 0 && m.firstFrameMs <= 1500) score += 180;
            else if (m.firstFrameMs > 1500 && m.firstFrameMs <= 3500) score += 80;
        }

        if (preferHighQuality) {
            String combined =
                    ((stream.label == null ? "" : stream.label)
                                    + " "
                                    + (channelHint == null ? "" : channelHint)
                                    + " "
                                    + rawUrl)
                            .toUpperCase(Locale.ROOT);
            boolean measuredLow = m != null && m.maxEdge() > 0 && m.maxEdge() < 1500;
            if (!measuredLow) {
                if (combined.contains("8K")
                        || combined.contains("4K")
                        || combined.contains("UHD")
                        || combined.contains("2160")) {
                    score += 1800;
                } else if (combined.contains("1080")
                        || combined.contains("FHD")
                        || combined.contains("蓝光")
                        || combined.contains("原画")
                        || combined.contains("超清")
                        || combined.contains("HEVC")
                        || combined.contains("50FPS")
                        || combined.contains("60FPS")) {
                    score += 1300;
                } else if (combined.contains("高清")
                        || combined.matches(".*(?<![A-Z])HD(?![A-Z]).*")) {
                    score += 550;
                }
            }
            if (combined.contains("720")
                    || combined.contains("标清")
                    || combined.contains("流畅")
                    || combined.matches(".*(?<![A-Z])SD(?![A-Z]).*")) {
                score -= 300;
            }
            if (hasIpv6 && isIpv6Stream(effectiveUrl, stream.label)) {
                score += 450;
            }
        }
        return score;
    }

    public static List<LiveCatalog.Stream> rankStreams(
            List<LiveCatalog.Stream> streams,
            String channelHint,
            String udpxyBase,
            boolean hasIpv6,
            Map<String, Metrics> metricsMap,
            boolean preferHighQuality) {
        if (streams == null || streams.size() <= 1) {
            return streams == null ? Collections.emptyList() : new ArrayList<>(streams);
        }
        final long nowMs = System.currentTimeMillis();
        final List<IndexedStream> indexed = new ArrayList<>(streams.size());
        for (int i = 0; i < streams.size(); i++) {
            LiveCatalog.Stream s = streams.get(i);
            int sc =
                    scoreStream(
                            s,
                            channelHint,
                            udpxyBase,
                            hasIpv6,
                            metricsMap,
                            preferHighQuality,
                            nowMs);
            indexed.add(new IndexedStream(s, i, sc));
        }
        Collections.sort(
                indexed,
                (a, b) -> {
                    if (b.score != a.score) return Integer.compare(b.score, a.score);
                    return Integer.compare(a.originalIndex, b.originalIndex);
                });
        List<LiveCatalog.Stream> out = new ArrayList<>(indexed.size());
        for (IndexedStream item : indexed) out.add(item.stream);
        return out;
    }

    private static final class IndexedStream {
        final LiveCatalog.Stream stream;
        final int originalIndex;
        final int score;

        IndexedStream(LiveCatalog.Stream stream, int originalIndex, int score) {
            this.stream = stream;
            this.originalIndex = originalIndex;
            this.score = score;
        }
    }

    public static String extractStaticQualityTag(String label, String url) {
        String s =
                ((label == null ? "" : label) + " " + (url == null ? "" : url))
                        .toUpperCase(Locale.ROOT);
        if (s.contains("8K")) return "8K";
        if (s.contains("4K") || s.contains("UHD") || s.contains("2160")) return "4K";
        if (s.contains("1080") || s.contains("FHD") || s.contains("蓝光") || s.contains("原画")) {
            return "1080P";
        }
        if (s.contains("720")) return "720P";
        if (s.contains("超清") || s.contains("高清") || s.matches(".*(?<![A-Z])HD(?![A-Z]).*")) {
            return "HD";
        }
        return "";
    }

    public static String formatStreamDisplayLabel(
            int index,
            LiveCatalog.Stream stream,
            String udpxyBase,
            Map<String, Metrics> metricsMap) {
        StringBuilder sb = new StringBuilder();
        String baseLabel = stream != null && stream.label != null ? stream.label.trim() : "";
        if (baseLabel.isEmpty()) {
            sb.append("线路 ").append(index + 1);
        } else {
            sb.append(baseLabel);
        }
        if (stream == null) return sb.toString();
        String rawUrl = stream.url == null ? "" : stream.url.trim();
        String effectiveUrl = rewriteMulticastUrl(rawUrl, udpxyBase);
        List<String> tags = new ArrayList<>();
        String upperBase = baseLabel.toUpperCase(Locale.ROOT);
        if (isMulticastUrl(rawUrl)) {
            tags.add(isMulticastUrl(effectiveUrl) ? "组播(需udpxy)" : "组播单播");
        } else if (isEmbyLiveUrl(rawUrl)) {
            if (!upperBase.contains("EMBY")) tags.add("Emby直连");
        } else if (isIpv6Stream(effectiveUrl, baseLabel) && !upperBase.contains("IPV6")) {
            tags.add("IPv6");
        }
        if (buildDrmFromKodiProps(stream.options) != null && !upperBase.contains("CLEARKEY")) {
            tags.add("DASH高清");
        }
        Metrics m = metricsMap == null ? null : metricsMap.get(metricKey(effectiveUrl));
        String measured = m == null ? "" : m.resolutionBadge();
        if (!measured.isEmpty()) {
            tags.add(measured);
        } else {
            String qTag = extractStaticQualityTag(baseLabel, rawUrl);
            if (!qTag.isEmpty() && !upperBase.contains(qTag)) {
                tags.add(qTag);
            }
        }
        for (String tag : tags) {
            sb.append(" · ").append(tag);
        }
        return sb.toString();
    }

    /**
     * Merges multiple parsed live catalogs into one deduplicated, quality-ranked catalog.
     */
    public static LiveCatalog.Catalog mergeCatalogs(
            List<NamedCatalog> inputs,
            String udpxyBase,
            boolean hasIpv6,
            Map<String, Metrics> metricsMap,
            boolean preferHighQuality) {
        LiveCatalog.Catalog merged = new LiveCatalog.Catalog();
        merged.origin = MERGED_SOURCE_URL;
        Map<String, LiveCatalog.Group> groupMap = new LinkedHashMap<>();
        for (String preset : new String[] {"央视频道", "卫视频道"}) {
            LiveCatalog.Group g = new LiveCatalog.Group();
            g.name = preset;
            groupMap.put(preset, g);
        }
        Map<String, LiveCatalog.Channel> channelByCanonical = new LinkedHashMap<>();
        Map<String, Set<String>> seenUrlsByCanonical = new LinkedHashMap<>();

        if (inputs != null) {
            for (NamedCatalog named : inputs) {
                if (named == null || named.catalog == null) continue;
                if (!merged.options.containsKey("x-tvg-url")
                        && named.catalog.options.containsKey("x-tvg-url")) {
                    merged.options.put("x-tvg-url", named.catalog.options.get("x-tvg-url"));
                }
                for (LiveCatalog.Group srcGroup : named.catalog.groups) {
                    for (LiveCatalog.Channel srcCh : srcGroup.channels) {
                        if (srcCh.streams.isEmpty()) continue;
                        String canon = canonicalChannelName(srcCh.name);
                        String targetGroupName = standardGroupForChannel(canon, srcGroup.name);
                        LiveCatalog.Channel target = channelByCanonical.get(canon);
                        if (target == null) {
                            target = new LiveCatalog.Channel();
                            target.name = canon;
                            target.id = srcCh.id;
                            target.logo = srcCh.logo;
                            target.options.putAll(srcCh.options);
                            channelByCanonical.put(canon, target);
                            seenUrlsByCanonical.put(canon, new HashSet<>());
                            LiveCatalog.Group grp = groupMap.get(targetGroupName);
                            if (grp == null) {
                                grp = new LiveCatalog.Group();
                                grp.name = targetGroupName;
                                groupMap.put(targetGroupName, grp);
                            }
                            grp.channels.add(target);
                        } else {
                            if (target.logo.isEmpty() && !srcCh.logo.isEmpty()) {
                                target.logo = srcCh.logo;
                            }
                            if (target.id.isEmpty() && !srcCh.id.isEmpty()) {
                                target.id = srcCh.id;
                            }
                            String incomingEpg = srcCh.options.get("epg");
                            if (incomingEpg != null
                                    && !incomingEpg.trim().isEmpty()
                                    && (!target.options.containsKey("epg")
                                            || target.options.get("epg").trim().isEmpty())) {
                                target.options.put("epg", incomingEpg.trim());
                            }
                            for (String optKey :
                                    new String[] {
                                        "tvg-name", "catchup", "catchup-source", "catchup-days"
                                    }) {
                                String incomingVal = srcCh.options.get(optKey);
                                if (incomingVal != null
                                        && !incomingVal.trim().isEmpty()
                                        && (!target.options.containsKey(optKey)
                                                || target.options.get(optKey).trim().isEmpty())) {
                                    target.options.put(optKey, incomingVal.trim());
                                }
                            }
                        }
                        Set<String> seenUrls = seenUrlsByCanonical.get(canon);
                        String rawBadgeHint = extractStaticQualityTag(srcCh.name, "");
                        for (LiveCatalog.Stream s : srcCh.streams) {
                            if (s == null || s.url == null || s.url.trim().isEmpty()) continue;
                            String dedupKey = rewriteMulticastUrl(s.url.trim(), udpxyBase);
                            if (!seenUrls.add(dedupKey)) continue;
                            LiveCatalog.Stream copy = new LiveCatalog.Stream();
                            copy.url = s.url;
                            copy.headers.putAll(s.headers);
                            copy.options.putAll(s.options);
                            StringBuilder lbl = new StringBuilder();
                            if (!named.sourceName.isEmpty()) lbl.append(named.sourceName);
                            if (s.label != null && !s.label.trim().isEmpty()) {
                                if (lbl.length() > 0) lbl.append(" ");
                                lbl.append(s.label.trim());
                            } else if (!rawBadgeHint.isEmpty()) {
                                if (lbl.length() > 0) lbl.append(" ");
                                lbl.append(rawBadgeHint);
                            }
                            copy.label = lbl.toString();
                            target.streams.add(copy);
                        }
                    }
                }
            }
        }

        for (LiveCatalog.Group g : groupMap.values()) {
            if (g.channels.isEmpty()) continue;
            if ("央视频道".equals(g.name)) {
                Collections.sort(
                        g.channels,
                        (a, b) -> Integer.compare(cctvSortOrder(a.name), cctvSortOrder(b.name)));
            }
            for (LiveCatalog.Channel ch : g.channels) {
                List<LiveCatalog.Stream> ranked =
                        rankStreams(
                                ch.streams,
                                ch.name,
                                udpxyBase,
                                hasIpv6,
                                metricsMap,
                                preferHighQuality);
                ch.streams.clear();
                ch.streams.addAll(ranked);
            }
            merged.groups.add(g);
        }
        return merged;
    }

    private static int cctvSortOrder(String name) {
        if (name == null) return 999;
        if ("CCTV-4K".equals(name)) return 18;
        if ("CCTV-8K".equals(name)) return 19;
        if ("CCTV-5+".equals(name)) return 6;
        if ("CCTV-4欧洲".equals(name)) return 41;
        if ("CCTV-4美洲".equals(name)) return 42;
        if (name.startsWith("CCTV-")) {
            try {
                int n = Integer.parseInt(name.substring(5));
                return n <= 5 ? n : n + 1;
            } catch (Exception ignored) {
            }
        }
        if (name.startsWith("CGTN")) return 100;
        return 500;
    }

    /** Ranks streams inside a single catalog in place. */
    public static void rankCatalogInPlace(
            LiveCatalog.Catalog catalog,
            String udpxyBase,
            boolean hasIpv6,
            Map<String, Metrics> metricsMap,
            boolean preferHighQuality) {
        if (catalog == null) return;
        for (LiveCatalog.Group g : catalog.groups) {
            for (LiveCatalog.Channel ch : g.channels) {
                if (ch.streams.size() <= 1) continue;
                List<LiveCatalog.Stream> ranked =
                        rankStreams(
                                ch.streams,
                                ch.name,
                                udpxyBase,
                                hasIpv6,
                                metricsMap,
                                preferHighQuality);
                ch.streams.clear();
                ch.streams.addAll(ranked);
            }
        }
    }

    /** Stable metric cache key preserving channel query identifiers while stripping volatile tokens. */
    public static String metricKey(String rawUrl) {
        if (rawUrl == null || rawUrl.trim().isEmpty()) return "";
        String trimmed = rawUrl.trim();
        String normalized = trimmed;
        try {
            int qIdx = trimmed.indexOf('?');
            if (qIdx > 0) {
                int hashIdx = trimmed.indexOf('#', qIdx);
                String prefix = trimmed.substring(0, qIdx);
                String query =
                        hashIdx > qIdx
                                ? trimmed.substring(qIdx + 1, hashIdx)
                                : trimmed.substring(qIdx + 1);
                List<String> kept = new ArrayList<>();
                for (String part : query.split("&")) {
                    if (part.isEmpty()) continue;
                    int eq = part.indexOf('=');
                    String k = eq > 0 ? part.substring(0, eq) : part;
                    if (!VOLATILE_QUERY_KEY.matcher(k).matches()) {
                        kept.add(part);
                    }
                }
                Collections.sort(kept);
                normalized = kept.isEmpty() ? prefix : prefix + "?" + joinAmp(kept);
            }
        } catch (Exception ignored) {
        }
        try {
            MessageDigest md = MessageDigest.getInstance("SHA-256");
            byte[] digest = md.digest(normalized.getBytes(StandardCharsets.UTF_8));
            StringBuilder hex = new StringBuilder(24);
            for (int i = 0; i < 12; i++) {
                hex.append(String.format(Locale.ROOT, "%02x", digest[i] & 0xFF));
            }
            return hex.toString();
        } catch (Exception e) {
            return Integer.toHexString(normalized.hashCode());
        }
    }

    private static String joinAmp(List<String> items) {
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < items.size(); i++) {
            if (i > 0) sb.append('&');
            sb.append(items.get(i));
        }
        return sb.toString();
    }

    public static Map<String, Metrics> parseMetrics(String rawJson) {
        Map<String, Metrics> out = new LinkedHashMap<>();
        if (rawJson == null || rawJson.trim().isEmpty()) return out;
        try {
            JSONObject root = new JSONObject(rawJson);
            Iterator<String> keys = root.keys();
            while (keys.hasNext()) {
                String k = keys.next();
                JSONObject item = root.optJSONObject(k);
                if (item == null) continue;
                Metrics m = new Metrics();
                m.width = Math.max(0, item.optInt("w", 0));
                m.height = Math.max(0, item.optInt("h", 0));
                m.firstFrameMs = Math.max(0, item.optInt("ms", 0));
                m.okAt = Math.max(0L, item.optLong("ok", 0L));
                m.failCount = Math.max(0, item.optInt("fc", 0));
                m.failAt = Math.max(0L, item.optLong("fa", 0L));
                out.put(k, m);
            }
        } catch (Exception ignored) {
        }
        return out;
    }

    public static String encodeMetrics(Map<String, Metrics> map) {
        JSONObject root = new JSONObject();
        if (map == null || map.isEmpty()) return "{}";
        List<Map.Entry<String, Metrics>> entries = new ArrayList<>(map.entrySet());
        if (entries.size() > MAX_METRICS_ENTRIES) {
            Collections.sort(
                    entries,
                    (a, b) ->
                            Long.compare(
                                    Math.max(b.getValue().okAt, b.getValue().failAt),
                                    Math.max(a.getValue().okAt, a.getValue().failAt)));
            entries = entries.subList(0, MAX_METRICS_ENTRIES);
        }
        for (Map.Entry<String, Metrics> e : entries) {
            Metrics m = e.getValue();
            if (m == null) continue;
            try {
                JSONObject item = new JSONObject();
                if (m.width > 0) item.put("w", m.width);
                if (m.height > 0) item.put("h", m.height);
                if (m.firstFrameMs > 0) item.put("ms", m.firstFrameMs);
                if (m.okAt > 0) item.put("ok", m.okAt);
                if (m.failCount > 0) item.put("fc", m.failCount);
                if (m.failAt > 0) item.put("fa", m.failAt);
                root.put(e.getKey(), item);
            } catch (Exception ignored) {
            }
        }
        return root.toString();
    }

    public static String recordStreamSuccess(
            String existingJson, String url, int width, int height, int firstFrameMs, long nowMs) {
        String key = metricKey(url);
        if (key.isEmpty()) return existingJson == null ? "{}" : existingJson;
        Map<String, Metrics> map = parseMetrics(existingJson);
        Metrics m = map.get(key);
        if (m == null) m = new Metrics();
        if (width > 0) m.width = width;
        if (height > 0) m.height = height;
        if (firstFrameMs > 0) m.firstFrameMs = firstFrameMs;
        m.okAt = nowMs;
        m.failCount = 0;
        m.failAt = 0L;
        map.put(key, m);
        return encodeMetrics(map);
    }

    public static String recordStreamFailure(String existingJson, String url, long nowMs) {
        String key = metricKey(url);
        if (key.isEmpty()) return existingJson == null ? "{}" : existingJson;
        Map<String, Metrics> map = parseMetrics(existingJson);
        Metrics m = map.get(key);
        if (m == null) m = new Metrics();
        m.failCount = Math.min(10, m.failCount + 1);
        m.failAt = nowMs;
        map.put(key, m);
        return encodeMetrics(map);
    }

    public static List<CustomLiveSource> parseCustomSources(
            String sourcesJson, String legacyUrl, String legacyName) {
        List<CustomLiveSource> out = new ArrayList<>();
        Set<String> seenUrls = new HashSet<>();
        if (sourcesJson != null && !sourcesJson.trim().isEmpty()) {
            try {
                JSONArray arr = new JSONArray(sourcesJson);
                for (int i = 0; i < arr.length(); i++) {
                    JSONObject item = arr.optJSONObject(i);
                    if (item == null) continue;
                    String u = item.optString("url", "").trim();
                    String n = item.optString("name", "自定义直播 " + (i + 1)).trim();
                    if (!u.isEmpty() && seenUrls.add(u)) {
                        out.add(new CustomLiveSource(n.isEmpty() ? "自定义直播源" : n, u));
                    }
                }
            } catch (Exception ignored) {
            }
        }
        String legU = legacyUrl == null ? "" : legacyUrl.trim();
        if (!legU.isEmpty() && seenUrls.add(legU)) {
            String legN = legacyName == null ? "" : legacyName.trim();
            out.add(0, new CustomLiveSource(legN.isEmpty() ? "自定义直播源" : legN, legU));
        }
        return out;
    }

    public static String encodeCustomSources(List<CustomLiveSource> sources) {
        JSONArray arr = new JSONArray();
        if (sources != null) {
            Set<String> seen = new HashSet<>();
            for (CustomLiveSource s : sources) {
                if (s == null || s.url.isEmpty() || !seen.add(s.url)) continue;
                try {
                    arr.put(
                            new JSONObject()
                                    .put("name", s.name.isEmpty() ? "自定义直播源" : s.name)
                                    .put("url", s.url));
                } catch (Exception ignored) {
                }
            }
        }
        return arr.toString();
    }
}
