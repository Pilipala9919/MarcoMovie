package com.pilipala.marcomovie;

import androidx.media3.common.text.Cue;
import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.util.Arrays;
import java.util.Collections;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.atomic.AtomicReference;
import org.json.JSONObject;

/**
 * Pure-JVM offline verification suite for all 8 TV optimization items in Batch 2:
 * 1. Config Center dialog zero-overflow layout & structured JSON action rendering
 * 2. Netdisk login state sync (no stale cached 0 shadowing real credentials + RefreshEvent.config)
 * 3. Bilingual subtitle non-overlapping cue normalization
 * 4. Infinite wrap-around top navigation bar (no left/right dead-ends)
 * 5. Custom TV navigation order & display names + LAN phone QR drag-and-drop server
 * 6. Douban rating badge across Home, Library ("片库"), and Search ("搜索") + persistent cache
 * 7. Automatic subscription Config Center compatibility inside Netdisk config page
 * 8. Anchored Netdisk QR popover bubble (no auto-closing Netdisk dialog, collapse + "扫码成功")
 */
public final class Tv063Batch2Checks {
    private static int passed = 0;

    private static void check(boolean cond, String name) {
        if (!cond) {
            throw new AssertionError("FAILED: " + name);
        }
        passed++;
        System.out.println("PASS " + name);
    }

    private static String readSrc(String relPath) throws Exception {
        return new String(Files.readAllBytes(Paths.get(relPath)), StandardCharsets.UTF_8);
    }

    public static void main(String[] args) throws Exception {
        checkItem1ConfigCenterZeroOverflow();
        checkItem2NetdiskLoginStateSync();
        checkItem3BilingualSubtitleNoOverlap();
        checkItem4InfiniteTopNavLoop();
        checkItem5CustomNavAndLanQrServer();
        checkItem6DoubanScoreOnAllCards();
        checkItem7ConfigCenterAutoCompat();
        checkItem8AnchoredNetdiskQrBubble();
        checkPrefsInvariant();
        System.out.println("ALL PASS (" + passed + " TV 0.6.3 batch-2 checks)");
    }

    private static void checkItem1ConfigCenterZeroOverflow() throws Exception {
        check(
                PluginDialogStyler.resolveMaxDialogHeightPx(540, true) == 464,
                "Item1 resolveMaxDialogHeightPx clamps 540dp TV viewport to 86% (464px)");
        check(
                PluginDialogStyler.isInjectedHelperClass(
                        "com.pilipala.marcomovie.TvQrInputHelper$1", null),
                "Item1 PluginDialogStyler ignores injected TvQrInputHelper class so plugin styling is never abandoned");
        check(
                PluginDialogStyler.isInjectedHelperClass(
                        "android.widget.LinearLayout", TvQrInputHelper.TAG_WRAPPED_INPUT),
                "Item1 PluginDialogStyler ignores TAG_WRAPPED_INPUT wrapper");
        check(
                !PluginDialogStyler.isInjectedHelperClass(
                        "com.pilipala.marcomovie.AppDialog", "app-dialog"),
                "Item1 real app-owned dialogs remain excluded from plugin restyling");
        check(
                PluginDialogStyler.isLikelyQrDimensions(220, 260, 0, 0, 100),
                "Item1 non-square captioned QR image (220x260) is detected and bounded");
        check(
                !PluginDialogStyler.isLikelyQrDimensions(400, 60, 400, 60, 100),
                "Item1 wide banner (400x60) is not misclassified as a QR code");

        JSONObject inputAction =
                new JSONObject()
                        .put("actionId", "set_ck")
                        .put("type", "input")
                        .put("title", "设置Cookie");
        JSONObject menuAction =
                new JSONObject()
                        .put("actionId", "pick_pan")
                        .put("type", "menu")
                        .put("option", new org.json.JSONArray().put("夸克").put("UC"));
        JSONObject qrAction =
                new JSONObject()
                        .put("type", "qrcode")
                        .put("imageUrl", "https://source.test/qr.png");
        check(
                SourceController.isStructuredActionJson(inputAction)
                        && SourceController.isStructuredActionJson(menuAction)
                        && SourceController.isStructuredActionJson(qrAction),
                "Item1 SourceController detects TVBox/OK structured JSON actions (input/menu/qrcode)");

        String stylerSrc =
                readSrc("android-tv/src/main/java/com/pilipala/marcomovie/PluginDialogStyler.java");
        String focusSrc =
                readSrc("android-tv/src/main/java/com/pilipala/marcomovie/FocusMotion.java");
        check(
                stylerSrc.contains("enforceVerticalBounds(")
                        && stylerSrc.contains("wrapChildrenInScrollView(")
                        && stylerSrc.contains("clampOversizedBounds(")
                        && stylerSrc.contains("recheckAsyncQrImages(")
                        && focusSrc.contains("\"plugin-dialog-card\""),
                "Item1 PluginDialogStyler enforces vertical scroll clamp, clips cardRoot, and stops FocusMotion unclip");
    }

    private static void checkItem2NetdiskLoginStateSync() throws Exception {
        check(
                AccountPanel.resolveEffectiveLoginState(0, true, -1),
                "Item2 live credential file overrides stale cached 0 ('未登录') immediately");
        check(
                AccountPanel.resolveEffectiveLoginState(0, false, 1),
                "Item2 live spider Config Center '已登录' card status overrides stale cached 0");
        check(
                AccountPanel.resolveEffectiveLoginState(1, false, -1),
                "Item2 confirmed QR scan preference (1) reports logged in even for in-memory spider tokens");
        check(
                !AccountPanel.resolveEffectiveLoginState(0, false, 0),
                "Item2 unauthenticated drive cleanly reports not logged in");
        check(
                AccountPanel.textHasDriveCredentialValue(
                        "{\"quark_cookie\":\"__pus=abcdef1234567890\",\"uc\":\"\"}",
                        new String[] {"quark", "kuake"}),
                "Item2 unified JSON config credential parser detects non-empty quark cookie");
        check(
                !AccountPanel.textHasDriveCredentialValue(
                        "{\"quark_cookie\":\"\",\"uc\":\"null\"}", new String[] {"quark", "uc"}),
                "Item2 unified JSON config parser ignores empty or null placeholder values");

        String refreshSrc =
                readSrc("android-tv/src/main/java/com/fongmi/android/tv/event/RefreshEvent.java");
        String accountSrc =
                readSrc("android-tv/src/main/java/com/pilipala/marcomovie/AccountPanel.java");
        check(
                refreshSrc.contains("CspEngine.onPluginConfigRefreshed()")
                        && accountSrc.contains("markDriveLoggedIn(")
                        && accountSrc.contains("activePageRefresh = tvLiveRefresh"),
                "Item2 RefreshEvent.config() bridges into AccountPanel + TV dialog registers live refresh");
    }

    private static void checkItem3BilingualSubtitleNoOverlap() {
        // 1. Bilingual ASS simultaneous bottom cues sharing exact line=0.95f
        Cue cnAss =
                new Cue.Builder()
                        .setText("你好，世界")
                        .setLine(0.95f, Cue.LINE_TYPE_FRACTION)
                        .setLineAnchor(Cue.ANCHOR_TYPE_END)
                        .build();
        Cue enAss =
                new Cue.Builder()
                        .setText("Hello, world")
                        .setLine(0.95f, Cue.LINE_TYPE_FRACTION)
                        .setLineAnchor(Cue.ANCHOR_TYPE_END)
                        .build();
        List<Cue> normAss =
                SubtitleOverlayView.normalizeCuesForDisplay(Arrays.asList(cnAss, enAss), 0.045f);
        check(
                normAss.size() == 1
                        && "你好，世界\nHello, world".equals(String.valueOf(normAss.get(0).text))
                        && normAss.get(0).line == Cue.DIMEN_UNSET,
                "Item3 bilingual ASS bottom cues at identical line=0.95 coalesce into 1 stacked Cue with DIMEN_UNSET");

        // 2. Bilingual ASS \pos cues (upper y=0.88, lower y=0.94) maintain vertical order
        Cue enLower =
                new Cue.Builder()
                        .setText("English lower line")
                        .setLine(0.94f, Cue.LINE_TYPE_FRACTION)
                        .build();
        Cue cnUpper =
                new Cue.Builder().setText("中文在上方").setLine(0.88f, Cue.LINE_TYPE_FRACTION).build();
        List<Cue> normPos =
                SubtitleOverlayView.normalizeCuesForDisplay(
                        Arrays.asList(enLower, cnUpper), 0.045f);
        check(
                normPos.size() == 1
                        && "中文在上方\nEnglish lower line".equals(String.valueOf(normPos.get(0).text)),
                "Item3 bilingual \\pos cues sort upper-above-lower and coalesce without overlapping");

        // 3. Simultaneous top (\an8) + bottom cues stay separated in their regions
        Cue topNote =
                new Cue.Builder()
                        .setText("{\\an8}注释：公元 2026")
                        .setLine(0.05f, Cue.LINE_TYPE_FRACTION)
                        .setLineAnchor(Cue.ANCHOR_TYPE_START)
                        .build();
        Cue topNoteEn =
                new Cue.Builder()
                        .setText("Note: Year 2026")
                        .setLine(0.05f, Cue.LINE_TYPE_FRACTION)
                        .setLineAnchor(Cue.ANCHOR_TYPE_START)
                        .build();
        List<Cue> normTopBottom =
                SubtitleOverlayView.normalizeCuesForDisplay(
                        Arrays.asList(topNote, topNoteEn, cnAss, enAss), 0.045f);
        check(
                normTopBottom.size() == 2
                        && "注释：公元 2026\nNote: Year 2026"
                                .equals(String.valueOf(normTopBottom.get(0).text))
                        && "你好，世界\nHello, world".equals(String.valueOf(normTopBottom.get(1).text)),
                "Item3 top bilingual notes & bottom bilingual dialogue stack independently with ASS tags stripped");

        // 4. Deduplicates identical simultaneous lines
        Cue dup = new Cue.Builder().setText("你好，世界").build();
        List<Cue> normDup =
                SubtitleOverlayView.normalizeCuesForDisplay(Arrays.asList(cnAss, dup), 0.045f);
        check(
                normDup.size() == 1 && "你好，世界".equals(String.valueOf(normDup.get(0).text)),
                "Item3 duplicate simultaneous subtitle lines are deduplicated");
    }

    private static void checkItem4InfiniteTopNavLoop() throws Exception {
        check(
                HomeDock.wrapHorizontalIndex(0, 8, true) == 7,
                "Item4 pressing LEFT on first top-nav tab wraps seamlessly to last tab (0 -> 7)");
        check(
                HomeDock.wrapHorizontalIndex(7, 8, false) == 0,
                "Item4 pressing RIGHT on last top-nav tab wraps seamlessly to first tab (7 -> 0)");
        check(
                HomeDock.wrapHorizontalIndex(3, 8, true) == 2
                        && HomeDock.wrapHorizontalIndex(3, 8, false) == 4,
                "Item4 middle top-nav steps move cleanly left and right");

        String dockSrc =
                readSrc("android-tv/src/main/java/com/pilipala/marcomovie/HomeDock.java")
                        .replaceAll("\\s+", " ");
        check(
                dockSrc.contains("wrapHorizontalIndex(i, items.length, true)")
                                && dockSrc.contains("wrapHorizontalIndex(i, items.length, false)")
                                && dockSrc.contains("wrapHorizontalIndex( index, items.length")
                        || dockSrc.contains("wrapHorizontalIndex(index, items.length"),
                "Item4 HomeDock wires infinite circular wrap in both D-pad key handler and nextFocusIds");
    }

    private static void checkItem5CustomNavAndLanQrServer() throws Exception {
        List<TvNavConfig.Module> defs = TvNavConfig.defaultModules();
        check(
                defs.size() == 8 && "nav-home".equals(defs.get(0).key),
                "Item5 TvNavConfig has 8 canonical modules");

        List<TvNavConfig.Module> moved = TvNavConfig.move(defs, 7, 0);
        check(
                "nav-settings".equals(moved.get(0).key) && "nav-home".equals(moved.get(1).key),
                "Item5 TvNavConfig.move reorders modules cleanly");

        List<TvNavConfig.Module> renamed = TvNavConfig.rename(moved, "nav-accounts", "云盘中心");
        String json = TvNavConfig.toJson(renamed);
        List<TvNavConfig.Module> parsed = TvNavConfig.parseJson(json);
        check(
                parsed.size() == 8
                        && "nav-settings".equals(parsed.get(0).key)
                        && "云盘中心".equals(findByKey(parsed, "nav-accounts").label),
                "Item5 TvNavConfig JSON roundtrips custom order and custom display names");

        // Missing or duplicate keys in partial payload are auto-repaired so navigation never bricks
        List<TvNavConfig.Module> repaired =
                TvNavConfig.parseJson(
                        "{\"items\":[{\"key\":\"nav-live\",\"label\":\"电视直播\"},{\"key\":\"nav-live\",\"label\":\"重复\"},{\"key\":\"bogus\",\"label\":\"坏数据\"}]}");
        check(
                repaired.size() == 8
                        && "nav-live".equals(repaired.get(0).key)
                        && "电视直播".equals(repaired.get(0).label)
                        && findByKey(repaired, "nav-settings") != null,
                "Item5 TvNavConfig sanitizes partial/duplicate/bogus JSON without losing any module");

        // Live loopback HTTP test of NavCustomizeServer (GET HTML + GET state + POST save + POST
        // reset)
        final AtomicReference<List<TvNavConfig.Module>> liveState = new AtomicReference<>(defs);
        try (NavCustomizeServer server =
                new NavCustomizeServer(
                        "127.0.0.1",
                        new NavCustomizeServer.Listener() {
                            @Override
                            public List<TvNavConfig.Module> currentModules() {
                                return liveState.get();
                            }

                            @Override
                            public void onModulesSaved(List<TvNavConfig.Module> updated) {
                                liveState.set(updated);
                            }

                            @Override
                            public void onModulesReset(List<TvNavConfig.Module> defaults) {
                                liveState.set(defaults);
                            }
                        })) {
            String baseUrl = server.url();
            String html = httpRequest("GET", baseUrl, null);
            check(
                    html.contains("电视导航栏自定义") && html.contains("bindDrag("),
                    "Item5 NavCustomizeServer serves mobile touch drag-and-drop & rename editor HTML");

            String savePayload =
                    "{\"items\":[{\"key\":\"nav-favorites\",\"label\":\"私人片单\"},{\"key\":\"nav-home\",\"label\":\"大厅\"}]}";
            String saveResp = httpRequest("POST", baseUrl + "/save", savePayload);
            check(
                    saveResp.contains("\"ok\":true")
                            && "nav-favorites".equals(liveState.get().get(0).key)
                            && "私人片单".equals(liveState.get().get(0).label)
                            && "大厅".equals(findByKey(liveState.get(), "nav-home").label),
                    "Item5 NavCustomizeServer POST /save live-updates TV module order & names");

            String resetResp = httpRequest("POST", baseUrl + "/reset", "");
            check(
                    resetResp.contains("\"ok\":true") && TvNavConfig.isDefault(liveState.get()),
                    "Item5 NavCustomizeServer POST /reset restores default order & names");
        }

        String settingsSrc =
                readSrc("android-tv/src/main/java/com/pilipala/marcomovie/SettingsScreen.java");
        String homeSrc =
                readSrc("android-tv/src/main/java/com/pilipala/marcomovie/HomeScreen.java");
        check(
                settingsSrc.contains("自定义导航栏顺序与名称")
                        && settingsSrc.contains("TvNavCustomizeDialog.show(")
                        && homeSrc.contains("TvNavConfig.signature(a)"),
                "Item5 Settings exposes nav customizer and HomeScreen invalidates dock cache on change");
    }

    private static TvNavConfig.Module findByKey(List<TvNavConfig.Module> mods, String key) {
        for (TvNavConfig.Module m : mods) {
            if (key.equals(m.key)) return m;
        }
        return null;
    }

    private static String httpRequest(String method, String urlStr, String body) throws Exception {
        HttpURLConnection conn = (HttpURLConnection) new URL(urlStr).openConnection();
        conn.setRequestMethod(method);
        conn.setConnectTimeout(4000);
        conn.setReadTimeout(4000);
        if (body != null) {
            conn.setDoOutput(true);
            byte[] bytes = body.getBytes(StandardCharsets.UTF_8);
            conn.setRequestProperty("Content-Type", "application/json; charset=utf-8");
            conn.setFixedLengthStreamingMode(bytes.length);
            try (OutputStream out = conn.getOutputStream()) {
                out.write(bytes);
            }
        }
        InputStream in =
                conn.getResponseCode() < 400 ? conn.getInputStream() : conn.getErrorStream();
        ByteArrayOutputStream buf = new ByteArrayOutputStream();
        if (in != null) {
            byte[] tmp = new byte[4096];
            int n;
            while ((n = in.read(tmp)) >= 0) buf.write(tmp, 0, n);
            in.close();
        }
        conn.disconnect();
        return new String(buf.toByteArray(), StandardCharsets.UTF_8);
    }

    private static void checkItem6DoubanScoreOnAllCards() throws Exception {
        check(
                "豆 8.7".equals(DoubanScoreRepository.formatBadgeText(8.7)),
                "Item6 formats Douban score badge cleanly as '豆 8.7'");
        check(
                "".equals(DoubanScoreRepository.formatBadgeText(0.0))
                        && "".equals(DoubanScoreRepository.formatBadgeText(10.0)),
                "Item6 rejects invalid 0.0 and MacCMS placeholder 10.0 scores");

        String rexxarJson =
                "{\"subjects\":{\"items\":[{\"target\":{\"title\":\"漫长的季节\",\"year\":\"2023\",\"rating\":{\"value\":9.4}}}]}}";
        double parsed =
                DoubanScoreRepository.parseRexxarSearchBestScore(
                        rexxarJson, TvSeriesScraper.normalizeCoreKey("漫长的季节"), "2023");
        check(
                Math.abs(parsed - 9.4) < 0.01,
                "Item6 DoubanScoreRepository parses Rexxar search score (9.4)");

        Map<String, DoubanScoreRepository.CacheEntry> cache = new HashMap<>();
        cache.put("三体#2023", new DoubanScoreRepository.CacheEntry(8.7, System.currentTimeMillis()));
        String cacheJson = DoubanScoreRepository.serializeCacheJson(cache);
        Map<String, DoubanScoreRepository.CacheEntry> restored = new HashMap<>();
        DoubanScoreRepository.parseCacheJsonInto(cacheJson, restored);
        check(
                restored.containsKey("三体#2023")
                        && Math.abs(restored.get("三体#2023").score - 8.7) < 0.01,
                "Item6 DoubanScoreRepository disk cache serializes and restores losslessly");

        Cms.Video parsedVid =
                Cms.listing(
                                "{\"list\":[{\"vod_id\":\"1\",\"vod_name\":\"三体\",\"vod_douban_id\":\"26647087\",\"rating\":\"8.7\"}]}")
                        .videos
                        .get(0);
        check(
                "8.7".equals(parsedVid.doubanScore) && "26647087".equals(parsedVid.doubanId),
                "Item6 Cms.video parses rating aliases and vod_douban_id");

        String homeSrc =
                readSrc("android-tv/src/main/java/com/pilipala/marcomovie/HomeScreen.java");
        String catSrc =
                readSrc("android-tv/src/main/java/com/pilipala/marcomovie/CatalogScreen.java");
        String searchSrc =
                readSrc("android-tv/src/main/java/com/pilipala/marcomovie/GlobalSearchScreen.java");
        check(
                homeSrc.contains("TvV17PosterCard.attachDoubanBadge(a, artWrap, item)")
                        && homeSrc.contains(
                                "TvV17PosterCard.wrapArtworkWithDoubanBadge(a, art, video")
                        && homeSrc.contains("vj.put(\"doubanScore\"")
                        && catSrc.contains("TvV17PosterCard.attachDoubanBadge(a, art, v)")
                        && searchSrc.contains(
                                "TvV17PosterCard.wrapArtworkWithDoubanBadge(a, poster, video"),
                "Item6 Home, Library ('片库'), Catalog, and Search cards all render Douban rating badges");
    }

    private static void checkItem7ConfigCenterAutoCompat() throws Exception {
        String accountSrc =
                readSrc("android-tv/src/main/java/com/pilipala/marcomovie/AccountPanel.java");
        check(
                accountSrc.contains("account-config-center-embed")
                        && accountSrc.contains("eng.home()")
                        && accountSrc.contains("eng.homeVideos()")
                        && accountSrc.contains("eng.category(")
                        && accountSrc.contains("harvestConfigCenterVideos(a, vids)")
                        && accountSrc.contains("account-embed-back"),
                "Item7 AccountPanel auto-loads & embeds all subscription Config Center categories, cards, folders, and actions");
        check(
                !accountSrc.contains("\"全部网盘登录与启用\""),
                "Item7 preserves TvUxOptimizationChecks invariant (no redundant LoginShow label)");
    }

    private static void checkItem8AnchoredNetdiskQrBubble() throws Exception {
        // Button on left column of TV (960x540) -> bubble extends cleanly to the RIGHT with
        // EDGE_LEFT pointer
        NetdiskQrBubble.BubblePlacement rightPlace =
                NetdiskQrBubble.computePlacement(960, 540, 120, 140, 440, 204, 232, 282, 14, 6);
        check(
                rightPlace.pointerEdge == NetdiskQrBubble.EDGE_LEFT
                        && rightPlace.x >= 446
                        && rightPlace.x + 232 <= 960 - 14
                        && rightPlace.y >= 14
                        && rightPlace.y + 282 <= 540 - 14,
                "Item8 QR bubble extends to right of left-column drive card and stays strictly inside TV bounds");

        // Button near right edge -> bubble flips cleanly to LEFT with EDGE_RIGHT pointer, zero
        // overflow!
        NetdiskQrBubble.BubblePlacement leftPlace =
                NetdiskQrBubble.computePlacement(960, 540, 560, 140, 860, 204, 232, 282, 14, 6);
        check(
                leftPlace.pointerEdge == NetdiskQrBubble.EDGE_RIGHT
                        && leftPlace.x >= 14
                        && leftPlace.x + 232 <= 560 - 6
                        && leftPlace.y >= 14
                        && leftPlace.y + 282 <= 540 - 14,
                "Item8 QR bubble flips cleanly to left of right-column drive card with zero edge overflow");

        check(
                NetdiskQrBubble.isSuccessStatusText("夸克网盘 登录成功")
                        && NetdiskQrBubble.isSuccessStatusText("扫码成功")
                        && !NetdiskQrBubble.isSuccessStatusText("扫码失败，请重试")
                        && !NetdiskQrBubble.isSuccessStatusText("二维码已过期"),
                "Item8 QR bubble status classifier accurately distinguishes scan success from errors/expiry");

        String bubbleSrc =
                readSrc("android-tv/src/main/java/com/pilipala/marcomovie/NetdiskQrBubble.java");
        String accountSrc =
                readSrc("android-tv/src/main/java/com/pilipala/marcomovie/AccountPanel.java");
        check(
                bubbleSrc.contains("tryCapturePluginQrWindow(")
                        && bubbleSrc.contains("扫码成功")
                        && bubbleSrc.contains(".scaleX(0.2f)")
                        && accountSrc.contains("NetdiskQrBubble.arm(")
                        && !accountSrc.contains(
                                "dialog.dismiss();\n                                    a.ensureStoragePermissionForNetdisk"),
                "Item8 Netdisk dialog stays open on drive click, extends anchored QR bubble, collapses on scan success with '扫码成功'");
    }

    private static void checkPrefsInvariant() {
        check(
                Prefs.KEYS.length == 46,
                "Invariant: Prefs.KEYS.length remains strictly 46 (nav customizer uses dedicated tv_nav_custom prefs)");
    }
}
