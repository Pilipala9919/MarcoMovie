package com.pilipala.marcomovie;

import android.animation.ValueAnimator;
import android.graphics.*;
import android.view.*;
import android.widget.*;

/** Current-page playback feedback; never creates a navigation destination. */
final class PlaybackLoading extends FrameLayout {
    private final TextView speedView;
    private final NetworkSpeedMonitor speedMonitor;

    PlaybackLoading(MainActivity a) {
        super(a);
        setTag("playback-loading");
        UiCompat.setBackground(this, UiCompat.createFocusSafeColorBackground(0x66000000));
        UiCompat.setDefaultFocusHighlightEnabled(this, false);
        setFocusable(true);
        setFocusableInTouchMode(true);
        setClickable(true);
        LinearLayout pill = a.row();
        pill.setGravity(Gravity.CENTER_VERTICAL);
        pill.setPadding(a.dp(18), a.dp(13), a.dp(20), a.dp(13));
        android.graphics.drawable.GradientDrawable bg = a.bg(0xea141822, 18);
        bg.setStroke(Math.max(1, a.dp(1)), 0x38ffffff);
        pill.setBackground(bg);
        UiCompat.setElevation(pill, a.dp(12));
        BrandLogoLoaderView loader = new BrandLogoLoaderView(a);
        loader.setReducedMotion(a.reduced);
        loader.setActive(true);
        pill.addView(loader, new LinearLayout.LayoutParams(a.dp(28), a.dp(28)));

        boolean inPlayer = a.current != null && a.current.player && !a.miniMode;
        String videoTitle =
                a.playbackControls != null
                                && a.playbackControls.video != null
                                && a.playbackControls.video.title != null
                        ? a.playbackControls.video.title
                        : (a.playingBookmark != null && a.playingBookmark.title != null
                                ? a.playingBookmark.title
                                : "");
        String epName =
                inPlayer && a.activeEpisode != null && a.activeEpisode.name != null
                        ? a.activeEpisode.name
                        : "";
        String headline = inPlayer ? "正在加载播放…" : "正在解析播放地址…";
        String sub =
                inPlayer
                        ? PlayerChrome.formatLoadingSubtitle(videoTitle, epName)
                        : (a.isTvDevice() ? "按返回键可取消" : "");
        if (sub.isEmpty() && a.isTvDevice()) {
            sub = "按返回键可取消";
        }
        int cardMax =
                PlayerChrome.resolveLoadingCardMaxWidthPx(
                        a.windowWidth(), a.dp(40), a.dp(180), a.dp(a.isTvDevice() ? 360 : 288));
        int textMax = Math.max(a.dp(110), cardMax - a.dp(82));

        LinearLayout copy = new LinearLayout(a);
        copy.setOrientation(LinearLayout.VERTICAL);
        copy.setGravity(Gravity.CENTER_VERTICAL);
        LinearLayout.LayoutParams copyLp = new LinearLayout.LayoutParams(-2, -2);
        copyLp.leftMargin = a.dp(13);

        TextView titleView = a.text(headline, 14.5f, MainActivity.WHITE);
        titleView.setTypeface(Typeface.create("sans-serif-medium", Typeface.BOLD));
        titleView.setIncludeFontPadding(false);
        titleView.setSingleLine(true);
        titleView.setEllipsize(android.text.TextUtils.TruncateAt.END);
        titleView.setMaxWidth(textMax);
        copy.addView(titleView, new LinearLayout.LayoutParams(-2, -2));

        if (!sub.isEmpty()) {
            TextView subView = a.text(sub, 12f, 0xffb4c0d0);
            subView.setIncludeFontPadding(false);
            subView.setSingleLine(true);
            subView.setEllipsize(android.text.TextUtils.TruncateAt.END);
            subView.setMaxWidth(textMax);
            LinearLayout.LayoutParams subLp = new LinearLayout.LayoutParams(-2, -2);
            subLp.topMargin = a.dp(3);
            copy.addView(subView, subLp);
        }
        speedView = a.text(NetworkSpeedMonitor.formatSpeedLabel(-1L), 11.5f, 0xff5ac8fa);
        speedView.setTag("playback-loading-speed");
        speedView.setFontFeatureSettings("tnum");
        speedView.setIncludeFontPadding(false);
        speedView.setSingleLine(true);
        speedView.setMaxWidth(textMax);
        LinearLayout.LayoutParams spdLp = new LinearLayout.LayoutParams(-2, -2);
        spdLp.topMargin = a.dp(4);
        copy.addView(speedView, spdLp);

        speedMonitor =
                new NetworkSpeedMonitor(
                        () -> a.player != null ? a.player.networkSpeedBytesPerSec() : -1L,
                        (bps, formatted) -> speedView.setText(formatted));

        pill.addView(copy, copyLp);
        addView(pill, new FrameLayout.LayoutParams(-2, -2, Gravity.CENTER));
    }

    @Override
    protected void onAttachedToWindow() {
        super.onAttachedToWindow();
        if (speedMonitor != null) speedMonitor.start();
    }

    @Override
    protected void onDetachedFromWindow() {
        if (speedMonitor != null) speedMonitor.stop();
        super.onDetachedFromWindow();
    }

    static final class Ring extends View {
        final Paint paint = new Paint(3);
        ValueAnimator animation;
        float angle;

        Ring(MainActivity a) {
            super(a);
            paint.setStyle(Paint.Style.STROKE);
            paint.setStrokeWidth(a.dp(2));
            paint.setStrokeCap(Paint.Cap.ROUND);
            paint.setColor(MainActivity.WHITE);
        }

        protected void onAttachedToWindow() {
            super.onAttachedToWindow();
            animation = ValueAnimator.ofFloat(0, 360);
            animation.setDuration(900);
            animation.setRepeatCount(-1);
            animation.setInterpolator(new android.view.animation.LinearInterpolator());
            animation.addUpdateListener(
                    v -> {
                        angle = (float) v.getAnimatedValue();
                        invalidate();
                    });
            animation.start();
        }

        protected void onDetachedFromWindow() {
            if (animation != null) {
                animation.removeAllUpdateListeners();
                animation.cancel();
                animation = null;
            }
            super.onDetachedFromWindow();
        }

        protected void onDraw(Canvas c) {
            super.onDraw(c);
            float inset = paint.getStrokeWidth();
            c.drawArc(
                    new RectF(inset, inset, getWidth() - inset, getHeight() - inset),
                    angle,
                    260,
                    false,
                    paint);
        }
    }
}
