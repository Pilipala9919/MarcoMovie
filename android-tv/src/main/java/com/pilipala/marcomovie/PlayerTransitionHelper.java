// Copyright (C) 2026 Pilipala
// SPDX-License-Identifier: GPL-3.0-only
package com.pilipala.marcomovie;

import android.animation.Animator;
import android.animation.AnimatorListenerAdapter;
import android.animation.ValueAnimator;
import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.BitmapShader;
import android.graphics.Canvas;
import android.graphics.Paint;
import android.graphics.Rect;
import android.graphics.RectF;
import android.graphics.RuntimeShader;
import android.graphics.Shader;
import android.os.Build;
import android.view.View;
import android.view.ViewGroup;
import android.view.ViewParent;
import android.view.ViewTreeObserver;
import android.widget.FrameLayout;

/**
 * Tiered Detail -> Player and Poster -> Detail transition engine for Android Mobile/Tablet/TV.
 *
 * <ul>
 *   <li>API 33+ Mobile/Tablet: AGSL {@link RuntimeShader} Cinema Portal ({@code 420ms} enter /
 *       {@code 300ms} exit) with physical-pixel {@code uBackdropTexSize} coordinate scaling and
 *       immediate downsampled ({@code <= 1080px}) bitmap disposal.
 *   <li>API 23-32 Mobile/Tablet: Pure hardware {@code RenderNode} view properties ({@code scaleX},
 *       {@code scaleY}, {@code alpha}, {@code translationY}, {@code 320ms}) with {@link
 *       GlassFreezeCallback} hook to freeze {@code GlassworkSurface} resampling during animation.
 *       Strictly zero software Camera+Matrix redraw and zero per-frame heap allocations.
 *   <li>Android TV: Lightweight hardware scale ({@code 1.0 -> 1.08}) + alpha fade ({@code <=
 *       220ms}), strictly zero shader, zero blur, and zero full-screen screenshot capture.
 *   <li>Reduced Motion ({@code Prefs.REDUCED}): {@code 150ms} linear opacity fade.
 * </ul>
 */
public final class PlayerTransitionHelper {
    private PlayerTransitionHelper() {}

    public static final int MAX_BACKDROP_EDGE_PX = 1080;

    /** Resolved execution tier for Detail -> Player transitions. */
    public enum Mode {
        REDUCED_FADE,
        TV_LIGHTWEIGHT,
        API33_AGSL_SHADER,
        API23_HARDWARE_RENDERNODE
    }

    /**
     * Hook invoked around API 23-32 hardware transitions so callers can pause/resume {@code
     * GlassworkSurface} backdrop resampling without frame drops.
     */
    public interface GlassFreezeCallback {
        void setGlassFrozen(boolean frozen);
    }

    /** Idempotent handle for cancelling an in-flight transition cleanly. */
    public interface TransitionHandle {
        void cancel();

        boolean isRunning();
    }

    /**
     * Clean-room AGSL Cinema Portal shader for Android 13+ (API 33+).
     *
     * <p>Note AGSL contract: {@code shader.eval(coord)} receives unnormalized Bitmap physical pixel
     * coordinates {@code [0..bitmapW, 0..bitmapH]}, so normalized UVs are scaled explicitly by
     * {@code uBackdropTexSize} and {@code uPosterTexSize}. Output is strictly premultiplied RGBA.
     */
    public static final String AGSL_PLAYER_ENTER_SOURCE =
            "uniform shader uBackdropTex;\n"
                    + "uniform shader uPosterTex;\n"
                    + "uniform float2 uViewport;\n"
                    + "uniform float2 uBackdropTexSize;\n"
                    + "uniform float2 uPosterTexSize;\n"
                    + "uniform float uProgress;\n"
                    + "uniform float uRecedeTilt;\n"
                    + "uniform float4 uPosterOrigin;\n"
                    + "uniform float4 uSafePadding;\n"
                    + "uniform float uPosterRadius;\n"
                    + "uniform float uPosterAvailable;\n"
                    + "uniform float uPosterAspect;\n"
                    + "half4 main(float2 fragCoord) {\n"
                    + "    float2 viewport = max(uViewport, float2(1.0));\n"
                    + "    float2 p = fragCoord / viewport;\n"
                    + "    float progress = clamp(uProgress, 0.0, 1.0);\n"
                    + "    float scaleBg = mix(1.0, 0.91, smoothstep(0.0, 0.85, progress));\n"
                    + "    float perspDenom = max(0.35, 1.0 - uRecedeTilt * (p.y - 0.5));\n"
                    + "    float perspX = (p.x - 0.5) / perspDenom + 0.5;\n"
                    + "    float2 bgUv = (float2(perspX, p.y) - 0.5) / max(scaleBg, 0.001) + 0.5;\n"
                    + "    float2 fw = float2(1.0) / viewport;\n"
                    + "    float2 edgeAa = smoothstep(-fw, fw, bgUv) * (1.0 - smoothstep(1.0 - fw, 1.0 + fw, bgUv));\n"
                    + "    float inBounds = mix(1.0, edgeAa.x * edgeAa.y, smoothstep(0.0, 0.05, progress));\n"
                    + "    float bgDim = 1.0 - smoothstep(0.10, 0.88, progress);\n"
                    + "    float2 centered = (p - 0.5) * 2.0;\n"
                    + "    float vignette = 1.0 - smoothstep(0.35, 1.35, length(centered)) * (0.55 * progress);\n"
                    + "    float2 bgCoord = clamp(bgUv, float2(0.0), float2(1.0)) * uBackdropTexSize;\n"
                    + "    half4 bgSample = uBackdropTex.eval(bgCoord);\n"
                    + "    float3 bgRgb = float3(bgSample.rgb) * inBounds * bgDim * clamp(vignette, 0.0, 1.0);\n"
                    + "    float2 safeOrigin = uSafePadding.xy;\n"
                    + "    float2 safeSize = max(viewport - uSafePadding.xy - uSafePadding.zw, float2(1.0));\n"
                    + "    float safeAspect = safeSize.x / safeSize.y;\n"
                    + "    float targetAspect = 16.0 / 9.0;\n"
                    + "    float2 targetSize = safeAspect > targetAspect\n"
                    + "        ? float2(safeSize.y * targetAspect, safeSize.y)\n"
                    + "        : float2(safeSize.x, safeSize.x / targetAspect);\n"
                    + "    float2 targetPos = safeOrigin + (safeSize - targetSize) * 0.5;\n"
                    + "    float4 targetRect = float4(targetPos, targetSize);\n"
                    + "    float rectT = smoothstep(0.0, 0.82, progress);\n"
                    + "    float4 curRect = mix(uPosterOrigin, targetRect, rectT);\n"
                    + "    float2 curSize = max(curRect.zw, float2(1.0));\n"
                    + "    float maxRadius = 0.5 * min(curSize.x, curSize.y);\n"
                    + "    float r = clamp(mix(uPosterRadius, 0.0, smoothstep(0.15, 0.75, progress)), 0.0, maxRadius);\n"
                    + "    float2 localUv = (fragCoord - curRect.xy) / curSize;\n"
                    + "    float rectAspect = curSize.x / curSize.y;\n"
                    + "    float safePosterAspect = max(uPosterAspect, 0.0001);\n"
                    + "    float2 coverScale = rectAspect > safePosterAspect\n"
                    + "        ? float2(1.0, safePosterAspect / rectAspect)\n"
                    + "        : float2(rectAspect / safePosterAspect, 1.0);\n"
                    + "    float2 posterUv = clamp((localUv - 0.5) * coverScale + 0.5, float2(0.0), float2(1.0));\n"
                    + "    float posterFade = 1.0 - smoothstep(0.45, 0.80, progress);\n"
                    + "    float hasPoster = step(0.5, uPosterAvailable);\n"
                    + "    float3 posterRgb = float3(0.0);\n"
                    + "    if (uPosterAvailable > 0.5) {\n"
                    + "        half4 ps = uPosterTex.eval(posterUv * uPosterTexSize);\n"
                    + "        posterRgb = float3(ps.rgb) * posterFade;\n"
                    + "    }\n"
                    + "    float2 rectHalf = curSize * 0.5;\n"
                    + "    float2 rectCenter = curRect.xy + rectHalf;\n"
                    + "    float2 q = abs(fragCoord - rectCenter) - rectHalf + float2(r);\n"
                    + "    float sdf = length(max(q, float2(0.0))) + min(max(q.x, q.y), 0.0) - r;\n"
                    + "    float mask = 1.0 - smoothstep(-0.75, 0.75, sdf);\n"
                    + "    float rimBand = (1.0 - smoothstep(0.0, 1.75, abs(sdf)))\n"
                    + "        * sin(3.14159265 * progress)\n"
                    + "        * (1.0 - smoothstep(0.55, 0.85, progress));\n"
                    + "    float3 portalRgb = clamp(posterRgb + float3(0.16, 0.18, 0.22) * rimBand, float3(0.0), float3(1.0));\n"
                    + "    float portalPresence = step(1.0, uPosterOrigin.z) * step(1.0, uPosterOrigin.w) * hasPoster;\n"
                    + "    float effMask = mask * portalPresence;\n"
                    + "    float4 bgPremul = float4(clamp(bgRgb, float3(0.0), float3(1.0)), 1.0);\n"
                    + "    float4 fgPremul = float4(portalRgb * effMask, effMask);\n"
                    + "    float4 composed = fgPremul + bgPremul * (1.0 - fgPremul.a);\n"
                    + "    float handoffAlpha = 1.0 - smoothstep(0.68, 1.0, progress);\n"
                    + "    return half4(half3(composed.rgb * handoffAlpha), half(handoffAlpha));\n"
                    + "}\n";

    /** Resolves the exact transition tier for the current device, API level, and preferences. */
    public static Mode resolveMode(
            int sdkInt,
            boolean isTvDevice,
            boolean reducedMotion,
            boolean agslAvailable,
            boolean hasBackdrop) {
        if (reducedMotion) return Mode.REDUCED_FADE;
        if (isTvDevice) return Mode.TV_LIGHTWEIGHT;
        if (sdkInt >= 33 && agslAvailable && hasBackdrop) return Mode.API33_AGSL_SHADER;
        return Mode.API23_HARDWARE_RENDERNODE;
    }

    /** Resolves transition duration in milliseconds from {@link MotionTokens}. */
    public static int resolveDurationMs(Mode mode, boolean entering) {
        switch (mode) {
            case REDUCED_FADE:
                return MotionTokens.DURATION_FAST_MS;
            case TV_LIGHTWEIGHT:
                return MotionTokens.DURATION_TV_PLAY_EXIT_MS;
            case API33_AGSL_SHADER:
                return entering
                        ? MotionTokens.DURATION_TRANSITION_ENTER_MS
                        : MotionTokens.DURATION_TRANSITION_EXIT_MS;
            case API23_HARDWARE_RENDERNODE:
            default:
                return entering
                        ? MotionTokens.DURATION_EMPHASIZED_MS
                        : MotionTokens.DURATION_TRANSITION_EXIT_MS;
        }
    }

    /** Computes aspect-preserving downsampled capture dimensions capped at {@code maxEdgePx}. */
    public static void computeDownsampleSize(
            int srcWidth, int srcHeight, int maxEdgePx, int[] outWidthHeight) {
        int w = Math.max(1, srcWidth);
        int h = Math.max(1, srcHeight);
        int cap = Math.max(1, maxEdgePx);
        int longest = Math.max(w, h);
        if (longest <= cap) {
            outWidthHeight[0] = w;
            outWidthHeight[1] = h;
            return;
        }
        float scale = (float) cap / (float) longest;
        outWidthHeight[0] = Math.max(1, Math.round(w * scale));
        outWidthHeight[1] = Math.max(1, Math.round(h * scale));
    }

    /** Resolved Cinema Portal parameters passed to the API 33+ AGSL shader. */
    public static final class PortalParams {
        public final float originLeft;
        public final float originTop;
        public final float originWidth;
        public final float originHeight;
        public final float radiusPx;
        public final float posterAvailable;
        public final float posterAspect;
        public final boolean portalActive;

        PortalParams(
                float originLeft,
                float originTop,
                float originWidth,
                float originHeight,
                float radiusPx,
                float posterAvailable,
                float posterAspect,
                boolean portalActive) {
            this.originLeft = originLeft;
            this.originTop = originTop;
            this.originWidth = originWidth;
            this.originHeight = originHeight;
            this.radiusPx = radiusPx;
            this.posterAvailable = posterAvailable;
            this.posterAspect = posterAspect;
            this.portalActive = portalActive;
        }
    }

    /**
     * Returns {@code true} only when {@code candidateRect} describes a bounded local independent
     * poster card inside {@code viewportWidth x viewportHeight} — never a full-bleed backdrop
     * covering the screen (which would occlude titles/buttons on frame 0 if passed as {@code
     * uPosterOrigin}).
     */
    public static boolean isBoundedPosterCardBounds(
            float cardWidth, float cardHeight, float viewportWidth, float viewportHeight) {
        if (viewportWidth <= 1f || viewportHeight <= 1f) {
            return false;
        }
        if (cardWidth <= 1f || cardHeight <= 1f) {
            return false;
        }
        float widthRatio = cardWidth / viewportWidth;
        float heightRatio = cardHeight / viewportHeight;
        float areaRatio = (cardWidth * cardHeight) / (viewportWidth * viewportHeight);
        if (widthRatio >= 0.85f && heightRatio >= 0.60f) {
            return false;
        }
        if (areaRatio >= 0.65f) {
            return false;
        }
        return true;
    }

    public static boolean isBoundedPosterCardRect(
            RectF candidateRect, float viewportWidth, float viewportHeight) {
        if (candidateRect == null) {
            return false;
        }
        return isBoundedPosterCardBounds(
                candidateRect.width(), candidateRect.height(), viewportWidth, viewportHeight);
    }

    /**
     * Normalizes AGSL Cinema Portal uniforms so full-bleed detail pages (or layouts whose poster
     * bitmap is not ready) always resolve to {@code portalActive == false} ({@code uPosterOrigin =
     * (0, 0, 0, 0)}, {@code uPosterAvailable = 0}) and execute depth recession + vignette only.
     */
    public static PortalParams resolvePortalParams(
            RectF candidateOriginPx,
            float candidateRadiusPx,
            float viewportWidth,
            float viewportHeight,
            boolean posterReady,
            int posterBitmapWidth,
            int posterBitmapHeight) {
        if (!posterReady
                || !isBoundedPosterCardRect(candidateOriginPx, viewportWidth, viewportHeight)) {
            return new PortalParams(0f, 0f, 0f, 0f, 0f, 0f, 2f / 3f, false);
        }
        float aspect =
                posterBitmapWidth > 0 && posterBitmapHeight > 0
                        ? (float) posterBitmapWidth / (float) posterBitmapHeight
                        : (2f / 3f);
        return new PortalParams(
                candidateOriginPx.left,
                candidateOriginPx.top,
                candidateOriginPx.width(),
                candidateOriginPx.height(),
                Math.max(0f, candidateRadiusPx),
                1f,
                aspect,
                true);
    }

    /**
     * Computes aspect-preserving {@code BoxFit.cover} UV coordinates inside a portal rectangle,
     * mirroring {@link #AGSL_PLAYER_ENTER_SOURCE}.
     */
    public static void computePosterCoverUv(
            float fragX,
            float fragY,
            float rectLeft,
            float rectTop,
            float rectWidth,
            float rectHeight,
            float posterAspect,
            float[] outUv2) {
        float safeW = Math.max(1f, rectWidth);
        float safeH = Math.max(1f, rectHeight);
        float localU = (fragX - rectLeft) / safeW;
        float localV = (fragY - rectTop) / safeH;
        float rectAspect = safeW / safeH;
        float safePosterAspect = Math.max(posterAspect, 0.0001f);
        float coverScaleX = rectAspect > safePosterAspect ? 1f : (rectAspect / safePosterAspect);
        float coverScaleY = rectAspect > safePosterAspect ? (safePosterAspect / rectAspect) : 1f;
        float u = (localU - 0.5f) * coverScaleX + 0.5f;
        float v = (localV - 0.5f) * coverScaleY + 0.5f;
        outUv2[0] = Math.max(0f, Math.min(1f, u));
        outUv2[1] = Math.max(0f, Math.min(1f, v));
    }

    /** Returns {@code true} if {@code candidate} is a strict descendant of {@code ancestor}. */
    static boolean isDescendantOf(View ancestor, View candidate) {
        if (ancestor == null || candidate == null || ancestor == candidate) {
            return false;
        }
        ViewParent p = candidate.getParent();
        while (p instanceof View) {
            if (p == ancestor) {
                return true;
            }
            p = p.getParent();
        }
        return false;
    }

    /**
     * Determines whether {@code detailLayer} may safely use {@code LAYER_TYPE_HARDWARE}: never
     * promote an ancestor whose descendant {@code posterView} is scaled/transformed per frame, as
     * doing so invalidates and rebuilds the parent's full-screen hardware FBO every single frame.
     */
    static boolean shouldPromoteDetailHardwareLayer(View detailLayer, View posterView) {
        if (detailLayer == null) return false;
        if (posterView == null || posterView == detailLayer) return true;
        return !isDescendantOf(detailLayer, posterView);
    }

    static boolean shouldPromotePosterHardwareLayer(View detailLayer, View posterView) {
        if (posterView == null || posterView == detailLayer) return false;
        if (detailLayer != null && isDescendantOf(posterView, detailLayer)) return false;
        return true;
    }

    /** Computes centered 16:9 cinema target rectangle inside safe insets into {@code outRect4}. */
    public static void computePortalTargetRect(
            float viewWidth,
            float viewHeight,
            float padLeft,
            float padTop,
            float padRight,
            float padBottom,
            float[] outRect4) {
        float safeW = Math.max(1f, viewWidth - padLeft - padRight);
        float safeH = Math.max(1f, viewHeight - padTop - padBottom);
        float targetAspect = 16f / 9f;
        float tw;
        float th;
        if (safeW / safeH > targetAspect) {
            th = safeH;
            tw = safeH * targetAspect;
        } else {
            tw = safeW;
            th = safeW / targetAspect;
        }
        outRect4[0] = padLeft + (safeW - tw) * 0.5f;
        outRect4[1] = padTop + (safeH - th) * 0.5f;
        outRect4[2] = tw;
        outRect4[3] = th;
    }

    /**
     * Captures a downsampled snapshot ({@code <= 1080px} longest edge) of a view for API 33+ AGSL
     * mobile transitions. Never invoked on TV or reduced motion.
     */
    public static Bitmap captureDownsampledBackdrop(View sourceView) {
        if (sourceView == null) return null;
        int w = sourceView.getWidth();
        int h = sourceView.getHeight();
        if (w <= 0 || h <= 0) return null;
        int[] dims = new int[2];
        computeDownsampleSize(w, h, MAX_BACKDROP_EDGE_PX, dims);
        Bitmap bitmap = null;
        try {
            bitmap = Bitmap.createBitmap(dims[0], dims[1], Bitmap.Config.ARGB_8888);
            Canvas canvas = new Canvas(bitmap);
            canvas.scale((float) dims[0] / (float) w, (float) dims[1] / (float) h);
            sourceView.draw(canvas);
            return bitmap;
        } catch (Throwable ignored) {
            if (bitmap != null && !bitmap.isRecycled()) bitmap.recycle();
            return null;
        }
    }

    /**
     * Pure-Java projection of shared-bounds start transforms from {@code originRectInRoot} onto a
     * target poster rectangle already expressed in {@code detailRoot} coordinate space.
     *
     * @param outScaleXYTranslateXY 4-element buffer receiving {@code [startScaleX, startScaleY,
     *     startDx, startDy]}.
     */
    public static void computeSharedBoundsDeltas(
            float originLeft,
            float originTop,
            float originRight,
            float originBottom,
            float targetLeftInRoot,
            float targetTopInRoot,
            float targetWidth,
            float targetHeight,
            float[] outScaleXYTranslateXY) {
        float safeTargetW = Math.max(1f, targetWidth);
        float safeTargetH = Math.max(1f, targetHeight);
        float originW = Math.max(1f, originRight - originLeft);
        float originH = Math.max(1f, originBottom - originTop);
        float originCx = (originLeft + originRight) * 0.5f;
        float originCy = (originTop + originBottom) * 0.5f;
        float targetCx = targetLeftInRoot + safeTargetW * 0.5f;
        float targetCy = targetTopInRoot + safeTargetH * 0.5f;
        outScaleXYTranslateXY[0] = Math.max(0.2f, originW / safeTargetW);
        outScaleXYTranslateXY[1] = Math.max(0.2f, originH / safeTargetH);
        outScaleXYTranslateXY[2] = originCx - targetCx;
        outScaleXYTranslateXY[3] = originCy - targetCy;
    }

    /** Resolves {@code descendant}'s bounding rectangle in {@code detailRoot}'s coordinate space. */
    static void resolveDescendantRectInRoot(View detailRoot, View descendant, Rect outRect) {
        int w = descendant.getWidth();
        int h = descendant.getHeight();
        outRect.set(0, 0, w, h);
        if (detailRoot == null || detailRoot == descendant) {
            return;
        }
        if (detailRoot instanceof ViewGroup) {
            try {
                ((ViewGroup) detailRoot).offsetDescendantRectToMyCoords(descendant, outRect);
                return;
            } catch (IllegalArgumentException ignored) {
                // Fall back to explicit parent walk if hierarchy is detached/transitional.
            }
        }
        int offsetX = 0;
        int offsetY = 0;
        View cur = descendant;
        while (cur != null && cur != detailRoot) {
            offsetX += cur.getLeft();
            offsetY += cur.getTop();
            ViewParent p = cur.getParent();
            if (p instanceof View) {
                View pv = (View) p;
                offsetX -= pv.getScrollX();
                offsetY -= pv.getScrollY();
                cur = pv;
            } else {
                break;
            }
        }
        outRect.set(offsetX, offsetY, offsetX + w, offsetY + h);
    }

    /**
     * Runs the Poster -> Detail shared-bounds entry animation ({@code 280ms} decelerate curve, or
     * {@code 150ms} linear fade under {@code reducedMotion}). Projects {@code heroPosterView} into
     * {@code detailRoot} coordinate space and defers cleanly via a cancellable one-shot {@link
     * ViewTreeObserver.OnPreDrawListener} when invoked before first layout.
     */
    public static TransitionHandle animateSharedBoundsEnter(
            final View detailRoot,
            final View heroPosterView,
            final Rect originRectInRoot,
            boolean reducedMotion,
            final Runnable onComplete) {
        if (detailRoot == null) {
            if (onComplete != null) onComplete.run();
            return NO_OP_HANDLE;
        }
        if (reducedMotion || originRectInRoot == null || heroPosterView == null) {
            return runSimpleAlphaFade(
                    detailRoot, 0f, 1f, MotionTokens.DURATION_FAST_MS, true, false, onComplete);
        }
        if (heroPosterView.getWidth() > 0 && heroPosterView.getHeight() > 0) {
            return launchSharedBoundsAnimator(
                    detailRoot, heroPosterView, originRectInRoot, onComplete);
        }
        // Pre-layout frame-0 path: hide root immediately and start 280ms shared-bounds on pre-draw.
        detailRoot.setAlpha(0f);
        return new DeferredSharedBoundsHandle(
                detailRoot, heroPosterView, new Rect(originRectInRoot), onComplete);
    }

    private static TransitionHandle launchSharedBoundsAnimator(
            final View detailRoot,
            final View heroPosterView,
            Rect originRectInRoot,
            final Runnable onComplete) {
        final int targetW = heroPosterView.getWidth();
        final int targetH = heroPosterView.getHeight();
        if (targetW <= 0 || targetH <= 0) {
            return runSimpleAlphaFade(
                    detailRoot, 0f, 1f, MotionTokens.DURATION_FAST_MS, true, false, onComplete);
        }
        Rect targetInRoot = new Rect();
        resolveDescendantRectInRoot(detailRoot, heroPosterView, targetInRoot);
        float[] deltas = new float[4];
        computeSharedBoundsDeltas(
                originRectInRoot.left,
                originRectInRoot.top,
                originRectInRoot.right,
                originRectInRoot.bottom,
                targetInRoot.left,
                targetInRoot.top,
                targetW,
                targetH,
                deltas);
        final float startScaleX = deltas[0];
        final float startScaleY = deltas[1];
        final float startDx = deltas[2];
        final float startDy = deltas[3];

        detailRoot.setAlpha(0f);
        heroPosterView.setPivotX(targetW * 0.5f);
        heroPosterView.setPivotY(targetH * 0.5f);
        heroPosterView.setScaleX(startScaleX);
        heroPosterView.setScaleY(startScaleY);
        heroPosterView.setTranslationX(startDx);
        heroPosterView.setTranslationY(startDy);

        final ValueAnimator animator = ValueAnimator.ofFloat(0f, 1f);
        animator.setDuration(MotionTokens.DURATION_MOBILE_SHARED_BOUNDS_MS);
        animator.setInterpolator(MotionTokens.createDecelerateInterpolator());
        final AtomicFinish finish =
                new AtomicFinish(
                        animator,
                        () -> {
                            detailRoot.setAlpha(1f);
                            heroPosterView.setScaleX(1f);
                            heroPosterView.setScaleY(1f);
                            heroPosterView.setTranslationX(0f);
                            heroPosterView.setTranslationY(0f);
                            if (onComplete != null) onComplete.run();
                        });
        animator.addUpdateListener(
                anim -> {
                    float t = (Float) anim.getAnimatedValue();
                    float inv = 1f - t;
                    detailRoot.setAlpha(t);
                    heroPosterView.setScaleX(startScaleX + (1f - startScaleX) * t);
                    heroPosterView.setScaleY(startScaleY + (1f - startScaleY) * t);
                    heroPosterView.setTranslationX(startDx * inv);
                    heroPosterView.setTranslationY(startDy * inv);
                });
        animator.addListener(
                new AnimatorListenerAdapter() {
                    @Override
                    public void onAnimationEnd(Animator animation) {
                        finish.runOnce();
                    }

                    @Override
                    public void onAnimationCancel(Animator animation) {
                        finish.runOnce();
                    }
                });
        final AnimatorHandle handle = new AnimatorHandle(animator, finish);
        finish.bindDetachCancel(detailRoot, handle);
        try {
            animator.start();
        } catch (RuntimeException error) {
            finish.runOnce();
            throw error;
        }
        return handle;
    }

    /** Lightweight Android TV page transition ({@code 180ms} pure alpha, zero shader/blur). */
    public static TransitionHandle animateTvPageFade(
            View targetView, boolean fadeIn, boolean reducedMotion, Runnable onComplete) {
        int duration =
                reducedMotion
                        ? MotionTokens.DURATION_FAST_MS
                        : MotionTokens.DURATION_TV_PAGE_FADE_MS;
        return runSimpleAlphaFade(
                targetView,
                fadeIn ? 0f : 1f,
                fadeIn ? 1f : 0f,
                duration,
                reducedMotion,
                false,
                onComplete);
    }

    /**
     * Runs the tiered Detail -> Player enter transition according to platform capability:
     *
     * <ol>
     *   <li>{@code reducedMotion}: {@code 150ms} linear crossfade.
     *   <li>{@code isTvDevice}: {@code 220ms} lightweight hardware scale ({@code 1.0 -> 1.08}) +
     *       fade (ZERO blur/shader/screenshot).
     *   <li>API 33+ Mobile/Tablet: {@code 420ms} AGSL Cinema Portal overlay (hides {@code
     *       detailLayer} under overlay and recycles owned backdrop on completion/cancel).
     *   <li>API 23-32 Mobile/Tablet (or AGSL fallback): {@code 320ms} hardware {@code RenderNode}
     *       scale/alpha/translationY with {@link GlassFreezeCallback} freeze/unfreeze and zero
     *       per-frame allocations.
     * </ol>
     *
     * <p>All 4 modes enforce the identical completion/cancel post-condition: {@code onComplete}
     * executes first (allowing callers to hide/detach {@code detailLayer} in the same frame), then
     * {@code finally} restores {@code detailLayer} and {@code posterView} transforms/alpha/layers
     * cleanly so returning to detail never renders an invisible view.
     */
    public static TransitionHandle startDetailToPlayerTransition(
            ViewGroup overlayHost,
            View detailLayer,
            View posterView,
            Bitmap optionalBackdrop,
            boolean ownsBackdrop,
            Bitmap optionalPosterBitmap,
            RectF posterOriginPx,
            float posterRadiusPx,
            Rect safeInsetsPx,
            boolean isTvDevice,
            boolean reducedMotion,
            GlassFreezeCallback glassFreezeCallback,
            Runnable onComplete) {
        boolean agslReady = Build.VERSION.SDK_INT >= 33 && !isTvDevice && !reducedMotion;
        Bitmap backdrop = optionalBackdrop;
        boolean recycleBackdrop = ownsBackdrop;
        if (agslReady && backdrop == null && detailLayer != null) {
            backdrop = captureDownsampledBackdrop(detailLayer);
            recycleBackdrop = backdrop != null;
        }
        Mode mode =
                resolveMode(
                        Build.VERSION.SDK_INT,
                        isTvDevice,
                        reducedMotion,
                        agslReady,
                        backdrop != null && !backdrop.isRecycled());

        if (mode == Mode.API33_AGSL_SHADER && overlayHost != null && Build.VERSION.SDK_INT >= 33) {
            TransitionHandle handle =
                    Api33AgslRunner.start(
                            overlayHost,
                            detailLayer,
                            backdrop,
                            recycleBackdrop,
                            optionalPosterBitmap,
                            posterOriginPx,
                            posterRadiusPx,
                            safeInsetsPx,
                            onComplete);
            if (handle != null) {
                return handle;
            }
            // Fall through cleanly to hardware RenderNode if AGSL compilation failed on device.
            if (recycleBackdrop && backdrop != null && !backdrop.isRecycled()) {
                backdrop.recycle();
            }
            mode = Mode.API23_HARDWARE_RENDERNODE;
        } else if (recycleBackdrop && backdrop != null && !backdrop.isRecycled()) {
            backdrop.recycle();
        }

        if (mode == Mode.REDUCED_FADE) {
            return runSimpleAlphaFade(
                    detailLayer, 1f, 0f, MotionTokens.DURATION_FAST_MS, true, true, onComplete);
        }

        if (mode == Mode.TV_LIGHTWEIGHT) {
            return runTvLightweightExit(detailLayer, posterView, onComplete);
        }

        return runApi23HardwareRenderNodeTransition(
                detailLayer, posterView, glassFreezeCallback, onComplete);
    }

    private static TransitionHandle runSimpleAlphaFade(
            final View target,
            final float startAlpha,
            final float endAlpha,
            int durationMs,
            boolean linear,
            final boolean restoreAlphaAfterComplete,
            final Runnable onComplete) {
        if (target == null || durationMs <= 0) {
            try {
                if (target != null) target.setAlpha(endAlpha);
                if (onComplete != null) onComplete.run();
            } finally {
                if (target != null && restoreAlphaAfterComplete) {
                    target.setAlpha(1f);
                }
            }
            return NO_OP_HANDLE;
        }
        target.setAlpha(startAlpha);
        final ValueAnimator animator = ValueAnimator.ofFloat(startAlpha, endAlpha);
        animator.setDuration(durationMs);
        animator.setInterpolator(
                linear
                        ? MotionTokens.createLinearInterpolator()
                        : MotionTokens.createDecelerateInterpolator());
        final AtomicFinish finish =
                new AtomicFinish(
                        animator,
                        () -> {
                            try {
                                target.setAlpha(endAlpha);
                                if (onComplete != null) onComplete.run();
                            } finally {
                                if (restoreAlphaAfterComplete) {
                                    target.setAlpha(1f);
                                }
                            }
                        });
        animator.addUpdateListener(anim -> target.setAlpha((Float) anim.getAnimatedValue()));
        animator.addListener(
                new AnimatorListenerAdapter() {
                    @Override
                    public void onAnimationEnd(Animator animation) {
                        finish.runOnce();
                    }

                    @Override
                    public void onAnimationCancel(Animator animation) {
                        finish.runOnce();
                    }
                });
        final AnimatorHandle handle = new AnimatorHandle(animator, finish);
        finish.bindDetachCancel(target, handle);
        try {
            animator.start();
        } catch (RuntimeException error) {
            finish.runOnce();
            throw error;
        }
        return handle;
    }

    /**
     * API 23 (Android 6.0.1) low-RAM TV GPUs (e.g., Mali-450 on MiTV OS 1.3.130) can hit
     * {@code EGL_OUT_OF_MEMORY} or RenderThread crashes when promoting full-screen detail layers
     * to offscreen {@code LAYER_TYPE_HARDWARE} FBOs right before video surface allocation.
     */
    static boolean shouldUseTvHardwareExitLayer(int sdkInt) {
        return sdkInt > 23;
    }

    /**
     * Android TV lightweight exit ({@code 220ms}): poster scales {@code 1.0 -> 1.08} while fading
     * smoothly into pure black player layer. Zero blur, zero shader, zero screenshot.
     */
    static TransitionHandle runTvLightweightExit(
            final View detailLayer, final View posterView, final Runnable onComplete) {
        if (detailLayer == null && posterView == null) {
            if (onComplete != null) onComplete.run();
            return NO_OP_HANDLE;
        }
        final boolean animatePoster = posterView != null && posterView != detailLayer;
        final boolean allowHwExitLayer = shouldUseTvHardwareExitLayer(Build.VERSION.SDK_INT);
        final boolean promoteDetailLayer =
                allowHwExitLayer
                        && shouldPromoteDetailHardwareLayer(
                                detailLayer, animatePoster ? posterView : null);
        final boolean promotePosterLayer =
                allowHwExitLayer
                        && shouldPromotePosterHardwareLayer(
                                detailLayer, animatePoster ? posterView : null);
        final int prevDetailLayer =
                detailLayer != null ? detailLayer.getLayerType() : View.LAYER_TYPE_NONE;
        final int prevPosterLayer =
                animatePoster ? posterView.getLayerType() : View.LAYER_TYPE_NONE;
        if (promoteDetailLayer) detailLayer.setLayerType(View.LAYER_TYPE_HARDWARE, null);
        if (promotePosterLayer) posterView.setLayerType(View.LAYER_TYPE_HARDWARE, null);

        final ValueAnimator animator = ValueAnimator.ofFloat(0f, 1f);
        animator.setDuration(MotionTokens.DURATION_TV_PLAY_EXIT_MS);
        animator.setInterpolator(MotionTokens.createDecelerateInterpolator());
        final AtomicFinish finish =
                new AtomicFinish(
                        animator,
                        () -> {
                            try {
                                if (onComplete != null) onComplete.run();
                            } finally {
                                if (detailLayer != null) {
                                    if (promoteDetailLayer) {
                                        detailLayer.setLayerType(prevDetailLayer, null);
                                    }
                                    detailLayer.setScaleX(1f);
                                    detailLayer.setScaleY(1f);
                                    detailLayer.setTranslationY(0f);
                                    detailLayer.setAlpha(1f);
                                }
                                if (animatePoster) {
                                    if (promotePosterLayer) {
                                        posterView.setLayerType(prevPosterLayer, null);
                                    }
                                    posterView.setScaleX(1f);
                                    posterView.setScaleY(1f);
                                    posterView.setAlpha(1f);
                                }
                            }
                        });
        animator.addUpdateListener(
                anim -> {
                    float t = (Float) anim.getAnimatedValue();
                    if (detailLayer != null) {
                        detailLayer.setAlpha(1f - t);
                    }
                    if (animatePoster) {
                        float s = 1f + 0.08f * t;
                        posterView.setScaleX(s);
                        posterView.setScaleY(s);
                    }
                });
        animator.addListener(
                new AnimatorListenerAdapter() {
                    @Override
                    public void onAnimationEnd(Animator animation) {
                        finish.runOnce();
                    }

                    @Override
                    public void onAnimationCancel(Animator animation) {
                        finish.runOnce();
                    }
                });
        final AnimatorHandle handle = new AnimatorHandle(animator, finish);
        finish.bindDetachCancel(detailLayer != null ? detailLayer : posterView, handle);
        try {
            animator.start();
        } catch (RuntimeException error) {
            finish.runOnce();
            throw error;
        }
        return handle;
    }

    /**
     * API 23-32 mobile/tablet transition using pure hardware {@code RenderNode} view properties
     * ({@code scaleX}, {@code scaleY}, {@code alpha}, {@code translationY}) and {@link
     * GlassFreezeCallback} freeze/unfreeze — zero software Camera+Matrix and zero allocations per
     * frame.
     */
    static TransitionHandle runApi23HardwareRenderNodeTransition(
            final View detailLayer,
            final View posterView,
            final GlassFreezeCallback glassFreezeCallback,
            final Runnable onComplete) {
        if (detailLayer == null && posterView == null) {
            if (onComplete != null) onComplete.run();
            return NO_OP_HANDLE;
        }
        final float density =
                detailLayer != null
                        ? detailLayer.getResources().getDisplayMetrics().density
                        : posterView.getResources().getDisplayMetrics().density;
        final float maxTranslateY = 18f * density;
        final boolean animatePoster = posterView != null && posterView != detailLayer;
        final boolean promoteDetailLayer =
                shouldPromoteDetailHardwareLayer(detailLayer, animatePoster ? posterView : null);
        final boolean promotePosterLayer =
                shouldPromotePosterHardwareLayer(detailLayer, animatePoster ? posterView : null);
        final int prevDetailLayer =
                detailLayer != null ? detailLayer.getLayerType() : View.LAYER_TYPE_NONE;
        final int prevPosterLayer =
                animatePoster ? posterView.getLayerType() : View.LAYER_TYPE_NONE;

        if (glassFreezeCallback != null) {
            glassFreezeCallback.setGlassFrozen(true);
        }
        if (promoteDetailLayer) detailLayer.setLayerType(View.LAYER_TYPE_HARDWARE, null);
        if (promotePosterLayer) posterView.setLayerType(View.LAYER_TYPE_HARDWARE, null);

        final ValueAnimator animator = ValueAnimator.ofFloat(0f, 1f);
        animator.setDuration(MotionTokens.DURATION_EMPHASIZED_MS);
        animator.setInterpolator(MotionTokens.createStandardInterpolator());
        final AtomicFinish finish =
                new AtomicFinish(
                        animator,
                        () -> {
                            try {
                                if (onComplete != null) onComplete.run();
                            } finally {
                                try {
                                    if (detailLayer != null) {
                                        if (promoteDetailLayer) {
                                            detailLayer.setLayerType(prevDetailLayer, null);
                                        }
                                        detailLayer.setScaleX(1f);
                                        detailLayer.setScaleY(1f);
                                        detailLayer.setTranslationY(0f);
                                        detailLayer.setAlpha(1f);
                                    }
                                    if (animatePoster) {
                                        if (promotePosterLayer) {
                                            posterView.setLayerType(prevPosterLayer, null);
                                        }
                                        posterView.setScaleX(1f);
                                        posterView.setScaleY(1f);
                                        posterView.setAlpha(1f);
                                    }
                                } finally {
                                    if (glassFreezeCallback != null) {
                                        glassFreezeCallback.setGlassFrozen(false);
                                    }
                                }
                            }
                        });
        animator.addUpdateListener(
                anim -> {
                    float t = (Float) anim.getAnimatedValue();
                    if (detailLayer != null) {
                        float bgScale = 1f - 0.08f * t;
                        detailLayer.setScaleX(bgScale);
                        detailLayer.setScaleY(bgScale);
                        detailLayer.setTranslationY(maxTranslateY * t);
                        detailLayer.setAlpha(1f - t);
                    }
                    if (animatePoster) {
                        float posterScale = 1f + 0.10f * t;
                        posterView.setScaleX(posterScale);
                        posterView.setScaleY(posterScale);
                        float posterAlpha = t < 0.45f ? 1f : Math.max(0f, 1f - (t - 0.45f) / 0.40f);
                        posterView.setAlpha(posterAlpha);
                    }
                });
        animator.addListener(
                new AnimatorListenerAdapter() {
                    @Override
                    public void onAnimationEnd(Animator animation) {
                        finish.runOnce();
                    }

                    @Override
                    public void onAnimationCancel(Animator animation) {
                        finish.runOnce();
                    }
                });
        final AnimatorHandle handle = new AnimatorHandle(animator, finish);
        finish.bindDetachCancel(detailLayer != null ? detailLayer : posterView, handle);
        try {
            animator.start();
        } catch (RuntimeException error) {
            finish.runOnce();
            throw error;
        }
        return handle;
    }

    /** Isolated API 33+ AGSL runner so Dalvik/ART on API 23-32 never resolves RuntimeShader. */
    private static final class Api33AgslRunner {
        static TransitionHandle start(
                final ViewGroup overlayHost,
                final View detailLayer,
                final Bitmap backdrop,
                final boolean ownsBackdrop,
                final Bitmap poster,
                final RectF posterOriginPx,
                final float posterRadiusPx,
                final Rect safeInsetsPx,
                final Runnable onComplete) {
            final Api33AgslOverlay overlay;
            try {
                overlay =
                        new Api33AgslOverlay(
                                overlayHost.getContext(),
                                backdrop,
                                poster,
                                posterOriginPx,
                                posterRadiusPx,
                                safeInsetsPx);
            } catch (Throwable ignored) {
                return null;
            }

            overlayHost.addView(overlay, new FrameLayout.LayoutParams(-1, -1));
            // Hide live detailLayer immediately after backdrop capture + overlay attach so the
            // 0.68 -> 1.0 shader dissolve reveals the underlying video surface with zero flash.
            if (detailLayer != null) {
                detailLayer.setAlpha(0f);
            }
            final ValueAnimator animator = ValueAnimator.ofFloat(0f, 1f);
            animator.setDuration(MotionTokens.DURATION_TRANSITION_ENTER_MS);
            // Match Flutter player_enter.frag linear uProgress driver (shader owns smoothstep).
            animator.setInterpolator(MotionTokens.createLinearInterpolator());
            final AtomicFinish finish =
                    new AtomicFinish(
                            animator,
                            () -> {
                                try {
                                    if (onComplete != null) onComplete.run();
                                } finally {
                                    try {
                                        if (overlay.getParent() instanceof ViewGroup) {
                                            ((ViewGroup) overlay.getParent()).removeView(overlay);
                                        }
                                        overlay.release(ownsBackdrop);
                                    } finally {
                                        if (detailLayer != null) {
                                            detailLayer.setScaleX(1f);
                                            detailLayer.setScaleY(1f);
                                            detailLayer.setTranslationY(0f);
                                            detailLayer.setAlpha(1f);
                                        }
                                    }
                                }
                            });
            animator.addUpdateListener(
                    anim -> {
                        overlay.setProgress((Float) anim.getAnimatedValue());
                    });
            animator.addListener(
                    new AnimatorListenerAdapter() {
                        @Override
                        public void onAnimationEnd(Animator animation) {
                            finish.runOnce();
                        }

                        @Override
                        public void onAnimationCancel(Animator animation) {
                            finish.runOnce();
                        }
                    });
            final AnimatorHandle handle = new AnimatorHandle(animator, finish);
            overlay.setOnDetachCancel(handle::cancel);
            try {
                animator.start();
            } catch (RuntimeException error) {
                finish.runOnce();
                throw error;
            }
            return handle;
        }
    }

    private static final class Api33AgslOverlay extends View {
        private final RuntimeShader shader;
        private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final Bitmap backdropBitmap;
        private final Bitmap placeholderPoster;
        private final RectF candidatePosterOrigin;
        private final float candidatePosterRadius;
        private final boolean hasPosterBitmap;
        private final int posterBitmapWidth;
        private final int posterBitmapHeight;
        private final float padLeft;
        private final float padTop;
        private final float padRight;
        private final float padBottom;
        private int cachedViewportW = -1;
        private int cachedViewportH = -1;
        private PortalParams cachedPortal;
        private float progress;
        private boolean released;
        private Runnable onDetachCancel;

        Api33AgslOverlay(
                Context context,
                Bitmap backdrop,
                Bitmap poster,
                RectF posterOriginPx,
                float posterRadiusPx,
                Rect safeInsetsPx) {
            super(context);
            setClickable(false);
            setFocusable(false);
            this.backdropBitmap = backdrop;
            this.shader = new RuntimeShader(AGSL_PLAYER_ENTER_SOURCE);

            BitmapShader backdropShader =
                    new BitmapShader(backdrop, Shader.TileMode.CLAMP, Shader.TileMode.CLAMP);
            shader.setInputShader("uBackdropTex", backdropShader);
            shader.setFloatUniform(
                    "uBackdropTexSize", (float) backdrop.getWidth(), (float) backdrop.getHeight());

            this.hasPosterBitmap = poster != null && !poster.isRecycled();
            Bitmap boundPoster;
            if (this.hasPosterBitmap) {
                boundPoster = poster;
                this.placeholderPoster = null;
            } else {
                this.placeholderPoster = Bitmap.createBitmap(1, 1, Bitmap.Config.ARGB_8888);
                boundPoster = this.placeholderPoster;
            }
            this.posterBitmapWidth = boundPoster.getWidth();
            this.posterBitmapHeight = boundPoster.getHeight();
            BitmapShader posterShader =
                    new BitmapShader(boundPoster, Shader.TileMode.CLAMP, Shader.TileMode.CLAMP);
            shader.setInputShader("uPosterTex", posterShader);
            shader.setFloatUniform(
                    "uPosterTexSize",
                    (float) this.posterBitmapWidth,
                    (float) this.posterBitmapHeight);

            this.candidatePosterOrigin = posterOriginPx != null ? new RectF(posterOriginPx) : null;
            this.candidatePosterRadius = Math.max(0f, posterRadiusPx);
            this.padLeft = safeInsetsPx != null ? Math.max(0, safeInsetsPx.left) : 0f;
            this.padTop = safeInsetsPx != null ? Math.max(0, safeInsetsPx.top) : 0f;
            this.padRight = safeInsetsPx != null ? Math.max(0, safeInsetsPx.right) : 0f;
            this.padBottom = safeInsetsPx != null ? Math.max(0, safeInsetsPx.bottom) : 0f;

            paint.setShader(shader);
        }

        void setOnDetachCancel(Runnable action) {
            onDetachCancel = action;
        }

        void setProgress(float next) {
            progress = Math.max(0f, Math.min(1f, next));
            invalidate();
        }

        void release(boolean recycleBackdrop) {
            if (released) return;
            released = true;
            onDetachCancel = null;
            paint.setShader(null);
            if (placeholderPoster != null && !placeholderPoster.isRecycled()) {
                placeholderPoster.recycle();
            }
            if (recycleBackdrop && backdropBitmap != null && !backdropBitmap.isRecycled()) {
                backdropBitmap.recycle();
            }
        }

        @Override
        protected void onDetachedFromWindow() {
            Runnable cancel = onDetachCancel;
            if (cancel != null && !released) {
                cancel.run();
            }
            super.onDetachedFromWindow();
        }

        @Override
        protected void onDraw(Canvas canvas) {
            if (released) return;
            int w = getWidth();
            int h = getHeight();
            if (w <= 0 || h <= 0) return;
            if (cachedPortal == null || w != cachedViewportW || h != cachedViewportH) {
                cachedViewportW = w;
                cachedViewportH = h;
                cachedPortal =
                        resolvePortalParams(
                                candidatePosterOrigin,
                                candidatePosterRadius,
                                (float) w,
                                (float) h,
                                hasPosterBitmap,
                                posterBitmapWidth,
                                posterBitmapHeight);
            }
            PortalParams portal = cachedPortal;
            float tilt = (float) (0.10 * Math.sin(Math.PI * progress));
            shader.setFloatUniform("uViewport", (float) w, (float) h);
            shader.setFloatUniform("uProgress", progress);
            shader.setFloatUniform("uRecedeTilt", tilt);
            shader.setFloatUniform(
                    "uPosterOrigin",
                    portal.originLeft,
                    portal.originTop,
                    portal.originWidth,
                    portal.originHeight);
            shader.setFloatUniform("uSafePadding", padLeft, padTop, padRight, padBottom);
            shader.setFloatUniform("uPosterRadius", portal.radiusPx);
            shader.setFloatUniform("uPosterAvailable", portal.posterAvailable);
            shader.setFloatUniform("uPosterAspect", portal.posterAspect);
            canvas.drawRect(0f, 0f, (float) w, (float) h, paint);
        }
    }

    private static final class DeferredSharedBoundsHandle
            implements TransitionHandle,
                    ViewTreeObserver.OnPreDrawListener,
                    View.OnAttachStateChangeListener {
        private final View detailRoot;
        private final View heroPosterView;
        private final Rect originRectInRoot;
        private final Runnable onComplete;
        private ViewTreeObserver observedTree;
        private TransitionHandle activeHandle;
        private boolean finished;

        DeferredSharedBoundsHandle(
                View detailRoot, View heroPosterView, Rect originRectInRoot, Runnable onComplete) {
            this.detailRoot = detailRoot;
            this.heroPosterView = heroPosterView;
            this.originRectInRoot = originRectInRoot;
            this.onComplete = onComplete;
            this.observedTree = detailRoot.getViewTreeObserver();
            if (this.observedTree != null && this.observedTree.isAlive()) {
                this.observedTree.addOnPreDrawListener(this);
                detailRoot.addOnAttachStateChangeListener(this);
            } else {
                this.finished = true;
                detailRoot.setAlpha(1f);
                if (onComplete != null) onComplete.run();
            }
        }

        private void detachListeners() {
            ViewTreeObserver vto = observedTree;
            observedTree = null;
            if (vto != null && vto.isAlive()) {
                vto.removeOnPreDrawListener(this);
            } else {
                ViewTreeObserver current = detailRoot.getViewTreeObserver();
                if (current != null && current.isAlive()) {
                    current.removeOnPreDrawListener(this);
                }
            }
            detailRoot.removeOnAttachStateChangeListener(this);
        }

        @Override
        public boolean onPreDraw() {
            detachListeners();
            if (finished) return true;
            finished = true;
            activeHandle =
                    launchSharedBoundsAnimator(
                            detailRoot, heroPosterView, originRectInRoot, onComplete);
            return true;
        }

        @Override
        public void onViewAttachedToWindow(View v) {}

        @Override
        public void onViewDetachedFromWindow(View v) {
            cancel();
        }

        @Override
        public void cancel() {
            detachListeners();
            TransitionHandle handle = activeHandle;
            if (handle != null) {
                handle.cancel();
                return;
            }
            if (!finished) {
                finished = true;
                detailRoot.setAlpha(1f);
                if (onComplete != null) onComplete.run();
            }
        }

        @Override
        public boolean isRunning() {
            if (activeHandle != null) return activeHandle.isRunning();
            return !finished;
        }
    }

    private static final class AtomicFinish {
        private final ValueAnimator animator;
        private final Runnable action;
        private View detachWatchView;
        private View.OnAttachStateChangeListener detachListener;
        private boolean done;

        AtomicFinish(ValueAnimator animator, Runnable action) {
            this.animator = animator;
            this.action = action;
        }

        void bindDetachCancel(View watchView, final TransitionHandle handle) {
            if (watchView == null || handle == null || done) return;
            detachWatchView = watchView;
            detachListener =
                    new View.OnAttachStateChangeListener() {
                        @Override
                        public void onViewAttachedToWindow(View v) {}

                        @Override
                        public void onViewDetachedFromWindow(View v) {
                            handle.cancel();
                        }
                    };
            watchView.addOnAttachStateChangeListener(detachListener);
        }

        void runOnce() {
            if (done) return;
            done = true;
            try {
                action.run();
            } finally {
                if (detachWatchView != null && detachListener != null) {
                    detachWatchView.removeOnAttachStateChangeListener(detachListener);
                    detachWatchView = null;
                    detachListener = null;
                }
                if (animator != null) {
                    animator.removeAllUpdateListeners();
                    animator.removeAllListeners();
                }
            }
        }
    }

    private static final class AnimatorHandle implements TransitionHandle {
        private final ValueAnimator animator;
        private final AtomicFinish finish;

        AnimatorHandle(ValueAnimator animator, AtomicFinish finish) {
            this.animator = animator;
            this.finish = finish;
        }

        @Override
        public void cancel() {
            if (animator.isStarted() || animator.isRunning()) {
                animator.cancel();
            }
            finish.runOnce();
        }

        @Override
        public boolean isRunning() {
            return animator.isRunning();
        }
    }

    private static final TransitionHandle NO_OP_HANDLE =
            new TransitionHandle() {
                @Override
                public void cancel() {}

                @Override
                public boolean isRunning() {
                    return false;
                }
            };
}
