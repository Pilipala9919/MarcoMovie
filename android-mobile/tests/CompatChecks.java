package com.pilipala.marcomovie;

import com.sun.net.httpserver.HttpServer;
import java.io.*;
import java.lang.reflect.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.util.*;
import java.util.zip.*;
import javax.tools.JavaCompiler;
import javax.tools.ToolProvider;
import org.json.*;

public final class CompatChecks {
    static int count;

    static void check(boolean value, String label) {
        if (!value) throw new AssertionError(label);
        System.out.println("PASS " + label);
        count++;
    }

    public static void main(String[] args) throws Exception {
        Path assets = Paths.get(args[0], "android-mobile/src/main/assets/search");
        PhoneticSearchIndex index =
                new PhoneticSearchIndex(
                        Files.newInputStream(assets.resolve("pinyin-characters.tsv")),
                        Files.newInputStream(assets.resolve("pinyin-phrases.dict.yaml")));
        index.learn("三体");
        index.learn("流浪地球2");
        index.learn("长安十二时辰");
        check(index.expand("st").contains("三体"), "initials match learned real title");
        check(index.expand("santi").contains("三体"), "full pinyin matches same title by default");
        check(index.matches("流浪地球2", "lldq"), "initials prefix supports digits in title");
        check(index.matches("流浪地球2", "liulangdiqiu"), "full pinyin prefix supports title suffix");
        check(index.matches("长安十二时辰", "changanshiershichen"), "polyphonic readings are retained");
        check(index.expand("BATMAN").contains("BATMAN"), "English source query is preserved");
        PhoneticSearchIndex fresh =
                new PhoneticSearchIndex(
                        Files.newInputStream(assets.resolve("pinyin-characters.tsv")),
                        Files.newInputStream(assets.resolve("pinyin-phrases.dict.yaml")));
        check(fresh.expand("santi").contains("三体"), "full pinyin decoded without learned title");
        check(
                fresh.expand("liulangdiqiu").contains("流浪地球"),
                "phrase decoding joins multiple words");
        check(
                index.expand("三体").equals(Collections.singletonList("三体")),
                "Chinese query is unchanged");
        PhoneticSearchIndex named =
                new PhoneticSearchIndex(
                        Files.newInputStream(assets.resolve("pinyin-characters.tsv")),
                        Files.newInputStream(assets.resolve("pinyin-phrases.dict.yaml")),
                        Files.newInputStream(assets.resolve("title-phrases.txt")));
        check(
                named.searchTerms("dldl").get(0).equals("斗罗大陆"),
                "fresh initials expand to title without prior browsing");
        check(named.searchTerms("DLDL").contains("DLDL"), "literal acronym is preserved");
        check(
                named.searchTerms("douluodalu").get(0).equals("斗罗大陆"),
                "full pinyin uses same title vocabulary");
        check(
                named.searchTerms("frxxz").contains("凡人修仙传"),
                "other fresh initials use general title vocabulary");
        for (String title : Arrays.asList("斗罗大陆第二季", "斗罗大陆第三季", "斗罗大陆第四季", "斗罗大陆新篇"))
            named.prefer(title);
        check(
                named.searchTerms("dldl").get(0).equals("斗罗大陆"),
                "exact initials outrank recently learned longer titles");
        check(
                named.searchTerms("dldl").size() <= 3
                        && named.searchTerms("dldl")
                                .get(named.searchTerms("dldl").size() - 1)
                                .equals("dldl"),
                "all planned variants and literal fit runner request budget");
        check(named.matches("【动漫】斗罗大陆 第二季", "dldl"), "decorated title is not filtered out");
        check(
                named.searchTerms("未知片名").equals(Collections.singletonList("未知片名")),
                "Chinese input stays unchanged");
        HomeKeyTracker shortcuts = new HomeKeyTracker();
        check(
                !shortcuts.up(100, 0) && !shortcuts.up(300, 0) && shortcuts.up(500, 0),
                "legacy non-TV three discrete up taps trigger home shortcut");
        check(!shortcuts.up(600, 1) && !shortcuts.up(700, 2), "held Up does not count as taps");
        shortcuts.reset();
        check(
                !shortcuts.up(100, 0) && !shortcuts.up(1200, 0) && !shortcuts.up(1400, 0),
                "expired tap window resets");
        shortcuts.reset();
        check(!shortcuts.up(1500, 0), "other keys or screen changes reset tap sequence");
        Cms.Site site = new Cms.Site();
        site.headers.put("user-agent", "old");
        Cms.Episode ep = new Cms.Episode();
        ep.name = "episode";
        JSONObject response =
                new JSONObject(
                        "{\"url\":\"https://media.test/movie.mp4\",\"UA\":\"source-agent\",\"header\":{\"Referer\":\"https://catalog.test/\"},\"subt\":[{\"url\":\"subtitle.vtt\",\"name\":\"中文\"}],\"drm\":{\"scheme\":\"widevine\",\"licenseUrl\":\"https://license.test/\"}}");
        Cms.Episode normalized = MediaOptions.episode(site, ep, response);
        check(
                normalized.headers.get("User-Agent").equals("source-agent")
                        && !normalized.headers.containsKey("user-agent"),
                "player UA overrides inherited header case-insensitively");
        check(
                normalized
                        .media
                        .getJSONArray("subtitles")
                        .getJSONObject(0)
                        .getString("url")
                        .equals("https://media.test/subtitle.vtt"),
                "relative source subtitle normalized");
        check(
                normalized.media.getJSONObject("drm").getString("scheme").equals("widevine"),
                "DRM license declaration preserved without bypass");
        check(
                MediaOptions.subtitleMime("x.ASS?token=a", "").equals("text/x-ssa"),
                "external ASS MIME recognized");
        Cms.Episode file = new Cms.Episode();
        file.name = "[7GB] sample HDR.MKV";
        JSONObject relay =
                new JSONObject()
                        .put("url", "http://127.0.0.1:9999/opaque")
                        .put("format", "application/octet-stream");
        check(
                MediaOptions.mime(MediaOptions.episode(site, file, relay).media) == null,
                "original MKV filename does not override opaque relay format");
        relay.put("format", "application/x-mpegURL");
        check(
                "application/x-mpegURL"
                        .equals(MediaOptions.mime(MediaOptions.episode(site, file, relay).media)),
                "declared relay HLS retains Media3 canonical MIME case");
        relay.put("type", 0);
        check(
                "application/x-mpegURL"
                        .equals(MediaOptions.mime(MediaOptions.episode(site, file, relay).media)),
                "numeric source type does not hide declared MIME format");
        relay.put("mimeType", "application/vnd.apple.mpegurl; charset=UTF-8");
        check(
                "application/x-mpegURL"
                        .equals(MediaOptions.mime(MediaOptions.episode(site, file, relay).media)),
                "vendor HLS MIME normalizes with parameters");
        relay.remove("mimeType");
        relay.put("format", "application/octet-stream")
                .put("url", "http://127.0.0.1:9999/stream.m3u8");
        check(
                MediaOptions.mime(MediaOptions.episode(site, file, relay).media) == null,
                "generic source format preserves manifest URL inference");
        relay.put("url", "https://media.test/opaque");
        check(
                MediaOptions.mime(MediaOptions.episode(site, file, relay).media) == null,
                "remote opaque media retains format detection");
        file.name = "第1集";
        relay.put("url", "http://127.0.0.1:9999/opaque");
        check(
                MediaOptions.mime(MediaOptions.episode(site, file, relay).media) == null,
                "unknown local file retains format detection");
        Cms.Video action =
                Cms.listing(
                                "{\"list\":[{\"vod_id\":\"0000\",\"vod_name\":\"登录\",\"action\":\"LoginShow\"},{\"vod_id\":\"huya_1\",\"vod_tag\":\"folder\"}]}")
                        .videos
                        .get(0);
        check(action.action.equals("LoginShow"), "account action not discarded by CMS parser");
        List<DanmakuData.Comment> comments =
                DanmakuData.parse(
                        "<i><d p=\"1.5,1,25,16711680\">hello</d><d p=\"3,5,25,16777215\"><![CDATA[top & text]]></d></i>");
        check(
                comments.size() == 2
                        && comments.get(0).time == 1500
                        && comments.get(0).color == 0xff0000,
                "Bili XML comment timing and color");
        check(
                comments.get(1).mode == 5 && comments.get(1).text.equals("top & text"),
                "fixed comment mode and CDATA");
        comments = DanmakuData.parse("{\"danmuku\":[[2,1,16777215,\"text\"]]}");
        check(comments.size() == 1 && comments.get(0).time == 2000, "source JSON comments");
        comments =
                DanmakuData.parse(
                        "{\"comments\":[{\"p\":\"4.5,16711680,1,user\",\"m\":\"test\"}]}");
        check(
                comments.get(0).time == 4500 && comments.get(0).color == 0xff0000,
                "Dandan-style comment schema");
        comments =
                DanmakuData.parse(
                        "<i><d p=\"2.0,1,25,16777215\">A & B <3\u0007</d><d p=\"3.0,1,25,16777215\">ok</d></i>");
        check(
                comments.size() == 2 && comments.get(0).text.contains("A & B"),
                "fault-tolerant XML danmaku recovers from unescaped ampersand and control chars");
        comments =
                DanmakuData.parse(
                        "{\"code\":0,\"data\":{\"danmuku\":[[5,1,16777215,\"nested\"]]}}");
        check(
                comments.size() == 1 && comments.get(0).time == 5000,
                "nested data.danmuku JSON schema supported");
        check(
                Cms.isMedia("rtmps://live.example/app/stream")
                        && Cms.isMedia("mmsh://live.example/stream")
                        && Cms.isMedia("proxy://do=live&type=m3u8"),
                "live streaming protocols and proxy scheme recognized as media");
        boolean refused = false;
        try {
            DanmakuData.parse(
                    "<!DOCTYPE i [<!ENTITY x SYSTEM 'file:///private'>]><i><d p=\"0,1,25,1\">&x;</d></i>");
        } catch (IOException expected) {
            refused = true;
        }
        check(refused, "external XML entities rejected");
        check(
                ProxyAddress.rewrite("http://127.0.0.1:9978/proxy?do=a&url=x%2By%3D", 42123)
                        .equals("http://127.0.0.1:42123/proxy?do=a&url=x%2By%3D"),
                "reserved proxy relocated without altering encoded query");
        check(
                ProxyAddress.rewrite("http://127.0.0.1:-1/proxy?do=a", 42123)
                        .equals("http://127.0.0.1:42123/proxy?do=a"),
                "unresolved plugin proxy port repaired");
        check(
                ProxyAddress.rewrite("http://localhost:9980/proxy?do=a", 42123)
                        .equals("http://127.0.0.1:42123/proxy?do=a"),
                "discovery range routes to this application's proxy");
        check(
                ProxyAddress.rewrite("http://127.0.0.1:9978/other", 42123)
                        .equals("http://127.0.0.1:9978/other"),
                "other loopback services left unchanged");
        check(
                ProxyAddress.rewrite("https://media.test:9978/proxy?do=a", 42123)
                        .equals("https://media.test:9978/proxy?do=a"),
                "remote proxy URLs left unchanged");
        check(
                ProxyAddress.rewrite("http://127.0.0.1:9978/proxy?do=a", 42123, "sec123")
                        .equals("http://127.0.0.1:42123/proxy?do=a&_mm_token=sec123"),
                "session token appended when rewriting local proxy URL");
        check(
                ProxyAddress.isAllowedRequest(
                                "127.0.0.1:42123", null, null, "sec123", "sec123", true)
                        && !ProxyAddress.isAllowedRequest(
                                "evil.example:42123", null, null, "sec123", "sec123", false)
                        && !ProxyAddress.isAllowedRequest(
                                "127.0.0.1:42123",
                                "https://evil.example",
                                null,
                                "sec123",
                                "sec123",
                                false)
                        && !ProxyAddress.isAllowedRequest(
                                "127.0.0.1:42123", null, "cross-site", "sec123", "sec123", false)
                        && !ProxyAddress.isAllowedRequest(
                                "127.0.0.1:42123", null, null, "wrong", "sec123", false)
                        && !ProxyAddress.isAllowedRequest(
                                "127.0.0.1:42123", null, null, null, "sec123", true),
                "proxy request guard blocks DNS rebinding, browser CSRF, and bad tokens");
        response.remove("subt");
        response.put("subs", new JSONArray().put(new JSONObject().put("url", "caption.srt")));
        check(
                MediaOptions.episode(site, ep, response)
                        .media
                        .getJSONArray("subtitles")
                        .getJSONObject(0)
                        .getString("url")
                        .endsWith("/caption.srt"),
                "cloud subs alias preserves external captions");
        Cms.Episode cloudEp = new Cms.Episode();
        cloudEp.name = "第01集";
        JSONObject cloudSameTier =
                new JSONObject()
                        .put(
                                "url",
                                new JSONArray()
                                        .put("多线程原画")
                                        .put("http://127.0.0.1:9978/proxy?do=quark&id=1")
                                        .put("原画")
                                        .put(
                                                "https://drive-pc.quark.example/file/ep01|Referer=https://pan.quark.example/"));
        Cms.Episode preferredProxy = MediaOptions.episode(site, cloudEp, cloudSameTier);
        check(
                preferredProxy.url.startsWith("http://127.0.0.1:9978/proxy")
                        && "https://drive-pc.quark.example/file/ep01"
                                .equals(
                                        preferredProxy
                                                .media
                                                .getJSONArray("qualities")
                                                .getJSONObject(1)
                                                .getString("url"))
                        && "https://pan.quark.example/"
                                .equals(
                                        preferredProxy
                                                .media
                                                .getJSONArray("qualities")
                                                .getJSONObject(1)
                                                .getJSONObject("headers")
                                                .getString("Referer")),
                "multi-threaded loopback proxy stays primary while direct CDN remains in qualities with stripped headers");
        JSONObject cloudLowerTier =
                new JSONObject()
                        .put(
                                "url",
                                new JSONArray()
                                        .put("原画")
                                        .put("http://127.0.0.1:9978/proxy?do=quark&id=2")
                                        .put("普画")
                                        .put("https://drive-pc.quark.example/transcode/720.m3u8"));
        Cms.Episode keptRaw = MediaOptions.episode(site, cloudEp, cloudLowerTier);
        check(
                keptRaw.url.startsWith("http://127.0.0.1:9978/proxy"),
                "4K original stream via proxy is not downgraded to lower transcode tier");
        String history = "[]";
        for (int n = 0; n < 65; n++) {
            WatchHistory.Entry e = new WatchHistory.Entry();
            e.site = "source";
            e.id = "id" + n;
            e.title = "Sample";
            e.line = "line";
            e.episode = "episode";
            e.position = 24000;
            e.duration = 120000;
            e.updated = n;
            history = WatchHistory.upsert(history, e);
        }
        List<WatchHistory.Entry> entries = WatchHistory.read(history);
        check(
                entries.size() == 60 && entries.get(0).id.equals("id64"),
                "history keeps latest 60 distinct titles");
        WatchHistory.Entry e = entries.get(12);
        e.position = 45000;
        history = WatchHistory.upsert(history, e);
        entries = WatchHistory.read(history);
        check(
                entries.size() == 60
                        && entries.get(0).id.equals(e.id)
                        && entries.get(0).resume() == 45000,
                "updating a title moves it to front and retains progress");
        check(
                !new JSONObject(history.substring(1, history.indexOf("}") + 1)).has("url"),
                "history does not store expiring playback URL");
        check(
                WatchHistory.read(WatchHistory.remove(history, e.key())).size() == 59,
                "history item removal");
        check(WatchHistory.read("bad JSON").isEmpty(), "invalid history recovers safely");
        WatchHistory.setCorrupted(false);
        e.duration = 120000;
        e.position = 118000;
        check(e.resume() == 0, "finished item restarts from beginning");
        e.duration = 3000;
        e.position = 1200;
        check(e.resume() == 1200, "short clip is not prematurely marked completed");
        e.position = -50;
        history = WatchHistory.upsert("[]", e);
        check(WatchHistory.read(history).get(0).position == 0, "negative history position clamped");
        String decoderManifest =
                new String(
                        java.nio.file.Files.readAllBytes(
                                java.nio.file.Paths.get(
                                        args[0], "android-mobile/decoder-dependencies.json")),
                        "UTF-8");
        JSONArray decoderItems = new JSONArray(decoderManifest);
        boolean hasArmv7Decoders = false, hasArm64Decoders = false;
        for (int i = 0; i < decoderItems.length(); i++) {
            JSONArray members = decoderItems.getJSONObject(i).optJSONArray("native_members");
            if (members == null) continue;
            String joined = members.toString();
            if (joined.contains("lib/armeabi-v7a/libffmpegJNI.so")
                    && joined.contains("lib/armeabi-v7a/libgav1JNI.so")
                    && joined.contains("lib/armeabi-v7a/libvpxV2JNI.so")) {
                hasArmv7Decoders = true;
            }
            if (joined.contains("lib/arm64-v8a/libffmpegJNI.so")
                    && joined.contains("lib/arm64-v8a/libgav1JNI.so")
                    && joined.contains("lib/arm64-v8a/libvpxV2JNI.so")) {
                hasArm64Decoders = true;
            }
        }
        check(
                hasArmv7Decoders && hasArm64Decoders,
                "decoder manifest ships both armeabi-v7a and arm64-v8a Media3 native extensions");
        runModuleBChecks(Paths.get(args[0]));
        System.out.println(
                "OK " + count + " compatibility checks; network and playback not implied");
    }

    private static byte[] buildMockDnsAResponse(String host, byte[] ipv4, int ttl)
            throws IOException {
        ByteArrayOutputStream out = new ByteArrayOutputStream(96);
        // Header: ID=0, Flags=0x8180 (QR=1, RD=1, RA=1, RCODE=0), QD=1, AN=1, NS=0, AR=0
        out.write(new byte[] {0, 0, (byte) 0x81, (byte) 0x80, 0, 1, 0, 1, 0, 0, 0, 0});
        for (String label : host.split("\\.")) {
            byte[] b = label.getBytes(StandardCharsets.US_ASCII);
            out.write(b.length);
            out.write(b);
        }
        out.write(0);
        out.write(new byte[] {0, 1, 0, 1}); // QTYPE=A, QCLASS=IN
        // Answer: pointer 0xC00C -> QNAME, TYPE=A(1), CLASS=IN(1), TTL, RDLENGTH=4, RDATA
        out.write(new byte[] {(byte) 0xc0, 0x0c, 0, 1, 0, 1});
        out.write((ttl >> 24) & 0xff);
        out.write((ttl >> 16) & 0xff);
        out.write((ttl >> 8) & 0xff);
        out.write(ttl & 0xff);
        out.write(new byte[] {0, 4});
        out.write(ipv4, 0, 4);
        return out.toByteArray();
    }

    private static void deleteTree(Path dir) throws IOException {
        if (dir == null || !Files.exists(dir)) return;
        try (java.util.stream.Stream<Path> walk = Files.walk(dir)) {
            List<Path> sorted = new ArrayList<>();
            walk.forEach(sorted::add);
            Collections.reverse(sorted);
            for (Path p : sorted) {
                p.toFile().setWritable(true);
            }
            for (Path p : sorted) {
                Files.deleteIfExists(p);
            }
        }
    }

    private static void runModuleBChecks(Path root) throws Exception {
        // 1. Cms DoH fallback against DNS pollution (RFC 8484 Wire Format) + null-safe extraction
        HttpServer mockNet = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        try {
            mockNet.createContext(
                    "/dns-wire",
                    ex -> {
                        byte[] wire =
                                buildMockDnsAResponse(
                                        "polluted-wogg.invalid", new byte[] {127, 0, 0, 1}, 120);
                        ex.getResponseHeaders().set("Content-Type", "application/dns-message");
                        ex.sendResponseHeaders(200, wire.length);
                        ex.getResponseBody().write(wire);
                        ex.close();
                    });
            mockNet.createContext(
                    "/dns-poisoned",
                    ex -> {
                        byte[] wire =
                                buildMockDnsAResponse(
                                        "poisoned.invalid", new byte[] {0, 0, 0, 0}, 120);
                        ex.getResponseHeaders().set("Content-Type", "application/dns-message");
                        ex.sendResponseHeaders(200, wire.length);
                        ex.getResponseBody().write(wire);
                        ex.close();
                    });
            mockNet.createContext(
                    "/tvbox/sub.json",
                    ex -> {
                        byte[] body =
                                "{\"sites\":[{\"key\":\"wogg\",\"name\":\"玩偶4K\",\"type\":3,\"api\":\"csp_Wogg\"}]}"
                                        .getBytes(StandardCharsets.UTF_8);
                        ex.getResponseHeaders().set("Content-Type", "application/json");
                        ex.sendResponseHeaders(200, body.length);
                        ex.getResponseBody().write(body);
                        ex.close();
                    });
            mockNet.createContext(
                    "/api/echo",
                    ex -> {
                        ByteArrayOutputStream reqBody = new ByteArrayOutputStream();
                        byte[] buf = new byte[1024];
                        int n;
                        while ((n = ex.getRequestBody().read(buf)) != -1) reqBody.write(buf, 0, n);
                        JSONObject reply =
                                new JSONObject()
                                        .put("method", ex.getRequestMethod())
                                        .put("query", String.valueOf(ex.getRequestURI().getQuery()))
                                        .put(
                                                "xTag",
                                                String.valueOf(
                                                        ex.getRequestHeaders().getFirst("X-Tag")))
                                        .put(
                                                "body",
                                                new String(
                                                        reqBody.toByteArray(),
                                                        StandardCharsets.UTF_8));
                        byte[] out = reply.toString().getBytes(StandardCharsets.UTF_8);
                        ex.getResponseHeaders()
                                .set("Content-Type", "application/json; charset=utf-8");
                        ex.getResponseHeaders().set("X-Server", "module-b");
                        ex.sendResponseHeaders(200, out.length);
                        ex.getResponseBody().write(out);
                        ex.close();
                    });
            mockNet.createContext(
                    "/api/bin",
                    ex -> {
                        byte[] bin = new byte[] {0x43, 0x41, 0x54, (byte) 0xff};
                        ex.getResponseHeaders().set("Content-Type", "application/octet-stream");
                        ex.sendResponseHeaders(200, bin.length);
                        ex.getResponseBody().write(bin);
                        ex.close();
                    });
            mockNet.start();
            int port = mockNet.getAddress().getPort();

            try {
                Cms.setDohEndpointsForTest(
                        "http://127.0.0.1:1/dead-doh", "http://127.0.0.1:" + port + "/dns-wire");
                String fetched =
                        Cms.fetch("http://polluted-wogg.invalid:" + port + "/tvbox/sub.json", null);
                Cms.Config dohCfg = Cms.parseConfig(fetched, "");
                check(
                        dohCfg.sites.size() == 1 && "wogg".equals(dohCfg.sites.get(0).key),
                        "Cms.fetch recovers via concurrent RFC8484 DoH fallback when DNS is polluted");
            } finally {
                Cms.setDohEndpointsForTest();
            }

            // 2. Verify js-host bridge assets exist & are non-empty
            Path jsHostDir = root.resolve("android-mobile/src/main/assets/js-host");
            for (String requiredAsset :
                    new String[] {
                        "bootstrap.js",
                        "module-interop.js",
                        "catvod.mjs",
                        "cat-lib.mjs",
                        "utils-lib.mjs",
                        "lodash-shim.mjs",
                        "cheerio-bridge.mjs",
                        "http-shim.mjs",
                        "crypto-js.js",
                        "jsonpath.mjs"
                    }) {
                Path p = jsHostDir.resolve(requiredAsset);
                check(
                        Files.isRegularFile(p) && Files.size(p) > 64,
                        "js-host asset present: " + requiredAsset);
            }

            // 3. Compile & unit-test Spider, SpiderApi, CspEngine, and JsEngine in isolated
            // temp dir
            Path tempRoot = Files.createTempDirectory("mm-compat-modb-");
            try {
                Path classesDir = Files.createDirectories(tempRoot.resolve("classes"));
                Path stubPkg =
                        Files.createDirectories(tempRoot.resolve("stubs/com/pilipala/marcomovie"));
                Path stubMain = stubPkg.resolve("MainActivity.java");
                Files.write(
                        stubMain,
                        ("package com.pilipala.marcomovie;\n"
                                        + "import android.app.Activity;\n"
                                        + "import android.os.Handler;\n"
                                        + "public class MainActivity extends Activity {\n"
                                        + "    public static volatile MainActivity activeActivity;\n"
                                        + "    public Handler ui;\n"
                                        + "    public PlaybackControlsStub playbackControls;\n"
                                        + "    public static class PlaybackControlsStub {\n"
                                        + "        public void applyExternalDanmaku(String url) {}\n"
                                        + "    }\n"
                                        + "}\n")
                                .getBytes(StandardCharsets.UTF_8));
                Path stubSourceController = stubPkg.resolve("SourceController.java");
                Files.write(
                        stubSourceController,
                        ("package com.pilipala.marcomovie;\n"
                                        + "public final class SourceController {\n"
                                        + "    public static boolean isConfigOrNetdiskSite(Cms.Site s) {\n"
                                        + "        return s != null && s.isNetdiskSite();\n"
                                        + "    }\n"
                                        + "}\n")
                                .getBytes(StandardCharsets.UTF_8));
                Path aarClasses = tempRoot.resolve("wrapper-android-classes.jar");
                try (ZipFile aar =
                        new ZipFile(
                                root.resolve("tools/java-dependencies/wrapper-android-3.2.3.aar")
                                        .toFile())) {
                    ZipEntry entry = aar.getEntry("classes.jar");
                    try (InputStream in = aar.getInputStream(entry)) {
                        Files.copy(in, aarClasses, StandardCopyOption.REPLACE_EXISTING);
                    }
                }

                Path deps = root.resolve("tools/java-dependencies");
                Path jsonJar = root.resolve("android-mobile/tests/lib/json-20240303.jar");
                String envAndroidJar = System.getenv("MARCOMOVIE_ANDROID_JAR");
                Path androidJar =
                        (envAndroidJar != null
                                        && !envAndroidJar.trim().isEmpty()
                                        && Files.isRegularFile(Paths.get(envAndroidJar)))
                                ? Paths.get(envAndroidJar)
                                : root.resolve("tools/android-35/android.jar");
                List<Path> cpEntries =
                        Arrays.asList(
                                jsonJar,
                                androidJar,
                                deps.resolve("okhttp-3.14.9.jar"),
                                deps.resolve("okio-1.17.2.jar"),
                                deps.resolve("gson-2.10.1.jar"),
                                deps.resolve("jsoup-1.18.3.jar"),
                                deps.resolve("jlibtorrent-2.0.12.9.jar"),
                                deps.resolve("wrapper-java-3.2.3.jar"),
                                aarClasses);
                StringBuilder cp = new StringBuilder();
                for (Path entry : cpEntries) {
                    if (cp.length() > 0) cp.append(File.pathSeparator);
                    cp.append(entry.toString());
                }

                Path pkg = root.resolve("android-mobile/src/main/java/com/pilipala/marcomovie");
                List<String> javacArgs =
                        Arrays.asList(
                                "-encoding",
                                "UTF-8",
                                "-source",
                                "8",
                                "-target",
                                "8",
                                "-cp",
                                cp.toString(),
                                "-d",
                                classesDir.toString(),
                                root.resolve("shared/java/com/pilipala/source/Json.java")
                                        .toString(),
                                root.resolve("shared/java/com/pilipala/source/Warehouse.java")
                                        .toString(),
                                root.resolve("shared/java/com/pilipala/catpaw/CatPawHost.java")
                                        .toString(),
                                root.resolve("shared/java/com/pilipala/catpaw/NodeRuntime.java")
                                        .toString(),
                                stubMain.toString(),
                                stubSourceController.toString(),
                                pkg.resolve("TvLayoutPolicy.java").toString(),
                                pkg.resolve("Prefs.java").toString(),
                                pkg.resolve("AppLog.java").toString(),
                                pkg.resolve("LiveQualityPolicy.java").toString(),
                                pkg.resolve("LiveCatalog.java").toString(),
                                pkg.resolve("VideoFilters.java").toString(),
                                pkg.resolve("SourceEngine.java").toString(),
                                pkg.resolve("RequestScope.java").toString(),
                                pkg.resolve("ProxyAddress.java").toString(),
                                pkg.resolve("QuickJsDeadline.java").toString(),
                                pkg.resolve("LocalSourcePackage.java").toString(),
                                pkg.resolve("DrpyEngine.java").toString(),
                                pkg.resolve("LocalProxy.java").toString(),
                                pkg.resolve("MagnetStream.java").toString(),
                                root.resolve(
                                                "android-mobile/src/main/java/com/github/catvod/crawler/Spider.java")
                                        .toString(),
                                root.resolve(
                                                "android-mobile/src/main/java/com/github/catvod/crawler/SpiderApi.java")
                                        .toString(),
                                pkg.resolve("Cms.java").toString(),
                                pkg.resolve("JsEngine.java").toString(),
                                pkg.resolve("CspEngine.java").toString());
                JavaCompiler compiler = ToolProvider.getSystemJavaCompiler();
                ByteArrayOutputStream compilerErr = new ByteArrayOutputStream();
                int rc = compiler.run(null, null, compilerErr, javacArgs.toArray(new String[0]));
                if (rc != 0) {
                    throw new AssertionError(
                            "Module B Android sources failed to compile:\n"
                                    + new String(
                                            compilerErr.toByteArray(), StandardCharsets.UTF_8));
                }
                check(true, "Spider, SpiderApi, CspEngine, Cms, and JsEngine compile at -target 8");

                List<URL> loaderUrls = new ArrayList<>();
                loaderUrls.add(classesDir.toUri().toURL());
                for (Path entry : cpEntries) loaderUrls.add(entry.toUri().toURL());

                try (URLClassLoader cl =
                        new URLClassLoader(
                                loaderUrls.toArray(new URL[0]),
                                ClassLoader.getPlatformClassLoader())) {
                    // 3a. Spider.client() & Spider.safeDns()
                    Class<?> spiderCls = cl.loadClass("com.github.catvod.crawler.Spider");
                    Object client1 = spiderCls.getMethod("client").invoke(null);
                    Object client2 = spiderCls.getMethod("client").invoke(null);
                    check(
                            client1 != null && client1 == client2,
                            "Spider.client() returns non-null global singleton OkHttpClient");
                    int connTimeout =
                            (Integer)
                                    client1.getClass()
                                            .getMethod("connectTimeoutMillis")
                                            .invoke(client1);
                    int readTimeout =
                            (Integer)
                                    client1.getClass()
                                            .getMethod("readTimeoutMillis")
                                            .invoke(client1);
                    boolean followRedir =
                            (Boolean)
                                    client1.getClass().getMethod("followRedirects").invoke(client1);
                    boolean followSslRedir =
                            (Boolean)
                                    client1.getClass()
                                            .getMethod("followSslRedirects")
                                            .invoke(client1);
                    Object safeDns = spiderCls.getMethod("safeDns").invoke(null);
                    Object clientDns = client1.getClass().getMethod("dns").invoke(client1);
                    check(
                            connTimeout == 15000
                                    && readTimeout == 30000
                                    && followRedir
                                    && followSslRedir
                                    && safeDns != null
                                    && safeDns == clientDns,
                            "Spider.client() configures 15s/30s timeouts, redirects, and safeDns()");

                    Method setDoh =
                            spiderCls.getDeclaredMethod("setDohEndpointsForTest", String[].class);
                    setDoh.setAccessible(true);
                    Class<?> dnsInterface = cl.loadClass("okhttp3.Dns");
                    Method lookup = dnsInterface.getMethod("lookup", String.class);
                    try {
                        setDoh.invoke(
                                null,
                                (Object)
                                        new String[] {
                                            "http://127.0.0.1:1/unreachable",
                                            "http://127.0.0.1:" + port + "/dns-wire"
                                        });
                        @SuppressWarnings("unchecked")
                        List<InetAddress> resolved =
                                (List<InetAddress>) lookup.invoke(safeDns, "polluted-wogg.invalid");
                        check(
                                resolved.size() == 1
                                        && "127.0.0.1".equals(resolved.get(0).getHostAddress())
                                        && "polluted-wogg.invalid"
                                                .equals(resolved.get(0).getHostName()),
                                "Spider.safeDns() races DoH endpoints and preserves original SNI host");

                        // Re-query same host before clearing cache: already cached!
                        @SuppressWarnings("unchecked")
                        List<InetAddress> cachedHit =
                                (List<InetAddress>) lookup.invoke(safeDns, "polluted-wogg.invalid");
                        check(
                                cachedHit.size() == 1
                                        && "127.0.0.1".equals(cachedHit.get(0).getHostAddress()),
                                "Spider.safeDns() serves valid DoH record from bounded TTL cache");

                        // Poisoned 0.0.0.0 rejected -> falls back to Dns.SYSTEM (test with
                        // localhost)
                        setDoh.invoke(
                                null,
                                (Object)
                                        new String[] {
                                            "http://127.0.0.1:" + port + "/dns-poisoned"
                                        });
                        @SuppressWarnings("unchecked")
                        List<InetAddress> sysFallback =
                                (List<InetAddress>) lookup.invoke(safeDns, "localhost");
                        check(
                                !sysFallback.isEmpty(),
                                "Spider.safeDns() bypasses/falls back to Dns.SYSTEM cleanly");
                    } finally {
                        setDoh.invoke(null, (Object) new String[0]);
                    }

                    // 3b. SpiderApi.multiReq(JsonArray)
                    Class<?> spiderApiCls = cl.loadClass("com.github.catvod.crawler.SpiderApi");
                    Class<?> jsonParserCls = cl.loadClass("com.google.gson.JsonParser");
                    Class<?> jsonArrayCls = cl.loadClass("com.google.gson.JsonArray");
                    Object spiderApi = spiderApiCls.getDeclaredConstructor().newInstance();
                    String batchJson =
                            new JSONArray()
                                    .put(
                                            new JSONObject()
                                                    .put(
                                                            "url",
                                                            "http://127.0.0.1:"
                                                                    + port
                                                                    + "/api/echo")
                                                    .put(
                                                            "params",
                                                            new JSONObject().put("page", "2"))
                                                    .put(
                                                            "headers",
                                                            new JSONObject().put("X-Tag", "req0")))
                                    .put(
                                            new JSONObject()
                                                    .put(
                                                            "url",
                                                            "http://127.0.0.1:"
                                                                    + port
                                                                    + "/api/echo")
                                                    .put("method", "POST")
                                                    .put("postType", "json")
                                                    .put(
                                                            "data",
                                                            new JSONObject().put("pan", "quark4k")))
                                    .put(
                                            new JSONObject()
                                                    .put(
                                                            "url",
                                                            "http://127.0.0.1:" + port + "/api/bin")
                                                    .put("buffer", 2))
                                    .put(
                                            new JSONObject()
                                                    .put("url", "http://127.0.0.1:1/dead")
                                                    .put("timeout", 500))
                                    .toString();
                    Class<?> jsonElementCls = cl.loadClass("com.google.gson.JsonElement");
                    Object gsonElement =
                            jsonParserCls
                                    .getMethod("parseString", String.class)
                                    .invoke(null, batchJson);
                    Object gsonArray =
                            jsonElementCls.getMethod("getAsJsonArray").invoke(gsonElement);
                    String multiOut =
                            (String)
                                    spiderApiCls
                                            .getMethod("multiReq", jsonArrayCls)
                                            .invoke(spiderApi, gsonArray);
                    JSONArray multiArr = new JSONArray(multiOut);
                    JSONObject r0 = multiArr.getJSONObject(0);
                    JSONObject r0Body = new JSONObject(r0.getString("content"));
                    JSONObject r1 = multiArr.getJSONObject(1);
                    JSONObject r1Body = new JSONObject(r1.getString("content"));
                    JSONObject r2 = multiArr.getJSONObject(2);
                    JSONObject r3 = multiArr.getJSONObject(3);
                    check(
                            multiArr.length() == 4
                                    && r0.getInt("code") == 200
                                    && "page=2".equals(r0Body.getString("query"))
                                    && "req0".equals(r0Body.getString("xTag"))
                                    && r1.getInt("code") == 200
                                    && "POST".equals(r1Body.getString("method"))
                                    && r1Body.getString("body").contains("quark4k")
                                    && r2.getInt("code") == 200
                                    && "Q0FU/w==".equals(r2.getString("content"))
                                    && r3.getInt("code") == 0
                                    && !r3.optString("error").isEmpty(),
                            "SpiderApi.multiReq executes concurrent GET/POST/binary requests in order and isolates failures");

                    // 3c. CspEngine 64 MB cap + 64/32-bit ABI native library extraction & W^X
                    // read-only
                    Class<?> cspCls = cl.loadClass("com.pilipala.marcomovie.CspEngine");
                    Field maxPluginField = cspCls.getDeclaredField("MAX_PLUGIN_BYTES");
                    maxPluginField.setAccessible(true);
                    check(
                            maxPluginField.getInt(null) == 64 * 1024 * 1024,
                            "CspEngine plugin download limit increased to 64 MB");

                    Path mockJar = tempRoot.resolve("mock-spider.jar");
                    try (ZipOutputStream zos =
                            new ZipOutputStream(Files.newOutputStream(mockJar))) {
                        Object[][] entries = {
                            {"classes.dex", "dex".getBytes(StandardCharsets.UTF_8)},
                            {
                                "lib/armeabi-v7a/libgojni.so",
                                "elf32-arm".getBytes(StandardCharsets.UTF_8)
                            },
                            {
                                "lib/arm64-v8a/libgojni.so",
                                "elf64-arm".getBytes(StandardCharsets.UTF_8)
                            },
                            {
                                "jni/arm64-v8a/libpan.so",
                                "elf64-jni".getBytes(StandardCharsets.UTF_8)
                            },
                            {"lib/x86_64/libgojni.so", "elf64-x86".getBytes(StandardCharsets.UTF_8)}
                        };
                        for (Object[] item : entries) {
                            zos.putNextEntry(new ZipEntry((String) item[0]));
                            zos.write((byte[]) item[1]);
                            zos.closeEntry();
                        }
                    }
                    Method extractLibs =
                            cspCls.getDeclaredMethod(
                                    "extractNativeLibraries",
                                    File.class,
                                    File.class,
                                    String[].class,
                                    boolean.class);
                    extractLibs.setAccessible(true);

                    Path libOut64 = tempRoot.resolve("csp-lib-64");
                    String path64 =
                            (String)
                                    extractLibs.invoke(
                                            null,
                                            mockJar.toFile(),
                                            libOut64.toFile(),
                                            new String[] {"arm64-v8a", "armeabi-v7a"},
                                            true);
                    Path so64Main = Paths.get(path64, "libgojni.so");
                    Path so64Jni = Paths.get(path64, "libpan.so");
                    check(
                            path64 != null
                                    && path64.endsWith("arm64-v8a")
                                    && "elf64-arm"
                                            .equals(
                                                    new String(
                                                            Files.readAllBytes(so64Main),
                                                            StandardCharsets.UTF_8))
                                    && "elf64-jni"
                                            .equals(
                                                    new String(
                                                            Files.readAllBytes(so64Jni),
                                                            StandardCharsets.UTF_8))
                                    && !so64Main.toFile().canWrite(),
                            "CspEngine extracts matching 64-bit lib/<abi> and jni/<abi> .so files as read-only");

                    Path libOut32 = tempRoot.resolve("csp-lib-32");
                    String path32 =
                            (String)
                                    extractLibs.invoke(
                                            null,
                                            mockJar.toFile(),
                                            libOut32.toFile(),
                                            new String[] {"arm64-v8a", "armeabi-v7a"},
                                            false);
                    check(
                            path32 != null
                                    && path32.endsWith("armeabi-v7a")
                                    && "elf32-arm"
                                            .equals(
                                                    new String(
                                                            Files.readAllBytes(
                                                                    Paths.get(
                                                                            path32, "libgojni.so")),
                                                            StandardCharsets.UTF_8)),
                            "CspEngine filters out 64-bit ABIs when running in a 32-bit process");

                    Path zipSlipJar = tempRoot.resolve("zipslip.jar");
                    try (ZipOutputStream zos =
                            new ZipOutputStream(Files.newOutputStream(zipSlipJar))) {
                        zos.putNextEntry(new ZipEntry("lib/arm64-v8a/../../escape.so"));
                        zos.write("bad".getBytes(StandardCharsets.UTF_8));
                        zos.closeEntry();
                    }
                    boolean zipSlipRejected = false;
                    try {
                        extractLibs.invoke(
                                null,
                                zipSlipJar.toFile(),
                                tempRoot.resolve("csp-slip").toFile(),
                                new String[] {"arm64-v8a"},
                                true);
                    } catch (InvocationTargetException expected) {
                        zipSlipRejected = expected.getCause() instanceof IOException;
                    }
                    check(zipSlipRejected, "CspEngine rejects Zip-Slip .so traversal entries");

                    // 3d. JsEngine //bb (CATOP) QuickJS bytecode probe/decode & assets://js/lib/
                    // mapping
                    Class<?> jsCls = cl.loadClass("com.pilipala.marcomovie.JsEngine");
                    Method isBb = jsCls.getMethod("isQuickJsBytecode", String.class);
                    Method probeBb = jsCls.getDeclaredMethod("probeQuickJsBytecode", String.class);
                    probeBb.setAccessible(true);
                    Method decodeBb =
                            jsCls.getDeclaredMethod(
                                    "decodeQuickJsBytecode", String.class, byte.class);
                    decodeBb.setAccessible(true);
                    Method resolveLib =
                            jsCls.getDeclaredMethod("resolveAssetLibTarget", String.class);
                    resolveLib.setAccessible(true);

                    // "CATOP" (0x43,0x41,0x54,0x4f,0x50) + [0x10, 0x20, 0x30, 0x40] =>
                    // Base64 "Q0FUT1AQIDBA"
                    String catopScript = "//bbQ0FUT1AQIDBA";
                    check(
                            (Boolean) isBb.invoke(null, catopScript)
                                    && !(Boolean) isBb.invoke(null, "export default {}"),
                            "JsEngine.isQuickJsBytecode detects //bb header");
                    Object probeObj = probeBb.invoke(null, catopScript);
                    Field catopField = probeObj.getClass().getDeclaredField("catopMagic");
                    catopField.setAccessible(true);
                    Field rawLenField = probeObj.getClass().getDeclaredField("rawLength");
                    rawLenField.setAccessible(true);
                    byte[] adapted = (byte[]) decodeBb.invoke(null, catopScript, (byte) 2);
                    check(
                            catopField.getBoolean(probeObj)
                                    && rawLenField.getInt(probeObj) == 9
                                    && Arrays.equals(
                                            adapted, new byte[] {2, 0x10, 0x20, 0x30, 0x40}),
                            "JsEngine probes CATOP magic and adapts //bb bytecode header to runtime BC_VERSION");

                    boolean badBbRejected = false;
                    try {
                        decodeBb.invoke(null, "//bb@@@bad_base64@@@", (byte) 2);
                    } catch (InvocationTargetException expected) {
                        badBbRejected = expected.getCause() instanceof IOException;
                    }
                    check(badBbRejected, "JsEngine rejects corrupted //bb Base64 bytecode cleanly");

                    check(
                            "asset:js-host/cat-lib.mjs"
                                            .equals(
                                                    resolveLib.invoke(
                                                            null, "assets://js/lib/cat.js"))
                                    && "asset:js-host/utils-lib.mjs"
                                            .equals(
                                                    resolveLib.invoke(
                                                            null, "assets://js/lib/utils.js"))
                                    && "asset:js-host/lodash-shim.mjs"
                                            .equals(
                                                    resolveLib.invoke(
                                                            null, "assets://js/lib/lodash.min.js"))
                                    && "asset:js-host/cheerio-bridge.mjs"
                                            .equals(
                                                    resolveLib.invoke(
                                                            null, "assets://js/lib/cheerio.min.js"))
                                    && "asset:js-host/http-shim.mjs"
                                            .equals(
                                                    resolveLib.invoke(
                                                            null, "assets://js/lib/http.js"))
                                    && String.valueOf(
                                                    resolveLib.invoke(
                                                            null, "assets://js/lib/crypto-js.js"))
                                            .startsWith("inline:")
                                    && resolveLib.invoke(null, "assets://js/lib/unknown_custom.js")
                                            == null,
                            "JsEngine maps common assets://js/lib/ netdisk dependencies to local js-host shims");
                }
            } finally {
                deleteTree(tempRoot);
            }
        } finally {
            mockNet.stop(0);
        }
    }
}
