package com.pilipala.marcomovie.hud;

import android.content.Context;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.os.Build;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.View;
import android.view.animation.LinearInterpolator;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.TextView;
import com.pilipala.marcomovie.PlayerGestureStateMachine;
import java.util.Locale;

/**
 * Top-center speed boost & swipe-up speed lock capsule for touch playback (player-hud-spec.md
 * §4.3).
 *
 * <p>Pure solid high-contrast rounded surfaces with zero blur and zero shaders.
 */
public final class SpeedLockCapsule extends LinearLayout {
    public static final long LOCKED_DIM_DELAY_MS = 3000L;
    public static final float LOCKED_DIM_ALPHA = 0.72f;

    private final TextView primaryText;
    private final LinearLayout detentRow;
    private final TextView[] detentViews;
    private final TextView secondaryText;
    private final Runnable dimRunnable = this::applyDimmedAlpha;

    private boolean reducedMotion;
    private boolean reducedTransparency;
    private boolean lockedMode;
    private int safeTopPx;

    public SpeedLockCapsule(Context context) {
        super(context);
        setTag("player-speed-lock-capsule");
        setOrientation(VERTICAL);
        setGravity(Gravity.CENTER_HORIZONTAL);
        setFocusable(false);
        setClickable(false);
        setPadding(dp(16), dp(9), dp(16), dp(9));
        applySurface(false, false);

        primaryText = new TextView(context);
        primaryText.setTag("player-speed-primary");
        primaryText.setTextSize(TypedValue.COMPLEX_UNIT_SP, 13.5f);
        primaryText.setTextColor(0xfff5f5f7);
        primaryText.setTypeface(Typeface.create("sans-serif-medium", Typeface.BOLD));
        primaryText.setSingleLine(true);
        primaryText.setIncludeFontPadding(false);
        primaryText.setGravity(Gravity.CENTER);
        addView(primaryText, new LayoutParams(-2, -2));

        detentRow = new LinearLayout(context);
        detentRow.setOrientation(HORIZONTAL);
        detentRow.setGravity(Gravity.CENTER);
        LayoutParams detentRowLp = new LayoutParams(-2, -2);
        detentRowLp.topMargin = dp(6);
        float[] detents = PlayerGestureStateMachine.SPEED_DETENTS;
        detentViews = new TextView[detents.length];
        for (int i = 0; i < detents.length; i++) {
            TextView tv = new TextView(context);
            tv.setText(formatSpeed(detents[i]));
            tv.setTextSize(TypedValue.COMPLEX_UNIT_SP, 10.5f);
            tv.setTypeface(Typeface.create("sans-serif-medium", Typeface.BOLD));
            tv.setIncludeFontPadding(false);
            tv.setSingleLine(true);
            tv.setGravity(Gravity.CENTER);
            tv.setPadding(dp(6), dp(2), dp(6), dp(2));
            LayoutParams lp = new LayoutParams(-2, -2);
            if (i > 0) lp.leftMargin = dp(5);
            detentRow.addView(tv, lp);
            detentViews[i] = tv;
        }
        addView(detentRow, detentRowLp);

        secondaryText = new TextView(context);
        secondaryText.setTag("player-speed-secondary");
        secondaryText.setTextSize(TypedValue.COMPLEX_UNIT_SP, 11f);
        secondaryText.setTextColor(0xc8ebebf5);
        secondaryText.setSingleLine(true);
        secondaryText.setIncludeFontPadding(false);
        secondaryText.setGravity(Gravity.CENTER);
        LayoutParams secLp = new LayoutParams(-2, -2);
        secLp.topMargin = dp(5);
        addView(secondaryText, secLp);

        if (Build.VERSION.SDK_INT >= 21) {
            setElevation(dp(12));
        }
        setVisibility(View.GONE);
    }

    private int dp(float v) {
        float d = getResources() != null ? getResources().getDisplayMetrics().density : 1f;
        return Math.max(1, Math.round(v * d));
    }

    public static String formatSpeed(float speed) {
        if (Math.abs(speed - Math.round(speed)) < 0.01f) {
            return String.format(Locale.US, "%.1f×", speed);
        }
        if (Math.abs(speed * 10f - Math.round(speed * 10f)) < 0.01f) {
            return String.format(Locale.US, "%.1f×", speed);
        }
        return String.format(Locale.US, "%.2f×", speed);
    }

    public void setAccessibilityFlags(boolean reducedMotion, boolean reducedTransparency) {
        this.reducedMotion = reducedMotion;
        this.reducedTransparency = reducedTransparency;
    }

    public void updateSafeTop(int safeTopPx) {
        this.safeTopPx = Math.max(0, safeTopPx);
        if (getLayoutParams() instanceof FrameLayout.LayoutParams) {
            FrameLayout.LayoutParams lp = (FrameLayout.LayoutParams) getLayoutParams();
            int nextTop = Math.max(dp(16), this.safeTopPx + dp(16));
            if (lp.topMargin != nextTop) {
                lp.topMargin = nextTop;
                setLayoutParams(lp);
            }
        }
    }

    private void applySurface(boolean lockReady, boolean locked) {
        GradientDrawable bg = new GradientDrawable();
        bg.setCornerRadius(dp(locked ? 999 : 18));
        int fill;
        int stroke;
        if (lockReady) {
            fill = reducedTransparency ? 0xf51c3328 : 0xe8162b21;
            stroke = 0xff34d399;
        } else if (locked) {
            fill = reducedTransparency ? 0xf51e1e22 : 0xdc161820;
            stroke = 0x99ff9f0a;
        } else {
            fill = reducedTransparency ? 0xf51e1e22 : 0xdc16161a;
            stroke = 0x38ffffff;
        }
        bg.setColor(fill);
        bg.setStroke(Math.max(1, dp(lockReady ? 1.5f : 1f)), stroke);
        setBackground(bg);
    }

    private void updateDetentHighlight(int activeIndex) {
        for (int i = 0; i < detentViews.length; i++) {
            TextView tv = detentViews[i];
            boolean active = i == activeIndex;
            tv.setTextColor(active ? 0xff101216 : 0xb8d1d1da);
            GradientDrawable pill = new GradientDrawable();
            pill.setCornerRadius(dp(999));
            pill.setColor(active ? 0xff34d399 : 0x1effffff);
            tv.setBackground(pill);
        }
    }

    public void showBoosting(float speed, int detentIndex, boolean lockReady) {
        removeCallbacks(dimRunnable);
        animate().cancel();
        lockedMode = false;
        setClickable(false);
        setOnClickListener(null);
        setAlpha(1f);
        setPadding(dp(16), dp(9), dp(16), dp(9));
        applySurface(lockReady, false);

        String speedStr = formatSpeed(speed);
        primaryText.setText((lockReady ? "🔒 " : "⏩ ") + speedStr + " 倍速播放中");
        detentRow.setVisibility(View.VISIBLE);
        updateDetentHighlight(detentIndex);
        secondaryText.setVisibility(View.VISIBLE);
        secondaryText.setTextColor(lockReady ? 0xff63e682 : 0xc8ebebf5);
        secondaryText.setText(lockReady ? ("松手即可锁定 " + speedStr) : "左右滑动调速 · 上滑锁定");

        setVisibility(View.VISIBLE);
    }

    public void showLocked(float speed, Runnable onUnlockClick) {
        removeCallbacks(dimRunnable);
        animate().cancel();
        lockedMode = true;
        setAlpha(1f);
        setPadding(dp(14), dp(7), dp(14), dp(7));
        applySurface(false, true);

        String speedStr = formatSpeed(speed);
        primaryText.setText("🔒 " + speedStr + " 锁定中 · 点击恢复");
        detentRow.setVisibility(View.GONE);
        secondaryText.setVisibility(View.GONE);

        setClickable(true);
        setOnClickListener(
                v -> {
                    if (onUnlockClick != null) onUnlockClick.run();
                });
        setVisibility(View.VISIBLE);
        postDelayed(dimRunnable, LOCKED_DIM_DELAY_MS);
    }

    public void hide() {
        removeCallbacks(dimRunnable);
        animate().cancel();
        lockedMode = false;
        setClickable(false);
        setOnClickListener(null);
        setAlpha(1f);
        setVisibility(View.GONE);
    }

    @Override
    protected void onDetachedFromWindow() {
        removeCallbacks(dimRunnable);
        animate().cancel();
        super.onDetachedFromWindow();
    }

    private void applyDimmedAlpha() {
        if (!lockedMode || getVisibility() != View.VISIBLE) return;
        if (reducedMotion) {
            setAlpha(LOCKED_DIM_ALPHA);
        } else {
            animate()
                    .alpha(LOCKED_DIM_ALPHA)
                    .setDuration(220L)
                    .setInterpolator(new LinearInterpolator())
                    .start();
        }
    }
}
