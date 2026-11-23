package com.pilipala.marcomovie;

import android.view.Gravity;
import android.view.KeyEvent;
import android.view.View;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.TextView;
import java.io.IOException;
import java.util.List;

/**
 * Live TV source/group/channel browsing, HD multi-source aggregation, udpxy multicast rewrite,
 * Emby Live TV, XMLTV EPG/Catchup, numeric keypad overlay, and remote key bindings.
 */
final class LiveController {
    private static final long CATALOG_CACHE_TTL_MS = 15L * 60L * 1000L;
    private static final java.util.Map<String, CachedCatalog> CATALOG_CACHE =
            new java.util.LinkedHashMap<String, CachedCatalog>(8, 0.75f, true) {
                @Override
                protected boolean removeEldestEntry(
                        java.util.Map.Entry<String, CachedCatalog> eldest) {
                    return size() > 6;
                }
            };

    private static final class CachedCatalog {
        final LiveCatalog.Catalog catalog;
        final LiveEpgService.Guide guide;
        final long loadedAtMs;

        CachedCatalog(LiveCatalog.Catalog catalog, LiveEpgService.Guide guide, long loadedAtMs) {
            this.catalog = catalog;
            this.guide = guide;
            this.loadedAtMs = loadedAtMs;
        }
    }

    private LiveController() {}

    static void clearCatalogCache() {
        synchronized (CATALOG_CACHE) {
            CATALOG_CACHE.clear();
        }
    }

    private static String catalogCacheKey(MainActivity a, LiveCatalog.Source source) {
        String url = source != null && source.url != null ? source.url : "";
        String udpxy =
                a != null && a.prefs != null ? a.prefs.getString(Prefs.LIVE_UDPXY_URL, "") : "";
        boolean preferHq =
                a == null || a.prefs == null || a.prefs.getBoolean(Prefs.LIVE_HIGH_QUALITY, true);
        String epg = a != null && a.prefs != null ? a.prefs.getString(Prefs.LIVE_EPG_URL, "") : "";
        int epoch = a != null ? a.engineEpoch : 0;
        return epoch + "|" + url + "|" + udpxy + "|" + preferHq + "|" + epg;
    }

    static LiveCatalog.Catalog peekCachedCatalog(MainActivity a, LiveCatalog.Source source) {
        if (source == null) return null;
        String key = catalogCacheKey(a, source);
        synchronized (CATALOG_CACHE) {
            CachedCatalog entry = CATALOG_CACHE.get(key);
            if (entry != null
                    && (System.currentTimeMillis() - entry.loadedAtMs) <= CATALOG_CACHE_TTL_MS) {
                return entry.catalog;
            }
        }
        return null;
    }

    static LiveEpgService.Guide peekCachedGuide(MainActivity a, LiveCatalog.Source source) {
        if (source == null) return null;
        String key = catalogCacheKey(a, source);
        synchronized (CATALOG_CACHE) {
            CachedCatalog entry = CATALOG_CACHE.get(key);
            if (entry != null
                    && (System.currentTimeMillis() - entry.loadedAtMs) <= CATALOG_CACHE_TTL_MS) {
                return entry.guide;
            }
        }
        return null;
    }

    static List<LiveCatalog.Source> rawSourcesFor(MainActivity a) {
        if (a == null) return java.util.Collections.emptyList();
        String raw = a.config != null ? a.config.raw : "";
        String origin =
                a.config != null && a.config.origin != null && !a.config.origin.isEmpty()
                        ? a.config.origin
                        : a.configOrigin;
        String customJson = a.prefs != null ? a.prefs.getString(Prefs.LIVE_SOURCES_JSON, "") : "";
        String customUrl = a.prefs != null ? a.prefs.getString(Prefs.LIVE_URL, "") : "";
        String customName = a.prefs != null ? a.prefs.getString(Prefs.LIVE_NAME, "自定义直播源") : "";
        List<LiveCatalog.Source> out =
                new java.util.ArrayList<>(
                        LiveCatalog.sourcesFor(raw, origin, customJson, customUrl, customName));
        if (a.config != null && a.config.sites != null) {
            java.util.Set<String> seenEmby = new java.util.HashSet<>();
            int insertPos = 0;
            for (Cms.Site site : a.config.sites) {
                if (site == null
                        || site.api == null
                        || !site.api.startsWith(com.pilipala.emby.EmbyLibrary.PREFIX)) continue;
                String acct =
                        site.api.substring(com.pilipala.emby.EmbyLibrary.PREFIX.length()).trim();
                if (acct.isEmpty() || !seenEmby.add(acct)) continue;
                LiveCatalog.Source embyLive = new LiveCatalog.Source();
                embyLive.name =
                        (site.name == null || site.name.trim().isEmpty()
                                        ? "Emby"
                                        : site.name.trim())
                                + " · 直播";
                embyLive.url = com.pilipala.emby.EmbyLibrary.LIVE_CATALOG_PREFIX + acct;
                embyLive.origin = embyLive.url;
                out.add(insertPos++, embyLive);
            }
        }
        return out;
    }

    static List<LiveCatalog.Source> sourcesFor(MainActivity a) {
        List<LiveCatalog.Source> base = rawSourcesFor(a);
        if (base.size() <= 1
                || a.prefs == null
                || !a.prefs.getBoolean(Prefs.LIVE_MERGE_SOURCES, true)) {
            return base;
        }
        List<LiveCatalog.Source> out = new java.util.ArrayList<>(base.size() + 1);
        LiveCatalog.Source merged = new LiveCatalog.Source();
        merged.name = LiveQualityPolicy.MERGED_SOURCE_NAME;
        merged.url = LiveQualityPolicy.MERGED_SOURCE_URL;
        merged.origin = LiveQualityPolicy.MERGED_SOURCE_URL;
        out.add(merged);
        out.addAll(base);
        return out;
    }

    static String[] streamLabelsFor(MainActivity a, LiveCatalog.Channel channel) {
        if (channel == null || channel.streams.isEmpty()) return new String[0];
        String udpxy =
                a != null && a.prefs != null ? a.prefs.getString(Prefs.LIVE_UDPXY_URL, "") : "";
        java.util.Map<String, LiveQualityPolicy.Metrics> metrics =
                LiveQualityPolicy.parseMetrics(
                        a != null && a.prefs != null
                                ? a.prefs.getString(Prefs.LIVE_STREAM_METRICS, "")
                                : "");
        String[] names = new String[channel.streams.size()];
        for (int n = 0; n < names.length; n++) {
            names[n] =
                    LiveQualityPolicy.formatStreamDisplayLabel(
                            n, channel.streams.get(n), udpxy, metrics);
        }
        return names;
    }

    static void liveSources(MainActivity a) {
        if (a.isTvDevice()) {
            new TvV17LiveScreen(a).show();
            return;
        }
        a.renderPage("直播", "LIVE TV");
        LinearLayout actions = a.row();
        a.addButton(
                actions,
                a.button(
                        "＋ 导入直播源 (M3U / TXT / JSON)",
                        "live-import",
                        () -> SourceController.showLiveImportDialog(a)));
        a.body.addView(actions);
        a.gap(a.body, 10);
        try {
            List<LiveCatalog.Source> sources = sourcesFor(a);
            if (sources.isEmpty()) {
                a.paragraph("当前没有直播频道列表。可点击上方「＋ 导入直播源」导入 M3U、TXT 或 JSON 直播源。");
                return;
            }
            int cols = 3;
            LinearLayout row = null;
            for (int i = 0; i < sources.size(); i++) {
                if (i % cols == 0) {
                    row = a.row();
                    LinearLayout.LayoutParams rlp = new LinearLayout.LayoutParams(-1, -2);
                    rlp.bottomMargin = a.dp(10);
                    a.body.addView(row, rlp);
                }
                LiveCatalog.Source source = sources.get(i);
                TextView btn =
                        a.button(
                                source.name,
                                "live-source:" + source.name,
                                () ->
                                        a.open(
                                                new MainActivity.Screen(
                                                        () -> liveGroups(a, source)),
                                                true));
                LinearLayout.LayoutParams blp = new LinearLayout.LayoutParams(0, -2, 1f);
                if (i % cols != cols - 1) blp.rightMargin = a.dp(10);
                row.addView(btn, blp);
            }
        } catch (Exception e) {
            AppLog.w("LiveController", "parse live sources failed", e);
            a.paragraph("无法读取直播配置。");
        }
    }

    static void liveGroups(MainActivity a, LiveCatalog.Source source) {
        a.renderPage(source.name, "LIVE CHANNELS");
        a.load(
                "读取频道分组…",
                () -> loadCatalog(a, source),
                catalog -> {
                    a.liveSession = new LiveSession(source, catalog);
                    a.paragraph(catalog.channelCount() + " 个频道 · 选择分组");
                    int cols = 4;
                    LinearLayout row = null;
                    for (int i = 0; i < catalog.groups.size(); i++) {
                        if (i % cols == 0) {
                            row = a.row();
                            LinearLayout.LayoutParams rlp = new LinearLayout.LayoutParams(-1, -2);
                            rlp.bottomMargin = a.dp(10);
                            a.body.addView(row, rlp);
                        }
                        LiveCatalog.Group group = catalog.groups.get(i);
                        TextView btn =
                                a.button(
                                        group.name + "  ·  " + group.channels.size(),
                                        "group:" + group.name,
                                        () ->
                                                a.open(
                                                        new MainActivity.Screen(
                                                                () ->
                                                                        liveChannels(
                                                                                a, source, group,
                                                                                0)),
                                                        true));
                        LinearLayout.LayoutParams blp = new LinearLayout.LayoutParams(0, -2, 1f);
                        if (i % cols != cols - 1) blp.rightMargin = a.dp(10);
                        row.addView(btn, blp);
                    }
                });
    }

    private static LiveCatalog.Catalog loadSingleCatalog(MainActivity a, LiveCatalog.Source source)
            throws Exception {
        if (source != null
                && source.url != null
                && source.url.startsWith(com.pilipala.emby.EmbyLibrary.LIVE_CATALOG_PREFIX)) {
            return loadEmbyLiveCatalog(a, source.url);
        }
        LiveCatalog.Source effective = source.copy();
        if (effective.plugin != null || effective.isLocalProxy()) {
            if (!a.prefs.getBoolean(Prefs.EXPERIMENTAL_CSP, true))
                throw new IOException("请先启用来源扩展");
            a.ensureProxy(a.config);
            if (effective.plugin == null) effective.url = LocalProxy.rewrite(effective.url);
        }
        return LiveCatalog.load(effective, (site, url) -> a.engine(site).liveContent(url));
    }

    private static LiveCatalog.Catalog loadEmbyLiveCatalog(MainActivity a, String catalogUrl)
            throws Exception {
        String acct = com.pilipala.emby.EmbyLibrary.parseLiveAccount(catalogUrl);
        if (acct.isEmpty()) throw new IOException("Emby 直播账户标识无效");
        com.pilipala.emby.EmbyLibrary lib =
                com.pilipala.emby.EmbyAccounts.open(a, com.pilipala.emby.EmbyLibrary.PREFIX + acct);
        org.json.JSONArray rows = lib.liveChannels();
        if (rows.length() == 0) throw new IOException("该 Emby 服务器未配置电视直播频道");
        LiveCatalog.Catalog cat = new LiveCatalog.Catalog();
        cat.origin = catalogUrl;
        java.util.Map<String, LiveCatalog.Group> groupMap = new java.util.LinkedHashMap<>();
        for (int i = 0; i < rows.length(); i++) {
            org.json.JSONObject row = rows.optJSONObject(i);
            if (row == null) continue;
            LiveCatalog.Channel ch = new LiveCatalog.Channel();
            ch.id = row.optString("id", "");
            ch.name = row.optString("name", "频道 " + (i + 1));
            ch.logo = row.optString("logo", "");
            String epg = row.optString("epg", "").trim();
            if (!epg.isEmpty()) ch.options.put("epg", epg);
            String num = row.optString("number", "").trim();
            if (!num.isEmpty()) ch.options.put("number", num);
            LiveCatalog.Stream s = new LiveCatalog.Stream();
            s.url = row.optString("url", "");
            s.label = "Emby直连";
            if (s.url.isEmpty()) continue;
            ch.streams.add(s);
            String rawGroup = row.optString("group", "").trim();
            String canon = LiveQualityPolicy.canonicalChannelName(ch.name);
            String grpName =
                    LiveQualityPolicy.standardGroupForChannel(
                            canon, rawGroup.isEmpty() ? "Emby 直播" : rawGroup);
            LiveCatalog.Group grp = groupMap.get(grpName);
            if (grp == null) {
                grp = new LiveCatalog.Group();
                grp.name = grpName;
                groupMap.put(grpName, grp);
            }
            grp.channels.add(ch);
        }
        cat.groups.addAll(groupMap.values());
        if (cat.channelCount() == 0) throw new IOException("未能读取到有效的 Emby 直播频道");
        return cat;
    }

    static LiveCatalog.Catalog loadCatalog(MainActivity a, LiveCatalog.Source source)
            throws Exception {
        return loadCatalog(a, source, false);
    }

    static LiveCatalog.Catalog loadCatalog(
            MainActivity a, LiveCatalog.Source source, boolean forceRefresh) throws Exception {
        if (!forceRefresh) {
            LiveCatalog.Catalog cached = peekCachedCatalog(a, source);
            if (cached != null) return cached;
        }
        String udpxy = a.prefs != null ? a.prefs.getString(Prefs.LIVE_UDPXY_URL, "") : "";
        boolean preferHq = a.prefs == null || a.prefs.getBoolean(Prefs.LIVE_HIGH_QUALITY, true);
        boolean hasIpv6 = LiveQualityPolicy.hasGlobalIpv6Connectivity();
        java.util.Map<String, LiveQualityPolicy.Metrics> metrics =
                LiveQualityPolicy.parseMetrics(
                        a.prefs != null ? a.prefs.getString(Prefs.LIVE_STREAM_METRICS, "") : "");
        if (source != null && LiveQualityPolicy.MERGED_SOURCE_URL.equals(source.url)) {
            List<LiveCatalog.Source> all = rawSourcesFor(a);
            int cap = Math.min(all.size(), 6);
            final LiveCatalog.Catalog[] results = new LiveCatalog.Catalog[cap];
            final Exception[] firstError = {null};
            Thread[] workers = new Thread[cap];
            for (int i = 0; i < cap; i++) {
                final int idx = i;
                final LiveCatalog.Source item = all.get(i);
                workers[i] =
                        new Thread(
                                () -> {
                                    try {
                                        LiveCatalog.Source bounded = item.copy();
                                        bounded.timeoutMs = Math.min(bounded.timeoutMs, 8000);
                                        results[idx] = loadSingleCatalog(a, bounded);
                                    } catch (Exception ex) {
                                        synchronized (firstError) {
                                            if (firstError[0] == null) firstError[0] = ex;
                                        }
                                    }
                                },
                                "live-merge-" + i);
                workers[i].setDaemon(true);
                workers[i].start();
            }
            for (int i = 0; i < cap; i++) {
                try {
                    workers[i].join(8500);
                } catch (InterruptedException e) {
                    Thread.currentThread().interrupt();
                    break;
                }
            }
            List<LiveQualityPolicy.NamedCatalog> loaded = new java.util.ArrayList<>();
            for (int i = 0; i < cap; i++) {
                if (results[i] != null && results[i].channelCount() > 0) {
                    loaded.add(new LiveQualityPolicy.NamedCatalog(all.get(i).name, results[i]));
                }
            }
            if (loaded.isEmpty()) {
                if (firstError[0] != null) throw firstError[0];
                throw new IOException("未能从任何直播源读取到有效频道");
            }
            LiveCatalog.Catalog merged =
                    LiveQualityPolicy.mergeCatalogs(loaded, udpxy, hasIpv6, metrics, preferHq);
            LiveEpgService.Guide guide = enrichCatalogWithEpg(a, merged);
            synchronized (CATALOG_CACHE) {
                CATALOG_CACHE.put(
                        catalogCacheKey(a, source),
                        new CachedCatalog(merged, guide, System.currentTimeMillis()));
            }
            return merged;
        }
        LiveCatalog.Catalog single = loadSingleCatalog(a, source);
        LiveQualityPolicy.rankCatalogInPlace(single, udpxy, hasIpv6, metrics, preferHq);
        LiveEpgService.Guide guide = enrichCatalogWithEpg(a, single);
        synchronized (CATALOG_CACHE) {
            CATALOG_CACHE.put(
                    catalogCacheKey(a, source),
                    new CachedCatalog(single, guide, System.currentTimeMillis()));
        }
        return single;
    }

    private static LiveEpgService.Guide enrichCatalogWithEpg(
            MainActivity a, LiveCatalog.Catalog catalog) {
        if (catalog == null || catalog.channelCount() == 0) return null;
        String userEpg = a.prefs != null ? a.prefs.getString(Prefs.LIVE_EPG_URL, "") : "";
        String epgUrl = LiveEpgService.firstEpgUrl(catalog, userEpg);
        if (epgUrl.isEmpty()) return null;
        try {
            LiveEpgService.Guide guide = LiveEpgService.load(epgUrl);
            LiveEpgService.applyGuideToCatalog(catalog, guide, System.currentTimeMillis());
            if (a.liveSession != null && a.liveSession.catalog == catalog) {
                a.liveSession.epgGuide = guide;
            }
            return guide;
        } catch (Exception ignored) {
            // EPG enrichment is strictly best-effort and must never block live playback.
            return null;
        }
    }

    static void liveChannels(
            MainActivity a, LiveCatalog.Source source, LiveCatalog.Group group, int page) {
        a.renderPage(group.name, "LIVE CHANNELS");
        int pageSize = 40;
        int start = page * pageSize, end = Math.min(group.channels.size(), start + pageSize);
        int cols = 4;
        LinearLayout row = null;
        for (int i = start; i < end; i++) {
            int offset = i - start;
            if (offset % cols == 0) {
                row = a.row();
                LinearLayout.LayoutParams rlp = new LinearLayout.LayoutParams(-1, -2);
                rlp.bottomMargin = a.dp(10);
                a.body.addView(row, rlp);
            }
            LiveCatalog.Channel channel = group.channels.get(i);
            String epg = channel.options.get("epg");
            String label =
                    channel.streams.size() > 1
                            ? channel.name + "  ·  " + channel.streams.size() + "源"
                            : channel.name;
            if (epg != null && !epg.trim().isEmpty()) {
                String shortEpg = epg.trim();
                if (shortEpg.length() > 14) shortEpg = shortEpg.substring(0, 14) + "…";
                label = label + "\n" + shortEpg;
            }
            TextView btn =
                    a.button(
                            label,
                            "channel:" + i,
                            () -> {
                                if (channel.streams.size() == 1)
                                    playLive(a, source, channel, channel.streams.get(0));
                                else {
                                    String[] names = streamLabelsFor(a, channel);
                                    new AppDialog.Builder(a)
                                            .setTitle(channel.name)
                                            .setItems(
                                                    names,
                                                    (dialog, n) ->
                                                            playLive(
                                                                    a,
                                                                    source,
                                                                    channel,
                                                                    channel.streams.get(n)))
                                            .show();
                                }
                            });
            LinearLayout.LayoutParams blp = new LinearLayout.LayoutParams(0, -2, 1f);
            if (offset % cols != cols - 1) blp.rightMargin = a.dp(10);
            row.addView(btn, blp);
        }
        LinearLayout pages = a.row();
        if (page > 0)
            a.addButton(
                    pages,
                    a.button(
                            "上一页",
                            "previous",
                            () ->
                                    a.open(
                                            new MainActivity.Screen(
                                                    () -> liveChannels(a, source, group, page - 1)),
                                            true)));
        if (end < group.channels.size())
            a.addButton(
                    pages,
                    a.button(
                            "下一页",
                            "next",
                            () ->
                                    a.open(
                                            new MainActivity.Screen(
                                                    () -> liveChannels(a, source, group, page + 1)),
                                            true)));
        a.body.addView(pages);
    }

    private static boolean isPlayableLiveUrl(String rawUrl) {
        if (rawUrl == null || rawUrl.trim().isEmpty()) return false;
        String u = rawUrl.trim();
        if (u.regionMatches(true, 0, "webview://", 0, 10)) return true;
        if (LiveQualityPolicy.isEmbyLiveUrl(u)) return true;
        return Cms.isMedia(LocalProxy.rewrite(u));
    }

    private static boolean isDirectExoLiveUrl(String rawUrl) {
        if (rawUrl == null || rawUrl.trim().isEmpty()) return false;
        if (LiveQualityPolicy.isEmbyLiveUrl(rawUrl)) return true;
        String rewritten = LocalProxy.rewrite(rawUrl.trim());
        if (rewritten == null) return false;
        String lower = rewritten.trim().toLowerCase(java.util.Locale.ROOT);
        return lower.startsWith("http://")
                || lower.startsWith("https://")
                || lower.startsWith("rtsp://")
                || lower.startsWith("rtsps://")
                || lower.startsWith("udp://")
                || lower.startsWith("rtp://");
    }

    private static int resolveLivePlayerType(
            LiveCatalog.Source source, LiveCatalog.Channel channel, LiveCatalog.Stream stream) {
        String[] candidates =
                new String[] {
                    stream != null ? stream.options.get("playerType") : null,
                    channel != null ? channel.options.get("playerType") : null,
                    source != null ? source.options.get("playerType") : null
                };
        for (String val : candidates) {
            if (val != null && !val.trim().isEmpty()) {
                try {
                    return Integer.parseInt(val.trim());
                } catch (NumberFormatException ignored) {
                }
            }
        }
        return 0;
    }

    static void playFromCatalog(
            MainActivity a,
            LiveCatalog.Source source,
            LiveCatalog.Catalog catalog,
            LiveCatalog.Channel channel,
            LiveCatalog.Stream stream,
            TvSearchContext context) {
        if (!context.matches(a.config, a.privateMode, a.engineEpoch)) {
            a.notice("来源已更改，请重新打开直播。");
            return;
        }
        if (stream == null || !channel.streams.contains(stream)) {
            a.notice("所选线路不在当前频道中。");
            return;
        }
        try {
            a.liveSession = LiveSession.forChannel(source, catalog, channel);
        } catch (IllegalArgumentException invalid) {
            a.notice("频道列表已失效，请返回后重试。");
            return;
        }
        playLive(a, source, channel, stream);
    }

    static void playLive(
            MainActivity a,
            LiveCatalog.Source source,
            LiveCatalog.Channel channel,
            LiveCatalog.Stream stream) {
        String udpxy = a.prefs != null ? a.prefs.getString(Prefs.LIVE_UDPXY_URL, "") : "";
        boolean preferHq = a.prefs == null || a.prefs.getBoolean(Prefs.LIVE_HIGH_QUALITY, true);
        if (a.liveSession != null && a.liveSession.source == source)
            a.liveSession.index = a.liveSession.channels.indexOf(channel);
        if (a.config != null) {
            try {
                a.ensureProxy(a.config);
            } catch (Exception ignored) {
            }
        }
        LiveCatalog.Stream chosen = stream;
        if (channel != null
                && !channel.streams.isEmpty()
                && (chosen == null || !isDirectExoLiveUrl(chosen.url))) {
            for (LiveCatalog.Stream candidate : channel.streams) {
                if (isDirectExoLiveUrl(candidate.url)) {
                    chosen = candidate;
                    break;
                }
            }
            if (chosen == null || !isPlayableLiveUrl(chosen.url)) {
                for (LiveCatalog.Stream candidate : channel.streams) {
                    if (isPlayableLiveUrl(candidate.url)) {
                        chosen = candidate;
                        break;
                    }
                }
            }
            if (chosen == null) chosen = channel.streams.get(0);
        }

        String effectiveUrl = LiveQualityPolicy.rewriteMulticastUrl(chosen.url, udpxy);
        if (LiveQualityPolicy.isMulticastUrl(effectiveUrl)) {
            LiveCatalog.Stream fallback = null;
            if (channel != null && channel.streams.indexOf(chosen) == 0) {
                for (LiveCatalog.Stream cand : channel.streams) {
                    String rw = LiveQualityPolicy.rewriteMulticastUrl(cand.url, udpxy);
                    if (!rw.isEmpty() && !LiveQualityPolicy.isMulticastUrl(rw)) {
                        fallback = cand;
                        effectiveUrl = rw;
                        break;
                    }
                }
            }
            if (fallback != null) {
                chosen = fallback;
            } else {
                a.toast("此频道为运营商组播源，请在设置或直播管理中配置路由器 udpxy 网关地址");
                return;
            }
        }

        a.activeLine = null;
        a.activeEpisode = null;
        a.resumeAt = 0;
        String resolvedUrl =
                LiveQualityPolicy.isEmbyLiveUrl(effectiveUrl)
                        ? effectiveUrl
                        : LocalProxy.rewrite(effectiveUrl);
        Cms.Site site = new Cms.Site();
        site.key = "live";
        site.name = source.name;
        site.api = resolvedUrl;
        site.type = 1;
        site.playUrl = "";
        site.headers.putAll(chosen.headers);
        Cms.Video video = new Cms.Video();
        video.title = channel.name;
        Cms.Episode ep = new Cms.Episode();
        ep.name =
                chosen.label != null && !chosen.label.trim().isEmpty() ? chosen.label.trim() : "直播";
        ep.url = resolvedUrl;
        ep.headers.putAll(chosen.headers);
        try {
            ep.media.put("live", true);
            ep.media.put("livePreferHighQuality", preferHq);
            int playerType = resolveLivePlayerType(source, channel, chosen);
            if (playerType > 0) {
                ep.media.put("playerType", playerType);
            }
            String kodiMime = LiveQualityPolicy.mimeFromKodiProps(chosen.options);
            if (!kodiMime.isEmpty()) ep.media.put("mimeType", kodiMime);
            org.json.JSONObject kodiDrm = LiveQualityPolicy.buildDrmFromKodiProps(chosen.options);
            if (kodiDrm != null) ep.media.put("drm", kodiDrm);
            if (channel != null && channel.streams.size() > 1) {
                String[] displayLabels = streamLabelsFor(a, channel);
                org.json.JSONArray qualities = new org.json.JSONArray();
                int activeQualityIdx = 0;
                for (int i = 0; i < channel.streams.size(); i++) {
                    LiveCatalog.Stream cand = channel.streams.get(i);
                    String candUrl = LiveQualityPolicy.rewriteMulticastUrl(cand.url, udpxy);
                    if (candUrl.isEmpty()
                            || LiveQualityPolicy.isMulticastUrl(candUrl)
                            || candUrl.regionMatches(true, 0, "webview://", 0, 10)) continue;
                    if (!isDirectExoLiveUrl(candUrl)) continue;
                    if (cand == chosen) activeQualityIdx = qualities.length();
                    org.json.JSONObject qObj = new org.json.JSONObject();
                    qObj.put("name", i < displayLabels.length ? displayLabels[i] : "线路 " + (i + 1));
                    qObj.put(
                            "url",
                            LiveQualityPolicy.isEmbyLiveUrl(candUrl)
                                    ? candUrl
                                    : LocalProxy.rewrite(candUrl));
                    if (!cand.headers.isEmpty()) {
                        qObj.put("headers", new org.json.JSONObject(cand.headers));
                    }
                    String cMime = LiveQualityPolicy.mimeFromKodiProps(cand.options);
                    if (!cMime.isEmpty()) qObj.put("mimeType", cMime);
                    org.json.JSONObject cDrm =
                            LiveQualityPolicy.buildDrmFromKodiProps(cand.options);
                    if (cDrm != null) qObj.put("drm", cDrm);
                    qualities.put(qObj);
                }
                if (qualities.length() > 1) {
                    ep.media.put("qualities", qualities);
                    ep.media.put("_qualityIdx", activeQualityIdx);
                }
            }
        } catch (Exception ignored) {
        }
        if (resolvedUrl != null && resolvedUrl.regionMatches(true, 0, "webview://", 0, 10)) {
            ep.url = resolvedUrl.substring(10).trim();
            site.api = ep.url;
            PlaybackController.resolveWebPage(a, site, video, ep, "");
            return;
        }
        if (LiveQualityPolicy.isEmbyLiveUrl(resolvedUrl)) {
            playEmbyLiveAsync(a, site, video, ep, resolvedUrl);
            return;
        }
        openLivePlayerScreen(a, site, video, ep);
    }

    private static void openLivePlayerScreen(
            MainActivity a, Cms.Site site, Cms.Video video, Cms.Episode ep) {
        if (a.current != null && a.current.player) {
            if (!Cms.isMedia(ep.url)) {
                PlaybackController.openPlayer(a, site, video, ep);
                return;
            }
            MainActivity.Screen next =
                    new MainActivity.Screen(
                            () -> PlaybackController.playerPage(a, site, video, ep));
            next.player = true;
            a.current = next;
            next.render.run();
        } else a.openPlayer(site, video, ep);
    }

    static void playEmbyLiveAsync(
            MainActivity a, Cms.Site site, Cms.Video video, Cms.Episode ep, String embyLiveUrl) {
        final String acct = com.pilipala.emby.EmbyLibrary.parseLiveAccount(embyLiveUrl);
        if (acct.isEmpty()) {
            a.toast("Emby 直播频道账户无效");
            return;
        }
        final int ticket = a.generation;
        final int resolveSerial = ++a.playbackResolveSerial;
        if (a.playStatus != null && a.current != null && a.current.player) {
            a.playStatus.setText("正在打开 Emby 直播流…");
        } else {
            a.toast("正在打开 Emby 直播流…");
        }
        a.worker.execute(
                () -> {
                    try {
                        com.pilipala.emby.EmbyLibrary lib =
                                com.pilipala.emby.EmbyAccounts.open(
                                        a, com.pilipala.emby.EmbyLibrary.PREFIX + acct);
                        org.json.JSONObject resolved = lib.resolveLiveChannel(embyLiveUrl, false);
                        String streamUrl = resolved.optString("url", "").trim();
                        if (streamUrl.isEmpty()) {
                            throw new IOException("Emby 未返回直播流地址");
                        }
                        org.json.JSONObject embySession = resolved.optJSONObject("embySession");
                        org.json.JSONObject headerObj = resolved.optJSONObject("header");
                        a.ui.post(
                                () -> {
                                    if (a.isFinishing()
                                            || ticket != a.generation
                                            || resolveSerial != a.playbackResolveSerial) {
                                        if (embySession != null) {
                                            try {
                                                lib.track(embySession).stop(0);
                                            } catch (Exception ignored) {
                                            }
                                        }
                                        return;
                                    }
                                    site.api = com.pilipala.emby.EmbyLibrary.PREFIX + acct;
                                    ep.url = streamUrl;
                                    ep.headers.clear();
                                    if (headerObj != null) {
                                        java.util.Iterator<String> keys = headerObj.keys();
                                        while (keys.hasNext()) {
                                            String k = keys.next();
                                            String val = headerObj.optString(k, "");
                                            if (!val.isEmpty()) ep.headers.put(k, val);
                                        }
                                    }
                                    site.headers.clear();
                                    site.headers.putAll(ep.headers);
                                    try {
                                        if (embySession != null) {
                                            ep.media.put("embySession", embySession);
                                        } else {
                                            ep.media.remove("embySession");
                                        }
                                    } catch (Exception ignored) {
                                    }
                                    openLivePlayerScreen(a, site, video, ep);
                                });
                    } catch (Exception ex) {
                        AppLog.w("LiveController", "resolve Emby live failed", ex);
                        a.ui.post(
                                () -> {
                                    if (a.isFinishing()
                                            || ticket != a.generation
                                            || resolveSerial != a.playbackResolveSerial) return;
                                    if (!PlaybackController.tryAdvanceQualityOrLiveStream(
                                            a, ticket, site, video, ep)) {
                                        a.toast("Emby 直播打开失败：" + a.message(ex));
                                    }
                                });
                    }
                });
    }

    static boolean isLive(MainActivity a) {
        return a.playbackControls != null && "live".equals(a.playbackControls.site.key);
    }

    static boolean liveStep(MainActivity a, int direction) {
        if (a.liveSession == null || a.liveSession.channels.isEmpty()) return false;
        tuneLive(a, a.liveSession.step(direction), 0);
        return true;
    }

    static void tuneLive(MainActivity a, int index, int stream) {
        if (a.liveSession == null || index < 0 || index >= a.liveSession.channels.size()) return;
        LiveCatalog.Channel channel = a.liveSession.channels.get(index);
        playLive(
                a,
                a.liveSession.source,
                channel,
                channel.streams.get(Math.min(stream, channel.streams.size() - 1)));
    }

    static void chooseLiveChannel(MainActivity a) {
        if (a.liveSession == null) return;
        String[] labels = new String[a.liveSession.channels.size()];
        for (int i = 0; i < labels.length; i++)
            labels[i] = (i + 1) + " · " + a.liveSession.channels.get(i).name;
        a.playbackControls.choose("选择频道", labels, a.liveSession.index, i -> tuneLive(a, i, 0));
    }

    static void chooseLiveStream(MainActivity a) {
        if (a.liveSession == null || a.liveSession.index < 0) return;
        LiveCatalog.Channel c = a.liveSession.channels.get(a.liveSession.index);
        String[] labels = streamLabelsFor(a, c);
        a.playbackControls.choose("直播线路", labels, -1, i -> tuneLive(a, a.liveSession.index, i));
    }

    static void showEpgAndCatchupDialog(MainActivity a) {
        if (a == null || a.liveSession == null || a.liveSession.index < 0) {
            if (a != null) a.toast("当前没有可查询节目单的直播频道");
            return;
        }
        final LiveCatalog.Channel channel = a.liveSession.channels.get(a.liveSession.index);
        final String userEpg = a.prefs != null ? a.prefs.getString(Prefs.LIVE_EPG_URL, "") : "";
        final String epgUrl = LiveEpgService.firstEpgUrl(a.liveSession.catalog, userEpg);
        if (a.liveSession.epgGuide != null) {
            presentEpgDialog(a, channel, a.liveSession.epgGuide);
            return;
        }
        if (epgUrl.isEmpty()) {
            String inlineEpg = channel.options.get("epg");
            if (inlineEpg != null && !inlineEpg.trim().isEmpty()) {
                a.toast("当前正在播出：" + inlineEpg.trim());
            } else {
                a.toast("未找到节目单，请在设置或直播管理中配置 XMLTV EPG 地址");
            }
            return;
        }
        a.toast("正在加载节目单…");
        a.worker.execute(
                () -> {
                    try {
                        LiveEpgService.Guide guide = LiveEpgService.load(epgUrl);
                        a.liveSession.epgGuide = guide;
                        a.ui.post(() -> presentEpgDialog(a, channel, guide));
                    } catch (Exception ex) {
                        a.ui.post(() -> a.toast("节目单加载失败：" + a.message(ex)));
                    }
                });
    }

    private static void presentEpgDialog(
            MainActivity a, LiveCatalog.Channel channel, LiveEpgService.Guide guide) {
        if (a.isFinishing() || a.playbackControls == null) return;
        long nowMs = System.currentTimeMillis();
        String tvgName = channel.options.get("tvg-name");
        LiveEpgService.Program current =
                guide.currentProgram(channel.id, tvgName, channel.name, nowMs);
        List<LiveEpgService.Program> upcoming =
                guide.upcomingPrograms(channel.id, tvgName, channel.name, nowMs, 6);
        boolean canCatchup = LiveEpgService.supportsCatchup(channel);
        int days = LiveEpgService.catchupDays(channel);
        List<LiveEpgService.Program> past =
                guide.pastPrograms(channel.id, tvgName, channel.name, nowMs, days);
        if (past.size() > 24) past = past.subList(0, 24);

        List<String> labels = new java.util.ArrayList<>();
        final List<LiveEpgService.Program> actionPrograms = new java.util.ArrayList<>();
        labels.add("🔴 返回实时直播 · " + channel.name);
        actionPrograms.add(null);
        if (current != null) {
            labels.add("正在播出 · " + current.timeRangeLabel() + "  " + current.title);
            actionPrograms.add(null);
        }
        for (LiveEpgService.Program p : upcoming) {
            labels.add("预告 · " + p.timeRangeLabel() + "  " + p.title);
            actionPrograms.add(null);
        }
        for (LiveEpgService.Program p : past) {
            labels.add((canCatchup ? "⏪ 回看 · " : "已播 · ") + p.dayAndTimeLabel() + "  " + p.title);
            actionPrograms.add(canCatchup ? p : null);
        }
        if (labels.size() <= 1) {
            a.toast("该频道暂无匹配的 XMLTV 节目单记录");
            return;
        }
        a.playbackControls.choose(
                channel.name + (canCatchup ? " · 节目单与回看" : " · 节目单"),
                labels.toArray(new String[0]),
                current != null ? 1 : 0,
                idx -> {
                    if (idx == 0) {
                        tuneLive(a, a.liveSession.index, 0);
                        return;
                    }
                    LiveEpgService.Program chosen =
                            idx >= 0 && idx < actionPrograms.size()
                                    ? actionPrograms.get(idx)
                                    : null;
                    if (chosen == null) return;
                    playCatchupProgram(a, channel, chosen);
                });
    }

    private static void playCatchupProgram(
            MainActivity a, LiveCatalog.Channel channel, LiveEpgService.Program program) {
        if (channel.streams.isEmpty()) return;
        String udpxy = a.prefs != null ? a.prefs.getString(Prefs.LIVE_UDPXY_URL, "") : "";
        LiveCatalog.Stream stream = channel.streams.get(0);
        String baseUrl = LiveQualityPolicy.rewriteMulticastUrl(stream.url, udpxy);
        String mode = LiveEpgService.optionIgnoreCase(channel.options, "catchup");
        String src = LiveEpgService.optionIgnoreCase(channel.options, "catchup-source");
        String catchupUrl =
                LiveEpgService.buildCatchupUrl(
                        baseUrl, mode, src, program.startMs, program.stopMs, null);
        if (catchupUrl.isEmpty()) {
            a.toast("当前线路不支持回看模板拼接");
            return;
        }
        Cms.Site site = new Cms.Site();
        site.key = "live";
        site.name = "回看";
        site.api = catchupUrl;
        site.type = 1;
        site.headers.putAll(stream.headers);
        Cms.Video video = new Cms.Video();
        video.title = channel.name + " · 回看：" + program.title;
        Cms.Episode ep = new Cms.Episode();
        ep.name = program.title;
        ep.url = catchupUrl;
        ep.headers.putAll(stream.headers);
        try {
            ep.media.put("live", false);
            ep.media.put("catchupReplay", true);
        } catch (Exception ignored) {
        }
        a.resumeAt = 0;
        openLivePlayerScreen(a, site, video, ep);
    }

    static void clearLiveNumber(MainActivity a) {
        a.ui.removeCallbacks(a.tuneLiveNumber);
        if (a.liveSession != null) a.liveSession.clear();
        if (a.root != null) {
            View old = a.root.findViewWithTag("live-number");
            if (old != null) a.root.removeView(old);
        }
    }

    static void commitLiveNumber(MainActivity a) {
        if (!isLive(a) || a.liveSession == null) {
            clearLiveNumber(a);
            return;
        }
        int index = a.liveSession.selectedNumber();
        clearLiveNumber(a);
        if (index >= 0) tuneLive(a, index, 0);
        else a.toast("没有这个频道号");
    }

    static boolean liveKey(MainActivity a, KeyEvent event) {
        if (!isLive(a) || a.miniMode || a.liveSession == null || a.playbackControls.dialogOpen)
            return false;
        int key = event.getKeyCode();
        boolean down = event.getAction() == KeyEvent.ACTION_DOWN;
        int digit =
                key >= KeyEvent.KEYCODE_0 && key <= KeyEvent.KEYCODE_9
                        ? key - KeyEvent.KEYCODE_0
                        : key >= KeyEvent.KEYCODE_NUMPAD_0 && key <= KeyEvent.KEYCODE_NUMPAD_9
                                ? key - KeyEvent.KEYCODE_NUMPAD_0
                                : -1;
        if (digit >= 0) {
            if (down && event.getRepeatCount() == 0) {
                a.liveSession.digit(digit);
                TextView label = (TextView) a.root.findViewWithTag("live-number");
                if (label == null) {
                    label = a.text("", 30, MainActivity.WHITE);
                    label.setTag("live-number");
                    label.setPadding(a.dp(18), a.dp(10), a.dp(18), a.dp(10));
                    label.setBackground(a.bg(0xee25252b, 18));
                    FrameLayout.LayoutParams size =
                            new FrameLayout.LayoutParams(-2, -2, Gravity.TOP | Gravity.RIGHT);
                    size.setMargins(0, a.dp(30), a.dp(40), 0);
                    a.root.addView(label, size);
                }
                label.setText(a.liveSession.digits);
                a.ui.removeCallbacks(a.tuneLiveNumber);
                a.ui.postDelayed(a.tuneLiveNumber, 1200);
            }
            return true;
        }
        if (!a.liveSession.digits.isEmpty()
                && (key == KeyEvent.KEYCODE_DPAD_CENTER
                        || key == KeyEvent.KEYCODE_ENTER
                        || key == KeyEvent.KEYCODE_BACK)) {
            if (down && event.getRepeatCount() == 0) {
                if (key == KeyEvent.KEYCODE_BACK) clearLiveNumber(a);
                else commitLiveNumber(a);
            }
            return true;
        }
        boolean up =
                key == KeyEvent.KEYCODE_CHANNEL_UP
                        || !a.controlsVisible && key == KeyEvent.KEYCODE_DPAD_UP;
        boolean lower =
                key == KeyEvent.KEYCODE_CHANNEL_DOWN
                        || !a.controlsVisible && key == KeyEvent.KEYCODE_DPAD_DOWN;
        if (up || lower) {
            if (down && event.getRepeatCount() == 0) {
                clearLiveNumber(a);
                liveStep(
                        a,
                        key == KeyEvent.KEYCODE_CHANNEL_UP
                                ? 1
                                : key == KeyEvent.KEYCODE_CHANNEL_DOWN ? -1 : up ? -1 : 1);
            }
            return true;
        }
        return false;
    }
}
