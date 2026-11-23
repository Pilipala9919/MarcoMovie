package com.pilipala.marcomovie;

import android.net.Uri;
import androidx.media3.common.C;
import androidx.media3.datasource.DataSource;
import androidx.media3.datasource.DataSpec;
import androidx.media3.datasource.DefaultHttpDataSource;
import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.EOFException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.Socket;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;
import org.json.JSONArray;
import org.json.JSONObject;

/**
 * Offline unit + loopback TCP integration checks for 4K netdisk chunked 206 proxy streaming,
 * MKV proxy quality priority, container detection, keep-alive socket reuse, and legacy chunk
 * chaining across byte[] / ByteBuffer / InputStream spider payloads.
 */
public final class LocalProxyRangeChecks {
    private static int passed;

    private static void check(boolean ok, String label) {
        if (!ok) {
            throw new AssertionError("FAILED: " + label);
        }
        passed++;
        System.out.println("PASS " + label);
    }

    private static byte expectedByteAt(long pos) {
        return (byte) ((pos * 31L + (pos >>> 17) * 13L + 7L) & 0xFF);
    }

    private static byte[] generateSlice(long start, int len) {
        byte[] out = new byte[len];
        for (int i = 0; i < len; i++) {
            out[i] = expectedByteAt(start + i);
        }
        return out;
    }

    private static long parseRangeStart(Map<String, String> params) throws Exception {
        String range = params.get("Range");
        if (range == null) range = params.get("range");
        if (range == null && params.get("request-headers") != null) {
            JSONObject h = new JSONObject(params.get("request-headers"));
            range = h.optString("Range", h.optString("range", null));
        }
        if (range == null || !range.startsWith("bytes=")) return 0L;
        int dash = range.indexOf('-', 6);
        if (dash <= 6) return 0L;
        return Long.parseLong(range.substring(6, dash).trim());
    }

    public static void main(String[] args) throws Exception {
        testMediaOptionsKeepsProxyPrimaryForMkv();
        testKnownContainerDetection();
        testChunkedProxyEndToEndAndKeepAlive();
        testLegacyChainChunksMixedPayloadTypes();
        testDanmakuActionPushRoute();
        testDisguisedMp3VideoExtractorOrder();
        testClanUriAndApi23TlsSupport();
        testChunkedProxyTransientTruncationRecovery();
        System.out.println("ALL " + passed + " LocalProxy + ChunkedProxyDataSource checks passed.");
    }

    private static void testMediaOptionsKeepsProxyPrimaryForMkv() throws Exception {
        ProxyAddress.port = 19978;
        ProxyAddress.token = "tok123";

        Cms.Site site = new Cms.Site();
        site.key = "quark";
        site.api = "csp_Quark";

        Cms.Episode orig = new Cms.Episode();
        orig.name = "01.mkv [38.4G]";
        orig.url = "share_id_1";

        JSONObject result = new JSONObject();
        JSONArray rawUrls =
                new JSONArray()
                        .put("代理原画")
                        .put("http://127.0.0.1:9978/proxy?do=quark&id=abc")
                        .put("直连原画")
                        .put(
                                "https://pan-cdn.example/4k/01.mkv|Cookie=puus=xyz&Referer=https://pan.quark.example/");
        result.put("url", rawUrls);
        result.put("header", new JSONObject().put("User-Agent", "Mozilla/5.0 QuarkPan"));

        Cms.Episode normalized = MediaOptions.episode(site, orig, result);
        check(
                normalized.url.startsWith("http://127.0.0.1:19978/proxy?do=quark&id=abc")
                        && normalized.url.contains("_mm_token=tok123"),
                "MKV episode keeps loopback proxy ('代理原画') as primary URL");

        JSONArray qualities = normalized.media.getJSONArray("qualities");
        check(qualities.length() == 2, "both proxy and direct qualities retained");
        check(
                "代理原画".equals(qualities.getJSONObject(0).getString("name")),
                "first quality remains 代理原画");
        JSONObject fallback = qualities.getJSONObject(1);
        check(
                "直连原画".equals(fallback.getString("name"))
                        && "https://pan-cdn.example/4k/01.mkv".equals(fallback.getString("url")),
                "secondary fallback URL has inline pipe headers cleanly stripped");
        JSONObject fbHeaders = fallback.optJSONObject("headers");
        check(
                fbHeaders != null
                        && "puus=xyz".equals(fbHeaders.optString("Cookie"))
                        && "https://pan.quark.example/".equals(fbHeaders.optString("Referer")),
                "secondary fallback inline headers preserved in quality metadata");
    }

    private static void testKnownContainerDetection() {
        Uri proxyUri = Uri.parse("http://127.0.0.1:9978/proxy?do=quark&ts=1730000000&id=1");
        check(
                "MKV".equals(MoviePlayer.detectKnownContainer("01.mkv [38.4G]", proxyUri)),
                "episode name with trailing size badge [38.4G] detected as MKV");
        check(
                "MKV"
                        .equals(
                                MoviePlayer.detectKnownContainer(
                                        "[夸克4K] 沙丘2.2160p.MKV#part1", proxyUri)),
                "uppercase .MKV before fragment detected as MKV");
        check(
                "MP4".equals(MoviePlayer.detectKnownContainer("S01E02.mp4 (14.2GB)", proxyUri)),
                "episode name with .mp4 and size suffix detected as MP4");
        check(
                "TS".equals(MoviePlayer.detectKnownContainer("BDMV_00001.m2ts [58G]", proxyUri)),
                ".m2ts BluRay Remux stream detected as TS");
        check(
                "".equals(MoviePlayer.detectKnownContainer("正片 4K", proxyUri)),
                "query parameter ?ts= timestamp does not false-match TS container");
        Uri queryFileUri =
                Uri.parse("http://127.0.0.1:9978/proxy?do=uc&name=Dune2.2160p.mkv&ts=1730000000");
        check(
                "MKV".equals(MoviePlayer.detectKnownContainer("正片", queryFileUri)),
                ".mkv filename inside proxy query parameter detected as MKV");
    }

    private static void testChunkedProxyEndToEndAndKeepAlive() throws Exception {
        // 40 GiB virtual MKV (> 32-bit signed/unsigned range) served in 256 KiB byte[] slices
        final long totalSize = 40L * 1024L * 1024L * 1024L;
        final int maxSlice = 256 * 1024;
        final AtomicBoolean leakedInternalHeader = new AtomicBoolean(false);
        final AtomicInteger spiderCalls = new AtomicInteger();

        LocalProxy.SourceResolver mockNetdiskSpider =
                (app, cfg, params) -> {
                    spiderCalls.incrementAndGet();
                    for (String k : params.keySet()) {
                        if ("x-movie-chunked-client".equalsIgnoreCase(k)) {
                            leakedInternalHeader.set(true);
                        }
                    }
                    String reqHeadersJson = params.get("request-headers");
                    if (reqHeadersJson != null
                            && reqHeadersJson
                                    .toLowerCase(Locale.ROOT)
                                    .contains("x-movie-chunked-client")) {
                        leakedInternalHeader.set(true);
                    }
                    if ("hls".equals(params.get("mode"))) {
                        String m3u8 = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:6\n";
                        return new Object[] {
                            200, "application/vnd.apple.mpegurl", m3u8, Collections.emptyMap()
                        };
                    }
                    long reqStart = parseRangeStart(params);
                    if (reqStart >= totalSize) {
                        Map<String, String> h416 = new LinkedHashMap<>();
                        h416.put("Content-Range", "bytes */" + totalSize);
                        return new Object[] {416, "text/plain", new byte[0], h416};
                    }
                    // Intentionally align high-offset seeks (> 39 GiB) down by 4096 bytes to verify
                    // unaligned block-aligned netdisk spider responses!
                    long actualStart =
                            reqStart > (39L * 1024L * 1024L * 1024L)
                                    ? (reqStart - 4096L)
                                    : reqStart;
                    int len = (int) Math.min((long) maxSlice, totalSize - actualStart);
                    long actualEnd = actualStart + len - 1L;
                    byte[] body = generateSlice(actualStart, len);
                    Map<String, String> respHeaders = new LinkedHashMap<>();
                    respHeaders.put(
                            "Content-Range",
                            "bytes " + actualStart + "-" + actualEnd + "/" + totalSize);
                    return new Object[] {206, "video/x-matroska", body, respHeaders};
                };

        try (LocalProxy proxy =
                new LocalProxy(
                        null,
                        new Cms.Config(),
                        params -> new Object[] {404, "text/plain", "unused"},
                        mockNetdiskSpider)) {
            String rawProxyUrl =
                    LocalProxy.rewrite("http://127.0.0.1:9978/proxy?do=quark&file=remux");
            Uri uri = Uri.parse(rawProxyUrl);

            DefaultHttpDataSource.Factory httpFactory =
                    new DefaultHttpDataSource.Factory()
                            .setUserAgent("MarcoMovieTest/1.0")
                            .setConnectTimeoutMs(5000)
                            .setReadTimeoutMs(5000);
            DataSource ds =
                    new MoviePlayer.ChunkedProxyDataSource.Factory(httpFactory).createDataSource();

            // 1. Initial open at byte 0 reports full 40 GiB length
            long reportedLen = ds.open(new DataSpec(uri, 0L, C.LENGTH_UNSET));
            check(
                    reportedLen == totalSize,
                    "open(0, LENGTH_UNSET) exposes full 40 GiB total length (" + reportedLen + ")");

            // 2. Read 700 KiB across 3 consecutive 256 KiB byte[] chunks seamlessly
            int firstReadTotal = 700 * 1024;
            byte[] buf = new byte[firstReadTotal];
            int pos = 0;
            while (pos < firstReadTotal) {
                int n = ds.read(buf, pos, Math.min(33333, firstReadTotal - pos));
                if (n < 0) throw new EOFException("Premature EOF at " + pos);
                pos += n;
            }
            boolean firstBytesMatch = true;
            for (int i = 0; i < firstReadTotal; i++) {
                if (buf[i] != expectedByteAt(i)) {
                    firstBytesMatch = false;
                    break;
                }
            }
            check(
                    firstBytesMatch,
                    "700 KiB sequential read across 3 byte[] 206 chunks is byte-exact");

            // 3. Mid-chunk close() + immediate 40 GiB EOF Cues seek (> 32-bit offset + unaligned
            // cr[0])
            long t0 = System.nanoTime();
            ds.close();
            long closeMs = (System.nanoTime() - t0) / 1_000_000L;
            check(
                    closeMs < 500L,
                    "mid-chunk close() is instant without 40 GiB drain (" + closeMs + " ms)");

            long cuesOffset = totalSize - 90_123L;
            long eofRemaining = ds.open(new DataSpec(uri, cuesOffset, C.LENGTH_UNSET));
            check(
                    eofRemaining == 90_123L,
                    "64-bit EOF Cues seek open() reports exact remaining 90,123 bytes");

            ByteArrayOutputStream tail = new ByteArrayOutputStream();
            byte[] scratch = new byte[16384];
            int r;
            while ((r = ds.read(scratch, 0, scratch.length)) != C.RESULT_END_OF_INPUT) {
                tail.write(scratch, 0, r);
            }
            ds.close();
            byte[] tailBytes = tail.toByteArray();
            check(
                    tailBytes.length == 90_123,
                    "EOF Cues read terminates cleanly at exact 40 GiB boundary");
            boolean tailMatch = true;
            for (int i = 0; i < tailBytes.length; i++) {
                if (tailBytes[i] != expectedByteAt(cuesOffset + i)) {
                    tailMatch = false;
                    break;
                }
            }
            check(
                    tailMatch,
                    "unaligned block-aligned 206 response skipped prefix accurately at >39 GiB offset");
            check(
                    !leakedInternalHeader.get(),
                    "internal X-Movie-Chunked-Client header stripped before reaching spider");

            // 4. HLS 200 OK pass-through check
            Uri hlsUri =
                    Uri.parse(LocalProxy.rewrite("http://127.0.0.1:9978/proxy?do=quark&mode=hls"));
            DataSource hlsDs =
                    new MoviePlayer.ChunkedProxyDataSource.Factory(httpFactory).createDataSource();
            hlsDs.open(new DataSpec(hlsUri, 0L, C.LENGTH_UNSET));
            byte[] m3u8Buf = new byte[256];
            int m3u8Len = hlsDs.read(m3u8Buf, 0, m3u8Buf.length);
            hlsDs.close();
            String playlist = new String(m3u8Buf, 0, m3u8Len, StandardCharsets.UTF_8);
            check(playlist.startsWith("#EXTM3U"), "200 OK HLS playlist passes through unchanged");

            // 5. Raw socket keep-alive reuse + bounded Range: bytes=0-511 clamping check
            int port = ProxyAddress.port;
            String pathAndQuery = uri.getPath() + "?" + uri.getQuery();
            try (Socket raw = new Socket("127.0.0.1", port)) {
                raw.setSoTimeout(5000);
                InputStream in = raw.getInputStream();
                OutputStream out = raw.getOutputStream();

                // Request #1 on socket: bounded sniffMime probe (bytes=0-511 without chunked
                // header)
                String req1 =
                        "GET "
                                + pathAndQuery
                                + " HTTP/1.1\r\nHost: 127.0.0.1:"
                                + port
                                + "\r\nRange: bytes=0-511\r\nConnection: keep-alive\r\n\r\n";
                out.write(req1.getBytes(StandardCharsets.ISO_8859_1));
                out.flush();
                HttpReply reply1 = readHttpReply(in);
                check(
                        reply1.status == 206
                                && reply1.body.length == 512
                                && ("bytes 0-511/" + totalSize)
                                        .equals(reply1.headers.get("content-range"))
                                && "keep-alive".equalsIgnoreCase(reply1.headers.get("connection")),
                        "bounded Range: bytes=0-511 clamped to 512 bytes with Connection: keep-alive");

                // Request #2 on THE SAME socket: chunked client request at offset 512
                String req2 =
                        "GET "
                                + pathAndQuery
                                + " HTTP/1.1\r\nHost: 127.0.0.1:"
                                + port
                                + "\r\nX-Movie-Chunked-Client: 1\r\nRange: bytes=512-\r\nConnection: close\r\n\r\n";
                out.write(req2.getBytes(StandardCharsets.ISO_8859_1));
                out.flush();
                HttpReply reply2 = readHttpReply(in);
                check(
                        reply2.status == 206
                                && reply2.body.length == maxSlice
                                && reply2.body[0] == expectedByteAt(512L),
                        "second request succeeded over reused HTTP/1.1 keep-alive socket");
            }
            check(spiderCalls.get() >= 6, "mock netdisk spider invoked as expected");
        }
    }

    private static void testLegacyChainChunksMixedPayloadTypes() throws Exception {
        // Legacy client (e.g. SystemPlayer without X-Movie-Chunked-Client) reading a 1 MiB stream
        // across 4 chunks returning byte[], ByteBuffer, overlapping byte[], and InputStream.
        final long fileSize = 1024L * 1024L;
        final int chunkSize = 256 * 1024;
        LocalProxy.SourceResolver mixedSpider =
                (app, cfg, params) -> {
                    long start = parseRangeStart(params);
                    int idx = (int) (start / chunkSize);
                    long actualStart = (idx == 2 && start > 1024) ? (start - 1024) : start;
                    int len = (int) Math.min((long) chunkSize, fileSize - actualStart);
                    byte[] raw = generateSlice(actualStart, len);
                    Object payload;
                    if (idx == 0) {
                        payload = raw; // byte[]
                    } else if (idx == 1) {
                        payload = ByteBuffer.wrap(raw); // ByteBuffer
                    } else if (idx == 2) {
                        payload = raw; // overlapping byte[] (actualStart < currentOffset)
                    } else {
                        payload = new ByteArrayInputStream(raw); // InputStream
                    }
                    Map<String, String> h = new LinkedHashMap<>();
                    h.put(
                            "Content-Range",
                            "bytes "
                                    + actualStart
                                    + "-"
                                    + (actualStart + len - 1L)
                                    + "/"
                                    + fileSize);
                    return new Object[] {206, "video/mp4", payload, h};
                };

        try (LocalProxy proxy =
                new LocalProxy(
                        null,
                        new Cms.Config(),
                        params -> new Object[] {404, "text/plain", "unused"},
                        mixedSpider)) {
            Uri uri = Uri.parse(LocalProxy.rewrite("http://127.0.0.1:9978/proxy?do=baidu&id=9"));
            int port = ProxyAddress.port;
            String pathAndQuery = uri.getPath() + "?" + uri.getQuery();
            try (Socket raw = new Socket("127.0.0.1", port)) {
                raw.setSoTimeout(5000);
                OutputStream out = raw.getOutputStream();
                String req =
                        "GET "
                                + pathAndQuery
                                + " HTTP/1.1\r\nHost: 127.0.0.1:"
                                + port
                                + "\r\nRange: bytes=0-\r\nConnection: close\r\n\r\n";
                out.write(req.getBytes(StandardCharsets.ISO_8859_1));
                out.flush();
                HttpReply reply = readHttpReply(raw.getInputStream());
                check(
                        reply.status == 206 && reply.body.length == fileSize,
                        "legacy chainChunks delivers full 1 MiB across byte[] + ByteBuffer + InputStream");
                boolean exact = true;
                for (int i = 0; i < reply.body.length; i++) {
                    if (reply.body[i] != expectedByteAt(i)) {
                        exact = false;
                        break;
                    }
                }
                check(exact, "legacy chainChunks mixed payload bytes match 100%");
            }
        }
    }

    private static void testDanmakuActionPushRoute() throws Exception {
        try (LocalProxy proxy =
                new LocalProxy(
                        null,
                        new Cms.Config(),
                        params -> new Object[] {404, "text/plain", "unused"},
                        (app, cfg, params) -> new Object[] {404, "text/plain", "unused"})) {
            final String[] received = {null};
            proxy.danmakuConsumer = path -> received[0] = path;
            int port = ProxyAddress.port;

            // 1. GET /action?do=refresh&type=danmaku&path=... (#36)
            try (Socket raw = new Socket("127.0.0.1", port)) {
                raw.setSoTimeout(5000);
                OutputStream out = raw.getOutputStream();
                String req =
                        "GET /action?do=refresh&type=danmaku&path=http%3A%2F%2F127.0.0.1%3A9978%2Fproxy%3Fdo%3Ddm"
                                + " HTTP/1.1\r\nHost: 127.0.0.1:"
                                + port
                                + "\r\nConnection: close\r\n\r\n";
                out.write(req.getBytes(StandardCharsets.ISO_8859_1));
                out.flush();
                HttpReply reply = readHttpReply(raw.getInputStream());
                check(
                        reply.status == 200
                                && "ok".equals(new String(reply.body, StandardCharsets.UTF_8))
                                && "http://127.0.0.1:9978/proxy?do=dm".equals(received[0]),
                        "GET /action?do=refresh&type=danmaku pushes danmaku URL with 200 ok");
            }

            // 2. POST /action form-encoded danmaku push
            received[0] = null;
            try (Socket raw = new Socket("127.0.0.1", port)) {
                raw.setSoTimeout(5000);
                OutputStream out = raw.getOutputStream();
                byte[] form =
                        "do=refresh&type=danmaku&path=https%3A%2F%2Fdanmaku.example%2Fdm.xml"
                                .getBytes(StandardCharsets.UTF_8);
                String req =
                        "POST /action HTTP/1.1\r\nHost: 127.0.0.1:"
                                + port
                                + "\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: "
                                + form.length
                                + "\r\nConnection: close\r\n\r\n";
                out.write(req.getBytes(StandardCharsets.ISO_8859_1));
                out.write(form);
                out.flush();
                HttpReply reply = readHttpReply(raw.getInputStream());
                check(
                        reply.status == 200 && "https://danmaku.example/dm.xml".equals(received[0]),
                        "POST /action form body pushes danmaku URL with 200 ok");
            }

            // 3. Cross-origin browser CSRF attempt to /action must be rejected with 403
            received[0] = null;
            try (Socket raw = new Socket("127.0.0.1", port)) {
                raw.setSoTimeout(5000);
                OutputStream out = raw.getOutputStream();
                String req =
                        "GET /action?do=refresh&type=danmaku&path=https://evil.example/dm.xml"
                                + " HTTP/1.1\r\nHost: 127.0.0.1:"
                                + port
                                + "\r\nOrigin: https://evil.example\r\nConnection: close\r\n\r\n";
                out.write(req.getBytes(StandardCharsets.ISO_8859_1));
                out.flush();
                HttpReply reply = readHttpReply(raw.getInputStream());
                check(
                        reply.status == 403 && received[0] == null,
                        "cross-origin browser request to /action rejected with 403");
            }
        }
    }

    private static class FakeExtractor implements androidx.media3.extractor.Extractor {
        @Override
        public boolean sniff(androidx.media3.extractor.ExtractorInput input) {
            return false;
        }

        @Override
        public void init(androidx.media3.extractor.ExtractorOutput output) {}

        @Override
        public int read(
                androidx.media3.extractor.ExtractorInput input,
                androidx.media3.extractor.PositionHolder seekPosition) {
            return RESULT_END_OF_INPUT;
        }

        @Override
        public void seek(long position, long timeUs) {}

        @Override
        public void release() {}
    }

    private static final class Mp3ExtractorStub extends FakeExtractor {}

    private static final class Mp4ExtractorStub extends FakeExtractor {}

    private static final class MatroskaExtractorStub extends FakeExtractor {}

    private static final class TsExtractorStub extends FakeExtractor {}

    private static void testDisguisedMp3VideoExtractorOrder() {
        androidx.media3.extractor.Extractor[] input =
                new androidx.media3.extractor.Extractor[] {
                    new Mp3ExtractorStub(),
                    new TsExtractorStub(),
                    new Mp4ExtractorStub(),
                    new MatroskaExtractorStub()
                };
        androidx.media3.extractor.Extractor[] ordered =
                MoviePlayer.reorderDisguisedMp3Extractors(input);
        int mp4Idx = -1;
        int mkvIdx = -1;
        int mp3Idx = -1;
        for (int i = 0; i < ordered.length; i++) {
            String name = ordered[i].getClass().getSimpleName();
            if (mp4Idx < 0 && name.contains("Mp4")) mp4Idx = i;
            if (mkvIdx < 0 && name.contains("Matroska")) mkvIdx = i;
            if (mp3Idx < 0 && name.contains("Mp3")) mp3Idx = i;
        }
        check(
                mp4Idx == 0 && mkvIdx == 1 && mp3Idx > mkvIdx,
                "disguised .mp3 stream places MP4/MKV container extractors ahead of Mp3Extractor");
    }

    private static void testClanUriAndApi23TlsSupport() throws Exception {
        String normalized = Cms.normalizeClanUri("clan://localhost/oktv/fty/fty.json");
        check(
                normalized.startsWith("file://") && normalized.endsWith("/oktv/fty/fty.json"),
                "clan://localhost URI normalizes to file:// URI (#41)");
        String relative = Cms.resolve("clan://localhost/oktv/fty/fty.json", "./spider.jar");
        check(
                relative.startsWith("file://") && relative.endsWith("/oktv/fty/spider.jar"),
                "relative ./spider.jar resolves against clan:// origin (#41)");
        check(
                Cms.buildCompositeIsrgSocketFactory() != null,
                "API 23 composite ISRG Root X1 SSLSocketFactory builds cleanly (#55)");

        // Verify Android CloudSync source-only mode (syncHistory=false, #44)
        CloudSync.SubscriptionItem sharedSub =
                CloudSync.SubscriptionItem.create(
                        "家庭共享源",
                        "https://config.example/family.json",
                        "{\"sites\":[{\"key\":\"s1\",\"name\":\"共享源\",\"type\":1,\"api\":\"https://vod.example/api.php/provide/vod/\"}]}",
                        true,
                        "",
                        1000L);
        String parentPayload =
                new JSONObject()
                        .put("schema", CloudSync.SCHEMA)
                        .put("version", CloudSync.VERSION)
                        .put(
                                "watch_history",
                                new JSONArray()
                                        .put(
                                                new JSONObject()
                                                        .put("site", "s1")
                                                        .put("id", "parent_vid")
                                                        .put("title", "Parent Movie")
                                                        .put("updated", 2000L)))
                        .put(
                                "favorites",
                                new JSONArray()
                                        .put(
                                                new JSONObject()
                                                        .put("site", "s1")
                                                        .put("id", "parent_fav")
                                                        .put("title", "Parent Fav")
                                                        .put("updated", 2100L)))
                        .put("subscriptions", new JSONArray().put(sharedSub.toJson()))
                        .toString();
        String elderLocalHist =
                "[{\"site\":\"s1\",\"id\":\"elder_vid\",\"title\":\"Elder Opera\",\"updated\":2500}]";
        CloudSync.MergeResult elderMerged =
                CloudSync.merge(
                        elderLocalHist,
                        "[]",
                        "{}",
                        Collections.emptyList(),
                        true,
                        false,
                        parentPayload,
                        3000L);
        JSONObject writtenBack = new JSONObject(elderMerged.payloadJson);
        check(
                elderMerged.subscriptions != null
                        && elderMerged.subscriptions.size() == 1
                        && elderLocalHist.equals(elderMerged.historyJson)
                        && "[]".equals(elderMerged.favoritesJson)
                        && writtenBack.getJSONArray("watch_history").length() == 1
                        && "parent_vid"
                                .equals(
                                        writtenBack
                                                .getJSONArray("watch_history")
                                                .getJSONObject(0)
                                                .getString("id")),
                "CloudSync syncHistory=false syncs subscriptions while isolating local & remote history (#44)");
    }

    private static void testChunkedProxyTransientTruncationRecovery() throws Exception {
        final long totalSize = 192 * 1024L;
        final int chunkSize = 64 * 1024;
        final AtomicInteger chunkCalls = new AtomicInteger();
        final AtomicBoolean injectedDrop = new AtomicBoolean(false);

        LocalProxy.SourceResolver flakyResolver =
                (app, config, params) -> {
                    int call = chunkCalls.incrementAndGet();
                    long start = parseRangeStart(params);
                    long end = Math.min(totalSize - 1L, start + chunkSize - 1L);
                    int len = (int) (end - start + 1L);
                    Map<String, String> h = new LinkedHashMap<>();
                    h.put("Accept-Ranges", "bytes");
                    h.put("Content-Range", "bytes " + start + "-" + end + "/" + totalSize);
                    // On chunk #2, simulate a transient upstream netdisk TCP drop halfway through!
                    if (start == chunkSize && injectedDrop.compareAndSet(false, true)) {
                        byte[] truncated = generateSlice(start, len / 2);
                        InputStream shortStream =
                                new InputStream() {
                                    int pos = 0;

                                    @Override
                                    public int read() {
                                        return pos < truncated.length
                                                ? (truncated[pos++] & 0xff)
                                                : -1;
                                    }

                                    @Override
                                    public int read(byte[] b, int off, int l) {
                                        if (pos >= truncated.length) return -1;
                                        int n = Math.min(l, truncated.length - pos);
                                        System.arraycopy(truncated, pos, b, off, n);
                                        pos += n;
                                        return n;
                                    }
                                };
                        // Declare full Content-Length so client sees unexpected EOF mid-chunk
                        h.put("Content-Length", String.valueOf(len));
                        return new Object[] {206, "video/x-matroska", shortStream, h};
                    }
                    return new Object[] {
                        206,
                        "video/x-matroska",
                        new ByteArrayInputStream(generateSlice(start, len)),
                        h
                    };
                };

        try (LocalProxy proxy = new LocalProxy(null, null, params -> null, flakyResolver)) {
            String url =
                    "http://127.0.0.1:"
                            + proxy.server.getLocalPort()
                            + "/proxy?do=quark&id=flaky&_mm_token="
                            + proxy.token;
            DefaultHttpDataSource.Factory http =
                    new DefaultHttpDataSource.Factory()
                            .setConnectTimeoutMs(5000)
                            .setReadTimeoutMs(5000);
            DataSource ds = new MoviePlayer.ChunkedProxyDataSource.Factory(http).createDataSource();
            long openedLen = ds.open(new DataSpec.Builder().setUri(Uri.parse(url)).build());
            check(openedLen == totalSize, "flaky chunked MKV exposes full byte length");
            byte[] buf = new byte[16 * 1024];
            long offset = 0;
            int n;
            boolean bytesMatch = true;
            while ((n = ds.read(buf, 0, buf.length)) != C.RESULT_END_OF_INPUT) {
                for (int i = 0; i < n; i++) {
                    if (buf[i] != expectedByteAt(offset + i)) {
                        bytesMatch = false;
                        break;
                    }
                }
                offset += n;
            }
            ds.close();
            check(
                    injectedDrop.get()
                            && offset == totalSize
                            && bytesMatch
                            && chunkCalls.get() >= 4,
                    "ChunkedProxyDataSource transparently recovers mid-chunk upstream truncation with exact byte integrity");
        }
    }

    private static final class HttpReply {
        final int status;
        final Map<String, String> headers;
        final byte[] body;

        HttpReply(int status, Map<String, String> headers, byte[] body) {
            this.status = status;
            this.headers = headers;
            this.body = body;
        }
    }

    private static HttpReply readHttpReply(InputStream in) throws Exception {
        String statusLine = LocalProxy.line(in, 8192);
        int status = Integer.parseInt(statusLine.split(" ")[1]);
        Map<String, String> headers = new LinkedHashMap<>();
        for (; ; ) {
            String line = LocalProxy.line(in, 8192);
            if (line.isEmpty()) break;
            int colon = line.indexOf(':');
            if (colon > 0) {
                headers.put(
                        line.substring(0, colon).trim().toLowerCase(Locale.ROOT),
                        line.substring(colon + 1).trim());
            }
        }
        int contentLen = Integer.parseInt(headers.get("content-length"));
        byte[] body = new byte[contentLen];
        int off = 0;
        while (off < contentLen) {
            int n = in.read(body, off, contentLen - off);
            if (n < 0) throw new EOFException("Truncated HTTP reply at " + off + "/" + contentLen);
            off += n;
        }
        return new HttpReply(status, headers, body);
    }
}
