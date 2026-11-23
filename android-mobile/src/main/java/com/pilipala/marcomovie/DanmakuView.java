package com.pilipala.marcomovie;

import android.content.Context;
import android.graphics.*;
import android.os.SystemClock;
import android.view.View;
import com.pilipala.marcomovie.DanmakuData.Comment;
import com.pilipala.marcomovie.DanmuProvider.BlockFilter;
import com.pilipala.marcomovie.DanmuProvider.DanmuItem;
import com.pilipala.marcomovie.DanmuSegmentCache.ActiveSlot;
import com.pilipala.marcomovie.DanmuSegmentCache.FramePacingMonitor;
import com.pilipala.marcomovie.DanmuSegmentCache.LayoutEngine;
import com.pilipala.marcomovie.DanmuSegmentCache.SmoothClock;
import com.pilipala.marcomovie.DanmuSegmentCache.TextWidthMeasurer;
import java.io.*;
import java.net.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.zip.GZIPInputStream;
import java.util.zip.Inflater;
import java.util.zip.InflaterInputStream;

/**
 * Bounded danmu overlay supporting both legacy full-episode {@link DanmakuData} loading and
 * segmented {@link DanmuSegmentCache} playback with collision-free linear kinematics lane
 * allocation and Android TV P90 adaptive row degradation. Zero allocations on {@link #onDraw}.
 */
class DanmakuView extends View implements AutoCloseable {
    interface Clock {
        int position();

        boolean playing();
    }

    interface Listener {
        void loaded(int count);

        void error(String message);
    }

    private static final Typeface DANMAKU_TYPEFACE = Typeface.create("sans-serif", Typeface.BOLD);
    private static final float MIN_BOTTOM_SAFE_INSET_DP = 44f;

    /** Sample again while paused or buffering so playback can resume the animation loop. */
    private static final long PAUSED_REDRAW_DELAY_MS = 250L;

    final Clock clock;
    final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG | Paint.SUBPIXEL_TEXT_FLAG);
    final Paint strokePaint = new Paint(Paint.ANTI_ALIAS_FLAG | Paint.SUBPIXEL_TEXT_FLAG);
    final ExecutorService loader = Executors.newSingleThreadExecutor();
    final LayoutEngine layoutEngine = new LayoutEngine();
    final FramePacingMonitor tvPacingMonitor = new FramePacingMonitor();
    final SmoothClock smoothClock = new SmoothClock();
    private final ArrayList<DanmuItem> frameItems = new ArrayList<>(128);
    private final TextWidthMeasurer widthMeasurer =
            new TextWidthMeasurer() {
                @Override
                public float measureWidth(String text) {
                    return text == null ? 0f : paint.measureText(text);
                }
            };

    List<Comment> comments = Collections.emptyList();
    List<DanmuItem> legacyItems = Collections.emptyList();
    List<DanmuItem> filteredLegacyItems = Collections.emptyList();
    private DanmuSegmentCache segmentCache;
    private volatile BlockFilter blockFilter = BlockFilter.EMPTY;

    boolean closed, enabled;
    boolean tvMode = false;
    boolean showScroll = true;
    boolean showTop = true;
    boolean showBottom = true;
    int request;
    float textSize = 20f;
    float opacity = 0.85f;
    float area = 0.50f;
    float speedMultiplier = 1.0f;
    float playSpeed = 1.0f;
    long timeOffsetMs = 0L;
    int configuredMaxRows = 14;
    float subtitleBottomClearanceDp = MIN_BOTTOM_SAFE_INSET_DP;

    private long lastDrawNanos = 0L;

    void setMobileStyle(float areaRatio, int opacityPct, int speedPreset) {
        this.area = Math.max(0.15f, Math.min(1.0f, areaRatio));
        this.opacity = Math.max(0.20f, Math.min(1.0f, opacityPct / 100f));
        this.speedMultiplier = speedPreset == 0 ? 0.78f : (speedPreset == 2 ? 1.32f : 1.0f);
        invalidate();
    }

    DanmakuView(Context context, Clock clock) {
        super(context);
        this.clock = clock;
        setImportantForAccessibility(IMPORTANT_FOR_ACCESSIBILITY_NO);
        paint.setTypeface(DANMAKU_TYPEFACE);
        paint.setStyle(Paint.Style.FILL);
        strokePaint.setTypeface(DANMAKU_TYPEFACE);
        strokePaint.setStyle(Paint.Style.STROKE);
        strokePaint.setStrokeJoin(Paint.Join.ROUND);
        strokePaint.setStrokeCap(Paint.Cap.ROUND);
        strokePaint.setColor(0xd8000000);
    }

    void enabled(boolean value) {
        enabled = value;
        setVisibility(value ? VISIBLE : GONE);
        if (!value) {
            lastDrawNanos = 0L;
        } else {
            invalidate();
        }
    }

    void setTvMode(boolean isTv) {
        tvMode = isTv;
        if (isTv) {
            configuredMaxRows = Math.max(2, Math.min(8, configuredMaxRows));
            tvPacingMonitor.setCeilingRows(configuredMaxRows);
        }
        layoutEngine.reset();
        invalidate();
    }

    void setPlaySpeed(float speed) {
        playSpeed = Math.max(0.5f, Math.min(2.0f, speed));
        smoothClock.setPlaySpeed(
                playSpeed, clock.position(), clock.playing(), SystemClock.elapsedRealtime());
    }

    void setTimeOffsetMs(long offsetMs) {
        timeOffsetMs = Math.max(-30000L, Math.min(30000L, offsetMs));
        if (segmentCache != null) {
            segmentCache.setTimeOffsetMs(timeOffsetMs);
            segmentCache.onPlaybackTick(clock.position(), clock.playing());
        }
        layoutEngine.reset();
        invalidate();
    }

    void setSubtitleBottomClearanceDp(float clearanceDp) {
        subtitleBottomClearanceDp = Math.max(MIN_BOTTOM_SAFE_INSET_DP, clearanceDp);
        layoutEngine.reset();
        invalidate();
    }

    private void rebuildFilteredLegacyItems() {
        filteredLegacyItems = DanmuSegmentCache.filterItems(legacyItems, blockFilter);
    }

    void setLegacyItems(List<DanmuItem> items) {
        legacyItems = items == null ? Collections.<DanmuItem>emptyList() : items;
        rebuildFilteredLegacyItems();
        layoutEngine.reset();
    }

    List<DanmuItem> getFrameItemsForTest() {
        return frameItems;
    }

    void setBlockFilter(BlockFilter filter) {
        BlockFilter next = filter == null ? BlockFilter.EMPTY : filter;
        boolean changed = !blockFilter.sameRules(next);
        blockFilter = next;
        if (segmentCache != null) {
            segmentCache.setBlockFilter(blockFilter);
        }
        if (changed) {
            rebuildFilteredLegacyItems();
            layoutEngine.onBlockFilterChanged(blockFilter);
        }
        invalidate();
    }

    void applyConfig(DanmuSettingsPanel.DanmuConfig config) {
        if (config == null) return;
        boolean offsetChanged = timeOffsetMs != config.timeOffsetMs;
        tvMode = config.tvProfile;
        opacity = config.opacity;
        area = config.displayArea;
        textSize = config.fontSizeSp;
        speedMultiplier = config.speedMultiplier;
        timeOffsetMs = config.timeOffsetMs;
        showScroll = config.showScroll;
        showTop = config.showTop;
        showBottom = config.showBottom;
        configuredMaxRows = config.maxRows;
        if (tvMode) {
            tvPacingMonitor.setCeilingRows(configuredMaxRows);
        }
        BlockFilter nextFilter = config.createBlockFilter();
        boolean filterChanged = !blockFilter.sameRules(nextFilter);
        blockFilter = nextFilter;
        if (segmentCache != null) {
            segmentCache.setTimeOffsetMs(timeOffsetMs);
            segmentCache.setBlockFilter(blockFilter);
            if (offsetChanged) {
                segmentCache.onPlaybackTick(clock.position(), clock.playing());
            }
        }
        if (filterChanged) {
            rebuildFilteredLegacyItems();
        }
        if (offsetChanged) {
            layoutEngine.reset();
        } else if (filterChanged) {
            layoutEngine.onBlockFilterChanged(blockFilter);
        }
        enabled(config.enabled);
    }

    void attachSegmentCache(DanmuSegmentCache cache) {
        if (segmentCache != null && segmentCache != cache) {
            segmentCache.setListener(null);
        }
        segmentCache = cache;
        layoutEngine.reset();
        if (cache != null) {
            cache.setTimeOffsetMs(timeOffsetMs);
            cache.setBlockFilter(blockFilter);
            cache.setListener(
                    new DanmuSegmentCache.Listener() {
                        @Override
                        public void onWindowReady(int windowIndex, int count) {
                            if (!closed) postInvalidate();
                        }

                        @Override
                        public void onSessionReady(boolean segmented) {
                            if (!closed) postInvalidate();
                        }

                        @Override
                        public void onError(String message) {
                            AppLog.w("DanmakuView", "Segmented danmu error: " + message, null);
                        }
                    });
            invalidate();
        }
    }

    void detachSegmentCache() {
        if (segmentCache != null) {
            segmentCache.setListener(null);
            segmentCache = null;
        }
        layoutEngine.reset();
    }

    void onSeekInitiated() {
        layoutEngine.reset();
        if (segmentCache != null) {
            segmentCache.onSeekInitiated();
        }
    }

    void onSeekSettled(long targetRawPositionMs) {
        layoutEngine.reset();
        if (segmentCache != null) {
            segmentCache.onSeekSettled(targetRawPositionMs);
        }
        invalidate();
    }

    boolean hasSegmentCache() {
        return segmentCache != null;
    }

    int getEffectiveMaxRows() {
        return tvMode ? tvPacingMonitor.getEffectiveMaxRows() : configuredMaxRows;
    }

    static String decodeResponseStream(InputStream rawStream, String encoding) throws IOException {
        return LocalProxy.decodeDanmakuResponseStream(rawStream, encoding);
    }

    static Map<String, String> sanitizeDanmakuHeaders(
            String danmakuUrl, String videoUrl, Map<String, String> videoHeaders) {
        if (videoHeaders == null || videoHeaders.isEmpty()) return Collections.emptyMap();
        boolean sameOrigin = sameHttpOrigin(danmakuUrl, videoUrl);
        Map<String, String> clean = new LinkedHashMap<>();
        for (Map.Entry<String, String> e : videoHeaders.entrySet()) {
            String k = e.getKey();
            String v = e.getValue();
            if (k == null || v == null || v.isEmpty()) continue;
            String lower = k.toLowerCase(Locale.ROOT);
            if (lower.equals("range")
                    || lower.equals("if-range")
                    || lower.equals("host")
                    || lower.equals("origin")
                    || lower.equals("content-length")
                    || lower.equals("accept-encoding")) {
                continue;
            }
            // Never leak netdisk / video-CDN Cookie, Referer, Authorization, or client UA
            // to a different danmaku server or loopback proxy route.
            if (!sameOrigin
                    && (lower.equals("cookie")
                            || lower.equals("authorization")
                            || lower.equals("referer")
                            || lower.equals("user-agent"))) {
                continue;
            }
            clean.put(k, v);
        }
        return clean;
    }

    private static boolean sameHttpOrigin(String aUrl, String bUrl) {
        if (aUrl == null || bUrl == null || aUrl.isEmpty() || bUrl.isEmpty()) return false;
        try {
            URL u1 = new URL(aUrl);
            URL u2 = new URL(bUrl);
            if (!u1.getProtocol().equalsIgnoreCase(u2.getProtocol())) return false;
            if (!u1.getHost().equalsIgnoreCase(u2.getHost())) return false;
            int p1 = u1.getPort() > 0 ? u1.getPort() : u1.getDefaultPort();
            int p2 = u2.getPort() > 0 ? u2.getPort() : u2.getDefaultPort();
            return p1 == p2;
        } catch (Exception ignored) {
            return false;
        }
    }

    static String encodeDanmakuUrl(String raw) {
        return LocalProxy.encodeDanmakuUrl(raw);
    }

    private static String describeUrlForLog(String url) {
        if (url == null || url.isEmpty()) return "<empty>";
        try {
            URL u = new URL(url);
            String query = u.getQuery();
            String qHint = "";
            if (query != null && !query.isEmpty()) {
                int amp = query.indexOf('&');
                qHint = "?" + (amp > 0 ? query.substring(0, amp) : query);
                if (qHint.length() > 48) qHint = qHint.substring(0, 48);
            }
            return u.getProtocol()
                    + "://"
                    + u.getHost()
                    + (u.getPort() > 0 ? ":" + u.getPort() : "")
                    + u.getPath()
                    + qHint;
        } catch (Exception ignored) {
            return url.length() > 48 ? url.substring(0, 48) : url;
        }
    }

    static String fetchDanmaku(String candidate, Map<String, String> headers) throws Exception {
        String input = candidate == null ? "" : candidate.trim();
        if (input.startsWith("[") || input.startsWith("{")) {
            try {
                org.json.JSONObject wrapper = new org.json.JSONObject().put("danmaku", input);
                input = MediaOptions.extractDanmakuUrl(wrapper);
            } catch (Exception ignored) {
            }
        }
        // Support local XML/JSON danmaku files pushed by CSP plugins (file:// or absolute path).
        if (input.startsWith("file://") || input.startsWith("/")) {
            String filePath =
                    input.startsWith("file://")
                            ? java.net.URLDecoder.decode(input.substring(7), "UTF-8")
                            : input;
            java.io.File file = new java.io.File(filePath);
            if (!file.isFile() || !file.canRead()) {
                throw new IOException("本地弹幕文件不可读: " + file.getName());
            }
            try (InputStream fis = new java.io.FileInputStream(file)) {
                return decodeResponseStream(fis, "");
            }
        }
        String address = LocalProxy.rewrite(input);
        if (!Cms.isHttp(address)) {
            throw new IOException("来源没有提供有效弹幕地址");
        }
        String encodedAddress = encodeDanmakuUrl(address);
        String body = fetchDanmakuOnce(encodedAddress, headers, true);
        if (body == null || body.trim().isEmpty()) {
            // Retry once cleanly with identity encoding and empty headers after brief wait
            // (handles async plugin cache warm-up and servers sensitive to gzip/extra headers).
            try {
                Thread.sleep(650);
            } catch (InterruptedException ie) {
                Thread.currentThread().interrupt();
            }
            body = fetchDanmakuOnce(encodedAddress, Collections.emptyMap(), false);
        }
        return body == null ? "" : body;
    }

    private static String fetchDanmakuOnce(
            String address, Map<String, String> headers, boolean allowCompressed) throws Exception {
        Map<String, String> reqHeaders =
                ProxyAddress.requestHeaders(
                        address,
                        headers != null ? headers : Collections.<String, String>emptyMap());
        URL currentUrl = new URL(Cms.normalizeHttp(address));
        HttpURLConnection connection = null;
        Map<String, Cms.RedirectCookie> redirectCookies = new LinkedHashMap<>();

        try {
            for (int redirect = 0; redirect < 5; redirect++) {
                if (connection != null) {
                    connection.disconnect();
                }
                boolean isLoopback = LocalProxy.loopbackHost(currentUrl.getHost());
                connection = ProxyAddress.openHttpConnection(currentUrl);
                connection.setInstanceFollowRedirects(false);
                connection.setConnectTimeout(12000);
                connection.setReadTimeout(25000);
                connection.setRequestProperty("User-Agent", Cms.USER_AGENT);
                connection.setRequestProperty("Accept", "*/*");
                connection.setRequestProperty(
                        "Accept-Encoding", allowCompressed ? "gzip, deflate" : "identity");
                for (Map.Entry<String, String> h : reqHeaders.entrySet()) {
                    String k = h.getKey();
                    if (k == null) continue;
                    if (isLoopback
                            && ("Origin".equalsIgnoreCase(k) || "Host".equalsIgnoreCase(k))) {
                        continue;
                    }
                    connection.setRequestProperty(k, h.getValue());
                }
                int status = connection.getResponseCode();

                // Track Set-Cookie headers
                List<String> setCookies = connection.getHeaderFields().get("Set-Cookie");
                if (setCookies == null) {
                    for (Map.Entry<String, List<String>> entry :
                            connection.getHeaderFields().entrySet()) {
                        if ("set-cookie".equalsIgnoreCase(entry.getKey())) {
                            setCookies = entry.getValue();
                            break;
                        }
                    }
                }
                List<Cms.RedirectCookie> newCookies = Cms.parseSetCookies(setCookies, currentUrl);
                for (Cms.RedirectCookie cookie : newCookies) {
                    redirectCookies.put(
                            cookie.domain
                                    + "|"
                                    + cookie.hostOnly
                                    + "|"
                                    + cookie.path
                                    + "|"
                                    + cookie.name,
                            cookie);
                }

                if (status == 301
                        || status == 302
                        || status == 303
                        || status == 307
                        || status == 308) {
                    String loc = connection.getHeaderField("Location");
                    if (loc == null || loc.trim().isEmpty()) {
                        throw new IOException("弹幕重定向缺少地址");
                    }
                    URL targetUrl = new URL(currentUrl, encodeDanmakuUrl(loc.trim()));
                    if (!Cms.isHttp(targetUrl.toString())) {
                        throw new IOException("不支持此弹幕重定向协议: " + targetUrl.getProtocol());
                    }
                    if (targetUrl.getUserInfo() != null) {
                        throw new IOException("弹幕重定向不能注入登录凭据");
                    }
                    reqHeaders =
                            Cms.inheritedHeaders(
                                    currentUrl.toString(), targetUrl.toString(), reqHeaders);
                    Cms.mergeRedirectCookies(reqHeaders, redirectCookies.values(), targetUrl);
                    currentUrl = targetUrl;
                    continue;
                }

                if (status < 200 || status >= 300) {
                    throw new IOException(
                            "弹幕服务器返回 HTTP "
                                    + status
                                    + " ("
                                    + describeUrlForLog(currentUrl.toString())
                                    + ")");
                }

                String encoding = connection.getContentEncoding();
                String contentType = connection.getContentType();
                try (InputStream in = connection.getInputStream()) {
                    String text = decodeResponseStream(in, encoding);
                    if (text == null || text.trim().isEmpty()) {
                        AppLog.w(
                                "DanmakuView",
                                "Empty danmaku body from "
                                        + describeUrlForLog(currentUrl.toString())
                                        + " status="
                                        + status
                                        + " ct="
                                        + contentType
                                        + " enc="
                                        + encoding,
                                null);
                    }
                    return text;
                }
            }
            throw new IOException("弹幕重定向次数过多");
        } finally {
            if (connection != null) {
                connection.disconnect();
            }
        }
    }

    private static List<DanmuItem> convertLegacyComments(List<Comment> values) {
        if (values == null || values.isEmpty()) return Collections.emptyList();
        List<DanmuItem> items = new ArrayList<>(values.size());
        for (int i = 0; i < values.size(); i++) {
            Comment c = values.get(i);
            items.add(
                    new DanmuItem(
                            "legacy_" + i + "_" + c.time,
                            c.time,
                            DandanplayProvider.normalizeMode(c.mode),
                            c.color & 0xFFFFFF,
                            c.text));
        }
        return items;
    }

    void load(String url, Map<String, String> headers, Listener listener) {
        final int ticket = ++request;
        loader.execute(
                () -> {
                    try {
                        String body = fetchDanmaku(url, headers);
                        List<Comment> values = DanmakuData.parse(body);
                        BlockFilter filterSnap = blockFilter;
                        List<DanmuItem> converted = convertLegacyComments(values);
                        List<DanmuItem> prefiltered =
                                DanmuSegmentCache.filterItems(converted, filterSnap);
                        post(
                                () -> {
                                    if (!closed && ticket == request) {
                                        detachSegmentCache();
                                        comments = values;
                                        legacyItems = converted;
                                        filteredLegacyItems =
                                                blockFilter.sameRules(filterSnap)
                                                        ? prefiltered
                                                        : DanmuSegmentCache.filterItems(
                                                                converted, blockFilter);
                                        layoutEngine.reset();
                                        listener.loaded(values.size());
                                        invalidate();
                                    }
                                });
                    } catch (Exception error) {
                        AppLog.w(
                                "DanmakuView",
                                "Failed to load danmaku: " + error.getMessage(),
                                error);
                        post(
                                () -> {
                                    if (!closed && ticket == request) {
                                        listener.error("弹幕暂时不可用，可导入本地 XML / JSON 文件。");
                                    }
                                });
                    }
                });
    }

    void loadText(String text, Listener listener) {
        final int ticket = ++request;
        loader.execute(
                () -> {
                    try {
                        List<Comment> values = DanmakuData.parse(text);
                        BlockFilter filterSnap = blockFilter;
                        List<DanmuItem> converted = convertLegacyComments(values);
                        List<DanmuItem> prefiltered =
                                DanmuSegmentCache.filterItems(converted, filterSnap);
                        post(
                                () -> {
                                    if (!closed && ticket == request) {
                                        detachSegmentCache();
                                        comments = values;
                                        legacyItems = converted;
                                        filteredLegacyItems =
                                                blockFilter.sameRules(filterSnap)
                                                        ? prefiltered
                                                        : DanmuSegmentCache.filterItems(
                                                                converted, blockFilter);
                                        layoutEngine.reset();
                                        listener.loaded(values.size());
                                        invalidate();
                                    }
                                });
                    } catch (Exception error) {
                        post(
                                () -> {
                                    if (!closed && ticket == request) listener.error("无法识别弹幕文件。");
                                });
                    }
                });
    }

    private long smoothNow() {
        return smoothClock.sample(clock.position(), clock.playing(), SystemClock.elapsedRealtime());
    }

    void populateLegacyFrameItems(long effectiveMs) {
        frameItems.clear();
        if (effectiveMs < 0L || filteredLegacyItems.isEmpty()) return;
        long minTimeMs = effectiveMs - DanmuSegmentCache.MAX_COMMENT_LIFETIME_MS;
        int lo = 0;
        int hi = filteredLegacyItems.size();
        while (lo < hi) {
            int mid = (lo + hi) >>> 1;
            if (filteredLegacyItems.get(mid).timeMs < minTimeMs) lo = mid + 1;
            else hi = mid;
        }
        for (int i = lo; i < filteredLegacyItems.size(); i++) {
            DanmuItem item = filteredLegacyItems.get(i);
            if (item.timeMs > effectiveMs) break;
            if (item.timeMs < minTimeMs) continue;
            frameItems.add(item);
        }
    }

    @Override
    protected void onDraw(Canvas canvas) {
        super.onDraw(canvas);
        if (!enabled || closed) return;

        boolean playing = clock.playing();
        if (tvMode && playing) {
            long nowNanos = SystemClock.elapsedRealtimeNanos();
            if (lastDrawNanos > 0L) {
                double dtMs = (nowNanos - lastDrawNanos) / 1_000_000.0;
                tvPacingMonitor.recordFrameIntervalMs(dtMs);
            }
            lastDrawNanos = nowNanos;
        } else {
            lastDrawNanos = 0L;
        }

        long rawNow = smoothNow();
        DanmuSegmentCache cache = segmentCache;
        if (cache != null) {
            cache.onPlaybackTick(rawNow, playing);
            cache.fillVisibleWindowSnapshot(rawNow, frameItems);
        } else {
            if (legacyItems.isEmpty()) return;
            populateLegacyFrameItems(DanmuSegmentCache.computeEffectiveMs(rawNow, timeOffsetMs));
        }

        long effectiveMs =
                cache != null
                        ? DanmuSegmentCache.computeEffectiveMs(rawNow, cache.getTimeOffsetMs())
                        : DanmuSegmentCache.computeEffectiveMs(rawNow, timeOffsetMs);
        if (effectiveMs < 0L) {
            scheduleNextFrame(playing);
            return;
        }

        int viewW = getWidth();
        int viewH = getHeight();
        if (viewW <= 0 || viewH <= 0) return;

        float density = getResources().getDisplayMetrics().density;
        float scaledDensity = getResources().getDisplayMetrics().scaledDensity;
        float pxSize = textSize * (scaledDensity > 0f ? scaledDensity : density);
        paint.setTextSize(pxSize);
        strokePaint.setTextSize(pxSize);
        strokePaint.setStrokeWidth(Math.max(2f, 2.4f * density));

        int alpha = Math.max(0, Math.min(255, Math.round(opacity * 255f)));
        strokePaint.setAlpha(Math.min(255, Math.round(alpha * 0.90f)));

        int rowCap = tvMode ? tvPacingMonitor.getEffectiveMaxRows() : configuredMaxRows;
        int itemCap = tvMode ? tvPacingMonitor.getEffectiveMaxItems() : 120;
        long scrollDurationMs = LayoutEngine.computeScrollDurationMs(tvMode, speedMultiplier);
        float bottomSafeInsetPx =
                Math.max(MIN_BOTTOM_SAFE_INSET_DP, subtitleBottomClearanceDp) * density;

        layoutEngine.step(
                effectiveMs,
                frameItems,
                viewW,
                viewH,
                pxSize,
                getPaddingTop(),
                bottomSafeInsetPx,
                area,
                rowCap,
                itemCap,
                scrollDurationMs,
                showScroll,
                showTop,
                showBottom,
                widthMeasurer);

        ActiveSlot[] slots = layoutEngine.getSlots();
        for (int i = 0; i < slots.length; i++) {
            ActiveSlot slot = slots[i];
            if (!slot.active || slot.text == null) continue;
            canvas.drawText(slot.text, slot.x, slot.y, strokePaint);
            paint.setColor(0xff000000 | (slot.rgbColor & 0xffffff));
            paint.setAlpha(alpha);
            canvas.drawText(slot.text, slot.x, slot.y, paint);
        }

        scheduleNextFrame(playing);
    }

    /**
     * One scheduling path for both draw exits. An attached, visible, enabled overlay requests the
     * next animation frame while playing, and a delayed redraw while paused or buffering. The
     * delayed draw samples {@link #clock} again and resumes animation as soon as playback returns.
     */
    private void scheduleNextFrame(boolean playing) {
        if (!enabled || closed || getVisibility() != VISIBLE || !isAttachedToWindow()) return;
        if (playing) {
            postInvalidateOnAnimation();
        } else {
            postInvalidateDelayed(PAUSED_REDRAW_DELAY_MS);
        }
    }

    @Override
    protected void onDetachedFromWindow() {
        lastDrawNanos = 0L;
        smoothClock.reset();
        super.onDetachedFromWindow();
    }

    @Override
    public void close() {
        closed = true;
        request++;
        lastDrawNanos = 0L;
        smoothClock.reset();
        detachSegmentCache();
        loader.shutdownNow();
        comments = Collections.emptyList();
        legacyItems = Collections.emptyList();
        filteredLegacyItems = Collections.emptyList();
        frameItems.clear();
        layoutEngine.reset();
    }
}
