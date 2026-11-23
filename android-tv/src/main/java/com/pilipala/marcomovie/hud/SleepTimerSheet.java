package com.pilipala.marcomovie.hud;

import android.content.Context;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.os.Build;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.View;
import android.widget.Button;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.TextView;
import java.util.concurrent.atomic.AtomicInteger;

/**
 * Session-scoped sleep timer controller and pre-expiry warning banner (player-hud-spec.md §4.5).
 *
 * <p>Cold-start default is OFF. Supports 15m / 30m / 60m / 90m / End-of-Episode presets, a 30s
 * pre-expiry warning banner with "+15m" extension or cancel, and zero blur/shaders for ARM32 TV.
 */
public final class SleepTimerSheet {
    public static final int MODE_OFF = 0;
    public static final int MODE_15M = 1;
    public static final int MODE_30M = 2;
    public static final int MODE_60M = 3;
    public static final int MODE_90M = 4;
    public static final int MODE_END_OF_EPISODE = 5;

    public static final long WARNING_WINDOW_MS = 30_000L;
    public static final long EXTEND_STEP_MS = 15L * 60_000L;

    public static final String[] PRESET_LABELS = {
        "关闭（默认）", "15 分钟后停止", "30 分钟后停止", "60 分钟后停止", "90 分钟后停止", "播完本集后停止"
    };

    private static final AtomicInteger FALLBACK_VIEW_ID = new AtomicInteger(0x4d300000);

    private SleepTimerSheet() {}

    /** Computes the top margin for the pre-expiry warning pill respecting mobile safe.top inset. */
    public static int computeWarningTopMarginPx(boolean tv, int safeTopPx, float density) {
        float d = density > 0f ? density : 1f;
        int base = Math.max(1, Math.round((tv ? 24f : 18f) * d));
        if (tv) return base;
        return Math.max(base, Math.max(0, safeTopPx) + base);
    }

    /**
     * Resolves {@code nextFocusUpId} for TV playback actions so D-pad Up reaches the 30s sleep
     * warning pill whenever visible instead of locking focus onto the action row itself.
     */
    public static int resolveActionUpFocusId(
            boolean warningVisible, int warningExtendBtnId, int fallbackUpId) {
        return warningVisible && warningExtendBtnId != View.NO_ID
                ? warningExtendBtnId
                : fallbackUpId;
    }

    private static int nextViewId() {
        if (Build.VERSION.SDK_INT >= 17) {
            return View.generateViewId();
        }
        return FALLBACK_VIEW_ID.getAndIncrement();
    }

    /** Pure-Java sleep timer state controller for deterministic JVM unit checks. */
    public static final class Controller {
        private int mode = MODE_OFF;
        private long deadlineMs = -1L;
        private boolean expired;

        public int getMode() {
            return mode;
        }

        public boolean isActive() {
            return mode != MODE_OFF && !expired;
        }

        public boolean isEndOfEpisodeMode() {
            return mode == MODE_END_OF_EPISODE && !expired;
        }

        public boolean isExpired() {
            return expired;
        }

        public void selectPreset(int presetMode, long nowMs) {
            expired = false;
            if (presetMode < MODE_OFF || presetMode > MODE_END_OF_EPISODE) {
                presetMode = MODE_OFF;
            }
            this.mode = presetMode;
            long minutes = minutesForMode(presetMode);
            if (minutes > 0L) {
                this.deadlineMs = nowMs + minutes * 60_000L;
            } else {
                this.deadlineMs = -1L;
            }
        }

        public static long minutesForMode(int mode) {
            switch (mode) {
                case MODE_15M:
                    return 15L;
                case MODE_30M:
                    return 30L;
                case MODE_60M:
                    return 60L;
                case MODE_90M:
                    return 90L;
                default:
                    return 0L;
            }
        }

        public void cancel() {
            mode = MODE_OFF;
            deadlineMs = -1L;
            expired = false;
        }

        /**
         * Clears the session-scoped sleep timer when exiting playback unless an in-place episode or
         * line switch is actively transitioning to the next player instance.
         */
        public void onPlayerSessionClosed(boolean preserveForInPlaceSwitch) {
            if (!preserveForInPlaceSwitch) {
                cancel();
            }
        }

        /**
         * Guards a newly opened playback session so an abandoned or already-expired timer from a
         * previous session can never immediately pause a newly opened video.
         */
        public void onNewPlaybackSession(boolean preserveFromInPlaceSwitch, long nowMs) {
            if (!preserveFromInPlaceSwitch) {
                cancel();
                return;
            }
            if (isActive() && deadlineMs >= 0L && nowMs >= deadlineMs) {
                cancel();
            }
        }

        public void extend15Minutes(long nowMs) {
            if (mode == MODE_OFF) {
                selectPreset(MODE_15M, nowMs);
                return;
            }
            expired = false;
            if (mode == MODE_END_OF_EPISODE) {
                mode = MODE_15M;
                deadlineMs = nowMs + EXTEND_STEP_MS;
            } else {
                long base = Math.max(nowMs, deadlineMs);
                deadlineMs = base + EXTEND_STEP_MS;
            }
        }

        public long remainingMs(long nowMs) {
            if (!isActive() || deadlineMs < 0L) return -1L;
            return Math.max(0L, deadlineMs - nowMs);
        }

        public boolean shouldShowPreExpiryWarning(long nowMs) {
            long rem = remainingMs(nowMs);
            return rem > 0L && rem <= WARNING_WINDOW_MS;
        }

        /** @return {@code true} if the countdown just reached zero and playback should pause. */
        public boolean tick(long nowMs) {
            if (!isActive() || deadlineMs < 0L) return false;
            if (nowMs >= deadlineMs) {
                expired = true;
                mode = MODE_OFF;
                deadlineMs = -1L;
                return true;
            }
            return false;
        }

        /** @return {@code true} if end-of-episode sleep mode should stop playback now. */
        public boolean onEpisodeCompleted() {
            if (isEndOfEpisodeMode()) {
                expired = true;
                mode = MODE_OFF;
                deadlineMs = -1L;
                return true;
            }
            return false;
        }

        public String summaryLabel(long nowMs) {
            if (!isActive()) return "关闭";
            if (mode == MODE_END_OF_EPISODE) return "播完本集";
            long rem = remainingMs(nowMs);
            if (rem <= 0L) return "即将停止";
            long sec = (rem + 999L) / 1000L;
            if (sec < 60L) return "剩 " + sec + " 秒";
            long min = (sec + 59L) / 60L;
            return "剩 " + min + " 分钟";
        }
    }

    /** Lightweight pre-expiry warning banner shown in the final 30 seconds. */
    public static final class WarningPill extends LinearLayout {
        private final boolean isTv;
        private final TextView label;
        private final Button extendBtn;
        private final Button cancelBtn;
        private Runnable touchInteractionHook;
        private boolean reducedTransparency;
        private int safeTopPx;
        private final Runnable focusExtendBtnRunnable =
                new Runnable() {
                    @Override
                    public void run() {
                        if (getVisibility() == View.VISIBLE) {
                            extendBtn.requestFocus();
                        }
                    }
                };

        public WarningPill(Context context, boolean tv, Runnable onExtend, Runnable onCancel) {
            super(context);
            this.isTv = tv;
            setTag("player-sleep-warning-pill");
            setOrientation(HORIZONTAL);
            setGravity(Gravity.CENTER_VERTICAL);
            setMotionEventSplittingEnabled(false);
            setPadding(dp(14), dp(8), dp(14), dp(8));
            applySurface();

            label = new TextView(context);
            label.setTextSize(TypedValue.COMPLEX_UNIT_SP, tv ? 14f : 12.5f);
            label.setTextColor(0xfff5f5f7);
            label.setTypeface(Typeface.create("sans-serif-medium", Typeface.BOLD));
            label.setSingleLine(true);
            label.setIncludeFontPadding(false);
            LayoutParams lblLp = new LayoutParams(-2, -2);
            lblLp.rightMargin = dp(10);
            addView(label, lblLp);

            extendBtn = makeButton(context, "+15 分钟", true);
            extendBtn.setId(nextViewId());
            extendBtn.setTag("player-sleep-extend");
            extendBtn.setOnClickListener(
                    v -> {
                        if (touchInteractionHook != null) touchInteractionHook.run();
                        if (onExtend != null) onExtend.run();
                    });
            LayoutParams extLp = new LayoutParams(-2, dp(tv ? 34 : 30));
            extLp.rightMargin = dp(6);
            addView(extendBtn, extLp);

            cancelBtn = makeButton(context, "取消", false);
            cancelBtn.setId(nextViewId());
            cancelBtn.setTag("player-sleep-cancel");
            cancelBtn.setOnClickListener(
                    v -> {
                        if (touchInteractionHook != null) touchInteractionHook.run();
                        if (onCancel != null) onCancel.run();
                    });
            addView(cancelBtn, new LayoutParams(-2, dp(tv ? 34 : 30)));

            if (tv) {
                extendBtn.setNextFocusLeftId(cancelBtn.getId());
                extendBtn.setNextFocusRightId(cancelBtn.getId());
                extendBtn.setNextFocusUpId(extendBtn.getId());
                cancelBtn.setNextFocusLeftId(extendBtn.getId());
                cancelBtn.setNextFocusRightId(extendBtn.getId());
                cancelBtn.setNextFocusUpId(cancelBtn.getId());
            }

            if (Build.VERSION.SDK_INT >= 21) {
                setElevation(dp(12));
            }
            setVisibility(View.GONE);
        }

        public void setTouchInteractionHook(Runnable touchInteractionHook) {
            this.touchInteractionHook = touchInteractionHook;
        }

        public int getExtendButtonId() {
            return extendBtn.getId();
        }

        public int getCancelButtonId() {
            return cancelBtn.getId();
        }

        public Button getExtendButton() {
            return extendBtn;
        }

        public Button getCancelButton() {
            return cancelBtn;
        }

        public boolean isShowing() {
            return getVisibility() == View.VISIBLE;
        }

        public void setDownFocusTargetId(int targetId) {
            if (!isTv) return;
            extendBtn.setNextFocusDownId(targetId);
            cancelBtn.setNextFocusDownId(targetId);
        }

        public void requestInitialTvFocus() {
            if (!isTv || getVisibility() != View.VISIBLE) return;
            extendBtn.removeCallbacks(focusExtendBtnRunnable);
            extendBtn.requestFocus();
            extendBtn.post(focusExtendBtnRunnable);
        }

        public void updateSafeTop(int safeTopPx) {
            this.safeTopPx = Math.max(0, safeTopPx);
            if (getLayoutParams() instanceof FrameLayout.LayoutParams) {
                FrameLayout.LayoutParams lp = (FrameLayout.LayoutParams) getLayoutParams();
                float d = getResources() != null ? getResources().getDisplayMetrics().density : 1f;
                int nextTop = computeWarningTopMarginPx(isTv, this.safeTopPx, d);
                if (lp.topMargin != nextTop) {
                    lp.topMargin = nextTop;
                    setLayoutParams(lp);
                }
            }
        }

        private int dp(float v) {
            float d = getResources() != null ? getResources().getDisplayMetrics().density : 1f;
            return Math.max(1, Math.round(v * d));
        }

        private Button makeButton(Context context, String text, boolean primary) {
            Button b = new Button(context);
            b.setText(text);
            b.setAllCaps(false);
            b.setIncludeFontPadding(false);
            b.setSingleLine(true);
            b.setMinWidth(0);
            b.setMinimumWidth(0);
            b.setMinHeight(0);
            b.setMinimumHeight(0);
            b.setGravity(Gravity.CENTER);
            b.setTextSize(TypedValue.COMPLEX_UNIT_SP, isTv ? 13f : 12f);
            b.setTypeface(Typeface.create("sans-serif-medium", Typeface.BOLD));
            b.setPadding(dp(10), 0, dp(10), 0);
            b.setFocusable(isTv);
            b.setFocusableInTouchMode(isTv);
            styleButton(b, primary, false);
            if (isTv) {
                b.setOnFocusChangeListener((v, f) -> styleButton(b, primary, f));
            }
            return b;
        }

        private void styleButton(Button b, boolean primary, boolean focused) {
            GradientDrawable gd = new GradientDrawable();
            gd.setCornerRadius(dp(999));
            if (focused) {
                gd.setColor(0xfff5f5f7);
                gd.setStroke(dp(2), 0xffffffff);
                b.setTextColor(0xff101013);
            } else if (primary) {
                gd.setColor(0xff0a84ff);
                b.setTextColor(0xffffffff);
            } else {
                gd.setColor(0x28ffffff);
                b.setTextColor(0xffe5e7eb);
            }
            b.setBackground(gd);
        }

        private void applySurface() {
            GradientDrawable gd = new GradientDrawable();
            gd.setCornerRadius(dp(999));
            gd.setColor(reducedTransparency ? 0xf516161a : 0xd916161a);
            gd.setStroke(Math.max(1, dp(1)), 0x66ff9f0a);
            setBackground(gd);
        }

        public void setReducedTransparency(boolean reducedTransparency) {
            if (this.reducedTransparency != reducedTransparency) {
                this.reducedTransparency = reducedTransparency;
                applySurface();
            }
        }

        public void showCountdownSeconds(long secondsLeft) {
            label.setText("⏱ 定时关闭 · 剩余 " + Math.max(1L, secondsLeft) + " 秒");
            if (getVisibility() != View.VISIBLE) {
                setVisibility(View.VISIBLE);
            }
        }

        public void hide() {
            extendBtn.removeCallbacks(focusExtendBtnRunnable);
            if (getVisibility() != View.GONE) {
                setVisibility(View.GONE);
            }
        }

        @Override
        protected void onDetachedFromWindow() {
            extendBtn.removeCallbacks(focusExtendBtnRunnable);
            super.onDetachedFromWindow();
        }
    }
}
