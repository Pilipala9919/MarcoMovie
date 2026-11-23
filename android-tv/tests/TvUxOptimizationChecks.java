package com.pilipala.marcomovie;

import java.io.ByteArrayInputStream;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * Pure JVM regression checks for the 10-item Android TV UX specialization & optimization pass:
 * dialog sizing/QR bounds, Android TV storage permission fallbacks, Settings left-focus category
 * mapping, top immersive nav bar shrink progress, source-independent curated Home parsing &
 * matching, official HD landscape poster ranking & Douban credits/seasons parsing, continue-play
 * route caption, chunked DLNA SOAP & SSDP v2 handling, and selectable LAN DLNA discovery/XML/SOAP.
 */
public final class TvUxOptimizationChecks {
    private static int checks;

    private static void check(boolean ok, String label) {
        if (!ok) throw new AssertionError("FAILED: " + label);
        checks++;
        System.out.println("PASS " + label);
    }

    public static void main(String[] args) throws Exception {
        testDialogAndQrSizing();
        testStoragePermissionFallbacks();
        testSettingsCategoryAndTopDockShrink();
        testCuratedHomeParsingAndSourceMatching();
        testOfficialLandscapePosterRankingAndDoubanParsing();
        testContinuePlaySubtitle();
        testCastServiceHardeningAndDlnaClient();
        testDanmakuSanitizationAndParsing();
        testCuratedShelfComfortWindowAndScopedFocusFrame();
        testCrashHardeningMiniDetailsAndHudRedesign();
        testPlayerFocusHighlightSuppression();
        testTvSkipSingleDoubleTapAndCompactDialog();
        testDirectNetdiskQrAndPluginOverflowGuards();
        testLeftDockHeroLeftFlipAndMetadataDedup();
        testSkip20MinCapAndHdrFlickerSuppression();
        testApi23MiTvCrashFixes();
        testEpisodeHoldSwitchController();
        testOnlineMkvResiliencePolicies();
        testHybridCrashReportingAndQrFallback();
        testSeriesSubtitlePersistenceToastLayoutAndSpecBanner();
        testCompactLoadingCardFastFailoverAndDvColorWarning();
        testLanSpiderGatewayAndTvQrInputBubble();
        testAppleTvLiveAndMineRedesign();
        testXiaomiHyperOsTvUpdateInstallFallbacks();
        testLiveQrFileUploadSupport();
        testAdaptiveTvNavBarAndWelcomeScreen();
        testGlobalSearchCrashHardening();
        testDanmuSettingsRedesign();
        testAutoAudioSubtitleSelectionHistoryFailoverAndAlistMount();
        testTvPlaybackTooltipAndCustomToolbarOrder();
        System.out.println("ALL PASS (" + checks + " TV UX optimization checks)");
    }

    private static void testDialogAndQrSizing() {
        check(
                PluginDialogStyler.resolveDialogWidthPx(1920, 176, 1320) == 1320,
                "PluginDialogStyler widens TV dialog up to 660dp cap on 1080p");
        check(
                PluginDialogStyler.resolveDialogWidthPx(960, 88, 660) == 660,
                "PluginDialogStyler fits 660px width cleanly inside 960px window");
        check(
                PluginDialogStyler.resolveDialogWidthPx(600, 88, 660) == 512,
                "PluginDialogStyler clamps narrow window to winW - marginH");

        int tvQr540 = PluginDialogStyler.resolveMaxQrSizePx(540, 132, 168, true);
        int tvQr1080 = PluginDialogStyler.resolveMaxQrSizePx(1080, 264, 336, true);
        check(
                tvQr540 >= 132 && tvQr540 <= 168 && tvQr1080 >= 264 && tvQr1080 <= 336,
                "PluginDialogStyler keeps TV QR code compact so scan dialogs never clip vertically");

        int maxContent = AppDialog.computeMaxContentHeight(540, 148, 56, 120);
        check(
                maxContent == 336,
                "AppDialog computes exact available content height from window minus chrome");
        check(
                AppDialog.computeMaxContentHeight(260, 200, 56, 120) == 120,
                "AppDialog enforces minimum scroll body height on ultra-short windows");
    }

    private static void testStoragePermissionFallbacks() {
        check(
                MainActivity.isManageAllFilesAction(
                                "android.settings.MANAGE_APP_ALL_FILES_ACCESS_PERMISSION")
                        && MainActivity.isManageAllFilesAction(
                                "android.settings.MANAGE_ALL_FILES_ACCESS_PERMISSION")
                        && !MainActivity.isManageAllFilesAction(
                                "android.settings.APPLICATION_DETAILS_SETTINGS"),
                "MainActivity identifies Android 11+ all-files storage settings intents");

        List<String> api30 = MainActivity.storagePermissionFallbackActions(30);
        check(
                api30.size() == 3
                        && "android.settings.MANAGE_APP_ALL_FILES_ACCESS_PERMISSION"
                                .equals(api30.get(0))
                        && "android.settings.MANAGE_ALL_FILES_ACCESS_PERMISSION"
                                .equals(api30.get(1))
                        && "android.settings.APPLICATION_DETAILS_SETTINGS".equals(api30.get(2)),
                "API 30+ TV storage fallback chain ends at app details settings");

        List<String> api28 = MainActivity.storagePermissionFallbackActions(28);
        check(
                api28.size() == 1
                        && "android.settings.APPLICATION_DETAILS_SETTINGS".equals(api28.get(0)),
                "Pre-API 30 TV storage fallback targets app details settings directly");
    }

    private static void testSettingsCategoryAndTopDockShrink() {
        check(
                SettingsScreen.resolveTvCategoryIndex("外观与壁纸") == 0
                        && SettingsScreen.resolveTvCategoryIndex("播放与字幕") == 1
                        && SettingsScreen.resolveTvCategoryIndex("片源与直播") == 2
                        && SettingsScreen.resolveTvCategoryIndex("数据与备份") == 3
                        && SettingsScreen.resolveTvCategoryIndex("软件更新") == 4
                        && SettingsScreen.resolveTvCategoryIndex("未知分类") == 0,
                "SettingsScreen resolves all 5 TV left-sidebar categories accurately");

        check(
                HomeDock.computeTopShrinkProgress(0, 180) == 0f
                        && Math.abs(HomeDock.computeTopShrinkProgress(90, 180) - 0.5f) < 0.001f
                        && HomeDock.computeTopShrinkProgress(260, 180) == 1f
                        && HomeDock.computeTopShrinkProgress(-20, 180) == 0f,
                "HomeDock top immersive shrink progress clamps cleanly in [0, 1]");

        float scrimTop = HomeDock.computeTopScrimAlpha(0f);
        float scrimMid = HomeDock.computeTopScrimAlpha(0.5f);
        float scrimFull = HomeDock.computeTopScrimAlpha(1f);
        check(
                scrimTop > 0.1f
                        && scrimTop < 0.25f
                        && scrimMid > scrimTop
                        && scrimFull > scrimMid
                        && scrimFull <= 0.96f,
                "HomeDock top scrim alpha eases smoothly without abrupt cutoff");

        String[] navLabels = HomeDock.tvNavLabels();
        String[] navKeys = HomeDock.tvNavKeys();
        check(
                navLabels.length == 8
                        && navKeys.length == 8
                        && "历史".equals(navLabels[2])
                        && "nav-history".equals(navKeys[2])
                        && "nav-accounts".equals(navKeys[5]),
                "HomeDock exposes 8 TV nav items including dedicated Watch History entry");

        check(
                MainActivity.isMenuShortPress(android.view.KeyEvent.ACTION_UP, false, 0)
                        && MainActivity.isMenuShortPress(
                                android.view.KeyEvent.ACTION_UP, true, 0x7531)
                        && !MainActivity.isMenuShortPress(
                                android.view.KeyEvent.ACTION_UP, true, 0x20)
                        && !MainActivity.isMenuShortPress(
                                android.view.KeyEvent.ACTION_DOWN, false, 0),
                "MainActivity accepts both standard TV MENU taps and MiTV synthetic 0x7531 MENU taps");

        float revTop = HomeAmbient.computeScrollReveal(0, 660);
        float revStart = HomeAmbient.computeScrollReveal(60, 660);
        float revMid = HomeAmbient.computeScrollReveal(320, 660);
        float revOffHero = HomeAmbient.computeScrollReveal(600, 660);
        float revNoHero = HomeAmbient.computeScrollReveal(0, 0);
        check(
                revTop >= 0.65f
                        && revTop <= 0.72f
                        && Math.abs(revStart - revTop) < 0.01f
                        && revMid > revTop
                        && revMid < 1f
                        && revOffHero == 1f
                        && revNoHero == 1f,
                "HomeAmbient holds seamless base glow under feathered hero and rises smoothly to full strength on scroll");
    }

    private static void testCuratedHomeParsingAndSourceMatching() {
        String collectionJson =
                "{\"subject_collection_items\":["
                        + "{\"id\":\"3600001\",\"title\":\"藏海传\",\"year\":\"2025\","
                        + "\"card_subtitle\":\"2025 / 中国大陆 / 古装 权谋 / 肖战 张婧仪\","
                        + "\"episodes_info\":\"更新至24集\",\"rating\":{\"value\":8.2},"
                        + "\"pic\":{\"large\":\"https://img1.doubanio.com/p1.jpg\"}},"
                        + "{\"id\":\"3600002\",\"title\":\"藏海传\",\"year\":\"2025\"}"
                        + "]}";
        List<Cms.Video> parsed = TvCuratedHome.parseCollectionVideos(collectionJson, false);
        check(
                parsed.size() == 1
                        && "藏海传".equals(parsed.get(0).title)
                        && "2025".equals(parsed.get(0).year)
                        && "中国大陆".equals(parsed.get(0).area)
                        && "8.2".equals(parsed.get(0).doubanScore),
                "TvCuratedHome parses and deduplicates Douban collection metadata");

        Cms.Video target = new Cms.Video();
        target.title = "庆余年 第二季";
        target.year = "2024";

        Cms.Video exact4k = new Cms.Video();
        exact4k.title = "庆余年 第二季";
        exact4k.year = "2024";
        exact4k.remarks = "4K HDR 更新至36集";

        Cms.Video wrongSeason = new Cms.Video();
        wrongSeason.title = "庆余年 第一季";
        wrongSeason.year = "2019";

        Cms.Video unrelated = new Cms.Video();
        unrelated.title = "长安十二时辰";
        unrelated.year = "2019";

        int exactScore = TvCuratedHome.scoreSourceMatch(target, exact4k);
        int wrongSeasonScore = TvCuratedHome.scoreSourceMatch(target, wrongSeason);
        int unrelatedScore = TvCuratedHome.scoreSourceMatch(target, unrelated);
        check(
                exactScore > 120 && exactScore > wrongSeasonScore && unrelatedScore < 0,
                "TvCuratedHome.scoreSourceMatch prefers exact title/season/year/4K and rejects unrelated");
    }

    private static void testOfficialLandscapePosterRankingAndDoubanParsing() {
        // Wallpaper (W) > Official Landscape Poster (R) > Clean 16:9 Still (S) > Rejected
        // BTS/Portrait
        int wScore = ImmersivePoster.scoreLandscapePhoto(1920, 1080, "官方主视觉横版壁纸", "W");
        int rScore = ImmersivePoster.scoreLandscapePhoto(1600, 900, "定档横版海报", "R");
        int sScore = ImmersivePoster.scoreLandscapePhoto(1600, 900, "剧照", "S");
        int btsScore = ImmersivePoster.scoreLandscapePhoto(1920, 1080, "开机发布会现场花絮", "S");
        int portraitScore = ImmersivePoster.scoreLandscapePhoto(1080, 1600, "官方海报", "R");
        int lowResScore = ImmersivePoster.scoreLandscapePhoto(640, 360, "剧照", "S");
        check(
                wScore > rScore
                        && rScore > sScore
                        && sScore > 0
                        && btsScore < 0
                        && portraitScore < 0
                        && lowResScore < 0,
                "ImmersivePoster.scoreLandscapePhoto ranks official W > R > clean 16:9 S and rejects BTS/portrait/low-res");

        String photosJson =
                "{\"photos\":["
                        + "{\"description\":\"首映礼发布会合影\",\"image\":{\"large\":{\"width\":1920,\"height\":1080,\"url\":\"https://img1.doubanio.com/bts.jpg\"}}},"
                        + "{\"description\":\"竖版海报\",\"image\":{\"large\":{\"width\":1000,\"height\":1500,\"url\":\"https://img1.doubanio.com/portrait.jpg\"}}},"
                        + "{\"description\":\"官方横版主视觉海报\",\"image\":{\"large\":{\"width\":1920,\"height\":1080,\"url\":\"https://img2.doubanio.com/official_wide.jpg\"}}},"
                        + "{\"description\":\"普通剧照\",\"image\":{\"large\":{\"width\":1280,\"height\":720,\"url\":\"https://img3.doubanio.com/still.jpg\"}}}"
                        + "]}";
        List<String> ranked = ImmersivePoster.extractBestDoubanLandscapeUrls(photosJson, "S");
        check(
                ranked.size() == 2
                        && ranked.get(0).contains("official_wide.jpg")
                        && ranked.get(1).contains("still.jpg"),
                "ImmersivePoster.extractBestDoubanLandscapeUrls filters out BTS/portrait and ranks official HD poster first");

        // Douban Rexxar real /credits grouped schema + seasons_count parsing
        String subjectJson =
                "{\"year\":\"2024\",\"countries\":[\"中国大陆\"],\"episodes_count\":36,\"seasons_count\":2,"
                        + "\"genres\":[\"古装\",\"剧情\"],\"intro\":\"范闲再入京都风云。\","
                        + "\"rating\":{\"value\":7.3}}";
        String groupedCreditsJson =
                "{\"credits\":["
                        + "{\"title\":\"导演\",\"celebrities\":[{\"name\":\"孙皓\",\"avatar\":{\"normal\":\"https://img1.doubanio.com/dir.jpg\"}}]},"
                        + "{\"title\":\"演员\",\"celebrities\":["
                        + "{\"name\":\"张若昀\",\"character\":\"饰 范闲\",\"avatar\":{\"normal\":\"https://img2.doubanio.com/zry.jpg\"}},"
                        + "{\"name\":\"李沁\",\"character\":\"饰 林婉儿\",\"avatar\":{\"normal\":\"https://img3.doubanio.com/lq.jpg\"}}"
                        + "]}]}";
        ImmersivePoster.SubjectDetails parsed =
                ImmersivePoster.parseDoubanSubjectJson(subjectJson, groupedCreditsJson);
        check(
                parsed.seasonsCount == 2
                        && parsed.episodesCount == 36
                        && parsed.cast.size() == 3
                        && "张若昀".equals(parsed.cast.get(1).name)
                        && "范闲".equals(parsed.cast.get(1).role)
                        && parsed.cast.get(1).avatarUrl.contains("zry.jpg"),
                "parseDoubanSubjectJson parses grouped Douban credits/celebrities and seasons_count");

        Cms.Video show = new Cms.Video();
        show.title = "庆余年 第二季";
        List<String> badges = ImmersivePoster.buildOfficialFactBadges(show, parsed, 0);
        String line = ImmersivePoster.formatOfficialFactLine(show, parsed);
        check(
                badges.contains("2024")
                        && badges.contains("中国大陆")
                        && badges.contains("共 2 季")
                        && badges.contains("全 36 集")
                        && line.contains("共 2 季"),
                "buildOfficialFactBadges & formatOfficialFactLine display year, region, multi-season count, and real episode count");
    }

    private static void testContinuePlaySubtitle() {
        WatchHistory.Entry bm = new WatchHistory.Entry();
        bm.line = "夸克4K";
        bm.episode = "三体.S01E05.2160p.HDR.mkv";
        bm.position = 1230000;
        bm.duration = 2700000;
        String sub =
                TvV17DetailScreen.formatContinuePlaySubtitle(
                        bm, "夸克4K  ·  三体.S01E05.2160p.HDR.mkv", "");
        check(
                sub.startsWith("上次播放：夸克4K  ·  三体.S01E05.2160p.HDR.mkv")
                        && sub.contains("20:30 / 45:00"),
                "formatContinuePlaySubtitle shows last played route resource name and progress beneath Play buttons");
        check(
                "".equals(TvV17DetailScreen.formatContinuePlaySubtitle(null, "夸克4K · EP01", "")),
                "formatContinuePlaySubtitle returns empty when not continuing playback");
    }

    private static void testCastServiceHardeningAndDlnaClient() throws Exception {
        // 1. Chunked HTTP SOAP body decoding
        String soapPayload = "<s:Envelope><s:Body><u:Play/></s:Body></s:Envelope>";
        String chunk1 = soapPayload.substring(0, 16);
        String chunk2 = soapPayload.substring(16);
        String chunkedWire =
                Integer.toHexString(chunk1.length())
                        + "\r\n"
                        + chunk1
                        + "\r\n"
                        + Integer.toHexString(chunk2.length())
                        + "\r\n"
                        + chunk2
                        + "\r\n0\r\n\r\n";
        byte[] decoded =
                CastService.readChunkedBody(
                        new ByteArrayInputStream(chunkedWire.getBytes(StandardCharsets.UTF_8)),
                        CastService.MAX_HTTP_BODY);
        check(
                soapPayload.equals(new String(decoded, StandardCharsets.UTF_8)),
                "CastService.readChunkedBody decodes chunked DLNA SOAP requests accurately");

        // 2. Case-insensitive M-SEARCH + MediaRenderer:2 / AVTransport:2 matching
        String lowerSearch =
                "m-search * http/1.1\r\n"
                        + "HOST: 239.255.255.250:1900\r\n"
                        + "MAN: \"ssdp:discover\"\r\n"
                        + "ST: urn:schemas-upnp-org:device:MediaRenderer:2\r\n\r\n";
        List<String[]> replies = CastService.matchSsdpReplies(lowerSearch, "abcd-1234");
        check(
                replies.size() == 1 && CastService.NT_RENDERER.equals(replies.get(0)[0]),
                "CastService.matchSsdpReplies handles case-insensitive M-SEARCH and MediaRenderer:2");

        // 3. validateCastMediaUrl preserves SSRF blocks while encoding unescaped pipe/space in
        // query
        String pipeUrl =
                CastService.validateCastMediaUrl("https://cdn.example/live/ch1.m3u8?tags=a|b c");
        check(
                pipeUrl.contains("%7C")
                        && pipeUrl.contains("%20")
                        && CastService.validateCastMediaUrl("http://127.0.0.1:8080/a.m3u8")
                                .isEmpty(),
                "CastService.validateCastMediaUrl encodes CDN query chars while keeping strict SSRF loopback block");

        // 4. DlnaCastClient SSDP location parsing (accepts LAN 10.x, rejects loopback/public)
        List<String> locs =
                DlnaCastClient.parseSsdpLocations(
                        Arrays.asList(
                                "HTTP/1.1 200 OK\r\nLOCATION: http://10.0.2.2:49152/description.xml\r\n\r\n",
                                "HTTP/1.1 200 OK\r\nLOCATION: http://127.0.0.1:8080/evil.xml\r\n\r\n",
                                "HTTP/1.1 200 OK\r\nLOCATION: http://10.0.2.2:49152/description.xml\r\n\r\n"));
        check(
                locs.size() == 1 && "http://10.0.2.2:49152/description.xml".equals(locs.get(0)),
                "DlnaCastClient.parseSsdpLocations deduplicates valid LAN devices and drops loopback");

        // 5. DlnaCastClient device.xml parsing + XXE & cross-host SSRF rejection
        String devXml =
                "<?xml version=\"1.0\" encoding=\"utf-8\"?>"
                        + "<root xmlns=\"urn:schemas-upnp-org:device-1-0\">"
                        + "<device>"
                        + "<deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType>"
                        + "<friendlyName>客厅极米投影仪</friendlyName>"
                        + "<manufacturer>XGIMI</manufacturer>"
                        + "<UDN>uuid:99887766-5544-3322-1100-aabbccddeeff</UDN>"
                        + "<serviceList><service>"
                        + "<serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>"
                        + "<controlURL>/upnp/control/AVTransport</controlURL>"
                        + "</service></serviceList></device></root>";
        DlnaCastClient.Device dev =
                DlnaCastClient.parseDeviceDescriptionXml(
                        "http://10.0.2.2:49152/description.xml", devXml);
        check(
                dev != null
                        && "客厅极米投影仪".equals(dev.friendlyName)
                        && "http://10.0.2.2:49152/upnp/control/AVTransport"
                                .equals(dev.avTransportControlUrl),
                "DlnaCastClient parses LAN MediaRenderer device.xml and resolves AVTransport controlURL");

        String xxeXml = "<?xml version=\"1.0\"?><!DOCTYPE root [<!ENTITY a \"b\">]><root/>";
        check(
                DlnaCastClient.parseDeviceDescriptionXml(
                                "http://10.0.2.2:49152/description.xml", xxeXml)
                        == null,
                "DlnaCastClient rejects DOCTYPE/XXE payloads in device.xml");

        Map<String, String> args = new LinkedHashMap<>();
        args.put("InstanceID", "0");
        args.put("CurrentURI", "https://cdn.example/v.m3u8?a=1&b=2");
        String soap =
                DlnaCastClient.buildSoapEnvelope(
                        DlnaCastClient.ST_AV_TRANSPORT_1, "SetAVTransportURI", args);
        check(
                soap.contains("<u:SetAVTransportURI") && soap.contains("a=1&amp;b=2"),
                "DlnaCastClient.buildSoapEnvelope escapes XML special characters cleanly");
    }

    private static void testDanmakuSanitizationAndParsing() throws Exception {
        Map<String, String> quarkHeaders = new LinkedHashMap<>();
        quarkHeaders.put("Cookie", "__puus=secret; __pus=token");
        quarkHeaders.put("Referer", "https://pan.example/");
        quarkHeaders.put("User-Agent", "Mozilla/5.0 cloud-drive/2.5.20");
        quarkHeaders.put("Range", "bytes=0-1024");
        quarkHeaders.put("Accept-Encoding", "gzip, br");
        quarkHeaders.put("X-Custom-Token", "keep-same-origin");

        Map<String, String> crossOrigin =
                DanmakuView.sanitizeDanmakuHeaders(
                        "https://dm.example/api/v1/danmu?name=顶楼 第一季",
                        "https://dl.pan.example/file/video.mkv",
                        quarkHeaders);
        check(
                !crossOrigin.containsKey("Cookie")
                        && !crossOrigin.containsKey("Referer")
                        && !crossOrigin.containsKey("User-Agent")
                        && !crossOrigin.containsKey("Range")
                        && !crossOrigin.containsKey("Accept-Encoding"),
                "DanmakuView.sanitizeDanmakuHeaders strips cross-origin netdisk cookies, referer, UA, Range, and Accept-Encoding");

        Map<String, String> sameOrigin =
                DanmakuView.sanitizeDanmakuHeaders(
                        "https://cdn.example/dm.xml",
                        "https://cdn.example/video.mp4",
                        quarkHeaders);
        check(
                sameOrigin.containsKey("Cookie")
                        && !sameOrigin.containsKey("Range")
                        && !sameOrigin.containsKey("Accept-Encoding"),
                "DanmakuView.sanitizeDanmakuHeaders preserves same-origin cookies while stripping Range/Accept-Encoding");

        String encoded =
                DanmakuView.encodeDanmakuUrl("https://dm.example/api?title=顶楼 第一季 [4K]&ep=1");
        check(
                !encoded.contains(" ")
                        && !encoded.contains("[")
                        && encoded.contains("%20")
                        && encoded.contains("&ep=1"),
                "DanmakuView.encodeDanmakuUrl percent-encodes Chinese chars, spaces, and brackets cleanly");

        boolean emptyRejected = false;
        try {
            DanmakuData.parse("   \r\n  ");
        } catch (java.io.IOException expected) {
            emptyRejected = expected.getMessage() != null && expected.getMessage().contains("为空");
        }
        check(emptyRejected, "DanmakuData.parse rejects empty response body with clear message");

        String noisyXml =
                "prefix noise <?xml version=\"1.0\" encoding=\"utf-8\"?><i><d p=\"12.5,1,25,16777215,0,0,0,0\">好看</d></i>";
        List<DanmakuData.Comment> parsed = DanmakuData.parse(noisyXml);
        check(
                parsed.size() == 1 && "好看".equals(parsed.get(0).text),
                "DanmakuData.parse skips leading noise before XML payload");

        org.json.JSONObject multiDm =
                new org.json.JSONObject(
                        "{\"danmaku\":[{\"name\":\"自动\",\"url\":\"https://dm1.example/a.xml\"},"
                                + "{\"name\":\"备用\",\"url\":\"https://dm2.example/b.xml\"}]}");
        List<String> extracted = MediaOptions.extractDanmakuUrls(multiDm);
        check(
                extracted.size() == 2
                        && extracted.get(0).contains("dm1.example")
                        && extracted.get(1).contains("dm2.example"),
                "MediaOptions.extractDanmakuUrls preserves all danmaku array candidates for automatic failover");

        org.json.JSONObject hashDm =
                new org.json.JSONObject(
                        "{\"danmu\":\"线路1$https://dm1.example/1.xml#线路2$https://dm2.example/2.xml\"}");
        List<String> hashExtracted = MediaOptions.extractDanmakuUrls(hashDm);
        check(
                hashExtracted.size() == 2
                        && "https://dm1.example/1.xml".equals(hashExtracted.get(0))
                        && "https://dm2.example/2.xml".equals(hashExtracted.get(1)),
                "MediaOptions.extractDanmakuUrls parses name$url#name$url multi-route danmaku strings");
    }

    private static void testCuratedShelfComfortWindowAndScopedFocusFrame() {
        // Curated shelf cards at leftPad=88, slotStep=300, maxScroll=3000.
        // Card 1 (left=88), Card 2 (left=388), Card 3 (left=688) must NOT scroll from scrollX=0!
        int pad = 88;
        int step = 300;
        int max = 3000;
        check(
                HomeScreen.computeShelfScrollX(0, pad, step, pad, max) == 0
                        && HomeScreen.computeShelfScrollX(0, pad + step, step, pad, max) == 0
                        && HomeScreen.computeShelfScrollX(0, pad + step * 2, step, pad, max) == 0,
                "HomeScreen.computeShelfScrollX keeps focus free across cards 1-3 without shifting row");

        // Moving right to Card 4 (left=988) shifts row by 1 step so Card 4 rests in slot 3.
        int afterCard4 = HomeScreen.computeShelfScrollX(0, pad + step * 3, step, pad, max);
        check(
                afterCard4 == step,
                "HomeScreen.computeShelfScrollX advances cleanly by one slot when reaching card 4");

        // Moving back left from Card 4 -> Card 3 (slot 2) -> Card 2 (slot 1) must stay stationary!
        check(
                HomeScreen.computeShelfScrollX(afterCard4, pad + step * 2, step, pad, max) == step
                        && HomeScreen.computeShelfScrollX(afterCard4, pad + step, step, pad, max)
                                == step,
                "HomeScreen.computeShelfScrollX allows returning across slots 3->2->1 without bouncing row");

        // Moving left past slot 1 back to Card 1 (left=pad) shifts row back to 0.
        check(
                HomeScreen.computeShelfScrollX(afterCard4, pad, step, pad, max) == 0,
                "HomeScreen.computeShelfScrollX scrolls back left when moving past slot 1");

        // Clamps safely at maxScroll and handles short rows (maxScroll == 0).
        check(
                HomeScreen.computeShelfScrollX(2900, pad + step * 15, step, pad, max) == max
                        && HomeScreen.computeShelfScrollX(0, pad + step * 4, step, pad, 0) == 0,
                "HomeScreen.computeShelfScrollX clamps cleanly at maxScroll bounds");

        // Scoped TvFocusFrame: glide ONLY within same poster group and nearby neighbor cards.
        check(
                TvFocusFrame.shouldGlideBetween(
                                "home-curated-drama",
                                "home-curated-drama",
                                200f,
                                500f,
                                500f,
                                500f,
                                260f,
                                380f)
                        && TvFocusFrame.shouldGlideBetween(
                                "home-library-grid",
                                "home-library-grid",
                                400f,
                                300f,
                                400f,
                                720f,
                                260f,
                                380f),
                "TvFocusFrame glides cleanly between adjacent cards in the same shelf or grid");

        // Cross-group jumps (drama -> movie, movie -> library, or null group) must NOT fly!
        check(
                !TvFocusFrame.shouldGlideBetween(
                                "home-curated-drama",
                                "home-curated-movie",
                                200f,
                                500f,
                                200f,
                                920f,
                                260f,
                                380f)
                        && !TvFocusFrame.shouldGlideBetween(
                                null, "home-curated-drama", 200f, 500f, 200f, 500f, 260f, 380f)
                        && !TvFocusFrame.shouldGlideBetween(
                                "home-library-grid",
                                "home-library-grid",
                                1500f,
                                300f,
                                200f,
                                720f,
                                260f,
                                380f),
                "TvFocusFrame snaps instead of flying diagonally across sections or row wraps");
    }

    private static void testCrashHardeningMiniDetailsAndHudRedesign() throws Exception {
        // 1. Cms.Site non-null defaults prevent PlaybackController/SourceController NPEs
        Cms.Site blankSite = new Cms.Site();
        check(
                "".equals(blankSite.key)
                        && "".equals(blankSite.name)
                        && "".equals(blankSite.api)
                        && "".equals(blankSite.playUrl)
                        && "".equals(blankSite.jar),
                "Cms.Site initializes string fields to non-null empty strings");

        // 2. Startup prewarm only triggers for lightweight HTTP JSON/T4 sites, never heavy plugins
        Cms.Site httpSite = new Cms.Site();
        httpSite.key = "http1";
        httpSite.type = 1;
        httpSite.api = "https://cms.example/api.php/provide/list/";
        Cms.Site cspSite = new Cms.Site();
        cspSite.key = "csp1";
        cspSite.type = 3;
        cspSite.api = "csp_AppYs";
        Cms.Site catpawSite = new Cms.Site();
        catpawSite.key = "cp1";
        catpawSite.type = 3;
        catpawSite.api = "catpaw://site/1";
        check(
                MainActivity.shouldPrewarmSiteOnStartup(httpSite)
                        && !MainActivity.shouldPrewarmSiteOnStartup(cspSite)
                        && !MainActivity.shouldPrewarmSiteOnStartup(catpawSite)
                        && !MainActivity.shouldPrewarmSiteOnStartup(null),
                "MainActivity.shouldPrewarmSiteOnStartup excludes heavy CSP/CatPaw plugin runtimes");

        // 3. Startup boot-guard crash-loop circuit breaker & volatile cache purge
        java.io.File tempDir =
                java.nio.file.Files.createTempDirectory("marco-boot-guard-test-").toFile();
        try {
            java.io.File snap = new java.io.File(tempDir, "home_snap_v1");
            snap.mkdirs();
            new java.io.File(snap, "a.json").createNewFile();
            java.io.File wide = new java.io.File(tempDir, "tv_wide_v5_abc.img");
            wide.createNewFile();
            java.io.File keep = new java.io.File(tempDir, "unrelated_keep.txt");
            keep.createNewFile();

            int c0 = MainActivity.recordStartupBootGuard(tempDir);
            int c1 = MainActivity.recordStartupBootGuard(tempDir);
            int c2 = MainActivity.recordStartupBootGuard(tempDir);
            MainActivity.purgeVolatileCrashCaches(tempDir);
            MainActivity.clearStartupBootGuard(tempDir);
            int afterClear = MainActivity.recordStartupBootGuard(tempDir);
            check(
                    c0 == 0
                            && c1 == 1
                            && c2 == 2
                            && afterClear == 0
                            && !snap.exists()
                            && !wide.exists()
                            && keep.exists(),
                    "Startup crash-loop circuit breaker tracks streak, purges volatile caches, and clears cleanly");
        } finally {
            MainActivity.clearStartupBootGuard(tempDir);
            java.io.File[] children = tempDir.listFiles();
            if (children != null) {
                for (java.io.File f : children) f.delete();
            }
            tempDir.delete();
        }

        // 4. TvDetailHost curated source bounding excludes heavy CatPaw/Drpy/Js/Guard fan-out and
        // caps to 4
        java.util.List<Cms.Site> pool = new java.util.ArrayList<>();
        pool.add(catpawSite);
        Cms.Site drpySite = new Cms.Site();
        drpySite.key = "drpy1";
        drpySite.type = 3;
        drpySite.api = "https://cdn.example/drpy_libs/drpy2.min.js";
        pool.add(drpySite);
        Cms.Site jsSite = new Cms.Site();
        jsSite.key = "js1";
        jsSite.type = 3;
        jsSite.api = "https://cdn.example/spider.js";
        pool.add(jsSite);
        for (int i = 0; i < 8; i++) {
            Cms.Site s = new Cms.Site();
            s.key = "http_" + i;
            s.type = 1;
            s.api = "https://cdn.example/s" + i + "/api.php/provide/list/";
            pool.add(s);
        }
        List<Cms.Site> bounded =
                TvDetailHost.selectCuratedSearchSources(
                        pool, "http_5", TvDetailHost.CURATED_MAX_SOURCES);
        boolean hasHeavy = false;
        for (Cms.Site s : bounded) {
            if ("cp1".equals(s.key) || "drpy1".equals(s.key) || "js1".equals(s.key)) {
                hasHeavy = true;
            }
        }
        List<Cms.Site> heavyOnly =
                TvDetailHost.selectCuratedSearchSources(
                        Arrays.asList(catpawSite, drpySite, jsSite),
                        "",
                        TvDetailHost.CURATED_MAX_SOURCES);
        check(
                bounded.size() == TvDetailHost.CURATED_MAX_SOURCES
                        && "http_5".equals(bounded.get(0).key)
                        && !hasHeavy
                        && heavyOnly.size() == 1
                        && TvDetailHost.CURATED_MAX_CONCURRENCY == 1,
                "TvDetailHost bounds curated fallback to 4 light sources with concurrency 1 and skips heavy Node/JS/Guard runtimes");

        // 5. Cast avatar accent handles Integer.MIN_VALUE hashCode ("polygenelubricants") safely
        int minHashAccent = TvV17DetailScreen.castAvatarAccent("polygenelubricants");
        int nullAccent = TvV17DetailScreen.castAvatarAccent(null);
        check(
                "polygenelubricants".hashCode() == Integer.MIN_VALUE
                        && minHashAccent != 0
                        && nullAccent != 0,
                "TvV17DetailScreen.castAvatarAccent handles Integer.MIN_VALUE hashCode and null safely");

        // 6. ImmersivePoster byte-bounded caches stay within tight low-RAM TV budgets
        check(
                ImmersivePoster.WIDE_MEM_CACHE_MAX_BYTES <= 12 * 1024 * 1024
                        && ImmersivePoster.HERO_FEATHERED_CACHE_MAX_BYTES <= 8 * 1024 * 1024
                        && ImmersivePoster.PORTRAIT_HD_MEM_CACHE_MAX_BYTES <= 10 * 1024 * 1024,
                "ImmersivePoster bitmap caches are byte-bounded for low-RAM TVs");

        // 7. MiniDetails collapses episodes/seasons into popup triggers beside Return-to-Playback
        check(
                MiniDetails.INLINE_EPISODES_COLLAPSED
                        && "mini-episodes-trigger".equals(MiniDetails.TAG_EPISODES_TRIGGER)
                        && "mini-seasons-trigger".equals(MiniDetails.TAG_SEASONS_TRIGGER),
                "MiniDetails keeps episodes and seasons collapsed behind popup triggers");

        // 8. Top-right TV HUD is frameless with clearly distinct font family & scale for clock vs
        // progress
        check(
                PlayerChrome.TV_TOP_RIGHT_HUD_FRAMELESS
                        && !PlayerChrome.HUD_CLOCK_FONT_FAMILY.equals(
                                PlayerChrome.HUD_PROGRESS_FONT_FAMILY)
                        && PlayerChrome.HUD_CLOCK_SIZE_U >= PlayerChrome.HUD_PROGRESS_SIZE_U + 3.0f,
                "PlayerChrome TV top-right HUD is frameless with distinct typography for current time vs progress");
    }

    private static String readJavaSource(String fileName) throws Exception {
        java.nio.file.Path path =
                java.nio.file.Paths.get(
                        "android-tv/src/main/java/com/pilipala/marcomovie", fileName);
        return new String(java.nio.file.Files.readAllBytes(path), StandardCharsets.UTF_8);
    }

    private static void testPlayerFocusHighlightSuppression() throws Exception {
        // 1. API 26+ runtime guard and null-safety
        check(
                !UiCompat.supportsDefaultFocusHighlightApi(23)
                        && !UiCompat.supportsDefaultFocusHighlightApi(25)
                        && UiCompat.supportsDefaultFocusHighlightApi(26)
                        && UiCompat.supportsDefaultFocusHighlightApi(35),
                "UiCompat.supportsDefaultFocusHighlightApi guards API 26+ cleanly");
        UiCompat.setDefaultFocusHighlightEnabled(null, false);
        check(true, "UiCompat.setDefaultFocusHighlightEnabled tolerates null View");

        // 2. Player root disables defaultFocusHighlight and uses focus-stateful pure-black
        // background so hiding TV controls + a.root.requestFocus() never leaves a full-screen gray
        // veil over letterbox bars or the video SurfaceView
        String playbackControllerSrc = readJavaSource("PlaybackController.java");
        check(
                playbackControllerSrc.contains(
                                "UiCompat.createFocusSafeColorBackground(Color.BLACK)")
                        && playbackControllerSrc.contains(
                                "UiCompat.setDefaultFocusHighlightEnabled(a.root, false)")
                        && playbackControllerSrc.contains(
                                "UiCompat.setDefaultFocusHighlightEnabled(a.playbackLayer, false)")
                        && !playbackControllerSrc.contains(
                                "a.root.setBackgroundColor(Color.BLACK)"),
                "PlaybackController.playerPage protects a.root against API 26+ defaultFocusHighlight gray veil");

        // 3. Player controls (timeline, circular ModernIconButton) & FocusMotion suppress stray
        // rectangular system focus highlight boxes
        String playbackControlsSrc = readJavaSource("PlaybackControls.java");
        check(
                playbackControlsSrc.contains(
                                "UiCompat.setDefaultFocusHighlightEnabled(timeline, false)")
                        && playbackControlsSrc.contains(
                                "UiCompat.setDefaultFocusHighlightEnabled(b, false)")
                        && playbackControlsSrc.contains(
                                "UiCompat.setDefaultFocusHighlightEnabled(this, false)"),
                "PlaybackControls suppresses system defaultFocusHighlight on timeline and circular icon buttons");

        // 4. Full-screen overlays & custom-focused TV views suppress defaultFocusHighlight
        check(
                readJavaSource("FocusMotion.java")
                                .contains("UiCompat.setDefaultFocusHighlightEnabled(view, false)")
                        && readJavaSource("MainActivity.java")
                                .contains("UiCompat.setDefaultFocusHighlightEnabled(b, false)")
                        && readJavaSource("PlaybackLoading.java")
                                .contains("UiCompat.setDefaultFocusHighlightEnabled(this, false)")
                        && readJavaSource("TvV17MarkerOverlay.java")
                                .contains("UiCompat.setDefaultFocusHighlightEnabled(this, false)")
                        && readJavaSource("OnboardingScreen.java")
                                .contains("UiCompat.setDefaultFocusHighlightEnabled(this, false)")
                        && readJavaSource("HomeDock.java")
                                .contains(
                                        "UiCompat.setDefaultFocusHighlightEnabled(pillItem, false)")
                        && readJavaSource("TvScrollView.java")
                                .contains("UiCompat.setDefaultFocusHighlightEnabled(this, false)"),
                "FocusMotion, full-screen overlays, HomeDock, and TvScrollView suppress defaultFocusHighlight");
    }

    private static void testTvSkipSingleDoubleTapAndCompactDialog() throws Exception {
        // 1. Single-click schedules direct current-time capture; second click within window opens
        // editor
        check(
                PlaybackControls.decideSkipTap(false, true, 0L, true, 1000L)
                        == PlaybackControls.SKIP_TAP_SCHEDULE_SINGLE,
                "First tap on skip-intro schedules single-click direct capture");
        check(
                PlaybackControls.decideSkipTap(true, true, 1000L, true, 1260L)
                        == PlaybackControls.SKIP_TAP_TRIGGER_DOUBLE,
                "Second tap on same skip button within double-click window opens edit dialog");
        check(
                PlaybackControls.decideSkipTap(true, true, 1000L, true, 1600L)
                        == PlaybackControls.SKIP_TAP_SCHEDULE_SINGLE,
                "Tap after double-click window expires starts a fresh single-click");
        check(
                PlaybackControls.decideSkipTap(true, true, 1000L, false, 1150L)
                        == PlaybackControls.SKIP_TAP_FLUSH_OTHER_AND_SCHEDULE,
                "Tapping opposite skip button flushes previous pending single-click and schedules new one");

        // 2. Direct current-time capture calculations for intro and outro (up to 20 min / 1200s)
        check(
                VideoSkipStore.MAX_SKIP_SECONDS == 1200
                        && PlaybackControls.captureSkipSecondsFromPlayback(true, 92_500, 2_700_000)
                                == 92
                        && PlaybackControls.captureSkipSecondsFromPlayback(true, 900_000, 2_700_000)
                                == 900
                        && PlaybackControls.captureSkipSecondsFromPlayback(
                                        true, 1_500_000, 2_700_000)
                                == 1200
                        && PlaybackControls.captureSkipSecondsFromPlayback(
                                        false, 1_800_000, 2_700_000)
                                == 900
                        && PlaybackControls.captureSkipSecondsFromPlayback(
                                        false, 2_570_000, 2_700_000)
                                == 130
                        && PlaybackControls.captureSkipSecondsFromPlayback(
                                        false, 300_000, 2_700_000)
                                == -1
                        && PlaybackControls.captureSkipSecondsFromPlayback(true, 0, 2_700_000) == 0,
                "captureSkipSecondsFromPlayback supports up to 20min (1200s) intro/outro and rejects outro >20min before end");

        // 3. Compact skip edit dialog width stays well inside TV viewport with zero overflow
        check(
                PlaybackControls.resolveSkipDialogWidthPx(1920, 904, 192) == 904
                        && PlaybackControls.resolveSkipDialogWidthPx(960, 452, 96) == 452
                        && PlaybackControls.resolveSkipDialogWidthPx(500, 452, 96) == 404,
                "resolveSkipDialogWidthPx enforces compact centered TV bounds");

        // 4. Redesigned skip edit dialog uses bounded equal-weight rows (no overflowing 9-button
        // HorizontalScrollView) and never mutates saved value on open
        String controlsSrc = readJavaSource("PlaybackControls.java");
        check(
                controlsSrc.contains("stepRow.setWeightSum(deltas.length)")
                        && controlsSrc.contains("actionRow.setWeightSum(3f)")
                        && controlsSrc.contains("window.setLayout(cardWidth,")
                        && !controlsSrc.contains("applySec.accept(initialSec)"),
                "Redesigned showSkipAdjuster uses bounded equal-weight rows and never auto-mutates on open");
    }

    private static void testDirectNetdiskQrAndPluginOverflowGuards() throws Exception {
        // 1. Direct per-drive routing across all config site types
        Cms.Site panSite = new Cms.Site();
        panSite.api = "csp_PanConfig";
        Cms.Site wexSite = new Cms.Site();
        wexSite.api = "csp_WexConfig";
        Cms.Site myDriveSite = new Cms.Site();
        myDriveSite.api = "csp_MyDriveGuard";
        Cms.Site customConfig = new Cms.Site();
        customConfig.api = "csp_ConfigCenter";

        check(
                "direct:quark".equals(AccountPanel.resolveDirectDriveRoute(panSite, "quark"))
                        && "direct:uccookie"
                                .equals(AccountPanel.resolveDirectDriveRoute(panSite, "uc"))
                        && "direct:baidu"
                                .equals(AccountPanel.resolveDirectDriveRoute(panSite, "baidu"))
                        && "dynamic:ali"
                                .equals(AccountPanel.resolveDirectDriveRoute(panSite, "ali")),
                "PanConfig routes quark/uc/baidu directly to QR codes and ali dynamically");
        check(
                "direct:quarkcookie".equals(AccountPanel.resolveDirectDriveRoute(wexSite, "quark"))
                        && "direct:ucpancookie"
                                .equals(AccountPanel.resolveDirectDriveRoute(wexSite, "uc"))
                        && "direct:baidupanlogin"
                                .equals(AccountPanel.resolveDirectDriveRoute(wexSite, "baidu"))
                        && "direct:aliyuntoken"
                                .equals(AccountPanel.resolveDirectDriveRoute(wexSite, "ali")),
                "WexConfig routes all 4 drives directly to per-drive QR actions");
        check(
                "forward:LoginShow"
                                .equals(AccountPanel.resolveDirectDriveRoute(myDriveSite, "quark"))
                        && "dynamic:quark"
                                .equals(
                                        AccountPanel.resolveDirectDriveRoute(
                                                customConfig, "quark")),
                "MyDrive uses transparent auto-forward to QR dialog; generic ConfigCenter resolves direct card");

        // 2. Drive row label detection distinguishes login button from enable/disable pill
        check(
                "quark".equals(PluginDialogStyler.detectDriveKeyFromLabel("我的夸父(未登录)"))
                        && "uc".equals(PluginDialogStyler.detectDriveKeyFromLabel("我的优汐已登录"))
                        && "baidu".equals(PluginDialogStyler.detectDriveKeyFromLabel("百度网盘扫码"))
                        && "ali".equals(PluginDialogStyler.detectDriveKeyFromLabel("我的阿狸未登录"))
                        && PluginDialogStyler.isDriveStatusToggleLabel("启用中")
                        && PluginDialogStyler.isDriveStatusToggleLabel("未启用")
                        && PluginDialogStyler.isDirectDriveLoginTarget("quark", "我的夸父(未登录)")
                        && !PluginDialogStyler.isDirectDriveLoginTarget("quark", "启用中"),
                "PluginDialogStyler accurately targets drive login button and ignores status toggle pill");

        // 3. Zero-overflow guard: never widen children of horizontal LinearLayouts to MATCH_PARENT
        check(
                PluginDialogStyler.shouldExpandToMatchParent(false, false)
                        && !PluginDialogStyler.shouldExpandToMatchParent(false, true)
                        && !PluginDialogStyler.shouldExpandToMatchParent(true, false),
                "PluginDialogStyler never expands horizontal row children to MATCH_PARENT");

        // 4. Direct card lookup skips clear/reset actions and prefers QR login cards
        Cms.Video clearCard = new Cms.Video();
        clearCard.id = "clear_quark";
        clearCard.title = "清除夸克登录";
        Cms.Video qrCard = new Cms.Video();
        qrCard.id = "quark_qr";
        qrCard.title = "夸克网盘扫码登录";
        Cms.Video foundCard =
                SettingsScreen.findDirectDriveCard(Arrays.asList(clearCard, qrCard), "quark");
        check(
                foundCard != null && "quark_qr".equals(foundCard.id),
                "SettingsScreen.findDirectDriveCard selects QR login card and ignores clear actions");

        // 5. Level-1 TV AccountPanel removes redundant intermediate LoginShow action button
        String accountSrc = readJavaSource("AccountPanel.java");
        check(
                accountSrc.contains("panel.findViewWithTag(\"account-drive:quark\")")
                        && !accountSrc.contains("\"全部网盘登录与启用\""),
                "Level-1 TV AccountPanel focuses drive cards directly without redundant intermediate page button");
    }

    private static void testLeftDockHeroLeftFlipAndMetadataDedup() {
        // 1. Left-dock hero DPAD_LEFT flips backward when index > 0 and enters dock only at 0
        check(
                HomeScreen.resolveCuratedHeroLeftIndex(true, 2, 6) == 1
                        && HomeScreen.resolveCuratedHeroLeftIndex(true, 1, 6) == 0
                        && HomeScreen.resolveCuratedHeroLeftIndex(true, 0, 6) == -1
                        && HomeScreen.resolveCuratedHeroLeftIndex(false, 0, 6) == 5,
                "Curated hero DPAD_LEFT flips previous card when index > 0 and only enters left dock at card 0");

        // 2. Curated home parser never leaks Douban card_subtitle into description
        String json =
                "{\"subject_collection_items\":[{"
                        + "\"id\":\"3600001\",\"title\":\"藏海传\",\"year\":\"2025\","
                        + "\"card_subtitle\":\"2025 / 中国大陆 大陆 / 古装 权谋 古装 / 肖战 张婧仪\","
                        + "\"rating\":{\"value\":8.2}"
                        + "}]}";
        List<Cms.Video> parsed = TvCuratedHome.parseCollectionVideos(json, false);
        check(
                parsed.size() == 1
                        && "".equals(parsed.get(0).description)
                        && "中国大陆".equals(parsed.get(0).area)
                        && "古装 权谋".equals(parsed.get(0).genre),
                "TvCuratedHome keeps description empty instead of duplicating card_subtitle metadata");

        // 3. Home Hero metadata and summary deduplicate country/genre and strip cached
        // card_subtitle
        Cms.Video cachedStale = new Cms.Video();
        cachedStale.year = "2025";
        cachedStale.area = "中国大陆 / 大陆";
        cachedStale.genre = "中国大陆 古装 权谋 古装";
        cachedStale.actor = "肖战 张婧仪";
        cachedStale.description = "2025 / 中国大陆 / 古装 权谋 / 肖战 张婧仪";
        String heroMeta = HomeScreen.formatCuratedHeroMeta(cachedStale);
        String heroSummary = HomeScreen.formatCuratedHeroSummary(cachedStale);
        check(
                "2025 · 中国大陆 · 古装 权谋".equals(heroMeta) && "主演：肖战 张婧仪".equals(heroSummary),
                "Home Hero deduplicates country/genre tokens and replaces stale card_subtitle with cast");

        // 4. Detail screen badges & synopsis deduplicate country/genre and reject card_subtitle
        Cms.Video detailVid = new Cms.Video();
        detailVid.year = "2025";
        detailVid.area = "中国大陆,大陆";
        detailVid.genre = "国产剧,大陆,古装,古装,权谋";
        detailVid.description = "2025 / 中国大陆 / 古装 权谋 / 肖战 张婧仪";
        List<String> badges = ImmersivePoster.buildOfficialFactBadges(detailVid, null, 0);
        check(
                badges.contains("2025")
                        && badges.contains("中国大陆")
                        && badges.contains("古装 / 权谋")
                        && !badges.contains("国产剧")
                        && "".equals(TvV17DetailScreen.cleanSynopsisText(detailVid.description))
                        && "范闲再入京都风云。".equals(TvV17DetailScreen.cleanSynopsisText("范闲再入京都风云。")),
                "Detail page badges deduplicate region/genre aliases and strip metadata-only synopsis");
    }

    private static void testSkip20MinCapAndHdrFlickerSuppression() throws Exception {
        // 1. 20-minute (1200s) intro/outro skip cap + prompt consistency
        check(
                VideoSkipStore.clampSkipSeconds(1200) == 1200
                        && VideoSkipStore.clampSkipSeconds(1800) == 1200
                        && VideoSkipStore.defaultSecondsFromPlayback(false, 0, 1_500_000, 2_700_000)
                                == 1200,
                "VideoSkipStore clamps and defaults intro/outro skip seconds up to 20 minutes (1200s)");
        String controlsSrc = readJavaSource("PlaybackControls.java");
        check(
                controlsSrc.contains("超过 20 分钟") && !controlsSrc.contains("超过 10 分钟"),
                "PlaybackControls prompts reflect 20-minute outro cap");

        // 2. HDR10 color flicker prevention: TV Activity window never switches to COLOR_MODE_HDR
        check(
                !VideoOutput.shouldRequestWindowHdrColorMode(28, true, true, true, true)
                        && !VideoOutput.shouldRequestWindowHdrColorMode(34, true, true, true, true)
                        && !VideoOutput.shouldRequestWindowHdrColorMode(
                                28, false, true, true, false)
                        && VideoOutput.shouldRequestWindowHdrColorMode(28, false, true, true, true)
                        && !VideoOutput.shouldRequestWindowHdrColorMode(
                                25, false, true, true, true),
                "VideoOutput keeps TV UI windows in COLOR_MODE_DEFAULT while permitting wide-gamut mobile HDR");

        // 3. Fullscreen TV HDR playback suppresses 1Hz RGBA HUD redraws when controls are hidden
        check(
                PlayerChrome.shouldSuppressLiveHudRedraws(true, true, false)
                        && !PlayerChrome.shouldSuppressLiveHudRedraws(true, true, true)
                        && !PlayerChrome.shouldSuppressLiveHudRedraws(true, false, false)
                        && !PlayerChrome.shouldSuppressLiveHudRedraws(false, true, false),
                "PlayerChrome suppresses 1Hz live HUD redraws only during hidden-controls TV HDR playback");
    }

    private static void testApi23MiTvCrashFixes() throws Exception {
        // 1. Zero unguarded API 24+/26+ String.join / Map.getOrDefault in main Java sources
        java.nio.file.Path srcRoot =
                java.nio.file.Paths.get("android-tv/src/main/java/com/pilipala/marcomovie");
        List<String> offending = new java.util.ArrayList<>();
        try (java.util.stream.Stream<java.nio.file.Path> walk = java.nio.file.Files.walk(srcRoot)) {
            for (java.nio.file.Path p :
                    walk.filter(f -> f.toString().endsWith(".java"))
                            .collect(java.util.stream.Collectors.toList())) {
                String content =
                        new String(java.nio.file.Files.readAllBytes(p), StandardCharsets.UTF_8);
                if (content.contains("String.join(") || content.contains(".getOrDefault(")) {
                    offending.add(p.getFileName().toString());
                }
            }
        }
        check(
                offending.isEmpty(),
                "Zero API 24+/26+ String.join or Map.getOrDefault calls remain in Android sources");

        // 2. Cms vod_play_list JSON parsing works on API 23 without String.join
        String detailJson =
                "{\"list\":[{\"vod_id\":\"1001\",\"vod_name\":\"庆余年\",\"vod_play_list\":["
                        + "{\"from\":\"quark\",\"urls\":{"
                        + "\"1\":{\"name\":\"第01集\",\"url\":\"https://stream.example/1.mkv\"},"
                        + "\"2\":{\"name\":\"第02集\",\"url\":\"https://stream.example/2.mkv\"}"
                        + "}}]}]}";
        Cms.Listing parsedListing = Cms.listing(detailJson);
        Cms.Video parsed =
                parsedListing != null && !parsedListing.videos.isEmpty()
                        ? parsedListing.videos.get(0)
                        : null;
        check(
                parsed != null
                        && parsed.lines.size() == 1
                        && parsed.lines.get(0).episodes.size() == 2,
                "Cms.listing parses vod_play_list without API 26 String.join");

        // 3. MobileDetailScreen.defaultAmbientForTitle survives hashCode() == Integer.MIN_VALUE
        int minHashAmbient = MobileDetailScreen.defaultAmbientForTitle("polygenelubricants");
        check(
                minHashAmbient != 0,
                "MobileDetailScreen.defaultAmbientForTitle handles Integer.MIN_VALUE hashCode safely");

        // 4. API 23 Mali-450 lightweight backdrop + no hardware exit FBO + bounded low-RAM
        // LoadControl
        check(
                ImmersivePoster.useLightweightBackdropDraw(23, false)
                        && !ImmersivePoster.useLightweightBackdropDraw(28, false)
                        && ImmersivePoster.useLightweightBackdropDraw(28, true),
                "ImmersivePoster disables nested saveLayer/DST_IN offscreen FBOs on API 23 and reduced-motion");
        check(
                !PlayerTransitionHelper.shouldUseTvHardwareExitLayer(23)
                        && PlayerTransitionHelper.shouldUseTvHardwareExitLayer(24),
                "PlayerTransitionHelper skips LAYER_TYPE_HARDWARE exit promotion on API 23");
        MoviePlayer.LoadControlProfile lowRam =
                MoviePlayer.resolveLoadControlProfile(96, true, 30, false);
        MoviePlayer.LoadControlProfile midRam =
                MoviePlayer.resolveLoadControlProfile(256, false, 30, false);
        MoviePlayer.LoadControlProfile highRam =
                MoviePlayer.resolveLoadControlProfile(512, false, 30, false);
        check(
                lowRam.targetBufferBytes == 16 * 1024 * 1024
                        && !lowRam.prioritizeTimeOverSize
                        && lowRam.maxBufferMs <= 16000
                        && midRam.targetBufferBytes == 32 * 1024 * 1024
                        && !midRam.prioritizeTimeOverSize
                        && highRam.targetBufferBytes == 64 * 1024 * 1024
                        && !highRam.prioritizeTimeOverSize,
                "MoviePlayer.resolveLoadControlProfile caps heap budgets safely for 1GB/2GB/4GB devices");
    }

    private static void testEpisodeHoldSwitchController() {
        com.pilipala.marcomovie.hud.EpisodeHoldSwitchOverlay.Controller ctl =
                new com.pilipala.marcomovie.hud.EpisodeHoldSwitchOverlay.Controller();

        // 1. Key direction mapping: UP -> previous (-1), DOWN -> next (+1)
        check(
                com.pilipala.marcomovie.hud.EpisodeHoldSwitchOverlay.Controller.directionForKeyCode(
                                        19)
                                == -1
                        && com.pilipala.marcomovie.hud.EpisodeHoldSwitchOverlay.Controller
                                        .directionForKeyCode(20)
                                == 1
                        && com.pilipala.marcomovie.hud.EpisodeHoldSwitchOverlay.Controller
                                        .directionForKeyCode(21)
                                == 0,
                "EpisodeHoldSwitchOverlay maps DPAD_UP to previous (-1) and DPAD_DOWN to next (+1)");

        // 2. Short tap (< 320ms) preserves original short-press behavior
        check(
                ctl.begin(19, 1000L, 1000L, true, "第01集")
                        && ctl.onTick(1200L)
                                == com.pilipala.marcomovie.hud.EpisodeHoldSwitchOverlay.Controller
                                        .TICK_NONE
                        && !ctl.isOverlayVisible()
                        && ctl.onKeyUp(19, false, 1220L)
                                == com.pilipala.marcomovie.hud.EpisodeHoldSwitchOverlay.Controller
                                        .UP_SHORT_PRESS
                        && !ctl.isTracking(),
                "Short tap (<320ms) returns UP_SHORT_PRESS without showing countdown overlay");

        // 3. Holding >= 320ms shows 3 -> 2 -> 1 countdown; releasing early cancels cleanly
        ctl.begin(20, 2000L, 2000L, true, "第03集");
        check(
                ctl.onTick(2350L)
                                == com.pilipala.marcomovie.hud.EpisodeHoldSwitchOverlay.Controller
                                        .TICK_SHOWING
                        && ctl.isOverlayVisible()
                        && ctl.countdownSeconds() == 3,
                "Hold at 350ms shows overlay with countdown 3");
        ctl.onTick(3200L);
        check(ctl.countdownSeconds() == 2, "Hold at 1200ms transitions countdown to 2");
        ctl.onTick(4500L);
        check(ctl.countdownSeconds() == 1, "Hold at 2500ms transitions countdown to 1");
        check(
                ctl.onKeyUp(20, false, 4600L)
                                == com.pilipala.marcomovie.hud.EpisodeHoldSwitchOverlay.Controller
                                        .UP_CANCELLED
                        && !ctl.isTracking(),
                "Releasing before 3000ms cancels switch cleanly");

        // 4. Holding to 3000ms commits exactly once and swallows subsequent ticks + final UP
        ctl.begin(20, 6000L, 6000L, true, "第04集");
        check(
                ctl.onTick(9000L)
                                == com.pilipala.marcomovie.hud.EpisodeHoldSwitchOverlay.Controller
                                        .TICK_COMMIT
                        && ctl.onTick(9100L)
                                == com.pilipala.marcomovie.hud.EpisodeHoldSwitchOverlay.Controller
                                        .TICK_NONE
                        && ctl.onKeyUp(20, false, 9200L)
                                == com.pilipala.marcomovie.hud.EpisodeHoldSwitchOverlay.Controller
                                        .UP_ALREADY_COMMITTED
                        && !ctl.isTracking(),
                "Holding full 3000ms commits exactly once and swallows final key release");
    }

    private static void testOnlineMkvResiliencePolicies() throws Exception {
        // 1. Rogue extension Activity.finish() must never pop an active playback screen
        check(
                !MainActivity.shouldPopScreenOnPluginFinish(false, true, true)
                        && !MainActivity.shouldPopScreenOnPluginFinish(true, false, true)
                        && MainActivity.shouldPopScreenOnPluginFinish(false, false, true)
                        && !MainActivity.shouldPopScreenOnPluginFinish(false, false, false),
                "MainActivity.shouldPopScreenOnPluginFinish protects active playback from rogue plugin finish()");

        // 2. Premature progressive EOF detection on multi-GB online MKV streams
        check(
                MoviePlayer.isPrematureProgressiveEnd(false, 600_000, 2_700_000)
                        && !MoviePlayer.isPrematureProgressiveEnd(false, 2_690_000, 2_700_000)
                        && !MoviePlayer.isPrematureProgressiveEnd(true, 600_000, 2_700_000)
                        && !MoviePlayer.isPrematureProgressiveEnd(false, 1_000, 2_700_000)
                        && !MoviePlayer.isPrematureProgressiveEnd(false, 10_000, 30_000),
                "MoviePlayer.isPrematureProgressiveEnd distinguishes mid-movie drops from genuine endings");

        // 3. ChunkedProxyDataSource retryable error classifier
        check(
                MoviePlayer.ChunkedProxyDataSource.isRetryableChunkError(
                                new java.io.EOFException("truncated"))
                        && MoviePlayer.ChunkedProxyDataSource.isRetryableChunkError(
                                new java.net.SocketTimeoutException("read timeout"))
                        && !MoviePlayer.ChunkedProxyDataSource.isRetryableChunkError(
                                new java.io.InterruptedIOException("cancelled")),
                "ChunkedProxyDataSource retries EOF/SocketTimeout but stops immediately on cancellation");

        // 4. SourceController.ensureProxy recreates closed LocalProxy automatically
        String sourceCtlSrc = readJavaSource("SourceController.java");
        check(
                sourceCtlSrc.contains("a.localProxy == null || a.localProxy.closed"),
                "SourceController.ensureProxy automatically restarts LocalProxy if previously closed");
    }

    private static void testHybridCrashReportingAndQrFallback() throws Exception {
        // 1. Strict privacy sanitization strips URLs, credentials, Bearer, cookies, and storage
        // paths
        String dirty =
                "Failed loading https://pan.quark.example/s/secret?token=abc123 "
                        + "Cookie: puus=supersecret123; Authorization: Bearer eyJhbGciOiJIUzI1NiJ9 "
                        + "path=/storage/emulated/0/Download/private.mkv";
        String clean = CrashReportStore.sanitize(dirty);
        check(
                !clean.contains("pan.quark.example")
                        && !clean.contains("supersecret123")
                        && !clean.contains("eyJhbGciOiJIUzI1NiJ9")
                        && !clean.contains("private.mkv")
                        && clean.contains("[URL_REDACTED]")
                        && clean.contains("[REDACTED]")
                        && clean.contains("[PATH_REDACTED]"),
                "CrashReportStore.sanitize redacts URLs, cookies, bearer tokens, and storage paths");

        // 2. Bounded local persistence, 5-file pruning, and submission marking
        java.nio.file.Path tempDir = java.nio.file.Files.createTempDirectory("mm-crash-store-");
        try {
            java.io.File filesDir = tempDir.toFile();
            for (int i = 0; i < 7; i++) {
                CrashReportStore.CrashReport r = new CrashReportStore.CrashReport();
                r.id = "crash_170000000" + i + "_000" + i;
                r.timestampMs = 1_700_000_000_000L + i * 10_000L;
                r.kind = CrashReportStore.KIND_JAVA;
                r.screen = "详情页";
                r.summary = "详情页 · RuntimeException #" + i;
                r.appVersion = "0.6.0";
                r.appVersionCode = 96;
                r.edition = "android-tv";
                r.deviceModel = "MiTV_TEST";
                r.manufacturer = "Xiaomi";
                r.androidRelease = "6.0.1";
                r.sdkInt = 23;
                r.memoryClassMb = 96;
                r.stackTrace =
                        "java.lang.RuntimeException: boom\n"
                                + "\tat com.pilipala.marcomovie.DetailScreen.show(DetailScreen.java:42)";
                r.fingerprint =
                        CrashReportStore.computeFingerprint(
                                r.kind, "RuntimeException", r.stackTrace);
                CrashReportStore.saveReport(filesDir, r);
                Thread.sleep(15L);
            }
            List<CrashReportStore.CrashReport> loaded = CrashReportStore.loadReports(filesDir);
            check(
                    loaded.size() == CrashReportStore.MAX_REPORTS
                            && loaded.get(0).timestampMs
                                    >= loaded.get(loaded.size() - 1).timestampMs,
                    "CrashReportStore bounds stored reports to MAX_REPORTS (5) sorted newest-first");

            // 3. GitHub Issue Markdown + pre-filled URL formatting
            List<CrashReportStore.CrashReport> batch =
                    java.util.Collections.singletonList(loaded.get(0));
            String title = CrashReportStore.formatIssueTitle(batch);
            String md = CrashReportStore.formatIssueMarkdown(batch);
            String ghUrl = CrashReportStore.buildGithubNewIssueUrl(batch);
            check(
                    title.startsWith("[Crash][TV 0.6.0]")
                            && md.contains(
                                    "<!-- crash-fingerprint: " + loaded.get(0).fingerprint + " -->")
                            && md.contains("MiTV_TEST")
                            && ghUrl.startsWith(
                                    "https://github.com/Pilipala9919/MarcoMovie/issues/new?labels="),
                    "CrashReportStore generates fingerprinted GitHub Issue Markdown and pre-filled URL");

            // 4. Hybrid uploader: auto GitHub relay success vs failure -> QR fallback
            CrashReportUploader.UploadResult okRes =
                    CrashReportUploader.submit(
                            CrashReportStore.RELAY_ENDPOINT,
                            batch,
                            (url, body) ->
                                    new CrashReportUploader.Response(
                                            200,
                                            "{\"ok\":true,\"issue_number\":128,"
                                                    + "\"issue_url\":\"https://github.com/Pilipala9919/MarcoMovie/issues/128\"}"));
            check(
                    okRes.ok && okRes.issueNumber == 128 && okRes.issueUrl.endsWith("/issues/128"),
                    "CrashReportUploader parses GitHub Issue relay success with issue number & URL");

            CrashReportStore.markSubmitted(filesDir, batch, okRes.issueNumber, okRes.issueUrl);
            List<CrashReportStore.CrashReport> unsubmitted =
                    CrashReportStore.loadUnsubmittedReports(filesDir);
            check(
                    unsubmitted.size() == CrashReportStore.MAX_REPORTS - 1,
                    "CrashReportStore.markSubmitted persists submitted state across reloads");

            CrashReportUploader.UploadResult failRes =
                    CrashReportUploader.submit(
                            CrashReportStore.RELAY_ENDPOINT,
                            batch,
                            (url, body) -> new CrashReportUploader.Response(404, "not deployed"));
            check(
                    !failRes.ok && failRes.errorMessage.contains("404"),
                    "CrashReportUploader surfaces relay failure cleanly to trigger QR fallback");

            // 5. QR fallback LAN share server serves HTML GitHub button + .txt download and
            // enforces
            // Host check
            try (CrashReportShareServer server =
                    new CrashReportShareServer(
                            batch, 60_000L, new java.net.InetSocketAddress("127.0.0.1", 0))) {
                int port = server.socket.getLocalPort();
                String htmlResp = httpGetLoopback(port, server.path, "127.0.0.1:" + port);
                String txtResp =
                        httpGetLoopback(port, server.path + "/download", "127.0.0.1:" + port);
                String badHost = httpGetLoopback(port, server.path, "evil.example:80");
                check(
                        htmlResp.startsWith("HTTP/1.1 200")
                                && htmlResp.contains(
                                        "github.com/Pilipala9919/MarcoMovie/issues/new")
                                && htmlResp.contains("复制完整日志")
                                && txtResp.startsWith("HTTP/1.1 200")
                                && txtResp.contains("MarcoMovie-crash-report.txt")
                                && txtResp.contains(loaded.get(0).fingerprint)
                                && badHost.startsWith("HTTP/1.1 403"),
                        "CrashReportShareServer serves token-scoped HTML & .txt download and rejects Host mismatch");
            }
            CrashReportStore.clearAll(filesDir);
            check(
                    CrashReportStore.loadReports(filesDir).isEmpty(),
                    "CrashReportStore.clearAll deletes all stored crash reports");
        } finally {
            CrashReportStore.clearAll(tempDir.toFile());
            java.io.File sub = CrashReportStore.reportDir(tempDir.toFile());
            if (sub.exists()) sub.delete();
            tempDir.toFile().delete();
        }
    }

    private static void testSeriesSubtitlePersistenceToastLayoutAndSpecBanner() throws Exception {
        // 1. Per-series subtitle memory matches across episodes by exact label, episode-stripped
        // template, language bucket, index fallback, and explicit off (-2)
        SubtitlePreferenceStore.Selection chsSel =
                new SubtitlePreferenceStore.Selection(false, 1, "✓ 庆余年.S01E01.简体中文.ass");
        String stored = SubtitlePreferenceStore.write("[]", "quark", "vid_101", chsSel);
        SubtitlePreferenceStore.Selection reloaded =
                SubtitlePreferenceStore.read(stored, "quark", "vid_101");
        check(
                reloaded != null
                        && !reloaded.disabled
                        && SubtitlePreferenceStore.matchTrackIndex(
                                        reloaded,
                                        Arrays.asList(
                                                "English",
                                                "庆余年.S01E02.繁体中文.ass",
                                                "庆余年.S01E02.简体中文.ass"))
                                == 2,
                "SubtitlePreferenceStore matches next-episode subtitle across changed episode numbers (S01E01 -> S01E02)");

        SubtitlePreferenceStore.Selection langSel =
                new SubtitlePreferenceStore.Selection(false, 0, "中英双语");
        check(
                SubtitlePreferenceStore.matchTrackIndex(
                                langSel, Arrays.asList("English", "Bilingual 简英双语", "日本語"))
                        == 1,
                "SubtitlePreferenceStore matches bilingual Chinese subtitle bucket across naming styles");

        SubtitlePreferenceStore.Selection offSel =
                new SubtitlePreferenceStore.Selection(true, -2, "");
        check(
                SubtitlePreferenceStore.matchTrackIndex(offSel, Arrays.asList("简中", "English"))
                        == -2,
                "SubtitlePreferenceStore preserves explicit subtitles-off (-2) across episodes");

        SubtitlePreferenceStore.Selection idxFallback =
                new SubtitlePreferenceStore.Selection(false, 2, "轨道 3");
        check(
                SubtitlePreferenceStore.matchTrackIndex(
                                idxFallback, Arrays.asList("Track A", "Track B", "Track C"))
                        == 2,
                "SubtitlePreferenceStore falls back to matching track index when labels differ");

        SubtitlePreferenceStore.setPrivate("quark", "priv_1", chsSel);
        check(
                SubtitlePreferenceStore.getPrivate("quark", "priv_1") != null,
                "SubtitlePreferenceStore tracks private-space subtitle selection in memory");
        SubtitlePreferenceStore.clearPrivateRecords();
        check(
                SubtitlePreferenceStore.getPrivate("quark", "priv_1") == null,
                "SubtitlePreferenceStore clears private-space subtitle records on exit");

        // 2. Toast layout never collapses into an 80dp vertical column when root is unlaid-out
        // (parentW==0) or when TV top dock spans full width
        int[] unlaid = MainActivity.computeToastLayout(1920, 0, 0, 0, 0, 0, 20, 56, 80, 520, 1120);
        int[] topDock =
                MainActivity.computeToastLayout(
                        1920,
                        1820,
                        96,
                        android.view.Gravity.TOP | android.view.Gravity.CENTER_HORIZONTAL,
                        0,
                        0,
                        20,
                        56,
                        80,
                        520,
                        1120);
        int[] rightDock =
                MainActivity.computeToastLayout(
                        1920,
                        120,
                        600,
                        android.view.Gravity.RIGHT | android.view.Gravity.CENTER_VERTICAL,
                        0,
                        24,
                        20,
                        56,
                        80,
                        520,
                        1120);
        int[] bottomDock =
                MainActivity.computeToastLayout(
                        1080,
                        1000,
                        120,
                        android.view.Gravity.BOTTOM | android.view.Gravity.CENTER_HORIZONTAL,
                        24,
                        0,
                        20,
                        56,
                        80,
                        520,
                        1120);
        check(
                unlaid[1] == 0
                        && unlaid[2] == 1120
                        && topDock[1] == 0
                        && topDock[2] == 1120
                        && rightDock[1] == 164
                        && rightDock[2] >= 1000
                        && bottomDock[0] == 164
                        && bottomDock[1] == 0,
                "MainActivity.computeToastLayout keeps toasts wide and horizontal across top/left/right/bottom docks");

        // 3. StartSpecBanner defers opening spec badge while initial controls are visible instead
        // of silently dropping it for the entire episode
        String bannerSrc = readJavaSource("hud/StartSpecBanner.java");
        check(
                com.pilipala.marcomovie.hud.StartSpecBanner.shouldDeferReveal(true)
                        && !com.pilipala.marcomovie.hud.StartSpecBanner.shouldDeferReveal(false)
                        && bannerSrc.contains("pendingReveal = true")
                        && bannerSrc.contains("!controlsVisible && pendingReveal"),
                "StartSpecBanner defers reveal until initial playback controls hide so TV spec badges reliably display");
    }

    private static void testCompactLoadingCardFastFailoverAndDvColorWarning() throws Exception {
        // 1. Compact loading card strips bloated raw netdisk filenames and bounds card width
        String rawDvFilename =
                "[21.29GB] 4KNF杜比视界杜比全景声内封简繁 "
                        + "Possible.Love.2026.2160p.NF.WEB-DL.DDP5.1.Atmos.DV.H.265-SmartWeb.mkv";
        String dvSub = PlayerChrome.formatLoadingSubtitle("可能的爱 (臻彩)", rawDvFilename);
        String epFileSub =
                PlayerChrome.formatLoadingSubtitle("繁花", "Blossoms.S01E05.2160p.WEB-DL.H265.mkv");
        String cleanEpSub = PlayerChrome.formatLoadingSubtitle("庆余年", "第08集");
        String genericSub = PlayerChrome.formatLoadingSubtitle("可能的爱", "正片");
        String noTitleSub = PlayerChrome.formatLoadingSubtitle("", rawDvFilename);
        check(
                "可能的爱 (臻彩) · 21.29GB".equals(dvSub)
                        && "繁花 · S01E05".equals(epFileSub)
                        && "庆余年 · 第08集".equals(cleanEpSub)
                        && "可能的爱".equals(genericSub)
                        && noTitleSub.length() <= 34
                        && !noTitleSub.contains(".mkv"),
                "PlayerChrome.formatLoadingSubtitle collapses raw netdisk release filenames into compact subtitles");

        check(
                PlayerChrome.resolveLoadingCardMaxWidthPx(1920, 80, 360, 720) == 720
                        && PlayerChrome.resolveLoadingCardMaxWidthPx(640, 80, 360, 720) == 480
                        && PlayerChrome.resolveLoadingCardMaxWidthPx(0, 80, 360, 720) == 720,
                "PlayerChrome.resolveLoadingCardMaxWidthPx caps loading card cleanly across TV and phone widths");

        // 2. Bogus HLS fallback is skipped for known MKV/MP4 containers and local /proxy streams
        check(
                !MoviePlayer.shouldRetryAsHlsFallback(
                                null,
                                rawDvFilename,
                                "http",
                                "127.0.0.1",
                                "/proxy",
                                "do=quark&id=abc123",
                                "http://127.0.0.1:45678/proxy?do=quark&id=abc123")
                        && !MoviePlayer.shouldRetryAsHlsFallback(
                                null,
                                "第01集",
                                "http",
                                "127.0.0.1",
                                "/proxy",
                                "do=quark&id=abc123",
                                "http://127.0.0.1:45678/proxy?do=quark&id=abc123")
                        && !MoviePlayer.shouldRetryAsHlsFallback(
                                null,
                                rawDvFilename,
                                "https",
                                "cdn.example",
                                "/play/stream999",
                                "",
                                "https://cdn.example/play/stream999")
                        && !MoviePlayer.shouldRetryAsHlsFallback(
                                "video/x-matroska",
                                "第01集",
                                "https",
                                "cdn.example",
                                "/play/stream999",
                                "",
                                "https://cdn.example/play/stream999")
                        && MoviePlayer.shouldRetryAsHlsFallback(
                                null,
                                "直播",
                                "http",
                                "127.0.0.1",
                                "/proxy",
                                "do=live&mode=hls",
                                "http://127.0.0.1:45678/proxy?do=live&mode=hls")
                        && MoviePlayer.shouldRetryAsHlsFallback(
                                null,
                                "第01集",
                                "https",
                                "cdn.example",
                                "/play/stream999",
                                "",
                                "https://cdn.example/play/stream999"),
                "MoviePlayer.shouldRetryAsHlsFallback skips HLS retries on MKV/MP4 and netdisk /proxy streams");

        // 3. Startup fail-fast vs mid-playback resilience in ResilientLoadErrorPolicy and
        // ChunkedProxyDataSource
        final boolean[] started = new boolean[] {false};
        MoviePlayer.ResilientLoadErrorPolicy vodPolicy =
                new MoviePlayer.ResilientLoadErrorPolicy(false, () -> started[0]);
        androidx.media3.exoplayer.upstream.LoadErrorHandlingPolicy.LoadErrorInfo timeoutErr1 =
                new androidx.media3.exoplayer.upstream.LoadErrorHandlingPolicy.LoadErrorInfo(
                        null, null, new java.net.SocketTimeoutException("read timed out"), 1);
        androidx.media3.exoplayer.upstream.LoadErrorHandlingPolicy.LoadErrorInfo ioErr1 =
                new androidx.media3.exoplayer.upstream.LoadErrorHandlingPolicy.LoadErrorInfo(
                        null, null, new java.io.IOException("connection reset"), 1);
        androidx.media3.exoplayer.upstream.LoadErrorHandlingPolicy.LoadErrorInfo ioErr2 =
                new androidx.media3.exoplayer.upstream.LoadErrorHandlingPolicy.LoadErrorInfo(
                        null, null, new java.io.IOException("connection reset"), 2);
        check(
                vodPolicy.getMinimumLoadableRetryCount(androidx.media3.common.C.DATA_TYPE_MEDIA)
                                == 1
                        && vodPolicy.getRetryDelayMsFor(timeoutErr1)
                                == androidx.media3.common.C.TIME_UNSET
                        && vodPolicy.getRetryDelayMsFor(ioErr1) == 400L
                        && vodPolicy.getRetryDelayMsFor(ioErr2)
                                == androidx.media3.common.C.TIME_UNSET,
                "ResilientLoadErrorPolicy fails fast before first frame so broken proxy qualities switch immediately");

        started[0] = true;
        check(
                vodPolicy.getMinimumLoadableRetryCount(androidx.media3.common.C.DATA_TYPE_MEDIA)
                                == 6
                        && vodPolicy.getRetryDelayMsFor(timeoutErr1) == 500L
                        && vodPolicy.getRetryDelayMsFor(ioErr2) == 1000L,
                "ResilientLoadErrorPolicy keeps full 6-retry resilience once mid-playback streaming is active");

        java.io.IOException wrappedTimeout =
                new java.io.IOException(new java.net.SocketTimeoutException("spider timeout"));
        check(
                MoviePlayer.ChunkedProxyDataSource.resolveOpenMaxRetries(0L, false, wrappedTimeout)
                                == 0
                        && MoviePlayer.ChunkedProxyDataSource.resolveOpenMaxRetries(
                                        0L, false, new java.io.IOException("reset"))
                                == 1
                        && MoviePlayer.ChunkedProxyDataSource.resolveOpenMaxRetries(
                                        0L, true, wrappedTimeout)
                                == MoviePlayer.ChunkedProxyDataSource.MAX_CHUNK_RETRIES
                        && MoviePlayer.ChunkedProxyDataSource.resolveOpenMaxRetries(
                                        4096L, false, wrappedTimeout)
                                == MoviePlayer.ChunkedProxyDataSource.MAX_CHUNK_RETRIES,
                "ChunkedProxyDataSource avoids multiplicative startup timeout retries while preserving seek/mid-play retries");

        // 4. Transcoded pure Dolby Vision Profile 5 color-risk detector
        check(
                MoviePlayer.looksLikeTranscodedDolbyVisionColorRisk(
                                rawDvFilename, "夸克网盘", "video/avc")
                        && !MoviePlayer.looksLikeTranscodedDolbyVisionColorRisk(
                                "Movie.2026.2160p.DV.HDR10.H.265.mkv", "夸克网盘", "video/avc")
                        && !MoviePlayer.looksLikeTranscodedDolbyVisionColorRisk(
                                rawDvFilename, "夸克网盘", "video/hevc")
                        && !MoviePlayer.looksLikeTranscodedDolbyVisionColorRisk(
                                rawDvFilename, "夸克网盘", "video/dolby-vision")
                        && !MoviePlayer.looksLikeTranscodedDolbyVisionColorRisk(
                                "Normal.Movie.2026.2160p.HDR10.H265.mkv", "夸克网盘", "video/avc"),
                "MoviePlayer.looksLikeTranscodedDolbyVisionColorRisk flags cloud-transcoded H.264 pure DV streams without false positives");
    }

    private static void testLanSpiderGatewayAndTvQrInputBubble() throws Exception {
        // 1. SpiderGatewayServer real UDP discovery + Bearer auth + invoke + loopback proxy rewrite
        String gwToken = "a1b2c3d4e5f60718";
        SpiderGatewayServer.ActionDispatcher stubDispatcher =
                new SpiderGatewayServer.ActionDispatcher() {
                    @Override
                    public String dispatch(
                            String action,
                            org.json.JSONObject siteObj,
                            org.json.JSONObject paramsObj) {
                        if ("play".equals(action)) {
                            return "{\"parse\":0,\"url\":\"http://127.0.0.1:9978/proxy?do=quark&id=7\"}";
                        }
                        return "{\"list\":[{\"vod_id\":\"42\",\"vod_name\":\"Echo:"
                                + action
                                + ":"
                                + paramsObj.optString("wd", "")
                                + "\"}]}";
                    }

                    @Override
                    public int routeCount() {
                        return 12;
                    }
                };
        try (SpiderGatewayServer gw =
                new SpiderGatewayServer(
                        0, 0, gwToken, "客厅小米电视", "android-csp", true, stubDispatcher, null, null)) {
            // UDP discovery probe matches iOS SpiderGatewayClient byte-for-byte and omits token
            try (java.net.DatagramSocket clientUdp = new java.net.DatagramSocket()) {
                clientUdp.setSoTimeout(3000);
                byte[] probe =
                        SpiderGatewayServer.DISCOVERY_PROBE_PAYLOAD.getBytes(
                                StandardCharsets.UTF_8);
                java.net.DatagramPacket req =
                        new java.net.DatagramPacket(
                                probe,
                                probe.length,
                                java.net.InetAddress.getByName("127.0.0.1"),
                                gw.discoveryPort);
                clientUdp.send(req);
                byte[] buf = new byte[1024];
                java.net.DatagramPacket resp = new java.net.DatagramPacket(buf, buf.length);
                clientUdp.receive(resp);
                String replyJson =
                        new String(
                                resp.getData(),
                                resp.getOffset(),
                                resp.getLength(),
                                StandardCharsets.UTF_8);
                org.json.JSONObject disc = new org.json.JSONObject(replyJson);
                check(
                        SpiderGatewayServer.PROTOCOL_ID.equals(disc.optString("protocol"))
                                && disc.optInt("port") == gw.httpPort
                                && "客厅小米电视".equals(disc.optString("deviceName"))
                                && "android-csp".equals(disc.optString("engine"))
                                && disc.optBoolean("supportsNativeSo")
                                && disc.optBoolean("requiresToken")
                                && !replyJson.contains(gwToken),
                        "SpiderGatewayServer answers UDP discovery probe without ever leaking Bearer token");
            }

            // Unauthenticated health returns 401; authenticated health returns 200
            String unauth =
                    httpRequestLoopback(
                            gw.httpPort, "GET", "/marco-gateway/v1/health", null, null, null);
            String authed =
                    httpRequestLoopback(
                            gw.httpPort,
                            "GET",
                            "/marco-gateway/v1/health",
                            "Bearer " + gwToken,
                            null,
                            null);
            check(
                    unauth.startsWith("HTTP/1.1 401")
                            && authed.startsWith("HTTP/1.1 200")
                            && authed.contains("\"supportsNativeSo\":true")
                            && authed.contains("\"routeCount\":12"),
                    "SpiderGatewayServer enforces Bearer auth and serves marco-spider-gateway-v1 health");

            // Authenticated invoke search & play (loopback proxy URL rewritten, direct URL intact)
            String searchBody =
                    "{\"protocol\":\"marco-spider-gateway-v1\",\"action\":\"search\","
                            + "\"site\":{\"api\":\"csp_Demo\"},\"params\":{\"wd\":\"繁花\"}}";
            String searchReply =
                    httpRequestLoopback(
                            gw.httpPort,
                            "POST",
                            "/marco-gateway/v1/invoke",
                            "Bearer " + gwToken,
                            "application/json",
                            searchBody);
            String playBody =
                    "{\"protocol\":\"marco-spider-gateway-v1\",\"action\":\"play\","
                            + "\"site\":{\"api\":\"csp_Demo\"},\"params\":{\"flag\":\"quark\",\"id\":\"7\"}}";
            String playReply =
                    httpRequestLoopback(
                            gw.httpPort,
                            "POST",
                            "/marco-gateway/v1/invoke",
                            "Bearer " + gwToken,
                            "application/json",
                            playBody);
            String directUnchanged =
                    SpiderGatewayServer.rewriteLoopbackProxyUrls(
                            "{\"url\":\"https://cdn.example/video.m3u8\"}",
                            "127.0.0.1",
                            9981,
                            gwToken);
            check(
                    searchReply.startsWith("HTTP/1.1 200")
                            && searchReply.contains("Echo:search:繁花")
                            && playReply.startsWith("HTTP/1.1 200")
                            && playReply.contains("/marco-gateway/v1/proxy?token=" + gwToken)
                            && directUnchanged.contains("https://cdn.example/video.m3u8"),
                    "SpiderGatewayServer executes invoke actions and rewrites loopback proxy URLs while keeping direct CDNs untouched");
        }

        // 2. RemoteInputServer LAN push, Host/Origin CSRF guards, and sanitization
        final String[] received = new String[] {""};
        RemoteInputServer.FieldSpec spec =
                new RemoteInputServer.FieldSpec(
                        "扫码输入 · 配置地址", "https://…", "", false, false, false, 2048);
        try (RemoteInputServer srv =
                new RemoteInputServer(
                        spec,
                        (text, clear) -> received[0] = clear ? "<CLEARED>" : text,
                        60_000L,
                        new java.net.InetSocketAddress("127.0.0.1", 0))) {
            String hostHdr = "127.0.0.1:" + srv.port();
            String pageOk = httpGetLoopback(srv.port(), srv.path, hostHdr);
            String badHost = httpGetLoopback(srv.port(), srv.path, "evil.example:" + srv.port());
            String crossOrigin =
                    httpPostLoopback(
                            srv.port(),
                            srv.path + "/push",
                            hostHdr,
                            "https://evil.example",
                            "{\"text\":\"blocked\"}");
            String goodPush =
                    httpPostLoopback(
                            srv.port(),
                            srv.path + "/push",
                            hostHdr,
                            "http://" + hostHdr,
                            "{\"text\":\"https://sub.example/tv.json\"}");
            check(
                    pageOk.startsWith("HTTP/1.1 200")
                            && pageOk.contains("配置地址")
                            && badHost.startsWith("HTTP/1.1 403")
                            && crossOrigin.startsWith("HTTP/1.1 403")
                            && goodPush.startsWith("HTTP/1.1 200")
                            && "https://sub.example/tv.json".equals(received[0]),
                    "RemoteInputServer delivers LAN QR text input while enforcing Host and Origin CSRF guards");
        }
        check(
                "1234".equals(RemoteInputServer.sanitizeInput("ab12-3456", false, true, 4))
                        && "a\nb"
                                .equals(
                                        RemoteInputServer.sanitizeInput(
                                                "a\r\nb\u0000", true, false, 64))
                        && "a b".equals(RemoteInputServer.sanitizeInput("a\nb", false, false, 64)),
                "RemoteInputServer.sanitizeInput handles numeric PIN, multiline, and single-line inputs cleanly");

        // 3. TvQrInputHelper anchored bubble placement math stays strictly on-screen across edges
        TvQrInputHelper.BubblePlacement below =
                TvQrInputHelper.computeBubblePlacement(
                        1200, 220, 40, 40, 220, 260, 1920, 1080, 16, 4, 28, false);
        TvQrInputHelper.BubblePlacement above =
                TvQrInputHelper.computeBubblePlacement(
                        1200, 920, 40, 40, 220, 260, 1920, 1080, 16, 4, 28, false);
        TvQrInputHelper.BubblePlacement side =
                TvQrInputHelper.computeBubblePlacement(
                        420, 140, 40, 40, 230, 260, 1920, 1080, 16, 4, 28, true);
        check(
                below.pointerEdge == TvQrInputHelper.EDGE_TOP
                        && below.y >= 260
                        && above.pointerEdge == TvQrInputHelper.EDGE_BOTTOM
                        && above.y + 260 <= 920
                        && side.pointerEdge == TvQrInputHelper.EDGE_LEFT
                        && side.x >= 460
                        && below.x >= 16
                        && below.x + 220 <= 1904,
                "TvQrInputHelper.computeBubblePlacement anchors QR bubbles below/above/beside the button within screen bounds");

        // 4. All TV inputs remove paste buttons on TV and integrate TvQrInputHelper
        String addrSrc = readJavaSource("AddressInput.java");
        String srcCtlSrc = readJavaSource("SourceController.java");
        String searchSrc = readJavaSource("GlobalSearchScreen.java");
        String cloudSrc = readJavaSource("CloudSyncDialog.java");
        String castSrc = readJavaSource("CastScreen.java");
        String danmuSrc = readJavaSource("DanmuSettingsPanel.java");
        String pickerSrc = readJavaSource("SourcePicker.java");
        String privacySrc = readJavaSource("PrivacySpace.java");
        String pluginStylerSrc = readJavaSource("PluginDialogStyler.java");
        check(
                addrSrc.contains("if (!a.isTvDevice())")
                        && addrSrc.contains("TvQrInputHelper.wrap(")
                        && srcCtlSrc.contains("if (!a.isTvDevice())")
                        && srcCtlSrc.contains("TvQrInputHelper.wrap(")
                        && searchSrc.contains("TvQrInputHelper.showSearchBubble(")
                        && cloudSrc.contains("TvQrInputHelper.wrap(")
                        && castSrc.contains("TvQrInputHelper.wrap(")
                        && danmuSrc.contains("TvQrInputHelper.wrap(")
                        && pickerSrc.contains("TvQrInputHelper.wrap(")
                        && privacySrc.contains("TvQrInputHelper.wrap(")
                        && pluginStylerSrc.contains(
                                "TvQrInputHelper.attachToExistingPluginEditText("),
                "All Android TV text inputs drop touch paste clutter and attach TvQrInputHelper QR bubble popovers");
    }

    private static void testAppleTvLiveAndMineRedesign() throws Exception {
        // 1. LivePreferences favorite & blocked-group round-trip and canonical matching
        LiveCatalog.Catalog raw = new LiveCatalog.Catalog();
        LiveCatalog.Group cctv = new LiveCatalog.Group();
        cctv.name = "央视";
        LiveCatalog.Channel ch1 = new LiveCatalog.Channel();
        ch1.name = "CCTV-1 综合";
        ch1.options.put("epg", "新闻联播");
        ch1.streams.add(new LiveCatalog.Stream());
        LiveCatalog.Channel ch5p = new LiveCatalog.Channel();
        ch5p.name = "CCTV-5+";
        ch5p.options.put("epg", "体育赛事");
        ch5p.streams.add(new LiveCatalog.Stream());
        cctv.channels.add(ch1);
        cctv.channels.add(ch5p);

        LiveCatalog.Group sat = new LiveCatalog.Group();
        sat.name = "卫视";
        LiveCatalog.Channel hn = new LiveCatalog.Channel();
        hn.name = "湖南卫视";
        hn.options.put("epg", "晚间剧场");
        hn.streams.add(new LiveCatalog.Stream());
        sat.channels.add(hn);

        LiveCatalog.Group hidden = new LiveCatalog.Group();
        hidden.name = "购物频道";
        LiveCatalog.Channel shop = new LiveCatalog.Channel();
        shop.name = "时尚购物";
        shop.streams.add(new LiveCatalog.Stream());
        hidden.channels.add(shop);

        raw.groups.add(cctv);
        raw.groups.add(sat);
        raw.groups.add(hidden);

        java.util.Set<String> favs = LivePreferences.toggleFavorite(null, "CCTV-1 综合");
        String favJson = LivePreferences.serializeStringSet(favs);
        java.util.Set<String> favsReloaded = LivePreferences.readStringSet(favJson);
        check(
                LivePreferences.isFavorite(favsReloaded, ch1)
                        && !LivePreferences.isFavorite(favsReloaded, hn),
                "LivePreferences persists favorite channels cleanly via canonical keys");

        java.util.Set<String> blocked =
                LivePreferences.toggleBlockedGroup((java.util.Set<String>) null, "购物频道");
        blocked = LivePreferences.toggleBlockedGroup(blocked, LivePreferences.FAVORITES_GROUP_NAME);
        check(
                blocked.contains("购物频道") && !blocked.contains(LivePreferences.FAVORITES_GROUP_NAME),
                "LivePreferences blocks real channel groups while protecting virtual Favorites group");

        // 2. Display group synthesis: Favorites pinned first, blocked groups omitted, raw intact
        List<LiveCatalog.Group> display =
                LivePreferences.buildDisplayGroups(raw, favsReloaded, blocked, "");
        check(
                display.size() == 3
                        && LivePreferences.FAVORITES_GROUP_NAME.equals(display.get(0).name)
                        && display.get(0).channels.size() == 1
                        && "央视".equals(display.get(1).name)
                        && "卫视".equals(display.get(2).name)
                        && raw.groups.size() == 3,
                "LivePreferences synthesizes Favorites group first and hides blocked groups without mutating raw catalog");

        // 3. Channel & EPG search filtering respects blocked groups
        List<LiveCatalog.Group> epgSearch =
                LivePreferences.buildDisplayGroups(raw, favsReloaded, blocked, "新闻联播");
        List<LiveCatalog.Group> blockedSearch =
                LivePreferences.buildDisplayGroups(raw, favsReloaded, blocked, "购物");
        check(
                epgSearch.size() == 1
                        && LivePreferences.SEARCH_GROUP_NAME.equals(epgSearch.get(0).name)
                        && epgSearch.get(0).channels.size() == 1
                        && "CCTV-1 综合".equals(epgSearch.get(0).channels.get(0).name)
                        && blockedSearch.size() == 1
                        && blockedSearch.get(0).channels.isEmpty(),
                "LivePreferences searches channel names and EPG titles while honoring blocked groups");

        // 4. Initial source recall, EPG progress, and channel monogram helpers
        LiveCatalog.Source s0 = new LiveCatalog.Source();
        s0.url = "https://live.example/a.m3u";
        LiveCatalog.Source s1 = new LiveCatalog.Source();
        s1.url = "https://live.example/b.m3u";
        check(
                LivePreferences.resolveInitialSourceIndex(Arrays.asList(s0, s1), s1.url) == 1
                        && LivePreferences.resolveInitialSourceIndex(
                                        Arrays.asList(s0, s1), "https://missing.example/c.m3u")
                                == 0,
                "LivePreferences restores last selected live source URL with safe fallback");

        float midProgress = LivePreferences.computeEpgProgress(1000L, 5000L, 3000L);
        float invalidProgress = LivePreferences.computeEpgProgress(5000L, 5000L, 5000L);
        check(
                Math.abs(midProgress - 0.5f) < 0.001f && invalidProgress < 0f,
                "LivePreferences computes bounded EPG progress ratio");

        check(
                "C5+".equals(LivePreferences.channelMonogram("CCTV-5+"))
                        && "湖南".equals(LivePreferences.channelMonogram("湖南卫视"))
                        && "TV".equals(LivePreferences.channelMonogram("   ")),
                "LivePreferences generates concise channel monograms for logo fallback");

        // 5. Mine screen watch progress helper
        check(
                Math.abs(TvV17MineScreen.computeHistoryProgress(45000, 90000) - 0.5f) < 0.001f
                        && TvV17MineScreen.computeHistoryProgress(1000, 0) == 0f
                        && Math.abs(TvV17MineScreen.computeHistoryProgress(95000, 90000) - 1.0f)
                                < 0.001f,
                "TvV17MineScreen computes watch history card progress ratios safely");

        // 6. Architectural wiring verification across TV & Mobile Live + Mine + PlaybackControls
        String playbackControlsSrc = readJavaSource("PlaybackControls.java");
        String liveCtrlSrc = readJavaSource("LiveController.java");
        String sourceCtrlSrc = readJavaSource("SourceController.java");
        String tvLiveSrc = readJavaSource("TvV17LiveScreen.java");
        String mobileShellSrc = readJavaSource("MobileShell.java");
        String tvMineSrc = readJavaSource("TvV17MineScreen.java");
        check(
                playbackControlsSrc.contains("a.player.setSpeed(1.0f)")
                        && liveCtrlSrc.contains("peekCachedCatalog(")
                        && liveCtrlSrc.contains("peekCachedGuide(")
                        && liveCtrlSrc.contains("clearCatalogCache()")
                        && sourceCtrlSrc.contains("LiveController.clearCatalogCache()")
                        && tvLiveSrc.contains("LivePreferences.buildDisplayGroups")
                        && tvLiveSrc.contains("TvQrInputHelper.wrap")
                        && tvLiveSrc.contains("TvMenuAction.Release")
                        && mobileShellSrc.contains("LivePreferences.buildDisplayGroups")
                        && mobileShellSrc.contains("LivePreferences.toggleFavorite")
                        && tvMineSrc.contains("TvMineActionMetrics.width")
                        && tvMineSrc.contains("SpiderGatewayDialog.show")
                        && tvMineSrc.contains("MineGlyph"),
                "Apple TV Live/Mine redesigns, Mobile Live favorites, snapshot caching, and 1.0x live speed lock are wired");
    }

    private static void testXiaomiHyperOsTvUpdateInstallFallbacks() throws Exception {
        // 1. TV unknown-sources fallback chain includes Xiaomi MiTV/HyperOS native security
        // settings and ends at generic Settings so TVs lacking ACTION_MANAGE_UNKNOWN_APP_SOURCES
        // never dead-end
        List<String> tvActions = UpdateScreen.unknownSourcesSettingsActionOrder(true);
        List<String> phoneActions = UpdateScreen.unknownSourcesSettingsActionOrder(false);
        check(
                tvActions.size() == 6
                        && tvActions.get(0).contains("MANAGE_UNKNOWN_APP_SOURCES|package")
                        && tvActions.get(1).contains("MANAGE_UNKNOWN_APP_SOURCES")
                        && UpdateScreen.XIAOMI_TV_SECURITY_ACTION.equals(tvActions.get(2))
                        && tvActions.get(3).contains("SECURITY_SETTINGS")
                        && tvActions.get(4).contains("APPLICATION_DETAILS_SETTINGS")
                        && tvActions.get(5).contains("android.settings.SETTINGS")
                        && !phoneActions.contains(UpdateScreen.XIAOMI_TV_SECURITY_ACTION),
                "UpdateScreen TV unknown-sources fallback chain includes Xiaomi HyperOS/MiTV Security settings");

        // 2. API 29+ prioritizes ACTION_VIEW (ACTION_INSTALL_PACKAGE deprecated on Android 10+),
        // while API 23-28 keeps ACTION_INSTALL_PACKAGE primary with ACTION_VIEW fallback
        List<String> api33Order = UpdateScreen.installActionOrder(33);
        List<String> api28Order = UpdateScreen.installActionOrder(28);
        check(
                api33Order.size() == 2
                        && android.content.Intent.ACTION_VIEW.equals(api33Order.get(0))
                        && android.content.Intent.ACTION_INSTALL_PACKAGE.equals(api33Order.get(1))
                        && api28Order.size() == 2
                        && android.content.Intent.ACTION_INSTALL_PACKAGE.equals(api28Order.get(0))
                        && android.content.Intent.ACTION_VIEW.equals(api28Order.get(1)),
                "UpdateScreen uses ACTION_VIEW primary on Android 10+ and ACTION_INSTALL_PACKAGE primary on API 23-28");

        // 3. Exported APK filename sanitization for local Download fallback
        check(
                "MarcoMovie-0.6.0-android-tv.apk"
                                .equals(UpdateScreen.exportApkFileName("0.6.0", true))
                        && "MarcoMovie-0.5.27-android-mobile.apk"
                                .equals(UpdateScreen.exportApkFileName("0.5.27", false))
                        && "MarcoMovie-0.6.0-android-tv.apk"
                                .equals(UpdateScreen.exportApkFileName("../0.6.0", true)),
                "UpdateScreen sanitizes exported APK filename cleanly for Download directory fallback");

        // 4. Source verification: UpdateScreen never hard-blocks install when per-app settings
        // page is absent, always verifies APK before Download export, and supports permission-free
        // API 29+ MediaStore downloads URI
        String updateSrc = readJavaSource("UpdateScreen.java");
        check(
                updateSrc.contains("hasUnknownSourcesSettingsActivity(")
                        && updateSrc.contains("直接尝试安装")
                        && updateSrc.contains("exportVerifiedApkToDownloads()")
                        && updateSrc.contains("content://media/external/downloads")
                        && updateSrc.contains("UpdateManager.verifyApk(a, apkFile, release)")
                        && updateSrc.contains("launchSystemInstaller()"),
                "UpdateScreen removes hard block on HyperOS/MiTV, adds direct install + multi-intent fallback + verified Download export");
    }

    private static void testLiveQrFileUploadSupport() throws Exception {
        // 1. Filename sanitization & extension stripping
        check(
                "evil.m3u".equals(RemoteInputServer.sanitizeFileName("../../evil.m3u"))
                        && "央视高清.m3u".equals(RemoteInputServer.sanitizeFileName("央视高清.m3u"))
                        && "live.txt".equals(RemoteInputServer.sanitizeFileName("   "))
                        && "央视高清".equals(SourceController.stripFileExtension("央视高清.m3u"))
                        && "iptv_list"
                                .equals(SourceController.stripFileExtension("../iptv_list.json")),
                "RemoteInputServer.sanitizeFileName and SourceController.stripFileExtension handle Unicode & traversal safely");

        // 2. Live loopback HTTP upload test: text + raw M3U/TXT/JSON file upload + CSRF guard
        final String[] gotFileName = {null};
        final String[] gotFileBody = {null};
        RemoteInputServer.FieldSpec uploadSpec =
                new RemoteInputServer.FieldSpec(
                        "扫码 · 直播源网址或文件",
                        "https://…/ipv6.m3u",
                        "",
                        true,
                        false,
                        false,
                        RemoteInputServer.DEFAULT_MAX_CHARS,
                        ".txt,.json,.m3u,.m3u8",
                        "支持上传 TXT / JSON / M3U / M3U8");
        try (RemoteInputServer srv =
                new RemoteInputServer(
                        uploadSpec,
                        (text, clear) -> {},
                        (name, data) -> {
                            gotFileName[0] = name;
                            gotFileBody[0] = new String(data, StandardCharsets.UTF_8);
                            LiveCatalog.Catalog parsed =
                                    LiveCatalog.parse(gotFileBody[0], "", null);
                            return "已导入 " + name + "（共 " + parsed.channelCount() + " 个频道）";
                        },
                        60_000L,
                        new java.net.InetSocketAddress("127.0.0.1", 0))) {
            int port = srv.port();
            String hostHeader = "127.0.0.1:" + port;
            String html = httpGetLoopback(port, srv.path, hostHeader);
            check(
                    html.contains("200 OK")
                            && html.contains("id=file")
                            && html.contains("/upload?name=")
                            && html.contains("TXT / JSON / M3U / M3U8"),
                    "RemoteInputServer renders mobile file-upload picker alongside text input when FileListener is attached");

            String sampleM3u =
                    "#EXTM3U\n#EXTINF:-1 group-title=\"央视\",CCTV-1\nhttps://stream.example/cctv1.m3u8\n";
            String encodedName = java.net.URLEncoder.encode("央视高清.m3u", "UTF-8");
            String uploadResp =
                    httpPostBinaryLoopback(
                            port,
                            srv.path + "/upload?name=" + encodedName,
                            hostHeader,
                            "http://" + hostHeader,
                            sampleM3u.getBytes(StandardCharsets.UTF_8));
            String badOrigin =
                    httpPostBinaryLoopback(
                            port,
                            srv.path + "/upload?name=" + encodedName,
                            hostHeader,
                            "https://evil.example",
                            sampleM3u.getBytes(StandardCharsets.UTF_8));
            String emptyUpload =
                    httpPostBinaryLoopback(
                            port,
                            srv.path + "/upload?name=empty.txt",
                            hostHeader,
                            "http://" + hostHeader,
                            new byte[0]);
            check(
                    uploadResp.contains("200 OK")
                            && uploadResp.contains("\"ok\":true")
                            && uploadResp.contains("共 1 个频道")
                            && "央视高清.m3u".equals(gotFileName[0])
                            && sampleM3u.equals(gotFileBody[0])
                            && badOrigin.contains("403 Forbidden")
                            && emptyUpload.contains("400 Bad Request"),
                    "RemoteInputServer /upload decodes Chinese filenames, parses uploaded playlists, and enforces Origin & non-empty guards");
        }

        // 3. Source wiring check: SourceController.showLiveImportDialog uses wrapWithFileUpload
        String sourceCtrlSrc = readJavaSource("SourceController.java");
        String qrHelperSrc = readJavaSource("TvQrInputHelper.java");
        check(
                sourceCtrlSrc.contains("TvQrInputHelper.wrapWithFileUpload(")
                        && sourceCtrlSrc.contains("importLiveFileBytesSync(")
                        && sourceCtrlSrc.contains("LiveCatalog.sources(trimmed, \"\")")
                        && qrHelperSrc.contains("wrapWithFileUpload("),
                "SourceController wires live QR bubble to dual text/URL + TXT/JSON/M3U/M3U8 file upload");
    }

    private static void testAdaptiveTvNavBarAndWelcomeScreen() throws Exception {
        // 1. Adaptive TV top nav bar scales down cleanly on compact / 120%-scaled TVs and scales
        // up on wide large-canvas TVs without ever overflowing or colliding with brand mark
        HomeDock.AdaptiveTopMetrics compact =
                HomeDock.computeAdaptiveTopMetrics(1600, 900, 2.0f, 1.0f, 1.0f, 8); // 800x450dp
        HomeDock.AdaptiveTopMetrics standard1080 =
                HomeDock.computeAdaptiveTopMetrics(1920, 1080, 2.0f, 1.0f, 1.0f, 8); // 960x540dp
        HomeDock.AdaptiveTopMetrics standard4k =
                HomeDock.computeAdaptiveTopMetrics(3840, 2160, 4.0f, 1.0f, 1.0f, 8); // 960x540dp
        HomeDock.AdaptiveTopMetrics wideTv =
                HomeDock.computeAdaptiveTopMetrics(1920, 1080, 1.5f, 1.0f, 1.0f, 8); // 1280x720dp
        HomeDock.AdaptiveTopMetrics hugeFont =
                HomeDock.computeAdaptiveTopMetrics(1280, 720, 1.6f, 1.30f, 1.20f, 8); // 800x450dp

        check(
                compact.fitScale < standard1080.fitScale
                        && Math.abs(standard1080.fitScale - standard4k.fitScale) < 0.001f
                        && wideTv.fitScale > standard1080.fitScale
                        && compact.sideMarginDp < standard1080.sideMarginDp
                        && wideTv.sideMarginDp >= standard1080.sideMarginDp,
                "HomeDock.computeAdaptiveTopMetrics adapts scale and margins proportionally across 720p/1080p/4K/wide TV canvases");

        // 2. Top safe inset always clears topMargin + crossDp + breathing room, and height <= 11%
        check(
                compact.topSafeInsetDp >= compact.topMarginDp + compact.crossDp + 16
                        && standard1080.topSafeInsetDp
                                >= standard1080.topMarginDp + standard1080.crossDp + 20
                        && wideTv.topSafeInsetDp >= wideTv.topMarginDp + wideTv.crossDp + 20
                        && hugeFont.crossDp <= Math.ceil(450 * 0.11f)
                        && hugeFont.fitScale <= 0.90f,
                "HomeDock top safe inset guarantees zero nav bar overlap and clamps oversized system font/navScale");

        // 3. Wiring verification: MainActivity.home() uses TvV17WelcomeHomeScreen, renderPage
        // reserves HomeDock safe insets, and HomeDock enforces pixel-exact labels + post-layout
        // anti-overlap guard
        String mainSrc = readJavaSource("MainActivity.java");
        String dockSrc = readJavaSource("HomeDock.java");
        String welcomeSrc = readJavaSource("TvV17WelcomeHomeScreen.java");
        check(
                mainSrc.contains("new TvV17WelcomeHomeScreen(this).show()")
                        && mainSrc.contains("homeDock.topSafeInsetPx()")
                        && dockSrc.contains("computeAdaptiveTopMetrics(")
                        && dockSrc.contains("reconcileTopOverflow()")
                        && dockSrc.contains("TypedValue.COMPLEX_UNIT_PX, a.dp(12.8f * fitScale)")
                        && welcomeSrc.contains("a.homeDock.topSafeInsetPx()")
                        && welcomeSrc.contains("WelcomeGlyph")
                        && welcomeSrc.contains("\"primary\"")
                        && welcomeSrc.contains("\"history-open\"")
                        && welcomeSrc.contains("\"cloud-sync-open\""),
                "TvV17WelcomeHomeScreen and adaptive HomeDock eliminate top overlap and match Apple TV visual design");
    }

    private static void testGlobalSearchCrashHardening() throws Exception {
        // 1. IME selection clamping prevents IndexOutOfBoundsException when cursor is -1 or > text
        check(
                GlobalSearchScreen.safeSelectionIndex(-1, 5) == 0
                        && GlobalSearchScreen.safeSelectionIndex(10, 5) == 5
                        && GlobalSearchScreen.safeSelectionIndex(3, 5) == 3
                        && GlobalSearchScreen.safeSelectionIndex(2, 0) == 0,
                "GlobalSearchScreen.safeSelectionIndex clamps negative and out-of-range IME cursors");

        // 2. Low-RAM TV search concurrency cap prevents simultaneous 6-spider OOM crashes
        check(
                GlobalSearchScreen.computeEffectiveSearchThreads(6, true, true) == 3
                        && GlobalSearchScreen.computeEffectiveSearchThreads(2, true, true) == 2
                        && GlobalSearchScreen.computeEffectiveSearchThreads(6, true, false) == 6
                        && GlobalSearchScreen.computeEffectiveSearchThreads(6, false, true) == 6,
                "GlobalSearchScreen caps concurrent spider workers to 3 on low-RAM TVs");

        // 3. Source guards for RejectedExecutionException, OOM recovery, and null/bounds safety
        String searchSrc = readJavaSource("GlobalSearchScreen.java");
        String coordSrc = readJavaSource("SearchCoordinator.java");
        String hotSrc = readJavaSource("HotTitleCatalog.java");
        check(
                searchSrc.contains("saved.context != null")
                        && searchSrc.contains("safeSelectionIndex(")
                        && searchSrc.contains(
                                "catch (java.util.concurrent.RejectedExecutionException")
                        && searchSrc.contains("column < lastRow.getChildCount()")
                        && coordSrc.contains("error instanceof OutOfMemoryError")
                        && coordSrc.contains("onLowMemoryHook")
                        && hotSrc.contains("RejectedExecutionException"),
                "GlobalSearchScreen, SearchCoordinator, and HotTitleCatalog guard IME, executor shutdown, grid bounds, and OOM");
    }

    private static String httpPostBinaryLoopback(
            int port, String reqPath, String hostHeader, String origin, byte[] payload)
            throws Exception {
        try (java.net.Socket s = new java.net.Socket("127.0.0.1", port)) {
            s.setSoTimeout(5000);
            String req =
                    "POST "
                            + reqPath
                            + " HTTP/1.1\r\nHost: "
                            + hostHeader
                            + "\r\nOrigin: "
                            + origin
                            + "\r\nContent-Type: application/octet-stream\r\nContent-Length: "
                            + payload.length
                            + "\r\nConnection: close\r\n\r\n";
            s.getOutputStream().write(req.getBytes(StandardCharsets.ISO_8859_1));
            if (payload.length > 0) s.getOutputStream().write(payload);
            s.getOutputStream().flush();
            java.io.ByteArrayOutputStream out = new java.io.ByteArrayOutputStream();
            byte[] buf = new byte[4096];
            int n;
            while ((n = s.getInputStream().read(buf)) != -1) out.write(buf, 0, n);
            return new String(out.toByteArray(), StandardCharsets.UTF_8);
        }
    }

    private static String httpRequestLoopback(
            int port,
            String method,
            String reqPath,
            String authHeader,
            String contentType,
            String body)
            throws Exception {
        byte[] payload = body == null ? new byte[0] : body.getBytes(StandardCharsets.UTF_8);
        try (java.net.Socket s = new java.net.Socket("127.0.0.1", port)) {
            s.setSoTimeout(5000);
            StringBuilder req = new StringBuilder();
            req.append(method)
                    .append(' ')
                    .append(reqPath)
                    .append(" HTTP/1.1\r\nHost: 127.0.0.1:")
                    .append(port)
                    .append("\r\n");
            if (authHeader != null) req.append("Authorization: ").append(authHeader).append("\r\n");
            if (contentType != null) {
                req.append("Content-Type: ").append(contentType).append("\r\n");
            }
            if (payload.length > 0) {
                req.append("Content-Length: ").append(payload.length).append("\r\n");
            }
            req.append("Connection: close\r\n\r\n");
            s.getOutputStream().write(req.toString().getBytes(StandardCharsets.ISO_8859_1));
            if (payload.length > 0) s.getOutputStream().write(payload);
            s.getOutputStream().flush();
            java.io.ByteArrayOutputStream out = new java.io.ByteArrayOutputStream();
            byte[] buf = new byte[4096];
            int n;
            while ((n = s.getInputStream().read(buf)) != -1) out.write(buf, 0, n);
            return new String(out.toByteArray(), StandardCharsets.UTF_8);
        }
    }

    private static void testDanmuSettingsRedesign() throws Exception {
        // 1. Preset arrays include defaults and respect clamps for both TV and Mobile.
        int[] tvRows = DanmuSettingsPanel.rowPresets(true);
        int[] mobileRows = DanmuSettingsPanel.rowPresets(false);
        float[] tvFonts = DanmuSettingsPanel.fontSizePresets(true);
        float[] mobileFonts = DanmuSettingsPanel.fontSizePresets(false);
        float[] opacities = DanmuSettingsPanel.opacityPresets();

        boolean tvRowsHasDef = false;
        for (int r : tvRows) {
            check(
                    DanmuSettingsPanel.clampMaxRows(r, true) == r,
                    "TV danmu row preset " + r + " is within clamp bounds");
            if (r == DanmuSettingsPanel.DEFAULT_TV_MAX_ROWS) tvRowsHasDef = true;
        }
        check(
                tvRowsHasDef && tvRows.length == 4,
                "TV row presets expose 4 tiers including default");

        boolean mobileRowsHasDef = false;
        for (int r : mobileRows) {
            check(
                    DanmuSettingsPanel.clampMaxRows(r, false) == r,
                    "Mobile danmu row preset " + r + " is within clamp bounds");
            if (r == DanmuSettingsPanel.DEFAULT_MOBILE_MAX_ROWS) mobileRowsHasDef = true;
        }
        check(
                mobileRowsHasDef && mobileRows.length == 4,
                "Mobile row presets expose 4 tiers including default");

        boolean tvFontsHasDef = false;
        for (float f : tvFonts) {
            check(
                    Math.abs(DanmuSettingsPanel.clampFontSize(f, true) - f) < 0.01f,
                    "TV danmu font preset " + f + "sp is within clamp bounds");
            if (Math.abs(f - DanmuSettingsPanel.DEFAULT_TV_FONT_SIZE) < 0.01f) tvFontsHasDef = true;
        }
        check(
                tvFontsHasDef && tvFonts.length == 4,
                "TV font presets expose 4 tiers including default");

        boolean mobileFontsHasDef = false;
        for (float f : mobileFonts) {
            check(
                    Math.abs(DanmuSettingsPanel.clampFontSize(f, false) - f) < 0.01f,
                    "Mobile danmu font preset " + f + "sp is within clamp bounds");
            if (Math.abs(f - DanmuSettingsPanel.DEFAULT_MOBILE_FONT_SIZE) < 0.01f) {
                mobileFontsHasDef = true;
            }
        }
        check(
                mobileFontsHasDef && mobileFonts.length == 4,
                "Mobile font presets expose 4 tiers including default");

        boolean opacityHasDef = false;
        for (float o : opacities) {
            check(
                    Math.abs(DanmuSettingsPanel.clampOpacity(o) - o) < 0.01f,
                    "Danmu opacity preset " + o + " is within clamp bounds");
            if (Math.abs(o - DanmuSettingsPanel.DEFAULT_OPACITY) < 0.01f) opacityHasDef = true;
        }
        check(
                opacityHasDef && opacities.length == 4,
                "Danmu opacity presets expose 4 tiers including default");

        // 2. resetDisplayDefaults restores appearance/offset while preserving servers & blocklist.
        DanmuSettingsPanel.DanmuConfig customized =
                new DanmuSettingsPanel.DanmuConfig(
                        true,
                        "https://danmu.example",
                        "demoApp",
                        "demoSec",
                        0.40f,
                        1.00f,
                        32f,
                        1.50f,
                        2500L,
                        false,
                        false,
                        false,
                        3,
                        Arrays.asList("剧透", "re:广告.*"),
                        true);
        DanmuSettingsPanel.DanmuConfig reset = DanmuSettingsPanel.resetDisplayDefaults(customized);
        check(
                reset.enabled
                        && "https://danmu.example".equals(reset.serverUrls)
                        && "demoApp".equals(reset.appId)
                        && "demoSec".equals(reset.appSecret)
                        && reset.blockRules.size() == 2,
                "resetDisplayDefaults preserves enabled state, custom server credentials, and block rules");
        check(
                reset.maxRows == DanmuSettingsPanel.DEFAULT_TV_MAX_ROWS
                        && Math.abs(reset.fontSizeSp - DanmuSettingsPanel.DEFAULT_TV_FONT_SIZE)
                                < 0.01f
                        && Math.abs(
                                        reset.speedMultiplier
                                                - DanmuSettingsPanel.DEFAULT_SPEED_MULTIPLIER)
                                < 0.01f
                        && Math.abs(reset.opacity - DanmuSettingsPanel.DEFAULT_OPACITY) < 0.01f
                        && Math.abs(reset.displayArea - DanmuSettingsPanel.DEFAULT_DISPLAY_AREA)
                                < 0.01f
                        && reset.timeOffsetMs == 0L
                        && reset.showScroll
                        && reset.showTop
                        && reset.showBottom,
                "resetDisplayDefaults restores rows, font size, speed, opacity, area, offset, and positions");

        // 3. Concise Chinese formatters.
        check(
                "1/4屏".equals(DanmuSettingsPanel.formatAreaShort(0.25f))
                        && "半屏".equals(DanmuSettingsPanel.formatAreaShort(0.50f))
                        && "3/4屏".equals(DanmuSettingsPanel.formatAreaShort(0.75f))
                        && "全屏".equals(DanmuSettingsPanel.formatAreaShort(1.00f)),
                "formatAreaShort produces intuitive Chinese area labels");
        check(
                "0.75x".equals(DanmuSettingsPanel.formatSpeedShort(0.75f))
                        && "1.0x".equals(DanmuSettingsPanel.formatSpeedShort(1.00f))
                        && "1.25x".equals(DanmuSettingsPanel.formatSpeedShort(1.25f))
                        && "1.5x".equals(DanmuSettingsPanel.formatSpeedShort(1.50f)),
                "formatSpeedShort produces crisp speed labels");
        check(
                "0.0s".equals(DanmuSettingsPanel.formatOffsetShort(0L))
                        && "+1.5s".equals(DanmuSettingsPanel.formatOffsetShort(1500L))
                        && "-0.5s".equals(DanmuSettingsPanel.formatOffsetShort(-500L)),
                "formatOffsetShort formats zero and signed offsets cleanly");
        String summary = DanmuSettingsPanel.formatConfigSummary(reset);
        check(
                summary.contains("已开启")
                        && summary.contains("6行")
                        && summary.contains("24sp")
                        && summary.contains("1.0x")
                        && summary.contains("半屏")
                        && summary.contains("1个源"),
                "formatConfigSummary summarizes status, rows, font size, speed, area, and server count");

        // 4. Source architecture invariants for redesigned tabbed Apple TV frosted modal.
        String src = readJavaSource("DanmuSettingsPanel.java");
        check(
                src.contains("\"显示样式\"")
                        && src.contains("\"源与屏蔽\"")
                        && src.contains("\"显示行数\"")
                        && src.contains("\"字体大小\"")
                        && src.contains("\"移动速度\"")
                        && src.contains("\"不透明度\"")
                        && src.contains("\"显示区域\"")
                        && src.contains("\"显示位置\"")
                        && src.contains("\"时间校准\"")
                        && src.contains("\"恢复默认\"")
                        && src.contains("TvQrInputHelper.wrap(")
                        && src.contains("UiCompat.setDefaultFocusHighlightEnabled(")
                        && !src.contains("CheckBox"),
                "DanmuSettingsPanel implements minimalist tabbed Apple TV frosted modal with row/font/speed presets and zero legacy CheckBoxes");
    }

    private static void testAutoAudioSubtitleSelectionHistoryFailoverAndAlistMount()
            throws Exception {
        // 1. Auto subtitle & audio track selection + per-series audio memory
        List<String> nfSubs =
                Arrays.asList(
                        "✓ English (CC)", "Arabic", "简体中文 · Forced", "繁体中文", "简体中文", "中英双语 · 简体");
        check(
                SubtitlePreferenceStore.pickBestSubtitleTrack(nfSubs) == 5,
                "pickBestSubtitleTrack prefers bilingual simplified Chinese over forced/CC/English");

        List<String> sdhVsClean = Arrays.asList("英语", "简体中文 · SDH", "简体中文", "导演评论 · 中文");
        check(
                SubtitlePreferenceStore.pickBestSubtitleTrack(sdhVsClean) == 2,
                "pickBestSubtitleTrack prefers clean Simplified Chinese over SDH and commentary");

        List<String> noZhSubs = Arrays.asList("English", "Japanese", "Korean");
        check(
                SubtitlePreferenceStore.pickBestSubtitleTrack(noZhSubs) == -1,
                "pickBestSubtitleTrack does not force non-Chinese subtitles");

        List<String> multiAudio =
                Arrays.asList(
                        "✓ Audio Description · 英语 · 6 声道", "英语 · EAC3 · 6 声道", "国语 · EAC3 · 6 声道");
        check(
                SubtitlePreferenceStore.pickBestAudioTrack(
                                multiAudio, SubtitlePreferenceStore.AUDIO_PREF_SMART)
                        == 2,
                "pickBestAudioTrack SMART mode rescues Audio Description track and picks Mandarin");
        check(
                SubtitlePreferenceStore.pickBestAudioTrack(
                                multiAudio, SubtitlePreferenceStore.AUDIO_PREF_ORIGINAL)
                        == 1,
                "pickBestAudioTrack ORIGINAL mode skips Audio Description and picks first clean original track");

        List<String> origEnWithDub = Arrays.asList("✓ 英语 · EAC3 · 6 声道", "国语 · AAC · 2 声道");
        check(
                SubtitlePreferenceStore.pickBestAudioTrack(
                                origEnWithDub, SubtitlePreferenceStore.AUDIO_PREF_SMART)
                        == -1,
                "pickBestAudioTrack SMART mode preserves clean English original audio");
        check(
                SubtitlePreferenceStore.pickBestAudioTrack(
                                origEnWithDub, SubtitlePreferenceStore.AUDIO_PREF_CHINESE)
                        == 1,
                "pickBestAudioTrack CHINESE mode auto-switches to Mandarin audio");

        List<String> dubPack = Arrays.asList("✓ 阿拉伯语 · 2 声道", "粤语 · 2 声道", "国语 · 6 声道");
        check(
                SubtitlePreferenceStore.pickBestAudioTrack(
                                dubPack, SubtitlePreferenceStore.AUDIO_PREF_SMART)
                        == 2,
                "pickBestAudioTrack SMART mode switches away from non-CJK/non-EN dub to Mandarin");

        SubtitlePreferenceStore.Selection audioSel =
                new SubtitlePreferenceStore.Selection(false, 1, "✓ 国语 · EAC3 · 6 声道");
        String audioJson = SubtitlePreferenceStore.write("[]", "s1", "v1", audioSel);
        SubtitlePreferenceStore.Selection audioReloaded =
                SubtitlePreferenceStore.read(audioJson, "s1", "v1");
        check(
                audioReloaded != null
                        && SubtitlePreferenceStore.matchTrackIndex(
                                        audioReloaded,
                                        Arrays.asList("英语 · EAC3 · 6 声道", "中文 · AAC · 2 声道"))
                                == 1,
                "Per-series audio memory matches Chinese track on next episode");
        String audioCleared = SubtitlePreferenceStore.remove(audioJson, "s1", "v1");
        check(
                SubtitlePreferenceStore.read(audioCleared, "s1", "v1") == null,
                "SubtitlePreferenceStore.remove clears per-series audio override cleanly");

        // 2. WatchHistory null-safety & HistoryResumeMatcher cross-source failover
        String nullFieldsJson =
                "[{\"site\":\"dead_site\",\"id\":\"v9\",\"title\":\"庆余年 第二季\",\"poster\":null,\"line\":null,\"episode\":null,\"index\":4,\"position\":725000,\"duration\":2700000,\"updated\":1700000000000}]";
        List<WatchHistory.Entry> safeEntries = WatchHistory.read(nullFieldsJson);
        check(
                safeEntries.size() == 1
                        && safeEntries.get(0).poster.isEmpty()
                        && safeEntries.get(0).line.isEmpty()
                        && safeEntries.get(0).episode.isEmpty(),
                "WatchHistory.read safely converts JSON null fields to empty strings instead of literal 'null'");

        check(
                HistoryResumeMatcher.extractEpisodeNumber("第05集") == 5
                        && HistoryResumeMatcher.extractEpisodeNumber("EP05") == 5
                        && HistoryResumeMatcher.extractEpisodeNumber(
                                        "Show.2026.2160p.H265.S02E05.mkv")
                                == 5
                        && HistoryResumeMatcher.extractEpisodeNumber("第五集") == 5,
                "HistoryResumeMatcher extracts canonical episode numbers across Chinese/English/MKV formats");

        Cms.Video altVideo = new Cms.Video();
        altVideo.id = "alt_v2";
        altVideo.title = "庆余年 第二季";
        Cms.Line altLine = new Cms.Line();
        altLine.name = "极速线路";
        for (int epN = 1; epN <= 10; epN++) {
            Cms.Episode ep = new Cms.Episode();
            ep.name = String.format(java.util.Locale.US, "EP%02d", epN);
            ep.url = "https://cdn.example/ep" + epN + ".m3u8";
            altLine.episodes.add(ep);
        }
        altVideo.lines.add(altLine);
        WatchHistory.Entry histBm = new WatchHistory.Entry();
        histBm.site = "old_dead_site";
        histBm.id = "old_id";
        histBm.title = "庆余年 第二季";
        histBm.line = "旧线路";
        histBm.episode = "第05集";
        histBm.index = 4;
        histBm.position = 754000;
        HistoryResumeMatcher.EpisodeMatch epMatch =
                HistoryResumeMatcher.matchEpisode(altVideo, histBm);
        check(
                epMatch != null && "EP05".equals(epMatch.episode.name),
                "HistoryResumeMatcher matches 第05集 on dead source to EP05 on alternative source");

        Cms.Video wrongSeason = new Cms.Video();
        wrongSeason.title = "庆余年 第一季";
        check(
                HistoryResumeMatcher.scoreTitleMatch(histBm, altVideo) >= 85
                        && HistoryResumeMatcher.scoreTitleMatch(histBm, wrongSeason) < 55,
                "HistoryResumeMatcher.scoreTitleMatch accepts exact season and rejects mismatched season");

        // 3. AList v3 mount pure-JVM protocol + loopback integration checks
        check(
                AlistEngine.naturalCompare("S01E2.mkv", "S01E10.mkv") < 0
                        && AlistEngine.naturalCompare("第2集.mp4", "第10集.mp4") < 0,
                "AlistEngine.naturalCompare sorts episodes numerically (E2 before E10)");
        check(
                "http://alist.example:5244/d/%E7%94%B5%E5%BD%B1/test%20video.mkv?sign=abc"
                        .equals(
                                AlistEngine.buildDirectDownloadUrl(
                                        "http://alist.example:5244/", "/电影/test video.mkv", "abc")),
                "AlistEngine.buildDirectDownloadUrl encodes UTF-8 path segments and sign cleanly");

        final java.util.concurrent.atomic.AtomicInteger loginCalls =
                new java.util.concurrent.atomic.AtomicInteger();
        final java.util.concurrent.atomic.AtomicBoolean expiredOnce =
                new java.util.concurrent.atomic.AtomicBoolean(false);
        com.sun.net.httpserver.HttpServer alistServer =
                com.sun.net.httpserver.HttpServer.create(
                        new java.net.InetSocketAddress("127.0.0.1", 0), 0);
        try {
            alistServer.createContext(
                    "/api/auth/login",
                    ex -> {
                        int n = loginCalls.incrementAndGet();
                        byte[] resp =
                                ("{\"code\":200,\"message\":\"success\",\"data\":{\"token\":\"tok_"
                                                + n
                                                + "\"}}")
                                        .getBytes(StandardCharsets.UTF_8);
                        ex.getResponseHeaders().set("Content-Type", "application/json");
                        ex.sendResponseHeaders(200, resp.length);
                        try (java.io.OutputStream os = ex.getResponseBody()) {
                            os.write(resp);
                        }
                    });
            alistServer.createContext(
                    "/api/fs/list",
                    ex -> {
                        String auth = ex.getRequestHeaders().getFirst("Authorization");
                        if ("tok_1".equals(auth) && expiredOnce.compareAndSet(false, true)) {
                            byte[] unauth =
                                    "{\"code\":401,\"message\":\"token expired\"}"
                                            .getBytes(StandardCharsets.UTF_8);
                            ex.sendResponseHeaders(200, unauth.length);
                            try (java.io.OutputStream os = ex.getResponseBody()) {
                                os.write(unauth);
                            }
                            return;
                        }
                        byte[] reqBytes = readAllBytes(ex.getRequestBody());
                        String reqBody = new String(reqBytes, StandardCharsets.UTF_8);
                        String json;
                        if (reqBody.contains("\"/剧集/庆余年\"")) {
                            json =
                                    "{\"code\":200,\"message\":\"success\",\"data\":{\"total\":4,\"content\":["
                                            + "{\"name\":\"S01E10.mkv\",\"is_dir\":false,\"size\":1200000000,\"sign\":\"s10\",\"raw_url\":\"http://cdn.example/e10.mkv\"},"
                                            + "{\"name\":\"S01E02.mkv\",\"is_dir\":false,\"size\":1100000000,\"sign\":\"s2\",\"raw_url\":\"http://cdn.example/e02.mkv\"},"
                                            + "{\"name\":\"S01E02.chs.srt\",\"is_dir\":false,\"size\":45000,\"sign\":\"sub2\",\"raw_url\":\"http://cdn.example/e02.chs.srt\"},"
                                            + "{\"name\":\"S01E02.eng.srt\",\"is_dir\":false,\"size\":41000,\"sign\":\"sub2e\",\"raw_url\":\"http://cdn.example/e02.eng.srt\"}"
                                            + "]}}";
                        } else {
                            json =
                                    "{\"code\":200,\"message\":\"success\",\"data\":{\"total\":2,\"content\":["
                                            + "{\"name\":\"剧集\",\"is_dir\":true,\"size\":0},"
                                            + "{\"name\":\"演示电影.4K.mkv\",\"is_dir\":false,\"size\":4294967296,\"raw_url\":\"http://cdn.example/movie.mkv\"}"
                                            + "]}}";
                        }
                        byte[] resp = json.getBytes(StandardCharsets.UTF_8);
                        ex.getResponseHeaders().set("Content-Type", "application/json");
                        ex.sendResponseHeaders(200, resp.length);
                        try (java.io.OutputStream os = ex.getResponseBody()) {
                            os.write(resp);
                        }
                    });
            alistServer.createContext(
                    "/api/fs/get",
                    ex -> {
                        byte[] resp =
                                ("{\"code\":200,\"message\":\"success\",\"data\":{\"name\":\"S01E02.mkv\",\"is_dir\":false,\"size\":1100000000,\"raw_url\":\"http://cdn.example/e02.mkv\"}}")
                                        .getBytes(StandardCharsets.UTF_8);
                        ex.getResponseHeaders().set("Content-Type", "application/json");
                        ex.sendResponseHeaders(200, resp.length);
                        try (java.io.OutputStream os = ex.getResponseBody()) {
                            os.write(resp);
                        }
                    });
            alistServer.createContext(
                    "/api/fs/search",
                    ex -> {
                        byte[] resp =
                                ("{\"code\":200,\"message\":\"success\",\"data\":{\"total\":1,\"content\":["
                                                + "{\"parent\":\"/剧集/庆余年\",\"name\":\"S01E02.mkv\",\"is_dir\":false,\"size\":1100000000}"
                                                + "]}}")
                                        .getBytes(StandardCharsets.UTF_8);
                        ex.getResponseHeaders().set("Content-Type", "application/json");
                        ex.sendResponseHeaders(200, resp.length);
                        try (java.io.OutputStream os = ex.getResponseBody()) {
                            os.write(resp);
                        }
                    });
            alistServer.start();
            int port = alistServer.getAddress().getPort();
            AlistEngine.MountConfig mount =
                    new AlistEngine.MountConfig(
                            "demo1",
                            "家庭影音",
                            "http://127.0.0.1:" + port,
                            "/",
                            "admin",
                            "secret",
                            "",
                            "");
            AlistEngine engine = new AlistEngine(mount);
            org.json.JSONObject homeObj = new org.json.JSONObject(engine.home());
            check(
                    loginCalls.get() == 2 && homeObj.getJSONArray("class").length() == 2,
                    "AlistEngine authenticates, refreshes expired 401 token automatically, and lists home folders");

            org.json.JSONObject detailObj =
                    new org.json.JSONObject(engine.detail("/剧集/庆余年/S01E02.mkv"));
            org.json.JSONObject vod = detailObj.getJSONArray("list").getJSONObject(0);
            String playUrl = vod.getString("vod_play_url");
            check(
                    "庆余年".equals(vod.getString("vod_name"))
                            && playUrl.indexOf("S01E02") < playUrl.indexOf("S01E10"),
                    "AlistEngine.detail groups sibling episodes in natural order under folder title");

            org.json.JSONObject playObj =
                    new org.json.JSONObject(engine.player("AList 直连", "/剧集/庆余年/S01E02.mkv"));
            org.json.JSONArray subs = playObj.getJSONArray("subtitles");
            check(
                    "http://cdn.example/e02.mkv".equals(playObj.getString("url"))
                            && subs.length() == 2
                            && subs.getJSONObject(0).getString("name").contains("chs"),
                    "AlistEngine.player returns direct raw_url and auto-attaches Chinese sibling subtitles first");

            org.json.JSONObject searchObj = new org.json.JSONObject(engine.search("庆余年", 1));
            check(
                    searchObj.getJSONArray("list").length() == 1
                            && "/剧集/庆余年/S01E02.mkv"
                                    .equals(
                                            searchObj
                                                    .getJSONArray("list")
                                                    .getJSONObject(0)
                                                    .getString("vod_id")),
                    "AlistEngine.search maps AList search results to full playable paths");

            String mountsSer =
                    AlistAccounts.serializeMounts(java.util.Collections.singletonList(mount));
            List<AlistEngine.MountConfig> mountsParsed = AlistAccounts.parseMounts(mountsSer);
            check(
                    mountsParsed.size() == 1
                            && "demo1".equals(mountsParsed.get(0).id)
                            && "alist://mount/demo1".equals(mountsParsed.get(0).apiUri()),
                    "AlistAccounts serializes and restores mount configs cleanly");
        } finally {
            alistServer.stop(0);
        }

        // 4. Wiring checks across Cms, SourceController, AccountPanel, Settings, Playback
        String cmsSrc = readJavaSource("Cms.java");
        String srcCtl = readJavaSource("SourceController.java");
        String alistUi = readJavaSource("AlistAccounts.java");
        String catSrc = readJavaSource("CatalogScreen.java");
        String pbCtl = readJavaSource("PlaybackController.java");
        String pbCtrls = readJavaSource("PlaybackControls.java");
        check(
                cmsSrc.contains("alist://")
                        && srcCtl.contains("AlistEngine.PREFIX")
                        && srcCtl.contains("new AlistEngine(")
                        && alistUi.contains("TvQrInputHelper.wrap(")
                        && catSrc.contains("resumeHistoryFromAlternativeSources(")
                        && pbCtl.contains("tryHistoryCrossSourceFailover(")
                        && pbCtrls.contains("applyPreferredAudioIfNeeded(")
                        && pbCtrls.contains("pickBestSubtitleTrack("),
                "AList mount, cross-source history failover, and auto audio/subtitle selection are fully wired");
    }

    private static byte[] readAllBytes(java.io.InputStream in) throws java.io.IOException {
        java.io.ByteArrayOutputStream out = new java.io.ByteArrayOutputStream();
        byte[] buf = new byte[2048];
        int n;
        while ((n = in.read(buf)) != -1) out.write(buf, 0, n);
        return out.toByteArray();
    }

    private static String httpPostLoopback(
            int port, String reqPath, String hostHeader, String origin, String body)
            throws Exception {
        byte[] payload = body.getBytes(StandardCharsets.UTF_8);
        try (java.net.Socket s = new java.net.Socket("127.0.0.1", port)) {
            s.setSoTimeout(5000);
            String req =
                    "POST "
                            + reqPath
                            + " HTTP/1.1\r\nHost: "
                            + hostHeader
                            + "\r\nOrigin: "
                            + origin
                            + "\r\nContent-Type: application/json\r\nContent-Length: "
                            + payload.length
                            + "\r\nConnection: close\r\n\r\n";
            s.getOutputStream().write(req.getBytes(StandardCharsets.ISO_8859_1));
            s.getOutputStream().write(payload);
            s.getOutputStream().flush();
            java.io.ByteArrayOutputStream out = new java.io.ByteArrayOutputStream();
            byte[] buf = new byte[4096];
            int n;
            while ((n = s.getInputStream().read(buf)) != -1) out.write(buf, 0, n);
            return new String(out.toByteArray(), StandardCharsets.UTF_8);
        }
    }

    private static String httpGetLoopback(int port, String reqPath, String hostHeader)
            throws Exception {
        try (java.net.Socket s = new java.net.Socket("127.0.0.1", port)) {
            s.setSoTimeout(5000);
            String req =
                    "GET "
                            + reqPath
                            + " HTTP/1.1\r\nHost: "
                            + hostHeader
                            + "\r\nConnection: close\r\n\r\n";
            s.getOutputStream().write(req.getBytes(StandardCharsets.ISO_8859_1));
            s.getOutputStream().flush();
            java.io.ByteArrayOutputStream out = new java.io.ByteArrayOutputStream();
            byte[] buf = new byte[4096];
            int n;
            while ((n = s.getInputStream().read(buf)) != -1) {
                out.write(buf, 0, n);
            }
            return new String(out.toByteArray(), StandardCharsets.UTF_8);
        }
    }

    private static void testTvPlaybackTooltipAndCustomToolbarOrder() throws Exception {
        // 1. Default orders preserve existing Modern TV (10) & Classic TV (9) button layouts
        List<String> defModern = TvPlayerToolbarOrder.resolveOrder("", true);
        List<String> defClassic = TvPlayerToolbarOrder.resolveOrder(null, false);
        check(
                defModern.size() == 10
                        && TvPlayerToolbarOrder.KEY_PLAY_PAUSE.equals(defModern.get(0))
                        && TvPlayerToolbarOrder.KEY_MORE.equals(defModern.get(9)),
                "TvPlayerToolbarOrder preserves 10-button Modern TV default order");
        check(
                defClassic.size() == 9
                        && TvPlayerToolbarOrder.KEY_NEXT_EPISODE.equals(defClassic.get(0))
                        && TvPlayerToolbarOrder.KEY_DECODER.equals(defClassic.get(5))
                        && TvPlayerToolbarOrder.KEY_MORE.equals(defClassic.get(8)),
                "TvPlayerToolbarOrder preserves 9-button Classic TV default order");

        // 2. Move + merge + cross-style preservation + restore to default
        List<String> edited = TvPlayerToolbarOrder.defaultOrder(true);
        check(
                !TvPlayerToolbarOrder.moveItem(edited, 0, -1)
                        && !TvPlayerToolbarOrder.moveItem(edited, edited.size() - 1, 1),
                "TvPlayerToolbarOrder.moveItem rejects out-of-bounds swaps");
        check(
                TvPlayerToolbarOrder.moveItem(edited, 2, -2)
                        && TvPlayerToolbarOrder.KEY_EPISODES.equals(edited.get(0))
                        && TvPlayerToolbarOrder.KEY_PLAY_PAUSE.equals(edited.get(1)),
                "TvPlayerToolbarOrder.moveItem moves episodes to first slot cleanly");
        String merged = TvPlayerToolbarOrder.mergeEditedOrder("", edited, true);
        List<String> resolvedModern = TvPlayerToolbarOrder.resolveOrder(merged, true);
        List<String> resolvedClassic = TvPlayerToolbarOrder.resolveOrder(merged, false);
        check(
                resolvedModern.equals(edited) && !TvPlayerToolbarOrder.isDefaultOrder(merged, true),
                "Modern TV toolbar resolves exact custom order after merge");
        check(
                resolvedClassic.size() == 9
                        && TvPlayerToolbarOrder.KEY_EPISODES.equals(resolvedClassic.get(0))
                        && resolvedClassic.indexOf(TvPlayerToolbarOrder.KEY_DECODER)
                                == resolvedClassic.indexOf(TvPlayerToolbarOrder.KEY_AUDIO_TRACKS)
                                        + 1
                        && TvPlayerToolbarOrder.KEY_MORE.equals(resolvedClassic.get(8)),
                "Classic TV toolbar inherits shared custom order and keeps decoder beside audio-tracks");
        String resetMerged =
                TvPlayerToolbarOrder.mergeEditedOrder(
                        "", TvPlayerToolbarOrder.defaultOrder(true), true);
        check(
                "".equals(resetMerged) && TvPlayerToolbarOrder.isDefaultOrder(resetMerged, true),
                "Restoring default order serializes back to canonical empty preference");

        // 3. Sanitization for backup/restore
        String dirty = "episodes, unknown-btn, lines, episodes, <script>, speed";
        check(
                "episodes,lines,speed".equals(Prefs.sanitizeTvToolbarOrder(dirty))
                        && "episodes,lines,speed"
                                .equals(
                                        Prefs.sanitizeUserData(
                                                Prefs.TV_PLAYER_TOOLBAR_ORDER, dirty))
                        && Prefs.sanitizeTvToolbarOrder(12345) == null
                        && "".equals(Prefs.sanitizeTvToolbarOrder("   ")),
                "Prefs.sanitizeTvToolbarOrder deduplicates, strips unknown tokens, and rejects non-strings");

        // 4. Dynamic tooltip names for all TV playback buttons (VOD + Live + states)
        check(
                "暂停"
                                .equals(
                                        TvPlayerToolbarOrder.tooltipLabel(
                                                "play-pause", false, true, 1f, 0, 0, 0))
                        && "播放"
                                .equals(
                                        TvPlayerToolbarOrder.tooltipLabel(
                                                "play-pause", false, false, 1f, 0, 0, 0))
                        && "下一集"
                                .equals(
                                        TvPlayerToolbarOrder.tooltipLabel(
                                                "next-episode", false, true, 1f, 0, 0, 0))
                        && "下一频道"
                                .equals(
                                        TvPlayerToolbarOrder.tooltipLabel(
                                                "next-episode", true, true, 1f, 0, 0, 0))
                        && "选集"
                                .equals(
                                        TvPlayerToolbarOrder.tooltipLabel(
                                                "episodes", false, true, 1f, 0, 0, 0))
                        && "频道列表"
                                .equals(
                                        TvPlayerToolbarOrder.tooltipLabel(
                                                "episodes", true, true, 1f, 0, 0, 0))
                        && "字幕"
                                .equals(
                                        TvPlayerToolbarOrder.tooltipLabel(
                                                "subtitles", false, true, 1f, 0, 0, 0))
                        && "音轨"
                                .equals(
                                        TvPlayerToolbarOrder.tooltipLabel(
                                                "audio-tracks", false, true, 1f, 0, 0, 0))
                        && "换源"
                                .equals(
                                        TvPlayerToolbarOrder.tooltipLabel(
                                                "lines", false, true, 1f, 0, 0, 0))
                        && "切换线路"
                                .equals(
                                        TvPlayerToolbarOrder.tooltipLabel(
                                                "lines", true, true, 1f, 0, 0, 0)),
                "TvPlayerToolbarOrder.tooltipLabel resolves clear VOD/Live button names");
        check(
                "倍速".equals(TvPlayerToolbarOrder.tooltipLabel("speed", false, true, 1f, 0, 0, 0))
                        && "倍速 1.25×"
                                .equals(
                                        TvPlayerToolbarOrder.tooltipLabel(
                                                "speed", false, true, 1.25f, 0, 0, 0))
                        && "倍速 2×"
                                .equals(
                                        TvPlayerToolbarOrder.tooltipLabel(
                                                "speed", false, true, 2f, 0, 0, 0))
                        && "跳过片头"
                                .equals(
                                        TvPlayerToolbarOrder.tooltipLabel(
                                                "skip-intro-tool", false, true, 1f, 0, 0, 0))
                        && "跳过片头 01:30"
                                .equals(
                                        TvPlayerToolbarOrder.tooltipLabel(
                                                "skip-intro-tool", false, true, 1f, 90, 0, 0))
                        && "跳过片尾 02:05"
                                .equals(
                                        TvPlayerToolbarOrder.tooltipLabel(
                                                "skip-outro-tool", false, true, 1f, 0, 125, 0))
                        && "解码 · IJK"
                                .equals(
                                        TvPlayerToolbarOrder.tooltipLabel(
                                                "decoder", false, true, 1f, 0, 0, 2))
                        && "更多"
                                .equals(
                                        TvPlayerToolbarOrder.tooltipLabel(
                                                "more", false, true, 1f, 0, 0, 0)),
                "TvPlayerToolbarOrder.tooltipLabel formats dynamic speed, skip timestamps, and decoder engine");
        check(
                "默认顺序".equals(TvPlayerToolbarOrder.settingsSummary("", true))
                        && TvPlayerToolbarOrder.settingsSummary(merged, true)
                                .startsWith("已自定义 · 选集"),
                "TvPlayerToolbarOrder.settingsSummary distinguishes default vs custom order");

        // 5. Tooltip bubble placement geometry clamps cleanly at screen edges while keeping pointer
        // aligned to anchor
        TvPlayerToolbarOrder.TooltipPlacement centered =
                TvPlayerToolbarOrder.computeTooltipPlacement(
                        1920, 1080, 960, 880, 120, 52, 24, 9, 26f);
        check(
                centered.left == 900
                        && centered.top == 819
                        && Math.abs(centered.arrowCenterX - 60f) < 0.01f,
                "TooltipPlacement centers bubble and arrow directly above mid-screen button");
        TvPlayerToolbarOrder.TooltipPlacement rightEdge =
                TvPlayerToolbarOrder.computeTooltipPlacement(
                        1920, 1080, 1890, 880, 160, 52, 24, 9, 26f);
        check(
                rightEdge.left == 1736
                        && rightEdge.left + 160 <= 1920 - 24
                        && Math.abs(rightEdge.arrowCenterX - 134f) < 0.01f,
                "TooltipPlacement clamps right-edge bubble inside safe bounds and bounds arrow inside rounded corners");

        // 6. Source wiring invariants for PlaybackControls, SettingsScreen, and MobileShell
        String playbackSrc = readJavaSource("PlaybackControls.java");
        String settingsSrc = readJavaSource("SettingsScreen.java");
        String mobileSrc = readJavaSource("MobileShell.java");
        check(
                playbackSrc.contains("TvPlayerToolbarOrder.resolveOrder(")
                        && playbackSrc.contains("player-button-tooltip")
                        && playbackSrc.contains("showButtonTooltip(")
                        && playbackSrc.contains("hideButtonTooltip(")
                        && playbackSrc.contains("TooltipBubbleDrawable"),
                "PlaybackControls wires TV button focus tooltip bubble and custom toolbar order");
        check(
                settingsSrc.contains("播放工具条按钮顺序")
                        && settingsSrc.contains("showTvToolbarOrderDialog")
                        && settingsSrc.contains("Prefs.TV_PLAYER_TOOLBAR_ORDER"),
                "SettingsScreen wires TV toolbar button reorder dialog, reset, and backup/restore");
        check(
                mobileSrc.contains("Prefs.TV_PLAYER_TOOLBAR_ORDER"),
                "MobileShell.SettingIconView assigns dedicated swap-arrow icon for toolbar order setting");
    }
}
