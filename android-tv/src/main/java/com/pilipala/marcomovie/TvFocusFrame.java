package com.pilipala.marcomovie;

import android.graphics.Canvas;
import android.graphics.Paint;
import android.graphics.Rect;
import android.graphics.RectF;
import android.view.View;
import android.view.ViewParent;
import android.view.ViewTreeObserver;

/**
 * Hardware-friendly gliding focus ring drawn inside {@link TvScrollView#dispatchDraw(Canvas)}.
 *
 * <p>Scoped strictly to opt-in media poster cards (registered via {@link #attachCard(View,
 * String)}). Adjacent peers within the same poster shelf or grid glide smoothly via critically
 * damped springs, while cross-section or far jumps snap immediately with a soft alpha bloom so no
 * stray outline ever flies across keyboards, buttons, or headings.
 */
final class TvFocusFrame {
    private static final float SPRING_FREQ = 28f;
    private static final float SPRING_SETTLE = 0.35f;
    private static final float ALPHA_FREQ = 34f;

    final MainActivity a;
    final TvScrollView scroller;

    final MotionSpring left = new MotionSpring(0, SPRING_FREQ, SPRING_SETTLE);
    final MotionSpring top = new MotionSpring(0, SPRING_FREQ, SPRING_SETTLE);
    final MotionSpring right = new MotionSpring(0, SPRING_FREQ, SPRING_SETTLE);
    final MotionSpring bottom = new MotionSpring(0, SPRING_FREQ, SPRING_SETTLE);
    final MotionSpring radius = new MotionSpring(0, SPRING_FREQ, 0.4f);
    final MotionSpring alpha = new MotionSpring(1f, ALPHA_FREQ, 0.01f);

    private final Rect tempRect = new Rect();
    private final RectF liveBounds = new RectF();
    private final RectF drawBounds = new RectF();
    private final float[] liveRadius = new float[1];
    private final Paint haloPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint ringPaint = new Paint(Paint.ANTI_ALIAS_FLAG);

    View target;
    MotionLoop.Step animator;
    boolean positioned;
    boolean enabled = true;
    String currentGroup;
    private float lastTargetLeft, lastTargetTop, lastTargetRight, lastTargetBottom;
    private boolean listenerAttached;

    private final ViewTreeObserver.OnGlobalFocusChangeListener globalFocusListener;

    static void attachCard(View view, String group) {
        if (view == null || group == null || group.isEmpty()) return;
        FocusMotion.state(view).focusFrameGroup = group;
    }

    static String groupOf(View view) {
        if (view == null) return null;
        Object obj = view.getTag(R.id.focus_motion);
        return (obj instanceof FocusMotion.State)
                ? ((FocusMotion.State) obj).focusFrameGroup
                : null;
    }

    static boolean shouldGlideBetween(
            String fromGroup,
            String toGroup,
            float fromCx,
            float fromCy,
            float toCx,
            float toCy,
            float targetW,
            float targetH) {
        if (fromGroup == null || toGroup == null || !fromGroup.equals(toGroup)) return false;
        float w = Math.max(1f, targetW);
        float h = Math.max(1f, targetH);
        float dx = Math.abs(toCx - fromCx);
        float dy = Math.abs(toCy - fromCy);
        return dx <= w * 3.2f && dy <= h * 2.4f;
    }

    TvFocusFrame(MainActivity activity, TvScrollView host) {
        a = activity;
        scroller = host;
        globalFocusListener =
                (oldFocus, newFocus) -> {
                    if (!scroller.isAttachedToWindow()) return;
                    if (newFocus != null && isDescendant(newFocus)) {
                        follow(newFocus);
                    } else {
                        clear();
                    }
                };
        haloPaint.setStyle(Paint.Style.STROKE);
        haloPaint.setColor(0x34ffffff);
        ringPaint.setStyle(Paint.Style.STROKE);
        ringPaint.setColor(0xf4ffffff);
    }

    void setEnabled(boolean value) {
        if (enabled == value) return;
        enabled = value;
        if (!enabled) clear();
    }

    void onAttachedToWindow() {
        if (!listenerAttached) {
            listenerAttached = true;
            scroller.getViewTreeObserver().addOnGlobalFocusChangeListener(globalFocusListener);
        }
        View cur = scroller.findFocus();
        if (cur != null && cur != scroller) {
            follow(cur);
        }
    }

    void onDetachedFromWindow() {
        stop();
        target = null;
        currentGroup = null;
        positioned = false;
        alpha.snap(1f);
        if (listenerAttached) {
            listenerAttached = false;
            try {
                scroller.getViewTreeObserver()
                        .removeOnGlobalFocusChangeListener(globalFocusListener);
            } catch (Exception ignored) {
            }
        }
    }

    boolean isDescendant(View view) {
        if (view == null || view == scroller) return false;
        ViewParent p = view.getParent();
        while (p != null && p != scroller) p = p.getParent();
        return p == scroller;
    }

    boolean handles(View view) {
        if (!enabled || view == null || !isDescendant(view)) return false;
        return groupOf(view) != null;
    }

    void follow(View view) {
        if (!handles(view)) {
            clear();
            return;
        }
        if (target == view && positioned) {
            syncTargetLive();
            return;
        }
        target = view;
        if (!measureTarget(view, liveBounds, liveRadius)) {
            scroller.post(
                    () -> {
                        if (target == view && scroller.isAttachedToWindow()) {
                            syncTargetOnAttach(view);
                        }
                    });
            return;
        }
        String nextGroup = groupOf(view);
        boolean glide =
                positioned
                        && !a.reduced
                        && shouldGlideBetween(
                                currentGroup,
                                nextGroup,
                                (left.value + right.value) * 0.5f,
                                (top.value + bottom.value) * 0.5f,
                                liveBounds.centerX(),
                                liveBounds.centerY(),
                                liveBounds.width(),
                                liveBounds.height());
        currentGroup = nextGroup;
        applyTargetBounds(liveBounds, liveRadius[0], !glide);
    }

    private void syncTargetOnAttach(View view) {
        if (target != view || !measureTarget(view, liveBounds, liveRadius)) return;
        String nextGroup = groupOf(view);
        boolean glide =
                positioned
                        && !a.reduced
                        && shouldGlideBetween(
                                currentGroup,
                                nextGroup,
                                (left.value + right.value) * 0.5f,
                                (top.value + bottom.value) * 0.5f,
                                liveBounds.centerX(),
                                liveBounds.centerY(),
                                liveBounds.width(),
                                liveBounds.height());
        currentGroup = nextGroup;
        applyTargetBounds(liveBounds, liveRadius[0], !glide);
    }

    void clear() {
        stop();
        target = null;
        currentGroup = null;
        positioned = false;
        alpha.snap(1f);
        scroller.invalidate();
    }

    void stop() {
        if (animator != null) {
            MotionLoop.remove(animator);
            animator = null;
        }
    }

    private void applyTargetBounds(RectF rect, float cornerPx, boolean snap) {
        lastTargetLeft = rect.left;
        lastTargetTop = rect.top;
        lastTargetRight = rect.right;
        lastTargetBottom = rect.bottom;
        if (snap || !scroller.isAttachedToWindow()) {
            stop();
            left.snap(rect.left);
            top.snap(rect.top);
            right.snap(rect.right);
            bottom.snap(rect.bottom);
            radius.snap(cornerPx);
            positioned = true;
            if (a.reduced || !scroller.isAttachedToWindow()) {
                alpha.snap(1f);
            } else {
                alpha.snap(0.18f);
                alpha.target(1f);
                ensureAnimating();
            }
            scroller.invalidate();
            return;
        }
        left.target(rect.left);
        top.target(rect.top);
        right.target(rect.right);
        bottom.target(rect.bottom);
        radius.target(cornerPx);
        alpha.target(1f);
        ensureAnimating();
        scroller.invalidate();
    }

    private void syncTargetLive() {
        if (target == null || !positioned) return;
        if (!measureTarget(target, liveBounds, liveRadius)) return;
        float dl = liveBounds.left - lastTargetLeft;
        float dt = liveBounds.top - lastTargetTop;
        float dr = liveBounds.right - lastTargetRight;
        float db = liveBounds.bottom - lastTargetBottom;
        if (Math.abs(dl) < 0.5f
                && Math.abs(dt) < 0.5f
                && Math.abs(dr) < 0.5f
                && Math.abs(db) < 0.5f) {
            return;
        }
        lastTargetLeft = liveBounds.left;
        lastTargetTop = liveBounds.top;
        lastTargetRight = liveBounds.right;
        lastTargetBottom = liveBounds.bottom;
        if (animator == null) {
            // Card moved because a child HorizontalScrollView scrolled: track it in lockstep.
            left.snap(liveBounds.left);
            top.snap(liveBounds.top);
            right.snap(liveBounds.right);
            bottom.snap(liveBounds.bottom);
            radius.snap(liveRadius[0]);
        } else {
            // Shift both current value and target by the scroll delta so horizontal scrolling
            // never fights the spring glide.
            if (Math.abs(dl - dr) < 1f) {
                left.value += dl;
                right.value += dr;
            }
            if (Math.abs(dt - db) < 1f) {
                top.value += dt;
                bottom.value += db;
            }
            left.target(liveBounds.left);
            top.target(liveBounds.top);
            right.target(liveBounds.right);
            bottom.target(liveBounds.bottom);
            radius.target(liveRadius[0]);
        }
    }

    private void ensureAnimating() {
        if (animator != null) return;
        if (!left.step(0)
                && !top.step(0)
                && !right.step(0)
                && !bottom.step(0)
                && !radius.step(0)
                && !alpha.step(0)) {
            return;
        }
        animator =
                seconds -> {
                    if (!scroller.isAttachedToWindow() || target == null) {
                        animator = null;
                        return false;
                    }
                    syncTargetLive();
                    boolean moving = left.step(seconds);
                    moving |= top.step(seconds);
                    moving |= right.step(seconds);
                    moving |= bottom.step(seconds);
                    moving |= radius.step(seconds);
                    moving |= alpha.step(seconds);
                    scroller.invalidate();
                    if (!moving) animator = null;
                    return moving;
                };
        MotionLoop.add(animator);
    }

    private boolean measureTarget(View view, RectF outRect, float[] outRadius) {
        if (view == null
                || !view.isAttachedToWindow()
                || !view.isShown()
                || view.getWidth() <= 0
                || view.getHeight() <= 0
                || !isDescendant(view)) {
            return false;
        }
        tempRect.set(0, 0, view.getWidth(), view.getHeight());
        try {
            scroller.offsetDescendantRectToMyCoords(view, tempRect);
        } catch (IllegalArgumentException ignored) {
            return false;
        }
        float scale = 1f;
        float cornerPx = a.dp(13);
        Object fmObj = view.getTag(R.id.focus_motion);
        if (fmObj instanceof FocusMotion.State) {
            FocusMotion.State st = (FocusMotion.State) fmObj;
            scale = a.reduced ? 1f : Math.max(1f, st.gain);
            if (st.radiusPx > 0) cornerPx = st.radiusPx;
        }
        float w = tempRect.width();
        float h = tempRect.height();
        float cx = tempRect.exactCenterX();
        float cy = tempRect.exactCenterY();
        float halfW = (w * scale) * 0.5f;
        float halfH = (h * scale) * 0.5f;
        outRect.set(cx - halfW, cy - halfH, cx + halfW, cy + halfH);
        float maxR = Math.min(halfW, halfH);
        outRadius[0] = Math.min(cornerPx * scale, maxR);
        return true;
    }

    void draw(Canvas canvas) {
        if (!enabled || !positioned || target == null) return;
        if (!target.isAttachedToWindow() || !target.isShown() || !target.hasFocus()) {
            clear();
            return;
        }
        syncTargetLive();
        drawBounds.set(left.value, top.value, right.value, bottom.value);
        if (drawBounds.width() <= 2f || drawBounds.height() <= 2f) return;

        float maxR = Math.min(drawBounds.width(), drawBounds.height()) * 0.5f;
        float r = Math.max(0f, Math.min(radius.value, maxR));
        float aFactor = Math.max(0f, Math.min(1f, alpha.value));

        // Soft outer luminous halo
        haloPaint.setAlpha(Math.round(0x34 * aFactor));
        haloPaint.setStrokeWidth(Math.max(2f, a.dp(4.2f)));
        canvas.drawRoundRect(drawBounds, r, r, haloPaint);

        // Crisp primary white focus ring
        ringPaint.setAlpha(Math.round(0xf4 * aFactor));
        ringPaint.setStrokeWidth(Math.max(2f, a.dp(2.2f)));
        canvas.drawRoundRect(drawBounds, r, r, ringPaint);
    }
}
