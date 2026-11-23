package com.pilipala.marcomovie;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;
import java.util.Collections;
import java.util.List;
import java.util.Map;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;
import org.json.JSONArray;
import org.json.JSONObject;

public final class CastSearchAndPickerChecks {
    private static int passed;

    private static void check(boolean ok, String label) {
        if (!ok) {
            throw new AssertionError("FAIL: " + label);
        }
        passed++;
    }

    private static String rawHttp(int port, String rawRequest) throws Exception {
        try (Socket s = new Socket("127.0.0.1", port)) {
            s.setSoTimeout(5000);
            OutputStream out = s.getOutputStream();
            out.write(rawRequest.getBytes(StandardCharsets.UTF_8));
            out.flush();
            InputStream in = s.getInputStream();
            ByteArrayOutputStream buf = new ByteArrayOutputStream();
            byte[] b = new byte[4096];
            int n;
            while ((n = in.read(b)) != -1) {
                buf.write(b, 0, n);
            }
            return new String(buf.toByteArray(), StandardCharsets.UTF_8);
        }
    }

    private static void testSourcePickerEdits() throws Exception {
        String rawCfg =
                "{\"sites\":["
                        + "{\"key\":\"alpha\",\"name\":\"一号源\",\"type\":1,\"api\":\"https://alpha.example/api.php/provide/vod/\",\"searchable\":1},"
                        + "{\"key\":\"beta\",\"name\":\"二号源\",\"type\":1,\"api\":\"https://beta.example/api.php/provide/vod/\",\"searchable\":1},"
                        + "{\"key\":\"legacy_jar\",\"name\":\"未兼容插件\",\"type\":3,\"api\":\"csp_LegacyJar\",\"searchable\":1}"
                        + "]}";
        Cms.Config cfg = Cms.parseConfig(rawCfg, "https://sub.example/config.json");
        check(cfg.sites.size() == 3, "initial parsed sites count == 3");

        String alphaId = cfg.sites.get(0).siteId();
        String betaId = cfg.sites.get(1).siteId();
        String jarId = cfg.sites.get(2).siteId();

        JSONObject saved = new JSONObject();
        JSONObject overrides = new JSONObject();
        overrides.put(alphaId, new JSONObject().put("group", "主力4K"));
        overrides.put(
                jarId,
                new JSONObject()
                        .put("name", "修复直连源")
                        .put("group", "备用源")
                        .put("api", "https://repaired.example/api.php/provide/vod/")
                        .put("playUrl", "https://parser.example/?url=")
                        .put("ext", "{\"token\":\"xyz\"}")
                        .put("searchable", false));
        saved.put("overrides", overrides);
        saved.put("removed", new JSONArray().put(betaId));
        saved.put("order", new JSONArray().put(jarId).put(alphaId));

        SourcePicker.applyEditsToConfig(cfg, saved);
        check(cfg.sites.size() == 2, "removed site filtered out");
        Cms.Site first = cfg.sites.get(0);
        Cms.Site second = cfg.sites.get(1);
        check("修复直连源".equals(first.name), "edited site moved first and renamed");
        check("备用源".equals(first.group), "edited site custom group applied");
        check(
                "https://repaired.example/api.php/provide/vod/".equals(first.api),
                "edited site api applied");
        check(
                "csp_LegacyJar".equals(first.originalApi),
                "originalApi preserved for stable identity");
        check(first.siteId().equals(jarId), "siteId remains stable after api override");
        check(first.type == 1, "http JSON CMS api override upgrades site type to 1");
        check(
                "https://parser.example/?url=".equals(first.playUrl) && first.requiresParser,
                "playUrl override applied");
        check(
                first.ext instanceof JSONObject && !first.searchable,
                "JSON ext and searchable override applied");
        check("主力4K".equals(second.group), "alpha group override applied");

        // Re-parse fresh subscription and re-apply same saved profile -> edits survive subscription
        // refresh
        Cms.Config refreshed = Cms.parseConfig(rawCfg, "https://sub.example/config.json");
        SourcePicker.applyEditsToConfig(refreshed, saved);
        check(
                refreshed.sites.size() == 2
                        && "修复直连源".equals(refreshed.sites.get(0).name)
                        && "主力4K".equals(refreshed.sites.get(1).group),
                "overrides and deletions survive subscription refresh");
    }

    private static void testSearchInputServer() throws Exception {
        final AtomicReference<String> pushedKw = new AtomicReference<>("");
        final AtomicBoolean pushedSubmit = new AtomicBoolean(false);
        try (SearchInputServer srv =
                new SearchInputServer(
                        new SearchInputServer.Listener() {
                            @Override
                            public void onKeyword(String keyword, boolean submitNow) {
                                pushedKw.set(keyword);
                                pushedSubmit.set(submitNow);
                            }

                            @Override
                            public List<String> recentKeywords() {
                                return Arrays.asList("流浪地球", "三体");
                            }

                            @Override
                            public String currentKeyword() {
                                return "初始词";
                            }
                        },
                        60000L,
                        new InetSocketAddress("127.0.0.1", 0))) {
            int port = srv.port();
            String host = "127.0.0.1:" + port;

            // 1. Wrong token -> 404
            String r404 =
                    rawHttp(port, "GET /search/wrongtoken HTTP/1.1\r\nHost: " + host + "\r\n\r\n");
            check(
                    r404.startsWith("HTTP/1.1 404 "),
                    "SearchInputServer rejects wrong token with 404");

            // 2. Wrong Host header (DNS rebinding guard) -> 403
            String rBadHost =
                    rawHttp(port, "GET " + srv.path + " HTTP/1.1\r\nHost: evil.example\r\n\r\n");
            check(
                    rBadHost.startsWith("HTTP/1.1 403 "),
                    "SearchInputServer blocks DNS rebinding Host with 403");

            // 3. Valid GET page & state
            String rPage =
                    rawHttp(port, "GET " + srv.path + " HTTP/1.1\r\nHost: " + host + "\r\n\r\n");
            check(
                    rPage.startsWith("HTTP/1.1 200 ") && rPage.contains("流浪地球"),
                    "SearchInputServer renders mobile input HTML with history chips");

            // 4. Cross-site POST blocked by Sec-Fetch-Site & Origin
            String body = "{\"keyword\":\"黑客帝国\",\"submit\":true}";
            byte[] bodyBytes = body.getBytes(StandardCharsets.UTF_8);
            String rCsrf =
                    rawHttp(
                            port,
                            "POST "
                                    + srv.path
                                    + "/push HTTP/1.1\r\nHost: "
                                    + host
                                    + "\r\nSec-Fetch-Site: cross-site\r\nContent-Type: application/json\r\nContent-Length: "
                                    + bodyBytes.length
                                    + "\r\n\r\n"
                                    + body);
            check(rCsrf.startsWith("HTTP/1.1 403 "), "SearchInputServer blocks cross-site POST");

            // 5. Valid same-origin JSON push + 80-codepoint truncation
            StringBuilder longKw = new StringBuilder();
            for (int i = 0; i < 100; i++) longKw.append("剧");
            String okBody =
                    new JSONObject()
                            .put("keyword", longKw.toString())
                            .put("submit", true)
                            .toString();
            byte[] okBytes = okBody.getBytes(StandardCharsets.UTF_8);
            String rPush =
                    rawHttp(
                            port,
                            "POST "
                                    + srv.path
                                    + "/push HTTP/1.1\r\nHost: "
                                    + host
                                    + "\r\nOrigin: http://"
                                    + host
                                    + "\r\nSec-Fetch-Site: same-origin\r\nContent-Type: application/json\r\nContent-Length: "
                                    + okBytes.length
                                    + "\r\n\r\n"
                                    + okBody);
            check(
                    rPush.startsWith("HTTP/1.1 200 "),
                    "SearchInputServer accepts valid same-origin push");
            check(
                    pushedKw.get().codePointCount(0, pushedKw.get().length()) == 80
                            && pushedSubmit.get(),
                    "SearchInputServer caps keyword to 80 codepoints and triggers submit");
        }

        // 6. Expired session -> 410 Gone
        try (SearchInputServer expired =
                new SearchInputServer(
                        (kw, sub) -> {}, -1000L, new InetSocketAddress("127.0.0.1", 0))) {
            int p = expired.port();
            String resp =
                    rawHttp(
                            p,
                            "GET "
                                    + expired.path
                                    + " HTTP/1.1\r\nHost: 127.0.0.1:"
                                    + p
                                    + "\r\n\r\n");
            check(resp.startsWith("HTTP/1.1 410 "), "Expired SearchInputServer returns 410 Gone");
        }
    }

    private static void testCastServiceDlnaAndWeb() throws Exception {
        final AtomicReference<String> openedUrl = new AtomicReference<>("");
        final AtomicReference<String> openedTitle = new AtomicReference<>("");
        final AtomicReference<Map<String, String>> openedHeaders =
                new AtomicReference<>(Collections.emptyMap());
        final AtomicReference<String> transport = new AtomicReference<>("STOPPED");
        final AtomicInteger positionMs = new AtomicInteger(12000);
        final AtomicInteger volumePct = new AtomicInteger(60);
        final AtomicBoolean muted = new AtomicBoolean(false);

        CastService.Bridge bridge =
                new CastService.Bridge() {
                    @Override
                    public void openMedia(
                            String url, String title, Map<String, String> headers, int startMs) {
                        openedUrl.set(url);
                        openedTitle.set(title);
                        openedHeaders.set(headers);
                        transport.set("PLAYING");
                    }

                    @Override
                    public void resume() {
                        transport.set("PLAYING");
                    }

                    @Override
                    public void pause() {
                        transport.set("PAUSED_PLAYBACK");
                    }

                    @Override
                    public void stop() {
                        transport.set("STOPPED");
                    }

                    @Override
                    public void seekTo(int posMs) {
                        positionMs.set(posMs);
                    }

                    @Override
                    public int positionMs() {
                        return positionMs.get();
                    }

                    @Override
                    public int durationMs() {
                        return 3600000;
                    }

                    @Override
                    public String transportState() {
                        return transport.get();
                    }

                    @Override
                    public int getVolumePercent() {
                        return volumePct.get();
                    }

                    @Override
                    public void setVolumePercent(int percent) {
                        volumePct.set(percent);
                    }

                    @Override
                    public boolean isMuted() {
                        return muted.get();
                    }

                    @Override
                    public void setMuted(boolean m) {
                        muted.set(m);
                    }
                };

        try (CastService cast =
                new CastService(
                        "12345678-1234-1234-1234-123456789abc",
                        "客厅测试电视",
                        "10.0.0.8",
                        bridge,
                        false,
                        new InetSocketAddress("127.0.0.1", 0))) {
            int port = cast.httpSocket.getLocalPort();
            String host = "127.0.0.1:" + port;

            // 1. DLNA device description XML
            String devXml =
                    rawHttp(port, "GET /dlna/device.xml HTTP/1.1\r\nHost: " + host + "\r\n\r\n");
            check(
                    devXml.startsWith("HTTP/1.1 200 ")
                            && devXml.contains("客厅测试电视")
                            && devXml.contains("urn:schemas-upnp-org:device:MediaRenderer:1"),
                    "DLNA device.xml exposes MediaRenderer:1 and friendlyName");

            // 2. Browser cross-origin UPnP request blocked with 403
            String dlnaBrowserBlocked =
                    rawHttp(
                            port,
                            "GET /dlna/device.xml HTTP/1.1\r\nHost: "
                                    + host
                                    + "\r\nOrigin: https://evil.example\r\n\r\n");
            check(
                    dlnaBrowserBlocked.startsWith("HTTP/1.1 403 "),
                    "DLNA blocks browser Origin header to prevent LAN UPnP CSRF");

            // 3. XXE DOCTYPE / ENTITY payload rejected with 400
            String xxeSoap =
                    "<?xml version=\"1.0\"?><!DOCTYPE foo [<!ENTITY xxe SYSTEM \"file:///etc/passwd\">]>"
                            + "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\"><s:Body>&xxe;</s:Body></s:Envelope>";
            byte[] xxeBytes = xxeSoap.getBytes(StandardCharsets.UTF_8);
            String rXxe =
                    rawHttp(
                            port,
                            "POST /dlna/control/AVTransport HTTP/1.1\r\nHost: "
                                    + host
                                    + "\r\nSOAPAction: \"urn:schemas-upnp-org:service:AVTransport:1#Stop\""
                                    + "\r\nContent-Type: text/xml\r\nContent-Length: "
                                    + xxeBytes.length
                                    + "\r\n\r\n"
                                    + xxeSoap);
            check(rXxe.startsWith("HTTP/1.1 400 "), "DLNA SOAP parser blocks XXE DOCTYPE payloads");

            // 4. SSRF loopback / file:// URI rejected in SetAVTransportURI
            String ssrfSoap =
                    "<?xml version=\"1.0\" encoding=\"utf-8\"?>"
                            + "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\">"
                            + "<s:Body><u:SetAVTransportURI xmlns:u=\"urn:schemas-upnp-org:service:AVTransport:1\">"
                            + "<InstanceID>0</InstanceID><CurrentURI>http://127.0.0.1:8080/secret.m3u8</CurrentURI>"
                            + "<CurrentURIMetaData></CurrentURIMetaData></u:SetAVTransportURI></s:Body></s:Envelope>";
            byte[] ssrfBytes = ssrfSoap.getBytes(StandardCharsets.UTF_8);
            String rSsrf =
                    rawHttp(
                            port,
                            "POST /dlna/control/AVTransport HTTP/1.1\r\nHost: "
                                    + host
                                    + "\r\nSOAPAction: \"urn:schemas-upnp-org:service:AVTransport:1#SetAVTransportURI\""
                                    + "\r\nContent-Type: text/xml\r\nContent-Length: "
                                    + ssrfBytes.length
                                    + "\r\n\r\n"
                                    + ssrfSoap);
            check(
                    rSsrf.startsWith("HTTP/1.1 500 "),
                    "DLNA SetAVTransportURI rejects loopback SSRF URL");

            // 5. Valid DLNA SetAVTransportURI with DIDL-Lite metadata + Play + Seek +
            // GetPositionInfo + SetVolume
            String didl =
                    "&lt;DIDL-Lite xmlns:dc=&quot;http://dc.example/elements/1.1/&quot;&gt;"
                            + "&lt;item&gt;&lt;dc:title&gt;星际穿越 4K&lt;/dc:title&gt;&lt;/item&gt;&lt;/DIDL-Lite&gt;";
            String setUriSoap =
                    "<?xml version=\"1.0\" encoding=\"utf-8\"?>"
                            + "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\">"
                            + "<s:Body><u:SetAVTransportURI xmlns:u=\"urn:schemas-upnp-org:service:AVTransport:1\">"
                            + "<InstanceID>0</InstanceID>"
                            + "<CurrentURI>https://cdn.example/interstellar/master.m3u8</CurrentURI>"
                            + "<CurrentURIMetaData>"
                            + didl
                            + "</CurrentURIMetaData></u:SetAVTransportURI></s:Body></s:Envelope>";
            byte[] setUriBytes = setUriSoap.getBytes(StandardCharsets.UTF_8);
            String rSetUri =
                    rawHttp(
                            port,
                            "POST /dlna/control/AVTransport HTTP/1.1\r\nHost: "
                                    + host
                                    + "\r\nSOAPAction: \"urn:schemas-upnp-org:service:AVTransport:1#SetAVTransportURI\""
                                    + "\r\nContent-Type: text/xml\r\nContent-Length: "
                                    + setUriBytes.length
                                    + "\r\n\r\n"
                                    + setUriSoap);
            check(
                    rSetUri.startsWith("HTTP/1.1 200 ")
                            && "https://cdn.example/interstellar/master.m3u8"
                                    .equals(openedUrl.get())
                            && "星际穿越 4K".equals(openedTitle.get()),
                    "DLNA SetAVTransportURI extracts DIDL title and opens stream");

            String seekSoap =
                    "<?xml version=\"1.0\" encoding=\"utf-8\"?>"
                            + "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\">"
                            + "<s:Body><u:Seek xmlns:u=\"urn:schemas-upnp-org:service:AVTransport:1\">"
                            + "<InstanceID>0</InstanceID><Unit>REL_TIME</Unit><Target>00:15:30</Target>"
                            + "</u:Seek></s:Body></s:Envelope>";
            byte[] seekBytes = seekSoap.getBytes(StandardCharsets.UTF_8);
            String rSeek =
                    rawHttp(
                            port,
                            "POST /dlna/control/AVTransport HTTP/1.1\r\nHost: "
                                    + host
                                    + "\r\nSOAPAction: \"urn:schemas-upnp-org:service:AVTransport:1#Seek\""
                                    + "\r\nContent-Type: text/xml\r\nContent-Length: "
                                    + seekBytes.length
                                    + "\r\n\r\n"
                                    + seekSoap);
            check(
                    rSeek.startsWith("HTTP/1.1 200 ") && positionMs.get() == 930000,
                    "DLNA Seek REL_TIME 00:15:30 seeks to 930000ms");

            String posSoap =
                    "<?xml version=\"1.0\" encoding=\"utf-8\"?>"
                            + "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\">"
                            + "<s:Body><u:GetPositionInfo xmlns:u=\"urn:schemas-upnp-org:service:AVTransport:1\">"
                            + "<InstanceID>0</InstanceID></u:GetPositionInfo></s:Body></s:Envelope>";
            byte[] posBytes = posSoap.getBytes(StandardCharsets.UTF_8);
            String rPos =
                    rawHttp(
                            port,
                            "POST /dlna/control/AVTransport HTTP/1.1\r\nHost: "
                                    + host
                                    + "\r\nSOAPAction: \"urn:schemas-upnp-org:service:AVTransport:1#GetPositionInfo\""
                                    + "\r\nContent-Type: text/xml\r\nContent-Length: "
                                    + posBytes.length
                                    + "\r\n\r\n"
                                    + posSoap);
            check(
                    rPos.contains("<RelTime>00:15:30</RelTime>")
                            && rPos.contains("<TrackDuration>01:00:00</TrackDuration>"),
                    "DLNA GetPositionInfo reports formatted RelTime and TrackDuration");

            // 6. Token-scoped QR Web Cast push + headers + volume control
            String webPlayJson =
                    new JSONObject()
                            .put("action", "play")
                            .put("url", "https://live.example/channel1.m3u8")
                            .put("title", "网页直投测试")
                            .put("referer", "https://live.example/")
                            .toString();
            byte[] webPlayBytes = webPlayJson.getBytes(StandardCharsets.UTF_8);
            String rWebPlay =
                    rawHttp(
                            port,
                            "POST "
                                    + cast.webCastPath
                                    + "/api HTTP/1.1\r\nHost: "
                                    + host
                                    + "\r\nOrigin: http://"
                                    + host
                                    + "\r\nSec-Fetch-Site: same-origin\r\nContent-Type: application/json\r\nContent-Length: "
                                    + webPlayBytes.length
                                    + "\r\n\r\n"
                                    + webPlayJson);
            check(
                    rWebPlay.startsWith("HTTP/1.1 200 ")
                            && "https://live.example/channel1.m3u8".equals(openedUrl.get())
                            && "网页直投测试".equals(openedTitle.get())
                            && "https://live.example/".equals(openedHeaders.get().get("Referer")),
                    "QR Web Cast API pushes URL, title, and Referer header to bridge");
        }
    }

    private static void testWallpaperUploadServer() throws Exception {
        java.util.concurrent.atomic.AtomicReference<byte[]> receivedBytes =
                new java.util.concurrent.atomic.AtomicReference<>();
        try (WallpaperUploadServer server =
                new WallpaperUploadServer(
                        bytes -> receivedBytes.set(bytes),
                        60_000L,
                        new java.net.InetSocketAddress("127.0.0.1", 0))) {
            int port = server.socket.getLocalPort();
            String path = server.path;
            String host = "127.0.0.1:" + port;

            String html = rawHttp(port, "GET " + path + " HTTP/1.1\r\nHost: " + host + "\r\n\r\n");
            check(
                    html.startsWith("HTTP/1.1 200 ") && html.contains("Marco Movie"),
                    "WallpaperUploadServer serves mobile upload page for valid token");

            String wrongTok =
                    rawHttp(
                            port,
                            "GET /wallpaper/00000000000000000000000000000000 HTTP/1.1\r\nHost: "
                                    + host
                                    + "\r\n\r\n");
            check(
                    wrongTok.startsWith("HTTP/1.1 404 "),
                    "WallpaperUploadServer rejects wrong token with 404");

            String notImgStr = "not-an-image-payload-0123456789";
            byte[] notImg = notImgStr.getBytes(java.nio.charset.StandardCharsets.UTF_8);
            String badOrigin =
                    rawHttp(
                            port,
                            "POST "
                                    + path
                                    + " HTTP/1.1\r\nHost: "
                                    + host
                                    + "\r\nOrigin: http://evil.invalid\r\nContent-Length: "
                                    + notImg.length
                                    + "\r\n\r\n"
                                    + notImgStr);
            check(
                    badOrigin.startsWith("HTTP/1.1 403 "),
                    "WallpaperUploadServer rejects cross-origin POST with 403");

            String tooSmall =
                    rawHttp(
                            port,
                            "POST "
                                    + path
                                    + " HTTP/1.1\r\nHost: "
                                    + host
                                    + "\r\nOrigin: http://"
                                    + host
                                    + "\r\nContent-Length: 5\r\n\r\nhello");
            check(
                    tooSmall.startsWith("HTTP/1.1 413 "),
                    "WallpaperUploadServer rejects tiny payload with 413");

            String badMagic =
                    rawHttp(
                            port,
                            "POST "
                                    + path
                                    + " HTTP/1.1\r\nHost: "
                                    + host
                                    + "\r\nOrigin: http://"
                                    + host
                                    + "\r\nContent-Length: "
                                    + notImg.length
                                    + "\r\n\r\n"
                                    + notImgStr);
            check(
                    badMagic.startsWith("HTTP/1.1 415 "),
                    "WallpaperUploadServer rejects non-image magic bytes with 415");

            byte[] pngPayload =
                    new byte[] {
                        (byte) 0x89,
                        0x50,
                        0x4E,
                        0x47,
                        0x0D,
                        0x0A,
                        0x1A,
                        0x0A,
                        0x00,
                        0x00,
                        0x00,
                        0x0D,
                        0x49,
                        0x48,
                        0x44,
                        0x52,
                        0x00,
                        0x00,
                        0x00,
                        0x01
                    };
            try (java.net.Socket s = new java.net.Socket("127.0.0.1", port)) {
                s.setSoTimeout(3000);
                java.io.OutputStream os = s.getOutputStream();
                String hdr =
                        "POST "
                                + path
                                + " HTTP/1.1\r\nHost: "
                                + host
                                + "\r\nOrigin: http://"
                                + host
                                + "\r\nContent-Type: image/png\r\nContent-Length: "
                                + pngPayload.length
                                + "\r\nConnection: close\r\n\r\n";
                os.write(hdr.getBytes(java.nio.charset.StandardCharsets.UTF_8));
                os.write(pngPayload);
                os.flush();
                java.io.ByteArrayOutputStream resp = new java.io.ByteArrayOutputStream();
                byte[] buf = new byte[1024];
                int n;
                while ((n = s.getInputStream().read(buf)) != -1) resp.write(buf, 0, n);
                String ok = resp.toString("UTF-8");
                check(
                        ok.startsWith("HTTP/1.1 200 ")
                                && receivedBytes.get() != null
                                && receivedBytes.get().length == pngPayload.length,
                        "WallpaperUploadServer accepts valid PNG upload and delivers bytes");
            }
        }
    }

    public static void main(String[] args) throws Exception {
        // Frozen 55799fd backup/reset contract, plus reviewed V17 & TV background/live preferences.
        // Compare identities, not just a count: a removed legacy key must fail too.
        List<String> expectedKeys =
                Arrays.asList(
                        "ui_scale_percent",
                        "nav_scale_percent",
                        "tv_dock_position",
                        "tv_player_style",
                        "startup_animation",
                        "show_hero_banner",
                        "home_ambient",
                        "home_columns",
                        "home_rows",
                        "home_sections",
                        "wallpaper_enabled",
                        "wallpaper_dim",
                        "reduced",
                        "reduced_transparency",
                        "player_engine",
                        "video_output",
                        "decoder_mode",
                        "software_audio",
                        "prefer_aac",
                        "tunneled_playback",
                        "aspect",
                        "buffer_seconds",
                        "play_speed",
                        "auto_next",
                        "repeat_mode",
                        "skip_intro",
                        "skip_outro",
                        "subtitle_size",
                        "subtitle_bottom",
                        "subtitle_style",
                        "subtitle_weight",
                        "subtitle_offset_x",
                        "danmaku_default",
                        "picture_effect",
                        "audio_effect",
                        "search_threads",
                        "search_timeout",
                        "episodes_descending",
                        "tv_navigation_mode",
                        "tv_ambient_percent",
                        "tv_bg_mode",
                        "tv_glow_preset",
                        "tv_glow_color_left",
                        "tv_glow_color_right",
                        "live_high_quality",
                        "live_merge_sources");
        java.util.Set<String> actualKeys = new java.util.HashSet<>(Arrays.asList(Prefs.KEYS));
        check(actualKeys.size() == Prefs.KEYS.length, "preference export/reset keys are unique");
        check(
                actualKeys.equals(new java.util.HashSet<>(expectedKeys)),
                "legacy preference identities preserved with reviewed V17, TV glow, and Live HD additions");
        testSourcePickerEdits();
        testSearchInputServer();
        testWallpaperUploadServer();
        testCastServiceDlnaAndWeb();
        System.out.println(
                "PASS " + passed + " Cast, Search QR, Wallpaper QR & SourcePicker checks");
    }
}
