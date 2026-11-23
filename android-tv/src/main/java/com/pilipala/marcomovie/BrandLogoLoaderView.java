// Copyright (C) 2026 Pilipala
// SPDX-License-Identifier: GPL-3.0-only
package com.pilipala.marcomovie;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.LinearGradient;
import android.graphics.Matrix;
import android.graphics.Paint;
import android.graphics.Path;
import android.graphics.PathMeasure;
import android.graphics.RectF;
import android.graphics.Shader;
import android.view.View;

/**
 * F8 metallic film-ribbon {@code M} brand loader matching {@code logo_mark.png}, {@code
 * StartupIntro.BrandView}, and Flutter {@code BrandLogoLoader}.
 *
 * <ul>
 *   <li>Cycle period: {@code 1600ms} ({@link MotionTokens#DURATION_LOGO_LOOP_MS}). First half
 *       traces the continuous ribbon path; second half sweeps a diagonal metallic specular sheen.
 *   <li>Reduce motion ({@code Prefs.REDUCED}): renders static full ribbon with calm breathing
 *       opacity between {@code 0.72} and {@code 1.0}.
 *   <li>Zero per-frame object allocations in {@link #onDraw(Canvas)}, and stops {@link MotionLoop}
 *       immediately when detached, invisible, window-hidden, or inactive.
 * </ul>
 */
public final class BrandLogoLoaderView extends View {
    public static final float[] SPROCKET_RATIOS = {0.16f, 0.27f, 0.38f, 0.72f, 0.84f};

    private static final float CYCLE_SECONDS = MotionTokens.DURATION_LOGO_LOOP_MS / 1000f;

    private final Path fullPath = new Path();
    private final Path tracePath = new Path();
    private final PathMeasure pathMeasure = new PathMeasure();
    private final Paint guidePaint = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint metallicPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint sheenPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint sprocketPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Matrix sheenMatrix = new Matrix();
    private final RectF sprocketRect = new RectF();
    private final float[] sprocketX = new float[SPROCKET_RATIOS.length];
    private final float[] sprocketY = new float[SPROCKET_RATIOS.length];
    private final float[] sprocketDeg = new float[SPROCKET_RATIOS.length];
    private final float[] posTmp = new float[2];
    private final float[] tanTmp = new float[2];

    private LinearGradient metallicGradient;
    private LinearGradient sheenGradient;
    private float pathLength;
    private float ribbonWidth;
    private float holeHalfW;
    private float holeHalfH;
    private float holeRadius;
    private boolean showSprockets;

    private final MainActivity hostActivity;
    private Boolean reducedMotionOverride;
    private boolean active = true;
    private boolean loopRunning;
    private float phase;

    private final MotionLoop.Step frameStep = this::advanceFrame;

    public BrandLogoLoaderView(Context context) {
        super(context);
        setTag("brand-logo-loader");
        setFocusable(false);
        setContentDescription("正在加载");

        this.hostActivity = (context instanceof MainActivity) ? (MainActivity) context : null;

        guidePaint.setStyle(Paint.Style.STROKE);
        guidePaint.setStrokeCap(Paint.Cap.ROUND);
        guidePaint.setStrokeJoin(Paint.Join.ROUND);
        guidePaint.setColor(0xFFA8AEBC);

        metallicPaint.setStyle(Paint.Style.STROKE);
        metallicPaint.setStrokeCap(Paint.Cap.ROUND);
        metallicPaint.setStrokeJoin(Paint.Join.ROUND);

        sheenPaint.setStyle(Paint.Style.STROKE);
        sheenPaint.setStrokeCap(Paint.Cap.ROUND);
        sheenPaint.setStrokeJoin(Paint.Join.ROUND);

        sprocketPaint.setStyle(Paint.Style.FILL);
        sprocketPaint.setColor(0xFF14161B);
    }

    private static float clamp01(float v) {
        return Math.max(0f, Math.min(1f, v));
    }

    private static float easeInOutCubic(float t) {
        float x = clamp01(t);
        if (x < 0.5f) {
            return 4f * x * x * x;
        }
        float inv = -2f * x + 2f;
        return 1f - (inv * inv * inv) * 0.5f;
    }

    /** Normalized traced fraction {@code [0, 1]} along the continuous ribbon M silhouette. */
    public static float computeStrokeFraction(float phase, boolean reducedMotion) {
        if (reducedMotion) return 1f;
        float p = clamp01(phase);
        if (p >= 0.56f) return 1f;
        return easeInOutCubic(p / 0.56f);
    }

    /** Normalized diagonal sheen sweep progress {@code [0, 1]}, or {@code -1} when inactive. */
    public static float computeSheenProgress(float phase, boolean reducedMotion) {
        if (reducedMotion) return -1f;
        float p = clamp01(phase);
        if (p < 0.48f || p > 0.90f) return -1f;
        return easeInOutCubic((p - 0.48f) / (0.90f - 0.48f));
    }

    /**
     * Ribbon opacity at {@code phase}. Under {@code reducedMotion}, breathes gently within {@code
     * [0.72, 1.0]} ({@link MotionTokens#REDUCE_MOTION_LOGO_MIN_ALPHA} .. {@link
     * MotionTokens#REDUCE_MOTION_LOGO_MAX_ALPHA}).
     */
    public static float computeRibbonAlpha(float phase, boolean reducedMotion) {
        float p = clamp01(phase);
        if (reducedMotion) {
            float minA = MotionTokens.REDUCE_MOTION_LOGO_MIN_ALPHA;
            float maxA = MotionTokens.REDUCE_MOTION_LOGO_MAX_ALPHA;
            return minA + (maxA - minA) * (float) (0.5 + 0.5 * Math.cos(2.0 * Math.PI * p));
        }
        if (p <= 0.90f) return 1f;
        if (p <= 0.97f) {
            float t = (p - 0.90f) / 0.07f;
            return 1f - 0.65f * t;
        }
        float t = (p - 0.97f) / 0.03f;
        return 0.35f + 0.65f * t;
    }

    /** Pure lifecycle predicate controlling whether the 1.6s loader clock may tick. */
    public static boolean shouldRunLoop(
            boolean attached, boolean viewVisible, boolean windowVisible, boolean active) {
        return attached && viewVisible && windowVisible && active;
    }

    public void setActive(boolean active) {
        if (this.active == active) return;
        this.active = active;
        syncLoop();
    }

    /** Resolves effective reduce-motion state (explicit override takes precedence over host). */
    public static boolean resolveEffectiveReducedMotion(
            Boolean explicitOverride, boolean hostReduced) {
        return explicitOverride != null ? explicitOverride.booleanValue() : hostReduced;
    }

    private boolean isReducedMotionEffective() {
        return resolveEffectiveReducedMotion(
                reducedMotionOverride, hostActivity != null && hostActivity.reduced);
    }

    public void setReducedMotion(boolean reduced) {
        Boolean next = Boolean.valueOf(reduced);
        if (next.equals(this.reducedMotionOverride)) return;
        this.reducedMotionOverride = next;
        invalidate();
    }

    public boolean isLoopRunning() {
        return loopRunning;
    }

    private boolean canAnimate() {
        return shouldRunLoop(
                UiCompat.isAttached(this),
                getVisibility() == View.VISIBLE && isShown(),
                getWindowVisibility() == View.VISIBLE,
                active);
    }

    private void syncLoop() {
        if (canAnimate()) {
            if (!loopRunning) {
                loopRunning = true;
                MotionLoop.add(frameStep);
            }
        } else if (loopRunning) {
            loopRunning = false;
            MotionLoop.remove(frameStep);
        }
    }

    private boolean advanceFrame(float dtSeconds) {
        if (!canAnimate()) {
            loopRunning = false;
            return false;
        }
        phase = (phase + Math.min(dtSeconds, 0.05f) / CYCLE_SECONDS) % 1f;
        invalidate();
        return true;
    }

    private void rebuildGeometry(int w, int h) {
        float fw = w;
        float fh = h;
        float minDim = Math.min(fw, fh);
        ribbonWidth = Math.max(2.4f, minDim * 0.145f);
        guidePaint.setStrokeWidth(ribbonWidth);
        metallicPaint.setStrokeWidth(ribbonWidth);
        sheenPaint.setStrokeWidth(ribbonWidth * 0.96f);

        fullPath.reset();
        fullPath.moveTo(0.12f * fw, 0.72f * fh);
        fullPath.cubicTo(0.06f * fw, 0.44f * fh, 0.24f * fw, 0.22f * fh, 0.41f * fw, 0.29f * fh);
        fullPath.cubicTo(0.51f * fw, 0.33f * fh, 0.49f * fw, 0.64f * fh, 0.57f * fw, 0.63f * fh);
        fullPath.cubicTo(0.65f * fw, 0.62f * fh, 0.73f * fw, 0.19f * fh, 0.92f * fw, 0.27f * fh);

        pathMeasure.setPath(fullPath, false);
        pathLength = pathMeasure.getLength();

        metallicGradient =
                new LinearGradient(
                        0.08f * fw,
                        0.78f * fh,
                        0.94f * fw,
                        0.22f * fh,
                        new int[] {0xFF6A707E, 0xFFD2D6E0, 0xFFF4F6FA, 0xFFEAD8C6, 0xFFACB2BE},
                        new float[] {0f, 0.28f, 0.54f, 0.76f, 1f},
                        Shader.TileMode.CLAMP);
        metallicPaint.setShader(metallicGradient);

        float band = fw * 0.28f;
        sheenGradient =
                new LinearGradient(
                        -band,
                        0.15f * fh,
                        band,
                        0.85f * fh,
                        new int[] {0x00FFFFFF, 0xD9FFFFFF, 0x8CF5E8D6, 0x00FFFFFF},
                        new float[] {0f, 0.46f, 0.62f, 1f},
                        Shader.TileMode.CLAMP);
        sheenPaint.setShader(sheenGradient);

        float density = getResources().getDisplayMetrics().density;
        showSprockets = (minDim / Math.max(density, 1f)) >= 24f;
        holeHalfW = Math.max(0.7f, ribbonWidth * 0.17f);
        holeHalfH = Math.max(0.6f, ribbonWidth * 0.13f);
        holeRadius = Math.max(0.5f, holeHalfH * 0.56f);
        sprocketRect.set(-holeHalfW, -holeHalfH, holeHalfW, holeHalfH);

        for (int i = 0; i < SPROCKET_RATIOS.length; i++) {
            pathMeasure.getPosTan(pathLength * SPROCKET_RATIOS[i], posTmp, tanTmp);
            sprocketX[i] = posTmp[0];
            sprocketY[i] = posTmp[1];
            sprocketDeg[i] = (float) Math.toDegrees(Math.atan2(tanTmp[1], tanTmp[0]));
        }
    }

    @Override
    protected void onMeasure(int widthMeasureSpec, int heightMeasureSpec) {
        float density = getResources().getDisplayMetrics().density;
        int defaultPx = Math.max(1, Math.round(44f * density));
        int w = resolveSize(defaultPx, widthMeasureSpec);
        int h = resolveSize(defaultPx, heightMeasureSpec);
        setMeasuredDimension(w, h);
    }

    @Override
    protected void onSizeChanged(int w, int h, int oldw, int oldh) {
        super.onSizeChanged(w, h, oldw, oldh);
        if (w > 0 && h > 0) {
            rebuildGeometry(w, h);
        }
    }

    @Override
    protected void onDraw(Canvas canvas) {
        int w = getWidth();
        int h = getHeight();
        if (w <= 0 || h <= 0 || pathLength <= 0f) return;

        boolean reducedNow = isReducedMotionEffective();
        float strokeFraction = computeStrokeFraction(phase, reducedNow);
        float sheenProgress = computeSheenProgress(phase, reducedNow);
        float alpha = computeRibbonAlpha(phase, reducedNow);

        // 1) Grounded guide silhouette (zero allocations).
        guidePaint.setAlpha(Math.round(255f * 0.16f * alpha));
        canvas.drawPath(fullPath, guidePaint);

        // 2) Continuous ribbon M trace (reuse tracePath via rewind()).
        Path activePath;
        if (strokeFraction >= 0.999f) {
            activePath = fullPath;
        } else {
            tracePath.rewind();
            pathMeasure.getSegment(0f, pathLength * strokeFraction, tracePath, true);
            activePath = tracePath;
        }

        metallicPaint.setAlpha(Math.round(255f * alpha));
        canvas.drawPath(activePath, metallicPaint);

        // 3) Diagonal metallic sheen sweep (translate pre-allocated Matrix only).
        if (sheenProgress >= 0f && sheenProgress <= 1f && sheenGradient != null) {
            float sweepX = (-0.35f + 1.70f * sheenProgress) * w;
            sheenMatrix.setTranslate(sweepX, 0f);
            sheenGradient.setLocalMatrix(sheenMatrix);
            sheenPaint.setAlpha(Math.round(255f * alpha));
            canvas.drawPath(activePath, sheenPaint);
        }

        // 4) Film sprocket perforations along traced arc (precomputed coordinates).
        if (showSprockets) {
            sprocketPaint.setAlpha(Math.round(255f * 0.78f * alpha));
            for (int i = 0; i < SPROCKET_RATIOS.length; i++) {
                if (SPROCKET_RATIOS[i] > strokeFraction - 0.02f) continue;
                int save = canvas.save();
                canvas.translate(sprocketX[i], sprocketY[i]);
                canvas.rotate(sprocketDeg[i]);
                canvas.drawRoundRect(sprocketRect, holeRadius, holeRadius, sprocketPaint);
                canvas.restoreToCount(save);
            }
        }
    }

    @Override
    public void setVisibility(int visibility) {
        super.setVisibility(visibility);
        syncLoop();
    }

    @Override
    protected void onVisibilityChanged(View changedView, int visibility) {
        super.onVisibilityChanged(changedView, visibility);
        syncLoop();
    }

    @Override
    protected void onWindowVisibilityChanged(int visibility) {
        super.onWindowVisibilityChanged(visibility);
        syncLoop();
    }

    @Override
    protected void onAttachedToWindow() {
        super.onAttachedToWindow();
        syncLoop();
    }

    @Override
    protected void onDetachedFromWindow() {
        if (loopRunning) {
            loopRunning = false;
            MotionLoop.remove(frameStep);
        }
        super.onDetachedFromWindow();
    }
}
