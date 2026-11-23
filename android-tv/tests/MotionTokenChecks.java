// Copyright (C) 2026 Pilipala
// SPDX-License-Identifier: GPL-3.0-only
package com.pilipala.marcomovie;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.Iterator;
import org.json.JSONArray;
import org.json.JSONObject;

/**
 * Pure-JVM verification suite for M4a Android motion tokens, analytical underdamped spring solver,
 * tiered transition policy/math/AGSL contracts, aurora lifecycle gating, and F8 brand ribbon M
 * loader curves.
 */
public final class MotionTokenChecks {
    private static int checks;

    private static void check(boolean condition, String message) {
        checks++;
        if (!condition) {
            throw new AssertionError("FAILED: " + message);
        }
    }

    private static void checkEq(int expected, int actual, String name) {
        check(expected == actual, name + " expected=" + expected + " actual=" + actual);
    }

    private static void checkEq(boolean expected, boolean actual, String name) {
        check(expected == actual, name + " expected=" + expected + " actual=" + actual);
    }

    private static void checkEq(String expected, String actual, String name) {
        check(
                expected != null && expected.equals(actual),
                name + " expected=" + expected + " actual=" + actual);
    }

    private static void checkClose(double expected, double actual, double eps, String name) {
        check(
                Math.abs(expected - actual) <= eps,
                name + " expected=" + expected + " actual=" + actual + " eps=" + eps);
    }

    private static int parseArgb(String hex) {
        if (hex == null || !hex.startsWith("#") || hex.length() != 9) {
            throw new IllegalArgumentException("Expected #AARRGGBB: " + hex);
        }
        return (int) Long.parseLong(hex.substring(1), 16);
    }

    private static void checkFloatArray(JSONArray arr, float[] actual, String name) {
        checkEq(arr.length(), actual.length, name + ".length");
        for (int i = 0; i < arr.length(); i++) {
            checkClose(arr.getDouble(i), actual[i], 1e-5, name + "[" + i + "]");
        }
    }

    private static void checkSpringPreset(
            JSONObject obj, MotionTokens.SpringPreset preset, String name) {
        checkClose(obj.getDouble("response"), preset.response, 1e-5, name + ".response");
        checkClose(
                obj.getDouble("dampingRatio"), preset.dampingRatio, 1e-5, name + ".dampingRatio");
        checkClose(obj.getDouble("mass"), preset.mass, 1e-5, name + ".mass");
        checkClose(obj.getDouble("stiffness"), preset.stiffness, 1e-4, name + ".stiffness");
        checkClose(
                obj.getDouble("viscousDamping"),
                preset.viscousDamping,
                1e-4,
                name + ".viscousDamping");
        checkClose(
                obj.getDouble("motionSpringFrequency"),
                preset.motionSpringFrequency,
                1e-4,
                name + ".motionSpringFrequency");
    }

    private static void checkBadgeMetrics(
            JSONObject obj, MotionTokens.BadgeMetrics actual, String name) {
        checkClose(obj.getDouble("height"), actual.height, 1e-5, name + ".height");
        checkClose(
                obj.getDouble("paddingHorizontal"),
                actual.paddingHorizontal,
                1e-5,
                name + ".paddingHorizontal");
        checkClose(
                obj.getDouble("paddingVertical"),
                actual.paddingVertical,
                1e-5,
                name + ".paddingVertical");
        checkClose(
                obj.getDouble("cornerRadius"), actual.cornerRadius, 1e-5, name + ".cornerRadius");
        if (obj.has("iosConcentricRadius")) {
            checkClose(
                    obj.getDouble("iosConcentricRadius"),
                    actual.iosConcentricRadius,
                    1e-5,
                    name + ".iosConcentricRadius");
        } else {
            check(actual.iosConcentricRadius < 0f, name + ".iosConcentricRadius omitted");
        }
        checkClose(obj.getDouble("borderWidth"), actual.borderWidth, 1e-5, name + ".borderWidth");
        checkClose(obj.getDouble("fontSize"), actual.fontSize, 1e-5, name + ".fontSize");
        checkEq(obj.getInt("fontWeight"), actual.fontWeight, name + ".fontWeight");
        checkClose(
                obj.getDouble("letterSpacing"),
                actual.letterSpacing,
                1e-5,
                name + ".letterSpacing");
        checkClose(obj.getDouble("gap"), actual.gap, 1e-5, name + ".gap");
    }

    private static void verifyMotionTokensJsonParity(Path root) throws Exception {
        Path specPath = root.resolve("shared/ui-spec/motion-tokens.json");
        String raw = new String(Files.readAllBytes(specPath), StandardCharsets.UTF_8);
        JSONObject doc = new JSONObject(raw);

        checkEq(doc.getInt("schemaVersion"), MotionTokens.SCHEMA_VERSION, "schemaVersion");

        JSONObject dur = doc.getJSONObject("durationsMs");
        checkEq(dur.getInt("instant"), MotionTokens.DURATION_INSTANT_MS, "durationsMs.instant");
        checkEq(dur.getInt("micro"), MotionTokens.DURATION_MICRO_MS, "durationsMs.micro");
        checkEq(
                dur.getInt("reducedHudFade"),
                MotionTokens.DURATION_REDUCED_HUD_FADE_MS,
                "durationsMs.reducedHudFade");
        checkEq(dur.getInt("fast"), MotionTokens.DURATION_FAST_MS, "durationsMs.fast");
        checkEq(
                dur.getInt("windowsRouteExit"),
                MotionTokens.DURATION_WINDOWS_ROUTE_EXIT_MS,
                "durationsMs.windowsRouteExit");
        checkEq(
                dur.getInt("tvPageFade"),
                MotionTokens.DURATION_TV_PAGE_FADE_MS,
                "durationsMs.tvPageFade");
        checkEq(
                dur.getInt("windowsRouteEnter"),
                MotionTokens.DURATION_WINDOWS_ROUTE_ENTER_MS,
                "durationsMs.windowsRouteEnter");
        checkEq(dur.getInt("standard"), MotionTokens.DURATION_STANDARD_MS, "durationsMs.standard");
        checkEq(
                dur.getInt("tvPlayExit"),
                MotionTokens.DURATION_TV_PLAY_EXIT_MS,
                "durationsMs.tvPlayExit");
        checkEq(
                dur.getInt("mobileSharedBounds"),
                MotionTokens.DURATION_MOBILE_SHARED_BOUNDS_MS,
                "durationsMs.mobileSharedBounds");
        checkEq(
                dur.getInt("transitionExit"),
                MotionTokens.DURATION_TRANSITION_EXIT_MS,
                "durationsMs.transitionExit");
        checkEq(
                dur.getInt("emphasized"),
                MotionTokens.DURATION_EMPHASIZED_MS,
                "durationsMs.emphasized");
        checkEq(
                dur.getInt("transitionEnter"),
                MotionTokens.DURATION_TRANSITION_ENTER_MS,
                "durationsMs.transitionEnter");
        checkEq(dur.getInt("logoLoop"), MotionTokens.DURATION_LOGO_LOOP_MS, "durationsMs.logoLoop");
        checkEq(
                dur.getInt("auroraCycle"),
                MotionTokens.DURATION_AURORA_CYCLE_MS,
                "durationsMs.auroraCycle");

        JSONObject hud = doc.getJSONObject("hudTimersMs");
        checkEq(
                hud.getInt("startSpecFadeIn"),
                MotionTokens.HUD_START_SPEC_FADE_IN_MS,
                "hud.startSpecFadeIn");
        checkEq(
                hud.getInt("startSpecDisplay"),
                MotionTokens.HUD_START_SPEC_DISPLAY_MS,
                "hud.startSpecDisplay");
        checkEq(
                hud.getInt("startSpecFadeOut"),
                MotionTokens.HUD_START_SPEC_FADE_OUT_MS,
                "hud.startSpecFadeOut");
        checkEq(
                hud.getInt("desktopCursorIdleHide"),
                MotionTokens.HUD_DESKTOP_CURSOR_IDLE_HIDE_MS,
                "hud.desktopCursorIdleHide");
        checkEq(
                hud.getInt("touchControlsIdleHide"),
                MotionTokens.HUD_TOUCH_CONTROLS_IDLE_HIDE_MS,
                "hud.touchControlsIdleHide");
        checkEq(
                hud.getInt("skipCountdownTotal"),
                MotionTokens.HUD_SKIP_COUNTDOWN_TOTAL_MS,
                "hud.skipCountdownTotal");
        checkEq(
                hud.getInt("touchHoldSpeedBoostThreshold"),
                MotionTokens.HUD_TOUCH_HOLD_SPEED_BOOST_THRESHOLD_MS,
                "hud.touchHoldSpeedBoostThreshold");
        checkEq(
                hud.getInt("touchHoldFastForwardThreshold"),
                MotionTokens.HUD_TOUCH_HOLD_FAST_FORWARD_THRESHOLD_MS,
                "hud.touchHoldFastForwardThreshold");
        checkEq(
                hud.getInt("desktopHoldFastForwardThreshold"),
                MotionTokens.HUD_DESKTOP_HOLD_FAST_FORWARD_THRESHOLD_MS,
                "hud.desktopHoldFastForwardThreshold");
        checkEq(
                hud.getInt("tvHoldFastForwardThreshold"),
                MotionTokens.HUD_TV_HOLD_FAST_FORWARD_THRESHOLD_MS,
                "hud.tvHoldFastForwardThreshold");
        checkEq(
                hud.getInt("danmuSeekDebounce"),
                MotionTokens.HUD_DANMU_SEEK_DEBOUNCE_MS,
                "hud.danmuSeekDebounce");
        checkEq(
                hud.getInt("transitionCaptureBudget"),
                MotionTokens.HUD_TRANSITION_CAPTURE_BUDGET_MS,
                "hud.transitionCaptureBudget");

        JSONObject gest = doc.getJSONObject("gestureThresholds");
        checkClose(
                gest.getDouble("touchSlopDp"),
                MotionTokens.GESTURE_TOUCH_SLOP_DP,
                1e-5,
                "gesture.touchSlopDp");
        checkEq(
                gest.getInt("doubleTapTimeoutMs"),
                MotionTokens.GESTURE_DOUBLE_TAP_TIMEOUT_MS,
                "gesture.doubleTapTimeoutMs");
        checkClose(
                gest.getDouble("doubleTapSlopDp"),
                MotionTokens.GESTURE_DOUBLE_TAP_SLOP_DP,
                1e-5,
                "gesture.doubleTapSlopDp");
        checkEq(
                gest.getInt("multiTapSeekWindowMs"),
                MotionTokens.GESTURE_MULTI_TAP_SEEK_WINDOW_MS,
                "gesture.multiTapSeekWindowMs");
        checkClose(
                gest.getDouble("edgeBackGuardDp"),
                MotionTokens.GESTURE_EDGE_BACK_GUARD_DP,
                1e-5,
                "gesture.edgeBackGuardDp");
        checkClose(
                gest.getDouble("systemVerticalGuardDp"),
                MotionTokens.GESTURE_SYSTEM_VERTICAL_GUARD_DP,
                1e-5,
                "gesture.systemVerticalGuardDp");
        checkClose(
                gest.getDouble("speedSlideStepDp"),
                MotionTokens.GESTURE_SPEED_SLIDE_STEP_DP,
                1e-5,
                "gesture.speedSlideStepDp");
        checkClose(
                gest.getDouble("touchSwipeLockThresholdDp"),
                MotionTokens.GESTURE_TOUCH_SWIPE_LOCK_THRESHOLD_DP,
                1e-5,
                "gesture.touchSwipeLockThresholdDp");
        checkClose(
                gest.getDouble("touchSwipeLockReleaseHysteresisDp"),
                MotionTokens.GESTURE_TOUCH_SWIPE_LOCK_RELEASE_HYSTERESIS_DP,
                1e-5,
                "gesture.touchSwipeLockReleaseHysteresisDp");
        checkFloatArray(
                gest.getJSONArray("speedBoostDetents"),
                MotionTokens.GESTURE_SPEED_BOOST_DETENTS,
                "gesture.speedBoostDetents");
        checkClose(
                gest.getDouble("defaultBoostSpeed"),
                MotionTokens.GESTURE_DEFAULT_BOOST_SPEED,
                1e-5,
                "gesture.defaultBoostSpeed");

        JSONObject ios = doc.getJSONObject("ios26PlayerGlassMetrics");
        checkClose(
                ios.getDouble("topCapsuleHeightPt"),
                MotionTokens.IOS26_TOP_CAPSULE_HEIGHT_PT,
                1e-5,
                "ios.topCapsuleHeightPt");
        checkClose(
                ios.getDouble("topCapsuleRadiusPt"),
                MotionTokens.IOS26_TOP_CAPSULE_RADIUS_PT,
                1e-5,
                "ios.topCapsuleRadiusPt");
        checkClose(
                ios.getDouble("centerPrimaryButtonSizePt"),
                MotionTokens.IOS26_CENTER_PRIMARY_BUTTON_SIZE_PT,
                1e-5,
                "ios.centerPrimaryButtonSizePt");
        checkClose(
                ios.getDouble("centerSecondaryButtonSizePt"),
                MotionTokens.IOS26_CENTER_SECONDARY_BUTTON_SIZE_PT,
                1e-5,
                "ios.centerSecondaryButtonSizePt");
        checkClose(
                ios.getDouble("scrubberTrackIdleHeightPt"),
                MotionTokens.IOS26_SCRUBBER_TRACK_IDLE_HEIGHT_PT,
                1e-5,
                "ios.scrubberTrackIdleHeightPt");
        checkClose(
                ios.getDouble("scrubberTrackExpandedHeightPt"),
                MotionTokens.IOS26_SCRUBBER_TRACK_EXPANDED_HEIGHT_PT,
                1e-5,
                "ios.scrubberTrackExpandedHeightPt");
        checkClose(
                ios.getDouble("dockCapsuleRadiusPt"),
                MotionTokens.IOS26_DOCK_CAPSULE_RADIUS_PT,
                1e-5,
                "ios.dockCapsuleRadiusPt");
        checkEq(
                ios.getInt("maxPrimaryDockActions"),
                MotionTokens.IOS26_MAX_PRIMARY_DOCK_ACTIONS,
                "ios.maxPrimaryDockActions");

        JSONObject curves = doc.getJSONObject("curves");
        checkFloatArray(
                curves.getJSONObject("standard").getJSONArray("cubicBezier"),
                MotionTokens.CURVE_STANDARD,
                "curves.standard");
        checkFloatArray(
                curves.getJSONObject("decelerate").getJSONArray("cubicBezier"),
                MotionTokens.CURVE_DECELERATE,
                "curves.decelerate");
        checkFloatArray(
                curves.getJSONObject("accelerate").getJSONArray("cubicBezier"),
                MotionTokens.CURVE_ACCELERATE,
                "curves.accelerate");
        checkFloatArray(
                curves.getJSONObject("linear").getJSONArray("cubicBezier"),
                MotionTokens.CURVE_LINEAR,
                "curves.linear");

        JSONObject presets = doc.getJSONObject("springs").getJSONObject("presets");
        checkSpringPreset(
                presets.getJSONObject("tvFocus"), MotionTokens.SPRING_TV_FOCUS, "springs.tvFocus");
        checkSpringPreset(
                presets.getJSONObject("pressFeedback"),
                MotionTokens.SPRING_PRESS_FEEDBACK,
                "springs.pressFeedback");
        checkSpringPreset(
                presets.getJSONObject("hudPopup"),
                MotionTokens.SPRING_HUD_POPUP,
                "springs.hudPopup");
        checkSpringPreset(
                presets.getJSONObject("playerTransition"),
                MotionTokens.SPRING_PLAYER_TRANSITION,
                "springs.playerTransition");

        // Verify spring physics formulas against presets
        checkClose(
                MotionTokens.SPRING_HUD_POPUP.stiffness,
                MotionTokens.computeStiffness(1.0, MotionTokens.SPRING_HUD_POPUP.response),
                0.05,
                "formula.hudPopup.stiffness");
        checkClose(
                MotionTokens.SPRING_HUD_POPUP.viscousDamping,
                MotionTokens.computeViscousDamping(
                        MotionTokens.SPRING_HUD_POPUP.dampingRatio,
                        MotionTokens.SPRING_HUD_POPUP.stiffness,
                        MotionTokens.SPRING_HUD_POPUP.mass),
                0.05,
                "formula.hudPopup.viscousDamping");

        JSONObject a11y = doc.getJSONObject("accessibilitySubstitutions");
        JSONObject rmRules = a11y.getJSONObject("reduceMotion").getJSONObject("rules");
        JSONObject rmTrans = rmRules.getJSONObject("pageAndPlayerTransition");
        checkEq(
                rmTrans.getString("mode"),
                MotionTokens.REDUCE_MOTION_TRANSITION_MODE,
                "rm.trans.mode");
        checkEq(
                rmTrans.getInt("durationMs"),
                MotionTokens.REDUCE_MOTION_TRANSITION_DURATION_MS,
                "rm.trans.durationMs");
        checkEq(
                rmTrans.getString("curve"),
                MotionTokens.REDUCE_MOTION_TRANSITION_CURVE,
                "rm.trans.curve");
        checkClose(
                rmTrans.getDouble("scale"),
                MotionTokens.REDUCE_MOTION_TRANSITION_SCALE,
                1e-5,
                "rm.trans.scale");
        checkEq(
                rmTrans.getBoolean("shaderEnabled"),
                MotionTokens.REDUCE_MOTION_TRANSITION_SHADER_ENABLED,
                "rm.trans.shaderEnabled");

        JSONObject rmTv = rmRules.getJSONObject("tvAndCardFocus");
        checkEq(rmTv.getString("mode"), MotionTokens.REDUCE_MOTION_TV_FOCUS_MODE, "rm.tv.mode");
        checkEq(
                rmTv.getInt("durationMs"),
                MotionTokens.REDUCE_MOTION_TV_FOCUS_DURATION_MS,
                "rm.tv.durationMs");
        checkClose(
                rmTv.getDouble("focusScale"),
                MotionTokens.REDUCE_MOTION_TV_FOCUS_SCALE,
                1e-5,
                "rm.tv.focusScale");
        checkEq(
                rmTv.getBoolean("keepFocusStrokeAndFill"),
                MotionTokens.REDUCE_MOTION_TV_FOCUS_KEEP_STROKE_AND_FILL,
                "rm.tv.keepFocusStrokeAndFill");

        JSONObject rmHud = rmRules.getJSONObject("hudOverlays");
        checkEq(rmHud.getString("mode"), MotionTokens.REDUCE_MOTION_HUD_MODE, "rm.hud.mode");
        checkEq(
                rmHud.getInt("durationMs"),
                MotionTokens.REDUCE_MOTION_HUD_DURATION_MS,
                "rm.hud.durationMs");
        checkEq(rmHud.getString("curve"), MotionTokens.REDUCE_MOTION_HUD_CURVE, "rm.hud.curve");
        checkClose(
                rmHud.getDouble("translateDp"),
                MotionTokens.REDUCE_MOTION_HUD_TRANSLATE_DP,
                1e-5,
                "rm.hud.translateDp");

        JSONObject rmAurora = rmRules.getJSONObject("auroraBackground");
        checkEq(
                rmAurora.getString("mode"),
                MotionTokens.REDUCE_MOTION_AURORA_MODE,
                "rm.aurora.mode");
        checkClose(
                rmAurora.getDouble("frozenTimeSec"),
                MotionTokens.REDUCE_MOTION_AURORA_FROZEN_TIME_SEC,
                1e-5,
                "rm.aurora.frozenTimeSec");
        checkEq(
                rmAurora.getBoolean("tickerRunning"),
                MotionTokens.REDUCE_MOTION_AURORA_TICKER_RUNNING,
                "rm.aurora.tickerRunning");

        JSONObject rmLogo = rmRules.getJSONObject("brandLogoLoader");
        checkEq(rmLogo.getString("mode"), MotionTokens.REDUCE_MOTION_LOGO_MODE, "rm.logo.mode");
        checkEq(
                rmLogo.getInt("cycleMs"),
                MotionTokens.REDUCE_MOTION_LOGO_CYCLE_MS,
                "rm.logo.cycleMs");
        checkClose(
                rmLogo.getDouble("minAlpha"),
                MotionTokens.REDUCE_MOTION_LOGO_MIN_ALPHA,
                1e-5,
                "rm.logo.minAlpha");
        checkClose(
                rmLogo.getDouble("maxAlpha"),
                MotionTokens.REDUCE_MOTION_LOGO_MAX_ALPHA,
                1e-5,
                "rm.logo.maxAlpha");

        JSONObject rtRules = a11y.getJSONObject("reduceTransparency").getJSONObject("rules");
        checkEq(
                parseArgb(rtRules.getString("glassSurfaceFillArgb")),
                MotionTokens.REDUCE_TRANSPARENCY_GLASS_SURFACE_FILL_ARGB,
                "rt.glassSurfaceFillArgb");
        checkEq(
                parseArgb(rtRules.getString("hudBackdropFillArgb")),
                MotionTokens.REDUCE_TRANSPARENCY_HUD_BACKDROP_FILL_ARGB,
                "rt.hudBackdropFillArgb");
        checkEq(
                rtRules.getBoolean("useBadgeSolidFill"),
                MotionTokens.REDUCE_TRANSPARENCY_USE_BADGE_SOLID_FILL,
                "rt.useBadgeSolidFill");
        checkClose(
                rtRules.getDouble("minBorderAlpha"),
                MotionTokens.REDUCE_TRANSPARENCY_MIN_BORDER_ALPHA,
                1e-5,
                "rt.minBorderAlpha");
        checkEq(
                rtRules.getBoolean("disableShaderRefraction"),
                MotionTokens.REDUCE_TRANSPARENCY_DISABLE_SHADER_REFRACTION,
                "rt.disableShaderRefraction");

        JSONObject scale = doc.getJSONObject("scaleTokens");
        JSONObject uiScale = scale.getJSONObject("androidUiScalePercent");
        checkClose(
                uiScale.getDouble("100"), MotionTokens.ANDROID_UI_SCALE_100, 1e-5, "uiScale.100");
        checkClose(
                uiScale.getDouble("110"), MotionTokens.ANDROID_UI_SCALE_110, 1e-5, "uiScale.110");
        checkClose(
                uiScale.getDouble("120"), MotionTokens.ANDROID_UI_SCALE_120, 1e-5, "uiScale.120");
        JSONObject textClamp = scale.getJSONObject("flutterTextScaleClamp");
        checkClose(
                textClamp.getDouble("min"),
                MotionTokens.FLUTTER_TEXT_SCALE_CLAMP_MIN,
                1e-5,
                "textClamp.min");
        checkClose(
                textClamp.getDouble("max"),
                MotionTokens.FLUTTER_TEXT_SCALE_CLAMP_MAX,
                1e-5,
                "textClamp.max");
        JSONObject tvFocus = scale.getJSONObject("tvFocus");
        checkClose(
                tvFocus.getDouble("posterScale"),
                MotionTokens.TV_FOCUS_POSTER_SCALE,
                1e-5,
                "tvFocus.posterScale");
        checkClose(
                tvFocus.getDouble("pillScale"),
                MotionTokens.TV_FOCUS_PILL_SCALE,
                1e-5,
                "tvFocus.pillScale");
        checkClose(
                tvFocus.getDouble("reducedScale"),
                MotionTokens.TV_FOCUS_REDUCED_SCALE,
                1e-5,
                "tvFocus.reducedScale");
        checkClose(
                tvFocus.getDouble("strokeWidthDp"),
                MotionTokens.TV_FOCUS_STROKE_WIDTH_DP,
                1e-5,
                "tvFocus.strokeWidthDp");
        checkEq(
                parseArgb(tvFocus.getString("strokeArgb")),
                MotionTokens.TV_FOCUS_STROKE_ARGB,
                "tvFocus.strokeArgb");

        JSONObject badgeMetrics = scale.getJSONObject("badgeMetrics");
        checkBadgeMetrics(
                badgeMetrics.getJSONObject("compact"),
                MotionTokens.BADGE_METRICS_COMPACT,
                "badgeMetrics.compact");
        checkBadgeMetrics(
                badgeMetrics.getJSONObject("startSpec"),
                MotionTokens.BADGE_METRICS_START_SPEC,
                "badgeMetrics.startSpec");
        checkBadgeMetrics(
                badgeMetrics.getJSONObject("tv"), MotionTokens.BADGE_METRICS_TV, "badgeMetrics.tv");

        JSONObject badgeStyles = doc.getJSONObject("badgeStyles");
        int styleCount = 0;
        for (Iterator<String> it = badgeStyles.keys(); it.hasNext(); ) {
            String key = it.next();
            JSONObject st = badgeStyles.getJSONObject(key);
            if ("liteTextOnly".equals(key)) {
                checkEq(
                        st.getString("separator"),
                        MotionTokens.LITE_BADGE_SEPARATOR,
                        "liteTextOnly.separator");
                checkEq(
                        parseArgb(st.getString("metaTextArgb")),
                        MotionTokens.LITE_BADGE_META_TEXT_ARGB,
                        "liteTextOnly.metaTextArgb");
                checkEq(
                        parseArgb(st.getString("chipIdleTextArgb")),
                        MotionTokens.LITE_BADGE_CHIP_IDLE_TEXT_ARGB,
                        "liteTextOnly.chipIdleTextArgb");
                checkEq(
                        parseArgb(st.getString("chipSelectedFillArgb")),
                        MotionTokens.LITE_BADGE_CHIP_SELECTED_FILL_ARGB,
                        "liteTextOnly.chipSelectedFillArgb");
                checkEq(
                        parseArgb(st.getString("chipFocusedFillArgb")),
                        MotionTokens.LITE_BADGE_CHIP_FOCUSED_FILL_ARGB,
                        "liteTextOnly.chipFocusedFillArgb");
                checkEq(
                        parseArgb(st.getString("chipFocusedTextArgb")),
                        MotionTokens.LITE_BADGE_CHIP_FOCUSED_TEXT_ARGB,
                        "liteTextOnly.chipFocusedTextArgb");
                checkEq(
                        st.getInt("maxInlineBadges"),
                        MotionTokens.LITE_BADGE_MAX_INLINE,
                        "liteTextOnly.maxInlineBadges");
                continue;
            }
            styleCount++;
            MotionTokens.BadgeStyle actual = MotionTokens.BADGE_STYLES.get(key);
            check(actual != null, "Missing badge style in MotionTokens.BADGE_STYLES: " + key);
            checkEq(parseArgb(st.getString("fillArgb")), actual.fillArgb, key + ".fillArgb");
            checkEq(parseArgb(st.getString("strokeArgb")), actual.strokeArgb, key + ".strokeArgb");
            checkEq(parseArgb(st.getString("textArgb")), actual.textArgb, key + ".textArgb");
            checkEq(
                    parseArgb(st.getString("solidFillArgb")),
                    actual.solidFillArgb,
                    key + ".solidFillArgb");
            checkEq(
                    parseArgb(st.getString("focusedFillArgb")),
                    actual.focusedFillArgb,
                    key + ".focusedFillArgb");
            checkEq(
                    parseArgb(st.getString("focusedStrokeArgb")),
                    actual.focusedStrokeArgb,
                    key + ".focusedStrokeArgb");
            checkEq(
                    parseArgb(st.getString("focusedTextArgb")),
                    actual.focusedTextArgb,
                    key + ".focusedTextArgb");
        }
        checkEq(styleCount, MotionTokens.BADGE_STYLES.size(), "badgeStyles.count");

        JSONObject aurora = doc.getJSONObject("auroraPalette");
        checkEq(
                parseArgb(aurora.getString("baseCanvasArgb")),
                MotionTokens.AURORA_BASE_CANVAS_ARGB,
                "aurora.baseCanvasArgb");
        checkEq(
                parseArgb(aurora.getString("waveBlueArgb")),
                MotionTokens.AURORA_WAVE_BLUE_ARGB,
                "aurora.waveBlueArgb");
        checkEq(
                parseArgb(aurora.getString("waveTealArgb")),
                MotionTokens.AURORA_WAVE_TEAL_ARGB,
                "aurora.waveTealArgb");
        checkEq(
                parseArgb(aurora.getString("waveIndigoArgb")),
                MotionTokens.AURORA_WAVE_INDIGO_ARGB,
                "aurora.waveIndigoArgb");
        checkEq(
                parseArgb(aurora.getString("wavePurpleArgb")),
                MotionTokens.AURORA_WAVE_PURPLE_ARGB,
                "aurora.wavePurpleArgb");
        checkClose(
                aurora.getDouble("timeRateRadPerSec"),
                MotionTokens.AURORA_TIME_RATE_RAD_PER_SEC,
                1e-5,
                "aurora.timeRateRadPerSec");
    }

    private static void verifySpringSolverAndAuroraWrap() {
        // Underdamped HUD popup spring: exhibits controlled overshoot and settles cleanly at 1.0.
        MotionTokens.SpringState hud = new MotionTokens.SpringState(0f, 0f);
        float maxHud = 0f;
        boolean moving = true;
        for (int i = 0; i < 180 && moving; i++) {
            moving =
                    MotionTokens.stepUnderdampedSpring(
                            hud, 1f, MotionTokens.SPRING_HUD_POPUP, 1f / 60f, 0.001f);
            if (hud.value > maxHud) maxHud = hud.value;
        }
        check(!moving, "hudPopup spring settles within 3s");
        checkClose(1.0, hud.value, 1e-4, "hudPopup settled value");
        check(
                maxHud > 1.001f && maxHud < 1.05f,
                "hudPopup subtle underdamped overshoot: " + maxHud);

        // Underdamped playerTransition spring settles cleanly to 1.0.
        MotionTokens.SpringState player = new MotionTokens.SpringState(0f, 0f);
        moving = true;
        for (int i = 0; i < 240 && moving; i++) {
            moving =
                    MotionTokens.stepUnderdampedSpring(
                            player, 1f, MotionTokens.SPRING_PLAYER_TRANSITION, 1f / 60f, 0.001f);
        }
        check(!moving, "playerTransition spring settles");
        checkClose(1.0, player.value, 1e-4, "playerTransition settled value");

        // Critically damped TV focus spring: zero overshoot and matches MotionSpring solver.
        MotionTokens.SpringState tv = new MotionTokens.SpringState(0f, 0f);
        MotionSpring legacy =
                new MotionSpring(
                        0f, (float) Math.sqrt(MotionTokens.SPRING_TV_FOCUS.stiffness), 0.001f);
        legacy.target(1f);
        for (int i = 0; i < 60; i++) {
            MotionTokens.stepUnderdampedSpring(
                    tv, 1f, MotionTokens.SPRING_TV_FOCUS, 1f / 60f, 0.001f);
            legacy.step(1f / 60f);
            check(tv.value <= 1.0001f, "critically damped tvFocus has zero overshoot: " + tv.value);
            checkClose(legacy.value, tv.value, 1e-3, "tvFocus matches MotionSpring step " + i);
        }

        // Overdamped spring settles monotonically without overshoot.
        MotionTokens.SpringPreset overdamped =
                new MotionTokens.SpringPreset(0.3f, 1.35f, 1f, 400f, 54f, 20f);
        MotionTokens.SpringState od = new MotionTokens.SpringState(0f, 0f);
        float prev = 0f;
        for (int i = 0; i < 180; i++) {
            MotionTokens.stepUnderdampedSpring(od, 1f, overdamped, 1f / 60f, 0.001f);
            check(od.value >= prev - 1e-5f && od.value <= 1.0001f, "overdamped monotonic");
            prev = od.value;
        }
        checkClose(1.0, od.value, 1e-3, "overdamped settled");

        // Aurora elapsed time wrap mod 6283.1853
        checkClose(0.0, MotionTokens.wrapAuroraElapsedSeconds(0.0), 1e-4, "auroraWrap(0)");
        checkClose(
                0.0,
                MotionTokens.wrapAuroraElapsedSeconds(MotionTokens.AURORA_WRAP_PERIOD_SEC),
                1e-3,
                "auroraWrap(period)");
        checkClose(
                12.5,
                MotionTokens.wrapAuroraElapsedSeconds(MotionTokens.AURORA_WRAP_PERIOD_SEC + 12.5),
                1e-3,
                "auroraWrap(period + 12.5)");
        checkClose(0.0, MotionTokens.wrapAuroraElapsedSeconds(Double.NaN), 1e-5, "auroraWrap(NaN)");
        check(
                MotionTokens.wrapAuroraElapsedSeconds(-1.0) > 6282.0f,
                "auroraWrap(-1) wraps positively");
    }

    private static void verifyPlayerTransitionHelper(Path root) throws Exception {
        // Tier resolution matrix
        check(
                PlayerTransitionHelper.resolveMode(34, false, true, true, true)
                        == PlayerTransitionHelper.Mode.REDUCED_FADE,
                "reduceMotion overrides API33 AGSL");
        check(
                PlayerTransitionHelper.resolveMode(34, true, true, true, true)
                        == PlayerTransitionHelper.Mode.REDUCED_FADE,
                "reduceMotion overrides TV");
        check(
                PlayerTransitionHelper.resolveMode(34, true, false, true, true)
                        == PlayerTransitionHelper.Mode.TV_LIGHTWEIGHT,
                "TV never uses AGSL shader");
        check(
                PlayerTransitionHelper.resolveMode(28, true, false, false, false)
                        == PlayerTransitionHelper.Mode.TV_LIGHTWEIGHT,
                "TV on Android 9 uses TV_LIGHTWEIGHT");
        check(
                PlayerTransitionHelper.resolveMode(33, false, false, true, true)
                        == PlayerTransitionHelper.Mode.API33_AGSL_SHADER,
                "API 33 mobile with backdrop uses AGSL");
        check(
                PlayerTransitionHelper.resolveMode(33, false, false, false, true)
                        == PlayerTransitionHelper.Mode.API23_HARDWARE_RENDERNODE,
                "API 33 AGSL unavailable falls back to RenderNode");
        check(
                PlayerTransitionHelper.resolveMode(33, false, false, true, false)
                        == PlayerTransitionHelper.Mode.API23_HARDWARE_RENDERNODE,
                "API 33 missing backdrop falls back to RenderNode");
        check(
                PlayerTransitionHelper.resolveMode(32, false, false, true, true)
                        == PlayerTransitionHelper.Mode.API23_HARDWARE_RENDERNODE,
                "API 32 uses RenderNode");
        check(
                PlayerTransitionHelper.resolveMode(23, false, false, false, false)
                        == PlayerTransitionHelper.Mode.API23_HARDWARE_RENDERNODE,
                "API 23 uses RenderNode");

        // Durations match motion-tokens.json
        checkEq(
                150,
                PlayerTransitionHelper.resolveDurationMs(
                        PlayerTransitionHelper.Mode.REDUCED_FADE, true),
                "REDUCED_FADE enter");
        checkEq(
                220,
                PlayerTransitionHelper.resolveDurationMs(
                        PlayerTransitionHelper.Mode.TV_LIGHTWEIGHT, true),
                "TV_LIGHTWEIGHT enter <= 220ms");
        checkEq(
                420,
                PlayerTransitionHelper.resolveDurationMs(
                        PlayerTransitionHelper.Mode.API33_AGSL_SHADER, true),
                "API33_AGSL enter");
        checkEq(
                300,
                PlayerTransitionHelper.resolveDurationMs(
                        PlayerTransitionHelper.Mode.API33_AGSL_SHADER, false),
                "API33_AGSL exit");
        checkEq(
                320,
                PlayerTransitionHelper.resolveDurationMs(
                        PlayerTransitionHelper.Mode.API23_HARDWARE_RENDERNODE, true),
                "API23 RenderNode enter");

        // Downsample bounds <= 1080px
        int[] wh = new int[2];
        PlayerTransitionHelper.computeDownsampleSize(2400, 1080, 1080, wh);
        checkEq(1080, wh[0], "downsample 2400x1080 w");
        checkEq(486, wh[1], "downsample 2400x1080 h");
        PlayerTransitionHelper.computeDownsampleSize(1080, 2340, 1080, wh);
        checkEq(498, wh[0], "downsample 1080x2340 w");
        checkEq(1080, wh[1], "downsample 1080x2340 h");
        PlayerTransitionHelper.computeDownsampleSize(800, 600, 1080, wh);
        checkEq(800, wh[0], "downsample 800x600 w unchanged");
        checkEq(600, wh[1], "downsample 800x600 h unchanged");

        // 16:9 Cinema Portal target rect inside safe insets
        float[] rect = new float[4];
        PlayerTransitionHelper.computePortalTargetRect(1080f, 2400f, 0f, 100f, 0f, 100f, rect);
        checkClose(0.0, rect[0], 1e-3, "portrait target left");
        checkClose(1080.0, rect[2], 1e-3, "portrait target width");
        checkClose(1080.0 * 9.0 / 16.0, rect[3], 1e-2, "portrait target height 16:9");

        // AGSL shader source contracts & NO software Camera+Matrix
        String agsl = PlayerTransitionHelper.AGSL_PLAYER_ENTER_SOURCE;
        check(agsl.contains("uniform float2 uBackdropTexSize;"), "AGSL declares uBackdropTexSize");
        check(agsl.contains("uniform float2 uPosterTexSize;"), "AGSL declares uPosterTexSize");
        check(agsl.contains("uBackdropTex.eval("), "AGSL scales eval with uBackdropTexSize");
        check(agsl.contains("uPosterAspect"), "AGSL preserves poster BoxFit.cover aspect");
        check(agsl.contains("composed.rgb * handoffAlpha"), "AGSL outputs premultiplied alpha");
        // S-02 hardening: NEVER paint opaque #121216 gray slab when poster is unavailable, and
        // gate portalPresence on uPosterAvailable > 0.5.
        check(
                !agsl.contains("0.071, 0.071, 0.086"),
                "S-02 AGSL must NOT paint opaque #121216 gray slab when poster is unavailable");
        check(
                agsl.contains("step(0.5, uPosterAvailable)") && agsl.contains("* hasPoster;"),
                "S-02 AGSL gates portalPresence on uPosterAvailable");

        // S-02 bounded poster card guard rejects full-bleed backdrops and accepts local cards.
        checkEq(
                false,
                PlayerTransitionHelper.isBoundedPosterCardBounds(1080f, 2400f, 1080f, 2400f),
                "S-02 rejects full-screen backdrop rect");
        checkEq(
                false,
                PlayerTransitionHelper.isBoundedPosterCardBounds(1080f, 1850f, 1080f, 2400f),
                "S-02 rejects 77%-height full-bleed portrait backdrop");
        checkEq(
                false,
                PlayerTransitionHelper.isBoundedPosterCardBounds(0f, 0f, 1080f, 2400f),
                "S-02 rejects empty rect");
        checkEq(
                true,
                PlayerTransitionHelper.isBoundedPosterCardBounds(240f, 360f, 1280f, 800f),
                "S-02 accepts bounded tablet 2:3 poster card");

        // S-02 BoxFit.cover UV math: 2:3 poster expanded into 16:9 viewport crops vertically
        // without horizontal stretching.
        float[] uvTopLeft = new float[2];
        float[] uvBotRight = new float[2];
        PlayerTransitionHelper.computePosterCoverUv(
                0f, 0f, 0f, 0f, 1280f, 720f, 2f / 3f, uvTopLeft);
        PlayerTransitionHelper.computePosterCoverUv(
                1280f, 720f, 0f, 0f, 1280f, 720f, 2f / 3f, uvBotRight);
        checkClose(0.0, uvTopLeft[0], 1e-4, "S-02 BoxFit.cover u left=0");
        checkClose(1.0, uvBotRight[0], 1e-4, "S-02 BoxFit.cover u right=1");
        checkClose(0.3125, uvTopLeft[1], 1e-4, "S-02 BoxFit.cover v top=0.3125");
        checkClose(0.6875, uvBotRight[1], 1e-4, "S-02 BoxFit.cover v bottom=0.6875");

        String helperSrc =
                new String(
                        Files.readAllBytes(
                                root.resolve(
                                        "android-tv/src/main/java/com/pilipala/marcomovie/PlayerTransitionHelper.java")),
                        StandardCharsets.UTF_8);
        check(
                !helperSrc.contains("android.graphics.Camera"),
                "PlayerTransitionHelper must NOT use software android.graphics.Camera");

        // Round 2 MAJOR-3 regression: shared-bounds deltas in detailRoot space (nested poster)
        float[] sbDeltas = new float[4];
        PlayerTransitionHelper.computeSharedBoundsDeltas(
                40f, 620f, 280f, 980f, 140f, 220f, 300f, 450f, sbDeltas);
        checkClose(0.8, sbDeltas[0], 1e-4, "sharedBounds startScaleX");
        checkClose(0.8, sbDeltas[1], 1e-4, "sharedBounds startScaleY");
        checkClose(-130.0, sbDeltas[2], 1e-3, "sharedBounds startDx in detailRoot space");
        checkClose(355.0, sbDeltas[3], 1e-3, "sharedBounds startDy in detailRoot space");

        // Verify source contracts for Round 2 Android fixes (MAJOR-1, MAJOR-3, MINOR-1, MINOR-3)
        check(
                helperSrc.contains("offsetDescendantRectToMyCoords"),
                "animateSharedBoundsEnter projects descendant rect into detailRoot coordinates");
        check(
                helperSrc.contains("DeferredSharedBoundsHandle")
                        && helperSrc.contains("OnPreDrawListener"),
                "animateSharedBoundsEnter defers pre-layout frame-0 calls via OnPreDrawListener");
        check(
                helperSrc.contains("detailLayer.setAlpha(0f);"),
                "Api33AgslRunner hides detailLayer immediately under AGSL overlay");
        check(
                helperSrc.contains("restoreAlphaAfterComplete"),
                "REDUCED_FADE restores detailLayer alpha cleanly after onComplete");
        check(
                helperSrc.contains("animator.removeAllUpdateListeners();")
                        && helperSrc.contains("animator.removeAllListeners();"),
                "AtomicFinish detaches animator listeners on finish/cancel");
    }

    private static void verifyAuroraAndBrandLogoLoader() {
        // Round 2 MINOR-2 regression: dynamic MainActivity.reduced tracking vs explicit override
        checkEq(
                false,
                AuroraSurfaceView.resolveEffectiveReducedMotion(null, false),
                "aurora follows host reduced=false");
        checkEq(
                true,
                AuroraSurfaceView.resolveEffectiveReducedMotion(null, true),
                "aurora follows host reduced=true dynamically");
        checkEq(
                false,
                AuroraSurfaceView.resolveEffectiveReducedMotion(Boolean.FALSE, true),
                "aurora explicit override false wins over host");
        checkEq(
                true,
                AuroraSurfaceView.resolveEffectiveReducedMotion(Boolean.TRUE, false),
                "aurora explicit override true wins over host");
        checkEq(
                true,
                BrandLogoLoaderView.resolveEffectiveReducedMotion(null, true),
                "brandLoader follows host reduced=true dynamically");
        checkEq(
                false,
                BrandLogoLoaderView.resolveEffectiveReducedMotion(Boolean.FALSE, true),
                "brandLoader explicit override false wins over host");

        // AuroraSurfaceView lifecycle safety
        check(
                AuroraSurfaceView.shouldRunLoop(true, true, true, true, false, false, 0.62f),
                "aurora runs when attached, visible, active, non-reduced, non-TV");
        check(
                !AuroraSurfaceView.shouldRunLoop(false, true, true, true, false, false, 0.62f),
                "aurora stops when detached");
        check(
                !AuroraSurfaceView.shouldRunLoop(true, false, true, true, false, false, 0.62f),
                "aurora stops when view invisible");
        check(
                !AuroraSurfaceView.shouldRunLoop(true, true, false, true, false, false, 0.62f),
                "aurora stops when backgrounded (window invisible)");
        check(
                !AuroraSurfaceView.shouldRunLoop(true, true, true, false, false, false, 0.62f),
                "aurora stops when inactive (e.g. during playback)");
        check(
                !AuroraSurfaceView.shouldRunLoop(true, true, true, true, true, false, 0.62f),
                "aurora stops under reduceMotion");
        check(
                !AuroraSurfaceView.shouldRunLoop(true, true, true, true, false, true, 0.62f),
                "aurora never runs on Android TV");
        check(
                !AuroraSurfaceView.shouldRunLoop(true, true, true, true, false, false, 0.0f),
                "aurora stops when strength == 0");

        String auroraAgsl = AuroraSurfaceView.AGSL_AURORA_SOURCE;
        check(!auroraAgsl.contains("uniform shader"), "aurora AGSL has zero texture samplers");
        check(auroraAgsl.contains("uElapsedSec * 0.38"), "aurora AGSL uses 0.38 rate");
        check(auroraAgsl.contains("half4(half3(color), 1.0)"), "aurora AGSL opaque premul output");

        // BrandLogoLoaderView (F8) 1.6s trace + sheen + reduce-motion breathing
        checkClose(0.0, BrandLogoLoaderView.computeStrokeFraction(0.0f, false), 1e-5, "stroke@0");
        float midStroke = BrandLogoLoaderView.computeStrokeFraction(0.28f, false);
        check(midStroke > 0.45f && midStroke < 0.55f, "stroke@0.28 mid: " + midStroke);
        checkClose(
                1.0, BrandLogoLoaderView.computeStrokeFraction(0.56f, false), 1e-5, "stroke@0.56");
        checkClose(
                1.0, BrandLogoLoaderView.computeStrokeFraction(0.95f, false), 1e-5, "stroke@0.95");

        check(BrandLogoLoaderView.computeSheenProgress(0.20f, false) < 0f, "sheen off before 0.48");
        float midSheen = BrandLogoLoaderView.computeSheenProgress(0.69f, false);
        check(midSheen > 0.45f && midSheen < 0.55f, "sheen@0.69 mid: " + midSheen);
        check(BrandLogoLoaderView.computeSheenProgress(0.95f, false) < 0f, "sheen off after 0.90");

        // Reduce-motion: static full ribbon + calm breathing alpha strictly in [0.72, 1.0]
        for (int i = 0; i <= 100; i++) {
            float p = i / 100f;
            checkClose(
                    1.0,
                    BrandLogoLoaderView.computeStrokeFraction(p, true),
                    1e-5,
                    "rm stroke always 1.0 at " + p);
            check(
                    BrandLogoLoaderView.computeSheenProgress(p, true) < 0f,
                    "rm sheen always off at " + p);
            float alpha = BrandLogoLoaderView.computeRibbonAlpha(p, true);
            check(
                    alpha >= MotionTokens.REDUCE_MOTION_LOGO_MIN_ALPHA - 1e-4f
                            && alpha <= MotionTokens.REDUCE_MOTION_LOGO_MAX_ALPHA + 1e-4f,
                    "rm breathing alpha in [0.72, 1.0] at " + p + " got=" + alpha);
        }
        checkClose(
                1.0, BrandLogoLoaderView.computeRibbonAlpha(0.0f, true), 1e-4, "rm alpha peak@0");
        checkClose(
                0.72, BrandLogoLoaderView.computeRibbonAlpha(0.5f, true), 1e-4, "rm alpha min@0.5");

        // BrandLogoLoaderView lifecycle gating
        check(BrandLogoLoaderView.shouldRunLoop(true, true, true, true), "logo runs visible");
        check(!BrandLogoLoaderView.shouldRunLoop(false, true, true, true), "logo stops detached");
        check(!BrandLogoLoaderView.shouldRunLoop(true, false, true, true), "logo stops invisible");
        check(!BrandLogoLoaderView.shouldRunLoop(true, true, false, true), "logo stops background");
        check(!BrandLogoLoaderView.shouldRunLoop(true, true, true, false), "logo stops inactive");
    }

    public static void main(String[] args) throws Exception {
        Path root = args.length > 0 ? Paths.get(args[0]) : Paths.get(".").toAbsolutePath();
        verifyMotionTokensJsonParity(root);
        verifySpringSolverAndAuroraWrap();
        verifyPlayerTransitionHelper(root);
        verifyAuroraAndBrandLogoLoader();
        System.out.println("PASS MotionTokenChecks (" + checks + " assertions)");
    }
}
