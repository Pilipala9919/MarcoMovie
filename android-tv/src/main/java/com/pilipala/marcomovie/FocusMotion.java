package com.pilipala.marcomovie;

import android.graphics.Color;
import android.graphics.drawable.GradientDrawable;
import android.view.*;
import android.view.animation.DecelerateInterpolator;
import android.widget.TextView;

/** Shared frame clock and velocity-preserving focus/press springs. No layout animation. */
final class FocusMotion {
    private static DecelerateInterpolator tvDecelCache;

    private static DecelerateInterpolator tvDecel() {
        if (tvDecelCache == null) tvDecelCache = new DecelerateInterpolator();
        return tvDecelCache;
    }

    static final class State {
        final GradientDrawable background = new GradientDrawable();
        final MotionSpring emphasis = new MotionSpring(0, 30, .0025f),
                compression = new MotionSpring(0, 40, .0025f);
        MotionLoop.Step animator;
        int targetColor, color, stroke, text, normal, active, idleText, activeText, radiusPx;
        int appliedRadiusPx = -1, strokeWidthPx = -1;
        float scale = 1, elevation, gain = 1;
        boolean ready, pressed, border, unclipped;
        String focusFrameGroup;
    }

    static int lerpColor(int start, int end, float fraction) {
        if (start == end || fraction <= 0f) return start;
        if (fraction >= 1f) return end;
        int a0 = (start >>> 24) & 0xff,
                r0 = (start >>> 16) & 0xff,
                g0 = (start >>> 8) & 0xff,
                b0 = start & 0xff;
        int a1 = (end >>> 24) & 0xff,
                r1 = (end >>> 16) & 0xff,
                g1 = (end >>> 8) & 0xff,
                b1 = end & 0xff;
        return ((a0 + Math.round((a1 - a0) * fraction)) << 24)
                | ((r0 + Math.round((r1 - r0) * fraction)) << 16)
                | ((g0 + Math.round((g1 - g0) * fraction)) << 8)
                | (b0 + Math.round((b1 - b0) * fraction));
    }

    static boolean hasDirectScrollChild(ViewGroup g) {
        for (int i = 0, n = g.getChildCount(); i < n; i++) {
            View c = g.getChildAt(i);
            if (c instanceof android.widget.ScrollView
                    || c instanceof android.widget.HorizontalScrollView
                    || "scroll-viewport-clip".equals(c.getTag())) {
                return true;
            }
        }
        return false;
    }

    static void unclipAncestors(View view) {
        if (view == null) return;
        if (view.getContext() instanceof MainActivity
                && !((MainActivity) view.getContext()).isTvDevice()) {
            return;
        }
        ViewParent p = view.getParent();
        while (p instanceof ViewGroup) {
            ViewGroup g = (ViewGroup) p;
            Object tag = g.getTag();
            if (g instanceof android.widget.ScrollView
                    || g instanceof android.widget.HorizontalScrollView
                    || g.getClipToOutline()
                    || "scroll-viewport-clip".equals(tag)
                    || "player-dock".equals(tag)
                    || "app-dialog".equals(tag)
                    || "source-picker".equals(tag)
                    || "account-panel".equals(tag)
                    || "plugin-dialog-card".equals(tag)
                    || "netdisk-qr-bubble".equals(tag)) {
                break;
            }
            if (!hasDirectScrollChild(g)) {
                if (g.getClipChildren()) g.setClipChildren(false);
                if (g.getClipToPadding()) g.setClipToPadding(false);
            }
            p = g.getParent();
        }
    }

    static State state(View view) {
        UiCompat.setDefaultFocusHighlightEnabled(view, false);
        State state = (State) view.getTag(R.id.focus_motion);
        if (state == null) {
            state = new State();
            view.setTag(R.id.focus_motion, state);
            final State saved = state;
            view.addOnAttachStateChangeListener(
                    new View.OnAttachStateChangeListener() {
                        public void onViewAttachedToWindow(View v) {
                            unclipAncestors(v);
                            saved.unclipped = true;
                        }

                        public void onViewDetachedFromWindow(View v) {
                            cancel(saved);
                            v.animate().cancel();
                            saved.pressed = false;
                            saved.unclipped = false;
                            saved.compression.snap(0);
                            v.setAlpha(1);
                        }
                    });
        }
        return state;
    }

    static void cancel(State state) {
        if (state.animator != null) {
            MotionLoop.remove(state.animator);
            state.animator = null;
        }
    }

    static void style(
            MainActivity a,
            View view,
            boolean focused,
            int normal,
            int active,
            int radius,
            int idleText,
            int activeText,
            boolean border,
            float gain) {
        State state = state(view);
        if (!state.unclipped) {
            unclipAncestors(view);
            if (view.isAttachedToWindow()) state.unclipped = true;
        }
        if (state.strokeWidthPx < 0)
            state.strokeWidthPx =
                    Math.max(1, Math.round(view.getResources().getDisplayMetrics().density * 2));
        if (!state.ready) {
            state.ready = true;
            state.color = normal;
            state.text = idleText;
            state.stroke = 0x00f5f5f7;
            state.background.setColor(normal);
            state.background.setStroke(state.strokeWidthPx, state.stroke);
            view.animate().cancel();
        }
        state.targetColor = focused ? active : normal;
        state.normal = normal;
        state.active = active;
        state.idleText = idleText;
        state.activeText = activeText;
        state.border = border;
        state.gain = gain;
        state.radiusPx = a.dp(radius);
        if (state.appliedRadiusPx != state.radiusPx && view.getWidth() == 0) {
            state.appliedRadiusPx = state.radiusPx;
            state.background.setCornerRadius(state.radiusPx);
        }
        if (view.getBackground() != state.background) view.setBackground(state.background);
        if (!focused) {
            state.pressed = false;
            state.compression.target(0);
        }
        state.emphasis.target(focused ? 1 : 0);
        transition(a, view, state);
    }

    static boolean isReducedMotion(MainActivity a) {
        return a != null
                && (a.reduced || (a.prefs != null && a.prefs.getBoolean(Prefs.REDUCED, false)));
    }

    static float resolveScale(float gain, float emphasis, float compression, boolean reduced) {
        if (reduced) {
            return MotionTokens.TV_FOCUS_REDUCED_SCALE;
        }
        float f = Math.max(0f, Math.min(1f, emphasis));
        float p = Math.max(0f, Math.min(1f, compression));
        return (1f + (gain - 1f) * f) * (1f - 0.03f * p);
    }

    static int resolveStrokeColor(boolean border, float emphasis, boolean reduced) {
        float f = Math.max(0f, Math.min(1f, emphasis));
        if (reduced) {
            return f >= 0.5f ? MotionTokens.TV_FOCUS_STROKE_ARGB : 0x00f5f5f7;
        }
        return border ? lerpColor(0x00f5f5f7, MotionTokens.TV_FOCUS_STROKE_ARGB, f) : 0x00f5f5f7;
    }

    static void transition(MainActivity a, View view, State state) {
        boolean reduced = isReducedMotion(a);
        if (reduced || !view.isAttachedToWindow()) {
            cancel(state);
            view.animate().cancel();
            state.emphasis.snap(state.emphasis.target);
            state.compression.snap(state.compression.target);
            paint(view, state, reduced);
            return;
        }
        // On Android TV, snap static background/stroke/text colors once so the View's
        // DisplayList never rebuilds per frame, and animate only GPU-composited scale/alpha
        // on the RenderThread. When TvScrollView's gliding TvFocusFrame wraps a transparent
        // poster card, suppress the duplicate static stroke so only the smooth gliding ring draws.
        if (a != null && a.isTvDevice()) {
            cancel(state);
            state.emphasis.snap(state.emphasis.target);
            state.compression.snap(state.compression.target);
            float f = Math.max(0f, Math.min(1f, state.emphasis.value));
            float p = Math.max(0f, Math.min(1f, state.compression.value));
            int color = lerpColor(state.normal, state.active, f);
            boolean suppressStaticRing = hasScrollFocusFrame(view);
            int outline =
                    suppressStaticRing ? 0x00f5f5f7 : resolveStrokeColor(state.border, f, false);
            int text = resolveTextColor(view, state, color, f);
            applyStaticAppearance(view, state, color, outline, text);
            float targetScale = resolveScale(state.gain, f, p, false);
            float targetAlpha = 1f - .1f * p;
            state.scale = targetScale;
            state.elevation = 0;
            view.animate().cancel();
            if (Math.abs(view.getScaleX() - targetScale) > 0.001f
                    || Math.abs(view.getScaleY() - targetScale) > 0.001f
                    || Math.abs(view.getAlpha() - targetAlpha) > 0.001f) {
                view.animate()
                        .scaleX(targetScale)
                        .scaleY(targetScale)
                        .alpha(targetAlpha)
                        .setDuration(120)
                        .setInterpolator(tvDecel())
                        .start();
            } else {
                if (view.getScaleX() != targetScale) view.setScaleX(targetScale);
                if (view.getScaleY() != targetScale) view.setScaleY(targetScale);
                if (view.getAlpha() != targetAlpha) view.setAlpha(targetAlpha);
            }
            return;
        }
        if (!state.emphasis.step(0) && !state.compression.step(0)) {
            paint(view, state, false);
            return;
        }
        if (state.animator != null) return;
        state.animator =
                seconds -> {
                    if (!view.isAttachedToWindow()) {
                        state.animator = null;
                        return false;
                    }
                    if (isReducedMotion(a)) {
                        state.emphasis.snap(state.emphasis.target);
                        state.compression.snap(state.compression.target);
                        paint(view, state, true);
                        state.animator = null;
                        return false;
                    }
                    boolean moving = state.emphasis.step(seconds);
                    moving |= state.compression.step(seconds);
                    paint(view, state, false);
                    if (!moving) state.animator = null;
                    return moving;
                };
        MotionLoop.add(state.animator);
    }

    private static boolean hasScrollFocusFrame(View view) {
        if (view == null) return false;
        ViewParent p = view.getParent();
        while (p instanceof ViewGroup) {
            if (p instanceof TvScrollView) {
                TvScrollView sv = (TvScrollView) p;
                return sv.focusFrame != null && sv.focusFrame.handles(view);
            }
            p = p.getParent();
        }
        return false;
    }

    private static int resolveTextColor(View view, State state, int color, float f) {
        int text = f < .5f ? state.idleText : state.activeText;
        if (view instanceof TextView && Color.alpha(color) > 220) {
            float light =
                    (Color.red(color) * .299f
                            + Color.green(color) * .587f
                            + Color.blue(color) * .114f);
            text =
                    light > 150
                            ? MainActivity.DARK
                            : state.activeText == MainActivity.DARK
                                    ? MainActivity.WHITE
                                    : state.activeText;
        }
        return text;
    }

    private static void applyStaticAppearance(
            View view, State state, int color, int stroke, int text) {
        if (state.color != color) {
            state.background.setColor(color);
            state.color = color;
        }
        int maxRadius =
                view.getWidth() > 0 && view.getHeight() > 0
                        ? Math.min(view.getWidth(), view.getHeight()) / 2
                        : state.radiusPx;
        int effectiveRadius = Math.min(state.radiusPx, maxRadius);
        if (state.stroke != stroke) {
            int sw =
                    state.strokeWidthPx > 0
                            ? state.strokeWidthPx
                            : Math.max(
                                    1,
                                    Math.round(
                                            view.getResources().getDisplayMetrics().density * 2));
            state.background.setStroke(sw, stroke);
            state.stroke = stroke;
        }
        if (state.appliedRadiusPx != effectiveRadius) {
            state.background.setCornerRadius(effectiveRadius);
            state.appliedRadiusPx = effectiveRadius;
        }
        if (view instanceof TextView && ((TextView) view).getCurrentTextColor() != text)
            ((TextView) view).setTextColor(text);
        if (view.getElevation() != 0) view.setElevation(0);
        state.text = text;
    }

    static void paint(View view, State state, boolean reduced) {
        float f = Math.max(0, Math.min(1, state.emphasis.value)),
                p = Math.max(0, Math.min(1, state.compression.value));
        int color = lerpColor(state.normal, state.active, f),
                outline = resolveStrokeColor(state.border, f, reduced);
        int text = resolveTextColor(view, state, color, f);
        apply(
                view,
                state,
                color,
                outline,
                text,
                resolveScale(state.gain, f, p, reduced),
                0,
                1 - .1f * p);
    }

    static void apply(
            View view,
            State state,
            int color,
            int stroke,
            int text,
            float scale,
            float elevation,
            float alpha) {
        if (state.color != color) {
            state.background.setColor(color);
            state.color = color;
        }
        int maxRadius =
                view.getWidth() > 0 && view.getHeight() > 0
                        ? Math.min(view.getWidth(), view.getHeight()) / 2
                        : state.radiusPx;
        int effectiveRadius = Math.min(state.radiusPx, maxRadius);
        if (state.stroke != stroke) {
            int newAlpha = Color.alpha(stroke);
            int oldAlpha = Color.alpha(state.stroke);
            boolean endpoint =
                    newAlpha == 0
                            || stroke == MotionTokens.TV_FOCUS_STROKE_ARGB
                            || Math.abs(newAlpha - oldAlpha) >= 64;
            if (endpoint) {
                int sw =
                        state.strokeWidthPx > 0
                                ? state.strokeWidthPx
                                : Math.max(
                                        1,
                                        Math.round(
                                                view.getResources().getDisplayMetrics().density
                                                        * 2));
                state.background.setStroke(sw, stroke);
                state.stroke = stroke;
            }
        }
        if (state.appliedRadiusPx != effectiveRadius) {
            state.background.setCornerRadius(effectiveRadius);
            state.appliedRadiusPx = effectiveRadius;
        }
        if (view instanceof TextView && ((TextView) view).getCurrentTextColor() != text)
            ((TextView) view).setTextColor(text);
        if (view.getScaleX() != scale) view.setScaleX(scale);
        if (view.getScaleY() != scale) view.setScaleY(scale);
        if (view.getElevation() != elevation) view.setElevation(elevation);
        if (view.getAlpha() != alpha) view.setAlpha(alpha);
        state.text = text;
        state.scale = scale;
        state.elevation = elevation;
    }

    static void press(MainActivity a, View view, boolean pressed) {
        State state = (State) view.getTag(R.id.focus_motion);
        if (state == null || state.pressed == pressed) return;
        state.pressed = pressed;
        state.compression.target(pressed ? 1 : 0);
        transition(a, view, state);
    }

    static void key(MainActivity a, View view, int key, KeyEvent event) {
        if (key == KeyEvent.KEYCODE_DPAD_CENTER || key == KeyEvent.KEYCODE_ENTER)
            press(a, view, event.getAction() == KeyEvent.ACTION_DOWN);
    }
}
