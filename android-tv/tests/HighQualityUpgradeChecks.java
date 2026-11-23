package com.pilipala.marcomovie;

import com.sun.net.httpserver.HttpServer;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.Arrays;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.atomic.AtomicInteger;

/**
 * Automated JVM verification for high-quality playback & source-adaptation upgrades:
 * HlsStreamProxy, MediaDiskCache, MoviePlayer heuristics, MpvPlayer direct-guard, WebResolver
 * rules/ad blocking, Cms config parsing, Prefs validation, and NativePython/WebViewJS eligibility.
 */
public final class HighQualityUpgradeChecks {
    private static int passed = 0;

    private static void check(boolean condition, String name) {
        if (!condition) {
            throw new AssertionError("FAILED: " + name);
        }
        passed++;
    }

    public static void main(String[] args) throws Exception {
        testPrefsAndPlayerHeuristics();
        testWebResolverAndCmsRules();
        testHlsSyncAndPlaylistRewrite();
        testHlsLoopbackIntegration();
        testMediaDiskCacheIntegration();
        testSourceEngineEligibility();
        System.out.println("PASS HighQualityUpgradeChecks (" + passed + " checks)");
    }

    private static void testPrefsAndPlayerHeuristics() {
        check(
                Integer.valueOf(3).equals(Prefs.sanitizeSetting(Prefs.PLAYER_ENGINE, 3)),
                "PLAYER_ENGINE allows MPV (3)");
        check(
                Prefs.sanitizeSetting(Prefs.PLAYER_ENGINE, 4) == null,
                "PLAYER_ENGINE rejects out-of-range 4");
        check(
                Integer.valueOf(1024).equals(Prefs.sanitizeSetting(Prefs.MEDIA_CACHE_MB, 1024)),
                "MEDIA_CACHE_MB max 1024");
        check(
                Integer.valueOf(15).equals(Prefs.sanitizeSetting(Prefs.LOUDNESS_BOOST, 15)),
                "LOUDNESS_BOOST max 15");
        check(
                Boolean.TRUE.equals(Prefs.sanitizeSetting(Prefs.ANIME4K_ENABLED, true)),
                "ANIME4K_ENABLED in backup");
        check(
                Boolean.TRUE.equals(Prefs.sanitizeSetting(Prefs.HDR_TONE_MAPPING, true)),
                "HDR_TONE_MAPPING in backup");
        check(
                Boolean.TRUE.equals(Prefs.sanitizeSetting(Prefs.HLS_PROXY_ENABLED, true)),
                "HLS_PROXY_ENABLED in backup");
        check(
                Boolean.TRUE.equals(Prefs.sanitizeSetting(Prefs.HLS_AD_STRIP, true)),
                "HLS_AD_STRIP in backup");
        check(
                Boolean.TRUE.equals(Prefs.sanitizeSetting(Prefs.WEBVIEW_JS_FALLBACK, true)),
                "WEBVIEW_JS_FALLBACK in backup");
        check(
                Boolean.TRUE.equals(Prefs.sanitizeSetting(Prefs.NATIVE_PYTHON_ENABLED, true)),
                "NATIVE_PYTHON_ENABLED in backup");

        check(
                MoviePlayer.safeBufferBytes(64L * 1024 * 1024) == 48 * 1024 * 1024,
                "safeBufferBytes floor 48 MiB");
        check(
                MoviePlayer.safeBufferBytes(2048L * 1024 * 1024) == 256 * 1024 * 1024,
                "safeBufferBytes cap 256 MiB");
        check(
                MoviePlayer.safeBufferBytes(256L * 1024 * 1024)
                        == (int) ((256L * 1024 * 1024 * 45L) / 100L),
                "safeBufferBytes scales 45%");

        check(
                MoviePlayer.isPlatformSoftwareDecoder("c2.android.hevc.decoder"),
                "c2.android detected as software");
        check(
                MoviePlayer.isPlatformSoftwareDecoder("OMX.google.h264.decoder"),
                "OMX.google detected as software");
        check(
                !MoviePlayer.isPlatformSoftwareDecoder("c2.qti.hevc.decoder"),
                "hardware decoder not treated as software");

        check(
                "mediacodec,mediacodec-copy"
                        .equals(MpvPlayer.selectHwdecMode(0, false, true, true, "", "hevc")),
                "MPV direct hwdec on HDR display");
        check(
                "mediacodec-copy"
                        .equals(MpvPlayer.selectHwdecMode(0, false, true, false, "", "hevc")),
                "MPV copy hwdec when tone-mapping HDR on SDR display");
        check(
                "mediacodec-copy"
                        .equals(MpvPlayer.selectHwdecMode(0, true, false, true, "", "hevc")),
                "MPV copy hwdec when Anime4K enabled");
        check(
                "mediacodec-copy"
                        .equals(
                                MpvPlayer.selectHwdecMode(
                                        0, false, false, true, "hevc,av1", "HEVC")),
                "MPV copy hwdec when codec in direct-guard blacklist");
        check(
                "no".equals(MpvPlayer.selectHwdecMode(2, false, false, true, "", "hevc")),
                "MPV SW mode uses hwdec=no");
        check("gpu-next".equals(MpvPlayer.selectVo(true, false)), "gpu-next for HDR tone-mapping");
        check("gpu-next".equals(MpvPlayer.selectVo(false, true)), "gpu-next for Anime4K");
        check("gpu".equals(MpvPlayer.selectVo(false, false)), "gpu fallback when plain SDR");
        check(
                "hevc,av1".equals(MpvPlayer.addUnsafeCodec("hevc", "AV1")),
                "direct-guard codec blacklist dedup/append");
    }

    private static void testWebResolverAndCmsRules() throws Exception {
        check(WebResolver.isMedia("https://cdn.example/video/index.m3u8?token=1"), "m3u8 detected");
        check(WebResolver.isMedia("https://cdn.example/video/tos/12345"), "video/tos detected");
        check(WebResolver.isMedia("rtmp://live.example/app/stream"), "rtmp detected");
        check(
                !WebResolver.isMedia("https://play.example/embed.php?url=https://a.example/x.m3u8"),
                "rejects query-embedded wrapper URL");
        check(!WebResolver.isMedia("https://cdn.example/page/index.html"), "rejects html");
        check(!WebResolver.isMedia("https://cdn.example/assets/cover.png"), "rejects png");

        Cms.SniffRule rule = new Cms.SniffRule();
        rule.hosts.add("*.vod.example");
        rule.regex.add("/stream/play\\?id=\\d+");
        rule.exclude.add("preview=1");
        List<Cms.SniffRule> rules = Collections.singletonList(rule);
        check(
                WebResolver.isMedia(
                        "https://s1.vod.example/stream/play?id=42",
                        "https://www.vod.example/watch/1",
                        rules),
                "custom SniffRule regex matches");
        check(
                !WebResolver.isMedia(
                        "https://s1.vod.example/stream/play?id=42&preview=1",
                        "https://www.vod.example/watch/1",
                        rules),
                "custom SniffRule exclude blocks");

        List<String> ads = Arrays.asList("ad.tracker.example", "*.popup.example");
        check(
                WebResolver.isBlockedAdUrl("https://sub.ad.tracker.example/js.js", ads),
                "ad host subdomain blocked");
        check(
                WebResolver.isBlockedAdUrl("https://x.popup.example/p.png", ads),
                "wildcard ad host blocked");
        check(
                !WebResolver.isBlockedAdUrl("https://cdn.vod.example/v.m3u8", ads),
                "normal CDN not blocked");

        String cfgJson =
                "{"
                        + "\"sites\":[{\"key\":\"s1\",\"name\":\"Demo\",\"type\":1,\"api\":\"https://api.example/vod\"}],"
                        + "\"rules\":[{\"name\":\"r1\",\"hosts\":[\"vod.example\"],\"regex\":[\"/v/\\\\d+\"],\"exclude\":[\"ad\"],\"script\":\"document.querySelector('.play').click()\"}],"
                        + "\"ads\":[\"ads.example\",\"track.example\"]"
                        + "}";
        Cms.Config parsed = Cms.parseConfig(cfgJson, "https://cfg.example/config.json");
        check(parsed.rules.size() == 1, "Cms.parseConfig parses rules");
        check(
                "document.querySelector('.play').click()".equals(parsed.rules.get(0).script),
                "Cms.parseConfig parses rule script");
        check(parsed.ads.size() == 2, "Cms.parseConfig parses ads");
    }

    private static void testHlsSyncAndPlaylistRewrite() {
        // Build fake PNG header (123 bytes) + 3 valid 188-byte MPEG-TS packets
        int fakeHeaderLen = 123;
        byte[] disguised = new byte[fakeHeaderLen + 188 * 3 + 40];
        disguised[0] = (byte) 0x89;
        disguised[1] = 'P';
        disguised[2] = 'N';
        disguised[3] = 'G';
        disguised[fakeHeaderLen] = 0x47;
        disguised[fakeHeaderLen + 188] = 0x47;
        disguised[fakeHeaderLen + 376] = 0x47;
        check(
                HlsStreamProxy.findTsSyncOffset(disguised, disguised.length) == fakeHeaderLen,
                "findTsSyncOffset strips fake PNG header");

        byte[] cleanTs = new byte[188 * 3];
        cleanTs[0] = 0x47;
        cleanTs[188] = 0x47;
        cleanTs[376] = 0x47;
        check(HlsStreamProxy.findTsSyncOffset(cleanTs, cleanTs.length) == 0, "clean TS offset 0");

        byte[] mp4Init = "....ftypisom....moov....".getBytes(StandardCharsets.US_ASCII);
        check(HlsStreamProxy.findTsSyncOffset(mp4Init, mp4Init.length) == 0, "fMP4 untouched");

        // Playlist with discontinuity ad injection
        String m3u8 =
                "#EXTM3U\n"
                        + "#EXT-X-VERSION:3\n"
                        + "#EXT-X-KEY:METHOD=AES-128,URI=\"keys/k.key\"\n"
                        + "#EXTINF:10.0,\n"
                        + "seg0.png\n"
                        + "#EXTINF:10.0,\n"
                        + "seg1.png\n"
                        + "#EXTINF:10.0,\n"
                        + "seg2.png\n"
                        + "#EXTINF:10.0,\n"
                        + "seg3.png\n"
                        + "#EXTINF:10.0,\n"
                        + "seg4.png\n"
                        + "#EXT-X-DISCONTINUITY\n"
                        + "#EXTINF:5.0,\n"
                        + "https://ads.other.example/ad/promo1.ts\n"
                        + "#EXTINF:5.0,\n"
                        + "https://ads.other.example/ad/promo2.ts\n"
                        + "#EXT-X-DISCONTINUITY\n"
                        + "#EXTINF:10.0,\n"
                        + "seg5.png\n"
                        + "#EXT-X-ENDLIST\n";
        String rewritten =
                HlsStreamProxy.rewritePlaylist(
                        m3u8,
                        "https://cdn.example/movie/index.m3u8",
                        true,
                        (url, isPl, raw) ->
                                (isPl ? "/hls?" : "/seg?") + (raw ? "raw=1&u=" : "u=") + url);
        check(
                rewritten.contains("URI=\"/seg?raw=1&u=https://cdn.example/movie/keys/k.key\""),
                "EXT-X-KEY rewritten as raw");
        check(
                rewritten.contains("/seg?u=https://cdn.example/movie/seg0.png"),
                "relative segment resolved and rewritten");
        check(
                !rewritten.contains("promo1.ts") && !rewritten.contains("promo2.ts"),
                "discontinuity ad block stripped");
        check(rewritten.contains("seg5.png"), "post-ad content preserved");
    }

    private static void testHlsLoopbackIntegration() throws Exception {
        byte[] disguisedSegment = new byte[87 + 188 * 4];
        disguisedSegment[0] = (byte) 0x89;
        disguisedSegment[1] = 'P';
        disguisedSegment[2] = 'N';
        disguisedSegment[3] = 'G';
        for (int p = 0; p < 4; p++) {
            disguisedSegment[87 + p * 188] = 0x47;
            disguisedSegment[87 + p * 188 + 1] = (byte) (p + 1);
        }

        HttpServer upstream =
                HttpServer.create(new InetSocketAddress(InetAddress.getByName("127.0.0.1"), 0), 0);
        int upPort = upstream.getAddress().getPort();
        upstream.createContext(
                "/live/index.m3u8",
                ex -> {
                    byte[] body =
                            ("#EXTM3U\n#EXT-X-VERSION:3\n#EXTINF:4.0,\nchunk.png\n#EXT-X-ENDLIST\n")
                                    .getBytes(StandardCharsets.UTF_8);
                    ex.getResponseHeaders().add("Content-Type", "application/vnd.apple.mpegurl");
                    ex.sendResponseHeaders(200, body.length);
                    try (OutputStream os = ex.getResponseBody()) {
                        os.write(body);
                    }
                });
        upstream.createContext(
                "/live/chunk.png",
                ex -> {
                    ex.getResponseHeaders().add("Content-Type", "image/png");
                    ex.sendResponseHeaders(200, disguisedSegment.length);
                    try (OutputStream os = ex.getResponseBody()) {
                        os.write(disguisedSegment);
                    }
                });
        upstream.start();

        LocalProxy proxy = new LocalProxy(null, new Cms.Config());
        try {
            String proxiedM3u8 =
                    HlsStreamProxy.register(
                            "http://127.0.0.1:" + upPort + "/live/index.m3u8",
                            Collections.singletonMap("User-Agent", "TestAgent"),
                            false);
            // Missing token must return 403
            String noTokenUrl = proxiedM3u8.replaceAll("&_mm_token=[^&]+", "");
            HttpURLConnection bad = (HttpURLConnection) new URL(noTokenUrl).openConnection();
            check(bad.getResponseCode() == 403, "HLS proxy rejects missing _mm_token with 403");
            bad.disconnect();

            // Valid request returns rewritten m3u8 with /seg URL
            String body = new String(httpGet(proxiedM3u8), StandardCharsets.UTF_8);
            String segUrl = null;
            for (String line : body.split("\n")) {
                if (line.startsWith("http://127.0.0.1:")) {
                    segUrl = line.trim();
                    break;
                }
            }
            check(segUrl != null && segUrl.contains("/seg?"), "m3u8 rewrote segment to /seg");
            byte[] stripped = httpGet(segUrl);
            check(
                    stripped.length == 188 * 4 && (stripped[0] & 0xFF) == 0x47 && stripped[1] == 1,
                    "HLS /seg stripped 87-byte fake PNG header cleanly");
        } finally {
            proxy.close();
            upstream.stop(0);
        }
    }

    private static void testMediaDiskCacheIntegration() throws Exception {
        int payloadLen = 600 * 1024; // > 2 x 256 KiB blocks
        byte[] payload = new byte[payloadLen];
        for (int i = 0; i < payloadLen; i++) payload[i] = (byte) ((i * 31 + 7) & 0xFF);
        AtomicInteger upstreamHits = new AtomicInteger(0);
        AtomicInteger force416 = new AtomicInteger(0);

        HttpServer upstream =
                HttpServer.create(new InetSocketAddress(InetAddress.getByName("127.0.0.1"), 0), 0);
        int upPort = upstream.getAddress().getPort();
        upstream.createContext(
                "/video.mp4",
                ex -> {
                    upstreamHits.incrementAndGet();
                    String range = ex.getRequestHeaders().getFirst("Range");
                    if (force416.get() > 0 && range != null) {
                        ex.sendResponseHeaders(416, -1);
                        ex.close();
                        return;
                    }
                    if (range != null && range.startsWith("bytes=")) {
                        long[] r = MediaDiskCache.parseRangeHeader(range, payloadLen);
                        int start = (int) r[0];
                        int end = (int) r[1];
                        int len = end - start + 1;
                        ex.getResponseHeaders().add("Content-Type", "video/mp4");
                        ex.getResponseHeaders().add("Accept-Ranges", "bytes");
                        ex.getResponseHeaders()
                                .add(
                                        "Content-Range",
                                        "bytes " + start + "-" + end + "/" + payloadLen);
                        ex.sendResponseHeaders(206, len);
                        try (OutputStream os = ex.getResponseBody()) {
                            os.write(payload, start, len);
                        }
                    } else {
                        ex.getResponseHeaders().add("Content-Type", "video/mp4");
                        ex.sendResponseHeaders(200, payloadLen);
                        try (OutputStream os = ex.getResponseBody()) {
                            os.write(payload);
                        }
                    }
                });
        upstream.start();

        File tempRoot = Files.createTempDirectory("mm-disk-cache-test").toFile();
        try {
            MediaDiskCache cache = new MediaDiskCache(tempRoot, 2L * 1024 * 1024);
            MediaDiskCache.Session session =
                    new MediaDiskCache.Session(
                            "s1",
                            "http://127.0.0.1:" + upPort + "/video.mp4",
                            Collections.emptyMap(),
                            "entry1");

            // First Range read spanning blocks 0 and 1 (0..300000)
            ByteArrayOutputStream resp1 = new ByteArrayOutputStream();
            cache.serveSession(session, "GET", "bytes=0-300000", resp1);
            byte[] raw1 = resp1.toByteArray();
            int bodyOffset1 = findHttpBodyOffset(raw1);
            String head1 = new String(raw1, 0, bodyOffset1, StandardCharsets.ISO_8859_1);
            check(head1.startsWith("HTTP/1.1 206"), "MediaDiskCache returns 206 Partial Content");
            check(raw1.length - bodyOffset1 == 300001, "MediaDiskCache exact 206 length");
            for (int i = 0; i <= 300000; i += 997) {
                if (raw1[bodyOffset1 + i] != payload[i]) {
                    throw new AssertionError("Byte mismatch at " + i);
                }
            }
            int hitsAfterFirst = upstreamHits.get();
            check(hitsAfterFirst == 2, "First 300KB read fetched exactly 2 x 256KiB blocks");

            // Second Range read inside cached blocks 0..1 must hit 0 upstream requests
            ByteArrayOutputStream resp2 = new ByteArrayOutputStream();
            cache.serveSession(session, "GET", "bytes=1024-270000", resp2);
            check(upstreamHits.get() == hitsAfterFirst, "Second read served 100% from disk cache");

            // Block 2 with upstream returning 416 must fallback cleanly without Range
            force416.set(1);
            ByteArrayOutputStream resp3 = new ByteArrayOutputStream();
            cache.serveSession(session, "GET", "bytes=530000-535000", resp3);
            byte[] raw3 = resp3.toByteArray();
            int bodyOffset3 = findHttpBodyOffset(raw3);
            check(raw3.length - bodyOffset3 == 5001, "416 fallback returns exact slice length");
            check(raw3[bodyOffset3] == payload[530000], "416 fallback byte matches upstream");

            // LRU trim test
            cache.setMaxBytes(1024L);
            cache.trimIfNeeded();
            check(cache.totalCachedBytes() <= 1024L, "LRU trim enforces cache size cap");
        } finally {
            upstream.stop(0);
            deleteRecursive(tempRoot);
        }
    }

    private static void testSourceEngineEligibility() {
        Cms.Site pySite = new Cms.Site();
        pySite.type = 3;
        pySite.api = "https://repo.example/spider.py";
        check(NativePythonEngine.eligible(pySite), "NativePythonEngine accepts remote .py");

        Cms.Site localPy = new Cms.Site();
        localPy.type = 3;
        localPy.api = "csp_LocalPython";
        localPy.ext = "/tmp/test.py";
        check(NativePythonEngine.eligible(localPy), "NativePythonEngine accepts csp_LocalPython");

        Cms.Site jsSite = new Cms.Site();
        jsSite.type = 3;
        jsSite.api = "https://repo.example/spider.js";
        check(!NativePythonEngine.eligible(jsSite), "NativePythonEngine ignores .js");

        check(
                WebViewJsEngine.shouldFallbackFromJsError(
                        new RuntimeException("ReferenceError: DOMParser is not defined")),
                "WebViewJsEngine fallback triggers on DOMParser ReferenceError");
        check(
                !WebViewJsEngine.shouldFallbackFromJsError(
                        new java.net.SocketTimeoutException("timeout")),
                "WebViewJsEngine fallback does not trigger on network timeout");
        check(
                !WebViewJsEngine.shouldFallbackFromJsError(new JsEngine.DrpyRuleDetected("rule")),
                "WebViewJsEngine fallback does not swallow DrpyRuleDetected");
    }

    private static byte[] httpGet(String url) throws Exception {
        HttpURLConnection conn = (HttpURLConnection) new URL(url).openConnection();
        try {
            int code = conn.getResponseCode();
            if (code != 200) throw new AssertionError("Expected HTTP 200, got " + code);
            ByteArrayOutputStream out = new ByteArrayOutputStream();
            try (InputStream in = conn.getInputStream()) {
                byte[] buf = new byte[8192];
                int n;
                while ((n = in.read(buf)) != -1) out.write(buf, 0, n);
            }
            return out.toByteArray();
        } finally {
            conn.disconnect();
        }
    }

    private static int findHttpBodyOffset(byte[] raw) {
        for (int i = 0; i < raw.length - 3; i++) {
            if (raw[i] == '\r' && raw[i + 1] == '\n' && raw[i + 2] == '\r' && raw[i + 3] == '\n') {
                return i + 4;
            }
        }
        throw new AssertionError("Missing HTTP header terminator");
    }

    private static void deleteRecursive(File f) {
        if (f == null || !f.exists()) return;
        if (f.isDirectory()) {
            File[] list = f.listFiles();
            if (list != null) {
                for (File child : list) deleteRecursive(child);
            }
        }
        f.delete();
    }
}
