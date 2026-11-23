package com.pilipala.marcomovie;

import android.graphics.Color;
import android.net.Uri;
import android.os.SystemClock;
import android.view.Gravity;
import android.view.KeyEvent;
import android.view.Surface;
import android.view.View;
import android.view.ViewGroup;
import android.view.WindowManager;
import android.widget.FrameLayout;
import android.widget.TextView;
import com.pilipala.marcomovie.hud.EpisodeHoldSwitchOverlay;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import org.json.JSONArray;
import org.json.JSONObject;

/**
 * Playback resolution (direct, plugin/JS player, web resolver, magnet stream), player page
 * lifecycle, mini-player transitions, remote seek gesture, control overlay auto-hide, and watch
 * history bookmark persistence extracted from {@link MainActivity}.
 */
final class PlaybackController {
    private static final ExecutorService PLAYER_RESOLVE =
            Executors.newCachedThreadPool(
                    r -> {
                        Thread t = new Thread(r, "player-resolve");
                        t.setDaemon(true);
                        return t;
                    });
    private static final ExecutorService PLAYER_INIT =
            Executors.newSingleThreadExecutor(
                    r -> {
                        Thread t = new Thread(r, "player-init");
                        t.setDaemon(true);
                        return t;
                    });
    static final ExecutorService STORAGE_EXECUTOR = WatchHistory.STORAGE_EXECUTOR;
    private static final long DISK_SAVE_INTERVAL_MS = 15000L;

    private PlaybackController() {}

    static WatchHistory.Entry cloneBookmark(WatchHistory.Entry src) {
        return WatchHistory.cloneEntry(src);
    }

    static void updateInMemoryBookmark(MainActivity a) {
        if (a.player == null || !a.prepared || a.playingBookmark == null) return;
        try {
            int rawPos = a.player.getCurrentPosition();
            int position =
                    a.playbackControls != null
                            ? a.playbackControls.displayPosition(rawPos)
                            : rawPos;
            if (a.playbackControls != null
                    && a.playbackControls.pendingResumeMs > 0
                    && position < 2000) {
                position = a.playbackControls.pendingResumeMs;
            }
            if (position < 1000 && a.playingBookmark.position >= 1000) {
                position = a.playingBookmark.position;
            }
            a.playingBookmark.position = Math.max(0, position);
            int dur = a.player.getDuration();
            if (dur > 0) {
                a.playingBookmark.duration = dur;
            }
            a.playingBookmark.updated = System.currentTimeMillis();
        } catch (Exception ignored) {
        }
    }

    static String formatTime(int ms) {
        int sec = Math.max(0, ms / 1000);
        return sec >= 3600
                ? String.format(Locale.ROOT, "%d:%02d:%02d", sec / 3600, (sec / 60) % 60, sec % 60)
                : String.format(Locale.ROOT, "%02d:%02d", sec / 60, sec % 60);
    }

    static void stopMagnet(MainActivity a) {
        if (a.magnetStream != null) {
            a.magnetStream.close();
            a.magnetStream = null;
        }
    }

    static void stopWeb(MainActivity a) {
        if (a.webResolver != null) {
            a.webResolver.stop();
            a.webResolver = null;
        }
    }

    static void resolveWebPage(
            MainActivity a, Cms.Site s, Cms.Video v, Cms.Episode ep, String prefix) {
        String address = (prefix == null ? "" : prefix) + ep.url;
        if (!Cms.isHttp(address)) {
            a.changingMiniEpisode = false;
            clearPlaybackLoading(a);
            failInPlaceSwitch(a, "解析页面地址不受支持。");
            return;
        }
        final int ticket = a.generation;
        final int serial = a.playbackResolveSerial;
        try {
            List<Cms.SniffRule> sniffRules =
                    a.config != null ? a.config.rules : java.util.Collections.emptyList();
            List<String> adHosts =
                    a.config != null ? a.config.ads : java.util.Collections.emptyList();
            String clickJs = ep.media != null ? ep.media.optString("click", "") : "";
            a.webResolver =
                    new WebResolver(
                            a,
                            address,
                            ep.headers,
                            sniffRules,
                            adHosts,
                            clickJs,
                            new WebResolver.Listener() {
                                public void media(String url, Map<String, String> headers) {
                                    if (ticket != a.generation || serial != a.playbackResolveSerial)
                                        return;
                                    a.webResolver = null;
                                    clearPlaybackLoading(a);
                                    Cms.Episode resolved = new Cms.Episode();
                                    resolved.name = ep.name;
                                    resolved.url = url;
                                    resolved.headers.putAll(headers);
                                    resolved.media = ep.media;
                                    openPlayer(a, s, v, resolved);
                                }

                                public void failed(String reason) {
                                    if (ticket == a.generation
                                            && serial == a.playbackResolveSerial) {
                                        a.changingMiniEpisode = false;
                                        clearPlaybackLoading(a);
                                        stopWeb(a);
                                        failInPlaceSwitch(a, reason);
                                    }
                                }
                            });
            if (a.webResolver.view() != null) {
                a.playbackLoading.addView(a.webResolver.view(), new FrameLayout.LayoutParams(1, 1));
            }
        } catch (Exception error) {
            AppLog.w("PlaybackController", "WebResolver init failed", error);
            a.changingMiniEpisode = false;
            clearPlaybackLoading(a);
            failInPlaceSwitch(a, "这台设备无法打开网页播放组件。");
        }
    }

    static void failInPlaceSwitch(MainActivity a, String message) {
        if (a.playerChrome != null) a.playerChrome.setLoading(false);
        if (a.current != null && a.current.player) {
            if (a.playStatus != null) a.playStatus.setText(message);
            showControls(a, true);
        }
        a.toast(message);
    }

    private static boolean tryHistoryCrossSourceFailover(
            MainActivity a, Cms.Site failedSite, int currentPositionMs, String reason) {
        if (a == null
                || failedSite == null
                || "live".equals(failedSite.key)
                || a.historyFallbackInFlight) {
            return false;
        }
        WatchHistory.Entry bm = a.historyFallbackBookmark;
        if (bm == null || bm.title == null || bm.title.trim().isEmpty()) {
            return false;
        }
        if (!CatalogScreen.hasAlternativeHistorySources(a, failedSite.key)) {
            return false;
        }
        WatchHistory.Entry updated = WatchHistory.cloneEntry(bm);
        if (currentPositionMs > updated.position) {
            updated.position = currentPositionMs;
        }
        a.historyFallbackBookmark = null;
        CatalogScreen.resumeHistoryFromAlternativeSources(
                a, updated, failedSite.key, reason, false);
        return true;
    }

    static WatchHistory.Entry lookupSavedBookmark(
            MainActivity a, Cms.Site s, Cms.Video v, Cms.Line line, Cms.Episode ep) {
        if (a == null
                || s == null
                || s.key == null
                || "live".equals(s.key)
                || v == null
                || v.id == null
                || ep == null) {
            return null;
        }
        int epIdx = line != null ? line.episodes.indexOf(ep) : -1;
        for (WatchHistory.Entry entry : a.watchHistory()) {
            if (s.key.equals(entry.site) && v.id.equals(entry.id)) {
                boolean sameName = ep.name != null && ep.name.equals(entry.episode);
                boolean sameIndex =
                        line != null
                                && line.name != null
                                && line.name.equals(entry.line)
                                && epIdx >= 0
                                && epIdx == entry.index;
                if (sameName || sameIndex) {
                    return entry;
                }
                break;
            }
        }
        return null;
    }

    private static Cms.Site findPushSite(MainActivity a) {
        if (a == null || a.config == null) return null;
        for (Cms.Site site : a.config.sites) {
            if (site.api != null
                    && site.api.toLowerCase(Locale.ROOT).contains("push")
                    && a.available(site)) {
                return site;
            }
        }
        return null;
    }

    private static boolean looksLikeNetdiskLine(Cms.Site s, Cms.Line line, String url) {
        String combined =
                ((s != null && s.name != null ? s.name : "")
                                + " "
                                + (line != null && line.name != null ? line.name : "")
                                + " "
                                + (url != null ? url : ""))
                        .toLowerCase(Locale.ROOT);
        return combined.contains("原画")
                || combined.contains("原畫")
                || combined.contains("网盘")
                || combined.contains("百度")
                || combined.contains("摆渡")
                || combined.contains("夸克")
                || combined.contains("夸父")
                || combined.contains("阿里")
                || combined.contains("天翼")
                || combined.contains("移动")
                || combined.contains("115")
                || combined.contains("123")
                || combined.contains("uc")
                || combined.contains("pan")
                || combined.contains("quark")
                || combined.contains("baidu");
    }

    private static Cms.Episode findMatchingEpisode(
            Cms.Line targetLine, Cms.Line fromLine, Cms.Episode ep) {
        return TvSeriesScraper.findMatchingEpisodeAcrossLines("", targetLine, fromLine, ep, null);
    }

    static void resolvePlayer(
            MainActivity a, Cms.Site s, Cms.Video v, Cms.Line line, Cms.Episode ep) {
        if (a.miniMode) {
            a.changingMiniEpisode = true;
            showEpisodeDetails(a, s, v);
        }
        a.activeLine = line;
        a.activeEpisode = ep;
        if (a.resumeAt == 0) {
            WatchHistory.Entry saved = lookupSavedBookmark(a, s, v, line, ep);
            if (saved != null) {
                a.resumeAt = saved.resume();
            }
        }
        if (s.supported()) {
            String rewrittenEpUrl = LocalProxy.rewrite(ep.url);
            String cleanPath =
                    rewrittenEpUrl == null
                            ? ""
                            : rewrittenEpUrl.split("[?#]", 2)[0].toLowerCase(Locale.ROOT);
            boolean looksLikeWebPage =
                    cleanPath.endsWith(".html")
                            || cleanPath.endsWith(".htm")
                            || cleanPath.endsWith(".shtml")
                            || cleanPath.contains("/share/");
            if (Cms.isDirectStreamUrl(rewrittenEpUrl)
                    || (!s.requiresParser && Cms.isMedia(rewrittenEpUrl) && !looksLikeWebPage)) {
                openPlayer(a, s, v, ep);
                return;
            }
            if (v != null && v.lines != null) {
                for (Cms.Line sibling : v.lines) {
                    if (sibling == line) continue;
                    Cms.Episode match = findMatchingEpisode(sibling, line, ep);
                    if (match != null && Cms.isDirectStreamUrl(LocalProxy.rewrite(match.url))) {
                        a.activeLine = sibling;
                        a.activeEpisode = match;
                        rememberEpisodeOnBackStack(a, sibling, match);
                        openPlayer(a, s, v, match);
                        return;
                    }
                }
            }
            resolveCmsWithParser(a, s, v, ep, s.playUrl);
            return;
        }
        if (a.playbackLoading != null) return;
        showPlaybackLoading(a);
        PluginDialogStyler.watch(a);
        final int serial = a.playbackResolveSerial, ticket = a.generation;
        Future<?> request =
                RequestScope.submit(
                        PLAYER_RESOLVE,
                        () -> {
                            try {
                                Cms.Site targetSite = s;
                                Cms.Line chosenLine = line;
                                Cms.Episode chosenEp = ep;
                                String targetFlag = line != null ? line.name : "";
                                String targetId = ep.url != null ? ep.url : "";
                                if (targetId.regionMatches(true, 0, "push://", 0, 7)) {
                                    Cms.Site pushSite = findPushSite(a);
                                    if (pushSite != null) {
                                        targetSite = pushSite;
                                        String pushTarget = targetId.substring(7);
                                        Cms.Listing pushList =
                                                Cms.listing(a.engine(pushSite).detail(pushTarget));
                                        if (!pushList.videos.isEmpty()
                                                && !pushList.videos.get(0).lines.isEmpty()
                                                && !pushList.videos
                                                        .get(0)
                                                        .lines
                                                        .get(0)
                                                        .episodes
                                                        .isEmpty()) {
                                            Cms.Line pLine = pushList.videos.get(0).lines.get(0);
                                            targetFlag = pLine.name;
                                            targetId = pLine.episodes.get(0).url;
                                        }
                                    }
                                }
                                JSONObject result = null;
                                Cms.Episode resolvedCandidate = null;
                                Exception primaryError = null;
                                try {
                                    result =
                                            new JSONObject(
                                                    a.engine(targetSite)
                                                            .player(targetFlag, targetId));
                                    resolvedCandidate =
                                            MediaOptions.episode(targetSite, chosenEp, result);
                                    if (resolvedCandidate.url.regionMatches(
                                            true, 0, "push://", 0, 7)) {
                                        Cms.Site pushSite = findPushSite(a);
                                        if (pushSite != null) {
                                            String pushTarget = resolvedCandidate.url.substring(7);
                                            Cms.Listing pushList =
                                                    Cms.listing(
                                                            a.engine(pushSite).detail(pushTarget));
                                            if (!pushList.videos.isEmpty()
                                                    && !pushList.videos.get(0).lines.isEmpty()
                                                    && !pushList.videos
                                                            .get(0)
                                                            .lines
                                                            .get(0)
                                                            .episodes
                                                            .isEmpty()) {
                                                Cms.Line pLine =
                                                        pushList.videos.get(0).lines.get(0);
                                                JSONObject pushRes =
                                                        new JSONObject(
                                                                a.engine(pushSite)
                                                                        .player(
                                                                                pLine.name,
                                                                                pLine.episodes.get(
                                                                                                0)
                                                                                        .url));
                                                resolvedCandidate =
                                                        MediaOptions.episode(
                                                                pushSite, chosenEp, pushRes);
                                                result = pushRes;
                                            }
                                        }
                                    }
                                } catch (Exception e) {
                                    primaryError = e;
                                }

                                boolean primaryPlayable =
                                        resolvedCandidate != null
                                                && resolvedCandidate.url != null
                                                && !resolvedCandidate.url.trim().isEmpty()
                                                && (Cms.isMedia(resolvedCandidate.url.trim())
                                                        || resolvedCandidate
                                                                .url
                                                                .trim()
                                                                .startsWith("magnet:?")
                                                        || (result != null
                                                                && (result.optInt("parse", 0) != 0
                                                                        || result.optInt("jx", 0)
                                                                                != 0)));
                                if (!primaryPlayable
                                        && v != null
                                        && v.lines != null
                                        && v.lines.size() > 1
                                        && !looksLikeNetdiskLine(s, line, targetId)) {
                                    for (Cms.Line altLine : v.lines) {
                                        if (altLine == null
                                                || altLine == line
                                                || altLine.episodes.isEmpty()) {
                                            continue;
                                        }
                                        Cms.Episode altEp = findMatchingEpisode(altLine, line, ep);
                                        if (altEp == null || altEp.url == null) continue;
                                        if (looksLikeNetdiskLine(s, altLine, altEp.url)) continue;
                                        try {
                                            JSONObject altRes =
                                                    new JSONObject(
                                                            a.engine(s)
                                                                    .player(
                                                                            altLine.name,
                                                                            altEp.url));
                                            Cms.Episode altResolved =
                                                    MediaOptions.episode(s, altEp, altRes);
                                            String altUrl =
                                                    altResolved.url == null
                                                            ? ""
                                                            : altResolved.url.trim();
                                            if (!altUrl.isEmpty()
                                                    && (Cms.isMedia(altUrl)
                                                            || altUrl.startsWith("magnet:?")
                                                            || altRes.optInt("parse", 0) != 0
                                                            || altRes.optInt("jx", 0) != 0)) {
                                                result = altRes;
                                                resolvedCandidate = altResolved;
                                                chosenLine = altLine;
                                                chosenEp = altEp;
                                                primaryError = null;
                                                break;
                                            }
                                        } catch (Exception ignored) {
                                        }
                                    }
                                }
                                if (primaryError != null && resolvedCandidate == null) {
                                    throw primaryError;
                                }
                                final JSONObject finalResult =
                                        result != null ? result : new JSONObject();
                                final Cms.Episode resolved =
                                        resolvedCandidate != null
                                                ? resolvedCandidate
                                                : MediaOptions.episode(
                                                        targetSite, chosenEp, finalResult);
                                final Cms.Line finalLine = chosenLine;
                                final Cms.Episode finalEp = chosenEp;
                                final boolean switchedLine =
                                        chosenLine != line && chosenLine != null;
                                a.ui.post(
                                        () -> {
                                            if (serial != a.playbackResolveSerial
                                                    || ticket != a.generation
                                                    || a.isFinishing()) {
                                                JSONObject unused =
                                                        resolved.media.optJSONObject("embySession");
                                                if (unused != null
                                                        && s != null
                                                        && s.api != null
                                                        && s.api.startsWith(
                                                                com.pilipala.emby.EmbyLibrary
                                                                        .PREFIX))
                                                    try {
                                                        com.pilipala.emby.EmbyAccounts.open(
                                                                        a, s.api)
                                                                .track(unused)
                                                                .stop(0);
                                                    } catch (Exception ignored) {
                                                    }
                                                return;
                                            }
                                            try {
                                                if (switchedLine) {
                                                    a.activeLine = finalLine;
                                                    a.activeEpisode = finalEp;
                                                    a.toast("当前线路响应异常，已自动切换至 " + finalLine.name);
                                                }
                                                String url =
                                                        resolved.url == null
                                                                ? ""
                                                                : resolved.url.trim();
                                                if (url.isEmpty() && finalEp.url != null) {
                                                    String fallbackEpUrl =
                                                            LocalProxy.rewrite(finalEp.url.trim());
                                                    if (Cms.isMedia(fallbackEpUrl)
                                                            || fallbackEpUrl.startsWith(
                                                                    "magnet:?")) {
                                                        url = fallbackEpUrl;
                                                        resolved.url = fallbackEpUrl;
                                                    }
                                                }
                                                if (finalResult.optInt("parse", 0) != 0
                                                        || finalResult.optInt("jx", 0) != 0) {
                                                    String playPrefix =
                                                            finalResult.optString(
                                                                    "playUrl", s.playUrl);
                                                    if ((playPrefix == null || playPrefix.isEmpty())
                                                            && a.config != null
                                                            && !a.config.parses.isEmpty()) {
                                                        clearPlaybackLoading(a);
                                                        resolveCmsWithParser(a, s, v, resolved, "");
                                                        return;
                                                    }
                                                    resolveWebPage(a, s, v, resolved, playPrefix);
                                                    return;
                                                }
                                                clearPlaybackLoading(a);
                                                if (url.isEmpty()) {
                                                    a.changingMiniEpisode = false;
                                                    if (tryHistoryCrossSourceFailover(
                                                            a, s, a.resumeAt, "原片源未返回有效播放地址")) {
                                                        return;
                                                    }
                                                    String spiderMsg =
                                                            finalResult
                                                                    .optString(
                                                                            "msg",
                                                                            finalResult.optString(
                                                                                    "message",
                                                                                    finalResult
                                                                                            .optString(
                                                                                                    "tip",
                                                                                                    "")))
                                                                    .trim();
                                                    if (!spiderMsg.isEmpty()) {
                                                        failInPlaceSwitch(a, spiderMsg);
                                                    } else if (looksLikeNetdiskLine(
                                                            s, finalLine, finalEp.url)) {
                                                        failInPlaceSwitch(
                                                                a,
                                                                "该网盘线路未返回播放地址，请先在「网盘与账号」扫码登录对应网盘，或点击右上角 ⇄ 切换其他线路");
                                                    } else {
                                                        failInPlaceSwitch(
                                                                a, "当前线路未返回有效播放地址，请点击右上角 ⇄ 切换其他线路");
                                                    }
                                                    return;
                                                }
                                                if (!Cms.isMedia(url)
                                                        && !url.startsWith("magnet:?")) {
                                                    a.changingMiniEpisode = false;
                                                    if (looksLikeNetdiskLine(s, finalLine, url)) {
                                                        failInPlaceSwitch(
                                                                a,
                                                                "该网盘线路需先在「网盘与账号」登录授权，或点击右上角 ⇄ 切换其他线路");
                                                    } else {
                                                        failInPlaceSwitch(
                                                                a, "来源返回的播放协议暂不支持，请切换其他线路");
                                                    }
                                                    return;
                                                }
                                                openPlayer(a, s, v, resolved);
                                            } catch (Exception error) {
                                                AppLog.w(
                                                        "PlaybackController",
                                                        "parse player response failed",
                                                        error);
                                                a.changingMiniEpisode = false;
                                                clearPlaybackLoading(a);
                                                failInPlaceSwitch(a, "播放信息无法读取，请重试");
                                            }
                                        });
                            } catch (Exception error) {
                                AppLog.w("PlaybackController", "engine.player failed", error);
                                a.ui.post(
                                        () -> {
                                            if (serial != a.playbackResolveSerial
                                                    || ticket != a.generation) return;
                                            a.changingMiniEpisode = false;
                                            clearPlaybackLoading(a);
                                            if (tryHistoryCrossSourceFailover(
                                                    a, s, a.resumeAt, "原片源解析失败")) {
                                                return;
                                            }
                                            failInPlaceSwitch(a, a.message(error));
                                        });
                            }
                        });
        a.pageRequests.add(request);
    }

    private static String extractEmbeddedStreamUrl(String baseUrl, String body) {
        if (body == null || body.isEmpty()) return "";
        java.util.regex.Matcher m =
                java.util.regex.Pattern.compile(
                                "(?:const|var|let)?\\s*(?:url|main|playurl|src|vid)\\s*[:=]\\s*[\"']([^\"']+\\.(?:m3u8|mp4)(?:\\?[^\"']*)?)[\"']",
                                java.util.regex.Pattern.CASE_INSENSITIVE)
                        .matcher(body);
        if (!m.find()) {
            m =
                    java.util.regex.Pattern.compile(
                                    "[\"']((?:https?:)?//[^\"']+\\.(?:m3u8|mp4)(?:\\?[^\"']*)?|/[^\"'\\s<>]+\\.(?:m3u8|mp4)(?:\\?[^\"'\\s<>]*)?)[\"']",
                                    java.util.regex.Pattern.CASE_INSENSITIVE)
                            .matcher(body);
            if (!m.find()) return "";
        }
        String found = m.group(1).trim().replace("\\/", "/");
        if (found.isEmpty()) return "";
        try {
            if (found.startsWith("//")) return "https:" + found;
            if (Cms.isHttp(found)) return found;
            if (baseUrl != null && Cms.isHttp(baseUrl)) {
                return new java.net.URI(baseUrl).resolve(found).toString();
            }
        } catch (Exception ignored) {
        }
        return "";
    }

    static void resolveCmsWithParser(
            MainActivity a, Cms.Site s, Cms.Video v, Cms.Episode ep, String preferredPrefix) {
        if (a.playbackLoading != null) return;
        showPlaybackLoading(a);
        PluginDialogStyler.watch(a);
        final int serial = a.playbackResolveSerial, ticket = a.generation;
        Future<?> request =
                RequestScope.submit(
                        PLAYER_RESOLVE,
                        () -> {
                            // 0. If ep.url is an HTML share wrapper with an embedded .m3u8/.mp4,
                            // extract it directly before falling back to external parsers.
                            if (ep.url != null && Cms.isHttp(ep.url)) {
                                try {
                                    String html = Cms.fetch(ep.url, s.headers);
                                    String embedded = extractEmbeddedStreamUrl(ep.url, html);
                                    if (Cms.isDirectStreamUrl(embedded)) {
                                        final Cms.Episode directEp = new Cms.Episode();
                                        directEp.name = ep.name;
                                        directEp.url = embedded;
                                        directEp.headers.putAll(
                                                Cms.inheritedHeaders(s.api, embedded, s.headers));
                                        a.ui.post(
                                                () -> {
                                                    if (serial != a.playbackResolveSerial
                                                            || ticket != a.generation
                                                            || a.isFinishing()) return;
                                                    clearPlaybackLoading(a);
                                                    openPlayer(a, s, v, directEp);
                                                });
                                        return;
                                    }
                                } catch (Exception ignored) {
                                }
                            }
                            // 1. Try preferredPrefix or JSON parsers in config.parses
                            List<Cms.Parse> candidates = new java.util.ArrayList<>();
                            if (preferredPrefix != null && Cms.isHttp(preferredPrefix)) {
                                Cms.Parse direct = new Cms.Parse();
                                direct.name = s.name;
                                direct.url = preferredPrefix;
                                direct.type = 1;
                                direct.headers.putAll(s.headers);
                                candidates.add(direct);
                            }
                            if (a.config != null && a.config.parses != null) {
                                for (Cms.Parse p : a.config.parses) {
                                    if (p != null && Cms.isHttp(p.url)) candidates.add(p);
                                }
                            }
                            String webFallbackPrefix =
                                    preferredPrefix != null ? preferredPrefix : "";
                            for (int i = 0; i < Math.min(4, candidates.size()); i++) {
                                if (Thread.currentThread().isInterrupted()) return;
                                Cms.Parse p = candidates.get(i);
                                if (p.type == 0 && webFallbackPrefix.isEmpty()) {
                                    webFallbackPrefix = p.url;
                                }
                                if (p.type == 1 || p.type == 2 || p.type == 3 || i == 0) {
                                    try {
                                        String targetUrl =
                                                p.url + java.net.URLEncoder.encode(ep.url, "UTF-8");
                                        String resp = Cms.fetch(targetUrl, p.headers);
                                        if (resp != null && resp.trim().startsWith("{")) {
                                            JSONObject jo = new JSONObject(resp.trim());
                                            String mediaUrl = jo.optString("url", "").trim();
                                            if (Cms.isMedia(mediaUrl)) {
                                                final Cms.Episode resolved =
                                                        MediaOptions.episode(s, ep, jo);
                                                a.ui.post(
                                                        () -> {
                                                            if (serial != a.playbackResolveSerial
                                                                    || ticket != a.generation
                                                                    || a.isFinishing()) return;
                                                            clearPlaybackLoading(a);
                                                            openPlayer(a, s, v, resolved);
                                                        });
                                                return;
                                            }
                                        }
                                    } catch (Exception ignored) {
                                    }
                                }
                            }
                            final String finalPrefix = webFallbackPrefix;
                            a.ui.post(
                                    () -> {
                                        if (serial != a.playbackResolveSerial
                                                || ticket != a.generation
                                                || a.isFinishing()) return;
                                        if (Cms.isHttp(finalPrefix + ep.url)) {
                                            resolveWebPage(a, s, v, ep, finalPrefix);
                                        } else if (Cms.isMedia(ep.url)) {
                                            clearPlaybackLoading(a);
                                            openPlayer(a, s, v, ep);
                                        } else {
                                            a.changingMiniEpisode = false;
                                            clearPlaybackLoading(a);
                                            failInPlaceSwitch(a, "此剧集需要外部解析，未找到可用解析接口");
                                        }
                                    });
                        });
        a.pageRequests.add(request);
    }

    static void showPlaybackLoading(MainActivity a) {
        a.playbackLoadingFocus = a.getCurrentFocus();
        if (a.markerHost != null) a.markerHost.abort();
        a.playbackLoading = new PlaybackLoading(a);
        a.root.addView(a.playbackLoading, new FrameLayout.LayoutParams(-1, -1));
        if (a.playerChrome != null) a.playerChrome.update();
        a.playbackLoading.requestFocus();
    }

    static void clearPlaybackLoading(MainActivity a) {
        a.playbackResolveSerial++;
        if (a.playbackLoading != null) {
            if (a.playbackLoading.getParent() instanceof ViewGroup)
                ((ViewGroup) a.playbackLoading.getParent()).removeView(a.playbackLoading);
            a.playbackLoading = null;
            if (a.playerChrome != null) a.playerChrome.update();
            if (a.playbackLoadingFocus != null && UiCompat.isAttached(a.playbackLoadingFocus))
                a.playbackLoadingFocus.requestFocus();
            a.playbackLoadingFocus = null;
        }
    }

    static void openPlayer(MainActivity a, Cms.Site s, Cms.Video v, Cms.Episode e) {
        if (e.url != null) {
            e.url = e.url.trim();
            if (e.url.startsWith("//")) {
                e.url = "https:" + e.url;
            }
            if (e.url.regionMatches(true, 0, "webview://", 0, 10)) {
                e.url = e.url.substring(10).trim();
                resolveWebPage(a, s, v, e, "");
                return;
            }
            if (a.config != null
                    && (e.url.regionMatches(true, 0, "proxy://", 0, 8)
                            || e.url.contains("/proxy"))) {
                try {
                    a.ensureProxy(a.config);
                } catch (Exception ignored) {
                }
            }
            e.url = LocalProxy.rewrite(e.url);
        }
        if (e.url != null && e.url.startsWith("magnet:?")) {
            magnetPlayer(a, s, v, e);
            return;
        }
        if (!Cms.isMedia(e.url)) {
            if (a.playerChrome != null) a.playerChrome.setLoading(false);
            a.notice("这条剧集需要解析或使用了特殊协议，基础版尚未支持。");
            return;
        }
        MainActivity.Screen screen = new MainActivity.Screen(() -> playerPage(a, s, v, e));
        screen.player = true;
        a.open(screen, a.current == null || !a.current.player);
    }

    static void magnetPlayer(MainActivity a, Cms.Site site, Cms.Video video, Cms.Episode episode) {
        a.open(
                new MainActivity.Screen(
                        () -> {
                            a.renderPage(video.title, "MAGNET PLAYBACK");
                            TextView state = a.text("正在获取磁力文件列表…", 17, MainActivity.MUTED);
                            a.body.addView(state);
                            final int ticket = a.generation;
                            try {
                                a.magnetStream =
                                        MagnetStream.start(
                                                a,
                                                episode.url,
                                                new MagnetStream.Listener() {
                                                    public void progress(String message) {
                                                        if (ticket == a.generation)
                                                            state.setText(message);
                                                    }

                                                    public void files(
                                                            List<MagnetStream.MediaFile> files,
                                                            int suggested,
                                                            MagnetStream.Selection selection) {
                                                        if (ticket != a.generation) return;
                                                        String[] names = new String[files.size()];
                                                        for (int i = 0; i < names.length; i++)
                                                            names[i] = files.get(i).name;
                                                        new AppDialog.Builder(a)
                                                                .setTitle("选择要播放的视频")
                                                                .setSingleChoiceItems(
                                                                        names,
                                                                        suggested,
                                                                        (dialog, index) -> {
                                                                            dialog.dismiss();
                                                                            selection.select(index);
                                                                        })
                                                                .setNegativeButton(
                                                                        "取消",
                                                                        (dialog, index) ->
                                                                                a.onBackPressed())
                                                                .setOnCancelListener(
                                                                        dialog -> a.onBackPressed())
                                                                .show();
                                                    }

                                                    public void ready(
                                                            String url, String mime, String name) {
                                                        if (ticket != a.generation) return;
                                                        Cms.Episode resolved = new Cms.Episode();
                                                        resolved.name = name;
                                                        resolved.url = url;
                                                        resolved.headers.putAll(episode.headers);
                                                        try {
                                                            resolved.media =
                                                                    new JSONObject(
                                                                                    episode.media
                                                                                            .toString())
                                                                            .put("mimeType", mime);
                                                        } catch (Exception ignored) {
                                                        }
                                                        if (!a.back.isEmpty())
                                                            a.current = a.back.pop();
                                                        openPlayer(a, site, video, resolved);
                                                    }

                                                    public void error(String message) {
                                                        if (ticket == a.generation) {
                                                            state.setText(message);
                                                            a.addButton(
                                                                    a.body,
                                                                    a.button(
                                                                            "重试",
                                                                            "primary",
                                                                            a::refresh));
                                                        }
                                                    }
                                                });
                            } catch (Exception error) {
                                AppLog.w("PlaybackController", "MagnetStream start failed", error);
                                state.setText("磁力播放初始化失败：" + error.getClass().getSimpleName());
                            }
                        }),
                true);
    }

    static void changeEpisode(
            MainActivity a,
            Cms.Site site,
            Cms.Video video,
            Cms.Line line,
            Cms.Episode episode,
            int position) {
        if (episode != null && episode.media != null && episode != a.activeEpisode) {
            episode.media.remove("_eofReconnectCount");
            episode.media.remove("_ioReconnectCount");
            episode.media.remove("_hwRetry");
        }
        a.changingMiniEpisode = a.miniMode;
        a.resumeAt = position;
        if (a.miniMode) {
            showEpisodeDetails(a, site, video);
        } else {
            rememberEpisodeOnBackStack(a, line, episode);
            if (a.current != null && a.current.player) {
                prepareInPlaceSwitch(a, line, episode);
            }
        }
        resolvePlayer(a, site, video, line, episode);
    }

    static void rememberEpisodeOnBackStack(MainActivity a, Cms.Line line, Cms.Episode episode) {
        if (a.back.isEmpty() || line == null || episode == null) return;
        MainActivity.Screen prev = a.back.peek();
        if (prev == null) return;
        int epIdx = line.episodes.indexOf(episode);
        if (epIdx >= 0) {
            boolean desc = a.prefs.getBoolean(Prefs.EPISODES_DESCENDING, false);
            int page = EpisodeSelection.pageFor(epIdx, line.episodes.size(), desc);
            prev.selection.select(line.name, page, line.episodes.size());
            prev.focus = "episode:" + line.name + ":" + epIdx;
            prev.episodeFocus = epIdx;
            prev.episodeFocusLine = line.name;
        }
    }

    static void prepareInPlaceSwitch(MainActivity a, Cms.Line line, Cms.Episode episode) {
        finishSeek(a, false);
        savePlaybackHistory(a, true);
        stopWeb(a);
        stopMagnet(a);
        if (a.player != null) {
            try {
                a.player.release();
            } catch (Exception error) {
                AppLog.w("PlaybackController", "player.release failed", error);
            }
            a.player = null;
        }
        a.prepared = false;
        a.playing = false;
        if (a.playerChrome != null) {
            a.playerChrome.switchEpisode(episode, line);
        }
    }

    static void showEpisodeDetails(MainActivity a, Cms.Site site, Cms.Video video) {
        releasePlayer(a);
        if (!a.isTvDevice()) {
            a.applyMobileSystemBars(false);
            a.setRequestedOrientation(android.content.pm.ActivityInfo.SCREEN_ORIENTATION_USER);
            if (a.usableWidth > a.usableHeight && a.usableHeight > 0) {
                int tmp = a.usableWidth;
                a.usableWidth = a.usableHeight;
                a.usableHeight = tmp;
            }
        }
        if (a.current != null && a.current.player)
            a.current =
                    a.back.isEmpty()
                            ? new MainActivity.Screen(() -> a.detail(site, video))
                            : a.back.pop();
        if (a.current != null) {
            a.detail(site, video, video);
            a.restore(a.current);
        }
    }

    static void leavePlayback(MainActivity a) {
        a.playerLocked = false;
        if (a.hideLockButton != null) {
            a.ui.removeCallbacks(a.hideLockButton);
            a.hideLockButton = null;
        }
        if (!a.isTvDevice()) {
            a.applyMobileSystemBars(false);
            a.setRequestedOrientation(android.content.pm.ActivityInfo.SCREEN_ORIENTATION_USER);
            if (a.usableWidth > a.usableHeight && a.usableHeight > 0) {
                int tmp = a.usableWidth;
                a.usableWidth = a.usableHeight;
                a.usableHeight = tmp;
            }
        }
        if (!a.back.isEmpty()) {
            releasePlayer(a);
            a.current = a.back.pop();
            a.renderReturn(a.current);
            a.restore(a.current);
        } else a.onBackPressed();
    }

    static void minimizePlayback(MainActivity a) {
        if (a.playbackControls == null || a.miniMode) return;
        if (a.playerLocked) {
            setPlayerLocked(a, false);
        }
        a.miniMode = true;
        showControls(a, false);
        if (a.playerChrome != null) a.playerChrome.syncClockViews();
        a.playbackControls.subtitle.setVisibility(View.GONE);
        a.playbackControls.danmaku.setVisibility(View.GONE);
        a.miniDetails = new MiniDetails(a);
    }

    static void expandPlayback(MainActivity a) {
        if (!a.miniMode) return;
        a.miniMode = false;
        if (a.miniDetails != null) {
            a.miniDetails.remove();
            a.miniDetails = null;
        }
        UiCompat.setClipToOutline(a.playbackLayer, false);
        a.playbackLayer.setLayoutParams(new FrameLayout.LayoutParams(-1, -1));
        a.playbackControls.subtitle.setVisibility(View.VISIBLE);
        a.playbackControls.danmaku.setVisibility(View.VISIBLE);
        if (a.playerChrome != null) a.playerChrome.syncClockViews();
        a.playbackLayer.post(
                () -> {
                    if (a.playbackControls != null) {
                        a.playbackControls.resize(
                                a.playbackControls.videoWidth, a.playbackControls.videoHeight);
                        showControls(a, true);
                        a.playbackControls.timeline.requestFocus();
                    }
                });
    }

    static void playerPage(MainActivity a, Cms.Site s, Cms.Video v, Cms.Episode ep) {
        ep.url = LocalProxy.rewrite(ep.url);
        try {
            String dm = ep.media.optString("danmaku");
            if (dm != null && !dm.isEmpty()) {
                ep.media.put("danmaku", LocalProxy.rewrite(dm));
            } else {
                String recentDm = CspEngine.consumeRecentPluginDanmaku(25000L);
                if (!recentDm.isEmpty()) {
                    ep.media.put("danmaku", LocalProxy.rewrite(recentDm));
                }
            }
            JSONArray subtitles = ep.media.optJSONArray("subtitles");
            if (subtitles != null)
                for (int i = 0; i < subtitles.length(); i++) {
                    JSONObject sub = subtitles.optJSONObject(i);
                    if (sub != null) sub.put("url", LocalProxy.rewrite(sub.optString("url")));
                }
        } catch (Exception ignored) {
        }
        final boolean keepLocked =
                !a.isTvDevice()
                        && a.current != null
                        && a.current.player
                        && !a.miniMode
                        && a.playerLocked;
        JSONObject embySession = ep.media.optJSONObject("embySession");
        com.pilipala.emby.EmbyLibrary.Reporter retained = a.embyReporter;
        if (retained != null && retained.matches(embySession)) a.embyReporter = null;
        else retained = null;
        releasePlayer(a);
        try {
            android.app.ActivityManager am =
                    (android.app.ActivityManager)
                            a.getSystemService(android.content.Context.ACTIVITY_SERVICE);
            if (am != null
                    && ((android.os.Build.VERSION.SDK_INT >= 19 && am.isLowRamDevice())
                            || am.getMemoryClass() <= 128)) {
                a.images.evictAll();
                ImmersivePoster.trimMemory(
                        android.content.ComponentCallbacks2.TRIM_MEMORY_RUNNING_LOW);
            }
        } catch (Throwable ignored) {
        }
        a.embyReporter = retained;
        a.playingBookmark = null;
        if (s != null
                && s.api != null
                && s.api.startsWith(com.pilipala.emby.EmbyLibrary.PREFIX)
                && embySession != null) {
            try {
                if (a.embyReporter == null)
                    a.embyReporter =
                            com.pilipala.emby.EmbyAccounts.open(a, s.api).track(embySession);
            } catch (Exception ignored) {
                // Check-in setup must not prevent an already resolved video from playing.
            }
        }
        String bookmarkId =
                v != null && v.id != null && !v.id.trim().isEmpty()
                        ? v.id.trim()
                        : (a.activeEpisode != null
                                        && a.activeEpisode.url != null
                                        && !a.activeEpisode.url.trim().isEmpty()
                                ? a.activeEpisode.url.trim()
                                : (v != null && v.title != null ? v.title.trim() : ""));
        if (v != null && !bookmarkId.isEmpty() && (v.id == null || v.id.trim().isEmpty())) {
            v.id = bookmarkId;
        }
        if (s.key != null
                && !s.key.equals("live")
                && !bookmarkId.isEmpty()
                && a.activeLine != null
                && a.activeEpisode != null) {
            WatchHistory.Entry saved = lookupSavedBookmark(a, s, v, a.activeLine, a.activeEpisode);
            int initialResume =
                    a.resumeAt > 0
                            ? a.resumeAt
                            : (a.resumeAt < 0 ? 0 : (saved != null ? saved.resume() : 0));
            a.playingBookmark = new WatchHistory.Entry();
            a.playingBookmark.site = s.key;
            a.playingBookmark.id = bookmarkId;
            a.playingBookmark.title = v.title;
            a.playingBookmark.poster = v.poster;
            a.playingBookmark.line = a.activeLine.name;
            a.playingBookmark.episode = a.activeEpisode.name;
            a.playingBookmark.index = a.activeLine.episodes.indexOf(a.activeEpisode);
            a.playingBookmark.position = Math.max(0, initialResume);
            a.playingBookmark.duration = saved != null ? Math.max(0, saved.duration) : 0;
            a.playingBookmark.updated = System.currentTimeMillis();
            a.lastBookmarkSave = a.playingBookmark.updated;
            final WatchHistory.Entry snapshot = cloneBookmark(a.playingBookmark);
            if (a.prefs != null && snapshot != null) {
                WatchHistory.enqueueUpsert(a.historyPersistence(), snapshot);
            }
            CloudSyncDialog.scheduleAutoPush(a, false);
        }
        a.generation++;
        final int ticket = a.generation;
        a.getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        if (!a.isTvDevice()) {
            a.applyMobileSystemBars(true);
            if (!keepLocked) {
                a.setRequestedOrientation(
                        android.content.pm.ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE);
            } else if (android.os.Build.VERSION.SDK_INT >= 18) {
                a.setRequestedOrientation(
                        android.content.pm.ActivityInfo.SCREEN_ORIENTATION_LOCKED);
            }
        }
        a.root = new FrameLayout(a);
        // Disable Android API 26+ defaultFocusHighlight and attach an explicit state_focused
        // pure-black background so a.root.requestFocus() when hiding TV controls never paints a
        // full-screen translucent gray highlight over letterbox bars or the video SurfaceView.
        UiCompat.setBackground(a.root, UiCompat.createFocusSafeColorBackground(Color.BLACK));
        UiCompat.setDefaultFocusHighlightEnabled(a.root, false);
        a.root.setFocusable(true);
        a.root.setFocusableInTouchMode(true);
        a.root.setTag("player-surface");
        a.scroll = null;
        boolean softwareVideoActive =
                a.prefs.getInt(Prefs.DECODER_MODE, 0) == 2
                        || (ep.media.optBoolean("_softwareFallback")
                                && ep.media.optInt("_fallbackMode", 2) == 2);
        boolean useCompatibleOutput =
                a.prefs.getInt(Prefs.VIDEO_OUTPUT, 0) == 1 || softwareVideoActive;
        VideoOutput surface = new VideoOutput(a, useCompatibleOutput);
        VideoOutput.setWindowHdrMode(a, false);
        a.playbackLayer = new FrameLayout(a);
        UiCompat.setDefaultFocusHighlightEnabled(a.playbackLayer, false);
        a.playbackLayer.setTag("playback-layer");
        a.root.addView(a.playbackLayer, new FrameLayout.LayoutParams(-1, -1));
        a.playbackLayer.addView(surface, new FrameLayout.LayoutParams(-1, -1, Gravity.CENTER));
        a.playerChrome = new PlayerChrome(a, v, ep, "live".equals(s.key));
        if (!a.isTvDevice()) {
            final PlayerChrome chrome = a.playerChrome;
            a.root.setOnApplyWindowInsetsListener(
                    (view, insets) -> {
                        int left = insets.getSystemWindowInsetLeft();
                        int top = insets.getSystemWindowInsetTop();
                        int right = insets.getSystemWindowInsetRight();
                        int bottom = insets.getSystemWindowInsetBottom();
                        if (android.os.Build.VERSION.SDK_INT >= 30) {
                            android.graphics.Insets safe =
                                    insets.getInsets(
                                            android.view.WindowInsets.Type.systemBars()
                                                    | android.view.WindowInsets.Type.displayCutout()
                                                    | android.view.WindowInsets.Type
                                                            .systemGestures());
                            left = safe.left;
                            top = safe.top;
                            right = safe.right;
                            android.graphics.Insets navigation =
                                    insets.getInsetsIgnoringVisibility(
                                            android.view.WindowInsets.Type.navigationBars());
                            left = Math.max(left, navigation.left);
                            right = Math.max(right, navigation.right);
                            bottom = Math.max(safe.bottom, navigation.bottom);
                        } else if (android.os.Build.VERSION.SDK_INT >= 28
                                && insets.getDisplayCutout() != null) {
                            android.view.DisplayCutout cutout = insets.getDisplayCutout();
                            left = Math.max(left, cutout.getSafeInsetLeft());
                            top = Math.max(top, cutout.getSafeInsetTop());
                            right = Math.max(right, cutout.getSafeInsetRight());
                            bottom = Math.max(bottom, cutout.getSafeInsetBottom());
                        }
                        chrome.safeInsets(left, top, right, bottom);
                        return insets;
                    });
            a.root.requestApplyInsets();
        }
        a.playbackControls =
                new PlaybackControls(
                        a, a.playerChrome.dock, a.playerChrome.progress, surface, s, v, ep);
        TouchPlayerGesture.attach(a, surface);
        final PlaybackControls controls = a.playbackControls;
        a.root.addOnLayoutChangeListener(
                (view, l, t, r, b, ol, ot, or, ob) -> {
                    int w = r - l, h = b - t;
                    if (w > 0 && h > 0) {
                        if (w != a.usableWidth || h != a.usableHeight) {
                            a.usableWidth = w;
                            a.usableHeight = h;
                            view.requestApplyInsets();
                            view.post(
                                    () -> {
                                        if (ticket != a.generation || a.isFinishing()) return;
                                        if (a.playerChrome != null) a.playerChrome.relayout();
                                        if (a.playbackControls != null) {
                                            a.playbackControls.resize(
                                                    a.playbackControls.videoWidth,
                                                    a.playbackControls.videoHeight);
                                        }
                                    });
                        }
                    }
                });
        a.setContentView(a.root);
        if (!a.isTvDevice()) a.root.requestApplyInsets();
        final boolean useSystemBackend =
                ep.media.optBoolean("_systemFallback")
                        || a.prefs.getInt(Prefs.PLAYER_ENGINE, 0) == 1;
        final Surface[] activeSurface = new Surface[1];
        final boolean[] initDispatched = new boolean[1];
        final Runnable launchPlayerInit =
                () -> {
                    if (initDispatched[0] || ticket != a.generation) return;
                    initDispatched[0] = true;
                    PLAYER_INIT.execute(
                            () -> {
                                MoviePlayer candidate = null;
                                try {
                                    Map<String, String> mediaHeaders =
                                            Cms.inheritedHeaders(s.api, ep.url, s.headers);
                                    Cms.mergeHeaders(mediaHeaders, ep.headers);
                                    int engPref = a.prefs.getInt(Prefs.PLAYER_ENGINE, 0);
                                    JSONObject drmObj = ep.media.optJSONObject("drm");
                                    String drmScheme =
                                            drmObj == null
                                                    ? ep.media.optString("drmScheme", "")
                                                    : drmObj.optString(
                                                            "scheme", drmObj.optString("type", ""));
                                    boolean useMpv =
                                            !ep.media.optBoolean("_systemFallback")
                                                    && !ep.media.optBoolean("_softwareFallback")
                                                    && !ep.media.optBoolean("_mpvFallback")
                                                    && drmScheme.isEmpty()
                                                    && engPref == 3
                                                    && MpvPlayer.isAvailable();
                                    boolean preferIjk =
                                            engPref == 2
                                                    || (engPref == 0
                                                            && (ep.media.optBoolean("live")
                                                                    || ep.media.optInt(
                                                                                    "playerType", 0)
                                                                            == 2));
                                    if (ep.media.optBoolean("_systemFallback") || engPref == 1) {
                                        candidate = new SystemPlayer(a);
                                    } else if (useMpv) {
                                        try {
                                            candidate = new MpvPlayer(a);
                                        } catch (Throwable mpvInitErr) {
                                            AppLog.w(
                                                    "PlaybackController",
                                                    "MPV init failed, falling back to Media3",
                                                    mpvInitErr);
                                            candidate = new MoviePlayer(a);
                                        }
                                    } else if (ep.media.optBoolean("_softwareFallback")) {
                                        candidate =
                                                new MoviePlayer(
                                                        a,
                                                        ep.media.optInt("_fallbackMode", 2),
                                                        preferIjk);
                                    } else if (preferIjk) {
                                        candidate = MoviePlayer.createIjk(a);
                                    } else {
                                        candidate = new MoviePlayer(a);
                                    }
                                    String rawPlayUrl =
                                            Cms.isHttp(ep.url) ? Cms.normalizeHttp(ep.url) : ep.url;
                                    String playUrl = rawPlayUrl;
                                    boolean isLiveStream = ep.media.optBoolean("live");
                                    String declaredMime = MediaOptions.mime(ep.media);
                                    if (!isLiveStream
                                            && a.prefs.getBoolean(Prefs.HLS_PROXY_ENABLED, true)
                                            && HlsStreamProxy.looksLikeHls(
                                                    rawPlayUrl, declaredMime)) {
                                        try {
                                            SourceController.ensureProxy(a, a.config);
                                            playUrl =
                                                    HlsStreamProxy.register(
                                                            rawPlayUrl,
                                                            mediaHeaders,
                                                            a.prefs.getBoolean(
                                                                    Prefs.HLS_AD_STRIP, false));
                                        } catch (Exception proxyErr) {
                                            AppLog.w(
                                                    "PlaybackController",
                                                    "HLS proxy fallback to direct URL",
                                                    proxyErr);
                                        }
                                    } else if (!isLiveStream) {
                                        int cacheMb = a.prefs.getInt(Prefs.MEDIA_CACHE_MB, 256);
                                        if (cacheMb > 0
                                                && MediaDiskCache.isCacheableDirectUrl(
                                                        rawPlayUrl, declaredMime)) {
                                            try {
                                                SourceController.ensureProxy(a, a.config);
                                                playUrl =
                                                        MediaDiskCache.getInstance(
                                                                        a.getCacheDir(), cacheMb)
                                                                .register(rawPlayUrl, mediaHeaders);
                                            } catch (Exception cacheErr) {
                                                AppLog.w(
                                                        "PlaybackController",
                                                        "Disk cache proxy fallback to direct URL",
                                                        cacheErr);
                                            }
                                        }
                                    }
                                    candidate.configureDefaultAudio();
                                    candidate.setDataSource(a, Uri.parse(playUrl), mediaHeaders);
                                    try {
                                        if (ep.name != null
                                                && !ep.name.isEmpty()
                                                && ep.media
                                                        .optString("_episodeName", "")
                                                        .isEmpty()) {
                                            ep.media.put("_episodeName", ep.name);
                                        }
                                        if (a.activeLine != null
                                                && a.activeLine.name != null
                                                && !a.activeLine.name.isEmpty()
                                                && ep.media.optString("_lineName", "").isEmpty()) {
                                            ep.media.put("_lineName", a.activeLine.name);
                                        }
                                    } catch (Exception ignored) {
                                    }
                                    candidate.setOptions(ep.media);
                                    final MoviePlayer ready = candidate;
                                    a.ui.post(
                                            () -> {
                                                if (ticket != a.generation || a.isFinishing()) {
                                                    ready.release();
                                                    return;
                                                }
                                                if (useSystemBackend
                                                        && (activeSurface[0] == null
                                                                || !activeSurface[0].isValid())) {
                                                    initDispatched[0] = false;
                                                    ready.release();
                                                    return;
                                                }
                                                a.player = ready;
                                                surface.setExternalNativeRenderer(
                                                        ready instanceof MpvPlayer);
                                                if (activeSurface[0] != null
                                                        && activeSurface[0].isValid()) {
                                                    ready.setSurface(activeSurface[0]);
                                                    if (surface.getWidth() > 0
                                                            && surface.getHeight() > 0) {
                                                        ready.setSurfaceSize(
                                                                surface.getWidth(),
                                                                surface.getHeight());
                                                    }
                                                }
                                                ready.bindSubtitles(
                                                        controls.subtitle,
                                                        text -> {
                                                            if (ticket == a.generation) {
                                                                controls.lastSubtitle =
                                                                        String.valueOf(text);
                                                            }
                                                        });
                                                ready.setOnTextTracksChangedListener(
                                                        () -> {
                                                            if (ticket == a.generation
                                                                    && a.playbackControls
                                                                            == controls) {
                                                                controls
                                                                        .onPlayerTextTracksChanged();
                                                            }
                                                        });
                                                ready.setOnAudioTracksChangedListener(
                                                        () -> {
                                                            if (ticket == a.generation
                                                                    && a.playbackControls
                                                                            == controls) {
                                                                controls
                                                                        .onPlayerAudioTracksChanged();
                                                            }
                                                        });
                                                ready.setOnHdrChangedListener(
                                                        hdr -> {
                                                            if (ticket != a.generation
                                                                    || a.isFinishing()) return;
                                                            boolean hdrSurface =
                                                                    hdr
                                                                            && surface
                                                                                    .usesSurfaceView();
                                                            surface.setHdrContent(hdr);
                                                            VideoOutput.setWindowHdrMode(
                                                                    a, hdrSurface);
                                                            if (a.playerChrome != null) {
                                                                a.playerChrome.setHdrSurfaceActive(
                                                                        hdrSurface);
                                                            }
                                                        });
                                                ready.setOnBufferingListener(
                                                        (buf, pct) -> {
                                                            if (ticket != a.generation
                                                                    || a.isFinishing()) return;
                                                            if (a.playerChrome != null) {
                                                                a.playerChrome.setBuffering(
                                                                        buf, pct);
                                                            }
                                                        });
                                                ready.setOnPreparedListener(
                                                        mp -> {
                                                            if (ticket != a.generation) return;
                                                            a.prepared = true;
                                                            a.historyFallbackInFlight = false;
                                                            a.historyFallbackBookmark = null;
                                                            if (a.migratingHistoryOldKey != null) {
                                                                String oldKey =
                                                                        a.migratingHistoryOldKey;
                                                                a.migratingHistoryOldKey = null;
                                                                if (a.playingBookmark == null
                                                                        || !oldKey.equals(
                                                                                a.playingBookmark
                                                                                        .key())) {
                                                                    a.removeWatchHistory(
                                                                            oldKey, null);
                                                                }
                                                            }
                                                            boolean hdr = mp.isHdrVideo();
                                                            boolean hdrSurface =
                                                                    hdr
                                                                            && surface
                                                                                    .usesSurfaceView();
                                                            surface.setHdrContent(hdr);
                                                            VideoOutput.setWindowHdrMode(
                                                                    a, hdrSurface);
                                                            if (a.playerChrome != null) {
                                                                a.playerChrome.setHdrSurfaceActive(
                                                                        hdrSurface);
                                                                a.playerChrome.setLoading(false);
                                                            }
                                                            a.playing = a.foreground;
                                                            if (a.foreground) mp.start();
                                                            else mp.pause();
                                                            controls.prepared();
                                                            if (!"live".equals(s.key)
                                                                    && a.foreground
                                                                    && !ep.media.optBoolean(
                                                                            "_dvColorWarned")) {
                                                                String dvEpName =
                                                                        ep.media.optString(
                                                                                "_episodeName",
                                                                                ep.name != null
                                                                                        ? ep.name
                                                                                        : "");
                                                                String dvLineName =
                                                                        ep.media.optString(
                                                                                "_lineName",
                                                                                a.activeLine != null
                                                                                                && a.activeLine
                                                                                                                .name
                                                                                                        != null
                                                                                        ? a.activeLine
                                                                                                .name
                                                                                        : "");
                                                                if (MoviePlayer
                                                                        .looksLikeTranscodedDolbyVisionColorRisk(
                                                                                dvEpName,
                                                                                dvLineName,
                                                                                mp
                                                                                        .activeVideoMimeType())) {
                                                                    try {
                                                                        ep.media.put(
                                                                                "_dvColorWarned",
                                                                                true);
                                                                    } catch (Exception ignored) {
                                                                    }
                                                                    a.toast(
                                                                            "纯杜比视界片源经转码易偏色，建议选 HDR10 / SDR / DV+HDR 片源");
                                                                }
                                                            }
                                                            savePlaybackHistoryOnPrepared(a);
                                                            a.playStatus.setText(
                                                                    a.foreground
                                                                            ? ("live".equals(s.key)
                                                                                    ? (a
                                                                                                    .isTvDevice()
                                                                                            ? "正在直播 · 上下换台 · 菜单键工具条"
                                                                                            : "正在直播 · 单击显示选台工具栏")
                                                                                    : (a
                                                                                                    .isTvDevice()
                                                                                            ? "正在播放 · 确认暂停 · 上下键显示工具条"
                                                                                            : "正在播放 · 双击暂停 · 左右滑快进 · 上下滑调亮度音量"))
                                                                            : (a.isTvDevice()
                                                                                    ? "已暂停 · 按确认继续"
                                                                                    : "已暂停 · 双击继续"));
                                                            clock(a, ticket);
                                                            if (a.changingMiniEpisode) {
                                                                a.changingMiniEpisode = false;
                                                                minimizePlayback(a);
                                                            } else if (a.foreground) {
                                                                if (a.playerLocked) {
                                                                    showControls(a, false);
                                                                } else if ("live".equals(s.key)) {
                                                                    showControls(a, false);
                                                                    a.toast(
                                                                            "频道 "
                                                                                    + (a.liveSession
                                                                                                    == null
                                                                                            ? ""
                                                                                            : (a.liveSession
                                                                                                                    .index
                                                                                                            + 1)
                                                                                                    + " · ")
                                                                                    + v.title);
                                                                } else scheduleHide(a);
                                                            }
                                                        });
                                                ready.setOnVideoSizeChangedListener(
                                                        (mp, w, h) -> {
                                                            if (ticket == a.generation) {
                                                                if (w > 0
                                                                        && h > 0
                                                                        && mp.isHdrVideo()) {
                                                                    boolean hdrSurface =
                                                                            surface
                                                                                    .usesSurfaceView();
                                                                    surface.setHdrContent(true);
                                                                    VideoOutput.setWindowHdrMode(
                                                                            a, hdrSurface);
                                                                    if (a.playerChrome != null) {
                                                                        a.playerChrome
                                                                                .setHdrSurfaceActive(
                                                                                        hdrSurface);
                                                                    }
                                                                }
                                                                controls.resize(w, h);
                                                                if ("live".equals(s.key)
                                                                        && w > 0
                                                                        && h > 0
                                                                        && a.prefs != null) {
                                                                    String updated =
                                                                            LiveQualityPolicy
                                                                                    .recordStreamSuccess(
                                                                                            a.prefs
                                                                                                    .getString(
                                                                                                            Prefs
                                                                                                                    .LIVE_STREAM_METRICS,
                                                                                                            ""),
                                                                                            ep.url,
                                                                                            w,
                                                                                            h,
                                                                                            (int)
                                                                                                    mp
                                                                                                            .getFirstFrameMs(),
                                                                                            System
                                                                                                    .currentTimeMillis());
                                                                    a.prefs
                                                                            .edit()
                                                                            .putString(
                                                                                    Prefs
                                                                                            .LIVE_STREAM_METRICS,
                                                                                    updated)
                                                                            .apply();
                                                                }
                                                            }
                                                        });
                                                ready.setOnCompletionListener(
                                                        mp -> {
                                                            if (ticket != a.generation
                                                                    || a.player != ready) return;
                                                            if (a.markerHost != null)
                                                                a.markerHost.abort();
                                                            int curPos = ready.getCurrentPosition();
                                                            int curDur = ready.getDuration();
                                                            if (curDur <= 0
                                                                    && a.playingBookmark != null
                                                                    && a.playingBookmark.duration
                                                                            > 0) {
                                                                curDur = a.playingBookmark.duration;
                                                            }
                                                            int eofRetries =
                                                                    Math.max(
                                                                            ep.media.optInt(
                                                                                    "_eofReconnectCount",
                                                                                    0),
                                                                            a.activeEpisode != null
                                                                                            && a.activeEpisode
                                                                                                            .media
                                                                                                    != null
                                                                                    ? a
                                                                                            .activeEpisode
                                                                                            .media
                                                                                            .optInt(
                                                                                                    "_eofReconnectCount",
                                                                                                    0)
                                                                                    : 0);
                                                            if (MoviePlayer
                                                                            .isPrematureProgressiveEnd(
                                                                                    "live"
                                                                                            .equals(
                                                                                                    s.key),
                                                                                    curPos,
                                                                                    curDur)
                                                                    && eofRetries < 3
                                                                    && a.activeLine != null
                                                                    && a.activeEpisode != null) {
                                                                try {
                                                                    ep.media.put(
                                                                            "_eofReconnectCount",
                                                                            eofRetries + 1);
                                                                    if (a.activeEpisode.media
                                                                            != null) {
                                                                        a.activeEpisode.media.put(
                                                                                "_eofReconnectCount",
                                                                                eofRetries + 1);
                                                                    }
                                                                } catch (Exception ignored) {
                                                                }
                                                                a.resumeAt = curPos;
                                                                a.toast("网络波动，正在断点续连…");
                                                                a.playStatus.setText(
                                                                        "网络中断，正在断点续连…");
                                                                final Cms.Line retryLine =
                                                                        a.activeLine;
                                                                final Cms.Episode retryEp =
                                                                        a.activeEpisode;
                                                                a.ui.postDelayed(
                                                                        () -> {
                                                                            if (ticket
                                                                                            == a.generation
                                                                                    && !a
                                                                                            .isFinishing()) {
                                                                                resolvePlayer(
                                                                                        a, s, v,
                                                                                        retryLine,
                                                                                        retryEp);
                                                                            }
                                                                        },
                                                                        450L);
                                                                return;
                                                            }
                                                            if (a.playingBookmark != null) {
                                                                if (curDur > 0) {
                                                                    a.playingBookmark.duration =
                                                                            curDur;
                                                                    a.playingBookmark.position =
                                                                            Math.max(
                                                                                    a.playingBookmark
                                                                                            .position,
                                                                                    curDur);
                                                                } else if (a.playingBookmark
                                                                                .position
                                                                        <= 0) {
                                                                    a.playingBookmark.position =
                                                                            1000;
                                                                }
                                                            }
                                                            savePlaybackHistory(a, true);
                                                            a.playing = false;
                                                            stopEmbySession(a);
                                                            a.playStatus.setText("播放结束");
                                                            controls.completed();
                                                        });
                                                ready.setOnErrorListener(
                                                        (mp, what, extra) -> {
                                                            if (ticket != a.generation
                                                                    || a.player != ready)
                                                                return true;
                                                            if (a.markerHost != null)
                                                                a.markerHost.abort();
                                                            int currentPos =
                                                                    mp.getCurrentPosition();
                                                            if (!"live".equals(s.key)
                                                                    && what >= 2000
                                                                    && what < 3000
                                                                    && currentPos > 0
                                                                    && a.activeLine != null
                                                                    && a.activeEpisode != null) {
                                                                int ioRetries =
                                                                        Math.max(
                                                                                ep.media.optInt(
                                                                                        "_ioReconnectCount",
                                                                                        0),
                                                                                a.activeEpisode
                                                                                                        .media
                                                                                                != null
                                                                                        ? a
                                                                                                .activeEpisode
                                                                                                .media
                                                                                                .optInt(
                                                                                                        "_ioReconnectCount",
                                                                                                        0)
                                                                                        : 0);
                                                                if (ioRetries < 2) {
                                                                    try {
                                                                        ep.media.put(
                                                                                "_ioReconnectCount",
                                                                                ioRetries + 1);
                                                                        if (a.activeEpisode.media
                                                                                != null) {
                                                                            a.activeEpisode.media
                                                                                    .put(
                                                                                            "_ioReconnectCount",
                                                                                            ioRetries
                                                                                                    + 1);
                                                                        }
                                                                    } catch (Exception ignored) {
                                                                    }
                                                                    a.resumeAt = currentPos;
                                                                    a.toast("连接波动，正在刷新播放链接并续播…");
                                                                    a.playStatus.setText(
                                                                            "连接波动，正在刷新播放链接…");
                                                                    final Cms.Line retryLine =
                                                                            a.activeLine;
                                                                    final Cms.Episode retryEp =
                                                                            a.activeEpisode;
                                                                    a.ui.postDelayed(
                                                                            () -> {
                                                                                if (ticket
                                                                                                == a.generation
                                                                                        && !a
                                                                                                .isFinishing()) {
                                                                                    resolvePlayer(
                                                                                            a, s, v,
                                                                                            retryLine,
                                                                                            retryEp);
                                                                                }
                                                                            },
                                                                            500L);
                                                                    return true;
                                                                }
                                                            }
                                                            if (mp instanceof MpvPlayer
                                                                    && !ep.media.optBoolean(
                                                                            "_mpvFallback")) {
                                                                try {
                                                                    ep.media.put(
                                                                            "_mpvFallback", true);
                                                                } catch (Exception ignored) {
                                                                }
                                                                a.resumeAt =
                                                                        mp.getCurrentPosition();
                                                                a.playStatus.setText(
                                                                        "MPV 播放异常，正在切换 Media3 内核…");
                                                                a.ui.post(
                                                                        () -> {
                                                                            if (ticket
                                                                                    == a.generation)
                                                                                playerPage(
                                                                                        a, s, v,
                                                                                        ep);
                                                                        });
                                                                return true;
                                                            }
                                                            if (PlaybackFailure.decoderFallback(
                                                                            what)
                                                                    && a.prefs.getInt(
                                                                                    Prefs
                                                                                            .DECODER_MODE,
                                                                                    0)
                                                                            == 0) {
                                                                if (currentPos >= 5000
                                                                        && !ep.media.optBoolean(
                                                                                "_hwRetry")
                                                                        && !ep.media.optBoolean(
                                                                                "_softwareFallback")
                                                                        && !ep.media.optBoolean(
                                                                                "_systemFallback")
                                                                        && !mp
                                                                                .isUnsupportedDolbyVisionProfile5()) {
                                                                    try {
                                                                        ep.media.put(
                                                                                "_hwRetry", true);
                                                                    } catch (Exception ignored) {
                                                                    }
                                                                    a.resumeAt = currentPos;
                                                                    a.playStatus.setText(
                                                                            "解码器波动，正在重新初始化硬件解码…");
                                                                    a.ui.postDelayed(
                                                                            () -> {
                                                                                if (ticket
                                                                                                == a.generation
                                                                                        && !a
                                                                                                .isFinishing()) {
                                                                                    playerPage(
                                                                                            a, s, v,
                                                                                            ep);
                                                                                }
                                                                            },
                                                                            250L);
                                                                    return true;
                                                                }
                                                                if (!ep.media.optBoolean(
                                                                                "_softwareFallback")
                                                                        && !mp
                                                                                .isUnsupportedDolbyVisionProfile5()) {
                                                                    try {
                                                                        ep.media.put(
                                                                                "_softwareFallback",
                                                                                true);
                                                                        ep.media.put(
                                                                                "_fallbackMode",
                                                                                mp
                                                                                        .softFallbackMode());
                                                                    } catch (Exception ignored) {
                                                                    }
                                                                    a.resumeAt =
                                                                            mp.getCurrentPosition();
                                                                    a.playStatus.setText(
                                                                            "正在尝试内置软解码…");
                                                                    a.ui.post(
                                                                            () -> {
                                                                                if (ticket
                                                                                        == a.generation)
                                                                                    playerPage(
                                                                                            a, s, v,
                                                                                            ep);
                                                                            });
                                                                    return true;
                                                                }
                                                                if (!ep.media.optBoolean(
                                                                                "_systemFallback")
                                                                        && a.prefs.getInt(
                                                                                        Prefs
                                                                                                .PLAYER_ENGINE,
                                                                                        0)
                                                                                != 1) {
                                                                    try {
                                                                        ep.media.put(
                                                                                "_systemFallback",
                                                                                true);
                                                                    } catch (Exception ignored) {
                                                                    }
                                                                    a.resumeAt =
                                                                            mp.getCurrentPosition();
                                                                    a.playStatus.setText(
                                                                            "正在切换至系统硬件播放器…");
                                                                    a.ui.post(
                                                                            () -> {
                                                                                if (ticket
                                                                                        == a.generation)
                                                                                    playerPage(
                                                                                            a, s, v,
                                                                                            ep);
                                                                            });
                                                                    return true;
                                                                }
                                                            }
                                                            if (tryAdvanceQualityOrLiveStream(
                                                                    a, ticket, s, v, ep)) {
                                                                return true;
                                                            }
                                                            if (v != null
                                                                    && v.lines != null
                                                                    && v.lines.size() > 1
                                                                    && a.activeLine != null) {
                                                                int curLineIdx =
                                                                        v.lines.indexOf(
                                                                                a.activeLine);
                                                                int hopCount =
                                                                        ep.media.optInt(
                                                                                "_lineHopCount", 0);
                                                                if (curLineIdx >= 0
                                                                        && hopCount
                                                                                < Math.min(
                                                                                        3,
                                                                                        v.lines
                                                                                                        .size()
                                                                                                - 1)) {
                                                                    Cms.Line nextLine =
                                                                            v.lines.get(
                                                                                    (curLineIdx + 1)
                                                                                            % v
                                                                                                    .lines
                                                                                                    .size());
                                                                    Cms.Episode nextEp =
                                                                            findMatchingEpisode(
                                                                                    nextLine,
                                                                                    a.activeLine,
                                                                                    a.activeEpisode
                                                                                                    != null
                                                                                            ? a.activeEpisode
                                                                                            : ep);
                                                                    if (nextEp != null
                                                                            && nextLine
                                                                                    != a.activeLine) {
                                                                        try {
                                                                            nextEp.media.put(
                                                                                    "_lineHopCount",
                                                                                    hopCount + 1);
                                                                        } catch (
                                                                                Exception ignored) {
                                                                        }
                                                                        a.resumeAt =
                                                                                mp
                                                                                        .getCurrentPosition();
                                                                        a.playStatus.setText(
                                                                                "当前线路异常，正在切换至 "
                                                                                        + nextLine.name
                                                                                        + "…");
                                                                        a.ui.post(
                                                                                () -> {
                                                                                    if (ticket
                                                                                            == a.generation) {
                                                                                        rememberEpisodeOnBackStack(
                                                                                                a,
                                                                                                nextLine,
                                                                                                nextEp);
                                                                                        resolvePlayer(
                                                                                                a,
                                                                                                s,
                                                                                                v,
                                                                                                nextLine,
                                                                                                nextEp);
                                                                                    }
                                                                                });
                                                                        return true;
                                                                    }
                                                                }
                                                            }
                                                            if (tryHistoryCrossSourceFailover(
                                                                    a,
                                                                    s,
                                                                    Math.max(
                                                                            0,
                                                                            mp
                                                                                    .getCurrentPosition()),
                                                                    "原片源播放失败")) {
                                                                return true;
                                                            }
                                                            stopEmbySession(a);
                                                            a.prepared = false;
                                                            a.playing = false;
                                                            if (a.playerChrome != null)
                                                                a.playerChrome.setLoading(false);
                                                            a.playStatus.setText(
                                                                    mp.getFailureMessage(what)
                                                                            + "（"
                                                                            + what
                                                                            + "）");
                                                            showControls(a, true);
                                                            return true;
                                                        });
                                                a.playStatus.setText("正在加载播放…");
                                                ready.prepareAsync();
                                                if ("live".equals(s.key)) {
                                                    JSONArray liveQs =
                                                            ep.media.optJSONArray("qualities");
                                                    int curQIdx = ep.media.optInt("_qualityIdx", 0);
                                                    if (liveQs != null
                                                            && curQIdx + 1 < liveQs.length()) {
                                                        a.ui.postDelayed(
                                                                () -> {
                                                                    if (ticket == a.generation
                                                                            && !a.prepared
                                                                            && a.current != null
                                                                            && a.current.player) {
                                                                        tryAdvanceQualityOrLiveStream(
                                                                                a, ticket, s, v,
                                                                                ep);
                                                                    }
                                                                },
                                                                7500L);
                                                    }
                                                }
                                            });
                                } catch (Exception ex) {
                                    AppLog.w("PlaybackController", "player init failed", ex);
                                    if (candidate != null) candidate.release();
                                    a.ui.post(
                                            () -> {
                                                if (ticket == a.generation) {
                                                    if (a.playerChrome != null)
                                                        a.playerChrome.setLoading(false);
                                                    a.playStatus.setText(a.message(ex));
                                                    showControls(a, true);
                                                }
                                            });
                                }
                            });
                };
        surface.listen(
                new VideoOutput.Listener() {
                    public void available(Surface value) {
                        activeSurface[0] = value;
                        if (ticket != a.generation) return;
                        if (a.player != null) {
                            a.player.setSurface(value);
                            if (surface.getWidth() > 0 && surface.getHeight() > 0) {
                                a.player.setSurfaceSize(surface.getWidth(), surface.getHeight());
                            }
                            return;
                        }
                        launchPlayerInit.run();
                    }

                    public void resized(int width, int height) {
                        if (ticket == a.generation && a.player != null) {
                            a.player.setSurfaceSize(width, height);
                        }
                    }

                    public void destroyed() {
                        activeSurface[0] = null;
                        if (ticket == a.generation && a.player != null) a.player.setSurface(null);
                    }
                });
        if (!useSystemBackend) {
            launchPlayerInit.run();
        }
        if (keepLocked) {
            a.playerLocked = true;
            a.controlsVisible = false;
            if (a.playbackControls != null) a.playbackControls.visible(false);
            if (a.playerOverlay != null) {
                a.playerOverlay.animate().cancel();
                a.playerOverlay.setAlpha(0f);
                a.playerOverlay.setVisibility(View.GONE);
            }
            if (a.hideControls != null) a.ui.removeCallbacks(a.hideControls);
            setUnlockButtonVisible(a, false, false);
            a.root.requestFocus();
        } else {
            a.playbackControls.timeline.requestFocus();
            if ("live".equals(s.key)) showControls(a, false);
        }
    }

    static boolean isPlayerLocked(MainActivity a) {
        return a != null && !a.isTvDevice() && a.playerLocked;
    }

    static void setPlayerLocked(MainActivity a, boolean locked) {
        if (a == null || a.isTvDevice() || a.playerLocked == locked) return;
        if (locked) {
            finishSeek(a, false);
            if (a.touchPlayerGesture != null) {
                a.touchPlayerGesture.cancelActiveGesture();
            }
            if (a.playbackControls != null) {
                a.playbackControls.sliderSeeking = false;
                a.playbackControls.touchSeeking = false;
                if (a.playbackControls.activeDialog != null) {
                    a.playbackControls.activeDialog.dismiss();
                    a.playbackControls.activeDialog = null;
                    a.playbackControls.dialogOpen = false;
                }
            }
            showControls(a, false);
            a.playerLocked = true;
            if (android.os.Build.VERSION.SDK_INT >= 18) {
                a.setRequestedOrientation(
                        android.content.pm.ActivityInfo.SCREEN_ORIENTATION_LOCKED);
            }
            setUnlockButtonVisible(a, true, true);
            if (a.touchPlayerGesture != null) {
                a.touchPlayerGesture.showBriefNotice("已锁定播放界面 · 防误触开启");
            }
        } else {
            a.playerLocked = false;
            a.setRequestedOrientation(
                    a.isPortrait()
                            ? android.content.pm.ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
                            : android.content.pm.ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE);
            setUnlockButtonVisible(a, false, false);
            showControls(a, true);
            if (a.touchPlayerGesture != null) {
                a.touchPlayerGesture.showBriefNotice("已解锁播放界面");
            }
        }
    }

    static void setUnlockButtonVisible(MainActivity a, boolean visible, boolean autoHide) {
        if (a == null) return;
        if (a.hideLockButton != null) {
            a.ui.removeCallbacks(a.hideLockButton);
        }
        if (a.playerChrome != null && a.playerChrome.unlockPill != null) {
            View pill = a.playerChrome.unlockPill;
            pill.animate().cancel();
            pill.setAlpha(1f);
            pill.setVisibility(visible && a.playerLocked ? View.VISIBLE : View.GONE);
        }
        if (visible && autoHide && a.playerLocked) {
            a.hideLockButton =
                    () -> {
                        if (a.playerLocked) {
                            setUnlockButtonVisible(a, false, false);
                        }
                    };
            a.ui.postDelayed(a.hideLockButton, 3500L);
        }
    }

    static void toggleUnlockButton(MainActivity a) {
        if (a == null || !a.playerLocked) return;
        boolean currentlyVisible =
                a.playerChrome != null
                        && a.playerChrome.unlockPill != null
                        && a.playerChrome.unlockPill.getVisibility() == View.VISIBLE;
        setUnlockButtonVisible(a, !currentlyVisible, !currentlyVisible);
    }

    static void revealLockedHint(MainActivity a) {
        if (a == null || !a.playerLocked) return;
        setUnlockButtonVisible(a, true, true);
        if (a.touchPlayerGesture != null) {
            a.touchPlayerGesture.showBriefNotice("屏幕已锁定 · 点击解锁恢复操作");
        }
    }

    static void showControls(MainActivity a, boolean visible) {
        showControls(a, visible, false);
    }

    static void showControls(MainActivity a, boolean visible, boolean progressOnly) {
        if (!visible) finishSeek(a, false);
        if (visible && a.playerChrome != null) a.playerChrome.cancelEpisodeHoldSwitch();
        if (a.miniMode && visible) return;
        if (a.playerLocked && visible) {
            setUnlockButtonVisible(a, true, true);
            return;
        }
        boolean changed = a.controlsVisible != visible;
        a.controlsVisible = visible;
        if (visible && a.playClock != null && a.player != null && a.prepared) {
            try {
                int rawPos = a.player.getCurrentPosition();
                int displayPos =
                        a.playbackControls != null
                                ? a.playbackControls.displayPosition(rawPos)
                                : rawPos;
                int dur = a.player.getDuration();
                if (dur <= 0 && a.playingBookmark != null && a.playingBookmark.duration > 0) {
                    dur = a.playingBookmark.duration;
                }
                String clockText =
                        formatTime(displayPos)
                                + " / "
                                + (dur > 0 ? formatTime(dur) : (a.isLive() ? "直播" : "--:--"));
                if (!clockText.contentEquals(a.playClock.getText())) {
                    a.playClock.setText(clockText);
                }
            } catch (Exception ignored) {
            }
        }
        if (a.playerChrome != null) {
            a.playerChrome.setProgressOnlyMode(visible && progressOnly);
        }
        if (a.playbackControls != null) a.playbackControls.visible(visible);
        if (a.playerChrome != null) a.playerChrome.update();
        if (a.playerOverlay != null) {
            a.playerOverlay.animate().cancel();
            if (visible) {
                a.playerOverlay.setAlpha(1f);
                a.playerOverlay.setTranslationY(0f);
                a.playerOverlay.setVisibility(View.VISIBLE);
                if (changed && !a.reduced && !a.isTvDevice()) {
                    a.playerOverlay.setAlpha(0f);
                    a.playerOverlay.animate().alpha(1f).setDuration(150).start();
                }
            } else {
                if (a.reduced || a.isTvDevice()) {
                    a.playerOverlay.setAlpha(0f);
                    a.playerOverlay.setVisibility(View.GONE);
                } else {
                    long hideDur = 140;
                    UiCompat.startWithEndAction(
                            a.playerOverlay.animate().alpha(0f).setDuration(hideDur),
                            a.playerOverlay,
                            hideDur,
                            () -> {
                                if (!a.controlsVisible && a.playerOverlay != null)
                                    a.playerOverlay.setVisibility(View.GONE);
                            });
                }
                a.root.requestFocus();
            }
        }
        if (visible) {
            if (changed && a.playbackControls != null && a.isTvDevice()) {
                a.playbackControls.timeline.requestFocus();
            }
            scheduleHide(a);
        } else if (a.hideControls != null) a.ui.removeCallbacks(a.hideControls);
    }

    static void scheduleHide(MainActivity a) {
        if (a.hideControls != null) a.ui.removeCallbacks(a.hideControls);
        a.hideControls =
                () -> {
                    if (a.prepared
                            && a.playing
                            && (a.playbackControls == null || !a.playbackControls.dialogOpen))
                        showControls(a, false);
                };
        a.ui.postDelayed(a.hideControls, 5000);
    }

    static void clock(MainActivity a, int ticket) {
        if (ticket != a.generation || a.player == null || !a.prepared) return;
        updateInMemoryBookmark(a);
        savePlaybackHistory(a, false);
        try {
            if (a.embyReporter != null)
                a.embyReporter.update(a.player.getCurrentPosition(), !a.player.isPlaying());
            if (a.seekGesture.active) previewSeek(a);
            else if (a.playbackControls == null || !a.playbackControls.isUserSeeking()) {
                int rawPos = a.player.getCurrentPosition();
                int displayPos =
                        a.playbackControls != null
                                ? a.playbackControls.displayPosition(rawPos)
                                : rawPos;
                int dur = a.player.getDuration();
                if (dur <= 0 && a.playingBookmark != null && a.playingBookmark.duration > 0) {
                    dur = a.playingBookmark.duration;
                }
                if (a.playerChrome != null) {
                    a.playerChrome.updatePlaybackHud(displayPos, dur, a.isLive());
                }
                if (a.controlsVisible && a.playClock != null) {
                    String clockText =
                            formatTime(displayPos)
                                    + " / "
                                    + (dur > 0 ? formatTime(dur) : (a.isLive() ? "直播" : "--:--"));
                    if (!clockText.contentEquals(a.playClock.getText())) {
                        a.playClock.setText(clockText);
                    }
                }
                if (a.playbackControls != null) a.playbackControls.tick();
            }
            if (a.playerChrome != null) a.playerChrome.update();
        } catch (Exception ignored) {
        }
        a.ui.postDelayed(() -> clock(a, ticket), 1000);
    }

    static void togglePlayback(MainActivity a) {
        if (a.player == null || !a.prepared) return;
        if (a.embyReporter == null
                && a.playbackControls != null
                && a.playbackControls.site != null
                && a.playbackControls.site.api != null
                && a.playbackControls.site.api.startsWith(com.pilipala.emby.EmbyLibrary.PREFIX)) {
            a.resumeAt = -1;
            resolvePlayer(
                    a,
                    a.playbackControls.site,
                    a.playbackControls.video,
                    a.activeLine,
                    a.activeEpisode);
            return;
        }
        try {
            if (a.player.isPlaying()) {
                a.player.pause();
                a.playing = false;
                savePlaybackHistory(a, true);
                a.playStatus.setText(a.isTvDevice() ? "已暂停 · 按确认继续" : "已暂停 · 双击继续");
            } else {
                if (a.player.getDuration() > 0
                        && a.player.getCurrentPosition() >= a.player.getDuration() - 300)
                    a.player.seekTo(0);
                a.player.start();
                a.playing = true;
                a.playStatus.setText(
                        a.isTvDevice()
                                ? "正在播放 · 确认暂停 · 上下键显示工具条"
                                : "正在播放 · 双击暂停 · 左右滑快进 · 上下滑调亮度音量");
            }
            if (a.playerChrome != null) a.playerChrome.update();
            if (a.embyReporter != null)
                a.embyReporter.update(a.player.getCurrentPosition(), !a.playing);
        } catch (Exception error) {
            AppLog.w("PlaybackController", "togglePlayback failed", error);
        }
    }

    static void beginSeek(MainActivity a, int direction) {
        if (a.player == null || !a.prepared || a.player.getDuration() <= 0) return;
        int position = a.seekGesture.active ? a.seekGesture.target : a.player.getCurrentPosition();
        if (!a.seekGesture.active) a.seekStatus = a.playStatus.getText().toString();
        a.seekGesture.begin(
                direction, position, a.player.getDuration(), SystemClock.uptimeMillis());
        showControls(a, true, a.isTvDevice());
        if (a.playbackControls != null && a.isTvDevice()) {
            a.playbackControls.timeline.requestFocus();
        }
        previewSeek(a);
        a.ui.removeCallbacks(a.seekPulse);
        a.ui.postDelayed(a.seekPulse, 100);
    }

    static void previewSeek(MainActivity a) {
        if (!a.seekGesture.active || a.playbackControls == null) return;
        a.playbackControls.timeline.setProgress(a.seekGesture.target);
        a.playClock.setText(
                formatTime(a.seekGesture.target) + " / " + formatTime(a.seekGesture.duration));
        long now = SystemClock.uptimeMillis();
        int seekSpeed = a.seekGesture.speed(now);
        boolean accel = a.seekGesture.accelerated(now);
        String msg =
                (a.seekGesture.direction > 0 ? "快进" : "快退")
                        + (seekSpeed > 0
                                ? (accel ? " · 加速 " : " · ") + seekSpeed + " 秒/秒"
                                : " · 15 秒")
                        + " · 松开跳转";
        if (a.playStatus != null) a.playStatus.setText(msg);
        if (a.playerChrome != null && a.playerChrome.seekHint != null) {
            a.playerChrome.seekHint.setText(msg);
        }
    }

    static void finishSeek(MainActivity a, boolean commit) {
        if (!a.seekGesture.active) return;
        a.seekGesture.advance(SystemClock.uptimeMillis());
        int target = a.seekGesture.target;
        a.seekGesture.cancel();
        a.ui.removeCallbacks(a.seekPulse);
        if (commit && a.player != null && a.prepared) {
            a.player.seekTo(target);
            if (a.playingBookmark != null) {
                a.playingBookmark.position = Math.max(0, target);
            }
            savePlaybackHistory(a, true);
        }
        if (a.playStatus != null) a.playStatus.setText(a.seekStatus);
        if (a.playerChrome != null && a.playerChrome.seekHint != null) {
            a.playerChrome.seekHint.setText("");
        }
        if (a.player != null && a.prepared && a.playbackControls != null) {
            int position = commit ? target : a.player.getCurrentPosition();
            int dur = a.player.getDuration();
            a.playbackControls.timeline.setProgress(position);
            a.playClock.setText(formatTime(position) + " / " + formatTime(dur));
            if (a.playerChrome != null) {
                a.playerChrome.updatePlaybackHud(
                        a.playbackControls.displayPosition(position), dur, a.isLive());
            }
        }
        if (commit) scheduleHide(a);
    }

    static boolean tryAdvanceQualityOrLiveStream(
            MainActivity a, int ticket, Cms.Site s, Cms.Video v, Cms.Episode ep) {
        if ("live".equals(s.key) && a.prefs != null && ep.url != null && !ep.url.isEmpty()) {
            String failedMetrics =
                    LiveQualityPolicy.recordStreamFailure(
                            a.prefs.getString(Prefs.LIVE_STREAM_METRICS, ""),
                            ep.url,
                            System.currentTimeMillis());
            a.prefs.edit().putString(Prefs.LIVE_STREAM_METRICS, failedMetrics).apply();
        }
        JSONArray qualities = ep.media.optJSONArray("qualities");
        int qIdx = ep.media.optInt("_qualityIdx", 0);
        if (qualities == null || qIdx + 1 >= qualities.length()) return false;
        JSONObject nextQ = qualities.optJSONObject(qIdx + 1);
        String nextUrl = nextQ != null ? nextQ.optString("url", "") : "";
        if (nextUrl.isEmpty()) return false;
        try {
            ep.media.put("_qualityIdx", qIdx + 1);
            ep.media.remove("_softwareFallback");
            ep.media.remove("_systemFallback");
            ep.media.remove("_mpvFallback");
        } catch (Exception ignored) {
        }
        applyCandidateHeaders(s, ep, nextQ);
        if (LiveQualityPolicy.isEmbyLiveUrl(nextUrl)) {
            a.ui.post(
                    () -> {
                        if (ticket == a.generation) {
                            LiveController.playEmbyLiveAsync(a, s, v, ep, nextUrl);
                        }
                    });
            return true;
        }
        ep.url = LocalProxy.rewrite(nextUrl);
        String qName = nextQ.optString("name", "备用线路");
        if (a.playStatus != null) {
            a.playStatus.setText("正在切换至 " + qName + "…");
        }
        if (a.playerChrome != null) {
            a.playerChrome.setLoadingStatus("正在切换至 " + qName + "…", null);
        }
        a.ui.post(
                () -> {
                    if (ticket == a.generation) playerPage(a, s, v, ep);
                });
        return true;
    }

    static void applyCandidateHeaders(Cms.Site s, Cms.Episode ep, JSONObject qObj) {
        if (ep == null || qObj == null) return;
        ep.headers.clear();
        if (s != null && !"live".equals(s.key)) {
            ep.headers.putAll(s.headers);
        }
        JSONObject hs = qObj.optJSONObject("headers");
        if (hs != null) {
            java.util.Iterator<String> keys = hs.keys();
            while (keys.hasNext()) {
                String k = keys.next();
                String val = hs.optString(k, "");
                if (!val.isEmpty()) ep.headers.put(k, val);
            }
        }
        if (s != null && "live".equals(s.key)) {
            s.headers.clear();
            s.headers.putAll(ep.headers);
            if (!LiveQualityPolicy.isEmbyLiveUrl(qObj.optString("url", ""))) {
                ep.media.remove("embySession");
                s.api = qObj.optString("url", "");
            }
        }
        String mime = qObj.optString("mimeType", "").trim();
        JSONObject drm = qObj.optJSONObject("drm");
        try {
            if (!mime.isEmpty()) ep.media.put("mimeType", mime);
            else ep.media.remove("mimeType");
            if (drm != null) ep.media.put("drm", new JSONObject(drm.toString()));
            else ep.media.remove("drm");
        } catch (Exception ignored) {
        }
    }

    static void savePlaybackHistoryOnPrepared(MainActivity a) {
        if (a.privateMode) return;
        if (a.player == null || !a.prepared || a.playingBookmark == null) return;
        updateInMemoryBookmark(a);
        a.lastBookmarkSave = a.playingBookmark.updated;
        final WatchHistory.Entry snapshot = cloneBookmark(a.playingBookmark);
        if (a.prefs != null && snapshot != null) {
            WatchHistory.enqueueUpsert(a.historyPersistence(), snapshot);
        }
        CloudSyncDialog.scheduleAutoPush(a, false);
    }

    static void savePlaybackHistory(MainActivity a, boolean force) {
        if (a.privateMode) return;
        if (a.player == null || !a.prepared || a.playingBookmark == null) return;
        updateInMemoryBookmark(a);
        if (a.playingBookmark.position < 1000 && a.playingBookmark.position == 0) return;
        long now = System.currentTimeMillis();
        if (!force && now - a.lastBookmarkSave < DISK_SAVE_INTERVAL_MS) return;
        a.lastBookmarkSave = now;
        final WatchHistory.Entry snapshot = cloneBookmark(a.playingBookmark);
        if (a.prefs != null && snapshot != null) {
            WatchHistory.enqueueUpsert(a.historyPersistence(), snapshot);
        }
        CloudSyncDialog.scheduleAutoPush(a, force);
    }

    static void stopEmbySession(MainActivity a) {
        if (a.embyReporter == null) return;
        int position = 0;
        try {
            if (a.player != null && a.prepared) position = a.player.getCurrentPosition();
        } catch (Exception ignored) {
        }
        a.embyReporter.stop(position);
        a.embyReporter = null;
    }

    static void releasePlayer(MainActivity a) {
        if (a.markerHost != null) a.markerHost.abort();
        if (a.playerChrome != null) a.playerChrome.cancelEpisodeHoldSwitch();
        finishSeek(a, false);
        if (a.hideLockButton != null) {
            a.ui.removeCallbacks(a.hideLockButton);
            a.hideLockButton = null;
        }
        a.playerLocked = false;
        a.touchPlayerGesture = null;
        a.clearLiveNumber();
        savePlaybackHistory(a, true);
        stopEmbySession(a);
        a.miniMode = false;
        a.miniDetails = null;
        if (a.playbackControls != null) a.playbackControls.close();
        a.playbackControls = null;
        a.prepared = false;
        a.playing = false;
        if (a.player != null) {
            try {
                a.player.release();
            } catch (Exception error) {
                AppLog.w("PlaybackController", "player.release failed", error);
            }
            a.player = null;
        }
        VideoOutput.setWindowHdrMode(a, false);
        a.getWindow().clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
    }

    /**
     * Policy for HUD visibility on TV pause/resume toggle: clicking pause on TV keeps the frame
     * clean without popping up top/bottom toolbars or timeline HUD.
     */
    static boolean shouldShowHudOnPauseToggle(
            boolean tvDevice, boolean controlsAlreadyVisible, boolean nowPlaying) {
        if (!tvDevice) return true;
        return false;
    }

    static boolean dispatchPlaybackKey(MainActivity a, KeyEvent event) {
        if (a.current == null
                || !a.current.player
                || a.miniMode
                || (a.playbackControls != null && a.playbackControls.dialogOpen)) return false;
        int key = event.getKeyCode();
        EpisodeHoldSwitchOverlay holdOverlay =
                a.playerChrome != null ? a.playerChrome.episodeHoldOverlay : null;
        if (holdOverlay != null) {
            if (holdOverlay.isTracking() && !holdOverlay.isTrackingKey(key)) {
                holdOverlay.cancel();
            }
            if (EpisodeHoldSwitchOverlay.isEpisodeHoldKey(key)) {
                int action = event.getAction();
                boolean eligibleHold =
                        a.isTvDevice()
                                && !a.isLive()
                                && !a.isCast()
                                && a.prepared
                                && a.markerHost == null
                                && !a.seekGesture.active
                                && (!a.controlsVisible
                                        || (a.playerChrome != null
                                                && a.playerChrome.progressOnlyMode))
                                && (a.playbackControls == null
                                        || !a.playbackControls.isSkipCountdownActive());
                if (action == KeyEvent.ACTION_DOWN) {
                    if (event.getRepeatCount() == 0 && eligibleHold) {
                        int dir = EpisodeHoldSwitchOverlay.Controller.directionForKeyCode(key);
                        boolean hasTarget =
                                a.playbackControls != null
                                        && a.playbackControls.hasAdjacentEpisode(dir);
                        String targetName =
                                a.playbackControls != null
                                        ? a.playbackControls.peekAdjacentEpisodeName(dir)
                                        : "";
                        if (holdOverlay.beginHold(
                                key, event.getDownTime(), hasTarget, targetName)) {
                            return true;
                        }
                    } else if (holdOverlay.isTrackingKey(key)) {
                        holdOverlay.onKeyRepeat(key);
                        return true;
                    }
                } else if (action == KeyEvent.ACTION_UP && holdOverlay.isTrackingKey(key)) {
                    int upResult = holdOverlay.handleKeyUp(key, event.isCanceled());
                    if (upResult == EpisodeHoldSwitchOverlay.Controller.UP_SHORT_PRESS) {
                        if (key == KeyEvent.KEYCODE_DPAD_UP && a.playbackControls != null) {
                            KeyEvent syntheticDown =
                                    new KeyEvent(
                                            event.getDownTime(),
                                            event.getEventTime(),
                                            KeyEvent.ACTION_DOWN,
                                            KeyEvent.KEYCODE_DPAD_UP,
                                            0);
                            if (a.playbackControls.markers().open(syntheticDown)) {
                                return true;
                            }
                        }
                        showControls(a, true, false);
                        if (a.playbackControls != null) a.playbackControls.focusPrimaryAction();
                    }
                    return true;
                }
            }
        }
        if (a.isTvDevice()
                && key == KeyEvent.KEYCODE_DPAD_UP
                && a.playbackControls != null
                && a.playbackControls.markers().open(event)) return true;
        boolean down = event.getAction() == KeyEvent.ACTION_DOWN;
        View focus = a.getCurrentFocus();
        boolean horizontal =
                key == KeyEvent.KEYCODE_DPAD_LEFT || key == KeyEvent.KEYCODE_DPAD_RIGHT;
        if (a.seekGesture.active && !horizontal && down)
            finishSeek(a, key != KeyEvent.KEYCODE_BACK);
        boolean confirm = key == KeyEvent.KEYCODE_DPAD_CENTER || key == KeyEvent.KEYCODE_ENTER;
        if (confirm
                && (!a.controlsVisible
                        || focus == a.root
                        || a.playbackControls != null && focus == a.playbackControls.timeline)) {
            if (down && event.getRepeatCount() == 0) {
                boolean wasVisible = a.controlsVisible;
                togglePlayback(a);
                if (shouldShowHudOnPauseToggle(a.isTvDevice(), wasVisible, a.playing)) {
                    showControls(a, true);
                } else {
                    if (wasVisible && !a.playing) {
                        showControls(a, false);
                    } else if (a.playerChrome != null) {
                        a.playerChrome.update();
                    }
                }
            }
            return true;
        }
        if ((!a.controlsVisible || (a.playerChrome != null && a.playerChrome.progressOnlyMode))
                && (key == KeyEvent.KEYCODE_DPAD_UP
                        || key == KeyEvent.KEYCODE_DPAD_DOWN
                        || key == KeyEvent.KEYCODE_MENU)) {
            if (down) {
                showControls(a, true, false);
                if (a.playbackControls != null) a.playbackControls.focusPrimaryAction();
            }
            return true;
        }
        if (a.controlsVisible && key == KeyEvent.KEYCODE_MENU) {
            if (down && event.getRepeatCount() == 0) {
                if (a.playbackControls != null && focus == a.playbackControls.timeline) {
                    a.playbackControls.focusPrimaryAction();
                } else {
                    showControls(a, false);
                }
            }
            return true;
        }
        if (horizontal
                && !a.isLive()
                && (a.seekGesture.active
                        || !a.controlsVisible
                        || focus == a.root
                        || a.playbackControls != null && focus == a.playbackControls.timeline)) {
            int direction = key == KeyEvent.KEYCODE_DPAD_LEFT ? -1 : 1;
            if (down) {
                if (!a.seekGesture.active && event.getRepeatCount() == 0
                        || a.seekGesture.active
                                && a.seekGesture.direction != direction
                                && event.getRepeatCount() == 0) beginSeek(a, direction);
            } else if (event.getAction() == KeyEvent.ACTION_UP
                    && a.seekGesture.active
                    && a.seekGesture.direction == direction) finishSeek(a, !event.isCanceled());
            return true;
        }
        if (key == KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE
                || key == KeyEvent.KEYCODE_MEDIA_PLAY
                || key == KeyEvent.KEYCODE_MEDIA_PAUSE) {
            if (down && event.getRepeatCount() == 0) {
                boolean wasVisible = a.controlsVisible;
                if (key == KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE
                        || (key == KeyEvent.KEYCODE_MEDIA_PLAY && !a.playing)
                        || (key == KeyEvent.KEYCODE_MEDIA_PAUSE && a.playing)) togglePlayback(a);
                if (shouldShowHudOnPauseToggle(a.isTvDevice(), wasVisible, a.playing)) {
                    showControls(a, true);
                } else {
                    if (wasVisible && !a.playing) {
                        showControls(a, false);
                    } else if (a.playerChrome != null) {
                        a.playerChrome.update();
                    }
                }
            }
            return true;
        }
        if (a.controlsVisible && down) scheduleHide(a);
        return false;
    }
}
