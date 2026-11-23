package com.pilipala.marcomovie.hud;

import android.content.Context;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.os.Build;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.View;
import android.widget.LinearLayout;
import android.widget.TextView;
import java.util.Locale;

/**
 * High-contrast, zero-blur Android TV seek preview capsule consuming {@code SeekGesture} state
 * (player-hud-spec.md §3.2).
 *
 * <p>Preserves {@code SeekGesture} and {@code InteractionProbe} assertions while presenting large,
 * 10-foot legible target timestamp, signed offset, and acceleration rate.
 */
public final class FastForwardScrubCapsule extends LinearLayout {
    private final TextView timeLine;
    private final TextView detailLine;
    private boolean reducedTransparency;
    private String lastTimeText = "";
    private String lastDetailText = "";

    public FastForwardScrubCapsule(Context context) {
        super(context);
        setTag("player-tv-scrub-capsule");
        setOrientation(VERTICAL);
        setGravity(Gravity.CENTER_HORIZONTAL);
        setFocusable(false);
        setClickable(false);
        setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO);
        setPadding(dp(22), dp(12), dp(22), dp(12));
        applySurface();

        timeLine = new TextView(context);
        timeLine.setTextSize(TypedValue.COMPLEX_UNIT_SP, 22f);
        timeLine.setTextColor(0xfff5f5f7);
        timeLine.setTypeface(Typeface.create("sans-serif-medium", Typeface.BOLD));
        timeLine.setFontFeatureSettings("tnum");
        timeLine.setSingleLine(true);
        timeLine.setIncludeFontPadding(false);
        addView(timeLine, new LayoutParams(-2, -2));

        detailLine = new TextView(context);
        detailLine.setTextSize(TypedValue.COMPLEX_UNIT_SP, 13.5f);
        detailLine.setTextColor(0xff70d7ff);
        detailLine.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        detailLine.setSingleLine(true);
        detailLine.setIncludeFontPadding(false);
        LayoutParams dLp = new LayoutParams(-2, -2);
        dLp.topMargin = dp(4);
        addView(detailLine, dLp);

        if (Build.VERSION.SDK_INT >= 21) {
            setElevation(dp(12));
        }
        setVisibility(View.GONE);
    }

    private int dp(float v) {
        float d = getResources() != null ? getResources().getDisplayMetrics().density : 1f;
        return Math.max(1, Math.round(v * d));
    }

    private void applySurface() {
        GradientDrawable bg = new GradientDrawable();
        bg.setCornerRadius(dp(16));
        bg.setColor(reducedTransparency ? 0xf516161a : 0xd916161a);
        bg.setStroke(Math.max(1, dp(1.5f)), reducedTransparency ? 0x73ffffff : 0x38ffffff);
        setBackground(bg);
    }

    public void setReducedTransparency(boolean reducedTransparency) {
        if (this.reducedTransparency != reducedTransparency) {
            this.reducedTransparency = reducedTransparency;
            applySurface();
        }
    }

    public static String formatClock(int ms) {
        int totalSec = Math.max(0, ms / 1000);
        int h = totalSec / 3600;
        int m = (totalSec % 3600) / 60;
        int s = totalSec % 60;
        if (h > 0) {
            return String.format(Locale.US, "%d:%02d:%02d", h, m, s);
        }
        return String.format(Locale.US, "%02d:%02d", m, s);
    }

    public static String formatSignedOffset(int deltaMs) {
        String sign = deltaMs >= 0 ? "+" : "-";
        return sign + formatClock(Math.abs(deltaMs));
    }

    public void updatePreview(
            int targetMs,
            int durationMs,
            int deltaMs,
            int direction,
            int speedSecPerSec,
            boolean accelerated) {
        String nextTime = formatClock(targetMs) + " / " + formatClock(durationMs);
        String dir = direction >= 0 ? "快进 " : "快退 ";
        String nextDetail =
                dir
                        + formatSignedOffset(deltaMs)
                        + (speedSecPerSec > 0
                                ? (accelerated ? " · 加速 " : " · ") + speedSecPerSec + " 秒/秒"
                                : " · 松开跳转");
        if (!nextTime.equals(lastTimeText)) {
            lastTimeText = nextTime;
            timeLine.setText(nextTime);
        }
        if (!nextDetail.equals(lastDetailText)) {
            lastDetailText = nextDetail;
            detailLine.setText(nextDetail);
        }
        if (getVisibility() != View.VISIBLE) {
            setVisibility(View.VISIBLE);
        }
    }

    public void hide() {
        if (getVisibility() != View.GONE) {
            setVisibility(View.GONE);
        }
    }
}
