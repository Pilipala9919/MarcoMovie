// Copyright (C) 2026 Pilipala
// SPDX-License-Identifier: GPL-3.0-only
package com.pilipala.marcomovie;

import android.animation.ValueAnimator;
import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.BitmapShader;
import android.graphics.Canvas;
import android.graphics.Rect;
import android.graphics.RectF;
import android.graphics.RuntimeShader;
import android.os.Build;
import android.os.Handler;
import android.os.SystemClock;
import android.view.View;
import android.widget.FrameLayout;
import android.widget.ImageView;
import com.pilipala.glass.GlassworkMaterial;
import com.pilipala.glass.GlassworkSurface;
import com.pilipala.marcomovie.DanmuProvider.BlockFilter;
import com.pilipala.marcomovie.DanmuProvider.DanmuItem;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.List;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;

/**
 * Offline JVM regression suite for Wave 2 Android wiring:
 *
 * <ol>
 *   <li>PlaybackControls child Z-order strictly Video(0) -> DanmakuView(1) -> SubtitleOverlayView(2)
 *       -> HUD(3+).
 *   <li>API 23-32 GlassworkSurface freeze on transition start and idempotent unfreeze on animation
 *       end, cancel, and view detach.
 *   <li>FocusMotion Prefs.REDUCED 1.0f scale guard with high-contrast focus stroke retention.
 *   <li>TvV17DetailScreen.formatEpisodeFileCaption / extractFilenameFromUrl literal '+' and %XX
 *       UTF-8 percent-decoding without URLDecoder.
 *   <li>Onboarding, FirstPlayGestureHint, Danmu default empty server / TV adaptive row clamp, and
 *       wiring invariants.
 * </ol>
 */
public final class Wave2AndroidWireChecks {
    private static int checks;

    private static void check(boolean condition, String message) {
        checks++;
        if (!condition) {
            throw new AssertionError("FAILED: " + message);
        }
    }

    private static void checkEq(int expected, int actual, String label) {
        check(expected == actual, label + " expected=" + expected + " actual=" + actual);
    }

    private static void checkEq(boolean expected, boolean actual, String label) {
        check(expected == actual, label + " expected=" + expected + " actual=" + actual);
    }

    private static void checkEq(String expected, String actual, String label) {
        check(
                expected != null && expected.equals(actual),
                label + " expected=[" + expected + "] actual=[" + actual + "]");
    }

    private static void checkClose(float expected, float actual, float eps, String label) {
        check(
                Math.abs(expected - actual) <= eps,
                label + " expected=" + expected + " actual=" + actual);
    }

    private static void testPlaybackControlsZOrder() {
        Context ctx = new Context();
        FrameLayout playbackLayer = new FrameLayout(ctx);

        // Mirror PlaybackController.playerPage + PlayerChrome mount sequence:
        // [0] Video surface, [1..N] HUD overlays.
        View videoSurface = new View(ctx);
        videoSurface.setTag("video-surface");
        View hudOverlay = new View(ctx);
        hudOverlay.setTag("player-hud-overlay");
        View loadingPill = new View(ctx);
        loadingPill.setTag("player-loading");
        View startSpecBanner = new View(ctx);
        startSpecBanner.setTag("player-start-spec");
        View slimProgress = new View(ctx);
        slimProgress.setTag("player-slim-progress");
        View hintSlot = new View(ctx);
        hintSlot.setTag("player-first-play-gesture-hint-slot");

        playbackLayer.addView(videoSurface, new FrameLayout.LayoutParams(-1, -1));
        playbackLayer.addView(hudOverlay, new FrameLayout.LayoutParams(-1, -1));
        playbackLayer.addView(loadingPill, new FrameLayout.LayoutParams(-2, -2));
        playbackLayer.addView(startSpecBanner, new FrameLayout.LayoutParams(-2, -2));
        playbackLayer.addView(slimProgress, new FrameLayout.LayoutParams(-1, 6));
        playbackLayer.addView(hintSlot, new FrameLayout.LayoutParams(-1, -1));

        View danmakuView = new View(ctx);
        danmakuView.setTag("danmaku-view");
        View subtitleView = new View(ctx);
        subtitleView.setTag("subtitle-overlay-view");

        PlaybackControls.mountMediaOverlaysInZOrder(
                playbackLayer,
                danmakuView,
                new FrameLayout.LayoutParams(-1, -1),
                subtitleView,
                new FrameLayout.LayoutParams(-1, -1));

        // Append trailing HUD pills just as PlaybackControls does after mounting overlays.
        View skipCountdownPill = new View(ctx);
        skipCountdownPill.setTag("skip-countdown-pill");
        View sleepWarningPill = new View(ctx);
        sleepWarningPill.setTag("sleep-warning-pill");
        playbackLayer.addView(skipCountdownPill, new FrameLayout.LayoutParams(-2, -2));
        playbackLayer.addView(sleepWarningPill, new FrameLayout.LayoutParams(-2, -2));

        int idxVideo = playbackLayer.indexOfChild(videoSurface);
        int idxDanmu = playbackLayer.indexOfChild(danmakuView);
        int idxSubtitle = playbackLayer.indexOfChild(subtitleView);
        int idxHud = playbackLayer.indexOfChild(hudOverlay);
        int idxLoading = playbackLayer.indexOfChild(loadingPill);
        int idxSpec = playbackLayer.indexOfChild(startSpecBanner);
        int idxSlim = playbackLayer.indexOfChild(slimProgress);
        int idxHint = playbackLayer.indexOfChild(hintSlot);
        int idxSkip = playbackLayer.indexOfChild(skipCountdownPill);
        int idxSleep = playbackLayer.indexOfChild(sleepWarningPill);

        checkEq(0, idxVideo, "zorder.video");
        checkEq(1, idxDanmu, "zorder.danmaku");
        checkEq(2, idxSubtitle, "zorder.subtitle");
        check(idxVideo < idxDanmu, "video below danmaku");
        check(idxDanmu < idxSubtitle, "danmaku strictly below subtitle");
        check(idxSubtitle < idxHud, "subtitle strictly below HUD overlay");
        check(idxSubtitle < idxLoading, "subtitle strictly below loading pill");
        check(idxSubtitle < idxSpec, "subtitle strictly below start spec banner");
        check(idxSubtitle < idxSlim, "subtitle strictly below slim progress");
        check(idxSubtitle < idxHint, "subtitle strictly below first-play hint slot");
        check(idxSubtitle < idxSkip, "subtitle strictly below skip countdown pill");
        check(idxSubtitle < idxSleep, "subtitle strictly below sleep warning pill");

        // Re-mounting already attached views must preserve exact Video -> Danmaku -> Subtitle ->
        // HUD order.
        PlaybackControls.mountMediaOverlaysInZOrder(
                playbackLayer,
                danmakuView,
                new FrameLayout.LayoutParams(-1, -1),
                subtitleView,
                new FrameLayout.LayoutParams(-1, -1));
        checkEq(0, playbackLayer.indexOfChild(videoSurface), "remount.zorder.video");
        checkEq(1, playbackLayer.indexOfChild(danmakuView), "remount.zorder.danmaku");
        checkEq(2, playbackLayer.indexOfChild(subtitleView), "remount.zorder.subtitle");
        checkEq(3, playbackLayer.indexOfChild(hudOverlay), "remount.zorder.hud");

        // Defensive Z-order check (#12): mounting subtitle alone when a DanmakuView child is
        // already attached at index 1 must place Subtitle strictly ABOVE DanmakuView (index 2).
        FrameLayout incrementalLayer = new FrameLayout(ctx);
        View incVideo = new View(ctx);
        View incDanmaku = new View(ctx);
        incDanmaku.setTag("danmaku-view");
        View incHud = new View(ctx);
        incrementalLayer.addView(incVideo, new FrameLayout.LayoutParams(-1, -1));
        incrementalLayer.addView(incDanmaku, new FrameLayout.LayoutParams(-1, -1));
        incrementalLayer.addView(incHud, new FrameLayout.LayoutParams(-1, -1));
        View incSubtitle = new View(ctx);
        PlaybackControls.mountMediaOverlaysInZOrder(
                incrementalLayer, null, null, incSubtitle, new FrameLayout.LayoutParams(-1, -1));
        checkEq(0, incrementalLayer.indexOfChild(incVideo), "incremental.zorder.video");
        checkEq(1, incrementalLayer.indexOfChild(incDanmaku), "incremental.zorder.danmaku");
        checkEq(2, incrementalLayer.indexOfChild(incSubtitle), "incremental.zorder.subtitle");
        checkEq(3, incrementalLayer.indexOfChild(incHud), "incremental.zorder.hud");

        // Defensive Z-order check: inverted [Video, Subtitle, Danmaku, HUD] restored cleanly.
        FrameLayout invertedLayer = new FrameLayout(ctx);
        View invVideo = new View(ctx);
        View invSubtitle = new View(ctx);
        View invDanmaku = new View(ctx);
        invDanmaku.setTag("danmaku-view");
        View invHud = new View(ctx);
        invertedLayer.addView(invVideo, new FrameLayout.LayoutParams(-1, -1));
        invertedLayer.addView(invSubtitle, new FrameLayout.LayoutParams(-1, -1));
        invertedLayer.addView(invDanmaku, new FrameLayout.LayoutParams(-1, -1));
        invertedLayer.addView(invHud, new FrameLayout.LayoutParams(-1, -1));
        PlaybackControls.mountMediaOverlaysInZOrder(
                invertedLayer,
                invDanmaku,
                new FrameLayout.LayoutParams(-1, -1),
                invSubtitle,
                new FrameLayout.LayoutParams(-1, -1));
        checkEq(0, invertedLayer.indexOfChild(invVideo), "inverted.zorder.video");
        checkEq(1, invertedLayer.indexOfChild(invDanmaku), "inverted.zorder.danmaku");
        checkEq(2, invertedLayer.indexOfChild(invSubtitle), "inverted.zorder.subtitle");
        checkEq(3, invertedLayer.indexOfChild(invHud), "inverted.zorder.hud");
    }

    private static void testApi23GlassFreezeLifecycle() {
        // 1. Unit check GlassFreezeController ref-counting & GlassworkSurface option gate.
        AtomicInteger unfreezeEvents = new AtomicInteger();
        MainActivity.GlassFreezeController controller =
                new MainActivity.GlassFreezeController(unfreezeEvents::incrementAndGet);
        checkEq(false, controller.isFrozen(), "glass.initial.unfrozen");
        checkEq(false, controller.shouldReduceTransparency(false), "glass.gate.normal");
        checkEq(true, controller.shouldReduceTransparency(true), "glass.gate.userReduced");

        controller.setGlassFrozen(true);
        checkEq(true, controller.isFrozen(), "glass.frozen.afterTrue");
        // L-03: freezing glass MUST NOT snap cached material to solid tint via reduceTransparency
        checkEq(
                false,
                controller.shouldReduceTransparency(false),
                "glass.gate.frozenPreservesCachedMaterial");
        checkEq(
                true,
                controller.shouldReduceTransparency(true),
                "glass.gate.frozenRespectsUserReducedTransparency");
        checkEq(0, unfreezeEvents.get(), "glass.unfreezeCount.whileFrozen");

        // Nested freeze stays frozen until matching unfreeze.
        controller.setGlassFrozen(true);
        controller.setGlassFrozen(false);
        checkEq(true, controller.isFrozen(), "glass.nested.stillFrozen");
        checkEq(0, unfreezeEvents.get(), "glass.nested.noEarlyUnfreeze");

        controller.setGlassFrozen(false);
        checkEq(false, controller.isFrozen(), "glass.nested.unfrozen");
        checkEq(1, unfreezeEvents.get(), "glass.nested.unfreezeCallbackOnce");
        checkEq(false, controller.shouldReduceTransparency(false), "glass.gate.restored");

        // Redundant unfreeze must remain a safe no-op.
        controller.setGlassFrozen(false);
        checkEq(false, controller.isFrozen(), "glass.extraUnfreeze.safe");
        checkEq(1, unfreezeEvents.get(), "glass.extraUnfreeze.noDoubleCallback");

        // forceUnfreeze clears arbitrary depth once.
        controller.setGlassFrozen(true);
        controller.setGlassFrozen(true);
        controller.forceUnfreeze();
        checkEq(false, controller.isFrozen(), "glass.forceUnfreeze.cleared");
        checkEq(2, unfreezeEvents.get(), "glass.forceUnfreeze.callback");

        // 2. Real PlayerTransitionHelper API 23-32 RenderNode transition: normal end.
        Context ctx = new Context();
        View detailLayer = new View(ctx);
        View posterView = new View(ctx);
        AtomicInteger completeEnd = new AtomicInteger();
        AtomicInteger unfreezeEnd = new AtomicInteger();
        MainActivity.GlassFreezeController freezeEnd =
                new MainActivity.GlassFreezeController(unfreezeEnd::incrementAndGet);

        ValueAnimator.clearLastStarted();
        PlayerTransitionHelper.TransitionHandle handleEnd =
                PlayerTransitionHelper.runApi23HardwareRenderNodeTransition(
                        detailLayer, posterView, freezeEnd, completeEnd::incrementAndGet);
        ValueAnimator animEnd = ValueAnimator.getLastStarted();
        check(animEnd != null, "api23.end.animatorStarted");
        checkEq(MotionTokens.DURATION_EMPHASIZED_MS, (int) animEnd.getDuration(), "api23.duration");
        checkEq(true, freezeEnd.isFrozen(), "api23.end.frozenDuringTransition");
        checkEq(View.LAYER_TYPE_HARDWARE, detailLayer.getLayerType(), "api23.end.hwLayerDetail");
        checkEq(View.LAYER_TYPE_HARDWARE, posterView.getLayerType(), "api23.end.hwLayerPoster");

        animEnd.stepTo(0.5f);
        checkClose(0.96f, detailLayer.getScaleX(), 1e-4f, "api23.mid.detailScale");
        checkClose(0.5f, detailLayer.getAlpha(), 1e-4f, "api23.mid.detailAlpha");
        checkClose(1.05f, posterView.getScaleX(), 1e-4f, "api23.mid.posterScale");
        checkEq(true, freezeEnd.isFrozen(), "api23.mid.stillFrozen");

        animEnd.finish();
        checkEq(1, completeEnd.get(), "api23.end.onCompleteOnce");
        checkEq(false, freezeEnd.isFrozen(), "api23.end.unfrozen");
        checkEq(1, unfreezeEnd.get(), "api23.end.unfreezeCallbackOnce");
        checkClose(1f, detailLayer.getScaleX(), 1e-4f, "api23.end.detailScaleRestored");
        checkClose(1f, detailLayer.getAlpha(), 1e-4f, "api23.end.detailAlphaRestored");
        checkClose(0f, detailLayer.getTranslationY(), 1e-4f, "api23.end.detailTransRestored");
        checkEq(View.LAYER_TYPE_NONE, detailLayer.getLayerType(), "api23.end.detailLayerRestored");
        checkClose(1f, posterView.getScaleX(), 1e-4f, "api23.end.posterScaleRestored");
        checkClose(1f, posterView.getAlpha(), 1e-4f, "api23.end.posterAlphaRestored");
        checkEq(View.LAYER_TYPE_NONE, posterView.getLayerType(), "api23.end.posterLayerRestored");
        checkEq(0, detailLayer.getAttachListenerCount(), "api23.end.detachListenerRemoved");
        handleEnd.cancel(); // idempotent post-end cancel
        checkEq(1, unfreezeEnd.get(), "api23.end.postCancelNoDoubleUnfreeze");

        // 3. Real PlayerTransitionHelper API 23-32 RenderNode transition: explicit cancel.
        AtomicInteger completeCancel = new AtomicInteger();
        AtomicInteger unfreezeCancel = new AtomicInteger();
        MainActivity.GlassFreezeController freezeCancel =
                new MainActivity.GlassFreezeController(unfreezeCancel::incrementAndGet);
        View detailCancel = new View(ctx);
        View posterCancel = new View(ctx);

        ValueAnimator.clearLastStarted();
        PlayerTransitionHelper.TransitionHandle handleCancel =
                PlayerTransitionHelper.runApi23HardwareRenderNodeTransition(
                        detailCancel, posterCancel, freezeCancel, completeCancel::incrementAndGet);
        ValueAnimator animCancel = ValueAnimator.getLastStarted();
        animCancel.stepTo(0.35f);
        checkEq(true, freezeCancel.isFrozen(), "api23.cancel.frozenBeforeCancel");
        handleCancel.cancel();
        checkEq(1, completeCancel.get(), "api23.cancel.onCompleteOnce");
        checkEq(false, freezeCancel.isFrozen(), "api23.cancel.unfrozen");
        checkEq(1, unfreezeCancel.get(), "api23.cancel.unfreezeCallbackOnce");
        checkClose(1f, detailCancel.getAlpha(), 1e-4f, "api23.cancel.alphaRestored");
        checkClose(1f, detailCancel.getScaleX(), 1e-4f, "api23.cancel.scaleRestored");
        checkEq(0, detailCancel.getAttachListenerCount(), "api23.cancel.detachListenerRemoved");

        // 4. Real PlayerTransitionHelper API 23-32 RenderNode transition: view detach mid-flight.
        AtomicInteger completeDetach = new AtomicInteger();
        AtomicInteger unfreezeDetach = new AtomicInteger();
        MainActivity.GlassFreezeController freezeDetach =
                new MainActivity.GlassFreezeController(unfreezeDetach::incrementAndGet);
        View detailDetach = new View(ctx);
        View posterDetach = new View(ctx);

        ValueAnimator.clearLastStarted();
        PlayerTransitionHelper.runApi23HardwareRenderNodeTransition(
                detailDetach, posterDetach, freezeDetach, completeDetach::incrementAndGet);
        ValueAnimator animDetach = ValueAnimator.getLastStarted();
        animDetach.stepTo(0.25f);
        checkEq(true, freezeDetach.isFrozen(), "api23.detach.frozenBeforeDetach");
        checkEq(1, detailDetach.getAttachListenerCount(), "api23.detach.listenerAttached");
        detailDetach.dispatchDetachedFromWindow();
        checkEq(1, completeDetach.get(), "api23.detach.onCompleteOnce");
        checkEq(false, freezeDetach.isFrozen(), "api23.detach.unfrozen");
        checkEq(1, unfreezeDetach.get(), "api23.detach.unfreezeCallbackOnce");
        checkClose(1f, detailDetach.getAlpha(), 1e-4f, "api23.detach.alphaRestored");
        checkClose(1f, posterDetach.getScaleX(), 1e-4f, "api23.detach.posterScaleRestored");
        checkEq(0, detailDetach.getAttachListenerCount(), "api23.detach.listenerRemoved");
    }

    private static void testFocusMotionReducedGuard() {
        // Reduced motion MUST clamp scale to strictly 1.0f regardless of gain, emphasis, or press.
        checkClose(
                1.0f,
                FocusMotion.resolveScale(1.06f, 1.0f, 0.0f, true),
                1e-6f,
                "focus.reduced.focused");
        checkClose(
                1.0f,
                FocusMotion.resolveScale(1.08f, 1.0f, 1.0f, true),
                1e-6f,
                "focus.reduced.pressed");
        checkClose(
                1.0f,
                FocusMotion.resolveScale(1.05f, 0.0f, 0.0f, true),
                1e-6f,
                "focus.reduced.idle");

        // Normal motion scales smoothly by gain and press compression.
        checkClose(
                1.06f,
                FocusMotion.resolveScale(1.06f, 1.0f, 0.0f, false),
                1e-5f,
                "focus.normal.focused");
        checkClose(
                1.06f * 0.97f,
                FocusMotion.resolveScale(1.06f, 1.0f, 1.0f, false),
                1e-5f,
                "focus.normal.pressed");
        checkClose(
                1.0f,
                FocusMotion.resolveScale(1.06f, 0.0f, 0.0f, false),
                1e-5f,
                "focus.normal.idle");

        // High-contrast focus stroke MUST remain visible under Prefs.REDUCED even when
        // border=false.
        checkEq(
                MotionTokens.TV_FOCUS_STROKE_ARGB,
                FocusMotion.resolveStrokeColor(false, 1.0f, true),
                "focus.reduced.strokeKeptEvenWithoutBorder");
        checkEq(
                MotionTokens.TV_FOCUS_STROKE_ARGB,
                FocusMotion.resolveStrokeColor(true, 0.8f, true),
                "focus.reduced.strokeKeptWithBorder");
        checkEq(
                0x00f5f5f7,
                FocusMotion.resolveStrokeColor(true, 0.0f, true),
                "focus.reduced.unfocusedTransparent");
        checkEq(
                0x00f5f5f7,
                FocusMotion.resolveStrokeColor(false, 1.0f, false),
                "focus.normal.noBorderStaysTransparent");
        checkEq(
                MotionTokens.TV_FOCUS_STROKE_ARGB,
                FocusMotion.resolveStrokeColor(true, 1.0f, false),
                "focus.normal.borderHighlighted");
    }

    private static void testTvV17EpisodeFileCaptionDecoding() {
        // Direct filename extraction tests covering literal '+', %2B, HDR10+, DD+, UTF-8, malformed
        // %ZZ/%2.
        checkEq(
                "Film.2025.2160p.HDR10+.DD+.5.1.mkv",
                TvV17DetailScreen.extractFilenameFromUrl(
                        "https://media.test/videos/Film.2025.2160p.HDR10+.DD+.5.1.mkv"),
                "caption.literalPlus.HDR10+_DD+");
        checkEq(
                "Film.HDR10+.DD+.Atmos.mkv",
                TvV17DetailScreen.extractFilenameFromUrl(
                        "https://media.test/videos/Film.HDR10%2B.DD%2B.Atmos.mkv"),
                "caption.percent2B");
        checkEq(
                "Film.HDR10+.DD+.Atmos.mp4",
                TvV17DetailScreen.extractFilenameFromUrl(
                        "https://media.test/videos/Film.HDR10+.DD%2B.Atmos.mp4?token=a+b#t=5"),
                "caption.mixedPlusAndQuery");
        checkEq(
                "中文.2160p.HDR10+.DD+.mkv",
                TvV17DetailScreen.extractFilenameFromUrl(
                        "https://media.test/v/%E4%B8%AD%E6%96%87.2160p.HDR10+.DD+.mkv"),
                "caption.utf8ChineseAndPlus");
        checkEq(
                "Clip.%ZZ.HDR10+.mp4",
                TvV17DetailScreen.extractFilenameFromUrl(
                        "https://media.test/v/Clip.%ZZ.HDR10+.mp4"),
                "caption.malformedPercentZZ");
        checkEq(
                "Clip.DD+.%2.mkv",
                TvV17DetailScreen.extractFilenameFromUrl("https://media.test/v/Clip.DD+.%2.mkv"),
                "caption.malformedPercent2");
        checkEq(
                "",
                TvV17DetailScreen.extractFilenameFromUrl("https://media.test/v/Clip.mp4%2"),
                "caption.trailingIncompletePercentSafe");
        checkEq(
                "",
                TvV17DetailScreen.extractFilenameFromUrl("https://media.test/hls/index.m3u8"),
                "caption.genericManifestIgnored");
        checkEq(
                "",
                TvV17DetailScreen.extractFilenameFromUrl(
                        "https://media.test/v/0123456789abcdef1234.mp4"),
                "caption.hexHashIgnored");

        // Minor 3 (#11 & #14): Pathless URLs carrying '/' in query or fragment must NOT extract
        // fake filenames.
        String pathlessHost = "https://host.example";
        checkEq(
                "",
                TvV17DetailScreen.extractRawHttpPath(pathlessHost + "?file=/a/b.mkv"),
                "caption.pathlessQuerySlash.rawPathEmpty");
        checkEq(
                "",
                TvV17DetailScreen.extractFilenameFromUrl(pathlessHost + "?file=/a/b.mkv"),
                "caption.pathlessQuerySlash.ignored");
        checkEq(
                "",
                TvV17DetailScreen.extractFilenameFromUrl(pathlessHost + "#x/b.mkv"),
                "caption.pathlessFragmentSlash.ignored");
        checkEq(
                "",
                TvV17DetailScreen.extractFilenameFromUrl(
                        pathlessHost + "?redirect=/clip.HDR10+.mp4"),
                "caption.pathlessQueryRedirect.ignored");
        checkEq(
                "Film.HDR10+.mkv",
                TvV17DetailScreen.extractFilenameFromUrl(
                        "https://host.example/v/Film.HDR10+.mkv?redirect=/other.mp4#frag/foo.mkv"),
                "caption.realPathWithQueryAndFragmentSlashes");

        // Full formatEpisodeFileCaption integration test.
        Cms.Line line = new Cms.Line();
        line.name = "原画线路";
        Cms.Episode ep = new Cms.Episode();
        ep.name = "正片";
        ep.url =
                "https://media.example/lib/%E4%B8%AD%E6%96%87.2160p.HDR10+.DD%2B.Atmos.mkv?sig=1+2";
        checkEq(
                "原画线路  ·  正片 · 中文.2160p.HDR10+.DD+.Atmos.mkv",
                TvV17DetailScreen.formatEpisodeFileCaption(line, ep),
                "formatEpisodeFileCaption.full");

        Cms.Episode malformedEp = new Cms.Episode();
        malformedEp.name = "HD";
        malformedEp.url = "https://media.example/lib/Movie.%ZZ.%2.HDR10+.mp4";
        checkEq(
                "原画线路  ·  HD · Movie.%ZZ.%2.HDR10+.mp4",
                TvV17DetailScreen.formatEpisodeFileCaption(line, malformedEp),
                "formatEpisodeFileCaption.malformedPercentPreserved");
    }

    private static void testOnboardingFirstPlayAndDanmuPolicies() {
        // 1. Onboarding first launch & settings replay flow.
        OnboardingScreen.MemoryStore store = new OnboardingScreen.MemoryStore();
        checkEq(
                true,
                OnboardingScreen.Controller.shouldShowOnLaunch(store),
                "onboarding.firstLaunchShows");
        OnboardingScreen.Controller ob = new OnboardingScreen.Controller(store);
        ob.complete(false);
        checkEq(
                false,
                OnboardingScreen.Controller.shouldShowOnLaunch(store),
                "onboarding.completedHidesOnNextLaunch");

        // 2. FirstPlayGestureHint 3-show cap + dismiss forever + replay reset.
        checkEq(true, FirstPlayGestureHint.Policy.shouldShow(store), "hint.show1");
        FirstPlayGestureHint.Policy.recordShown(store);
        checkEq(true, FirstPlayGestureHint.Policy.shouldShow(store), "hint.show2");
        FirstPlayGestureHint.Policy.recordShown(store);
        checkEq(true, FirstPlayGestureHint.Policy.shouldShow(store), "hint.show3");
        FirstPlayGestureHint.Policy.recordShown(store);
        checkEq(false, FirstPlayGestureHint.Policy.shouldShow(store), "hint.suppressedAfter3");

        OnboardingScreen.Controller.resetForReplay(store);
        checkEq(
                true,
                OnboardingScreen.Controller.shouldShowOnLaunch(store),
                "onboarding.replayResetsLaunchFlag");
        checkEq(
                true,
                FirstPlayGestureHint.Policy.shouldShow(store),
                "onboarding.replayResetsGestureHint");

        FirstPlayGestureHint.Policy.dismissForever(store);
        checkEq(
                false,
                FirstPlayGestureHint.Policy.shouldShow(store),
                "hint.dismissForeverSuppressesImmediately");

        // 3. Danmu defaults & TV ARM32 P90 adaptive row downgrade (2..8 rows).
        DanmuSettingsPanel.DanmuConfig mobileDef = DanmuSettingsPanel.DanmuConfig.defaults(false);
        DanmuSettingsPanel.DanmuConfig tvDef = DanmuSettingsPanel.DanmuConfig.defaults(true);
        checkEq("", mobileDef.serverUrls, "danmu.mobile.defaultServerEmpty");
        checkEq("", tvDef.serverUrls, "danmu.tv.defaultServerEmpty");
        checkEq(false, mobileDef.enabled, "danmu.mobile.defaultDisabled");
        checkEq(false, tvDef.enabled, "danmu.tv.defaultDisabled");
        checkEq(
                true,
                mobileDef.createProvider().getConfiguredOrigins().isEmpty(),
                "danmu.mobile.noOrigins");
        checkEq(
                true,
                tvDef.createProvider().getConfiguredOrigins().isEmpty(),
                "danmu.tv.noOrigins");
        checkEq(2, DanmuSettingsPanel.clampMaxRows(1, true), "danmu.tv.minRows2");
        checkEq(8, DanmuSettingsPanel.clampMaxRows(14, true), "danmu.tv.maxRows8");
        checkEq(14, DanmuSettingsPanel.clampMaxRows(20, false), "danmu.mobile.maxRows14");

        DanmuSegmentCache.FramePacingMonitor pacing = new DanmuSegmentCache.FramePacingMonitor();
        pacing.setCeilingRows(8);
        for (int i = 0; i < 60; i++) {
            pacing.recordFrameIntervalMs(28.0); // heavy jank triggers downgrade
        }
        int downgraded = pacing.getEffectiveMaxRows();
        check(downgraded >= 2 && downgraded < 8, "danmu.tv.p90DowngradedWithin2To8=" + downgraded);

        // 4. Gate 2 Review Fix Regressions (Majors 1-3 + Minors 1-2).
        // Major 1: TV Onboarding must NOT post container requestFocus over OnboardingScreen's
        // nextButton focus.
        checkEq(
                false,
                MainActivity.shouldPostOnboardingContainerFocus(true),
                "onboarding.tv.noContainerFocusSteal");
        checkEq(
                true,
                MainActivity.shouldPostOnboardingContainerFocus(false),
                "onboarding.mobile.postsContainerFocus");

        // Major 2: Act 5 "立即导入配置" after UI scale change must cancel deferred recreate() so
        // importDialog() stays open without WindowLeaked.
        final AtomicInteger recreateCalls = new AtomicInteger();
        final AtomicInteger restoreCalls = new AtomicInteger();
        final Runnable[] queuedRecreate = new Runnable[1];
        MainActivity.OnboardingFinishCoordinator importCoord =
                new MainActivity.OnboardingFinishCoordinator(100);
        checkEq(
                true,
                importCoord.onFinished(
                        120,
                        () ->
                                queuedRecreate[0] =
                                        () ->
                                                importCoord.runDeferredRecreateIfStillNeeded(
                                                        true, recreateCalls::incrementAndGet),
                        restoreCalls::incrementAndGet),
                "onboarding.act5ImportAfterScale.schedulesDeferredRecreate");
        checkEq(
                true,
                importCoord.beginFollowUpAction(true),
                "onboarding.act5ImportAfterScale.allowsImportDialog");
        check(queuedRecreate[0] != null, "onboarding.act5ImportAfterScale.deferredTaskPosted");
        queuedRecreate[0].run();
        checkEq(0, recreateCalls.get(), "onboarding.act5ImportAfterScale.recreateCancelled");
        checkEq(0, restoreCalls.get(), "onboarding.act5ImportAfterScale.noSpuriousRestore");

        // Act 5 finish/skip WITHOUT follow-up import after scale change MUST execute recreate().
        final AtomicInteger finishRecreateCalls = new AtomicInteger();
        final Runnable[] queuedFinishRecreate = new Runnable[1];
        MainActivity.OnboardingFinishCoordinator finishCoord =
                new MainActivity.OnboardingFinishCoordinator(100);
        finishCoord.onFinished(
                110,
                () ->
                        queuedFinishRecreate[0] =
                                () ->
                                        finishCoord.runDeferredRecreateIfStillNeeded(
                                                true, finishRecreateCalls::incrementAndGet),
                restoreCalls::incrementAndGet);
        checkEq(true, finishCoord.isRecreateScheduled(), "onboarding.finishScale.scheduled");
        queuedFinishRecreate[0].run();
        checkEq(1, finishRecreateCalls.get(), "onboarding.finishScale.recreatedOnce");
        checkEq(true, finishCoord.isRecreateExecuted(), "onboarding.finishScale.markedExecuted");
        checkEq(
                false,
                finishCoord.beginFollowUpAction(true),
                "onboarding.postRecreate.blocksFollowUpDialog");

        // Unchanged scale restores focus directly with zero recreate.
        final AtomicInteger unchangedRestore = new AtomicInteger();
        MainActivity.OnboardingFinishCoordinator unchangedCoord =
                new MainActivity.OnboardingFinishCoordinator(100);
        checkEq(
                false,
                unchangedCoord.onFinished(100, () -> {}, unchangedRestore::incrementAndGet),
                "onboarding.unchangedScale.noRecreate");
        checkEq(1, unchangedRestore.get(), "onboarding.unchangedScale.restoresFocus");

        // Major 3: Detached DanmuSegmentCache detection prevents 4-thread pool & tick leak.
        checkEq(
                true,
                PlaybackControls.shouldCloseDetachedSegmentCache(true, false),
                "danmu.detachedCache.triggersClose");
        checkEq(
                false,
                PlaybackControls.shouldCloseDetachedSegmentCache(true, true),
                "danmu.attachedCache.staysOpen");
        checkEq(
                false,
                PlaybackControls.shouldCloseDetachedSegmentCache(false, false),
                "danmu.noCache.noop");

        // Minor 1: Appearance tweak in DanmuSettingsPanel must NOT overwrite loaded source/local
        // danmaku when server signature is unchanged.
        String savedUrl = "https://danmu.example";
        String changedUrl = "https://danmu2.example";
        String savedSig = savedUrl + "||";
        String changedSig = changedUrl + "||";
        checkEq(
                false,
                PlaybackControls.shouldStartSegmentedSessionOnConfigUpdate(
                        true, savedUrl, false, true, savedSig, savedSig),
                "danmu.appearanceTweak.preservesLoadedLegacyDanmaku");
        checkEq(
                true,
                PlaybackControls.shouldStartSegmentedSessionOnConfigUpdate(
                        true, changedUrl, false, true, savedSig, changedSig),
                "danmu.serverChange.startsNewSegmentedSession");
        checkEq(
                true,
                PlaybackControls.shouldStartSegmentedSessionOnConfigUpdate(
                        true, savedUrl, false, false, savedSig, savedSig),
                "danmu.noLegacyLoaded.startsSegmentedSession");
        checkEq(
                false,
                PlaybackControls.shouldStartSegmentedSessionOnConfigUpdate(
                        false, savedUrl, false, false, "", savedSig),
                "danmu.disabled.neverStartsSession");
        checkEq(
                false,
                PlaybackControls.shouldStartSegmentedSessionOnConfigUpdate(
                        true, "", false, false, "", ""),
                "danmu.emptyServer.neverStartsSession");

        // Minor 2: Async match completion checks latest config (rejects if disabled or server
        // changed while match was in flight; accepts appearance tweaks so latestCfg applies).
        DanmuSettingsPanel.DanmuConfig reqCfg =
                new DanmuSettingsPanel.DanmuConfig(
                        true,
                        "https://danmu.example",
                        "",
                        "",
                        0.85f,
                        0.50f,
                        20f,
                        1.0f,
                        0L,
                        true,
                        true,
                        true,
                        10,
                        java.util.Collections.emptyList(),
                        false);
        DanmuSettingsPanel.DanmuConfig tweakedCfg =
                new DanmuSettingsPanel.DanmuConfig(
                        true,
                        "https://danmu.example",
                        "",
                        "",
                        0.50f,
                        0.75f,
                        24f,
                        1.25f,
                        500L,
                        true,
                        false,
                        true,
                        8,
                        java.util.Collections.emptyList(),
                        false);
        DanmuSettingsPanel.DanmuConfig disabledCfg =
                new DanmuSettingsPanel.DanmuConfig(
                        false,
                        "https://danmu.example",
                        "",
                        "",
                        0.85f,
                        0.50f,
                        20f,
                        1.0f,
                        0L,
                        true,
                        true,
                        true,
                        10,
                        java.util.Collections.emptyList(),
                        false);
        DanmuSettingsPanel.DanmuConfig switchedServerCfg =
                new DanmuSettingsPanel.DanmuConfig(
                        true,
                        "https://danmu2.example",
                        "",
                        "",
                        0.85f,
                        0.50f,
                        20f,
                        1.0f,
                        0L,
                        true,
                        true,
                        true,
                        10,
                        java.util.Collections.emptyList(),
                        false);
        checkEq(
                true,
                PlaybackControls.shouldApplyAsyncMatchResult(reqCfg, tweakedCfg),
                "danmu.asyncMatch.acceptsLatestAppearanceEdits");
        checkEq(
                false,
                PlaybackControls.shouldApplyAsyncMatchResult(reqCfg, disabledCfg),
                "danmu.asyncMatch.abortsIfDisabledInFlight");
        checkEq(
                false,
                PlaybackControls.shouldApplyAsyncMatchResult(reqCfg, switchedServerCfg),
                "danmu.asyncMatch.abortsIfServerChangedInFlight");
    }

    private static String readUtf8(Path path) throws Exception {
        return new String(Files.readAllBytes(path), StandardCharsets.UTF_8);
    }

    private static void testSourceWiringInvariants(Path root) throws Exception {
        Path src = root.resolve("android-tv/src/main/java/com/pilipala/marcomovie");

        // Prefs.KEYS length must remain strictly 46.
        checkEq(46, Prefs.KEYS.length, "prefs.keys.length46");

        // TvV17DetailScreen must not use URLDecoder.decode.
        String tvDetail = readUtf8(src.resolve("TvV17DetailScreen.java"));
        check(!tvDetail.contains("URLDecoder.decode"), "tvDetail.noUrlDecoder");
        check(
                tvDetail.contains("MediaBadges.percentDecodeUtf8PreservePlus"),
                "tvDetail.usesPercentDecodePreservePlus");

        // PlaybackControls wiring: Z-order helper, DanmuSegmentCache, DanmuSettingsPanel,
        // FirstPlayGestureHint, NO Aurora.
        String playbackControls = readUtf8(src.resolve("PlaybackControls.java"));
        check(
                playbackControls.contains("mountMediaOverlaysInZOrder("),
                "playbackControls.usesZOrderHelper");
        check(
                playbackControls.contains("DanmuSegmentCache"),
                "playbackControls.wiresDanmuSegmentCache");
        check(
                playbackControls.contains("DanmuSettingsPanel.showDialog("),
                "playbackControls.wiresDanmuSettingsPanel");
        check(
                playbackControls.contains("FirstPlayGestureHint"),
                "playbackControls.wiresFirstPlayGestureHint");
        check(
                playbackControls.contains("setSubtitleBottomClearanceDp("),
                "playbackControls.syncsSubtitleClearance");
        check(
                !playbackControls.contains("AuroraSurfaceView"),
                "playbackControls.neverMountsAurora");
        check(
                playbackControls.contains("loadLocalDanmakuText(")
                        && playbackControls.contains("reconcileDetachedSegmentedDanmuSession()"),
                "playbackControls.closesSegmentedSessionOnLocalAndExternalLoad");
        check(
                playbackControls.contains("shouldApplyAsyncMatchResult(")
                        && playbackControls.contains("danmaku.applyConfig(latestCfg)"),
                "playbackControls.appliesLatestConfigAfterAsyncMatch");
        check(
                playbackControls.contains("shouldStartSegmentedSessionOnConfigUpdate("),
                "playbackControls.guardsAppearanceTweakAgainstLegacyOverwrite");

        String sourceController = readUtf8(src.resolve("SourceController.java"));
        check(
                sourceController.contains("controls.loadLocalDanmakuText(text)"),
                "sourceController.delegatesLocalDanmakuThroughControls");

        // PlayerChrome & PlaybackLoading wiring: BrandLogoLoaderView, NO Aurora.
        String playerChrome = readUtf8(src.resolve("PlayerChrome.java"));
        check(
                playerChrome.contains("new BrandLogoLoaderView("),
                "playerChrome.mountsBrandLogoLoader");
        check(
                playerChrome.contains("brandLoader.setActive(showSpinner)"),
                "playerChrome.syncsBrandLoaderActive");
        check(
                playerChrome.contains("syncDanmuPlaybackState()"),
                "playerChrome.syncsDanmuPlaybackState");
        check(!playerChrome.contains("AuroraSurfaceView"), "playerChrome.neverMountsAurora");

        String playbackLoading = readUtf8(src.resolve("PlaybackLoading.java"));
        check(
                playbackLoading.contains("new BrandLogoLoaderView("),
                "playbackLoading.mountsBrandLogoLoader");

        // Settings entries in both TV/Legacy SettingsScreen and MobileIosSettings.
        String settingsScreen = readUtf8(src.resolve("SettingsScreen.java"));
        check(
                settingsScreen.contains("DanmuSettingsPanel.showDialog("),
                "settingsScreen.wiresDanmuPanel");
        check(
                settingsScreen.contains("a.isFinishing()")
                        && settingsScreen.contains("a.isDestroyed()"),
                "settingsScreen.guardsDanmuDismissListener");
        check(
                settingsScreen.contains("重新查看新手引导")
                        && settingsScreen.contains("OnboardingScreen.resetForReplay("),
                "settingsScreen.wiresReplayOnboarding");

        String mobileSettings = readUtf8(src.resolve("MobileIosSettings.java"));
        check(
                mobileSettings.contains("DanmuSettingsPanel.showDialog("),
                "mobileSettings.wiresDanmuPanel");
        check(
                mobileSettings.contains("a.isFinishing()")
                        && mobileSettings.contains("a.isDestroyed()"),
                "mobileSettings.guardsDanmuDismissListener");
        check(
                mobileSettings.contains("重新查看新手引导")
                        && mobileSettings.contains("OnboardingScreen.resetForReplay("),
                "mobileSettings.wiresReplayOnboarding");
        check(
                mobileSettings.contains("new AuroraSurfaceView("),
                "mobileSettings.wiresAuroraInAbout");

        // MainActivity wiring: Onboarding, GlassFreezeController, graded transitions, TV page fade,
        // mobile-only Aurora.
        String mainActivity = readUtf8(src.resolve("MainActivity.java"));
        check(mainActivity.contains("GlassFreezeController"), "mainActivity.hasGlassFreeze");
        check(
                mainActivity.contains("class GlassFreezeFrameLayout")
                        && mainActivity.contains("GlassworkSurface.FrameSource"),
                "mainActivity.freezesResamplingViaFrameSource");
        check(
                mainActivity.contains("resolveDetailPortalSelection("),
                "mainActivity.usesBoundedDetailPortalResolver");
        check(
                mainActivity.contains("FOCUS_AFTER_DESCENDANTS")
                        && mainActivity.contains("shouldPostOnboardingContainerFocus("),
                "mainActivity.preservesTvOnboardingInitialFocus");
        check(
                mainActivity.contains("OnboardingFinishCoordinator"),
                "mainActivity.coordinatesOnboardingScaleRecreateAndImport");
        check(
                mainActivity.contains("PlayerTransitionHelper.startDetailToPlayerTransition("),
                "mainActivity.wiresDetailToPlayerTransition");
        check(
                mainActivity.contains("PlayerTransitionHelper.animateTvPageFade("),
                "mainActivity.wiresTvDetailFade");
        check(
                mainActivity.contains("OnboardingScreen.shouldShow("),
                "mainActivity.wiresFirstLaunchOnboarding");
        check(
                mainActivity.contains("activeOnboarding.handleBackPressed()"),
                "mainActivity.routesBackToOnboarding");
        check(
                mainActivity.contains("prefs.getString(\"origin\", \"\")"),
                "mainActivity.preservesEmptyOriginDefault");
    }

    /** Pure-Java mirror of AGSL Cinema Portal math for pixel-level frame-0 occlusion checks. */
    private static float evalAgslEffectiveMask(
            float fragX,
            float fragY,
            float viewW,
            float viewH,
            float progress,
            float[] uPosterOrigin,
            float uPosterRadius,
            float uPosterAvailable,
            float[] uSafePadding) {
        float safeW = Math.max(1f, viewW - uSafePadding[0] - uSafePadding[2]);
        float safeH = Math.max(1f, viewH - uSafePadding[1] - uSafePadding[3]);
        float targetAspect = 16f / 9f;
        float tw = (safeW / safeH > targetAspect) ? (safeH * targetAspect) : safeW;
        float th = (safeW / safeH > targetAspect) ? safeH : (safeW / targetAspect);
        float tx = uSafePadding[0] + (safeW - tw) * 0.5f;
        float ty = uSafePadding[1] + (safeH - th) * 0.5f;

        float rectT = smoothstep(0f, 0.82f, progress);
        float curX = mix(uPosterOrigin[0], tx, rectT);
        float curY = mix(uPosterOrigin[1], ty, rectT);
        float curW = Math.max(1f, mix(uPosterOrigin[2], tw, rectT));
        float curH = Math.max(1f, mix(uPosterOrigin[3], th, rectT));
        float maxRadius = 0.5f * Math.min(curW, curH);
        float r =
                Math.max(
                        0f,
                        Math.min(
                                maxRadius,
                                mix(uPosterRadius, 0f, smoothstep(0.15f, 0.75f, progress))));
        float halfW = curW * 0.5f;
        float halfH = curH * 0.5f;
        float cx = curX + halfW;
        float cy = curY + halfH;
        float qx = Math.abs(fragX - cx) - halfW + r;
        float qy = Math.abs(fragY - cy) - halfH + r;
        float outLen = (float) Math.hypot(Math.max(qx, 0f), Math.max(qy, 0f));
        float sdf = outLen + Math.min(Math.max(qx, qy), 0f) - r;
        float mask = 1f - smoothstep(-0.75f, 0.75f, sdf);
        float hasPoster = uPosterAvailable >= 0.5f ? 1f : 0f;
        float portalPresence =
                (uPosterOrigin[2] >= 1f ? 1f : 0f) * (uPosterOrigin[3] >= 1f ? 1f : 0f) * hasPoster;
        return mask * portalPresence;
    }

    private static float mix(float a, float b, float t) {
        return a + (b - a) * t;
    }

    private static float smoothstep(float edge0, float edge1, float x) {
        float t = Math.max(0f, Math.min(1f, (x - edge0) / (edge1 - edge0)));
        return t * t * (3f - 2f * t);
    }

    private static void testS02DetailPlayTransitionApi33AndApi23() {
        final int savedSdk = Build.VERSION.SDK_INT;
        try {
            Context ctx = new Context();

            // -----------------------------------------------------------------
            // (1) Full-bleed MobileDetailScreen-equivalent hierarchy on API 33+
            // -----------------------------------------------------------------
            Build.VERSION.SDK_INT = 34;
            MainActivity.GlassFreezeController freeze33 =
                    new MainActivity.GlassFreezeController(null);
            MainActivity.GlassFreezeFrameLayout fullBleedRoot =
                    new MainActivity.GlassFreezeFrameLayout(ctx, freeze33);
            fullBleedRoot.layout(0, 0, 1080, 2400);

            View backdropView = new View(ctx);
            backdropView.setTag("detail-backdrop");
            backdropView.layout(0, 0, 1080, 2400);
            fullBleedRoot.addView(backdropView, new FrameLayout.LayoutParams(-1, -1));

            ImageView hiddenCoverHook = new ImageView(ctx);
            hiddenCoverHook.setTag("detail-cover");
            hiddenCoverHook.setVisibility(View.GONE);
            hiddenCoverHook.setImageBitmap(Bitmap.createBitmap(400, 600, Bitmap.Config.ARGB_8888));
            hiddenCoverHook.layout(0, 0, 1080, 1620);
            fullBleedRoot.addView(hiddenCoverHook, new FrameLayout.LayoutParams(1080, 1620));

            View titleView = new View(ctx);
            titleView.setTag("detail-title");
            titleView.layout(80, 1100, 1000, 1220);
            fullBleedRoot.addView(titleView);

            View playBtn = new View(ctx);
            playBtn.setTag("detail-play");
            playBtn.layout(54, 1480, 1026, 1624);
            fullBleedRoot.addView(playBtn);

            FrameLayout playerOverlayHost = new FrameLayout(ctx);
            playerOverlayHost.layout(0, 0, 1080, 2400);
            AtomicInteger complete33 = new AtomicInteger();
            final PlayerTransitionHelper.TransitionHandle[] active33 =
                    new PlayerTransitionHelper.TransitionHandle[1];

            // Mirror MainActivity.open() click-play wiring end-to-end
            playBtn.setOnClickListener(
                    v -> {
                        MainActivity.DetailPortalSelection portal =
                                MainActivity.resolveDetailPortalSelection(fullBleedRoot);
                        Bitmap capturedBackdrop =
                                PlayerTransitionHelper.captureDownsampledBackdrop(fullBleedRoot);
                        active33[0] =
                                PlayerTransitionHelper.startDetailToPlayerTransition(
                                        playerOverlayHost,
                                        null,
                                        null,
                                        capturedBackdrop,
                                        true,
                                        portal.posterBitmap,
                                        portal.posterOriginPx,
                                        portal.posterBitmap != null ? 32f : 0f,
                                        new Rect(0, 88, 0, 48),
                                        false,
                                        false,
                                        freeze33,
                                        complete33::incrementAndGet);
                    });

            ValueAnimator.clearLastStarted();
            RuntimeShader.lastCreated = null;
            checkEq(true, playBtn.performClick(), "s02.api33.fullbleed.clickPlay");

            MainActivity.DetailPortalSelection fullBleedSel =
                    MainActivity.resolveDetailPortalSelection(fullBleedRoot);
            check(fullBleedSel.portalCardView == null, "s02.api33.fullbleed.noLocalPortalCard");
            checkClose(0f, fullBleedSel.posterOriginPx.width(), 1e-4f, "s02.fullbleed.emptyW");
            checkClose(0f, fullBleedSel.posterOriginPx.height(), 1e-4f, "s02.fullbleed.emptyH");
            check(fullBleedSel.posterBitmap == null, "s02.fullbleed.noPosterBitmap");

            // Even a VISIBLE full-bleed ImageView tagged detail-poster-card with a ready bitmap
            // must be rejected as full-bleed (empty uPosterOrigin) so frame 0 is never occluded.
            FrameLayout fullBleedCardTrap = new FrameLayout(ctx);
            fullBleedCardTrap.layout(0, 0, 1080, 2400);
            ImageView fullBleedImg = new ImageView(ctx);
            fullBleedImg.setTag("detail-poster-card");
            fullBleedImg.setImageBitmap(Bitmap.createBitmap(400, 600, Bitmap.Config.ARGB_8888));
            fullBleedImg.layout(0, 0, 1080, 1850); // 77% height portrait backdrop
            fullBleedCardTrap.addView(fullBleedImg);
            MainActivity.DetailPortalSelection trapSel =
                    MainActivity.resolveDetailPortalSelection(fullBleedCardTrap);
            check(trapSel.portalCardView == null, "s02.fullbleedTrap.rejectedAsFullBleed");
            checkClose(0f, trapSel.posterOriginPx.width(), 1e-4f, "s02.fullbleedTrap.emptyW");
            check(trapSel.posterBitmap == null, "s02.fullbleedTrap.nullBitmap");

            checkEq(1, playerOverlayHost.getChildCount(), "s02.api33.fullbleed.overlayMounted");
            View overlay33 = playerOverlayHost.getChildAt(0);
            overlay33.layout(0, 0, 1080, 2400);
            ValueAnimator anim33 = ValueAnimator.getLastStarted();
            check(anim33 != null, "s02.api33.fullbleed.animatorStarted");
            checkEq(
                    MotionTokens.DURATION_TRANSITION_ENTER_MS,
                    (int) anim33.getDuration(),
                    "s02.api33.duration");

            // Frame 0 draw: assert empty uPosterOrigin and uPosterAvailable == 0 -> ZERO occlusion
            anim33.stepTo(0f);
            Canvas frame0Canvas = new Canvas();
            overlay33.draw(frame0Canvas);
            RuntimeShader shader33 = RuntimeShader.lastCreated;
            check(shader33 != null, "s02.api33.fullbleed.shaderCreated");
            float[] fbOrigin = shader33.floatUniforms.get("uPosterOrigin");
            float[] fbAvail = shader33.floatUniforms.get("uPosterAvailable");
            float[] fbSafe = shader33.floatUniforms.get("uSafePadding");
            check(fbOrigin != null && fbAvail != null, "s02.api33.fullbleed.uniformsSet");
            checkClose(0f, fbOrigin[2], 1e-5f, "s02.api33.fullbleed.uPosterOriginWZero");
            checkClose(0f, fbOrigin[3], 1e-5f, "s02.api33.fullbleed.uPosterOriginHZero");
            checkClose(0f, fbAvail[0], 1e-5f, "s02.api33.fullbleed.uPosterAvailableZero");
            checkClose(
                    0f,
                    evalAgslEffectiveMask(
                            540f, 1160f, 1080f, 2400f, 0f, fbOrigin, 0f, fbAvail[0], fbSafe),
                    1e-5f,
                    "s02.api33.fullbleed.frame0TitleUnoccluded");
            checkClose(
                    0f,
                    evalAgslEffectiveMask(
                            540f, 1552f, 1080f, 2400f, 0f, fbOrigin, 0f, fbAvail[0], fbSafe),
                    1e-5f,
                    "s02.api33.fullbleed.frame0PlayBtnUnoccluded");

            // Mid-flight: depth recession + vignette only (portalPresence stays 0)
            anim33.stepTo(0.4f);
            overlay33.draw(frame0Canvas);
            float[] fbTilt = shader33.floatUniforms.get("uRecedeTilt");
            check(fbTilt != null && fbTilt[0] > 0.05f, "s02.api33.fullbleed.recedeTiltActive");
            checkClose(
                    0f,
                    evalAgslEffectiveMask(
                            540f, 1200f, 1080f, 2400f, 0.4f, fbOrigin, 0f, fbAvail[0], fbSafe),
                    1e-5f,
                    "s02.api33.fullbleed.midFlightNoPortalOverlay");

            anim33.finish();
            checkEq(1, complete33.get(), "s02.api33.fullbleed.onCompleteOnce");
            checkEq(0, playerOverlayHost.getChildCount(), "s02.api33.fullbleed.overlayRemoved");

            // -----------------------------------------------------------------
            // (2) Tablet/Card layout WITH genuine bounded poster card + ready bitmap (API 33+)
            // -----------------------------------------------------------------
            FrameLayout tabletRoot = new FrameLayout(ctx);
            tabletRoot.layout(0, 0, 1280, 800);
            ImageView posterCard = new ImageView(ctx);
            posterCard.setTag("detail-poster-card");
            Bitmap readyPosterBmp = Bitmap.createBitmap(400, 600, Bitmap.Config.ARGB_8888);
            posterCard.setImageBitmap(readyPosterBmp);
            posterCard.layout(48, 120, 288, 480); // 240x360 bounded local card
            tabletRoot.addView(posterCard);

            View tabletPlayBtn = new View(ctx);
            tabletPlayBtn.setTag("detail-play");
            tabletPlayBtn.layout(360, 320, 640, 420);
            tabletRoot.addView(tabletPlayBtn);

            FrameLayout tabletOverlayHost = new FrameLayout(ctx);
            tabletOverlayHost.layout(0, 0, 1280, 800);
            tabletPlayBtn.setOnClickListener(
                    v -> {
                        MainActivity.DetailPortalSelection sel =
                                MainActivity.resolveDetailPortalSelection(tabletRoot);
                        Bitmap cap = PlayerTransitionHelper.captureDownsampledBackdrop(tabletRoot);
                        PlayerTransitionHelper.startDetailToPlayerTransition(
                                tabletOverlayHost,
                                null,
                                null,
                                cap,
                                true,
                                sel.posterBitmap,
                                sel.posterOriginPx,
                                sel.posterBitmap != null ? 24f : 0f,
                                new Rect(0, 0, 0, 0),
                                false,
                                false,
                                null,
                                null);
                    });

            ValueAnimator.clearLastStarted();
            RuntimeShader.lastCreated = null;
            tabletPlayBtn.performClick();

            View tabletOverlay = tabletOverlayHost.getChildAt(0);
            tabletOverlay.layout(0, 0, 1280, 800);
            ValueAnimator tabletAnim = ValueAnimator.getLastStarted();
            tabletAnim.stepTo(0f);
            tabletOverlay.draw(new Canvas());
            RuntimeShader tabletShader = RuntimeShader.lastCreated;
            float[] cardOrigin = tabletShader.floatUniforms.get("uPosterOrigin");
            float[] cardAvail = tabletShader.floatUniforms.get("uPosterAvailable");
            float[] cardAspect = tabletShader.floatUniforms.get("uPosterAspect");
            float[] cardSafe = tabletShader.floatUniforms.get("uSafePadding");
            checkClose(48f, cardOrigin[0], 1e-4f, "s02.api33.card.originLeft");
            checkClose(120f, cardOrigin[1], 1e-4f, "s02.api33.card.originTop");
            checkClose(240f, cardOrigin[2], 1e-4f, "s02.api33.card.originWidth");
            checkClose(360f, cardOrigin[3], 1e-4f, "s02.api33.card.originHeight");
            checkClose(1f, cardAvail[0], 1e-4f, "s02.api33.card.posterAvailable");
            checkClose(400f / 600f, cardAspect[0], 1e-4f, "s02.api33.card.posterAspect");
            // Frame 0: title/play area outside bounded card is 100% unoccluded; card interior
            // active
            checkClose(
                    0f,
                    evalAgslEffectiveMask(
                            500f, 370f, 1280f, 800f, 0f, cardOrigin, 24f, cardAvail[0], cardSafe),
                    1e-5f,
                    "s02.api33.card.frame0PlayBtnOutsideCardUnoccluded");
            checkClose(
                    1f,
                    evalAgslEffectiveMask(
                            168f, 300f, 1280f, 800f, 0f, cardOrigin, 24f, cardAvail[0], cardSafe),
                    1e-4f,
                    "s02.api33.card.frame0CardCenterActive");
            // Expanded to centered 16:9 viewport (0, 40, 1280, 720) with BoxFit.cover
            float[] target16x9 = new float[4];
            PlayerTransitionHelper.computePortalTargetRect(1280f, 800f, 0f, 0f, 0f, 0f, target16x9);
            checkClose(0f, target16x9[0], 1e-3f, "s02.api33.card.target16x9Left");
            checkClose(40f, target16x9[1], 1e-3f, "s02.api33.card.target16x9Top");
            checkClose(1280f, target16x9[2], 1e-3f, "s02.api33.card.target16x9Width");
            checkClose(720f, target16x9[3], 1e-3f, "s02.api33.card.target16x9Height");
            float[] uv0 = new float[2];
            float[] uv1 = new float[2];
            PlayerTransitionHelper.computePosterCoverUv(
                    0f,
                    40f,
                    target16x9[0],
                    target16x9[1],
                    target16x9[2],
                    target16x9[3],
                    cardAspect[0],
                    uv0);
            PlayerTransitionHelper.computePosterCoverUv(
                    1280f,
                    760f,
                    target16x9[0],
                    target16x9[1],
                    target16x9[2],
                    target16x9[3],
                    cardAspect[0],
                    uv1);
            checkClose(0f, uv0[0], 1e-4f, "s02.api33.card.boxFitCoverU0");
            checkClose(1f, uv1[0], 1e-4f, "s02.api33.card.boxFitCoverU1");
            checkClose(0.3125f, uv0[1], 1e-4f, "s02.api33.card.boxFitCoverV0");
            checkClose(0.6875f, uv1[1], 1e-4f, "s02.api33.card.boxFitCoverV1");
            tabletAnim.finish();

            // -----------------------------------------------------------------
            // (3) Tablet/Card layout when poster bitmap is NOT ready (API 33+):
            //     NEVER paints opaque #121216 gray slab over uBackdropTex!
            // -----------------------------------------------------------------
            posterCard.setImageDrawable(null);
            MainActivity.DetailPortalSelection notReadySel =
                    MainActivity.resolveDetailPortalSelection(tabletRoot);
            check(notReadySel.posterBitmap == null, "s02.api33.notReady.nullBitmap");
            checkClose(
                    0f,
                    notReadySel.posterOriginPx.width(),
                    1e-4f,
                    "s02.api33.notReady.emptyOrigin");

            // Even if a caller passes a non-empty card RectF directly with null poster bitmap,
            // PlayerTransitionHelper + AGSL MUST keep portalPresence == 0 and effMask == 0!
            FrameLayout directHost = new FrameLayout(ctx);
            directHost.layout(0, 0, 1280, 800);
            ValueAnimator.clearLastStarted();
            RuntimeShader.lastCreated = null;
            PlayerTransitionHelper.startDetailToPlayerTransition(
                    directHost,
                    null,
                    null,
                    Bitmap.createBitmap(640, 400, Bitmap.Config.ARGB_8888),
                    true,
                    null,
                    new RectF(48f, 120f, 288f, 480f),
                    24f,
                    new Rect(0, 0, 0, 0),
                    false,
                    false,
                    null,
                    null);
            View directOverlay = directHost.getChildAt(0);
            directOverlay.layout(0, 0, 1280, 800);
            ValueAnimator directAnim = ValueAnimator.getLastStarted();
            directAnim.stepTo(0f);
            directOverlay.draw(new Canvas());
            RuntimeShader directShader = RuntimeShader.lastCreated;
            float[] nrOrigin = directShader.floatUniforms.get("uPosterOrigin");
            float[] nrAvail = directShader.floatUniforms.get("uPosterAvailable");
            float[] nrSafe = directShader.floatUniforms.get("uSafePadding");
            checkClose(0f, nrAvail[0], 1e-5f, "s02.api33.directNotReady.uPosterAvailableZero");
            checkClose(0f, nrOrigin[2], 1e-5f, "s02.api33.directNotReady.uPosterOriginZeroed");
            checkClose(
                    0f,
                    evalAgslEffectiveMask(
                            168f, 300f, 1280f, 800f, 0f, nrOrigin, 24f, nrAvail[0], nrSafe),
                    1e-5f,
                    "s02.api33.directNotReady.noOpaqueGrayBlockInsideCard");
            // Also verify raw shader math if non-zero origin + uPosterAvailable=0 were forced:
            checkClose(
                    0f,
                    evalAgslEffectiveMask(
                            168f,
                            300f,
                            1280f,
                            800f,
                            0f,
                            new float[] {48f, 120f, 240f, 360f},
                            24f,
                            0f,
                            nrSafe),
                    1e-5f,
                    "s02.api33.shaderMath.unavailablePosterNeverOccludes");
            directAnim.finish();

            // -----------------------------------------------------------------
            // (4) Real Full-Bleed Detail Screen on API 23-32 (RenderNode + glass freeze)
            // -----------------------------------------------------------------
            Build.VERSION.SDK_INT = 28;
            AtomicInteger unfreeze28 = new AtomicInteger();
            AtomicInteger complete28 = new AtomicInteger();
            MainActivity.GlassFreezeController freeze28 =
                    new MainActivity.GlassFreezeController(unfreeze28::incrementAndGet);
            MainActivity.GlassFreezeFrameLayout detail28Root =
                    new MainActivity.GlassFreezeFrameLayout(ctx, freeze28);
            detail28Root.layout(0, 0, 1080, 2400);
            View backdrop28 = new View(ctx);
            backdrop28.setTag("detail-backdrop");
            backdrop28.layout(0, 0, 1080, 2400);
            detail28Root.addView(backdrop28, new FrameLayout.LayoutParams(-1, -1));
            View playBtn28 = new View(ctx);
            playBtn28.setTag("detail-play");
            playBtn28.layout(54, 1480, 1026, 1624);
            detail28Root.addView(playBtn28);

            playBtn28.setOnClickListener(
                    v -> {
                        MainActivity.DetailPortalSelection sel =
                                MainActivity.resolveDetailPortalSelection(detail28Root);
                        PlayerTransitionHelper.startDetailToPlayerTransition(
                                null,
                                detail28Root,
                                sel.ambientPosterView,
                                null,
                                false,
                                null,
                                sel.posterOriginPx,
                                0f,
                                new Rect(0, 88, 0, 48),
                                false,
                                false,
                                freeze28,
                                complete28::incrementAndGet);
                    });

            ValueAnimator.clearLastStarted();
            playBtn28.performClick();
            ValueAnimator anim28 = ValueAnimator.getLastStarted();
            check(anim28 != null, "s02.api23.animatorStarted");
            checkEq(
                    MotionTokens.DURATION_EMPHASIZED_MS,
                    (int) anim28.getDuration(),
                    "s02.api23.duration320");
            checkEq(true, freeze28.isFrozen(), "s02.api23.glassFrozen");
            checkEq(
                    false,
                    freeze28.shouldReduceTransparency(false),
                    "s02.api23.glassFrozenDoesNotSnapToSolidTint");
            // M-02 check on real API 23 detail tree: parent detail28Root stays LAYER_TYPE_NONE!
            checkEq(
                    View.LAYER_TYPE_NONE,
                    detail28Root.getLayerType(),
                    "s02.api23.parentDetailNoNestedHwLayer");
            checkEq(
                    View.LAYER_TYPE_HARDWARE,
                    backdrop28.getLayerType(),
                    "s02.api23.childBackdropHwLayer");

            anim28.stepTo(0f);
            checkClose(1f, detail28Root.getAlpha(), 1e-4f, "s02.api23.frame0Alpha1");
            checkClose(1f, detail28Root.getScaleX(), 1e-4f, "s02.api23.frame0Scale1");
            anim28.stepTo(0.5f);
            checkClose(0.96f, detail28Root.getScaleX(), 1e-4f, "s02.api23.midDetailScale");
            checkClose(0.5f, detail28Root.getAlpha(), 1e-4f, "s02.api23.midDetailAlpha");
            checkClose(1.05f, backdrop28.getScaleX(), 1e-4f, "s02.api23.midBackdropScale");
            anim28.finish();
            checkEq(1, complete28.get(), "s02.api23.onCompleteOnce");
            checkEq(false, freeze28.isFrozen(), "s02.api23.glassUnfrozen");
            checkEq(1, unfreeze28.get(), "s02.api23.unfreezeCallbackOnce");
            checkEq(
                    View.LAYER_TYPE_NONE,
                    backdrop28.getLayerType(),
                    "s02.api23.backdropLayerRestored");
            checkClose(1f, detail28Root.getAlpha(), 1e-4f, "s02.api23.detailAlphaRestored");
        } finally {
            Build.VERSION.SDK_INT = savedSdk;
        }
    }

    private static void testM02NestedHardwareLayerGuard() {
        Context ctx = new Context();

        // 1. TV lightweight exit: direct child poster inside parent detailLayer
        FrameLayout tvDetail = new FrameLayout(ctx);
        View tvPoster = new View(ctx);
        tvDetail.addView(tvPoster);
        ValueAnimator.clearLastStarted();
        PlayerTransitionHelper.runTvLightweightExit(tvDetail, tvPoster, null);
        ValueAnimator tvAnim = ValueAnimator.getLastStarted();
        checkEq(
                View.LAYER_TYPE_NONE,
                tvDetail.getLayerType(),
                "m02.tv.child.parentDetailNotHwLayer");
        checkEq(
                View.LAYER_TYPE_HARDWARE,
                tvPoster.getLayerType(),
                "m02.tv.child.posterGetsHwLayer");
        tvAnim.stepTo(0.5f);
        checkClose(0.5f, tvDetail.getAlpha(), 1e-4f, "m02.tv.child.detailAlphaAnimates");
        checkClose(1.04f, tvPoster.getScaleX(), 1e-4f, "m02.tv.child.posterScaleAnimates");
        tvAnim.finish();
        checkEq(View.LAYER_TYPE_NONE, tvDetail.getLayerType(), "m02.tv.child.parentRestored");
        checkEq(View.LAYER_TYPE_NONE, tvPoster.getLayerType(), "m02.tv.child.posterRestored");

        // 2. API 23-32 transition: deeply nested grandchild poster inside parent detailLayer
        FrameLayout api23Detail = new FrameLayout(ctx);
        FrameLayout middleContainer = new FrameLayout(ctx);
        View grandchildPoster = new View(ctx);
        grandchildPoster.setLayerType(View.LAYER_TYPE_SOFTWARE, null);
        middleContainer.addView(grandchildPoster);
        api23Detail.addView(middleContainer);

        ValueAnimator.clearLastStarted();
        PlayerTransitionHelper.TransitionHandle nestedHandle =
                PlayerTransitionHelper.runApi23HardwareRenderNodeTransition(
                        api23Detail, grandchildPoster, null, null);
        checkEq(
                View.LAYER_TYPE_NONE,
                api23Detail.getLayerType(),
                "m02.api23.grandchild.parentDetailNotHwLayer");
        checkEq(
                View.LAYER_TYPE_HARDWARE,
                grandchildPoster.getLayerType(),
                "m02.api23.grandchild.posterGetsHwLayer");
        nestedHandle.cancel();
        checkEq(
                View.LAYER_TYPE_NONE,
                api23Detail.getLayerType(),
                "m02.api23.grandchild.parentRestoredAfterCancel");
        checkEq(
                View.LAYER_TYPE_SOFTWARE,
                grandchildPoster.getLayerType(),
                "m02.api23.grandchild.posterPrevLayerRestoredAfterCancel");

        // 3. Single-layer case (no animated child): detailLayer DOES promote & restore cleanly
        FrameLayout singleDetail = new FrameLayout(ctx);
        singleDetail.setLayerType(View.LAYER_TYPE_SOFTWARE, null);
        ValueAnimator.clearLastStarted();
        PlayerTransitionHelper.runTvLightweightExit(singleDetail, null, null);
        ValueAnimator singleAnim = ValueAnimator.getLastStarted();
        checkEq(
                View.LAYER_TYPE_HARDWARE,
                singleDetail.getLayerType(),
                "m02.singleLayer.detailPromotedToHwLayer");
        singleAnim.finish();
        checkEq(
                View.LAYER_TYPE_SOFTWARE,
                singleDetail.getLayerType(),
                "m02.singleLayer.detailRestoredToSoftware");

        // 4. Mid-flight view detach on nested child restores child layer & transforms cleanly
        FrameLayout detachDetail = new FrameLayout(ctx);
        View detachPoster = new View(ctx);
        detachPoster.setLayerType(View.LAYER_TYPE_SOFTWARE, null);
        detachDetail.addView(detachPoster);
        ValueAnimator.clearLastStarted();
        PlayerTransitionHelper.runTvLightweightExit(detachDetail, detachPoster, null);
        checkEq(View.LAYER_TYPE_NONE, detachDetail.getLayerType(), "m02.detach.parentNotHwLayer");
        checkEq(View.LAYER_TYPE_HARDWARE, detachPoster.getLayerType(), "m02.detach.childHwLayer");
        detachDetail.dispatchDetachedFromWindow();
        checkEq(View.LAYER_TYPE_NONE, detachDetail.getLayerType(), "m02.detach.parentRestored");
        checkEq(View.LAYER_TYPE_SOFTWARE, detachPoster.getLayerType(), "m02.detach.childRestored");
    }

    private static void testL03GlassFreezePreservesCachedMaterialWithoutSolidSnap()
            throws Exception {
        Handler.clearPending();
        Context ctx = new Context();
        AtomicInteger unfreezeCalls = new AtomicInteger();
        AtomicBoolean userReduced = new AtomicBoolean(false);
        MainActivity.GlassFreezeController controller =
                new MainActivity.GlassFreezeController(unfreezeCalls::incrementAndGet);
        MainActivity.GlassFreezeFrameLayout root =
                new MainActivity.GlassFreezeFrameLayout(ctx, controller);
        root.layout(0, 0, 1080, 2400);

        View backdropArt = new View(ctx);
        backdropArt.layout(0, 0, 1080, 2400);
        root.addView(backdropArt);

        View backBtn = new View(ctx);
        backBtn.layout(32, 96, 112, 176);
        root.addView(backBtn);

        GlassworkSurface.attach(
                backBtn, root, 40f, () -> controller.shouldReduceTransparency(userReduced.get()));
        check(
                backBtn.getBackground() instanceof GlassworkSurface,
                "l03.backgroundRemainsGlassworkSurfaceForRecursionGuard");
        GlassworkSurface surface = (GlassworkSurface) backBtn.getBackground();

        // Attach window and complete one real unfrozen capture so cached `material` bitmap exists
        root.dispatchAttachedToWindow();
        SystemClock.advanceUptimeMs(250L);
        Handler.flushPending();
        // Wait briefly for GlassworkSurface's background WORK thread to post material back to MAIN
        Canvas initialCanvas = new Canvas();
        boolean materialReady = false;
        for (int attempt = 0; attempt < 50; attempt++) {
            Handler.flushPending();
            initialCanvas.lastFillShader = null;
            surface.draw(initialCanvas);
            if (initialCanvas.lastFillShader instanceof BitmapShader) {
                materialReady = true;
                break;
            }
            Thread.sleep(10L);
        }
        check(materialReady, "l03.initialCapturePopulatesCachedMaterialBitmap");
        check(backdropArt.drawCount >= 1, "l03.initialCaptureDrewBackdrop");

        // Now FREEZE glass resampling during transition
        controller.setGlassFrozen(true);
        backdropArt.drawCount = 0;

        // Trigger every resampling signal while frozen: invalidateBackdrop, scroll, layout
        GlassworkSurface.invalidateBackdrop(root);
        surface.onScrollChanged();
        surface.onGlobalLayout();
        SystemClock.advanceUptimeMs(500L);
        Handler.flushPending();
        Thread.sleep(30L);
        Handler.flushPending();

        // (a) ZERO backdrop resampling / capture occurred while frozen
        checkEq(0, backdropArt.drawCount, "l03.frozen.zeroBackdropResampling");
        check(
                controller.getDeferredCaptureCount() >= 1,
                "l03.frozen.captureInterceptedAndDeferred");

        // (b) Independent child draw (API 23+ DisplayList without root.draw) keeps cached material
        Canvas frozenChildCanvas = new Canvas();
        surface.draw(frozenChildCanvas);
        check(
                frozenChildCanvas.lastFillShader instanceof BitmapShader,
                "l03.frozen.childDrawUsesCachedMaterialBitmapNotSolidTint");
        check(
                backBtn.getBackground() instanceof GlassworkSurface,
                "l03.frozen.backgroundStillGlassworkSurface");

        // (c) Real user Prefs.REDUCED_TRANSPARENCY is still respected
        userReduced.set(true);
        Canvas reducedCanvas = new Canvas();
        surface.draw(reducedCanvas);
        check(
                reducedCanvas.lastFillShader == null
                        && reducedCanvas.lastFillColor == GlassworkMaterial.DARK_TINT,
                "l03.userReducedTransparencyDrawsSolidDarkTint");
        userReduced.set(false);

        // (d) Unfreeze resumes deferred capture & triggers refresh cleanly
        controller.setGlassFrozen(false);
        checkEq(1, unfreezeCalls.get(), "l03.unfreeze.callbackInvokedOnce");
        checkEq(0, controller.getDeferredCaptureCount(), "l03.unfreeze.deferredDrained");
        SystemClock.advanceUptimeMs(250L);
        Handler.flushPending();
        check(backdropArt.drawCount >= 1, "l03.unfreeze.resumesBackdropRefreshAfterTransition");

        // (e) When unfrozen, GlassFreezeFrameLayout delegates to a visible descendant FrameSource
        final AtomicInteger childFrameCalls = new AtomicInteger();
        final AtomicBoolean childAdvancing = new AtomicBoolean(true);
        class FakeVideoFrameSource extends View implements GlassworkSurface.FrameSource {
            FakeVideoFrameSource(Context c) {
                super(c);
            }

            @Override
            public void prepareGlassFrame(Runnable ready) {
                childFrameCalls.incrementAndGet();
                if (ready != null) ready.run();
            }

            @Override
            public boolean glassFrameAdvancing() {
                return childAdvancing.get();
            }
        }
        FakeVideoFrameSource fakeVideo = new FakeVideoFrameSource(ctx);
        root.addView(fakeVideo);
        checkEq(true, root.glassFrameAdvancing(), "l03.unfrozen.delegatesDescendantAdvancing");
        AtomicInteger readyRun = new AtomicInteger();
        root.prepareGlassFrame(readyRun::incrementAndGet);
        checkEq(1, childFrameCalls.get(), "l03.unfrozen.delegatesPrepareGlassFrame");
        checkEq(1, readyRun.get(), "l03.unfrozen.readyCallbackExecuted");

        // While frozen, descendant FrameSource is suppressed (no PixelCopy/resampling)
        controller.setGlassFrozen(true);
        checkEq(false, root.glassFrameAdvancing(), "l03.frozen.suppressesDescendantAdvancing");
        root.prepareGlassFrame(readyRun::incrementAndGet);
        checkEq(1, childFrameCalls.get(), "l03.frozen.doesNotInvokeDescendantFrameSource");

        // Detach cleans up deferred callbacks safely without leak
        root.dispatchDetachedFromWindow();
        checkEq(0, controller.getDeferredCaptureCount(), "l03.detach.clearsDeferredCallbacks");
        controller.forceUnfreeze();
    }

    private static void testM01DanmakuViewLegacyZeroRepeatFilterPerFrame() {
        Context ctx = new Context();
        final int[] posMs = new int[] {1000};
        DanmakuView view =
                new DanmakuView(
                        ctx,
                        new DanmakuView.Clock() {
                            @Override
                            public int position() {
                                return posMs[0];
                            }

                            @Override
                            public boolean playing() {
                                return true;
                            }
                        });
        try {
            view.layout(0, 0, 1920, 1080);
            view.setTvMode(true);
            view.enabled(true);

            List<DanmuItem> items = new ArrayList<>();
            for (int i = 0; i < 80; i++) {
                String text =
                        (i % 4 == 0)
                                ? ("广告链接" + i + "加VX12345")
                                : (i % 4 == 1) ? ("Spoiler 剧透 " + i) : ("正常本地弹幕 " + i);
                items.add(new DanmuItem("leg_" + i, 1000L + i * 60L, 1, 0xFFFFFF, text));
            }
            BlockFilter regexFilter =
                    BlockFilter.compile(
                            Arrays.asList("spoiler", "re:广告.*链接", "re:(微信|QQ|VX)\\d{4,}"));
            checkEq(3, regexFilter.ruleCount(), "m01.legacy.allThreeRulesCompiled");
            view.setBlockFilter(regexFilter);
            view.setLegacyItems(items);

            long evalAfterLoad = regexFilter.getEvaluationCount();
            checkEq(items.size(), (int) evalAfterLoad, "m01.legacy.evaluatedOnceOnIngest");

            // 60 steady-state frames of populateLegacyFrameItems + layoutEngine.step
            for (int f = 0; f < 60; f++) {
                long t = 5500L + f * 16L;
                view.populateLegacyFrameItems(t);
                view.layoutEngine.step(
                        t,
                        view.getFrameItemsForTest(),
                        1920,
                        1080,
                        24f,
                        0f,
                        88f,
                        0.50f,
                        6,
                        48,
                        8200L,
                        true,
                        true,
                        true,
                        text -> text == null ? 0f : text.length() * 24f);
            }
            checkEq(
                    (int) evalAfterLoad,
                    (int) regexFilter.getEvaluationCount(),
                    "m01.legacy.zeroRepeatFilterAcross60Frames");
            check(!view.getFrameItemsForTest().isEmpty(), "m01.legacy.safeItemsPresent");
            for (DanmuItem kept : view.getFrameItemsForTest()) {
                check(
                        !kept.text.contains("广告链接") && !kept.text.contains("Spoiler"),
                        "m01.legacy.noBlockedLeak:" + kept.text);
            }

            // Changing rules re-filters legacyItems once and updates subsequent frames
            BlockFilter updatedFilter =
                    BlockFilter.compile(Collections.singletonList("re:正常本地弹幕.*2$"));
            view.setBlockFilter(updatedFilter);
            long evalAfterUpdate = updatedFilter.getEvaluationCount();
            check(evalAfterUpdate >= items.size(), "m01.legacy.ruleChangeReEvaluatesOnce");
            for (int f = 0; f < 30; f++) {
                view.populateLegacyFrameItems(6000L + f * 16L);
            }
            checkEq(
                    (int) evalAfterUpdate,
                    (int) updatedFilter.getEvaluationCount(),
                    "m01.legacy.zeroRepeatFilterAfterRuleChange");
            boolean sawRestoredSpoiler = false;
            for (DanmuItem kept : view.getFrameItemsForTest()) {
                if (kept.text.contains("Spoiler")) sawRestoredSpoiler = true;
                check(!kept.text.endsWith(" 2"), "m01.legacy.newRegexRuleApplied");
            }
            check(sawRestoredSpoiler, "m01.legacy.removedRuleRestoresItems");
        } finally {
            view.close();
        }
    }

    public static void main(String[] args) throws Exception {
        Path root = args.length > 0 ? Paths.get(args[0]) : Paths.get(".");
        testPlaybackControlsZOrder();
        testApi23GlassFreezeLifecycle();
        testS02DetailPlayTransitionApi33AndApi23();
        testM02NestedHardwareLayerGuard();
        testL03GlassFreezePreservesCachedMaterialWithoutSolidSnap();
        testM01DanmakuViewLegacyZeroRepeatFilterPerFrame();
        testFocusMotionReducedGuard();
        testTvV17EpisodeFileCaptionDecoding();
        testOnboardingFirstPlayAndDanmuPolicies();
        testSourceWiringInvariants(root);
        System.out.println("Wave2AndroidWireChecks OK (" + checks + " checks passed)");
    }
}
