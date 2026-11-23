package com.pilipala.marcomovie;

import android.graphics.Rect;
import android.view.*;
import android.widget.ScrollView;

/** A single focus reveal policy; retargeting retains position and velocity. */
final class TvScrollView extends ScrollView {
    final MainActivity a;
    final MotionSpring spring = new MotionSpring(0, 28, .4f);
    final Rect tempRect = new Rect();
    final TvFocusFrame focusFrame;
    MotionLoop.Step motion;
    boolean focusing, layingOut;
    boolean readingMode;
    boolean suppressNextReveal;
    long lastReadingStep;
    int goal;

    TvScrollView(MainActivity host) {
        super(host);
        a = host;
        focusFrame = (host != null && host.isTvDevice()) ? new TvFocusFrame(host, this) : null;
        setOverScrollMode(OVER_SCROLL_NEVER);
        setSmoothScrollingEnabled(false);
        UiCompat.setDefaultFocusHighlightEnabled(this, false);
        setClipChildren(false);
        setClipToPadding(false);
    }

    void setFocusFrameEnabled(boolean enabled) {
        if (focusFrame != null) focusFrame.setEnabled(enabled);
    }

    @Override
    protected void dispatchDraw(android.graphics.Canvas canvas) {
        int save = canvas.save();
        canvas.clipRect(
                getScrollX(), getScrollY(), getScrollX() + getWidth(), getScrollY() + getHeight());
        super.dispatchDraw(canvas);
        if (focusFrame != null) focusFrame.draw(canvas);
        canvas.restoreToCount(save);
    }

    int limit() {
        return getChildCount() == 0
                ? 0
                : Math.max(
                        0,
                        getChildAt(0).getHeight()
                                - getHeight()
                                + getPaddingTop()
                                + getPaddingBottom());
    }

    int bound(int y) {
        return Math.max(0, Math.min(y, limit()));
    }

    void cancelMotion() {
        if (motion != null) MotionLoop.remove(motion);
        motion = null;
        spring.snap(getScrollY());
    }

    void moveTo(int y) {
        int end = bound(y);
        goal = end;
        if (a.reduced) {
            cancelMotion();
            spring.snap(end);
            super.scrollTo(0, end);
            return;
        }
        if (motion == null) spring.snap(getScrollY());
        spring.target(end);
        if (motion != null || getScrollY() == end && spring.velocity == 0) return;
        motion =
                seconds -> {
                    if (!isAttachedToWindow()) {
                        motion = null;
                        return false;
                    }
                    boolean moving = spring.step(seconds);
                    int next = bound(Math.round(spring.value));
                    if (next != getScrollY()) TvScrollView.super.scrollTo(0, next);
                    if (!moving) {
                        motion = null;
                        return false;
                    }
                    return true;
                };
        MotionLoop.add(motion);
    }

    void reveal(View focused) {
        if (suppressNextReveal) {
            suppressNextReveal = false;
            return;
        }
        if (focused == null || getHeight() == 0) return;
        tempRect.set(0, 0, focused.getWidth(), focused.getHeight());
        offsetDescendantRectToMyCoords(focused, tempRect);
        reveal(tempRect);
    }

    void reveal(Rect area) {
        int margin = readingMode ? a.dp(56) : a.dp(14);
        int reference = motion == null ? getScrollY() : goal;
        int top = reference + margin, bottom = reference + getHeight() - margin;
        int y = reference;
        // Small focus changes inside the destination's safe region do not move the page.
        if (area.height() > getHeight() - 2 * margin) y = area.top - margin;
        else if (area.top < top) y = area.top - Math.max(margin, (getHeight() - area.height()) / 3);
        else if (area.bottom > bottom)
            y = area.bottom - getHeight() + Math.max(margin, (getHeight() - area.height()) / 3);
        else return;
        moveTo(y);
    }

    @Override
    public void requestChildFocus(View child, View focused) {
        focusing = true;
        try {
            super.requestChildFocus(child, focused);
        } finally {
            focusing = false;
        }
        if (focusFrame != null) focusFrame.follow(focused);
        reveal(focused);
    }

    @Override
    public void scrollTo(int x, int y) {
        if (focusing) return;
        if (layingOut) {
            if (motion != null) return;
            super.scrollTo(x, y);
            spring.snap(getScrollY());
            return;
        }
        cancelMotion();
        super.scrollTo(x, y);
        spring.snap(getScrollY());
        goal = getScrollY();
    }

    @Override
    protected void onLayout(boolean changed, int l, int t, int r, int b) {
        layingOut = true;
        try {
            super.onLayout(changed, l, t, r, b);
        } finally {
            layingOut = false;
        }
        if (motion != null && goal > limit()) moveTo(limit());
    }

    @Override
    public boolean requestChildRectangleOnScreen(View child, Rect rectangle, boolean immediate) {
        if (focusing) return false;
        Rect area = new Rect(rectangle);
        offsetDescendantRectToMyCoords(child, area);
        int old = goal;
        if (immediate && !readingMode) {
            int delta = computeScrollDeltaToGetChildRectOnScreen(area);
            scrollTo(0, getScrollY() + delta);
        } else reveal(area);
        return old != goal || motion != null;
    }

    @Override
    public boolean dispatchKeyEvent(KeyEvent event) {
        int key = event.getKeyCode();
        if (readingMode
                && (key == KeyEvent.KEYCODE_DPAD_UP || key == KeyEvent.KEYCODE_DPAD_DOWN)
                && !event.isAltPressed()) return executeKeyEvent(event);
        return super.dispatchKeyEvent(event);
    }

    boolean readingKey(KeyEvent event, int direction, View focused, View next) {
        if (event.getRepeatCount() > 0 && event.getEventTime() - lastReadingStep < 90) return true;
        lastReadingStep = event.getEventTime();
        int reference = motion == null ? getScrollY() : goal;
        int top = reference + a.dp(12), bottom = reference + getHeight() - a.dp(12);
        // A focusable prose block (e.g. release notes) keeps reading until its edge.
        // Action rows move focus immediately even when the next row is off-screen.
        boolean readingText = focused instanceof android.widget.TextView && !focused.isClickable();
        boolean moreText = false;
        if (readingText) {
            Rect area = new Rect(0, 0, focused.getWidth(), focused.getHeight());
            offsetDescendantRectToMyCoords(focused, area);
            moreText = direction == FOCUS_DOWN ? area.bottom > bottom : area.top < top;
        }
        if (!moreText && next != null && next != this && next != focused) {
            if (next.requestFocus(direction)) {
                Rect area = new Rect(0, 0, next.getWidth(), next.getHeight());
                offsetDescendantRectToMyCoords(next, area);
                if (direction == FOCUS_UP && area.height() > getHeight() - a.dp(28))
                    moveTo(area.bottom - getHeight() + a.dp(14));
                return true;
            }
        }
        int lineHeight =
                readingText ? ((android.widget.TextView) focused).getLineHeight() : a.dp(24);
        int distance = TvReadingScrollPolicy.step(getHeight() - a.dp(24), lineHeight, a.dp(48));
        int step = distance * (direction == FOCUS_UP ? -1 : 1);
        // Limit queued travel while a remote sends rapid repeat events.
        int end = bound(reference + step);
        end = Math.max(getScrollY() - distance, Math.min(getScrollY() + distance, end));
        moveTo(end);
        return true;
    }

    @Override
    public boolean executeKeyEvent(KeyEvent event) {
        int key = event.getKeyCode();
        if ((key == KeyEvent.KEYCODE_DPAD_UP || key == KeyEvent.KEYCODE_DPAD_DOWN)
                && !event.isAltPressed()) {
            if (event.getAction() != KeyEvent.ACTION_DOWN) return true;
            int direction = key == KeyEvent.KEYCODE_DPAD_UP ? View.FOCUS_UP : View.FOCUS_DOWN;
            View focused = findFocus();
            if (focused == this) focused = null;
            View next = FocusFinder.getInstance().findNextFocus(this, focused, direction);
            if (readingMode) return readingKey(event, direction, focused, next);
            if (next != null && next != this) {
                next.requestFocus(direction);
                return true;
            }
            int end = key == KeyEvent.KEYCODE_DPAD_UP ? 0 : limit();
            if ((motion == null ? getScrollY() : goal) == end) return false;
            moveTo(end);
            return true;
        }
        return super.executeKeyEvent(event);
    }

    @Override
    public boolean dispatchTouchEvent(MotionEvent ev) {
        if (getAlpha() < 0.05f) return false;
        return super.dispatchTouchEvent(ev);
    }

    @Override
    public boolean onTouchEvent(MotionEvent event) {
        if (event.getActionMasked() == MotionEvent.ACTION_DOWN) cancelMotion();
        return super.onTouchEvent(event);
    }

    @Override
    protected void onAttachedToWindow() {
        super.onAttachedToWindow();
        if (focusFrame != null) focusFrame.onAttachedToWindow();
    }

    @Override
    protected void onDetachedFromWindow() {
        if (focusFrame != null) focusFrame.onDetachedFromWindow();
        cancelMotion();
        super.onDetachedFromWindow();
    }
}
