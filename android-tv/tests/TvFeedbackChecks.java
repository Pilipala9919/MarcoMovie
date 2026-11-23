package com.pilipala.marcomovie;

import java.nio.file.*;
import java.nio.charset.StandardCharsets;
import java.util.*;
import java.net.*;
import java.util.concurrent.atomic.AtomicInteger;
import com.sun.net.httpserver.HttpServer;

public final class TvFeedbackChecks {
    static int count;

    static void check(boolean value, String label) {
        if (!value) throw new AssertionError(label);
        count++;
        System.out.println("PASS " + label);
    }

    static String classify(String text, String mime) {
        byte[] b = text.getBytes(StandardCharsets.UTF_8);
        return MediaContentProbe.classify(b, b.length, mime);
    }

    static boolean eq(Object a, Object b) {
        return Objects.equals(a, b);
    }

    public static void main(String[] args) throws Exception {
        Path assets = Paths.get(args[0], "android-tv/src/main/assets/search");
        PhoneticSearchIndex index =
                new PhoneticSearchIndex(
                        Files.newInputStream(assets.resolve("pinyin-characters.tsv")),
                        Files.newInputStream(assets.resolve("pinyin-phrases.dict.yaml")),
                        Files.newInputStream(assets.resolve("title-phrases.txt")));
        check(
                index.suggestTitles("DLDL", 6).get(0).equals("斗罗大陆"),
                "uppercase initials suggest actual title");
        check(
                index.suggestTitles("douluodalu", 6).get(0).equals("斗罗大陆"),
                "full pinyin exact ranking");
        check(index.suggestTitles("斗罗", 6).contains("斗罗大陆"), "Chinese partial title");
        index.learn("流浪地球2");
        index.learn("长安十二时辰");
        index.learn("Batman 2022");
        check(index.suggestTitles("lldq2", 6).contains("流浪地球2"), "initials preserve digits");
        check(
                index.suggestTitles("changanshiershichen", 6).contains("长安十二时辰"),
                "polyphonic title suggestion");
        check(index.suggestTitles("bat", 6).contains("Batman 2022"), "English title suggestion");
        check(
                index.suggestTitles("zzzzzzzz", 6).isEmpty(),
                "unknown initials do not invent movies");
        check(
                index.suggestTitles("", 6).isEmpty() && index.suggestTitles("dl", 0).isEmpty(),
                "no empty-query or zero-budget suggestions");
        for (int i = 0; i < 20; i++) index.learn("斗罗大陆" + i);
        check(index.suggestTitles("dl", 99).size() == 8, "suggestions have hard upper bound");
        check(index.searchTerms("DLDL").contains("DLDL"), "remote literal query preserved");
        index.learnHotTitles(Arrays.asList("长安的荔枝", "生万物"));
        check(
                index.suggestTitles("cadlz", 8).contains("长安的荔枝")
                        && index.suggestTitles("sww", 8).contains("生万物"),
                "trending hot titles match Chinese initials for fast search suggestions");
        PhoneticSearchIndex privateSession = index.newSession(false);
        privateSession.learnHotTitles(Collections.singletonList("隐秘热剧测试"));
        check(
                !privateSession.suggestTitles("ymrj", 8).contains("隐秘热剧测试"),
                "private search session never ingests trending hot titles");
        check(
                TvReadingScrollPolicy.step(600, 24, 48) == 552,
                "prose keeps two lines of reading context");
        check(TvReadingScrollPolicy.step(600, 48, 48) == 480, "larger text adjusts prose step");
        check(TvReadingScrollPolicy.step(20, 48, 48) == 20, "small viewport remains bounded");
        check(TvReadingScrollPolicy.step(0, 24, 48) == 0, "unlaid-out viewport does not jump");
        check(
                MediaContentProbe.disguisedPath("/a.ISO")
                        && MediaContentProbe.disguisedPath("/b.mp3"),
                "suspicious suffixes receive bounded probe");
        check(
                !MediaContentProbe.disguisedPath("/real.mp4"),
                "ordinary video path keeps fast prepare");
        check(
                eq(
                        classify("\ufeff#EXTM3U\n#EXT-X-VERSION:3\n", "application/octet-stream"),
                        MediaContentProbe.HLS),
                "HLS content overrides octet-stream and filename");
        check(
                eq(
                        classify(
                                "<?xml version=\"1.0\"?>\n<MPD xmlns=\"urn:mpeg:dash:schema:mpd:2011\">",
                                "audio/mpeg"),
                        MediaContentProbe.DASH),
                "DASH root overrides audio MIME");
        check(
                classify("<html><body><MPD>login</MPD></body></html>", "application/dash+xml")
                        == null,
                "HTML containing MPD is not DASH");
        check(
                classify("{\"error\":401}", "application/x-mpegURL") == null,
                "JSON authentication failure is not HLS");
        check(
                eq(classify("\0\0\0\030ftypisom\0\0\0\0", "audio/mpeg"), "video/mp4"),
                "MP4 magic beats MP3 MIME");
        check(
                eq(classify("RIFF0000WAVEfmt ", "video/mp4"), "audio/wav"),
                "real audio remains audio");
        check(
                eq(classify("ID3\004\0\0\0\0\0\0", "audio/mpeg"), MediaContentProbe.BINARY),
                "ID3 remains player-sniffed, not forced video");
        check(
                MediaContentProbe.classify(new byte[512], 512, "application/x-iso9660-image")
                        == null,
                "ISO system area is not mislabeled video");
        check(
                classify("#EXTM3UX fake", "application/octet-stream") == null,
                "HLS magic requires delimiter");
        byte[] ebml = {(byte) 0x1a, 0x45, (byte) 0xdf, (byte) 0xa3};
        check(
                eq(MediaContentProbe.classify(ebml, 4, "audio/mpeg"), "video/x-matroska"),
                "Matroska magic wins misleading MIME");
        network();
        System.out.println("TOTAL " + count);
    }

    static void network() throws Exception {
        HttpServer server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        AtomicInteger requests = new AtomicInteger(), cross = new AtomicInteger();
        List<String> ranges = new ArrayList<>(), auth = new ArrayList<>();
        server.createContext(
                "/",
                exchange -> {
                    requests.incrementAndGet();
                    String p = exchange.getRequestURI().getPath();
                    ranges.add(exchange.getRequestHeaders().getFirst("Range"));
                    auth.add(exchange.getRequestHeaders().getFirst("Authorization"));
                    if (p.equals("/redirect")) {
                        exchange.getResponseHeaders().set("Location", "/video.iso");
                        exchange.sendResponseHeaders(302, -1);
                        exchange.close();
                        return;
                    }
                    if (p.equals("/cross")) {
                        exchange.getResponseHeaders()
                                .set(
                                        "Location",
                                        "http://localhost:"
                                                + server.getAddress().getPort()
                                                + "/secret");
                        exchange.sendResponseHeaders(302, -1);
                        exchange.close();
                        return;
                    }
                    if (p.equals("/secret")) cross.incrementAndGet();
                    byte[] body =
                            "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-ENDLIST\n"
                                    .getBytes(StandardCharsets.UTF_8);
                    int code =
                            p.equals("/unauthorized") ? 401 : p.equals("/range-error") ? 416 : 206;
                    exchange.getResponseHeaders().set("Content-Type", "application/octet-stream");
                    exchange.getResponseHeaders()
                            .set(
                                    "Content-Range",
                                    p.equals("/wrong-offset")
                                            ? "bytes 100-142/500"
                                            : "bytes 0-" + (body.length - 1) + "/" + body.length);
                    exchange.sendResponseHeaders(code, body.length);
                    exchange.getResponseBody().write(body);
                    exchange.close();
                });
        server.start();
        try {
            String root = "http://127.0.0.1:" + server.getAddress().getPort();
            Map<String, String> headers = new LinkedHashMap<>();
            headers.put("Authorization", "Bearer synthetic-test");
            headers.put("Referer", root + "/catalogue");
            check(
                    eq(
                            MediaContentProbe.probe(
                                    new URL(root + "/video.iso?filename=wrong.mpd"),
                                    headers,
                                    "test",
                                    null),
                            MediaContentProbe.HLS),
                    "real HTTP probe ignores misleading query suffix");
            check(
                    ranges.get(0).equals("bytes=0-511")
                            && auth.get(0).equals("Bearer synthetic-test"),
                    "bounded Range and authentication preserved");
            check(!headers.containsKey("Range"), "caller headers not mutated");
            check(
                    eq(
                            MediaContentProbe.probe(
                                    new URL(root + "/redirect"), headers, "test", null),
                            MediaContentProbe.HLS),
                    "same-origin redirect reaches content");
            check(
                    MediaContentProbe.probe(new URL(root + "/cross"), headers, "test", null) == null
                            && cross.get() == 0,
                    "cross-origin probe does not forward credentials");
            check(
                    MediaContentProbe.probe(new URL(root + "/unauthorized"), headers, "test", null)
                            == null,
                    "HTTP authentication error deferred to real loader");
            check(
                    MediaContentProbe.probe(new URL(root + "/range-error"), headers, "test", null)
                            == null,
                    "416 not retried as full download");
            check(
                    MediaContentProbe.probe(new URL(root + "/wrong-offset"), headers, "test", null)
                            == null,
                    "nonzero Content-Range cannot impersonate header");
            headers.put("range", "bytes=8-20");
            int before = requests.get();
            check(
                    MediaContentProbe.probe(new URL(root + "/video.iso"), headers, "test", null)
                                    == null
                            && before == requests.get(),
                    "signed nonzero Range untouched and unprobed");
            headers.remove("range");
            RequestScope cancelled = new RequestScope();
            cancelled.cancel();
            before = requests.get();
            check(
                    MediaContentProbe.probe(
                                            new URL(root + "/video.iso"),
                                            headers,
                                            "test",
                                            cancelled)
                                    == null
                            && before == requests.get(),
                    "cancelled probe makes no request");
        } finally {
            server.stop(0);
        }
    }
}
