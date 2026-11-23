package com.pilipala.marcomovie;

import android.app.Activity;
import android.content.Intent;
import android.net.Uri;
import android.os.SystemClock;
import android.view.View;
import android.widget.LinearLayout;
import android.widget.TextView;
import java.io.IOException;
import java.io.InputStream;
import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.concurrent.Future;

/**
 * Manages source engine lifecycles, detail loading, phonetic title indexing, and configuration /
 * subtitle / danmaku document imports.
 */
final class SourceController {
    static final int MAX_CACHED_ENGINES_TV = 14;
    static final int MAX_CACHED_ENGINES_MOBILE = 24;

    private SourceController() {}

    static int maxCachedEngines(boolean tvDevice) {
        return tvDevice ? MAX_CACHED_ENGINES_TV : MAX_CACHED_ENGINES_MOBILE;
    }

    private static void closeEnginesAsync(final List<SourceEngine> toClose) {
        if (toClose == null || toClose.isEmpty()) return;
        Thread t =
                new Thread(
                        () -> {
                            for (SourceEngine e : toClose) {
                                if (e == null) continue;
                                try {
                                    e.close();
                                } catch (Throwable ignored) {
                                }
                            }
                        },
                        "close-source-engines");
        t.setDaemon(true);
        t.start();
    }

    static String importOrigin(String address) {
        return com.pilipala.emby.CheckedScript.matches(address) ? "" : address;
    }

    static String fetchImport(android.content.Context context, String address) throws Exception {
        if (!com.pilipala.emby.CheckedScript.matches(address)) return Cms.fetchImport(address);
        com.pilipala.emby.CheckedScript script = com.pilipala.emby.CheckedScript.read(address);
        if (com.pilipala.catpaw.CatPawHost.isBundle(script.code))
            return new com.pilipala.catpaw.CatPawHost(context).install(script.code);
        if (!Cms.looksLikeJsSpider(script.code, "")) throw new IOException("已校验的文件没有兼容的来源入口");
        org.json.JSONObject site =
                new org.json.JSONObject()
                        .put("key", "script_" + script.base.hashCode())
                        .put("name", new java.net.URL(script.base).getHost())
                        .put("type", 3)
                        .put("api", script.base)
                        .put("ext", new org.json.JSONObject().put("_mm_entrySource", script.code));
        return new org.json.JSONObject()
                .put("sites", new org.json.JSONArray().put(site))
                .toString();
    }

    static boolean available(MainActivity a, Cms.Site s) {
        return available(a, a != null ? a.config : null, s);
    }

    static boolean available(MainActivity a, Cms.Config cfg, Cms.Site s) {
        if (s == null) return false;
        String api = s.api == null ? "" : s.api;
        return api.startsWith(com.pilipala.emby.EmbyLibrary.PREFIX)
                || api.startsWith(AlistEngine.PREFIX)
                || api.startsWith("catpaw://")
                || HttpT4Engine.eligible(s)
                || s.supported()
                || (a.prefs.getBoolean(Prefs.EXPERIMENTAL_CSP, true)
                        && ((CspEngine.eligible(s)
                                        && ((s.jar != null && !s.jar.isEmpty())
                                                || (cfg != null && !cfg.spider.isEmpty())))
                                || ((JsEngine.eligible(s) || DrpyEngine.eligible(s))
                                        && cfg != null)));
    }

    static SourceEngine engine(MainActivity a, Cms.Site s) throws Exception {
        return engine(a, s, null);
    }

    static SourceEngine engine(MainActivity a, Cms.Site s, TvSearchContext context)
            throws Exception {
        if (Thread.currentThread().isInterrupted()) throw new InterruptedException();
        final Cms.Config snapshot;
        final int epoch;
        SourceEngine wedgedToClose = null;
        synchronized (a) {
            if (context != null && !context.matches(a.config, a.privateMode, a.engineEpoch))
                throw new IOException("搜索上下文已失效");
            SourceEngine existing = a.engines.get(s.key);
            if (existing instanceof QueuedSourceEngine
                    && ((QueuedSourceEngine) existing).isWedged()) {
                a.engines.remove(s.key);
                wedgedToClose = existing;
                existing = null;
            }
            if (existing != null) return existing;
            snapshot = a.config;
            epoch = a.engineEpoch;
        }
        if (wedgedToClose != null) {
            closeEnginesAsync(java.util.Collections.singletonList(wedgedToClose));
        }
        return a.engineInitializations.get(
                epoch + ":" + s.key,
                () -> {
                    synchronized (a) {
                        if (epoch != a.engineEpoch) throw new IOException("配置已更改，请重新选择来源");
                        if (context != null
                                && !context.matches(a.config, a.privateMode, a.engineEpoch))
                            throw new IOException("搜索上下文已失效");
                        SourceEngine existing = a.engines.get(s.key);
                        if (existing != null) return existing;
                    }
                    SourceEngine raw;
                    String api = s.api == null ? "" : s.api;
                    if (api.startsWith(com.pilipala.emby.EmbyLibrary.PREFIX))
                        raw = new EmbyEngine(a, s);
                    else if (api.startsWith(AlistEngine.PREFIX)) raw = new AlistEngine(a, s);
                    else if (api.startsWith("catpaw://")) raw = new CatPawEngine(a, s);
                    else if (HttpT4Engine.eligible(s)) raw = new HttpT4Engine(s);
                    else if (s.supported()) raw = new JsonCmsEngine(s);
                    else if (a.prefs.getBoolean(Prefs.EXPERIMENTAL_CSP, true)
                            && DrpyEngine.eligible(s)
                            && snapshot != null) raw = new DrpyEngine(a, snapshot, s);
                    else if (a.prefs.getBoolean(Prefs.EXPERIMENTAL_CSP, true)
                            && GuardEngine.eligible(s)
                            && snapshot != null) {
                        raw =
                                GuardEngine.open(
                                        a,
                                        snapshot,
                                        s,
                                        () -> {
                                            ensureProxy(a, snapshot);
                                            return new CspEngine(a.getApplication(), snapshot, s);
                                        });
                    } else if (a.prefs.getBoolean(Prefs.EXPERIMENTAL_CSP, true)
                            && !JsEngine.eligible(s)
                            && CspEngine.eligible(s)
                            && snapshot != null) {
                        ensureProxy(a, snapshot);
                        raw = new CspEngine(a.getApplication(), snapshot, s);
                    } else if (a.prefs.getBoolean(Prefs.EXPERIMENTAL_CSP, true)
                            && NativePythonEngine.eligible(s)
                            && a.prefs.getBoolean(Prefs.NATIVE_PYTHON_ENABLED, true)
                            && NativePythonEngine.isAvailable()
                            && snapshot != null) {
                        ensureProxy(a, snapshot);
                        try {
                            raw = new NativePythonEngine(a.getApplication(), snapshot, s);
                        } catch (Throwable nativePyError) {
                            AppLog.w(
                                    "SourceController",
                                    "Native CPython failed for "
                                            + s.key
                                            + ", falling back to JsEngine",
                                    nativePyError);
                            raw = new JsEngine(a.getApplication(), snapshot, s);
                        }
                    } else if (a.prefs.getBoolean(Prefs.EXPERIMENTAL_CSP, true)
                            && JsEngine.eligible(s)
                            && snapshot != null) {
                        ensureProxy(a, snapshot);
                        try {
                            raw = new JsEngine(a.getApplication(), snapshot, s);
                        } catch (JsEngine.DrpyRuleDetected rule) {
                            raw = new DrpyEngine(a, snapshot, s, rule.source);
                        } catch (Throwable jsError) {
                            if (a.prefs.getBoolean(Prefs.WEBVIEW_JS_FALLBACK, true)
                                    && WebViewJsEngine.shouldFallbackFromJsError(jsError)) {
                                AppLog.w(
                                        "SourceController",
                                        "QuickJS failed for "
                                                + s.key
                                                + ", trying WebView JS fallback",
                                        jsError);
                                try {
                                    raw = new WebViewJsEngine(a.getApplication(), snapshot, s);
                                } catch (Throwable wvError) {
                                    if (jsError instanceof Exception) throw (Exception) jsError;
                                    throw new IOException(jsError.getMessage(), jsError);
                                }
                            } else {
                                if (jsError instanceof Exception) throw (Exception) jsError;
                                throw new IOException(jsError.getMessage(), jsError);
                            }
                        }
                    } else throw new IOException("来源需要尚未启用的扩展引擎");
                    SourceEngine created = new QueuedSourceEngine(raw);
                    List<SourceEngine> evicted = null;
                    boolean accepted = false;
                    synchronized (a) {
                        if (epoch == a.engineEpoch
                                && (context == null
                                        || context.matches(
                                                a.config, a.privateMode, a.engineEpoch))) {
                            if (raw instanceof JsEngine) ((JsEngine) raw).activate();
                            a.engines.put(s.key, created);
                            accepted = true;
                            int cap = maxCachedEngines(a.isTvDevice());
                            if (a.engines.size() > cap) {
                                String selectedKey =
                                        a.prefs != null
                                                ? a.prefs.getString(Prefs.SELECTED_SITE, "")
                                                : "";
                                String configCenterKey =
                                        a.prefs != null
                                                ? a.prefs.getString(
                                                        Prefs.ACCOUNT_CONFIG_CENTER_KEY, "")
                                                : "";
                                evicted = new ArrayList<>();
                                java.util.Iterator<java.util.Map.Entry<String, SourceEngine>> it =
                                        a.engines.entrySet().iterator();
                                while (a.engines.size() > cap && it.hasNext()) {
                                    java.util.Map.Entry<String, SourceEngine> entry = it.next();
                                    String ek = entry.getKey();
                                    if (ek.equals(s.key)
                                            || ek.equals(selectedKey)
                                            || ek.equals(configCenterKey)) {
                                        continue;
                                    }
                                    evicted.add(entry.getValue());
                                    it.remove();
                                }
                            }
                        }
                    }
                    if (evicted != null && !evicted.isEmpty()) {
                        closeEnginesAsync(evicted);
                    }
                    if (accepted) return created;
                    created.close();
                    throw new IOException("配置已更改，请重新选择来源");
                });
    }

    private static final Object PROXY_LOCK = new Object();

    static void ensureProxy(MainActivity a, Cms.Config snapshot) throws IOException {
        synchronized (PROXY_LOCK) {
            if (a.localProxy == null || a.localProxy.closed) {
                a.localProxy = new LocalProxy(a.getApplication(), snapshot);
            }
        }
    }

    static void closeEngines(MainActivity a) {
        if (a.markerHost != null) a.markerHost.abort();
        GlobalSearchScreen.invalidateContext(a);
        a.liveSession = null;
        CspEngine.resetActiveProxy();
        if (a.detailPrefetch != null) a.detailPrefetch.cancel(true);
        a.detailCache.clear();
        a.homeData.clear();
        if (a.localProxy != null) {
            a.localProxy.close();
            a.localProxy = null;
        }
        final List<SourceEngine> old;
        synchronized (a) {
            a.engineEpoch++;
            old = new ArrayList<>(a.engines.values());
            a.engines.clear();
        }
        if (!old.isEmpty())
            new Thread(
                            () -> {
                                for (SourceEngine e : old) e.close();
                            },
                            "close-source-engines")
                    .start();
    }

    static volatile long lastConfigActionAt;
    static volatile boolean pendingConfigRefreshOnFocus;

    static boolean isDedicatedConfigSite(Cms.Site site) {
        if (site == null) return false;
        String api = site.api == null ? "" : site.api.toLowerCase(java.util.Locale.ROOT);
        String key = site.key == null ? "" : site.key.toLowerCase(java.util.Locale.ROOT);
        String name = site.name == null ? "" : site.name;
        return api.contains("mydrive")
                || api.contains("config")
                || api.contains("panconfig")
                || api.contains("wexconfig")
                || api.contains("wexokconfig")
                || api.contains("pconfig")
                || api.contains("localconfig")
                || api.contains("csp_pan")
                || api.contains("csp_token")
                || key.contains("mydrive")
                || key.contains("config")
                || key.contains("panconfig")
                || key.contains("wexconfig")
                || key.contains("pconfig")
                || name.contains("配置中心")
                || name.contains("配置┃中心")
                || name.contains("配置丨中心")
                || name.contains("配置|中心")
                || (name.contains("配置") && name.contains("中心"))
                || name.contains("设置中心")
                || name.contains("账号配置")
                || name.contains("玩偶配置")
                || (name.contains("云盘") && (name.contains("配置") || name.contains("设置")))
                || (name.contains("网盘") && (name.contains("配置") || name.contains("设置")));
    }

    static boolean isConfigOrNetdiskSite(Cms.Site site) {
        if (site == null) return false;
        if (isDedicatedConfigSite(site)) return true;
        String api = site.api == null ? "" : site.api.toLowerCase(java.util.Locale.ROOT);
        String key = site.key == null ? "" : site.key.toLowerCase(java.util.Locale.ROOT);
        String name = site.name == null ? "" : site.name;
        return api.contains("mypan")
                || key.contains("mypan")
                || name.contains("我的云盘")
                || name.contains("我的网盘")
                || name.contains("我的┃网盘")
                || name.contains("我的┃云盘");
    }

    static boolean isConfigOrNetdiskActionCard(Cms.Site site, Cms.Video v) {
        if (!isConfigOrNetdiskSite(site) || v == null) return false;
        if ("folder".equalsIgnoreCase(v.tag)) return false;
        if (v.lines != null && !v.lines.isEmpty()) return false;
        String id = v.id == null ? "" : v.id.trim();
        if (id.isEmpty() || id.startsWith("msearch:")) return false;
        String api = site.api == null ? "" : site.api.toLowerCase(java.util.Locale.ROOT);
        String key = site.key == null ? "" : site.key.toLowerCase(java.util.Locale.ROOT);
        if ((api.contains("mydrive") || key.contains("mydrive")) && id.startsWith("{")) {
            return false;
        }
        if (isDedicatedConfigSite(site)
                && !id.contains("/")
                && !id.startsWith("http://")
                && !id.startsWith("https://")) {
            return true;
        }
        String title = v.title == null ? "" : v.title;
        if (title.contains("登入")
                || title.contains("登录")
                || title.contains("清除")
                || title.contains("配置")
                || title.contains("顺序")
                || title.contains("设置")
                || title.contains("扫码")
                || title.contains("Cookie")
                || title.contains("token")
                || title.contains("Token")
                || title.contains("刷新")
                || title.contains("注册")
                || title.contains("输入")
                || title.contains("代理")
                || title.contains("加速")
                || title.contains("适配")
                || title.contains("DNS")
                || title.contains("弹幕")
                || title.contains("日志")
                || title.contains("备份")
                || title.contains("还原")
                || title.contains("突破")) {
            return true;
        }
        String lowerId = id.toLowerCase(java.util.Locale.ROOT);
        return id.startsWith("{")
                || lowerId.startsWith("action")
                || lowerId.contains("cookie")
                || lowerId.contains("token")
                || lowerId.contains("login")
                || lowerId.contains("clear")
                || lowerId.contains("manual")
                || lowerId.contains("register");
    }

    private static final long DETAIL_DISK_TTL_MS = 15L * 60L * 1000L;

    private static java.io.File detailDiskFile(MainActivity a, Cms.Site site, String id) {
        if (a == null || a.privateMode || a.reduced || site == null || id == null || id.isEmpty()) {
            return null;
        }
        if (isConfigOrNetdiskSite(site)) return null;
        if (site.api != null && site.api.contains("fixture.test")) return null;
        java.io.File cacheRoot = a.getCacheDir();
        if (cacheRoot == null) return null;
        java.io.File dir = new java.io.File(cacheRoot, "detail_v1");
        String material = (site.key == null ? "" : site.key) + "\u0000" + id;
        long h1 = 1125899906842597L;
        for (int i = 0; i < material.length(); i++) {
            h1 = h1 * 31L + material.charAt(i);
        }
        String name =
                Long.toHexString(h1) + "_" + Integer.toHexString(material.hashCode()) + ".json";
        return new java.io.File(dir, name);
    }

    private static String readDetailDiskCache(MainActivity a, Cms.Site site, String id) {
        java.io.File f = detailDiskFile(a, site, id);
        if (f == null || !f.isFile() || f.length() < 16 || f.length() > 1024 * 1024) return null;
        long age = System.currentTimeMillis() - f.lastModified();
        if (age < 0 || age > DETAIL_DISK_TTL_MS) return null;
        try (java.io.FileInputStream in = new java.io.FileInputStream(f);
                java.io.ByteArrayOutputStream out =
                        new java.io.ByteArrayOutputStream((int) f.length())) {
            byte[] buf = new byte[4096];
            int n;
            while ((n = in.read(buf)) != -1) out.write(buf, 0, n);
            return new String(out.toByteArray(), java.nio.charset.StandardCharsets.UTF_8);
        } catch (Throwable ignored) {
            return null;
        }
    }

    private static void writeDetailDiskCache(MainActivity a, Cms.Site site, String id, String raw) {
        if (raw == null || raw.length() < 16 || raw.length() > 1024 * 1024) return;
        java.io.File f = detailDiskFile(a, site, id);
        if (f == null) return;
        try {
            java.io.File dir = f.getParentFile();
            if (dir != null && !dir.isDirectory()) dir.mkdirs();
            try (java.io.FileOutputStream fos = new java.io.FileOutputStream(f)) {
                fos.write(raw.getBytes(java.nio.charset.StandardCharsets.UTF_8));
            }
        } catch (Throwable ignored) {
        }
    }

    static void prefetchDetail(MainActivity a, Cms.Site site, Cms.Video video) {
        if (a == null
                || a.reduced
                || site == null
                || video == null
                || video.id == null
                || video.id.isEmpty()) return;
        if (isConfigOrNetdiskSite(site) || isConfigOrNetdiskActionCard(site, video)) return;
        if (ListingRoute.isRedirect(video.tag, video.action, video.id)) return;
        if (SearchCoordinator.isSiteWedged(site.key)) return;
        // Speculation must never initialize a new source, and keeps at most one in-flight request.
        // Already-initialized engines (including TV CSP/JS/CatPaw sites) may safely prefetch while
        // idle so pressing OK opens the detail page immediately.
        final SourceEngine source;
        synchronized (a) {
            source = a.engines.get(site.key);
        }
        if (source == null) return;
        if (a.detailPrefetch != null && !a.detailPrefetch.isDone()) return;
        if (video.lines != null
                && !video.lines.isEmpty()
                && video.description != null
                && !video.description.trim().isEmpty()) return;
        final int epoch = a.engineEpoch;
        final boolean privateAtStart = a.privateMode;
        final String id = video.id;
        final String key = epoch + ":" + site.key.length() + ":" + site.key + id;
        if (a.detailCache.get(key) != null) return;
        a.detailPrefetch =
                RequestScope.submit(
                        a.details,
                        () -> {
                            try {
                                if (a.detailCache.get(key) != null) return;
                                String disk = readDetailDiskCache(a, site, id);
                                if (disk != null
                                        && epoch == a.engineEpoch
                                        && !Cms.listing(disk).videos.isEmpty()) {
                                    a.detailCache.put(key, disk);
                                    return;
                                }
                                String raw =
                                        a.detailFlights.get(
                                                key,
                                                () -> {
                                                    String cached = a.detailCache.get(key);
                                                    if (cached != null) return cached;
                                                    long[] phases = new long[2];
                                                    String fetched =
                                                            SourceGate.measured(
                                                                    phases,
                                                                    () -> source.detail(id));
                                                    if (fetched != null
                                                            && epoch == a.engineEpoch
                                                            && !Cms.listing(fetched)
                                                                    .videos
                                                                    .isEmpty()) {
                                                        a.detailCache.put(key, fetched);
                                                        if (!privateAtStart && !a.privateMode) {
                                                            writeDetailDiskCache(
                                                                    a, site, id, fetched);
                                                        }
                                                    }
                                                    return fetched;
                                                });
                            } catch (Throwable ignored) {
                            }
                        });
    }

    private static boolean hasPlayableDetailLines(Cms.Video video) {
        if (video == null || video.lines == null) return false;
        for (Cms.Line line : video.lines) {
            if (line != null && line.episodes != null && !line.episodes.isEmpty()) return true;
        }
        return false;
    }

    static void loadDetail(
            MainActivity a, Cms.Site site, String id, MainActivity.Done<Cms.Video> done) {
        loadDetail(a, site, id, done, null);
    }

    static void loadDetail(
            MainActivity a,
            Cms.Site site,
            String id,
            MainActivity.Done<Cms.Video> done,
            MainActivity.Done<Throwable> onError) {
        final int ticket = a.generation, epoch = a.engineEpoch;
        final TvSearchContext detailContext =
                new TvSearchContext(a.config, a.privateMode, a.engineEpoch);
        final String key = epoch + ":" + site.key.length() + ":" + site.key + id;
        final DetailRequest timing = new DetailRequest();
        Future<?> request =
                RequestScope.submit(
                        a.details,
                        () -> {
                            try {
                                timing.dispatched = SystemClock.elapsedRealtime();
                                String raw = a.detailCache.get(key);
                                if (raw != null) {
                                    Cms.Listing memListing = Cms.listing(raw);
                                    if (memListing.videos.isEmpty()
                                            || !hasPlayableDetailLines(memListing.videos.get(0))) {
                                        raw = null;
                                    }
                                }
                                if (raw == null) {
                                    String disk = readDetailDiskCache(a, site, id);
                                    if (disk != null) {
                                        Cms.Listing diskListing = Cms.listing(disk);
                                        if (!diskListing.videos.isEmpty()
                                                && hasPlayableDetailLines(
                                                        diskListing.videos.get(0))) {
                                            raw = disk;
                                            if (detailContext.matches(
                                                    a.config, a.privateMode, a.engineEpoch)) {
                                                a.detailCache.put(key, disk);
                                            }
                                        }
                                    }
                                }
                                timing.cached = raw != null;
                                if (raw == null) {
                                    final long[] phases = new long[2];
                                    raw =
                                            a.detailFlights.get(
                                                    key,
                                                    () -> {
                                                        String cached = a.detailCache.get(key);
                                                        if (cached != null) return cached;
                                                        SourceEngine source =
                                                                engine(a, site, detailContext);
                                                        timing.engineReady =
                                                                SystemClock.elapsedRealtime();
                                                        String fetched =
                                                                SourceGate.measured(
                                                                        phases,
                                                                        () -> source.detail(id));
                                                        return fetched;
                                                    });
                                    if (timing.engineReady == 0)
                                        timing.engineReady = SystemClock.elapsedRealtime();
                                    timing.gateWaitNanos = phases[0];
                                    timing.delegateNanos = phases[1];
                                    timing.returned = SystemClock.elapsedRealtime();
                                } else
                                    timing.engineReady =
                                            timing.returned = SystemClock.elapsedRealtime();
                                if (Thread.currentThread().isInterrupted()) return;
                                Cms.Listing listing = Cms.listing(raw);
                                if (listing.videos.isEmpty()) throw new IOException("来源没有返回影片详情");
                                timing.parsed = SystemClock.elapsedRealtime();
                                Cms.Video video = listing.videos.get(0);
                                if ((video.id == null || video.id.trim().isEmpty()) && id != null) {
                                    video.id = id.trim();
                                }
                                if (!timing.cached
                                        && hasPlayableDetailLines(video)
                                        && detailContext.matches(
                                                a.config, a.privateMode, a.engineEpoch)) {
                                    a.detailCache.put(key, raw);
                                    if (!a.privateMode) {
                                        writeDetailDiskCache(a, site, id, raw);
                                    }
                                }
                                a.ui.post(
                                        () -> {
                                            if (a.isFinishing()
                                                    || ticket != a.generation
                                                    || !detailContext.matches(
                                                            a.config, a.privateMode, a.engineEpoch))
                                                return;
                                            try {
                                                done.accept(video);
                                                a.root.postOnAnimation(timing::ready);
                                            } catch (Throwable error) {
                                                a.paragraph("详情数据无法显示，请返回后重试。");
                                            }
                                        });
                            } catch (Throwable error) {
                                if (Thread.currentThread().isInterrupted()) return;
                                a.ui.post(
                                        () -> {
                                            if (a.isFinishing()
                                                    || ticket != a.generation
                                                    || !detailContext.matches(
                                                            a.config, a.privateMode, a.engineEpoch))
                                                return;
                                            if (onError != null) {
                                                try {
                                                    onError.accept(error);
                                                    return;
                                                } catch (Throwable ignored) {
                                                }
                                            }
                                            View state = a.root.findViewWithTag("detail-loading");
                                            if (state instanceof TextView) {
                                                state.setVisibility(View.VISIBLE);
                                                ((TextView) state).setText(a.message(error));
                                            }
                                            LinearLayout target =
                                                    state != null
                                                                    && state.getParent()
                                                                            instanceof LinearLayout
                                                            ? (LinearLayout) state.getParent()
                                                            : a.body;
                                            a.addButton(
                                                    target, a.button("重试", "primary", a::refresh));
                                        });
                            }
                        });
        for (int i = a.pageRequests.size() - 1; i >= 0; i--) {
            if (a.pageRequests.get(i).isDone()) a.pageRequests.remove(i);
        }
        a.pageRequests.add(request);
    }

    static <T> void load(
            MainActivity a, String label, MainActivity.Work<T> task, MainActivity.Done<T> done) {
        final int ticket = a.generation;
        TextView loading = a.text(label, 17, MainActivity.MUTED);
        a.body.addView(loading);
        a.submitPage(
                () -> {
                    try {
                        T value = task.run();
                        a.ui.post(
                                () -> {
                                    if (a.isFinishing() || ticket != a.generation) return;
                                    a.body.removeView(loading);
                                    try {
                                        done.accept(value);
                                    } catch (Throwable e) {
                                        a.notice("数据格式不符合此版本支持的格式。");
                                    }
                                });
                    } catch (Throwable e) {
                        a.ui.post(
                                () -> {
                                    if (a.isFinishing() || ticket != a.generation) return;
                                    a.body.removeView(loading);
                                    a.paragraph(a.message(e));
                                    a.addButton(a.body, a.button("重试", "primary", a::refresh));
                                });
                    }
                });
    }

    static String message(Throwable e) {
        if (e == null) return "连接超时、来源不可达或数据格式不受支持。请检查配置与网络后重试。";
        String s = e.getMessage();
        if (e instanceof CspEngine.EngineException) return s;
        if (e instanceof com.pilipala.catpaw.CatPawHost.DrpySourceException
                && s != null
                && !s.isEmpty()) return s;
        if (e instanceof OutOfMemoryError) return "设备运行内存不足，已保护性中止加载。建议切换轻量片源。";
        if (e instanceof LinkageError) return "此片源扩展与当前电视系统版本不兼容，请切换其他片源。";
        if (e instanceof java.net.UnknownHostException) return "无法解析来源域名，请检查网络或切换其他来源。";
        if (e instanceof javax.net.ssl.SSLException) return "与来源建立安全连接失败，请检查设备时间或切换其他来源。";
        if (e instanceof java.net.SocketTimeoutException) return "来源响应超时，请重试或切换其他来源。";
        if (e instanceof java.net.ConnectException) return "无法连接来源服务，请重试或切换其他来源。";
        if (s != null
                && (s.startsWith("直播列表")
                        || s.startsWith("配置")
                        || s.startsWith("来源返回 HTTP")
                        || s.startsWith("来源没有")
                        || s.startsWith("来源重定向")
                        || s.startsWith("单页超过")
                        || s.startsWith("响应超过")
                        || s.startsWith("剧集返回")
                        || s.startsWith("媒体地址返回")
                        || s.startsWith("此剧集"))) return s;
        return "连接超时、来源不可达或数据格式不受支持。请检查配置与网络后重试。";
    }

    static void learnTitles(MainActivity a, List<Cms.Video> videos) {
        if (a.privateMode || a.switchingPrivacy) return;
        if (a.phonetic == null || videos == null || videos.isEmpty()) return;
        for (Cms.Video video : videos)
            if (video.title != null && !video.title.isEmpty()) a.pendingTitles.add(video.title);
        while (a.pendingTitles.size() > 400)
            a.pendingTitles.remove(a.pendingTitles.iterator().next());
        a.ui.removeCallbacks(a.learnPendingTitles);
        a.ui.postDelayed(a.learnPendingTitles, 500);
    }

    static void learnPendingTitles(MainActivity a) {
        List<String> titles = new ArrayList<>(a.pendingTitles);
        a.pendingTitles.clear();
        final PhoneticSearchIndex index = a.phonetic;
        final android.content.SharedPreferences target = a.prefs;
        if (index == null || titles.isEmpty() || a.privateMode || a.switchingPrivacy) return;
        final TvSearchContext context = new TvSearchContext(a.config, a.privateMode, a.engineEpoch);
        a.phoneticWork.execute(
                () -> {
                    if (!context.matches(a.config, a.privateMode, a.engineEpoch)) return;
                    final PhoneticSearchIndex.PreparedTitles prepared = index.prepareTitles(titles);
                    if (!context.matches(a.config, a.privateMode, a.engineEpoch)) return;
                    // Commit on the UI thread with the space switch, not between worker checks.
                    // A stale worker may finish parsing, but cannot mutate an index or persist it.
                    a.ui.post(
                            () -> {
                                if (a.isDestroyed()
                                        || a.isFinishing()
                                        || a.switchingPrivacy
                                        || a.phonetic != index
                                        || !context.matches(a.config, a.privateMode, a.engineEpoch))
                                    return;
                                // Merge with the latest committed cache here. Multiple workers can
                                // finish
                                // before either UI commit; a worker's earlier snapshot would lose a
                                // batch.
                                LinkedHashSet<String> values = new LinkedHashSet<>();
                                try {
                                    org.json.JSONArray previous =
                                            new org.json.JSONArray(
                                                    target.getString(
                                                            Prefs.PHONETIC_PUBLIC_TITLES_V2, "[]"));
                                    for (int i = 0; i < previous.length(); i++)
                                        values.add(previous.optString(i));
                                } catch (Exception ignored) {
                                }
                                values.addAll(titles);
                                while (values.size() > 400) values.remove(values.iterator().next());
                                index.learnPrepared(prepared);
                                target.edit()
                                        .putString(
                                                Prefs.PHONETIC_PUBLIC_TITLES_V2,
                                                new org.json.JSONArray(values).toString())
                                        .apply();
                            });
                });
    }

    static void onActivityFocusChanged(MainActivity a, boolean focus) {
        if (a == null) return;
        if (!focus) {
            if (SystemClock.elapsedRealtime() - lastConfigActionAt < 15000) {
                pendingConfigRefreshOnFocus = true;
            }
            return;
        }
        if (pendingConfigRefreshOnFocus) {
            pendingConfigRefreshOnFocus = false;
            a.ui.postDelayed(() -> refreshCurrentConfigCategory(a, null), 250);
        }
    }

    static void refreshCurrentConfigCategory(MainActivity a, Cms.Site targetSite) {
        if (a == null
                || a.isFinishing()
                || a.current == null
                || !a.current.home
                || a.config == null) return;
        String selKey = a.prefs.getString(Prefs.SELECTED_SITE, "");
        Cms.Site currentSite = null;
        for (Cms.Site s : a.config.sites) {
            if (s.key.equals(selKey)) {
                currentSite = s;
                break;
            }
        }
        if (currentSite == null || !isConfigOrNetdiskSite(currentSite)) return;
        if (targetSite != null
                && targetSite.key != null
                && !targetSite.key.equals(currentSite.key)) {
            return;
        }
        a.detailCache.clear();
        a.homeData.remove(currentSite.key);
        if (a.current.retainedHome != null) {
            a.current.retainedHome.reloadCurrentCategory();
        } else if (a.current.mobileHome != null && a.current.mobileHome.reloadCategory != null) {
            a.current.mobileHome.reloadCategory.run();
        }
    }

    static boolean isInternalActionCode(String s, String action) {
        if (s == null) return true;
        String trimmed = s.trim();
        if (trimmed.isEmpty()) return true;
        if (action != null && trimmed.equalsIgnoreCase(action.trim())) return true;
        return "LoginShow".equalsIgnoreCase(trimmed)
                || "pushCkShow".equalsIgnoreCase(trimmed)
                || "panSortShow".equalsIgnoreCase(trimmed)
                || "panSourceSortShow".equalsIgnoreCase(trimmed)
                || "null".equalsIgnoreCase(trimmed)
                || "{}".equals(trimmed)
                || "[]".equals(trimmed);
    }

    static void invokeConfigPlayerAction(MainActivity a, Cms.Site site, String flag, String id) {
        lastConfigActionAt = SystemClock.elapsedRealtime();
        pendingConfigRefreshOnFocus = false;
        CspEngine.syncAllPluginActivities(a);
        PluginDialogStyler.watch(a);
        final int ticket = a.generation;
        a.worker.execute(
                () -> {
                    try {
                        CspEngine.syncAllPluginActivities(a);
                        SourceEngine eng = a.engine(site);
                        CspEngine.syncAllPluginActivities(a);
                        final String resp = eng.player(flag, id);
                        a.ui.post(
                                () -> {
                                    if (ticket != a.generation || a.isFinishing()) return;
                                    a.ui.postDelayed(
                                            () -> {
                                                if (a.isFinishing() || ticket != a.generation)
                                                    return;
                                                if (!a.hasWindowFocus()) {
                                                    pendingConfigRefreshOnFocus = true;
                                                } else {
                                                    refreshCurrentConfigCategory(a, site);
                                                }
                                            },
                                            550);
                                    if (resp == null || resp.trim().isEmpty()) return;
                                    try {
                                        org.json.JSONObject obj = new org.json.JSONObject(resp);
                                        String msg =
                                                obj.optString("msg", obj.optString("message", ""));
                                        if (!msg.isEmpty() && !isInternalActionCode(msg, id)) {
                                            a.notice(msg);
                                        }
                                    } catch (Throwable ignored) {
                                    }
                                });
                    } catch (Throwable error) {
                        a.ui.post(
                                () -> {
                                    if (ticket == a.generation) a.notice(a.message(error));
                                });
                    }
                });
    }

    static void sourceAction(MainActivity a, Cms.Site site, String action) {
        sourceAction(a, site, action, false);
    }

    static void sourceAction(MainActivity a, Cms.Site site, String action, boolean preferDetail) {
        a.detailCache.clear();
        lastConfigActionAt = SystemClock.elapsedRealtime();
        pendingConfigRefreshOnFocus = false;
        CspEngine.syncAllPluginActivities(a);
        PluginDialogStyler.watch(a);
        final int ticket = a.generation;
        a.worker.execute(
                () -> {
                    try {
                        CspEngine.syncAllPluginActivities(a);
                        SourceEngine eng = a.engine(site);
                        CspEngine.syncAllPluginActivities(a);
                        String actResp;
                        boolean detailFallback = false;
                        if (eng.supportsCustomAction()) {
                            actResp = eng.action(action);
                        } else {
                            actResp = eng.detailAction(action);
                            detailFallback = true;
                        }
                        final String response = actResp;
                        final boolean usedDetailFallback = detailFallback;
                        a.ui.post(
                                () -> {
                                    if (ticket != a.generation || a.isFinishing()) return;
                                    a.ui.postDelayed(
                                            () -> {
                                                if (a.isFinishing() || ticket != a.generation)
                                                    return;
                                                if (!a.hasWindowFocus()) {
                                                    pendingConfigRefreshOnFocus = true;
                                                } else if (usedDetailFallback) {
                                                    refreshCurrentConfigCategory(a, site);
                                                }
                                            },
                                            550);
                                    if (response == null || response.trim().isEmpty()) return;
                                    try {
                                        org.json.JSONObject result =
                                                new org.json.JSONObject(response);
                                        if (result.has("list")) {
                                            Cms.Listing list = Cms.listing(response);
                                            if (usedDetailFallback) {
                                                if (list.videos.size() == 1) {
                                                    Cms.Video v = list.videos.get(0);
                                                    for (Cms.Line line : v.lines) {
                                                        if ("Config".equalsIgnoreCase(line.name)
                                                                && !line.episodes.isEmpty()) {
                                                            if (line.episodes.size() == 1) {
                                                                invokeConfigPlayerAction(
                                                                        a,
                                                                        site,
                                                                        line.name,
                                                                        line.episodes.get(0).url);
                                                            } else {
                                                                String[] epNames =
                                                                        new String
                                                                                [line.episodes
                                                                                        .size()];
                                                                for (int i = 0;
                                                                        i < line.episodes.size();
                                                                        i++) {
                                                                    epNames[i] =
                                                                            line.episodes.get(i)
                                                                                    .name;
                                                                }
                                                                new AppDialog.Builder(a)
                                                                        .setTitle(
                                                                                v.title != null
                                                                                                && !v
                                                                                                        .title
                                                                                                        .isEmpty()
                                                                                        ? v.title
                                                                                        : site.name)
                                                                        .setItems(
                                                                                epNames,
                                                                                (d, idx) ->
                                                                                        invokeConfigPlayerAction(
                                                                                                a,
                                                                                                site,
                                                                                                line.name,
                                                                                                line
                                                                                                        .episodes
                                                                                                        .get(
                                                                                                                idx)
                                                                                                        .url))
                                                                        .setNegativeButton(
                                                                                "关闭", null)
                                                                        .show();
                                                            }
                                                            return;
                                                        }
                                                    }
                                                }
                                                return;
                                            }
                                            if (list.videos.size() == 1
                                                    && (list.videos.get(0).title.contains("刷新配置中心")
                                                            || "配置中心"
                                                                    .equals(
                                                                            list.videos.get(0)
                                                                                    .remarks))) {
                                                return;
                                            }
                                            String[] titles = new String[list.videos.size()];
                                            for (int i = 0; i < list.videos.size(); i++)
                                                titles[i] = list.videos.get(i).title;
                                            new AppDialog.Builder(a)
                                                    .setTitle(site.name)
                                                    .setItems(
                                                            titles,
                                                            (dialog, index) ->
                                                                    a.openListing(
                                                                            site,
                                                                            list.videos.get(index)))
                                                    .setNegativeButton("关闭", null)
                                                    .show();
                                        } else if (handleStructuredActionJson(a, site, result)) {
                                            return;
                                        } else {
                                            String msg =
                                                    result.optString(
                                                            "msg", result.optString("message", ""));
                                            if (!msg.isEmpty()
                                                    && !isInternalActionCode(msg, action)) {
                                                a.notice(msg);
                                            } else if (!usedDetailFallback
                                                    && !isInternalActionCode(response, action)) {
                                                a.notice(response);
                                            }
                                        }
                                    } catch (Throwable ignored) {
                                        if (!usedDetailFallback
                                                && !isInternalActionCode(response, action)) {
                                            a.notice(response);
                                        }
                                    }
                                });
                    } catch (Throwable error) {
                        a.ui.post(
                                () -> {
                                    if (ticket == a.generation) a.notice(a.message(error));
                                });
                    }
                });
    }

    /**
     * Renders TVBox / FongMi / OK structured JSON action responses ({@code actionId}, {@code type}:
     * {@code input}, {@code edit}, {@code multiInput}, {@code multiInputX}, {@code menu}, {@code
     * msg}, {@code help}, {@code qrcode}) inside a strictly bounded native {@link AppDialog}
     * instead of dumping raw JSON text.
     */
    static boolean isStructuredActionJson(org.json.JSONObject result) {
        if (result == null) return false;
        String type = result.optString("type", "").trim().toLowerCase(java.util.Locale.ROOT);
        if ("input".equals(type)
                || "edit".equals(type)
                || "multiinput".equals(type)
                || "multiinputx".equals(type)
                || "menu".equals(type)
                || "msg".equals(type)
                || "help".equals(type)
                || "qrcode".equals(type)) {
            return true;
        }
        return result.has("actionId")
                && (result.has("option") || result.has("initValue") || result.has("imageUrl"));
    }

    static boolean handleStructuredActionJson(
            final MainActivity a, final Cms.Site site, final org.json.JSONObject result) {
        if (!isStructuredActionJson(result)) return false;
        final String actionId = result.optString("actionId", "").trim();
        final String type = result.optString("type", "").trim().toLowerCase(java.util.Locale.ROOT);
        final String title =
                !result.optString("title", "").trim().isEmpty()
                        ? result.optString("title", "").trim()
                        : (site != null ? site.name : "配置中心");
        final String msg = result.optString("msg", result.optString("tip", "")).trim();

        if ("msg".equals(type) || "help".equals(type)) {
            new AppDialog.Builder(a)
                    .setTitle(title)
                    .setMessage(msg.isEmpty() ? "操作已完成" : msg)
                    .setPositiveButton("知道了", null)
                    .show();
            return true;
        }

        if ("qrcode".equals(type) || !result.optString("imageUrl", "").trim().isEmpty()) {
            String qrImgUrl = result.optString("imageUrl", "").trim();
            String qrText = result.optString("url", result.optString("qrcode", "")).trim();
            if (NetdiskQrBubble.tryShowForStructuredAction(a, title, msg, qrImgUrl, qrText)) {
                return true;
            }
            android.widget.LinearLayout box = a.vertical();
            box.setGravity(android.view.Gravity.CENTER_HORIZONTAL);
            if (!msg.isEmpty()) {
                android.widget.TextView mt = a.text(msg, 13f, 0xffd0d6e2);
                mt.setGravity(android.view.Gravity.CENTER);
                mt.setPadding(0, 0, 0, a.dp(10));
                box.addView(mt);
            }
            android.widget.ImageView iv = new android.widget.ImageView(a);
            int sz = a.dp(a.isTvDevice() ? 164 : 188);
            iv.setScaleType(android.widget.ImageView.ScaleType.FIT_CENTER);
            android.graphics.drawable.GradientDrawable frame =
                    new android.graphics.drawable.GradientDrawable();
            frame.setColor(0xffffffff);
            frame.setCornerRadius(a.dp(14));
            iv.setBackground(frame);
            iv.setPadding(a.dp(8), a.dp(8), a.dp(8), a.dp(8));
            box.addView(iv, new android.widget.LinearLayout.LayoutParams(sz, sz));
            if (!qrText.isEmpty()) {
                try {
                    android.graphics.Bitmap bmp = TvQrInputHelper.renderQrBitmap(qrText, sz);
                    if (bmp != null) iv.setImageBitmap(bmp);
                } catch (Exception ignored) {
                }
            } else if (!qrImgUrl.isEmpty()) {
                a.poster(qrImgUrl, iv);
            }
            new AppDialog.Builder(a)
                    .setTitle(title)
                    .setView(box)
                    .setPositiveButton("关闭", null)
                    .show();
            return true;
        }

        if ("menu".equals(type)) {
            org.json.JSONArray opts = result.optJSONArray("option");
            if (opts == null || opts.length() == 0) return false;
            final String[] labels = new String[opts.length()];
            final String[] values = new String[opts.length()];
            for (int i = 0; i < opts.length(); i++) {
                org.json.JSONObject o = opts.optJSONObject(i);
                if (o != null) {
                    labels[i] = o.optString("name", o.optString("title", o.optString("value", "")));
                    values[i] = o.optString("action", o.optString("value", labels[i]));
                } else {
                    labels[i] = opts.optString(i, "");
                    values[i] = labels[i];
                }
            }
            new AppDialog.Builder(a)
                    .setTitle(title)
                    .setMessage(msg.isEmpty() ? null : msg)
                    .setItems(
                            labels,
                            (d, idx) -> {
                                String picked = values[idx];
                                if (picked != null && picked.trim().startsWith("{")) {
                                    sourceAction(a, site, picked);
                                } else if (!actionId.isEmpty()) {
                                    try {
                                        org.json.JSONObject payload = new org.json.JSONObject();
                                        payload.put("actionId", actionId);
                                        payload.put("value", picked);
                                        sourceAction(a, site, payload.toString());
                                    } catch (Exception ignored) {
                                    }
                                } else if (picked != null && !picked.isEmpty()) {
                                    sourceAction(a, site, picked);
                                }
                            })
                    .setNegativeButton("取消", null)
                    .show();
            return true;
        }

        if ("multiinput".equals(type) || "multiinputx".equals(type)) {
            org.json.JSONArray opts = result.optJSONArray("option");
            if (opts == null || opts.length() == 0) return false;
            android.widget.LinearLayout form = a.vertical();
            final java.util.List<String> keys = new java.util.ArrayList<>();
            final java.util.List<android.widget.EditText> inputs = new java.util.ArrayList<>();
            for (int i = 0; i < opts.length(); i++) {
                org.json.JSONObject o = opts.optJSONObject(i);
                if (o == null) continue;
                String k = o.optString("id", o.optString("key", "field" + i));
                String lbl = o.optString("name", k);
                String val = o.optString("value", o.optString("initValue", ""));
                String hint = o.optString("tip", lbl);
                android.widget.TextView labelTv = a.text(lbl, 12.5f, MainActivity.MUTED);
                labelTv.setPadding(0, i > 0 ? a.dp(8) : 0, 0, a.dp(4));
                form.addView(labelTv);
                android.widget.EditText et = new android.widget.EditText(a);
                et.setText(val);
                et.setHint(hint);
                et.setTextColor(MainActivity.WHITE);
                et.setHintTextColor(0x88cbd5e1);
                et.setSingleLine(true);
                et.setPadding(a.dp(12), a.dp(9), a.dp(12), a.dp(9));
                android.graphics.drawable.GradientDrawable bg =
                        new android.graphics.drawable.GradientDrawable();
                bg.setColor(0x28ffffff);
                bg.setCornerRadius(a.dp(10));
                bg.setStroke(Math.max(1, a.dp(1)), 0x44ffffff);
                et.setBackground(bg);
                android.view.View wrapped = TvQrInputHelper.wrap(a, et, lbl);
                form.addView(wrapped, new android.widget.LinearLayout.LayoutParams(-1, -2));
                keys.add(k);
                inputs.add(et);
            }
            new AppDialog.Builder(a)
                    .setTitle(title)
                    .setMessage(msg.isEmpty() ? null : msg)
                    .setView(form)
                    .setNegativeButton("取消", null)
                    .setPositiveButton(
                            "确定",
                            (d, w) -> {
                                try {
                                    org.json.JSONObject payload = new org.json.JSONObject();
                                    if (!actionId.isEmpty()) payload.put("actionId", actionId);
                                    for (int i = 0; i < keys.size(); i++) {
                                        CharSequence cs = inputs.get(i).getText();
                                        payload.put(keys.get(i), cs == null ? "" : cs.toString());
                                    }
                                    sourceAction(a, site, payload.toString());
                                } catch (Exception ignored) {
                                }
                            })
                    .show();
            return true;
        }

        final String idKey = result.optString("id", "value");
        final String initVal = result.optString("initValue", result.optString("value", ""));
        final String tip = result.optString("tip", msg.isEmpty() ? "请输入内容" : msg);
        android.widget.LinearLayout form = a.vertical();
        android.widget.EditText et = new android.widget.EditText(a);
        et.setText(initVal);
        et.setHint(tip);
        et.setTextColor(MainActivity.WHITE);
        et.setHintTextColor(0x88cbd5e1);
        et.setSingleLine(false);
        et.setMaxLines(4);
        et.setPadding(a.dp(12), a.dp(10), a.dp(12), a.dp(10));
        android.graphics.drawable.GradientDrawable bg =
                new android.graphics.drawable.GradientDrawable();
        bg.setColor(0x28ffffff);
        bg.setCornerRadius(a.dp(12));
        bg.setStroke(Math.max(1, a.dp(1)), 0x44ffffff);
        et.setBackground(bg);
        form.addView(
                TvQrInputHelper.wrap(a, et, title),
                new android.widget.LinearLayout.LayoutParams(-1, -2));
        new AppDialog.Builder(a)
                .setTitle(title)
                .setMessage(msg.isEmpty() ? null : msg)
                .setView(form)
                .setNegativeButton("取消", null)
                .setPositiveButton(
                        "确定",
                        (d, w) -> {
                            try {
                                org.json.JSONObject payload = new org.json.JSONObject();
                                if (!actionId.isEmpty()) payload.put("actionId", actionId);
                                String val = et.getText() == null ? "" : et.getText().toString();
                                payload.put(idKey, val);
                                if (!"value".equals(idKey)) payload.put("value", val);
                                sourceAction(a, site, payload.toString());
                            } catch (Exception ignored) {
                            }
                        })
                .show();
        return true;
    }

    static void pickDocument(MainActivity a, int requestCode, String missingPickerNotice) {
        try {
            Intent intent = new Intent(Intent.ACTION_OPEN_DOCUMENT);
            intent.addCategory(Intent.CATEGORY_OPENABLE);
            intent.setType("*/*");
            a.startActivityForResult(intent, requestCode);
        } catch (Exception error) {
            a.notice(missingPickerNotice);
        }
    }

    static void addressImportDialog(MainActivity a) {
        String existingOrigin = a.prefs.getString(Prefs.ORIGIN, "");
        if (SubscriptionManager.isMergedOrigin(existingOrigin)) existingOrigin = "";
        AddressInput input =
                new AddressInput(a, "https://…/config.json（支持每行一个，多源自动分组）", existingOrigin, true);
        LinearLayout container = a.vertical();
        container.addView(input, new LinearLayout.LayoutParams(-1, -2));
        final android.widget.CheckBox appendCheck = new android.widget.CheckBox(a);
        boolean hasExisting = a.config != null && !a.config.sites.isEmpty();
        if (hasExisting) {
            appendCheck.setText("追加到现有片源并按源自动分组（多源线路同时显示；取消勾选则替换）");
            appendCheck.setTextColor(MainActivity.WHITE);
            appendCheck.setTextSize(13f);
            appendCheck.setChecked(true);
            LinearLayout.LayoutParams chkLp = new LinearLayout.LayoutParams(-1, -2);
            chkLp.topMargin = a.dp(8);
            container.addView(appendCheck, chkLp);
        }
        AppDialog d =
                new AppDialog.Builder(a)
                        .setTitle("导入配置")
                        .setView(container)
                        .setNegativeButton("取消", null)
                        .setNeutralButton("选择本地文件", (x, y) -> a.pickConfig())
                        .setPositiveButton("导入地址", null)
                        .create();
        final String existingOriginFinal = existingOrigin;
        d.setOnShowListener(
                x ->
                        d.getButton(-1)
                                .setOnClickListener(
                                        view -> {
                                            String rawAddress = input.value();
                                            final List<SubscriptionManager.ImportSpec> specs;
                                            try {
                                                specs =
                                                        SubscriptionManager.parseImportSpecsStrict(
                                                                rawAddress);
                                            } catch (Exception err) {
                                                input.invalid(
                                                        err.getMessage() != null
                                                                ? err.getMessage()
                                                                : "请输入 HTTP(S) 配置地址");
                                                return;
                                            }
                                            boolean refreshingSameSingle =
                                                    specs.size() == 1
                                                            && !existingOriginFinal.isEmpty()
                                                            && existingOriginFinal.equals(
                                                                    specs.get(0).url.trim());
                                            final boolean appendMerge =
                                                    hasExisting
                                                            && appendCheck.isChecked()
                                                            && !refreshingSameSingle;
                                            d.dismiss();
                                            if (specs.size() == 1 && !appendMerge) {
                                                final String onlyUrl = specs.get(0).url;
                                                a.open(
                                                        new MainActivity.Screen(
                                                                () -> {
                                                                    a.renderPage(
                                                                            "正在导入",
                                                                            "IMPORT CONFIGURATION");
                                                                    a.load(
                                                                            "连接配置并读取来源…",
                                                                            () -> {
                                                                                String raw =
                                                                                        fetchImport(
                                                                                                a,
                                                                                                onlyUrl);
                                                                                return Cms
                                                                                        .parseConfig(
                                                                                                raw,
                                                                                                importOrigin(
                                                                                                        onlyUrl));
                                                                            },
                                                                            c ->
                                                                                    a.saveConfig(
                                                                                            c,
                                                                                            importOrigin(
                                                                                                    onlyUrl)));
                                                                }),
                                                        true);
                                                return;
                                            }
                                            a.open(
                                                    new MainActivity.Screen(
                                                            () -> {
                                                                a.renderPage(
                                                                        "多源分组导入",
                                                                        "MULTI-SOURCE IMPORT");
                                                                a.load(
                                                                        "正在读取 "
                                                                                + specs.size()
                                                                                + " 个订阅源并自动分组…",
                                                                        () ->
                                                                                fetchAndMergeImportSpecs(
                                                                                        a,
                                                                                        specs,
                                                                                        appendMerge),
                                                                        merged -> {
                                                                            a.saveConfig(
                                                                                    merged.config,
                                                                                    merged.origin);
                                                                            a.toast(
                                                                                    "已导入 "
                                                                                            + merged.sourceCount
                                                                                            + " 个源并自动分组（共 "
                                                                                            + merged
                                                                                                    .config
                                                                                                    .sites
                                                                                                    .size()
                                                                                            + " 条线路）");
                                                                        });
                                                            }),
                                                    true);
                                        }));
        d.show();
    }

    static String extractGroupRawJson(Cms.Config cfg, String groupName) {
        if (cfg == null || cfg.sites == null || cfg.sites.isEmpty()) return "";
        String target = groupName == null ? "" : groupName.trim();
        try {
            org.json.JSONArray arr = new org.json.JSONArray();
            for (Cms.Site s : cfg.sites) {
                if (s == null) continue;
                String g = SourcePicker.siteGroup(s);
                if (!target.isEmpty() && !target.equals(g)) continue;
                org.json.JSONObject obj =
                        new org.json.JSONObject()
                                .put("key", s.key)
                                .put("name", s.name)
                                .put("group", g)
                                .put("type", s.type)
                                .put("api", s.api)
                                .put("searchable", s.searchable ? 1 : 0);
                String jar =
                        s.jar != null && !s.jar.isEmpty()
                                ? s.jar
                                : (cfg.spider == null ? "" : cfg.spider);
                if (!jar.isEmpty()) obj.put("jar", jar);
                if (s.playUrl != null && !s.playUrl.isEmpty()) obj.put("playUrl", s.playUrl);
                if (s.ext != null) obj.put("ext", s.ext);
                arr.put(obj);
            }
            if (arr.length() == 0) return "";
            org.json.JSONObject root = new org.json.JSONObject().put("sites", arr);
            if (cfg.spider != null && !cfg.spider.isEmpty()) root.put("spider", cfg.spider);
            return root.toString();
        } catch (Exception ignored) {
            return "";
        }
    }

    /**
     * Fetches one or more subscription URLs (optionally appending onto the currently active
     * config), persists each individual HTTP subscription in {@link ConfigLibrary}, and merges all
     * bundles into an auto-grouped {@link Cms.Config}.
     */
    static SubscriptionManager.MergedResult fetchAndMergeImportSpecs(
            MainActivity a, List<SubscriptionManager.ImportSpec> specs, boolean appendToExisting)
            throws Exception {
        if (specs == null || specs.isEmpty()) {
            throw new IOException("请至少提供一个有效的订阅地址");
        }
        ConfigLibrary library = new ConfigLibrary(a.configStore.directory);
        long now = System.currentTimeMillis();
        java.util.LinkedHashMap<String, SubscriptionManager.SourceBundle> ordered =
                new java.util.LinkedHashMap<String, SubscriptionManager.SourceBundle>();

        if (appendToExisting
                && a.config != null
                && a.config.raw != null
                && !a.config.raw.trim().isEmpty()) {
            List<SubscriptionManager.MultiSourceMeta> existingMeta =
                    SubscriptionManager.readMultiSourceMeta(a.config.raw);
            if (!existingMeta.isEmpty()) {
                java.util.Map<String, ConfigLibrary.Entry> byOrigin =
                        new java.util.HashMap<String, ConfigLibrary.Entry>();
                try {
                    for (ConfigLibrary.Entry e : library.entries()) {
                        if (e != null && e.origin != null && !e.origin.isEmpty()) {
                            byOrigin.put(e.origin.trim(), e);
                        }
                    }
                } catch (Exception ignored) {
                }
                for (SubscriptionManager.MultiSourceMeta m : existingMeta) {
                    ConfigLibrary.Entry saved = byOrigin.get(m.url);
                    String mapKey = m.url.isEmpty() ? ("existing:" + ordered.size()) : m.url;
                    if (saved != null) {
                        try {
                            String raw = library.raw(saved);
                            ordered.put(
                                    mapKey,
                                    new SubscriptionManager.SourceBundle(
                                            m.name, m.url, raw, saved.updated));
                            continue;
                        } catch (Exception ignored) {
                        }
                    }
                    // Fallback: preserve existing sites for this group directly from active config
                    // so local/unindexed subscription lines are never dropped when appending.
                    String synthRaw = extractGroupRawJson(a.config, m.name);
                    if (!synthRaw.isEmpty()) {
                        ordered.put(
                                mapKey,
                                new SubscriptionManager.SourceBundle(
                                        m.name, m.url, synthRaw, m.updated));
                    }
                }
            }
            if (ordered.isEmpty()) {
                String prevOrigin = a.configOrigin == null ? "" : a.configOrigin.trim();
                String prevName = configName(a.config);
                String mapKey = prevOrigin.isEmpty() ? "existing:0" : prevOrigin;
                ordered.put(
                        mapKey,
                        new SubscriptionManager.SourceBundle(
                                prevName, prevOrigin, a.config.raw, now));
            }
        }

        int succeeded = 0;
        Exception lastError = null;
        for (SubscriptionManager.ImportSpec spec : specs) {
            try {
                String origin = importOrigin(spec.url);
                String fetched = fetchImport(a, spec.url);
                Cms.Config parsed = Cms.parseConfig(fetched, origin);
                String effectiveOrigin =
                        !parsed.warehouse.isEmpty()
                                ? parsed.warehouse
                                : (!parsed.origin.isEmpty() ? parsed.origin : origin);
                String savedName = !spec.name.isEmpty() ? spec.name : configName(parsed);
                if (Cms.isHttp(effectiveOrigin)) {
                    try {
                        library.remember(parsed.raw, effectiveOrigin, savedName, "", now);
                    } catch (Exception ignored) {
                    }
                }
                String mapKey =
                        effectiveOrigin.isEmpty() ? ("spec:" + ordered.size()) : effectiveOrigin;
                ordered.put(
                        mapKey,
                        new SubscriptionManager.SourceBundle(
                                spec.name.isEmpty() ? savedName : spec.name,
                                effectiveOrigin,
                                parsed.raw,
                                now));
                succeeded++;
            } catch (Exception err) {
                lastError = err;
                AppLog.w("SourceController", "Batch import source failed: " + spec.url, err);
            }
        }
        if (succeeded == 0) {
            if (lastError != null) throw lastError;
            throw new IOException("未能成功读取任何订阅源，请检查地址与网络");
        }
        return SubscriptionManager.mergeSources(
                new ArrayList<SubscriptionManager.SourceBundle>(ordered.values()));
    }

    /** Merges user-selected saved subscriptions from {@link ConfigLibrary} into auto-grouped tabs. */
    static void mergeSavedSubscriptions(
            final MainActivity a, final List<ConfigLibrary.Entry> chosen) {
        if (a == null || chosen == null || chosen.isEmpty()) return;
        final ConfigLibrary library = new ConfigLibrary(a.configStore.directory);
        a.toast("正在合并 " + chosen.size() + " 个订阅并自动分组…");
        a.worker.execute(
                () -> {
                    try {
                        List<SubscriptionManager.SourceBundle> bundles =
                                new ArrayList<SubscriptionManager.SourceBundle>();
                        for (ConfigLibrary.Entry entry : chosen) {
                            if (entry == null) continue;
                            String raw = library.raw(entry);
                            bundles.add(
                                    new SubscriptionManager.SourceBundle(
                                            entry.name, entry.origin, raw, entry.updated));
                        }
                        final SubscriptionManager.MergedResult merged =
                                SubscriptionManager.mergeSources(bundles);
                        a.ui.post(
                                () -> {
                                    if (a.isFinishing() || a.isDestroyed()) return;
                                    try {
                                        saveConfig(a, merged.config, merged.origin);
                                        a.toast(
                                                "已合并 "
                                                        + merged.sourceCount
                                                        + " 个订阅并自动分组（共 "
                                                        + merged.config.sites.size()
                                                        + " 条线路）");
                                        SourcePicker.show(a);
                                    } catch (Exception err) {
                                        a.notice("合并保存失败：" + a.message(err));
                                    }
                                });
                    } catch (Exception err) {
                        a.ui.post(
                                () -> {
                                    if (!a.isFinishing()) {
                                        a.notice("合并订阅失败：" + a.message(err));
                                    }
                                });
                    }
                });
    }

    private static final java.util.concurrent.atomic.AtomicBoolean AUTO_UPDATE_RUNNING =
            new java.util.concurrent.atomic.AtomicBoolean(false);

    static String subscriptionAutoUpdateSummary(MainActivity a) {
        if (a == null || a.prefs == null) return "每天自动检查并更新导入的 HTTP 订阅源";
        String lastStatus = a.prefs.getString(Prefs.SUBSCRIPTION_LAST_AUTO_STATUS, "");
        if (!lastStatus.isEmpty()) return lastStatus;
        long lastTs = a.prefs.getLong(Prefs.SUBSCRIPTION_LAST_AUTO_UPDATE, 0L);
        if (lastTs > 0L) {
            return "上次检查：" + formatShortTimestamp(lastTs) + " · 点击立即刷新全部订阅";
        }
        return "每天自动更新已导入的订阅源 · 点击立即刷新";
    }

    static String formatShortTimestamp(long epochMs) {
        if (epochMs <= 1L) return "";
        try {
            return new java.text.SimpleDateFormat("MM-dd HH:mm", java.util.Locale.ROOT)
                    .format(new java.util.Date(epochMs));
        } catch (Throwable ignored) {
            return "";
        }
    }

    /**
     * Checks imported HTTP(S) subscriptions daily (every 24h) or on explicit manual request,
     * refreshes stale configs atomically without interrupting active video playback, and preserves
     * user site edits and multi-source groups.
     */
    static void runDailyAutoUpdateIfNeeded(final MainActivity a, final boolean force) {
        if (a == null
                || a.privateMode
                || a.prefs == null
                || a.configStore == null
                || a.isFinishing()
                || a.isDestroyed()) {
            return;
        }
        if (!force && !a.prefs.getBoolean(Prefs.SUBSCRIPTION_AUTO_UPDATE, true)) {
            return;
        }
        final long now = System.currentTimeMillis();
        if (!force) {
            long lastGlobal = a.prefs.getLong(Prefs.SUBSCRIPTION_LAST_AUTO_UPDATE, 0L);
            if (lastGlobal > 0L && !SubscriptionManager.isDueForDailyUpdate(lastGlobal, now)) {
                return;
            }
        }
        if (!AUTO_UPDATE_RUNNING.compareAndSet(false, true)) {
            if (force) a.toast("正在刷新订阅源，请稍候…");
            return;
        }
        if (force) {
            a.toast("正在检查并更新全部订阅源…");
        }
        final String snapshotOrigin = a.configOrigin == null ? "" : a.configOrigin;
        final String snapshotRaw = a.config != null && a.config.raw != null ? a.config.raw : "";
        final ConfigLibrary library = new ConfigLibrary(a.configStore.directory);
        a.worker.execute(
                () -> {
                    try {
                        final SubscriptionManager.RefreshSummary summary =
                                SubscriptionManager.refreshDueSubscriptions(
                                        library,
                                        snapshotOrigin,
                                        snapshotRaw,
                                        now,
                                        force,
                                        url -> fetchImport(a, url));
                        String stamp = formatShortTimestamp(now);
                        String statusText;
                        if (summary.checkedCount == 0) {
                            statusText = stamp + " · 暂无需要更新的在线订阅";
                        } else if (summary.updatedCount > 0) {
                            statusText =
                                    stamp
                                            + " · 已更新 "
                                            + summary.updatedCount
                                            + "/"
                                            + summary.checkedCount
                                            + " 个订阅";
                        } else if (summary.failedCount == summary.checkedCount) {
                            statusText = stamp + " · 检查失败（请检查网络）";
                        } else {
                            statusText = stamp + " · 已检查 " + summary.checkedCount + " 个订阅，均为最新";
                        }
                        if (summary.checkedCount == 0
                                || summary.failedCount < summary.checkedCount) {
                            a.prefs
                                    .edit()
                                    .putLong(Prefs.SUBSCRIPTION_LAST_AUTO_UPDATE, now)
                                    .putString(Prefs.SUBSCRIPTION_LAST_AUTO_STATUS, statusText)
                                    .apply();
                        } else {
                            a.prefs
                                    .edit()
                                    .putString(Prefs.SUBSCRIPTION_LAST_AUTO_STATUS, statusText)
                                    .apply();
                        }

                        if (summary.activeChanged && !summary.updatedActiveRaw.isEmpty()) {
                            final Cms.Config fresh =
                                    Cms.parseConfig(
                                            summary.updatedActiveRaw, summary.updatedActiveOrigin);
                            a.configStore.write(fresh.raw);
                            a.ui.post(
                                    () -> {
                                        if (a.isFinishing() || a.isDestroyed()) return;
                                        boolean playingNow =
                                                a.player != null
                                                        || (a.current != null && a.current.player);
                                        boolean searchingOrConfiguring =
                                                a.searchScreen != null
                                                        || (a.accountDialog != null
                                                                && a.accountDialog.isShowing());
                                        if (!playingNow && !searchingOrConfiguring) {
                                            SourcePicker.applyEdits(
                                                    a, fresh, summary.updatedActiveOrigin);
                                            closeEngines(a);
                                            a.config = fresh;
                                            a.configOrigin = summary.updatedActiveOrigin;
                                            if (a.current != null && a.current.home) {
                                                a.refresh();
                                            }
                                            a.toast("已自动更新 " + summary.updatedCount + " 个订阅源");
                                        } else {
                                            AppLog.i(
                                                    "SourceController",
                                                    "Daily subscription update saved; deferring live reload during active playback/search");
                                        }
                                    });
                        } else if (force) {
                            final String msg =
                                    summary.checkedCount == 0
                                            ? "当前没有可在线刷新的 HTTP 订阅源"
                                            : summary.updatedCount > 0
                                                    ? ("已更新 " + summary.updatedCount + " 个订阅源")
                                                    : summary.failedCount == summary.checkedCount
                                                            ? "订阅刷新失败，原配置已保留"
                                                            : "全部订阅源已是最新（共检查 "
                                                                    + summary.checkedCount
                                                                    + " 个）";
                            a.ui.post(
                                    () -> {
                                        if (!a.isFinishing()) {
                                            a.toast(msg);
                                            if (a.current != null && !a.current.player) {
                                                a.refresh();
                                            }
                                        }
                                    });
                        }
                    } catch (Throwable err) {
                        AppLog.w("SourceController", "Subscription auto-update failed", err);
                        if (force) {
                            a.ui.post(
                                    () -> {
                                        if (!a.isFinishing()) {
                                            a.toast("订阅刷新失败：" + a.message(err));
                                        }
                                    });
                        }
                    } finally {
                        AUTO_UPDATE_RUNNING.set(false);
                    }
                });
    }

    static void onActivityResult(MainActivity a, int request, int result, Intent data) {
        if (request == UpdateScreen.INSTALL) {
            UpdateScreen.result(a);
            return;
        }
        if (request == LocalDriveScanner.REQ_LOCAL_DRIVE_TREE) {
            if (result == Activity.RESULT_OK && data != null && data.getData() != null) {
                TvLocalDriveScreen.onTreeSelected(a, data);
            }
            return;
        }
        if (request >= 44 && request <= 46) {
            if (result == Activity.RESULT_OK && data != null && data.getData() != null)
                SettingsScreen.result(a, request, data.getData());
            return;
        }
        if (request == 43
                && result == Activity.RESULT_OK
                && data != null
                && data.getData() != null) {
            final PlaybackControls controls = a.playbackControls;
            if (controls != null) {
                Uri file = data.getData();
                a.worker.execute(
                        () -> {
                            try (InputStream in = a.getContentResolver().openInputStream(file)) {
                                String text = Cms.read(in, 8 * 1024 * 1024);
                                a.ui.post(
                                        () -> {
                                            if (controls == a.playbackControls) {
                                                controls.loadLocalDanmakuText(text);
                                            }
                                        });
                            } catch (Exception error) {
                                AppLog.w("SourceController", "load danmaku file failed", error);
                                a.ui.post(() -> a.notice("弹幕文件无法读取。"));
                            }
                        });
            }
            return;
        }
        if (request == 42
                && result == Activity.RESULT_OK
                && data != null
                && data.getData() != null) {
            Uri subtitle = data.getData();
            if (a.player != null && a.prepared) {
                String name = "外挂字幕";
                try (android.database.Cursor cursor =
                        a.getContentResolver()
                                .query(
                                        subtitle,
                                        new String[] {
                                            android.provider.OpenableColumns.DISPLAY_NAME
                                        },
                                        null,
                                        null,
                                        null)) {
                    if (cursor != null && cursor.moveToFirst()) name = cursor.getString(0);
                } catch (Exception ignored) {
                }
                try {
                    a.player.addExternalSubtitle(
                            subtitle, name, MediaOptions.subtitleMime(name, ""));
                    a.toast("已导入字幕");
                } catch (Exception error) {
                    AppLog.w("SourceController", "load subtitle file failed", error);
                    a.notice("字幕无法读取，请选择 SRT、VTT、ASS 或 TTML 文件。");
                }
            }
            return;
        }
        if ((request == 41 || request == 47)
                && result == Activity.RESULT_OK
                && data != null
                && data.getData() != null) {
            importLocalUri(a, data.getData(), request == 47);
        }
    }

    static void pickLiveSource(MainActivity a) {
        pickDocument(a, 47, "这台设备没有文件选择器，请使用网址或剪贴板导入直播源。");
    }

    static void upsertCustomLiveSource(MainActivity a, String name, String url) {
        if (a == null || a.prefs == null || url == null || url.trim().isEmpty()) return;
        java.util.List<LiveQualityPolicy.CustomLiveSource> list =
                LiveQualityPolicy.parseCustomSources(
                        a.prefs.getString(Prefs.LIVE_SOURCES_JSON, ""),
                        a.prefs.getString(Prefs.LIVE_URL, ""),
                        a.prefs.getString(Prefs.LIVE_NAME, ""));
        String cleanUrl = url.trim();
        String cleanName = name == null || name.trim().isEmpty() ? "自定义直播源" : name.trim();
        java.util.List<LiveQualityPolicy.CustomLiveSource> updated = new java.util.ArrayList<>();
        updated.add(new LiveQualityPolicy.CustomLiveSource(cleanName, cleanUrl));
        for (LiveQualityPolicy.CustomLiveSource item : list) {
            if (!item.url.equals(cleanUrl) && updated.size() < 16) {
                updated.add(item);
            }
        }
        a.prefs
                .edit()
                .putString(Prefs.LIVE_SOURCES_JSON, LiveQualityPolicy.encodeCustomSources(updated))
                .putString(Prefs.LIVE_URL, updated.get(0).url)
                .putString(Prefs.LIVE_NAME, updated.get(0).name)
                .apply();
        LiveController.clearCatalogCache();
    }

    static void showUdpxyDialog(MainActivity a) {
        LinearLayout panel = a.vertical();
        panel.setPadding(a.dp(4), a.dp(6), a.dp(4), a.dp(4));
        TextView tip =
                a.text(
                        "填写路由器或 NAS 上的 udpxy / rtp2httpd 单播代理根地址后，列表中 rtp:// 与 udp:// 运营商高清组播源将自动转为 HTTP 单播播放：",
                        13,
                        MainActivity.MUTED);
        panel.addView(tip);
        a.gap(panel, 10);
        final android.widget.EditText input = new android.widget.EditText(a);
        input.setSingleLine(true);
        input.setHint("例如 http://…:4022（路由器局域网地址:端口）");
        input.setHintTextColor(0xff6b7280);
        input.setTextColor(MainActivity.WHITE);
        input.setTextSize(14);
        input.setPadding(a.dp(12), a.dp(10), a.dp(12), a.dp(10));
        input.setBackground(a.bg(0xff1e2623, 12));
        String current = a.prefs.getString(Prefs.LIVE_UDPXY_URL, "");
        if (!current.isEmpty()) {
            input.setText(current);
            input.setSelection(current.length());
        }
        panel.addView(
                TvQrInputHelper.wrap(a, input, "组播网关地址"), new LinearLayout.LayoutParams(-1, -2));
        AppDialog.Builder builder =
                new AppDialog.Builder(a)
                        .setTitle("组播转单播网关 (udpxy)")
                        .setView(panel)
                        .setNegativeButton("取消", null)
                        .setPositiveButton(
                                "保存",
                                (d, w) -> {
                                    String raw = input.getText().toString().trim();
                                    try {
                                        String norm = LiveQualityPolicy.normalizeUdpxyBase(raw);
                                        a.prefs
                                                .edit()
                                                .putString(Prefs.LIVE_UDPXY_URL, norm)
                                                .apply();
                                        LiveController.clearCatalogCache();
                                        a.toast(
                                                norm.isEmpty()
                                                        ? "已关闭 udpxy 组播重写"
                                                        : "已保存组播网关：" + norm);
                                        if (!a.isTvDevice()) MobileShell.show(a);
                                        else a.refresh();
                                    } catch (Exception ex) {
                                        a.toast(a.message(ex));
                                    }
                                });
        if (!current.isEmpty()) {
            builder.setNeutralButton(
                    "清除网关",
                    (d, w) -> {
                        a.prefs.edit().remove(Prefs.LIVE_UDPXY_URL).apply();
                        LiveController.clearCatalogCache();
                        a.toast("已清除 udpxy 组播网关");
                        if (!a.isTvDevice()) MobileShell.show(a);
                        else a.refresh();
                    });
        }
        builder.show();
    }

    static void showEpgDialog(MainActivity a) {
        LinearLayout panel = a.vertical();
        panel.setPadding(a.dp(4), a.dp(6), a.dp(4), a.dp(4));
        TextView tip =
                a.text(
                        "填写自定义 XMLTV 节目单地址（支持 .xml 与 .xml.gz，留空则自动读取 M3U 头部声明的 x-tvg-url）：",
                        13,
                        MainActivity.MUTED);
        panel.addView(tip);
        a.gap(panel, 10);
        final android.widget.EditText input = new android.widget.EditText(a);
        input.setSingleLine(true);
        input.setHint("例如 https://…/epg.xml.gz");
        input.setHintTextColor(0xff6b7280);
        input.setTextColor(MainActivity.WHITE);
        input.setTextSize(14);
        input.setPadding(a.dp(12), a.dp(10), a.dp(12), a.dp(10));
        input.setBackground(a.bg(0xff1e2623, 12));
        String current = a.prefs.getString(Prefs.LIVE_EPG_URL, "");
        if (!current.isEmpty()) {
            input.setText(current);
            input.setSelection(current.length());
        }
        panel.addView(
                TvQrInputHelper.wrap(a, input, "EPG 节目单地址"), new LinearLayout.LayoutParams(-1, -2));
        AppDialog.Builder builder =
                new AppDialog.Builder(a)
                        .setTitle("自定义 XMLTV 节目单 (EPG)")
                        .setView(panel)
                        .setNegativeButton("取消", null)
                        .setPositiveButton(
                                "保存",
                                (d, w) -> {
                                    String raw = input.getText().toString().trim();
                                    if (raw.isEmpty()) {
                                        a.prefs.edit().remove(Prefs.LIVE_EPG_URL).apply();
                                        LiveController.clearCatalogCache();
                                        a.toast("已恢复使用列表自带 EPG");
                                    } else if (!Cms.isHttp(raw)) {
                                        a.toast("请输入有效的 HTTP(S) XMLTV 地址");
                                        return;
                                    } else {
                                        try {
                                            String norm = Cms.normalizeHttp(raw);
                                            a.prefs
                                                    .edit()
                                                    .putString(Prefs.LIVE_EPG_URL, norm)
                                                    .apply();
                                            LiveController.clearCatalogCache();
                                            a.toast("已保存 EPG 节目单地址");
                                        } catch (Exception ex) {
                                            a.toast(a.message(ex));
                                            return;
                                        }
                                    }
                                    if (!a.isTvDevice()) MobileShell.show(a);
                                    else a.refresh();
                                });
        if (!current.isEmpty()) {
            builder.setNeutralButton(
                    "清除",
                    (d, w) -> {
                        a.prefs.edit().remove(Prefs.LIVE_EPG_URL).apply();
                        LiveController.clearCatalogCache();
                        a.toast("已清除自定义 EPG");
                        if (!a.isTvDevice()) MobileShell.show(a);
                        else a.refresh();
                    });
        }
        builder.show();
    }

    private static android.view.View liveDialogAction(
            MainActivity a, String label, boolean primary, Runnable onClick) {
        if (a.isTvDevice()) {
            android.widget.Button b = a.navButton(label, null, onClick);
            b.setGravity(android.view.Gravity.CENTER);
            return b;
        }
        TextView btn = a.text(label, 13, android.graphics.Color.WHITE);
        if (primary) btn.setTypeface(null, android.graphics.Typeface.BOLD);
        btn.setGravity(android.view.Gravity.CENTER);
        btn.setPadding(a.dp(14), a.dp(11), a.dp(14), a.dp(11));
        btn.setBackground(a.bg(primary ? 0xff0a84ff : 0xff1e2623, 999));
        MobileDetailScreen.bindTouchFeedback(btn);
        btn.setOnClickListener(v -> onClick.run());
        return btn;
    }

    static void showLiveImportDialog(MainActivity a) {
        LinearLayout panel = a.vertical();
        panel.setPadding(a.dp(4), a.dp(6), a.dp(4), a.dp(4));

        java.util.List<LiveQualityPolicy.CustomLiveSource> savedList =
                LiveQualityPolicy.parseCustomSources(
                        a.prefs.getString(Prefs.LIVE_SOURCES_JSON, ""),
                        a.prefs.getString(Prefs.LIVE_URL, ""),
                        a.prefs.getString(Prefs.LIVE_NAME, ""));
        TextView tip =
                a.text(
                        a.isTvDevice()
                                ? "支持叠加导入多份 M3U / TXT (#genre#) / JSON 直播源；点击右侧二维码图标，手机扫码即可输入网址或直接上传文件："
                                : "支持叠加导入多份 M3U / TXT (#genre#) / JSON 高清直播源（如 IPv6 源、组播源），同名频道将自动合并优选：",
                        13,
                        MainActivity.MUTED);
        panel.addView(tip);
        if (!savedList.isEmpty()) {
            a.gap(panel, 6);
            StringBuilder summary =
                    new StringBuilder("已添加自定义源（").append(savedList.size()).append("）：");
            for (int i = 0; i < Math.min(3, savedList.size()); i++) {
                if (i > 0) summary.append(" · ");
                summary.append(savedList.get(i).name);
            }
            if (savedList.size() > 3) summary.append(" …");
            panel.addView(a.text(summary.toString(), 12, 0xff60a5fa));
        }
        a.gap(panel, 10);

        final AppDialog[] holder = new AppDialog[1];
        final android.widget.EditText input = new android.widget.EditText(a);
        input.setHint("https://…/ipv6.m3u 或 #EXTM3U…（添加新直播源）");
        input.setHintTextColor(0xff6b7280);
        input.setTextColor(MainActivity.WHITE);
        input.setTextSize(14);
        input.setMaxLines(4);
        input.setPadding(a.dp(12), a.dp(10), a.dp(12), a.dp(10));
        input.setBackground(a.bg(0xff1e2623, 12));
        panel.addView(
                TvQrInputHelper.wrapWithFileUpload(
                        a,
                        input,
                        "直播源网址或文件",
                        true,
                        ".txt,.json,.m3u,.m3u8",
                        "支持选择手机本地 TXT / JSON / M3U / M3U8 直播源文件直接导入电视（最大 8MB）",
                        (fileName, data) -> importLiveFileBytesSync(a, fileName, data),
                        () -> {
                            if (holder[0] != null) holder[0].dismiss();
                        }),
                new LinearLayout.LayoutParams(-1, -2));
        a.gap(panel, 12);

        if (!a.isTvDevice()) {
            panel.addView(
                    liveDialogAction(
                            a,
                            "📋 从剪贴板一键粘贴添加直播源",
                            true,
                            () -> {
                                if (holder[0] != null) holder[0].dismiss();
                                android.content.ClipboardManager cm =
                                        (android.content.ClipboardManager)
                                                a.getSystemService(
                                                        android.content.Context.CLIPBOARD_SERVICE);
                                String clipText = "";
                                if (cm != null
                                        && cm.hasPrimaryClip()
                                        && cm.getPrimaryClip() != null) {
                                    android.content.ClipData clip = cm.getPrimaryClip();
                                    if (clip.getItemCount() > 0
                                            && clip.getItemAt(0).getText() != null) {
                                        clipText = clip.getItemAt(0).getText().toString().trim();
                                    }
                                }
                                if (clipText.isEmpty()) {
                                    a.toast("剪贴板为空，请先复制直播源网址或内容");
                                    return;
                                }
                                importLiveTextOrUrl(a, clipText);
                            }),
                    new LinearLayout.LayoutParams(-1, -2));
            a.gap(panel, 8);
        }

        panel.addView(
                liveDialogAction(
                        a,
                        "📂 选择本地直播源文件 (TXT / M3U / JSON)",
                        false,
                        () -> {
                            if (holder[0] != null) holder[0].dismiss();
                            pickLiveSource(a);
                        }),
                new LinearLayout.LayoutParams(-1, -2));
        a.gap(panel, 8);

        String udpxyCur = a.prefs.getString(Prefs.LIVE_UDPXY_URL, "");
        panel.addView(
                liveDialogAction(
                        a,
                        udpxyCur.isEmpty() ? "🌐 配置路由器 udpxy 组播转单播网关" : "🌐 udpxy 网关：" + udpxyCur,
                        false,
                        () -> {
                            if (holder[0] != null) holder[0].dismiss();
                            showUdpxyDialog(a);
                        }),
                new LinearLayout.LayoutParams(-1, -2));
        a.gap(panel, 8);

        String epgCur = a.prefs.getString(Prefs.LIVE_EPG_URL, "");
        panel.addView(
                liveDialogAction(
                        a,
                        epgCur.isEmpty() ? "📅 配置自定义 XMLTV 节目单 (EPG)" : "📅 自定义 EPG：已配置",
                        false,
                        () -> {
                            if (holder[0] != null) holder[0].dismiss();
                            showEpgDialog(a);
                        }),
                new LinearLayout.LayoutParams(-1, -2));

        AppDialog.Builder builder =
                new AppDialog.Builder(a)
                        .setTitle("导入或管理直播源")
                        .setView(panel)
                        .setNegativeButton("取消", null)
                        .setPositiveButton(
                                "添加输入内容",
                                (d, w) -> {
                                    String raw = input.getText().toString().trim();
                                    if (raw.isEmpty()) {
                                        a.toast("请输入直播源网址或内容");
                                        return;
                                    }
                                    importLiveTextOrUrl(a, raw);
                                });
        if (!savedList.isEmpty()) {
            builder.setNeutralButton(
                    "管理/移除 (" + savedList.size() + ")",
                    (d, w) -> showManageCustomLiveSourcesDialog(a, savedList));
        }
        holder[0] = builder.create();
        holder[0].show();
    }

    private static void showManageCustomLiveSourcesDialog(
            MainActivity a, java.util.List<LiveQualityPolicy.CustomLiveSource> savedList) {
        String[] labels = new String[savedList.size() + 1];
        for (int i = 0; i < savedList.size(); i++) {
            labels[i] = "移除 · " + savedList.get(i).name;
        }
        labels[savedList.size()] = "清空全部自定义直播源";
        new AppDialog.Builder(a)
                .setTitle("管理已添加的直播源")
                .setItems(
                        labels,
                        (d, idx) -> {
                            if (idx == savedList.size()) {
                                a.prefs
                                        .edit()
                                        .remove(Prefs.LIVE_SOURCES_JSON)
                                        .remove(Prefs.LIVE_URL)
                                        .remove(Prefs.LIVE_NAME)
                                        .apply();
                                LiveController.clearCatalogCache();
                                a.toast("已清空自定义直播源");
                            } else if (idx >= 0 && idx < savedList.size()) {
                                java.util.List<LiveQualityPolicy.CustomLiveSource> next =
                                        new java.util.ArrayList<>(savedList);
                                LiveQualityPolicy.CustomLiveSource removed = next.remove(idx);
                                android.content.SharedPreferences.Editor ed = a.prefs.edit();
                                if (next.isEmpty()) {
                                    ed.remove(Prefs.LIVE_SOURCES_JSON)
                                            .remove(Prefs.LIVE_URL)
                                            .remove(Prefs.LIVE_NAME);
                                } else {
                                    ed.putString(
                                                    Prefs.LIVE_SOURCES_JSON,
                                                    LiveQualityPolicy.encodeCustomSources(next))
                                            .putString(Prefs.LIVE_URL, next.get(0).url)
                                            .putString(Prefs.LIVE_NAME, next.get(0).name);
                                }
                                ed.apply();
                                LiveController.clearCatalogCache();
                                a.toast("已移除：" + removed.name);
                            }
                            if (!a.isTvDevice()) MobileShell.show(a);
                            else a.refresh();
                        })
                .setNegativeButton("返回", null)
                .show();
    }

    static String stripFileExtension(String fileName) {
        String safe = RemoteInputServer.sanitizeFileName(fileName);
        int dot = safe.lastIndexOf('.');
        String base = dot > 0 ? safe.substring(0, dot).trim() : safe.trim();
        return base.isEmpty() ? "本地直播" : base;
    }

    /**
     * Parses, validates, persists, and activates a live source file uploaded from a phone (supports
     * M3U / M3U8, TXT {@code #genre#}, JSON channel lists, TVBox {@code lives} JSON manifests, and
     * single-URL TXT files, with automatic UTF-8/GBK decoding).
     */
    static String importLiveFileBytesSync(MainActivity a, String fileName, byte[] rawBytes)
            throws Exception {
        if (rawBytes == null || rawBytes.length == 0) {
            throw new IllegalArgumentException("上传的文件为空");
        }
        if (rawBytes.length > LiveCatalog.MAX_BYTES) {
            throw new IllegalArgumentException("文件超过 8MB 大小限制");
        }
        String safeName = RemoteInputServer.sanitizeFileName(fileName);
        String baseName = stripFileExtension(safeName);
        String text = Cms.document(rawBytes);
        String trimmed = text == null ? "" : text.trim();
        if (trimmed.isEmpty()) {
            throw new IllegalArgumentException("文件内容为空或无法识别编码");
        }

        // 1. Single HTTP(S) live URL stored inside a .txt file
        if (!trimmed.contains("\n") && Cms.isHttp(trimmed)) {
            String norm = Cms.normalizeHttp(trimmed);
            LiveCatalog.Source src = new LiveCatalog.Source();
            src.name = baseName;
            src.url = norm;
            src.origin = norm;
            src.headers.put("User-Agent", Cms.USER_AGENT);
            LiveCatalog.Catalog cat = LiveCatalog.load(src);
            int count = cat.channelCount();
            if (count <= 0) {
                throw new IllegalArgumentException("网址中未解析到有效直播频道");
            }
            final String savedName = baseName + " (" + count + "台)";
            final String savedUrl = norm;
            a.ui.post(
                    () -> {
                        upsertCustomLiveSource(a, savedName, savedUrl);
                        a.toast("已导入 " + safeName + "（共 " + count + " 个频道）");
                        if (!a.isTvDevice()) MobileShell.show(a);
                        else a.refresh();
                    });
            return "已导入 " + safeName + "（共 " + count + " 个频道）";
        }

        // 2. Direct M3U / M3U8 / TXT (#genre#) / channel-list JSON
        Exception parseErr = null;
        try {
            LiveCatalog.Catalog cat = LiveCatalog.parse(trimmed, "", null);
            int count = cat.channelCount();
            if (count > 0) {
                String suffix = LiveQualityPolicy.metricKey(trimmed);
                if (suffix.length() > 8) suffix = suffix.substring(0, 8);
                java.io.File liveFile =
                        new java.io.File(a.getFilesDir(), "custom_live_" + suffix + ".txt");
                try (java.io.OutputStream out = new java.io.FileOutputStream(liveFile)) {
                    out.write(trimmed.getBytes("UTF-8"));
                }
                final String savedUrl = Cms.fileUri(liveFile);
                final String savedName = baseName + " (" + count + "台)";
                a.ui.post(
                        () -> {
                            upsertCustomLiveSource(a, savedName, savedUrl);
                            a.toast("已导入 " + safeName + "（共 " + count + " 个频道）");
                            if (!a.isTvDevice()) MobileShell.show(a);
                            else a.refresh();
                        });
                return "已导入 " + safeName + "（共 " + count + " 个频道）";
            }
        } catch (Exception e) {
            parseErr = e;
        }

        // 3. TVBox-style JSON manifest containing a "lives" array of remote live URLs
        if (trimmed.startsWith("{") || trimmed.startsWith("[")) {
            try {
                java.util.List<LiveCatalog.Source> manifestSources =
                        LiveCatalog.sources(trimmed, "");
                final java.util.List<LiveCatalog.Source> validHttp =
                        new java.util.ArrayList<LiveCatalog.Source>();
                for (LiveCatalog.Source s : manifestSources) {
                    if (s != null && s.url != null && Cms.isHttp(s.url)) {
                        validHttp.add(s);
                    }
                }
                if (!validHttp.isEmpty()) {
                    a.ui.post(
                            () -> {
                                for (int i = validHttp.size() - 1; i >= 0; i--) {
                                    LiveCatalog.Source s = validHttp.get(i);
                                    String label =
                                            s.name == null || s.name.trim().isEmpty()
                                                    ? baseName
                                                    : s.name.trim();
                                    upsertCustomLiveSource(a, label, s.url);
                                }
                                a.toast("已导入 " + safeName + "（共 " + validHttp.size() + " 个直播源）");
                                if (!a.isTvDevice()) MobileShell.show(a);
                                else a.refresh();
                            });
                    return "已导入 " + safeName + "（共 " + validHttp.size() + " 个直播源）";
                }
            } catch (Exception ignored) {
            }
        }

        throw new IllegalArgumentException(
                parseErr != null && parseErr.getMessage() != null
                        ? "未识别到有效直播源：" + parseErr.getMessage()
                        : "未在文件中识别到有效的 M3U / TXT / JSON 直播频道");
    }

    static void importLiveTextOrUrl(MainActivity a, String rawInput) {
        final String text = rawInput == null ? "" : rawInput.trim();
        if (text.isEmpty()) {
            a.toast("请输入直播源网址或内容");
            return;
        }
        a.toast("正在读取并校验直播源…");
        a.worker.execute(
                () -> {
                    try {
                        final String savedUrl;
                        final String savedName;
                        final int count;
                        if (Cms.isHttp(text)) {
                            String norm = Cms.normalizeHttp(text);
                            LiveCatalog.Source src = new LiveCatalog.Source();
                            src.name = "自定义直播源";
                            src.url = norm;
                            src.origin = norm;
                            src.headers.put("User-Agent", Cms.USER_AGENT);
                            LiveCatalog.Catalog cat = LiveCatalog.load(src);
                            count = cat.channelCount();
                            savedUrl = norm;
                            String hostLabel = "";
                            try {
                                hostLabel = new java.net.URI(norm).getHost();
                            } catch (Exception ignored) {
                            }
                            savedName =
                                    (hostLabel != null && !hostLabel.isEmpty()
                                                    ? hostLabel
                                                    : "自定义直播")
                                            + " ("
                                            + count
                                            + "台)";
                        } else {
                            LiveCatalog.Catalog cat = LiveCatalog.parse(text, "", null);
                            count = cat.channelCount();
                            String suffix = LiveQualityPolicy.metricKey(text);
                            if (suffix.length() > 8) suffix = suffix.substring(0, 8);
                            java.io.File liveFile =
                                    new java.io.File(
                                            a.getFilesDir(), "custom_live_" + suffix + ".txt");
                            try (java.io.OutputStream out =
                                    new java.io.FileOutputStream(liveFile)) {
                                out.write(text.getBytes("UTF-8"));
                            }
                            savedUrl = Cms.fileUri(liveFile);
                            savedName = "本地直播 (" + count + "台)";
                        }
                        a.ui.post(
                                () -> {
                                    upsertCustomLiveSource(a, savedName, savedUrl);
                                    a.toast("直播源添加成功（共 " + count + " 个频道）");
                                    if (!a.isTvDevice()) MobileShell.show(a);
                                    else a.refresh();
                                });
                    } catch (Exception e) {
                        a.ui.post(() -> a.toast("直播源导入失败：" + a.message(e)));
                    }
                });
    }

    static void mergeOrSaveConfig(MainActivity a, Cms.Config incoming, String origin, boolean merge)
            throws Exception {
        if (!merge || a.config == null || a.config.sites.isEmpty()) {
            saveConfig(a, incoming, origin);
            return;
        }
        org.json.JSONObject baseJson;
        try {
            baseJson = new org.json.JSONObject(Cms.withoutComments(a.config.raw));
        } catch (Exception ignored) {
            saveConfig(a, incoming, origin);
            return;
        }
        org.json.JSONArray sitesArr = baseJson.optJSONArray("sites");
        if (sitesArr == null) {
            sitesArr = new org.json.JSONArray();
            baseJson.put("sites", sitesArr);
        }
        for (Cms.Site ns : incoming.sites) {
            for (int i = sitesArr.length() - 1; i >= 0; i--) {
                org.json.JSONObject existing = sitesArr.optJSONObject(i);
                if (existing != null
                        && (ns.key.equals(existing.optString("key"))
                                || ns.api.equals(existing.optString("api")))) {
                    sitesArr.remove(i);
                }
            }
            org.json.JSONObject sObj =
                    new org.json.JSONObject()
                            .put("key", ns.key)
                            .put("name", ns.name)
                            .put("type", ns.type)
                            .put("api", ns.api)
                            .put("searchable", ns.searchable ? 1 : 0);
            if (ns.jar != null && !ns.jar.isEmpty()) sObj.put("jar", ns.jar);
            if (ns.ext != null) sObj.put("ext", ns.ext);
            sitesArr.put(sObj);
        }
        String mergedRaw = baseJson.toString(2);
        Cms.Config merged = Cms.parseConfig(mergedRaw, a.configOrigin);
        if (!incoming.sites.isEmpty()) {
            a.prefs.edit().putString(Prefs.SELECTED_SITE, incoming.sites.get(0).key).apply();
        }
        saveConfig(a, merged, a.configOrigin);
    }

    static void importLocalUri(MainActivity a, Uri uri, boolean preferLive) {
        a.toast("正在读取本地文件…");
        a.worker.execute(
                () -> {
                    try {
                        String displayName = "imported";
                        try (android.database.Cursor cursor =
                                a.getContentResolver()
                                        .query(
                                                uri,
                                                new String[] {
                                                    android.provider.OpenableColumns.DISPLAY_NAME
                                                },
                                                null,
                                                null,
                                                null)) {
                            if (cursor != null && cursor.moveToFirst()) {
                                String n = cursor.getString(0);
                                if (n != null && !n.trim().isEmpty()) displayName = n.trim();
                            }
                        } catch (Exception ignored) {
                        }
                        byte[] rawBytes;
                        try (InputStream in = a.getContentResolver().openInputStream(uri);
                                java.io.ByteArrayOutputStream bos =
                                        new java.io.ByteArrayOutputStream()) {
                            byte[] buf = new byte[8192];
                            int n;
                            while ((n = in.read(buf)) != -1) {
                                if (bos.size() + n > 28 * 1024 * 1024)
                                    throw new IOException("本地文件超过 28 MB 大小限制");
                                bos.write(buf, 0, n);
                            }
                            rawBytes = bos.toByteArray();
                        }
                        String lowerName = displayName.toLowerCase(java.util.Locale.ROOT);
                        boolean isZip =
                                lowerName.endsWith(".zip")
                                        || (rawBytes.length >= 4
                                                && (rawBytes[0] & 0xff) == 0x50
                                                && (rawBytes[1] & 0xff) == 0x4b
                                                && (rawBytes[2] & 0xff) == 0x03
                                                && (rawBytes[3] & 0xff) == 0x04);
                        if (isZip && !lowerName.endsWith(".jar")) {
                            LocalSourcePackage pkg =
                                    LocalSourcePackage.open(a.getFilesDir(), rawBytes);
                            a.ui.post(
                                    () -> {
                                        try {
                                            applyLocalPackage(a, pkg);
                                        } catch (Exception ex) {
                                            a.toast("保存本地包配置失败：" + a.message(ex));
                                        }
                                    });
                            return;
                        }
                        String text = Cms.document(rawBytes);
                        if (preferLive
                                || lowerName.endsWith(".m3u")
                                || lowerName.endsWith(".m3u8")
                                || lowerName.endsWith(".txt")) {
                            try {
                                LiveCatalog.Catalog cat = LiveCatalog.parse(text, "", null);
                                String suffix = LiveQualityPolicy.metricKey(text);
                                if (suffix.length() > 8) suffix = suffix.substring(0, 8);
                                java.io.File liveFile =
                                        new java.io.File(
                                                a.getFilesDir(), "custom_live_" + suffix + ".txt");
                                try (java.io.OutputStream out =
                                        new java.io.FileOutputStream(liveFile)) {
                                    out.write(text.getBytes("UTF-8"));
                                }
                                final String liveUrl = Cms.fileUri(liveFile);
                                final int count = cat.channelCount();
                                final String liveName = displayName + " (" + count + "台)";
                                a.ui.post(
                                        () -> {
                                            upsertCustomLiveSource(a, liveName, liveUrl);
                                            a.toast("直播源添加成功（共 " + count + " 个频道）");
                                            if (!a.isTvDevice()) MobileShell.show(a);
                                            else a.refresh();
                                        });
                                return;
                            } catch (Exception liveErr) {
                                if (preferLive) throw liveErr;
                            }
                        }
                        if (lowerName.endsWith(".js")
                                || lowerName.endsWith(".mjs")
                                || lowerName.endsWith(".py")
                                || Cms.looksLikeJsSpider(text, displayName)
                                || Cms.looksLikePySpider(text, displayName)) {
                            java.io.File spiderDir =
                                    new java.io.File(a.getFilesDir(), "local_spiders");
                            if (!spiderDir.exists()) spiderDir.mkdirs();
                            String safeName =
                                    displayName.replaceAll("[^A-Za-z0-9._\\-\\u4e00-\\u9fa5]", "_");
                            java.io.File savedFile = new java.io.File(spiderDir, safeName);
                            try (java.io.OutputStream out =
                                    new java.io.FileOutputStream(savedFile)) {
                                out.write(text.getBytes("UTF-8"));
                            }
                            String fileOrigin = Cms.fileUri(savedFile);
                            Cms.Config singleCfg = Cms.parseConfig(text, fileOrigin);
                            a.ui.post(
                                    () -> {
                                        try {
                                            mergeOrSaveConfig(a, singleCfg, "", true);
                                            a.toast("已导入扩展片源：" + singleCfg.sites.get(0).name);
                                        } catch (Exception ex) {
                                            a.toast("保存扩展片源失败：" + a.message(ex));
                                        }
                                    });
                            return;
                        }
                        final String finalOrigin =
                                uri == null
                                        ? ""
                                        : Cms.localImportOrigin(uri.getScheme(), uri.toString());
                        try {
                            Cms.Config parsed =
                                    Cms.parseConfig(
                                            text, finalOrigin.isEmpty() ? null : finalOrigin);
                            a.ui.post(
                                    () -> {
                                        try {
                                            saveConfig(a, parsed, finalOrigin);
                                        } catch (Exception ex) {
                                            a.toast("保存配置失败：" + a.message(ex));
                                        }
                                    });
                        } catch (Exception configErr) {
                            // Fallback: check if the JSON/text file is actually a live channel list
                            try {
                                LiveCatalog.Catalog cat = LiveCatalog.parse(text, "", null);
                                java.io.File liveFile =
                                        new java.io.File(a.getFilesDir(), "custom_live.txt");
                                try (java.io.OutputStream out =
                                        new java.io.FileOutputStream(liveFile)) {
                                    out.write(text.getBytes("UTF-8"));
                                }
                                final String liveUrl = Cms.fileUri(liveFile);
                                final int count = cat.channelCount();
                                a.ui.post(
                                        () -> {
                                            upsertCustomLiveSource(
                                                    a, "本地直播 (" + count + "台)", liveUrl);
                                            a.toast("已识别并添加直播源（共 " + count + " 个频道）");
                                            if (!a.isTvDevice()) MobileShell.show(a);
                                            else a.refresh();
                                        });
                            } catch (Exception ignored) {
                                throw configErr;
                            }
                        }
                    } catch (Exception e) {
                        a.ui.post(() -> a.toast("文件读取失败：" + a.message(e)));
                    }
                });
    }

    static void applyLocalPackage(MainActivity a, LocalSourcePackage pkg) throws Exception {
        if (pkg.liveChannels > 0) {
            upsertCustomLiveSource(a, "本地包直播 (" + pkg.liveChannels + "台)", pkg.origin);
            a.toast("本地播放列表导入成功（共 " + pkg.liveChannels + " 个频道）");
            if (!a.isTvDevice()) MobileShell.show(a);
            else a.refresh();
        } else {
            saveConfig(a, pkg.config, pkg.origin);
            a.toast("本地包导入成功（共 " + pkg.config.sites.size() + " 个片源）");
        }
    }

    static final class SavedState {
        final Cms.Config config;
        final String configOrigin;

        SavedState(Cms.Config config, String configOrigin) {
            this.config = config;
            this.configOrigin = configOrigin;
        }
    }

    static ConfigStore.PointerStore pointerStoreFor(final MainActivity a) {
        return new ConfigStore.PointerStore() {
            @Override
            public ConfigStore.PointerSnapshot readCurrentPointers() {
                String curOrigin =
                        a.prefs.contains(Prefs.ORIGIN)
                                ? a.prefs.getString(Prefs.ORIGIN, null)
                                : null;
                String curSelected =
                        a.prefs.contains(Prefs.SELECTED_SITE)
                                ? a.prefs.getString(Prefs.SELECTED_SITE, null)
                                : null;
                return new ConfigStore.PointerSnapshot(
                        curOrigin, curSelected, new SavedState(a.config, a.configOrigin));
            }

            @Override
            public void applyPointers(ConfigStore.PointerSnapshot snapshot) {
                if (snapshot == null || a.prefs == null) return;
                android.content.SharedPreferences.Editor editor = a.prefs.edit();
                if (snapshot.origin != null) {
                    editor.putString(Prefs.ORIGIN, snapshot.origin);
                } else {
                    editor.remove(Prefs.ORIGIN);
                }
                if (snapshot.selectedSite != null) {
                    editor.putString(Prefs.SELECTED_SITE, snapshot.selectedSite);
                } else {
                    editor.remove(Prefs.SELECTED_SITE);
                }
                editor.apply();
            }
        };
    }

    static void saveConfig(MainActivity a, Cms.Config c, String origin) throws Exception {
        if (!c.warehouse.isEmpty()) origin = c.warehouse;
        else if (!c.origin.isEmpty()) origin = c.origin;
        if (origin == null) origin = "";
        ConfigLibrary library = new ConfigLibrary(a.configStore.directory);
        String selected = a.prefs.getString(Prefs.SELECTED_SITE, "");
        boolean isLocalFile = ConfigLibrary.isLocalFileOrigin(origin);
        if (a.isTvDevice() || !isLocalFile) {
            try {
                rememberConfig(a, library);
                String id = ConfigLibrary.identity(origin, c.raw);
                String previousId =
                        a.config == null
                                ? ""
                                : ConfigLibrary.identity(a.configOrigin, a.config.raw);
                if (!id.equals(previousId)) {
                    selected = "";
                    for (ConfigLibrary.Entry entry : library.entries()) {
                        if (id.equals(entry.id)) selected = entry.selected;
                    }
                }
                library.remember(c.raw, origin, configName(c), selected);
            } catch (Exception e) {
                if (a.isTvDevice()) throw e;
            }
        }
        final String rawConfig = c.raw;
        final String targetOrigin = origin;
        SourcePicker.applyEdits(a, c, targetOrigin);
        String currentKey = selected;
        boolean hasSelected = false;
        Cms.Site firstAvailable = null;
        for (Cms.Site s : c.sites) {
            if (available(a, c, s)) {
                if (firstAvailable == null) firstAvailable = s;
                if (s.key.equals(currentKey)) hasSelected = true;
            }
        }
        final String nextSelectedSite =
                !hasSelected && firstAvailable != null
                        ? firstAvailable.key
                        : (hasSelected ? currentKey : null);
        final ConfigStore store = a.configStore;
        final ConfigStore.PointerStore pointerStore = pointerStoreFor(a);
        final ConfigStore.PointerSnapshot nextPointers =
                new ConfigStore.PointerSnapshot(
                        targetOrigin, nextSelectedSite, new SavedState(c, targetOrigin));
        if (store != null) {
            store.saveAsync(
                    rawConfig,
                    nextPointers,
                    pointerStore,
                    (seq, error, rolledBackTo) ->
                            a.ui.post(
                                    () -> {
                                        if (store.latestWriteSeq() != seq
                                                || a.isFinishing()
                                                || a.isDestroyed()) {
                                            return;
                                        }
                                        if (rolledBackTo != null
                                                && rolledBackTo.stateTag instanceof SavedState) {
                                            SavedState prev = (SavedState) rolledBackTo.stateTag;
                                            a.closeEngines();
                                            a.config = prev.config;
                                            a.configOrigin =
                                                    prev.configOrigin == null
                                                            ? ""
                                                            : prev.configOrigin;
                                            if (a.current != null && a.player == null) {
                                                a.refresh();
                                            }
                                        }
                                        a.notice("配置保存失败，已回滚至原配置：" + a.message(error));
                                    }));
        } else {
            pointerStore.applyPointers(nextPointers);
        }
        a.closeEngines();
        a.config = c;
        a.configOrigin = targetOrigin;
        if (!isLocalFile) {
            CloudSyncDialog.onSubscriptionSaved(a, targetOrigin, c.raw);
        }
        a.back.clear();
        a.current = new MainActivity.Screen(a::home);
        a.current.render.run();
        a.restore(a.current);
        a.toast("已导入 " + c.sites.size() + " 个来源");
    }

    static String configName(Cms.Config config) {
        if (config == null || config.sites.isEmpty()) return "我的订阅";
        List<SubscriptionManager.MultiSourceMeta> multi =
                SubscriptionManager.readMultiSourceMeta(config.raw);
        if (multi.size() >= 2) {
            List<String> names = new ArrayList<String>(multi.size());
            for (SubscriptionManager.MultiSourceMeta m : multi) {
                if (!m.name.isEmpty()) names.add(m.name);
            }
            return SubscriptionManager.mergedSubscriptionName(names)
                    + " · "
                    + config.sites.size()
                    + " 个片源";
        }
        return config.sites.get(0).name
                + (config.sites.size() > 1 ? " · " + config.sites.size() + " 个片源" : "");
    }

    static void rememberConfig(MainActivity a, ConfigLibrary library) throws Exception {
        if (a.config != null && a.config.raw != null && !a.config.raw.isEmpty())
            library.remember(
                    a.config.raw,
                    a.configOrigin,
                    configName(a.config),
                    a.prefs.getString(Prefs.SELECTED_SITE, ""));
    }
}
