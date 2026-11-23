import com.pilipala.emby.EmbyLibrary;
import com.pilipala.marcomovie.LiveCatalog;
import com.pilipala.marcomovie.LiveEpgService;
import com.pilipala.marcomovie.LiveQualityPolicy;
import java.io.*;
import java.net.URL;
import java.nio.file.*;
import java.util.*;
import java.util.zip.GZIPOutputStream;
import org.json.*;

public final class LiveCatalogChecks {
    static int count;

    static void check(boolean value, String message) {
        if (!value) throw new AssertionError(message);
        System.out.println("PASS " + message);
        count++;
    }

    static LiveCatalog.Channel first(LiveCatalog.Catalog c) {
        return c.groups.get(0).channels.get(0);
    }

    public static void main(String[] args) throws Exception {
        pluginCatalogues();
        Map<String, String> inherited = new LinkedHashMap<>();
        String wrapper = "proxy://do=live&type=txt&ext=aHR0cHM6Ly9saXN0LnRlc3QvbGl2ZS50eHQ=";
        List<LiveCatalog.Source> wrapped =
                LiveCatalog.sources(
                        "{\"lives\":[{\"group\":\"频道组\",\"ua\":\"Group-UA\",\"channels\":["
                                + "{\"name\":\"目录\",\"urls\":[\""
                                + wrapper
                                + "\",\"https://video.test/direct.m3u8\"]},"
                                + "{\"name\":\"普通频道\",\"url\":\"https://video.test/other.m3u8\"}]}]}",
                        "https://list.test/config.json");
        check(
                wrapped.size() == 2
                        && wrapped.get(0).url.equals(wrapper)
                        && wrapped.get(0).name.equals("目录")
                        && wrapped.get(0).inline == null,
                "legacy TVBox catalogue wrapper becomes its own selectable source");
        check(
                wrapped.get(0).headers.get("User-Agent").equals("Group-UA")
                        && !wrapped.get(0).isLocalProxy(),
                "directory wrapper inherits headers and does not require a plugin host");
        LiveCatalog.Catalog ordinary = LiveCatalog.load(wrapped.get(1));
        check(
                ordinary.channelCount() == 2
                        && ordinary.streamCount() == 2
                        && ordinary.groups.get(0).name.equals("频道组"),
                "extracting directories preserves ordinary channels and legacy group name");
        List<LiveCatalog.Source> plugin =
                LiveCatalog.sources(
                        "{\"lives\":[{\"name\":\"插件\",\"url\":\"http://127.0.0.1:9978/proxy?do=custom&type=txt&ext=owned\"}]}",
                        "");
        check(plugin.get(0).isLocalProxy(), "custom plugin proxy remains a plugin source");
        plugin.get(0).url = "proxy://do=custom&type=txt&ext=owned";
        check(plugin.get(0).isLocalProxy(), "custom proxy scheme starts the local plugin host");
        for (String other :
                new String[] {
                    "http://127.0.0.1:1234/proxy?do=custom",
                    "http://127.0.0.1:9978/proxy-other?do=custom",
                    "https://list.test/proxy?do=custom"
                }) {
            plugin.get(0).url = other;
            check(!plugin.get(0).isLocalProxy(), "unrelated endpoint does not start a plugin host");
        }
        for (String invalid :
                new String[] {
                    "",
                    "@@@",
                    "Z===",
                    "aHR0cHM6Ly9saXN0LnRlc3Qv&ext=duplicate",
                    "ZmlsZTovLy90bXAvbG9jYWwudHh0",
                    "cHJveHk6Ly9kbz1saXZlJnR5cGU9dHh0"
                }) {
            LiveCatalog.Source source = new LiveCatalog.Source();
            source.url = "proxy://do=live&type=txt&ext=" + invalid;
            source.origin = "https://list.test/config.json";
            boolean rejected = false;
            try {
                LiveCatalog.load(source);
            } catch (IOException expected) {
                rejected = expected.getMessage().contains("ext");
            }
            check(rejected, "invalid, recursive or remote-to-local directory reference rejected");
        }
        List<LiveCatalog.Source> declared =
                LiveCatalog.sources(
                        "{\"lives\":[{\"name\":\"Owned\",\"url\":\"list.php\",\"origin\":\"https://origin.test\"}]}",
                        "https://list.test/config.json");
        check(
                declared.get(0).headers.get("Origin").equals("https://origin.test"),
                "TVBox source origin becomes request header");
        LiveCatalog.Catalog originCatalogue =
                LiveCatalog.parse(
                        "{\"groups\":[{\"name\":\"Owned\",\"origin\":\"https://origin.test\",\"channels\":[{\"name\":\"Test\",\"url\":\"https://video.test/live.m3u8\"}]}]}",
                        "https://list.test/config.json",
                        inherited);
        check(
                first(originCatalogue)
                        .streams
                        .get(0)
                        .headers
                        .get("Origin")
                        .equals("https://origin.test"),
                "TVBox group origin inherited by stream");
        inherited.put("User-Agent", "Source-UA");
        String m3u =
                "\uFEFF#EXTM3U x-tvg-url=\"https://epg.test/e.xml\"\n#EXTINF:-1 tvg-id=\"c1\" tvg-logo=\"../logo.png\" group-title=\"News, World\" http-user-agent=\"Channel-UA\",News, live\n#EXTVLCOPT:http-referrer=https://ref.test/\n#KODIPROP:inputstream.adaptive.manifest_type=hls\n../live/a.m3u8\n#EXTINF:-1 group-title=\"Second\",Other\nhttps://video.test/x.m3u8\n";
        LiveCatalog.Catalog c =
                LiveCatalog.parse(m3u, "https://list.test/lists/index.m3u", inherited);
        LiveCatalog.Channel channel = first(c);
        LiveCatalog.Stream stream = channel.streams.get(0);
        check(
                c.groups.size() == 2 && c.channelCount() == 2,
                "M3U grouping and commas inside metadata");
        check(
                channel.name.equals("News, live") && channel.id.equals("c1"),
                "M3U display name and tvg id");
        check(
                channel.logo.equals("https://list.test/logo.png")
                        && stream.url.equals("https://list.test/live/a.m3u8"),
                "relative image and stream URL resolution");
        check(
                stream.headers.get("User-Agent").equals("Channel-UA")
                        && stream.headers.get("Referer").equals("https://ref.test/"),
                "M3U channel header override and VLC referrer");
        check(
                c.groups
                                .get(1)
                                .channels
                                .get(0)
                                .streams
                                .get(0)
                                .headers
                                .get("User-Agent")
                                .equals("Source-UA")
                        && !c.groups
                                .get(1)
                                .channels
                                .get(0)
                                .streams
                                .get(0)
                                .headers
                                .containsKey("Referer"),
                "per-channel headers do not leak into next channel");
        check(
                stream.options.get("inputstream.adaptive.manifest_type").equals("hls")
                        && c.options.containsKey("x-tvg-url"),
                "preserve player metadata and EPG declaration");
        c =
                LiveCatalog.parse(
                        "新闻,#genre#\n测试,http://stream.test/a#https://backup.test/b\n有片段,http://stream.test/a#keep\n选项,https://stream.test/p|User-Agent=UA%2F1&Referer=https%3A%2F%2Fr.test%2F\n",
                        null, inherited);
        check(
                c.groups.get(0).name.equals("新闻") && first(c).streams.size() == 2,
                "TXT group and alternative stream URLs");
        check(
                c.groups.get(0).channels.get(1).streams.get(0).url.endsWith("#keep"),
                "URL fragment preserved instead of split");
        check(
                c.groups
                        .get(0)
                        .channels
                        .get(2)
                        .streams
                        .get(0)
                        .headers
                        .get("User-Agent")
                        .equals("UA/1"),
                "URL pipe options percent decoded");
        c =
                LiveCatalog.parse(
                        "{\"groups\":[{\"name\":\"电视\",\"ua\":\"Group-UA\",\"channels\":[{\"name\":\"A\",\"urls\":[\"a.m3u8\",{\"name\":\"备用\",\"url\":\"b.m3u8\",\"headers\":{\"Referer\":\"https://r.test/\"}}]}]}]}",
                        "https://list.test/index.json",
                        inherited);
        check(
                c.groups.get(0).name.equals("电视") && first(c).streams.size() == 2,
                "TVBox inline groups and array URLs");
        check(
                first(c).streams.get(1).label.equals("备用")
                        && first(c).streams.get(1).headers.get("User-Agent").equals("Group-UA"),
                "inline alternative metadata and inherited headers");
        check(
                first(c).streams.get(1).headers.get("Referer").equals("https://r.test/"),
                "inline per-stream header");
        boolean failed = false;
        try {
            LiveCatalog.parse("<!doctype html><html>upstream error</html>", null, inherited);
        } catch (IOException e) {
            failed = true;
        }
        check(failed, "HTML error response is rejected");
        failed = false;
        try {
            LiveCatalog.parse("#EXTM3U\n#EXTINF:-1,Missing", null, inherited);
        } catch (IOException e) {
            failed = true;
        }
        check(failed, "empty M3U never reported as parsed channel");
        failed = false;
        try {
            LiveCatalog.parse(
                    "#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXTINF:6,\nsegment.ts", null, inherited);
        } catch (IOException e) {
            failed = true;
        }
        check(failed, "HLS media segments are not mistaken for live channels");
        c = LiveCatalog.parse("A,http://media.test/v?token=x$2", null, inherited);
        check(
                first(c).streams.get(0).url.endsWith("token=x$2"),
                "dollar in URL query remains intact");
        byte[] gbkBytes =
                "央视频道,#genre#\nCCTV1综合,http://media.test/cctv1.m3u8\n".getBytes("GB18030");
        LiveCatalog.Catalog gbkCatalog =
                LiveCatalog.parse(
                        LiveCatalog.decodePayloadBytes(gbkBytes, null),
                        "http://media.test/iptv.php",
                        inherited);
        check(
                "央视频道".equals(gbkCatalog.groups.get(0).name)
                        && "CCTV1综合".equals(first(gbkCatalog).name),
                "GB18030/GBK live list bytes without charset header decode cleanly");
        String preVlcM3u =
                "#EXTM3U\n"
                        + "#EXTINF:-1 http-user-agent=\"Leaked-UA\",DanglingWithoutUrl\n"
                        + "#EXTVLCOPT:http-user-agent=AptvPlayer/1.4.10\n"
                        + "#EXTVLCOPT:http-referrer=https://live.test/\n"
                        + "#EXTINF:-1 tvg-name=\"CCTV-5+\" group-title=\"体育\",\n"
                        + "https://media.test/cctv5p.m3u8\n";
        LiveCatalog.Catalog preVlcCatalog =
                LiveCatalog.parse(preVlcM3u, "https://list.test/kimentanm.m3u", inherited);
        LiveCatalog.Channel preVlcCh = first(preVlcCatalog);
        check(
                "CCTV-5+".equals(preVlcCh.name)
                        && "AptvPlayer/1.4.10"
                                .equals(preVlcCh.streams.get(0).headers.get("User-Agent"))
                        && "https://live.test/"
                                .equals(preVlcCh.streams.get(0).headers.get("Referer")),
                "pre-EXTINF EXTVLCOPT preserved and empty trailing title falls back to tvg-name");
        String plainEncoded =
                "notice://placeholder**"
                        + java.util.Base64.getEncoder()
                                .encodeToString(
                                        "卫视频道,https://media.test/ws.m3u8\n".getBytes("UTF-8"));
        LiveCatalog.Catalog plainB64Catalog =
                LiveCatalog.parse(plainEncoded, "https://list.test/enc.txt", inherited);
        check(
                plainB64Catalog.channelCount() == 1 && "卫视频道".equals(first(plainB64Catalog).name),
                "**Base64 live list unwraps even with scheme prefix and without #genre#");
        LiveCatalog.Source origSource = new LiveCatalog.Source();
        origSource.name = "牛播一";
        origSource.url = "http://127.0.0.1:9978/proxy?do=cctva";
        origSource.options.put("playerType", "2");
        LiveCatalog.Source copiedSource = origSource.copy();
        copiedSource.url = "http://127.0.0.1:18888/proxy?do=cctva&_mm_token=abc";
        check(
                "http://127.0.0.1:9978/proxy?do=cctva".equals(origSource.url)
                        && "2".equals(copiedSource.options.get("playerType")),
                "Source.copy isolates local proxy rewrite from cached source URL");
        if (args.length > 1) {
            String base = args[1];
            LiveCatalog.Source s = new LiveCatalog.Source();
            s.url = base + "redirect";
            s.timeoutMs = 4000;
            c = LiveCatalog.load(s);
            check(
                    first(c).streams.get(0).url.equals(base + "media/test.m3u8"),
                    "HTTP relative redirect resolves playlist stream against final URL");
            s.url = base + "failure";
            failed = false;
            try {
                LiveCatalog.load(s);
            } catch (IOException e) {
                failed = e.getMessage().contains("503");
            }
            check(failed, "HTTP failure status retained");
            s.url = base + "loop";
            failed = false;
            try {
                LiveCatalog.load(s);
            } catch (IOException e) {
                failed = e.getMessage().contains("重定向");
            }
            check(failed, "redirect loop bounded");
        }
        // High-definition live TV quality policy & udpxy checks
        check(
                LiveQualityPolicy.canonicalChannelName("CCTV-1 综合 [1080P]").equals("CCTV-1")
                        && LiveQualityPolicy.canonicalChannelName("CCTV01高清").equals("CCTV-1")
                        && LiveQualityPolicy.canonicalChannelName("CCTV-5+ 体育赛事").equals("CCTV-5+")
                        && LiveQualityPolicy.canonicalChannelName("CCTV4K 超高清").equals("CCTV-4K")
                        && LiveQualityPolicy.canonicalChannelName("CCTV-16 奥林匹克").equals("CCTV-16")
                        && LiveQualityPolicy.canonicalChannelName("湖南卫视 FHD").equals("湖南卫视"),
                "channel name normalization merges HD variants while preserving distinct channels");
        check(
                LiveQualityPolicy.normalizeUdpxyBase("udpxy.test:4022/udp/")
                                .equals("http://udpxy.test:4022")
                        && LiveQualityPolicy.rewriteMulticastUrl(
                                        "rtp://@239.253.64.120:5140", "http://udpxy.test:4022")
                                .equals("http://udpxy.test:4022/rtp/239.253.64.120:5140")
                        && LiveQualityPolicy.rewriteMulticastUrl(
                                        "udp://239.0.0.1:8000", "udpxy.test:4022")
                                .equals("http://udpxy.test:4022/udp/239.0.0.1:8000"),
                "udpxy multicast-to-unicast URL rewriting");
        String ipv6Sample = "http://" + "[2001:db8::1]/cctv1.m3u8$IPV6-1080P";
        LiveCatalog.Catalog subLow =
                LiveCatalog.parse(
                        "央视,#genre#\nCCTV-1综合,http://v4.example.test/cctv1_720p.m3u8$720P#"
                                + ipv6Sample
                                + "\n",
                        null,
                        inherited);
        LiveCatalog.Catalog subMulticast =
                LiveCatalog.parse(
                        "#EXTM3U\n#EXTINF:-1 group-title=\"电信组播\",CCTV1HD\nrtp://239.9.9.1:5140\n",
                        null,
                        inherited);
        List<LiveQualityPolicy.NamedCatalog> toMerge =
                Arrays.asList(
                        new LiveQualityPolicy.NamedCatalog("订阅源", subLow),
                        new LiveQualityPolicy.NamedCatalog("组播源", subMulticast));
        LiveCatalog.Catalog mergedNoUdpxy =
                LiveQualityPolicy.mergeCatalogs(toMerge, "", true, Collections.emptyMap(), true);
        LiveCatalog.Channel mergedCctv1 = first(mergedNoUdpxy);
        check(
                mergedCctv1.name.equals("CCTV-1")
                        && mergedCctv1.streams.size() == 3
                        && mergedCctv1.streams.get(0).url.contains("[2001:db8::1]")
                        && mergedCctv1.streams.get(2).url.startsWith("rtp://"),
                "IPv6 1080P stream ranked ahead of 720P and unconfigured multicast");
        LiveCatalog.Catalog mergedNoV6 =
                LiveQualityPolicy.mergeCatalogs(toMerge, "", false, Collections.emptyMap(), true);
        check(
                first(mergedNoV6).streams.get(0).url.contains("v4.example.test"),
                "unreachable IPv6 literal demoted on IPv4-only network");
        LiveCatalog.Catalog mergedWithUdpxy =
                LiveQualityPolicy.mergeCatalogs(
                        toMerge, "http://udpxy.test:4022", true, Collections.emptyMap(), true);
        check(
                first(mergedWithUdpxy).streams.get(0).url.startsWith("rtp://")
                        && LiveQualityPolicy.formatStreamDisplayLabel(
                                        0,
                                        first(mergedWithUdpxy).streams.get(0),
                                        "http://udpxy.test:4022",
                                        Collections.emptyMap())
                                .contains("组播单播"),
                "configured udpxy multicast stream prioritized with unicast badge");
        String metricsJson =
                LiveQualityPolicy.recordStreamSuccess(
                        "{}",
                        "http://v4.example.test/cctv1_720p.m3u8?token=abc123",
                        3840,
                        2160,
                        420,
                        System.currentTimeMillis());
        Map<String, LiveQualityPolicy.Metrics> parsedMetrics =
                LiveQualityPolicy.parseMetrics(metricsJson);
        LiveCatalog.Catalog mergedMeasured =
                LiveQualityPolicy.mergeCatalogs(toMerge, "", true, parsedMetrics, true);
        check(
                first(mergedMeasured).streams.get(0).url.contains("v4.example.test")
                        && LiveQualityPolicy.formatStreamDisplayLabel(
                                        0, first(mergedMeasured).streams.get(0), "", parsedMetrics)
                                .contains("实测4K"),
                "measured 4K resolution cached and prioritized across token changes");
        LiveCatalog.Catalog queryBadgeCat =
                LiveCatalog.parse(
                        "A,http://live.example.test/play.php?id=cctv1$IPV6-1080P", null, inherited);
        check(
                first(queryBadgeCat).streams.get(0).label.equals("IPV6-1080P")
                        && first(queryBadgeCat)
                                .streams
                                .get(0)
                                .url
                                .equals("http://live.example.test/play.php?id=cctv1"),
                "quality badge suffix after query extracted cleanly");
        String dashM3u =
                "#EXTM3U\n"
                        + "#EXTINF:-1 group-title=\"高清DASH\",CCTV-1\n"
                        + "#KODIPROP:inputstream.adaptive.manifest_type=mpd\n"
                        + "#KODIPROP:inputstream.adaptive.license_type=org.w3.clearkey\n"
                        + "#KODIPROP:inputstream.adaptive.license_key=0123456789abcdef0123456789abcdef:fedcba9876543210fedcba9876543210\n"
                        + "https://dash.example.test/cctv1/index.mpd\n";
        LiveCatalog.Catalog dashCat = LiveCatalog.parse(dashM3u, null, inherited);
        LiveCatalog.Stream dashStream = first(dashCat).streams.get(0);
        JSONObject kodiDrm = LiveQualityPolicy.buildDrmFromKodiProps(dashStream.options);
        check(
                LiveQualityPolicy.mimeFromKodiProps(dashStream.options)
                                .equals("application/dash+xml")
                        && kodiDrm != null
                        && "clearkey".equals(kodiDrm.optString("scheme"))
                        && kodiDrm.optString("clearKeyJson").contains("\"kty\":\"oct\"")
                        && !kodiDrm.optString("clearKeyJson").contains("="),
                "KODIPROP ClearKey kid:key normalized to Base64URL JWK without padding");
        if (args.length > 1) {
            String base = args[1];
            JSONObject embySess =
                    new JSONObject()
                            .put("base", base)
                            .put("user", "u1")
                            .put("token", "tok-secret")
                            .put("device", "dev-1");
            EmbyLibrary embyLib = new EmbyLibrary(embySess);
            JSONArray embyChannels = embyLib.liveChannels();
            check(
                    embyChannels.length() == 2
                            && embyChannels.getJSONObject(0).getString("epg").equals("新闻联播")
                            && embyChannels.getJSONObject(1).getString("epg").equals("纪录片 · 第一集")
                            && embyChannels
                                    .getJSONObject(0)
                                    .getString("url")
                                    .startsWith(EmbyLibrary.LIVE_PLAY_PREFIX),
                    "Emby Live TV fetches channels with CurrentProgram EPG");
            JSONObject directRes =
                    embyLib.resolveLiveChannel(
                            embyChannels.getJSONObject(0).getString("url"), false);
            check(
                    directRes
                                    .getString("url")
                                    .contains("/emby/LiveTv/LiveStreamFiles/ls-101/stream.ts")
                            && !directRes.getString("url").contains("api_key=")
                            && directRes
                                    .getJSONObject("header")
                                    .getString("X-Emby-Token")
                                    .equals("tok-secret")
                            && directRes
                                    .getJSONObject("embySession")
                                    .getString("LiveStreamId")
                                    .equals("ls-101"),
                    "Emby Live TV direct stream resolves cleanly with token in header");
            JSONObject openedRes =
                    embyLib.resolveLiveChannel(
                            embyChannels.getJSONObject(1).getString("url"), true);
            check(
                    openedRes.getString("url").contains("/emby/Videos/ch2/live.m3u8")
                            && openedRes
                                    .getJSONObject("embySession")
                                    .getString("LiveStreamId")
                                    .equals("ls-202"),
                    "Emby Live TV RequiresOpening fallback calls LiveStreams/Open");
            embyLib.report(directRes.getJSONObject("embySession"), "Stop", 0, false, true);
            String closedResp;
            try (InputStream in = new URL(base + "emby/closed-live-streams").openStream()) {
                ByteArrayOutputStream buf = new ByteArrayOutputStream();
                byte[] b = new byte[1024];
                int n;
                while ((n = in.read(b)) != -1) buf.write(b, 0, n);
                closedResp = buf.toString("UTF-8");
            }
            check(
                    closedResp.contains("ls-101"),
                    "Emby Live TV stop closes LiveStreamId to release tuner");
        }
        long sampleNow = LiveEpgService.parseXmltvTime("20261119191500 +0800");
        String sampleXml =
                "<?xml version=\"1.0\" encoding=\"UTF-8\"?><tv>"
                        + "<channel id=\"c1\"><display-name>CCTV-1</display-name></channel>"
                        + "<programme start=\"20261119180000 +0800\" stop=\"20261119190000 +0800\" channel=\"c1\"><title>共同关注</title></programme>"
                        + "<programme start=\"20261119190000 +0800\" stop=\"20261119193000 +0800\" channel=\"c1\"><title>新闻联播</title></programme>"
                        + "<programme start=\"20261119193000 +0800\" stop=\"20261119200000 +0800\" channel=\"c1\"><title>焦点访谈</title></programme>"
                        + "</tv>";
        ByteArrayOutputStream gzBuf = new ByteArrayOutputStream();
        try (GZIPOutputStream gz = new GZIPOutputStream(gzBuf)) {
            gz.write(sampleXml.getBytes("UTF-8"));
        }
        LiveEpgService.Guide guide = LiveEpgService.parseXmltv(gzBuf.toByteArray(), sampleNow);
        LiveEpgService.Program curProg = guide.currentProgram("", "", "CCTV1综合 [1080P]", sampleNow);
        List<LiveEpgService.Program> pastProgs =
                guide.pastPrograms("", "", "CCTV1综合 [1080P]", sampleNow, 7);
        List<LiveEpgService.Program> nextProgs =
                guide.upcomingPrograms("", "", "CCTV1综合 [1080P]", sampleNow, 3);
        check(
                curProg != null
                        && curProg.title.equals("新闻联播")
                        && pastProgs.size() == 1
                        && pastProgs.get(0).title.equals("共同关注")
                        && nextProgs.size() == 1
                        && nextProgs.get(0).title.equals("焦点访谈"),
                "gzipped XMLTV EPG matches canonical CCTV channel for live, past, and upcoming programs");
        String catchupBuilt =
                LiveEpgService.buildCatchupUrl(
                        "http://live.example.test/cctv1.m3u8?fmt=hls",
                        "append",
                        "?playseek=${(b)yyyyMMddHHmmss}-${(e)yyyyMMddHHmmss}",
                        pastProgs.get(0).startMs,
                        pastProgs.get(0).stopMs,
                        TimeZone.getTimeZone("GMT+08:00"));
        check(
                catchupBuilt.equals(
                        "http://live.example.test/cctv1.m3u8?fmt=hls&playseek=20261119180000-20261119190000"),
                "IPTV catchup append template expands start/end timestamps cleanly");
        System.out.println("OK " + count + " live checks");
    }

    static void pluginCatalogues() throws Exception {
        String raw =
                "{\"spider\":\"./global.jar;md5;abc\",\"lives\":["
                        + "{\"name\":\"Same\",\"api\":\"./source.js\",\"ext\":\"../data.json\",\"ua\":\"Live-UA\",\"groups\":[]},"
                        + "{\"name\":\"Same\",\"api\":\"csp_Live\",\"jar\":\"./own.jar\",\"url\":\"opaque-input\",\"ext\":{\"mode\":1}}]}";
        List<LiveCatalog.Source> sources =
                LiveCatalog.sources(raw, "https://list.test/folder/config.json");
        check(
                sources.size() == 2 && sources.get(0).url.isEmpty(),
                "api-only live source retained without a catalogue URL");
        LiveCatalog.Source js = sources.get(0), jar = sources.get(1);
        check(
                js.plugin.api.equals("https://list.test/folder/source.js")
                        && js.plugin.ext.equals("https://list.test/data.json")
                        && js.plugin.jar.equals("https://list.test/folder/global.jar;md5;abc"),
                "live plugin resolves API ext and inherited JAR against subscription");
        check(
                jar.plugin.api.equals("csp_Live")
                        && jar.plugin.jar.equals("https://list.test/folder/own.jar")
                        && jar.plugin.ext instanceof org.json.JSONObject,
                "live plugin keeps explicit JAR and structured extension");
        check(
                !js.plugin.key.equals(jar.plugin.key)
                        && js.plugin.key.startsWith("live-plugin:")
                        && js.plugin.key.equals(
                                LiveCatalog.sources(raw, "https://list.test/folder/config.json")
                                        .get(0)
                                        .plugin
                                        .key),
                "same-name live plugins have stable isolated engine identities");
        LiveCatalog.Catalog catalogue =
                LiveCatalog.load(
                        jar,
                        (site, url) -> {
                            if (site != jar.plugin || !url.equals("opaque-input"))
                                throw new AssertionError("dispatch changed");
                            return "Plugin,#genre#\nLocal,https://media.test/a.m3u8";
                        });
        check(
                catalogue.channelCount() == 1 && catalogue.groups.get(0).name.equals("Plugin"),
                "liveContent text reaches ordinary catalogue reader");
        catalogue =
                LiveCatalog.load(
                        js,
                        (site, url) ->
                                "[{\"name\":\"JSON\",\"channels\":[{\"name\":\"Local\",\"url\":\"https://media.test/a.m3u8\"}]}]");
        check(
                first(catalogue).streams.get(0).headers.get("User-Agent").equals("Live-UA"),
                "liveContent JSON inherits source headers");
        boolean missing = false;
        try {
            LiveCatalog.load(js);
        } catch (IOException error) {
            missing = error.getMessage().contains("引擎");
        }
        check(missing, "plugin catalogue never falls back to downloading its input URL");
        boolean failed = false;
        try {
            LiveCatalog.load(
                    js,
                    (site, url) -> {
                        throw new IOException("fixture-failure");
                    });
        } catch (IOException error) {
            failed = error.getMessage().equals("fixture-failure");
        }
        check(failed, "plugin failure remains visible instead of a blank list");
    }
}
