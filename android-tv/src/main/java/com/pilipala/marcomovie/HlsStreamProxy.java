package com.pilipala.marcomovie;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.io.SequenceInputStream;
import java.net.HttpURLConnection;
import java.net.URI;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Loopback HLS proxy with real-time 64 KiB MPEG-TS sync detection (strips fake PNG/GIF/JPEG
 * disguise headers without full-segment buffering), nested playlist/key URI rewriting, and opt-in
 * heuristic discontinuity ad-block stripping.
 */
public final class HlsStreamProxy {
    static final int PROBE_LIMIT = 64 * 1024;
    static final int TS_PACKET_SIZE = 188;
    private static final int MAX_SESSIONS = 64;
    private static final Pattern URI_ATTR = Pattern.compile("URI=\"([^\"]+)\"");
    private static final Pattern EXTINF_DURATION =
            Pattern.compile("^#EXTINF:([0-9]+(?:\\.[0-9]+)?)");

    static final class Session {
        final String id;
        final Map<String, String> headers;
        final boolean stripAds;
        final ConcurrentHashMap<Integer, String> idToUrl = new ConcurrentHashMap<>();
        final ConcurrentHashMap<String, Integer> urlToId = new ConcurrentHashMap<>();
        final AtomicInteger nextId = new AtomicInteger(0);

        Session(String id, Map<String, String> headers, boolean stripAds) {
            this.id = id;
            this.headers =
                    headers == null
                            ? Collections.emptyMap()
                            : Collections.unmodifiableMap(new LinkedHashMap<>(headers));
            this.stripAds = stripAds;
        }

        int registerUrl(String url) {
            Integer existing = urlToId.get(url);
            if (existing != null) return existing;
            int assigned = nextId.getAndIncrement();
            Integer raced = urlToId.putIfAbsent(url, assigned);
            if (raced != null) return raced;
            idToUrl.put(assigned, url);
            return assigned;
        }

        String resolveId(int index) {
            return idToUrl.get(index);
        }
    }

    private static final Map<String, Session> SESSIONS =
            Collections.synchronizedMap(
                    new LinkedHashMap<String, Session>(32, 0.75f, true) {
                        @Override
                        protected boolean removeEldestEntry(Map.Entry<String, Session> eldest) {
                            return size() > MAX_SESSIONS;
                        }
                    });

    private HlsStreamProxy() {}

    public static boolean looksLikeHls(String url, String declaredMime) {
        if (declaredMime != null && declaredMime.toLowerCase(Locale.ROOT).contains("mpegurl")) {
            return true;
        }
        if (url == null || !Cms.isHttp(url)) return false;
        String lower = url.toLowerCase(Locale.ROOT);
        if (ProxyAddress.isLoopbackHost(safeHost(url))
                && (lower.contains("/hls?") || lower.contains("/seg?"))) {
            return false;
        }
        String path = lower.split("[?#]", 2)[0];
        return path.endsWith(".m3u8")
                || path.endsWith(".m3u")
                || lower.contains(".m3u8?")
                || lower.contains(".m3u8&");
    }

    private static String safeHost(String url) {
        try {
            return new URI(url).getHost();
        } catch (Exception ignored) {
            return "";
        }
    }

    public static String register(
            String playlistUrl, Map<String, String> headers, boolean stripAds) {
        LocalProxy.hlsRouteHandler = HlsStreamProxy::handle;
        String sid = UUID.randomUUID().toString().replace("-", "").substring(0, 16);
        Session session = new Session(sid, headers, stripAds);
        int rootId = session.registerUrl(playlistUrl);
        SESSIONS.put(sid, session);
        return buildLocalUrl("/hls", sid, rootId, false);
    }

    static String buildLocalUrl(String route, String sid, int targetId, boolean raw) {
        StringBuilder sb =
                new StringBuilder(ProxyAddress.base())
                        .append(route)
                        .append("?sid=")
                        .append(sid)
                        .append("&t=")
                        .append(targetId);
        if (raw) sb.append("&raw=1");
        String tok = ProxyAddress.token;
        if (tok != null && !tok.isEmpty()) {
            sb.append("&_mm_token=").append(tok);
        }
        return sb.toString();
    }

    /**
     * Locates the first MPEG-TS sync byte ({@code 0x47}) aligned on a 188-byte packet stride.
     * Returns {@code 0} if the buffer already begins with TS packets or if no valid TS sync stride
     * is present (e.g., fMP4 / AAC / WebVTT segments).
     */
    public static int findTsSyncOffset(byte[] buf, int length) {
        if (buf == null || length <= 0) return 0;
        int limit = Math.min(buf.length, Math.min(length, PROBE_LIMIT));
        if (limit >= TS_PACKET_SIZE * 2 + 1) {
            int maxStart = limit - TS_PACKET_SIZE * 2 - 1;
            for (int i = 0; i <= maxStart; i++) {
                if ((buf[i] & 0xFF) == 0x47
                        && (buf[i + TS_PACKET_SIZE] & 0xFF) == 0x47
                        && (buf[i + TS_PACKET_SIZE * 2] & 0xFF) == 0x47) {
                    return i;
                }
            }
        }
        if (limit >= TS_PACKET_SIZE + 1) {
            int maxStart = limit - TS_PACKET_SIZE - 1;
            for (int i = 0; i <= maxStart; i++) {
                if ((buf[i] & 0xFF) == 0x47 && (buf[i + TS_PACKET_SIZE] & 0xFF) == 0x47) {
                    return i;
                }
            }
        }
        return 0;
    }

    static String resolveUrl(String baseUrl, String relative) {
        if (relative == null) return "";
        String trimmed = relative.trim();
        if (trimmed.isEmpty()) return "";
        if (trimmed.startsWith("http://") || trimmed.startsWith("https://")) return trimmed;
        try {
            return new URL(new URL(baseUrl), trimmed).toString();
        } catch (Exception ignored) {
            return trimmed;
        }
    }

    interface LinkRewriter {
        String rewrite(String resolvedUrl, boolean playlist, boolean raw);
    }

    static String rewritePlaylist(
            String content, String baseUrl, boolean stripAds, LinkRewriter rewriter) {
        if (content == null) return "";
        String[] rawLines = content.replace("\r\n", "\n").replace('\r', '\n').split("\n", -1);
        List<String> lines = new ArrayList<>(rawLines.length);
        Collections.addAll(lines, rawLines);
        if (stripAds) {
            lines = stripDiscontinuityAds(lines, baseUrl);
        }
        StringBuilder out = new StringBuilder(content.length() + 512);
        boolean nextIsVariantPlaylist = false;
        for (int i = 0; i < lines.size(); i++) {
            String line = lines.get(i);
            String trimmed = line.trim();
            if (i > 0) out.append('\n');
            if (trimmed.isEmpty()) {
                out.append(line);
                continue;
            }
            if (trimmed.startsWith("#")) {
                if (trimmed.startsWith("#EXT-X-STREAM-INF")) {
                    nextIsVariantPlaylist = true;
                }
                if (trimmed.contains("URI=\"")) {
                    boolean isMediaPlaylistTag =
                            trimmed.startsWith("#EXT-X-MEDIA")
                                    || trimmed.startsWith("#EXT-X-I-FRAME-STREAM-INF");
                    Matcher m = URI_ATTR.matcher(line);
                    StringBuffer sb = new StringBuffer();
                    while (m.find()) {
                        String resolved = resolveUrl(baseUrl, m.group(1));
                        boolean isPlaylist =
                                isMediaPlaylistTag
                                        && resolved.toLowerCase(Locale.ROOT).contains(".m3u");
                        String replacement =
                                Cms.isHttp(resolved)
                                        ? rewriter.rewrite(resolved, isPlaylist, !isPlaylist)
                                        : m.group(1);
                        m.appendReplacement(
                                sb, Matcher.quoteReplacement("URI=\"" + replacement + "\""));
                    }
                    m.appendTail(sb);
                    out.append(sb);
                } else {
                    out.append(line);
                }
            } else {
                String resolved = resolveUrl(baseUrl, trimmed);
                if (Cms.isHttp(resolved)) {
                    boolean isPlaylist =
                            nextIsVariantPlaylist
                                    || resolved.split("[?#]", 2)[0]
                                            .toLowerCase(Locale.ROOT)
                                            .endsWith(".m3u8");
                    out.append(rewriter.rewrite(resolved, isPlaylist, false));
                } else {
                    out.append(line);
                }
                nextIsVariantPlaylist = false;
            }
        }
        return out.toString();
    }

    private static final class SegmentBlock {
        final List<String> lines = new ArrayList<>();
        int segmentCount;
        double durationSec;
        boolean adUrlHint;
        String hostPathPrefix = "";
    }

    /**
     * Conservative VOD discontinuity ad-block filter. Only removes bounded short blocks (<= 60s,
     * <= 20 segments) separated by {@code #EXT-X-DISCONTINUITY} whose host/directory prefix differs
     * from the dominant feature-film blocks or whose segment URLs match explicit ad markers. Never
     * removes more than 40% of total playlist duration.
     */
    static List<String> stripDiscontinuityAds(List<String> lines, String baseUrl) {
        boolean isVod = false;
        boolean hasDiscontinuity = false;
        for (String line : lines) {
            String t = line.trim();
            if ("#EXT-X-ENDLIST".equals(t) || "#EXT-X-PLAYLIST-TYPE:VOD".equals(t)) {
                isVod = true;
            } else if ("#EXT-X-DISCONTINUITY".equals(t)) {
                hasDiscontinuity = true;
            }
        }
        if (!isVod || !hasDiscontinuity) return lines;

        List<String> header = new ArrayList<>();
        List<String> footer = new ArrayList<>();
        List<SegmentBlock> blocks = new ArrayList<>();
        SegmentBlock current = null;
        boolean inFooter = false;
        double pendingDuration = 0.0;

        for (String line : lines) {
            String t = line.trim();
            if ("#EXT-X-ENDLIST".equals(t)) {
                inFooter = true;
                footer.add(line);
                continue;
            }
            if (inFooter) {
                footer.add(line);
                continue;
            }
            if ("#EXT-X-DISCONTINUITY".equals(t)) {
                current = new SegmentBlock();
                blocks.add(current);
                pendingDuration = 0.0;
                continue;
            }
            boolean isSegmentMeta =
                    t.startsWith("#EXTINF:")
                            || t.startsWith("#EXT-X-BYTERANGE:")
                            || t.startsWith("#EXT-X-PROGRAM-DATE-TIME:");
            if (current == null && (isSegmentMeta || (!t.isEmpty() && !t.startsWith("#")))) {
                current = new SegmentBlock();
                blocks.add(current);
            }
            if (current == null) {
                header.add(line);
                continue;
            }
            current.lines.add(line);
            if (t.startsWith("#EXTINF:")) {
                Matcher m = EXTINF_DURATION.matcher(t);
                if (m.find()) {
                    try {
                        pendingDuration = Double.parseDouble(m.group(1));
                    } catch (NumberFormatException ignored) {
                        pendingDuration = 0.0;
                    }
                }
            } else if (!t.isEmpty() && !t.startsWith("#")) {
                current.segmentCount++;
                current.durationSec += pendingDuration;
                pendingDuration = 0.0;
                String resolved = resolveUrl(baseUrl, t);
                if (current.hostPathPrefix.isEmpty()) {
                    current.hostPathPrefix = urlPrefixSignature(resolved);
                }
                String lower = resolved.toLowerCase(Locale.ROOT);
                if (lower.contains("/ad/")
                        || lower.contains("/ads/")
                        || lower.contains("adjump")
                        || lower.contains("advert")
                        || lower.contains("_ad_")
                        || lower.contains("-ad-")) {
                    current.adUrlHint = true;
                }
            }
        }
        if (blocks.size() < 2) return lines;

        Map<String, Double> prefixDurations = new LinkedHashMap<>();
        double totalDuration = 0.0;
        for (SegmentBlock b : blocks) {
            totalDuration += b.durationSec;
            if (!b.hostPathPrefix.isEmpty()) {
                Double prev = prefixDurations.get(b.hostPathPrefix);
                prefixDurations.put(b.hostPathPrefix, (prev == null ? 0.0 : prev) + b.durationSec);
            }
        }
        if (totalDuration <= 0.0) return lines;

        String dominantPrefix = "";
        double dominantDuration = -1.0;
        for (Map.Entry<String, Double> entry : prefixDurations.entrySet()) {
            if (entry.getValue() > dominantDuration) {
                dominantDuration = entry.getValue();
                dominantPrefix = entry.getKey();
            }
        }

        List<SegmentBlock> kept = new ArrayList<>();
        double removedDuration = 0.0;
        for (int i = 0; i < blocks.size(); i++) {
            SegmentBlock b = blocks.get(i);
            boolean shortBlock =
                    b.segmentCount > 0 && b.segmentCount <= 20 && b.durationSec <= 60.0;
            boolean foreignPrefix =
                    !dominantPrefix.isEmpty()
                            && !b.hostPathPrefix.isEmpty()
                            && !dominantPrefix.equals(b.hostPathPrefix);
            boolean likelyAd = shortBlock && (b.adUrlHint || (i > 0 && foreignPrefix));
            if (likelyAd) {
                removedDuration += b.durationSec;
            } else {
                kept.add(b);
            }
        }
        if (kept.isEmpty() || removedDuration <= 0.0 || removedDuration > totalDuration * 0.40) {
            return lines;
        }
        List<String> rebuilt = new ArrayList<>(lines.size());
        rebuilt.addAll(header);
        for (int i = 0; i < kept.size(); i++) {
            if (i > 0) rebuilt.add("#EXT-X-DISCONTINUITY");
            rebuilt.addAll(kept.get(i).lines);
        }
        rebuilt.addAll(footer);
        return rebuilt;
    }

    private static String urlPrefixSignature(String url) {
        try {
            URI u = new URI(url);
            String host = u.getHost() == null ? "" : u.getHost().toLowerCase(Locale.ROOT);
            String path = u.getPath() == null ? "/" : u.getPath();
            int slash = path.lastIndexOf('/');
            String dir = slash > 0 ? path.substring(0, slash) : "/";
            return host + dir;
        } catch (Exception ignored) {
            return "";
        }
    }

    static boolean handle(
            String path,
            String method,
            Map<String, String> queryParams,
            Map<String, String> requestHeaders,
            OutputStream out)
            throws IOException {
        String sid = queryParams.get("sid");
        String targetStr = queryParams.get("t");
        if (sid == null || targetStr == null) {
            LocalProxy.simple(out, 400, "Missing HLS session parameters");
            return false;
        }
        Session session = SESSIONS.get(sid);
        if (session == null) {
            LocalProxy.simple(out, 404, "HLS session expired");
            return false;
        }
        int targetId;
        try {
            targetId = Integer.parseInt(targetStr);
        } catch (NumberFormatException invalid) {
            LocalProxy.simple(out, 400, "Invalid HLS target");
            return false;
        }
        String targetUrl = session.resolveId(targetId);
        if (targetUrl == null || !Cms.isHttp(targetUrl)) {
            LocalProxy.simple(out, 404, "HLS target not found");
            return false;
        }
        if ("/hls".equals(path)) {
            return servePlaylist(session, targetUrl, method, out);
        }
        boolean raw = "1".equals(queryParams.get("raw"));
        return serveSegment(session, targetUrl, method, raw, requestHeaders, out);
    }

    private static boolean servePlaylist(
            Session session, String targetUrl, String method, OutputStream out) throws IOException {
        HttpURLConnection conn = openUpstream(targetUrl, session.headers, null);
        try {
            int code = conn.getResponseCode();
            String finalUrl = conn.getURL() != null ? conn.getURL().toString() : targetUrl;
            if (code >= 400) {
                LocalProxy.simple(out, code, "Upstream playlist HTTP " + code);
                return false;
            }
            byte[] rawBytes = readAllBounded(conn.getInputStream(), 8 * 1024 * 1024);
            String text = new String(rawBytes, StandardCharsets.UTF_8);
            String rewritten =
                    rewritePlaylist(
                            text,
                            finalUrl,
                            session.stripAds,
                            (resolved, isPlaylist, isRaw) -> {
                                int id = session.registerUrl(resolved);
                                return buildLocalUrl(
                                        isPlaylist ? "/hls" : "/seg", session.id, id, isRaw);
                            });
            byte[] payload = rewritten.getBytes(StandardCharsets.UTF_8);
            String headers =
                    "HTTP/1.1 200 OK\r\n"
                            + "Content-Type: application/vnd.apple.mpegurl; charset=utf-8\r\n"
                            + "Cache-Control: no-store\r\n"
                            + "Connection: close\r\n"
                            + "Content-Length: "
                            + payload.length
                            + "\r\n\r\n";
            out.write(headers.getBytes(StandardCharsets.ISO_8859_1));
            if (!"HEAD".equals(method)) {
                out.write(payload);
            }
            out.flush();
            return false;
        } finally {
            RequestScope.detach(conn);
            conn.disconnect();
        }
    }

    private static boolean serveSegment(
            Session session,
            String targetUrl,
            String method,
            boolean raw,
            Map<String, String> requestHeaders,
            OutputStream out)
            throws IOException {
        String range = requestHeaders != null ? requestHeaders.get("range") : null;
        HttpURLConnection conn = openUpstream(targetUrl, session.headers, range);
        try {
            int code = conn.getResponseCode();
            if (code >= 400) {
                LocalProxy.simple(out, code, "Upstream segment HTTP " + code);
                return false;
            }
            String contentType = conn.getContentType();
            long upstreamLength = parseContentLength(conn);
            String contentRange = conn.getHeaderField("Content-Range");
            if ("HEAD".equals(method)) {
                StringBuilder head =
                        new StringBuilder("HTTP/1.1 ")
                                .append(code)
                                .append(code == 206 ? " Partial Content" : " OK")
                                .append("\r\nConnection: close\r\nContent-Type: ")
                                .append(
                                        contentType != null && LocalProxy.safe(contentType)
                                                ? contentType
                                                : "video/mp2t")
                                .append("\r\n");
                if (upstreamLength >= 0) {
                    head.append("Content-Length: ").append(upstreamLength).append("\r\n");
                }
                head.append("\r\n");
                out.write(head.toString().getBytes(StandardCharsets.ISO_8859_1));
                out.flush();
                return false;
            }

            String lowerPath = targetUrl.split("[?#]", 2)[0].toLowerCase(Locale.ROOT);
            boolean skipProbe =
                    raw
                            || range != null
                            || lowerPath.endsWith(".m4s")
                            || lowerPath.endsWith(".mp4")
                            || lowerPath.endsWith(".key")
                            || lowerPath.endsWith(".vtt");

            try (InputStream upstream = conn.getInputStream()) {
                InputStream bodyStream = upstream;
                int strippedOffset = 0;
                if (!skipProbe) {
                    byte[] probe = new byte[PROBE_LIMIT];
                    int filled = readFullyUpTo(upstream, probe, probe.length);
                    strippedOffset = findTsSyncOffset(probe, filled);
                    ByteArrayInputStream prefixStream =
                            new ByteArrayInputStream(
                                    probe, strippedOffset, Math.max(0, filled - strippedOffset));
                    bodyStream = new SequenceInputStream(prefixStream, upstream);
                }

                String responseMime =
                        strippedOffset > 0
                                ? "video/mp2t"
                                : (contentType != null && LocalProxy.safe(contentType)
                                        ? contentType
                                        : "video/mp2t");
                long finalLength =
                        upstreamLength >= 0 ? Math.max(0L, upstreamLength - strippedOffset) : -1L;
                StringBuilder head =
                        new StringBuilder("HTTP/1.1 ")
                                .append(code)
                                .append(code == 206 ? " Partial Content" : " OK")
                                .append("\r\nConnection: close\r\nContent-Type: ")
                                .append(responseMime)
                                .append("\r\n");
                if (contentRange != null && strippedOffset == 0 && LocalProxy.safe(contentRange)) {
                    head.append("Content-Range: ").append(contentRange).append("\r\n");
                }
                if (finalLength >= 0) {
                    head.append("Content-Length: ").append(finalLength).append("\r\n\r\n");
                } else {
                    head.append("Transfer-Encoding: chunked\r\n\r\n");
                }
                out.write(head.toString().getBytes(StandardCharsets.ISO_8859_1));

                byte[] buf = new byte[64 * 1024];
                int n;
                if (finalLength >= 0) {
                    long remaining = finalLength;
                    while (remaining > 0
                            && (n = bodyStream.read(buf, 0, (int) Math.min(buf.length, remaining)))
                                    != -1) {
                        if (n > 0) {
                            out.write(buf, 0, n);
                            remaining -= n;
                        }
                    }
                } else {
                    while ((n = bodyStream.read(buf)) != -1) {
                        if (n == 0) continue;
                        out.write(
                                (Integer.toHexString(n) + "\r\n")
                                        .getBytes(StandardCharsets.US_ASCII));
                        out.write(buf, 0, n);
                        out.write(new byte[] {13, 10});
                    }
                    out.write("0\r\n\r\n".getBytes(StandardCharsets.US_ASCII));
                }
                out.flush();
                return false;
            }
        } finally {
            RequestScope.detach(conn);
            conn.disconnect();
        }
    }

    private static long parseContentLength(HttpURLConnection conn) {
        String header = conn.getHeaderField("Content-Length");
        if (header != null) {
            try {
                return Long.parseLong(header.trim());
            } catch (NumberFormatException ignored) {
            }
        }
        int legacy = conn.getContentLength();
        return legacy >= 0 ? legacy : -1L;
    }

    private static HttpURLConnection openUpstream(
            String url, Map<String, String> headers, String range) throws IOException {
        HttpURLConnection conn = (HttpURLConnection) new URL(url).openConnection();
        RequestScope.attach(conn);
        conn.setConnectTimeout(15000);
        conn.setReadTimeout(25000);
        conn.setInstanceFollowRedirects(true);
        boolean hasUa = false;
        for (Map.Entry<String, String> entry : headers.entrySet()) {
            String k = entry.getKey();
            String v = entry.getValue();
            if (k == null || v == null || k.equalsIgnoreCase("Host")) continue;
            if (k.equalsIgnoreCase("User-Agent")) hasUa = true;
            conn.setRequestProperty(k, v);
        }
        if (!hasUa) {
            conn.setRequestProperty("User-Agent", "MarcoMovie/0.2.0");
        }
        if (range != null && !range.isEmpty()) {
            conn.setRequestProperty("Range", range);
        }
        return conn;
    }

    private static int readFullyUpTo(InputStream in, byte[] dst, int maxBytes) throws IOException {
        int total = 0;
        while (total < maxBytes) {
            int n = in.read(dst, total, maxBytes - total);
            if (n < 0) break;
            total += n;
        }
        return total;
    }

    private static byte[] readAllBounded(InputStream in, int maxBytes) throws IOException {
        ByteArrayOutputStream out = new ByteArrayOutputStream(8192);
        byte[] buf = new byte[8192];
        int n;
        int total = 0;
        while ((n = in.read(buf)) != -1) {
            total += n;
            if (total > maxBytes) throw new IOException("HLS playlist too large");
            out.write(buf, 0, n);
        }
        return out.toByteArray();
    }
}
