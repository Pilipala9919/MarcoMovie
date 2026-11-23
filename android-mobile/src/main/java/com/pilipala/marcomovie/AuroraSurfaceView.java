// Copyright (C) 2026 Pilipala
// SPDX-License-Identifier: GPL-3.0-only
package com.pilipala.marcomovie;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.LinearGradient;
import android.graphics.Matrix;
import android.graphics.Paint;
import android.graphics.RuntimeShader;
import android.graphics.Shader;
import android.os.Build;
import android.view.View;

/**
 * Standalone four-tone flowing aurora backdrop ({@code Marco Aurora}) for onboarding, about, and
 * empty states (never run during video playback or on Android TV).
 *
 * <ul>
 *   <li>API 33+: Runs clean-room AGSL {@link RuntimeShader} matching {@code aurora.frag} (zero
 *       texture sampling, premultiplied opaque output).
 *   <li>API 23-32: Pre-allocates {@link LinearGradient} and {@link Matrix} at construction /
 *       resize, driving wave drift strictly via {@link Shader#setLocalMatrix(Matrix)} with zero
 *       per-frame heap allocations.
 *   <li>Lifecycle safety: Immediately unregisters from {@link MotionLoop} when detached,
 *       invisible, window-hidden (backgrounded), inactive, TV-mode, or {@code reducedMotion}.
 * </ul>
 */
public final class AuroraSurfaceView extends View {
    /** Exact 4-tone harmonic AGSL source matching {@code flutter/shaders/aurora.frag}. */
    public static final String AGSL_AURORA_SOURCE =
            "uniform float2 uCanvasSize;\n"
                    + "uniform float uElapsedSec;\n"
                    + "uniform float uStrength;\n"
                    + "uniform float3 uWaveBlue;\n"
                    + "uniform float3 uWaveTeal;\n"
                    + "uniform float3 uWaveIndigo;\n"
                    + "uniform float3 uWavePurple;\n"
                    + "half4 main(float2 fragCoord) {\n"
                    + "    float2 canvasSize = max(uCanvasSize, float2(1.0));\n"
                    + "    float2 uv = (fragCoord - 0.5 * canvasSize) / max(canvasSize.y, 1.0);\n"
                    + "    float t = uElapsedSec * 0.38;\n"
                    + "    float d1 = uv.y + 0.22 * sin(uv.x * 2.1 + t) + 0.12 * cos(uv.x * 1.3 - t * 0.7);\n"
                    + "    float w1 = exp(-3.4 * d1 * d1);\n"
                    + "    float d2 = uv.y - 0.18 * cos(uv.x * 1.7 - t * 0.85) + 0.15 * sin(t * 0.45);\n"
                    + "    float w2 = exp(-4.2 * d2 * d2);\n"
                    + "    float d3 = length(uv - float2(0.28 * sin(t * 0.55), -0.16 * cos(t * 0.65))) - 0.34;\n"
                    + "    float w3 = exp(-3.8 * d3 * d3);\n"
                    + "    float3 base = float3(0.035, 0.035, 0.047);\n"
                    + "    float strength = clamp(uStrength, 0.0, 1.0);\n"
                    + "    float3 wave1Color = mix(uWaveBlue, uWaveTeal, 0.5 + 0.5 * sin(t));\n"
                    + "    float3 color = clamp(\n"
                    + "        base + strength * (0.42 * w1 * wave1Color + 0.36 * w2 * uWaveIndigo + 0.30 * w3 * uWavePurple),\n"
                    + "        float3(0.0),\n"
                    + "        float3(1.0)\n"
                    + "    );\n"
                    + "    return half4(half3(color), 1.0);\n"
                    + "}\n";

    private static float channelR(int argb) {
        return ((argb >>> 16) & 0xFF) / 255f;
    }

    private static float channelG(int argb) {
        return ((argb >>> 8) & 0xFF) / 255f;
    }

    private static float channelB(int argb) {
        return (argb & 0xFF) / 255f;
    }

    private static final float BLUE_R = channelR(MotionTokens.AURORA_WAVE_BLUE_ARGB);
    private static final float BLUE_G = channelG(MotionTokens.AURORA_WAVE_BLUE_ARGB);
    private static final float BLUE_B = channelB(MotionTokens.AURORA_WAVE_BLUE_ARGB);
    private static final float TEAL_R = channelR(MotionTokens.AURORA_WAVE_TEAL_ARGB);
    private static final float TEAL_G = channelG(MotionTokens.AURORA_WAVE_TEAL_ARGB);
    private static final float TEAL_B = channelB(MotionTokens.AURORA_WAVE_TEAL_ARGB);
    private static final float INDIGO_R = channelR(MotionTokens.AURORA_WAVE_INDIGO_ARGB);
    private static final float INDIGO_G = channelG(MotionTokens.AURORA_WAVE_INDIGO_ARGB);
    private static final float INDIGO_B = channelB(MotionTokens.AURORA_WAVE_INDIGO_ARGB);
    private static final float PURPLE_R = channelR(MotionTokens.AURORA_WAVE_PURPLE_ARGB);
    private static final float PURPLE_G = channelG(MotionTokens.AURORA_WAVE_PURPLE_ARGB);
    private static final float PURPLE_B = channelB(MotionTokens.AURORA_WAVE_PURPLE_ARGB);

    private final Paint basePaint = new Paint(Paint.ANTI_ALIAS_FLAG | Paint.DITHER_FLAG);
    private final Paint bandPaintPrimary = new Paint(Paint.ANTI_ALIAS_FLAG | Paint.DITHER_FLAG);
    private final Paint bandPaintSecondary = new Paint(Paint.ANTI_ALIAS_FLAG | Paint.DITHER_FLAG);
    private final Matrix matrixPrimary = new Matrix();
    private final Matrix matrixSecondary = new Matrix();

    private LinearGradient primaryGradient;
    private LinearGradient secondaryGradient;
    private final Api33AgslDriver agslDriver;

    private final MainActivity hostActivity;
    private final boolean tvDevice;
    private Boolean reducedMotionOverride;
    private boolean active = true;
    private boolean loopRunning;
    private float strength = MotionTokens.AURORA_DEFAULT_STRENGTH;
    private double elapsedSec = 0.0;

    private final MotionLoop.Step frameStep = this::advanceFrame;

    public AuroraSurfaceView(Context context) {
        super(context);
        setTag("marco-aurora-surface");
        UiCompat.hideFromAccessibility(this, false);
        basePaint.setColor(MotionTokens.AURORA_BASE_CANVAS_ARGB);

        if (context instanceof MainActivity) {
            MainActivity host = (MainActivity) context;
            this.hostActivity = host;
            this.tvDevice = host.isTvDevice();
        } else {
            this.hostActivity = null;
            this.tvDevice = false;
        }

        Api33AgslDriver driver = null;
        if (!tvDevice && Build.VERSION.SDK_INT >= 33) {
            driver = Api33AgslDriver.tryCreate();
        }
        this.agslDriver = driver;
        rebuildLegacyGradients(1080, 1920);
    }

    /** Pure lifecycle predicate controlling whether frame updates are allowed to run. */
    public static boolean shouldRunLoop(
            boolean attached,
            boolean viewVisible,
            boolean windowVisible,
            boolean active,
            boolean reducedMotion,
            boolean tvDevice,
            float strength) {
        return attached
                && viewVisible
                && windowVisible
                && active
                && !reducedMotion
                && !tvDevice
                && strength > 0.005f;
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

    public void setActive(boolean active) {
        if (this.active == active) return;
        this.active = active;
        syncLoop();
    }

    public void setReducedMotion(boolean reduced) {
        Boolean next = Boolean.valueOf(reduced);
        if (next.equals(this.reducedMotionOverride)) return;
        this.reducedMotionOverride = next;
        if (reduced) {
            elapsedSec = MotionTokens.REDUCE_MOTION_AURORA_FROZEN_TIME_SEC;
        }
        syncLoop();
        invalidate();
    }

    public void setStrength(float nextStrength) {
        float clamped = Math.max(0f, Math.min(1f, nextStrength));
        if (this.strength == clamped) return;
        this.strength = clamped;
        updateLegacyBandAlphas();
        syncLoop();
        invalidate();
    }

    public boolean isLoopRunning() {
        return loopRunning;
    }

    private boolean canAnimate() {
        boolean viewVisible = getVisibility() == View.VISIBLE && isShown();
        boolean windowVisible = getWindowVisibility() == View.VISIBLE;
        return shouldRunLoop(
                UiCompat.isAttached(this),
                viewVisible,
                windowVisible,
                active,
                isReducedMotionEffective(),
                tvDevice,
                strength);
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
        elapsedSec = MotionTokens.wrapAuroraElapsedSeconds(elapsedSec + Math.min(dtSeconds, 0.05f));
        invalidate();
        return true;
    }

    private void rebuildLegacyGradients(int w, int h) {
        float spanW = Math.max(1f, w);
        float spanH = Math.max(1f, h);
        primaryGradient =
                new LinearGradient(
                        -spanW * 0.4f,
                        0f,
                        spanW * 1.4f,
                        spanH * 0.85f,
                        new int[] {0x000A84FF, 0x660A84FF, 0x5C5AC8FA, 0x525E5CE6, 0x005E5CE6},
                        new float[] {0f, 0.25f, 0.50f, 0.78f, 1f},
                        Shader.TileMode.CLAMP);
        secondaryGradient =
                new LinearGradient(
                        spanW * 1.2f,
                        spanH * 0.15f,
                        -spanW * 0.2f,
                        spanH * 1.1f,
                        new int[] {0x00BF5AF2, 0x4D5E5CE6, 0x59BF5AF2, 0x385AC8FA, 0x0009090C},
                        new float[] {0f, 0.28f, 0.56f, 0.82f, 1f},
                        Shader.TileMode.CLAMP);
        bandPaintPrimary.setShader(primaryGradient);
        bandPaintSecondary.setShader(secondaryGradient);
        updateLegacyBandAlphas();
    }

    private void updateLegacyBandAlphas() {
        int a1 = Math.max(0, Math.min(255, Math.round(255f * strength)));
        int a2 = Math.max(0, Math.min(255, Math.round(230f * strength)));
        bandPaintPrimary.setAlpha(a1);
        bandPaintSecondary.setAlpha(a2);
    }

    @Override
    protected void onSizeChanged(int w, int h, int oldw, int oldh) {
        super.onSizeChanged(w, h, oldw, oldh);
        if (w > 0 && h > 0 && agslDriver == null) {
            rebuildLegacyGradients(w, h);
        }
    }

    @Override
    protected void onDraw(Canvas canvas) {
        int w = getWidth();
        int h = getHeight();
        if (w <= 0 || h <= 0) return;

        if (tvDevice || strength <= 0.005f) {
            canvas.drawRect(0f, 0f, w, h, basePaint);
            return;
        }

        boolean reducedNow = isReducedMotionEffective();
        if (reducedNow && loopRunning) {
            elapsedSec = MotionTokens.REDUCE_MOTION_AURORA_FROZEN_TIME_SEC;
            syncLoop();
        }
        float tSec = reducedNow ? 0f : (float) elapsedSec;
        if (agslDriver != null && Build.VERSION.SDK_INT >= 33) {
            agslDriver.draw(canvas, w, h, tSec, strength);
            return;
        }

        // API 23-32 zero-allocation path: translate pre-allocated LinearGradients via local Matrix.
        canvas.drawRect(0f, 0f, w, h, basePaint);
        float t = tSec * MotionTokens.AURORA_TIME_RATE_RAD_PER_SEC;
        float dx1 = (float) Math.sin(t * 0.70) * (w * 0.18f);
        float dy1 = (float) Math.cos(t * 0.55) * (h * 0.12f);
        matrixPrimary.setTranslate(dx1, dy1);
        primaryGradient.setLocalMatrix(matrixPrimary);
        canvas.drawRect(0f, 0f, w, h, bandPaintPrimary);

        float dx2 = (float) Math.cos(t * 0.85) * (w * 0.16f);
        float dy2 = (float) Math.sin(t * 0.45) * (h * 0.14f);
        matrixSecondary.setTranslate(dx2, dy2);
        secondaryGradient.setLocalMatrix(matrixSecondary);
        canvas.drawRect(0f, 0f, w, h, bandPaintSecondary);
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

    /** Isolated API 33+ AGSL driver so API 23-32 Dalvik/ART never resolves RuntimeShader. */
    private static final class Api33AgslDriver {
        private final RuntimeShader shader;
        private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);

        private Api33AgslDriver(RuntimeShader shader) {
            this.shader = shader;
            this.shader.setFloatUniform("uWaveBlue", BLUE_R, BLUE_G, BLUE_B);
            this.shader.setFloatUniform("uWaveTeal", TEAL_R, TEAL_G, TEAL_B);
            this.shader.setFloatUniform("uWaveIndigo", INDIGO_R, INDIGO_G, INDIGO_B);
            this.shader.setFloatUniform("uWavePurple", PURPLE_R, PURPLE_G, PURPLE_B);
            this.paint.setShader(this.shader);
        }

        static Api33AgslDriver tryCreate() {
            try {
                return new Api33AgslDriver(new RuntimeShader(AGSL_AURORA_SOURCE));
            } catch (Throwable ignored) {
                return null;
            }
        }

        void draw(Canvas canvas, int width, int height, float elapsedSec, float strength) {
            shader.setFloatUniform("uCanvasSize", (float) width, (float) height);
            shader.setFloatUniform("uElapsedSec", elapsedSec);
            shader.setFloatUniform("uStrength", strength);
            canvas.drawRect(0f, 0f, (float) width, (float) height, paint);
        }
    }
}
