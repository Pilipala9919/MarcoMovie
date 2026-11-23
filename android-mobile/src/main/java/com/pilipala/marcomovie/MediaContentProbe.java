package com.pilipala.marcomovie;

import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.TimeUnit;

/** Optional, bounded format hint. The real loader keeps ownership of transport and errors. */
final class MediaContentProbe {
    static final String HLS = "application/x-mpegURL", DASH = "application/dash+xml";
    static final String BINARY = "application/octet-stream";
    static final int MAX_BYTES = 512, BUDGET_MS = 3000;

    static boolean disguisedPath(String path) {
        return path != null && path.toLowerCase(Locale.ROOT).matches(".*\\.(iso|mp3)$");
    }

    static boolean starts(byte[] b, int n, int... magic) {
        if (n < magic.length) return false;
        for (int i = 0; i < magic.length; i++) if ((b[i] & 255) != magic[i]) return false;
        return true;
    }

    static boolean at(byte[] b, int n, int offset, String value) {
        if (offset + value.length() > n) return false;
        for (int i = 0; i < value.length(); i++)
            if ((b[offset + i] & 255) != value.charAt(i)) return false;
        return true;
    }

    static String classify(byte[] b, int n, String contentType) {
        // Strong container signatures precede even an incorrect audio or playlist MIME.
        if (n >= 12 && (at(b, n, 4, "ftyp") || at(b, n, 4, "styp"))) return "video/mp4";
        if (starts(b, n, 0x1a, 0x45, 0xdf, 0xa3)) return "video/x-matroska";
        if (at(b, n, 0, "FLV") && n >= 9 && b[3] == 1) return "video/x-flv";
        if (at(b, n, 0, "RIFF") && at(b, n, 8, "AVI ")) return "video/x-msvideo";
        if (at(b, n, 0, "RIFF") && at(b, n, 8, "WAVE")) return "audio/wav";
        if (at(b, n, 0, "fLaC")) return "audio/flac";
        if (at(b, n, 0, "OggS")) return BINARY; // Ogg may contain audio or video.
        if (at(b, n, 0, "ID3"))
            return BINARY; // ID3 is also legal before other media, not proof of MP3.
        if (n >= 377 && b[0] == 0x47 && b[188] == 0x47 && b[376] == 0x47) return "video/mp2t";
        String text = new String(b, 0, n, StandardCharsets.UTF_8).replaceFirst("^\\s+", "");
        if (text.startsWith("\ufeff")) text = text.substring(1).replaceFirst("^\\s+", "");
        // The prefix can end midway through the first line. Wait for its delimiter so
        // '#EXTM3U' followed by 'X' in a later network read cannot be accepted early.
        if (text.matches("(?s)^#EXTM3U[\\t ]*(?:\\r\\n|\\n|\\r).*")) return HLS;
        if (text.matches("(?s)^(?:<\\?xml[^>]*\\?>\\s*)?(?:<!--.*?-->\\s*)*<MPD(?:\\s|>).*"))
            return DASH;
        // contentType is deliberately insufficient on its own. Proxies may label a login/error
        // body, a single '#' chunk or real audio as mpegurl. Keep the original loader in charge.
        return null;
    }

    /** Positive response span, or -1 for a nonzero, impossible or unrepresentable byte range. */
    static long initialRangeLength(String value) {
        if (value == null || !value.matches("(?i)bytes 0-[0-9]+/(?:[0-9]+|\\*)")) return -1;
        try {
            int slash = value.indexOf('/');
            long end = Long.parseLong(value.substring(8, slash));
            if (end == Long.MAX_VALUE) return -1;
            String size = value.substring(slash + 1);
            if (!"*".equals(size) && end >= Long.parseLong(size)) return -1;
            return end + 1;
        } catch (NumberFormatException invalid) {
            return -1;
        }
    }

    static boolean sameOrigin(URL a, URL b) {
        return a.getProtocol().equalsIgnoreCase(b.getProtocol())
                && a.getHost().equalsIgnoreCase(b.getHost())
                && (a.getPort() < 0 ? a.getDefaultPort() : a.getPort())
                        == (b.getPort() < 0 ? b.getDefaultPort() : b.getPort());
    }

    static String probe(
            URL address, Map<String, String> headers, String userAgent, RequestScope scope) {
        if (!"http".equalsIgnoreCase(address.getProtocol())
                && !"https".equalsIgnoreCase(address.getProtocol())) return null;
        String requestedRange = null;
        for (Map.Entry<String, String> h : headers.entrySet())
            if (h.getKey().equalsIgnoreCase("Range")) requestedRange = h.getValue();
        // Do not alter a signed range or sniff a non-zero byte offset as a container header.
        if (requestedRange != null && !requestedRange.matches("(?i)bytes=0-[0-9]*")) return null;
        long deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(BUDGET_MS);
        URL target = address;
        for (int redirect = 0; redirect <= 3; redirect++) {
            HttpURLConnection c = null;
            try {
                if (scope != null) scope.check();
                int remaining = (int) TimeUnit.NANOSECONDS.toMillis(deadline - System.nanoTime());
                if (remaining <= 0) return null;
                c = ProxyAddress.openHttpConnection(target);
                RequestScope.attach(c);
                c.setConnectTimeout(Math.min(1200, remaining));
                c.setReadTimeout(Math.min(1200, remaining));
                c.setInstanceFollowRedirects(false);
                c.setRequestProperty("User-Agent", userAgent);
                for (Map.Entry<String, String> h : headers.entrySet())
                    c.setRequestProperty(h.getKey(), h.getValue());
                if (requestedRange == null)
                    c.setRequestProperty("Range", "bytes=0-" + (MAX_BYTES - 1));
                int status = c.getResponseCode();
                if (status == 301
                        || status == 302
                        || status == 303
                        || status == 307
                        || status == 308) {
                    String location = c.getHeaderField("Location");
                    if (location == null) return null;
                    URL next = new URL(target, location);
                    // Leave cross-origin/authentication/downgrade handling to the real player.
                    if (!sameOrigin(address, next)) return null;
                    target = next;
                    continue;
                }
                if (status != 200 && status != 206) return null;
                long responseSpan =
                        status == 206
                                ? initialRangeLength(c.getHeaderField("Content-Range"))
                                : MAX_BYTES;
                if (responseSpan <= 0) return null;
                byte[] prefix = new byte[(int) Math.min(MAX_BYTES, responseSpan)];
                int count = 0;
                try (InputStream stream = c.getInputStream()) {
                    while (count < prefix.length) {
                        if (scope != null) scope.check();
                        remaining =
                                (int) TimeUnit.NANOSECONDS.toMillis(deadline - System.nanoTime());
                        if (remaining <= 0) break;
                        c.setReadTimeout(Math.min(1200, remaining));
                        int read = stream.read(prefix, count, prefix.length - count);
                        if (read < 0) break;
                        count += read;
                        String result = classify(prefix, count, c.getContentType());
                        if (result != null) return result;
                    }
                }
                return classify(prefix, count, c.getContentType());
            } catch (Exception ignored) {
                return null; // No extra retry, no mutation of the actual playback headers or URL.
            } finally {
                if (c != null) {
                    RequestScope.detach(c);
                    c.disconnect();
                }
            }
        }
        return null;
    }
}
