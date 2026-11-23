// Copyright (C) 2026 Pilipala
// SPDX-License-Identifier: GPL-3.0-only
package com.pilipala.marcomovie;

import android.view.animation.Interpolator;
import android.view.animation.LinearInterpolator;
import android.view.animation.PathInterpolator;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.Map;

/**
 * Cross-platform motion timings, curves, physical spring presets, accessibility substitutions,
 * badge metrics/palettes, and aurora constants mirroring {@code shared/ui-spec/motion-tokens.json}
 * (schemaVersion 2).
 *
 * <p>All numeric tokens and the zero-dependency damped-harmonic spring solver are pure Java so
 * offline JVM conformance checks can verify exact parity without Android runtime stubs.
 */
public final class MotionTokens {
    private MotionTokens() {}

    public static final int SCHEMA_VERSION = 2;

    // --- durationsMs ---
    public static final int DURATION_INSTANT_MS = 0;
    public static final int DURATION_MICRO_MS = 90;
    public static final int DURATION_REDUCED_HUD_FADE_MS = 120;
    public static final int DURATION_FAST_MS = 150;
    public static final int DURATION_WINDOWS_ROUTE_EXIT_MS = 150;
    public static final int DURATION_TV_PAGE_FADE_MS = 180;
    public static final int DURATION_WINDOWS_ROUTE_ENTER_MS = 185;
    public static final int DURATION_STANDARD_MS = 220;
    public static final int DURATION_TV_PLAY_EXIT_MS = 220;
    public static final int DURATION_MOBILE_SHARED_BOUNDS_MS = 280;
    public static final int DURATION_TRANSITION_EXIT_MS = 300;
    public static final int DURATION_EMPHASIZED_MS = 320;
    public static final int DURATION_TRANSITION_ENTER_MS = 420;
    public static final int DURATION_LOGO_LOOP_MS = 1600;
    public static final int DURATION_AURORA_CYCLE_MS = 16000;

    // --- hudTimersMs ---
    public static final int HUD_START_SPEC_FADE_IN_MS = 180;
    public static final int HUD_START_SPEC_DISPLAY_MS = 3000;
    public static final int HUD_START_SPEC_FADE_OUT_MS = 240;
    public static final int HUD_DESKTOP_CURSOR_IDLE_HIDE_MS = 2500;
    public static final int HUD_TOUCH_CONTROLS_IDLE_HIDE_MS = 4000;
    public static final int HUD_SKIP_COUNTDOWN_TOTAL_MS = 3000;
    public static final int HUD_TOUCH_HOLD_SPEED_BOOST_THRESHOLD_MS = 350;
    public static final int HUD_TOUCH_HOLD_FAST_FORWARD_THRESHOLD_MS = 350;
    public static final int HUD_DESKTOP_HOLD_FAST_FORWARD_THRESHOLD_MS = 280;
    public static final int HUD_TV_HOLD_FAST_FORWARD_THRESHOLD_MS = 500;
    public static final int HUD_DANMU_SEEK_DEBOUNCE_MS = 180;
    public static final int HUD_TRANSITION_CAPTURE_BUDGET_MS = 16;

    // --- gestureThresholds ---
    public static final float GESTURE_TOUCH_SLOP_DP = 12f;
    public static final int GESTURE_DOUBLE_TAP_TIMEOUT_MS = 260;
    public static final float GESTURE_DOUBLE_TAP_SLOP_DP = 42f;
    public static final int GESTURE_MULTI_TAP_SEEK_WINDOW_MS = 650;
    public static final float GESTURE_EDGE_BACK_GUARD_DP = 24f;
    public static final float GESTURE_SYSTEM_VERTICAL_GUARD_DP = 28f;
    public static final float GESTURE_SPEED_SLIDE_STEP_DP = 36f;
    public static final float GESTURE_TOUCH_SWIPE_LOCK_THRESHOLD_DP = 48f;
    public static final float GESTURE_TOUCH_SWIPE_LOCK_RELEASE_HYSTERESIS_DP = 36f;
    public static final float[] GESTURE_SPEED_BOOST_DETENTS = {1.25f, 1.5f, 2.0f, 3.0f};
    public static final float GESTURE_DEFAULT_BOOST_SPEED = 2.0f;

    // --- ios26PlayerGlassMetrics ---
    public static final float IOS26_TOP_CAPSULE_HEIGHT_PT = 40f;
    public static final float IOS26_TOP_CAPSULE_RADIUS_PT = 20f;
    public static final float IOS26_CENTER_PRIMARY_BUTTON_SIZE_PT = 76f;
    public static final float IOS26_CENTER_SECONDARY_BUTTON_SIZE_PT = 56f;
    public static final float IOS26_SCRUBBER_TRACK_IDLE_HEIGHT_PT = 5f;
    public static final float IOS26_SCRUBBER_TRACK_EXPANDED_HEIGHT_PT = 10f;
    public static final float IOS26_DOCK_CAPSULE_RADIUS_PT = 22f;
    public static final int IOS26_MAX_PRIMARY_DOCK_ACTIONS = 7;

    // --- curves ---
    public static final float[] CURVE_STANDARD = {0.2f, 0.0f, 0.0f, 1.0f};
    public static final float[] CURVE_DECELERATE = {0.05f, 0.7f, 0.1f, 1.0f};
    public static final float[] CURVE_ACCELERATE = {0.3f, 0.0f, 0.8f, 0.15f};
    public static final float[] CURVE_LINEAR = {0.0f, 0.0f, 1.0f, 1.0f};

    public static Interpolator createStandardInterpolator() {
        return new PathInterpolator(
                CURVE_STANDARD[0], CURVE_STANDARD[1], CURVE_STANDARD[2], CURVE_STANDARD[3]);
    }

    public static Interpolator createDecelerateInterpolator() {
        return new PathInterpolator(
                CURVE_DECELERATE[0], CURVE_DECELERATE[1], CURVE_DECELERATE[2], CURVE_DECELERATE[3]);
    }

    public static Interpolator createAccelerateInterpolator() {
        return new PathInterpolator(
                CURVE_ACCELERATE[0], CURVE_ACCELERATE[1], CURVE_ACCELERATE[2], CURVE_ACCELERATE[3]);
    }

    public static Interpolator createLinearInterpolator() {
        return new LinearInterpolator();
    }

    // --- springs ---
    public static final class SpringPreset {
        public final float response;
        public final float dampingRatio;
        public final float mass;
        public final float stiffness;
        public final float viscousDamping;
        public final float motionSpringFrequency;

        public SpringPreset(
                float response,
                float dampingRatio,
                float mass,
                float stiffness,
                float viscousDamping,
                float motionSpringFrequency) {
            this.response = response;
            this.dampingRatio = dampingRatio;
            this.mass = mass;
            this.stiffness = stiffness;
            this.viscousDamping = viscousDamping;
            this.motionSpringFrequency = motionSpringFrequency;
        }
    }

    /** Reusable zero-allocation spring state for {@link #stepUnderdampedSpring}. */
    public static final class SpringState {
        public float value;
        public float velocity;

        public SpringState(float initialValue, float initialVelocity) {
            this.value = initialValue;
            this.velocity = initialVelocity;
        }

        public void reset(float nextValue, float nextVelocity) {
            this.value = nextValue;
            this.velocity = nextVelocity;
        }
    }

    public static final SpringPreset SPRING_TV_FOCUS =
            new SpringPreset(0.21f, 1.0f, 1.0f, 895.2f, 59.84f, 30.0f);
    public static final SpringPreset SPRING_PRESS_FEEDBACK =
            new SpringPreset(0.16f, 1.0f, 1.0f, 1542.13f, 78.54f, 40.0f);
    public static final SpringPreset SPRING_HUD_POPUP =
            new SpringPreset(0.28f, 0.86f, 1.0f, 503.55f, 38.6f, 22.44f);
    public static final SpringPreset SPRING_PLAYER_TRANSITION =
            new SpringPreset(0.42f, 0.92f, 1.0f, 223.8f, 27.53f, 14.96f);

    public static double omegaRadPerSec(double response) {
        return (2.0 * Math.PI) / response;
    }

    public static double computeStiffness(double mass, double response) {
        double omega = omegaRadPerSec(response);
        return mass * omega * omega;
    }

    public static double computeViscousDamping(double dampingRatio, double stiffness, double mass) {
        return 2.0 * dampingRatio * Math.sqrt(stiffness * mass);
    }

    /**
     * Zero-dependency analytical damped-harmonic spring integrator supporting underdamped
     * ({@code dampingRatio < 1.0}), critically damped ({@code == 1.0}), and overdamped
     * ({@code > 1.0}) presets without {@code androidx.dynamicanimation}.
     *
     * @return {@code true} while still moving beyond {@code tolerance}, {@code false} once settled.
     */
    public static boolean stepUnderdampedSpring(
            SpringState state,
            float target,
            SpringPreset preset,
            float dtSeconds,
            float tolerance) {
        double omega = Math.sqrt(preset.stiffness / Math.max(preset.mass, 1e-6f));
        double zeta = Math.max(0.0, preset.dampingRatio);
        double tol = Math.max(1e-6, tolerance);
        if (dtSeconds <= 0f) {
            return Math.abs(state.value - target) > tol || Math.abs(state.velocity) > tol * omega;
        }
        double dt = dtSeconds;
        double x0 = state.value - target;
        double v0 = state.velocity;
        double nextX;
        double nextV;

        if (Math.abs(zeta - 1.0) < 1e-5) {
            // Critically damped closed form (exact parity with MotionSpring).
            double coupling = v0 + omega * x0;
            double decay = Math.exp(-omega * dt);
            nextX = target + (x0 + coupling * dt) * decay;
            nextV = (v0 - omega * coupling * dt) * decay;
        } else if (zeta < 1.0) {
            // Underdamped closed form.
            double omegaD = omega * Math.sqrt(1.0 - zeta * zeta);
            double decay = Math.exp(-zeta * omega * dt);
            double a = x0;
            double b = (v0 + zeta * omega * x0) / omegaD;
            double cos = Math.cos(omegaD * dt);
            double sin = Math.sin(omegaD * dt);
            nextX = target + decay * (a * cos + b * sin);
            nextV =
                    decay
                            * ((b * omegaD - a * zeta * omega) * cos
                                    - (a * omegaD + b * zeta * omega) * sin);
        } else {
            // Overdamped closed form.
            double root = Math.sqrt(zeta * zeta - 1.0);
            double r1 = -omega * (zeta - root);
            double r2 = -omega * (zeta + root);
            double c1 = (v0 - r2 * x0) / (r1 - r2);
            double c2 = x0 - c1;
            double e1 = Math.exp(r1 * dt);
            double e2 = Math.exp(r2 * dt);
            nextX = target + c1 * e1 + c2 * e2;
            nextV = c1 * r1 * e1 + c2 * r2 * e2;
        }

        state.value = (float) nextX;
        state.velocity = (float) nextV;
        boolean moving =
                Math.abs(state.value - target) > tol || Math.abs(state.velocity) > tol * omega;
        if (!moving) {
            state.value = target;
            state.velocity = 0f;
        }
        return moving;
    }

    // --- accessibilitySubstitutions.reduceMotion ---
    public static final String REDUCE_MOTION_TRANSITION_MODE = "crossFade";
    public static final int REDUCE_MOTION_TRANSITION_DURATION_MS = 150;
    public static final String REDUCE_MOTION_TRANSITION_CURVE = "linear";
    public static final float REDUCE_MOTION_TRANSITION_SCALE = 1.0f;
    public static final boolean REDUCE_MOTION_TRANSITION_SHADER_ENABLED = false;

    public static final String REDUCE_MOTION_TV_FOCUS_MODE = "snap";
    public static final int REDUCE_MOTION_TV_FOCUS_DURATION_MS = 0;
    public static final float REDUCE_MOTION_TV_FOCUS_SCALE = 1.0f;
    public static final boolean REDUCE_MOTION_TV_FOCUS_KEEP_STROKE_AND_FILL = true;

    public static final String REDUCE_MOTION_HUD_MODE = "opacityOnly";
    public static final int REDUCE_MOTION_HUD_DURATION_MS = 120;
    public static final String REDUCE_MOTION_HUD_CURVE = "linear";
    public static final float REDUCE_MOTION_HUD_TRANSLATE_DP = 0f;

    public static final String REDUCE_MOTION_AURORA_MODE = "staticFrame";
    public static final float REDUCE_MOTION_AURORA_FROZEN_TIME_SEC = 0.0f;
    public static final boolean REDUCE_MOTION_AURORA_TICKER_RUNNING = false;

    public static final String REDUCE_MOTION_LOGO_MODE = "staticBreathingAlpha";
    public static final int REDUCE_MOTION_LOGO_CYCLE_MS = 1600;
    public static final float REDUCE_MOTION_LOGO_MIN_ALPHA = 0.72f;
    public static final float REDUCE_MOTION_LOGO_MAX_ALPHA = 1.0f;

    // --- accessibilitySubstitutions.reduceTransparency ---
    public static final int REDUCE_TRANSPARENCY_GLASS_SURFACE_FILL_ARGB = 0xF51E1E22;
    public static final int REDUCE_TRANSPARENCY_HUD_BACKDROP_FILL_ARGB = 0xEB16161A;
    public static final boolean REDUCE_TRANSPARENCY_USE_BADGE_SOLID_FILL = true;
    public static final float REDUCE_TRANSPARENCY_MIN_BORDER_ALPHA = 0.45f;
    public static final boolean REDUCE_TRANSPARENCY_DISABLE_SHADER_REFRACTION = true;

    // --- scaleTokens ---
    public static final float ANDROID_UI_SCALE_100 = 1.0f;
    public static final float ANDROID_UI_SCALE_110 = 1.1f;
    public static final float ANDROID_UI_SCALE_120 = 1.2f;
    public static final float FLUTTER_TEXT_SCALE_CLAMP_MIN = 0.85f;
    public static final float FLUTTER_TEXT_SCALE_CLAMP_MAX = 1.35f;

    public static final float TV_FOCUS_POSTER_SCALE = 1.05f;
    public static final float TV_FOCUS_PILL_SCALE = 1.06f;
    public static final float TV_FOCUS_REDUCED_SCALE = 1.0f;
    public static final float TV_FOCUS_STROKE_WIDTH_DP = 2.0f;
    public static final int TV_FOCUS_STROKE_ARGB = 0xFFF5F5F7;

    public static final class BadgeMetrics {
        public final float height;
        public final float paddingHorizontal;
        public final float paddingVertical;
        public final float cornerRadius;
        public final float iosConcentricRadius;
        public final float borderWidth;
        public final float fontSize;
        public final int fontWeight;
        public final float letterSpacing;
        public final float gap;

        public BadgeMetrics(
                float height,
                float paddingHorizontal,
                float paddingVertical,
                float cornerRadius,
                float iosConcentricRadius,
                float borderWidth,
                float fontSize,
                int fontWeight,
                float letterSpacing,
                float gap) {
            this.height = height;
            this.paddingHorizontal = paddingHorizontal;
            this.paddingVertical = paddingVertical;
            this.cornerRadius = cornerRadius;
            this.iosConcentricRadius = iosConcentricRadius;
            this.borderWidth = borderWidth;
            this.fontSize = fontSize;
            this.fontWeight = fontWeight;
            this.letterSpacing = letterSpacing;
            this.gap = gap;
        }
    }

    public static final BadgeMetrics BADGE_METRICS_COMPACT =
            new BadgeMetrics(20f, 6f, 2f, 5f, 999f, 1.0f, 11f, 600, 0.3f, 4f);
    public static final BadgeMetrics BADGE_METRICS_START_SPEC =
            new BadgeMetrics(24f, 8f, 3f, 6f, 999f, 1.0f, 12f, 700, 0.35f, 6f);
    public static final BadgeMetrics BADGE_METRICS_TV =
            new BadgeMetrics(28f, 10f, 4f, 7f, -1f, 1.5f, 14f, 700, 0.4f, 8f);

    public static final class BadgeStyle {
        public final int fillArgb;
        public final int strokeArgb;
        public final int textArgb;
        public final int solidFillArgb;
        public final int focusedFillArgb;
        public final int focusedStrokeArgb;
        public final int focusedTextArgb;

        public BadgeStyle(
                int fillArgb,
                int strokeArgb,
                int textArgb,
                int solidFillArgb,
                int focusedFillArgb,
                int focusedStrokeArgb,
                int focusedTextArgb) {
            this.fillArgb = fillArgb;
            this.strokeArgb = strokeArgb;
            this.textArgb = textArgb;
            this.solidFillArgb = solidFillArgb;
            this.focusedFillArgb = focusedFillArgb;
            this.focusedStrokeArgb = focusedStrokeArgb;
            this.focusedTextArgb = focusedTextArgb;
        }
    }

    public static final Map<String, BadgeStyle> BADGE_STYLES;

    static {
        Map<String, BadgeStyle> styles = new LinkedHashMap<>();
        styles.put(
                "uhdGold",
                new BadgeStyle(
                        0x2EFF9F0A,
                        0x66FF9F0A,
                        0xFFFFB340,
                        0xEB3A2810,
                        0xFFF5F5F7,
                        0xFFF5F5F7,
                        0xFF101013));
        styles.put(
                "hdCyan",
                new BadgeStyle(
                        0x2964D2FF,
                        0x5C64D2FF,
                        0xFF70D7FF,
                        0xEB142C38,
                        0xFFF5F5F7,
                        0xFFF5F5F7,
                        0xFF101013));
        styles.put(
                "sdNeutral",
                new BadgeStyle(
                        0x33787884,
                        0x4DEBEBF5,
                        0xFFD1D1DA,
                        0xEB25252B,
                        0xFFF5F5F7,
                        0xFFF5F5F7,
                        0xFF101013));
        styles.put(
                "premiumCombo",
                new BadgeStyle(
                        0x335E5CE6,
                        0x73BF5AF2,
                        0xFFE5C7FF,
                        0xEB261F42,
                        0xFFF5F5F7,
                        0xFFF5F5F7,
                        0xFF101013));
        styles.put(
                "visionPurple",
                new BadgeStyle(
                        0x2EBF5AF2,
                        0x66BF5AF2,
                        0xFFDEB0FF,
                        0xEB2D1B38,
                        0xFFF5F5F7,
                        0xFFF5F5F7,
                        0xFF101013));
        styles.put(
                "hdrBlue",
                new BadgeStyle(
                        0x2E0A84FF,
                        0x660A84FF,
                        0xFF64D2FF,
                        0xEB122640,
                        0xFFF5F5F7,
                        0xFFF5F5F7,
                        0xFF101013));
        styles.put(
                "discEmerald",
                new BadgeStyle(
                        0x2930D158,
                        0x5C30D158,
                        0xFF63E682,
                        0xEB142E1C,
                        0xFFF5F5F7,
                        0xFFF5F5F7,
                        0xFF101013));
        styles.put(
                "streamTeal",
                new BadgeStyle(
                        0x265AC8FA,
                        0x525AC8FA,
                        0xFF82D7FF,
                        0xEB152936,
                        0xFFF5F5F7,
                        0xFFF5F5F7,
                        0xFF101013));
        styles.put(
                "spatialAudio",
                new BadgeStyle(
                        0x2E0A84FF,
                        0x665AC8FA,
                        0xFF8AE0FF,
                        0xEB13283D,
                        0xFFF5F5F7,
                        0xFFF5F5F7,
                        0xFF101013));
        styles.put(
                "standardAudio",
                new BadgeStyle(
                        0x38787884,
                        0x3BFFFFFF,
                        0xFFF5F5F7,
                        0xEB28282E,
                        0xFFF5F5F7,
                        0xFFF5F5F7,
                        0xFF101013));
        styles.put(
                "codecSlate",
                new BadgeStyle(
                        0x29787884,
                        0x29FFFFFF,
                        0xFFD1D1DA,
                        0xEB222228,
                        0xFFF5F5F7,
                        0xFFF5F5F7,
                        0xFF101013));
        styles.put(
                "platformTag",
                new BadgeStyle(
                        0x2E36363D,
                        0x45FFFFFF,
                        0xFFEBEBF5,
                        0xEB28282E,
                        0xFFF5F5F7,
                        0xFFF5F5F7,
                        0xFF101013));
        BADGE_STYLES = Collections.unmodifiableMap(styles);
    }

    public static final String LITE_BADGE_SEPARATOR = " · ";
    public static final int LITE_BADGE_META_TEXT_ARGB = 0xFF64D2FF;
    public static final int LITE_BADGE_CHIP_IDLE_TEXT_ARGB = 0xFFEEEEF2;
    public static final int LITE_BADGE_CHIP_SELECTED_FILL_ARGB = 0xFF0A84FF;
    public static final int LITE_BADGE_CHIP_FOCUSED_FILL_ARGB = 0xFFF5F5F7;
    public static final int LITE_BADGE_CHIP_FOCUSED_TEXT_ARGB = 0xFF101013;
    public static final int LITE_BADGE_MAX_INLINE = 4;

    // --- auroraPalette ---
    public static final int AURORA_BASE_CANVAS_ARGB = 0xFF09090C;
    public static final int AURORA_WAVE_BLUE_ARGB = 0xFF0A84FF;
    public static final int AURORA_WAVE_TEAL_ARGB = 0xFF5AC8FA;
    public static final int AURORA_WAVE_INDIGO_ARGB = 0xFF5E5CE6;
    public static final int AURORA_WAVE_PURPLE_ARGB = 0xFFBF5AF2;
    public static final float AURORA_TIME_RATE_RAD_PER_SEC = 0.38f;
    public static final float AURORA_DEFAULT_STRENGTH = 0.62f;

    /** Exact wrap period ({@code 2000 * pi}) specified by {@code transitions-spec.md} §2.2. */
    public static final double AURORA_WRAP_PERIOD_SEC = 6283.1853;

    public static float wrapAuroraElapsedSeconds(double rawSec) {
        if (Double.isNaN(rawSec) || Double.isInfinite(rawSec)) return 0f;
        double mod = rawSec % AURORA_WRAP_PERIOD_SEC;
        if (mod < 0.0) mod += AURORA_WRAP_PERIOD_SEC;
        return (float) mod;
    }
}
