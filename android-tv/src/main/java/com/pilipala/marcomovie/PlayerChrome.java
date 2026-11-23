package com.pilipala.marcomovie;

import android.graphics.*;
import android.graphics.drawable.GradientDrawable;
import android.os.SystemClock;
import android.text.Editable;
import android.text.TextWatcher;
import android.view.*;
import android.widget.*;
import com.pilipala.marcomovie.hud.EpisodeHoldSwitchOverlay;
import com.pilipala.marcomovie.hud.FastForwardScrubCapsule;
import com.pilipala.marcomovie.hud.PlayerHudPrefs;
import com.pilipala.marcomovie.hud.SlimProgressBar;
import com.pilipala.marcomovie.hud.StartSpecBanner;

/** Three independent floating regions with one visibility/focus owner. */
final class PlayerChrome {
    static final boolean TV_TOP_RIGHT_HUD_FRAMELESS = true;
    static final String HUD_PROGRESS_FONT_FAMILY = "sans-serif-light";
    static final String HUD_CLOCK_FONT_FAMILY = "sans-serif-condensed";
    static final float HUD_PROGRESS_SIZE_U = 12.2f;
    static final float HUD_CLOCK_SIZE_U = 16.5f;

    final MainActivity a;
    final boolean modernTv;
    final boolean isLiveStream;
    final FrameLayout overlay;
    final View topShade, bottomShade;
    final LinearLayout dock, progress, heading;
    final LinearLayout actionHost, badgeRow;
    final LinearLayout mobileSpecBadgeRow;
    final LinearLayout loadingPill;
    final LinearLayout centerRow;
    final LinearLayout topActions;
    final LinearLayout tvTopRightHud;
    final StartSpecBanner startSpecBanner;
    final SlimProgressBar slimProgressBar;
    final FastForwardScrubCapsule tvScrubCapsule;
    final EpisodeHoldSwitchOverlay episodeHoldOverlay;

    /** Reserved empty mount slots for Wave 2 (FirstPlayGestureHint & BrandLogoLoader). */
    final FrameLayout firstPlayGestureHintSlot;

    final FrameLayout loadingIndicatorSlot;
    final BrandLogoLoaderView brandLoader;
    final TextView hudProgressView;
    final View hudDivider;
    final Button backBtn;
    final FrameLayout lockBtn;
    final LinearLayout unlockPill;
    final TextView rewindBtn, forwardBtn;
    final TextView loadingText,
            loadingSubText,
            loadingSpeedText,
            episodeLabel,
            titleView,
            seekHint,
            wallClock,
            persistentClock,
            cardTitleView;
    final Button fsBtn;
    final StateGlyph state;
    final View tvMinimalPauseBadge;
    final TextView resolution;
    final Cms.Video chromeVideo;
    final NetworkSpeedMonitor loadingSpeedMonitor;
    boolean loading = true;
    boolean buffering = false;
    int bufferingPercent = -1;
    boolean progressOnlyMode = false;
    boolean hdrSurfaceActive = false;
    final Rect windowInsets = new Rect();
    boolean layoutPending;
    String lastBadgeSignature = "";
    String lastWallClock = "";
    String lastPersistentClockText = "";
    String lastWallClockText = "";
    String lastHudProgressKey = "";

    static float modernUnit(MainActivity a) {
        int w = Math.max(1, a.windowWidth());
        int h = Math.max(1, a.windowHeight());
        return Math.min(Math.max(w, h) / 960f, Math.min(w, h) / 540f);
    }

    static int vp(MainActivity a, float v) {
        return Math.max(1, Math.round(v * modernUnit(a)));
    }

    private GradientDrawable chromeSurface(int color, float radiusDp, int strokeColor) {
        GradientDrawable d = a.bg(color, radiusDp);
        if (strokeColor != 0) {
            d.setStroke(Math.max(1, a.dp(1)), strokeColor);
        }
        return d;
    }

    private GradientDrawable modernSurface(int color, float radiusU, int strokeColor) {
        GradientDrawable d = new GradientDrawable();
        d.setColor(color);
        d.setCornerRadius(modernUnit(a) * radiusU);
        if (strokeColor != 0) {
            d.setStroke(Math.max(1, Math.round(modernUnit(a) * .75f)), strokeColor);
        }
        return d;
    }

    private String formatWallTime() {
        return String.valueOf(
                android.text.format.DateFormat.format("HH:mm", System.currentTimeMillis()));
    }

    private CharSequence styledWallTime(String raw) {
        if (raw == null) return "";
        int colon = raw.indexOf(':');
        if (colon < 0) return raw;
        android.text.SpannableString sp = new android.text.SpannableString(raw);
        sp.setSpan(
                new android.text.style.ReplacementSpan() {
                    @Override
                    public int getSize(
                            Paint paint,
                            CharSequence text,
                            int start,
                            int end,
                            Paint.FontMetricsInt fm) {
                        return Math.round(paint.measureText(":") * 1.15f);
                    }

                    @Override
                    public void draw(
                            Canvas canvas,
                            CharSequence text,
                            int start,
                            int end,
                            float x,
                            int top,
                            int y,
                            int bottom,
                            Paint paint) {
                        float w = Math.round(paint.measureText(":") * 1.15f);
                        float cx = x + w * .5f;
                        float capH = -paint.ascent() * .74f;
                        float cy = y - capH * .5f;
                        float gap = capH * .24f;
                        float r = Math.max(1.2f, paint.getTextSize() * .058f);
                        Paint.Style prevStyle = paint.getStyle();
                        paint.setStyle(Paint.Style.FILL);
                        canvas.drawCircle(cx, cy - gap, r, paint);
                        canvas.drawCircle(cx, cy + gap, r, paint);
                        paint.setStyle(prevStyle);
                    }
                },
                colon,
                colon + 1,
                android.text.Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
        return sp;
    }

    static CharSequence formatTvHudProgress(String elapsed, String total) {
        if (elapsed == null || elapsed.isEmpty()) return "";
        if (total == null || total.isEmpty()) return elapsed;
        String raw = elapsed + "/" + total;
        final int slash = elapsed.length();
        android.text.SpannableString sp = new android.text.SpannableString(raw);
        sp.setSpan(
                new android.text.style.ForegroundColorSpan(0xe2eaf6ff),
                0,
                slash,
                android.text.Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
        sp.setSpan(
                new android.text.style.ReplacementSpan() {
                    @Override
                    public int getSize(
                            Paint paint,
                            CharSequence text,
                            int start,
                            int end,
                            Paint.FontMetricsInt fm) {
                        return Math.round(paint.measureText("/") + paint.measureText("0") * 0.62f);
                    }

                    @Override
                    public void draw(
                            Canvas canvas,
                            CharSequence text,
                            int start,
                            int end,
                            float x,
                            int top,
                            int y,
                            int bottom,
                            Paint paint) {
                        int prevColor = paint.getColor();
                        paint.setColor(0x68c4d0e2);
                        float totalW =
                                Math.round(paint.measureText("/") + paint.measureText("0") * 0.62f);
                        float sw = paint.measureText("/");
                        canvas.drawText("/", x + (totalW - sw) * 0.5f, y, paint);
                        paint.setColor(prevColor);
                    }
                },
                slash,
                slash + 1,
                android.text.Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
        sp.setSpan(
                new android.text.style.ForegroundColorSpan(0xa0c8d4e6),
                slash + 1,
                raw.length(),
                android.text.Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
        return sp;
    }

    private String formatCardTitle(Cms.Video video, Cms.Episode episode) {
        String base = video != null && video.title != null ? video.title.trim() : "";
        String ep = episode != null && episode.name != null ? episode.name.trim() : "";
        boolean multi =
                a.activeLine != null
                        && a.activeLine.episodes != null
                        && a.activeLine.episodes.size() > 1;
        if (!ep.isEmpty() && !ep.equalsIgnoreCase(base)) {
            if (multi
                    || (!"正片".equals(ep)
                            && !"HD".equalsIgnoreCase(ep)
                            && !"4K".equalsIgnoreCase(ep)
                            && !"1080P".equalsIgnoreCase(ep)
                            && !"超清".equals(ep))) {
                return base.isEmpty() ? ep : base + " · " + ep;
            }
        }
        return base.isEmpty() ? ep : base;
    }

    private void renderBadgePills(java.util.List<String> badges) {
        if (badgeRow == null) return;
        float u = modernUnit(a);
        StringBuilder sig = new StringBuilder();
        sig.append(Math.round(u * 100)).append(':');
        for (int i = 0; i < badges.size(); i++) {
            if (i > 0) sig.append('|');
            sig.append(badges.get(i));
        }
        String nextSig = sig.toString();
        if (nextSig.equals(lastBadgeSignature)) return;
        lastBadgeSignature = nextSig;
        badgeRow.removeAllViews();
        for (int i = 0; i < badges.size(); i++) {
            String label = badges.get(i);
            if (label == null || label.isEmpty()) continue;
            TextView pill = a.text(label, 9f, 0xffcfd6e2);
            pill.setTextSize(android.util.TypedValue.COMPLEX_UNIT_PX, u * 8.8f);
            pill.setTypeface(Typeface.create("sans-serif-medium", Typeface.BOLD));
            if (android.os.Build.VERSION.SDK_INT >= 21) {
                pill.setLetterSpacing(0.03f);
            }
            pill.setSingleLine(true);
            pill.setIncludeFontPadding(false);
            pill.setGravity(Gravity.CENTER);
            pill.setPadding(
                    Math.round(u * 6.5f),
                    Math.round(u * 2.2f),
                    Math.round(u * 6.5f),
                    Math.round(u * 2.2f));
            String upper = label.toUpperCase(java.util.Locale.ROOT);
            int fillArgb = 0x1cffffff;
            int strokeArgb = 0x22ffffff;
            int textArgb = 0xffcfd6e2;
            if (upper.contains("DOLBY VISION")
                    || upper.startsWith("DOLBY P")
                    || upper.contains("DV ·")) {
                fillArgb = 0x385e5ce6;
                strokeArgb = 0x80bf5af2;
                textArgb = 0xffebd6ff;
            } else if (upper.contains("HDR10")
                    || upper.contains("HLG")
                    || "4K".equals(upper)
                    || "8K".equals(upper)) {
                fillArgb = 0x30ff9f0a;
                strokeArgb = 0x70ff9f0a;
                textArgb = 0xffffc766;
            } else if (upper.contains("ATMOS")
                    || upper.contains("TRUEHD")
                    || upper.contains("DTS")
                    || upper.contains("DD+")
                    || upper.contains("DOLBY AUDIO")) {
                fillArgb = 0x2e0a84ff;
                strokeArgb = 0x665ac8fa;
                textArgb = 0xff93e2ff;
            }
            pill.setTextColor(textArgb);
            pill.setBackground(modernSurface(fillArgb, 4.2f, strokeArgb));
            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-2, -2);
            if (i > 0) lp.leftMargin = Math.round(u * 5f);
            badgeRow.addView(pill, lp);
        }
    }

    PlayerChrome(MainActivity host, Cms.Video video, Cms.Episode episode, boolean live) {
        a = host;
        chromeVideo = video;
        isLiveStream = live;
        modernTv = a.isTvDevice() && a.prefs.getInt(Prefs.TV_PLAYER_STYLE, 0) == 0;
        overlay = new FrameLayout(a);
        overlay.setTag("player-chrome");
        overlay.setMotionEventSplittingEnabled(false);
        overlay.setClipChildren(true);
        overlay.setClipToPadding(true);
        overlay.addOnLayoutChangeListener(
                (view, l, t, r, b, ol, ot, or, ob) -> {
                    if (l != ol || t != ot || r != or || b != ob) scheduleLayout();
                });
        topShade = new View(a);
        if (a.isTvDevice()) {
            topShade.setBackground(
                    new GradientDrawable(
                            GradientDrawable.Orientation.TOP_BOTTOM,
                            new int[] {0x8c000000, 0x00000000}));
        } else {
            topShade.setBackgroundColor(Color.TRANSPARENT);
        }
        float u = modernUnit(a);
        overlay.addView(
                topShade,
                new FrameLayout.LayoutParams(
                        -1, a.isTvDevice() ? vp(a, 106) : a.dp(140), Gravity.TOP));
        bottomShade = new View(a);
        if (a.isTvDevice()) {
            bottomShade.setBackground(
                    new GradientDrawable(
                            GradientDrawable.Orientation.BOTTOM_TOP,
                            new int[] {modernTv ? 0x84000000 : 0x94000000, 0x00000000}));
        } else {
            bottomShade.setBackgroundColor(Color.TRANSPARENT);
        }
        overlay.addView(
                bottomShade,
                new FrameLayout.LayoutParams(
                        -1,
                        a.isTvDevice() ? vp(a, modernTv ? 172 : 196) : a.dp(200),
                        Gravity.BOTTOM));
        heading = a.vertical();
        heading.setTag("player-heading");
        heading.setMotionEventSplittingEnabled(false);
        if (!a.isTvDevice()) {
            topActions = a.row();
            topActions.setMotionEventSplittingEnabled(false);
            topActions.setGravity(Gravity.CENTER_VERTICAL);
            topActions.setPadding(0, 0, 0, a.dp(8));
            backBtn =
                    a.navButton(
                            "‹ 返回",
                            "player-back",
                            () -> {
                                cancelActiveTouchGesture();
                                PlaybackControls.clearSleepTimerOnLeave();
                                a.leavePlayback();
                            });
            backBtn.setTextColor(MainActivity.WHITE);
            backBtn.setBackground(chromeSurface(0xcc22222a, 17, 0x33ffffff));
            topActions.addView(backBtn, new LinearLayout.LayoutParams(-2, a.dp(34)));
            mobileSpecBadgeRow = a.row();
            mobileSpecBadgeRow.setTag("player-inline-spec-badges");
            mobileSpecBadgeRow.setGravity(Gravity.CENTER_VERTICAL);
            LinearLayout.LayoutParams specRowLp = new LinearLayout.LayoutParams(-2, -2);
            specRowLp.leftMargin = a.dp(10);
            topActions.addView(mobileSpecBadgeRow, specRowLp);
            View spacer = new View(a);
            topActions.addView(spacer, new LinearLayout.LayoutParams(0, 1, 1));
            // Orientation toggle lives only on the progress row ("全屏横屏 / 退出全屏").
            heading.addView(topActions, new LinearLayout.LayoutParams(-1, -2));
        } else {
            topActions = null;
            backBtn = null;
            mobileSpecBadgeRow = null;
        }
        LinearLayout titleRow = a.row();
        titleRow.setGravity(Gravity.CENTER_VERTICAL);
        titleView = a.text(video.title, a.isPortrait() ? 20 : 26, MainActivity.WHITE);
        if (a.isTvDevice()) {
            titleView.setTextSize(android.util.TypedValue.COMPLEX_UNIT_PX, u * 20.5f);
            titleView.setTypeface(Typeface.create("sans-serif-medium", Typeface.BOLD));
            titleView.setIncludeFontPadding(false);
            titleView.setShadowLayer(u * 3f, 0, u * 1.2f, 0xaa000000);
        } else {
            titleView.setTypeface(Typeface.create("sans-serif", Typeface.BOLD));
            titleView.getPaint().setFakeBoldText(true);
            titleView.setShadowLayer(a.dp(4), 0, a.dp(2), 0xdd000000);
        }
        titleView.setSingleLine();
        titleView.setEllipsize(android.text.TextUtils.TruncateAt.END);
        LinearLayout.LayoutParams titleLp =
                modernTv
                        ? new LinearLayout.LayoutParams(0, -2, 1)
                        : new LinearLayout.LayoutParams(-2, -2);
        titleLp.rightMargin = a.isTvDevice() ? vp(a, 12) : a.dp(10);
        titleRow.addView(titleView, titleLp);
        resolution = a.text("分辨率读取中", 11, 0xffeeeef2);
        resolution.setTag("player-resolution");
        resolution.setSingleLine();
        resolution.setEllipsize(android.text.TextUtils.TruncateAt.END);
        resolution.setPadding(a.dp(9), a.dp(3), a.dp(9), a.dp(3));
        resolution.setBackground(chromeSurface(0xb824242c, 10, 0x28ffffff));
        if (modernTv) resolution.setVisibility(View.GONE);
        titleRow.addView(resolution, new LinearLayout.LayoutParams(-2, -2));
        if (a.isTvDevice() && !modernTv) {
            titleRow.addView(new View(a), new LinearLayout.LayoutParams(0, 1, 1f));
        }
        if (a.isTvDevice()) {
            lastWallClock = formatWallTime();
            wallClock = a.text("", 15f, 0xcaf0f4fb);
            wallClock.setTag("player-wall-clock");
            wallClock.setTextSize(android.util.TypedValue.COMPLEX_UNIT_PX, u * 15.0f);
            wallClock.setTypeface(Typeface.create("sans-serif-light", Typeface.NORMAL));
            wallClock.setFontFeatureSettings("tnum");
            if (android.os.Build.VERSION.SDK_INT >= 21) {
                wallClock.setLetterSpacing(0.055f);
            }
            wallClock.setIncludeFontPadding(false);
            wallClock.setSingleLine();
            wallClock.setShadowLayer(u * 2.2f, 0, u * .8f, 0x66000000);
            wallClock.setText(styledWallTime(lastWallClock));
            titleRow.addView(wallClock, new LinearLayout.LayoutParams(-2, -2));
        } else {
            wallClock = null;
        }
        heading.addView(titleRow, new LinearLayout.LayoutParams(-1, -2));
        String line = a.activeLine == null ? "" : a.activeLine.name;
        episodeLabel =
                a.text(episode.name + (line.isEmpty() ? "" : "  ·  " + line), 14, 0xffdddddf);
        episodeLabel.setTag("player-episode");
        episodeLabel.setSingleLine();
        episodeLabel.setEllipsize(android.text.TextUtils.TruncateAt.END);
        episodeLabel.setPadding(0, a.dp(6), 0, 0);
        if (modernTv) episodeLabel.setVisibility(View.GONE);
        heading.addView(episodeLabel);
        a.playStatus = a.text("正在加载所选剧集…", 12, MainActivity.MUTED);
        if (modernTv) {
            a.playStatus.setTextSize(android.util.TypedValue.COMPLEX_UNIT_PX, u * 11f);
            a.playStatus.setPadding(0, vp(a, 3), 0, 0);
        } else {
            a.playStatus.setPadding(0, a.dp(6), 0, 0);
        }
        heading.addView(a.playStatus);
        FrameLayout.LayoutParams top = new FrameLayout.LayoutParams(-1, -2, Gravity.TOP);
        int width = a.windowWidth();
        int initialCardW = Math.max(vp(a, 260), Math.min(vp(a, 824), Math.round(width * 0.855f)));
        int sideMargin =
                a.isPortrait()
                        ? a.dp(20)
                        : (modernTv ? Math.max(vp(a, 24), (width - initialCardW) / 2) : a.dp(44));
        top.setMargins(sideMargin, modernTv ? vp(a, 22) : a.dp(24), sideMargin, 0);
        overlay.addView(heading, top);

        boolean mobileLandscape = !a.isTvDevice() && !a.isPortrait();
        if (modernTv) {
            fsBtn = null;
            dock = a.vertical();
            dock.setTag("player-dock");
            dock.setMotionEventSplittingEnabled(false);
            dock.setPadding(vp(a, 20), vp(a, 12.5f), vp(a, 20), vp(a, 11.5f));
            dock.setClipChildren(false);
            dock.setClipToPadding(false);
            dock.setClipToOutline(true);
            int cardColor =
                    a.prefs.getBoolean(Prefs.REDUCED_TRANSPARENCY, false) ? 0xf2191b22 : 0xdc181a21;
            dock.setBackground(modernSurface(cardColor, 19f, 0x24ffffff));
            UiCompat.setElevation(dock, vp(a, 10));

            LinearLayout headerRow = a.row();
            headerRow.setGravity(Gravity.CENTER_VERTICAL);
            headerRow.setClipChildren(false);
            headerRow.setClipToPadding(false);
            cardTitleView = a.text(formatCardTitle(video, episode), 14.5f, 0xfff5f7fb);
            cardTitleView.setTag("player-card-title");
            cardTitleView.setTextSize(android.util.TypedValue.COMPLEX_UNIT_PX, u * 14.5f);
            cardTitleView.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
            cardTitleView.setIncludeFontPadding(false);
            cardTitleView.setSingleLine(true);
            cardTitleView.setEllipsize(android.text.TextUtils.TruncateAt.END);
            LinearLayout.LayoutParams ctLp = new LinearLayout.LayoutParams(0, -2, 1);
            ctLp.rightMargin = vp(a, 14);
            headerRow.addView(cardTitleView, ctLp);

            actionHost = a.row();
            actionHost.setTag("player-action-host");
            actionHost.setGravity(Gravity.CENTER_VERTICAL | Gravity.RIGHT);
            actionHost.setClipChildren(false);
            actionHost.setClipToPadding(false);
            headerRow.addView(actionHost, new LinearLayout.LayoutParams(-2, -2));
            dock.addView(headerRow, new LinearLayout.LayoutParams(-1, -2));

            progress = a.vertical();
            progress.setTag("player-progress");
            progress.setMotionEventSplittingEnabled(false);
            progress.setClipChildren(false);
            progress.setClipToPadding(false);
            progress.setVisibility(live ? View.GONE : View.VISIBLE);
            LinearLayout.LayoutParams progLp = new LinearLayout.LayoutParams(-1, -2);
            progLp.topMargin = vp(a, 6);
            progLp.bottomMargin = vp(a, 5);
            dock.addView(progress, progLp);

            LinearLayout metaRow = a.row();
            metaRow.setGravity(Gravity.CENTER_VERTICAL);
            badgeRow = a.row();
            badgeRow.setTag("player-badges");
            badgeRow.setGravity(Gravity.CENTER_VERTICAL);
            metaRow.addView(badgeRow, new LinearLayout.LayoutParams(0, -2, 1));
            renderBadgePills(java.util.Collections.singletonList(live ? "直播频道" : "准备播放"));

            seekHint = a.text("", 11f, 0xffdce2ec);
            seekHint.setTag("player-seek-hint");
            seekHint.setTextSize(android.util.TypedValue.COMPLEX_UNIT_PX, u * 10.5f);
            seekHint.setIncludeFontPadding(false);
            seekHint.setGravity(Gravity.RIGHT | Gravity.CENTER_VERTICAL);
            seekHint.setPadding(0, 0, vp(a, 10), 0);
            seekHint.setVisibility(View.GONE);
            metaRow.addView(seekHint, new LinearLayout.LayoutParams(-2, -2));

            a.playClock = a.text(live ? "直播" : "--:-- / --:--", 11f, 0xffe4e9f2);
            a.playClock.setTextSize(android.util.TypedValue.COMPLEX_UNIT_PX, u * 11.0f);
            a.playClock.setTypeface(Typeface.create("sans-serif", Typeface.NORMAL));
            a.playClock.setFontFeatureSettings("tnum");
            a.playClock.setIncludeFontPadding(false);
            a.playClock.setGravity(Gravity.RIGHT | Gravity.CENTER_VERTICAL);
            metaRow.addView(a.playClock, new LinearLayout.LayoutParams(-2, -2));
            LinearLayout.LayoutParams metaLp = new LinearLayout.LayoutParams(-1, -2);
            if (live) metaLp.topMargin = vp(a, 8);
            dock.addView(metaRow, metaLp);

            FrameLayout.LayoutParams dockLp =
                    new FrameLayout.LayoutParams(
                            initialCardW, -2, Gravity.BOTTOM | Gravity.CENTER_HORIZONTAL);
            dockLp.bottomMargin = vp(a, 22);
            overlay.addView(dock, dockLp);
        } else {
            actionHost = null;
            badgeRow = null;
            cardTitleView = null;
            progress = a.vertical();
            progress.setTag("player-progress");
            progress.setMotionEventSplittingEnabled(false);
            progress.setClipChildren(false);
            progress.setClipToPadding(false);
            LinearLayout clockRow = a.row();
            a.playClock = a.text("--:-- / --:--", 12, MainActivity.WHITE);
            if (a.isTvDevice()) {
                a.playClock.setTextSize(android.util.TypedValue.COMPLEX_UNIT_PX, u * 12f);
                a.playClock.setFontFeatureSettings("tnum");
                a.playClock.setIncludeFontPadding(false);
                a.playClock.setShadowLayer(u * 2f, 0, u * 1f, 0x88000000);
            }
            a.playClock.setGravity(Gravity.LEFT | Gravity.CENTER_VERTICAL);
            a.playClock.setPadding(a.dp(6), 0, a.dp(12), a.isTvDevice() ? vp(a, 5) : 0);
            clockRow.addView(a.playClock, new LinearLayout.LayoutParams(0, -2, 1));
            seekHint = a.text("", 12, 0xffe5e7eb);
            seekHint.setTag("player-seek-hint");
            if (a.isTvDevice()) {
                seekHint.setTextSize(android.util.TypedValue.COMPLEX_UNIT_PX, u * 11.5f);
                seekHint.setIncludeFontPadding(false);
                seekHint.setShadowLayer(u * 2f, 0, u * 1f, 0x88000000);
            }
            seekHint.setGravity(Gravity.RIGHT | Gravity.CENTER_VERTICAL);
            seekHint.setPadding(a.dp(8), 0, a.dp(6), a.isTvDevice() ? vp(a, 5) : 0);
            seekHint.setVisibility(View.GONE);
            clockRow.addView(seekHint, new LinearLayout.LayoutParams(-2, -2));
            if (!a.isTvDevice()) {
                fsBtn =
                        a.navButton(
                                a.isPortrait() ? "⛶ 全屏横屏" : "⛶ 退出全屏",
                                "player-fullscreen",
                                () -> {
                                    cancelActiveTouchGesture();
                                    a.togglePlayerOrientation();
                                });
                fsBtn.setTextColor(MainActivity.WHITE);
                fsBtn.setTextSize(12);
                fsBtn.setMinHeight(a.dp(30));
                fsBtn.setMinimumHeight(a.dp(30));
                fsBtn.setPadding(a.dp(12), a.dp(4), a.dp(12), a.dp(4));
                fsBtn.setBackground(chromeSurface(0xcc22222a, 15, 0x33ffffff));
                clockRow.addView(fsBtn, new LinearLayout.LayoutParams(-2, a.dp(30)));
            } else {
                fsBtn = null;
            }
            progress.addView(clockRow, new LinearLayout.LayoutParams(-1, -2));
            FrameLayout.LayoutParams track;
            if (a.isTvDevice()) {
                track =
                        new FrameLayout.LayoutParams(
                                Math.min(vp(a, 824), Math.max(vp(a, 260), width - vp(a, 56))),
                                -2,
                                Gravity.BOTTOM | Gravity.CENTER_HORIZONTAL);
                track.bottomMargin = vp(a, 106);
            } else {
                int trackSideMargin = a.dp(mobileLandscape ? 20 : 22);
                track =
                        new FrameLayout.LayoutParams(
                                Math.max(a.dp(140), width - trackSideMargin * 2),
                                -2,
                                Gravity.BOTTOM | Gravity.CENTER_HORIZONTAL);
                track.leftMargin = trackSideMargin;
                track.rightMargin = trackSideMargin;
                track.bottomMargin = a.dp(mobileLandscape ? 12 : 20);
            }
            // Browsing live channels leaves a live session available for returning.
            // Only the currently playing source decides whether seeking is hidden.
            progress.setVisibility(live ? View.GONE : View.VISIBLE);
            overlay.addView(progress, track);

            dock = a.vertical();
            dock.setTag("player-dock");
            dock.setMotionEventSplittingEnabled(false);
            if (a.isTvDevice()) {
                dock.setPadding(vp(a, 12), vp(a, 7), vp(a, 12), vp(a, 7));
                dock.setClipChildren(false);
                dock.setClipToPadding(false);
                dock.setClipToOutline(true);
                int dockBg =
                        a.prefs.getBoolean(Prefs.REDUCED_TRANSPARENCY, false)
                                ? 0xf2161922
                                : 0xcf151923;
                dock.setBackground(modernSurface(dockBg, 24f, 0x26ffffff));
                UiCompat.setElevation(dock, vp(a, 10));
            } else {
                dock.setPadding(a.dp(3), a.dp(5), a.dp(3), a.dp(5));
                dock.setClipChildren(true);
                dock.setClipToPadding(true);
                dock.setClipToOutline(true);
                dock.setBackground(chromeSurface(0xd81c1c22, 24, 0x2affffff));
                UiCompat.setElevation(dock, a.dp(10));
            }
            FrameLayout.LayoutParams dockLp;
            if (a.isTvDevice()) {
                dockLp =
                        new FrameLayout.LayoutParams(
                                -2, -2, Gravity.BOTTOM | Gravity.CENTER_HORIZONTAL);
                dockLp.bottomMargin = vp(a, 18);
            } else {
                dockLp =
                        new FrameLayout.LayoutParams(
                                a.dp(mobileLandscape ? 48 : 52),
                                a.dp(mobileLandscape ? 276 : 356),
                                Gravity.RIGHT | Gravity.BOTTOM);
                dockLp.rightMargin = a.dp(10);
                dockLp.bottomMargin = a.dp(mobileLandscape ? 66 : 82);
            }
            overlay.addView(dock, dockLp);
        }

        state = new StateGlyph();
        state.setTag("player-state");
        state.setFocusable(false);
        state.setVisibility(View.GONE);
        state.setOnClickListener(
                v -> {
                    cancelActiveTouchGesture();
                    a.togglePlayback();
                    a.showControls(true);
                });
        if (!a.isTvDevice()) {
            centerRow = a.row();
            centerRow.setMotionEventSplittingEnabled(false);
            centerRow.setGravity(Gravity.CENTER);
            rewindBtn = buildSeekCircle("↺ 15s", -15000);
            forwardBtn = buildSeekCircle("15s ↻", 15000);
            LinearLayout.LayoutParams sideLp = new LinearLayout.LayoutParams(a.dp(58), a.dp(58));
            LinearLayout.LayoutParams centerLp = new LinearLayout.LayoutParams(a.dp(76), a.dp(76));
            centerLp.leftMargin = a.dp(28);
            centerLp.rightMargin = a.dp(28);
            boolean liveStream = episode != null && episode.media.optBoolean("live");
            if (liveStream) {
                rewindBtn.setVisibility(View.GONE);
                forwardBtn.setVisibility(View.GONE);
            }
            centerRow.addView(rewindBtn, sideLp);
            centerRow.addView(state, centerLp);
            centerRow.addView(forwardBtn, sideLp);
            overlay.addView(centerRow, new FrameLayout.LayoutParams(-2, -2, Gravity.CENTER));

            lockBtn = new FrameLayout(a);
            lockBtn.setTag("player-lock");
            lockBtn.setContentDescription("锁定屏幕");
            lockBtn.setClickable(true);
            lockBtn.setFocusable(false);
            lockBtn.setBackground(chromeSurface(0xb81c1c24, 999, 0x33ffffff));
            lockBtn.addView(
                    new PadlockGlyph(false, MainActivity.WHITE),
                    new FrameLayout.LayoutParams(a.dp(20), a.dp(20), Gravity.CENTER));
            a.pressFeedback(lockBtn);
            lockBtn.setOnClickListener(
                    v -> {
                        if (a.touchPlayerGesture != null) {
                            a.touchPlayerGesture.onScreenLockRequested();
                        }
                        if (a.playbackControls != null) {
                            a.playbackControls.onScreenLockRequested();
                        }
                        PlaybackController.setPlayerLocked(a, true);
                    });
            FrameLayout.LayoutParams lockLp =
                    new FrameLayout.LayoutParams(
                            a.dp(44), a.dp(44), Gravity.LEFT | Gravity.CENTER_VERTICAL);
            lockLp.leftMargin = a.dp(16);
            overlay.addView(lockBtn, lockLp);
        } else {
            centerRow = null;
            rewindBtn = null;
            forwardBtn = null;
            lockBtn = null;
            overlay.addView(
                    state, new FrameLayout.LayoutParams(a.dp(72), a.dp(72), Gravity.CENTER));
        }
        a.playbackLayer.addView(overlay, new FrameLayout.LayoutParams(-1, -1));

        if (!a.isTvDevice()) {
            unlockPill = a.row();
            unlockPill.setTag("player-unlock");
            unlockPill.setContentDescription("点击解锁屏幕");
            unlockPill.setClickable(true);
            unlockPill.setFocusable(false);
            unlockPill.setGravity(Gravity.CENTER_VERTICAL);
            unlockPill.setPadding(a.dp(14), a.dp(9), a.dp(16), a.dp(9));
            unlockPill.setBackground(chromeSurface(0xdc181a22, 999, 0x3dffffff));
            UiCompat.setElevation(unlockPill, a.dp(14));
            LinearLayout.LayoutParams iconLp = new LinearLayout.LayoutParams(a.dp(18), a.dp(18));
            iconLp.rightMargin = a.dp(7);
            unlockPill.addView(new PadlockGlyph(true, 0xffff9f0a), iconLp);
            TextView unlockLabel = a.text("点击解锁", 13.5f, MainActivity.WHITE);
            unlockLabel.setTypeface(Typeface.create("sans-serif-medium", Typeface.BOLD));
            unlockLabel.setIncludeFontPadding(false);
            unlockLabel.setSingleLine(true);
            unlockPill.addView(unlockLabel, new LinearLayout.LayoutParams(-2, -2));
            unlockPill.setVisibility(View.GONE);
            a.pressFeedback(unlockPill);
            unlockPill.setOnClickListener(
                    v -> {
                        cancelActiveTouchGesture();
                        PlaybackController.setPlayerLocked(a, false);
                    });
            FrameLayout.LayoutParams uLp =
                    new FrameLayout.LayoutParams(-2, -2, Gravity.LEFT | Gravity.CENTER_VERTICAL);
            uLp.leftMargin = a.dp(16);
            a.playbackLayer.addView(unlockPill, uLp);
        } else {
            unlockPill = null;
        }

        loadingPill = a.row();
        loadingPill.setTag("player-loading");
        loadingPill.setGravity(Gravity.CENTER_VERTICAL);
        loadingPill.setPadding(a.dp(18), a.dp(13), a.dp(20), a.dp(13));
        loadingPill.setBackground(chromeSurface(0xea141822, 18, 0x38ffffff));
        UiCompat.setElevation(loadingPill, a.dp(12));
        loadingIndicatorSlot = new FrameLayout(a);
        loadingIndicatorSlot.setTag("player-loading-indicator-slot");
        brandLoader = new BrandLogoLoaderView(a);
        brandLoader.setReducedMotion(a.reduced);
        brandLoader.setActive(true);
        loadingIndicatorSlot.addView(
                brandLoader, new FrameLayout.LayoutParams(a.dp(28), a.dp(28), Gravity.CENTER));
        loadingPill.addView(
                loadingIndicatorSlot, new LinearLayout.LayoutParams(a.dp(28), a.dp(28)));
        LinearLayout loadingCopy = new LinearLayout(a);
        loadingCopy.setOrientation(LinearLayout.VERTICAL);
        loadingCopy.setGravity(Gravity.CENTER_VERTICAL);
        LinearLayout.LayoutParams copyLp = new LinearLayout.LayoutParams(-2, -2);
        copyLp.leftMargin = a.dp(13);
        loadingText = a.text(resolveInitialLoadingHeadline(episode), 14.5f, MainActivity.WHITE);
        loadingText.setTypeface(Typeface.create("sans-serif-medium", Typeface.BOLD));
        loadingText.setIncludeFontPadding(false);
        loadingText.setSingleLine(true);
        loadingText.setEllipsize(android.text.TextUtils.TruncateAt.END);
        loadingCopy.addView(loadingText, new LinearLayout.LayoutParams(-2, -2));

        String loadingSub =
                formatLoadingSubtitle(
                        video != null ? video.title : "", episode != null ? episode.name : "");
        loadingSubText = a.text(loadingSub, 12f, 0xffb4c0d0);
        loadingSubText.setIncludeFontPadding(false);
        loadingSubText.setSingleLine(true);
        loadingSubText.setEllipsize(android.text.TextUtils.TruncateAt.END);
        loadingSubText.setVisibility(loadingSub.isEmpty() ? View.GONE : View.VISIBLE);
        LinearLayout.LayoutParams subLp = new LinearLayout.LayoutParams(-2, -2);
        subLp.topMargin = a.dp(3);
        loadingCopy.addView(loadingSubText, subLp);

        loadingSpeedText = a.text(NetworkSpeedMonitor.formatSpeedLabel(-1L), 11.5f, 0xff5ac8fa);
        loadingSpeedText.setTag("player-loading-speed");
        loadingSpeedText.setFontFeatureSettings("tnum");
        loadingSpeedText.setIncludeFontPadding(false);
        loadingSpeedText.setSingleLine(true);
        LinearLayout.LayoutParams spdLp = new LinearLayout.LayoutParams(-2, -2);
        spdLp.topMargin = a.dp(3);
        loadingCopy.addView(loadingSpeedText, spdLp);

        loadingSpeedMonitor =
                new NetworkSpeedMonitor(
                        () -> a.player != null ? a.player.networkSpeedBytesPerSec() : -1L,
                        (bps, formatted) -> {
                            if (loadingSpeedText != null) {
                                loadingSpeedText.setText(formatted);
                            }
                        });
        loadingPill.addOnAttachStateChangeListener(
                new View.OnAttachStateChangeListener() {
                    @Override
                    public void onViewAttachedToWindow(View v) {}

                    @Override
                    public void onViewDetachedFromWindow(View v) {
                        loadingSpeedMonitor.stop();
                    }
                });

        loadingPill.addView(loadingCopy, copyLp);
        applyLoadingCardBounds(a.windowWidth());
        a.playbackLayer.addView(loadingPill, new FrameLayout.LayoutParams(-2, -2, Gravity.CENTER));

        if (a.isTvDevice()) {
            tvMinimalPauseBadge = new MinimalPauseBadge();
            tvMinimalPauseBadge.setTag("player-minimal-pause");
            tvMinimalPauseBadge.setFocusable(false);
            tvMinimalPauseBadge.setClickable(false);
            tvMinimalPauseBadge.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO);
            tvMinimalPauseBadge.setVisibility(View.GONE);
            int badgeSize = vp(a, 54);
            a.playbackLayer.addView(
                    tvMinimalPauseBadge,
                    new FrameLayout.LayoutParams(badgeSize, badgeSize, Gravity.CENTER));
        } else {
            tvMinimalPauseBadge = null;
        }

        String initialPersistentTime = formatWallTime();
        if (a.isTvDevice()) {
            tvTopRightHud = a.row();
            tvTopRightHud.setTag("player-tv-top-right-hud");
            tvTopRightHud.setGravity(Gravity.CENTER_VERTICAL);
            tvTopRightHud.setFocusable(false);
            tvTopRightHud.setClickable(false);
            tvTopRightHud.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO);
            // Frameless cinematic floating typography — no outer box or pill border.
            tvTopRightHud.setBackground(null);
            tvTopRightHud.setPadding(0, 0, 0, 0);

            hudProgressView = a.text("", HUD_PROGRESS_SIZE_U, 0xd6dce6f4);
            hudProgressView.setTag("player-hud-progress");
            hudProgressView.setFocusable(false);
            hudProgressView.setClickable(false);
            hudProgressView.setTextSize(
                    android.util.TypedValue.COMPLEX_UNIT_PX, u * HUD_PROGRESS_SIZE_U);
            hudProgressView.setTypeface(Typeface.create(HUD_PROGRESS_FONT_FAMILY, Typeface.NORMAL));
            hudProgressView.setFontFeatureSettings("tnum");
            if (android.os.Build.VERSION.SDK_INT >= 21) {
                hudProgressView.setLetterSpacing(0.025f);
            }
            hudProgressView.setIncludeFontPadding(false);
            hudProgressView.setSingleLine();
            hudProgressView.setShadowLayer(u * 3.2f, 0, u * 1.0f, 0xc0000000);
            String initElapsed =
                    live
                            ? "直播"
                            : PlaybackController.formatTime(
                                    a.playingBookmark != null ? a.playingBookmark.position : 0);
            String initTotal =
                    live
                            ? ""
                            : (a.playingBookmark != null && a.playingBookmark.duration > 0
                                    ? PlaybackController.formatTime(a.playingBookmark.duration)
                                    : "--:--");
            lastHudProgressKey = initElapsed + "/" + initTotal;
            hudProgressView.setText(formatTvHudProgress(initElapsed, initTotal));
            tvTopRightHud.addView(hudProgressView, new LinearLayout.LayoutParams(-2, -2));

            hudDivider = new View(a);
            GradientDrawable divBg = new GradientDrawable();
            divBg.setColor(0x52ffffff);
            divBg.setCornerRadius(u * 1f);
            hudDivider.setBackground(divBg);
            LinearLayout.LayoutParams divLp =
                    new LinearLayout.LayoutParams(Math.max(1, Math.round(u * 1f)), vp(a, 12.5f));
            divLp.leftMargin = vp(a, 10);
            divLp.rightMargin = vp(a, 10);
            tvTopRightHud.addView(hudDivider, divLp);

            persistentClock = a.text("", HUD_CLOCK_SIZE_U, 0xfaffffff);
            persistentClock.setTag("player-persistent-clock");
            persistentClock.setFocusable(false);
            persistentClock.setClickable(false);
            persistentClock.setTextSize(
                    android.util.TypedValue.COMPLEX_UNIT_PX, u * HUD_CLOCK_SIZE_U);
            persistentClock.setTypeface(Typeface.create(HUD_CLOCK_FONT_FAMILY, Typeface.BOLD));
            persistentClock.setFontFeatureSettings("tnum");
            if (android.os.Build.VERSION.SDK_INT >= 21) {
                persistentClock.setLetterSpacing(0.04f);
            }
            persistentClock.setIncludeFontPadding(false);
            persistentClock.setSingleLine();
            persistentClock.setShadowLayer(u * 3.8f, 0, u * 1.2f, 0xd4000000);
            persistentClock.setText(styledWallTime(initialPersistentTime));
            tvTopRightHud.addView(persistentClock, new LinearLayout.LayoutParams(-2, -2));

            // Starts hidden because controlsVisible == true on entry; reveals automatically in
            // full-screen playback once the toolbar hides.
            tvTopRightHud.setVisibility(View.GONE);
            FrameLayout.LayoutParams hudLp =
                    new FrameLayout.LayoutParams(-2, -2, Gravity.TOP | Gravity.END);
            hudLp.topMargin = vp(a, 18);
            hudLp.rightMargin = vp(a, 26);
            a.playbackLayer.addView(tvTopRightHud, hudLp);
        } else {
            tvTopRightHud = null;
            hudProgressView = null;
            hudDivider = null;
            persistentClock = a.text("", 12.5f, 0xeef3f6fc);
            persistentClock.setTag("player-persistent-clock");
            persistentClock.setFocusable(false);
            persistentClock.setClickable(false);
            persistentClock.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO);
            persistentClock.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
            persistentClock.setFontFeatureSettings("tnum");
            if (android.os.Build.VERSION.SDK_INT >= 21) {
                persistentClock.setLetterSpacing(0.05f);
            }
            persistentClock.setIncludeFontPadding(false);
            persistentClock.setSingleLine();
            persistentClock.setPadding(a.dp(10), a.dp(4), a.dp(10), a.dp(4));
            persistentClock.setBackground(chromeSurface(0x7a10141a, 999, 0x24ffffff));
            persistentClock.setText(styledWallTime(initialPersistentTime));
            boolean showAlwaysClock =
                    !a.miniMode && a.prefs.getBoolean(Prefs.PLAYER_ALWAYS_SHOW_CLOCK, false);
            persistentClock.setVisibility(showAlwaysClock ? View.VISIBLE : View.GONE);
            FrameLayout.LayoutParams pClockLp =
                    new FrameLayout.LayoutParams(-2, -2, Gravity.TOP | Gravity.END);
            pClockLp.topMargin = a.dp(14);
            pClockLp.rightMargin = a.dp(18);
            a.playbackLayer.addView(persistentClock, pClockLp);
        }
        final Runnable persistentClockTicker =
                new Runnable() {
                    @Override
                    public void run() {
                        if (!persistentClock.isAttachedToWindow()
                                || a.playerChrome != PlayerChrome.this) return;
                        syncClockViews();
                        persistentClock.postDelayed(this, 15000);
                    }
                };
        persistentClock.addOnAttachStateChangeListener(
                new View.OnAttachStateChangeListener() {
                    @Override
                    public void onViewAttachedToWindow(View v) {
                        v.removeCallbacks(persistentClockTicker);
                        v.postDelayed(persistentClockTicker, 15000);
                    }

                    @Override
                    public void onViewDetachedFromWindow(View v) {
                        v.removeCallbacks(persistentClockTicker);
                    }
                });

        a.playerOverlay = overlay;
        a.controlsVisible = true;

        boolean reducedTransparency =
                a.prefs != null && a.prefs.getBoolean(Prefs.REDUCED_TRANSPARENCY, false);
        startSpecBanner = new StartSpecBanner(a, a.isTvDevice());
        startSpecBanner.setAccessibilityFlags(a.reduced, reducedTransparency);
        FrameLayout.LayoutParams specLp =
                new FrameLayout.LayoutParams(-2, -2, Gravity.TOP | Gravity.LEFT);
        specLp.leftMargin = a.dp(16);
        specLp.topMargin = a.dp(16);
        a.playbackLayer.addView(startSpecBanner, specLp);

        slimProgressBar = new SlimProgressBar(a, a.isTvDevice());
        slimProgressBar.setReducedMotion(a.reduced);
        a.playbackLayer.addView(
                slimProgressBar,
                new FrameLayout.LayoutParams(
                        -1, SlimProgressBar.preferredHeightPx(a, a.isTvDevice()), Gravity.BOTTOM));

        if (a.isTvDevice()) {
            tvScrubCapsule = new FastForwardScrubCapsule(a);
            tvScrubCapsule.setReducedTransparency(reducedTransparency);
            FrameLayout.LayoutParams scrubLp =
                    new FrameLayout.LayoutParams(-2, -2, Gravity.TOP | Gravity.CENTER_HORIZONTAL);
            scrubLp.topMargin = vp(a, 54);
            a.playbackLayer.addView(tvScrubCapsule, scrubLp);
            bindTvSeekHintObserver();

            episodeHoldOverlay =
                    new EpisodeHoldSwitchOverlay(
                            a,
                            direction -> {
                                if (a.isFinishing()
                                        || a.playerChrome != this
                                        || a.playbackControls == null) return;
                                if (a.playbackControls.step(direction)) {
                                    a.toast(direction < 0 ? "正在切换上一集" : "正在切换下一集");
                                } else {
                                    a.toast(direction < 0 ? "已经是第一集" : "已经是最后一集");
                                }
                            });
            episodeHoldOverlay.setReducedMotion(a.reduced);
            a.playbackLayer.addView(
                    episodeHoldOverlay,
                    new FrameLayout.LayoutParams(
                            EpisodeHoldSwitchOverlay.preferredWidthPx(a),
                            EpisodeHoldSwitchOverlay.preferredHeightPx(a),
                            Gravity.CENTER));
        } else {
            tvScrubCapsule = null;
            episodeHoldOverlay = null;
        }

        firstPlayGestureHintSlot = new FrameLayout(a);
        firstPlayGestureHintSlot.setTag("player-first-play-gesture-hint-slot");
        firstPlayGestureHintSlot.setFocusable(false);
        firstPlayGestureHintSlot.setClickable(false);
        firstPlayGestureHintSlot.setVisibility(View.GONE);
        a.playbackLayer.addView(firstPlayGestureHintSlot, new FrameLayout.LayoutParams(-1, -1));

        dock.addOnLayoutChangeListener(
                (view, l, t, r, b, ol, ot, or, ob) -> {
                    if (b - t != ob - ot) scheduleLayout();
                });
        progress.addOnLayoutChangeListener(
                (view, l, t, r, b, ol, ot, or, ob) -> {
                    if (b - t != ob - ot) scheduleLayout();
                });
        scheduleLayout();
    }

    private void cancelActiveTouchGesture() {
        if (a.touchPlayerGesture != null) {
            a.touchPlayerGesture.cancelActiveGesture();
        }
    }

    TextView buildSeekCircle(String label, int deltaMs) {
        TextView btn = a.text(label, 12, MainActivity.WHITE);
        btn.setGravity(Gravity.CENTER);
        btn.setTypeface(null, Typeface.BOLD);
        GradientDrawable bg = a.bg(0x99303034, 29);
        bg.setStroke(a.dp(1), 0x33ffffff);
        btn.setBackground(bg);
        btn.setOnClickListener(
                v -> {
                    cancelActiveTouchGesture();
                    if (a.player != null && a.prepared) {
                        int dur = Math.max(1, a.player.getDuration());
                        int cur =
                                a.playbackControls != null
                                        ? a.playbackControls.displayPosition(
                                                a.player.getCurrentPosition())
                                        : a.player.getCurrentPosition();
                        int next = Math.max(0, Math.min(dur, cur + deltaMs));
                        if (a.playbackControls != null) a.playbackControls.recordUserSeek(next);
                        a.player.seekTo(next);
                        if (a.playClock != null && dur > 1) {
                            a.playClock.setText(
                                    PlaybackController.formatTime(next)
                                            + " / "
                                            + PlaybackController.formatTime(dur));
                        }
                    }
                    a.showControls(true);
                });
        return btn;
    }

    void scheduleLayout() {
        if (layoutPending) return;
        layoutPending = true;
        overlay.post(
                () -> {
                    layoutPending = false;
                    if (a.playerChrome == this) relayout();
                });
    }

    void safeInsets(int left, int top, int right, int bottom) {
        windowInsets.set(left, top, right, bottom);
        relayout();
    }

    void relayout() {
        // A rotation request is not a measurement. OEM bars, multi-window and
        // embedded playback can all leave this layer smaller than the display.
        int measuredWidth = overlay.getWidth(), measuredHeight = overlay.getHeight();
        if (measuredWidth <= 0 || measuredHeight <= 0) return;
        boolean portrait = measuredWidth < measuredHeight;
        Rect safe = new Rect(0, 0, measuredWidth, measuredHeight);
        Rect visible = new Rect();
        if (overlay.getLocalVisibleRect(visible)) safe.intersect(visible);
        if (!a.isTvDevice()) {
            int[] location = new int[2];
            overlay.getLocationInWindow(location);
            View decor = a.getWindow().getDecorView();
            if (portrait) {
                safe.left = Math.max(safe.left, windowInsets.left - location[0]);
                safe.top =
                        Math.max(
                                safe.top,
                                Math.min(a.dp(48), Math.max(0, windowInsets.top - location[1])));
                safe.right =
                        Math.min(safe.right, decor.getWidth() - windowInsets.right - location[0]);
                safe.bottom =
                        Math.min(
                                safe.bottom,
                                decor.getHeight()
                                        - Math.min(a.dp(48), windowInsets.bottom)
                                        - location[1]);
            } else {
                int leftCutout = Math.min(a.dp(24), Math.max(0, windowInsets.left - location[0]));
                int rightCutout =
                        Math.min(
                                a.dp(24),
                                Math.max(
                                        0,
                                        windowInsets.right
                                                - Math.max(
                                                        0,
                                                        decor.getWidth()
                                                                - location[0]
                                                                - measuredWidth)));
                safe.left = Math.max(safe.left, leftCutout);
                safe.right = Math.min(safe.right, measuredWidth - rightCutout);
            }
        }
        safe.left = Math.max(0, Math.min(measuredWidth, safe.left));
        safe.top = Math.max(0, Math.min(measuredHeight, safe.top));
        safe.right = Math.max(safe.left, Math.min(measuredWidth, safe.right));
        safe.bottom = Math.max(safe.top, Math.min(measuredHeight, safe.bottom));
        overlay.setPadding(
                safe.left, safe.top, measuredWidth - safe.right, measuredHeight - safe.bottom);
        if (persistentClock != null
                && persistentClock.getLayoutParams() instanceof FrameLayout.LayoutParams) {
            FrameLayout.LayoutParams pLp =
                    (FrameLayout.LayoutParams) persistentClock.getLayoutParams();
            int nextTop = a.isTvDevice() ? vp(a, 22) : Math.max(a.dp(12), safe.top + a.dp(10));
            int nextRight =
                    a.isTvDevice()
                            ? vp(a, 32)
                            : Math.max(a.dp(16), (measuredWidth - safe.right) + a.dp(14));
            if (pLp.topMargin != nextTop || pLp.rightMargin != nextRight) {
                pLp.topMargin = nextTop;
                pLp.rightMargin = nextRight;
                persistentClock.setLayoutParams(pLp);
            }
        }
        if (unlockPill != null
                && unlockPill.getLayoutParams() instanceof FrameLayout.LayoutParams) {
            FrameLayout.LayoutParams uLp = (FrameLayout.LayoutParams) unlockPill.getLayoutParams();
            int nextLeft = Math.max(a.dp(16), safe.left + a.dp(12));
            if (uLp.leftMargin != nextLeft) {
                uLp.leftMargin = nextLeft;
                unlockPill.setLayoutParams(uLp);
            }
        }
        if (startSpecBanner != null) {
            int headingBottom = heading != null ? safe.top + heading.getBottom() : safe.top;
            startSpecBanner.updateSafeLayout(safe.left, safe.top, headingBottom);
        }
        if (a.touchPlayerGesture != null) {
            a.touchPlayerGesture.updateSafeTop(safe.top);
        }
        if (a.playbackControls != null) {
            a.playbackControls.updateSafeTop(safe.top);
        }
        int width = safe.width(), height = safe.height();
        boolean mobileLandscape = !a.isTvDevice() && !portrait;
        boolean compact = !a.isTvDevice() && (mobileLandscape || height < a.dp(440));
        if (topActions != null && backBtn != null) {
            topActions.setPadding(0, 0, 0, a.dp(compact ? 4 : 8));
            ViewGroup.LayoutParams backLp = backBtn.getLayoutParams();
            int backH = a.dp(compact ? 28 : 34);
            if (backLp != null && backLp.height != backH) {
                backLp.height = backH;
                backBtn.setLayoutParams(backLp);
            }
        }
        if (titleView != null) {
            if (modernTv) {
                titleView.setTextSize(
                        android.util.TypedValue.COMPLEX_UNIT_PX, modernUnit(a) * 20.5f);
            } else {
                titleView.setTextSize(compact ? 17 : (portrait ? 20 : 26));
            }
        }
        boolean ultraShort = !a.isTvDevice() && height < a.dp(325);
        episodeLabel.setTextSize(compact ? 12f : 13.5f);
        episodeLabel.setVisibility(modernTv || ultraShort ? View.GONE : View.VISIBLE);
        if (a.playStatus != null) {
            boolean showStatusOnCompact = !a.prepared && !loading;
            a.playStatus.setVisibility(
                    showStatusOnCompact
                            ? View.VISIBLE
                            : compact
                                    ? View.GONE
                                    : (a.isTvDevice() && a.prepared && a.playing && !loading
                                            ? View.GONE
                                            : View.VISIBLE));
        }
        if (fsBtn != null) {
            fsBtn.setText(portrait ? "⛶ 全屏横屏" : "⛶ 退出全屏");
        }
        if (centerRow != null && rewindBtn != null && forwardBtn != null) {
            int sideSz = a.dp(compact ? 44 : 54);
            int centerSz = a.dp(compact ? 56 : 70);
            int gap = a.dp(compact ? 20 : 26);
            LinearLayout.LayoutParams rLp = (LinearLayout.LayoutParams) rewindBtn.getLayoutParams();
            LinearLayout.LayoutParams fLp =
                    (LinearLayout.LayoutParams) forwardBtn.getLayoutParams();
            LinearLayout.LayoutParams cLp = (LinearLayout.LayoutParams) state.getLayoutParams();
            if (rLp.width != sideSz || cLp.width != centerSz || cLp.leftMargin != gap) {
                rLp.width = rLp.height = sideSz;
                fLp.width = fLp.height = sideSz;
                cLp.width = cLp.height = centerSz;
                cLp.leftMargin = cLp.rightMargin = gap;
                rewindBtn.setLayoutParams(rLp);
                forwardBtn.setLayoutParams(fLp);
                state.setLayoutParams(cLp);
            }
        }
        if (modernTv) {
            float u = modernUnit(a);
            if (wallClock != null) {
                wallClock.setTextSize(android.util.TypedValue.COMPLEX_UNIT_PX, u * 15.0f);
            }
            if (cardTitleView != null) {
                cardTitleView.setTextSize(android.util.TypedValue.COMPLEX_UNIT_PX, u * 14.5f);
            }
            if (a.playClock != null) {
                a.playClock.setTextSize(android.util.TypedValue.COMPLEX_UNIT_PX, u * 11.0f);
            }
            if (seekHint != null) {
                seekHint.setTextSize(android.util.TypedValue.COMPLEX_UNIT_PX, u * 10.5f);
            }
            dock.setPadding(vp(a, 20), vp(a, 12.5f), vp(a, 20), vp(a, 11.5f));
            int cardWidth = Math.max(vp(a, 260), Math.min(vp(a, 824), Math.round(width * 0.855f)));
            place(
                    dock,
                    cardWidth,
                    -2,
                    Gravity.BOTTOM | Gravity.CENTER_HORIZONTAL,
                    0,
                    0,
                    0,
                    vp(a, 22));
            int side = Math.max(vp(a, 24), (width - cardWidth) / 2);
            place(heading, -1, -2, Gravity.TOP, side, Math.min(vp(a, 22), height / 8), side, 0);
        } else if (a.isTvDevice()) {
            float u = modernUnit(a);
            if (wallClock != null) {
                wallClock.setTextSize(android.util.TypedValue.COMPLEX_UNIT_PX, u * 15.0f);
            }
            dock.setPadding(vp(a, 12), vp(a, 7), vp(a, 12), vp(a, 7));
            int dockBottom = vp(a, 18);
            place(dock, -2, -2, Gravity.BOTTOM | Gravity.CENTER_HORIZONTAL, 0, 0, 0, dockBottom);
            int side = Math.max(vp(a, 28), Math.round(width * 0.068f));
            int trackWidth = Math.max(vp(a, 260), Math.min(vp(a, 824), width - side * 2));
            int left = Math.max(0, (width - trackWidth) / 2);
            int progressHeight = Math.max(progress.getMeasuredHeight(), vp(a, 44));
            int dockH = Math.max(dock.getMeasuredHeight(), vp(a, 48));
            // Leave 40vp clear space above dock so focused-icon Chinese tooltip bubbles never touch
            // the upper timeline.
            int bottom = progressOnlyMode ? vp(a, 24) : (dockBottom + dockH + vp(a, 40));
            bottom = Math.max(0, Math.min(bottom, height - progressHeight));
            place(progress, trackWidth, -2, Gravity.BOTTOM | Gravity.LEFT, left, 0, left, bottom);
            place(heading, -1, -2, Gravity.TOP, left, Math.min(vp(a, 22), height / 8), left, 0);
        } else {
            int sideMargin = Math.min(a.dp(compact ? 20 : 22), Math.max(a.dp(12), width / 16));
            int trackWidth = Math.max(a.dp(120), width - sideMargin * 2);
            int progressHeight = Math.max(progress.getMeasuredHeight(), a.dp(compact ? 46 : 56));
            int bottom = Math.min(a.dp(compact ? 10 : 18), Math.max(0, height - progressHeight));
            place(
                    progress,
                    trackWidth,
                    -2,
                    Gravity.BOTTOM | Gravity.CENTER_HORIZONTAL,
                    sideMargin,
                    0,
                    sideMargin,
                    bottom);
            dock.setPadding(a.dp(3), a.dp(compact ? 4 : 6), a.dp(3), a.dp(compact ? 4 : 6));
            int dockWidth = a.dp(compact ? 48 : 52);
            int dockRight = Math.min(a.dp(10), Math.max(a.dp(6), width / 24));
            int dockBottom = bottom + progressHeight + a.dp(8);
            int dockTop = a.dp(compact ? 12 : 52);
            int availDockH = Math.max(a.dp(96), height - dockBottom - dockTop);
            int dockHeight = Math.min(a.dp(compact ? 286 : 368), availDockH);
            place(
                    dock,
                    dockWidth,
                    dockHeight,
                    Gravity.RIGHT | Gravity.BOTTOM,
                    0,
                    0,
                    dockRight,
                    dockBottom);
            int side = sideMargin;
            int headingRight = Math.max(side, dockWidth + dockRight + a.dp(12));
            place(
                    heading,
                    -1,
                    -2,
                    Gravity.TOP,
                    side,
                    Math.min(a.dp(compact ? 8 : 22), height / 8),
                    headingRight,
                    0);
            if (lockBtn != null) {
                int lockSz = a.dp(compact ? 42 : 44);
                int lockBottomOffset = width < a.dp(420) ? a.dp(74) : 0;
                place(
                        lockBtn,
                        lockSz,
                        lockSz,
                        Gravity.LEFT | Gravity.CENTER_VERTICAL,
                        sideMargin,
                        0,
                        0,
                        lockBottomOffset);
            }
        }
        if (a.playbackControls != null) {
            a.playbackControls.relayout(compact);
        }
        applyLoadingCardBounds(width);
    }

    private void applyLoadingCardBounds(int containerWidth) {
        if (loadingText == null || loadingSubText == null) return;
        int cardMax =
                resolveLoadingCardMaxWidthPx(
                        containerWidth, a.dp(40), a.dp(180), a.dp(a.isTvDevice() ? 360 : 288));
        int textMax = Math.max(a.dp(110), cardMax - a.dp(82));
        loadingText.setMaxWidth(textMax);
        loadingSubText.setMaxWidth(textMax);
        if (loadingSpeedText != null) loadingSpeedText.setMaxWidth(textMax);
    }

    static int resolveLoadingCardMaxWidthPx(
            int containerWidth, int sideMarginPx, int minWidthPx, int maxCapPx) {
        int safeCap = Math.max(1, maxCapPx);
        int safeMin = Math.max(1, Math.min(minWidthPx, safeCap));
        if (containerWidth <= 0) return safeCap;
        int available = Math.max(1, containerWidth - Math.max(0, sideMarginPx) * 2);
        return Math.max(Math.min(safeMin, available), Math.min(safeCap, available));
    }

    private static final java.util.regex.Pattern LOADING_SIZE_TAG_PATTERN =
            java.util.regex.Pattern.compile(
                    "(?i)[\\[\\(【（]\\s*(\\d+(?:\\.\\d+)?\\s*(?:TB|GB|MB|GiB|MiB))\\s*[\\]\\)】）]");
    private static final java.util.regex.Pattern LOADING_EPISODE_MARKER_PATTERN =
            java.util.regex.Pattern.compile(
                    "(?i)(第\\s*\\d+\\s*[集话期]|(?:^|[^a-z0-9])(S\\d{1,2}E\\d{1,3}|EP?\\d{1,3})(?:$|[^a-z0-9]))");
    private static final java.util.regex.Pattern LOADING_RAW_RELEASE_PATTERN =
            java.util.regex.Pattern.compile(
                    "(?i)(?:\\.(?:mkv|mp4|m4v|avi|ts|m2ts|mov|webm|flv)(?:$|[^a-z0-9])|"
                            + "(?:^|[^a-z0-9])(?:web[-.]?dl|webrip|bluray|remux|2160p|1080p|720p|"
                            + "h\\.?265|h\\.?264|x265|x264|hevc|ddp\\d|atmos|hdr10)(?:$|[^a-z0-9]))");

    static String formatLoadingSubtitle(String videoTitle, String episodeName) {
        String title = videoTitle == null ? "" : videoTitle.trim();
        String ep = episodeName == null ? "" : episodeName.trim();
        String out;
        if (ep.isEmpty() || ep.equalsIgnoreCase(title) || isGenericEpisodeLabel(ep)) {
            out = title;
        } else {
            boolean rawFilename =
                    ep.length() > 26 || LOADING_RAW_RELEASE_PATTERN.matcher(ep).find();
            if (rawFilename) {
                String epMarker = extractEpisodeMarker(ep);
                String sizeTag = extractSizeTag(ep);
                if (!title.isEmpty()) {
                    if (!epMarker.isEmpty()) {
                        out = title + " · " + epMarker;
                    } else if (!sizeTag.isEmpty()) {
                        out = title + " · " + sizeTag;
                    } else {
                        out = title;
                    }
                } else if (!epMarker.isEmpty()) {
                    out = sizeTag.isEmpty() ? epMarker : epMarker + " · " + sizeTag;
                } else {
                    String cleaned =
                            LOADING_SIZE_TAG_PATTERN
                                    .matcher(ep)
                                    .replaceAll(" ")
                                    .replaceAll(
                                            "(?i)\\.(?:mkv|mp4|m4v|avi|ts|m2ts|mov|webm|flv)$", "")
                                    .replaceAll("\\s+", " ")
                                    .trim();
                    out = cleaned.isEmpty() ? ep : cleaned;
                }
            } else {
                out = title.isEmpty() ? ep : title + " · " + ep;
            }
        }
        return clampLoadingText(out, 34);
    }

    private static boolean isGenericEpisodeLabel(String ep) {
        return "正片".equals(ep)
                || "HD".equalsIgnoreCase(ep)
                || "4K".equalsIgnoreCase(ep)
                || "1080P".equalsIgnoreCase(ep)
                || "超清".equals(ep);
    }

    private static String extractEpisodeMarker(String raw) {
        java.util.regex.Matcher m = LOADING_EPISODE_MARKER_PATTERN.matcher(raw);
        if (!m.find()) return "";
        String g2 = m.group(2);
        String token = (g2 != null && !g2.isEmpty()) ? g2 : m.group(1);
        return token == null ? "" : token.replaceAll("\\s+", "").toUpperCase(java.util.Locale.ROOT);
    }

    private static String extractSizeTag(String raw) {
        java.util.regex.Matcher m = LOADING_SIZE_TAG_PATTERN.matcher(raw);
        if (!m.find()) return "";
        String g1 = m.group(1);
        return g1 == null ? "" : g1.replaceAll("\\s+", "").toUpperCase(java.util.Locale.ROOT);
    }

    private static String clampLoadingText(String text, int maxChars) {
        if (text == null) return "";
        String trimmed = text.trim();
        if (trimmed.length() <= maxChars) return trimmed;
        return trimmed.substring(0, Math.max(1, maxChars - 1)).trim() + "…";
    }

    private static String resolveInitialLoadingHeadline(Cms.Episode episode) {
        if (episode != null && episode.media != null) {
            int qIdx = episode.media.optInt("_qualityIdx", 0);
            org.json.JSONArray qualities = episode.media.optJSONArray("qualities");
            if (qIdx > 0 && qualities != null && qIdx < qualities.length()) {
                org.json.JSONObject q = qualities.optJSONObject(qIdx);
                String qName = q != null ? q.optString("name", "").trim() : "";
                if (!qName.isEmpty()) {
                    return "正在切换至 " + clampLoadingText(qName, 14) + "…";
                }
            }
        }
        return "正在加载播放…";
    }

    void setLoadingStatus(String headline, String subtitle) {
        if (loadingText != null && headline != null && !headline.trim().isEmpty()) {
            loadingText.setText(clampLoadingText(headline, 22));
        }
        if (loadingSubText != null && subtitle != null) {
            String sub = clampLoadingText(subtitle, 34);
            loadingSubText.setText(sub);
            loadingSubText.setVisibility(sub.isEmpty() ? View.GONE : View.VISIBLE);
        }
    }

    private void place(
            View view,
            int width,
            int height,
            int gravity,
            int left,
            int top,
            int right,
            int bottom) {
        FrameLayout.LayoutParams p = (FrameLayout.LayoutParams) view.getLayoutParams();
        if (p.width == width
                && p.height == height
                && p.gravity == gravity
                && p.leftMargin == left
                && p.topMargin == top
                && p.rightMargin == right
                && p.bottomMargin == bottom) return;
        p.width = width;
        p.height = height;
        p.gravity = gravity;
        p.setMargins(left, top, right, bottom);
        view.setLayoutParams(p);
    }

    private void bindTvSeekHintObserver() {
        if (tvScrubCapsule == null || seekHint == null) return;
        seekHint.addTextChangedListener(
                new TextWatcher() {
                    @Override
                    public void beforeTextChanged(
                            CharSequence s, int start, int count, int after) {}

                    @Override
                    public void onTextChanged(CharSequence s, int start, int before, int count) {}

                    @Override
                    public void afterTextChanged(Editable s) {
                        syncTvScrubCapsule();
                    }
                });
    }

    void syncTvScrubCapsule() {
        if (tvScrubCapsule == null) return;
        if (a.seekGesture.active && a.seekGesture.duration > 0) {
            long now = SystemClock.uptimeMillis();
            int curPos =
                    a.player != null && a.prepared
                            ? a.player.getCurrentPosition()
                            : a.seekGesture.initialTarget;
            tvScrubCapsule.updatePreview(
                    a.seekGesture.target,
                    a.seekGesture.duration,
                    a.seekGesture.target - curPos,
                    a.seekGesture.direction,
                    a.seekGesture.speed(now),
                    a.seekGesture.accelerated(now));
        } else {
            tvScrubCapsule.hide();
        }
    }

    private void renderMobileInlineSpecBadges(java.util.List<StartSpecBanner.Badge> badges) {
        if (mobileSpecBadgeRow == null) return;
        mobileSpecBadgeRow.removeAllViews();
        if (badges == null || badges.isEmpty()) {
            mobileSpecBadgeRow.setVisibility(View.GONE);
            return;
        }
        boolean solid = a.prefs != null && a.prefs.getBoolean(Prefs.REDUCED_TRANSPARENCY, false);
        int limit = Math.min(3, badges.size());
        for (int i = 0; i < limit; i++) {
            StartSpecBanner.Badge b = badges.get(i);
            TextView pill = a.text(b.label, 10.5f, b.textArgb);
            pill.setTypeface(Typeface.create("sans-serif-medium", Typeface.BOLD));
            pill.setSingleLine(true);
            pill.setIncludeFontPadding(false);
            pill.setGravity(Gravity.CENTER);
            pill.setPadding(a.dp(6), a.dp(2), a.dp(6), a.dp(2));
            GradientDrawable bg = a.bg(solid ? b.solidFillArgb : b.fillArgb, 5);
            bg.setStroke(Math.max(1, a.dp(1)), b.strokeArgb);
            pill.setBackground(bg);
            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-2, -2);
            if (i > 0) lp.leftMargin = a.dp(4);
            mobileSpecBadgeRow.addView(pill, lp);
        }
        mobileSpecBadgeRow.setVisibility(View.VISIBLE);
    }

    void resolution(int width, int height) {
        if (a.player != null && a.prepared) {
            resolution.setText(a.player.videoResolution());
        } else {
            resolution.setText(width > 0 && height > 0 ? width + " × " + height : "分辨率未知");
        }
        if (width > 0 && height > 0 && startSpecBanner != null) {
            java.util.List<String> trackBadges =
                    a.player != null && a.prepared
                            ? a.player.mediaBadges()
                            : java.util.Collections.emptyList();
            String lineName =
                    a.activeLine != null && a.activeLine.name != null ? a.activeLine.name : "";
            String epName =
                    a.activeEpisode != null && a.activeEpisode.name != null
                            ? a.activeEpisode.name
                            : "";
            boolean specEnabled = PlayerHudPrefs.isStartSpecHudEnabled(a);
            startSpecBanner.scheduleIfReady(
                    trackBadges,
                    width,
                    height,
                    lineName,
                    epName,
                    specEnabled,
                    isLiveStream,
                    a.miniMode,
                    a.controlsVisible);
            renderMobileInlineSpecBadges(startSpecBanner.getLatestBadges());
        }
    }

    void setLoading(boolean value) {
        loading = value;
        if (!value) {
            buffering = false;
            bufferingPercent = -1;
        }
        update();
    }

    void setBuffering(boolean active, int percent) {
        buffering = active;
        bufferingPercent = percent;
        if (active && a.prepared) {
            String head = (percent >= 0 && percent < 100) ? ("正在缓冲 " + percent + "%") : "正在缓冲…";
            setLoadingStatus(head, null);
        }
        update();
    }

    void setHdrSurfaceActive(boolean active) {
        if (this.hdrSurfaceActive == active) return;
        this.hdrSurfaceActive = active;
        update();
    }

    void cancelEpisodeHoldSwitch() {
        if (episodeHoldOverlay != null) {
            episodeHoldOverlay.cancel();
        }
    }

    /**
     * Suppresses background 1Hz RGBA HUD redraws on Android TV HDR SurfaceView playback while
     * main controls are hidden so Amlogic/MediaTek HWC2 compositors remain locked in hardware HDR
     * VPP overlay instead of periodically dropping into GPU mixed composition (which flashes HDR
     * video toward SDR for ~200–300ms per HUD tick).
     */
    static boolean shouldSuppressLiveHudRedraws(
            boolean tvDevice, boolean hdrSurfaceActive, boolean controlsVisible) {
        return tvDevice && hdrSurfaceActive && !controlsVisible;
    }

    void switchEpisode(Cms.Episode episode, Cms.Line line) {
        cancelEpisodeHoldSwitch();
        hdrSurfaceActive = false;
        PlaybackControls.markSleepTimerInPlaceSwitch();
        if (startSpecBanner != null) startSpecBanner.resetEpisode();
        if (mobileSpecBadgeRow != null) {
            mobileSpecBadgeRow.removeAllViews();
            mobileSpecBadgeRow.setVisibility(View.GONE);
        }
        if (a.touchPlayerGesture != null) {
            a.touchPlayerGesture.onEpisodeSwitch();
        }
        if (a.playbackControls != null) {
            a.playbackControls.resetEpisodeTransientState();
        }
        String lineName = line == null || line.name == null ? "" : line.name;
        String epName = episode == null || episode.name == null ? "" : episode.name;
        episodeLabel.setText(epName + (lineName.isEmpty() ? "" : "  ·  " + lineName));
        if (cardTitleView != null) {
            cardTitleView.setText(formatCardTitle(chromeVideo, episode));
        }
        resolution.setText("分辨率读取中");
        String loadingSub =
                formatLoadingSubtitle(chromeVideo != null ? chromeVideo.title : "", epName);
        if (a.playStatus != null) a.playStatus.setText("正在加载播放…");
        setLoadingStatus("正在切换剧集…", loadingSub);
        buffering = false;
        bufferingPercent = -1;
        loading = true;
        update();
    }

    /**
     * Resolves progress-only seek preview mode independently from {@code player_slim_progress},
     * which only governs the persistent 2dp {@link SlimProgressBar} while HUD controls are hidden.
     */
    static boolean resolveProgressOnlyMode(
            boolean requestedProgressOnly, boolean slimProgressEnabled) {
        return requestedProgressOnly;
    }

    static boolean shouldShowSlimProgressBar(
            boolean controlsVisible,
            boolean miniMode,
            boolean live,
            boolean prepared,
            int durationMs,
            boolean slimProgressEnabled) {
        return !controlsVisible
                && !miniMode
                && !live
                && prepared
                && durationMs > 0
                && slimProgressEnabled;
    }

    void setProgressOnlyMode(boolean progressOnly) {
        boolean resolved =
                resolveProgressOnlyMode(progressOnly, PlayerHudPrefs.isSlimProgressEnabled(a));
        if (this.progressOnlyMode == resolved) return;
        this.progressOnlyMode = resolved;
        int otherVis = resolved ? View.INVISIBLE : View.VISIBLE;
        topShade.setVisibility(otherVis);
        heading.setVisibility(otherVis);
        if (modernTv) {
            dock.setVisibility(View.VISIBLE);
            if (actionHost != null) actionHost.setVisibility(otherVis);
        } else {
            dock.setVisibility(otherVis);
            if (lockBtn != null) lockBtn.setVisibility(otherVis);
        }
        seekHint.setVisibility(resolved ? View.VISIBLE : View.GONE);
        if (!modernTv && a.isTvDevice()) {
            scheduleLayout();
        }
        update();
        if (a.playbackControls != null) {
            a.playbackControls.visible(a.controlsVisible);
        }
    }

    void updatePlaybackHud(int displayPosMs, int durationMs, boolean live) {
        boolean suppressLiveHud =
                shouldSuppressLiveHudRedraws(a.isTvDevice(), hdrSurfaceActive, a.controlsVisible);
        if (slimProgressBar != null) {
            if (suppressLiveHud) {
                slimProgressBar.setActiveVisible(false);
            } else {
                slimProgressBar.setProgress(displayPosMs, durationMs);
                syncSlimProgressVisibility(durationMs, live);
            }
        }
        if (tvTopRightHud == null || hudProgressView == null || suppressLiveHud) return;
        String elapsed;
        String total;
        if (live && durationMs <= 0) {
            elapsed = "直播";
            total = "";
        } else {
            elapsed = PlaybackController.formatTime(Math.max(0, displayPosMs));
            total = durationMs > 0 ? PlaybackController.formatTime(durationMs) : "--:--";
        }
        String key = elapsed + "/" + total;
        if (!key.equals(lastHudProgressKey)) {
            lastHudProgressKey = key;
            hudProgressView.setText(formatTvHudProgress(elapsed, total));
        }
    }

    private void syncSlimProgressVisibility(int durationMs, boolean live) {
        if (slimProgressBar == null) return;
        slimProgressBar.setReducedMotion(a.reduced);
        boolean suppressLiveHud =
                shouldSuppressLiveHudRedraws(a.isTvDevice(), hdrSurfaceActive, a.controlsVisible);
        boolean showSlim =
                !suppressLiveHud
                        && shouldShowSlimProgressBar(
                                a.controlsVisible,
                                a.miniMode,
                                live,
                                a.prepared,
                                durationMs,
                                PlayerHudPrefs.isSlimProgressEnabled(a));
        slimProgressBar.setActiveVisible(showSlim);
    }

    void syncClockViews() {
        if (a.touchPlayerGesture != null) {
            a.touchPlayerGesture.syncRuntimeState();
        }
        String now = formatWallTime();
        boolean timeChanged = !now.equals(lastWallClock);
        if (timeChanged) {
            lastWallClock = now;
        }
        if (a.isTvDevice()) {
            boolean hudEnabled = a.prefs.getBoolean(Prefs.TV_PLAYER_TOP_RIGHT_HUD, true);
            boolean suppressLiveHud =
                    shouldSuppressLiveHudRedraws(true, hdrSurfaceActive, a.controlsVisible);
            boolean showHud = hudEnabled && !a.miniMode && !a.controlsVisible && !suppressLiveHud;
            if (tvTopRightHud != null) {
                int targetVis = showHud ? View.VISIBLE : View.GONE;
                if (tvTopRightHud.getVisibility() != targetVis) {
                    tvTopRightHud.setVisibility(targetVis);
                }
            }
            if (showHud
                    && persistentClock != null
                    && (!now.equals(lastPersistentClockText)
                            || persistentClock.getText().length() == 0)) {
                lastPersistentClockText = now;
                persistentClock.setText(styledWallTime(now));
            }
            if (a.controlsVisible && wallClock != null) {
                if (!now.equals(lastWallClockText) || wallClock.getText().length() == 0) {
                    lastWallClockText = now;
                    wallClock.setText(styledWallTime(now));
                }
                if (wallClock.getVisibility() != View.VISIBLE) {
                    wallClock.setVisibility(View.VISIBLE);
                }
            }
            return;
        }
        boolean alwaysShow =
                !a.miniMode && a.prefs.getBoolean(Prefs.PLAYER_ALWAYS_SHOW_CLOCK, false);
        if (persistentClock != null) {
            if (timeChanged || persistentClock.getText().length() == 0) {
                persistentClock.setText(styledWallTime(now));
            }
            persistentClock.setVisibility(alwaysShow ? View.VISIBLE : View.GONE);
        }
        if (wallClock != null) {
            if (timeChanged) {
                wallClock.setText(styledWallTime(now));
            }
            wallClock.setVisibility(alwaysShow ? View.GONE : View.VISIBLE);
        }
    }

    void update() {
        if (a.prepared) loading = false;
        syncClockViews();
        if (a.playbackControls != null) {
            a.playbackControls.syncSkipCountdownLifecycle();
            a.playbackControls.syncDanmuPlaybackState();
        }
        if (startSpecBanner != null) {
            startSpecBanner.onControlsVisibilityChanged(a.controlsVisible);
        }
        int dur = a.player != null && a.prepared ? a.player.getDuration() : 0;
        syncSlimProgressVisibility(dur, isLiveStream);
        syncTvScrubCapsule();
        boolean showSpinner =
                ((loading && !a.prepared) || (buffering && a.prepared))
                        && a.playbackLoading == null
                        && !a.miniMode;
        if (loadingPill.getVisibility() != (showSpinner ? View.VISIBLE : View.GONE)) {
            loadingPill.setVisibility(showSpinner ? View.VISIBLE : View.GONE);
        }
        if (loadingSpeedMonitor != null) {
            if (showSpinner) loadingSpeedMonitor.start();
            else loadingSpeedMonitor.stop();
        }
        if (brandLoader != null) {
            brandLoader.setReducedMotion(a.reduced);
            brandLoader.setActive(showSpinner);
        }
        if (tvMinimalPauseBadge != null) {
            boolean showMinimalPause =
                    a.isTvDevice()
                            && a.prepared
                            && !a.playing
                            && !a.controlsVisible
                            && !showSpinner
                            && !a.miniMode
                            && a.playbackLoading == null;
            tvMinimalPauseBadge.setVisibility(showMinimalPause ? View.VISIBLE : View.GONE);
        }
        if (!a.controlsVisible && !loading && !buffering && a.prepared) {
            return;
        }
        if (a.player != null && a.prepared) {
            String res = a.player.videoResolution();
            if (!res.contentEquals(resolution.getText())) {
                resolution.setText(res);
            }
            if (modernTv) {
                java.util.List<String> badges = a.player.mediaBadges();
                if (badges != null && !badges.isEmpty()) renderBadgePills(badges);
            }
        }
        if (a.playStatus != null) {
            if (a.isTvDevice()) {
                a.playStatus.setVisibility(
                        loading || buffering || !a.prepared || !a.playing
                                ? View.VISIBLE
                                : View.GONE);
            } else {
                boolean compact = !a.isPortrait() || a.windowHeight() < a.dp(440);
                a.playStatus.setVisibility(
                        (!a.prepared && !loading) || !compact ? View.VISIBLE : View.GONE);
            }
        }
        if (modernTv && cardTitleView != null && a.activeEpisode != null) {
            String expected = formatCardTitle(chromeVideo, a.activeEpisode);
            if (!expected.contentEquals(cardTitleView.getText())) {
                cardTitleView.setText(expected);
            }
        }
        if (a.playbackControls != null) {
            a.playbackControls.refreshPlayPauseGlyph();
        }
        int stateVis =
                showSpinner
                        ? View.GONE
                        : (progressOnlyMode
                                ? View.INVISIBLE
                                : (a.isTvDevice() && a.prepared && a.playing
                                        ? View.GONE
                                        : View.VISIBLE));
        state.setVisibility(stateVis);
        if (centerRow != null) centerRow.setVisibility(stateVis);
        state.setContentDescription(!a.prepared ? "正在准备" : a.playing ? "正在播放，确认暂停" : "已暂停，确认继续");
        state.invalidate();
    }

    /** Subtle unobtrusive frosted pause circle shown when TV pauses without opening HUD. */
    final class MinimalPauseBadge extends View {
        final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
        final RectF rect = new RectF();

        MinimalPauseBadge() {
            super(a);
        }

        @Override
        protected void onDraw(Canvas canvas) {
            float w = getWidth(), h = getHeight();
            if (w <= 0 || h <= 0) return;
            float cx = w * .5f, cy = h * .5f, r = Math.min(w, h) * .5f;
            paint.setStyle(Paint.Style.FILL);
            paint.setColor(0x99141822);
            canvas.drawCircle(cx, cy, r - 1f, paint);
            paint.setStyle(Paint.Style.STROKE);
            paint.setStrokeWidth(Math.max(1.2f, r * .045f));
            paint.setColor(0x38ffffff);
            canvas.drawCircle(cx, cy, r - paint.getStrokeWidth(), paint);
            paint.setStyle(Paint.Style.FILL);
            paint.setColor(0xf2ffffff);
            float bw = r * .17f, bh = r * .33f, gap = r * .12f, cr = r * .07f;
            rect.set(cx - gap - bw, cy - bh, cx - gap, cy + bh);
            canvas.drawRoundRect(rect, cr, cr, paint);
            rect.set(cx + gap, cy - bh, cx + gap + bw, cy + bh);
            canvas.drawRoundRect(rect, cr, cr, paint);
        }
    }

    final class StateGlyph extends View {
        final Paint paint = new Paint(3);

        StateGlyph() {
            super(a);
        }

        @Override
        protected void onDraw(Canvas canvas) {
            float cx = getWidth() / 2f, cy = getHeight() / 2f;
            paint.setColor(0x99303034);
            canvas.drawCircle(cx, cy, getWidth() / 2f, paint);
            paint.setColor(MainActivity.WHITE);
            if (!a.prepared) {
                paint.setStrokeWidth(a.dp(3));
                paint.setStyle(Paint.Style.STROKE);
                canvas.drawCircle(cx, cy, a.dp(12), paint);
                paint.setStyle(Paint.Style.FILL);
                return;
            }
            if (a.playing) {
                canvas.drawRoundRect(
                        new RectF(cx - a.dp(10), cy - a.dp(13), cx - a.dp(3), cy + a.dp(13)),
                        a.dp(2),
                        a.dp(2),
                        paint);
                canvas.drawRoundRect(
                        new RectF(cx + a.dp(3), cy - a.dp(13), cx + a.dp(10), cy + a.dp(13)),
                        a.dp(2),
                        a.dp(2),
                        paint);
            } else {
                Path p = new Path();
                p.moveTo(cx - a.dp(8), cy - a.dp(14));
                p.lineTo(cx + a.dp(15), cy);
                p.lineTo(cx - a.dp(8), cy + a.dp(14));
                p.close();
                paint.setStrokeJoin(Paint.Join.ROUND);
                paint.setStrokeWidth(a.dp(3));
                paint.setStyle(Paint.Style.FILL_AND_STROKE);
                canvas.drawPath(p, paint);
                paint.setStyle(Paint.Style.FILL);
            }
        }
    }

    final class PadlockGlyph extends View {
        final boolean closed;
        final int color;
        final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
        final RectF rect = new RectF();

        PadlockGlyph(boolean closed, int color) {
            super(a);
            this.closed = closed;
            this.color = color;
        }

        @Override
        protected void onDraw(Canvas canvas) {
            float w = getWidth(), h = getHeight();
            if (w <= 0 || h <= 0) return;
            float cx = w * 0.5f;
            float stroke = Math.max(a.dp(1.6f), w * 0.105f);
            paint.reset();
            paint.setAntiAlias(true);
            paint.setColor(color);
            paint.setStrokeCap(Paint.Cap.ROUND);
            paint.setStrokeJoin(Paint.Join.ROUND);

            float bodyW = w * 0.68f;
            float bodyH = h * 0.48f;
            float bodyLeft = cx - bodyW * 0.5f;
            float bodyTop = h * 0.44f;
            rect.set(bodyLeft, bodyTop, bodyLeft + bodyW, bodyTop + bodyH);
            paint.setStyle(Paint.Style.FILL);
            canvas.drawRoundRect(rect, w * 0.14f, w * 0.14f, paint);

            float shackleW = bodyW * 0.62f;
            float shackleLeft = cx - shackleW * 0.5f;
            float shackleTop = closed ? h * 0.13f : h * 0.08f;
            rect.set(shackleLeft, shackleTop, shackleLeft + shackleW, shackleTop + shackleW);
            paint.setStyle(Paint.Style.STROKE);
            paint.setStrokeWidth(stroke);
            if (closed) {
                canvas.drawArc(rect, 180f, 180f, false, paint);
                canvas.drawLine(
                        shackleLeft, shackleTop + shackleW * 0.5f, shackleLeft, bodyTop, paint);
                canvas.drawLine(
                        shackleLeft + shackleW,
                        shackleTop + shackleW * 0.5f,
                        shackleLeft + shackleW,
                        bodyTop,
                        paint);
            } else {
                canvas.drawArc(rect, 195f, 165f, false, paint);
                canvas.drawLine(
                        shackleLeft + shackleW,
                        shackleTop + shackleW * 0.5f,
                        shackleLeft + shackleW,
                        bodyTop,
                        paint);
            }

            paint.setStyle(Paint.Style.FILL);
            paint.setColor(0xff181a22);
            canvas.drawCircle(cx, bodyTop + bodyH * 0.48f, Math.max(1.2f, w * 0.075f), paint);
        }
    }
}
