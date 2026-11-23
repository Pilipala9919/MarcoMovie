package com.pilipala.marcomovie;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URI;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.UUID;
import org.json.JSONObject;

/**
 * Persistent 256 KiB block-aligned HTTP Range disk cache for direct VOD streams.
 *
 * <p>Stores blocks on disk under {@code <cacheDir>/media-cache/<sha256>/b_<index>.bin} with
 * bounded LRU eviction, full HTTP 206 Range serving, and automatic 416 non-Range fallback for
 * upstream servers that reject partial requests.
 */
public final class MediaDiskCache {
    public static final int BLOCK_SIZE = 256 * 1024;
    private static final int MAX_SESSIONS = 64;
    private static volatile MediaDiskCache shared;

    static final class Session {
        final String id;
        final String url;
        final Map<String, String> headers;
        final String cacheKey;

        Session(String id, String url, Map<String, String> headers, String cacheKey) {
            this.id = id;
            this.url = url;
            this.headers =
                    headers == null
                            ? Collections.emptyMap()
                            : Collections.unmodifiableMap(new LinkedHashMap<>(headers));
            this.cacheKey = cacheKey;
        }
    }

    static final class Meta {
        long contentLength = -1L;
        String contentType = "application/octet-stream";
        boolean rangeSupported = true;
    }

    private final File rootDir;
    private volatile long maxBytes;
    private final Map<String, Session> sessions =
            Collections.synchronizedMap(
                    new LinkedHashMap<String, Session>(32, 0.75f, true) {
                        @Override
                        protected boolean removeEldestEntry(Map.Entry<String, Session> eldest) {
                            return size() > MAX_SESSIONS;
                        }
                    });

    public MediaDiskCache(File rootDir, long maxBytes) {
        this.rootDir = rootDir;
        this.maxBytes = Math.max(0L, maxBytes);
        if (this.rootDir != null && !this.rootDir.exists()) {
            this.rootDir.mkdirs();
        }
    }

    public static MediaDiskCache getInstance(File cacheDir, int maxMb) {
        long cap = Math.max(0L, (long) maxMb) * 1024L * 1024L;
        MediaDiskCache existing = shared;
        if (existing != null) {
            existing.setMaxBytes(cap);
            return existing;
        }
        synchronized (MediaDiskCache.class) {
            if (shared == null) {
                shared = new MediaDiskCache(new File(cacheDir, "media-cache"), cap);
            } else {
                shared.setMaxBytes(cap);
            }
            return shared;
        }
    }

    static MediaDiskCache currentInstance() {
        return shared;
    }

    public void setMaxBytes(long bytes) {
        this.maxBytes = Math.max(0L, bytes);
    }

    public long getMaxBytes() {
        return maxBytes;
    }

    public static boolean isCacheableDirectUrl(String url, String declaredMime) {
        if (url == null || !Cms.isHttp(url)) return false;
        if (HlsStreamProxy.looksLikeHls(url, declaredMime)) return false;
        if (declaredMime != null && declaredMime.toLowerCase(Locale.ROOT).contains("dash")) {
            return false;
        }
        try {
            URI u = new URI(url);
            if (ProxyAddress.isLoopbackHost(u.getHost())) return false;
        } catch (Exception ignored) {
            return false;
        }
        String lower = url.split("[?#]", 2)[0].toLowerCase(Locale.ROOT);
        if (lower.endsWith(".mpd") || lower.endsWith(".m3u8") || lower.endsWith(".m3u")) {
            return false;
        }
        return true;
    }

    public String register(String url, Map<String, String> headers) {
        LocalProxy.diskCacheRouteHandler =
                (path, method, queryParams, reqHeaders, out) ->
                        MediaDiskCache.handleRoute(path, method, reqHeaders, out);
        String sid = UUID.randomUUID().toString().replace("-", "").substring(0, 16);
        String key = sha256(url);
        Session session = new Session(sid, url, headers, key);
        sessions.put(sid, session);
        String tok = ProxyAddress.token;
        StringBuilder sb = new StringBuilder(ProxyAddress.base()).append("/kcache/").append(sid);
        if (tok != null && !tok.isEmpty()) {
            sb.append("?_mm_token=").append(tok);
        }
        return sb.toString();
    }

    Session getSession(String sid) {
        return sid == null ? null : sessions.get(sid);
    }

    static boolean handleRoute(
            String path, String method, Map<String, String> requestHeaders, OutputStream out)
            throws IOException {
        MediaDiskCache cache = currentInstance();
        if (cache == null) {
            LocalProxy.simple(out, 404, "Disk cache unavailable");
            return false;
        }
        return cache.handle(path, method, requestHeaders, out);
    }

    boolean handle(String path, String method, Map<String, String> requestHeaders, OutputStream out)
            throws IOException {
        if (path == null || !path.startsWith("/kcache/")) {
            LocalProxy.simple(out, 404, "Not found");
            return false;
        }
        String sid = path.substring("/kcache/".length());
        int slash = sid.indexOf('/');
        if (slash >= 0) sid = sid.substring(0, slash);
        Session session = getSession(sid);
        if (session == null) {
            LocalProxy.simple(out, 404, "Cache session expired");
            return false;
        }
        String rangeHeader = requestHeaders != null ? requestHeaders.get("range") : null;
        return serveSession(session, method, rangeHeader, out);
    }

    boolean serveSession(Session session, String method, String rangeHeader, OutputStream out)
            throws IOException {
        File entryDir = new File(rootDir, session.cacheKey);
        if (!entryDir.exists()) entryDir.mkdirs();

        Meta meta = loadMeta(entryDir);
        if (meta == null) {
            meta = probeUpstream(session, entryDir);
        }
        touchMeta(entryDir);

        if (meta == null || meta.contentLength <= 0 || !meta.rangeSupported) {
            return passthroughStream(session, method, rangeHeader, out);
        }

        long total = meta.contentLength;
        long start = 0L;
        long end = total - 1L;
        boolean isPartial = false;
        if (rangeHeader != null && !rangeHeader.trim().isEmpty()) {
            long[] parsed = parseRangeHeader(rangeHeader, total);
            if (parsed == null) {
                String resp =
                        "HTTP/1.1 416 Range Not Satisfiable\r\n"
                                + "Content-Range: bytes */"
                                + total
                                + "\r\nConnection: close\r\nContent-Length: 0\r\n\r\n";
                out.write(resp.getBytes(StandardCharsets.ISO_8859_1));
                out.flush();
                return false;
            }
            start = parsed[0];
            end = parsed[1];
            isPartial = true;
        }

        long length = (end - start) + 1L;
        StringBuilder head =
                new StringBuilder("HTTP/1.1 ")
                        .append(isPartial ? "206 Partial Content" : "200 OK")
                        .append("\r\nConnection: close\r\nAccept-Ranges: bytes\r\nContent-Type: ")
                        .append(
                                LocalProxy.safe(meta.contentType)
                                        ? meta.contentType
                                        : "application/octet-stream")
                        .append("\r\nContent-Length: ")
                        .append(length)
                        .append("\r\n");
        if (isPartial) {
            head.append("Content-Range: bytes ")
                    .append(start)
                    .append('-')
                    .append(end)
                    .append('/')
                    .append(total)
                    .append("\r\n");
        }
        head.append("\r\n");
        out.write(head.toString().getBytes(StandardCharsets.ISO_8859_1));
        if ("HEAD".equals(method)) {
            out.flush();
            return false;
        }

        long pos = start;
        while (pos <= end) {
            long blockIndex = pos / BLOCK_SIZE;
            int offsetInBlock = (int) (pos % BLOCK_SIZE);
            byte[] block = getOrFetchBlock(session, entryDir, meta, blockIndex);
            if (block == null || offsetInBlock >= block.length) {
                break;
            }
            int available = block.length - offsetInBlock;
            int toWrite = (int) Math.min((long) available, (end - pos) + 1L);
            out.write(block, offsetInBlock, toWrite);
            pos += toWrite;
        }
        out.flush();
        trimIfNeeded();
        return false;
    }

    byte[] getOrFetchBlock(Session session, File entryDir, Meta meta, long blockIndex)
            throws IOException {
        File blockFile = new File(entryDir, "b_" + blockIndex + ".bin");
        if (blockFile.isFile() && blockFile.length() > 0) {
            return readFile(blockFile);
        }
        long blockStart = blockIndex * (long) BLOCK_SIZE;
        long blockEnd = Math.min(meta.contentLength - 1L, blockStart + BLOCK_SIZE - 1L);
        if (blockStart > blockEnd) return new byte[0];

        HttpURLConnection conn =
                openUpstream(session.url, session.headers, "bytes=" + blockStart + "-" + blockEnd);
        try {
            int code = conn.getResponseCode();
            if (code == 416) {
                // Retry once without Range for servers that reject bounded partial fetches.
                RequestScope.detach(conn);
                conn.disconnect();
                return fetchBlockWithoutRange(session, blockStart, blockEnd);
            }
            if (code != 206 && code != 200) {
                throw new IOException("Upstream block HTTP " + code);
            }
            byte[] data;
            if (code == 206) {
                data = readExactUpTo(conn.getInputStream(), (int) (blockEnd - blockStart + 1L));
            } else {
                data =
                        readSliceFromFull(
                                conn.getInputStream(),
                                blockStart,
                                (int) (blockEnd - blockStart + 1L));
            }
            if (maxBytes > 0 && data.length > 0) {
                writeAtomically(blockFile, data);
            }
            return data;
        } finally {
            RequestScope.detach(conn);
            conn.disconnect();
        }
    }

    private byte[] fetchBlockWithoutRange(Session session, long blockStart, long blockEnd)
            throws IOException {
        HttpURLConnection retry = openUpstream(session.url, session.headers, null);
        try {
            int code = retry.getResponseCode();
            if (code < 200 || code >= 300) {
                throw new IOException("Upstream fallback HTTP " + code);
            }
            return readSliceFromFull(
                    retry.getInputStream(), blockStart, (int) (blockEnd - blockStart + 1L));
        } finally {
            RequestScope.detach(retry);
            retry.disconnect();
        }
    }

    private Meta probeUpstream(Session session, File entryDir) throws IOException {
        HttpURLConnection conn =
                openUpstream(session.url, session.headers, "bytes=0-" + (BLOCK_SIZE - 1));
        try {
            int code = conn.getResponseCode();
            Meta meta = new Meta();
            String ct = conn.getContentType();
            if (ct != null && !ct.trim().isEmpty()) meta.contentType = ct.trim();

            if (code == 206) {
                long[] cr = LocalProxy.parseContentRange(conn.getHeaderField("Content-Range"));
                if (cr != null && cr[2] > 0) {
                    meta.contentLength = cr[2];
                    meta.rangeSupported = true;
                    byte[] firstBlock =
                            readExactUpTo(
                                    conn.getInputStream(),
                                    (int) Math.min((long) BLOCK_SIZE, meta.contentLength));
                    if (maxBytes > 0 && firstBlock.length > 0) {
                        writeAtomically(new File(entryDir, "b_0.bin"), firstBlock);
                    }
                    saveMeta(entryDir, meta);
                    return meta;
                }
            } else if (code == 200) {
                long len = parseContentLength(conn);
                meta.contentLength = len;
                meta.rangeSupported =
                        "bytes".equalsIgnoreCase(conn.getHeaderField("Accept-Ranges"));
                if (len > 0 && len <= BLOCK_SIZE) {
                    byte[] whole = readExactUpTo(conn.getInputStream(), (int) len);
                    meta.contentLength = whole.length;
                    meta.rangeSupported = true;
                    if (maxBytes > 0 && whole.length > 0) {
                        writeAtomically(new File(entryDir, "b_0.bin"), whole);
                    }
                    saveMeta(entryDir, meta);
                    return meta;
                }
            } else if (code == 416) {
                meta.rangeSupported = false;
                return meta;
            }
            return meta;
        } finally {
            RequestScope.detach(conn);
            conn.disconnect();
        }
    }

    private boolean passthroughStream(
            Session session, String method, String rangeHeader, OutputStream out)
            throws IOException {
        HttpURLConnection conn = openUpstream(session.url, session.headers, rangeHeader);
        try {
            int code = conn.getResponseCode();
            if (code == 416 && rangeHeader != null) {
                RequestScope.detach(conn);
                conn.disconnect();
                conn = openUpstream(session.url, session.headers, null);
                code = conn.getResponseCode();
            }
            if (code >= 400) {
                LocalProxy.simple(out, code, "Upstream HTTP " + code);
                return false;
            }
            String ct = conn.getContentType();
            long len = parseContentLength(conn);
            String cr = conn.getHeaderField("Content-Range");
            StringBuilder head =
                    new StringBuilder("HTTP/1.1 ")
                            .append(code)
                            .append(code == 206 ? " Partial Content" : " OK")
                            .append("\r\nConnection: close\r\nContent-Type: ")
                            .append(
                                    ct != null && LocalProxy.safe(ct)
                                            ? ct
                                            : "application/octet-stream")
                            .append("\r\n");
            if (cr != null && LocalProxy.safe(cr)) {
                head.append("Content-Range: ").append(cr).append("\r\n");
            }
            if (len >= 0) {
                head.append("Content-Length: ").append(len).append("\r\n\r\n");
            } else {
                head.append("Transfer-Encoding: chunked\r\n\r\n");
            }
            out.write(head.toString().getBytes(StandardCharsets.ISO_8859_1));
            if (!"HEAD".equals(method)) {
                byte[] buf = new byte[64 * 1024];
                int n;
                try (InputStream in = conn.getInputStream()) {
                    if (len >= 0) {
                        long rem = len;
                        while (rem > 0
                                && (n = in.read(buf, 0, (int) Math.min(buf.length, rem))) != -1) {
                            if (n > 0) {
                                out.write(buf, 0, n);
                                rem -= n;
                            }
                        }
                    } else {
                        while ((n = in.read(buf)) != -1) {
                            if (n == 0) continue;
                            out.write(
                                    (Integer.toHexString(n) + "\r\n")
                                            .getBytes(StandardCharsets.US_ASCII));
                            out.write(buf, 0, n);
                            out.write(new byte[] {13, 10});
                        }
                        out.write("0\r\n\r\n".getBytes(StandardCharsets.US_ASCII));
                    }
                }
            }
            out.flush();
            return false;
        } finally {
            RequestScope.detach(conn);
            conn.disconnect();
        }
    }

    static long[] parseRangeHeader(String rangeHeader, long total) {
        if (rangeHeader == null || total <= 0) return null;
        String s = rangeHeader.trim();
        if (!s.regionMatches(true, 0, "bytes=", 0, 6)) return null;
        String spec = s.substring(6).trim();
        int comma = spec.indexOf(',');
        if (comma >= 0) spec = spec.substring(0, comma).trim();
        int dash = spec.indexOf('-');
        if (dash < 0) return null;
        String startPart = spec.substring(0, dash).trim();
        String endPart = spec.substring(dash + 1).trim();
        try {
            long start;
            long end;
            if (startPart.isEmpty()) {
                long suffix = Long.parseLong(endPart);
                if (suffix <= 0) return null;
                start = Math.max(0L, total - suffix);
                end = total - 1L;
            } else {
                start = Long.parseLong(startPart);
                end =
                        endPart.isEmpty()
                                ? total - 1L
                                : Math.min(total - 1L, Long.parseLong(endPart));
            }
            if (start < 0 || start >= total || end < start) return null;
            return new long[] {start, end};
        } catch (NumberFormatException invalid) {
            return null;
        }
    }

    public synchronized void trimIfNeeded() {
        if (rootDir == null || !rootDir.isDirectory()) return;
        File[] children = rootDir.listFiles();
        if (children == null || children.length == 0) return;
        long total = 0L;
        List<File> dirs = new ArrayList<>();
        for (File child : children) {
            if (child.isDirectory()) {
                dirs.add(child);
                total += directoryBytes(child);
            }
        }
        if (total <= maxBytes) return;
        Collections.sort(
                dirs,
                new Comparator<File>() {
                    @Override
                    public int compare(File a, File b) {
                        return Long.compare(entryLastUsed(a), entryLastUsed(b));
                    }
                });
        for (File dir : dirs) {
            if (total <= maxBytes) break;
            long size = directoryBytes(dir);
            deleteRecursive(dir);
            total -= size;
        }
    }

    public synchronized void clear() {
        if (rootDir == null || !rootDir.isDirectory()) return;
        File[] children = rootDir.listFiles();
        if (children == null) return;
        for (File child : children) {
            deleteRecursive(child);
        }
    }

    long totalCachedBytes() {
        return directoryBytes(rootDir);
    }

    private static long entryLastUsed(File dir) {
        File meta = new File(dir, "meta.json");
        return meta.isFile() ? meta.lastModified() : dir.lastModified();
    }

    private static long directoryBytes(File file) {
        if (file == null || !file.exists()) return 0L;
        if (file.isFile()) return file.length();
        File[] list = file.listFiles();
        if (list == null) return 0L;
        long sum = 0L;
        for (File item : list) sum += directoryBytes(item);
        return sum;
    }

    private static void deleteRecursive(File file) {
        if (file == null || !file.exists()) return;
        if (file.isDirectory()) {
            File[] list = file.listFiles();
            if (list != null) {
                for (File item : list) deleteRecursive(item);
            }
        }
        file.delete();
    }

    private static Meta loadMeta(File entryDir) {
        File file = new File(entryDir, "meta.json");
        if (!file.isFile()) return null;
        try {
            JSONObject obj = new JSONObject(new String(readFile(file), StandardCharsets.UTF_8));
            Meta meta = new Meta();
            meta.contentLength = obj.optLong("contentLength", -1L);
            meta.contentType = obj.optString("contentType", "application/octet-stream");
            meta.rangeSupported = obj.optBoolean("rangeSupported", true);
            return meta;
        } catch (Exception ignored) {
            return null;
        }
    }

    private static void saveMeta(File entryDir, Meta meta) {
        try {
            JSONObject obj =
                    new JSONObject()
                            .put("contentLength", meta.contentLength)
                            .put("contentType", meta.contentType)
                            .put("rangeSupported", meta.rangeSupported);
            writeAtomically(
                    new File(entryDir, "meta.json"),
                    obj.toString().getBytes(StandardCharsets.UTF_8));
        } catch (Exception ignored) {
        }
    }

    private static void touchMeta(File entryDir) {
        File meta = new File(entryDir, "meta.json");
        if (meta.isFile()) {
            meta.setLastModified(System.currentTimeMillis());
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

    private static byte[] readExactUpTo(InputStream in, int maxBytes) throws IOException {
        ByteArrayOutputStream out = new ByteArrayOutputStream(Math.min(maxBytes, 65536));
        byte[] buf = new byte[16384];
        int remaining = maxBytes;
        while (remaining > 0) {
            int n = in.read(buf, 0, Math.min(buf.length, remaining));
            if (n < 0) break;
            if (n > 0) {
                out.write(buf, 0, n);
                remaining -= n;
            }
        }
        return out.toByteArray();
    }

    private static byte[] readSliceFromFull(InputStream in, long skip, int length)
            throws IOException {
        byte[] discard = new byte[16384];
        long rem = skip;
        while (rem > 0) {
            int n = in.read(discard, 0, (int) Math.min(discard.length, rem));
            if (n < 0) return new byte[0];
            rem -= n;
        }
        return readExactUpTo(in, length);
    }

    private static byte[] readFile(File file) throws IOException {
        byte[] data = new byte[(int) file.length()];
        int offset = 0;
        try (FileInputStream in = new FileInputStream(file)) {
            while (offset < data.length) {
                int n = in.read(data, offset, data.length - offset);
                if (n < 0) break;
                offset += n;
            }
        }
        if (offset == data.length) return data;
        byte[] trimmed = new byte[offset];
        System.arraycopy(data, 0, trimmed, 0, offset);
        return trimmed;
    }

    private static void writeAtomically(File target, byte[] data) throws IOException {
        File tmp =
                new File(
                        target.getParentFile(),
                        target.getName() + "." + Thread.currentThread().getId() + ".tmp");
        try (FileOutputStream out = new FileOutputStream(tmp)) {
            out.write(data);
        }
        if (!tmp.renameTo(target)) {
            try (FileOutputStream out = new FileOutputStream(target)) {
                out.write(data);
            } finally {
                tmp.delete();
            }
        }
    }

    private static String sha256(String input) {
        try {
            MessageDigest md = MessageDigest.getInstance("SHA-256");
            byte[] digest = md.digest(input.getBytes(StandardCharsets.UTF_8));
            StringBuilder sb = new StringBuilder(digest.length * 2);
            for (byte b : digest) {
                sb.append(String.format(Locale.ROOT, "%02x", b & 0xFF));
            }
            return sb.toString();
        } catch (Exception e) {
            return Integer.toHexString(input.hashCode());
        }
    }
}
