package com.pilipala.marcomovie;

import android.content.DialogInterface;
import com.pilipala.glass.GlassworkSurface;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/**
 * Comprehensive unit + wiring checks covering all 9 Android TV 0.6.3 optimizations:
 * 1) UpdateScreen layout refactor, collapsed notes, default focus on "立即下载"
 * 2) SettingsScreen default focus on left primary rail
 * 3) Update install dialog default focus on "确认安装"
 * 4) Local USB hard drive discovery, smart movie/series grouping, NFO, JSON cache & poster wall
 * 5) Mine page compact header without avatar hero banner + USB drive entry
 * 6) Double-Layer player frameless floating timeline + icon dock + Chinese tooltips + silent pause + skip parity
 * 7) Universal in-series episode scraping, constant-number suppression, special isolation & Danmaku matching
 * 8) Home exit dialog GlassworkSurface alpha=0 retry, liquid-glass buttons & default focus on "退出应用"
 * 9) Real-time loading network speed monitor & mid-playback buffering wiring across engines
 */
public final class Tv063OptimizationChecks {
    private static int passed;

    private static void check(boolean cond, String desc) {
        if (!cond) {
            throw new AssertionError("FAILED: " + desc);
        }
        passed++;
        System.out.println("PASS " + desc);
    }

    private static String readSrc(String relativePath) throws Exception {
        Path p = Paths.get(relativePath);
        return new String(Files.readAllBytes(p), StandardCharsets.UTF_8);
    }

    private static Cms.Episode ep(String name, String url) {
        Cms.Episode e = new Cms.Episode();
        e.name = name;
        e.url = url;
        return e;
    }

    public static void main(String[] args) throws Exception {
        checkItem1UpdateScreen();
        checkItem2SettingsFocus();
        checkItem3UpdateInstallFocus();
        checkItem4And5LocalUsbAndMine();
        checkItem6DoubleLayerAndPause();
        checkItem7EpisodeScrapingAndDanmaku();
        checkItem8ExitDialogLiquidGlass();
        checkItem9LoadingNetworkSpeed();
        checkPrefsKeyCountInvariant();
        System.out.println("ALL PASS (" + passed + " TV 0.6.3 optimization checks)");
    }

    private static void checkItem1UpdateScreen() throws Exception {
        String longNotes =
                "## 主要更新\n"
                        + "- 重构更新页面布局：采用单屏双栏结构\n"
                        + "- 修复设置页初始焦点：进入默认聚焦左栏\n"
                        + "- 修复安装确认焦点：默认聚焦确认安装\n"
                        + "- 新增移动硬盘海报墙：自动刮削封面\n"
                        + "- 优化我的页面顶部：去除多余头像横条\n"
                        + "- 升级双层播放器界面：图标底栏加中文气泡\n"
                        + "- 新增剧集内刮削能力：精准匹配弹幕与集号\n";
        UpdateScreen.PreviewNotes preview =
                UpdateScreen.buildPreviewData(longNotes, UpdateScreen.TV_PREVIEW_MAX_ITEMS);
        check(preview.totalItems >= 7, "Item1 buildPreviewData counts all changelog items");
        check(
                preview.previewItems.size() == UpdateScreen.TV_PREVIEW_MAX_ITEMS,
                "Item1 buildPreviewData caps visible preview to 4 highlights");
        check(
                preview.hiddenItems == preview.totalItems - UpdateScreen.TV_PREVIEW_MAX_ITEMS,
                "Item1 buildPreviewData computes exact hidden item count");

        check(
                "立即下载".equals(UpdateScreen.resolvePrimaryButtonLabel(false, false, "0.6.3", true)),
                "Item1 TV primary button label is '立即下载' when update is available");
        check(
                "立即安装 0.6.3"
                        .equals(UpdateScreen.resolvePrimaryButtonLabel(false, true, "0.6.3", true)),
                "Item1 TV primary button label switches to '立即安装' when downloaded");
        check(
                "取消下载".equals(UpdateScreen.resolvePrimaryButtonLabel(true, false, "0.6.3", true)),
                "Item1 TV primary button label switches to '取消下载' while busy");

        String updateSrc =
                readSrc("android-tv/src/main/java/com/pilipala/marcomovie/UpdateScreen.java");
        check(
                updateSrc.contains("showTvLayout()")
                        && updateSrc.contains("showFullReleaseNotesDialog")
                        && updateSrc.contains("a.tvInitialFocus = primaryBtn")
                        && updateSrc.contains("notesBody.setFocusable(false)"),
                "Item1 UpdateScreen refactors TV layout, disables notes focus trap, and defaults focus to primaryBtn");
    }

    private static void checkItem2SettingsFocus() throws Exception {
        String settingsSrc =
                readSrc("android-tv/src/main/java/com/pilipala/marcomovie/SettingsScreen.java");
        String mainSrc =
                readSrc("android-tv/src/main/java/com/pilipala/marcomovie/MainActivity.java");
        check(
                settingsSrc.contains("a.tvInitialFocus = tvActiveCategoryButton"),
                "Item2 SettingsScreen declares left primary category button as tvInitialFocus");
        check(
                mainSrc.contains("View first = tvInitialFocus;")
                        && mainSrc.indexOf("View first = tvInitialFocus;")
                                < mainSrc.indexOf("root.findViewWithTag(\"primary\")"),
                "Item2 MainActivity.restore prioritizes tvInitialFocus before right-pane body fallback");
    }

    private static void checkItem3UpdateInstallFocus() throws Exception {
        check(
                AppDialog.resolveInitialFocusActionCode(
                                DialogInterface.BUTTON_POSITIVE, false, true, true, true, false)
                        == DialogInterface.BUTTON_POSITIVE,
                "Item3 AppDialog.resolveInitialFocusActionCode honors explicit BUTTON_POSITIVE even with content");
        check(
                AppDialog.resolveInitialFocusActionCode(0, false, false, true, true, false)
                        == DialogInterface.BUTTON_POSITIVE,
                "Item3 AppDialog defaults focus to BUTTON_POSITIVE when message is non-scrollable");

        String updateSrc =
                readSrc("android-tv/src/main/java/com/pilipala/marcomovie/UpdateScreen.java");
        check(
                updateSrc.contains(".setPositiveButton(\"确认安装\"")
                        && updateSrc.contains(
                                ".setDefaultFocusButton(DialogInterface.BUTTON_POSITIVE)"),
                "Item3 UpdateScreen.install labels confirm action '确认安装' and focuses BUTTON_POSITIVE");
    }

    private static void checkItem4And5LocalUsbAndMine() throws Exception {
        String sampleMounts =
                "/dev/fuse /storage/emulated fuse rw,nosuid 0 0\n"
                        + "/dev/block/vold/public:8,1 /storage/9C33-6BBD exfat rw,nosuid 0 0\n"
                        + "/dev/block/sda1 /mnt/usb/sda1 ntfs3 ro,relatime 0 0\n"
                        + "/dev/block/dm-0 /mnt/runtime/default/emulated sdcardfs rw 0 0\n"
                        + "/dev/block/sdb1 /mnt/media_rw/My\\040Drive vfat rw 0 0\n";
        List<String> parsedMounts = LocalDriveScanner.parseProcMounts(sampleMounts);
        check(
                parsedMounts.contains("/storage/9C33-6BBD")
                        && parsedMounts.contains("/mnt/usb/sda1")
                        && parsedMounts.contains("/mnt/media_rw/My Drive"),
                "Item4 parseProcMounts detects exFAT, NTFS3, and escaped-space vFAT USB mounts");
        check(
                !parsedMounts.contains("/storage/emulated")
                        && !parsedMounts.contains("/mnt/runtime/default/emulated"),
                "Item4 parseProcMounts filters out internal emulated storage");

        // Multi-season TV show + flat movie folder grouping test
        List<LocalDriveScanner.ScannedFile> files = new ArrayList<>();
        files.add(
                new LocalDriveScanner.ScannedFile(
                        "fs:/storage/USB",
                        "移动硬盘",
                        "Three.Body.S01E10.2160p.WEB-DL.H.265.mkv",
                        "/storage/USB/三体/Season 1",
                        "Season 1",
                        "三体",
                        "file:///storage/USB/三体/Season 1/Three.Body.S01E10.mkv",
                        2_500_000_000L,
                        1000L,
                        "file:///storage/USB/三体/poster.jpg",
                        "",
                        "",
                        Collections.singletonList(
                                "file:///storage/USB/三体/Season 1/Three.Body.S01E10.srt")));
        files.add(
                new LocalDriveScanner.ScannedFile(
                        "fs:/storage/USB",
                        "移动硬盘",
                        "Three.Body.S01E02.2160p.WEB-DL.H.265.mkv",
                        "/storage/USB/三体/Season 1",
                        "Season 1",
                        "三体",
                        "file:///storage/USB/三体/Season 1/Three.Body.S01E02.mkv",
                        2_400_000_000L,
                        1000L,
                        "",
                        "",
                        "",
                        Collections.<String>emptyList()));
        files.add(
                new LocalDriveScanner.ScannedFile(
                        "fs:/storage/USB",
                        "移动硬盘",
                        "Three.Body.S02E01.2160p.mkv",
                        "/storage/USB/三体/Season 2",
                        "Season 2",
                        "三体",
                        "file:///storage/USB/三体/Season 2/Three.Body.S02E01.mkv",
                        2_600_000_000L,
                        1000L,
                        "",
                        "",
                        "",
                        Collections.<String>emptyList()));
        files.add(
                new LocalDriveScanner.ScannedFile(
                        "fs:/storage/USB",
                        "移动硬盘",
                        "Inception.2010.2160p.BluRay.x265.mkv",
                        "/storage/USB/Movies",
                        "Movies",
                        "USB",
                        "file:///storage/USB/Movies/Inception.2010.2160p.BluRay.x265.mkv",
                        15_000_000_000L,
                        2000L,
                        "",
                        "",
                        "",
                        Collections.<String>emptyList()));
        files.add(
                new LocalDriveScanner.ScannedFile(
                        "fs:/storage/USB",
                        "移动硬盘",
                        "Interstellar.2014.4K.HDR.mkv",
                        "/storage/USB/Movies",
                        "Movies",
                        "USB",
                        "file:///storage/USB/Movies/Interstellar.2014.4K.HDR.mkv",
                        18_000_000_000L,
                        2000L,
                        "",
                        "",
                        "",
                        Collections.singletonList(
                                "file:///storage/USB/Movies/Interstellar.2014.4K.HDR.zh.ass")));

        List<LocalMediaLibrary.LocalVideoItem> grouped =
                LocalMediaLibrary.groupScannedFiles(files, new HashMap<>());
        check(
                grouped.size() == 3,
                "Item4 groupScannedFiles merges Season 1+2 into 1 series and keeps 2 flat movies separate");
        LocalMediaLibrary.LocalVideoItem series = grouped.get(0);
        check(
                series.isSeries && "三体".equals(series.title),
                "Item4 series title resolves to parent show folder");
        check(series.episodes.size() == 3, "Item4 series collects all 3 episodes across seasons");
        check(
                series.episodes.get(0).episodeNumber == 2
                        && series.episodes.get(1).episodeNumber == 10
                        && series.episodes.get(2).season == 2
                        && series.episodes.get(2).episodeNumber == 1,
                "Item4 series episodes sort cleanly by (season, episodeNumber): S01E02 -> S01E10 -> S02E01");
        LocalMediaLibrary.LocalVideoItem movieWithSub = null;
        for (LocalMediaLibrary.LocalVideoItem it : grouped) {
            if (!it.isSeries && it.rawTitle.contains("Interstellar")) movieWithSub = it;
        }
        check(movieWithSub != null, "Item4 finds local movie with sibling subtitle");
        Cms.Video cmsMovie = movieWithSub.toCmsVideo();
        org.json.JSONArray attachedSubs =
                cmsMovie.lines.get(0).episodes.get(0).media.optJSONArray("subtitles");
        check(
                attachedSubs != null
                        && attachedSubs.length() == 1
                        && attachedSubs.optJSONObject(0).optString("url").endsWith(".zh.ass"),
                "Item4 toCmsVideo wires sibling local USB subtitles into Cms.Episode.media");

        LocalMediaLibrary.LocalVideoItem nfoTarget = new LocalMediaLibrary.LocalVideoItem();
        LocalMediaLibrary.parseNfoInto(
                nfoTarget,
                "<movie><title>星际穿越</title><year>2014</year><rating>9.4</rating><plot>穿越虫洞</plot></movie>");
        check(
                "星际穿越".equals(nfoTarget.title)
                        && "2014".equals(nfoTarget.year)
                        && Math.abs(nfoTarget.doubanScore - 9.4) < 0.01
                        && "穿越虫洞".equals(nfoTarget.synopsis),
                "Item4 parseNfoInto reads Kodi/Emby title, year, rating, and plot");

        String serialized = LocalMediaLibrary.serializeLibraryJson(grouped);
        List<LocalMediaLibrary.LocalVideoItem> restored =
                LocalMediaLibrary.parseLibraryJson(serialized);
        check(
                restored.size() == grouped.size()
                        && restored.get(0).episodes.size() == 3
                        && "file:///storage/USB/三体/poster.jpg".equals(restored.get(0).posterUrl),
                "Item4 LocalMediaLibrary JSON cache roundtrips losslessly");

        check(
                ImageLoader.isLocalArtworkAddress("file:///storage/USB/poster.jpg")
                        && ImageLoader.isLocalArtworkAddress(
                                "content://com.android.externalstorage/doc/1")
                        && !ImageLoader.isLocalArtworkAddress("https://source.test/p.jpg"),
                "Item4 ImageLoader supports file:// and content:// local artwork URIs");

        String mineSrc =
                readSrc("android-tv/src/main/java/com/pilipala/marcomovie/TvV17MineScreen.java");
        check(
                !mineSrc.contains("mine-profile-hero")
                        && !mineSrc.contains("renderProfileHero")
                        && mineSrc.contains("mine-compact-header")
                        && mineSrc.contains("mine-local-drive")
                        && mineSrc.contains("TvLocalDriveScreen"),
                "Item4+5 Mine screen removes bulky avatar hero banner and exposes '移动硬盘' poster-wall entry");
    }

    private static void checkItem6DoubleLayerAndPause() throws Exception {
        check(
                !PlaybackController.shouldShowHudOnPauseToggle(true, false, false),
                "Item6 TV pause with hidden HUD keeps HUD hidden");
        check(
                !PlaybackController.shouldShowHudOnPauseToggle(true, true, false),
                "Item6 TV pause does not force toolbar HUD open");
        check(
                PlaybackController.shouldShowHudOnPauseToggle(false, false, false),
                "Item6 Mobile touch pause preserves touch overlay behavior");

        String controlsSrc =
                readSrc("android-tv/src/main/java/com/pilipala/marcomovie/PlaybackControls.java");
        String chromeSrc =
                readSrc("android-tv/src/main/java/com/pilipala/marcomovie/PlayerChrome.java");
        check(
                controlsSrc.contains("ICON_DECODER = 11")
                        && controlsSrc.contains("addClassicToolbarAction")
                        && controlsSrc.contains("if (!a.isTvDevice()) return;"),
                "Item6 Double-Layer toolbar uses vector icons including ICON_DECODER and syncs Live/Movie visibility on all TV styles");
        check(
                controlsSrc.contains("openSkipEditDialog(n == 0)"),
                "Item6 More menu intro/outro opens adjuster directly in parity with Floating Card");
        check(
                chromeSrc.contains("tvMinimalPauseBadge")
                        && chromeSrc.contains("MinimalPauseBadge")
                        && chromeSrc.contains("player-minimal-pause"),
                "Item6 PlayerChrome mounts subtle MinimalPauseBadge directly in playbackLayer without toolbar HUD");
    }

    private static void checkItem7EpisodeScrapingAndDanmaku() throws Exception {
        // 1. Constant franchise number + tech noise + leading special + scrambled lexicographic
        // order
        List<Cms.Episode> noisyLine =
                Arrays.asList(
                        ep("先导片_斗罗大陆2_4K_60fps.mkv", "u0"),
                        ep("斗罗大陆2_10_H.265_1920x1080_DDP5.1_[1.8GB].mkv", "u10"),
                        ep("斗罗大陆2_02_H.265_60fps.mkv", "u2"),
                        ep("斗罗大陆2_01_2160p_HDR10+.mkv", "u1"),
                        ep("SP01 特别篇花絮.mkv", "usp"));
        TvSeriesScraper.ScrapedLine scraped =
                TvSeriesScraper.scrapeLine("斗罗大陆2 [4K高码]", noisyLine, null);
        check(
                scraped.sourceOrderScrambled,
                "Item7 detects scrambled lexicographic order + leading special");
        check(
                scraped.regularCount == 3 && scraped.specialCount == 2,
                "Item7 isolates 2 specials from 3 regular episodes");
        check(scraped.atSourceIndex(0).isSpecial, "Item7 marks 先导片 as special");
        check(
                scraped.atSourceIndex(1).episodeNumber == 10,
                "Item7 strips H.265/1920x1080/DDP5.1/1.8GB to extract Ep 10");
        check(
                scraped.atSourceIndex(2).episodeNumber == 2,
                "Item7 suppresses franchise '2' noise and still parses real Ep 2");
        check(
                scraped.atSourceIndex(3).episodeNumber == 1,
                "Item7 suppresses franchise '2' so Ep 1 is NOT misread as Ep 2");
        check(scraped.atSourceIndex(4).isSpecial, "Item7 marks SP01 as special");

        List<Integer> sorted = scraped.orderedIndices(true, false, false);
        check(
                sorted.get(0) == 3 && sorted.get(1) == 2 && sorted.get(2) == 1,
                "Item7 orderedIndices sorts regular episodes 1 -> 2 -> 10 before specials");

        // Bare numeric episodes on a sequel franchise ("斗罗大陆2") must NOT drop Ep 2!
        List<Cms.Episode> bareSequelLine =
                Arrays.asList(ep("01", "b1"), ep("02", "b2"), ep("03", "b3"));
        TvSeriesScraper.ScrapedLine bareScraped =
                TvSeriesScraper.scrapeLine("斗罗大陆2", bareSequelLine, null);
        check(
                bareScraped.atSourceIndex(0).episodeNumber == 1
                        && bareScraped.atSourceIndex(1).episodeNumber == 2
                        && bareScraped.atSourceIndex(2).episodeNumber == 3,
                "Item7 bare numeric episodes ('01','02','03') under sequel title preserve Ep 2");

        // 2. Danmaku real episode number (never shifts by leading special; returns 0 for single
        // movies!)
        int danmuEpForIdx3 =
                TvSeriesScraper.resolveDanmuEpisodeNumber("斗罗大陆2 [4K]", noisyLine, 3, null);
        check(
                danmuEpForIdx3 == 1,
                "Item7 resolveDanmuEpisodeNumber returns real Ep 1 (not array index 4!)");

        SeriesScrapeStore.OverrideRecord offsetOv = new SeriesScrapeStore.OverrideRecord();
        offsetOv.episodeOffset = 12;
        int offsetEp = TvSeriesScraper.resolveDanmuEpisodeNumber("斗罗大陆2", noisyLine, 3, offsetOv);
        check(offsetEp == 13, "Item7 episodeOffset (+12) shifts Danmaku query cleanly to Ep 13");

        List<Cms.Episode> singleMovie = Collections.singletonList(ep("4K蓝光正片", "umovie"));
        check(
                TvSeriesScraper.resolveDanmuEpisodeNumber("流浪地球2", singleMovie, 0, null) == 0,
                "Item7 single-stream movie resolves Danmaku episode number to 0 (no bogus E01)");

        DanmuProvider.MatchQuery movieQuery =
                new DanmuProvider.MatchQuery("流浪地球2 [4K蓝光]", "正片", 0, 10000L, -1, true, "", "");
        check(
                "流浪地球2".equals(DandanplayProvider.buildCleanFileName(movieQuery)),
                "Item7 DandanplayProvider cleans movie title and omits E01");

        DanmuProvider.MatchQuery s2Query =
                new DanmuProvider.MatchQuery("咒术回战", "S02E05", 5, 1440L, 2, false, "", "");
        check(
                "咒术回战 S02 E05".equals(DandanplayProvider.buildCleanFileName(s2Query)),
                "Item7 DandanplayProvider includes season S02 and real scraped E05");

        double goodScore = DandanplayProvider.scoreSearchCandidate("斗罗大陆", 1, 5, "斗罗大陆", "第5集");
        double motionComicScore =
                DandanplayProvider.scoreSearchCandidate("斗罗大陆", 1, 5, "斗罗大陆 动态漫画", "第5集");
        check(
                goodScore > motionComicScore + 0.20,
                "Item7 DandanplayProvider candidate scorer penalizes 动态漫画 mismatches");

        // 3. Cross-line episode matching
        Cms.Line lineA = new Cms.Line();
        lineA.name = "线路A";
        lineA.episodes.addAll(Arrays.asList(ep("第01集", "a1"), ep("第05集", "a5")));
        Cms.Line lineB = new Cms.Line();
        lineB.name = "夸克4K";
        lineB.episodes.addAll(
                Arrays.asList(
                        ep("Show.S01E05.2160p.mkv", "b5"), ep("Show.S01E01.2160p.mkv", "b1")));
        Cms.Episode matched =
                TvSeriesScraper.findMatchingEpisodeAcrossLines(
                        "Show", lineB, lineA, lineA.episodes.get(1), null);
        check(
                matched != null && "b5".equals(matched.url),
                "Item7 cross-line matching jumps to S01E05 even when target line is reversed");

        // 4. SeriesScrapeStore JSON serialization roundtrip
        SeriesScrapeStore.OverrideRecord rec = new SeriesScrapeStore.OverrideRecord();
        rec.matchedTitle = "三体";
        rec.metadataSource = "douban";
        rec.episodeOffset = -1;
        rec.hideSpecials = true;
        rec.danmuAnimeId = "12345";
        rec.episodeNumberOverrides.put(0, 7);
        rec.officialEpisodeTitles.put(7, "射手与农场主");
        Map<String, SeriesScrapeStore.OverrideRecord> map = new HashMap<>();
        map.put("item:s1::v1", rec);
        Map<String, SeriesScrapeStore.OverrideRecord> parsedMap =
                SeriesScrapeStore.parseMapJson(SeriesScrapeStore.serializeMapJson(map));
        SeriesScrapeStore.OverrideRecord rt = parsedMap.get("item:s1::v1");
        check(
                rt != null
                        && "三体".equals(rt.matchedTitle)
                        && rt.episodeOffset == -1
                        && rt.hideSpecials
                        && "12345".equals(rt.danmuAnimeId)
                        && Integer.valueOf(7).equals(rt.episodeNumberOverrides.get(0))
                        && "射手与农场主".equals(rt.officialEpisodeTitles.get(7)),
                "Item7 SeriesScrapeStore serializes and restores overrides losslessly");
    }

    private static void checkItem8ExitDialogLiquidGlass() throws Exception {
        check(
                GlassworkSurface.shouldRetryBlockedCapture(
                        true, false, true, false, true, 0f, 520, 220, 0),
                "Item8 GlassworkSurface retries capture when panel alpha=0 during entrance animation");
        check(
                GlassworkSurface.shouldRetryBlockedCapture(
                        true, false, true, false, true, 1f, 0, 0, 0),
                "Item8 GlassworkSurface retries capture when panel has not laid out (w=0)");
        check(
                !GlassworkSurface.shouldRetryBlockedCapture(
                        true, false, true, false, true, 1f, 520, 220, 0),
                "Item8 GlassworkSurface does not retry once view is shown, alpha>=0.01, and laid out");
        check(
                !GlassworkSurface.shouldRetryBlockedCapture(
                        true, false, true, false, true, 0f, 520, 220, 24),
                "Item8 GlassworkSurface retry count is strictly bounded (max 24)");

        String mainSrc =
                readSrc("android-tv/src/main/java/com/pilipala/marcomovie/MainActivity.java");
        String dialogSrc =
                readSrc("android-tv/src/main/java/com/pilipala/marcomovie/AppDialog.java");
        check(
                mainSrc.contains("if (exitBtn != null) {\n            exitBtn.requestFocus();")
                        || mainSrc.contains("exitBtn.requestFocus();"),
                "Item8 MainActivity.confirmExitApp defaults focus on exitBtn ('退出应用')");
        check(
                dialogSrc.contains("useLiquidGlassButtons()")
                        && dialogSrc.contains("panel.setAlpha(0.02f)")
                        && dialogSrc.contains("GlassworkSurface.forceRecapture(panel)"),
                "Item8 AppDialog styles TV buttons with liquid glass and recaptures after entrance");
    }

    private static void checkItem9LoadingNetworkSpeed() throws Exception {
        check(
                "测速中…".equals(NetworkSpeedMonitor.formatSpeed(-1L)),
                "Item9 formats negative rate as '测速中…'");
        check(
                "0 KB/s".equals(NetworkSpeedMonitor.formatSpeed(0L)),
                "Item9 formats zero rate as '0 KB/s'");
        check("512 B/s".equals(NetworkSpeedMonitor.formatSpeed(512L)), "Item9 formats byte rate");
        check(
                "320 KB/s".equals(NetworkSpeedMonitor.formatSpeed(320L * 1024L)),
                "Item9 formats KB/s rate");
        check(
                "4.5 MB/s".equals(NetworkSpeedMonitor.formatSpeed((long) (4.5 * 1024 * 1024))),
                "Item9 formats MB/s rate");
        check(
                NetworkSpeedMonitor.computeRateBytesPerSec(1024L * 1024L, 500L)
                        == 2L * 1024L * 1024L,
                "Item9 computes accurate bytes/sec from sliding delta");
        check(
                NetworkSpeedMonitor.computeRateBytesPerSec(100L, 0L) == -1L,
                "Item9 guards zero/negative elapsed intervals");

        String loadingSrc =
                readSrc("android-tv/src/main/java/com/pilipala/marcomovie/PlaybackLoading.java");
        String chromeSrc =
                readSrc("android-tv/src/main/java/com/pilipala/marcomovie/PlayerChrome.java");
        String mpvSrc = readSrc("android-tv/src/main/java/com/pilipala/marcomovie/MpvPlayer.java");
        String exoSrc =
                readSrc("android-tv/src/main/java/com/pilipala/marcomovie/MoviePlayer.java");
        check(
                loadingSrc.contains("NetworkSpeedMonitor")
                        && chromeSrc.contains("loadingSpeedMonitor")
                        && chromeSrc.contains("setBuffering(")
                        && mpvSrc.contains("\"cache-speed\"")
                        && mpvSrc.contains("\"paused-for-cache\"")
                        && exoSrc.contains("Player.STATE_BUFFERING"),
                "Item9 wires real-time network speed & mid-playback buffering across PlaybackLoading, PlayerChrome, ExoPlayer, and MPV");
    }

    private static void checkPrefsKeyCountInvariant() {
        check(
                Prefs.KEYS.length == 46,
                "Invariant: Prefs.KEYS.length remains strictly 46 (overrides stored in dedicated preference files)");
    }
}
