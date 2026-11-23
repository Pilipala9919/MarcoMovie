package com.pilipala.marcomovie;

import android.graphics.*;
import android.graphics.drawable.BitmapDrawable;
import android.util.LruCache;
import android.view.View;
import android.widget.ImageView;

/**
 * Dynamic, luminous ambient aurora field for TV and Home backdrops.
 *
 * <p>Supports vivid poster-driven adaptive glow ({@link Prefs#BG_MODE_ADAPTIVE}) and user-selected
 * Apple TV living-room soft gradient themes / custom dual-tone hues ({@link
 * Prefs#BG_MODE_GRADIENT}). Three overlapping soft radial light pools breathe and drift smoothly
 * across the screen and morph colors in place as focus moves across covers.
 */
final class HomeAmbient extends View {
    static final int PRESET_CUSTOM = 6;

    static final String[] PRESET_NAMES = {"极光青翠", "暮色流光", "深海晨雾", "暖金影院", "星云紫夜", "冰川银雾"};
    static final String[] PRESET_SUBTITLES = {
        "翡翠湖光与晴空柔雾", "鸢尾紫霞与玫瑰晚风", "冰川海湾与蔚蓝天际", "胡桃木暖灯与胶片琥珀", "深空星尘与极夜紫罗兰", "通透银灰与克制微光"
    };
    static final int[] PRESET_LEFT = {
        0xff0ea88d, 0xff7c4dff, 0xff1685d8, 0xffc87d20, 0xff813cf0, 0xff4f7396
    };
    static final int[] PRESET_RIGHT = {
        0xff2474d6, 0xffd13d82, 0xff0fa6b5, 0xffb83b42, 0xff1b85cf, 0xff35689c
    };

    private static final float ORB_UNIT = 100f;
    private static final float MORPH_SECONDS = 0.42f;
    private static final int TV_CACHE_W = 192;
    private static final int TV_CACHE_H = 108;

    final MainActivity a;
    final LruCache<String, int[]> colors = new LruCache<>(64);

    private final Paint basePaint = new Paint(Paint.ANTI_ALIAS_FLAG | Paint.DITHER_FLAG);
    private final Paint orb1Paint = new Paint(Paint.ANTI_ALIAS_FLAG | Paint.DITHER_FLAG);
    private final Paint orb2Paint = new Paint(Paint.ANTI_ALIAS_FLAG | Paint.DITHER_FLAG);
    private final Paint orb3Paint = new Paint(Paint.ANTI_ALIAS_FLAG | Paint.DITHER_FLAG);
    private final Paint cacheDrawPaint = new Paint(Paint.FILTER_BITMAP_FLAG | Paint.DITHER_FLAG);
    private final Paint cacheCrossfadePaint =
            new Paint(Paint.FILTER_BITMAP_FLAG | Paint.DITHER_FLAG);
    private final RectF dstRect = new RectF();
    private Bitmap cachedPrevBitmap;
    private Bitmap cachedCurrBitmap;
    private boolean cachedBitmapDirty = true;

    ImageView wanted;
    Runnable pending;

    // Target colors (public-package fields retained for compatibility)
    int left = 0xff1c6ea8, right = 0xff6e3da8;
    int applied;
    volatile float strength = 1f;
    volatile boolean adaptivePosterMode = true;
    int appearanceRevision;

    // Live morph & dynamic aurora state
    private int startLeft = left, startRight = right, startMid = deriveTertiary(left, right);
    private int targetMid = deriveTertiary(left, right);
    private int curLeft = left, curRight = right, curMid = targetMid;
    float morphProgress = 1f;
    private float phase = 0f;
    private float frameAccum = 0f;
    private boolean shadersDirty = true;
    private int lastBaseW = -1, lastBaseH = -1;
    boolean loopRunning;
    private float scrollReveal = 1f;

    static float computeScrollReveal(int scrollY, int heroHeightPx) {
        if (heroHeightPx <= 0) return 1f;
        float start = heroHeightPx * 0.12f;
        float end = heroHeightPx * 0.82f;
        if (scrollY <= start) return 0.68f;
        if (scrollY >= end) return 1f;
        float t = (scrollY - start) / (end - start);
        float smooth = t * t * (3f - 2f * t);
        return 0.68f + 0.32f * smooth;
    }

    void followHeroColors(int first, int second) {
        if (!adaptivePosterMode) return;
        transition(first, second);
    }

    void setScrollReveal(float reveal) {
        float clamped = Math.max(0f, Math.min(1f, reveal));
        if (Math.abs(clamped - scrollReveal) < 0.004f) return;
        scrollReveal = clamped;
        setAlpha(clamped);
    }

    private final MotionLoop.Step driftStep = this::advanceDrift;

    private boolean advanceDrift(float dt) {
        if (!shouldAnimate()) {
            loopRunning = false;
            return false;
        }
        boolean tv = a.isTvDevice();
        boolean morphing = morphProgress < 1f;
        if (morphing) {
            morphProgress = Math.min(1f, morphProgress + dt / MORPH_SECONDS);
            float eased = cubicEaseOut(morphProgress);
            curLeft = mix(startLeft, left, eased);
            curRight = mix(startRight, right, eased);
            curMid = mix(startMid, targetMid, eased);
            if (!tv) {
                shadersDirty = true;
                if (morphProgress >= 1f && a.root != null) {
                    com.pilipala.glass.GlassworkSurface.invalidateBackdrop(a.root);
                }
            } else if (morphProgress >= 1f) {
                cachedPrevBitmap = null;
            }
        }
        if (tv) {
            invalidate();
            if (morphProgress >= 1f) {
                loopRunning = false;
                return false;
            }
            return true;
        }
        phase += dt;
        if (phase > 6283.185f) phase -= 6283.185f;
        frameAccum += dt;
        float interval = morphing ? 0.016f : 0.032f;
        if (morphing || frameAccum >= interval) {
            frameAccum = 0f;
            invalidate();
        }
        return true;
    }

    HomeAmbient(MainActivity host) {
        super(host);
        a = host;
        setTag("home-ambient");
        setImportantForAccessibility(IMPORTANT_FOR_ACCESSIBILITY_NO);
        applyFromPrefs(false);
    }

    static int effectiveBgMode(MainActivity host) {
        if (host == null || host.prefs == null) return Prefs.BG_MODE_ADAPTIVE;
        return Prefs.resolveTvBgMode(
                host.prefs.contains(Prefs.TV_BG_MODE),
                host.prefs.getInt(Prefs.TV_BG_MODE, Prefs.BG_MODE_ADAPTIVE),
                host.prefs.getBoolean(Prefs.WALLPAPER_ENABLED, false),
                host.prefs.getBoolean(Prefs.HOME_AMBIENT, true));
    }

    static int[] activeGradientColors(MainActivity host) {
        if (host == null || host.prefs == null) {
            return new int[] {PRESET_LEFT[0], PRESET_RIGHT[0]};
        }
        int preset = Prefs.clampGlowPreset(host.prefs.getInt(Prefs.TV_GLOW_PRESET, 0));
        if (preset == PRESET_CUSTOM) {
            int l =
                    0xff000000
                            | Prefs.clampRgb24(
                                    host.prefs.getInt(
                                            Prefs.TV_GLOW_COLOR_LEFT, PRESET_LEFT[0] & 0xFFFFFF));
            int r =
                    0xff000000
                            | Prefs.clampRgb24(
                                    host.prefs.getInt(
                                            Prefs.TV_GLOW_COLOR_RIGHT, PRESET_RIGHT[0] & 0xFFFFFF));
            return new int[] {l, r};
        }
        int idx = Math.max(0, Math.min(PRESET_LEFT.length - 1, preset));
        return new int[] {PRESET_LEFT[idx], PRESET_RIGHT[idx]};
    }

    static String activeBackgroundSummary(MainActivity host) {
        int mode = effectiveBgMode(host);
        if (mode == Prefs.BG_MODE_WALLPAPER) return "自定义图片壁纸";
        if (mode == Prefs.BG_MODE_DARK) return "纯深色影院";
        if (mode == Prefs.BG_MODE_GRADIENT) {
            int preset =
                    host == null || host.prefs == null
                            ? 0
                            : Prefs.clampGlowPreset(host.prefs.getInt(Prefs.TV_GLOW_PRESET, 0));
            return preset == PRESET_CUSTOM
                    ? "动态柔光渐变 · 自定义双色"
                    : "动态柔光渐变 · " + PRESET_NAMES[Math.min(PRESET_NAMES.length - 1, preset)];
        }
        return "封面色调动态自适应柔光";
    }

    void applyFromPrefs(boolean animate) {
        int mode = effectiveBgMode(a);
        strength =
                a.isTvDevice()
                        ? Prefs.tvAmbientStrength(a.prefs.getInt(Prefs.TV_AMBIENT_PERCENT, 75))
                        : 1f;
        adaptivePosterMode = (mode == Prefs.BG_MODE_ADAPTIVE);
        if (mode == Prefs.BG_MODE_WALLPAPER || mode == Prefs.BG_MODE_DARK) {
            setVisibility(View.GONE);
            syncMotionLoop();
            return;
        }
        setVisibility(View.VISIBLE);
        if (mode == Prefs.BG_MODE_GRADIENT) {
            int[] pair = activeGradientColors(a);
            int c0 = softenAccentForGlow(pair[0]);
            int c1 = harmonizeSecondary(c0, softenAccentForGlow(pair[1]));
            if (animate) {
                transition(c0, c1);
            } else {
                snapColors(c0, c1);
            }
        } else {
            shadersDirty = true;
            cachedBitmapDirty = true;
            invalidate();
            if (wanted != null) posterReady(wanted);
        }
        syncMotionLoop();
        if (!a.isTvDevice() && a.root != null) {
            com.pilipala.glass.GlassworkSurface.invalidateBackdrop(a.root);
        }
    }

    void previewCustomColors(int leftColor, int rightColor) {
        adaptivePosterMode = false;
        setVisibility(View.VISIBLE);
        int c0 = softenAccentForGlow(leftColor);
        int c1 = harmonizeSecondary(c0, softenAccentForGlow(rightColor));
        transition(c0, c1);
        syncMotionLoop();
    }

    static int softenAccentForGlow(int color) {
        float[] hsv = new float[3];
        Color.colorToHSV(color, hsv);
        hsv[1] = Math.max(0.38f, Math.min(0.92f, hsv[1] * 1.12f));
        hsv[2] = Math.max(0.52f, Math.min(0.84f, hsv[2] * 1.15f));
        return Color.HSVToColor(hsv);
    }

    static int harmonizeSecondary(int primary, int secondary) {
        float[] h1 = new float[3];
        float[] h2 = new float[3];
        Color.colorToHSV(primary, h1);
        Color.colorToHSV(secondary, h2);
        float diff = Math.abs(h1[0] - h2[0]);
        if (diff > 180f) diff = 360f - diff;
        if (diff < 26f) {
            h2[0] = (h1[0] + 36f) % 360f;
            h2[1] = Math.max(0.46f, Math.min(0.92f, h2[1]));
            h2[2] = Math.max(0.54f, Math.min(0.82f, h1[2] * 0.94f));
            return Color.HSVToColor(h2);
        }
        return secondary;
    }

    static int deriveTertiary(int primary, int secondary) {
        int blended = mix(primary, secondary, 0.5f);
        float[] hsv = new float[3];
        Color.colorToHSV(blended, hsv);
        hsv[0] = (hsv[0] + 332f) % 360f;
        hsv[1] = Math.max(0.48f, Math.min(0.94f, hsv[1] * 1.08f));
        hsv[2] = Math.max(0.56f, Math.min(0.86f, hsv[2] * 1.04f));
        return Color.HSVToColor(hsv);
    }

    void follow(ImageView image) {
        if (wanted == image) return;
        wanted = image;
        if (adaptivePosterMode) posterReady(image);
    }

    void posterReady(ImageView image) {
        if (!adaptivePosterMode || image != wanted) return;
        if (pending != null) removeCallbacks(pending);
        pending =
                () -> {
                    pending = null;
                    if (!adaptivePosterMode
                            || image != wanted
                            || !isAttachedToWindow()
                            || !(image.getDrawable() instanceof BitmapDrawable)) return;
                    Bitmap bitmap = ((BitmapDrawable) image.getDrawable()).getBitmap();
                    if (bitmap == null || bitmap.isRecycled()) return;
                    String key = String.valueOf(image.getTag());
                    int[] cached = colors.get(key);
                    if (cached != null) {
                        transition(cached[0], cached[1]);
                        return;
                    }
                    if (a.reduced) {
                        int c0 = sample(bitmap, 0);
                        int c1 = harmonizeSecondary(c0, sample(bitmap, 1));
                        int[] target = new int[] {c0, c1};
                        colors.put(key, target);
                        transition(c0, c1);
                        return;
                    }
                    final int revision = appearanceRevision;
                    a.artwork.execute(
                            () -> {
                                try {
                                    if (bitmap.isRecycled()) return;
                                    final int c0 = sample(bitmap, 0);
                                    final int c1 = harmonizeSecondary(c0, sample(bitmap, 1));
                                    final int[] target = new int[] {c0, c1};
                                    colors.put(key, target);
                                    post(
                                            () -> {
                                                if (adaptivePosterMode
                                                        && image == wanted
                                                        && isAttachedToWindow()
                                                        && revision == appearanceRevision) {
                                                    transition(c0, c1);
                                                }
                                            });
                                } catch (Throwable ignored) {
                                }
                            });
                };
        postDelayed(pending, a.reduced ? 0 : (a.isTvDevice() ? 180 : 80));
    }

    static int sample(Bitmap bitmap, int side) {
        double red = 0, green = 0, blue = 0, weight = 0;
        float[] hsv = new float[3];
        int bw = bitmap.getWidth(), bh = bitmap.getHeight();
        for (int y = 0; y < 20; y++) {
            for (int x = 0; x < 12; x++) {
                int px = Math.min(bw - 1, (x * 2 + 1 + side * 24) * bw / 48);
                int py = Math.min(bh - 1, (y * 2 + 1) * bh / 40);
                int c = bitmap.getPixel(px, py);
                Color.colorToHSV(c, hsv);
                if (Color.alpha(c) < 128 || hsv[2] < 0.08f || hsv[2] > 0.96f) continue;
                double satBoost = hsv[1] * hsv[1] * 3.8;
                double midBright = Math.max(0.3, 1.0 - Math.abs(hsv[2] - 0.56) * 0.65);
                double w = 0.05 + satBoost * midBright;
                red += Color.red(c) * w;
                green += Color.green(c) * w;
                blue += Color.blue(c) * w;
                weight += w;
            }
        }
        if (weight == 0) return side == 0 ? 0xff1f76b8 : 0xff7042b8;
        Color.colorToHSV(
                Color.rgb(
                        Math.min(255, (int) (red / weight)),
                        Math.min(255, (int) (green / weight)),
                        Math.min(255, (int) (blue / weight))),
                hsv);
        hsv[1] = Math.max(0.46f, Math.min(0.94f, hsv[1] * 1.32f));
        hsv[2] = Math.max(0.58f, Math.min(0.84f, 0.54f + hsv[2] * 0.34f));
        return Color.HSVToColor(hsv);
    }

    static int mix(int from, int to, float f) {
        float t = Math.max(0f, Math.min(1f, f));
        return Color.rgb(
                Math.round(Color.red(from) + (Color.red(to) - Color.red(from)) * t),
                Math.round(Color.green(from) + (Color.green(to) - Color.green(from)) * t),
                Math.round(Color.blue(from) + (Color.blue(to) - Color.blue(from)) * t));
    }

    private static float cubicEaseOut(float t) {
        float inv = 1f - Math.max(0f, Math.min(1f, t));
        return 1f - inv * inv * inv;
    }

    /** Called by the host when its persisted TV appearance setting changes. */
    void setStrength(float value) {
        float next = Math.max(0f, Math.min(1f, value));
        if (strength == next) return;
        strength = next;
        appearanceRevision++;
        shadersDirty = true;
        cachedBitmapDirty = true;
        invalidate();
        syncMotionLoop();
        if (!a.isTvDevice() && a.root != null) {
            com.pilipala.glass.GlassworkSurface.invalidateBackdrop(a.root);
        }
        if (adaptivePosterMode && wanted != null) posterReady(wanted);
    }

    private void snapColors(int first, int second) {
        left = first;
        right = second;
        targetMid = deriveTertiary(first, second);
        startLeft = curLeft = left;
        startRight = curRight = right;
        startMid = curMid = targetMid;
        morphProgress = 1f;
        shadersDirty = true;
        cachedBitmapDirty = true;
        cachedPrevBitmap = null;
        invalidate();
    }

    void transition(int first, int second) {
        if (left == first && right == second) return;
        applied++;
        startLeft = curLeft;
        startRight = curRight;
        startMid = curMid;
        left = first;
        right = second;
        targetMid = deriveTertiary(first, second);
        if (a.reduced) {
            snapColors(first, second);
            if (!a.isTvDevice() && a.root != null) {
                com.pilipala.glass.GlassworkSurface.invalidateBackdrop(a.root);
            }
            return;
        }
        if (a.isTvDevice()) {
            cachedPrevBitmap = cachedCurrBitmap;
            cachedCurrBitmap = renderCachedField(left, right);
            cachedBitmapDirty = false;
        }
        morphProgress = 0f;
        syncMotionLoop();
        invalidate();
    }

    private Bitmap renderCachedField(int first, int second) {
        float eff = effectiveStrength();
        int mid = deriveTertiary(first, second);
        Bitmap b;
        try {
            b = Bitmap.createBitmap(TV_CACHE_W, TV_CACHE_H, Bitmap.Config.ARGB_8888);
        } catch (Throwable ignored) {
            return null;
        }
        Canvas c = new Canvas(b);
        Paint p = new Paint(Paint.ANTI_ALIAS_FLAG | Paint.DITHER_FLAG);
        p.setShader(
                new LinearGradient(
                        0,
                        0,
                        TV_CACHE_W,
                        TV_CACHE_H,
                        mix(0xff0d111a, first, eff * 0.56f),
                        mix(0xff080b12, second, eff * 0.44f),
                        Shader.TileMode.CLAMP));
        c.drawRect(0, 0, TV_CACHE_W, TV_CACHE_H, p);
        if (strength > 0.005f) {
            p.setShader(makeOrbShader(first, eff, 242, 152, 54));
            drawOrb(
                    c,
                    TV_CACHE_W * 0.24f,
                    TV_CACHE_H * 0.22f,
                    TV_CACHE_W * 0.68f,
                    TV_CACHE_H * 0.86f,
                    p);
            p.setShader(makeOrbShader(second, eff, 234, 144, 50));
            drawOrb(
                    c,
                    TV_CACHE_W * 0.78f,
                    TV_CACHE_H * 0.46f,
                    TV_CACHE_W * 0.66f,
                    TV_CACHE_H * 0.84f,
                    p);
            p.setShader(makeOrbShader(mid, eff, 200, 110, 34));
            drawOrb(
                    c,
                    TV_CACHE_W * 0.46f,
                    TV_CACHE_H * 0.84f,
                    TV_CACHE_W * 0.60f,
                    TV_CACHE_H * 0.74f,
                    p);
        }
        // Bake subtle cinema depth vignette directly into the cached TV texture so we avoid
        // stacking a separate 1080p homeGradient() overdraw layer on Android TV.
        p.setShader(
                new LinearGradient(
                        0,
                        0,
                        0,
                        TV_CACHE_H,
                        new int[] {0x28090c14, 0x0c090c14, 0x48090c14},
                        new float[] {0f, 0.48f, 1f},
                        Shader.TileMode.CLAMP));
        c.drawRect(0, 0, TV_CACHE_W, TV_CACHE_H, p);
        return b;
    }

    private float effectiveStrength() {
        if (strength <= 0.005f) return 0f;
        return Math.min(1f, (float) Math.pow(strength, 0.72));
    }

    private void rebuildShaders(int w, int h) {
        float eff = effectiveStrength();
        int baseTop = mix(0xff0d111a, curLeft, eff * 0.56f);
        int baseBottom = mix(0xff080b12, curRight, eff * 0.44f);
        basePaint.setShader(
                new LinearGradient(0, 0, w, h, baseTop, baseBottom, Shader.TileMode.CLAMP));

        orb1Paint.setShader(makeOrbShader(curLeft, eff, 242, 152, 54));
        orb2Paint.setShader(makeOrbShader(curRight, eff, 234, 144, 50));
        orb3Paint.setShader(makeOrbShader(curMid, eff, 200, 110, 34));

        lastBaseW = w;
        lastBaseH = h;
        shadersDirty = false;
    }

    private static RadialGradient makeOrbShader(
            int color, float eff, int coreAlpha, int midAlpha, int outerAlpha) {
        int r = Color.red(color), g = Color.green(color), b = Color.blue(color);
        return new RadialGradient(
                0f,
                0f,
                ORB_UNIT,
                new int[] {
                    Color.argb(Math.min(255, Math.round(coreAlpha * eff)), r, g, b),
                    Color.argb(Math.min(255, Math.round(midAlpha * eff)), r, g, b),
                    Color.argb(Math.min(255, Math.round(outerAlpha * eff)), r, g, b),
                    0x00000000
                },
                new float[] {0f, 0.38f, 0.72f, 1f},
                Shader.TileMode.CLAMP);
    }

    /** Static snapshot helper for callers/tests requesting a rendered field preview. */
    Bitmap field(int first, int second) {
        int w = 240, h = 135;
        float eff = effectiveStrength();
        int mid = deriveTertiary(first, second);
        Bitmap b = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888);
        Canvas c = new Canvas(b);
        Paint p = new Paint(Paint.ANTI_ALIAS_FLAG | Paint.DITHER_FLAG);
        p.setShader(
                new LinearGradient(
                        0,
                        0,
                        w,
                        h,
                        mix(0xff0d111a, first, eff * 0.56f),
                        mix(0xff080b12, second, eff * 0.44f),
                        Shader.TileMode.CLAMP));
        c.drawRect(0, 0, w, h, p);

        p.setShader(makeOrbShader(first, eff, 242, 152, 54));
        drawOrb(c, w * 0.24f, h * 0.22f, w * 0.68f, h * 0.84f, p);
        p.setShader(makeOrbShader(second, eff, 234, 144, 50));
        drawOrb(c, w * 0.78f, h * 0.46f, w * 0.66f, h * 0.82f, p);
        p.setShader(makeOrbShader(mid, eff, 200, 110, 34));
        drawOrb(c, w * 0.46f, h * 0.84f, w * 0.60f, h * 0.74f, p);
        return b;
    }

    private static void drawOrb(Canvas c, float cx, float cy, float rx, float ry, Paint paint) {
        c.save();
        c.translate(cx, cy);
        c.scale(rx / ORB_UNIT, ry / ORB_UNIT);
        c.drawRect(-ORB_UNIT, -ORB_UNIT, ORB_UNIT, ORB_UNIT, paint);
        c.restore();
    }

    private boolean shouldAnimate() {
        if (!isAttachedToWindow()
                || getVisibility() != View.VISIBLE
                || getWindowVisibility() != View.VISIBLE
                || a.reduced
                || strength <= 0.01f) {
            return false;
        }
        // On Android TV, only animate during active color transitions; stay completely idle
        // between focus changes so scrolling and focus hops hold steady 60fps.
        if (a.isTvDevice()) {
            return morphProgress < 1f;
        }
        return true;
    }

    private void syncMotionLoop() {
        if (shouldAnimate()) {
            if (!loopRunning) {
                loopRunning = true;
                frameAccum = 0f;
                MotionLoop.add(driftStep);
            }
        } else if (loopRunning) {
            loopRunning = false;
            MotionLoop.remove(driftStep);
        }
    }

    @Override
    protected void onDraw(Canvas c) {
        int w = getWidth(), h = getHeight();
        if (w <= 0 || h <= 0) return;
        if (a.isTvDevice()) {
            if (cachedBitmapDirty || cachedCurrBitmap == null || cachedCurrBitmap.isRecycled()) {
                cachedCurrBitmap = renderCachedField(left, right);
                cachedBitmapDirty = false;
            }
            if (cachedCurrBitmap == null || cachedCurrBitmap.isRecycled()) {
                c.drawColor(0xff0b0e16);
                return;
            }
            dstRect.set(0, 0, w, h);
            if (morphProgress < 1f && cachedPrevBitmap != null && !cachedPrevBitmap.isRecycled()) {
                c.drawBitmap(cachedPrevBitmap, null, dstRect, cacheDrawPaint);
                cacheCrossfadePaint.setAlpha(
                        Math.max(0, Math.min(255, Math.round(cubicEaseOut(morphProgress) * 255f))));
                c.drawBitmap(cachedCurrBitmap, null, dstRect, cacheCrossfadePaint);
            } else {
                c.drawBitmap(cachedCurrBitmap, null, dstRect, cacheDrawPaint);
            }
            return;
        }
        if (shadersDirty || w != lastBaseW || h != lastBaseH) {
            rebuildShaders(w, h);
        }
        c.drawRect(0, 0, w, h, basePaint);
        if (strength <= 0.005f) return;

        float t = a.reduced ? 0f : phase;

        // Orb 1: Dominant upper-left ↔ top-center luminous pool
        float cx1 = w * (0.24f + 0.16f * (float) Math.sin(t * 0.52));
        float cy1 = h * (0.22f + 0.15f * (float) Math.cos(t * 0.41));
        float rx1 = w * (0.68f + 0.09f * (float) Math.sin(t * 0.63));
        float ry1 = h * (0.86f + 0.10f * (float) Math.cos(t * 0.47));
        drawOrb(c, cx1, cy1, rx1, ry1, orb1Paint);

        // Orb 2: Vivid secondary right ↔ lower-right pool
        float cx2 = w * (0.78f + 0.15f * (float) Math.cos(t * 0.46 + 1.3));
        float cy2 = h * (0.46f + 0.18f * (float) Math.sin(t * 0.37 + 0.7));
        float rx2 = w * (0.66f + 0.10f * (float) Math.cos(t * 0.54));
        float ry2 = h * (0.84f + 0.11f * (float) Math.sin(t * 0.42 + 0.4));
        drawOrb(c, cx2, cy2, rx2, ry2, orb2Paint);

        // Orb 3: Harmonic flowing lower highlight
        float cx3 = w * (0.46f + 0.22f * (float) Math.sin(t * 0.34 + 2.4));
        float cy3 = h * (0.84f + 0.13f * (float) Math.cos(t * 0.49 + 1.1));
        float rx3 = w * (0.60f + 0.09f * (float) Math.sin(t * 0.44 + 0.5));
        float ry3 = h * (0.74f + 0.10f * (float) Math.cos(t * 0.38));
        drawOrb(c, cx3, cy3, rx3, ry3, orb3Paint);
    }

    @Override
    public void setVisibility(int visibility) {
        super.setVisibility(visibility);
        syncMotionLoop();
    }

    @Override
    protected void onWindowVisibilityChanged(int visibility) {
        super.onWindowVisibilityChanged(visibility);
        syncMotionLoop();
    }

    @Override
    protected void onAttachedToWindow() {
        super.onAttachedToWindow();
        syncMotionLoop();
    }

    @Override
    protected void onDetachedFromWindow() {
        if (pending != null) removeCallbacks(pending);
        pending = null;
        if (loopRunning) {
            loopRunning = false;
            MotionLoop.remove(driftStep);
        }
        cachedPrevBitmap = null;
        cachedCurrBitmap = null;
        cachedBitmapDirty = true;
        wanted = null;
        super.onDetachedFromWindow();
    }
}
