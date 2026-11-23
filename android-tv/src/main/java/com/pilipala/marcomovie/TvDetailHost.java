package com.pilipala.marcomovie;

import android.view.View;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Iterator;
import java.util.List;
import java.util.Objects;

/** TV-only bridge to detail loading, curated source resolution, favorites, and bookmark playback. */
final class TvDetailHost {
    static final int CURATED_MAX_SOURCES = 4;
    static final int CURATED_MAX_CONCURRENCY = 1;

    interface Valid {
        boolean get();
    }

    private static final class MatchedSource {
        final Cms.Site site;
        final Cms.Video listing;
        final int score;

        MatchedSource(Cms.Site site, Cms.Video listing, int score) {
            this.site = site;
            this.listing = listing;
            this.score = score;
        }
    }

    static int[] initialSelection(
            Cms.Video video,
            WatchHistory.Entry bookmark,
            String preferred,
            EpisodeSelection saved,
            boolean descending) {
        int line = 0, page = 0;
        if (video == null || video.lines == null || video.lines.isEmpty()) {
            return new int[] {0, 0};
        }
        for (int i = 0; i < video.lines.size(); i++) {
            Cms.Line cand = video.lines.get(i);
            if (cand != null && cand.name != null && cand.name.equals(preferred)) {
                line = i;
                break;
            }
        }
        if (bookmark != null) {
            for (int i = 0; i < video.lines.size(); i++) {
                Cms.Line candidate = video.lines.get(i);
                if (candidate == null
                        || candidate.name == null
                        || !candidate.name.equals(bookmark.line)) continue;
                line = i;
                if (candidate.episodes != null) {
                    int foundIdx = -1;
                    int bmEpNum = TvSeriesScraper.extractEpisodeNumber(bookmark.episode);
                    for (int n = 0; n < candidate.episodes.size(); n++) {
                        Cms.Episode ep = candidate.episodes.get(n);
                        if (ep != null && Objects.equals(ep.name, bookmark.episode)) {
                            foundIdx = n;
                            break;
                        }
                    }
                    if (foundIdx < 0 && bmEpNum > 0) {
                        for (int n = 0; n < candidate.episodes.size(); n++) {
                            Cms.Episode ep = candidate.episodes.get(n);
                            if (ep != null
                                    && TvSeriesScraper.extractEpisodeNumber(ep.name) == bmEpNum) {
                                foundIdx = n;
                                break;
                            }
                        }
                    }
                    if (foundIdx >= 0) {
                        page =
                                (descending ? candidate.episodes.size() - 1 - foundIdx : foundIdx)
                                        / 50;
                    }
                }
                break;
            }
        }
        if (saved != null && saved.selected)
            for (int i = 0; i < video.lines.size(); i++) {
                Cms.Line candidate = video.lines.get(i);
                if (candidate != null
                        && candidate.name != null
                        && candidate.name.equals(saved.line)) {
                    line = i;
                    int epCount = candidate.episodes == null ? 0 : candidate.episodes.size();
                    page = EpisodeSelection.boundPage(saved.page, epCount);
                    break;
                }
            }
        return new int[] {line, page};
    }

    static String formatHistoryCaption(
            MainActivity a, WatchHistory.Entry bookmark, String episodeFileCaption) {
        if (bookmark == null) return "";
        String progress =
                bookmark.complete()
                        ? "已看完"
                        : PlaybackController.formatTime(bookmark.position)
                                + (bookmark.duration > 0
                                        ? " / " + PlaybackController.formatTime(bookmark.duration)
                                        : "");
        String ep = bookmark.episode == null ? "" : bookmark.episode.trim();
        if (!ep.isEmpty() && episodeFileCaption != null && episodeFileCaption.contains(ep)) {
            return "上次观看进度 · " + progress;
        }
        return "上次观看 · " + a.historyLabel(bookmark);
    }

    private static Cms.Episode resolveActiveEpisode(Cms.Line line, WatchHistory.Entry bookmark) {
        if (line == null || line.episodes == null || line.episodes.isEmpty()) return null;
        if (bookmark != null
                && Objects.equals(line.name, bookmark.line)
                && bookmark.episode != null) {
            for (Cms.Episode ep : line.episodes) {
                if (ep != null && bookmark.episode.equals(ep.name)) return ep;
            }
            int bmNum = TvSeriesScraper.extractEpisodeNumber(bookmark.episode);
            if (bmNum > 0) {
                for (Cms.Episode ep : line.episodes) {
                    if (ep != null && TvSeriesScraper.extractEpisodeNumber(ep.name) == bmNum) {
                        return ep;
                    }
                }
            }
        }
        return line.episodes.get(0);
    }

    private static WatchHistory.Entry findBookmark(MainActivity a, Cms.Site site, Cms.Video video) {
        if (a == null || site == null || site.key == null || video == null || video.id == null)
            return null;
        for (WatchHistory.Entry entry : a.watchHistory()) {
            if (entry != null
                    && Objects.equals(site.key, entry.site)
                    && Objects.equals(video.id, entry.id)) {
                return entry;
            }
        }
        return null;
    }

    private static void mergeListingFallback(Cms.Video target, Cms.Video fallback) {
        if (target == null || fallback == null) return;
        if (target.id == null || target.id.trim().isEmpty()) target.id = fallback.id;
        if (target.title == null || target.title.isEmpty()) target.title = fallback.title;
        if (target.poster == null || target.poster.isEmpty()) target.poster = fallback.poster;
        if (target.year == null || target.year.isEmpty()) target.year = fallback.year;
        if (target.area == null || target.area.isEmpty()) target.area = fallback.area;
        if (target.tag == null || target.tag.isEmpty()) target.tag = fallback.tag;
        if (target.remarks == null || target.remarks.isEmpty()) target.remarks = fallback.remarks;
        if (target.doubanScore == null || target.doubanScore.isEmpty()) {
            target.doubanScore = fallback.doubanScore;
        }
        if (target.description == null || target.description.trim().isEmpty()) {
            target.description = fallback.description;
        }
        if (target.actor == null || target.actor.trim().isEmpty()) target.actor = fallback.actor;
        if (target.director == null || target.director.trim().isEmpty()) {
            target.director = fallback.director;
        }
        if (target.lines != null) {
            for (Iterator<Cms.Line> it = target.lines.iterator(); it.hasNext(); ) {
                Cms.Line line = it.next();
                if (line == null || line.episodes == null || line.episodes.isEmpty()) it.remove();
            }
        }
    }

    private static boolean hasPlayableLines(Cms.Video video) {
        if (video == null || video.lines == null) return false;
        for (Cms.Line line : video.lines) {
            if (line != null && line.episodes != null && !line.episodes.isEmpty()) return true;
        }
        return false;
    }

    static String buildEpisodesButtonLabel(Cms.Video video, int lineIdx) {
        if (video == null || video.lines == null || video.lines.isEmpty()) return "☰ 选集";
        Cms.Line line = video.lines.get(Math.max(0, Math.min(lineIdx, video.lines.size() - 1)));
        int epCount = line == null || line.episodes == null ? 0 : line.episodes.size();
        int lineCount = video.lines.size();
        if (epCount <= 1 && lineCount > 1) return "☰ 选线路 (" + lineCount + ")";
        if (epCount > 1 && lineCount > 1) return "☰ 选集与线路 · " + epCount + " 集";
        if (epCount > 1) return "☰ 选集 · " + epCount + " 集";
        return "☰ 线路与片源";
    }

    static void showEpisodesDialog(
            MainActivity a,
            Cms.Site site,
            Cms.Video video,
            int initialLine,
            int initialPage,
            Runnable onDismiss) {
        if (a == null || video == null || video.lines == null || video.lines.isEmpty()) {
            if (a != null) a.toast("该来源没有可播放线路");
            return;
        }
        int safeLine = Math.max(0, Math.min(initialLine, video.lines.size() - 1));
        Cms.Line targetLine = video.lines.get(safeLine);
        int epCount =
                targetLine == null || targetLine.episodes == null ? 0 : targetLine.episodes.size();
        int safePage = EpisodeSelection.boundPage(initialPage, epCount);

        LinearLayout host = a.vertical();
        host.setTag("detail-episodes");
        host.setClipChildren(false);
        host.setClipToPadding(false);
        host.setPadding(a.dp(6), a.dp(6), a.dp(6), a.dp(10));
        if (epCount > 16) {
            host.setMinimumHeight(Math.max(a.dp(280), a.windowHeight() - a.dp(220)));
        }

        DetailScreen.renderEpisodes(a, site, video, safeLine, safePage, host, null);

        AppDialog dialog =
                new AppDialog.Builder(a)
                        .setTitle("选线路与选集")
                        .setWide(true)
                        .setView(host)
                        .setNegativeButton("关闭", null)
                        .create();
        if (onDismiss != null) {
            dialog.setOnDismissListener(d -> onDismiss.run());
        }
        dialog.show();
        View firstEp = host.findViewWithTag("detail-line:" + safeLine);
        if (firstEp != null) firstEp.requestFocus();
    }

    private static void showEpisodesPopup(
            MainActivity a,
            Cms.Site site,
            Cms.Video video,
            WatchHistory.Entry bookmark,
            MainActivity.Screen screen,
            TvV17DetailScreen ui) {
        if (!hasPlayableLines(video)) {
            a.toast("该来源没有可播放线路");
            return;
        }
        int[] selection =
                initialSelection(
                        video,
                        bookmark,
                        a.prefs.getString(Prefs.PREFERRED_LINE, ""),
                        screen.selection,
                        a.prefs.getBoolean(Prefs.EPISODES_DESCENDING, false));
        showEpisodesDialog(
                a,
                site,
                video,
                selection[0],
                selection[1],
                () -> {
                    if (!hasPlayableLines(video)) return;
                    int[] updated =
                            initialSelection(
                                    video,
                                    bookmark,
                                    a.prefs.getString(Prefs.PREFERRED_LINE, ""),
                                    screen.selection,
                                    a.prefs.getBoolean(Prefs.EPISODES_DESCENDING, false));
                    Cms.Line activeLine = video.lines.get(updated[0]);
                    Cms.Episode activeEp = resolveActiveEpisode(activeLine, bookmark);
                    ui.updateEpisodeCaption(
                            TvV17DetailScreen.formatEpisodeFileCaption(activeLine, activeEp),
                            buildEpisodesButtonLabel(video, updated[0]));
                });
    }

    private static void bindSeasonPopupDiscovery(
            MainActivity a, Cms.Site site, Cms.Video video, TvV17DetailScreen ui) {
        if (a == null || site == null || video == null || ui == null) return;
        ui.setSeasonsAction(null, null);
        DetailScreen.discoverTvRelatedSeasons(
                a,
                site,
                video,
                ui.view,
                seasons -> {
                    ui.setDetectedSeasonCount(seasons.count());
                    ui.setSeasonsAction(
                            "☰ 选季 · 共 " + seasons.count() + " 季",
                            () -> DetailScreen.showTvSeasonsPopup(a, site, video, seasons, false));
                });
    }

    static void show(MainActivity a, Cms.Site site, Cms.Video listing, Cms.Video ready) {
        a.renderPage(listing.title == null ? "详情" : listing.title, "");
        final MainActivity.Screen screen = a.current;
        final int ticket = a.generation;
        final TvSearchContext context = new TvSearchContext(a.config, a.privateMode, a.engineEpoch);
        final Valid valid =
                () ->
                        a.current == screen
                                && ticket == a.generation
                                && !a.isFinishing()
                                && context.matches(a.config, a.privateMode, a.engineEpoch);

        final Cms.Video initialVideo = ready != null ? ready : listing;
        mergeListingFallback(initialVideo, listing);
        SeriesScrapeStore.OverrideRecord savedOv =
                SeriesScrapeStore.load(
                        a, site != null ? site.key : "", initialVideo.id, initialVideo.title);
        if (savedOv != null) {
            TvSeriesScrapeDialog.applyOverrideToVideo(initialVideo, savedOv);
        }
        final Cms.Video[] activeVideo = {initialVideo};
        final WatchHistory.Entry[] activeBookmark = {findBookmark(a, site, initialVideo)};
        final boolean initiallyPlayable = hasPlayableLines(initialVideo);

        int[] initSel =
                initiallyPlayable
                        ? initialSelection(
                                initialVideo,
                                activeBookmark[0],
                                a.prefs.getString(Prefs.PREFERRED_LINE, ""),
                                screen.selection,
                                a.prefs.getBoolean(Prefs.EPISODES_DESCENDING, false))
                        : new int[] {0, 0};
        Cms.Line initLine = initiallyPlayable ? initialVideo.lines.get(initSel[0]) : null;
        Cms.Episode initEp = resolveActiveEpisode(initLine, activeBookmark[0]);
        String initFileCaption = TvV17DetailScreen.formatEpisodeFileCaption(initLine, initEp);
        String initHistoryCaption = formatHistoryCaption(a, activeBookmark[0], initFileCaption);
        String initContinueCaption =
                TvV17DetailScreen.formatContinuePlaySubtitle(
                        activeBookmark[0], initFileCaption, initHistoryCaption);
        String initPlayLabel =
                !initiallyPlayable ? "正在获取线路…" : (activeBookmark[0] == null ? "► 开始播放" : "► 继续播放");

        final TvV17DetailScreen[] holder = new TvV17DetailScreen[1];
        TvV17DetailScreen ui =
                new TvV17DetailScreen(
                        a,
                        site,
                        initialVideo,
                        null,
                        Favorites.contains(
                                a.prefs.getString(Prefs.FAVORITES, "[]"),
                                site.key,
                                initialVideo.id),
                        initiallyPlayable,
                        initPlayLabel,
                        buildEpisodesButtonLabel(initialVideo, initSel[0]),
                        !initContinueCaption.isEmpty() ? initContinueCaption : initFileCaption,
                        !initContinueCaption.isEmpty() ? "" : initHistoryCaption,
                        new TvV17DetailScreen.Actions() {
                            public void back() {
                                if (valid.get()) a.onBackPressed();
                            }

                            public void play() {
                                Cms.Video v = activeVideo[0];
                                if (!valid.get() || !hasPlayableLines(v)) return;
                                WatchHistory.Entry bm = activeBookmark[0];
                                int[] sel =
                                        initialSelection(
                                                v,
                                                bm,
                                                a.prefs.getString(Prefs.PREFERRED_LINE, ""),
                                                screen.selection,
                                                a.prefs.getBoolean(
                                                        Prefs.EPISODES_DESCENDING, false));
                                if (bm != null
                                        && (!screen.selection.selected
                                                || Objects.equals(
                                                        v.lines.get(sel[0]).name, bm.line))) {
                                    a.playBookmark(site, v, bm);
                                } else {
                                    Cms.Line line = v.lines.get(sel[0]);
                                    if (line != null
                                            && line.episodes != null
                                            && !line.episodes.isEmpty()) {
                                        a.resolvePlayer(site, v, line, line.episodes.get(0));
                                    }
                                }
                            }

                            public void episodes() {
                                if (!valid.get()) return;
                                showEpisodesPopup(
                                        a,
                                        site,
                                        activeVideo[0],
                                        activeBookmark[0],
                                        screen,
                                        holder[0]);
                            }

                            public void favorite() {
                                if (!valid.get()) return;
                                holder[0].setFavorite(
                                        DetailScreen.toggleFavorite(a, site, activeVideo[0]));
                            }

                            public void synopsis() {
                                if (valid.get())
                                    new AppDialog.Builder(a)
                                            .setTitle(activeVideo[0].title)
                                            .setMessage(
                                                    DetailScreen.buildFullSynopsisMessage(
                                                            activeVideo[0]))
                                            .setPositiveButton("关闭", null)
                                            .show();
                            }
                        });
        holder[0] = ui;
        if (activeBookmark[0] != null) ui.setBookmark(activeBookmark[0]);
        ui.setScrapeAction(
                () -> {
                    if (!valid.get()) return;
                    Cms.Video v = activeVideo[0];
                    int[] sel =
                            hasPlayableLines(v)
                                    ? initialSelection(
                                            v,
                                            activeBookmark[0],
                                            a.prefs.getString(Prefs.PREFERRED_LINE, ""),
                                            screen.selection,
                                            a.prefs.getBoolean(Prefs.EPISODES_DESCENDING, false))
                                    : new int[] {0, 0};
                    Cms.Line curLine = hasPlayableLines(v) ? v.lines.get(sel[0]) : null;
                    TvSeriesScrapeDialog.show(
                            a,
                            site,
                            v,
                            curLine,
                            () -> {
                                if (!valid.get()) return;
                                SeriesScrapeStore.OverrideRecord ov =
                                        SeriesScrapeStore.load(
                                                a, site != null ? site.key : "", v.id, v.title);
                                if (ov != null) TvSeriesScrapeDialog.applyOverrideToVideo(v, ov);
                                Cms.Line updatedLine =
                                        hasPlayableLines(v) ? v.lines.get(sel[0]) : null;
                                Cms.Episode updatedEp =
                                        resolveActiveEpisode(updatedLine, activeBookmark[0]);
                                String fc =
                                        TvV17DetailScreen.formatEpisodeFileCaption(
                                                updatedLine, updatedEp);
                                ui.bindResolvedVideo(
                                        site,
                                        v,
                                        activeBookmark[0],
                                        Favorites.contains(
                                                a.prefs.getString(Prefs.FAVORITES, "[]"),
                                                site != null ? site.key : "",
                                                v.id),
                                        activeBookmark[0] == null ? "► 开始播放" : "► 继续播放",
                                        buildEpisodesButtonLabel(v, sel[0]),
                                        fc,
                                        formatHistoryCaption(a, activeBookmark[0], fc));
                            });
                });

        // Mount immediately so entering detail is instant (zero blank "正在加载影片详情…" screen)
        a.root.removeView(a.scroll);
        a.root.addView(ui.view, new FrameLayout.LayoutParams(-1, -1));
        a.scroll = ui.scroll;
        a.body = ui.content;

        if (!initiallyPlayable) {
            ui.setLoadingStatus("正在获取播放线路…");
            if (screen.focus == null || "detail-back".equals(screen.focus)) {
                screen.focus = "detail-favorite";
            }
        } else {
            bindSeasonPopupDiscovery(a, site, initialVideo, ui);
            if (screen.focus == null || "detail-back".equals(screen.focus)) {
                screen.focus = "detail-play";
            }
        }
        a.restore(screen);

        MainActivity.Done<Cms.Video> bindInPlace =
                resolved -> {
                    if (!valid.get() || resolved == null) return;
                    mergeListingFallback(resolved, listing);
                    SeriesScrapeStore.OverrideRecord ov =
                            SeriesScrapeStore.load(
                                    a, site != null ? site.key : "", resolved.id, resolved.title);
                    if (ov != null) TvSeriesScrapeDialog.applyOverrideToVideo(resolved, ov);
                    activeVideo[0] = resolved;
                    WatchHistory.Entry bm = findBookmark(a, site, resolved);
                    activeBookmark[0] = bm;
                    boolean playable = hasPlayableLines(resolved);
                    int[] sel =
                            playable
                                    ? initialSelection(
                                            resolved,
                                            bm,
                                            a.prefs.getString(Prefs.PREFERRED_LINE, ""),
                                            screen.selection,
                                            a.prefs.getBoolean(Prefs.EPISODES_DESCENDING, false))
                                    : new int[] {0, 0};
                    Cms.Line activeLine = playable ? resolved.lines.get(sel[0]) : null;
                    Cms.Episode activeEpisode = resolveActiveEpisode(activeLine, bm);
                    String fileCap =
                            TvV17DetailScreen.formatEpisodeFileCaption(activeLine, activeEpisode);
                    String histCap = formatHistoryCaption(a, bm, fileCap);
                    ui.bindResolvedVideo(
                            site,
                            resolved,
                            bm,
                            Favorites.contains(
                                    a.prefs.getString(Prefs.FAVORITES, "[]"),
                                    site.key,
                                    resolved.id),
                            bm == null ? "► 开始播放" : "► 继续播放",
                            buildEpisodesButtonLabel(resolved, sel[0]),
                            fileCap,
                            histCap);
                    if (!playable) {
                        WatchHistory.Entry fallbackBm = bm != null ? bm : a.historyFallbackBookmark;
                        if (fallbackBm != null
                                && !a.historyFallbackInFlight
                                && fallbackBm.title != null
                                && !fallbackBm.title.trim().isEmpty()
                                && CatalogScreen.hasAlternativeHistorySources(a, site.key)) {
                            CatalogScreen.resumeHistoryFromAlternativeSources(
                                    a, fallbackBm, site.key, "原片源暂无可播放线路", true);
                            return;
                        }
                        ui.setLoadingStatus("该来源没有返回可播放线路");
                        if (resolved.title != null && !resolved.title.trim().isEmpty()) {
                            ui.setSourceSwitchAction(
                                    "🔍 换其他源", () -> a.openSearch(resolved.title.trim()));
                        }
                    } else {
                        ui.setLoadingStatus("");
                        bindSeasonPopupDiscovery(a, site, resolved, ui);
                        View curFocus = a.getCurrentFocus();
                        if (curFocus == null
                                || curFocus == ui.favorite
                                || curFocus == ui.back
                                || "detail-favorite".equals(screen.focus)
                                || "detail-play".equals(screen.focus)) {
                            screen.focus = "detail-play";
                            ui.play.requestFocus();
                        }
                    }
                };

        MainActivity.Done<Throwable> onDetailError =
                error -> {
                    if (!valid.get()) return;
                    WatchHistory.Entry fallbackBm =
                            activeBookmark[0] != null
                                    ? activeBookmark[0]
                                    : a.historyFallbackBookmark;
                    if (fallbackBm != null
                            && !a.historyFallbackInFlight
                            && fallbackBm.title != null
                            && !fallbackBm.title.trim().isEmpty()
                            && CatalogScreen.hasAlternativeHistorySources(a, site.key)) {
                        CatalogScreen.resumeHistoryFromAlternativeSources(
                                a, fallbackBm, site.key, "原片源加载失败", true);
                        return;
                    }
                    ui.setLoadingStatus(a.message(error));
                    String fallbackTitle =
                            initialVideo.title != null ? initialVideo.title.trim() : "";
                    if (!fallbackTitle.isEmpty()) {
                        ui.setSourceSwitchAction("🔍 全站搜其他源", () -> a.openSearch(fallbackTitle));
                        ui.switchSourceBtn.requestFocus();
                    }
                };

        if (ready != null) {
            try {
                bindInPlace.accept(ready);
            } catch (Exception e) {
                a.notice("详情数据无法显示，请返回后重试。");
            }
        } else if (initiallyPlayable) {
            if (!a.reduced
                    && (listing.description == null || listing.description.trim().isEmpty())) {
                ui.setLoadingStatus("正在补全详情…");
                a.loadDetail(site, listing.id, bindInPlace, onDetailError);
            }
        } else {
            a.loadDetail(site, listing.id, bindInPlace, onDetailError);
        }
    }

    /**
     * Opens a source-independent curated Home recommendation: shows the detail page immediately
     * using metadata + official HD landscape poster while resolving playable lines exclusively from
     * the user's already-added sources.
     */
    static void openCurated(MainActivity a, Cms.Video curated) {
        if (a == null
                || curated == null
                || curated.title == null
                || curated.title.trim().isEmpty()) {
            return;
        }
        List<Cms.Site> sources = collectUserSearchableSites(a);
        if (sources.isEmpty()) {
            new AppDialog.Builder(a)
                    .setTitle("请先添加片源")
                    .setMessage(
                            "首页热门推荐仅展示近期热剧与热门电影信息，不内置播放资源。\n\n添加您自己的片源后，点击《"
                                    + curated.title.trim()
                                    + "》即可自动从已添加片源中匹配播放。")
                    .setPositiveButton("添加片源", (d, w) -> a.importDialog())
                    .setNegativeButton("取消", null)
                    .show();
            return;
        }
        a.open(new MainActivity.Screen(() -> showCurated(a, curated)), true);
    }

    private static boolean isHeavyRuntimeSite(Cms.Site site) {
        if (site == null) return false;
        String api = site.api == null ? "" : site.api;
        return api.startsWith("catpaw://")
                || DrpyEngine.eligible(site)
                || GuardEngine.eligible(site)
                || JsEngine.eligible(site);
    }

    private static boolean isLightweightSite(Cms.Site site) {
        if (site == null) return false;
        String api = site.api == null ? "" : site.api;
        return site.supported()
                || HttpT4Engine.eligible(site)
                || api.startsWith(com.pilipala.emby.EmbyLibrary.PREFIX)
                || api.startsWith(AlistEngine.PREFIX);
    }

    /**
     * Bounds automatic curated-home background matching so low-RAM Android TVs never fan out into
     * 16 simultaneous Node/WebView/CSP plugin runtimes on a single poster click.
     */
    static List<Cms.Site> selectCuratedSearchSources(
            List<Cms.Site> prioritizedSources, String selectedSiteKey, int maxCount) {
        List<Cms.Site> out = new ArrayList<>();
        if (prioritizedSources == null || prioritizedSources.isEmpty() || maxCount <= 0) return out;
        List<Cms.Site> selectedTier = new ArrayList<>();
        List<Cms.Site> lightTier = new ArrayList<>();
        List<Cms.Site> standardTier = new ArrayList<>();
        List<Cms.Site> heavyFallbackTier = new ArrayList<>();
        for (Cms.Site site : prioritizedSources) {
            if (site == null || site.key == null) continue;
            if (SearchCoordinator.isSiteWedged(site.key)) continue;
            boolean isSelected = selectedSiteKey != null && selectedSiteKey.equals(site.key);
            if (isSelected) {
                selectedTier.add(site);
            } else if (isLightweightSite(site)) {
                lightTier.add(site);
            } else if (isHeavyRuntimeSite(site)) {
                heavyFallbackTier.add(site);
            } else {
                standardTier.add(site);
            }
        }
        for (Cms.Site s : selectedTier) {
            if (out.size() < maxCount) out.add(s);
        }
        for (Cms.Site s : lightTier) {
            if (out.size() < maxCount) out.add(s);
        }
        for (Cms.Site s : standardTier) {
            if (out.size() < maxCount) out.add(s);
        }
        if (out.isEmpty() && !heavyFallbackTier.isEmpty()) {
            out.add(heavyFallbackTier.get(0));
        }
        return out;
    }

    private static List<Cms.Site> collectUserSearchableSites(MainActivity a) {
        List<Cms.Site> sources = new ArrayList<>();
        if (a == null || a.config == null || a.config.sites == null) return sources;
        for (Cms.Site site : SourcePreferences.prioritized(a, a.config.sites)) {
            if (site == null || !site.searchable || !a.available(site)) continue;
            if (SourceController.isConfigOrNetdiskSite(site)) continue;
            sources.add(site);
        }
        final String selected = a.prefs.getString(Prefs.SELECTED_SITE, "");
        Collections.sort(
                sources,
                (x, y) ->
                        Boolean.compare(
                                !Objects.equals(x.key, selected),
                                !Objects.equals(y.key, selected)));
        return sources;
    }

    private static void showCurated(MainActivity a, Cms.Video curated) {
        final String query = curated.title == null ? "" : curated.title.trim();
        a.renderPage(query.isEmpty() ? "热门推荐" : query, "");
        final MainActivity.Screen screen = a.current;
        final int ticket = a.generation;
        final TvSearchContext context = new TvSearchContext(a.config, a.privateMode, a.engineEpoch);
        final Valid valid =
                () ->
                        a.current == screen
                                && ticket == a.generation
                                && !a.isFinishing()
                                && context.matches(a.config, a.privateMode, a.engineEpoch);

        final List<Cms.Site> allSources = collectUserSearchableSites(a);
        final String selectedKey = a.prefs.getString(Prefs.SELECTED_SITE, "");
        final List<Cms.Site> targetSources =
                selectCuratedSearchSources(allSources, selectedKey, CURATED_MAX_SOURCES);

        final Cms.Site[] activeSite = {TvCuratedHome.curatedSite()};
        final Cms.Video[] activeVideo = {curated};
        final WatchHistory.Entry[] activeBookmark = {null};
        final List<MatchedSource> matches = new ArrayList<>();
        final boolean[] detailBound = {false};
        final boolean[] detailLoading = {false};
        final int[] finishedCount = {0};
        final SearchCoordinator[] coordinatorRef = new SearchCoordinator[1];
        final Runnable closeCoordinator =
                () -> {
                    SearchCoordinator c = coordinatorRef[0];
                    if (c != null) c.close();
                };

        final Cms.Site primarySource = targetSources.isEmpty() ? null : targetSources.get(0);
        final List<Cms.Site> fallbackSources =
                targetSources.size() > 1
                        ? new ArrayList<>(targetSources.subList(1, targetSources.size()))
                        : Collections.emptyList();
        final boolean[] fallbackStarted = {false};
        final Runnable[] startFallbackSearchRef = new Runnable[1];

        final TvV17DetailScreen[] holder = new TvV17DetailScreen[1];
        final Runnable[] openSourcePickerRef = new Runnable[1];

        TvV17DetailScreen ui =
                new TvV17DetailScreen(
                        a,
                        activeSite[0],
                        curated,
                        null,
                        false,
                        false,
                        "正在匹配片源…",
                        "☰ 选集",
                        "",
                        "",
                        new TvV17DetailScreen.Actions() {
                            public void back() {
                                closeCoordinator.run();
                                if (valid.get()) a.onBackPressed();
                            }

                            public void play() {
                                closeCoordinator.run();
                                Cms.Video v = activeVideo[0];
                                Cms.Site s = activeSite[0];
                                if (!valid.get()
                                        || TvCuratedHome.isCuratedSite(s)
                                        || !hasPlayableLines(v)) {
                                    return;
                                }
                                WatchHistory.Entry bm = activeBookmark[0];
                                int[] sel =
                                        initialSelection(
                                                v,
                                                bm,
                                                a.prefs.getString(Prefs.PREFERRED_LINE, ""),
                                                screen.selection,
                                                a.prefs.getBoolean(
                                                        Prefs.EPISODES_DESCENDING, false));
                                if (bm != null
                                        && (!screen.selection.selected
                                                || Objects.equals(
                                                        v.lines.get(sel[0]).name, bm.line))) {
                                    a.playBookmark(s, v, bm);
                                } else {
                                    Cms.Line line = v.lines.get(sel[0]);
                                    if (line != null
                                            && line.episodes != null
                                            && !line.episodes.isEmpty()) {
                                        a.resolvePlayer(s, v, line, line.episodes.get(0));
                                    }
                                }
                            }

                            public void episodes() {
                                closeCoordinator.run();
                                if (!valid.get() || TvCuratedHome.isCuratedSite(activeSite[0])) {
                                    return;
                                }
                                showEpisodesPopup(
                                        a,
                                        activeSite[0],
                                        activeVideo[0],
                                        activeBookmark[0],
                                        screen,
                                        holder[0]);
                            }

                            public void favorite() {
                                if (!valid.get()) return;
                                if (TvCuratedHome.isCuratedSite(activeSite[0])) {
                                    a.toast("正在匹配可播放片源，稍后即可收藏");
                                    return;
                                }
                                holder[0].setFavorite(
                                        DetailScreen.toggleFavorite(
                                                a, activeSite[0], activeVideo[0]));
                            }

                            public void synopsis() {
                                if (valid.get()) {
                                    new AppDialog.Builder(a)
                                            .setTitle(activeVideo[0].title)
                                            .setMessage(
                                                    DetailScreen.buildFullSynopsisMessage(
                                                            activeVideo[0]))
                                            .setPositiveButton("关闭", null)
                                            .show();
                                }
                            }
                        });
        holder[0] = ui;
        ui.setScrapeAction(
                () -> {
                    if (!valid.get() || TvCuratedHome.isCuratedSite(activeSite[0])) {
                        a.toast("正在匹配可播放片源，稍后即可刮削剧集");
                        return;
                    }
                    Cms.Video v = activeVideo[0];
                    Cms.Line curLine = hasPlayableLines(v) ? v.lines.get(0) : null;
                    TvSeriesScrapeDialog.show(
                            a,
                            activeSite[0],
                            v,
                            curLine,
                            () -> {
                                if (!valid.get()) return;
                                SeriesScrapeStore.OverrideRecord ov =
                                        SeriesScrapeStore.load(
                                                a,
                                                activeSite[0] != null ? activeSite[0].key : "",
                                                v.id,
                                                v.title);
                                if (ov != null) TvSeriesScrapeDialog.applyOverrideToVideo(v, ov);
                                ui.bindResolvedVideo(
                                        activeSite[0],
                                        v,
                                        activeBookmark[0],
                                        Favorites.contains(
                                                a.prefs.getString(Prefs.FAVORITES, "[]"),
                                                activeSite[0].key,
                                                v.id),
                                        activeBookmark[0] == null ? "► 开始播放" : "► 继续播放",
                                        buildEpisodesButtonLabel(v, 0),
                                        TvV17DetailScreen.formatEpisodeFileCaption(
                                                curLine,
                                                resolveActiveEpisode(curLine, activeBookmark[0])),
                                        "");
                            });
                });
        ui.setLoadingStatus(
                primarySource != null ? ("正在从「" + primarySource.name + "」匹配资源…") : "正在匹配片源…");
        ui.setSourceSwitchAction(
                "🔍 全站搜索",
                () -> {
                    closeCoordinator.run();
                    a.openSearch(query);
                });

        a.root.removeView(a.scroll);
        a.root.addView(ui.view, new FrameLayout.LayoutParams(-1, -1));
        a.scroll = ui.scroll;
        a.body = ui.content;
        screen.focus = "detail-switch-source";
        a.restore(screen);

        final MainActivity.Done<MatchedSource> loadMatched =
                new MainActivity.Done<MatchedSource>() {
                    @Override
                    public void accept(MatchedSource picked) {
                        if (!valid.get() || picked == null) return;
                        detailLoading[0] = true;
                        ui.setLoadingStatus("正在从「" + picked.site.name + "」加载播放线路…");
                        MainActivity.Done<Cms.Video> applyLoaded =
                                loaded -> {
                                    if (!valid.get() || loaded == null) return;
                                    detailLoading[0] = false;
                                    mergeListingFallback(loaded, picked.listing);
                                    mergeListingFallback(loaded, curated);
                                    if (!hasPlayableLines(loaded)) {
                                        // Find next matched source safely without mutating during
                                        // loop
                                        MatchedSource nextAlt = null;
                                        for (MatchedSource alt : matches) {
                                            if (alt != picked
                                                    && !Objects.equals(
                                                            alt.site.key, picked.site.key)) {
                                                nextAlt = alt;
                                                break;
                                            }
                                        }
                                        matches.remove(picked);
                                        if (nextAlt != null) {
                                            accept(nextAlt);
                                            return;
                                        }
                                        if (!detailBound[0]) {
                                            if (!fallbackStarted[0]
                                                    && startFallbackSearchRef[0] != null) {
                                                startFallbackSearchRef[0].run();
                                                return;
                                            }
                                            ui.setLoadingStatus("已匹配片源暂无可播放线路，可点击「全站搜索」查找更多来源");
                                        }
                                        return;
                                    }
                                    detailBound[0] = true;
                                    closeCoordinator.run();
                                    activeSite[0] = picked.site;
                                    activeVideo[0] = loaded;
                                    WatchHistory.Entry bm = findBookmark(a, picked.site, loaded);
                                    activeBookmark[0] = bm;
                                    int[] sel =
                                            initialSelection(
                                                    loaded,
                                                    bm,
                                                    a.prefs.getString(Prefs.PREFERRED_LINE, ""),
                                                    screen.selection,
                                                    a.prefs.getBoolean(
                                                            Prefs.EPISODES_DESCENDING, false));
                                    Cms.Line line = loaded.lines.get(sel[0]);
                                    Cms.Episode ep = resolveActiveEpisode(line, bm);
                                    String fileCap =
                                            TvV17DetailScreen.formatEpisodeFileCaption(line, ep);
                                    String histCap = formatHistoryCaption(a, bm, fileCap);
                                    ui.bindResolvedVideo(
                                            picked.site,
                                            loaded,
                                            bm,
                                            Favorites.contains(
                                                    a.prefs.getString(Prefs.FAVORITES, "[]"),
                                                    picked.site.key,
                                                    loaded.id),
                                            bm == null ? "► 开始播放" : "► 继续播放",
                                            buildEpisodesButtonLabel(loaded, sel[0]),
                                            fileCap,
                                            histCap);
                                    ui.setLoadingStatus("");
                                    if (matches.size() > 1 && openSourcePickerRef[0] != null) {
                                        ui.setSourceSwitchAction(
                                                "⇄ 切换来源 (" + matches.size() + ")",
                                                openSourcePickerRef[0]);
                                    } else {
                                        ui.setSourceSwitchAction(
                                                "🔍 更多来源",
                                                () -> {
                                                    closeCoordinator.run();
                                                    a.openSearch(query);
                                                });
                                    }
                                    bindSeasonPopupDiscovery(a, picked.site, loaded, ui);
                                    screen.focus = "detail-play";
                                    ui.play.requestFocus();
                                };
                        if (hasPlayableLines(picked.listing)) {
                            try {
                                applyLoaded.accept(picked.listing);
                            } catch (Exception ignored) {
                            }
                        } else {
                            a.loadDetail(picked.site, picked.listing.id, applyLoaded);
                        }
                    }
                };
        final Runnable[] triggerLoadMatched = new Runnable[1];
        final MatchedSource[] pendingPick = new MatchedSource[1];
        triggerLoadMatched[0] =
                () -> {
                    try {
                        loadMatched.accept(pendingPick[0]);
                    } catch (Exception ignored) {
                    }
                };

        openSourcePickerRef[0] =
                () -> {
                    closeCoordinator.run();
                    if (!valid.get() || matches.isEmpty()) {
                        a.openSearch(query);
                        return;
                    }
                    String[] labels = new String[matches.size() + 1];
                    for (int i = 0; i < matches.size(); i++) {
                        MatchedSource m = matches.get(i);
                        String activeMark =
                                Objects.equals(m.site.key, activeSite[0].key) ? "（当前）" : "";
                        String remark =
                                m.listing.remarks != null && !m.listing.remarks.trim().isEmpty()
                                        ? " · " + m.listing.remarks.trim()
                                        : "";
                        labels[i] = m.site.name + activeMark + remark;
                    }
                    labels[matches.size()] = "🔍 前往全站搜索查看更多来源";
                    new AppDialog.Builder(a)
                            .setTitle("选择已添加片源")
                            .setItems(
                                    labels,
                                    (d, which) -> {
                                        if (which >= 0 && which < matches.size()) {
                                            pendingPick[0] = matches.get(which);
                                            triggerLoadMatched[0].run();
                                        } else {
                                            a.openSearch(query);
                                        }
                                    })
                            .setNegativeButton("取消", null)
                            .show();
                };

        if (primarySource == null) {
            ui.play.setText("暂未匹配片源");
            ui.setLoadingStatus("当前可用片源繁忙，可点击「全站搜索」手动查找");
            ui.setSourceSwitchAction("🔍 全站搜索", () -> a.openSearch(query));
            ui.switchSourceBtn.requestFocus();
            return;
        }
        ui.view.addOnAttachStateChangeListener(
                new View.OnAttachStateChangeListener() {
                    @Override
                    public void onViewAttachedToWindow(View v) {}

                    @Override
                    public void onViewDetachedFromWindow(View v) {
                        closeCoordinator.run();
                    }
                });

        startFallbackSearchRef[0] =
                () -> {
                    if (!valid.get() || detailBound[0] || fallbackStarted[0]) return;
                    fallbackStarted[0] = true;
                    if (fallbackSources.isEmpty()) {
                        ui.play.setText("暂未匹配片源");
                        ui.setLoadingStatus("已添加的片源中暂未找到《" + query + "》，可点击「全站搜索」手动查找");
                        ui.setSourceSwitchAction("🔍 全站搜索", () -> a.openSearch(query));
                        ui.switchSourceBtn.requestFocus();
                        return;
                    }
                    ui.setLoadingStatus("正在从其余 " + fallbackSources.size() + " 个常用片源依次匹配…");
                    SearchCoordinator.configureThreads(a.prefs.getInt(Prefs.SEARCH_THREADS, 6));
                    final SearchCoordinator coordinator =
                            new SearchCoordinator(
                                    (site, q) -> {
                                        SourceEngine eng =
                                                SourceController.engine(a, site, context);
                                        return Cms.listing(eng.search(q, 1)).videos;
                                    },
                                    (site, videos, outcome) ->
                                            a.ui.post(
                                                    () -> {
                                                        if (!valid.get() || detailBound[0]) return;
                                                        finishedCount[0]++;
                                                        if (videos != null && !videos.isEmpty()) {
                                                            Cms.Video bestCand = null;
                                                            int bestScore = 39;
                                                            for (Cms.Video cand : videos) {
                                                                int sc =
                                                                        TvCuratedHome
                                                                                .scoreSourceMatch(
                                                                                        curated,
                                                                                        cand);
                                                                if (sc > bestScore) {
                                                                    bestScore = sc;
                                                                    bestCand = cand;
                                                                }
                                                            }
                                                            if (bestCand != null) {
                                                                matches.add(
                                                                        new MatchedSource(
                                                                                site, bestCand,
                                                                                bestScore));
                                                                Collections.sort(
                                                                        matches,
                                                                        (x, y) ->
                                                                                Integer.compare(
                                                                                        y.score,
                                                                                        x.score));
                                                                if (!detailBound[0]
                                                                        && !detailLoading[0]) {
                                                                    pendingPick[0] = matches.get(0);
                                                                    triggerLoadMatched[0].run();
                                                                    return;
                                                                }
                                                            }
                                                        }
                                                        if (!detailBound[0]
                                                                && !detailLoading[0]
                                                                && finishedCount[0]
                                                                        >= fallbackSources.size()) {
                                                            if (!matches.isEmpty()) {
                                                                pendingPick[0] = matches.get(0);
                                                                triggerLoadMatched[0].run();
                                                            } else {
                                                                ui.play.setText("暂未匹配片源");
                                                                ui.setLoadingStatus(
                                                                        "已添加的片源中暂未找到《"
                                                                                + query
                                                                                + "》，可点击「全站搜索」手动查找");
                                                                ui.setSourceSwitchAction(
                                                                        "🔍 全站搜索",
                                                                        () -> a.openSearch(query));
                                                                ui.switchSourceBtn.requestFocus();
                                                            }
                                                        }
                                                    }),
                                    6000,
                                    14000,
                                    8,
                                    CURATED_MAX_CONCURRENCY);
                    coordinatorRef[0] = coordinator;
                    coordinator.start(fallbackSources, query);
                };

        // Phase 1: Search ONLY the user's primary/selected source first so clicking a show on
        // low-RAM TVs never fans out into extra spider JARs / Node / WebView runtimes
        // unnecessarily.
        a.submitPage(
                () -> {
                    Cms.Video bestCand = null;
                    int bestScore = 39;
                    try {
                        SourceEngine eng = SourceController.engine(a, primarySource, context);
                        List<Cms.Video> videos = Cms.listing(eng.search(query, 1)).videos;
                        if (videos != null) {
                            for (Cms.Video cand : videos) {
                                int sc = TvCuratedHome.scoreSourceMatch(curated, cand);
                                if (sc > bestScore) {
                                    bestScore = sc;
                                    bestCand = cand;
                                }
                            }
                        }
                    } catch (Throwable ignored) {
                    }
                    final Cms.Video found = bestCand;
                    final int foundScore = bestScore;
                    a.ui.post(
                            () -> {
                                if (!valid.get() || detailBound[0]) return;
                                if (found != null) {
                                    MatchedSource picked =
                                            new MatchedSource(primarySource, found, foundScore);
                                    matches.add(picked);
                                    pendingPick[0] = picked;
                                    triggerLoadMatched[0].run();
                                } else {
                                    startFallbackSearchRef[0].run();
                                }
                            });
                });
    }
}
