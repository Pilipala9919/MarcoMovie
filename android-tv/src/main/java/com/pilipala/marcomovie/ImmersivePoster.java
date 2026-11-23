package com.pilipala.marcomovie;

import android.graphics.*;
import android.util.LruCache;
import android.view.*;
import android.widget.*;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.util.Calendar;
import java.util.LinkedHashSet;
import java.util.Locale;
import java.util.Objects;
import java.util.Set;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import org.json.JSONArray;
import org.json.JSONObject;

/**
 * Immersive full-bleed TV hero backdrop & poster engine.
 *
 * <p>Combines:
 * <ul>
 *   <li>Strictly verified 16:9 HD horizontal poster / official still resolution (Douban Rexxar
 *       official subject stills and Bilibili PGC horizontal covers verified against exact title,
 *       release year, and cast/director) so TV backgrounds use genuine widescreen HD artwork with
 *       zero poster mismatch.
 *   <li>Non-stretched vertical poster fallback (scaled strictly by height with feathered side edges
 *       over an ambient color aura) when only a vertical poster is available.
 *   <li>Mobile-style progressive lower frosted-glass blur, dynamic ambient color extraction, and
 *       scroll-driven blur/veil transition.
 * </ul>
 */
final class ImmersivePoster extends FrameLayout {
    interface AmbientListener {
        void onAmbientChanged(int color);
    }

    static final class Ratings {
        final double douban;
        final int rtPercent;
        final long fetchedAtMs;

        Ratings(double douban, int rtPercent, long fetchedAtMs) {
            this.douban = douban;
            this.rtPercent = rtPercent;
            this.fetchedAtMs = fetchedAtMs;
        }
    }

    static final class CastMember {
        final String name;
        final String role;
        final String avatarUrl;
        final boolean director;

        CastMember(String name, String role, String avatarUrl, boolean director) {
            this.name = name == null ? "" : name.trim();
            this.role = role == null ? "" : role.trim();
            this.avatarUrl = avatarUrl == null ? "" : avatarUrl.trim();
            this.director = director;
        }
    }

    static final class SubjectDetails {
        final String year;
        final String countries;
        final int episodesCount;
        final int seasonsCount;
        final String duration;
        final String genres;
        final String intro;
        final String posterUrl;
        final double doubanScore;
        final int rtPercent;
        final java.util.List<CastMember> cast;
        final long fetchedAtMs;

        SubjectDetails(
                String year,
                String countries,
                int episodesCount,
                String duration,
                String genres,
                String intro,
                String posterUrl,
                double doubanScore,
                int rtPercent,
                java.util.List<CastMember> cast,
                long fetchedAtMs) {
            this(
                    year,
                    countries,
                    episodesCount,
                    0,
                    duration,
                    genres,
                    intro,
                    posterUrl,
                    doubanScore,
                    rtPercent,
                    cast,
                    fetchedAtMs);
        }

        SubjectDetails(
                String year,
                String countries,
                int episodesCount,
                int seasonsCount,
                String duration,
                String genres,
                String intro,
                String posterUrl,
                double doubanScore,
                int rtPercent,
                java.util.List<CastMember> cast,
                long fetchedAtMs) {
            this.year = year == null ? "" : year.trim();
            this.countries = countries == null ? "" : countries.trim();
            this.episodesCount = Math.max(0, episodesCount);
            this.seasonsCount = Math.max(0, seasonsCount);
            this.duration = duration == null ? "" : duration.trim();
            this.genres = genres == null ? "" : genres.trim();
            this.intro = intro == null ? "" : intro.trim();
            this.posterUrl = posterUrl == null ? "" : posterUrl.trim();
            this.doubanScore = doubanScore;
            this.rtPercent = rtPercent;
            this.cast =
                    cast == null
                            ? java.util.Collections.emptyList()
                            : java.util.Collections.unmodifiableList(
                                    new java.util.ArrayList<>(cast));
            this.fetchedAtMs = fetchedAtMs;
        }
    }

    static final int WIDE_MEM_CACHE_MAX_BYTES = 10 * 1024 * 1024;
    static final int HERO_FEATHERED_CACHE_MAX_BYTES = 6 * 1024 * 1024;
    static final int PORTRAIT_HD_MEM_CACHE_MAX_BYTES = 8 * 1024 * 1024;
    private static final int MAX_DISK_IMAGE_BYTES = 8 * 1024 * 1024;

    private static LruCache<String, Bitmap> newByteBoundedBitmapCache(int maxBytes) {
        return new LruCache<String, Bitmap>(maxBytes) {
            @Override
            protected int sizeOf(String key, Bitmap value) {
                if (value == null || value.isRecycled()) return 1;
                return Math.max(1, value.getByteCount());
            }
        };
    }

    private static final LruCache<String, Bitmap> WIDE_MEM_CACHE =
            newByteBoundedBitmapCache(WIDE_MEM_CACHE_MAX_BYTES);
    private static final LruCache<String, Bitmap> HERO_FEATHERED_CACHE =
            newByteBoundedBitmapCache(HERO_FEATHERED_CACHE_MAX_BYTES);
    private static final LruCache<String, Bitmap> PORTRAIT_HD_MEM_CACHE =
            newByteBoundedBitmapCache(PORTRAIT_HD_MEM_CACHE_MAX_BYTES);
    private static volatile boolean lowRamBudget = false;

    /**
     * API 23 (Android 6.0.1) low-RAM Mali-450 TV GPUs (e.g., MiTV OS 1.3.130) crash RenderThread
     * or hit EGL_OUT_OF_MEMORY on nested 1080p {@code Canvas.saveLayer} + {@code DST_IN} offscreen
     * FBO allocations during detail-card navigation. Use direct clipped canvas + ambient gradient
     * feathering instead.
     */
    static boolean useLightweightBackdropDraw(int sdkInt, boolean reducedMotion) {
        return sdkInt <= 23 || reducedMotion;
    }

    static void applyMemoryBudget(int memoryClassMb) {
        if (memoryClassMb <= 0 || memoryClassMb > 192) return;
        lowRamBudget = true;
        if (android.os.Build.VERSION.SDK_INT >= 21) {
            try {
                if (memoryClassMb <= 128) {
                    WIDE_MEM_CACHE.resize(3 * 1024 * 1024);
                    HERO_FEATHERED_CACHE.resize(2 * 1024 * 1024);
                    PORTRAIT_HD_MEM_CACHE.resize(2 * 1024 * 1024);
                } else {
                    WIDE_MEM_CACHE.resize(5 * 1024 * 1024);
                    HERO_FEATHERED_CACHE.resize(3 * 1024 * 1024);
                    PORTRAIT_HD_MEM_CACHE.resize(4 * 1024 * 1024);
                }
            } catch (Throwable ignored) {
            }
        }
    }

    static void trimMemory(int level) {
        if (level >= android.content.ComponentCallbacks2.TRIM_MEMORY_RUNNING_LOW
                || level >= android.content.ComponentCallbacks2.TRIM_MEMORY_MODERATE) {
            WIDE_MEM_CACHE.evictAll();
            HERO_FEATHERED_CACHE.evictAll();
            PORTRAIT_HD_MEM_CACHE.evictAll();
        } else if (level >= android.content.ComponentCallbacks2.TRIM_MEMORY_UI_HIDDEN) {
            WIDE_MEM_CACHE.trimToSize(WIDE_MEM_CACHE_MAX_BYTES / 2);
            HERO_FEATHERED_CACHE.trimToSize(HERO_FEATHERED_CACHE_MAX_BYTES / 2);
            PORTRAIT_HD_MEM_CACHE.trimToSize(PORTRAIT_HD_MEM_CACHE_MAX_BYTES / 2);
        }
    }

    private static final LruCache<String, Double> DOUBAN_RATING_CACHE = new LruCache<>(96);
    private static final LruCache<String, Integer> RT_RATING_CACHE = new LruCache<>(96);
    private static final LruCache<String, Ratings> MEDIA_RATINGS_CACHE = new LruCache<>(128);
    private static final LruCache<String, SubjectDetails> SUBJECT_DETAILS_CACHE =
            new LruCache<>(64);
    private static final LruCache<String, java.util.List<DoubanCandidate>> DOUBAN_SUBJECT_CACHE =
            new LruCache<>(96);
    private static final LruCache<String, String> DOUBAN_REXXAR_JSON_CACHE = new LruCache<>(96);
    private static final java.util.concurrent.ConcurrentHashMap<String, Object>
            DOUBAN_SUBJECT_LOCKS = new java.util.concurrent.ConcurrentHashMap<>();
    private static final java.util.concurrent.ConcurrentHashMap<
                    String, java.util.concurrent.CopyOnWriteArrayList<MainActivity.Done<Ratings>>>
            INFLIGHT_RATINGS = new java.util.concurrent.ConcurrentHashMap<>();
    private static final java.util.concurrent.ConcurrentHashMap<
                    String,
                    java.util.concurrent.CopyOnWriteArrayList<MainActivity.Done<SubjectDetails>>>
            INFLIGHT_SUBJECT_DETAILS = new java.util.concurrent.ConcurrentHashMap<>();
    private static final String SESSION_DOUBAN_BID = generateDoubanBid();
    private static final Pattern YEAR_PATTERN = Pattern.compile("((?:19|20)\\d{2})");
    private static final java.util.concurrent.ExecutorService HD_POOL =
            java.util.concurrent.Executors.newFixedThreadPool(
                    4,
                    r -> {
                        Thread t = new Thread(r, "immersive-hd-backdrop");
                        t.setDaemon(true);
                        return t;
                    });
    private static final java.util.concurrent.ExecutorService RATING_POOL =
            java.util.concurrent.Executors.newFixedThreadPool(
                    4,
                    r -> {
                        Thread t = new Thread(r, "media-ratings-resolver");
                        t.setDaemon(true);
                        return t;
                    });
    private static volatile boolean legacyCachePurged = false;

    private static String generateDoubanBid() {
        final String chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
        java.util.Random rnd = new java.util.Random();
        StringBuilder sb = new StringBuilder(11);
        for (int i = 0; i < 11; i++) {
            sb.append(chars.charAt(rnd.nextInt(chars.length())));
        }
        return sb.toString();
    }

    final MainActivity a;
    final Art image;
    final Backdrop backdrop;
    boolean immersiveMode = true;
    int revision;
    int hdRevision;
    String currentAddress = "";
    String currentTitle = "";
    String currentYear = "";
    String currentActor = "";
    String currentDirector = "";
    AmbientListener onAmbientChanged;

    ImmersivePoster(MainActivity host, String tag) {
        super(host);
        a = host;
        setTag(tag);
        setFocusable(false);
        setClickable(false);
        setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO);
        backdrop = new Backdrop();
        TextView placeholder = a.text("暂无封面", 14, MainActivity.MUTED);
        placeholder.setGravity(Gravity.CENTER);
        addView(placeholder, new LayoutParams(-1, -1));
        image = new Art();
        image.setScaleType(ImageView.ScaleType.FIT_CENTER);
        addView(image, new LayoutParams(-1, -1));
        purgeLegacyMismatchedCacheAsync();
    }

    private void purgeLegacyMismatchedCacheAsync() {
        if (legacyCachePurged) return;
        legacyCachePurged = true;
        HD_POOL.execute(
                () -> {
                    try {
                        File dir = a.getCacheDir();
                        File[] files = dir == null ? null : dir.listFiles();
                        if (files == null) return;
                        for (File f : files) {
                            String name = f.getName();
                            if (name.startsWith("tv_wide_v1_")
                                    || name.startsWith("tv_wide_v2_")
                                    || name.startsWith("tv_wide_v3_")
                                    || name.startsWith("tv_wide_v4_")) {
                                // Delete legacy cached images (v4 lacked W/R official poster
                                // ranking)
                                f.delete();
                            }
                        }
                    } catch (Exception ignored) {
                    }
                });
    }

    @Override
    protected void dispatchDraw(Canvas canvas) {
        if (immersiveMode) {
            // In immersive TV mode, the full-bleed Backdrop view renders the hero artwork.
            // Keep this view's bounds for layout/decode policies without drawing a boxed card.
            return;
        }
        super.dispatchDraw(canvas);
    }

    void load(String address) {
        load(address, currentTitle, currentYear, currentActor, currentDirector, false);
    }

    void load(String address, String title) {
        load(address, title, currentYear, currentActor, currentDirector, false);
    }

    void load(
            String address,
            String title,
            String year,
            String actor,
            String director,
            boolean resolveWide) {
        load(address, title, year, actor, director, resolveWide, false);
    }

    void load(
            String address,
            String title,
            String year,
            String actor,
            String director,
            boolean resolveWide,
            boolean likelyTvSeries) {
        String nextAddress = address == null ? "" : address.trim();
        String nextTitle = title == null ? "" : title.trim();
        if (!Objects.equals(nextTitle, currentTitle)
                || (!nextAddress.isEmpty() && !Objects.equals(nextAddress, currentAddress))) {
            backdrop.wideBitmap = null;
            backdrop.wideBlurredBitmap = null;
            backdrop.invalidate();
        }
        currentAddress = nextAddress;
        if (!nextTitle.isEmpty()) currentTitle = nextTitle;
        if (year != null && !year.trim().isEmpty()) currentYear = extractFourDigitYear(year);
        if (actor != null && !actor.trim().isEmpty()) currentActor = actor.trim();
        if (director != null && !director.trim().isEmpty()) currentDirector = director.trim();

        a.poster(currentAddress, image, true);
        if (resolveWide && !currentTitle.isEmpty()) {
            resolveHdBackdrop(
                    currentTitle,
                    currentYear,
                    currentActor,
                    currentDirector,
                    currentAddress,
                    likelyTvSeries);
        }
    }

    void soften(Bitmap bitmap) {
        final int token = ++revision;
        final int generation = a.generation;
        if (bitmap == null) {
            backdrop.rawBitmap = null;
            backdrop.bitmap = null;
            backdrop.invalidate();
            return;
        }
        backdrop.rawBitmap = bitmap;
        backdrop.invalidate();
        HD_POOL.execute(
                () -> {
                    try {
                        if (bitmap.isRecycled()) return;
                        final int extractedAmbient =
                                MobileDetailScreen.extractAmbientColor(bitmap, 0xff090c14);
                        Bitmap blurred = createSoftenedBitmap(bitmap, 72, 108, 3, 3);
                        a.ui.post(
                                () -> {
                                    if (token != revision
                                            || generation != a.generation
                                            || a.isFinishing()) {
                                        return;
                                    }
                                    backdrop.rawBitmap = bitmap;
                                    backdrop.bitmap = blurred;
                                    if (backdrop.wideBitmap == null) {
                                        backdrop.ambientColor = extractedAmbient;
                                        if (onAmbientChanged != null) {
                                            onAmbientChanged.onAmbientChanged(extractedAmbient);
                                        }
                                    }
                                    backdrop.invalidate();
                                });
                    } catch (Throwable ignored) {
                    }
                });
    }

    private static Bitmap createSoftenedBitmap(
            Bitmap source, int targetW, int targetH, int passes, int radius) {
        if (source == null || source.isRecycled()) return null;
        // Never alter or recycle the shared image-cache bitmap.
        Bitmap small = Bitmap.createScaledBitmap(source, targetW, targetH, true);
        int[] src = new int[targetW * targetH];
        small.getPixels(src, 0, targetW, 0, 0, targetW, targetH);
        if (small != source) small.recycle();
        int[] tmp = new int[src.length];
        int window = radius * 2 + 1;
        for (int pass = 0; pass < passes; pass++) {
            // Fast separable 1D horizontal blur
            for (int y = 0; y < targetH; y++) {
                int row = y * targetW;
                int rSum = 0, gSum = 0, bSum = 0;
                for (int dx = -radius; dx <= radius; dx++) {
                    int c = src[row + Math.max(0, Math.min(targetW - 1, dx))];
                    rSum += (c >> 16) & 0xff;
                    gSum += (c >> 8) & 0xff;
                    bSum += c & 0xff;
                }
                for (int x = 0; x < targetW; x++) {
                    tmp[row + x] =
                            0xff000000
                                    | ((rSum / window) << 16)
                                    | ((gSum / window) << 8)
                                    | (bSum / window);
                    int addX = Math.min(targetW - 1, x + radius + 1);
                    int subX = Math.max(0, x - radius);
                    int addC = src[row + addX];
                    int subC = src[row + subX];
                    rSum += ((addC >> 16) & 0xff) - ((subC >> 16) & 0xff);
                    gSum += ((addC >> 8) & 0xff) - ((subC >> 8) & 0xff);
                    bSum += (addC & 0xff) - (subC & 0xff);
                }
            }
            // Fast separable 1D vertical blur
            for (int x = 0; x < targetW; x++) {
                int rSum = 0, gSum = 0, bSum = 0;
                for (int dy = -radius; dy <= radius; dy++) {
                    int c = tmp[Math.max(0, Math.min(targetH - 1, dy)) * targetW + x];
                    rSum += (c >> 16) & 0xff;
                    gSum += (c >> 8) & 0xff;
                    bSum += c & 0xff;
                }
                for (int y = 0; y < targetH; y++) {
                    src[y * targetW + x] =
                            0xff000000
                                    | ((rSum / window) << 16)
                                    | ((gSum / window) << 8)
                                    | (bSum / window);
                    int addY = Math.min(targetH - 1, y + radius + 1);
                    int subY = Math.max(0, y - radius);
                    int addC = tmp[addY * targetW + x];
                    int subC = tmp[subY * targetW + x];
                    rSum += ((addC >> 16) & 0xff) - ((subC >> 16) & 0xff);
                    gSum += ((addC >> 8) & 0xff) - ((subC >> 8) & 0xff);
                    bSum += (addC & 0xff) - (subC & 0xff);
                }
            }
        }
        return Bitmap.createBitmap(src, targetW, targetH, Bitmap.Config.ARGB_8888);
    }

    private static String extractFourDigitYear(String raw) {
        if (raw == null) return "";
        Matcher m = YEAR_PATTERN.matcher(raw);
        return m.find() ? m.group(1) : "";
    }

    private static String extractMediaFormatQualifier(String text) {
        if (text == null || text.isEmpty()) return "";
        StringBuilder sb = new StringBuilder();
        if (text.contains("动态漫")) sb.append("#dongtaiman");
        else if (text.contains("短漫") || text.contains("漫剧")) sb.append("#manju");
        else if (text.contains("漫画")) sb.append("#manhua");
        if (text.contains("真人")) sb.append("#liveaction");
        return sb.toString();
    }

    static String normalizeTitleForBackdrop(String rawTitle) {
        if (rawTitle == null) return "";
        String base =
                rawTitle.replaceAll(
                                "(?i)\\b(2160p|1080p|720p|4k|hdr|dv|hq|hd|bd|remux|bluray|web-?dl|mp4|mkv|x264|x265|hevc|h264|h265)\\b",
                                "")
                        .replaceAll(
                                "【(?![^】]*(?:动态漫|漫剧|短漫|漫画|真人|第\\s*[一二三四五六七八九十2-9]+\\s*[季部]|(?i)season\\s*\\d))[^】]*】|\\[(?![^\\]]*(?:动态漫|漫剧|短漫|漫画|真人|第\\s*[一二三四五六七八九十2-9]+\\s*[季部]|(?i)season\\s*\\d))[^\\]]*\\]|\\((?![^)]*(?:动态漫|漫剧|短漫|漫画|真人|第\\s*[一二三四五六七八九十2-9]+\\s*[季部]|(?i)season\\s*\\d))[^)]*\\)|（(?![^）]*(?:动态漫|漫剧|短漫|漫画|真人|第\\s*[一二三四五六七八九十2-9]+\\s*[季部]|(?i)season\\s*\\d))[^）]*）",
                                " ")
                        .replaceAll("(全集|高清|超清|未删减|国语|粤语|双语|中字|特效字幕|完结|更新至.*)", "")
                        .replaceAll("(?<=[\\u4e00-\\u9fa5A-Za-z])\\s*(?:19|20)\\d{2}\\s*$", "")
                        .replaceAll("\\s{2,}", " ")
                        .trim();
        return base.isEmpty() ? rawTitle.trim() : base;
    }

    static String extractSequelPrefixBeforeSubtitle(String s) {
        if (s == null) return "";
        String noHtml = s.replaceAll("<[^>]*>", "").trim();
        String formatTag = extractMediaFormatQualifier(noHtml);
        String normalized = SearchVariants.normalizeUnicodeRoman(noHtml);
        Matcher m =
                Pattern.compile(
                                "^([\\u4e00-\\u9fa5A-Za-z]{2,14}\\s*(?:[2-9]|VIII|VII|III|IX|IV|VI|II|V|第\\s*[二三四五六七八九2-9]\\s*[季部]))\\s*(?:[：:·\\-—]\\s*|\\s+)[\\u4e00-\\u9fa5A-Za-z0-9]{2,}.*$")
                        .matcher(normalized);
        if (m.matches()) {
            return m.group(1).trim() + formatTag;
        }
        return s;
    }

    static String normalizeForStrictCompare(String s) {
        if (s == null) return "";
        String noHtml = s.replaceAll("<[^>]*>", "");
        String formatTag = extractMediaFormatQualifier(noHtml);
        String base =
                noHtml.replaceAll(
                                "【(?![^】]*(?:第\\s*[一二三四五六七八九十2-9]+\\s*[季部]|(?i)season\\s*\\d))[^】]*】|\\[(?![^\\]]*(?:第\\s*[一二三四五六七八九十2-9]+\\s*[季部]|(?i)season\\s*\\d))[^\\]]*\\]|\\((?![^)]*(?:第\\s*[一二三四五六七八九十2-9]+\\s*[季部]|(?i)season\\s*\\d))[^)]*\\)|（(?![^）]*(?:第\\s*[一二三四五六七八九十2-9]+\\s*[季部]|(?i)season\\s*\\d))[^）]*）",
                                " ")
                        .replaceAll("(?:动态漫|短漫|漫剧|漫画|真人版|真人剧)", "")
                        .replaceAll("(?<=[\\u4e00-\\u9fa5A-Za-z])\\s*(?:19|20)\\d{2}\\s*$", "");
        String normalized = SearchVariants.canonicalSearchKey(base);
        return (normalized + formatTag).trim();
    }

    interface HeroColorsCallback {
        void onHeroColors(int leftColor, int rightColor);
    }

    /**
     * Composes a top-weighted exact-aspect hero texture with both a left readability vignette and
     * a smooth bottom alpha feather (0x00 transparent at the bottom row) baked into one bitmap.
     * Draws as a single hardware ImageView pass with zero saveLayer and zero hard seam against
     * {@link HomeAmbient}.
     */
    static Bitmap composeFeatheredHeroBitmap(Bitmap src, int viewWidthPx, int viewHeightPx) {
        if (src == null || src.isRecycled()) return null;
        int outW = Math.max(320, Math.min(960, viewWidthPx > 0 ? viewWidthPx / 2 : 960));
        int outH =
                viewWidthPx > 0 && viewHeightPx > 0
                        ? Math.max(160, Math.round(outW * (viewHeightPx / (float) viewWidthPx)))
                        : Math.max(180, Math.round(outW * 0.34f));
        Bitmap out;
        try {
            out = Bitmap.createBitmap(outW, outH, Bitmap.Config.ARGB_8888);
        } catch (Throwable ignored) {
            return null;
        }
        Canvas c = new Canvas(out);

        // Top-weighted CENTER_CROP (26% from top) preserves faces while filling the wide hero.
        float sw = src.getWidth(), sh = src.getHeight();
        float scale = Math.max(outW / sw, outH / sh);
        float drawW = sw * scale;
        float drawH = sh * scale;
        float dx = (outW - drawW) * 0.5f;
        float dy = (outH - drawH) * 0.26f;
        Paint imgPaint =
                new Paint(Paint.ANTI_ALIAS_FLAG | Paint.FILTER_BITMAP_FLAG | Paint.DITHER_FLAG);
        c.drawBitmap(src, null, new RectF(dx, dy, dx + drawW, dy + drawH), imgPaint);

        // Soft left cinema vignette baked before alpha mask so its bottom edge also dissolves to 0.
        Paint scrimPaint = new Paint(Paint.ANTI_ALIAS_FLAG | Paint.DITHER_FLAG);
        scrimPaint.setShader(
                new LinearGradient(
                        0f,
                        0f,
                        outW,
                        0f,
                        new int[] {0xdc0b0e14, 0xaa0b0e14, 0x420b0e14, 0x000b0e14},
                        new float[] {0f, 0.28f, 0.56f, 0.82f},
                        Shader.TileMode.CLAMP));
        c.drawRect(0f, 0f, outW, outH, scrimPaint);

        // Subtle top-edge feather for crisp logo contrast.
        scrimPaint.setShader(
                new LinearGradient(
                        0f,
                        0f,
                        0f,
                        outH * 0.26f,
                        new int[] {0x660b0e14, 0x000b0e14},
                        null,
                        Shader.TileMode.CLAMP));
        c.drawRect(0f, 0f, outW, outH * 0.26f, scrimPaint);

        // Smooth bottom alpha dissolve (DST_IN): bottom 50% fades smoothly to 0x00 transparent so
        // the hero melts invisibly into HomeAmbient below with zero horizontal boundary.
        Paint maskPaint = new Paint(Paint.ANTI_ALIAS_FLAG | Paint.DITHER_FLAG);
        maskPaint.setXfermode(new PorterDuffXfermode(PorterDuff.Mode.DST_IN));
        maskPaint.setShader(
                new LinearGradient(
                        0f,
                        0f,
                        0f,
                        outH,
                        new int[] {
                            0xffffffff,
                            0xffffffff,
                            0xe6ffffff,
                            0xa6ffffff,
                            0x48ffffff,
                            0x12ffffff,
                            0x00ffffff
                        },
                        new float[] {0f, 0.46f, 0.60f, 0.74f, 0.86f, 0.94f, 1.0f},
                        Shader.TileMode.CLAMP));
        c.drawRect(0f, 0f, outW, outH, maskPaint);
        return out;
    }

    static void prewarmOfficialLandscape(MainActivity a, Cms.Video item) {
        if (a == null || item == null || item.title == null || item.title.trim().isEmpty()) return;
        loadOfficialLandscapeInto(a, item, null, null, 0, 0, null);
    }

    /**
     * Lightweight hardware-accelerated loader for the full-bleed Home Hero ImageView.
     * Reuses the same verified W -> R -> Bilibili horizontal_cover -> S ranking and
     * WIDE_MEM_CACHE / tv_wide_v5_ disk cache, compositing a bottom-feathered exact-aspect bitmap
     * off the UI thread so the hero blends seamlessly into {@link HomeAmbient} with zero saveLayer.
     */
    static void loadOfficialLandscapeInto(
            MainActivity a,
            Cms.Video item,
            ImageView target,
            int[] requestSeq,
            int viewWidthPx,
            int viewHeightPx,
            HeroColorsCallback colorsCallback) {
        if (a == null || item == null) return;
        final int token = requestSeq != null ? ++requestSeq[0] : 0;
        final String cleanTitle = normalizeTitleForBackdrop(item.title);
        if (cleanTitle.isEmpty()) return;
        if (item.poster != null && item.poster.contains("fixture.test")) return;

        final String cleanYear = extractFourDigitYear(item.year);
        final String cacheKey = (cleanTitle + "#" + cleanYear).toLowerCase(Locale.ROOT);
        final String featheredKey = cacheKey + "@" + viewWidthPx + "x" + viewHeightPx;
        if (target != null) {
            Bitmap featheredCached = HERO_FEATHERED_CACHE.get(featheredKey);
            if (featheredCached != null && !featheredCached.isRecycled()) {
                target.setTag(null);
                target.setImageBitmap(featheredCached);
                Bitmap rawMem = WIDE_MEM_CACHE.get(cacheKey);
                if (colorsCallback != null && rawMem != null && !rawMem.isRecycled()) {
                    int c0 = HomeAmbient.sample(rawMem, 0);
                    int c1 = HomeAmbient.harmonizeSecondary(c0, HomeAmbient.sample(rawMem, 1));
                    colorsCallback.onHeroColors(c0, c1);
                }
                return;
            }
        }
        final int generation = a.generation;
        final boolean likelyTvSeries = !"电影".equals(item.tag);
        final String rawActor = item.actor == null ? "" : item.actor;
        final String rawDirector = item.director == null ? "" : item.director;
        final String fallbackPosterUrl = item.poster == null ? "" : item.poster.trim();
        HD_POOL.execute(
                () -> {
                    if (generation != a.generation || a.isFinishing()) return;
                    if (requestSeq != null && token != requestSeq[0]) return;
                    try {
                        Bitmap wide = WIDE_MEM_CACHE.get(cacheKey);
                        if ((wide == null || wide.isRecycled()) && !cleanYear.isEmpty()) {
                            wide = WIDE_MEM_CACHE.get((cleanTitle + "#").toLowerCase(Locale.ROOT));
                        }
                        if (wide == null || wide.isRecycled()) {
                            File diskFile =
                                    new File(
                                            a.getCacheDir(),
                                            "tv_wide_v5_"
                                                    + Integer.toHexString(cacheKey.hashCode())
                                                    + ".img");
                            if (diskFile.exists() && diskFile.length() > 8192) {
                                wide = decodeWideBytes(readFileBytes(diskFile));
                                if (wide != null) {
                                    WIDE_MEM_CACHE.put(cacheKey, wide);
                                } else {
                                    diskFile.delete();
                                }
                            }
                            if (wide == null) {
                                Set<String> candidates = new LinkedHashSet<>();
                                collectVerifiedDoubanOfficialLandscape(
                                        cleanTitle,
                                        cleanYear,
                                        rawActor,
                                        rawDirector,
                                        likelyTvSeries,
                                        candidates);
                                if (candidates.isEmpty()) {
                                    collectVerifiedBilibiliHorizontalCovers(
                                            cleanTitle, cleanYear, candidates);
                                }
                                if (candidates.isEmpty()) {
                                    collectVerifiedDoubanStillsFallback(
                                            cleanTitle, cleanYear, likelyTvSeries, candidates);
                                }
                                for (String candidate : candidates) {
                                    if (generation != a.generation || a.isFinishing()) return;
                                    if (requestSeq != null && token != requestSeq[0]) return;
                                    byte[] data = downloadImageBytes(candidate, 5500);
                                    if (data == null || data.length < 10240) continue;
                                    Bitmap decoded = decodeWideBytes(data);
                                    if (decoded != null) {
                                        writeFileBytesAtomically(diskFile, data);
                                        WIDE_MEM_CACHE.put(cacheKey, decoded);
                                        wide = decoded;
                                        break;
                                    }
                                }
                            }
                        }
                        if (wide == null && !fallbackPosterUrl.isEmpty()) {
                            byte[] fallbackData = downloadImageBytes(fallbackPosterUrl, 5000);
                            if (fallbackData != null && fallbackData.length > 2048) {
                                wide = decodePortraitHdBytes(fallbackData);
                            }
                        }
                        if (wide == null || wide.isRecycled()) return;
                        if (target == null) return;
                        if (generation != a.generation || a.isFinishing()) return;
                        if (requestSeq != null && token != requestSeq[0]) return;
                        final Bitmap feathered =
                                composeFeatheredHeroBitmap(wide, viewWidthPx, viewHeightPx);
                        if (feathered == null) return;
                        HERO_FEATHERED_CACHE.put(featheredKey, feathered);
                        final int c0 = HomeAmbient.sample(wide, 0);
                        final int c1 =
                                HomeAmbient.harmonizeSecondary(c0, HomeAmbient.sample(wide, 1));
                        a.ui.post(
                                () -> {
                                    if (generation != a.generation
                                            || a.isFinishing()
                                            || (requestSeq != null && token != requestSeq[0])) {
                                        return;
                                    }
                                    target.setTag(null);
                                    target.setImageBitmap(feathered);
                                    if (colorsCallback != null) {
                                        colorsCallback.onHeroColors(c0, c1);
                                    }
                                });
                    } catch (Throwable ignored) {
                    }
                });
    }

    void resolveHdBackdrop(
            String rawTitle,
            String rawYear,
            String rawActor,
            String rawDirector,
            String posterUrl,
            boolean likelyTvSeries) {
        final String cleanTitle = normalizeTitleForBackdrop(rawTitle);
        if (cleanTitle.isEmpty()) return;
        // Skip synthetic fixture URLs during unit/device probes so offline fixtures remain
        // deterministic
        if (posterUrl != null && posterUrl.contains("fixture.test")) return;
        if ("选集响应样本".equals(cleanTitle) || "独立调度".equals(cleanTitle)) return;

        final String cleanYear = extractFourDigitYear(rawYear);
        final String cacheKey = (cleanTitle + "#" + cleanYear).toLowerCase(Locale.ROOT);
        Bitmap memCached = WIDE_MEM_CACHE.get(cacheKey);
        if (memCached == null && !cleanYear.isEmpty()) {
            memCached = WIDE_MEM_CACHE.get((cleanTitle + "#").toLowerCase(Locale.ROOT));
        }
        if (memCached != null && !memCached.isRecycled()) {
            applyWideBitmap(memCached);
            return;
        }
        if (backdrop.wideBitmap != null
                && !backdrop.wideBitmap.isRecycled()
                && Objects.equals(rawTitle == null ? "" : rawTitle.trim(), currentTitle)) {
            return;
        }
        final int token = ++hdRevision;
        final int generation = a.generation;
        HD_POOL.execute(
                () -> {
                    if (token != hdRevision || generation != a.generation) return;
                    try {
                        File diskFile =
                                new File(
                                        a.getCacheDir(),
                                        "tv_wide_v5_"
                                                + Integer.toHexString(cacheKey.hashCode())
                                                + ".img");
                        if (diskFile.exists() && diskFile.length() > 8192) {
                            Bitmap diskBmp = decodeWideBytes(readFileBytes(diskFile));
                            if (diskBmp != null) {
                                WIDE_MEM_CACHE.put(cacheKey, diskBmp);
                                postWideBitmap(diskBmp, token, generation);
                                return;
                            }
                            diskFile.delete();
                        }

                        Set<String> candidates = new LinkedHashSet<>();
                        // 1. Primary authoritative source: Douban official HD wallpapers (type=W)
                        //    and landscape official posters (type=R)
                        collectVerifiedDoubanOfficialLandscape(
                                cleanTitle,
                                cleanYear,
                                rawActor,
                                rawDirector,
                                likelyTvSeries,
                                candidates);
                        // 2. Secondary authoritative source: Bilibili official horizontal_cover
                        //    (verified by exact title + year, skipping random episode screenshots)
                        if (candidates.isEmpty()) {
                            collectVerifiedBilibiliHorizontalCovers(
                                    cleanTitle, cleanYear, candidates);
                        }
                        // 3. Fallback: strictly filtered & ranked Douban official 16:9 stills
                        //    (type=S, rejecting BTS/event/press/subtitle frames)
                        if (candidates.isEmpty()) {
                            collectVerifiedDoubanStillsFallback(
                                    cleanTitle, cleanYear, likelyTvSeries, candidates);
                        }

                        for (String candidate : candidates) {
                            if (token != hdRevision || generation != a.generation) return;
                            byte[] data = downloadImageBytes(candidate, 5500);
                            if (data == null || data.length < 10240) continue;
                            Bitmap wide = decodeWideBytes(data);
                            if (wide != null) {
                                writeFileBytesAtomically(diskFile, data);
                                WIDE_MEM_CACHE.put(cacheKey, wide);
                                postWideBitmap(wide, token, generation);
                                return;
                            }
                        }

                        // 3. Verified portrait HD fallback if no 16:9 still is available and source
                        //    poster failed or is missing/small.
                        if (token != hdRevision || generation != a.generation) return;
                        Bitmap curRaw = backdrop.rawBitmap;
                        boolean needsPortraitFallback =
                                curRaw == null || curRaw.isRecycled() || curRaw.getWidth() < 320;
                        if (needsPortraitFallback) {
                            Set<String> portraitCandidates = new LinkedHashSet<>();
                            collectVerifiedDoubanPosters(
                                    cleanTitle,
                                    cleanYear,
                                    rawActor,
                                    rawDirector,
                                    portraitCandidates);
                            collectVerifiedBilibiliVerticalCovers(
                                    cleanTitle, cleanYear, portraitCandidates);
                            for (String pCand : portraitCandidates) {
                                if (token != hdRevision || generation != a.generation) return;
                                byte[] pData = downloadImageBytes(pCand, 5500);
                                if (pData == null || pData.length < 8192) continue;
                                Bitmap portraitBmp = decodePortraitHdBytes(pData);
                                if (portraitBmp != null) {
                                    a.ui.post(
                                            () -> {
                                                if (token != hdRevision
                                                        || generation != a.generation
                                                        || a.isFinishing()) return;
                                                if (backdrop.wideBitmap == null) {
                                                    soften(portraitBmp);
                                                }
                                            });
                                    return;
                                }
                            }
                        }
                    } catch (Throwable ignored) {
                    }
                });
    }

    private void postWideBitmap(Bitmap wide, int token, int generation) {
        final int ambient = MobileDetailScreen.extractAmbientColor(wide, 0xff090c14);
        final Bitmap softWide = createSoftenedBitmap(wide, 96, 54, 3, 2);
        a.ui.post(
                () -> {
                    if (token != hdRevision || generation != a.generation || a.isFinishing()) {
                        return;
                    }
                    backdrop.wideBitmap = wide;
                    backdrop.wideBlurredBitmap = softWide;
                    backdrop.ambientColor = ambient;
                    if (onAmbientChanged != null) {
                        onAmbientChanged.onAmbientChanged(ambient);
                    }
                    backdrop.invalidate();
                });
    }

    private void applyWideBitmap(Bitmap wide) {
        backdrop.wideBitmap = wide;
        HD_POOL.execute(
                () -> {
                    try {
                        if (wide == null || wide.isRecycled()) return;
                        final int ambient =
                                MobileDetailScreen.extractAmbientColor(wide, 0xff090c14);
                        final Bitmap softWide = createSoftenedBitmap(wide, 96, 54, 3, 2);
                        a.ui.post(
                                () -> {
                                    if (a.isFinishing()) return;
                                    backdrop.wideBlurredBitmap = softWide;
                                    backdrop.ambientColor = ambient;
                                    if (onAmbientChanged != null) {
                                        onAmbientChanged.onAmbientChanged(ambient);
                                    }
                                    backdrop.invalidate();
                                });
                    } catch (Throwable ignored) {
                    }
                });
        backdrop.invalidate();
    }

    private static Bitmap decodeWideBytes(byte[] bytes) {
        if (bytes == null || bytes.length < 8192 || bytes.length > MAX_DISK_IMAGE_BYTES) {
            return null;
        }
        try {
            BitmapFactory.Options bounds = new BitmapFactory.Options();
            bounds.inJustDecodeBounds = true;
            BitmapFactory.decodeByteArray(bytes, 0, bytes.length, bounds);
            if (bounds.outWidth < 720
                    || bounds.outHeight < 380
                    || bounds.outWidth < bounds.outHeight * 1.22f) {
                return null;
            }
            BitmapFactory.Options opts = new BitmapFactory.Options();
            int targetW = lowRamBudget ? 960 : 1280;
            int targetH = lowRamBudget ? 540 : 720;
            int sample = 1;
            while ((bounds.outWidth / (sample * 2)) >= targetW
                    && (bounds.outHeight / (sample * 2)) >= targetH) {
                sample *= 2;
            }
            opts.inSampleSize = sample;
            opts.inPreferredConfig = Bitmap.Config.RGB_565;
            return BitmapFactory.decodeByteArray(bytes, 0, bytes.length, opts);
        } catch (Throwable ignored) {
            return null;
        }
    }

    private static byte[] readFileBytes(File f) {
        if (f == null || !f.isFile()) return null;
        long len = f.length();
        if (len <= 0 || len > MAX_DISK_IMAGE_BYTES) {
            if (len > MAX_DISK_IMAGE_BYTES) {
                try {
                    f.delete();
                } catch (Throwable ignored) {
                }
            }
            return null;
        }
        try (FileInputStream in = new FileInputStream(f);
                ByteArrayOutputStream out = new ByteArrayOutputStream((int) len)) {
            byte[] buf = new byte[8192];
            int n;
            int total = 0;
            while ((n = in.read(buf)) != -1) {
                total += n;
                if (total > MAX_DISK_IMAGE_BYTES) return null;
                out.write(buf, 0, n);
            }
            return out.toByteArray();
        } catch (Throwable e) {
            return null;
        }
    }

    private static void writeFileBytesAtomically(File target, byte[] data) {
        if (target == null
                || data == null
                || data.length == 0
                || data.length > MAX_DISK_IMAGE_BYTES) {
            return;
        }
        File tmp = new File(target.getParentFile(), target.getName() + ".tmp");
        try (FileOutputStream fos = new FileOutputStream(tmp)) {
            fos.write(data);
            fos.flush();
        } catch (Throwable ignored) {
            tmp.delete();
            return;
        }
        if (!tmp.renameTo(target)) {
            tmp.delete();
        }
    }

    static void resolveHdPortraitPoster(
            final MainActivity a,
            final String rawTitle,
            final String rawYear,
            final String rawActor,
            final String rawDirector,
            final String rawPosterUrl,
            final MainActivity.Done<Bitmap> onResolved) {
        resolveHdPortraitPoster(
                a, rawTitle, rawYear, rawActor, rawDirector, rawPosterUrl, true, onResolved);
    }

    static void resolveHdPortraitPoster(
            final MainActivity a,
            final String rawTitle,
            final String rawYear,
            final String rawActor,
            final String rawDirector,
            final String rawPosterUrl,
            final boolean allowThirdPartyLookup,
            final MainActivity.Done<Bitmap> onResolved) {
        if (a == null || onResolved == null) return;
        if (rawPosterUrl != null && rawPosterUrl.contains("fixture.test")) return;
        final String cleanTitle = normalizeTitleForBackdrop(rawTitle);
        if ("选集响应样本".equals(cleanTitle) || "独立调度".equals(cleanTitle)) return;
        final String cleanYear = extractFourDigitYear(rawYear);
        final boolean hasSourcePoster = Cms.isHttp(rawPosterUrl);
        final String upgradedDirect =
                !hasSourcePoster ? "" : ImageLoader.upgradePosterUrl(rawPosterUrl, true);
        final boolean hasDirectUpgrade =
                hasSourcePoster
                        && !upgradedDirect.isEmpty()
                        && !upgradedDirect.equals(rawPosterUrl);
        if (!allowThirdPartyLookup && !hasDirectUpgrade) {
            return;
        }
        if (cleanTitle.isEmpty() && !hasDirectUpgrade) return;

        final String cacheKey =
                "portrait_v4|"
                        + normalizeForStrictCompare(cleanTitle)
                        + "|"
                        + cleanYear
                        + "|"
                        + (allowThirdPartyLookup ? "hd:" + upgradedDirect : upgradedDirect);
        Bitmap mem = PORTRAIT_HD_MEM_CACHE.get(cacheKey);
        if (mem != null && !mem.isRecycled()) {
            try {
                onResolved.accept(mem);
            } catch (Exception ignored) {
            }
            return;
        }

        final int generation = a.generation;
        HD_POOL.execute(
                () -> {
                    if (generation != a.generation || a.isFinishing()) return;
                    try {
                        File diskFile =
                                new File(
                                        a.getCacheDir(),
                                        "mob_hd_poster_v4_"
                                                + Integer.toHexString(cacheKey.hashCode())
                                                + ".img");
                        if (diskFile.exists() && diskFile.length() > 12288) {
                            Bitmap diskBmp = decodePortraitHdBytes(readFileBytes(diskFile));
                            if (diskBmp != null) {
                                PORTRAIT_HD_MEM_CACHE.put(cacheKey, diskBmp);
                                a.ui.post(
                                        () -> {
                                            if (generation == a.generation && !a.isFinishing()) {
                                                try {
                                                    onResolved.accept(diskBmp);
                                                } catch (Exception ignored) {
                                                }
                                            }
                                        });
                                return;
                            }
                            diskFile.delete();
                        }

                        Set<String> candidates = new LinkedHashSet<>();
                        if (hasDirectUpgrade) {
                            candidates.add(upgradedDirect);
                        }
                        if (allowThirdPartyLookup && !cleanTitle.isEmpty()) {
                            collectVerifiedDoubanPosters(
                                    cleanTitle, cleanYear, rawActor, rawDirector, candidates);
                            collectVerifiedBilibiliVerticalCovers(
                                    cleanTitle, cleanYear, candidates);
                        }

                        for (String candidate : candidates) {
                            if (generation != a.generation || a.isFinishing()) return;
                            byte[] data = downloadImageBytes(candidate, 5500);
                            if (data == null || data.length < 12288) continue;
                            Bitmap hdBmp = decodePortraitHdBytes(data);
                            if (hdBmp != null) {
                                writeFileBytesAtomically(diskFile, data);
                                PORTRAIT_HD_MEM_CACHE.put(cacheKey, hdBmp);
                                a.ui.post(
                                        () -> {
                                            if (generation == a.generation && !a.isFinishing()) {
                                                try {
                                                    onResolved.accept(hdBmp);
                                                } catch (Exception ignored) {
                                                }
                                            }
                                        });
                                return;
                            }
                        }
                    } catch (Throwable ignored) {
                    }
                });
    }

    private static Bitmap decodePortraitHdBytes(byte[] bytes) {
        if (bytes == null || bytes.length < 12288 || bytes.length > MAX_DISK_IMAGE_BYTES) {
            return null;
        }
        try {
            BitmapFactory.Options bounds = new BitmapFactory.Options();
            bounds.inJustDecodeBounds = true;
            BitmapFactory.decodeByteArray(bytes, 0, bytes.length, bounds);
            if (bounds.outWidth < 460 || bounds.outHeight < 620) {
                return null;
            }
            BitmapFactory.Options opts = new BitmapFactory.Options();
            int sample = 1;
            while ((bounds.outWidth / (sample * 2)) >= 720
                    && (bounds.outHeight / (sample * 2)) >= 1080) {
                sample *= 2;
            }
            opts.inSampleSize = sample;
            opts.inPreferredConfig = Bitmap.Config.RGB_565;
            return BitmapFactory.decodeByteArray(bytes, 0, bytes.length, opts);
        } catch (Throwable ignored) {
            return null;
        }
    }

    private static final class DoubanCandidate {
        final String id;
        final String imgUrl;
        final double rating;
        final int score;
        final boolean isTv;
        final String subTitle;

        DoubanCandidate(
                String id, String imgUrl, double rating, int score, boolean isTv, String subTitle) {
            this.id = id;
            this.imgUrl = imgUrl;
            this.rating = rating;
            this.score = score;
            this.isTv = isTv;
            this.subTitle = subTitle == null ? "" : subTitle.trim();
        }
    }

    static double extractDoubanScoreFromText(String text) {
        if (text == null || text.isEmpty()) return 0.0;
        String clean = text.replace('\u3000', ' ').replace('\u00A0', ' ');
        Matcher m =
                Pattern.compile(
                                "(?:豆瓣(?:评分)?|Douban(?:\\s*评分)?|评分)\\s*[:：为是]?\\s*([2-9]\\.[0-9]|10\\.0)\\s*分?",
                                Pattern.CASE_INSENSITIVE)
                        .matcher(clean);
        if (m.find()) {
            try {
                double v = Double.parseDouble(m.group(1));
                if (v >= 2.0 && v <= 9.9) return v;
            } catch (NumberFormatException ignored) {
            }
        }
        return 0.0;
    }

    static int extractRtPercentFromText(String text) {
        if (text == null || text.isEmpty()) return -1;
        String clean = text.replace('\u3000', ' ').replace('\u00A0', ' ');
        Matcher m =
                Pattern.compile(
                                "(?:烂番茄(?:新鲜度|指数|好评率|评分|口碑)?[^0-9%\\n，。；！？]{0,8}|Tomatometer[^0-9%\\n]{0,18}|Rotten\\s*Tomatoes[^0-9%\\n]{0,24})\\s*(\\d{1,3})\\s*%|(\\d{1,3})\\s*%\\s*(?:的)?(?:烂番茄|新鲜度|Tomatometer)",
                                Pattern.CASE_INSENSITIVE)
                        .matcher(clean);
        if (m.find()) {
            String grp = m.group(1) != null ? m.group(1) : m.group(2);
            if (grp != null) {
                try {
                    int pct = Integer.parseInt(grp);
                    if (pct >= 1 && pct <= 100) return pct;
                } catch (NumberFormatException ignored) {
                }
            }
        }
        return -1;
    }

    private static String stripHtmlSnippet(String rawHtml) {
        if (rawHtml == null || rawHtml.isEmpty()) return "";
        return rawHtml.replaceAll("<[^>]*>", " ")
                .replace("&nbsp;", " ")
                .replace('\u3000', ' ')
                .replace('\u00A0', ' ')
                .replace("&quot;", "\"")
                .replace("&amp;", "&")
                .replace("&#39;", "'")
                .replace("&middot;", "·")
                .replaceAll("\\s+", " ")
                .trim();
    }

    private static boolean snippetMatchesTitleAndYear(
            String plain, String rawTitle, String englishTitle, int targetYear) {
        if (plain == null || plain.isEmpty()) return false;
        String lowerPlain = plain.toLowerCase(Locale.ROOT);
        String compactPlain = normalizeForStrictCompare(plain);
        String cleanTitle = normalizeTitleForBackdrop(rawTitle);
        String lowerClean = cleanTitle.toLowerCase(Locale.ROOT);
        String compactClean = normalizeForStrictCompare(cleanTitle);

        boolean titleMatched =
                (!lowerClean.isEmpty() && lowerPlain.contains(lowerClean))
                        || (!compactClean.isEmpty() && compactPlain.contains(compactClean));
        if (!titleMatched && englishTitle != null && englishTitle.trim().length() >= 3) {
            String lowerEn = englishTitle.trim().toLowerCase(Locale.ROOT);
            String compactEn = normalizeForStrictCompare(englishTitle);
            titleMatched =
                    lowerPlain.contains(lowerEn)
                            || (compactEn.length() >= 3 && compactPlain.contains(compactEn));
        }
        if (!titleMatched) return false;

        if (targetYear > 0) {
            Matcher ym = Pattern.compile("\\b((?:19|20)\\d{2})\\b").matcher(plain);
            boolean anyNear = false;
            boolean anyFar = false;
            int count = 0;
            while (ym.find()) {
                int y = parseYearInt(ym.group(1));
                if (y <= 0) continue;
                count++;
                int diff = Math.abs(y - targetYear);
                if (diff <= 2) anyNear = true;
                if (diff >= 4) anyFar = true;
            }
            if (count > 0 && !anyNear && anyFar) {
                return false;
            }
        }
        return true;
    }

    static int extractRtPercentFromBingHtml(
            String html, String rawTitle, String englishTitle, int targetYear) {
        if (html == null || html.isEmpty()) return -1;
        Matcher algoBlocks =
                Pattern.compile("<li\\s+class=\"b_algo\"[\\s\\S]*?</li>", Pattern.CASE_INSENSITIVE)
                        .matcher(html);
        Pattern rtPat =
                Pattern.compile(
                        "(?:烂番茄(?:新鲜度|指数|好评率|评分|口碑)?[^0-9%\\n，。；！？]{0,8}|Rotten\\s*Tomatoes[^0-9%\\n]{0,28}|Tomatometer[^0-9%\\n]{0,22})\\s*(\\d{1,3})\\s*%|(\\d{1,3})\\s*%\\s*(?:的)?(?:烂番茄|新鲜度|Tomatometer|on\\s+Rotten\\s+Tomatoes)",
                        Pattern.CASE_INSENSITIVE);
        while (algoBlocks.find()) {
            String block = algoBlocks.group(0);
            String plain = stripHtmlSnippet(block);
            if (!snippetMatchesTitleAndYear(plain, rawTitle, englishTitle, targetYear)) {
                continue;
            }
            boolean fromRtSite = block.toLowerCase(Locale.ROOT).contains("rottentomatoes.com");
            Matcher rtm = rtPat.matcher(plain);
            if (rtm.find()) {
                String grp = rtm.group(1) != null ? rtm.group(1) : rtm.group(2);
                if (grp != null) {
                    try {
                        int pct = Integer.parseInt(grp);
                        if (pct >= 1 && pct <= 100) return pct;
                    } catch (NumberFormatException ignored) {
                    }
                }
            }
            if (fromRtSite) {
                Matcher directPct = Pattern.compile("\\b(\\d{1,3})%").matcher(plain);
                if (directPct.find()) {
                    try {
                        int pct = Integer.parseInt(directPct.group(1));
                        if (pct >= 1 && pct <= 100) return pct;
                    } catch (NumberFormatException ignored) {
                    }
                }
            }
        }
        return -1;
    }

    static double extractDoubanScoreFromBingHtml(String html, String rawTitle, int targetYear) {
        if (html == null || html.isEmpty()) return 0.0;
        Matcher algoBlocks =
                Pattern.compile("<li\\s+class=\"b_algo\"[\\s\\S]*?</li>", Pattern.CASE_INSENSITIVE)
                        .matcher(html);
        Pattern dbPat =
                Pattern.compile(
                        "(?:豆瓣(?:评分)?|Douban[^0-9\\n]{0,16})\\s*[:：为是]?\\s*([2-9]\\.[0-9])\\s*分?",
                        Pattern.CASE_INSENSITIVE);
        while (algoBlocks.find()) {
            String block = algoBlocks.group(0);
            String plain = stripHtmlSnippet(block);
            if (!snippetMatchesTitleAndYear(plain, rawTitle, "", targetYear)) {
                continue;
            }
            Matcher dm = dbPat.matcher(plain);
            if (dm.find()) {
                try {
                    double v = Double.parseDouble(dm.group(1));
                    if (v >= 2.0 && v <= 9.9) return v;
                } catch (NumberFormatException ignored) {
                }
            }
        }
        return 0.0;
    }

    private static String fetchDoubanRexxarJson(String kind, String subjectId, int timeoutMs) {
        if (kind == null || kind.isEmpty() || subjectId == null || subjectId.isEmpty()) return null;
        String cacheKey = kind + ":" + subjectId;
        String cached = DOUBAN_REXXAR_JSON_CACHE.get(cacheKey);
        if (cached != null) return cached.isEmpty() ? null : cached;
        String url = "https://m.douban.com/rexxar/api/v2/" + kind + "/" + subjectId;
        String referer = "https://m.douban.com/movie/subject/" + subjectId + "/";
        String json = httpGetText(url, referer, true, timeoutMs);
        if (json != null && json.trim().startsWith("{")) {
            DOUBAN_REXXAR_JSON_CACHE.put(cacheKey, json);
            return json;
        }
        return null;
    }

    private static java.util.List<DoubanCandidate> findVerifiedDoubanSubjects(
            String title, String year) {
        String normTarget = normalizeForStrictCompare(title);
        if (normTarget.isEmpty()) return new java.util.ArrayList<>();
        String cleanYear = extractFourDigitYear(year);
        String subjectCacheKey = normTarget + "#" + cleanYear;
        java.util.List<DoubanCandidate> cached = DOUBAN_SUBJECT_CACHE.get(subjectCacheKey);
        if (cached != null) {
            return new java.util.ArrayList<>(cached);
        }
        Object lock = DOUBAN_SUBJECT_LOCKS.get(subjectCacheKey);
        if (lock == null) {
            Object created = new Object();
            Object prev = DOUBAN_SUBJECT_LOCKS.putIfAbsent(subjectCacheKey, created);
            lock = prev != null ? prev : created;
        }
        synchronized (lock) {
            cached = DOUBAN_SUBJECT_CACHE.get(subjectCacheKey);
            if (cached != null) {
                return new java.util.ArrayList<>(cached);
            }
            java.util.List<DoubanCandidate> fetched =
                    findVerifiedDoubanSubjectsUncached(title, normTarget, cleanYear);
            if (!fetched.isEmpty()) {
                DOUBAN_SUBJECT_CACHE.put(
                        subjectCacheKey,
                        java.util.Collections.unmodifiableList(new java.util.ArrayList<>(fetched)));
            }
            return fetched;
        }
    }

    private static java.util.List<DoubanCandidate> findVerifiedDoubanSubjectsUncached(
            String title, String normTarget, String cleanYear) {
        java.util.List<DoubanCandidate> results = new java.util.ArrayList<>();
        String altTitle = extractSequelPrefixBeforeSubtitle(title);
        String normAlt = normalizeForStrictCompare(altTitle);
        int targetYear = parseYearInt(cleanYear);

        String[] queries =
                altTitle.equals(title) ? new String[] {title} : new String[] {title, altTitle};

        // 1. Primary fast JSON resolver: movie.douban.com/j/subject_suggest (with session bid
        // cookie)
        for (String qStr : queries) {
            try {
                String suggestUrl =
                        "https://movie.douban.com/j/subject_suggest?q="
                                + URLEncoder.encode(qStr, "UTF-8");
                String json = httpGetText(suggestUrl, "https://movie.douban.com/", false, 2800);
                if (json != null && json.trim().startsWith("[")) {
                    JSONArray arr = new JSONArray(json);
                    for (int i = 0; i < arr.length(); i++) {
                        JSONObject item = arr.optJSONObject(i);
                        if (item == null) continue;
                        String itemUrl = item.optString("url", "");
                        String itemType = item.optString("type", "");
                        if (itemUrl.contains("/celebrity/")
                                || itemUrl.contains("/personage/")
                                || "celebrity".equalsIgnoreCase(itemType)) {
                            continue;
                        }
                        String id = item.optString("id").trim();
                        if (id.isEmpty()) continue;
                        String rawItemTitle = item.optString("title");
                        String rawSubTitle = item.optString("sub_title");
                        String itTitle = normalizeForStrictCompare(rawItemTitle);
                        String itTitleAlt =
                                normalizeForStrictCompare(
                                        extractSequelPrefixBeforeSubtitle(rawItemTitle));
                        String itSub = normalizeForStrictCompare(rawSubTitle);
                        if (!normTarget.equals(itTitle)
                                && !normTarget.equals(itTitleAlt)
                                && !normTarget.equals(itSub)
                                && !normAlt.equals(itTitle)) {
                            continue;
                        }
                        int itYear = parseYearInt(extractFourDigitYear(item.optString("year")));
                        int score = 45;
                        if (targetYear > 0 && itYear > 0) {
                            int diff = Math.abs(targetYear - itYear);
                            if (diff == 0) score = 100;
                            else if (diff == 1) score = 65;
                            else continue;
                        }
                        boolean isTv = !item.optString("episode", "").trim().isEmpty();
                        results.add(
                                new DoubanCandidate(
                                        id,
                                        item.optString("img", "").trim(),
                                        0.0,
                                        score,
                                        isTv,
                                        rawSubTitle));
                    }
                }
                if (!results.isEmpty()) break;
            } catch (Exception ignored) {
            }
        }

        // Skip slow mobile HTML search when subject_suggest already found a strong verified ID;
        // Rexxar API will return authoritative rating/metadata using that exact subject ID.
        boolean strongSuggestHit = false;
        for (DoubanCandidate c : results) {
            if (c.score >= 45 && !c.id.isEmpty()) {
                strongSuggestHit = true;
                break;
            }
        }

        // 2. Mobile HTML search fallback: only when subject_suggest yielded no verified match
        if (!strongSuggestHit) {
            for (String qStr : queries) {
                try {
                    String searchUrl =
                            "https://m.douban.com/search/?query="
                                    + URLEncoder.encode(qStr, "UTF-8")
                                    + "&type=movie";
                    String html = httpGetText(searchUrl, "https://m.douban.com/", true, 3200);
                    if (html != null && html.contains("/movie/subject/")) {
                        Matcher itemMatcher =
                                Pattern.compile(
                                                "<a\\s+href=\"/movie/subject/(\\d+)/\"[^>]*>([\\s\\S]*?)</a>",
                                                Pattern.CASE_INSENSITIVE)
                                        .matcher(html);
                        while (itemMatcher.find()) {
                            String sid = itemMatcher.group(1).trim();
                            String body = itemMatcher.group(2);
                            Matcher tm =
                                    Pattern.compile(
                                                    "<span\\s+class=\"subject-title\"[^>]*>([^<]+)</span>",
                                                    Pattern.CASE_INSENSITIVE)
                                            .matcher(body);
                            if (!tm.find()) continue;
                            String rawSubTitle = tm.group(1).trim();
                            String normSub = normalizeForStrictCompare(rawSubTitle);
                            String normSubAlt =
                                    normalizeForStrictCompare(
                                            extractSequelPrefixBeforeSubtitle(rawSubTitle));
                            if (!normTarget.equals(normSub)
                                    && !normAlt.equals(normSub)
                                    && !normTarget.equals(normSubAlt)) {
                                continue;
                            }
                            boolean hasDefaultImg = body.contains("default");
                            boolean unreleased = body.contains("尚未");
                            String imgUrl = "";
                            Matcher im = Pattern.compile("src=\"(https?://[^\"]+)\"").matcher(body);
                            if (im.find() && !hasDefaultImg) {
                                imgUrl = im.group(1).trim();
                            }
                            double rating = 0.0;
                            Matcher rm =
                                    Pattern.compile(
                                                    "data-rating=\"([0-9.]+)\"|<span[^>]*>([2-9]\\.[0-9]|10\\.0)(?:分)?</span>")
                                            .matcher(body);
                            if (rm.find()) {
                                String rStr = rm.group(1) != null ? rm.group(1) : rm.group(2);
                                try {
                                    double rawR = Double.parseDouble(rStr);
                                    if (rawR > 10.0) rawR = rawR / 10.0;
                                    if (rawR >= 2.0 && rawR <= 9.9) rating = rawR;
                                } catch (Exception ignored) {
                                }
                            }
                            int score =
                                    (hasDefaultImg ? 0 : 40)
                                            + (unreleased ? 0 : 30)
                                            + (rating >= 2.0 ? 35 : 0);
                            boolean updatedExisting = false;
                            for (int k = 0; k < results.size(); k++) {
                                DoubanCandidate ex = results.get(k);
                                if (ex.id.equals(sid)) {
                                    if (rating >= 2.0 && ex.rating < 2.0) {
                                        results.set(
                                                k,
                                                new DoubanCandidate(
                                                        ex.id,
                                                        ex.imgUrl.isEmpty() ? imgUrl : ex.imgUrl,
                                                        rating,
                                                        Math.max(ex.score, score),
                                                        ex.isTv,
                                                        ex.subTitle));
                                    }
                                    updatedExisting = true;
                                    break;
                                }
                            }
                            if (!updatedExisting) {
                                results.add(
                                        new DoubanCandidate(sid, imgUrl, rating, score, false, ""));
                            }
                        }
                    }
                    boolean hasRated = false;
                    for (DoubanCandidate c : results) {
                        if (c.rating >= 2.0) {
                            hasRated = true;
                            break;
                        }
                    }
                    if (hasRated) break;
                } catch (Exception ignored) {
                }
            }
        }

        java.util.Collections.sort(results, (a, b) -> Integer.compare(b.score, a.score));
        for (DoubanCandidate c : results) {
            if (c.rating >= 2.0 && c.rating <= 9.9) {
                DOUBAN_RATING_CACHE.put(normTarget + "#" + cleanYear, c.rating);
                DOUBAN_RATING_CACHE.put(normTarget + "#", c.rating);
                break;
            }
        }
        return results;
    }

    private static void collectVerifiedDoubanPosters(
            String title, String year, String actor, String director, Set<String> out) {
        try {
            String normTarget = normalizeForStrictCompare(title);
            if (normTarget.isEmpty()) return;
            java.util.List<DoubanCandidate> cands = findVerifiedDoubanSubjects(title, year);
            if (cands.isEmpty()) return;

            for (int i = 0; i < Math.min(2, cands.size()); i++) {
                DoubanCandidate cand = cands.get(i);
                if (!cand.imgUrl.isEmpty()) {
                    out.add(ImageLoader.upgradePosterUrl(cand.imgUrl, true));
                }
                String[] kinds =
                        cand.isTv ? new String[] {"tv", "movie"} : new String[] {"movie", "tv"};
                for (String kind : kinds) {
                    String rexxarJson = fetchDoubanRexxarJson(kind, cand.id, 3200);
                    if (rexxarJson != null && rexxarJson.trim().startsWith("{")) {
                        JSONObject obj = new JSONObject(rexxarJson);
                        JSONObject ratingObj = obj.optJSONObject("rating");
                        if (ratingObj != null) {
                            double rv = ratingObj.optDouble("value", 0.0);
                            if (rv >= 2.0 && rv <= 9.9) {
                                DOUBAN_RATING_CACHE.put(
                                        normTarget + "#" + extractFourDigitYear(year), rv);
                                DOUBAN_RATING_CACHE.put(normTarget + "#", rv);
                            }
                        }
                        String intro = obj.optString("intro", "");
                        int introRt = extractRtPercentFromText(intro);
                        if (introRt > 0) {
                            RT_RATING_CACHE.put(
                                    normTarget + "#" + extractFourDigitYear(year), introRt);
                            RT_RATING_CACHE.put(normTarget + "#", introRt);
                        }
                        JSONObject pic = obj.optJSONObject("pic");
                        if (pic != null) {
                            String large = pic.optString("large", "").trim();
                            if (!large.isEmpty()) {
                                out.add(ImageLoader.upgradePosterUrl(large, true));
                            }
                            String normal = pic.optString("normal", "").trim();
                            if (!normal.isEmpty()) {
                                out.add(ImageLoader.upgradePosterUrl(normal, true));
                            }
                        }
                        break;
                    }
                }
                if (!out.isEmpty()) break;
            }
        } catch (Exception ignored) {
        }
    }

    private static int fetchVerifiedRtPercent(
            String cleanTitle, String englishTitle, int targetYear) {
        String normTarget = normalizeForStrictCompare(cleanTitle);
        String cleanYear = targetYear > 0 ? String.valueOf(targetYear) : "";
        Integer cached = RT_RATING_CACHE.get(normTarget + "#" + cleanYear);
        if (cached == null) cached = RT_RATING_CACHE.get(normTarget + "#");
        if (cached != null && cached > 0) return cached;

        String altTitle = extractSequelPrefixBeforeSubtitle(cleanTitle);
        String primary = !altTitle.isEmpty() ? altTitle : cleanTitle;
        String yearHint = targetYear > 0 ? (targetYear + " ") : "";

        // 1. Chinese Bing search snippet ("<title>" [year] 烂番茄 新鲜度)
        try {
            String q = URLEncoder.encode("\"" + primary + "\" " + yearHint + "烂番茄 新鲜度", "UTF-8");
            String html =
                    httpGetText(
                            "https://cn.bing.com/search?q=" + q,
                            "https://cn.bing.com/",
                            false,
                            2800);
            int pct = extractRtPercentFromBingHtml(html, cleanTitle, englishTitle, targetYear);
            if (pct > 0) {
                RT_RATING_CACHE.put(normTarget + "#" + cleanYear, pct);
                RT_RATING_CACHE.put(normTarget + "#", pct);
                return pct;
            }
        } catch (Exception ignored) {
        }

        // 2. If verified original English title is available (e.g. from Douban sub_title), query RT
        // snippet
        if (englishTitle != null && englishTitle.trim().length() >= 3) {
            String en = englishTitle.trim();
            if (!en.equalsIgnoreCase(primary)) {
                try {
                    String qEn =
                            URLEncoder.encode(
                                    "\"" + en + "\" " + yearHint + "\"Rotten Tomatoes\"", "UTF-8");
                    String htmlEn =
                            httpGetText(
                                    "https://cn.bing.com/search?q=" + qEn,
                                    "https://cn.bing.com/",
                                    false,
                                    2800);
                    int pctEn = extractRtPercentFromBingHtml(htmlEn, cleanTitle, en, targetYear);
                    if (pctEn > 0) {
                        RT_RATING_CACHE.put(normTarget + "#" + cleanYear, pctEn);
                        RT_RATING_CACHE.put(normTarget + "#", pctEn);
                        return pctEn;
                    }
                } catch (Exception ignored) {
                }
            }
        }

        // 3. Baidu Baike summary check (often records Rotten Tomatoes Tomatometer for major
        // releases)
        try {
            String baikeUrl = "https://baike.baidu.com/item/" + URLEncoder.encode(primary, "UTF-8");
            String baikeHtml = httpGetText(baikeUrl, "https://baike.baidu.com/", false, 2600);
            if (baikeHtml != null && !baikeHtml.isEmpty()) {
                Matcher metaDesc =
                        Pattern.compile(
                                        "<meta\\s+name=\"description\"\\s+content=\"([^\"]+)\"",
                                        Pattern.CASE_INSENSITIVE)
                                .matcher(baikeHtml);
                if (metaDesc.find()) {
                    String desc = stripHtmlSnippet(metaDesc.group(1));
                    if (snippetMatchesTitleAndYear(desc, cleanTitle, englishTitle, targetYear)) {
                        int pctBk = extractRtPercentFromText(desc);
                        if (pctBk > 0) {
                            RT_RATING_CACHE.put(normTarget + "#" + cleanYear, pctBk);
                            RT_RATING_CACHE.put(normTarget + "#", pctBk);
                            return pctBk;
                        }
                    }
                }
            }
        } catch (Exception ignored) {
        }
        return -1;
    }

    static Ratings extractImmediateRatings(Cms.Video v) {
        if (v == null) return new Ratings(0.0, -1, 0L);
        double db = Cms.parseValidDoubanScore(v.doubanScore);
        String blob =
                (v.remarks == null ? "" : v.remarks)
                        + " "
                        + (v.description == null ? "" : v.description);
        if (db < 2.0) {
            db = extractDoubanScoreFromText(blob);
        }
        int rt = extractRtPercentFromText(blob);
        String cleanTitle = normalizeTitleForBackdrop(v.title);
        String normTarget = normalizeForStrictCompare(cleanTitle);
        String cleanYear = extractFourDigitYear(v.year);
        if (!normTarget.isEmpty()) {
            if (db < 2.0) {
                Double cDb = DOUBAN_RATING_CACHE.get(normTarget + "#" + cleanYear);
                if (cDb == null) cDb = DOUBAN_RATING_CACHE.get(normTarget + "#");
                if (cDb != null && cDb >= 2.0) db = cDb;
            }
            if (rt <= 0) {
                Integer cRt = RT_RATING_CACHE.get(normTarget + "#" + cleanYear);
                if (cRt == null) cRt = RT_RATING_CACHE.get(normTarget + "#");
                if (cRt != null && cRt > 0) rt = cRt;
            }
        }
        return new Ratings(db, rt, 0L);
    }

    static void resolveMediaRatings(
            final MainActivity a, final Cms.Video v, final MainActivity.Done<Ratings> onResolved) {
        if (a == null || v == null || onResolved == null) return;
        final Ratings immediate = extractImmediateRatings(v);
        if (immediate.douban >= 2.0 || immediate.rtPercent > 0) {
            try {
                onResolved.accept(immediate);
            } catch (Exception ignored) {
            }
        }
        if (immediate.douban >= 2.0 && immediate.rtPercent > 0) {
            return;
        }
        final String cleanTitle = normalizeTitleForBackdrop(v.title);
        final String normTarget = normalizeForStrictCompare(cleanTitle);
        if (normTarget.isEmpty()) return;
        final String cleanYear = extractFourDigitYear(v.year);
        final int targetYear = parseYearInt(cleanYear);
        final boolean likelyTvSeries =
                v.lines != null
                        && !v.lines.isEmpty()
                        && v.lines.get(0) != null
                        && v.lines.get(0).episodes != null
                        && v.lines.get(0).episodes.size() > 1;
        final String cacheKey = normTarget + "#" + cleanYear;
        Ratings cached = MEDIA_RATINGS_CACHE.get(cacheKey);
        long now = System.currentTimeMillis();
        if (cached != null && (now - cached.fetchedAtMs) < 10 * 60 * 1000L) {
            double mergedDb = immediate.douban >= 2.0 ? immediate.douban : cached.douban;
            int mergedRt = immediate.rtPercent > 0 ? immediate.rtPercent : cached.rtPercent;
            if (mergedDb >= 2.0 || mergedRt > 0) {
                try {
                    onResolved.accept(new Ratings(mergedDb, mergedRt, cached.fetchedAtMs));
                } catch (Exception ignored) {
                }
            }
            return;
        }

        final int generation = a.generation;
        final MainActivity.Done<Ratings> uiCallback =
                resolved -> {
                    a.ui.post(
                            () -> {
                                if (generation == a.generation && !a.isFinishing()) {
                                    try {
                                        onResolved.accept(resolved);
                                    } catch (Exception ignored) {
                                    }
                                }
                            });
                };

        java.util.concurrent.CopyOnWriteArrayList<MainActivity.Done<Ratings>> listeners =
                new java.util.concurrent.CopyOnWriteArrayList<>();
        listeners.add(uiCallback);
        java.util.concurrent.CopyOnWriteArrayList<MainActivity.Done<Ratings>> existing =
                INFLIGHT_RATINGS.putIfAbsent(cacheKey, listeners);
        if (existing != null) {
            existing.add(uiCallback);
            return;
        }

        RATING_POOL.execute(
                () -> {
                    double db = immediate.douban;
                    int rt = immediate.rtPercent;
                    String englishTitle = "";
                    try {
                        java.util.List<DoubanCandidate> cands =
                                findVerifiedDoubanSubjects(cleanTitle, cleanYear);
                        for (DoubanCandidate c : cands) {
                            if (englishTitle.isEmpty() && !c.subTitle.isEmpty()) {
                                englishTitle = c.subTitle;
                            }
                            if (db < 2.0 && c.rating >= 2.0) {
                                db = c.rating;
                            }
                        }
                        if (db < 2.0 && !cands.isEmpty()) {
                            for (int i = 0; i < Math.min(2, cands.size()) && db < 2.0; i++) {
                                DoubanCandidate cand = cands.get(i);
                                String[] kinds =
                                        (cand.isTv || likelyTvSeries)
                                                ? new String[] {"tv", "movie"}
                                                : new String[] {"movie", "tv"};
                                for (String kind : kinds) {
                                    String rexxarJson = fetchDoubanRexxarJson(kind, cand.id, 3200);
                                    if (rexxarJson != null && rexxarJson.trim().startsWith("{")) {
                                        JSONObject obj = new JSONObject(rexxarJson);
                                        JSONObject ratingObj = obj.optJSONObject("rating");
                                        if (ratingObj != null) {
                                            double rv = ratingObj.optDouble("value", 0.0);
                                            if (rv >= 2.0 && rv <= 9.9) {
                                                db = rv;
                                                DOUBAN_RATING_CACHE.put(cacheKey, rv);
                                                DOUBAN_RATING_CACHE.put(normTarget + "#", rv);
                                            }
                                        }
                                        if (rt <= 0) {
                                            int introRt =
                                                    extractRtPercentFromText(
                                                            obj.optString("intro", ""));
                                            if (introRt > 0) {
                                                rt = introRt;
                                                RT_RATING_CACHE.put(cacheKey, introRt);
                                                RT_RATING_CACHE.put(normTarget + "#", introRt);
                                            }
                                        }
                                        if (englishTitle.isEmpty()) {
                                            JSONArray aka = obj.optJSONArray("aka");
                                            if (aka != null) {
                                                for (int k = 0; k < aka.length(); k++) {
                                                    String ak = aka.optString(k, "").trim();
                                                    if (ak.matches(".*[A-Za-z]{3,}.*")) {
                                                        englishTitle = ak;
                                                        break;
                                                    }
                                                }
                                            }
                                        }
                                        break;
                                    }
                                }
                            }
                        }
                        if (db < 2.0) {
                            String yearHint = targetYear > 0 ? (targetYear + " ") : "";
                            String bq =
                                    URLEncoder.encode(
                                            "\"" + cleanTitle + "\" " + yearHint + "豆瓣评分", "UTF-8");
                            String bHtml =
                                    httpGetText(
                                            "https://cn.bing.com/search?q=" + bq,
                                            "https://cn.bing.com/",
                                            false,
                                            2600);
                            double bDb =
                                    extractDoubanScoreFromBingHtml(bHtml, cleanTitle, targetYear);
                            if (bDb >= 2.0) {
                                db = bDb;
                                DOUBAN_RATING_CACHE.put(cacheKey, bDb);
                                DOUBAN_RATING_CACHE.put(normTarget + "#", bDb);
                            }
                        }
                        // Deliver Douban score immediately while RT continues if needed
                        if (db >= 2.0 && rt <= 0) {
                            Ratings partial = new Ratings(db, -1, System.currentTimeMillis());
                            java.util.List<MainActivity.Done<Ratings>> cur =
                                    INFLIGHT_RATINGS.get(cacheKey);
                            if (cur != null) {
                                for (MainActivity.Done<Ratings> cb : cur) {
                                    try {
                                        cb.accept(partial);
                                    } catch (Exception ignored) {
                                    }
                                }
                            }
                        }
                        if (rt <= 0) {
                            rt = fetchVerifiedRtPercent(cleanTitle, englishTitle, targetYear);
                        }
                    } catch (Exception ignored) {
                    } finally {
                        Ratings done = new Ratings(db, rt, System.currentTimeMillis());
                        MEDIA_RATINGS_CACHE.put(cacheKey, done);
                        java.util.List<MainActivity.Done<Ratings>> waiters =
                                INFLIGHT_RATINGS.remove(cacheKey);
                        if (waiters != null && (db >= 2.0 || rt > 0)) {
                            for (MainActivity.Done<Ratings> cb : waiters) {
                                try {
                                    cb.accept(done);
                                } catch (Exception ignored) {
                                }
                            }
                        }
                    }
                });
    }

    static SubjectDetails parseDoubanSubjectJson(String subjectJson, String creditsJson) {
        String year = "";
        String countries = "";
        int episodesCount = 0;
        int seasonsCount = 0;
        String duration = "";
        String genres = "";
        String intro = "";
        String posterUrl = "";
        double doubanScore = 0.0;
        int rtPercent = -1;
        java.util.List<CastMember> cast = new java.util.ArrayList<>();
        java.util.Set<String> seenNames = new java.util.LinkedHashSet<>();

        if (subjectJson != null && subjectJson.trim().startsWith("{")) {
            try {
                JSONObject obj = new JSONObject(subjectJson);
                year = extractFourDigitYear(obj.optString("year", ""));
                countries = joinJsonStringArray(obj.optJSONArray("countries"), " / ", 2);
                episodesCount = Math.max(0, obj.optInt("episodes_count", 0));
                seasonsCount = Math.max(0, obj.optInt("seasons_count", 0));
                if (seasonsCount <= 0) {
                    seasonsCount = Math.max(0, obj.optInt("season_count", 0));
                }
                if (seasonsCount <= 1) {
                    JSONArray seasonsArr = obj.optJSONArray("seasons");
                    if (seasonsArr != null && seasonsArr.length() > seasonsCount) {
                        seasonsCount = seasonsArr.length();
                    }
                }
                if (seasonsCount <= 1) {
                    JSONArray relSeasons = obj.optJSONArray("related_seasons");
                    if (relSeasons != null && relSeasons.length() > seasonsCount) {
                        seasonsCount = relSeasons.length();
                    }
                }
                duration = joinJsonStringArray(obj.optJSONArray("durations"), " / ", 1);
                genres = joinJsonStringArray(obj.optJSONArray("genres"), " / ", 3);
                intro = obj.optString("intro", "").trim();
                JSONObject pic = obj.optJSONObject("pic");
                if (pic != null) {
                    String large = pic.optString("large", "").trim();
                    String normal = pic.optString("normal", "").trim();
                    posterUrl = normalizeCoverUrl(!large.isEmpty() ? large : normal);
                }
                JSONObject ratingObj = obj.optJSONObject("rating");
                if (ratingObj != null) {
                    double rv = ratingObj.optDouble("value", 0.0);
                    if (rv >= 2.0 && rv <= 9.9) doubanScore = rv;
                }
                rtPercent = extractRtPercentFromText(intro);
                appendDoubanPeopleArray(obj.optJSONArray("directors"), true, cast, seenNames);
                appendDoubanPeopleArray(obj.optJSONArray("actors"), false, cast, seenNames);
            } catch (Exception ignored) {
            }
        }

        if (creditsJson != null && creditsJson.trim().startsWith("{")) {
            try {
                JSONObject cr = new JSONObject(creditsJson);
                java.util.List<CastMember> richer = new java.util.ArrayList<>();
                java.util.Set<String> richerSeen = new java.util.LinkedHashSet<>();
                JSONArray items = cr.optJSONArray("items");
                if (items != null) {
                    for (int i = 0; i < items.length() && richer.size() < 16; i++) {
                        JSONObject item = items.optJSONObject(i);
                        if (item == null) continue;
                        String category = item.optString("category", "").trim();
                        boolean isDir =
                                category.contains("导演") || "director".equalsIgnoreCase(category);
                        boolean isActor =
                                category.contains("演员")
                                        || category.contains("主演")
                                        || category.contains("配音")
                                        || "actor".equalsIgnoreCase(category);
                        if (!isDir && !isActor && !category.isEmpty()) continue;
                        CastMember member = parseDoubanPersonObject(item, isDir);
                        if (member != null
                                && !member.name.isEmpty()
                                && richerSeen.add(member.name)) {
                            richer.add(member);
                        }
                    }
                }
                // Also support real Douban Rexxar /credits grouped schema:
                // {"credits": [{"title": "导演", "celebrities": [...]}, {"title": "演员",
                // "celebrities": [...]}]}
                JSONArray creditGroups = cr.optJSONArray("credits");
                if (creditGroups != null) {
                    for (int g = 0; g < creditGroups.length() && richer.size() < 16; g++) {
                        JSONObject group = creditGroups.optJSONObject(g);
                        if (group == null) continue;
                        String gTitle = group.optString("title", "").trim();
                        boolean isDir =
                                gTitle.contains("导演") || "director".equalsIgnoreCase(gTitle);
                        boolean isActor =
                                gTitle.contains("演员")
                                        || gTitle.contains("主演")
                                        || gTitle.contains("配音")
                                        || gTitle.contains("Cast")
                                        || "actor".equalsIgnoreCase(gTitle);
                        if (!isDir && !isActor && !gTitle.isEmpty()) continue;
                        JSONArray celebs = group.optJSONArray("celebrities");
                        if (celebs == null) celebs = group.optJSONArray("items");
                        appendDoubanPeopleArray(celebs, isDir, richer, richerSeen);
                    }
                }
                appendDoubanPeopleArray(cr.optJSONArray("directors"), true, richer, richerSeen);
                appendDoubanPeopleArray(cr.optJSONArray("actors"), false, richer, richerSeen);
                if (!richer.isEmpty()) {
                    cast = richer;
                }
            } catch (Exception ignored) {
            }
        }

        return new SubjectDetails(
                year,
                countries,
                episodesCount,
                seasonsCount,
                duration,
                genres,
                intro,
                posterUrl,
                doubanScore,
                rtPercent,
                cast,
                System.currentTimeMillis());
    }

    private static String joinJsonStringArray(JSONArray arr, String sep, int maxItems) {
        if (arr == null || arr.length() == 0) return "";
        StringBuilder sb = new StringBuilder();
        java.util.Set<String> seen = new java.util.LinkedHashSet<>();
        int count = 0;
        for (int i = 0; i < arr.length() && count < maxItems; i++) {
            String s = arr.optString(i, "").trim();
            if (s.isEmpty() || !seen.add(normalizeFactTokenKey(s))) continue;
            if (sb.length() > 0) sb.append(sep);
            sb.append(s);
            count++;
        }
        return sb.toString();
    }

    static String normalizeFactTokenKey(String raw) {
        if (raw == null) return "";
        String s = raw.trim().toLowerCase(java.util.Locale.ROOT);
        if (s.equals("大陆") || s.equals("内地") || s.equals("国产") || s.equals("中国内地")) {
            return "中国大陆";
        }
        if (s.equals("香港")) return "中国香港";
        if (s.equals("台湾")) return "中国台湾";
        return s;
    }

    private static void appendDoubanPeopleArray(
            JSONArray arr,
            boolean isDirector,
            java.util.List<CastMember> out,
            java.util.Set<String> seen) {
        if (arr == null) return;
        for (int i = 0; i < arr.length() && out.size() < 16; i++) {
            JSONObject p = arr.optJSONObject(i);
            if (p == null) continue;
            CastMember m = parseDoubanPersonObject(p, isDirector);
            if (m != null && !m.name.isEmpty() && seen.add(m.name)) {
                out.add(m);
            }
        }
    }

    private static CastMember parseDoubanPersonObject(JSONObject p, boolean isDirector) {
        String name = p.optString("name", "").trim();
        if (name.isEmpty()) return null;
        String role = p.optString("character", "").trim();
        if (role.isEmpty()) {
            JSONArray roles = p.optJSONArray("roles");
            if (roles != null && roles.length() > 0) {
                role = roles.optString(0, "").trim();
            }
        }
        if (role.startsWith("饰 ") || role.startsWith("饰:")) {
            role = role.substring(2).trim();
        }
        if (role.isEmpty()) {
            role = isDirector ? "导演" : "演员";
        }
        String avatarUrl = "";
        JSONObject avatar = p.optJSONObject("avatar");
        if (avatar != null) {
            avatarUrl = avatar.optString("normal", "").trim();
            if (avatarUrl.isEmpty()) avatarUrl = avatar.optString("large", "").trim();
        }
        if (avatarUrl.isEmpty()) {
            avatarUrl = p.optString("cover_url", "").trim();
        }
        if (avatarUrl.contains("celebrity-default") || avatarUrl.contains("personage-default")) {
            avatarUrl = "";
        }
        avatarUrl = normalizeCoverUrl(avatarUrl);
        return new CastMember(name, role, avatarUrl, isDirector);
    }

    static java.util.List<CastMember> parseCastNamesFallback(String director, String actor) {
        java.util.List<CastMember> out = new java.util.ArrayList<>();
        java.util.Set<String> seen = new java.util.LinkedHashSet<>();
        addSplitCast(director, "导演", true, out, seen, 3);
        addSplitCast(actor, "主演", false, out, seen, 12);
        return out;
    }

    private static void addSplitCast(
            String raw,
            String role,
            boolean isDirector,
            java.util.List<CastMember> out,
            java.util.Set<String> seen,
            int maxAdd) {
        if (raw == null || raw.trim().isEmpty()) return;
        String[] parts = raw.split("[,，、/|;；]+");
        int added = 0;
        for (String part : parts) {
            String name = part.trim();
            if (name.isEmpty() || "未知".equals(name) || "暂无".equals(name) || "内详".equals(name)) {
                continue;
            }
            if (seen.add(name)) {
                out.add(new CastMember(name, role, "", isDirector));
                if (++added >= maxAdd) break;
            }
        }
    }

    private static boolean isRedundantRegionCategoryLabel(String token) {
        return "国产剧".equals(token)
                || "大陆剧".equals(token)
                || "内地剧".equals(token)
                || "港剧".equals(token)
                || "港台剧".equals(token)
                || "台剧".equals(token)
                || "美剧".equals(token)
                || "欧美剧".equals(token)
                || "韩剧".equals(token)
                || "日韩剧".equals(token)
                || "日剧".equals(token)
                || "英剧".equals(token)
                || "泰剧".equals(token);
    }

    static java.util.List<String> buildOfficialFactBadges(
            Cms.Video v, SubjectDetails official, int detectedSeasons) {
        java.util.List<String> parts = new java.util.ArrayList<>();
        java.util.Set<String> seenTokens = new java.util.LinkedHashSet<>();
        String year =
                official != null && !official.year.isEmpty()
                        ? official.year
                        : (v == null ? "" : extractFourDigitYear(v.year));
        if (!year.isEmpty() && seenTokens.add(normalizeFactTokenKey(year))) {
            parts.add(year);
        }

        String rawRegion =
                official != null && !official.countries.isEmpty()
                        ? official.countries
                        : (v == null || v.area == null ? "" : v.area.trim());
        if (!rawRegion.isEmpty()) {
            String[] rParts = rawRegion.split("[/,，、;；\\s]+");
            StringBuilder rBuf = new StringBuilder();
            int rAdded = 0;
            for (String r : rParts) {
                String clean = r.trim();
                if (clean.isEmpty()) continue;
                if (!seenTokens.add(normalizeFactTokenKey(clean))) continue;
                if (rBuf.length() > 0) rBuf.append(" / ");
                rBuf.append(clean);
                if (++rAdded >= 2) break;
            }
            if (rBuf.length() > 0) parts.add(rBuf.toString());
        }

        int seasons =
                Math.max(
                        official != null ? official.seasonsCount : 0, Math.max(0, detectedSeasons));
        if (seasons > 1) {
            parts.add("共 " + seasons + " 季");
        }

        String episodeOrDuration = "";
        if (official != null && official.episodesCount > 0) {
            episodeOrDuration = "全 " + official.episodesCount + " 集";
        } else if (v != null && v.lines != null && !v.lines.isEmpty()) {
            int maxEp = 0;
            for (Cms.Line line : v.lines) {
                if (line != null && line.episodes != null && line.episodes.size() > maxEp) {
                    maxEp = line.episodes.size();
                }
            }
            if (maxEp > 1) {
                episodeOrDuration = "共 " + maxEp + " 集";
            } else if (official != null && !official.duration.isEmpty()) {
                episodeOrDuration = official.duration;
            } else if (v.remarks != null && !v.remarks.trim().isEmpty()) {
                episodeOrDuration = v.remarks.trim();
            }
        } else if (official != null && !official.duration.isEmpty()) {
            episodeOrDuration = official.duration;
        } else if (v != null && v.remarks != null && !v.remarks.trim().isEmpty()) {
            episodeOrDuration = v.remarks.trim();
        }
        if (!episodeOrDuration.isEmpty()
                && seenTokens.add(normalizeFactTokenKey(episodeOrDuration))) {
            parts.add(episodeOrDuration);
        }

        String genreText =
                official != null && !official.genres.isEmpty()
                        ? official.genres
                        : (v != null && v.genre != null && !v.genre.trim().isEmpty()
                                ? v.genre.trim()
                                : (v == null || v.tag == null ? "" : v.tag.trim()));
        boolean hasRegionBadge = !rawRegion.isEmpty();
        if (!genreText.isEmpty()) {
            String[] gParts = genreText.split("[/,，、;；\\s]+");
            StringBuilder gBuf = new StringBuilder();
            int gAdded = 0;
            for (String g : gParts) {
                String clean = g.trim();
                if (clean.isEmpty()) continue;
                if (hasRegionBadge && isRedundantRegionCategoryLabel(clean)) continue;
                String normKey = normalizeFactTokenKey(clean);
                if (!seenTokens.add(normKey)) continue;
                if (gBuf.length() > 0) gBuf.append(" / ");
                gBuf.append(clean);
                if (++gAdded >= 2) break;
            }
            if (gBuf.length() > 0) parts.add(gBuf.toString());
        }
        return parts;
    }

    static String formatOfficialFactLine(Cms.Video v, SubjectDetails official) {
        java.util.List<String> parts = buildOfficialFactBadges(v, official, 0);
        StringBuilder joined = new StringBuilder();
        for (int i = 0; i < parts.size(); i++) {
            if (i > 0) joined.append("  ·  ");
            joined.append(parts.get(i));
        }
        return joined.toString();
    }

    static void resolveSubjectDetails(
            final MainActivity a,
            final Cms.Video v,
            final MainActivity.Done<SubjectDetails> onResolved) {
        if (a == null || v == null || onResolved == null) return;
        if (v.poster != null && v.poster.contains("fixture.test")) return;
        final String cleanTitle = normalizeTitleForBackdrop(v.title);
        final String normTarget = normalizeForStrictCompare(cleanTitle);
        if (normTarget.isEmpty() || "选集响应样本".equals(cleanTitle) || "独立调度".equals(cleanTitle)) {
            return;
        }
        final String cleanYear = extractFourDigitYear(v.year);
        final boolean likelyTvSeries =
                v.lines != null
                        && !v.lines.isEmpty()
                        && v.lines.get(0) != null
                        && v.lines.get(0).episodes != null
                        && v.lines.get(0).episodes.size() > 1;
        final String cacheKey = normTarget + "#" + cleanYear + "#" + (likelyTvSeries ? "tv" : "mv");
        SubjectDetails cached = SUBJECT_DETAILS_CACHE.get(cacheKey);
        if (cached != null && (System.currentTimeMillis() - cached.fetchedAtMs) < 10 * 60 * 1000L) {
            try {
                onResolved.accept(cached);
            } catch (Exception ignored) {
            }
            return;
        }

        final int generation = a.generation;
        final MainActivity.Done<SubjectDetails> uiCallback =
                details ->
                        a.ui.post(
                                () -> {
                                    if (generation == a.generation && !a.isFinishing()) {
                                        try {
                                            onResolved.accept(details);
                                        } catch (Exception ignored) {
                                        }
                                    }
                                });

        java.util.concurrent.CopyOnWriteArrayList<MainActivity.Done<SubjectDetails>> listeners =
                new java.util.concurrent.CopyOnWriteArrayList<>();
        listeners.add(uiCallback);
        java.util.concurrent.CopyOnWriteArrayList<MainActivity.Done<SubjectDetails>> existing =
                INFLIGHT_SUBJECT_DETAILS.putIfAbsent(cacheKey, listeners);
        if (existing != null) {
            existing.add(uiCallback);
            return;
        }

        RATING_POOL.execute(
                () -> {
                    SubjectDetails resolved = null;
                    try {
                        java.util.List<DoubanCandidate> cands =
                                findVerifiedDoubanSubjects(cleanTitle, cleanYear);
                        for (int i = 0; i < Math.min(2, cands.size()) && resolved == null; i++) {
                            DoubanCandidate cand = cands.get(i);
                            String[] kinds =
                                    (cand.isTv || likelyTvSeries)
                                            ? new String[] {"tv", "movie"}
                                            : new String[] {"movie", "tv"};
                            for (String kind : kinds) {
                                String subjectJson = fetchDoubanRexxarJson(kind, cand.id, 3400);
                                if (subjectJson == null || !subjectJson.trim().startsWith("{")) {
                                    continue;
                                }
                                String base =
                                        "https://m.douban.com/rexxar/api/v2/"
                                                + kind
                                                + "/"
                                                + cand.id;
                                String referer =
                                        "https://m.douban.com/movie/subject/" + cand.id + "/";
                                String creditsJson =
                                        httpGetText(base + "/credits", referer, true, 3400);
                                SubjectDetails parsed =
                                        parseDoubanSubjectJson(subjectJson, creditsJson);
                                if (!parsed.year.isEmpty()
                                        || !parsed.countries.isEmpty()
                                        || parsed.episodesCount > 0
                                        || !parsed.cast.isEmpty()
                                        || !parsed.intro.isEmpty()
                                        || !parsed.posterUrl.isEmpty()) {
                                    resolved = parsed;
                                    if (parsed.doubanScore >= 2.0) {
                                        DOUBAN_RATING_CACHE.put(
                                                normTarget + "#" + cleanYear, parsed.doubanScore);
                                        DOUBAN_RATING_CACHE.put(
                                                normTarget + "#", parsed.doubanScore);
                                    }
                                    if (parsed.rtPercent > 0) {
                                        RT_RATING_CACHE.put(
                                                normTarget + "#" + cleanYear, parsed.rtPercent);
                                        RT_RATING_CACHE.put(normTarget + "#", parsed.rtPercent);
                                    }
                                    break;
                                }
                            }
                        }
                    } catch (Exception ignored) {
                    } finally {
                        if (resolved != null) {
                            SUBJECT_DETAILS_CACHE.put(cacheKey, resolved);
                        }
                        java.util.List<MainActivity.Done<SubjectDetails>> waiters =
                                INFLIGHT_SUBJECT_DETAILS.remove(cacheKey);
                        if (waiters != null && resolved != null) {
                            for (MainActivity.Done<SubjectDetails> cb : waiters) {
                                try {
                                    cb.accept(resolved);
                                } catch (Exception ignored) {
                                }
                            }
                        }
                    }
                });
    }

    private static void collectVerifiedBilibiliVerticalCovers(
            String title, String year, Set<String> out) {
        String normTarget = normalizeForStrictCompare(title);
        if (normTarget.isEmpty()) return;
        String normAlt = normalizeForStrictCompare(extractSequelPrefixBeforeSubtitle(title));
        int targetYear = parseYearInt(year);

        String[] types = {"media_bangumi", "media_ft"};
        for (String type : types) {
            try {
                String url =
                        "https://api.bilibili.com/x/web-interface/search/type?search_type="
                                + type
                                + "&keyword="
                                + URLEncoder.encode(title, "UTF-8");
                String json = httpGetText(url, "https://www.bilibili.com/", false, 3800);
                if (json == null || json.isEmpty()) continue;
                JSONObject root = new JSONObject(json);
                JSONObject data = root.optJSONObject("data");
                if (data == null) continue;
                JSONArray results = data.optJSONArray("result");
                if (results == null || results.length() == 0) continue;

                for (int i = 0; i < Math.min(4, results.length()); i++) {
                    JSONObject item = results.optJSONObject(i);
                    if (item == null) continue;
                    String rawItemTitle = item.optString("title");
                    String itemTitle = normalizeForStrictCompare(rawItemTitle);
                    String itemTitleAlt =
                            normalizeForStrictCompare(
                                    extractSequelPrefixBeforeSubtitle(rawItemTitle));
                    if (!normTarget.equals(itemTitle)
                            && !normAlt.equals(itemTitle)
                            && !normTarget.equals(itemTitleAlt)) {
                        continue;
                    }

                    if (targetYear > 0) {
                        long pubtime = item.optLong("pubtime", 0L);
                        if (pubtime > 0) {
                            Calendar cal = Calendar.getInstance();
                            cal.setTimeInMillis(pubtime * 1000L);
                            int pubYear = cal.get(Calendar.YEAR);
                            if (Math.abs(pubYear - targetYear) > 1) continue;
                        }
                    }

                    String vCover = normalizeCoverUrl(item.optString("cover"));
                    if (!vCover.isEmpty()) {
                        out.add(vCover);
                        return;
                    }
                }
            } catch (Exception ignored) {
            }
        }
    }

    private static final String[] REJECTED_PHOTO_KEYWORDS = {
        "花絮",
        "发布会",
        "开机",
        "杀青",
        "路透",
        "首映",
        "宣传",
        "访谈",
        "采访",
        "幕后",
        "片场",
        "工作照",
        "现场",
        "截图",
        "字幕",
        "合影",
        "签名",
        "红毯",
        "颁奖",
        "活动",
        "粉丝",
        "杂志",
        "写真",
        "动图",
        "表情包",
        "gif",
        "meme",
        "behind the scenes",
        "premiere",
        "press",
        "interview",
        "event",
        "backstage"
    };

    private static final String[] OFFICIAL_POSTER_KEYWORDS = {
        "海报",
        "壁纸",
        "横版",
        "横屏",
        "官方",
        "主视觉",
        "概念",
        "终极",
        "定档",
        "剧集海报",
        "poster",
        "wallpaper",
        "key art",
        "banner"
    };

    /**
     * Pure landscape artwork scorer: strongly prefers official HD horizontal wallpapers (W) and
     * official landscape posters (R) over stills (S), enforces 16:9-friendly aspect ratio and HD
     * resolution, and rejects behind-the-scenes/event/subtitle/portrait frames.
     */
    static int scoreLandscapePhoto(int w, int h, String desc, String photoType) {
        if (w < 800 || h < 420) return -1;
        float ar = (float) w / h;
        if (ar < 1.25f || ar > 2.45f) return -1;
        String low = desc == null ? "" : desc.trim().toLowerCase(Locale.ROOT);
        if (!low.isEmpty()) {
            for (String kw : REJECTED_PHOTO_KEYWORDS) {
                if (low.contains(kw)) return -1;
            }
        }
        int score;
        if ("W".equalsIgnoreCase(photoType)) score = 140;
        else if ("R".equalsIgnoreCase(photoType)) score = 120;
        else if ("H".equalsIgnoreCase(photoType)) score = 110;
        else score = 55;

        if (w >= 1920) score += 36;
        else if (w >= 1280) score += 24;
        else if (w >= 1000) score += 12;

        float arDiff = Math.abs(ar - 1.778f);
        if (arDiff <= 0.14f) score += 28;
        else if (arDiff <= 0.28f) score += 14;
        else if (arDiff > 0.45f) score -= 12;

        if (!low.isEmpty()) {
            for (String kw : OFFICIAL_POSTER_KEYWORDS) {
                if (low.contains(kw)) {
                    score += 20;
                    break;
                }
            }
        }
        return score;
    }

    static java.util.List<String> extractBestDoubanLandscapeUrls(
            String photosJson, String photoType) {
        java.util.List<String> result = new java.util.ArrayList<>();
        if (photosJson == null || !photosJson.trim().startsWith("{")) return result;
        try {
            JSONObject root = new JSONObject(photosJson);
            JSONArray photos = root.optJSONArray("photos");
            if (photos == null || photos.length() == 0) return result;
            java.util.List<Object[]> scored = new java.util.ArrayList<>();
            for (int i = 0; i < photos.length(); i++) {
                JSONObject p = photos.optJSONObject(i);
                if (p == null) continue;
                JSONObject img = p.optJSONObject("image");
                if (img == null) continue;
                JSONObject chosen = img.optJSONObject("raw");
                if (chosen == null || chosen.optString("url", "").trim().isEmpty()) {
                    chosen = img.optJSONObject("large");
                }
                if (chosen == null || chosen.optString("url", "").trim().isEmpty()) {
                    chosen = img.optJSONObject("normal");
                }
                if (chosen == null) continue;
                int w = chosen.optInt("width", 0);
                int h = chosen.optInt("height", 0);
                String u = chosen.optString("url", "").trim();
                if (u.isEmpty()) continue;
                if (w <= 0 || h <= 0) {
                    JSONObject large = img.optJSONObject("large");
                    if (large != null) {
                        w = large.optInt("width", w);
                        h = large.optInt("height", h);
                    }
                }
                String desc =
                        (p.optString("description", "")
                                        + " "
                                        + p.optString("title", "")
                                        + " "
                                        + p.optString("subtype", ""))
                                .trim();
                int score = scoreLandscapePhoto(w, h, desc, photoType);
                if (score > 0) {
                    scored.add(
                            new Object[] {
                                Integer.valueOf(score), ImageLoader.upgradePosterUrl(u, true)
                            });
                }
            }
            java.util.Collections.sort(
                    scored, (a, b) -> Integer.compare((Integer) b[0], (Integer) a[0]));
            for (int i = 0; i < Math.min(4, scored.size()); i++) {
                result.add((String) scored.get(i)[1]);
            }
        } catch (Exception ignored) {
        }
        return result;
    }

    private static void collectVerifiedDoubanOfficialLandscape(
            String title,
            String year,
            String actor,
            String director,
            boolean likelyTvSeries,
            Set<String> out) {
        try {
            java.util.List<DoubanCandidate> cands = findVerifiedDoubanSubjects(title, year);
            if (cands.isEmpty()) return;

            // Strict priority: type=W (official HD wallpapers) -> type=R (official landscape
            // posters)
            String[] officialTypes = {"W", "R"};
            for (int cIdx = 0; cIdx < Math.min(2, cands.size()) && out.isEmpty(); cIdx++) {
                DoubanCandidate cand = cands.get(cIdx);
                String bestId = cand.id;
                if (bestId == null || bestId.isEmpty()) continue;
                String[] kinds =
                        (cand.isTv || likelyTvSeries)
                                ? new String[] {"tv", "movie"}
                                : new String[] {"movie", "tv"};
                String referer = "https://m.douban.com/movie/subject/" + bestId + "/";
                for (String kind : kinds) {
                    for (String pType : officialTypes) {
                        String photosUrl =
                                "https://m.douban.com/rexxar/api/v2/"
                                        + kind
                                        + "/"
                                        + bestId
                                        + "/photos?type="
                                        + pType
                                        + "&count="
                                        + ("W".equals(pType) ? 12 : 16);
                        String photosJson = httpGetText(photosUrl, referer, true, 3600);
                        java.util.List<String> ranked =
                                extractBestDoubanLandscapeUrls(photosJson, pType);
                        if (!ranked.isEmpty()) {
                            out.addAll(ranked);
                            return;
                        }
                    }
                }
            }
        } catch (Exception ignored) {
        }
    }

    private static void collectVerifiedDoubanStillsFallback(
            String title, String year, boolean likelyTvSeries, Set<String> out) {
        try {
            java.util.List<DoubanCandidate> cands = findVerifiedDoubanSubjects(title, year);
            if (cands.isEmpty()) return;

            for (int cIdx = 0; cIdx < Math.min(2, cands.size()) && out.isEmpty(); cIdx++) {
                DoubanCandidate cand = cands.get(cIdx);
                String bestId = cand.id;
                if (bestId == null || bestId.isEmpty()) continue;
                String[] kinds =
                        (cand.isTv || likelyTvSeries)
                                ? new String[] {"tv", "movie"}
                                : new String[] {"movie", "tv"};
                String referer = "https://m.douban.com/movie/subject/" + bestId + "/";
                for (String kind : kinds) {
                    if (!out.isEmpty()) break;
                    String photosUrl =
                            "https://m.douban.com/rexxar/api/v2/"
                                    + kind
                                    + "/"
                                    + bestId
                                    + "/photos?type=S&count=20";
                    String photosJson = httpGetText(photosUrl, referer, true, 3600);
                    java.util.List<String> ranked = extractBestDoubanLandscapeUrls(photosJson, "S");
                    if (!ranked.isEmpty()) {
                        out.addAll(ranked);
                        return;
                    }
                }
            }
        } catch (Exception ignored) {
        }
    }

    private static void collectVerifiedBilibiliHorizontalCovers(
            String title, String year, Set<String> out) {
        String normTarget = normalizeForStrictCompare(title);
        if (normTarget.isEmpty()) return;
        int targetYear = parseYearInt(year);

        String[] types = {"media_bangumi", "media_ft"};
        for (String type : types) {
            try {
                String url =
                        "https://api.bilibili.com/x/web-interface/search/type?search_type="
                                + type
                                + "&keyword="
                                + URLEncoder.encode(title, "UTF-8");
                String json = httpGetText(url, "https://search.bilibili.com/", false, 3200);
                if (json == null || json.isEmpty()) continue;
                JSONObject root = new JSONObject(json);
                JSONObject data = root.optJSONObject("data");
                if (data == null) continue;
                JSONArray results = data.optJSONArray("result");
                if (results == null || results.length() == 0) continue;

                for (int i = 0; i < Math.min(4, results.length()); i++) {
                    JSONObject item = results.optJSONObject(i);
                    if (item == null) continue;
                    String itemTitle = normalizeForStrictCompare(item.optString("title"));
                    // Strictly require the normalized Bilibili title to equal our target title
                    if (!normTarget.equals(itemTitle)) continue;

                    if (targetYear > 0) {
                        long pubtime = item.optLong("pubtime", 0L);
                        if (pubtime > 0) {
                            Calendar cal = Calendar.getInstance();
                            cal.setTimeInMillis(pubtime * 1000L);
                            int pubYear = cal.get(Calendar.YEAR);
                            if (Math.abs(pubYear - targetYear) > 1) continue;
                        }
                    }

                    // Strictly use official horizontal_cover (never arbitrary episode frame grabs)
                    String hCover = normalizeCoverUrl(item.optString("horizontal_cover"));
                    if (!hCover.isEmpty()) {
                        out.add(hCover);
                        return;
                    }
                }
            } catch (Exception ignored) {
            }
        }
    }

    private static int parseYearInt(String y) {
        if (y == null || y.isEmpty()) return 0;
        try {
            return Integer.parseInt(y.trim());
        } catch (Exception e) {
            return 0;
        }
    }

    private static String normalizeCoverUrl(String raw) {
        if (raw == null || raw.isEmpty()) return "";
        String url = raw.trim();
        if (url.startsWith("//")) url = "https:" + url;
        else if (url.startsWith("http://")) url = "https://" + url.substring(7);
        int at = url.indexOf('@');
        if (at > 0) url = url.substring(0, at);
        return url;
    }

    private static String httpGetText(
            String urlStr, String referer, boolean mobileUa, int timeoutMs) {
        HttpURLConnection conn = null;
        try {
            conn = (HttpURLConnection) new URL(urlStr).openConnection();
            conn.setConnectTimeout(timeoutMs);
            conn.setReadTimeout(timeoutMs);
            conn.setInstanceFollowRedirects(true);
            conn.setRequestProperty(
                    "User-Agent",
                    mobileUa
                            ? "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 MicroMessenger/8.0.40"
                            : "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36");
            conn.setRequestProperty("Accept-Language", "zh-CN,zh;q=0.9,en;q=0.8");
            if (urlStr != null && urlStr.contains("bilibili.com")) {
                conn.setRequestProperty(
                        "Cookie",
                        "buvid3=00000000-0000-0000-0000-000000000000infoc; b_nut=1700000000");
            } else if (urlStr != null && urlStr.contains("douban.com")) {
                conn.setRequestProperty("Cookie", "bid=" + SESSION_DOUBAN_BID);
                conn.setRequestProperty("Accept", "application/json, text/html, */*");
            }
            if (referer != null && !referer.isEmpty()) {
                conn.setRequestProperty("Referer", referer);
            }
            try (InputStream in = conn.getInputStream();
                    ByteArrayOutputStream out = new ByteArrayOutputStream()) {
                byte[] buf = new byte[8192];
                int n;
                while ((n = in.read(buf)) != -1) {
                    if (out.size() + n > 2 * 1024 * 1024) break;
                    out.write(buf, 0, n);
                }
                return new String(out.toByteArray(), StandardCharsets.UTF_8);
            }
        } catch (Exception e) {
            return null;
        } finally {
            if (conn != null) conn.disconnect();
        }
    }

    private static byte[] downloadImageBytes(String urlStr, int timeoutMs) {
        if (urlStr == null || urlStr.trim().isEmpty()) return null;
        String currentUrl = urlStr.trim();
        if (currentUrl.startsWith("//")) currentUrl = "https:" + currentUrl;
        for (int hop = 0; hop < 4; hop++) {
            HttpURLConnection conn = null;
            try {
                conn = (HttpURLConnection) new URL(currentUrl).openConnection();
                conn.setConnectTimeout(timeoutMs);
                conn.setReadTimeout(timeoutMs);
                conn.setInstanceFollowRedirects(false);
                conn.setRequestProperty(
                        "User-Agent",
                        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36");
                ImageLoader.applyArtworkHeaders(conn, currentUrl, null);
                int code = conn.getResponseCode();
                if (code == 301 || code == 302 || code == 303 || code == 307 || code == 308) {
                    String loc = conn.getHeaderField("Location");
                    if (loc == null || loc.trim().isEmpty()) return null;
                    currentUrl = new URL(new URL(currentUrl), loc.trim()).toString();
                    continue;
                }
                if (code < 200 || code >= 300) return null;
                try (InputStream in = conn.getInputStream();
                        ByteArrayOutputStream out = new ByteArrayOutputStream()) {
                    byte[] buf = new byte[8192];
                    int n;
                    while ((n = in.read(buf)) != -1) {
                        if (out.size() + n > 8 * 1024 * 1024) return null;
                        out.write(buf, 0, n);
                    }
                    return out.toByteArray();
                }
            } catch (Exception e) {
                return null;
            } finally {
                if (conn != null) conn.disconnect();
            }
        }
        return null;
    }

    final class Art extends ImageView {
        final Paint mask = new Paint(3);

        Art() {
            super(a);
        }

        @Override
        public void setImageBitmap(Bitmap b) {
            super.setImageBitmap(b);
            soften(b);
        }

        @Override
        protected void onDraw(Canvas canvas) {
            if (immersiveMode || getDrawable() == null) return;
            if (useLightweightBackdropDraw(android.os.Build.VERSION.SDK_INT, a.reduced)) {
                super.onDraw(canvas);
                return;
            }
            int save = canvas.saveLayer(0, 0, getWidth(), getHeight(), null);
            super.onDraw(canvas);
            mask.setXfermode(new PorterDuffXfermode(PorterDuff.Mode.DST_IN));
            mask.setShader(
                    new LinearGradient(
                            0,
                            0,
                            getWidth(),
                            0,
                            new int[] {0x00ffffff, 0xffffffff, 0xffffffff, 0x00ffffff},
                            new float[] {0, .07f, .78f, 1},
                            Shader.TileMode.CLAMP));
            canvas.drawRect(0, 0, getWidth(), getHeight(), mask);
            mask.setShader(
                    new LinearGradient(
                            0,
                            0,
                            0,
                            getHeight(),
                            new int[] {0x00ffffff, 0xffffffff, 0xffffffff, 0x00ffffff},
                            new float[] {0, .06f, .86f, 1},
                            Shader.TileMode.CLAMP));
            canvas.drawRect(0, 0, getWidth(), getHeight(), mask);
            mask.setXfermode(null);
            mask.setShader(null);
            canvas.restoreToCount(save);
        }
    }

    final class Backdrop extends View {
        Bitmap bitmap;
        Bitmap rawBitmap;
        Bitmap wideBitmap;
        Bitmap wideBlurredBitmap;
        int ambientColor = 0xff090c14;
        float scrollProgress = 0f;
        boolean leftAlignedHero = false;
        final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG | Paint.FILTER_BITMAP_FLAG);
        final Paint maskPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
        final Paint veilPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
        final RectF dstRect = new RectF();
        final RectF wingRect = new RectF();

        Backdrop() {
            super(a);
            setTag("detail-backdrop");
            setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO);
            maskPaint.setXfermode(new PorterDuffXfermode(PorterDuff.Mode.DST_IN));
        }

        void setScrollOffset(int scrollY) {
            int h = getHeight();
            float collapseRange = h > 0 ? h * 0.42f : a.dp(240);
            float next = Math.max(0f, Math.min(1f, scrollY / Math.max(1f, collapseRange)));
            if (Math.abs(next - scrollProgress) > 0.004f) {
                scrollProgress = next;
                invalidate();
            }
        }

        @Override
        protected void onDraw(Canvas c) {
            int w = getWidth();
            int h = getHeight();
            if (w <= 0 || h <= 0) return;

            int bg = immersiveMode ? ambientColor : MainActivity.DARK;
            c.drawColor(bg);

            if (!immersiveMode) {
                if (bitmap == null) return;
                paint.setAlpha(135);
                c.drawBitmap(
                        bitmap, null, new RectF(-w * .05f, -h * .15f, w * 1.05f, h * 1.15f), paint);
                paint.setAlpha(255);
                return;
            }

            float winH = leftAlignedHero ? h * 0.88f : h * 0.80f;
            Bitmap horizontalHero = null;
            if (wideBitmap != null && !wideBitmap.isRecycled()) {
                horizontalHero = wideBitmap;
            } else if (rawBitmap != null
                    && !rawBitmap.isRecycled()
                    && rawBitmap.getWidth() >= rawBitmap.getHeight() * 1.15f) {
                horizontalHero = rawBitmap;
            }

            if (horizontalHero != null) {
                drawHorizontalHero(c, w, h, winH, horizontalHero, bg);
            } else if (rawBitmap != null && !rawBitmap.isRecycled()) {
                drawUnstretchedVerticalFallback(c, w, h, winH, rawBitmap, bg);
            } else if (bitmap != null && !bitmap.isRecycled()) {
                paint.setAlpha(150);
                wingRect.set(0, 0, w, winH);
                c.drawBitmap(bitmap, null, wingRect, paint);
                paint.setAlpha(255);
            }

            int r = Color.red(bg);
            int g = Color.green(bg);
            int b = Color.blue(bg);

            // Apple TV+ cinema directional left vignette for left-aligned hero typography
            if (leftAlignedHero) {
                veilPaint.setShader(
                        new LinearGradient(
                                0,
                                0,
                                w * 0.74f,
                                0,
                                new int[] {
                                    Color.argb(236, r, g, b),
                                    Color.argb(204, r, g, b),
                                    Color.argb(122, r, g, b),
                                    Color.argb(28, r, g, b),
                                    Color.argb(0, r, g, b)
                                },
                                new float[] {0f, 0.30f, 0.56f, 0.82f, 1f},
                                Shader.TileMode.CLAMP));
                c.drawRect(0, 0, w * 0.75f, h, veilPaint);
                veilPaint.setShader(null);
            }

            // Top floating navigation bar subtle legibility scrim
            veilPaint.setShader(
                    new LinearGradient(
                            0,
                            0,
                            0,
                            h * 0.16f,
                            new int[] {0x70000000, 0x24000000, 0x00000000},
                            new float[] {0f, 0.55f, 1f},
                            Shader.TileMode.CLAMP));
            c.drawRect(0, 0, w, h * 0.16f, veilPaint);
            veilPaint.setShader(null);

            // Bottom lock-in gradient into ambientColor so the episode shelf sits on a pure surface
            float fadeStart = leftAlignedHero ? winH * 0.42f : winH * 0.46f;
            veilPaint.setShader(
                    new LinearGradient(
                            0,
                            fadeStart,
                            0,
                            winH,
                            new int[] {
                                Color.argb(0, r, g, b),
                                Color.argb(104, r, g, b),
                                Color.argb(220, r, g, b),
                                Color.argb(255, r, g, b)
                            },
                            new float[] {0f, 0.44f, 0.80f, 1f},
                            Shader.TileMode.CLAMP));
            c.drawRect(0, fadeStart, w, winH + 2f, veilPaint);
            veilPaint.setShader(null);

            // Scroll-driven ambient veil when user scrolls down into the episode grid
            if (scrollProgress > 0.005f) {
                int veilAlpha = Math.min(240, Math.round(scrollProgress * 240f));
                veilPaint.setColor(Color.argb(veilAlpha, r, g, b));
                c.drawRect(0, 0, w, winH, veilPaint);
            }
        }

        private void drawHorizontalHero(Canvas c, int w, int h, float winH, Bitmap hero, int bg) {
            int bw = hero.getWidth();
            int bh = hero.getHeight();
            if (bw <= 0 || bh <= 0) return;

            // Proportional widescreen framing: never stretches aspect ratio (scaleX == scaleY)
            float scale = Math.max((float) w / bw, winH / bh);
            float dw = bw * scale;
            float dh = bh * scale;
            float dx = (w - dw) * 0.5f;
            float dy = (winH - dh) * 0.22f;
            dstRect.set(dx, dy, dx + dw, dy + dh);

            if (useLightweightBackdropDraw(android.os.Build.VERSION.SDK_INT, a.reduced)) {
                int clip = c.save();
                c.clipRect(0, 0, w, winH);
                paint.setAlpha(255);
                c.drawBitmap(hero, null, dstRect, paint);
                Bitmap blurred =
                        wideBlurredBitmap != null && !wideBlurredBitmap.isRecycled()
                                ? wideBlurredBitmap
                                : bitmap;
                if (blurred != null && !blurred.isRecycled() && scrollProgress > 0.01f) {
                    int scrollBlurAlpha = Math.min(220, Math.round(scrollProgress * 220f));
                    paint.setAlpha(scrollBlurAlpha);
                    c.drawBitmap(blurred, null, dstRect, paint);
                    paint.setAlpha(255);
                }
                c.restoreToCount(clip);
                return;
            }

            int layer = c.saveLayer(0, 0, w, winH, null);

            paint.setAlpha(255);
            c.drawBitmap(hero, null, dstRect, paint);

            Bitmap blurred =
                    wideBlurredBitmap != null && !wideBlurredBitmap.isRecycled()
                            ? wideBlurredBitmap
                            : bitmap;
            if (blurred != null && !blurred.isRecycled()) {
                // Lower overlap frosted-glass blur (50%..100% of winH), matching MobileDetailScreen
                float blurTop = winH * 0.50f;
                int blurLayer = c.saveLayer(0, blurTop, w, winH, null);
                paint.setAlpha(255);
                c.drawBitmap(blurred, null, dstRect, paint);
                maskPaint.setShader(
                        new LinearGradient(
                                0,
                                blurTop,
                                0,
                                winH,
                                new int[] {0x00ffffff, 0x90ffffff, 0xedffffff, 0xffffffff},
                                new float[] {0f, 0.35f, 0.72f, 1f},
                                Shader.TileMode.CLAMP));
                c.drawRect(0, blurTop, w, winH, maskPaint);
                maskPaint.setShader(null);
                c.restoreToCount(blurLayer);

                if (scrollProgress > 0.01f) {
                    int scrollBlurAlpha = Math.min(230, Math.round(scrollProgress * 230f));
                    paint.setAlpha(scrollBlurAlpha);
                    c.drawBitmap(blurred, null, dstRect, paint);
                    paint.setAlpha(255);
                }
            }

            // Feather bottom edge of hero window into ambient background
            maskPaint.setShader(
                    new LinearGradient(
                            0,
                            0,
                            0,
                            winH,
                            new int[] {0xffffffff, 0xffffffff, 0xd8ffffff, 0x58ffffff, 0x00ffffff},
                            new float[] {0f, 0.58f, 0.76f, 0.91f, 1f},
                            Shader.TileMode.CLAMP));
            c.drawRect(0, 0, w, winH, maskPaint);
            maskPaint.setShader(null);
            c.restoreToCount(layer);
        }

        private void drawUnstretchedVerticalFallback(
                Canvas c, int w, int h, float winH, Bitmap raw, int bg) {
            int bw = raw.getWidth();
            int bh = raw.getHeight();
            if (bw <= 0 || bh <= 0) return;

            if (useLightweightBackdropDraw(android.os.Build.VERSION.SDK_INT, a.reduced)) {
                int clip = c.save();
                c.clipRect(0, 0, w, winH);
                if (bitmap != null && !bitmap.isRecycled()) {
                    wingRect.set(-w * 0.04f, -winH * 0.06f, w * 1.04f, winH * 1.06f);
                    paint.setAlpha(185);
                    c.drawBitmap(bitmap, null, wingRect, paint);
                    paint.setAlpha(255);
                }
                float scale = (winH * 0.96f) / bh;
                float dw = bw * scale;
                float dh = bh * scale;
                float dx =
                        leftAlignedHero
                                ? Math.max(
                                        w * 0.36f,
                                        Math.min(w - dw - w * 0.04f, w * 0.68f - dw * 0.5f))
                                : (w - dw) * 0.5f;
                dstRect.set(dx, 0f, dx + dw, dh);
                paint.setAlpha(255);
                c.drawBitmap(raw, null, dstRect, paint);
                int r = Color.red(bg);
                int g = Color.green(bg);
                int b = Color.blue(bg);
                float edge = Math.max(12f, dw * 0.20f);
                veilPaint.setShader(
                        new LinearGradient(
                                dx,
                                0,
                                dx + edge,
                                0,
                                new int[] {Color.argb(235, r, g, b), Color.argb(0, r, g, b)},
                                null,
                                Shader.TileMode.CLAMP));
                c.drawRect(dx, 0, dx + edge, winH, veilPaint);
                veilPaint.setShader(
                        new LinearGradient(
                                dx + dw - edge,
                                0,
                                dx + dw,
                                0,
                                new int[] {Color.argb(0, r, g, b), Color.argb(235, r, g, b)},
                                null,
                                Shader.TileMode.CLAMP));
                c.drawRect(dx + dw - edge, 0, dx + dw, winH, veilPaint);
                veilPaint.setShader(null);
                c.restoreToCount(clip);
                return;
            }

            int layer = c.saveLayer(0, 0, w, winH, null);

            // 1. Soft ambient color aura across the 16:9 wings so the sides are rich and
            // atmospheric
            if (bitmap != null && !bitmap.isRecycled()) {
                wingRect.set(-w * 0.04f, -winH * 0.06f, w * 1.04f, winH * 1.06f);
                paint.setAlpha(185);
                c.drawBitmap(bitmap, null, wingRect, paint);
                paint.setAlpha(255);
            }

            // 2. Crisp vertical poster scaled strictly by height (NEVER stretched or zoomed to 16:9
            // width). In leftAlignedHero mode, position subtly right of center so the left-aligned
            // hero stack enjoys breathing room while the right side displays the full poster
            // cleanly.
            float scale = (winH * 0.96f) / bh;
            float dw = bw * scale;
            float dh = bh * scale;
            float dx =
                    leftAlignedHero
                            ? Math.max(
                                    w * 0.36f, Math.min(w - dw - w * 0.04f, w * 0.68f - dw * 0.5f))
                            : (w - dw) * 0.5f;
            float dy = 0f;
            dstRect.set(dx, dy, dx + dw, dy + dh);

            int centerLayer = c.saveLayer(dx, 0, dx + dw, winH, null);
            paint.setAlpha(255);
            c.drawBitmap(raw, null, dstRect, paint);
            // Feather left and right edges of the vertical poster into the ambient color wings
            maskPaint.setShader(
                    new LinearGradient(
                            dx,
                            0,
                            dx + dw,
                            0,
                            new int[] {0x00ffffff, 0xffffffff, 0xffffffff, 0x00ffffff},
                            new float[] {0f, 0.15f, 0.85f, 1f},
                            Shader.TileMode.CLAMP));
            c.drawRect(dx, 0, dx + dw, winH, maskPaint);
            maskPaint.setShader(null);
            c.restoreToCount(centerLayer);

            // 3. Lower overlap frosted-glass blur
            if (bitmap != null && !bitmap.isRecycled()) {
                float blurTop = winH * 0.52f;
                int blurLayer = c.saveLayer(0, blurTop, w, winH, null);
                paint.setAlpha(245);
                c.drawBitmap(bitmap, null, dstRect, paint);
                maskPaint.setShader(
                        new LinearGradient(
                                0,
                                blurTop,
                                0,
                                winH,
                                new int[] {0x00ffffff, 0x90ffffff, 0xedffffff, 0xffffffff},
                                new float[] {0f, 0.36f, 0.74f, 1f},
                                Shader.TileMode.CLAMP));
                c.drawRect(0, blurTop, w, winH, maskPaint);
                maskPaint.setShader(null);
                c.restoreToCount(blurLayer);

                if (scrollProgress > 0.01f) {
                    int scrollBlurAlpha = Math.min(225, Math.round(scrollProgress * 225f));
                    wingRect.set(0, 0, w, winH);
                    paint.setAlpha(scrollBlurAlpha);
                    c.drawBitmap(bitmap, null, wingRect, paint);
                    paint.setAlpha(255);
                }
            }

            // 4. Vertical bottom feathering into ambientColor
            maskPaint.setShader(
                    new LinearGradient(
                            0,
                            0,
                            0,
                            winH,
                            new int[] {0xffffffff, 0xffffffff, 0xd8ffffff, 0x58ffffff, 0x00ffffff},
                            new float[] {0f, 0.58f, 0.76f, 0.91f, 1f},
                            Shader.TileMode.CLAMP));
            c.drawRect(0, 0, w, winH, maskPaint);
            maskPaint.setShader(null);
            c.restoreToCount(layer);
        }
    }
}
